-- sim/turtlelib_place.lua
--
-- tl.place (ADR-0008 phase 3): blocks placed with the state wanted, on sim/lib/buildworld's mock world, which
-- follows the game's placing rules (so a wrong row of the module's table shows up here before it does in game).
--   * stairs and slabs each way: sideways always the bottom half, facing the heading; placeDown the bottom half
--     iff there is a block under the target; placeUp the top half iff there is a block over it; in each of
--     the four facings and in a world whose heading 0 is not north;
--   * a log's axis (standing, lying along the heading, lying across); a torch on a wall (both ways round, one
--     reached by a route round the support) and standing (on top of a fence, a wall or a pane too, though none of
--     them holds one on a side); a sign and its text (standing on a wall or a fence too); a ladder (sideways, and from above
--     and below in a shaft, facing the wall it goes on), button, lever, trapdoor, fence gate, chest;
--   * signs toward a reader (opts.toward, ADR-0013 D6.3): a wall sign when a block stands behind the cell, else
--     standing at the nearest of the four rotations a turtle gives (how far off said; in a world turned too; reached
--     from above); opts.rotation; refusals (a rotation it can't give, not a sign, a facing too, no origin, a reader
--     straight above, not a cell); T.signFor (the nearest wall, opts.look, no wall, nowhere in front, no sign, a bad look);
--   * a door: the cell above free, a block below, set into a gap in a wall; refused otherwise, without moving;
--   * pistons, sticky pistons, dispensers, droppers and observers in each facing, up and down too (no origin needed for
--     those); repeaters and comparators on a floor (refused without); a wrong row learnt, a vertical facing too;
--   * the table wrong about a row: the retry gets it right, the wrong block is dug out (in a protected area too),
--     the correction is kept in .placements, used from then on and after a restart; a wrong guess on a map
--     that does not know the surroundings is not learnt from; the table wrong about a facing rule;
--   * what it refuses: a cell in use, no item, a state the family has no key for, a facing without the
--     world origin; a cell that already holds the block as wanted is left alone; what it finds there goes in the map;
--   * support: a top slab with nothing above (placing from above refused) gets a temporary block above, is placed from
--     below, and the block is taken away (opts.temp names it; none on board is refused, saying so);
--   * opts.digBelow: a top slab on a floor refused without it (the floor untouched, the option named); with it the
--     floor dug, the slab placed from there, the floor put back (a log floor the same way round), with a temporary
--     block above too when nothing is there; a floor that drops itself (soul soil) needing none on board, only a free
--     slot; refused before digging with none of the floor's block on board, with no way out of the floor's cell, in a
--     protected area (unless opts.inside); every unmet need said at once;
--   * opts.digBelow on solid ground (ADR-0013 D7): a floor cell beside the floor with air above dug and stood in, the
--     floor dug sideways, both put back as they were (blocks that drop themselves, and carried stone), both digs in the
--     undo journal; refused before digging with no neighbour with air above, the only one protected (unless
--     opts.inside) or with lava beside it, and with the blocks for both missing (named at once);
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

-- ADR-0015 D5: a placement that closes the turtle in: a corridor walled in stone whose only way out is the cell
-- placed (the turtle sealed itself in so in the field, and wrote down the wrong lesson); with opts.exit, refused
do
    local walls = {}
    for x = -1, 1 do for y = -1, 1 do for z = -1, 4 do
        if not (x == 0 and y == 0 and z >= 0) then walls[#walls + 1] = stone(x, y, z) end
    end end end
    fresh(nil, walls)
    knowAll()
    W.give(1, STONE, 4)
    local name, why = T.placeAt(0, 0, 3, STONE, { exit = { 0, 0, 6 } })
    check("opts.exit: a block that would close the last way to it is refused, saying why", name == nil
        and why:find("won't place stone at 0,0,3: no way from 0,0,2 to opts.exit 0,0,6 after it", 1, true) ~= nil and W.get(0, 0, 3) == nil,
        tostring(why))
    local placed, _, how = T.placeAt(0, 0, 3, STONE)
    check("...without it, placed with a warning that the turtle is closed in", placed == STONE and how and how.warning
        and how.warning:find("warning: placed stone at 0,0,3, but the turtle at 0,0,2 is closed in after it", 1, true) ~= nil,
        tostring(how and how.warning))
    fresh(nil, { stone(0, -1, 3) })
    knowAll()
    W.give(1, STONE, 4)
    placed, _, how = T.placeAt(0, 0, 3, STONE, { exit = { 0, 0, 6 } })
    check("...in the open, no warning and no refusal", placed == STONE and how and how.warning == nil, tostring(how and how.warning))
end

-- ADR-0015: a chain lies as a log does (it had no axis to place by); a lantern stands or hangs (opts.hanging)
local CHAIN, LANTERN = "minecraft:chain", "minecraft:lantern"
scene("a chain hanging down (axis y) with a floor to click", {
    item = CHAIN, blocks = { stone(0, -1, 3) }, opts = { axis = "y" }, expect = { { 0, 0, 3, "chain", { axis = "y" } } } })
scene("a chain lying along x onto a block beyond to the east", {
    item = CHAIN, blocks = { stone(1, 0, 3) }, opts = { axis = "x" },
    expect = { { 0, 0, 3, "chain", { axis = "x" } } }, approach = "front", from = { -1, 0, 3 } })
scene("a lantern hanging under a block (opts.hanging = true), nothing under the cell", {
    item = LANTERN, blocks = { stone(0, 1, 3) }, opts = { hanging = true },
    expect = { { 0, 0, 3, "lantern", { hanging = true } } } })
scene("a lantern standing on the floor (opts.hanging = false)", {
    item = LANTERN, blocks = { stone(0, -1, 3), stone(0, 1, 3) }, opts = { hanging = false },
    expect = { { 0, 0, 3, "lantern", { hanging = false } } } })
scene("a lantern under a chain hanging from a block", {
    item = LANTERN, blocks = { { 0, 1, 3, "minecraft:chain", { axis = "y" } }, stone(0, 2, 3) }, opts = { hanging = true },
    expect = { { 0, 0, 3, "lantern", { hanging = true } } } })
do
    fresh(nil, { stone(0, 1, 3) })
    knowAll()
    W.give(1, LANTERN, 2)
    local name, why = T.placeAt(0, 0, 3, LANTERN, { hanging = false })
    check("a lantern wanted standing with only a block above: refused, a block under the target named", name == nil
        and why:find("needs a block to hang it on under the target", 1, true) and W.get(0, 0, 3) == nil, tostring(why))
    name, why = T.placeAt(0, 0, 3, LANTERN, { hang = true })
    check("an option placeAt doesn't take is refused, named, with the ones it does (not ignored)", name == nil
        and why:find("placeAt has no option hang (it takes ", 1, true) and why:find("hanging", 1, true) and W.get(0, 0, 3) == nil,
        tostring(why))
    local info = T.placeInfo(LANTERN)
    check("T.placeInfo: a lantern hangs, by opts.hanging; a chain has an axis", info.family == "lantern" and info.hang == true
        and info.keys.hanging == true and T.placeInfo(CHAIN).keys.axis == true and T.placeInfo("minecraft:sea_lantern").family == "block")
end

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
    check("...naming the approach that would do and what it lacks", why:find("sideways from 0,0,4 facing south: needs a block to hang it on "
        .. "beyond the target, and the map has minecraft:air at 0,0,2", 1, true) ~= nil, tostring(why))
end
do
    -- a stair with its top half wanted, a block under the target: from above gives the bottom half, from below can't stand
    fresh(nil, { stone(0, 0, 3) })
    knowAll()
    W.give(1, ST, 4)
    local name, why = T.placeAt(0, 1, 3, ST, { facing = "north", half = "top" })
    check("no way to place a stair as asked: each approach says what it lacks", name == nil and why:find("no way to place", 1, true) ~= nil
        and why:find("from above from 0,2,3 facing north: gives half=bottom", 1, true) ~= nil
        and why:find("from below from 0,0,3: the map has minecraft:stone there", 1, true) ~= nil, tostring(why))
    -- every approach tried and the game refused each: the message lists them
    fresh(nil, {})
    knowAll()
    W.give(1, STONE, 4)
    local rawPlace = T.placeDir
    T.placeDir = function() return false, "Cannot place block here" end
    name, why = T.placeAt(0, 0, 3, STONE)
    T.placeDir = rawPlace
    check("every approach tried and refused: it says which it tried and what each got", name == nil and why:find("^couldn't place stone at 0,0,3") ~= nil
        and why:find("6 ways tried: sideways from 0,0,2: the game refused (Cannot place block here)", 1, true) ~= nil
        and why:find("from above from 0,1,3: the game refused", 1, true) ~= nil, tostring(why))
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
-- On top of a fence, a wall or a pane a torch stands, and so does a sign: a post in the middle holds them
for _, post in ipairs({ "oak_fence", "cobblestone_wall", "glass_pane" }) do
    scene("a torch on top of " .. post .. ": it stands there", {
        item = TORCH, blocks = { { 0, -1, 3, "minecraft:" .. post } }, expect = { { 0, 0, 3, "torch" } } })
end
scene("a sign on top of a wall: it stands there", {
    item = "minecraft:oak_sign", blocks = { { 0, -1, 3, "minecraft:cobblestone_wall" } }, opts = { text = "Mind the drop" },
    expect = { { 0, 0, 3, "oak_sign" } } })
check("...with its text", W.get(0, 0, 3) and W.get(0, 0, 3).text and W.get(0, 0, 3).text[2] == "Mind the drop")
scene("a sign on top of a fence: it stands there", {
    item = "minecraft:oak_sign", blocks = { { 0, -1, 3, "minecraft:oak_fence" } }, expect = { { 0, 0, 3, "oak_sign" } } })
do
    -- a fence beyond and nothing under: still nothing to hang a torch on
    fresh(nil, { { 0, 0, 4, "minecraft:cobblestone_wall" }, { 0, -1, 3, "minecraft:cobblestone_wall" } })
    knowAll()
    W.give(1, TORCH, 4)
    local name, state = T.placeAt(0, 0, 3, TORCH)
    check("a torch beside a wall and on top of another: it stands on the one below, not hung on the side",
        name == TORCH and has(0, 0, 3, "torch"), tostring(name) .. " " .. W.show(0, 0, 3))
end
scene("a ladder on the block beyond, facing back", {
    item = "minecraft:ladder", blocks = { stone(0, 0, 4) }, opts = { facing = "south" },
    expect = { { 0, 0, 3, "ladder", { facing = "south" } } }, approach = "front" })

-- Blocks whose item has another name (one table, T.itemOfBlock and T.blockOfItem): redstone dust is redstone_wire,
-- seeds make a crop, the wall forms by name and by ending
do
    fresh(nil, {})
    local function call(name, ...)
        if type(T[name]) ~= "function" then return "no T." .. name end
        return T[name](...)
    end
    local ofBlock = {
        { "redstone_wire", "redstone" }, { "tripwire", "string" }, { "wall_torch", "torch" }, { "soul_wall_torch", "soul_torch" },
        { "redstone_wall_torch", "redstone_torch" }, { "oak_wall_sign", "oak_sign" }, { "cherry_wall_hanging_sign", "cherry_hanging_sign" },
        { "red_wall_banner", "red_banner" }, { "skeleton_wall_skull", "skeleton_skull" }, { "creeper_wall_head", "creeper_head" },
        { "dead_tube_coral_wall_fan", "dead_tube_coral_fan" }, { "wheat", "wheat_seeds" }, { "carrots", "carrot" },
        { "cave_vines_plant", "glow_berries" }, { "kelp_plant", "kelp" }, { "attached_pumpkin_stem", "pumpkin_seeds" },
        { "stone", "stone" }, { "oak_sign", "oak_sign" }, { "cobblestone_wall", "cobblestone_wall" },
    }
    local wrong = {}
    for _, p in ipairs(ofBlock) do
        local got = call("itemOfBlock", "minecraft:" .. p[1])
        if got ~= "minecraft:" .. p[2] then wrong[#wrong + 1] = p[1] .. " -> " .. tostring(got) end
    end
    check("T.itemOfBlock: the item of a block whose item has another name, by name and by ending; any other block its own",
        #wrong == 0, table.concat(wrong, "; "))
    local ofItem = {
        { "redstone", nil, "redstone_wire" }, { "glow_berries", nil, "cave_vines" }, { "wheat_seeds", nil, "wheat" },
        { "torch", nil, "torch" }, { "stone", nil, "stone" }, { "torch", "wall", "wall_torch" }, { "redstone_torch", "wall", "redstone_wall_torch" },
        { "oak_sign", "wall", "oak_wall_sign" }, { "oak_hanging_sign", "wall", "oak_wall_hanging_sign" },
        { "zombie_head", "wall", "zombie_wall_head" }, { "stone", "wall", false }, { "redstone", "wall", false },
    }
    wrong = {}
    for _, p in ipairs(ofItem) do
        local got = call("blockOfItem", "minecraft:" .. p[1], p[2])
        local want = p[3] and "minecraft:" .. p[3] or nil
        if got ~= want then wrong[#wrong + 1] = p[1] .. " " .. tostring(p[2]) .. " -> " .. tostring(got) end
    end
    check("T.blockOfItem: the block an item places, and its wall form (nil for an item with none)", #wrong == 0, table.concat(wrong, "; "))

    fresh(nil, { stone(0, -1, 3) })
    knowAll()
    W.give(1, "minecraft:redstone", 8)
    local name, state, how = T.placeAt(0, 0, 3, "minecraft:redstone")
    check("redstone dust on a floor: redstone_wire, taken as the redstone asked for, not dug back and tried again",
        name == "minecraft:redstone_wire" and has(0, 0, 3, "redstone_wire") and (W.dug or 0) == 0 and type(how) == "table"
        and how.tries == 1 and W.carrying("minecraft:redstone") == 7,
        tostring(name) .. " " .. tostring(state) .. " " .. W.show(0, 0, 3) .. " dug " .. tostring(W.dug))
    check("...and the map has the block", T.map.get(0, 0, 3) == "minecraft:redstone_wire", tostring(T.map.get(0, 0, 3)))
    name, state, how = T.placeAt(0, 0, 3, "minecraft:redstone")
    check("...asked again: already there", name == "minecraft:redstone_wire" and type(how) == "table" and how.approach == "already there",
        tostring(name) .. " " .. tostring(state))
    fresh(nil, {})
    knowAll()
    W.give(1, "minecraft:redstone", 8)
    name, state = T.placeAt(0, 0, 3, "minecraft:redstone")
    check("redstone dust with no floor: the game refuses it, nothing placed", name == nil and W.get(0, 0, 3) == nil, tostring(state))

    fresh(nil, { { 0, -1, 3, "minecraft:farmland" } })
    knowAll()
    W.give(1, "minecraft:wheat_seeds", 8)
    name, state, how = T.placeAt(0, 0, 3, "minecraft:wheat_seeds")
    check("wheat seeds on farmland: a wheat crop, taken as the seeds asked for", name == "minecraft:wheat" and has(0, 0, 3, "wheat")
        and (W.dug or 0) == 0 and type(how) == "table" and how.tries == 1, tostring(name) .. " " .. tostring(state) .. " " .. W.show(0, 0, 3))
end
-- Ladders from above and below: the turtle faces the wall the ladder goes on (the first side the game looks at)
local LADDER = "minecraft:ladder"
-- a shaft one cell wide at 0,y,3, its walls at y from y1 to y2, and stone at the cells named
local function shaft(y1, y2, extra)
    local out = {}
    for y = y1, y2 do
        for _, c in ipairs({ { 0, 4 }, { 0, 2 }, { 1, 3 }, { -1, 3 } }) do out[#out + 1] = stone(c[1], y, c[2]) end
    end
    for _, b in ipairs(extra or {}) do out[#out + 1] = b end
    return out
end
scene("a ladder in a shaft with a floor, from above: facing the wall beyond the target, on it", {
    item = LADDER, blocks = shaft(0, 0, { stone(0, -1, 3) }), opts = { facing = "south" },
    expect = { { 0, 0, 3, "ladder", { facing = "south" } } }, approach = "down", from = { 0, 1, 3 } })
scene("a ladder in a shaft with a roof, from below", {
    item = LADDER, blocks = shaft(0, 0, { stone(0, 1, 3) }), opts = { facing = "south" },
    expect = { { 0, 0, 3, "ladder", { facing = "south" } } }, approach = "up", from = { 0, -1, 3 } })
scene("a ladder from above with no facing asked: on a wall the turtle turns to", {
    item = LADDER, blocks = shaft(0, 0, { stone(0, -1, 3) }),
    expect = { { 0, 0, 3, "ladder" } }, approach = "down" })
do
    fresh(nil, shaft(0, 2, { stone(0, -1, 3) }))
    knowAll()
    W.give(1, LADDER, 4)
    local good = true
    for y = 0, 2 do
        local name, _, how = T.placeAt(0, y, 3, LADDER, { facing = "south" })
        good = good and name ~= nil and how.approach == "down" and has(0, y, 3, "ladder", { facing = "south" })
    end
    check("a ladder column up a shaft, each from above, bottom first", good, W.show(0, 0, 3) .. " " .. W.show(0, 1, 3) .. " " .. W.show(0, 2, 3))
    fresh(nil, { stone(0, -1, 3), stone(1, 0, 3), stone(-1, 0, 3), stone(0, 0, 4) })
    knowAll()
    W.give(1, LADDER, 4)
    local name, why = T.placeAt(0, 0, 3, LADDER, { facing = "north" })
    check("a ladder facing north with no wall south of it: refused, saying the wall it needs from above",
        name == nil and why:find("from above from 0,1,3 facing south: needs a block to hang it on beside the target the way the turtle "
        .. "faces, and the map has minecraft:air at 0,0,2", 1, true) ~= nil and W.get(0, 0, 3) == nil, tostring(why))
end
scene("a button on a wall beyond", {
    item = "minecraft:stone_button", blocks = { stone(0, 0, 4) }, opts = { face = "wall", facing = "south" },
    expect = { { 0, 0, 3, "stone_button", { face = "wall", facing = "south" } } } })
scene("a lever on the floor, from above", {
    item = "minecraft:lever", blocks = { stone(0, -1, 3) }, opts = { face = "floor" },
    expect = { { 0, 0, 3, "lever", { face = "floor" } } } })

--------------------------------------------------------------------------
-- Signs: on a wall when the block beyond holds one, else standing; opts.text written, 4 lines of 15
--------------------------------------------------------------------------
local SIGN = "minecraft:oak_sign"
local function signLines(x, y, z)
    local b = W.get(x, y, z)
    return b and b.text and table.concat(b.text, "|") or "no text"
end
do
    local _, _, how = scene("a sign on the wall beyond: a wall sign facing back at the turtle", {
        item = SIGN, blocks = { stone(0, 0, 4) }, opts = { text = "Welcome to the castle" },
        expect = { { 0, 0, 3, "oak_wall_sign", { facing = "south" } } }, approach = "front", from = { 0, 0, 2 } })
    check("...its text wrapped to lines of 15 (two lines start on the sign's second)", signLines(0, 0, 3) == "|Welcome to the|castle|",
        signLines(0, 0, 3))
    check("...and the lines come back in how", how and how.lines and #how.lines == 2 and how.lines[1] == "Welcome to the",
        tostring(how and how.lines))
    scene("a sign with a floor and no wall: it stands", {
        item = SIGN, blocks = { stone(0, -1, 3) }, opts = { text = "Keep\nout" }, expect = { { 0, 0, 3, "oak_sign" } } })
    check("...the lines as given, each its own", signLines(0, 0, 3) == "|Keep|out|", signLines(0, 0, 3))
    scene("a sign's UTF-8 text (an arrow, a dash) as the game shows it, spelled out", {
        item = SIGN, blocks = { stone(0, -1, 3) }, opts = { text = "Gate \226\134\146\nRoad \226\128\148 Ember" },
        expect = { { 0, 0, 3, "oak_sign" } } })
    check("...no mojibake on the sign", signLines(0, 0, 3) == "|Gate ->|Road - Ember|", signLines(0, 0, 3))
    scene("a sign facing north goes round its wall to the north side", {
        item = SIGN, blocks = { stone(0, 0, 2) }, opts = { facing = "north", text = "north" },
        expect = { { 0, 0, 3, "oak_wall_sign", { facing = "north" } } }, from = { 0, 0, 4 } })
    fresh(nil, { stone(0, 0, 4) })
    knowAll()
    W.give(1, SIGN, 4)
    local name, why = T.placeAt(0, 0, 3, SIGN, { text = "one two three four five six seven eight nine ten eleven twelve" })
    check("text that will not fit 4 lines of 15 is refused with why, nothing placed, no move", name == nil
        and why:find("4 lines of 15", 1, true) ~= nil and W.get(0, 0, 3) == nil and atCell(0, 0, 0), tostring(why))
    W.give(2, STONE, 4)
    name, why = T.placeAt(0, 0, 3, STONE, { text = "hello" })
    check("text on a block that is not a sign is refused", name == nil and why:find("only a sign", 1, true) ~= nil and W.get(0, 0, 3) == nil,
        tostring(why))
    fresh(nil, { stone(0, 0, 2) })
    W.give(1, SIGN, 2)
    T.selectItem(SIGN)
    local ok = T.placeDir(0, "by hand")
    check("T.placeDir(d, text) writes the text on a sign", ok == true and signLines(0, 0, 1) == "|by hand||", signLines(0, 0, 1))
    local info = T.placeInfo(SIGN)
    check("placeInfo: a sign is its own family, hangs, placed by facing", info.family == "sign" and info.hang == true and info.keys.facing == true)
end

--------------------------------------------------------------------------
-- Signs toward a reader (ADR-0013 D6.3): opts.toward, the reader's cell: a wall sign when a sturdy block stands behind
-- the cell, else a standing sign turned to the nearest of the four rotations a turtle gives (0 south, 4 west, 8 north,
-- 12 east: the way its face looks); T.signFor finds the cell in front of the reader
--------------------------------------------------------------------------
do
    local function aimOf(how) return how and how.toward or {} end
    local _, _, how = scene("toward a reader with a wall behind the cell: a wall sign whose face looks at the reader", {
        item = SIGN, blocks = { stone(0, 0, 4), stone(0, -1, 3) }, opts = { toward = { 0, 0, 1 }, text = "Hello" },
        expect = { { 0, 0, 3, "oak_wall_sign", { facing = "south" } } } })
    check("...how.toward: a wall sign facing south, the block behind named", aimOf(how).form == "wall" and aimOf(how).facing == "south"
        and aimOf(how).behind and aimOf(how).behind.z == 4 and signLines(0, 0, 3) == "|Hello||", tostring(aimOf(how).form))
    _, _, how = scene("the reader on the wall's side: not behind the cell, so a standing sign, its face north (rotation 8), placed from above", {
        item = SIGN, blocks = { stone(0, 0, 4), stone(0, -1, 3) }, opts = { toward = { 0, 0, 5 } },
        expect = { { 0, 0, 3, "oak_sign", { rotation = 8 } } }, approach = "down" })
    check("...how.toward: standing, rotation 8, nothing off", aimOf(how).form == "standing" and aimOf(how).rotation == 8 and aimOf(how).off == 0)
    _, _, how = scene("a standing sign in open ground, the reader off to one side: the nearest of the four (east, rotation 12)", {
        item = SIGN, blocks = { stone(0, -1, 3) }, opts = { toward = { 2, 0, 4 } }, expect = { { 0, 0, 3, "oak_sign", { rotation = 12 } } } })
    check("...how.toward says how far off: the reader's way is rotation 11, 27 degrees from it", aimOf(how).wanted == 11 and aimOf(how).off == 27
        and tostring(aimOf(how).note):find("27 degrees", 1, true) ~= nil, tostring(aimOf(how).wanted) .. " " .. tostring(aimOf(how).off))
    scene("...the same in a world whose heading 0 is east: the reader is mostly south, rotation 0", {
        facing = "east", item = SIGN, blocks = { stone(0, -1, 3) }, opts = { toward = { 2, 0, 4 } },
        expect = { { 0, 0, 3, "oak_sign", { rotation = 0 } } } })
    scene("the reader straight in front, below the sign: its face south (rotation 0)", {
        item = SIGN, blocks = { stone(0, 0, 3) }, at = { 0, 1, 3 }, opts = { toward = { 0, 0, 0 } },
        expect = { { 0, 1, 3, "oak_sign", { rotation = 0 } } } })
    scene("opts.rotation by itself: a standing sign turned so (4: its face west)", {
        item = SIGN, blocks = { stone(0, -1, 3) }, opts = { rotation = 4 }, expect = { { 0, 0, 3, "oak_sign", { rotation = 4 } } } })
    check("placeInfo: a sign is placed by rotation too", T.placeInfo(SIGN).keys.rotation == true)
    -- refusals, each before a move
    local function refused(label, blocks, opts, words, item, origin)
        fresh(nil, blocks, origin)
        knowAll()
        W.give(1, item or SIGN, 4)
        local name, why = T.placeAt(0, 0, 3, item or SIGN, opts)
        check(label, name == nil and tostring(why):find(words, 1, true) ~= nil and W.get(0, 0, 3) == nil and atCell(0, 0, 0), tostring(why))
    end
    refused("opts.rotation a turtle can't give (6): refused, naming the four", { stone(0, -1, 3) }, { rotation = 6 }, "0 (its face south), 4")
    refused("opts.toward on what is not a sign: refused", { stone(0, -1, 3) }, { toward = { 0, 0, 0 } }, "is not one", "minecraft:torch")
    refused("opts.toward with a facing too: refused", { stone(0, -1, 3) }, { toward = { 0, 0, 0 }, facing = "north" }, "leave those out")
    refused("opts.toward without the world origin: refused, naming T.setOrigin", { stone(0, -1, 3) }, { toward = { 0, 0, 0 } }, "T.setOrigin", nil, false)
    refused("a reader straight above the sign: refused", { stone(0, -1, 3) }, { toward = { 0, 5, 3 } }, "straight above or below")
    refused("opts.toward not a cell: refused", { stone(0, -1, 3) }, { toward = "me" }, "the reader's cell")

    -- T.signFor: a wall 3 cells north of the reader at 0,0,0, a floor all round
    local function room(extra)
        local blocks = {}
        for x = -3, 3 do for z = -3, 5 do blocks[#blocks + 1] = stone(x, -1, z) end end
        for _, b in ipairs(extra or {}) do blocks[#blocks + 1] = b end
        fresh(nil, blocks)
        knowAll()
        W.give(1, SIGN, 4)
    end
    local wall = {}
    for x = -2, 2 do for y = 0, 2 do wall[#wall + 1] = stone(x, y, 3) end end
    room(wall)
    local name, state
    name, state, how = T.signFor({ 0, 0, 0 }, "Shop")
    check("T.signFor: the reader faces the nearest wall the map shows; the sign on it at eye level, its face toward them",
        name ~= nil and has(0, 1, 2, "oak_wall_sign", { facing = "south" }) and signLines(0, 1, 2) == "|Shop||" and how.at
        and how.at.y == 1 and how.look == "north", tostring(state) .. " " .. W.show(0, 1, 2))
    room(wall)
    name, state, how = T.signFor({ 0, 0, 0 }, "East", { look = "east" })
    check("...opts.look east, no wall that way: standing on the floor in front, its face back at the reader (rotation 4)",
        name ~= nil and has(1, 0, 0, "oak_sign", { rotation = 4 }) and how.look == "east", tostring(state) .. " " .. W.show(1, 0, 0))
    room()
    name, why = T.signFor({ 0, 0, 0 }, "Lost")
    check("...no wall near and no opts.look: refused, saying to name the way", name == nil and tostring(why):find("opts.look", 1, true) ~= nil
        and atCell(0, 0, 0), tostring(why))
    room({ stone(0, 0, 1), stone(0, 1, 1) })
    name, why = T.signFor({ 0, 0, 0 }, "Wall", { look = "north" })
    check("...nowhere in front for one (a wall against the reader): refused, each cell's why named", name == nil
        and tostring(why):find("0,1,1: the map has minecraft:stone there", 1, true) ~= nil, tostring(why))
    room(wall)
    W.give(1, nil)
    name, why = T.signFor({ 0, 0, 0 }, "Shop")
    check("...no sign on board: refused", name == nil and tostring(why):find("no sign on board", 1, true) ~= nil, tostring(why))
    room(wall)
    name, why = T.signFor({ 0, 0, 0 }, "Shop", { look = "up" })
    check("...opts.look not a compass way: refused", name == nil and tostring(why):find("compass", 1, true) ~= nil, tostring(why))
end

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
-- Pistons, dispensers, droppers and observers by facing, up and down too; repeaters and comparators on a floor
--------------------------------------------------------------------------
local PISTON, OBSERVER, REPEATER = "minecraft:piston", "minecraft:observer", "minecraft:repeater"
for _, f in ipairs({ "north", "east", "south", "west", "up", "down" }) do
    scene("a piston facing " .. f .. " in the open", {
        item = PISTON, opts = { facing = f }, expect = { { 0, 0, 3, "piston", { facing = f } } } })
    scene("an observer facing " .. f .. " in the open", {
        item = OBSERVER, opts = { facing = f }, expect = { { 0, 0, 3, "observer", { facing = f } } } })
end
scene("a piston facing up on a floor", {
    item = PISTON, blocks = { stone(0, -1, 3) }, opts = { facing = "up" }, expect = { { 0, 0, 3, "piston", { facing = "up" } } } })
scene("a sticky piston facing south against a wall beyond", {
    item = "minecraft:sticky_piston", blocks = { stone(0, 0, 4) }, opts = { facing = "south" },
    expect = { { 0, 0, 3, "sticky_piston", { facing = "south" } } } })
scene("a dispenser facing down", { item = "minecraft:dispenser", opts = { facing = "down" }, expect = { { 0, 0, 3, "dispenser", { facing = "down" } } } })
scene("a dropper facing west with a floor and a block beyond (with only a floor sideways looks down at it: up)", {
    item = "minecraft:dropper", blocks = { stone(0, -1, 3), stone(1, 0, 3) }, opts = { facing = "west" },
    expect = { { 0, 0, 3, "dropper", { facing = "west" } } } })
for _, f in ipairs({ "north", "east", "south", "west" }) do
    scene("a repeater on a floor facing " .. f, {
        item = REPEATER, blocks = { stone(0, -1, 3) }, opts = { facing = f }, expect = { { 0, 0, 3, "repeater", { facing = f } } } })
end
scene("a comparator facing west in a world whose heading 0 is east", {
    facing = "east", item = "minecraft:comparator", blocks = { stone(0, -1, 3) }, opts = { facing = "west" },
    expect = { { 0, 0, 3, "comparator", { facing = "west" } } } })
do
    fresh(nil, {})
    knowAll()
    W.give(1, REPEATER, 2)
    local name, why = T.placeAt(0, 0, 3, REPEATER, { facing = "north" })
    check("a repeater with no floor: refused for that, without moving", name == nil and why:find("solid block under", 1, true) ~= nil
        and atCell(0, 0, 0) and W.get(0, 0, 3) == nil, tostring(why))
    W.give(2, PISTON, 2)
    name, why = T.placeAt(0, 0, 3, PISTON, { facing = "sideways" })
    check("a piston's facing is a compass name, up or down", name == nil and why:find("up or down", 1, true) ~= nil, tostring(why))
    name, why = T.placeAt(0, 0, 3, REPEATER, { facing = "up" })
    check("...a repeater's only a compass name", name == nil and why:find("compass name", 1, true) ~= nil
        and not why:find("up or down", 1, true), tostring(why))
    fresh(nil, {}, false)
    W.give(1, PISTON, 2)
    name, why = T.placeAt(0, 0, 3, PISTON, { facing = "up" })
    check("a piston facing up needs no world origin", name ~= nil and has(0, 0, 3, "piston", { facing = "up" }), tostring(why))
    -- the table wrong about a row: what the game gives, up included, is learnt
    fresh(nil, {})
    knowAll()
    W.give(1, PISTON, 4)
    T.need("placeAt")
    T.PLACE_TABLE.piston.front[3].set.facing = "back"
    local state
    name, state = T.placeAt(0, 0, 3, PISTON, { facing = "north" })
    check("a wrong piston row: the first try comes out the other way, is dug out, and the retry faces north",
        name == PISTON and state.facing == "north" and has(0, 0, 3, "piston", { facing = "north" }) and W.carrying(PISTON) == 3, tostring(name))
    check("...the rule learnt relative to the heading", learnedText() == "piston front always facing=heading\n", tostring(learnedText()))
    fresh(nil, { stone(0, -1, 3) })
    knowAll()
    W.give(1, PISTON, 4)
    T.need("placeAt")
    T.PLACE_TABLE.piston.front[2].set.facing = "back"
    name = T.placeAt(0, 0, 3, PISTON, { facing = "north" })
    check("...and a row that gives up where the table said a compass way: learnt as up", learnedText() == "piston front floor facing=up\n"
        and W.get(0, 0, 3) == nil, tostring(learnedText()))
    local info = T.placeInfo(PISTON)
    check("placeInfo: a piston, a dispenser and a dropper are one family, an observer and a repeater their own, each by facing",
        info.family == "piston" and info.keys.facing and T.placeInfo("minecraft:dropper").family == "piston"
        and T.placeInfo(OBSERVER).family == "observer" and T.placeInfo(REPEATER).family == "diode"
        and T.placeInfo("minecraft:comparator").keys.facing and T.placeInfo(REPEATER).door == false)
end

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
    check("...and the map has the block it found", T.map.get(0, 0, 3) == STONE, tostring(T.map.get(0, 0, 3)))
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
    -- the map out of date: it says air where the stair is
    fresh(nil, { { 0, 0, 3, ST, { facing = "north", half = "bottom", shape = "straight", waterlogged = false } } })
    knowAll()
    T.map.set(0, 0, 3, "minecraft:air")
    W.give(1, ST, 4)
    name, state, how = T.placeAt(0, 0, 3, ST, { facing = "north", half = "bottom" })
    local mapName, mapState = T.map.get(0, 0, 3)
    check("a stair already there that the map had as air: found, and the map has it now, with its state", name == ST
        and how.approach == "already there" and mapName == ST and mapState and mapState.facing == "north", tostring(mapName))
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
-- Support: a top half placed from below with nothing above to place against gets a temporary block there, taken away
-- after (here the game refuses the placement from above, so from below is the only way left)
--------------------------------------------------------------------------
local COBBLE = "minecraft:cobblestone"
-- T.placeDir with placing down refused, as a game that won't place from above would
local function noPlacingDown()
    local rawPlace = T.placeDir
    T.placeDir = function(d, ...)
        if d == "down" then return false, "Cannot place block here" end
        return rawPlace(d, ...)
    end
end
do
    fresh(nil, {})
    knowAll()
    W.give(1, SL, 4)
    W.give(2, COBBLE, 3)
    noPlacingDown()
    local name, state, how = T.placeAt(0, 0, 3, SL, { half = "top" })
    check("a top slab with nothing above: a temporary block above, the slab from below, the block taken away",
        name ~= nil and has(0, 0, 3, "oak_slab", { type = "top" }) and W.get(0, 1, 3) == nil and how.approach == "up"
        and how.support and how.support.temp == COBBLE, tostring(state) .. " " .. W.show(0, 0, 3) .. " " .. W.show(0, 1, 3))
    check("...the cobblestone back on board, one slab used, the map with air where the block was", W.carrying(COBBLE) == 3 and W.carrying(SL) == 3
        and T.map.get(0, 1, 3) == "minecraft:air", W.carrying(COBBLE) .. " " .. tostring(T.map.get(0, 1, 3)))
    fresh(nil, {})
    knowAll()
    W.give(1, SL, 4)
    W.give(2, "minecraft:dirt", 2)
    W.give(3, COBBLE, 2)
    noPlacingDown()
    name, state, how = T.placeAt(0, 0, 3, SL, { half = "top", temp = "minecraft:dirt" })
    check("opts.temp names the block to use", name ~= nil and how.support and how.support.temp == "minecraft:dirt" and W.carrying("minecraft:dirt") == 2
        and W.get(0, 1, 3) == nil, tostring(state))
    fresh(nil, {})
    knowAll()
    W.give(1, SL, 4)
    noPlacingDown()
    local why
    name, why = T.placeAt(0, 0, 3, SL, { half = "top" })
    check("no block on board to hold it up: refused, saying so", name == nil and why:find("a block to put above it for a moment", 1, true) ~= nil
        and W.get(0, 0, 3) == nil, tostring(why))
end

--------------------------------------------------------------------------
-- opts.digBelow: a top half on a floor is placed from where the floor is: the floor dug, stood in, the item placed up,
-- the floor put back with the same block; never without the option
--------------------------------------------------------------------------
local FLOOR = "minecraft:stone_bricks"
-- A floor round 0,-1,3 with air under it (the way out), and what else is named
local function floorScene(floorBlock, extra)
    local blocks = { { 0, -1, 3, floorBlock[1], floorBlock[2] }, stone(1, -1, 3), stone(-1, -1, 3), stone(0, -1, 2), stone(0, -1, 4) }
    for _, b in ipairs(extra or {}) do blocks[#blocks + 1] = b end
    fresh(nil, blocks)
    knowAll()
end
do
    local STAIR_ON = { 0, 1, 3, ST, { facing = "north", half = "bottom", shape = "straight", waterlogged = false } }
    floorScene({ FLOOR }, { STAIR_ON })
    W.give(1, SL, 4)
    W.give(2, FLOOR, 1)
    local name, why = T.placeAt(0, 0, 3, SL, { half = "top" })
    check("a top slab on a floor under a stair, without opts.digBelow: refused, the floor left as it is, the option named",
        name == nil and has(0, -1, 3, "stone_bricks") and W.get(0, 0, 3) == nil and W.dug == nil
        and why:find("opts.digBelow = true", 1, true) ~= nil, tostring(why))
    local state, how
    name, state, how = T.placeAt(0, 0, 3, SL, { half = "top", digBelow = true })
    check("...with opts.digBelow: the floor dug, the slab placed up from there against the stair, the floor put back",
        name ~= nil and has(0, 0, 3, "oak_slab", { type = "top" }) and has(0, -1, 3, "stone_bricks") and how.support
        and how.support.floor == FLOOR and how.support.temp == nil, tostring(state) .. " " .. W.show(0, 0, 3) .. " " .. W.show(0, -1, 3))
    check("...the same number of bricks on board as before, the map with the floor and the slab", W.carrying(FLOOR) == 1
        and T.map.get(0, -1, 3) == FLOOR and T.map.get(0, 0, 3) == SL, W.carrying(FLOOR) .. " " .. tostring(T.map.get(0, -1, 3)))
    -- nothing above: a temporary block too, and a floor with a state put back the same way round
    floorScene({ "minecraft:oak_log", { axis = "y" } })
    W.give(1, SL, 4)
    W.give(2, "minecraft:oak_log", 1)
    W.give(3, COBBLE, 1)
    name, state, how = T.placeAt(0, 0, 3, SL, { half = "top", digBelow = true })
    check("with nothing above as well: a temporary block above, the floor dug, the slab, the floor back, the block taken away",
        name ~= nil and has(0, 0, 3, "oak_slab", { type = "top" }) and has(0, -1, 3, "oak_log", { axis = "y" }) and W.get(0, 1, 3) == nil
        and how.support and how.support.temp == COBBLE and W.carrying(COBBLE) == 1 and W.carrying("minecraft:oak_log") == 1,
        tostring(state) .. " " .. W.show(0, 0, 3) .. " " .. W.show(0, -1, 3) .. " " .. W.show(0, 1, 3))
    -- a floor that comes back as itself when dug needs none on board, only a free slot for the one dug (ADR-0013)
    floorScene({ "minecraft:soul_soil" }, { STAIR_ON })
    W.give(1, SL, 4)
    name, state, how = T.placeAt(0, 0, 3, SL, { half = "top", digBelow = true })
    check("a soul soil floor and none on board: dug, the slab placed from there, the floor put back with the soil dug",
        name ~= nil and has(0, 0, 3, "oak_slab", { type = "top" }) and has(0, -1, 3, "soul_soil") and W.carrying("minecraft:soul_soil") == 0
        and how and how.support and how.support.floor == "minecraft:soul_soil", tostring(state) .. " " .. W.show(0, -1, 3))
    floorScene({ "minecraft:soul_soil" }, { STAIR_ON })
    W.give(1, SL, 4)
    for slot = 2, 16 do W.give(slot, "minecraft:dirt", 64) end
    name, why = T.placeAt(0, 0, 3, SL, { half = "top", digBelow = true })
    check("...but with no free slot for the soil dug: refused, nothing dug, saying so", name == nil and W.dug == nil
        and has(0, -1, 3, "soul_soil") and why:find("free a slot", 1, true) ~= nil, tostring(why))
    -- refusals before anything is dug
    floorScene({ STONE }, { STAIR_ON })
    W.give(1, SL, 4)
    name, why = T.placeAt(0, 0, 3, SL, { half = "top", digBelow = true })
    check("opts.digBelow on a floor that drops something else, with none of it on board: refused, nothing dug, saying to carry one",
        name == nil and W.dug == nil and has(0, -1, 3, "stone") and why:find("carry one minecraft:stone", 1, true) ~= nil, tostring(why))
    -- (walled in: the cells beside the target hold blocks, so no floor cell beside it has air above, ADR-0013 D7)
    local WALLED = { stone(1, 0, 3), stone(-1, 0, 3), stone(0, 0, 2), stone(0, 0, 4) }
    floorScene({ STONE }, { STAIR_ON, stone(0, -2, 3), table.unpack(WALLED) })
    W.give(1, SL, 4)
    name, why = T.placeAt(0, 0, 3, SL, { half = "top" })
    check("every need of a dug floor said at once: the option, a block to carry, a way out",
        name == nil and W.dug == nil and why:find("opts.digBelow = true", 1, true) ~= nil and why:find("carry one minecraft:stone", 1, true) ~= nil
        and why:find("no free cell beside the floor", 1, true) ~= nil, tostring(why))
    floorScene({ FLOOR }, { STAIR_ON, stone(0, -2, 3), table.unpack(WALLED) })
    W.give(1, SL, 4)
    W.give(2, FLOOR, 1)
    name, why = T.placeAt(0, 0, 3, SL, { half = "top", digBelow = true })
    check("...with no free cell beside the floor to step out to: refused, nothing dug", name == nil and W.dug == nil
        and why:find("no free cell beside the floor", 1, true) ~= nil, tostring(why))
    floorScene({ FLOOR }, { STAIR_ON })
    W.give(1, SL, 4)
    W.give(2, FLOOR, 1)
    T.protect("hall", -1, -1, 2, 1, -1, 4)
    name, why = T.placeAt(0, 0, 3, SL, { half = "top", digBelow = true })
    check("...a floor in a protected area is not dug: refused, saying so", name == nil and has(0, -1, 3, "stone_bricks")
        and why:find("protected", 1, true) ~= nil, tostring(why))
    name = T.placeAt(0, 0, 3, SL, { half = "top", digBelow = true, inside = "hall" })
    check("...unless the job owns it (opts.inside)", name ~= nil and has(0, 0, 3, "oak_slab", { type = "top" }) and has(0, -1, 3, "stone_bricks"))
end

--------------------------------------------------------------------------
-- digBelow on solid ground (ADR-0013 D7): no free cell beside the floor, so a floor cell beside it with air above is
-- dug too, stood in, the floor dug sideways and stood in, the item placed up, and both put back as they were
--------------------------------------------------------------------------
do
    local STAIR_ON = { 0, 1, 3, ST, { facing = "north", half = "bottom", shape = "straight", waterlogged = false } }
    local ANDESITE = "minecraft:polished_andesite"
    -- the floor at 0,-1,3 with solid ground under it and the neighbours given (all four the same block, or a list by
    -- 0,-1,2 / 1,-1,3 / -1,-1,3 / 0,-1,4), and what else is named
    local function solidScene(floorName, beside, extra)
        local cells = { { 0, -1, 2 }, { 1, -1, 3 }, { -1, -1, 3 }, { 0, -1, 4 } }
        local blocks = { { 0, -1, 3, floorName }, stone(0, -2, 3), STAIR_ON }
        for i, c in ipairs(cells) do
            blocks[#blocks + 1] = { c[1], c[2], c[3], type(beside) == "table" and beside[i] or beside }
        end
        for _, b in ipairs(extra or {}) do blocks[#blocks + 1] = b end
        fresh(nil, blocks)
        knowAll()
        W.give(1, SL, 4)
    end
    -- blocks over three of the neighbours, so only 0,-1,2 has air above it
    local OVER3 = { stone(1, 0, 3), stone(-1, 0, 3), stone(0, 0, 4) }
    local function allBack(floorName, besideName)
        return has(0, -1, 3, floorName) and has(0, -1, 2, besideName) and has(1, -1, 3, besideName) and has(-1, -1, 3, besideName)
            and has(0, -1, 4, besideName)
    end

    solidScene(FLOOR, ANDESITE)
    local name, state, how = T.placeAt(0, 0, 3, SL, { half = "top", digBelow = true })
    check("digBelow on solid ground: a neighbour dug and stood in, the floor dug sideways, the slab placed up, both floors back",
        name ~= nil and has(0, 0, 3, "oak_slab", { type = "top" }) and allBack("stone_bricks", "polished_andesite") and how and how.support
        and how.support.exit and how.support.exit.x == 0 and how.support.exit.z == 2, tostring(state) .. " " .. W.show(0, -1, 3) .. " " .. W.show(0, -1, 2))
    check("...nothing carried before or after (both drop themselves), two digs, the map with both floors", W.carrying(FLOOR) == 0
        and W.carrying(ANDESITE) == 0 and W.dug == 2 and T.map.get(0, -1, 3) == FLOOR and T.map.get(0, -1, 2) == ANDESITE,
        tostring(W.dug) .. " " .. W.carrying(FLOOR) .. " " .. tostring(T.map.get(0, -1, 2)))

    -- floors that drop something else: two carried; with the undo journal on, both digs written down
    solidScene(STONE, STONE)
    W.give(2, STONE, 2)
    package.loaded["tl.journal"] = nil
    T.cfg.undo = true
    name, state = T.placeAt(0, 0, 3, SL, { half = "top", digBelow = true })
    local f = fs.open(T.dataPath(".undo"), "r")
    local journal = f and f.readAll() or ""
    if f then f.close() end
    T.cfg.undo = false
    -- (the mock's stone drops itself, the game's cobblestone: either way two come back)
    check("...stone floors (in game they drop cobblestone): put back with the two carried, both as they were",
        name ~= nil and allBack("stone", "stone") and W.carrying(STONE) + W.carrying("minecraft:cobblestone") == 2,
        W.carrying(STONE) .. " " .. W.carrying("minecraft:cobblestone") .. " " .. W.show(0, -1, 3) .. " " .. W.show(0, -1, 2) .. " " .. W.show(0, 0, 3))
    check("...with T.cfg.undo on, both digs are in the undo journal", journal:find(" dig 0 -1 2 minecraft:stone", 1, true) ~= nil
        and journal:find(" dig 0 -1 3 minecraft:stone", 1, true) ~= nil, journal)

    -- refusals, before anything is dug
    solidScene(FLOOR, ANDESITE, { stone(1, 0, 3), stone(-1, 0, 3), stone(0, 0, 2), stone(0, 0, 4) })
    local why
    name, why = T.placeAt(0, 0, 3, SL, { half = "top", digBelow = true })
    check("...no neighbour with air above it: refused, nothing dug, each neighbour's why named", name == nil and W.dug == nil
        and why:find("no free cell beside the floor", 1, true) ~= nil and why:find("0,-1,2: the map has minecraft:stone above it", 1, true) ~= nil,
        tostring(why))
    solidScene(FLOOR, ANDESITE, OVER3)
    T.protect("edge", 0, -1, 2, 0, -1, 2)
    name, why = T.placeAt(0, 0, 3, SL, { half = "top", digBelow = true })
    check("...the only neighbour in a protected area: refused, nothing dug, the area named", name == nil and W.dug == nil
        and why:find("0,-1,2: in the protected area edge", 1, true) ~= nil, tostring(why))
    name = T.placeAt(0, 0, 3, SL, { half = "top", digBelow = true, inside = "edge" })
    check("...unless the job owns it (opts.inside)", name ~= nil and has(0, 0, 3, "oak_slab", { type = "top" }) and allBack("stone_bricks", "polished_andesite"))
    solidScene(FLOOR, ANDESITE, { stone(1, 0, 3), stone(-1, 0, 3), stone(0, 0, 4), { 0, -1, 1, "minecraft:lava" } })
    name, why = T.placeAt(0, 0, 3, SL, { half = "top", digBelow = true })
    check("...lava beside the only neighbour: refused, nothing dug, the lava named", name == nil and W.dug == nil
        and why:find("0,-1,2: minecraft:lava beside it at 0,-1,1", 1, true) ~= nil, tostring(why))
    solidScene(STONE, STONE)
    name, why = T.placeAt(0, 0, 3, SL, { half = "top" })
    check("...every need named at once: the option, and two stone to carry (the floor and the neighbour)", name == nil and W.dug == nil
        and why:find("opts.digBelow = true", 1, true) ~= nil and why:find("carry two minecraft:stone", 1, true) ~= nil, tostring(why))
    solidScene(STONE, { "minecraft:soul_soil", STONE, STONE, STONE }, OVER3)
    for slot = 2, 16 do W.give(slot, "minecraft:dirt", 64) end
    name, why = T.placeAt(0, 0, 3, SL, { half = "top", digBelow = true })
    check("...a stone floor beside soul soil, nothing carried and no free slot: both needs named at once, nothing dug", name == nil
        and W.dug == nil and why:find("carry one minecraft:stone", 1, true) ~= nil and why:find("free a slot", 1, true) ~= nil
        and why:find("soul_soil", 1, true) ~= nil, tostring(why))
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
