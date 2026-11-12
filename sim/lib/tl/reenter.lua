-- sim/lib/tl/reenter.lua -- a module that asks T for its own function while it
-- is still loading, for the loader sim: that must be nil and why, not a loop.
local T = require("turtlelib")
REENTER_EARLY = table.pack(T.need("reentrantTwo"))

-- The first function.
function T.reentrantOne() return 1 end

-- The second function.
function T.reentrantTwo() return 2 end

return true
