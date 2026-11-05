-- ps.lua -- list the processes
--
--   ps [-l] [-e] [-A]
--
-- Every process init runs (see `help init`), one a line: its process ID,
-- terminal (con: the screen; pts/n: a telnet session; ?: none, as for a
-- service), state (R running: ps itself, or what started it; S waiting
-- for an event; T stopped, by Ctrl+Z or kill -STOP; N not yet started;
-- a + after it: in its terminal's foreground group, what's typed goes
-- to it), the time it has spent running (seconds), and its command.  -l
-- adds the parent's ID, the process group's (a ccsh job's number, as
-- jobs -l shows it) and when it started (the computer's clock).  -e and
-- -A are taken and ignored: every process is always listed.  Without
-- init there are no processes to list (only the shell this runs in),
-- and ps says so, status 1.

package.path = (ccnix and ccnix.lib or "/" .. fs.getDir(fs.getDir(shell.getRunningProgram())) .. "/lib/?.lua;") .. package.path  -- ccnix's lib/, or the one beside bin/
local cu = require("cu").init("ps", "ps [-l] [-e] [-A]")
local opts, operands = cu.getopt({ ... }, "leA")
if #operands > 0 then cu.usageError("unexpected operand " .. operands[1]) end
local proc = rawget(_G, "proc")
if not proc then
    cu.fail("init isn't running, so there are no processes (`help init`)")
    return cu.exit()
end

local rows = {}
for _, p in ipairs(proc.list()) do
    local cmd = p.service and p.name or p.cmd
    local time = string.format("%.1f", p.cpu)
    local stat = p.state .. (p.fg and "+" or "")
    if opts.l then
        rows[#rows + 1] = string.format("%5d %5d %5d %-6s %-4s %6s %s %s", p.pid, p.ppid, p.pgid or p.pid, p.tty, stat,
            time, os.date("%H:%M", math.floor(p.started / 1000)), cmd)
    else
        rows[#rows + 1] = string.format("%5d %-6s %-4s %6s %s", p.pid, p.tty, stat, time, cmd)
    end
end
io.write(opts.l and "  PID  PPID  PGID TTY    STAT   TIME START CMD\n" or "  PID TTY    STAT   TIME CMD\n")
for _, r in ipairs(rows) do io.write(r, "\n") end
return cu.exit()
