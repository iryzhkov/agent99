package main

// Transport into the running Neovim instance. Each tool call goes through
// the non-blocking start/poll protocol implemented by the agent99 plugin
// (lua/agent99/rpc.lua): Agent99RpcStart kicks the tool off in a coroutine
// and returns a request id; Agent99RpcPoll is polled until the JSON result
// is ready. Payloads travel base64-encoded so no shell or Vimscript
// escaping is needed.

import (
	"context"
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
	// Cap on one --remote-expr round trip. Generous, because a tool that
	// blocks the main loop briefly (a synchronous git or rg call in Lua)
	// must not be mistaken for a wedged instance; but bounded, so that a
	// wedged instance cannot hold the caller forever.
	remoteExprTimeout = 20 * time.Second
)

// Tools allowed to run longer than nvimTimeout: installs download and compile.
var toolTimeouts = map[string]time.Duration{
	"install_language": 15 * time.Minute,
	"install_debugger": 15 * time.Minute,
	"check_project":    10 * time.Minute,
	"run_tests":        15 * time.Minute,
	// Debugger tools that wait for the program: the Lua side clamps its
	// own wait to well under this so it always answers first.
	"debug_launch":   5 * time.Minute,
	"debug_attach":   5 * time.Minute,
	"debug_continue": 5 * time.Minute,
	"debug_step":     5 * time.Minute,
	"debug_wait":     5 * time.Minute,
	"debug_stop":     5 * time.Minute,
}

func remoteExpr(sock, expr string) (string, error) {
	// One round trip is bounded on its own. The tools that take minutes
	// run asynchronously behind Agent99RpcStart and are waited for by the
	// poll loop in nvimCall, so a single --remote-expr that does not come
	// back within this is an instance whose main loop is wedged, and
	// nothing that waited longer (nvimCall's deadline, stopWorkspace's
	// kill fallback, the signal handler) would ever have returned.
	ctx, cancel := context.WithTimeout(context.Background(), remoteExprTimeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, "nvim", "--server", sock, "--remote-expr", expr)
	var out, errb strings.Builder
	cmd.Stdout = &out
	cmd.Stderr = &errb
	if err := cmd.Run(); err != nil {
		if ctx.Err() != nil {
			// "Is the instance wedged?" names one cause and it is
			// usually the wrong one: a language server answering its
			// first request on a large project routinely takes longer
			// than this, and two of those timeouts in a row were
			// followed by a third call that answered normally. Say
			// what is known - no answer yet, the request is still
			// running - and leave the diagnosis to the retry.
			return "", fmt.Errorf("nvim RPC failed: no answer from %s within %s. The request "+
				"was not cancelled and is still running in that Neovim; a language server "+
				"answering its first request on a big project takes longer than this, so "+
				"retry before treating the instance as wedged",
				sock, remoteExprTimeout)
		}
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

// envSocket is the Neovim named by the environment: an explicit
// $AGENT99_NVIM wins (the plugin sets it when it spawns the bridge), then
// the $NVIM of an enclosing :terminal. A headless workspace opened through
// the MCP server takes precedence over both, and is picked per call by
// resolveSession (routing.go).
func envSocket() string {
	if sock := os.Getenv("AGENT99_NVIM"); sock != "" {
		return sock
	}
	return os.Getenv("NVIM")
}

// nvimCall runs one tool in the instance listening on sock.
func nvimCall(ses session, tool string, args map[string]any) (any, error) {
	sock := ses.Socket
	if sock == "" {
		return nil, errors.New("no Neovim to talk to: call open_workspace(root) first, " +
			"or launch the bridge with $AGENT99_NVIM (or $NVIM) pointing at a running Neovim")
	}
	// Which client the call is for travels with it: the editor keeps the
	// undo ledger, the two baselines and the set of diagnostics already
	// shown per (root, client), and without this they would be per root and
	// shared by every agent talking to this instance. Copied rather than
	// added to the caller's map, so nothing else sees a key it did not set.
	withClient := make(map[string]any, len(args)+1)
	for k, v := range args {
		withClient[k] = v
	}
	if _, ok := withClient["client"]; !ok && ses.Client != "" {
		withClient["client"] = ses.Client
	}
	args = withClient
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
