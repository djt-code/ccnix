-- ircd.lua -- an IRC server's heart: users, channels and what they say (bin/ircd)
--
--   local ircd = require("ircd")
--   local srv = ircd.new({ name = "irc.ccnix", network = "ccnix", motd = { "hi" } })
--   local c = srv:connect(function(line) conn:send(line .. "\r\n") end, "10.1.1.5")
--   srv:input(c, "NICK steve")          -- each line that comes in, without its CR LF
--   srv:tick()                          -- each second: pings, timeouts, the services' timers
--   srv:closed(c, "Connection reset")   -- the connection went
--   -- c.dead: the server is done with it (QUIT, KILL, a ping timeout):
--   -- send what's left and close the connection
--
-- One server, as ngIRCd is when not linked: no server-to-server, no
-- flood limits.  What it speaks (RFC 1459 and 2812, the parts clients
-- use): PASS NICK USER CAP (no capabilities offered) PING PONG QUIT JOIN
-- PART PRIVMSG NOTICE TOPIC NAMES LIST MODE KICK INVITE WHO WHOIS AWAY
-- ISON USERHOST MOTD LUSERS VERSION TIME OPER KILL.  Channels start with
-- # and the first one in is an operator (@); modes o v b k l i m n s t
-- (+nt to start).  Users: +i, +o (OPER, with opts.oper as the password).
-- Names compare in rfc1459 case (`help irc` in lib/irc).  A user quiet
-- for 90 seconds is PINGed, and dropped 90 seconds later without a PONG.
--
-- opts: name (the server's), network, motd (lines), password (PASS;
-- nil: none needed), oper (OPER's password; nil: no operators), time
-- (now, in seconds since 1970; os.epoch), clock (seconds, for timers;
-- os.clock), version, log(text).
--
-- Services (lib/ircserv) sit on it as users with no connection: a
-- message to one goes to its handler, and it hears what happens:
--   srv:addService(nick, realname, function(from, text) ... end)
--   srv:on(event, fn)    "registered" (c), "nick" (c, old), "join" (c, chan),
--                        "part" (c, chan), "quit" (c), "create" (chan),
--                        "message" (c, chan, text, notice), "topic" (c, chan),
--                        "tick" ()
--   srv:notice(svc, c, text)  srv:say(svc, chan, text)  srv:forceNick(c, nick)
--   srv:kill(c, why)  srv:setMode(svc, chan, "+o", nick)  srv:setTopic(svc, chan, text)
--   srv:find(nick)  srv:channel(name)  srv:fold(name)

local irc = require("irc")
local scan = require("scan")

local D = {}
D.VERSION = "ccnix-ircd-1.0"
D.PING_AFTER, D.PING_TIMEOUT = 90, 90
D.NICKLEN, D.TOPICLEN, D.MAXCHANNELS = 30, 300, 20
D.CHANMODES = "b,k,l,imnst"

local Server = {}
Server.__index = Server
local CMD = {}                  -- the commands, by name: CMD.JOIN(srv, c, m)

function D.new(opts)
    opts = opts or {}
    local srv = setmetatable({
        name = opts.name or "irc.ccnix",
        network = opts.network or "ccnix",
        motd = opts.motd,
        password = opts.password,
        operPass = opts.oper,
        version = opts.version or D.VERSION,
        time = opts.time or function() return math.floor(os.epoch("utc") / 1000) end,
        clock = opts.clock or os.clock,
        log = opts.log or function() end,
        clients = {},           -- id -> client
        nicks = {},             -- folded nick -> client
        channels = {},          -- folded name -> channel
        hooks = {},
        nextId = 1,
    }, Server)
    srv.created = os.date and os.date("%Y-%m-%d %H:%M", srv.time()) or tostring(srv.time())
    return srv
end

--------------------------------------------------------------------------
-- Sending
--------------------------------------------------------------------------
function Server:fold(s) return irc.casefold(s, "rfc1459") end

function Server:prefixOf(c)
    if c.service then return c.nick .. "!" .. c.user .. "@" .. self.name end
    return (c.nick or "*") .. "!" .. (c.user or "*") .. "@" .. (c.host or "*")
end

function Server:send(c, line)
    if c.send and not c.dead then c.send(line) end
end

-- A message from the server: ":name command params..."
function Server:reply(c, command, ...)
    self:send(c, ":" .. self.name .. " " .. irc.build(command, ...))
end

-- A numeric reply: ":name 001 nick params... :text", the last param
-- after " :" always, as ngIRCd and the rest write it.
function Server:numeric(c, code, ...)
    self:send(c, ":" .. self.name .. " " .. irc.buildTrailing(code, c.nick or "*", ...))
end

-- The commands whose last param is text: always after " :".
local TEXT = { PRIVMSG = true, NOTICE = true, KICK = true, PART = true, QUIT = true, TOPIC = true }

-- From c (as nick!user@host) to whoever gets it.
function Server:from(src, command, ...)
    local build = (TEXT[command] and select("#", ...) > 1) and irc.buildTrailing or irc.build
    return ":" .. self:prefixOf(src) .. " " .. build(command, ...)
end

function Server:toChannel(chan, line, except)
    for _, m in pairs(chan.members) do
        if m.client ~= except then self:send(m.client, line) end
    end
end

-- Everyone who shares a channel with c (and c), once each.
function Server:peers(c)
    local seen, out = { [c] = true }, { c }
    for _, chan in pairs(c.channels) do
        for _, m in pairs(chan.members) do
            if not seen[m.client] then seen[m.client] = true; out[#out + 1] = m.client end
        end
    end
    return out
end

function Server:on(event, fn)
    self.hooks[event] = self.hooks[event] or {}
    table.insert(self.hooks[event], fn)
end

function Server:emit(event, ...)
    for _, fn in ipairs(self.hooks[event] or {}) do
        local ok, err = pcall(fn, ...)
        if not ok then self.log("hook " .. event .. ": " .. tostring(err)) end
    end
end

--------------------------------------------------------------------------
-- Connections
--------------------------------------------------------------------------
function Server:connect(send, host)
    local c = {
        id = self.nextId, send = send, host = host or "unknown",
        modes = {}, channels = {}, registered = false,
        signon = self.time(), idleSince = self.time(), heard = self.clock(),
    }
    self.nextId = self.nextId + 1
    self.clients[c.id] = c
    return c
end

function Server:input(c, line)
    if c.dead then return end
    c.heard = self.clock()
    c.pingOut = nil
    line = line:sub(1, irc.MAX_LINE - 2)
    local m = irc.parse(line)
    if not m then return end
    local handler = CMD[m.command]
    if not handler then
        if c.registered then self:numeric(c, "421", m.command, "Unknown command") end
        return
    end
    if not c.registered and not CMD.before[m.command] then
        self:numeric(c, "451", "You have not registered")
        return
    end
    handler(self, c, m)
end

-- The connection went (or the server drops it): QUIT to the others.
function Server:closed(c, why)
    if not self.clients[c.id] then return end
    self:quit(c, why or "Connection closed")
end

function Server:quit(c, why)
    if c.registered then
        local line = self:from(c, "QUIT", why)
        for _, p in ipairs(self:peers(c)) do
            if p ~= c then self:send(p, line) end
        end
        self:emit("quit", c)
    end
    for _, chan in pairs(c.channels) do self:leave(c, chan) end
    if c.nick and self.nicks[self:fold(c.nick)] == c then self.nicks[self:fold(c.nick)] = nil end
    self:send(c, "ERROR :Closing link: " .. (c.host or "") .. " (" .. why .. ")")
    self.clients[c.id] = nil
    c.dead = true
end

function Server:kill(c, why) self:quit(c, why) end

-- Each second.
function Server:tick()
    local now = self.clock()
    for _, c in pairs(self.clients) do
        if not c.service and not c.dead then
            if c.pingOut and now - c.pingOut > D.PING_TIMEOUT then
                self:quit(c, "Ping timeout: " .. D.PING_TIMEOUT .. " seconds")
            elseif not c.pingOut and now - c.heard > D.PING_AFTER then
                c.pingOut = now
                self:send(c, "PING :" .. self.name)
            end
        end
    end
    self:emit("tick")
end

--------------------------------------------------------------------------
-- Registration
--------------------------------------------------------------------------
function Server:find(nick) return nick and self.nicks[self:fold(nick)] end

local function supportTokens(srv)
    return { "CASEMAPPING=rfc1459", "CHANTYPES=#", "PREFIX=(ov)@+", "CHANMODES=" .. D.CHANMODES,
        "NICKLEN=" .. D.NICKLEN, "CHANNELLEN=50", "TOPICLEN=" .. D.TOPICLEN, "CHANLIMIT=#:" .. D.MAXCHANNELS,
        "MODES=4", "NETWORK=" .. srv.network, "AWAYLEN=200", "KICKLEN=300" }
end

function Server:sendMotd(c)
    if not self.motd or #self.motd == 0 then
        self:numeric(c, "422", "MOTD File is missing")
        return
    end
    self:numeric(c, "375", "- " .. self.name .. " Message of the day - ")
    for _, line in ipairs(self.motd) do self:numeric(c, "372", "- " .. line) end
    self:numeric(c, "376", "End of MOTD command")
end

function Server:sendLusers(c)
    local users, invisible, opers = 0, 0, 0
    for _, x in pairs(self.clients) do
        if x.registered then
            users = users + 1
            if x.modes.i then invisible = invisible + 1 end
            if x.modes.o then opers = opers + 1 end
        end
    end
    local chans = 0
    for _ in pairs(self.channels) do chans = chans + 1 end
    self:numeric(c, "251", "There are " .. (users - invisible) .. " users and " .. invisible .. " invisible on 1 servers")
    if opers > 0 then self:numeric(c, "252", opers, "operator(s) online") end
    self:numeric(c, "254", chans, "channels formed")
    self:numeric(c, "255", "I have " .. users .. " clients and 0 servers")
end

local function tryRegister(srv, c)
    if c.registered or not c.nick or not c.user or c.capping then return end
    if srv.password and c.pass ~= srv.password then
        srv:numeric(c, "464", "Password incorrect")
        srv:quit(c, "Bad password")
        return
    end
    c.registered = true
    srv:numeric(c, "001", "Welcome to the " .. srv.network .. " IRC network " .. srv:prefixOf(c))
    srv:numeric(c, "002", "Your host is " .. srv.name .. ", running version " .. srv.version)
    srv:numeric(c, "003", "This server was created " .. srv.created)
    srv:send(c, ":" .. srv.name .. " 004 " .. c.nick .. " " .. srv.name .. " " .. srv.version .. " io biklmnostv")
    local tokens = supportTokens(srv)
    srv:send(c, ":" .. srv.name .. " 005 " .. c.nick .. " " .. table.concat(tokens, " ") .. " :are supported by this server")
    srv:sendLusers(c)
    srv:sendMotd(c)
    srv.log(c.nick .. "!" .. c.user .. "@" .. c.host .. " connected")
    srv:emit("registered", c)
end

-- Give c the nick (taken already checked).
local function setNick(srv, c, nick)
    local old = c.nick
    if old then srv.nicks[srv:fold(old)] = nil end
    srv.nicks[srv:fold(nick)] = c
    if c.registered then
        local line = srv:from(c, "NICK", nick)
        for _, p in ipairs(srv:peers(c)) do srv:send(p, line) end
    end
    c.nick = nick
    for _, chan in pairs(c.channels) do
        local m = chan.members[srv:fold(old)]
        chan.members[srv:fold(old)] = nil
        chan.members[srv:fold(nick)] = m
    end
    if c.registered then srv:emit("nick", c, old) end
end

function Server:forceNick(c, nick)
    if self:find(nick) then return false end
    setNick(self, c, nick)
    return true
end

-- The commands a client may send before it's registered.
CMD.before = { CAP = true, PASS = true, NICK = true, USER = true, PING = true, PONG = true, QUIT = true }

function CMD.CAP(srv, c, m)
    local sub = (m.params[1] or ""):upper()
    if sub == "LS" then
        c.capping = not c.registered
        srv:reply(c, "CAP", c.nick or "*", "LS", "")
    elseif sub == "REQ" then
        srv:reply(c, "CAP", c.nick or "*", "NAK", m.params[2] or "")
    elseif sub == "END" then
        c.capping = nil
        tryRegister(srv, c)
    elseif sub == "LIST" then
        srv:reply(c, "CAP", c.nick or "*", "LIST", "")
    end
end

function CMD.PASS(srv, c, m)
    if c.registered then return srv:numeric(c, "462", "You may not reregister") end
    c.pass = m.params[1]
end

function CMD.NICK(srv, c, m)
    local nick = m.params[1]
    if not nick or nick == "" then return srv:numeric(c, "431", "No nickname given") end
    if not irc.validNick(nick, D.NICKLEN) then return srv:numeric(c, "432", nick, "Erroneous nickname") end
    local holder = srv:find(nick)
    if holder and holder ~= c then return srv:numeric(c, "433", nick, "Nickname is already in use") end
    if holder == c and c.nick == nick then return end
    setNick(srv, c, nick)
    tryRegister(srv, c)
end

function CMD.USER(srv, c, m)
    if c.registered then return srv:numeric(c, "462", "You may not reregister") end
    if #m.params < 4 then return srv:numeric(c, "461", "USER", "Not enough parameters") end
    -- the user name: its letters, digits, - . and _, ten at most
    local userChar = scan.oneOf("-._")
    local kept = {}
    for i = 1, #m.params[1] do
        local ch = m.params[1]:sub(i, i)
        if scan.isAlnum(ch) or userChar(ch) then kept[#kept + 1] = ch end
    end
    c.user = table.concat(kept):sub(1, 10)
    if c.user == "" then c.user = "user" end
    c.real = m.params[4]
    tryRegister(srv, c)
end

function CMD.PING(srv, c, m)
    srv:reply(c, "PONG", srv.name, m.params[1] or srv.name)
end

function CMD.PONG() end                 -- (input() already noted it)

function CMD.QUIT(srv, c, m)
    srv:quit(c, "Quit: " .. (m.params[1] or ""))
end

--------------------------------------------------------------------------
-- Channels
--------------------------------------------------------------------------
function Server:channel(name) return name and self.channels[self:fold(name)] end

local function member(srv, chan, c) return c and c.nick and chan.members[srv:fold(c.nick)] end

local function isOp(srv, chan, c)
    local mem = member(srv, chan, c)
    return mem and mem.op or (c and c.service and true) or false
end

local function memberPrefix(mem)
    return (mem.op and "@" or "") .. (mem.voice and "+" or "")
end

local function banned(srv, chan, c)
    local full = srv:prefixOf(c)
    for _, mask in ipairs(chan.bans) do
        if irc.match(mask, full) then return true end
    end
    return false
end

-- The channel's modes as "+ntk key" (key and limit only for members).
local function modeString(chan, showArgs)
    local letters, args = "+", {}
    for _, l in ipairs({ "i", "m", "n", "s", "t" }) do
        if chan.modes[l] then letters = letters .. l end
    end
    if chan.modes.k then letters = letters .. "k"; args[#args + 1] = showArgs and chan.modes.k or "*" end
    if chan.modes.l then letters = letters .. "l"; args[#args + 1] = tostring(chan.modes.l) end
    return letters, args
end

function Server:sendNames(c, chan)
    local names = {}
    local inside = member(self, chan, c)
    for _, mem in pairs(chan.members) do
        if inside or not mem.client.modes.i then
            names[#names + 1] = memberPrefix(mem) .. mem.client.nick
        end
    end
    table.sort(names)
    -- in lines that stay well under 512 bytes
    local line = {}
    local function flush()
        if #line > 0 then self:numeric(c, "353", chan.modes.s and "@" or "=", chan.name, table.concat(line, " ")) end
        line = {}
    end
    local size = 0
    for _, n in ipairs(names) do
        if size + #n > 400 then flush(); size = 0 end
        line[#line + 1] = n
        size = size + #n + 1
    end
    flush()
    self:numeric(c, "366", chan.name, "End of /NAMES list.")
end

function Server:sendTopic(c, chan)
    if not chan.topic or chan.topic == "" then
        self:numeric(c, "331", chan.name, "No topic is set")
        return
    end
    self:numeric(c, "332", chan.name, chan.topic)
    self:numeric(c, "333", chan.name, chan.topicBy or self.name, tostring(chan.topicAt or chan.created))
end

local function newChannel(srv, name)
    local chan = { name = name, members = {}, modes = { n = true, t = true }, bans = {}, invited = {},
        created = srv.time() }
    srv.channels[srv:fold(name)] = chan
    srv:emit("create", chan)
    return chan
end

-- c into the channel (made if it isn't there), without the checks.
function Server:join(c, name)
    local chan = self:channel(name)
    local fresh = not chan
    chan = chan or newChannel(self, name)
    if member(self, chan, c) then return chan end
    chan.members[self:fold(c.nick)] = { client = c, op = fresh and not chan.registered }
    c.channels[self:fold(chan.name)] = chan
    chan.invited[self:fold(c.nick)] = nil
    self:toChannel(chan, self:from(c, "JOIN", chan.name))
    if not c.service then
        self:sendTopic(c, chan)
        self:sendNames(c, chan)
    end
    self:emit("join", c, chan)
    return chan
end

-- c out of the channel (no message); an empty channel goes.
function Server:leave(c, chan)
    chan.members[self:fold(c.nick)] = nil
    c.channels[self:fold(chan.name)] = nil
    if next(chan.members) == nil then self.channels[self:fold(chan.name)] = nil end
end

function CMD.JOIN(srv, c, m)
    local list = m.params[1]
    if not list then return srv:numeric(c, "461", "JOIN", "Not enough parameters") end
    if list == "0" then                     -- JOIN 0: out of them all
        for _, chan in pairs(c.channels) do
            srv:toChannel(chan, srv:from(c, "PART", chan.name, "Left all channels"))
            srv:emit("part", c, chan)
            srv:leave(c, chan)
        end
        return
    end
    local keys = {}
    for _, k in ipairs(scan.split(m.params[2] or "", ",")) do keys[#keys + 1] = k end
    local i = 0
    for _, name in ipairs(scan.split(list, ",")) do
        i = i + 1
        local chan = srv:channel(name)
        local invited = chan and chan.invited[srv:fold(c.nick)]
        local count = 0
        for _ in pairs(c.channels) do count = count + 1 end
        if not irc.validChannel(name, "#") then
            srv:numeric(c, "403", name, "No such channel")
        elseif chan and member(srv, chan, c) then
            -- (already in)
        elseif count >= D.MAXCHANNELS then
            srv:numeric(c, "405", name, "You have joined too many channels")
        elseif chan and chan.modes.k and keys[i] ~= chan.modes.k then
            srv:numeric(c, "475", name, "Cannot join channel (+k)")
        elseif chan and chan.modes.i and not invited then
            srv:numeric(c, "473", name, "Cannot join channel (+i)")
        elseif chan and chan.modes.l and not invited and srv:countMembers(chan) >= chan.modes.l then
            srv:numeric(c, "471", name, "Cannot join channel (+l)")
        elseif chan and not invited and banned(srv, chan, c) then
            srv:numeric(c, "474", name, "Cannot join channel (+b)")
        else
            srv:join(c, name)
        end
    end
end

function Server:countMembers(chan)
    local n = 0
    for _ in pairs(chan.members) do n = n + 1 end
    return n
end

function CMD.PART(srv, c, m)
    if not m.params[1] then return srv:numeric(c, "461", "PART", "Not enough parameters") end
    for _, name in ipairs(scan.split(m.params[1], ",")) do
        local chan = srv:channel(name)
        if not chan then srv:numeric(c, "403", name, "No such channel")
        elseif not member(srv, chan, c) then srv:numeric(c, "442", name, "You're not on that channel")
        else
            srv:toChannel(chan, srv:from(c, "PART", chan.name, m.params[2]))
            srv:emit("part", c, chan)
            srv:leave(c, chan)
        end
    end
end

function Server:setTopic(by, chan, text)
    chan.topic = text:sub(1, D.TOPICLEN)
    chan.topicBy = by.nick
    chan.topicAt = self.time()
    self:toChannel(chan, self:from(by, "TOPIC", chan.name, chan.topic))
    self:emit("topic", by, chan)
end

function CMD.TOPIC(srv, c, m)
    local chan = srv:channel(m.params[1])
    if not m.params[1] then return srv:numeric(c, "461", "TOPIC", "Not enough parameters") end
    if not chan then return srv:numeric(c, "403", m.params[1], "No such channel") end
    if not m.params[2] then
        if chan.modes.s and not member(srv, chan, c) then return srv:numeric(c, "442", chan.name, "You're not on that channel") end
        return srv:sendTopic(c, chan)
    end
    if not member(srv, chan, c) then return srv:numeric(c, "442", chan.name, "You're not on that channel") end
    if chan.modes.t and not isOp(srv, chan, c) then return srv:numeric(c, "482", chan.name, "You're not channel operator") end
    srv:setTopic(c, chan, m.params[2])
end

function CMD.NAMES(srv, c, m)
    if not m.params[1] then
        for _, chan in pairs(srv.channels) do
            if not chan.modes.s or member(srv, chan, c) then srv:sendNames(c, chan) end
        end
        return
    end
    for _, name in ipairs(scan.split(m.params[1], ",")) do
        local chan = srv:channel(name)
        if chan and (not chan.modes.s or member(srv, chan, c)) then srv:sendNames(c, chan)
        else srv:numeric(c, "366", name, "End of /NAMES list.") end
    end
end

function CMD.LIST(srv, c, m)
    srv:numeric(c, "321", "Channel", "Users  Name")
    local want
    if m.params[1] then
        want = {}
        for _, name in ipairs(scan.split(m.params[1], ",")) do want[srv:fold(name)] = true end
    end
    local names = {}
    for key in pairs(srv.channels) do names[#names + 1] = key end
    table.sort(names)
    for _, key in ipairs(names) do
        local chan = srv.channels[key]
        if (not want or want[key]) and (not chan.modes.s or member(srv, chan, c)) then
            srv:numeric(c, "322", chan.name, tostring(srv:countMembers(chan)), chan.topic or "")
        end
    end
    srv:numeric(c, "323", "End of /LIST")
end

function CMD.INVITE(srv, c, m)
    local who, name = srv:find(m.params[1]), m.params[2]
    if not name then return srv:numeric(c, "461", "INVITE", "Not enough parameters") end
    if not who then return srv:numeric(c, "401", m.params[1], "No such nick/channel") end
    local chan = srv:channel(name)
    if chan then
        if not member(srv, chan, c) then return srv:numeric(c, "442", chan.name, "You're not on that channel") end
        if member(srv, chan, who) then return srv:numeric(c, "443", who.nick, chan.name, "is already on channel") end
        if chan.modes.i and not isOp(srv, chan, c) then return srv:numeric(c, "482", chan.name, "You're not channel operator") end
        chan.invited[srv:fold(who.nick)] = true
    end
    srv:numeric(c, "341", who.nick, name)
    srv:send(who, srv:from(c, "INVITE", who.nick, name))
end

function CMD.KICK(srv, c, m)
    local chan, who = srv:channel(m.params[1]), srv:find(m.params[2])
    if not m.params[2] then return srv:numeric(c, "461", "KICK", "Not enough parameters") end
    if not chan then return srv:numeric(c, "403", m.params[1], "No such channel") end
    if not isOp(srv, chan, c) then return srv:numeric(c, "482", chan.name, "You're not channel operator") end
    if not who or not member(srv, chan, who) then
        return srv:numeric(c, "441", m.params[2], chan.name, "They aren't on that channel")
    end
    srv:toChannel(chan, srv:from(c, "KICK", chan.name, who.nick, m.params[3] or c.nick))
    srv:emit("part", who, chan)
    srv:leave(who, chan)
end

--------------------------------------------------------------------------
-- Modes
--------------------------------------------------------------------------
-- Which channel modes take an argument: o v b always, k when set and
-- unset, l when set.
local function takesArg(letter, adding)
    if letter == "o" or letter == "v" or letter == "b" or letter == "k" then return true end
    if letter == "l" then return adding end
    return false
end

-- Apply one change; the argument it went out with ("" for none), or nil
-- if it changed nothing.
local function applyChannelMode(srv, c, chan, adding, letter, arg)
    if letter == "o" or letter == "v" then
        local who = srv:find(arg)
        local mem = who and member(srv, chan, who)
        if not mem then srv:numeric(c, "441", arg or "*", chan.name, "They aren't on that channel"); return nil end
        local field = letter == "o" and "op" or "voice"
        if (mem[field] or false) == adding then return nil end
        mem[field] = adding or nil
        return who.nick
    elseif letter == "b" then
        if not irc.containsAny(arg, "!@") then arg = arg .. "!*@*" end
        for i, mask in ipairs(chan.bans) do
            if irc.casefold(mask) == irc.casefold(arg) then
                if adding then return nil end
                table.remove(chan.bans, i)
                return arg
            end
        end
        if not adding then return nil end
        table.insert(chan.bans, arg)
        return arg
    elseif letter == "k" then
        if adding then chan.modes.k = arg; return arg end
        if not chan.modes.k then return nil end
        chan.modes.k = nil
        return "*"
    elseif letter == "l" then
        if adding then
            local n = tonumber(arg)
            if not n or n < 1 then return nil end
            chan.modes.l = math.floor(n)
            return tostring(chan.modes.l)
        end
        if not chan.modes.l then return nil end
        chan.modes.l = nil
        return ""
    elseif ("imnst"):find(letter, 1, true) then
        if (chan.modes[letter] or false) == adding then return nil end
        chan.modes[letter] = adding or nil
        return ""
    end
    srv:numeric(c, "472", letter, "is unknown mode char to me")
    return nil
end

local function channelMode(srv, c, chan, m)
    if not m.params[2] then
        local letters, args = modeString(chan, member(srv, chan, c))
        srv:numeric(c, "324", chan.name, letters, table.unpack(args))
        srv:numeric(c, "329", chan.name, tostring(chan.created))
        return
    end
    local spec, argi = m.params[2], 3
    -- +b alone: the ban list (anyone may look)
    if (spec == "b" or spec == "+b") and not m.params[3] then
        for _, mask in ipairs(chan.bans) do srv:numeric(c, "367", chan.name, mask) end
        return srv:numeric(c, "368", chan.name, "End of channel ban list")
    end
    if not isOp(srv, chan, c) then return srv:numeric(c, "482", chan.name, "You're not channel operator") end
    local adding, done, outArgs = true, {}, {}
    local lastSign
    local changes = 0
    for i = 1, #spec do
        local ch = spec:sub(i, i)
        if ch == "+" then adding = true
        elseif ch == "-" then adding = false
        elseif changes < 4 or not takesArg(ch, adding) then
            local arg
            if takesArg(ch, adding) then
                arg = m.params[argi]
                argi = argi + 1
            end
            if takesArg(ch, adding) and not arg then
                -- (no argument for it: skipped)
            else
                if takesArg(ch, adding) then changes = changes + 1 end
                local out = applyChannelMode(srv, c, chan, adding, ch, arg)
                if out then
                    local sign = adding and "+" or "-"
                    if sign ~= lastSign then done[#done + 1] = sign; lastSign = sign end
                    done[#done + 1] = ch
                    if out ~= "" then outArgs[#outArgs + 1] = out end
                end
            end
        end
    end
    if #done == 0 then return end
    local line = srv:from(c, "MODE", chan.name, table.concat(done), table.unpack(outArgs))
    srv:toChannel(chan, line)
end

function Server:setMode(by, chan, spec, ...)
    channelMode(self, by, chan, { params = { chan.name, spec, ... } })
end

local function userMode(srv, c, m)
    local target = m.params[1]
    if srv:fold(target) ~= srv:fold(c.nick) then return srv:numeric(c, "502", "Cant change mode for other users") end
    local spec = m.params[2]
    if not spec then
        return srv:numeric(c, "221", "+" .. (c.modes.i and "i" or "") .. (c.modes.o and "o" or ""))
    end
    local adding, changed = true, {}
    local lastSign
    for i = 1, #spec do
        local ch = spec:sub(i, i)
        if ch == "+" then adding = true
        elseif ch == "-" then adding = false
        elseif ch == "i" or (ch == "o" and not adding) then
            if (c.modes[ch] or false) ~= adding then
                c.modes[ch] = adding or nil
                local sign = adding and "+" or "-"
                if sign ~= lastSign then changed[#changed + 1] = sign; lastSign = sign end
                changed[#changed + 1] = ch
            end
        elseif ch ~= "o" then
            srv:numeric(c, "501", "Unknown MODE flag")
        end
    end
    if #changed > 0 then srv:send(c, srv:from(c, "MODE", c.nick, table.concat(changed))) end
end

function CMD.MODE(srv, c, m)
    local target = m.params[1]
    if not target then return srv:numeric(c, "461", "MODE", "Not enough parameters") end
    if irc.isChannel(target, "#&") then
        local chan = srv:channel(target)
        if not chan then return srv:numeric(c, "403", target, "No such channel") end
        return channelMode(srv, c, chan, m)
    end
    if not srv:find(target) then return srv:numeric(c, "401", target, "No such nick/channel") end
    userMode(srv, c, m)
end

--------------------------------------------------------------------------
-- Messages
--------------------------------------------------------------------------
-- Why c can't speak in chan (nil: it can).
local function cantSend(srv, chan, c)
    local mem = member(srv, chan, c)
    if c.service then return nil end
    if chan.modes.n and not mem then return "no external messages (+n)" end
    if chan.modes.m and not (mem and (mem.op or mem.voice)) then return "the channel is moderated (+m)" end
    if banned(srv, chan, c) and not (mem and (mem.op or mem.voice)) then return "you are banned (+b)" end
    return nil
end

local function message(srv, c, m, notice)
    local command = notice and "NOTICE" or "PRIVMSG"
    if not m.params[1] then
        if not notice then srv:numeric(c, "411", "No recipient given (" .. command .. ")") end
        return
    end
    local text = m.params[2]
    if not text or text == "" then
        if not notice then srv:numeric(c, "412", "No text to send") end
        return
    end
    c.idleSince = srv.time()
    for _, target in ipairs(scan.split(m.params[1], ",")) do
        if irc.isChannel(target, "#&") then
            local chan = srv:channel(target)
            local why = chan and cantSend(srv, chan, c)
            if not chan then
                if not notice then srv:numeric(c, "403", target, "No such channel") end
            elseif why then
                if not notice then srv:numeric(c, "404", chan.name, "Cannot send to channel: " .. why) end
            else
                srv:toChannel(chan, srv:from(c, command, chan.name, text), c)
                srv:emit("message", c, chan, text, notice)
            end
        else
            local who = srv:find(target)
            if not who then
                if not notice then srv:numeric(c, "401", target, "No such nick/channel") end
            elseif who.service then
                if not notice then who.service(c, text) end
            else
                srv:send(who, srv:from(c, command, who.nick, text))
                if who.away and not notice then srv:numeric(c, "301", who.nick, who.away) end
            end
        end
    end
end

function CMD.PRIVMSG(srv, c, m) message(srv, c, m, false) end
function CMD.NOTICE(srv, c, m) message(srv, c, m, true) end

-- A service's NOTICE to one user, or its PRIVMSG to a channel.
function Server:notice(svc, c, text) self:send(c, self:from(svc, "NOTICE", c.nick, text)) end
function Server:say(svc, chan, text)
    self:toChannel(chan, self:from(svc, "PRIVMSG", chan.name, text), svc)
end

function CMD.AWAY(srv, c, m)
    local text = m.params[1]
    if text and text ~= "" then
        c.away = text:sub(1, 200)
        srv:numeric(c, "306", "You have been marked as being away")
    else
        c.away = nil
        srv:numeric(c, "305", "You are no longer marked as being away")
    end
end

--------------------------------------------------------------------------
-- Who's who
--------------------------------------------------------------------------
function CMD.WHOIS(srv, c, m)
    local list = m.params[2] or m.params[1]     -- (WHOIS server nick: the server is this one)
    if not list then return srv:numeric(c, "431", "No nickname given") end
    for _, nick in ipairs(scan.split(list, ",")) do
        local who = srv:find(nick)
        if not who then
            srv:numeric(c, "401", nick, "No such nick/channel")
        else
            local host = who.service and srv.name or who.host
            srv:numeric(c, "311", who.nick, who.user or "*", host, "*", who.real or "")
            local chans = {}
            for _, chan in pairs(who.channels) do
                if not chan.modes.s or member(srv, chan, c) then
                    chans[#chans + 1] = memberPrefix(member(srv, chan, who)) .. chan.name
                end
            end
            table.sort(chans)
            if #chans > 0 then srv:numeric(c, "319", who.nick, table.concat(chans, " ")) end
            srv:numeric(c, "312", who.nick, srv.name, srv.network .. " on ccnix")
            if who.modes.o then srv:numeric(c, "313", who.nick, "is an IRC operator") end
            if who.service then srv:numeric(c, "313", who.nick, "is a network service") end
            if who.away then srv:numeric(c, "301", who.nick, who.away) end
            if who.account then srv:numeric(c, "330", who.nick, who.account, "is logged in as") end
            if who.mc then srv:numeric(c, "320", who.nick, "is the Minecraft player " .. who.mc) end
            if not who.service then
                srv:numeric(c, "317", who.nick, tostring(srv.time() - who.idleSince), tostring(who.signon),
                    "seconds idle, signon time")
            end
        end
    end
    srv:numeric(c, "318", list, "End of /WHOIS list.")
end

local function whoLine(srv, c, chanName, who, mem)
    local flags = (who.away and "G" or "H") .. (who.modes.o and "*" or "") .. (mem and memberPrefix(mem) or "")
    srv:numeric(c, "352", chanName, who.user or "*", who.service and srv.name or who.host, srv.name, who.nick, flags,
        "0 " .. (who.real or ""))
end

function CMD.WHO(srv, c, m)
    local mask = m.params[1] or "*"
    local chan = irc.isChannel(mask, "#&") and srv:channel(mask)
    if chan then
        if not chan.modes.s or member(srv, chan, c) then
            for _, mem in pairs(chan.members) do whoLine(srv, c, chan.name, mem.client, mem) end
        end
    elseif not irc.isChannel(mask, "#&") then
        for _, who in pairs(srv.clients) do
            if who.registered and (not who.modes.i or who == c)
                and (irc.match(mask, who.nick) or irc.match(mask, who.host or "")) then
                whoLine(srv, c, "*", who)
            end
        end
    end
    srv:numeric(c, "315", mask, "End of /WHO list.")
end

function CMD.ISON(srv, c, m)
    local on = {}
    for _, p in ipairs(m.params) do
        for _, nick in ipairs(scan.words(p)) do
            local who = srv:find(nick)
            if who then on[#on + 1] = who.nick end
        end
    end
    srv:numeric(c, "303", table.concat(on, " "))
end

function CMD.USERHOST(srv, c, m)
    local out = {}
    for i = 1, math.min(5, #m.params) do
        local who = srv:find(m.params[i])
        if who then
            out[#out + 1] = who.nick .. (who.modes.o and "*" or "") .. "=" .. (who.away and "-" or "+")
                .. (who.user or "*") .. "@" .. (who.host or "*")
        end
    end
    srv:numeric(c, "302", table.concat(out, " "))
end

function CMD.MOTD(srv, c) srv:sendMotd(c) end
function CMD.LUSERS(srv, c) srv:sendLusers(c) end
function CMD.VERSION(srv, c) srv:numeric(c, "351", srv.version, srv.name, "ccnix") end
function CMD.TIME(srv, c)
    srv:numeric(c, "391", srv.name, os.date and os.date("%Y-%m-%d %H:%M:%S", srv.time()) or tostring(srv.time()))
end

function CMD.OPER(srv, c, m)
    if #m.params < 2 then return srv:numeric(c, "461", "OPER", "Not enough parameters") end
    if not srv.operPass or m.params[2] ~= srv.operPass then return srv:numeric(c, "464", "Password incorrect") end
    c.modes.o = true
    srv:numeric(c, "381", "You are now an IRC operator")
    srv:send(c, srv:from(c, "MODE", c.nick, "+o"))
    srv.log(c.nick .. " is an operator now")
end

function CMD.KILL(srv, c, m)
    if not c.modes.o then return srv:numeric(c, "481", "Permission Denied- You're not an IRC operator") end
    local who = srv:find(m.params[1])
    if not who then return srv:numeric(c, "401", m.params[1] or "*", "No such nick/channel") end
    if who.service then return srv:numeric(c, "483", "You can't kill a server!") end
    srv:quit(who, "Killed (" .. c.nick .. " (" .. (m.params[2] or "") .. "))")
end

--------------------------------------------------------------------------
-- Services
--------------------------------------------------------------------------
function Server:addService(nick, realname, handler)
    local svc = { id = self.nextId, nick = nick, user = nick:lower(), host = self.name, real = realname,
        modes = { o = true }, channels = {}, registered = true, service = handler,
        signon = self.time(), idleSince = self.time(), heard = self.clock() }
    self.nextId = self.nextId + 1
    self.clients[svc.id] = svc
    self.nicks[self:fold(nick)] = svc
    return svc
end

return D
