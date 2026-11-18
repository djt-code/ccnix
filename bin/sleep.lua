-- sleep.lua -- wait a while (POSIX sleep)
--
--   sleep time
--
-- Waits `time` real seconds, as the clock on the wall counts them, at any
-- server tick rate (lib/realtime).  Decimals are allowed (sleep 0.5);
-- CraftOS counts time in ticks, so the wait is rounded up to the next
-- tick.  Ctrl+T stops it early.

package.path = (ccnix and ccnix.lib or "/" .. fs.getDir(fs.getDir(shell.getRunningProgram())) .. "/lib/?.lua;") .. package.path  -- ccnix's lib/, or the one beside bin/
local cu = require("cu").init("sleep", "sleep time")
local convert = require("convert")
local scan = require("scan")
local realtime = require("realtime")
local _, ops = cu.getopt({ ... }, "")
if #ops ~= 1 then cu.usageError(#ops < 1 and "missing operand" or "extra operand") end
local t = ops[1]

-- a decimal number (scan.isNumber: 5, 0.5, .5, 1e3), not below zero
if not scan.isNumber(t) or scan.isNegative(t) then
    cu.usageError("invalid time interval '" .. t .. "'")
end
realtime.sleep(convert.toNumber(t))
return cu.exit()
