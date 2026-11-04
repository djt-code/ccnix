-- service.lua -- background services, kept running by init
--
--   service                         the services: state, process ID, whether at boot
--   service status [name]           the same, with its command, when it started, what it last showed
--   service start|stop|restart name
--   service enable|disable name     start it at boot, or not
--   service add name command...     a new service (not started: start or enable it)
--   service remove name
--
-- A service is a command init runs in the background and starts again if
-- it ends (after 1 s, 2 s, 4 s... up to a minute).  It's kept in the
-- settings: service.<name>.cmd, service.<name>.enabled and
-- service.<name>.restart ("always", or "no": leave it ended).  What it
-- prints goes to a screen of its own, not the console: status shows the
-- last of it; and to the system log, a line each under its name
-- (/var/log/messages: `help syslog`), unless service.<name>.log is false.  add, remove, enable and disable work without init; the
-- rest need it running (`help init`).

package.path = (ccnix and ccnix.lib or "/" .. fs.getDir(fs.getDir(shell.getRunningProgram())) .. "/lib/?.lua;") .. package.path  -- ccnix's lib/, or the one beside bin/
local cu = require("cu").init("service",
    "service [status [name] | start|stop|restart|enable|disable|remove name | add name command...]")
local P = require("proc")               -- the module: the settings' services, when init isn't running
local args = { ... }
local action, name = args[1] or "list", args[2]
local proc = rawget(_G, "proc")

local function needInit()
    if not proc then
        cu.fail("init isn't running (`help init`)")
        cu.exit()
    end
end

local function key(n, what) return "service." .. n .. "." .. what end
local function defined(n) return P.serviceDef(n) ~= nil end

local function since(ms)
    if not ms then return "" end
    local s = math.floor((os.epoch("utc") - ms) / 1000)
    if s < 120 then return s .. "s" elseif s < 7200 then return math.floor(s / 60) .. "m" end
    return math.floor(s / 3600) .. "h"
end

if action == "list" or action == "status" then
    local list = proc and proc.services() or P.serviceStatus()
    if name then
        local keep = {}
        for _, s in ipairs(list) do if s.name == name then keep[1] = s end end
        if not keep[1] then cu.fail(name .. ": no such service"); return cu.exit() end
        list = keep
    end
    if #list == 0 then
        print("No services.  service add name command... sets one up.")
        return cu.exit()
    end
    for _, s in ipairs(list) do
        io.write(string.format("%-10s %-10s %5s %s\n", s.name, s.state, s.pid and tostring(s.pid) or "-",
            s.enabled and "at boot" or ""))
        if action == "status" then
            io.write("  " .. (s.cmd or "?") .. "\n")
            if s.since then io.write("  started " .. since(s.since) .. " ago; restarts: " .. s.restarts .. "\n") end
            if s.last then io.write("  last time: " .. s.last .. "\n") end
            for i = math.max(1, #(s.lines or {}) - 4), #(s.lines or {}) do io.write("  | " .. s.lines[i] .. "\n") end
        end
    end
    if not proc then io.write("(init isn't running: nothing is started)\n") end
    return cu.exit()
end

if not name then cu.usageError("which service?") end

if action == "add" then
    if not args[3] then cu.usageError("add needs a command") end
    if defined(name) then cu.fail(name .. ": already set up (remove it first)"); return cu.exit() end
    settings.set(key(name, "cmd"), table.concat(args, " ", 3))
    settings.save()
    print(name .. " set up: service start " .. name .. " (now), service enable " .. name .. " (at boot)")
elseif action == "remove" then
    if not defined(name) then cu.fail(name .. ": no such service"); return cu.exit() end
    if proc then proc.stop(name) end
    for _, what in ipairs({ "cmd", "enabled", "restart" }) do settings.unset(key(name, what)) end
    settings.save()
elseif action == "enable" or action == "disable" then
    if not defined(name) then cu.fail(name .. ": no such service"); return cu.exit() end
    settings.set(key(name, "enabled"), action == "enable")
    settings.save()
    if action == "enable" and not settings.get("init.boot") then
        print("(init doesn't start at boot yet: init boot)")
    end
elseif action == "start" or action == "stop" or action == "restart" then
    needInit()
    local ok, err = proc[action](name)
    if not ok then cu.fail(err) end
else
    cu.usageError("unknown action " .. action)
end
return cu.exit()
