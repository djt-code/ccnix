-- sim/turtlelib_place.lua
--
-- tl.place (ADR-0008 phase 3): blocks placed with the state wanted, on sim/lib/buildworld's mock world, which
-- follows the game's placing rules (so a wrong row of the module's table shows up here before it does in game).
--   * stairs and slabs each way: sideways always the bottom half, facing the heading; placeDown the bottom half
--     iff there is a block under the target; placeUp the top half iff there is a block over it; in each of
--     the four facings and in a world whose heading 0 is not north;
--   * a log's axis (standing, lying along the heading, lying across); a torch on a wall (both ways round, one
--     reached by a route round the support) and standing; a ladder, button, lever, trapdoor, fence gate, chest;
--   * a door: the cell above free, a block below, set into a gap in a wall; refused otherwise, without moving;
--   * the table wrong about a row: the retry gets it right, the wrong block is dug out (in a protected area too),
--     the correction is kept in .placements, used from then on and after a restart; a wrong guess on a map
--     that does not know the surroundings is not learnt from; the table wrong about a facing rule;
--   * what it refuses: a cell in use, no item, a state the family has no key for, a facing without the
--     world origin; a cell that already holds the block as wanted is left alone;
--   * T.ignite: a fire from above, refused with no flint and steel, nothing solid under, a block in the cell.
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
local W, T                                  -- the world, the library

-- A new world with the turtle at 0,0,0 (heading 0 is `facing`), the library loaded afresh and (unless origin is
-- false) told which way the frame points; then the blocks of the scene: { x, y, z, name, state }.
local function fresh(facing, blocks, origin)
    facing = facing or "north"
    W = B.new({ facing = facing })
    W.install()
    CLK = 0
    for _, name in ipairs({ "turtlelib", "tl.world", "tl.path", "tl.place" }) do package.loaded[name] = nil end
    T = require("turtlelib")
    for _, b in ipairs(blocks or {}) do W.set(b[1], b[2], b[3], b[4], b[5]) end
    if origin ~= false then T.setOrigin(0, 0, 0, facing) end
    return W, T
end
-- A restart of the computer, the disk and the world as they are: the library loaded afresh, the turtle where it is.
local function restart()
    local p, d = { W.S.P.x, W.S.P.y, W.S.P.z }, W.S.P.d
    for _, name in ipairs({ "turtlelib", "tl.world", "tl.path", "tl.place" }) do package.loaded[name] = nil end
    T = require("turtlelib")
    T.pos.x, T.pos.y, T.pos.z, T.dir = p[1], p[2], p[3], d
    T.savePos()
    return T
end
-- Teach the map every cell of a box, as a perfect scan would.
local function know(x1, y1, z1, x2, y2, z2)
    for x = x1, x2 do for y = y1, y2 do for z = z1, z2 do
        local b = W.get(x, y, z)
        T.map.set(x, y, z, b and b.name or "minecraft:air", b and b.state or nil)
    end end end
end
local function knowAll() know(-4, -3, -4, 4, 4, 6) end
local function has(x, y, z, name, state)
    local b = W.get(x, y, z)
    if not name then return b == nil end
    if not b or b.name ~= "minecraft:" .. name then return false end
    for k, v in pairs(state or {}) do
        if b.state[k] ~= v then return false end
    end
    return true
end
local function stone(x, y, z) return { x, y, z, STONE } end
local function learnedText()
    local f = fs.open(T.dataPath(".placements"), "r")
    if not f then return nil end
    local s = f.readAll()
    f.close()
    return s
end
local function atCell(x, y, z) return T.pos.x == x and T.pos.y == y and T.pos.z == z and W.S.P.x == x and W.S.P.y == y and W.S.P.z == z end

-- A scene: blocks about, the item (a stack of 8), the target, the options; then what the world holds at the target.
-- expect: a list of { x, y, z, name, state } (name nil: nothing); approach: where it should place from.
local function scene(label, s)
    fresh(s.facing, s.blocks, s.origin)
    if s.know ~= false then knowAll() end
    W.give(1, s.item, 8)
    local at = s.at or { 0, 0, 3 }
    local name, state, how = T.placeAt(at[1], at[2], at[3], s.item, s.opts)
    local good = name ~= nil
    for _, e in ipairs(s.expect or {}) do good = good and has(e[1], e[2], e[3], e[4], e[5]) end
    if good and s.approach then good = how.approach == s.approach end
    if good and s.from then good = how.from.x == s.from[1] and how.from.y == s.from[2] and how.from.z == s.from[3] end
    local shown = at[1] .. "," .. at[2] .. "," .. at[3]
    local detail
    if not good then
        detail = "got " .. tostring(name) .. " at " .. shown .. ": " .. W.show(at[1], at[2], at[3])
            .. (how and (" via " .. tostring(how.approach)) or (" (" .. tostring(state) .. ")"))
    end
    check(label, good, detail)
    return W, T, how
end

--------------------------------------------------------------------------
-- Stairs: facing the heading, the half by the block below or over the target
--------------------------------------------------------------------------
local ST = "minecraft:oak_stairs"
local SL = "minecraft:oak_slab"
local DIRS = { { "north", 0, 0, 1 }, { "east", 1, 0, 0 }, { "south", 0, 0, -1 }, { "west", -1, 0, 0 } }
for _, d in ipairs(DIRS) do
    -- (a block beyond the target on the far side of the way it faces)
    scene("stairs facing " .. d[1] .. " with a block beyond: sideways, bottom half, facing as the turtle does", {
        item = ST, blocks = { stone(0 + d[2] * 1, 0, 3 + d[4] * 1) }, opts = { facing = d[1], half = "bottom" },
        expect = { { 0, 0, 3, "oak_stairs", { facing = d[1], half = "bottom" } } }, approach = "front",
        from = { -d[2], 0, 3 - d[4] } })
end
scene("stairs top half in the open: placeDown with nothing below the target", {
    item = ST, opts = { facing = "north", half = "top" },
    expect = { { 0, 0, 3, "oak_stairs", { facing = "north", half = "top" } } }, approach = "down" })
scene("stairs top half with a block over the target (and over the cell above, so not from above): placeUp, a block above", {
    item = ST, blocks = { stone(0, 1, 3) }, opts = { facing = "north", half = "top" },
    expect = { { 0, 0, 3, "oak_stairs", { facing = "north", half = "top" } } }, approach = "up" })
scene("stairs bottom half with a block under the target: bottom half, facing north", {
    item = ST, blocks = { stone(0, -1, 3) }, opts = { facing = "north", half = "bottom" },
    expect = { { 0, 0, 3, "oak_stairs", { facing = "north", half = "bottom" } } } })
scene("stairs bottom half over a block, the way sideways is blocked: placeDown with a block below", {
    item = ST, blocks = { stone(0, -1, 3), stone(0, 0, 2), stone(0, 0, 4), stone(1, 0, 3), stone(-1, 0, 3) },
    opts = { facing = "north", half = "bottom" },
    expect = { { 0, 0, 3, "oak_stairs", { facing = "north", half = "bottom" } } }, approach = "down" })
scene("stairs bottom half with nothing about: any way gives it, facing east", {
    item = ST, opts = { facing = "east", half = "bottom" },
    expect = { { 0, 0, 3, "oak_stairs", { facing = "east", half = "bottom" } } } })
scene("stairs top half facing west in a world whose heading 0 is east: the compass is the origin's", {
    facing = "east", item = ST, blocks = { stone(0, 1, 3) }, opts = { facing = "west", half = "top" },
    expect = { { 0, 0, 3, "oak_stairs", { facing = "west", half = "top" } } }, approach = "up" })
scene("stairs facing south in a world whose heading 0 is east, a block beyond along the way it goes: a right turn", {
    facing = "east", item = ST, blocks = { stone(1, 0, 3) }, opts = { facing = "south", half = "bottom" },
    expect = { { 0, 0, 3, "oak_stairs", { facing = "south", half = "bottom" } } }, approach = "front", from = { -1, 0, 3 } })
scene("stairs with no state asked for: placed, whatever way is nearest", {
    item = ST, blocks = { stone(0, 0, 4) }, expect = { { 0, 0, 3, "oak_stairs" } }, approach = "front" })

--------------------------------------------------------------------------
-- Slabs
--------------------------------------------------------------------------
scene("slab top half in the open: placeDown, nothing below", {
    item = SL, opts = { half = "top" }, expect = { { 0, 0, 3, "oak_slab", { type = "top" } } }, approach = "down" })
scene("slab bottom half with a block under it: bottom", {
    item = SL, blocks = { stone(0, -1, 3), stone(0, 1, 3) }, opts = { half = "bottom" },
    expect = { { 0, 0, 3, "oak_slab", { type = "bottom" } } } })
scene("slab top half with a block over it: placeUp, a block above", {
    item = SL, blocks = { stone(0, 1, 3) }, opts = { half = "top" },
    expect = { { 0, 0, 3, "oak_slab", { type = "top" } } }, approach = "up" })
scene("slab sideways is always the bottom half", {
    item = SL, blocks = { stone(0, 0, 4), stone(0, 1, 3), stone(0, -1, 3) }, opts = { half = "bottom" },
    expect = { { 0, 0, 3, "oak_slab", { type = "bottom" } } } })
scene("a slab's top half where nothing is above or below can still be had (from above)", {
    item = SL, blocks = { stone(0, 0, 4) }, opts = { half = "top" },
    expect = { { 0, 0, 3, "oak_slab", { type = "top" } } }, approach = "down" })

--------------------------------------------------------------------------
-- Logs: the axis of the face clicked
--------------------------------------------------------------------------
local LOG = "minecraft:oak_log"
scene("a standing log in the open: from above, axis y", {
    item = LOG, opts = { axis = "y" }, expect = { { 0, 0, 3, "oak_log", { axis = "y" } } } })
scene("a log lying along z (north-south) onto a block beyond", {
    item = LOG, blocks = { stone(0, 0, 4) }, opts = { axis = "z" },
    expect = { { 0, 0, 3, "oak_log", { axis = "z" } } }, approach = "front" })
scene("a log lying along x onto a block beyond to the east (the turtle comes at it from the west)", {
    item = LOG, blocks = { stone(1, 0, 3) }, opts = { axis = "x" },
    expect = { { 0, 0, 3, "oak_log", { axis = "x" } } }, approach = "front", from = { -1, 0, 3 } })
scene("a log standing with a floor to click: axis y", {
    item = LOG, blocks = { stone(0, -1, 3) }, opts = { axis = "y" }, expect = { { 0, 0, 3, "oak_log", { axis = "y" } } } })
scene("an x log in a world whose heading 0 is east: the compass's x is the turtle's z", {
    facing = "east", item = LOG, blocks = { stone(0, 0, 4), stone(1, 0, 3) }, opts = { axis = "x" },
    expect = { { 0, 0, 3, "oak_log", { axis = "x" } } } })
scene("a log across a hole: lying along x with nothing to click is the turtle's own block, along the heading", {
    item = LOG, opts = { axis = "z" }, expect = { { 0, 0, 3, "oak_log", { axis = "z" } } } })

--------------------------------------------------------------------------
-- Torches, ladders, buttons and levers: hung on the block beyond
--------------------------------------------------------------------------
local TORCH = "minecraft:torch"
scene("a torch on a wall beyond: a wall torch facing back at the turtle", {
    item = TORCH, blocks = { stone(0, 0, 4) }, opts = { facing = "south" },
    expect = { { 0, 0, 3, "wall_torch", { facing = "south" } } }, approach = "front", from = { 0, 0, 2 } })
scene("a torch facing north needs its wall to the south: the turtle goes round the wall to the north side", {
    item = TORCH, blocks = { stone(0, 0, 2) }, opts = { facing = "north" },
    expect = { { 0, 0, 3, "wall_torch", { facing = "north" } } }, approach = "front", from = { 0, 0, 4 } })
scene("a torch with a floor and nothing else: it stands", {
    item = TORCH, blocks = { stone(0, -1, 3) }, expect = { { 0, 0, 3, "torch" } } })
scene("a torch with a wall on a side and no facing asked: the nearest wall will do", {
    item = TORCH, blocks = { stone(1, 0, 3) }, expect = { { 0, 0, 3, "wall_torch", { facing = "west" } } } })
do
    fresh(nil, { })
    knowAll()
    W.give(1, TORCH, 4)
    local name, why = T.placeAt(0, 0, 3, TORCH, { facing = "north" })
    check("a torch with nothing to hang on: refused and the table says why", name == nil and why:find("no way to place", 1, true) ~= nil
        and W.get(0, 0, 3) == nil and atCell(0, 0, 0), tostring(why))
end
do
    fresh(nil, { stone(0, 0, 4) })
    knowAll()
    W.give(1, TORCH, 4)
    T.placeAt(0, 0, 3, TORCH, { facing = "south" })
    check("a wall torch placed as the table says leaves nothing in .placements", learnedText() == nil, tostring(learnedText()))
    fresh(nil, { { 0, 0, 4, "minecraft:oak_fence" } })
    knowAll()
    W.give(1, TORCH, 4)
    local name, why = T.placeAt(0, 0, 3, TORCH, { facing = "south" })
    check("a torch will not be hung on a fence (clickable but nothing to hold it): no approach, no move",
        name == nil and why:find("no way to place", 1, true) and atCell(0, 0, 0) and W.get(0, 0, 3) == nil, tostring(why))
end
scene("a ladder on the block beyond, facing back", {
    item = "minecraft:ladder", blocks = { stone(0, 0, 4) }, opts = { facing = "south" },
    expect = { { 0, 0, 3, "ladder", { facing = "south" } } }, approach = "front" })
scene("a button on a wall beyond", {
    item = "minecraft:stone_button", blocks = { stone(0, 0, 4) }, opts = { face = "wall", facing = "south" },
    expect = { { 0, 0, 3, "stone_button", { face = "wall", facing = "south" } } } })
scene("a lever on the floor, from above", {
    item = "minecraft:lever", blocks = { stone(0, -1, 3) }, opts = { face = "floor" },
    expect = { { 0, 0, 3, "lever", { face = "floor" } } } })

--------------------------------------------------------------------------
-- Doors, trapdoors, gates, chests
--------------------------------------------------------------------------
local DOOR = "minecraft:oak_door"
scene("a door with a floor and the cell above free: both halves, facing as wanted", {
    item = DOOR, blocks = { stone(0, -1, 3) }, opts = { facing = "north" },
    expect = { { 0, 0, 3, "oak_door", { facing = "north", half = "lower" } }, { 0, 1, 3, "oak_door", { half = "upper" } } },
    approach = "front" })
scene("a door set into a gap in a wall (the walls first), facing north", {
    item = DOOR, blocks = { stone(-1, 0, 3), stone(-1, 1, 3), stone(1, 0, 3), stone(1, 1, 3), stone(0, -1, 3), stone(0, 2, 3) },
    opts = { facing = "north" },
    expect = { { 0, 0, 3, "oak_door", { facing = "north", half = "lower" } }, { 0, 1, 3, "oak_door", { half = "upper" } } } })
do
    fresh(nil, { stone(0, 1, 3), stone(0, -1, 3) })
    knowAll()
    W.give(1, DOOR, 2)
    local name, why = T.placeAt(0, 0, 3, DOOR, {})
    check("a door with a block in the cell above: refused for that, without moving", name == nil and why:find("above", 1, true) ~= nil
        and atCell(0, 0, 0) and W.get(0, 0, 3) == nil, tostring(why))
    fresh(nil, {})
    knowAll()
    W.give(1, DOOR, 2)
    name, why = T.placeAt(0, 0, 3, DOOR, {})
    check("a door with air under it: refused for that, without moving", name == nil and why:find("solid block under", 1, true) ~= nil
        and atCell(0, 0, 0), tostring(why))
end
scene("a trapdoor top half in the open: from above, nothing below", {
    item = "minecraft:oak_trapdoor", opts = { half = "top" }, expect = { { 0, 0, 3, "oak_trapdoor", { half = "top" } } }, approach = "down" })
scene("a trapdoor bottom half with a floor under it", {
    item = "minecraft:oak_trapdoor", blocks = { stone(0, -1, 3) }, opts = { half = "bottom" },
    expect = { { 0, 0, 3, "oak_trapdoor", { half = "bottom" } } } })
scene("a fence gate facing east with a floor under it", {
    item = "minecraft:oak_fence_gate", blocks = { stone(0, -1, 3) }, opts = { facing = "east" },
    expect = { { 0, 0, 3, "oak_fence_gate", { facing = "east" } } } })
scene("a chest facing back at a turtle that comes from the south", {
    item = "minecraft:chest", blocks = { stone(0, -1, 3) }, opts = { facing = "south" },
    expect = { { 0, 0, 3, "chest", { facing = "south" } } } })
scene("a plain block needs no state: placed", { item = STONE, expect = { { 0, 0, 3, "stone" } } })

--------------------------------------------------------------------------
-- A table that is wrong about a row: corrected by the retry, remembered
--------------------------------------------------------------------------
do
    -- the table says placeDown with nothing under the target gives the bottom half; the game gives the top
    local blocks = { }
    fresh(nil, blocks)
    knowAll()
    W.give(1, ST, 4)
    T.need("placeAt")
    T.PLACE_TABLE.stairs.down[2].set.half = "bottom"
    local name, state, how = T.placeAt(0, 0, 3, ST, { facing = "north", half = "bottom" })
    check("a wrong row of the table: the first try comes out the top half, is dug out, and the next approach gets it right",
        name == "minecraft:oak_stairs" and state.half == "bottom" and state.facing == "north" and how.tries >= 2
        and has(0, 0, 3, "oak_stairs", { half = "bottom", facing = "north" }))
    check("the stairs the wrong try dug up came back: one stair used", W.carrying(ST) == 3 and W.dug == 1)
    local text_ = learnedText()
    check("what the game gave is kept in .placements", text_ == "stairs down always half=top\n", tostring(text_))
    local name2, state2, how2 = T.placeAt(0, 0, 6, ST, { facing = "north", half = "bottom" })
    check("a second placement in the same session uses the correction: first try right", name2 and how2.tries == 1
        and state2.half == "bottom", tostring(how2 and how2.tries))
    -- a restart, the table wrong again the same way (as if the module's table were wrong): the file corrects it
    restart()
    knowAll()
    W.give(2, ST, 4)
    T.need("placeAt")
    T.PLACE_TABLE.stairs.down[2].set.half = "bottom"
    W.dug = 0
    local name3, state3, how3 = T.placeAt(0, 0, -3, ST, { facing = "north", half = "bottom" })
    check("after a restart the file still corrects the table: first try right, nothing dug", name3 and how3.tries == 1
        and W.dug == 0 and state3.half == "bottom", tostring(how3 and how3.tries))
    -- and asking for the half the corrected row now gives
    local name4, state4 = T.placeAt(0, 0, 9, ST, { half = "top" })
    check("the corrected row gives the top half now: from above, nothing under the target", name4 and state4.half == "top")
end
do
    -- a wrong guess on a map that knows nothing: not learnt from
    fresh(nil, {})
    W.give(1, ST, 4)
    T.need("placeAt")
    T.PLACE_TABLE.stairs.down[2].set.half = "bottom"
    T.PLACE_TABLE.stairs.front[3].set.half = "bottom"
    local name, state, how = T.placeAt(0, 0, 3, ST, { facing = "north", half = "bottom" })
    check("the same wrong row with a map that has never seen the cells: still gets it right", name ~= nil and state.half == "bottom")
    check("...but a guess is not learnt from (the facts were unknown)", learnedText() == nil, tostring(learnedText()))
end
do
    -- a wrong facing rule: the table says a block below the target gives the stair facing back; the game gives the heading
    fresh(nil, { stone(0, -1, 3), stone(0, 0, 4), stone(0, 0, 2), stone(1, 0, 3), stone(-1, 0, 3) })
    knowAll()
    W.give(1, ST, 4)
    T.need("placeAt")
    T.PLACE_TABLE.stairs.down[1].set.facing = "back"
    local name, state, how = T.placeAt(0, 0, 3, ST, { facing = "north", half = "bottom" })
    check("a wrong facing rule (back for heading): the stair faced the wrong way, was dug out, and the heading found",
        name and state.facing == "north" and how.tries == 2 and how.approach == "down", tostring(how and how.tries))
    check("the correction is a rule relative to the heading, not a compass name", learnedText() == "stairs down beyond facing=heading\n",
        tostring(learnedText()))
end

do
    -- the rules relative to the heading: which heading the first try is made with says what they mean
    for _, c in ipairs({ { "right", 0 }, { "left", 2 }, { "back", 3 }, { "heading", 1 } }) do
        -- (the sides are blocked, so only placing from above is left)
        fresh(nil, { stone(0, -1, 3), stone(0, 0, 2), stone(0, 0, 4), stone(1, 0, 3), stone(-1, 0, 3) })
        knowAll()
        W.give(1, ST, 4)
        T.need("placeAt")
        T.PLACE_TABLE.stairs.down[1].set.facing = c[1]
        local first
        T.onChange(function(e) if e.kind == "place" and not first then first = T.dir end end)
        local name, state = T.placeAt(0, 0, 3, ST, { facing = "east", half = "bottom" })
        check("a row that says facing=" .. c[1] .. " is tried with the heading that gives east (" .. c[2] .. ")", first == c[2] and name ~= nil
            and state.facing == "east", tostring(first))
    end
end

--------------------------------------------------------------------------
-- A wrong try in a protected area: the library's own work, so the dig is allowed
--------------------------------------------------------------------------
do
    fresh(nil, {})
    knowAll()
    W.give(1, ST, 4)
    T.need("placeAt")
    T.PLACE_TABLE.stairs.down[2].set.half = "bottom"
    T.protect("keep", -2, -2, 1, 2, 3, 5)
    local name, state, how = T.placeAt(0, 0, 3, ST, { facing = "north", half = "bottom" })
    check("a wrong try inside a protected area is dug out all the same: it is the library's own block",
        name and state.half == "bottom" and how.tries >= 2 and has(0, 0, 3, "oak_stairs", { half = "bottom" }))
    check("the area still holds for a dig of anything else", (function()
        local ok, why = turtle.digDown()
        W.set(T.pos.x, T.pos.y - 1, T.pos.z, STONE)
        ok, why = turtle.digDown()
        return ok == false and why == "protected: keep"
    end)())
    check("T.cfg.inside and digContainers are as they were", T.cfg.inside == nil and not T.cfg.digContainers)
end
do
    -- opts.inside: the job walks and digs in the area it owns
    fresh(nil, { stone(0, 0, 1) })
    knowAll()
    W.give(1, STONE, 2)
    T.protect("keep", -2, -2, 0, 2, 3, 5)
    local name, why = T.placeAt(0, 0, 3, STONE, { inside = "keep", move = { dig = true } })
    check("opts.inside lets the job's moves dig a block in the way in its own area", name and has(0, 0, 3, "stone") and T.cfg.inside == nil
        and has(0, 0, 1), tostring(why))
    fresh(nil, { stone(0, 0, 1) })
    knowAll()
    W.give(1, STONE, 2)
    T.protect("keep", -2, -2, 0, 2, 3, 5)
    name = T.placeAt(0, 0, 3, STONE, { move = { dig = true } })
    check("...and without it the area holds: the stone stays, the block goes in another way", name and not has(0, 0, 1))
end

--------------------------------------------------------------------------
-- What it refuses
--------------------------------------------------------------------------
do
    fresh(nil, { stone(0, 0, 3) })
    knowAll()
    W.give(1, ST, 4)
    local name, why = T.placeAt(0, 0, 3, ST, { half = "bottom" })
    check("a cell holding another block is refused (nothing dug, no move)", name == nil and why:find("in the way", 1, true) and has(0, 0, 3, "stone")
        and atCell(0, 0, 0), tostring(why))
    fresh(nil, { stone(0, 0, 3) })
    W.give(1, ST, 4)
    name, why = T.placeAt(0, 0, 3, ST, { half = "bottom" })
    check("...also when the map has never seen it: found when the turtle gets there, and still left alone",
        name == nil and why:find("in the way", 1, true) and has(0, 0, 3, "stone"), tostring(why))
    fresh(nil, {})
    knowAll()
    name, why = T.placeAt(0, 0, 3, ST, { half = "bottom" })
    check("no item on board: say so", name == nil and why == "no minecraft:oak_stairs on board", tostring(why))
    W.give(1, LOG, 2)
    name, why = T.placeAt(0, 0, 3, LOG, { facing = "north" })
    check("a state the family has no key for: says what it has", name == nil and why:find("no facing", 1, true) and why:find("axis", 1, true),
        tostring(why))
    name, why = T.placeAt(0, 0, 3, LOG, { axis = "z", facing = "north" })
    check("...for any of the keys asked", name == nil)
    W.give(2, ST, 2)
    name, why = T.placeAt(0, 0, 3, ST, { facing = "up" })
    check("a facing that isn't a compass name", name == nil and why:find("compass name", 1, true), tostring(why))
    name, why = T.placeAt(1.5, 0, 3, ST, {})
    check("a cell that isn't whole numbers", name == nil and why:find("whole numbers", 1, true))
    fresh(nil, {}, false)
    W.give(1, ST, 2)
    name, why = T.placeAt(0, 0, 3, ST, { facing = "north" })
    check("a facing without the world origin: says to set it, and does nothing", name == nil and why:find("T.setOrigin", 1, true)
        and atCell(0, 0, 0) and W.get(0, 0, 3) == nil, tostring(why))
    name, why = T.placeAt(0, 0, 3, ST, { half = "top" })
    check("a half needs no origin", name ~= nil and has(0, 0, 3, "oak_stairs", { half = "top" }), tostring(why))
end
do
    -- already there: left alone
    fresh(nil, { { 0, 0, 3, ST, { facing = "north", half = "bottom", shape = "straight", waterlogged = false } } })
    knowAll()
    W.give(1, ST, 4)
    local name, state, how = T.placeAt(0, 0, 3, ST, { facing = "north", half = "bottom" })
    check("a stair already there as wanted comes back as it is, nothing placed", name == "minecraft:oak_stairs" and how.approach == "already there"
        and W.placed == 0 and W.carrying(ST) == 4, tostring(how and how.approach))
    name, state = T.placeAt(0, 0, 3, ST, { facing = "south", half = "bottom" })
    check("...but one facing the other way is not touched: it is in the way", name == nil and has(0, 0, 3, "oak_stairs", { facing = "north" }))
end
do
    -- the position follows the placement; the map is told what is there
    fresh(nil, { stone(0, 0, 4) })
    knowAll()
    W.give(1, TORCH, 4)
    T.placeAt(0, 0, 3, TORCH, { facing = "south" })
    check("the library's position is the turtle's after the walk and the placement", atCell(0, 0, 2))
    local n = T.map.get(0, 0, 3)
    check("the map holds the wall torch (not the item's name)", n == "minecraft:wall_torch", tostring(n))
    local _, st = T.map.get(0, 0, 3)
    check("...with its state", st and st.facing == "south", tostring(st and st.facing))
end

--------------------------------------------------------------------------
-- T.ignite
--------------------------------------------------------------------------
local FLINT = "minecraft:flint_and_steel"
do
    fresh(nil, { { 0, -1, 3, "minecraft:netherrack" } })
    knowAll()
    W.give(1, FLINT, 1)
    local name, was = T.ignite(0, 0, 3)
    check("ignite: fire in the cell, lit from above", name == "minecraft:fire" and was == false and has(0, 0, 3, "fire") and atCell(0, 1, 3),
        tostring(name) .. tostring(was))
    check("...the flint and steel is still there, and the map has the fire", W.carrying(FLINT) == 1 and T.map.get(0, 0, 3) == "minecraft:fire")
    name, was = T.ignite(0, 0, 3)
    check("ignite again: already burning, nothing used", name == "minecraft:fire" and was == true)
    fresh(nil, { { 0, -1, 3, "minecraft:netherrack" } })
    local n, why = T.ignite(0, 0, 3)
    check("ignite with no flint and steel: says so, no move", n == nil and why:find("no minecraft:flint_and_steel", 1, true) and atCell(0, 0, 0), tostring(why))
    fresh(nil, {})
    knowAll()
    W.give(1, FLINT, 1)
    n, why = T.ignite(0, 0, 3)
    check("ignite over air: nothing solid to light it from, no move", n == nil and why:find("nothing solid", 1, true) and atCell(0, 0, 0), tostring(why))
    fresh(nil, { { 0, -1, 3, "minecraft:netherrack" }, stone(0, 0, 3) })
    knowAll()
    W.give(1, FLINT, 1)
    n, why = T.ignite(0, 0, 3)
    check("ignite a cell with a block in it: refused, and the block left", n == nil and why:find("minecraft:stone is in the cell", 1, true) and has(0, 0, 3, "stone"),
        tostring(why))
    fresh(nil, { { 0, -1, 3, "minecraft:netherrack" } })
    W.give(1, FLINT, 1)
    n = T.ignite(0, 0, 3)
    check("ignite on a map that has never seen the cell: found out on arrival", n == "minecraft:fire")
end

--------------------------------------------------------------------------
-- T.placeInfo: what a plan reads off an item
--------------------------------------------------------------------------
do
    fresh(nil, {})
    local stairs, slab, door, torch, plainInfo = T.placeInfo("minecraft:oak_stairs"), T.placeInfo("minecraft:oak_slab"), T.placeInfo("minecraft:oak_door"),
        T.placeInfo("minecraft:torch"), T.placeInfo("minecraft:stone")
    check("placeInfo: a stair is placed by facing and half; a slab by type (half is the same); a door by facing, and is two blocks",
        stairs.family == "stairs" and stairs.keys.facing and stairs.keys.half and slab.keys.type and slab.keys.half and door.keys.facing and not door.keys.half
        and door.door == true and stairs.door == false)
    check("...a torch hangs; a plain block has no keys", torch.hang == true and torch.keys.facing and plainInfo.family == "block" and next(plainInfo.keys) == nil
        and plainInfo.hang == false)
    check("...an empty name is nothing", T.placeInfo("") == nil and T.placeInfo(nil) == nil)
end

--------------------------------------------------------------------------
-- A slab over a half slab of its own kind: the game skips that slab (it counts as replaceable) and clicks on, so the
-- approach is a guess, and nothing wrong is learnt from it; T.forgetPlacements puts the table's rows back
--------------------------------------------------------------------------
do
    local SL = "minecraft:oak_slab"
    local walls = { stone(0, 0, 2), stone(0, 0, 4), stone(1, 0, 3), stone(-1, 0, 3) }
    local blocks = { { 0, -1, 3, SL, { type = "bottom" } }, stone(0, -2, 3) }
    for _, b in ipairs(walls) do blocks[#blocks + 1] = b end
    fresh("north", blocks)
    knowAll()
    W.give(1, SL, 8)
    T.placeAt(0, 0, 3, SL, { half = "bottom" })
    local kept = learnedText()
    check("a slab placed over a half slab of its kind learns nothing", kept == nil, tostring(kept))
    blocks = { stone(0, -1, 3) }
    for _, b in ipairs(walls) do blocks[#blocks + 1] = b end
    fresh("north", blocks)
    if kept then                            -- (the same turtle's disk, later)
        local f = fs.open(T.dataPath(".placements"), "w"); f.write(kept); f.close()
    end
    knowAll()
    W.give(1, SL, 8)
    local name, why = T.placeAt(0, 0, 3, SL, { half = "bottom" })
    check("...so a bottom slab over plain stone still goes in from above", name ~= nil and has(0, 0, 3, "oak_slab", { type = "bottom" }),
        tostring(why))
    -- a row learnt wrong, by hand: forgotten
    local h = fs.open(T.dataPath(".placements"), "w")
    h.write("slab down beyond type=top\nstairs down beyond facing=back\n")
    h.close()
    check("T.forgetPlacements(family) forgets that family's rows only", T.forgetPlacements("slab") == true
        and learnedText() == "stairs down beyond facing=back\n", tostring(learnedText()))
    check("...an unknown family is refused", select(1, T.forgetPlacements("nonsense")) == false)
    check("...and with no family, all of them", T.forgetPlacements() == true and learnedText() == nil)
end
