-- sim/farm_bone_meal.lua
--
-- Grow passes: with enough bone meal in the chest, the turtle bone-meals
-- the whole farm, harvests and replants, and repeats while meal lasts.
local PROJ = ...
package.path = PROJ .. "/turtle/?.lua;" .. PROJ .. "/lib/?.lua;" .. PROJ .. "/sim/lib/?.lua;" .. package.path
local F = require("farmworld")
local run = F.runner(PROJ)

F.build({ width = 5, length = 6, lanes = { 3 }, crops = { [4] = "minecraft:carrots", [5] = "minecraft:beetroots" } })
F.set(0, 0, -1, { name = "minecraft:hopper" })      -- directly behind home

-- the crops' ages, in the order they stand
local function ages()
    local t = {}
    for x = 1, F.WIDTH do for z = 1, F.LENGTH do
        local b = F.get(x, -1, z)
        if b and F.RIPE[b.name] then t[#t + 1] = b.age end
    end end
    return table.concat(t, "")
end

F.chest = { { name = "minecraft:wheat_seeds", count = 64 }, { name = "minecraft:carrot", count = 64 },
            { name = "minecraft:beetroot_seeds", count = 64 }, { name = "minecraft:dirt", count = 64 } }
-- learn first with no bone meal
run("5", "6", "0")
local _, before = F.chestLine()
F.print("   crop ages after the pass: " .. ages())
-- now 250 bone meal in the chest, and a plain run
F.chest[10] = { name = "minecraft:bone_meal", count = 64 }
F.chest[11] = { name = "minecraft:bone_meal", count = 64 }
F.chest[12] = { name = "minecraft:bone_meal", count = 64 }
F.chest[13] = { name = "minecraft:bone_meal", count = 58 }
MEAL = 0
run("0")
local _, after = F.chestLine()
F.print("   bone meal applied: " .. MEAL .. ", left in chest: " .. tostring(after["minecraft:bone_meal"]))
for _, n in ipairs({ "minecraft:wheat", "minecraft:carrot", "minecraft:beetroot" }) do
    F.print(string.format("   %s in chest: %d -> %d", n, before[n] or 0, after[n] or 0))
end
F.print("   crop ages now: " .. ages())
