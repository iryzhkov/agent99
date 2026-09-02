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

func nvimCall(tool string, args map[string]any) (any, error) {
	sock := os.Getenv("AGENT99_NVIM")
	if sock == "" {
		sock = os.Getenv("NVIM")
	}
	if sock == "" {
		return nil, errors.New("no Neovim socket: neither $AGENT99_NVIM nor $NVIM is set. " +
			"The bridge must be launched from (or pointed at) a running Neovim.")
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
	deadline := time.Now().Add(nvimTimeout)
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
	return nil, fmt.Errorf("timed out after %s waiting for the Neovim tool result", nvimTimeout)
}
