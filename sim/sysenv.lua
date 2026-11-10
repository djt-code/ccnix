-- sim/sysenv.lua
--
-- lib/sysenv: the environment functions ccsh and init's kernel give a
-- command (and putting them in os and back), the host name and the name
-- shown to a person, finding a ccnix program (ccnix's own, else the
-- checkout beside the running one), and a number setting.  Over a fake
-- os, shell, fs, settings and ccnix.
local PROJ = ...
package.path = PROJ .. "/lib/?.lua;" .. PROJ .. "/sim/lib/?.lua;" .. package.path
local M = require("mock")
local check = M.check
local tables = require("tables")
local sysenv = require("sysenv")

local function show(v)
    if type(v) == "string" then return string.format("%q", v) end
    return tostring(v)
end
local function same(label, got, want)
    check(label, got == want, "got " .. show(got) .. ", want " .. show(want))
end

-- 1. the environment
local env = { HOME = "/", X = "1" }
local api = sysenv.envApi(env)
same("getenv", api.getenv("X"), "1")
same("getenv: unset", api.getenv("nope"), nil)
check("getenv: a name that isn't a string is an error", not pcall(api.getenv, 5))
api.setenv("Y", 3)
same("setenv: the value as a string", env.Y, "3")
api.setenv("Y", nil)
same("setenv nil unsets", env.Y, nil)
check("setenv: an empty name, or one with =, is an error", not pcall(api.setenv, "", "v") and not pcall(api.setenv, "A=B", "v"))
local all = api.environ()
check("environ: a copy of all of it", all ~= env and all.HOME == "/" and all.X == "1" and #tables.sortedKeys(all) == 2)

local fakeOs = { getenv = "the old getenv" }
local saved = sysenv.swapEnv(api, fakeOs)
check("swapEnv: the three in os while it runs", fakeOs.getenv == api.getenv and fakeOs.setenv == api.setenv
    and fakeOs.environ == api.environ)
sysenv.swapEnv(saved, fakeOs)
check("... and the ones before back after", fakeOs.getenv == "the old getenv" and fakeOs.setenv == nil and fakeOs.environ == nil)

-- 2. the computer's names
local function osWith(label, id)
    return { getComputerLabel = function() return label end, getComputerID = function() return id end }
end
same("hostname: the label", sysenv.hostname(osWith("miner", 7)), "miner")
same("hostname: the ID with no label", sysenv.hostname(osWith(nil, 7)), "7")
same("hostname: an empty label is none", sysenv.hostname(osWith("", 7)), "7")
same("hostname: an os without them", sysenv.hostname({}), "0")
same("computerName: the label", sysenv.computerName(osWith("miner", 7)), "miner")
same("computerName: computer <ID> with none", sysenv.computerName(osWith(nil, 12)), "computer 12")
same("computerName: an empty label too", sysenv.computerName(osWith("", 12)), "computer 12")

-- 3. finding a program
local FILES = { ["/home/me/repo/bin/ccsh.lua"] = true, ["/home/me/repo/lib/procrun.lua"] = true }
fs = {
    exists = function(p) return FILES[p] == true end,
    getDir = function(p)
        local i = #p
        while i > 0 and p:sub(i, i) ~= "/" do i = i - 1 end
        return p:sub(1, math.max(0, i - 1))
    end,
}
local fakeShell = { getRunningProgram = function() return "home/me/repo/bin/telnetd.lua" end }
same("repoRoot: above the running program's folder", sysenv.repoRoot(fakeShell), "/home/me/repo")
same("findProgram: the checkout's, without .lua", sysenv.findProgram("bin/ccsh", fakeShell), "/home/me/repo/bin/ccsh")
same("findProgram: nil when it isn't there", sysenv.findProgram("pc/router", fakeShell), nil)
same("findProgram: nil with no shell to ask", sysenv.findProgram("bin/ccsh"), nil)
ccnix = { find = function(rel) if rel == "bin/ccsh.lua" then return "rom/ccnix/bin/ccsh.lua" end end }
same("findProgram: ccnix's own first", sysenv.findProgram("bin/ccsh", fakeShell), "rom/ccnix/bin/ccsh")
same("findProgram: the checkout when ccnix hasn't it", sysenv.findProgram("lib/procrun", fakeShell), "/home/me/repo/lib/procrun")
ccnix = nil

-- 4. a number setting
local SETTINGS = {}
settings = { get = function(k) return SETTINGS[k] end }
local function setting(v, default, least)
    SETTINGS.x = v
    return sysenv.setting("x", default, least)
end
same("setting: unset is the default", setting(nil, 23), 23)
same("setting: a number", setting(8080, 23), 8080)
same("setting: a string that is one", setting("2.5", 10), 2.5)
same("setting: a string that isn't", setting("abc", 10), 10)
same("setting: not a number at all", setting(true, 10), 10)
same("setting: below least is the default", setting(-1, 5, 0), 5)
same("setting: least itself is fine", setting(0, 5, 0), 0)
same("setting: no default is nil", setting(nil), nil)
