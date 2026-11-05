-- proc.lua -- processes for CraftOS: what init runs
--
--   local K = require("proc").new({ native = term.current(), shell = shell })
--   K.spawn({ cmd = "telnetd", service = "telnetd" })
--   K.run()                                -- for ever
--
-- CraftOS has no processes: a program is a coroutine its shell resumes,
-- and only multishell (advanced computers) runs more than one.  This is a
-- small kernel in the same spirit, for every computer and turtle: a table
-- of processes, each a coroutine with a process ID, its own terminal (a
-- window: the console's, or a hidden one) and its own environment
-- (os.getenv), resumed with the events it waits for.  Every event but
-- the keyboard's and the mouse's (timers, modems, redstone...) goes to
-- every process; those go to a terminal's foreground process group
-- (below).  A command runs in a CraftOS shell of its own
-- (rom/programs/shell.lua under the shell init was started from), so it
-- has the path, aliases and directory as usual.
--
-- Sessions and process groups, as Unix has them.  A process spawned by
-- init, or with a terminal (tty: "con", "pts/1") its parent isn't on,
-- leads a session of its own, and is in front of that terminal: what's
-- typed there (the console's keyboard, proc.input from telnetd) goes to
-- the terminal's foreground group.  A child is in its parent's group and
-- session, on its terminal, unless spawned with pgid (true: a group of
-- its own; a number: that group).  A shell puts a job's group in front
-- with proc.setForeground, and takes the terminal back after.  Ctrl+Z on
-- a terminal stops its foreground group (TSTP), except a process that
-- ignores TSTP (proc.ignore) or one in the session leader's own group;
-- with no live process in the foreground group, what's typed goes to the
-- session leader.  A stopped process keeps its events (up to 256) for
-- when it's continued (CONT).  Stopping, continuing and ending are
-- proc_stop, proc_cont and proc_exit events (proc_exit: pid, "ok" or the
-- error, the status, whether Ctrl+T reached it).  When a session leader
-- ends, its terminal hangs up: what's left of the session gets HUP.  A
-- process's children go to init (process 1) when it ends.
--
-- Services are commands kept running: settings service.<name>.cmd (the
-- command line), service.<name>.enabled (started at boot) and
-- service.<name>.restart ("always", the default, or "no").  One that ends
-- is started again after 1 s, 2 s, 4 s... (up to a minute; back to 1 s
-- once it has run 30 s).
--
-- The system log (`help syslog`): proc.log(rec) takes a message (lib/log's
-- record) for syslogd, the process that has called proc.register("syslog").
-- It's handed over in memory (the inbox, not CC's event queue) as a
-- "syslog" event; while no syslogd runs, the last 200 wait here, and past
-- 500 events waiting in the inbox new ones are dropped (and counted).
-- K.capture(_G) (init does it) logs what each service prints, as journald
-- takes a unit's output: print, write and io.write at info, printError
-- and io.stderr at err, a line each, under the service's name (facility
-- daemon); a line starting "<N>" (0-7) is logged at severity N.  Not the
-- console's processes, syslogd itself, or a
-- service with service.<name>.log false.  A service's children on its
-- terminal are captured as it is (under their own names).  Init logs
-- services starting, ending and failing too.
--
-- Programs reach it through _G.proc (init sets it): proc.spawn, kill
-- (a negative ID: that process group), list, self, console, term,
-- inject, input, getpgid, foreground, setForeground, ignore, signal,
-- wait, log, register, uncaptured (fn(...) with capture off), and the
-- service functions.
-- The module's P.serviceDef, serviceNames and serviceStatus read the
-- settings' services without init (service.lua).

local P = {}

local USER = { char = true, key = true, key_up = true, paste = true, terminate = true,
    mouse_click = true, mouse_up = true, mouse_scroll = true, mouse_drag = true }
P.USER = USER
P.SIGNALS = { HUP = 1, INT = 2, KILL = 9, TERM = 15, CONT = 18, STOP = 19, TSTP = 20 }

-- A signal as its name: "TERM", "SIGTERM", "term", "15" and 15 are all
-- "TERM"; 0 and "0" are 0; nil for one that isn't known.
function P.signal(s)
    s = tostring(s):upper():gsub("^SIG", "")
    if s == "0" then return 0 end
    if P.SIGNALS[s] then return s end
    for name, n in pairs(P.SIGNALS) do if tostring(n) == s then return name end end
end

local function copy(t)
    local c = {}
    for k, v in pairs(t) do c[k] = v end
    return c
end

-- os.getenv, os.setenv and os.environ over the table env.
local function envApi(env)
    return {
        getenv = function(name)
            if type(name) ~= "string" then error("bad argument #1 (string expected, got " .. type(name) .. ")", 2) end
            return env[name]
        end,
        setenv = function(name, value)
            if type(name) ~= "string" or not name:match("^[^=]+$") then error("bad argument #1 (a name expected)", 2) end
            env[name] = value ~= nil and tostring(value) or nil
        end,
        environ = function() return copy(env) end,
    }
end

-- Service `name` as the settings (settingsT) define it: { cmd, restart,
-- enabled }, or nil without a service.<name>.cmd.
function P.serviceDef(name, settingsT)
    settingsT = settingsT or settings
    local cmd = settingsT.get("service." .. name .. ".cmd")
    if type(cmd) ~= "string" or cmd == "" then return nil end
    return { cmd = cmd, restart = settingsT.get("service." .. name .. ".restart") or "always",
             enabled = settingsT.get("service." .. name .. ".enabled") == true }
end

-- The services defined in the settings, and those in `known` (a kernel's
-- K.services), sorted.
function P.serviceNames(settingsT, known)
    settingsT = settingsT or settings
    local names, seen = {}, {}
    for _, key in ipairs(settingsT.getNames()) do
        local n = key:match("^service%.(.+)%.cmd$")
        if n and not seen[n] then seen[n] = true; names[#names + 1] = n end
    end
    for n in pairs(known or {}) do
        if not seen[n] then seen[n] = true; names[#names + 1] = n end
    end
    table.sort(names)
    return names
end

-- { name, state ("running", "restarting", "stopped", "exited", or
-- "-" never started), pid, enabled, cmd, restarts, since, last, lines
-- (what it last showed) } for each service: kernel K's, or the settings'
-- alone without one (init isn't running).
function P.serviceStatus(settingsT, K)
    local out = {}
    for _, name in ipairs(P.serviceNames(settingsT, K and K.services)) do
        local svc, d = K and K.services[name] or {}, P.serviceDef(name, settingsT)
        local lines = {}
        if svc.term and svc.term.getLine then
            local _, h = svc.term.getSize()
            for y = 1, h do
                local l = svc.term.getLine(y):gsub("%s+$", "")
                if l ~= "" then lines[#lines + 1] = l end
            end
        end
        out[#out + 1] = { name = name, state = svc.state or "-", pid = svc.pid, enabled = d and d.enabled or false,
                          cmd = d and d.cmd, restarts = svc.restarts or 0, since = svc.since, last = svc.last,
                          lines = lines }
    end
    return out
end

-- o: native (the terminal under everything), shell (the shell to run
-- commands under), multishell, settings, window (the window API), osT
-- (os: pullEventRaw, queueEvent, startTimer, run, epoch), env (the first
-- processes' environment), keys (for Ctrl+Z).
function P.new(o)
    local osT = o.osT or os
    local settingsT = o.settings or settings
    local windowT = o.window or window
    local native = o.native or term.current()
    local termT = o.term or term
    local SHELL = o.shellProgram or "rom/programs/shell.lua"
    local keysT = o.keys or rawget(_G, "keys")
    local function now() return osT.epoch("utc") end

    local K = {
        procs = {},             -- pid -> process
        list = {},              -- the processes, oldest first
        exited = {},            -- pid -> { ok, err, name }: the last few that ended
        services = {},          -- name -> { state, pid, restarts, fails, since, last, term }
        timers = {},            -- timer id -> function
        inbox = {},             -- events for one process, { pid, ev }, or typed at a terminal, { tty, ev }
        ttys = {},              -- terminal -> { sid (its session's leader), fg (the group in front), ctrl }
        nextPid = 2, console = nil, current = nil, started = now(), cpu = 0,
        env = o.env and copy(o.env) or {},
        syslog = nil,           -- syslogd's process ID
        held = {},              -- messages waiting for it
        logDropped = 0,         -- messages dropped since the last one handed over
    }
    local hostname = o.hostname or function()
        local label = osT.getComputerLabel and osT.getComputerLabel()
        if label and label ~= "" then return label end
        return tostring(osT.getComputerID and osT.getComputerID() or 0)
    end

    --------------------------------------------------------------------
    -- Terminals
    --------------------------------------------------------------------
    -- A terminal that draws nowhere, w x h, colour or not: the parent of a
    -- hidden window.
    local function nullTerm(w, h, colour)
        local t = {}
        for k, v in pairs(native) do
            if type(v) == "function" then t[k] = function() end end
        end
        t.isColour = function() return colour end
        t.getSize = function() return w, h end
        t.getCursorPos = function() return 1, 1 end
        t.getPaletteColour = function(c) return native.getPaletteColour(c) end
        t.getTextColour = function() return 1 end
        t.getBackgroundColour = function() return 32768 end
        t.isColor, t.getPaletteColor = t.isColour, t.getPaletteColour
        t.getTextColor, t.getBackgroundColor = t.getTextColour, t.getBackgroundColour
        return t
    end

    -- A hidden window (w x h; default the screen's size), for a process
    -- with no screen; what it draws can be read back (getLine).
    function K.newTerm(w, h, colour)
        local nw, nh = native.getSize()
        if colour == nil then colour = native.isColour() end
        return windowT.create(nullTerm(w or nw, h or nh, colour), 1, 1, w or nw, h or nh, false)
    end

    --------------------------------------------------------------------
    -- Running a process
    --------------------------------------------------------------------
    local reap

    -- Resume p with the event ...: its terminal and environment in place
    -- while it runs.
    local function resume(p, ...)
        local was = K.current
        K.current = p
        local api = p.envApi
        local saved = { rawget(osT, "getenv"), rawget(osT, "setenv"), rawget(osT, "environ") }
        osT.getenv, osT.setenv, osT.environ = api.getenv, api.setenv, api.environ
        local prevTerm = termT.redirect(p.term)
        local ctx = p.enter and p.enter(p)
        local t0 = now()
        local r = table.pack(coroutine.resume(p.co, ...))
        p.cpu = p.cpu + (now() - t0)
        if p.leave then p.leave(p, ctx) end
        p.term = termT.current()
        termT.redirect(prevTerm)
        osT.getenv, osT.setenv, osT.environ = saved[1], saved[2], saved[3]
        K.current = was
        if coroutine.status(p.co) == "dead" then
            reap(p, r[1], r[2])
        elseif p.killed then
            reap(p, false, "killed")
        else
            p.state, p.filter = "wait", r[2]
        end
    end

    local function start(p)
        if p.state == "new" and not p.stopped then resume(p) end
    end

    local function deliver(p, ev)
        if p.stopped then
            if #p.held < 256 then p.held[#p.held + 1] = ev end
            return
        end
        if p.state == "new" then start(p) end
        if p.state == "wait" and (p.filter == nil or p.filter == ev[1] or ev[1] == "terminate") then
            if ev[1] == "terminate" then p.terminated = true end
            resume(p, table.unpack(ev, 1, ev.n))
        end
    end

    local signalGroup

    -- What's typed at terminal t: to its foreground group (Ctrl+Z stops
    -- that), or to the session leader if no one's left in the group.
    local function input(t, ev)
        local tt = K.ttys[t]
        if not tt then                          -- (no session there: the console's process, if any)
            local p = t == "con" and K.console and K.procs[K.console]
            if p then deliver(p, ev) end
            return
        end
        if keysT and (ev[1] == "key" or ev[1] == "key_up") and (ev[2] == keysT.leftCtrl or ev[2] == keysT.rightCtrl) then
            tt.ctrl = ev[1] == "key"
        elseif keysT and tt.ctrl and ev[1] == "key" and ev[2] == keysT.z and signalGroup(tt.fg, "TSTP", true) > 0 then
            return
        end
        local any = false
        for _, p in ipairs(copy(K.list)) do
            if K.procs[p.pid] and p.pgid == tt.fg and p.tty == t then any = true; deliver(p, ev) end
        end
        local leader = not any and K.procs[tt.sid]
        if leader then deliver(leader, ev) end
    end

    -- Start what was spawned and hand on what was injected, until done.
    local function flush()
        for _ = 1, 1000 do
            local busy = false
            for _, p in ipairs(copy(K.list)) do
                if p.state == "new" then start(p); busy = true end
            end
            while K.inbox[1] do
                local m = table.remove(K.inbox, 1)
                if m.tty then
                    input(m.tty, m.ev)
                else
                    local p = K.procs[m.pid]
                    if p then deliver(p, m.ev) end
                end
                busy = true
            end
            if not busy then return end
        end
    end

    -- Every event: the keyboard's and the mouse's to the console's
    -- foreground group, the rest to everyone.
    function K.dispatch(ev)
        if ev[1] == "timer" and K.timers[ev[2]] then
            local fn = K.timers[ev[2]]
            K.timers[ev[2]] = nil
            fn()
        elseif USER[ev[1]] then
            input("con", ev)
        else
            for _, p in ipairs(copy(K.list)) do
                if K.procs[p.pid] then deliver(p, ev) end
            end
        end
        flush()
    end

    -- For ever (or until nothing is left).
    function K.run()
        flush()
        while next(K.procs) do
            local ev = table.pack(osT.pullEventRaw())
            local t0 = now()
            K.dispatch(ev)
            K.cpu = K.cpu + (now() - t0)
        end
    end

    function K.after(seconds, fn)
        K.timers[osT.startTimer(seconds)] = fn
    end

    --------------------------------------------------------------------
    -- Processes
    --------------------------------------------------------------------
    -- spec: cmd (a command line; nil: an interactive shell) or fn (a
    -- function, with args), name, term (default a hidden one), tty (its
    -- terminal: "con", "pts/1"; default the parent's, or "?" for none),
    -- session (true: a session of its own, as a process with a tty its
    -- parent isn't on, or spawned by init, always is), pgid (true: a
    -- group of its own; a number: that one; default the parent's), env
    -- (default the parent's), service, capture (default the parent's,
    -- for a child on its terminal), enter(p) and leave(p, what enter
    -- returned) (around each of its turns: ccsh puts a command's io in
    -- place so), onExit(p).  The process ID.
    function K.spawn(spec)
        local pid = K.nextPid
        K.nextPid = pid + 1
        local parent = K.current
        -- (a new session starts with no terminal unless given one, as setsid does)
        local tty = spec.tty or (not spec.session and parent and parent.tty) or "?"
        local session = spec.session or not parent or tty ~= parent.tty
        local capture = spec.capture
        if capture == nil and not session and (spec.term == nil or spec.term == parent.term) then
            capture = parent.capture
        end
        local env = copy(spec.env or (parent and parent.env) or K.env)
        local co
        if spec.fn then
            local args = spec.args or {}
            co = coroutine.create(function() return spec.fn(table.unpack(args)) end)
        else
            local shellEnv = { shell = o.shell, multishell = o.multishell }
            co = coroutine.create(function()
                if spec.cmd then return osT.run(shellEnv, SHELL, spec.cmd) end
                return osT.run(shellEnv, SHELL)
            end)
        end
        local p = {
            pid = pid, ppid = parent and parent.pid or 1, co = co, state = "new",
            name = spec.name or (spec.cmd and spec.cmd:match("^%S+"):match("([^/]*)$")) or "shell",
            cmd = spec.cmd or spec.name or "shell",
            term = spec.term or K.newTerm(), tty = tty, env = env, envApi = envApi(env),
            started = now(), cpu = 0, service = spec.service, onExit = spec.onExit,
            capture = capture, enter = spec.enter, leave = spec.leave,
            sid = session and pid or parent.sid,
            pgid = (session or spec.pgid == true) and pid or tonumber(spec.pgid) or parent.pgid,
        }
        if p.name:sub(-4) == ".lua" then p.name = p.name:sub(1, -5) end
        local held = K.ttys[tty]
        if session and tty ~= "?" and not (held and K.procs[held.sid]) then   -- (one a live session holds stays its)
            K.ttys[tty] = { sid = pid, fg = pid }
        end
        K.procs[pid] = p
        K.list[#K.list + 1] = p
        if not K.current then flush() end           -- (else after the one running now: see dispatch)
        return pid
    end

    local signalOne

    reap = function(p, ok, err)
        if not K.procs[p.pid] then return end
        local value = ok and err                -- (what it returned: a number is its status)
        p.status = type(value) == "number" and value or (ok and value ~= false) and 0 or 1
        p.state, p.ok, p.err = "dead", ok, (not ok) and tostring(err) or nil
        K.procs[p.pid] = nil
        for i, q in ipairs(K.list) do
            if q == p then table.remove(K.list, i); break end
        end
        if p.logbuf and p.logbuf ~= "" then K.logLine(p, p.logbuf); p.logbuf = "" end
        if K.syslog == p.pid then K.syslog = nil end
        K.exited[p.pid] = { ok = ok, err = p.err, name = p.name, at = now(), status = p.status,
                            terminated = p.terminated == true }
        local n = 0
        for pid in pairs(K.exited) do
            n = n + 1
            if n > 32 then K.exited[pid] = nil end
        end
        for _, q in ipairs(K.list) do
            if q.ppid == p.pid then q.ppid = 1 end              -- (orphans go to init)
        end
        local tt = K.ttys[p.tty]
        if tt and tt.sid == p.pid then                          -- a session leader: its terminal hangs up
            K.ttys[p.tty] = nil
            for _, q in ipairs(copy(K.list)) do
                if q.sid == p.pid then signalOne(q, "HUP"); signalOne(q, "CONT") end
            end
        end
        osT.queueEvent("proc_exit", p.pid, ok and "ok" or p.err, p.status, p.terminated == true)
        if p.onExit then p.onExit(p) end
    end

    local function stop(p)
        if p.stopped then return end
        p.stopped, p.held = true, {}
        osT.queueEvent("proc_stop", p.pid)
    end

    -- (what it missed goes first, in order)
    local function cont(p)
        if not p.stopped then return end
        p.stopped = false
        for i, ev in ipairs(p.held) do table.insert(K.inbox, i, { pid = p.pid, ev = ev }) end
        p.held = nil
        osT.queueEvent("proc_cont", p.pid)
    end

    -- Signal `name` to p.  fromTty: Ctrl+Z's TSTP, which doesn't stop a
    -- process that ignores it, nor one in its session leader's group.
    -- false if it did nothing.
    signalOne = function(p, name, fromTty)
        if name == "KILL" then
            if p == K.current then p.killed = true else reap(p, false, "killed") end
        elseif name == "TERM" or name == "INT" or name == "HUP" then
            K.inbox[#K.inbox + 1] = { pid = p.pid, ev = table.pack("terminate") }
        elseif name == "STOP" or name == "TSTP" then
            if name == "TSTP" and ((p.ignore and p.ignore.TSTP) or (fromTty and p.pgid == p.sid)) then return false end
            stop(p)
        elseif name == "CONT" then
            cont(p)
        end
        return true
    end

    -- Signal every process in group pgid; how many it reached.
    signalGroup = function(pgid, name, fromTty)
        local n = 0
        for _, p in ipairs(copy(K.list)) do
            if p.pgid == pgid and K.procs[p.pid] and signalOne(p, name, fromTty) then n = n + 1 end
        end
        return n
    end

    -- Send a signal to process pid, or to every process in group -pid:
    -- TERM, INT and HUP are Ctrl+T (a terminate event); KILL drops it at
    -- once; STOP and TSTP stop it, CONT carries it on; 0 only asks
    -- whether it's there.  sig is a name or a number, as P.signal takes
    -- them; TERM when nil.
    function K.kill(pid, sig)
        local name = P.signal(sig or "TERM")
        pid = tonumber(pid)
        if pid == 1 then return false, "init can't be signalled" end
        local targets = {}
        if pid and pid < 0 then
            for _, p in ipairs(K.list) do if p.pgid == -pid then targets[#targets + 1] = p end end
            if #targets == 0 then return false, "no such process group" end
        else
            targets[1] = pid and K.procs[pid]
            if not targets[1] then return false, "no such process" end
        end
        if not name then return false, "unknown signal " .. tostring(sig) end
        if name == 0 then return true end
        for _, p in ipairs(targets) do
            if K.procs[p.pid] then signalOne(p, name) end
        end
        if not K.current then flush() end
        return true
    end

    -- Hand the event ... to process pid alone.
    function K.inject(pid, ...)
        if not K.procs[pid] then return false end
        K.inbox[#K.inbox + 1] = { pid = pid, ev = table.pack(...) }
        if not K.current then flush() end
        return true
    end

    -- The event ... typed at terminal tty: for its foreground group.
    function K.input(tty, ...)
        K.inbox[#K.inbox + 1] = { tty = tty, ev = table.pack(...) }
        if not K.current then flush() end
        return true
    end

    --------------------------------------------------------------------
    -- The system log
    --------------------------------------------------------------------
    local HOLD, BACKLOG, LINE = 200, 500, 1024

    -- Hand a message (lib/log's record; time and host filled in if not
    -- there) to syslogd, or keep it until one runs.  false if dropped.
    function K.log(rec)
        rec.time = rec.time or now()
        rec.host = rec.host or hostname()
        local pid = K.syslog
        if not (pid and K.procs[pid]) then
            K.held[#K.held + 1] = rec
            if #K.held > HOLD then table.remove(K.held, 1); K.logDropped = K.logDropped + 1 end
            return true
        end
        if #K.inbox >= BACKLOG then K.logDropped = K.logDropped + 1; return false end
        if K.logDropped > 0 then
            local n = K.logDropped
            K.logDropped = 0
            K.inbox[#K.inbox + 1] = { pid = pid, ev = table.pack("syslog", { fac = 5, sev = 4, time = rec.time,
                host = rec.host, app = "init", pid = 1, msg = n .. " message" .. (n == 1 and "" or "s") .. " dropped" }) }
        end
        K.inbox[#K.inbox + 1] = { pid = pid, ev = table.pack("syslog", rec) }
        -- (handed on when the running process yields; from init's own
        -- loop, say lib/net's hook, an event wakes it)
        if not K.current then osT.queueEvent("syslog_wake") end
        return true
    end

    -- init's own message about the services (facility daemon).
    local function say(sev, msg)
        K.log({ fac = 3, sev = sev, app = "init", pid = 1, msg = msg })
    end
    K.say = say

    -- The calling process is syslogd, for name "syslog": what waited is
    -- handed to it.  false and why if another one is running.
    function K.register(name)
        if name ~= "syslog" then return false, "nothing registers as " .. tostring(name) end
        local p = K.current
        if not p then return false, "not a process" end
        if K.syslog and K.syslog ~= p.pid and K.procs[K.syslog] then
            return false, "syslogd is running already (process " .. K.syslog .. ")"
        end
        K.syslog, p.capture = p.pid, false
        local held = K.held
        K.held = {}
        for _, rec in ipairs(held) do K.log(rec) end
        return true
    end

    -- A line process p printed, to the log.
    function K.logLine(p, line)
        local err = p.logerr
        p.logerr = nil
        line = line:gsub("%s+$", "")
        if not line:find("%S") then return end
        local sev = err and 3 or 6
        local n, rest = line:match("^<([0-7])>(.*)$")
        if n then sev, line = tonumber(n), rest end
        K.log({ fac = 3, sev = sev, app = p.service or p.name, pid = p.pid, msg = line })
    end

    local function capturing()
        local p = K.current
        if p and p.capture and (p.quiet or 0) == 0 and p.pid ~= K.syslog then return p end
    end

    local function gather(p, s)
        if (p.stderr or 0) > 0 then p.logerr = true end
        local buf = (p.logbuf or "") .. tostring(s)
        while true do
            local line, rest = buf:match("^([^\n]*)\n(.*)$")
            if not line then break end
            buf = rest
            K.logLine(p, line)
            if (p.stderr or 0) > 0 and buf ~= "" then p.logerr = true end
        end
        if #buf >= LINE then K.logLine(p, buf); buf = "" end
        p.logbuf = buf
    end

    -- fn(...) with the calling process's output not captured (lib/log's
    -- own copy on the screen).
    function K.uncaptured(fn, ...)
        local p = K.current
        if p then p.quiet = (p.quiet or 0) + 1 end
        local r = table.pack(pcall(fn, ...))
        if p then p.quiet = p.quiet - 1 end
        if not r[1] then error(r[2], 0) end
        return table.unpack(r, 2, r.n)
    end

    -- Capture what services print: G's write and printError, and its io's
    -- stdout and stderr, wrapped.  Returns a function that undoes it.
    function K.capture(G)
        local rawWrite, rawPrintError = G.write, G.printError
        local undo = {}
        G.write = function(s)
            local n = rawWrite(s)
            local p = capturing()
            if p then gather(p, s) end
            return n
        end
        local function asError(fn)
            return function(...)
                local p = K.current
                if p then p.stderr = (p.stderr or 0) + 1 end
                local r = table.pack(pcall(fn, ...))
                if p then p.stderr = p.stderr - 1 end
                if not r[1] then error(r[2], 0) end
                return table.unpack(r, 2, r.n)
            end
        end
        G.printError = asError(rawPrintError)
        undo[#undo + 1] = function() G.write, G.printError = rawWrite, rawPrintError end
        -- CraftOS's io.stdout keeps the write it was made with, not
        -- _G.write's later self; io.stderr calls _G.write each time
        local io_ = G.io
        local out = io_ and type(io_.stdout) == "table" and rawget(io_.stdout, "_handle")
        if type(out) == "table" and out.write == rawWrite then
            out.write = function(s)
                local n = rawWrite(s)
                local p = capturing()
                if p then gather(p, s) end
                return n
            end
            undo[#undo + 1] = function() out.write = rawWrite end
        end
        local errH = io_ and type(io_.stderr) == "table" and rawget(io_.stderr, "_handle")
        if type(errH) == "table" and type(errH.write) == "function" then
            local w = errH.write
            errH.write = asError(w)
            undo[#undo + 1] = function() errH.write = w end
        end
        return function() for i = #undo, 1, -1 do undo[i]() end end
    end

    local function info(p)
        local tt = K.ttys[p.tty]
        return { pid = p.pid, ppid = p.ppid, pgid = p.pgid, sid = p.sid, name = p.name, cmd = p.cmd, tty = p.tty,
                 service = p.service,
                 state = p == K.current and "R" or p.stopped and "T" or p.state == "new" and "N" or "S",
                 fg = tt ~= nil and tt.fg == p.pgid, cpu = p.cpu / 1000, started = p.started,
                 console = p.pid == K.console }
    end

    -- Every process (init first), as ps shows them.
    function K.ps()
        local out = { { pid = 1, ppid = 0, pgid = 1, sid = 1, name = "init", cmd = "init", tty = "?", state = "S",
                        cpu = K.cpu / 1000, started = K.started } }
        for _, p in ipairs(K.list) do out[#out + 1] = info(p) end
        return out
    end

    --------------------------------------------------------------------
    -- Services
    --------------------------------------------------------------------
    local function def(name) return P.serviceDef(name, settingsT) end
    K.serviceDef = def
    function K.serviceNames() return P.serviceNames(settingsT, K.services) end

    local launch

    local function exited(svc, p)
        svc.pid, svc.last = nil, p.ok and "ended" or ("failed: " .. tostring(p.err))
        local d = def(svc.name)
        local what = p.ok and svc.name .. " ended" or svc.name .. " failed: " .. tostring(p.err)
        if svc.stopping or not d or d.restart == "no" then
            if svc.stopping then say(6, "stopped " .. svc.name) else say(p.ok and 5 or 3, what) end
            svc.state, svc.stopping = svc.stopping and "stopped" or "exited", nil
            return
        end
        if now() - svc.since >= 30000 then svc.fails = 0 end
        svc.fails, svc.restarts = svc.fails + 1, svc.restarts + 1
        svc.state = "restarting"
        local wait = math.floor(math.min(60, 2 ^ (svc.fails - 1)))
        say(p.ok and 5 or 3, what .. "; again in " .. wait .. " s")
        K.after(wait, function()
            if svc.state == "restarting" then launch(svc) end
        end)
    end

    launch = function(svc)
        local d = def(svc.name)
        if not d then svc.state = "exited"; svc.last = "no service." .. svc.name .. ".cmd"; return end
        svc.term = K.newTerm()
        svc.state, svc.since = "running", now()
        say(6, "started " .. svc.name .. " (process " .. K.nextPid .. ")")
        svc.pid = K.spawn({ cmd = d.cmd, service = svc.name, term = svc.term, env = K.env, session = true,
            capture = settingsT.get("service." .. svc.name .. ".log") ~= false,
            onExit = function(p) exited(svc, p) end })
    end

    function K.serviceStart(name)
        local d = def(name)
        if not d then return false, "no such service (set service." .. name .. ".cmd)" end
        local svc = K.services[name]
        if svc and (svc.state == "running" or svc.state == "restarting") then
            return false, name .. " is already " .. svc.state
        end
        svc = svc or { name = name, restarts = 0, fails = 0 }
        svc.fails = 0
        K.services[name] = svc
        launch(svc)
        return true
    end

    function K.serviceStop(name)
        local svc = K.services[name]
        if not svc or (svc.state ~= "running" and svc.state ~= "restarting") then
            return false, name .. " isn't running"
        end
        if svc.state == "restarting" then svc.state = "stopped"; say(6, "stopped " .. name); return true end
        svc.stopping = true
        local pid = svc.pid
        K.kill(pid, "TERM")
        K.after(3, function()                   -- (it didn't stop for Ctrl+T)
            if K.procs[pid] then K.kill(pid, "KILL") end
        end)
        return true
    end

    function K.serviceStatus() return P.serviceStatus(settingsT, K) end

    -- Start the services enabled in the settings.
    function K.startServices()
        for _, name in ipairs(K.serviceNames()) do
            local d = def(name)
            if d and d.enabled then K.serviceStart(name) end
        end
    end

    --------------------------------------------------------------------
    -- What programs see: _G.proc
    --------------------------------------------------------------------
    K.api = {
        spawn = function(spec) return K.spawn(spec) end,
        kill = K.kill,
        inject = K.inject,
        input = K.input,
        list = K.ps,
        self = function() return K.current and K.current.pid or 1 end,
        console = function() return K.console end,
        signal = P.signal,
        -- process pid's group (the caller's, with none)
        getpgid = function(pid)
            if pid == 1 then return 1 end
            local p = pid and K.procs[pid] or (pid == nil and K.current)
            return p and p.pgid or nil
        end,
        -- the group in front of the caller's terminal (nil without one)
        foreground = function()
            local tt = K.current and K.ttys[K.current.tty]
            return tt and tt.fg
        end,
        -- put group pgid in front of the caller's terminal (in its session)
        setForeground = function(pgid)
            local p = K.current
            local tt = p and K.ttys[p.tty]
            if not tt or tt.sid ~= p.sid then return false, "no terminal" end
            tt.fg = pgid
            return true
        end,
        -- the caller ignores signal sig (TSTP: the only one that can be),
        -- or with on false, no longer does
        ignore = function(sig, on)
            local p, name = K.current, P.signal(sig)
            if not p or name ~= "TSTP" then return false end
            p.ignore = p.ignore or {}
            p.ignore[name] = on ~= false or nil
            return true
        end,
        -- process pid's terminal (a window: getLine reads it back)
        term = function(pid)
            local p = K.procs[pid]
            return p and p.term
        end,
        newTerm = K.newTerm,
        log = K.log,
        register = K.register,
        uncaptured = K.uncaptured,
        -- Wait for process pid to end: true, or false and why it failed;
        -- nil after timeout seconds.
        wait = function(pid, timeout)
            local timer = timeout and osT.startTimer(timeout)
            while K.procs[pid] do
                local ev = table.pack(osT.pullEvent())
                if ev[1] == "timer" and ev[2] == timer then return nil end
            end
            local e = K.exited[pid]
            return e and e.ok or false, e and e.err
        end,
        -- A process ID nothing will use (ccsh numbers its jobs so).
        reservePid = function()
            local pid = K.nextPid
            K.nextPid = pid + 1
            return pid
        end,
        services = K.serviceStatus,
        start = K.serviceStart,
        stop = K.serviceStop,
        restart = function(name)
            local svc = K.services[name]
            if svc and (svc.state == "running" or svc.state == "restarting") then
                local pid = svc.pid
                K.serviceStop(name)
                if not pid then return K.serviceStart(name) end
                local onExit = K.procs[pid] and K.procs[pid].onExit
                if K.procs[pid] then
                    K.procs[pid].onExit = function(p)
                        if onExit then onExit(p) end
                        K.serviceStart(name)
                    end
                end
                return true
            end
            return K.serviceStart(name)
        end,
    }
    return K
end

return P
