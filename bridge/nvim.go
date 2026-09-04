package main

// Transport into the running Neovim instance. Each tool call goes through
// the non-blocking start/poll protocol implemented by the agent99 plugin
// (lua/agent99/rpc.lua): Agent99RpcStart kicks the tool off in a coroutine
// and returns a request id; Agent99RpcPoll is polled until the JSON result
// is ready. Payloads travel base64-encoded so no shell or Vimscript
// escaping is needed.

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"time"
)

const (
	nvimTimeout  = 60 * time.Second
	pollInterval = 150 * time.Millisecond
)

// Tools allowed to run longer than nvimTimeout: installs download and compile.
var toolTimeouts = map[string]time.Duration{
	"install_language": 15 * time.Minute,
	"check_project":    10 * time.Minute,
}

func remoteExpr(sock, expr string) (string, error) {
	cmd := exec.Command("nvim", "--server", sock, "--remote-expr", expr)
	var out, errb strings.Builder
	cmd.Stdout = &out
	cmd.Stderr = &errb
	if err := cmd.Run(); err != nil {
		detail := strings.TrimSpace(errb.String())
		if detail == "" {
			detail = strings.TrimSpace(out.String())
		}
		if strings.Contains(detail, "Agent99Rpc") {
			detail += " (is the agent99 plugin on the runtimepath of that Neovim?)"
		}
		return "", fmt.Errorf("nvim RPC failed: %s", detail)
	}
	return out.String(), nil
}

// nvimSocket resolves the Neovim instance tools are routed to: an explicit
// $AGENT99_NVIM wins (the plugin sets it when it spawns the bridge), then
// a headless workspace opened through the MCP server, then the $NVIM of an
// enclosing :terminal.
func nvimSocket() string {
	if sock := os.Getenv("AGENT99_NVIM"); sock != "" {
		return sock
	}
	if sock := headlessSocket(); sock != "" {
		return sock
	}
	return os.Getenv("NVIM")
}

func nvimCall(tool string, args map[string]any) (any, error) {
	sock := nvimSocket()
	if sock == "" {
		return nil, errors.New("no Neovim to talk to: call open_workspace(root) first, " +
			"or launch the bridge with $AGENT99_NVIM (or $NVIM) pointing at a running Neovim")
	}
	if args == nil {
		args = map[string]any{}
	}
	payload, err := json.Marshal(map[string]any{"tool": tool, "args": args})
	if err != nil {
		return nil, err
	}
	b64 := base64.StdEncoding.EncodeToString(payload)
	id, err := remoteExpr(sock, fmt.Sprintf("v:lua.Agent99RpcStart('%s')", b64))
	if err != nil {
		return nil, err
	}
	id = strings.TrimSpace(id)
	timeout := nvimTimeout
	if t, ok := toolTimeouts[tool]; ok {
		timeout = t
	}
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		out, err := remoteExpr(sock, fmt.Sprintf("v:lua.Agent99RpcPoll('%s')", id))
		if err != nil {
			return nil, err
		}
		var resp struct {
			Pending bool   `json:"pending"`
			OK      bool   `json:"ok"`
			Result  any    `json:"result"`
			Error   string `json:"error"`
		}
		if err := json.Unmarshal([]byte(out), &resp); err != nil {
			return nil, fmt.Errorf("unparseable response from nvim: %v", err)
		}
		if resp.Pending {
			time.Sleep(pollInterval)
			continue
		}
		if !resp.OK {
			return nil, errors.New(resp.Error)
		}
		return resp.Result, nil
	}
	return nil, fmt.Errorf("timed out after %s waiting for the Neovim tool result", timeout)
}
