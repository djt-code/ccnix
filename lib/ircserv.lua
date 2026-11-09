-- ircserv.lua -- services for bin/ircd: NickServ, ChanServ, and MC (the Minecraft bridge)
--
--   local services = require("ircserv").attach(srv, {
--       load = function() return db end, save = function(db) ... end,
--       mc = require("mc").new(), bridge = "#minecraft" })
--   services.mcEvent(e)      -- each event mc.event() or mc.poll() gives
--
-- NickServ keeps nicks for whoever registered them:
--   REGISTER <password>      the nick you have, yours (you're identified)
--   IDENTIFY [nick] <password>   prove it's you (once a connection)
--   LOGOUT, DROP <password>, INFO <nick>, GHOST <nick> <password> (drop
--   a connection holding your nick)
--   VERIFY <player>          (with a Chat Box) a code is whispered to that
--                            player in the game; CONFIRM <code> then ties
--                            your nick to them: WHOIS shows "is the
--                            Minecraft player ..."
-- Taking a registered nick without identifying in 60 seconds gets you
-- renamed Guest<n>.  Passwords are kept hashed (FNV-1a with a salt, many
-- rounds): enough that they don't show; not real security, as anyone at
-- the computer can read the file anyway.
--
-- ChanServ keeps channels for their founders:
--   REGISTER #chan           (identified, and an operator there) yours;
--                            its topic and modes are kept when it empties
--   OP #chan [nick], DEOP #chan [nick]     (founder, or on the AOP list)
--   AOP #chan ADD|DEL|LIST [nick]          those it ops as they join
--   INFO #chan, DROP #chan
--
-- MC is the game.  It sits in the bridge channel (#minecraft): what's
-- said there goes into the game's chat as [nick] text, and what players
-- say in the game comes back as <player> text, with joins, leaves and
-- deaths.  /msg MC: PLAYERS (who's on), TIME (the world's clock),
-- WEATHER, TELL <player> <text> (a whisper in the game).  What it can do
-- depends on what lib/mc finds: the time always; chat with a Chat Box
-- (speaking only, with a command computer); players with a Player
-- Detector or a command computer; the weather with an Environment
-- Detector.

local irc = require("irc")
local scan = require("scan")

local S = {}
S.ENFORCE = 60              -- seconds to identify for a registered nick
S.CODE_LIFE = 300           -- seconds a VERIFY code lasts
S.ROUNDS = 500

--------------------------------------------------------------------------
-- Passwords
--------------------------------------------------------------------------
-- a XOR b for bytes, without bit32 (not every Lua has it)
local function xor8(a, b)
    local r, bit = 0, 1
    for _ = 1, 8 do
        if (a % 2) ~= (b % 2) then r = r + bit end
        a, b, bit = math.floor(a / 2), math.floor(b / 2), bit * 2
    end
    return r
end

-- FNV-1a, 32 bits: h = (h XOR byte) * 16777619 mod 2^32, the multiply
-- split (2^24 + 403) so it stays exact in a double
local function fnv(s, h)
    h = h or 2166136261
    for i = 1, #s do
        local low = h % 256
        h = h - low + xor8(low, s:byte(i))
        h = (h * 403 + (h % 256) * 16777216) % 4294967296
    end
    return h
end

function S.hash(password, salt)
    local h = fnv(salt .. password)
    for _ = 1, S.ROUNDS do h = fnv(salt .. tostring(h) .. password, h) end
    return string.format("%08x", h)
end

local function words(text) return scan.words(text or "") end

--------------------------------------------------------------------------
-- Attaching
--------------------------------------------------------------------------
function S.attach(srv, opts)
    opts = opts or {}
    local db = (opts.load and opts.load()) or {}
    db.nicks, db.chans = db.nicks or {}, db.chans or {}
    local function save() if opts.save then opts.save(db) end end
    local random = opts.random or math.random
    local mc = opts.mc
    local bridgeName = opts.bridge
    local enforce = {}          -- client -> the clock time its nick goes
    local pending = {}          -- client -> { player, code, until } (VERIFY)
    local guests = 0
    local self = {}

    local NickServ, ChanServ, MC
    local function fold(s) return srv:fold(s) end
    local function tell(svc, c, text) srv:notice(svc, c, text) end

    local function account(c) return c.account and db.nicks[fold(c.account)] end

    -- ChanServ: may c run things in this registered channel?
    local function access(rec, c)
        if not c.account then return nil end
        local who = fold(c.account)
        if rec.founder == who then return "founder" end
        if rec.aop[who] then return "aop" end
        return nil
    end

    -- Op c in every registered channel it's in and has access to.
    local function autoOp(c)
        for key, chan in pairs(c.channels) do
            local rec = db.chans[key]
            if rec and access(rec, c) then srv:setMode(ChanServ, chan, "+o", c.nick) end
        end
    end

    -- NickServ: the nick c has is registered and c isn't it: warn, and
    -- start the clock.
    local function checkNick(c)
        enforce[c] = nil
        local rec = db.nicks[fold(c.nick)]
        if not rec then return end
        if c.account and fold(c.account) == fold(rec.nick) then return end
        tell(NickServ, c, "This nick is registered. /msg NickServ IDENTIFY <password> within " .. S.ENFORCE
            .. " seconds, or it will be changed.")
        enforce[c] = srv.clock() + S.ENFORCE
    end

    local function identify(c, rec)
        c.account = rec.nick
        c.mc = rec.mc
        rec.seen = srv.time()
        if enforce[c] and fold(c.nick) == fold(rec.nick) then enforce[c] = nil end
        save()
        autoOp(c)
    end

    ------------------------------------------------------------------
    -- NickServ
    ------------------------------------------------------------------
    local NS = {}
    NS.HELP = function(c)
        for _, line in ipairs({
            "NickServ keeps your nick for you. Commands:",
            "REGISTER <password>   IDENTIFY [nick] <password>   LOGOUT",
            "DROP <password>   INFO <nick>   GHOST <nick> <password>",
            "VERIFY <player>, then CONFIRM <code>: tie your nick to your Minecraft player",
        }) do tell(NickServ, c, line) end
    end
    NS.REGISTER = function(c, w)
        if not w[2] then return tell(NickServ, c, "Syntax: REGISTER <password>") end
        if db.nicks[fold(c.nick)] then return tell(NickServ, c, c.nick .. " is registered already.") end
        local salt = string.format("%06x", random(0, 16777215))
        local rec = { nick = c.nick, salt = salt, hash = S.hash(w[2], salt), registered = srv.time() }
        db.nicks[fold(c.nick)] = rec
        identify(c, rec)
        tell(NickServ, c, c.nick .. " is registered to you now. Next time: /msg NickServ IDENTIFY <password>")
    end
    NS.IDENTIFY = function(c, w)
        local nick, pass = c.nick, w[2]
        if w[3] then nick, pass = w[2], w[3] end
        if not pass then return tell(NickServ, c, "Syntax: IDENTIFY [nick] <password>") end
        local rec = db.nicks[fold(nick)]
        if not rec then return tell(NickServ, c, nick .. " isn't registered.") end
        if S.hash(pass, rec.salt) ~= rec.hash then return tell(NickServ, c, "Wrong password.") end
        identify(c, rec)
        tell(NickServ, c, "You're identified as " .. rec.nick .. ".")
    end
    NS.LOGOUT = function(c)
        c.account, c.mc = nil, nil
        tell(NickServ, c, "You're logged out.")
        checkNick(c)
    end
    NS.DROP = function(c, w)
        local rec = account(c)
        if not rec then return tell(NickServ, c, "Identify first.") end
        if not w[2] or S.hash(w[2], rec.salt) ~= rec.hash then return tell(NickServ, c, "Syntax: DROP <password>") end
        db.nicks[fold(rec.nick)] = nil
        c.account, c.mc = nil, nil
        save()
        tell(NickServ, c, rec.nick .. " is dropped.")
    end
    NS.INFO = function(c, w)
        local rec = w[2] and db.nicks[fold(w[2])]
        if not rec then return tell(NickServ, c, (w[2] or "That") .. " isn't registered.") end
        tell(NickServ, c, rec.nick .. ": registered " .. os.date("%Y-%m-%d", rec.registered)
            .. (rec.seen and (", last seen " .. os.date("%Y-%m-%d %H:%M", rec.seen)) or ""))
        if rec.mc then tell(NickServ, c, rec.nick .. " is the Minecraft player " .. rec.mc) end
        local on = srv:find(rec.nick)
        if on and on.account and fold(on.account) == fold(rec.nick) then
            tell(NickServ, c, rec.nick .. " is online and identified.")
        end
    end
    NS.GHOST = function(c, w)
        if not w[3] then return tell(NickServ, c, "Syntax: GHOST <nick> <password>") end
        local rec = db.nicks[fold(w[2])]
        if not rec or S.hash(w[3], rec.salt) ~= rec.hash then return tell(NickServ, c, "Wrong nick or password.") end
        local holder = srv:find(w[2])
        if not holder or holder == c then return tell(NickServ, c, w[2] .. " isn't in use.") end
        srv:kill(holder, "Killed (NickServ (GHOST command used by " .. c.nick .. "))")
        tell(NickServ, c, w[2] .. " is free.")
    end
    NS.VERIFY = function(c, w)
        local rec = account(c)
        if not rec then return tell(NickServ, c, "Identify first.") end
        if not w[2] then return tell(NickServ, c, "Syntax: VERIFY <player>") end
        if not (mc and mc.has.chat) then return tell(NickServ, c, "This server can't talk to the game (no Chat Box).") end
        local online = mc.players()
        if online then
            local found
            for _, p in ipairs(online) do if p:lower() == w[2]:lower() then found = p end end
            if not found then return tell(NickServ, c, w[2] .. " isn't in the game now.") end
            w[2] = found
        end
        local code = string.format("%06d", random(0, 999999))
        pending[c] = { player = w[2], code = code, untilT = srv.clock() + S.CODE_LIFE }
        mc.tell(w[2], "IRC: " .. c.nick .. " says this is you. If so, in IRC: /msg NickServ CONFIRM " .. code, "NickServ")
        tell(NickServ, c, "A code is on its way to " .. w[2] .. " in the game: /msg NickServ CONFIRM <code>")
    end
    NS.CONFIRM = function(c, w)
        local p, rec = pending[c], account(c)
        if not p or not rec or srv.clock() > p.untilT then return tell(NickServ, c, "No code is waiting (VERIFY first).") end
        if w[2] ~= p.code then return tell(NickServ, c, "That's not the code.") end
        pending[c] = nil
        rec.mc, c.mc = p.player, p.player
        save()
        tell(NickServ, c, rec.nick .. " is the Minecraft player " .. p.player .. " now.")
    end

    ------------------------------------------------------------------
    -- ChanServ
    ------------------------------------------------------------------
    local CS = {}
    local function chanRec(c, name, need)
        local chan = name and srv:channel(name)
        local rec = name and db.chans[fold(name)]
        if not name then tell(ChanServ, c, "Which channel?"); return nil end
        if not rec then tell(ChanServ, c, name .. " isn't registered."); return nil end
        if need and not access(rec, c) then tell(ChanServ, c, "You don't have access to " .. rec.name .. "."); return nil end
        if need == "founder" and access(rec, c) ~= "founder" then
            tell(ChanServ, c, "Only " .. rec.name .. "'s founder can do that."); return nil
        end
        return rec, chan
    end
    CS.HELP = function(c)
        for _, line in ipairs({
            "ChanServ keeps channels for their founders. Commands:",
            "REGISTER #chan   DROP #chan   INFO #chan",
            "OP #chan [nick]   DEOP #chan [nick]   AOP #chan ADD|DEL|LIST [nick]",
        }) do tell(ChanServ, c, line) end
    end
    CS.REGISTER = function(c, w)
        local chan = w[2] and srv:channel(w[2])
        if not c.account then return tell(ChanServ, c, "Identify to NickServ first.") end
        if not chan then return tell(ChanServ, c, "Syntax: REGISTER #chan (you in it, an operator)") end
        if db.chans[fold(chan.name)] then return tell(ChanServ, c, chan.name .. " is registered already.") end
        local mem = chan.members[fold(c.nick)]
        if not (mem and mem.op) then return tell(ChanServ, c, "You need to be an operator in " .. chan.name .. ".") end
        db.chans[fold(chan.name)] = { name = chan.name, founder = fold(c.account), aop = {}, topic = chan.topic,
            registered = srv.time() }
        chan.registered = true
        save()
        tell(ChanServ, c, chan.name .. " is registered to " .. c.account .. ".")
    end
    CS.DROP = function(c, w)
        local rec, chan = chanRec(c, w[2], "founder")
        if not rec then return end
        db.chans[fold(rec.name)] = nil
        if chan then chan.registered = nil end
        save()
        tell(ChanServ, c, rec.name .. " is dropped.")
    end
    CS.INFO = function(c, w)
        local rec = chanRec(c, w[2])
        if not rec then return end
        local founder = db.nicks[rec.founder]
        tell(ChanServ, c, rec.name .. ": founder " .. (founder and founder.nick or rec.founder) .. ", registered "
            .. os.date("%Y-%m-%d", rec.registered))
        if rec.topic then tell(ChanServ, c, "Topic: " .. rec.topic) end
    end
    local function opOrDeop(spec)
        return function(c, w)
            local rec, chan = chanRec(c, w[2], true)
            if not rec then return end
            if not chan then return tell(ChanServ, c, rec.name .. " is empty.") end
            srv:setMode(ChanServ, chan, spec, w[3] or c.nick)
        end
    end
    CS.OP, CS.DEOP = opOrDeop("+o"), opOrDeop("-o")
    CS.AOP = function(c, w)
        local sub = (w[3] or ""):upper()
        local rec = chanRec(c, w[2], sub == "LIST" and true or "founder")
        if not rec then return end
        if sub == "LIST" then
            local names = {}
            for k in pairs(rec.aop) do names[#names + 1] = db.nicks[k] and db.nicks[k].nick or k end
            table.sort(names)
            return tell(ChanServ, c, rec.name .. " AOP: " .. (#names > 0 and table.concat(names, " ") or "(none)"))
        end
        if not w[4] or (sub ~= "ADD" and sub ~= "DEL") then return tell(ChanServ, c, "Syntax: AOP #chan ADD|DEL|LIST [nick]") end
        if sub == "ADD" and not db.nicks[fold(w[4])] then return tell(ChanServ, c, w[4] .. " isn't a registered nick.") end
        rec.aop[fold(w[4])] = (sub == "ADD") or nil
        save()
        tell(ChanServ, c, w[4] .. (sub == "ADD" and " is on " or " is off ") .. rec.name .. "'s AOP list.")
    end

    ------------------------------------------------------------------
    -- MC
    ------------------------------------------------------------------
    local MS = {}
    -- (the game's answer, both values: `mc and mc.x()` would keep only the first)
    local function ask(name, ...)
        if not mc then return nil, "no game" end
        return mc[name](...)
    end
    local bridge                -- the bridge channel, once MC is in it
    MS.HELP = function(c)
        local can = { "MC is the Minecraft world. Commands: TIME" }
        if mc and mc.has.players then can[#can + 1] = "PLAYERS" end
        if mc and mc.has.weather then can[#can + 1] = "WEATHER" end
        if mc and mc.has.chat then can[#can + 1] = "TELL <player> <text>" end
        tell(MC, c, table.concat(can, "   "))
        if bridge and mc and mc.has.chat then
            tell(MC, c, bridge.name .. " is the game's chat: say something there and the players see it.")
        end
    end
    MS.TIME = function(c) tell(MC, c, "In the world it's " .. (mc and mc.time() or "unknown") .. ".") end
    MS.PLAYERS = function(c)
        local list, why = ask("players")
        if not list then return tell(MC, c, "Can't tell who's on: " .. (why or "no game")) end
        table.sort(list)
        tell(MC, c, #list == 0 and "Nobody is in the game." or (#list .. " in the game: " .. table.concat(list, ", ")))
    end
    MS.WEATHER = function(c)
        local wx, why = ask("weather")
        tell(MC, c, wx and ("The weather: " .. wx .. ".") or ("Can't tell: " .. (why or "no game")))
    end
    MS.TELL = function(c, w, text)
        local msg = irc.afterWords(text, 2)
        if not msg then return tell(MC, c, "Syntax: TELL <player> <text>") end
        local ok, why = ask("tell", w[2], irc.strip(msg), c.nick)
        tell(MC, c, ok and ("Told " .. w[2] .. ".") or ("Can't: " .. (why or "no game")))
    end

    ------------------------------------------------------------------
    local function dispatch(svcName, table_)
        return function(from, text)
            local w = words(text)
            local cmd = (w[1] or "HELP"):upper()
            local fn = table_[cmd]
            if not fn then
                return tell(srv:find(svcName), from, "No such command: " .. cmd .. ". /msg " .. svcName .. " HELP")
            end
            fn(from, w, text)
        end
    end
    NickServ = srv:addService("NickServ", "Nickname services", dispatch("NickServ", NS))
    ChanServ = srv:addService("ChanServ", "Channel services", dispatch("ChanServ", CS))
    MC = srv:addService("MC", "Minecraft", dispatch("MC", MS))

    srv:on("registered", checkNick)
    srv:on("nick", function(c)
        pending[c] = nil
        checkNick(c)
    end)
    srv:on("quit", function(c)
        local rec = account(c)
        if rec then rec.seen = srv.time(); save() end
        enforce[c], pending[c] = nil, nil
    end)
    srv:on("tick", function()
        local now = srv.clock()
        for c, deadline in pairs(enforce) do
            if c.dead then
                enforce[c] = nil
            elseif now >= deadline then
                enforce[c] = nil
                local nick
                repeat
                    guests = guests + 1
                    nick = "Guest" .. guests
                until not srv:find(nick)
                tell(NickServ, c, "You didn't identify: you're " .. nick .. " now.")
                srv:forceNick(c, nick)
            end
        end
        if mc then mc.flush() end
    end)
    srv:on("create", function(chan)
        local rec = db.chans[fold(chan.name)]
        if not rec then return end
        chan.registered = true
        chan.topic, chan.topicBy, chan.topicAt = rec.topic, "ChanServ", rec.registered
    end)
    srv:on("join", function(c, chan)
        local rec = db.chans[fold(chan.name)]
        if rec and access(rec, c) then srv:setMode(ChanServ, chan, "+o", c.nick) end
    end)
    srv:on("topic", function(_, chan)
        local rec = db.chans[fold(chan.name)]
        if rec then rec.topic = chan.topic; save() end
    end)

    -- the bridge: MC in it; what's said there goes into the game
    if bridgeName and bridgeName ~= "" then
        bridge = srv:join(MC, bridgeName)
        if not bridge.topic then bridge.topic, bridge.topicBy, bridge.topicAt = "The Minecraft chat. /msg MC HELP", "MC", srv.time() end
        srv:on("message", function(c, chan, text, notice)
            if chan ~= bridge or c == MC or notice or not (mc and mc.has.chat) then return end
            local cmd, args = irc.ctcp(text)
            if cmd == "ACTION" then mc.say("* " .. c.nick .. " " .. irc.strip(args))
            elseif not cmd then mc.say(irc.strip(text), c.nick) end
        end)
    end

    -- What happened in the game, into the bridge.
    function self.mcEvent(e)
        if not e or not bridge or not srv:channel(bridge.name) then return end
        if e.kind == "chat" then srv:say(MC, bridge, "<" .. e.player .. "> " .. e.text)
        elseif e.kind == "join" then srv:say(MC, bridge, "* " .. e.player .. " joined the game")
        elseif e.kind == "leave" then srv:say(MC, bridge, "* " .. e.player .. " left the game")
        elseif e.kind == "death" then srv:say(MC, bridge, "* " .. e.player .. " died") end
    end

    self.db = db
    self.NickServ, self.ChanServ, self.MC = NickServ, ChanServ, MC
    return self
end

return S
