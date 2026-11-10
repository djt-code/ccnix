-- sim/farm_clone_lane_fallback.lua
--
-- Same as farm_clone, but two lane tiles never turn into a source by
-- themselves: the turtle has to notice and pour them.
local PROJ = ...
package.path = PROJ .. "/turtle/?.lua;" .. PROJ .. "/lib/?.lua;" .. PROJ .. "/sim/lib/?.lua;" .. package.path
local F = require("farmworld")
local run = F.runner(PROJ)

F.build({ width = 7, length = 16, lanes = { 3, 6 } })
F.chest = { { name = "minecraft:wheat_seeds", count = 64 }, { name = "minecraft:wheat_seeds", count = 64 },
            { name = "minecraft:dirt", count = 64 }, { name = "minecraft:water_bucket", count = 1 },
            { name = "minecraft:water_bucket", count = 1 }, { name = "minecraft:bucket", count = 4 } }
F.inv = { { name = "minecraft:diamond_pickaxe", count = 1 } }
run("7", "16", "0")

-- wipe the farm back to grass, keep the dirt floor
for x = 1, F.WIDTH do for z = 1, F.LENGTH do
    F.set(x, -2, z, { name = "minecraft:grass_block" }); F.set(x, -1, z, nil)
end end
SCOOPS, POURS = 0, 0
F.STUCK = { ["3,6"] = true, ["3,11"] = true }
run("clone", "0")
local crops = F.cropCount()
F.print(string.format("CLONE: moves=%d scoops=%d pours=%d bad lane tiles=%d crops=%d spilled=%s",
    F.moves, SCOOPS, POURS or 0, F.badLaneTiles(), crops, tostring(SPILLED or 0)))
