-- sim/turtlelib_moveto.lua
--
-- T.moveTo (ADR-0008): a move to a cell in three dimensions, in the order
-- of axes asked for, that says why it stopped: blocked by a block, a
-- protected area, lava (or fire, or a door, or the player's furnishings), a
-- chest, an unbreakable block,
-- something in the way, no fuel; digging only what it may; and asking a
-- route finder for a way when a straight run is blocked (and, when not
-- asked, saying opts.path is there: ADR-0023 3).
local PROJ = ...
package.path = PROJ .. "/turtle/?.lua;" .. PROJ .. "/lib/?.lua;" .. PROJ .. "/sim/lib/?.lua;" .. package.path
local M = require("mock")
local check = M.check

local S = M.state()
fs = M.fsApi(S)
textutils = M.textutilsApi()
shell = M.shellApi("x.lua")
sleep = function() end

-- The world: air, apart from what is set
local W = {}
local function get(x, y, z) return W[M.key(x, y, z)] or nil end
local function set(x, y, z, b) W[M.key(x, y, z)] = b or nil end
local function block(name, state) return { name = name, state = state } end
local function fluid(name, state) return { name = name, fluid = true, state = state } end
local ENTITY = { entity = true }            -- a mob: nothing to inspect, but it can't be moved into
S.get = get
local DIGS = 0

local function inspectAt(x, y, z)
    local b = get(x, y, z)
    if not b or b.entity then return false, "No block to inspect" end
    return true, { name = b.name, state = b.state or {} }
end
turtle = M.merge(
    M.inventoryApi(S), M.fuelApi(S), M.noAttackApi(),
    M.movementApi(S, function(b) return b == nil or b.fluid == true end),
    M.lookingApi(S, inspectAt, function(b) return b ~= nil and not b.fluid end),
    M.actingApi(S, "dig", function(x, y, z)
        local b = get(x, y, z)
        if not b or b.fluid then return false, "Nothing to dig here" end
        if b.name == "minecraft:bedrock" then return false, "Unbreakable block detected" end
        DIGS = DIGS + 1
        set(x, y, z, nil)
        return true
    end),
    M.actingApi(S, "place", function(x, y, z)
        local b = get(x, y, z)
        if b and not b.fluid then return false, "Cannot place block here" end
        set(x, y, z, block("minecraft:cobblestone"))
        return true
    end))

package.loaded.turtlelib = nil
local T = require("turtlelib")
local function at() return string.format("(%d,%d,%d)", T.pos.x, T.pos.y, T.pos.z) end
local function home(x, y, z, d)
    S.P.x, S.P.y, S.P.z, S.P.d = x or 0, y or 0, z or 0, d or 0
    T.pos.x, T.pos.y, T.pos.z, T.dir = x or 0, y or 0, z or 0, d or 0
    S.moves, S.turns = 0, 0
end
local function clearWorld() W = {}; S.get = get end

--------------------------------------------------------------------------
-- Going there
--------------------------------------------------------------------------
local steps = {}
T.onChange(function(e)
    if e.kind == "move" then
        steps[#steps + 1] = (e.x ~= e.from.x and "x") or (e.y ~= e.from.y and "y") or "z"
    end
end)
home()
local ok, why = T.moveTo(2, 3, 4)
check("moveTo gets there through clear air", ok == true and why == nil and at() == "(2,3,4)" and S.P.x == 2 and S.P.y == 3 and S.P.z == 4, at())
check("...up and down first, then x, then z (\"yxz\")", table.concat(steps) == "yyyxxzzzz", table.concat(steps))
check("...and the position is saved", S.files[".turtlepos"] == "2 3 4 0 flat", tostring(S.files[".turtlepos"]))
steps = {}
home()
ok = T.moveTo(2, 3, 4, { order = "zxy" })
check("an order of axes given is the order walked", ok and table.concat(steps) == "zzzzxxyyy", table.concat(steps))
steps = {}
ok = T.moveTo(2, 3, 4)
check("already there: true, no moves", ok == true and #steps == 0)
home()
ok = T.moveTo(0, 40, -3)
check("a height past T.cfg.maxHeight is fine (the program's grid does not apply)", ok and at() == "(0,40,-3)" and S.P.y == 40, at())
ok, why = T.moveTo(1.5, 0, 0)
check("a cell of whole numbers", ok == false and why and why:find("whole numbers", 1, true), tostring(why))
ok, why = T.moveTo(1, 0, 0, { order = "yq" })
check("an order of the letters x, y, z", ok == false and why and why:find("letters x, y and z", 1, true), tostring(why))

--------------------------------------------------------------------------
-- Blocks in the way
--------------------------------------------------------------------------
clearWorld(); home(); DIGS = 0
set(1, 0, 0, block("minecraft:stone"))
local name, cell
ok, why, name, cell = T.moveTo(3, 0, 0, { order = "x" })
check("a block in the way, dig off: false, \"blocked by <block> at <cell>\", the block and the cell; the why names opts.path (ADR-0023 3)",
    ok == false and why == "blocked by minecraft:stone at 1,0,0; opts.path = true routes round it" and name == "minecraft:stone"
    and cell and cell.x == 1 and cell.y == 0 and cell.z == 0, tostring(why))
check("...the turtle stayed where it got to, the block is there, nothing dug", at() == "(0,0,0)" and get(1, 0, 0) and DIGS == 0)
ok, why = T.moveTo(3, 0, 0, { order = "x", path = false })
check("...with opts.path = false, the why is the block alone", ok == false and why == "blocked by minecraft:stone at 1,0,0", tostring(why))
ok = T.moveTo(3, 0, 0, { order = "x", dig = true })
check("dig = true digs through it", ok and at() == "(3,0,0)" and get(1, 0, 0) == nil and DIGS == 1, at())

clearWorld(); home(); DIGS = 0
set(1, 0, 0, block("minecraft:stone"))
ok, why = T.moveTo(3, 0, 0, { order = "x", dig = "minecraft:*_ore" })
check("dig = a glob that doesn't match: blocked", ok == false and why == "blocked by minecraft:stone at 1,0,0; opts.path = true routes round it" and DIGS == 0, tostring(why))
ok = T.moveTo(3, 0, 0, { order = "x", dig = { "minecraft:*_ore", "minecraft:st*" } })
check("a list of globs, one matching: dug", ok and DIGS == 1 and at() == "(3,0,0)", at())

clearWorld(); home(); DIGS = 0
set(1, 0, 0, block("minecraft:stone")); set(2, 0, 0, block("minecraft:netherrack"))
ok, why = T.moveTo(3, 0, 0, { order = "x", dig = { ["minecraft:stone"] = true, ["*netherrack"] = true } })
check("dig as a set of names and globs digs what it names", ok and DIGS == 2 and at() == "(3,0,0)", tostring(why))
clearWorld(); home(); DIGS = 0
set(1, 0, 0, block("minecraft:stone"))
ok, why = T.moveTo(3, 0, 0, { order = "x", dig = { "stone" } })
check("...and a name without its namespace is matched by its short name", ok and DIGS == 1, tostring(why))
clearWorld(); home(); DIGS = 0
set(1, 0, 0, block("minecraft:stone"))
ok, why = T.moveTo(3, 0, 0, { order = "x", dig = { ["minecraft:stone"] = false } })
check("...but not one set to false", ok == false and DIGS == 0, tostring(why))
clearWorld(); home(); DIGS = 0
set(0, 0, 1, block("minecraft:stone"))
T.diggable = { "minecraft:st*" }
ok = T.forward()
check("T.diggable as a list of globs: T.forward digs what it names", ok and DIGS == 1 and at() == "(0,0,1)", at())
T.diggable = {}

-- up and down, and the cell is the one in that direction
clearWorld(); home(); DIGS = 0
set(0, 1, 0, block("minecraft:dirt")); set(0, -1, 5, block("minecraft:gravel"))
ok, why = T.moveTo(0, 3, 0)
check("up: blocked by what is above", not ok and why == "blocked by minecraft:dirt at 0,1,0; opts.path = true routes round it", tostring(why))
ok = T.moveTo(0, 3, 0, { dig = true })
check("...and dug through", ok and at() == "(0,3,0)")
home(0, 0, 5)
ok, why = T.moveTo(0, -2, 5)
check("down: blocked by what is below", not ok and why == "blocked by minecraft:gravel at 0,-1,5; opts.path = true routes round it", tostring(why))

--------------------------------------------------------------------------
-- Protected areas, containers, bedrock
--------------------------------------------------------------------------
clearWorld(); home(); DIGS = 0
set(1, 0, 0, block("minecraft:polished_blackstone_bricks"))
T.protect("castle", 1, 0, 0, 1, 2, 0)
ok, why, name, cell = T.moveTo(3, 0, 0, { order = "x", dig = true })
check("a protected block, dig allowed: false, \"protected: <area>\", and it is not dug",
    ok == false and why == "protected: castle (minecraft:polished_blackstone_bricks at 1,0,0)"
    and name == "minecraft:polished_blackstone_bricks" and cell.x == 1 and get(1, 0, 0) and DIGS == 0, tostring(why))
ok, why = T.moveTo(3, 0, 0, { order = "x" })
check("with dig off it is just blocked", ok == false and why:find("^blocked by"), tostring(why))
ok = T.moveTo(3, 0, 0, { order = "x", dig = true, inside = "castle" })
check("opts.inside names the area the move may dig in", ok and DIGS == 1 and at() == "(3,0,0)" and T.cfg.inside == nil, at())
home()
ok = T.moveTo(3, 0, 0, { order = "x" })
check("an empty protected cell is walked through (only digs are refused)", ok and at() == "(3,0,0)", at())
T.unprotect("castle")

clearWorld(); home(); DIGS = 0
set(1, 0, 0, block("minecraft:chest"))
ok, why, name = T.moveTo(3, 0, 0, { order = "x", dig = true })
check("a chest is not dug, even with dig = true", ok == false and name == "minecraft:chest" and why:find("^couldn't dig minecraft:chest at 1,0,0: won't dig")
    and get(1, 0, 0) and DIGS == 0, tostring(why))
clearWorld(); home()
set(1, 0, 0, block("minecraft:bedrock"))
ok, why = T.moveTo(3, 0, 0, { order = "x", dig = true })
check("a block that can't be dug says what the dig said", ok == false and why == "couldn't dig minecraft:bedrock at 1,0,0: Unbreakable block detected", tostring(why))

--------------------------------------------------------------------------
-- Lava, fire, doors
--------------------------------------------------------------------------
clearWorld(); home()
set(1, 0, 0, fluid("minecraft:lava"))
ok, why, name, cell = T.moveTo(3, 0, 0, { order = "x", dig = true })
check("lava ahead: false, \"avoiding minecraft:lava at <cell>\", and the turtle did not go in",
    ok == false and why == "avoiding minecraft:lava at 1,0,0" and name == "minecraft:lava" and cell.x == 1 and at() == "(0,0,0)", tostring(why))
ok = T.moveTo(3, 0, 0, { order = "x", avoid = {} })
check("avoid = {} avoids nothing: it wades through", ok and at() == "(3,0,0)", at())
home()
ok, why = T.moveTo(3, 0, 0, { order = "x", avoid = "minecraft:lava" })
check("avoid can be one glob", not ok and why == "avoiding minecraft:lava at 1,0,0")
clearWorld(); home()
set(0, 0, 1, fluid("minecraft:water"))
ok = T.moveTo(0, 0, 2)
check("water is no reason to stop", ok and at() == "(0,0,2)", at())
clearWorld(); home(0, 2, 0)
set(0, 1, 0, fluid("minecraft:lava"))
ok, why = T.moveTo(0, 0, 0)
check("lava below: avoided going down too", not ok and why == "avoiding minecraft:lava at 0,1,0" and at() == "(0,2,0)", tostring(why))
clearWorld(); home()
set(1, 0, 0, block("minecraft:fire"))
ok, why = T.moveTo(3, 0, 0, { order = "x" })
check("fire is avoided", not ok and why == "avoiding minecraft:fire at 1,0,0", tostring(why))
clearWorld(); home()
set(1, 0, 0, block("minecraft:oak_door"))
ok, why = T.moveTo(3, 0, 0, { order = "x", dig = true })
check("a door is avoided, and not dug", not ok and why == "avoiding minecraft:oak_door at 1,0,0" and get(1, 0, 0), tostring(why))
-- the player's furnishings: a run that may dig goes no further than one, rather than dig it (ADR-0012)
local FURNISHINGS = { "minecraft:ladder", "minecraft:oak_trapdoor", "minecraft:iron_trapdoor", "minecraft:oak_fence_gate",
    "minecraft:oak_sign", "minecraft:oak_wall_sign", "minecraft:oak_hanging_sign", "minecraft:oak_wall_hanging_sign",
    "minecraft:lantern", "minecraft:soul_lantern", "minecraft:torch", "minecraft:wall_torch", "minecraft:soul_torch",
    "minecraft:soul_wall_torch", "minecraft:redstone_torch", "minecraft:redstone_wall_torch", "minecraft:rail",
    "minecraft:powered_rail", "minecraft:detector_rail", "minecraft:activator_rail" }
local dug = {}
for _, f in ipairs(FURNISHINGS) do
    clearWorld(); home()
    set(1, 0, 0, block(f))
    ok, why = T.moveTo(3, 0, 0, { order = "x", dig = true })
    if ok or why ~= "avoiding " .. f .. " at 1,0,0" or not get(1, 0, 0) then dug[#dug + 1] = f .. ": " .. tostring(why) end
end
check("ladders, trapdoors, fence gates, signs (on a wall, hanging), lanterns, torches (wall, soul, redstone) and rails: avoided with dig = true, not dug",
    #dug == 0, table.concat(dug, "; "))
clearWorld(); home()
set(1, 0, 0, block("minecraft:sea_lantern")); set(2, 0, 0, block("minecraft:jack_o_lantern"))
ok, why = T.moveTo(3, 0, 0, { order = "x", dig = true })
check("...but a sea lantern and a jack o'lantern are blocks like any other: dug", ok and not get(1, 0, 0) and not get(2, 0, 0), tostring(why))
clearWorld(); home()
set(1, 0, 0, block("minecraft:ladder"))
ok, why = T.moveTo(3, 0, 0, { order = "x", dig = true, avoid = {} })
check("...and avoid = {} digs a ladder too", ok and not get(1, 0, 0), tostring(why))

--------------------------------------------------------------------------
-- Something in the way, fuel
--------------------------------------------------------------------------
clearWorld(); home()
set(1, 0, 0, ENTITY)
ok, why, name = T.moveTo(3, 0, 0, { order = "x" })
check("a mob in the way that can't be pushed past: false and why, no block named",
    ok == false and why == "can't move into 1,0,0: something is in the way" and name == nil, tostring(why))

clearWorld(); home()
FUEL = 0
ok, why, name = T.moveTo(3, 0, 0, { order = "x" })
check("an empty tank: false, \"out of fuel\"", ok == false and why == "out of fuel at (0,0,0)" and name == nil, tostring(why))
FUEL = 30
S.inv = { { name = "minecraft:coal", count = 2 } }
ok = T.moveTo(3, 0, 0, { order = "x" })
check("a tank below T.cfg.lowFuel is topped up from the inventory first", ok and at() == "(3,0,0)" and FUEL > 100 and S.inv[1] == nil, "fuel " .. tostring(FUEL))
FUEL, S.inv = nil, {}

--------------------------------------------------------------------------
-- The one-block moves say why they refused
--------------------------------------------------------------------------
clearWorld(); home(0, 16, 0)
ok, why = T.up()
check("T.up at T.cfg.maxHeight: false, and the limit named", ok == false and why == "maxHeight 16 reached (T.cfg.maxHeight)" and at() == "(0,16,0)", tostring(why))
home(0, -12, 0)
ok, why = T.down()
check("T.down at T.cfg.maxDrop: false, and the limit named", ok == false and why == "maxDrop 12 reached (T.cfg.maxDrop)", tostring(why))
clearWorld(); home()
set(0, 1, 0, block("minecraft:dirt")); set(0, 0, 1, block("minecraft:stone"))
ok, why = T.up()
check("T.up under a block it may not dig: \"blocked by <block> at <cell>\"", ok == false and why == "blocked by minecraft:dirt at 0,1,0", tostring(why))
ok, why = T.forward()
check("T.forward the same", ok == false and why == "blocked by minecraft:stone at 0,0,1" and at() == "(0,0,0)", tostring(why))
set(0, 0, -1, block("minecraft:stone"))
ok, why = T.back()
check("T.back can't see behind it: false, \"can't move back: something is in the way\"", ok == false and why == "can't move back: something is in the way", tostring(why))
clearWorld(); home()
set(0, 0, 1, ENTITY)
ok, why = T.forward()
check("a mob in the way: \"can't move forward: something is in the way\"", ok == false and why == "can't move forward: something is in the way", tostring(why))
clearWorld(); home()
set(0, 0, 1, block("minecraft:stone"))
T.diggable["minecraft:stone"] = true
T.protect("castle", 0, 0, 1, 0, 0, 1)
ok, why = T.forward()
check("a block T.diggable lists in a protected area: the dig's reason", ok == false and why == "couldn't dig minecraft:stone at 0,0,1: protected: castle" and get(0, 0, 1), tostring(why))
T.unprotect("castle")
ok, why = T.forward()
check("...and outside one it is dug and the move made: true alone", ok == true and why == nil and at() == "(0,0,1)", tostring(why))
T.diggable = {}

--------------------------------------------------------------------------
-- A route finder
--------------------------------------------------------------------------
clearWorld(); home()
set(1, 0, 0, block("minecraft:stone"))
local asked
local function finder(x, y, z, opts)
    asked = { x, y, z, opts }
    return T.moveTo(x, y, z, { order = "zxy", dig = true })
end
local o = { order = "x", path = finder }
ok = T.moveTo(3, 0, 2, o)
check("a blocked straight run asks opts.path (a function) for a route to the same cell, with the same opts",
    ok == true and at() == "(3,0,2)" and asked and asked[1] == 3 and asked[3] == 2 and asked[4] == o, at())
clearWorld(); home()
set(1, 0, 0, block("minecraft:stone"))
ok, why, name = T.moveTo(3, 0, 0, { order = "x", path = function() return false, "no way round" end })
check("a finder that finds nothing: the block's reason, and its", ok == false and why == "blocked by minecraft:stone at 1,0,0 (no route: no way round)"
    and name == "minecraft:stone", tostring(why))
asked = nil
home(); clearWorld()
ok = T.moveTo(2, 0, 0, { path = finder })
check("a clear way never asks", ok and asked == nil)
FUEL = 0
set(1, 0, 0, nil)
ok = T.moveTo(3, 0, 0, { order = "x", path = finder })
check("nor does running out of fuel", ok == false and asked == nil)
FUEL = nil

-- the path module, loaded when first needed
clearWorld(); home()
T.registry.travel = "tl.route"
ROUTE_LOADS = nil
set(1, 0, 0, block("minecraft:stone"))
ok = T.moveTo(1, 0, 1, { order = "xz", path = true })
check("opts.path = true uses the path module's T.travel, loading it then", ok == true and ROUTE_LOADS == 1, tostring(ROUTE_LOADS))
check("...which took the route", at() == "(1,0,1)" and ROUTE_LOADS == 1, at() .. ", loaded " .. tostring(ROUTE_LOADS))
package.loaded.turtlelib = nil
T = require("turtlelib")
home(); clearWorld()
T.registry.travel = "tl.route"
ROUTE_LOADS = nil
ok = T.moveTo(2, 2, 2, { path = true })
check("a clear way with opts.path = true loads nothing", ok and ROUTE_LOADS == nil)
package.loaded.turtlelib = nil
T = require("turtlelib")
home(); clearWorld()
T.registry.travel, T.registry.path = nil, nil            -- (a turtlelib whose registry has no path module)
set(1, 0, 0, block("minecraft:stone"))
ok, why = T.moveTo(3, 0, 0, { order = "x", path = true })
check("opts.path = true with no path module: just the block's reason", ok == false and why == "blocked by minecraft:stone at 1,0,0", tostring(why))

--------------------------------------------------------------------------
-- Liquids beside a cell to dig (ADR-0011 D1), known from what the turtle looked at (no map here)
--------------------------------------------------------------------------
-- (a fresh turtlelib: what the turtle saw lately starts empty)
local function freshT()
    package.loaded.turtlelib = nil
    T = require("turtlelib")
    clearWorld(); home(); DIGS = 0
end
-- The turtle looks at the cell x, y, z from the cell before it on the x axis, facing +x, and comes home.
local function lookAtX(x, y, z)
    home(x - 1, y, z, 1)
    T.look(1)
    home()
end
freshT()
set(1, 0, 0, block("minecraft:stone")); set(1, 0, 1, fluid("minecraft:lava"))       -- a moat beside the channel
lookAtX(1, 0, 1)
ok, why, name, cell = T.moveTo(3, 0, 0, { order = "x", dig = true })
check("a cell to dig with lava beside it (the turtle saw it): refused, nothing dug, the lava named",
    ok == false and why == "digging minecraft:stone at 1,0,0 would release lava at 1,0,1 (opts.liquid = true digs it anyway)"
    and name == "minecraft:stone" and cell and cell.x == 1 and DIGS == 0 and get(1, 0, 0) and at() == "(0,0,0)", tostring(why))
ok, why = T.moveTo(3, 0, 0, { order = "x", dig = true, liquid = true })
check("...opts.liquid = true digs it anyway", ok == true and DIGS == 1 and at() == "(3,0,0)", tostring(why))
check("T.liquidNear names the lava and its cell", select("#", T.liquidNear(1, 0, 0)) == 4 and T.liquidNear(1, 0, 0) == "minecraft:lava"
    and select(4, T.liquidNear(1, 0, 0)) == 1 and T.liquidNear(5, 0, 5) == nil)

freshT()
set(1, 0, 0, block("minecraft:stone")); set(1, -1, 0, fluid("minecraft:lava"))
home(0, -1, 0, 1); T.look(1); home()
ok, why = T.moveTo(3, 0, 0, { order = "x", dig = true })
check("lava below the cell doesn't flow up into it: dug", ok == true and DIGS == 1, tostring(why))

freshT()
set(1, 0, 0, block("minecraft:stone")); set(1, 1, 0, fluid("minecraft:water", { level = 0 }))
lookAtX(1, 1, 0)
ok, why = T.moveTo(3, 0, 0, { order = "x", dig = true })
check("a water source above the cell: refused", ok == false and why == "digging minecraft:stone at 1,0,0 would release water at 1,1,0 (opts.liquid = true digs it anyway)"
    and DIGS == 0, tostring(why))
freshT()
set(1, 0, 0, block("minecraft:stone")); set(1, 0, 1, fluid("minecraft:water", { level = 3 }))
lookAtX(1, 0, 1)
ok, why = T.moveTo(3, 0, 0, { order = "x", dig = true })
check("flowing water beside it (a level above 0): dug", ok == true and DIGS == 1, tostring(why))
freshT()
set(1, 0, 0, block("minecraft:stone")); set(1, 0, 1, block("minecraft:oak_stairs", { waterlogged = true }))
lookAtX(1, 0, 1)
ok, why = T.moveTo(3, 0, 0, { order = "x", dig = true })
check("a waterlogged block beside it is water too", ok == false and why and why:find("would release water at 1,0,1", 1, true) and DIGS == 0, tostring(why))

freshT()
set(1, 0, 0, block("minecraft:stone")); set(1, 0, 1, fluid("minecraft:lava"))
lookAtX(1, 0, 1)
set(1, 0, 1, block("minecraft:netherrack"))
lookAtX(1, 0, 1)
ok, why = T.moveTo(3, 0, 0, { order = "x", dig = true })
check("a second look that finds the lava gone lifts the refusal", ok == true and DIGS == 1, tostring(why))
freshT()
set(1, 0, 0, block("minecraft:stone")); set(1, 0, 1, fluid("minecraft:lava"))
home(0, 0, 1, 1); T.look(1)
T.placeDir(1)
home()
ok, why = T.moveTo(3, 0, 0, { order = "x", dig = true })
check("...so does a block placed into it", ok == true and DIGS == 1 and get(1, 0, 1).name == "minecraft:cobblestone", tostring(why))
freshT()
set(1, 0, 0, block("minecraft:stone")); set(1, 0, 1, fluid("minecraft:lava"))
ok, why = T.moveTo(3, 0, 0, { order = "x", dig = true })
check("(lava the turtle never saw, with no map, isn't known: dug)", ok == true and DIGS == 1, tostring(why))

-- falling blocks: a warning, not a refusal
freshT()
set(1, 0, 0, block("minecraft:stone")); set(1, 1, 0, block("minecraft:gravel"))
lookAtX(1, 1, 0)
ok, why = T.moveTo(3, 0, 0, { order = "x", dig = true })
check("a dig under gravel: true, and a warning that it may fall", ok == true and DIGS == 1 and at() == "(3,0,0)"
    and why == "warning: dug 1,0,0 under minecraft:gravel, which may fall into it", tostring(why))
check("T.isFalling: sand, gravel, concrete powder; not stone", T.isFalling("minecraft:sand") and T.isFalling("minecraft:red_concrete_powder")
    and not T.isFalling("minecraft:stone"))

--------------------------------------------------------------------------
-- opts.digOnly: the only cells it may dig (ADR-0011 D7.1)
--------------------------------------------------------------------------
freshT()
set(1, 0, 0, block("minecraft:stone")); set(2, 0, 0, block("minecraft:stone"))
ok, why, name, cell = T.moveTo(3, 0, 0, { order = "x", digOnly = { "1,0,0" } })
check("opts.digOnly: the cell it lists is dug (any block, with no opts.dig), the next one stops it and says why",
    ok == false and why == "blocked by minecraft:stone at 2,0,0 (not a cell opts.digOnly lists); opts.path = true routes round it" and DIGS == 1 and get(1, 0, 0) == nil
    and get(2, 0, 0) and at() == "(1,0,0)" and cell.x == 2, tostring(why))
ok = T.moveTo(3, 0, 0, { order = "x", digOnly = { { x = 2, y = 0, z = 0 } } })
check("...cells as { x, y, z } will do", ok == true and DIGS == 2 and at() == "(3,0,0)")
freshT()
set(1, 0, 0, block("minecraft:stone")); set(2, 0, 0, block("minecraft:dirt"))
ok, why = T.moveTo(3, 0, 0, { order = "x", digOnly = { ["1,0,0"] = true, ["2,0,0"] = true }, dig = "*stone" })
check("...a set of keys, and opts.dig still says which blocks", ok == false and why == "blocked by minecraft:dirt at 2,0,0; opts.path = true routes round it" and DIGS == 1, tostring(why))
ok, why = T.moveTo(3, 0, 0, { order = "x", digOnly = { "2,0" } })
check("...a cell that isn't one: false and why", ok == false and why:find("opts.digOnly: a cell is", 1, true), tostring(why))
check("T.cellSet: a list, a set and one cell", T.cellSet({ "1,2,3", { 4, 5, 6 } })["4,5,6"] and T.cellSet({ ["1,2,3"] = true })["1,2,3"]
    and T.cellSet({ x = 1, y = 2, z = 3 })["1,2,3"] and T.cellSet("1,2,3") == nil)
