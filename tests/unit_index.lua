-- Unit checks for the index helpers that need no language server, driven by
-- scratch buffers. The one here is the widening that repairs a symbol a
-- server reported by the range of its name alone: pyright does that for a
-- module constant, and the smoke suite has no pyright to show it with.
--
-- Run with: nvim --clean --headless -u tests/minimal_init.lua -l tests/unit_index.lua

local index = require("agent99.index")

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
    pcall(vim.treesitter.start, bufnr, filetype)
    return bufnr
end

local lua_buf = buffer_with({
    "local RESPONSES = {",
    '    login_ok = "logged in",',
    '    login_bad = "try again",',
    "}",
    "",
    "local TIMEOUT = 30",
    "",
    "local function greet(name)",
    '    return "hello, " .. name',
    "end",
}, "lua")

check("a table constant reaches its closing brace",
    index.statement_end(lua_buf, 1) == 4, index.statement_end(lua_buf, 1))
check("a one-line assignment stays one line",
    index.statement_end(lua_buf, 6) == 6, index.statement_end(lua_buf, 6))
check("a function reaches its end",
    index.statement_end(lua_buf, 8) == 10, index.statement_end(lua_buf, 8))
check("a blank line is its own line",
    index.statement_end(lua_buf, 5) == 5, index.statement_end(lua_buf, 5))
check("a line past the end of the buffer answers itself",
    index.statement_end(lua_buf, 99) == 99, index.statement_end(lua_buf, 99))

-- The same shape in Python, the grammar the fault was found in: pyright
-- reports RESPONSES as one line, and the value runs to the closing brace.
if pcall(vim.treesitter.language.inspect, "python") then
    local py_buf = buffer_with({
        "RESPONSES = {",
        '    "login_ok": "logged in",',
        '    "gone": "not here",',
        "}",
        "",
        "TIMEOUT = 30",
    }, "python")
    check("a python dict constant reaches its closing brace",
        index.statement_end(py_buf, 1) == 4, index.statement_end(py_buf, 1))
    check("a python scalar stays one line",
        index.statement_end(py_buf, 6) == 6, index.statement_end(py_buf, 6))
else
    io.stdout:write("skip  no python treesitter parser\n")
end

-- A file with no parser at all must not error; the entry keeps the line the
-- server gave it.
local plain = buffer_with({ "KEY = value", "OTHER = value" }, "conf")
check("a file with no parser answers the line it was given",
    index.statement_end(plain, 1) == 1, index.statement_end(plain, 1))

-- The truncation contract: shown, total and dropped, over fixtures whose
-- true totals are known by construction. These arrive as successful replies,
-- so a check that only asserts a note exists passes against a note whose
-- number is wrong; every assertion here is on the exact number.
local cap = require("agent99.cap")

check("cap.note carries all three numbers",
    cap.note(150, 620, "declarations", "find_symbol reaches them")
    == "… +470 more declarations (150 of 620 shown); find_symbol reaches them",
    cap.note(150, 620, "declarations", "find_symbol reaches them"))
check("cap.fields is nil when nothing was dropped",
    cap.fields(10, 10, { unit = "frames" }) == nil, cap.fields(10, 10, {}))
local three = cap.fields(3, 46, { unit = "entries", reach = "raise max" })
check("cap.fields counts the drop",
    three.shown == 3 and three.total == 46 and three.dropped == 43
    and three.note == "43 of 46 entries are not shown; raise max", three)
local floored = cap.fields(3, 46, { unit = "entries", floor = true })
check("a floor says the count stopped early",
    floored.total_is_floor == true and floored.note:find("at least 46", 1, true) ~= nil, floored)

-- The same contract for one over-long string. A clipped line that simply
-- stops reads as a short line, which is how a 50,000-character minified line
-- and an 11-character match on it came back as the same reply.
check("cap.clip leaves a short string alone",
    cap.clip("abcdef", 10) == "abcdef", cap.clip("abcdef", 10))
local long = string.rep("x", 500)
check("cap.clip says how much it dropped",
    cap.clip(long, 100) == string.rep("x", 100) .. "… (+400 characters on this line)",
    cap.clip(long, 100))
check("cap.clip takes the noun it was given",
    cap.clip(long, 100, "characters of name path")
        :find("(+400 characters of name path)", 1, true) ~= nil,
    cap.clip(long, 100, "characters of name path"))
-- Cutting through a UTF-8 sequence makes the whole reply invalid JSON, which
-- costs far more than the tail of one line.
local runes = string.rep("é", 200)  -- two bytes each
local cut = cap.clip(runes, 101)
check("cap.clip never cuts through a rune",
    vim.fn.strchars(cut:gsub("… %(.*%)$", "")) == 50 and #cut:gsub("… %(.*%)$", "") == 100,
    cut)

if vim.treesitter.language.add and pcall(vim.treesitter.language.inspect, "json") then
    -- One nesting chain, 400 keys deep and no siblings anywhere. This is the
    -- case where the old count computed to 0 and took the note with it: 150
    -- entries were emitted and 250 were dropped in silence.
    local chain, DEPTH = {}, 400
    for i = 1, DEPTH do
        chain[#chain + 1] = string.rep(" ", i - 1) .. ('{ "d%d": '):format(i)
    end
    local text = table.concat(chain, "\n") .. "\n" .. string.rep(" ", DEPTH) .. "0"
    for i = DEPTH, 1, -1 do
        text = text .. "\n" .. string.rep(" ", i - 1) .. "}"
    end
    local chain_buf = buffer_with(vim.split(text, "\n"), "json")
    local chain_out = index.ts_outline(chain_buf)
    -- Indentation is what an outline is read by, and past a dozen levels it
    -- stops being that and becomes the reply: entry 150 of this chain used to
    -- carry 298 leading spaces, and one 3000-deep file spent about 8000
    -- tokens printing whitespace. The depth is still there, as a number.
    check("a deep entry writes its depth instead of indenting to it",
        chain_out[150]:sub(1, 24) == string.rep(" ", 24)
        and chain_out[150]:sub(25):match("^%[%+137%] 150%-") ~= nil
        and #chain_out[150] < 60,
        chain_out[150]:sub(1, 60))
    check("a shallow entry still indents",
        chain_out[3]:match("^    %d") ~= nil and chain_out[3]:find('"d3"', 1, true) ~= nil,
        chain_out[3])
    check("a nesting chain still gets its note",
        #chain_out == 151
        and chain_out[151] == "… +250 more declarations (150 of 400 shown) after line 150; "
            .. "find_symbol or read_file with offset reach them",
        chain_out[#chain_out])

    -- Three levels, 20 x 5 x 5 = 620 declarations. The old walk stopped
    -- descending past the cap, so it never saw the grandchildren of the
    -- subtrees it had skipped and answered "+90 more" for 470.
    local t = { "{" }
    for a = 1, 20 do
        t[#t + 1] = ('  "a%d": {'):format(a)
        for b = 1, 5 do
            t[#t + 1] = ('    "b%d": {'):format(b)
            for c = 1, 5 do
                t[#t + 1] = ('      "c%d": %d%s'):format(c, c, c < 5 and "," or "")
            end
            t[#t + 1] = "    }" .. (b < 5 and "," or "")
        end
        t[#t + 1] = "  }" .. (a < 20 and "," or "")
    end
    t[#t + 1] = "}"
    local tree_out = index.ts_outline(buffer_with(t, "json"))
    check("the count reaches below the cut point",
        #tree_out == 151
        and tree_out[151]:find("+470 more declarations (150 of 620 shown)", 1, true) ~= nil,
        tree_out[#tree_out])
else
    io.stdout:write("skip  no json treesitter parser\n")
end

-- references truncates by location, and the unit that matters for the task
-- it is advertised for is the file: five whole files used to vanish from a
-- reply that only ever counted locations.
local function loc(path, line)
    return {
        uri = vim.uri_from_fname(path),
        range = { start = { line = line, character = 0 }, ["end"] = { line = line, character = 4 } },
    }
end
local locations = {}
for i = 0, 99 do locations[#locations + 1] = loc("/tmp/agent99-cap-a.lua", i) end
for i = 0, 49 do locations[#locations + 1] = loc("/tmp/agent99-cap-b.lua", i) end
locations[#locations + 1] = loc("/tmp/agent99-cap-c.lua", 0)
local refs = require("agent99.lsp")._internal.format_locations(locations)
check("references counts locations after the cut",
    refs.count == 151 and refs.shown == 100 and refs.total == 151 and refs.dropped == 51, refs)
check("references counts the files too",
    refs.files and refs.files.shown == 1 and refs.files.total == 3 and refs.files.dropped == 2,
    refs.files)
check("references names the files no location above comes from",
    vim.deep_equal(refs.files_omitted, { "/tmp/agent99-cap-b.lua", "/tmp/agent99-cap-c.lua" }),
    refs.files_omitted)

if failures > 0 then
    io.stdout:write(("unit_index: %d failed\n"):format(failures))
    vim.cmd("cquit 1")
end
io.stdout:write("unit_index: OK\n")
io.stdout:flush()
vim.cmd("quit")
