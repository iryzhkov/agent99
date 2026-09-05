#!/usr/bin/env python3
"""Smoke test for the MCP bridge against a live headless Neovim.

Run through tests/smoke.sh, which starts the Neovim instance and sets
$AGENT99_NVIM. Talks to bridge/agent99_mcp.py over its stdio MCP transport
and asserts on real lua_ls results from tests/testproj.
"""

import json
import os
import subprocess
import sys
import time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BRIDGE = os.path.join(REPO, "bin", "agent99-bridge")
PROJ = os.path.join(REPO, "tests", "testproj")
MAIN = os.path.join(PROJ, "lua", "testproj", "main.lua")
UTIL = os.path.join(PROJ, "lua", "testproj", "util.lua")

EXPECTED_TOOLS = {
    "definition", "type_definition", "implementation", "references", "hover",
    "expand_symbol", "code_actions", "apply_code_action", "document_symbols",
    "workspace_symbols", "diagnostics", "incoming_calls", "outgoing_calls",
    "buffer_lines", "skim", "ts_query", "find_symbol",
    "replace_symbol_body", "replace_symbol_lines",
    "insert_after_symbol", "insert_before_symbol",
}
MESSY = os.path.join(PROJ, "lua", "testproj", "messy.lua")


class Bridge:
    def __init__(self, env=None):
        self.proc = subprocess.Popen(
            [BRIDGE, "mcp"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True,
            env=env,
        )
        assert self.proc.stdin is not None and self.proc.stdout is not None
        self.next_id = 0

    def rpc(self, method, params=None):
        self.next_id += 1
        msg = {"jsonrpc": "2.0", "id": self.next_id, "method": method}
        if params is not None:
            msg["params"] = params
        self.proc.stdin.write(json.dumps(msg) + "\n")
        self.proc.stdin.flush()
        line = self.proc.stdout.readline()
        reply = json.loads(line)
        assert reply["id"] == self.next_id, reply
        return reply

    def call(self, name, arguments):
        reply = self.rpc("tools/call", {"name": name, "arguments": arguments})
        result = reply["result"]
        text = result["content"][0]["text"]
        if result.get("isError"):
            raise RuntimeError("%s failed: %s" % (name, text))
        return json.loads(text)

    def close(self):
        self.proc.stdin.close()
        self.proc.wait(timeout=10)


def check(label, cond, detail: object = ""):
    if not cond:
        print("FAIL %s %s" % (label, detail))
        sys.exit(1)
    print("PASS %s" % label)


def main():
    assert os.environ.get("AGENT99_NVIM"), "AGENT99_NVIM must point at a running nvim"
    b = Bridge()

    init = b.rpc("initialize", {
        "protocolVersion": "2025-06-18",
        "capabilities": {},
        "clientInfo": {"name": "drive_mcp", "version": "0"},
    })
    check("initialize", init["result"]["protocolVersion"] == "2025-06-18", init)

    tools = {t["name"] for t in b.rpc("tools/list")["result"]["tools"]}
    check("tools/list", EXPECTED_TOOLS <= tools, tools)

    # Without AGENT99_FULL_TOOLS, the advertised roster must be the slim set,
    # while the trimmed tools stay callable.
    slim_env = {k: v for k, v in os.environ.items() if k != "AGENT99_FULL_TOOLS"}
    b2 = Bridge(env=slim_env)
    b2.rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                          "clientInfo": {"name": "drive_mcp", "version": "0"}})
    slim = {t["name"] for t in b2.rpc("tools/list")["result"]["tools"]}
    res = b2.call("document_symbols", {"file": UTIL})
    check("slim roster", "expand_symbol" not in slim and "document_symbols" not in slim
          and "find_symbol" in slim and "M.greet" in "\n".join(res.get("outline", [])),
          slim)
    b2.close()

    # The debugger tools are advertised only with AGENT99_DEBUG, in both
    # modes; embedded, the installer stays out (it is standalone-only).
    dbg_env = dict(os.environ, AGENT99_DEBUG="1")
    b3 = Bridge(env=dbg_env)
    b3.rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                          "clientInfo": {"name": "drive_mcp", "version": "0"}})
    dbg = {t["name"] for t in b3.rpc("tools/list")["result"]["tools"]}
    b3.close()
    check("debug roster gated on AGENT99_DEBUG",
          "debug_launch" not in tools and "debug_launch" in dbg
          and "debug_stop" in dbg and "install_debugger" not in dbg, dbg)

    # lua_ls may still be indexing right after startup; retry until the
    # cross-file definition resolves.
    locs = []
    for _ in range(10):
        res = b.call("definition", {"file": MAIN, "line": 4, "symbol": "greet"})
        locs = res.get("locations", [])
        if locs:
            break
        time.sleep(1)
    check("definition cross-file",
          len(locs) == 1 and locs[0]["file"].endswith("util.lua") and locs[0]["line"] == 6,
          locs)

    res = b.call("hover", {"file": MAIN, "line": 5, "symbol": "shout"})
    check("hover", "function" in (res.get("hover") or ""), res)

    res = b.call("references", {"file": UTIL, "line": 6, "symbol": "greet"})
    check("references", res.get("count", 0) >= 2, res)

    res = b.call("expand_symbol", {"file": MAIN, "line": 4, "symbol": "greet"})
    source = "\n".join(res.get("source", []))
    check("expand_symbol", "function M.greet" in source and res.get("hover"), res)

    res = b.call("document_symbols", {"file": UTIL})
    outline = "\n".join(res.get("outline", []))
    check("document_symbols", "M.greet" in outline and "M.shout" in outline, res)

    res = b.call("skim", {"files": [UTIL, MAIN]})
    text = json.dumps(res)
    check("skim",
          len(res.get("files", [])) == 2
          and "function M.greet(name)" in text and "local function run()" in text,
          res)

    res = b.call("ts_query", {
        "query": "(function_declaration name: (_) @name)",
        "glob": "**/*.lua",
    })
    names = {m["text"] for m in res.get("matches", [])}
    check("ts_query", res.get("count", 0) >= 3 and "M.greet" in names, res)

    res = b.call("find_symbol", {"name": "M.greet", "glob": "**/*.lua", "include_body": True})
    body = "\n".join(res.get("matches", [{}])[0].get("body", []))
    check("find_symbol",
          res.get("count", 0) >= 1 and 'return "hello, " .. name' in body, res)

    res = b.call("replace_symbol_body", {
        "file": UTIL, "name_path": "M.shout",
        "body": 'function M.shout(name)\n    return string.upper(M.greet(name)) .. "!"\nend',
    })
    check("replace_symbol_body", res.get("replaced") == "M.shout", res)
    res = b.call("buffer_lines", {"file": UTIL})
    check("replace applied", '.. "!"' in "\n".join(res.get("lines", [])), res)

    res = b.call("insert_after_symbol", {
        "file": UTIL, "name_path": "M.shout",
        "text": "function M.whisper(name)\n    return string.lower(M.greet(name))\nend",
    })
    check("insert_after_symbol", "after M.shout" in res.get("inserted", ""), res)
    res = b.call("find_symbol", {"file": UTIL, "name": "M.whisper"})
    check("inserted symbol indexed", res.get("count", 0) == 1, res)

    # Slice edit with symbol-relative line numbers: change only the return
    # line (line 2 of the 3-line M.whisper inserted above).
    res = b.call("replace_symbol_lines", {
        "file": UTIL, "name_path": "M.whisper",
        "first_line": 2, "last_line": 2,
        "text": '    return string.lower(M.greet(name)) .. "..."',
    })
    check("replace_symbol_lines", "lines 2-2 of M.whisper" in res.get("replaced", ""), res)
    res = b.call("find_symbol", {"file": UTIL, "name": "M.whisper", "include_body": True})
    body = "\n".join(res["matches"][0]["body"])
    check("slice applied, relative numbering",
          '2:     return string.lower(M.greet(name)) .. "..."' in body, res)

    # An out-of-range slice must be refused.
    try:
        b.call("replace_symbol_lines", {
            "file": UTIL, "name_path": "M.whisper",
            "first_line": 5, "last_line": 9, "text": "x",
        })
        check("slice out-of-range", False, "expected an error")
    except RuntimeError as exc:
        check("slice out-of-range", "outside the symbol" in str(exc), exc)

    # Diagnostics on a file with an unused local: the warning should surface,
    # with quick_fixes listed when lua_ls offers code actions for it.
    res = b.call("diagnostics", {"file": MESSY})
    diags = res.get("diagnostics", [])
    check("diagnostics warning", res.get("count", 0) >= 1
          and any("unused" in (d.get("message") or "").lower() for d in diags), res)
    print("INFO quick_fixes:", [d.get("quick_fixes") for d in diags])

    # A query that cannot compile must come back as a clear error.
    try:
        b.call("ts_query", {"query": "(no_such_node) @x", "files": [UTIL]})
        check("ts_query bad-query", False, "expected an error")
    except RuntimeError as exc:
        check("ts_query bad-query", "does not compile" in str(exc), exc)

    res = b.call("buffer_lines", {"file": UTIL, "first": 1, "last": 3})
    check("buffer_lines", res.get("lines", [None])[0] == "1: local M = {}", res)

    res = b.call("code_actions", {"file": MAIN, "line": 1, "symbol": "util"})
    check("code_actions", "token" in res and isinstance(res.get("actions"), list), res)

    res = b.call("diagnostics", {"file": MAIN})
    check("diagnostics", res.get("count") == 0, res)

    b.close()


if __name__ == "__main__":
    main()
