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
local err, await, sleep = core.err, core.await, core.sleep
local load_buf, rel_path, fresh_buf = core.load_buf, core.rel_path, core.fresh_buf
local get_client, request, resync_open_buffers = core.get_client, core.request, core.resync_open_buffers
local position_params, line_preview, decl_line = core.position_params, core.line_preview, core.decl_line
local REQUEST_TIMEOUT_MS, MAX_LOCATIONS, FRESH_RETRY_MS = core.REQUEST_TIMEOUT_MS, core.MAX_LOCATIONS,
    core.FRESH_RETRY_MS

local index = require("agent99.index")
local symbol_kind, ts_outline, symbol_index = index.symbol_kind, index.ts_outline, index.symbol_index
local resolve_symbol, innermost_entry, annotate_locations = index.resolve_symbol, index.innermost_entry,
    index.annotate_locations
local skim, workspace_map, document_symbols = index.skim, index.workspace_map, index.document_symbols
local workspace_symbols, ts_query, find_symbol = index.workspace_symbols, index.ts_query, index.find_symbol
local enclosing_symbols = index.enclosing_symbols

local edit = require("agent99.edit")
local code_actions, apply_code_action = edit.code_actions, edit.apply_code_action
local replace_symbol_body, replace_symbol_lines = edit.replace_symbol_body, edit.replace_symbol_lines
local insert_symbol_tool, undo_edit, rename_symbol = edit.insert_symbol_tool, edit.undo_edit, edit.rename_symbol
local create_file, move_file, delete_file, move_symbols = edit.create_file, edit.move_file, edit.delete_file,
    edit.move_symbols

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
    return { hover = text }
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
    for _, a in ipairs(actions) do
        -- lua_ls and friends offer "Disable diagnostics ..." actions; those
        -- silence the problem instead of fixing it and must not be sold to
        -- the model as quick fixes.
        if not a.title:find("^Disable diagnostics") and not a.title:find("^Ignore ") then
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
    -- Same reason as before an edit: a file changed by another tool is stale
    -- in the server until it is told, and this file's diagnostics may depend
    -- on it.
    if #resync_open_buffers() > 0 then
        sleep(300)
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
    return {
        count = total,
        diagnostics = out,
        note = total > 0
            and "quick_fixes lists code actions the language server can apply for you: "
            .. "call code_actions with this file and line (the col above is optional), "
            .. "then apply_code_action, instead of editing by hand"
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
    workspace_support = workspace_support,
    install_language = install_language,
    ts_query = ts_query,
    find_symbol = find_symbol,
    replace_symbol_body = replace_symbol_body,
    replace_symbol_lines = replace_symbol_lines,
    insert_after_symbol = insert_symbol_tool("after"),
    insert_before_symbol = insert_symbol_tool("before"),
    undo_edit = undo_edit,
    rename_symbol = rename_symbol,
    create_file = create_file,
    move_file = move_file,
    delete_file = delete_file,
    move_symbols = move_symbols,
    check_project = check_project,
    enclosing_symbols = enclosing_symbols,
    -- Internal: the bridge reports a disk read so the code window can follow.
    ui_follow = function(args)
        pcall(function()
            require("agent99.ui").on_read(args.file, tonumber(args.line) or 1)
        end)
        return { ok = true }
    end,
}

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
    if tool ~= "ui_follow" and tool ~= "enclosing_symbols" then
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
