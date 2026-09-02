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
        repeated = repeated + (r.repeated_calls or 0)
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
        lines[#lines + 1] = ("  %d auto-fix rounds · %d repeated calls nudged")
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

--- Open a browsable list of past requests; <CR> opens the record under the
--- cursor (the transcript path inside it holds the full conversation).
function M.browse()
    local files = record_files()
    table.sort(files, function(a, b) return a > b end)
    local lines, targets = {}, {}
    for _, path in ipairs(files) do
        local rec = read_record(path)
        if rec then
            lines[#lines + 1] = ("%s │ %-13s │ %s:%d-%d │ %s"):format(
                rec.time or "?", rec.status or "?",
                vim.fn.fnamemodify(rec.file or "?", ":t"),
                rec.first or 0, rec.last or 0,
                (rec.instruction or ""):sub(1, 70):gsub("\n", " "))
            targets[#lines] = path
        end
    end
    if #lines == 0 then
        vim.notify("agent99: no history yet")
        return
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
            vim.cmd.edit(target)
        end
    end, { buffer = buf, desc = "agent99: open record" })
    vim.keymap.set("n", "q", vim.cmd.close, { buffer = buf })
end

return M
