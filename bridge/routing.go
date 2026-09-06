package main

// Routing: which Neovim a tool call is sent to, and which project root its
// relative paths resolve against.
//
// The standalone server can hold several headless workspaces open at once
// (see headless.go). They never overlap, so a path belongs to at most one of
// them and most calls route themselves: the workspace that owns the file
// named in the arguments is the one that gets the call. Calls that name no
// path - check_project, undo_edit, the debugger tools - fall back to an
// explicit "workspace" argument, then to the workspace last used for that
// kind of work, then to the active one.

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
func argPaths(args map[string]any) []string {
	var out []string
	add := func(v any) {
		if s, ok := v.(string); ok && filepath.IsAbs(s) {
			out = append(out, filepath.Clean(s))
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
		// No workspace: the file tools still work against the working
		// directory, and the LSP tools report that there is no Neovim.
		return session{Root: cwd(), Socket: os.Getenv("NVIM")}, nil
	}

	if want, ok := args["workspace"].(string); ok && strings.TrimSpace(want) != "" {
		ws := workspaceFor(realPath(absPath(want)))
		if ws == nil {
			return session{}, fmt.Errorf("no open workspace at %s (open: %s)",
				want, strings.Join(roots, ", "))
		}
		return ws.session(), nil
	}

	owners := map[string]*headlessWorkspace{}
	for _, p := range argPaths(args) {
		if ws := workspaceFor(realPath(p)); ws != nil {
			owners[ws.Root] = ws
		}
	}
	if len(owners) > 1 {
		var named []string
		for root := range owners {
			named = append(named, root)
		}
		return session{}, fmt.Errorf("this call names paths in %d workspaces (%s); "+
			"one call works in one workspace at a time",
			len(owners), strings.Join(named, ", "))
	}
	for _, ws := range owners {
		return ws.session(), nil
	}
	// Every path was relative, outside every workspace (a dependency under
	// ~/go/pkg/mod, a header in /usr/include), or there was none at all.
	if len(roots) == 1 {
		if ws := workspaceAt(roots[0]); ws != nil {
			return ws.session(), nil
		}
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
