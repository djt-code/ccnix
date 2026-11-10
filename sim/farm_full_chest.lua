-- sim/farm_full_chest.lua
--
-- Inventory and chest limits: a turtle stuffed with coal, a chest with
-- room for only a few stacks, then a chest that is already full.  Nothing
-- should spill on the ground; the turtle waits for room instead.
local PROJ = ...
package.path = PROJ .. "/turtle/?.lua;" .. PROJ .. "/lib/?.lua;" .. PROJ .. "/sim/lib/?.lua;" .. package.path
local F = require("farmworld")
local run = F.runner(PROJ)

-- the "player" empties the chest on the turtle's second long wait for room
local fixtureSleep = sleep
sleep = function(t)
    fixtureSleep(t)
    if t and t >= 30 then
        WAITS = WAITS + 1
        if WAITS == 2 then F.chest = {}; print("  [player empties the chest]") end
    end
end

local function regrowCane()
    for z = 1, F.LENGTH do for h = 1, 3 do F.set(4, -2 + h, z, { name = F.CANE }) end end
end
local function fullOfCoal()
    F.inv = {}
    for s = 1, 11 do F.inv[s] = { name = "minecraft:coal", count = 64 } end
end

-- F1. learn the farm (no limits), then everything ripe
F.build({ width = 5, length = 6, lanes = { 3 }, crops = { [4] = "cane", [5] = "minecraft:beetroots" } })
F.stock({ cane = 16, water = 1 })
WAITS = 0
run("5", "6", "0")
F.ripen()
regrowCane()
-- F2. 11 slots of coal (kept as fuel), and a chest with room for only a few more stacks
fullOfCoal()
F.stock({ cane = 16, water = 1 })
F.CHEST_SIZE = #F.chest + 3
SPILLED, WAITS = 0, 0
run("0")
F.print("   spilled on the ground: " .. SPILLED .. "   waits: " .. WAITS)
-- F3. same, but the chest is already full
F.ripen()
regrowCane()
fullOfCoal()
F.stock({ cane = 16, water = 1 })
F.CHEST_SIZE = #F.chest
SPILLED, WAITS = 0, 0
run("0")
F.print("   spilled on the ground: " .. SPILLED .. "   waits: " .. WAITS)
