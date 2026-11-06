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
-- At boot (init.boot on: `ccnix setup init`) startup runs init last.
-- It starts the services that are enabled, then the console: the
-- autostart (ccnix.autostart: the miner, farmer, router...) if one
-- is set, then ccsh if ccsh.login is on, then the CraftOS shell;
-- each when the one before it ends.  Leaving that last shell shuts the
-- computer down, as leaving CraftOS's own does.  Run by hand, init skips
-- the autostart.  A turtle's job that's a service of the same name
-- (service.mine..., which setup sets up with init) runs as that instead,
-- in the background, and the console starts at ccsh or the shell.
--
-- What a service prints is logged too, a line each under its name
-- (printError's at err), and so is each service starting, ending and
-- failing: syslogd, a service of its own, files it (`help syslog`).
-- service.<name>.log false leaves a service's output out.
--
-- The keyboard and mouse go to the console: to the process group in
-- front of it (ccsh puts each job there in turn; Ctrl+Z stops it, Ctrl+C
-- ends it); every
-- other event to every process.  The console keeps a scrollback, as a
-- Linux console does: Shift+Page Up and Down, or the mouse wheel, look
-- back through what scrolled off its top (the last 500 lines); any other
-- key comes back.  What scrolls with the wheel itself keeps it: vi, the
-- pager, CraftOS's edit.  What boot showed (the MOTD, the startup
-- files' output) stays on the console.  A program that computes for a long time
-- without waiting holds everything up, as it does in CraftOS.
--
-- A program that crashes ends its own process alone, failed (status 1
-- unless it gave one): the error and its traceback go to the log, and
-- `service status` shows a service's.  When a process ends, the sockets
-- it had open are closed (its ports free again).
--
-- A panic: if init itself fails (a bug in it, not in a program), it
-- writes what it knew to /var/log/panic (the error and where, the
-- processes, the log's messages not yet filed), then reboots after
-- init.panic seconds (10 unless set; holding Ctrl+T meanwhile shuts the
-- computer down instead; 0: no wait, it shuts down at once, as it did
-- before).  After three panics in a row (each within ten minutes of the
-- last) it shuts down instead, so a fault that comes back every boot
-- doesn't reboot it for ever.  The next boot logs the panic at crit and
-- moves the report to /var/log/panic.1.

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
        print("init.boot is on, but startup doesn't run init: run ccnix setup init.")
    else
        print("init starts at boot.")
    end
    return
end
if rawget(_G, "proc") then
    printError("init is already running (process 1): see ps")
    return
end

local P = require("proc")
local resume0 = coroutine.resume                -- (the kernel swaps it while a process runs)
-- (commands run through lib/procrun, so a crash is seen)
local K = P.new({ native = term.current(), shell = shell, multishell = multishell, runner = program("lib/procrun") })
_G.proc = K.api
-- what services print, to the system log (syslogd: `help syslog`)
local uncapture = K.capture(_G)
K.say(5, "init started")
K.lastPanic()                                   -- (the last boot's, if it ended in one: logged at crit)
-- a process's sockets closed when it ends (lib/net's running stack, if it's up)
K.onReap(function(p)
    local S = rawget(_G, "ccnet")
    if S and S.closeOwned then S.closeOwned(p.pid) end
end)

-- the console: each of these in turn
local chain = {}
local auto = settings.get("ccnix.autostart", "")
local def = auto ~= "" and require("proc").serviceDef(auto)
if args[1] == "--boot" and auto ~= "" and not (turtle and def and def.enabled) then
    if turtle and program("turtle/autostart") then chain[#chain + 1] = program("turtle/autostart")
    elseif auto == "router" and program("pc/router") then chain[#chain + 1] = program("pc/router") end
end
if settings.get("ccsh.login") and program("bin/ccsh") then chain[#chain + 1] = program("bin/ccsh") end
chain[#chain + 1] = false                       -- the CraftOS shell

local w, h = term.getSize()
local under = term.current()
-- A new window starts blank, and draws itself so over what's under it as
-- it's made: what boot left on the screen (the MOTD, the startup files'
-- output) is read first, when it can be read back (boot sees that it
-- can), then put in the console.
local shown
if under.getLine then
    shown = { lines = {}, x = 0, y = 0, fg = under.getTextColour(), bg = under.getBackgroundColour() }
    for y = 1, h do shown.lines[y] = { under.getLine(y) } end
    shown.x, shown.y = under.getCursorPos()
end
local console = window.create(under, 1, 1, w, h, true)
if shown then
    for y = 1, h do
        console.setCursorPos(1, y)
        console.blit(table.unpack(shown.lines[y]))
    end
    console.setCursorPos(shown.x, shown.y)
    console.setTextColour(shown.fg)
    console.setBackgroundColour(shown.bg)
end
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
-- (the traceback taken where it failed, before the stack unwinds)
local ok, failure = xpcall(K.run, function(e) return { err = e, trace = debug.traceback(tostring(e), 2) } end)
uncapture()
_G.proc = nil
if ok then return end

-- A panic: init itself failed.  What it knew to /var/log/panic, then a
-- reboot after init.panic seconds (0: shut down now, as boot does after
-- an error).
local err = type(failure) == "table" and failure.err or failure
-- (it may have failed in the middle of a process's turn: its window and
-- the kernel's coroutine.resume in place)
pcall(term.redirect, term.native())
coroutine.resume = resume0
local wrote, why = K.writePanic(err, type(failure) == "table" and failure.trace or nil)
printError("init panicked: " .. tostring(err))
printError(wrote and ("(what it knew is in " .. wrote .. ")") or ("(" .. P.PANIC .. " not written: " .. tostring(why) .. ")"))
local delay = tonumber(settings.get("init.panic")) or 10
-- (a fault that comes back every boot stops after a few, not a reboot
-- every few seconds for ever)
local inRow = K.panicsInRow(os.epoch("utc"))
if delay > 0 and inRow > P.PANIC_MOST then
    printError("init has panicked " .. inRow .. " times in a row: not rebooting again")
    delay = 0
end
if delay <= 0 then error(err, 0) end
print("Rebooting in " .. delay .. " s (hold Ctrl+T to shut down instead; the setting init.panic is the wait)")
sleep(delay)
os.reboot()
