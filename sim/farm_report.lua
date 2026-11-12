-- sim/farm_report.lua
--
-- farm.report: with a player to tell (turtle.player) and a chat box in the
-- chest below home, farm tells the player when a single pass is done (the
-- chat box taken out for it and put back), after a pass with trouble even
-- when it repeats, and when it stops on an error; a clean pass that repeats
-- says nothing; off, or with no player, no one is told.
local PROJ = ...
package.path = PROJ .. "/turtle/?.lua;" .. PROJ .. "/lib/?.lua;" .. PROJ .. "/sim/lib/?.lua;" .. package.path
local M = require("mock")
local F = require("farmworld")
local check = F.check
local run = F.runner(PROJ, { stopped = function(err)
    if err == "Terminated" then return "(stopped as if by Ctrl+T)" end
    if err == "boom" then return "(stopped by an error, as the simulator was told to)" end
end })
-- Time passes with sleep; past STOP_AT the simulator ends the run as Ctrl+T does, or with an error (STOP_WITH).
STOP_WITH = "Terminated"
sleep = function(t)
    t = t or 0
    CLOCK = CLOCK + t
    HOPPER = math.max(0, HOPPER - 2.5 * t)
    if STOP_AT and CLOCK > STOP_AT then error(STOP_WITH, 0) end
end
local CHAT = "advancedperipherals:chat_box"

-- A chat box only speaks while it is aboard (which stands in for its being equipped).
local told = {}
package.loaded.mc = { new = function()
    local aboard = M.carried(F, CHAT) > 0
    return { has = { chat = aboard and "chat box" or nil }, flush = function() return true end,
             tell = function(who, message)
                 told[#told + 1] = who .. ": " .. message .. (aboard and " {chat box aboard}" or "")
                 return true
             end }
end }
local function withSettings(chosen, fn)
    local defaults = {}
    settings = { define = function(name, o) defaults[name] = o.default end,
                 get = function(name) if chosen[name] ~= nil then return chosen[name] end return defaults[name] end,
                 set = function() end, save = function() end }
    fn()
    settings = nil
end
local function newComputer()
    for name in pairs(F.files) do F.files[name] = nil end
    F.dirs = {}
    turtle._ccnixWorld = nil
    if turtle._ccnixWrap then turtle._ccnixWrap.listeners = {} end
    F.P.x, F.P.y, F.P.z, F.P.d = 0, 0, 0, 0
    told = {}
end
local function farm()
    newComputer()
    F.build({ width = 5, length = 6, lanes = { 3 } })
    F.stock()
    F.chest[#F.chest + 1] = { name = CHAT, count = 1 }
end
local function boxInChest()
    local n = 0
    for s = 1, F.CHEST_SIZE do if F.chest[s] and F.chest[s].name == CHAT then n = n + F.chest[s].count end end
    return n
end
local WITH = { ["farm.report"] = true, ["turtle.player"] = "Tester" }

-- 1. a single pass: told once that it is done, with the fuel; the chat box
--    was aboard for the telling and is back in the chest
farm()
withSettings(WITH, function() run("5", "6", "0") end)
check("a single pass: the player is told once, that it is done, with the fuel",
    #told == 1 and told[1]:find("^Tester: farm: pass complete %[") and told[1]:find("fuel ", 1, true), table.concat(told, " | "))
check("...the chat box was aboard for it and is back in the chest", told[1] and told[1]:find("{chat box aboard}", 1, true)
    and boxInChest() == 1 and M.carried(F, CHAT) == 0)

-- 2. repeating: a clean first pass says nothing; one with trouble (both ways
--    out of home blocked, so the farm is unreachable) is told
farm()
withSettings({}, function() run("5", "6", "0") end)
told = {}
F.ripen()
STOP_AT = 100
withSettings(WITH, function() run("1") end)
STOP_AT = nil
check("a clean pass that repeats says nothing", #told == 0, table.concat(told, " | "))
F.set(0, 0, 1, { name = "minecraft:cobblestone" }); F.set(1, 0, 0, { name = "minecraft:cobblestone" })
F.ripen()
STOP_AT = 100
withSettings(WITH, function() run("1") end)
STOP_AT = nil
check("a pass with trouble is told even though it repeats", #told >= 1 and told[1]:find("farm: pass complete; 24 unreachable", 1, true), table.concat(told, " | "))

-- 3. a pass that finds damage (a hole in the land with no floor): told what
farm()
withSettings({}, function() run("5", "6", "0") end)
told = {}
F.ripen()
F.set(2, -1, 3, nil); F.set(2, -2, 3, nil); F.set(2, -3, 3, nil)
withSettings(WITH, function() run("0") end)
check("damage is trouble, and said", #told == 1 and told[1]:find("farm: pass complete; 1 tiles damaged", 1, true), table.concat(told, " | "))

-- 4. `farm repair` says it is done
farm()
withSettings({}, function() run("5", "6", "0") end)
told = {}
withSettings(WITH, function() run("repair") end)
check("farm repair: told that it is done", #told == 1 and told[1]:find("^Tester: farm repair: done"), table.concat(told, " | "))

-- 5. stopped by an error in the wait between passes: told what stopped it,
--    and the error goes on (a Ctrl+T is not told: it cannot speak then)
farm()
withSettings({}, function() run("5", "6", "0") end)
told = {}
F.ripen()
STOP_AT, STOP_WITH = 100, "boom"
local ran, err
withSettings(WITH, function() ran, err = run("1") end)
STOP_AT, STOP_WITH = nil, "Terminated"
check("an error stops it: the player is told what stopped it", #told == 1 and told[1]:find("farm stopped: ", 1, true) and told[1]:find("boom", 1, true), table.concat(told, " | "))
check("...and the error goes on", ran == false and tostring(err):find("boom", 1, true) ~= nil, tostring(err))

-- 6. off, and on with no player: no one is told, and farm says why
farm()
withSettings({ ["turtle.player"] = "Tester" }, function() run("5", "6", "0") end)
check("farm.report off (the default): no one is told", #told == 0, table.concat(told, " | "))
farm()
withSettings({ ["farm.report"] = true }, function() run("5", "6", "0") end)
check("on, but no player set: no one is told, and farm says why", #told == 0 and F.logHas("Couldn't tell the player %(no player to tell"), table.concat(told, " | "))
package.loaded.mc = nil
