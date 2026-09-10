-- Which client a call belongs to.
--
-- One headless Neovim serves every client that opened its root, and several
-- of the records kept here are per client rather than per project: the undo
-- ledger, the check_project and run_tests baselines, and the set of
-- diagnostics a client has already been shown. Keyed by the root alone they
-- leaked between clients - one agent's undo_edit() with no arguments popped
-- another agent's edit, reverted it, and reported success, and a client that
-- had never recorded a baseline was told what was "new since the baseline"
-- another client recorded.
--
-- The bridge puts the id in every call's arguments (bridge/client.go says
-- where it comes from and what it can and cannot tell apart). Nothing is
-- guessed here: with no id the call is the editor's own, which is what an
-- interactive request and a unit test are.

local M = {}

-- The editor itself: an interactive request, a keymap, a unit test, a
-- callback outside any request. Its edits are what :Agent99Revert reverts,
-- so the agent run inside a live Neovim shares this ledger with it on
-- purpose (bridge/client.go maps embedded mode onto this id).
M.EDITOR = "editor"

-- Which client the request running on each coroutine is for. rpc.lua runs
-- one request per coroutine and the tools yield inside it (core.await), so
-- two clients' calls interleave in this editor: one "current client"
-- variable would be whichever request resumed last. Weak keys, so a
-- finished coroutine's entry goes away with it.
local by_co = setmetatable({}, { __mode = "k" })

-- The running coroutine, or nil on the main one. LuaJIT returns nil there;
-- Lua 5.4 returns the main coroutine and true, and neither is a request.
local function co_key()
    local co, main = coroutine.running()
    if co == nil or main == true then return nil end
    return co
end

--- Record which client the request on this coroutine is for. Called once per
--- dispatched request, with the id the bridge sent in its arguments.
function M.enter(id)
    local co = co_key()
    if not co then return end
    by_co[co] = (type(id) == "string" and id ~= "") and id or nil
end

--- Who the call now running is for.
function M.current()
    local co = co_key()
    if co then
        local id = by_co[co]
        if id then return id end
    end
    return M.EDITOR
end

--- Run `fn` as if the running call belonged to `id`, then put the previous
--- id back. For work owed to one client that is finished while another
--- client's call happens to be the one running: a verdict deferred by a
--- wait=false edit is reported to the client that made that edit, and has to
--- be measured against what *that* client has been shown, not against the
--- list of whoever's reply is carrying it out of the editor.
function M.as_client(id, fn)
    local co = co_key()
    if not co or type(id) ~= "string" or id == "" then
        return fn()
    end
    local previous = by_co[co]
    by_co[co] = id
    local ok, res = pcall(fn)
    by_co[co] = previous
    if not ok then error(res, 0) end
    return res
end

--- This client's own table inside a store keyed by client id, made on first
--- use. The store stays visible to its owner, so a reply can also say what
--- the other clients have in it.
function M.slot(store)
    local id = M.current()
    local mine = store[id]
    if mine == nil then
        mine = {}
        store[id] = mine
    end
    return mine
end

--- A key for a per-client, per-root record: the same command run by two
--- clients is two baselines.
function M.key(...)
    local parts = { M.current() }
    for _, part in ipairs({ ... }) do
        parts[#parts + 1] = tostring(part)
    end
    return table.concat(parts, "\0")
end

--- The id as a reply names it. Ids are opaque and a session id is a
--- 36-character UUID, so a reply carries a prefix; it is a label to tell two
--- holders apart in one sentence, not an address to call a client by.
--- Matches shortClient in bridge/client.go.
function M.label(id)
    id = id or M.current()
    if #id <= 12 then return id end
    return id:sub(1, 8)
end

return M
