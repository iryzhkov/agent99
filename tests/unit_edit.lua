-- Unit checks for the two guards that decide whether a formatter's pass is
-- kept after an edit. They run without a language server: the formatters
-- that fail these checks (a server that rewrites string contents, a server
-- that ignores the indent options it was handed) are not ones the smoke
-- test can start, so the check is driven by rewriting the buffer directly,
-- exactly as a bad format pass would.
--
-- Run with: nvim --clean --headless -u tests/minimal_init.lua -l tests/unit_edit.lua

local edit = require("agent99.edit")

local failures = 0

local function check(name, ok, detail)
    if ok then
        io.stdout:write("ok   " .. name .. "\n")
    else
        failures = failures + 1
        io.stdout:write("FAIL " .. name .. (detail and ("\n     " .. vim.inspect(detail)) or "") .. "\n")
    end
    io.stdout:flush()
end

local function buffer_with(lines, filetype)
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.bo[bufnr].filetype = filetype
    return bufnr
end

-- indent_profile: the step is measured between the widths that occur, so a
-- region that starts deep inside a nested block still reports the unit.
local flat = edit.indent_profile({ "a", "  b", "    c" })
check("indent_profile finds a two-space unit", flat.step == 2 and flat.levels == 2, flat)

local nested = edit.indent_profile({ "      a", "        b", "      c" })
check("indent_profile ignores the depth a region starts at",
    nested.step == 2 and nested.levels == 2, nested)

local tabbed = edit.indent_profile({ "a", "\tb", "\t\tc" })
check("indent_profile counts tabs", tabbed.tabs == 2 and tabbed.spaces == 0, tabbed)

-- format_damage: respacing code is what a formatter is for.
local before = {
    "local M = {}",
    "",
    "function M.add(x)",
    "  return x   +  1",
    "end",
    "",
    "return M",
}
local bufnr = buffer_with(before, "lua")
vim.api.nvim_buf_set_lines(bufnr, 3, 4, false, { "  return x + 1" })
check("format_damage allows respacing code",
    edit.format_damage(bufnr, before, 3, 5) == nil,
    vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))

-- A string literal is content. The leading spaces inside one belong to
-- whoever wrote it (an embedded shell script, a here-doc, a test fixture).
local with_string = {
    "local M = {}",
    "",
    "M.script = [[",
    "  restore=$(cat state)",
    "  echo $restore",
    "]]",
    "",
    "return M",
}
bufnr = buffer_with(with_string, "lua")
vim.api.nvim_buf_set_lines(bufnr, 3, 5, false, { " restore=$(cat state)", " echo $restore" })
local harm = edit.format_damage(bufnr, with_string, 3, 6)
check("format_damage catches a rewritten string literal",
    type(harm) == "string" and harm:find("string literal"), harm)

-- Re-indenting the region to the server's own default rewrites every line
-- of the symbol in a file that uses a different width.
local two_space = {
    "local M = {}",
    "",
    "function M.add(x)",
    "  if x then",
    "    return x + 1",
    "  end",
    "end",
    "",
    "return M",
}
bufnr = buffer_with(two_space, "lua")
vim.api.nvim_buf_set_lines(bufnr, 3, 6, false, {
    "    if x then",
    "        return x + 1",
    "    end",
})
harm = edit.format_damage(bufnr, two_space, 3, 7)
check("format_damage catches a re-indent to another width",
    type(harm) == "string" and harm:find("re%-indented"), harm)

-- The same region formatted at the file's own width is fine.
bufnr = buffer_with(two_space, "lua")
vim.api.nvim_buf_set_lines(bufnr, 4, 5, false, { "    return x+1" })
check("format_damage leaves a same-width format alone",
    edit.format_damage(bufnr, two_space, 3, 7) == nil,
    vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))

-- map_region: where an edited region ends up once polishing has moved it,
-- and which old lines below it the ledger has to fold in so an undo puts
-- the whole change back.
local function lines_of(n, mark)
    local out = {}
    for i = 1, n do out[i] = (mark or "line ") .. i end
    return out
end

local base = lines_of(10)

local shifted = vim.list_slice(base, 1, 10)
table.insert(shifted, 2, "new")
local first_line, last_line, extra = edit.map_region(base, shifted, 5, 6)
check("map_region shifts a region by what was added above it",
    first_line == 6 and last_line == 7 and #extra == 0,
    { first_line, last_line, extra })

local grown = vim.list_slice(base, 1, 10)
table.insert(grown, 6, "new")
first_line, last_line, extra = edit.map_region(base, grown, 5, 6)
check("map_region grows a region by what was added inside it",
    first_line == 5 and last_line == 7 and #extra == 0,
    { first_line, last_line, extra })

local below = vim.list_slice(base, 1, 10)
below[8] = "reformatted"
first_line, last_line, extra = edit.map_region(base, below, 5, 6)
check("map_region reaches down to what polishing changed below",
    first_line == 5 and last_line == 8 and #extra == 2
    and extra[1] == "line 7" and extra[2] == "line 8",
    { first_line, last_line, extra })

-- The case that made undo destructive: a range format answered with edits
-- for the whole document. Every line differs, so the region cannot be
-- anchored to a mark - but it must still start where the edit was, or the
-- ledger records the file as the edit and undo replaces it wholesale.
local rewritten = lines_of(10, "  line ")
first_line, last_line, extra = edit.map_region(base, rewritten, 5, 6)
check("map_region keeps its start when the whole file was rewritten",
    first_line == 5 and last_line == 10 and #extra == 4,
    { first_line, last_line, extra })

first_line, last_line, extra = edit.map_region(base, base, 5, 6)
check("map_region leaves an untouched buffer alone",
    first_line == 5 and last_line == 6 and #extra == 0,
    { first_line, last_line, extra })

if failures > 0 then
    io.stdout:write(("unit_edit: %d failed\n"):format(failures))
    vim.cmd("cquit 1")
end
io.stdout:write("unit_edit: OK\n")
io.stdout:flush()
vim.cmd("quit")
