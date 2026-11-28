-- sim/mine_water_dry.lua
--
-- `mine` out of open water into dry rock (ADR-0022), as the field had it:
-- a 10x10 tunnel with a scanner whose second segment runs along a lake on
-- its left that ends a block past the segment's end, so the segment ends
-- under water and leaves an end cap; the third segment starts at that cap
-- and is dry rock past it.  The third segment should look before it
-- builds a bulkhead (a scan, not the end cap alone), work as open water
-- only what is water (not the rock a scan from a corner can't reach), and
-- go back to digging as ever once it's through; and a full inventory
-- should send it home once, not on every block (open water's bulk blocks
-- kept aboard, in part stacks of many kinds, used to leave it with no
-- room after unloading).
local PROJ = ...
package.path = PROJ .. "/turtle/?.lua;" .. PROJ .. "/lib/?.lua;" .. PROJ .. "/sim/lib/?.lua;" .. package.path
local Mine = require("mineworld")
local run = Mine.runner(PROJ)
local get, set, chestAt = Mine.get, Mine.set, Mine.chestAt
local setup, stock = Mine.setup, Mine.stock
local startAt, atStart = Mine.startAt, Mine.atStart
local check, logHas, leftIn = Mine.check, Mine.logHas, Mine.leftIn
local settleWater, isWater = Mine.settleWater, Mine.isWater

local W, H = 10, 10

local function wetIn(z1, z2)
    local n = 0
    for x = 0, W - 1 do for y = 0, H - 1 do for z = z1, z2 do
        if isWater(get(x, y, z)) then n = n + 1 end
    end end end
    return n
end

-- Each line the run prints, as it prints it.
local lines = {}
ONPRINT = function(line) lines[#lines + 1] = line end
local function count(pattern, from)
    local n = 0
    for i = from or 1, #lines do
        if lines[i]:find(pattern) then n = n + 1 end
    end
    return n
end
-- The first line that matches, its index.
local function first(pattern)
    for i, l in ipairs(lines) do
        if l:find(pattern) then return i end
    end
end

-- D1. the lake: x=-5..3 (the tunnel's left four columns and the rock left
--     of it), every row, z=20..33; the tunnel 48 long, spacing 16, a
--     scanner and torches aboard, cobblestone at the start
local kit = stock(6, 256, 128)
table.insert(kit, 1, { name = SCANNER, count = 1 })
setup(kit)
do
    local c = chestAt(0, -1, 0)
    for _ = 1, 12 do table.insert(c, { name = "minecraft:cobblestone", count = 64 }) end
end
for x = -5, 3 do for y = -2, H + 1 do for z = 20, 33 do
    set(x, y, z, { name = "minecraft:water", level = 0 })
end end end
startAt(); Mine.inv, Mine.files = {}, {}
EQ = { left = "advancedperipherals:chunk_controller", right = "minecraft:diamond_pickaxe" }
FUEL, DRY, PLACED = 20000, 0, 0
WATERY = true
settleWater()
run(tostring(W), tostring(H), "48", "--spacing", "16")
WATERY = false
local seg3 = first("^Segment z=33%.%.48") or #lines + 1
check("D1: finished", logHas("^Done"), "moves " .. Mine.moves .. ", turns " .. Mine.turns .. ", digs " .. (DIGS or 0)
    .. ", placed " .. (PLACED or 0))
check("D1: the second segment ended under water: an end cap", logHas("^Open water at z=%d+%.%.32"))
check("D1: the third segment: no bulkhead before a scan says the tunnel ahead is water",
    count("^Bulkhead across the tunnel at z=31", seg3) == 0)
local late = 0
for i = seg3, #lines do
    local z = tonumber(lines[i]:match("^Open water at z=(%d+)"))
    if z and z > 35 then late = late + 1 end
end
check("D1: no open water past the lake (z>35): dry rock dug as ever", late == 0, late .. " chunks")
check("D1: the tunnel is dry", wetIn(1, 48) == 0, wetIn(1, 48) .. " blocks of water")
check("D1: dug to the end", leftIn(0, W - 1, 0, H - 1, 1, 48) == 0, leftIn(0, W - 1, 0, H - 1, 1, 48) .. " blocks left")
local full = count("^Inventory nearly full")
check("D1: no more than 12 trips for room", full <= 12, full .. " trips")
check("D1: back at the start", atStart())

-- D2. the same without a scanner: the probe finds the lake; past it, the
--     fill's lanes going through the column the shell dug isn't water met,
--     so open water ends where the lake does
setup(stock(6, 256, 128))
do
    local c = chestAt(0, -1, 0)
    for _ = 1, 12 do table.insert(c, { name = "minecraft:cobblestone", count = 64 }) end
end
for x = -5, 3 do for y = -2, H + 1 do for z = 20, 33 do
    set(x, y, z, { name = "minecraft:water", level = 0 })
end end end
startAt(); Mine.inv, Mine.files = {}, {}
EQ = { left = "advancedperipherals:chunk_controller", right = "minecraft:diamond_pickaxe" }
FUEL, DRY, PLACED = 20000, 0, 0
lines = {}
WATERY = true
settleWater()
run(tostring(W), tostring(H), "48", "--spacing", "16")
WATERY = false
seg3 = first("^Segment z=33%.%.48") or #lines + 1
check("D2: finished", logHas("^Done"), "moves " .. Mine.moves .. ", turns " .. Mine.turns .. ", digs " .. (DIGS or 0)
    .. ", placed " .. (PLACED or 0))
late = 0
for i = 1, #lines do
    local z = tonumber(lines[i]:match("^Open water at z=(%d+)"))
    if z and z > 35 then late = late + 1 end
end
check("D2: no open water past the lake (z>35): dry rock dug as ever", late == 0, late .. " chunks")
check("D2: the tunnel is dry", wetIn(1, 48) == 0, wetIn(1, 48) .. " blocks of water")
check("D2: dug to the end", leftIn(0, W - 1, 0, H - 1, 1, 48) == 0, leftIn(0, W - 1, 0, H - 1, 1, 48) .. " blocks left")
full = count("^Inventory nearly full")
check("D2: no more than 12 trips for room", full <= 12, full .. " trips")
check("D2: back at the start", atStart())
