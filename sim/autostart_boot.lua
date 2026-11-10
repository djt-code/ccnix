-- sim/autostart_boot.lua
--
-- turtle/autostart.lua at boot: what it runs for each program the setting
-- ccnix.autostart can name, from the job's files and the saved
-- position: a tunnel dug when it went down is resumed (from the last home,
-- going back there first if need be), a finished or self-stopped one is
-- left alone, no tunnel starts one; a saved farm is farmed (home first),
-- no farm is learned from the settings' size; a mow pass cut short is done
-- again, and a finished one only on repeat.  A key in the 5 seconds
-- cancels; a step that fails stops the rest.
local PROJ = ...
package.path = PROJ .. "/turtle/?.lua;" .. PROJ .. "/lib/?.lua;" .. PROJ .. "/sim/lib/?.lua;" .. package.path
local M = require("mock")
local realPrint = print
local check = M.check

local S = { files = {} }               -- the computer's files, for M.fsApi
local SET, runs, out, EVENTS, failOn
fs = M.fsApi(S)
textutils = M.textutilsApi()               -- (lib/fileio, under turtlelib, reads JSON with it)
settings = { get = function(name, default) if SET[name] == nil then return default end return SET[name] end }
shell = M.shellApi("ccnix/turtle/autostart.lua")
shell.run = function(...)
    local line = table.concat({ ... }, " ")
    runs[#runs + 1] = line
    return line ~= failOn
end
os.startTimer = function() return 7 end
os.pullEvent = function() return table.unpack(table.remove(EVENTS, 1) or { "timer", 7 }) end
printError = function(s) out[#out + 1] = s end

local DIR = "ccnix/turtle/"
local function boot(name, set, have, opts)
    opts = opts or {}
    S.files, SET, runs, out, EVENTS, failOn = {}, set, {}, {}, opts.events or {}, opts.fail
    for k, v in pairs(have) do S.files[DIR .. k] = v end
    print = function(...) out[#out + 1] = table.concat({ ... }, " ") end
    package.loaded.turtlelib = nil
    local ok, err = pcall(assert(loadfile(PROJ .. "/turtle/autostart.lua")), table.unpack(opts.args or {}))
    print = realPrint
    if not ok then out[#out + 1] = "ERROR " .. tostring(err) end
    return table.concat(runs, "; "), table.concat(out, " | ")
end

local AT_START = "0 0 0 0 flat"
local r, o

r = boot("nothing set", {}, {})
check("no autostart set: nothing runs", r == "", r)

r = boot("mine, no tunnel", { ["ccnix.autostart"] = "mine" }, {})
check("mine with no tunnel yet: a new one from the settings", r == "mine", r)
r, o = boot("mine dug, at start", { ["ccnix.autostart"] = "mine" }, { ["mine.job"] = "3 3 0 16 2 active", [".turtlepos"] = AT_START })
check("a tunnel it went down in, at the start: mine --resume", r == "mine --resume", r)
check("it says what it will do and waits", o:find("in 5 s", 1, true) ~= nil, o)
r = boot("mine dug, at home 2", { ["ccnix.autostart"] = "mine" }, { ["mine.job"] = "3 3 0 16 2 active", [".turtlepos"] = "0 0 32 2 flat" })
check("at a home: straight to mine --resume", r == "mine --resume", r)
r = boot("mine dug, mid-tunnel", { ["ccnix.autostart"] = "mine" }, { ["mine.job"] = "3 3 0 16 2 active", [".turtlepos"] = "1 2 37 1 flat" })
check("elsewhere: mine reset, then mine --resume", r == "mine reset; mine --resume", r)
r, o = boot("mine finished", { ["ccnix.autostart"] = "mine" }, { ["mine.job"] = "3 3 32 16 2 done", [".turtlepos"] = AT_START })
check("a finished tunnel: nothing, and it says why", r == "" and o:find("finished", 1, true) ~= nil, o)
r, o = boot("mine stopped", { ["ccnix.autostart"] = "mine" }, { ["mine.job"] = "3 3 0 16 2 stopped", [".turtlepos"] = AT_START })
check("a tunnel that stopped itself (out of chests): left to you", r == "" and o:find("stopped itself", 1, true) ~= nil, o)
r = (function()
    S.files, SET, runs, out, EVENTS, failOn = { ["ccnix/mine.job"] = "3 3 0 16 2 active", ["ccnix/.turtlepos"] = AT_START },
        { ["ccnix.autostart"] = "mine" }, {}, {}, {}, nil
    package.loaded.turtlelib = nil
    print = function() end
    pcall(assert(loadfile(PROJ .. "/turtle/autostart.lua")))
    print = realPrint
    return table.concat(runs, "; ")
end)()
check("a job's files from before turtle/ still count", r == "mine --resume" and S.files[DIR .. "mine.job"] ~= nil, r)

r, o = boot("farm, nothing", { ["ccnix.autostart"] = "farm" }, {})
check("farm with no map and no size: nothing, and how to set one", r == "" and o:find("farm.width", 1, true) ~= nil, o)
r = boot("farm, size set", { ["ccnix.autostart"] = "farm", ["farm.width"] = 9, ["farm.length"] = 9 }, {})
check("no map but a size in the settings: farm (learns it)", r == "farm", r)
r = boot("farm, map, home", { ["ccnix.autostart"] = "farm" }, { ["farm.map"] = "x", [".turtlepos"] = AT_START })
check("a saved farm, at home: farm", r == "farm", r)
r = boot("farm, map, away", { ["ccnix.autostart"] = "farm" }, { ["farm.map"] = "x", [".turtlepos"] = "4 0 7 3 flat" })
check("a saved farm, away from home: farm reset, then farm", r == "farm reset; farm", r)

r = boot("mow, done", { ["ccnix.autostart"] = "mow", ["mow.repeat"] = 0 }, { [".turtlepos"] = AT_START })
check("mow, a pass finished and no repeat: nothing", r == "", r)
r = boot("mow, repeat", { ["ccnix.autostart"] = "mow", ["mow.repeat"] = 30 }, { [".turtlepos"] = AT_START })
check("mow on repeat: mow", r == "mow", r)
r = boot("mow, cut short", { ["ccnix.autostart"] = "mow" }, { [".turtlepos"] = "3 1 5 0 terrain" })
check("mow cut short: mow reset, then mow", r == "mow reset; mow", r)

r = boot("autocompost", { ["ccnix.autostart"] = "autocompost" }, {})
check("autocompost: autocompost", r == "autocompost", r)
r, o = boot("claude", { ["ccnix.autostart"] = "claude" }, {})
check("a program it can't start on its own: refused", r == "" and o:find("can't start", 1, true) ~= nil, o)

r, o = boot("key", { ["ccnix.autostart"] = "farm" }, { ["farm.map"] = "x" }, { events = { { "key", 28 } } })
check("a key in the 5 seconds cancels", r == "" and o:find("cancelled", 1, true) ~= nil, o)
r = boot("now", { ["ccnix.autostart"] = "farm" }, { ["farm.map"] = "x" }, { args = { "--now" }, events = { { "key", 28 } } })
check("--now doesn't wait", r == "farm", r)
r, o = boot("reset fails", { ["ccnix.autostart"] = "farm" }, { ["farm.map"] = "x", [".turtlepos"] = "4 0 7 3 flat" }, { fail = "farm reset" })
check("a step that fails stops the rest", r == "farm reset" and o:find("didn't finish", 1, true) ~= nil, o)
