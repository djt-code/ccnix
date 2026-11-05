-- sim/proc.lua
--
-- lib/proc.lua, init's kernel, over a fake os, terminal, window API and
-- settings: processes started at once and as events come; the keyboard
-- to the console only, other events to all, by each one's filter;
-- inject; signals (TERM as a terminate event, KILL, 0, init refused);
-- each process's own terminal and environment, in place only while it
-- runs; ps; proc_exit and wait; services: started from the settings,
-- started again after they end (1 s, 2 s, 4 s...), not with restart =
-- "no", stopped (Ctrl+T, then KILL after 3 s), what they showed.
local PROJ = ...
package.path = PROJ .. "/lib/?.lua;" .. PROJ .. "/sim/lib/?.lua;" .. package.path
local M = require("mock")
local check = M.check
local P = require("proc")

-- the fake world
local events, timers, nextTimer, CLOCK = {}, {}, 0, 1000000
local fakeOs = {}
fakeOs.pullEventRaw = function(f)
    if coroutine.isyieldable() then return coroutine.yield(f) end
    return table.unpack(table.remove(events, 1) or { "none" })
end
fakeOs.pullEvent = function(f)
    local ev = table.pack(fakeOs.pullEventRaw(f))
    if ev[1] == "terminate" then error("Terminated", 0) end
    return table.unpack(ev, 1, ev.n)
end
fakeOs.queueEvent = function(...) events[#events + 1] = table.pack(...) end
fakeOs.startTimer = function(s) nextTimer = nextTimer + 1; timers[nextTimer] = CLOCK + s * 1000; return nextTimer end
fakeOs.epoch = function() return CLOCK end
local COMMANDS = {}
fakeOs.run = function(env, path, cmd)
    local fn = COMMANDS[cmd or "shell"]
    if not fn then error("no command " .. tostring(cmd)) end
    fn(env)
    return true
end
-- time passes: the timers due fire, in order
local function pass(seconds)
    CLOCK = CLOCK + seconds * 1000
    local due = {}
    for id, at in pairs(timers) do if at <= CLOCK then due[#due + 1] = id end end
    table.sort(due)
    for _, id in ipairs(due) do timers[id] = nil; events[#events + 1] = table.pack("timer", id) end
end

local current = { name = "native" }
local fakeTerm = {
    redirect = function(t) local old = current; current = t; return old end,
    current = function() return current end,
}
local native = { getSize = function() return 20, 5 end, isColour = function() return true end,
    getPaletteColour = function() return 0, 0, 0 end }
local fakeWindow = { create = function(parent, x, y, w, h)
    local rows = {}
    for r = 1, h do rows[r] = (" "):rep(w) end
    local cx, cy = 1, 1
    local win = { parent = parent, rows = rows }
    function win.getSize() return w, h end
    function win.getLine(r) return rows[r] end
    function win.write(s)
        rows[cy] = (rows[cy]:sub(1, cx - 1) .. s .. rows[cy]:sub(cx + #s)):sub(1, w)
        cx = cx + #s
    end
    function win.newline() cy = math.min(h, cy + 1); cx = 1 end
    return win
end }
local STORE = {}
local fakeSettings = {
    get = function(k) return STORE[k] end,
    getNames = function() local t = {} for k in pairs(STORE) do t[#t + 1] = k end table.sort(t) return t end,
}

local KEYS = { leftCtrl = 29, rightCtrl = 157, z = 44 }
local K = P.new({ native = native, osT = fakeOs, term = fakeTerm, window = fakeWindow, settings = fakeSettings,
    env = { BASE = "yes" }, keys = KEYS })
-- drain: hand every queued event on, as init's loop does
local function drain()
    for _ = 1, 1000 do
        if not events[1] then return end
        K.dispatch(table.remove(events, 1))
    end
end

-- 1. processes and events
local log = {}
local consoleTerm = fakeWindow.create(native, 1, 1, 20, 5)
local con = K.spawn({ fn = function()
    while true do
        local ev = table.pack(fakeOs.pullEventRaw())
        log[#log + 1] = "con:" .. ev[1] .. ":" .. tostring(ev[2])
        if ev[1] == "char" and ev[2] == "q" then return end
    end
end, name = "con", term = consoleTerm, tty = "con" })
K.console = con
local during = {}
local bg = K.spawn({ fn = function()
    during.term = fakeTerm.current()
    during.env = fakeOs.getenv("BASE")
    fakeOs.setenv("MINE", "1")
    while true do
        local _, v = fakeOs.pullEvent("tick")
        log[#log + 1] = "bg:tick:" .. tostring(v)
    end
end, name = "bg" })
check("spawned outside a process: started at once, in its own (hidden) terminal and environment",
    during.term == K.procs[bg].term and during.term ~= consoleTerm and during.env == "yes"
        and current.name == "native" and rawget(fakeOs, "getenv") == nil)
check("the environment: its own copy (setenv stays in it)", K.procs[bg].env.MINE == "1" and K.env.MINE == nil)
fakeOs.queueEvent("char", "a")
fakeOs.queueEvent("tick", 1)
fakeOs.queueEvent("other", 2)
drain()
check("the keyboard to the console alone; other events to everyone, as each one's filter lets them",
    table.concat(log, " ") == "con:char:a con:tick:1 bg:tick:1 con:other:2", table.concat(log, " "))
log = {}
K.inject(bg, "tick", "direct")
K.inject(bg, "char", "z")
check("inject: one process only, and still only what it waits for", table.concat(log, " ") == "bg:tick:direct",
    table.concat(log, " "))

-- 2. spawned from inside a process: started on the next turn, inheriting the env
local child
log = {}
local parent = K.spawn({ fn = function()
    fakeOs.setenv("FROM", "parent")
    child = K.spawn({ fn = function()
        log[#log + 1] = "child:" .. tostring(fakeOs.getenv("FROM"))
        fakeOs.pullEvent("never")
    end, name = "child" })
    log[#log + 1] = "parent spawned"
    fakeOs.pullEvent("never")
end, name = "parent" })
drain()
check("spawned from a process: after it yields; the parent's environment, its parent its ID",
    table.concat(log, " ") == "parent spawned child:parent" and K.procs[child].ppid == parent, table.concat(log, " "))

-- 3. ps
local ps = K.ps()
local names = {}
for _, p in ipairs(ps) do names[#names + 1] = p.pid .. ":" .. p.name .. ":" .. p.tty .. ":" .. p.state end
check("ps: init first, then the rest oldest first, with tty and state",
    table.concat(names, " ") == "1:init:?:S 2:con:con:S 3:bg:?:S 4:parent:?:S 5:child:?:S", table.concat(names, " "))

-- 4. signals
local ended = {}
K.procs[child].onExit = function(p) ended[#ended + 1] = p.pid .. ":" .. tostring(p.err) end
check("kill 0: it's there", K.kill(child, 0) == true)
K.kill(child, "TERM")
drain()
check("TERM: a terminate event, which ends it (Terminated)", K.procs[child] == nil and ended[1] == child .. ":Terminated",
    tostring(ended[1]))
K.kill(parent, 9)
check("KILL (9): gone at once", K.procs[parent] == nil and K.exited[parent].err == "killed")
local last = events[#events]
check("each end is a proc_exit event", last[1] == "proc_exit" and last[2] == parent and last[3] == "killed")
local ok, why = K.kill(1)
local ok2, why2 = K.kill(99)
check("init can't be signalled; no such process", not ok and why == "init can't be signalled"
    and not ok2 and why2 == "no such process")
check("P.signal: a name, SIG-name, number or numeric string; 0 is 0; unknown is nil",
    P.signal("term") == "TERM" and P.signal("SIGTERM") == "TERM" and P.signal(15) == "TERM"
    and P.signal("15") == "TERM" and P.signal("9") == "KILL" and P.signal(0) == 0 and P.signal("0") == 0
    and P.signal("FOO") == nil and P.signal(99) == nil)
drain()
fakeOs.queueEvent("char", "q")
drain()
check("the console ends when its program does", K.procs[con] == nil)
K.console = nil

-- 5. services
STORE["service.web.cmd"] = "web"
STORE["service.web.enabled"] = true
STORE["service.once.cmd"] = "once"
STORE["service.once.restart"] = "no"
local runs = 0
COMMANDS.web = function()
    runs = runs + 1
    fakeTerm.current().write("web run " .. runs)
    fakeOs.pullEvent("never")
end
COMMANDS.once = function() end
K.startServices()
local st = K.serviceStatus()
check("services: from the settings, sorted; the enabled one started at boot, the other not",
    #st == 2 and st[1].name == "once" and st[1].state == "-" and st[2].name == "web" and st[2].state == "running"
        and st[2].enabled and runs == 1)
local pid1 = K.services.web.pid
K.kill(pid1, "TERM")
drain()
check("it ends: restarting, not yet back", K.services.web.state == "restarting" and runs == 1)
pass(1); drain()
check("back after 1 s, a new process", K.services.web.state == "running" and runs == 2 and K.services.web.pid ~= pid1)
K.kill(K.services.web.pid, "TERM"); drain()
pass(1); drain()
check("ending again soon after: 2 s this time", runs == 2)
pass(1); drain()
check("(there it is)", runs == 3 and K.services.web.restarts == 2, runs)
st = K.serviceStatus()
check("status: what it showed last, its process, restarts", st[2].lines[1] == "web run 3" and st[2].pid == K.services.web.pid
    and st[2].restarts == 2 and st[2].last == "failed: Terminated", tostring(st[2].last))
COMMANDS.web = function() while true do fakeOs.pullEventRaw("never") end end   -- (now one that ignores Ctrl+T)
K.kill(K.services.web.pid, "KILL")
pass(4); drain()
local pid = K.services.web.pid
check("started again after a KILL too", K.services.web.state == "running" and K.procs[pid] ~= nil)
K.serviceStop("web")
drain()
check("stop: Ctrl+T first; one that ignores it is still there", K.procs[pid] ~= nil and K.services.web.state == "running")
pass(3); drain()
check("... and killed 3 s later, stopped, not started again", K.procs[pid] == nil and K.services.web.state == "stopped")
pass(60); drain()
check("(still stopped)", K.services.web.state == "stopped")
check("start", K.serviceStart("web") and K.services.web.state == "running")
local again, err = K.serviceStart("web")
check("start again: it's already running", not again and err == "web is already running")
K.serviceStart("once")
drain()
check("restart = no: left ended", K.services.once.state == "exited" and K.services.once.last == "ended")
local none, e2 = K.serviceStart("nope")
check("an unknown service", not none and e2:find("no such service"))
local w = K.services.web.pid
K.api.restart("web")
pass(4); drain()
check("restart: stopped (Ctrl+T ignored: killed), then started anew",
    K.services.web.state == "running" and K.services.web.pid ~= w and K.procs[w] == nil)

-- 6. proc.wait, from a process
local result
local short = K.spawn({ fn = function() fakeOs.pullEvent("go") end, name = "short" })
K.spawn({ fn = function() result = table.pack(K.api.wait(short)) end, name = "waiter" })
drain()
fakeOs.queueEvent("go")
drain()
check("proc.wait: true once it has ended", result and result[1] == true)
check("after: no environment left on os, the terminal as it was", rawget(fakeOs, "getenv") == nil and current.name == "native")

-- 7. the system log: held until syslogd registers, then handed over in
-- memory; what services print captured (print, write, printError,
-- io.write, io.stderr, "<N>"), not the console's or syslogd's own
local function msgs(list, app)
    local t = {}
    for _, r in ipairs(list) do
        if not app or r.app == app then t[#t + 1] = r.sev .. ":" .. tostring(r.app) .. ":" .. r.msg end
    end
    return table.concat(t, " | ")
end
local early = #K.held
check("before syslogd: init's messages about services wait in init", early > 0 and msgs(K.held, "init"):find("6:init:started web"),
    msgs(K.held))
local got, G = {}, nil
local sysd = K.spawn({ fn = function()
    local ok = K.api.register("syslog")
    got.ok = ok
    while true do
        local ev = table.pack(fakeOs.pullEventRaw())
        if ev[1] == "syslog" then got[#got + 1] = ev[2] end
        if ev[1] == "say" then G.print("syslogd's own line") end
    end
end, name = "syslogd", service = "syslogd", capture = true })
drain()
check("register: what waited is handed over, as syslog events", got.ok and #got == early and #K.held == 0, #got .. " of " .. early)
local again2, why3 = K.api.register("syslog")
check("register from outside a process: refused", again2 == false and why3 == "not a process")

-- a fake BIOS's printing globals, wrapped as init wraps _G's
local screen = {}
local function biosWrite(s) screen[#screen + 1] = tostring(s); return 1 end
G = { io = {} }
G.write = biosWrite
G.print = function(...)
    local parts = table.pack(...)
    for i = 1, parts.n do G.write(tostring(parts[i])); if i < parts.n then G.write("\t") end end
    G.write("\n")
end
G.printError = function(...) G.print(...) end
G.io.stdout = { _handle = { write = biosWrite } }
G.io.stderr = { _handle = { write = function(s) G.write(s) end } }
G.io.write = function(...) for _, s in ipairs({ ... }) do G.io.stdout._handle.write(s) end end
local undo = K.capture(G)
got = {}
COMMANDS.chatty = function()
    G.print("hello", "there")
    G.write("half a ")
    G.write("line\n")
    G.printError("it broke")
    G.io.write("from io.write\n")
    G.io.stderr._handle.write("to stderr\n")
    G.print("<4>a warning")
    G.print("   ")
    K.api.uncaptured(G.print, "not this one")
    G.write("no newline at the end")
    fakeOs.pullEvent("go")
end
STORE["service.chatty.cmd"] = "chatty"
K.serviceStart("chatty")
drain()
local cpid = K.services.chatty.pid
check("a service's prints: a line each, under its name and process; err from printError and io.stderr; <N>; blanks and uncaptured left out",
    msgs(got, "chatty") == "6:chatty:hello\tthere | 6:chatty:half a line | 3:chatty:it broke | 6:chatty:from io.write"
        .. " | 3:chatty:to stderr | 4:chatty:a warning" and got[#got].pid == cpid and got[#got].fac == 3,
    msgs(got))
check("... still drawn on its screen as before", table.concat(screen):find("hello\tthere\nhalf a line\nit broke\n", 1, true)
    and table.concat(screen):find("not this one", 1, true))
got = {}
fakeOs.queueEvent("go")
drain()
check("a partial line when it ends; init says it ended",
    msgs(got) == "6:chatty:no newline at the end | 5:init:chatty ended; again in 1 s", msgs(got))
K.serviceStop("chatty"); pass(1); drain()

got = {}
local conLog = K.spawn({ fn = function() G.print("typed at the console") end, name = "sh", tty = "con" })
drain()
fakeOs.queueEvent("say")
drain()
check("not captured: a process that isn't a service, nor syslogd's own prints", #got == 0, msgs(got))
STORE["service.quiet.cmd"] = "quiet"
STORE["service.quiet.log"] = false
COMMANDS.quiet = function() G.print("shh"); fakeOs.pullEvent("never") end
K.serviceStart("quiet")
drain()
check("service.<name>.log false: not captured", msgs(got, "quiet") == "" and msgs(got, "init"):find("started quiet"), msgs(got))
local big = {}
COMMANDS.long = function() G.write(("x"):rep(1500)); fakeOs.pullEvent("never") end
STORE["service.long.cmd"] = "long"
K.serviceStart("long")
drain()
check("a line past 1 KiB without a newline: logged then", msgs(got, "long") == "6:long:" .. ("x"):rep(1500), #msgs(got, "long"))

-- the backlog: from inside one process, past 500 waiting, dropped and counted
got = {}
COMMANDS.flood = function()
    for i = 1, 600 do K.api.log({ fac = 1, sev = 6, app = "flood", msg = "n" .. i }) end
    fakeOs.pullEvent("go2")
    K.api.log({ fac = 1, sev = 6, app = "flood", msg = "after" })
    fakeOs.pullEvent("never")
end
STORE["service.flood.cmd"] = "flood"
K.serviceStart("flood")
drain()
local n = #got
fakeOs.queueEvent("go2")
drain()
check("past 500 in the inbox: dropped, then counted once it's handed on",
    n <= 500 and n > 400 and got[#got - 1].msg:find("^%d+ messages dropped$") and got[#got].msg == "after",
    n .. " " .. tostring(got[#got - 1] and got[#got - 1].msg))

-- syslogd gone: held again (the last 200)
K.kill(sysd, 9)
for i = 1, 250 do K.log({ fac = 1, sev = 6, app = "x", msg = "h" .. i }) end
check("syslogd gone: the last 200 held", #K.held == 200 and K.held[1].msg == "h51" and K.syslog == nil, #K.held)
check("a held message has its time and host filled in", K.held[1].time == CLOCK and K.held[1].host == "0", tostring(K.held[1].host))
undo()
check("capture undone: the globals as they were", G.write == biosWrite and G.io.stdout._handle.write == biosWrite)

-- 8. sessions, process groups and terminals: what's typed goes to the
-- group in front; Ctrl+Z stops it (not the leader's own group, nor one
-- that ignores TSTP); a stopped process keeps its events until CONT;
-- kill -pgid; with no one in front, the leader; the leader gone, HUP;
-- orphans to init; exit status; enter and leave; capture for a child on
-- a service's terminal
local seen = {}
local function noter(name)
    return function()
        while true do
            local ev = table.pack(fakeOs.pullEventRaw())
            seen[#seen + 1] = name .. ":" .. ev[1] .. (ev[2] ~= nil and (":" .. tostring(ev[2])) or "")
            if ev[1] == "terminate" then return end
        end
    end
end
local function saw(prefix)
    local t = {}
    for _, e in ipairs(seen) do if not prefix or e:sub(1, #prefix) == prefix then t[#t + 1] = e end end
    return table.concat(t, " ")
end
local ids = {}
local L = K.spawn({ name = "lead", tty = "pts/7", fn = function()
    ids.a = K.spawn({ name = "a", pgid = true, fn = noter("a") })
    ids.b = K.spawn({ name = "b", pgid = ids.a, fn = noter("b") })
    ids.c = K.spawn({ name = "c", fn = noter("c") })
    ids.q = K.spawn({ name = "q", pgid = true, fn = function() K.api.ignore("TSTP"); noter("q")() end })
    ids.fg, ids.pg = K.api.foreground(), K.api.getpgid()
    ids.set = K.api.setForeground(ids.a)
    noter("lead")()
end })
drain()
local a, b, c = K.procs[ids.a], K.procs[ids.b], K.procs[ids.c]
check("a session: its leader in front of its terminal at first; children on it, in its session, in its group unless given one",
    ids.fg == L and ids.pg == L and ids.set and a.sid == L and a.ppid == L and a.tty == "pts/7" and a.pgid == ids.a
        and b.pgid == ids.a and c.pgid == L and K.ttys["pts/7"].fg == ids.a)
local function noBefore() for i = #events, 1, -1 do if events[i][1] ~= "timer" then table.remove(events, i) end end end
noBefore()
seen = {}
K.input("pts/7", "char", "x")
check("typed there: the group in front alone gets it", saw() == "a:char:x b:char:x", saw())
seen = {}
K.input("pts/7", "key", KEYS.leftCtrl)
K.input("pts/7", "key", KEYS.z)
K.input("pts/7", "key_up", KEYS.leftCtrl)
local stops = {}
for _, e in ipairs(events) do if e[1] == "proc_stop" then stops[#stops + 1] = e[2] end end
check("Ctrl+Z: the group in front stops (proc_stop each), the Z not passed on",
    a.stopped and b.stopped and not c.stopped and saw() == "a:key:29 b:key:29" and #stops == 2 and stops[1] == ids.a,
    saw())
local row
for _, r in ipairs(K.ps()) do if r.pid == ids.a then row = r end end
check("ps: stopped (T), in front (fg)", row.state == "T" and row.fg == true and row.pgid == ids.a)
seen = {}
fakeOs.queueEvent("tick", 2)
drain()
check("stopped: it misses nothing, it's kept", saw("a:") == "" and saw("c:"):find("c:tick:2", 1, true) ~= nil
    and #a.held > 0, saw())
seen = {}
check("kill -pgid CONT: carried on, what it missed first and in order",
    K.kill(-ids.a, "CONT") and not a.stopped and not b.stopped
        and saw("a:"):find("^a:key_up:29 a:proc_stop:" .. ids.a .. " a:proc_stop:" .. ids.b .. " a:tick:2") ~= nil,
    saw("a:"))
local conts = 0
for _, e in ipairs(events) do if e[1] == "proc_cont" then conts = conts + 1 end end
check("... and proc_cont each", conts == 2)
drain()
local ok9, why9 = K.kill(-4242, "TERM")
check("a group with no one in it", not ok9 and why9 == "no such process group")

K.ttys["pts/7"].fg = L
seen = {}
K.input("pts/7", "key", KEYS.leftCtrl)
K.input("pts/7", "key", KEYS.z)
K.input("pts/7", "key_up", KEYS.leftCtrl)
check("Ctrl+Z with the leader's own group in front: nothing stops, the keys go on to it",
    not K.procs[L].stopped and not c.stopped and saw("lead:") == "lead:key:29 lead:key:44 lead:key_up:29", saw())
K.ttys["pts/7"].fg = ids.q
seen = {}
K.input("pts/7", "key", KEYS.leftCtrl)
K.input("pts/7", "key", KEYS.z)
K.input("pts/7", "key_up", KEYS.leftCtrl)
check("... with a group that ignores TSTP in front, the same", not K.procs[ids.q].stopped and saw("q:"):find("q:key:44", 1, true),
    saw())
K.kill(ids.q, "STOP")
check("STOP is never ignored", K.procs[ids.q].stopped)
K.kill(ids.q, "CONT")
seen = {}
K.input("pts/7", "terminate")
check("Ctrl+T: the group in front alone", saw() == "q:terminate" and K.procs[ids.q] == nil, saw())
check("an end's status, and that Ctrl+T reached it", K.exited[ids.q].terminated == true and K.exited[ids.q].status == 0)
local last = events[#events]
check("proc_exit: the ID, ok, the status, whether Ctrl+T reached it",
    last[1] == "proc_exit" and last[2] == ids.q and last[3] == "ok" and last[4] == 0 and last[5] == true)
drain()
seen = {}
K.input("pts/7", "char", "y")
check("no one left in the group in front: the leader gets what's typed", saw() == "lead:char:y", saw())

local three = K.spawn({ name = "three", fn = function() return 3 end })
check("a function's number is its status", K.exited[three].status == 3 and K.exited[three].ok)

-- the leader gone: its terminal hangs up
seen = {}
K.kill(L, "KILL")
drain()
check("the leader gone: the terminal with it, and what's left of the session gets HUP (Ctrl+T)",
    K.ttys["pts/7"] == nil and K.procs[ids.a] == nil and K.procs[ids.b] == nil and K.procs[ids.c] == nil
        and saw():find("a:terminate", 1, true) and K.exited[ids.c].terminated, saw())

-- orphans: a process with no terminal ends, its child carries on under init
local orphan
local mid = K.spawn({ name = "mid", fn = function()
    orphan = K.spawn({ name = "orphan", fn = function() fakeOs.pullEvent("never") end })
    fakeOs.pullEvent("never")
end })
drain()
K.kill(mid, "KILL")
drain()
check("orphans go to init (no terminal: no hangup)", K.procs[orphan] and K.procs[orphan].ppid == 1)
K.kill(orphan, "KILL")

-- enter and leave, around each turn
local inside, turns = {}, { enter = 0, leave = 0 }
local FLAG = nil
local hooked = K.spawn({ name = "hooked",
    enter = function(p) turns.enter = turns.enter + 1; FLAG = "on"; return "saved" end,
    leave = function(p, o) turns.leave = turns.leave + 1; FLAG = nil; inside.saved = o end,
    fn = function()
        inside[1] = FLAG
        fakeOs.pullEvent("go3")
        inside[2] = FLAG
    end })
fakeOs.queueEvent("go3")
drain()
check("enter and leave around each of its turns, what enter returned handed to leave",
    turns.enter == 2 and turns.leave == 2 and inside[1] == "on" and inside[2] == "on" and inside.saved == "saved"
        and FLAG == nil and K.procs[hooked] == nil)

-- capture passed on to a child on the service's terminal only
local kids = {}
K.spawn({ name = "svc", service = "svc", capture = true, fn = function()
    kids.same = K.spawn({ name = "same", fn = function() fakeOs.pullEvent("never") end })
    kids.own = K.spawn({ name = "own", term = K.newTerm(), fn = function() fakeOs.pullEvent("never") end })
    kids.tty = K.spawn({ name = "tty", tty = "pts/8", fn = function() fakeOs.pullEvent("never") end })
    fakeOs.pullEvent("never")
end })
drain()
check("capture: a service's child on its terminal is captured; one with a terminal or a session of its own isn't",
    K.procs[kids.same].capture == true and K.procs[kids.own].capture == nil and K.procs[kids.tty].capture == nil
        and K.procs[kids.tty].sid == kids.tty and K.ttys["pts/8"].fg == kids.tty)

-- a service started from a process on a terminal (`service start` typed
-- at the console): a session of its own with no terminal, the console's
-- keyboard still the console's
STORE["service.det.cmd"] = "det"
COMMANDS.det = function() fakeOs.pullEvent("never") end
seen = {}
local typer = K.spawn({ name = "typer", tty = "pts/9", fn = function()
    K.serviceStart("det")
    noter("typer")()
end })
drain()
local det = K.procs[K.services.det.pid]
K.input("pts/9", "char", "k")
check("a service started from a terminal: no terminal of its own, and that terminal still its session's",
    det.tty == "?" and det.sid == det.pid and K.ttys["pts/9"].sid == typer and K.ttys["pts/9"].fg == typer
        and saw() == "typer:char:k", det.tty .. " " .. saw())
local intruder = K.spawn({ name = "intruder", tty = "pts/9", session = true, fn = function() fakeOs.pullEvent("never") end })
check("a new session on a terminal a live session holds doesn't take it", K.ttys["pts/9"].sid == typer
    and K.procs[intruder].sid == intruder)
