-- Driven by tests/e2e.sh inside a headless Neovim whose cwd is a temporary
-- copy of the test project. Fires one real agent edit; the shell script
-- polls busy() and then asserts on the buffer content.

local a99 = require("agent99")
a99.setup({ keymaps = false, preview = false })
local buf = vim.fn.bufadd(vim.fn.fnamemodify("lua/testproj/util.lua", ":p"))
vim.fn.bufload(buf)
a99.edit_range(buf, 10, 12,
    "Immediately above the function, add exactly one Lua comment line of the form "
    .. "'-- callers: <absolute file path>:<line>' listing every call site of M.shout "
    .. "in this project. Use the LSP references tool to find the call sites. "
    .. "Keep the function itself byte-for-byte unchanged.")
