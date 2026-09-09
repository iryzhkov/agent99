-- Unit checks for the index helpers that need no language server, driven by
-- scratch buffers. The one here is the widening that repairs a symbol a
-- server reported by the range of its name alone: pyright does that for a
-- module constant, and the smoke suite has no pyright to show it with.
--
-- Run with: nvim --clean --headless -u tests/minimal_init.lua -l tests/unit_index.lua

local index = require("agent99.index")

local failures = 0

local function check(name, ok, detail)
    if ok then
        io.stdout:write("ok   " .. name .. "\n")
    else
        failures = failures + 1
        io.stdout:write("FAIL " .. name .. (detail and ("\n     " .. vim.inspect(detail)) or "") .. "\n")
    end
    io.stdout:flush()
end

local function buffer_with(lines, filetype)
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.bo[bufnr].filetype = filetype
    pcall(vim.treesitter.start, bufnr, filetype)
    return bufnr
end

local lua_buf = buffer_with({
    "local RESPONSES = {",
    '    login_ok = "logged in",',
    '    login_bad = "try again",',
    "}",
    "",
    "local TIMEOUT = 30",
    "",
    "local function greet(name)",
    '    return "hello, " .. name',
    "end",
}, "lua")

check("a table constant reaches its closing brace",
    index.statement_end(lua_buf, 1) == 4, index.statement_end(lua_buf, 1))
check("a one-line assignment stays one line",
    index.statement_end(lua_buf, 6) == 6, index.statement_end(lua_buf, 6))
check("a function reaches its end",
    index.statement_end(lua_buf, 8) == 10, index.statement_end(lua_buf, 8))
check("a blank line is its own line",
    index.statement_end(lua_buf, 5) == 5, index.statement_end(lua_buf, 5))
check("a line past the end of the buffer answers itself",
    index.statement_end(lua_buf, 99) == 99, index.statement_end(lua_buf, 99))

-- The same shape in Python, the grammar the fault was found in: pyright
-- reports RESPONSES as one line, and the value runs to the closing brace.
if pcall(vim.treesitter.language.inspect, "python") then
    local py_buf = buffer_with({
        "RESPONSES = {",
        '    "login_ok": "logged in",',
        '    "gone": "not here",',
        "}",
        "",
        "TIMEOUT = 30",
    }, "python")
    check("a python dict constant reaches its closing brace",
        index.statement_end(py_buf, 1) == 4, index.statement_end(py_buf, 1))
    check("a python scalar stays one line",
        index.statement_end(py_buf, 6) == 6, index.statement_end(py_buf, 6))
else
    io.stdout:write("skip  no python treesitter parser\n")
end

-- A file with no parser at all must not error; the entry keeps the line the
-- server gave it.
local plain = buffer_with({ "KEY = value", "OTHER = value" }, "conf")
check("a file with no parser answers the line it was given",
    index.statement_end(plain, 1) == 1, index.statement_end(plain, 1))

if failures > 0 then
    io.stdout:write(("unit_index: %d failed\n"):format(failures))
    vim.cmd("cquit 1")
end
io.stdout:write("unit_index: OK\n")
io.stdout:flush()
vim.cmd("quit")
