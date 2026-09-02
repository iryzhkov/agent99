-- The compose window: a telescope-style floating prompt for the region
-- flows (edit/ask). Invoking <leader>9v / <leader>9a from a visual
-- selection opens it with that selection as the edit/ask TARGET; invoking
-- it again from another selection (any file) stacks that selection as
-- additional context instead of starting over, and the typed draft
-- survives closing the window. <CR> sends target + contexts + draft as one
-- request; the draft and stack reset only on send or explicit clear.

local M = {}

local MAX_SELECTION_LINES = 300

local state = {
    mode = nil,     -- "edit" or "ask", locked by the first staged selection
    target = nil,   -- { buf, file, first, last } - the region being edited/asked about
    contexts = {},  -- additional { file, first, last, text } selections
    buf = nil,      -- draft buffer (persists while hidden)
    win = nil,
}

local function capture(buf, first, last)
    local lines = vim.api.nvim_buf_get_lines(buf, first - 1, last, false)
    local truncated = ""
    if #lines > MAX_SELECTION_LINES then
        lines = vim.list_slice(lines, 1, MAX_SELECTION_LINES)
        truncated = "\n... (selection truncated at " .. MAX_SELECTION_LINES .. " lines)"
    end
    return {
        buf = buf,
        file = vim.api.nvim_buf_get_name(buf),
        first = first,
        last = last,
        text = table.concat(lines, "\n") .. truncated,
    }
end

local function short(file)
    return vim.fn.fnamemodify(file, ":t")
end

local function win_open()
    return state.win and vim.api.nvim_win_is_valid(state.win)
end

local function title()
    if not state.target then
        return " agent99 "
    end
    return (" agent99 %s — %s:%d-%d "):format(state.mode,
        short(state.target.file), state.target.first, state.target.last)
end

local function footer()
    local parts = {}
    for _, c in ipairs(state.contexts) do
        parts[#parts + 1] = ("%s:%d-%d"):format(short(c.file), c.first, c.last)
    end
    local hint = "<CR> send · q keep draft · gx discard"
    if #parts == 0 then
        return " " .. hint .. " "
    end
    return (" +context: %s · %s "):format(table.concat(parts, ", "), hint)
end

local function refresh_border()
    if win_open() then
        vim.api.nvim_win_set_config(state.win, { title = title(), title_pos = "center",
            footer = footer(), footer_pos = "center" })
    end
end

local function close_win()
    if win_open() then
        pcall(vim.api.nvim_win_close, state.win, true)
    end
    state.win = nil
end

--- Drop the draft and every staged selection.
function M.discard()
    close_win()
    if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
        vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, {})
    end
    state.mode, state.target, state.contexts = nil, nil, {}
    vim.notify("agent99: draft discarded")
end

local function send()
    local a99req = require("agent99.request")
    if a99req.busy() then
        vim.notify("agent99: a request is already running (cancel it first)",
            vim.log.levels.WARN)
        return
    end
    local text = vim.trim(table.concat(
        vim.api.nvim_buf_get_lines(state.buf, 0, -1, false), "\n"))
    if text == "" then
        vim.notify("agent99: empty instruction", vim.log.levels.WARN)
        return
    end
    local target = state.target
    if not (target and vim.api.nvim_buf_is_valid(target.buf)) then
        vim.notify("agent99: the target buffer is gone - draft kept, reselect and retry",
            vim.log.levels.WARN)
        return
    end
    -- Extra selections ride along inside the instruction, so the prompt
    -- builder and engine stay unchanged.
    local instruction = text
    if #state.contexts > 0 then
        local parts = { text, "",
            "The user attached additional context selections:" }
        for _, c in ipairs(state.contexts) do
            parts[#parts + 1] = ("<context file=%q lines=%d-%d>"):format(
                c.file, c.first, c.last)
            parts[#parts + 1] = c.text
            parts[#parts + 1] = "</context>"
        end
        instruction = table.concat(parts, "\n")
    end
    local mode = state.mode
    close_win()
    vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, {})
    state.mode, state.target, state.contexts = nil, nil, {}
    require("agent99.request").start(target.buf, target.first, target.last,
        instruction, { mode = mode })
end

local function ensure_buf()
    if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
        return
    end
    state.buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(state.buf, "agent99://compose")
    vim.bo[state.buf].filetype = "markdown"
    vim.bo[state.buf].bufhidden = "hide"
    local o = { buffer = state.buf }
    vim.keymap.set("n", "<CR>", send,
        vim.tbl_extend("force", o, { desc = "agent99: send" }))
    vim.keymap.set("i", "<C-s>", function()
        vim.cmd.stopinsert()
        send()
    end, vim.tbl_extend("force", o, { desc = "agent99: send" }))
    vim.keymap.set("n", "q", close_win,
        vim.tbl_extend("force", o, { desc = "agent99: close (keep draft)" }))
    vim.keymap.set("n", "<Esc>", close_win,
        vim.tbl_extend("force", o, { desc = "agent99: close (keep draft)" }))
    vim.keymap.set("n", "gx", M.discard,
        vim.tbl_extend("force", o, { desc = "agent99: discard draft" }))
end

--- Open (or re-open) the compose float over the current draft.
function M.open()
    ensure_buf()
    if win_open() then
        vim.api.nvim_set_current_win(state.win)
    else
        local width = math.min(72, vim.o.columns - 8)
        local height = 8
        state.win = vim.api.nvim_open_win(state.buf, true, {
            relative = "editor",
            width = width,
            height = height,
            row = math.floor((vim.o.lines - height) / 2),
            col = math.floor((vim.o.columns - width) / 2),
            style = "minimal",
            border = "rounded",
            title = title(),
            title_pos = "center",
            footer = footer(),
            footer_pos = "center",
        })
        vim.wo[state.win].wrap = true
        vim.wo[state.win].linebreak = true
    end
    refresh_border()
    if vim.api.nvim_buf_get_lines(state.buf, 0, -1, false)[1] == "" then
        vim.cmd.startinsert()
    end
end

--- Stage the current visual selection and open the compose window. The
--- first staged selection becomes the edit/ask target and locks the mode;
--- later ones (from any file) stack as additional context. Line numbers
--- are captured now, so heavy editing of the target region before sending
--- can shift them - send promptly or restage.
function M.from_visual(mode)
    local buf = vim.api.nvim_get_current_buf()
    local vline = vim.fn.getpos("v")[2]
    local cline = vim.fn.getpos(".")[2]
    local first, last = math.min(vline, cline), math.max(vline, cline)
    vim.api.nvim_feedkeys(
        vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
    local entry = capture(buf, first, last)
    if not state.target then
        state.mode = mode
        state.target = entry
    else
        local dup = false
        for _, c in ipairs(state.contexts) do
            if c.file == entry.file and c.first == entry.first and c.last == entry.last then
                dup = true
            end
        end
        local is_target = state.target.file == entry.file
            and state.target.first == entry.first and state.target.last == entry.last
        if not dup and not is_target then
            state.contexts[#state.contexts + 1] = entry
        end
    end
    vim.schedule(M.open)
end

return M
