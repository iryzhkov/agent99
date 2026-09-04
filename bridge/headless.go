package main

// Headless workspace for the standalone MCP server. When the bridge is not
// launched from inside Neovim (no $AGENT99_NVIM), a client such as Claude
// Code first calls open_workspace(root): the bridge spawns
// `nvim --headless --listen <socket>` in that root with the user's normal
// configuration, so the same LSP servers attach as in an interactive
// session, and every later tool call is routed to that instance. The
// instance is killed when the workspace is closed or the server exits.

import (
	"crypto/sha1"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

const (
	headlessStartTimeout = 20 * time.Second
	headlessStopTimeout  = 3 * time.Second
)

type headlessWorkspace struct {
	Root   string
	Socket string
	cmd    *exec.Cmd
	stderr *tailBuffer
	done   chan struct{}
}

var (
	headlessMu sync.Mutex
	headless   *headlessWorkspace
)

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

// headlessSocket returns the socket of the open headless workspace, or "".
func headlessSocket() string {
	headlessMu.Lock()
	defer headlessMu.Unlock()
	if headless == nil {
		return ""
	}
	select {
	case <-headless.done:
		return "" // the instance died underneath us
	default:
		return headless.Socket
	}
}

// headlessRoot returns the root of the open headless workspace, or "".
func headlessRoot() string {
	headlessMu.Lock()
	defer headlessMu.Unlock()
	if headless == nil {
		return ""
	}
	return headless.Root
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

// openWorkspace starts (or reuses) a headless Neovim rooted at root. Opening
// a different root replaces the previous instance: the server drives one
// workspace at a time.
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

	headlessMu.Lock()
	defer headlessMu.Unlock()
	if headless != nil && headless.Root == abs {
		select {
		case <-headless.done:
			// died; fall through and restart
		default:
			if nvimAlive(headless.Socket) {
				return headless, nil
			}
		}
	}
	stopLocked()

	dir, err := socketDir()
	if err != nil {
		return nil, err
	}
	sum := sha1.Sum([]byte(abs))
	sock := filepath.Join(dir, fmt.Sprintf("%s-%d.sock", hex.EncodeToString(sum[:6]), os.Getpid()))
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
	ws := &headlessWorkspace{Root: abs, Socket: sock, cmd: cmd, stderr: tail, done: make(chan struct{})}
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
			headless = ws
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

// closeWorkspace stops the headless instance, if any. Returns whether one
// was running.
func closeWorkspace() bool {
	headlessMu.Lock()
	defer headlessMu.Unlock()
	return stopLocked()
}

func stopLocked() bool {
	ws := headless
	headless = nil
	if ws == nil {
		return false
	}
	select {
	case <-ws.done:
		os.Remove(ws.Socket)
		return true
	default:
	}
	// Ask nicely so buffers and LSP clients shut down, then force it.
	remoteExpr(ws.Socket, "execute('qa!')")
	select {
	case <-ws.done:
	case <-time.After(headlessStopTimeout):
		ws.cmd.Process.Kill()
		<-ws.done
	}
	os.Remove(ws.Socket)
	return true
}

// Edits made by the symbol tools land in buffers; with no user at the
// keyboard they must reach disk on their own, otherwise a client reading
// files directly would see stale content. (BufModifiedSet does not fire for
// API edits to hidden buffers, so an autocmd cannot do this.)
var editTools = map[string]bool{
	"replace_symbol_body":  true,
	"replace_symbol_lines": true,
	"insert_after_symbol":  true,
	"insert_before_symbol": true,
	"apply_code_action":    true,
	"undo_edit":            true,
	"rename_symbol":        true,
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
func headlessSaveAll() error {
	sock := headlessSocket()
	if sock == "" {
		return nil
	}
	out, err := remoteExpr(sock, "luaeval('"+headlessSaveLua+"')")
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
