// agent99-bridge: the process side of the agent99 Neovim plugin.
//
// Two subcommands share the same tool set, which is backed by the LSP
// clients of a running Neovim instance (reached over --remote-expr, see
// nvim.go):
//
//	agent99-bridge agent   read a JSON payload on stdin, run an
//	                       OpenAI-compatible function-calling loop
//	                       (DeepSeek by default), print the final
//	                       answer on stdout
//	agent99-bridge mcp     serve the tools over the MCP stdio protocol,
//	                       for use with `claude -p --mcp-config`
//
// No dependencies outside the Go standard library.
package main

import (
	"encoding/json"
	"fmt"
	"os"
)

func main() {
	sub := ""
	if len(os.Args) > 1 {
		sub = os.Args[1]
	}
	switch sub {
	case "agent":
		runAgent()
	case "mcp":
		runMCP()
	case "tool":
		// Debug helper: run one tool directly, e.g.
		//   agent99-bridge tool grep '{"pattern":"foo"}'
		// Root is the working directory; $AGENT99_NVIM as usual.
		if len(os.Args) < 4 {
			fmt.Fprintln(os.Stderr, "usage: agent99-bridge tool <name> <json-args>")
			os.Exit(2)
		}
		var args map[string]any
		if err := json.Unmarshal([]byte(os.Args[3]), &args); err != nil {
			fmt.Fprintln(os.Stderr, "bad json args:", err)
			os.Exit(2)
		}
		cwd, _ := os.Getwd()
		out, err := callTool(os.Args[2], args, cwd)
		if err != nil {
			fmt.Fprintln(os.Stderr, "error:", err)
			os.Exit(1)
		}
		fmt.Println(out)
	default:
		fmt.Fprintln(os.Stderr, "usage: agent99-bridge <agent|mcp|tool>")
		os.Exit(2)
	}
}
