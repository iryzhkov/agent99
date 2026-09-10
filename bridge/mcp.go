package main

// MCP stdio server exposing the tools. Speaks newline-delimited JSON-RPC on
// stdin/stdout. Two modes:
//
//   - embedded: $AGENT99_NVIM is set (the plugin spawned `claude -p` against
//     this server). Only the LSP tools are served; claude brings its own file
//     tools and the editor's buffers are the source of truth.
//   - standalone: no $AGENT99_NVIM (e.g. registered with `claude mcp add`).
//     Serves open_workspace/close_workspace, which run a headless Neovim in a
//     project root, plus the file tools (annotated grep, skim-on-large-read,
//     list_files). LSP tools error until a workspace is open, unless the
//     server inherited $NVIM from an enclosing :terminal.

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"
)

const (
	fallbackProtocolVersion = "2025-06-18"
	serverVersion           = "0.4.0"
)

// The revisions this server implements, newest first. It used to answer
// `initialize` with whatever version the client claimed, which is a promise
// it cannot keep: a client asking for a revision this does not speak was
// told it had it. The spec's rule is the other way round - answer with a
// version the server supports and let the client decide.
var supportedProtocolVersions = []string{"2025-06-18", "2025-03-26", "2024-11-05"}

func negotiateProtocolVersion(asked string) string {
	for _, v := range supportedProtocolVersions {
		if asked == v {
			return v
		}
	}
	return fallbackProtocolVersion
}

var workspaceTools = []tool{
	{
		Name: "open_workspace",
		Description: "Start a headless Neovim in the given project root and route tool calls " +
			"in that tree to it: its language servers back definition/references/hover/" +
			"diagnostics/symbol edits and the rest. Call this once per project before any " +
			"LSP tool. A root already open joins that instance instead of starting one, and " +
			"the reply says so (already_open, clients, shared): its buffers and language " +
			"servers are shared with the other clients using it, while your undo ledger, " +
			"your check_project and run_tests baselines and the diagnostics you have been " +
			"shown are your own. Several projects can be open at " +
			"once, as long as no root contains another and no other bridge process already " +
			"holds it; each call is routed to the workspace owning the path it names, as it " +
			"names it, so pass absolute paths (or workspace=<root>) once more than one is " +
			"open. With several open, a path no workspace holds is refused rather than served " +
			"from an arbitrary one. Symbol edits made through this server are saved to disk " +
			"at once.",
		InputSchema: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"root": map[string]any{"type": "string", "description": "Project root directory (absolute path)."},
			},
			"required": []string{"root"},
		},
	},
	{
		Name: "close_workspace",
		Description: "Stop a headless Neovim started by open_workspace, freeing its language " +
			"servers. With one workspace open the root is optional. A workspace other " +
			"clients are using is closed for them too - the reply names them under " +
			"was_shared - so close a root you opened rather than one you found open.",
		InputSchema: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"root": map[string]any{"type": "string", "description": "Root of the workspace to close."},
				"all":  map[string]any{"type": "boolean", "description": "Close every open workspace."},
			},
		},
	},
}

func embeddedMode() bool {
	return os.Getenv("AGENT99_NVIM") != ""
}

// openWorkspaceResult is what a client gets back for an opened workspace:
// where it is, and what its Neovim can actually serve.
func openWorkspaceResult(ws *headlessWorkspace, client string, wasOpen bool) map[string]any {
	ses := ws.session()
	ses.Client = client
	result := map[string]any{
		"root":   ws.Root,
		"socket": ws.Socket,
		"pid":    ws.cmd.Process.Pid,
	}
	// Reopening the same root is a no-op, and used to be reported as one:
	// the full first-time reply, with nothing saying the instance was
	// already there, whose it was, or that its buffers and language servers
	// are now shared. An agent reading that had no way to know it had
	// joined another agent's workspace.
	if wasOpen {
		result["already_open"] = true
	}
	if holders := holdersOf(ws.Root); len(holders) > 0 {
		result["clients"] = len(holders)
	}
	if note := sharedNote(ws.Root, client); note != "" {
		result["shared"] = note
	}
	// Tell the client up front which languages the instance can actually
	// serve, instead of letting symbol tools come back quietly empty.
	if support, err := nvimCall(ses, "workspace_support", map[string]any{"root": ws.Root}); err == nil {
		if m, ok := support.(map[string]any); ok {
			result["languages"] = m["languages"]
			if note, ok := m["note"].(string); ok && note != "" {
				result["note"] = note
			}
		}
	} else {
		result["note"] = "could not probe language support: " + err.Error()
	}
	// The tree is the check that the right project was opened and the hint
	// which subdirectory to map next; it costs one wc pass, so it is cheap
	// enough for every open.
	if tree, err := nvimCall(ses, "workspace_tree", map[string]any{"root": ws.Root}); err == nil {
		if m, ok := tree.(map[string]any); ok {
			result["tree"] = m["tree"]
			result["file_count"] = m["file_count"]
			result["line_count"] = m["line_count"]
			if note, ok := m["note"].(string); ok && note != "" {
				result["tree_note"] = note
			}
		}
	} else {
		result["tree_note"] = "could not build the workspace tree: " + err.Error()
	}
	// With more than one open, the roster is what the model needs in order
	// to address them; with one it would be noise.
	if roots := openRoots(); len(roots) > 1 {
		result["workspaces"] = roots
		result["routing"] = "calls are routed by the path they name, as they name it: pass an " +
			"absolute path, or workspace=<root>, when a call names none. With several open, a " +
			"path no workspace holds is refused rather than guessed at, and so is one that " +
			"leaves the root it was named under through a symlink"
	}
	return result
}

// Wording that is true inside a live editor but misleading for a headless
// workspace, where the server writes every edit to disk itself.
var standaloneDescriptionFixes = []struct{ from, to string }{
	{"Changes stay unsaved in editor buffers - inspect them with buffer_lines.",
		"Changes are saved to disk right away."},
	{"The edit is applied to the editor buffer immediately and is tracked (the user can revert).",
		"The edit is applied and saved to disk immediately."},
	{"Applied to the editor buffer immediately and tracked; returns fresh diagnostics.",
		"Applied and saved to disk immediately; returns fresh diagnostics."},
	{"Applied to the editor buffer immediately and tracked.",
		"Applied and saved to disk immediately."},
	{" Do not use this on the user's selected region; that region is changed only via the <replacement> reply.", ""},
	{"Use buffer_lines instead for files the user has open in the editor (they may have unsaved changes).",
		"In a headless workspace nothing is unsaved, so this is the normal way to read."},
}

func standaloneTools(tools []tool) []tool {
	out := make([]tool, 0, len(tools))
	for _, t := range tools {
		d := t.Description
		for _, f := range standaloneDescriptionFixes {
			d = strings.ReplaceAll(d, f.from, f.to)
		}
		t.Description = d
		if needsWorkspaceArg(t) {
			t.InputSchema = withWorkspaceArg(t.InputSchema)
		}
		out = append(out, t)
	}
	return out
}

// needsWorkspaceArg reports whether a tool takes an explicit workspace.
//
// It used to exclude any tool with a required path argument, on the reasoning
// that such a call routes itself. It does not: a relative path means "in the
// workspace this call is routed to", so argPaths leaves it out and the call is
// refused with advice to pass workspace= - a parameter skim, read_file,
// diagnostics, references, definition and replace_symbol_lines did not have.
// Those are the tools an agent calls most, and the friction arrived as a run
// of consecutive failures none of which could be followed. Every tool takes it
// now; an absolute path still wins, so nothing else changes.
func needsWorkspaceArg(t tool) bool {
	return t.Name != "open_workspace" && t.Name != "close_workspace"
}

// withWorkspaceArg returns the schema with a "workspace" property added. The
// tool literals are shared with the embedded server, which has no workspaces
// to speak of, so nothing is modified in place.
func withWorkspaceArg(schema map[string]any) map[string]any {
	props := map[string]any{
		"workspace": map[string]any{
			"type": "string",
			"description": "Root of the open workspace to run in. Only needed when several " +
				"are open and this call names no path inside one of them.",
		},
	}
	if existing, ok := schema["properties"].(map[string]any); ok {
		for k, v := range existing {
			props[k] = v
		}
	}
	out := map[string]any{}
	for k, v := range schema {
		out[k] = v
	}
	out["properties"] = props
	return out
}

// Tools kept out of the embedded (in-editor) schema but always advertised
// by the standalone server, where the headless instance is the one that may
// lack parsers and servers.
var standaloneOnly = map[string]bool{"install_language": true, "install_debugger": true}

func servedTools() []tool {
	full := os.Getenv("AGENT99_FULL_TOOLS") != ""
	tools := activeTools(lspTools, full)
	if debugEnabled() {
		for _, t := range debugTools {
			if embeddedMode() && standaloneOnly[t.Name] {
				continue
			}
			tools = append(tools, t)
		}
	}
	if embeddedMode() {
		return tools
	}
	out := append([]tool{}, workspaceTools...)
	out = append(out, tools...)
	if !full {
		for _, t := range lspTools {
			if standaloneOnly[t.Name] {
				out = append(out, t)
			}
		}
	}
	return standaloneTools(append(out, fileTools...))
}

func writeMsg(w *bufio.Writer, msg map[string]any) {
	data, err := json.Marshal(msg)
	if err != nil {
		return
	}
	w.Write(data)
	w.WriteByte('\n')
	w.Flush()
}

func textResult(text string, isError bool) map[string]any {
	return map[string]any{
		"content": []map[string]any{{"type": "text", "text": text}},
		"isError": isError,
	}
}

// renderJSON encodes a tool result for the model: readable but compact
// (one-space indent), and without HTML escaping - json.Marshal would turn
// every "<", ">" and "&" in a signature into a six-character \u escape,
// which on generic-heavy code (TypeScript, C++, Go) is pure token waste.
func renderJSON(v any) ([]byte, error) {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	enc.SetIndent("", " ")
	if err := enc.Encode(v); err != nil {
		return nil, err
	}
	return bytes.TrimRight(buf.Bytes(), "\n"), nil
}

func jsonResult(v any) map[string]any {
	pretty, err := renderJSON(v)
	if err != nil {
		return textResult(fmt.Sprintf("Error: %v", err), true)
	}
	return textResult(string(pretty), false)
}

func callMCPTool(name string, arguments map[string]any, client string) map[string]any {
	started := time.Now()
	res, root := dispatchMCPTool(name, arguments, client)
	logFriction(name, root, arguments, res, started)
	return res
}

// dispatchMCPTool runs one tool call and reports which workspace answered it,
// empty when the call failed before it was routed anywhere. The second return
// exists for the friction spool: where a call ran is part of reading it later.
func dispatchMCPTool(name string, arguments map[string]any, client string) (map[string]any, string) {
	if arguments == nil {
		arguments = map[string]any{}
	}
	switch name {
	case "open_workspace":
		if embeddedMode() {
			return textResult("Error: open_workspace is not available while embedded in Neovim", true), ""
		}
		root, _ := arguments["root"].(string)
		// Whether this call started the instance or joined one that was
		// already up, asked before opening: afterwards the two are
		// indistinguishable, which is how "reopening is a no-op" came to be
		// reported as a first-time open.
		wasOpen := root != "" && workspaceFor(realPath(absPath(root))) != nil
		ws, err := openWorkspace(root)
		if err != nil {
			return textResult("Error: "+err.Error(), true), ""
		}
		noteHolder(ws.Root, client)
		return jsonResult(openWorkspaceResult(ws, client, wasOpen)), ws.Root
	case "close_workspace":
		roots, err := closeTargets(arguments)
		if err != nil {
			return textResult("Error: "+err.Error(), true), ""
		}
		// Who else was using each root, read before it is closed: the
		// instance is gone by the time the reply is built, and a close that
		// takes another agent's buffers and language servers with it used to
		// say only "closed".
		shared := map[string][]string{}
		for _, root := range roots {
			if others := otherHolders(root, client); len(others) > 0 {
				labels := make([]string, 0, len(others))
				for _, id := range others {
					labels = append(labels, shortClient(id))
				}
				shared[root] = labels
			}
		}
		result := map[string]any{"closed": closeWorkspaces(roots)}
		if len(shared) > 0 {
			result["was_shared"] = shared
			result["was_shared_note"] = "these roots were in use by other clients as well, and " +
				"closing one closes it for them too: the Neovim, its buffers and its language " +
				"servers are gone, and their next call naming a path inside it is served " +
				"somewhere else"
		}
		if open := openRoots(); len(open) > 0 {
			result["workspaces"] = open
		}
		return jsonResult(result), ""
	}
	served := false
	for _, t := range servedTools() {
		if t.Name == name {
			served = true
			break
		}
	}
	// The slim roster hides some LSP tools from the schema but keeps them callable.
	if !served && !lspToolNames[name] {
		return textResult("Error: unknown tool: "+name, true), ""
	}
	if debugToolNames[name] && !debugEnabled() {
		return textResult("Error: the debugger tools are off; start the server with AGENT99_DEBUG=1 "+
			"(or setup({ debug = { enabled = true } }) in the plugin)", true), ""
	}
	ses, err := resolveSession(name, arguments)
	if err != nil {
		return textResult("Error: "+err.Error(), true), ""
	}
	ses.Client = client
	// A workspace opened for this call, or revived for it, is held by this
	// client as surely as one it opened by name.
	if ses.Headless {
		noteHolder(ses.Root, client)
	}
	// Busy from here until the reply, so the idle sweep cannot close the
	// workspace under a long call; touched again on the way out either way.
	beginCall(ses)
	defer endCall(ses)
	out, err := callTool(name, arguments, ses)
	if err != nil {
		return textResult("Error: "+err.Error(), true), ses.Root
	}
	if editTools[name] && ses.Headless {
		if err := headlessSaveAll(ses); err != nil {
			// The tool's own reply says the edit was saved, because in a
			// headless workspace it normally is. It was not, so this has
			// to come back as a failure rather than a footnote under a
			// success: nothing reached the disk.
			return textResult("Error: the edit was applied in the editor but not saved: "+
				err.Error()+"\n\nThe reply below describes an edit that is not on disk.\n\n"+out, true), ses.Root
		}
	}
	noteCall(name, ses)
	// Which workspace answered is only in question when several are open,
	// and then it is worth a line: a misrouted call is otherwise invisible.
	if len(openRoots()) > 1 {
		out = "workspace: " + ses.Root + "\n" + out
	}
	return textResult(out, false), ses.Root
}

func mcpHandle(method string, params map[string]any) (map[string]any, bool) {
	switch method {
	case "initialize":
		noteFrictionClient(params)
		asked, _ := params["protocolVersion"].(string)
		return map[string]any{
			"protocolVersion": negotiateProtocolVersion(asked),
			"capabilities":    map[string]any{"tools": map[string]any{}},
			"serverInfo":      map[string]any{"name": "agent99-lsp", "version": serverVersion},
		}, true
	case "server/discover":
		// Mandatory from the 2026-07-28 revision, and cheap: the versions
		// this server actually implements, plus what it can do.
		return map[string]any{
			"protocolVersions": supportedProtocolVersions,
			"capabilities":     map[string]any{"tools": map[string]any{}},
			"serverInfo":       map[string]any{"name": "agent99-lsp", "version": serverVersion},
		}, true
	case "ping":
		return map[string]any{}, true
	case "tools/list":
		return map[string]any{"tools": servedTools()}, true
	case "tools/call":
		name, _ := params["name"].(string)
		arguments, _ := params["arguments"].(map[string]any)
		// _meta is where a caller can say which agent it is speaking for
		// (client.go); with no such field the whole connection is one
		// client, which is what this process is.
		return callMCPTool(name, arguments, callClient(metaClient(params))), true
	}
	return nil, false
}

func runMCP() {
	defer closeAllWorkspaces()
	// Sockets left by bridges that are gone, and a sweep that gives back the
	// memory of a workspace nothing has touched for a while.
	sweepStaleSockets()
	startIdleReaper()
	// A client that terminates the server instead of closing stdin must not
	// leave a headless Neovim behind.
	sigs := make(chan os.Signal, 1)
	signal.Notify(sigs, syscall.SIGTERM, syscall.SIGINT, syscall.SIGHUP)
	go func() {
		<-sigs
		closeAllWorkspaces()
		os.Exit(0)
	}()
	scanner := bufio.NewScanner(os.Stdin)
	scanner.Buffer(make([]byte, 1024*1024), 16*1024*1024)
	out := bufio.NewWriter(os.Stdout)
	for scanner.Scan() {
		line := scanner.Bytes()
		if len(line) == 0 {
			continue
		}
		var msg map[string]any
		if err := json.Unmarshal(line, &msg); err != nil {
			continue
		}
		id, hasID := msg["id"]
		if !hasID {
			continue // notification
		}
		method, _ := msg["method"].(string)
		params, _ := msg["params"].(map[string]any)
		reply := map[string]any{"jsonrpc": "2.0", "id": id}
		if result, ok := mcpHandle(method, params); ok {
			reply["result"] = result
		} else {
			reply["error"] = map[string]any{
				"code":    -32601,
				"message": fmt.Sprintf("method not found: %s", method),
			}
		}
		writeMsg(out, reply)
	}
	// A request over the buffer cap ends Scan without an error on stdout;
	// the client would wait forever for a reply that never comes. Say so on
	// stderr, where the client shows it, and exit non-zero.
	if err := scanner.Err(); err != nil {
		fmt.Fprintf(os.Stderr, "agent99 mcp: reading stdin: %v\n", err)
		closeAllWorkspaces()
		os.Exit(1)
	}
}
