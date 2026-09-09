#!/usr/bin/env python3
"""Smoke test for the standalone MCP server: no $AGENT99_NVIM, the bridge
starts its own headless Neovim through open_workspace and routes the LSP
and file tools to it. Runs on a scratch copy of tests/testproj because
headless edits are written to disk.

Run through tests/smoke.sh (which sets AGENT99_HEADLESS_INIT so the
instance uses the minimal config, not the user's).

The checks are grouped by the family of tools they cover, and a group is
what this file takes as an argument:

    python3 tests/drive_headless.py edit        # or tests/smoke.sh headless:edit

Groups share nothing - each runs in its own process, against its own copy
of the project, with its own headless Neovim - so one of them can be run
on its own while working on that family, and the whole suite runs several
at a time. AGENT99_TEST_JOBS caps how many; 1 runs them in order in this
process, which reads better when something fails.
"""

import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from drive_mcp import REPO, PROJ, Bridge, check  # noqa: E402


# The suite is a set of groups, one per family of tools, so a change to one
# family can be checked without paying for the others: tests/smoke.sh takes
# headless:<group>, and this file takes the same names as arguments. Every
# group starts from the pristine project, so it does not matter which of
# them ran before, or whether any did.
class Context:
    def __init__(self, b, work, root):
        self.b = b
        self.work = work
        self.root = root
        self.util = os.path.join(root, "lua", "testproj", "util.lua")
        self.main_lua = os.path.join(root, "lua", "testproj", "main.lua")
        self.tools = set()
        self.pid = 0
        self.opened = False


def seed(root):
    """The two files the workspace and list_files checks need on top of the
    project: a language the minimal config cannot serve, and a binary."""
    with open(os.path.join(root, "tool.zig"), "w") as f:
        f.write("pub fn main() void {}\n")
    with open(os.path.join(root, "blob.bin"), "wb") as f:
        f.write(b"\x00\x01" * 64)


def reset(c):
    """Put the scratch project back the way a group expects to find it: every
    file restored, anything an earlier check added removed. The editor is not
    told; it picks the change up itself, the way it does for any file changed
    behind its back.

    What the undo ledger still holds is left alone on purpose. Undoing writes
    the text it takes back, and a write is refused for a file that changed on
    disk since the editor read it - which is every file this just restored -
    so the undo would leave those buffers unsaved and poison every write
    after it. A check that cares what the ledger holds calls restart()."""
    restore(c)


def restore(c):
    pristine = set()
    for dirpath, _, names in os.walk(PROJ):
        for name in names:
            pristine.add(os.path.relpath(os.path.join(dirpath, name), PROJ))
    added = []
    for dirpath, _, names in os.walk(c.root):
        for name in names:
            rel = os.path.relpath(os.path.join(dirpath, name), c.root)
            if rel not in pristine:
                added.append(os.path.join(c.root, rel))
    for path in added:
        os.remove(path)
    shutil.copytree(PROJ, c.root, dirs_exist_ok=True)
    seed(c.root)
    # A read through agent99, so the editor's buffers follow the restore
    # before anything is judged against them. Only once there is an editor:
    # a read before that would have the server open a workspace for it.
    if c.opened:
        c.b.call("find_symbol", {"file": c.util, "name": "M.greet"})
        c.b.call("find_symbol", {"file": c.main_lua, "name": "run"})


def restart(c):
    """A group gets its own editor: buffers, undo ledger, owed verdicts and
    the settle each server has learned all start from nothing, so a group
    cannot be helped or hindered by the ones that ran before it."""
    try:
        c.b.call("close_workspace", {})
    except RuntimeError:
        pass
    c.opened = False
    restore(c)
    res = c.b.call("open_workspace", {"root": c.root})
    c.pid = res["pid"]
    c.opened = True


def group_workspace(c):
    """Opening, reopening and closing a workspace, what the map says about
    the languages in it, check_project and install_language."""
    b, root, work = c.b, c.root, c.work
    util, main_lua, tools = c.util, c.main_lua, c.tools

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

    # The home directory and a filesystem root are not projects: opening
    # one points every language server at the whole machine, and the
    # friction spool measured what that costs in a real session.
    for wide, word in ((os.path.expanduser("~"), "home directory"), ("/", "filesystem root")):
        try:
            b.call("open_workspace", {"root": wide})
            check("a root that is not a project is refused (%s)" % word, False, "call succeeded")
        except RuntimeError as e:
            check("a root that is not a project is refused (%s)" % word,
                  word in str(e) and "AGENT99_ALLOW_WIDE_ROOT" in str(e), e)

    # A call that needs Neovim opens the project the path it names belongs
    # to, instead of the "call open_workspace first" round trip: the file
    # is inside a project once the project has a marker at its top.
    os.mkdir(os.path.join(root, ".git"))
    res = b.call("find_symbol", {"file": main_lua, "name": "run"})
    check("a call with no workspace opens the project around its file",
          res.get("count") == 1, res)
    res = b.call("close_workspace", {})
    check("the auto-opened workspace is the project root",
          res.get("closed") == [os.path.realpath(root)], res)
    shutil.rmtree(os.path.join(root, ".git"))

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
    c.pid = res["pid"]
    langs = {l["filetype"]: l for l in res.get("languages", [])}
    check("open_workspace reports languages",
          "lua" in langs and langs.get("zig", {}).get("treesitter_parser") is False
          and "zig" in (res.get("note") or ""), res)

    again = b.call("open_workspace", {"root": root})
    check("reopen is a no-op", again.get("pid") == c.pid, again)

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

    reset(c)
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
    c.pid = res["pid"]
    res = b.call("check_project", {})
    check("remembered command survives a workspace restart",
          res.get("remembered", "").startswith("using the command remembered")
          and res.get("output") == ["one", "three"], res)

    reset(c)
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

    reset(c)
    # Navigation tools that were implemented but hidden from the schema
    # must be advertised: a hidden tool is one nobody knows exists.
    check("call hierarchy and implementations are advertised",
          {"incoming_calls", "outgoing_calls", "implementation",
           "type_definition"} <= tools, sorted(tools))


def group_index(c):
    """Reading structure: skim, find_symbol and workspace_map over Lua,
    markdown and data files, and the globs that address them."""
    b, root, work = c.b, c.root, c.work
    util, main_lua, tools = c.util, c.main_lua, c.tools

    reset(c)
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
        # A truncated read says where to resume and how much is left, so
        # finding that out does not cost another call.
        r = b.rpc("tools/call", {"name": "read_file",
                                 "arguments": {"path": big, "offset": 1, "limit": 100}})
        text = r["result"]["content"][0]["text"]
        check("a truncated read points at the rest",
              "lines 1-100 of 601" in text and "offset=101" in text,
              text[-200:])
        os.remove(big)

    reset(c)
    # A small project lists its tests in the map by default.
    res = b.call("workspace_map", {})
    check("small project map includes tests",
          any(f["file"].endswith("util_test.lua") for f in res.get("files", []))
          and "test files left out" not in (res.get("note") or ""), res)
    res = b.call("workspace_map", {"include_tests": False})
    check("include_tests=false leaves them out",
          not any(f["file"].endswith("util_test.lua") for f in res.get("files", []))
          and "1 test files left out" in (res.get("note") or ""), res)

    # workspace_tree: directories with aggregated stats, root files first,
    # the tree cut to the budget, and a zoom by path.
    res = b.call("workspace_tree", {})
    tree = res.get("tree", [])
    check("workspace_tree lists lua/testproj with stats",
          any(l.startswith("lua/testproj/") and "files" in l and "lines" in l and "lua" in l
              for l in tree)
          and res.get("file_count", 0) > 0 and res.get("line_count", 0) > 0, res)
    check("workspace_tree counts declarations in a small project",
          any("decls" in l for l in tree), tree)
    res = b.call("workspace_tree", {"budget": 5})
    check("workspace_tree honours the budget", len(res.get("tree", [])) <= 5, res)
    res = b.call("workspace_tree", {"path": "lua/testproj", "depth": 1})
    check("workspace_tree zooms by path",
          res.get("root", "").endswith("lua/testproj")
          and any(l.startswith("util.lua") for l in res.get("tree", [])), res)
    try:
        b.call("workspace_tree", {"path": "nowhere"})
        check("workspace_tree refuses a missing directory", False, "call succeeded")
    except RuntimeError as e:
        check("workspace_tree refuses a missing directory", "not a directory" in str(e), e)

    reset(c)
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

    reset(c)
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
    # With no file, files or glob at all the search is the whole workspace,
    # rather than an error asking for a scope the caller does not have yet.
    res = b.call("find_symbol", {"name": "M.greet"})
    files = [m["file"] for m in res.get("matches", [])]
    check("no scope searches the whole workspace",
          res.get("count", 0) >= 1 and any(f.endswith("util.lua") for f in files), res)
    # A name nothing spells is still an error, and says where it looked.
    try:
        b.call("find_symbol", {"name": "no_such_symbol_anywhere"})
        check("whole-workspace miss explains itself", False, "call succeeded")
    except RuntimeError as e:
        check("whole-workspace miss explains itself",
              "mentions" in str(e) and "glob" in str(e), e)

    reset(c)
    # Build files are structure too, and they are everywhere: a make target
    # is a symbol whose body is its recipe, a make variable is a symbol of
    # one line, and a shell script is its functions plus the variables it
    # sets at the top - not the ones it sets again inside a loop, which are
    # statements and would index the same name twice.
    mk = os.path.join(root, "Makefile")
    res = b.call("skim", {"files": [mk]})
    if "no treesitter parser" in (res["files"][0].get("note") or ""):
        print("SKIP make checks: no make parser under the test config")
    else:
        outline = res["files"][0].get("outline", [])
        check("skim outlines make variables and rules",
              any(l.strip().startswith("1:") and "CFLAGS" in l for l in outline)
              and any("build:" in l for l in outline)
              and any("test: build" in l for l in outline), res)
        res = b.call("find_symbol", {"file": mk, "name": "test", "include_body": True})
        body = res.get("matches", [{}])[0].get("body", [])
        check("find_symbol reads a make target with its recipe",
              res.get("count") == 1 and len(body) == 2
              and body[0].endswith("test: build")
              and "echo testing" in body[1], res)
        # The recipe's tab survives, and the rule owns no blank line beyond
        # it: a target that ate the gap would run into the next one.
        res = b.call("replace_symbol_body", {
            "file": mk, "name_path": "build", "body": "build:\n\techo building it"})
        with open(mk) as f:
            made = f.read()
        check("a make recipe keeps its tab and its spacing",
              "\techo building it\n\ntest: build" in made, made)

    # A Lua file that declares nothing (a table of package names, the way a
    # plugin config lists them) has no treesitter outline, so the server's
    # symbols answer instead - and those hold every element of every array,
    # named after its own text. The keys are the outline; the elements are
    # left out and counted.
    deps = os.path.join(root, "lua", "testproj", "deps.lua")
    with open(deps, "w") as f:
        f.write("return {\n"
                "    parsers = { \"lua\", \"go\", \"python\", \"bash\" },\n"
                "    servers = { \"lua_ls\", \"gopls\" },\n"
                "}\n")
    res = b.call("skim", {"files": [deps]})
    entry = res["files"][0]
    outline = entry.get("outline", [])
    if not outline:
        print("SKIP data-table checks: no outline for a declaration-less Lua file")
    else:
        check("skim leaves an array's elements out of a data table's outline",
              any("parsers" in line for line in outline)
              and any("servers" in line for line in outline)
              and not any(line.strip().split(":")[1].startswith(" String") for line in outline)
              and "6 list entries are left out" in (entry.get("note") or ""), res)
    os.remove(deps)

    script = os.path.join(root, "scripts", "build.sh")
    res = b.call("skim", {"files": [script]})
    if "no treesitter parser" in (res["files"][0].get("note") or ""):
        print("SKIP shell checks: no bash parser under the test config")
    else:
        outline = res["files"][0].get("outline", [])
        check("skim outlines shell functions and the variables set at the top",
              any("pick_mode()" in l for l in outline)
              and any("main()" in l for l in outline)
              and len([l for l in outline if "MODE=" in l]) == 1, res)
        res = b.call("find_symbol", {"file": script, "name": "pick_mode", "include_body": True})
        body = res.get("matches", [{}])[0].get("body", [])
        check("find_symbol reads a shell function",
              res.get("count") == 1 and body and body[0].endswith("pick_mode() {")
              and body[-1].endswith("}")
              and any('MODE="$arg"' in line for line in body), res)
        res = b.call("replace_symbol_lines", {
            "file": script, "name_path": "MODE",
            "match": 'MODE="fast"', "text": 'MODE="${1:-fast}"'})
        with open(script) as f:
            check("a shell variable is editable as a symbol",
                  'MODE="${1:-fast}"' in f.read(), res)

    reset(c)
    # unreferenced_symbols: the sweep an extract-to-module refactor needs,
    # because nothing else reports a definition left behind. messy.lua holds
    # a function nothing calls.
    messy = os.path.join(root, "lua", "testproj", "messy.lua")
    res = b.call("unreferenced_symbols", {"file": messy})
    names = [s["name"] for s in res.get("unreferenced", [])]
    check("unreferenced_symbols finds what nothing calls",
          "M.noop" in names and res.get("count", 0) >= 1, res)
    # M.greet is called from main.lua, so it is not a finding - as long as
    # the server links the two files at all.
    refs = b.call("references", {"file": util, "line": 6, "symbol": "greet"})
    if refs.get("count", 0) <= 1:
        print("SKIP unreferenced_symbols cross-file check: no references from main.lua")
    else:
        res = b.call("unreferenced_symbols", {"file": util})
        names = [s["name"] for s in res.get("unreferenced", [])]
        check("unreferenced_symbols keeps quiet about a symbol with callers",
              "M.greet" not in names, res)


def group_edit(c):
    """The symbol edit tools: whole bodies, line ranges by number, text or
    chunk, the relocation of a stale offset, and rename_symbol."""
    b, root, work = c.b, c.root, c.work
    util, main_lua, tools = c.util, c.main_lua, c.tools

    reset(c)
    # A stale offset with the right expect: the text sits in exactly one
    # other place, so the edit is applied there and the reply says so.
    res = b.call("replace_symbol_lines", {
        "file": util, "name_path": "M.greet", "first_line": 3, "last_line": 3,
        "expect": 'return "hello, " .. name', "text": '    return "hi, " .. name',
    })
    moves = res.get("relocated", [])
    check("stale expect is relocated and applied",
          res.get("replaced") == "lines 2-2 of M.greet"
          and 'return "hi, "' in open(util).read()
          and len(moves) == 1 and moves[0].get("requested") == "lines 3-3 of M.greet"
          and moves[0].get("applied_at", "").startswith("lines 2-2 of M.greet")
          and "stale too" in res.get("relocated_note", ""), res)

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
        # The refusal names the chunk's symbol, and reports the search as
        # file-wide, because that is how far locate_expected looked.
        check("chunked edit is all-or-nothing",
              "of M.greet do not hold the expected text" in str(e)
              and "nowhere in" in str(e) and open(util).read() == text, e)

    # Chunks may name their own symbols: one concept living in two
    # functions is one call. A stale chunk relocates to wherever its
    # expected text is, as long as that text covers the whole range the
    # chunk asked for.
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
    res = b.call("replace_symbol_lines", {
        "file": util,
        "chunks": [
            {"name_path": "M.greet", "first_line": 1, "last_line": 1,
             "expect": "name = tostring(name):lower()", "text": "    name = tostring(name)"},
            {"name_path": "M.shout", "first_line": 3, "last_line": 3,
             "expect": 'return string.upper(M.greet(name)) .. "!"',
             "text": "    return string.upper(M.greet(name))"},
        ],
    })
    text = open(util).read()
    check("stale chunks across symbols are relocated and applied",
          "tostring(name):lower()" not in text and '.. "!"' not in text
          and "    name = tostring(name)\n" in text
          and len(res.get("relocated", [])) == 2, res)
    # The call's name_path scopes every chunk that names none. A chunk
    # whose match text sits outside that symbol, in exactly one place in
    # the file (the module header here, a const block in Go), is applied
    # there and reported as relocated rather than refused.
    res = b.call("replace_symbol_lines", {
        "file": util, "name_path": "M.shout",
        "chunks": [
            {"match": "local M = {}", "text": "local M = {} -- module"},
            {"match": "return string.upper(M.greet(name))",
             "text": "    return string.upper(M.greet(name)) -- loud"},
        ],
    })
    text = open(util).read()
    check("a chunk matched outside its symbol is applied where the text is",
          "local M = {} -- module" in text and "-- loud" in text
          and any("outside M.shout" in r.get("applied_at", "") for r in res.get("relocated", []))
          and "scoped to" in res.get("relocated_note", ""), res)
    b.call("replace_symbol_lines", {
        "file": util,
        "chunks": [
            {"match": "local M = {} -- module", "text": "local M = {}"},
            {"match": "return string.upper(M.greet(name)) -- loud",
             "text": "    return string.upper(M.greet(name))"},
        ],
    })

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
    # A fragment of a longer line is never found - locate_between only
    # matches whole lines - so the refusal should point at the whole line
    # instead of just saying "nowhere" and sending the caller in a circle.
    try:
        b.call("replace_symbol_lines", {"file": util, "name_path": "M.greet",
                                        "match": "tostring(name):upper", "text": "x"})
        check("match on a line fragment is refused with the whole line", False, "call succeeded")
    except RuntimeError as e:
        check("match on a line fragment is refused with the whole line",
              "part of line" in str(e) and "tostring(name):upper()" in str(e), e)
    # A name_path the file does not have names what it does have, so the
    # caller can fix the name from the refusal instead of going back to
    # find_symbol for it.
    try:
        b.call("replace_symbol_lines", {"file": util, "name_path": "M.greeting",
                                        "match": "name = tostring(name)", "text": "x"})
        check("an unknown name_path names the near misses", False, "call succeeded")
    except RuntimeError as e:
        check("an unknown name_path names the near misses",
              "no symbol named" in str(e) and "M.greet" in str(e), e)
    # Absolute numbers, as read_file reports them: M.greet starts at 6.
    res = b.call("replace_symbol_lines", {
        "file": util, "name_path": "M.greet", "absolute": True,
        "first_line": 7, "last_line": 7, "expect": "name = tostring(name):upper()",
        "text": "    name = tostring(name)",
    })
    check("absolute line numbers",
          res.get("replaced") == "lines 2-2 of M.greet"
          and "tostring(name):upper()" not in open(util).read(), res)

    reset(c)
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
    # A stale symbol-less chunk relocates too, addressing the buffer's own
    # lines: with no name_path there is no declaration to be relative to.
    res = b.call("replace_symbol_lines", {
        "file": util, "absolute": True, "first_line": 3, "last_line": 3,
        "expect": "local M = {}", "text": "local M = {} -- barrel"})
    check("stale symbol-less expect is relocated and applied",
          open(util).read().startswith("local M = {} -- barrel\n")
          and len(res.get("relocated", [])) == 1, res)
    b.call("replace_symbol_lines", {
        "file": util, "match": "local M = {} -- barrel", "text": "local M = {}"})

    # The bytes that landed are echoed on request, and a control
    # character among them is reported without being asked for: text
    # that came through a JSON round trip can carry an escape the
    # caller never meant.
    res = b.call("replace_symbol_lines", {
        "file": util, "match": "local M = {}", "text": "local M = {}", "verify": True})
    check("verify echoes the written bytes", res.get("new_text") == ["local M = {}"], res)
    scratch = os.path.join(root, "bytes.txt")
    with open(scratch, "w") as f:
        f.write("clean\n")
    res = b.call("replace_symbol_lines", {
        "file": scratch, "absolute": True, "first_line": 1, "last_line": 1,
        "text": "a" + chr(0) + "b"})
    check("a control character in the written text is reported",
          "NUL" in (res.get("control_characters") or "")
          and res.get("new_text") == ["a" + chr(0) + "b"], res)
    os.remove(scratch)

    reset(c)
    # An expect= that covers fewer lines than the range is a different
    # mistake from a stale offset, and relocating it would apply the edit to
    # those lines alone - the rest of the range would survive, below the new
    # text. M.greet is three lines; guarding all three with only its first
    # line is refused, and the narrowing is offered instead of being taken.
    before_short = open(util).read()
    try:
        b.call("replace_symbol_lines", {
            "file": util, "name_path": "M.greet", "first_line": 1, "last_line": 3,
            "expect": "function M.greet(name)",
            "text": 'function M.greet(name)\n    return "hi, " .. name\nend',
        })
        check("a short expect is refused, not narrowed", False, "call succeeded")
    except RuntimeError as e:
        token = re.search(r"token=(\d+)", str(e))
        check("a short expect is refused, not narrowed",
              "expect covers 1 line(s)" in str(e) and "cover 3" in str(e)
              and "do start with that text" in str(e)
              and open(util).read() == before_short and token is not None, e)
        if token:
            res = b.call("apply_code_action", {"token": token.group(1), "index": 1})
            check("the refusal offers the narrowing it would not do on its own",
                  res.get("replaced") == "lines 1-1 of M.greet"
                  and 'return "hi, " .. name' in open(util).read(), res)

    reset(c)
    # insert_lines: main.lua starts with a bare require, so there is no
    # symbol to anchor an insert to and nothing but its own text to address
    # its first line by. A guard goes above it by line number.
    res = b.call("insert_lines", {"file": main_lua, "line": 1, "text": "-- guard"})
    check("insert_lines puts text above a line",
          open(main_lua).read().startswith("-- guard\nlocal util")
          and res.get("inserted") == "1 line(s) above line 1", res)
    res = b.call("insert_lines", {"file": main_lua, "at": "end", "text": "-- tail"})
    check("insert_lines appends without knowing the length",
          open(main_lua).read().rstrip().endswith("-- tail"), res)
    # The same text into several files in one call: one guard, a directory
    # of files, no line arithmetic per file.
    res = b.call("insert_lines", {"files": [util, main_lua], "at": "start", "text": "-- top"})
    check("insert_lines covers several files at once",
          res.get("files") == 2 and len(res.get("reports", [])) == 2
          and open(util).read().startswith("-- top\nlocal M")
          and open(main_lua).read().startswith("-- top\n-- guard\n"), res)
    before_insert = open(util).read()
    res = b.call("insert_lines", {"file": util, "line": 2, "text": "-- dry", "dry_run": True})
    check("insert_lines dry_run shows the diff and changes nothing",
          open(util).read() == before_insert
          and any(line.startswith("+") for line in res.get("diff", [])), res)
    try:
        b.call("insert_lines", {"file": util, "line": 999, "text": "x"})
        check("insert_lines refuses a line past the end", False, "call succeeded")
    except RuntimeError as e:
        check("insert_lines refuses a line past the end", "outside the file" in str(e), e)
    b.call("undo_edit", {"all": True})

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

    # A fresh editor, not just fresh files: the checks below count what the
    # undo ledger still holds, so nothing an earlier check left in it may
    # still be there.
    restart(c)
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

    reset(c)
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

    reset(c)
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

    reset(c)
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

    reset(c)
    # Indentation alone is not drift. A format pass that re-indented the
    # region left the same text on the same lines, and refusing there sends
    # the caller to re-read a file that holds exactly what it expected.
    res = b.call("replace_symbol_lines", {
        "file": util, "name_path": "M.greet", "first_line": 1, "last_line": 2,
        "expect": 'function M.greet(name)\nreturn "hello, " .. name',
        "text": 'function M.greet(name)\n    return "hi, " .. name',
    })
    check("expect= ignores indentation",
          res.get("replaced") == "lines 1-2 of M.greet"
          and 'return "hi, " .. name' in open(util).read(), res)

    reset(c)
    # The expected text left the symbol entirely - the symbol shrank, or the
    # code moved - and it is still findable in the file. Relocating there
    # beats telling the caller to re-read a file that already holds it.
    # The relocated chunk drops name_path: buffer numbers outside the
    # symbol would be converted back to offsets and refused for being out
    # of its span.
    res = b.call("replace_symbol_lines", {
        "file": util, "name_path": "M.greet", "first_line": 2, "last_line": 2,
        "expect": "return string.upper(M.greet(name))",
        "text": "    return M.greet(name):upper()",
    })
    moves = res.get("relocated", [])
    check("expect= relocates out of the symbol and applies",
          "return M.greet(name):upper()" in open(util).read()
          and len(moves) == 1
          and moves[0].get("applied_at") == "buffer lines 11-11, outside M.greet", res)

    reset(c)
    # Same for match=: text found once outside the named symbol is edited
    # where it is, and the reply says the symbol it was not in.
    res = b.call("replace_symbol_lines", {
        "file": util, "name_path": "M.greet",
        "match": "return string.upper(M.greet(name))", "text": "    return M.greet(name):upper()",
    })
    moves = res.get("relocated", [])
    check("match found outside the symbol is applied where the text is",
          "return M.greet(name):upper()" in open(util).read()
          and len(moves) == 1 and moves[0].get("named") == "M.greet"
          and moves[0].get("applied_at") == "buffer lines 11-11, outside M.greet", res)

    reset(c)
    # replace_pattern: the same change in many places, where a rename does
    # not apply. dry_run counts without touching anything.
    res = b.call("replace_pattern", {
        "files": [util, main_lua], "pattern": "util.greet",
        "replacement": "util.hello", "literal": True, "dry_run": True,
    })
    check("replace_pattern dry_run counts and changes nothing",
          res.get("total_replacements") == 1 and res.get("dry_run") is True
          and "util.greet" in open(main_lua).read()
          and "util.hello" not in open(main_lua).read(), res)
    res = b.call("replace_pattern", {
        "files": [util, main_lua], "pattern": "util.greet",
        "replacement": "util.hello", "literal": True,
    })
    check("replace_pattern applies and reports a verdict",
          res.get("total_replacements") == 1
          and "util.hello" in open(main_lua).read()
          and res.get("diagnostics_after") is not None, res)
    b.call("undo_edit", {})
    check("replace_pattern is undoable",
          "util.greet" in open(main_lua).read()
          and "util.hello" not in open(main_lua).read(), None)

    reset(c)
    # kind=code is the thing sed cannot do: the only "hello" in util.lua is
    # inside a string literal, so it is left alone with the filter and
    # replaced without it.
    res = b.call("replace_pattern", {
        "files": [util], "pattern": "hello", "replacement": "howdy",
        "literal": True, "kind": "code",
    })
    check("replace_pattern kind=code leaves a string literal alone",
          res.get("total_replacements") == 0 and "left_alone" in res
          and 'return "hello, " .. name' in open(util).read(), res)
    res = b.call("replace_pattern", {
        "files": [util], "pattern": "hello", "replacement": "howdy", "literal": True,
    })
    check("replace_pattern without kind replaces it",
          res.get("total_replacements") == 1
          and 'return "howdy, " .. name' in open(util).read(), res)

    reset(c)
    # A very magic pattern with a group, and a pattern that does not compile.
    res = b.call("replace_pattern", {
        "files": [util], "pattern": "return \"(hello), \"", "replacement": "return \"\\1! \"",
    })
    check("replace_pattern uses very magic groups",
          res.get("total_replacements") == 1
          and 'return "hello! " .. name' in open(util).read(), res)
    try:
        b.call("replace_pattern", {"files": [util], "pattern": "(unclosed", "replacement": "x"})
        check("replace_pattern refuses a bad pattern", False, "call succeeded")
    except RuntimeError as e:
        check("replace_pattern refuses a bad pattern", "does not compile" in str(e), e)
    reset(c)

    # An alternation of lines of code: in very magic mode `=` makes the atom
    # before it optional, so the branch holding one matches nothing while
    # the reply still reports the files the other branch matched. Each
    # branch is counted, and a dead one is named with the reason.
    res = b.call("replace_pattern", {
        "files": [main_lua], "pattern": "local util = require|print\\(util.greet",
        "replacement": "-- gone", "dry_run": True,
    })
    alts = res.get("alternatives", [])
    check("replace_pattern counts each alternative and names the dead ones",
          [a.get("matches") for a in alts] == [0, 1]
          and "1 of the 2 alternatives matched nothing" in res.get("alternatives_note", "")
          and "optional" in res.get("alternatives_note", ""), res)
    # The same explanation for a single pattern that matched nothing at all.
    res = b.call("replace_pattern", {
        "files": [main_lua], "pattern": "local util = require",
        "replacement": "-- gone", "dry_run": True,
    })
    check("a very magic pattern that matched nothing says what it did instead",
          res.get("total_replacements") == 0
          and "optional" in (res.get("hint") or "")
          and "literal=true" in (res.get("hint") or ""), res)
    # literal=true takes the same text as bytes and matches it.
    res = b.call("replace_pattern", {
        "files": [main_lua], "pattern": "local util = require",
        "replacement": "local util = require", "literal": True, "dry_run": True,
    })
    check("literal=true matches the line the regex could not",
          res.get("total_replacements") == 1 and res.get("alternatives") is None, res)
    reset(c)

    # A name two declarations share (Stack.push and Queue.push) is not a
    # refusal when the chunk says which: its match text sits in one of them
    # only. The same name with text both hold is still ambiguous.
    pair = os.path.join(root, "lua", "testproj", "pair.lua")
    with open(pair, "w") as f:
        f.write("local Stack = {\n"
                "    push = function(self, item)\n"
                "        self.items[#self.items + 1] = item\n"
                "        return self\n"
                "    end,\n"
                "}\n"
                "local Queue = {\n"
                "    push = function(self, item)\n"
                "        table.insert(self.items, 1, item)\n"
                "        return self\n"
                "    end,\n"
                "}\n"
                "return { Stack = Stack, Queue = Queue }\n")
    res = b.call("replace_symbol_lines", {
        "file": pair, "name_path": "push",
        "match": "        table.insert(self.items, 1, item)",
        "text": "        table.insert(self.items, item)",
    })
    text = open(pair).read()
    check("a shared name is settled by the chunk's match text",
          "table.insert(self.items, item)" in text
          and "self.items[#self.items + 1] = item" in text, res)
    try:
        b.call("replace_symbol_lines", {
            "file": pair, "name_path": "push",
            "match": "        return self", "text": "        return nil",
        })
        check("a shared name with text both hold is still ambiguous", False, "call succeeded")
    except RuntimeError as e:
        check("a shared name with text both hold is still ambiguous",
              "ambiguous" in str(e) and "Stack/push" in str(e) and "Queue/push" in str(e), e)

    # A guessed path that does not exist: the refusal names the files that
    # share its basename, so the next call is the right one.
    try:
        b.call("replace_symbol_lines", {
            "file": os.path.join(root, "lua", "util.lua"),
            "match": "x", "text": "y",
        })
        check("a missing file names its namesakes", False, "call succeeded")
    except RuntimeError as e:
        check("a missing file names its namesakes",
              "no such file" in str(e) and "lua/testproj/util.lua" in str(e), e)
    reset(c)


def group_verdict(c):
    """What an edit reports afterwards: new, pre-existing and fixed
    diagnostics, the wait for them, deferred verdicts and undo_edit."""
    b, root, work = c.b, c.root, c.work
    util, main_lua, tools = c.util, c.main_lua, c.tools

    reset(c)
    # The pre-existing diagnostics are listed once, then reported as
    # unchanged until they change or full_diagnostics asks again.
    # The first reply about this file lists them, whatever it is, so the
    # pair below starts from a listing that has already gone out.
    b.call("replace_symbol_lines", {
        "file": util, "name_path": "M.greet", "first_line": 2, "last_line": 2,
        "text": "    name = tostring(name) -- listed",
    })
    res = b.call("replace_symbol_lines", {
        "file": util, "name_path": "M.greet", "first_line": 2, "last_line": 2,
        "text": "    name = tostring(name) -- again",
    })
    res2 = b.call("replace_symbol_lines", {
        "file": util, "name_path": "M.greet", "first_line": 2, "last_line": 2,
        "text": "    name = tostring(name)",
    })
    check("preexisting diagnostics reported as unchanged",
          res2.get("preexisting") is None or "none new to this list" in res2.get("preexisting"), res2)
    check("an unchanged list is not listed again",
          "preexisting_new_to_list" not in res2 and "preexisting_list" not in res2, res2)
    res3 = b.call("replace_symbol_lines", {
        "file": util, "name_path": "M.greet", "first_line": 2, "last_line": 2,
        "text": "    name = tostring(name)", "full_diagnostics": True,
    })
    check("full_diagnostics lists them again",
          res3.get("preexisting") is None
          or ("all listed" in res3.get("preexisting") and isinstance(res3.get("preexisting_list"), list)), res3)

    # A fresh editor, not just fresh files: the undo checks below count what
    # the ledger holds, and the timings compare edits made in one session.
    restart(c)
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
    # The error the earlier edit planted is new to the pre-existing list,
    # so it is named this once (with its file), and not on the next reply.
    check("an entry new to the list is named once",
          any("nme" in d and "util" in d for d in res.get("preexisting_new_to_list", [])), res)
    res = b.call("replace_symbol_lines", {
        "file": util, "name_path": "M.shout", "first_line": 2, "last_line": 2,
        "text": '    return string.upper(M.greet(name)) -- again',
    })
    check("then it is a count",
          "none new to this list" in res.get("preexisting", "") and "preexisting_new_to_list" not in res, res)
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

    # Formatting is opt-in. Without format= the text lands byte for
    # byte, odd spacing included; with format="range" the server's
    # formatter straightens it and the reply says so.
    ugly = "function M.ugly(x)\n        return x   +  1\nend"
    res = b.call("insert_after_symbol", {"file": util, "name_path": "M.shout", "text": ugly})
    with open(util) as f:
        on_disk = f.read()
    check("no formatting unless asked",
          ugly in on_disk and "formatted" not in res.get("polished", ""), res)
    b.call("undo_edit", {})
    res = b.call("insert_after_symbol", {"file": util, "name_path": "M.shout",
                                         "text": ugly, "format": "range"})
    with open(util) as f:
        on_disk = f.read()
    check("format=range runs the formatter",
          ugly not in on_disk and "return x + 1" in on_disk
          and "formatted" in res.get("polished", ""), res)
    # The reply says where the written text is, not how far the ledger
    # reaches, and shows what the formatter changed instead of leaving
    # the caller to find out with git diff.
    span = [int(n) for n in res.get("lines", "0").split("-")]
    check("a formatted edit reports its own span",
          len(span) == 2 and span[0] > 1 and span[1] - span[0] < 6, res)
    check("a formatted edit shows the formatter's diff",
          any("return x" in line for line in res.get("polish_diff", [])), res)
    b.call("undo_edit", {})

    # The two timings below are compared with each other, so the session has
    # to be past the point where every edit still costs the configured
    # settle: agent99 learns each server's publish lag from a few edits that
    # actually change the diagnostics, and waits for that afterwards.
    for _ in range(4):
        b.call("replace_symbol_lines", {"file": util, "name_path": "M.greet",
                                        "first_line": 2, "last_line": 2,
                                        "text": '    return "hello, " .. nme'})
        b.call("replace_symbol_lines", {"file": util, "name_path": "M.greet",
                                        "first_line": 2, "last_line": 2,
                                        "text": '    return "hello, " .. name'})
    # A clean edit must not idle out post_edit.wait_ms (4 s): lua_ls
    # publishes nothing when the diagnostics did not change, and the
    # barrier request sent with the edit is what lets the wait end.
    t0 = time.time()
    res = b.call("insert_after_symbol", {"file": util, "name_path": "M.shout",
                                         "text": "function M.quick() return 2 end"})
    waited = time.time() - t0
    check("clean edit returns well before the ceiling",
          waited < 2.5 and res.get("diagnostics_after") == "no new errors or warnings",
          "%.2fs %s" % (waited, res))
    b.call("undo_edit", {})

    # wait=false: the edit returns as soon as the text is in, and the
    # verdict rides on the next reply, whatever tool produces it. Measured
    # against the edit above rather than against a fixed number of
    # milliseconds, because how long a server takes to answer depends on the
    # server, the machine and how much of the session it has already seen.
    t0 = time.time()
    res = b.call("replace_symbol_lines", {
        "file": util, "name_path": "M.greet", "first_line": 2, "last_line": 2,
        "text": '    return "hello, " .. nme', "wait": False,
    })
    took = time.time() - t0
    # Clearly under the waiting edit rather than a fixed fraction of it: an
    # edit that stopped deferring would take about as long as that one, and
    # the machine may be running the other groups at the same time.
    check("wait=false returns without waiting for the verdict",
          took < waited * 0.75 and "deferred" in str(res.get("diagnostics_after")),
          "%.2fs against %.2fs waited %s" % (took, waited, res))
    res = b.call("find_symbol", {"name": "M.greet", "file": util})
    check("a reply before the verdict is in says so",
          "still_pending" in res and "deferred_verdicts" not in res, res)
    time.sleep(0.6)
    res = b.call("find_symbol", {"name": "M.greet", "file": util})
    verdicts = res.get("deferred_verdicts") or []
    check("deferred verdict comes with the next reply",
          len(verdicts) == 1 and "util.lua" in verdicts[0].get("edit", "")
          and any("nme" in d for d in verdicts[0].get("diagnostics_after", [])), res)
    res = b.call("find_symbol", {"name": "M.greet", "file": util})
    check("a delivered verdict is not repeated", "deferred_verdicts" not in res, res)
    # A reply produced outside the editor carries it too.
    b.call("replace_symbol_lines", {
        "file": util, "name_path": "M.greet", "first_line": 2, "last_line": 2,
        "text": '    return "hello, " .. nme .. "?"', "wait": False,
    })
    time.sleep(0.6)
    reply = b.rpc("tools/call", {"name": "grep", "arguments": {"pattern": "nme", "path": root}})
    text = reply["result"]["content"][0]["text"]
    check("grep reply carries the owed verdict",
          "from earlier edits:" in text and "deferred_verdicts" in text
          and text.index("nme") < text.index("from earlier edits:"), text)
    # Two deferred edits, then an edit that must take a snapshot: the owed
    # verdicts are settled first so nothing is charged to the wrong edit.
    b.call("replace_symbol_lines", {
        "file": util, "name_path": "M.greet", "first_line": 2, "last_line": 2,
        "text": '    return "hello, " .. name', "wait": False,
    })
    res = b.call("replace_symbol_lines", {
        "file": util, "name_path": "M.shout", "first_line": 2, "last_line": 2,
        "text": '    return M.greet(name):upper() .. "!"',
    })
    verdicts = res.get("deferred_verdicts") or []
    check("an owed verdict is settled before the next edit's snapshot",
          len(verdicts) == 1 and "fixed" in verdicts[0]
          and res.get("diagnostics_after") == "no new errors or warnings", res)
    b.call("undo_edit", {"all": True})


def group_search(c):
    """grep and list_files: annotation, path globs, the tests= and kind=
    filters."""
    b, root, work = c.b, c.root, c.work
    util, main_lua, tools = c.util, c.main_lua, c.tools

    reset(c)
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


def group_files(c):
    """Files as whole things: created, moved, deleted, split with
    move_symbols, and changed behind the editor's back."""
    b, root, work = c.b, c.root, c.work
    util, main_lua, tools = c.util, c.main_lua, c.tools

    reset(c)
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

    reset(c)
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

    reset(c)
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

    # A file created through the tools has to be analyzed like any other,
    # in a second workspace with a language server that has more to say
    # than lua_ls. gopls answers "No packages found for open file" for a
    # file it is told about with workspace/didCreateFiles before it has
    # seen the document, and keeps answering it, so a regression there
    # leaves every created Go file silently unchecked.
    if shutil.which("gopls"):
        goroot = os.path.join(work, "goproj")
        shutil.copytree(os.path.join(REPO, "tests", "debugproj"), goroot)
        b.call("open_workspace", {"root": goroot})
        res = b.call("create_file", {
            "file": os.path.join(goroot, "broken.go"),
            "text": "package main\n\nfunc Broken() int {\n\treturn accumulate(1, 2)\n}\n",
        })
        after = res.get("diagnostics_after")
        check("a created Go file is analyzed by gopls",
              isinstance(after, list)
              and any("accumulate" in line for line in after), res)
        # A Go file written by another tool (a plain Write, a heredoc) is
        # one no server hears of: Neovim registers no file watcher on
        # Linux, so gopls goes on calling the name it defines undefined
        # while the build passes. The resync before an edit is judged has
        # to relay the new file, or the error stays "pre-existing" forever.
        res = b.call("replace_symbol_lines", {
            "file": os.path.join(goroot, "main.go"), "name_path": "main",
            "match": '\tfmt.Println("debugproj: start")',
            "text": '\tfmt.Println("debugproj: start", localHostName())',
        })
        after = res.get("diagnostics_after")
        check("a use before the definition is an error",
              isinstance(after, list) and any("localHostName" in line for line in after), res)
        with open(os.path.join(goroot, "host.go"), "w") as f:
            f.write("package main\n\nimport \"os\"\n\nfunc localHostName() string {\n"
                    "\th, _ := os.Hostname()\n\treturn h\n}\n")
        res = b.call("replace_symbol_lines", {
            "file": os.path.join(goroot, "main.go"), "name_path": "main",
            "match": '\tfmt.Fprintln(os.Stderr, "debugproj: stderr line")',
            "text": '\tfmt.Fprintln(os.Stderr, "debugproj: stderr line 2")',
        })
        check("a file written by another tool reaches the server",
              "fixed" in res
              and not any("localHostName" in d for d in res.get("preexisting_new_to_list", [])), res)
        diags = b.call("diagnostics", {"file": os.path.join(goroot, "main.go")})
        check("and the stale error is gone",
              not any("localHostName" in d.get("message", "") for d in diags.get("diagnostics", [])), diags)
        b.call("close_workspace", {"root": goroot})


def group_tests(c):
    """run_tests: the runner is guessed, failures come back with their test
    symbol, and a rerun reports what changed against the baseline."""
    b, work = c.b, c.work
    if not shutil.which("go"):
        return
    goroot = os.path.join(work, "gotests")
    os.makedirs(goroot)
    with open(os.path.join(goroot, "go.mod"), "w") as f:
        f.write("module scratch\n\ngo 1.22\n")
    with open(os.path.join(goroot, "calc.go"), "w") as f:
        f.write("package scratch\n\nfunc Add(a, b int) int { return a + b }\n\n"
                "func Mul(a, b int) int { return a*b + 1 }\n")
    with open(os.path.join(goroot, "calc_test.go"), "w") as f:
        f.write("package scratch\n\nimport \"testing\"\n\n"
                "func TestAdd(t *testing.T) {\n\tif Add(2, 2) != 4 {\n\t\tt.Fatal(\"add\")\n\t}\n}\n\n"
                "func TestMul(t *testing.T) {\n\tif got := Mul(3, 3); got != 9 {\n"
                "\t\tt.Fatalf(\"Mul(3,3) = %d, want 9\", got)\n\t}\n}\n")
    b.call("open_workspace", {"root": goroot})
    res = b.call("run_tests", {"workspace": goroot})
    fails = res.get("failures", [])
    check("run_tests guesses go test and parses the failure",
          res.get("command") == "go test ./..." and res.get("guessed") is True
          and len(fails) == 1 and fails[0].get("test") == "TestMul"
          and fails[0].get("file") == "calc_test.go" and fails[0].get("line") == 13
          and fails[0].get("symbol") == "TestMul" and "baseline" in res, res)
    res = b.call("run_tests", {"workspace": goroot, "filter": "TestAdd"})
    check("run_tests filter narrows to one test",
          "-run 'TestAdd'" in res.get("command", "") and res.get("exit") == 0
          and res.get("summary", "").startswith("all passing"), res)
    # Fix the bug through the tools; the rerun reports the test as fixed.
    b.call("replace_symbol_lines", {
        "file": os.path.join(goroot, "calc.go"), "name_path": "Mul",
        "match": "func Mul(a, b int) int { return a*b + 1 }",
        "text": "func Mul(a, b int) int { return a * b }",
    })
    res = b.call("run_tests", {"workspace": goroot})
    check("run_tests reports the fixed test against the baseline",
          res.get("exit") == 0 and res.get("fixed") == ["TestMul"]
          and res.get("new_failures") == [] and "1 fixed" in res.get("summary", ""), res)
    res = b.call("run_tests", {"workspace": goroot, "command": "go test -count=1 ./...", "remember": True})
    check("run_tests remembers an explicit command", "remembered" in res, res)
    res = b.call("run_tests", {"workspace": goroot})
    check("run_tests uses the remembered command",
          res.get("command") == "go test -count=1 ./..." and res.get("guessed") is None, res)
    b.call("close_workspace", {"root": goroot})


def group_lifecycle(c):
    """The headless instance ends with the workspace and with the server."""
    b, root, work = c.b, c.root, c.work
    util, main_lua, tools = c.util, c.main_lua, c.tools

    reset(c)
    res = b.call("close_workspace", {})
    check("close_workspace", res.get("closed") == [os.path.realpath(root)], res)
    for _ in range(30):
        if not os.path.exists("/proc/%d" % c.pid):
            break
        time.sleep(0.1)
    check("nvim stopped", not os.path.exists("/proc/%d" % c.pid), c.pid)

    # Reopen, then let the server exit: the instance must die with it.
    res = b.call("open_workspace", {"root": root})
    c.pid = res["pid"]
    b.close()
    for _ in range(50):
        if not os.path.exists("/proc/%d" % c.pid):
            break
        time.sleep(0.1)
    check("nvim dies with the server", not os.path.exists("/proc/%d" % c.pid), c.pid)


GROUPS = [
    ("workspace", group_workspace),
    ("index", group_index),
    ("edit", group_edit),
    ("verdict", group_verdict),
    ("search", group_search),
    ("files", group_files),
    ("tests", group_tests),
    ("lifecycle", group_lifecycle),
]


def main(argv=None):
    names = [name for name, _ in GROUPS]
    wanted = list(argv or names)
    for name in wanted:
        if name not in names:
            print("unknown group '%s' (known: %s)" % (name, " ".join(names)))
            sys.exit(2)
    # Canonical order whatever order they were asked for: the workspace
    # group has the checks that need no workspace open yet, and the
    # lifecycle group ends the instance.
    selected = [name for name in names if name in wanted]

    # Groups share nothing, so several of them run at once: each is a
    # process with its own bridge, its own headless Neovim and its own copy
    # of the project. One group runs here instead, so that debugging it is
    # a plain run with the output as it happens. AGENT99_TEST_JOBS=1 forces
    # that for the whole suite.
    if len(selected) > 1:
        sys.exit(run_groups(selected))
    run_group(selected[0])
    # A group spawned by a parallel run says nothing about the run as a
    # whole; the process that spawned it reports that.
    if not os.environ.get("AGENT99_TEST_CHILD"):
        print(report_line(selected, names))


def jobs_limit(count):
    asked = os.environ.get("AGENT99_TEST_JOBS", "")
    if asked.isdigit() and int(asked) > 0:
        return min(count, int(asked))
    return min(count, 4)


def run_groups(selected):
    """Run each group in its own process, report them in the order asked
    for, and fail if any of them did."""
    limit = jobs_limit(len(selected))
    if limit == 1:
        for name in selected:
            run_group(name)
        print(report_line(selected, [name for name, _ in GROUPS]))
        return 0
    env = dict(os.environ, AGENT99_TEST_CHILD="1")
    running, pending, failed = [], list(selected), []
    while pending or running:
        while pending and len(running) < limit:
            name = pending.pop(0)
            running.append((name, subprocess.Popen(
                [sys.executable, os.path.abspath(__file__), name], env=env,
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)))
        name, proc = running.pop(0)
        out, _ = proc.communicate()
        sys.stdout.write(out)
        sys.stdout.flush()
        if proc.returncode != 0:
            failed.append(name)
    if failed:
        print("headless: FAILED (%s)" % " ".join(failed))
        return 1
    print(report_line(selected, [name for name, _ in GROUPS]))
    return 0


def report_line(selected, names):
    if selected == names:
        return "headless: OK"
    return ("headless (%s): OK - partial run, the whole suite is "
            "tests/smoke.sh headless" % " ".join(selected))


def run_group(name):
    env = {k: v for k, v in os.environ.items() if k not in ("AGENT99_NVIM", "NVIM")}
    env["AGENT99_HEADLESS_INIT"] = os.path.join(REPO, "tests", "minimal_init.lua")
    work = tempfile.mkdtemp(prefix="agent99-headless-")
    root = os.path.join(work, "proj")
    shutil.copytree(PROJ, root)
    seed(root)

    # Started in the scratch tree: nothing above it is a project, so the
    # server has no working directory to auto-open, and a group controls
    # its own workspace.
    b = Bridge(env=env, cwd=work)
    c = Context(b, work, root)
    try:
        b.rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                             "clientInfo": {"name": "drive_headless", "version": "0"}})
        c.tools = {t["name"] for t in b.rpc("tools/list")["result"]["tools"]}
        if name != "workspace":
            restart(c)
        dict(GROUPS)[name](c)
    finally:
        try:
            b.proc.kill()
        except Exception:
            pass
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    main(sys.argv[1:])
