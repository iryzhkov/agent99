-- The compose window: a telescope-style floating prompt for the region
-- flows (edit/ask), laid out like a picker - selection list top-left,
-- instruction prompt below it, live preview of the highlighted selection
-- on the right:
--
--   +--------------------+------------------------------+
--   | selections (j/k)   |  preview of the highlighted  |
--   |  > target a.lua:.. |  selection, syntax-highlit   |
--   |    ctx    b.go:..  |                              |
--   +--------------------+                              |
--   | instruction prompt |                              |
--   +--------------------+------------------------------+
--
-- Invoking <leader>9v / <leader>9a from a visual selection opens it with
-- that selection as the edit/ask TARGET; invoking again from another
-- selection (any file) stacks it as additional context, and the typed
-- draft survives closing. <CR> sends target + contexts + draft as one
-- request; q/<Esc> keeps the draft, gx discards, x in the list removes a
-- context, <Tab> hops between prompt and list.

local M = {}

local MAX_SELECTION_LINES = 300

local state = {
    mode = nil,     -- "edit" or "ask", locked by the first staged selection
    target = nil,   -- { buf, file, first, last, text } - the edit/ask region
    contexts = {},  -- additional selections
    buf = nil,      -- draft buffer (persists while hidden)
    win = nil,      -- prompt window
    list_buf = nil,
    list_win = nil,
    prev_buf = nil,
    prev_win = nil,
    closing = false,
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

-- Target first, then the stacked contexts.
local function entries()
    local out = {}
    if state.target then
        out[#out + 1] = state.target
    end
    vim.list_extend(out, state.contexts)
    return out
end

local function close_all()
    if state.closing then
        return
    end
    state.closing = true
    for _, w in ipairs({ state.win, state.list_win, state.prev_win }) do
        if w and vim.api.nvim_win_is_valid(w) then
            pcall(vim.api.nvim_win_close, w, true)
        end
    end
    state.win, state.list_win, state.prev_win = nil, nil, nil
    state.closing = false
end

--- Drop the draft and every staged selection.
function M.discard()
    close_all()
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
    local mode = state.mode
    local contexts = state.contexts
    close_all()
    vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, {})
    state.mode, state.target, state.contexts = nil, nil, {}
    require("agent99.request").start(target.buf, target.first, target.last,
        text, { mode = mode, contexts = contexts })
end

-- ---------------------------------------------------------------- render --

local function current_index()
    if not (state.list_win and vim.api.nvim_win_is_valid(state.list_win)) then
        return 1
    end
    return vim.api.nvim_win_get_cursor(state.list_win)[1]
end

local function update_preview()
    if not (state.prev_buf and vim.api.nvim_buf_is_valid(state.prev_buf)) then
        return
    end
    local entry = entries()[current_index()]
    if not entry then
        return
    end
    vim.bo[state.prev_buf].modifiable = true
    vim.api.nvim_buf_set_lines(state.prev_buf, 0, -1, false,
        vim.split(entry.text, "\n", { plain = true }))
    vim.bo[state.prev_buf].modifiable = false
    local ft = vim.filetype.match({ filename = entry.file }) or ""
    if vim.bo[state.prev_buf].filetype ~= ft then
        vim.bo[state.prev_buf].filetype = ft
    end
    if state.prev_win and vim.api.nvim_win_is_valid(state.prev_win) then
        vim.api.nvim_win_set_config(state.prev_win, {
            title = (" %s:%d-%d "):format(short(entry.file), entry.first, entry.last),
            title_pos = "center",
        })
    end
end

local function update_list()
    if not (state.list_buf and vim.api.nvim_buf_is_valid(state.list_buf)) then
        return
    end
    local lines = {}
    for i, e in ipairs(entries()) do
        lines[#lines + 1] = ("%s %s:%d-%d"):format(
            i == 1 and (state.mode or "edit") or " ctx ",
            short(e.file), e.first, e.last)
    end
    vim.bo[state.list_buf].modifiable = true
    vim.api.nvim_buf_set_lines(state.list_buf, 0, -1, false, lines)
    vim.bo[state.list_buf].modifiable = false
    update_preview()
end

local function move_selection(delta)
    if not (state.list_win and vim.api.nvim_win_is_valid(state.list_win)) then
        return
    end
    local n = #entries()
    local row = math.min(math.max(current_index() + delta, 1), math.max(n, 1))
    pcall(vim.api.nvim_win_set_cursor, state.list_win, { row, 0 })
    update_preview()
end

local function remove_current()
    local idx = current_index()
    if idx == 1 then
        vim.notify("agent99: the target cannot be removed (gx discards everything)")
        return
    end
    table.remove(state.contexts, idx - 1)
    update_list()
    move_selection(0)
end

local function focus_prompt(insert)
    if win_open() then
        vim.api.nvim_set_current_win(state.win)
        if insert then
            vim.cmd.startinsert({ bang = true })
        end
    end
end

local function focus_list()
    if state.list_win and vim.api.nvim_win_is_valid(state.list_win) then
        vim.cmd.stopinsert()
        vim.api.nvim_set_current_win(state.list_win)
    end
end

local function ensure_prompt_buf()
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
    vim.keymap.set("n", "q", close_all,
        vim.tbl_extend("force", o, { desc = "agent99: close (keep draft)" }))
    vim.keymap.set("n", "<Esc>", close_all,
        vim.tbl_extend("force", o, { desc = "agent99: close (keep draft)" }))
    vim.keymap.set("n", "gx", M.discard,
        vim.tbl_extend("force", o, { desc = "agent99: discard draft" }))
    vim.keymap.set({ "n", "i" }, "<Tab>", focus_list,
        vim.tbl_extend("force", o, { desc = "agent99: to selection list" }))
    vim.keymap.set({ "n", "i" }, "<C-j>", function() move_selection(1) end,
        vim.tbl_extend("force", o, { desc = "agent99: next selection" }))
    vim.keymap.set({ "n", "i" }, "<C-k>", function() move_selection(-1) end,
        vim.tbl_extend("force", o, { desc = "agent99: previous selection" }))
end

local function make_scratch(name)
    local buf = vim.api.nvim_create_buf(false, true)
    pcall(vim.api.nvim_buf_set_name, buf, name)
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].modifiable = false
    return buf
end

--- Open (or re-focus) the compose picker over the current draft.
function M.open()
    ensure_prompt_buf()
    if win_open() then
        update_list()
        focus_prompt(false)
        return
    end
    local cc = (require("agent99.config").options.ui or {}).compose or {}
    local border = cc.border or "rounded"
    local W = math.min(cc.width or 110, vim.o.columns - 6)
    local H = math.min(cc.height or 24, vim.o.lines - 6)
    local pw = math.floor(W * (cc.preview_ratio or 0.55))
    local lw = W - pw - 2
    local prompt_h = cc.prompt_height or 5
    local list_h = math.max(H - prompt_h - 2, 3)
    local row = math.floor((vim.o.lines - H) / 2) - 1
    local col = math.floor((vim.o.columns - W) / 2)

    state.list_buf = make_scratch("agent99://compose-list")
    state.prev_buf = make_scratch("agent99://compose-preview")

    state.list_win = vim.api.nvim_open_win(state.list_buf, false, {
        relative = "editor", row = row, col = col, width = lw, height = list_h,
        style = "minimal", border = border,
        title = " selections — j/k · x remove ", title_pos = "center",
    })
    vim.wo[state.list_win].cursorline = true

    state.prev_win = vim.api.nvim_open_win(state.prev_buf, false, {
        relative = "editor", row = row, col = col + lw + 2,
        width = pw, height = H,
        style = "minimal", border = border,
        title = " preview ", title_pos = "center",
    })
    vim.wo[state.prev_win].wrap = false
    vim.wo[state.prev_win].number = true

    state.win = vim.api.nvim_open_win(state.buf, true, {
        relative = "editor", row = row + list_h + 2, col = col,
        width = lw, height = prompt_h,
        style = "minimal", border = border,
        title = (" %s — <CR> send · <Tab> list · gx discard "):format(state.mode or "compose"),
        title_pos = "center",
    })
    vim.wo[state.win].wrap = true
    vim.wo[state.win].linebreak = true

    -- List-side keys: picker navigation plus the same lifecycle keys.
    local lo = { buffer = state.list_buf }
    vim.keymap.set("n", "x", remove_current,
        vim.tbl_extend("force", lo, { desc = "agent99: remove context" }))
    vim.keymap.set("n", "<CR>", send, vim.tbl_extend("force", lo, { desc = "agent99: send" }))
    vim.keymap.set("n", "<Tab>", function() focus_prompt(false) end,
        vim.tbl_extend("force", lo, { desc = "agent99: to prompt" }))
    vim.keymap.set("n", "i", function() focus_prompt(true) end,
        vim.tbl_extend("force", lo, { desc = "agent99: to prompt (insert)" }))
    vim.keymap.set("n", "q", close_all, vim.tbl_extend("force", lo, {}))
    vim.keymap.set("n", "<Esc>", close_all, vim.tbl_extend("force", lo, {}))
    vim.keymap.set("n", "gx", M.discard, vim.tbl_extend("force", lo, {}))
    vim.api.nvim_create_autocmd("CursorMoved", {
        buffer = state.list_buf,
        callback = update_preview,
    })
    -- Closing any pane (however it happens) closes the whole picker.
    for _, w in ipairs({ state.win, state.list_win, state.prev_win }) do
        vim.api.nvim_create_autocmd("WinClosed", {
            pattern = tostring(w),
            once = true,
            callback = function()
                vim.schedule(close_all)
            end,
        })
    end

    update_list()
    if vim.api.nvim_buf_get_lines(state.buf, 0, -1, false)[1] == "" then
        vim.cmd.startinsert()
    end
end

--- Stage the current visual selection and open the compose picker. The
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
        local dup = state.target.file == entry.file
            and state.target.first == entry.first and state.target.last == entry.last
        for _, c in ipairs(state.contexts) do
            if c.file == entry.file and c.first == entry.first and c.last == entry.last then
                dup = true
            end
        end
        if not dup then
            state.contexts[#state.contexts + 1] = entry
        end
    end
    vim.schedule(M.open)
end

return M
