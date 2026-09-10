package main

// Routing: which Neovim a tool call is sent to, and which project root its
// relative paths resolve against.
//
// The standalone server can hold several headless workspaces open at once
// (see headless.go). They never overlap, so a path belongs to at most one of
// them and most calls route themselves: the workspace that owns the file
// named in the arguments is the one that gets the call - owns it as the
// caller wrote it, not as it resolves, so a symlink cannot carry the call
// into a workspace nobody named. Calls that name no path - check_project,
// undo_edit, the debugger tools - fall back to an explicit "workspace"
// argument, then to the workspace last used for that kind of work, then to
// the active one. With several open, a path no workspace holds is refused
// rather than guessed at.

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
)

// session is the Neovim instance a tool call is routed to, plus the project
// root its relative paths resolve against.
type session struct {
	Root   string
	Socket string
	// Headless is true when the instance is a workspace this server
	// started: nobody is at the keyboard, so edits are saved to disk and
	// the tools word their replies accordingly.
	Headless bool
	// Client is who the call is for (see client.go). One instance serves
	// every client that opened its root, and the editor keys the undo
	// ledger, the baselines and the disclosed-diagnostics set by it.
	Client string
}

// Sticky pointers, so that a call with nothing to route on lands where the
// work it continues happened. Which one applies depends on the tool: an undo
// belongs to the workspace that was edited even if a read of another
// workspace came in between, and a code action belongs to the workspace that
// issued its token.
type stickyKind int

const (
	stickyActive stickyKind = iota
	stickyEdit
	stickyAction
	stickyDebug
)

var routing struct {
	mu     sync.Mutex
	active string
	edit   string
	action string
	debug  string
}

func (k stickyKind) slot() *string {
	switch k {
	case stickyEdit:
		return &routing.edit
	case stickyAction:
		return &routing.action
	case stickyDebug:
		return &routing.debug
	default:
		return &routing.active
	}
}

func noteRouted(kind stickyKind, root string) {
	routing.mu.Lock()
	defer routing.mu.Unlock()
	*kind.slot() = root
}

func stickyRoot(kind stickyKind) string {
	routing.mu.Lock()
	defer routing.mu.Unlock()
	return *kind.slot()
}

// forgetRoot clears the sticky pointers to a workspace that is gone, so a
// later call is not routed to a socket nobody is listening on.
func forgetRoot(root string) {
	routing.mu.Lock()
	defer routing.mu.Unlock()
	for _, k := range []stickyKind{stickyActive, stickyEdit, stickyAction, stickyDebug} {
		if slot := k.slot(); *slot == root {
			*slot = ""
		}
	}
}

// stickyFor says which sticky pointer a tool follows when its arguments name
// no path.
func stickyFor(name string) stickyKind {
	switch {
	case name == "apply_code_action":
		return stickyAction
	case editTools[name]:
		// undo_edit is in here: an undo belongs to the workspace that was
		// edited, which is not always the one read from last.
		return stickyEdit
	case debugToolNames[name]:
		return stickyDebug
	}
	return stickyActive
}

func cwd() string {
	if dir, err := os.Getwd(); err == nil {
		return dir
	}
	return "."
}

// Argument keys whose value is a file path. "from" and "to" belong to
// move_file and move_symbols and name paths exactly as "file" does; the
// debugger's are "program" and "cwd". debug_continue's "to" is an object
// carrying its own file, handled separately.
var pathArgKeys = []string{"file", "from", "to", "path", "program", "cwd"}

// argPaths collects the absolute paths a call names. Relative paths are left
// out on purpose: they mean "in the workspace this call is routed to", which
// is the question being answered here.
// argPathValues collects every path-valued string a call names, in the
// argument shape argPaths knows about, absolute or relative.
func argPathValues(args map[string]any) []string {
	var out []string
	add := func(v any) {
		if s, ok := v.(string); ok && s != "" {
			out = append(out, s)
		}
	}
	for _, key := range pathArgKeys {
		add(args[key])
	}
	if to, ok := args["to"].(map[string]any); ok {
		add(to["file"])
	}
	if list, ok := args["files"].([]any); ok {
		for _, v := range list {
			add(v)
		}
	}
	return out
}

// argPaths collects the absolute paths a call names. Relative paths are left
// out on purpose: they mean "in the workspace this call is routed to", which
// is the question being answered here.
func argPaths(args map[string]any) []string {
	var out []string
	for _, s := range argPathValues(args) {
		if filepath.IsAbs(s) {
			out = append(out, filepath.Clean(s))
		}
	}
	return out
}

// realPath resolves symlinks in a path that may not exist yet (the
// destination of move_file, the file create_file is about to write) by
// resolving the longest ancestor that does exist. Workspace roots are stored
// resolved, so containment tests have to compare like with like.
func realPath(path string) string {
	rest := ""
	for dir := path; ; {
		if resolved, err := filepath.EvalSymlinks(dir); err == nil {
			return filepath.Join(resolved, rest)
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return path
		}
		rest = filepath.Join(filepath.Base(dir), rest)
		dir = parent
	}
}

// namedOwner returns the workspace the caller named: the one holding the
// path as it was written. Resolution is a fallback, not the first move,
// because a symlink inside one workspace can point at a file in another: a
// path resolved first routes the call to the workspace at the far end of
// the link, which then answers with its own relative path and takes the
// edit into its own undo ledger. Resolving second still lets a root reached
// through a symlinked ancestor route, since roots are stored resolved.
func namedOwner(p string) *headlessWorkspace {
	if ws := workspaceFor(filepath.Clean(absPath(p))); ws != nil {
		return ws
	}
	return workspaceFor(realPath(p))
}

// assertNamedRoot refuses a call whose path lies inside the workspace it
// named but resolves, through a symlink, to a file outside it. Confinement
// used to be tested against the set of open roots rather than against the
// root the request named, so a link from one open workspace into another
// passed it: the write landed in the other workspace and the reply read
// like success in the one the caller had named.
func assertNamedRoot(name, root string, paths []string) error {
	for _, p := range paths {
		if !underRoot(root, p) {
			continue
		}
		target := realPath(p)
		if underRoot(root, target) {
			continue
		}
		where := "outside it"
		if other := workspaceFor(target); other != nil {
			where = "inside the open workspace " + other.Root
		}
		return fmt.Errorf("%s is inside the workspace %s, but it resolves through a symlink "+
			"to %s, which is %s. A call works in the workspace the path it names belongs to, "+
			"so %s is refused rather than served from the far end of the link: the reply would "+
			"carry the other workspace's relative path, and an edit would land there and enter "+
			"its undo ledger. Name %s to work on it where it lives",
			p, root, target, where, name, target)
	}
	return nil
}

// resolveSession picks the instance a call goes to. The returned error is
// meant for the model: it says what is open and how to disambiguate.
func resolveSession(name string, args map[string]any) (session, error) {
	// A live editor that spawned this bridge owns the session outright.
	if sock := os.Getenv("AGENT99_NVIM"); sock != "" {
		return session{Root: cwd(), Socket: sock}, nil
	}
	// A workspace that died, or that the idle sweep collected, comes back
	// here rather than turning this call into an error about open_workspace.
	reviveIfNeeded(args)
	roots := openRoots()
	if len(roots) == 0 {
		// Nothing is open. A call that needs Neovim can usually say which
		// project it means - the file it names, or the working directory -
		// so open that rather than making the agent read an error and call
		// open_workspace with a root it has already given us.
		if ws := autoOpenFor(name, args); ws != nil {
			return ws.session(), nil
		}
		// No workspace and nothing to infer one from: the file tools still
		// work against the working directory, and the LSP tools report that
		// there is no Neovim.
		return session{Root: cwd(), Socket: os.Getenv("NVIM")}, nil
	}

	if want, ok := args["workspace"].(string); ok && strings.TrimSpace(want) != "" {
		ws := workspaceFor(realPath(absPath(want)))
		if ws == nil {
			return session{}, fmt.Errorf("no open workspace at %s (open: %s)",
				want, strings.Join(roots, ", "))
		}
		// Naming the workspace does not exempt the paths from it: a link
		// out of the named root leads somewhere this call did not ask for
		// just the same.
		if err := assertNamedRoot(name, ws.Root, argPaths(args)); err != nil {
			return session{}, err
		}
		return ws.session(), nil
	}

	named := argPaths(args)
	owners := map[string]*headlessWorkspace{}
	for _, p := range named {
		if ws := namedOwner(p); ws != nil {
			owners[ws.Root] = ws
		}
	}
	if len(owners) > 1 {
		var owned []string
		for root := range owners {
			owned = append(owned, root)
		}
		return session{}, fmt.Errorf("this call names paths in %d workspaces (%s); "+
			"one call works in one workspace at a time",
			len(owners), strings.Join(owned, ", "))
	}
	for _, ws := range owners {
		if err := assertNamedRoot(name, ws.Root, named); err != nil {
			return session{}, err
		}
		return ws.session(), nil
	}
	// A write to a path no open workspace holds is refused here rather than
	// in the editor, because this is where the open roots are known. The
	// editor sees only the one workspace the call landed in, so its refusal
	// named that workspace as though the caller had asked for it - "X is
	// outside the workspace Y" about a Y nobody had mentioned.
	if editTools[name] {
		for _, p := range named {
			if namedOwner(p) != nil {
				continue
			}
			return session{}, fmt.Errorf("no open workspace holds %s, and %s writes only "+
				"inside a workspace. The root that holds it is not open (open: %s): "+
				"open_workspace there and call again - one call works in one workspace",
				p, name, strings.Join(roots, ", "))
		}
	}
	// Every path was relative, outside every workspace (a dependency under
	// ~/go/pkg/mod, a header in /usr/include), or there was none at all.
	if len(roots) == 1 {
		if ws := workspaceAt(roots[0]); ws != nil {
			return ws.session(), nil
		}
	}
	// With several open, guessing is worse than refusing. The sticky
	// pointers live in this process, and one server is shared by every agent
	// talking to it, so "where the last call of this kind went" can be
	// another agent's repository: a grep with no path answered "(no matches)"
	// from someone else's checkout, and a pattern replace with a relative
	// glob would have rewritten it. The one exception is a code action,
	// which is tied to the workspace that issued its token.
	if name == "apply_code_action" {
		if ws := workspaceAt(stickyRoot(stickyAction)); ws != nil {
			return ws.session(), nil
		}
	}
	// Nothing open owns what this call named. With one workspace open there
	// is no guess to make: an absolute path in no workspace at all - a
	// dependency under ~/go/pkg/mod, a system header - is read in that one
	// instance as it always has been, and only read, since the edit tools
	// were already turned away above. With several open one guard covers
	// both shapes of unroutable path, because the reason is the same for
	// both: the sticky pointers live in this process, one server is shared
	// by every agent talking to it, and the workspace that would answer is
	// whichever one the call happened to land in. /etc/passwd was read
	// through one agent's workspace and /etc/hostname through another's,
	// minutes apart.
	if len(roots) > 1 {
		if len(named) == 0 {
			return session{}, fmt.Errorf("%s named no absolute path and no workspace=, and %d "+
				"workspaces are open (%s), so there is nothing to route it by - a relative path "+
				"means \"in whichever workspace this lands in\". Pass workspace=<root>, or an "+
				"absolute path. The server will not guess with several open, because the guess "+
				"can be another agent's repository. This count is not yours to cache: one server "+
				"is shared by every agent on this machine, so a workspace can open between two "+
				"of your calls",
				name, len(roots), strings.Join(roots, ", "))
		}
		return session{}, fmt.Errorf("no open workspace holds %s (open: %s), and %d are open, so "+
			"%s has nothing to route it by. Whichever workspace answered would be an arbitrary "+
			"one, and the server will not guess with several open, because the guess can be "+
			"another agent's repository - it would load that path into their Neovim and their "+
			"language servers. open_workspace at the root that holds it, or pass "+
			"workspace=<root> to read it against one of the open ones. This count is not yours "+
			"to cache: one server is shared by every agent on this machine, so a workspace can "+
			"open or close between two of your calls",
			named[0], strings.Join(roots, ", "), len(roots), name)
	}
	for _, root := range []string{stickyRoot(stickyFor(name)), stickyRoot(stickyActive), roots[0]} {
		if ws := workspaceAt(root); ws != nil {
			return ws.session(), nil
		}
	}
	return session{}, fmt.Errorf("could not pick a workspace for %s (open: %s); "+
		"pass workspace=<root> or an absolute path", name, strings.Join(roots, ", "))
}

// closeTargets turns close_workspace's arguments into the roots to stop. A
// root inside an open workspace closes that workspace, the way every other
// path argument names the workspace that owns it.
func closeTargets(args map[string]any) ([]string, error) {
	open := openRoots()
	if all, _ := args["all"].(bool); all {
		return open, nil
	}
	if root, ok := args["root"].(string); ok && strings.TrimSpace(root) != "" {
		ws := workspaceFor(realPath(absPath(root)))
		if ws == nil {
			if len(open) == 0 {
				return nil, fmt.Errorf("no workspace is open")
			}
			return nil, fmt.Errorf("no open workspace at %s (open: %s)",
				root, strings.Join(open, ", "))
		}
		return []string{ws.Root}, nil
	}
	if len(open) > 1 {
		return nil, fmt.Errorf("%d workspaces are open (%s); name the root to close, "+
			"or pass all=true", len(open), strings.Join(open, ", "))
	}
	return open, nil
}

// noteCall records where a call went, so that a later call with nothing to
// route on lands where the work it continues happened. Only successful calls
// get here: a failed edit must not claim the edit pointer.
func noteCall(name string, ses session) {
	if !ses.Headless {
		return
	}
	noteRouted(stickyActive, ses.Root)
	switch {
	case name == "code_actions" || name == "apply_code_action":
		noteRouted(stickyAction, ses.Root)
	case editTools[name]:
		noteRouted(stickyEdit, ses.Root)
	case name == "debug_launch" || name == "debug_attach":
		noteRouted(stickyDebug, ses.Root)
	case name == "debug_stop":
		// The session is over; later debugger calls follow the active
		// workspace again rather than the one that used to hold it.
		noteRouted(stickyDebug, "")
	}
}

func absPath(path string) string {
	if abs, err := filepath.Abs(path); err == nil {
		return abs
	}
	return path
}
