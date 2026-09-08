package main

// Workspace lifecycle: what happens to a headless Neovim between the call
// that opened it and the one that closes it.
//
// Four things live here, and they are one design rather than four fixes.
//
// A workspace can go away without anybody closing it - the Neovim crashes, or
// the OOM killer takes it, or the idle sweep below collects it. Until now that
// turned the next call into "no Neovim to talk to: call open_workspace first",
// an error the agent has to notice, understand and recover from in the middle
// of doing something else. reviveFor starts the instance again instead, so a
// workspace dying underneath the server costs a pause.
//
// That is what makes an idle timeout safe to have. A workspace is a Neovim
// with a full set of language servers behind it - measured on this machine, a
// lua-language-server is 175-450 MB and a session holding two workspaces was
// 923 MB - and it stays up for the whole session even when nothing has touched
// it for hours. Collecting an idle one gives that memory back, and because the
// next call reopens it, the agent sees a slow call rather than a failure.
//
// The same reasoning covers the workspace that was never opened at all.
// autoOpenFor takes the root a call already names - the file in its
// arguments, or the project around the working directory - and opens it,
// because "call open_workspace first" is a round trip spent restating what
// the arguments said.
//
// Finally, an instance that is killed outright cannot remove its own socket,
// so the runtime directory collects dead entries. Every socket carries the pid
// of the bridge that made it, which is enough to tell on startup which ones
// belong to nobody.

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// defaultWorkspaceIdle is how long a workspace may sit untouched before it is
// closed. Long enough not to fire between two steps of the same piece of work,
// short enough that a session left open over lunch is not holding a gigabyte.
const defaultWorkspaceIdle = 30 * time.Minute

// reopenable remembers the roots of workspaces that went away without the
// agent closing them, against why. Guarded by headlessMu, like the workspaces
// map it shadows.
var reopenable = map[string]string{}

// noteReopenableLocked records that a root's instance is gone but its work is
// probably not. reason is what to tell the log when it comes back. The caller
// holds headlessMu.
func noteReopenableLocked(root, reason string) {
	if root != "" {
		reopenable[root] = reason
	}
}

// forgetReopenableLocked drops a root that is open again, or that the user
// closed deliberately. The caller holds headlessMu.
func forgetReopenableLocked(root string) {
	delete(reopenable, root)
}

func reopenableRoots() []string {
	headlessMu.Lock()
	defer headlessMu.Unlock()
	roots := make([]string, 0, len(reopenable))
	for root := range reopenable {
		roots = append(roots, root)
	}
	return roots
}

// reviveFor restarts the workspace that owned path, when one was open there
// and went away by itself. It returns nil when there is nothing to revive,
// and when the restart fails - a failure here has to look like "no workspace",
// not like a new kind of error, because the caller is in the middle of an
// ordinary call that never asked for any of this.
func reviveFor(path string) *headlessWorkspace {
	if path == "" {
		return nil
	}
	headlessMu.Lock()
	target, reason := "", ""
	for root, why := range reopenable {
		if underRoot(root, path) {
			target, reason = root, why
			break
		}
	}
	headlessMu.Unlock()
	if target == "" {
		return nil
	}
	ws, err := openWorkspace(target)
	if err != nil {
		// Do not try again on every call: whatever stopped it starting is
		// unlikely to clear up between one tool call and the next, and the
		// agent is better off being told to open a workspace itself.
		headlessMu.Lock()
		forgetReopenableLocked(target)
		headlessMu.Unlock()
		fmt.Fprintf(os.Stderr, "agent99: could not reopen %s: %v\n", target, err)
		return nil
	}
	fmt.Fprintf(os.Stderr, "agent99: reopened %s (%s)\n", target, reason)
	return ws
}

// relativeRevivalRoot picks the one root, among candidates, whose tree
// actually holds this relative path - checking the path itself first (an
// existing file: find_symbol, hover, replace_symbol_lines all name one),
// then its parent directory (create_file names a path that does not exist
// yet, but the directory it lands in does). More than one candidate holding
// it is not a disambiguation, so that is treated the same as none: a guess
// between two real projects is worse than the error the caller already
// knows how to recover from.
func relativeRevivalRoot(rel string, roots []string) string {
	under := func(sub string) string {
		match := ""
		for _, root := range roots {
			if _, err := os.Stat(filepath.Join(root, sub)); err != nil {
				continue
			}
			if match != "" {
				return ""
			}
			match = root
		}
		return match
	}
	if root := under(rel); root != "" {
		return root
	}
	if dir := filepath.Dir(rel); dir != "." && dir != "" {
		return under(dir)
	}
	return ""
}

// reviveIfNeeded gives a call that names a path in a vanished workspace its
// workspace back, before the routing tries to pick one.
func reviveIfNeeded(args map[string]any) {
	// A workspace is only known to be gone once something has looked, and
	// what looks is liveLocked. Without this the first call after an instance
	// dies still sees an empty reopenable map and fails the way it used to.
	headlessMu.Lock()
	liveLocked()
	waiting := len(reopenable)
	headlessMu.Unlock()
	if waiting == 0 {
		return
	}
	if want, ok := args["workspace"].(string); ok && strings.TrimSpace(want) != "" {
		reviveFor(realPath(absPath(want)))
		return
	}
	for _, path := range argPaths(args) {
		if resolved := realPath(path); workspaceFor(resolved) == nil {
			if reviveFor(resolved) != nil {
				return
			}
		}
	}
	// A relative path names no workspace by itself - that is what argPaths
	// leaves it out for - but it can still pick one out of several
	// reopenable roots: a path that exists under exactly one of them almost
	// certainly belongs to it. This is what an idle-swept session with a
	// relative-only call (no absolute path, cwd refused as a root) needs,
	// since without it such a call falls through to autoOpenFor and finds
	// nothing to open either.
	roots := reopenableRoots()
	for _, rel := range argPathValues(args) {
		if filepath.IsAbs(rel) {
			continue
		}
		if root := relativeRevivalRoot(rel, roots); root != "" {
			reviveFor(root)
			return
		}
	}
	if len(openRoots()) == 0 && len(roots) == 1 {
		reviveFor(roots[0])
	}
}

// projectMarkers are the files that say "this directory is a project". The
// list is deliberately short: a marker that is common inside a project as
// well as at its top (a Makefile, a README) would root a workspace at a
// subdirectory and hide the rest of the tree from every symbol tool.
var projectMarkers = []string{
	".git", ".hg", "go.mod", "package.json", "Cargo.toml",
	"pyproject.toml", "setup.py", "pom.xml", "build.gradle", "flake.nix",
}

// projectRootFor walks up from path to the nearest directory holding a
// project marker, and returns "" when there is none below the home
// directory. Stopping at home is what keeps the walk from answering with the
// home directory itself, which openWorkspace refuses anyway (usableRoot).
func projectRootFor(path string) string {
	if path == "" {
		return ""
	}
	dir := path
	if info, err := os.Stat(dir); err != nil || !info.IsDir() {
		dir = filepath.Dir(dir)
	}
	home, err := os.UserHomeDir()
	if err == nil && home != "" {
		if resolved, err := filepath.EvalSymlinks(home); err == nil {
			home = resolved
		}
		home = filepath.Clean(home)
	}
	for dir != "" && dir != home && dir != filepath.Dir(dir) {
		for _, marker := range projectMarkers {
			if _, err := os.Stat(filepath.Join(dir, marker)); err == nil {
				return dir
			}
		}
		dir = filepath.Dir(dir)
	}
	return ""
}

// autoOpenFor opens the workspace a call is already talking about, when the
// call needs Neovim and none is open.
//
// The friction spool is what asked for this. "no Neovim to talk to: call
// open_workspace(root) first" was one of the most common failures in real
// sessions, and every one of them recovered the same way: the agent read the
// error, called open_workspace with the root it had just named in the failed
// call, and carried on. That is a round trip spent restating something the
// arguments already said, so the server does it instead. It stays a failure
// when there is nothing to infer from - no path in the arguments and no
// project around the working directory - because guessing a root wrongly is
// worse than asking for one.
func autoOpenFor(name string, args map[string]any) *headlessWorkspace {
	// Embedded in an editor, or pointed at a running Neovim: there is a
	// session already and workspaces are not this bridge's to open.
	if !lspToolNames[name] || os.Getenv("NVIM") != "" {
		return nil
	}
	candidates := []string{}
	if want, ok := args["workspace"].(string); ok && strings.TrimSpace(want) != "" {
		candidates = append(candidates, absPath(want))
	}
	candidates = append(candidates, argPaths(args)...)
	candidates = append(candidates, cwd())
	seen := map[string]bool{}
	for _, candidate := range candidates {
		root := projectRootFor(realPath(candidate))
		if root == "" || seen[root] {
			continue
		}
		seen[root] = true
		ws, err := openWorkspace(root)
		if err != nil {
			fmt.Fprintf(os.Stderr, "agent99: %s needed a workspace and %s would not open: %v\n",
				name, root, err)
			continue
		}
		fmt.Fprintf(os.Stderr, "agent99: opened %s for %s (nothing was open)\n", root, name)
		return ws
	}
	return nil
}

// workspaceIdleTimeout is how long a workspace may go untouched.
// AGENT99_WORKSPACE_IDLE takes a duration ("45m", "2h"); "0" or "off" leaves
// workspaces up for the whole session, the way they used to be.
func workspaceIdleTimeout() time.Duration {
	value := strings.TrimSpace(os.Getenv("AGENT99_WORKSPACE_IDLE"))
	if value == "" {
		return defaultWorkspaceIdle
	}
	if value == "0" || strings.EqualFold(value, "off") {
		return 0
	}
	idle, err := time.ParseDuration(value)
	if err != nil || idle <= 0 {
		return defaultWorkspaceIdle
	}
	return idle
}

// beginCall marks the workspace a session was resolved to as busy for the
// duration of one call, and endCall releases it; both also mark it as
// used, so "idle" means what it says rather than "opened a while ago".
// Between the two the idle sweep leaves the workspace alone, however long
// the call runs. The socket identifies the instance (it is unique per
// instance), so a workspace replaced underneath a call is not miscounted.
func beginCall(ses session) {
	headlessMu.Lock()
	if ws := workspaces[ses.Root]; ws != nil && ws.Socket == ses.Socket {
		ws.inFlight++
		ws.lastUsed = time.Now()
	}
	headlessMu.Unlock()
}

func endCall(ses session) {
	headlessMu.Lock()
	if ws := workspaces[ses.Root]; ws != nil && ws.Socket == ses.Socket {
		if ws.inFlight > 0 {
			ws.inFlight--
		}
		ws.lastUsed = time.Now()
	}
	headlessMu.Unlock()
}

// reapIdleWorkspaces closes the workspaces nothing has used for idle, and
// returns their roots. They stay reopenable, so the next call that needs one
// gets it back.
func reapIdleWorkspaces(idle time.Duration) []string {
	headlessMu.Lock()
	var stale []string
	for root, ws := range liveLocked() {
		// A call in flight is use, however long ago it started.
		if ws.inFlight == 0 && time.Since(ws.lastUsed) >= idle {
			stale = append(stale, root)
		}
	}
	headlessMu.Unlock()
	if len(stale) == 0 {
		return nil
	}
	closed := closeWorkspaces(stale)
	headlessMu.Lock()
	for _, root := range closed {
		noteReopenableLocked(root, "closed as idle")
	}
	headlessMu.Unlock()
	return closed
}

func startIdleReaper() {
	idle := workspaceIdleTimeout()
	if idle <= 0 {
		return
	}
	// Check twice per idle period, but never more than once a minute: the
	// sweep costs nothing, and a short timeout set for a test should not have
	// to wait a whole minute to be observed.
	interval := idle / 2
	if interval > time.Minute {
		interval = time.Minute
	}
	if interval < time.Second {
		interval = time.Second
	}
	go func() {
		ticker := time.NewTicker(interval)
		defer ticker.Stop()
		for range ticker.C {
			for _, root := range reapIdleWorkspaces(idle) {
				fmt.Fprintf(os.Stderr,
					"agent99: closed %s, idle for %s (it reopens on the next call)\n",
					root, idle)
			}
		}
	}()
}

// sweepStaleSockets removes socket files left by bridges that are no longer
// running. A Neovim that exits normally removes its own; one that is killed
// outright cannot, and nothing else ever cleans up after it.
func sweepStaleSockets() {
	dir, err := socketDir()
	if err != nil {
		return
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		return
	}
	self := os.Getpid()
	for _, entry := range entries {
		name := entry.Name()
		if !strings.HasSuffix(name, ".sock") {
			continue
		}
		// The name ends in -<pid of the bridge that made it>.sock (see
		// openWorkspace), so the owner is knowable without talking to the
		// socket - which matters, because another live bridge's socket must
		// not be touched.
		base := strings.TrimSuffix(name, ".sock")
		dash := strings.LastIndexByte(base, '-')
		if dash < 0 {
			continue
		}
		pid, err := strconv.Atoi(base[dash+1:])
		if err != nil || pid == self || processAlive(pid) {
			continue
		}
		os.Remove(filepath.Join(dir, name))
	}
}

func processAlive(pid int) bool {
	proc, err := os.FindProcess(pid)
	if err != nil {
		return false
	}
	return proc.Signal(syscall.Signal(0)) == nil
}
