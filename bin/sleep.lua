-- sleep.lua -- wait a while (POSIX sleep)
--
--   sleep time
--
-- Waits `time` seconds.  Decimals are allowed (sleep 0.5); CraftOS counts
-- time in ticks, so the wait is rounded up to the next 0.05 s.  Ctrl+T
-- stops it early.

package.path = (ccnix and ccnix.lib or "/" .. fs.getDir(fs.getDir(shell.getRunningProgram())) .. "/lib/?.lua;") .. package.path  -- ccnix's lib/, or the one beside bin/
local cu = require("cu").init("sleep", "sleep time")
local scan = require("scan")
local _, ops = cu.getopt({ ... }, "")
if #ops ~= 1 then cu.usageError(#ops < 1 and "missing operand" or "extra operand") end
local t = ops[1]

-- time: digit+ ("." digit*)? | "." digit+
local function isTime(text)
    local sc = scan.new(text)
    local whole, fraction = sc:readWhile(scan.isDigit), ""
    if sc:accept(".") then fraction = sc:readWhile(scan.isDigit) end
    return sc:atEnd() and (whole ~= "" or fraction ~= "")
end

if not isTime(t) then
    cu.usageError("invalid time interval '" .. t .. "'")
end
sleep(tonumber(t))
return cu.exit()
