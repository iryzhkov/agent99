-- The agent panel: a vertical split on the right holding a scrolling
-- conversation (output pane) above a small prompt buffer (input pane), with
-- the window the user started from kept on the left as the code window.
-- Edits the agent makes land in real buffers; the code window jumps to each
-- one as it happens.
--
--   +--------------------+--------------------+
--   |                    |  conversation      |
--   |  code window       |  (markdown, ro)    |
--   |  (edits shown      +--------------------+
--   |   and flashed)     |  input (<CR> send) |
--   +--------------------+--------------------+

local M = {}

local ns = vim.api.nvim_create_namespace("agent99_ui")

M.config = {
    width = 0.4,       -- fraction of columns for the panel
    input_height = 5,
}

local state = {
    out_buf = nil,
    in_buf = nil,
    out_win = nil,
    in_win = nil,
    code_win = nil,
    pending_context = nil, -- selection staged for the next message
}

--- Stage a selection as context for the next chat message. Re-invoking the
--- panel from a new selection (any file) mid-conversation replaces it.
function M.attach_context(ctx)
    state.pending_context = ctx
    M.append(("    · context attached: %s:%d-%d")
        :format(vim.fn.fnamemodify(ctx.file, ":t"), ctx.first, ctx.last))
end

--- Consume the staged context (used by chat_send when building the prompt).
function M.take_context()
    local ctx = state.pending_context
    state.pending_context = nil
    return ctx
end

local function panel_open()
    return state.out_win and vim.api.nvim_win_is_valid(state.out_win)
end
M.is_open = panel_open

local function scroll_to_bottom()
    if panel_open() then
        local count = vim.api.nvim_buf_line_count(state.out_buf)
        pcall(vim.api.nvim_win_set_cursor, state.out_win, { count, 0 })
    end
end

--- Append lines to the conversation pane.
function M.append(lines)
    if not (state.out_buf and vim.api.nvim_buf_is_valid(state.out_buf)) then
        return
    end
    if type(lines) == "string" then
        lines = vim.split(lines, "\n", { plain = true })
    end
    vim.bo[state.out_buf].modifiable = true
    local count = vim.api.nvim_buf_line_count(state.out_buf)
    -- Replace the initial empty line instead of leaving a blank at the top.
    if count == 1 and vim.api.nvim_buf_get_lines(state.out_buf, 0, 1, false)[1] == "" then
        vim.api.nvim_buf_set_lines(state.out_buf, 0, 1, false, lines)
    else
        vim.api.nvim_buf_set_lines(state.out_buf, count, count, false, lines)
    end
    vim.bo[state.out_buf].modifiable = false
    scroll_to_bottom()
end

--- Append a raw text chunk, continuing the current last line (used for
--- token-by-token streaming of the agent's answer).
function M.stream_text(chunk)
    if not (state.out_buf and vim.api.nvim_buf_is_valid(state.out_buf)) then
        return
    end
    local pieces = vim.split(chunk, "\n", { plain = true })
    vim.bo[state.out_buf].modifiable = true
    local count = vim.api.nvim_buf_line_count(state.out_buf)
    local last = vim.api.nvim_buf_get_lines(state.out_buf, count - 1, count, false)[1] or ""
    pieces[1] = last .. pieces[1]
    vim.api.nvim_buf_set_lines(state.out_buf, count - 1, count, false, pieces)
    vim.bo[state.out_buf].modifiable = false
    scroll_to_bottom()
end

--- Wipe the conversation pane back to the welcome text. Pane content only —
--- resetting the transcript itself is chat_reset's job, which calls this.
function M.clear()
    if not (state.out_buf and vim.api.nvim_buf_is_valid(state.out_buf)) then
        return
    end
    vim.bo[state.out_buf].modifiable = true
    vim.api.nvim_buf_set_lines(state.out_buf, 0, -1, false, { "" })
    vim.bo[state.out_buf].modifiable = false
    M.append({ "# agent99", "", "Type a message below — `/help` lists commands.", "" })
end

--- One compact activity line while the agent works (tool calls etc.).
function M.activity(text)
    if #text > 100 then
        text = text:sub(1, 100) .. "…"
    end
    M.append("    · " .. text)
end

local function ensure_bufs()
    if not (state.out_buf and vim.api.nvim_buf_is_valid(state.out_buf)) then
        state.out_buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_name(state.out_buf, "agent99://chat")
        vim.bo[state.out_buf].filetype = "markdown"
        vim.bo[state.out_buf].bufhidden = "hide"
        vim.bo[state.out_buf].modifiable = false
        -- Treesitter renders the markdown (headings, bold, fenced code with
        -- language injection); conceal in the window hides the raw markup.
        pcall(vim.treesitter.start, state.out_buf, "markdown")
    end
    if not (state.in_buf and vim.api.nvim_buf_is_valid(state.in_buf)) then
        state.in_buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_name(state.in_buf, "agent99://input")
        vim.bo[state.in_buf].filetype = "markdown"
        vim.bo[state.in_buf].bufhidden = "hide"
        local a99 = require("agent99")
        vim.keymap.set("n", "<CR>", M.submit, { buffer = state.in_buf, desc = "agent99: send" })
        vim.keymap.set("i", "<C-s>", function()
            vim.cmd.stopinsert()
            M.submit()
        end, { buffer = state.in_buf, desc = "agent99: send" })
        vim.keymap.set("n", "q", M.close, { buffer = state.in_buf })
        vim.keymap.set("n", "gn", function()
            a99.chat_reset()
        end, { buffer = state.in_buf, desc = "agent99: new conversation" })
    end
    for _, b in ipairs({ state.out_buf }) do
        vim.keymap.set("n", "q", M.close, { buffer = b })
        vim.keymap.set("n", "gn", function()
            require("agent99").chat_reset()
        end, { buffer = b, desc = "agent99: new conversation" })
        vim.keymap.set("n", "i", function()
            if state.in_win and vim.api.nvim_win_is_valid(state.in_win) then
                vim.api.nvim_set_current_win(state.in_win)
                vim.cmd.startinsert()
            end
        end, { buffer = b, desc = "agent99: go to input" })
    end
end

function M.open()
    if panel_open() then
        if state.in_win and vim.api.nvim_win_is_valid(state.in_win) then
            vim.api.nvim_set_current_win(state.in_win)
        end
        return
    end
    ensure_bufs()
    state.code_win = vim.api.nvim_get_current_win()
    vim.cmd("botright vsplit")
    state.out_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_width(state.out_win,
        math.max(40, math.floor(vim.o.columns * M.config.width)))
    vim.api.nvim_win_set_buf(state.out_win, state.out_buf)
    vim.wo[state.out_win].winbar = "agent99 — q hide · gn new · i input"
    vim.wo[state.out_win].wrap = true
    vim.wo[state.out_win].linebreak = true
    vim.wo[state.out_win].number = false
    vim.wo[state.out_win].relativenumber = false
    -- Conceal markdown markup (**bold**, `code`, links) for a rendered look;
    -- the raw text reappears on the cursor line for copying.
    vim.wo[state.out_win].conceallevel = 2
    vim.wo[state.out_win].concealcursor = "nc"
    vim.cmd("belowright " .. M.config.input_height .. "split")
    state.in_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(state.in_win, state.in_buf)
    vim.wo[state.in_win].winbar = "prompt — <CR> send (insert: <C-s>)"
    vim.wo[state.in_win].number = false
    vim.wo[state.in_win].relativenumber = false
    vim.api.nvim_set_current_win(state.in_win)
    if vim.api.nvim_buf_line_count(state.out_buf) == 1
        and vim.api.nvim_buf_get_lines(state.out_buf, 0, 1, false)[1] == "" then
        M.append({ "# agent99", "", "Type a message below — `/help` lists commands.", "" })
    end
    scroll_to_bottom()
end

function M.close()
    for _, w in ipairs({ state.in_win, state.out_win }) do
        if w and vim.api.nvim_win_is_valid(w) then
            pcall(vim.api.nvim_win_close, w, true)
        end
    end
    state.out_win, state.in_win = nil, nil
end

function M.toggle()
    if panel_open() then
        M.close()
    else
        M.open()
    end
end

--- The window edits should be displayed in. Falls back to any window that
--- is not part of the panel.
local function edit_window()
    if state.code_win and vim.api.nvim_win_is_valid(state.code_win) then
        return state.code_win
    end
    for _, w in ipairs(vim.api.nvim_list_wins()) do
        if w ~= state.out_win and w ~= state.in_win then
            state.code_win = w
            return w
        end
    end
    return nil
end

--- Follow the agent's attention: when it deliberately reads a file, show
--- that file (at the read position) in the code window. No highlight —
--- edits flash, reads just move the view.
function M.on_read(file, line)
    if not panel_open() then
        return
    end
    vim.schedule(function()
        local win = edit_window()
        if not win then
            return
        end
        local ok, bufnr = pcall(function()
            local b = vim.fn.bufadd(vim.fn.fnamemodify(file, ":p"))
            vim.fn.bufload(b)
            return b
        end)
        if not ok then
            return
        end
        vim.api.nvim_win_set_buf(win, bufnr)
        pcall(vim.api.nvim_win_set_cursor, win,
            { math.min(math.max(line or 1, 1), vim.api.nvim_buf_line_count(bufnr)), 0 })
    end)
end

--- Called by the edits ledger whenever the agent applies a symbol edit:
--- show the edited buffer in the code window, jump to the edit, flash it.
function M.on_edit(entry)
    if not panel_open() then
        return
    end
    vim.schedule(function()
        M.activity(("%s %s in %s"):format(entry.kind, entry.name_path,
            vim.fn.fnamemodify(entry.file, ":t")))
        local win = edit_window()
        if not (win and entry.bufnr and vim.api.nvim_buf_is_valid(entry.bufnr)) then
            return
        end
        vim.api.nvim_win_set_buf(win, entry.bufnr)
        pcall(vim.api.nvim_win_set_cursor, win,
            { math.min(entry.first, vim.api.nvim_buf_line_count(entry.bufnr)), 0 })
        local last = math.max(entry.first + math.max(entry.new_count, 1) - 1, entry.first)
        local mark = vim.api.nvim_buf_set_extmark(entry.bufnr, ns, entry.first - 1, 0, {
            end_row = math.min(last, vim.api.nvim_buf_line_count(entry.bufnr)),
            end_col = 0,
            hl_group = "Agent99Working",
            hl_eol = true,
            strict = false,
        })
        vim.defer_fn(function()
            pcall(vim.api.nvim_buf_del_extmark, entry.bufnr, ns, mark)
        end, 2500)
    end)
end

local HELP = {
    "",
    "**Commands** (type in the prompt):",
    "- `/help` — this text",
    "- `/clear` — new conversation, wipes the pane (also `gn`)",
    "- `/revert` — undo the agent's last batch of edits",
    "- `/cancel` — cancel the running request (also `<leader>9x`)",
    "- `/stats` — usage this session (`/stats all` — lifetime)",
    "- `/history` — past requests",
    "- `/hide` — hide the panel (also `q`; reopen with `<leader>99`)",
    "",
    "**Keys**: `<CR>` send (insert: `<C-s>`) · `i` in the conversation jumps",
    "to the prompt · visual `<leader>99` attaches the selection as context",
    "for the next message, from any file, mid-conversation too.",
    "",
}

local commands = {
    help = function()
        M.append(HELP)
    end,
    clear = function()
        require("agent99").chat_reset()
    end,
    revert = function()
        require("agent99").revert_edits()
    end,
    cancel = function()
        require("agent99").cancel()
    end,
    -- Stats and history render into the conversation itself (local only —
    -- never part of what is sent to the agent).
    stats = function(args)
        local scope = args == "all" and "all" or nil
        local lines = require("agent99").stats_lines(scope)
        if not lines then
            M.append(scope == "all" and "    · no history yet"
                or "    · no requests this session — `/stats all` for lifetime")
            return
        end
        M.append({ "", "```" })
        M.append(lines)
        M.append({ "```", "" })
    end,
    history = function()
        local lines = require("agent99").history_lines(15)
        if not lines then
            M.append("    · no history yet")
            return
        end
        M.append({ "", "```" })
        M.append(lines)
        M.append({ "```", "*(interactive view: :Agent99History)*", "" })
    end,
    hide = function()
        M.close()
    end,
}

--- Read the input pane, clear it, and hand the message to the chat engine.
--- Lines starting with "/" are panel commands, not messages.
function M.submit()
    local a99 = require("agent99")
    local text = vim.trim(table.concat(
        vim.api.nvim_buf_get_lines(state.in_buf, 0, -1, false), "\n"))
    if text == "" then
        return
    end
    vim.api.nvim_buf_set_lines(state.in_buf, 0, -1, false, {})
    local cmd, args = text:match("^/(%S+)%s*(.*)$")
    if cmd then
        if commands[cmd] then
            commands[cmd](vim.trim(args))
        else
            M.append(("    · unknown command /%s — try /help"):format(cmd))
        end
        return
    end
    if a99.busy() then
        vim.notify("agent99: still working on the previous message", vim.log.levels.WARN)
        return
    end
    M.append({ "", "## You", "" })
    M.append(text)
    M.append("")
    a99.chat_send(text)
end

return M
