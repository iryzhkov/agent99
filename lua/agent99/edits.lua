-- Ledger of buffer edits made by the agent's symbol-edit tools during one
-- request. lsp.lua records into it; init.lua takes the list when the request
-- finishes (for the summary notification) and keeps it for :Agent99Revert.
-- Everything lives in editor buffers (unsaved), so reverting is just
-- restoring the recorded lines in reverse order.

local M = {}

local current = {}

--- Record one applied edit.
--- entry = { file, bufnr, name_path, kind, first, last, old_lines, new_count }
function M.record(entry)
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
    current[#current + 1] = entry
end

--- Undo the newest `n` recorded edits (all of them when n is nil), newest
--- first, and drop them from the ledger. Each edit is checked against the
--- buffer first: the lines it wrote must still be there, or something else
--- has changed that region since and blindly restoring would clobber it.
--- File operations carry their own check inside their undo function.
--- Returns the list of undone entries and the list of refusals.
function M.undo_last(n)
    local undone, refused = {}, {}
    local todo = n or #current
    while todo > 0 and #current > 0 do
        local e = current[#current]
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
        todo = todo - 1
    end
    return undone, refused
end

--- Undo a list of edits (as returned by take), newest first. Each entry's
--- coordinates were valid when it was applied, so reverse order restores
--- the original state as long as the user has not edited in between.
function M.revert(edits)
    local reverted = 0
    for i = #edits, 1, -1 do
        local e = edits[i]
        if e.file_op then
            if pcall(e.undo) then
                reverted = reverted + 1
            end
        elseif e.bufnr and vim.api.nvim_buf_is_valid(e.bufnr) then
            local ok = pcall(vim.api.nvim_buf_set_lines, e.bufnr,
                e.first - 1, e.first - 1 + e.new_count, false, e.old_lines)
            if ok then
                reverted = reverted + 1
            end
        end
    end
    return reverted
end

return M
