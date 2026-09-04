#!/usr/bin/env python3
"""Smoke test for the standalone MCP server: no $AGENT99_NVIM, the bridge
starts its own headless Neovim through open_workspace and routes the LSP
and file tools to it. Runs on a scratch copy of tests/testproj because
headless edits are written to disk.

Run through tests/smoke.sh (which sets AGENT99_HEADLESS_INIT so the
instance uses the minimal config, not the user's).
"""

import os
import shutil
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from drive_mcp import REPO, PROJ, Bridge, check  # noqa: E402


def main():
    env = {k: v for k, v in os.environ.items() if k not in ("AGENT99_NVIM", "NVIM")}
    env["AGENT99_HEADLESS_INIT"] = os.path.join(REPO, "tests", "minimal_init.lua")
    work = tempfile.mkdtemp(prefix="agent99-headless-")
    root = os.path.join(work, "proj")
    shutil.copytree(PROJ, root)
    main_lua = os.path.join(root, "lua", "testproj", "main.lua")
    util = os.path.join(root, "lua", "testproj", "util.lua")

    b = Bridge(env=env)
    try:
        b.rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                             "clientInfo": {"name": "drive_headless", "version": "0"}})
        tools = {t["name"] for t in b.rpc("tools/list")["result"]["tools"]}
        check("standalone roster",
              {"open_workspace", "close_workspace", "grep", "read_file",
               "list_files", "definition", "install_language"} <= tools, tools)

        # LSP tools must fail cleanly before a workspace exists.
        try:
            b.call("definition", {"file": main_lua, "line": 4, "symbol": "greet"})
            check("no workspace -> error", False, "call succeeded")
        except RuntimeError as e:
            check("no workspace -> error", "open_workspace" in str(e), e)

        try:
            b.call("open_workspace", {"root": os.path.join(work, "missing")})
            check("bad root -> error", False, "call succeeded")
        except RuntimeError as e:
            check("bad root -> error", "workspace root" in str(e), e)

        # A root-level file of a language nothing in the minimal config can
        # serve, and a binary blob: the map must flag both instead of
        # pretending they are fine.
        with open(os.path.join(root, "tool.zig"), "w") as f:
            f.write("pub fn main() void {}\n")
        with open(os.path.join(root, "blob.bin"), "wb") as f:
            f.write(b"\x00\x01" * 64)

        res = b.call("open_workspace", {"root": root})
        check("open_workspace", res.get("root") == os.path.realpath(root)
              and os.path.exists(res.get("socket", "")), res)
        pid = res["pid"]
        langs = {l["filetype"]: l for l in res.get("languages", [])}
        check("open_workspace reports languages",
              "lua" in langs and langs.get("zig", {}).get("treesitter_parser") is False
              and "zig" in (res.get("note") or ""), res)

        again = b.call("open_workspace", {"root": root})
        check("reopen is a no-op", again.get("pid") == pid, again)

        locs = []
        for _ in range(15):
            res = b.call("definition", {"file": main_lua, "line": 4, "symbol": "greet"})
            locs = res.get("locations", [])
            if locs:
                break
            time.sleep(1)
        check("definition via headless",
              len(locs) == 1 and locs[0]["file"].endswith("util.lua"), res)

        # workspace_map: "**/*.x" also matches root-level files, binaries are
        # skipped, and a missing parser is called out.
        res = b.call("workspace_map", {"glob": "**/*.zig"})
        check("workspace_map glob matches root files",
              [f["file"] for f in res.get("files", [])] == ["tool.zig"]
              and "zig" in (res.get("note") or ""), res)
        res = b.call("workspace_map", {})
        blob = [f for f in res.get("files", []) if f["file"] == "blob.bin"]
        check("workspace_map skips binaries",
              blob and blob[0].get("skipped") == "binary", res)

        # Edits in a headless workspace must not claim to be unsaved.
        res = b.call("replace_symbol_lines", {
            "file": util, "name_path": "M.greet", "first_line": 2, "last_line": 2,
            "text": '    return "hello, " .. tostring(name)',
        })
        check("headless edit note says saved",
              "saved" in res.get("note", "") and "diagnostics_after" in res, res)
        # tostring(name) is fine: nothing new; the file's unused-local hint
        # is below WARN and must not be reported either.
        check("post-edit reports nothing new",
              res.get("diagnostics_after") == "no new errors or warnings", res)
        # An edit that plants an undefined global is reported as new; the
        # next edit elsewhere sees it as pre-existing rather than new again.
        res = b.call("replace_symbol_lines", {
            "file": util, "name_path": "M.greet", "first_line": 2, "last_line": 2,
            "text": '    return "hello, " .. nme',
        })
        check("post-edit reports the new error",
              isinstance(res.get("diagnostics_after"), list)
              and any("nme" in d for d in res["diagnostics_after"]), res)
        res = b.call("replace_symbol_lines", {
            "file": util, "name_path": "M.shout", "first_line": 2, "last_line": 2,
            "text": '    return string.upper(M.greet(name))',
        })
        check("post-edit separates pre-existing",
              res.get("diagnostics_after") == "no new errors or warnings"
              and "1 warnings" in res.get("preexisting", ""), res)
        res = b.call("replace_symbol_lines", {
            "file": util, "name_path": "M.greet", "first_line": 2, "last_line": 2,
            "text": '    return "hello, " .. tostring(name)',
        })
        check("post-edit reports fixed",
              "1 diagnostics" in res.get("fixed", ""), res)

        # undo_edit takes back the newest edit, saves, and refuses to go
        # past a region that changed since.
        res = b.call("insert_after_symbol", {
            "file": util, "name_path": "M.shout", "text": "function M.extra() return 1 end",
        })
        res = b.call("undo_edit", {})
        with open(util) as f:
            on_disk = f.read()
        check("undo_edit removes the insert",
              len(res.get("undone", [])) == 1 and "M.extra" not in on_disk
              and res.get("undone")[0].get("removed_lines"), res)
        check("undo_edit keeps older edits", res.get("remaining", 0) >= 1, res)
        res = b.call("undo_edit", {"all": True})
        with open(util) as f:
            on_disk = f.read()
        check("undo_edit all restores the file",
              res.get("remaining") == 0 and "tostring" not in on_disk
              and '.. "!"' not in on_disk, res)
        res = b.call("undo_edit", {})
        check("undo_edit with empty ledger explains",
              res.get("undone") == [] and "no symbol edits" in res.get("note", ""), res)

        # rename_symbol: dry run touches nothing, the real one reaches the
        # caller in main.lua, undo restores both files.
        res = b.call("rename_symbol", {"file": util, "line": 6, "symbol": "greet",
                                       "new_name": "hello", "dry_run": True})
        # (lua_ls renames the declaration and the in-file caller; whether
        # it reaches main.lua depends on its workspace indexing, so the
        # check stays within util.lua.)
        check("rename dry_run lists files",
              res.get("dry_run") is True and res.get("total_edits", 0) >= 2
              and any(f["file"].endswith("util.lua") for f in res.get("files", [])), res)
        with open(util) as f:
            check("rename dry_run changed nothing", "M.greet(name)" in f.read(), res)
        res = b.call("rename_symbol", {"file": util, "line": 6, "symbol": "greet",
                                       "new_name": "hello"})
        with open(util) as f:
            util_text = f.read()
        check("rename applied",
              res.get("renamed_to") == "hello" and "M.hello(name)" in util_text
              and "M.greet" not in util_text, res)
        res = b.call("undo_edit", {"all": True})
        with open(util) as f:
            util_text = f.read()
        check("rename undone", "M.greet(name)" in util_text and res.get("remaining") == 0, res)

        # check_project: first run records a baseline, later runs of the
        # same command diff against it (the command reads a file we change).
        probe = os.path.join(work, "probe.txt")
        with open(probe, "w") as f:
            f.write("one\ntwo\n")
        cmd = "cat " + probe
        res = b.call("check_project", {"command": cmd})
        check("check_project baseline", res.get("output") == ["one", "two"]
              and "recorded" in res.get("baseline", ""), res)
        with open(probe, "w") as f:
            f.write("one\nthree\n")
        res = b.call("check_project", {"command": cmd})
        check("check_project diff", res.get("new") == ["three"] and res.get("resolved") == 1, res)
        res = b.call("check_project", {"command": cmd, "reset": True})
        check("check_project reset", "recorded" in res.get("baseline", ""), res)

        # References come grouped by file with paths relative to the root.
        res = b.call("references", {"file": util, "line": 6, "symbol": "greet"})
        files = res.get("files", [])
        check("references grouped and relative",
              res.get("count", 0) >= 2 and files
              and all(not f["file"].startswith("/") for f in files)
              and all("hits" in f for f in files), res)

        # The map leaves test files out unless asked.
        res = b.call("workspace_map", {})
        check("workspace_map hides tests by default",
              not any("/tests/" in f["file"] or f["file"].startswith("tests/")
                      for f in res.get("files", [])) or "test files left out" in (res.get("note") or ""), res)

        # Relative paths resolve against the workspace root, not the bridge's cwd.
        res = b.call("find_symbol", {"file": "lua/testproj/util.lua", "name": "M.greet"})
        check("relative path resolves in root", res.get("count") == 1, res)

        # File tools run in-process, rooted at the workspace.
        reply = b.rpc("tools/call", {"name": "grep", "arguments": {"pattern": "M.greet"}})
        text = reply["result"]["content"][0]["text"]
        check("grep annotated", "util.lua:" in text and "[M.greet" in text, text)
        # A single-file target keeps the filename, so hits stay annotated.
        reply = b.rpc("tools/call", {"name": "grep", "arguments": {
            "pattern": "M.greet", "path": "lua/testproj/util.lua", "context": 0}})
        text = reply["result"]["content"][0]["text"]
        check("single-file grep annotated", "util.lua:" in text and "[M.greet" in text, text)

        # install_language under the minimal config has neither nvim-treesitter
        # nor Mason: it must say so per step instead of failing outright.
        res = b.call("install_language", {"language": "zig"})
        check("install_language reports missing installers",
              res.get("language") == "zig"
              and res.get("parser", {}).get("status") == "skipped"
              and res.get("server", {}).get("status") == "skipped", res)
        try:
            b.call("install_language", {})
            check("install_language needs language", False, "call succeeded")
        except RuntimeError as e:
            check("install_language needs language", "language" in str(e), e)

        # Symbol edits reach disk without anyone saving.
        res = b.call("replace_symbol_body", {
            "file": util, "name_path": "M.shout",
            "body": 'function M.shout(name)\n    return string.upper(M.greet(name)) .. "!"\nend',
        })
        check("replace_symbol_body", res.get("replaced") == "M.shout", res)
        on_disk = ""
        for _ in range(20):
            with open(util) as f:
                on_disk = f.read()
            if '.. "!"' in on_disk:
                break
            time.sleep(0.1)
        check("edit autosaved to disk", '.. "!"' in on_disk, on_disk)

        res = b.call("close_workspace", {})
        check("close_workspace", res.get("closed") is True, res)
        for _ in range(30):
            if not os.path.exists("/proc/%d" % pid):
                break
            time.sleep(0.1)
        check("nvim stopped", not os.path.exists("/proc/%d" % pid), pid)

        # Reopen, then let the server exit: the instance must die with it.
        res = b.call("open_workspace", {"root": root})
        pid = res["pid"]
        b.close()
        for _ in range(50):
            if not os.path.exists("/proc/%d" % pid):
                break
            time.sleep(0.1)
        check("nvim dies with the server", not os.path.exists("/proc/%d" % pid), pid)
    finally:
        try:
            b.proc.kill()
        except Exception:
            pass
        shutil.rmtree(work, ignore_errors=True)
    print("headless: OK")


if __name__ == "__main__":
    main()
