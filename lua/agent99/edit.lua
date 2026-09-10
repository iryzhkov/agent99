-- The edit family: symbol-addressed replacements and inserts, the ledger
-- that undoes them, code actions, renames, file lifecycle and moving symbols
-- between files. Every edit ends in finish_edit / post_edit_report, which
-- format the region, organize imports, wait for the language servers to
-- re-publish, and reply with only the diagnostics the edit introduced.

local M = {}

local core = require("agent99.core")
local index = require("agent99.index")
local err, await, sleep, load_buf, rel_path = core.err, core.await, core.sleep, core.load_buf, core.rel_path
local assert_writable = core.assert_writable
local get_client, request, client_for, write_buf = core.get_client, core.request, core.client_for, core.write_buf
local make_position, resync_open_buffers, save_all = core.make_position, core.resync_open_buffers, core.save_all
local notify_watched_files, dialect_note = core.notify_watched_files, core.dialect_note
local position_params, fresh_buf, enabled_lsp_configs_for =
    core.position_params, core.fresh_buf, core.enabled_lsp_configs_for
local resolve_symbol, doc_block_start, decl_block_top =
    index.resolve_symbol, index.doc_block_start, index.decl_block_top
local closure = require("agent99.closure")
local cap = require("agent99.cap")

-- Neovim 0.12 moved the diff to vim.text.diff and deprecated vim.diff; one
-- name for it here keeps the rest of the file indifferent to the version.
---@diagnostic disable-next-line: deprecated
local text_diff = (vim.text and vim.text.diff) or vim.diff

-- A symbol edit whose target lines overlap the region a request in
-- progress owns as its PRIMARY edit target (the one only the <replacement>
-- reply is supposed to touch, per the tool guide) collides with whatever
-- that reply is about to write. Refusing it here, instead of letting
-- apply_lines silently drop the losing side later, gives the agent an
-- immediate, actionable error instead of a same-run surprise.
local function primary_region_conflict(bufnr, first, last)
    local ok, req = pcall(require, "agent99.request")
    if not ok then
        return nil
    end
    local pfirst, plast = req.primary_region(bufnr)
    if not pfirst or last < pfirst or first > plast then
        return nil
    end
    return ("lines %d-%d overlap %d-%d, the primary edit region of the request "
        .. "in progress. Make this change through the <replacement> reply instead "
        .. "of a symbol edit tool.")
        :format(first, last, pfirst, plast)
end

-- The format switch as setup(), AGENT99_FORMAT or a tool call may spell it,
-- reduced to false, "range" or "file". Anything unrecognized is off, so a
-- typo cannot turn formatting on.
local function normalize_format(value)
    if value == true or value == "range" or value == "on" or value == "true" then
        return "range"
    end
    if value == "file" then
        return "file"
    end
    return false
end

-- Fresh diagnostics right after an edit, returned inside the edit tool's
-- own result so problems surface without an extra round.
-- Post-edit report. Before the edit, diag_snapshot() records every error
-- and warning (all buffers) keyed by file, severity and message - not by
-- line, so an edit that shifts code does not make old problems look new.
-- After the edit, post_edit_report() waits for the servers to re-publish,
-- optionally runs linters, then splits what it sees into new, fixed and
-- pre-existing, so the model reads what its edit caused and nothing else.
local function post_edit_options(args)
    local ok, config = pcall(require, "agent99.config")
    local opts = ok and config.options and config.options.post_edit
    local merged = vim.tbl_deep_extend("force", {
        wait_ms = 4000,
        settle_ms = 300,
        wait = true,
        commands = {},
        nvim_lint = true,
        lint_timeout_ms = 30000,
        -- Off by default: a server's formatter rewrites whitespace the caller
        -- chose on purpose often enough that formatting is opt-in, through
        -- setup(), AGENT99_FORMAT, or the tool call's own `format`.
        format = false,
        organize_imports = true,
    }, opts or {})
    local env = os.getenv("AGENT99_FORMAT")
    if env and env ~= "" then
        merged.format = env
    end
    if type(args) == "table" and args.format ~= nil then
        merged.format = args.format
    end
    merged.format = normalize_format(merged.format)
    -- wait=false defers the verdict to the next reply; the environment
    -- switch serves the standalone server, the argument one call.
    local wait_env = os.getenv("AGENT99_POST_EDIT_WAIT")
    if wait_env == "0" or wait_env == "false" or wait_env == "off" then
        merged.wait = false
    elseif wait_env and wait_env ~= "" then
        merged.wait = true
    end
    if type(args) == "table" and args.wait ~= nil then
        merged.wait = args.wait ~= false
    end
    return merged
end

-- Servers whose only formatting is whole-file and canonical (gofmt), so
-- formatting the file after an edit never produces an unrelated diff.
local FILE_FORMAT_OK = { go = true }

-- How long a server command gets to do its work before the reply goes out.
local COMMAND_WAIT_MS = 2000

-- Run a server command and wait, bounded, for what it does. exec_cmd only
-- sends workspace/executeCommand; the edit the command makes arrives later,
-- as a workspace/applyEdit request from the server, so returning right
-- after the send would report "applied" about a buffer that has not
-- changed yet and, headless, save it before it does. Returns whether the
-- server answered the command in time and the list of buffers that
-- changed meanwhile (freshly loaded ones included).
local function exec_command_and_wait(client, cmd, bufnr, wait_ms)
    local ticks = {}
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(b) then
            ticks[b] = vim.api.nvim_buf_get_changedtick(b)
        end
    end
    local function changed()
        local out = {}
        for _, b in ipairs(vim.api.nvim_list_bufs()) do
            if vim.api.nvim_buf_is_loaded(b)
                and ticks[b] ~= vim.api.nvim_buf_get_changedtick(b) then
                out[#out + 1] = b
            end
        end
        return out
    end
    -- A command the client itself implements runs synchronously inside
    -- exec_cmd, and one the server never registered is dropped with a
    -- warning; neither will ever call the handler, so neither is waited on.
    local name = type(cmd) == "table" and cmd.command or nil
    local provider = (client.server_capabilities or {}).executeCommandProvider
    local offered = type(provider) == "table" and provider.commands or {}
    local answered = name == nil
        or client.commands[name] ~= nil or vim.lsp.commands[name] ~= nil
        or not vim.list_contains(offered, name)
    local ok = pcall(function()
        client:exec_cmd(cmd, { bufnr = bufnr }, function() answered = true end)
    end)
    if not ok then return false, {} end
    local waited, grace = 0, nil
    while waited < (wait_ms or COMMAND_WAIT_MS) do
        local bufs = changed()
        if #bufs > 0 then return true, bufs end
        -- A server usually sends its applyEdit and waits for the answer
        -- before it replies to the command, but not every one does: give
        -- the edit a moment more after the reply before deciding nothing came.
        if answered then
            grace = (grace or 0) + 50
            if grace > 200 then return true, {} end
        end
        sleep(50)
        waited = waited + 50
    end
    return answered, changed()
end

-- Tell the ledger how a change above the recorded edits (an import block
-- that grew or shrank) moved them, so an entry recorded earlier in the
-- same buffer keeps pointing at the text it wrote and a later undo of it
-- is not refused as "changed since".
local function ledger_absorb(bufnr, before_lines, after_lines)
    local hunks = text_diff(
        table.concat(before_lines, "\n") .. "\n",
        table.concat(after_lines, "\n") .. "\n",
        { result_type = "indices" })
    if type(hunks) ~= "table" or #hunks == 0 then return end
    local ledger = require("agent99.edits")
    -- Bottom-up, in the old text's numbering: each hunk moves what sits
    -- below it, and a lower hunk's shift never carries an entry above a
    -- higher hunk's footprint.
    for i = #hunks, 1, -1 do
        local start_a, count_a, count_b = hunks[i][1], hunks[i][2], hunks[i][4]
        local to = count_a > 0 and (start_a + count_a - 1) or start_a
        ledger.shift(bufnr, to, count_b - count_a)
    end
end

-- Defined below, next to the format pass that shares them.
local indent_profile

-- The line an import pass kept and re-indented, or nil when it re-indented
-- nothing. Organizing imports adds, removes and reorders lines; it has no
-- business changing the indentation of the ones it keeps, and tsserver
-- rewrote a 2-space import block to 4 on every edit of every file, which no
-- format setting switches off because this pass is not the format pass.
--
-- Lines are paired by their own text, occurrence by occurrence: the k-th
-- line reading `}` before the pass is the k-th one after it, so long as the
-- pass neither added nor removed a line of that text. A text whose count
-- changed cannot be paired and is left alone, which is the churn the pass is
-- entitled to. Judging each line against the first occurrence of its text
-- instead read a file with `}` at two depths - every Go, TypeScript and Lua
-- file there is - as a re-indentation, and reverted an import pass that had
-- changed nothing but the imports.
local function reindented_kept_line(before_lines, after_lines)
    local function indents_by_text(lines)
        local by_text = {}
        for _, l in ipairs(lines) do
            local text = vim.trim(l)
            if text ~= "" then
                local seen = by_text[text] or {}
                seen[#seen + 1] = l:match("^[ \t]*")
                by_text[text] = seen
            end
        end
        return by_text
    end
    local was, now = indents_by_text(before_lines), indents_by_text(after_lines)
    for text, indents in pairs(was) do
        local after_indents = now[text]
        if after_indents and #after_indents == #indents then
            for k, indent in ipairs(indents) do
                if after_indents[k] ~= indent then
                    return text
                end
            end
        end
    end
    return nil
end

-- Files whose import-polish refusal has already been explained this session.
local imports_note_said = {}

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
    local before_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local applied, note = false, nil
    if action.edit then
        pcall(vim.lsp.util.apply_workspace_edit, action.edit, client.offset_encoding)
        applied = true
    end
    if action.command then
        local cmd = type(action.command) == "table" and action.command or action
        local answered, changed = exec_command_and_wait(client, cmd, bufnr)
        if #changed > 0 then
            applied = true
        elseif not answered then
            note = ("the server's organize-imports command had not answered after %d ms; "
                .. "the imports may still change"):format(COMMAND_WAIT_MS)
        end
    end
    if applied then
        -- The same guard the format pass has: a server that re-indents to a
        -- width the file does not use turns every edit into a whole-file
        -- diff, and undo_edit runs this pass again after restoring, so even
        -- a correct undo put the rewrite back.
        local after_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        local reindented = reindented_kept_line(before_lines, after_lines)
        if reindented then
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, before_lines)
            -- This is a fact about the file and its server rather than about
            -- the edit, so it is the same on every edit to that file: it went
            -- out on nine consecutive replies, each quoting a different line
            -- of the same import block, and none of them was a decision the
            -- caller could act on twice.
            local name = vim.api.nvim_buf_get_name(bufnr)
            if imports_note_said[name] then return false end
            imports_note_said[name] = true
            return false, ("the imports were left as they were: organizing them re-indented "
                .. "lines it did not otherwise change (%q), which would have rewritten the "
                .. "block in a width this file does not use. This holds for every edit to "
                .. "this file, and is said once per file per session"):format(reindented:sub(1, 40))
        end
        ledger_absorb(bufnr, before_lines, after_lines)
    end
    return applied, note
end

-- How a block of lines is indented: how many lines start with a tab, how
-- many with spaces, how many distinct space widths there are, and the
-- step between those widths that most of the lines follow. The step is
-- measured between the widths rather than from column zero, so a region
-- that sits inside a nested block reports the file's unit and not the
-- depth it starts at.
function indent_profile(lines)
    local tabs, spaces, counts = 0, 0, {}
    for _, line in ipairs(lines) do
        local ws, first = line:match("^(%s+)(%S)")
        -- A comment continuation line (" * ..." in JSDoc and Javadoc) sits
        -- one column in; counting it makes the unit look like one space, the
        -- "one space per level" bug. Skip it and the odd lone-space line.
        if ws and first ~= "*" then
            if ws:sub(1, 1) == "\t" then
                tabs = tabs + 1
            else
                spaces = spaces + 1
                if #ws > 1 then counts[#ws] = (counts[#ws] or 0) + 1 end
            end
        end
    end
    local sorted = vim.tbl_keys(counts)
    table.sort(sorted)
    -- The candidates are the gaps between the widths that occur (and the
    -- first width itself). The step is the largest candidate that divides
    -- the width of nearly every indented line: one paren-aligned
    -- continuation at width 6 in a 4-space file must not turn the unit
    -- into 2, which the smallest gap alone would do, and the formatter
    -- would then re-indent to it.
    local total, candidates, smallest = 0, {}, nil
    for i, w in ipairs(sorted) do
        total = total + counts[w]
        local gap = i == 1 and w or (w - sorted[i - 1])
        if gap > 1 then
            candidates[gap] = true
            if not smallest or gap < smallest then smallest = gap end
        end
    end
    local step = nil
    for cand in pairs(candidates) do
        local covered = 0
        for _, w in ipairs(sorted) do
            if w % cand == 0 then covered = covered + counts[w] end
        end
        if covered * 5 >= total * 4 and (not step or cand > step) then
            step = cand
        end
    end
    return { tabs = tabs, spaces = spaces, step = step or smallest, levels = #sorted }
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
    local profile = indent_profile(vim.api.nvim_buf_get_lines(bufnr, 0, 2000, false))
    if profile.tabs == 0 and profile.spaces == 0 then
        local sw = vim.bo[bufnr].shiftwidth
        return {
            insertSpaces = vim.bo[bufnr].expandtab,
            tabSize = sw > 0 and sw or vim.bo[bufnr].tabstop
        }
    end
    if profile.tabs > profile.spaces then
        return { insertSpaces = false, tabSize = vim.bo[bufnr].tabstop }
    end
    return { insertSpaces = true, tabSize = profile.step or 4 }
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
    local hunks = text_diff(
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
        -- first == nil means keep nothing: the whole format pass is being
        -- taken back because it changed something it had no business
        -- changing (see format_damage).
        if first and from <= last and to >= first then
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

-- Every string literal in `text`, in order, as the parser for `lang` sees
-- them. Formatting is allowed to rearrange the whitespace between tokens;
-- what is inside a literal is content, not layout. Returns nil when there
-- is no parser for the language, so the caller can tell "nothing changed"
-- apart from "nothing was checked".
local function string_literals(text, lang)
    if not lang then return nil end
    local ok, parser = pcall(vim.treesitter.get_string_parser, text, lang)
    if not ok or not parser then return nil end
    local okp, trees = pcall(parser.parse, parser)
    if not okp or type(trees) ~= "table" or not trees[1] then return nil end
    local out = {}
    local function walk(node)
        local kind = node:type()
        if kind:find("string") or kind:find("char_literal") or kind:find("heredoc") then
            -- A template literal holds code as well as text. Its
            -- interpolations are ordinary expressions and a formatter may
            -- respace them; only the literal chunks around them are content.
            local parts, interpolated = {}, false
            for child in node:iter_children() do
                local child_kind = child:type()
                if child_kind:find("interpolation") or child_kind:find("substitution")
                    or child_kind:find("expansion") then
                    interpolated = true
                else
                    parts[#parts + 1] = child
                end
            end
            if not interpolated then
                out[#out + 1] = vim.treesitter.get_node_text(node, text)
                return
            end
            for _, part in ipairs(parts) do
                out[#out + 1] = vim.treesitter.get_node_text(part, text)
            end
            return
        end
        for child in node:iter_children() do walk(child) end
    end
    walk(trees[1]:root())
    return out
end

-- What a format pass did beyond respacing code, or nil when it did only the
-- job it is there for. Both cases below have been seen from real servers:
--
--   * the formatter rewrites the inside of a string literal, so an embedded
--     shell script silently loses the indentation that is part of it;
--   * the formatter ignores the indent options it was handed and re-indents
--     the region to its own default, which rewrites every line of a symbol
--     in a file that uses a different width.
--
-- Neither is something the caller asked for, and both are invisible in a
-- reply that says "formatted", so the caller gets the edit as written
-- instead and a line saying why the formatter was refused.
local function format_damage(bufnr, before_lines, first, last)
    local after_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local before_text = table.concat(before_lines, "\n")
    local after_text = table.concat(after_lines, "\n")
    if before_text == after_text then return nil end
    local lang = vim.treesitter.language.get_lang(vim.bo[bufnr].filetype)
    local was = string_literals(before_text, lang)
    local now = was and string_literals(after_text, lang)
    if was and now and table.concat(was, "\0") ~= table.concat(now, "\0") then
        return "the formatter changed the text inside a string literal"
    end
    local file = indent_profile(before_lines)
    if file.step then
        local region = indent_profile(vim.list_slice(after_lines,
            math.max(1, first), math.min(last, #after_lines)))
        -- One indent width in the region says nothing: it is the depth the
        -- region sits at. Two or more give the unit the formatter used.
        if region.step and region.levels > 1 and region.step ~= file.step then
            return ("the formatter re-indented the region in steps of %d in a %d-space file")
                :format(region.step, file.step)
        end
    end
    return nil
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
                -- A range formatter is asked about a range and is free to
                -- answer with anything: qmlls replies with edits for the
                -- whole document. Confine those exactly as a whole-file
                -- format is confined, so an edit never drags a file-wide
                -- reflow along with it.
                local before_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
                pcall(vim.lsp.util.apply_text_edits, edits, bufnr, client.offset_encoding)
                return confine_format(bufnr, before_lines, first, last)
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


-- How much of the polish diff the reply carries before it becomes a tally.
local POLISH_DIFF_LINES = 40

-- Where a region ended up after polishing, measured from the diff of the
-- buffer rather than from an extmark placed around it.
--
-- Extmarks are the obvious anchor and the wrong one: a server that answers
-- a range format with edits covering the whole document (qmlls does)
-- replaces every line, which collapses every mark in the buffer to the top.
-- The region then reads as "line 1 to the end of the file", which is a lie
-- in the reply and worse than a lie in the ledger, where it makes undo
-- replace the whole file with the few lines the edit had written.
--
-- Returns the region's first and last line in the new text, plus the old
-- lines below it that polishing also changed; the ledger folds those into
-- the edit so an undo puts them back with it.
local function map_region(before_lines, after_lines, first, last)
    local hunks = text_diff(
        table.concat(before_lines, "\n") .. "\n",
        table.concat(after_lines, "\n") .. "\n",
        { result_type = "indices" })
    if type(hunks) ~= "table" or #hunks == 0 then
        return first, last, {}
    end
    -- shift: lines added or removed above the region, which move it.
    -- grow: lines added or removed inside it or below it within reach.
    -- reach: the last old line polishing touched at or after the region.
    local shift, grow, reach = 0, 0, last
    for _, h in ipairs(hunks) do
        local start_a, count_a, count_b = h[1], h[2], h[4]
        -- A hunk with count_a == 0 is an insertion sitting after old line
        -- start_a, so its footprint in the old text is that one position.
        local to = count_a > 0 and (start_a + count_a - 1) or start_a
        local delta = count_b - count_a
        if to < first then
            shift = shift + delta
        else
            grow = grow + delta
            if to > reach then reach = to end
        end
    end
    local extra_old = {}
    for i = last + 1, reach do extra_old[#extra_old + 1] = before_lines[i] end
    return first + shift, reach + shift + grow, extra_old
end

-- After an edit wrote `count` lines at `first`, format that region and
-- organize imports (both optional). Returns where the region ended up
-- (imports added above it shift it), a list of what was done, the old
-- lines a formatter reached below the region, and an info table holding
-- where the written text now sits, the diff of what polishing changed,
-- and the reason a format pass was refused when one was.
local function polish_after_edit(bufnr, first, count, opts)
    local done, info = {}, {}
    if not (opts.format or opts.organize_imports) then
        return first, count, done, nil, info
    end
    if not client_for(bufnr, "textDocument/didOpen") then
        return first, count, done, nil, info
    end
    local last = first + count - 1
    local before_polish = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    if opts.format and count > 0 then
        if format_region(bufnr, first, last, opts.format) then
            local harm = format_damage(bufnr, before_polish, first, last)
            if harm then
                confine_format(bufnr, before_polish, nil, nil)
                info.format_skipped = harm ..
                    ", so its pass was taken back; the text is in the file as it was written"
            else
                done[#done + 1] = "formatted"
            end
        end
    end
    -- Where the written text sits once the format pass is settled, before
    -- imports can move it: that is the region the reply is about.
    local after_format = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local edit_first, edit_last = map_region(before_polish, after_format, first, last)
    if opts.organize_imports then
        local organized, note = organize_imports(bufnr)
        if organized then
            done[#done + 1] = "organized imports"
            local after_imports = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            edit_first, edit_last = map_region(after_format, after_imports, edit_first, edit_last)
        end
        info.imports_note = note
    end
    if count > 0 and edit_last >= edit_first then
        info.edit_first, info.edit_last = edit_first, edit_last
    end
    -- What polishing changed, so "formatted" is a statement the caller can
    -- read rather than one it has to go and verify with git diff.
    local after = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    if #done > 0 then
        local diff = text_diff(
            table.concat(before_polish, "\n") .. "\n",
            table.concat(after, "\n") .. "\n",
            { result_type = "unified", ctxlen = 1 })
        if type(diff) == "string" and diff ~= "" then
            local lines = vim.split(diff:gsub("\n$", ""), "\n", { plain = true })
            if #lines > POLISH_DIFF_LINES then
                local extra = #lines - POLISH_DIFF_LINES
                lines = vim.list_slice(lines, 1, POLISH_DIFF_LINES)
                lines[#lines + 1] = ("… +%d more diff lines"):format(extra)
            end
            info.diff = lines
        end
    end
    -- The ledger's region: the written text plus whatever polishing changed
    -- below it (a formatter drops the blank line after a function that
    -- shrank), so an undo does not restore the region and leave the
    -- formatter's change standing.
    local ledger_first, ledger_last, extra_old = map_region(before_polish, after, first, last)
    local total = vim.api.nvim_buf_line_count(bufnr)
    if ledger_last > total then ledger_last = total end
    if ledger_first < 1 or ledger_last < ledger_first - 1 then
        return first, count, done, {}, info
    end
    return ledger_first, ledger_last - ledger_first + 1, done, extra_old, info
end

-- Pre-existing diagnostics in the edited file are listed rather than counted,
-- up to this many; past it the rest become a tally.
local PREEXISTING_LISTED = 10
-- full_diagnostics=true exists to defeat that cap, so its list is far
-- longer; it is still a list with an end, and the reply says so rather than
-- claiming "all listed" above a "+92 more".
local FULL_PREEXISTING_LISTED = 60
-- Hints in the edited files are named rather than dropped, but a server that
-- hints on every unused local would fill a reply on its own.
local HINTS_LISTED = 5

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

-- Defined further down; a snapshot must not be taken while a verdict is
-- still owed, or the owed diagnostics would be charged to the next edit.
local flush_deferred

local function diag_snapshot()
    if flush_deferred then flush_deferred(true) end
    local counts = {}
    for _, d in ipairs(vim.diagnostic.get(nil)) do
        if d.severity <= vim.diagnostic.severity.WARN then
            local sig = diag_signature(d)
            counts[sig] = (counts[sig] or 0) + 1
        end
    end
    return counts
end

-- ---------------------------------------------------------------------------
-- The verdict on an edit: when the servers have said all they will say.
--
-- A push-only server (lua_ls is one) does not republish when an edit left
-- its diagnostics as they were, so silence alone cannot be told apart from
-- "still analyzing", and every clean edit used to cost the whole wait_ms
-- ceiling. Three things resolve that:
--
--  * A barrier: one cheap request per server, sent with the change. A server
--    answers it only once it has taken the change in, so the reply is proof
--    the edit was seen, and settle_ms of silence after it means no
--    diagnostics are coming. The reply itself is discarded. (Asking
--    pull-capable servers for textDocument/diagnostic instead was tried and
--    dropped: pyright answers the pull and pushes as well, and every
--    diagnostic then appeared twice.)
--  * Learning: how long after the barrier reply a server's diagnostics
--    arrived is recorded per workspace and server, and the settle used for
--    that server follows the longest lag seen with a margin, once enough
--    publishes have been observed. Diagnostics that turn up after a report
--    went out count as a miss and raise it at once.
--  * Late delivery: whatever arrives after a report was sent is carried in
--    the next reply, so a wrong estimate delays attribution rather than
--    losing the diagnostic. With post_edit.wait off the whole report is
--    deferred that way and the edit tool returns as soon as the text is in.
--
-- The barrier alone turned out not to be enough, and the reason is worth
-- keeping: `textDocument/documentSymbol` is answered off the syntax tree,
-- which pyright and tsserver have ready in single-digit milliseconds, while
-- type checking runs on a separate queue and publishes later. So the ack
-- proves the server read the edit, not that it finished thinking about it,
-- and the settle that follows is silence measured before the analysis
-- started. Two things now sit above it:
--
--  * Version stamping (exact): publishDiagnostics carries the version of the
--    text it describes, and Neovim sends the buffer's changedtick as that
--    version. A publish stamped with the version we wrote is the server's own
--    statement that it analyzed this edit. Nothing is inferred from silence,
--    so no settle is waited out at all. Servers that omit the version fall
--    through to the heuristic, and the reply says which basis it had.
--  * Progress (a veto): a workDoneProgress token opened after the change is
--    the server saying outright that it is still working, whatever the clock
--    says. Tokens already open before the edit are somebody else's work.
--
-- Two more ideas, not implemented, in the order they are worth trying if the
-- two above prove insufficient:
--
--  * A semantic barrier for servers that do not stamp versions: pull
--    diagnostics (`textDocument/diagnostic`, LSP 3.17) cannot be answered
--    without analyzing, which is exactly the property documentSymbol lacks.
--    It was tried once and dropped because pyright answers the pull and
--    pushes as well and every diagnostic appeared twice - but that is a
--    deduplication problem, and the fix is to discard the pull's payload and
--    use it purely as the barrier, the way the documentSymbol reply is
--    discarded today. `semanticTokens/full` needs binding information too.
--  * Cross-file: version stamping speaks for the edited buffer only. A move
--    that leaves a stale import in a third file needs that file re-analyzed,
--    which servers do lazily and may not do at all until asked. move_symbols
--    loads those files (ctx.also); a pull diagnostic per file would be the
--    semantic barrier for them, and would have caught the black probe's
--    trans.py breakage at reply time instead of 230 ms later.

-- When each buffer last had diagnostics published, and by which server,
-- from one listener that outlives any single wait.
local last_publish = {}    -- [bufnr] = { at = ms, by = { [client.name] = ms } }

-- Which servers have ever published a diagnostic in this session, by name. A
-- server that has produced none at all is one whose silence certifies
-- nothing: bash-language-server is attached to every shell file, answers
-- every request, and reported nothing for a file holding a deliberate syntax
-- error. Silence from a server that has been reporting all session is
-- evidence; silence from one that has never reported anything is not.
local ever_published = {}  -- [client.name] = true

-- Which files each server has published for, by absolute path, whether the
-- publish carried diagnostics or emptied the list. A publish says the server
-- has an opinion about THAT file and about nothing else, so this is what the
-- hedge above has to be gated on. Gating it on `ever_published` alone flipped
-- every file in a project from honestly hedged to flatly clean the moment one
-- unrelated file got a diagnostic: zls hedged correctly on a file it had
-- never analysed, one edit elsewhere made it publish for a different file,
-- and the same query on the still-unanalysed file came back bare.
local published_for = {}   -- [client.name] = { [path] = true }

local function note_published_for(name, path)
    if not (name and path and path ~= "") then return end
    local per = published_for[name] or {}
    published_for[name] = per
    per[path] = true
end

-- Servers that published in this session and are no longer running. Their
-- diagnostics are still in the editor and nothing is refreshing them, so
-- neither what they said nor what they did not say is current. After gopls
-- was killed an edit still answered "1 errors were there before the edit (1
-- in this file, 0 elsewhere)": a positive claim of cleanliness about the rest
-- of the project, sourced from a server that had stopped existing.
local function stopped_servers()
    local out = {}
    for name in pairs(ever_published) do
        if #vim.lsp.get_clients({ name = name }) == 0 then out[#out + 1] = name end
    end
    table.sort(out)
    return out
end
-- How many change barriers each server has answered, so that "it has reported
-- nothing" is only said of a server that has had a chance to. One is enough:
-- a server that answered a barrier has taken the change in and stayed silent,
-- and a caveat on the first edit of a session is a small price against the
-- first edit being the one that breaks a file and reads as clean.
local edits_acked = {}     -- [client.name] = count
local SILENT_AFTER = 1

-- The document version each server last published diagnostics for, and which
-- servers stamp a version at all. This is the exact signal the settle
-- heuristic was standing in for: `textDocument/publishDiagnostics` carries the
-- version of the text the diagnostics describe, so a publish stamped with the
-- version we just sent is proof the server analyzed THIS edit rather than the
-- one before it. Neovim sends the buffer's changedtick as the version
-- (vim/lsp.lua sets util.buf_versions[bufnr] = changedtick) and then discards
-- params.version in its own handler, so the wrapper below is what recovers it.
-- Neovim's codelens, inlay_hint, semantic_tokens and linked_editing_range all
-- compare against util.buf_versions the same way.
local publish_version = {}  -- [bufnr] = { [client.name] = version }
local stamps_version = {}   -- [client.name] = true once a version is seen

-- Work a server has open that began after our change. gopls, pyright and
-- rust-analyzer all open a workDoneProgress while they analyze, so a token
-- still open is the server saying outright that it has not finished. Only
-- tokens that began after the edit count: a workspace load that was already
-- running is not this edit's business and would otherwise block every wait
-- until its full budget expired.
local progress_open = {}    -- [client.name] = { [token] = began_ms }

local function wrap_publish_handler(client)
    -- Per client, not on the global vim.lsp.handlers table. Client:_resolve_handler
    -- reads `self.handlers[method] or lsp.handlers[method]`, so a per-client entry
    -- is consulted first and needs no load-order luck: wrapping the global table
    -- when agent99 loads did nothing at all, because that ran before vim.lsp had
    -- populated it and the wrap silently no-opped (publish_seen stayed 0 over a
    -- whole smoke run, which is how this was caught).
    if not client or client._agent99_publish_wrapped then return end
    client._agent99_publish_wrapped = true
    client.handlers = client.handlers or {}
    local inner = client.handlers["textDocument/publishDiagnostics"]
        or vim.lsp.handlers["textDocument/publishDiagnostics"]
    if not inner then return end
    client.handlers["textDocument/publishDiagnostics"] = function(lsp_err, params, ctx, cfg)
        -- Every publish, whether or not it carries a version and whether or
        -- not it carries any diagnostics: an empty set for a file is the
        -- server saying it looked at that file and found nothing, which is
        -- the evidence the hedge needs and the thing it cannot infer from a
        -- publish about some other file.
        if params and params.uri then
            local okf, fname = pcall(vim.uri_to_fname, params.uri)
            if okf then note_published_for(client.name, fname) end
        end
        local version = params and params.version
        if version then
            stamps_version[client.name] = true
            local bufnr = params.uri and vim.uri_to_bufnr(params.uri)
            if bufnr then
                local per = publish_version[bufnr] or {}
                publish_version[bufnr] = per
                -- A server may still be working through older changes; the
                -- newest version it has spoken for is the one that counts.
                if (per[client.name] or -1) < version then per[client.name] = version end
            end
        end
        return inner(lsp_err, params, ctx, cfg)
    end
end

vim.api.nvim_create_autocmd("LspAttach", {
    group = vim.api.nvim_create_augroup("agent99_publish_version", { clear = true }),
    callback = function(ev)
        wrap_publish_handler(ev.data and ev.data.client_id
            and vim.lsp.get_client_by_id(ev.data.client_id))
    end,
})

vim.api.nvim_create_autocmd("LspProgress", {
    group = vim.api.nvim_create_augroup("agent99_progress", { clear = true }),
    callback = function(ev)
        local data = ev.data or {}
        local client = data.client_id and vim.lsp.get_client_by_id(data.client_id)
        local token = data.params and data.params.token
        if not (client and token ~= nil) then return end
        local kind = data.params.value and data.params.value.kind
        local open = progress_open[client.name] or {}
        progress_open[client.name] = open
        if kind == "begin" then
            open[token] = vim.uv.now()
        elseif kind == "end" then
            open[token] = nil
        end
    end,
})

-- Whether any of these servers has work open that started after `since`.
local function progress_since(names, since)
    for _, name in ipairs(names or {}) do
        for _, began in pairs(progress_open[name] or {}) do
            if began >= since then return true end
        end
    end
    return false
end

local function client_names_of(diags)
    local names = {}
    for _, d in ipairs(diags or {}) do
        local ns = d.namespace and vim.diagnostic.get_namespace(d.namespace)
        local name = ns and ns.name and ns.name:match("^nvim%.lsp%.(.-)%.%d+")
        if name then names[name] = true end
    end
    return names
end

vim.api.nvim_create_autocmd("DiagnosticChanged", {
    group = vim.api.nvim_create_augroup("agent99_verdict", { clear = true }),
    callback = function(ev)
        local now = vim.uv.now()
        local rec = last_publish[ev.buf] or { by = {} }
        last_publish[ev.buf] = rec
        rec.at = now
        local names = client_names_of(ev.data and ev.data.diagnostics)
        local path = vim.api.nvim_buf_get_name(ev.buf)
        for name in pairs(names) do
            ever_published[name] = true
            -- A publish this server made about this file, which is what says
            -- its silence about the file means something. Recorded here as
            -- well as in the publish handler: a server that attached before
            -- agent99 wrapped its handler still lands here.
            note_published_for(name, path)
        end
        if next(names) == nil then
            -- A cleared set names nobody; credit every attached server.
            for _, c in ipairs(vim.lsp.get_clients({ bufnr = ev.buf })) do
                names[c.name] = true
            end
        end
        for name in pairs(names) do rec.by[name] = now end
    end,
})

-- The servers attached to this buffer, named, when not one of them has ever
-- published anything about THIS FILE; nil once one of them has. Returns the
-- names and how wide the silence is ("at all in this session", or "for this
-- file in this session"), so the caveat says what it actually knows.
--
-- The gate used to be per server: one diagnostic in one file made every other
-- file in the project answer flatly clean, hedge and all, though nothing had
-- looked at them. That is the mechanism by which several other defects read
-- as successes.
local function silent_server(bufnr, names, min_acks)
    if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then return nil end
    min_acks = min_acks or SILENT_AFTER
    local list = {}
    for _, name in ipairs(names or {}) do list[#list + 1] = name end
    if #list == 0 then
        for _, c in ipairs(vim.lsp.get_clients({ bufnr = bufnr })) do list[#list + 1] = c.name end
    end
    if #list == 0 then return nil end
    local path = vim.api.nvim_buf_get_name(bufnr)
    -- How wide the silence is: a server that has published nothing anywhere
    -- all session is a stronger caveat than one that has simply never spoken
    -- about this file, and the two read differently to whoever gets the reply.
    local anywhere = true
    for _, name in ipairs(list) do
        -- Silence before the server has been asked anything says nothing. The
        -- diagnostics tool waits for a publish itself, so it passes 0 and asks
        -- only whether this server has ever said anything about this file.
        if (edits_acked[name] or 0) < min_acks then return nil end
        -- Published for THIS file - with diagnostics or with an empty list -
        -- so its silence about the file now is a verdict rather than an
        -- absence. Published only about other files is not: that is the whole
        -- of what one diagnostic in one file used to prove about all of them.
        -- `last_publish` is deliberately not consulted here: it credits every
        -- server attached to a buffer whenever that buffer's diagnostics are
        -- cleared, whoever cleared them, which is the same over-crediting one
        -- step smaller.
        if (published_for[name] or {})[path] then return nil end
        if ever_published[name] then anywhere = false end
    end
    table.sort(list)
    return table.concat(list, " and "),
        anywhere and "at all in this session" or "for this file in this session"
end

-- Publish lag learned over the session, per workspace root and server: the
-- last few gaps between a server acknowledging a change and publishing
-- diagnostics for it. A ring rather than a running maximum, so one slow
-- moment stops mattering after a handful of ordinary publishes.
local publish_lag = {}    -- [root][client.name] = { lags = { ms, ... }, next = i, n = count }
local last_ack = {}       -- [root][client.name] = ms, the newest barrier reply anywhere
local SETTLE_FLOOR_MS = 100
local LEARN_AFTER = 3
local LAG_RING = 10

local function per_root(tbl, root)
    local t = tbl[root or ""] or {}
    tbl[root or ""] = t
    return t
end

local function note_publish_lag(root, name, lag)
    local e = per_root(publish_lag, root)[name] or { lags = {}, next = 1, n = 0 }
    per_root(publish_lag, root)[name] = e
    e.lags[e.next] = lag
    e.next = e.next % LAG_RING + 1
    e.n = e.n + 1
end

-- The settle to use for these servers: the configured value until enough
-- has been seen of a server, then 1.5x the longest recent publish lag plus
-- 50 ms, never below the floor nor above the ceiling. Several servers: the
-- largest.
local function settle_for(root, names, configured, ceiling)
    local settle = nil
    for _, name in ipairs(names or {}) do
        local e = per_root(publish_lag, root)[name]
        local ms = configured
        if e and e.n >= LEARN_AFTER then
            local worst = 0
            for _, lag in pairs(e.lags) do worst = math.max(worst, lag) end
            ms = math.floor(worst * 1.5 + 50)
        end
        ms = math.max(SETTLE_FLOOR_MS, math.min(ms, ceiling))
        if not settle or ms > settle then settle = ms end
    end
    return settle or configured
end

-- Send the barrier to every server attached to bufnr. Returns the ack
-- table the wait polls: acks[name] is false until that server replied.
local function send_barriers(bufnr, root)
    local acks, names = {}, {}
    local uri = vim.uri_from_bufnr(bufnr)
    for _, c in ipairs(vim.lsp.get_clients({ bufnr = bufnr })) do
        local method, params
        if c:supports_method("textDocument/documentSymbol", bufnr) then
            method = "textDocument/documentSymbol"
            params = { textDocument = { uri = uri } }
        elseif c:supports_method("textDocument/hover", bufnr) then
            method = "textDocument/hover"
            params = { textDocument = { uri = uri }, position = { line = 0, character = 0 } }
        end
        local name = c.name
        local function acked()
            acks[name] = vim.uv.now()
            per_root(last_ack, root)[name] = acks[name]
        end
        if method and c:request(method, params, acked, bufnr) then
            acks[name] = false
            names[#names + 1] = name
        end
    end
    return acks, names
end

local function all_acked(acks)
    local last = nil
    for _, at in pairs(acks) do
        if not at then return nil end
        if not last or at > last then last = at end
    end
    return last
end

-- Whether the servers have said all they will about the change made at
-- `since`: a publish followed by `settle` of quiet, or every barrier
-- answered and `settle` of quiet after the last answer.
local function verdict_in(bufnr, since, acks, settle, names, want_version)
    local now = vim.uv.now()
    -- A server that is telling us it is still working has not finished,
    -- whatever the clock says. This outranks every signal below it.
    if progress_since(names, since) then
        return false, false, "working"
    end
    -- The exact answer, where the servers give it: every server attached to
    -- this buffer that stamps its publishes has now spoken for a version at
    -- least as new as the text we wrote. Nothing is inferred from silence
    -- here, so there is no settle to wait out either.
    if want_version then
        local per = publish_version[bufnr] or {}
        local stamped, all_current = 0, true
        for _, name in ipairs(names or {}) do
            if stamps_version[name] then
                stamped = stamped + 1
                if (per[name] or -1) < want_version then all_current = false end
            end
        end
        if stamped > 0 and stamped == #(names or {}) and all_current then
            return true, true, "version"
        end
    end
    local lp = last_publish[bufnr]
    if lp and lp.at >= since then
        return now - lp.at >= settle, true, "published"
    end
    local acked = all_acked(acks)
    if acked and next(acks) ~= nil then
        return now - acked >= settle, false, "acked"
    end
    return false, false, "waiting"
end

-- Record what a publish on bufnr since `since` says about each server's
-- lag: the gap from that server's newest acknowledgement anywhere in the
-- workspace, since an edit elsewhere can be what changed this buffer's
-- diagnostics. Publishes later than `within` after the acknowledgement are
-- not lessons: that is a server re-checking the workspace on its own
-- schedule (lua_ls does so three seconds after a change), and waiting for
-- those on every edit would cost more than the late delivery does.
local function learn_from(bufnr, root, since, within)
    local lp = last_publish[bufnr]
    if not (lp and lp.at >= since) then return end
    for name, at in pairs(lp.by) do
        local ack = per_root(last_ack, root)[name]
        if at >= since and ack then
            local lag = math.max(0, at - ack)
            if not within or lag <= within then
                note_publish_lag(root, name, lag)
            end
        end
    end
end

-- Wait for the verdict on bufnr, at most wait_ms from `since` (default now).
-- Returns whether diagnostics were published for the change.
local function wait_for_diagnostics(bufnr, root, wait_ms, settle_ms, since, acks, names)
    since = since or vim.uv.now()
    if not acks then acks, names = send_barriers(bufnr, root) end
    -- Read after the barriers: client:request flushes any pending didChange
    -- before it sends, so by now the server has been told about this edit and
    -- buf_versions holds the version it was told about.
    local want_version = vim.lsp.util.buf_versions and vim.lsp.util.buf_versions[bufnr] or nil
    -- Counted here rather than at the end of an edit, so that settling a
    -- buffer before an edit counts too. Gating the "this server has reported
    -- nothing" caveat on three finished edits meant the first edit of a
    -- session never carried it - and the first edit is the one a probe used
    -- to break a shell file, which came back "no new errors or warnings".
    for _, name in ipairs(names or {}) do
        edits_acked[name] = (edits_acked[name] or 0) + 1
    end
    local settle = settle_for(root, names, settle_ms, wait_ms)
    local deadline = since + wait_ms
    local done, published, how = verdict_in(bufnr, since, acks, settle, names, want_version)
    while not done and vim.uv.now() < deadline do
        sleep(50)
        done, published, how = verdict_in(bufnr, since, acks, settle, names, want_version)
    end
    learn_from(bufnr, root, since, nil)
    -- What the wait actually established, which is not the same question as
    -- whether it finished:
    --   "version"    - every server stamped a publish for the text we wrote.
    --                  This is the server's own statement, not an inference.
    --   "published"  - a publish arrived for this buffer and was followed by
    --                  quiet. Good, but the publish may have been for an
    --                  earlier version.
    --   "unmeasured" - the servers answered the barrier and said nothing, and
    --                  none of them has been timed here yet, so the settle was
    --                  a guess and its expiry proves nothing. pyright
    --                  published two errors 230 ms after a reply that had
    --                  already called a move clean, and tsserver 66 ms after
    --                  another; both had answered the barrier at once, because
    --                  documentSymbol comes off the syntax tree while type
    --                  checking runs on another queue.
    --   "timeout"    - the budget ran out with the servers still talking.
    local basis = "timeout"
    if how == "version" then
        basis = "version"
    elseif published then
        basis = "published"
    elseif done then
        basis = "acked"
        for _, name in ipairs(names or {}) do
            local e = per_root(publish_lag, root)[name]
            if not (e and e.n >= LEARN_AFTER) then
                basis = "unmeasured"
                break
            end
        end
    end
    return published, done, basis
end

-- The closure files are asked at the same moment the edited file is, so the
-- two waits overlap instead of running end to end.
local function closure_barriers(also)
    local out = {}
    for b in pairs(also or {}) do
        if vim.api.nvim_buf_is_valid(b) and #vim.lsp.get_clients({ bufnr = b }) > 0 then
            local uri = vim.uri_from_bufnr(b)
            local acks, names, used = {}, {}, nil
            for _, c in ipairs(vim.lsp.get_clients({ bufnr = b })) do
                -- A pull-diagnostics request where the server offers one.
                -- documentSymbol - the barrier the edited file gets - comes
                -- off the syntax tree and is answered long before the server
                -- has type-checked anything, which is how four broken Go
                -- packages passed a wait that had "acknowledged" all four.
                -- textDocument/diagnostic is answered only once the server
                -- has worked out what this file's problems are, so its reply
                -- is a real point to measure the quiet from. The answer
                -- itself is not read: it lands in a namespace of its own and
                -- would be counted twice beside the server's own publish.
                local method, params
                if c:supports_method("textDocument/diagnostic", b) then
                    method = "textDocument/diagnostic"
                    params = { textDocument = { uri = uri } }
                elseif c:supports_method("textDocument/documentSymbol", b) then
                    method = "textDocument/documentSymbol"
                    params = { textDocument = { uri = uri } }
                end
                local name = c.name
                -- Not recorded in last_ack: that ring is how the settle for
                -- the edited file is learned, and a pull answered after a
                -- whole-package type-check would teach it the wrong number.
                if method and c:request(method, params, function()
                        acks[name] = vim.uv.now()
                    end, b) then
                    acks[name] = false
                    names[#names + 1] = name
                    used = method:match("[^/]+$")
                end
            end
            if next(acks) ~= nil then
                out[#out + 1] = { bufnr = b, acks = acks, names = names, method = used }
            end
        end
    end
    return out
end

-- What a server does after an edit, learned per workspace. gopls answers for
-- the file it was told about within a couple of hundred milliseconds and
-- publishes the packages that depend on it about a second later, in a second
-- wave; lua_ls publishes once and never comes back. Waiting out the gopls
-- wave on every lua_ls edit would cost a second for nothing, and not waiting
-- it costs the whole point of the closure - so how long to hold on for is
-- learned from what the server has actually done here, the same way the
-- settle is.
local closure_wave = {}          -- [root][name] = { lag = worst ms seen, quiet = n }
local CLOSURE_GRACE_MS = 1200    -- before anything is known about the server
local CLOSURE_QUIET_AFTER = 3    -- closure waits with no second wave = it has none

local function closure_grace(root, names)
    local grace = 0
    for _, name in ipairs(names or {}) do
        local e = per_root(closure_wave, root)[name]
        local ms
        if e and e.lag then
            ms = math.floor(e.lag * 1.5 + 100)
        elseif e and e.quiet >= CLOSURE_QUIET_AFTER then
            ms = 0
        else
            ms = CLOSURE_GRACE_MS
        end
        if ms > grace then grace = ms end
    end
    return grace
end

-- `lag` is how long after the edit this server's wave arrived, or nil when
-- it never came. A wave that arrives resets the quiet count: a server that
-- has one is not to be written off because three edits in a row changed
-- nothing downstream.
local function note_closure_wave(root, names, lag)
    for _, name in ipairs(names or {}) do
        local e = per_root(closure_wave, root)[name] or { quiet = 0 }
        per_root(closure_wave, root)[name] = e
        if lag then
            e.lag = math.max(e.lag or 0, lag)
            e.quiet = 0
        else
            e.quiet = e.quiet + 1
        end
    end
end

-- Loading a file is not asking it. The four Go packages a return-type change
-- broke were already open in the editor, every one of them had been asked for
-- its diagnostics moments earlier, and the reply still read "no new errors or
-- warnings": gopls had not republished for them by the time the wait on the
-- edited file ended. So the quiet these files are waited out for is counted
-- from the edited file's own publish where there was one - a server that
-- re-checks a package publishes the file it was told about first and the
-- files that depend on it after.

local function wait_for_closure(entries, root, bufnr, since, opts)
    if #entries == 0 then return {} end
    local deadline = since + opts.wait_ms
    for _, e in ipairs(entries) do
        e.settle = settle_for(root, e.names, opts.settle_ms, opts.wait_ms)
        e.grace = closure_grace(root, e.names)
    end
    local function settled(e, from)
        local now = vim.uv.now()
        local lp = last_publish[e.bufnr]
        if lp and lp.at >= from then
            -- The wave arrived. Quiet after it is the ordinary signal.
            e.how = "published"
            return now - lp.at >= e.settle
        end
        local acked = all_acked(e.acks)
        if acked then
            e.how = "quiet"
            return now - from >= e.grace and now - acked >= e.settle
        end
        return false
    end
    local all_done = false
    while not all_done and vim.uv.now() < deadline do
        -- Re-read every round: the edited file's publish may arrive while
        -- this loop is running, and it moves the point the dependents' wave
        -- is measured from.
        local from = since
        local lp = bufnr and last_publish[bufnr]
        if lp and lp.at >= since then from = lp.at end
        all_done = true
        for _, e in ipairs(entries) do
            -- No wanted version: nothing changed these buffers, so the
            -- version the server has already answered for is the current
            -- one, and asking for it would end the wait before the
            -- re-publish this whole pass exists to wait for.
            if not e.done then e.done = settled(e, from) end
            if not e.done then all_done = false end
        end
        if not all_done then sleep(50) end
    end
    local how = {}
    for _, e in ipairs(entries) do
        local lp = last_publish[e.bufnr]
        note_closure_wave(root, e.names, lp and lp.at >= since and (lp.at - since) or nil)
        how[#how + 1] = ("%s %s/%s %s grace=%d settle=%d pub=%s"):format(
            vim.fn.fnamemodify(vim.api.nvim_buf_get_name(e.bufnr), ":t"),
            e.method or "?", table.concat(e.names, ","), e.done and (e.how or "?") or "timeout",
            e.grace, e.settle, lp and tostring(lp.at - since) or "none")
    end
    return how
end

-- Reports not yet delivered: verdicts deferred by wait=false, and
-- diagnostics that arrived after a report went out. Both ride on the next
-- reply, whatever tool produces it.
local deferred = {}   -- [bufnr] = { since, acks, names, before, root, headless, opts, full, label, client }
local watched = {}    -- [bufnr] = { reported_at, after, names, root, label, settle_ms, wait_ms, client }
-- What the next reply takes along, per client: a verdict deferred by one
-- client's wait=false edit belongs to that client, and used to ride out on
-- whichever client's reply left the editor first.
local carries = {}    -- [client] = { late_diagnostics, deferred_verdicts, still_pending }

local function carry_for(id)
    id = id or require("agent99.client").current()
    if not carries[id] then carries[id] = {} end
    return carries[id]
end

local WATCH_MS = 60 * 1000

-- Late diagnostics ride along on whatever reply comes next, and that reply is
-- about something else. They get a budget for the same reason every other
-- list does.
local LATE_DIAGNOSTICS_FILES = 6
local LATE_DIAGNOSTICS_PER_FILE = 8

local function edit_label(kind, bufnr)
    -- Undoing a create_file wipes the buffer, and the entries undone after
    -- it in the same step still name it: labelling threw "Invalid buffer id"
    -- and the caller got an exception instead of its undo report, for an
    -- undo that had in fact succeeded.
    if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
        return ("%s on a file that is gone"):format(kind)
    end
    return ("%s on %s"):format(kind, rel_path(vim.api.nvim_buf_get_name(bufnr)))
end

-- Signature counts for one buffer, the unit the late report diffs.
local function buf_snapshot(bufnr)
    local counts = {}
    if not vim.api.nvim_buf_is_valid(bufnr) then return counts end
    for _, d in ipairs(vim.diagnostic.get(bufnr)) do
        if d.severity <= vim.diagnostic.severity.WARN then
            local sig = diag_signature(d)
            counts[sig] = (counts[sig] or 0) + 1
        end
    end
    return counts
end

-- After a report on bufnr went out, remember what it showed so anything
-- the server adds afterwards can be told apart and delivered.
local function watch_after_report(bufnr, root, names, opts, label, extra)
    -- The report just accounted for every buffer's diagnostics (new errors
    -- elsewhere, the ones that went away), so what the other watched
    -- buffers show now is no longer "late" for their own reports. This
    -- client's reports only: another client has not been shown any of it,
    -- and discharging its watches here is how it came to be told "none new
    -- to this list" about text it had never seen.
    local me = require("agent99.client").current()
    local now = vim.uv.now()
    for b, w in pairs(watched) do
        if b ~= bufnr and w.client == me and vim.api.nvim_buf_is_valid(b) then
            w.after, w.reported_at = buf_snapshot(b), now
            -- And the label with them. It names the reply the next late
            -- report is measured from, so leaving it behind while the
            -- snapshot moved on is how one late report came to name a call
            -- several edits earlier that had already been reverted.
            w.label, w.root = label, root
            w.names = names or w.names
            w.settle_ms, w.wait_ms = opts.settle_ms, opts.wait_ms
        end
    end
    local function watch(b)
        watched[b] = {
            reported_at = now, after = buf_snapshot(b),
            names = names or {}, root = root, label = label,
            settle_ms = opts.settle_ms, wait_ms = opts.wait_ms,
            client = me,
        }
    end
    if bufnr then watch(bufnr) end
    -- Every other file this call wrote, and every file it loaded to ask about
    -- - the closure. A late publish lands in those as readily as in the file
    -- the call was addressed to, and watching only that one is why a move
    -- across four dependents reported the late diagnostics of one of them.
    for b in pairs(extra or {}) do
        if b ~= bufnr and vim.api.nvim_buf_is_valid(b) then watch(b) end
    end
end

-- Diagnostics that arrived on watched buffers since their report: a diff of
-- that buffer against what the report showed, added to the carry.
local function collect_late()
    local now = vim.uv.now()
    for bufnr, w in pairs(watched) do
        local lp = last_publish[bufnr]
        if not vim.api.nvim_buf_is_valid(bufnr) or now - w.reported_at > WATCH_MS then
            watched[bufnr] = nil
        elseif lp and lp.at > w.reported_at then
            local current = buf_snapshot(bufnr)
            local added, gone = {}, 0
            for _, d in ipairs(vim.diagnostic.get(bufnr)) do
                if d.severity <= vim.diagnostic.severity.WARN then
                    local sig = diag_signature(d)
                    if (w.after[sig] or 0) > 0 then
                        w.after[sig] = w.after[sig] - 1
                    else
                        added[#added + 1] = ("%s line %d: %s"):format(
                            vim.diagnostic.severity[d.severity], d.lnum + 1, d.message)
                    end
                end
            end
            for _, n in pairs(w.after) do gone = gone + n end
            if #added > 0 or gone > 0 then
                -- `since_reply` is the reply this delta is measured from, not
                -- a cause: the field used to be called `after` and named the
                -- edit, which read as "this edit did it" and was wrong as
                -- often as it was right - it once named a call that had
                -- already been reverted.
                local item = {
                    since_reply = w.label,
                    file = vim.api.nvim_buf_get_name(bufnr),
                    arrived = ("%d ms after that reply"):format(lp.at - w.reported_at),
                }
                if #added > 0 then item.new = added end
                if gone > 0 then item.gone = gone .. " diagnostics reported then are no longer there" end
                -- To the client whose report this is late for, whoever's
                -- call happens to be running now.
                local into = carry_for(w.client)
                into.late_diagnostics = into.late_diagnostics or {}
                into.late_diagnostics[#into.late_diagnostics + 1] = item
                -- A near miss teaches: the server took a little longer than
                -- the settle allowed, so the settle grows. A publish far
                -- beyond it is the server's own re-check and only delivered.
                local settle = settle_for(w.root, w.names, w.settle_ms, w.wait_ms)
                learn_from(bufnr, w.root, w.reported_at, 2 * settle + 200)
            end
            w.after = current
            w.reported_at = now
        end
    end
end

-- Forward declaration: post_edit_report is defined below and resolves a
-- deferred entry into the report it would have been.
local post_edit_report

-- Deliver deferred verdicts: the ripe ones always, the rest only when
-- `wait` is true (an edit or a diagnostics read is about to take a
-- snapshot, and an unresolved verdict would be charged to it).
function flush_deferred(wait)
    for bufnr, d in pairs(deferred) do
        if not vim.api.nvim_buf_is_valid(bufnr) then
            deferred[bufnr] = nil
        else
            local settle = settle_for(d.root, d.names, d.opts.settle_ms, d.opts.wait_ms)
            local ripe = verdict_in(bufnr, d.since, d.acks, settle, d.names, d.version)
                or vim.uv.now() >= d.since + d.opts.wait_ms
            if ripe or wait then
                deferred[bufnr] = nil
                local opts = vim.tbl_extend("force", d.opts, { wait = true })
                -- As the client that made the edit: the report says what is
                -- new to *its* list, and another client's call happening to
                -- be the one running must not consume or widen it.
                local report = require("agent99.client").as_client(d.client, function()
                    return post_edit_report(bufnr, d.before, d.root, d.headless, opts, d.full,
                        { since = d.since, acks = d.acks, names = d.names, label = d.label,
                          closure = d.closure, also = d.also, also_names = d.also_names })
                end)
                report.edit = d.label
                report.file = vim.api.nvim_buf_get_name(bufnr)
                local into = carry_for(d.client)
                into.deferred_verdicts = into.deferred_verdicts or {}
                into.deferred_verdicts[#into.deferred_verdicts + 1] = report
            else
                local into = carry_for(d.client)
                into.still_pending = into.still_pending or {}
                into.still_pending[#into.still_pending + 1] = d.label
            end
        end
    end
end

-- What the reply about to leave takes along, and a reset for the next one.
-- Called by the dispatcher on every tool result.
local function take_carry()
    collect_late()
    flush_deferred(false)
    local id = require("agent99.client").current()
    local out = carries[id] or {}
    carries[id] = {}
    if type(out.late_diagnostics) == "table" and #out.late_diagnostics > 0 then
        -- One entry per file watched, and every file a call wrote or loaded
        -- is watched, so a structural edit across a package can carry a dozen
        -- of them with a diagnostic list each. Capped like every other list,
        -- and the cap says what it left out.
        local total = #out.late_diagnostics
        for _, item in ipairs(out.late_diagnostics) do
            if type(item.new) == "table" then
                item.new = cap.list(item.new, LATE_DIAGNOSTICS_PER_FILE, "new diagnostics",
                    "diagnostics(file=) lists them all")
            end
        end
        out.late_diagnostics = vim.list_slice(out.late_diagnostics,
            1, math.min(total, LATE_DIAGNOSTICS_FILES))
        out.late_diagnostics_note = "each of these is the difference between what the reply "
            .. "named in since_reply showed for that file and what the server published "
            .. "afterwards; which call the server was reacting to is not something the editor "
            .. "can tell, so the name is when, not why"
        if total > LATE_DIAGNOSTICS_FILES then
            out.late_diagnostics_note = out.late_diagnostics_note .. "; "
                .. cap.note(LATE_DIAGNOSTICS_FILES, total, "files",
                    "diagnostics(file=) reads the rest")
        end
    end
    local pending = out.still_pending
    if type(pending) == "table" then
        out.still_pending = ("%d edit(s) await the server's verdict, which comes with a later reply: %s")
            :format(#pending, table.concat(pending, "; "))
    end
    return out
end

-- Buffers this has already waited on. Whether a server has published for a
-- buffer is `last_publish`, and nothing else separates "this file is clean"
-- from "the server has not said anything about it yet" - a difference that
-- decides whether the snapshot an edit is measured against holds the
-- problems the file already had or an empty list.
local settled_once = {}

-- Buffer numbers are reused after a wipe, and a stale entry would skip the
-- wait for the file that took the number over.
vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    group = vim.api.nvim_create_augroup("agent99_settled", { clear = true }),
    callback = function(ev) settled_once[ev.buf] = nil end,
})

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
    -- Two reasons to wait: the buffer was loaded moments ago and its server
    -- may still be indexing, or no server has ever published for it, in
    -- which case the snapshot taken next would be empty and every problem
    -- the file already had would be reported as caused by the edit.
    local published = last_publish[bufnr] ~= nil
    if not fresh_buf(bufnr) and (published or settled_once[bufnr]) then return end
    if #vim.lsp.get_clients({ bufnr = bufnr }) == 0
        and #enabled_lsp_configs_for(vim.bo[bufnr].filetype) == 0 then
        return -- nothing will ever attach
    end
    -- Marked as waited-for either way: a server with nothing to say about a
    -- clean file never publishes, and waiting again on every edit in that
    -- file would spend the wait for nothing.
    settled_once[bufnr] = true
    local okc = pcall(get_client, bufnr, "textDocument/didOpen", 3000)
    if okc then
        -- A server that has never reported on this file gets longer: the
        -- first publish comes after it has parsed the file, which on a big
        -- one is slower than the re-publish after an edit.
        wait_for_diagnostics(bufnr, nil, published and 2500 or 4000,
            post_edit_options().settle_ms)
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
-- Signatures of the pre-existing diagnostics as last reported, with their
-- counts, so the next report names only what is new to the list; the
-- signatures carried over one extra reply because they left the list without
-- being fixed (a server re-analyzing a file drops its diagnostics and
-- publishes them again a moment later - carried once, so a diagnostic that is
-- really gone stops being remembered on the reply after that); and whether
-- the once-per-session hint about full_diagnostics has gone out.
--
-- All three are per client. "New to this list" means new to what *you* have
-- been shown, and while this was per root one client's reply discharged
-- another's disclosure: an agent was told "none new to this list" about four
-- warnings only the other agent had ever been shown.
local prior_state_by_client = {}

local function prior_state()
    local id = require("agent99.client").current()
    local state = prior_state_by_client[id]
    if not state then
        state = { last = {}, carried = {}, hinted = false }
        prior_state_by_client[id] = state
    end
    return state
end

-- Whether a diagnostic message names one of these symbols. Whole-word, so a
-- moved `add` is not found inside `address` and a file's unrelated error is
-- not charged to the move; the frontier patterns are what a plain
-- `find(name, 1, true)` was missing. The name is escaped because a symbol
-- path can carry pattern magic - `(*Archiver).Do` is a Go method as the
-- symbol index spells it.
local function mentions_name(message, names)
    message = message or ""
    for _, name in ipairs(names or {}) do
        if name ~= "" then
            local escaped = name:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0")
            -- A frontier only means anything next to a word character. A name
            -- that begins or ends with punctuation - `(*Archiver).Do`, as the
            -- symbol index spells a Go method - gets none on that side, or the
            -- pattern could never match at all.
            local head = name:match("^[%w_]") and "%f[%w_]" or ""
            local tail = name:match("[%w_]$") and "%f[^%w_]" or ""
            if message:find(head .. escaped .. tail) then
                return true
            end
        end
    end
    return false
end

-- ctx (optional): label = what the edit was, for the deferred and late
-- reports; since/acks/names = the barrier already sent, when resolving a
-- deferred verdict rather than judging a fresh edit.
function post_edit_report(bufnr, before, root, headless, opts, full, ctx)
    opts = opts or post_edit_options()
    ctx = ctx or {}
    -- The closure the caller computed before its edit: the files that use
    -- what this edit changed, already loaded and settled. They are `also`
    -- files like a move's referrers - this call did not edit them - and the
    -- names it asked about are what tells one of their diagnostics apart as
    -- this edit's doing.
    local cl = ctx.closure
    -- Whether the caller named the extra files itself, before the closure is
    -- folded in. It is what makes a change "structural" below, and a closure
    -- must not: every symbol edit has one now, and hanging the provisional
    -- wording on all of them would teach the reader to skip the field.
    local caller_also = (ctx.also and next(ctx.also) ~= nil) or false
    if cl then
        local also = ctx.also or {}
        for b in pairs(cl.also) do
            -- A buffer this call edited itself is `own`, and `own` is the
            -- stronger claim: `also` reports errors from a file and drops its
            -- warnings, which is right for a file the call only read.
            if not (ctx.own and ctx.own[b]) then also[b] = true end
        end
        ctx.also = also
        ctx.also_names = ctx.also_names or cl.names
    end
    local label = ctx.label or (bufnr and edit_label("edit", bufnr)) or "edit"
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
    local since, acks, names = ctx.since or vim.uv.now(), ctx.acks, ctx.names
    if attached and not acks then
        acks, names = send_barriers(bufnr, root)
    end
    if attached and not opts.wait and not ctx.since then
        deferred[bufnr] = {
            since = since, acks = acks, names = names, before = before, root = root,
            headless = headless, opts = opts, full = full, label = label,
            -- Whose edit it was: the verdict is owed to that client, and
            -- rode out on whichever client's next reply left first.
            client = require("agent99.client").current(),
            -- The version the servers were told about, so the deferred check
            -- can use the same exact signal the waiting path does.
            version = vim.lsp.util.buf_versions and vim.lsp.util.buf_versions[bufnr] or nil,
            -- The closure was computed before the edit; a deferred verdict
            -- covers the same files a waited one would, or it would answer a
            -- narrower question than the caller asked.
            closure = cl, also = ctx.also, also_names = ctx.also_names,
        }
        return {
            diagnostics_after = "deferred: the server's verdict on this edit comes with the next reply "
                .. "(under deferred_verdicts); nothing was waited for",
        }
    end
    -- Whether the wait actually obtained a verdict. `settled` false means the
    -- budget expired first, and every "no new errors" below is then a guess
    -- about a server that had not finished answering.
    -- Sent before the wait below, not after it: the closure's servers get
    -- the same barrier at the same moment, so the two waits overlap.
    local closure_wait = closure_barriers(ctx.also)
    local basis = "published"
    if attached then
        local _, _, how = wait_for_diagnostics(bufnr, root, opts.wait_ms, opts.settle_ms,
            since, acks, names)
        basis = how
    end
    local closure_how = wait_for_closure(closure_wait, root, bufnr, since, opts)
    local report = {}
    -- AGENT99_DEBUG_VERDICT surfaces which signal the wait actually got, which
    -- is otherwise only visible through the wording it produces. Worth keeping:
    -- "does this server stamp versions" is the question to ask first when an
    -- edit verdict turns out to have been early.
    local debug_verdict = os.getenv("AGENT99_DEBUG_VERDICT") ~= nil
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
    local new_here, new_elsewhere, prior_items = {}, {}, {}
    local preexisting = { errors = 0, warnings = 0 }
    -- Which files still have anything published, for the fixed count below.
    local still_reported = {}
    -- A file deleted outside the tools keeps its diagnostics in the editor
    -- forever: one `rm` of a scratch file put a phantom error into the
    -- pre-existing count of every later reply in the session.
    local on_disk = {}
    local function exists(b)
        local name = vim.api.nvim_buf_get_name(b)
        if on_disk[name] == nil then
            on_disk[name] = name == "" or vim.uv.fs_stat(name) ~= nil
        end
        return on_disk[name]
    end
    for _, d in ipairs(vim.diagnostic.get(nil)) do
        if d.severity <= vim.diagnostic.severity.WARN and exists(d.bufnr) then
            local sig = diag_signature(d)
            still_reported[vim.api.nvim_buf_get_name(d.bufnr)] = true
            if (remaining[sig] or 0) > 0 then
                remaining[sig] = remaining[sig] - 1
                if d.severity == vim.diagnostic.severity.ERROR then
                    preexisting.errors = preexisting.errors + 1
                else
                    preexisting.warnings = preexisting.warnings + 1
                end
                -- A count alone does not answer the question the caller
                -- actually has, which is whether any of these are in the
                -- code being edited, and which of them are new to the list.
                prior_items[#prior_items + 1] = {
                    -- "Here" is every file this call edited, not only the one
                    -- it was addressed to: a glob replace_pattern touching
                    -- five files reported four warnings as "none of them in
                    -- this file" while three of them were in files it had
                    -- just edited.
                    sig = sig, here = d.bufnr == bufnr or (ctx.own and ctx.own[d.bufnr]) or false,
                    text = ("%s %s:%d: %s"):format(vim.diagnostic.severity[d.severity],
                        vim.fn.fnamemodify(vim.api.nvim_buf_get_name(d.bufnr), ":."),
                        d.lnum + 1, d.message),
                }
            elseif d.bufnr == bufnr then
                new_here[#new_here + 1] = ("%s line %d: %s"):format(
                    vim.diagnostic.severity[d.severity], d.lnum + 1, d.message)
            elseif ctx.also and ctx.also[d.bufnr] then
                -- A file this call did not edit, loaded only so the server
                -- would check it. A diagnostic naming one of the moved symbols
                -- is this call's doing and is reported with the edit's own;
                -- anything else in that file is treated exactly as any other
                -- unedited file's is, which means an error is still reported
                -- under new_errors_elsewhere.
                --
                -- Both halves are load-bearing and each fixes the other's bug.
                -- Filing all of it as the edit's doing charged one move with
                -- three pre-existing warnings in a Go test file it had never
                -- touched. Dropping the rest instead - which is what this
                -- branch did until now - made an unresolved-import error in a
                -- file the move had genuinely broken vanish from the reply
                -- entirely, while the identical error in an unrelated open
                -- file was reported. That is the silent-drop this whole line
                -- of work exists to prevent, so it must fall through, not stop.
                if mentions_name(d.message, ctx.also_names) then
                    new_here[#new_here + 1] = ("%s %s:%d: %s"):format(
                        vim.diagnostic.severity[d.severity],
                        vim.fn.fnamemodify(vim.api.nvim_buf_get_name(d.bufnr), ":."),
                        d.lnum + 1, d.message)
                elseif d.severity == vim.diagnostic.severity.ERROR then
                    new_elsewhere[#new_elsewhere + 1] = ("%s:%d: %s"):format(
                        vim.fn.fnamemodify(vim.api.nvim_buf_get_name(d.bufnr), ":."),
                        d.lnum + 1, d.message)
                end
            elseif ctx.own and ctx.own[d.bufnr] then
                -- Another file this same call edited. Only errors are worth
                -- reporting from files the edit did not touch, but a warning
                -- in a file it did touch is this edit's doing: moving a
                -- function out of a Lua module left `Undefined global` in
                -- the source and the reply said "no new errors or warnings".
                new_here[#new_here + 1] = ("%s %s:%d: %s"):format(
                    vim.diagnostic.severity[d.severity],
                    vim.fn.fnamemodify(vim.api.nvim_buf_get_name(d.bufnr), ":."),
                    d.lnum + 1, d.message)
            elseif d.severity == vim.diagnostic.severity.ERROR then
                new_elsewhere[#new_elsewhere + 1] = ("%s:%d: %s"):format(
                    vim.fn.fnamemodify(vim.api.nvim_buf_get_name(d.bufnr), ":."),
                    d.lnum + 1, d.message)
            end
        end
    end
    -- What is in the snapshot and not here now looks fixed, and mostly is
    -- not: a server that re-analyzes a file publishes an empty set for it
    -- first, so an edit to one file was reported as having fixed five
    -- diagnostics in another that were back a moment later. A file that
    -- still reports something has really lost the ones that went; a file
    -- that reports nothing at all, and was not the file edited, is a server
    -- mid-republish and is not credited to this edit.
    local edited_file = bufnr and vim.api.nvim_buf_is_valid(bufnr)
        and vim.api.nvim_buf_get_name(bufnr) or nil
    local fixed = 0
    for sig, n in pairs(remaining) do
        local file = sig:match("^(.-)|") or ""
        if file == edited_file or still_reported[file] then
            fixed = fixed + n
        end
    end
    new_here = cap.list(new_here, 15, "new diagnostics in this file",
        "diagnostics(file=) lists them all")
    new_elsewhere = cap.list(new_elsewhere, 10, "new diagnostics elsewhere",
        "diagnostics(file=) lists a file's own")
    -- A glob replace_pattern or a move edits several files at once, and
    -- "this file" is then the wrong noun for what the reply is describing.
    local also_touched = 0
    for b in pairs(ctx.own or {}) do
        if b ~= bufnr then also_touched = also_touched + 1 end
    end
    local scope = also_touched > 0 and "the files this call edited" or "this file"
    -- A move, a rename or a glob pattern: more than one file, and the kind of
    -- change whose breakage lands in a file the reply is not looking at.
    local structural = also_touched > 0 or caller_also
    local silent, silent_scope
    if attached then silent, silent_scope = silent_server(bufnr, names) end
    -- Everything above counts errors and warnings only. In a JavaScript file
    -- with no tsconfig the server has nothing stronger than a hint to say
    -- with, and the hints dropped from one reply were the orphaned constants a
    -- move had left behind - the whole of the evidence that the file no longer
    -- ran. Collected before the verdict, because in that repository the hints
    -- ARE the verdict.
    local hints, strong_here = {}, false
    local hint_bufs = { [bufnr or -1] = true }
    for b in pairs(ctx.own or {}) do hint_bufs[b] = true end
    for b in pairs(hint_bufs) do
        if vim.api.nvim_buf_is_valid(b) then
            for _, d in ipairs(vim.diagnostic.get(b)) do
                if d.severity > vim.diagnostic.severity.WARN then
                    hints[#hints + 1] = ("%s:%d: %s"):format(
                        vim.fn.fnamemodify(vim.api.nvim_buf_get_name(b), ":."),
                        d.lnum + 1, d.message)
                else
                    strong_here = true
                end
            end
        end
    end
    if debug_verdict then
        report.verdict_basis = basis
        report.verdict_stamps = (vim.inspect(stamps_version):gsub("%s+", " "))
        if #closure_how > 0 then report.verdict_closure = closure_how end
    end
    -- What the verdict actually covered, as a clause. Not decoration: "no new
    -- errors or warnings" with nothing after it reads as a statement about
    -- the project, and it was one about a single file. Every clean verdict
    -- below names its own scope, whether or not a closure was computed.
    local covers = closure.clause(cl, scope)
    local not_analyzed = bufnr and not_analyzed_reason(bufnr) or nil
    if not_analyzed then
        -- Reporting "no new errors" here would be a straight lie: the server
        -- never looked. This is the build-tag case, where the edit is real
        -- but nothing is checking it.
        report.diagnostics_after = "not checked: the language server does not analyze this "
            .. "file in its current configuration (" .. not_analyzed .. "). An edit here is "
            .. "unverified - build or test with the tags that include it."
    elseif bufnr and dialect_note(bufnr) then
        -- A file whose language server was sent away because it cannot parse
        -- this dialect. Same shape of answer as the build-tag case above: the
        -- edit is real, and nothing checked it.
        report.diagnostics_after = "not checked: " .. dialect_note(bufnr)
    elseif not attached and bufnr then
        -- For JSON, YAML, TOML and Markdown no server is ever coming, and
        -- "nothing checked" was the whole of what an edit to one said - while
        -- the edit had, in the JSON case, left the file unparseable. The
        -- grammar that located the symbol can answer for the file's syntax.
        -- That is not a type check and does not pretend to be one, but it is
        -- the difference between a file that still loads and one that does
        -- not. When the grammar says the file is broken, finish_edit leads
        -- the verdict with that instead.
        local broken = core.has_parser(ft)
            and require("agent99.syntax").first_error(bufnr) or nil
        if not core.has_parser(ft) then
            report.diagnostics_after = "no language server attached to this file; nothing checked"
        elseif broken then
            -- Said without a cause: only the caller of finish_edit knows
            -- whether this edit is what broke it, and it says so there.
            report.diagnostics_after = ("no language server attached to this file, and the %s "
                .. "grammar does not parse it as it now stands"):format(ft)
        else
            report.diagnostics_after = ("no language server attached to this file; the %s "
                .. "grammar still parses it, which is all that was checked"):format(ft)
        end
    elseif not bufnr then
        -- delete_file: nothing is left to report against, and the old line
        -- claimed the project on the strength of whatever happened to be
        -- open. What it can honestly say is which files were asked - the
        -- ones that used what the deleted file declared.
        if #new_here > 0 then
            report.diagnostics_after = new_here
        elseif #new_elsewhere == 0 then
            report.diagnostics_after = "no new errors" .. closure.clause_gone(cl)
        end
    elseif #new_here == 0 and basis == "timeout" then
        -- The budget ran out before the servers had finished. Saying "no new
        -- errors" here asserts a verdict that was never given; whatever the
        -- server says next arrives under late_diagnostics on a later reply.
        report.diagnostics_after = ("nothing new so far%s, but the server had not finished "
            .. "answering within %d ms, so this verdict is provisional: anything that arrives "
            .. "later comes with a later reply under late_diagnostics"):format(covers, opts.wait_ms)
    elseif #new_here == 0 and basis == "unmeasured" and structural then
        -- The servers answered the barrier and then stayed quiet for as long
        -- as the settle guess allowed. For a server whose publish lag has
        -- never been measured that expiry proves nothing: pyright published
        -- two errors 230 ms after a reply that had already called a move
        -- clean, and tsserver 66 ms after another.
        --
        -- Only for a structural change. A one-file edit whose settle expired
        -- is the ordinary case and has been reliable; saying "provisional" on
        -- every first edit in every workspace would be noise that teaches the
        -- reader to skip the field, which is the failure this whole line of
        -- work exists to prevent. A move, a rename or a glob pattern is where
        -- the late answer actually lands, and where it costs the most.
        report.diagnostics_after = ("nothing new so far%s, but no server had published for "
            .. "this file when the wait ended and none of them has been timed in this "
            .. "workspace yet, so this verdict is provisional: what arrives later comes with "
            .. "a later reply under late_diagnostics. A structural change is worth confirming "
            .. "with check_project or diagnostics before it is treated as finished"):format(covers)
    elseif #new_here == 0 and silent then
        -- The servers on this file answered the barrier and then said nothing,
        -- and none of them has ever published anything about this file. That
        -- is what bash-language-server does for a file holding a deliberate
        -- syntax error, so the silence is not a verdict. The caveat says
        -- whether the server has been quiet everywhere or only here: a
        -- diagnostic it published about some other file is no evidence about
        -- this one, which is what the old per-server gate treated it as.
        report.diagnostics_after = ("no new errors or warnings%s, but %s has published no "
            .. "diagnostics %s, so its silence is not yet evidence that "
            .. "this file is clean; check_project runs the project's own build or check")
            :format(covers, silent, silent_scope)
    elseif #new_here == 0 and #hints > 0 and not strong_here then
        -- The server has hints for these files and has never had anything
        -- stronger to say about them, so "errors or warnings" is an empty
        -- category here and a clean line in it checks nothing. This is the
        -- .mjs-with-no-tsconfig case, where every edit came back clean
        -- including the one that broke three modules.
        report.diagnostics_after = ("no new errors or warnings - but the server reports "
            .. "nothing above hint severity for %s, so that is an empty category here and "
            .. "this line checks nothing. The hints below are the whole of what it has to "
            .. "say about these files; check_project runs the project's own build or check")
            :format(scope)
    elseif #new_here == 0 and basis == "version" and structural then
        -- Worth one clause on a structural change, because the alternative
        -- wording on this branch is "provisional": here the servers stamped a
        -- publish for the exact text that was written, so nothing is inferred.
        report.diagnostics_after = ("no new errors or warnings%s, and every server on this "
            .. "file published for the version this edit wrote, so that is their answer "
            .. "rather than a guess from how long they stayed quiet"):format(covers)
    elseif #new_here == 0 then
        report.diagnostics_after = "no new errors or warnings" .. covers
    else
        report.diagnostics_after = new_here
        -- A server analyzes one build configuration and can lag a change it
        -- has only just been told about, so a surprising error here is worth
        -- confirming rather than chasing.
        report.if_unexpected = "these come from the language server; check_project "
            .. "runs the project's own build or check for ground truth"
    end
    -- The closure, listed whatever the verdict says: a reply that does report
    -- new errors still has to say what it looked at, or the reader cannot
    -- tell a short list from a narrow one.
    closure.attach(report, cl)
    -- A multi-file edit takes its verdict from the buffer it was addressed to,
    -- and the rest only ever reached the reply through `preexisting`: three Go
    -- files behind a build tag, which the server had declined to analyze,
    -- appeared there while the verdict line read "no new errors or warnings".
    -- A file nothing looked at is a caveat on this edit, not a prior condition.
    local unchecked = {}
    for b in pairs(ctx.own or {}) do
        if b ~= bufnr and vim.api.nvim_buf_is_valid(b) then
            local why = not_analyzed_reason(b) or dialect_note(b)
                or (#vim.lsp.get_clients({ bufnr = b }) == 0
                    and "no language server attached to this file" or nil)
            if why then
                unchecked[#unchecked + 1] = ("%s: %s"):format(
                    vim.fn.fnamemodify(vim.api.nvim_buf_get_name(b), ":."), why)
            end
        end
    end
    if #unchecked > 0 then
        report.not_checked = unchecked
        report.not_checked_note = "this call edited these files as well and nothing analyzed "
            .. "them, so the verdict above does not cover them"
    end
    if #hints > 0 then
        local total = #hints
        hints = cap.list(hints, HINTS_LISTED, "hints", "diagnostics(file=) lists them all")
        report.hints = hints
        -- The old note called these "not errors or warnings", which reads as
        -- "discount them". Where they are the only channel the server has,
        -- that is exactly the wrong instruction.
        report.hints_note = strong_here
            and ("%d hint-level diagnostics in %s; below the severity counted above")
                :format(total, scope)
            or ("%d hint-level diagnostics in %s, and the server reports nothing above hint "
                .. "severity for these files at all - so these are not noise below the "
                .. "verdict, they are the verdict"):format(total, scope)
    end
    if #new_elsewhere > 0 then
        report.new_errors_elsewhere = new_elsewhere
    end
    -- A server that has stopped answers for nothing, and the counts below are
    -- read as claims about the project. After gopls was killed mid-session an
    -- edit still reported "1 errors were there before the edit (1 in this
    -- file, 0 elsewhere)": the list it counted was a corpse's.
    local stopped = stopped_servers()
    if #stopped > 0 then
        report.servers_stopped = ("%s published diagnostics in this session and %s no longer "
            .. "running; what %s reported is still in the editor and nothing is refreshing it, "
            .. "so no count in this reply is evidence about the files %s was analyzing")
            :format(table.concat(stopped, " and "), #stopped == 1 and "is" or "are",
                #stopped == 1 and "it" or "they", #stopped == 1 and "it" or "they")
    end
    local prior = {}
    if preexisting.errors > 0 then prior[#prior + 1] = preexisting.errors .. " errors" end
    if preexisting.warnings > 0 then prior[#prior + 1] = preexisting.warnings .. " warnings" end
    -- The pre-existing set rarely changes between two edits, and repeating
    -- it costs tokens on every reply for no decision. What the last reply
    -- listed is remembered per signature: an entry new to the list (an
    -- error the caller's own earlier edit introduced, pre-existing now) is
    -- named, the rest is a count, and a list with nothing new is one short
    -- line. full_diagnostics lists everything again. The ones in the edited
    -- file come first either way.
    table.sort(prior_items, function(a, b)
        if a.here ~= b.here then return a.here end
        return a.text < b.text
    end)
    local seen_now = {}
    for _, item in ipairs(prior_items) do seen_now[item.sig] = (seen_now[item.sig] or 0) + 1 end
    -- What this client has been shown, not what the editor has shown anyone.
    local disclosed = prior_state()
    if #prior > 0 then
        local listed, here, entered, entered_here = {}, 0, 0, 0
        local budget = vim.deepcopy(disclosed.last)
        for _, item in ipairs(prior_items) do
            if item.here then here = here + 1 end
            local known = (budget[item.sig] or 0) > 0
            if known then
                budget[item.sig] = budget[item.sig] - 1
            else
                entered = entered + 1
                if item.here then entered_here = entered_here + 1 end
            end
            if full or not known then listed[#listed + 1] = item.text end
        end
        local elsewhere = #prior_items - here
        local where = here == 0 and ("none of them in %s"):format(scope)
            or ("%d in %s, %d elsewhere"):format(here, scope, elsewhere)
        -- "0 elsewhere" reads as a statement about the rest of the project,
        -- and it is only ever a statement about what the editor is holding.
        -- Said with a server dead it is not even that.
        if #stopped > 0 then
            where = where .. ("; that is what the editor still holds, and %s stopped running "
                .. "during this session"):format(table.concat(stopped, " and "))
        end
        -- "New to this list" read as "new because of you", and often it is
        -- not: the list also grows as the language server is asked about more
        -- of the project, and one edit brought in 61 entries from files it had
        -- never opened. An entry in a file this call edited is the one that
        -- deserves that reading, so it is counted apart from the rest.
        --
        -- What this says is the delta and nothing else. It used to name the
        -- cause - "the server has been asked about more of the project, which
        -- is not a change this call made" - and that clause was attached to
        -- errors the previous call had created, errors another live agent had
        -- just typed, errors this same client had created moments earlier, an
        -- error created while gopls was dead, and errors caused by the very
        -- edit being undone. The bridge cannot tell those apart from a widened
        -- scope, and asserting the innocent one tells the reader to stop
        -- looking exactly when looking would have paid.
        -- full_diagnostics=true is the flag whose whole purpose is to defeat
        -- the cap, so it gets a far larger list - but it still has one, and
        -- "all listed" beside a "… +92 more" in the same object was the
        -- loudest wrong count in the reply. Say which of the two it is.
        local list_cap = full and FULL_PREEXISTING_LISTED or PREEXISTING_LISTED
        local how_new
        if full and #listed > list_cap then
            how_new = ("the first %d are listed, %d more are not")
                :format(list_cap, #listed - list_cap)
        elseif full then
            how_new = "all listed"
        elseif entered_here == 0 then
            how_new = ("%d entered this list since the last reply, none of them in %s")
                :format(entered, scope)
        elseif entered_here == entered then
            how_new = ("%d new to this list since the last reply, all of them in %s")
                :format(entered, scope)
        else
            how_new = ("%d entered this list since the last reply, %d of them in %s")
                :format(entered, entered_here, scope)
        end
        -- One cause the bridge can actually distinguish, now that every edit
        -- carries a client id: somebody else is editing this workspace, and
        -- their edits land in the same editor and the same diagnostics.
        if not full and entered > 0 then
            local okd, others = pcall(function() return require("agent99.edits").others() end)
            if okd and others and others.clients > 0 then
                how_new = how_new .. ("; %d other client%s has edits in this workspace")
                    :format(others.clients, others.clients == 1 and "" or "s")
            end
        end
        if full or entered > 0 then
            report.preexisting = ("%s were there before the edit (%s); %s"):format(
                table.concat(prior, " and "), where, how_new)
            listed = cap.list(listed, list_cap, "diagnostics",
                full and "narrow with diagnostics(file=) for one file"
                    or "full_diagnostics=true lists more of them")
            report[full and "preexisting_list" or "preexisting_new_to_list"] = listed
        else
            report.preexisting = ("%s were there before the edit (%s), none new to this list"):format(
                table.concat(prior, " and "), where)
        end
        if not disclosed.hinted then
            report.preexisting = report.preexisting .. "; full_diagnostics=true lists them all"
            disclosed.hinted = true
        end
    end
    -- The same churn empties a file's list and fills it again, and every
    -- return read as "new to this list". What the last two replies saw
    -- counts as seen, so a diagnostic has to be genuinely new to be named.
    for sig, n in pairs(disclosed.last) do
        if not seen_now[sig] and (disclosed.carried[sig] or 0) == 0 then
            seen_now[sig] = n
            disclosed.carried[sig] = n
        else
            disclosed.carried[sig] = nil
        end
    end
    disclosed.last = seen_now
    if fixed > 0 then
        report.fixed = fixed .. " diagnostics from before the edit are gone"
    end
    -- Watched together: the files this call edited and the files it loaded to
    -- ask about. A late publish in any of them belongs to this reply.
    local watch_too = {}
    for b in pairs(ctx.own or {}) do watch_too[b] = true end
    for b in pairs(ctx.also or {}) do watch_too[b] = true end
    watch_after_report(bufnr, root, names, opts, label, watch_too)
    return report
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
    local range
    if col == nil and (symbol == nil or symbol == "") then
        local lnum = tonumber(args.line) or 1
        local text = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
        -- From the first non-blank to the end of the line, not a point at
        -- the first non-blank: a quick fix for a diagnostic further along
        -- the line is offered only when the range reaches it.
        local start = make_position(bufnr, client, lnum, nil, text:find("%S") or 1)
        local stop = make_position(bufnr, client, lnum, nil, #text + 1)
        range = { start = start, ["end"] = stop }
    else
        local pos = make_position(bufnr, client, args.line, symbol, col)
        range = { start = pos, ["end"] = pos }
    end
    local lsp_diags = {}
    pcall(function()
        lsp_diags = vim.lsp.diagnostic.from(
            vim.diagnostic.get(bufnr, { lnum = range.start.line }))
    end)
    local result = request(client, bufnr, "textDocument/codeAction", {
        textDocument = { uri = vim.uri_from_bufnr(bufnr) },
        range = range,
        context = { diagnostics = lsp_diags, triggerKind = 1 },
    }) or {}
    action_token = action_token + 1
    local token = tostring(action_token)
    action_cache[token] = { client_id = client.id, bufnr = bufnr, actions = result }
    -- Servers repeat themselves: gopls offered "Remove variable trimmed"
    -- twice for one diagnostic, at indices 1 and 2, which reads as two
    -- different fixes. The first of each title keeps its index.
    local out, seen = {}, {}
    for i, a in ipairs(result) do
        local key = (a.title or "") .. "\0" .. (a.kind or "")
        if not seen[key] then
            seen[key] = true
            out[#out + 1] = {
                index = i,
                title = a.title,
                kind = a.kind,
                preferred = a.isPreferred or nil,
            }
        end
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
        local result = require("agent99.lsp").dispatch(entry.edit, action.args)
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
    local command_note
    if action.command then
        -- The command's edit comes back from the server later; wait for
        -- it (bounded) so the reply names the files it touched and, when
        -- headless, the save that follows this tool has something to save.
        local cmd = type(action.command) == "table" and action.command or action
        local answered, bufs = exec_command_and_wait(client, cmd, entry.bufnr)
        local seen = {}
        for _, f in ipairs(changed) do seen[f] = true end
        for _, b in ipairs(bufs) do
            local name = vim.api.nvim_buf_get_name(b)
            if name ~= "" and not seen[name] then
                seen[name] = true
                changed[#changed + 1] = name
            end
        end
        if #bufs == 0 then
            command_note = answered
                and "the server ran the command but changed no buffer"
                or ("the server had not answered the command after %d ms; its edit, "
                    .. "if any, arrives later and is not in changed_files"):format(COMMAND_WAIT_MS)
        end
    end
    action_cache[tostring(args.token)] = nil
    return {
        applied = action.title,
        changed_files = changed,
        command_note = command_note,
        note = args.headless
            and "changes applied and saved to disk"
            or "changes live in editor buffers (unsaved); use buffer_lines to inspect them",
    }
end

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

-- Text reaches an edit tool through a JSON round trip, and an escape can
-- arrive as bytes the caller never meant: an escaped NUL as one real NUL
-- byte, a doubled backslash where one was intended. The tools carry those
-- bytes faithfully into the file, and the reply otherwise echoes only the
-- text that was replaced, so the damage stays invisible until something
-- trips over it at runtime. Control characters in what was just written
-- are reported without being asked for; verify=true echoes the landed
-- bytes whether or not they look odd.
local function odd_bytes(lines)
    local names, seen = {}, {}
    for _, l in ipairs(lines) do
        -- Tab is ordinary in source; every other control character in a
        -- line, NUL included, is a byte nobody types on purpose.
        for c in l:gmatch("[%z\1-\8\10-\31\127]") do
            local b = c:byte()
            local name = b == 0 and "\\x00 (NUL)" or ("\\x%02X"):format(b)
            if not seen[name] then
                seen[name] = true
                names[#names + 1] = name
            end
        end
    end
    return names
end
-- Shared tail of every edit tool: the lines are already in the buffer;
-- polish (format, imports), record the final region in the ledger, and
-- build the reply with the post-edit report.
local function finish_edit(bufnr, args, before, ledger_path, kind, first, last_old, old_lines, count, fields, regions, cl)
    local opts = post_edit_options(args)
    -- The whole file as the edit left it, before any polish. Organizing
    -- imports rewrites the import block, which is above the edited region
    -- and so outside what the ledger records: undo_edit then reported
    -- "remaining: 0" while leaving a reindented import block behind, and the
    -- caller had to reach for git. If the polish touches anything above the
    -- region, the ledger entry becomes the whole file.
    local pre_polish = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local pfirst, pcount, done, extra_old, info
    if regions and #regions > 1 then
        -- Several edited regions far apart (chunks in different symbols):
        -- format each one on its own, bottom-up, so the code between them
        -- is left alone, then organize imports once. The span that goes in
        -- the ledger is re-measured from the diff of the whole pass, the
        -- same way polish_after_edit measures one region.
        local span_before = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        local seen = {}
        local format_only = vim.tbl_extend("force", opts, { organize_imports = false })
        info = { diff = {}, skipped = {} }
        local function absorb(d, region_info)
            for _, x in ipairs(d) do seen[x] = true end
            if region_info.format_skipped then
                info.skipped[region_info.format_skipped] = true
            end
            for _, l in ipairs(region_info.diff or {}) do
                info.diff[#info.diff + 1] = l
            end
        end
        for i = #regions, 1, -1 do
            local _, _, d, _, region_info = polish_after_edit(bufnr, regions[i].first, regions[i].count, format_only)
            absorb(d, region_info)
        end
        local _, _, d, _, imports_info =
            polish_after_edit(bufnr, first, 0, vim.tbl_extend("force", opts, { format = false }))
        absorb(d, imports_info)
        info.imports_note = imports_info.imports_note
        done = vim.tbl_keys(seen)
        table.sort(done)
        local reasons = vim.tbl_keys(info.skipped)
        table.sort(reasons)
        info.format_skipped = #reasons > 0 and table.concat(reasons, "; ") or nil
        if #info.diff == 0 then info.diff = nil end
        -- Same rule as polish_after_edit: whatever polishing changed below
        -- the span joins the recorded region.
        local span_after = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        local span_first, span_last
        span_first, span_last, extra_old = map_region(span_before, span_after, first, first + count - 1)
        if span_last > #span_after then span_last = #span_after end
        pfirst, pcount = span_first, math.max(0, span_last - span_first + 1)
    else
        pfirst, pcount, done, extra_old, info = polish_after_edit(bufnr, first, count, opts)
    end
    info = info or {}
    if extra_old and #extra_old > 0 then
        old_lines = vim.list_extend(vim.list_slice(old_lines, 1, #old_lines), extra_old)
        last_old = last_old + #extra_old
    end
    -- Did the polish change anything above the region the ledger holds? The
    -- lines above it were untouched by the edit itself, so pre_polish is the
    -- pre-edit text there, and comparing is enough.
    local after_polish = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local above_changed = false
    for i = 1, math.min(first, pfirst) - 1 do
        if pre_polish[i] ~= after_polish[i] then
            above_changed = true
            break
        end
    end
    if above_changed then
        local whole_old = vim.list_slice(pre_polish, 1, first - 1)
        vim.list_extend(whole_old, old_lines)
        vim.list_extend(whole_old, vim.list_slice(pre_polish, first + count))
        old_lines = whole_old
        first, pfirst = 1, 1
        last_old = #whole_old
        pcount = #after_polish
    end
    local new_lines = vim.api.nvim_buf_get_lines(bufnr, pfirst - 1, pfirst - 1 + pcount, false)
    record_edit(bufnr, ledger_path, kind, pfirst, last_old + (pfirst - first), old_lines, new_lines)
    fields.file = vim.api.nvim_buf_get_name(bufnr)
    -- Where the written text is, not how far the ledger reaches: the ledger
    -- deliberately swallows whatever a formatter or an import pass changed
    -- around the edit, and reporting that span as `lines` turned a two-line
    -- change into a claim that the tool had rewritten the file.
    local efirst, elast = info.edit_first, info.edit_last
    if efirst and elast then
        fields.lines = ("%d-%d"):format(efirst, elast)
    else
        fields.lines = pcount > 0 and ("%d-%d"):format(pfirst, pfirst + pcount - 1) or tostring(pfirst)
    end
    fields.note = edit_note(args)
    if #done > 0 then
        fields.polished = table.concat(done, ", ")
        if info.diff then
            fields.polish_diff = info.diff
        end
    end
    if info.format_skipped then
        fields.format_skipped = info.format_skipped
    end
    if info.imports_note then
        fields.imports_note = info.imports_note
    end
    local odd = odd_bytes(new_lines)
    if args.verify or #odd > 0 then
        fields.new_text = new_lines
    end
    if #odd > 0 then
        fields.control_characters = ("the written text holds %s; if that came from an escape "
            .. "in the request, the escape did not survive the round trip"):format(table.concat(odd, ", "))
    end
    -- Does the file still parse? Every symbol edit locates its target with a
    -- treesitter parser and then writes lines, and where the two disagree the
    -- file is left invalid: a JSON pair's separating comma sat outside the
    -- node, so replacing the pair ate it and the reply said "applied and
    -- saved to disk" over a file json.load could no longer read. The parser
    -- is already in hand; asking it again is the whole check. Only when the
    -- tree is broken is the pre-edit text reconstructed and parsed too, so a
    -- file that arrived invalid is not blamed on the edit that touched it.
    local syntax = require("agent99.syntax")
    local broke = syntax.first_error(bufnr)
    if broke then
        local whole = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        local was = vim.list_slice(whole, 1, pfirst - 1)
        vim.list_extend(was, old_lines)
        vim.list_extend(was, vim.list_slice(whole, pfirst + #new_lines))
        if syntax.error_in_lines(was, vim.bo[bufnr].filetype) then
            broke = nil
        end
    end
    local report = post_edit_report(bufnr, before, args.root, args.headless, opts,
        args.full_diagnostics, { label = edit_label(kind, bufnr), closure = cl })
    if broke then
        -- The two things the old reply got wrong, in the two fields a reader
        -- checks: the note called it done, and the verdict deferred to a
        -- language server that no data format has.
        fields.note = fields.note .. ", and the file no longer parses"
        local said = report.diagnostics_after
        -- A server's own verdict is kept beside the grammar's - the two
        -- answer different questions - but "nothing checked" from a file
        -- that has no server and never will is what this replaces.
        local keep = type(said) == "string"
            and #vim.lsp.get_clients({ bufnr = bufnr }) > 0
        report.diagnostics_after = syntax.clause(bufnr, broke)
            .. (keep and (". The language server's own answer: " .. said) or "")
    end
    return vim.tbl_extend("error", fields, report)
end

-- A unified diff of what an edit would do, for the dry_run of the tools that
-- otherwise apply immediately. rename_symbol has always been able to show its
-- blast radius before committing to it; a large body replacement is no less
-- worth looking at first.
local function preview_diff(old_lines, new_lines, label, at)
    -- An insertion has no old side, and a unified diff of "" against the new
    -- text renders as a replacement of line 1: "@@ -1 +1 @@" with a "-" for
    -- a blank line that does not exist, whatever line the text is going to.
    -- Four separate runs read that as "line 1 will be deleted".
    if #old_lines == 0 then
        local shown = {}
        for i, l in ipairs(new_lines) do
            shown[i] = "+" .. l
        end
        return {
            dry_run = true,
            inserted = label,
            diff = vim.list_extend({ ("@@ %s @@"):format(at or label) }, shown),
            note = "nothing applied; call again without dry_run to make the edit",
        }
    end
    local diff = text_diff(
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
    local bufnr, entry = resolve_symbol(args.file, args.name_path, nil, tonumber(args.line))
    if type(args.body) ~= "string" then
        err("missing required argument: body")
    end
    -- Only the final line terminator, not the blank lines before it.
    local new_lines = vim.split((args.body:gsub("\n$", "")), "\n", { plain = true })
    local old = vim.api.nvim_buf_get_lines(bufnr, entry.first - 1, entry.last, false)
    -- What is on the declaration's own lines but not part of the declaration.
    -- The tool replaced whole lines, so anything sharing the first or the last
    -- of them went with the symbol: a JSON object's separating comma sits
    -- after the pair the caller named and was eaten by every edit to it - the
    -- file stopped parsing and the reply said "applied and saved to disk" -
    -- and `package pkg; func OneLiner() int { ... }` lost its package clause.
    -- Only treesitter entries carry columns; a language server's do not, and
    -- those stay line-granular as before.
    local head = entry.first_col and (old[1] or ""):sub(1, entry.first_col) or ""
    -- Leading whitespace is the declaration's indentation, not something else
    -- on the line; it is what the reindent below is for.
    if head:match("^%s*$") then head = "" end
    local tail = entry.last_col and (old[#old] or ""):sub(entry.last_col + 1) or ""
    -- Written at the declaration's own indentation, which is what the tool
    -- has always promised and did not do: a Python method replaced with a
    -- body starting at column 0 landed at column 0, so it and the method
    -- after it fell out of their class - the suite went from three tests to
    -- one, and pyright, the diagnostics and run_tests all called it clean.
    -- The whole block shifts by one delta, so relative indentation inside it
    -- is the caller's business.
    local reindented
    local want = (old[1] or ""):match("^[ \t]*") or ""
    local have = (new_lines[1] or ""):match("^[ \t]*") or ""
    if want ~= have and head == "" then
        -- Shift by the difference rather than by rewriting a common prefix.
        -- Requiring every line to start with the first line's indentation
        -- meant one flush-left comment in an otherwise indented body
        -- disabled the whole shift, in silence: a Python method then landed
        -- inside the method above it and the class lost it.
        local shifted = {}
        for i, l in ipairs(new_lines) do
            if l == "" then
                shifted[i] = l
            elseif #want >= #have then
                shifted[i] = want:sub(#have + 1) .. l
            else
                -- Dedent: take back what the line can spare, never more.
                local drop = #have - #want
                local lead = l:match("^[ \t]*")
                shifted[i] = l:sub(math.min(drop, #lead) + 1)
            end
        end
        new_lines = shifted
        reindented = ("the body was written at column %d and %s sits at column %d; "
            .. "every line was shifted by %d"):format(#have, entry.path, #want, #want - #have)
    end
    local kept
    if head ~= "" or tail ~= "" then
        new_lines[1] = head .. new_lines[1]
        new_lines[#new_lines] = new_lines[#new_lines] .. tail
        kept = ("%s is not the whole of the line(s) it sits on; %s was left in place"):format(
            entry.path,
            head ~= "" and tail ~= ""
                and ("%q before it and %q after it"):format(head, tail)
                or (head ~= "" and ("%q before it"):format(head)
                    or ("%q after it"):format(tail)))
    end
    if args.dry_run then
        return vim.tbl_extend("force",
            { file = rel_path(vim.api.nvim_buf_get_name(bufnr)), reindented = reindented,
                kept_on_the_line = kept },
            preview_diff(old, new_lines, entry.path))
    end
    local conflict = primary_region_conflict(bufnr, entry.first, entry.last)
    if conflict then err(conflict) end
    settle_before_edit(bufnr)
    -- Asked while the declaration is still where the server expects it, and
    -- before the snapshot, so the problems these files already had are in the
    -- baseline and only what this edit breaks in them is new.
    local cl = closure.plan({
        bufnr = bufnr, root = args.root, seeds = { entry }, settle = settle_before_edit,
    })
    local before = diag_snapshot()
    vim.api.nvim_buf_set_lines(bufnr, entry.first - 1, entry.last, false, new_lines)
    return finish_edit(bufnr, args, before, entry.path, "replace", entry.first, entry.last,
        old, #new_lines, { replaced = entry.path, reindented = reindented,
            kept_on_the_line = kept }, nil, cl)
end

-- Join lines with each one's indentation dropped. Text that a format pass
-- re-indented is still the same text, and treating the moved leading
-- whitespace as drift refuses an edit the caller had exactly right.
local function indent_blind(lines)
    local out = {}
    for i, l in ipairs(lines) do
        out[i] = vim.trim(l)
    end
    return table.concat(out, "\n")
end

-- Where `key` sits between two buffer lines, as a 1-based offset from
-- `first`. Only an unambiguous hit counts: exactly one place, or none, in
-- which case the number of places is returned instead.
local function locate_between(bufnr, first, last, key, n, loose)
    local body = vim.api.nvim_buf_get_lines(bufnr, first - 1, last, false)
    local hits = {}
    for start = 1, #body - n + 1 do
        local slice = vim.list_slice(body, start, start + n - 1)
        local window = loose and indent_blind(slice) or vim.trim(table.concat(slice, "\n"))
        if window == key then
            hits[#hits + 1] = start
        end
    end
    if #hits == 1 then
        return hits[1], 1
    end
    return nil, #hits
end

-- Find the lines holding `want`: inside the symbol first, then anywhere in
-- the file, and on a second pass ignoring indentation. The offset returned
-- is relative to entry.first in every case, so a hit above or below the
-- symbol comes back outside 1..span and the caller can still turn it into a
-- buffer line number. Returns that offset (nil unless exactly one place
-- matched), how many places matched, how many lines `want` holds, and where
-- it was found: "symbol", "file", or nil for nowhere.

-- locate_between only ever matches a whole line (or whole lines, for a
-- multi-line match=): a caller who quoted a fragment of a long line - a
-- Markdown table row, a wrapped comment - gets "nowhere" even though the
-- text is right there. Nowhere is still nowhere, but when the text is a
-- substring of exactly one line, saying so turns a dead end into the fix:
-- quote that whole line instead. More than one line containing it is not
-- a fragment match worth reporting - there is nothing to point at.
local function substring_hint(bufnr, first, last, want)
    if want == "" or want:find("\n", 1, true) then return nil end
    local body = vim.api.nvim_buf_get_lines(bufnr, first - 1, last, false)
    local hit_line, hit_text
    for i, line in ipairs(body) do
        if line:find(want, 1, true) then
            if hit_line then return nil end
            hit_line, hit_text = first + i - 1, line
        end
    end
    return hit_line, hit_text
end

local function locate_expected(bufnr, entry, want)
    local want_lines = vim.split(want, "\n", { plain = true })
    local n = #want_lines
    local total = vim.api.nvim_buf_line_count(bufnr)
    local whole = entry.first <= 1 and entry.last >= total
    local keys = { vim.trim(want), indent_blind(want_lines) }
    -- Exact before indent-blind, so a symbol holding two lines that differ
    -- only in their indentation still resolves to the one the caller meant.
    for pass = 1, 2 do
        local loose = pass == 2
        local at, count = locate_between(bufnr, entry.first, entry.last, keys[pass], n, loose)
        if at then
            return at, 1, n, "symbol"
        end
        if whole then
            if count > 1 then
                return nil, count, n, "file"
            end
        else
            -- The symbol may have shrunk, or the text may have moved just
            -- past its end. It is still in the file, so relocating it beats
            -- telling the caller to re-read a file that already holds it.
            local wide, wide_count = locate_between(bufnr, 1, total, keys[pass], n, loose)
            if wide then
                return wide - entry.first + 1, 1, n, "file"
            end
            if wide_count > 1 then
                return nil, wide_count, n, "file"
            end
        end
    end
    local hint_line, hint_text = substring_hint(bufnr, entry.first, entry.last, want)
    if not hint_line then
        hint_line, hint_text = substring_hint(bufnr, 1, total, want)
    end
    return nil, 0, n, nil, hint_line, hint_text
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
    -- A key a chunk does not have is a chunk that means something else. The
    -- one that costs is `file`: chunks are one file per call, so a chunk
    -- carrying its own file was silently scoped to the call's file, and two
    -- of them came back as "chunks overlap: lines 1-1 of colors.lua and
    -- lines 1-1 of colors.lua" - the same file named twice, which is the
    -- only hint that the key was dropped.
    local KNOWN = {
        first_line = true, last_line = true, text = true, expect = true,
        match = true, absolute = true, name_path = true, line = true,
        -- The name this key had before it was `line` everywhere, still taken
        -- so a caller that learned it does not have to unlearn it.
        declared_on = true,
    }
    local out = {}
    for i, c in ipairs(chunks) do
        for k in pairs(c) do
            if not KNOWN[k] then
                if k == "file" then
                    err("chunk %d: a chunk cannot name its own file; one call edits one file "
                        .. "(the call's file=). Several files take one call each.", i)
                end
                err("chunk %d: unknown key %q; a chunk takes first_line, last_line, match, "
                    .. "text, expect, absolute, name_path and line", i, tostring(k))
            end
        end
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

-- Settle a tie between symbols that answer to the same name, from what the
-- chunk says beyond the name. A match= text that sits, exactly once, in
-- one of them names that one; absolute lines that fall inside one of them
-- do the same. Nil when nothing decides it, and the refusal that follows
-- names the candidates as before.
local function pick_tied_symbol(bufnr, tied, c)
    local found = {}
    if c.match ~= nil then
        local want = vim.trim((c.match:gsub("\n+$", "")))
        local want_lines = vim.split(want, "\n", { plain = true })
        local keys = { want, indent_blind(want_lines) }
        for _, entry in ipairs(tied) do
            local first = doc_block_start(bufnr, entry.first)
            for pass = 1, 2 do
                local at = locate_between(bufnr, first, entry.last, keys[pass], #want_lines, pass == 2)
                if at then
                    found[#found + 1] = entry
                    break
                end
            end
        end
    elseif c.absolute and c.first and c.last then
        for _, entry in ipairs(tied) do
            local first = doc_block_start(bufnr, entry.first)
            if c.first >= first and c.last <= entry.last then
                found[#found + 1] = entry
            end
        end
    end
    if #found == 1 then
        return found[1]
    end
    return nil
end

-- The same replace_symbol_lines call with every chunk re-addressed to
-- where its expected text actually is. Buffer line numbers throughout,
-- whatever the original used: a chunk that names no symbol has no
-- declaration to be relative to, and one whose text turned up outside its
-- symbol cannot keep naming it (the numbers would be converted back to
-- offsets and refused for being out of its span). The single-chunk fields
-- are cleared because a call-wide name_path is inherited by every chunk
-- that does not name one, which would put the symbol back on a chunk that
-- just left it.
local function relocated_args(args, chunks, relocated)
    local moved = {}
    for _, c in ipairs(chunks) do
        local r = relocated[c]
        local keep_symbol = not (r and r.scope == "file")
        moved[#moved + 1] = {
            first_line = r and (c.entry.first + r.first_line - 1) or c.abs_first,
            last_line = r and (c.entry.first + r.last_line - 1) or c.abs_last,
            text = c.text,
            expect = c.expect,
            name_path = keep_symbol and c.name_path or nil,
            absolute = true,
        }
    end
    local moved_args = vim.deepcopy(args)
    moved_args.chunks = moved
    moved_args.name_path = nil
    moved_args.first_line, moved_args.last_line = nil, nil
    moved_args.text, moved_args.expect = nil, nil
    moved_args.match, moved_args.absolute = nil, nil
    return moved_args
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
            local entry = entries[c.name_path]
            if not entry then
                -- A name shared by two declarations (Stack/push and
                -- Queue/push) is a tie the name alone cannot break, but
                -- a chunk carries more than the name: its match text, or
                -- its absolute lines, sit in only one of them. Picked
                -- entries are not cached, since the next chunk may pick
                -- the other one.
                local b, picked
                b, entry = resolve_symbol(args.file, c.name_path, function(buf, tied)
                    picked = pick_tied_symbol(buf, tied, c)
                    return picked
                end, tonumber(c.line or c.declared_on or args.line or args.declared_on))
                bufnr = bufnr or b
                if not picked then
                    entries[c.name_path] = entry
                end
            end
            c.entry = entry
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
            local at, count, n, scope, hint_line, hint_text = locate_expected(bufnr,
                { first = doc_first, last = c.entry.last }, want)
            if at then at = at - doc_lines end
            local where = scope == "symbol" and c.entry.path
                or rel_path(vim.api.nvim_buf_get_name(bufnr))
            if at and scope == "file" then
                -- Found, but not in the symbol the caller named: the call's
                -- name_path scopes every chunk that names none, and a chunk
                -- meant for the const block above the function lands here.
                -- The text is in exactly one place, so it is applied there,
                -- and the reply says so; a bounds error here would send the
                -- caller off to do this same search by hand.
                local abs = c.entry.first + at - 1
                c.outside = { named = c.entry.path, abs_first = abs, abs_last = abs + n - 1 }
                if not entries[false] then
                    entries[false] = { first = 1, last = vim.api.nvim_buf_line_count(bufnr),
                        path = rel_path(vim.api.nvim_buf_get_name(bufnr)), whole = true }
                end
                c.entry = entries[false]
                at = abs
            end
            if not at then
                if count == 0 then
                    if hint_line then
                        err("chunk %d: the match text is part of line %d, not the whole line; "
                            .. "match= must be the whole line. Line %d is: %s",
                            c.index, hint_line, hint_line, vim.inspect(hint_text))
                    end
                    -- Both scopes: the symbol the caller named, and the file
                    -- the search went on to cover.
                    if c.name_path then
                        err("chunk %d: the match text is nowhere in %s, nor anywhere else in %s; "
                            .. "re-read it with find_symbol", c.index, c.entry.path, where)
                    end
                    err("chunk %d: the match text is nowhere in %s; re-read it with find_symbol",
                        c.index, where)
                end
            -- Is any of it inside the symbol that was named? "occurs 2 times
            -- in the file; include more context" cannot be acted on when the
            -- text is not in that symbol at all - no amount of context will
            -- put it there.
            local inside = select(2, locate_between(bufnr, doc_first, c.entry.last,
                want, #vim.split(want, "\n", { plain = true }), false))
            if c.name_path and inside == 0 then
                err("chunk %d: the match text is not in %s at all; it occurs %d times elsewhere "
                    .. "in %s. Name the symbol that holds it, or drop name_path to address the "
                    .. "file's own lines", c.index, c.entry.path, count, where)
            end
            err("chunk %d: the match text occurs %d times in %s; include more context",
                    c.index, count, where)
            end
            c.first, c.last, c.expect = at, at + n - 1, c.match
        elseif c.absolute then
            -- Numbers as read_file, grep hits and buffer_lines report them.
            c.first = c.first - c.entry.first + 1
            c.last = c.last - c.entry.first + 1
        end
        local floor = (c.match ~= nil or c.absolute) and (1 - doc_lines) or 1
        if c.outside then
            -- Re-scoped to the whole file above; the symbol's bounds no
            -- longer apply, and its doc comment is not a floor either.
            span, floor, doc_lines = c.entry.last, 1, 0
        end
        if c.first < floor or c.last < c.first or c.last > span then
            err("chunk %d: lines %s-%s are outside the symbol %s, which spans %d-%d (%d lines%s)",
                c.index, tostring(c.first + c.entry.first - 1), tostring(c.last + c.entry.first - 1),
                c.entry.path, c.entry.first, c.entry.last, span,
                doc_lines > 0 and (", doc comment from %d"):format(doc_first) or "")
        end
        c.abs_first = c.entry.first + c.first - 1
        c.abs_last = c.entry.first + c.last - 1
        local conflict = primary_region_conflict(bufnr, c.abs_first, c.abs_last)
        if conflict then err("chunk %d: %s", c.index, conflict) end
        -- "" deletes the lines, as it does in replace_pattern; it used to
        -- leave one blank line behind and need a second call.
        c.new_lines = c.text == "" and {}
            or vim.split((c.text:gsub("\n$", "")), "\n", { plain = true })
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
    -- Line numbers are read off a snapshot - a find_symbol body, a grep hit -
    -- and the code moves under them. Numbers relative to a symbol survive an
    -- edit above it, because the symbol is resolved again on every call and
    -- the offsets are counted from wherever its declaration is now; absolute
    -- numbers survive nothing, and either kind is shifted by an earlier edit
    -- inside the same symbol. The numbers stay perfectly valid-looking after
    -- the shift, so the edit lands on the wrong lines and silently replaces
    -- working code. `expect` is the guard: give the text those lines are
    -- supposed to hold and a stale offset fails loudly instead. The refusal
    -- also does the search the caller would do next: when the expected text
    -- sits in exactly one place, it offers the relocated edit as a code
    -- action, so the fix is one apply_code_action call and no re-read.
    local stale, relocated, narrow, anchored = {}, {}, {}, {}
    for _, c in ipairs(chunks) do
        if c.expect ~= nil and not args.force then
            local want = vim.trim((c.expect:gsub("\n+$", "")))
            local want_lines = vim.split(want, "\n", { plain = true })
            local have = vim.trim(table.concat(c.old, "\n"))
            -- Indentation alone is not drift: a format pass that re-indented
            -- the region left the same text on the same lines.
            local moved = want ~= have and indent_blind(want_lines) ~= indent_blind(c.old)
            if moved then
                local at, count, n, scope, hint_line, hint_text = locate_expected(bufnr, c.entry, want)
                -- An expect= that covers a different number of lines than the
                -- range is a different mistake from a stale offset, and the
                -- two must not be treated alike. Relocating a shorter expect
                -- to wherever its text sits shrinks the edit to those lines:
                -- a 79-line replacement guarded by its own first line becomes
                -- a one-line replacement, and the other 78 lines stay where
                -- they are, below the new text. Only an expect that covers
                -- the whole range relocates; a length mismatch is refused,
                -- and narrowing is offered as a code action instead.
                local sized = #want_lines == #c.old
                local head = not sized and #c.old > #want_lines
                    and indent_blind(vim.list_slice(c.old, 1, #want_lines)) == indent_blind(want_lines)
                if head then
                    -- The requested range starts with exactly the text the
                    -- caller expected, so the offset is not stale, which is
                    -- the only thing expect= exists to prove. Refusing here
                    -- taught nobody: callers kept sending a short expect for a
                    -- long range, and that refusal was the largest open
                    -- friction cluster in the digest, six of sixteen leaving
                    -- the caller stuck. A short expect is a prefix anchor on
                    -- the first lines of the range from now on, and the reply
                    -- says how much of the range it actually vouched for.
                    anchored[#anchored + 1] = ("expect= covered the first %d of the %d lines "
                        .. "replaced (lines %d-%d of %s), so it anchored the start of the range "
                        .. "and said nothing about the rest of it. match= guards the whole of "
                        .. "what it names."):format(#want_lines, #c.old, c.first, c.last, c.entry.path)
                else
                    stale[#stale + 1] = { c = c, have = have, want = want, at = at, want_n = #want_lines,
                        count = count, n = n, scope = scope, sized = sized, head = head,
                        hint_line = hint_line, hint_text = hint_text }
                    if sized and at then
                        -- The relocated range is as long as the expected text,
                        -- which is also as long as the requested one.
                        relocated[c] = { first_line = at, last_line = at + n - 1, scope = scope }
                    elseif at then
                        narrow[c] = { first_line = at, last_line = at + n - 1, scope = scope }
                    end
                end
            end
        end
    end
    if #stale > 0 then
        local lines = {}
        local everywhere = vim.tbl_count(relocated) == #stale
        -- Every stale chunk sits in exactly one other place, and the search
        -- that found it is the one the caller would do next before calling
        -- again with the new numbers. Do that call now: apply at the
        -- relocated lines, and say so in the reply. The refusal below is
        -- for the cases with nothing safe to do - text that is nowhere, or
        -- in two places.
        if everywhere and not args._relocating then
            local moved_args = relocated_args(args, chunks, relocated)
            moved_args._relocating = true
            local result = replace_symbol_lines(moved_args)
            local moves = {}
            for _, s in ipairs(stale) do
                local abs_first = s.c.entry.first + s.at - 1
                moves[#moves + 1] = {
                    requested = ("lines %d-%d of %s"):format(s.c.first, s.c.last, s.c.entry.path),
                    applied_at = s.scope == "symbol"
                        and ("lines %d-%d of %s (buffer lines %d-%d)"):format(
                            s.at, s.at + s.n - 1, s.c.entry.path, abs_first, abs_first + s.n - 1)
                        or ("buffer lines %d-%d, outside %s"):format(
                            abs_first, abs_first + s.n - 1, s.c.entry.path),
                    found_at_requested = s.have,
                }
            end
            result.relocated = moves
            result.relocated_note = ("%d chunk(s) did not hold the expected text at the requested lines; "
                .. "the numbers were from before an earlier edit shifted them. The expected text was "
                .. "in exactly one other place, so the edit was applied there instead - the lines above "
                .. "say where. Later numbers for this file are stale too: re-read it, or use match=.")
                :format(#moves)
            return result
        end
        for _, s in ipairs(stale) do
            if not s.sized then
                -- Length mismatch: say both counts, and never narrow to the
                -- shorter text on the caller's behalf.
                lines[#lines + 1] = ("expect covers %d line(s), but lines %d-%d of %s cover %d, so it "
                        .. "cannot say what the rest of the range holds.\nexpect: %s\nfound:  %s")
                    :format(s.want_n, s.c.first, s.c.last, s.c.entry.path, #s.c.old,
                        vim.inspect(s.want), vim.inspect(s.have))
                if s.at then
                    local abs = s.c.entry.first + s.at - 1
                    lines[#lines + 1] = ("the expected text is %d line(s) at buffer lines %d-%d, which is not "
                            .. "the range that was asked for."):format(s.n, abs, abs + s.n - 1)
                elseif s.count > 1 then
                    lines[#lines + 1] = ("the expected text occurs %d times in the file; it names no single "
                        .. "range."):format(s.count)
                else
                    lines[#lines + 1] = "the expected text is nowhere else either; re-read the region."
                end
                goto next_stale
            end
            lines[#lines + 1] = ("lines %d-%d of %s do not hold the expected text, so the numbers are "
                    .. "probably from before an earlier edit shifted them.\nexpected: %s\nfound:    %s")
                :format(s.c.first, s.c.last, s.c.entry.path, vim.inspect(s.want), vim.inspect(s.have))
            local where = s.scope == "symbol" and s.c.entry.path
                or rel_path(vim.api.nvim_buf_get_name(bufnr))
            if s.at and s.scope == "symbol" then
                lines[#lines + 1] = ("the expected text is at lines %d-%d (relative) instead."):format(
                    s.at, s.at + s.n - 1)
            elseif s.at then
                -- Outside the symbol, where a relative number would be
                -- negative or past its end: name the buffer lines the code
                -- action is going to use.
                local abs = s.c.entry.first + s.at - 1
                lines[#lines + 1] = ("the expected text is outside %s, at buffer lines %d-%d instead."):format(
                    s.c.entry.path, abs, abs + s.n - 1)
            elseif s.count > 1 then
                lines[#lines + 1] = ("the expected text occurs %d times in %s; pick with more context."):format(
                    s.count, where)
            elseif s.hint_line then
                lines[#lines + 1] = ("the expected text is part of line %d, not the whole line; "
                        .. "expect= must be the whole line. Line %d is: %s")
                    :format(s.hint_line, s.hint_line, vim.inspect(s.hint_text))
            else
                lines[#lines + 1] = ("the expected text is nowhere in %s; re-read it with find_symbol."):format(
                    where)
            end
            ::next_stale::
        end
        local actions = {}
        if everywhere then
            -- Reached only from a relocated call that went stale again (the
            -- file changed between the two): offer the action rather than
            -- chase it.
            actions[#actions + 1] = {
                title = "apply the same edit at the relocated lines",
                args = relocated_args(args, chunks, relocated),
            }
        end
        -- Narrowing to the lines the expect text covers is a real intention
        -- (a caller who miscounted the last line), just not one to guess at:
        -- offered here, applied only when it is chosen.
        -- Narrowing to the lines the expect text covers is offered only when
        -- the text sent with the call fits there. Text written for the whole
        -- range, dropped onto the one line that was quoted, leaves the rest of
        -- the range below it - the duplication this refusal exists to prevent,
        -- reached by taking the fix it offered. Every agent that took that
        -- action in testing hit exactly that, so it is withheld rather than
        -- labelled: for such a call, applying at the requested lines is the
        -- action that matches what the text was written for.
        local targeted, all_targeted, all_fit = {}, true, true
        for _, s in ipairs(stale) do
            local t = relocated[s.c] or narrow[s.c]
            targeted[s.c] = t
            if not t then
                all_targeted = false
            elseif #s.c.new_lines > (t.last_line - t.first_line + 1) then
                all_fit = false
            end
        end
        if not everywhere and all_targeted and all_fit then
            local title = "replace only the lines each chunk's expect text covers"
            if #stale == 1 then
                local c = stale[1].c
                local t = targeted[c]
                local abs_first = c.entry.first + t.first_line - 1
                local abs_last = c.entry.first + t.last_line - 1
                title = ("replace only the %d line(s) the expect text covers (buffer lines %d-%d)"):format(
                    abs_last - abs_first + 1, abs_first, abs_last)
            end
            actions[#actions + 1] = { title = title, args = relocated_args(args, chunks, targeted) }
        end
        -- A call refused for one stale chunk out of several: the chunks that
        -- did match are still right, and re-sending them by hand is the work
        -- the caller has already done once.
        if #chunks > #stale then
            local kept = {}
            for _, c in ipairs(chunks) do
                local is_stale = false
                for _, s in ipairs(stale) do
                    if s.c == c then is_stale = true end
                end
                if not is_stale then
                    kept[#kept + 1] = {
                        first_line = c.abs_first, last_line = c.abs_last, text = c.text,
                        expect = c.expect, name_path = c.name_path, absolute = true,
                    }
                end
            end
            local kept_args = vim.deepcopy(args)
            kept_args.chunks = kept
            kept_args.name_path, kept_args.first_line, kept_args.last_line = nil, nil, nil
            kept_args.text, kept_args.expect, kept_args.match, kept_args.absolute = nil, nil, nil, nil
            actions[#actions + 1] = {
                title = ("apply only the %d chunk(s) that matched, leaving the %d stale one(s)")
                    :format(#kept, #stale),
                args = kept_args,
            }
        end
        actions[#actions + 1] = {
            title = "apply at the requested lines anyway (ignore expect)",
            args = vim.tbl_extend("force", args, { force = true })
        }
        action_token = action_token + 1
        local token = tostring(action_token)
        action_cache[token] = { edit = "replace_symbol_lines", actions = actions }
        -- A literal `index=N` is not a call anybody can make, and when the
        -- token is itself a short number the whole line reads as a template
        -- with nothing filled in. Each action is printed as the call that
        -- runs it, token quoted.
        local calls = {}
        for i, a in ipairs(actions) do
            calls[#calls + 1] = ("apply_code_action(token=%q, index=%d) = %s")
                :format(token, i, a.title)
        end
        -- The last action here is the destructive one: it writes at line
        -- numbers that have already been shown to be wrong.
        calls[#calls + 1] = "or read the region again (read_file, or find_symbol with "
            .. "include_body) and send the edit with match= instead, which needs no line numbers"
        err("%s\n%s", table.concat(lines, "\n"), table.concat(calls, "\n"))
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
    -- The declarations these chunks are inside, and the files that use them:
    -- a chunk that changes a signature breaks its callers, and this is what
    -- gets those files loaded and asked before the verdict is taken.
    local seeds = {}
    for _, c in ipairs(chunks) do
        if c.entry then seeds[#seeds + 1] = c.entry end
    end
    local cl = closure.plan({
        bufnr = bufnr, root = args.root, settle = settle_before_edit,
        seeds = #seeds > 0 and seeds or nil,
        region = { first = chunks[1].abs_first, last = chunks[#chunks].abs_last },
    })
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
        { replaced = label }, symbols > 1 and regions or nil, cl)
    if #anchored > 0 then
        result.expect_was_a_prefix = anchored
    end
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
    -- Chunks whose match text was outside the symbol they were scoped to.
    local outside = {}
    for _, c in ipairs(chunks) do
        if c.outside then
            outside[#outside + 1] = {
                chunk = c.index,
                named = c.outside.named,
                applied_at = ("buffer lines %d-%d, outside %s"):format(
                    c.outside.abs_first, c.outside.abs_last, c.outside.named),
            }
        end
    end
    if #outside > 0 then
        result.relocated = result.relocated or {}
        vim.list_extend(result.relocated, outside)
        result.relocated_note = ((result.relocated_note and (result.relocated_note .. " ") or "")
            .. "%d chunk(s) matched text outside the symbol they were scoped to (the call's "
            .. "name_path is the default for every chunk that names none); the text was in "
            .. "exactly one place, so the edit was applied there."):format(#outside)
    end
    return result
end

-- How many blank lines separate two top-level declarations in this language.
-- PEP 8 and black both require two in Python, and one everywhere else here.
local function blank_separator(bufnr)
    return vim.bo[bufnr].filetype == "python" and 2 or 1
end

-- Formats whose objects separate their members with a comma. YAML and TOML
-- need nothing between two members, which is why the same bug was never seen
-- in them.
local JSON_LIKE = { json = true, jsonc = true, json5 = true }

-- Where a comma has to go so that inserting next to `entry` leaves the object
-- valid, or nil when the format needs none. `on_text` puts it after the
-- inserted text (something already follows the anchor); `on_anchor` puts it
-- after the anchor's own last line at row `row` (the anchor was the last
-- member, so it is now followed by one).
local function json_pair_separator(bufnr, entry, where)
    if not JSON_LIKE[vim.bo[bufnr].filetype] or entry.kind ~= "pair" then
        return nil
    end
    if where ~= "after" then
        -- The anchor follows the new text, so the new text needs the comma
        -- whatever else is around it.
        return { on_text = true }
    end
    -- What is on the anchor's last line after the anchor itself. A comma
    -- there means another member follows and the new text needs its own;
    -- anything else (the object's closing brace, or nothing at all because
    -- the brace is on the next line) means the anchor was the last member.
    local rest = entry.last_col
        and ((vim.api.nvim_buf_get_lines(bufnr, entry.last - 1, entry.last, false)[1] or "")
            :sub(entry.last_col + 1))
        or ""
    if vim.trim(rest):sub(1, 1) == "," then
        return { on_text = true }
    end
    return { on_anchor = true, row = entry.last }
end

local function insert_symbol_tool(where)
    return function(args)
        local bufnr, entry = resolve_symbol(args.file, args.name_path, nil, tonumber(args.line))
        if type(args.text) ~= "string" or args.text == "" then
            err("missing required argument: text")
        end
        local lines = vim.split((args.text:gsub("\n$", "")), "\n", { plain = true })
        local ft = vim.bo[bufnr].filetype
        -- A blank line belongs between two functions and nowhere near two
        -- constants: inserting a sibling into a `const (...)` or `var (...)`
        -- block should not split the block in half. Single-line declarations
        -- are the ones that live in such groups.
        -- Text that already begins (or ends) with a blank line does not want
        -- another one: the two together left a double blank that gofmt then
        -- reported as dirty, with nothing said in the reply.
        -- One blank line reads as the separator everywhere except Python,
        -- where PEP 8 and black want two between top-level definitions: an
        -- insert into black's own source produced one blank above the new
        -- function and two below it, which black would reformat in CI.
        -- Never inside a data file: a blank line between two members of a
        -- JSON object is not how anyone writes one, and the tool put one
        -- there while also leaving the object unparseable.
        local spaced = (entry.last - entry.first) > 0 and not JSON_LIKE[ft]
            and ft ~= "yaml" and ft ~= "toml"
        -- The wider separator is a top-level rule: two blank lines between
        -- methods inside a Python class is one too many.
        local anchor = vim.api.nvim_buf_get_lines(bufnr, entry.first - 1, entry.first, false)[1] or ""
        local sep = anchor:match("^%s") == nil and blank_separator(bufnr) or 1
        -- What a JSON object needs between two members and nothing else in
        -- this tool ever supplied. Inserting after `"alpha": {...}` used to
        -- put the new pair straight below it with no comma anywhere, and the
        -- reply said "applied and saved to disk" over a file json.load could
        -- no longer read.
        local comma = json_pair_separator(bufnr, entry, where)
        local separator
        if comma and comma.on_text and not lines[#lines]:match(",%s*$") then
            lines[#lines] = lines[#lines] .. ","
            separator = "a comma was added after the inserted text: a JSON object "
                .. "separates its members with one"
        end
        local row -- 0-based insertion point
        if where == "after" then
            row = entry.last
            if spaced and lines[1] ~= "" then
                for _ = 1, sep do table.insert(lines, 1, "") end
            end
        else
            -- Above the whole declaration, its decorators and doc comment
            -- included, so a new sibling never lands between @Decorator (or
            -- a Rust #[attr], or a Python decorator) and the thing it
            -- annotates, which is a syntax error.
            row = decl_block_top(bufnr, entry.first) - 1
            if spaced and lines[#lines] ~= "" then
                for _ = 1, sep do table.insert(lines, "") end
            end
        end
        local conflict = primary_region_conflict(bufnr, row + 1, row + 1)
        if conflict then err(conflict) end
        -- The anchor was the object's last member, so the comma goes after
        -- it rather than after the new text. That rewrites the anchor's last
        -- line, so the whole thing is written as one region and the ledger
        -- holds it: an undo that gave back the inserted lines and left a
        -- stray comma behind would be no undo at all.
        local anchor_line, anchor_row
        if comma and comma.on_anchor then
            anchor_row = comma.row
            anchor_line = vim.api.nvim_buf_get_lines(bufnr, anchor_row - 1, anchor_row, false)[1] or ""
            separator = "a comma was added after " .. entry.path
                .. ": it was the object's last member and now has one after it"
        end
        -- Checked before it is written, like every other edit tool: files=
        -- probes each file with dry_run before it writes any of them, and a
        -- tool that ignores the flag inserted the text once for the probe
        -- and once for the edit, in every file it was given.
        if args.dry_run then
            local preview, at = lines, ("+%d,%d"):format(row + 1, #lines)
            if anchor_line then
                preview = vim.list_extend({ anchor_line .. "," }, lines)
                at = ("+%d,%d"):format(anchor_row, #preview)
            end
            return vim.tbl_extend("force",
                { file = rel_path(vim.api.nvim_buf_get_name(bufnr)), separator = separator },
                preview_diff(anchor_line and { anchor_line } or {}, preview,
                    ("%s %s"):format(where, entry.path), at))
        end
        settle_before_edit(bufnr)
        local before = diag_snapshot()
        if anchor_line then
            local written = vim.list_extend({ anchor_line .. "," }, lines)
            vim.api.nvim_buf_set_lines(bufnr, anchor_row - 1, anchor_row, false, written)
            return finish_edit(bufnr, args, before, entry.path, "insert_" .. where,
                anchor_row, anchor_row, { anchor_line }, #written,
                { inserted = ("%s %s"):format(where, entry.path), separator = separator })
        end
        vim.api.nvim_buf_set_lines(bufnr, row, row, false, lines)
        return finish_edit(bufnr, args, before, entry.path, "insert_" .. where, row + 1, row,
            {}, #lines, { inserted = ("%s %s"):format(where, entry.path), separator = separator })
    end
end

-- Insert text at a line, with no symbol to anchor it to. The symbol inserts
-- cover everything that has a declaration to sit next to; a file whose first
-- statement is a bare call has none, and prepending a guard to it used to
-- mean quoting its first line into replace_symbol_lines, or falling back to
-- a shell `cat`. `files` takes the same text to each of several files, which
-- is how that guard reaches a directory of them in one call.
local function insert_lines(args)
    if type(args.text) ~= "string" or args.text == "" then
        err("missing required argument: text")
    end
    local at = args.at
    if at ~= nil and at ~= "start" and at ~= "end" then
        err("at must be start or end")
    end
    local line = args.line ~= nil and tonumber(args.line) or nil
    if line and at then
        err("give line, or at=start/end, not both")
    end
    if not line and not at then
        err("missing required argument: line (1-based; the text lands above that line), "
            .. "or at=start/end")
    end
    local wanted = {}
    if type(args.file) == "string" and args.file ~= "" then wanted[1] = args.file end
    for _, f in ipairs(args.files or {}) do wanted[#wanted + 1] = f end
    if #wanted == 0 then
        err("missing required argument: file (or files, for the same text in several)")
    end
    local seen, files = {}, {}
    for _, f in ipairs(wanted) do
        local path = vim.fn.fnamemodify(f, ":p")
        if not seen[path] then
            seen[path] = true
            files[#files + 1] = path
        end
    end
    -- Only the final line terminator goes, not the blank lines before it: a
    -- guard inserted with a blank line after it landed flush against the
    -- next statement, and the tool documents that the text lands as given.
    local lines = vim.split((args.text:gsub("\n$", "")), "\n", { plain = true })
    -- Every file is resolved and bounds-checked before any of them is
    -- written, so a line number that is past the end of the fourth file
    -- does not leave the first three edited.
    local targets = {}
    for _, path in ipairs(files) do
        local bufnr = load_buf(path)
        local total = vim.api.nvim_buf_line_count(bufnr)
        local row -- 0-based insertion point
        if at == "start" then
            row = 0
        elseif at == "end" then
            row = total
        else
            if line < 1 or line > total + 1 then
                err("%s: line %d is outside the file, which has %d lines (line %d appends)",
                    rel_path(path), line, total, total + 1)
            end
            row = line - 1
        end
        local conflict = primary_region_conflict(bufnr, row + 1, row + 1)
        if conflict then err("%s: %s", rel_path(path), conflict) end
        targets[#targets + 1] = { bufnr = bufnr, row = row, path = path }
    end
    if args.dry_run then
        local previews = {}
        for _, t in ipairs(targets) do
            previews[#previews + 1] = vim.tbl_extend("force",
                { file = rel_path(t.path) },
                preview_diff({}, lines, ("%d line(s) above line %d"):format(#lines, t.row + 1),
                    ("+%d,%d"):format(t.row + 1, #lines)))
        end
        if #previews == 1 then return previews[1] end
        return { chunks = previews }
    end
    -- One call is one undo step, however many files it wrote: undoing an
    -- insert over three files took three undo_edit calls, and a caller who
    -- did not check was left with two of them still inserted.
    local reports = {}
    require("agent99.edits").as_one_step(function()
        for _, t in ipairs(targets) do
            settle_before_edit(t.bufnr)
            local before = diag_snapshot()
            vim.api.nvim_buf_set_lines(t.bufnr, t.row, t.row, false, lines)
            reports[#reports + 1] = finish_edit(t.bufnr, args, before,
                ("%s:%d"):format(rel_path(t.path), t.row + 1), "insert_lines", t.row + 1, t.row,
                {}, #lines, { inserted = ("%d line(s) above line %d"):format(#lines, t.row + 1) })
        end
    end)
    if #reports == 1 then return reports[1] end
    return { files = #reports, reports = reports }
end

-- How many of an undo's reverted files the reply lists by name. One bulk
-- edit's undo is one step to the caller and hundreds of file entries to the
-- reply; past this many the count says it better than the list does.
local MAX_UNDONE_SHOWN = 40

local function undo_edit(args)
    local edits = require("agent99.edits")
    local count = (not args.all) and (tonumber(args.count) or 1) or nil
    -- What the other clients sharing this editor have pending, read before
    -- anything is undone: their entries are in their own ledgers and are
    -- never reached from here, and a reply that says nothing about them
    -- reads as "there was nothing else to undo".
    local others = edits.others()
    if edits.count() == 0 then
        local out = {
            undone = {},
            note = "no symbol edits recorded for you in this workspace; apply_code_action "
                .. "edits are not tracked here - reverse a server's own action with another "
                .. "code action or an edit (an action offered by a refused edit is tracked: "
                .. "it re-runs that edit tool)",
        }
        if others.clients > 0 then
            out.other_clients = ("%d other client(s) sharing this workspace have %d undo step(s) "
                .. "of their own on it. Those are not yours and undo_edit will not reach them; "
                .. "what they wrote is still in the files"):format(others.clients, others.steps)
        end
        return out
    end
    local last_bufnr
    -- The closure of what is about to be put back, worked out before the
    -- snapshot: an undo puts an older shape of a symbol back and breaks the
    -- files that had been updated to the new one, and skip=true leaves half a
    -- rename standing on purpose. The reply said "no new errors or warnings"
    -- with an import in another file naming a symbol the undo had just
    -- removed.
    local target_files = edits.pending_files(count)
    local cl
    for _, path in ipairs(target_files) do
        local okb, b = pcall(load_buf, path)
        if okb then
            settle_before_edit(b)
            -- extra_paths: the other files this undo step touches belong in
            -- the closure whatever the reference graph says, because half of
            -- a rename left standing is exactly what skip=true produces.
            local part = closure.plan({
                bufnr = b, root = args.root, settle = settle_before_edit,
                extra_paths = target_files,
            })
            cl = cl and closure.merge(cl, part) or part
        end
    end
    local before = diag_snapshot()
    local undone, refused, dropped = edits.undo_last(count, args.skip == true)
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
    -- Steps left, not files left: one rename across seven files is one. Left
    -- of this client's own edits: another client's stand whatever this says.
    --
    -- The list is budgeted, because undoing one bulk edit answered with 2,431
    -- lines over 59 KB - one entry per file the edit had touched - and the
    -- `remaining` a caller actually reads was buried inside it. What each
    -- entry says is the same sentence with a different file name in it; the
    -- count is the part that carries information once there are hundreds.
    local shown_undone = out
    if #out > MAX_UNDONE_SHOWN then
        shown_undone = vim.list_slice(out, 1, MAX_UNDONE_SHOWN)
    end
    local result = { undone = shown_undone, remaining = edits.operations() }
    result.undone_entries = cap.fields(#shown_undone, #out, {
        unit = "reverted files",
        reach = "all of them were reverted; only the listing is cut",
    })
    if others.clients > 0 then
        result.other_clients = ("%d other client(s) share this workspace and had %d undo step(s) "
            .. "on it, which this call did not touch: the ledger is per client, so undo_edit "
            .. "only ever reaches your own edits"):format(others.clients, others.steps)
    end
    if #dropped > 0 then
        result.dropped = cap.list(dropped, MAX_UNDONE_SHOWN, "forgotten entries",
            "each was left as it stands in the file")
        result.dropped_note = "skip=true: these entries could not be undone and were forgotten, "
            .. "so the ones under them could be reached. What they wrote is still in the file."
    end
    if #refused > 0 and #dropped == 0 then
        result.refused = cap.list(refused, MAX_UNDONE_SHOWN, "refused entries",
            "they were all left alone")
        result.refused_note = "the entries under this one were left alone, because undoing them "
            .. "over a region that has changed would clobber it. Fix that region by hand, or "
            .. "pass skip=true to forget this entry and undo the rest."
    elseif #refused > 0 then
        result.refused = cap.list(refused, MAX_UNDONE_SHOWN, "refused entries",
            "they were all left alone")
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
        -- Every buffer this undo wrote to, not only the last one: the rest
        -- reached the reply as "elsewhere in the project" - errors only, and
        -- unattributed - though the undo is exactly what put them there.
        local own = {}
        for _, e in ipairs(undone) do
            if e.bufnr and vim.api.nvim_buf_is_valid(e.bufnr) then own[e.bufnr] = true end
        end
        result = vim.tbl_extend("error", result,
            post_edit_report(last_bufnr, before, args.root, args.headless, opts,
                args.full_diagnostics, { own = own, closure = cl }))
        result.note = edit_note(args)
    end
    return result
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

-- Files that hold a reference to the symbol and are not in the rename's
-- workspace edit. bash-language-server implements rename with document scope
-- only: a rename of a function defined in one shell module and called from
-- five others reported one file, one edit, no diagnostics, and left the five
-- callers calling a name that no longer exists. The check asks the server the
-- other question it can answer about the same position, so it needs to know
-- nothing about any particular server to catch the mismatch.
local function references_outside(client, bufnr, params, files)
    if not client:supports_method("textDocument/references") then return nil end
    local rp = vim.deepcopy(params)
    rp.newName = nil
    rp.context = { includeDeclaration = true }
    local ok, refs = pcall(request, client, bufnr, "textDocument/references", rp)
    if not ok or type(refs) ~= "table" then return nil end
    local touched = {}
    for _, f in ipairs(files) do touched[f.file] = true end
    local extra, seen = {}, {}
    for _, r in ipairs(refs) do
        local file = r.uri and vim.uri_to_fname(r.uri)
        if file and not touched[file] and not seen[file] then
            seen[file] = true
            extra[#extra + 1] = rel_path(file)
        end
    end
    table.sort(extra)
    return #extra > 0 and extra or nil
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
    local untouched = references_outside(client, bufnr, params, files)
    local scope_note = untouched and (("the server reports references to this symbol in %d "
        .. "file(s) that the rename does not touch. Some servers - bash-language-server is "
        .. "one - rename within a single document only, and the rest of the project keeps "
        .. "calling the old name. replace_pattern with kind=code over those files renames "
        .. "the rest; references(file, line) lists every one."):format(#untouched)) or nil
    if args.dry_run then
        -- The dry run is the call made to decide whether to trust the
        -- rename, so it is the one that most needs the caveat.
        local missing_dry = core.deps_missing(args.root or vim.fn.getcwd())
        return { dry_run = true, new_name = new_name, files = files,
            total_edits = total, file_operations = #file_ops > 0 and file_ops or nil,
            references_not_renamed = untouched, references_not_renamed_note = scope_note,
            may_be_incomplete = missing_dry and ("the language server cannot resolve this "
                .. "project's imports (" .. missing_dry .. ") so call sites in other packages "
                .. "are missing from this list; grep for the name to see them") or nil,
            note = "nothing applied; call again without dry_run to rename" }
    end
    -- Every touched file is loaded before anything is applied. load_buf
    -- refuses a file that changed on disk while this session holds unsaved
    -- edits to it, and that refusal has to stop the rename here: applying
    -- anyway would edit a buffer nobody had snapshotted, with no undo.
    -- Each freshly loaded buffer is settled too, so the problems it
    -- already had are in the baseline and not charged to the rename.
    local snaps = {}
    for _, f in ipairs(files) do
        local b = load_buf(f.file)
        settle_before_edit(b)
        snaps[#snaps + 1] = { bufnr = b, file = f.file }
    end
    settle_before_edit(bufnr)
    local before = diag_snapshot()
    -- Whole-file snapshots of every touched file feed the undo ledger.
    for _, snap in ipairs(snaps) do
        snap.old = vim.api.nvim_buf_get_lines(snap.bufnr, 0, -1, false)
    end
    vim.lsp.util.apply_workspace_edit(edit, client.offset_encoding)
    -- One rename is one undo step, however many files it reached: undoing it
    -- file by file leaves the project half-renamed and uncompilable.
    require("agent99.edits").as_one_step(function()
        for _, snap in ipairs(snaps) do
            local new = vim.api.nvim_buf_get_lines(snap.bufnr, 0, -1, false)
            record_edit(snap.bufnr, "rename " .. new_name, "rename", 1, #snap.old, snap.old, new)
        end
    end)
    local result = { renamed_to = new_name, files = files, total_edits = total,
        file_operations = #file_ops > 0 and file_ops or nil,
        references_not_renamed = untouched, references_not_renamed_note = scope_note }
    -- A rename reaches exactly as far as the server's references do.
    local missing = core.deps_missing(args.root)
    if missing then
        result.may_be_incomplete = "the language server cannot resolve this project's imports ("
            .. missing .. ") so call sites in other packages were not renamed; grep for the old "
            .. "name before trusting this"
    end
    local own = {}
    for _, snap in ipairs(snaps) do own[snap.bufnr] = true end
    result = vim.tbl_extend("error", result,
        post_edit_report(bufnr, before, args.root, args.headless, nil, args.full_diagnostics,
            { own = own }))
    result.note = edit_note(args)
    return result
end

-- ---------------------------------------------------------------------------
-- replace_pattern: the same shape of change in many places.
--
-- Not every bulk edit is a rename. When a call site moves from one receiver
-- to another (root.finiteNum(x) -> Sanitize.finiteNum(x)) the identifier the
-- language server knows does not change at all, so rename_symbol has nothing
-- to offer, and a hundred replace_symbol_lines chunks is not a real option.
-- That left the shell, and a sed -i over the file is outside everything this
-- plugin exists for: no ledger, no diagnostics, no idea what it touched.
--
-- This keeps it inside the editor - the same buffers, the same undo ledger,
-- the same verdict afterwards - and adds the one thing sed cannot do, which
-- is to leave a match inside a comment or a string literal alone.

local MAX_PATTERN_FILES = 400

-- The files a pattern call works over, absolute and deduplicated.
local function pattern_files(args)
    local wanted, glob_note = {}, nil
    for _, f in ipairs(args.files or {}) do
        wanted[#wanted + 1] = f
    end
    if type(args.glob) == "string" and args.glob ~= "" then
        local paths, why = core.expand_glob(args.root, args.glob)
        glob_note = why
        vim.list_extend(wanted, paths)
    end
    if #wanted == 0 then
        err("%s", glob_note
            or "no files to work on: pass files (array of paths) and/or glob")
    end
    local seen, out = {}, {}
    for _, f in ipairs(wanted) do
        local path = vim.fn.fnamemodify(f, ":p")
        if not seen[path] then
            seen[path] = true
            local rel = rel_path(path)
            local is_test = core.is_test_path(rel)
            if args.tests == "only" and not is_test then
                -- filtered out
            elseif args.tests == "exclude" and is_test then
                -- filtered out
            else
                out[#out + 1] = path
            end
        end
    end
    return out
end

-- Characters that mean something in very magic mode which a caller quoting a
-- line of code does not expect them to. `=` is the one that matters: it makes
-- the atom before it optional, and most lines of code contain one, so an
-- alternation of first-lines quietly matches only the branches without an `=`.
local VERY_MAGIC_TRAPS = {
    ["="] = "`=` makes the atom before it optional",
    ["<"] = "`<` and `>` are word boundaries",
    [">"] = "`<` and `>` are word boundaries",
    ["@"] = "`@` introduces a lookaround or a multi",
    ["{"] = "`{ }` is a count",
    ["~"] = "`~` matches the text of the last substitution",
}

-- The trap characters a pattern uses unescaped, each explained once.
local function very_magic_traps(pattern)
    local seen, out = {}, {}
    local i = 1
    while i <= #pattern do
        local c = pattern:sub(i, i)
        if c == "\\" then
            i = i + 2
        else
            local why = VERY_MAGIC_TRAPS[c]
            if why and not seen[why] then
                seen[why] = true
                out[#out + 1] = why
            end
            i = i + 1
        end
    end
    return out
end

-- A pattern's top-level alternatives: the branches of an unparenthesized
-- `a|b|c`, which is how a caller asks for several unrelated lines in one
-- call. Branches inside a group or a bracket expression are that group's
-- business, and an escaped \| is a literal bar.
local function top_level_alternatives(pattern)
    local alts, start, depth, in_class, i = {}, 1, 0, false, 1
    while i <= #pattern do
        local c = pattern:sub(i, i)
        if c == "\\" then
            i = i + 1
        elseif in_class then
            if c == "]" then in_class = false end
        elseif c == "[" then
            in_class = true
        elseif c == "(" then
            depth = depth + 1
        elseif c == ")" then
            depth = depth - 1
        elseif c == "|" and depth == 0 then
            alts[#alts + 1] = pattern:sub(start, i - 1)
            start = i + 1
        end
        i = i + 1
    end
    alts[#alts + 1] = pattern:sub(start)
    return alts
end

-- The Vim regex a call's pattern and replacement become. literal=true means
-- the caller wants the bytes it wrote and nothing about them read as syntax,
-- on both sides; otherwise the pattern is very magic (\v), which is close to
-- an extended regular expression, and \1..\9 in the replacement are groups.
local function pattern_regex(args)
    local pattern, replacement = args.pattern, args.replacement
    -- \C: case sensitive whatever 'ignorecase' is set to in this editor. A
    -- bulk replace that quietly matched more or less depending on a user
    -- setting would be the worst kind of surprise. A caller who wants the
    -- other behaviour puts \c in the pattern, which wins for being later.
    if args.literal then
        -- \V: backslash is the only character left with a meaning in the
        -- pattern. & ~ and \ are the ones with a meaning in a replacement.
        local escaped = vim.fn.escape(pattern, "\\")
        return "\\C\\V" .. escaped,
            vim.fn.escape(replacement, "\\&~"),
            function(col) return "\\C\\V\\%" .. col .. "c" .. escaped end
    end
    -- The contract for the replacement is "\1..\9 are the groups", nothing
    -- else: a bare & (the whole match) or ~ (the previous replacement) is
    -- text the caller wrote, so it is escaped. Backslash sequences pass
    -- through untouched, which keeps \1..\9, \n and \\ meaning what they do.
    local out, i = {}, 1
    while i <= #replacement do
        local c = replacement:sub(i, i)
        if c == "\\" then
            out[#out + 1] = replacement:sub(i, i + 1)
            i = i + 2
        else
            if c == "&" or c == "~" then out[#out + 1] = "\\" end
            out[#out + 1] = c
            i = i + 1
        end
    end
    return "\\C\\v" .. pattern, table.concat(out),
        function(col) return "\\C\\v%" .. col .. "c%(" .. pattern .. ")" end
end

-- Every match of `re` in `line`, as 0-based [start, stop) byte pairs.
local function match_spans(pat, line)
    local spans, from = {}, 0
    while from <= #line do
        -- matchstrpos with a count matches against the whole line from
        -- byte `from` on, so ^, \<, > and a lookbehind still see what is
        -- before the match. Cutting the line at `from` instead would make
        -- ^ab match twice in abab and \<foo match in the middle of foofoo.
        local m = vim.fn.matchstrpos(line, pat, from, 1)
        local s, e = m[2], m[3]
        if s < 0 then break end
        if e <= s then
            -- A zero-width match replaces nothing and would loop here
            -- forever; the pattern is not one this tool can act on.
            return spans, true
        end
        spans[#spans + 1] = { s, e }
        from = e
    end
    return spans, false
end

-- What the replacement expands to for the match at span [s, e) of `line`,
-- computed against the whole line so a group, a lookaround or a \< in the
-- pattern reads the same context it matched in. Every span is expanded
-- against the original line, as :substitute does, so one replacement
-- cannot change what the next one sees.
local function expand_at(line, pat, anchored, rep, span)
    local s, e = span[1], span[2]
    local at = anchored(s + 1)
    local okm, m = pcall(vim.fn.matchstrpos, line, at, s, 1)
    if okm and m[2] == s and m[3] == e then
        local whole = vim.fn.substitute(line, at, rep, "")
        return whole:sub(s + 1, #whole - (#line - e))
    end
    -- \zs in the pattern, or one that will not take an anchor: fall back to
    -- expanding the matched text on its own.
    return vim.fn.substitute(line:sub(s + 1, e), pat, rep, "")
end

local function replace_pattern(args)
    local pattern, replacement = args.pattern, args.replacement
    if type(pattern) ~= "string" or pattern == "" then
        err("missing required argument: pattern")
    end
    if type(replacement) ~= "string" then
        err("missing required argument: replacement (\"\" deletes the match)")
    end
    if pattern:find("\n", 1, true) then
        err("pattern matches within one line; a multi-line pattern is not supported "
            .. "(replace_symbol_body or replace_symbol_lines take a whole block)")
    end
    local kind = args.kind
    if kind ~= nil and kind ~= "code" and kind ~= "comment" and kind ~= "string" then
        err("kind must be code, comment or string")
    end
    if args.tests ~= nil and args.tests ~= "exclude" and args.tests ~= "only" then
        err("tests must be exclude or only")
    end
    local pat, rep, anchored = pattern_regex(args)
    local okr, re = pcall(vim.regex, pat)
    if not okr then
        err("the pattern does not compile: %s. It is a Vim regex in very magic mode "
            .. "(\\v), close to an extended regular expression; literal=true takes the "
            .. "text as bytes instead.", tostring(re):gsub("\n", " "))
    end
    -- One dead branch in an alternation is a silent half-edit: the reply
    -- says how many files matched, which looks like success whether all
    -- seven alternatives worked or only the two without an `=` in them.
    -- Count the branches one by one so the ones that matched nothing are
    -- named, with what very magic did to them.
    local alts = not args.literal and top_level_alternatives(pattern) or {}
    if #alts < 2 then alts = {} end
    local alt_pats, alt_hits = {}, {}
    for k, a in ipairs(alts) do
        alt_hits[k] = 0
        local oka, ra = pcall(vim.regex, "\\C\\v^%(" .. a .. ")$")
        alt_pats[k] = oka and ra or nil
    end
    local files = pattern_files(args)
    local capped = 0
    if #files > MAX_PATTERN_FILES then
        capped = #files - MAX_PATTERN_FILES
        files = vim.list_slice(files, 1, MAX_PATTERN_FILES)
    end

    local per_file, samples = {}, {}
    local total, skipped_total, unreadable, zero_width = 0, 0, {}, false
    local no_parser = {}
    local pending = {}
    for _, path in ipairs(files) do
        local okb, bufnr = pcall(load_buf, path)
        if not okb then
            unreadable[#unreadable + 1] = rel_path(path)
        elseif kind and not core.has_parser(vim.bo[bufnr].filetype) then
            -- kind= is a promise to tell a comment or a string from code,
            -- and without a parser every hit classifies as nothing: code
            -- would then replace inside comments and strings, and comment
            -- or string would replace nothing at all. Say so instead.
            no_parser[#no_parser + 1] = rel_path(path)
        else
            local old = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            local new = {}
            local hits, skipped = 0, 0
            for i, line in ipairs(old) do
                local spans, degenerate = match_spans(pat, line)
                if degenerate then zero_width = true end
                if #spans == 0 then
                    new[i] = line
                else
                    -- Every span is matched and expanded against the
                    -- original line, the way :substitute does it, so
                    -- anchors, \< and lookaround see their real context and
                    -- the count is the number of replacements made.
                    local out, from = {}, 0
                    for _, span in ipairs(spans) do
                        local want = true
                        for k = 1, #alts do
                            local ra = alt_pats[k]
                            if ra and ra:match_str(line:sub(span[1] + 1, span[2])) then
                                alt_hits[k] = alt_hits[k] + 1
                                break
                            end
                        end
                        if kind then
                            local at = index.classify_hit(bufnr, i, span[1] + 1)
                            want = kind == "code"
                                and not (at == "comment" or at == "string")
                                or kind == at
                        end
                        out[#out + 1] = line:sub(from + 1, span[1])
                        if want then
                            out[#out + 1] = expand_at(line, pat, anchored, rep, span)
                            hits = hits + 1
                        else
                            out[#out + 1] = line:sub(span[1] + 1, span[2])
                            skipped = skipped + 1
                        end
                        from = span[2]
                    end
                    out[#out + 1] = line:sub(from + 1)
                    new[i] = table.concat(out)
                end
                if new[i] ~= line and #samples < 8 then
                    samples[#samples + 1] = ("%s:%d"):format(rel_path(path), i)
                    -- No space after the marker: the space made the sample
                    -- one byte different from the line in the file, so it
                    -- could not be copied into a match= or an expect=.
                    samples[#samples + 1] = "-" .. line
                    samples[#samples + 1] = "+" .. new[i]
                end
            end
            total = total + hits
            skipped_total = skipped_total + skipped
            if hits > 0 or skipped > 0 then
                per_file[#per_file + 1] = {
                    file = path,
                    replacements = hits > 0 and hits or nil,
                    left_alone = skipped > 0 and skipped or nil,
                }
            end
            if hits > 0 then
                pending[#pending + 1] = { bufnr = bufnr, old = old, new = new }
            end
        end
    end
    if #no_parser > 0 and #no_parser == #files - #unreadable then
        err("kind=%s needs a treesitter parser to tell comments and strings from code, "
            .. "and none of the files has one (%s); install_language adds it, or call "
            .. "without kind=", kind, table.concat(no_parser, ", "))
    end

    local FILES_SHOWN = 40
    local files_note
    if #per_file > FILES_SHOWN then
        files_note = ("%d of %d files listed"):format(FILES_SHOWN, #per_file)
    end
    local result = {
        pattern = pattern,
        replacement = replacement,
        total_replacements = total,
        files_matched = #per_file,
        files_listed = files_note,
        files = #per_file > 0 and vim.list_slice(per_file, 1, FILES_SHOWN) or nil,
        samples = #samples > 0 and samples or nil,
    }
    if #alts > 0 then
        local per_alt, dead = {}, {}
        for k, a in ipairs(alts) do
            per_alt[#per_alt + 1] = { pattern = a, matches = alt_hits[k] }
            if alt_hits[k] == 0 then dead[#dead + 1] = a end
        end
        result.alternatives = per_alt
        if #dead > 0 then
            local traps = very_magic_traps(table.concat(dead, "|"))
            result.alternatives_note = ("%d of the %d alternatives matched nothing: %s."):format(
                    #dead, #alts, table.concat(dead, ", "))
                .. (#traps > 0 and (" The pattern is a very magic (\\v) regex, where "
                    .. table.concat(traps, ", ") .. ". Escape those characters, or pass "
                    .. "literal=true to take the pattern as bytes.") or "")
        end
    end
    if skipped_total > 0 then
        -- The sentence used to be written for kind=code whatever the filter
        -- was, so kind=string reported its skipped *code* matches as "inside
        -- a comment or a string literal".
        result.left_alone = kind == "code"
            and ("%d matches are inside a comment or a string literal and were not replaced "
                .. "(kind=code)"):format(skipped_total)
            or ("%d matches are not %s and were not replaced (kind=%s)")
            :format(skipped_total, kind == "comment" and "in a comment" or "in a string literal", kind)
    end
    if #unreadable > 0 then
        result.unreadable = unreadable
    end
    if #no_parser > 0 then
        result.no_parser = no_parser
        result.no_parser_note = ("kind=%s needs a treesitter parser to tell comments and strings "
            .. "from code; these files have none and were left alone"):format(kind)
    end
    if capped > 0 then
        -- Kept out of `note`, which the dry-run message overwrites: the
        -- dangerous case is a run that replaced something and left the rest
        -- of the tree unlooked-at, and that note used to disappear.
        result.not_looked_at = ("%d further files were not looked at (cap: %d); the answer above "
            .. "covers the first %d only - narrow with glob= or files= to reach the rest")
            :format(capped, MAX_PATTERN_FILES, MAX_PATTERN_FILES)
    end
    if zero_width then
        result.warning = "the pattern can match nothing at some positions (a zero-width "
            .. "match); those positions were left alone, and the count above may be short"
    end
    if total == 0 then
        -- "nothing matched" is a claim about the project; with files left
        -- unlooked-at it is a claim about a prefix of it. A 555-file glob
        -- capped at 400 answered "nothing matched" while the only matching
        -- file sat in the 155 it never opened.
        result.summary = capped > 0
            and ("no replacements in the %d files looked at, and %d further files were not "
                .. "looked at (cap: %d) - this is not \"nothing matched\"; narrow with glob= "
                .. "or files= to cover them"):format(#files, capped, MAX_PATTERN_FILES)
            or "no replacements: nothing matched"
                .. (skipped_total > 0 and ", except in comments and string literals" or "")
        if #alts == 0 and not args.literal then
            local traps = very_magic_traps(pattern)
            if #traps > 0 then
                result.hint = ("the pattern is a very magic (\\v) regex, where " .. table.concat(traps, ", ")
                    .. ". Escape those characters, or pass literal=true to take the pattern as bytes.")
            end
        end
        return result
    end
    if args.dry_run then
        result.dry_run = true
        result.note = "nothing applied; call again without dry_run to replace"
        return result
    end

    for _, p in ipairs(pending) do
        for i = 1, #p.new do
            if p.new[i] ~= p.old[i] then
                local conflict = primary_region_conflict(p.bufnr, i, i)
                if conflict then err(conflict) end
            end
        end
    end
    for _, p in ipairs(pending) do
        settle_before_edit(p.bufnr)
    end
    local before = diag_snapshot()
    -- One pattern replace is one undo step across every file it changed.
    local own_bufs = {}
    for _, p in ipairs(pending) do own_bufs[p.bufnr] = true end
    require("agent99.edits").as_one_step(function()
        for _, p in ipairs(pending) do
            vim.api.nvim_buf_set_lines(p.bufnr, 0, -1, false, p.new)
            record_edit(p.bufnr, "replace_pattern " .. pattern, "pattern",
                1, #p.old, p.old, p.new)
        end
    end)
    result.note = edit_note(args)
    return vim.tbl_extend("error", result,
        post_edit_report(pending[1].bufnr, before, args.root, args.headless, nil,
            args.full_diagnostics, { own = own_bufs }))
end

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

-- The same operation as watched-file changes, which is how a server learns
-- that its view of the project is out of date: a rename is the old path
-- gone and the new path arrived.
local WATCHED_CREATED, WATCHED_DELETED = 1, 3

local function watched_changes_for(method, files)
    local changes = {}
    local function add(uri, type)
        if uri then changes[#changes + 1] = { uri = uri, type = type } end
    end
    for _, f in ipairs(files) do
        if method == "workspace/didCreateFiles" then
            add(f.uri, WATCHED_CREATED)
        elseif method == "workspace/didDeleteFiles" then
            add(f.uri, WATCHED_DELETED)
        elseif method == "workspace/didRenameFiles" then
            add(f.oldUri, WATCHED_DELETED)
            add(f.newUri, WATCHED_CREATED)
        end
    end
    return changes
end

-- Tell every interested server that files appeared, moved or went away.
local function notify_file_operation(method, files)
    -- workspace/didCreateFiles is deliberately never sent. gopls answers "No
    -- packages found for open file" for a file it is told about that way
    -- before it has analyzed the document, and keeps answering it, so the
    -- file created here would stay unanalyzed for the rest of the session
    -- (measured: creating a Go file with the notification breaks it, without
    -- it the same file analyzes at once). The watched-files change below is
    -- what a server reloads its view of the project from anyway.
    if method ~= "workspace/didCreateFiles" then
        for _, client in ipairs(file_op_clients(method)) do
            pcall(function() client:notify(method, { files = files }) end)
        end
    end
    notify_watched_files(watched_changes_for(method, files))
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

-- What a file operation must do before forget_buf wipes the buffer for
-- `path`: get its unsaved changes to disk. Symbol edits made earlier in
-- the run live in the buffer, headless or not, and a forced wipe would
-- discard them without a word. Headless, every changed buffer is saved
-- (a willRename edit may have touched others); in a live editor only this
-- file's buffer is written, since the rest is the user's to save. A write
-- that fails refuses the operation rather than losing the edit.
local function flush_before_file_op(path, headless, what)
    if headless then
        local failures = save_all()
        if #failures > 0 then
            err("could not save before the %s: %s", what, table.concat(failures, "; "))
        end
    end
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].modified
            and vim.api.nvim_buf_get_name(bufnr) == path then
            local ok, why = write_buf(bufnr)
            if not ok then
                err("%s has unsaved changes that could not be written before the %s: %s",
                    rel_path(path), what, tostring(why))
            end
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
    local opts = post_edit_options(args)
    local _, _, done, _, info = polish_after_edit(bufnr, 1, #lines, opts)
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
        if info.diff then
            result.polish_diff = info.diff
        end
    end
    if info.format_skipped then
        result.format_skipped = info.format_skipped
    end
    if info.imports_note then
        result.imports_note = info.imports_note
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
    -- The file's own problems, loaded and settled at the old path, count as
    -- pre-existing at the new one: the report keys diagnostics by file
    -- name, and the move is not what put them there.
    local from_buf = load_buf(from)
    settle_before_edit(from_buf)
    -- The files that name this module. A server that rewrites imports on a
    -- rename rewrites theirs; one that addresses modules by a string it does
    -- not rename leaves them broken, and those are the files whose diagnostic
    -- says so.
    local cl = closure.plan({
        bufnr = from_buf, root = args.root, settle = settle_before_edit,
    })
    local before = diag_snapshot()
    local prefix = from .. "|"
    for sig, n in pairs(vim.deepcopy(before)) do
        if sig:sub(1, #prefix) == prefix then
            before[to .. sig:sub(#from + 1)] = n
        end
    end
    -- Ask first: this is where a server rewrites the imports that name the
    -- old path. It has to happen while the file is still at the old one.
    local touched = apply_will_file_operation("workspace/willRenameFiles", files)
    flush_before_file_op(from, args.headless, "move")
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
    else
        -- Silence here read as "nothing needed changing", and the reply's
        -- "no new errors or warnings" agreed with it: a Lua config whose
        -- three `require("iryzhkov.theme")` call sites now pointed at a
        -- module that no longer existed was reported clean, because a
        -- require argument is a string and no diagnostic covers it.
        result.updated_by_server = nil
        result.updated_note = "the language server rewrote nothing: either no file referred to "
            .. "the old path, or this language addresses modules by a name the server does not "
            .. "rename (a Lua require, a Python import string). Check the callers yourself - "
            .. "grep for the old module path - because no diagnostic covers it."
    end
    return vim.tbl_extend("force", result,
        post_edit_report(bufnr, before, args.root, args.headless, nil, args.full_diagnostics,
            { closure = cl }))
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
    if not vim.uv.fs_access(path, "R") then
        err("could not read %s before deleting it", rel_path(path))
    end

    local files = { { uri = file_uri(path) } }
    -- Asked while the file is still here: once it is gone there is no buffer
    -- to ask from, which is why this tool had no closure pass at all and
    -- still phrased its verdict as covering the project. A delete breaks
    -- exactly the files that used what it declared.
    local okd, doomed = pcall(load_buf, path)
    local cl
    if okd then
        settle_before_edit(doomed)
        cl = closure.plan({ bufnr = doomed, root = args.root, settle = settle_before_edit })
    end
    local before = diag_snapshot()
    local touched = apply_will_file_operation("workspace/willDeleteFiles", files)
    flush_before_file_op(path, args.headless, "delete")
    -- Read after the flush, so undo restores the file as it was last
    -- edited and not as it was last saved.
    local okr, contents = pcall(vim.fn.readfile, path, "b")
    if not okr then
        err("could not read %s before deleting it", rel_path(path))
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

    -- readfile in binary mode ends with an empty string for a file that
    -- ends in a newline, which every text file does: a 9-line file was
    -- reported as 10.
    local line_count = #contents
    if line_count > 0 and contents[line_count] == "" then
        line_count = line_count - 1
    end
    local result = {
        deleted = rel_path(path), lines = line_count, note = edit_note(args),
        restorable = "undo_edit puts it back with its contents",
    }
    if #touched > 0 then
        result.updated_by_server = touched
    end
    -- No buffer left to report against: the verdict is what the files that
    -- used this one say now.
    local report = post_edit_report(nil, before, args.root, args.headless, nil,
        args.full_diagnostics, { closure = cl })
    report.file = nil
    return vim.tbl_extend("force", result, report)
end

-- The row (0-based, as an insertion point) of a module's trailing `return`
-- statement, when its last top-level statement is one. Lua modules end that
-- way, and so do older JavaScript ones; anything appended below it is dead
-- code the parser rejects.
local function trailing_return_row(bufnr)
    local okp, parser = pcall(vim.treesitter.get_parser, bufnr)
    if not okp or not parser then return nil end
    local okt, trees = pcall(function() return parser:parse() end)
    if not okt or not trees or not trees[1] then return nil end
    local root = trees[1]:root()
    local last
    for child in root:iter_children() do
        if child:named() and child:type() ~= "comment" then
            last = child
        end
    end
    if not last or not last:type():find("return", 1, true) then
        return nil
    end
    local srow = last:range()
    return srow
end


-- Collapse the run of blank lines that meets at `row` (1-based, the first line
-- after a removal) down to `keep`, and to nothing at the top or the bottom of
-- the file. Every move left four consecutive blank lines at the removal site -
-- the two that had surrounded the symbol, brought together - which in Python
-- is source that black reformats rather than a cosmetic matter.
local function collapse_blanks(bufnr, row, keep)
    local function blank(i)
        if i < 1 or i > vim.api.nvim_buf_line_count(bufnr) then return false end
        return (vim.api.nvim_buf_get_lines(bufnr, i - 1, i, false)[1] or ""):match("^%s*$") ~= nil
    end
    local first, last = row, row - 1
    while blank(first - 1) do first = first - 1 end
    while blank(last + 1) do last = last + 1 end
    if last < first then return end
    -- A run at the very top or the very bottom of the file separates nothing.
    local want = keep
    if first == 1 or last >= vim.api.nvim_buf_line_count(bufnr) then want = 0 end
    if last - first + 1 <= want then return end
    vim.api.nvim_buf_set_lines(bufnr, first - 1 + want, last, false, {})
end

-- The files other than the two this move edits, and what breaks in them, are
-- worked out by the shared closure pass in agent99.closure - move_symbols had
-- the first version of it, one hop deep and its own.
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
            -- The whole block the declaration belongs to: its decorators
            -- or attributes as well as its doc comment, the same top
            -- insert_before_symbol uses, so a @Decorator or a Rust #[attr]
            -- is not left behind pointing at nothing.
            first = decl_block_top(from_buf, entry.first),
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
    for _, m in ipairs(moving) do
        local conflict = primary_region_conflict(from_buf, m.first, m.last)
        if conflict then err(conflict) end
    end

    local from_before = vim.api.nvim_buf_get_lines(from_buf, 0, -1, false)
    local blocks = {}
    for _, m in ipairs(moving) do
        blocks[#blocks + 1] = vim.api.nvim_buf_get_lines(from_buf, m.first - 1, m.last, false)
    end

    -- Every refusal comes before anything is written: an existing
    -- destination whose tail is the primary region of the request in
    -- progress is checked here, so a refused call leaves no half-made file.
    local exists = vim.uv.fs_stat(to_path) ~= nil
    if exists then
        local existing = load_buf(to_path)
        local tail = vim.api.nvim_buf_line_count(existing)
        local to_conflict = primary_region_conflict(existing, tail + 1, tail + 1)
        if to_conflict then err(to_conflict) end
    end

    -- A new destination needs whatever declares which module it belongs to.
    -- Only Go-style `package X` is inferred; anything else the caller supplies
    -- with header=, since guessing wrong writes a broken file.
    local created = false
    -- Recorded inside the undo step below rather than here, so the move is
    -- one step: create, source, destination.
    local created_op
    if not exists then
        local header = args.header
        if header == nil then
            -- The destination directory's own package first: copying the
            -- source's `package archive` into a `package fs` directory
            -- writes a file that cannot compile, and the errors were then
            -- reported as pre-existing. A sibling in the destination
            -- directory says what the package is called there.
            local dir = vim.fn.fnamemodify(to_path, ":h")
            for _, sibling in ipairs(vim.fn.globpath(dir, "*", true, true)) do
                if header == nil and sibling ~= to_path and sibling:sub(-3) == ".go" then
                    local okr, lines = pcall(vim.fn.readfile, sibling, "", 30)
                    for _, line in ipairs(okr and lines or {}) do
                        if line:match("^package%s+%S") then
                            header = line
                            break
                        end
                    end
                end
            end
        end
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
        -- A repository where every file opens with a licence or copyright
        -- block expects the new file to carry it too; `package gin` alone is
        -- not the header people mean by a header. The source file's own
        -- leading comment block is the best available answer, and an explicit
        -- header= still replaces it.
        if args.header == nil then
            for _, line in ipairs(from_before) do
                if line:match("^%s*//") or line:match("^%s*#") or line:match("^%s*%-%-") then
                    seed[#seed + 1] = line
                elseif line:match("^%s*$") and #seed == 0 then
                    -- a blank line before the block starts is not part of it
                else
                    break
                end
            end
            if #seed > 0 then seed[#seed + 1] = "" end
        end
        if header and header ~= "" then
            vim.list_extend(seed, vim.split(header, "\n", { plain = true }))
            seed[#seed + 1] = ""
        end
        if vim.fn.writefile(seed, to_path) ~= 0 then
            err("could not create %s", rel_path(to_path))
        end
        notify_file_operation("workspace/didCreateFiles", { { uri = file_uri(to_path) } })
        created = true
        -- Recorded before the content edits below, so undo_edit takes those
        -- back first and then removes the file this call made. Without it the
        -- undo restored the destination to its seeded header and left a
        -- two-line `package x` stub behind, which no build and no linter
        -- complains about and a repeated move/undo litters the package with.
        created_op = function()
            require("agent99.edits").record_file_op({
            file = to_path,
            kind = "create_file",
            undo = function()
                if not vim.uv.fs_stat(to_path) then
                    return "the file is already gone"
                end
                forget_buf(to_path)
                if vim.fn.delete(to_path) ~= 0 then
                    return "could not delete it"
                end
                notify_file_operation("workspace/didDeleteFiles", { { uri = file_uri(to_path) } })
                return nil
            end,
            })
        end
    end

    local to_buf = load_buf(to_path)
    local to_before = vim.api.nvim_buf_get_lines(to_buf, 0, -1, false)
    settle_before_edit(from_buf)
    -- The destination was loaded moments ago too; without its own wait the
    -- problems it already had would be charged to the move.
    settle_before_edit(to_buf)
    -- Load the files that reference the moved symbols before the snapshot is
    -- taken, so the problems they already have are in the baseline and only
    -- what this move breaks in them is reported. This is the pass every edit
    -- tool now shares; move_symbols had a one-hop version of it first, and
    -- the shared one reaches a file that breaks through one of these rather
    -- than through the moved symbol itself.
    --
    -- The closure's files are `also`, not `own`: this call did not edit them,
    -- so only a diagnostic naming one of the moved symbols is its doing.
    -- Filing them under `own` charged one move with three pre-existing
    -- warnings in a test file it had never touched.
    local cl = closure.plan({
        bufnr = from_buf, root = args.root, seeds = moving, settle = settle_before_edit,
        exclude = { [vim.fn.fnamemodify(args.from, ":p")] = true, [to_path] = true },
    })
    local own, also = { [from_buf] = true }, cl.also
    local before = diag_snapshot()

    -- Append to the destination, then delete from the source bottom upwards so
    -- the earlier line numbers stay valid as the later ones go. An empty file
    -- loads as one empty line; that line is replaced, not appended to, and a
    -- separating blank goes in only after a line that has something on it.
    local empty_dest = #to_before == 0 or (#to_before == 1 and to_before[1] == "")
    -- Python wants two blank lines between top-level definitions, not one:
    -- moving a function into black's own source produced a file black would
    -- have reformatted in CI, and pyright says nothing about it.
    local sep = blank_separator(to_buf)
    local appended = {}
    local function add_separator()
        for _ = 1, sep do appended[#appended + 1] = "" end
    end
    for _, block in ipairs(blocks) do
        if #appended > 0 or (not empty_dest and to_before[#to_before] ~= "") then
            add_separator()
        end
        vim.list_extend(appended, block)
    end
    local at = empty_dest and 0 or #to_before
    -- A module whose last statement returns it ends there: `return M` in Lua,
    -- the same shape in JavaScript. Appending after that line is unreachable
    -- at best and a syntax error at worst - moving a function into a Lua
    -- module put it below `return M` and broke the file every time. Land
    -- above the return instead.
    local tail_return = not empty_dest and trailing_return_row(to_buf) or nil
    if tail_return then
        at = tail_return
        appended = {}
        for _, block in ipairs(blocks) do
            if #appended > 0 then add_separator() end
            vim.list_extend(appended, block)
        end
        if at > 0 and (to_before[at] or "") ~= "" then
            for _ = 1, sep do table.insert(appended, 1, "") end
        end
        add_separator()
    end
    vim.api.nvim_buf_set_lines(to_buf, at, empty_dest and #to_before or at, false, appended)
    local from_sep = blank_separator(from_buf)
    for i = #moving, 1, -1 do
        vim.api.nvim_buf_set_lines(from_buf, moving[i].first - 1, moving[i].last, false, {})
        collapse_blanks(from_buf, moving[i].first, from_sep)
    end

    local opts = post_edit_options(args)
    local _, _, polished, _, info = polish_after_edit(to_buf, at + 1, #appended, opts)
    local from_organized = false
    if opts.organize_imports then
        from_organized = organize_imports(from_buf)
    end
    -- Whether an import pass actually ran, rather than whether one was asked
    -- for. lua_ls offers no organize-imports action at all, and the reply
    -- claimed the imports had been "sorted and pruned" over a diff that
    -- touched no require line in either file.
    local polished_imports = from_organized or vim.tbl_contains(polished, "organized imports")
    if args.headless then
        save_all()
    end
    -- The polish above added the imports the moved code needs and took away
    -- the ones the source no longer uses. Without waiting for the servers to
    -- catch up with that, the report below is read off the diagnostics they
    -- published mid-move: nine "undefined" errors were reported for a file
    -- that compiled, and retracted 115 ms later as late_diagnostics.
    settle_before_edit(to_buf)
    settle_before_edit(from_buf)
    for b in pairs(also) do settle_before_edit(b) end

    -- Whole-file entries for both, so undo_edit puts the split back. Both of
    -- them plus the destination's create belong to one undo step: undoing
    -- "half" a move restored the destination while the symbol stayed deleted
    -- from the source, so it existed in neither file.
    require("agent99.edits").as_one_step(function()
        if created_op then created_op() end
        record_edit(from_buf, ("moved out of %s"):format(rel_path(args.from)), "move_symbols",
            1, #from_before, from_before, vim.api.nvim_buf_get_lines(from_buf, 0, -1, false))
        record_edit(to_buf, ("moved into %s"):format(rel_path(to_path)), "move_symbols",
            1, #to_before, to_before, vim.api.nvim_buf_get_lines(to_buf, 0, -1, false))
    end)

    local names = {}
    for _, m in ipairs(moving) do names[#names + 1] = m.path end
    local result = {
        moved = names,
        from = rel_path(vim.fn.fnamemodify(args.from, ":p")),
        to = rel_path(to_path),
        created = created or nil,
        note = edit_note(args),
        -- What no diagnostic covers: a definition the extraction duplicated
        -- rather than moved, or a helper whose last caller went with the
        -- symbols, is unreferenced and unreferenced is not an error.
        when_finished = ("unreferenced_symbols on %s finds anything the move left "
            .. "behind with no callers"):format(rel_path(vim.fn.fnamemodify(args.from, ":p"))),
    }
    if #polished > 0 then
        result.polished = table.concat(polished, ", ")
        if info.diff then
            result.polish_diff = info.diff
        end
    end
    if info.format_skipped then
        result.format_skipped = info.format_skipped
    end
    if info.imports_note then
        result.imports_note = info.imports_note
    end
    -- The tool description promised that the imports of both files are
    -- reorganized, and that is a description of gopls rather than of the tool:
    -- source.organizeImports sorts and prunes, and only goimports also adds
    -- what is missing. pyright, tsserver and lua_ls implement the sorting
    -- meaning alone, so the moved code can arrive in the destination with no
    -- import for anything it uses, and a reply that reads clean over a tree
    -- that no longer runs is worse than one that says what was not done.
    result.imports = polished_imports
        and ("an import pass ran on both files: it sorts and prunes. Adding an import the "
            .. "moved code now needs is something only some servers do on that pass (gopls "
            .. "does; pyright, tsserver and lua_ls do not), so a name the moved code uses "
            .. "may be unresolved in %s, and a file that imported it from %s may still do so")
            :format(rel_path(to_path), rel_path(vim.fn.fnamemodify(args.from, ":p")))
        or ("no import pass ran on either file: this language server offers no "
            .. "organize-imports action, so nothing was added, sorted or pruned. A name the "
            .. "moved code uses is now unresolved in %s unless it was already imported there, "
            .. "and a file that imported it from %s still does")
            :format(rel_path(to_path), rel_path(vim.fn.fnamemodify(args.from, ":p")))
    -- A symbol that was file-local is not reachable from where it was called
    -- once it lives in another module, and no language server calls that an
    -- error: a Lua `local function` moved across a module boundary compiled
    -- fine, was exported by nobody, and its old call site became an undefined
    -- global. Nothing else in this reply says so.
    local locals = {}
    for i, m in ipairs(moving) do
        local first = (blocks[i] or {})[1] or ""
        if first:match("^%s*local%s") or first:match("^%s*static%s") then
            locals[#locals + 1] = m.path
        end
    end
    if #locals > 0 then
        result.still_file_local = locals
        result.still_file_local_note = ("these were declared file-local and were moved across "
            .. "a module boundary unchanged, so nothing outside %s can reach them and their "
            .. "old call sites now resolve to nothing. Export them there and import them "
            .. "where they are called, or move them back"):format(rel_path(to_path))
    end
    -- The list itself comes back under `checked`, with the rest of the
    -- closure; what is move-specific is the warning, because move_symbols
    -- reorganizes the imports of the two files it edits and of nothing else.
    -- Not "anything this move broke in them is reported below": that is a
    -- promise the verdict cannot keep when the server answers after the
    -- reply has gone out, and a move that did break one of these files came
    -- back clean. Say what was done, not what was guaranteed.
    if #cl.checked > 0 then
        result.also_checked_note = "the files under checked use what moved. Their imports were "
            .. "not rewritten - this tool reorganizes the two files it edits and no others - "
            .. "so check them before treating the move as finished"
    elseif cl.computable then
        result.also_checked_note = "the server reports no other file referencing the moved "
            .. "symbols, so only the two files above needed changing"
    else
        result.also_checked_note = ("%s, so nothing could be checked about other files that "
            .. "use the moved symbols; grep for their names before treating this move as "
            .. "finished"):format(cl.reason)
    end
    local moved_names = {}
    for _, m in ipairs(moving) do
        moved_names[#moved_names + 1] = m.path:match("[^%.:/]+$") or m.path
    end
    return vim.tbl_extend("force", result,
        post_edit_report(to_buf, before, args.root, args.headless, opts, args.full_diagnostics,
            { own = own, also = also, also_names = moved_names, closure = cl }))
end
M.post_edit_options = post_edit_options
M.organize_imports = organize_imports
-- Exported for tests/unit_edit.lua: the guard that keeps an import pass from
-- re-indenting the lines it kept.
M.reindented_kept_line = reindented_kept_line
M.polish_after_edit = polish_after_edit
M.diag_snapshot = diag_snapshot
M.settle_before_edit = settle_before_edit
M.post_edit_report = post_edit_report
M.take_carry = take_carry
M.flush_deferred = flush_deferred
-- For the diagnostics tool, which reports the same verdict from another door
-- and used to certify a server's silence without saying whose silence it was.
M.silent_server = silent_server
-- Exported for tests/unit_edit.lua: which servers have gone away since they
-- published. A count that says "0 elsewhere" is theirs, and it stops being an
-- answer the moment they stop running.
M.stopped_servers = stopped_servers
M.code_actions = code_actions
M.apply_code_action = apply_code_action
M.replace_symbol_body = replace_symbol_body
M.replace_symbol_lines = replace_symbol_lines
M.insert_symbol_tool = insert_symbol_tool
M.insert_lines = insert_lines
M.undo_edit = undo_edit
M.rename_symbol = rename_symbol
M.replace_pattern = replace_pattern
M.create_file = create_file
M.move_file = move_file
M.delete_file = delete_file
M.move_symbols = move_symbols
-- Exported for tests/unit_edit.lua: the two checks that decide whether a
-- formatter's pass is kept are worth testing on their own, because the
-- servers that fail them are not the ones the smoke test can run.
M.indent_profile = indent_profile
M.format_damage = format_damage
M.map_region = map_region
-- Exported for tests/unit_edit.lua: whether a diagnostic in a file a move only
-- loaded is the move's doing. Getting this wrong drops a real error silently.
M.mentions_name = mentions_name

return M
