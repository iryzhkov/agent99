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

-- The QML JavaScript guard. A .js file that opens with QML's own directives
-- is not JavaScript any TypeScript server can parse, so the server that
-- attached to it is detached and what it published is discarded; this is the
-- detection that decides it. No server is needed to check the decision, and
-- none of the ones the smoke test can start would attach to a .js file
-- anyway.
local core = require("agent99.core")

local function named_buffer(name, lines)
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(bufnr, name)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    return bufnr
end

check("a .pragma header marks a file as QML JavaScript",
    core.dialect_note(named_buffer("/tmp/agent99-unit/Sanitize.js",
        { "// helpers", "", ".pragma library", "function f() {}" })) ~= nil)

check("an .import header counts too",
    core.dialect_note(named_buffer("/tmp/agent99-unit/Helper.js",
        { '.import "Sanitize.js" as Sanitize', "function g() {}" })) ~= nil)

-- The directives come before any code. A dot at the start of a line further
-- down is a method call split across lines, not a QML header.
check("plain JavaScript is left alone",
    core.dialect_note(named_buffer("/tmp/agent99-unit/plain.js",
        { "const x = 1;", ".pragma library" })) == nil)

check("a .qml file is not a JavaScript library",
    core.dialect_note(named_buffer("/tmp/agent99-unit/Panel.qml",
        { ".pragma library" })) == nil)

-- reindented_kept_line: the guard that keeps an import pass from rewriting a
-- file's indentation. It has to fire on the pass that re-indents the lines it
-- kept, and stay quiet on the pass that only adds or removes imports - a file
-- where one text sits at two depths (`}` in every Go, TypeScript and C file
-- there is) must not read as re-indented.
local go_before = {
    "package main",
    "",
    "import (",
    "\t\"fmt\"",
    ")",
    "",
    "func a() {",
    "\tif true {",
    "\t\tfmt.Println(\"x\")",
    "\t}",
    "}",
}
local go_after = vim.deepcopy(go_before)
table.insert(go_after, 5, "\t\"os\"")
check("an import added leaves the kept lines alone",
    edit.reindented_kept_line(go_before, go_after) == nil,
    edit.reindented_kept_line(go_before, go_after))

local ts_before = {
    "import { a } from \"./a\";",
    "import {",
    "  b,",
    "} from \"./b\";",
    "",
    "export function f() {",
    "  return a;",
    "}",
}
local ts_after = vim.deepcopy(ts_before)
ts_after[3] = "    b,"
check("a re-indented import block is caught",
    edit.reindented_kept_line(ts_before, ts_after) == "b,",
    edit.reindented_kept_line(ts_before, ts_after))

-- The guard reads lines rather than syntax, so the fixture is lines: a text
-- the pass removed one of cannot be paired occurrence by occurrence, and
-- pairing it anyway would call an untouched line below it re-indented.
local dropped_before = { "keep", "\tdrop", "}", "\t}", "\t\tdrop" }
local dropped_after = { "keep", "}", "\t}", "\t\tdrop" }
check("a text the pass removed a line of is left unpaired",
    edit.reindented_kept_line(dropped_before, dropped_after) == nil,
    edit.reindented_kept_line(dropped_before, dropped_after))

-- move_symbols loads the files that referenced a moved symbol so the server
-- checks them, and only a diagnostic naming one of those symbols is the move's
-- doing. The two ways to get this wrong both shipped: charging the whole file
-- to the move put three pre-existing warnings from an untouched Go test file
-- into one move's verdict, and the fix for that dropped everything else in
-- those files on the floor - an unresolved-import error in a file the move had
-- genuinely broken vanished from the reply while the same error in an
-- unrelated open file was reported.
check("a message naming the moved symbol is the move's doing",
    edit.mentions_name('"has_triple_quotes" is unknown import symbol',
        { "has_triple_quotes" }) == true, "not matched")
check("a longer word merely containing the name is not",
    edit.mentions_name("address is not defined", { "add" }) == false, "matched")
check("a name that is only a suffix of a word is not",
    edit.mentions_name("reshout is undefined", { "shout" }) == false, "matched")
check("an unrelated error in the same file is not the move's doing",
    edit.mentions_name('Import "black.strings" could not be resolved',
        { "has_triple_quotes" }) == false, "matched")
-- The symbol index spells a Go method `(*Archiver).Do`, which begins with
-- punctuation: a leading word-frontier there can never match, so it must not
-- be applied on that side.
check("a name carrying pattern magic still matches",
    edit.mentions_name("undefined: (*Archiver).Do", { "(*Archiver).Do" }) == true, "not matched")
check("a name in backticks matches",
    edit.mentions_name("undefined global `shout`", { "shout" }) == true, "not matched")
check("no names means nothing is the move's doing",
    edit.mentions_name("anything at all", {}) == false, "matched")
check("a nil message is not a match",
    edit.mentions_name(nil, { "shout" }) == false, "matched")

-- The honest hedge, and what it is gated on. A server's silence about a file
-- is only evidence once that server has published something about THAT file:
-- gating it per server instead made one diagnostic in one file answer for
-- every other file in the project, which is how a file nothing had analysed
-- came back flatly clean. Driven through the same DiagnosticChanged path a
-- real publish takes, with a namespace named the way vim.lsp names its own.
local function hedge_buffer(path, filetype)
    local b = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(b, path)
    vim.bo[b].filetype = filetype
    return b
end

local function publish(bufnr, server, message)
    local ns = vim.api.nvim_create_namespace("nvim.lsp." .. server .. ".1")
    vim.api.nvim_exec_autocmds("DiagnosticChanged", {
        buffer = bufnr,
        data = {
            diagnostics = {
                {
                    bufnr = bufnr, lnum = 0, col = 0, namespace = ns,
                    severity = vim.diagnostic.severity.ERROR, message = message,
                },
            },
        },
    })
end

local analysed = hedge_buffer("/tmp/agent99-unit-hedge/analysed.zig", "zig")
local untouched = hedge_buffer("/tmp/agent99-unit-hedge/untouched.zig", "zig")

local who, how = edit.silent_server(untouched, { "fakels" }, 0)
check("a server that has published nothing hedges, and says so of the session",
    who == "fakels" and how == "at all in this session", { who, how })

publish(analysed, "fakels", "something is wrong here")

who, how = edit.silent_server(analysed, { "fakels" }, 0)
check("the file the server did publish for is not hedged", who == nil, { who, how })

who, how = edit.silent_server(untouched, { "fakels" }, 0)
check("a diagnostic in one file does not certify another file",
    who == "fakels", { who, how })
check("and the hedge narrows to what is actually unknown about this file",
    how == "for this file in this session", { who, how })

-- Two servers on one file: the hedge is gone only when one of them has
-- spoken about this file. The other having spoken about some other file is
-- exactly the evidence that is not evidence.
local both = hedge_buffer("/tmp/agent99-unit-hedge/both.zig", "zig")
who = edit.silent_server(both, { "fakels", "otherls" }, 0)
check("both servers silent about this file still hedges, naming both",
    who == "fakels and otherls", who)
publish(both, "otherls", "and here")
check("one of them publishing for this file ends the hedge",
    edit.silent_server(both, { "fakels", "otherls" }, 0) == nil, who)

-- Liveness. A server that published and is no longer running leaves its
-- diagnostics in the editor with nothing refreshing them, so "0 elsewhere" is
-- no longer an answer about the project. No LSP client is running under the
-- unit tests, so every server that has published here counts as stopped.
local gone = edit.stopped_servers()
check("a server that published and is not running is reported as stopped",
    vim.tbl_contains(gone, "fakels") and vim.tbl_contains(gone, "otherls"), gone)

-- byte_report: what verify= answers about the bytes, which its echo of the
-- changed lines structurally cannot. Two files whose bytes differ produce
-- the identical array of lines, so these questions have to be answered
-- somewhere else, and this is where.
local lf = edit.byte_report("a\nb\n")
check("LF endings are named, and the final newline is reported",
    lf.line_endings == "LF" and lf.final_newline == true and lf.bytes == 4, lf)

local crlf = edit.byte_report("a\r\nb\r\n")
check("a CRLF file is not reported as an LF one",
    crlf.line_endings == "CRLF" and crlf.bytes == 6, crlf)

local nonl = edit.byte_report("a\nb")
check("a missing final newline is reported as missing",
    nonl.final_newline == false and nonl.line_endings == "LF", nonl)

local oneline = edit.byte_report("a")
check("one line with no terminator says so rather than naming an ending",
    oneline.line_endings == "none: the file is one line with no terminator", oneline)

local mixed = edit.byte_report("a\r\nb\nc\n")
check("mixed endings are counted, not picked between",
    mixed.line_endings == "mixed: 2 LF, 1 CRLF", mixed)

local bom = edit.byte_report("\239\187\191a\n")
check("a BOM is named", bom.bom == "UTF-8" and bom.bytes == 5, bom)
check("and a file without one says so", edit.byte_report("a\n").bom == "none", lf)

local empty = edit.byte_report("")
check("a 0-byte file has no final newline and no endings",
    empty.bytes == 0 and empty.final_newline == false, empty)
check("and its digest is the digest of nothing",
    empty.sha256 == vim.fn.sha256(""), empty)

-- The account an undo gives of itself when it fails after the files are
-- back. Nothing else exercises this wording: the one thing known to throw
-- there was an invalid buffer id, which is now guarded, and a reply nothing
-- exercises is a reply whose first defect ships.
local undodir = "/tmp/agent99-unit-undo"
vim.fn.delete(undodir, "rf")
vim.fn.mkdir(undodir, "p")
local undofile = undodir .. "/note.txt"
vim.fn.writefile({ "one", "two" }, undofile)
edit.insert_lines({ file = undofile, at = "end", text = "three", headless = true })
vim.env.AGENT99_FAULT_UNDO_TAIL = "the editor went away"
local hurt = edit.undo_edit({ headless = true })
vim.env.AGENT99_FAULT_UNDO_TAIL = nil
check("an undo that fails after the restore still lists what it undid",
    #hurt.undone == 1 and hurt.remaining == 0, hurt)
check("and says what it did not manage, rather than throwing",
    type(hurt.incomplete) == "string"
    and hurt.incomplete:find("restored and written", 1, true) ~= nil
    and hurt.incomplete:find("the editor went away", 1, true) ~= nil, hurt)
check("and the restore itself really happened",
    table.concat(vim.fn.readfile(undofile), "\n") == "one\ntwo",
    vim.fn.readfile(undofile))
vim.fn.delete(undodir, "rf")

if failures > 0 then
    io.stdout:write(("unit_edit: %d failed\n"):format(failures))
    vim.cmd("cquit 1")
end
io.stdout:write("unit_edit: OK\n")
io.stdout:flush()
vim.cmd("quit")
