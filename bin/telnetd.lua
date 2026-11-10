-- telnetd.lua -- a telnet server: a shell, or the console, over the network
--
--   telnetd                 serve (run it as a service: see below)
--
-- Any telnet client can connect (ours is `telnet`).  After the password,
-- each connection gets a shell of its own, sized to the client's screen:
-- ccsh if ccsh.login is on, else the CraftOS shell; leaving it
-- closes the connection.  With telnetd.attach set to "console" it gets
-- the console instead, whatever runs there (the miner's screen, the
-- farmer's...): what's on the screen is shown, and what's typed goes to
-- it as if typed here, but Ctrl+T doesn't (Telnet's "interrupt process",
-- Ctrl+] then t in our client, does).  A session's shell leads a session
-- of its own on terminal pts/n (ps shows it): what's typed goes to what's
-- in front there, as on the console.  The screen goes as ANSI escapes
-- with xterm's 256 colours.
--
-- Settings: telnetd.password (what to type at "Password:"); telnetd.open
-- (true: no password at all); telnetd.attach ("console", or "" for a
-- shell each); telnetd.port (23); telnetd.facility (local6: the system
-- log's facility; the rules file it in /var/log/telnetd.log).  It won't start without a password
-- unless telnetd.open is on.  The password crosses the network as typed,
-- as with any telnet.
--
-- telnetd needs init, which runs its shells as processes, and the network
-- (`ip up`).  To keep it running in the background:
--   service add telnetd telnetd
--   service enable telnetd          (at boot)
--   service start telnetd
-- deploy/setup telnetd does all that.  Who connects, logs in or gives a
-- wrong password is logged (`help syslog`): /var/log/telnetd.log, and
-- `service status telnetd` shows the last of it.

package.path = (ccnix and ccnix.lib or "/" .. fs.getDir(fs.getDir(shell.getRunningProgram())) .. "/lib/?.lua;") .. package.path  -- ccnix's lib/, or the one beside bin/
local repo = "/" .. fs.getDir(fs.getDir(shell.getRunningProgram()))
local net = require("net")
local T = require("telnet")
local text = require("text")

local function fail(msg)
    printError("telnetd: " .. msg)
    error("", 0)
end
local proc = rawget(_G, "proc")
if not proc then fail("init isn't running (`help init`): it runs the shells") end
if not net.stack() then fail("the network isn't up (`ip up`)") end
local password = settings.get("telnetd.password")
local open = settings.get("telnetd.open") == true
if (type(password) ~= "string" or password == "") and not open then
    fail("no password: sysctl telnetd.password=<password> (or telnetd.open=true, for anyone)")
end
local attach = settings.get("telnetd.attach") == "console"
local port = tonumber(settings.get("telnetd.port")) or 23
local listener, err = net.listen(port)
if not listener then fail(err) end

local FRAME = 0.1
local sessions = {}             -- conn id -> session
local kills = {}                -- timer -> a session's shell to KILL, if Ctrl+T didn't end it
local ptys, timer = 0, nil

-- who comes and goes, to the system log (and this screen)
local syslog = require("log").new("telnetd", settings.get("telnetd.facility") or "local6", { perror = true })
local function log(s, sev) syslog.log(sev or "info", s) end

local function send(s, data) s.conn:send(data) end

-- the terminal a session shows, and the process it's for
local function target(s)
    if s.term then return s.term, s.pid end
    local pid = proc.console()
    return pid and proc.term(pid), pid
end

-- an event typed in a session: for whatever is in front of its terminal
-- (an init without terminals: the session's process)
local function typedEvent(s, ...)
    if proc.input then return proc.input(s.tty, ...) end
    local _, pid = target(s)
    if pid then proc.inject(pid, ...) end
end

local function finish(s, why)
    if s.done then return end
    s.done = true
    sessions[s.id] = nil
    if s.pid then
        proc.kill(s.pid, "TERM")
        kills[os.startTimer(2)] = s.pid
    end
    if s.conn:state() ~= "CLOSED" then
        if s.state == "live" then send(s, T.MODES_OFF .. "\27[" .. (s.h or 24) .. ";1H\r\n") end
        s.conn:close()
    end
    log(s.who .. " " .. why)
end

local function startSession(s)
    s.state, s.last = "live", {}
    if not attach then
        ptys = ptys + 1
        s.term = proc.newTerm(s.w, s.h, true)
        local ccsh = ccnix and ccnix.find("bin/ccsh.lua") or (fs.exists(repo .. "/bin/ccsh.lua") and repo .. "/bin/ccsh.lua")
        ccsh = ccsh and (text.stripSuffix(ccsh, ".lua") or ccsh)    -- (run without its .lua)
        local cmd = settings.get("ccsh.login") and ccsh or nil
        s.tty = "pts/" .. ptys
        s.pid = proc.spawn({ cmd = cmd, term = s.term, tty = s.tty, session = true })
    end
    send(s, T.MODES_ON)                         -- (the first frame clears the screen)
    if not timer then timer = os.startTimer(FRAME) end
end

-- What a session typed, once logged in: events for its process.
local function newDecoder(s)
    return T.decoder(function(name, ...)
        if name == "ctrl-t" then
            if s.term then typedEvent(s, "terminate") end      -- (not for the console: see the header)
        else
            typedEvent(s, name, ...)
        end
    end)
end

local function typed(s, data)
    if s.state == "live" then return s.decode(data) end
    -- the password, a character at a time (not echoed)
    local i = 1
    while i <= #data and s.state == "login" do
        local ch = data:sub(i, i)
        i = i + 1
        if ch == "\n" and s.lastCR then
            -- (CR LF: one Enter)
        elseif ch == "\r" or ch == "\n" then
            if s.typed == password then
                send(s, "\r\n")
                log(s.who .. " logged in", "notice")
                startSession(s)
            else
                s.tries = s.tries + 1
                log(s.who .. " gave a wrong password", "warning")
                if s.tries >= 3 then send(s, "\r\nLogin incorrect\r\n"); return finish(s, "turned away") end
                send(s, "\r\nLogin incorrect\r\nPassword: ")
                s.typed = ""
            end
        elseif ch == "\8" or ch == "\127" then
            s.typed = s.typed:sub(1, -2)
        elseif ch ~= "\0" then
            s.typed = s.typed .. ch
        end
        s.lastCR = ch == "\r"
    end
    -- what came after the password, typed ahead
    local rest = data:sub(i)
    if s.lastCR then rest = text.stripPrefix(rest, "\n") or text.stripPrefix(rest, "\0") or rest end   -- (the LF or NUL after a CR)
    if s.state == "live" and rest ~= "" then s.decode(rest) end
end

local function newSession(conn)
    local ip, p = conn:remote()
    local s = { conn = conn, id = conn:id(), who = ip .. ":" .. p, state = "login", typed = "", tries = 0, w = 51, h = 19,
                tty = "con" }                   -- (a shell's own terminal, once it has one)
    s.decode = newDecoder(s)
    s.parse = T.parser({
        data = function(d) typed(s, d) end,
        option = function() end,            -- (we asked; what they say back changes nothing)
        sub = function(opt, payload)
            if opt == T.NAWS and #payload >= 4 then
                local a, b, c, d = payload:byte(1, 4)
                s.w = math.max(20, math.min(164, a * 256 + b))
                s.h = math.max(5, math.min(81, c * 256 + d))
                if s.term then
                    s.term.reposition(1, 1, s.w, s.h)
                    typedEvent(s, "term_resize")
                end
            end
        end,
        command = function(c)
            if c == T.IP and s.state == "live" then typedEvent(s, "terminate") end
        end,
    })
    sessions[s.id] = s
    log(s.who .. " connected")
    send(s, T.cmd(T.WILL, T.ECHO) .. T.cmd(T.WILL, T.SGA) .. T.cmd(T.DO, T.SGA) .. T.cmd(T.DO, T.NAWS))
    if open then
        startSession(s)
    else
        send(s, "\r\n" .. (os.getComputerLabel() or ("computer " .. os.getComputerID())) .. "\r\nPassword: ")
    end
end

local function frames()
    local any = false
    for _, s in pairs(sessions) do
        if s.state == "live" and not s.done then
            any = true
            local win = target(s)
            if win and win.getLine and s.conn:pending() < 4096 then
                local out = T.render(win, s.last)
                if out ~= "" then send(s, out) end
            end
        end
    end
    timer = any and os.startTimer(FRAME) or nil
end

log("listening on port " .. port .. (attach and ", the console" or ", a shell each"))
local ok, e = pcall(function()
    while true do
        local ev = table.pack(os.pullEventRaw())
        if ev[1] == "terminate" then
            return
        elseif ev[1] == "net_accept" and ev[2] == port then
            local conn = listener:poll()
            while conn do
                newSession(conn)
                conn = listener:poll()
            end
        elseif ev[1] == "net_tcp" then
            local s = sessions[ev[2]]
            if s then
                while not s.done do
                    local data, why = s.conn:read(0)
                    if data then s.parse(data)
                    elseif why ~= "timeout" then finish(s, why == "closed" and "left" or why); break
                    else break end
                end
            end
        elseif ev[1] == "timer" and ev[2] == timer then
            frames()
        elseif ev[1] == "timer" and kills[ev[2]] then
            proc.kill(kills[ev[2]], "KILL")             -- (if it's still there)
            kills[ev[2]] = nil
        elseif ev[1] == "proc_exit" then
            for _, s in pairs(sessions) do
                if s.pid == ev[2] and not s.done then
                    local win = s.term
                    if win then send(s, T.render(win, s.last)) end
                    s.pid = nil
                    finish(s, "logged out")
                end
            end
        end
    end
end)
listener:close()
for _, s in pairs(sessions) do finish(s, "dropped: telnetd stopped") end
if not ok then error(e, 0) end
