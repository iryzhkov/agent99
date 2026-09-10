#!/usr/bin/env python3
"""Smoke test for several workspaces open at once in the standalone MCP
server: two scratch copies of tests/testproj are opened side by side, and
each call has to land in the right one.

Run through tests/smoke.sh (which sets AGENT99_HEADLESS_INIT so the
instances use the minimal config, not the user's).
"""

import os
import shutil
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from drive_mcp import REPO, PROJ, Bridge, check  # noqa: E402


def util_of(root):
    return os.path.join(root, "lua", "testproj", "util.lua")


def main():
    env = {k: v for k, v in os.environ.items() if k not in ("AGENT99_NVIM", "NVIM")}
    env["AGENT99_HEADLESS_INIT"] = os.path.join(REPO, "tests", "minimal_init.lua")
    # Two is enough to exercise the limit without paying for a third Neovim.
    env["AGENT99_MAX_WORKSPACES"] = "2"
    work = tempfile.mkdtemp(prefix="agent99-multi-")
    alpha = os.path.join(work, "alpha")
    beta = os.path.join(work, "beta")
    shutil.copytree(PROJ, alpha)
    shutil.copytree(PROJ, beta)
    # A third project, opened only to be refused by the limit.
    gamma = os.path.join(work, "gamma")
    shutil.copytree(PROJ, gamma)
    alpha, beta, gamma = (os.path.realpath(p) for p in (alpha, beta, gamma))
    outsider = os.path.join(work, "outsider.lua")
    with open(outsider, "w") as f:
        f.write("local M = {}\nfunction M.outside() return 1 end\nreturn M\n")

    b = Bridge(env=env)
    try:
        b.rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                             "clientInfo": {"name": "drive_multi", "version": "0"}})

        # The workspace argument is advertised on every tool that can be
        # routed. A required file= does not route the call by itself: a
        # relative path means "in the workspace this lands in", so the call is
        # refused with advice to pass workspace= - which those tools did not
        # have. open_workspace and close_workspace name their own root.
        tools = {t["name"]: t for t in b.rpc("tools/list")["result"]["tools"]}
        props = lambda name: set(tools[name]["inputSchema"].get("properties", {}))
        check("workspace arg on pathless tools",
              "workspace" in props("check_project") and "workspace" in props("workspace_map")
              and "workspace" in props("undo_edit") and "workspace" in props("find_symbol"),
              sorted(props("check_project")))
        check("workspace arg on the file- and position-addressed tools too",
              all("workspace" in props(name) for name in
                  ("read_file", "skim", "diagnostics", "references", "definition",
                   "replace_symbol_lines")),
              sorted(props("read_file")))
        check("no workspace arg where the tool names its own root",
              "workspace" not in props("open_workspace")
              and "workspace" not in props("close_workspace"),
              sorted(props("open_workspace")))

        res = b.call("open_workspace", {"root": alpha})
        check("first workspace opens", res.get("root") == alpha, res)
        check("one workspace lists no roster", "workspaces" not in res, res)
        check("open reply carries the workspace tree",
              isinstance(res.get("tree"), list) and res.get("file_count", 0) > 0
              and any("lua" in l for l in res["tree"]), res)
        alpha_pid = res["pid"]

        # A root that shares a file tree with an open workspace is refused,
        # from either side, because two instances would hold their own
        # buffers for the same files.
        for bad in (os.path.join(alpha, "lua"), work):
            try:
                b.call("open_workspace", {"root": bad})
                check("overlapping root refused (%s)" % bad, False, "call succeeded")
            except RuntimeError as e:
                check("overlapping root refused (%s)" % bad,
                      "shares a file tree" in str(e) and alpha in str(e), e)

        # One Neovim per tree held inside a process and not across them:
        # openWorkspace consulted only its own map, so a second bridge - the
        # ordinary shape here, one per agent on the machine - started its
        # own instance over the same files. Two instances each hold their
        # own buffers, and an edit made in one is lost when the other
        # writes, which is the whole reason for the rule.
        other = Bridge(env=env)
        try:
            other.rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                     "clientInfo": {"name": "drive_multi_2", "version": "0"}})
            try:
                other.call("open_workspace", {"root": alpha})
                check("another bridge cannot open the same root", False, "call succeeded")
            except RuntimeError as e:
                check("another bridge cannot open the same root",
                      "already open in another agent99 bridge" in str(e)
                      and alpha in str(e), e)
            # A root nobody holds still opens in the second bridge, so the
            # check is about the tree and not about being second.
            res = other.call("open_workspace", {"root": gamma})
            check("a free root still opens in the second bridge",
                  res.get("root") == gamma and res["pid"] != alpha_pid, res)
            other.call("close_workspace", {"root": gamma})
        finally:
            other.proc.kill()
            try:
                other.proc.wait(timeout=10)
            except Exception:
                pass

        res = b.call("open_workspace", {"root": beta})
        beta_pid = res["pid"]
        check("second workspace opens beside the first",
              res.get("root") == beta and beta_pid != alpha_pid, res)
        check("two workspaces list the roster",
              res.get("workspaces") == sorted([alpha, beta]), res)

        try:
            b.call("open_workspace", {"root": gamma})
            check("workspace limit refuses a third", False, "call succeeded")
        except RuntimeError as e:
            check("workspace limit refuses a third", "limit is 2" in str(e), e)

        # An absolute path routes the call by itself, and the reply says
        # which instance answered.
        reply = b.rpc("tools/call", {"name": "find_symbol", "arguments": {
            "file": util_of(beta), "name": "M.greet"}})
        text = reply["result"]["content"][0]["text"]
        check("reply names the workspace that answered",
              text.startswith("workspace: " + beta + "\n"), text[:120])

        res = b.call("find_symbol", {"file": util_of(alpha), "name": "M.greet"})
        check("absolute path routes to its own workspace", res.get("count") == 1, res)

        # The explicit argument targets a workspace a pathless call could
        # not have found on its own.
        res = b.call("workspace_map", {"workspace": beta, "glob": "lua/**/*.lua"})
        check("workspace= targets a workspace",
              any(f["file"] == "lua/testproj/util.lua" for f in res.get("files", [])), res)
        try:
            b.call("workspace_map", {"workspace": os.path.join(work, "nowhere")})
            check("unknown workspace= is refused", False, "call succeeded")
        except RuntimeError as e:
            check("unknown workspace= is refused", "no open workspace at" in str(e), e)

        # A relative path means "in the workspace this call is routed to",
        # which answers nothing while several are open - and replies print
        # relative paths, so feeding one back used to land in another
        # workspace and report the file missing there. Refused now.
        try:
            b.call("find_symbol", {"file": "lua/testproj/util.lua", "name": "M.greet"})
            check("a relative path with several workspaces open is refused",
                  False, "call succeeded")
        except RuntimeError as e:
            check("a relative path with several workspaces open is refused",
                  "no absolute path and no workspace=" in str(e)
                  and alpha in str(e) and beta in str(e), e)
        # With workspace= it is unambiguous again.
        res = b.call("find_symbol", {"file": "lua/testproj/util.lua", "name": "M.greet",
                                     "workspace": beta})
        check("a relative path with workspace= resolves", res.get("count") == 1, res)
        # A call with no path at all is refused for the same reason: a grep
        # answered "(no matches)" from another agent's checkout.
        try:
            b.call("check_project", {})
            check("a path-less call with several workspaces open is refused",
                  False, "call succeeded")
        except RuntimeError as e:
            check("a path-less call with several workspaces open is refused",
                  "nothing to route it by" in str(e), e)

        # One call works in one workspace: a move across them is refused
        # rather than half-done.
        try:
            b.call("move_file", {"from": util_of(alpha),
                                 "to": os.path.join(beta, "lua", "testproj", "moved.lua")})
            check("a call across workspaces is refused", False, "call succeeded")
        except RuntimeError as e:
            check("a call across workspaces is refused", "2 workspaces" in str(e), e)

        # A path in no workspace at all used to be read in whichever
        # instance the call landed in. That instance is arbitrary - one
        # probe read /etc/passwd through one agent's workspace and
        # /etc/hostname through another's, minutes apart - and answering
        # loads the file into that agent's Neovim and language servers.
        # Refused while several are open, for the reason the relative-path
        # guard already gave.
        for path, label in ((outsider, "a file beside the workspaces"),
                            ("/etc/passwd", "a system file in no project")):
            try:
                b.call("find_symbol", {"file": path, "name": "M.outside"})
                check("%s is refused, not guessed at" % label, False, "call succeeded")
            except RuntimeError as e:
                check("%s is refused, not guessed at" % label,
                      "no open workspace holds" in str(e) and path in str(e)
                      and alpha in str(e) and beta in str(e), e)
        # workspace= is the deliberate way to read one anyway: a dependency
        # under ~/go/pkg/mod, a system header.
        res = b.call("find_symbol", {"file": outsider, "name": "M.outside",
                                     "workspace": alpha})
        check("a path outside every workspace resolves with workspace=",
              res.get("count") == 1, res)

        # A write to a path no workspace holds is refused by the router,
        # which knows what is open. The editor's own refusal named the
        # workspace the call had landed in - "X is outside the workspace Y"
        # about a Y the caller had never mentioned.
        before = open(outsider).read()
        try:
            b.call("replace_symbol_body", {"file": outsider, "name_path": "M.outside",
                                           "body": "function M.outside() return 2 end"})
            check("a write outside every workspace is refused", False, "call succeeded")
        except RuntimeError as e:
            check("a write outside every workspace is refused",
                  "no open workspace holds" in str(e)
                  and "writes only inside a workspace" in str(e)
                  and "The root that holds it is not open" in str(e), e)
        check("the file outside every workspace is untouched",
              open(outsider).read() == before, outsider)

        # A symlink inside one workspace pointing at a file in another used
        # to route the call to the far end of the link: the write landed in
        # the other workspace, the reply carried that workspace's relative
        # path so it read like success here, and the edit entered that
        # workspace's undo ledger. Confinement is against the root the call
        # named now.
        link = os.path.join(beta, "lua", "testproj", "link_to_alpha.lua")
        os.symlink(util_of(alpha), link)
        alpha_before = open(util_of(alpha)).read()
        try:
            b.call("replace_symbol_body", {"file": link, "name_path": "M.greet",
                                           "body": 'function M.greet(name) return "x" end'})
            check("a symlink into another workspace is refused", False, "call succeeded")
        except RuntimeError as e:
            check("a symlink into another workspace is refused",
                  "resolves through a symlink" in str(e) and link in str(e)
                  and util_of(alpha) in str(e)
                  and ("inside the open workspace " + alpha) in str(e), e)
        check("the file at the far end of the symlink is untouched",
              open(util_of(alpha)).read() == alpha_before, util_of(alpha))
        # A read through the same link is refused for the same reason: it
        # would be answered by alpha's Neovim under beta's name.
        try:
            b.call("find_symbol", {"file": link, "name": "M.greet"})
            check("a read through such a symlink is refused too", False, "call succeeded")
        except RuntimeError as e:
            check("a read through such a symlink is refused too",
                  "resolves through a symlink" in str(e), e)
        # Naming the workspace does not exempt the path from it.
        try:
            b.call("find_symbol", {"file": link, "name": "M.greet", "workspace": beta})
            check("workspace= does not exempt the symlink", False, "call succeeded")
        except RuntimeError as e:
            check("workspace= does not exempt the symlink",
                  "resolves through a symlink" in str(e), e)
        # A link that stays inside its own workspace is ordinary work.
        inner = os.path.join(beta, "lua", "testproj", "link_to_own.lua")
        os.symlink(util_of(beta), inner)
        res = b.call("find_symbol", {"file": inner, "name": "M.greet"})
        check("a symlink inside its own workspace still resolves",
              res.get("count") == 1, res)
        os.unlink(link)
        os.unlink(inner)

        # An undo belongs to the workspace that was edited, even when a read
        # of the other one came in between.
        res = b.call("replace_symbol_lines", {
            "file": util_of(alpha), "name_path": "M.greet",
            "match": '    return "hello, " .. name', "text": '    return "hi, " .. name'})
        check("edit lands in alpha", 'return "hi, "' in open(util_of(alpha)).read(), res)
        b.call("find_symbol", {"file": util_of(beta), "name": "M.greet"})
        # workspace= is required now: the sticky "last edited" pointer lives
        # in the server, which several agents share, so it can point at
        # somebody else's repository.
        res = b.call("undo_edit", {"workspace": alpha})
        check("undo follows the workspace it is given, not the last read",
              len(res.get("undone", [])) == 1
              and 'return "hello, " .. name' in open(util_of(alpha)).read()
              and 'return "hi, "' not in open(util_of(beta)).read(), res)

        # Closing needs to say which one while several are open.
        try:
            b.call("close_workspace", {})
            check("ambiguous close is refused", False, "call succeeded")
        except RuntimeError as e:
            check("ambiguous close is refused", "name the root to close" in str(e), e)

        res = b.call("close_workspace", {"root": os.path.join(alpha, "lua")})
        check("a path inside a workspace closes that workspace",
              res.get("closed") == [alpha] and res.get("workspaces") == [beta], res)
        for _ in range(30):
            if not os.path.exists("/proc/%d" % alpha_pid):
                break
            time.sleep(0.1)
        check("the closed instance stopped", not os.path.exists("/proc/%d" % alpha_pid), alpha_pid)
        check("the other instance is still serving",
              b.call("find_symbol", {"file": util_of(beta), "name": "M.greet"}).get("count") == 1,
              beta)

        # With one left, close takes no argument again; with all=true it
        # would not need one either.
        res = b.call("open_workspace", {"root": gamma})
        gamma_pid = res["pid"]
        check("a workspace opens again once one is closed", res.get("root") == gamma, res)

        # A path under a root that was closed - by this client or, in the
        # field, by another one sharing it - is not served by whatever else
        # happens to be open. One agent's find_symbol on a closed root was
        # answered by an uninvolved agent's workspace, which then loaded the
        # whole module and reported the errors as its own.
        try:
            b.call("find_symbol", {"file": util_of(alpha), "name": "M.greet"})
            check("a path under a closed root is refused", False, "call succeeded")
        except RuntimeError as e:
            check("a path under a closed root is refused",
                  "no open workspace holds" in str(e) and util_of(alpha) in str(e)
                  and beta in str(e) and gamma in str(e), e)
        res = b.call("close_workspace", {"all": True})
        check("all=true closes every workspace",
              res.get("closed") == sorted([beta, gamma]) and "workspaces" not in res, res)
        for pid in (beta_pid, gamma_pid):
            for _ in range(30):
                if not os.path.exists("/proc/%d" % pid):
                    break
                time.sleep(0.1)
            check("instance %d stopped" % pid, not os.path.exists("/proc/%d" % pid), pid)
    finally:
        try:
            b.proc.kill()
        except Exception:
            pass
        shutil.rmtree(work, ignore_errors=True)
    print("multi-workspace: OK")


if __name__ == "__main__":
    main()
