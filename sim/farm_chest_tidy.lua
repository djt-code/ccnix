-- sim/farm_chest_tidy.lua
--
-- The farm chest is tidied at every chest visit: part stacks scattered
-- through it are merged, then it's sorted against the last slot, each
-- item's stacks together and like items side by side, the empty slots
-- first.  A chest already in order takes no moves; a full one is sorted
-- with the turtle holding a stack meanwhile.
local PROJ = ...
package.path = PROJ .. "/turtle/?.lua;" .. PROJ .. "/lib/?.lua;" .. PROJ .. "/sim/lib/?.lua;" .. package.path
local F = require("farmworld")
local run = F.runner(PROJ)

F.build({ width = 5, length = 6, lanes = { 3 }, crops = { [4] = "minecraft:carrots", [5] = "minecraft:beetroots" } })
F.set(0, 0, -1, { name = "minecraft:hopper" })      -- directly behind home

local function slots()
    local t = {}
    for s = 1, F.CHEST_SIZE do
        local c = F.chest[s]
        if c then t[#t + 1] = s .. ":" .. c.count .. " " .. c.name:gsub("minecraft:", "") end
    end
    return table.concat(t, ", ")
end
-- Sorted: each item's stacks side by side, items grouped by kind (the last
-- word of the id), packed against the last slot: the empty slots first.
local function kind(n) return n:match("([^_:]+)$") end
local function sorted()
    local last, seen, started = nil, {}, false
    for s = 1, F.CHEST_SIZE do
        local c = F.chest[s]
        if not c then
            if started then return "an empty slot after the first stack (slot " .. s .. ")" end
        else
            started = true
            if c.name ~= last then
                if seen[c.name] then return c.name .. " split up (slot " .. s .. ")" end
                if last and (kind(last) > kind(c.name) or (kind(last) == kind(c.name) and last > c.name)) then
                    return "out of order at slot " .. s
                end
                seen[c.name], last = true, c.name
            end
        end
    end
    return "yes"
end

F.chest = {}
F.chest[1] = { name = "minecraft:bone_meal", count = 7 }
F.chest[2] = { name = "minecraft:wheat_seeds", count = 64 }
F.chest[3] = { name = "minecraft:wheat", count = 30 }
F.chest[4] = { name = "minecraft:bone_meal", count = 12 }
F.chest[6] = { name = "minecraft:wheat_seeds", count = 20 }
F.chest[7] = { name = "minecraft:wheat", count = 40 }
F.chest[9] = { name = "minecraft:bone_meal", count = 3 }
F.chest[10] = { name = "minecraft:dirt", count = 64 }
F.chest[12] = { name = "minecraft:wheat_seeds", count = 15 }
F.chest[14] = { name = "minecraft:bone_meal", count = 60 }
F.chest[15] = { name = "minecraft:carrot", count = 40 }
F.chest[16] = { name = "minecraft:beetroot_seeds", count = 40 }
F.print("chest before: " .. slots())
run("5", "6", "0")
F.print("   chest after:  " .. slots())
F.print("   sorted: " .. sorted() .. "  (pushes: " .. tostring(PUSHES) .. ")")
-- the next visit finds it in order already: no moves to sort it
PUSHES = 0
run("0")
F.print("   chest after a second run:  " .. slots())
F.print("   sorted: " .. sorted() .. "  (pushes: " .. tostring(PUSHES) .. ")")
-- a full chest, out of order: merged where it can be, but no room to sort
F.chest = {}
for s = 1, F.CHEST_SIZE do
    F.chest[s] = { name = s % 2 == 0 and "minecraft:wheat" or "minecraft:carrot", count = 64 }
end
F.chest[27] = { name = "minecraft:wheat_seeds", count = 64 }
PUSHES = 0
run("0")
F.print("   full chest after:  " .. slots())
F.print("   sorted: " .. sorted() .. "  (pushes: " .. tostring(PUSHES) .. ")")
