-- sim/lib/tl/fixture.lua -- a stand-in for a turtle/tl/ module, for the
-- sims of turtlelib's loader: it counts how often it is loaded (the global
-- FIXTURE_LOADS) and adds a few functions to the T it is handed.
FIXTURE_LOADS = (FIXTURE_LOADS or 0) + 1
local T = require("turtlelib")

-- A function that says hello.
function T.fixtureHello(name) return "hello " .. tostring(name) end

-- A second function of the same module.
function T.fixtureSecond() return "second" end

-- The T the module was handed.
function T.fixtureSame() return T end

-- Whether a module sees the real fs: the API key file is out of the model's
-- reach in claude's code, but not of turtlelib's world.
function T.fixtureReadsKey()
    local h = fs.open("claude.key", "r")
    if h then h.close() end
    return h ~= nil
end

return true
