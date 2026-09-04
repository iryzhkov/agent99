//go:build linux

package main

import (
	"os/exec"
	"syscall"
)

// setDeathSignal makes the kernel terminate the headless Neovim if the
// bridge dies without cleaning up (e.g. SIGKILL from the MCP client).
func setDeathSignal(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{Pdeathsig: syscall.SIGTERM}
}
