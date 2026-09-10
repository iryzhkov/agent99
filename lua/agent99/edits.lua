-- Ledger of buffer edits made by the agent's symbol-edit tools during one
-- request. lsp.lua records into it; init.lua takes the list when the request
-- finishes (for the summary notification) and keeps it for :Agent99Revert.
-- Everything lives in editor buffers (unsaved), so reverting is just
-- restoring the recorded lines in reverse order.
--
-- One ledger per client, not one per editor. This Neovim serves every client
-- that opened its root, and with a single stack `undo_edit()` with no
-- arguments popped whatever the newest edit in the editor was: one agent's
-- undo reverted another agent's edit, reported success, and never told the
-- agent whose work had gone. See agent99/client.lua for where the id that
-- keys these comes from.

local M = {}

local client = require("agent99.client")

local ledgers = {}    -- [client] = { entry, ... }, newest last
local groups = {}     -- [client] = { seq = n, open = n or nil }

local function ledger()
    return client.slot(ledgers)
end

local function group_state()
    local id = client.current()
    if not groups[id] then groups[id] = { seq = 0 } end
    return groups[id]
end

-- How many undo steps a list of entries holds: tool calls, not files
-- touched.
local function count_steps(entries)
    local seen, n = {}, 0
    for _, e in ipairs(entries) do
        if e.group == nil or not seen[e.group] then
            if e.group ~= nil then seen[e.group] = true end
            n = n + 1
        end
    end
    return n
end

-- One tool call is one undo step, however many files or ledger entries it
-- took. A rename across seven files was seven entries, so undo_edit(count=1)
-- put two of them back and left the package uncompilable; a move_symbols was
-- three, and undoing one of those restored the destination while the symbol
-- stayed deleted from the source - the function was then in neither file.
-- Entries recorded inside the same group are undone together, in order.

--- Record everything `fn` writes as one undo step.
function M.as_one_step(fn)
    local state = group_state()
    local outer = state.open
    state.seq = state.seq + 1
    state.open = state.seq
    local ok, res = pcall(fn)
    state.open = outer
    if not ok then error(res, 0) end
    return res
end

local function stamp(entry)
    local state = group_state()
    if state.open then
        entry.group = state.open
    else
        state.seq = state.seq + 1
        entry.group = state.seq
    end
end

--- Record one applied edit.
--- entry = { file, bufnr, name_path, kind, first, last, old_lines, new_count }
function M.record(entry)
    stamp(entry)
    local current = ledger()
    current[#current + 1] = entry
    -- Live UI: show the edit in the code window as it happens.
    pcall(function()
        require("agent99.ui").on_edit(entry)
    end)
end

--- Number of edits this client has recorded.
function M.count()
    return #ledger()
end

--- Return this client's recorded edits and start it a fresh ledger.
function M.take()
    local id = client.current()
    local out = ledgers[id] or {}
    ledgers[id] = {}
    return out
end

--- Record one file-lifecycle operation (create, move, delete). These do not
--- live in a buffer region, so the entry carries its own `undo` function,
--- which returns nil on success or a reason for refusing.
--- entry = { file, kind, file_op = true, undo = function() ... end }
function M.record_file_op(entry)
    entry.file_op = true
    stamp(entry)
    local current = ledger()
    current[#current + 1] = entry
end

--- How many undo steps this client's ledger holds: tool calls, not files
--- touched.
function M.operations()
    return count_steps(ledger())
end

--- What the other clients using this editor have pending: how many of them,
--- and how many undo steps between them. A reply that undid nothing, or that
--- undid only this client's own work, can then say what it left alone
--- instead of being silent about it.
function M.others()
    local id, clients, steps = client.current(), 0, 0
    for who, entries in pairs(ledgers) do
        if who ~= id and #entries > 0 then
            clients = clients + 1
            steps = steps + count_steps(entries)
        end
    end
    return { clients = clients, steps = steps }
end

--- The files the newest `n` steps of this client's ledger touch, absolute
--- paths, newest first. Asked before an undo, so the files that use what is
--- about to be put back can be loaded while the diagnostics baseline is still
--- the pre-undo one. Same step grouping as undo_last, so the two agree about
--- what one step is.
function M.pending_files(n)
    local current = ledger()
    local todo = n or M.operations()
    local step_group, out, seen = nil, {}, {}
    for i = #current, 1, -1 do
        if todo <= 0 then break end
        local e = current[i]
        if step_group == nil then
            step_group = e.group
        elseif e.group ~= step_group then
            todo = todo - 1
            step_group = e.group
            if todo == 0 then break end
        end
        if e.file and not seen[e.file] then
            seen[e.file] = true
            out[#out + 1] = e.file
        end
    end
    return out
end

--- Undo the newest `n` edits this client recorded (all of them when n is
--- nil), newest first, and drop them from its ledger. Another client's
--- entries are not in this ledger and are never reached. Each edit is checked
--- against the buffer first: the lines it wrote must still be there, or
--- something else has changed that region since and blindly restoring would
--- clobber it. File operations carry their own check inside their undo
--- function.
--- Returns the list of undone entries and the list of refusals.
--- `skip` drops an entry that refuses to undo instead of stopping there:
--- one region changed by hand made every older edit unreachable, and the
--- only way out was git.
function M.undo_last(n, skip)
    local undone, refused, dropped = {}, {}, {}
    local current = ledger()
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
            -- Against the file as it is now, not as the editor last read it:
            -- a region changed on disk went undetected, the undo wrote over
            -- it in the buffer, and only the save refused - by which point
            -- the ledger entry was gone and the hand edit with it.
            pcall(function()
                require("agent99.core").resync_buf(e.bufnr)
            end)
            -- Anything the editor throws here is this one entry's problem,
            -- not the call's: undo_edit(all=true) died on a single bad entry
            -- with a raw Lua error and no account of the thirty it had
            -- already undone. A refusal is an account.
            local okr, now = pcall(vim.api.nvim_buf_get_lines, e.bufnr,
                e.first - 1, e.first - 1 + e.new_count, false)
            if not okr then
                why = ("the editor refused to read the region back: %s"):format(tostring(now))
            elseif not vim.deep_equal(now, e.new_lines or {}) then
                why = "the region changed since the edit; fix it by hand"
            end
        end
        if why then
            refused[#refused + 1] = { file = e.file, name_path = e.name_path, why = why }
            if not skip then
                break -- older edits below it would be off too
            end
            -- Asked to skip: forget this entry and carry on with the older
            -- ones. They are not made safer by it, so each is still checked.
            dropped[#dropped + 1] = { file = e.file, name_path = e.name_path, why = why }
            current[#current] = nil
            -- Dropping is not undoing: the step the caller asked for is still
            -- owed, and the next entry belongs to it.
            step_group = nil
            goto continue
        end
        if not e.file_op then
            local oks, serr = pcall(vim.api.nvim_buf_set_lines, e.bufnr,
                e.first - 1, e.first - 1 + e.new_count, false, e.old_lines)
            if not oks then
                refused[#refused + 1] = { file = e.file, name_path = e.name_path,
                    why = ("could not restore the lines: %s"):format(tostring(serr)) }
                break
            end
        end
        -- Written first, dropped from the ledger only once it is safely on
        -- disk: a failed save used to consume the entry, so the edit stayed
        -- in the file with nothing left to undo it with.
        local saved, save_why = true, nil
        if e.bufnr and vim.api.nvim_buf_is_valid(e.bufnr) then
            local okw, res = pcall(function()
                return require("agent99.core").write_buf(e.bufnr)
            end)
            saved = okw and res ~= false
            if not saved then save_why = "the file changed on disk since; nothing was written" end
        end
        if not saved then
            -- Put the buffer back the way it was and keep the entry.
            if not e.file_op then
                vim.api.nvim_buf_set_lines(e.bufnr, e.first - 1,
                    e.first - 1 + #(e.old_lines or {}), false, e.new_lines or {})
            end
            refused[#refused + 1] = { file = e.file, name_path = e.name_path, why = save_why }
            break
        end
        undone[#undone + 1] = e
        current[#current] = nil
        -- Restoring rarely puts back as many lines as the edit wrote, so
        -- everything below it moves. Entries in every ledger follow, this
        -- client's and the other clients' both: their regions are checked
        -- against the buffer before an undo, and one left pointing at the old
        -- row is refused as "changed since" over an edit its owner never
        -- made. Under one shared LIFO stack this could not happen - the
        -- newest edit was always the one undone - and with a ledger per
        -- client it can, whenever the edit undone sits above another's.
        if not e.file_op then
            local delta = #(e.old_lines or {}) - e.new_count
            M.shift(e.bufnr, e.first + e.new_count - 1, delta)
        end
        ::continue::
    end
    return undone, refused, dropped
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
    -- Every client's entries, not only this one's: the buffer is shared, so
    -- text moving down moves what another client's entry points at too, and
    -- leaving those behind would make its undo refuse them as "changed since"
    -- over an edit it never made.
    for _, entries in pairs(ledgers) do
        for _, e in ipairs(entries) do
            if not e.file_op and e.bufnr == bufnr and e.first > after then
                e.first = e.first + delta
                if e.last then e.last = e.last + delta end
            end
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
