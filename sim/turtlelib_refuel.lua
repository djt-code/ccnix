-- sim/turtlelib_refuel.lua
--
-- T.refuelTo and T.totalFuelAvailable with wood on board: planks, logs,
-- sticks, chests and a crafting table all burn in a furnace (and in a
-- turtle), but they're what chests and torches are crafted from, so only
-- what T.fuel lists is burnt, or counted as fuel.
local PROJ = ...
package.path = PROJ .. "/turtle/?.lua;" .. PROJ .. "/lib/?.lua;" .. PROJ .. "/sim/lib/?.lua;" .. package.path
local Mine = require("mineworld")
local T = require("turtlelib")
local check = Mine.check

Mine.setup({})
Mine.inv = {
    { name = "minecraft:oak_planks", count = 20 }, { name = "minecraft:chest", count = 4 },
    { name = "minecraft:oak_log", count = 8 }, { name = "minecraft:stick", count = 6 },
    { name = "minecraft:crafting_table", count = 1 }, { name = "minecraft:coal", count = 3 },
}
Mine.sel = 1
FUEL = 10
check("counts only the coal as fuel, and burns nothing to count it",
    T.totalFuelAvailable() == 10 + 3 * 80 and next(BURNT) == nil, tostring(T.totalFuelAvailable()))
T.refuelTo(1000)
local burnt = {}
for name, n in pairs(BURNT) do burnt[#burnt + 1] = n .. " " .. name end
check("refuelling burns the coal, none of the wood", FUEL == 250 and BURNT["minecraft:coal"] == 3 and #burnt == 1,
    "fuel " .. FUEL .. "; burnt " .. table.concat(burnt, ", "))
local function n(s) return Mine.inv[s] and Mine.inv[s].count or 0 end
check("the wood and chests are all still there", n(1) == 20 and n(2) == 4 and n(3) == 8 and n(4) == 6 and n(5) == 1)
