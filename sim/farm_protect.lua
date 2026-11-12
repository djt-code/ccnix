-- sim/farm_protect.lua
--
-- Protected areas (ADR-0008) hold for farm's own crop digs, which call
-- turtle.digDown() straight: a garden of two ripe wheat tiles and a cane
-- tile that another program protected is left alone (not harvested, not
-- counted as damage, no repair pass), the rest of the farm is farmed as
-- ever, and once the area is let go of the next pass takes them.
local PROJ = ...
package.path = PROJ .. "/turtle/?.lua;" .. PROJ .. "/lib/?.lua;" .. PROJ .. "/sim/lib/?.lua;" .. package.path
local F = require("farmworld")
local check = F.check
local run = F.runner(PROJ)

local function ripeAt(x, z)
    local b = F.get(x, -1, z)
    return b ~= nil and F.RIPE[b.name] ~= nil and b.age >= F.RIPE[b.name]
end

-- 1. learn a 5x6 wheat farm (a lane at x=3), everything ripe, with the
--    garden protected: two crop tiles at (2,2) and (2,3)
F.build({ width = 5, length = 6, lanes = { 3 } })
F.stock()
run("5", "6", "0")
F.ripen()
F.stock()
F.files[".protected"] = "2 -1 2 2 -1 3 garden\n"
local unprotected = {}
for x = 1, 5 do for z = 1, 6 do
    if x ~= 3 and not (x == 2 and (z == 2 or z == 3)) then unprotected[#unprotected + 1] = { x, z } end
end end
run("0")
F.show("after the pass with the garden protected")
local harvested = 0
for _, t in ipairs(unprotected) do if not ripeAt(t[1], t[2]) then harvested = harvested + 1 end end
check("the garden's ripe crops are still standing, not harvested", ripeAt(2, 2) and ripeAt(2, 3))
check("the rest of the farm was harvested and replanted (unripe now)", harvested == #unprotected, harvested .. " of " .. #unprotected)
check("the tiles left alone are not counted as harvested (22 of 24)", F.logHas("Harvested 22,"))
check("it said how many tiles it left alone", F.logHas("2 tiles left alone: they are in a protected area"))
check("...and did not call that damage or start a repair", not F.logHas("Damage:") and not F.logHas("Full repair"))

-- 2. the garden let go of: the next pass takes the ripe crops
F.files[".protected"] = nil
F.ripen()
F.stock()
run("0")
check("with the area gone the garden is harvested too", not ripeAt(2, 2) and F.get(2, -1, 2) ~= nil and not ripeAt(2, 3))
check("...and nothing is left alone", not F.logHas("left alone"))

-- 3. a protected cane strip, two high (the second block is what farm cuts):
--    the cut is refused and the cane stays; the other strip is cut
for k in pairs(F.files) do F.files[k] = nil end
F.P.x, F.P.y, F.P.z, F.P.d = 0, 0, 0, 0
F.build({ width = 5, length = 4, lanes = { 3 }, crops = { [1] = "cane", [5] = "cane" } })
F.stock({ cane = 16 })
run("5", "4", "0")

for x = 1, 5, 4 do for z = 1, 4 do for h = 1, 2 do F.set(x, -2 + h, z, { name = F.CANE }) end end end
F.stock({ cane = 16 })
F.files[".protected"] = "1 0 1 1 1 4 cane strip\n"
run("0")
F.print("   cane heights x=1: " .. F.caneHeights(1) .. "   x=5: " .. F.caneHeights(5))
check("a protected cane strip is not cut (still 2 high)", F.caneHeights(1) == "2 2 2 2", F.caneHeights(1))
check("...the other strip is cut down to its bottom block", F.caneHeights(5) == "1 1 1 1", F.caneHeights(5))
check("...and the four cane tiles are said to be left alone", F.logHas("4 tiles left alone"))
