-- sim/syslog.lua
--
-- The system log: lib/log's names, records, file lines and RFC 5424 (out
-- and in, RFC 3164 too); lib/syslogd's syslog.conf (selectors as BSD's:
-- each one naming a facility decides, =, !, none, program blocks,
-- comments, bad lines told by number), rotation, the engine (files, the
-- console, forwarding, the rate limit and its count); lib/log in a
-- program, under init (proc.log) and without (files by the same rules);
-- logger; syslogd itself, taking messages from init, its rules from
-- /etc/syslog.conf.
local PROJ = ...
package.path = PROJ .. "/lib/?.lua;" .. PROJ .. "/sim/lib/?.lua;" .. package.path
local M = require("mock")
local SW = require("shellworld")
local check = M.check
local function show(s) return (tostring(s):gsub("\n", "|")) end

local STORE = {}
settings = {
    get = function(k) return STORE[k] end, set = function(k, v) STORE[k] = v end,
    unset = function(k) STORE[k] = nil end, save = function() end,
    getNames = function() local t = {} for k in pairs(STORE) do t[#t + 1] = k end table.sort(t) return t end,
}
os.getComputerID = os.getComputerID or function() return 1 end

local W = SW.new(PROJ)
W.label = "base"
-- lib/log and lib/syslogd as a program would load them (the world's fs, os)
local L, D
local r0 = W:call(function(env) L, D = env.require("log"), env.require("syslogd") end)
if not L then error(r0.errText) end

--------------------------------------------------------------------------
-- lib/log: names, records, lines, the wire
--------------------------------------------------------------------------
check("severities and facilities: by name or number, the old aliases; nil for neither",
    L.severity("err") == 3 and L.severity("error") == 3 and L.severity("warn") == 4 and L.severity("panic") == 0
        and L.severity(7) == 7 and L.severity("8") == nil and L.severity("loud") == nil
        and L.facility("local7") == 23 and L.facility("security") == 4 and L.facility("kern") == 0
        and L.facility(24) == nil and L.facility("nope") == nil)
local T0 = 1793188800000 + 123        -- 2026-10-28T12:00:00.123Z
local rec = { fac = 22, sev = 5, time = T0, host = "base", app = "telnetd", pid = 9, msg = "10.0.1.5:49152 logged in" }
check("a line of a log file: time (UTC), host, app[pid], message",
    L.line(rec) == "2026-10-28T12:00:00Z base telnetd[9]: 10.0.1.5:49152 logged in", L.line(rec))
check("RFC 5424 out: PRI (facility * 8 + severity), version 1, the time to the millisecond, no structured data",
    L.encode(rec) == "<181>1 2026-10-28T12:00:00.123Z base telnetd 9 - - 10.0.1.5:49152 logged in", L.encode(rec))
local odd = L.encode({ fac = 1, sev = 6, time = T0, host = "my base", msg = ("x"):rep(3000) })
check("... a space in a field made _, a missing one -, the whole cut to 2048 bytes",
    odd:find("^<14>1 %S+ my_base %- %- %- %- x") and #odd == 2048, odd:sub(1, 60))
local r = L.decode(L.encode(rec))
check("RFC 5424 in: what went out comes back (its time as it was written)",
    r.fac == 22 and r.sev == 5 and r.host == "base" and r.app == "telnetd" and r.pid == "9"
        and r.msg == rec.msg and r.stamp == "2026-10-28T12:00:00.123Z")
r = L.decode('<165>1 2003-10-11T22:14:15.003Z mymachine evntslog - ID47 [exampleSDID@32473 iut="3" eventID="10\\]11"][x@1 a="b"] \239\187\191An application event')
check("... structured data skipped (an escaped ] inside), the BOM dropped, - fields nil",
    r.fac == 20 and r.sev == 5 and r.app == "evntslog" and r.pid == nil and r.msg == "An application event", show(r.msg))
r = L.decode("<34>Oct 11 22:14:15 mymachine su[230]: 'su root' failed for lonvick on /dev/pts/8")
local r2 = L.decode("<13>Oct  1 01:02:03 host cron: ran")
local r3 = L.decode("no priority at all")
check("RFC 3164 in: host, tag[pid]: message; no PID; no PRI at all: user.notice, all of it the message",
    r.fac == 4 and r.sev == 2 and r.host == "mymachine" and r.app == "su" and r.pid == "230" and r.msg:find("^'su root'")
        and r2.app == "cron" and r2.pid == nil and r2.msg == "ran" and r2.host == "host"
        and r3.fac == 1 and r3.sev == 5 and r3.msg == "no priority at all")

--------------------------------------------------------------------------
-- lib/syslogd: the rules
--------------------------------------------------------------------------
local rules, problems = D.parse(D.DEFAULT)
check("the default rules parse, five of them", #rules == 5 and #problems == 0, #rules .. " " .. table.concat(problems, ";"))
local function m(sel, fac, sev, app)
    local rs = D.parse(sel .. " /x")
    return D.matches(rs[1], { fac = L.facility(fac), sev = L.severity(sev), app = app })
end
check("a severity is it and worse; * any; =, ! and != ; none",
    m("*.info", "mail", "err") and not m("*.info", "mail", "debug") and m("mail.*", "mail", "debug")
        and m("kern.=warning", "kern", "warning") and not m("kern.=warning", "kern", "err")
        and m("mail.*;mail.!err", "mail", "info") and not m("mail.*;mail.!err", "mail", "crit")
        and m("mail.*;mail.!=info", "mail", "debug") and not m("mail.*;mail.!=info", "mail", "info"))
check("each selector naming the facility decides, in order: *.info;mail.none, *.err;kern.warning, lists",
    m("*.info;mail.none", "user", "info") and not m("*.info;mail.none", "mail", "err")
        and m("*.err;kern.warning", "kern", "warning") and not m("*.err;kern.warning", "user", "warning")
        and m("auth,authpriv.*", "authpriv", "debug") and not m("auth,authpriv.*", "user", "emerg"))
rules, problems = D.parse([[
# a comment
*.err                /var/log/errors      # and one after
!httpd
*.*                  /var/log/web.log
#!telnetd,sshd
auth.*               -/var/log/logins.log
!*
local0.*             @loghost:5514
*.emerg              *
user.loud            /x
mail.info
kern.*               |/bin/mail
]])
check("rules: comments, program blocks (! and #!, several, !* ends it), -/file, @host:port, *",
    #rules == 5 and rules[1].action.path == "/var/log/errors" and rules[2].progs.httpd and not rules[2].progs.telnetd
        and rules[3].progs.telnetd and rules[3].progs.sshd and rules[3].action.path == "/var/log/logins.log"
        and rules[4].progs == nil and rules[4].action.kind == "forward" and rules[4].action.host == "loghost"
        and rules[4].action.port == 5514 and rules[5].action.kind == "console")
check("... the lines it can't read told by number",
    #problems == 3 and problems[1]:find("^line 10: unknown severity") and problems[2]:find("^line 11: want")
        and problems[3]:find("^line 12: unknown action"), table.concat(problems, "; "))
check("a program block: only that program's messages",
    D.matches(rules[2], { fac = 1, sev = 6, app = "httpd" }) and not D.matches(rules[2], { fac = 1, sev = 6, app = "other" }))

-- syslog.maxSize: bytes, or K/M
check("sizes: a number, K and M (KiB, MiB), junk is nil",
    D.size(32768) == 32768 and D.size("2M") == 2097152 and D.size("512k") == 524288 and D.size("1.5M") == 1572864
        and D.size("2MB") == 2097152 and D.size("4096") == 4096 and D.size("big") == nil and D.size(nil) == nil)

-- rotation, in the world's filesystem
local fsT = W.fs
for i = 1, 5 do D.append(fsT, "var/log/r.log", ("a"):rep(30), 64, 2) end
check("append: the folder made; past maxSize moved to .1, .1 to .2, the oldest dropped",
    W:read("var/log/r.log") == ("a"):rep(30) .. "\n" and W:read("var/log/r.log.1") == (("a"):rep(30) .. "\n"):rep(2)
        and W:read("var/log/r.log.2") == (("a"):rep(30) .. "\n"):rep(2), show(W:read("var/log/r.log")))
D.append(fsT, "var/log/z.log", "one", 5, 0)
D.append(fsT, "var/log/z.log", "two", 5, 0)
check("keep 0: started again, nothing kept", W:read("var/log/z.log") == "two\n" and W:read("var/log/z.log.1") == nil)

-- the engine
local clock, shown, sent = 0, {}, {}
local e = D.new({ rules = (D.parse(D.DEFAULT .. "*.notice @loghost\n")), fs = fsT, burst = 3, window = 10,
    clock = function() return clock end,
    console = function(line, rc) shown[#shown + 1] = rc.sev .. " " .. line end,
    send = function(h, p, dg) sent[#sent + 1] = h .. ":" .. p .. " " .. dg end })
local function R(fac, sev, app, msg) return { fac = L.facility(fac), sev = L.severity(sev), time = T0, host = "base", app = app, msg = msg } end
e.handle(R("daemon", "info", "web", "up"))
e.handle(R("local7", "info", "httpd", "GET /"))
e.handle(R("local6", "notice", "telnetd", "in"))
e.handle(R("auth", "warning", "su", "no"))
e.handle(R("kern", "crit", "net", "bad"))
e.handle(R("user", "debug", "x", "quiet"))
check("by the default rules: messages, httpd.log, telnetd.log, auth.log; crit on the console too; debug nowhere",
    W:read("var/log/messages") == "2026-10-28T12:00:00Z base web: up\n2026-10-28T12:00:00Z base net: bad\n"
        and W:read("var/log/httpd.log") == "2026-10-28T12:00:00Z base httpd: GET /\n"
        and W:read("var/log/telnetd.log"):find("telnetd: in") and W:read("var/log/auth.log"):find("su: no")
        and #shown == 1 and shown[1]:find("^2 .* net: bad$"), show(W:read("var/log/messages")))
check("@loghost: notice and worse forwarded, as RFC 5424 to port 514",
    #sent == 3 and sent[1] == "loghost:514 <181>1 2026-10-28T12:00:00.123Z base telnetd - - - in", show(table.concat(sent, "\n")))
for i = 1, 5 do e.handle(R("daemon", "info", "spam", "n" .. i)) end
local before = W:read("var/log/messages")
check("the rate limit: 3 from one program in the window, the rest dropped", select(2, before:gsub("spam: n", "")) == 3)
clock = 11
e.tick()
check("... then counted when the window ends", W:read("var/log/messages"):find("syslogd: 2 messages from spam@base suppressed\n$"),
    show(W:read("var/log/messages"):sub(-80)))
check("... and taken again after it", e.handle(R("daemon", "info", "spam", "again")) == true)
local fo = D.new({ rules = (D.parse(D.DEFAULT .. "*.notice @loghost\n")), fs = fsT, files = true,
    console = function() error("no console") end, send = function() error("no forwarding") end })
fo.route(R("kern", "emerg", "k", "files only"))
check("files only (lib/log's own): no console, no forwarding", W:read("var/log/messages"):find("k: files only\n$"))

--------------------------------------------------------------------------
-- lib/log in a program
--------------------------------------------------------------------------
W.fs.delete("var")
local got = {}
local r1 = W:call(function(env)
    local log = env.require("log").open("myapp", "local0", { perror = true })
    log.info("on port %d", 80)
    log.err("it %s", "broke")
    log.mask("notice")
    log.info("left out")
    log.warning("two\nlines")
    log.notice("100%")
end)
check("without init: filed by the default rules (local0 into messages), the screen too (\"HH:MM msg\", err in red)",
    W:read("var/log/messages"):find("base myapp: on port 80\n.*base myapp: it broke\n.*myapp: two\n.*myapp: lines\n.*myapp: 100%%\n$")
        and not W:read("var/log/messages"):find("left out")
        and r1.tty:find("%d%d:%d%d on port 80\n") and r1.errText:find("%d%d:%d%d it broke"),
    show(W:read("var/log/messages")) .. show(r1.tty))
W:file("etc/syslog.conf", "local0.* /var/log/mine.log\n")
W:call(function(env)
    env.require("log").open("myapp", "local0").info("by my rules")
end)
check("... by /etc/syslog.conf's rules when there is one", W:read("var/log/mine.log"):find("myapp: by my rules\n$"))
W.fs.delete("etc")
_G.proc = { log = function(rc) got[#got + 1] = rc end, self = function() return 7 end,
    uncaptured = function(fn, ...) got.quiet = true; return fn(...) end }
local r4 = W:call(function(env)
    local logm = env.require("log")
    local lib = logm.new("lib", "daemon", { pid = false, fallback = false })
    logm.open("prog", "user", { perror = true })
    logm.notice("under init")
    lib.debug("a library's own")
end)
_G.proc = nil
check("under init: to proc.log, with its process; a logger apart keeps its own name; perror uncaptured",
    #got == 2 and got[1].app == "prog" and got[1].pid == 7 and got[1].fac == 1 and got[1].sev == 5 and got[1].host == "base"
        and got[2].app == "lib" and got[2].pid == nil and got[2].sev == 7 and got.quiet and r4.tty:find("under init"),
    show(r4.tty) .. tostring(#got))
local r5 = W:call(function(env) env.require("log").new("x", "nonsense") end)
check("a bad facility: an error", not r5.ok and r5.errText:find("bad facility nonsense"))

--------------------------------------------------------------------------
-- logger
--------------------------------------------------------------------------
W.fs.delete("var")
r1 = W:run("logger", "disk", "is", "full")
r2 = W:run("logger", "-p", "local3.err", "-t", "backup", "-i", "-s", "failed")
r3 = W:run("logger", "-t", "pipe", { stdin = "line one\nline two\n", pipe = true })
local r6 = W:run("logger", "-p", "loud", "x")
local r7 = W:run("logger", "-p", "nope.err", "x")
local msgs = W:read("var/log/messages") or ""
check("logger: its words (user.notice, tagged logger); -p -t -i (no process without init); -s to stderr; each line of its input",
    r1.status == 0 and msgs:find("base logger: disk is full\n") and msgs:find("base backup: failed\n")
        and r2.errText == "failed\n" and msgs:find("pipe: line one\n.*pipe: line two\n"), show(msgs) .. show(r2.errText))
check("logger: a bad severity or facility: usage, status 2", r6.status == 2 and r6.errText:find("unknown severity loud")
    and r7.status == 2 and r7.errText:find("unknown facility nope"), show(r6.errText))

--------------------------------------------------------------------------
-- syslogd, under a fake init
--------------------------------------------------------------------------
W.fs.delete("var")
W:file("etc/syslog.conf", "*.info /var/log/all.log\n*.err /dev/console\nfrob\n")
local registered
local function fakeProc(refuse)
    return { self = function() return 5 end, console = function() return nil end,
        register = function(name) registered = name; if refuse then return false, "syslogd is running already (process 4)" end return true end,
        log = function() end, spawn = function() end, inject = function() end }
end
_G.proc = fakeProc()
STORE["syslog.burst"] = 2
r1 = W:run("syslogd", { events = {
    { "syslog", { fac = 3, sev = 6, time = T0, host = "base", app = "web", pid = 3, msg = "hello" }, n = 2 },
    { "syslog_wake", n = 1 },
    { "syslog", { fac = 3, sev = 6, time = T0, host = "base", app = "web", pid = 3, msg = "two" }, n = 2 },
    { "syslog", { fac = 3, sev = 6, time = T0, host = "base", app = "web", pid = 3, msg = "three" }, n = 2 },
    { "terminate", n = 1 } } })
_G.proc = nil
STORE["syslog.burst"] = nil
local all = W:read("var/log/all.log") or ""
check("syslogd: registers, says (and logs) where its rules came from, files what init hands it, stops at Ctrl+T",
    r1.status == 0 and registered == "syslog" and r1.tty:find("syslogd: started: 2 rules from /etc/syslog.conf")
        and all:find("syslogd: started: 2 rules from /etc/syslog.conf\n") and all:find("base web%[3%]: hello\n") and all:find("web%[3%]: two\n") and r1.tty:find("syslogd: stopped"),
    show(r1.tty) .. show(all))
check("... a line it couldn't read: on its screen and logged; syslog.burst's limit", r1.tty:find("syslogd: line 3: want")
    and all:find("syslogd: /etc/syslog.conf: line 3: want") and not all:find("three"), show(all))
_G.proc = fakeProc(true)
r2 = W:run("syslogd", { events = {} })
_G.proc = nil
r3 = W:run("syslogd", { events = {} })
check("syslogd: one at a time; not without init", r2.status == 1 and r2.errText:find("running already")
    and r3.status == 1 and r3.errText:find("init isn't running"), show(r2.errText) .. show(r3.errText))
W.fs.delete("etc")
_G.proc = fakeProc()
r1 = W:run("syslogd", { events = { { "terminate", n = 1 } } })
_G.proc = nil
check("syslogd with no /etc/syslog.conf: writes the defaults there, and uses them",
    W:read("etc/syslog.conf") == D.DEFAULT and r1.tty:find("started: 5 rules from /etc/syslog.conf", 1, true),
    show(r1.tty))
