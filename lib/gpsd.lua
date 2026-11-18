-- gpsd.lua -- a GPS host, for bin/gpsd (ADR-0016): answers CC's GPS pings
--
--   local G = require("gpsd")
--   local d, why = G.new(env)        -- nil and why on a pocket computer or a turtle
--   d:start()
--   while true do d:handle(os.pullEvent()) end
--
-- The protocol, as CC's clients speak it: on channel 65534 a client
-- sends "PING" (reply channel 65534 too); a host answers on the ping's
-- reply channel, reply channel 65534, with {x, y, z}.  The client takes
-- the distance its modem measured to each reply and works out where it
-- is.  Written from that description: none of CC's own gps code is here.
--
-- env: peripheral, settings, log(severity, message), startTimer(s) (game
-- time: a reply comes within a tick or two, at any tick rate), realTimer(s)
-- (real seconds: retries, re-checks, the count), locate(timeout) (x, y, z
-- or nil: gps.locate), commands (a command computer's), kind ("computer",
-- "turtle" or "pocket").
--
-- The position: gpsd.x, gpsd.y and gpsd.z; else a command computer's own
-- block; else GPS, from the other hosts (tried every 10 s until there's a
-- fix; not saved, so a computer moved locates again).  A position from the
-- settings is checked first (unless gpsd.check is false): a ping, and each
-- host's reply weighed, the distance the modem measured against the one
-- between the two positions.  Out by more than TOL blocks, it disagrees:
-- CC measures from the lower corner of the block each modem is attached to
-- (the computer's own block, its F3 coordinates), so a right position gives
-- the distance exactly, and a typo of one block shows.
-- Disagreeing hosts outnumbering agreeing ones, and two or more: the
-- position is wrong (or the computer was moved), and it doesn't serve; it
-- checks again every minute.  Otherwise it serves, naming each host that
-- disagrees (that host's position, or ours, is wrong).  No host answering
-- (they all started at once, a server restart): it serves, and checks again
-- every minute, serving meanwhile, until one has answered.
local G = {}

G.CHANNEL = 65534       -- CC's GPS channel (gps.CHANNEL_GPS)
G.TOL = 0.1             -- blocks: distances are exact, corner to corner (and a typo moves a far client's fix by tens of blocks)
G.WINDOW = 2            -- seconds a check waits for replies (game time, as CC's gps.locate)
G.RETRY = 10            -- real seconds between tries at a fix
G.RECHECK = 60          -- real seconds between checks while not serving
G.COUNT = 600           -- real seconds between counts of requests served (only when it changed)

local function dist(a, b)
    local dx, dy, dz = a[1] - b[1], a[2] - b[2], a[3] - b[3]
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end
local function round(n, places)
    local m = 10 ^ (places or 0)
    return math.floor(n * m + 0.5) / m
end
local function num(n, places)                   -- (a whole number without ".0")
    n = round(n, places)
    return n == math.floor(n) and string.format("%d", n) or tostring(n)
end
local function fmt(p) return num(p[1], 2) .. ", " .. num(p[2], 2) .. ", " .. num(p[3], 2) end
G.fmt = fmt

-- A position reply's {x, y, z}, as numbers; nil if the message isn't one.
function G.position(msg)
    if type(msg) ~= "table" or #msg ~= 3 then return nil end
    local x, y, z = tonumber(msg[1]), tonumber(msg[2]), tonumber(msg[3])
    if not (x and y and z) then return nil end
    return { x, y, z }
end

-- The position the settings give: {x, y, z}; nil when none is set; nil and
-- why when only some are, or one isn't a number.
function G.configured(settingsT)
    local got, set = {}, 0
    for i, k in ipairs({ "gpsd.x", "gpsd.y", "gpsd.z" }) do
        local v = settingsT.get(k)
        if v ~= nil and v ~= "" then
            set = set + 1
            got[i] = tonumber(v)
            if not got[i] then return nil, k .. " isn't a number: " .. tostring(v) end
        end
    end
    if set == 0 then return nil end
    if set < 3 then return nil, "set all three of gpsd.x, gpsd.y and gpsd.z (or none: it locates itself)" end
    return got
end

-- The verdict on a position, from the replies heard: each {pos = {x, y, z},
-- distance = measured}.  Returns { refuse = bool, agree = {...}, disagree =
-- {...} }, each entry the reply with expected (the distance the positions
-- give) and off (how far the two differ).
function G.judge(pos, replies, tol)
    tol = tol or G.TOL
    local v = { agree = {}, disagree = {} }
    for _, r in ipairs(replies) do
        local expected = dist(pos, r.pos)
        local e = { pos = r.pos, distance = r.distance, expected = expected, off = math.abs(expected - r.distance) }
        local list = e.off <= tol and v.agree or v.disagree
        list[#list + 1] = e
    end
    v.refuse = #v.disagree >= 2 and #v.disagree > #v.agree
    return v
end

local D = {}
D.__index = D

function G.new(env)
    if env.kind == "pocket" or env.kind == "turtle" then
        return nil, "a " .. (env.kind == "pocket" and "pocket computer" or "turtle")
            .. " moves, and a GPS host must stay put: run gpsd on a computer"
    end
    local d = setmetatable({ env = env, modems = {}, timers = {}, served = 0, counted = 0, replies = nil }, D)
    return d
end

function D:log(sev, msg) self.env.log(sev, msg) end

-- the wireless modems: each with 65534 open
local function wireless(env, name)
    return env.peripheral.getType(name) == "modem" and env.peripheral.call(name, "isWireless") == true
end
function D:addModem(name)
    if self.modems[name] or not wireless(self.env, name) then return false end
    self.modems[name] = true
    if not self.env.peripheral.call(name, "isOpen", G.CHANNEL) then
        self.env.peripheral.call(name, "open", G.CHANNEL)
    end
    return true
end
function D:modemList()
    local list = {}
    for name in pairs(self.modems) do list[#list + 1] = name end
    table.sort(list)
    return list
end

function D:timer(kind, s, real)
    local id = (real and self.env.realTimer or self.env.startTimer)(s)
    self.timers[id] = kind
    return id
end

function D:start()
    for _, name in ipairs(self.env.peripheral.getNames()) do self:addModem(name) end
    if not next(self.modems) then
        self:log("warning", "no wireless modem: waiting for one (an ender modem reaches farthest)")
    end
    local pos, why = G.configured(self.env.settings)
    if why then self:log("err", why); self.state = "stopped"; return nil, why end
    if pos then
        self.pos, self.from = pos, "gpsd.x, gpsd.y and gpsd.z"
        if self.env.settings.get("gpsd.check") == false then return self:serve() end
        return self:check()
    end
    local cmd = self.env.commands
    if cmd and cmd.getBlockPosition then
        local x, y, z = cmd.getBlockPosition()
        self.pos, self.from = { x, y, z }, "the command computer's own block"
        return self:serve()
    end
    return self:locate()
end

-- no position set: from GPS, again every RETRY seconds until there's a fix
function D:locate()
    self.state = "locating"
    local x, y, z
    if next(self.modems) and self.env.locate then x, y, z = self.env.locate(G.WINDOW) end
    if x then
        self.pos, self.from = { round(x), round(y), round(z) }, "GPS (the other hosts)"
        return self:serve()
    end
    if not self.toldLocating then
        self.toldLocating = true
        self:log("notice", "no GPS fix yet: trying every " .. G.RETRY .. " s (it needs 4 hosts in range,"
            .. " or set gpsd.x, gpsd.y and gpsd.z)")
    end
    self:timer("locate", G.RETRY, true)
end

-- a position from the settings: a ping, and the replies weighed (serving
-- meanwhile, if it is: the other hosts may be checking too)
function D:check()
    if self.state ~= "serving" then self.state = "checking" end
    self.replies = {}
    for name in pairs(self.modems) do
        self.env.peripheral.call(name, "transmit", G.CHANNEL, G.CHANNEL, "PING")
    end
    self:timer("checked", G.WINDOW, false)
end

function D:checked()
    local replies = self.replies or {}
    self.replies = nil
    local v = G.judge(self.pos, replies)
    if v.refuse then
        local d = v.disagree[1]
        local key = "refuse " .. #v.disagree .. "/" .. #replies
        if self.verdict ~= key then
            self.verdict = key
            self:log("crit", "gpsd.x, gpsd.y and gpsd.z say " .. fmt(self.pos) .. ", but " .. #v.disagree .. " of "
                .. #replies .. " hosts disagree (the one at " .. fmt(d.pos) .. " is " .. num(d.distance, 1)
                .. " blocks away, not " .. num(d.expected, 1) .. "): the position is wrong, or the computer was"
                .. " moved (or the modem isn't on the computer itself). Not serving; checking again every minute"
                .. " (gpsd.check=false serves anyway).")
        end
        self.state = "refusing"
        self:timer("recheck", G.RECHECK, true)
        return
    end
    if #replies == 0 then                       -- (checked again in a minute, until a host answers)
        if self.state ~= "serving" then
            self:log("info", "no other host answered: the position isn't checked yet (again in a minute)")
        end
    end
    for _, d in ipairs(v.disagree) do
        self:log("warning", "the host at " .. fmt(d.pos) .. " answers from " .. num(d.distance, 1)
            .. " blocks, but its position is " .. num(d.expected, 1) .. " from ours: its position (or ours) is wrong")
    end
    if self.state == "serving" then             -- (a check while serving: said only if a host answered)
        if #v.agree > 0 then self:log("info", "checked: " .. #v.agree .. " other host" .. (#v.agree == 1 and "" or "s") .. " agree") end
    else
        self:serve(v)
    end
    if #replies == 0 then self:timer("recheck", G.RECHECK, true) end
    return true
end

function D:serve(v)
    local wasRefusing = self.state == "refusing" or self.verdict
    self.state, self.verdict = "serving", nil
    local agreed = v and #v.agree > 0 and (" (" .. #v.agree .. " other host" .. (#v.agree == 1 and "" or "s")
        .. " agree)") or ""
    local on = next(self.modems) and (" on " .. table.concat(self:modemList(), ", ")) or ", once there's a wireless modem"
    self:log(wasRefusing and "notice" or "info", "serving " .. fmt(self.pos) .. ", from " .. self.from .. agreed .. on)
    if not self.countTimer then self.countTimer = self:timer("count", G.COUNT, true) end
    return true
end

function D:handle(ev, a, b, c, msg, distance)
    if ev == "modem_message" then
        local side, channel, reply = a, b, c
        if not self.modems[side] or channel ~= G.CHANNEL then return end
        if msg == "PING" then
            if self.state == "serving" and distance then
                self.env.peripheral.call(side, "transmit", reply, G.CHANNEL, { self.pos[1], self.pos[2], self.pos[3] })
                self.served = self.served + 1
            end
            return
        end
        -- another host's reply (to us, or to a client): weighed while checking
        local pos = self.replies and reply == G.CHANNEL and distance and G.position(msg)
        if pos then
            for _, r in ipairs(self.replies) do
                if dist(r.pos, pos) < 1 then return end         -- (the same host, through another modem)
            end
            self.replies[#self.replies + 1] = { pos = pos, distance = distance }
        end
    elseif ev == "timer" then
        local kind = self.timers[a]
        if not kind then return end
        self.timers[a] = nil
        if kind == "locate" then return self:locate()
        elseif kind == "checked" then return self:checked()
        elseif kind == "recheck" then
            local pos, why = G.configured(self.env.settings)    -- (corrected meanwhile: sysctl gpsd.x=...)
            if pos then self.pos = pos end
            if why then self:log("err", why) end
            if self.env.settings.get("gpsd.check") == false then return self:serve() end
            return self:check()
        elseif kind == "count" then
            if self.served ~= self.counted then
                self:log("info", "served " .. self.served .. " request" .. (self.served == 1 and "" or "s")
                    .. " (" .. (self.served - self.counted) .. " in the last " .. num(G.COUNT / 60) .. " minutes)")
                self.counted = self.served
            end
            self.countTimer = self:timer("count", G.COUNT, true)
        end
    elseif ev == "peripheral" then
        if self:addModem(a) then
            self:log("info", "answering on " .. a .. " too")
            if self.state == "locating" and not self.pos then return self:locate() end
        end
    elseif ev == "peripheral_detach" then
        if self.modems[a] then
            self.modems[a] = nil
            if not next(self.modems) then
                self:log("warning", "no wireless modem: waiting for one (" .. a .. " was removed)")
            end
        end
    end
end

return G
