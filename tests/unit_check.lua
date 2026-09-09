-- Unit checks for the commands check_project guesses from a project's
-- files. Driven by scratch directories rather than by running anything: the
-- point is which command is chosen, and running it would need the toolchain
-- of every language the guess covers.
--
-- Run with: nvim --clean --headless -u tests/minimal_init.lua -l tests/unit_check.lua

local install = require("agent99.install")

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

local function scratch(files)
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    for name, contents in pairs(files) do
        local dir = vim.fn.fnamemodify(root .. "/" .. name, ":h")
        vim.fn.mkdir(dir, "p")
        if contents ~= false then
            vim.fn.writefile(vim.split(contents, "\n", { plain = true }), root .. "/" .. name)
        end
    end
    return root
end

local function commands(root)
    local out = {}
    for _, g in ipairs(install.guess_check_command(root)) do
        out[#out + 1] = g.cmd
    end
    return out
end

local function any(list, text)
    for _, cmd in ipairs(list) do
        if cmd:find(text, 1, true) then return true end
    end
    return false
end

-- The configuration this Neovim actually loads is checked by starting
-- Neovim on it: its real breakage is load-time, and no static check sees it.
local this_config = vim.fn.stdpath("config")
if vim.fn.executable("nvim") == 0 or vim.uv.fs_stat(this_config .. "/init.lua") == nil then
    io.stdout:write("skip  no init.lua at " .. this_config .. "\n")
else
    local own = commands(this_config)
    check("the loaded configuration is checked by starting Neovim",
        any(own, "nvim --headless") and any(own, "messages") and not any(own, "-u init.lua"), own)
    check("it still gets the Lua syntax check",
        any(own, "luac") or any(own, "luacheck"), own)
end

-- A configuration-shaped tree that is NOT the one Neovim loads: starting
-- `nvim -u <root>/init.lua` there sources that init, but every require and
-- every plugin/after script still resolves out of stdpath("config"), so the
-- check would run the machine's own configuration and call a broken copy
-- clean. No nvim command is guessed for it.
local copy_root = scratch({
    ["init.lua"] = 'require("user.options")',
    ["lua/user/options.lua"] = "return {}",
    ["after/plugin/theme.lua"] = 'vim.cmd("colorscheme default")',
    ["lazy-lock.json"] = "{}",
})
local copy_cmds = commands(copy_root)
check("a configuration copy is not started as a config", not any(copy_cmds, "nvim --headless"), copy_cmds)
check("a configuration copy still gets the Lua syntax check",
    any(copy_cmds, "luac") or any(copy_cmds, "luacheck"), copy_cmds)
vim.fn.delete(copy_root, "rf")

-- A Lua library with an init.lua of its own is not a configuration either.
local lib_root = scratch({
    ["init.lua"] = "return require('lib.core')",
    ["lua/lib/core.lua"] = "return {}",
})
local lib_cmds = commands(lib_root)
check("a plain Lua project is not started as a config",
    not any(lib_cmds, "nvim --headless"), lib_cmds)
vim.fn.delete(lib_root, "rf")

if failures > 0 then
    io.stdout:write(("unit_check: %d failed\n"):format(failures))
    vim.cmd("cquit 1")
end
io.stdout:write("unit_check: OK\n")
io.stdout:flush()
vim.cmd("quit")
