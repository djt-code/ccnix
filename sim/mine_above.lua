-- sim/mine_above.lua
--
-- `mine` under water from above (ADR-0022's amendment of 2026-11-27): a
-- 3x3 tunnel under a low cave (two blocks tall, its floor the tunnel's
-- ceiling), with water falling through the cave into a hole in the
-- tunnel's ceiling, and a second hole in the cave floor a few blocks on.
--   A1: one source 4 blocks above the ceiling, in a pocket beside the top
--       of a shaft in the cave's roof: the water is followed up and along
--       to it, and it's filled.  Nothing is left flowing anywhere.
--   A2: the same source 17 blocks above the ceiling, out of the trace's
--       reach: a bowl right over the hole catches the water, which stays
--       in it; none spreads over the cave floor.  5 blocks, its four sides
--       and its bottom, and here 4 more: a rim on the sides, as the cave
--       over them is open (water landing on the turtle while it stood in
--       the bowl spread round the column a block up, where the column
--       keeps it flowing, as the game does).
--   A3: the source within reach, but in a protected area: a bowl.
--   A4: a pool above, spilling down two shafts side by side (each fed by
--       two of its sources): filling one source doesn't stop it, so a
--       closed trough over both holes catches the water.
--   A5, A6: A2 and A4 under a cave 4 tall: coming back down a column
--       that's still falling, the turtle climbs down beside it, so it
--       leaves no water spread round it higher up than the bowl's rim.
-- Each prints its moves, turns, digs and blocks placed (each about 8
-- ticks in game).  Before the amendment the turtle plugged the hole: the
-- water landed on the plug, spread over the cave floor and came in
-- through the second hole.
local PROJ = ...
package.path = PROJ .. "/turtle/?.lua;" .. PROJ .. "/lib/?.lua;" .. PROJ .. "/sim/lib/?.lua;" .. package.path
local Mine = require("mineworld")
local run = Mine.runner(PROJ)
local get, set, chestAt = Mine.get, Mine.set, Mine.chestAt
local setup, stock = Mine.setup, Mine.stock
local startAt, atStart = Mine.startAt, Mine.atStart
local check, logHas, leftIn = Mine.check, Mine.logHas, Mine.leftIn
local flow, settleWater, isWater = Mine.flow, Mine.settleWater, Mine.isWater

local LENGTH = 16
local CAVE = { x0 = -3, x1 = 5, y0 = 4, y1 = 5, z0 = 3, z1 = 13 }
local SOURCE = { name = "minecraft:water", level = 0 }

-- Water in the box x 0..2, y 0..2 from z 1 to LENGTH.
local function wetTunnel()
    local n = 0
    for x = 0, 2 do for y = 0, 2 do for z = 1, LENGTH do
        if isWater(get(x, y, z)) then n = n + 1 end
    end end end
    return n
end

-- Water in the cave but for the columns `except` names ("x,z" -> true).
local function wetCave(except)
    local n = 0
    for x = CAVE.x0, CAVE.x1 do for y = CAVE.y0, CAVE.y1 do for z = CAVE.z0, CAVE.z1 do
        if isWater(get(x, y, z)) and not (except and except[x .. "," .. z]) then n = n + 1 end
    end end end
    return n
end

local function solid(x, y, z)
    local b = get(x, y, z)
    return b ~= nil and not isWater(b) and b.name ~= "minecraft:lava"
end

local function summary()
    return string.format("moves %d, turns %d, digs %d, placed %d; water flowed into the open tunnel %d times",
        Mine.moves, Mine.turns, DIGS or 0, PLACED or 0, INGRESS or 0)
end

-- The cave over the tunnel (`high` blocks tall from y=4), the hole at
-- (1,3,8) and the second one at (0,3,12); shafts up through the cave's
-- roof at each of `shafts` ({x, z}), `tall` blocks; each fed at the top
-- by what `feed(top)` puts there.  The water is let settle before the run.
local function world(high, shafts, tall, feed, protect)
    CAVE.y1 = 3 + high
    setup(stock(4, 128))
    table.insert(chestAt(0, -1, 0), { name = "minecraft:cobblestone", count = 64 })
    table.insert(chestAt(0, -1, 0), { name = "minecraft:cobblestone", count = 64 })
    for x = CAVE.x0, CAVE.x1 do for y = CAVE.y0, CAVE.y1 do for z = CAVE.z0, CAVE.z1 do set(x, y, z, nil) end end end
    set(0, 3, 12, nil)
    for _, s in ipairs(shafts) do
        set(s[1], 3, s[2], nil)
        for y = CAVE.y1 + 1, CAVE.y1 + tall do set(s[1], y, s[2], nil) end
    end
    feed(CAVE.y1 + tall + 1)
    startAt(); Mine.inv, Mine.files = {}, {}
    if protect then Mine.files[".protected"] = protect end
    EQ = { left = "advancedperipherals:chunk_controller", right = "minecraft:diamond_pickaxe" }
    FUEL, DRY, PLACED, DIGS, INGRESS = 5000, 0, 0, 0, 0
    WATERY, BOX = true, { 0, 2, 0, 2 }
    settleWater()
end

-- A pocket at the top of the shaft at (1, top-1, 8): the cell over it
-- open, and a source beside that: what falls is the source's stream.
local function pocket(top)
    set(1, top, 8, nil)
    set(2, top, 8, SOURCE)
    flow(2, top, 8)
end

-- A pool (x -3..1, z 5..11) spilling down two shafts side by side at
-- (1,8) and (1,9): each spill cell is fed by two sources.
local function pool(top)
    for x = -3, 1 do for z = 5, 11 do
        if not (x == 1 and (z == 8 or z == 9)) then set(x, top, z, SOURCE) end
    end end
    set(1, top, 8, nil); set(1, top, 9, nil)
    flow(1, top, 8); flow(1, top, 9)
end

local function dig()
    run("3", "3", tostring(LENGTH), "--no-lights")
    WATERY, BOX = false, nil
    settleWater()
end

-- The bowl over (x, 4, z): its sides and the rim on them (y=4 and 5) and
-- its bottom (the ceiling cell) solid, and water in it.
local function bowlAt(x, z, sides)
    local n = 0
    for _, d in ipairs(sides) do
        if solid(x + d[1], 4, z + d[2]) and solid(x + d[1], 5, z + d[2]) then n = n + 1 end
    end
    return n == #sides and solid(x, 3, z) and isWater(get(x, 4, z))
end
local ALL = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }
local COLUMN, COLUMNS = { ["1,8"] = true }, { ["1,8"] = true, ["1,9"] = true }

-- A1. one source, 4 blocks above the ceiling (y=7): traced and filled
world(2, { { 1, 8 } }, 1, pocket)
check("A1: the water falls through the cave into the hole in the ceiling before it's dug",
    isWater(get(1, 3, 8)) and isWater(get(1, 4, 8)) and wetCave(COLUMN) == 0)
dig()
check("A1: finished", logHas("^Done"))
check("A1: followed the water up and along to its source and filled it",
    logHas("^Traced the water at %(1,3,8%) to its source 5 blocks up and 1 across: filled%.") and solid(2, 7, 8), summary())
check("A1: the tunnel is dry", wetTunnel() == 0, wetTunnel() .. " blocks of water")
check("A1: no water left in the cave (none spread over its floor)", wetCave() == 0, wetCave() .. " blocks")
check("A1: no water got into the tunnel past the block being dug", INGRESS <= 3, INGRESS .. " times")
check("A1: dug to the end", leftIn(0, 2, 0, 2, 1, LENGTH) == 0, leftIn(0, 2, 0, 2, 1, LENGTH) .. " blocks left")
check("A1: back at the start", atStart())

-- A2 (A5: under a cave 4 tall). the source 20 blocks above the ceiling:
-- the trace turns back; a bowl
local function outOfReach(name, high)
    world(high, { { 1, 8 } }, 16 - high, pocket)
    dig()
    check(name .. ": finished", logHas("^Done"))
    check(name .. ": couldn't reach the source, and said so",
        logHas("^Couldn't trace the water at %(1,3,8%): its source is more than 16 blocks out%."))
    check(name .. ": a bowl over the hole: 4 sides, a rim on them and the bottom",
        logHas("^Caught the water falling in at %(1,3,8%): a bowl of 9 blocks above the ceiling%.") and bowlAt(1, 8, ALL), summary())
    check(name .. ": the tunnel is dry", wetTunnel() == 0, wetTunnel() .. " blocks of water")
    check(name .. ": the water stays in the bowl: none on the cave floor round it, nor spread round the column",
        wetCave(COLUMN) == 0, wetCave(COLUMN) .. " blocks")
    check(name .. ": back at the start", atStart())
end
outOfReach("A2", 2)

-- A3. A1's source in a protected area (another program's): not gone into; a bowl
world(2, { { 1, 8 } }, 1, pocket, "1 7 8 2 7 8 a farm\n")
dig()
check("A3: finished", logHas("^Done"))
check("A3: didn't go into the protected area: the source is still there, and it said why",
    isWater(get(2, 7, 8)) and get(2, 7, 8).level == 0
    and logHas("^Couldn't trace the water at %(1,3,8%): it comes through the protected area a farm%."))
check("A3: a bowl over the hole", logHas("^Caught the water falling in at %(1,3,8%): a bowl of 9 blocks")
    and bowlAt(1, 8, ALL), summary())
check("A3: the tunnel is dry", wetTunnel() == 0, wetTunnel() .. " blocks of water")
check("A3: the water stays in the bowl", wetCave(COLUMN) == 0, wetCave(COLUMN) .. " blocks")
check("A3: back at the start", atStart())

-- A4 (A6: under a cave 4 tall). the pool spilling down two shafts: a trough
local function waterfall(name, high)
    world(high, { { 1, 8 }, { 1, 9 } }, 1, pool)
    check(name .. ": two columns fall into two holes side by side",
        isWater(get(1, 3, 8)) and isWater(get(1, 3, 9)) and (get(1, 4, 8) or {}).level == 8)
    dig()
    check(name .. ": finished", logHas("^Done"))
    check(name .. ": filling a source didn't stop it, so a trough over both holes",
        logHas("^Filled the source of the water at %(1,3,%d+%), but it's still coming %(more than one source%)%.")
        and logHas("^Caught the water falling in at %(1,3,%d+%): a trough over 2 columns, 14 blocks above the ceiling%.")
        and bowlAt(1, 8, { { 1, 0 }, { -1, 0 }, { 0, -1 } }) and bowlAt(1, 9, { { 1, 0 }, { -1, 0 }, { 0, 1 } }), summary())
    check(name .. ": the tunnel is dry", wetTunnel() == 0, wetTunnel() .. " blocks of water")
    check(name .. ": the water stays in the trough", wetCave(COLUMNS) == 0, wetCave(COLUMNS) .. " blocks")
    check(name .. ": back at the start", atStart())
end
waterfall("A4", 2)
outOfReach("A5", 4)
waterfall("A6", 4)
