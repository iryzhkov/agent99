-- One truncation contract, shared by every tool that caps its reply.
--
-- Three numbers, and all three are computed after every filter has run:
-- `shown` is what the reply carries, `total` is what existed, and `dropped`
-- is the difference. A count taken from an already-truncated set is not one
-- of them. The counting pass has to reach past the point where the emitting
-- pass stopped, or the number it produces describes the cut rather than the
-- loss.
--
-- The rule this module exists to enforce: whenever `dropped > 0` the reply
-- says so, and says how many. A count that computes itself out of existence
-- suppresses the warning exactly where the loss is worst. skim answered a
-- 3000-deep JSON chain with 150 entries and no note at all, because its
-- count was of the not-yet-emitted siblings at the cut point and a chain has
-- none; the same count told a 5262-line document that 55 headings were
-- missing when 1161 were.
--
-- Two shapes, because replies have two shapes:
--
--   * `note()` for a truncation that lives inside a list of strings, where
--     the last entry has to carry the whole story.
--   * `fields()` for an object reply, which can hold `shown`, `total` and
--     `dropped` as numbers a caller can compute with.
--
-- A total that a bounded counting pass could not finish is a floor, and is
-- reported as one rather than as a number that looks exact.

local M = {}

-- Fields for an object-shaped reply. Returns nil when nothing was dropped,
-- so a caller can `vim.tbl_extend` the result in unconditionally.
--
-- opts.unit    what is being counted, for the note ("frames", "entries")
-- opts.reach   how to get the rest ("raise max=", "depth= shows them")
-- opts.floor   true when `total` is a lower bound, not the exact count
function M.fields(shown, total, opts)
    opts = opts or {}
    if total <= shown then
        return nil
    end
    local out = {
        shown = shown,
        total = total,
        dropped = total - shown,
    }
    if opts.floor then
        out.total_is_floor = true
    end
    local unit = opts.unit or "entries"
    local how = opts.floor
        and ("%d of at least %d %s are shown; the count stopped before it reached the end")
            :format(shown, total, unit)
        or ("%d of %d %s are not shown"):format(total - shown, total, unit)
    if opts.reach then
        how = how .. "; " .. opts.reach
    end
    out.note = how
    return out
end

-- A one-line note for a truncation inside a list of strings.
--
-- unit   what is being counted ("declarations", "files", "matches")
-- reach  how to get the rest; appended after a semicolon when given
-- where  an optional clause naming the cut point (" after line 607")
function M.note(shown, total, unit, reach, where)
    local line = ("… +%d more %s (%d of %d shown)%s"):format(
        total - shown, unit, shown, total, where or "")
    if reach and reach ~= "" then
        line = line .. "; " .. reach
    end
    return line
end

-- Slice a list to `limit` and append the note when anything was dropped.
-- `total` defaults to #items, which is right whenever the list itself is the
-- complete set; pass it explicitly when the emitting pass already stopped
-- short and something else counted the rest.
function M.list(items, limit, unit, reach, total, where)
    total = total or #items
    if total <= limit and #items <= limit then
        return items
    end
    local out = vim.list_slice(items, 1, limit)
    out[#out + 1] = M.note(math.min(#items, limit), total, unit, reach, where)
    return out
end

return M
