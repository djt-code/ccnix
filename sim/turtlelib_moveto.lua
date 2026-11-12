-- sim/turtlelib_moveto.lua
--
-- T.moveTo (ADR-0008): a move to a cell in three dimensions, in the order
-- of axes asked for, that says why it stopped: blocked by a block, a
-- protected area, lava (or fire, or a door), a chest, an unbreakable block,
-- something in the way, no fuel; digging only what it may; and asking a
-- route finder for a way when a straight run is blocked.
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
local function block(name) return { name = name } end
local function fluid(name) return { name = name, fluid = true } end
local ENTITY = { entity = true }            -- a mob: nothing to inspect, but it can't be moved into
S.get = get
local DIGS = 0

local function inspectAt(x, y, z)
    local b = get(x, y, z)
    if not b or b.entity then return false, "No block to inspect" end
    return true, { name = b.name, state = {} }
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
check("a block in the way, dig off: false, \"blocked by <block> at <cell>\", the block and the cell",
    ok == false and why == "blocked by minecraft:stone at 1,0,0" and name == "minecraft:stone"
    and cell and cell.x == 1 and cell.y == 0 and cell.z == 0, tostring(why))
check("...the turtle stayed where it got to, the block is there, nothing dug", at() == "(0,0,0)" and get(1, 0, 0) and DIGS == 0)
ok = T.moveTo(3, 0, 0, { order = "x", dig = true })
check("dig = true digs through it", ok and at() == "(3,0,0)" and get(1, 0, 0) == nil and DIGS == 1, at())

clearWorld(); home(); DIGS = 0
set(1, 0, 0, block("minecraft:stone"))
ok, why = T.moveTo(3, 0, 0, { order = "x", dig = "minecraft:*_ore" })
check("dig = a glob that doesn't match: blocked", ok == false and why == "blocked by minecraft:stone at 1,0,0" and DIGS == 0, tostring(why))
ok = T.moveTo(3, 0, 0, { order = "x", dig = { "minecraft:*_ore", "minecraft:st*" } })
check("a list of globs, one matching: dug", ok and DIGS == 1 and at() == "(3,0,0)", at())

-- up and down, and the cell is the one in that direction
clearWorld(); home(); DIGS = 0
set(0, 1, 0, block("minecraft:dirt")); set(0, -1, 5, block("minecraft:gravel"))
ok, why = T.moveTo(0, 3, 0)
check("up: blocked by what is above", not ok and why == "blocked by minecraft:dirt at 0,1,0", tostring(why))
ok = T.moveTo(0, 3, 0, { dig = true })
check("...and dug through", ok and at() == "(0,3,0)")
home(0, 0, 5)
ok, why = T.moveTo(0, -2, 5)
check("down: blocked by what is below", not ok and why == "blocked by minecraft:gravel at 0,-1,5", tostring(why))

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
clearWorld(); home()
set(1, 0, 0, block("minecraft:oak_trapdoor"))
ok, why = T.moveTo(3, 0, 0, { order = "x" })
check("a trapdoor is not a door (just a block)", not ok and why == "blocked by minecraft:oak_trapdoor at 1,0,0", tostring(why))

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
set(1, 0, 0, block("minecraft:stone"))
ok, why = T.moveTo(3, 0, 0, { order = "x", path = true })
check("opts.path = true with no path module: just the block's reason", ok == false and why == "blocked by minecraft:stone at 1,0,0", tostring(why))
