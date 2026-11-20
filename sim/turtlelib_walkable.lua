-- sim/turtlelib_walkable.lua
--
-- tl.lint (ADR-0012 D1): a build seen by a two-tall player, on sim/lib/buildworld's mock world.
--   * T.lint over a box of the map: a good staircase (an approach, a landing, 3 air above each stair, 2 above the
--     top one with a level exit) gives no warnings; too little headroom over a stair; an approach blocked and one with
--     no floor; an exit into a wall and one out over an edge; railings meeting only on a diagonal, level and stepped,
--     and closed by a corner piece; an unrailed drop of 4 (a drop of 3 is fine); a lantern at head height (one a block
--     higher is fine); each warning names the cell and the rule; (ADR-0013) a lone stair against a wall, or two side
--     by side with no step up beyond, is a seat, not a flight (no warnings), and a lone stair up onto a ledge is still checked;
--     a wall torch (soul, redstone) in a walk cell's head or feet cell, a flush light suggested (not one over head height,
--     and a lantern at head height warned of by the lantern rule alone);
--   * T.lint of a plan: the plan's cells and states, the map round it; stairs with no facing counted as unchecked;
--     (ADR-0019) a torch with a facing is its wall torch, so the light rule fires (in T.lint and T.build's lint), and
--     a torch with none stands;
--   * T.build reports the lint's warnings when every cell is tried (in info.warnings and printed, a line a rule) without
--     changing its success, and opts.player = false leaves them out; T.verify(plan, { player = true }) reports them in
--     info.warnings, and without it doesn't;
--   * (ADR-0013) a plan's warnings tagged in the plan or round it (counted in info, the plan's first); T.build prints
--     the plan's and one line counting those round it; a box's lint has no tags.
--   * T.walkable: a path for a 1x2 player up the good staircase; none past a ceiling over the first stair; a step up
--     in a 2-high corridor refused for headroom (3 air needed where the step starts), allowed once the ceiling is
--     raised; a fall of 5 taken only when there is no other way, and listed (refused with opts.maxFall = 3); up a
--     ladder, and not without it; a lantern at head height blocking a corridor, named in the why; a goal the map
--     hasn't seen.
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

    -- (ADR-0013) benches made of stairs: a lone stair with nothing to climb to isn't a flight
    local floor = cube(-2, 0, -2, 6, 0, 8, STONE)
    warnings = lintScene(add(add(cube(-2, 0, -2, 6, 0, 8, STONE), cube(0, 1, 3, 4, 2, 3, STONE)), { { 2, 1, 2, STAIRS, NORTH } }))
    check("a lone stair against a wall (a seat) isn't a flight: no warnings", warnings and #warnings == 0, texts(warnings))
    warnings = lintScene(add(floor, { { 1, 1, 2, STAIRS, NORTH }, { 2, 1, 2, STAIRS, NORTH } }))
    check("...nor two side by side, facing the same way, with no step up beyond them", warnings and #warnings == 0, texts(warnings))
    warnings = lintScene(add(add(cube(-2, 0, -2, 6, 0, 8, STONE), cube(0, 1, 3, 4, 1, 5, STONE)),
        { { 2, 1, 2, STAIRS, NORTH }, { 2, 3, 3, STONE } }))
    exit = ofRule(warnings, "exit")
    check("...but a lone stair up onto a ledge is a flight of one, checked as before", at(exit, 2, 1, 2) ~= nil
        and exit[1].text:find("2,3,3", 1, true) ~= nil, texts(warnings))
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

    -- ADR-0015: one rule with many warnings doesn't take the whole limit (a walkway open on one side: a drop at each
    -- walk cell; a lantern at head height over one), and opts.rules picks the rules
    local open = walkway()
    for i = #open, 1, -1 do
        local b = open[i]
        if b[1] == 2 and b[2] == 5 then table.remove(open, i) end
    end
    add(open, { { 1, 6, 2, "minecraft:lantern", { hanging = "true" } } })
    lintScene(open, { 0, 4, 0, 2, 6, 4 })
    local cut, cutInfo = T.lint({ 0, 4, 0, 2, 6, 4 }, { limit = 3 })
    check("a shared limit: a rule with many warnings (drops) leaves room for the others (the lantern)", cut and #cut == 3
        and #ofRule(cut, "lantern") == 1 and #ofRule(cut, "drop") == 2 and cutInfo.more == cutInfo.rules.drop - 2, texts(cut or {}))
    local only, onlyInfo = T.lint({ 0, 4, 0, 2, 6, 4 }, { rules = { "lantern" } })
    check("...opts.rules checks only the rules named", only and #only == 1 and only[1].rule == "lantern" and onlyInfo.rules.drop == nil,
        texts(only or {}))
    local bad, badWhy = T.lint({ 0, 4, 0, 2, 6, 4 }, { rules = { "lanterns" } })
    check("...a rule it doesn't have: nil and why, naming the rules", bad == nil and badWhy:find("no lint rule lanterns (the rules: headroom", 1, true) ~= nil,
        tostring(badWhy))
    warnings = lintScene(add(cube(-2, 0, -2, 4, 0, 4, STONE), { { 1, 2, 1, "minecraft:lantern", { hanging = "true" } } }), { 0, 0, 0, 2, 2, 2 })
    local lantern = ofRule(warnings, "lantern")
    check("lantern: a lantern at head height over a walk cell is warned of", #lantern == 1 and at(lantern, 1, 1, 1) ~= nil
        and lantern[1].text:find("1,2,1", 1, true) ~= nil, texts(warnings))
    warnings = lintScene(add(cube(-2, 0, -2, 4, 0, 4, STONE), { { 1, 3, 1, "minecraft:soul_lantern", { hanging = "true" } } }), { 0, 0, 0, 2, 3, 2 })
    check("...one a block higher is not", #ofRule(warnings, "lantern") == 0, texts(warnings))

    -- (ADR-0013) lights in a walkway: a wall torch in a walk cell's head or feet cell
    local function lit(y, name)
        return add(cube(-2, 0, -2, 4, 0, 4, STONE), { { 1, 1, 2, STONE }, { 1, 2, 2, STONE }, { 1, 3, 2, STONE },
            { 1, y, 1, name, { facing = "south" } } })
    end
    warnings = lintScene(lit(2, "minecraft:wall_torch"), { 0, 0, 0, 2, 3, 2 })
    local light = ofRule(warnings, "light")
    check("light: a wall torch at head height over a walk cell is warned of, with a flush light suggested", #light == 1 and at(light, 1, 1, 1) ~= nil
        and light[1].text:find("1,2,1", 1, true) ~= nil and light[1].text:find("glowstone", 1, true) ~= nil, texts(warnings))
    warnings = lintScene(lit(1, "minecraft:soul_wall_torch"), { 0, 0, 0, 2, 3, 2 })
    light = ofRule(warnings, "light")
    check("...a soul torch on the wall at the feet too", #light == 1 and at(light, 1, 1, 1) ~= nil and light[1].text:find("soul_wall_torch", 1, true) ~= nil,
        texts(warnings))
    warnings = lintScene(lit(3, "minecraft:redstone_wall_torch"), { 0, 0, 0, 2, 3, 2 })
    check("...one over head height is not", #ofRule(warnings, "light") == 0, texts(warnings))
    warnings = lintScene(add(cube(-2, 0, -2, 4, 0, 4, STONE), { { 1, 2, 1, "minecraft:lantern", { hanging = "true" } } }), { 0, 0, 0, 2, 2, 2 })
    check("...a lantern at head height is the lantern rule's alone (no light warning too)", #ofRule(warnings, "lantern") == 1
        and #ofRule(warnings, "light") == 0, texts(warnings))
end

-- ADR-0015 D8.6: T.walkable{ with = ... }: what-if cells in place of the map's
do
    local blocks = cube(-2, 0, -2, 6, 0, 6, STONE)
    add(blocks, cube(-2, 1, 3, 6, 2, 3, STONE))               -- a wall across z = 3
    add(blocks, { { 2, 1, 3, "minecraft:air" }, { 2, 2, 3, "minecraft:air" } })
    for i = #blocks, 1, -1 do
        local b = blocks[i]
        if b[1] == 2 and b[3] == 3 and (b[2] == 1 or b[2] == 2) and b[4] == STONE then table.remove(blocks, i) end
    end
    fresh(blocks)
    know(-3, -1, -3, 7, 4, 7)
    local path = T.walkable({ 2, 1, 1 }, { 2, 1, 5 })
    check("(control) a doorway in a wall: a walk through it", path ~= nil)
    local none, why = T.walkable({ 2, 1, 1 }, { 2, 1, 5 }, { with = { { 2, 1, 3, "stone" }, { 2, 2, 3, "stone" } } })
    local shown = {}
    for _, c in ipairs(type(none) == "table" and none or {}) do shown[#shown + 1] = c.x .. "," .. c.y .. "," .. c.z end
    check("T.walkable{ with }: the doorway filled, as a what-if: no walk, the map unchanged", none == nil and why:find("no walk", 1, true) ~= nil
        and T.map.get(2, 1, 3) == "minecraft:air", none and table.concat(shown, " ") or tostring(why))
    path = T.walkable({ 2, 1, 1 }, { 2, 1, 5 }, { with = { { 2, 2, 3, "lantern", { hanging = true } } } })
    check("...a lantern hanging in it at head height: no walk either (2 tall)", path == nil)
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

    -- (ADR-0019) a plan names a wall torch by its item (a torch with a facing): lint reads it as the wall torch
    fresh(cube(-2, 0, -2, 4, 0, 4, STONE))
    know(-3, -1, -3, 5, 4, 5)
    local function torchPlan(torch)
        return T.blueprint.new({ anchor = { 1, 1, 2 }, legend = { B = STONE, t = torch },
            layers = { { "B", "." }, { "B", "t" }, { "B" } } })
    end
    warnings = T.lint(torchPlan("minecraft:wall_torch[facing=south]"))
    local light = ofRule(warnings, "light")
    check("a plan's wall torch at head height over a walk cell is warned of (the light rule)", #light == 1 and at(light, 1, 1, 1) ~= nil
        and light[1].text:find("wall_torch at 1,2,1", 1, true) ~= nil, texts(warnings))
    warnings = T.lint(torchPlan("minecraft:soul_torch[facing=south]"))
    check("...named as its item with a facing too (a soul torch)", #ofRule(warnings, "light") == 1, texts(warnings))
    warnings = T.lint(torchPlan("minecraft:torch"))
    check("...a torch with no facing stands, and isn't", #ofRule(warnings, "light") == 0, texts(warnings))
end

--------------------------------------------------------------------------
-- T.build and T.verify report the warnings
--------------------------------------------------------------------------
do
    -- a pillar 5 high on a stone floor: its top is a walk cell over a drop of 5 on every side
    local function pillarScene()
        fresh(cube(-3, -1, -3, 5, -1, 5, STONE))
        know(-3, -1, -3, 5, 6, 5)
        W.give(1, STONE, 5)
        for i = #PRINTED, 1, -1 do PRINTED[i] = nil end
        return T.blueprint.fill(2, 0, 2, 2, 4, 2, STONE)
    end
    local plan = pillarScene()
    local ok, info = T.build(plan, { name = "pillar" })
    local drop = ofRule(info and info.warnings, "drop")
    check("T.build finishes as before and reports the lint's warnings: the pillar's top over a drop of 5",
        ok == true and info.finished and at(drop, 2, 5, 2) ~= nil and drop[1].text:find("drop of 5", 1, true) ~= nil,
        tostring(ok) .. " " .. tostring(info) .. " " .. texts(info and info.warnings))
    local said = table.concat(PRINTED, " | ")
    check("...and prints them, a line a rule", #PRINTED == 1 and said:find("drop at 2,5,2", 1, true) ~= nil, said)
    local diffs, vinfo = T.verify(plan, { player = true })
    check("T.verify(plan, { player = true }): the build as planned, and the warnings", diffs and #diffs == 0 and at(ofRule(vinfo.warnings, "drop"), 2, 5, 2) ~= nil,
        texts(vinfo and vinfo.warnings))
    diffs, vinfo = T.verify(plan)
    check("...without player = true, no lint", diffs and #diffs == 0 and vinfo.warnings == nil)

    plan = pillarScene()
    ok, info = T.build(plan, { name = "pillar", player = false })
    check("T.build with player = false: no lint, nothing printed", ok == true and info.warnings == nil and #PRINTED == 0, table.concat(PRINTED, " | "))

    plan = pillarScene()
    ok, _, info = T.build(plan, { name = "pillar", limit = 2 })
    check("...nor for a build stopped before every cell was tried", ok == false and info.warnings == nil and #PRINTED == 0, table.concat(PRINTED, " | "))

    -- (ADR-0013) the plan's warnings apart from those round it: a planned pillar at x = 4 and, inside the plan's box
    -- but left alone by it, the map's own pillar at x = 0, each with a drop of 5 round its top
    fresh(add(cube(-3, -1, -3, 7, -1, 5, STONE), cube(0, 0, 2, 0, 4, 2, STONE)))
    know(-3, -1, -3, 7, 6, 5)
    W.give(1, STONE, 5)
    for i = #PRINTED, 1, -1 do PRINTED[i] = nil end
    plan = T.blueprint.new({ anchor = { 0, 0, 2 }, legend = { B = STONE }, layers = { { "    B" }, { "    B" }, { "    B" }, { "    B" }, { "    B" } } })
    local warnings, lint = T.lint(plan)
    local mine, theirs = at(ofRule(warnings, "drop"), 4, 5, 2), at(ofRule(warnings, "drop"), 0, 5, 2)
    check("a plan's lint tags each warning: in the plan (the planned pillar's top) or round it (the map's pillar)",
        mine and mine.where == "plan" and theirs and theirs.where == "around", texts(warnings))
    check("...its info counts them, and lists the plan's own first", lint and lint.inPlan == 1 and lint.around == 1 and warnings[1] == mine,
        tostring(lint and lint.inPlan) .. " " .. tostring(lint and lint.around))
    ok, info = T.build(plan, { name = "pillars" })
    local said = table.concat(PRINTED, " | ")
    check("T.build prints the plan's warnings and one line for those round it; info.warnings keeps them all",
        ok == true and #PRINTED == 2 and said:find("player: drop at 4,5,2", 1, true) ~= nil and not said:find("0,5,2", 1, true)
        and said:find("player: 1 more round it (T.lint(box) lists them)", 1, true) ~= nil and #info.warnings == 2, said)
    warnings = T.lint({ -1, 0, 1, 5, 4, 3 })
    check("...a box's lint has no tags", warnings and #warnings == 2 and warnings[1].where == nil, texts(warnings))

    -- (ADR-0019) T.build's lint reads a plan's wall torch as one too
    fresh(cube(-2, 0, -2, 4, 0, 4, STONE))
    know(-3, -1, -3, 5, 4, 5)
    W.give(1, STONE, 3)
    W.give(2, "minecraft:torch", 1)
    for i = #PRINTED, 1, -1 do PRINTED[i] = nil end
    plan = T.blueprint.new({ anchor = { 1, 1, 2 }, legend = { B = STONE, t = "minecraft:wall_torch[facing=south]" },
        layers = { { "B", "." }, { "B", "t" }, { "B" } } })
    ok, info = T.build(plan, { name = "torch" })
    said = table.concat(PRINTED, " | ")
    check("T.build prints the light rule's line for a plan's wall torch over a walk cell",
        ok == true and at(ofRule(info.warnings, "light"), 1, 1, 1) ~= nil and said:find("player: light at 1,1,1", 1, true) ~= nil, said)
end

--------------------------------------------------------------------------
-- T.walkable: a path for a 1x2 player
--------------------------------------------------------------------------
local function has(path, x, y, z)
    for _, c in ipairs(path or {}) do if c.x == x and c.y == y and c.z == z then return true end end
    return false
end
local function show(path)
    local out = {}
    for i, c in ipairs(path or {}) do out[i] = c.x .. "," .. c.y .. "," .. c.z end
    return table.concat(out, " ")
end
do
    fresh(staircase())
    know(table.unpack(KNOW))
    local path, info = T.walkable({ 2, 1, 0 }, { x = 2, y = 4, z = 5 })
    check("walkable: up the good staircase to the landing, by its stairs", path and has(path, 2, 2, 2) and has(path, 2, 3, 3) and has(path, 2, 4, 4)
        and path[#path].x == 2 and path[#path].y == 4 and path[#path].z == 5 and #info.falls == 0, show(path) .. " " .. tostring(info))
    local again = T.walkable({ 2, 4, 5 }, { 2, 1, 0 })
    check("...and back down", again ~= nil and has(again, 2, 2, 2), tostring(again))

    fresh(add(staircase(), { { 2, 4, 2, STONE } }))
    know(table.unpack(KNOW))
    local none, why = T.walkable({ 2, 1, 0 }, { 2, 4, 5 })
    check("...none with a ceiling 3 over the first stair (2 air)", none == nil and type(why) == "string" and why:find("no walk", 1, true) ~= nil, tostring(why))

    -- a sealed corridor along +z at x = 0, 2 high, and a step up at z = 3 into a part 2 high over the step
    local function corridor(raised)
        local blocks = cube(-3, -1, -3, 3, -1, 9, STONE)
        add(blocks, cube(-1, 0, -1, -1, 3, 7, STONE))
        add(blocks, cube(1, 0, -1, 1, 3, 7, STONE))
        add(blocks, cube(0, 0, -1, 0, 1, -1, STONE))
        add(blocks, cube(0, 0, 3, 0, 0, 6, STONE))
        add(blocks, cube(0, 1, 7, 0, 2, 7, STONE))
        add(blocks, cube(0, 2, 0, 0, 2, raised and 1 or 2, STONE))
        add(blocks, cube(0, 3, raised and 2 or 3, 0, 3, 6, STONE))
        return blocks
    end
    fresh(corridor(false))
    know(-3, -1, -3, 3, 5, 9)
    none, why = T.walkable({ 0, 0, 0 }, { 0, 1, 6 })
    check("a step up from a 2-high corridor: no walk, for headroom where the step starts", none == nil and why:find("headroom", 1, true) ~= nil
        and why:find("0,2,2", 1, true) ~= nil, tostring(why))
    fresh(corridor(true))
    know(-3, -1, -3, 3, 5, 9)
    path = T.walkable({ 0, 0, 0 }, { 0, 1, 6 })
    check("...with 3 air where it starts, up it", path ~= nil and has(path, 0, 1, 3), tostring(path))

    -- the top of a pillar 5 high: down only by a fall
    fresh(add(cube(-3, -1, -3, 5, -1, 5, STONE), cube(2, 0, 2, 2, 4, 2, STONE)))
    know(-3, -1, -3, 5, 6, 5)
    path, info = T.walkable({ 2, 5, 2 }, { 0, 0, 0 })
    check("a fall of 5 is taken when there is no other way, and listed", path ~= nil and #info.falls == 1 and info.falls[1].height == 5,
        show(path) .. " " .. tostring(info and #info.falls))
    none, why = T.walkable({ 2, 5, 2 }, { 0, 0, 0 }, { maxFall = 3 })
    check("...refused with opts.maxFall = 3, the why naming the fall", none == nil and why:find("fall of 5", 1, true) ~= nil, tostring(why))

    -- a wall 5 high with a ladder up its south face
    local function ladderScene(withLadder)
        local blocks = add(cube(-3, -1, -3, 3, -1, 3, STONE), cube(0, 0, 1, 0, 4, 1, STONE))
        if withLadder then add(blocks, cube(0, 0, 0, 0, 4, 0, "minecraft:ladder")) end
        fresh(blocks)
        know(-3, -1, -3, 3, 7, 3)
    end
    ladderScene(true)
    path = T.walkable({ 2, 0, 0 }, { 0, 5, 1 })
    check("up a ladder to the top of a wall", path ~= nil and has(path, 0, 3, 0) and has(path, 0, 5, 1), show(path))
    ladderScene(false)
    none, why = T.walkable({ 2, 0, 0 }, { 0, 5, 1 })
    check("...and not without it", none == nil and type(why) == "string", tostring(why))

    -- a sealed corridor with a lantern hanging at head height
    local blocks = add(cube(-3, -1, -3, 3, -1, 7, STONE), cube(-1, 0, -1, -1, 2, 5, STONE))
    add(blocks, cube(1, 0, -1, 1, 2, 5, STONE))
    add(blocks, cube(0, 0, -1, 0, 1, -1, STONE))
    add(blocks, cube(0, 0, 5, 0, 1, 5, STONE))
    fresh(add(blocks, { { 0, 1, 2, "minecraft:lantern", { hanging = "true" } } }))
    know(-3, -1, -3, 3, 4, 7)
    none, why = T.walkable({ 0, 0, 0 }, { 0, 0, 4 })
    check("a lantern at head height blocks a corridor, named in the why", none == nil and why:find("lantern at 0,1,2", 1, true) ~= nil, tostring(why))
    W.set(0, 1, 2, nil)
    T.map.set(0, 1, 2, "minecraft:air")
    path = T.walkable({ 0, 0, 0 }, { 0, 0, 4 })
    check("...taken down, the corridor walks", path ~= nil and #path == 4, show(path))

    none, why = T.walkable({ 0, 0, 0 }, { 30, 0, 30 })
    check("a goal the map hasn't seen is refused with why", none == nil and why:find("30,0,30", 1, true) ~= nil, tostring(why))
end
