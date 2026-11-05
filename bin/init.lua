-- init.lua -- processes and services: the first process
--
--   init                    take over this computer: services, then the console
--   init boot [off]         run it at every boot (or not): the setting init.boot
--
-- CraftOS has no processes or background programs (only multishell's
-- tabs, on advanced computers).  init is the nearest thing to Unix's: it
-- runs every program as a process with a process ID, its own terminal
-- and its own environment (see lib/proc.lua), and keeps services running
-- in the background.  `ps` lists the processes, `kill` signals them and
-- `service` starts, stops and sets up services.
--
-- At boot (init.boot on: `deploy/install --init`) startup runs init last.
-- It starts the services that are enabled, then the console: the
-- autostart (ccnix.autostart: the miner, farmer, router...) if one
-- is set, then ccsh if ccsh.login is on, then the CraftOS shell;
-- each when the one before it ends.  Leaving that last shell shuts the
-- computer down, as leaving CraftOS's own does.  Run by hand, init skips
-- the autostart.
--
-- What a service prints is logged too, a line each under its name
-- (printError's at err), and so is each service starting, ending and
-- failing: syslogd, a service of its own, files it (`help syslog`).
-- service.<name>.log false leaves a service's output out.
--
-- The keyboard and mouse go to the console: to the process group in
-- front of it (ccsh puts each job there in turn; Ctrl+Z stops it); every
-- other event to every process.  The console keeps a scrollback, as a
-- Linux console does: Shift+Page Up and Down look back through what
-- scrolled off its top (the last 500 lines); any other key comes back.  A program that computes for a long time
-- without waiting holds everything up, as it does in CraftOS.

local args = { ... }
local repo = "/" .. fs.getDir(fs.getDir(shell.getRunningProgram()))
package.path = (ccnix and ccnix.lib or repo .. "/lib/?.lua;") .. package.path
-- a program of the repo's (path without .lua): ccnix's, or the one beside this
local function program(path)
    local found = ccnix and ccnix.find(path .. ".lua")
    if found then return (found:gsub("%.lua$", "")) end
    return fs.exists(repo .. "/" .. path .. ".lua") and repo .. "/" .. path or nil
end

if args[1] == "boot" then
    local on = args[2] ~= "off"
    settings.set("init.boot", on)
    settings.save()
    if not on then print("init doesn't start at boot now.")
    elseif not (fs.exists("/startup.lua") or fs.exists("/startup/zz-ccnix.lua") or fs.exists("/rom/ccnix/.manifest")) then
        print("init.boot is on, but startup doesn't run init: run deploy/install.")
    else
        print("init starts at boot.")
    end
    return
end
if rawget(_G, "proc") then
    printError("init is already running (process 1): see ps")
    return
end

local K = require("proc").new({ native = term.current(), shell = shell, multishell = multishell })
_G.proc = K.api
-- what services print, to the system log (syslogd: `help syslog`)
local uncapture = K.capture(_G)
K.say(5, "init started")

-- the console: each of these in turn
local chain = {}
local auto = settings.get("ccnix.autostart", "")
if args[1] == "--boot" and auto ~= "" then
    if turtle and program("turtle/autostart") then chain[#chain + 1] = program("turtle/autostart")
    elseif auto == "router" and program("pc/router") then chain[#chain + 1] = program("pc/router") end
end
if settings.get("ccsh.login") and program("bin/ccsh") then chain[#chain + 1] = program("bin/ccsh") end
chain[#chain + 1] = false                       -- the CraftOS shell

local w, h = term.getSize()
local console = window.create(term.current(), 1, 1, w, h, true)
K.scrollback(console, term.current())          -- (Shift+Page Up/Down on the console)
local function nextConsole()
    if #chain == 0 then
        os.shutdown()
        return
    end
    local cmd = table.remove(chain, 1)
    K.console = K.spawn({ cmd = cmd or nil, term = console, tty = "con", session = true, onExit = nextConsole })
end

K.startServices()
nextConsole()
local ok, err = pcall(K.run)
uncapture()
_G.proc = nil
if not ok then error(err, 0) end
