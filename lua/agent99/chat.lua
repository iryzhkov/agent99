-- The panel conversation: transcript state, sending a message, and reset.
-- Persists for the whole Neovim session; only reset (gn in the panel,
-- /clear, :Agent99Clear) starts over.

local config = require("agent99.config")

local M = {}

local state = {
    messages = nil, -- full transcript (system + turns + tool calls)
    turns = 0,
    session = nil,  -- groups this conversation's records in the history
}

-- Build the prompt for one chat message: staged selection first, otherwise
-- what is on screen in the code window. Returns the prompt and the buffer
-- providing context.
local function chat_context(text)
    local parts, buf = {}, nil
    local ctx = require("agent99.ui").take_context()
    if ctx then
        buf = ctx.buf
        parts[#parts + 1] = ("The user selected lines %d-%d of %s:")
            :format(ctx.first, ctx.last, ctx.file)
        parts[#parts + 1] = "<selection>"
        parts[#parts + 1] = ctx.text
        parts[#parts + 1] = "</selection>"
    else
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

--- Send one panel message through the request engine. When the active
--- provider cannot chat (claude: no transcript comes back), fall back to
--- the configured chat_provider preset for this request only.
function M.send(text)
    local request = require("agent99.request")
    if request.busy() then
        vim.notify("agent99: a request is already running", vim.log.levels.WARN)
        return
    end
    local provider
    if config.options.provider.kind ~= "openai" then
        local fallback = config.options.chat_provider
        local ok, resolved = false, nil
        if fallback then
            ok, resolved = pcall(config.resolve, fallback)
        end
        if not (ok and resolved and resolved.kind == "openai") then
            vim.notify("agent99: the chat panel needs an openai-kind provider - switch with "
                .. ":Agent99Provider, or set chat_provider = \"deepseek\" to let the panel "
                .. "fall back automatically", vim.log.levels.WARN)
            return
        end
        provider = resolved
        pcall(function()
            require("agent99.ui").activity(("chat via %s (chat_provider)")
                :format(tostring(resolved.model)))
        end)
    end
    state.session = state.session
        or (os.date("%Y%m%d-%H%M%S") .. "-s" .. math.random(1000, 9999))
    local prompt, ctx_buf = chat_context(text)
    local buf = ctx_buf or vim.api.nvim_get_current_buf()
    request.start(buf, nil, nil, text, {
        mode = "chat",
        prompt = prompt,
        provider = provider,
        chat_session = state.session,
        messages = state.messages,
        system = state.messages == nil and require("agent99.prompts").CHAT_SYSTEM or nil,
        stream = true,
    })
end

--- Called by the request engine when a chat run finishes: adopt the run's
--- transcript as the ongoing conversation.
function M.absorb(record)
    if record.transcript and vim.fn.filereadable(record.transcript) == 1 then
        local ok, msgs = pcall(function()
            return vim.json.decode(table.concat(vim.fn.readfile(record.transcript), "\n"))
        end)
        if ok then
            state.messages = msgs
        end
    end
    state.turns = state.turns + 1
end

--- Restore a past chat conversation from its history record: the stored
--- transcript becomes the live conversation and the panel is rebuilt from
--- it, so the chat continues where it left off. Returns true on success;
--- false (with a notification) when a request is running, the transcript
--- is gone, or the user keeps the current conversation.
function M.restore(rec)
    if require("agent99.request").busy() then
        vim.notify("agent99: a request is running - showing the record instead",
            vim.log.levels.WARN)
        return false
    end
    local path = rec.transcript
    if not (path and vim.fn.filereadable(path) == 1) then
        vim.notify("agent99: this chat's transcript is gone - showing the record instead",
            vim.log.levels.WARN)
        return false
    end
    local ok, msgs = pcall(function()
        return vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
    end)
    if not (ok and type(msgs) == "table") then
        vim.notify("agent99: could not read the transcript - showing the record instead",
            vim.log.levels.WARN)
        return false
    end
    if state.messages and vim.fn.confirm(
        "agent99: replace the current panel conversation?", "&Yes\n&No", 2) ~= 1 then
        return false
    end
    state.messages = msgs
    state.turns = 0
    -- Continue the restored conversation's history grouping.
    state.session = rec.chat_session or rec.id
    local ui = require("agent99.ui")
    ui.open() -- creates the panel buffers when this is the first open
    ui.clear()
    for _, m in ipairs(msgs) do
        if m.role == "user" then
            local text = (m.content or ""):match("The user says:\n(.*)$") or m.content
            ui.append({ "", "## You", "" })
            ui.append(text or "")
        elseif m.role == "assistant" and m.content and m.content ~= "" then
            state.turns = state.turns + 1
            ui.append({ "", "## Agent", "" })
            ui.append(m.content)
        end
    end
    ui.append({ "", ("*conversation restored from %s — continue below*")
        :format(rec.time or "history"), "" })
    ui.open()
    return true
end

--- Start a fresh conversation (the panel's /clear): resets the transcript
--- sent to the agent and wipes the conversation pane.
function M.reset()
    if require("agent99.request").busy() then
        vim.notify("agent99: cancel the running request first", vim.log.levels.WARN)
        return
    end
    -- The conversation's records stay in the history (one entry per
    -- session, restorable from the picker); this only starts a new one.
    state.messages = nil
    state.turns = 0
    state.session = nil
    pcall(function()
        require("agent99.ui").clear()
    end)
    vim.notify("agent99: new conversation (the old one stays in :Agent99History)")
end

return M
