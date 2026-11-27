-- sim/turtlelib_placecount.lua
--
-- The wrapped turtle.place, placeUp and placeDown (and T.placeDir through
-- them) go by the item count: a place the game says failed that used the
-- item did place it (CC: Tweaked 1.120 on NeoForge says so of an AE2 facade,
-- and may use a second one: ccnix#392), so it returns true, with what the
-- game said and how many it used.  A place that really failed (nothing
-- used) and one the game says worked are as the game says, so it's right
-- with ccnix-mod's fix or without.
local PROJ = ...
package.path = PROJ .. "/turtle/?.lua;" .. PROJ .. "/lib/?.lua;" .. PROJ .. "/sim/lib/?.lua;" .. package.path
local M = require("mock")
local check = M.check

local S = { files = {} }
fs = M.fsApi(S)
textutils = M.textutilsApi()

-- A turtle whose place does what the next entry of PLACES says: { ok, why, used }.
local COUNT, PLACES = { 10 }, {}
local function placing()
    local p = table.remove(PLACES, 1) or { false, "Cannot place item here", 0 }
    COUNT[1] = COUNT[1] - p[3]
    if p[1] then return true end
    return false, p[2]
end
turtle = {
    getSelectedSlot = function() return 1 end,
    getItemCount = function(s) return COUNT[s or 1] or 0 end,
    getItemDetail = function() return COUNT[1] > 0 and { name = "ae2:facade", count = COUNT[1] } or nil end,
    place = placing, placeUp = placing, placeDown = placing,
    inspect = function() return false end, inspectUp = function() return false end,
    inspectDown = function() return false end,
    turnLeft = function() return true end, turnRight = function() return true end,
}
local T = require("turtlelib")

-- the game says it failed, and it used one: placed
PLACES = { { false, "Cannot place item here", 1 } }
local ok, why = turtle.place()
check("a 'failed' place that used the item: true", ok == true and COUNT[1] == 9, tostring(ok) .. " " .. tostring(why))
check("...saying what the game said and how many it used",
    why == "placed, though the game said \"Cannot place item here\" (it used 1)", tostring(why))

-- it used two (the second on a block nearby): placed, and says 2
PLACES = { { false, "Cannot place item here", 2 } }
ok, why = T.placeDir("up")
check("through T.placeDir, up, using two: true, and says 2", ok == true and why and why:find("(it used 2)", 1, true) ~= nil,
    tostring(ok) .. " " .. tostring(why))

-- a real failure: nothing used, as the game says
PLACES = { { false, "Cannot place block here", 0 } }
ok, why = turtle.placeDown()
check("a place that used nothing: false, and the game's why", ok == false and why == "Cannot place block here",
    tostring(ok) .. " " .. tostring(why))

-- the game says it worked (with ccnix-mod's fix): as it says
PLACES = { { true, nil, 1 } }
ok, why = turtle.place()
check("a place the game says worked: true, nothing added", ok == true and why == nil, tostring(ok) .. " " .. tostring(why))

-- an empty slot: as the game says
COUNT[1] = 0
PLACES = { { false, "No items to place", 0 } }
ok, why = turtle.place()
check("nothing selected: false, the game's why", ok == false and why == "No items to place", tostring(ok) .. " " .. tostring(why))
