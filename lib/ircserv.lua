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
local text = require("text")

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

local function words(s) return text.words(s or "") end

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
    -- The services' commands, as tables.  Each command:
    --   usage   its arguments, for HELP and "Syntax:"
    --   about   what it does, for HELP
    --   min     the arguments it needs (fewer: "Syntax: ...")
    --   needs   what the sender must be first (NEEDS below)
    --   chan    for ChanServ: the channel (its first argument) must be
    --           "registered", or the sender must have "access" (founder
    --           or AOP) or be its "founder"; run then gets its record
    --           and the channel (nil if empty) after the arguments
    --   when    shown and run only while this is true (MC: what the game has)
    --   run(c, args, text)   args: the words after the command
    ------------------------------------------------------------------
    local bridge                -- the bridge channel, once MC is in it

    -- (the game's answer, both values: `mc and mc.x()` would keep only the first)
    local function ask(name, ...)
        if not mc then return nil, "no game" end
        return mc[name](...)
    end
    local function gameHas(what) return function() return mc ~= nil and mc.has[what] ~= nil end end

    local NEEDS = {
        account = function(c) return not account(c) and "Identify first: /msg NickServ IDENTIFY <password>" or nil end,
        game = function() return not (mc and mc.has.chat) and "This server can't talk to the game (no Chat Box)." or nil end,
    }

    -- The record of the channel a ChanServ command names, if the sender
    -- may use it at that level; else why not.
    local function channelFor(c, name, level)
        local rec = db.chans[fold(name)]
        if not rec then return nil, name .. " isn't registered." end
        local has = access(rec, c)
        if level == "access" and not has then return nil, "You don't have access to " .. rec.name .. "." end
        if level == "founder" and has ~= "founder" then return nil, "Only " .. rec.name .. "'s founder can do that." end
        return rec
    end

    local NS = {
        REGISTER = { usage = "<password>", about = "the nick you have becomes yours", min = 1,
            run = function(c, a)
                if db.nicks[fold(c.nick)] then return tell(NickServ, c, c.nick .. " is registered already.") end
                local salt = string.format("%06x", random(0, 16777215))
                local rec = { nick = c.nick, salt = salt, hash = S.hash(a[1], salt), registered = srv.time() }
                db.nicks[fold(c.nick)] = rec
                identify(c, rec)
                tell(NickServ, c, c.nick .. " is registered to you now. Next time: /msg NickServ IDENTIFY <password>")
            end },
        IDENTIFY = { usage = "[nick] <password>", about = "prove the nick is yours", min = 1,
            run = function(c, a)
                local nick, pass = c.nick, a[1]
                if a[2] then nick, pass = a[1], a[2] end
                local rec = db.nicks[fold(nick)]
                if not rec then return tell(NickServ, c, nick .. " isn't registered.") end
                if S.hash(pass, rec.salt) ~= rec.hash then return tell(NickServ, c, "Wrong password.") end
                identify(c, rec)
                tell(NickServ, c, "You're identified as " .. rec.nick .. ".")
            end },
        LOGOUT = { usage = "", about = "not identified any more",
            run = function(c)
                c.account, c.mc = nil, nil
                tell(NickServ, c, "You're logged out.")
                checkNick(c)
            end },
        DROP = { usage = "<password>", about = "give your registration up", min = 1, needs = "account",
            run = function(c, a)
                local rec = account(c)
                if S.hash(a[1], rec.salt) ~= rec.hash then return tell(NickServ, c, "Wrong password.") end
                db.nicks[fold(rec.nick)] = nil
                c.account, c.mc = nil, nil
                save()
                tell(NickServ, c, rec.nick .. " is dropped.")
            end },
        INFO = { usage = "<nick>", about = "who registered a nick, and when", min = 1,
            run = function(c, a)
                local rec = db.nicks[fold(a[1])]
                if not rec then return tell(NickServ, c, a[1] .. " isn't registered.") end
                tell(NickServ, c, rec.nick .. ": registered " .. os.date("%Y-%m-%d", rec.registered)
                    .. (rec.seen and (", last seen " .. os.date("%Y-%m-%d %H:%M", rec.seen)) or ""))
                if rec.mc then tell(NickServ, c, rec.nick .. " is the Minecraft player " .. rec.mc) end
                local on = srv:find(rec.nick)
                if on and on.account and fold(on.account) == fold(rec.nick) then
                    tell(NickServ, c, rec.nick .. " is online and identified.")
                end
            end },
        GHOST = { usage = "<nick> <password>", about = "drop a connection holding your nick", min = 2,
            run = function(c, a)
                local rec = db.nicks[fold(a[1])]
                if not rec or S.hash(a[2], rec.salt) ~= rec.hash then return tell(NickServ, c, "Wrong nick or password.") end
                local holder = srv:find(a[1])
                if not holder or holder == c then return tell(NickServ, c, a[1] .. " isn't in use.") end
                srv:kill(holder, "Killed (NickServ (GHOST command used by " .. c.nick .. "))")
                tell(NickServ, c, a[1] .. " is free.")
            end },
        VERIFY = { usage = "<player>", about = "a code is whispered to that player in the game", min = 1,
            needs = "account", when = gameHas("chat"),
            run = function(c, a)
                local player = a[1]
                local online = mc.players()
                if online then
                    local found
                    for _, p in ipairs(online) do if p:lower() == player:lower() then found = p end end
                    if not found then return tell(NickServ, c, player .. " isn't in the game now.") end
                    player = found
                end
                local code = string.format("%06d", random(0, 999999))
                pending[c] = { player = player, code = code, untilT = srv.clock() + S.CODE_LIFE }
                mc.tell(player, "IRC: " .. c.nick .. " says this is you. If so, in IRC: /msg NickServ CONFIRM " .. code, "NickServ")
                tell(NickServ, c, "A code is on its way to " .. player .. " in the game: /msg NickServ CONFIRM <code>")
            end },
        CONFIRM = { usage = "<code>", about = "the code: your nick is that Minecraft player now", min = 1,
            needs = "account", when = gameHas("chat"),
            run = function(c, a)
                local p, rec = pending[c], account(c)
                if not p or srv.clock() > p.untilT then return tell(NickServ, c, "No code is waiting (VERIFY first).") end
                if a[1] ~= p.code then return tell(NickServ, c, "That's not the code.") end
                pending[c] = nil
                rec.mc, c.mc = p.player, p.player
                save()
                tell(NickServ, c, rec.nick .. " is the Minecraft player " .. p.player .. " now.")
            end },
    }

    local function opOrDeop(spec)
        return function(c, a, rec, chan)
            if not chan then return tell(ChanServ, c, rec.name .. " is empty.") end
            srv:setMode(ChanServ, chan, spec, a[2] or c.nick)
        end
    end

    local CS = {
        REGISTER = { usage = "#chan", about = "keep a channel you're an operator in", min = 1, needs = "account",
            run = function(c, a)
                local chan = srv:channel(a[1])
                if not chan then return tell(ChanServ, c, "Syntax: REGISTER #chan (you in it, an operator)") end
                if db.chans[fold(chan.name)] then return tell(ChanServ, c, chan.name .. " is registered already.") end
                local mem = chan.members[fold(c.nick)]
                if not (mem and mem.op) then return tell(ChanServ, c, "You need to be an operator in " .. chan.name .. ".") end
                db.chans[fold(chan.name)] = { name = chan.name, founder = fold(c.account), aop = {}, topic = chan.topic,
                    registered = srv.time() }
                chan.registered = true
                save()
                tell(ChanServ, c, chan.name .. " is registered to " .. c.account .. ".")
            end },
        DROP = { usage = "#chan", about = "give a channel's registration up", min = 1, chan = "founder",
            run = function(c, _, rec, chan)
                db.chans[fold(rec.name)] = nil
                if chan then chan.registered = nil end
                save()
                tell(ChanServ, c, rec.name .. " is dropped.")
            end },
        INFO = { usage = "#chan", about = "its founder, when, its topic", min = 1, chan = "registered",
            run = function(c, _, rec)
                local founder = db.nicks[rec.founder]
                tell(ChanServ, c, rec.name .. ": founder " .. (founder and founder.nick or rec.founder) .. ", registered "
                    .. os.date("%Y-%m-%d", rec.registered))
                if rec.topic then tell(ChanServ, c, "Topic: " .. rec.topic) end
            end },
        OP = { usage = "#chan [nick]", about = "operator status, for you or nick", min = 1, chan = "access", run = opOrDeop("+o") },
        DEOP = { usage = "#chan [nick]", about = "operator status taken", min = 1, chan = "access", run = opOrDeop("-o") },
        AOP = { usage = "#chan ADD|DEL|LIST [nick]", about = "those opped as they join", min = 2, chan = "access",
            run = function(c, a, rec)
                local sub = a[2]:upper()
                if sub == "LIST" then
                    local names = {}
                    for k in pairs(rec.aop) do names[#names + 1] = db.nicks[k] and db.nicks[k].nick or k end
                    table.sort(names)
                    return tell(ChanServ, c, rec.name .. " AOP: " .. (#names > 0 and table.concat(names, " ") or "(none)"))
                end
                if not a[3] or (sub ~= "ADD" and sub ~= "DEL") then return tell(ChanServ, c, "Syntax: AOP #chan ADD|DEL|LIST [nick]") end
                if access(rec, c) ~= "founder" then return tell(ChanServ, c, "Only " .. rec.name .. "'s founder can do that.") end
                if sub == "ADD" and not db.nicks[fold(a[3])] then return tell(ChanServ, c, a[3] .. " isn't a registered nick.") end
                rec.aop[fold(a[3])] = (sub == "ADD") or nil
                save()
                tell(ChanServ, c, a[3] .. (sub == "ADD" and " is on " or " is off ") .. rec.name .. "'s AOP list.")
            end },
    }

    local MS = {
        TIME = { usage = "", about = "the world's clock",
            run = function(c) tell(MC, c, "In the world it's " .. (mc and mc.time() or "unknown") .. ".") end },
        PLAYERS = { usage = "", about = "who's in the game",
            run = function(c)
                local list, why = ask("players")
                if not list then return tell(MC, c, "Can't tell who's on: " .. (why or "no game")) end
                table.sort(list)
                tell(MC, c, #list == 0 and "Nobody is in the game." or (#list .. " in the game: " .. table.concat(list, ", ")))
            end },
        WEATHER = { usage = "", about = "rain, thunder or clear",
            run = function(c)
                local wx, why = ask("weather")
                tell(MC, c, wx and ("The weather: " .. wx .. ".") or ("Can't tell: " .. (why or "no game")))
            end },
        TELL = { usage = "<player> <text>", about = "a whisper to a player in the game", min = 2, needs = "game",
            run = function(c, a, text)
                local ok, why = ask("tell", a[1], irc.strip(irc.afterWords(text, 2)), c.nick)
                tell(MC, c, ok and ("Told " .. a[1] .. ".") or ("Can't: " .. (why or "no game")))
            end },
    }

    -- HELP for a service: its first line, then each command it has now.
    local function help(svc, c, intro, commands)
        tell(svc, c, intro)
        local names = {}
        for name, cmd in pairs(commands) do
            if not cmd.when or cmd.when() then names[#names + 1] = name end
        end
        table.sort(names)
        for _, name in ipairs(names) do
            local cmd = commands[name]
            tell(svc, c, name .. (cmd.usage ~= "" and (" " .. cmd.usage) or "") .. ": " .. cmd.about)
        end
    end

    -- A service: a user whose messages are commands, checked against its
    -- table (enough arguments, what the sender must be), then run.
    local function addService(nick, realname, intro, commands)
        local function handle(c, text)
            local svc = srv:find(nick)
            local w = words(text)
            local name = (w[1] or "HELP"):upper()
            local args = { table.unpack(w, 2) }
            if name == "HELP" then return help(svc, c, intro, commands) end
            local cmd = commands[name]
            if not cmd or (cmd.when and not cmd.when()) then
                return tell(svc, c, "No such command: " .. name .. ". /msg " .. nick .. " HELP")
            end
            if #args < (cmd.min or 0) then return tell(svc, c, "Syntax: " .. name .. " " .. cmd.usage) end
            local refused = cmd.needs and NEEDS[cmd.needs](c)
            if refused then return tell(svc, c, refused) end
            if cmd.chan then
                local rec, why = channelFor(c, args[1], cmd.chan)
                if not rec then return tell(svc, c, why) end
                return cmd.run(c, args, rec, srv:channel(rec.name))
            end
            cmd.run(c, args, text)
        end
        return srv:addService(nick, realname, handle)
    end
    NickServ = addService("NickServ", "Nickname services", "NickServ keeps your nick for you. Commands:", NS)
    ChanServ = addService("ChanServ", "Channel services", "ChanServ keeps channels for their founders. Commands:", CS)
    MC = addService("MC", "Minecraft", "MC is the Minecraft world. Commands:", MS)

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

    -- What happened in the game, as a line in the bridge.
    local GAME_EVENTS = {
        chat  = function(e) return "<" .. e.player .. "> " .. e.text end,
        join  = function(e) return "* " .. e.player .. " joined the game" end,
        leave = function(e) return "* " .. e.player .. " left the game" end,
        death = function(e) return "* " .. e.player .. " died" end,
    }
    function self.mcEvent(e)
        local line = e and GAME_EVENTS[e.kind]
        if not line or not bridge or not srv:channel(bridge.name) then return end
        srv:say(MC, bridge, line(e))
    end

    self.db = db
    self.NickServ, self.ChanServ, self.MC = NickServ, ChanServ, MC
    return self
end

return S
