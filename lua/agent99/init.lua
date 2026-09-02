-- agent99: agentic code edits in Neovim, 99-style.
--
-- Select a region, give an instruction, and an LLM agent rewrites the
-- selection. The agent gets tools backed by this Neovim instance's own LSP
-- clients (see bridge/ and lua/agent99/lsp.lua), so it can chase definitions,
-- references, types, and diagnostics through the same warm language servers
-- the editor is already running.

local M = {}

local ns = vim.api.nvim_create_namespace("agent99")

M.config = {
    -- Which backend runs the agent loop.
    --   kind = "openai": bridge/agent99_agent.py drives any OpenAI-compatible
    --     chat-completions API (DeepSeek by default) with the LSP tools wired
    --     in directly. Fields: base_url, model, api_key_env, max_rounds.
    --   kind = "claude": spawns `claude -p` with the LSP tools attached as an
    --     MCP server. Fields: claude_cmd, model (nil = CLI default),
    --     allowed_tools. Note: uses your Claude subscription/API quota, and
    --     does not support follow-ups (no transcript comes back).
    provider = {
        kind = "openai",
        base_url = "https://api.deepseek.com/v1",
        model = "deepseek-chat",
        api_key_env = "DEEPSEEK_API_KEY",
        -- When the environment variable is not set, the key is read from the
        -- system keyring: `secret-tool lookup service <keyring_service>`.
        -- Store it from inside Neovim with :Agent99SetKey.
        keyring_service = "deepseek",
        -- Advertise the full tool roster (type_definition, implementation,
        -- call hierarchy, document_symbols, expand_symbol) instead of the
        -- slim default. Costs ~2k extra prompt tokens per round.
        full_tools = false,
        max_rounds = 30,
        claude_cmd = "claude",
        allowed_tools = { "mcp__lsp", "Read", "Grep", "Glob" },
    },
    -- Show the proposed replacement in a preview split (<CR> apply, q discard)
    -- instead of editing the buffer directly.
    preview = true,
    -- After applying, wait auto_fix_delay_ms for the LSP to re-publish and,
    -- if the edit introduced new ERROR diagnostics, automatically ask the
    -- agent (with its full conversation) to fix them. One round, no loops.
    auto_fix = true,
    auto_fix_delay_ms = 2000,
    -- File context embedded in the initial prompt: the whole file when it has
    -- at most context_full_file_max lines, otherwise context_lines around the
    -- selection. Saves the agent its usual first buffer_lines round-trip.
    context_full_file_max = 200,
    context_lines = 50,
    -- How many request records to keep in the history directory.
    history_keep = 100,
    timeout_ms = 5 * 60 * 1000,
    keymaps = true,
    -- Path to the compiled bridge binary; nil means <plugin>/bin/agent99-bridge
    -- (built with `make build`, requires Go).
    bridge_bin = nil,
}

-- One in-flight request at a time keeps cancellation and marks simple.
local state = {
    job = nil,
    buf = nil,
    mark_start = nil,
    mark_end = nil,
    started_at = nil,
    record = nil,     -- history record of the running request
    preview = nil,    -- { pbuf, lines } while a preview awaits a decision
    last = nil,       -- { buf, mark_start, mark_end, record } after an apply
    last_edits = nil, -- symbol-tool edits of the last run, for :Agent99Revert
    stderr_acc = nil, -- accumulated stderr when streaming (chat mode)
    stdout_acc = nil, -- accumulated stdout when streaming (chat mode)
}

-- The panel conversation. Persists for the whole Neovim session; only
-- chat_reset (gn in the panel, :Agent99Clear) starts over.
local chat = {
    messages = nil,   -- full transcript (system + turns + tool calls)
    turns = 0,
}

local function state_dir()
    local dir = vim.fn.stdpath("state") .. "/agent99"
    vim.fn.mkdir(dir .. "/history", "p")
    return dir
end

local function log_path()
    return state_dir() .. "/agent99.log"
end

local function log(lines)
    local f = io.open(log_path(), "a")
    if not f then return end
    f:write(("\n=== %s ===\n"):format(os.date("%Y-%m-%d %H:%M:%S")))
    f:write(type(lines) == "table" and table.concat(lines, "\n") or tostring(lines))
    f:write("\n")
    f:close()
end

local function plugin_root()
    local src = debug.getinfo(1, "S").source:sub(2)
    return vim.fn.fnamemodify(src, ":h:h:h")
end

local function bridge_bin()
    return M.config.bridge_bin or (plugin_root() .. "/bin/agent99-bridge")
end

local function check_bridge()
    local bin = bridge_bin()
    if vim.fn.executable(bin) == 1 then
        return bin
    end
    vim.notify(("agent99: bridge binary not found at %s. Run `make build` in %s "
        .. "(requires Go)."):format(bin, plugin_root()), vim.log.levels.ERROR)
    return nil
end

local function server_socket()
    local sock = vim.v.servername
    if sock == nil or sock == "" then
        sock = vim.fn.serverstart()
    end
    return sock
end

-- Write the MCP config claude is pointed at. Regenerated per request so the
-- socket path is always the current instance's.
local function write_mcp_config()
    local dir = vim.fn.stdpath("cache") .. "/agent99"
    vim.fn.mkdir(dir, "p")
    local path = dir .. "/mcp.json"
    local cfg = {
        mcpServers = {
            lsp = {
                command = bridge_bin(),
                args = { "mcp" },
                env = { AGENT99_NVIM = server_socket() },
            },
        },
    }
    vim.fn.writefile({ vim.json.encode(cfg) }, path)
    return path
end

local function project_root(file)
    return vim.fs.root(file, { ".git" }) or vim.fn.fnamemodify(file, ":h")
end

-- ---------------------------------------------------------------- api key --

-- Resolve the API key: environment first, then the system keyring.
local function resolve_api_key()
    local provider = M.config.provider
    local key = vim.env[provider.api_key_env]
    if key and key ~= "" then
        return key
    end
    if provider.keyring_service and vim.fn.executable("secret-tool") == 1 then
        local out = vim.fn.system({ "secret-tool", "lookup", "service", provider.keyring_service })
        if vim.v.shell_error == 0 and out ~= "" then
            return (out:gsub("%s+$", ""))
        end
    end
    return nil
end

--- Prompt for the API key and store it in the system keyring, so requests
--- work without exporting the environment variable.
function M.set_key()
    local provider = M.config.provider
    if not provider.keyring_service then
        vim.notify("agent99: provider.keyring_service is not configured", vim.log.levels.ERROR)
        return
    end
    if vim.fn.executable("secret-tool") ~= 1 then
        vim.notify("agent99: secret-tool not found (install libsecret)", vim.log.levels.ERROR)
        return
    end
    local key = vim.fn.inputsecret(("API key for %s: "):format(provider.base_url))
    if key == nil or key == "" then
        return
    end
    local res = vim.system({
        "secret-tool", "store", "--label", "agent99 " .. provider.keyring_service,
        "service", provider.keyring_service,
    }, { stdin = key }):wait()
    if res.code == 0 then
        vim.notify(("agent99: key stored in keyring (service=%s)"):format(provider.keyring_service))
    else
        vim.notify("agent99: storing the key failed: " .. (res.stderr or ""), vim.log.levels.ERROR)
    end
end

-- ---------------------------------------------------------------- history --

local function history_dir()
    return state_dir() .. "/history"
end

local function prune_history()
    local files = vim.fn.glob(history_dir() .. "/*.json", true, true)
    table.sort(files)
    for i = 1, #files - M.config.history_keep do
        vim.fn.delete(files[i])
    end
end

-- Ids of records created in this Neovim session, so stats can be scoped.
local session_ids = {}

local function write_record(record)
    session_ids[record.id] = true
    local path = history_dir() .. "/" .. record.id .. ".json"
    vim.fn.writefile(vim.split(vim.json.encode(record), "\n"), path)
    prune_history()
    return path
end

local function record_files()
    local out = {}
    for _, path in ipairs(vim.fn.glob(history_dir() .. "/*.json", true, true)) do
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

--- Open a browsable list of past requests; <CR> opens the record under the
--- cursor (the transcript path inside it holds the full conversation).
function M.history()
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
--- Session-scoped by default; :Agent99Stats all covers the whole history.
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

-- ---------------------------------------------------------------- prompts --

local TOOL_GUIDE = {
    "You have %s tools backed by the user's live editor.",
    "Explore cheaply: skim (structure of many files in one call - use before",
    "reading whole files), find_symbol (fetch exactly one function/class by",
    "name with include_body=true - prefer this over reading files), ts_query",
    "(structural multi-file search), plus grep (hits are annotated with their",
    "enclosing [Symbol/Path]) and file reading. Semantic questions: references",
    "(each hit shows its enclosing symbol), hover, definition,",
    "workspace_symbols, diagnostics. buffer_lines shows a file's unsaved",
    "editor state; prefer it over disk reads for files the user has open.",
    "Rounds are the main cost: batch independent tool calls in a single turn,",
    "and prefer one broad call (grep with context, skim of several files)",
    "over a chain of narrow ones.",
    "Editing: the user's selection is your main context and the PRIMARY edit",
    "target - change it via the <replacement> reply. For changes that belong",
    "elsewhere (helpers, imports, other symbols or files), use",
    "replace_symbol_body / replace_symbol_lines (a slice of a symbol by",
    "symbol-relative line numbers - cheapest for small changes in big",
    "functions) / insert_after_symbol / insert_before_symbol, which address",
    "code by symbol name, apply immediately to editor buffers, and return",
    "fresh diagnostics so you see breakage at once.",
    "When a diagnostic lists quick_fixes, apply the language server's own fix",
    "via code_actions + apply_code_action instead of writing it yourself.",
    "Never use the symbol edit tools on the selected region itself: the",
    "selection is changed only through your <replacement> reply.",
    "code_actions/apply_code_action apply the editor's own quick fixes.",
}

local function replacement_contract(first, last)
    return {
        ("In your final reply, provide the replacement text for lines %d-%d"):format(first, last),
        "wrapped in <replacement></replacement> tags: raw code exactly as it",
        "should appear in the file - no markdown fences, no line numbers. Match",
        "the file's existing indentation style. Everything between the tags",
        "replaces those lines verbatim; everything outside the tags is discarded.",
        "Exception: if you made every needed change with the symbol edit tools",
        "and the selected lines themselves must stay as they are, reply instead",
        "with <summary>one short paragraph of what you changed and where</summary>.",
    }
end

-- Line-numbered snapshot of the file around the selection, embedded in the
-- prompt so the agent doesn't have to spend its first round on buffer_lines.
local function build_context(buf, first, last)
    local total = vim.api.nvim_buf_line_count(buf)
    local cfirst, clast
    if total <= M.config.context_full_file_max then
        cfirst, clast = 1, total
    else
        cfirst = math.max(1, first - M.config.context_lines)
        clast = math.min(total, last + M.config.context_lines)
    end
    local lines = vim.api.nvim_buf_get_lines(buf, cfirst - 1, clast, false)
    local numbered = {}
    for i, l in ipairs(lines) do
        numbered[i] = ("%d: %s"):format(cfirst + i - 1, l)
    end
    local label
    if cfirst == 1 and clast == total then
        label = ("Full content of the target file (%d lines, numbered) at request time:")
            :format(total)
    else
        label = ("Lines %d-%d of the target file (of %d total, numbered) at request time:")
            :format(cfirst, clast, total)
    end
    return table.concat({
        label,
        "<file_context>",
        table.concat(numbered, "\n"),
        "</file_context>",
        "This is a snapshot; buffer_lines gives the live state if you need to re-check.",
    }, "\n")
end

local function build_prompt(buf, file, ft, root, first, last, selection, instruction, tool_prefix)
    local parts = {
        "You are performing a surgical code edit inside the user's Neovim session.",
        ("Target file: %s (filetype: %s)"):format(file, ft),
        ("Project root: %s"):format(root),
        ("The user selected lines %d-%d of the target file:"):format(first, last),
        "<selection>",
        selection,
        "</selection>",
        "The user's instruction for this selection:",
        "<instruction>",
        instruction,
        "</instruction>",
        "",
        build_context(buf, first, last),
        "",
        table.concat(TOOL_GUIDE, "\n"):format(tool_prefix),
        "",
    }
    vim.list_extend(parts, replacement_contract(first, last))
    return table.concat(parts, "\n")
end

local function build_ask_prompt(buf, file, ft, root, first, last, selection, question, tool_prefix)
    local parts = {
        "You are answering a question about code inside the user's Neovim session.",
        ("Target file: %s (filetype: %s)"):format(file, ft),
        ("Project root: %s"):format(root),
        ("The user selected lines %d-%d of the target file:"):format(first, last),
        "<selection>",
        selection,
        "</selection>",
        "The user's question about this code:",
        "<question>",
        question,
        "</question>",
        "",
        build_context(buf, first, last),
        "",
        table.concat(TOOL_GUIDE, "\n"):format(tool_prefix),
        "",
        "Answer the question directly and concisely, in markdown. Ground your",
        "answer in code you actually inspected and cite locations as file:line.",
        "Do NOT output <replacement> tags and do not edit anything - this is a",
        "question, not an edit request. The user may follow up afterwards to",
        "turn the discussion into an edit.",
    }
    return table.concat(parts, "\n")
end

local function build_followup_prompt(file, first, last, region, instruction)
    local parts = {
        "Follow-up on the work above. The relevant region of " .. file,
        ("is now lines %d-%d and currently reads:"):format(first, last),
        "<current>",
        region,
        "</current>",
        "The user's follow-up instruction:",
        "<instruction>",
        instruction,
        "</instruction>",
        "",
    }
    vim.list_extend(parts, replacement_contract(first, last))
    return table.concat(parts, "\n")
end

-- ---------------------------------------------------------------- request --

-- Remove only this request's own marks: the namespace also holds the
-- follow-up marks around the last applied region, which must survive.
local function clear_request(kill)
    if kill and state.job then
        state.job:kill(15)
    end
    state.job = nil
    if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
        for _, id in ipairs({ state.mark_start, state.mark_end }) do
            if id then
                pcall(vim.api.nvim_buf_del_extmark, state.buf, ns, id)
            end
        end
    end
    state.buf, state.mark_start, state.mark_end = nil, nil, nil
    state.record, state.started_at = nil, nil
end

-- Extract the replacement text from a reply, or nil when the reply does not
-- contain one. Never fall back to the raw reply: a model that lost the
-- format contract produces prose, and applying prose into a buffer is worse
-- than refusing.
local function extract_replacement(out)
    out = out:gsub("\r\n", "\n")
    -- Preferred: the <replacement> contract from the prompt.
    local tagged = out:match("<replacement>\n?(.-)\n?</replacement>")
    if tagged then
        return (tagged:gsub("\n+$", ""))
    end
    -- Tolerate a fully fenced reply despite instructions to the contrary.
    local whole = out:match("^%s*```[%w_%-]*\n(.*)\n```%s*$")
    if whole then
        return (whole:gsub("\n+$", ""))
    end
    -- Commentary with code fences: salvage the last fenced block.
    local last
    for block in out:gmatch("```[%w_%-]*\n(.-)\n```") do
        last = block
    end
    if last then
        return (last:gsub("\n+$", ""))
    end
    return nil
end

-- Exposed for tests.
M._extract_replacement = extract_replacement

local function region_from_marks(buf, mark_start, mark_end)
    local spos = vim.api.nvim_buf_get_extmark_by_id(buf, ns, mark_start, {})
    local epos = vim.api.nvim_buf_get_extmark_by_id(buf, ns, mark_end, {})
    if not (spos[1] and epos[1]) then
        return nil
    end
    return spos[1], epos[1]
end

local function del_mark(buf, id)
    if buf and id and vim.api.nvim_buf_is_valid(buf) then
        pcall(vim.api.nvim_buf_del_extmark, buf, ns, id)
    end
end

-- Multiset of ERROR diagnostics by severity+message, line-independent so the
-- edit shifting lines doesn't count as "new".
local function error_multiset(buf)
    local counts = {}
    for _, d in ipairs(vim.diagnostic.get(buf, { severity = vim.diagnostic.severity.ERROR })) do
        local sig = d.severity .. "|" .. d.message
        counts[sig] = (counts[sig] or 0) + 1
    end
    return counts
end

-- After an apply, wait for the LSP to re-publish, then fire one automatic
-- follow-up round if the edit introduced errors that were not there before.
local function schedule_auto_fix(buf, pre_errors, record)
    if not M.config.auto_fix or record.autofix
        or M.config.provider.kind ~= "openai" or not record.transcript then
        return
    end
    vim.defer_fn(function()
        if state.job or state.preview or not vim.api.nvim_buf_is_valid(buf) then
            return
        end
        if not (state.last and state.last.record and state.last.record.id == record.id) then
            return -- another edit superseded this one
        end
        local new_errors, seen = {}, {}
        for _, d in ipairs(vim.diagnostic.get(buf, { severity = vim.diagnostic.severity.ERROR })) do
            local sig = d.severity .. "|" .. d.message
            seen[sig] = (seen[sig] or 0) + 1
            if seen[sig] > (pre_errors[sig] or 0) then
                new_errors[#new_errors + 1] = ("line %d: %s"):format(d.lnum + 1, d.message)
            end
        end
        if #new_errors == 0 then
            return
        end
        log({ "auto-fix triggered for " .. record.id, unpack(new_errors) })
        vim.notify(("agent99: the edit introduced %d new error(s); asking the agent to fix them")
            :format(#new_errors), vim.log.levels.WARN)
        M.followup(
            "Your previous replacement introduced new LSP error diagnostics:\n"
            .. table.concat(new_errors, "\n")
            .. "\nFix them in the replacement region. Check the diagnostics tool first: "
            .. "when a diagnostic offers quick_fixes, apply the server's own fix via "
            .. "code_actions + apply_code_action instead of rewriting the code.",
            { autofix = true })
    end, M.config.auto_fix_delay_ms)
end

local function apply_lines(buf, lines, record)
    local srow, erow = region_from_marks(buf, state.mark_start, state.mark_end)
    if not srow then
        vim.notify("agent99: selection marks lost, edit not applied (see :Agent99Logs)",
            vim.log.levels.ERROR)
        return
    end
    -- Refuse to overwrite a region the user changed after the request started.
    local current = table.concat(
        vim.api.nvim_buf_get_lines(buf, srow, erow + 1, false), "\n")
    if record.region_hash and vim.fn.sha256(current) ~= record.region_hash then
        record.applied = false
        if record.symbol_edits then
            -- The agent already rewrote this region through the symbol edit
            -- tools; the extra replacement reply is redundant, not a conflict.
            record.status = "tool_edits"
            write_record(record)
            vim.notify(("agent99: %d symbol edit(s) applied; the duplicate replacement "
                .. "reply was skipped (:Agent99Revert to undo)"):format(#record.symbol_edits))
            return
        end
        record.status = "stale_refused"
        write_record(record)
        vim.notify("agent99: the selection changed while the agent worked; edit NOT applied "
            .. "(proposal kept in :Agent99History)", vim.log.levels.ERROR)
        return
    end
    local pre_errors = error_multiset(buf)
    vim.api.nvim_buf_set_lines(buf, srow, erow + 1, false, lines)
    -- Retire this request's marks and any previous follow-up marks by id.
    -- Never nvim_buf_clear_namespace here: cleared ids get reused by the
    -- next set_extmark, so a later delete-by-id would kill the wrong mark.
    del_mark(buf, state.mark_start)
    del_mark(buf, state.mark_end)
    state.mark_start, state.mark_end = nil, nil
    if state.last then
        del_mark(state.last.buf, state.last.mark_start)
        del_mark(state.last.buf, state.last.mark_end)
    end
    -- Remember the applied region (as fresh marks) so a follow-up can target
    -- it even after unrelated edits elsewhere in the buffer.
    state.last = {
        buf = buf,
        mark_start = vim.api.nvim_buf_set_extmark(buf, ns, srow, 0, {}),
        mark_end = vim.api.nvim_buf_set_extmark(buf, ns, srow + math.max(#lines - 1, 0), 0, {}),
        record = record,
    }
    record.applied = true
    record.status = "applied"
    write_record(record)
    vim.notify(("agent99: replaced %s:%d-%d with %d lines (<leader>9f to follow up)")
        :format(vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":t"),
            srow + 1, erow + 1, #lines))
    schedule_auto_fix(buf, pre_errors, record)
    -- Undo detection: if half a minute later the region matches its pre-edit
    -- content again, the user reverted the edit - the strongest "bad edit"
    -- signal there is. Recorded for :Agent99Stats.
    local pre_hash = record.region_hash
    local this_last = state.last
    if pre_hash and this_last then
        vim.defer_fn(function()
            if not (vim.api.nvim_buf_is_valid(buf) and state.last == this_last) then
                return
            end
            local usrow, uerow = region_from_marks(buf, this_last.mark_start, this_last.mark_end)
            if not usrow then
                return
            end
            local now_text = table.concat(
                vim.api.nvim_buf_get_lines(buf, usrow, uerow + 1, false), "\n")
            if vim.fn.sha256(now_text) == pre_hash then
                record.undone = true
                write_record(record)
                log("undo detected for " .. record.id)
            end
        end, 30000)
    end
end

-- ---------------------------------------------------------------- preview --

-- Detach the preview from state first, then delete its buffer: the
-- BufWipeout autocmd only acts when the wipe arrives from outside (e.g. the
-- user :bd-ing the preview window), which it detects by state.preview still
-- being set.
local function close_preview()
    local p = state.preview
    state.preview = nil
    if p and vim.api.nvim_buf_is_valid(p.pbuf) then
        vim.api.nvim_buf_delete(p.pbuf, { force = true })
    end
    return p
end

local function discard_preview(silent)
    local p = close_preview()
    if not p then return end
    p.record.applied = false
    p.record.status = "discarded"
    write_record(p.record)
    clear_request(false)
    if not silent then
        vim.notify("agent99: proposal discarded")
    end
end

local function accept_preview()
    local p = close_preview()
    if not p then return end
    if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
        apply_lines(state.buf, p.lines, p.record)
    end
    clear_request(false)
end

local function open_preview(lines, record)
    local pbuf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(pbuf, 0, -1, false, lines)
    vim.bo[pbuf].bufhidden = "wipe"
    vim.bo[pbuf].modifiable = false
    if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
        vim.bo[pbuf].filetype = vim.bo[state.buf].filetype
    end
    vim.api.nvim_buf_set_name(pbuf, "agent99://preview")
    vim.cmd("botright " .. math.min(#lines + 2, 15) .. "split")
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, pbuf)
    vim.wo[win].winbar = "agent99 proposal — <CR> apply · q discard"
    state.preview = { pbuf = pbuf, lines = lines, record = record }
    vim.keymap.set("n", "<CR>", accept_preview, { buffer = pbuf, desc = "agent99: apply" })
    vim.keymap.set("n", "q", discard_preview, { buffer = pbuf, desc = "agent99: discard" })
    -- Wiping the preview buffer any other way counts as a discard.
    vim.api.nvim_create_autocmd("BufWipeout", {
        buffer = pbuf,
        callback = function()
            if state.preview and state.preview.pbuf == pbuf then
                local p = state.preview
                state.preview = nil
                p.record.applied = false
                p.record.status = "discarded"
                write_record(p.record)
                clear_request(false)
                vim.notify("agent99: proposal discarded")
            end
        end,
    })
end

-- ----------------------------------------------------------------- answer --

-- Show an ask-mode answer in a markdown split. The original selection stays
-- marked as state.last, so <leader>9f can turn the discussion into an edit.
local function open_answer(text)
    local old = vim.fn.bufnr("agent99://answer")
    if old ~= -1 then
        pcall(vim.api.nvim_buf_delete, old, { force = true })
    end
    local abuf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(abuf, 0, -1, false, vim.split(text, "\n", { plain = true }))
    vim.bo[abuf].bufhidden = "wipe"
    vim.bo[abuf].modifiable = false
    vim.bo[abuf].filetype = "markdown"
    vim.api.nvim_buf_set_name(abuf, "agent99://answer")
    vim.cmd("botright 15split")
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, abuf)
    vim.wo[win].winbar = "agent99 answer — <leader>9f to turn into an edit · q close"
    vim.wo[win].wrap = true
    vim.keymap.set("n", "q", vim.cmd.close, { buffer = abuf })
end

-- ------------------------------------------------------------------- runs --

-- Structured usage data mined from the runner's stderr, stored on the
-- history record so :Agent99Stats can aggregate real usage over time.
local function harvest_usage(record, stderr)
    stderr = stderr or ""
    local rounds, tokens_in, tokens_out, tokens_cached = 0, 0, 0, 0
    for line in stderr:gmatch("[^\n]+") do
        local p, c = line:match("^usage: prompt=(%d+).-completion=(%d+)")
        if p then
            rounds = rounds + 1
            tokens_in = tokens_in + tonumber(p)
            tokens_out = tokens_out + tonumber(c)
            local hit = line:match("cache_hit=(%d+)")
            if hit then
                tokens_cached = tokens_cached + tonumber(hit)
            end
        end
    end
    local tools, repeated = {}, 0
    for name in stderr:gmatch("tool ([%w_]+)%(") do
        tools[name] = (tools[name] or 0) + 1
    end
    for _ in stderr:gmatch("tool [%w_]+ REPEATED") do
        repeated = repeated + 1
    end
    if rounds > 0 then
        record.rounds = rounds
        record.tokens_in = tokens_in
        record.tokens_out = tokens_out
        record.tokens_cached = tokens_cached
        record.secs = state.started_at
            and math.floor((vim.uv.now() - state.started_at) / 1000) or nil
        local cached_pct = tokens_in > 0
            and math.floor(tokens_cached * 100 / tokens_in + 0.5) or 0
        record.stats = ("%d rounds · %.1fk in (%d%% cached) / %.1fk out · %ds")
            :format(rounds, tokens_in / 1000, cached_pct, tokens_out / 1000, record.secs or 0)
    end
    if next(tools) then
        record.tools = tools
    end
    if repeated > 0 then
        record.repeated_calls = repeated
    end
end

local function finish_failed(record, status, message)
    record.status = status
    record.applied = false
    write_record(record)
    vim.notify("agent99: " .. message, vim.log.levels.ERROR)
    if record.mode == "chat" then
        pcall(function()
            require("agent99.ui").append({ "", "*request failed: " .. message .. "*" })
        end)
    end
    clear_request(false)
end

local function on_exit(result)
    vim.schedule(function()
        local record = state.record
        -- When stderr was streamed (chat mode), vim.system delivers none in
        -- the result; use what the stream callback accumulated.
        if result.stderr == nil and state.stderr_acc then
            result.stderr = table.concat(state.stderr_acc.chunks)
        end
        state.stderr_acc = nil
        local streamed = false
        if result.stdout == nil and state.stdout_acc then
            result.stdout = table.concat(state.stdout_acc.chunks)
            streamed = state.stdout_acc.started
        end
        state.stdout_acc = nil
        log({
            "exit code: " .. tostring(result.code),
            "stdout:", result.stdout or "", "stderr:", result.stderr or "",
        })
        harvest_usage(record, result.stderr)
        if not (state.buf and vim.api.nvim_buf_is_valid(state.buf)) then
            record.status = "buffer_gone"
            write_record(record)
            clear_request(false)
            return
        end
        if result.code ~= 0 then
            record.error = (result.stderr or ""):sub(-500)
            finish_failed(record, "error",
                ("agent exited with code %d (:Agent99Logs for details)"):format(result.code))
            return
        end
        if result.stdout == nil or result.stdout:gsub("%s", "") == "" then
            finish_failed(record, "empty_reply",
                "empty reply from agent (:Agent99Logs for details)")
            return
        end
        -- Symbol-tool edits made during the run were applied to buffers
        -- already; collect them for the summary and for :Agent99Revert.
        local tool_edits = require("agent99.edits").take()
        if #tool_edits > 0 then
            state.last_edits = tool_edits
            local summary = {}
            for _, e in ipairs(tool_edits) do
                summary[#summary + 1] = ("%s %s in %s (lines %d+)"):format(
                    e.kind, e.name_path, vim.fn.fnamemodify(e.file, ":t"), e.first)
            end
            record.symbol_edits = summary
        end

        -- Chat mode: the answer goes to the panel, edits already happened
        -- through the symbol tools, and the transcript becomes the ongoing
        -- conversation.
        if record.mode == "chat" then
            local answer = (result.stdout:gsub("\r\n", "\n"):gsub("%s+$", ""))
            record.result = answer
            record.status = "answered"
            write_record(record)
            if record.transcript and vim.fn.filereadable(record.transcript) == 1 then
                local okt, msgs = pcall(function()
                    return vim.json.decode(table.concat(vim.fn.readfile(record.transcript), "\n"))
                end)
                if okt then
                    chat.messages = msgs
                end
            end
            chat.turns = chat.turns + 1
            clear_request(false)
            pcall(function()
                local ui = require("agent99.ui")
                if not streamed then
                    -- Fallback for a run where nothing streamed.
                    ui.append({ "", "## Agent", "" })
                    ui.append(answer)
                end
                if record.stats then
                    ui.append({ "", "*" .. record.stats .. "*" })
                end
            end)
            return
        end

        -- Ask-mode answers stay raw markdown; edits go through the
        -- <replacement> extraction. A reply without a replacement is accepted
        -- when the work was done through the symbol edit tools; otherwise it
        -- is refused rather than pasted into the buffer.
        local out
        if record.mode == "ask" then
            out = (result.stdout:gsub("\r\n", "\n"):gsub("\n+$", ""))
        else
            out = extract_replacement(result.stdout)
            if not out and #tool_edits > 0 then
                local summary = result.stdout:match("<summary>%s*(.-)%s*</summary>")
                    or (result.stdout:gsub("%s+$", ""))
                record.result = summary
                record.status = "tool_edits"
                if record.stats then
                    vim.notify("agent99: " .. record.stats)
                end
                write_record(record)
                -- Keep the selection reachable for a follow-up.
                local srow, erow = region_from_marks(state.buf, state.mark_start, state.mark_end)
                if srow then
                    if state.last then
                        del_mark(state.last.buf, state.last.mark_start)
                        del_mark(state.last.buf, state.last.mark_end)
                    end
                    state.last = {
                        buf = state.buf,
                        mark_start = vim.api.nvim_buf_set_extmark(state.buf, ns, srow, 0, {}),
                        mark_end = vim.api.nvim_buf_set_extmark(state.buf, ns, erow, 0, {}),
                        record = record,
                    }
                end
                clear_request(false)
                vim.notify(("agent99: %d symbol edit(s) applied - %s (:Agent99Revert to undo)")
                    :format(#tool_edits, summary:sub(1, 120)))
                return
            end
            if not out then
                record.result = result.stdout
                finish_failed(record, "no_replacement",
                    "the reply contained no <replacement> block; nothing applied "
                    .. "(reply kept in :Agent99History)")
                return
            end
        end
        local lines = vim.split(out, "\n", { plain = true })
        record.result = out
        record.status = record.mode == "ask" and "answered" or "proposed"
        if record.stats then
            vim.notify("agent99: " .. record.stats)
        end
        write_record(record)
        state.job = nil
        if record.mode == "ask" then
            -- No edit: keep the discussed region reachable for a follow-up,
            -- then show the answer.
            local answer = record.result
            local srow, erow = region_from_marks(state.buf, state.mark_start, state.mark_end)
            if srow then
                if state.last then
                    del_mark(state.last.buf, state.last.mark_start)
                    del_mark(state.last.buf, state.last.mark_end)
                end
                state.last = {
                    buf = state.buf,
                    mark_start = vim.api.nvim_buf_set_extmark(state.buf, ns, srow, 0, {}),
                    mark_end = vim.api.nvim_buf_set_extmark(state.buf, ns, erow, 0, {}),
                    record = record,
                }
            end
            clear_request(false)
            open_answer(answer)
        elseif M.config.preview then
            open_preview(lines, record)
        else
            apply_lines(state.buf, lines, record)
            clear_request(false)
        end
    end)
end

local function start_request(buf, first, last, instruction, opts)
    opts = opts or {}
    local file = vim.api.nvim_buf_get_name(buf)
    if file == "" and opts.mode ~= "chat" then
        vim.notify("agent99: buffer has no file name", vim.log.levels.ERROR)
        return
    end
    if state.preview then
        discard_preview(true)
    end
    -- Drop any stale ledger entries from a crashed or cancelled run.
    require("agent99.edits").take()
    local provider = M.config.provider
    local root = file ~= "" and project_root(file) or vim.uv.cwd()
    local id = os.date("%Y%m%d-%H%M%S") .. "-" .. math.random(1000, 9999)
    local transcript = history_dir() .. "/" .. id .. ".transcript.json"

    local mode = opts.mode or "edit"
    local region_lines = first
        and vim.api.nvim_buf_get_lines(buf, first - 1, last, false) or nil
    local prompt = opts.prompt
    if not prompt then
        local selection = table.concat(region_lines, "\n")
        local tool_prefix = provider.kind == "claude" and "MCP (mcp__lsp__*)" or "LSP"
        local builder = mode == "ask" and build_ask_prompt or build_prompt
        prompt = builder(buf, file, vim.bo[buf].filetype, root, first, last,
            selection, instruction, tool_prefix)
    end

    local bin = check_bridge()
    if not bin then
        return
    end
    local cmd, stdin
    if provider.kind == "claude" then
        cmd = {
            provider.claude_cmd, "-p",
            "--mcp-config", write_mcp_config(),
            "--strict-mcp-config",
            "--allowedTools", table.concat(provider.allowed_tools, ","),
        }
        if provider.model then
            vim.list_extend(cmd, { "--model", provider.model })
        end
        -- The prompt goes on stdin: --allowedTools is variadic and would
        -- swallow a trailing positional argument.
        stdin = prompt
    elseif provider.kind == "openai" then
        local api_key = resolve_api_key()
        if not api_key then
            vim.notify(("agent99: no API key found. Run :Agent99SetKey to store one in the "
                .. "keyring, or export $%s before starting Neovim."):format(provider.api_key_env),
                vim.log.levels.ERROR)
            return
        end
        opts.api_key = api_key
        cmd = { bin, "agent" }
        stdin = vim.json.encode({
            prompt = prompt,
            root = root,
            base_url = provider.base_url,
            model = provider.model,
            api_key_env = provider.api_key_env,
            max_rounds = provider.max_rounds,
            messages = opts.messages,
            transcript_out = transcript,
            full_tools = provider.full_tools or nil,
            system = opts.system,
            stream = opts.stream or nil,
            final_reminder = (mode == "ask" or mode == "chat")
                and "Answer in markdown."
                or "Remember: the replacement text MUST be wrapped in <replacement></replacement> tags.",
        })
    else
        vim.notify("agent99: unknown provider.kind: " .. tostring(provider.kind),
            vim.log.levels.ERROR)
        return
    end

    state.buf = buf
    if first then
        -- Extmarks ride out concurrent edits elsewhere in the buffer. The
        -- start mark also carries a highlight over the whole region, so the
        -- user can see exactly which lines the agent is working on.
        state.mark_start = vim.api.nvim_buf_set_extmark(buf, ns, first - 1, 0, {
            virt_text = { { "  agent99 working…", "Comment" } },
            virt_text_pos = "eol",
            end_row = last,
            end_col = 0,
            hl_group = "Agent99Working",
            hl_eol = true,
            strict = false,
        })
        state.mark_end = vim.api.nvim_buf_set_extmark(buf, ns, last - 1, 0, {})
    end
    state.started_at = vim.uv.now()
    state.record = {
        id = id,
        mode = mode,
        time = os.date("%Y-%m-%d %H:%M:%S"),
        file = file,
        first = first,
        last = last,
        instruction = instruction,
        provider = provider.kind .. "/" .. tostring(provider.model),
        transcript = provider.kind == "openai" and transcript or nil,
        followup_of = opts.followup_of,
        autofix = opts.autofix or nil,
        -- Guards against applying over a region the user edited mid-flight.
        region_hash = region_lines
            and vim.fn.sha256(table.concat(region_lines, "\n")) or nil,
    }

    log({ "request " .. id, "file: " .. file,
        "lines: " .. tostring(first) .. "-" .. tostring(last),
        "instruction: " .. instruction, "cmd: " .. table.concat(cmd, " ") })

    local env = { AGENT99_NVIM = server_socket() }
    if opts.api_key then
        env[provider.api_key_env] = opts.api_key
    end
    -- Chat mode streams stderr so tool activity shows live in the panel.
    local sysopts = {
        cwd = root,
        text = true,
        stdin = stdin,
        timeout = M.config.timeout_ms,
        env = env,
    }
    if opts.stream then
        -- Answer text streams into the panel as it is generated.
        state.stdout_acc = { chunks = {}, started = false }
        local oacc = state.stdout_acc
        sysopts.stdout = function(_, data)
            if not data then return end
            oacc.chunks[#oacc.chunks + 1] = data
            vim.schedule(function()
                pcall(function()
                    local ui = require("agent99.ui")
                    if not oacc.started then
                        oacc.started = true
                        ui.append({ "", "## Agent", "" })
                    end
                    ui.stream_text(data)
                end)
            end)
        end
        state.stderr_acc = { chunks = {}, partial = "" }
        local acc = state.stderr_acc
        sysopts.stderr = function(_, data)
            if not data then return end
            acc.chunks[#acc.chunks + 1] = data
            acc.partial = acc.partial .. data
            while true do
                local nl = acc.partial:find("\n", 1, true)
                if not nl then break end
                local line = acc.partial:sub(1, nl - 1)
                acc.partial = acc.partial:sub(nl + 1)
                local name, cargs = line:match("^tool ([%w_]+)%((.*)%) %->")
                if name then
                    vim.schedule(function()
                        pcall(function()
                            require("agent99.ui").activity(name .. "(" .. cargs .. ")")
                        end)
                    end)
                elseif line:find("REPEATED", 1, true) or line:find("degenerate", 1, true) then
                    vim.schedule(function()
                        pcall(function()
                            require("agent99.ui").activity(line)
                        end)
                    end)
                end
            end
        end
    end
    local ok, job = pcall(vim.system, cmd, sysopts, on_exit)
    if not ok then
        clear_request(false)
        vim.notify("agent99: failed to spawn agent: " .. tostring(job), vim.log.levels.ERROR)
        return
    end
    state.job = job
    if mode ~= "chat" then
        vim.notify(("agent99: working on %s:%d-%d…")
            :format(vim.fn.fnamemodify(file, ":t"), first, last))
    end
end

-- ------------------------------------------------------------------- chat --

local CHAT_SYSTEM = table.concat({
    "You are an AI pair programmer living inside the user's Neovim session,",
    "conversing in a side panel. You explore the project with your tools and",
    "make code changes with the symbol edit tools (replace_symbol_body,",
    "replace_symbol_lines, insert_after_symbol, insert_before_symbol) and",
    "apply_code_action - edits apply to the user's editor buffers immediately",
    "and are shown to them as they happen, so never print whole files or",
    "large code blocks into the conversation; make the edit instead and",
    "mention it briefly. Check the diagnostics each edit returns. Answer in",
    "concise markdown, cite locations as file:line, and ask a short question",
    "when the request is ambiguous rather than guessing.",
}, "\n")

local function chat_context(text)
    local parts, buf = {}, nil
    -- A staged selection (panel invoked from visual mode) is the primary
    -- context for this message.
    local ctx = require("agent99.ui").take_context()
    if ctx then
        buf = ctx.buf
        parts[#parts + 1] = ("The user selected lines %d-%d of %s:")
            :format(ctx.first, ctx.last, ctx.file)
        parts[#parts + 1] = "<selection>"
        parts[#parts + 1] = ctx.text
        parts[#parts + 1] = "</selection>"
    else
        -- Otherwise just describe what is on screen in the code window.
        for _, w in ipairs(vim.api.nvim_list_wins()) do
            local b = vim.api.nvim_win_get_buf(w)
            local name = vim.api.nvim_buf_get_name(b)
            if name ~= "" and not name:match("^agent99://") then
                buf = b
                parts[#parts + 1] = ("Currently open in the editor: %s (cursor at line %d).")
                    :format(name, vim.api.nvim_win_get_cursor(w)[1])
                break
            end
        end
    end
    parts[#parts + 1] = "The user says:"
    parts[#parts + 1] = text
    return table.concat(parts, "\n"), buf
end

--- Send one chat message from the panel.
function M.chat_send(text)
    if state.job then
        vim.notify("agent99: a request is already running", vim.log.levels.WARN)
        return
    end
    if M.config.provider.kind ~= "openai" then
        vim.notify("agent99: the chat panel needs the openai provider", vim.log.levels.WARN)
        return
    end
    local prompt, ctx_buf = chat_context(text)
    local opts = {
        mode = "chat",
        prompt = prompt,
        messages = chat.messages,
        system = chat.messages == nil and CHAT_SYSTEM or nil,
        stream = true,
    }
    local buf = ctx_buf or vim.api.nvim_get_current_buf()
    start_request(buf, nil, nil, text, opts)
end

--- Start a fresh conversation (the panel's /clear): resets the transcript
--- sent to the agent and wipes the conversation pane.
function M.chat_reset()
    if state.job then
        vim.notify("agent99: cancel the running request first", vim.log.levels.WARN)
        return
    end
    chat.messages = nil
    chat.turns = 0
    pcall(function()
        require("agent99.ui").clear()
    end)
    vim.notify("agent99: conversation cleared")
end

--- Toggle the agent panel.
function M.toggle_panel()
    require("agent99.ui").toggle()
end

--- Open the panel from a visual selection: the selection (file, range,
--- text) is staged as context for the next message. Works mid-conversation
--- too - select something new anywhere and re-invoke to continue the chat
--- with fresh context.
function M.panel_visual()
    local buf = vim.api.nvim_get_current_buf()
    local vline = vim.fn.getpos("v")[2]
    local cline = vim.fn.getpos(".")[2]
    local first, last = math.min(vline, cline), math.max(vline, cline)
    vim.api.nvim_feedkeys(
        vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
    local lines = vim.api.nvim_buf_get_lines(buf, first - 1, last, false)
    local truncated = ""
    if #lines > 300 then
        lines = vim.list_slice(lines, 1, 300)
        truncated = "\n... (selection truncated at 300 lines)"
    end
    local ui = require("agent99.ui")
    ui.open()
    ui.attach_context({
        buf = buf,
        file = vim.api.nvim_buf_get_name(buf),
        first = first,
        last = last,
        text = table.concat(lines, "\n") .. truncated,
    })
end

-- -------------------------------------------------------------------- API --

local function visual_request(mode, prompt_label)
    if state.job then
        vim.notify("agent99: a request is already running (<leader>9x to cancel)",
            vim.log.levels.WARN)
        return
    end
    local buf = vim.api.nvim_get_current_buf()
    -- getpos("v")/getpos(".") are valid while still in visual mode.
    local vline = vim.fn.getpos("v")[2]
    local cline = vim.fn.getpos(".")[2]
    local first, last = math.min(vline, cline), math.max(vline, cline)
    -- Leave visual mode NOW (the "x" flag executes the key instead of
    -- queueing it) and only then open the prompt: a queued <Esc> would be
    -- swallowed by vim.ui.input and cancel it before it is ever seen.
    vim.api.nvim_feedkeys(
        vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
    vim.schedule(function()
        vim.ui.input({ prompt = ("%s (lines %d-%d)> "):format(prompt_label, first, last) },
            function(instruction)
                if instruction == nil or instruction:gsub("%s", "") == "" then
                    vim.notify("agent99: cancelled (empty instruction)")
                    return
                end
                start_request(buf, first, last, instruction, { mode = mode })
            end)
    end)
end

--- Edit the current visual selection. Call from a visual-mode mapping.
function M.edit_visual()
    visual_request("edit", "agent99")
end

--- Ask a question about the current visual selection; the answer opens in a
--- markdown split, and <leader>9f afterwards turns the discussion into an
--- edit of the selected region.
function M.ask_visual()
    visual_request("ask", "agent99 ask")
end

--- Continue the conversation of the last applied edit with a new instruction,
--- targeting the region that edit produced. Prompts for the instruction
--- unless one is passed (programmatic use). `internal` is used by the
--- auto-fix path to mark the request and prevent fix-of-fix loops.
function M.followup(given_instruction, internal)
    local function bail(msg)
        log("followup refused: " .. msg)
        vim.notify("agent99: " .. msg, vim.log.levels.WARN)
    end
    if state.job then
        return bail("a request is already running")
    end
    local last = state.last
    if not last then
        return bail("no previous edit to follow up on")
    end
    if M.config.provider.kind ~= "openai" then
        return bail("follow-ups need the openai provider (no transcript otherwise)")
    end
    if not (vim.api.nvim_buf_is_valid(last.buf)) then
        return bail("the buffer of the last edit is gone")
    end
    local srow, erow = region_from_marks(last.buf, last.mark_start, last.mark_end)
    if not srow then
        return bail("lost track of the last edit's region")
    end
    local transcript_path = last.record and last.record.transcript
    if not (transcript_path and vim.fn.filereadable(transcript_path) == 1) then
        return bail("no transcript recorded for the last edit")
    end
    local ok, messages = pcall(function()
        return vim.json.decode(table.concat(vim.fn.readfile(transcript_path), "\n"))
    end)
    if not ok then
        return bail("could not read the last transcript")
    end
    local buf, first, last_line = last.buf, srow + 1, erow + 1
    local function run(instruction)
        if instruction == nil or instruction:gsub("%s", "") == "" then
            return
        end
        local region = table.concat(
            vim.api.nvim_buf_get_lines(buf, first - 1, last_line, false), "\n")
        local file = vim.api.nvim_buf_get_name(buf)
        local prompt = build_followup_prompt(file, first, last_line, region, instruction)
        start_request(buf, first, last_line, instruction, {
            prompt = prompt,
            messages = messages,
            followup_of = last.record and last.record.id or nil,
            autofix = internal and internal.autofix or nil,
        })
    end
    if given_instruction then
        run(given_instruction)
    else
        vim.ui.input({ prompt = "agent99 follow-up> " }, run)
    end
end

--- Programmatic entry point (used by tests): edit an explicit line range.
function M.edit_range(buf, first, last, instruction)
    if state.job then
        error("agent99: a request is already running")
    end
    start_request(buf, first, last, instruction)
end

--- Programmatic entry point (used by tests): ask about an explicit range.
function M.ask_range(buf, first, last, question)
    if state.job then
        error("agent99: a request is already running")
    end
    start_request(buf, first, last, question, { mode = "ask" })
end

function M.cancel()
    if state.preview then
        discard_preview(false)
        return
    end
    if not state.job then
        vim.notify("agent99: nothing to cancel")
        return
    end
    if state.record then
        state.record.status = "cancelled"
        write_record(state.record)
    end
    clear_request(true)
    vim.notify("agent99: request cancelled")
end

--- Undo the symbol-tool edits of the last run (newest first).
function M.revert_edits()
    if not state.last_edits or #state.last_edits == 0 then
        vim.notify("agent99: no symbol edits to revert")
        return
    end
    local n = require("agent99.edits").revert(state.last_edits)
    vim.notify(("agent99: reverted %d of %d symbol edit(s)"):format(n, #state.last_edits))
    state.last_edits = nil
end

--- Apply a pending preview (same as pressing <CR> in the preview window).
function M.accept()
    if not state.preview then
        vim.notify("agent99: no pending proposal")
        return
    end
    accept_preview()
end

function M.busy()
    return state.job ~= nil
end

function M.pending_preview()
    return state.preview ~= nil
end

function M.view_logs()
    vim.cmd.split(log_path())
end

function M.setup(opts)
    M.config = vim.tbl_deep_extend("force", M.config, opts or {})
    vim.api.nvim_set_hl(0, "Agent99Working", { default = true, link = "Visual" })
    vim.api.nvim_create_user_command("Agent99Logs", M.view_logs, {})
    vim.api.nvim_create_user_command("Agent99Cancel", M.cancel, {})
    vim.api.nvim_create_user_command("Agent99Apply", M.accept, {})
    vim.api.nvim_create_user_command("Agent99History", M.history, {})
    vim.api.nvim_create_user_command("Agent99Stats", function(o)
        M.stats(vim.trim(o.args) == "all" and "all" or nil)
    end, { nargs = "?", complete = function() return { "all" } end })
    vim.api.nvim_create_user_command("Agent99Revert", M.revert_edits, {})
    vim.api.nvim_create_user_command("Agent99SetKey", M.set_key, {})
    vim.api.nvim_create_user_command("Agent99", M.toggle_panel, {})
    vim.api.nvim_create_user_command("Agent99Clear", M.chat_reset, {})
    if M.config.keymaps then
        vim.keymap.set("n", "<leader>99", M.toggle_panel,
            { desc = "agent99: toggle agent panel" })
        vim.keymap.set("x", "<leader>99", M.panel_visual,
            { desc = "agent99: open panel with selection as context" })
        vim.keymap.set("x", "<leader>9v", M.edit_visual,
            { desc = "agent99: edit selection" })
        vim.keymap.set("x", "<leader>9a", M.ask_visual,
            { desc = "agent99: ask about selection" })
        vim.keymap.set("n", "<leader>9f", M.followup,
            { desc = "agent99: follow up on last edit" })
        vim.keymap.set("n", "<leader>9x", M.cancel,
            { desc = "agent99: cancel request / discard preview" })
        vim.keymap.set("n", "<leader>9h", M.history,
            { desc = "agent99: request history" })
        vim.keymap.set("n", "<leader>9l", M.view_logs,
            { desc = "agent99: view logs" })
    end
end

return M
