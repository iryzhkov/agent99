package main

// MCP stdio server exposing the Neovim LSP tools, for the claude provider
// (`claude -p --mcp-config`). Speaks newline-delimited JSON-RPC on
// stdin/stdout. Only the LSP tools are served: claude brings its own file
// tools.

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
)

const fallbackProtocolVersion = "2025-06-18"

func writeMsg(w *bufio.Writer, msg map[string]any) {
	data, err := json.Marshal(msg)
	if err != nil {
		return
	}
	w.Write(data)
	w.WriteByte('\n')
	w.Flush()
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
			"serverInfo":      map[string]any{"name": "agent99-lsp", "version": "0.3.0"},
		}, true
	case "ping":
		return map[string]any{}, true
	case "tools/list":
		full := os.Getenv("AGENT99_FULL_TOOLS") != ""
		return map[string]any{"tools": activeTools(lspTools, full)}, true
	case "tools/call":
		name, _ := params["name"].(string)
		arguments, _ := params["arguments"].(map[string]any)
		if name == "ts_query" || name == "find_symbol" || name == "workspace_map" {
			if arguments == nil {
				arguments = map[string]any{}
			}
			if arguments["root"] == nil {
				// The MCP server runs with the project as its working directory.
				if cwd, err := os.Getwd(); err == nil {
					arguments["root"] = cwd
				}
			}
		}
		text := ""
		isError := false
		if !lspToolNames[name] {
			text = fmt.Sprintf("Error: unknown tool: %s", name)
			isError = true
		} else if result, err := nvimCall(name, arguments); err != nil {
			text = fmt.Sprintf("Error: %v", err)
			isError = true
		} else if pretty, err := json.MarshalIndent(result, "", "  "); err != nil {
			text = fmt.Sprintf("Error: %v", err)
			isError = true
		} else {
			text = string(pretty)
		}
		return map[string]any{
			"content": []map[string]any{{"type": "text", "text": text}},
			"isError": isError,
		}, true
	}
	return nil, false
}

func runMCP() {
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
