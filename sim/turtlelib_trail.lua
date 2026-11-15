-- sim/turtlelib_trail.lua
--
-- The breadcrumb trail (ADR-0011 D7.3): every move the turtle makes, through turtlelib or the turtle API, adds the
-- cell it moved into to a trail of the last 200; T.trail lists it, T.retrace(n) walks back over the last n cells with
-- T.moveTo, skipping loops, and takes them off the trail; a re-zero moves it with the frame; a move it can't make
-- stops it and says why.
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
S.get = get
local function inspectAt(x, y, z)
    local b = get(x, y, z)
    if not b then return false, "No block to inspect" end
    return true, { name = b.name, state = {} }
end
local T
-- A new turtle (its own table, so a trail of its own) and the library loaded afresh, at 0,0,0 facing 0.
local function fresh()
    W = {}
    S.files, S.P.x, S.P.y, S.P.z, S.P.d, S.moves = {}, 0, 0, 0, 0, 0
    turtle = M.merge(
        M.inventoryApi(S), M.fuelApi(S), M.noAttackApi(),
        M.movementApi(S, function(b) return b == nil end),
        M.lookingApi(S, inspectAt, function(b) return b ~= nil end),
        M.actingApi(S, "dig", function(x, y, z)
            if not get(x, y, z) then return false, "Nothing to dig here" end
            set(x, y, z, nil)
            return true
        end))
    package.loaded.turtlelib = nil
    T = require("turtlelib")
    return T
end
local function at() return string.format("(%d,%d,%d)", T.pos.x, T.pos.y, T.pos.z) end
local function keys(list)
    local out = {}
    for _, c in ipairs(list) do out[#out + 1] = c.x .. "," .. c.y .. "," .. c.z end
    return table.concat(out, " ")
end

--------------------------------------------------------------------------
-- The trail
--------------------------------------------------------------------------
fresh()
check("a new turtle's trail is empty", #T.trail() == 0)
T.moveTo(2, 0, 0, { order = "x" })
T.moveTo(2, 1, 1, { order = "yz" })
check("each move adds the cell it moved into, after the one it started from", keys(T.trail()) == "0,0,0 1,0,0 2,0,0 2,1,0 2,1,1", keys(T.trail()))
turtle.forward()
check("a move made straight through the turtle API is on it too", keys(T.trail()) == "0,0,0 1,0,0 2,0,0 2,1,0 2,1,1 2,1,2", keys(T.trail()))
local copy = T.trail()
copy[1].x = 99
check("T.trail gives copies", T.trail()[1].x == 0)
-- another copy of the library adds to the same trail
package.loaded.turtlelib = nil
local T2 = require("turtlelib")
T2.pos.x, T2.pos.y, T2.pos.z, T2.dir = T.pos.x, T.pos.y, T.pos.z, T.dir
T2.up()
check("another copy of turtlelib adds to the same trail", #T.trail() == 7 and T.trail()[7].y == 2, keys(T.trail()))
T = T2

-- 200 at most
fresh()
for _ = 1, 250 do T.forward() end
local list = T.trail()
check("the trail keeps the last 200 cells", #list == 200 and list[200].z == 250 and list[1].z == 51, #list .. " " .. list[1].z)

--------------------------------------------------------------------------
-- Retracing
--------------------------------------------------------------------------
fresh()
T.moveTo(3, 0, 0, { order = "x" })
T.moveTo(3, 0, 2, { order = "z" })
local steps = {}
T.onChange(function(e) if e.kind == "move" then steps[#steps + 1] = e.x .. "," .. e.y .. "," .. e.z end end)
local ok, hops = T.retrace(3)
check("T.retrace(3) walks back over the last 3 cells", ok == true and hops == 3 and at() == "(2,0,0)" and table.concat(steps, " ") == "3,0,1 3,0,0 2,0,0",
    table.concat(steps, " ") .. " " .. at())
check("...and takes them off the trail", keys(T.trail()) == "0,0,0 1,0,0 2,0,0", keys(T.trail()))
ok, hops = T.retrace()
check("T.retrace() goes back to the start of the trail, not forward again", ok == true and hops == 2 and at() == "(0,0,0)", at())
check("...leaving just where it is", keys(T.trail()) == "0,0,0")
ok, hops = T.retrace(5)
check("nothing left to go back over: true, 0", ok == true and hops == 0 and at() == "(0,0,0)")

-- a loop: out along x, round a square and back through a cell it crossed, then on
fresh()
T.moveTo(2, 0, 0, { order = "x" })      -- 1,0,0 2,0,0
T.moveTo(2, 0, 2, { order = "z" })      -- 2,0,1 2,0,2
T.moveTo(1, 0, 2, { order = "x" })      -- 1,0,2
T.moveTo(1, 0, 0, { order = "z" })      -- 1,0,1 1,0,0 (crossed before)
T.moveTo(1, 2, 0, { order = "y" })      -- 1,1,0 1,2,0
steps = {}
T.onChange(function(e) if e.kind == "move" then steps[#steps + 1] = e.x .. "," .. e.y .. "," .. e.z end end)
ok, hops = T.retrace()
check("a loop on the trail is skipped: back down to 1,0,0, then straight to the start", ok == true and table.concat(steps, " ") == "1,1,0 1,0,0 0,0,0" and hops == 3
    and at() == "(0,0,0)", table.concat(steps, " "))

-- a block in the way since
fresh()
T.moveTo(3, 0, 0, { order = "x" })
set(1, 0, 0, { name = "minecraft:stone" })
local why
ok, why, hops = T.retrace()
check("a block on the way back: false, why, and how far it got", ok == false and hops == 1 and at() == "(2,0,0)"
    and why == "retrace stopped short of 1,0,0: blocked by minecraft:stone at 1,0,0", tostring(why))
check("...the trail ends where the turtle is", keys(T.trail()) == "0,0,0 1,0,0 2,0,0", keys(T.trail()))
ok, hops = T.retrace(nil, { dig = true })
check("opts go to T.moveTo: with dig = true it gets through", ok == true and hops == 2 and at() == "(0,0,0)" and get(1, 0, 0) == nil, at())
ok, why = T.retrace(-1)
check("a count of cells from 0", ok == false and why:find("whole number", 1, true), tostring(why))

-- a re-zero moves the trail with the frame
fresh()
T.moveTo(2, 0, 0, { order = "x" })
T.turnRight()                           -- (facing -z now: the new frame is turned half round)
T.clearPos()
T.startAtHome(false)
check("a re-zero (T.clearPos, then a start) moves the trail into the new frame", keys(T.trail()) == "2,0,0 1,0,0 0,0,0", keys(T.trail()))
ok = T.retrace()
check("...and retracing it still goes back the way it came", ok and S.P.x == 0 and S.P.z == 0 and at() == "(2,0,0)", at())
T.moveTo(0, 0, 0)
T.clearPos()
S.files[".turtlepos"] = nil
local T3 = fresh()
check("a new start of the computer starts a new trail", #T3.trail() == 0)
