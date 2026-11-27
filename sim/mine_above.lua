-- sim/mine_above.lua
--
-- `mine` under water from above (ADR-0022's amendment of 2026-11-27): a
-- 3x3 tunnel under a low cave (two blocks tall, its floor the tunnel's
-- ceiling), with water falling through the cave into a hole in the
-- tunnel's ceiling, and a second hole in the cave floor a few blocks on.
--   A1: one source 4 blocks above the ceiling, in a pocket beside the top
--       of a shaft in the cave's roof: the water is followed up and along
--       to it, and it's filled.  Nothing is left flowing anywhere.
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

local function dig()
    run("3", "3", tostring(LENGTH), "--no-lights")
    WATERY, BOX = false, nil
    settleWater()
end

local COLUMN = { ["1,8"] = true }

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
