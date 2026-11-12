-- sim/turtlelib_path.lua
--
-- tl.path (ADR-0008): routes over the map, and walking them.
--   * T.path: a route through known air; round a protected box (and through it with opts.inside), round lava, fire,
--     doors and chests; through a wall only where digging is allowed (and only the blocks opts.dig names); through
--     cells never seen, at a cost, with the unseen counted in the info; the cells opts.avoidCells lists; a goal that
--     is a wall says why; a sealed goal says no route; the node limit says so; a map in another frame; an unaligned map;
--   * the search reads cubes as strings (no T.map.get), and gives the computer a turn on a clock;
--   * T.travel: over a wall under a roof along a clear layer, scanning first when the map doesn't know, a search when
--     there is no layer; an unexpected block is noted in the map and the route planned again, a bounded number of times;
--     protected areas kept out of; T.moveTo's opts.path asks it.
local PROJ = ...
package.path = PROJ .. "/turtle/?.lua;" .. PROJ .. "/lib/?.lua;" .. PROJ .. "/sim/lib/?.lua;" .. package.path
local M = require("mock")
local check = M.check

local S = M.state()
os.epoch = function() return 1000 * 1000 end
-- A clock that moves by STEP each time it's read (0: stands still)
local CLK, STEP = 0, 0
os.clock = function() CLK = CLK + STEP; return CLK end
fs = M.fsApi(S)
textutils = M.textutilsApi()
shell = M.shellApi("x.lua")
SLEEPS = 0
sleep = function() SLEEPS = SLEEPS + 1 end
local SETTINGS, DEFAULTS = {}, {}
settings = {
    define = function(name, opts) DEFAULTS[name] = opts.default end,
    get = function(name) if SETTINGS[name] ~= nil then return SETTINGS[name] end return DEFAULTS[name] end,
}
local realPrint = print
print = function() end

--------------------------------------------------------------------------
-- The world: blocks by cell of the turtle's frame; nothing is air
--------------------------------------------------------------------------
local W = {}
local function get(x, y, z) return W[M.key(x, y, z)] or nil end
local function put(x, y, z, name, fluid) W[M.key(x, y, z)] = name and { name = name, fluid = fluid } or nil end
local function box(x1, y1, z1, x2, y2, z2, name, fluid)
    for x = x1, x2 do for y = y1, y2 do for z = z1, z2 do put(x, y, z, name, fluid) end end end
end
S.get = get
local DIGS = 0
local STONE, LAVA, DOOR, CHEST, DIRT, AIR = "minecraft:stone", "minecraft:lava", "minecraft:oak_door", "minecraft:chest",
    "minecraft:dirt", "minecraft:air"

-- The geo scanner, as in the world sim
local scanCalls = 0
local function scanBlocks(r)
    scanCalls = scanCalls + 1
    local px, py, pz, d = S.P.x, S.P.y, S.P.z, S.P.d
    local out = {}
    for dy = -r, r do for dz = -r, r do for dx = -r, r do
        local b = get(px + dx, py + dy, pz + dz)
        if b then
            out[#out + 1] = { name = b.name, tags = {}, x = dx, y = dy, z = dz, u = dy,
                f = dx * M.DX[d] + dz * M.DZ[d], r = dx * M.DX[(d + 1) % 4] + dz * M.DZ[(d + 1) % 4] }
        end
    end end end
    return out
end
local SCANNER, PICK = "advancedperipherals:geo_scanner", "minecraft:diamond_pickaxe"
EQ = { left = SCANNER, right = PICK }
peripheral = {
    getType = function(side) return (EQ[side] == SCANNER) and "geoScanner" or nil end,
    getMethods = function(side) return EQ[side] == SCANNER and { "scanBlocks" } or {} end,
    wrap = function(side) if EQ[side] == SCANNER then return { scanBlocks = scanBlocks } end end,
}

local function inspectAt(x, y, z)
    local b = get(x, y, z)
    if not b or b.entity then return false, "No block to inspect" end
    return true, { name = b.name, state = {} }
end
local function newTurtle()
    turtle = M.merge(
        M.inventoryApi(S), M.equipmentApi(S), M.fuelApi(S), M.noAttackApi(),
        M.movementApi(S, function(b) return b == nil or b.fluid == true end),
        M.lookingApi(S, inspectAt, function(b) return b ~= nil and not b.fluid end),
        M.actingApi(S, "dig", function(x, y, z)
            local b = get(x, y, z)
            if not b or b.fluid then return false, "Nothing to dig here" end
            if b.name == "minecraft:bedrock" then return false, "Unbreakable block detected" end
            DIGS = DIGS + 1
            put(x, y, z, nil)
            return true
        end))
end

-- A new start of the computer: the turtle API unwrapped, turtlelib and the modules loaded afresh, the disk as it was.
local function reboot()
    newTurtle()
    package.loaded.turtlelib, package.loaded["tl.world"], package.loaded["tl.path"] = nil, nil, nil
    return require("turtlelib")
end
-- An empty disk and an empty world; the turtle at 0,0,0 facing 0.
local function fresh()
    S.files, S.dirs, S.inv, S.sel = {}, {}, {}, 1
    W, DIGS, scanCalls, SLEEPS, STEP = {}, 0, 0, 0, 0
    EQ.left, EQ.right = SCANNER, PICK
    S.P.x, S.P.y, S.P.z, S.P.d = 0, 0, 0, 0
    S.moves, S.turns = 0, 0
    return reboot()
end
-- The turtle (really, and as the library counts) at x, y, z facing d.
local function tp(T, x, y, z, d)
    S.P.x, S.P.y, S.P.z, S.P.d = x, y, z, d or 0
    T.pos.x, T.pos.y, T.pos.z, T.dir = x, y, z, d or 0
    T.savePos()
end
-- Put the world's cells in the box into the map, as a perfect scan would: air where nothing is.
local function learn(T, x1, y1, z1, x2, y2, z2)
    for x = x1, x2 do for y = y1, y2 do for z = z1, z2 do
        local b = get(x, y, z)
        T.map.set(x, y, z, b and b.name or AIR)
    end end end
end
local function has(list, x, y, z)
    for _, c in ipairs(list) do if c.x == x and c.y == y and c.z == z then return true end end
    return false
end
-- A route is walkable: each cell a step from the one before (the first from `from`)
local function connected(route, from)
    local px, py, pz = from.x, from.y, from.z
    for _, c in ipairs(route) do
        if math.abs(c.x - px) + math.abs(c.y - py) + math.abs(c.z - pz) ~= 1 then return false end
        px, py, pz = c.x, c.y, c.z
    end
    return true
end
local function at(T) return string.format("(%d,%d,%d)", T.pos.x, T.pos.y, T.pos.z) end
-- Where the turtle's moves went (T.onChange): the cells it was in, after the first
local visited
local function watch(T)
    visited = {}
    T.onChange(function(e) if e.kind == "move" then visited[#visited + 1] = { x = e.x, y = e.y, z = e.z } end end)
end
local function highest(list)
    local top = -math.huge
    for _, c in ipairs(list) do top = math.max(top, c.y) end
    return top
end

--------------------------------------------------------------------------
-- Nothing loaded until it is used
--------------------------------------------------------------------------
local T = fresh()
check("T.path and T.travel are in the registry, and loading turtlelib loads no path module",
    T.registry.path == "tl.path" and T.registry.travel == "tl.path" and package.loaded["tl.path"] == nil)

--------------------------------------------------------------------------
-- Known air
--------------------------------------------------------------------------
T = fresh()
learn(T, -12, -3, -12, 12, 3, 12)
local calls = { get = 0, cube = 0 }
local mapGet, mapCube = T.map.get, T.map.cube
T.map.get = function(...) calls.get = calls.get + 1; return mapGet(...) end
T.map.cube = function(...) calls.cube = calls.cube + 1; return mapCube(...) end
local route, info = T.path(3, 0, 4)
check("T.path loads the module the first time it is used", package.loaded["tl.path"] ~= nil)
check("through known air: the straight way, a cell at a time, the goal last",
    route and #route == 7 and connected(route, T.pos) and route[#route].x == 3 and route[#route].y == 0 and route[#route].z == 4
    and info.cost == 7 and info.digs == 0 and info.unknown == 0, route and #route or tostring(info))
check("...nothing moved", at(T) == "(0,0,0)" and S.moves == 0)
check("...and the search read cubes whole (T.map.cube), never cell by cell (T.map.get)", calls.get == 0 and calls.cube > 0 and calls.cube <= 40,
    calls.get .. " gets, " .. calls.cube .. " cubes")
T.map.get, T.map.cube = mapGet, mapCube
route = T.path(0, 0, 0)
check("already there: an empty route", route and #route == 0)
route = T.path(0, 3, 0)
check("straight up", route and #route == 3 and route[3].y == 3 and connected(route, T.pos))
route = T.path(1, 2, 3, { from = { x = 5, y = 5, z = 5 } })
check("opts.from plans from elsewhere", route and connected(route, { x = 5, y = 5, z = 5 }) and #route == 4 + 3 + 2 and at(T) == "(0,0,0)")
local why
route, why = T.path(1.5, 0, 0)
check("a cell of whole numbers", route == nil and why:find("whole numbers", 1, true), tostring(why))
route, why = T.path(1, 0, 0, { from = { x = 1 } })
check("opts.from is a cell too", route == nil and why:find("opts.from", 1, true), tostring(why))

--------------------------------------------------------------------------
-- Protected areas
--------------------------------------------------------------------------
T.protect("castle", -2, -3, 2, 2, 3, 3)
route, info = T.path(0, 0, 6)
local inBox = false
for _, c in ipairs(route or {}) do if T.protected(c.x, c.y, c.z) then inBox = true end end
check("round a protected box that fills the known height: a detour, none of its cells inside",
    route and not inBox and connected(route, T.pos) and #route == 6 + 6 and route[#route].z == 6, route and #route or tostring(info))
route = T.path(0, 0, 6, { inside = "castle" })
check("opts.inside: the area the job owns is an ordinary region (here, air)", route and #route == 6 and has(route, 0, 0, 2))
T.cfg.inside = "castle"
route = T.path(0, 0, 6)
check("...so is T.cfg.inside (T.inside)", route and #route == 6)
T.cfg.inside = nil
route = T.path(0, 0, 3)
check("a goal in an empty cell of a protected area is reachable (only its empty cells)", route and #route == 3 and connected(route, T.pos))
put(1, 0, 3, STONE); T.map.set(1, 0, 3, STONE)
route, why = T.path(1, 0, 3)
check("a goal that is a solid block of a protected area: no route, and why", route == nil and why:find("goal 1,0,3 is inside the protected area castle", 1, true), tostring(why))
put(1, 0, 3, nil); T.map.set(1, 0, 3, AIR)
-- an area the route starts in: its empty cells can be left through
tp(T, 0, 0, 2, 0)
route = T.path(0, 0, 6)
check("a route that starts in an area may leave it through empty cells", route and #route == 4 and connected(route, T.pos), route and #route or tostring(why))
tp(T, 0, 0, 0, 0)
T.unprotect("castle")
-- not through a solid protected block even where digging is allowed
T = fresh()
learn(T, -3, 0, -1, 3, 0, 5)
box(-3, 0, 2, 3, 0, 2, STONE)
learn(T, -3, 0, 2, 3, 0, 2)
local info2
route, info2 = T.path(0, 0, 4, { dig = true, margin = 0 })
check("(control) with dig = true a stone wall is dug through", route and info2.digs == 1)
T.protect("wall", -3, 0, 2, 3, 0, 2)
route = T.path(0, 0, 4, { dig = true, margin = 0 })
check("...but a protected wall is not, even with dig = true", route == nil)
route = T.path(0, 0, 4, { dig = true, margin = 0, inside = "wall" })
check("...unless the job owns it (opts.inside)", route and #route == 4)
T.unprotect("wall")

--------------------------------------------------------------------------
-- Lava, fire, doors, chests, bedrock, avoidCells
--------------------------------------------------------------------------
T = fresh()
learn(T, -12, -8, -12, 12, 8, 12)
box(-12, -8, 2, 7, 8, 2, LAVA, true)                 -- a lava wall across z = 2, open from x = 8
learn(T, -12, -8, 2, 12, 8, 2)
route = T.path(0, 0, 4)
local touched = false
for _, c in ipairs(route or {}) do if get(c.x, c.y, c.z) then touched = true end end
local dump = {}
for _, c in ipairs(route or {}) do dump[#dump + 1] = c.x .. "," .. c.y .. "," .. c.z end
check("round a lava wall by its gap", route and not touched and connected(route, T.pos) and has(route, 8, 0, 2) and #route == 8 + 4 + 8,
    table.concat(dump, " "))
route = T.path(0, 0, 4, { avoid = {} })
check("avoid = {} avoids nothing: it wades straight through", route and #route == 4 and has(route, 0, 0, 2))
route = T.path(0, 0, 4, { avoid = "minecraft:stone" })
check("avoid replaces the default list (here, lava is no longer avoided)", route and #route == 4)
box(8, -8, 2, 12, 8, 2, LAVA, true)
learn(T, 8, -8, 2, 12, 8, 2)
route = T.path(0, 0, 4)
check("a wall across the whole of the known box: the way round is through what was never seen, over it", route and connected(route, T.pos) and highest(route) >= 9
    and not has(route, 0, 0, 2), route and #route or "nil")
route = T.path(0, 0, 4, { margin = 1 })
check("...and with the search kept to the box of the two ends, none", route == nil)
-- fire, doors
T = fresh()
learn(T, -6, -3, -6, 6, 3, 6)
box(-6, -3, 2, 6, 3, 2, DOOR); put(6, 0, 2, nil); put(6, 1, 2, nil); put(6, 2, 2, nil); put(6, 3, 2, nil); put(6, -1, 2, nil); put(6, -2, 2, nil); put(6, -3, 2, nil)
learn(T, -6, -3, 2, 6, 3, 2)
route = T.path(0, 0, 4, { margin = 8 })
check("doors are walls: the way round is by the one gap", route and not has(route, 0, 0, 2) and has(route, 6, 0, 2))
T = fresh()
learn(T, -2, -2, -2, 2, 2, 8)
put(0, 0, 3, "minecraft:fire"); T.map.set(0, 0, 3, "minecraft:fire")
route = T.path(0, 0, 5, { from = { x = 0, y = 0, z = 1 } })
check("fire is a wall", route and not has(route, 0, 0, 3) and #route == 6)
-- chest
T = fresh()
learn(T, -3, 0, 0, 3, 0, 6)
box(-3, 0, 3, 3, 0, 3, CHEST)
learn(T, -3, 0, 3, 3, 0, 3)
route = T.path(0, 0, 5, { dig = true, margin = 2 })
check("a chest is never dug, even with dig = true", route and not has(route, 0, 0, 3), route and #route or "nil")
T.cfg.digContainers = true
route = T.path(0, 0, 5, { dig = true, margin = 2 })
check("...unless T.cfg.digContainers says it may be", route and #route == 5 and has(route, 0, 0, 3))
T.cfg.digContainers = nil
-- bedrock
T = fresh()
learn(T, -2, 0, 0, 2, 0, 4)
box(-2, 0, 2, 2, 0, 2, "minecraft:bedrock")
learn(T, -2, 0, 2, 2, 0, 2)
route = T.path(0, 0, 4, { dig = true, margin = 1 })
check("bedrock is a wall whatever may be dug", route and not has(route, 0, 0, 2), route and #route or "nil")
-- avoidCells
T = fresh()
learn(T, -5, 0, -1, 5, 0, 8)
route = T.path(0, 0, 5, { avoidCells = { { x = 0, y = 0, z = 3 } } })
check("opts.avoidCells: a cell a route may not use", route and not has(route, 0, 0, 3) and #route == 7 and connected(route, T.pos), route and #route or "nil")
route, why = T.path(0, 0, 5, { avoidCells = { { x = 0, y = 0, z = 5 } } })
check("...a goal in that list: no route and why", route == nil and why:find("goal", 1, true) and why:find("keep out of", 1, true), tostring(why))

--------------------------------------------------------------------------
-- Digging
--------------------------------------------------------------------------
T = fresh()
learn(T, -6, 0, -1, 6, 0, 8)
box(-6, 0, 3, 6, 0, 3, STONE)
learn(T, -6, 0, 3, 6, 0, 3)
route = T.path(0, 0, 5, { margin = 0 })
check("a wall of stone, dig off: no way (the margin 0 keeps the search to the plane)", route == nil)
route, info = T.path(0, 0, 5, { dig = true })
check("dig = true goes through it, a dig counted", route and #route == 5 and has(route, 0, 0, 3) and info.digs == 1 and info.cost == 4 + 4, route and #route or tostring(info))
route = T.path(0, 0, 5, { dig = "minecraft:dirt", margin = 0 })
check("dig = a glob that doesn't match the wall: still a wall", route == nil)
route, info = T.path(0, 0, 5, { dig = { "minecraft:dirt", "minecraft:st*" } })
check("a list of globs, one matching: dug", route and #route == 5 and info.digs == 1)
-- a short wall: the detour round it is cheaper than a dig
T = fresh()
learn(T, -6, 0, -1, 6, 0, 8)
put(0, 0, 3, STONE); T.map.set(0, 0, 3, STONE)
route, info = T.path(0, 0, 5, { dig = true })
check("a dig costs more than a step: a one-block wall is gone round rather than dug", route and #route == 7 and info.digs == 0, route and #route or "nil")
put(1, 0, 3, STONE); T.map.set(1, 0, 3, STONE); put(-1, 0, 3, STONE); T.map.set(-1, 0, 3, STONE)
route, info = T.path(0, 0, 5, { dig = true })
check("...a three-block wall is dug: the detour round it costs more", route and #route == 5 and info.digs == 1, route and #route or "nil")

--------------------------------------------------------------------------
-- What was never seen
--------------------------------------------------------------------------
T = fresh()
route, info = T.path(0, 0, 5)
check("an empty map: a route through the unseen, and the info counts it", route and #route == 5 and info.unknown == 5 and info.cost == 5 * 3
    and connected(route, T.pos), route and #route or tostring(info))
route, info = T.path(0, 0, 5, { dig = true })
check("...digging everything allowed, the unseen costs a dig", route and info.cost == 5 * 4)
learn(T, -3, 0, -1, 3, 0, 6)
put(0, 0, 3, STONE); T.map.set(0, 0, 3, STONE)
route, info = T.path(0, 0, 5)
check("the known is preferred to the unseen when the detour is short", route and info.unknown == 0 and #route == 7)

--------------------------------------------------------------------------
-- No way, and the limits
--------------------------------------------------------------------------
T = fresh()
learn(T, -2, -2, -2, 2, 2, 2)
route, info = T.path(0, 0, 0, { from = { x = 1, y = 0, z = 0 } })
check("(control) a goal in the open is reachable", route and #route == 1)
box(-1, -1, -1, 1, 1, 1, STONE); put(0, 0, 0, nil)
learn(T, -2, -2, -2, 2, 2, 2)
route, why = T.path(0, 0, 0, { from = { x = 2, y = 0, z = 0 }, margin = 4 })
check("a goal walled in on every side: no route, \"walled off\" and the cells searched", route == nil and why:find("walled off", 1, true)
    and why:find("searched", 1, true), tostring(why))
T = fresh()
learn(T, -20, 0, -20, 20, 0, 20)
route, why = T.path(18, 0, 18, { limit = 10 })
check("the node limit: nil, and the reason says how many cells were searched", route == nil and why:find("gave up after searching 10 cells", 1, true), tostring(why))
route = T.path(18, 0, 18)
check("...the default limit is enough for this", route and #route == 36)

--------------------------------------------------------------------------
-- Yielding
--------------------------------------------------------------------------
T = fresh()
learn(T, -1, 0, -1, 40, 0, 40)
box(37, 0, 38, 37, 0, 38, STONE); box(38, 0, 37, 38, 0, 37, STONE)       -- the far corner is shut in
learn(T, 37, 0, 38, 38, 0, 38); learn(T, 38, 0, 37, 38, 0, 37)
SLEEPS, STEP = 0, 0.05
route, why = T.path(38, 0, 38, { margin = 0 })
check("a long search (the whole plane, 1500 cells) gives the computer a turn on a clock", route == nil and why:find("walled off", 1, true) and SLEEPS >= 3,
    tostring(why) .. " / " .. SLEEPS .. " turns")
SLEEPS = 0
route = T.path(2, 0, 2, { margin = 0 })
check("...a short one does not", route and SLEEPS == 0, SLEEPS .. " turns")
STEP = 0

--------------------------------------------------------------------------
-- The map in another frame, and unaligned
--------------------------------------------------------------------------
T = fresh()
T.alignMap(5, 0, 7, 1)                          -- the turtle's frame sits turned and shifted in the map's
learn(T, -6, -1, -3, 6, 1, 9)
box(-6, -1, 2, 3, 1, 2, LAVA, true)
learn(T, -6, -1, 2, 3, 1, 2)
route = T.path(0, 0, 4)
local wet = false
for _, c in ipairs(route or {}) do if get(c.x, c.y, c.z) then wet = true end end
check("a map whose frame is turned from the turtle's: the route is in the turtle's cells and keeps out of the lava",
    route and not wet and connected(route, T.pos) and has(route, 4, 0, 2) and #route == 4 + 4 + 4, route and #route or "nil")
T.map.clear()
tp(T, 0, 0, 0, 0)
T = fresh()
learn(T, -2, 0, 0, 2, 0, 5)
tp(T, 3, 0, 2, 1)
T.map.flush()
S.files[".turtlepos"] = nil
T = reboot()
T.startAtHome(false)
check("(the position was lost: the map is unaligned)", T.map.frame().aligned == false)
route, info = T.path(0, 0, 4)
check("an unaligned map is not read: every cell is unseen", route and #route == 4 and info.unknown == 4)

--------------------------------------------------------------------------
-- Travel: over a wall under a roof
--------------------------------------------------------------------------
T = fresh()
box(-10, 0, 4, 10, 6, 4, STONE)                -- a wall across z = 4, seven high
box(-10, 9, -10, 10, 9, 10, STONE)             -- a roof at y = 9
learn(T, -10, -1, -10, 10, 10, 10)
watch(T)
local ok
ok, why = T.travel(0, 0, 8, { scan = false })
check("over a wall under a roof: it climbs to the lowest clear layer, crosses, and comes down",
    ok == true and at(T) == "(0,0,8)" and highest(visited) == 7 and S.moves == 7 + 8 + 7 and DIGS == 0, tostring(why) .. " " .. at(T) .. " " .. S.moves .. " moves")
ok = true
for _, c in ipairs(visited) do if c.y >= 9 then ok = false end end
check("...and never reaches the roof", ok == true)
ok = T.travel(0, 0, 8)
check("already there: true, no moves", ok == true and S.moves == 22)

-- a roof lower, the layer between is one cell
T = fresh()
box(-10, 0, 4, 10, 5, 4, STONE); box(-10, 7, -10, 10, 7, 10, STONE)
learn(T, -10, -1, -10, 10, 8, 10)
watch(T)
ok, why = T.travel(0, 0, 8, { scan = false })
check("a roof one above the wall: the one clear layer between is used", ok and highest(visited) == 6 and DIGS == 0, tostring(why) .. " " .. tostring(highest(visited)))

-- no layer: a search
T = fresh()
box(-10, 0, 4, 10, 8, 4, STONE); box(-10, 9, -10, 10, 9, 10, STONE)
box(4, 0, 4, 4, 2, 4, nil)                     -- a hole in the wall at x = 4
box(-10, -1, -10, 10, -1, 10, STONE)           -- a floor
learn(T, -10, -1, -10, 10, 10, 10)
watch(T)
ok, why = T.travel(0, 0, 8, { scan = false })
check("a wall to the roof with a hole in it: no layer, the search finds the hole", ok and at(T) == "(0,0,8)" and S.moves == 4 + 8 + 4 and DIGS == 0
    and has(visited, 4, 0, 4), tostring(why) .. " " .. S.moves .. " moves")

--------------------------------------------------------------------------
-- Travel: protected areas, T.moveTo's opts.path
--------------------------------------------------------------------------
T = fresh()
learn(T, -10, -1, -10, 10, 3, 10)
T.protect("keep", -2, -1, 3, 2, 3, 5)
watch(T)
ok, why = T.travel(0, 0, 8, { scan = false })
local trespass = false
for _, c in ipairs(visited) do if T.protected(c.x, c.y, c.z) then trespass = true end end
check("a protected area is kept out of (over it, the area reaching the top of the known cube is not a layer)", ok and not trespass and at(T) == "(0,0,8)" and DIGS == 0,
    tostring(why) .. " " .. at(T))

T = fresh()
learn(T, -10, -1, -10, 10, 3, 10)
box(-10, -1, 3, 10, 3, 3, STONE)
box(2, 0, 3, 2, 0, 3, nil)
learn(T, -10, -1, 3, 10, 3, 3)
watch(T)
ok, why = T.moveTo(0, 0, 6)
check("(control) T.moveTo alone stops at the wall", ok == false and why:find("blocked by minecraft:stone at 0,0,3", 1, true) and at(T) == "(0,0,2)", tostring(why) .. at(T))
tp(T, 0, 0, 0, 0)
ok, why = T.moveTo(0, 0, 6, { path = true })
check("T.moveTo with opts.path = true asks the route finder, which gets it there", ok == true and at(T) == "(0,0,6)" and DIGS == 0, tostring(why) .. " " .. at(T))
tp(T, 0, 0, 0, 0)
local asked
ok = T.moveTo(0, 0, 6, { path = function(x, y, z, o) asked = { x, y, z }; return false, "nope" end })
check("...and a function in its place", ok == false and asked and asked[3] == 6)

-- no way: the goal is sealed
T = fresh()
learn(T, -4, -2, -2, 4, 2, 6)
box(-1, -1, 4, 1, 1, 6, STONE); put(0, 0, 5, nil)
learn(T, -4, -2, 0, 4, 2, 6)
ok, why = T.moveTo(0, 0, 5, { path = true })
check("a sealed goal: moveTo says why it stopped and that there was no route", ok == false and why:find("blocked by", 1, true) and why:find("no route", 1, true), tostring(why))
ok, why = T.travel(0, 0, 5, { scan = false, margin = 3 })
check("T.travel says no route", ok == false and why:find("no route", 1, true) and why:find("walled off", 1, true), tostring(why))

--------------------------------------------------------------------------
-- Travel: an unexpected block
--------------------------------------------------------------------------
T = fresh()
put(0, 0, 2, STONE)                             -- the map has never seen it
watch(T)
ok, why = T.travel(0, 0, 5, { scan = false })
check("through the unseen: a block the turtle meets is dodged, and the route planned again", ok and at(T) == "(0,0,5)" and DIGS == 0 and not has(visited, 0, 0, 2), tostring(why) .. " " .. at(T))
check("...the block is in the map now", T.map.get(0, 0, 2) == STONE)
check("...the cells it walked are air in the map", T.map.get(0, 0, 1) == AIR and T.map.get(0, 0, 5) == AIR)

-- every way bumps: bounded
T = fresh()
for _, d in ipairs({ { 1, 0, 0 }, { -1, 0, 0 }, { 0, 1, 0 }, { 0, -1, 0 }, { 0, 0, 1 }, { 0, 0, -1 } }) do put(d[1], d[2], 5 + d[3], STONE) end
ok, why = T.travel(0, 0, 5, { scan = false, replans = 2 })
check("blocks all round the goal: it plans again no more than opts.replans times, and says so", ok == false and why:find("gave up after 2 re-plans", 1, true)
    and DIGS == 0, tostring(why))
T = fresh()
for _, d in ipairs({ { 1, 0, 0 }, { -1, 0, 0 }, { 0, 1, 0 }, { 0, -1, 0 }, { 0, 0, 1 }, { 0, 0, -1 } }) do put(d[1], d[2], 5 + d[3], STONE) end
ok, why = T.travel(0, 0, 5, { scan = false, replans = 20 })
check("...and once all six are in the map, there is no route round: the plan says so", ok == false and why:find("no route round", 1, true), tostring(why))
-- a mob that does not move: nothing to note in the map, the cell is kept out of the next plan
T = fresh()
W[M.key(0, 0, 2)] = { entity = true }
watch(T)
ok, why = T.travel(0, 0, 5, { scan = false })
check("a mob in the way that will not move: no block to note, the cell is kept out of the next plan, and it gets round",
    ok and at(T) == "(0,0,5)" and not has(visited, 0, 0, 2) and T.map.get(0, 0, 2) == nil, tostring(why) .. " " .. at(T))
-- a block that can be dug: dig = true goes through it, nothing to re-plan
T = fresh()
put(0, 0, 2, DIRT)
ok, why = T.travel(0, 0, 5, { scan = false, dig = true })
check("with dig = true the unseen block is simply dug", ok and DIGS == 1 and at(T) == "(0,0,5)", tostring(why))
-- out of fuel is not the map's to fix
T = fresh()
FUEL = 0
ok, why = T.travel(0, 0, 5, { scan = false })
check("out of fuel: false and why, no re-plan", ok == false and why:find("out of fuel", 1, true) and not why:find("re-plan", 1, true), tostring(why))
FUEL = nil

--------------------------------------------------------------------------
-- Travel: scanning first when the map does not know
--------------------------------------------------------------------------
T = fresh()
box(-12, 0, 4, 12, 6, 4, STONE); box(-12, 9, -12, 12, 9, 12, STONE)
watch(T)
ok, why = T.travel(0, 0, 6)
check("the map knows nothing: it scans the route's box first, then crosses along the layer the scan showed", ok and scanCalls >= 1 and at(T) == "(0,0,6)" and DIGS == 0
    and highest(visited) == 7, tostring(why) .. " " .. scanCalls .. " scans, " .. at(T))
check("...the scan went into the map", T.map.get(0, 3, 4) == STONE and T.map.get(0, 9, 3) == STONE)
T = fresh()
box(-12, 0, 4, 12, 6, 4, STONE); box(-12, 9, -12, 12, 9, 12, STONE)
ok, why = T.travel(0, 0, 6, { scan = false })
check("opts.scan = false: no scan, a search through the unseen and a re-plan at the wall", scanCalls == 0 and ok ~= nil, tostring(why))
T = fresh()
EQ.left = nil
box(-12, 0, 4, 12, 6, 4, STONE)
ok, why = T.travel(0, 0, 6, { move = { dig = false } })
check("no scanner: the scan fails quietly and the search takes over; it still gets there round the wall (the margin lets it)", ok and at(T) == "(0,0,6)" and DIGS == 0,
    tostring(why) .. " " .. at(T))
EQ.left = SCANNER

print = realPrint
