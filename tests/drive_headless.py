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

import json
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

# A source file under a leading-dot directory: the shape of a monorepo that
# vendors its dependencies under `.repos/`, where the searchers used to skip
# 11,110 of 13,374 files the census had just counted. Written by the checks
# that need it rather than kept in tests/testproj, so every other check still
# sees the project's usual shape.
VENDORED_REL = os.path.join("scripts", ".vendored", "vendorlib.lua")


def seed_dot_directory(root):
    path = os.path.join(root, VENDORED_REL)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write("local V = {}\n"
                "\n"
                "function V.vendored_only_symbol(x)\n"
                "    return x\n"
                "end\n"
                "\n"
                "return V\n")
    return path



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
    # scripts/lint has no extension and a bash shebang. Reported as no
    # language at all, its shell tooling looks absent rather than covered.
    check("a shebang names the language of an extension-less script",
          "sh" in langs or "bash" in langs, langs)

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
    # The reply has to say which store the command went into: "kept for this
    # session" and "stored on disk" are different promises.
    check("check_project remember", "later sessions" in res.get("remembered", ""), res)
    b.call("close_workspace", {})
    res = b.call("open_workspace", {"root": root})
    c.pid = res["pid"]
    res = b.call("check_project", {})
    check("remembered command survives a workspace restart",
          res.get("remembered", "").startswith("using the command stored")
          and res.get("output") == ["one", "three"], res)
    # A command that cannot run on this machine says nothing about the project
    # and must not be stored for the root, where it would poison every later
    # bare call in this session and the next.
    res = b.call("check_project",
                 {"command": "agent99-no-such-checker --all", "remember": True})
    check("a command that is not installed is not remembered",
          "not_remembered" in res and "did_not_run" in res
          and "remembered" not in res, res)
    res = b.call("check_project", {})
    check("the failed command did not become this root's default",
          res.get("command") == cmd, res)

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
        # A list of scalars, deliberately: it is the case this check is for,
        # a long file whose whole outline is one line. A list of mappings is
        # indexed item by item now, so its outline is not trivial and
        # read_file answers with the structure, which is the right answer for
        # a different file.
        with open(big, "w") as f:
            f.write("items:\n" + "".join("  - item%d\n  - spare%d\n" % (i, i) for i in range(300)))
        r = b.rpc("tools/call", {"name": "read_file", "arguments": {"path": big}})
        text = r["result"]["content"][0]["text"]
        check("read_file returns text when the outline is trivial",
              "1: items:" in text and "600: " in text, text[:120])
        # And says why: the rule is documented in lines, so a file over the
        # threshold that comes back as text has to account for itself.
        check("a long file read as text says the outline rule could not fire",
              text.startswith("note: this file has 601 lines, over the 400 at which")
              and "nothing could outline it" in text, text[:200])
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
    # The map lists one level into a declaration by design, and it used to
    # count only as far as it listed: a file whose headings go deeper was
    # neither listed nor counted below that level, so its entry carried no
    # note and read as complete. The listing is unchanged; the count is the
    # whole file's.
    deepmd = os.path.join(root, "deep.md")
    with open(deepmd, "w") as f:
        f.write("# Top\n\n## One\n\n### Two\n\n#### Three\n\n##### Four\n\n"
                "## Five\n\n### Six\n")
    res = b.call("workspace_map", {"glob": "deep.md"})
    entry = res["files"][0]
    check("the map counts the declarations below the level it lists",
          len(entry.get("outline", [])) == 4
          and entry["outline"][:3] == ["1: # Top", "  3: ## One", "  11: ## Five"]
          and "+4 more declarations (3 of 7 shown)" in entry["outline"][3]
          and "the map goes 2 level(s) into a file" in entry["outline"][3], entry)
    os.remove(deepmd)

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
    # A directory line used to be emitted whether or not the budget had room
    # for it, and the summary line a partly-listed directory still needs was
    # spent by then: one more directory in the tree turned budget=5 into six
    # lines. The budget is a promise about the size of the reply, so it is
    # checked at the size where it used to break.
    extra_dir = os.path.join(root, "vendor", "thirdparty")
    os.makedirs(extra_dir, exist_ok=True)
    with open(os.path.join(extra_dir, "dep.lua"), "w") as f:
        f.write("local D = {}\n\nfunction D.dep() end\n\nreturn D\n")
    for budget in (5, 6, 7, 8):
        res = b.call("workspace_tree", {"budget": budget})
        check("workspace_tree honours budget=%d with one more directory" % budget,
              len(res.get("tree", [])) <= budget, res)
    # And the "+N more files" line says what it is N of.
    res = b.call("workspace_tree", {"budget": 12})
    more = [l for l in res.get("tree", []) if "more files" in l]
    check("the omitted-files note names shown and total",
          all(re.search(r"… \+(\d+) more files \((\d+) of (\d+) shown\)", l)
              and int(re.search(r"\((\d+) of (\d+) shown\)", l).group(2))
              - int(re.search(r"\((\d+) of (\d+) shown\)", l).group(1))
              == int(re.search(r"\+(\d+) more", l).group(1))
              for l in more), res)
    os.remove(os.path.join(extra_dir, "dep.lua"))
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

    # A constant whose value spans several lines. Some servers report a
    # variable by the range of its name alone (pyright does), and a one-line
    # symbol for an eight-line dict is a rewrite that orphans the rest of it.
    fixtures = os.path.join(root, "lua", "testproj", "fixtures.lua")
    with open(fixtures, "w") as f:
        f.write("local RESPONSES = {\n"
                '    login_ok = "logged in",\n'
                '    login_bad = "try again",\n'
                '    gone = "not here",\n'
                "}\n"
                "\n"
                "return RESPONSES\n")
    # The same shape in Python, where the server (pyright) reports a variable
    # by the range of its name alone. A file that declares no function has no
    # treesitter entries at all, so its symbols come from the server unmerged
    # - the path the first version of this fix missed.
    pyconst = os.path.join(root, "lua", "testproj", "constants.py")
    with open(pyconst, "w") as f:
        f.write("RESPONSES = {\n"
                '    "ok": "fine",\n'
                '    "bad": "nope",\n'
                "}\n"
                "\n"
                "TIMEOUT = 30\n")
    res = b.call("find_symbol", {"file": pyconst, "name": "RESPONSES", "include_body": True})
    match = (res.get("matches") or [{}])[0]
    if not match.get("body"):
        print("SKIP python constant check: no python server under the test config")
    else:
        check("a python multi-line constant carries its whole value",
              match.get("lines") == "1-4" and len(match["body"]) == 4
              and match["body"][-1].endswith("}"), res)
        res2 = b.call("find_symbol", {"file": pyconst, "name": "TIMEOUT", "include_body": True})
        m2 = (res2.get("matches") or [{}])[0]
        check("a python scalar constant stays one line", m2.get("lines") == "6-6", res2)
    os.remove(pyconst)

    res = b.call("find_symbol", {"file": fixtures, "name": "RESPONSES", "include_body": True})
    match = (res.get("matches") or [{}])[0]
    body = match.get("body") or []
    if not body:
        print("SKIP multi-line constant check: no symbol for RESPONSES")
    else:
        check("a multi-line constant carries its whole value",
              match.get("lines") == "1-5" and len(body) == 5
              and body[-1].endswith("}"), res)
        res = b.call("replace_symbol_body", {
            "file": fixtures, "name_path": "RESPONSES",
            "body": 'local RESPONSES = { login_ok = "logged in" }', "dry_run": True})
        removed = [l for l in res.get("diff", []) if l.startswith("-")]
        check("rewriting it replaces the whole value, not its first line",
              len(removed) == 5, res)
    os.remove(fixtures)

    # A file whose only declaration is a top-level const had no outline at
    # all, so it had no line in the map either: a Go config sample or MIME
    # table simply was not there.
    goconst = os.path.join(root, "sample.go")
    with open(goconst, "w") as f:
        f.write("package sample\n"
                "\n"
                "const sampleConfig = `\n"
                "listen = 8080\n"
                "`\n"
                "\n"
                "func use() string {\n"
                "\tlocalVar := sampleConfig\n"
                "\treturn localVar\n"
                "}\n")
    res = b.call("workspace_map", {"glob": "sample.go"})
    entry = next((f for f in res.get("files", []) if f["file"].endswith("sample.go")), None)
    if entry is None or "no treesitter parser" in str(res.get("notes") or ""):
        print("SKIP go const check: sample.go not mapped")
    else:
        outline = entry.get("outline") or []
        check("a file whose only declaration is a const is outlined",
              any("sampleConfig" in line for line in outline)
              and any("func use" in line for line in outline)
              and not any("localVar" in line for line in outline), res)
    os.remove(goconst)

    # The test-file count belongs to the files the call asked about: a glob
    # over one directory used to report the whole repository's tests.
    res = b.call("workspace_map", {"glob": "lua/testproj/*.lua", "include_tests": False})
    mapped = [f["file"] for f in res.get("files", [])]
    notes = " ".join(res.get("notes") or [])
    check("the test-file count is scoped to the glob",
          all("_test" not in f for f in mapped)
          and ("1 test files left out" in notes or "test files left out" not in notes), res)

    # A QML file is an object tree: the Items, properties and signals are
    # most of what it declares, and outlining only its JS functions summed a
    # 1400-line component up as 34 function names.
    qml = os.path.join(root, "Panel.qml")
    with open(qml, "w") as f:
        f.write("import QtQuick\n"
                "\n"
                "Item {\n"
                "    id: root\n"
                "\n"
                "    property string label: \"\"\n"
                "    signal ready(string text)\n"
                "\n"
                "    function refresh() {\n"
                "        root.label = \"x\"\n"
                "    }\n"
                "\n"
                "    Rectangle {\n"
                "        color: \"black\"\n"
                "    }\n"
                "}\n")
    res = b.call("workspace_map", {"glob": "Panel.qml"})
    mapped = next((f for f in res.get("files", []) if f["file"].endswith("Panel.qml")), None)
    if mapped and mapped.get("outline"):
        check("the map descends into a QML object",
              len(mapped["outline"]) > 1
              and any("property string label" in line for line in mapped["outline"]), res)
    res = b.call("skim", {"files": [qml]})
    entry = res["files"][0]
    outline = entry.get("outline", [])
    if "no treesitter parser" in (entry.get("note") or ""):
        print("SKIP qml checks: no qmljs parser under the test config")
    else:
        check("skim outlines QML objects, properties and signals",
              any("Item {" in line for line in outline)
              and any("property string label" in line for line in outline)
              and any("signal ready" in line for line in outline)
              and any("function refresh" in line for line in outline)
              and any("Rectangle {" in line for line in outline), res)
    os.remove(qml)

    # A callback that is one expression declares nothing worth an outline
    # entry; one with a statement block still does.
    tsx = os.path.join(root, "widget.js")
    with open(tsx, "w") as f:
        f.write("const setPrompt = useStore((store) => store.setPrompt);\n"
                "const addImage = useStore((store) => store.addImage);\n"
                "\n"
                "describe('widget', () => {\n"
                "    it('renders', () => {\n"
                "        expect(1).toBe(1);\n"
                "    });\n"
                "});\n"
                "\n"
                "function render() {\n"
                "    return null;\n"
                "}\n")
    res = b.call("skim", {"files": [tsx]})
    entry = res["files"][0]
    outline = entry.get("outline", [])
    if "no treesitter parser" in (entry.get("note") or ""):
        print("SKIP javascript checks: no javascript parser under the test config")
    else:
        check("a one-expression callback is not a declaration",
              not any("store.setPrompt" in line for line in outline)
              and any("function render" in line for line in outline)
              and any("describe(" in line for line in outline), res)
    os.remove(tsx)

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
    # A helper declared in a test file is used by tests and by nothing else
    # by design. Dropping test references there reported every test fixture
    # in a repository as dead - 30 of one project's 72 findings.
    test_file = os.path.join(root, "lua", "testproj", "util_test.lua")
    res = b.call("unreferenced_symbols", {"file": test_file})
    names = [s["name"] for s in res.get("unreferenced", [])]
    check("a helper used only by its own test file is not a finding",
          "test_greet" not in names, res)
    # Settings on an object the file did not declare are not declarations:
    # 24 of 27 findings in a Neovim configuration were `vim.opt.*` lines.
    settings = os.path.join(root, "lua", "testproj", "settings.lua")
    with open(settings, "w") as f:
        f.write("vim.opt.number = true\n"
                "vim.opt.tabstop = 4\n"
                "vim.g.mapleader = ' '\n"
                "\n"
                "function orphan_helper()\n"
                "    return 1\n"
                "end\n")
    res = b.call("unreferenced_symbols", {"file": settings})
    names = [s["name"] for s in res.get("unreferenced", [])]
    check("a setting on a foreign object is not reported as unreferenced",
          not any(n.startswith("vim.") for n in names)
          and any("orphan_helper" in n for n in names), res)
    # Each skip reason carries its own justification: one sentence about
    # methods and receivers used to explain locals too, which is nonsense on
    # a module of plain functions.
    check("what was skipped is counted and named",
          res.get("symbols_skipped", 0) >= 3
          and "fields on an object this file does not declare"
          in res.get("symbols_skipped_note", ""), res)
    os.remove(settings)
    # A file holding nothing this tool checks used to come back with
    # "every top-level symbol in these files is referenced somewhere else"
    # and symbols_checked: 0 - an all-clear over a file nothing had looked
    # at. The reply has to state that instead of asserting anything.
    only_fields = os.path.join(root, "lua", "testproj", "only_fields.lua")
    with open(only_fields, "w") as f:
        f.write("vim.opt.number = true\n"
                "vim.opt.tabstop = 4\n")
    res = b.call("unreferenced_symbols", {"file": only_fields})
    check("a file with nothing to check says nothing was checked",
          res.get("symbols_checked") == 0
          and res.get("summary", "").startswith("nothing was checked")
          and "referenced somewhere else" not in res.get("summary", ""), res)
    os.remove(only_fields)

    reset(c)
    seed_dot_directory(root)
    # find_symbol used to skip every leading-dot directory while the census
    # counted the files in it, and then said so as a fact: "no file under
    # <root> mentions X". The sentence is the finding here - an error is a
    # plausible-looking reply, so a check that only catches the exception
    # passes against the bug.
    err_text = ""
    try:
        res = b.call("find_symbol", {"name": "vendored_only_symbol"})
    except RuntimeError as e:
        res, err_text = {}, str(e)
    check("find_symbol reaches a symbol declared under a leading-dot directory",
          res.get("count", 0) >= 1
          and any("scripts/.vendored/vendorlib.lua" in m.get("file", "")
                  for m in res.get("matches", [])), res or err_text)
    check("and does not claim no file mentions it",
          "mentions" not in err_text, err_text)
    # The same through a glob: expand_glob walked with globpath, whose "*"
    # skips a leading dot, so a glob could not reach the directory either.
    res = b.call("find_symbol", {"name": "vendored_only_symbol", "glob": "**/*.lua"})
    check("a glob reaches it too",
          res.get("count", 0) >= 1, res)
    # unreferenced_symbols' file universe is the same glob expansion, so its
    # cap note read as precise while being measured against a fraction of
    # the tree. A symbol nothing calls, in a directory nothing walked, is
    # exactly the case that ends in a deletion.
    res = b.call("unreferenced_symbols", {"glob": "**/*.lua"})
    names = [s["name"] for s in res.get("unreferenced", [])]
    check("unreferenced_symbols examines files under a leading-dot directory",
          any("vendored_only_symbol" in n for n in names), res)

    # Setext headings ("Title" over "====") are valid CommonMark and the
    # grammar opens no section for them, so the heading above them ran to the
    # end of the document: a replace_symbol_body on what looked like a
    # four-line preamble would have overwritten 5,261 lines.
    doc = os.path.join(root, "setext.md")
    with open(doc, "w") as f:
        f.write("# Handbook\n\nIntro paragraph.\n\n"
                "Setext Level One\n================\n\nBody under a setext H1.\n\n"
                "Setext Level Two\n----------------\n\nBody under a setext H2.\n\n"
                "## Paths\n\nTail.\n")
    res = b.call("skim", {"files": [doc]})
    outline = res["files"][0].get("outline", [])
    check("skim indexes a setext heading",
          any("Setext Level One" in line for line in outline), res)
    check("and the ATX heading above it no longer runs to the end of the file",
          any(line.startswith("1-3: ") and "# Handbook" in line for line in outline), res)
    check("and the heading tree nests by level, not by what the grammar sectioned",
          any(line.startswith("  10-13: ") and "Setext Level Two" in line
              for line in outline), res)
    res = b.call("find_symbol", {"file": doc, "name": "Setext Level One"})
    check("find_symbol reaches a setext heading",
          res.get("count") == 1 and res["matches"][0]["lines"] == "5-17", res)
    os.remove(doc)

    # YAML sequence items: 680 of a Kubernetes manifest's 1,600 keys were
    # invisible because a sequence was opaque whatever it held. A list of
    # mappings is most of what anyone edits in such a file; a list of
    # scalars still has nothing worth an index entry.
    manifest = os.path.join(root, "pod.yaml")
    with open(manifest, "w") as f:
        f.write("apiVersion: v1\nkind: Pod\nmetadata:\n  name: demo\nspec:\n"
                "  containers:\n    - name: app\n      image: nginx:1.25\n"
                "    - name: side\n      image: busybox\n"
                "  args:\n    - -c\n    - --flag\n")
    res = b.call("find_symbol", {"file": manifest, "name": "spec/containers/app",
                                 "include_body": True})
    body = res.get("matches", [{}])[0].get("body", [])
    check("find_symbol reaches a yaml sequence item by its name",
          res.get("count") == 1 and any("image: nginx:1.25" in line for line in body), res)
    res = b.call("skim", {"files": [manifest]})
    outline = res["files"][0].get("outline", [])
    check("skim indexes the keys inside a sequence item",
          any("image: busybox" in line for line in outline), res)
    check("and leaves a list of scalars alone",
          not any("--flag" in line for line in outline), res)
    os.remove(manifest)

    # An outline of a file that does not parse used to be shaped exactly like
    # an outline of a healthy one: two siblings silently missing, a
    # grandchild lifted to the top, no note of any kind.
    broken = os.path.join(root, "broken.json")
    with open(broken, "w") as f:
        f.write('{\n  "a": {\n    "x": 1\n  }\n  "b": 2\n}\n')
    res = b.call("skim", {"files": [broken]})
    entry = res["files"][0]
    check("skim says when the file it outlined does not parse",
          entry.get("partial") is True and "cannot read" in (entry.get("parse_error") or ""),
          res)
    check("and says the outline may be missing entries",
          "may be missing" in (entry.get("parse_error_note") or ""), res)
    os.remove(broken)

    # Depth, not size and not minification. A JSON file 3,000 objects deep
    # overflowed the Lua stack on the find_symbol path, and the overflow left
    # the editor as a bare "Error: stack overflow": no file named, no partial
    # result, and every other file in the same call lost with it. A 1.6 MB
    # single-line file six deep was always fine, so the depth is the number
    # worth asserting - and the exact depth, not "it does not crash".
    def nest(depth, pretty):
        sep = "\n" if pretty else ""
        open_ = sep.join('{"d%d": ' % i for i in range(depth, 0, -1))
        return "%s0%s%s\n" % (open_, sep, sep.join("}" for _ in range(depth)))

    deep = os.path.join(root, "deep.json")
    with open(deep, "w") as f:
        f.write(nest(5000, False))
    res = b.call("find_symbol", {"file": deep, "name": "d4999"})
    check("find_symbol indexes a 5000-deep file that used to overflow the stack",
          res.get("count", 0) >= 1
          and res["matches"][0]["name_path"].startswith("d5000/d4999"), res)
    # 3,000 deep is where it used to give up; the pretty-printed variant
    # is the one that made it clear size was not the cause (38 KB).
    pretty_deep = os.path.join(root, "deep_pretty.json")
    with open(pretty_deep, "w") as f:
        f.write(nest(3000, True))
    res = b.call("find_symbol", {"file": pretty_deep, "name": "d2999"})
    check("and a 3000-deep pretty-printed one, which is where it used to stop",
          res.get("count", 0) >= 1, res)
    # A name path 5,000 segments long is neither an address anyone can use
    # nor something a reply can afford: one such query came back at 147,819
    # characters. It is clipped, and the reply says a clipped path cannot be
    # handed to an edit tool.
    res = b.call("find_symbol", {"file": deep, "name": "d1"})
    path = res["matches"][0]["name_path"]
    check("a name path too long to print is clipped and says how much it lost",
          len(path) < 400 and "characters of name path)" in path
          and "not one an edit tool can resolve" in (res.get("name_paths_clipped") or ""),
          {"len": len(path), "tail": path[-80:], "note": res.get("name_paths_clipped")})

    # A batch tool survives one bad member. Nineteen good files used to be
    # lost to one that failed, and the reply named none of them.
    md = os.path.join(root, "NOTES.md")
    res = b.call("skim", {"files": [md, os.path.join(root, "nosuch.json"),
                                    pretty_deep, os.path.join(root, "deploy"), util]})
    files = res.get("files", [])
    named = {os.path.basename(f.get("file", "").rstrip("/")): f for f in files}
    check("a skim batch returns the good files and names the ones that failed",
          len(files) == 5
          and named["NOTES.md"].get("outline")
          and named["util.lua"].get("outline")
          and named["deep_pretty.json"].get("outline")
          and named["nosuch.json"].get("error")
          and "rest of the batch is unaffected" in (named["nosuch.json"].get("note") or ""),
          [(f.get("file"), bool(f.get("outline")), f.get("error")) for f in files])
    # And the deep file's own outline says how much of it was left out
    # without spending the reply on indentation: entry 150 used to carry 298
    # leading spaces.
    outline = named["deep_pretty.json"]["outline"]
    check("a deep outline writes its depth instead of indenting to it",
          len(outline) == 151 and outline[149].strip().startswith("[+137]")
          and max(len(l) for l in outline) < 200
          and "+2850 more declarations (150 of 3000 shown)" in outline[150],
          outline[148:])
    os.remove(deep)
    os.remove(pretty_deep)


SMALL_JSON = ('{\n'
              '  "alpha": {\n'
              '    "one": 1,\n'
              '    "two": 2\n'
              '  },\n'
              '  "beta": {\n'
              '    "three": 3\n'
              '  },\n'
              '  "gamma": 4\n'
              '}\n')


def seed_json(root, name, text=SMALL_JSON):
    """A JSON object with three members, written by the check that needs it
    rather than kept in tests/testproj: the project's own shape stays as
    every other check expects it."""
    path = os.path.join(root, name)
    with open(path, "w") as f:
        f.write(text)
    return path


def json_state(path):
    """Whether the file on disk is still JSON, and what it holds."""
    try:
        with open(path) as f:
            return True, json.load(f)
    except ValueError as e:
        return False, str(e)


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

    # One stale chunk out of several: the ones that matched are still
    # right, and re-sending them by hand is work already done once.
    try:
        b.call("replace_symbol_lines", {
            "file": util, "name_path": "M.greet",
            "chunks": [
                {"first_line": 1, "last_line": 1, "expect": "function M.greet(name)",
                 "text": "function M.greet(name)"},
                {"first_line": 3, "last_line": 3, "expect": "nothing like this here", "text": "x"},
            ],
        })
        check("a partly stale chunked call is refused", False, "call succeeded")
    except RuntimeError as e:
        token = re.search(r'token="(\d+)"', str(e))
        check("the refusal offers to apply the chunks that matched",
              "apply only the 1 chunk(s) that matched" in str(e) and token is not None, e)
        if token:
            res = b.call("apply_code_action", {"token": token.group(1), "index": 1})
            check("that action applies them",
                  res.get("replaced") == "lines 1-1 of M.greet", res)
            b.call("undo_edit", {"count": 1})

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
    # An expect= shorter than the range anchors the start of it. Proving the
    # numbers are not stale is the whole of what expect= is for, and the
    # requested range starting with exactly the expected text proves it.
    # Refusing here taught nobody: callers kept sending the first line of a
    # long range with no way to comply, and it was the largest open friction
    # cluster in the digest. The whole range is replaced, and the reply says
    # how much of it the expect actually vouched for.
    res = b.call("replace_symbol_lines", {
        "file": util, "name_path": "M.greet", "first_line": 1, "last_line": 3,
        "expect": "function M.greet(name)",
        "text": 'function M.greet(name)\n    return "hi, " .. name\nend',
    })
    text_now = open(util).read()
    check("a short expect anchors the range and the edit applies to all of it",
          res.get("replaced") == "lines 1-3 of M.greet"
          and 'return "hi, " .. name' in text_now
          and 'return "hello, " .. name' not in text_now
          and text_now.count("function M.greet(name)") == 1, res)
    check("the reply says how much of the range the expect covered",
          any("covered the first 1 of the 3 lines" in s
              for s in res.get("expect_was_a_prefix", [])), res)

    reset(c)
    # An expect that is not what the range starts with is a stale offset
    # still, and still refused with nothing written.
    before_short = open(util).read()
    try:
        b.call("replace_symbol_lines", {
            "file": util, "name_path": "M.greet", "first_line": 1, "last_line": 3,
            "expect": "nothing like this",
            "text": "x",
        })
        check("an expect the range does not start with is refused", False, "call succeeded")
    except RuntimeError as e:
        check("an expect the range does not start with is refused",
              "expect covers 1 line(s)" in str(e) and "cover 3" in str(e)
              and open(util).read() == before_short, e)

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
    # A write outside the workspace is refused before anything is opened.
    # Reaching /etc/hosts through a project's workspace applied the text to a
    # buffer, and only file permissions kept it off the disk. An absolute
    # path is turned away by the router, which is where the open roots are
    # known: the editor sees only the workspace the call landed in, and its
    # refusal used to name that workspace as though the caller had asked for
    # it - "X is outside the workspace Y" about a Y nobody had mentioned.
    outside = os.path.join(work, "outside.txt")
    with open(outside, "w") as f:
        f.write("untouched\n")
    for tool, args in (("insert_lines", {"file": outside, "at": "end", "text": "x"}),
                       ("create_file", {"file": os.path.join(work, "new.txt"), "text": "x"}),
                       ("delete_file", {"file": outside}),
                       ("replace_pattern", {"files": [outside], "pattern": "untouched",
                                            "replacement": "touched", "literal": True})):
        try:
            b.call(tool, args)
            check("%s refuses a path outside the workspace" % tool, False, "call succeeded")
        except RuntimeError as e:
            check("%s refuses a path outside the workspace" % tool,
                  "no open workspace holds" in str(e)
                  and "writes only inside a workspace" in str(e)
                  and "The root that holds it is not open" in str(e), e)
    # A relative path names no workspace, so it is the editor that catches
    # this one, against the root the call was routed to.
    try:
        b.call("insert_lines", {"file": "../outside.txt", "at": "end", "text": "x"})
        check("a relative path out of the workspace is refused", False, "call succeeded")
    except RuntimeError as e:
        check("a relative path out of the workspace is refused",
              "is not inside" in str(e)
              and "the workspace this call was routed to" in str(e)
              and "writes only inside the workspace it is routed to" in str(e), e)
    with open(outside) as f:
        check("the file outside the workspace is untouched", f.read() == "untouched\n", None)
    os.remove(outside)
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
    # A rename that reached every reference must not warn that it did not:
    # the scope check compares the rename's files against the server's
    # references, and a false positive here would make the warning noise.
    check("a complete rename carries no scope warning",
          "references_not_renamed" not in res, res)
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

    # A double-quoted shell string is live code - `cd "$DIR"` expands inside
    # it - so kind=code must not skip it: skipping left three scripts
    # assigning a new name and reading the old one, reported as a success.
    shellfile = os.path.join(root, "scripts", "paths.sh")
    with open(shellfile, "w") as f:
        f.write("#!/usr/bin/env bash\n"
                "PROJECT_DIR=/tmp/x\n"
                'cd "$PROJECT_DIR" || exit 1\n'
                "echo 'literal $PROJECT_DIR stays'\n")
    res = b.call("replace_pattern", {
        "files": [shellfile], "pattern": "PROJECT_DIR", "replacement": "REPO_DIR",
        "literal": True, "kind": "code", "dry_run": True})
    check("a double-quoted shell string is code, a single-quoted one is not",
          res.get("total_replacements") == 2 and "1 matches are inside" in (res.get("left_alone") or ""),
          res)
    os.remove(shellfile)

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

    # A JSON object is edited by its structure, not by the lines its members
    # happen to sit on. The pair separator sits after the pair, so replacing
    # or inserting next to one used to eat it or omit it, leave a file
    # json.load could not read, and answer "applied and saved to disk". Every
    # check below asserts on the reply's wording *and* on the file parsing,
    # because the old reply was a clean, plausible success.
    path = seed_json(root, "small.json")
    res = b.call("replace_symbol_body", {
        "file": path, "name_path": "alpha",
        "body": '  "alpha": {\n    "one": 111\n  }'})
    ok, data = json_state(path)
    check("replace_symbol_body leaves the JSON file parseable", ok, data)
    check("and the object still has all three members",
          ok and sorted(data) == ["alpha", "beta", "gamma"], data)
    check("and the reply says what it kept on the line",
          '","' in (res.get("kept_on_the_line") or ""), res)
    check("and does not claim the file no longer parses",
          res.get("note") == "applied and saved to disk", res)
    check("and the verdict answers with the grammar, not with the absent server",
          "json grammar still parses it" in (res.get("diagnostics_after") or ""), res)

    path = seed_json(root, "insert_mid.json")
    res = b.call("insert_after_symbol", {
        "file": path, "name_path": "alpha",
        "text": '  "inserted": {\n    "x": 9\n  }'})
    ok, data = json_state(path)
    check("insert_after_symbol leaves the JSON file parseable", ok, data)
    check("and both the new member and the old ones are there",
          ok and sorted(data) == ["alpha", "beta", "gamma", "inserted"], data)
    check("and the reply says a comma was added after the inserted text",
          "comma was added after the inserted text" in (res.get("separator") or ""), res)
    with open(path) as f:
        text = f.read()
    check("and no blank line was inserted inside the object",
          "\n\n" not in text, text)

    # The anchor was the last member, so the comma goes after the anchor
    # instead - and the anchor's line is part of the edit, so an undo takes
    # the comma back with it.
    path = seed_json(root, "insert_last.json")
    res = b.call("insert_after_symbol", {
        "file": path, "name_path": "gamma", "text": '  "tail": 7'})
    ok, data = json_state(path)
    check("insert after the object's last member leaves it parseable", ok, data)
    check("and the reply says the comma went after the anchor",
          "comma was added after gamma" in (res.get("separator") or ""), res)
    res = b.call("undo_edit", {})
    ok, data = json_state(path)
    check("undo takes back the inserted member and the comma with it",
          ok and sorted(data) == ["alpha", "beta", "gamma"], (res, data))

    # A one-line file where the declaration is not the whole of its line:
    # replacing the function used to delete the package clause with it.
    one = os.path.join(root, "oneline.go")
    with open(one, "w") as f:
        f.write("package pkg; func OneLiner() int { return 1 }\n")
    res = b.call("replace_symbol_body", {
        "file": one, "name_path": "OneLiner",
        "body": "func OneLiner() int { return 2 }"})
    with open(one) as f:
        text = f.read()
    # gofmt may well put the package clause on its own line afterwards, which
    # is the point: it is still there to format.
    check("replacing a declaration keeps what shares its line",
          "package pkg" in text and "return 2" in text, text)
    check("and the reply names what it kept",
          "package pkg; " in (res.get("kept_on_the_line") or ""), res)
    os.remove(one)

    # An edit that really does break the file says so, in the note and in
    # the verdict, instead of deferring to a language server JSON never has.
    path = seed_json(root, "broken_by_edit.json")
    res = b.call("insert_lines", {"file": path, "line": 2, "text": "  oops"})
    ok, data = json_state(path)
    check("an edit that breaks the file leaves it broken", not ok, data)
    check("and the note no longer calls that done",
          res.get("note") == "applied and saved to disk, and the file no longer parses", res)
    check("and the verdict leads with the grammar",
          (res.get("diagnostics_after") or "").startswith(
              "the json grammar no longer parses this file"), res)
    check("and it says the file did parse before the edit",
          "and it did before this edit" in (res.get("diagnostics_after") or ""), res)

    # A file that arrived broken is not blamed on the edit that touches it.
    path = seed_json(root, "was_broken.json",
                     '{\n  "a": {\n    "x": 1\n  }\n  "b": 2\n}\n')
    res = b.call("insert_lines", {"file": path, "at": "end", "text": "  "})
    check("an edit to an already broken file is not blamed for it",
          res.get("note") == "applied and saved to disk", res)
    check("though the verdict still says the file does not parse",
          "does not parse it as it now stands" in (res.get("diagnostics_after") or ""), res)
    reset(c)


def group_indent(c):
    """A body written at the wrong indentation: the tool says it matches the
    file's, and silently did not - a Python method replaced at column 0 took
    the method after it out of the class."""
    b, root = c.b, c.root

    reset(c)
    klass = os.path.join(root, "lua", "testproj", "cls.py")
    with open(klass, "w") as f:
        f.write("class Suite:\n"
                "    def test_alpha(self):\n"
                "        return 1\n"
                "\n"
                "    def test_beta(self):\n"
                "        return 2\n"
                "\n"
                "    def test_gamma(self):\n"
                "        return 3\n")
    res = b.call("find_symbol", {"file": klass, "name": "Suite/test_beta"})
    if res.get("count", 0) == 0:
        print("SKIP indentation check: no symbol for Suite/test_beta")
        os.remove(klass)
        return
    res = b.call("replace_symbol_body", {
        "file": klass, "name_path": "Suite/test_beta",
        "body": "def test_beta(self):\n    return 22"})
    text = open(klass).read()
    check("a body written at column 0 is shifted to the declaration's column",
          "    def test_beta(self):" in text and "\ndef test_beta" not in text
          and "    def test_gamma(self):" in text
          and "shifted by 4" in (res.get("reindented") or ""), (res, text))
    # A body already at the right indentation is left byte for byte.
    res = b.call("replace_symbol_body", {
        "file": klass, "name_path": "Suite/test_alpha",
        "body": "    def test_alpha(self):\n        return 11"})
    check("a body at the right column is untouched",
          res.get("reindented") is None
          and "        return 11" in open(klass).read(), res)
    os.remove(klass)


def group_ambiguity(c):
    """Two declarations answering to one name path: the refusal has to name
    something the caller can act on, and line= has to settle it."""
    b, root = c.b, c.root

    reset(c)
    pair = os.path.join(root, "lua", "testproj", "twins.lua")
    with open(pair, "w") as f:
        f.write("local Stack = {\n"
                "    push = function(self, item)\n"
                "        return item\n"
                "    end,\n"
                "}\n"
                "local Queue = {\n"
                "    push = function(self, item)\n"
                "        return item\n"
                "    end,\n"
                "}\n"
                "return { Stack = Stack, Queue = Queue }\n")
    try:
        b.call("replace_symbol_body", {"file": pair, "name_path": "push", "body": "x"})
        check("an ambiguous name path is refused", False, "call succeeded")
    except RuntimeError as e:
        check("the ambiguity names the line of each candidate",
              "line 2" in str(e) and "line 7" in str(e)
              and "pass line=" in str(e), e)
    res = b.call("replace_symbol_body", {
        "file": pair, "name_path": "push", "line": 7,
        "body": "    push = function(self, item)\n        return item, 2\n    end,"})
    text = open(pair).read()
    check("line= picks the declaration that starts there",
          "return item, 2" in text and text.count("return item") == 2, (res, text))
    try:
        b.call("replace_symbol_body", {"file": pair, "name_path": "push", "line": 3, "body": "x"})
        check("a line that declares nothing is refused", False, "call succeeded")
    except RuntimeError as e:
        check("a line that declares nothing is refused",
              "declared on line 3" in str(e) and "line 2" in str(e), e)
    # The same key, on the tool the refusal is most often raised by: it used
    # to read an undocumented `declared_on` and ignore the `line=` its own
    # error message asked for.
    res = b.call("replace_symbol_lines", {
        "file": pair, "name_path": "push", "line": 2,
        "first_line": 2, "last_line": 2, "text": "        return item, 3"})
    text = open(pair).read()
    check("line= picks the declaration for replace_symbol_lines too",
          "return item, 3" in text and text.count("return item") == 2, (res, text))
    os.remove(pair)


def group_multifile(c):
    """The same symbol edit in several files: one call, one undo step."""
    b, root = c.b, c.root

    reset(c)
    made = []
    for name in ("alpha", "beta"):
        path = os.path.join(root, "lua", "testproj", name + ".lua")
        with open(path, "w") as f:
            f.write("local M = {}\n\nfunction M.run()\n    return 1\nend\n\nreturn M\n")
        made.append(path)
    # dry_run has to reach the tool itself: the files= pre-pass probes each
    # file with it before writing any of them, and an insert that ignored the
    # flag wrote the text once for the probe and once for the edit.
    res = b.call("insert_before_symbol", {
        "files": made, "name_path": "M.run", "text": "--- Runs it.\n", "dry_run": True})
    check("a dry run over several files writes none of them",
          all("--- Runs it." not in open(p).read() for p in made), res)
    res = b.call("insert_before_symbol", {
        "files": made, "name_path": "M.run", "text": "--- Runs it.\n"})
    check("insert_before_symbol edits every file it is given",
          res.get("files") == 2 and len(res.get("reports", [])) == 2
          and all("--- Runs it." in open(p).read() for p in made), res)
    check("it inserts the text once, not once per pass",
          all(open(p).read().count("--- Runs it.") == 1 for p in made),
          [open(p).read() for p in made])
    res = b.call("replace_symbol_body", {
        "files": made, "name_path": "M.run",
        "body": "function M.run()\n    return 2\nend"})
    check("replace_symbol_body edits every file it is given",
          res.get("files") == 2 and all("return 2" in open(p).read() for p in made), res)
    res = b.call("undo_edit", {"count": 1})
    check("one undo takes back the whole multi-file edit",
          all("return 1" in open(p).read() for p in made), res)
    try:
        b.call("replace_symbol_body", {"files": made, "file": made[0],
                                       "name_path": "M.run", "body": "x"})
        check("file and files together are refused", False, "call succeeded")
    except RuntimeError as e:
        check("file and files together are refused", "not both" in str(e), e)
    try:
        b.call("replace_symbol_body", {
            "files": made, "name_path": "M.missing", "body": "x"})
        check("a file without the symbol is named", False, "call succeeded")
    except RuntimeError as e:
        check("a file without the symbol is named",
              "alpha.lua" in str(e) and "no symbol named" in str(e), e)
    # A file that lacks the symbol refuses the whole call: the files before
    # it in the list must not be left edited.
    with open(made[0]) as f:
        first_before = f.read()
    third = os.path.join(root, "lua", "testproj", "gamma.lua")
    with open(third, "w") as f:
        f.write("local M = {}\n\nreturn M\n")
    try:
        b.call("replace_symbol_body", {
            "files": [made[0], third], "name_path": "M.run",
            "body": "function M.run()\n    return 3\nend"})
        check("a partly-applicable multi-file edit is refused whole", False, "call succeeded")
    except RuntimeError as e:
        with open(made[0]) as f:
            check("a partly-applicable multi-file edit is refused whole",
                  "gamma.lua" in str(e) and f.read() == first_before, e)
    os.remove(third)
    try:
        b.call("replace_symbol_body", {"files": "not-an-array", "name_path": "M.run", "body": "x",
                                       "workspace": root})
        check("a files= that is not an array is refused", False, "call succeeded")
    except RuntimeError as e:
        check("a files= that is not an array is refused", "must be an array" in str(e), e)
    b.call("undo_edit", {"all": True})
    for p in made:
        os.path.exists(p) and os.remove(p)


def group_undo(c):
    """An entry that refuses to undo blocked every older one, with no way
    past it but git."""
    b, root = c.b, c.root

    reset(c)
    util = c.util
    b.call("replace_symbol_lines", {
        "file": util, "name_path": "M.greet",
        "match": '    return "hello, " .. name', "text": '    return "hi, " .. name'})
    b.call("replace_symbol_lines", {
        "file": util, "match": "local M = {}", "text": "local M = {} -- edited"})
    # Change the newest edit's region behind the tool's back.
    with open(util) as f:
        text = f.read()
    with open(util, "w") as f:
        f.write(text.replace("local M = {} -- edited", "local M = {} -- by hand"))
    b.call("find_symbol", {"file": util, "name": "M.greet"})
    res = b.call("undo_edit", {"all": True})
    check("an entry whose region changed refuses and says how to get past it",
          len(res.get("refused", [])) == 1 and "skip=true" in (res.get("refused_note") or "")
          and 'return "hi, "' in open(util).read(), res)
    res = b.call("undo_edit", {"all": True, "skip": True})
    check("skip=true forgets it and undoes the rest",
          len(res.get("dropped", [])) == 1
          and 'return "hello, " .. name' in open(util).read()
          and res.get("remaining") == 0, res)

    reset(c)
    # Undoing one bulk edit answered with 2,431 lines over 59 KB - one entry
    # per file the edit had touched, each the same sentence with a different
    # name in it - and the `remaining` a caller actually reads was buried
    # inside it. The list is budgeted; the revert itself is not.
    bulk = os.path.join(root, "bulk")
    os.makedirs(bulk, exist_ok=True)
    for i in range(50):
        with open(os.path.join(bulk, "f%02d.lua" % i), "w") as f:
            f.write("local NAME_HERE = %d\nreturn NAME_HERE\n" % i)
    res = b.call("replace_pattern", {
        "glob": "bulk/**/*.lua", "pattern": "NAME_HERE", "replacement": "RENAMED",
        "literal": True})
    check("the bulk edit reached every file", res.get("files_matched") == 50,
          {k: v for k, v in res.items() if k != "files"})
    res = b.call("undo_edit", {"count": 1})
    cut = res.get("undone_entries") or {}
    check("a bulk undo lists a budgeted sample and counts the rest",
          len(res.get("undone", [])) == 40
          and cut.get("shown") == 40 and cut.get("total") == 50 and cut.get("dropped") == 10
          and "only the listing is cut" in (cut.get("note") or "")
          and res.get("remaining") == 0, {"listed": len(res.get("undone", [])), "cut": cut,
                                          "remaining": res.get("remaining")})
    check("and every file really was reverted",
          all("NAME_HERE" in open(os.path.join(bulk, "f%02d.lua" % i)).read()
              for i in range(50)), res)
    shutil.rmtree(bulk)


def group_polish(c):
    """What the polish after an edit does to the record of that edit: an
    import organizer rewrites lines above it, and undo has to take those
    back too."""
    b, root = c.b, c.root

    reset(c)
    # The function holds a nested block on purpose, so the file has a `}` at
    # two depths: the guard that keeps the import pass from re-indenting the
    # lines it kept read that as a re-indentation and reverted every import
    # pass in every Go, TypeScript and Lua file there is. A flat fixture
    # cannot see it.
    goimp = os.path.join(root, "importer.go")
    with open(goimp, "w") as f:
        f.write("package sample\n"
                "\n"
                "import (\n"
                "\t\"strings\"\n"
                ")\n"
                "\n"
                "func use() string {\n"
                "\tif true {\n"
                "\t\treturn strings.ToUpper(\"x\")\n"
                "\t}\n"
                "\treturn \"\"\n"
                "}\n")
    before_imp = open(goimp).read()
    res = b.call("replace_symbol_body", {
        "file": goimp, "name_path": "use",
        "body": "func use() string {\n\tif true {\n"
                "\t\treturn fmt.Sprintf(\"%s\", strings.ToUpper(\"x\"))\n"
                "\t}\n\treturn \"\"\n}"})
    if res.get("imports_note"):
        # A refusal here is the bug, not a reason to skip: the pass ran and
        # was taken back.
        check("the import polish is not refused over a re-indentation it did not do",
              False, res.get("imports_note"))
    elif "organized imports" not in (res.get("polished") or ""):
        print("SKIP import-polish undo check: no import organizer ran (gopls missing?)")
    else:
        check("the import polish added the import it needed",
              "fmt" in open(goimp).read(), res)
        b.call("undo_edit", {"count": 1})
        check("undo takes back what the import polish changed too",
              open(goimp).read() == before_imp, open(goimp).read())
    os.remove(goimp)

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
    # "all listed" and "… +92 more" used to sit in the same object, and
    # full_diagnostics=true is the flag whose whole purpose is to defeat the
    # cap - the loudest wrong count in any reply.
    listed = res3.get("preexisting_list") or []
    check("full_diagnostics does not claim to list all and then stop",
          not ("all listed" in (res3.get("preexisting") or "")
               and any(l.startswith("… +") for l in listed)), res3)

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
    # startswith, not equality: a server that has not published anything yet
    # gets its silence labelled as silence, and whether lua_ls has published
    # this buffer's unused-local hint by now is a race. Both forms open with
    # the same clause; neither may claim more than that.
    check("post-edit reports nothing new",
          res.get("diagnostics_after", "").startswith("no new errors or warnings"), res)
    # An edit that plants an undefined global is reported as new; the
    # next edit elsewhere sees it as pre-existing rather than new again.
    res = b.call("replace_symbol_lines", {
        "file": util, "name_path": "M.greet", "first_line": 2, "last_line": 2,
        "text": '    return "hello, " .. nme',
    })
    # The exact signal: publishDiagnostics carries the version of the text it
    # describes, and this edit made the server publish, so the verdict came
    # from lua_ls stating which version it had analyzed rather than from
    # waiting out a settle guess. AGENT99_DEBUG_VERDICT surfaces which of the
    # two it was; without it the wording is the only tell. The first edit of
    # the group cannot reach this state - a clean file makes a push-only
    # server publish nothing at all, which is the gap pull diagnostics would
    # close (see the design note in edit.lua).
    if os.environ.get("AGENT99_DEBUG_VERDICT"):
        check("the verdict came from the server's own document version",
              res.get("verdict_basis") == "version"
              and "lua_ls" in (res.get("verdict_stamps") or ""), res)
    check("post-edit reports the new error",
          isinstance(res.get("diagnostics_after"), list)
          and any("nme" in d for d in res["diagnostics_after"]), res)
    res = b.call("replace_symbol_lines", {
        "file": util, "name_path": "M.shout", "first_line": 2, "last_line": 2,
        "text": '    return string.upper(M.greet(name))',
    })
    # startswith: every clean verdict now names the scope it covered, because
    # "no new errors or warnings" on its own reads as a statement about the
    # project and was one about a single file.
    check("post-edit separates pre-existing",
          str(res.get("diagnostics_after", "")).startswith("no new errors or warnings")
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

    # An entry that enters the pre-existing list from a file this call did not
    # touch is reported as a delta and nothing else. The reply used to name a
    # cause for it - "the server has been asked about more of the project,
    # which is not a change this call made" - and that clause was observed on
    # errors the previous call had created, on errors another live agent had
    # just typed, on an error created while the server was dead, and on the
    # errors an undo was putting back. Here it would be attached to an error
    # this same client planted one call earlier, which is the shape that reads
    # as an alibi.
    b.call("replace_symbol_lines", {
        "file": util, "name_path": "M.shout", "first_line": 2, "last_line": 2,
        "text": "    return upper_missing(name)",
    })
    res = b.call("replace_symbol_lines", {
        "file": main_lua, "name_path": "run", "first_line": 2, "last_line": 2,
        "text": '    print(util.greet("world!"))',
    })
    pre = res.get("preexisting", "")
    check("an entry from another file is reported as a delta",
          "entered this list since the last reply, none of them in this file" in pre, res)
    check("and no cause is asserted for it",
          "not a change this call made" not in json.dumps(res)
          and "asked about more of the project" not in json.dumps(res), res)
    b.call("replace_symbol_lines", {
        "file": util, "name_path": "M.shout", "first_line": 2, "last_line": 2,
        "text": "    return string.upper(M.greet(name))",
    })

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
          waited < 2.5
          and str(res.get("diagnostics_after", "")).startswith("no new errors or warnings"),
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
          and str(res.get("diagnostics_after", "")).startswith("no new errors or warnings"), res)
    b.call("undo_edit", {"all": True})

    verdict_closure(c)


def verdict_closure(c):
    """The scope the verdict covers. An edit that changes a symbol's shape
    breaks the files that use it, and a language server publishes only for
    the documents something has opened: four Go packages broken by one
    return-type change came back as "no new errors or warnings", and the
    warmer the server the cleaner that false verdict read. Asserted on the
    wording, because the defect arrives as a successful reply with a clean
    exit code and every count in it is right about the files it looked at."""
    b, work = c.b, c.work
    if not shutil.which("gopls") or not shutil.which("go"):
        return
    goroot = os.path.join(work, "closureproj")
    os.makedirs(goroot)
    with open(os.path.join(goroot, "go.mod"), "w") as f:
        f.write("module closureproj\n\ngo 1.22\n")
    files = {
        "core/core.go":
            "package core\n\n// Compute returns an int derived from a.\n"
            "func Compute(a int) int {\n\treturn a * 2\n}\n",
        "usera/a.go":
            "package usera\n\nimport \"closureproj/core\"\n\n"
            "// Val takes its type from Compute's return type.\n"
            "var Val = core.Compute(1)\n\nfunc Wrap() int {\n\treturn core.Compute(9)\n}\n",
        "userb/b.go":
            "package userb\n\nimport \"closureproj/core\"\n\nvar B int = core.Compute(2)\n",
        "userc/c.go":
            "package userc\n\nimport \"closureproj/core\"\n\n"
            "func C() int {\n\tx := core.Compute(3)\n\treturn x\n}\n",
        # Never mentions Compute: it breaks through usera.Val's inferred
        # type, so its error names neither the edited symbol nor the edited
        # file. A one-hop closure does not reach it, and that is the exact
        # shape the last round's regression hid in.
        "userd/d.go":
            "package userd\n\nimport \"closureproj/usera\"\n\n"
            "func D() int {\n\treturn usera.Val\n}\n",
    }
    for rel, text in files.items():
        os.makedirs(os.path.join(goroot, os.path.dirname(rel)), exist_ok=True)
        with open(os.path.join(goroot, rel), "w") as f:
            f.write(text)
    # A package that is broken on purpose and stays broken, so the warm-up
    # below has something gopls must eventually publish. Without it "gopls has
    # said nothing yet" and "gopls says this is clean" are the same reply, and
    # the check would pass against a server that never woke up.
    os.makedirs(os.path.join(goroot, "warm"))
    with open(os.path.join(goroot, "warm", "warm.go"), "w") as f:
        f.write("package warm\n\nfunc W() int {\n\treturn missingHelper()\n}\n")
    b.call("open_workspace", {"root": goroot})
    core_go = os.path.join(goroot, "core", "core.go")
    # The probe found the false verdict got *cleaner* the warmer the server
    # was, so this has to run against a gopls that has already loaded the
    # module and answered for every one of these files.
    warm = os.path.join(goroot, "warm", "warm.go")
    deadline = time.time() + 60
    while time.time() < deadline:
        if b.call("diagnostics", {"file": warm}).get("count", 0) > 0:
            break
        time.sleep(0.5)
    check("gopls is warm before the closure is judged",
          b.call("diagnostics", {"file": warm}).get("count", 0) > 0, "gopls never published")
    for rel in files:
        b.call("diagnostics", {"file": os.path.join(goroot, rel)})
    res = b.call("replace_symbol_body", {
        "file": core_go, "name_path": "Compute",
        "body": "func Compute(a int) string {\n\treturn \"x\"\n}",
    })
    blob = repr(res)
    for name in ("usera/a.go", "userb/b.go", "userc/c.go", "userd/d.go"):
        check("the verdict names %s" % name, name in blob, res)
    reported = list(res.get("new_errors_elsewhere") or [])
    if isinstance(res.get("diagnostics_after"), list):
        reported += res["diagnostics_after"]
    check("the indirect dependent's own error is reported",
          any("usera.Val" in line for line in reported), res)
    check("the verdict is not a clean line",
          not str(res.get("diagnostics_after", "")).startswith("no new errors"), res)
    # Put it back, and check the clean verdict states its own scope rather
    # than reading as a statement about the project.
    res = b.call("replace_symbol_body", {
        "file": core_go, "name_path": "Compute",
        "body": "func Compute(a int) int {\n\treturn a * 2\n}",
    })
    after = str(res.get("diagnostics_after", ""))
    check("a clean verdict says which files it covered",
          "listed under checked" in after and isinstance(res.get("checked"), list)
          and "usera/a.go" in res["checked"] and "userd/d.go" in res["checked"], res)

    # undo_edit(skip=True) leaves half a rename standing on purpose: the
    # entry it could not reverse keeps the new name while the rest of the
    # project goes back to the old one. The prose said so and
    # diagnostics_after - the field read as the verdict - said "no new errors
    # or warnings".
    res = b.call("rename_symbol", {"file": core_go, "line": 4, "symbol": "Compute",
                                   "new_name": "Calculate"})
    check("the rename the undo check needs went through",
          res.get("renamed_to") == "Calculate" and len(res.get("files", [])) > 1, res)
    if res.get("renamed_to") == "Calculate":
        # Change one of the renamed files behind the ledger's back, so its
        # undo entry is refused and skip=true drops it.
        usera = os.path.join(goroot, "usera", "a.go")
        with open(usera) as f:
            text = f.read()
        with open(usera, "w") as f:
            f.write(text.replace("func Wrap() int {", "func Wrap() int { // pinned"))
        b.call("find_symbol", {"file": usera, "name": "Wrap"})
        res = b.call("undo_edit", {"skip": True, "workspace": goroot})
        blob = repr(res)
        check("undo_edit reports the file it did not undo",
              "usera/a.go" in blob and not
              str(res.get("diagnostics_after", "")).startswith("no new errors or warnings"),
              res)
        b.call("undo_edit", {"all": True, "skip": True, "workspace": goroot})
        with open(usera, "w") as f:
            f.write(text)
        b.call("find_symbol", {"file": usera, "name": "Wrap"})

    # delete_file had no closure pass at all and phrased its verdict as
    # covering the project.
    res = b.call("delete_file", {"file": os.path.join(goroot, "userd", "d.go")})
    after = str(res.get("diagnostics_after", ""))
    check("delete_file states the scope of its verdict",
          "checked" in res or "no other file using what this file declared" in after
          or "importers were not checked" in after, res)
    res = b.call("delete_file", {"file": core_go})
    blob = repr(res)
    check("delete_file reports the files that used the deleted one",
          all(name in blob for name in ("usera/a.go", "userb/b.go", "userc/c.go")), res)
    b.call("close_workspace", {"root": goroot})


def group_search(c):
    """grep and list_files: annotation, path globs, the tests= and kind=
    filters."""
    b, root, work = c.b, c.root, c.work
    util, main_lua, tools = c.util, c.main_lua, c.tools

    reset(c)
    # files= was accepted and ignored: one file asked for, three returned.
    r = b.rpc("tools/call", {"name": "grep", "arguments": {
        "pattern": "greet", "files": [os.path.join(root, "lua", "testproj", "util.lua")]}})
    only = r["result"]["content"][0]["text"]
    check("grep searches only the files it was given",
          "util.lua" in only and "main.lua" not in only, only)
    # A glob that matches nothing is a different answer from a pattern that
    # is not there, and needs a different fix.
    r = b.rpc("tools/call", {"name": "grep", "arguments": {
        "pattern": "greet", "glob": "nosuchdir/**/*.lua"}})
    empty = r["result"]["content"][0]["text"]
    check("a glob that matches no files says so",
          "matched no files" in empty, empty)

    # An eleven-character match on a 50,000-character minified line came back
    # as the whole line: one grep hit, 30 KB, and a reply budget spent on a
    # file nobody was reading. workspace_map has clipped at 80 characters for
    # as long as it has existed; grep and read_file clipped nothing.
    minified = os.path.join(root, "bundle.min.js")
    with open(minified, "w") as f:
        f.write("var pad=%s;var NEEDLE_HERE=1;\n" % ('"' + "x" * 50000 + '"'))
    r = b.rpc("tools/call", {"name": "grep", "arguments": {
        "pattern": "NEEDLE_HERE", "files": [minified], "context": 0}})
    hit = r["result"]["content"][0]["text"]
    check("a grep hit on a very long line is clipped and says how much it lost",
          len(hit) < 1000 and "NEEDLE_HERE" not in hit
          and "characters on this line)" in hit, {"len": len(hit), "head": hit[:120]})
    # read_file has a byte budget as well as a line budget: limit=2000 over a
    # file of 40 KB lines returned 85 KB and every line of it was one nobody
    # could read.
    r = b.rpc("tools/call", {"name": "read_file",
                             "arguments": {"path": minified, "offset": 1, "limit": 10}})
    text = r["result"]["content"][0]["text"]
    check("read_file clips a very long line too, and counts the ones it clipped",
          len(text) < 2000 and "1 of the lines above were longer than 400 characters"
          in text, {"len": len(text), "tail": text[-200:]})
    # Lines short enough that the per-line clip never fires: it is the total
    # that has to stop this read, and say so rather than let the caller read
    # "truncated" as "limit=2000 was reached".
    with open(minified, "w") as f:
        f.write("".join('var v%d="%s";\n' % (i, "y" * 300) for i in range(2000)))
    r = b.rpc("tools/call", {"name": "read_file",
                             "arguments": {"path": minified, "offset": 1, "limit": 2000}})
    text = r["result"]["content"][0]["text"]
    check("a read stops at its character budget and says that is why",
          len(text) < 60000 and "the read stopped at its 48000-character budget, "
          "not at limit=2000" in text, {"len": len(text), "tail": text[-260:]})
    os.remove(minified)

    # A match inside a string literal that sits on a declaration's own line:
    # calling the whole declaration line "def" kept it under kind=code, which
    # is the one thing that filter exists to drop.
    envfile = os.path.join(root, "lua", "testproj", "env.lua")
    with open(envfile, "w") as f:
        f.write('local DB = os.getenv("NOTES_DB")\n'
                "\n"
                "local function open_db()\n"
                "    return DB\n"
                "end\n"
                "\n"
                "return { open_db = open_db }\n")
    r = b.rpc("tools/call", {"name": "grep", "arguments": {
        "pattern": "NOTES_DB", "path": "lua/testproj/env.lua"}})
    plain = r["result"]["content"][0]["text"]
    r = b.rpc("tools/call", {"name": "grep", "arguments": {
        "pattern": "NOTES_DB", "path": "lua/testproj/env.lua", "kind": "code"}})
    code_only = r["result"]["content"][0]["text"]
    check("a string literal on a declaration line is not code",
          "NOTES_DB" in plain and "NOTES_DB" not in code_only, (plain, code_only))
    r = b.rpc("tools/call", {"name": "grep", "arguments": {
        "pattern": "DB", "path": "lua/testproj/env.lua", "kind": "code"}})
    decl = r["result"]["content"][0]["text"]
    check("the declaration itself is still code", "local DB" in decl, decl)
    os.remove(envfile)

    # A source file with a stray NUL byte: the searcher stops at the first
    # match in it, and the rest goes unsearched. That has to be visible - it
    # cost a real search half of a 4000-line TypeScript file - and text=true
    # searches it in full.
    nul = os.path.join(root, "lua", "testproj", "nul.lua")
    with open(nul, "wb") as f:
        f.write(b'-- needle one\nlocal x = "\x00"\n-- needle two\n-- needle three\n')
    r = b.rpc("tools/call", {"name": "grep", "arguments": {"pattern": "needle", "path": "lua/testproj/nul.lua"}})
    hit = r["result"]["content"][0]["text"]
    check("a file the search gave up on is named, not passed off as a result",
          "hold a NUL byte" in hit and "text=true" in hit
          and "WARNING" not in hit, hit)
    # The NUL before the first match is the case that used to answer
    # "(no matches)": ripgrep skipped the file in silence.
    early = os.path.join(root, "lua", "testproj", "earlynul.lua")
    with open(early, "wb") as f:
        f.write(b'local a = "\x00"\n-- needle one\n-- needle two\n')
    r = b.rpc("tools/call", {"name": "grep", "arguments": {
        "pattern": "needle", "path": "lua/testproj/earlynul.lua"}})
    early_hit = r["result"]["content"][0]["text"]
    check("a file skipped as binary is named rather than answered as empty",
          "hold a NUL byte" in early_hit and "(no matches)" not in early_hit, early_hit)
    os.remove(early)
    r = b.rpc("tools/call", {"name": "grep", "arguments": {
        "pattern": "needle", "path": "lua/testproj/nul.lua", "text": True}})
    full = r["result"]["content"][0]["text"]
    check("text=true searches the whole file",
          full.count("needle") >= 3 and "hold a NUL byte" not in full, full)
    os.remove(nul)

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
          "matched no files" in reply["result"]["content"][0]["text"], reply)

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
    # The cap used to say only that it stopped: a 1,261-file glob answered
    # with 500 files and no remainder, so a caller could not tell whether one
    # file was missed or three quarters of them.
    many = os.path.join(root, "many")
    os.makedirs(many, exist_ok=True)
    for i in range(520):
        with open(os.path.join(many, "f%03d.txt" % i), "w") as f:
            f.write("x\n")
    reply = b.rpc("tools/call", {"name": "list_files",
                                 "arguments": {"glob": "many/**/*.txt"}})
    text = reply["result"]["content"][0]["text"]
    check("list_files names its remainder",
          "500 of 520 files listed; 20 more are not shown" in text
          and len([l for l in text.splitlines() if l.startswith("many/")]) == 500,
          text.splitlines()[-1])
    shutil.rmtree(many)
    # A single-file target keeps the filename, so hits stay annotated.
    reply = b.rpc("tools/call", {"name": "grep", "arguments": {
        "pattern": "M.greet", "path": "lua/testproj/util.lua", "context": 0}})
    text = reply["result"]["content"][0]["text"]
    check("single-file grep annotated", "util.lua:" in text and "[M.greet" in text, text)

    # A leading dot on a directory used to mean "not part of the project" to
    # the searchers and "part of the project" to the census, so grep answered
    # "(no matches)" about a file list_files had just printed. The counts are
    # what this asserts on: "(no matches)" is a clean, plausible reply, and a
    # check on the exit code passes against the bug.
    reset(c)
    seed_dot_directory(root)
    hidden = grep_text(pattern="vendored_only_symbol")
    check("grep searches a leading-dot directory",
          "scripts/.vendored/vendorlib.lua" in hidden and "(no matches)" not in hidden, hidden)
    reply = b.rpc("tools/call", {"name": "list_files", "arguments": {"glob": "**/*.lua"}})
    listed = reply["result"]["content"][0]["text"]
    check("list_files still lists the same file, so the two agree",
          "scripts/.vendored/vendorlib.lua" in listed, listed)
    # .gitignore does not list .git, so --hidden alone would hand back the
    # object store: every search names it as the one exclusion of its own.
    os.makedirs(os.path.join(root, ".git"), exist_ok=True)
    with open(os.path.join(root, ".git", "COMMIT_EDITMSG"), "w") as f:
        f.write("vendored_only_symbol\n")
    with_git = grep_text(pattern="vendored_only_symbol")
    check("grep does not walk .git",
          ".git/" not in with_git and "scripts/.vendored/vendorlib.lua" in with_git, with_git)
    reply = b.rpc("tools/call", {"name": "list_files", "arguments": {}})
    listed = reply["result"]["content"][0]["text"]
    check("list_files does not walk .git either", "COMMIT_EDITMSG" not in listed, listed)


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
    # The description used to promise that both files' imports are
    # reorganized, which describes gopls and not the tool: pyright, tsserver
    # and lua_ls sort and prune and add nothing, so three of four languages
    # were left non-runnable by a reply that read clean. The reply says what
    # was and was not done, and whether other files could be checked at all.
    # Either the pass ran and sorts-and-prunes without adding, or no server
    # offered one at all (lua_ls does not). Both readings must say that a name
    # the moved code needs may now be unresolved; neither may claim an import
    # was added. "sorted and pruned" over a diff that touched no require line
    # was the wording this replaced.
    imports = res.get("imports", "")
    check("move_symbols says what its import pass did and did not do",
          ("an import pass ran" in imports or "no import pass ran" in imports)
          and "unresolved" in imports
          and res.get("also_checked_note", "") != "", res)
    check("the symbol that stayed is untouched", "function M.greet" in left_text, left_text)
    check("the removal site is not left with a run of blank lines",
          "\n\n\n" not in left_text, left_text)
    # One move is one undo step. Undoing it entry by entry restored the
    # destination while the symbol was still deleted from the source, so it
    # existed in neither file - and the reply said "no new errors".
    res = b.call("undo_edit", {"count": 1})
    with open(util) as f:
        back = f.read()
    check("one undo takes a whole move back",
          "function M.shout" in back and len(res.get("undone", [])) == 3
          and not os.path.exists(split), res)
    res = b.call("undo_edit", {"all": True})
    with open(util) as f:
        check("undo_edit puts a split back", "function M.shout" in f.read(), res)
    # The destination this move created goes with it: restoring it to the
    # header it was seeded with left a two-line stub no build complains
    # about, and a repeated move and undo litters the package with them.
    check("undo_edit removes a destination the move created",
          not os.path.exists(split), os.path.exists(split) and open(split).read())
    os.path.exists(split) and os.remove(split)

    # A move into another package must not carry the source's package line:
    # it produced a file that cannot compile, and the errors were reported
    # as pre-existing.
    godir = os.path.join(root, "gopkg")
    os.makedirs(godir, exist_ok=True)
    with open(os.path.join(godir, "go.mod"), "w") as f:
        f.write("module sample\n\ngo 1.22\n")
    src = os.path.join(godir, "a", "src.go")
    os.makedirs(os.path.dirname(src), exist_ok=True)
    with open(src, "w") as f:
        f.write("package apkg\n\nfunc Helper() int {\n\treturn 1\n}\n")
    dstdir = os.path.join(godir, "b")
    os.makedirs(dstdir, exist_ok=True)
    with open(os.path.join(dstdir, "existing.go"), "w") as f:
        f.write("package bpkg\n\nfunc Other() int {\n\treturn 2\n}\n")
    dst = os.path.join(dstdir, "moved.go")
    res = b.call("move_symbols", {"from": src, "to": dst, "names": ["Helper"]})
    with open(dst) as f:
        head = f.read().split("\n")[0]
    check("a move into another package takes that package's name",
          head == "package bpkg", (res, head))
    b.call("undo_edit", {"count": 1})
    shutil.rmtree(godir, ignore_errors=True)

    # A Lua module ends with `return M`; appending below it is a syntax
    # error, and the move did that every time.
    reset(c)
    dest = os.path.join(root, "lua", "testproj", "helpers.lua")
    with open(dest, "w") as f:
        f.write("local H = {}\n\nfunction H.keep()\n    return 1\nend\n\nreturn H\n")
    res = b.call("move_symbols", {"from": util, "to": dest, "names": ["M.shout"]})
    moved_text = open(dest).read()
    # The move does not requalify identifiers, so `M` is undefined in the
    # destination - which the reply says. What matters here is that the
    # symbol went above the return rather than below it.
    check("a symbol moved into a Lua module lands above its return",
          moved_text.rstrip().endswith("return H")
          and "function M.shout" in moved_text
          and moved_text.index("function M.shout") < moved_text.index("return H"),
          (res, moved_text))
    b.call("undo_edit", {"all": True})
    os.path.exists(dest) and os.remove(dest)
    reset(c)

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


def group_clients(c):
    """Per-client identity: one bridge, one root, two clients. Each client's
    undo ledger, check_project and run_tests baselines and set of already
    disclosed diagnostics are its own, and the workspace replies say when a
    root is shared. Every check here is on the wording as well as on the
    files: the defect this covers arrived as a successful reply.

    The client id rides in _meta on the tools/call request (see
    bridge/client.go for what the transport can and cannot tell apart), which
    is what lets one process act as two clients here."""
    b, root = c.b, c.root
    util = c.util

    restart(c)
    # restart() opened the workspace as the connection's own client; A and B
    # then join the same instance. The second must say so and name the other.
    res = b.call("open_workspace", {"root": root}, client="A")
    check("open_workspace reports the client count",
          res.get("already_open") is True and res.get("clients", 0) >= 2, res)
    res = b.call("open_workspace", {"root": root}, client="B")
    check("open_workspace on an already-open root names the other holder",
          res.get("already_open") is True and res.get("clients", 0) >= 3
          and "A" in (res.get("shared") or "")
          and "yours alone" in (res.get("shared") or ""), res)

    # Two clients edit two symbols in one file; A undoes. The old ledger was
    # one stack per root, so A's undo took B's edit off disk and reported
    # success, and B was never told.
    b.call("replace_symbol_body", {
        "file": util, "name_path": "M.greet",
        "body": 'function M.greet(name)\n    local a_marker = 1\n    return "hello, " .. name\nend',
    }, client="A")
    b.call("replace_symbol_body", {
        "file": util, "name_path": "M.shout",
        "body": 'function M.shout(name)\n    local b_marker = 1\n    return string.upper(M.greet(name))\nend',
    }, client="B")
    with open(util) as f:
        both = f.read()
    check("both clients' edits are on disk", "a_marker" in both and "b_marker" in both, both)
    res = b.call("undo_edit", {}, client="A")
    with open(util) as f:
        after = f.read()
    check("A's undo takes back A's edit and leaves B's on disk",
          "a_marker" not in after and "b_marker" in after, after)
    check("A's undo names A's own symbol",
          [item.get("symbol") for item in res.get("undone", [])] == ["M.greet"], res)
    check("A's undo says what it left alone",
          "1 other client(s)" in (res.get("other_clients") or "")
          and "1 undo step(s)" in (res.get("other_clients") or ""), res)

    # A client that has edited nothing has an empty ledger of its own, and is
    # told that the steps it can see are not its to undo.
    res = b.call("undo_edit", {}, client="C")
    check("a client that edited nothing has nothing to undo",
          res.get("undone") == []
          and "no symbol edits recorded for you" in (res.get("note") or "")
          and "will not reach them" in (res.get("other_clients") or ""), res)
    # B's edit is still B's to undo.
    res = b.call("undo_edit", {}, client="B")
    with open(util) as f:
        after = f.read()
    check("B can still undo its own edit",
          "b_marker" not in after
          and [item.get("symbol") for item in res.get("undone", [])] == ["M.shout"], res)

    # Baselines. A records one; B, which never recorded one, must not be
    # compared against it - it used to be handed A's, and told how many lines
    # were "new since the baseline" over a change it had not made.
    marker = os.path.join(root, "marker.txt")
    with open(marker, "w") as f:
        f.write("one\n")
    cmd = {"command": "cat marker.txt", "workspace": root}
    res = b.call("check_project", cmd, client="A")
    check("A records its own check_project baseline",
          res.get("baseline", "").startswith("recorded")
          and "yours and this command's" in res.get("baseline", ""), res)
    with open(marker, "w") as f:
        f.write("one\ntwo\n")
    res = b.call("check_project", cmd, client="B")
    check("B does not inherit A's check_project baseline",
          "baseline_lines" not in res and "since the baseline" not in (res.get("summary") or "")
          and res.get("baseline", "").startswith("recorded"), res)
    res = b.call("check_project", cmd, client="A")
    check("A's second call compares against A's own baseline",
          res.get("baseline_lines") == 1 and res.get("new") == ["two"]
          and res.get("summary") == "1 new lines since the baseline", res)
    res = b.call("check_project", dict(cmd, reset=True), client="A")
    check("re-recording says it replaced the client's own baseline",
          "re-recorded, replacing this client's previous baseline" in res.get("baseline", ""), res)

    # The same for run_tests, where the baseline is the set of failing tests.
    if shutil.which("go"):
        goroot = os.path.join(c.work, "clientgo")
        os.makedirs(goroot, exist_ok=True)
        with open(os.path.join(goroot, "go.mod"), "w") as f:
            f.write("module scratch\n\ngo 1.22\n")
        with open(os.path.join(goroot, "calc.go"), "w") as f:
            f.write("package scratch\n\nfunc Mul(a, b int) int { return a*b + 1 }\n")
        with open(os.path.join(goroot, "calc_test.go"), "w") as f:
            f.write("package scratch\n\nimport \"testing\"\n\n"
                    "func TestMul(t *testing.T) {\n\tif got := Mul(3, 3); got != 9 {\n"
                    "\t\tt.Fatalf(\"Mul(3,3) = %d, want 9\", got)\n\t}\n}\n")
        b.call("open_workspace", {"root": goroot}, client="A")
        res = b.call("run_tests", {"workspace": goroot}, client="A")
        check("A records its own run_tests baseline",
              res.get("baseline", "").startswith("recorded")
              and "yours and this command's" in res.get("baseline", ""), res)
        res = b.call("run_tests", {"workspace": goroot}, client="B")
        check("B does not inherit A's run_tests baseline",
              "baseline_failures" not in res and "fixed" not in res
              and res.get("baseline", "").startswith("recorded"), res)
        res = b.call("run_tests", {"workspace": goroot}, client="A")
        check("A's second run compares against A's own baseline",
              res.get("baseline_failures") == 1 and res.get("new_failures") == []
              and "still failing as at the baseline" in (res.get("summary") or ""), res)
        b.call("close_workspace", {"root": goroot}, client="A")

    # The disclosure set: "new to this list" means new to what this client
    # has been shown. It was per root, so one client's reply discharged
    # another's disclosure - an agent was told "none new to this list" about
    # errors only the other agent had ever seen.
    broken = os.path.join(root, "lua", "testproj", "broken.lua")
    with open(broken, "w") as f:
        f.write("local M = {}\n\nfunction M.oops(\n\nreturn M\n")
    b.call("diagnostics", {"file": broken}, client="A")
    body = 'function M.greet(name)\n    return "hello, " .. name\nend'
    res = b.call("replace_symbol_body", {"file": util, "name_path": "M.greet", "body": body},
                 client="A")
    listed = "\n".join(res.get("preexisting_new_to_list") or [])
    check("A is shown the pre-existing error", "broken.lua" in listed, res)
    res = b.call("replace_symbol_body", {"file": util, "name_path": "M.greet", "body": body},
                 client="B")
    listed = "\n".join(res.get("preexisting_new_to_list") or [])
    check("B is shown it too, rather than told none is new to the list",
          "broken.lua" in listed
          and "none new to this list" not in (res.get("preexisting") or ""), res)
    res = b.call("replace_symbol_body", {"file": util, "name_path": "M.greet", "body": body},
                 client="A")
    check("A, having been shown it, is not shown it again",
          "none new to this list" in (res.get("preexisting") or "")
          and not res.get("preexisting_new_to_list"), res)

    # Closing a shared root says whose workspace it was taking with it.
    res = b.call("close_workspace", {"root": root}, client="B")
    holders = (res.get("was_shared") or {}).get(os.path.realpath(root)) or []
    check("close_workspace names the other clients using the root",
          "A" in holders and "closing one closes it for them too" in (res.get("was_shared_note") or ""),
          res)
    c.opened = False


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
    ("indent", group_indent),
    ("ambiguity", group_ambiguity),
    ("undo", group_undo),
    ("multifile", group_multifile),
    ("polish", group_polish),
    ("verdict", group_verdict),
    ("search", group_search),
    ("files", group_files),
    ("tests", group_tests),
    ("clients", group_clients),
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
