-- Request history: one JSON record per request (plus the agent transcript
-- alongside), pruned to config.history.keep. Aggregated by stats_lines for
-- /stats and :Agent99Stats; browsable via M.browse.

local config = require("agent99.config")

local M = {}

local function prune()
    local files = vim.fn.glob(config.history_dir() .. "/*.json", true, true)
    table.sort(files)
    for i = 1, #files - config.options.history.keep do
        vim.fn.delete(files[i])
    end
end

-- Ids of records created in this Neovim session, so stats can be scoped.
local session_ids = {}

--- Persist (or re-persist) one request record.
function M.write(record)
    session_ids[record.id] = true
    local path = config.history_dir() .. "/" .. record.id .. ".json"
    vim.fn.writefile(vim.split(vim.json.encode(record), "\n"), path)
    prune()
    return path
end

--- Fresh id + transcript path for a new request.
function M.new_id()
    local id = os.date("%Y%m%d-%H%M%S") .. "-" .. math.random(1000, 9999)
    return id, config.history_dir() .. "/" .. id .. ".transcript.json"
end

local function record_files()
    local out = {}
    for _, path in ipairs(vim.fn.glob(config.history_dir() .. "/*.json", true, true)) do
        if not path:match("%.transcript%.json$") then
            out[#out + 1] = path
        end
    end
    return out
end

local function read_record(path)
    local ok, rec = pcall(function()
        return vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
    end)
    if ok and type(rec) == "table" then
        return rec
    end
    return nil
end

--- Aggregate usage into a report: outcome rates, cost, tool usage. Scoped
--- to requests made in this Neovim session unless scope is "all". Returns
--- the report as lines (nil when nothing matches); the raw data lives in
--- the history JSON records, machine-readable.
function M.stats_lines(scope)
    local recs = {}
    for _, path in ipairs(record_files()) do
        local rec = read_record(path)
        if rec and (scope == "all" or session_ids[rec.id]) then
            recs[#recs + 1] = rec
        end
    end
    if #recs == 0 then
        return nil
    end
    local by_status, by_mode, tools = {}, {}, {}
    local n_usage, rounds, tin, tout, secs, repeated, autofixes = 0, 0, 0, 0, 0, 0, 0
    local tcached, undone = 0, 0
    local failures = {}
    for _, r in ipairs(recs) do
        if r.undone then
            undone = undone + 1
        end
        local st = r.status or (r.applied and "applied" or "unknown")
        by_status[st] = (by_status[st] or 0) + 1
        by_mode[r.mode or "edit"] = (by_mode[r.mode or "edit"] or 0) + 1
        if r.rounds then
            n_usage = n_usage + 1
            rounds = rounds + r.rounds
            tin = tin + (r.tokens_in or 0)
            tcached = tcached + (r.tokens_cached or 0)
            tout = tout + (r.tokens_out or 0)
            secs = secs + (r.secs or 0)
        end
        for name, count in pairs(r.tools or {}) do
            tools[name] = (tools[name] or 0) + count
        end
        repeated = repeated + (r.repeated_calls or 0) + (r.duplicate_results or 0)
        if r.autofix then
            autofixes = autofixes + 1
        end
        if st == "error" or st == "empty_reply" or st == "no_replacement" then
            failures[#failures + 1] = ("%s  %s  %s"):format(
                r.time or "?", st, (r.instruction or ""):sub(1, 60):gsub("\n", " "))
        end
    end
    local lines = { ("agent99 usage — %d requests (%s)"):format(#recs,
        scope == "all" and "all time" or "this session"), "" }
    local function section(title, tbl, total)
        lines[#lines + 1] = title
        local keys = vim.tbl_keys(tbl)
        table.sort(keys, function(a, b) return tbl[a] > tbl[b] end)
        for _, k in ipairs(keys) do
            lines[#lines + 1] = ("  %-18s %4d  (%d%%)"):format(k, tbl[k],
                math.floor(tbl[k] * 100 / total + 0.5))
        end
        lines[#lines + 1] = ""
    end
    section("By outcome:", by_status, #recs)
    section("By mode:", by_mode, #recs)
    if n_usage > 0 then
        lines[#lines + 1] = ("Averages over %d runs with usage data:"):format(n_usage)
        lines[#lines + 1] = ("  %.1f rounds · %.1fk tokens in / %.1fk out · %.1fs per request")
            :format(rounds / n_usage, tin / 1000 / n_usage, tout / 1000 / n_usage, secs / n_usage)
        local miss = tin - tcached
        lines[#lines + 1] = ("  totals: %.0fk in (%.0fk cache-miss / %.0fk cached ≈ 10x cheaper) / %.1fk out")
            :format(tin / 1000, miss / 1000, tcached / 1000, tout / 1000)
        lines[#lines + 1] = ("  %d auto-fix rounds · %d repeated/duplicate calls nudged")
            :format(autofixes, repeated)
        if undone > 0 then
            lines[#lines + 1] = ("  %d applied edit(s) were undone by the user within 30s")
                :format(undone)
        end
        lines[#lines + 1] = ""
    end
    if next(tools) then
        local total_calls = 0
        for _, c in pairs(tools) do
            total_calls = total_calls + c
        end
        section("Tool calls:", tools, math.max(1, total_calls))
    end
    if #failures > 0 then
        lines[#lines + 1] = "Recent failures:"
        for i = math.max(1, #failures - 5), #failures do
            lines[#lines + 1] = "  " .. failures[i]
        end
    end
    return lines
end

--- :Agent99Stats — the report in its own split (outside the panel).
--- Session-scoped by default; scope "all" covers the whole history.
function M.stats(scope)
    local lines = M.stats_lines(scope)
    if not lines then
        vim.notify(scope == "all" and "agent99: no history yet"
            or "agent99: no requests this session (try :Agent99Stats all)")
        return
    end
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.bo[buf].bufhidden = "wipe"
    vim.cmd.split()
    vim.api.nvim_win_set_buf(0, buf)
    vim.keymap.set("n", "q", vim.cmd.close, { buffer = buf })
end

--- Recent request history as plain lines (for the panel).
function M.history_lines(n)
    local files = record_files()
    table.sort(files, function(a, b) return a > b end)
    local lines = {}
    for i = 1, math.min(n or 15, #files) do
        local rec = read_record(files[i])
        if rec then
            lines[#lines + 1] = ("%s │ %-12s │ %s"):format(
                rec.time or "?", rec.status or "?",
                (rec.instruction or ""):sub(1, 60):gsub("\n", " "))
        end
    end
    if #lines == 0 then
        return nil
    end
    return lines
end

-- A change rendered as code in the file's own language: one Added or
-- Removed block when a side is empty, Before/After blocks otherwise.
local function change_lines(file, before, after, full)
    local out = {}
    local lang = (file and vim.filetype.match({ filename = file })) or ""
    local function block(title, text)
        out[#out + 1] = ""
        out[#out + 1] = "**" .. title .. "**"
        out[#out + 1] = "```" .. lang
        local body = vim.split(text, "\n", { plain = true })
        if not full and #body > 60 then
            body = vim.list_slice(body, 1, 60)
            body[#body + 1] = "... (truncated; <CR> opens the full view)"
        end
        vim.list_extend(out, body)
        out[#out + 1] = "```"
    end
    local b = vim.trim(before or "")
    local a = vim.trim(after or "")
    if b == "" and a ~= "" then
        block("Added", after)
    elseif a == "" and b ~= "" then
        block("Removed", before)
    else
        block("Before", before)
        block("After", after)
    end
    return out
end

-- What was given to the agent and what came back, rendered as read-only
-- markdown for the picker preview. `full` lifts the truncation caps and
-- adds gf-able paths to the raw record and transcript (the opened view).
local function record_preview(rec, running_secs, full)
    local lines = {}
    local function add(s)
        vim.list_extend(lines, vim.split(s, "\n", { plain = true }))
    end
    local function add_change(file, before, after)
        vim.list_extend(lines, change_lines(file, before, after, full))
    end
    if running_secs then
        add(("# RUNNING — %ds elapsed"):format(running_secs))
    else
        add(("# %s — %s"):format(rec.time or "?", rec.status or "?"))
    end
    add(("- mode: %s · provider: %s"):format(rec.mode or "edit", rec.provider or "?"))
    if rec.file and rec.file ~= "" then
        add(("- target: %s:%s-%s"):format(vim.fn.fnamemodify(rec.file, ":~:."),
            tostring(rec.first), tostring(rec.last)))
    end
    if rec.stats then
        add("- " .. rec.stats)
    end
    if full then
        add("- record: " .. config.history_dir() .. "/" .. rec.id .. ".json")
        if rec.transcript then
            add("- transcript: " .. rec.transcript)
        end
    end
    add("")
    add("## Instruction")
    add(rec.instruction or "(none)")
    if rec.edits and #rec.edits > 0 then
        add("")
        add("## Symbol edits")
        for _, e in ipairs(rec.edits) do
            add("")
            add("### " .. e.label)
            add_change(e.file, e.before, e.after)
        end
    elseif rec.edit_diffs and #rec.edit_diffs > 0 then
        -- Records from the short-lived unified-diff format.
        add("")
        add("## Symbol edits")
        for _, d in ipairs(rec.edit_diffs) do
            add("")
            add("**" .. d.label .. "**")
            add("```diff")
            local body = vim.split(d.diff, "\n", { plain = true })
            if not full and #body > 60 then
                body = vim.list_slice(body, 1, 60)
                body[#body + 1] = "... (edit truncated)"
            end
            vim.list_extend(lines, body)
            add("```")
        end
    elseif rec.symbol_edits and #rec.symbol_edits > 0 then
        add("")
        add("## Symbol edits")
        for _, e in ipairs(rec.symbol_edits) do
            add("- " .. e)
        end
    end
    if rec.result and rec.result ~= "" then
        add("")
        local body
        if rec.mode == "ask" or rec.mode == "chat" then
            add("## Answer")
            body = vim.split(rec.result, "\n", { plain = true })
        elseif rec.before then
            -- Edit with the pre-edit region on record: show the change as
            -- Before/After code in the file's own language (a single Added
            -- block when the region was empty).
            add("")
            add("## Change")
            add_change(rec.file, rec.before, rec.result)
            body = {}
        else
            add("## Replacement")
            body = vim.split(rec.result, "\n", { plain = true })
        end
        if not full and #body > 120 then
            body = vim.list_slice(body, 1, 120)
            body[#body + 1] = "... (truncated; <CR> opens the full view)"
        end
        vim.list_extend(lines, body)
    end
    if rec.error then
        add("")
        add("## Error")
        add(rec.error)
    end
    return lines
end

-- Relative age for the list ("just now", "10m ago", "2h ago", "3d ago"),
-- undotree-style; falls back to the raw timestamp when it doesn't parse.
-- The absolute time stays in the ordinal, so date searches keep working.
local function rel_time(timestr)
    local y, mo, d, h, mi, s = (timestr or ""):match(
        "(%d+)-(%d+)-(%d+) (%d+):(%d+):(%d+)")
    if not y then
        return timestr or "?"
    end
    local age = os.time() - os.time({ year = y, month = mo, day = d,
        hour = h, min = mi, sec = s })
    if age < 60 then
        return "just now"
    elseif age < 3600 then
        return ("%dm ago"):format(math.floor(age / 60))
    elseif age < 86400 then
        return ("%dh ago"):format(math.floor(age / 3600))
    elseif age < 7 * 86400 then
        return ("%dd ago"):format(math.floor(age / 86400))
    end
    return ("%s-%s-%s"):format(y, mo, d)
end

-- A record is relevant to the current workspace when its project root and
-- the cwd contain one another (being in a subdirectory of the project, or
-- the project being under the cwd, both count). Legacy records without a
-- root are matched on their target file instead.
local function in_workspace(rec)
    local cwd = vim.uv.cwd()
    local anchor = rec.root
    if not anchor and rec.file and rec.file ~= "" then
        anchor = vim.fn.fnamemodify(rec.file, ":h")
    end
    if not anchor then
        return true -- chat records with no file: no way to place them
    end
    local function under(a, b)
        return a == b or a:sub(1, #b + 1) == b .. "/"
    end
    return under(anchor, cwd) or under(cwd, anchor)
end

-- Running request first, then records newest-first. Each item carries its
-- one-line display, a searchable ordinal, the preview lines, and the
-- record path (nil while running). scope "all" lifts the workspace filter.
local function picker_items(scope)
    local items = {}
    local running, secs = require("agent99.request").current()
    if running then
        items[#items + 1] = {
            display = ("● running %3ds │ %-5s │ %s"):format(secs,
                running.mode or "edit",
                (running.instruction or ""):sub(1, 60):gsub("\n", " ")),
            ordinal = "running " .. (running.instruction or ""),
            preview = record_preview(running, secs),
            path = nil,
        }
    end
    local files = record_files()
    table.sort(files, function(a, b) return a > b end)
    for _, path in ipairs(files) do
        local rec = read_record(path)
        if rec and (scope == "all" or in_workspace(rec)) then
            -- @now / @past tokens make the fuzzy search session-aware:
            -- type "@past" for runs from earlier Neovim sessions.
            local session = session_ids[rec.id] and "@now" or "@past"
            items[#items + 1] = {
                display = ("%s%-10s │ %-12s │ %-5s │ %-14s │ %s"):format(
                    session_ids[rec.id] and "• " or "  ",
                    rel_time(rec.time), rec.status or "?", rec.mode or "edit",
                    (rec.file and rec.file ~= "")
                        and vim.fn.fnamemodify(rec.file, ":t"):sub(1, 14) or "-",
                    (rec.instruction or ""):sub(1, 60):gsub("\n", " ")),
                ordinal = table.concat({ session, rec.time or "", rec.status or "",
                    rec.mode or "", rec.file or "", rec.instruction or "" }, " "),
                preview = record_preview(rec),
                rec = rec,
                path = path,
            }
        end
    end
    return items
end

-- Markdown highlights ```diff fences through language injection, which
-- needs a diff treesitter parser (not bundled with Neovim). Without one
-- the fences render plain; fall back to line highlights so +/-/@@ still
-- read as a diff.
local diff_ns = vim.api.nvim_create_namespace("agent99_history_diff")

-- Hide the raw ``` fence delimiter lines (conceal_lines). Treesitter's
-- language injection highlights the fence CONTENT regardless; this removes
-- the markup lines themselves in surfaces render-markdown does not cover
-- (the telescope preview renders while the prompt is in insert mode).
local function conceal_fences(buf, lines)
    for i, l in ipairs(lines) do
        if l:match("^```") then
            vim.api.nvim_buf_set_extmark(buf, diff_ns, i - 1, 0,
                { conceal_lines = "" })
        end
    end
end

local function colorize_diff_fences(buf, lines)
    if pcall(vim.treesitter.language.add, "diff") then
        return -- injection will do a better job
    end
    local in_diff = false
    for i, l in ipairs(lines) do
        if l == "```diff" then
            in_diff = true
        elseif l == "```" then
            in_diff = false
        elseif in_diff then
            local hl = (l:sub(1, 1) == "+" and "DiffAdd")
                or (l:sub(1, 1) == "-" and "DiffDelete")
                or (l:sub(1, 2) == "@@" and "DiffText")
            if hl then
                vim.api.nvim_buf_set_extmark(buf, diff_ns, i - 1, 0,
                    { line_hl_group = hl })
            end
        end
    end
end

-- The record broken into named sections for the two-pane view: info,
-- instruction, one section per edit, answer/replacement, error.
local function record_sections(rec)
    local sections = {}
    -- `jump` = { file, first, last }: <CR> on the section leaves the record
    -- view and visually selects that region in the last active window.
    local function sec(name, lines, jump)
        if lines and #lines > 0 then
            sections[#sections + 1] = { name = name, lines = lines, jump = jump }
        end
    end
    local info = {
        ("# %s — %s"):format(rec.time or "?", rec.status or "?"),
        ("- mode: %s · provider: %s"):format(rec.mode or "edit", rec.provider or "?"),
    }
    if rec.file and rec.file ~= "" then
        info[#info + 1] = ("- target: %s:%s-%s"):format(
            vim.fn.fnamemodify(rec.file, ":~:."), tostring(rec.first), tostring(rec.last))
    end
    if rec.stats then
        info[#info + 1] = "- " .. rec.stats
    end
    info[#info + 1] = "- record: " .. config.history_dir() .. "/" .. (rec.id or "?") .. ".json"
    if rec.transcript then
        info[#info + 1] = "- transcript: " .. rec.transcript
    end
    sec("info", info)
    local function ctx_section(file, first, last, text)
        local lang = (file and vim.filetype.match({ filename = file })) or ""
        local body = { ("%s:%s-%s"):format(vim.fn.fnamemodify(file, ":~:."),
            tostring(first), tostring(last)), "", "```" .. lang }
        vim.list_extend(body, vim.split(text or "", "\n", { plain = true }))
        body[#body + 1] = "```"
        sec(("ctx: %s:%s-%s"):format(vim.fn.fnamemodify(file, ":t"),
            tostring(first), tostring(last)), body,
            { file = file, first = tonumber(first), last = tonumber(last) })
    end
    local instruction = rec.instruction or "(none)"
    local pending_ctx = {}
    if rec.contexts then
        sec("instruction", vim.split(instruction, "\n", { plain = true }))
        for _, c in ipairs(rec.contexts) do
            pending_ctx[#pending_ctx + 1] = c
        end
    else
        -- Older records inlined the compose contexts into the instruction;
        -- split them back apart for the section list.
        local head = instruction:match(
            "^(.-)\n\nThe user attached additional context selections:")
        sec("instruction", vim.split(head or instruction, "\n", { plain = true }))
        if head then
            for file, first, last, text in instruction:gmatch(
                '<context file="(.-)" lines=(%d+)%-(%d+)>\n(.-)\n</context>') do
                pending_ctx[#pending_ctx + 1] =
                    { file = file, first = first, last = last, text = text }
            end
        end
    end
    -- The main/target selection as its own section. For edits the change
    -- section already shows it (as Before); asks get it explicitly.
    if rec.mode == "ask" and rec.before and rec.file and rec.file ~= "" then
        local lang = vim.filetype.match({ filename = rec.file }) or ""
        local body = { ("%s:%s-%s"):format(vim.fn.fnamemodify(rec.file, ":~:."),
            tostring(rec.first), tostring(rec.last)), "", "```" .. lang }
        vim.list_extend(body, vim.split(rec.before, "\n", { plain = true }))
        body[#body + 1] = "```"
        sec(("target: %s:%s-%s"):format(vim.fn.fnamemodify(rec.file, ":t"),
            tostring(rec.first), tostring(rec.last)), body,
            { file = rec.file, first = rec.first, last = rec.last })
    end
    for _, c in ipairs(pending_ctx) do
        ctx_section(c.file, c.first, c.last, c.text)
    end
    if rec.mode ~= "ask" and rec.mode ~= "chat" and rec.before and rec.result then
        sec("change", change_lines(rec.file, rec.before, rec.result, true),
            { file = rec.file, first = rec.first, last = rec.last })
    end
    for _, e in ipairs(rec.edits or {}) do
        local jump
        if e.first then
            local n = #vim.split(e.after or "", "\n", { plain = true })
            jump = { file = e.file, first = e.first, last = e.first + math.max(n - 1, 0) }
        end
        sec(e.label or "edit", change_lines(e.file, e.before, e.after, true), jump)
    end
    for _, d in ipairs(rec.edit_diffs or {}) do
        local body = { "```diff" }
        vim.list_extend(body, vim.split(d.diff, "\n", { plain = true }))
        body[#body + 1] = "```"
        sec(d.label or "edit", body)
    end
    if rec.result and rec.result ~= "" then
        if rec.mode == "ask" or rec.mode == "chat" then
            sec("answer", vim.split(rec.result, "\n", { plain = true }))
        elseif not rec.before then
            sec("replacement", vim.split(rec.result, "\n", { plain = true }))
        end
    end
    if rec.error then
        sec("error", vim.split(rec.error, "\n", { plain = true }))
    end
    return sections
end

-- The full rendered view of one record: a telescope-style two-pane float -
-- section list on the left (j/k), the selected section rendered as
-- markdown on the right. Also serves as the answer window for finished
-- ask requests. gf on the record/transcript lines opens the raw JSON.
-- The record shown most recently (via the picker or as a fresh answer),
-- for :Agent99Record.
local last_record = nil

--- Re-open the most recently shown record.
function M.open_last()
    if last_record then
        M.open_record(last_record)
    else
        vim.notify("agent99: no record shown yet (open one from :Agent99History)")
    end
end

function M.open_record(rec)
    last_record = rec
    local origin_win = vim.api.nvim_get_current_win()
    local sections = record_sections(rec)
    local rc = (config.options.ui or {}).record or {}
    -- Near-full height, and a content pane wide enough that code up to
    -- content_width columns renders without wrapping.
    local lw = rc.list_width or 26
    local cw = math.min(rc.content_width or 120, vim.o.columns - lw - 8)
    local W = lw + cw + 2
    local H = vim.o.lines - 5
    local row = 1
    local col = math.floor((vim.o.columns - W) / 2)

    local list_buf = vim.api.nvim_create_buf(false, true)
    local names = {}
    for i, s in ipairs(sections) do
        names[i] = s.name:sub(1, lw - 2)
    end
    vim.api.nvim_buf_set_lines(list_buf, 0, -1, false, names)
    vim.bo[list_buf].modifiable = false
    vim.bo[list_buf].bufhidden = "wipe"

    local content_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[content_buf].bufhidden = "wipe"
    vim.bo[content_buf].filetype = "markdown"
    pcall(vim.treesitter.start, content_buf, "markdown")
    pcall(vim.api.nvim_buf_set_name, content_buf,
        "agent99://record/" .. (rec.id or "?"))

    local list_win = vim.api.nvim_open_win(list_buf, true, {
        relative = "editor", row = row, col = col, width = lw, height = H,
        style = "minimal", border = rc.border or "rounded",
        title = (" %s — %s "):format(rec.mode or "record", rec.status or "?"),
        title_pos = "center",
        footer = " j/k · <CR> jump to file · C-h/C-l records · q ", footer_pos = "center",
    })
    vim.wo[list_win].cursorline = true
    -- Open on the payload - answer, change, or the first edit - not info.
    local default = 1
    for i, s in ipairs(sections) do
        if s.name == "answer" or s.name == "change" or s.name == "replacement" then
            default = i
            break
        end
    end
    if default == 1 then
        for i, s in ipairs(sections) do
            if s.name ~= "info" and s.name ~= "instruction"
                and not s.name:match("^ctx:") then
                default = i
                break
            end
        end
    end
    pcall(vim.api.nvim_win_set_cursor, list_win, { default, 0 })

    local content_win = vim.api.nvim_open_win(content_buf, false, {
        relative = "editor", row = row, col = col + lw + 2,
        width = cw, height = H,
        style = "minimal", border = rc.border or "rounded",
        title = " " .. (sections[1] and sections[1].name or "record") .. " ",
        title_pos = "center",
        footer = " <CR> jump to file · <Tab> panes · gf opens path ", footer_pos = "center",
    })
    vim.wo[content_win].conceallevel = 2
    vim.wo[content_win].concealcursor = "nc"
    vim.wo[content_win].wrap = true
    vim.wo[content_win].linebreak = true

    local function show_section()
        if not vim.api.nvim_win_is_valid(list_win) then
            return
        end
        local s = sections[vim.api.nvim_win_get_cursor(list_win)[1]]
        if not (s and vim.api.nvim_buf_is_valid(content_buf)) then
            return
        end
        vim.bo[content_buf].modifiable = true
        vim.api.nvim_buf_set_lines(content_buf, 0, -1, false, s.lines)
        vim.bo[content_buf].modifiable = false
        vim.api.nvim_buf_clear_namespace(content_buf, diff_ns, 0, -1)
        colorize_diff_fences(content_buf, s.lines)
        -- Always conceal the fence delimiters here: render-markdown only
        -- re-renders the CURRENT buffer on text changes, and section
        -- switches rewrite this pane while focus sits in the list.
        conceal_fences(content_buf, s.lines)
        if vim.api.nvim_win_is_valid(content_win) then
            vim.api.nvim_win_set_config(content_win,
                { title = " " .. s.name .. " ", title_pos = "center" })
            pcall(vim.api.nvim_win_set_cursor, content_win, { 1, 0 })
        end
    end

    local closing = false
    local function close()
        if closing then
            return
        end
        closing = true
        for _, w in ipairs({ list_win, content_win }) do
            if vim.api.nvim_win_is_valid(w) then
                pcall(vim.api.nvim_win_close, w, true)
            end
        end
    end

    -- <CR> on a section with a file location: leave the record view and
    -- visually select that region in the last active window.
    local function jump_to_section()
        local s = vim.api.nvim_win_is_valid(list_win)
            and sections[vim.api.nvim_win_get_cursor(list_win)[1]]
        local j = s and s.jump
        if not j then
            vim.notify("agent99: this section has no file location")
            return
        end
        close()
        local win = origin_win
        if not (win and vim.api.nvim_win_is_valid(win)
                and vim.api.nvim_win_get_config(win).relative == "") then
            win = nil
            for _, w in ipairs(vim.api.nvim_list_wins()) do
                if vim.api.nvim_win_get_config(w).relative == "" then
                    win = w
                    break
                end
            end
        end
        if not win then
            return
        end
        vim.api.nvim_set_current_win(win)
        local ok = pcall(vim.cmd.edit, vim.fn.fnameescape(j.file))
        if not ok then
            vim.notify("agent99: cannot open " .. j.file, vim.log.levels.ERROR)
            return
        end
        local total = vim.api.nvim_buf_line_count(0)
        local first = math.min(math.max(j.first or 1, 1), total)
        local last = math.min(j.last or first, total)
        vim.cmd(("normal! %dGV%dG"):format(first, last))
    end

    -- Chronological neighbors: <C-h> older, <C-l> newer, same view. Walks
    -- workspace-relevant records (the picker's scope); when the current
    -- record itself is outside the workspace - opened from the "all" view -
    -- it walks everything instead.
    local function nav(delta)
        local files = record_files()
        table.sort(files)
        local function build(scoped)
            local out = {}
            for _, path in ipairs(files) do
                local r = read_record(path)
                if r and (not scoped or in_workspace(r)) then
                    out[#out + 1] = { path = path, rec = r }
                end
            end
            return out
        end
        local function find(list)
            for i, e in ipairs(list) do
                if rec.id and e.path:find(rec.id, 1, true) then
                    return i
                end
            end
        end
        local list = build(true)
        local idx = find(list)
        if not idx then
            list = build(false)
            idx = find(list)
        end
        local target = idx and list[idx + delta]
        if not target then
            vim.notify("agent99: no " .. (delta < 0 and "older" or "newer")
                .. " record in this workspace")
            return
        end
        close()
        vim.schedule(function()
            M.open_record(target.rec)
        end)
    end

    for _, b in ipairs({ list_buf, content_buf }) do
        vim.keymap.set("n", "q", close, { buffer = b })
        vim.keymap.set("n", "<Esc>", close, { buffer = b })
        vim.keymap.set("n", "<CR>", jump_to_section,
            { buffer = b, desc = "agent99: go to section's file region" })
        vim.keymap.set("n", "<C-h>", function() nav(-1) end,
            { buffer = b, desc = "agent99: older record" })
        vim.keymap.set("n", "<C-l>", function() nav(1) end,
            { buffer = b, desc = "agent99: newer record" })
    end
    vim.keymap.set("n", "gf", jump_to_section,
        { buffer = list_buf, desc = "agent99: go to section's file region" })
    vim.keymap.set("n", "<Tab>", function()
        vim.api.nvim_set_current_win(content_win)
    end, { buffer = list_buf, desc = "agent99: to content" })
    vim.keymap.set("n", "<Tab>", function()
        if vim.api.nvim_win_is_valid(list_win) then
            vim.api.nvim_set_current_win(list_win)
        end
    end, { buffer = content_buf, desc = "agent99: to sections" })
    vim.api.nvim_create_autocmd("CursorMoved", {
        buffer = list_buf,
        callback = show_section,
    })
    for _, w in ipairs({ list_win, content_win }) do
        vim.api.nvim_create_autocmd("WinClosed", {
            pattern = tostring(w),
            once = true,
            callback = function()
                vim.schedule(close)
            end,
        })
    end
    show_section()
end

local function telescope_browse(items, scope)
    local pickers = require("telescope.pickers")
    local finders = require("telescope.finders")
    local conf = require("telescope.config").values
    local previewers = require("telescope.previewers")
    local actions = require("telescope.actions")
    local action_state = require("telescope.actions.state")
    pickers.new({}, {
        prompt_title = scope == "all" and "agent99 requests (all)"
            or "agent99 requests (workspace)",
        finder = finders.new_table({
            results = items,
            entry_maker = function(it)
                return { value = it, display = it.display, ordinal = it.ordinal }
            end,
        }),
        sorter = conf.generic_sorter({}),
        previewer = previewers.new_buffer_previewer({
            title = "request",
            define_preview = function(self, entry)
                vim.bo[self.state.bufnr].modifiable = true
                vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false,
                    entry.value.preview)
                vim.bo[self.state.bufnr].modifiable = false
                -- Render like the chat panel: treesitter markdown (with
                -- language injection for the diff fences) plus conceal in
                -- the preview window - a bare filetype gives raw markup.
                vim.bo[self.state.bufnr].filetype = "markdown"
                pcall(vim.treesitter.start, self.state.bufnr, "markdown")
                vim.api.nvim_buf_clear_namespace(self.state.bufnr, diff_ns, 0, -1)
                colorize_diff_fences(self.state.bufnr, entry.value.preview)
                conceal_fences(self.state.bufnr, entry.value.preview)
                if self.state.winid and vim.api.nvim_win_is_valid(self.state.winid) then
                    vim.wo[self.state.winid].conceallevel = 2
                    vim.wo[self.state.winid].concealcursor = "nc"
                    vim.wo[self.state.winid].wrap = true
                    vim.wo[self.state.winid].linebreak = true
                end
            end,
        }),
        attach_mappings = function(prompt_bufnr)
            actions.select_default:replace(function()
                local entry = action_state.get_selected_entry()
                actions.close(prompt_bufnr)
                if not entry then
                    return
                end
                if entry.value.rec then
                    M.open_record(entry.value.rec)
                else
                    vim.notify("agent99: request is still running (/cancel or <leader>9x to stop)")
                end
            end)
            return true
        end,
    }):find()
end

-- Plain-split fallback when telescope is not installed.
local function split_browse(items)
    local lines, targets = {}, {}
    for i, it in ipairs(items) do
        lines[i] = it.display
        targets[i] = it.rec
    end
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.bo[buf].bufhidden = "wipe"
    vim.api.nvim_buf_set_name(buf, "agent99://history")
    vim.cmd.split()
    vim.api.nvim_win_set_buf(0, buf)
    vim.keymap.set("n", "<CR>", function()
        local target = targets[vim.api.nvim_win_get_cursor(0)[1]]
        if target then
            M.open_record(target)
        end
    end, { buffer = buf, desc = "agent99: open record" })
    vim.keymap.set("n", "q", vim.cmd.close, { buffer = buf })
end

-- Exposed for tests.
M._picker_items = picker_items

--- Browse requests: the running one (live, previewed with what it was
--- given) plus past records, newest first. Uses telescope when installed
--- (fuzzy search over time/status/mode/file/instruction, read-only
--- markdown preview, <CR> opens the record); plain split otherwise.
--- Browse requests. Scoped to the current workspace (project roots that
--- contain or are contained by the cwd) unless scope is "all".
function M.browse(scope)
    local items = picker_items(scope)
    if #items == 0 then
        vim.notify(scope == "all" and "agent99: no history yet"
            or "agent99: no requests for this workspace (:Agent99History all)")
        return
    end
    if pcall(require, "telescope") then
        telescope_browse(items, scope)
    else
        split_browse(items)
    end
end

return M
