-- Does the file still parse?
--
-- Every symbol tool locates its target with a treesitter parser and then
-- edits by line. Where the two disagree the file is left invalid and nothing
-- says so: a JSON pair's separating comma sits outside the node the edit
-- replaced, so `replace_symbol_body` ate it, answered "applied and saved to
-- disk", and `skim` afterwards printed an outline of the part that still
-- parsed - shaped exactly like the outline of a healthy file. No language
-- server is attached to a JSON file, so `diagnostics_after` said nothing was
-- checked, which was true of the server and useless to the reader.
--
-- The parser is already in hand. This module asks it the one question the
-- replies were missing: is there an ERROR or a MISSING node in the tree, and
-- was it there before the edit.

local M = {}

-- The first place the grammar gave up: { line = <1-based>, text = <that
-- line, trimmed> }, or nil when the tree is clean. The walk is iterative
-- because a generated data file nests deep enough to overflow the Lua stack
-- on a recursive one.
local function first_error_in(root, get_line)
    if not root or not root:has_error() then
        return nil
    end
    local stack, best = { root }, nil
    while #stack > 0 do
        local node = table.remove(stack)
        if node:has_error() or node:missing() then
            if node:type() == "ERROR" or node:missing() then
                local srow, _, erow, ecol = node:range()
                if ecol == 0 and erow > srow then erow = erow - 1 end
                if best == nil or srow < best.first then
                    best = { first = srow, last = erow }
                end
            end
            -- Only a subtree that carries the error is worth descending
            -- into; has_error() is false for every clean sibling.
            for child in node:iter_children() do
                if child:named() or child:missing() then
                    stack[#stack + 1] = child
                end
            end
        end
    end
    if best == nil then
        -- has_error() was true but no ERROR node was reachable by name (an
        -- anonymous MISSING token inside an unnamed node). Say so without a
        -- line rather than claiming the file is clean.
        return { line = nil, text = nil }
    end
    return {
        line = best.first + 1,
        last_line = best.last + 1,
        text = vim.trim(get_line(best.first) or ""),
    }
end

-- The parse error in a buffer as it stands now.
function M.first_error(bufnr)
    local ok, parser = pcall(vim.treesitter.get_parser, bufnr)
    if not ok or parser == nil then
        return nil
    end
    local okp, trees = pcall(function() return parser:parse() end)
    if not okp or not trees or not trees[1] then
        return nil
    end
    return first_error_in(trees[1]:root(), function(row)
        return vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]
    end)
end

-- The parse error in a piece of text that is not in a buffer - the pre-edit
-- content, reconstructed from the ledger, so that a file which was already
-- invalid is not blamed on the edit that touched it.
function M.error_in_lines(lines, ft)
    local okl, lang = pcall(vim.treesitter.language.get_lang, ft or "")
    if not okl or not lang then
        return nil
    end
    local text = table.concat(lines, "\n")
    local ok, parser = pcall(vim.treesitter.get_string_parser, text, lang)
    if not ok or parser == nil then
        return nil
    end
    local okp, trees = pcall(function() return parser:parse() end)
    if not okp or not trees or not trees[1] then
        return nil
    end
    return first_error_in(trees[1]:root(), function(row)
        return lines[row + 1]
    end)
end

-- Did this edit break the file? Returns the parse error when the buffer does
-- not parse now and the text before the edit did, and nil otherwise: a file
-- that arrived broken stays the caller's business, and reporting it on every
-- later edit would teach the reader to skip the field.
function M.introduced(bufnr, before_lines)
    local after = M.first_error(bufnr)
    if not after then
        return nil
    end
    if before_lines and M.error_in_lines(before_lines, vim.bo[bufnr].filetype) then
        return nil
    end
    return after
end

-- The sentence an edit reply carries when the edit left the file
-- unparseable. Written as a statement about the file rather than about the
-- language server, because for JSON, YAML, TOML and Markdown there is no
-- server and "nothing checked" was the whole of what the reply said.
function M.clause(bufnr, parse_error)
    return ("the %s grammar no longer parses this file: %s, and it did before this edit. "
        .. "The edit is on disk; undo_edit takes it back")
        :format(vim.bo[bufnr].filetype ~= "" and vim.bo[bufnr].filetype or "file's",
            M.where(parse_error))
end

-- Where the grammar gave up, as a phrase. The span, not just its first line:
-- an ERROR node opens at the last construct the parser was sure of, so a
-- missing separator is reported from the member before it, and a reader sent
-- to that line alone finds nothing wrong there.
function M.where(parse_error)
    if not parse_error.line then
        return "the grammar could not report where"
    end
    local text = parse_error.text or ""
    if #text > 60 then text = text:sub(1, 60) .. "…" end
    if parse_error.last_line and parse_error.last_line > parse_error.line then
        return ("it cannot read lines %d-%d, from %q on")
            :format(parse_error.line, parse_error.last_line, text)
    end
    return ("it cannot read line %d, %q"):format(parse_error.line, text)
end

return M
