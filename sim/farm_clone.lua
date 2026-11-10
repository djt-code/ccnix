-- sim/farm_clone.lua
--
-- Learn a 7x16 farm with two lanes, wipe it back to grass and run
-- `farm clone`.  Reports moves, buckets scooped and poured, and any lane
-- tile that didn't end up a water source.
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
SCOOPS, POURS, FIRSTPOUR, LASTPOUR = 0, 0, nil, nil
run("clone", "0")
local crops = F.cropCount()
F.print(string.format("WATER PHASE: %d moves from first to last pour", (LASTPOUR or 0) - (FIRSTPOUR or 0)))
F.print(string.format("CLONE: moves=%d scoops=%d pours=%d bad lane tiles=%d crops=%d spilled=%s",
    F.moves, SCOOPS, POURS or 0, F.badLaneTiles(), crops, tostring(SPILLED or 0)))
