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
)

const fallbackProtocolVersion = "2025-06-18"

var workspaceTools = []tool{
	{
		Name: "open_workspace",
		Description: "Start a headless Neovim in the given project root and route every " +
			"other tool to it: its language servers back definition/references/hover/" +
			"diagnostics/symbol edits and the rest. Call this once before any LSP tool. " +
			"Reopening the same root is a no-op; a different root replaces the instance. " +
			"Symbol edits made through this server are saved to disk at once.",
		InputSchema: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"root": map[string]any{"type": "string", "description": "Project root directory (absolute path)."},
			},
			"required": []string{"root"},
		},
	},
	{
		Name:        "close_workspace",
		Description: "Stop the headless Neovim started by open_workspace.",
		InputSchema: map[string]any{
			"type":       "object",
			"properties": map[string]any{},
		},
	},
}

func embeddedMode() bool {
	return os.Getenv("AGENT99_NVIM") != ""
}

// toolRoot is the project root file paths are resolved against: the open
// headless workspace, else the server's working directory (the plugin runs
// the embedded server in the project).
func toolRoot() string {
	if root := headlessRoot(); root != "" {
		return root
	}
	if cwd, err := os.Getwd(); err == nil {
		return cwd
	}
	return "."
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
		out = append(out, t)
	}
	return out
}

// Tools kept out of the embedded (in-editor) schema but always advertised
// by the standalone server, where the headless instance is the one that may
// lack parsers and servers.
var standaloneOnly = map[string]bool{"install_language": true}

func servedTools() []tool {
	full := os.Getenv("AGENT99_FULL_TOOLS") != ""
	tools := activeTools(lspTools, full)
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

func callMCPTool(name string, arguments map[string]any) map[string]any {
	if arguments == nil {
		arguments = map[string]any{}
	}
	switch name {
	case "open_workspace":
		if embeddedMode() {
			return textResult("Error: open_workspace is not available while embedded in Neovim", true)
		}
		root, _ := arguments["root"].(string)
		ws, err := openWorkspace(root)
		if err != nil {
			return textResult("Error: "+err.Error(), true)
		}
		result := map[string]any{
			"root":   ws.Root,
			"socket": ws.Socket,
			"pid":    ws.cmd.Process.Pid,
		}
		// Tell the client up front which languages the instance can actually
		// serve, instead of letting symbol tools come back quietly empty.
		if support, err := nvimCall("workspace_support", map[string]any{"root": ws.Root}); err == nil {
			if m, ok := support.(map[string]any); ok {
				result["languages"] = m["languages"]
				if note, ok := m["note"].(string); ok && note != "" {
					result["note"] = note
				}
			}
		} else {
			result["note"] = "could not probe language support: " + err.Error()
		}
		return jsonResult(result)
	case "close_workspace":
		return jsonResult(map[string]any{"closed": closeWorkspace()})
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
		return textResult("Error: unknown tool: "+name, true)
	}
	out, err := callTool(name, arguments, toolRoot())
	if err != nil {
		return textResult("Error: "+err.Error(), true)
	}
	if editTools[name] && !embeddedMode() {
		if err := headlessSaveAll(); err != nil {
			// The tool's own reply says the edit was saved, because in a
			// headless workspace it normally is. It was not, so this has
			// to come back as a failure rather than a footnote under a
			// success: nothing reached the disk.
			return textResult("Error: the edit was applied in the editor but not saved: "+
				err.Error()+"\n\nThe reply below describes an edit that is not on disk.\n\n"+out, true)
		}
	}
	return textResult(out, false)
}

func mcpHandle(method string, params map[string]any) (map[string]any, bool) {
	switch method {
	case "initialize":
		version := fallbackProtocolVersion
		if v, ok := params["protocolVersion"].(string); ok && v != "" {
			version = v
		}
		return map[string]any{
			"protocolVersion": version,
			"capabilities":    map[string]any{"tools": map[string]any{}},
			"serverInfo":      map[string]any{"name": "agent99-lsp", "version": "0.4.0"},
		}, true
	case "ping":
		return map[string]any{}, true
	case "tools/list":
		return map[string]any{"tools": servedTools()}, true
	case "tools/call":
		name, _ := params["name"].(string)
		arguments, _ := params["arguments"].(map[string]any)
		return callMCPTool(name, arguments), true
	}
	return nil, false
}

func runMCP() {
	defer closeWorkspace()
	// A client that terminates the server instead of closing stdin must not
	// leave the headless Neovim behind.
	sigs := make(chan os.Signal, 1)
	signal.Notify(sigs, syscall.SIGTERM, syscall.SIGINT, syscall.SIGHUP)
	go func() {
		<-sigs
		closeWorkspace()
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
}
