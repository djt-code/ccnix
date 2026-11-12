-- sim/lib/tl/route.lua -- a stand-in for the path module, for the moveTo sim:
-- T.travel(x, y, z, opts) takes a route by digging straight through.
ROUTE_LOADS = (ROUTE_LOADS or 0) + 1
local T = require("turtlelib")

-- Go to the cell, digging what is in the way; true, or false and why.
function T.travel(x, y, z, opts)
    return T.moveTo(x, y, z, { order = "xzy", dig = true, inside = opts and opts.inside })
end

return true
