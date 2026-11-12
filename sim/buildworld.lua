-- sim/buildworld.lua
--
-- The mock itself (sim/lib/buildworld.lua): later pieces of ADR-0008 (tl.place, tl.blueprint, tl.craft, the
-- furnace) trust it, so each rule of it is checked here, worked out BY HAND from CC:Tweaked 1.120.2's
-- TurtlePlaceCommand and Minecraft's block rules (written in the mock's header), not from its own code:
--   * turtle.place* in the order the game tries: the block beyond the target on its near face, for a sideways
--     place the floor under the target, then the turtle's own block; a sideways click is at 0.45 (bottom half);
--   * each family each way (sideways, placeDown, placeUp; with and without a block to click): stairs and slabs
--     (half, facing, shape, double), logs (axis), torches, ladders, buttons and levers (what they hang on),
--     doors (two blocks, a floor, hinge), trapdoors, fence gates, chests and furnaces;
--   * a cell that cannot take the block, replaceable cells, entities, items that are not blocks, buckets;
--   * digging (the drops, a door's two halves, what hung on a dug block popping off) and inspect;
--   * the crafting grid and the workbench, a chest, and a furnace by its faces with the time it takes.
local PROJ = ...
package.path = PROJ .. "/sim/lib/?.lua;" .. package.path
local M = require("mock")
local B = require("buildworld")
local check = M.check

local STONE = "minecraft:stone"
local function stone(x, y, z) return { x, y, z, STONE } end

-- A fresh world with the turtle at 0,0,0 (heading 0), then the blocks of a scene.
local function world(facing, blocks)
    local w = B.new({ facing = facing })
    w.install()
    for _, b in ipairs(blocks or {}) do w.set(b[1], b[2], b[3], b[4], b[5]) end
    return w
end
local PLACE = { front = function() return turtle.place() end, up = function() return turtle.placeUp() end,
                down = function() return turtle.placeDown() end }
-- Does the block at x,y,z have this name and (at least) these state values?  "air" for nothing.
local function isBlock(w, x, y, z, name, state)
    local b = w.get(x, y, z)
    if not name then return b == nil end
    if not b or b.name ~= "minecraft:" .. name then return false end
    for k, v in pairs(state or {}) do
        if b.state[k] ~= v then return false end
    end
    return true
end

--------------------------------------------------------------------------
-- The table: one row a placement.  How the turtle stands (turn right N times), what blocks are about, which
-- way it places, and what must be there afterwards: a list of {x, y, z, name, state} (state the keys that
-- matter), or refused = true: nothing placed, the item still in hand.
--   F = the cell in front, B = the one beyond it, U = the floor under F
--------------------------------------------------------------------------
local FB, FU = stone(0, 0, 2), stone(0, -1, 1)           -- the block beyond the target, the floor under it
local DB, UB = stone(0, -2, 0), stone(0, 2, 0)           -- beyond the target for placeDown, for placeUp
local F, D, U = { 0, 0, 1 }, { 0, -1, 0 }, { 0, 1, 0 }   -- the target cells
local function want(at, name, state) return { at[1], at[2], at[3], name, state } end

local ROWS = {}
local function row(label, item, how, blocks, wants, extra)
    local r = { label = label, item = item, how = how, blocks = blocks, wants = wants }
    for k, v in pairs(extra or {}) do r[k] = v end
    ROWS[#ROWS + 1] = r
end
local function refused(label, item, how, blocks, extra)
    row(label, item, how, blocks, nil, extra)
    ROWS[#ROWS].refused = true
end

-- Stairs: facing is the placer's way, half from the face clicked and the height
local ST = "minecraft:oak_stairs"
row("stairs sideways, a block beyond: bottom half, facing the heading", ST, "front", { FB }, { want(F, "oak_stairs", { facing = "north", half = "bottom", shape = "straight" }) })
row("stairs sideways, only a floor: bottom half, facing the heading", ST, "front", { FU }, { want(F, "oak_stairs", { facing = "north", half = "bottom" }) })
row("stairs sideways, floor and beyond: the block beyond is clicked first", ST, "front", { FB, FU }, { want(F, "oak_stairs", { facing = "north", half = "bottom" }) })
row("stairs sideways, nothing about: the turtle's own block is clicked, the placer faces back at it", ST, "front", {}, { want(F, "oak_stairs", { facing = "south", half = "bottom" }) })
row("stairs sideways, turned east: facing east", ST, "front", { stone(2, 0, 0) }, { want({ 1, 0, 0 }, "oak_stairs", { facing = "east", half = "bottom" }) }, { turn = 1 })
row("stairs sideways, turned right twice: facing south", ST, "front", { stone(0, 0, -2) }, { want({ 0, 0, -1 }, "oak_stairs", { facing = "south" }) }, { turn = 2 })
row("stairs sideways in a world whose heading 0 is east: facing east", ST, "front", { FB }, { want(F, "oak_stairs", { facing = "east", half = "bottom" }) }, { facing = "east" })
row("stairs placeDown, a block below the target: bottom half", ST, "down", { DB }, { want(D, "oak_stairs", { facing = "north", half = "bottom" }) })
row("stairs placeDown, nothing below the target: top half", ST, "down", {}, { want(D, "oak_stairs", { facing = "north", half = "top" }) })
row("stairs placeUp, a block above the target: top half", ST, "up", { UB }, { want(U, "oak_stairs", { facing = "north", half = "top" }) })
row("stairs placeUp, nothing above the target: bottom half", ST, "up", {}, { want(U, "oak_stairs", { facing = "north", half = "bottom" }) })
row("stairs placeDown turned east: facing east", ST, "down", { DB }, { want(D, "oak_stairs", { facing = "east", half = "bottom" }) }, { turn = 1 })
row("stairs into tall grass replace it", ST, "front", { FB, { 0, 0, 1, "minecraft:short_grass" } }, { want(F, "oak_stairs", { half = "bottom" }) })
refused("stairs into a stone block: refused", ST, "front", { { 0, 0, 1, STONE } })
-- shapes: the corner the neighbours make
row("a stair beside one at right angles in front: outer corner", ST, "front",
    { stone(1, -1, 0), { 2, 0, 0, ST, { facing = "north", half = "bottom", shape = "straight" } } },
    { want({ 1, 0, 0 }, "oak_stairs", { facing = "east", shape = "outer_left" }) }, { turn = 1 })
row("... the one at the other angle: outer, the other hand", ST, "front",
    { stone(1, -1, 0), { 2, 0, 0, ST, { facing = "south", half = "bottom", shape = "straight" } } },
    { want({ 1, 0, 0 }, "oak_stairs", { facing = "east", shape = "outer_right" }) }, { turn = 1 })
row("a stair placed behind one at right angles makes it an inner corner", ST, "front",
    { stone(1, -1, 0), { 1, 0, 1, ST, { facing = "north", half = "bottom", shape = "straight" } } },
    { want({ 1, 0, 0 }, "oak_stairs", { facing = "east", shape = "straight" }), want({ 1, 0, 1 }, "oak_stairs", { facing = "north", shape = "inner_right" }) },
    { turn = 1 })
row("a stair placed in front of one at right angles makes it an outer corner", ST, "front",
    { stone(1, -1, 0), { 1, 0, 1, ST, { facing = "south", half = "bottom", shape = "straight" } } },
    { want({ 1, 0, 1 }, "oak_stairs", { facing = "south", shape = "outer_left" }) }, { turn = 1 })
row("a stair beside one of the other half stays straight", ST, "front",
    { stone(1, -1, 0), { 2, 0, 0, ST, { facing = "north", half = "top", shape = "straight" } } },
    { want({ 1, 0, 0 }, "oak_stairs", { facing = "east", shape = "straight" }) }, { turn = 1 })

-- Slabs
local SL = "minecraft:stone_slab"
row("slab sideways, a block beyond: bottom", SL, "front", { FB }, { want(F, "stone_slab", { type = "bottom" }) })
row("slab sideways, only a floor: bottom", SL, "front", { FU }, { want(F, "stone_slab", { type = "bottom" }) })
row("slab sideways, nothing about: bottom (0.45)", SL, "front", {}, { want(F, "stone_slab", { type = "bottom" }) })
row("slab placeDown, a block below the target: bottom", SL, "down", { DB }, { want(D, "stone_slab", { type = "bottom" }) })
row("slab placeDown, nothing below the target: top", SL, "down", {}, { want(D, "stone_slab", { type = "top" }) })
row("slab placeUp, a block above the target: top", SL, "up", { UB }, { want(U, "stone_slab", { type = "top" }) })
row("slab placeUp, nothing above the target: bottom", SL, "up", {}, { want(U, "stone_slab", { type = "bottom" }) })
row("a slab placeDown on a bottom slab of its kind: double", SL, "down", { { 0, -1, 0, SL, { type = "bottom" } } }, { want(D, "stone_slab", { type = "double" }) })
row("a slab sideways into a bottom slab of its kind, a block beyond: double", SL, "front", { FB, { 0, 0, 1, SL, { type = "bottom" } } }, { want(F, "stone_slab", { type = "double" }) })
row("a slab placeDown into a top slab of its kind: double", SL, "down", { { 0, -1, 0, SL, { type = "top" } } }, { want(D, "stone_slab", { type = "double" }) })
refused("a slab placeDown into a slab of another kind: refused", SL, "down", { { 0, -1, 0, "minecraft:oak_slab", { type = "bottom" } } })
refused("a slab into a double slab: refused", SL, "front", { FB, { 0, 0, 1, SL, { type = "double" } } })

-- Logs and pillars: the axis of the face clicked
row("log sideways, a block beyond: along the heading (z)", "minecraft:oak_log", "front", { FB }, { want(F, "oak_log", { axis = "z" }) })
row("log sideways, only a floor: it stands (y)", "minecraft:oak_log", "front", { FU }, { want(F, "oak_log", { axis = "y" }) })
row("log sideways, nothing about: along the heading", "minecraft:oak_log", "front", {}, { want(F, "oak_log", { axis = "z" }) })
row("log sideways, turned east with a block beyond: x", "minecraft:oak_log", "front", { stone(2, 0, 0) }, { want({ 1, 0, 0 }, "oak_log", { axis = "x" }) }, { turn = 1 })
row("log sideways in a world whose heading 0 is east: x", "minecraft:oak_log", "front", { FB }, { want(F, "oak_log", { axis = "x" }) }, { facing = "east" })
row("log placeDown: y", "minecraft:oak_log", "down", { DB }, { want(D, "oak_log", { axis = "y" }) })
row("log placeUp with nothing above: y", "minecraft:oak_log", "up", {}, { want(U, "oak_log", { axis = "y" }) })
row("a stripped log and a pillar are logs too", "minecraft:stripped_oak_log", "front", { FB }, { want(F, "stripped_oak_log", { axis = "z" }) })
row("quartz pillar", "minecraft:quartz_pillar", "front", { FU }, { want(F, "quartz_pillar", { axis = "y" }) })

-- Torches: a wall torch on the first side with a full face to hang on (the block clicked first), else standing
local TO = "minecraft:torch"
row("torch sideways, a block beyond: hung on it, facing the turtle", TO, "front", { FB }, { want(F, "wall_torch", { facing = "south" }) })
row("soul torch sideways, a block beyond", "minecraft:soul_torch", "front", { FB }, { want(F, "soul_wall_torch", { facing = "south" }) })
row("torch sideways, only a floor: standing", TO, "front", { FU }, { want(F, "torch") })
row("torch sideways, floor and a wall beside: the floor (clicked first)", TO, "front", { FU, stone(1, 0, 1) }, { want(F, "torch") })
row("torch sideways, nothing but a wall to the east: hung on it", TO, "front", { stone(1, 0, 1) }, { want(F, "wall_torch", { facing = "west" }) })
refused("torch sideways, nothing about: refused", TO, "front", {})
row("torch placeDown, a block below the target: standing", TO, "down", { DB }, { want(D, "torch") })
refused("torch placeDown, nothing below: refused", TO, "down", {})
refused("torch placeUp: never (a torch does not hang from a ceiling)", TO, "up", { UB })
refused("torch on a bottom slab: refused (its top is not a support)", TO, "front", { { 0, -1, 1, SL, { type = "bottom" } } })
row("torch on a top slab: standing", TO, "front", { { 0, -1, 1, SL, { type = "top" } } }, { want(F, "torch") })
row("torch on a fence: standing (the post supports the centre)", TO, "front", { { 0, -1, 1, "minecraft:oak_fence" } }, { want(F, "torch") })
refused("torch hung on the side of a bottom slab: refused (not a full face)", TO, "front", { { 0, 0, 2, SL, { type = "bottom" } } })
row("torch on the back of a stair (its tall side toward the turtle): hung on it", TO, "front", { { 0, 0, 2, ST, { facing = "south", half = "bottom" } } }, { want(F, "wall_torch", { facing = "south" }) })
refused("torch on a stair's low side: refused (only its back is full)", TO, "front", { { 0, 0, 2, ST, { facing = "north", half = "bottom" } } })

-- Ladders hang on a side only
local LA = "minecraft:ladder"
row("ladder sideways, a block beyond: on it, facing the turtle", LA, "front", { FB }, { want(F, "ladder", { facing = "south" }) })
refused("ladder sideways, only a floor: refused", LA, "front", { FU })
refused("ladder sideways, nothing about: refused", LA, "front", {})
refused("ladder placeDown over a floor: refused", LA, "down", { DB })
row("ladder with a wall to the west only: on it, facing east", LA, "front", { stone(-1, 0, 1) }, { want(F, "ladder", { facing = "east" }) })
row("a ladder onto the face of a ladder that looks at it: same facing", LA, "front", { { 0, 0, 2, LA, { facing = "south" } } }, { want(F, "ladder", { facing = "south" }) })

-- Buttons and levers: floor, wall or ceiling
local TO_WALL = "minecraft:wall_torch"
local BU, LE = "minecraft:stone_button", "minecraft:lever"
row("button sideways, a block beyond: on the wall", BU, "front", { FB }, { want(F, "stone_button", { face = "wall", facing = "south", powered = false }) })
row("button sideways, only a floor: on the floor, facing the heading", BU, "front", { FU }, { want(F, "stone_button", { face = "floor", facing = "north" }) })
row("button placeDown: on the floor", BU, "down", { DB }, { want(D, "stone_button", { face = "floor", facing = "north" }) })
row("button placeUp: on the ceiling", BU, "up", { UB }, { want(U, "stone_button", { face = "ceiling", facing = "north" }) })
refused("button with nothing to hang on: refused", BU, "front", {})
row("lever sideways, a block beyond: on the wall", LE, "front", { FB }, { want(F, "lever", { face = "wall", facing = "south" }) })
row("lever placeUp: on the ceiling", LE, "up", { UB }, { want(U, "lever", { face = "ceiling" }) })

-- Doors: two blocks, a full block below, the cell above free, the hinge from the neighbours
local DO = "minecraft:oak_door"
row("door sideways, a floor: two blocks, hinge left", DO, "front", { FU },
    { want(F, "oak_door", { facing = "north", half = "lower", hinge = "left", open = false }), want({ 0, 1, 1 }, "oak_door", { facing = "north", half = "upper", hinge = "left" }) })
refused("door with a block beyond but no floor: refused", DO, "front", { FB })
refused("door with the cell above taken: refused", DO, "front", { FU, stone(0, 1, 1) })
refused("door on a bottom slab: refused", DO, "front", { { 0, -1, 1, SL, { type = "bottom" } } })
row("door with a wall to its left: hinge left", DO, "front", { FU, stone(-1, 0, 1) }, { want(F, "oak_door", { hinge = "left" }) })
row("door with a wall to its right: hinge right", DO, "front", { FU, stone(1, 0, 1) }, { want(F, "oak_door", { hinge = "right" }) })
row("door with a wall on both sides: hinge left (the click is in the middle)", DO, "front", { FU, stone(1, 0, 1), stone(-1, 0, 1) }, { want(F, "oak_door", { hinge = "left" }) })
row("door beside a door on its left: hinge right", DO, "front", { FU, { -1, -1, 1, STONE }, { -1, 0, 1, DO, { facing = "north", half = "lower", hinge = "left" } } }, { want(F, "oak_door", { hinge = "right" }) })
refused("door placeDown: the cell above the target is the turtle", DO, "down", { DB })

-- Trapdoors
local TD = "minecraft:oak_trapdoor"
row("trapdoor sideways onto a block beyond: on it, bottom half", TD, "front", { FB }, { want(F, "oak_trapdoor", { facing = "south", half = "bottom", open = false }) })
row("trapdoor sideways onto a floor: bottom half, facing back", TD, "front", { FU }, { want(F, "oak_trapdoor", { facing = "south", half = "bottom" }) })
row("trapdoor sideways, nothing about: on the turtle", TD, "front", {}, { want(F, "oak_trapdoor", { facing = "north", half = "bottom" }) })
row("trapdoor placeDown onto a block below: bottom half", TD, "down", { DB }, { want(D, "oak_trapdoor", { facing = "south", half = "bottom" }) })
row("trapdoor placeDown, nothing below: top half", TD, "down", {}, { want(D, "oak_trapdoor", { facing = "south", half = "top" }) })
row("trapdoor placeUp onto a ceiling: top half", TD, "up", { UB }, { want(U, "oak_trapdoor", { facing = "south", half = "top" }) })

-- Fence gates
local FG = "minecraft:oak_fence_gate"
row("fence gate sideways: facing the heading", FG, "front", { FB }, { want(F, "oak_fence_gate", { facing = "north", in_wall = false, open = false }) })
row("fence gate with nothing about: the placer faces back", FG, "front", {}, { want(F, "oak_fence_gate", { facing = "south" }) })
row("fence gate between walls: in_wall", FG, "front", { FU, { 1, 0, 1, "minecraft:cobblestone_wall" } }, { want(F, "oak_fence_gate", { in_wall = true }) })

-- Containers, and plain blocks
row("a chest faces the placer", "minecraft:chest", "front", { FB }, { want(F, "chest", { facing = "south", type = "single" }) })
row("a furnace faces the placer", "minecraft:furnace", "front", { FB }, { want(F, "furnace", { facing = "south", lit = false }) })
row("a plain block has no state", "minecraft:cobblestone", "front", { FB }, { want(F, "cobblestone") })
row("a plain block into thin air, on the turtle", "minecraft:cobblestone", "front", {}, { want(F, "cobblestone") })

-- Cells that take a block, and cells that do not
row("into water: placed (a liquid is replaced)", "minecraft:cobblestone", "front", { FB, { 0, 0, 1, "minecraft:water" } }, { want(F, "cobblestone") })
row("into water with nothing beyond: placed", "minecraft:cobblestone", "front", { { 0, 0, 1, "minecraft:water" } }, { want(F, "cobblestone") })
row("into lava", "minecraft:cobblestone", "front", { { 0, 0, 1, "minecraft:lava" } }, { want(F, "cobblestone") })
row("a log into water, a floor under it: the floor is clicked (the water is not): it stands", "minecraft:oak_log", "front", { FU, { 0, 0, 1, "minecraft:water" } }, { want(F, "oak_log", { axis = "y" }) })
row("a stair into water with nothing else about: the turtle's own block, facing back", ST, "front", { { 0, 0, 1, "minecraft:water" } }, { want(F, "oak_stairs", { facing = "south" }) })
row("a log with grass beyond and a floor: the grass is not clicked (it would be replaced)", "minecraft:oak_log", "front", { FU, { 0, 0, 2, "minecraft:short_grass" } }, { want(F, "oak_log", { axis = "y" }) })
row("into a fern: replaced", "minecraft:cobblestone", "front", { { 0, 0, 1, "minecraft:fern" } }, { want(F, "cobblestone") })
refused("into stone: refused", "minecraft:cobblestone", "front", { { 0, 0, 1, STONE } })
refused("into a chest: refused", "minecraft:cobblestone", "front", { { 0, 0, 1, "minecraft:chest" } })
row("a water bucket: a source in the cell, the bucket back", "minecraft:water_bucket", "front", { FB }, { want(F, "water", { level = 0 }) })
row("a lava bucket placeDown", "minecraft:lava_bucket", "down", { DB }, { want(D, "lava") })

for _, r in ipairs(ROWS) do
    local w = world(r.facing, r.blocks)
    for _ = 1, r.turn or 0 do turtle.turnRight() end
    w.give(1, r.item, 1)
    local ok, why = PLACE[r.how]()
    local good
    if r.refused then
        good = ok == false and why == "Cannot place block here" and w.carrying(r.item) == 1
    else
        good = ok == true and (w.carrying(r.item) == 0 or w.carrying("minecraft:bucket") == 1)
        for _, wnt in ipairs(r.wants) do
            good = good and isBlock(w, wnt[1], wnt[2], wnt[3], wnt[4], wnt[5])
        end
    end
    local first, detail = r.wants and r.wants[1], nil
    if not good then
        detail = tostring(ok) .. " " .. tostring(why) .. "; got " .. (first and w.show(first[1], first[2], first[3]) or "nothing")
    end
    check(r.label, good, detail)
end

--------------------------------------------------------------------------
-- Messages, counts, entities
--------------------------------------------------------------------------
do
    local w = world(nil, { FB })
    local ok, why = turtle.place()
    check("nothing in the selected slot: false and 'No items to place'", ok == false and why == "No items to place")
    w.give(1, "minecraft:stick", 3)
    ok, why = turtle.place()
    check("an item that is not a block: false and 'Cannot place item here', none used",
        ok == false and why == "Cannot place item here" and w.carrying("minecraft:stick") == 3)
    w.give(1, "minecraft:diamond_pickaxe", 1)
    ok, why = turtle.place()
    check("a pickaxe: not a block", ok == false and why == "Cannot place item here")
    w.give(1, "minecraft:cobblestone", 3)
    check("one item used a place", turtle.place() == true and w.carrying("minecraft:cobblestone") == 2)
    ok, why = turtle.place()
    check("a second place at the same cell is refused (it is full)", ok == false and w.carrying("minecraft:cobblestone") == 2)
    check("the turtle's own cell is never placed into", select(1, turtle.placeUp()) == true and w.get(0, 1, 0) ~= nil and w.carrying("minecraft:cobblestone") == 1)
end
do
    local w = world(nil, { FB })
    w.addEntity(0, 0, 1, "minecraft:minecart")
    w.give(1, STONE, 2)
    local ok, why = turtle.place()
    check("a minecart in the cell: refused, block not placed", ok == false and w.get(0, 0, 1) == nil and w.carrying(STONE) == 2, tostring(why))
    w.addEntity(0, 0, 1, "minecraft:item_frame", true)
    ok = turtle.place()
    check("an item frame takes the item (entity first), no block placed",
        ok == true and w.get(0, 0, 1) == nil and w.carrying(STONE) == 1 and w.entities["0,0,1"].item == STONE)
end
do
    local w = world(nil, { FB })
    w.give(1, "minecraft:cobblestone", 1)
    local ok = turtle.placeDown()
    check("placeDown with nothing below: placed on the turtle's own block", ok == true and w.get(0, -1, 0) ~= nil)
    local _, i = turtle.inspectDown()
    check("inspect shows the block name and its state", i and i.name == "minecraft:cobblestone" and type(i.state) == "table")
    check("inspect of air: false and why", select(1, turtle.inspectUp()) == false and select(2, turtle.inspectUp()) == "No block to inspect")
    w.set(0, 0, 1, "minecraft:oak_stairs", { facing = "east", half = "top", shape = "straight", waterlogged = false })
    local _, s = turtle.inspect()
    check("inspect gives facing and half as strings and booleans as booleans",
        s.name == "minecraft:oak_stairs" and s.state.facing == "east" and s.state.half == "top" and s.state.waterlogged == false)
    s.state.facing = "west"
    check("the state table inspect returns is a copy", w.state(0, 0, 1).facing == "east")
end

--------------------------------------------------------------------------
-- Digging, and what hung on the block
--------------------------------------------------------------------------
do
    local w = world(nil, { { 0, 0, 1, SL, { type = "double" } } })
    check("dig a double slab: two slabs back", turtle.dig() == true and w.carrying(SL) == 2 and w.get(0, 0, 1) == nil)
    check("dig air: false and why", select(2, turtle.dig()) == "Nothing to dig here")
    w.set(0, 0, 1, "minecraft:bedrock")
    check("bedrock does not dig", select(2, turtle.dig()) == "Unbreakable block detected")
    w.set(0, 0, 1, "minecraft:water", { level = 0 })
    check("water does not dig", turtle.dig() == false)
end
do
    local w = world(nil, { FU })
    w.give(1, DO, 1)
    turtle.place()
    check("setup: a door", isBlock(w, 0, 0, 1, "oak_door", { half = "lower" }) and isBlock(w, 0, 1, 1, "oak_door", { half = "upper" }))
    check("dig the door: one door back, both halves gone", turtle.dig() == true and w.carrying(DO) == 1 and w.get(0, 0, 1) == nil and w.get(0, 1, 1) == nil)
    w.give(1, nil)
    w.set(0, 0, 1, DO, { half = "lower", facing = "north", hinge = "left" })
    w.set(0, 1, 1, DO, { half = "upper", facing = "north", hinge = "left" })
    w.set(0, -1, 1, nil)
    w.settle(0, -1, 1)
    check("take the floor from under a door: it pops off, as one door on the ground", w.get(0, 0, 1) == nil and w.get(0, 1, 1) == nil and w.ground["0,0,1"] and w.ground["0,0,1"][1].name == DO and #w.ground["0,0,1"] == 1)
end
do
    local w = world(nil, { FB })
    w.give(1, TO, 1)
    turtle.place()
    check("setup: a wall torch on the block beyond", isBlock(w, 0, 0, 1, "wall_torch", { facing = "south" }))
    w.set(0, 0, 2, nil); w.settle(0, 0, 2)
    check("dig its block: the torch pops off and lies as a torch", w.get(0, 0, 1) == nil and w.ground["0,0,1"] and w.ground["0,0,1"][1].name == TO)
    w.set(0, 0, 1, "minecraft:torch")
    w.set(0, -1, 1, STONE)
    w.set(0, -1, 1, nil); w.settle(0, -1, 1)
    check("a standing torch pops off when its floor goes", w.get(0, 0, 1) == nil)
    w.set(0, 0, 1, "minecraft:torch")
    w.set(0, -1, 1, "minecraft:cobblestone"); w.settle(0, -1, 1)
    check("... and stays on a floor that is there", w.get(0, 0, 1) ~= nil)
    w.set(0, 0, 1, LA, { facing = "south" })
    w.set(0, 0, 2, STONE)
    w.settle(0, 0, 2)
    check("a ladder stays on its block", w.get(0, 0, 1) ~= nil)
    w.set(0, 0, 2, nil); w.settle(0, 0, 2)
    check("a ladder falls off without it", w.get(0, 0, 1) == nil)
    w.set(0, 0, 1, BU, { face = "wall", facing = "south", powered = false })
    w.set(0, 0, 2, nil); w.settle(0, 0, 2)
    check("a button too", w.get(0, 0, 1) == nil)
end
do
    local w = world(nil, { stone(0, 0, 1), { 0, 0, 2, TO_WALL, { facing = "north" } } })
    w.settle(0, 0, 2)
    check("setup: the wall torch is hung on the stone in front", w.get(0, 0, 2) ~= nil)
    check("turtle.dig on that stone: the torch on its far side pops off", turtle.dig() == true and w.get(0, 0, 2) == nil and w.ground["0,0,2"][1].name == "minecraft:torch")
end
do
    local w = world(nil, { { 0, 0, 1, "minecraft:chest", {} } })
    w.get(0, 0, 1).inv[1] = { name = "minecraft:coal", count = 5 }
    check("dig a chest: it and its contents come to the turtle", turtle.dig() == true and w.carrying("minecraft:chest") == 1 and w.carrying("minecraft:coal") == 5)
end

--------------------------------------------------------------------------
-- Moving and detecting
--------------------------------------------------------------------------
do
    local w = world(nil, { { 0, 0, 1, "minecraft:torch" }, { 0, 0, 2, STONE }, { 0, 0, -1, LA, { facing = "south" } } })
    check("detect: a torch counts, air does not", turtle.detect() == true and turtle.detectUp() == false)
    check("the turtle can walk into a torch's cell", turtle.forward() == true and w.S.P.z == 1)
    check("not into stone", turtle.forward() == false)
    w.S.P.z = 0
    turtle.turnLeft(); turtle.turnLeft()
    check("not into a ladder (it has a shape)", turtle.forward() == false)
    w.set(0, 0, -1, "minecraft:water", { level = 0 })
    check("water is passable", turtle.forward() == true)
end

--------------------------------------------------------------------------
-- Items are dropped into the world when nothing takes them
--------------------------------------------------------------------------
do
    local w = world()
    w.give(1, STONE, 5)
    check("drop with no container: lands in the world, counted", turtle.drop(3) == true and w.thrown == 3 and w.carrying(STONE) == 2 and w.ground["0,0,1"][1].count == 3)
end

--------------------------------------------------------------------------
-- The crafting grid and the workbench
--------------------------------------------------------------------------
do
    local w = world()
    EQ.left = nil
    check("no workbench without the crafting table on a side", peripheral.getType("left") == nil and peripheral.wrap("left") == nil)
    w.give(1, "minecraft:crafting_table", 1)
    turtle.select(1); turtle.equipLeft()
    check("equipping the crafting table: the left side is a workbench", peripheral.getType("left") == "workbench" and peripheral.find("workbench") ~= nil)
    check("...whose methods (what T.withPeripheral waits for) are craft", peripheral.getMethods("left")[1] == "craft" and #peripheral.getMethods("left") == 1)
    local bench = peripheral.wrap("left")
    w.give(1, "minecraft:oak_log", 3)
    local ok = bench.craft(2)
    check("a log in the grid: planks, four a log, craft(2) uses two", ok == true and w.carrying("minecraft:oak_planks") == 8 and w.carrying("minecraft:oak_log") == 1)
    w.S.inv = {}
    w.give(1, "minecraft:oak_planks", 4); w.give(5, "minecraft:oak_planks", 4)
    ok = bench.craft()
    check("planks over planks: sticks, four a craft", ok == true and w.carrying("minecraft:stick") == 16 and w.carrying("minecraft:oak_planks") == 0)
    w.S.inv = {}
    w.give(1, "minecraft:coal", 2); w.give(5, "minecraft:stick", 2)
    check("coal over a stick: torches", bench.craft() == true and w.carrying("minecraft:torch") == 8)
    w.S.inv = {}
    w.give(1, "minecraft:oak_planks", 1); w.give(2, "minecraft:birch_planks", 1); w.give(3, "minecraft:oak_planks", 1)
    w.give(5, "minecraft:oak_planks", 1); w.give(7, "minecraft:oak_planks", 1)
    w.give(9, "minecraft:oak_planks", 1); w.give(10, "minecraft:oak_planks", 1); w.give(11, "minecraft:oak_planks", 1)
    check("eight planks of mixed wood round a hole: a chest", bench.craft() == true and w.carrying("minecraft:chest") == 1)
    w.S.inv = {}
    for _, s in ipairs({ 1, 5, 6, 9, 10, 11 }) do w.give(s, "minecraft:stone_bricks", 4) end
    ok = bench.craft(2)
    check("six stone bricks in the stair shape: stairs, four a craft (the name derived: stone_brick_stairs)",
        ok == true and w.carrying("minecraft:stone_brick_stairs") == 8 and w.carrying("minecraft:stone_bricks") == 12)
    w.S.inv = {}
    -- (the mirror image: the long row at the bottom still, the step rising to the right)
    for _, s in ipairs({ 3, 6, 7, 9, 10, 11 }) do w.give(s, "minecraft:cobblestone", 1) end
    check("the stair shape mirrored also works", bench.craft() == true and w.carrying("minecraft:cobblestone_stairs") == 4)
    w.S.inv = {}
    for _, s in ipairs({ 1, 2, 3 }) do w.give(s, "minecraft:oak_planks", 2) end
    check("three planks in a row: six slabs a craft", bench.craft() == true and w.carrying("minecraft:oak_slab") == 12)
    w.S.inv = {}
    for _, s in ipairs({ 1, 2, 3, 5, 6, 7 }) do w.give(s, "minecraft:oak_planks", 1) end
    check("six planks three by two: two trapdoors", bench.craft() == true and w.carrying("minecraft:oak_trapdoor") == 2)
    w.S.inv = {}
    for _, s in ipairs({ 1, 2, 5, 6, 9, 10 }) do w.give(s, "minecraft:spruce_planks", 1) end
    check("six planks two by three: three doors, of the wood they are", bench.craft() == true and w.carrying("minecraft:spruce_door") == 3)
    w.S.inv = {}
    w.give(1, "minecraft:oak_planks", 1); w.give(16, "minecraft:dirt", 1)
    check("an item outside the 3x3 window: no recipe", bench.craft() == false and w.carrying("minecraft:oak_planks") == 1)
    w.S.inv = {}
    w.give(1, "minecraft:stone_bricks", 1); w.give(2, "minecraft:cobblestone", 1); w.give(3, "minecraft:stone_bricks", 1)
    local _, why = bench.craft()
    check("mixed stones in a slab row: no recipe", why == "No matching recipes")
    w.S.inv = {}
    for _, s in ipairs({ 2, 3, 4, 6, 7, 8 }) do w.give(s, "minecraft:oak_log", 1) end
    check("a window one to the right (columns 2-4) is also read", select(2, bench.craft()) == "No matching recipes")
    w.S.inv = {}
    w.give(8, "minecraft:oak_log", 1)
    check("a lone log in the lower right 3x3: planks", bench.craft() == true and w.carrying("minecraft:oak_planks") == 4)
    w.S.inv = {}
    check("an empty grid: no recipe", select(2, bench.craft()) == "No matching recipes")
    w.S.inv = {}
    w.give(1, "minecraft:crimson_planks", 2); w.give(5, "minecraft:crimson_planks", 2)
    check("sticks from crimson planks", bench.craft() == true and w.carrying("minecraft:stick") == 8)
    w.S.inv = {}
    w.give(1, "minecraft:crimson_stem", 1)
    check("a stem is not a log for planks (so no recipe here)", select(2, bench.craft()) == "No matching recipes")
    w.S.inv = {}
    w.give(1, "minecraft:stripped_birch_log", 1)
    check("a stripped log: planks of its wood", bench.craft() == true and w.carrying("minecraft:birch_planks") == 4)
end

--------------------------------------------------------------------------
-- A chest, and a furnace by its faces
--------------------------------------------------------------------------
do
    local w = world(nil, { FB })
    w.give(1, "minecraft:chest", 1)
    turtle.place()
    w.give(2, "minecraft:coal", 10)
    turtle.select(2)
    check("drop into a chest the turtle placed", turtle.drop(4) == true and w.carrying("minecraft:coal") == 6)
    local c = peripheral.wrap("front")
    check("the chest as a peripheral: size and list", c.size() == 27 and c.list()[1].name == "minecraft:coal" and c.list()[1].count == 4)
    check("suck takes it back", turtle.suck(3) == true and w.carrying("minecraft:coal") == 9)
    check("peripheral type of a chest", peripheral.getType("front") == "minecraft:chest")
    local function recipe(...)
        local grid, rows = { {}, {}, {} }, { ... }
        for r, row in ipairs(rows) do
            for c, name in ipairs(row) do
                if name ~= "." then grid[r][c] = name end
            end
        end
        local name, count = B.recipeFor(grid)
        return name, count
    end
    local ingot, nugget, plank, stick = "minecraft:iron_ingot", "minecraft:iron_nugget", "minecraft:oak_planks", "minecraft:stick"
    local n1, c1 = recipe({ plank, stick, plank }, { plank, stick, plank })
    local n2, c2 = recipe({ "minecraft:stone", "minecraft:stone" }, { "minecraft:stone", "minecraft:stone" })
    local n3, c3 = recipe({ ingot, ingot, ingot }, { ingot, ingot, ingot })
    local n4, c4 = recipe({ ingot, ".", ingot }, { ".", ingot })
    local n5, c5 = recipe({ nugget }, { ingot }, { nugget })
    local n6, c6 = recipe({ "minecraft:glass", "minecraft:glass", "minecraft:glass" }, { "minecraft:glass", "minecraft:glass", "minecraft:glass" })
    check("recipes of the mock the craft module is compared with: a fence 3, stone bricks 4, iron bars 16, a bucket, a chain, glass panes 16",
        n1 == "minecraft:oak_fence" and c1 == 3 and n2 == "minecraft:stone_bricks" and c2 == 4 and n3 == "minecraft:iron_bars" and c3 == 16
        and n4 == "minecraft:bucket" and c4 == 1 and n5 == "minecraft:chain" and c5 == 1 and n6 == "minecraft:glass_pane" and c6 == 16,
        tostring(n1) .. " " .. tostring(n2) .. " " .. tostring(n3) .. " " .. tostring(n4) .. " " .. tostring(n5) .. " " .. tostring(n6))
    local methods = peripheral.getMethods("front")
    local names = {}
    for _, m in ipairs(methods or {}) do names[m] = true end
    check("getMethods of a chest lists its methods (list, size, pushItems); of an empty side, nothing", names.list and names.size and names.pushItems and peripheral.getMethods("top") == nil)
end
do
    -- furnace in front: fuel through the side, items from above, the result below
    local w = world(nil, { { 0, 0, 1, "minecraft:furnace", { facing = "south", lit = false } } })
    local f = w.get(0, 0, 1)
    w.give(1, "minecraft:cobblestone", 2)
    turtle.select(1)
    check("a furnace's side takes no stone: the fuel slot stays empty", turtle.drop() == false and f.inv[2] == nil and w.carrying("minecraft:cobblestone") == 2)
    w.give(1, "minecraft:coal", 1)
    check("a furnace's side takes fuel: into the fuel slot", turtle.drop() == true and f.inv[2] and f.inv[2].name == "minecraft:coal" and w.carrying("minecraft:coal") == 0)
    w.give(1, "minecraft:cobblestone", 8)
    check("... but not a stone block (the fuel slot takes fuel)", turtle.drop() == false and f.inv[1] == nil and w.carrying("minecraft:cobblestone") == 8)
    w.give(2, "minecraft:crimson_planks", 3)
    turtle.select(2)
    check("... nor nether planks (not fuel)", turtle.drop() == false and f.inv[2].name == "minecraft:coal")
    -- from above
    w.stand(0, 1, 1)
    turtle.select(1)
    check("dropDown from above puts items in the input slot", turtle.dropDown() == true and f.inv[1].name == "minecraft:cobblestone" and f.inv[1].count == 8)
    w.advance(5)
    check("five seconds: burning, not done", f.state.lit == true and f.inv[3] == nil and f.cook == 100)
    w.advance(5)
    check("ten seconds: one stone out, one cobblestone fewer", f.inv[3] and f.inv[3].name == "minecraft:stone" and f.inv[3].count == 1 and f.inv[1].count == 7)
    sleep(70)
    check("eighty seconds from the start: eight stone (a coal burns 80 s), all the fuel and input used",
        f.inv[3].count == 8 and f.inv[1] == nil and f.inv[2] == nil)
    sleep(0.05)
    check("... and a moment later the fire is out", f.state.lit == false)
    -- from below
    w.stand(0, -1, 1)
    check("the underside gives the result", turtle.suckUp() == true and w.carrying("minecraft:stone") == 8 and f.inv[3] == nil)
    check("... and nothing more", turtle.suckUp() == false)
    w.give(2, "minecraft:charcoal", 1)
    turtle.select(2)
    check("the underside takes fuel too", turtle.dropUp() == true and f.inv[2].name == "minecraft:charcoal")
    w.give(3, "minecraft:cobblestone", 1)
    turtle.select(3)
    check("... not items for the input slot", turtle.dropUp() == false and f.inv[1] == nil)
    sleep(10)
    check("fuel with nothing to smelt does not burn", f.inv[2] and f.inv[2].count == 1 and f.burn == 0)
    f.inv[1] = { name = "minecraft:iron_ore", count = 1 }
    f.inv[1] = { name = "minecraft:raw_iron", count = 2 }
    sleep(10)
    check("raw iron smelts into an ingot in ten seconds", f.inv[3] and f.inv[3].name == "minecraft:iron_ingot" and f.inv[3].count == 1)
    f.inv[3] = { name = "minecraft:stone", count = 1 }
    sleep(20)
    check("a different result will not stack onto the output slot: the second ingot waits", f.inv[1] and f.inv[1].count == 1 and f.inv[3].name == "minecraft:stone")
    f.inv[3] = nil
    f.inv[2] = { name = "minecraft:lava_bucket", count = 1 }
    f.burn = 0
    sleep(10)
    check("a lava bucket burns and leaves a bucket", f.inv[2] and f.inv[2].name == "minecraft:bucket")
    local p = peripheral.wrap("top")
    check("a furnace as a peripheral: three slots", p and p.size() == 3 and peripheral.getType("top") == "minecraft:furnace")
    -- smelt tables
    check("the tables: coal burns 80 s, nether planks do not, logs smelt to charcoal",
        B.fuelTicks("minecraft:coal") == 1600 and B.fuelTicks("minecraft:crimson_planks") == nil
        and B.fuelTicks("minecraft:oak_planks") == 300 and B.smeltsTo("minecraft:oak_log") == "minecraft:charcoal"
        and B.smeltsTo("minecraft:crimson_stem") == nil)
end
do
    -- a furnace the turtle places itself, then feeds
    local w = world(nil, { FB })
    w.give(1, "minecraft:furnace", 1)
    turtle.place()
    w.stand(0, 1, 1)
    w.give(1, "minecraft:sand", 1)
    check("dropDown onto a furnace the turtle placed", turtle.dropDown() == true and w.get(0, 0, 1).inv[1].name == "minecraft:sand")
end

-- Flint and steel: a fire in the target cell, lit from beside (the block beyond clicked) or from above
-- (placeDown onto the block under the target); it needs something solid under the fire and an empty cell,
-- and the item stays
do
    local FLINT = "minecraft:flint_and_steel"
    local w = world(nil, { { 0, -1, 1, "minecraft:netherrack" }, { 0, 0, 2, STONE } })
    w.give(1, FLINT, 1)
    local ok = turtle.place()
    check("flint and steel sideways onto the block beyond: fire in the target cell, the item stays",
        ok == true and w.get(0, 0, 1) and w.get(0, 0, 1).name == "minecraft:fire" and w.carrying(FLINT) == 1)
    w = world(nil, { { 0, -1, 1, "minecraft:netherrack" } })
    w.stand(0, 1, 1)
    w.give(1, FLINT, 1)
    ok = turtle.placeDown()
    check("flint and steel from above onto a block: the fire is in the cell above it, where the turtle looks",
        ok == true and w.get(0, 0, 1) and w.get(0, 0, 1).name == "minecraft:fire")
    w = world(nil, { { 0, 0, 2, STONE } })
    w.give(1, FLINT, 1)
    check("flint and steel with nothing solid under the fire: refused", turtle.place() == false and w.get(0, 0, 1) == nil)
    w = world(nil, { { 0, -1, 1, "minecraft:netherrack" }, { 0, 0, 1, STONE } })
    w.give(1, FLINT, 1)
    check("flint and steel into a cell that is not empty: refused", turtle.place() == false and w.get(0, 0, 1).name == STONE)
    w = world(nil, { { 0, -1, 1, "minecraft:netherrack" }, { 0, 0, 1, "minecraft:water" }, { 0, 0, 2, STONE } })
    w.give(1, FLINT, 1)
    check("flint and steel into water: refused", turtle.place() == false and w.get(0, 0, 1).name == "minecraft:water")
end

--------------------------------------------------------------------------
-- The pieces: names, directions
--------------------------------------------------------------------------
do
    check("compass: a right turn goes north, east, south, west",
        B.clockwise("north") == "east" and B.clockwise("west") == "north" and B.counterclockwise("north") == "west")
    local w = B.new({ facing = "south" })
    check("heading 0 faces the world's facing, a right turn the next", w.compass(0) == "south" and w.compass(1) == "west" and w.compass(3) == "east")
    local dx, _, dz = w.vec("west")
    check("a compass name is a vector in the turtle's frame", dx == 1 and dz == 0)
    check("families by name", B.familyOf("minecraft:oak_trapdoor") == "trapdoor" and B.familyOf("minecraft:oak_door") == "door"
        and B.familyOf("minecraft:oak_fence_gate") == "fence_gate" and B.familyOf("minecraft:oak_fence") == "fence"
        and B.familyOf("minecraft:soul_wall_torch") == "torch" and B.familyOf("minecraft:cobblestone") == "block")
end
