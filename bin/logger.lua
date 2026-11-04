-- logger.lua -- put messages in the system log (POSIX logger, with BSD's options)
--
--   logger [-is] [-p priority] [-t tag] [message...]
--
-- Logs the message (its words, spaces between), or each line of standard
-- input when there are none: `backup | logger -t backup`.  -p is
-- facility.severity ("local3.err") or a severity alone (user's); the
-- default is user.notice.  -t is the tag the message is logged under
-- (logger, or $USER when it's set); -i adds this process's ID; -s also
-- prints it on standard error.  syslogd (`help syslog`) files it as its
-- rules say; without init it goes to the log files directly.

package.path = (ccnix and ccnix.lib or "/" .. fs.getDir(fs.getDir(shell.getRunningProgram())) .. "/lib/?.lua;") .. package.path  -- ccnix's lib/, or the one beside bin/
local cu = require("cu").init("logger", "logger [-is] [-p priority] [-t tag] [message...]")
local L = require("log")
local opts, words = cu.getopt({ ... }, "isp:t:")

local fac, sev = "user", "notice"
if opts.p then
    local f, s = opts.p:match("^([^%.]+)%.([^%.]+)$")
    if not f then f, s = "user", opts.p end
    if not L.facility(f) then cu.usageError("unknown facility " .. f) end
    if not L.severity(s) then cu.usageError("unknown severity " .. s) end
    fac, sev = f, s
end
local tag = opts.t or os.getenv and os.getenv("USER") or "logger"
if tag == "" then tag = "logger" end
local log = L.new(tag, fac, { pid = opts.i == true, perror = opts.s and "stderr" or nil })

if #words > 0 then
    log.log(sev, table.concat(words, " "))
else
    local input, n = io.input(), 0
    for l in function() return cu.readLine(input) end do
        log.log(sev, l)
        n = n + 1
        if n % 64 == 0 and input ~= io.stdin then os.queueEvent("logger"); os.pullEvent("logger") end
    end
end
return cu.exit()
