-- Minimal Neovim config for the test harness: no user config, just the
-- agent99 plugin on the runtimepath and lua_ls enabled through the native
-- vim.lsp.config API (no lspconfig needed).

local here = debug.getinfo(1, "S").source:sub(2)
local repo = vim.fn.fnamemodify(here, ":h:h")
vim.opt.rtp:prepend(repo)

-- nvim-dap for the debugger tests: a checkout tests/smoke.sh made under
-- tests/.deps, or the one $AGENT99_TEST_NVIM_DAP points at (a dev
-- machine's lazy.nvim copy). Without either the debug tests skip.
local dap_dir = os.getenv("AGENT99_TEST_NVIM_DAP")
if dap_dir == nil or dap_dir == "" then
    dap_dir = repo .. "/tests/.deps/nvim-dap"
end
if vim.fn.isdirectory(dap_dir) == 1 then
    vim.opt.rtp:prepend(dap_dir)
end

-- Headless test instances must never fight over swap files or shada.
vim.opt.swapfile = false
vim.opt.shadafile = "NONE"

vim.lsp.config("lua_ls", {
    cmd = { "lua-language-server" },
    filetypes = { "lua" },
    root_markers = { ".luarc.json", ".git" },
})
vim.lsp.enable("lua_ls")

-- gopls when present, so the debugger tests get symbol annotation on Go.
if vim.fn.executable("gopls") == 1 then
    vim.lsp.config("gopls", {
        cmd = { "gopls" },
        filetypes = { "go", "gomod" },
        root_markers = { "go.mod", ".git" },
    })
    vim.lsp.enable("gopls")
end
