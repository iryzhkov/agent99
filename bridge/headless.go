package main

// Headless workspaces for the standalone MCP server. When the bridge is not
// launched from inside Neovim (no $AGENT99_NVIM), a client such as Claude
// Code first calls open_workspace(root): the bridge spawns
// `nvim --headless --listen <socket>` in that root with the user's normal
// configuration, so the same LSP servers attach as in an interactive
// session. Several roots can be open at once, and each tool call is routed
// to the instance that owns the path it names (see routing.go). An instance
// is killed when its workspace is closed or the server exits.
//
// Open workspaces never overlap: a root that contains, or is contained by,
// an open one is refused. Two instances over one file tree would each hold
// their own buffers for the same files, and an edit made in one would be
// lost the moment the other wrote.

import (
	"crypto/sha1"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

const (
	headlessStartTimeout = 20 * time.Second
	headlessStopTimeout  = 3 * time.Second
	// Each workspace is a Neovim with a full set of language servers - a
	// gopls over a large repository is a gigabyte by itself - so how many
	// run at once is capped rather than left to the agent.
	defaultMaxWorkspaces = 10
)

type headlessWorkspace struct {
	Root   string
	Socket string
	cmd    *exec.Cmd
	stderr *tailBuffer
	done   chan struct{}
	// lastUsed is when a call was last routed here, which is what the idle
	// sweep in lifecycle.go measures. Guarded by headlessMu.
	lastUsed time.Time
	// inFlight counts the calls running here right now. A workspace with
	// one is in use whatever lastUsed says: check_project can run for ten
	// minutes, and the idle sweep must not close it from under that call.
	// Guarded by headlessMu.
	inFlight int
}

func (w *headlessWorkspace) session() session {
	return session{Root: w.Root, Socket: w.Socket, Headless: true}
}

var (
	headlessMu sync.Mutex
	workspaces = map[string]*headlessWorkspace{}
	// instanceSeq numbers the instances this bridge has started, for their
	// socket names.
	instanceSeq atomic.Int64
)

func maxWorkspaces() int {
	if v := os.Getenv("AGENT99_MAX_WORKSPACES"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 {
			return n
		}
	}
	return defaultMaxWorkspaces
}

// tailBuffer keeps the last few kilobytes written to it, for error reports.
type tailBuffer struct {
	mu  sync.Mutex
	buf []byte
}

func (t *tailBuffer) Write(p []byte) (int, error) {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.buf = append(t.buf, p...)
	if len(t.buf) > 4096 {
		t.buf = t.buf[len(t.buf)-4096:]
	}
	return len(p), nil
}

func (t *tailBuffer) String() string {
	t.mu.Lock()
	defer t.mu.Unlock()
	return strings.TrimSpace(string(t.buf))
}

// liveLocked drops the workspaces whose Neovim has exited and returns the
// rest. An instance can die underneath the server (a crash, an OOM kill),
// and a stale entry would route calls to a socket nobody answers on.
func liveLocked() map[string]*headlessWorkspace {
	for root, ws := range workspaces {
		select {
		case <-ws.done:
			os.Remove(ws.Socket)
			delete(workspaces, root)
			forgetRoot(root)
			// The per-client state this instance held - ledger, baselines,
			// what each client had been shown - died with it, so the roster
			// of clients using it means nothing now.
			forgetHolders(root)
			// Nobody asked for this one to go, so the work that was being
			// done in it probably is not finished. lifecycle.go starts it
			// again on the next call that needs it.
			noteReopenableLocked(root, "its Neovim went away")
		default:
		}
	}
	return workspaces
}

func rootsLocked() []string {
	live := liveLocked()
	out := make([]string, 0, len(live))
	for root := range live {
		out = append(out, root)
	}
	sort.Strings(out)
	return out
}

// openRoots lists the roots of the open workspaces, sorted.
func openRoots() []string {
	headlessMu.Lock()
	defer headlessMu.Unlock()
	return rootsLocked()
}

// workspaceAt returns the open workspace whose root is exactly this path.
func workspaceAt(root string) *headlessWorkspace {
	if root == "" {
		return nil
	}
	headlessMu.Lock()
	defer headlessMu.Unlock()
	return liveLocked()[root]
}

// workspaceFor returns the open workspace whose root contains path (or is
// path). Roots never overlap, so at most one can match.
func workspaceFor(path string) *headlessWorkspace {
	if path == "" {
		return nil
	}
	headlessMu.Lock()
	defer headlessMu.Unlock()
	for root, ws := range liveLocked() {
		if underRoot(root, path) {
			return ws
		}
	}
	return nil
}

// underRoot reports whether path is root or lies inside it.
func underRoot(root, path string) bool {
	if root == path {
		return true
	}
	return strings.HasPrefix(path, strings.TrimSuffix(root, string(os.PathSeparator))+string(os.PathSeparator))
}

func socketDir() (string, error) {
	base := os.Getenv("XDG_RUNTIME_DIR")
	if base == "" {
		base = os.TempDir()
	}
	dir := filepath.Join(base, "agent99")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "", err
	}
	return dir, nil
}

// nvimAlive reports whether the plugin's RPC entry point answers on sock.
func nvimAlive(sock string) bool {
	if _, err := os.Stat(sock); err != nil {
		return false
	}
	out, err := remoteExpr(sock, "luaeval('type(Agent99RpcStart)')")
	return err == nil && strings.TrimSpace(out) == "function"
}

// usableRoot refuses the two directories that are not a project tree: the
// home directory, which holds every project on the machine plus its caches
// and dotfiles, and a filesystem root, which holds the machine. The refusal
// is not about taste. Everything that walks a workspace walks all of it -
// project_files behind find_symbol and workspace_map, and the language
// servers doing their own indexing - and the friction spool measured what
// that costs: single edits in a workspace rooted at the home directory took
// 244s, 255s and 476s, against a median of 1.4s for the same tool elsewhere.
//
// AGENT99_ALLOW_WIDE_ROOT=1 lifts the refusal, for a session that means it.
func usableRoot(abs string) error {
	if os.Getenv("AGENT99_ALLOW_WIDE_ROOT") != "" {
		return nil
	}
	if abs == filepath.Dir(abs) {
		return fmt.Errorf("%s is a filesystem root, not a project: opening it would "+
			"point the language servers at the whole machine. Open the project "+
			"directory instead, or set AGENT99_ALLOW_WIDE_ROOT=1 if that is really "+
			"what you want", abs)
	}
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		return nil
	}
	if resolved, err := filepath.EvalSymlinks(home); err == nil {
		home = resolved
	}
	if abs == filepath.Clean(home) {
		return fmt.Errorf("%s is the home directory, not a project root: every tool "+
			"that walks the tree would walk every project, cache and dotfile under it "+
			"(measured here: single edits in a workspace rooted at the home directory "+
			"took 4 to 8 minutes, against a median of 1.4s elsewhere). Open the "+
			"repository or config directory the work is in - ~/Work/<project>, "+
			"~/.config/hypr - or set AGENT99_ALLOW_WIDE_ROOT=1 to open the home "+
			"directory anyway", abs)
	}
	return nil
}

// openWorkspace starts (or reuses) a headless Neovim rooted at root, and
// makes it the active workspace. Reopening the same root is a no-op; a root
// that shares a file tree with an open workspace is refused, and so is one
// past the workspace limit and one that is not a project tree at all
// (usableRoot).
func openWorkspace(root string) (*headlessWorkspace, error) {
	if root == "" {
		return nil, errors.New("open_workspace needs a root directory")
	}
	abs, err := filepath.Abs(root)
	if err != nil {
		return nil, err
	}
	if resolved, err := filepath.EvalSymlinks(abs); err == nil {
		abs = resolved
	}
	info, err := os.Stat(abs)
	if err != nil {
		return nil, fmt.Errorf("workspace root: %v", err)
	}
	if !info.IsDir() {
		return nil, fmt.Errorf("workspace root is not a directory: %s", abs)
	}
	if err := usableRoot(abs); err != nil {
		return nil, err
	}

	headlessMu.Lock()
	defer headlessMu.Unlock()
	live := liveLocked()
	if ws := live[abs]; ws != nil {
		if nvimAlive(ws.Socket) {
			noteRouted(stickyActive, abs)
			forgetReopenableLocked(abs)
			ws.lastUsed = time.Now()
			return ws, nil
		}
		// Listening on the socket but not answering: replace it.
		delete(workspaces, abs)
		stopWorkspace(ws)
		forgetRoot(abs)
	}
	for _, other := range rootsLocked() {
		if underRoot(other, abs) || underRoot(abs, other) {
			return nil, fmt.Errorf("%s shares a file tree with the open workspace %s. "+
				"One Neovim per tree: two instances would hold their own buffers for the "+
				"same files, and an edit made in one is lost when the other writes. Close "+
				"%s first, or open a root beside it rather than inside or around it",
				abs, other, other)
		}
	}
	if max := maxWorkspaces(); len(workspaces) >= max {
		return nil, fmt.Errorf("%d workspaces are already open (%s) and the limit is %d; "+
			"close one of your own with close_workspace, or wait and retry - a workspace "+
			"is a Neovim with its own language servers, and the roots above may belong to "+
			"other agents sharing this server, whose slots free up when they finish. Raise "+
			"AGENT99_MAX_WORKSPACES in the server's environment if this machine has the "+
			"memory for more",
			len(workspaces), strings.Join(rootsLocked(), ", "), max)
	}

	dir, err := socketDir()
	if err != nil {
		return nil, err
	}
	// <hash of root>-<instance number>-<bridge pid>.sock. The instance
	// number keeps the name unique across reopenings of the same root: an
	// idle sweep unlocks before its stopWorkspace runs, and a call in that
	// window auto-opens a new instance whose socket must not be the one the
	// old instance is about to unlink. The pid stays last, which is where
	// sweepStaleSockets reads it.
	sum := sha1.Sum([]byte(abs))
	sock := filepath.Join(dir, fmt.Sprintf("%s-%d-%d.sock",
		hex.EncodeToString(sum[:6]), instanceSeq.Add(1), os.Getpid()))
	os.Remove(sock)

	args := []string{"--headless", "--listen", sock,
		"--cmd", "set noswapfile shadafile=NONE"}
	// Tests point this at a minimal config so the run does not depend on
	// the user's plugins.
	if init := os.Getenv("AGENT99_HEADLESS_INIT"); init != "" {
		args = append(args, "--clean", "-u", init)
	}
	cmd := exec.Command("nvim", args...)
	cmd.Dir = abs
	tail := &tailBuffer{}
	cmd.Stderr = tail
	cmd.Stdout = tail
	cmd.Stdin = nil
	setDeathSignal(cmd)
	if err := cmd.Start(); err != nil {
		return nil, fmt.Errorf("starting nvim: %v", err)
	}
	ws := &headlessWorkspace{Root: abs, Socket: sock, cmd: cmd, stderr: tail,
		done: make(chan struct{}), lastUsed: time.Now()}
	go func() {
		cmd.Wait()
		close(ws.done)
	}()

	deadline := time.Now().Add(headlessStartTimeout)
	for time.Now().Before(deadline) {
		select {
		case <-ws.done:
			os.Remove(sock)
			return nil, fmt.Errorf("nvim exited during startup: %s", tail.String())
		default:
		}
		if nvimAlive(sock) {
			workspaces[abs] = ws
			noteRouted(stickyActive, abs)
			forgetReopenableLocked(abs)
			ws.lastUsed = time.Now()
			return ws, nil
		}
		time.Sleep(100 * time.Millisecond)
	}
	cmd.Process.Kill()
	<-ws.done
	os.Remove(sock)
	detail := tail.String()
	if detail == "" {
		detail = "the agent99 plugin never answered on the socket (is it on the runtimepath?)"
	}
	return nil, fmt.Errorf("nvim did not come up within %s: %s", headlessStartTimeout, detail)
}

// closeWorkspaces stops the workspaces with these roots and returns the ones
// it actually stopped. The entries leave the map before the instances are
// told to quit, so a stop that takes its full timeout does not hold the lock
// against the rest of the server.
func closeWorkspaces(roots []string) []string {
	headlessMu.Lock()
	live := liveLocked()
	var targets []*headlessWorkspace
	for _, root := range roots {
		if ws := live[root]; ws != nil {
			targets = append(targets, ws)
		}
	}
	for _, ws := range targets {
		delete(workspaces, ws.Root)
		forgetRoot(ws.Root)
		forgetHolders(ws.Root)
		// An explicit close means it. The idle sweep marks its own roots
		// reopenable after calling this, because that close is the server's
		// decision rather than the agent's.
		forgetReopenableLocked(ws.Root)
	}
	headlessMu.Unlock()

	var wg sync.WaitGroup
	closed := make([]string, 0, len(targets))
	for _, ws := range targets {
		closed = append(closed, ws.Root)
		wg.Add(1)
		go func(ws *headlessWorkspace) {
			defer wg.Done()
			stopWorkspace(ws)
		}(ws)
	}
	wg.Wait()
	sort.Strings(closed)
	return closed
}

// closeAllWorkspaces stops every open workspace. Called on the way out, so
// the server never leaves a headless Neovim behind.
func closeAllWorkspaces() []string {
	return closeWorkspaces(openRoots())
}

// stopWorkspace ends one instance. The caller has already taken it out of
// the map.
func stopWorkspace(ws *headlessWorkspace) {
	// The socket name is unique to this instance (see openWorkspace), so
	// removing it can never unlink the socket of a newer instance that
	// reopened the same root while this one was on its way out.
	defer os.Remove(ws.Socket)
	select {
	case <-ws.done:
		return
	default:
	}
	// Ask nicely so buffers and LSP clients shut down, then force it. The
	// asking happens off to the side: on a wedged instance each remote
	// expression runs to its own timeout, and the kill below must still
	// come on schedule rather than after all of them.
	asked := make(chan struct{})
	go func() {
		defer close(asked)
		// A debug session's adapter and debuggee are grandchildren of this
		// process; end them before the instance goes, so close_workspace
		// never leaves a program running under a debugger nobody can reach.
		if debugEnabled() {
			remoteExpr(ws.Socket, "luaeval('"+headlessDebugStopLua+"')")
		}
		remoteExpr(ws.Socket, "execute('qa!')")
	}()
	kill := func() {
		ws.cmd.Process.Kill()
		<-ws.done
	}
	select {
	case <-ws.done:
	case <-asked:
		select {
		case <-ws.done:
		case <-time.After(headlessStopTimeout):
			kill()
		}
	case <-time.After(remoteExprTimeout):
		// The instance is not even answering the request to quit.
		kill()
	}
}

// Lua expression that ends the agent's debug session, if any; errors are
// swallowed because the instance is about to be killed anyway.
var headlessDebugStopLua = strings.Join([]string{
	`(function() pcall(function()`,
	`require("agent99.dap").shutdown_sync() end) return "" end)()`,
}, " ")

// Edits made by the symbol tools land in buffers; with no user at the
// keyboard they must reach disk on their own, otherwise a client reading
// files directly would see stale content. (BufModifiedSet does not fire for
// API edits to hidden buffers, so an autocmd cannot do this.)
var editTools = map[string]bool{
	"replace_symbol_body":  true,
	"replace_symbol_lines": true,
	"insert_after_symbol":  true,
	"insert_before_symbol": true,
	"insert_lines":         true,
	"apply_code_action":    true,
	"undo_edit":            true,
	"rename_symbol":        true,
	"replace_pattern":      true,
	// The file-lifecycle tools write the file themselves, but a server may
	// have rewritten other files' imports in response, and those land in
	// buffers like any other edit.
	"create_file":  true,
	"move_file":    true,
	"delete_file":  true,
	"move_symbols": true,
}

// headlessSaveAll writes every modified file buffer of the headless
// instance and reports the first failures.
func headlessSaveAll(ses session) error {
	if ses.Socket == "" {
		return nil
	}
	out, err := remoteExpr(ses.Socket, "luaeval('"+headlessSaveLua+"')")
	if err != nil {
		return err
	}
	if msg := strings.TrimSpace(out); msg != "" {
		return fmt.Errorf("saving buffers: %s", msg)
	}
	return nil
}

// Lua expression (single quotes are forbidden: it travels inside a
// Vimscript string literal) returning "" or the joined write errors.
//
// The saving itself lives in agent99.lsp so that it goes through the same
// disk-fingerprint check as every other write: a plain `:write` over a file
// that changed on disk asks the user whether to overwrite it, and in a
// headless instance that question never gets an answer - it hangs the RPC
// channel and the edit is lost.
var headlessSaveLua = strings.Join([]string{
	`(function() local ok, r = pcall(function()`,
	`return require("agent99.lsp").save_all() end)`,
	`if not ok then return tostring(r) end`,
	`return table.concat(r, "; ") end)()`,
}, " ")
