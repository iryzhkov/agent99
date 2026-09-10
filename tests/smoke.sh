#!/usr/bin/env bash
# Smoke test: starts a headless Neovim with the minimal test config, then
# exercises the MCP bridge tools against real lua_ls results, and the
# debugger tools against a real Delve session.
#
# Usage: tests/smoke.sh [suite ...]
#   suites: unit mcp headless multi debug (default: all of them, in that order)
#   the headless suite also takes one family of tools at a time:
#   headless:workspace, :index, :edit, :verdict, :search, :files, :lifecycle
# While iterating on one area run only the suite that covers it, e.g.
# `tests/smoke.sh headless:edit` after a change to the symbol edit tools;
# run the full set before committing, since the suites share the Lua and
# the bridge. The headless groups run as separate processes, four at a
# time; AGENT99_TEST_JOBS sets that number, and 1 runs them in order in
# one process, which is easier to read when something fails.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$PATH:$HOME/.local/share/nvim/mason/bin"
# Surfaces which signal the edit verdict actually rested on (the server's own
# document version, or the settle guess). One check asserts on it, and it is
# the first thing to look at when a verdict turns out to have been early.
export AGENT99_DEBUG_VERDICT=1

ALL_SUITES="unit mcp headless multi debug"
HEADLESS_GROUPS="workspace index edit indent ambiguity undo multifile polish verdict search files tests lifecycle"
HEADLESS_ARGS=""
if [ $# -eq 0 ]; then
    SUITES="$ALL_SUITES"
    ASKED="$ALL_SUITES"
else
    SUITES=""
    ASKED="$*"
    for s in "$@"; do
        case "$s" in
            headless:*)
                g="${s#headless:}"
                case " $HEADLESS_GROUPS " in
                    *" $g "*) ;;
                    *) echo "unknown headless group '$g' (known: $HEADLESS_GROUPS)"; exit 2 ;;
                esac
                SUITES="$SUITES headless"
                HEADLESS_ARGS="$HEADLESS_ARGS $g"
                ;;
            *)
                case " $ALL_SUITES " in
                    *" $s "*) SUITES="$SUITES $s" ;;
                    *) echo "unknown suite '$s' (known: $ALL_SUITES, or headless:<group>" \
                            "with group in: $HEADLESS_GROUPS)"; exit 2 ;;
                esac
                ;;
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
# whether a formatter's pass is kept after an edit, the region mapping the
# ledger records, the test-output parsers, and the commands check_project
# guesses from a project's files.
if want unit; then
    nvim --clean --headless -u "$REPO/tests/minimal_init.lua" -l "$REPO/tests/unit_edit.lua"
    nvim --clean --headless -u "$REPO/tests/minimal_init.lua" -l "$REPO/tests/unit_testrun.lua"
    nvim --clean --headless -u "$REPO/tests/minimal_init.lua" -l "$REPO/tests/unit_check.lua"
    nvim --clean --headless -u "$REPO/tests/minimal_init.lua" -l "$REPO/tests/unit_index.lua"
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
# Standalone mode: the bridge starts its own headless Neovim. One group of
# tools at a time when the caller named one, the whole family otherwise.
if want headless; then
    # shellcheck disable=SC2086      # the group names are separate arguments
    python3 "$REPO/tests/drive_headless.py" $HEADLESS_ARGS
fi
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
if [ "$ASKED" = "$ALL_SUITES" ]; then
    echo "smoke: OK"
else
    echo "smoke ($ASKED): OK - partial run, the full suite is tests/smoke.sh with no arguments"
fi
