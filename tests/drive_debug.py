#!/usr/bin/env python3
"""Debugger tools against a real Delve session in the standalone server.

Runs on a scratch copy of tests/debugproj. Needs nvim-dap on the test
runtimepath (tests/smoke.sh clones it under tests/.deps) and dlv on PATH;
tests/smoke.sh installs the pinned Delve into a cache and skips this file
with a clear line when that fails.
"""

import os
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from drive_mcp import REPO, Bridge, check  # noqa: E402

DEBUGPROJ = os.path.join(REPO, "tests", "debugproj")

DEBUG_TOOLS = {
    "debug_launch", "debug_attach", "debug_breakpoint", "debug_breakpoints",
    "debug_continue", "debug_step", "debug_wait", "debug_stack",
    "debug_variables", "debug_evaluate", "debug_output", "debug_stop",
    "install_debugger",
}


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def pids_matching(marker):
    out = subprocess.run(["pgrep", "-f", marker], capture_output=True, text=True).stdout
    return [int(p) for p in out.split()]


def wait_gone(pids, seconds=10):
    deadline = time.time() + seconds
    while time.time() < deadline:
        if not any(os.path.exists("/proc/%d" % p) for p in pids):
            return True
        time.sleep(0.1)
    return False


def initialize(b):
    b.rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                         "clientInfo": {"name": "drive_debug", "version": "0"}})


def main():
    env = {k: v for k, v in os.environ.items() if k not in ("AGENT99_NVIM", "NVIM")}
    env["AGENT99_HEADLESS_INIT"] = os.path.join(REPO, "tests", "minimal_init.lua")
    work = tempfile.mkdtemp(prefix="agent99-debug-")
    root = os.path.join(work, "proj")
    shutil.copytree(DEBUGPROJ, root)
    main_go = os.path.join(root, "main.go")
    # A marker in argv so leaked debuggees can be found and counted.
    marker = "a99dbg-" + os.path.basename(work)

    # 1. Off by default: neither advertised nor callable.
    off = Bridge(env=env)
    initialize(off)
    tools = {t["name"] for t in off.rpc("tools/list")["result"]["tools"]}
    check("debug tools hidden without AGENT99_DEBUG", not (DEBUG_TOOLS & tools), tools)
    try:
        off.call("debug_wait", {"wait_ms": 0})
        check("debug tool refused without AGENT99_DEBUG", False, "call succeeded")
    except RuntimeError as e:
        check("debug tool refused without AGENT99_DEBUG", "AGENT99_DEBUG" in str(e), e)
    off.close()

    env["AGENT99_DEBUG"] = "1"
    b = Bridge(env=env)
    srv = None
    try:
        initialize(b)
        tools = {t["name"] for t in b.rpc("tools/list")["result"]["tools"]}
        check("debug roster", DEBUG_TOOLS <= tools, DEBUG_TOOLS - tools)

        res = b.call("open_workspace", {"root": root})
        langs = {l["filetype"]: l for l in res.get("languages", [])}
        check("open_workspace names the debugger",
              "delve" in langs.get("go", {}).get("debugger", ""), langs)

        try:
            b.call("debug_step", {})
            check("no session -> launch hint", False, "call succeeded")
        except RuntimeError as e:
            check("no session -> launch hint", "debug_launch" in str(e), e)

        # 2. A breakpoint by name path before any session exists.
        res = b.call("debug_breakpoint", {"file": main_go, "name_path": "accumulate", "offset": 4})
        check("breakpoint by name_path resolves the line",
              res.get("line") == 14 and "total +=" in res.get("text", ""), res)

        # 3. Launch stops there, with the symbol annotated and output captured.
        res = b.call("debug_launch", {
            "file": main_go, "args": [marker], "track": ["i", "total*2", "nosuch"],
        })
        check("launch stops at the breakpoint",
              res.get("state") == "stopped" and res.get("reason") == "breakpoint"
              and res.get("frame", {}).get("line") == 14, res)
        check("stop reply names the symbol",
              res.get("frame", {}).get("symbol") == "accumulate"
              and res.get("frame", {}).get("file") == "main.go", res)
        check("launch reply verifies the breakpoint",
              any(bp.get("verified") is True and bp.get("line") == 14
                  for bp in res.get("breakpoints", [])), res)
        check("stop reply carries program output",
              any("debugproj: start" in l for l in res.get("output_new") or []), res)
        check("stop reply has source window and stack",
              any(l.startswith("14: >") for l in res.get("source", []))
              and res.get("stack", [""])[0].startswith("#0 main.accumulate main.go:14"), res)
        tracked = res.get("tracked") or []
        check("tracked expressions",
              len(tracked) == 3 and tracked[0] == "i = 0" and tracked[1] == "total*2 = 0"
              and tracked[2].endswith("<not in scope>"), tracked)
        check("locals in summary mode",
              any(l.startswith("total: int = 0") for l in res.get("locals", [])), res)

        # 4. Stepping, variables, evaluate.
        res = b.call("debug_step", {"action": "over", "count": 2})
        check("step over twice", res.get("state") == "stopped" and res.get("reason") == "step", res)
        res = b.call("debug_variables", {})
        check("debug_variables shows the changed local",
              any(l.startswith("total: int = 1") for l in res.get("variables", [])), res)
        res = b.call("debug_evaluate", {"expression": "total + 41"})
        check("debug_evaluate", res.get("result") == "42", res)
        res = b.call("debug_stack", {"all_frames": True})
        check("debug_stack lists external frames when asked",
              len(res.get("frames", [])) >= 3 and "runtime.main" in "\n".join(res["frames"]), res)
        res = b.call("debug_stack", {})
        check("debug_stack collapses external frames",
              any("<external" in f for f in res.get("frames", [])), res)

        # 6. Editing while stopped is reported on the next stop.
        res = b.call("replace_symbol_lines", {
            "file": main_go, "name_path": "worker", "first_line": 2, "last_line": 2,
            "text": "\ttime.Sleep(11 * time.Millisecond)",
        })
        res = b.call("debug_continue", {})
        check("continue hits the loop breakpoint again", res.get("state") == "stopped", res)
        check("stale_source after an edit", res.get("stale_source") == ["main.go"], res)

        # 5. Run to exit: exit code and stderr line.
        res = b.call("debug_breakpoints", {"clear": True})
        check("clear breakpoints", res.get("cleared") == 1, res)
        res = b.call("debug_continue", {})
        check("continue to exit",
              res.get("state") == "exited" and res.get("exit_code") == 3, res)
        check("exit reply has the stderr line",
              any("stderr line" in l for l in res.get("output_new") or []), res)
        try:
            b.call("debug_step", {})
            check("after exit the session is gone", False, "call succeeded")
        except RuntimeError as e:
            check("after exit the session is gone", "no debug session" in str(e), e)
        res = b.call("debug_output", {"grep": "sum"})
        check("debug_output survives the exit",
              any("sum 14" in l for l in res.get("lines", [])), res)

        # Relaunch with no arguments: the fresh binary, no stale warning,
        # names-only variables.
        b.call("debug_breakpoint", {"file": main_go, "line": 14})
        res = b.call("debug_launch", {"variables": "names"})
        check("relaunch with no arguments",
              res.get("state") == "stopped" and res.get("stale_source") is None, res)
        check("variables=names", any(l == "total: int" for l in res.get("locals", [])), res)
        res = b.call("debug_breakpoint", {"file": main_go, "line": 14, "remove": True})
        check("remove a breakpoint", res.get("removed") is True, res)
        res = b.call("debug_continue", {"to": {"file": main_go, "name_path": "main", "offset": 6}})
        check("run to line", res.get("state") == "stopped"
              and res.get("frame", {}).get("line") == 29, res)
        res = b.call("debug_stop", {})
        check("debug_stop", res.get("stopped") is True, res)
        check("stop leaves no debuggee", wait_gone(pids_matching(marker), 5), pids_matching(marker))

        # 9. Timeout: a sleeping program is "running", pause_after stops it.
        res = b.call("debug_launch", {"file": main_go, "args": ["sleep", marker], "wait_ms": 1500})
        check("launch times out as running", res.get("state") == "running", res)
        res = b.call("debug_wait", {"wait_ms": 500, "pause_after": True})
        check("debug_wait pause_after",
              res.get("state") == "stopped" and res.get("reason") == "pause", res)
        res = b.call("debug_stop", {})
        check("stop after pause", res.get("stopped") is True, res)

        # 7. Attach to a headless Delve server; disconnect leaves it running.
        subprocess.run(["go", "build", "-gcflags=all=-N -l", "-o", "debugproj-bin", "."],
                       cwd=root, check=True)
        port = free_port()
        srv = subprocess.Popen(
            ["dlv", "exec", "--headless", "--accept-multiclient",
             "--listen", "127.0.0.1:%d" % port, "./debugproj-bin", "--", "sleep", marker],
            cwd=root, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        b.call("debug_breakpoint", {"file": main_go, "line": 14})
        res = None
        for _ in range(20):
            try:
                res = b.call("debug_attach", {"host": "127.0.0.1", "port": port, "file": main_go})
                break
            except RuntimeError as e:
                last = e
                time.sleep(0.5)
        check("attach to a debug server",
              res is not None and res.get("state") == "stopped"
              and res.get("request") == "attach", res or last)
        res = b.call("debug_stop", {})
        time.sleep(0.5)
        debuggee = pids_matching("debugproj-bin sleep " + marker)
        check("disconnect leaves the attached process alive", len(debuggee) >= 1, debuggee)
        srv.kill()
        for p in debuggee:
            try:
                os.kill(p, signal.SIGKILL)
            except OSError:
                pass

        scope = open("/proc/sys/kernel/yama/ptrace_scope").read().strip()
        if scope != "0":
            victim = subprocess.Popen([os.path.join(root, "debugproj-bin"), "sleep", marker],
                                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            try:
                b.call("debug_attach", {"pid": victim.pid, "file": main_go})
                check("attach by pid names ptrace_scope", False, "call succeeded")
            except RuntimeError as e:
                check("attach by pid names ptrace_scope",
                      "ptrace" in str(e) and "dlv exec --headless" in str(e), e)
            victim.kill()

        # 8. Leak: a live session must not survive close_workspace.
        res = b.call("debug_launch", {"file": main_go, "args": ["sleep", marker], "wait_ms": 1000})
        check("launch for the leak test", res.get("state") == "running", res)
        leaked = pids_matching(marker)
        check("debuggee is running before close", len(leaked) >= 1, leaked)
        b.call("close_workspace", {})
        check("close_workspace ends the debuggee", wait_gone(leaked, 10), pids_matching(marker))

        # ... nor a SIGKILL of the bridge.
        res = b.call("open_workspace", {"root": root})
        nvim_pid = res["pid"]
        res = b.call("debug_launch", {"file": main_go, "args": ["sleep", marker], "wait_ms": 1000})
        leaked = pids_matching(marker)
        check("debuggee is running before SIGKILL", len(leaked) >= 1, leaked)
        b.proc.kill()
        check("nvim dies with the server", wait_gone([nvim_pid], 10), nvim_pid)
        check("SIGKILL of the bridge ends the debuggee", wait_gone(leaked, 10), pids_matching(marker))
    finally:
        try:
            b.proc.kill()
        except Exception:
            pass
        if srv is not None:
            try:
                srv.kill()
            except Exception:
                pass
        for p in pids_matching(marker):
            try:
                os.kill(p, signal.SIGKILL)
            except OSError:
                pass
        shutil.rmtree(work, ignore_errors=True)
    print("debug: OK")


if __name__ == "__main__":
    main()
