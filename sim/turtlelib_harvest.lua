-- sim/turtlelib_harvest.lua
--
-- tl.harvest (ADR-0008 phase 4): T.harvest, T.refuelFromLava and T.fuelFor on sim/lib/buildworld's mock world (digging with
-- drops, chests, a liquid an empty bucket takes up) with a geo scanner on the left.
--   * T.harvest: every block of a kind in a box, nearest first and each column top down; a target stops it; the place as a
--     box, a scan's result and a list of cells; a falling block over a block keeps it (unless that is to be dug first);
--     lava touching it, a protected area and a chest keep it (each until the option that lifts it); a map that is wrong is
--     put right (a block gone, a different block); a box the map does not know is scanned first, a known one is not; a
--     block with no free side is skipped, or tunnelled to when the moves may dig; a full inventory stops it, and
--     T.cfg.autoDump keeps it going;
--   * T.refuelFromLava: the nearest source the map knows, taken up with an empty bucket and burned, back where it began;
--     flowing lava passed over (known and found out), an unreachable source passed over, no bucket, a lava bucket aboard
--     burned first, a tank with no room, no lava known, unlimited fuel; stops at the target;
--   * T.fuelFor: a route, a build, scans and a box of scans added up against the tank and the fuel on board, with the
--     margin and the detour; short, enough, unlimited fuel, a plan it cannot read.
local PROJ = ...
package.path = PROJ .. "/turtle/?.lua;" .. PROJ .. "/lib/?.lua;" .. PROJ .. "/sim/lib/?.lua;" .. package.path
local M = require("mock")
local B = require("buildworld")
local realCheck = M.check
-- (a check's detail is only shown when it fails)
local function check(label, ok, detail) realCheck(label, ok, (not ok) and detail or nil) end

os.epoch = function() return 1000 * 1000 end
local CLK = 0
os.clock = function() CLK = CLK + 0.001; return CLK end
local SETTINGS, DEFAULTS = {}, {}
settings = {
    define = function(name, opts) DEFAULTS[name] = opts.default end,
    get = function(name) if SETTINGS[name] ~= nil then return SETTINGS[name] end return DEFAULTS[name] end,
}
print = function() end

local PICK, SCANNER = "minecraft:diamond_pickaxe", "advancedperipherals:geo_scanner"
local STONE, DIRT, BSTONE = "minecraft:stone", "minecraft:dirt", "minecraft:blackstone"
local GRAVEL, SAND, LAVA = "minecraft:gravel", "minecraft:sand", "minecraft:lava"
local BUCKET, LAVA_BUCKET = "minecraft:bucket", "minecraft:lava_bucket"
local W, T
local SCANS = 0
local MODS = { "turtlelib", "tl.world", "tl.path", "tl.store", "tl.harvest", "tl.blueprint", "tl.place" }

-- The geo scanner, as in the world sims: every block of the cube about the turtle, with its offsets in the turtle's own terms.
local function scanBlocks(r)
    SCANS = SCANS + 1
    local px, py, pz, d = W.S.P.x, W.S.P.y, W.S.P.z, W.S.P.d
    local out = {}
    for dy = -r, r do for dz = -r, r do for dx = -r, r do
        local b = W.get(px + dx, py + dy, pz + dz)
        if b then
            out[#out + 1] = { name = b.name, tags = {}, x = dx, y = dy, z = dz, u = dy,
                f = dx * M.DX[d] + dz * M.DZ[d], r = dx * M.DX[(d + 1) % 4] + dz * M.DZ[(d + 1) % 4] }
        end
    end end end
    return out
end

-- A new world: a floor of stone, the pickaxe on the left, 200 fuel, the library loaded afresh and told which way it points.
local function fresh()
    W = B.new({ facing = "north" })
    W.install()
    EQ.left, EQ.right = PICK, nil
    FUEL = 200
    SCANS = 0
    local p = W.peripheral
    local rawWrap, rawMethods, rawType = p.wrap, p.getMethods, p.getType
    p.wrap = function(side) if EQ[side] == SCANNER then return { scanBlocks = scanBlocks } end return rawWrap(side) end
    p.getMethods = function(side) if EQ[side] == SCANNER then return { "scanBlocks" } end return rawMethods(side) end
    p.getType = function(side) if EQ[side] == SCANNER then return "geoScanner" end return rawType(side) end
    for x = -8, 8 do for z = -8, 8 do W.set(x, -1, z, "minecraft:stone") end end
    for _, name in ipairs(MODS) do package.loaded[name] = nil end
    T = require("turtlelib")
    T.setOrigin(0, 0, 0, "north")
    return W, T
end
-- Put what the world has in the box into the map, as a perfect scan would.
local function know(x1, y1, z1, x2, y2, z2)
    for x = x1, x2 do for y = y1, y2 do for z = z1, z2 do
        local b = W.get(x, y, z)
        T.map.set(x, y, z, b and b.name or "minecraft:air", b and b.state or nil)
    end end end
end
local function carrying(name) return W.carrying(name) end
local function here(x, y, z, d)
    local P = W.S.P
    return P.x == (x or 0) and P.y == (y or 0) and P.z == (z or 0) and P.d == (d or 0)
        and T.pos.x == (x or 0) and T.pos.y == (y or 0) and T.pos.z == (z or 0) and T.dir == (d or 0)
end
local function has(x, y, z, name) local b = W.get(x, y, z); return b ~= nil and (name == nil or b.name == name) end
-- Record where digs happen, in order.
local function recordDigs()
    local digs = {}
    local off = T.onChange(function(e) if e.kind == "dig" then digs[#digs + 1] = { x = e.x, y = e.y, z = e.z } end end)
    return digs, off
end
local function inList(list, x, y, z)
    for _, c in ipairs(list) do
        if c.x == x and c.y == y and c.z == z then return c end
    end
end

--------------------------------------------------------------------------
-- Digging every block of a kind, nearest first and top down
--------------------------------------------------------------------------
do
    fresh()
    W.fill(2, 0, 2, 4, 2, 4, BSTONE)
    W.set(5, 0, 2, DIRT)
    know(-1, -1, -1, 6, 3, 6)
    local digs, off = recordDigs()
    local ok, info = T.harvest("blackstone", { 2, 0, 2, 4, 2, 4 })
    off()
    check("T.harvest digs every block of the kind in a box", ok == true and info.got == 27 and info.seen == 27 and #digs == 27 and not has(3, 1, 3), tostring(ok) .. " " .. tostring(info and info.got))
    check("...only that kind, the others stay", has(5, 0, 2, DIRT))
    check("...what it dug is aboard, and info says so", carrying(BSTONE) == 27 and info.items[BSTONE] == 27)
    check("...the nearest top block first", digs[1].x == 2 and digs[1].y == 2 and digs[1].z == 2, digs[1].x .. "," .. digs[1].y .. "," .. digs[1].z)
    local lastY, topDown = {}, true
    for _, d in ipairs(digs) do
        local k = d.x .. "," .. d.z
        if lastY[k] and d.y > lastY[k] then topDown = false end
        lastY[k] = d.y
    end
    check("...each column from the top down", topDown)
    check("...every cell dug once", (function()
        local seen = {}
        for _, d in ipairs(digs) do
            local k = d.x .. "," .. d.y .. "," .. d.z
            if seen[k] then return false end
            seen[k] = true
        end
        return true
    end)())
    check("...nothing skipped or failed, and the map has the cells as air", #info.skipped == 0 and #info.failed == 0 and T.map.get(3, 1, 3) == "minecraft:air")
end

do
    fresh()
    W.fill(2, 0, 2, 4, 2, 4, BSTONE)
    know(-1, -1, -1, 6, 3, 6)
    local digs, off = recordDigs()
    local ok, info = T.harvest("blackstone", { 2, 0, 2, 4, 2, 4 }, 5)
    off()
    check("with a target it stops there", ok == true and info.got == 5 and #digs == 5 and carrying(BSTONE) == 5, tostring(info and info.got) .. " " .. #digs)
    local why0
    ok, why0, info = T.harvest("blackstone", { 2, 0, 2, 4, 2, 4 }, 30)
    check("a target beyond what there is: false, how many, and why", ok == false and info.got == 22 and info.stopped == nil and info.target == 30
        and info.items[BSTONE] == 22, tostring(ok) .. " " .. tostring(info.got) .. " " .. tostring(info.stopped) .. " " .. tostring(info.items[BSTONE]))
    local _, why = T.harvest("blackstone", { 2, 0, 2, 4, 2, 4 }, 3)
    check("...and the reason says it", why:find("got 0 of 3", 1, true) and why:find("no more matching blocks", 1, true), tostring(why))
    ok, why = T.harvest("blackstone", { 2, 0, 2, 4, 2, 4 }, 0)
    check("a target that is not a whole number from 1: nil and why", ok == nil and why:find("whole number", 1, true), tostring(why))
    ok, why = T.harvest("", { 2, 0, 2, 4, 2, 4 })
    check("no glob: nil and why", ok == nil and why:find("glob of block names", 1, true), tostring(why))
    ok, why = T.harvest("stone", "somewhere")
    check("a place that is none of the three: nil and why", ok == nil and why:find("somewhere to look", 1, true), tostring(why))
    ok, why = T.harvest("stone", { 1, 2, 3 })
    check("...a short list of numbers is a list of cells with none", ok == nil or ok == true)
end

--------------------------------------------------------------------------
-- The place: a scan's result, a list of cells
--------------------------------------------------------------------------
do
    fresh()
    W.fill(2, 0, 2, 3, 0, 3, STONE)
    W.fill(-3, 0, 2, -2, 0, 2, STONE)
    know(-4, -1, -1, 5, 2, 5)
    local cells = {}
    for _, c in ipairs(T.map.find("stone", { 0, 0, 0, 5, 0, 5 })) do cells[c.x .. "," .. c.y .. "," .. c.z] = c.name end
    local ok, info = T.harvest("stone", cells)
    check("a scan's result: the cells in it that match are dug", ok == true and info.got == 4 and has(-3, 0, 2) and not has(2, 0, 2), tostring(info and info.got))
    local list = T.map.find("stone", { -4, 0, 0, 0, 0, 5 })
    ok, info = T.harvest("*stone", list)
    check("a list of cells, as T.map.find gives: dug, and the glob may leave out the namespace", ok == true and info.got == 2 and not has(-3, 0, 2), tostring(info and info.got))
    ok, info = T.harvest("stone", {})
    check("an empty list: nothing to do, and that is fine", ok == true and info.got == 0)
    fresh()
    ok, info = T.harvest("stone", { { x = 1, y = 2, z = 3 } })
    check("a cell the map has never seen is looked at when it is reached, and found empty", ok == true and info.gone == 1 and info.got == 0,
        tostring(ok) .. " " .. tostring(info.gone) .. " " .. tostring(info.got) .. " " .. tostring(info.failed[1] and info.failed[1].why))
end

--------------------------------------------------------------------------
-- Falling blocks over a block
--------------------------------------------------------------------------
do
    fresh()
    W.set(5, 0, 0, STONE); W.set(5, 1, 0, GRAVEL)
    W.set(5, 0, 2, STONE); W.set(5, 1, 2, SAND)
    W.set(5, 0, 4, STONE); W.set(5, 1, 4, "minecraft:white_concrete_powder")
    W.set(5, 0, 6, STONE); W.set(5, 1, 6, "minecraft:anvil")
    W.set(-5, 0, 0, STONE); W.set(-5, 1, 0, "minecraft:cobblestone")
    know(-6, -1, -1, 6, 2, 7)
    local ok, info = T.harvest("stone", { -6, 0, -1, 6, 0, 7 })
    check("a block under gravel, sand, concrete powder or an anvil is left, with the reason; one under cobblestone is dug", ok == true and info.got == 1 and #info.skipped == 4
        and has(5, 0, 0) and has(5, 0, 2) and has(5, 0, 4) and has(5, 0, 6) and not has(-5, 0, 0), tostring(info and #info.skipped))
    check("...the reason names the falling block", info.skipped[1].why:find("over it", 1, true) and (info.skipped[1].why:find("gravel", 1, true) or info.skipped[1].why:find("sand", 1, true)
        or info.skipped[1].why:find("concrete_powder", 1, true) or info.skipped[1].why:find("anvil", 1, true)), info.skipped[1].why)
    ok, info = T.harvest("gravel", { 5, 1, 0, 5, 1, 0 })
    check("the falling block itself is a block like any other", ok == true and info.got == 1 and not has(5, 1, 0))
    ok, info = T.harvest("stone", { 5, 0, 0, 5, 0, 0 })
    check("...and then what was under it can go", ok == true and info.got == 1 and not has(5, 0, 0))
    -- both to be dug: top first
    local digs, off = recordDigs()
    ok, info = T.harvest("*", { 5, 0, 2, 5, 1, 2 })
    off()
    check("both the sand and what is under it are to be dug: the sand first, then the stone", ok == true and info.got == 2 and digs[1].y == 1 and digs[2].y == 0 and not has(5, 0, 2),
        tostring(ok) .. " " .. tostring(info and info.got))
end

--------------------------------------------------------------------------
-- Lava, protected areas, containers
--------------------------------------------------------------------------
do
    fresh()
    W.set(4, 0, 0, STONE); W.set(5, 0, 0, LAVA, { level = 0 })          -- lava beside it
    W.set(4, 0, 2, STONE); W.set(4, 1, 2, LAVA, { level = 0 })          -- lava over it
    W.set(4, 0, 4, STONE)
    know(0, -1, -1, 7, 2, 6)
    local ok, info = T.harvest("stone", { 4, 0, 0, 4, 0, 4 })
    check("a block lava touches (beside it or over it) is left, with the reason; the clear one is dug", ok == true and info.got == 1 and #info.skipped == 2 and has(4, 0, 0) and has(4, 0, 2)
        and not has(4, 0, 4) and info.skipped[1].why:find("lava touches it", 1, true), tostring(info and #info.skipped))
    ok, info = T.harvest("stone", { 4, 0, 0, 4, 0, 4 }, nil, { lava = true })
    check("opts.lava digs them", ok == true and info.got == 2 and not has(4, 0, 0) and not has(4, 0, 2))
end

do
    fresh()
    W.set(3, 0, 3, STONE); W.set(3, 0, 5, STONE)
    know(0, -1, 0, 6, 1, 7)
    T.protect("keep", 3, 0, 3, 3, 0, 3)
    local ok, info = T.harvest("stone", { 3, 0, 3, 3, 0, 5 })
    check("a block in a protected area is left, with the area named; the other is dug", ok == true and info.got == 1 and has(3, 0, 3) and not has(3, 0, 5)
        and info.skipped[1].why == "protected: keep", tostring(info and info.skipped[1] and info.skipped[1].why))
    ok, info = T.harvest("stone", { 3, 0, 3, 3, 0, 5 }, nil, { inside = "keep" })
    check("opts.inside names the area the job owns: dug", ok == true and info.got == 1 and not has(3, 0, 3), tostring(ok) .. " " .. tostring(info.got) .. " " .. tostring(info.failed[1] and info.failed[1].why))
    check("T.cfg.inside is as it was", T.cfg.inside == nil)
end

do
    fresh()
    W.set(-2, 0, 2, "minecraft:chest")
    W.get(-2, 0, 2).inv[1] = { "x", 1 } and { name = "minecraft:coal", count = 3 }
    W.set(-2, 0, 4, "minecraft:stone")
    know(-4, -1, 0, 0, 1, 6)
    local ok, info = T.harvest("*", { -3, 0, 2, -1, 0, 4 })
    check("a chest is left, with the reason; stone is dug", ok == true and info.got == 1 and has(-2, 0, 2, "minecraft:chest") and info.skipped[1].why:find("won't dig minecraft:chest", 1, true)
        and carrying("minecraft:coal") == 0, tostring(ok) .. " " .. tostring(info and info.got))
    T.cfg.digContainers = true
    ok, info = T.harvest("*chest", { -3, 0, 2, -1, 0, 4 })
    check("T.cfg.digContainers lets it", ok == true and info.got == 1 and not has(-2, 0, 2) and carrying("minecraft:coal") == 3)
    T.cfg.digContainers = nil
end

--------------------------------------------------------------------------
-- A map that is wrong
--------------------------------------------------------------------------
do
    fresh()
    W.set(3, 0, 1, STONE)
    know(0, -1, 0, 6, 1, 4)
    T.map.set(3, 0, 3, STONE)                         -- (the world has nothing there)
    T.map.set(3, 0, 5, STONE); W.set(3, 0, 5, DIRT)   -- (the world has dirt)
    local ok, info = T.harvest("stone", { 3, 0, 1, 3, 0, 5 })
    check("a block that is gone and one that is something else are found out when reached, not dug", ok == true and info.got == 1 and info.gone == 2 and has(3, 0, 5, DIRT), tostring(info and info.gone))
    check("...and the map is put right", T.map.get(3, 0, 3) == "minecraft:air" and T.map.get(3, 0, 5) == DIRT)
end

--------------------------------------------------------------------------
-- Scanning the box as needed
--------------------------------------------------------------------------
-- (stones with the centre of the box left empty: the scan is made from the middle of it)
local SPOTS = { { 3, 0, 3 }, { 4, 1, 4 }, { 1, 1, 1 }, { 3, 1, 2 } }
local BOX = { 1, 0, 1, 4, 1, 4 }
local function sparse()
    fresh()
    for _, p in ipairs(SPOTS) do W.set(p[1], p[2], p[3], STONE) end
end
do
    sparse()
    W.give(1, SCANNER, 1)
    local ok, info = T.harvest("stone", BOX)
    check("a box the map does not know is scanned, then dug", ok == true and info.got == 4 and SCANS >= 1 and info.scanned and info.scanned >= 1 and not has(3, 0, 3),
        tostring(ok) .. " " .. tostring(info and info.got) .. " scans " .. SCANS .. " " .. tostring(info and info.scanWhy))
    check("...the pickaxe is back where it was", EQ.left == PICK and carrying(SCANNER) == 1)
    for _, p in ipairs(SPOTS) do W.set(p[1], p[2], p[3], STONE) end
    know(1, 0, 1, 4, 1, 4)
    local scans = SCANS
    ok, info = T.harvest("stone", BOX)
    check("a box the map knows is not scanned again", ok == true and info.got == 4 and SCANS == scans)
    sparse()
    W.give(1, SCANNER, 1)
    ok, info = T.harvest("stone", BOX, nil, { scan = false })
    check("opts.scan = false never scans: the map knows nothing, so nothing to dig", ok == true and info.got == 0 and SCANS == 0 and has(3, 0, 3))
    sparse()
    know(1, 0, 1, 4, 1, 4)
    W.give(1, SCANNER, 1)
    ok, info = T.harvest("stone", BOX, nil, { scan = true })
    check("opts.scan = true scans a known box too", ok == true and info.got == 4 and SCANS >= 1)
    sparse()
    local why
    ok, why = T.harvest("stone", BOX, nil, { scan = true })
    check("a scan that cannot be made when it was asked for: nil and why", ok == nil and why:find("couldn't scan the box", 1, true), tostring(why))
    sparse()
    know(1, 0, 1, 2, 1, 2)
    for _, p in ipairs(SPOTS) do T.map.set(p[1], p[2], p[3], STONE) end
    ok, info = T.harvest("stone", BOX)
    check("a scan that fails when it was only a convenience: it goes on with what the map has, and says why", ok == true and info.got == 4 and info.scanWhy ~= nil, tostring(info and info.scanWhy))
    sparse()
    W.set(2, 0, 2, STONE)
    W.give(1, SCANNER, 1)
    ok, info = T.harvest("stone", BOX, nil, { move = { dig = true } })
    check("a box with stone at its centre is scanned from inside when opts.move may dig (the stone dug getting there is not counted)", ok == true and info.got == 4 and SCANS >= 1 and not has(2, 0, 2), tostring(ok) .. " " .. tostring(info and info.scanWhy))
end

--------------------------------------------------------------------------
-- A block with no free side, a full inventory
--------------------------------------------------------------------------
do
    fresh()
    W.fill(1, 0, 3, 3, 2, 5, DIRT)
    W.set(2, 1, 4, STONE)
    know(-1, -1, 0, 5, 3, 7)
    local ok, why1, info = T.harvest("stone", { 2, 1, 4, 2, 1, 4 })
    check("a block with no free side the map shows is not dug, and says why", ok == false and info.got == 0 and #info.failed == 1 and info.failed[1].why:find("no free cell beside it", 1, true)
        and has(2, 1, 4), tostring(ok) .. " " .. tostring(info.failed[1] and info.failed[1].why) .. " " .. tostring(info.got))
    ok, info = T.harvest("stone", { 2, 1, 4, 2, 1, 4 }, nil, { move = { dig = true } })
    check("with moves that may dig it tunnels in", ok == true and info.got == 1 and not has(2, 1, 4), tostring(ok) .. " " .. tostring(info and info.failed[1] and info.failed[1].why))
end

do
    fresh()
    for i = 0, 5 do W.set(2, 0, 1 + i, "minecraft:block_" .. i) end
    know(0, -1, 0, 4, 1, 8)
    for s = 1, 14 do W.give(s, "minecraft:item_" .. s, 64) end
    local ok, why2, info = T.harvest("*block_*", { 2, 0, 1, 2, 0, 6 })
    check("a full inventory stops it, and says so", ok == false and info.stopped == "the inventory is full" and info.got == 2 and carrying("minecraft:block_1") == 1,
        tostring(ok) .. " " .. tostring(info and info.got) .. " " .. tostring(info and info.stopped))
    check("...the rest stay where they are", has(2, 0, 3) and has(2, 0, 6))
end

do
    fresh()
    W.set(0, 0, 3, "minecraft:chest")
    for i = 0, 7 do W.set(2, 0, 1 + i, "minecraft:block_" .. i) end
    know(-1, -1, 0, 4, 1, 10)
    T.addChest(0, 0, 2, 0, true)
    for s = 1, 13 do W.give(s, "minecraft:item_" .. s, 64) end
    T.cfg.autoDump = true
    local ok, info = T.harvest("*block_*", { 2, 0, 1, 2, 0, 8 })
    check("with T.cfg.autoDump it makes room and goes on", ok == true and info.got == 8 and info.stopped == nil, tostring(ok) .. " " .. tostring(info and info.got) .. " " .. tostring(info and info.stopped))
    local stowed = 0
    for _, it in pairs(W.get(0, 0, 3).inv) do stowed = stowed + it.count end
    check("...what it put away is in the bulk chest, and the turtle did not lose any", stowed >= 13 * 64 and carrying("minecraft:item_1") + (function()
        local n = 0
        for _, it in pairs(W.get(0, 0, 3).inv) do if it.name == "minecraft:item_1" then n = n + it.count end end
        return n
    end)() == 64, tostring(stowed))
end

do
    -- counting the items that came aboard, not the blocks (a double slab gives two)
    fresh()
    for i = 0, 3 do W.set(2, 0, 1 + i, "minecraft:oak_slab", { type = "double" }) end
    know(0, -1, 0, 4, 1, 6)
    local ok, info = T.harvest("oak_slab", { 2, 0, 1, 2, 0, 4 }, 4, { item = "oak_slab" })
    check("opts.item counts the items that came aboard: 4 slabs from 2 double slabs", ok == true and info.got == 2 and carrying("minecraft:oak_slab") == 4, tostring(info and info.got))
    fresh()
    for i = 0, 3 do W.set(2, 0, 1 + i, "minecraft:oak_slab", { type = "double" }) end
    know(0, -1, 0, 4, 1, 6)
    ok, info = T.harvest("oak_slab", { 2, 0, 1, 2, 0, 4 }, 4)
    check("...without it the target is blocks: 4 blocks, 8 slabs", ok == true and info.got == 4 and carrying("minecraft:oak_slab") == 8, tostring(info and info.got))
end

--------------------------------------------------------------------------
-- T.refuelFromLava
--------------------------------------------------------------------------
local function lavaWorld()
    fresh()
    W.set(3, -1, 3, LAVA, { level = 0 })
    W.set(-6, -1, 5, LAVA, { level = 0 })
    know(-7, -2, -1, 5, 1, 7)
    W.give(1, BUCKET, 1)
end
do
    lavaWorld()
    local ok, gained = T.refuelFromLava(1000)
    check("T.refuelFromLava takes the nearest source up and burns it", ok == true and FUEL >= 1000 and FUEL <= 1200 and gained == FUEL - 200 and not has(3, -1, 3) and has(-6, -1, 5, LAVA),
        tostring(ok) .. " " .. tostring(FUEL))
    check("...the bucket is back (empty), the turtle where it began, facing as before", carrying(BUCKET) == 1 and carrying(LAVA_BUCKET) == 0 and here())
    check("...the map has the cell as air now", T.map.get(3, -1, 3) == "minecraft:air")
    local moves = W.S.moves
    ok, gained = T.refuelFromLava(900)
    check("a tank already at the target: true, nothing done", ok == true and gained == 0 and W.S.moves == moves)
end

do
    lavaWorld()
    FUEL = 100
    local ok, why, gained = T.refuelFromLava(2400)
    check("a target beyond what the lava gives: both sources, then false and why", ok == false and gained > 1800 and gained < 2100 and not has(3, -1, 3) and not has(-6, -1, 5)
        and why:find("no more lava sources", 1, true) ~= nil, tostring(ok) .. " " .. tostring(gained) .. " " .. tostring(why))
    check("...and it came home", here())
end

do
    lavaWorld()
    W.set(1, -1, 1, LAVA, { level = 3 })               -- flowing, and the map is not told
    T.map.set(1, -1, 1, LAVA)
    W.set(2, -1, 1, LAVA, { level = 5 })               -- flowing, and the map knows
    T.map.set(2, -1, 1, LAVA, { level = 5 })
    local ok, gained = T.refuelFromLava(1000)
    check("flowing lava is passed over, known or found out, for the source farther off", ok == true and not has(3, -1, 3) and has(1, -1, 1, LAVA) and has(2, -1, 1, LAVA), tostring(ok))
    check("...the one found out is in the map with its state", (select(2, T.map.get(1, -1, 1)) or {}).level == "3" or (select(2, T.map.get(1, -1, 1)) or {}).level == 3)
end

do
    lavaWorld()
    W.fill(2, -1, 3, 4, 1, 3, "minecraft:bedrock")
    W.set(3, -1, 3, LAVA, { level = 0 })
    W.fill(2, -1, 2, 4, 1, 2, "minecraft:bedrock")
    W.fill(2, -1, 4, 4, 1, 4, "minecraft:bedrock")
    W.fill(2, 0, 3, 4, 1, 3, "minecraft:bedrock")
    W.fill(2, 0, 2, 4, 1, 4, "minecraft:bedrock")
    know(-1, -2, -1, 5, 2, 6)
    local ok, gained = T.refuelFromLava(1000)
    check("a source nothing can get next to is passed over for the next", ok == true and has(3, -1, 3, LAVA) and not has(-6, -1, 5) and here(), tostring(ok) .. " " .. tostring(gained))
end

do
    lavaWorld()
    W.give(1, nil)
    local ok, why = T.refuelFromLava(1000)
    check("no bucket: false and why, no trip", ok == false and why:find("no empty bucket", 1, true) and W.S.moves == 0 and has(3, -1, 3, LAVA), tostring(why))
    W.give(2, LAVA_BUCKET, 1)
    ok = T.refuelFromLava(1100)
    check("a lava bucket aboard is burned first, with no trip", ok == true and FUEL == 1200 and W.S.moves == 0 and carrying(LAVA_BUCKET) == 0 and carrying(BUCKET) == 1, tostring(FUEL))
    FUEL = 19500
    local ok2, gained = T.refuelFromLava()
    check("a tank with no room for another bucket: true, nothing done", ok2 == true and gained == 0 and W.S.moves == 0 and has(3, -1, 3, LAVA))
    FUEL = nil
    ok2, gained = T.refuelFromLava()
    check("fuel that is not needed: true, 0", ok2 == true and gained == 0)
    FUEL = 200
    T.map.clear()
    W.give(1, BUCKET, 1)
    local why2
    ok2, why2, gained = T.refuelFromLava(1000)
    check("no lava in the map: false and why", ok2 == false and gained == 0 and why2:find("knows no lava", 1, true) ~= nil, tostring(why2))
end

--------------------------------------------------------------------------
-- T.fuelFor
--------------------------------------------------------------------------
do
    fresh()
    FUEL = 100
    local ok, info = T.fuelFor({ route = { { x = 3, y = 0, z = 4 } } })
    check("a route: its length, a quarter more for detours, and the margin", ok == true and info.route == 9 and info.margin == 30 and info.need == 39 and info.have == 100 and info.enough, tostring(info and info.need))
    ok, info = T.fuelFor({ go = { x = 3, y = 0, z = 4 }, back = true })
    check("a point and the way back", info.route == 9 and info.back == 9 and info.need == 48, tostring(info.need))
    ok, info = T.fuelFor({ { x = 3, y = 0, z = 4 }, { x = 3, y = 5, z = 4 } })
    check("a bare list of points is a route: 7 and 5 moves", info.route == 15, tostring(info.route))
    FUEL = 20
    local why
    ok, why, info = T.fuelFor({ route = { { x = 3, y = 0, z = 4 } } })
    check("short: false, how much, and what the numbers were", ok == false and info.short == 19 and why:find("19 short", 1, true) and why:find("needs about 39", 1, true), tostring(why))
    W.give(1, "minecraft:coal", 2)
    ok, info = T.fuelFor({ route = { { x = 3, y = 0, z = 4 } } })
    check("fuel on board counts: 2 coal is 160", ok == true and info.board == 160 and info.have == 180)
    check("it moves nothing and burns nothing", W.S.moves == 0 and carrying("minecraft:coal") == 2 and FUEL == 20)
    FUEL = 19000
    ok, info = T.fuelFor({ scans = 2 })
    check("scans: a radius-8 scan is estimated from the 5300 of a radius-16 one", info.scans == 2 * 663 and info.need == 1326 + 30, tostring(info.scans))
    T.cfg.scanFuel = { [8] = 500 }
    ok, info = T.fuelFor({ scans = 2 })
    check("T.cfg.scanFuel gives the real cost", info.scans == 1000)
    ok, info = T.fuelFor({ scans = 1, radius = 4 })
    check("...a radius it has no cost for is estimated", info.scans == math.ceil(5300 / 64), tostring(info.scans))
    T.cfg.scanFuel = nil
    ok, info = T.fuelFor({ box = { 0, 0, 0, 16, 16, 16 } })
    check("a box of scans: one tile of 17, the scan and the moves across it", info.scans == 663 + 17, tostring(info.scans))
    ok, info = T.fuelFor({ box = { 0, 0, 0, 17, 16, 16 } })
    check("...a box one wider is two tiles", info.scans == 2 * 663 + 2 * 17, tostring(info.scans))
    local plan = T.blueprint.fill(0, 0, 3, 2, 0, 5, STONE)
    ok, info = T.fuelFor(plan)
    check("a blueprint: 9 cells, a layer, the way to its corner, a quarter more", info.build == math.ceil((9 + 1 + 3) * 1.25), tostring(info.build))
    ok, info = T.fuelFor({ build = plan, route = { { x = 0, y = 0, z = 2 } }, extra = 10 })
    check("...after a route, from where it ends; and extra fuel added", info.route == 3 and info.build == math.ceil((9 + 1 + 1) * 1.25) and info.extra == 10, tostring(info.route) .. " " .. tostring(info.build))
    ok, info = T.fuelFor({ route = { { x = 3, y = 0, z = 4 } } }, { detour = 1 })
    check("opts.detour changes the 25%", info.route == 7)
    T.cfg.fuelMargin = 100
    ok, info = T.fuelFor({ route = { { x = 3, y = 0, z = 4 } } })
    check("T.cfg.fuelMargin is the margin", info.margin == 100)
    T.cfg.fuelMargin = nil
    local bad, reason = T.fuelFor(nil)
    check("no plan: nil and why", bad == nil and reason:find("wants a plan", 1, true), tostring(reason))
    bad, reason = T.fuelFor({ route = { { x = 1.5, y = 0, z = 0 } } })
    check("a point that is not whole numbers: nil and why", bad == nil and reason:find("whole numbers", 1, true), tostring(reason))
    bad, reason = T.fuelFor({ scans = -1 })
    check("scans that are not a whole number from 0: nil and why", bad == nil and reason:find("whole number of scans", 1, true), tostring(reason))
    bad, reason = T.fuelFor({ build = { layers = 5 } })
    check("a blueprint that is no good: nil and why", bad == nil and reason ~= nil)
    FUEL = nil
    ok, info = T.fuelFor({ route = { { x = 3, y = 0, z = 4 } } })
    check("fuel that is not needed: always enough", ok == true and info.tank == "unlimited" and info.enough)
end
