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
local get_client, request, client_for = core.get_client, core.request, core.client_for
local make_position, position_params, line_preview = core.make_position, core.position_params, core.line_preview
local decl_line, expand_glob, has_parser = core.decl_line, core.expand_glob, core.has_parser
local project_files, enabled_lsp_configs_for = core.project_files, core.enabled_lsp_configs_for
local is_test_path, better_sample, write_buf = core.is_test_path, core.better_sample, core.write_buf
local disk_fingerprint, sync_buf, notify_changed_files = core.disk_fingerprint, core.sync_buf, core.notify_changed_files
local resync_open_buffers = core.resync_open_buffers
local REQUEST_TIMEOUT_MS, MAX_LOCATIONS, FRESH_RETRY_MS = core.REQUEST_TIMEOUT_MS, core.MAX_LOCATIONS,
    core.FRESH_RETRY_MS
local DATA_FILETYPES, ATTACH_TIMEOUT_MS = core.DATA_FILETYPES, core.ATTACH_TIMEOUT_MS
local index = require("agent99.index")
local symbol_kind, ts_outline, symbol_index = index.symbol_kind, index.ts_outline, index.symbol_index
local resolve_symbol, symbol_body, innermost_entry = index.resolve_symbol, index.symbol_body, index.innermost_entry
local doc_block_start, decl_block_top, annotate_locations = index.doc_block_start, index.decl_block_top,
    index.annotate_locations
local match_rank, control_depth, comment_above = index.match_rank, index.control_depth, index.comment_above
local skim, workspace_map, document_symbols = index.skim, index.workspace_map, index.document_symbols
local workspace_symbols, ts_query, find_symbol = index.workspace_symbols, index.ts_query, index.find_symbol
local enclosing_symbols, MAX_BODY_LINES = index.enclosing_symbols, index.MAX_BODY_LINES

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

-- Fresh diagnostics right after an edit, returned inside the edit tool's
-- own result so problems surface without an extra round.
-- Post-edit report. Before the edit, diag_snapshot() records every error
-- and warning (all buffers) keyed by file, severity and message - not by
-- line, so an edit that shifts code does not make old problems look new.
-- After the edit, post_edit_report() waits for the servers to re-publish,
-- optionally runs linters, then splits what it sees into new, fixed and
-- pre-existing, so the model reads what its edit caused and nothing else.
local function post_edit_options()
    local ok, config = pcall(require, "agent99.config")
    local opts = ok and config.options and config.options.post_edit
    return vim.tbl_deep_extend("force", {
        wait_ms = 4000,
        commands = {},
        nvim_lint = true,
        lint_timeout_ms = 30000,
        format = "range",
        organize_imports = true,
    }, opts or {})
end

-- Servers whose only formatting is whole-file and canonical (gofmt), so
-- formatting the file after an edit never produces an unrelated diff.
local FILE_FORMAT_OK = { go = true }


-- Run the server's source.organizeImports action on the buffer. Returns
-- true when an action was applied.
local function organize_imports(bufnr)
    local client = client_for(bufnr, "textDocument/codeAction")
    if not client then return false end
    local last = vim.api.nvim_buf_line_count(bufnr)
    local ok, actions = pcall(request, client, bufnr, "textDocument/codeAction", {
        textDocument = { uri = vim.uri_from_bufnr(bufnr) },
        range = { start = { line = 0, character = 0 }, ["end"] = { line = last, character = 0 } },
        context = { diagnostics = {}, only = { "source.organizeImports" }, triggerKind = 1 },
    })
    if not ok or type(actions) ~= "table" or #actions == 0 then return false end
    -- Take only an action that is what was asked for. A server that ignores
    -- `only` (or adds its fix-all) would otherwise have its first action
    -- applied blind, and tsserver's fixes include "add missing function
    -- declaration", which appends a throwing stub for an unresolved name:
    -- code nobody wrote, added silently after an edit.
    local action
    for _, a in ipairs(actions) do
        if type(a.kind) == "string" and a.kind:find("^source%.organizeImports") then
            action = a
            break
        end
    end
    if not action then return false end
    if not action.edit and not action.command and client:supports_method("codeAction/resolve") then
        local okr, resolved = pcall(request, client, bufnr, "codeAction/resolve", action)
        if okr and resolved then action = resolved end
    end
    local applied = false
    if action.edit then
        pcall(vim.lsp.util.apply_workspace_edit, action.edit, client.offset_encoding)
        applied = true
    end
    if action.command then
        local cmd = type(action.command) == "table" and action.command or action
        pcall(function() client:exec_cmd(cmd, { bufnr = bufnr }) end)
        applied = true
    end
    return applied
end

-- The file's own indentation (majority of indented lines: tabs or spaces,
-- and the smallest space step), so formatting matches the code around the
-- edit rather than the headless instance's buffer defaults.
local function detect_indent(bufnr)
    -- An .editorconfig that actually declares an indent style is the
    -- project's own answer. The `vim.b.editorconfig` table is present even
    -- when nothing matched, so trust it only when it names indent_style;
    -- otherwise sniff the file, because shiftwidth is Neovim's default, not
    -- the project's.
    local ec = vim.b[bufnr].editorconfig
    if type(ec) == "table" and ec.indent_style then
        if ec.indent_style == "tab" then
            return {
                insertSpaces = false,
                tabSize = tonumber(ec.tab_width or ec.indent_size) or vim.bo[bufnr].tabstop
            }
        end
        return {
            insertSpaces = true,
            tabSize = tonumber(ec.indent_size) or vim.bo[bufnr].shiftwidth
        }
    end
    local tabs, spaces, step = 0, 0, nil
    for _, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, 2000, false)) do
        local ws, first = line:match("^(%s+)(%S)")
        -- A comment continuation line (" * ..." in JSDoc and Javadoc) sits
        -- one column in; counting it makes the unit look like one space, the
        -- "one space per level" bug. Skip it and the odd lone-space line.
        if ws and first ~= "*" then
            if ws:sub(1, 1) == "\t" then
                tabs = tabs + 1
            else
                spaces = spaces + 1
                local n = #ws
                if n > 1 and (not step or n < step) then step = n end
            end
        end
    end
    if tabs == 0 and spaces == 0 then
        local sw = vim.bo[bufnr].shiftwidth
        return {
            insertSpaces = vim.bo[bufnr].expandtab,
            tabSize = sw > 0 and sw or vim.bo[bufnr].tabstop
        }
    end
    if tabs > spaces then
        return { insertSpaces = false, tabSize = vim.bo[bufnr].tabstop }
    end
    return { insertSpaces = true, tabSize = step or 4 }
end
-- Format lines first..last (1-based, inclusive) through the server: range
-- formatting when offered, else whole-file formatting for filetypes where
-- that is canonical. Returns true when edits were applied.
-- Undo the parts of a whole-file format that fall outside the edited region.
--
-- Several servers, gopls among them, offer no range formatting, so the only
-- way to format an edit is to format the document. In a file that was not
-- formatter-clean to begin with - and plenty are - that turns a two-line
-- change into a diff spanning the file, mixing the edit with unrelated
-- reflowing that nobody asked for and a reviewer has to pick apart.
--
-- So the format is applied, then the result is diffed against what was there
-- and every hunk that does not touch the edited lines is put back. The edit
-- comes out formatted; the rest of the file is left exactly as it was found.
-- Returns whether anything survived inside the region.
local function confine_format(bufnr, before_lines, first, last)
    local after_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local hunks = vim.diff(
        table.concat(before_lines, "\n") .. "\n",
        table.concat(after_lines, "\n") .. "\n",
        { result_type = "indices" })
    if type(hunks) ~= "table" or #hunks == 0 then
        return false
    end
    -- Reverted hunk by hunk, bottom upwards, rather than by rewriting the
    -- buffer: the caller tracks the edited region with extmarks, and
    -- replacing every line would move them to the top of the file and make
    -- the edit report claim it had rewritten the whole thing.
    local changed_inside = false
    for i = #hunks, 1, -1 do
        local start_a, count_a, start_b, count_b = hunks[i][1], hunks[i][2], hunks[i][3], hunks[i][4]
        -- A hunk with count_a == 0 is an insertion sitting after old line
        -- start_a, so its footprint in the old text is that one position.
        local from = count_a > 0 and start_a or start_a + 1
        local to = count_a > 0 and (start_a + count_a - 1) or start_a
        if from <= last and to >= first then
            changed_inside = true
        else
            local restored = {}
            for l = start_a, start_a + count_a - 1 do
                restored[#restored + 1] = before_lines[l]
            end
            -- count_b == 0 means the format deleted these lines, so there is
            -- nothing to replace: put them back after new line start_b.
            local at = count_b > 0 and (start_b - 1) or start_b
            local upto = count_b > 0 and (start_b - 1 + count_b) or start_b
            pcall(vim.api.nvim_buf_set_lines, bufnr, at, upto, false, restored)
        end
    end
    return changed_inside
end

local function format_region(bufnr, first, last, mode)
    if mode == "range" or mode == true then
        local client = client_for(bufnr, "textDocument/rangeFormatting")
        if client then
            local ok, edits = pcall(request, client, bufnr, "textDocument/rangeFormatting", {
                textDocument = { uri = vim.uri_from_bufnr(bufnr) },
                range = {
                    start = { line = first - 1, character = 0 },
                    ["end"] = { line = last, character = 0 }
                },
                options = detect_indent(bufnr),
            })
            if ok and type(edits) == "table" and #edits > 0 then
                pcall(vim.lsp.util.apply_text_edits, edits, bufnr, client.offset_encoding)
                return true
            end
            return false
        end
    end
    if mode == "file" or FILE_FORMAT_OK[vim.bo[bufnr].filetype] then
        local client = client_for(bufnr, "textDocument/formatting")
        if not client then return false end
        local ok, edits = pcall(request, client, bufnr, "textDocument/formatting", {
            textDocument = { uri = vim.uri_from_bufnr(bufnr) },
            options = detect_indent(bufnr),
        })
        if ok and type(edits) == "table" and #edits > 0 then
            local before_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            pcall(vim.lsp.util.apply_text_edits, edits, bufnr, client.offset_encoding)
            return confine_format(bufnr, before_lines, first, last)
        end
    end
    return false
end

local polish_ns = vim.api.nvim_create_namespace("agent99_polish")
-- Anchor for a multi-region edit's span: its own namespace, because
-- polish_after_edit clears polish_ns after every region it formats.
local span_ns = vim.api.nvim_create_namespace("agent99_span")
-- After an edit wrote `count` lines at `first`, format that region and
-- organize imports (both optional), then return where the region ended up
-- (imports added above it shift it) plus a list of what was done.
local function polish_after_edit(bufnr, first, count, opts)
    local done = {}
    if not (opts.format or opts.organize_imports) then
        return first, count, done
    end
    if not client_for(bufnr, "textDocument/didOpen") then
        return first, count, done
    end
    local start_row = first - 1
    -- The region's start is tracked by an extmark (imports added above it
    -- move it down); its end is anchored by the untouched tail of the file,
    -- which neither range formatting nor import edits reach.
    local tail = vim.api.nvim_buf_get_lines(bufnr, start_row + count, -1, false)
    local m_start = vim.api.nvim_buf_set_extmark(bufnr, polish_ns, start_row, 0,
        { right_gravity = false })
    if opts.format and count > 0 then
        if format_region(bufnr, first, first + count - 1, opts.format) then
            done[#done + 1] = "formatted"
        end
    end
    if opts.organize_imports then
        if organize_imports(bufnr) then
            done[#done + 1] = "organized imports"
        end
    end
    local s = vim.api.nvim_buf_get_extmark_by_id(bufnr, polish_ns, m_start, {})
    vim.api.nvim_buf_clear_namespace(bufnr, polish_ns, 0, -1)
    local new_total = vim.api.nvim_buf_line_count(bufnr)
    -- A range formatter can reach past the region it was given (lua_ls
    -- drops a blank line after a function that shrank). The part of the
    -- old tail that no longer matches is folded into the edited region,
    -- and handed back so the ledger's "before" covers it too; otherwise an
    -- undo would restore the region and leave the formatter's change.
    local keep = 0
    while keep < #tail and keep < new_total do
        local old_line = tail[#tail - keep]
        local new_line = vim.api.nvim_buf_get_lines(bufnr, new_total - keep - 1, new_total - keep, false)[1]
        if old_line ~= new_line then break end
        keep = keep + 1
    end
    local extra_old = {}
    for i = 1, #tail - keep do extra_old[#extra_old + 1] = tail[i] end
    if s and s[1] then
        local new_first = s[1] + 1
        local new_count = (new_total - keep) - s[1]
        if new_count >= 0 then
            return new_first, new_count, done, extra_old
        end
    end
    return first, count, done, extra_old
end
-- Pre-existing diagnostics in the edited file are listed rather than counted,
-- up to this many; past it the rest become a tally.
local PREEXISTING_LISTED = 10

-- A server saying it cannot analyze this file at all, rather than saying
-- something about the code in it. Usually a build-tag or project-membership
-- problem: the file is real, but it is not in the configuration the server
-- was given, so "no new errors" after an edit means nothing was checked.
local NOT_ANALYZED_PATTERNS = {
    "no packages found",                 -- gopls
    "build constraints exclude all",     -- go build tags
    "is not included in your workspace", -- gopls, outside the module
    "file is not included in tsconfig",  -- tsserver
    "no compile_commands",               -- clangd
}

local function not_analyzed_reason(bufnr)
    for _, d in ipairs(vim.diagnostic.get(bufnr)) do
        local message = (d.message or ""):lower()
        for _, pattern in ipairs(NOT_ANALYZED_PATTERNS) do
            if message:find(pattern, 1, true) then
                -- gopls follows this with several lines of documentation
                -- links; the first line is the whole of the answer.
                return vim.split(d.message, "\n", { plain = true })[1]
            end
        end
    end
    return nil
end

local function diag_signature(d)
    -- Messages that quote their own position ("used in Scan loop at line
    -- 746") would read as a new diagnostic every time an edit above shifts
    -- them; the position is not part of what the diagnostic says.
    local message = (d.message or ""):gsub("%s+", " ")
        :gsub("line %d+", "line N"):gsub(":%d+:%d+", ":N:N")
    return ("%s|%s|%s"):format(vim.api.nvim_buf_get_name(d.bufnr), d.severity, message)
end
local function diag_snapshot()
    local counts = {}
    for _, d in ipairs(vim.diagnostic.get(nil)) do
        if d.severity <= vim.diagnostic.severity.WARN then
            local sig = diag_signature(d)
            counts[sig] = (counts[sig] or 0) + 1
        end
    end
    return counts
end

-- Wait until diagnostics for bufnr change (any server), then a short
-- settle window for servers that publish twice (syntax, then semantic).
-- Returns once nothing has changed for settle_ms or the deadline passes.
local function wait_for_diagnostics(bufnr, wait_ms, settle_ms)
    local deadline = vim.uv.now() + wait_ms
    local last_change = nil
    local group = vim.api.nvim_create_augroup("agent99_post_edit_" .. bufnr, { clear = true })
    vim.api.nvim_create_autocmd("DiagnosticChanged", {
        group = group,
        buffer = bufnr,
        callback = function() last_change = vim.uv.now() end,
    })
    local changed = false
    while vim.uv.now() < deadline do
        if last_change then
            changed = true
            if vim.uv.now() - last_change >= settle_ms then break end
        end
        sleep(100)
    end
    pcall(vim.api.nvim_del_augroup_by_id, group)
    return changed
end

-- Before the first edit in a freshly loaded file, give its server time to
-- attach and publish, or every problem the file already had would be
-- reported as caused by the edit.
local function settle_before_edit(bufnr)
    -- Unconditional: a file changed by another tool is stale in the server
    -- whether or not this buffer is freshly loaded.
    local moved = resync_open_buffers()
    if #moved > 0 then
        -- Give the servers a moment to re-analyze what they were just told
        -- about, or the diagnostics snapshot taken next is the old picture.
        sleep(300)
    end
    if not fresh_buf(bufnr) then return end
    if #vim.lsp.get_clients({ bufnr = bufnr }) == 0
        and #enabled_lsp_configs_for(vim.bo[bufnr].filetype) == 0 then
        return -- nothing will ever attach
    end
    local okc = pcall(get_client, bufnr, "textDocument/didOpen", 3000)
    if okc then
        wait_for_diagnostics(bufnr, 2500, 300)
    end
end

local function expand_command(template, bufnr, root)
    local file = vim.api.nvim_buf_get_name(bufnr)
    return (template:gsub("{file}", vim.fn.shellescape(file))
        :gsub("{dir}", vim.fn.shellescape(vim.fs.dirname(file)))
        :gsub("{root}", vim.fn.shellescape(root or vim.fn.getcwd())))
end

local function run_lint_command(template, bufnr, root, timeout_ms)
    local cmd = expand_command(template, bufnr, root)
    local result = await(function(resume)
        local ok, e = pcall(vim.system, { "sh", "-c", cmd }, {
            cwd = root, text = true, timeout = timeout_ms,
        }, vim.schedule_wrap(function(r) resume(r) end))
        if not ok then resume({ code = -1, stderr = tostring(e) }) end
    end)
    local text = ((result.stdout or "") .. (result.stderr or "")):gsub("%s+$", "")
    local lines = text == "" and {} or vim.split(text, "\n", { plain = true })
    if #lines > 30 then
        lines = vim.list_slice(lines, 1, 30)
        lines[#lines + 1] = "… (output truncated)"
    end
    return { command = cmd, exit = result.code, output = lines }
end

-- bufnr is nil after delete_file: there is no buffer left to report on, but
-- the project-wide diagnostic diff below is exactly what the caller wants
-- to see (what did removing this file break?), so the report still runs.
-- Signatures of the pre-existing diagnostics as last reported, so the next
-- report can say "no change" instead of listing them again.
local last_prior_key = nil

local function post_edit_report(bufnr, before, root, headless, opts, full)
    opts = opts or post_edit_options()
    local ft = bufnr and vim.bo[bufnr].filetype or ""
    -- Kick nvim-lint before waiting so its diagnostics join the same report.
    if opts.nvim_lint and bufnr then
        local okl, lint = pcall(require, "lint")
        if okl and type(lint.try_lint) == "function"
            and lint.linters_by_ft and lint.linters_by_ft[ft] then
            pcall(lint.try_lint)
        end
    end
    local attached = bufnr ~= nil and #vim.lsp.get_clients({ bufnr = bufnr }) > 0
    if attached then
        wait_for_diagnostics(bufnr, opts.wait_ms, 300)
    end
    local report = {}
    -- AGENT99_LINT_<FILETYPE> in the environment (handy for `claude mcp add
    -- -e`) overrides the configured command for that filetype.
    local template = os.getenv("AGENT99_LINT_" .. ft:upper():gsub("[^%w]", "_"))
    if not template or template == "" then
        template = opts.commands and opts.commands[ft]
    end
    if bufnr and type(template) == "string" and template ~= "" then
        -- A shell linter reads the disk. Headless edits are saved anyway
        -- (the bridge does it after the call), so write now; in a live
        -- editor the user's buffer is theirs to save, so lint only if it
        -- is already clean on disk.
        if headless then
            write_buf(bufnr)
        end
        if not vim.bo[bufnr].modified then
            report.lint = run_lint_command(template, bufnr, root, opts.lint_timeout_ms)
        else
            report.lint = "skipped: buffer has unsaved changes; save it and run " .. template
        end
    end
    -- Diff against the snapshot: consume matching signatures as
    -- pre-existing, the rest are new; leftovers in the snapshot were fixed.
    local remaining = vim.deepcopy(before or {})
    local new_here, new_elsewhere, preexisting_here = {}, {}, {}
    local preexisting = { errors = 0, warnings = 0 }
    local prior_sigs = {}
    for _, d in ipairs(vim.diagnostic.get(nil)) do
        if d.severity <= vim.diagnostic.severity.WARN then
            local sig = diag_signature(d)
            if (remaining[sig] or 0) > 0 then
                remaining[sig] = remaining[sig] - 1
                prior_sigs[#prior_sigs + 1] = sig
                if d.severity == vim.diagnostic.severity.ERROR then
                    preexisting.errors = preexisting.errors + 1
                else
                    preexisting.warnings = preexisting.warnings + 1
                end
                -- A count alone does not answer the question the caller
                -- actually has, which is whether any of these are in the
                -- code being edited. The ones elsewhere in the project stay
                -- a count; these get named.
                if d.bufnr == bufnr then
                    preexisting_here[#preexisting_here + 1] = ("%s line %d: %s"):format(
                        vim.diagnostic.severity[d.severity], d.lnum + 1, d.message)
                end
            elseif d.bufnr == bufnr then
                new_here[#new_here + 1] = ("%s line %d: %s"):format(
                    vim.diagnostic.severity[d.severity], d.lnum + 1, d.message)
            elseif d.severity == vim.diagnostic.severity.ERROR then
                new_elsewhere[#new_elsewhere + 1] = ("%s:%d: %s"):format(
                    vim.fn.fnamemodify(vim.api.nvim_buf_get_name(d.bufnr), ":."),
                    d.lnum + 1, d.message)
            end
        end
    end
    local fixed = 0
    for _, n in pairs(remaining) do fixed = fixed + n end
    if #new_here > 15 then
        local extra = #new_here - 15
        new_here = vim.list_slice(new_here, 1, 15)
        new_here[#new_here + 1] = ("… +%d more new diagnostics in this file"):format(extra)
    end
    if #new_elsewhere > 10 then
        local extra = #new_elsewhere - 10
        new_elsewhere = vim.list_slice(new_elsewhere, 1, 10)
        new_elsewhere[#new_elsewhere + 1] = ("… +%d more"):format(extra)
    end
    local not_analyzed = bufnr and not_analyzed_reason(bufnr) or nil
    if not_analyzed then
        -- Reporting "no new errors" here would be a straight lie: the server
        -- never looked. This is the build-tag case, where the edit is real
        -- but nothing is checking it.
        report.diagnostics_after = "not checked: the language server does not analyze this "
            .. "file in its current configuration (" .. not_analyzed .. "). An edit here is "
            .. "unverified - build or test with the tags that include it."
    elseif not attached and bufnr then
        report.diagnostics_after = "no language server attached to this file; nothing checked"
    elseif not bufnr then
        report.diagnostics_after = #new_elsewhere == 0
            and "no new errors elsewhere in the project" or nil
    elseif #new_here == 0 then
        report.diagnostics_after = "no new errors or warnings"
    else
        report.diagnostics_after = new_here
        -- A server analyzes one build configuration and can lag a change it
        -- has only just been told about, so a surprising error here is worth
        -- confirming rather than chasing.
        report.if_unexpected = "these come from the language server; check_project "
            .. "runs the project's own build or check for ground truth"
    end
    if #new_elsewhere > 0 then
        report.new_errors_elsewhere = new_elsewhere
    end
    local prior = {}
    if preexisting.errors > 0 then prior[#prior + 1] = preexisting.errors .. " errors" end
    if preexisting.warnings > 0 then prior[#prior + 1] = preexisting.warnings .. " warnings" end
    -- The pre-existing set rarely changes between two edits, and repeating
    -- it costs tokens on every reply for no decision. Remember what was
    -- reported and say "no change" until it differs; full_diagnostics
    -- asks for the list again.
    table.sort(prior_sigs)
    local key = table.concat(prior_sigs, "\n")
    if #prior > 0 then
        if key == last_prior_key and not full then
            report.preexisting = "no change since the last reply (full_diagnostics=true lists them)"
        else
            local elsewhere = (preexisting.errors + preexisting.warnings) - #preexisting_here
            report.preexisting = table.concat(prior, " and ") .. " were there before the edit (unchanged)"
            if #preexisting_here > 0 then
                if #preexisting_here > PREEXISTING_LISTED then
                    local extra = #preexisting_here - PREEXISTING_LISTED
                    preexisting_here = vim.list_slice(preexisting_here, 1, PREEXISTING_LISTED)
                    preexisting_here[#preexisting_here + 1] =
                        ("… +%d more already in this file"):format(extra)
                end
                report.preexisting_in_this_file = preexisting_here
                if elsewhere > 0 then
                    report.preexisting = report.preexisting
                        .. ("; the other %d are in files this edit did not touch"):format(elsewhere)
                end
            elseif elsewhere > 0 then
                report.preexisting = report.preexisting .. "; none of them in this file"
            end
        end
    end
    last_prior_key = key
    if fixed > 0 then
        report.fixed = fixed .. " diagnostics from before the edit are gone"
    end
    return report
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
    -- Every other position tool needs a column because it has to land on one
    -- particular name. Code actions do not: they are asked for over a range,
    -- and the range that matters is the line a diagnostic was reported on.
    -- So when neither symbol nor col is given, take the whole line - that is
    -- what "code actions at that line" is supposed to mean.
    local col, symbol = args.col, args.symbol
    if col == nil and (symbol == nil or symbol == "") then
        local text = vim.api.nvim_buf_get_lines(bufnr, (tonumber(args.line) or 1) - 1,
            (tonumber(args.line) or 1), false)[1] or ""
        col = (text:find("%S") or 1)
    end
    local pos = make_position(bufnr, client, args.line, symbol, col)
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
    -- A refused edit offers its own follow-ups (relocated, or forced) under
    -- a token too; those re-run the edit tool with adjusted arguments.
    if entry.edit then
        action_cache[tostring(args.token)] = nil
        local result = M.dispatch(entry.edit, action.args)
        if type(result) == "table" then
            result.applied = action.title
        end
        return result
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
        note = args.headless
            and "changes applied and saved to disk"
            or "changes live in editor buffers (unsaved); use buffer_lines to inspect them",
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







-- The MCP server passes headless=true when it drives its own Neovim and
-- writes buffers to disk after each edit; then "unsaved" would be a lie.
local function edit_note(args)
    if args.headless then
        return "applied and saved to disk"
    end
    return "applied to the editor buffer (unsaved)"
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

-- Shared tail of every edit tool: the lines are already in the buffer;
-- polish (format, imports), record the final region in the ledger, and
-- build the reply with the post-edit report.
local function finish_edit(bufnr, args, before, ledger_path, kind, first, last_old, old_lines, count, fields, regions)
    local opts = post_edit_options()
    local pfirst, pcount, done, extra_old
    if regions and #regions > 1 then
        -- Several edited regions far apart (chunks in different symbols):
        -- format each one on its own, bottom-up, so the code between them
        -- is left alone, then organize imports once. The span that goes in
        -- the ledger is re-measured from an extmark at its start and the
        -- untouched tail of the file, the same anchors polish_after_edit
        -- uses for one region.
        local tail = vim.api.nvim_buf_get_lines(bufnr, first - 1 + count, -1, false)
        local m_start = vim.api.nvim_buf_set_extmark(bufnr, span_ns, first - 1, 0, { right_gravity = false })
        local seen = {}
        local format_only = vim.tbl_extend("force", opts, { organize_imports = false })
        for i = #regions, 1, -1 do
            local _, _, d = polish_after_edit(bufnr, regions[i].first, regions[i].count, format_only)
            for _, x in ipairs(d) do seen[x] = true end
        end
        local _, _, d = polish_after_edit(bufnr, first, 0, vim.tbl_extend("force", opts, { format = false }))
        for _, x in ipairs(d) do seen[x] = true end
        done = vim.tbl_keys(seen)
        table.sort(done)
        local s = vim.api.nvim_buf_get_extmark_by_id(bufnr, span_ns, m_start, {})
        vim.api.nvim_buf_clear_namespace(bufnr, span_ns, 0, -1)
        local new_total = vim.api.nvim_buf_line_count(bufnr)
        -- Same tail rule as polish_after_edit: whatever a formatter changed
        -- below the span joins the recorded region.
        local keep = 0
        while keep < #tail and keep < new_total do
            local new_line = vim.api.nvim_buf_get_lines(bufnr, new_total - keep - 1, new_total - keep, false)[1]
            if tail[#tail - keep] ~= new_line then break end
            keep = keep + 1
        end
        extra_old = {}
        for i = 1, #tail - keep do extra_old[#extra_old + 1] = tail[i] end
        pfirst, pcount = first, count
        if s and s[1] then
            pfirst = s[1] + 1
            pcount = math.max(0, (new_total - keep) - s[1])
        end
    else
        pfirst, pcount, done, extra_old = polish_after_edit(bufnr, first, count, opts)
    end
    if extra_old and #extra_old > 0 then
        old_lines = vim.list_extend(vim.list_slice(old_lines, 1, #old_lines), extra_old)
        last_old = last_old + #extra_old
    end
    local new_lines = vim.api.nvim_buf_get_lines(bufnr, pfirst - 1, pfirst - 1 + pcount, false)
    record_edit(bufnr, ledger_path, kind, pfirst, last_old + (pfirst - first), old_lines, new_lines)
    fields.file = vim.api.nvim_buf_get_name(bufnr)
    fields.lines = pcount > 0 and ("%d-%d"):format(pfirst, pfirst + pcount - 1) or tostring(pfirst)
    fields.note = edit_note(args)
    if #done > 0 then
        fields.polished = table.concat(done, ", ")
    end
    return vim.tbl_extend("error", fields,
        post_edit_report(bufnr, before, args.root, args.headless, opts, args.full_diagnostics))
end
-- A unified diff of what an edit would do, for the dry_run of the tools that
-- otherwise apply immediately. rename_symbol has always been able to show its
-- blast radius before committing to it; a large body replacement is no less
-- worth looking at first.
local function preview_diff(old_lines, new_lines, label)
    local diff = vim.diff(
        table.concat(old_lines, "\n") .. "\n",
        table.concat(new_lines, "\n") .. "\n",
        { result_type = "unified", ctxlen = 2 })
    if type(diff) ~= "string" or diff == "" then
        return { unchanged = true, note = "the replacement is identical to what is there" }
    end
    return {
        dry_run = true,
        replaced = label,
        diff = vim.split(diff:gsub("\n$", ""), "\n", { plain = true }),
        note = "nothing applied; call again without dry_run to make the edit",
    }
end

local function replace_symbol_body(args)
    local bufnr, entry = resolve_symbol(args.file, args.name_path)
    if type(args.body) ~= "string" then
        err("missing required argument: body")
    end
    local new_lines = vim.split((args.body:gsub("\n+$", "")), "\n", { plain = true })
    local old = vim.api.nvim_buf_get_lines(bufnr, entry.first - 1, entry.last, false)
    if args.dry_run then
        return vim.tbl_extend("force",
            { file = rel_path(vim.api.nvim_buf_get_name(bufnr)) },
            preview_diff(old, new_lines, entry.path))
    end
    settle_before_edit(bufnr)
    local before = diag_snapshot()
    vim.api.nvim_buf_set_lines(bufnr, entry.first - 1, entry.last, false, new_lines)
    return finish_edit(bufnr, args, before, entry.path, "replace", entry.first, entry.last,
        old, #new_lines, { replaced = entry.path })
end


local function locate_expected(bufnr, entry, want)
    local want_lines = vim.split(want, "\n", { plain = true })
    local n = #want_lines
    local body = vim.api.nvim_buf_get_lines(bufnr, entry.first - 1, entry.last, false)
    local hits = {}
    for start = 1, #body - n + 1 do
        local window = vim.trim(table.concat(vim.list_slice(body, start, start + n - 1), "\n"))
        if window == want then
            hits[#hits + 1] = start
        end
    end
    if #hits == 1 then
        return hits[1], 1, n
    end
    return nil, #hits, n
end

-- The chunks of a replace_symbol_lines call: the single first_line/
-- last_line/text/expect form, or `chunks` carrying several of them.
local function edit_chunks(args)
    local chunks = args.chunks
    if type(chunks) ~= "table" or #chunks == 0 then
        chunks = { {
            first_line = args.first_line,
            last_line = args.last_line,
            text = args.text,
            expect = args.expect,
            match = args.match,
            absolute = args.absolute,
        } }
    end
    local out = {}
    for i, c in ipairs(chunks) do
        local first, last = tonumber(c.first_line), tonumber(c.last_line)
        if c.match ~= nil and type(c.match) ~= "string" then
            err("chunk %d: match must be a string: the text to replace, as it is now", i)
        end
        if c.match == nil and (not first or not last) then
            err("chunk %d: give first_line and last_line, or match (the text to replace)", i)
        end
        if type(c.text) ~= "string" then
            err("chunk %d: missing text", i)
        end
        if c.expect ~= nil and type(c.expect) ~= "string" then
            err("chunk %d: expect must be a string: the text those lines currently hold", i)
        end
        if c.name_path ~= nil and type(c.name_path) ~= "string" then
            err("chunk %d: name_path must be a string", i)
        end
        out[i] = {
            first = first,
            last = last,
            text = c.text,
            expect = c.expect,
            match = c.match,
            absolute = c.absolute == true or (c.absolute == nil and args.absolute == true),
            name_path = c.name_path or args.name_path,
            index = i
        }
    end
    return out
end
local function replace_symbol_lines(args)
    local chunks = edit_chunks(args)
    -- Each chunk addresses its own symbol (default: the call's name_path),
    -- so one call can touch the four functions one concept lives in. All
    -- in one file: the ledger, the polish and the diagnostics report are
    -- per buffer.
    local bufnr
    local entries = {}
    for _, c in ipairs(chunks) do
        if not c.name_path then
            -- No symbol named: edit the file's own lines. Only meaningful
            -- with absolute numbers or a match, since there is no
            -- declaration to number relative to. This is the barrel file,
            -- the import block, the export list: regions with no symbol to
            -- name, which used to force a fall back to Write.
            if not c.absolute and c.match == nil then
                err("chunk %d: give name_path, or absolute=true with buffer line numbers, "
                    .. "or match with the text to replace", c.index)
            end
            bufnr = bufnr or load_buf(args.file)
            if not entries[false] then
                entries[false] = { first = 1, last = vim.api.nvim_buf_line_count(bufnr),
                    path = rel_path(vim.api.nvim_buf_get_name(bufnr)), whole = true }
            end
            c.entry = entries[false]
        else
            if not entries[c.name_path] then
                local b, entry = resolve_symbol(args.file, c.name_path)
                bufnr = bufnr or b
                entries[c.name_path] = entry
            end
            c.entry = entries[c.name_path]
        end
        local span = c.entry.last - c.entry.first + 1
        -- The doc comment above the declaration is reachable too, by
        -- match or by absolute number: editing a function's comment along
        -- with the function is the common case, and the index's range
        -- stops at the declaration.
        local doc_first = doc_block_start(bufnr, c.entry.first)
        local doc_lines = c.entry.first - doc_first
        if c.match ~= nil then
            -- Text-keyed: the lines are wherever this text sits in the
            -- symbol, which must be exactly one place. No line arithmetic,
            -- and the text doubles as the expect= guard.
            local want = vim.trim((c.match:gsub("\n+$", "")))
            local at, count, n = locate_expected(bufnr,
                { first = doc_first, last = c.entry.last }, want)
            if at then at = at - doc_lines end
            if not at then
                if count == 0 then
                    err("chunk %d: the match text is nowhere in %s; re-read it with find_symbol",
                        c.index, c.entry.path)
                end
                err("chunk %d: the match text occurs %d times in %s; include more context",
                    c.index, count, c.entry.path)
            end
            c.first, c.last, c.expect = at, at + n - 1, c.match
        elseif c.absolute then
            -- Numbers as read_file, grep hits and buffer_lines report them.
            c.first = c.first - c.entry.first + 1
            c.last = c.last - c.entry.first + 1
        end
        local floor = (c.match ~= nil or c.absolute) and (1 - doc_lines) or 1
        if c.first < floor or c.last < c.first or c.last > span then
            err("chunk %d: lines %s-%s are outside the symbol %s, which spans %d-%d (%d lines%s)",
                c.index, tostring(c.first + c.entry.first - 1), tostring(c.last + c.entry.first - 1),
                c.entry.path, c.entry.first, c.entry.last, span,
                doc_lines > 0 and (", doc comment from %d"):format(doc_first) or "")
        end
        c.abs_first = c.entry.first + c.first - 1
        c.abs_last = c.entry.first + c.last - 1
        c.new_lines = vim.split((c.text:gsub("\n+$", "")), "\n", { plain = true })
        c.old = vim.api.nvim_buf_get_lines(bufnr, c.abs_first - 1, c.abs_last, false)
    end
    local entry = chunks[1].entry
    local symbols = vim.tbl_count(entries)
    table.sort(chunks, function(a, b) return a.abs_first < b.abs_first end)
    for i = 2, #chunks do
        if chunks[i].abs_first <= chunks[i - 1].abs_last then
            err("chunks overlap: lines %d-%d of %s and %d-%d of %s", chunks[i - 1].first,
                chunks[i - 1].last, chunks[i - 1].entry.path, chunks[i].first, chunks[i].last, chunks[i].entry.path)
        end
    end
    -- Relative line numbers are read off a snapshot - a find_symbol body or a
    -- grep hit - and an edit anywhere above the symbol moves every one of
    -- them. The numbers stay perfectly valid-looking after the shift, so the
    -- edit lands on the wrong lines and silently replaces working code.
    -- `expect` is the guard: give the text those lines are supposed to hold
    -- and a stale offset fails loudly instead. The refusal also does the
    -- search the caller would do next: when the expected text sits exactly
    -- once in the symbol, it offers the relocated edit as a code action, so
    -- the fix is one apply_code_action call and no re-read.
    local stale, relocated = {}, {}
    for _, c in ipairs(chunks) do
        if c.expect ~= nil and not args.force then
            local want = vim.trim((c.expect:gsub("\n+$", "")))
            local have = vim.trim(table.concat(c.old, "\n"))
            if want ~= have then
                -- The relocated range is as long as the expected text, not
                -- as long as the requested one: a caller who miscounted the
                -- last line still meant the text it named.
                local at, count, n = locate_expected(bufnr, c.entry, want)
                stale[#stale + 1] = { c = c, have = have, want = want, at = at, count = count, n = n }
                if at then
                    relocated[c] = { first_line = at, last_line = at + n - 1 }
                end
            end
        end
    end
    if #stale > 0 then
        local lines = {}
        for _, s in ipairs(stale) do
            lines[#lines + 1] = ("lines %d-%d of %s do not hold the expected text, so the numbers are "
                    .. "probably from before an earlier edit shifted them.\nexpected: %s\nfound:    %s")
                :format(s.c.first, s.c.last, s.c.entry.path, vim.inspect(s.want), vim.inspect(s.have))
            if s.at then
                lines[#lines + 1] = ("the expected text is at lines %d-%d (relative) instead."):format(
                    s.at, s.at + s.n - 1)
            elseif s.count > 1 then
                lines[#lines + 1] = ("the expected text occurs %d times in %s; pick with more context."):format(
                    s.count, s.c.entry.path)
            else
                lines[#lines + 1] = ("the expected text is nowhere in %s; re-read it with find_symbol."):format(
                    s.c.entry.path)
            end
        end
        local actions = {}
        if vim.tbl_count(relocated) == #stale then
            -- Every stale chunk has one home: the whole call, relocated.
            local moved = {}
            for _, c in ipairs(chunks) do
                local r = relocated[c]
                moved[#moved + 1] = {
                    first_line = r and r.first_line or c.first,
                    last_line = r and r.last_line or c.last,
                    text = c.text,
                    expect = c.expect,
                    name_path = c.name_path,
                    -- Relocated lines are symbol-relative whatever the call used.
                    absolute = false,
                }
            end
            actions[#actions + 1] = {
                title = "apply the same edit at the relocated lines",
                args = vim.tbl_extend("force", args, {
                    chunks = moved,
                    first_line = nil,
                    last_line = nil,
                    text = nil,
                    expect = nil,
                    match = nil,
                    absolute = nil,
                })
            }
        end
        actions[#actions + 1] = {
            title = "apply at the requested lines anyway (ignore expect)",
            args = vim.tbl_extend("force", args, { force = true })
        }
        action_token = action_token + 1
        local token = tostring(action_token)
        action_cache[token] = { edit = "replace_symbol_lines", actions = actions }
        local titles = {}
        for i, a in ipairs(actions) do
            titles[#titles + 1] = ("%d = %s"):format(i, a.title)
        end
        err("%s\napply_code_action(token=%s, index=N) continues without a re-read: %s",
            table.concat(lines, "\n"), token, table.concat(titles, "; "))
    end

    if args.dry_run then
        local previews = {}
        for _, c in ipairs(chunks) do
            previews[#previews + 1] = preview_diff(c.old, c.new_lines,
                ("lines %d-%d of %s"):format(c.first, c.last, c.entry.path))
        end
        if #previews == 1 then
            return vim.tbl_extend("force", { file = rel_path(vim.api.nvim_buf_get_name(bufnr)) }, previews[1])
        end
        return { file = rel_path(vim.api.nvim_buf_get_name(bufnr)), chunks = previews }
    end

    settle_before_edit(bufnr)
    local before = diag_snapshot()
    -- Bottom-up, so a chunk's replacement never shifts the ones above it.
    local span_first, span_last = chunks[1].abs_first, chunks[#chunks].abs_last
    local span_old = vim.api.nvim_buf_get_lines(bufnr, span_first - 1, span_last, false)
    local delta = 0
    local regions = {}
    for i = #chunks, 1, -1 do
        local c = chunks[i]
        vim.api.nvim_buf_set_lines(bufnr, c.abs_first - 1, c.abs_last, false, c.new_lines)
        delta = delta + #c.new_lines - #c.old
    end
    -- Where each chunk landed, after the ones below it moved nothing and the
    -- ones above shifted it by their growth.
    local shift = 0
    for _, c in ipairs(chunks) do
        regions[#regions + 1] = { first = c.abs_first + shift, count = #c.new_lines }
        shift = shift + #c.new_lines - #c.old
    end
    local label
    if #chunks == 1 and chunks[1].first < 1 then
        label = ("lines %d-%d (the doc comment above %s)"):format(chunks[1].abs_first, chunks[1].abs_last, entry.path)
    elseif #chunks == 1 then
        label = ("lines %d-%d of %s"):format(chunks[1].first, chunks[1].last, entry.path)
    elseif symbols == 1 then
        label = ("%d chunks (lines %d-%d) of %s"):format(#chunks, chunks[1].first, chunks[#chunks].last, entry.path)
    else
        local names = {}
        for _, c in ipairs(chunks) do
            if not vim.tbl_contains(names, c.entry.path) then names[#names + 1] = c.entry.path end
        end
        label = ("%d chunks in %s"):format(#chunks, table.concat(names, ", "))
    end
    local ledger_path = symbols == 1
        and ("%s:%d-%d"):format(entry.path, chunks[1].first, chunks[#chunks].last)
        or ("%d symbols:%d-%d"):format(symbols, span_first, span_last)
    local result = finish_edit(bufnr, args, before, ledger_path,
        "replace_lines", span_first, span_last, span_old, #span_old + delta,
        { replaced = label }, symbols > 1 and regions or nil)
    -- Always echo what was there. Without `expect` this is the only way a
    -- caller finds out an offset had drifted, and it costs a few lines.
    if #chunks == 1 then
        result.replaced_text = chunks[1].old
    else
        local echo = {}
        for _, c in ipairs(chunks) do
            echo[#echo + 1] = { symbol = symbols > 1 and c.entry.path or nil,
                lines = ("%d-%d"):format(c.first, c.last), replaced_text = c.old }
        end
        result.replaced_chunks = echo
    end
    return result
end

local function insert_symbol_tool(where)
    return function(args)
        local bufnr, entry = resolve_symbol(args.file, args.name_path)
        if type(args.text) ~= "string" or args.text == "" then
            err("missing required argument: text")
        end
        local lines = vim.split((args.text:gsub("\n+$", "")), "\n", { plain = true })
        -- A blank line belongs between two functions and nowhere near two
        -- constants: inserting a sibling into a `const (...)` or `var (...)`
        -- block should not split the block in half. Single-line declarations
        -- are the ones that live in such groups.
        local spaced = (entry.last - entry.first) > 0
        local row -- 0-based insertion point
        if where == "after" then
            row = entry.last
            if spaced then table.insert(lines, 1, "") end
        else
            -- Above the whole declaration, its decorators and doc comment
            -- included, so a new sibling never lands between @Decorator (or
            -- a Rust #[attr], or a Python decorator) and the thing it
            -- annotates, which is a syntax error.
            row = decl_block_top(bufnr, entry.first) - 1
            if spaced then table.insert(lines, "") end
        end
        settle_before_edit(bufnr)
        local before = diag_snapshot()
        vim.api.nvim_buf_set_lines(bufnr, row, row, false, lines)
        return finish_edit(bufnr, args, before, entry.path, "insert_" .. where, row + 1, row,
            {}, #lines, { inserted = ("%s %s"):format(where, entry.path) })
    end
end
local function undo_edit(args)
    local edits = require("agent99.edits")
    local count = tonumber(args.count) or 1
    if args.all then count = nil end
    if edits.count() == 0 then
        return {
            undone = {},
            note = "no symbol edits recorded in this run; apply_code_action edits are "
                .. "not tracked here - reverse those with another code action or an edit",
        }
    end
    local last_bufnr
    local before = diag_snapshot()
    local undone, refused = edits.undo_last(count)
    local out = {}
    for _, e in ipairs(undone) do
        local item = { file = rel_path(e.file), symbol = e.name_path, kind = e.kind }
        if e.file_op then
            item.reversed = e.kind
        elseif #e.old_lines == 0 then
            item.removed_lines = ("%d-%d"):format(e.first, e.first + e.new_count - 1)
        else
            item.restored_lines = ("%d-%d"):format(e.first, e.first + #e.old_lines - 1)
        end
        out[#out + 1] = item
        last_bufnr = e.bufnr or last_bufnr
    end
    local result = { undone = out, remaining = edits.count() }
    if #refused > 0 then
        result.refused = refused
    end
    if last_bufnr then
        local opts = post_edit_options()
        if opts.organize_imports then
            -- Imports added for the undone code would now be unused (an
            -- error in Go); let the server drop them again.
            local seen = {}
            for _, e in ipairs(undone) do
                if e.bufnr and not seen[e.bufnr] and vim.api.nvim_buf_is_valid(e.bufnr) then
                    seen[e.bufnr] = true
                    organize_imports(e.bufnr)
                end
            end
        end
        result = vim.tbl_extend("error", result,
            post_edit_report(last_bufnr, before, args.root, args.headless, opts, args.full_diagnostics))
        result.note = edit_note(args)
    end
    return result
end

-- check_project: one project-wide check (type checker, vet, cargo check)
-- with a baseline. The first run in a root records its output; later runs
-- report only lines that are new since the baseline and lines that went
-- away, so "is the project still green after my refactor" is one call
-- with a short answer.
local check_baseline = {}
local CHECK_MAX_LINES = 60

-- Guessed commands are all type checks and vetting, never test runners: they
-- have to be fast enough to run after an edit, and the question they answer is
-- "did I break a reference", not "does the suite pass". The reply says so,
-- because a green check here is easy to mistake for a green project.
local function guess_check_command(root)
    local function has(rel) return vim.uv.fs_stat(root .. "/" .. rel) ~= nil end
    -- `go build ./...` writes a binary named after a lone main package into
    -- the cwd, which fails when a directory of that name exists (a repo with
    -- its main package in ./bridge). vet compiles everything without that.
    if has("go.mod") then return "go vet ./..." end
    if has("Cargo.toml") then return "cargo check --message-format short" end
    if has("tsconfig.json") then
        if has("node_modules/.bin/tsc") then return "node_modules/.bin/tsc --noEmit -p ." end
        if vim.fn.executable("tsc") == 1 then return "tsc --noEmit -p ." end
    end
    if has("pyproject.toml") or has("setup.py") or has("setup.cfg") then
        if vim.fn.executable("pyright") == 1 then return "pyright" end
        if vim.fn.executable("mypy") == 1 then return "mypy ." end
    end
    if has("CMakeLists.txt") and has("build") then return "cmake --build build" end
    return nil
end

-- A check command the caller has chosen for this project, replacing the guess
-- for the rest of the session. The guess cannot know that a project needs its
-- tests run, or needs checking under a second set of build tags; whoever is
-- working in the repository does, and should not have to repeat it on every
-- call. Keyed by root, and lives as long as the workspace does.
local check_override = {}

local function check_project(args)
    local root = args.root
    if type(root) ~= "string" or root == "" then
        root = vim.fn.getcwd()
    end
    local opts = post_edit_options()
    local okc, config = pcall(require, "agent99.config")
    local configured = okc and config.options and config.options.post_edit
        and config.options.post_edit.check or nil

    -- Explicit for this call, then whatever was remembered for this root,
    -- then the environment, the user's config, and finally the guess.
    local cmds
    if type(args.commands) == "table" and #args.commands > 0 then
        cmds = {}
        for _, c in ipairs(args.commands) do
            if type(c) ~= "string" or c == "" then
                err("commands must be a list of non-empty shell commands")
            end
            cmds[#cmds + 1] = c
        end
    elseif type(args.command) == "string" and args.command ~= "" then
        cmds = { args.command }
    end
    local explicit = cmds ~= nil
    if not cmds and check_override[root] then cmds = check_override[root] end
    local from_env = os.getenv("AGENT99_CHECK")
    if not cmds and from_env and from_env ~= "" then cmds = { from_env } end
    if not cmds and configured and configured ~= "" then cmds = { configured } end
    local guessed = false
    if not cmds then
        local guess = guess_check_command(root)
        if guess then
            cmds = { guess }
            guessed = true
        end
    end
    if not cmds then
        err("no check command: pass command= or commands=, set AGENT99_CHECK, "
            .. "or post_edit.check in setup()")
    end
    if explicit and args.remember then
        check_override[root] = cmds
    end
    -- Only for the baseline key and the reply; the commands are run one at a
    -- time below, not handed to a shell as one line.
    local cmd = table.concat(cmds, " ; ")
    local timeout = (okc and config.options and config.options.post_edit
        and config.options.post_edit.check_timeout_ms) or 5 * 60 * 1000
    -- Shell linters read the disk: flush what the tools changed first.
    local unsaved
    if args.headless then
        local failures = M.save_all()
        if #failures > 0 then
            unsaved = failures
        end
    end
    local started = vim.uv.now()
    -- Run each command in turn rather than joining them into one shell line.
    -- Joining with ";" would report the last command's exit code and hide a
    -- failure in an earlier one; joining with "&&" would stop at the first
    -- failure and never check the other build configuration, which is the
    -- main reason for passing more than one command in the first place.
    local lines, exit, failed = {}, 0, nil
    for _, one in ipairs(cmds) do
        local result = await(function(resume)
            local ok, e = pcall(vim.system, { "sh", "-c", one }, {
                cwd = root, text = true, timeout = timeout,
            }, vim.schedule_wrap(function(r) resume(r) end))
            if not ok then resume({ code = -1, stderr = tostring(e) }) end
        end)
        local text = ((result.stdout or "") .. (result.stderr or "")):gsub("%s+$", "")
        if #cmds > 1 and text ~= "" then
            lines[#lines + 1] = ("$ %s"):format(one)
        end
        if text ~= "" then
            vim.list_extend(lines, vim.split(text, "\n", { plain = true }))
        end
        if result.code ~= 0 and exit == 0 then
            exit, failed = result.code, one
        end
    end
    local out = {
        command = #cmds == 1 and cmd or nil,
        commands = #cmds > 1 and cmds or nil,
        guessed = guessed or nil,
        exit = exit,
        failed_command = failed,
        seconds = math.floor((vim.uv.now() - started) / 100) / 10,
        unsaved = unsaved,
    }
    if explicit and args.remember then
        out.remembered = "later check_project calls in this root use this without arguments"
    elseif not explicit and check_override[root] then
        out.remembered = "using the command remembered for this root"
    end
    if guessed then
        out.covers = "type and reference checking only: this does not run the tests, "
            .. "and it checks one build configuration, so code behind another build tag "
            .. "or feature flag is not analyzed. If that is the wrong gate for this "
            .. "project, pass a better one: commands=[...] runs several (one per build "
            .. "configuration), and remember=true makes it the default for this root "
            .. "for the rest of the session."
    end
    local key = root .. "\0" .. cmd
    local base = check_baseline[key]
    if base and not args.reset then
        local base_set, now_set = {}, {}
        for _, l in ipairs(base) do base_set[l] = (base_set[l] or 0) + 1 end
        for _, l in ipairs(lines) do now_set[l] = (now_set[l] or 0) + 1 end
        local new, resolved = {}, {}
        for _, l in ipairs(lines) do
            if (base_set[l] or 0) > 0 then base_set[l] = base_set[l] - 1 else new[#new + 1] = l end
        end
        for _, l in ipairs(base) do
            if (now_set[l] or 0) > 0 then now_set[l] = now_set[l] - 1 else resolved[#resolved + 1] = l end
        end
        out.baseline_lines = #base
        out.new = vim.list_slice(new, 1, CHECK_MAX_LINES)
        if #new > CHECK_MAX_LINES then out.new_truncated = #new - CHECK_MAX_LINES end
        out.resolved = #resolved
        if #new == 0 then
            out.summary = exit == 0 and "clean, nothing new since the baseline"
                or "nothing new since the baseline (the check still fails as it did before)"
        else
            out.summary = ("%d new lines since the baseline"):format(#new)
        end
    else
        check_baseline[key] = lines
        out.baseline = "recorded; later calls report only what changed"
        out.output = vim.list_slice(lines, 1, CHECK_MAX_LINES)
        if #lines > CHECK_MAX_LINES then out.output_truncated = #lines - CHECK_MAX_LINES end
        if #lines == 0 and exit == 0 then out.summary = "clean" end
    end
    return out
end

-- rename_symbol: textDocument/rename across the project. dry_run reports
-- which files and how many places would change; otherwise the edit is
-- applied, each touched file goes into the undo ledger as a whole-file
-- entry, and the origin file's diagnostics are reported like any edit.
local function summarize_workspace_edit(edit)
    local per_file, order = {}, {}
    local function add(uri, n)
        local file = vim.uri_to_fname(uri)
        if not per_file[file] then
            per_file[file] = 0
            order[#order + 1] = file
        end
        per_file[file] = per_file[file] + n
    end
    for uri, edits in pairs(edit.changes or {}) do
        add(uri, #edits)
    end
    local file_ops = {}
    for _, dc in ipairs(edit.documentChanges or {}) do
        if dc.textDocument then
            add(dc.textDocument.uri, #(dc.edits or {}))
        elseif dc.kind then
            file_ops[#file_ops + 1] = dc.kind .. " " .. (dc.uri or dc.newUri or dc.oldUri or "?")
        end
    end
    table.sort(order)
    local files = {}
    for _, file in ipairs(order) do
        files[#files + 1] = { file = file, edits = per_file[file] }
    end
    return files, file_ops
end

local function rename_symbol(args)
    local bufnr = load_buf(args.file)
    local new_name = args.new_name
    if type(new_name) ~= "string" or new_name == "" then
        err("missing required argument: new_name")
    end
    local client = get_client(bufnr, "textDocument/rename")
    local params = position_params(bufnr, client, args)
    if client:supports_method("textDocument/prepareRename") then
        local okp, prep = pcall(request, client, bufnr, "textDocument/prepareRename", params)
        if okp and prep == nil then
            err("the server refuses to rename at this position (not a renamable symbol)")
        end
    end
    params.newName = new_name
    local edit = request(client, bufnr, "textDocument/rename", params)
    if not edit or (not edit.changes and not edit.documentChanges) then
        err("the server returned no edit for this rename")
    end
    local files, file_ops = summarize_workspace_edit(edit)
    local total = 0
    for _, f in ipairs(files) do total = total + f.edits end
    if args.dry_run then
        return { dry_run = true, new_name = new_name, files = files,
            total_edits = total, file_operations = #file_ops > 0 and file_ops or nil,
            note = "nothing applied; call again without dry_run to rename" }
    end
    settle_before_edit(bufnr)
    local before = diag_snapshot()
    -- Whole-file snapshots of every touched file feed the undo ledger.
    local snaps = {}
    for _, f in ipairs(files) do
        local okb, b = pcall(load_buf, f.file)
        if okb then
            snaps[#snaps + 1] = { bufnr = b, file = f.file,
                old = vim.api.nvim_buf_get_lines(b, 0, -1, false) }
        end
    end
    vim.lsp.util.apply_workspace_edit(edit, client.offset_encoding)
    for _, snap in ipairs(snaps) do
        local new = vim.api.nvim_buf_get_lines(snap.bufnr, 0, -1, false)
        record_edit(snap.bufnr, "rename " .. new_name, "rename", 1, #snap.old, snap.old, new)
    end
    local result = { renamed_to = new_name, files = files, total_edits = total,
        file_operations = #file_ops > 0 and file_ops or nil }
    result = vim.tbl_extend("error", result,
        post_edit_report(bufnr, before, args.root, args.headless, nil, args.full_diagnostics))
    result.note = edit_note(args)
    return result
end

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

local FILE_OP_CAPABILITY = {
    ["workspace/willCreateFiles"] = "willCreate",
    ["workspace/didCreateFiles"] = "didCreate",
    ["workspace/willRenameFiles"] = "willRename",
    ["workspace/didRenameFiles"] = "didRename",
    ["workspace/willDeleteFiles"] = "willDelete",
    ["workspace/didDeleteFiles"] = "didDelete",
}

local function file_op_clients(method)
    local key = FILE_OP_CAPABILITY[method]
    local out = {}
    for _, client in ipairs(vim.lsp.get_clients()) do
        local workspace = (client.server_capabilities or {}).workspace or {}
        if (workspace.fileOperations or {})[key] then
            out[#out + 1] = client
        end
    end
    return out
end

-- Tell every interested server that files appeared, moved or went away.
local function notify_file_operation(method, files)
    for _, client in ipairs(file_op_clients(method)) do
        pcall(function() client:notify(method, { files = files }) end)
    end
end

-- Ask the servers what else has to change for this operation, and apply it.
-- Returns the list of files touched, so the caller can report and record it.
local function apply_will_file_operation(method, files)
    local touched = {}
    for _, client in ipairs(file_op_clients(method)) do
        local ok, edit = pcall(request, client, nil, method, { files = files })
        if ok and edit and (edit.changes or edit.documentChanges) then
            local affected = summarize_workspace_edit(edit)
            local snaps = {}
            for _, f in ipairs(affected) do
                local okb, b = pcall(load_buf, f.file)
                if okb then
                    snaps[#snaps + 1] = { bufnr = b, file = f.file,
                        old = vim.api.nvim_buf_get_lines(b, 0, -1, false) }
                end
            end
            vim.lsp.util.apply_workspace_edit(edit, client.offset_encoding)
            for _, snap in ipairs(snaps) do
                local new = vim.api.nvim_buf_get_lines(snap.bufnr, 0, -1, false)
                record_edit(snap.bufnr, method, "file_operation", 1, #snap.old, snap.old, new)
            end
            vim.list_extend(touched, affected)
        end
    end
    return touched
end

local function file_uri(path)
    return vim.uri_from_fname(path)
end

-- Resolve a path argument for a tool that is about to create something, so
-- unlike load_buf it must accept a path that does not exist yet.
local function resolve_new_path(value, what)
    if type(value) ~= "string" or value == "" then
        err("missing required argument: %s", what)
    end
    return vim.fn.fnamemodify(value, ":p"):gsub("/$", "")
end

-- Drop a buffer for a file that is no longer there (or is now somewhere
-- else), so nothing later reads or writes it by accident.
local function forget_buf(path)
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_valid(bufnr)
            and vim.api.nvim_buf_get_name(bufnr) == path then
            pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
        end
    end
end

local function create_file(args)
    local path = resolve_new_path(args.file, "file")
    if vim.uv.fs_stat(path) then
        err("%s already exists; edit it with the symbol tools, or delete it first",
            rel_path(path))
    end
    local text = args.text
    if text ~= nil and type(text) ~= "string" then
        err("text must be a string")
    end
    local dir = vim.fn.fnamemodify(path, ":h")
    if vim.fn.isdirectory(dir) == 0 and vim.fn.mkdir(dir, "p") == 0 then
        err("could not create the directory %s", rel_path(dir))
    end
    local files = { { uri = file_uri(path) } }
    apply_will_file_operation("workspace/willCreateFiles", files)
    local lines = vim.split((text or ""):gsub("\n$", ""), "\n", { plain = true })
    if vim.fn.writefile(lines, path) ~= 0 then
        err("could not write %s", rel_path(path))
    end
    notify_file_operation("workspace/didCreateFiles", files)

    local before = diag_snapshot()
    local bufnr = load_buf(path)
    settle_before_edit(bufnr)
    local opts = post_edit_options()
    local _, _, done = polish_after_edit(bufnr, 1, #lines, opts)
    if args.headless then
        write_buf(bufnr)
    end
    require("agent99.edits").record_file_op({
        file = path,
        kind = "create_file",
        undo = function()
            local now = vim.uv.fs_stat(path)
            if not now then
                return "the file is already gone"
            end
            forget_buf(path)
            if vim.fn.delete(path) ~= 0 then
                return "could not delete it"
            end
            notify_file_operation("workspace/didDeleteFiles", files)
            return nil
        end,
    })

    local result = { created = rel_path(path), lines = #lines, note = edit_note(args) }
    if #done > 0 then
        result.polished = table.concat(done, ", ")
    end
    return vim.tbl_extend("force", result,
        post_edit_report(bufnr, before, args.root, args.headless, opts, args.full_diagnostics))
end

local function move_file(args)
    local from = resolve_new_path(args.from, "from")
    local to = resolve_new_path(args.to, "to")
    if not vim.uv.fs_stat(from) then
        err("%s does not exist", rel_path(from))
    end
    if vim.uv.fs_stat(to) then
        err("%s already exists; delete it first or pick another name", rel_path(to))
    end
    -- Moving onto a path whose directory is missing is a common way to ask
    -- for a new package; make it rather than fail.
    local dir = vim.fn.fnamemodify(to, ":h")
    if vim.fn.isdirectory(dir) == 0 and vim.fn.mkdir(dir, "p") == 0 then
        err("could not create the directory %s", rel_path(dir))
    end

    local files = { { oldUri = file_uri(from), newUri = file_uri(to) } }
    local before = diag_snapshot()
    -- Ask first: this is where a server rewrites the imports that name the
    -- old path. It has to happen while the file is still at the old one.
    local touched = apply_will_file_operation("workspace/willRenameFiles", files)
    if args.headless then
        M.save_all()
    end
    forget_buf(from)
    local okm, e = vim.uv.fs_rename(from, to)
    if not okm then
        err("could not move %s to %s: %s", rel_path(from), rel_path(to), tostring(e))
    end
    notify_file_operation("workspace/didRenameFiles", files)

    require("agent99.edits").record_file_op({
        file = to,
        kind = "move_file",
        undo = function()
            if not vim.uv.fs_stat(to) then
                return "the moved file is no longer there"
            end
            if vim.uv.fs_stat(from) then
                return "something else now occupies the original path"
            end
            forget_buf(to)
            local ok = vim.uv.fs_rename(to, from)
            if not ok then
                return "could not move it back"
            end
            notify_file_operation("workspace/didRenameFiles",
                { { oldUri = file_uri(to), newUri = file_uri(from) } })
            return nil
        end,
    })

    local bufnr = load_buf(to)
    settle_before_edit(bufnr)
    local result = {
        moved = rel_path(from), to = rel_path(to), note = edit_note(args),
    }
    if #touched > 0 then
        result.updated_by_server = touched
        result.updated_note = "the language server rewrote references to the old path"
    end
    return vim.tbl_extend("force", result,
        post_edit_report(bufnr, before, args.root, args.headless, nil, args.full_diagnostics))
end

local function delete_file(args)
    local path = resolve_new_path(args.file, "file")
    local stat = vim.uv.fs_stat(path)
    if not stat then
        err("%s does not exist", rel_path(path))
    end
    if stat.type == "directory" then
        err("%s is a directory; this tool deletes one file at a time", rel_path(path))
    end
    local okr, contents = pcall(vim.fn.readfile, path, "b")
    if not okr then
        err("could not read %s before deleting it", rel_path(path))
    end

    local files = { { uri = file_uri(path) } }
    local before = diag_snapshot()
    local touched = apply_will_file_operation("workspace/willDeleteFiles", files)
    if args.headless then
        M.save_all()
    end
    forget_buf(path)
    if vim.fn.delete(path) ~= 0 then
        err("could not delete %s", rel_path(path))
    end
    notify_file_operation("workspace/didDeleteFiles", files)

    require("agent99.edits").record_file_op({
        file = path,
        kind = "delete_file",
        undo = function()
            if vim.uv.fs_stat(path) then
                return "something else now occupies that path"
            end
            local okw, wrote = pcall(vim.fn.writefile, contents, path, "b")
            if not okw or wrote ~= 0 then
                return "could not write the contents back"
            end
            notify_file_operation("workspace/didCreateFiles", files)
            return nil
        end,
    })

    local result = {
        deleted = rel_path(path), lines = #contents, note = edit_note(args),
        restorable = "undo_edit puts it back with its contents",
    }
    if #touched > 0 then
        result.updated_by_server = touched
    end
    -- No buffer left to report against, so report the project-wide picture.
    local report = post_edit_report(nil, before, args.root, args.headless, nil, args.full_diagnostics)
    report.file = nil
    return vim.tbl_extend("force", result, report)
end

-- doc_block_start (defined above replace_symbol_lines) is what anything
-- that moves a symbol widens its range by, or the documentation is left
-- behind, orphaned above whatever follows.




-- Move whole symbols from one file to another.
--
-- Splitting an oversized file is a symbol operation that no symbol tool could
-- express: the unit is a run of independent top-level declarations, not one
-- symbol, so replace_symbol_body has nothing to replace and the work fell back
-- to a literal string match over a large block - the very thing these tools
-- exist to avoid.
--
-- Doing it here also gets the two things a copy-and-delete cannot: each
-- symbol's doc comment travels with it, and both files have their imports
-- reorganized afterwards, so the destination gains what it now needs and the
-- source loses what it no longer uses.
local function move_symbols(args)
    local from_buf = load_buf(args.from)
    local to_path = resolve_new_path(args.to, "to")
    if type(args.names) ~= "table" or #args.names == 0 then
        err("missing required argument: names (the symbols to move)")
    end
    if vim.fn.fnamemodify(args.from, ":p") == to_path then
        err("from and to are the same file")
    end

    -- Resolve every name first: moving half a list and then failing would
    -- leave the caller with two files to reconcile by hand.
    local moving = {}
    local seen = {}
    for _, name in ipairs(args.names) do
        local _, entry = resolve_symbol(args.from, name)
        if seen[entry.path] then
            err("%s was named twice", entry.path)
        end
        seen[entry.path] = true
        moving[#moving + 1] = {
            path = entry.path,
            first = doc_block_start(from_buf, entry.first),
            last = entry.last,
        }
    end
    table.sort(moving, function(a, b) return a.first < b.first end)
    for i = 2, #moving do
        if moving[i].first <= moving[i - 1].last then
            err("%s and %s overlap; move them separately",
                moving[i - 1].path, moving[i].path)
        end
    end

    local from_before = vim.api.nvim_buf_get_lines(from_buf, 0, -1, false)
    local blocks = {}
    for _, m in ipairs(moving) do
        blocks[#blocks + 1] = vim.api.nvim_buf_get_lines(from_buf, m.first - 1, m.last, false)
    end

    -- A new destination needs whatever declares which module it belongs to.
    -- Only Go-style `package X` is inferred; anything else the caller supplies
    -- with header=, since guessing wrong writes a broken file.
    local created = false
    if not vim.uv.fs_stat(to_path) then
        local header = args.header
        if header == nil then
            for _, line in ipairs(vim.list_slice(from_before, 1, 30)) do
                if line:match("^package%s+%S") then
                    header = line
                    break
                end
            end
        end
        local dir = vim.fn.fnamemodify(to_path, ":h")
        if vim.fn.isdirectory(dir) == 0 and vim.fn.mkdir(dir, "p") == 0 then
            err("could not create the directory %s", rel_path(dir))
        end
        local seed = {}
        if header and header ~= "" then
            vim.list_extend(seed, vim.split(header, "\n", { plain = true }))
            seed[#seed + 1] = ""
        end
        if vim.fn.writefile(seed, to_path) ~= 0 then
            err("could not create %s", rel_path(to_path))
        end
        notify_file_operation("workspace/didCreateFiles", { { uri = file_uri(to_path) } })
        created = true
    end

    local to_buf = load_buf(to_path)
    local to_before = vim.api.nvim_buf_get_lines(to_buf, 0, -1, false)
    settle_before_edit(from_buf)
    local before = diag_snapshot()

    -- Append to the destination, then delete from the source bottom upwards so
    -- the earlier line numbers stay valid as the later ones go.
    local appended = {}
    for _, block in ipairs(blocks) do
        if #appended > 0 or #to_before > 0 then
            appended[#appended + 1] = ""
        end
        vim.list_extend(appended, block)
    end
    local at = #to_before
    vim.api.nvim_buf_set_lines(to_buf, at, at, false, appended)
    for i = #moving, 1, -1 do
        vim.api.nvim_buf_set_lines(from_buf, moving[i].first - 1, moving[i].last, false, {})
    end

    local opts = post_edit_options()
    local _, _, polished = polish_after_edit(to_buf, at + 1, #appended, opts)
    if opts.organize_imports then
        organize_imports(from_buf)
    end
    if args.headless then
        M.save_all()
    end

    -- Whole-file entries for both, so undo_edit puts the split back.
    record_edit(from_buf, ("moved out of %s"):format(rel_path(args.from)), "move_symbols",
        1, #from_before, from_before, vim.api.nvim_buf_get_lines(from_buf, 0, -1, false))
    record_edit(to_buf, ("moved into %s"):format(rel_path(to_path)), "move_symbols",
        1, #to_before, to_before, vim.api.nvim_buf_get_lines(to_buf, 0, -1, false))

    local names = {}
    for _, m in ipairs(moving) do names[#names + 1] = m.path end
    local result = {
        moved = names,
        from = rel_path(vim.fn.fnamemodify(args.from, ":p")),
        to = rel_path(to_path),
        created = created or nil,
        note = edit_note(args),
    }
    if #polished > 0 then
        result.polished = table.concat(polished, ", ")
    end
    return vim.tbl_extend("force", result,
        post_edit_report(to_buf, before, args.root, args.headless, opts, args.full_diagnostics))
end





-- Internal: what the editor can do for the languages in a workspace, so a
-- client that opened a headless instance learns up front when a language
-- has no parser (skim/find_symbol/ts_query blind) or no language server
-- (definition/references/hover/diagnostics blind). Counts files per
-- filetype from the git index, checks the parser instantly, and for the
-- filetypes that have an enabled LSP config loads one sample file and
-- waits briefly for a client to attach (the binary may be missing).
local SUPPORT_MAX_FILETYPES = 6
local SUPPORT_ATTACH_MS = 2500


-- A warning when a JavaScript or TypeScript project's dependencies are not
-- where the language server will look, or are a symlink escaping the root:
-- the two ways its diagnostics turn authoritative and wrong.
local function node_modules_note(root, by_ft)
    local js = (by_ft.typescript or 0) + (by_ft.typescriptreact or 0)
        + (by_ft.javascript or 0) + (by_ft.javascriptreact or 0)
    if js == 0 then return nil end
    local nm = root .. "/node_modules"
    local lstat = vim.uv.fs_lstat(nm)
    if not lstat then
        -- A pnpm/yarn workspace keeps packages in the repo root, not the
        -- package dir, so only warn when there is a manifest here to install.
        if vim.uv.fs_stat(root .. "/package.json") then
            return "node_modules is absent under this root: the language server will report "
                .. "unresolved-import errors that are about the missing install, not the code. "
                .. "Install dependencies (npm/pnpm/yarn install) before trusting diagnostics."
        end
        return nil
    end
    if lstat.type == "link" then
        local target = vim.uv.fs_realpath(nm)
        local real_root = vim.uv.fs_realpath(root) or root
        if target and target:sub(1, #real_root + 1) ~= real_root .. "/" then
            return ("node_modules is a symlink to %s, outside this root: a package may resolve "
                .. "into a different checkout and produce a plausible but wrong type error. "
                .. "Verify a suspicious import diagnostic against the real dependency."):format(target)
        end
    end
    return nil
end

local function workspace_support(args)
    local root = args.root
    if type(root) ~= "string" or root == "" then
        err("missing project root")
    end
    local files = project_files(root)
    local by_ft, sample, ext_cache = {}, {}, {}
    for _, rel in ipairs(files) do
        local ext = rel:match("%.([%w_]+)$") or rel
        local ft = ext_cache[ext]
        if ft == nil then
            ft = vim.filetype.match({ filename = rel }) or false
            ext_cache[ext] = ft
        end
        if ft then
            by_ft[ft] = (by_ft[ft] or 0) + 1
            if better_sample(sample[ft], rel) then
                sample[ft] = rel
            end
        end
    end
    local fts = vim.tbl_keys(by_ft)
    table.sort(fts, function(a, b) return by_ft[a] > by_ft[b] end)
    local out, blind = {}, {}
    for i, ft in ipairs(fts) do
        if i > SUPPORT_MAX_FILETYPES then break end
        local parser = has_parser(ft)
        local configs = enabled_lsp_configs_for(ft)
        -- What could run this language under a debugger, so a client
        -- learns the option exists even when the debug tools are off.
        -- Probed before the server starts: for Java the probe also adds
        -- the java-debug bundle to the jdtls config, which only counts
        -- for a client that has not started yet.
        local debugger
        if not DATA_FILETYPES[ft] then
            local okd, dbg = pcall(function()
                return require("agent99.dap").debugger_for(ft, root)
            end)
            if okd then debugger = dbg end
        end
        local clients = {}
        if #configs > 0 then
            local okb, bufnr = pcall(load_buf, root .. "/" .. sample[ft])
            if okb then
                local deadline = vim.uv.now() + SUPPORT_ATTACH_MS
                while vim.uv.now() < deadline do
                    for _, c in ipairs(vim.lsp.get_clients({ bufnr = bufnr })) do
                        clients[#clients + 1] = c.name
                    end
                    if #clients > 0 then break end
                    sleep(100)
                end
            end
        end
        local entry = {
            filetype = ft,
            files = by_ft[ft],
            treesitter_parser = parser,
            lsp = #clients > 0 and table.concat(clients, ",") or "none",
            debugger = debugger,
        }
        if #clients == 0 and #configs > 0 then
            entry.lsp = "none (configured: " .. table.concat(configs, ",") .. ", did not attach)"
        end
        if not parser and #clients == 0 and not DATA_FILETYPES[ft] then
            blind[#blind + 1] = ft
        end
        out[#out + 1] = entry
    end
    local notes = {}
    if #blind > 0 then
        notes[#notes + 1] = ("no parser and no language server for %s: symbol, navigation and "
                .. "diagnostic tools will not work on those files; grep and read_file will. "
                .. "install_language(language) can add both")
            :format(table.concat(blind, ", "))
    end
    -- A JS/TS project whose dependencies are not installed makes the language
    -- server report a wall of unresolved-import errors that say nothing about
    -- the code, and the failure looks authoritative. Worse, a node_modules
    -- symlink escaping the root can resolve a package into another checkout,
    -- producing one plausible-but-wrong type error. Say so up front.
    local ok_dep, dep_note = pcall(node_modules_note, root, by_ft)
    if ok_dep and dep_note then
        notes[#notes + 1] = dep_note
    end
    return { languages = out, note = #notes > 0 and table.concat(notes, " ") or nil }
end

-- install_language: add a treesitter parser (nvim-treesitter) and a language
-- server (Mason) for one filetype to the running instance, so the symbol and
-- navigation tools start working on files open_workspace flagged as blind.
-- Both installs are optional pieces of the user's setup; each step reports
-- what it did or why it could not.
local INSTALL_PARSER_MS = 5 * 60 * 1000
local INSTALL_SERVER_MS = 8 * 60 * 1000
local INSTALL_ATTACH_MS = 8000

-- Preferred language server per filetype where Mason offers several; the
-- lspconfig name, mapped to a Mason package through mason-lspconfig.
local PREFERRED_SERVER = {
    c = "clangd", cpp = "clangd", objc = "clangd", objcpp = "clangd",
    go = "gopls", gomod = "gopls",
    python = "pyright",
    javascript = "ts_ls", javascriptreact = "ts_ls",
    typescript = "ts_ls", typescriptreact = "ts_ls",
    lua = "lua_ls",
    rust = "rust_analyzer",
    java = "jdtls",
    kotlin = "kotlin_language_server",
    ruby = "ruby_lsp",
    php = "intelephense",
    cs = "omnisharp",
    swift = "sourcekit",
    zig = "zls",
    sh = "bashls",
    html = "html", css = "cssls", json = "jsonls", yaml = "yamlls",
    dockerfile = "dockerls",
    terraform = "terraformls",
    elixir = "elixirls",
    haskell = "hls",
    scala = "metals",
    dart = "dartls",
    ocaml = "ocamllsp",
    nix = "nil_ls",
    vim = "vimls",
}

local function install_parser(ft, lang)
    if has_parser(ft) then
        return { language = lang, status = "already installed" }
    end
    local okts, ts = pcall(require, "nvim-treesitter")
    if not okts or type(ts.install) ~= "function" then
        return { language = lang, status = "skipped",
            note = "nvim-treesitter is not on the runtimepath; install the parser by hand" }
    end
    local available = {}
    pcall(function()
        for _, l in ipairs(ts.get_available()) do available[l] = true end
    end)
    if next(available) and not available[lang] then
        return { language = lang, status = "unsupported",
            note = "nvim-treesitter has no parser named " .. lang }
    end
    local task
    local okstart, start_err = pcall(function() task = ts.install({ lang }) end)
    if not okstart or type(task) ~= "table" or type(task.await) ~= "function" then
        return { language = lang, status = "failed",
            note = "could not start the install: " .. tostring(start_err or task) }
    end
    local timer = vim.uv.new_timer()
    local aerr, done = await(function(resume)
        timer:start(INSTALL_PARSER_MS, 0, vim.schedule_wrap(function()
            resume("timed out")
        end))
        task:await(function(e, r) resume(e, r) end)
    end)
    timer:stop()
    timer:close()
    if aerr then
        return { language = lang, status = "failed", note = tostring(aerr) }
    end
    -- Neovim caches "no such parser"; a fresh add() picks the new .so up.
    pcall(vim.treesitter.language.add, lang)
    if has_parser(ft) then
        return { language = lang, status = "installed" }
    end
    return { language = lang, status = "failed",
        note = done == false and "nvim-treesitter reported the install as failed"
            or "install finished but the parser still does not load" }
end

local function attached_client(root, ft)
    local files = vim.fn.systemlist({ "git", "-C", root,
        "ls-files", "--cached", "--others", "--exclude-standard" })
    if vim.v.shell_error ~= 0 then
        files = vim.tbl_map(function(f) return f:sub(#root + 2) end,
            vim.fn.globpath(root, "**/*", true, true))
    end
    local sample
    for _, rel in ipairs(files) do
        if vim.filetype.match({ filename = rel }) == ft then
            sample = rel
            break
        end
    end
    if not sample then
        return nil, "no " .. ft .. " file in the workspace to try"
    end
    -- Server configs explain a refusal to start through vim.notify
    -- ("cargo not found"); collect those so the reply says why.
    local notices, orig_notify, orig_once = {}, vim.notify, vim.notify_once
    local function collect(msg, level)
        if type(msg) == "string" and (level or 0) >= vim.log.levels.WARN then
            notices[#notices + 1] = msg:gsub("%s+", " ")
        end
    end
    vim.notify = function(msg, level, opts)
        collect(msg, level)
        return orig_notify(msg, level, opts)
    end
    vim.notify_once = function(msg, level, opts)
        collect(msg, level)
        return orig_once(msg, level, opts)
    end
    local okb, bufnr = pcall(load_buf, root .. "/" .. sample)
    local client
    if okb then
        -- The sample may have been loaded before the server existed (the
        -- open_workspace probe does that); re-setting the filetype fires
        -- FileType again so vim.lsp.enable's autocmd gets a second chance.
        if #vim.lsp.get_clients({ bufnr = bufnr }) == 0 then
            pcall(function() vim.bo[bufnr].filetype = ft end)
        end
        local deadline = vim.uv.now() + INSTALL_ATTACH_MS
        while vim.uv.now() < deadline do
            local clients = vim.lsp.get_clients({ bufnr = bufnr })
            if #clients > 0 then
                client = clients[1].name
                break
            end
            sleep(200)
        end
    end
    vim.notify, vim.notify_once = orig_notify, orig_once
    if client then
        return client
    end
    if not okb then
        return nil, "could not load " .. sample
    end
    local why = "no client attached to " .. sample .. " within "
        .. (INSTALL_ATTACH_MS / 1000) .. "s"
    if #notices > 0 then
        why = why .. ": " .. table.concat(notices, "; ")
    else
        why = why .. "; the server's config may need a toolchain on PATH "
            .. "(rust_analyzer wants cargo, jdtls a JDK); see " .. vim.lsp.get_log_path()
    end
    return nil, why
end

local function install_server(ft, wanted, root)
    local okreg, registry = pcall(require, "mason-registry")
    local okml, mlsp = pcall(require, "mason-lspconfig")
    if not okreg or not okml then
        return { status = "skipped",
            note = "mason.nvim and mason-lspconfig.nvim are needed to install servers; "
                .. "install one by hand and enable it with vim.lsp.enable()" }
    end
    local maps = mlsp.get_mappings()
    -- Resolve the wanted server: an explicit name may be a Mason package or
    -- an lspconfig name; otherwise the preferred server for the filetype,
    -- else whatever Mason offers for it.
    local candidates = {}
    pcall(function()
        candidates = mlsp.get_available_servers({ filetype = ft })
    end)
    table.sort(candidates)
    local lspname, package
    if wanted and wanted ~= "" then
        if maps.package_to_lspconfig[wanted] then
            package, lspname = wanted, maps.package_to_lspconfig[wanted]
        elseif maps.lspconfig_to_package[wanted] then
            lspname, package = wanted, maps.lspconfig_to_package[wanted]
        else
            return { status = "unknown",
                note = ("Mason has no package or server named %s; servers for %s: %s")
                    :format(wanted, ft, #candidates > 0 and table.concat(candidates, ", ") or "none") }
        end
    else
        lspname = PREFERRED_SERVER[ft]
        if not lspname or not maps.lspconfig_to_package[lspname] then
            -- An already enabled config for this filetype wins over a fresh pick.
            for _, name in ipairs(enabled_lsp_configs_for(ft)) do
                if maps.lspconfig_to_package[name] then
                    lspname = name
                    break
                end
            end
        end
        if not lspname or not maps.lspconfig_to_package[lspname] then
            lspname = candidates[1]
        end
        if not lspname then
            return { status = "unsupported",
                note = "Mason offers no language server for filetype " .. ft }
        end
        package = maps.lspconfig_to_package[lspname]
    end
    local out = { package = package, lspconfig = lspname }
    if #candidates > 1 then
        out.alternatives = vim.tbl_filter(function(c) return c ~= lspname end, candidates)
    end
    local pkg
    local okp = pcall(function() pkg = registry.get_package(package) end)
    if not okp or not pkg then
        out.status = "unknown"
        out.note = "Mason registry has no package " .. package
        return out
    end
    if pkg:is_installed() then
        out.status = "already installed"
    else
        await(function(resume)
            pcall(registry.refresh, function() resume() end)
        end)
        local timer = vim.uv.new_timer()
        local timed_out = await(function(resume)
            timer:start(INSTALL_SERVER_MS, 0, vim.schedule_wrap(function()
                resume(true)
            end))
            local okh, herr = pcall(function()
                pkg:install():once("closed", vim.schedule_wrap(function() resume(false) end))
            end)
            if not okh then
                out.start_error = tostring(herr)
                resume(false)
            end
        end)
        timer:stop()
        timer:close()
        if timed_out then
            out.status = "failed"
            out.note = "install did not finish within " .. (INSTALL_SERVER_MS / 60000) .. " minutes"
            return out
        end
        if not pkg:is_installed() then
            out.status = "failed"
            out.note = (out.start_error or "Mason reported the install as failed")
                .. "; see :MasonLog (" .. vim.fn.stdpath("log") .. "/mason.log)"
            out.start_error = nil
            return out
        end
        out.status = "installed"
    end
    -- mason-lspconfig enables freshly installed servers itself when its
    -- automatic_enable is on; doing it here too is idempotent and covers
    -- the "already installed but never enabled" case.
    pcall(vim.lsp.enable, lspname)
    local cmd = vim.tbl_get(vim.lsp.config, lspname, "cmd")
    if type(cmd) == "table" and type(cmd[1]) == "string" and vim.fn.executable(cmd[1]) == 0 then
        out.attached = false
        out.note = cmd[1] .. " is not executable from this Neovim (Mason's bin dir "
            .. "is added to PATH by mason.setup(); is that in the config?)"
        return out
    end
    if type(root) == "string" and root ~= "" then
        local client, why = attached_client(root, ft)
        if client then
            out.attached = client
        else
            out.attached = false
            out.note = why
        end
    end
    return out
end

local function install_language(args)
    local ft = args.language
    if type(ft) ~= "string" or ft == "" then
        err("missing required argument: language")
    end
    ft = ft:lower()
    -- Accept a file extension or a treesitter name too ("ts", "cpp", "c++").
    ft = vim.filetype.match({ filename = "x." .. ft }) or ft
    local lang = vim.treesitter.language.get_lang(ft) or ft
    local result = { language = ft }
    if args.parser ~= false then
        result.parser = install_parser(ft, lang)
    else
        result.parser = { status = "skipped" }
    end
    if args.server ~= "none" then
        result.server = install_server(ft, args.server, args.root)
    else
        result.server = { status = "skipped" }
    end
    result.note = "installed pieces live in Neovim's data directory and survive restarts; "
        .. "add them to the editor config's ensure_installed lists to keep them on a fresh machine"
    return result
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
    await = await,
    sleep = sleep,
    err = err,
    load_buf = load_buf,
    resolve_symbol = resolve_symbol,
    rel_path = rel_path,
    disk_fingerprint = disk_fingerprint,
    symbol_index = symbol_index,
    innermost_entry = innermost_entry,
    decl_line = decl_line,
}
return M
