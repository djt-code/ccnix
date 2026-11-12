-- sim/farm_obstacles.lua
--
-- farm keeps the obstacles it runs into in the map (ADR-0008, `farm.map`):
-- a post standing in the way at travel height is bumped into once
-- (noted in the map, with its name); the next run, which starts with
-- nothing in memory, routes round it from the start and never bumps; with
-- `farm.map` off it bumps again.  A post that has been taken away is
-- found out about (the trip that finds no way drops the memory) and the
-- tile it blocked is farmed.
local PROJ = ...
package.path = PROJ .. "/turtle/?.lua;" .. PROJ .. "/lib/?.lua;" .. PROJ .. "/sim/lib/?.lua;" .. package.path
local M = require("mock")
local F = require("farmworld")
local check = F.check
local run = F.runner(PROJ)

local POST = { name = "minecraft:cobblestone" }
local BUMPS = 0                                  -- times the turtle looked at the post it stood facing
local rawInspect = turtle.inspect
turtle.inspect = function()
    local ok, data = rawInspect()
    if ok and data.name == POST.name then BUMPS = BUMPS + 1 end
    return ok, data
end

-- Settings, as the shell has them: a name chosen here, else the default.
local function withSettings(chosen, fn)
    local defaults = {}
    settings = { define = function(name, o) defaults[name] = o.default end,
                 get = function(name) if chosen[name] ~= nil then return chosen[name] end return defaults[name] end,
                 set = function() end, save = function() end }
    fn()
    settings = nil
end
local function mapHolds(x, y, z)
    local T = package.loaded.turtlelib
    return T and T.map and T.map.get(x, y, z)
end
-- A new start of the computer: the disk and what the map kept in memory are gone, the turtle is home.
local function newComputer()
    for name in pairs(F.files) do F.files[name] = nil end
    F.dirs = {}
    turtle._ccnixWorld = nil
    if turtle._ccnixWrap then turtle._ccnixWrap.listeners = {} end
    F.P.x, F.P.y, F.P.z, F.P.d = 0, 0, 0, 0
end

-- A 5x6 wheat farm with a lane at x=3 and a post at (0,0,1), cruise height, right
-- in front of home: the way to the first tile runs into it
local function farm()
    F.build({ width = 5, length = 6, lanes = { 3 } })
    F.stock()
    F.set(0, 0, 1, POST)
end

-- 1. learn and farm it: the post is bumped into on the way, and noted
newComputer()
farm()
withSettings({}, function() run("5", "6", "0") end)
local first = BUMPS
F.print("   bumps into the post, first run: " .. first)
check("the first run bumps into the post", first > 0, first)
check("...and the map holds it, by name", mapHolds(0, 0, 1) == POST.name, tostring(mapHolds(0, 0, 1)))

-- 2. a later run (a new program, nothing in memory): routes round the post
F.ripen(); F.stock()
BUMPS = 0
withSettings({}, function() run("0") end)
check("the next run does not bump into the known post", BUMPS == 0, BUMPS)
check("...and every ripe crop was still harvested", select(2, F.cropCount()) == 0 and F.logHas("unreachable 0"))

-- 3. the same run with the map switched off bumps again
F.ripen(); F.stock()
BUMPS = 0
withSettings({ ["farm.map"] = false }, function() run("0") end)
check("with farm.map off it bumps into the post again", BUMPS > 0, BUMPS)

-- 4. nothing was kept before: a farm with no post and no map keeps no map
F.build({ width = 5, length = 6, lanes = { 3 } })
F.stock()
newComputer()
BUMPS = 0
withSettings({}, function() run("5", "6", "0") end)
local mapFiles = 0
for name in pairs(F.files) do if name:find("^%.map") then mapFiles = mapFiles + 1 end end
check("a clean farm leaves no map behind", BUMPS == 0 and mapFiles == 0, mapFiles)

-- 5. both ways out of home blocked by posts, then taken away: the first
--    run finds the farm unreachable and notes both posts; the next run
--    finds no way with them remembered, drops the memory for the trip,
--    and farms (the cell it walks through is air in the map again)
F.build({ width = 5, length = 6, lanes = { 3 } })
F.stock()
newComputer()
withSettings({}, function() run("5", "6", "0") end)
F.set(0, 0, 1, POST); F.set(1, 0, 0, POST)
F.ripen(); F.stock()
withSettings({}, function() run("0") end)
check("with both ways out blocked nothing is reached", F.logHas("unreachable 2[0-9]") or F.logHas("unreachable 24"))
check("...and both posts are noted in the map", mapHolds(0, 0, 1) == POST.name and mapHolds(1, 0, 0) == POST.name,
    tostring(mapHolds(0, 0, 1)) .. " " .. tostring(mapHolds(1, 0, 0)))
F.set(0, 0, 1, nil); F.set(1, 0, 0, nil)
F.ripen(); F.stock()
withSettings({}, function() run("0") end)
check("the posts taken away, the farm is farmed all the same (the memory is dropped)", F.logHas("Harvested 24,") and F.logHas("unreachable 0"))
check("...and the map no longer holds the post it walked through", mapHolds(0, 0, 1) ~= POST.name or mapHolds(1, 0, 0) ~= POST.name,
    tostring(mapHolds(0, 0, 1)) .. " " .. tostring(mapHolds(1, 0, 0)))
