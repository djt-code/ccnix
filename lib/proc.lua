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
-- a terminal stops its foreground group (TSTP), and Ctrl+C ends it as
-- Ctrl+T would (INT), except a process that ignores the signal
-- (proc.ignore: a shell at its prompt, a program that wants the key) or
-- one in the session leader's own group: those get the key instead;
-- with no live process in the foreground group, what's typed goes to the
-- session leader.  A stopped process keeps its events (up to 256) for
-- when it's continued (CONT).  Stopping, continuing and ending are
-- proc_stop, proc_cont and proc_exit events (proc_exit: pid, "ok" or the
-- error, the status, whether Ctrl+T reached it).  When a session leader
-- ends, its terminal hangs up: what's left of the session gets HUP.  A
-- process's children go to init (process 1) when it ends.
--
-- The console keeps a scrollback, as a Linux virtual console does
-- (K.scrollback, which init sets up): Shift+Page Up and Down, and the
-- mouse wheel, look back through what scrolled off its top, under
-- whatever runs there, unless what's in front keeps them for itself
-- (proc.ownScrollback: the telnet client, whose scrollback is the other
-- computer's; vi and the pager, which scroll with the wheel themselves).
--
-- Services are commands kept running: settings service.<name>.cmd (the
-- command line), service.<name>.enabled (started at boot) and
-- service.<name>.restart ("always", the default, or "no").  One that ends
-- (or fails: an error, or its program exits non-zero, as a ccnix utility
-- or ccsh script says through _G.POSIX_STATUS, each process's own) is
-- started again after 1 s, 2 s, 4 s... (up to a minute; back to 1 s once
-- it has run 30 s).
--
-- A crash.  The CraftOS shell catches a program's error itself (it
-- prints it and goes on), so a command is run through lib/procrun.lua
-- (o.runner), which keeps what the shell's run said: a program that
-- failed ends with status 1 if it didn't set one of its own.  While a
-- process runs, coroutine.resume notes the last of its coroutines that
-- failed (forgotten when one of them carries on after), so when a
-- command ends failed, that's the error that ended it: the process
-- ends with it (not "ok"), and the traceback of the coroutine it
-- happened in is logged at err under its name and kept with the exit.
-- A function's process (spec.fn) fails the same way, with its own
-- coroutine's traceback.  Ctrl+T's "Terminated" isn't a crash.  The
-- last P.EXITS exits are kept (K.exited, proc.exited()), and `service
-- status` shows a service's last one.
--
-- K.onReap(fn) has fn(p) called as each process ends (before its onExit
-- and proc_exit): init lets lib/net close the sockets it had open so.
--
-- A panic (init itself failing, a bug in the kernel rather than in a
-- program): K.writePanic puts the error, the traceback, the processes
-- and the log's messages not yet filed in P.PANIC (/var/log/panic), and
-- at the next boot K.lastPanic logs it at crit and moves it to
-- /var/log/panic.1.
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
-- inject, input, getpgid, foreground, setForeground, ignore,
-- ownScrollback, signal, wait, exited (the last few to end, oldest
-- first), log, register, uncaptured (fn(...) with capture off), and the
-- service functions.
-- The module's P.serviceDef, serviceNames and serviceStatus read the
-- settings' services without init (service.lua).

local scan = require("scan")
local text = require("text")
local path = require("path")
local tables = require("tables")
local fileio = require("fileio")
local sysenv = require("sysenv")

local P = {}

local USER = { char = true, key = true, key_up = true, paste = true, terminate = true,
    mouse_click = true, mouse_up = true, mouse_scroll = true, mouse_drag = true }
P.USER = USER
P.HISTORY = 500                 -- lines of the console's scrollback (K.scrollback)
P.WHEEL = 3                     -- lines a turn of the mouse wheel scrolls it
P.SIGNALS = { HUP = 1, INT = 2, KILL = 9, TERM = 15, CONT = 18, STOP = 19, TSTP = 20 }
P.EXITS = 32                    -- processes' ends kept (K.exited)
P.TRACE = 16                    -- lines of a crash's traceback kept
P.PANIC = "/var/log/panic"      -- what init knew when it failed
P.PANIC_WINDOW = 10 * 60 * 1000 -- panics closer together than this (ms) are in a row
P.PANIC_MOST = 3                -- after this many in a row, init stops rebooting

local rawResume = coroutine.resume      -- (while a process runs, coroutine.resume is watched: see resume)

-- A signal as its name: "TERM", "SIGTERM", "term", "15" and 15 are all
-- "TERM"; 0 and "0" are 0; nil for one that isn't known.
function P.signal(s)
    s = tostring(s):upper()
    s = text.stripPrefix(s, "SIG") or s
    if s == "0" then return 0 end
    if P.SIGNALS[s] then return s end
    for name, n in pairs(P.SIGNALS) do if tostring(n) == s then return name end end
end

-- ps's columns: heading, width, on the right (numbers), and the field
-- of a process (a row of proc.list()) as text.  long: ps -l's alone;
-- start: only where START is shown (not in a panic's report).
local PS_COLUMNS = {
    { head = "PID", width = 5, right = true, field = function(p) return p.pid end },
    { head = "PPID", width = 5, right = true, long = true, field = function(p) return p.ppid end },
    { head = "PGID", width = 5, right = true, long = true, field = function(p) return p.pgid or p.pid end },
    { head = "TTY", width = 6, field = function(p) return p.tty end },
    -- the state, + in its terminal's foreground group
    { head = "STAT", width = 4, field = function(p) return tostring(p.state) .. (p.fg and "+" or "") end },
    { head = "TIME", width = 6, right = true, field = function(p) return string.format("%.1f", tonumber(p.cpu) or 0) end },
    { head = "START", width = 0, long = true, start = true,
      field = function(p) return os.date("%H:%M", math.floor((tonumber(p.started) or 0) / 1000)) end },
    -- a service by its name
    { head = "CMD", width = 0, field = function(p) return p.service and p.name or p.cmd end },
}

local function psCells(long, start, cellOf)
    local cells = {}
    for _, c in ipairs(PS_COLUMNS) do
        if (long or not c.long) and (start or not c.start) then
            local s = tostring(cellOf(c))
            cells[#cells + 1] = c.right and text.padLeft(s, c.width) or text.padRight(s, c.width)
        end
    end
    return table.concat(cells, " ")
end

-- ps's heading: PID TTY STAT TIME CMD; with long PPID and PGID after
-- the PID too, and START (when it started, by the computer's clock)
-- before CMD unless start is false.
function P.psHeader(long, start)
    return psCells(long, long and start ~= false, function(c) return c.head end)
end

-- Process p (a row of proc.list()) as a line under P.psHeader(long,
-- start).  Each field goes through tostring, so a damaged row (in a
-- panic's report) still makes a line.
function P.psLine(p, long, start)
    return psCells(long, long and start ~= false, function(c) return c.field(p) end)
end

-- A command line's program name: its first word's last name
local function programName(cmd)
    return path.basename(text.words(cmd)[1] or "")
end

-- An error as its message and the coroutine it happened in: CC:T's
-- exceptions (a table with a message and a thread, as parallel throws
-- them) carry both; anything else is the message, in coroutine co.
local function errorOf(e, co)
    if type(e) == "table" and type(rawget(e, "message")) == "string" and type(rawget(e, "thread")) == "thread" then
        return rawget(e, "message"), rawget(e, "thread")
    end
    return tostring(e), co
end

-- The traceback of coroutine co, which failed with msg: its lines after
-- the message, tabs as two spaces, at most P.TRACE of them.
local function traceOf(co, msg)
    local ok, trace = pcall(debug.traceback, co, msg)
    if not ok or type(trace) ~= "string" then return {} end
    local after = text.stripPrefix(trace, msg)
    if after then trace = after:sub(2) end                      -- (the message, and its newline)
    local out = {}
    for _, line in ipairs(text.lines(trace)) do
        if #out == P.TRACE then out[#out + 1] = "  ..."; break end
        out[#out + 1] = (text.replace(line, "\t", "  "))
    end
    return out
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
    local seen = {}
    for _, key in ipairs(settingsT.getNames()) do
        -- service.<name>.cmd, the name not empty
        local inner = text.stripPrefix(key, "service.")
        local n = inner and text.stripSuffix(inner, ".cmd")
        if n and n ~= "" then seen[n] = true end
    end
    for n in pairs(known or {}) do seen[n] = true end
    return tables.sortedKeys(seen)
end

-- { name, state ("running", "restarting", "stopped", "exited", or
-- "-" never started), pid, enabled, cmd, restarts, since, last, exit
-- (how it last ended: K.exited's entry), lines (what it last showed) }
-- for each service: kernel K's, or the settings' alone without one
-- (init isn't running).
function P.serviceStatus(settingsT, K)
    local out = {}
    for _, name in ipairs(P.serviceNames(settingsT, K and K.services)) do
        local svc, d = K and K.services[name] or {}, P.serviceDef(name, settingsT)
        local lines = {}
        if svc.term and svc.term.getLine then
            local _, h = svc.term.getSize()
            for y = 1, h do
                local l = text.trimEnd((svc.term.getLine(y)))
                if l ~= "" then lines[#lines + 1] = l end
            end
        end
        out[#out + 1] = { name = name, state = svc.state or "-", pid = svc.pid, enabled = d and d.enabled or false,
                          cmd = d and d.cmd, restarts = svc.restarts or 0, since = svc.since, last = svc.last,
                          exit = svc.exit, lines = lines }
    end
    return out
end

-- o: native (the terminal under everything), shell (the shell to run
-- commands under), multishell, settings, window (the window API), osT
-- (os: pullEventRaw, queueEvent, startTimer, run, epoch), env (the first
-- processes' environment), keys (for Ctrl+Z), runner (lib/procrun.lua's
-- path: a command runs through it, so a failure is seen; without it,
-- straight in the shell), fs (for the panic's file).
function P.new(o)
    local osT = o.osT or os
    local settingsT = o.settings or settings
    local windowT = o.window or window
    local native = o.native or term.current()
    local termT = o.term or term
    local fsT = o.fs or rawget(_G, "fs")
    local files = fsT and fileio.on(fsT)
    local SHELL = o.shellProgram or "rom/programs/shell.lua"
    local RUNNER = o.runner
    local keysT = o.keys or rawget(_G, "keys")
    local function now() return osT.epoch("utc") end

    local K = {
        procs = {},             -- pid -> process
        list = {},              -- the processes, oldest first
        exited = {},            -- pid -> { pid, name, cmd, service, ok, err, status, terminated, at, trace }
        exitOrder = {},         -- the pids in exited, oldest first (the last P.EXITS)
        reapHooks = {},         -- fn(p), as each process ends (K.onReap)
        services = {},          -- name -> { state, pid, restarts, fails, since, last, term }
        timers = {},            -- timer id -> function
        inbox = {},             -- events for one process, { pid, ev }, or typed at a terminal, { tty, ev }
        ttys = {},              -- terminal -> { sid (its session's leader), fg (the group in front), ctrl }
        nextPid = 2, console = nil, current = nil, started = now(), cpu = 0,
        env = o.env and tables.copy(o.env) or {},
        syslog = nil,           -- syslogd's process ID
        held = {},              -- messages waiting for it
        logDropped = 0,         -- messages dropped since the last one handed over
    }
    local hostname = o.hostname or function() return sysenv.hostname(osT) end

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
    -- The console's scrollback
    --------------------------------------------------------------------
    -- As a Linux virtual console's: the rows that scroll off the top of
    -- the console's window are kept (the last P.HISTORY), and Shift+Page
    -- Up and Down show them over it; any other key goes back to the live
    -- screen, and on to whoever it's for.  What runs there sees none of
    -- it (it carries on drawing, out of sight).
    local sb
    local function showBack()
        local win, out, hist = sb.win, sb.screen, sb.hist
        sb.back = math.max(0, math.min(sb.back, #hist))
        if sb.back == 0 then
            win.setVisible(true)
            win.redraw()
            win.restoreCursor()
            return
        end
        win.setVisible(false)
        local w, h = win.getSize()
        for r = 1, h - 1 do
            local i = #hist + r - sb.back
            local line, tf, tb
            if i <= #hist then line, tf, tb = hist[i][1], hist[i][2], hist[i][3]
            else line, tf, tb = win.getLine(i - #hist) end
            if #line ~= w then
                line, tf, tb = text.padRight(line, w), text.padRight(tf, w, "0"), text.padRight(tb, w, "f")
            end
            out.setCursorPos(1, r)
            out.blit(line, tf, tb)
        end
        out.setCursorPos(1, h)
        out.setBackgroundColour(32768)          -- (black)
        out.setTextColour(16)                   -- (yellow)
        out.clearLine()
        out.write(text.truncate("scrollback: " .. sb.back .. " up; Shift+PgUp/PgDn; a key: back", w))
        out.setCursorBlink(false)
    end

    -- Keep the scrollback of window win (the console's), drawn on screen.
    function K.scrollback(win, screen)
        sb = { win = win, screen = screen, hist = {}, back = 0, shift = false }
        local scroll = win.scroll
        win.scroll = function(n)
            local _, h = win.getSize()
            if type(n) == "number" and n > 0 then
                for r = 1, math.min(n, h) do sb.hist[#sb.hist + 1] = { win.getLine(r) } end
                local drop, m = #sb.hist - P.HISTORY, #sb.hist
                if drop > 0 then
                    for i = 1, m - drop do sb.hist[i] = sb.hist[i + drop] end
                    for i = m - drop + 1, m do sb.hist[i] = nil end
                end
                if sb.back > 0 then sb.back = sb.back + math.min(n, h) end     -- (the view stays put)
            end
            local r = scroll(n)
            if sb.back > 0 then showBack() end
            return r
        end
        K.sb = sb
    end

    -- Whether one in front of terminal t keeps the scrollback's keys and
    -- wheel: its own
    local function frontOwns(t)
        local tt = K.ttys[t]
        for _, p in ipairs(K.list) do
            if tt and p.pgid == tt.fg and p.tty == t and p.ownScrollback and K.procs[p.pid] then return true end
        end
        return false
    end

    -- Keys that leave the scrollback where it is: they type nothing and ask
    -- nothing of the program (PrintScreen for a screenshot, the lock keys,
    -- Ctrl or Alt alone, the function keys the game takes for itself)
    local QUIET_KEYS = {}
    for _, name in ipairs({ "printScreen", "scrollLock", "pause", "numLock", "capsLock", "leftSuper", "rightSuper",
                            "menu", "leftCtrl", "rightCtrl", "leftAlt", "rightAlt", "f1", "f2", "f3", "f4", "f5",
                            "f6", "f7", "f8", "f9", "f10", "f11", "f12" }) do
        local code = keysT and keysT[name]
        if code then QUIET_KEYS[code] = true end
    end

    -- Shift+Page Up/Down or the wheel at the console: true if it was the
    -- scrollback's.
    local function scrollKey(t, ev)
        if not (sb and keysT and t == "con") then return false end
        local kind, k = ev[1], ev[2]
        if (kind == "key" or kind == "key_up") and (k == keysT.leftShift or k == keysT.rightShift) then
            sb.shift = kind == "key"
        elseif kind == "key" and sb.shift and (k == keysT.pageUp or k == keysT.pageDown) then
            if frontOwns(t) then return false end
            local _, h = sb.win.getSize()
            local page = math.max(1, h - 2)
            sb.back = sb.back + (k == keysT.pageUp and page or -page)
            showBack()
            return true
        elseif kind == "mouse_scroll" and type(k) == "number" then
            if frontOwns(t) then return false end
            if k < 0 or sb.back > 0 then                        -- (down at the live screen: the program's)
                sb.back = sb.back - k * P.WHEEL
                showBack()
                return true
            end
        elseif sb.back > 0 and ((kind == "key" and not QUIET_KEYS[k]) or kind == "char" or kind == "paste") then
            sb.back = 0
            showBack()
        end
        return false
    end

    --------------------------------------------------------------------
    -- Running a process
    --------------------------------------------------------------------
    local reap

    -- coroutine.resume while a process runs: the same, but a coroutine
    -- that fails is noted on the process (p.fault: its error and the
    -- coroutine), and forgotten when one is resumed and carries on (it
    -- yields again).  So what's noted when a command ends is the error
    -- that ended its program, which the CraftOS shell caught (and only
    -- printed): the try it runs a program in is a coroutine too.
    local function watchedResume(co, ...)
        local r = table.pack(rawResume(co, ...))
        local p = K.current
        if p then
            if not r[1] then p.fault = { err = r[2], co = co }
            elseif coroutine.status(co) == "suspended" then p.fault = nil end
        end
        return table.unpack(r, 1, r.n)
    end

    -- Resume p with the event ...: its terminal and environment in place
    -- while it runs.
    local function resume(p, ...)
        local was = K.current
        K.current = p
        local savedEnv = sysenv.swapEnv(p.envApi, osT)
        local savedResume = coroutine.resume
        coroutine.resume = watchedResume
        local prevTerm = termT.redirect(p.term)
        local status = rawget(_G, "POSIX_STATUS")     -- (each process's own: what its last program said)
        _G.POSIX_STATUS = p.posixStatus
        local ctx = p.enter and p.enter(p)
        local t0 = now()
        local r = table.pack(rawResume(p.co, ...))
        p.cpu = p.cpu + (now() - t0)
        if p.leave then p.leave(p, ctx) end
        p.posixStatus = rawget(_G, "POSIX_STATUS")
        _G.POSIX_STATUS = status
        p.term = termT.current()
        termT.redirect(prevTerm)
        coroutine.resume = savedResume
        sysenv.swapEnv(savedEnv, osT)
        K.current = was
        if coroutine.status(p.co) == "dead" then
            reap(p, r[1], r[2], p.co)
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
        if scrollKey(t, ev) then return end
        local tt = K.ttys[t]
        if not tt then                          -- (no session there: the console's process, if any)
            local p = t == "con" and K.console and K.procs[K.console]
            if p then deliver(p, ev) end
            return
        end
        if keysT and (ev[1] == "key" or ev[1] == "key_up") and (ev[2] == keysT.leftCtrl or ev[2] == keysT.rightCtrl) then
            tt.ctrl = ev[1] == "key"
        elseif keysT and (ev[1] == "key" or ev[1] == "key_up") and (ev[2] == keysT.leftAlt or ev[2] == keysT.rightAlt) then
            tt.alt = ev[1] == "key"             -- (Ctrl with Alt is AltGr, typing a character)
        elseif keysT and tt.ctrl and not tt.alt and ev[1] == "key" and ev[2] == keysT.z and signalGroup(tt.fg, "TSTP", true) > 0 then
            return
        elseif keysT and tt.ctrl and not tt.alt and ev[1] == "key" and ev[2] == keysT.c and signalGroup(tt.fg, "INT", true) > 0 then
            return
        end
        local any = false
        for _, p in ipairs(tables.copy(K.list)) do
            if K.procs[p.pid] and p.pgid == tt.fg and p.tty == t then any = true; deliver(p, ev) end
        end
        local leader = not any and K.procs[tt.sid]
        if leader then deliver(leader, ev) end
    end

    -- Start what was spawned and hand on what was injected, until done.
    local function flush()
        for _ = 1, 1000 do
            local busy = false
            for _, p in ipairs(tables.copy(K.list)) do
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
            for _, p in ipairs(tables.copy(K.list)) do
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
        local env = tables.copy(spec.env or (parent and parent.env) or K.env)
        local co
        if spec.fn then
            local args = spec.args or {}
            co = coroutine.create(function() return spec.fn(table.unpack(args)) end)
        else
            local shellEnv = { shell = o.shell, multishell = o.multishell }
            -- (its status: what its program said, as cu.exit and ccsh set
            -- it, or the runner for one that failed; the CraftOS shell
            -- doesn't pass that on itself.  The shell splits the runner's
            -- name and the command line into words as it would the line
            -- alone, so the runner gets the command's words as they are.)
            co = coroutine.create(function()
                if spec.cmd and RUNNER then osT.run(shellEnv, SHELL, '"' .. RUNNER .. '"', spec.cmd)
                elseif spec.cmd then osT.run(shellEnv, SHELL, spec.cmd)
                else osT.run(shellEnv, SHELL) end
                return rawget(_G, "POSIX_STATUS")
            end)
        end
        local p = {
            pid = pid, ppid = parent and parent.pid or 1, co = co, state = "new",
            name = spec.name or (spec.cmd and programName(spec.cmd)) or "shell",
            cmd = spec.cmd or spec.name or "shell",
            term = spec.term or K.newTerm(), tty = tty, env = env, envApi = sysenv.envApi(env),
            started = now(), cpu = 0, service = spec.service, onExit = spec.onExit, isCmd = spec.fn == nil,
            capture = capture, enter = spec.enter, leave = spec.leave,
            sid = session and pid or parent.sid,
            pgid = (session or spec.pgid == true) and pid or tonumber(spec.pgid) or parent.pgid,
        }
        p.name = text.stripSuffix(p.name, ".lua") or p.name
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

    -- A crash, to the log at err under the process's name: the error,
    -- then its traceback a line each.
    local function logCrash(p, trace)
        local fac = p.service and 3 or 1                -- (daemon, or user)
        local function put(msg) K.log({ fac = fac, sev = 3, app = p.service or p.name, pid = p.pid, msg = msg }) end
        put("crashed: " .. p.err)
        for _, line in ipairs(trace) do put(line) end
    end

    -- Process p has ended: ok and what its coroutine returned (a number is
    -- its status), or false and its error (co: the coroutine it failed
    -- in; none when it was killed).
    reap = function(p, ok, err, co)
        if not K.procs[p.pid] then return end
        local value = ok and err                -- (what it returned: a number is its status)
        p.status = type(value) == "number" and value or (ok and value ~= false) and 0 or 1
        -- a command whose program failed (the runner's status) with an
        -- error the shell caught: that error is how it ended
        if ok and p.isCmd and p.status ~= 0 and p.fault then
            local msg, where = errorOf(p.fault.err, p.fault.co)
            if msg ~= "" then ok, err, co = false, msg, where end
        end
        local where
        if not ok then err, where = errorOf(err, co) end
        p.state, p.ok, p.err = "dead", ok, (not ok) and err or nil
        p.fault = nil
        -- (Ctrl+T's end isn't a crash: there's no bug to trace)
        local trace = where and not (p.terminated and err == "Terminated") and traceOf(where, err) or nil
        K.procs[p.pid] = nil
        for i, q in ipairs(K.list) do
            if q == p then table.remove(K.list, i); break end
        end
        if p.logbuf and p.logbuf ~= "" then K.logLine(p, p.logbuf); p.logbuf = "" end
        if K.syslog == p.pid then K.syslog = nil end
        if trace then logCrash(p, trace) end
        K.exited[p.pid] = { pid = p.pid, name = p.name, cmd = p.cmd, service = p.service, ok = ok, err = p.err,
                            status = p.status, terminated = p.terminated == true, at = now(), trace = trace }
        K.exitOrder[#K.exitOrder + 1] = p.pid
        while #K.exitOrder > P.EXITS do K.exited[table.remove(K.exitOrder, 1)] = nil end
        for _, fn in ipairs(K.reapHooks) do
            local hookOk, why = pcall(fn, p)
            if not hookOk then K.say(3, "at the end of process " .. p.pid .. ": " .. tostring(why)) end
        end
        for _, q in ipairs(K.list) do
            if q.ppid == p.pid then q.ppid = 1 end              -- (orphans go to init)
        end
        local tt = K.ttys[p.tty]
        if tt and tt.sid == p.pid then                          -- a session leader: its terminal hangs up
            K.ttys[p.tty] = nil
            for _, q in ipairs(tables.copy(K.list)) do
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

    -- Signal `name` to p.  A process that ignores TSTP or INT isn't
    -- reached by it; fromTty (Ctrl+Z's TSTP, Ctrl+C's INT) doesn't reach
    -- one in its session leader's group either.
    -- false if it did nothing.
    signalOne = function(p, name, fromTty)
        if name == "KILL" then
            if p == K.current then p.killed = true else reap(p, false, "killed") end
        elseif name == "TERM" or name == "INT" or name == "HUP" then
            if name == "INT" and ((p.ignore and p.ignore.INT) or (fromTty and p.pgid == p.sid)) then return false end
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
        for _, p in ipairs(tables.copy(K.list)) do
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

    -- fn(p) as each process ends, before its onExit and proc_exit (what it
    -- held let go first: init has lib/net close its sockets so).  An
    -- error in fn is logged, and the rest go on.
    function K.onReap(fn)
        K.reapHooks[#K.reapHooks + 1] = fn
    end

    -- The last few processes to end, oldest first: K.exited's entries.
    function K.exits()
        local out = {}
        for _, pid in ipairs(K.exitOrder) do out[#out + 1] = tables.copy(K.exited[pid]) end
        return out
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
        line = text.trimEnd(line)
        if line == "" then return end
        local sev = err and 3 or 6
        -- "<n>" first, n 0-7: the line's severity (syslog's way)
        local n = line:sub(2, 2)
        if text.startsWith(line, "<") and line:sub(3, 3) == ">" and scan.isOctalDigit(n) then
            sev, line = tonumber(n), line:sub(4)
        end
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
            local line, rest = text.cut(buf, "\n")
            if not rest then break end
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
    -- A panic: init itself failed
    --------------------------------------------------------------------
    -- What init knew when it failed with err (trace: debug.traceback's
    -- text): the error and where, the processes as ps -l lists them, and
    -- the log's messages that hadn't reached syslogd yet (held, or in the
    -- inbox), which would be lost.  A text, for P.PANIC.
    function K.panicReport(err, trace)
        local okL, L = pcall(require, "log")
        if not (okL and type(L) == "table") then L = nil end
        local out = {}
        local function put(s) out[#out + 1] = s end
        local okH, host = pcall(hostname)
        put("init panicked at " .. (L and L.stamp(now()) or tostring(now())) .. " on " .. (okH and tostring(host) or "?"))
        put("error: " .. tostring(err))
        for _, line in ipairs(text.lines(tostring(trace or ""))) do put(line) end
        put("")
        put("processes:")
        put(P.psHeader(true, false))
        local okP, rows = pcall(K.ps)
        for _, p in ipairs(okP and rows or {}) do put(P.psLine(p, true, false)) end
        local waiting = {}
        for _, rec in ipairs(K.held) do waiting[#waiting + 1] = rec end
        for _, m in ipairs(K.inbox) do
            if m.ev and m.ev[1] == "syslog" and type(m.ev[2]) == "table" then waiting[#waiting + 1] = m.ev[2] end
        end
        put("")
        put("log messages not yet filed (" .. #waiting .. "):")
        for _, rec in ipairs(waiting) do
            if L then
                put(L.facilityName(rec.fac) .. "." .. L.severityName(rec.sev) .. " " .. L.line(rec))
            else
                put(tostring(rec.app) .. ": " .. tostring(rec.msg))
            end
        end
        return table.concat(out, "\n") .. "\n"
    end

    -- Write the panic's report (K.panicReport) to P.PANIC: the path, or
    -- nil and why it couldn't.
    function K.writePanic(err, trace)
        if not fsT then return nil, "no file system" end
        local okR, report = pcall(K.panicReport, err, trace)
        if not okR then report = "init panicked: " .. tostring(err) .. "\n(and the report failed: " .. tostring(report) .. ")\n" end
        pcall(fsT.makeDir, fsT.getDir(P.PANIC))
        local ok, why = files.write(P.PANIC, report)
        if not ok then return nil, why end
        return P.PANIC
    end

    -- Count this panic (at time now, in ms) with the ones just before it:
    -- each within P.PANIC_WINDOW of the one before is in the same row.
    -- The count is kept in P.PANIC .. ".count", two lines: how many, and
    -- when the last was.  Returns how many in a row, this one included.
    function K.panicsInRow(now)
        if not fsT then return 1 end
        local countFile = P.PANIC .. ".count"
        local inRow = 1
        local saved = files.read(countFile)
        if saved then
            local said = text.lines(saved)
            local n, at = tonumber(said[1] or ""), tonumber(said[2] or "")
            if n and at and now - at < P.PANIC_WINDOW then inRow = n + 1 end
        end
        pcall(fsT.makeDir, fsT.getDir(countFile))
        files.write(countFile, inRow .. "\n" .. now .. "\n")
        return inRow
    end

    -- At boot: if the last one ended in a panic (P.PANIC is there), log
    -- it at crit (facility kern) and move the report to P.PANIC .. ".1"
    -- (one there before is dropped).  Its error line, or nil.
    function K.lastPanic()
        local report = files and files.read(P.PANIC)
        if not report then return nil end
        local errLine = "?"
        for _, line in ipairs(text.lines(report)) do
            local said = text.stripPrefix(line, "error: ")
            if said then errLine = said; break end
        end
        local old = P.PANIC .. ".1"
        if fsT.exists(old) then fsT.delete(old) end
        local moved = pcall(fsT.move, P.PANIC, old)
        K.log({ fac = 0, sev = 2, app = "init", pid = 1,
                msg = "the last boot ended in a panic: " .. errLine .. " (" .. (moved and old or P.PANIC) .. ")" })
        return errLine
    end

    --------------------------------------------------------------------
    -- Services
    --------------------------------------------------------------------
    local function def(name) return P.serviceDef(name, settingsT) end
    K.serviceDef = def
    function K.serviceNames() return P.serviceNames(settingsT, K.services) end

    local launch

    local function exited(svc, p)
        -- failed: an error, or its program exited non-zero
        local failed = not p.ok or (p.status or 0) ~= 0
        local why = not p.ok and tostring(p.err) or ("exit status " .. tostring(p.status))
        svc.pid, svc.last, svc.exit = nil, failed and ("failed: " .. why) or "ended", K.exited[p.pid]
        local d = def(svc.name)
        local what = svc.name .. (failed and (" failed: " .. why) or " ended")
        if svc.stopping or not d or d.restart == "no" then
            if svc.stopping then say(6, "stopped " .. svc.name) else say(failed and 3 or 5, what) end
            svc.state, svc.stopping = svc.stopping and "stopped" or "exited", nil
            return
        end
        if now() - svc.since >= 30000 then svc.fails = 0 end
        svc.fails, svc.restarts = svc.fails + 1, svc.restarts + 1
        svc.state = "restarting"
        local wait = math.floor(math.min(60, 2 ^ (svc.fails - 1)))
        say(failed and 3 or 5, what .. "; again in " .. wait .. " s")
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
        -- the caller keeps Shift+Page Up/Down and the mouse wheel for
        -- itself while it's in front of the console (its own scrollback,
        -- or it scrolls with them), or with on false no longer does; true
        -- and whether it did before
        ownScrollback = function(on)
            local p = K.current
            if not p then return false end
            local was = p.ownScrollback == true
            p.ownScrollback = on ~= false or nil
            return true, was
        end,
        -- the caller ignores signal sig (TSTP or INT: the ones that can
        -- be, so Ctrl+Z or Ctrl+C reaches it as a key), or with on false,
        -- no longer does
        ignore = function(sig, on)
            local p, name = K.current, P.signal(sig)
            if not p or (name ~= "TSTP" and name ~= "INT") then return false end
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
        -- The last few processes to end, oldest first: { pid, name, cmd,
        -- service, ok, err, status, terminated, at, trace (a crash's
        -- traceback, its lines) }.
        exited = K.exits,
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
