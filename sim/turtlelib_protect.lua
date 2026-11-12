-- sim/turtlelib_protect.lua
--
-- The turtle API wrapped once (ADR-0008, D11), protected areas and the
-- change hooks, on a small world of stone:
--   * turtle.forward() and the rest, called straight, keep T.pos and the
--     saved position right; T.forward counts a move once;
--   * the wrap is made once, however many times turtlelib is loaded (each
--     program the shell runs loads its own copy), and the newest load or
--     T.claim() is the copy the wrapped calls keep up to date;
--   * a protected area refuses turtle.dig() called straight and T.digDir
--     alike (and T.forward's own dig), the data file carries it to another
--     copy of the library, and T.inside lets a job work in its own area;
--   * chests and ComputerCraft blocks are refused unless allowed;
--   * T.onChange hears digs, placements and moves.
local PROJ = ...
package.path = PROJ .. "/turtle/?.lua;" .. PROJ .. "/lib/?.lua;" .. PROJ .. "/sim/lib/?.lua;" .. package.path
local M = require("mock")
local check = M.check

local S = M.state()
fs = M.fsApi(S)
textutils = M.textutilsApi()
shell = M.shellApi("x.lua")
sleep = function() end

-- The world: stone in a block from (0,0,1) to (4,2,4), nothing else
local W = {}
local function get(x, y, z) return W[M.key(x, y, z)] or nil end
local function set(x, y, z, b) W[M.key(x, y, z)] = b or false end
for x = 0, 4 do for y = 0, 2 do for z = 1, 4 do set(x, y, z, { name = "minecraft:stone" }) end end end
S.get = get
local LASTSIDE
local DIGS, PLACES = 0, 0                  -- the mock's own count of what really happened

local function inspectAt(x, y, z)
    local b = get(x, y, z)
    if not b then return false, "No block to inspect" end
    return true, { name = b.name, state = { facing = "north" } }
end
turtle = M.merge(
    M.inventoryApi(S), M.fuelApi(S), M.noAttackApi(),
    M.movementApi(S, function(b) return b == nil end),
    M.lookingApi(S, inspectAt, function(b) return b ~= nil end),
    M.actingApi(S, "dig", function(x, y, z, _, side)
        LASTSIDE = side
        if not get(x, y, z) then return false, "Nothing to dig here" end
        DIGS = DIGS + 1
        set(x, y, z, nil)
        return true
    end),
    M.actingApi(S, "place", function(x, y, z)
        local it = S.inv[S.sel]
        if get(x, y, z) or not it then return false, "Cannot place block here" end
        PLACES = PLACES + 1
        set(x, y, z, { name = it.name })
        return true
    end))
local rawDig, rawForward = turtle.dig, turtle.forward
FUEL = nil

local function load()
    package.loaded.turtlelib = nil
    return require("turtlelib")
end
local function at(T) return string.format("(%d,%d,%d) facing %d", T.pos.x, T.pos.y, T.pos.z, T.dir) end
local function saved() return S.files[".turtlepos"] end

--------------------------------------------------------------------------
-- The wrap, once
--------------------------------------------------------------------------
local T = load()
check("loading turtlelib replaces the turtle's digs, placements, moves and turns",
    turtle.dig ~= rawDig and turtle.forward ~= rawForward and T.raw.dig == rawDig and T.raw.forward == rawForward)
local wrapped = { dig = turtle.dig, forward = turtle.forward, place = turtle.place }
local T2 = load()
check("a second load is no new wrap: the same functions, the same originals",
    turtle.dig == wrapped.dig and turtle.forward == wrapped.forward and turtle.place == wrapped.place
    and T2.raw == T.raw and T2.raw.dig == rawDig)

-- straight through the turtle API, with the second copy the owner
S.P.x, S.P.y, S.P.z, S.P.d = 0, 0, 0, 0
S.moves = 0
turtle.turnRight(); turtle.turnLeft(); turtle.turnLeft(); turtle.turnRight()
check("turns made straight count once, and net nothing", T2.dir == 0 and S.turns == 4, at(T2))
turtle.turnRight()
check("turtle.turnRight() turns T.dir and saves it", T2.dir == 1 and saved() == "0 0 0 1 flat", saved())
turtle.turnLeft()
turtle.up(); turtle.up(); turtle.down(); turtle.back()
check("turtle.up, down and back keep T.pos right", T2.pos.x == 0 and T2.pos.y == 1 and T2.pos.z == -1 and S.P.z == -1,
    at(T2))
check("the saved position follows", saved() == "0 1 -1 0 flat", saved())
check("the older copy was left as it was: only the newest load is told", T.pos.y == 0 and T.pos.z == 0, at(T))
T.claim()
turtle.forward()
check("T.claim() makes a copy the owner again", T.pos.z == 1 and T2.pos.z == -1, at(T) .. " / " .. at(T2))
T.pos.x, T.pos.y, T.pos.z, T.dir = S.P.x, S.P.y, S.P.z, S.P.d

-- T's own moves go through the raw calls: once, and with their extras
S.P.x, S.P.y, S.P.z, S.P.d = 0, 0, 0, 2
T.pos.x, T.pos.y, T.pos.z, T.dir = 0, 0, 0, 2
S.moves = 0
local ok = T.forward()
check("T.forward on a clear way: one move, T.pos right", ok and S.moves == 1 and T.pos.z == -1 and S.P.z == -1, at(T))
T.pos.x, T.pos.y, T.pos.z, T.dir = 0, 0, 0, 0
S.moves, S.P.x, S.P.y, S.P.z, S.P.d = 0, 0, 0, 0, 0
T.diggable["minecraft:stone"] = true
ok = T.forward()
check("T.forward digs T.diggable and moves, counted once", ok and S.moves == 1 and DIGS == 1 and T.pos.z == 1 and S.P.z == 1,
    at(T) .. ", digs " .. DIGS)
ok = T.up(); ok = T.up() and ok
check("T.up digs through the same way and counts once", ok and T.pos.y == 2 and S.P.y == 2 and DIGS == 3, at(T))
T.diggable = {}
T.back(); T.down(); T.down()

--------------------------------------------------------------------------
-- Protected areas
--------------------------------------------------------------------------
S.P.x, S.P.y, S.P.z, S.P.d = 0, 0, 0, 0
T.pos.x, T.pos.y, T.pos.z, T.dir = 0, 0, 0, 0
set(0, 0, 1, { name = "minecraft:stone" })
DIGS = 0
check("nothing is protected to begin with", T.protected(0, 0, 1) == nil and #T.protections() == 0)
check("T.protect takes a name and two corners", T.protect("castle", 2, 2, 3, 0, 0, 1) == true)
check("T.protected names the area a cell is in, and nil outside it",
    T.protected(1, 1, 2) == "castle" and T.protected(0, 0, 1) == "castle" and T.protected(2, 2, 3) == "castle"
    and T.protected(3, 0, 1) == nil and T.protected(0, 0, 0) == nil)
local list = T.protections()
check("T.protections lists the box, low corner first", #list == 1 and list[1].name == "castle"
    and list[1].x1 == 0 and list[1].y1 == 0 and list[1].z1 == 1 and list[1].x2 == 2 and list[1].y2 == 2 and list[1].z2 == 3)
check("it is kept in a data file", S.files[".protected"] == "0 0 1 2 2 3 castle\n", (tostring(S.files[".protected"]):gsub("\n", "|")))

local a, b = turtle.dig()
check("turtle.dig() called straight into a protected cell: false and why",
    a == false and b == "protected: castle" and get(0, 0, 1) and DIGS == 0, tostring(a) .. ", " .. tostring(b))
a, b = T.digDir(0)
check("T.digDir the same", a == false and b == "protected: castle" and get(0, 0, 1) and DIGS == 0, tostring(a) .. ", " .. tostring(b))
T.diggable["minecraft:stone"] = true
a = T.forward()
check("T.forward does not dig through it either", a == false and get(0, 0, 1) and DIGS == 0 and T.pos.z == 0, at(T))
T.diggable = {}
set(0, 1, 0, { name = "minecraft:stone" })
a, b = turtle.digUp()
check("a cell outside the area digs as ever (up, at (0,1,0))", a == true and get(0, 1, 0) == nil, tostring(a) .. ", " .. tostring(b))
set(0, 1, 0, { name = "minecraft:stone" })
T.protect("garden", 0, 1, 0, 0, 1, 0)
a, b = turtle.digUp()
check("a second area refuses turtle.digUp() too", a == false and b == "protected: garden", tostring(b))
check("the data file holds both", S.files[".protected"] == "0 0 1 2 2 3 castle\n0 1 0 0 1 0 garden\n", (tostring(S.files[".protected"]):gsub("\n", "|")))

-- another copy of the library on the same turtle sees the areas
local T3 = load()
check("another copy of turtlelib reads the same areas from the file",
    T3.protected(1, 1, 2) == "castle" and T3.protected(0, 1, 0) == "garden" and #T3.protections() == 2)
T = T3
a, b = turtle.dig()
check("and the wrapped call it owns refuses the same", a == false and b == "protected: castle")

-- a job inside its own area
local digsBefore = DIGS
a, b = T.inside("castle", function() return turtle.dig() end)
check("T.inside: the job may dig in the area it owns", a == true and get(0, 0, 1) == nil and DIGS == digsBefore + 1, tostring(a) .. ", " .. tostring(b))
check("T.inside puts it back after", T.cfg.inside == nil and T.guarded(1, 1, 2) == "castle")
local okErr, err = pcall(T.inside, "castle", function() error("boom", 0) end)
check("T.inside puts it back after an error, and passes the error on", not okErr and err == "boom" and T.cfg.inside == nil, tostring(err))
check("T.guarded leaves out the job's area only: the others still hold",
    (function() T.cfg.inside = "castle"; local r = T.guarded(0, 1, 0); T.cfg.inside = nil; return r end)() == "garden")
set(0, 0, 1, { name = "minecraft:stone" })

check("T.protect asks for a name and whole corners",
    T.protect("", 0, 0, 0, 1, 1, 1) == nil and T.protect("x", 0, 0, 0, 1, 1) == nil and T.protect("x", 0, 0, 0, 1, 1.5, 1) == nil)
T.protect("castle", 0, 0, 1, 1, 0, 1)
list = T.protections()
check("protecting a name again replaces its box", #list == 2 and list[1].name == "castle" and list[1].x2 == 1 and list[1].y2 == 0)
a, b = T.unprotect("nothing")
check("T.unprotect on an unknown name says so", a == false and b == "no protected area called nothing", tostring(b))
check("T.unprotect removes one", T.unprotect("castle") == true and T.protected(0, 0, 1) == nil and #T.protections() == 1)
a = turtle.dig()
check("and the dig goes through", a == true and get(0, 0, 1) == nil)
check("the last one removed deletes the file", T.unprotect("garden") == true and S.files[".protected"] == nil)

--------------------------------------------------------------------------
-- Chests and computers
--------------------------------------------------------------------------
set(0, 0, 1, { name = "minecraft:chest" })
set(0, 1, 0, { name = "computercraft:turtle_advanced" })
set(0, -1, 0, { name = "minecraft:iron_chest" })
DIGS = 0
a, b = turtle.dig()
check("turtle.dig() at a chest: refused", a == false and b and b:find("won't dig minecraft:chest", 1, true) and get(0, 0, 1) and DIGS == 0,
    tostring(b))
a, b = turtle.digUp()
check("at a ComputerCraft turtle: refused", a == false and b and b:find("computercraft:turtle_advanced", 1, true) and DIGS == 0, tostring(b))
a = turtle.digDown()
check("at any other chest too (the name has \"chest\" in it)", a == false and DIGS == 0)
T.cfg.digContainers = true
a = turtle.dig()
check("T.cfg.digContainers = true lets it", a == true and get(0, 0, 1) == nil and DIGS == 1)
T.cfg.digContainers = nil
check("T.neverDig tells the families apart", T.neverDig("minecraft:barrel") and T.neverDig("minecraft:purple_shulker_box")
    and T.neverDig("minecraft:spawner") and T.neverDig("computercraft:computer_normal") and not T.neverDig("minecraft:stone")
    and not T.neverDig("minecraft:crafting_table"))
set(0, 0, 1, { name = "minecraft:stone" })
set(0, 1, 0, nil); set(0, -1, 0, nil)
a = turtle.dig("right")
check("turtle.dig(side) passes the tool side on", a == true and LASTSIDE == "right", tostring(LASTSIDE))
set(0, 0, 1, { name = "minecraft:stone" })

--------------------------------------------------------------------------
-- Change hooks
--------------------------------------------------------------------------
S.P.x, S.P.y, S.P.z, S.P.d = 0, 0, 0, 0
T.pos.x, T.pos.y, T.pos.z, T.dir = 0, 0, 0, 0
local heard = {}
local off = T.onChange(function(e) heard[#heard + 1] = e end)
local bad = T.onChange(function() error("a listener that breaks") end)
local also = 0
T.onChange(function() also = also + 1 end)
turtle.dig()
turtle.forward()
S.inv[1] = { name = "minecraft:cobblestone", count = 3 }
S.sel = 1
turtle.placeDown()
T.back()
turtle.place()
local placed = PLACES
a = turtle.place()
local e = heard[1]
check("a dig is told: the cell, and what was there as inspect gave it",
    e and e.kind == "dig" and e.x == 0 and e.y == 0 and e.z == 1 and e.was == "minecraft:stone" and e.state and e.state.facing == "north")
e = heard[2]
check("a move is told: where to, and from", e and e.kind == "move" and e.x == 0 and e.y == 0 and e.z == 1
    and e.from.z == 0 and e.from.y == 0)
e = heard[3]
check("a placement is told: the cell and the item",
    e and e.kind == "place" and e.x == 0 and e.y == -1 and e.z == 1 and e.item == "minecraft:cobblestone")
e = heard[4]
check("T's own move is told too, once", e and e.kind == "move" and e.z == 0 and e.from.z == 1 and heard[5].kind == "place")
check("a placement that fails is not told", a == false and PLACES == placed and #heard == 5, #heard .. " events")
T.diggable["minecraft:cobblestone"] = true
T.forward()
T.diggable = {}
check("T.forward's dig and move are told, in that order", #heard == 7 and heard[6].kind == "dig"
    and heard[6].was == "minecraft:cobblestone" and heard[7].kind == "move" and heard[7].z == 1, #heard .. " events")
check("a listener that breaks stops no one, and the turtle goes on", also == 7 and S.P.z == 1 and T.pos.z == 1, also .. " calls")
off()
turtle.up()
check("the remover stops one listener only", #heard == 7 and also == 8, #heard .. " events, " .. also .. " calls")
