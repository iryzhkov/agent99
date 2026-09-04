-- A test file, so the map's test-file handling has something to show.
local util = require("testproj.util")

local function test_greet()
    assert(util.greet("x") == "hello, x")
end

return { test_greet = test_greet }
