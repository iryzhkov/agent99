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

local ATTACH_TIMEOUT_MS = 5000
local REQUEST_TIMEOUT_MS = 10000
local MAX_LOCATIONS = 100

local function err(fmt, ...)
    error(fmt:format(...), 0)
end

-- Run `start(resume)` and yield until `resume(...)` is called. Guarded so a
-- late second resume (e.g. an LSP reply after its timeout fired) is ignored,
-- and so a resume that happens synchronously inside `start` works too.
local function await(start)
    local co = assert(coroutine.running(), "agent99: await called outside a coroutine")
    local resumed, yielded = false, false
    local sync_result
    start(function(...)
        if resumed then return end
        resumed = true
        if not yielded then
            sync_result = { n = select("#", ...), ... }
            return
        end
        local ok, e = coroutine.resume(co, ...)
        if not ok then
            vim.notify("agent99 rpc: " .. tostring(e), vim.log.levels.ERROR)
        end
    end)
    if resumed then
        return unpack(sync_result, 1, sync_result.n)
    end
    yielded = true
    return coroutine.yield()
end

local function sleep(ms)
    await(function(resume)
        vim.defer_fn(resume, ms)
    end)
end

-- Load `file` into a (possibly hidden) buffer. bufload triggers filetype
-- detection, so vim.lsp.enable()-style auto-attach fires just as it would
-- for an interactively opened file.
local function load_buf(file)
    if type(file) ~= "string" or file == "" then
        err("missing required argument: file")
    end
    local path = vim.fn.fnamemodify(file, ":p")
    if vim.fn.filereadable(path) == 0 then
        err("file not readable: %s", path)
    end
    local bufnr = vim.fn.bufadd(path)
    if not vim.api.nvim_buf_is_loaded(bufnr) then
        vim.fn.bufload(bufnr)
    end
    return bufnr, path
end

-- Wait for an attached client that supports `method`. Attaching can take a
-- moment when the buffer was just loaded and the server is still starting.
local function get_client(bufnr, method, timeout_ms)
    local deadline = vim.uv.now() + (timeout_ms or ATTACH_TIMEOUT_MS)
    while true do
        for _, c in ipairs(vim.lsp.get_clients({ bufnr = bufnr })) do
            if c:supports_method(method, bufnr) then
                return c
            end
        end
        if vim.uv.now() >= deadline then
            err("no LSP client supporting %s is attached to %s (filetype: %s)",
                method, vim.api.nvim_buf_get_name(bufnr), vim.bo[bufnr].filetype)
        end
        sleep(100)
    end
end

-- LSP request that yields until the reply (or a timeout) arrives.
local function request(client, bufnr, method, params)
    local timer = vim.uv.new_timer()
    local rpc_err, result = await(function(resume)
        timer:start(REQUEST_TIMEOUT_MS, 0, vim.schedule_wrap(function()
            resume({ message = ("timed out after %d ms"):format(REQUEST_TIMEOUT_MS) }, nil)
        end))
        local ok = client:request(method, params, function(e, r)
            resume(e, r)
        end, bufnr)
        if not ok then
            resume({ message = "failed to send request" }, nil)
        end
    end)
    timer:stop()
    timer:close()
    if rpc_err then
        err("LSP error from %s for %s: %s", client.name, method,
            rpc_err.message or vim.inspect(rpc_err))
    end
    return result
end

local function make_position(bufnr, client, line, symbol, col)
    line = tonumber(line)
    if not line then
        err("missing required argument: line")
    end
    local text = vim.api.nvim_buf_get_lines(bufnr, line - 1, line, false)[1]
    if text == nil then
        err("line %d is out of range in %s", line, vim.api.nvim_buf_get_name(bufnr))
    end
    local byte0
    if col then
        byte0 = tonumber(col) - 1
    elseif type(symbol) == "string" and symbol ~= "" then
        local s = text:find(symbol, 1, true)
        if not s then
            err("symbol %q not found on line %d, which reads: %s", symbol, line, text)
        end
        byte0 = s - 1
    else
        err("missing required argument: symbol (or col)")
    end
    local encoding = client.offset_encoding or "utf-16"
    local character = vim.str_utfindex(text, encoding, math.min(byte0, #text), false)
    return { line = line - 1, character = character }
end

local function position_params(bufnr, client, args)
    return {
        textDocument = { uri = vim.uri_from_bufnr(bufnr) },
        position = make_position(bufnr, client, args.line, args.symbol, args.col),
    }
end

local function line_preview(path, lnum)
    local bufnr = vim.fn.bufnr(path)
    if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
        return vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]
    end
    local ok, lines = pcall(vim.fn.readfile, path, "", lnum)
    return ok and lines[lnum] or nil
end

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
        out[#out + 1] = {
            file = path,
            line = lnum,
            end_line = range["end"].line + 1,
            text = line_preview(path, lnum),
        }
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

local function symbol_kind(kind)
    return vim.lsp.protocol.SymbolKind[kind] or tostring(kind)
end

local function decl_line(bufnr, lnum)
    local text = (vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or "")
        :gsub("^%s+", "")
    if #text > 120 then
        text = text:sub(1, 120) .. "…"
    end
    return text
end

-- DocumentSymbol[] (hierarchical) or SymbolInformation[] (flat) -> outline,
-- each entry carrying the declaration line so signatures are visible.
local function flatten_symbols(symbols, depth, out, bufnr)
    for _, s in ipairs(symbols or {}) do
        local range = s.selectionRange or (s.location and s.location.range)
        local lnum = range and (range.start.line + 1) or 0
        out[#out + 1] = ("%s%d: %s %s — %s"):format(
            string.rep("  ", depth), lnum, symbol_kind(s.kind), s.name,
            bufnr and lnum > 0 and decl_line(bufnr, lnum) or "")
        if s.children then
            flatten_symbols(s.children, depth + 1, out, bufnr)
        end
    end
    return out
end

-- Treesitter skim: every declaration-shaped node's first line, nested.
-- Fast, needs no language server, works on any file with a parser.
local MAX_SKIM_FILES = 20
local MAX_SKIM_ENTRIES = 150

-- Node types are matched on their underscore-separated segments, exactly:
-- "function_declaration" has segment "function" (wanted), while
-- "table_constructor" does not have segment "struct", and
-- "method_index_expression" is rejected by its "index"/"expression" segments.
local TS_WANTED = {
    ["function"] = true, method = true, class = true, struct = true,
    interface = true, impl = true, module = true, enum = true, trait = true,
}
local TS_EXCLUDED = {
    call = true, parameter = true, parameters = true, argument = true,
    arguments = true, index = true, expression = true, pointer = true,
    import = true, type = true,
}

local function ts_wanted(node_type)
    local wanted = false
    for segment in node_type:gmatch("[^_]+") do
        if TS_EXCLUDED[segment] then
            return false
        end
        if TS_WANTED[segment] then
            wanted = true
        end
    end
    return wanted
end

local function ts_outline(bufnr)
    local ok, parser = pcall(vim.treesitter.get_parser, bufnr)
    if not ok or parser == nil then
        return nil
    end
    local okp, trees = pcall(function()
        return parser:parse()
    end)
    if not okp or not trees or not trees[1] then
        return nil
    end
    local out = {}
    local last_row = -1
    local function walk(node, depth)
        if #out >= MAX_SKIM_ENTRIES then
            return
        end
        for child in node:iter_children() do
            if #out >= MAX_SKIM_ENTRIES then
                return
            end
            if child:named() then
                if ts_wanted(child:type()) then
                    local srow, _, erow = child:range()
                    -- A wrapper and its inner node often start on the same
                    -- row (e.g. declaration + definition); emit it once.
                    if srow ~= last_row then
                        last_row = srow
                        local span = erow > srow
                            and ("%d-%d"):format(srow + 1, erow + 1)
                            or tostring(srow + 1)
                        out[#out + 1] = ("%s%s: %s"):format(
                            string.rep("  ", depth), span, decl_line(bufnr, srow + 1))
                    end
                    walk(child, depth + 1)
                else
                    walk(child, depth)
                end
            end
        end
    end
    walk(trees[1]:root(), 0)
    return out
end

-- Structural multi-file search: run a treesitter query over a set of files.
local MAX_QUERY_FILES = 50
local MAX_QUERY_MATCHES = 200

local function ts_query(args)
    local qstr = args.query
    if type(qstr) ~= "string" or qstr == "" then
        err("missing required argument: query (a treesitter s-expression query)")
    end
    local files = {}
    for _, f in ipairs(args.files or {}) do
        files[#files + 1] = f
    end
    if type(args.glob) == "string" and args.glob ~= "" then
        if type(args.root) ~= "string" or args.root == "" then
            err("glob needs the project root; pass explicit files instead")
        end
        for _, f in ipairs(vim.fn.globpath(args.root, args.glob, true, true)) do
            files[#files + 1] = f
        end
    end
    if #files == 0 then
        err("no files to search: pass files (array of paths) and/or glob")
    end
    if #files > MAX_QUERY_FILES then
        files = vim.list_slice(files, 1, MAX_QUERY_FILES)
    end

    local compiled, first_query_error = {}, nil
    local matches, skipped = {}, {}
    for _, f in ipairs(files) do
        if #matches >= MAX_QUERY_MATCHES then
            break
        end
        local okb, bufnr = pcall(load_buf, f)
        if not okb then
            skipped[#skipped + 1] = f .. " (unreadable)"
        else
            local okp, parser = pcall(vim.treesitter.get_parser, bufnr)
            if not (okp and parser) then
                skipped[#skipped + 1] = f .. " (no treesitter parser)"
            else
                local lang = parser:lang()
                if compiled[lang] == nil then
                    local okq, q = pcall(vim.treesitter.query.parse, lang, qstr)
                    if okq then
                        compiled[lang] = q
                    else
                        compiled[lang] = false
                        first_query_error = first_query_error
                            or ("for language %s: %s"):format(lang, tostring(q))
                    end
                end
                local q = compiled[lang]
                local tree = q and parser:parse()[1] or nil
                if tree then
                    for id, node in q:iter_captures(tree:root(), bufnr) do
                        if #matches >= MAX_QUERY_MATCHES then
                            break
                        end
                        local srow = node:range()
                        local text = vim.treesitter.get_node_text(node, bufnr)
                            :gsub("%s+", " ")
                        if #text > 120 then
                            text = text:sub(1, 120) .. "…"
                        end
                        matches[#matches + 1] = {
                            file = vim.api.nvim_buf_get_name(bufnr),
                            line = srow + 1,
                            capture = q.captures[id],
                            text = text,
                        }
                    end
                end
            end
        end
    end
    if #matches == 0 and first_query_error then
        err("the query does not compile %s. Check node type names against the "
            .. "grammar - the skim tool shows which constructs exist in a file.",
            first_query_error:gsub("\n", " "))
    end
    local res = { count = #matches, matches = matches }
    if #skipped > 0 then
        res.skipped = skipped
    end
    if #matches >= MAX_QUERY_MATCHES then
        res.note = ("truncated at %d matches"):format(MAX_QUERY_MATCHES)
    end
    return res
end

local function skim(args)
    local files = args.files
    if type(files) ~= "table" or #files == 0 then
        err("missing required argument: files (array of paths)")
    end
    if #files > MAX_SKIM_FILES then
        err("too many files: %d (max %d)", #files, MAX_SKIM_FILES)
    end
    local out = {}
    for _, f in ipairs(files) do
        local okb, bufnr = pcall(load_buf, f)
        if not okb then
            out[#out + 1] = { file = f, error = tostring(bufnr) }
        else
            local entry = {
                file = vim.api.nvim_buf_get_name(bufnr),
                total_lines = vim.api.nvim_buf_line_count(bufnr),
            }
            local outline = ts_outline(bufnr)
            if not (outline and #outline > 0) then
                -- No parser (or nothing recognized): try LSP symbols, briefly.
                local okc, client = pcall(get_client, bufnr,
                    "textDocument/documentSymbol", 1500)
                if okc then
                    local okr, syms = pcall(request, client, bufnr,
                        "textDocument/documentSymbol",
                        { textDocument = { uri = vim.uri_from_bufnr(bufnr) } })
                    if okr then
                        outline = flatten_symbols(syms, 0, {}, bufnr)
                    end
                end
            end
            if outline and #outline > 0 then
                entry.outline = outline
            else
                entry.note = "no outline available for this file; read it instead"
            end
            out[#out + 1] = entry
        end
    end
    return { files = out }
end

-- Workspace map: the whole repo's shape in one cheap call - every project
-- file with its line count and TOP-LEVEL declarations only. Parses straight
-- from disk with string parsers, so no buffers are created and no language
-- servers attach; files without a parser are listed with name and size only.
local MAX_MAP_FILES = 200
local MAX_MAP_ENTRIES = 400

local function top_level_outline(path, budget)
    local ok, lines = pcall(vim.fn.readfile, path)
    if not ok or #lines == 0 then
        return nil, 0
    end
    local ft = vim.filetype.match({ filename = path, contents = lines })
    if not ft then
        return nil, #lines
    end
    local lang = vim.treesitter.language.get_lang(ft) or ft
    local okp, parser = pcall(vim.treesitter.get_string_parser,
        table.concat(lines, "\n"), lang)
    if not okp or not parser then
        return nil, #lines
    end
    local okt, trees = pcall(function() return parser:parse() end)
    if not okt or not trees or not trees[1] then
        return nil, #lines
    end
    local out = {}
    -- Emit declaration-shaped nodes but never descend into them: only the
    -- top level of each file, which is what a first look needs.
    local function walk(node)
        for child in node:iter_children() do
            if #out >= budget then
                return
            end
            if child:named() then
                if ts_wanted(child:type()) then
                    local srow = child:range()
                    local text = (lines[srow + 1] or ""):gsub("^%s+", "")
                    if #text > 100 then
                        text = text:sub(1, 100) .. "…"
                    end
                    out[#out + 1] = ("%d: %s"):format(srow + 1, text)
                else
                    walk(child)
                end
            end
        end
    end
    walk(trees[1]:root())
    return out, #lines
end

local function workspace_map(args)
    local root = args.root
    if type(root) ~= "string" or root == "" then
        err("missing project root")
    end
    local target = root
    if type(args.path) == "string" and args.path ~= "" then
        target = args.path:sub(1, 1) == "/" and args.path or (root .. "/" .. args.path)
    end
    local files = vim.fn.systemlist({ "git", "-C", target,
        "ls-files", "--cached", "--others", "--exclude-standard" })
    if vim.v.shell_error ~= 0 then
        files = {}
        for _, f in ipairs(vim.fn.globpath(target, "**/*", true, true)) do
            if vim.fn.isdirectory(f) == 0 then
                files[#files + 1] = f:sub(#target + 2)
            end
        end
    end
    if type(args.glob) == "string" and args.glob ~= "" then
        local re = vim.regex(vim.fn.glob2regpat(args.glob))
        files = vim.tbl_filter(function(f)
            return re:match_str(f) ~= nil
        end, files)
    end
    local total_files = #files
    local out, entries = {}, 0
    for i, rel in ipairs(files) do
        if i > MAX_MAP_FILES then
            break
        end
        if i % 10 == 0 then
            sleep(0) -- yield so the editor stays responsive on big repos
        end
        local entry = { file = rel }
        local outline, nlines = top_level_outline(target .. "/" .. rel,
            MAX_MAP_ENTRIES - entries)
        entry.lines = nlines
        if outline and #outline > 0 and entries < MAX_MAP_ENTRIES then
            entry.outline = outline
            entries = entries + #outline
        end
        out[#out + 1] = entry
    end
    local note
    if total_files > MAX_MAP_FILES then
        note = ("showing first %d of %d files; narrow with path or glob")
            :format(MAX_MAP_FILES, total_files)
    elseif entries >= MAX_MAP_ENTRIES then
        note = "outline budget exhausted; later files are listed without outlines"
    end
    return { file_count = total_files, files = out, note = note }
end

local function hover(args)
    local bufnr = load_buf(args.file)
    local client = get_client(bufnr, "textDocument/hover")
    local result = request(client, bufnr, "textDocument/hover",
        position_params(bufnr, client, args))
    if not (result and result.contents) then
        return { hover = nil, note = "no hover information at this position" }
    end
    local lines = vim.lsp.util.convert_input_to_markdown_lines(result.contents)
    return { hover = table.concat(lines, "\n") }
end

local function document_symbols(args)
    local bufnr = load_buf(args.file)
    local client = get_client(bufnr, "textDocument/documentSymbol")
    local result = request(client, bufnr, "textDocument/documentSymbol",
        { textDocument = { uri = vim.uri_from_bufnr(bufnr) } })
    return { outline = flatten_symbols(result, 0, {}, bufnr) }
end

local function workspace_symbols(args)
    local query = args.query
    if type(query) ~= "string" then
        err("missing required argument: query")
    end
    local out, seen_client = {}, false
    for _, client in ipairs(vim.lsp.get_clients()) do
        if client:supports_method("workspace/symbol") then
            local bufnr = next(client.attached_buffers or {})
            if bufnr then
                seen_client = true
                local result = request(client, bufnr, "workspace/symbol", { query = query })
                for _, s in ipairs(result or {}) do
                    if #out >= MAX_LOCATIONS then break end
                    local loc = s.location or {}
                    out[#out + 1] = {
                        name = s.name,
                        kind = symbol_kind(s.kind),
                        file = loc.uri and vim.uri_to_fname(loc.uri) or nil,
                        line = loc.range and (loc.range.start.line + 1) or nil,
                        container = s.containerName,
                        server = client.name,
                    }
                end
            end
        end
    end
    if not seen_client then
        err("no active LSP client supports workspace/symbol")
    end
    return { count = #out, symbols = out }
end

-- Titles of the code actions available for one diagnostic, so the agent
-- knows when the language server can fix a problem itself.
local function quick_fix_titles(bufnr, client, d)
    local lsp_diags = {}
    pcall(function()
        lsp_diags = vim.lsp.diagnostic.from({ d })
    end)
    local ok, actions = pcall(request, client, bufnr, "textDocument/codeAction", {
        textDocument = { uri = vim.uri_from_bufnr(bufnr) },
        range = {
            start = { line = d.lnum, character = d.col or 0 },
            ["end"] = { line = d.end_lnum or d.lnum, character = d.end_col or (d.col or 0) },
        },
        context = { diagnostics = lsp_diags, triggerKind = 1 },
    })
    if not ok or not actions or #actions == 0 then
        return nil
    end
    local titles = {}
    for i, a in ipairs(actions) do
        if i > 3 then break end
        titles[i] = a.title
    end
    return titles
end

local function diagnostics(args)
    local bufnr = load_buf(args.file)
    -- Give a freshly attached server a moment to publish.
    get_client(bufnr, "textDocument/didOpen")
    local deadline = vim.uv.now() + 1000
    while #vim.diagnostic.get(bufnr) == 0 and vim.uv.now() < deadline do
        sleep(100)
    end
    local okc, action_client = pcall(get_client, bufnr, "textDocument/codeAction", 1000)
    local out = {}
    for i, d in ipairs(vim.diagnostic.get(bufnr)) do
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
    return {
        count = #out,
        diagnostics = out,
        note = #out > 0
            and "quick_fixes lists code actions the language server can apply for you: "
            .. "use code_actions + apply_code_action at that line instead of editing by hand"
            or nil,
    }
end

-- Fresh diagnostics right after an edit, returned inside the edit tool's
-- own result so problems surface without an extra round.
local function post_edit_diagnostics(bufnr)
    sleep(700)
    local out = {}
    for _, d in ipairs(vim.diagnostic.get(bufnr)) do
        if d.severity <= vim.diagnostic.severity.WARN then
            out[#out + 1] = ("%s line %d: %s"):format(
                vim.diagnostic.severity[d.severity], d.lnum + 1, d.message)
            if #out >= 10 then break end
        end
    end
    if #out == 0 then
        return nil
    end
    return out
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

-- Code actions come in two steps: list them (returns a token), then apply
-- one by token + index. The raw actions are cached editor-side because
-- applying needs the original LSP objects, which the model must not edit.
local action_cache = {}
local action_token = 0

local function code_actions(args)
    local bufnr = load_buf(args.file)
    local client = get_client(bufnr, "textDocument/codeAction")
    local pos = make_position(bufnr, client, args.line, args.symbol, args.col)
    local lsp_diags = {}
    pcall(function()
        lsp_diags = vim.lsp.diagnostic.from(
            vim.diagnostic.get(bufnr, { lnum = pos.line }))
    end)
    local result = request(client, bufnr, "textDocument/codeAction", {
        textDocument = { uri = vim.uri_from_bufnr(bufnr) },
        range = { start = pos, ["end"] = pos },
        context = { diagnostics = lsp_diags, triggerKind = 1 },
    }) or {}
    action_token = action_token + 1
    local token = tostring(action_token)
    action_cache[token] = { client_id = client.id, bufnr = bufnr, actions = result }
    local out = {}
    for i, a in ipairs(result) do
        out[i] = {
            index = i,
            title = a.title,
            kind = a.kind,
            preferred = a.isPreferred or nil,
        }
    end
    return {
        token = token,
        actions = out,
        note = #out == 0 and "no code actions available at this position" or nil,
    }
end

local function apply_code_action(args)
    local entry = action_cache[tostring(args.token)]
    if not entry then
        err("unknown or expired code-action token: %s", tostring(args.token))
    end
    local action = entry.actions[tonumber(args.index) or -1]
    if not action then
        err("no code action with index %s under this token", tostring(args.index))
    end
    local client = vim.lsp.get_client_by_id(entry.client_id)
    if not client then
        err("the LSP client that offered this action is gone")
    end
    if not action.edit and not action.command
        and client:supports_method("codeAction/resolve") then
        local ok, resolved = pcall(request, client, entry.bufnr, "codeAction/resolve", action)
        if ok and resolved then
            action = resolved
        end
    end
    local changed = {}
    if action.edit then
        for uri in pairs(action.edit.changes or {}) do
            changed[#changed + 1] = vim.uri_to_fname(uri)
        end
        for _, dc in ipairs(action.edit.documentChanges or {}) do
            if dc.textDocument then
                changed[#changed + 1] = vim.uri_to_fname(dc.textDocument.uri)
            end
        end
        vim.lsp.util.apply_workspace_edit(action.edit, client.offset_encoding)
    end
    if action.command then
        local cmd = type(action.command) == "table" and action.command or action
        client:exec_cmd(cmd, { bufnr = entry.bufnr })
    end
    action_cache[tostring(args.token)] = nil
    return {
        applied = action.title,
        changed_files = changed,
        note = "changes live in editor buffers (unsaved); use buffer_lines to inspect them",
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

local index_cache = {}

local function ts_node_name(node, bufnr)
    local name_field = node:field("name")
    if name_field and name_field[1] then
        return vim.treesitter.get_node_text(name_field[1], bufnr)
    end
    local srow = node:range()
    local line = vim.api.nvim_buf_get_lines(bufnr, srow, srow + 1, false)[1] or ""
    return line:match("([%w_.:]+)%s*%(") or line:match("([%w_.:]+)%s*[={:]")
        or ("line" .. (srow + 1))
end

local function ts_index(bufnr)
    local ok, parser = pcall(vim.treesitter.get_parser, bufnr)
    if not ok or parser == nil then
        return nil
    end
    local okp, trees = pcall(function() return parser:parse() end)
    if not okp or not trees or not trees[1] then
        return nil
    end
    local entries = {}
    local function walk(node, prefix)
        for child in node:iter_children() do
            if child:named() then
                if ts_wanted(child:type()) then
                    local srow, _, erow = child:range()
                    local name = ts_node_name(child, bufnr)
                    local path = prefix == "" and name or (prefix .. "/" .. name)
                    entries[#entries + 1] = {
                        path = path, name = name, kind = child:type(),
                        first = srow + 1, last = erow + 1,
                    }
                    walk(child, path)
                else
                    walk(child, prefix)
                end
            end
        end
    end
    walk(trees[1]:root(), "")
    return entries
end

local function lsp_index(bufnr)
    local okc, client = pcall(get_client, bufnr, "textDocument/documentSymbol", 2000)
    if not okc then
        return nil
    end
    local okr, syms = pcall(request, client, bufnr, "textDocument/documentSymbol",
        { textDocument = { uri = vim.uri_from_bufnr(bufnr) } })
    if not okr then
        return nil
    end
    local entries = {}
    local function walk(list, prefix)
        for _, s in ipairs(list or {}) do
            local range = s.range or (s.location and s.location.range)
            if range then
                local path = prefix == "" and s.name or (prefix .. "/" .. s.name)
                entries[#entries + 1] = {
                    path = path, name = s.name, kind = symbol_kind(s.kind),
                    first = range.start.line + 1, last = range["end"].line + 1,
                }
                walk(s.children, path)
            end
        end
    end
    walk(syms, "")
    return entries
end

local function symbol_index(bufnr)
    local tick = vim.api.nvim_buf_get_changedtick(bufnr)
    local cached = index_cache[bufnr]
    if cached and cached.tick == tick then
        return cached.entries
    end
    local entries = ts_index(bufnr)
    if not entries or #entries == 0 then
        entries = lsp_index(bufnr) or {}
    end
    index_cache[bufnr] = { tick = tick, entries = entries }
    return entries
end

local function innermost_path(entries, line)
    local best
    for _, e in ipairs(entries) do
        if e.first <= line and line <= e.last then
            if not best or (e.last - e.first) < (best.last - best.first) then
                best = e
            end
        end
    end
    return best and best.path or nil
end

-- annotate_locations is defined after the enclosing-symbol helpers below;
-- forward local so the references dispatch entry can close over it.
local annotate_locations

-- Rank: 1 exact path, 2 path suffix / exact name, 3 name substring.
local function match_rank(entry, name)
    if entry.path == name then
        return 1
    end
    local n = #name
    if #entry.path > n and entry.path:sub(-n) == name
        and entry.path:sub(-n - 1, -n - 1) == "/" then
        return 2
    end
    if entry.name == name then
        return 2
    end
    if entry.name:lower():find(name:lower(), 1, true) then
        return 3
    end
    return nil
end

local MAX_FIND_RESULTS = 20
local MAX_BODY_LINES = 200

-- Body lines are numbered RELATIVE to the symbol (declaration = 1), matching
-- the addressing of replace_symbol_lines; the absolute file range is in the
-- accompanying `lines` field.
local function symbol_body(bufnr, entry)
    local last = math.min(entry.last, entry.first + MAX_BODY_LINES - 1)
    local lines = vim.api.nvim_buf_get_lines(bufnr, entry.first - 1, last, false)
    local numbered = {}
    for i, l in ipairs(lines) do
        numbered[i] = ("%d: %s"):format(i, l)
    end
    if last < entry.last then
        numbered[#numbered + 1] = ("... (truncated; the symbol has %d lines)")
            :format(entry.last - entry.first + 1)
    end
    return numbered
end

local function find_symbol(args)
    local name = args.name
    if type(name) ~= "string" or name == "" then
        err("missing required argument: name")
    end
    local files = {}
    if type(args.file) == "string" and args.file ~= "" then
        files[#files + 1] = args.file
    end
    for _, f in ipairs(args.files or {}) do
        files[#files + 1] = f
    end
    if type(args.glob) == "string" and args.glob ~= "" then
        if type(args.root) ~= "string" or args.root == "" then
            err("glob needs the project root; pass explicit files instead")
        end
        vim.list_extend(files, vim.fn.globpath(args.root, args.glob, true, true))
    end
    if #files == 0 then
        err("no files to search: pass file, files, or glob")
    end
    if #files > MAX_QUERY_FILES then
        files = vim.list_slice(files, 1, MAX_QUERY_FILES)
    end
    local found = {}
    for _, f in ipairs(files) do
        local okb, bufnr = pcall(load_buf, f)
        if okb then
            for _, entry in ipairs(symbol_index(bufnr)) do
                local rank = match_rank(entry, name)
                if rank then
                    found[#found + 1] = { rank = rank, bufnr = bufnr, entry = entry }
                end
            end
        end
    end
    table.sort(found, function(a, b) return a.rank < b.rank end)
    local out = {}
    for i, m in ipairs(found) do
        if i > MAX_FIND_RESULTS then break end
        local item = {
            name_path = m.entry.path,
            kind = m.entry.kind,
            file = vim.api.nvim_buf_get_name(m.bufnr),
            lines = ("%d-%d"):format(m.entry.first, m.entry.last),
        }
        if args.include_body and m.rank <= 2 and i <= 5 then
            item.body = symbol_body(m.bufnr, m.entry)
            if i == 1 then
                pcall(function()
                    require("agent99.ui").on_read(item.file, m.entry.first)
                end)
            end
        end
        out[i] = item
    end
    return {
        count = #found,
        matches = out,
        note = #found == 0 and "no symbol matched; try skim to see what exists" or nil,
    }
end

-- Resolve one unambiguous symbol for an edit.
local function resolve_symbol(file, name_path)
    if type(name_path) ~= "string" or name_path == "" then
        err("missing required argument: name_path")
    end
    local bufnr = load_buf(file)
    local candidates = {}
    for _, entry in ipairs(symbol_index(bufnr)) do
        local rank = match_rank(entry, name_path)
        if rank and rank <= 2 then
            candidates[#candidates + 1] = { rank = rank, entry = entry }
        end
    end
    table.sort(candidates, function(a, b) return a.rank < b.rank end)
    if #candidates == 0 then
        err("no symbol named %q in %s; use find_symbol or skim to locate it",
            name_path, file)
    end
    if #candidates > 1 and candidates[1].rank == candidates[2].rank then
        local names = {}
        for i, c in ipairs(candidates) do
            if i > 5 then break end
            names[#names + 1] = c.entry.path
        end
        err("ambiguous symbol %q in %s: %s - use the full name path",
            name_path, file, table.concat(names, ", "))
    end
    return bufnr, candidates[1].entry
end

local function record_edit(bufnr, entry_path, kind, first, last, old_lines, new_lines)
    require("agent99.edits").record({
        file = vim.api.nvim_buf_get_name(bufnr),
        bufnr = bufnr,
        name_path = entry_path,
        kind = kind,
        first = first,
        last = last,
        old_lines = old_lines,
        new_lines = new_lines,
        new_count = #new_lines,
    })
end

local function replace_symbol_body(args)
    local bufnr, entry = resolve_symbol(args.file, args.name_path)
    if type(args.body) ~= "string" then
        err("missing required argument: body")
    end
    local new_lines = vim.split((args.body:gsub("\n+$", "")), "\n", { plain = true })
    local old = vim.api.nvim_buf_get_lines(bufnr, entry.first - 1, entry.last, false)
    vim.api.nvim_buf_set_lines(bufnr, entry.first - 1, entry.last, false, new_lines)
    record_edit(bufnr, entry.path, "replace", entry.first, entry.last, old, new_lines)
    return {
        replaced = entry.path,
        file = vim.api.nvim_buf_get_name(bufnr),
        lines = ("%d-%d"):format(entry.first, entry.first + #new_lines - 1),
        note = "applied to the editor buffer (unsaved)",
        diagnostics_after = post_edit_diagnostics(bufnr),
    }
end

-- Edit a slice of a symbol, addressed by line numbers RELATIVE to the
-- symbol's first line (declaration = 1) - the numbering find_symbol bodies
-- use. Much cheaper than resending the whole symbol for a small change.
local function replace_symbol_lines(args)
    local bufnr, entry = resolve_symbol(args.file, args.name_path)
    local span = entry.last - entry.first + 1
    local first = tonumber(args.first_line)
    local last = tonumber(args.last_line)
    if not first or not last then
        err("missing required arguments: first_line and last_line (relative to the symbol)")
    end
    if first < 1 or last < first or last > span then
        err("lines %s-%s are outside the symbol %s, which has %d lines (1-%d relative)",
            tostring(first), tostring(last), entry.path, span, span)
    end
    if type(args.text) ~= "string" then
        err("missing required argument: text")
    end
    local abs_first = entry.first + first - 1
    local abs_last = entry.first + last - 1
    local new_lines = vim.split((args.text:gsub("\n+$", "")), "\n", { plain = true })
    local old = vim.api.nvim_buf_get_lines(bufnr, abs_first - 1, abs_last, false)
    vim.api.nvim_buf_set_lines(bufnr, abs_first - 1, abs_last, false, new_lines)
    record_edit(bufnr, ("%s:%d-%d"):format(entry.path, first, last), "replace_lines",
        abs_first, abs_last, old, new_lines)
    return {
        replaced = ("lines %d-%d of %s"):format(first, last, entry.path),
        file = vim.api.nvim_buf_get_name(bufnr),
        lines = ("%d-%d"):format(abs_first, abs_first + #new_lines - 1),
        note = "applied to the editor buffer (unsaved)",
        diagnostics_after = post_edit_diagnostics(bufnr),
    }
end

local function insert_symbol_tool(where)
    return function(args)
        local bufnr, entry = resolve_symbol(args.file, args.name_path)
        if type(args.text) ~= "string" or args.text == "" then
            err("missing required argument: text")
        end
        local lines = vim.split((args.text:gsub("\n+$", "")), "\n", { plain = true })
        local row -- 0-based insertion point
        if where == "after" then
            row = entry.last
            table.insert(lines, 1, "")
        else
            row = entry.first - 1
            table.insert(lines, "")
        end
        vim.api.nvim_buf_set_lines(bufnr, row, row, false, lines)
        record_edit(bufnr, entry.path, "insert_" .. where, row + 1, row, {}, lines)
        return {
            inserted = ("%s %s"):format(where, entry.path),
            file = vim.api.nvim_buf_get_name(bufnr),
            lines = ("%d-%d"):format(row + 1, row + #lines),
            note = "applied to the editor buffer (unsaved)",
            diagnostics_after = post_edit_diagnostics(bufnr),
        }
    end
end

-- First line of the contiguous comment block directly above a line, for
-- surfacing a symbol's doc summary. Language-agnostic prefix heuristic.
local function comment_above(bufnr, lnum)
    local first_comment
    for l = lnum - 1, math.max(1, lnum - 8), -1 do
        local text = vim.api.nvim_buf_get_lines(bufnr, l - 1, l, false)[1] or ""
        local stripped = text:gsub("^%s+", "")
        if stripped:match("^%-%-") or stripped:match("^//") or stripped:match("^#")
            or stripped:match("^/%*") or stripped:match("^%*") or stripped:match('^"""') then
            first_comment = stripped
        else
            break
        end
    end
    if first_comment and #first_comment > 90 then
        first_comment = first_comment:sub(1, 90) .. "…"
    end
    return first_comment
end

-- Control-flow nesting depth of a line inside its enclosing symbol: how many
-- loops/branches the line sits under. Segment-matched like ts_wanted.
local DEPTH_SEGMENTS = {
    ["for"] = true, ["while"] = true, ["repeat"] = true, loop = true,
    ["if"] = true, elseif_ = true, switch = true, case = true,
    match = true, try = true,
}

local function control_depth(bufnr, line, sym_first)
    local ok, parser = pcall(vim.treesitter.get_parser, bufnr)
    if not ok or parser == nil then
        return nil
    end
    local okp, trees = pcall(function() return parser:parse() end)
    if not okp or not trees or not trees[1] then
        return nil
    end
    local node = trees[1]:root():descendant_for_range(line - 1, 0, line - 1, 0)
    local depth = 0
    while node do
        local srow = node:range()
        if srow < sym_first - 1 then
            break -- left the enclosing symbol
        end
        for segment in node:type():gmatch("[^_]+") do
            if DEPTH_SEGMENTS[segment] then
                depth = depth + 1
                break
            end
        end
        node = node:parent()
    end
    return depth
end

local function innermost_entry(entries, line)
    local best
    for _, e in ipairs(entries) do
        if e.first <= line and line <= e.last then
            if not best or (e.last - e.first) < (best.last - best.first) then
                best = e
            end
        end
    end
    return best
end

-- Classify what a hit at (line, col) actually is: the definition line of its
-- symbol, the callee of a call, or text inside a comment or string literal.
-- nil (no tag) means a plain code reference.
local function classify_hit(bufnr, line, col, entry)
    if entry and entry.first == line then
        return "def"
    end
    local ok, parser = pcall(vim.treesitter.get_parser, bufnr)
    if not ok or parser == nil then
        return nil
    end
    local okp, trees = pcall(function() return parser:parse() end)
    if not okp or not trees or not trees[1] then
        return nil
    end
    local c = math.max((tonumber(col) or 1) - 1, 0)
    local node = trees[1]:root():descendant_for_range(line - 1, c, line - 1, c)
    if not node then
        return nil
    end
    local n = node
    while n do
        local t = n:type()
        if t:find("comment", 1, true) then
            return "comment"
        end
        if t:find("string", 1, true) then
            return "string"
        end
        n = n:parent()
    end
    n = node
    for _ = 1, 4 do
        local p = n and n:parent()
        if not p then
            break
        end
        for segment in p:type():gmatch("[^_]+") do
            if segment == "call" or segment == "invocation" then
                local callee = (p:field("function") or {})[1] or (p:field("name") or {})[1]
                if callee and (callee == node
                    or vim.treesitter.is_ancestor(callee, node)) then
                    return "call"
                end
            end
        end
        n = p
    end
    return nil
end

-- Worst diagnostic severity already present on a line (ERROR/WARN or nil).
local function line_diag(bufnr, line)
    local worst
    for _, d in ipairs(vim.diagnostic.get(bufnr, { lnum = line - 1 })) do
        if d.severity == vim.diagnostic.severity.ERROR then
            return "ERROR"
        end
        if d.severity == vim.diagnostic.severity.WARN then
            worst = "WARN"
        end
    end
    return worst
end

-- Internal (not in the model's tool list): line -> enclosing symbol info
-- (name path, declaration line = signature, doc comment summary, position,
-- nesting depth, hit kind, existing diagnostics), used by the bridge to
-- annotate grep hits. args.cols is optional, aligned with args.lines.
local function enclosing_symbols(args)
    local bufnr = load_buf(args.file)
    local entries = symbol_index(bufnr)
    local out = {}
    for i, line in ipairs(args.lines or {}) do
        local n = tonumber(line)
        local e = innermost_entry(entries, n)
        if e then
            out[tostring(line)] = {
                path = e.path,
                decl = decl_line(bufnr, e.first),
                comment = comment_above(bufnr, e.first),
                first = e.first,
                pos = n - e.first + 1,
                span = e.last - e.first + 1,
                depth = control_depth(bufnr, n, e.first),
                kind = classify_hit(bufnr, n, (args.cols or {})[i], e),
                diag = line_diag(bufnr, n),
            }
        end
    end
    return { symbols = out }
end

-- Attach enclosing-symbol context to each location (used by references):
-- symbol path, position within it, nesting depth, and - once per symbol -
-- its declaration line.
function annotate_locations(locations)
    local per_file, order = {}, {}
    for _, loc in ipairs(locations) do
        if not per_file[loc.file] then
            per_file[loc.file] = {}
            order[#order + 1] = loc.file
        end
        table.insert(per_file[loc.file], loc)
    end
    local seen = {}
    for i, file in ipairs(order) do
        if i > 10 then break end
        local okb, bufnr = pcall(load_buf, file)
        if okb then
            local entries = symbol_index(bufnr)
            for _, loc in ipairs(per_file[file]) do
                local e = innermost_entry(entries, loc.line)
                if e then
                    loc.in_symbol = e.path
                    if e.last > e.first then
                        loc.at = ("%d/%d"):format(loc.line - e.first + 1, e.last - e.first + 1)
                    end
                    local d = control_depth(bufnr, loc.line, e.first)
                    if d and d > 0 then
                        loc.depth = d
                    end
                    local key = file .. "|" .. e.path
                    if not seen[key] and e.first ~= loc.line then
                        seen[key] = true
                        loc.decl = decl_line(bufnr, e.first)
                    end
                end
            end
        end
    end
end

local dispatch_table = {
    definition = location_tool("textDocument/definition"),
    type_definition = location_tool("textDocument/typeDefinition"),
    implementation = location_tool("textDocument/implementation"),
    references = function(args)
        local result = location_tool("textDocument/references",
            { context = { includeDeclaration = true } })(args)
        annotate_locations(result.locations or {})
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
    ts_query = ts_query,
    find_symbol = find_symbol,
    replace_symbol_body = replace_symbol_body,
    replace_symbol_lines = replace_symbol_lines,
    insert_after_symbol = insert_symbol_tool("after"),
    insert_before_symbol = insert_symbol_tool("before"),
    enclosing_symbols = enclosing_symbols,
    -- Internal: the bridge reports a disk read so the code window can follow.
    ui_follow = function(args)
        pcall(function()
            require("agent99.ui").on_read(args.file, tonumber(args.line) or 1)
        end)
        return { ok = true }
    end,
}

function M.dispatch(tool, args)
    local fn = dispatch_table[tool]
    if not fn then
        err("unknown tool: %s", tostring(tool))
    end
    return fn(args or {})
end

return M
