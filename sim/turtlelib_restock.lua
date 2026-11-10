-- sim/turtlelib_restock.lua
--
-- T.restockFrom with a mixed chest: taking water buckets that sit behind
-- other stacks, without leaving junk behind.
local PROJ = ...
package.path = PROJ .. "/turtle/?.lua;" .. PROJ .. "/lib/?.lua;" .. PROJ .. "/sim/lib/?.lua;" .. package.path
local F = require("farmworld")
local T = require("turtlelib")

F.build({ width = 5, length = 6, lanes = { 3 } })
local function show(tag)
    local t = {}
    for q = 1, F.CHEST_SIZE do
        local c = F.chest[q]
        if c then t[#t + 1] = q .. ":" .. c.count .. " " .. c.name:gsub("minecraft:", "") end
    end
    local u = {}
    for q = 1, 16 do
        local c = F.inv[q]
        if c then u[#u + 1] = q .. ":" .. c.count .. " " .. c.name:gsub("minecraft:", "") end
    end
    F.print(tag .. "  chest: " .. table.concat(t, ", ") .. "  | turtle: " .. table.concat(u, ", "))
end
F.chest = {}
F.chest[1] = { name = "minecraft:wheat_seeds", count = 32 }
F.chest[2] = { name = "minecraft:wheat", count = 40 }
F.chest[3] = { name = "minecraft:dirt", count = 64 }
F.chest[4] = { name = "minecraft:water_bucket", count = 1 }
F.chest[5] = { name = "minecraft:water_bucket", count = 1 }
F.chest[6] = { name = "minecraft:bucket", count = 4 }
F.inv = { { name = "minecraft:diamond_pickaxe", count = 1 }, { name = "minecraft:wheat_seeds", count = 63 } }
show("before")
T.restockFrom("bottom", "minecraft:water_bucket", 2, { room = 3, label = "Water buckets" })
show("after ")
