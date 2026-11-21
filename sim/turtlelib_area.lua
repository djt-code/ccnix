-- sim/turtlelib_area.lua
--
-- tl.area (ADR-0015 D8: the claude model's own helpers, made library functions) on sim/lib/buildworld's mock world:
--   * T.pave: a floor of mixed blocks laid in one item, a move a cell; what is the item already left; opts.exclude; a
--     floor box that isn't one layer refused; the item running out stops it, saying so; (ADR-0019 D8) with
--     T.cfg.digNeedsRoom, the kinds the map shows to dig against the free slots: too many refused with the counts
--     before it moves; enough room (a stack to join, a free slot), or a floor the map hasn't seen, and it goes;
--   * T.clearBox: a solid tunnel cleared three layers a pass (fewer moves than cells), nothing outside the box dug; a
--     protected area inside it left, each cell failing with why; opts.maxFuel stops it;
--   * T.sweep: the items lying in a box picked up, never a chest's (a chest in the box keeps what it holds).
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

local PICK = "minecraft:diamond_pickaxe"
local STONE, DIRT, BRICKS = "minecraft:stone", "minecraft:dirt", "minecraft:stone_bricks"
local W, T
local MODS = { "turtlelib", "tl.world", "tl.path", "tl.area" }

-- A new world: the pickaxe on the left, 500 fuel, the library loaded afresh, every cell of the box known to the map.
local function fresh(blocks, know)
    W = B.new({ facing = "north" })
    W.install()
    EQ.left, EQ.right = PICK, nil
    FUEL = 500
    for _, b in ipairs(blocks or {}) do W.set(b[1], b[2], b[3], b[4]) end
    for _, name in ipairs(MODS) do package.loaded[name] = nil end
    T = require("turtlelib")
    T.setOrigin(0, 0, 0, "north")
    local k = know or { -3, -3, -3, 10, 5, 10 }
    for x = k[1], k[4] do for y = k[2], k[5] do for z = k[3], k[6] do
        local b = W.get(x, y, z)
        T.map.set(x, y, z, b and b.name or "minecraft:air")
    end end end
    return W, T
end
local function has(x, y, z, name) local b = W.get(x, y, z); return b ~= nil and (name == nil or b.name == name) end
local function cube(list, x1, y1, z1, x2, y2, z2, name)
    for x = x1, x2 do for y = y1, y2 do for z = z1, z2 do list[#list + 1] = { x, y, z, name } end end end
    return list
end

--------------------------------------------------------------------------
-- T.pave
--------------------------------------------------------------------------
do
    -- a floor at y -1, x 1..5, z 1..3, of stone with dirt patches and two bricks already in
    local blocks = cube({}, 1, -1, 1, 5, -1, 3, STONE)
    blocks[#blocks + 1] = { 2, -1, 2, DIRT }
    blocks[#blocks + 1] = { 3, -1, 1, BRICKS }
    blocks[#blocks + 1] = { 4, -1, 3, BRICKS }
    fresh(blocks)
    W.give(1, BRICKS, 20)
    local moves = W.S.moves
    local ok, info = T.pave({ 1, -1, 1, 5, -1, 3 }, BRICKS)
    local all = true
    for x = 1, 5 do for z = 1, 3 do all = all and has(x, -1, z, BRICKS) end end
    check("T.pave: every cell of the floor made the item, rows a block above, one move a cell", ok == true and all
        and info.placed == 13 and info.there == 2 and W.S.moves - moves <= 15 + 3, tostring(info and info.placed) .. " " .. (W.S.moves - moves))
    check("...what it dug came aboard (12 stone, a dirt)", W.carrying(STONE) == 12 and W.carrying(DIRT) == 1)
    fresh(cube({}, 1, -1, 1, 5, -1, 3, STONE))
    W.give(1, BRICKS, 20)
    ok, info = T.pave({ 1, -1, 1, 5, -1, 3 }, BRICKS, { exclude = { { 3, -1, 1, 3, -1, 3 } } })
    check("...opts.exclude leaves those cells as they are", ok == true and has(3, -1, 2, STONE) and has(2, -1, 2, BRICKS) and info.placed == 12)
    local bad, why = T.pave({ 1, -1, 1, 5, 0, 3 }, BRICKS)
    check("...a box of two layers: refused, saying it is the floor's one layer", bad == nil and why:find("one layer", 1, true) ~= nil, tostring(why))
    fresh(cube({}, 1, -1, 1, 5, -1, 3, STONE))
    W.give(1, BRICKS, 4)
    ok, why, info = T.pave({ 1, -1, 1, 5, -1, 3 }, BRICKS)
    check("...the item running out stops it, saying so", ok == false and why == "pave: out of minecraft:stone_bricks (4 placed)"
        and info.placed == 4, tostring(why))

    -- (ADR-0019 D8) room for what it digs: dirt, planks and andesite in a floor of stone; full stacks of glass in
    -- slots 2 to 15, one slot free
    local PLANKS, ANDESITE, GLASS = "minecraft:oak_planks", "minecraft:andesite", "minecraft:glass"
    local function mixed(know)
        local list = cube({}, 1, -1, 1, 5, -1, 3, STONE)
        list[#list + 1] = { 2, -1, 2, DIRT }
        list[#list + 1] = { 3, -1, 3, PLANKS }
        list[#list + 1] = { 4, -1, 1, ANDESITE }
        fresh(list, know)
        T.cfg.digNeedsRoom = true
        W.give(1, BRICKS, 20)
        for slot = 2, 15 do W.give(slot, GLASS, 64) end
    end
    mixed()
    moves = W.S.moves
    local nothing
    nothing, why = T.pave({ 1, -1, 1, 5, -1, 3 }, BRICKS)
    check("T.cfg.digNeedsRoom: four kinds to dig and one slot free: refused with the counts, before it moves",
        nothing == nil and why == "pave: what it would dig won't fit: the map shows 4 kinds to dig (minecraft:andesite x1, "
            .. "minecraft:cobblestone x12, minecraft:dirt x1, minecraft:oak_planks x1), 4 of them with no stack aboard to join, and 1 slot "
            .. "is free (T.cfg.digNeedsRoom; T.stow or drop something first, or a smaller box)"
            and W.S.moves == moves and has(2, -1, 2, DIRT), tostring(why))
    mixed({ -3, 0, -3, 10, 5, 10 })
    ok, why = T.pave({ 1, -1, 1, 5, -1, 3 }, BRICKS)
    check("...a floor the map hasn't seen, one slot free: one more kind fits, so it goes (stopping at the first dig with no room)",
        ok ~= nil and W.S.moves > moves, tostring(why))
    -- (ADR-0020 D3, #348) unseen cells are one more kind: with no slot free it refuses before it moves
    mixed({ -3, 0, -3, 10, 5, 10 })
    W.give(16, GLASS, 64)
    moves = W.S.moves
    nothing, why = T.pave({ 1, -1, 1, 5, -1, 3 }, BRICKS)
    check("...a floor the map hasn't seen and no slot free: refused, the unseen cells counted as one more kind", nothing == nil
        and tostring(why):find("15 cells not in the map, counted as one more kind (T.scanBox first)", 1, true) ~= nil
        and W.S.moves == moves, tostring(why))
    local floor = cube({}, 1, -1, 1, 5, -1, 3, DIRT)
    floor[#floor + 1] = { 2, -1, 2, PLANKS }
    fresh(floor)
    T.cfg.digNeedsRoom = true
    W.give(1, BRICKS, 20)
    W.give(2, DIRT, 10)
    for slot = 3, 15 do W.give(slot, GLASS, 64) end
    ok, info = T.pave({ 1, -1, 1, 5, -1, 3 }, BRICKS)
    check("...room enough (a stack of dirt to join, a slot for the planks): it paves", ok == true and info.placed == 15
        and W.carrying(DIRT) == 24 and W.carrying(PLANKS) == 1,
        tostring(ok) .. " " .. tostring(info and info.placed) .. " placed, " .. W.carrying(DIRT) .. " dirt, " .. W.carrying(PLANKS) .. " planks")
end

--------------------------------------------------------------------------
-- T.clearBox
--------------------------------------------------------------------------
do
    -- solid stone x -2..2, y -1..4, z 1..8; the box: a tunnel 1 wide, 3 high, 6 long (x 0, y 0..2, z 1..6), its
    -- mouth in front of the turtle
    local solid = cube({}, -2, -1, 1, 2, 4, 8, STONE)
    fresh(solid)
    local moves = W.S.moves
    local ok, why, info = T.clearBox({ 0, 0, 1, 0, 2, 6 })
    if ok then info = why end
    local clear, outside = true, true
    for y = 0, 2 do for z = 1, 6 do clear = clear and not has(0, y, z) end end
    for _, c in ipairs({ { 0, 0, 7 }, { 0, 2, 7 }, { 1, 1, 4 }, { -1, 1, 4 }, { 0, 3, 4 }, { 0, -1, 4 } }) do
        outside = outside and has(c[1], c[2], c[3], STONE)
    end
    check("T.clearBox: a solid tunnel cleared, three layers a pass (fewer moves than its 18 cells)", ok == true and clear
        and info.dug == 18 and W.S.moves - moves < 18, tostring(why) .. " / " .. tostring(info and info.dug) .. " dug, " .. (W.S.moves - moves) .. " moves")
    check("...nothing outside the box dug", outside == true)
    fresh(solid)
    T.protect("shrine", 0, 0, 5, 0, 2, 5)
    ok, why, info = T.clearBox({ 0, 0, 1, 0, 2, 6 })
    check("...a protected area in it: kept, its cells failing with why, the rest cleared", ok == false and has(0, 1, 5, STONE)
        and not has(0, 1, 4) and why:find("protected: shrine", 1, true) ~= nil, tostring(why))
    T.unprotect("shrine")
    fresh(solid)
    ok, why, info = T.clearBox({ 0, 0, 1, 0, 2, 6 }, { maxFuel = 3 })
    check("...opts.maxFuel stops it, saying so", ok == false and why:find("opts.maxFuel 3", 1, true) ~= nil, tostring(why))
end

--------------------------------------------------------------------------
-- T.sweep
--------------------------------------------------------------------------
do
    -- a floor at y -1; dirt lying in three cells of the layer above it; a chest in the box with cobblestone in it
    fresh(cube({}, -2, -1, -2, 6, -1, 6, STONE))
    W.set(3, 0, 3, "minecraft:chest")
    W.get(3, 0, 3).inv[1] = { name = "minecraft:cobblestone", count = 10 }
    T.map.set(3, 0, 3, "minecraft:chest")
    W.ground["1,0,2"] = { { name = DIRT, count = 3 } }
    W.ground["2,0,4"] = { { name = DIRT, count = 2 } }
    W.ground["4,0,1"] = { { name = "minecraft:oak_sapling", count = 1 } }
    local ok, info = T.sweep({ 0, 0, 0, 4, 0, 4 })
    check("T.sweep: what lay in the box picked up (5 dirt, a sapling)", ok == true and W.carrying(DIRT) == 5
        and W.carrying("minecraft:oak_sapling") == 1 and info.picked == 6, tostring(info and info.picked))
    check("...the chest in the box keeps what it holds", W.get(3, 0, 3).inv[1] and W.get(3, 0, 3).inv[1].count == 10
        and W.carrying("minecraft:cobblestone") == 0)
end
