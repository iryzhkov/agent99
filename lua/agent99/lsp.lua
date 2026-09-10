-- LSP query helpers for agent99.
--
-- Every function here runs inside the user's Neovim instance, invoked over
-- RPC by the MCP bridge (see bridge/agent99_mcp.py). The point of this module
-- is to reuse the LSP clients that are already running and warm instead of
-- making the agent spawn its own language servers.
--
-- Addressing convention for the agent: a position is (file, line, symbol).
-- `line` is 1-based; `symbol` is a piece of text on that line whose first
-- occurrence marks the column. This is far more robust for an LLM than
-- asking it to produce a correct UTF-16 column. An explicit 1-based byte
-- `col` is accepted as an alternative.
--
-- Concurrency model: every tool runs inside a coroutine started by
-- agent99.rpc. Anything that must wait (LSP replies, attach polling) yields
-- via `await` and is resumed from a callback, so the user's UI never blocks
-- while a tool call is in flight; the bridge polls for the result with cheap
-- --remote-expr calls.

local M = {}

local core = require("agent99.core")
local err, sleep = core.err, core.sleep
local load_buf, rel_path, fresh_buf = core.load_buf, core.rel_path, core.fresh_buf
local get_client, request, resync_open_buffers = core.get_client, core.request, core.resync_open_buffers
local position_params, line_preview = core.position_params, core.line_preview
local MAX_LOCATIONS, FRESH_RETRY_MS = core.MAX_LOCATIONS, core.FRESH_RETRY_MS

local index = require("agent99.index")
local symbol_kind, ts_outline, symbol_index = index.symbol_kind, index.ts_outline, index.symbol_index
local annotate_locations = index.annotate_locations
local skim, workspace_map, document_symbols = index.skim, index.workspace_map, index.document_symbols
local workspace_tree = index.workspace_tree
local run_tests = require("agent99.testrun").run_tests
local workspace_symbols, ts_query, find_symbol = index.workspace_symbols, index.ts_query, index.find_symbol
local enclosing_symbols = index.enclosing_symbols

local edit = require("agent99.edit")
local code_actions, apply_code_action = edit.code_actions, edit.apply_code_action
local replace_symbol_body, replace_symbol_lines = edit.replace_symbol_body, edit.replace_symbol_lines
local insert_symbol_tool, undo_edit, rename_symbol = edit.insert_symbol_tool, edit.undo_edit, edit.rename_symbol
local insert_lines = edit.insert_lines
local create_file, move_file, delete_file, move_symbols = edit.create_file, edit.move_file, edit.delete_file,
    edit.move_symbols
local replace_pattern = edit.replace_pattern

local install = require("agent99.install")
local check_project, workspace_support, install_language = install.check_project, install.workspace_support,
    install.install_language
-- The headless bridge saves every modified buffer through this.
M.save_all = core.save_all
-- Normalize Location | Location[] | LocationLink[] into a compact list.
local function format_locations(result)
    if result == nil then
        return { locations = {}, note = "no results" }
    end
    if result.uri or result.targetUri then
        result = { result }
    end
    local out, total = {}, #result
    for i, loc in ipairs(result) do
        if i > MAX_LOCATIONS then break end
        local uri = loc.uri or loc.targetUri
        local range = loc.targetSelectionRange or loc.range
        local path = vim.uri_to_fname(uri)
        local lnum = range.start.line + 1
        local item = { file = path, line = lnum, text = line_preview(path, lnum) }
        if range["end"].line ~= range.start.line then
            item.end_line = range["end"].line + 1
        end
        out[#out + 1] = item
    end
    local res = { count = total, locations = out }
    if total > MAX_LOCATIONS then
        res.note = ("truncated to first %d of %d locations"):format(MAX_LOCATIONS, total)
    end
    return res
end

local function location_tool(method, extra_params)
    return function(args)
        local bufnr = load_buf(args.file)
        local client = get_client(bufnr, method)
        local params = position_params(bufnr, client, args)
        if extra_params then
            params = vim.tbl_deep_extend("force", params, extra_params)
        end
        return format_locations(request(client, bufnr, method, params))
    end
end





















-- Some servers answer hover with a progress placeholder while they are
-- still indexing (lua_ls: "Workspace loading: 3 / 120"). That is not an
-- answer; wait a little and ask again.
local HOVER_RETRY_MS = 500
local HOVER_RETRY_DEADLINE_MS = 8000

local function placeholder_hover(text)
    return text:find("^%s*Workspace loading") ~= nil
        or text:find("^%s*Loading workspace") ~= nil
end

local function hover(args)
    local bufnr = load_buf(args.file)
    local client = get_client(bufnr, "textDocument/hover")
    local params = position_params(bufnr, client, args)
    local deadline = vim.uv.now() + HOVER_RETRY_DEADLINE_MS
    local text
    while true do
        local result = request(client, bufnr, "textDocument/hover", params)
        if not (result and result.contents) then
            return { hover = nil, note = "no hover information at this position" }
        end
        local lines = vim.lsp.util.convert_input_to_markdown_lines(result.contents)
        text = table.concat(lines, "\n")
        if not placeholder_hover(text) or vim.uv.now() >= deadline then
            break
        end
        sleep(HOVER_RETRY_MS)
    end
    if placeholder_hover(text) then
        return { hover = nil, note = "the language server is still indexing (" .. text .. "); retry shortly" }
    end
    -- qmlls answers with an empty payload rather than with nothing, and a
    -- bare `"hover": ""` reads as "the position was wrong".
    if vim.trim(text or "") == "" then
        return { hover = nil, note = "the language server returned no hover text for this symbol" }
    end
    return { hover = text }
end






-- Titles of the code actions available for one diagnostic, so the agent
-- knows when the language server can fix a problem itself.
local function quick_fix_titles(bufnr, client, d)
    local lsp_diags = {}
    pcall(function()
        lsp_diags = vim.lsp.diagnostic.from({ d })
    end)
    -- vim.diagnostic columns are 0-based bytes; the server wants characters
    -- in its own offset encoding, the conversion make_position does for a
    -- requested column. Past the end of the line the byte index clamps.
    local encoding = client.offset_encoding or "utf-16"
    local function character(lnum, byte0)
        local text = vim.api.nvim_buf_get_lines(bufnr, lnum, lnum + 1, false)[1] or ""
        local okx, ch = pcall(vim.str_utfindex, text, encoding, math.min(byte0 or 0, #text), false)
        return okx and ch or (byte0 or 0)
    end
    local end_lnum = d.end_lnum or d.lnum
    local ok, actions = pcall(request, client, bufnr, "textDocument/codeAction", {
        textDocument = { uri = vim.uri_from_bufnr(bufnr) },
        range = {
            start = { line = d.lnum, character = character(d.lnum, d.col) },
            ["end"] = { line = end_lnum, character = character(end_lnum, d.end_col or d.col) },
        },
        context = { diagnostics = lsp_diags, triggerKind = 1 },
    })
    if not ok or not actions or #actions == 0 then
        return nil
    end
    local titles, seen = {}, {}
    for _, a in ipairs(actions) do
        -- Only actions the server itself calls a fix. A server that answers
        -- a diagnostic-scoped request with its whole refactor menu offered
        -- "Convert default export to named export" as the fix for a type
        -- error, and the note above tells the caller to apply it. lua_ls and
        -- friends also offer "Disable diagnostics ...", which silences the
        -- problem rather than fixing it.
        -- gopls answers a diagnostic-scoped request with its whole line menu:
        -- "Add test for lastChar" and "Browse arm64 assembly" came back as
        -- quick fixes for an unused variable. Only quickfix kinds, and the
        -- servers that send no kind at all.
        local kind = a.kind or ""
        local fixes = kind == "" or kind:sub(1, 8) == "quickfix"
        if fixes and not seen[a.title]
            and not a.title:find("^Disable diagnostics") and not a.title:find("^Ignore ") then
            seen[a.title] = true
            titles[#titles + 1] = a.title
            if #titles == 3 then break end
        end
    end
    if #titles == 0 then
        return nil
    end
    return titles
end

-- Diagnostics sharing a severity and code beyond this many are folded:
-- the first DIAG_GROUP_SHOW stay verbose, the rest become a line list.
local DIAG_GROUP_MIN = 4
local DIAG_GROUP_SHOW = 3

local function diagnostics(args)
    local bufnr = load_buf(args.file)
    -- A verdict still owed on an earlier edit is settled first: reading the
    -- diagnostics before the server has answered would show the old set.
    edit.flush_deferred(true)
    -- Same reason as before an edit: a file changed by another tool is stale
    -- in the server until it is told, and this file's diagnostics may depend
    -- on it.
    if #resync_open_buffers() > 0 then
        sleep(300)
    end
    -- A file no server will ever attach to (a filetype with no enabled LSP
    -- config and no running client for it) gets an answer at once instead
    -- of the attach timeout and an error: whatever a linter left in
    -- vim.diagnostic, plus a note that no server was consulted.
    if #vim.lsp.get_clients({ bufnr = bufnr }) == 0 then
        local ft = vim.bo[bufnr].filetype
        local serves = #core.enabled_lsp_configs_for(ft) > 0
        if not serves then
            for _, c in ipairs(vim.lsp.get_clients()) do
                ---@diagnostic disable-next-line: undefined-field
                local fts = (c.config or {}).filetypes
                if vim.tbl_contains(fts or {}, ft) then
                    serves = true
                    break
                end
            end
        end
        if not serves then
            local diags = vim.diagnostic.get(bufnr)
            local out = {}
            for _, d in ipairs(diags) do
                out[#out + 1] = {
                    line = d.lnum + 1,
                    col = d.col + 1,
                    severity = vim.diagnostic.severity[d.severity],
                    message = d.message,
                    source = d.source,
                    code = d.code,
                }
            end
            return {
                count = #diags,
                diagnostics = out,
                note = ("no language server is enabled for filetype %s, so nothing checks this "
                    .. "file; install_language(%q) adds one"):format(ft ~= "" and ft or "(none)",
                    ft ~= "" and ft or vim.fn.fnamemodify(args.file, ":e")),
            }
        end
    end
    -- Give a freshly attached server a moment to publish.
    get_client(bufnr, "textDocument/didOpen")
    local deadline = vim.uv.now() + 1000
    while #vim.diagnostic.get(bufnr) == 0 and vim.uv.now() < deadline do
        sleep(100)
    end
    local okc, action_client = pcall(get_client, bufnr, "textDocument/codeAction", 1000)
    local diags = vim.diagnostic.get(bufnr)
    table.sort(diags, function(a, b)
        if a.severity ~= b.severity then return a.severity < b.severity end
        if a.lnum ~= b.lnum then return a.lnum < b.lnum end
        return a.col < b.col
    end)
    -- Many diagnostics with one code (an unresolved dependency reported on
    -- every import) collapse into the first few plus a line list.
    local by_code, groups = {}, {}
    for _, d in ipairs(diags) do
        local key = tostring(d.severity) .. ":" .. tostring(d.code or d.message)
        if not by_code[key] then
            by_code[key] = { n = 0, shown = 0, lines = {} }
            groups[#groups + 1] = by_code[key]
        end
        by_code[key].n = by_code[key].n + 1
    end
    local out, total = {}, #diags
    for i, d in ipairs(diags) do
        local key = tostring(d.severity) .. ":" .. tostring(d.code or d.message)
        local g = by_code[key]
        if g.n > DIAG_GROUP_MIN and g.shown >= DIAG_GROUP_SHOW then
            g.lines[#g.lines + 1] = d.lnum + 1
            if not g.summary then
                g.summary = {
                    severity = vim.diagnostic.severity[d.severity],
                    code = d.code,
                    source = d.source,
                    more = g.n - DIAG_GROUP_SHOW,
                    lines = g.lines,
                    message = ("%d more %s like the ones above, at the listed lines")
                        :format(g.n - DIAG_GROUP_SHOW, tostring(d.code or "")),
                }
                out[#out + 1] = g.summary
            end
        else
            g.shown = g.shown + 1
            local entry = {
                line = d.lnum + 1,
                col = d.col + 1,
                severity = vim.diagnostic.severity[d.severity],
                message = d.message,
                source = d.source,
                code = d.code,
            }
            if okc and i <= 8 and d.severity <= vim.diagnostic.severity.WARN then
                entry.quick_fixes = quick_fix_titles(bufnr, action_client, d)
            end
            out[#out + 1] = entry
        end
    end
    -- An empty answer is only as good as the server behind it. The edit tools
    -- hedge here; this one used to return {"count": 0, "diagnostics": []} for
    -- a shell file that `bash -n` rejects outright, which is the same lie
    -- through a different door.
    local silent = total == 0 and edit.silent_server(bufnr, nil, 0) or nil
    return {
        count = total,
        diagnostics = out,
        note = total > 0
            and "quick_fixes lists code actions the language server can apply for you: "
            .. "call code_actions with this file and line (the col above is optional), "
            .. "then apply_code_action, instead of editing by hand"
            or silent and ("nothing is reported for this file, but %s has published no "
                .. "diagnostics at all in this session, so this is not evidence that the file "
                .. "is clean; check_project runs the project's own build or check"):format(silent)
            or nil,
    }
end

















local function call_hierarchy(direction)
    local method = direction == "in"
        and "callHierarchy/incomingCalls" or "callHierarchy/outgoingCalls"
    return function(args)
        local bufnr = load_buf(args.file)
        local client = get_client(bufnr, "textDocument/prepareCallHierarchy")
        local items = request(client, bufnr, "textDocument/prepareCallHierarchy",
            position_params(bufnr, client, args))
        if not items or #items == 0 then
            return { calls = {}, note = "no call hierarchy item at this position" }
        end
        local calls = request(client, bufnr, method, { item = items[1] })
        local out = {}
        for _, c in ipairs(calls or {}) do
            local it = c.from or c.to
            out[#out + 1] = {
                name = it.name,
                kind = symbol_kind(it.kind),
                file = vim.uri_to_fname(it.uri),
                line = it.selectionRange.start.line + 1,
                call_sites = vim.tbl_map(function(r)
                    return r.start.line + 1
                end, c.fromRanges or {}),
            }
        end
        return { for_symbol = items[1].name, calls = out }
    end
end

-- Combo tool: definition lookup + source of the whole defining symbol +
-- hover, in one round-trip. Cuts the agent's most common two-step
-- (definition, then read the target) down to a single call.
local MAX_EXPAND_LINES = 200

local function expand_symbol(args)
    local bufnr = load_buf(args.file)
    local client = get_client(bufnr, "textDocument/definition")
    local pos = position_params(bufnr, client, args)
    local defres = format_locations(request(client, bufnr, "textDocument/definition", pos))
    if #defres.locations == 0 then
        return { note = "no definition found at this position" }
    end
    local loc = defres.locations[1]
    local tbuf = load_buf(loc.file)
    local target0 = loc.line - 1

    -- Find the smallest document symbol whose range contains the definition.
    local best
    local ok, syms = pcall(function()
        local tclient = get_client(tbuf, "textDocument/documentSymbol")
        return request(tclient, tbuf, "textDocument/documentSymbol",
            { textDocument = { uri = vim.uri_from_bufnr(tbuf) } })
    end)
    if ok then
        local function walk(list)
            for _, s in ipairs(list or {}) do
                local rng = s.range or (s.location and s.location.range)
                if rng and rng.start.line <= target0 and rng["end"].line >= target0 then
                    local size = rng["end"].line - rng.start.line
                    if not best or size < (best.rng["end"].line - best.rng.start.line) then
                        best = { sym = s, rng = rng }
                    end
                end
                walk(s.children)
            end
        end
        walk(syms)
    end

    local first0, last0
    if best then
        first0, last0 = best.rng.start.line, best.rng["end"].line
    else
        first0, last0 = math.max(0, target0 - 5), target0 + 20
    end
    local truncated = false
    if last0 - first0 > MAX_EXPAND_LINES then
        last0 = first0 + MAX_EXPAND_LINES
        truncated = true
    end
    local lines = vim.api.nvim_buf_get_lines(tbuf, first0,
        math.min(last0 + 1, vim.api.nvim_buf_line_count(tbuf)), false)
    local numbered = {}
    for i, l in ipairs(lines) do
        numbered[i] = ("%d: %s"):format(first0 + i, l)
    end

    local hover_text
    local hok, hres = pcall(request, client, bufnr, "textDocument/hover", pos)
    if hok and hres and hres.contents then
        hover_text = table.concat(
            vim.lsp.util.convert_input_to_markdown_lines(hres.contents), "\n")
    end

    return {
        definition = loc,
        symbol = best and best.sym.name or nil,
        source = numbered,
        hover = hover_text,
        note = truncated and ("source truncated to %d lines"):format(MAX_EXPAND_LINES) or nil,
    }
end




-- The editor's live view of a file, including unsaved changes -- the one
-- thing the agent's own Read tool cannot see.
local function buffer_lines(args)
    local bufnr = load_buf(args.file)
    local total = vim.api.nvim_buf_line_count(bufnr)
    -- Same guard as read_file: an unbounded read of a large file returns
    -- its structure instead of thousands of lines.
    if not args.first and not args.last and total > 400 then
        local outline = ts_outline(bufnr)
        if outline and #outline > 0 then
            return {
                total_lines = total,
                modified = vim.bo[bufnr].modified,
                outline = outline,
                note = ("%d lines - returning the structure instead. Re-call with "
                    .. "first/last for a region, or use find_symbol include_body=true "
                    .. "for one symbol."):format(total),
            }
        end
    end
    local first = tonumber(args.first) or 1
    local last = tonumber(args.last) or vim.api.nvim_buf_line_count(bufnr)
    pcall(function()
        require("agent99.ui").on_read(vim.api.nvim_buf_get_name(bufnr), first)
    end)
    local lines = vim.api.nvim_buf_get_lines(bufnr, first - 1, last, false)
    local numbered = {}
    for i, l in ipairs(lines) do
        numbered[i] = ("%d: %s"):format(first + i - 1, l)
    end
    return {
        modified = vim.bo[bufnr].modified,
        total_lines = vim.api.nvim_buf_line_count(bufnr),
        lines = numbered,
    }
end

-- ------------------------------------------------------ symbol addressing --
--
-- Symbols are addressed by name path, joined with "/" (e.g. "MyClass/method"
-- or just "M.greet"). The index is built from treesitter (fast, no server)
-- with LSP document symbols as fallback, cached per buffer changedtick.





















-- File lifecycle: create, move, delete.
--
-- These exist so that a refactor does not have to leave the editor halfway
-- through. Adding a file, splitting a module, renaming one - doing those
-- with a shell means the language servers never hear about it, and the very
-- next symbol tool is working from a stale picture of the project.
--
-- The interesting one is move_file. The LSP file-operation requests let a
-- server rewrite the project before and after the move, which is how the
-- import paths in every file that referenced the old name get fixed. Doing
-- the same move with `mv` leaves the agent to find and repair them by hand.











-- doc_block_start (defined above replace_symbol_lines) is what anything
-- that moves a symbol widens its range by, or the documentation is left
-- behind, orphaned above whatever follows.





















-- ---------------------------------------------------------------------------
-- unreferenced_symbols: what an extract-to-module refactor leaves behind.
--
-- Moving a group of functions into a new module and rewriting their call
-- sites leaves the original definitions in place unless something removes
-- them, and nothing complains: an unreferenced function is not an error to a
-- language server, and a project linter does not report one either. Every
-- edit along the way honestly answers "no new errors or warnings", and the
-- dead copy ships. This is the sweep that finds it, and the one thing worth
-- running at the end of an extraction.

local MAX_UNREFERENCED_FILES = 40

local MAX_UNREFERENCED_SYMBOLS = 200

-- One text search over the whole tree answers for every name at once; this
-- bounds it, so a huge tree costs one timeout rather than one per symbol.
local TEXT_SEARCH_TIMEOUT_MS = 30 * 1000

-- Every whole-word occurrence of each of `names` in the project, as a map
-- from name to file/line pairs, from a single rg (or grep) run. The fallback
-- for a file whose language has no server that answers references (QML is
-- one), which is the sweep a careful caller does by hand. nil means the
-- search could not be run or did not finish.
local function textual_hits(root, names)
    if #names == 0 then
        return {}
    end
    local cmd
    if vim.fn.executable("rg") == 1 then
        -- -o prints the matched word itself, which is what attributes each
        -- hit to its name when many are searched at once. rg skips .git and
        -- ignored files on its own.
        cmd = { "rg", "--no-heading", "--line-number", "--only-matching",
            "--word-regexp", "--fixed-strings" }
    elseif vim.fn.executable("grep") == 1 then
        cmd = { "grep", "-rnwIoF", "--exclude-dir=.git" }
    else
        return nil
    end
    for _, name in ipairs(names) do
        cmd[#cmd + 1] = "-e"
        cmd[#cmd + 1] = name
    end
    cmd[#cmd + 1] = "--"
    cmd[#cmd + 1] = root
    local result = core.await(function(resume)
        -- The exit callback runs in a fast event context, where buffers
        -- cannot be loaded; schedule the resume onto the main loop.
        local ok, e = pcall(vim.system, cmd, { text = true, timeout = TEXT_SEARCH_TIMEOUT_MS },
            vim.schedule_wrap(resume))
        if not ok then
            resume({ code = -1, stderr = tostring(e) })
        end
    end)
    -- Both searchers exit 1 for "nothing matched", which is an answer; a
    -- search killed at the timeout (124, SIGTERM) is not, and neither is a
    -- searcher that failed.
    if result.code == 124 and result.signal == 15 then
        return nil, "timed out"
    end
    if result.code > 1 then
        return nil
    end
    local hits, seen = {}, {}
    for _, name in ipairs(names) do
        hits[name] = {}
    end
    for line in (result.stdout or ""):gmatch("[^\n]+") do
        local path, lnum, name = line:match("^(.-):(%d+):(.*)$")
        if path and hits[name] then
            -- One hit per line and name, as a line-oriented search reports.
            local key = name .. "\0" .. path .. "\0" .. lnum
            if not seen[key] then
                seen[key] = true
                local list = hits[name]
                list[#list + 1] = { file = path, line = tonumber(lnum) }
            end
        end
    end
    return hits
end

-- The identifier a symbol is written as at a call site: the last component
-- of the name the index gives it. A Go method is indexed `(*Archiver).Do`
-- and called `a.Do(...)`; a Lua one is `M.greet` and called `util.greet(...)`.
local function bare_name(name)
    return name:match("[^%.:/]+$") or name
end

-- The line inside the symbol that carries its name, which is where a
-- reference request has to be made from. Almost always the first line; a
-- grammar that puts the name on the line after the keyword is the reason
-- this looks past it.
local function name_line(lines, entry)
    -- The reference request has to sit on the name itself. An entry named
    -- "M.noop" would put it on the M, and the answer would then be about M:
    -- its other uses are real references and the symbol looks alive. The
    -- last component is the one being declared here.
    local name = entry.name:match("[^%.:/]+$") or entry.name
    -- Whole word only: "get" inside "widget" or "getter" is not the name,
    -- and a request made there would be about the other identifier.
    local pattern = "%f[%w_]" .. name:gsub("%W", "%%%0") .. "%f[^%w_]"
    for lnum = entry.first, math.min(entry.last, entry.first + 2) do
        local text = lines[lnum]
        local s = text and text:find(pattern)
        if s then
            -- The 1-based byte column too: a caller that passed only the
            -- name would land on its first plain occurrence again.
            return lnum, name, s
        end
    end
    return nil
end

-- How many places outside the symbol's own body mention it. nil means the
-- question could not be answered, which is not the same as zero and is
-- reported as such.
local function references_outside(bufnr, path, entry, lines, client, root, cache, want_tests)
    -- A helper declared in a test file is used by tests and nowhere else by
    -- design, so dropping test references there reports every one of them as
    -- dead: 30 of one repository's 72 findings were its own test fixtures.
    -- Test references still do not keep production code alive.
    local own_is_test = core.is_test_path(rel_path(path))
    -- A Go doc comment starts with the symbol's name, and it sits above the
    -- declaration, so a text search counted it as a use: every documented
    -- dead function looked alive, and the only findings left in a whole
    -- repository were the undocumented ones.
    local own_first = entry.first
    do
        local ok, doc = pcall(index.doc_block_start, bufnr, entry.first)
        if ok and type(doc) == "number" and doc < own_first then own_first = doc end
    end
    local function counts(list, file_of)
        local n = 0
        for _, hit in ipairs(list) do
            local file, lnum = file_of(hit)
            local own = file == path and lnum >= own_first and lnum <= entry.last
            if not own and (want_tests or own_is_test or not core.is_test_path(rel_path(file))) then
                n = n + 1
            end
        end
        return n
    end
    -- The text search ran once for every name before this loop; a name it
    -- did not cover (a batch that failed) is searched on its own here. It
    -- searches the bare name: a method indexed as `(*Archiver).Candidates`
    -- is written `a.Candidates(...)` at every call site, so a whole-word
    -- search for the qualified spelling can never hit, and every method in
    -- the file came back unreferenced. The bare name over-counts instead
    -- (another type's method of the same name is a hit), which keeps live
    -- code off the list rather than putting it on.
    local function text_count()
        local key = bare_name(entry.name)
        if cache[key] == nil then
            local found = textual_hits(root, { key })
            cache[key] = found and found[key] or false
        end
        local hits = cache[key]
        if hits == false then
            return nil
        end
        -- A mention in prose is not a use. The text search knows nothing
        -- about comments, so a function named in a doc comment anywhere in
        -- the tree, or inside a string literal, counted as referenced -
        -- which is most functions worth deleting. The classifier grep uses
        -- settles it; a hit it cannot classify counts, as before.
        local code_hits = {}
        for _, hit in ipairs(hits) do
            local okb, hbuf = pcall(load_buf, hit.file)
            local kind = nil
            if okb then
                local oke, k = pcall(index.classify_hit, hbuf, hit.line, hit.col or 1, nil)
                kind = oke and k or nil
            end
            if kind ~= "comment" and kind ~= "string" then
                code_hits[#code_hits + 1] = hit
            end
        end
        return counts(code_hits, function(hit) return hit.file, hit.line end)
    end
    if client then
        local lnum, _, col = name_line(lines, entry)
        if not lnum then
            return nil
        end
        local okp, params = pcall(position_params, bufnr, client,
            { line = lnum, col = col })
        if not okp then
            return nil
        end
        params.context = { includeDeclaration = false }
        local okr, result = pcall(request, client, bufnr, "textDocument/references", params)
        if not okr then
            return nil
        end
        -- A server with nothing to report answers with an empty list or with
        -- nothing at all; both mean zero references, and only a request that
        -- failed means the question went unanswered.
        if result == nil then
            result = {}
        end
        if type(result) ~= "table" then
            return nil
        end
        local n = counts(result, function(loc)
            local uri = loc.uri or loc.targetUri
            local range = loc.range or loc.targetSelectionRange
            return uri and vim.uri_to_fname(uri) or path,
                range and (range.start.line + 1) or 0
        end)
        if n > 0 then
            return n
        end
        -- Zero from the server is the answer that gets code deleted, and it
        -- is also what a server whose module graph does not resolve says
        -- about everything: on a monorepo with no node_modules installed,
        -- tsserver reported a function with two live call sites in another
        -- package as referenced by nobody. A zero is therefore cross-checked
        -- against the text search, which knows nothing about modules; when
        -- that cannot run either, the server's answer stands.
        local text = text_count()
        return text or 0
    end
    return text_count()
end

-- A test the runner reaches by reflection, or a program's entry point. These
-- have no caller by construction, so listing them is noise that buries the
-- findings: 78 of one run's 78 entries were Go test functions, and they ate
-- the file budget on the way.
-- A symbol with no name of its own: an anonymous callback the server named
-- after its first parameter or after the call around it. Nothing references
-- those and nothing can delete them, so they are noise in this list.
local function anonymous(entry)
    local name = entry.name or ""
    -- Anchored: a server's placeholder for an anonymous function is called
    -- `callback`, but `handle_callback` is a function somebody wrote and can
    -- delete, and the unanchored match dropped it from the list unchecked.
    return name == "" or name:find("^<") ~= nil or name:find("%(%)") ~= nil
        or name:match("^callback%d*$") ~= nil or name:find("^line%d+$") ~= nil
end

local function entry_point(entry, path)
    local name = bare_name(entry.name)
    if name == "main" or name == "init" or name == "setup" or name == "teardown" then
        return true
    end
    if not core.is_test_path(rel_path(path)) then
        return false
    end
    -- Go's rule is that what follows the prefix must not be a lower-case
    -- letter: Benchmark404 and Example2 are entry points, and requiring an
    -- upper-case letter reported exactly those as dead code.
    for _, prefix in ipairs({ "Test", "Benchmark", "Example", "Fuzz" }) do
        local rest = name:match("^" .. prefix .. "(.*)$")
        if rest and not rest:match("^%l") then
            return true
        end
    end
    return name:match("^test_") ~= nil or name:match("^[Tt]est") ~= nil
end

-- A field set on an object this file did not declare: `vim.opt.number`,
-- `os.environ["X"]`. Servers report those as symbols of the file, and a
-- setting is not a definition anything could reference - 24 of 27 findings
-- in a Neovim configuration were `vim.opt.*` lines. A field on an object the
-- file does declare (`M.greet` after `local M = {}`) is a real declaration
-- and stays.
local function foreign_field(entry, declared_here)
    local head = (entry.name or ""):match("^[^%.:]+")
    if not head or head == entry.name then
        return false
    end
    return not declared_here[head]
end

local function unreferenced_symbols(args)
    local files = {}
    if type(args.file) == "string" and args.file ~= "" then
        files[#files + 1] = args.file
    end
    for _, f in ipairs(args.files or {}) do
        files[#files + 1] = f
    end
    local glob_note
    if type(args.glob) == "string" and args.glob ~= "" then
        local paths, why = core.expand_glob(args.root, args.glob)
        glob_note = why
        vim.list_extend(files, paths)
    end
    if #files == 0 then
        err("%s", glob_note or "no files to check: pass file, files or glob")
    end
    local capped = 0
    if #files > MAX_UNREFERENCED_FILES then
        capped = #files - MAX_UNREFERENCED_FILES
        files = vim.list_slice(files, 1, MAX_UNREFERENCED_FILES)
    end
    local root = args.root
    if type(root) ~= "string" or root == "" then
        root = vim.fn.getcwd()
    end
    local dead, unknown, methods, cache = {}, {}, {}, {}
    local checked = 0
    -- What was left out and why. Without this the reply asserted that every
    -- top-level symbol in a file was referenced when the file held nothing
    -- but methods and not one symbol had been examined.
    local skipped = {}
    -- First pass: load every file and pick its top-level symbols, so the
    -- names that need a text search are known before any search runs.
    -- Top-level names only. A method is reached through its receiver, and a
    -- zero-reference answer for one says more about the server than about
    -- the code.
    local work, text_names, text_seen = {}, {}, {}
    for _, f in ipairs(files) do
        local okb, bufnr = pcall(load_buf, f)
        if okb then
            local path = vim.api.nvim_buf_get_name(bufnr)
            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            local client = core.client_for(bufnr, "textDocument/references")
            methods[client and "language server" or "text search"] = true
            local entries = {}
            -- Only undotted names count as declared here: seeding this from
            -- every entry would let `vim.opt.number` declare `vim`, and so
            -- vouch for itself.
            local declared_here = {}
            for _, e in ipairs(symbol_index(bufnr)) do
                local name = e.name or ""
                if name ~= "" and not name:find("[%.:]") then
                    declared_here[name] = true
                end
            end
            for _, e in ipairs(symbol_index(bufnr)) do
                local why
                if not e.name or e.name == "" or anonymous(e) then
                    why = "anonymous"
                elseif e.path:find("/", 1, true) then
                    why = "nested"
                elseif entry_point(e, path) then
                    why = "entry_point"
                elseif foreign_field(e, declared_here) then
                    why = "method_or_field"
                end
                if why then
                    skipped[why] = (skipped[why] or 0) + 1
                elseif checked < MAX_UNREFERENCED_SYMBOLS then
                    checked = checked + 1
                    entries[#entries + 1] = e
                    local key = bare_name(e.name)
                    if not client and not text_seen[key] then
                        text_seen[key] = true
                        text_names[#text_names + 1] = key
                    end
                end
            end
            work[#work + 1] = { bufnr = bufnr, path = path, lines = lines, client = client, entries = entries }
        end
    end
    -- One search for all the names at once, rather than one process per
    -- symbol; a search that could not run leaves the cache empty, and each
    -- name is then tried alone in references_outside.
    local search_note
    if #text_names > 0 then
        local found, why = textual_hits(root, text_names)
        if found then
            for name, hits in pairs(found) do
                cache[name] = hits
            end
        elseif why then
            search_note = ("the text search %s after %d s; names it did not answer are listed under not_answered")
                :format(why, TEXT_SEARCH_TIMEOUT_MS / 1000)
            for _, name in ipairs(text_names) do
                cache[name] = false
            end
        end
    end
    for _, w in ipairs(work) do
        for _, e in ipairs(w.entries) do
            local n = references_outside(w.bufnr, w.path, e, w.lines, w.client, root,
                cache, args.include_tests)
            local entry = { file = w.path, line = e.first, name = e.path, kind = e.kind }
            if n == nil then
                unknown[#unknown + 1] = entry
            elseif n == 0 then
                dead[#dead + 1] = entry
            end
        end
    end
    local method_names = vim.tbl_keys(methods)
    table.sort(method_names)
    -- The skipped set, in the order a reader wants it: the deliberate policy
    -- exclusions first, the housekeeping ones after.
    -- Each reason carries its own justification. One sentence about methods
    -- and receivers used to explain all of them, which was nonsense on a
    -- module of plain functions whose 85 "skipped declarations" were locals
    -- inside those functions.
    local SKIP_LABEL = {
        method_or_field = "methods, and fields on an object this file does not declare",
        nested = "names declared inside another symbol (locals, parameters, nested functions)",
        entry_point = "entry points and tests, which have no caller by construction",
        anonymous = "anonymous declarations",
    }
    local SKIP_WHY = {
        method_or_field = "a method is reached through its receiver, and a zero-reference "
            .. "answer for one says more about the server than about the code",
        nested = "this tool reports top-level symbols only; a local is scoped to the symbol "
            .. "around it and its own server already warns when it is unused",
        entry_point = "nothing calls them by name, so a zero-reference answer means nothing",
        anonymous = "nothing can reference them and nothing can delete them by name",
    }
    local skipped_total, skipped_parts, skipped_why = 0, {}, {}
    for _, k in ipairs({ "method_or_field", "nested", "entry_point", "anonymous" }) do
        if skipped[k] then
            skipped_total = skipped_total + skipped[k]
            skipped_parts[#skipped_parts + 1] = ("%d %s"):format(skipped[k], SKIP_LABEL[k])
            skipped_why[#skipped_why + 1] = SKIP_WHY[k]
        end
    end
    local skipped_text = table.concat(skipped_parts, ", ")
    local res = {
        symbols_checked = checked,
        symbols_skipped = skipped_total > 0 and skipped_total or nil,
        count = #dead,
        unreferenced = #dead > 0 and dead or nil,
        method = #method_names > 0 and table.concat(method_names, " and ") or nil,
    }
    if skipped_total > 0 then
        res.symbols_skipped_note = ("not examined: %s - %s."):format(
            skipped_text, table.concat(skipped_why, "; "))
    end
    -- The answer is only as strong as what produced it, and "referenced
    -- somewhere else" from a whole-word text search is a much weaker claim
    -- than the same sentence backed by the language server. The method was
    -- reported as a bare field and the summary read identically either way.
    if res.method == "text search" then
        res.method_note = "no language server answered reference requests for these files, so "
            .. "this rests on a whole-word text search: a name that appears in a comment, a "
            .. "string or a stale call site counts as a reference"
    elseif res.method == "language server and text search" then
        res.method_note = "some of these files were answered by the language server and some "
            .. "by a whole-word text search, which is the weaker of the two"
    end
    -- A server that cannot resolve the project's imports answers about one
    -- package and calls it the project. references says so where it answers;
    -- this tool rests on the same data and used to assert flatly.
    local missing = core.deps_missing(root)
    if missing then
        res.may_be_incomplete = "the language server cannot resolve this project's imports ("
            .. missing .. ") so references from other packages are invisible to it; a symbol "
            .. "listed here may be used from one of them"
    end
    if #unknown > 0 then
        res.not_answered = unknown
        res.not_answered_note = "no reference answer for these; they are not a finding either way"
    end
    if search_note then
        res.search_note = search_note
    end
    if checked >= MAX_UNREFERENCED_SYMBOLS then
        res.symbols_note = ("stopped after %d symbols; the files after that were not fully "
            .. "checked - narrow with a smaller glob or a files list"):format(MAX_UNREFERENCED_SYMBOLS)
    end
    if capped > 0 then
        res.note = ("%d further files were not checked (cap: %d)"):format(capped, MAX_UNREFERENCED_FILES)
    end
    if checked == 0 then
        -- The reply used to say "every top-level symbol in these files is
        -- referenced somewhere else" whenever nothing was found, including
        -- when nothing had been looked at: a Go file of three methods came
        -- back with that sentence and symbols_checked: 0.
        -- "All N declarations in these files" counted every name the symbol
        -- index reported, locals included, and sent a reader looking for four
        -- declarations that do not exist in a four-declaration file.
        res.summary = skipped_total > 0
            and ("nothing was checked: every one of the %d names indexed in these files is "
                .. "something this tool does not check (%s), so this reply is not evidence "
                .. "that any of them is used"):format(skipped_total, skipped_text)
            or "nothing was checked: no declaration in these files was eligible"
    elseif #dead > 0 then
        res.summary = "nothing outside its own body mentions these names. A symbol that is "
            .. "this file's public API, reached by reflection or a string, or used from a "
            .. "file the search cannot see (another build configuration, another language) "
            .. "lands here too, so read each one before deleting it."
    else
        res.summary = ("every one of the %d symbols checked in these files is referenced "
            .. "somewhere else"):format(checked)
        if skipped_total > 0 then
            res.summary = res.summary
                .. ("; %d further indexed names were not checked (%s)"):format(skipped_total, skipped_text)
        end
    end
    return res
end

local dispatch_table = {
    definition = location_tool("textDocument/definition"),
    type_definition = location_tool("textDocument/typeDefinition"),
    implementation = location_tool("textDocument/implementation"),
    references = function(args)
        local tool = location_tool("textDocument/references",
            { context = { includeDeclaration = true } })
        local result = tool(args)
        if (result.count or 0) <= 1 then
            local okb, bufnr = pcall(load_buf, args.file)
            if okb and fresh_buf(bufnr) then
                sleep(FRESH_RETRY_MS)
                result = tool(args)
            end
        end
        annotate_locations(result.locations or {})
        -- Group by file so the path is written once per file, not per hit.
        local groups, order = {}, {}
        for _, loc in ipairs(result.locations or {}) do
            local file = loc.file
            if not groups[file] then
                groups[file] = { file = file, hits = {} }
                order[#order + 1] = file
            end
            loc.file = nil
            table.insert(groups[file].hits, loc)
        end
        local files = {}
        for _, file in ipairs(order) do
            files[#files + 1] = groups[file]
        end
        result.locations = nil
        result.files = files
        -- A server that cannot resolve the project's imports answers about
        -- one package and looks complete: on a monorepo with no node_modules
        -- installed, this returned 23 hits in 3 files while the symbol was
        -- used in 6, and rename_symbol went on to break the other 3. The
        -- caveat belongs here, where the answer is read, not only in the
        -- reply to open_workspace.
        local root = args.root or vim.fn.getcwd()
        local missing = core.deps_missing(root)
        if missing then
            result.may_be_incomplete = "the language server cannot resolve this project's "
                .. "imports (" .. missing .. ") so references from other packages are missing "
                .. "from this answer; grep for the name to see them"
        end
        -- "Only the declaration" is the answer a server gives for genuinely
        -- dead code and the answer it gives while its workspace index is still
        -- building, and the two are indistinguishable from the reply. A shell
        -- function with eleven call sites in six files came back as count: 1,
        -- and the identical call later in the same session came back as 11.
        -- That is a delete-it-and-ship-it answer, so the one case where it
        -- matters is checked against a plain text search before answering.
        if (result.count or 0) <= 1 and #(result.files or {}) <= 1 then
            local name = args.symbol
            if type(name) ~= "string" or name == "" then
                local hit = result.files and result.files[1] and result.files[1].hits[1]
                name = hit and hit.text and hit.text:match("[%w_]+") or nil
            end
            local found = name and textual_hits(root, { name })
            local elsewhere, seen = {}, {}
            local here = result.files and result.files[1] and result.files[1].file
            for _, h in ipairs(found and found[name] or {}) do
                if h.file ~= here and not seen[h.file] then
                    seen[h.file] = true
                    elsewhere[#elsewhere + 1] = rel_path(h.file)
                end
            end
            if #elsewhere > 0 then
                table.sort(elsewhere)
                result.text_search_disagrees = elsewhere
                result.text_search_note = ("the server reports no reference outside the "
                    .. "declaration, but a plain text search finds %q in %d other file(s). A "
                    .. "server whose workspace index is still building answers exactly like "
                    .. "one that has found nothing, so do not read this as dead code: check "
                    .. "those files, or ask again in a moment."):format(name, #elsewhere)
            end
        end
        return result
    end,
    hover = hover,
    document_symbols = document_symbols,
    workspace_symbols = workspace_symbols,
    diagnostics = diagnostics,
    incoming_calls = call_hierarchy("in"),
    outgoing_calls = call_hierarchy("out"),
    buffer_lines = buffer_lines,
    expand_symbol = expand_symbol,
    code_actions = code_actions,
    apply_code_action = apply_code_action,
    skim = skim,
    workspace_map = workspace_map,
    workspace_tree = workspace_tree,
    run_tests = run_tests,
    workspace_support = workspace_support,
    install_language = install_language,
    ts_query = ts_query,
    find_symbol = find_symbol,
    replace_symbol_body = replace_symbol_body,
    replace_symbol_lines = replace_symbol_lines,
    insert_after_symbol = insert_symbol_tool("after"),
    insert_before_symbol = insert_symbol_tool("before"),
    insert_lines = insert_lines,
    undo_edit = undo_edit,
    rename_symbol = rename_symbol,
    replace_pattern = replace_pattern,
    create_file = create_file,
    move_file = move_file,
    delete_file = delete_file,
    move_symbols = move_symbols,
    check_project = check_project,
    unreferenced_symbols = unreferenced_symbols,
    enclosing_symbols = enclosing_symbols,
    -- Internal: the bridge reports a disk read so the code window can follow.
    ui_follow = function(args)
        pcall(function()
            require("agent99.ui").on_read(args.file, tonumber(args.line) or 1)
        end)
        return { ok = true }
    end,
    -- Internal: a reply produced outside the editor (grep, read_file) asks
    -- for what earlier edits still owe; the dispatcher attaches it to this
    -- empty result like to any other.
    verdict_carry = function() return {} end,
}

-- Every tool that writes, wrapped once here rather than guarded in each of
-- them: a path outside the workspace the call was routed to is refused
-- before anything is opened. Reading outside stays allowed; see
-- core.assert_writable for why.
local WRITE_TOOLS = {
    replace_symbol_body = true, replace_symbol_lines = true,
    insert_after_symbol = true, insert_before_symbol = true, insert_lines = true,
    create_file = true, move_file = true, delete_file = true,
    move_symbols = true, replace_pattern = true,
}

-- The symbol edits take one file. `files=` runs the same call once per file
-- and answers with one report each: the same helper added to four modules,
-- the same line replaced in three, used to be four and three calls, and the
-- undo of them was as many steps.
local PER_FILE_TOOLS = {
    replace_symbol_body = true, replace_symbol_lines = true,
    insert_after_symbol = true, insert_before_symbol = true,
}

for name in pairs(PER_FILE_TOOLS) do
    local fn = dispatch_table[name]
    if fn then
        dispatch_table[name] = function(args)
            args = args or {}
            local files = args.files
            if type(files) ~= "table" or #files == 0 then
                return fn(args)
            end
            if type(args.file) == "string" and args.file ~= "" then
                core.err("give file or files, not both")
            end
            -- Every file is checked before any of them is written: an edit
            -- over three files that failed on the second used to leave the
            -- first one changed, with nothing in the error to say so.
            for _, f in ipairs(files) do
                if type(f) ~= "string" or f == "" then
                    core.err("files must be an array of paths")
                end
                local probe = vim.tbl_extend("force", args, { file = f, files = nil, dry_run = true })
                local ok, res = pcall(fn, probe)
                if not ok then
                    core.err("%s: %s", core.rel_path(f),
                        tostring(res):gsub("^[^:]*:%d+: ", ""))
                end
            end
            local reports = {}
            require("agent99.edits").as_one_step(function()
                for _, f in ipairs(files) do
                    local one = vim.tbl_extend("force", args, { file = f, files = nil })
                    local ok, res = pcall(fn, one)
                    if not ok then
                        -- Name the file: "no symbol named X" says nothing
                        -- about which of four files did not have it.
                        core.err("%s: %s", core.rel_path(f),
                            type(res) == "table" and (res.message or vim.inspect(res))
                            or tostring(res):gsub("^[^:]*:%d+: ", ""))
                    end
                    res.file = res.file or f
                    reports[#reports + 1] = res
                end
            end)
            return { files = #reports, reports = reports }
        end
    end
end

for name in pairs(WRITE_TOOLS) do
    local fn = dispatch_table[name]
    if fn then
        dispatch_table[name] = function(args)
            args = args or {}
            local paths = {}
            for _, key in ipairs({ "file", "from", "to" }) do
                if type(args[key]) == "string" and args[key] ~= "" then
                    paths[#paths + 1] = args[key]
                end
            end
            if args.files ~= nil and type(args.files) ~= "table" then
                core.err("files must be an array of paths, not a %s", type(args.files))
            end
            for _, f in ipairs(args.files or {}) do
                if type(f) == "string" and f ~= "" then
                    paths[#paths + 1] = f
                end
            end
            for _, p in ipairs(paths) do
                core.assert_writable(p, args.root, name)
            end
            return fn(args)
        end
    end
end

-- Turn absolute "file" fields (and changed_files lists) into paths relative
-- to the working directory before the result leaves the editor.
local function relativize(value, key)
    if type(value) == "string" then
        if (key == "file" or key == "changed_files") and value:sub(1, 1) == "/" then
            return rel_path(value)
        end
        return value
    end
    if type(value) ~= "table" then
        return value
    end
    for k, v in pairs(value) do
        value[k] = relativize(v, type(k) == "string" and k or key)
    end
    return value
end

function M.dispatch(tool, args)
    local fn = dispatch_table[tool]
    if not fn then
        -- The debugger tools live in their own module; they share the
        -- transport, the position addressing and the relativized replies.
        local okd, dap_tools = pcall(require, "agent99.dap")
        if okd and dap_tools.handles(tool) then
            return relativize(dap_tools.dispatch(tool, args))
        end
        err("unknown tool: %s", tostring(tool))
    end
    local result = fn(args or {})
    -- ui_follow and enclosing_symbols are the bridge's own calls in the
    -- middle of serving a read or a grep, not replies the agent sees: they
    -- take no carry (it would vanish) and keep absolute paths.
    local internal = tool == "ui_follow" or tool == "enclosing_symbols"
    -- Verdicts owed from earlier edits (deferred by wait=false, or
    -- diagnostics that arrived after their report) ride on this reply.
    if not internal and type(result) == "table"
        and (vim.tbl_isempty(result) or not vim.islist(result)) then
        for k, v in pairs(edit.take_carry()) do
            if result[k] == nil then result[k] = v end
        end
    end
    if not internal then
        result = relativize(result)
    end
    return result
end

-- Internals shared with agent99.dap, exported rather than moved so the
-- debugger module can reuse the coroutine helpers, buffer loading and the
-- symbol index without this file growing further.
M._internal = {
    await = core.await,
    sleep = core.sleep,
    err = core.err,
    load_buf = core.load_buf,
    resolve_symbol = index.resolve_symbol,
    rel_path = core.rel_path,
    disk_fingerprint = core.disk_fingerprint,
    symbol_index = index.symbol_index,
    innermost_entry = index.innermost_entry,
    decl_line = core.decl_line,
}
return M
