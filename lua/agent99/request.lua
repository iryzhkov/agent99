-- Request lifecycle: spawn the bridge, stream/collect its output, and land
-- the result — apply or preview a replacement, open an answer split, or
-- hand a chat reply to the panel. One in-flight request at a time keeps
-- cancellation and extmarks simple.

local config = require("agent99.config")
local history = require("agent99.history")

local M = {}

local ns = vim.api.nvim_create_namespace("agent99")
local log = config.log

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

local function check_bridge()
    local bin = config.bridge_bin()
    if vim.fn.executable(bin) == 1 then
        return bin
    end
    vim.notify(("agent99: bridge binary not found at %s. Run `make build` in %s "
        .. "(requires Go)."):format(bin, config.plugin_root()), vim.log.levels.ERROR)
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
                command = config.bridge_bin(),
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
    local opts = config.options
    if not opts.auto_fix or record.autofix
        or opts.provider.kind ~= "openai" or not record.transcript then
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
    end, opts.auto_fix_delay_ms)
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
            history.write(record)
            vim.notify(("agent99: %d symbol edit(s) applied; the duplicate replacement "
                .. "reply was skipped (:Agent99Revert to undo)"):format(#record.symbol_edits))
            return
        end
        record.status = "stale_refused"
        history.write(record)
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
    history.write(record)
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
                history.write(record)
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
    history.write(p.record)
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
                history.write(p.record)
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
    local tools, repeated, duplicates = {}, 0, 0
    for name in stderr:gmatch("tool ([%w_]+)%(") do
        tools[name] = (tools[name] or 0) + 1
    end
    for _ in stderr:gmatch("tool [%w_]+ REPEATED") do
        repeated = repeated + 1
    end
    for _ in stderr:gmatch("tool [%w_]+ DUPLICATE") do
        duplicates = duplicates + 1
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
    if duplicates > 0 then
        record.duplicate_results = duplicates
    end
end

local function finish_failed(record, status, message)
    record.status = status
    record.applied = false
    history.write(record)
    vim.notify("agent99: " .. message, vim.log.levels.ERROR)
    if record.mode == "chat" then
        pcall(function()
            require("agent99.ui").append({ "", "*request failed: " .. message .. "*" })
        end)
    end
    clear_request(false)
end

local function keep_last_region()
    local srow, erow = region_from_marks(state.buf, state.mark_start, state.mark_end)
    if not srow then
        return
    end
    if state.last then
        del_mark(state.last.buf, state.last.mark_start)
        del_mark(state.last.buf, state.last.mark_end)
    end
    state.last = {
        buf = state.buf,
        mark_start = vim.api.nvim_buf_set_extmark(state.buf, ns, srow, 0, {}),
        mark_end = vim.api.nvim_buf_set_extmark(state.buf, ns, erow, 0, {}),
        record = state.record,
    }
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
            history.write(record)
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
            history.write(record)
            require("agent99.chat").absorb(record)
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
                history.write(record)
                -- Keep the selection reachable for a follow-up.
                keep_last_region()
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
        history.write(record)
        state.job = nil
        if record.mode == "ask" then
            -- No edit: keep the discussed region reachable for a follow-up,
            -- then show the answer.
            local answer = record.result
            keep_last_region()
            clear_request(false)
            open_answer(answer)
        elseif config.options.preview then
            open_preview(lines, record)
        else
            apply_lines(state.buf, lines, record)
            clear_request(false)
        end
    end)
end

--- Start a request. opts: mode ("edit"/"ask"/"chat"), prompt (overrides the
--- built one), messages (prior transcript for follow-ups/chat), system,
--- stream, followup_of, autofix.
function M.start(buf, first, last, instruction, opts)
    opts = opts or {}
    local cfg = config.options
    local provider = cfg.provider
    local prompts = require("agent99.prompts")
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
    local root = file ~= "" and project_root(file) or vim.uv.cwd()
    local id, transcript = history.new_id()

    local mode = opts.mode or "edit"
    local region_lines = first
        and vim.api.nvim_buf_get_lines(buf, first - 1, last, false) or nil
    local prompt = opts.prompt
    if not prompt then
        local selection = table.concat(region_lines, "\n")
        local builder = mode == "ask" and prompts.ask or prompts.edit
        prompt = builder(buf, file, vim.bo[buf].filetype, root, first, last,
            selection, instruction)
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
    else
        local api_key = config.resolve_api_key()
        if not api_key then
            vim.notify(("agent99: no API key found. Run :Agent99SetKey to store one in the "
                .. "keyring, or export $%s before starting Neovim.")
                :format(provider.api_key_env or "API_KEY"), vim.log.levels.ERROR)
            return
        end
        opts.api_key = api_key
        cmd = { bin, "agent" }
        stdin = vim.json.encode({
            prompt = prompt,
            root = root,
            base_url = provider.base_url,
            model = provider.model,
            api_key_env = provider.api_key_env or "AGENT99_API_KEY",
            max_rounds = provider.max_rounds,
            temperature = provider.temperature,
            max_tokens = provider.max_tokens,
            messages = opts.messages,
            transcript_out = transcript,
            full_tools = provider.full_tools or nil,
            system = opts.system,
            stream = opts.stream or nil,
            final_reminder = (mode == "ask" or mode == "chat")
                and prompts.MARKDOWN_REMINDER
                or prompts.REPLACEMENT_REMINDER,
        })
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
        env[provider.api_key_env or "AGENT99_API_KEY"] = opts.api_key
    end
    -- Chat mode streams stderr so tool activity shows live in the panel.
    local sysopts = {
        cwd = root,
        text = true,
        stdin = stdin,
        timeout = cfg.timeout_ms,
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
                elseif line:find("REPEATED", 1, true) or line:find("DUPLICATE", 1, true)
                    or line:find("degenerate", 1, true) then
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

--- Continue the conversation of the last applied edit with a new
--- instruction, targeting the region that edit produced. Prompts for the
--- instruction unless one is passed (programmatic use). `internal` is used
--- by the auto-fix path to mark the request and prevent fix-of-fix loops.
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
    if config.options.provider.kind ~= "openai" then
        return bail("follow-ups need an openai-kind provider (no transcript otherwise)")
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
        local prompt = require("agent99.prompts").followup(
            file, first, last_line, region, instruction)
        M.start(buf, first, last_line, instruction, {
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
        history.write(state.record)
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

return M
