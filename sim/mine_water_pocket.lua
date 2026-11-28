-- sim/mine_water_pocket.lua
--
-- `mine` meeting a pocket of water inside the tunnel's box, mid-segment,
-- as the field had it: a 10x10 tunnel, 32 long (two segments), a 3x3x3
-- pocket of water sources in the second segment's box.  A lane digs into
-- it, the water it meets is sealed and dried, and that counts as open
-- water met (six sources close together).  With a scanner, a scan from
-- there shows nothing much is left: it carries on with that lane, sealing
-- as it goes (it used to go home, work the segment as open water from its
-- start and dig every lane again from the first).  Without one, the probe
-- says under half: the same.  Each is judged against the same tunnel dug
-- with no pocket.
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

local function tunnel(scanner, pocket)
    local kit = stock(6, 256, 128)
    if scanner then table.insert(kit, 1, { name = SCANNER, count = 1 }) end
    setup(kit)
    local c = chestAt(0, -1, 0)
    for _ = 1, 8 do table.insert(c, { name = "minecraft:cobblestone", count = 64 }) end
    if pocket then
        for x = 5, 7 do for y = 4, 6 do for z = 22, 24 do
            set(x, y, z, { name = "minecraft:water", level = 0 })
        end end end
    end
    startAt(); Mine.inv, Mine.files = {}, {}
    EQ = { left = "advancedperipherals:chunk_controller", right = "minecraft:diamond_pickaxe" }
    FUEL, DRY, PLACED = 20000, 0, 0
    WATERY = true
    settleWater()
    run(tostring(W), tostring(H), "32", "--spacing", "16")
    WATERY = false
    return Mine.moves
end

for _, v in ipairs({ { "P1", true }, { "P2", false } }) do
    local id, scanner = v[1], v[2]
    local dry = tunnel(scanner, false)
    local moves = tunnel(scanner, true)
    check(id .. ": finished", logHas("^Done"), moves .. " moves, " .. dry .. " with no pocket")
    if scanner then
        check(id .. ": a scan from where it met the water says to tunnel on",
            logHas("^Water at z=%d+: a scan from here sees %d+%% of the tunnel ahead and its sides wet %(%d+ of %d+%): tunnelling on"))
    else
        check(id .. ": the probe says to tunnel on", logHas("the probe met %d+%% %(under half%): tunnelling on"))
    end
    check(id .. ": no open water, no bulkhead", not logHas("^Open water at") and not logHas("^Bulkhead across"))
    check(id .. ": the tunnel is dry", wetIn(1, 32) == 0, wetIn(1, 32) .. " blocks of water")
    check(id .. ": dug to the end", leftIn(0, W - 1, 0, H - 1, 1, 32) == 0, leftIn(0, W - 1, 0, H - 1, 1, 32) .. " blocks left")
    check(id .. ": no more than a quarter more moves than with no pocket", moves <= dry * 1.25,
        moves .. " moves, " .. dry .. " with no pocket")
    check(id .. ": back at the start", atStart())
end

-- P3. water that is open water, met mid-segment by a lane part way up (a
--     lake over all but the bottom two rows, the ceiling and the walls,
--     z=20..26), a scanner on board: the scan from there says open water;
--     past it, the lanes carry on from where they had got to rather than
--     from the first
local kit = stock(6, 256, 128)
table.insert(kit, 1, { name = SCANNER, count = 1 })
setup(kit)
local c = chestAt(0, -1, 0)
for _ = 1, 12 do table.insert(c, { name = "minecraft:cobblestone", count = 64 }) end
for x = -3, W + 2 do for y = 2, H + 2 do for z = 20, 26 do
    set(x, y, z, { name = "minecraft:water", level = 0 })
end end end
startAt(); Mine.inv, Mine.files = {}, {}
EQ = { left = "advancedperipherals:chunk_controller", right = "minecraft:diamond_pickaxe" }
FUEL, DRY, PLACED = 20000, 0, 0
WATERY = true
settleWater()
run(tostring(W), tostring(H), "32", "--spacing", "16")
WATERY = false
check("P3: finished", logHas("^Done"), Mine.moves .. " moves")
check("P3: open water", logHas("^Open water at"))
check("P3: past it, the lanes carry on where they had got to (not lane 1)",
    logHas("^Out of the water at z=%d+: the lanes carry on from lane [2-9]%d* of"))
check("P3: the tunnel is dry", wetIn(1, 32) == 0, wetIn(1, 32) .. " blocks of water")
check("P3: dug to the end", leftIn(0, W - 1, 0, H - 1, 1, 32) == 0, leftIn(0, W - 1, 0, H - 1, 1, 32) .. " blocks left")
check("P3: back at the start", atStart())
