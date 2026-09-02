#!/usr/bin/env bash
# Smoke test: starts a headless Neovim with the minimal test config, then
# exercises the MCP bridge tools against real lua_ls results.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$PATH:$HOME/.local/share/nvim/mason/bin"

command -v nvim >/dev/null || { echo "nvim not found"; exit 1; }
command -v lua-language-server >/dev/null || {
    echo "lua-language-server not found (install it, e.g. via mason)"; exit 1
}

WORK="$(mktemp -d)"
SOCK="$WORK/nvim.sock"
cleanup() {
    nvim --server "$SOCK" --remote-expr 'execute("qa!")' >/dev/null 2>&1 || true
    [ -n "${NVIM_PID:-}" ] && kill "$NVIM_PID" 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT

cd "$REPO/tests/testproj"
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
echo "smoke: OK"
