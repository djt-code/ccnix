-- sim/farm_repair.lua
--
-- Learn a 5x6 wheat farm with a lane, then damage it in different ways:
-- holes, dry and flowing lane tiles, dirt in the lane, a block over the
-- lane, untilled dirt.  Checks what a farming pass fixes by itself, what
-- starts a full repair pass, and what `farm repair` rebuilds.  (Water
-- follows the infinite-source rule: a dry lane tile between two sources
-- comes back by itself; one at the lane's end doesn't.)
local PROJ = ...
package.path = PROJ .. "/turtle/?.lua;" .. PROJ .. "/lib/?.lua;" .. PROJ .. "/sim/lib/?.lua;" .. package.path
local F = require("farmworld")
local run = F.runner(PROJ)
local LANE_X = 3

-- 1. learn on a farm that already has a hole in a strip and a dry lane tile
F.build({ width = 5, length = 6, lanes = { LANE_X } })
F.stock()
F.set(2, -2, 3, nil); F.set(2, -3, 3, nil); F.set(2, -1, 3, nil)     -- land hole, no floor
F.set(LANE_X, -2, 4, nil)                                             -- dry lane, floor intact
F.show("before learn")
run("5", "6", "0")
F.print("   map: " .. (F.files["farm.map"] or ""):gsub("\n", " "))
F.show("after learn + first pass")

-- 2. damage it again and run a plain farm pass
F.set(4, -2, 5, nil); F.set(4, -1, 5, nil)                            -- land gone, floor left
F.set(LANE_X, -2, 2, nil); F.set(LANE_X, -3, 2, nil)                  -- lane hole, no floor
F.ripen()
F.stock()
run("0")
F.show("after second run")

-- 3. repair mode on an intact farm
F.stock()
run("repair")

-- 3b. untilled dirt in a strip and a dry lane tile: the farming pass tills
--     and plants the dirt, ignores the lane, and starts no full repair
F.set(1, -2, 2, { name = "minecraft:dirt" }); F.set(1, -1, 2, nil)
F.set(LANE_X, -2, 6, nil)
F.stock()
run("0")
F.show("after 3b")

-- 4. the turtle brings its own (empty) buckets, a pickaxe and junk; the chest
--    has no water buckets.  Lane damage: dirt in the lane, flowing water,
--    a block sitting above the lane.
F.stock({ water = 0 })
F.inv = { { name = "minecraft:bucket", count = 1 }, { name = "minecraft:bucket", count = 1 },
          { name = "minecraft:diamond_pickaxe", count = 1 }, { name = "minecraft:torch", count = 5 },
          { name = "minecraft:coal", count = 8 }, { name = "minecraft:cobblestone", count = 20 } }
F.set(LANE_X, -2, 2, { name = "minecraft:dirt" })
F.set(LANE_X, -2, 5, { name = "minecraft:water", level = 3 })
F.set(LANE_X, -1, 4, { name = "minecraft:dirt" })
F.show("before run 4")
run("repair")
F.show("after run 4")
local lv = {}
for z = 1, F.LENGTH do
    local b = F.get(LANE_X, -2, z)
    lv[#lv + 1] = b and (b.name:gsub("minecraft:", "") .. (b.level and (":" .. b.level) or ":src")) or "air"
end
F.print("   lane: " .. table.concat(lv, " "))
F.print("   crop level above lane z=4: " .. tostring(F.get(LANE_X, -1, 4) and F.get(LANE_X, -1, 4).name))
F.print("   chest: " .. F.chestLine())
F.print("   equipped: left=" .. tostring(EQ.left) .. " right=" .. tostring(EQ.right))
