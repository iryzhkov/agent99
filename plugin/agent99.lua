-- Global RPC entry points, defined eagerly so `nvim --remote-expr` calls from
-- the bridges work even before require("agent99").setup() has run.
-- The require is inside the functions, so nothing loads at startup.

if vim.g.loaded_agent99 then
    return
end
vim.g.loaded_agent99 = true

_G.Agent99RpcStart = function(b64)
    return require("agent99.rpc").start(b64)
end

_G.Agent99RpcPoll = function(id)
    return require("agent99.rpc").poll(id)
end
