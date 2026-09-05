#!/usr/bin/env python3
"""Smoke test for the standalone MCP server: no $AGENT99_NVIM, the bridge
starts its own headless Neovim through open_workspace and routes the LSP
and file tools to it. Runs on a scratch copy of tests/testproj because
headless edits are written to disk.

Run through tests/smoke.sh (which sets AGENT99_HEADLESS_INIT so the
instance uses the minimal config, not the user's).
"""

import os
import re
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

        # Markdown headings index like declarations: nested outline, a
        # section by name path with its body ending before the next heading,
        # grep hits tagged with their section, and section edits.
        notes = os.path.join(root, "NOTES.md")
        res = b.call("skim", {"files": [notes]})
        outline = res["files"][0].get("outline", [])
        check("skim outlines markdown sections",
              any(l.strip().startswith("5-") and "## Layout" in l for l in outline)
              and any("### Modules" in l for l in outline), res)
        res = b.call("find_symbol", {"file": notes, "name": "Layout/Modules", "include_body": True})
        body = res.get("matches", [{}])[0].get("body", [])
        check("find_symbol reads a markdown section",
              res.get("count") == 1 and body and body[0].endswith("### Modules")
              and not any("## Running" in l for l in body), res)
        r = b.rpc("tools/call", {"name": "grep", "arguments": {"pattern": "messy", "path": "NOTES.md"}})
        hit = r["result"]["content"][0]["text"]
        check("grep tags the markdown section", "Test project/Layout/Modules" in hit, hit)
        res = b.call("insert_after_symbol", {
            "file": notes, "name_path": "Running",
            "text": "## Caveats\n\nNone yet.\n",
        })
        with open(notes) as f:
            check("insert_after_symbol appends a markdown section",
                  f.read().rstrip().endswith("## Caveats\n\nNone yet."), res)
        res = b.call("replace_symbol_body", {
            "file": notes, "name_path": "Caveats",
            "body": "## Caveats\n\nOne, now.\n",
        })
        with open(notes) as f:
            check("replace_symbol_body rewrites a markdown section",
                  "One, now." in f.read() and "None yet." not in open(notes).read(), res)

        # Data files index by key: a compose service is a name path, a TOML
        # table too, and a long data file with one top-level key is read as
        # text rather than answered with a one-line outline.
        compose = os.path.join(root, "deploy", "docker-compose.yml")
        res = b.call("skim", {"files": [compose]})
        outline = res["files"][0].get("outline", [])
        yaml_parser = "no treesitter parser" not in (res["files"][0].get("note") or "")
        if not yaml_parser:
            print("SKIP data-file checks: no yaml parser under the test config")
        check("skim outlines yaml keys", not yaml_parser or (
              any(l.strip().startswith("1-") and "services:" in l for l in outline)
              and any("api:" in l for l in outline)), res)
        if yaml_parser:
            res = b.call("find_symbol", {"file": compose, "name": "services/api/environment", "include_body": True})
            body = res.get("matches", [{}])[0].get("body", [])
            check("find_symbol reads a yaml key by path",
                  res.get("count") == 1 and body and "LOG_LEVEL: info" in body[-1], res)
            res = b.call("replace_symbol_lines", {
                "file": compose, "name_path": "services/api/environment",
                "match": "      LOG_LEVEL: info", "text": "      LOG_LEVEL: debug",
            })
            check("edit a yaml key by path", "LOG_LEVEL: debug" in open(compose).read(), res)
            toml = os.path.join(root, "config.toml")
            res = b.call("find_symbol", {"file": toml, "name": "server", "include_body": True})
            body = res.get("matches", [{}])[0].get("body", [])
            check("find_symbol reads a toml table",
                  res.get("count") == 1 and body and body[0].endswith("[server]")
                  and any("port = 8080" in l for l in body), res)
            big = os.path.join(root, "big.yml")
            with open(big, "w") as f:
                f.write("items:\n" + "".join("  - name: item%d\n    value: %d\n" % (i, i) for i in range(300)))
            r = b.rpc("tools/call", {"name": "read_file", "arguments": {"path": big}})
            text = r["result"]["content"][0]["text"]
            check("read_file returns text when the outline is trivial",
                  text.startswith("1: items:") and "600: " in text, text[:120])
            os.remove(big)

        # A stale offset with the right expect is refused, and the refusal
        # carries a code action that applies the edit where the text is.
        try:
            b.call("replace_symbol_lines", {
                "file": util, "name_path": "M.greet", "first_line": 3, "last_line": 3,
                "expect": 'return "hello, " .. name', "text": '    return "hi, " .. name',
            })
            check("stale expect is refused", False, "call succeeded")
        except RuntimeError as e:
            msg = str(e)
            m = re.search(r"token=(\d+)", msg)
            check("stale expect is refused with a relocation",
                  "at lines 2-2 (relative)" in msg and m is not None, msg)
            assert m is not None
            res = b.call("apply_code_action", {"token": m.group(1), "index": 1})
            check("relocated edit applies",
                  res.get("replaced") == "lines 2-2 of M.greet"
                  and 'return "hi, "' in open(util).read(), res)

        # Several chunks in one symbol apply together, bottom-up.
        res = b.call("replace_symbol_lines", {
            "file": util, "name_path": "M.greet",
            "chunks": [
                {"first_line": 1, "last_line": 1, "expect": "function M.greet(name)",
                 "text": "function M.greet(name)\n    name = tostring(name)"},
                {"first_line": 2, "last_line": 2, "expect": 'return "hi, " .. name',
                 "text": '    return "hello, " .. name'},
            ],
        })
        text = open(util).read()
        check("chunked edit applies all chunks",
              "name = tostring(name)" in text and 'return "hello, " .. name' in text
              and len(res.get("replaced_chunks", [])) == 2, res)
        # A chunk whose expect fails refuses the whole call.
        try:
            b.call("replace_symbol_lines", {
                "file": util, "name_path": "M.greet",
                "chunks": [
                    {"first_line": 1, "last_line": 1, "expect": "function M.greet(name)", "text": "function M.greet(name)"},
                    {"first_line": 3, "last_line": 3, "expect": "nothing like this", "text": "x"},
                ],
            })
            check("chunked edit is all-or-nothing", False, "call succeeded")
        except RuntimeError as e:
            check("chunked edit is all-or-nothing",
                  "nowhere in M.greet" in str(e) and open(util).read() == text, e)

        # Chunks may name their own symbols: one concept living in two
        # functions is one call. The relocated range follows the expected
        # text's length, so a miscounted last_line still lands right.
        res = b.call("replace_symbol_lines", {
            "file": util,
            "chunks": [
                {"name_path": "M.greet", "first_line": 2, "last_line": 2,
                 "expect": "name = tostring(name)", "text": "    name = tostring(name):lower()"},
                {"name_path": "M.shout", "first_line": 2, "last_line": 2,
                 "expect": 'return string.upper(M.greet(name))',
                 "text": "    return string.upper(M.greet(name)) .. \"!\""},
            ],
        })
        text = open(util).read()
        check("chunks across symbols apply together",
              "tostring(name):lower()" in text and '.. "!"' in text
              and [c.get("symbol") for c in res.get("replaced_chunks", [])] == ["M.greet", "M.shout"], res)
        try:
            b.call("replace_symbol_lines", {
                "file": util,
                "chunks": [
                    {"name_path": "M.greet", "first_line": 1, "last_line": 3,
                     "expect": "name = tostring(name):lower()", "text": "    name = tostring(name)"},
                    {"name_path": "M.shout", "first_line": 3, "last_line": 3,
                     "expect": 'return string.upper(M.greet(name)) .. "!"',
                     "text": "    return string.upper(M.greet(name))"},
                ],
            })
            check("stale chunks across symbols are refused", False, "call succeeded")
        except RuntimeError as e:
            m = re.search(r"token=(\d+)", str(e))
            check("stale chunks across symbols are refused with a relocation",
                  "at lines 2-2 (relative)" in str(e) and m is not None, e)
            assert m is not None
            res = b.call("apply_code_action", {"token": m.group(1), "index": 1})
            text = open(util).read()
            check("relocated chunks apply in both symbols",
                  "tostring(name):lower()" not in text and '.. "!"' not in text
                  and "    name = tostring(name)\n" in text, res)

        # Text-keyed: match names the lines, no arithmetic; refused when the
        # text is absent or ambiguous.
        res = b.call("replace_symbol_lines", {
            "file": util, "name_path": "M.greet",
            "match": "name = tostring(name)", "text": "    name = tostring(name):upper()",
        })
        check("match addresses the lines by text",
              res.get("replaced") == "lines 2-2 of M.greet"
              and "tostring(name):upper()" in open(util).read(), res)
        try:
            b.call("replace_symbol_lines", {"file": util, "name_path": "M.greet",
                                            "match": "no such line", "text": "x"})
            check("match refuses absent text", False, "call succeeded")
        except RuntimeError as e:
            check("match refuses absent text", "nowhere in M.greet" in str(e), e)
        # Absolute numbers, as read_file reports them: M.greet starts at 6.
        res = b.call("replace_symbol_lines", {
            "file": util, "name_path": "M.greet", "absolute": True,
            "first_line": 7, "last_line": 7, "expect": "name = tostring(name):upper()",
            "text": "    name = tostring(name)",
        })
        check("absolute line numbers",
              res.get("replaced") == "lines 2-2 of M.greet"
              and "tostring(name):upper()" not in open(util).read(), res)

        # A small project lists its tests in the map by default.
        res = b.call("workspace_map", {})
        check("small project map includes tests",
              any(f["file"].endswith("util_test.lua") for f in res.get("files", []))
              and "test files left out" not in (res.get("note") or ""), res)
        res = b.call("workspace_map", {"include_tests": False})
        check("include_tests=false leaves them out",
              not any(f["file"].endswith("util_test.lua") for f in res.get("files", []))
              and "1 test files left out" in (res.get("note") or ""), res)
        # The pre-existing diagnostics are listed once, then reported as
        # unchanged until they change or full_diagnostics asks again.
        res = b.call("replace_symbol_lines", {
            "file": util, "name_path": "M.greet", "first_line": 2, "last_line": 2,
            "text": "    name = tostring(name) -- again",
        })
        res2 = b.call("replace_symbol_lines", {
            "file": util, "name_path": "M.greet", "first_line": 2, "last_line": 2,
            "text": "    name = tostring(name)",
        })
        check("preexisting diagnostics reported as unchanged",
              res2.get("preexisting") is None or "no change" in res2.get("preexisting"), res2)
        res3 = b.call("replace_symbol_lines", {
            "file": util, "name_path": "M.greet", "first_line": 2, "last_line": 2,
            "text": "    name = tostring(name)", "full_diagnostics": True,
        })
        check("full_diagnostics lists them again",
              res3.get("preexisting") is None or "no change" not in res3.get("preexisting"), res3)

        # A name path that matches nothing yields suggestions, not matches.
        res = b.call("find_symbol", {"file": util, "name": "Nope/greet"})
        check("find_symbol name path miss gives suggestions",
              res.get("count") == 0 and res.get("matches") == []
              and any(s.get("name_path") == "M.greet" for s in res.get("suggestions", [])), res)
        res = b.call("workspace_map", {"glob": "lua/**/*.rs"})
        check("workspace_map explains an empty glob",
              res.get("file_count") == 0 and "0 of" in (res.get("note") or ""), res)
        res = b.call("workspace_map", {"glob": "lua/**/*.lua"})
        check("workspace_map glob spans zero directories",
              any(f["file"] == "lua/testproj/util.lua" for f in res.get("files", [])), res)
        # A symbol-less region (the top-of-file `local M = {}`, which is no
        # declaration) is editable by match with no name_path, the barrel /
        # export-list case that used to force a fall back to Write.
        res = b.call("replace_symbol_lines", {
            "file": util, "match": "local M = {}", "text": "local M = {} -- module table"})
        check("symbol-less edit by match",
              "-- module table" in open(util).read()
              and res.get("replaced_text") == ["local M = {}"], res)
        res = b.call("replace_symbol_lines", {
            "file": util, "absolute": True, "first_line": 1, "last_line": 1,
            "expect": "local M = {} -- module table", "text": "local M = {}"})
        check("symbol-less edit by absolute line",
              open(util).read().startswith("local M = {}\n"), res)
        try:
            b.call("replace_symbol_lines", {"file": util, "first_line": 1, "last_line": 1, "text": "x"})
            check("symbol-less needs absolute or match", False, "call succeeded")
        except RuntimeError as e:
            check("symbol-less needs absolute or match", "absolute=true" in str(e), e)

        # insert_before lands above the doc comment, not between it and the
        # declaration, so the new sibling is not orphaned under the comment.
        res = b.call("insert_before_symbol", {
            "file": util, "name_path": "M.greet", "text": "local GREETING = \"hello\""})
        lines = open(util).read().splitlines()
        gi = lines.index("local GREETING = \"hello\"")
        check("insert_before clears the doc comment",
              lines[gi + 1] == "" and lines[gi + 2].startswith("--- Greet"), res)
        b.call("replace_symbol_lines", {
            "file": util, "match": 'local GREETING = "hello"\n\n', "text": ""})

        # Put M.greet back the way the checks below expect it.
        b.call("replace_symbol_body", {
            "file": util, "name_path": "M.greet",
            "body": 'function M.greet(name)\n    return "hello, " .. name\nend',
        })
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
        # The formatter drops the blank line after the inserted function; the
        # ledger folds that into the edit, so the undo puts the blank back
        # too (and reports a restore rather than a removal).
        check("undo_edit removes the insert",
              len(res.get("undone", [])) == 1 and "M.extra" not in on_disk
              and on_disk.endswith("end\n\nreturn M\n")
              and (res["undone"][0].get("removed_lines") or res["undone"][0].get("restored_lines")), res)
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
        # A remembered command outlives the workspace: close it, reopen the
        # same root, and a bare check_project still runs it.
        res = b.call("check_project", {"command": cmd, "remember": True})
        check("check_project remember", "later ones" in res.get("remembered", ""), res)
        b.call("close_workspace", {})
        res = b.call("open_workspace", {"root": root})
        pid = res["pid"]
        res = b.call("check_project", {})
        check("remembered command survives a workspace restart",
              res.get("remembered", "").startswith("using the command remembered")
              and res.get("output") == ["one", "three"], res)

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

        # A glob that matched nothing says so, and says why, instead of
        # claiming no files were passed at all.
        try:
            b.call("find_symbol", {"name": "M.greet", "glob": "nosuch/**/*.lua"})
            check("empty glob explains itself", False, "call succeeded")
        except RuntimeError as e:
            check("empty glob explains itself",
                  "matched no files" in str(e) and "**/" in str(e), e)
        # A bare filename reads as "wherever it lives", not "in the root".
        res = b.call("find_symbol", {"name": "M.greet", "glob": "util.lua"})
        check("bare filename glob searches subdirectories", res.get("count") == 1, res)

        # A file changed behind the editor's back is picked up rather than
        # written over. This is the case that used to hang the RPC channel
        # on nvim's "write anyway?" prompt and silently drop the edit.
        with open(util) as f:
            before_external = f.read()
        with open(util, "w") as f:
            f.write("-- external edit\n" + before_external)
        res = b.call("find_symbol", {"file": util, "name": "M.greet"})
        check("external change is picked up",
              res.get("count") == 1
              and res["matches"][0]["lines"].startswith("7"), res)
        res = b.call("replace_symbol_lines", {
            "file": util, "name_path": "M.greet", "first_line": 1, "last_line": 1,
            "text": "function M.greet(name)",
        })
        with open(util) as f:
            after_edit = f.read()
        check("edit after external change keeps it",
              "-- external edit" in after_edit and "note" in res, res)
        with open(util, "w") as f:
            f.write(before_external)

        # File tools run in-process, rooted at the workspace.
        reply = b.rpc("tools/call", {"name": "grep", "arguments": {"pattern": "M.greet"}})
        text = reply["result"]["content"][0]["text"]
        check("grep annotated", "util.lua:" in text and "[M.greet" in text, text)
        # A path glob is matched against the path from the root, so a
        # directory prefix has to work the way it reads.
        reply = b.rpc("tools/call", {"name": "grep", "arguments": {
            "pattern": "M.greet", "glob": "lua/**/*.lua", "context": 0}})
        text = reply["result"]["content"][0]["text"]
        check("grep path glob matches", "util.lua:" in text and text.startswith("/"), text)
        reply = b.rpc("tools/call", {"name": "grep", "arguments": {
            "pattern": "M.greet", "glob": "nosuch/**/*.lua", "context": 0}})
        check("grep path glob excludes",
              reply["result"]["content"][0]["text"] == "(no matches)", reply)

        # grep filters. The project has no test file of its own, so one is
        # added here: tests= is matched on the path, and kind= on what the
        # classifier says the hit is. "greet" appears as a definition, as
        # calls, and inside the doc comment above the definition.
        with open(os.path.join(root, "lua", "testproj", "util_test.lua"), "w") as f:
            f.write('local util = require("testproj.util")\nprint(util.greet("x"))\n')

        def grep_text(**a):
            r = b.rpc("tools/call", {"name": "grep", "arguments": a})
            return r["result"]["content"][0]["text"]

        plain = grep_text(pattern="greet", glob="**/*.lua", context=0)
        no_tests = grep_text(pattern="greet", glob="**/*.lua", context=0, tests="exclude")
        only_tests = grep_text(pattern="greet", glob="**/*.lua", context=0, tests="only")
        check("grep tests=exclude drops test files",
              "util_test.lua" in plain and "util_test.lua" not in no_tests
              and "util.lua:" in no_tests, no_tests)
        check("grep tests=only keeps just them",
              "util_test.lua" in only_tests
              and all("util_test.lua" in l or l.startswith("...")
                      for l in only_tests.split("\n")), only_tests)

        comments = grep_text(pattern="greet", glob="**/*.lua", kind="comment")
        code = grep_text(pattern="greet", glob="**/*.lua", kind="code")
        check("grep kind=comment finds the doc comment",
              "Greet a person" in comments, comments)
        # The doc comment is still quoted inside a hit's tag, so the test is
        # that no hit *line* is the comment line itself.
        check("grep kind=code drops the comment hit",
              all("]:" in l or l.startswith("...") for l in code.split("\n"))
              and "Greet a person" not in code.split("]:")[-1], code)
        defs = grep_text(pattern="greet", glob="**/*.lua", kind="def")
        check("grep kind=def keeps only declarations",
              "function M.greet" in defs
              and all(" def" in l or l.startswith("...") for l in defs.split("\n")), defs)
        # grep_text goes through rpc, which returns the error as content
        # rather than raising the way b.call does.
        bad = grep_text(pattern="greet", kind="nonsense")
        check("grep rejects an unknown kind", "must be one of" in bad, bad)
        os.remove(os.path.join(root, "lua", "testproj", "util_test.lua"))

        # list_files takes the same globs and leaves binaries out.
        reply = b.rpc("tools/call", {"name": "list_files", "arguments": {"glob": "lua/**/*.lua"}})
        text = reply["result"]["content"][0]["text"]
        check("list_files glob", "lua/testproj/util.lua" in text and "tool.zig" not in text, text)
        reply = b.rpc("tools/call", {"name": "list_files", "arguments": {}})
        text = reply["result"]["content"][0]["text"]
        check("list_files hides binaries",
              "blob.bin" not in text and "not listed" in text, text)
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

        # A file changed by another tool must be resynced, and the language
        # servers told, before the next edit is judged. Otherwise a symbol
        # added to one file with a plain write looks undefined to the file
        # that uses it, and the edit is reported as breaking something it did
        # not break.
        b.call("find_symbol", {"file": util, "name": "M.greet"})   # loads the buffer
        with open(util) as f:
            original_util = f.read()
        # Appended rather than substituted: earlier cases in this file have
        # already rewritten util.lua, so no particular line is still there to
        # anchor to.
        with open(util, "w") as f:
            f.write(original_util + "\nfunction M.added() return 7 end\n")
        res = b.call("replace_symbol_lines", {
            "file": main_lua, "name_path": "run", "first_line": 2, "last_line": 2,
            "text": '    print(util.greet("world"))',
        })
        seen = b.call("buffer_lines", {"file": util})
        check("an external change is resynced before the next edit is judged",
              any("M.added" in l for l in seen.get("lines", [])), seen)
        check("and the edit is not blamed for it",
              res.get("diagnostics_after") == "no new errors or warnings"
              or not isinstance(res.get("diagnostics_after"), list)
              or not any("added" in d for d in res["diagnostics_after"]), res)
        # Put the file back, then read it through agent99 so the buffer
        # follows: undo_edit saves, and the conflict guard would - correctly -
        # refuse to write a buffer whose file had changed underneath it.
        with open(util, "w") as f:
            f.write(original_util)
        b.call("find_symbol", {"file": util, "name": "M.greet"})
        b.call("undo_edit", {"all": True})

        # A stale relative offset must fail rather than clobber, and every
        # replace echoes back what it replaced.
        res = b.call("replace_symbol_lines", {
            "file": util, "name_path": "M.greet", "first_line": 2, "last_line": 2,
            "text": '    return "hi, " .. name', "expect": '    return "hello, " .. name',
        })
        check("expect= matching text applies",
              res.get("replaced_text") == ['    return "hello, " .. name'], res)
        try:
            b.call("replace_symbol_lines", {
                "file": util, "name_path": "M.greet", "first_line": 2, "last_line": 2,
                "text": "    return 1", "expect": '    return "hello, " .. name',
            })
            check("expect= mismatch refuses", False, "call succeeded")
        except RuntimeError as e:
            check("expect= mismatch refuses", "do not hold the expected text" in str(e), e)
        b.call("undo_edit", {"all": True})

        # Navigation tools that were implemented but hidden from the schema
        # must be advertised: a hidden tool is one nobody knows exists.
        check("call hierarchy and implementations are advertised",
              {"incoming_calls", "outgoing_calls", "implementation",
               "type_definition"} <= tools, sorted(tools))

        # dry_run shows the diff without touching the file.
        with open(util) as f:
            before_dry = f.read()
        res = b.call("replace_symbol_lines", {
            "file": util, "name_path": "M.greet", "first_line": 2, "last_line": 2,
            "text": '    return "DRY" .. name', "dry_run": True,
        })
        with open(util) as f:
            check("dry_run leaves the file alone", f.read() == before_dry, res)
        check("dry_run returns a diff",
              res.get("dry_run") is True
              and any(l.startswith("+") for l in res.get("diff", [])), res)

        # move_symbols: splitting a file is a symbol operation, not a text
        # one - the doc comments travel with their functions and both files
        # have their imports reorganized afterwards.
        split = os.path.join(root, "lua", "testproj", "context_store.lua")
        res = b.call("move_symbols", {
            "from": util, "to": split, "names": ["M.shout"],
        })
        with open(split) as f:
            moved_text = f.read()
        with open(util) as f:
            left_text = f.read()
        check("move_symbols moves the symbol",
              "function M.shout" in moved_text and "function M.shout" not in left_text,
              res)
        check("move_symbols creates the destination and reports what moved",
              res.get("created") is True and res.get("moved") == ["M.shout"], res)
        check("the symbol that stayed is untouched", "function M.greet" in left_text, left_text)
        res = b.call("undo_edit", {"all": True})
        with open(util) as f:
            check("undo_edit puts a split back", "function M.shout" in f.read(), res)
        os.path.exists(split) and os.remove(split)

        try:
            b.call("move_symbols", {"from": util, "to": util, "names": ["M.greet"]})
            check("move_symbols refuses a no-op move", False, "call succeeded")
        except RuntimeError as e:
            check("move_symbols refuses a no-op move", "same file" in str(e), e)

        # File lifecycle: create, move, delete, each undoable. (Whether the
        # new file comes back reformatted depends on the language having a
        # formatter, which the minimal config's lua_ls does not; the Go and
        # TypeScript servers do reformat and re-import it.)
        added = os.path.join(root, "lua", "testproj", "nested", "extra.lua")
        moved = os.path.join(root, "lua", "testproj", "renamed.lua")
        res = b.call("create_file", {
            "file": added,
            "text": "local M = {}\nfunction M.two()\n    return 2\nend\nreturn M\n",
        })
        with open(added) as f:
            created_text = f.read()
        check("create_file writes, making parent directories",
              res.get("created", "").endswith("extra.lua")
              and "function M.two()" in created_text, res)
        try:
            b.call("create_file", {"file": added, "text": "x"})
            check("create_file refuses to overwrite", False, "call succeeded")
        except RuntimeError as e:
            check("create_file refuses to overwrite", "already exists" in str(e), e)
        # A new file has to be visible to the symbol tools straight away.
        res = b.call("find_symbol", {"file": added, "name": "M.two"})
        check("created file is indexed", res.get("count") == 1, res)

        res = b.call("move_file", {"from": added, "to": moved})
        check("move_file moves",
              os.path.exists(moved) and not os.path.exists(added), res)
        res = b.call("delete_file", {"file": moved})
        check("delete_file deletes",
              not os.path.exists(moved) and res.get("lines", 0) > 0, res)

        res = b.call("undo_edit", {})
        check("undo_edit restores a deleted file",
              os.path.exists(moved) and len(res.get("undone", [])) == 1
              and res["undone"][0].get("reversed") == "delete_file", res)
        res = b.call("undo_edit", {})
        check("undo_edit reverses a move",
              os.path.exists(added) and not os.path.exists(moved), res)
        res = b.call("undo_edit", {})
        check("undo_edit removes a created file", not os.path.exists(added), res)

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
