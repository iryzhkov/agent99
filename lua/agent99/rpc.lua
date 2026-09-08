-- RPC entry points for the bridges.
--
-- Non-blocking protocol: the bridge calls
--   nvim --server <socket> --remote-expr "v:lua.Agent99RpcStart('<b64>')"
-- which starts the tool in a coroutine and returns a request id immediately,
-- then polls
--   nvim --server <socket> --remote-expr "v:lua.Agent99RpcPoll('<id>')"
-- until the JSON response is ready. Each poll costs the editor's main loop
-- only microseconds, so the UI stays responsive while LSP work is in flight.
--
-- Payloads are base64-encoded JSON ({tool = ..., args = {...}}) so they
-- survive shell and Vimscript quoting untouched.

local M = {}

-- Drop finished-but-never-polled requests after this long. A request
-- still running is left alone: a slow tool (a whole-project check) can
-- outlast this while another bridge's start sweeps, and dropping it would
-- turn its result into "unknown request id" for the bridge polling it.
local STALE_MS = 5 * 60 * 1000
-- ...except that a request nothing ever finishes (a coroutine that died
-- without resuming, a callback never invoked) must not stay forever.
local ABANDONED_MS = 20 * 60 * 1000

local pending = {}
local next_id = 0

local function sweep()
    local now = vim.uv.now()
    for id, p in pairs(pending) do
        local age = now - p.started
        if (p.done and age > STALE_MS) or age > ABANDONED_MS then
            pending[id] = nil
        end
    end
end

function M.start(b64)
    sweep()
    next_id = next_id + 1
    local id = tostring(next_id)
    pending[id] = { done = false, started = vim.uv.now() }
    local co = coroutine.create(function()
        -- LuaJIT pcall is yield-safe, so this catches errors from any resume.
        local ok, result = pcall(function()
            local payload = vim.json.decode(vim.base64.decode(b64))
            return require("agent99.lsp").dispatch(payload.tool, payload.args)
        end)
        local response = ok and { ok = true, result = result }
            or { ok = false, error = tostring(result) }
        -- A result the encoder rejects (a function value, a cycle, invalid
        -- UTF-8) must still answer the poll, as an error rather than a
        -- request that never completes.
        local okj, payload = pcall(vim.json.encode, response)
        if not okj then
            payload = vim.json.encode({ ok = false,
                error = "result not encodable as JSON: " .. tostring(payload) })
        end
        local p = pending[id]
        if p then
            p.done = true
            p.payload = payload
        end
    end)
    local ok, cerr = coroutine.resume(co)
    if not ok then
        pending[id] = {
            done = true,
            started = vim.uv.now(),
            payload = vim.json.encode({ ok = false, error = tostring(cerr) }),
        }
    end
    return id
end

function M.poll(id)
    local p = pending[id]
    if not p then
        return vim.json.encode({ ok = false, error = "unknown request id: " .. tostring(id) })
    end
    if not p.done then
        return vim.json.encode({ pending = true })
    end
    pending[id] = nil
    return p.payload
end

return M
