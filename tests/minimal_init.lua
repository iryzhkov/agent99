-- Minimal Neovim config for the test harness: no user config, just the
-- agent99 plugin on the runtimepath and lua_ls enabled through the native
-- vim.lsp.config API (no lspconfig needed).

local here = debug.getinfo(1, "S").source:sub(2)
local repo = vim.fn.fnamemodify(here, ":h:h")
vim.opt.rtp:prepend(repo)

-- Headless test instances must never fight over swap files or shada.
vim.opt.swapfile = false
vim.opt.shadafile = "NONE"

vim.lsp.config("lua_ls", {
    cmd = { "lua-language-server" },
    filetypes = { "lua" },
    root_markers = { ".luarc.json", ".git" },
})
vim.lsp.enable("lua_ls")
