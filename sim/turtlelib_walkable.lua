-- sim/turtlelib_walkable.lua
--
-- tl.lint (ADR-0012 D1): a build seen by a two-tall player, on sim/lib/buildworld's mock world.
--   * T.lint over a box of the map: a good staircase (an approach, a landing, 3 air above each stair, 2 above the
--     top one with a level exit) gives no warnings; too little headroom over a stair; an approach blocked and one with
--     no floor; an exit into a wall and one out over an edge; railings meeting only on a diagonal, level and stepped,
--     and closed by a corner piece; an unrailed drop of 4 (a drop of 3 is fine); a lantern at head height (one a block
--     higher is fine); each warning names the cell and the rule;
--   * T.lint of a plan: the plan's cells and states, the map round it; stairs with no facing counted as unchecked.
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
local PRINTED = {}
print = function(...) PRINTED[#PRINTED + 1] = table.concat({ ... }, " ") end

local STONE = "minecraft:stone"
local STAIRS = "minecraft:oak_stairs"
local FENCE = "minecraft:oak_fence"
local W, T                                  -- the world, the library
local MODULES = { "turtlelib", "tl.world", "tl.path", "tl.place", "tl.blueprint", "tl.lint" }

-- A new world with the turtle at 0,0,0 (heading 0, +z, is north) and the library loaded afresh, the origin told;
-- then the blocks of the scene: { x, y, z, name, state }.
local function fresh(blocks)
    W = B.new({ facing = "north" })
    W.install()
    CLK = 0
    for _, name in ipairs(MODULES) do package.loaded[name] = nil end
    T = require("turtlelib")
    for _, b in ipairs(blocks or {}) do W.set(b[1], b[2], b[3], b[4], b[5]) end
    T.setOrigin(0, 0, 0, "north")
    return W, T
end
-- The map told what the world holds in a box (air included), states and all.
local function know(x1, y1, z1, x2, y2, z2)
    for x = x1, x2 do for y = y1, y2 do for z = z1, z2 do
        local b = W.get(x, y, z)
        T.map.set(x, y, z, b and b.name or "minecraft:air", b and b.state or nil)
    end end end
end
local function cube(x1, y1, z1, x2, y2, z2, name)
    local out = {}
    for x = x1, x2 do for y = y1, y2 do for z = z1, z2 do out[#out + 1] = { x, y, z, name } end end end
    return out
end
local function add(list, more)
    for _, b in ipairs(more) do list[#list + 1] = b end
    return list
end
-- The warnings of one rule, and whether one is at the cell x, y, z.
local function ofRule(warnings, rule)
    local out = {}
    for _, w in ipairs(warnings or {}) do if w.rule == rule then out[#out + 1] = w end end
    return out
end
local function at(list, x, y, z)
    for _, w in ipairs(list) do if w.x == x and w.y == y and w.z == z then return w end end
    return nil
end
local function texts(warnings)
    local out = {}
    for i, w in ipairs(warnings or {}) do out[i] = w.text end
    return table.concat(out, " | ")
end

--------------------------------------------------------------------------
-- A staircase: a stone floor at y 0, three oak stairs going north (+z) up x = 2, filled under, a landing at the top
--------------------------------------------------------------------------
local NORTH = { facing = "north", half = "bottom" }
local function staircase()
    local blocks = cube(-2, 0, -2, 6, 0, 8, STONE)
    add(blocks, { { 2, 1, 2, STAIRS, NORTH }, { 2, 2, 3, STAIRS, NORTH }, { 2, 3, 4, STAIRS, NORTH },
                  { 2, 1, 3, STONE }, { 2, 1, 4, STONE }, { 2, 2, 4, STONE }, { 2, 3, 5, STONE } })
    return blocks
end
local KNOW = { -3, -1, -3, 7, 8, 9 }
local BOX = { 0, 0, 0, 4, 4, 6 }
local function lintScene(blocks, box)
    fresh(blocks)
    know(table.unpack(KNOW))
    return T.lint(box or BOX)
end

do
    local warnings, info = lintScene(staircase())
    check("a good staircase (an approach, a landing, open above, drops of 3 at most): no warnings",
        warnings ~= nil and #warnings == 0, texts(warnings) .. tostring(info))
    check("...info counts the cells looked at", info and info.cells and info.cells > 0 and info.unchecked == 0)

    -- a ceiling 3 above the top stair (2 air, the exit level: enough) and over the middle one (2 air: too little)
    warnings = lintScene(add(staircase(), { { 2, 6, 4, STONE }, { 2, 5, 3, STONE } }))
    local head = ofRule(warnings, "headroom")
    check("headroom: a stair with 2 air above it, mid-flight, is warned of", at(head, 2, 2, 3) ~= nil, texts(warnings))
    check("...the warning names the cell, the rule and what is in the way",
        at(head, 2, 2, 3) and at(head, 2, 2, 3).text:find("2,2,3", 1, true) and at(head, 2, 2, 3).text:find("headroom", 1, true)
        and at(head, 2, 2, 3).text:find("2,5,3", 1, true), at(head, 2, 2, 3) and at(head, 2, 2, 3).text)
    check("...the top stair with a level exit needs only 2 (no warning)", at(head, 2, 3, 4) == nil and #head == 1, texts(warnings))

    -- the approach: a block at head height in front of the first stair; then no floor there
    warnings = lintScene(add(staircase(), { { 2, 2, 1, STONE } }))
    local approach = ofRule(warnings, "approach")
    check("approach: a block in front of the first stair is warned of, at the first stair",
        at(approach, 2, 1, 2) ~= nil and approach[1].text:find("2,2,1", 1, true) ~= nil, texts(warnings))
    local blocks = staircase()
    for i = #blocks, 1, -1 do
        if blocks[i][1] == 2 and blocks[i][3] == 1 and blocks[i][2] == 0 then table.remove(blocks, i) end
    end
    warnings = lintScene(blocks)
    approach = ofRule(warnings, "approach")
    check("...and an approach with no floor", at(approach, 2, 1, 2) ~= nil and approach[1].text:find("floor", 1, true) ~= nil, texts(warnings))

    -- the exit: into a wall, then out over an edge (no landing)
    warnings = lintScene(add(staircase(), { { 2, 4, 5, STONE } }))
    local exit = ofRule(warnings, "exit")
    check("exit: a flight running into a wall is warned of, at the last stair",
        at(exit, 2, 3, 4) ~= nil and exit[1].text:find("2,4,5", 1, true) ~= nil, texts(warnings))
    blocks = staircase()
    blocks[#blocks] = nil                                 -- (the landing)
    warnings = lintScene(blocks)
    exit = ofRule(warnings, "exit")
    check("...and a flight that runs out over an edge", at(exit, 2, 3, 4) ~= nil and exit[1].text:find("edge", 1, true) ~= nil, texts(warnings))
end

--------------------------------------------------------------------------
-- Railings
--------------------------------------------------------------------------
do
    local floor = cube(-2, 0, -2, 6, 0, 6, STONE)
    local warnings = lintScene(add(cube(-2, 0, -2, 6, 0, 6, STONE), { { 1, 1, 1, FENCE }, { 2, 1, 2, FENCE } }))
    local rail = ofRule(warnings, "railing")
    check("railing: two fences meeting only on a diagonal are warned of, once", #rail == 1 and rail[1].text:find("1,1,1", 1, true)
        and rail[1].text:find("2,1,2", 1, true), texts(warnings))
    warnings = lintScene(add(floor, { { 1, 1, 1, FENCE }, { 2, 1, 2, FENCE }, { 2, 1, 1, FENCE } }))
    check("...a corner piece closes the gap", #ofRule(warnings, "railing") == 0, texts(warnings))
    warnings = lintScene(add(cube(-2, 0, -2, 6, 0, 6, STONE), { { 1, 1, 1, FENCE }, { 1, 2, 2, "minecraft:stone_brick_wall" } }))
    rail = ofRule(warnings, "railing")
    check("...a stepped railing (one post a block higher, on the diagonal) is warned of", #rail == 1, texts(warnings))
    warnings = lintScene(add(cube(-2, 0, -2, 6, 0, 6, STONE), { { 1, 1, 1, FENCE }, { 1, 2, 2, FENCE }, { 1, 2, 1, FENCE } }))
    check("...and closed by a post on top of the lower one", #ofRule(warnings, "railing") == 0, texts(warnings))
end

--------------------------------------------------------------------------
-- Drops and lanterns
--------------------------------------------------------------------------
do
    -- a walkway at y 4 over a floor at y 0 (a drop of 4), fenced on both sides, stone at the ends
    local function walkway()
        local blocks = cube(-3, 0, -3, 5, 0, 7, STONE)
        add(blocks, cube(1, 4, 0, 1, 4, 4, STONE))
        add(blocks, cube(0, 5, 0, 0, 5, 4, FENCE))
        add(blocks, cube(2, 5, 0, 2, 5, 4, FENCE))
        add(blocks, { { 1, 5, -1, STONE }, { 1, 5, 5, STONE }, { 1, 6, -1, STONE }, { 1, 6, 5, STONE } })
        return blocks
    end
    local box = { 0, 4, 0, 2, 4, 4 }
    local warnings = lintScene(walkway(), box)
    check("a walkway railed on both sides: no drop warnings", warnings and #ofRule(warnings, "drop") == 0, texts(warnings))
    local blocks = walkway()
    for i = #blocks, 1, -1 do
        local b = blocks[i]
        if b[1] == 2 and b[2] == 5 and b[3] == 2 then table.remove(blocks, i) end
    end
    warnings = lintScene(blocks, box)
    local drop = ofRule(warnings, "drop")
    check("drop: a gap in the railing over a drop of 4 is warned of, at the walk cell beside it",
        #drop == 1 and at(drop, 1, 5, 2) ~= nil and drop[1].text:find("2,5,2", 1, true) ~= nil and drop[1].text:find("4", 1, true) ~= nil,
        texts(warnings))
    -- the same gap a block lower: a drop of 3
    for _, b in ipairs(blocks) do if b[2] >= 4 then b[2] = b[2] - 1 end end
    warnings = lintScene(blocks, { 0, 3, 0, 2, 3, 4 })
    check("...a drop of 3 is not", #ofRule(warnings, "drop") == 0, texts(warnings))

    warnings = lintScene(add(cube(-2, 0, -2, 4, 0, 4, STONE), { { 1, 2, 1, "minecraft:lantern", { hanging = "true" } } }), { 0, 0, 0, 2, 2, 2 })
    local lantern = ofRule(warnings, "lantern")
    check("lantern: a lantern at head height over a walk cell is warned of", #lantern == 1 and at(lantern, 1, 1, 1) ~= nil
        and lantern[1].text:find("1,2,1", 1, true) ~= nil, texts(warnings))
    warnings = lintScene(add(cube(-2, 0, -2, 4, 0, 4, STONE), { { 1, 3, 1, "minecraft:soul_lantern", { hanging = "true" } } }), { 0, 0, 0, 2, 3, 2 })
    check("...one a block higher is not", #ofRule(warnings, "lantern") == 0, texts(warnings))
end

--------------------------------------------------------------------------
-- A plan: its cells and states, the map round it
--------------------------------------------------------------------------
do
    fresh(cube(-2, 0, -2, 6, 0, 8, STONE))
    know(table.unpack(KNOW))
    local plan = T.blueprint.new({
        anchor = { 2, 1, 4 },
        legend = { s = "oak_stairs[facing=north,half=bottom]", B = STONE },
        layers = { { "B", "B", "s" }, { "B", "s" }, { "s" }, { ".", " ", "B" } },     -- (a ceiling 2 over the first stair)
    })
    local warnings, info = T.lint(plan)
    local head = ofRule(warnings, "headroom")
    check("a plan is linted from its own cells and states: the stair under the plan's ceiling", at(head, 2, 2, 3) == nil and at(head, 2, 1, 2) ~= nil,
        texts(warnings))
    check("...the map round it (the floor in front is the map's): the approach is fine", #ofRule(warnings, "approach") == 0, texts(warnings))
    local bare = T.blueprint.new({ anchor = { 2, 1, 2 }, legend = { s = "oak_stairs" }, layers = { { "s" } } })
    warnings, info = T.lint(bare)
    check("...stairs with no facing are counted as unchecked", info and info.unchecked == 1, tostring(info and info.unchecked))
    local nothing, why = T.lint("not a plan")
    check("...something that is neither a box nor a plan is refused with why", nothing == nil and type(why) == "string", tostring(why))
end
