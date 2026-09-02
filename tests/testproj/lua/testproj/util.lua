local M = {}

--- Greet a person by name.
--- @param name string
--- @return string
function M.greet(name)
    return "hello, " .. name
end

function M.shout(name)
    return string.upper(M.greet(name))
end

return M
