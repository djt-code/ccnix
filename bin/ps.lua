-- ps.lua -- list the processes
--
--   ps [-l] [-e] [-A]
--   ps aux                           (BSD's way: letters with no dash)
--
-- Every process init runs (see `help init`), one a line: its process ID,
-- terminal (con: the screen; pts/n: a telnet session; ?: none, as for a
-- service), state (R running: ps itself, or what started it; S waiting
-- for an event; T stopped, by Ctrl+Z or kill -STOP; N not yet started;
-- a + after it: in its terminal's foreground group, what's typed goes
-- to it), the time it has spent running (seconds), and its command.  -l
-- adds the parent's ID, the process group's (a ccsh job's number, as
-- jobs -l shows it) and when it started (the computer's clock).  -e and
-- -A are taken and ignored: every process is always listed.  BSD's
-- letters with no dash, as hands used to `ps aux` type them, are taken
-- too: a, x and w as nothing more, u and l as -l.  Without
-- init there are no processes to list (only the shell this runs in),
-- and ps says so, status 1.

package.path = (ccnix and ccnix.lib or "/" .. fs.getDir(fs.getDir(shell.getRunningProgram())) .. "/lib/?.lua;") .. package.path  -- ccnix's lib/, or the one beside bin/
local cu = require("cu").init("ps", "ps [-l] [-e] [-A]")
local P = require("proc")               -- the module: the lines' layout; the running init is _G.proc
local opts, operands = cu.getopt({ ... }, "leA")
-- BSD's options (ps aux): what each letter means here
local BSD = { a = "all", x = "all", w = "wide", e = "all", u = "long", l = "long" }
local function bsdWord(w)
    if w == "" then return nil end
    for i = 1, #w do
        if not BSD[w:sub(i, i)] then return nil end
    end
    return w
end
if #operands == 1 and bsdWord(operands[1]) then
    for i = 1, #operands[1] do
        if BSD[operands[1]:sub(i, i)] == "long" then opts.l = true end
    end
    table.remove(operands, 1)
end
if #operands > 0 then cu.usageError("unexpected operand " .. operands[1]) end
local proc = rawget(_G, "proc")
if not proc then
    cu.fail("init isn't running, so there are no processes (`help init`)")
    return cu.exit()
end

local long = opts.l and true or false
local rows = proc.list()
io.write(P.psHeader(long), "\n")
for _, p in ipairs(rows) do io.write(P.psLine(p, long), "\n") end
return cu.exit()
