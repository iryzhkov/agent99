-- Ledger of buffer edits made by the agent's symbol-edit tools during one
-- request. lsp.lua records into it; init.lua takes the list when the request
-- finishes (for the summary notification) and keeps it for :Agent99Revert.
-- Everything lives in editor buffers (unsaved), so reverting is just
-- restoring the recorded lines in reverse order.

local M = {}

local current = {}

-- One tool call is one undo step, however many files or ledger entries it
-- took. A rename across seven files was seven entries, so undo_edit(count=1)
-- put two of them back and left the package uncompilable; a move_symbols was
-- three, and undoing one of those restored the destination while the symbol
-- stayed deleted from the source - the function was then in neither file.
-- Entries recorded inside the same group are undone together, in order.
local group_seq = 0
local open_group = nil

--- Record everything `fn` writes as one undo step.
function M.as_one_step(fn)
    local outer = open_group
    group_seq = group_seq + 1
    open_group = group_seq
    local ok, res = pcall(fn)
    open_group = outer
    if not ok then error(res, 0) end
    return res
end

local function stamp(entry)
    if open_group then
        entry.group = open_group
    else
        group_seq = group_seq + 1
        entry.group = group_seq
    end
end

--- Record one applied edit.
--- entry = { file, bufnr, name_path, kind, first, last, old_lines, new_count }
function M.record(entry)
    stamp(entry)
    current[#current + 1] = entry
    -- Live UI: show the edit in the code window as it happens.
    pcall(function()
        require("agent99.ui").on_edit(entry)
    end)
end

--- Number of edits recorded for the running request.
function M.count()
    return #current
end

--- Return the recorded edits and start a fresh ledger.
function M.take()
    local out = current
    current = {}
    return out
end

--- Record one file-lifecycle operation (create, move, delete). These do not
--- live in a buffer region, so the entry carries its own `undo` function,
--- which returns nil on success or a reason for refusing.
--- entry = { file, kind, file_op = true, undo = function() ... end }
function M.record_file_op(entry)
    entry.file_op = true
    stamp(entry)
    current[#current + 1] = entry
end

--- How many undo steps the ledger holds: tool calls, not files touched.
function M.operations()
    local seen, n = {}, 0
    for _, e in ipairs(current) do
        if e.group == nil or not seen[e.group] then
            if e.group ~= nil then seen[e.group] = true end
            n = n + 1
        end
    end
    return n
end

--- Undo the newest `n` recorded edits (all of them when n is nil), newest
--- first, and drop them from the ledger. Each edit is checked against the
--- buffer first: the lines it wrote must still be there, or something else
--- has changed that region since and blindly restoring would clobber it.
--- File operations carry their own check inside their undo function.
--- Returns the list of undone entries and the list of refusals.
function M.undo_last(n)
    local undone, refused = {}, {}
    local todo = n or M.operations()
    -- `todo` counts steps; a step is every entry sharing the newest group.
    local step_group = nil
    while todo > 0 and #current > 0 do
        local e = current[#current]
        if step_group == nil then
            step_group = e.group
        elseif e.group ~= step_group then
            todo = todo - 1
            step_group = e.group
            if todo == 0 then break end
        end
        local why
        if e.file_op then
            -- Not `ok and res or ...`: a successful undo returns nil, which
            -- that idiom turns into the refusal reason "nil".
            local ok, res = pcall(e.undo)
            if ok then
                why = res
            else
                why = tostring(res)
            end
        elseif not (e.bufnr and vim.api.nvim_buf_is_valid(e.bufnr)) then
            why = "its buffer is gone"
        else
            local now = vim.api.nvim_buf_get_lines(e.bufnr,
                e.first - 1, e.first - 1 + e.new_count, false)
            if not vim.deep_equal(now, e.new_lines or {}) then
                why = "the region changed since the edit; fix it by hand"
            end
        end
        if why then
            refused[#refused + 1] = { file = e.file, name_path = e.name_path, why = why }
            break -- older edits below it would be off too
        end
        if not e.file_op then
            vim.api.nvim_buf_set_lines(e.bufnr, e.first - 1, e.first - 1 + e.new_count,
                false, e.old_lines)
        end
        undone[#undone + 1] = e
        current[#current] = nil
    end
    return undone, refused
end

--- Where the lines an edit wrote sit now: at the recorded row when the text
--- there still reads as written, else at the one nearby row where it does
--- (an edit above it since has shifted it), else nil. The same check
--- undo_last makes, so a revert never writes over something else.
local function locate_written(e)
    local want = e.new_lines or {}
    local total = vim.api.nvim_buf_line_count(e.bufnr)
    local function at(row)
        if row < 1 or row - 1 + e.new_count > total then
            return false
        end
        return vim.deep_equal(
            vim.api.nvim_buf_get_lines(e.bufnr, row - 1, row - 1 + e.new_count, false), want)
    end
    if at(e.first) then
        return e.first
    end

    local found
    for d = 1, math.max(e.first - 1, total - e.first) do
        for _, row in ipairs({ e.first - d, e.first + d }) do
            if at(row) then
                if found then
                    return nil -- ambiguous
                end
                found = row
            end
        end
    end
    return found
end

--- Shift the recorded region of every entry in `bufnr` that sits entirely
--- below old line `after` by `delta` lines. Called when polishing an edit
--- adds or removes lines above earlier edits (an import block growing), so
--- those entries keep pointing at the text they wrote and a later undo
--- does not refuse them as "changed since".
function M.shift(bufnr, after, delta)
    if delta == 0 then return end
    for _, e in ipairs(current) do
        if not e.file_op and e.bufnr == bufnr and e.first > after then
            e.first = e.first + delta
            if e.last then e.last = e.last + delta end
        end
    end
end

--- Undo a list of edits (as returned by take), newest first. Each entry is
--- checked the way undo_last checks it: the lines it wrote must still be
--- where it wrote them (or at one unambiguous place nearby, when edits
--- above have moved them), or it is refused rather than clobbering what is
--- there now. Returns the number reverted and the list of refusals.
function M.revert(edits)
    local reverted, refused = 0, {}
    for i = #edits, 1, -1 do
        local e = edits[i]
        local why
        if e.file_op then
            -- Not `ok and res or ...`: a successful undo returns nil, which
            -- that idiom turns into the refusal reason "nil".
            local ok, res = pcall(e.undo)
            if ok then
                why = res
            else
                why = tostring(res)
            end
        elseif not (e.bufnr and vim.api.nvim_buf_is_valid(e.bufnr)) then
            why = "its buffer is gone"
        else
            local row = locate_written(e)
            if not row then
                why = "the edited text is no longer where it was written; fix it by hand"
            else
                local ok = pcall(vim.api.nvim_buf_set_lines, e.bufnr,
                    row - 1, row - 1 + e.new_count, false, e.old_lines)
                if not ok then
                    why = "could not restore the lines"
                end
            end
        end
        if why then
            refused[#refused + 1] = { file = e.file, name_path = e.name_path, why = why }
        else
            reverted = reverted + 1
        end
    end
    return reverted, refused
end

return M
