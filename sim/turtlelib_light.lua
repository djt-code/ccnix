-- sim/turtlelib_light.lua
--
-- tl.light (ADR-0013 D6.1): block light over the map and the cells where a mob could spawn, on sim/lib/buildworld's
-- mock world (the map told what the world holds).
--   * T.light: a room lit by one torch (14 in its cell, 1 less a step), a wall stopping it, the light going round the
--     wall through a gap and losing 1 a step on the way; a torch 13 cells outside the box lighting its edge to 1 and
--     one 14 away not at all; glass letting light through and tinted glass not; a bottom slab's underside stopping
--     light from above; a redstone lamp lit or not by its state, its state guessed (off) when the map lacks it;
--     opts.with (a torch that isn't there, a torch taken away); a bad box, a box too big, a bad opts.with.
--   * T.darkCells: the dark cells of a room cut off by a wall (the overworld's limit, 0), none once a gap lets the
--     light in; floors: stone and a top slab and an upside-down stair are spawnable, a bottom slab, glass, leaves,
--     glowstone and a chest are not, a carpet or a rail over stone leaves no room, a slab with no state is counted as
--     unsure; the nether's groups (light 7 or less, 11 or less, and the cells lit over 11 listed apart for ghasts and
--     magma cubes), magma a floor there but not in the overworld; opts.max; the list cut at opts.limit with the rest
--     counted; the summary line; T.cfg.dimension and a dimension it doesn't know.
--   * A big box yields to the rest of the computer as it goes, with the same answer.
-- tl.attach (ADR-0013 D6.2), on the same mock:
--   * T.attachedTo: a torch on top, a ladder and a wall torch facing away on the sides, a lantern hanging under, all
--     sure; a wall sign with no state a maybe; a button on a side facing along it, a wall torch on another block, a
--     standing lantern under it and a door's upper half not listed; a door's lower half, a ceiling button and vines
--     clinging to it listed; no origin making a facing a maybe; a cell of whole numbers.
--   * T.digCell's opts.attached: "refuse" refusing before it moves, naming what would drop; "warn" digging, the torches
--     dropping in the world, gone from the map, returned and named in the warning; a bad value; and without it the dig
--     as before (tl.attach not even loaded).
local PROJ = ...
package.path = PROJ .. "/turtle/?.lua;" .. PROJ .. "/lib/?.lua;" .. PROJ .. "/sim/lib/?.lua;" .. package.path
local M = require("mock")
local B = require("buildworld")
local realCheck = M.check
-- (a check's detail is only shown when it fails)
local function check(label, ok, detail) realCheck(label, ok, (not ok) and detail or nil) end

os.epoch = function() return 1000 * 1000 end
-- A clock that moves by STEP each time it's read
local CLK, STEP = 0, 0.001
os.clock = function() CLK = CLK + STEP; return CLK end
local SETTINGS, DEFAULTS = {}, {}
settings = {
    define = function(name, opts) DEFAULTS[name] = opts.default end,
    get = function(name) if SETTINGS[name] ~= nil then return SETTINGS[name] end return DEFAULTS[name] end,
}
print = function() end

local STONE, AIR, TORCH = "minecraft:stone", "minecraft:air", "minecraft:torch"
local W, T                                  -- the world, the library
local SLEEPS = 0
local MODULES = { "turtlelib", "tl.world", "tl.path", "tl.lint", "tl.light", "tl.attach" }

-- A new world with the turtle at 0,0,0 and the library loaded afresh, the origin told (unless noOrigin); then the
-- blocks of the scene: { x, y, z, name, state }.
local function fresh(blocks, noOrigin)
    W = B.new({ facing = "north" })
    W.install()
    local worldSleep = sleep
    sleep = function(t) SLEEPS = SLEEPS + 1; return worldSleep(t) end
    CLK, STEP, SLEEPS = 0, 0.001, 0
    for _, name in ipairs(MODULES) do package.loaded[name] = nil end
    T = require("turtlelib")
    for _, b in ipairs(blocks or {}) do W.set(b[1], b[2], b[3], b[4], b[5]) end
    if not noOrigin then T.setOrigin(0, 0, 0, "north") end
    return W, T
end
-- The map told what the world holds in a box (air included), states and all.
local function know(x1, y1, z1, x2, y2, z2)
    for x = x1, x2 do for y = y1, y2 do for z = z1, z2 do
        local b = W.get(x, y, z)
        T.map.set(x, y, z, b and b.name or AIR, b and b.state or nil)
    end end end
end
local function cube(x1, y1, z1, x2, y2, z2, name, state)
    local out = {}
    for x = x1, x2 do for y = y1, y2 do for z = z1, z2 do out[#out + 1] = { x, y, z, name, state } end end end
    return out
end
local function add(list, more)
    for _, b in ipairs(more) do list[#list + 1] = b end
    return list
end
-- A room: a stone shell round x 0..8, y 1..3, z 0..8 (the floor at y 0), with the blocks given in it.
local function room(more)
    local blocks = cube(-1, 0, -1, 9, 4, 9, STONE)
    for i = #blocks, 1, -1 do
        local b = blocks[i]
        if b[1] >= 0 and b[1] <= 8 and b[2] >= 1 and b[2] <= 3 and b[3] >= 0 and b[3] <= 8 then table.remove(blocks, i) end
    end
    return add(blocks, more or {})
end
local ROOM = { 0, 1, 0, 8, 3, 8 }
local function scene(blocks)
    fresh(blocks)
    know(-1, 0, -1, 9, 4, 9)
end
local function find(cells, x, y, z)
    for _, c in ipairs(cells or {}) do if c.x == x and c.y == y and c.z == z then return c end end
    return nil
end
local function show(cells)
    local out = {}
    for i, c in ipairs(cells or {}) do out[i] = c.x .. "," .. c.y .. "," .. c.z .. "=" .. c.light end
    return table.concat(out, " ")
end

--------------------------------------------------------------------------
-- T.light
--------------------------------------------------------------------------
do
    scene(room({ { 4, 1, 4, TORCH } }))
    local level, info = T.light(ROOM)
    check("a torch gives 14 in its own cell", level and level(4, 1, 4) == 14, level and level(4, 1, 4))
    local falls = true
    for x = 0, 8 do for z = 0, 8 do
        if level(x, 1, z) ~= 14 - math.abs(x - 4) - math.abs(z - 4) then falls = false end
    end end
    check("...and 1 less a step through air: 13 beside it, 6 in the far corner", falls and level(4, 1, 5) == 13 and level(0, 1, 0) == 6,
        level(0, 1, 0))
    check("...up too: 13 over it, 12 two over", level(4, 2, 4) == 13 and level(4, 3, 4) == 12)
    check("...a cell outside the box has no answer", level(9, 1, 4) == nil and level(4, 0, 4) == nil)
    check("...info counts the cells and the lights", info.cells == 243 and info.sources == 1 and info.guessed == 0 and info.unseen == nil,
        info.cells .. " " .. info.sources)

    -- a wall at x = 6 with no gap: the cells beyond are dark; with a gap at z = 8 the light goes round, 1 less a step
    local wall = cube(6, 1, 0, 6, 3, 8, STONE)
    scene(room(add({ { 4, 1, 4, TORCH } }, wall)))
    level = T.light(ROOM)
    check("a solid wall stops light: the cells beyond it are 0", level(7, 1, 4) == 0 and level(8, 1, 0) == 0 and level(5, 1, 4) == 13)
    local gap = { { 6, 1, 8, AIR }, { 6, 2, 8, AIR } }
    scene(room(add(add({ { 4, 1, 4, TORCH } }, wall), gap)))
    level = T.light(ROOM)
    check("...a gap at 6,1,8: the light goes round through it, 8 in the gap, 3 at 7,1,4 (not 11, as straight through)",
        level(6, 1, 8) == 8 and level(7, 1, 8) == 7 and level(7, 1, 4) == 3, level(6, 1, 8) .. " " .. level(7, 1, 4))

    -- glass and tinted glass as the wall
    scene(room(add({ { 4, 1, 4, TORCH } }, cube(6, 1, 0, 6, 3, 8, "minecraft:glass"))))
    level = T.light(ROOM)
    check("glass lets light through (1 less a step, as air)", level(6, 1, 4) == 12 and level(7, 1, 4) == 11, level(7, 1, 4))
    scene(room(add({ { 4, 1, 4, TORCH } }, cube(6, 1, 0, 6, 3, 8, "minecraft:tinted_glass"))))
    level = T.light(ROOM)
    check("...tinted glass doesn't", level(6, 1, 4) == 0 and level(7, 1, 4) == 0)

    -- a ceiling of bottom slabs at y 2 with a torch over it: no light comes down through a slab's underside; top slabs
    -- let it into themselves but not out of the top... (from above: a top slab's top face stops it)
    local function slabs(half)
        local blocks = room(cube(0, 2, 0, 8, 2, 8, "minecraft:stone_slab", { type = half }))
        return add(blocks, { { 4, 3, 4, TORCH } })
    end
    scene(slabs("bottom"))
    level = T.light(ROOM)
    check("a floor of bottom slabs takes the light in (13 in the slab under the torch) but not down through it",
        level(4, 2, 4) == 13 and level(4, 1, 4) == 0, level(4, 2, 4) .. " " .. level(4, 1, 4))
    scene(slabs("top"))
    level = T.light(ROOM)
    check("...top slabs stop it at their top face", level(4, 2, 4) == 0 and level(4, 1, 4) == 0)
    -- a torch under a ceiling of top slabs: the light goes up into them
    scene(add(room(cube(0, 3, 0, 8, 3, 8, "minecraft:stone_slab", { type = "top" })), { { 4, 1, 4, TORCH } }))
    level = T.light(ROOM)
    check("...from below, the light goes into top slabs (their underside is open)", level(4, 3, 4) == 12)

    -- a torch 13 cells beyond the box lights its edge cell to 1; 14 beyond, not at all
    local function corridor(tx)
        local blocks = cube(-1, 0, -1, 21, 2, 1, STONE)
        for i = #blocks, 1, -1 do
            local b = blocks[i]
            if b[1] >= 0 and b[1] <= 20 and b[2] == 1 and b[3] == 0 then table.remove(blocks, i) end
        end
        fresh(add(blocks, { { tx, 1, 0, TORCH } }))
        know(-1, 0, -1, 21, 2, 1)
    end
    corridor(19)
    level, info = T.light({ 5, 1, 0, 6, 1, 0 })
    check("a torch 13 cells beyond the box lights the box's edge cell to 1 (the next 0)", level(6, 1, 0) == 1 and level(5, 1, 0) == 0
        and info.sources == 1, level(6, 1, 0))
    corridor(20)
    level = T.light({ 5, 1, 0, 6, 1, 0 })
    check("...14 beyond, it doesn't reach", level(6, 1, 0) == 0)

    -- a redstone lamp by its state, and guessed off
    scene(room({ { 4, 1, 4, "minecraft:redstone_lamp", { lit = true } } }))
    level, info = T.light(ROOM)
    check("a lit redstone lamp gives 15 (14 beside it)", level(4, 2, 4) == 14 and info.guessed == 0)
    scene(room({ { 4, 1, 4, "minecraft:redstone_lamp" } }))
    T.map.set(4, 1, 4, "minecraft:redstone_lamp")
    level, info = T.light(ROOM)
    check("...one whose state the map lacks is taken as off (the game's default), counted as guessed",
        level(4, 2, 4) == 0 and info.guessed == 1, info.guessed)

    -- opts.with: what a torch would do, and a torch taken away
    scene(room({ { 4, 1, 4, TORCH } }))
    level = T.light(ROOM, { with = { { 0, 1, 0, "torch" } } })
    check("opts.with: a torch that isn't there lights as one would (14 at it), the map's torch too",
        level(0, 1, 0) == 14 and level(4, 1, 4) == 14)
    level = T.light(ROOM, { with = { { 4, 1, 4, "minecraft:air" } } })
    check("...and air over the map's torch takes its light away", level(4, 1, 4) == 0 and level(0, 1, 0) == 0)

    local none, why = T.light({ 0, 0, 0 })
    check("a box of fewer than six whole numbers is refused", none == nil and why:find("box", 1, true) ~= nil, tostring(why))
    none, why = T.light({ 0, 0, 0, 100, 10, 100 })
    check("...and a box over 65536 cells", none == nil and why:find("65536", 1, true) ~= nil, tostring(why))
    none, why = T.light(ROOM, { with = { { 1, 1 } } })
    check("...and a bad opts.with", none == nil and why:find("with", 1, true) ~= nil, tostring(why))
end

--------------------------------------------------------------------------
-- T.darkCells
--------------------------------------------------------------------------
do
    local wall = cube(6, 1, 0, 6, 3, 8, STONE)
    scene(room(add({ { 4, 1, 4, TORCH } }, wall)))
    local cells, info = T.darkCells(ROOM)
    local beyond = true
    for _, c in ipairs(cells) do beyond = beyond and c.x >= 7 and c.y == 1 and c.light == 0 end
    check("the overworld: the 18 cells beyond the wall are dark (feet on the floor, 2 air over it, light 0), and no others",
        cells and #cells == 18 and beyond and info.dark == 18 and info.dimension == "overworld" and info.max == 0, show(cells))
    check("...info counts the spawnable cells (every floor cell) and says so in a line",
        info.spawnable == 72 and info.summary == "overworld: of 72 spawnable cells, 18 at light 0 or less (monsters); the darkest 7,1,0 at 0",
        info.summary)
    scene(room(add(add({ { 4, 1, 4, TORCH } }, wall), { { 6, 1, 8, AIR }, { 6, 2, 8, AIR } })))
    cells, info = T.darkCells(ROOM)
    check("...a gap in the wall's far end: the light round it leaves only the 5 cells farthest from the gap dark",
        #cells == 5 and find(cells, 7, 1, 0) and find(cells, 7, 1, 1) and find(cells, 8, 1, 2) and not find(cells, 7, 1, 2)
        and info.spawnable == 73, show(cells))
    scene(room(add(add({ { 4, 1, 4, TORCH } }, wall), { { 6, 1, 4, AIR }, { 6, 2, 4, AIR } })))
    cells, info = T.darkCells(ROOM)
    check("...a gap facing the torch: none are dark (the gap's floor spawnable too), and the line says so",
        #cells == 0 and info.summary == "no dark cells: all 73 spawnable cells have block light over 0", info.summary)

    -- floors: a row along x at z 4 (the rest of the floor is glass, which is no floor); opts.max = 15 lists every
    -- spawnable cell whatever its light (the glowstone lights the room)
    local floors = {
        { 0, 0, 4, STONE }, { 1, 0, 4, "minecraft:stone_slab", { type = "top" } },
        { 2, 0, 4, "minecraft:oak_stairs", { facing = "north", half = "top" } },
        { 3, 0, 4, "minecraft:stone_slab", { type = "bottom" } }, { 4, 0, 4, "minecraft:glass" },
        { 5, 0, 4, "minecraft:oak_leaves" }, { 6, 0, 4, "minecraft:glowstone" }, { 7, 0, 4, "minecraft:chest" },
        { 8, 0, 4, "minecraft:stone_slab" },
    }
    local blocks = add(room(cube(0, 0, 0, 8, 0, 8, "minecraft:glass")), floors)
    add(blocks, { { 0, 0, 6, STONE }, { 0, 1, 6, "minecraft:white_carpet" }, { 1, 0, 6, STONE }, { 1, 1, 6, "minecraft:rail" },
                  { 2, 0, 6, STONE }, { 2, 1, 6, "minecraft:oak_sign" } })
    scene(blocks)
    T.map.set(8, 0, 4, "minecraft:stone_slab")          -- (as a scan gives it: no state)
    cells, info = T.darkCells(ROOM, { max = 15 })
    local function spawns(x, z) return find(cells, x, 1, z) ~= nil end
    check("floors: stone, a top slab and an upside-down stair are spawnable",
        spawns(0, 4) and spawns(1, 4) and spawns(2, 4), show(cells))
    check("...a bottom slab, glass, leaves, glowstone and a chest are not",
        not (spawns(3, 4) or spawns(4, 4) or spawns(5, 4) or spawns(6, 4) or spawns(7, 4)), show(cells))
    check("...a carpet or a rail over stone leaves no room; a sign does", not spawns(0, 6) and not spawns(1, 6) and spawns(2, 6), show(cells))
    check("...a slab whose half the map lacks is unsure, not listed, and the line says to inspect it",
        not spawns(8, 4) and #info.unsure == 1 and info.unsure[1].x == 8 and info.unsure[1].z == 4
            and info.summary:find("1 over a slab or stair whose half the map lacks (info.unsure", 1, true) ~= nil,
        info.summary)
    check("...glowstone lights the cell over it to 14", T.light(ROOM)(6, 1, 4) == 14)

    -- the nether: a corridor lit by a torch at x 0; the floor magma under x 18
    local corridor = cube(-1, 0, -1, 21, 3, 1, STONE)
    for i = #corridor, 1, -1 do
        local b = corridor[i]
        if b[1] >= 0 and b[1] <= 20 and b[2] >= 1 and b[2] <= 2 and b[3] == 0 then table.remove(corridor, i) end
    end
    fresh(add(corridor, { { 0, 1, 0, TORCH }, { 18, 0, 0, "minecraft:magma_block" } }))
    know(-1, 0, -1, 21, 3, 1)
    local BOX = { 1, 1, 0, 20, 1, 0 }
    cells, info = T.darkCells(BOX, { dimension = "nether" })
    -- light 14 - x at feet cell x (the magma's 3 adds 2 over it and 1 beside): x 7..20 at 7 or less (14 cells, magma's
    -- included), x 3..6 at 8..11, x 1..2 over 11; 0 at x 14..16 and 20
    check("the nether: light 7 or less and 11 or less in two groups (the first counted in both)",
        info.dimension == "nether" and info.max == 11 and #cells == 18 and info.groups[1].max == 7 and info.groups[1].count == 14
        and info.groups[2].max == 11 and info.groups[2].count == 18, show(cells))
    check("...the cells lit over 11 listed apart, for ghasts and magma cubes",
        info.anyLightCount == 2 and find(info.anyLight, 1, 1, 0) and find(info.anyLight, 2, 1, 0), show(info.anyLight))
    check("...magma is a floor in the nether", find(cells, 18, 1, 0) ~= nil)
    check("...the line names the groups and the rest",
        info.summary == "nether: of 20 spawnable cells, 14 at light 7 or less (skeletons, wither skeletons, endermen), 18 at light 11 "
            .. "or less (zombified piglins, piglins, hoglins, blazes); the darkest 14,1,0 at 0; 2 more take ghasts, magma cubes "
            .. "whatever the light (a slab or glass floor, or no room, stops them)", info.summary)
    cells, info = T.darkCells(BOX)
    check("...the same in the overworld: only the 4 cells at 0 are dark, magma no floor there, nothing listed apart",
        #cells == 4 and info.spawnable == 19 and info.anyLight == nil and find(cells, 20, 1, 0) and not find(cells, 18, 1, 0), info.summary)
    T.cfg.dimension = "minecraft:the_nether"
    cells, info = T.darkCells(BOX)
    check("T.cfg.dimension says which, the game's name too", info.dimension == "nether" and #cells == 18)
    T.cfg.dimension = nil
    cells, info = T.darkCells(BOX, { max = 9 })
    check("opts.max overrides the limit: one group, at 9 or less", #cells == 15 and #info.groups == 1 and info.groups[1].count == 15,
        show(cells))
    cells, info = T.darkCells(BOX, { dimension = "nether", limit = 5 })
    check("opts.limit cuts the list (darkest first), the rest counted in info.more",
        #cells == 5 and info.more == 13 and info.dark == 18 and cells[1].light == 0 and #info.anyLight == 2, show(cells))
    check("...and the line says so: listed the darkest 5 of 18", info.summary:find("listed the darkest 5 of 18 (opts.limit; info.more 13)", 1, true) ~= nil,
        info.summary)
    local none, why = T.darkCells(BOX, { dimension = "aether" })
    check("a dimension it doesn't know is refused", none == nil and why == "no such dimension: aether (overworld, nether or end)", tostring(why))
end

--------------------------------------------------------------------------
-- A big box yields as it goes
--------------------------------------------------------------------------
do
    local blocks = cube(0, 0, 0, 31, 0, 31, STONE)
    for x = 2, 30, 7 do for z = 2, 30, 7 do blocks[#blocks + 1] = { x, 1, z, TORCH } end end
    fresh(blocks)
    know(-1, -1, -1, 32, 4, 32)
    local cells, info = T.darkCells({ 0, 1, 0, 31, 3, 31 })
    local still = #cells .. " " .. info.spawnable
    fresh(blocks)
    know(-1, -1, -1, 32, 4, 32)
    STEP, SLEEPS = 0.05, 0
    cells, info = T.darkCells({ 0, 1, 0, 31, 3, 31 })
    check("a box of 3072 cells and 25 torches gives the rest of the computer turns as it goes (a clock that moves), with the same answer",
        SLEEPS > 5 and #cells .. " " .. info.spawnable == still, SLEEPS .. " " .. still)
end

--------------------------------------------------------------------------
-- T.attachedTo
--------------------------------------------------------------------------
local function names(list)
    local out = {}
    for i, a in ipairs(list or {}) do
        out[i] = a.name:sub(11) .. "@" .. a.x .. "," .. a.y .. "," .. a.z .. ":" .. a.how .. (a.sure and "" or "?")
    end
    return table.concat(out, " ")
end
do
    -- a block at 2,2,3 (heading 0, +z, is north): a torch on it, a ladder on its north side, a wall torch on its east
    -- side facing east, a wall sign on its west side with no state, a button on its south side facing west (on
    -- another block), a lantern hanging under it
    local around = {
        { 2, 2, 3, STONE }, { 2, 3, 3, TORCH }, { 2, 2, 4, "minecraft:ladder", { facing = "north" } },
        { 3, 2, 3, "minecraft:wall_torch", { facing = "east" } }, { 1, 2, 3, "minecraft:oak_wall_sign" },
        { 2, 2, 2, "minecraft:stone_button", { face = "wall", facing = "west" } },
        { 2, 1, 3, "minecraft:lantern", { hanging = true } },
    }
    fresh(around)
    know(0, 0, 0, 4, 4, 5)
    local list, info = T.attachedTo(2, 2, 3)
    check("T.attachedTo: a torch on top, a ladder and a wall torch facing away on the sides, a lantern hanging under (sure), "
        .. "a wall sign with no state (maybe); not a button facing along the side",
        names(list) == "torch@2,3,3:on top ladder@2,2,4:on the side wall_torch@3,2,3:on the side oak_wall_sign@1,2,3:on the side? "
            .. "lantern@2,1,3:below" and info.sure == 4 and info.maybe == 1, names(list))
    check("...the maybe says why, and the line names them all",
        list[4].why == "the map has no state for it (T.inspectAt)" and info.summary == "digging 2,2,3 would drop minecraft:torch at 2,3,3 "
            .. "(on top), minecraft:ladder at 2,2,4 (on the side), minecraft:wall_torch at 3,2,3 (on the side), minecraft:oak_wall_sign "
            .. "at 1,2,3 (on the side, maybe: the map has no state for it (T.inspectAt)), minecraft:lantern at 2,1,3 (below)", info.summary)

    -- the other way round: what isn't held by it
    fresh({ { 2, 2, 3, STONE }, { 3, 2, 3, "minecraft:wall_torch", { facing = "north" } },
            { 2, 1, 3, "minecraft:lantern", { hanging = false } }, { 2, 3, 3, "minecraft:oak_door", { half = "upper" } } })
    know(0, 0, 0, 4, 4, 5)
    list, info = T.attachedTo(2, 2, 3)
    check("...a wall torch on another block, a lantern standing under it and a door's upper half aren't held by it",
        #list == 0 and info.summary == "nothing in the map hangs on or stands on 2,2,3", names(list))
    fresh({ { 2, 2, 3, STONE }, { 2, 3, 3, "minecraft:oak_door", { half = "lower", facing = "north" } },
            { 2, 2, 2, "minecraft:vine", { north = true } }, { 1, 2, 3, "minecraft:vine", { north = true } },
            { 2, 1, 3, "minecraft:stone_button", { face = "ceiling", facing = "north" } } })
    know(0, 0, 0, 4, 4, 5)
    list = T.attachedTo(2, 2, 3)
    check("...a door's lower half on top, vines on its south side clinging north (not those clinging elsewhere), a ceiling button",
        names(list) == "oak_door@2,3,3:on top vine@2,2,2:on the side stone_button@2,1,3:below", names(list))

    -- no origin: a facing can't be told
    fresh(around, true)
    know(0, 0, 0, 4, 4, 5)
    list, info = T.attachedTo(2, 2, 3)
    check("with no origin, a facing is a maybe (and says so: the button on a side too); what needs no facing is still sure",
        info.sure == 2 and info.maybe == 4 and list[3].why == "no origin for its facing (T.setOrigin)", names(list))
    local none, why = T.attachedTo(2, 2.5, 3)
    check("...a cell of whole numbers", none == nil and why:find("whole numbers", 1, true) ~= nil)
end

--------------------------------------------------------------------------
-- T.digCell and opts.attached
--------------------------------------------------------------------------
do
    -- a floor at y -1; a block at 2,0,3 with a torch on it and a wall torch on its east side
    local function scene2()
        fresh(add(cube(-3, -1, -3, 6, -1, 8, STONE), { { 2, 0, 3, STONE }, { 2, 1, 3, TORCH },
                                                       { 3, 0, 3, "minecraft:wall_torch", { facing = "east" } } }))
        know(-3, -1, -3, 6, 3, 8)
    end
    scene2()
    local ok, why = T.digCell(2, 0, 3, { attached = "refuse" })
    check("T.digCell, opts.attached = \"refuse\": refused before it moves, naming what would drop",
        ok == false and why == "digging 2,0,3 would drop minecraft:torch at 2,1,3 (on top), minecraft:wall_torch at 3,0,3 (on the side) "
            .. "(opts.attached = \"warn\" digs anyway)" and W.get(2, 0, 3) and T.pos.x == 0 and T.pos.z == 0, tostring(why))
    local was, warning, extra
    ok, was, warning, extra = T.digCell(2, 0, 3, { attached = "warn" })
    check("...\"warn\": dug, the torches dropped in the world, and returned and named in the warning",
        ok == true and was == STONE and W.get(2, 0, 3) == nil and W.get(2, 1, 3) == nil and W.get(3, 0, 3) == nil
        and extra and #extra.attached == 2 and warning == "warning: dug 2,0,3, which held minecraft:torch at 2,1,3 (on top), "
            .. "minecraft:wall_torch at 3,0,3 (on the side)", tostring(warning))
    check("...the map has them as air", T.map.get(2, 1, 3) == AIR and T.map.get(3, 0, 3) == AIR and T.map.get(2, 0, 3) == AIR)
    ok, why = T.digCell(2, 0, 4, { attached = "yes" })
    check("...a value it doesn't know is refused", ok == false and why == "opts.attached is \"refuse\" or \"warn\"", tostring(why))
    scene2()
    ok, was, warning, extra = T.digCell(2, 0, 3)
    check("without opts.attached the dig is as before: no look at what it holds (tl.attach not loaded), the torches drop",
        ok == true and was == STONE and warning == nil and extra == nil and package.loaded["tl.attach"] == nil and W.get(2, 1, 3) == nil,
        tostring(warning))
end
