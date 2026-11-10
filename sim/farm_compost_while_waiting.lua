-- sim/farm_compost_while_waiting.lua
--
-- Compost hopper behind home: while waiting for the next run, surplus
-- wheat and beetroot seeds go into the hopper.  A 5-minute wait finishes
-- it all; a 1-minute wait runs out of time.  The simulator ends each wait
-- early by raising STOP.
local PROJ = ...
package.path = PROJ .. "/turtle/?.lua;" .. PROJ .. "/lib/?.lua;" .. PROJ .. "/sim/lib/?.lua;" .. package.path
local F = require("farmworld")
local run = F.runner(PROJ)

F.build({ width = 5, length = 6, lanes = { 3 }, crops = { [4] = "minecraft:carrots", [5] = "minecraft:beetroots" } })
F.set(0, 0, -1, { name = "minecraft:hopper" })      -- directly behind home

local function hopped()
    local cs = {}
    for n, v in pairs(HOPPED) do cs[#cs + 1] = v .. " " .. n:gsub("minecraft:", "") end
    table.sort(cs)
    return table.concat(cs, ", ")
end
local function addSeeds(stacks)
    for _ = 1, stacks do
        for s = 1, F.CHEST_SIZE do
            if not F.chest[s] then F.chest[s] = { name = "minecraft:wheat_seeds", count = 64 }; break end
        end
    end
end

F.chest = {}
for _ = 1, 6 do F.chest[#F.chest + 1] = { name = "minecraft:wheat", count = 64 } end
for _ = 1, 3 do F.chest[#F.chest + 1] = { name = "minecraft:bone_meal", count = 64 } end
for _ = 1, 6 do F.chest[#F.chest + 1] = { name = "minecraft:wheat_seeds", count = 64 } end
F.chest[#F.chest + 1] = { name = "minecraft:dirt", count = 64 }
for _ = 1, 3 do F.chest[#F.chest + 1] = { name = "minecraft:carrot", count = 64 } end
for _ = 1, 2 do F.chest[#F.chest + 1] = { name = "minecraft:beetroot_seeds", count = 64 } end
F.print("chest before: " .. F.chestLine())
run("5", "6", "0")
F.print("   hopper got: " .. hopped() .. "   chest now: " .. F.chestLine())
-- a repeating run with a 5-minute wait: stop just before the second pass
HOPPED = {}
STOP_AT = CLOCK + 5 * 60 - 1
run("5")
F.print(string.format("   waited %.0fs; hopper got: %s   chest now: %s", CLOCK, hopped(), F.chestLine()))
-- a 1-minute wait isn't long enough for all of it
addSeeds(10)
HOPPED, CLOCK, HOPPER = {}, 0, 0
STOP_AT = 59
run("1")
F.print(string.format("   waited %.0fs; hopper got: %s   chest now: %s", CLOCK, hopped(), F.chestLine()))
