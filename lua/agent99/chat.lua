-- The panel conversation: transcript state, sending a message, and reset.
-- Persists for the whole Neovim session; only reset (gn in the panel,
-- /clear, :Agent99Clear) starts over.

local config = require("agent99.config")

local M = {}

local state = {
    messages = nil, -- full transcript (system + turns + tool calls)
    turns = 0,
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

--- Send one panel message through the request engine.
function M.send(text)
    local request = require("agent99.request")
    if request.busy() then
        vim.notify("agent99: a request is already running", vim.log.levels.WARN)
        return
    end
    if config.options.provider.kind ~= "openai" then
        vim.notify("agent99: the chat panel needs an openai-kind provider", vim.log.levels.WARN)
        return
    end
    local prompt, ctx_buf = chat_context(text)
    local buf = ctx_buf or vim.api.nvim_get_current_buf()
    request.start(buf, nil, nil, text, {
        mode = "chat",
        prompt = prompt,
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

--- Start a fresh conversation (the panel's /clear): resets the transcript
--- sent to the agent and wipes the conversation pane.
function M.reset()
    if require("agent99.request").busy() then
        vim.notify("agent99: cancel the running request first", vim.log.levels.WARN)
        return
    end
    state.messages = nil
    state.turns = 0
    pcall(function()
        require("agent99.ui").clear()
    end)
    vim.notify("agent99: conversation cleared")
end

return M
