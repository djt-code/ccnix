-- sim/turtlelib_blueprint.lua
--
-- tl.blueprint (ADR-0008 phase 3): plans, T.build, T.verify and T.replace on sim/lib/buildworld's mock world.
--   * the format: text and table forms read the same, a plan written out and read back is the same plan, the errors
--     name the line; fill, box, walls and fromMap make plans; put and at;
--   * a small building (floor, walls, a stair bench, a torch, a door) built in the order the plan needs (walls before
--     the stair and the torch, the door last in its layer), stopped midway with a limit, resumed after a restart of the
--     computer, stopped by a Ctrl+T in the middle of a cell and resumed, then verified clean; the world is what
--     the plan says; no cell placed twice;
--   * the materials: short is refused before the turtle moves (with what could be crafted if a craft module is
--     there, loaded only then), partial builds what it can, a block in the way fails the cell and the build goes on, the
--     failed cell is tried again on the next run;
--   * a different plan while one is unfinished is refused (restart starts it), the same plan after a finished build
--     starts afresh; a facing without the world origin is refused; opts.protect keeps the finished build;
--   * T.verify: a deliberately wrong stair found by state, a wrong plain block found only when looking at every cell, a
--     stray block in a cell the plan wants empty, a cell it could not look at listed, the saved build checked with no
--     plan;
--   * T.replace: a wall's blocks swapped each from a free side, the one inside reported (and not dug to), a
--     protected area refusing unless the job owns it, a stateful block, short of blocks, a block changed since the map.
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

local STONE = "minecraft:stone"
local BRICKS = "minecraft:stone_bricks"
local W, T                                  -- the world, the library
local MODULES = { "turtlelib", "tl.world", "tl.path", "tl.place", "tl.blueprint", "tl.craft", "tl.craftstub" }

-- A new world with the turtle at 0,0,0 (heading 0 is north) and the library loaded afresh, told which way it points
-- (unless origin is false); then the blocks of the scene: { x, y, z, name, state }.
local function fresh(blocks, origin)
    W = B.new({ facing = "north" })
    W.install()
    CLK = 0
    for _, name in ipairs(MODULES) do package.loaded[name] = nil end
    CRAFTSTUB_LOADS = 0
    T = require("turtlelib")
    for _, b in ipairs(blocks or {}) do W.set(b[1], b[2], b[3], b[4], b[5]) end
    if origin ~= false then T.setOrigin(0, 0, 0, "north") end
    return W, T
end
-- A restart of the computer: the disk and the world as they are, the library loaded afresh, the turtle where it is.
local function restart()
    local p, d = { W.S.P.x, W.S.P.y, W.S.P.z }, W.S.P.d
    for _, name in ipairs(MODULES) do package.loaded[name] = nil end
    T = require("turtlelib")
    T.pos.x, T.pos.y, T.pos.z, T.dir = p[1], p[2], p[3], d
    T.savePos()
    return T
end
local function know(x1, y1, z1, x2, y2, z2)
    for x = x1, x2 do for y = y1, y2 do for z = z1, z2 do
        local b = W.get(x, y, z)
        T.map.set(x, y, z, b and b.name or "minecraft:air", b and b.state or nil)
    end end end
end
local function has(x, y, z, name, state)
    local b = W.get(x, y, z)
    if not name then return b == nil end
    if not b or b.name ~= "minecraft:" .. name then return false end
    for k, v in pairs(state or {}) do
        if b.state[k] ~= v then return false end
    end
    return true
end
local function fileText(name)
    local f = fs.open(T.dataPath(name), "r")
    if not f then return nil end
    local s = f.readAll()
    f.close()
    return s
end
-- T.build and T.replace answer true, info on success and false or nil, why, info otherwise: always ok, why, info here.
local function threeValues(ok, a, b)
    if ok == true then return true, nil, a end
    return ok, a, b
end
local function build(...) return threeValues(T.build(...)) end
local function replace(...) return threeValues(T.replace(...)) end
local function cube(x1, y1, z1, x2, y2, z2, name)
    local out = {}
    for x = x1, x2 do for y = y1, y2 do for z = z1, z2 do out[#out + 1] = { x, y, z, name } end end end
    return out
end

--------------------------------------------------------------------------
-- The format
--------------------------------------------------------------------------
local TEXT = [[
name: tower
anchor: 10 64 -3
B = minecraft:stone_bricks
s = stone_brick_stairs[facing=north,half=bottom]
layer 1:
BBBB
B..B
layer 2:
ssss
 s
]]
do
    fresh()
    local bpl = T.blueprint
    local p, why = bpl.parse(TEXT)
    check("a plan reads from text", p ~= nil, why)
    check("...its name and anchor", p and p.name == "tower" and p.anchor.x == 10 and p.anchor.y == 64 and p.anchor.z == -3)
    check("...the legend, a name without a namespace being minecraft:'s, and the state",
        p and p.legend.B.name == BRICKS and p.legend.s.name == "minecraft:stone_brick_stairs" and p.legend.s.state.facing == "north"
        and p.legend.s.state.half == "bottom")
    check("...two layers, rows kept (a space leaves a cell alone)", p and #p.layers == 2 and p.layers[1][2] == "B..B" and p.layers[2][2] == " s")
    check("at: the first character is the anchor; the next line is one z down; the next layer one up",
        p and bpl.at(p, 10, 64, -3) == BRICKS and bpl.at(p, 11, 64, -4) == "minecraft:air" and bpl.at(p, 10, 65, -3) == "minecraft:stone_brick_stairs"
        and bpl.at(p, 13, 64, -3) == BRICKS)
    check("...a cell left alone, and one outside, are nil", p and bpl.at(p, 10, 65, -4) == nil and bpl.at(p, 10, 66, -3) == nil
        and bpl.at(p, 20, 64, -3) == nil)
    local a, b, c, d, e, f = bpl.extent(p)
    check("extent: the cells the text reaches", a == 10 and b == 64 and c == -4 and d == 13 and e == 65 and f == -3, table.concat({ a, b, c, d, e, f }, " "))
    local out = bpl.format(p)
    local again = bpl.parse(out)
    check("written out and read back, the same plan", again and bpl.format(again) == out and again.layers[2][2] == " s" and again.name == "tower")
    local tbl = bpl.new({ name = "tower", anchor = { 10, 64, -3 }, legend = { B = BRICKS, s = { name = "stone_brick_stairs", state = { facing = "north", half = "bottom" } } },
        layers = { "BBBB\nB..B", { "ssss", " s" } } })
    check("the same plan as a table is the same", tbl and bpl.format(tbl) == out, tbl and bpl.format(tbl))
    local why1 = select(2, bpl.parse("anchor: 1 2\nlayer 1:\n"))
    check("a bad anchor says which line", why1 and why1:find("line 1", 1, true), tostring(why1))
    local why2 = select(2, bpl.parse("B = stone\nlayer 1:\nBX\n"))
    check("a symbol missing from the legend says where", why2 and why2:find("layer 1, line 1, column 2", 1, true) and why2:find("\"X\"", 1, true), tostring(why2))
    local why3 = select(2, bpl.parse("B stone\nlayer 1:\nB\n"))
    check("a bad legend line says which", why3 and why3:find("line 1", 1, true), tostring(why3))
    check("no layers", select(2, bpl.parse("B = stone\n")) ~= nil)
    check("a state without its bracket", select(2, bpl.parse("B = stone[facing\nlayer 1:\nB\n")) ~= nil)

    local fill = bpl.fill(2, 0, 3, 4, 1, 5, "stone")
    check("fill: a box of one block, the anchor its high-z corner", fill and fill.anchor.x == 2 and fill.anchor.z == 5 and #fill.layers == 2
        and fill.layers[1][1] == "BBB" and fill.layers[2][3] == "BBB" and bpl.at(fill, 4, 1, 3) == STONE)
    local box = bpl.box(0, 0, 0, 2, 2, 2, "stone_bricks")
    check("box: the six faces, the inside left alone", box and box.layers[1][2] == "BBB" and box.layers[2][2] == "B B" and box.layers[3][1] == "BBB"
        and bpl.at(box, 1, 1, 1) == nil)
    local walls = bpl.walls(0, 0, 0, 2, 1, 2, "stone_bricks")
    check("walls: the four sides, no floor or roof", walls and walls.layers[1][2] == "B B" and walls.layers[2][2] == "B B" and bpl.at(walls, 1, 0, 1) == nil
        and bpl.at(walls, 1, 0, 0) == BRICKS)
    check("corners in either order", bpl.fill(4, 1, 5, 2, 0, 3, "stone").anchor.z == 5)
    check("a bad box or block says so", select(2, bpl.fill(1.5, 0, 0, 1, 1, 1, "stone")) ~= nil and select(2, bpl.fill(0, 0, 0, 1, 1, 1, "stone[x")) ~= nil)
    check("put: a cell inside the layers set to a block", bpl.put(box, 1, 1, 1, "oak_stairs[facing=east,half=top]") and bpl.at(box, 1, 1, 1) == "minecraft:oak_stairs"
        and select(2, bpl.at(box, 1, 1, 1)).facing == "east")
    check("put: air, and leaving alone", bpl.put(box, 1, 1, 1, "air") and bpl.at(box, 1, 1, 1) == "minecraft:air" and bpl.put(box, 1, 1, 1, nil)
        and bpl.at(box, 1, 1, 1) == nil)
    check("put outside the layers (or before the anchor) says so", select(2, bpl.put(box, 1, 5, 1, "stone")) ~= nil and select(2, bpl.put(box, -1, 1, 1, "stone")) ~= nil
        and select(2, bpl.put(box, 1, 1, 3, "stone")) ~= nil)
    check("put beside the lines grows them", bpl.put(box, 4, 1, 1, "stone") and bpl.at(box, 4, 1, 1) == STONE and select(2, bpl.extent(box)) == 0)
    local rows = bpl.format(box)
    check("put keeps the plan whole through the text", bpl.format(bpl.parse(rows)) == rows)
    do
        local q = bpl.fill(0, 0, 0, 1, 0, 0, "stone")
        bpl.put(q, 0, 0, 0, "stone[a=b]")
        local _, s0 = bpl.at(q, 0, 0, 0)
        local _, s1 = bpl.at(q, 1, 0, 0)
        check("a state keeps a symbol of its own", q.layers[1][1] ~= "BB" and bpl.at(q, 0, 0, 0) == STONE and s0 and s0.a == "b" and bpl.at(q, 1, 0, 0) == STONE
            and s1 == nil)
    end

    local q2 = bpl.fill(0, 0, 0, 1, 0, 0, "stone")
    bpl.put(q2, 0, 0, 0, "dirt")
    bpl.put(q2, 1, 0, 0, "dirt")
    local kinds = 0
    for _ in pairs(q2.legend) do kinds = kinds + 1 end
    check("put gives the same block the same symbol", kinds == 2, q2.layers[1][1] .. " " .. kinds)

    -- fromMap
    fresh({ { 1, 0, 1, "minecraft:oak_stairs", { facing = "east", half = "top" } }, { 0, 0, 1, STONE } })
    know(0, 0, 0, 1, 0, 1)
    T.map.set(0, 0, 0, STONE)
    local q, qwhy = T.blueprint.fromMap({ 0, 0, 0, 2, 0, 1 })
    check("fromMap: the blocks as the map has them, air a dot, cells the map has never seen left alone", q and
        bpl.at(q, 0, 0, 0) == STONE and bpl.at(q, 1, 0, 0) == "minecraft:air" and bpl.at(q, 0, 0, 1) == STONE and bpl.at(q, 2, 0, 0) == nil,
        tostring(qwhy) .. tostring(q and bpl.format(q)))
    local qn, qs = T.blueprint.at(q, 1, 0, 1)
    check("...with a state it was inspected with", qn == "minecraft:oak_stairs" and qs and qs.facing == "east" and qs.half == "top")
    check("...and it goes through the text and back", bpl.format(bpl.parse(bpl.format(q))) == bpl.format(q))
    check("fromMap with a bad box says so", select(2, T.blueprint.fromMap({ 0, 0 })) ~= nil)
end

--------------------------------------------------------------------------
-- A small building: floor, walls, a stair bench, a torch, a door
--------------------------------------------------------------------------
local HOUSE = [[
name: house
anchor: 2 0 7
B = minecraft:stone
s = minecraft:oak_stairs[facing=east,half=bottom]
t = minecraft:torch
d = minecraft:oak_door[facing=south,half=lower]
D = minecraft:oak_door[facing=south,half=upper]
layer 1:
BBBBB
BBBBB
BBBBB
BBBBB
BBBBB
layer 2:
BBBBB
Bt..B
B.s.B
B...B
BBdBB
layer 3:
BBBBB
B...B
B...B
B...B
BBDBB
]]
-- floor 25, the ring of the walls less the door's gap 15 (twice), the bench, the torch and the door
local HOUSE_CELLS = 25 + 15 + 15 + 3
local function stock(world)
    world.give(1, STONE, 64)
    world.give(2, "minecraft:oak_stairs", 2)
    world.give(3, "minecraft:torch", 2)
    world.give(4, "minecraft:oak_door", 2)
end
local function houseIsBuilt()
    local good = true
    for x = 2, 6 do for z = 3, 7 do good = good and has(x, 0, z, "stone") end end
    for x = 2, 6 do for z = 3, 7 do
        local ring = x == 2 or x == 6 or z == 3 or z == 7
        if ring and not (x == 4 and z == 3) then
            good = good and has(x, 1, z, "stone") and has(x, 2, z, "stone")
        end
    end end
    good = good and has(4, 1, 3, "oak_door", { half = "lower", facing = "south" }) and has(4, 2, 3, "oak_door", { half = "upper" })
    good = good and has(4, 1, 5, "oak_stairs", { facing = "east", half = "bottom" }) and has(3, 1, 6, "torch")
    return good
end

do
    fresh()
    stock(W)
    local order = {}
    T.onChange(function(e) if e.kind == "place" then order[#order + 1] = e end end)
    local ok, why, info = build(HOUSE, { limit = 20 })
    check("a limit stops the build after that many cells, saying how to go on", ok == false and why:find("stopped after 20 cells", 1, true) and why:find("T.build()", 1, true), tostring(why))
    check("...the info counts the cells", info and info.done == 20 and info.total == HOUSE_CELLS and info.placed == 20 and info.finished == false,
        info and (info.done .. "/" .. info.total))
    local planFile, progress = fileText(".build"), fileText(".build.progress")
    check("the plan is kept as text in the data folder, and the progress beside it", planFile and planFile:find("layer 3:", 1, true) and progress
        and progress:find("done 20", 1, true) and progress:find("name house", 1, true), tostring(progress))
    check("a stop partway leaves the building partly built", has(2, 0, 7, "stone") and not has(6, 1, 3, "stone"))

    restart()
    T.onChange(function(e) if e.kind == "place" then order[#order + 1] = e end end)
    local placedBefore = W.placed
    ok, why, info = build()
    check("after a restart of the computer T.build() carries on from the saved plan and progress", ok == true and info and info.finished and info.resumed, tostring(why))
    check("...the building is as the plan says", houseIsBuilt())
    check("...no cell placed twice: the world saw exactly one placement per cell still to do", W.placed - placedBefore == HOUSE_CELLS - 20,
        tostring(W.placed - placedBefore))
    local lastY, ordered = -1, true
    for _, e in ipairs(order) do
        if e.y < lastY then ordered = false end
        lastY = e.y
    end
    check("layer by layer from the bottom", ordered)
    local function indexOf(x, y, z)
        for i, e in ipairs(order) do
            if e.x == x and e.y == y and e.z == z then return i end
        end
    end
    local door, bench, torch = indexOf(4, 1, 3), indexOf(4, 1, 5), indexOf(3, 1, 6)
    local lastWall = 0
    for x = 2, 6 do for z = 3, 7 do
        if (x == 2 or x == 6 or z == 3 or z == 7) and not (x == 4 and z == 3) then lastWall = math.max(lastWall, indexOf(x, 1, z) or 0) end
    end end
    check("in a layer: the walls, then the stair, then the torch, then the door", lastWall > 0 and bench and torch and door and bench > lastWall and torch > bench and door > torch,
        table.concat({ lastWall, bench or -1, torch or -1, door or -1 }, " "))
    local diffs, vinfo = T.verify()
    check("verify with no plan checks the saved build: clean", diffs and #diffs == 0, diffs and (#diffs .. " differ"))
    check("...it looked at the cells with a state or never seen (stair, doors, torch... and the air)", vinfo.inspected > 0 and vinfo.checked > HOUSE_CELLS)
    local diffs2 = T.verify(HOUSE)
    check("verify with the plan: clean too", diffs2 and #diffs2 == 0)
    local ok2, why2, info2 = build(HOUSE)
    check("the same plan again after it finished starts afresh: every cell is found there, nothing more placed", ok2 == true and not info2.resumed
        and W.placed - placedBefore == HOUSE_CELLS - 20, tostring(why2))
end

-- A Ctrl+T in the middle of a cell
do
    fresh()
    stock(W)
    local n = 0
    local remove = T.onChange(function(e)
        if e.kind == "place" then
            n = n + 1
            if n == 30 then error("Terminated", 0) end
        end
    end)
    local okRun, err = pcall(build, HOUSE)
    check("a Ctrl+T in the middle stops the build with the error going on", okRun == false and tostring(err):find("Terminated", 1, true), tostring(err))
    local progress = fileText(".build.progress")
    check("...the progress was saved on the way out", progress and progress:find("done 29", 1, true), tostring(progress))
    remove()
    restart()
    local placedBefore = W.placed
    local ok, why = build()
    check("...and T.build() finishes it: the cell in hand was found there, not placed twice", ok == true and houseIsBuilt() and W.placed - placedBefore == HOUSE_CELLS - 30,
        tostring(why) .. " " .. tostring(W.placed - placedBefore))
    local diffs = T.verify()
    check("...verified clean", diffs and #diffs == 0)
end

--------------------------------------------------------------------------
-- Materials, cells that fail, one build at a time
--------------------------------------------------------------------------
local SLAB = "name: slab\nanchor: 2 0 3\nB = minecraft:stone_bricks\nlayer 1:\nBBBB\nBBBB\n"
do
    fresh()
    W.give(1, STONE, 10)
    T.registry.canCraft = nil                -- (no craft module: tl.craft's row is taken out, to see the plain refusal)
    local ok, why, info = build(SLAB)
    check("short of the material: refused before the turtle moves, nothing placed", ok == nil and why:find("short of", 1, true) and why:find("stone_bricks", 1, true)
        and why:find("need 8", 1, true) and why:find("have 0", 1, true) and W.placed == 0 and W.S.P.x == 0 and W.S.P.z == 0, tostring(why))
    check("...the info lists what is short", info and info.short and info.short[1].item == BRICKS and info.short[1].need == 8 and info.short[1].have == 0
        and info.short[1].short == 8)
    check("...no craft module loaded to ask, and no file left behind", CRAFTSTUB_LOADS == 0 and fileText(".build") == nil)
    T.registry.canCraft = "tl.craftstub"
    ok, why, info = build(SLAB)
    check("with a craft module registered it is asked what could be crafted, and says so", CRAFTSTUB_LOADS == 1 and info.short[1].craft == true
        and why:find("can be crafted", 1, true), tostring(why))
    ok, why = build("name: slab\nanchor: 2 0 3\nB = minecraft:stone\nlayer 1:\nBBBB\nBBBB\n")
    check("...and not asked when nothing is short", ok == true and CRAFTSTUB_LOADS == 1)
    T.registry.canCraft = nil
    -- the real craft module (registered in turtlelib by default): 10 stone on board make the 8 stone bricks
    fresh()
    W.give(1, STONE, 10)
    ok, why, info = build(SLAB)
    check("with the real tl.craft (the default registry): short 8 bricks, and 10 stone on board means it says they can be crafted",
        ok == nil and info.short[1].craft == true and why:find("can be crafted", 1, true) ~= nil and package.loaded["tl.craft"] ~= nil, tostring(why))
    fresh()
    W.give(1, STONE, 3)
    ok, why, info = build(SLAB)
    check("...and with 3 stone on board it is not offered: the craft module says false", ok == nil and info.short[1].craft == false and why:find("can be crafted", 1, true) == nil, tostring(why))
end
do
    fresh()
    W.give(1, STONE, 5)
    local plan = "name: slab\nanchor: 2 0 3\nB = minecraft:stone\nlayer 1:\nBBBB\nBBBB\n"
    local ok, why, info = build(plan, { partial = true })
    check("partial builds what it can; the cells with nothing left fail one by one, saying so", ok == false and info.done == 8 and #info.failed == 3
        and info.failed[1].why == "no minecraft:stone on board" and info.placed == 5, tostring(why))
    check("...the failed cells are in the info with where they are", info.failed[1].item == STONE and info.failed[1].x and info.failed[1].y == 0)
    W.give(2, STONE, 10)
    ok, why, info = build()
    check("more stone and T.build() tries the failed cells again, and finishes", ok == true and info.finished and #info.failed == 0 and info.placed == 3, tostring(why))
    local progress = fileText(".build.progress")
    check("...the failed list is gone from the progress file", progress and not progress:find("failed", 1, true), tostring(progress))
end
do
    fresh({ { 3, 0, 3, "minecraft:dirt" } })
    W.give(1, STONE, 20)
    local plan = "name: slab\nanchor: 2 0 3\nB = minecraft:stone\nlayer 1:\nBBBB\nBBBB\n"
    local ok, why, info = build(plan)
    check("a block in the way fails that cell, is not dug out, and the build goes on", ok == false and #info.failed == 1 and info.failed[1].why:find("minecraft:dirt is in the way", 1, true)
        and has(3, 0, 3, "dirt") and has(5, 0, 2, "stone") and info.placed == 7, tostring(why) .. info.placed .. tostring(has(3, 0, 3, "dirt")) .. tostring(has(5, 0, 2, "stone")))
    check("...the message names the cell and why", why:find("1 cells failed", 1, true) and why:find("3,0,3", 1, true), tostring(why))
    W.set(3, 0, 3, nil)
    ok, why = build()
    check("...cleared, the next run puts it in", ok == true and has(3, 0, 3, "stone"), tostring(why))
end
do
    fresh()
    W.give(1, STONE, 40)
    local a = "name: first\nanchor: 2 0 3\nB = minecraft:stone\nlayer 1:\nBBBB\nBBBB\n"
    local b = "name: second\nanchor: 2 0 9\nB = minecraft:stone\nlayer 1:\nBB\n"
    build(a, { limit = 3 })
    local ok, why = build(b)
    check("a different plan while one is unfinished is refused, naming it and what to do", ok == nil and why:find("\"first\" is unfinished", 1, true) and why:find("restart = true", 1, true)
        and not has(2, 0, 9, "stone"), tostring(why))
    ok, why = build(b, { restart = true })
    check("...unless restart: the new plan is built", ok == true and has(2, 0, 9, "stone") and has(3, 0, 9, "stone"), tostring(why))
    ok, why = build()
    check("T.build() then carries on the new one: it is finished", ok == true and fileText(".build"):find("name: second", 1, true), tostring(why))
    ok, why = build(a)
    check("a different plan after a finished build is simply built", ok == true and has(5, 0, 2, "stone"), tostring(why))
    fresh()
    ok, why = build()
    check("T.build() with nothing saved says so", ok == nil and why:find("no build in progress", 1, true), tostring(why))
    ok, why = build("layer 1:\nX\n")
    check("a plan with a bad legend or layers is refused with the reason", ok == nil and why ~= nil)
end
do
    -- a door written twice with no half in its state: the second is its upper half, not another door
    fresh()
    W.give(1, STONE, 20)
    W.give(2, "minecraft:oak_door", 3)
    local plan = "name: gate\nanchor: 2 0 5\nB = minecraft:stone\nd = minecraft:oak_door[facing=south]\nlayer 1:\nBBB\nlayer 2:\nBdB\nlayer 3:\nBdB\n"
    local ok, why, info = build(plan)
    check("a door cell over a cell of the same door is its upper half: one door placed, whole", ok == true and info.total == 8 and has(3, 1, 5, "oak_door", { half = "lower" })
        and has(3, 2, 5, "oak_door", { half = "upper" }) and W.carrying("minecraft:oak_door") == 2, tostring(why))
    -- the map's word is taken for a cell, unless opts.look
    W.set(2, 0, 5, nil)
    ok, why, info = build(plan)
    check("a plan built over itself takes the map's word for a cell: a block that has gone since is not seen", ok == true and info.placed == 0 and has(2, 0, 5, nil), tostring(why) .. tostring(info.placed) .. tostring(has(2, 0, 5, nil)))
    ok, why, info = build(plan, { look = true })
    check("...opts.look goes to look at each cell, and puts the missing one back", ok == true and info.placed == 1 and has(2, 0, 5, "stone"), tostring(why))
end
do
    -- opts.retry = false leaves the failed cells alone
    fresh()
    W.give(1, STONE, 3)
    local plan = "name: slab\nanchor: 2 0 3\nB = minecraft:stone\nlayer 1:\nBBBB\n"
    local ok, why, info = build(plan, { partial = true })
    check("a short build with partial: one cell failed", ok == false and #info.failed == 1)
    W.give(2, STONE, 5)
    ok, why, info = build(nil, { retry = false })
    check("opts.retry = false leaves the failed cell for later", ok == false and info.placed == 0 and #info.failed == 1, tostring(why))
    ok, why, info = build()
    check("...and a plain run tries it again", ok == true and info.placed == 1)
end
do
    fresh(nil, false)
    W.give(1, "minecraft:oak_stairs", 2)
    local p = "name: s\nanchor: 2 0 3\ns = minecraft:oak_stairs[facing=north]\nlayer 1:\ns\n"
    local ok, why = build(p)
    check("a plan naming a compass facing without the world origin is refused, nothing moved", ok == nil and why:find("T.setOrigin", 1, true) and W.placed == 0
        and W.S.P.x == 0, tostring(why))
    local q = "name: s\nanchor: 2 0 3\ns = minecraft:oak_stairs[half=top]\nlayer 1:\ns\n"
    ok, why = build(q)
    check("a half needs no origin", ok == true and has(2, 0, 3, "oak_stairs", { half = "top" }), tostring(why))
end
do
    fresh()
    W.give(1, STONE, 40)
    local slab = "name: pad\nanchor: 2 0 3\nB = minecraft:stone\nlayer 1:\nBBBB\nBBBB\n"
    local ok, why, info = build(slab, { limit = 2, protect = "keep" })
    check("an unfinished build is not protected", T.protected(2, 0, 3) == nil)
    ok, why, info = build(nil, { protect = "keep" })
    check("opts.protect = \"keep\" protects the finished build under the plan's name, over the cells the plan covers", ok == true and info.protected == "pad"
        and T.protected(2, 0, 3) == "pad" and T.protected(5, 0, 2) == "pad" and T.protected(6, 0, 3) == nil and T.protected(2, 1, 3) == nil, tostring(why))
    fresh()
    W.give(1, STONE, 40)
    ok, why, info = build(slab, { protect = "castle" })
    check("a name as opts.protect is the area's name", info.protected == "castle" and T.protected(3, 0, 3) == "castle")
    fresh()
    W.give(1, STONE, 40)
    T.protect("yard", 0, 0, 0, 9, 3, 9)
    ok, why = build(slab, { inside = "yard" })
    check("a build inside a protected area it owns works (walking and placing in it)", ok == true and has(5, 0, 2, "stone"), tostring(why))
    check("...and the job's ownership is put back", T.cfg.inside == nil)
    fresh()
    W.give(1, STONE, 40)
    T.protect("yard", 0, 0, 0, 9, 3, 9)
    local owned = {}
    T.onChange(function(e) if e.kind == "place" then owned[#owned + 1] = T.cfg.inside end end)
    build(slab, { inside = "yard" })
    check("...the area is the job's own for every placement", #owned == 8 and owned[1] == "yard" and owned[8] == "yard", #owned .. tostring(owned[1]))
end

--------------------------------------------------------------------------
-- T.verify
--------------------------------------------------------------------------
do
    fresh()
    stock(W)
    build(HOUSE)
    -- the stair turned the wrong way, behind the library's back
    W.set(4, 1, 5, "minecraft:oak_stairs", { facing = "west", half = "bottom", shape = "straight", waterlogged = false })
    local diffs, info = T.verify(HOUSE)
    check("a stair facing the wrong way is found, by its state (the map still has it as it was built)", diffs and #diffs == 1 and diffs[1].x == 4 and diffs[1].y == 1 and diffs[1].z == 5
        and diffs[1].why:find("facing=east", 1, true) and diffs[1].why:find("facing=west", 1, true), diffs and (#diffs .. " " .. tostring(diffs[1] and diffs[1].why)))
    check("...the entry says what was wanted and found", diffs[1].want == "minecraft:oak_stairs" and diffs[1].wantState.facing == "east" and diffs[1].found == "minecraft:oak_stairs"
        and diffs[1].foundState.facing == "west" and info.differing == 1)
    W.set(4, 1, 5, "minecraft:oak_stairs", { facing = "east", half = "bottom", shape = "straight", waterlogged = false })
    check("...and clean again once put right", #T.verify(HOUSE) == 0)

    W.set(2, 0, 3, "minecraft:dirt")
    check("a plain block swapped behind its back is not seen by the default check (the map is trusted for it)", #T.verify(HOUSE) == 0)
    local allDiffs = T.verify(HOUSE, { inspect = "all" })
    check("...but is by opts.inspect = \"all\", which looks at every cell", #allDiffs == 1 and allDiffs[1].x == 2 and allDiffs[1].y == 0 and allDiffs[1].z == 3
        and allDiffs[1].why:find("found minecraft:dirt", 1, true), #allDiffs .. tostring(allDiffs[1] and allDiffs[1].why))
    check("...and the map is right afterwards (the look wrote it)", T.map.get(2, 0, 3) == "minecraft:dirt")
    W.set(2, 0, 3, STONE)
    T.map.set(2, 0, 3, STONE)


    W.set(6, 2, 5, nil)
    T.map.set(6, 2, 5, "minecraft:air")
    local missing = T.verify(HOUSE)
    check("a missing block is found too", #missing == 1 and missing[1].x == 6 and missing[1].y == 2 and missing[1].why:find("found minecraft:air", 1, true), #missing)
    W.set(5, 0, 6, nil)
    T.map.set(5, 0, 6, "minecraft:air")
    local sorted = T.verify(HOUSE)
    check("the differences come low to high", #sorted == 2 and sorted[1].y == 0 and sorted[2].y == 2)
    check("a bad plan, or none saved, is refused with the reason", select(2, T.verify("layer 1:\nX\n")) ~= nil)
end
do
    fresh()
    stock(W)
    build(HOUSE)
    W.set(3, 1, 4, "minecraft:cobblestone")
    T.map.set(3, 1, 4, nil)
    local strays = T.verify(HOUSE)
    check("a block in a cell the plan wants empty, which the map has never seen, is found: such cells are looked at", #strays == 1 and strays[1].x == 3 and strays[1].z == 4
        and strays[1].why:find("wanted minecraft:air", 1, true) and strays[1].why:find("cobblestone", 1, true), #strays .. tostring(strays[1] and strays[1].why))
end
do
    local blocks = cube(4, -1, 4, 6, 1, 6, STONE)
    fresh(blocks)
    know(3, -2, 3, 7, 2, 7)
    local plain = "name: core\nanchor: 5 0 5\nB = minecraft:stone\nlayer 1:\nB\n"
    local diffs, info = T.verify(plain)
    check("the stone is as planned: the map knows it and there is no state, so it is not looked at", #diffs == 0 and info.inspected == 0)
    local state = "name: core\nanchor: 5 0 5\ns = minecraft:oak_stairs[facing=east]\nlayer 1:\ns\n"
    diffs, info = T.verify(state)
    check("a cell it must look at but cannot reach (every neighbour solid) is listed as unverified, with why", #diffs == 1 and diffs[1].unverified == true and info.unverified == 1
        and diffs[1].why:find("couldn't look at it", 1, true), tostring(diffs[1] and diffs[1].why))
    check("...none saved and none given", select(2, T.verify(nil)) ~= nil)
end
do
    fresh()
    stock(W)
    build(HOUSE)
    check("opts.at that is the anchor already: the same result", #T.verify(HOUSE, { at = { 2, 0, 7 } }) == 0)
    check("verified somewhere it was not built: nearly everything differs", #T.verify(HOUSE, { at = { 12, 0, 7 } }) > 50)
end
do
    check("a plan whose stair is in the map facing the other way does not count it as there: it is still to be bought", (function()
        fresh({ { 3, 0, 3, "minecraft:oak_stairs", { facing = "west", half = "bottom" } } })
        T.map.set(3, 0, 3, "minecraft:oak_stairs", { facing = "west", half = "bottom" })
        local ok, why = build("name: s\nanchor: 3 0 3\ns = minecraft:oak_stairs[facing=east]\nlayer 1:\ns\n")
        return ok == nil and why:find("short of oak_stairs", 1, true)
    end)())
end

--------------------------------------------------------------------------
-- T.replace
--------------------------------------------------------------------------
do
    fresh(cube(0, 0, 4, 2, 2, 6, STONE))
    know(-3, -3, 1, 5, 5, 9)
    W.give(1, BRICKS, 40)
    local ok, why, info = replace({ 0, 0, 4, 2, 2, 6 }, "minecraft:stone", BRICKS)
    check("a wall of blocks is swapped, each from a free side; the one inside is reported, not dug to", ok == false and info.replaced == 26 and #info.trapped == 1 and #info.failed == 0
        and info.trapped[1].x == 1 and info.trapped[1].y == 1 and info.trapped[1].z == 5 and has(1, 1, 5, "stone"), tostring(why) .. " " .. tostring(info and info.replaced))
    check("...the trapped one says why", info.trapped[1].why:find("no free side", 1, true) and info.trapped[1].name == STONE)
    local bricks = 0
    for x = 0, 2 do for y = 0, 2 do for z = 4, 6 do if has(x, y, z, "stone_bricks") then bricks = bricks + 1 end end end end
    check("...26 stone bricks in the cube, 14 left aboard", bricks == 26 and W.carrying(BRICKS) == 14)
    check("the dug stone came aboard", W.carrying(STONE) == 26)
    ok, why, info = replace({ 0, 0, 4, 2, 2, 6 }, "minecraft:stone", BRICKS)
    check("run again, only the one inside matches and it is still trapped", info.replaced == 0 and #info.trapped == 1)
    ok, why, info = replace({ 0, 0, 4, 2, 2, 6 }, "stone_bricks", BRICKS)
    check("blocks already of the item are left (counted as same); a glob without the namespace matches", info.same == 26 and info.replaced == 0 and ok == true)
end
do
    fresh(cube(0, 0, 4, 2, 0, 4, STONE))
    know(-3, -3, 1, 5, 5, 9)
    W.give(1, BRICKS, 10)
    T.protect("keep", 0, 0, 4, 2, 0, 4)
    local ok, why, info = replace({ 0, 0, 4, 2, 0, 4 }, "stone", BRICKS)
    check("a protected area refuses the digs: every block fails with the area named, nothing swapped", ok == false and info.replaced == 0 and #info.failed == 3
        and info.failed[1].why:find("protected: keep", 1, true) and has(1, 0, 4, "stone"), tostring(why) .. " " .. tostring(info.failed[1] and info.failed[1].why))
    ok, why, info = replace({ 0, 0, 4, 2, 0, 4 }, "stone", BRICKS, { inside = "keep" })
    check("opts.inside names the area the job owns: swapped", ok == true and info.replaced == 3 and has(1, 0, 4, "stone_bricks"), tostring(why))
    check("...and the area still holds for anything else afterwards", T.cfg.inside == nil and T.protected(1, 0, 4) == "keep")
end
do
    fresh(cube(0, 0, 4, 2, 0, 4, STONE))
    know(-3, -3, 1, 5, 5, 9)
    W.give(1, "minecraft:oak_stairs", 5)
    local ok, why, info = replace({ 0, 0, 4, 2, 0, 4 }, "stone", "oak_stairs[facing=east,half=bottom]")
    local good = ok == true and info.replaced == 3
    for x = 0, 2 do good = good and has(x, 0, 4, "oak_stairs", { facing = "east", half = "bottom" }) end
    check("a block with a state is put through placeAt for that state", good, tostring(why))

    fresh(cube(0, 0, 4, 2, 0, 4, STONE))
    know(-3, -3, 1, 5, 5, 9)
    W.give(1, BRICKS, 2)
    ok, why, info = replace({ 0, 0, 4, 2, 0, 4 }, "stone", BRICKS)
    check("short of the new block: refused before any move, nothing dug", ok == nil and why:find("short of stone_bricks", 1, true) and why:find("3 blocks to swap, have 2", 1, true)
        and has(0, 0, 4, "stone") and (W.dug or 0) == 0, tostring(why))
    ok, why, info = replace({ 0, 0, 4, 2, 0, 4 }, "stone", BRICKS, { partial = true })
    check("partial swaps as many as it has; the rest fail one by one", ok == false and info.replaced == 2 and #info.failed == 1 and info.failed[1].why:find("no minecraft:stone_bricks left", 1, true),
        tostring(why))

    fresh(cube(0, 0, 4, 2, 0, 4, STONE))
    know(-3, -3, 1, 5, 5, 9)
    W.set(1, 0, 4, nil)
    W.give(1, BRICKS, 5)
    ok, why, info = replace({ 0, 0, 4, 2, 0, 4 }, "stone", BRICKS)
    check("a block gone since the map saw it is not placed into; the map is corrected and it is counted as gone", ok == true and info.gone == 1 and info.replaced == 2 and has(1, 0, 4, nil)
        and T.map.get(1, 0, 4) == "minecraft:air", tostring(why))
    -- the map says stone but another block is there now
    fresh(cube(0, 0, 4, 2, 0, 4, STONE))
    know(-3, -3, 1, 5, 5, 9)
    W.set(1, 0, 4, "minecraft:dirt")
    W.give(1, BRICKS, 5)
    ok, why, info = replace({ 0, 0, 4, 2, 0, 4 }, "stone", BRICKS)
    check("a block changed to another since the map saw it is left; the map is corrected", ok == true and info.gone == 1 and info.replaced == 2 and has(1, 0, 4, "dirt")
        and T.map.get(1, 0, 4) == "minecraft:dirt", tostring(why))
    check("a bad glob or block is refused", select(2, replace({ 0, 0, 4, 2, 0, 4 }, "", BRICKS)) ~= nil and select(2, replace({ 0, 0, 4, 2, 0, 4 }, "stone", "stone[x")) ~= nil)
    check("a bad box is refused", select(2, replace({ 0, 0, 4 }, "stone", BRICKS)) ~= nil)
end

--------------------------------------------------------------------------
-- Blocks whose item has another name, double slabs, and a named plan carried on
--------------------------------------------------------------------------
do
    local STONE_ = "minecraft:stone"
    local text = require("text")
    fresh()
    W.fill(-2, -1, 1, 2, -1, 5, STONE_)
    W.fill(-2, 0, 5, 2, 1, 5, STONE_)          -- a wall to the north
    know(-4, -3, -4, 4, 4, 6)
    W.give(1, "minecraft:torch", 8)
    local plan = assert(T.blueprint.new({ anchor = { 0, 0, 4 }, legend = { t = "minecraft:torch[facing=south]" }, layers = { "t" } }))
    local ok, why = build(plan)
    check("a torch with a facing builds as a wall torch", ok == true and has(0, 0, 4, "wall_torch", { facing = "south" }), tostring(why))
    local diffs = T.verify(plan, { inspect = "all" })
    check("...and verifies clean: a wall_torch is the torch the plan asked for", diffs and #diffs == 0,
        diffs and diffs[1] and diffs[1].why or "nil")
    local copy = assert(T.blueprint.fromMap({ 0, 0, 4, 0, 0, 4 }))
    check("T.blueprint.fromMap writes the item, a torch facing south, not the block", text.contains(T.blueprint.format(copy), "minecraft:torch[facing=south]"),
        T.blueprint.format(copy))
    W.set(0, 0, 4, nil)
    T.map.set(0, 0, 4, "minecraft:air")
    ok, why = build(copy, { restart = true })
    check("...and that plan builds again", ok == true and has(0, 0, 4, "wall_torch", { facing = "south" }), tostring(why))

    fresh()
    W.fill(-2, -1, 1, 2, -1, 5, STONE_)
    know(-4, -3, -4, 4, 4, 6)
    W.give(1, "minecraft:oak_slab", 1)
    local double = assert(T.blueprint.new({ anchor = { 0, 0, 3 }, legend = { d = "minecraft:oak_slab[type=double]" }, layers = { "d" } }))
    ok, why = build(double)
    check("a double slab counts two slabs", ok == nil and text.contains(tostring(why), "need 2, have 1"), tostring(why))
    W.give(1, "minecraft:oak_slab", 4)
    ok, why = build(double)
    check("...and builds as a bottom half with a second slab on it", ok == true and has(0, 0, 3, "oak_slab", { type = "double" }), tostring(why))
    diffs = T.verify(double, { inspect = "all" })
    check("...which verifies clean", diffs and #diffs == 0, diffs and diffs[1] and diffs[1].why or "nil")

    fresh()
    W.fill(-2, -1, 1, 2, -1, 5, STONE_)
    know(-4, -3, -4, 4, 4, 6)
    W.give(1, "minecraft:cobblestone", 64)
    local hut = assert(T.blueprint.fill(-1, 0, 2, 1, 0, 4, "cobblestone"))
    build(hut, { name = "hut", limit = 3 })
    ok, why = build(hut, { name = "hut" })
    check("the same plan with the same name carries on (opts.name)", ok == true and has(1, 0, 4, "cobblestone"), tostring(why))
end
