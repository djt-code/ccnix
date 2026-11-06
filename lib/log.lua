-- log.lua -- the system log, for programs: C's syslog(3) for ccnix
--
--   local log = require("log").open("httpd", "daemon")    -- openlog
--   log.info("listening on port %d", 80)                  -- printf-style
--   log.err("%s: %s", path, why)
--   log.log("warning", "...")                             -- syslog(priority, ...)
--   log.mask("info")                                      -- setlogmask(LOG_UPTO(LOG_INFO))
--
-- Each message goes to syslogd (`help syslog`), which files it, prints
-- it on the console or forwards it, as /etc/syslog.conf says.  Under
-- init it's handed to syslogd's process (proc.log: in memory, not CC's
-- event queue); messages logged while syslogd isn't running wait in init
-- (the last 200).  Without init this module files it itself, by the same
-- rules (files only: no console, no forwarding).
--
-- Severities, most severe first (0-7): emerg alert crit err warning
-- notice info debug.  Facilities, numbered as RFC 5424 numbers them: kern
-- user mail daemon auth syslog lpr news uucp cron authpriv ftp, and
-- local0-local7 (16-23) for anything else.  A message's priority (PRI) is
-- facility * 8 + severity.
--
-- open(app, facility, opts) sets the module's own logger (log.info...)
-- and returns it; new(...) makes one apart, so a library can log under
-- its own name without changing its program's.  opts: pid (false: no
-- process ID), perror (also show it on this program's screen: "HH:MM
-- message", in red from err; "stderr": all of it in red, as logger -s
-- does), fallback (false: nothing at all without init).  The app is the
-- running program's name when not given.  A message of several lines is
-- logged a line each.
--
-- What's shared with syslogd: record(), line() (the form of a line in a
-- log file), encode() and decode() (RFC 5424 on the wire; RFC 3164
-- understood coming in).

local L = {}

L.SEVERITIES = { "emerg", "alert", "crit", "err", "warning", "notice", "info", "debug" }
L.FACILITIES = { kern = 0, user = 1, mail = 2, daemon = 3, auth = 4, syslog = 5, lpr = 6, news = 7,
    uucp = 8, cron = 9, authpriv = 10, ftp = 11 }
for i = 0, 7 do L.FACILITIES["local" .. i] = 16 + i end
local SEV = {}
for i, name in ipairs(L.SEVERITIES) do SEV[name] = i - 1 end
-- the old names syslog.conf still takes
local SEV_ALIAS = { panic = 0, error = 3, warn = 4 }
local FAC_ALIAS = { security = 4 }

-- A severity's number, from its name or number; nil if it isn't one.
function L.severity(x)
    local n = tonumber(x)
    if n then return (n >= 0 and n <= 7 and n % 1 == 0) and n or nil end
    x = tostring(x):lower()
    return SEV[x] or SEV_ALIAS[x]
end

-- A facility's number, from its name or number; nil if it isn't one.
function L.facility(x)
    local n = tonumber(x)
    if n then return (n >= 0 and n <= 23 and n % 1 == 0) and n or nil end
    x = tostring(x):lower()
    return L.FACILITIES[x] or FAC_ALIAS[x]
end

local FAC_NAME = {}
for name, n in pairs(L.FACILITIES) do FAC_NAME[n] = name end
FAC_NAME[4] = "auth"
function L.facilityName(n) return FAC_NAME[n] or tostring(n) end
function L.severityName(n) return L.SEVERITIES[(n or 6) + 1] or tostring(n) end

-- This computer's name in the log: its label, else its ID.
function L.hostname()
    local label = os.getComputerLabel and os.getComputerLabel()
    if label and label ~= "" then return label end
    return tostring(os.getComputerID and os.getComputerID() or 0)
end

-- A message: { fac, sev (numbers), time (os.epoch "utc"), host, app, pid, msg }.
function L.record(facility, severity, app, msg, pid)
    return { fac = L.facility(facility) or 1, sev = L.severity(severity) or 6, time = os.epoch("utc"),
             host = L.hostname(), app = app, pid = pid, msg = tostring(msg) }
end

-- ms (os.epoch "utc") as RFC 3339 in UTC: 2026-11-03T14:02:11Z, with the
-- milliseconds when frac.
function L.stamp(ms, frac)
    ms = math.floor(ms or os.epoch("utc"))
    local s = os.date("!%Y-%m-%dT%H:%M:%S", math.floor(ms / 1000))
    if frac then return s .. string.format(".%03dZ", ms % 1000) end
    return s .. "Z"
end

-- A message as a line of a log file: "2026-11-03T14:02:11Z host app[pid]: msg".
function L.line(rec)
    local tag = rec.app or "-"
    if rec.pid then tag = tag .. "[" .. tostring(rec.pid) .. "]" end
    return (rec.stamp or L.stamp(rec.time)) .. " " .. tostring(rec.host or L.hostname()) .. " " .. tag .. ": " .. tostring(rec.msg or "")
end

-- RFC 5424's header fields are printable ASCII with no spaces, or "-".
local function field(s, max)
    if s == nil or s == "" then return "-" end
    s = tostring(s):gsub("[^\33-\126]", "_")
    return s:sub(1, max)
end

L.MAX = 2048        -- the most of a datagram (RFC 5426 asks receivers for 2048)

-- A message as an RFC 5424 datagram:
-- "<PRI>1 2026-11-03T14:02:11.123Z host app pid - - msg", cut to L.MAX bytes.
function L.encode(rec)
    local s = string.format("<%d>1 %s %s %s %s - - %s", (rec.fac or 1) * 8 + (rec.sev or 6),
        L.stamp(rec.time, true), field(rec.host, 255), field(rec.app, 48), field(rec.pid, 128),
        tostring(rec.msg or ""))
    return s:sub(1, L.MAX)
end

local function dash(s) if s ~= "-" then return s end end

-- A datagram as a message (RFC 5424, or RFC 3164's "<PRI>Mmm dd hh:mm:ss
-- host tag[pid]: msg"); one with no PRI is user.notice, as RFC 3164 says.
-- A 5424 timestamp is kept as it came (rec.stamp); otherwise the time is
-- now.  host is nil when it didn't say.
function L.decode(s)
    s = tostring(s):gsub("[\r\n]+$", "")
    local rec = { fac = 1, sev = 5, time = os.epoch("utc") }
    local pri, rest = s:match("^<(%d%d?%d?)>(.*)$")
    if not pri or tonumber(pri) > 191 then rec.msg = s; return rec end
    pri = tonumber(pri)
    rec.fac, rec.sev = math.floor(pri / 8), pri % 8
    local ts, host, app, pid, _, sd = rest:match("^1 (%S+) (%S+) (%S+) (%S+) (%S+) (.*)$")
    if ts then
        rec.stamp, rec.host, rec.app, rec.pid = dash(ts), dash(host), dash(app), dash(pid)
        local msg
        if sd:sub(1, 1) == "-" then
            msg = sd:sub(2)
        else
            -- structured data: [id k="v" ...] elements, \] escaped inside
            local i = 1
            while sd:sub(i, i) == "[" do
                i = i + 1
                while i <= #sd do
                    local c = sd:sub(i, i)
                    if c == "\\" then i = i + 2
                    elseif c == "]" then i = i + 1; break
                    else i = i + 1 end
                end
            end
            msg = sd:sub(i)
        end
        rec.msg = msg:gsub("^ ", ""):gsub("^\239\187\191", "")
        return rec
    end
    local after = rest:match("^%a%a%a [ %d]%d %d%d:%d%d:%d%d (.*)$")
    if after then
        local h, tagged = after:match("^(%S+) (.*)$")
        if h then rec.host, rest = h, tagged else rest = after end
    end
    local tag, p, msg = rest:match("^([^%[:%s]+)%[(%d+)%]: ?(.*)$")
    if not tag then tag, msg = rest:match("^([^%[:%s]+): ?(.*)$") end
    if tag then rec.app, rec.pid, rec.msg = tag, p, msg else rec.msg = rest end
    return rec
end

--------------------------------------------------------------------------
-- Logging
--------------------------------------------------------------------------
local fallbackEngine         -- this program's own filing, without init

-- Without init: the rules of /etc/syslog.conf (or the defaults), files only.
local function fallback(rec)
    if not fallbackEngine then
        local ok, D = pcall(require, "syslogd")
        if not ok or type(D) ~= "table" then return end
        local text = D.DEFAULT
        if fs.exists(D.CONF) and not fs.isDir(D.CONF) then
            local h = fs.open(D.CONF, "r")
            if h then text = h.readAll() or ""; h.close() end
        end
        fallbackEngine = D.new({ rules = (D.parse(text)), fs = fs, files = true,
            maxSize = D.size(settings.get("syslog.maxSize")), keep = tonumber(settings.get("syslog.keep")) })
    end
    pcall(fallbackEngine.route, rec)
end

local function programName()
    local sh = shell
    if type(sh) == "table" and sh.getRunningProgram then
        local p = sh.getRunningProgram()
        if p then return (fs.getName(p):gsub("%.lua$", "")) end
    end
    return "lua"
end

-- A logger of its own: app (nil: the program's name), facility (user),
-- opts as open's.
function L.new(app, facility, opts)
    opts = opts or {}
    local fac = L.facility(facility or "user")
    if not fac then error("bad facility " .. tostring(facility), 2) end
    local me, upto = {}, 7

    function me.mask(sev)
        local n = L.severity(sev)
        if not n then error("bad severity " .. tostring(sev), 2) end
        upto = n
    end

    -- Log at severity sev: fmt and its values as string.format takes
    -- them, or a message as it is when there are none.
    function me.log(sev, fmt, ...)
        local n = L.severity(sev)
        if not n then error("bad severity " .. tostring(sev), 2) end
        if n > upto then return end
        local msg = select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt)
        local proc = rawget(_G, "proc")
        local pid = opts.pid ~= false and proc and proc.self and proc.self() or nil
        for l in (msg .. "\n"):gmatch("(.-)\r?\n") do
            if l:find("%S") then
                if opts.perror then
                    local show = (opts.perror == "stderr" or n <= 3) and printError or print
                    local s = opts.perror == "stderr" and l or os.date("%H:%M ") .. l
                    if proc and proc.uncaptured then proc.uncaptured(show, s) else show(s) end
                end
                local rec = L.record(fac, n, app or programName(), l, pid)
                if proc and proc.log then proc.log(rec)
                elseif opts.fallback ~= false then fallback(rec) end
            end
        end
    end
    for i, name in ipairs(L.SEVERITIES) do
        me[name] = function(...) return me.log(i - 1, ...) end
    end
    return me
end

local default = L.new()
-- openlog: the module's logger, as these say; it's returned too.
function L.open(app, facility, opts)
    default = L.new(app, facility, opts)
    return default
end
function L.mask(sev) return default.mask(sev) end
function L.log(sev, ...) return default.log(sev, ...) end
for _, name in ipairs(L.SEVERITIES) do
    L[name] = function(...) return default[name](...) end
end

return L
