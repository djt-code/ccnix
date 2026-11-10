-- sleep.lua -- wait a while (POSIX sleep)
--
--   sleep time
--
-- Waits `time` seconds.  Decimals are allowed (sleep 0.5); CraftOS counts
-- time in ticks, so the wait is rounded up to the next 0.05 s.  Ctrl+T
-- stops it early.

package.path = (ccnix and ccnix.lib or "/" .. fs.getDir(fs.getDir(shell.getRunningProgram())) .. "/lib/?.lua;") .. package.path  -- ccnix's lib/, or the one beside bin/
local cu = require("cu").init("sleep", "sleep time")
local convert = require("convert")
local scan = require("scan")
local _, ops = cu.getopt({ ... }, "")
if #ops ~= 1 then cu.usageError(#ops < 1 and "missing operand" or "extra operand") end
local t = ops[1]

-- a decimal number (scan.isNumber: 5, 0.5, .5, 1e3), not below zero
if not scan.isNumber(t) or scan.isNegative(t) then
    cu.usageError("invalid time interval '" .. t .. "'")
end
sleep(convert.toNumber(t))
return cu.exit()
