-- sim/farm_sugar_cane.lua
--
-- A farm with a sugar cane strip: learning it, harvesting all but the
-- bottom block, replanting a missing cane after its lane dried up.
local PROJ = ...
package.path = PROJ .. "/turtle/?.lua;" .. PROJ .. "/lib/?.lua;" .. PROJ .. "/sim/lib/?.lua;" .. package.path
local F = require("farmworld")
local run = F.runner(PROJ)
local LANE_X, CANE_X = 3, 4

local function regrowCane()
    for z = 1, F.LENGTH do for h = 1, 3 do F.set(CANE_X, -2 + h, z, { name = F.CANE }) end end
end
local function cutCane(z)
    for y = -1, 1 do F.set(CANE_X, y, z, nil) end
end

-- C1. learn a farm with a cane strip of heights 1-3, one cane missing
F.build({ width = 5, length = 6, lanes = { LANE_X }, crops = { [CANE_X] = "cane", [5] = "minecraft:beetroots" } })
F.stock({ cane = 16, water = 1 })
cutCane(5)                                                            -- bare sand at z=5
LOST = 0
F.print("cane heights z=1..6 before: " .. F.caneHeights(CANE_X))
run("5", "6", "0")
F.print("   cane heights after: " .. F.caneHeights(CANE_X) .. "   lost to the ground: " .. LOST)
F.show("after C1")
-- C2. cane grows back to 3; the lane next to z=3 dries up (and stays dry
--     by itself) and that cane's bottom is gone
regrowCane()
F.STUCK["3,3"] = true
F.set(LANE_X, -2, 3, nil)
cutCane(3)
F.ripen()
F.stock({ cane = 16, water = 1 })
run("0")
F.print("   cane heights after: " .. F.caneHeights(CANE_X) .. "   lost to the ground: " .. LOST)
F.show("after C2")
F.print("   chest: " .. F.chestLine())
-- C3. one regular pass on the repaired cane farm, cane regrown to 3
regrowCane()
F.stock({ cane = 16, water = 1 })
run("0")
F.print("   cane heights after: " .. F.caneHeights(CANE_X) .. "   lost to the ground: " .. LOST)
