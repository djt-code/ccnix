-- kill.lua -- signal processes
--
--   kill [-s signal | -signal] pid...
--   kill -l
--
-- Sends each process (by ID: see ps), or with -- -n every process in
-- group n, a signal: TERM (the default), INT or HUP are Ctrl+T for it (a
-- terminate event: most programs stop, and one that catches it can tidy
-- up first); KILL ends it at once; STOP and TSTP stop it (it keeps the
-- events it misses), CONT carries it on; 0 only checks it's there.  A
-- signal is a name (TERM, SIGTERM) or its number (15, 9, 2, 1, 18, 19,
-- 20, 0).  -l lists them.  Process 1 is init itself.  Needs init
-- (`help init`); ccsh's own kill also takes %job.
-- Exit status 1 if any process couldn't be signalled.

package.path = (ccnix and ccnix.lib or "/" .. fs.getDir(fs.getDir(shell.getRunningProgram())) .. "/lib/?.lua;") .. package.path  -- ccnix's lib/, or the one beside bin/
local cu = require("cu").init("kill", "kill [-s signal | -signal] [--] pid|-pgid... | kill -l")
local P = require("proc")              -- the module, for the signal names; the running init is _G.proc
local tables = require("tables")
local text = require("text")
local convert = require("convert")
local args = { ... }

if args[1] == "-l" then
    io.write(table.concat(tables.sortedKeys(P.SIGNALS), " ") .. "\n")
    return cu.exit()
end

-- (read by hand, not getopt: -9 and -KILL are signals, and a -pgid can
-- follow -s TERM without a --)
local sig, i = "TERM", 1
local named = args[1] and args[1] ~= "--" and text.stripPrefix(args[1], "-")    -- -signal
if args[1] == "-s" then
    sig = args[2] and P.signal(args[2])
    if not sig then cu.usageError("unknown signal " .. tostring(args[2])) end
    i = 3
elseif named and named ~= "" then
    sig = P.signal(named)
    if not sig then cu.usageError("unknown signal " .. named) end
    i = 2
end
if args[i] == "--" then i = i + 1 end
if not args[i] then cu.usageError("no process ID") end

local proc = rawget(_G, "proc")
if not proc then
    cu.fail("init isn't running, so there are no processes (`help init`)")
    return cu.exit()
end
for k = i, #args do
    local pid = convert.toInteger(args[k])
    if not pid or pid == 0 then
        cu.fail(args[k] .. ": not a process ID")
    else
        local ok, err = proc.kill(pid, sig)
        if not ok then cu.fail(args[k] .. ": " .. err) end
    end
end
return cu.exit()
