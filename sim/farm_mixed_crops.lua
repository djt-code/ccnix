-- sim/farm_mixed_crops.lua
--
-- A mixed farm (wheat, carrots, potatoes, beetroot): learning the crop
-- layout, a bare tile and a hole, and a wrong crop planted on a tile.
local PROJ = ...
package.path = PROJ .. "/turtle/?.lua;" .. PROJ .. "/lib/?.lua;" .. PROJ .. "/sim/lib/?.lua;" .. package.path
local F = require("farmworld")
local run = F.runner(PROJ)

-- M1. learn a mixed farm: a bare farmland tile in the carrot strip, a hole
--     in a wheat strip, a potato planted where the plan says wheat
F.build({ width = 5, length = 6, lanes = { 3 }, crops = { [4] = "minecraft:carrots", [5] = "minecraft:beetroots" } })
F.stock({ carrots = true, water = 1 })
F.set(4, -1, 3, nil)                                                  -- bare farmland, carrot strip
F.set(1, -2, 5, nil); F.set(1, -1, 5, nil); F.set(1, -3, 5, nil)      -- hole in a wheat strip
F.show("before learn")
run("5", "6", "0")
F.print("   map crops: " .. ((F.files["farm.map"] or ""):gsub("\n", " "):gsub("minecraft:", "")))
F.show("after learn + pass")
-- M2. everything ripe; a potato ripe on a wheat tile (wrong crop)
F.ripen()
F.set(2, -1, 2, { name = "minecraft:potatoes", age = 7 })
F.stock({ carrots = true, water = 1 })
run("0")
F.show("after M2")
F.print("   chest: " .. F.chestLine())
