#!/usr/bin/env bash
# Smoke test: starts a headless Neovim with the minimal test config, then
# exercises the MCP bridge tools against real lua_ls results, and the
# debugger tools against a real Delve session.
#
# Usage: tests/smoke.sh [suite ...]
#   suites: unit mcp headless multi debug (default: all of them, in that order)
# While iterating on one area run only the suite that covers it, e.g.
# `tests/smoke.sh headless` after an edit-tool change; run the full set
# before committing, since the suites share the Lua and the bridge.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$PATH:$HOME/.local/share/nvim/mason/bin"

ALL_SUITES="unit mcp headless multi debug"
if [ $# -eq 0 ]; then
    SUITES="$ALL_SUITES"
else
    SUITES="$*"
    for s in $SUITES; do
        case " $ALL_SUITES " in
            *" $s "*) ;;
            *) echo "unknown suite '$s' (known: $ALL_SUITES)"; exit 2 ;;
        esac
    done
fi
want() { case " $SUITES " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# Debugger test dependencies, pinned and bumped by hand: a Delve release
# could otherwise break the gate on a day nothing in agent99 changed.
DLV_VERSION="v1.27.1"
NVIM_DAP_COMMIT="c9a0738e45f1bd41d792a126941348dce661cf9b"
TEST_CACHE="$HOME/.cache/agent99-tests"

command -v nvim >/dev/null || { echo "nvim not found"; exit 1; }
command -v lua-language-server >/dev/null || {
    echo "lua-language-server not found (install it, e.g. via mason)"; exit 1
}

# Delve for the debugger tests: the pinned version from the cache, installed
# there when missing (one cached go install; no network after the first run).
debug_skip=""
export PATH="$TEST_CACHE/bin:$PATH"
if want debug && ! { command -v dlv >/dev/null && dlv version | grep -q "Version: ${DLV_VERSION#v}"; }; then
    mkdir -p "$TEST_CACHE/bin"
    if ! GOBIN="$TEST_CACHE/bin" go install "github.com/go-delve/delve/cmd/dlv@$DLV_VERSION" 2>&1 | tail -3; then
        debug_skip="go install of dlv@$DLV_VERSION failed"
    fi
fi
command -v dlv >/dev/null || debug_skip="${debug_skip:-dlv not found}"

# nvim-dap on the test runtimepath: $AGENT99_TEST_NVIM_DAP, else a shallow
# checkout under tests/.deps at the pinned commit.
DAP_DIR="${AGENT99_TEST_NVIM_DAP:-$REPO/tests/.deps/nvim-dap}"
if want debug && [ ! -d "$DAP_DIR" ] && [ -z "${AGENT99_TEST_NVIM_DAP:-}" ]; then
    mkdir -p "$REPO/tests/.deps"
    if git clone --quiet https://github.com/mfussenegger/nvim-dap.git "$DAP_DIR" 2>&1 | tail -2; then
        git -C "$DAP_DIR" checkout --quiet "$NVIM_DAP_COMMIT" || true
    else
        debug_skip="${debug_skip:-could not clone nvim-dap}"
    fi
fi
[ -d "$DAP_DIR" ] || debug_skip="${debug_skip:-nvim-dap not found at $DAP_DIR}"

WORK="$(mktemp -d)"
SOCK="$WORK/nvim.sock"
cleanup() {
    nvim --server "$SOCK" --remote-expr 'execute("qa!")' >/dev/null 2>&1 || true
    [ -n "${NVIM_PID:-}" ] && kill "$NVIM_PID" 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT

# Pure-Lua checks that need no language server: the guards that decide
# whether a formatter's pass is kept after an edit, and the region
# mapping the ledger records.
if want unit; then
    nvim --clean --headless -u "$REPO/tests/minimal_init.lua" -l "$REPO/tests/unit_edit.lua"
fi

cd "$REPO/tests/testproj"
if want mcp; then
    nvim --clean --headless -u "$REPO/tests/minimal_init.lua" \
        --listen "$SOCK" lua/testproj/main.lua &
    NVIM_PID=$!

    for _ in $(seq 1 100); do
        [ -e "$SOCK" ] && break
        sleep 0.1
    done
    [ -e "$SOCK" ] || { echo "nvim socket never appeared"; exit 1; }

    # Full roster for coverage; drive_mcp separately checks the slim default.
    AGENT99_NVIM="$SOCK" AGENT99_FULL_TOOLS=1 python3 "$REPO/tests/drive_mcp.py"
fi
# Standalone mode: the bridge starts its own headless Neovim.
if want headless; then python3 "$REPO/tests/drive_headless.py"; fi
# Several workspaces open at once, and the routing between them.
if want multi; then python3 "$REPO/tests/drive_multi.py"; fi
# Debugger tools, standalone, against Delve.
if ! want debug; then
    :
elif [ -n "$debug_skip" ]; then
    echo "debug: SKIPPED ($debug_skip)"
    if [ -n "${AGENT99_TEST_REQUIRE_DEBUG:-}" ]; then
        echo "AGENT99_TEST_REQUIRE_DEBUG is set: treating the skip as a failure"
        exit 1
    fi
else
    python3 "$REPO/tests/drive_debug.py"
fi
if [ "$SUITES" = "$ALL_SUITES" ]; then
    echo "smoke: OK"
else
    echo "smoke ($SUITES): OK - partial run, the full suite is tests/smoke.sh with no arguments"
fi
