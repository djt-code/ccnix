-- syslogd.lua -- the system log daemon: files, shows and forwards what's logged
--
--   syslogd                 run (as a service: setup init does it)
--
-- Programs log through lib/log (C's syslog(3)), shell scripts with
-- `logger`, and init logs what each service prints; all of it comes here,
-- and goes where /etc/syslog.conf says: a log file, the console, or
-- another syslog server (forwarded as RFC 5424 over UDP).  `help syslog`
-- has the whole of it.  The first time it runs it writes /etc/syslog.conf
-- with the default rules, to edit; without it (deleted) they are:
--   *.info;auth,authpriv.none;local6,local7.none    /var/log/messages
--   auth,authpriv.*                                 /var/log/auth.log
--   local6.*                                        /var/log/telnetd.log
--   local7.*                                        /var/log/httpd.log
--   *.crit                                          /dev/console
-- (telnetd logs as local6 and httpd as local7 unless telnetd.facility or
-- httpd.facility say otherwise.)  The rules are read when it starts:
-- `service restart syslogd` after changing them.  What's logged while it
-- isn't running waits in init (the last 200).
--
-- Settings:
--   syslog.maxSize   a log file past this many bytes is moved to <name>.1
--                    and started again (32768; K or M after it for KiB
--                    or MiB: `sysctl syslog.maxSize=2M` on a bigger disk)
--   syslog.keep      how many old files to keep: .1, .2... (1; 0: none)
--   syslog.burst     at most this many messages from one program in 10 s;
--                    past that they're dropped, and counted (100)
--   syslog.listen    true: take messages from other computers on UDP
--                    (RFC 5424 or RFC 3164), as a loghost (false)
--   syslog.port      the port it listens on (514)
--
-- It needs init (`help init`).  Forwarding and listening need the network
-- (`ip up`); a name in an @host rule is looked up (net.hosts, DNS) aside,
-- and messages wait for it (the last 50).

package.path = (ccnix and ccnix.lib or "/" .. fs.getDir(fs.getDir(shell.getRunningProgram())) .. "/lib/?.lua;") .. package.path  -- ccnix's lib/, or the one beside bin/
local cu = require("cu").init("syslogd", "syslogd")
local L = require("log")
local D = require("syslogd")
local text = require("text")
local okNet, net = pcall(require, "net")
if not okNet then net = nil end

if #{ ... } > 0 then cu.usageError() end
local proc = rawget(_G, "proc")
if not (proc and proc.register) then cu.fail("init isn't running (`help init`): programs log through it"); return cu.exit() end

local conf, from = D.DEFAULT, "the defaults"
if not fs.exists(D.CONF) then                       -- (the defaults, written out for editing)
    fs.makeDir(fs.getDir(D.CONF))
    local h = fs.open(D.CONF, "w")
    if h then h.write(D.DEFAULT); h.close() end
end
if fs.exists(D.CONF) and not fs.isDir(D.CONF) then
    local h = fs.open(D.CONF, "r")
    if h then conf, from = h.readAll() or "", D.CONF; h.close() end
end
local rules, problems = D.parse(conf)

local function num(key, default)
    local v = tonumber(settings.get(key))
    if v and v >= 0 then return math.floor(v) end
    return default
end
local maxSize, keep, burst = D.size(settings.get("syslog.maxSize")) or D.MAX_SIZE, num("syslog.keep", D.KEEP), num("syslog.burst", D.BURST)
local listen, port = settings.get("syslog.listen") == true, num("syslog.port", D.PORT)
local me = proc.self()

-- the console: a line on its screen, red from err
local function console(line, rec)
    local pid = proc.console()
    local t = pid and proc.term(pid)
    if not t then return end
    local old = term.redirect(t)
    pcall(rec.sev <= 3 and printError or print, line)
    term.redirect(old)
end

-- forwarding: each @host's address, looked up aside (a lookup waits for
-- DNS, and syslogd mustn't); messages wait for it
local dests = {}            -- host -> { ip, asking, failedAt, queue }
local sock, warnedNet
local function look(host, d)
    d.asking = true
    proc.spawn({ name = "syslogd-lookup", fn = function()
        local ip, why = net.resolve(host)
        proc.inject(me, "syslog_resolved", host, ip, why)
    end })
end
local function send(host, dport, data)
    if not (net and net.stack()) then
        if not warnedNet then
            warnedNet = true
            console("syslogd: the network isn't up: not forwarding to " .. host, { sev = 3 })
        end
        return
    end
    local d = dests[host]
    if not d then
        d = { queue = {}, ip = net.parseIP(host) }
        dests[host] = d
    end
    if d.ip then
        if not sock then sock = net.udp() end
        if sock then sock.S.udpSend(sock.port, d.ip, dport, data) end
        return
    end
    d.queue[#d.queue + 1] = { dport, data }
    if #d.queue > 50 then table.remove(d.queue, 1) end
    if not d.asking and (not d.failedAt or os.clock() - d.failedAt >= 60) then look(host, d) end
end

local engine = D.new({ rules = rules, fs = fs, maxSize = maxSize, keep = keep, burst = burst > 0 and burst or false,
    console = console, send = send })

local lsock
if listen then
    local why
    if net and net.stack() then lsock, why = net.udp(port) else why = "the network isn't up" end
    if not lsock then problems[#problems + 1] = "can't listen on UDP " .. port .. ": " .. tostring(why) end
end

local ok, why = proc.register("syslog")
if not ok then cu.fail(why); return cu.exit() end
local started = "started: " .. #rules .. " rule" .. (#rules == 1 and "" or "s") .. " from " .. from
    .. (lsock and ", listening on UDP " .. port or "")
print("syslogd: " .. started)
engine.note("info", started)                        -- (in the log, as rsyslogd's own start is)
for _, p in ipairs(problems) do
    print("syslogd: " .. p)
    engine.note("err", (text.startsWith(p, "line ") and D.CONF .. ": " or "") .. p)
end

local tick = os.startTimer(5)
while true do
    local ev = table.pack(os.pullEventRaw())
    local e = ev[1]
    if e == "syslog" and type(ev[2]) == "table" then
        engine.handle(ev[2])
    elseif e == "syslog_resolved" then
        local d = dests[ev[2]]
        if d then
            d.asking = false
            if ev[3] then
                d.ip = ev[3]
                local q = d.queue
                d.queue = {}
                for _, m in ipairs(q) do send(ev[2], m[1], m[2]) end
            else
                d.failedAt = os.clock()
                engine.note("err", "can't forward to " .. ev[2] .. ": " .. tostring(ev[4]))
            end
        end
    elseif e == "net_udp" and lsock and ev[2] == lsock.port then
        while true do
            local dg = lsock.S.udpTake(lsock.port)
            if not dg then break end
            if type(dg.data) == "string" then
                local rec = L.decode(dg.data)
                rec.host = rec.host or net.ipString(dg.src)
                engine.handle(rec)
            end
        end
    elseif e == "timer" and ev[2] == tick then
        engine.tick()
        tick = os.startTimer(5)
    elseif e == "terminate" then
        break
    end
end
if lsock then lsock:close() end
if sock then sock:close() end
print("syslogd: stopped")
return cu.exit()
