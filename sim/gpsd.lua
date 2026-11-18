-- sim/gpsd.lua
--
-- lib/gpsd.lua, bin/gpsd's host (ADR-0016): CC's GPS answered (a "PING"
-- on 65534 gets {x, y, z} on its reply channel), on every wireless modem
-- (ender too, and one attached later) and never a wired one; what isn't a
-- ping left alone; pocket computers and turtles refused; the position
-- from the settings, a command computer's block, or GPS (tried again
-- every 10 s); the settings' position checked against the other hosts'
-- replies (D3: disagreeing hosts outnumbering agreeing ones, two or more,
-- and it doesn't serve, checking again every minute; one host out named;
-- gpsd.check=false); the count of requests served every 10 minutes, only
-- when it changed.
local PROJ = ...
package.path = PROJ .. "/lib/?.lua;" .. PROJ .. "/sim/lib/?.lua;" .. package.path
local M = require("mock")
local check = M.check
local G = require("gpsd")

-- a computer: modems by name (wireless, ender, wired), what each sends,
-- the settings, the log, the timers
local function world(opts)
    opts = opts or {}
    local w = { sent = {}, logs = {}, timers = {}, set = opts.settings or {} }
    local modems = opts.modems or { top = "wireless" }
    w.modems = modems
    w.open = {}
    local P = {}
    function P.getNames()
        local list = {}
        for name in pairs(modems) do list[#list + 1] = name end
        table.sort(list)
        return list
    end
    function P.getType(name) return modems[name] and "modem" or nil end
    function P.call(name, method, ...)
        local kind = modems[name]
        assert(kind, "no modem " .. tostring(name))
        local a = { ... }
        if method == "isWireless" then return kind ~= "wired" end
        if method == "isOpen" then return w.open[name .. ":" .. a[1]] == true end
        if method == "open" then w.open[name .. ":" .. a[1]] = true; return end
        if method == "transmit" then
            w.sent[#w.sent + 1] = { modem = name, channel = a[1], reply = a[2], msg = a[3] }
            return
        end
        error("modem method " .. method)
    end
    local n = 0
    local function timer(real) return function(s) n = n + 1; w.timers[n] = { s = s, real = real }; return n end end
    w.env = {
        peripheral = P,
        settings = { get = function(k) return w.set[k] end },
        log = function(sev, msg) w.logs[#w.logs + 1] = sev .. ": " .. msg end,
        startTimer = timer(false),
        realTimer = timer(true),
        locate = opts.locate,
        commands = opts.commands,
        kind = opts.kind or "computer",
    }
    -- the last timer of a kind of wait: the newest one asked for
    function w.lastTimer() return n, w.timers[n] end
    function w.logged(pattern)
        for _, l in ipairs(w.logs) do if l:find(pattern) then return l end end
        return nil
    end
    return w
end
local function pinged(w, d, side, reply, distance)
    local before = #w.sent
    d:handle("modem_message", side or "top", G.CHANNEL, reply or G.CHANNEL, "PING", distance)
    return w.sent[before + 1]
end
local function hostsAnswer(d, side, answers)        -- answers: { {x, y, z, distance} ... }
    for _, a in ipairs(answers) do
        d:handle("modem_message", side or "top", G.CHANNEL, G.CHANNEL, { a[1], a[2], a[3] }, a[4])
    end
end
local function fire(w, d) local id = w.lastTimer(); d:handle("timer", id) end
local HERE = { gpsd_x = 100, gpsd_y = 64, gpsd_z = -200 }
local function at(x, y, z) return { ["gpsd.x"] = x, ["gpsd.y"] = y, ["gpsd.z"] = z } end
local function distTo(x, y, z) return math.sqrt((x - 100) ^ 2 + (y - 64) ^ 2 + (z + 200) ^ 2) end
local function host(x, y, z, off) return { x, y, z, distTo(x, y, z) + (off or 0) } end

-- 1. pocket computers and turtles move: refused
check("a pocket computer is refused, with why", select(2, G.new(world({ kind = "pocket" }).env)):find("pocket computer moves"))
check("a turtle is refused", G.new(world({ kind = "turtle" }).env) == nil)

-- 2. the position from the settings, checked, then served
do
    local w = world({ settings = at(100, 64, -200), modems = { top = "wireless", back = "ender", left = "wired" } })
    local d = G.new(w.env)
    d:start()
    check("65534 opened on the wireless and the ender modem", w.open["top:65534"] and w.open["back:65534"])
    check("...and not on the wired one", not w.open["left:65534"])
    check("the check pings on each wireless modem", #w.sent == 2 and w.sent[1].msg == "PING" and w.sent[1].channel == 65534
        and w.sent[1].reply == 65534)
    local _, t = w.lastTimer()
    check("...and waits 2 s of game time for replies", t.s == 2 and not t.real)
    check("while checking it answers no ping", pinged(w, d, "top", 65534, 30) == nil)
    hostsAnswer(d, "top", { host(100, 200, -200), host(300, 150, -100), host(-50, 120, -350) })
    hostsAnswer(d, "back", { host(100, 200, -200) })         -- (the same host through the other modem: once)
    fire(w, d)
    check("three hosts agree: serving", d.state == "serving", d.state)
    check("...it says so, the position, where from, the modems",
        w.logged("^info: serving 100, 64, %-200, from gpsd.x, gpsd.y and gpsd.z %(3 other hosts agree%) on back, top"), w.logs[#w.logs])
    local r = pinged(w, d, "top", 4321, 25)
    check("a ping is answered on its reply channel, from 65534, with {x, y, z}",
        r and r.modem == "top" and r.channel == 4321 and r.reply == 65534 and r.msg[1] == 100 and r.msg[2] == 64 and r.msg[3] == -200)
    local e = pinged(w, d, "back", 65534, 900)
    check("...on the ender modem it came through too", e and e.modem == "back")
    check("a ping without a distance (a wired modem's) isn't answered", pinged(w, d, "top", 65534, nil) == nil)
    local before = #w.sent
    d:handle("modem_message", "top", 65534, 65534, "HELLO", 10)
    d:handle("modem_message", "top", 60000, 60000, "PING", 10)
    d:handle("modem_message", "left", 65534, 65534, "PING", 10)
    check("not a ping, another channel, a modem not its own: left alone", #w.sent == before)
    -- the count
    for _ = 1, 3 do pinged(w, d, "top", 65534, 12) end
    local id, t2 = nil, nil
    for i, t3 in pairs(w.timers) do if t3.s == 600 and t3.real then id, t2 = i, t3 end end
    check("the count is every 600 real seconds", t2 ~= nil)
    d:handle("timer", id)
    check("...it logs how many requests it answered", w.logged("served 5 requests %(5 in the last 10 minutes%)"), w.logs[#w.logs])
    local nlogs = #w.logs
    fire(w, d)
    check("...and nothing when none came since", #w.logs == nlogs, w.logs[#w.logs])
    -- a modem attached, and removed
    w.modems.right = "wireless"
    d:handle("peripheral", "right")
    check("a wireless modem attached later: opened, said", w.open["right:65534"] and w.logged("answering on right too"))
    check("...and answered on", pinged(w, d, "right", 65534, 8).modem == "right")
    for _, side in ipairs({ "top", "back", "right" }) do d:handle("peripheral_detach", side) end
    check("every wireless modem removed: a warning", w.logs[#w.logs]:find("^warning: no wireless modem"))
    check("...and no answer from a modem gone", pinged(w, d, "top", 65534, 8) == nil)
end

-- 3. a wrong position: most of the hosts disagree, and it doesn't serve
do
    local w = world({ settings = at(100, 64, -200) })
    local d = G.new(w.env)
    d:start()
    local wrong = { 100, 64, -230 }                     -- (where the computer really is: 30 blocks off)
    local function from(x, y, z) return { x, y, z, math.sqrt((x - wrong[1]) ^ 2 + (y - wrong[2]) ^ 2 + (z - wrong[3]) ^ 2) } end
    hostsAnswer(d, "top", { from(100, 200, -200), from(300, 150, -100), from(-50, 120, -350) })
    fire(w, d)
    check("three hosts disagree: not serving", d.state == "refusing", d.state)
    check("...said at crit, naming a host and both distances",
        w.logged("^crit: gpsd.x, gpsd.y and gpsd.z say 100, 64, %-200, but 3 of 3 hosts disagree %(the one at 100, 200, %-200 is"),
        w.logs[#w.logs])
    check("...pings aren't answered", pinged(w, d, "top", 65534, 30) == nil)
    local _, t = w.lastTimer()
    check("...it checks again in 60 real seconds", t.s == 60 and t.real)
    fire(w, d)
    hostsAnswer(d, "top", { from(100, 200, -200), from(300, 150, -100), from(-50, 120, -350) })
    local nlogs = #w.logs
    fire(w, d)
    check("the same verdict again: not said again", #w.logs == nlogs and d.state == "refusing", w.logs[#w.logs])
    -- corrected: sysctl gpsd.z=-230
    w.set["gpsd.z"] = -230
    fire(w, d)
    hostsAnswer(d, "top", { from(100, 200, -200), from(300, 150, -100), from(-50, 120, -350) })
    fire(w, d)
    check("the position corrected: the next check serves", d.state == "serving", d.state)
    check("...said as a notice", w.logs[#w.logs]:find("^notice: serving 100, 64, %-230"), w.logs[#w.logs])
end

-- 4. how many disagree
local function verdict(answers)
    local w = world({ settings = at(100, 64, -200) })
    local d = G.new(w.env)
    d:start()
    hostsAnswer(d, "top", answers)
    fire(w, d)
    return d.state, w
end
local A1, A2, A3 = host(100, 200, -200), host(300, 150, -100), host(-50, 120, -350)
local B1, B2, B3 = host(0, 90, -100, 12), host(200, 90, -300, -9), host(150, 70, -150, 4)
do
    local state, w = verdict({ A1, A2, A3, B1 })
    check("one host out among three that agree: serving", state == "serving")
    check("...the one out named in a warning",
        w.logged("^warning: the host at 0, 90, %-100 answers from [%d.]+ blocks, but its position is [%d.]+ from ours"), w.logs[#w.logs])
end
check("one host out, none agreeing: serving (one can't say which is wrong)", verdict({ B1 }) == "serving")
check("two out, one agreeing: not serving", verdict({ A1, B1, B2 }) == "refusing")
check("two out, two agreeing: serving", verdict({ A1, A2, B1, B2 }) == "serving")
check("within 2.5 blocks (modems a block from their computers): agrees", verdict({ host(0, 90, -100, 2.4), host(200, 90, -300, -2.4) }) == "serving")
check("2.6 out: disagrees", verdict({ host(0, 90, -100, 2.6), host(200, 90, -300, -2.6) }) == "refusing")
do
    local state, w = verdict({})
    check("no other host: serving, unchecked, said", state == "serving" and w.logged("^info: no other host answered"))
end
do
    local w = world({ settings = { ["gpsd.x"] = 1, ["gpsd.y"] = 2, ["gpsd.z"] = 3, ["gpsd.check"] = false } })
    local d = G.new(w.env)
    d:start()
    check("gpsd.check=false: serving at once, no ping", d.state == "serving" and #w.sent == 0)
end
do
    local w = world({ settings = { ["gpsd.x"] = 1, ["gpsd.z"] = 3 } })
    local d = G.new(w.env)
    local ok, why = d:start()
    check("two of the three set: refused, saying all three", ok == nil and why:find("set all three") and w.logged("^err: set all three"))
    w = world({ settings = at("10", "sixty", 3) })
    check("one not a number: named", select(2, G.new(w.env):start()):find("gpsd.y isn't a number: sixty"))
    w = world({ settings = at("10", "64", "-3") })
    d = G.new(w.env)
    d:start()
    check("numbers set as text (sysctl's): taken", d.pos[2] == 64 and d.pos[3] == -3)
end

-- 5. no position set: a command computer's block, or GPS
do
    local w = world({ commands = { getBlockPosition = function() return 7, 80, 9 end } })
    local d = G.new(w.env)
    d:start()
    check("a command computer: its own block, served at once", d.state == "serving" and d.pos[1] == 7 and d.pos[2] == 80
        and w.logged("from the command computer's own block"))
end
do
    local fixes = { false, false }
    local asked = {}
    local w = world({ locate = function(t)
        asked[#asked + 1] = t
        local f = table.remove(fixes, 1)
        if f then return table.unpack(f) end
        return nil
    end })
    local d = G.new(w.env)
    d:start()
    check("no settings: it locates itself (2 s, as gps.locate)", asked[1] == 2 and d.state == "locating")
    check("...no fix: said once, how to set one", w.logged("^notice: no GPS fix yet: trying every 10 s"))
    local _, t = w.lastTimer()
    check("...tried again in 10 real seconds", t.s == 10 and t.real)
    fire(w, d)
    check("...again no fix, not said again", #asked == 2 and #w.logs == 1, #w.logs)
    fixes[1] = { 40.0004, 70.9999, -12.0002 }
    fire(w, d)
    check("...a fix: serving, rounded to the block", d.state == "serving" and d.pos[1] == 40 and d.pos[2] == 71 and d.pos[3] == -12)
    check("...from GPS, and no check (the fix is the other hosts' already)", #w.sent == 0 and w.logged("from GPS"))
end
do
    local tried = 0
    local w = world({ modems = {}, locate = function() tried = tried + 1 end })
    local d = G.new(w.env)
    d:start()
    check("no wireless modem: a warning, and no locating until there is one", tried == 0
        and w.logged("^warning: no wireless modem: waiting for one"))
    w.modems.top = "ender"
    d:handle("peripheral", "top")
    check("...a modem attached: it tries at once", tried == 1)
end

-- 6. the reply's shape (what CC's clients take)
check("G.position: three numbers", G.position({ 1, 2, 3 })[3] == 3)
check("...numbers as text taken", G.position({ "1", "2", "3" })[1] == 1)
check("...two, four, or a word: not a position", not G.position({ 1, 2 }) and not G.position({ 1, 2, 3, 4 })
    and not G.position({ 1, "x", 3 }) and not G.position("PING"))
