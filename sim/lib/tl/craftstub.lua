-- sim/lib/tl/craftstub.lua -- a stand-in for the craft module (tl.craft), for the sims of tl.blueprint's materials
-- check: it counts how often it is loaded (the global CRAFTSTUB_LOADS) and answers T.canCraft.
CRAFTSTUB_LOADS = (CRAFTSTUB_LOADS or 0) + 1
local T = require("turtlelib")

-- Can n of the item be crafted from what is on hand?  (Here: stone bricks can, anything else cannot.)
function T.canCraft(name, n)
    if name == "minecraft:stone_bricks" then return true end
    return "no recipe for " .. name
end

return true
