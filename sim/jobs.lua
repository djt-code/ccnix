-- sim/jobs.lua
--
-- ccsh under init's kernel (lib/proc), on a shellworld turtle: a program
-- from the path runs as a process of its own, a child of the shell's (ps
-- shows it); at the prompt each job is a process group, in front of the
-- console while it's the job in front, so Ctrl+Z stops the group and the
-- job, and fg and bg carry both on; kill %n, kill -9 %n and kill -STOP;
-- Ctrl+T; pipes, status and the environment as before; the job's
-- processes when the shell ends.  (sim/ccsh.lua runs it without init.)
local PROJ = ...
package.path = PROJ .. "/lib/?.lua;" .. PROJ .. "/sim/lib/?.lua;" .. package.path
local M = require("mock")
local SW = require("shellworld")
local P = require("proc")
local check = M.check

local W = SW.new(PROJ)
for _, u in ipairs({ "printf", "sort", "head", "cat", "echo", "ps", "kill" }) do W:install(u) end
local HELPERS = {
    tick = [[local _, v = os.pullEvent("x") print("tick " .. tostring(v))]],
    ywait = [[os.pullEvent("y") print("y")]],
    waitT = [[os.pullEvent("never")]],
    crash = [[error("boom")]],
    genv = [[for _, a in ipairs({ ... }) do print(a .. "=" .. tostring(os.getenv and os.getenv(a))) end]],
}
for name, src in pairs(HELPERS) do W:file("ccnix/bin/" .. name .. ".lua", src) end
W.yieldEvents = true

-- ccsh with these arguments as the console's process, under a kernel of
-- its own (K, kept for a look after), init's loop handing it the scripted
-- events.  opts as W:run's, and: when = { [name] = { events } }, put in
-- once a process of that name waits; look(K), after each event.  With
-- nothing left, the user holds Ctrl+T (a few times, then it's stuck).
local K
local kbRead = W.g.read
local function underInit(args, opts)
    opts = opts or {}
    local path = W:install("ccsh")
    -- each line typed takes a turn, as typing it would: the others run meanwhile
    W.g.read = function(...)
        W.os.queueEvent("typed")
        W.os.pullEventRaw("typed")
        return kbRead(...)
    end
    return W:session(opts, function()
        K = P.new({ osT = W.os, term = term, native = term.current(), shell = W.shell, keys = keys,
            settings = { get = function() end, getNames = function() return {} end } })
        _G.proc = K.api
        local res, when = {}, {}
        for name, evs in pairs(opts.when or {}) do when[name] = evs end
        local pid = K.spawn({ name = "ccsh", tty = "con", term = term.current(), session = true,
            fn = function() res.ok, res.err = W:osRun(path, args); res.st = rawget(_G, "POSIX_STATUS") end })
        K.console = pid
        local spare = 3
        for _ = 1, 5000 do
            if not K.procs[pid] then break end
            for _, p in ipairs(K.list) do
                local evs = when[p.name]
                if evs and p.state == "wait" then
                    when[p.name] = nil
                    for _, e in ipairs(evs) do W.T.events[#W.T.events + 1] = e end
                end
            end
            local ev = table.remove(W.T.events, 1)
            if not ev then
                if spare == 0 then res.ok, res.err = false, "stuck"; break end
                spare = spare - 1
                ev = table.pack("terminate")
            end
            K.dispatch(ev)
            if opts.look then opts.look(K) end
        end
        _G.proc = nil
        W.g.read = kbRead
        _G.POSIX_STATUS = res.st            -- (the kernel keeps each process's own; the run's is ccsh's)
        return res.ok, res.err
    end)
end
local function sh(line, opts) return underInit({ "-c", line }, opts) end
local function typed(text, opts)
    opts = opts or {}
    opts.stdin = text
    return underInit({}, opts)
end
local function show(s) return (tostring(s):gsub("\n", "|")) end
local function rowOf(out, cmd)
    for line in out:gmatch("[^\n]+") do
        if line:match("%s" .. cmd:gsub("%-", "%%-") .. "$") then return line end
    end
end
-- a ps -l row's PID PPID PGID TTY STAT
local function cols(row)
    if not row then return {} end
    local pid, ppid, pgid, tty, stat = row:match("^%s*(%d+)%s+(%d+)%s+(%d+)%s+(%S+)%s+(%S+)")
    return { pid = tonumber(pid), ppid = tonumber(ppid), pgid = tonumber(pgid), tty = tty, stat = stat }
end

-- 0. ps aux (BSD's letters, no dash): as ps -l; a word of other letters is still refused
local rb = sh([[ps aux]])
check("ps aux: taken as ps -l (the PPID column there)", rb.out:find("PPID", 1, true) ~= nil and rowOf(rb.out, "ps aux") ~= nil, show(rb.out))
rb = sh([[ps auq]])
check("ps auq: refused, q isn't one of BSD's", rb.out:find("PID", 1, true) == nil, show(rb.out))

-- 1. a program is a process: a child of the shell's, on its terminal
local r = sh([[ps -l]])
local me, shellRow = cols(rowOf(r.out, "ps -l")), cols(rowOf(r.out, "ccsh"))
check("a program runs as a process: the shell's child, on its terminal, in front; in -c, in the shell's group",
    me.ppid == shellRow.pid and me.tty == "con" and me.stat == "R+" and me.pgid == shellRow.pgid
        and shellRow.stat == "S+", show(r.out))
r = sh([[echo $$ $PPID; (echo $$); echo $(echo $$); { echo $$; } &
wait; ps -l]])
shellRow = cols(rowOf(r.out, "ccsh"))
local ids = shellRow.pid and (shellRow.pid .. " " .. shellRow.ppid .. "\n" .. (shellRow.pid .. "\n"):rep(3))
check("$$ is the shell's process ID (in ( ), $(...) and a job too), $PPID its parent's",
    ids ~= nil and shellRow.pid ~= 1 and r.out:sub(1, #ids) == ids, show(r.out))
r = typed("ps -l\n")
me, shellRow = cols(rowOf(r.out, "ps -l")), cols(rowOf(r.out, "ccsh"))
check("at the prompt, its job's own group, in front; the shell not", me.ppid == shellRow.pid and me.pgid ~= shellRow.pgid
    and me.pgid ~= me.pid and me.stat == "R+" and shellRow.stat == "S", show(r.out))

-- 2. what ran before runs the same
W:file("m.txt", "hi\n")
r = sh([[printf 'b\na\nc\n' | sort | head -n 2; cat nope; echo $?; crash; echo $?; X=1 genv X; genv X]])
check("pipes, a utility's status, an error, a command's own environment",
    r.out == "a\nb\n1\n1\nX=1\nX=nil\n" and r.err[1] == "cat: nope: No such file or directory"
        and (r.err[2] or ""):find("boom") ~= nil, show(r.out) .. " " .. show(r.errText))
r = sh([[waitT; echo after]], { events = { { "terminate" } } })
check("Ctrl+T reaches the program (in the shell's group): it and the rest of the line stop, status 130",
    r.out == "" and r.status == 130 and r.err[1] == "Terminated", show(r.out) .. " " .. r.status .. " " .. show(r.errText))
check("nothing left: no processes, proc and os.getenv as they were",
    next(K.procs) == nil and rawget(_G, "proc") == nil and rawget(W.os, "getenv") == nil)

-- 3. jobs
r = sh([[tick & echo "first $!"; wait; echo "end $?"]], { when = { tick = { { "x", 5 } } } })
check("a & runs in the background while the line goes on; $!; wait", r.out:match("^first %d+\ntick 5\nend 0\n$") ~= nil,
    show(r.out))
r = sh([[waitT & kill %1; wait %1; echo $?]])
check("kill %1 ends a job's process (status 130)", r.out == "130\n" and next(K.procs) == nil, show(r.out))
local ctrlZ = { { "key", keys.leftCtrl }, { "key", keys.z }, { "key_up", keys.leftCtrl } }
local states = {}
local function stateOf(name)
    return function(k)
        for _, p in ipairs(k.ps()) do
            if p.name == name then states[#states + 1] = p.state .. (p.fg and "+" or "") end
        end
    end
end
r = typed("tick\njobs\nfg\necho \"fg $?\"\n", { when = { tick = ctrlZ }, look = stateOf("tick") })
local sawStopped = false
for _, st in ipairs(states) do if st == "T" then sawStopped = true end end
check("Ctrl+Z stops the job in front: its process (T, and the shell takes the console back)",
    sawStopped and r.out:find("/$ \n[1]+ Stopped  tick\n/$ [1]+ Stopped  tick\n/$ tick\n", 1, true) ~= nil, show(r.out))
r = typed("tick\njobs\nfg\necho \"fg $?\"\n", { when = { tick = { ctrlZ[1], ctrlZ[2], ctrlZ[3], { "x", 9 } } } })
check("fg carries it on (CONT), in front, with the events it missed while stopped",
    r.out:find("/$ \n[1]+ Stopped  tick\n/$ [1]+ Stopped  tick\n/$ tick\ntick 9\n/$ fg 0\n", 1, true) ~= nil, show(r.out))
r = typed("tick\nywait\nbg\n\n\n", { when = { tick = { ctrlZ[1], ctrlZ[2], ctrlZ[3], { "x", 4 } },
    ywait = { { "y" } } } })
check("bg carries it on in the background (the events it missed first); Done told before a prompt",
    r.out:find("/$ y\n/$ [1]+ tick &\n/$ tick 4\n", 1, true) ~= nil and r.out:find("[1]+ Done     tick\n/$ ", 1, true) ~= nil,
    show(r.out))
r = typed("waitT &\nkill -STOP %1\njobs\nkill -CONT %1\njobs\nkill -9 %1\njobs\n", { look = stateOf("waitT") })
check("kill -STOP and -CONT %1 stop and carry on its process; kill -9 drops it",
    r.out:find("[1]+ Stopped  waitT\n", 1, true) ~= nil and r.out:find("[1]+ Running  waitT &\n", 1, true) ~= nil
        and r.out:find("[1]+ Killed   waitT\n", 1, true) ~= nil and next(K.procs) == nil, show(r.out))
r = typed("waitT &\nps -l\n")
local bgRow = cols(rowOf(r.out, "waitT"))
shellRow = cols(rowOf(r.out, "ccsh"))
check("a background job's process: the shell's child, its own group, not in front",
    bgRow.ppid == shellRow.pid and bgRow.pgid ~= shellRow.pgid and bgRow.stat == "S", show(r.out))
check("... and when the shell ends, it ends too", next(K.procs) == nil)
r = typed("waitT\n", { events = { { "terminate" } } })
check("at the prompt, Ctrl+T ends the program in front, not the shell: $? 130",
    r.out:find("/$ /$ ", 1, true) ~= nil and r.err[1] == "Terminated", show(r.out) .. " " .. show(r.errText))
local ctrlC = { { "key", keys.leftCtrl }, { "key", keys.c }, { "key_up", keys.leftCtrl } }
r = typed("waitT\necho \"st $?\"\n", { when = { waitT = ctrlC } })
check("Ctrl+C: INT for the group in front, which ends as with Ctrl+T ($? 130); the shell stays",
    r.out:find("st 130\n", 1, true) ~= nil and r.err[1] == "Terminated", show(r.out) .. " " .. show(r.errText))
W:file("ccnix/bin/rawc.lua", [[proc.ignore("INT") local _, k repeat _, k = os.pullEvent("key") until k == keys.c print("got c")]])
r = typed("rawc\necho \"st $?\"\n", { when = { rawc = ctrlC } })
check("a program that ignores INT (vi, telnet) gets Ctrl+C as a key", r.out:find("got c\n/$ st 0\n", 1, true) ~= nil,
    show(r.out) .. " " .. show(r.errText))
W:file("ccnix/bin/paint.lua", [[local _, k repeat _, k = os.pullEvent("key") until k == keys.c print("got c")]])
r = typed("paint\necho \"st $?\"\n", { when = { paint = ctrlC } })
check("CraftOS's interactive programs (edit, paint, lua...) get Ctrl+C as a key without asking",
    r.out:find("got c\n/$ st 0\n", 1, true) ~= nil, show(r.out) .. " " .. show(r.errText))
-- at the prompt, with the real line editor: Ctrl+C is the shell's key
W.modules.readline = nil
local evs = { ctrlC[1], ctrlC[2], ctrlC[3] }
for c in ("echo \"st $?\""):gmatch(".") do evs[#evs + 1] = { "char", c } end
evs[#evs + 1] = { "key", keys.enter }
evs[#evs + 1] = { "key", keys.leftCtrl }
evs[#evs + 1] = { "key", keys.d }
r = typed("", { events = evs })
check("at the prompt Ctrl+C reaches the shell, not as INT: the line dropped, $? 130; Ctrl+D leaves",
    r.ok and r.out:find("st 130\n", 1, true) ~= nil and r.errText == "", show(r.out) .. " " .. show(r.errText))
W.modules.readline = SW.readlineStandIn()

-- 4. nothing left behind
check("after: the screen, io, printing globals, POSIX_SH, os.getenv and proc are as they were",
    term.current() == term.native() and W.io.output() == W.io.stdout and W.io.input() == W.io.stdin
    and rawget(_G, "write") == nil and _G.POSIX_SH == nil and rawget(W.os, "getenv") == nil
    and rawget(_G, "proc") == nil)
