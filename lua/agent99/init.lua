-- agent99: agentic code edits in Neovim, 99-style.
--
-- Select a region, give an instruction, and an LLM agent rewrites the
-- selection; or talk to the agent in a side panel. The agent gets tools
-- backed by this Neovim instance's own LSP clients (see bridge/ and
-- lua/agent99/lsp.lua), so it can chase definitions, references, types,
-- and diagnostics through the same warm language servers the editor is
-- already running.
--
-- Modules: config (options, provider presets, paths, keys), request (the
-- engine: spawn bridge, stream, apply/preview/answer), chat (panel
-- conversation), history (records and stats), prompts, ui (the panel),
-- edits (revert ledger), lsp (editor-side tools), rpc (bridge transport).
-- This module is the public API and wires up commands and keymaps.

local M = {}

local function config() return require("agent99.config") end
local function request() return require("agent99.request") end

-- ------------------------------------------------------------- public API --

--- Toggle the agent panel.
function M.toggle_panel()
    require("agent99.ui").toggle()
end

--- Open the panel from a visual selection: the selection (file, range,
--- text) is staged as context for the next message. Works mid-conversation
--- too - select something new anywhere and re-invoke to continue the chat
--- with fresh context.
function M.panel_visual()
    local buf = vim.api.nvim_get_current_buf()
    local vline = vim.fn.getpos("v")[2]
    local cline = vim.fn.getpos(".")[2]
    local first, last = math.min(vline, cline), math.max(vline, cline)
    vim.api.nvim_feedkeys(
        vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
    local lines = vim.api.nvim_buf_get_lines(buf, first - 1, last, false)
    local truncated = ""
    if #lines > 300 then
        lines = vim.list_slice(lines, 1, 300)
        truncated = "\n... (selection truncated at 300 lines)"
    end
    local ui = require("agent99.ui")
    ui.open()
    ui.attach_context({
        buf = buf,
        file = vim.api.nvim_buf_get_name(buf),
        first = first,
        last = last,
        text = table.concat(lines, "\n") .. truncated,
    })
end

local function visual_request(mode, prompt_label)
    if request().busy() then
        vim.notify("agent99: a request is already running (cancel it first)",
            vim.log.levels.WARN)
        return
    end
    local buf = vim.api.nvim_get_current_buf()
    -- getpos("v")/getpos(".") are valid while still in visual mode.
    local vline = vim.fn.getpos("v")[2]
    local cline = vim.fn.getpos(".")[2]
    local first, last = math.min(vline, cline), math.max(vline, cline)
    -- Leave visual mode NOW (the "x" flag executes the key instead of
    -- queueing it) and only then open the prompt: a queued <Esc> would be
    -- swallowed by vim.ui.input and cancel it before it is ever seen.
    vim.api.nvim_feedkeys(
        vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
    vim.schedule(function()
        vim.ui.input({ prompt = ("%s (lines %d-%d)> "):format(prompt_label, first, last) },
            function(instruction)
                if instruction == nil or instruction:gsub("%s", "") == "" then
                    vim.notify("agent99: cancelled (empty instruction)")
                    return
                end
                request().start(buf, first, last, instruction, { mode = mode })
            end)
    end)
end

--- Edit the current visual selection. Call from a visual-mode mapping.
function M.edit_visual()
    visual_request("edit", "agent99")
end

--- Ask a question about the current visual selection; the answer opens in a
--- markdown split, and a follow-up afterwards turns the discussion into an
--- edit of the selected region.
function M.ask_visual()
    visual_request("ask", "agent99 ask")
end

--- Follow up on the last edit or answer (full conversation preserved).
function M.followup(instruction, internal)
    request().followup(instruction, internal)
end

--- Programmatic entry point (used by tests): edit an explicit line range.
function M.edit_range(buf, first, last, instruction)
    if request().busy() then
        error("agent99: a request is already running")
    end
    request().start(buf, first, last, instruction)
end

--- Programmatic entry point (used by tests): ask about an explicit range.
function M.ask_range(buf, first, last, question)
    if request().busy() then
        error("agent99: a request is already running")
    end
    request().start(buf, first, last, question, { mode = "ask" })
end

function M.cancel() request().cancel() end
function M.accept() request().accept() end
function M.revert_edits() request().revert_edits() end
function M.busy() return request().busy() end
function M.pending_preview() return request().pending_preview() end

function M.chat_send(text) require("agent99.chat").send(text) end
function M.chat_reset() require("agent99.chat").reset() end

function M.history() require("agent99.history").browse() end
function M.stats(scope) require("agent99.history").stats(scope) end
function M.stats_lines(scope) return require("agent99.history").stats_lines(scope) end
function M.history_lines(n) return require("agent99.history").history_lines(n) end

function M.set_key() config().set_key() end

function M.view_logs()
    vim.cmd.split(config().log_path())
end

-- ------------------------------------------------------------------ setup --

local function define_commands()
    local cmd = vim.api.nvim_create_user_command
    cmd("Agent99", M.toggle_panel, {})
    cmd("Agent99Clear", M.chat_reset, {})
    cmd("Agent99Cancel", M.cancel, {})
    cmd("Agent99Apply", M.accept, {})
    cmd("Agent99Revert", M.revert_edits, {})
    cmd("Agent99History", M.history, {})
    cmd("Agent99Stats", function(o)
        M.stats(vim.trim(o.args) == "all" and "all" or nil)
    end, { nargs = "?", complete = function() return { "all" } end })
    cmd("Agent99SetKey", M.set_key, {})
    cmd("Agent99Logs", M.view_logs, {})
end

local function define_keymaps(maps)
    local function map(mode, lhs, rhs, desc)
        if lhs and lhs ~= "" then
            vim.keymap.set(mode, lhs, rhs, { desc = "agent99: " .. desc })
        end
    end
    map("n", maps.toggle_panel, M.toggle_panel,
        "toggle agent panel (chat persists; gn / :Agent99Clear resets)")
    map("x", maps.panel_selection, M.panel_visual,
        "open panel with the selection as context for the next message")
    map("x", maps.edit, M.edit_visual, "edit selection")
    map("x", maps.ask, M.ask_visual, "ask about selection (answer in split)")
    map("n", maps.followup, M.followup, "follow up on last edit/answer")
    map("n", maps.cancel, M.cancel, "cancel request / discard preview")
    map("n", maps.history, M.history, "request history")
    map("n", maps.logs, M.view_logs, "view logs")
end

function M.setup(opts)
    local cfg = config().setup(opts)
    vim.api.nvim_set_hl(0, "Agent99Working", { default = true, link = "Visual" })
    require("agent99.ui").config = cfg.ui
    define_commands()
    if cfg.keymaps then
        define_keymaps(cfg.keymaps)
    end
end

return M
