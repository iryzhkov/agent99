#!/usr/bin/env bash
# End-to-end test: one real agent edit through the configured provider
# (DeepSeek by default). Costs a few API calls; requires DEEPSEEK_API_KEY.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$PATH:$HOME/.local/share/nvim/mason/bin"

[ -n "${DEEPSEEK_API_KEY:-}" ] || { echo "DEEPSEEK_API_KEY not set; skipping e2e"; exit 1; }
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

# Run against a throwaway copy of the test project.
cp -r "$REPO/tests/testproj" "$WORK/proj"
cd "$WORK/proj"
nvim --clean --headless -u "$REPO/tests/minimal_init.lua" \
    --listen "$SOCK" lua/testproj/main.lua &
NVIM_PID=$!

for _ in $(seq 1 100); do
    [ -e "$SOCK" ] && break
    sleep 0.1
done
[ -e "$SOCK" ] || { echo "nvim socket never appeared"; exit 1; }
sleep 3  # let lua_ls attach and index

nvim --server "$SOCK" --remote-expr "execute('luafile $REPO/tests/e2e_edit.lua')"

for i in $(seq 1 30); do
    sleep 5
    busy="$(nvim --server "$SOCK" --remote-expr \
        "luaeval('tostring(require(\"agent99\").busy())')")"
    [ "$busy" = "false" ] && break
done
[ "$busy" = "false" ] || { echo "e2e: request still running after 150s"; exit 1; }

content="$(nvim --server "$SOCK" --remote-expr \
    "luaeval('table.concat(vim.api.nvim_buf_get_lines(vim.fn.bufnr(\"util.lua\"), 0, -1, false), \"\\n\")')")"

echo "$content" | grep -q -- "-- callers: .*main.lua:5" || {
    echo "e2e: expected callers comment not found; buffer was:"
    echo "$content"
    exit 1
}
echo "$content" | grep -q "function M.shout(name)" || {
    echo "e2e: shout function damaged; buffer was:"
    echo "$content"
    exit 1
}
echo "e2e: OK"
