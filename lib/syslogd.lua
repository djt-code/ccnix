-- syslogd.lua -- the system log's rules: syslog.conf, and filing by them
--
--   local D = require("syslogd")
--   local rules, problems = D.parse(text)          -- syslog.conf's text
--   local d = D.new({ rules = rules, fs = fs, console = fn, send = fn })
--   d.handle(rec)                                  -- a message (lib/log's record)
--   d.tick()                                       -- now and then: suppressed counts
--
-- bin/syslogd runs this under init; lib/log uses it alone (files only)
-- when init isn't running.
--
-- syslog.conf, as BSD's and rsyslog's: a rule a line, "selectors action",
-- blanks between.  Selectors are facility.severity, ";" between them:
-- that severity and worse; facility.=severity that one alone;
-- facility.!severity (or .!=severity) not those; facility.none none at
-- all; * any facility or severity; facilities listed with ",".  Read in
-- order, each one that names a message's facility decides for it, so
-- "*.info;mail.none" is everything at info or worse except mail.  A
-- line "!prog" (or "#!prog") makes the rules after it apply to that
-- program alone (several: "!a,b"); "!*" ends it.  "#" starts a comment,
-- at a line's start or after a blank.  Actions:
--   /path, -/path         add it to that file (made, with its folders)
--   /dev/console, *       show it on the console
--   @host, @host:port     forward it (RFC 5424 over UDP, port 514)
-- A message goes to every rule that matches.

local L = require("log")
local scan = require("scan")
local text = require("text")
local fileio = require("fileio")
local sysenv = require("sysenv")
local D = {}

D.CONF = "/etc/syslog.conf"
D.DEFAULT = [[
# ccnix's syslog.conf: `help syslog`
*.info;auth,authpriv.none;local6,local7.none    /var/log/messages
auth,authpriv.*                                 /var/log/auth.log
local6.*                                        /var/log/telnetd.log
local7.*                                        /var/log/httpd.log
*.crit                                          /dev/console
]]
D.MAX_SIZE, D.KEEP = 32768, 1       -- a file past MAX_SIZE bytes is moved to .1 (KEEP old ones)
D.BURST, D.WINDOW = 100, 10         -- at most BURST messages from one app in WINDOW seconds
D.PORT = 514

-- A size in bytes: a number, or one with K or M after it (KiB, MiB:
-- "2M", "512K"); nil if it's neither.
function D.size(v)
    if type(v) == "number" then return v >= 0 and math.floor(v) or nil end
    if type(v) ~= "string" then return nil end
    -- size: digit+ ("." digit*)? ("K" | "M")? "I"? "B"?, blanks around
    -- them allowed, any case
    local sc = scan.new(v:upper())
    sc:skipSpaces()
    local n = sc:readWhile(scan.isDigit)
    if n == "" then return nil end
    if sc:accept(".") then n = n .. "." .. sc:readWhile(scan.isDigit) end
    sc:skipSpaces()
    local unit = (sc:accept("K") and "K") or (sc:accept("M") and "M") or ""
    sc:accept("I")
    sc:accept("B")
    sc:skipSpaces()
    n = sc:atEnd() and tonumber(n)
    if not n then return nil end
    return math.floor(n * (unit == "M" and 1048576 or unit == "K" and 1024 or 1))
end

local notSpace = scan.isNot(scan.isSpace)
local function isFacilityChar(c) return c ~= "." and not scan.isSpace(c) end

-- a selector: facilities "." severity, the facilities anything but "."
-- and blanks, the severity non-blanks (blanks around it allowed).  The
-- two, or nil
local function readSelector(part)
    local sc = scan.new(part)
    sc:skipSpaces()
    local facs = sc:readWhile(isFacilityChar)
    if facs == "" or not sc:accept(".") then return nil end
    local lvl = sc:readWhile(notSpace)
    sc:skipSpaces()
    if lvl == "" or not sc:atEnd() then return nil end
    return facs, lvl
end

local function parseSelectors(s)
    local sels = {}
    for _, part in ipairs(text.pieces(s, ";")) do
        local facs, lvl = readSelector(part)
        if not facs then return nil, "bad selector \"" .. part .. "\"" end
        local sel = { facs = {} }
        for _, f in ipairs(text.pieces(facs, ",")) do
            if f == "*" then sel.all = true
            else
                local n = L.facility(f)
                if not n then return nil, "unknown facility \"" .. f .. "\"" end
                sel.facs[n] = true
            end
        end
        if lvl == "none" then sel.none = true
        elseif lvl == "*" then sel.sev = 7
        else
            -- the severity: "!" and "=" before its name
            local sc = scan.new(lvl)
            local op = sc:readWhile(scan.oneOf("!="))
            local name = sc:rest()
            local n = L.severity(name == "*" and 7 or name)
            if not n or #op > 2 then return nil, "unknown severity \"" .. lvl .. "\"" end
            sel.sev, sel.eq, sel.neg = n, text.contains(op, "="), text.contains(op, "!")
        end
        sels[#sels + 1] = sel
    end
    return sels
end

local function parseAction(a)
    if a == "*" or a == "/dev/console" then return { kind = "console" } end
    local dest = text.stripPrefix(a, "@")
    if dest then
        -- @host or @host:port, the port digits
        local host, port = text.cut(dest, ":")
        if not (host ~= "" and scan.isUnsigned(port)) then host, port = dest, nil end
        port = tonumber(port) or D.PORT
        if host == "" or port < 1 or port > 65535 then return nil, "bad forward \"" .. a .. "\"" end
        return { kind = "forward", host = host, port = port }
    end
    -- "-"? then a path from the root
    local file = text.stripPrefix(a, "-") or a
    if text.startsWith(file, "/") and #file > 1 then return { kind = "file", path = file } end
    return nil, "unknown action \"" .. a .. "\" (a /file, /dev/console, * or @host)"
end

-- line with its comment taken off: from a "#" at the start, or from the
-- blanks before a "#"
local function stripComment(line)
    if text.startsWith(line, "#") then return "" end
    for k = 2, #line do
        if line:sub(k, k) == "#" and scan.isSpace(line:sub(k - 1, k - 1)) then
            return text.trimEnd(line:sub(1, k - 1))
        end
    end
    return line
end

-- "!" (or "#!") then the programs: what comes after it, or nil
local function blockOf(line)
    local sc = scan.new(line)
    sc:accept("#")
    if not sc:accept("!") then return nil end
    return sc:rest()
end

-- a rule: selectors, blanks, action (each non-blanks); the two, or nil
local function readRule(line)
    local sc = scan.new(line)
    local sel = sc:readWhile(notSpace)
    if sel == "" or sc:skipSpaces() == 0 then return nil end
    local act = sc:readWhile(notSpace)
    if act == "" or not sc:atEnd() then return nil end
    return sel, act
end

local function isProgSep(c) return c == "," or scan.isSpace(c) end
local notProgSep = scan.isNot(isProgSep)

-- The rules' text: D.CONF's, or D.DEFAULT without it.  The text and
-- where it came from (D.CONF, or "the defaults").
function D.loadConf()
    local conf = fileio.read(D.CONF)
    if conf then return conf, D.CONF end
    return D.DEFAULT, "the defaults"
end

-- The settings (`help syslog`), each checked: { maxSize (bytes: D.size),
-- keep, burst, port (whole numbers, 0 or more), listen (true or false) },
-- the default for one that's unset or no good.
function D.settings()
    local function count(name, default) return math.floor(sysenv.setting(name, default, 0)) end
    return { maxSize = D.size(settings.get("syslog.maxSize")) or D.MAX_SIZE, keep = count("syslog.keep", D.KEEP),
             burst = count("syslog.burst", D.BURST), port = count("syslog.port", D.PORT),
             listen = settings.get("syslog.listen") == true }
end

-- syslog.conf's text as rules: { sels, action, progs }; and its problems,
-- "line n: why" (the line is left out).
function D.parse(conf)
    local rules, problems, progs, n = {}, {}, nil, 0
    for _, raw in ipairs(text.lines(tostring(conf))) do
        n = n + 1
        local line = text.trim(raw)
        local block = blockOf(line)
        if block then
            block = text.trim(block)
            if block == "*" or block == "" then progs = nil
            else
                -- the programs, "," or blanks between them
                progs = {}
                local sc = scan.new(block)
                while not sc:atEnd() do
                    sc:readWhile(isProgSep)
                    local p = sc:readWhile(notProgSep)
                    if p ~= "" then progs[p] = true end
                end
            end
        else
            line = stripComment(line)
            if line ~= "" then
                local sel, act = readRule(line)
                local sels, a, why
                if not sel then why = "want \"selectors action\""
                else
                    sels, why = parseSelectors(sel)
                    if sels then a, why = parseAction(act) end
                end
                if why then problems[#problems + 1] = "line " .. n .. ": " .. why
                else rules[#rules + 1] = { sels = sels, action = a, progs = progs, text = line } end
            end
        end
    end
    return rules, problems
end

-- Does the rule take message rec?
function D.matches(rule, rec)
    if rule.progs and not rule.progs[rec.app or ""] then return false end
    local on = false
    for _, s in ipairs(rule.sels) do
        if s.all or s.facs[rec.fac] then
            local hit = s.sev and (s.eq and rec.sev == s.sev or not s.eq and rec.sev <= s.sev)
            if s.none then on = false
            elseif s.neg then if hit then on = false end
            else on = hit end
        end
    end
    return on
end

-- Add line to the file at path, moving it to path.1 first if it would
-- pass maxSize (path.1 to path.2..., keep of them).  false and why if it
-- can't be written.
function D.append(fsT, path, line, maxSize, keep)
    local dir = fsT.getDir(path)
    if dir ~= "" and dir ~= ".." and not fsT.exists(dir) then fsT.makeDir(dir) end
    maxSize, keep = maxSize or D.MAX_SIZE, keep or D.KEEP
    if maxSize > 0 and fsT.exists(path) and fsT.getSize(path) + #line + 1 > maxSize then
        if keep < 1 then fsT.delete(path)
        else
            for i = keep, 1, -1 do
                local from, to = i == 1 and path or path .. "." .. (i - 1), path .. "." .. i
                if fsT.exists(from) then
                    if fsT.exists(to) then fsT.delete(to) end
                    fsT.move(from, to)
                end
            end
        end
    end
    local h, why = fsT.open(path, "a")
    if not h then return false, why or "can't open " .. path end
    local ok, err = pcall(function() h.write(line .. "\n"); h.close() end)
    if not ok then pcall(h.close); return false, err end
    return true
end

-- An engine.  o: rules; fs (the filesystem); maxSize, keep (rotation);
-- console(line, rec) (nil: no console); send(host, port, datagram) (nil:
-- no forwarding); clock() (seconds; os.epoch "utc" / 1000); burst,
-- window (the rate limit; burst false: none); files (true: files alone,
-- as lib/log uses it).
function D.new(o)
    local d = { rules = o.rules or {}, problems = {} }
    local fsT = o.fs or fs
    local clock = o.clock or function() return os.epoch("utc") / 1000 end
    local burst, window = o.burst, o.window or D.WINDOW
    if burst == nil then burst = D.BURST end
    local counts = {}           -- app@host -> { start, n, dropped }
    local failed = {}           -- path -> true: told already that it can't be written

    local function note(sev, msg)
        d.route(L.record("syslog", sev, "syslogd", msg))
    end

    -- Hand rec to every rule that takes it (no rate limit).
    function d.route(rec)
        local line
        for _, rule in ipairs(d.rules) do
            local a = rule.action
            if (not o.files or a.kind == "file") and D.matches(rule, rec) then
                line = line or L.line(rec)
                if a.kind == "file" then
                    local ok, why = D.append(fsT, a.path, line, o.maxSize, o.keep)
                    if ok then failed[a.path] = nil
                    elseif not failed[a.path] and not o.files then
                        failed[a.path] = true
                        d.problems[#d.problems + 1] = a.path .. ": " .. tostring(why)
                        if o.console then o.console("syslogd: can't write " .. a.path .. ": " .. tostring(why), { sev = 3 }) end
                    end
                elseif a.kind == "console" and o.console then o.console(line, rec)
                elseif a.kind == "forward" and o.send then o.send(a.host, a.port, L.encode(rec)) end
            end
        end
    end

    local function report(key, c)
        if c.dropped > 0 then
            note("warning", c.dropped .. " message" .. (c.dropped == 1 and "" or "s") .. " from " .. key .. " suppressed")
        end
    end

    -- A message: at most burst from one app (on one host) a window, then
    -- to the rules.  false if it was suppressed.
    function d.handle(rec)
        if burst then
            local now, key = clock(), tostring(rec.app or "-") .. "@" .. tostring(rec.host or "-")
            local c = counts[key]
            if c and now - c.start >= window then report(key, c); c = nil end
            if not c then c = { start = now, n = 0, dropped = 0 }; counts[key] = c end
            c.n = c.n + 1
            if c.n > burst then c.dropped = c.dropped + 1; return false end
        end
        d.route(rec)
        return true
    end

    -- Windows that have ended: what they suppressed, said.
    function d.tick()
        local now = clock()
        for key, c in pairs(counts) do
            if now - c.start >= window then
                report(key, c)
                counts[key] = nil
            end
        end
    end

    d.note = note
    return d
end

return D
