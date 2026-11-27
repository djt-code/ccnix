-- sim/mine_water.lua
--
-- `mine` through open water (ADR-0022): a 5x5 tunnel whose second segment
-- runs into a lake (water all round it, on past where the tunnel ends):
-- the shell first, then the water inside filled and dug out dry, an end
-- cap left where the segment ends under water, and a bulkhead keeping the
-- tunnel behind the home dry meanwhile.  Then the same tunnel carried on
-- through the end cap; and a tunnel with water under its bottom half only
-- (a scanner on board), shelled only there.  Each prints its moves, turns
-- and blocks placed.
local PROJ = ...
package.path = PROJ .. "/turtle/?.lua;" .. PROJ .. "/lib/?.lua;" .. PROJ .. "/sim/lib/?.lua;" .. package.path
local Mine = require("mineworld")
local run = Mine.runner(PROJ)
local P = Mine.P
local get, set, chestAt = Mine.get, Mine.set, Mine.chestAt
local setup, stock = Mine.setup, Mine.stock
local startAt, atStart = Mine.startAt, Mine.atStart
local check, logHas, leftIn = Mine.check, Mine.logHas, Mine.leftIn
local flow, settleWater, isWater = Mine.flow, Mine.settleWater, Mine.isWater

local W, H = 5, 5

-- Water in the box x 0..W-1, y 0..H-1 from z1 to z2.
local function wetIn(z1, z2)
    local n = 0
    for x = 0, W - 1 do for y = 0, H - 1 do for z = z1, z2 do
        if isWater(get(x, y, z)) then n = n + 1 end
    end end end
    return n
end

-- Water touching open space anywhere near the tunnel (not sealed off).
local function wetOpen(z2)
    local n = 0
    for x = -3, W + 2 do for y = -3, H + 2 do for z = 1, z2 do
        if isWater(get(x, y, z)) then
            for _, d in ipairs({ { 1, 0, 0 }, { -1, 0, 0 }, { 0, 1, 0 }, { 0, -1, 0 }, { 0, 0, 1 }, { 0, 0, -1 } }) do
                if not get(x + d[1], y + d[2], z + d[3]) then n = n + 1 end
            end
        end
    end end end
    return n
end

-- A body of water sources x0..x1, y0..y1, z0..z1, settled.
local function lake(x0, x1, y0, y1, z0, z1)
    for x = x0, x1 do for y = y0, y1 do for z = z0, z1 do
        set(x, y, z, { name = "minecraft:water", level = 0 })
    end end end
end

-- The start's bottom chest full of cobblestone (n stacks).
local function bulkAtStart(n)
    local c = chestAt(0, -1, 0)
    for _ = 1, n do table.insert(c, { name = "minecraft:cobblestone", count = 64 }) end
end

-- Watch the tunnel behind z (the box up to z): the most water it held at once.
local function watchBehind(z)
    local most = 0
    ONMOVE = function()
        local n = wetIn(1, z)
        if n > most then most = n end
    end
    return function() ONMOVE = nil; return most end
end

local function summary()
    -- (each of these takes the turtle a moment in game: their sum is the time)
    return string.format("moves %d, turns %d, digs %d, placed %d", Mine.moves, Mine.turns, DIGS or 0, PLACED or 0)
end

-- W1. into a lake: the second segment (z=17..32) runs into water from
--     z=20, which goes on past the tunnel's end (z=40), round it on every
--     side; the first segment is dry rock
setup(stock(4, 128))
bulkAtStart(20)
lake(-2, W + 1, -2, H + 1, 20, 40)
startAt(); Mine.inv, Mine.files = {}, {}
EQ = { left = "advancedperipherals:chunk_controller", right = "minecraft:diamond_pickaxe" }
FUEL, DRY, PLACED = 20000, 0, 0
WATERY = true
settleWater()
local behind = watchBehind(15)
run(tostring(W), tostring(H), "32", "--spacing", "16", "--no-lights")
local most = behind()
WATERY = false
check("W1: finished", logHas("^Done"))
check("W1: went into open-water mode", logHas("Open water at z="), summary())
check("W1: the tunnel is dry", wetIn(1, 32) == 0, wetIn(1, 32) .. " blocks of water")
check("W1: no water touching open space (sealed off)", wetOpen(32) == 0, wetOpen(32) .. " open faces")
check("W1: dug to the end", leftIn(0, W - 1, 0, H - 1, 1, 32) == 0, leftIn(0, W - 1, 0, H - 1, 1, 32) .. " blocks left")
local capped = 0
for x = 0, W - 1 do for y = 0, H - 1 do
    local b = get(x, y, 33)
    if b and not isWater(b) then capped = capped + 1 end
end end
check("W1: an end cap across the tunnel past its end (z=33)", capped == W * H, capped .. " of " .. W * H .. " blocks")
check("W1: the tunnel behind home 1 never got water in it", most == 0, most .. " blocks at most")
check("W1: a bulkhead (the lake fills the tunnel ahead, more than half of it)", logHas("^Bulkhead across the tunnel at z=15"))
check("W1: no more than 6000 moves and 3000 turns", Mine.moves < 6000 and Mine.turns < 3000, summary())
check("W1: back at the start", atStart())

-- W2. the same tunnel asked for again, 48 long: carried on from home 1,
--     home 2 built at z=32, then on through the end cap into the lake's
--     last 8 blocks and on into rock
WATERY, PLACED = true, 0
behind = watchBehind(31)
run(tostring(W), tostring(H), "48", "--no-lights", "--new")    -- (the same tunnel, longer: carried on)
most = behind()
WATERY = false
check("W2: finished", logHas("^Done"))
check("W2: started the segment past the end cap in open-water mode", logHas("Open water at z=33"), summary())
check("W2: the tunnel is dry", wetIn(1, 48) == 0, wetIn(1, 48) .. " blocks of water")
check("W2: no water touching open space (sealed off)", wetOpen(48) == 0, wetOpen(48) .. " open faces")
check("W2: dug to the end, the end cap with it", leftIn(0, W - 1, 0, H - 1, 1, 48) == 0,
    leftIn(0, W - 1, 0, H - 1, 1, 48) .. " blocks left")
check("W2: the tunnel behind home 2 never got water in it", most == 0, most .. " blocks at most")

-- W3. water under the bottom half only (y=-3..1: the floor and the bottom
--     two rows) for z=20..30, a scanner on board: the shell goes on the
--     floor and the walls' bottom rows (and the row above them), not on
--     the ceiling or the top of the walls
setup({ { name = SCANNER, count = 1 }, { name = "minecraft:chest", count = 4 }, { name = "minecraft:coal", count = 128 } })
bulkAtStart(20)
lake(-2, W + 1, -3, 1, 20, 30)
startAt(); Mine.inv, Mine.files = {}, {}
EQ = { left = "advancedperipherals:chunk_controller", right = "minecraft:diamond_pickaxe" }
FUEL, DRY, PLACED = 20000, 0, 0
WATERY = true
settleWater()
run(tostring(W), tostring(H), "32", "--spacing", "16", "--no-lights")
WATERY = false
check("W3: finished", logHas("^Done"))
check("W3: shelled only the bottom of the tunnel", logHas("Open water at z=%d+%.%.%d+: rows 0 to 2"), summary())
check("W3: no bulkhead (the tunnel ahead is under half water), and it says why",
    not logHas("^Bulkhead across") and logHas("^No bulkhead: %d+ of the %d+ cells ahead a scan saw are water or lava %(%d+%%: it takes more than half%)"))
check("W3: the tunnel is dry", wetIn(1, 32) == 0, wetIn(1, 32) .. " blocks of water")
check("W3: no water touching open space (sealed off)", wetOpen(32) == 0, wetOpen(32) .. " open faces")
check("W3: dug to the end", leftIn(0, W - 1, 0, H - 1, 1, 32) == 0, leftIn(0, W - 1, 0, H - 1, 1, 32) .. " blocks left")
check("W3: back at the start", atStart())

-- W4. W3's water with no scanner: the water it meets doesn't reach the
--     tunnel's top row: no bulkhead
setup({ { name = "minecraft:chest", count = 4 }, { name = "minecraft:coal", count = 128 } })
bulkAtStart(20)
lake(-2, W + 1, -3, 1, 20, 30)
startAt(); Mine.inv, Mine.files = {}, {}
EQ = { left = "advancedperipherals:chunk_controller", right = "minecraft:diamond_pickaxe" }
FUEL, DRY, PLACED = 20000, 0, 0
WATERY = true
settleWater()
run(tostring(W), tostring(H), "32", "--spacing", "16", "--no-lights")
WATERY = false
check("W4: finished", logHas("^Done"))
check("W4: no bulkhead: the water it met is all below the top row",
    not logHas("^Bulkhead across") and logHas("^No bulkhead: the water it met is all below the tunnel's top row"), summary())
check("W4: the tunnel is dry", wetIn(1, 32) == 0, wetIn(1, 32) .. " blocks of water")
check("W4: dug to the end", leftIn(0, W - 1, 0, H - 1, 1, 32) == 0, leftIn(0, W - 1, 0, H - 1, 1, 32) .. " blocks left")
check("W4: back at the start", atStart())
