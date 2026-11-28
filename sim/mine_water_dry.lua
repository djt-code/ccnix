-- sim/mine_water_dry.lua
--
-- `mine` out of open water into dry rock (ADR-0022), as the field had it:
-- a 10x10 tunnel whose second segment runs along a lake on its left that
-- ends a block past the segment's end, so the segment ends under water
-- and leaves an end cap; the third segment starts at that cap and is dry
-- rock past it.  The third segment should look before it builds a
-- bulkhead (a scan, not the end cap alone), work as open water only what
-- is water (not the rock a scan from a corner can't reach, nor the column
-- its own shell dug), and go back to digging as ever once it's through;
-- and a full inventory should send it home once, not on every block (open
-- water's bulk blocks kept aboard, in part stacks of many kinds, used to
-- leave it no room after unloading: the field saw a trip a block).
-- D1 with a scanner, D2 without, D3 with a scanner in ground of many
-- kinds (MIXED_ROCK), where the trip a block showed.
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

-- Each line the run prints, as it prints it, and the blocks dug before
-- each trip for room.
local lines, tripDigs = {}, {}
ONPRINT = function(line)
    lines[#lines + 1] = line
    if line:find("^Inventory nearly full") then tripDigs[#tripDigs + 1] = DIGS or 0 end
end
local function count(pattern, from)
    local n = 0
    for i = from or 1, #lines do
        if lines[i]:find(pattern) then n = n + 1 end
    end
    return n
end
local function first(pattern)
    for i, l in ipairs(lines) do
        if l:find(pattern) then return i end
    end
end
-- The fewest blocks dug between two trips for room.
local function leastBetween()
    local least
    for i = 2, #tripDigs do
        local d = tripDigs[i] - tripDigs[i - 1]
        if not least or d < least then least = d end
    end
    return least or math.huge
end

-- The lake: x=-5..3 (the tunnel's left four columns and the rock left of
-- it), every row, z=20..33; the tunnel 48 long, spacing 16, torches
-- aboard, cobblestone at the start.
local function lakeRun(scanner, mixed)
    local kit = stock(6, 256, 128)
    if scanner then table.insert(kit, 1, { name = SCANNER, count = 1 }) end
    setup(kit)
    local c = chestAt(0, -1, 0)
    for _ = 1, 12 do table.insert(c, { name = "minecraft:cobblestone", count = 64 }) end
    for x = -5, 3 do for y = -2, H + 1 do for z = 20, 33 do
        set(x, y, z, { name = "minecraft:water", level = 0 })
    end end end
    startAt(); Mine.inv, Mine.files = {}, {}
    EQ = { left = "advancedperipherals:chunk_controller", right = "minecraft:diamond_pickaxe" }
    FUEL, DRY, PLACED = 20000, 0, 0
    lines, tripDigs = {}, {}
    MIXED_ROCK = mixed
    WATERY = true
    settleWater()
    run(tostring(W), tostring(H), "48", "--spacing", "16")
    WATERY, MIXED_ROCK = false, nil
end

-- Open-water chunks past the lake (z > 35).
local function lateChunks()
    local n = 0
    for _, l in ipairs(lines) do
        local z = tonumber(l:match("^Open water at z=(%d+)"))
        if z and z > 35 then n = n + 1 end
    end
    return n
end

local function summary()
    return "moves " .. Mine.moves .. ", turns " .. Mine.turns .. ", digs " .. (DIGS or 0) .. ", placed " .. (PLACED or 0)
end

-- D1. with a scanner
lakeRun(true)
local seg3 = first("^Segment z=33%.%.48") or #lines + 1
check("D1: finished", logHas("^Done"), summary())
check("D1: the second segment ended under water: an end cap", logHas("^Open water at z=%d+%.%.32"))
check("D1: the third segment: a scan says no bulkhead (the end cap alone doesn't)",
    count("^Bulkhead across", seg3) == 0 and count("^No bulkhead: %d+ of the %d+ cells ahead a scan saw", seg3) == 1)
check("D1: no open water past the lake (z>35): dry rock dug as ever", lateChunks() == 0, lateChunks() .. " chunks")
check("D1: the tunnel is dry", wetIn(1, 48) == 0, wetIn(1, 48) .. " blocks of water")
check("D1: dug to the end", leftIn(0, W - 1, 0, H - 1, 1, 48) == 0, leftIn(0, W - 1, 0, H - 1, 1, 48) .. " blocks left")
local full = count("^Inventory nearly full")
check("D1: no more than 12 trips for room", full <= 12, full .. " trips")
check("D1: at least 64 blocks dug between two trips for room", leastBetween() >= 64, leastBetween() .. " at least")
check("D1: back at the start", atStart())

-- D2. without a scanner: the probe finds the lake; past it, the fill's
--     lanes going through the column the shell dug isn't water met, so
--     open water ends where the lake does
lakeRun(false)
check("D2: finished", logHas("^Done"), summary())
check("D2: no open water past the lake (z>35): dry rock dug as ever", lateChunks() == 0, lateChunks() .. " chunks")
check("D2: the tunnel is dry", wetIn(1, 48) == 0, wetIn(1, 48) .. " blocks of water")
check("D2: dug to the end", leftIn(0, W - 1, 0, H - 1, 1, 48) == 0, leftIn(0, W - 1, 0, H - 1, 1, 48) .. " blocks left")
full = count("^Inventory nearly full")
check("D2: no more than 12 trips for room", full <= 12, full .. " trips")
check("D2: at least 64 blocks dug between two trips for room", leastBetween() >= 64, leastBetween() .. " at least")
check("D2: back at the start", atStart())

-- D3. D1 in ground of many kinds: trips for room in the wet segments no
--     more often than in the dry first one (about one every 40 blocks
--     there; the trip a block made over 900)
lakeRun(true, true)
local seg2 = first("^Segment z=17%.%.32") or #lines + 1
local dry, wet = count("^Inventory nearly full", 1) - count("^Inventory nearly full", seg2), count("^Inventory nearly full", seg2)
check("D3: finished", logHas("^Done"), summary())
check("D3: the tunnel is dry", wetIn(1, 48) == 0, wetIn(1, 48) .. " blocks of water")
check("D3: dug to the end", leftIn(0, W - 1, 0, H - 1, 1, 48) == 0, leftIn(0, W - 1, 0, H - 1, 1, 48) .. " blocks left")
check("D3: trips for room in the two wet segments no more than 3 times the dry one's",
    wet <= 3 * dry, wet .. " in segments 2-3, " .. dry .. " in segment 1")
check("D3: back at the start", atStart())
