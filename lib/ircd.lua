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
-- Names compare in rfc1459 case (lib/irc).  A user quiet for 90 seconds
-- is PINGed, and dropped 90 seconds later without a PONG.
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
--
-- How it's laid out: the protocol's facts are tables, and the code reads
-- them.  REPLY names every numeric and holds its fixed text;
-- CHANNEL_MODES and USER_MODES say what each mode letter takes and does;
-- JOIN_RULES and SEND_RULES are the checks a JOIN or a message goes
-- through, in order; WHOIS_LINES are the lines a WHOIS gives; COMMANDS
-- says, for each command, how many params it needs and whether it may
-- come before registering, then what it does.

local irc = require("irc")
local scan = require("scan")
local text = require("text")
local convert = require("convert")

local D = {}
D.VERSION = "ccnix-ircd-1.0"
D.PING_AFTER, D.PING_TIMEOUT = 90, 90
D.NICKLEN, D.TOPICLEN, D.AWAYLEN, D.MAXCHANNELS = 30, 300, 200, 20

local Server = {}
Server.__index = Server

--------------------------------------------------------------------------
-- The replies: each numeric by its RFC name, and its text when that's
-- always the same (the params come before it)
--------------------------------------------------------------------------
local REPLY = {
    WELCOME           = { "001" },
    YOURHOST          = { "002" },
    CREATED           = { "003" },
    MYINFO            = { "004" },
    ISUPPORT          = { "005", "are supported by this server" },
    UMODEIS           = { "221" },
    LUSERCLIENT       = { "251" },
    LUSEROP           = { "252", "operator(s) online" },
    LUSERCHANNELS     = { "254", "channels formed" },
    LUSERME           = { "255" },
    AWAY              = { "301" },
    USERHOST          = { "302" },
    ISON              = { "303" },
    UNAWAY            = { "305", "You are no longer marked as being away" },
    NOWAWAY           = { "306", "You have been marked as being away" },
    WHOISUSER         = { "311" },
    WHOISSERVER       = { "312" },
    WHOISOPERATOR     = { "313" },
    ENDOFWHO          = { "315", "End of /WHO list." },
    WHOISIDLE         = { "317", "seconds idle, signon time" },
    ENDOFWHOIS        = { "318", "End of /WHOIS list." },
    WHOISCHANNELS     = { "319" },
    WHOISSPECIAL      = { "320" },
    LISTSTART         = { "321", "Users  Name" },
    LIST              = { "322" },
    LISTEND           = { "323", "End of /LIST" },
    CHANNELMODEIS     = { "324" },
    CREATIONTIME      = { "329" },
    WHOISACCOUNT      = { "330", "is logged in as" },
    NOTOPIC           = { "331", "No topic is set" },
    TOPIC             = { "332" },
    TOPICWHOTIME      = { "333" },
    INVITING          = { "341" },
    VERSION           = { "351" },
    WHOREPLY          = { "352" },
    NAMREPLY          = { "353" },
    ENDOFNAMES        = { "366", "End of /NAMES list." },
    BANLIST           = { "367" },
    ENDOFBANLIST      = { "368", "End of channel ban list" },
    MOTD              = { "372" },
    MOTDSTART         = { "375" },
    ENDOFMOTD         = { "376", "End of MOTD command" },
    YOUREOPER         = { "381", "You are now an IRC operator" },
    TIME              = { "391" },
    NOSUCHNICK        = { "401", "No such nick/channel" },
    NOSUCHCHANNEL     = { "403", "No such channel" },
    CANNOTSENDTOCHAN  = { "404" },
    TOOMANYCHANNELS   = { "405", "You have joined too many channels" },
    NORECIPIENT       = { "411" },
    NOTEXTTOSEND      = { "412", "No text to send" },
    UNKNOWNCOMMAND    = { "421", "Unknown command" },
    NOMOTD            = { "422", "MOTD File is missing" },
    NONICKNAMEGIVEN   = { "431", "No nickname given" },
    ERRONEUSNICKNAME  = { "432", "Erroneous nickname" },
    NICKNAMEINUSE     = { "433", "Nickname is already in use" },
    USERNOTINCHANNEL  = { "441", "They aren't on that channel" },
    NOTONCHANNEL      = { "442", "You're not on that channel" },
    USERONCHANNEL     = { "443", "is already on channel" },
    NOTREGISTERED     = { "451", "You have not registered" },
    NEEDMOREPARAMS    = { "461", "Not enough parameters" },
    ALREADYREGISTERED = { "462", "You may not reregister" },
    PASSWDMISMATCH    = { "464", "Password incorrect" },
    CHANNELISFULL     = { "471", "Cannot join channel (+l)" },
    UNKNOWNMODE       = { "472", "is unknown mode char to me" },
    INVITEONLYCHAN    = { "473", "Cannot join channel (+i)" },
    BANNEDFROMCHAN    = { "474", "Cannot join channel (+b)" },
    BADCHANNELKEY     = { "475", "Cannot join channel (+k)" },
    NOPRIVILEGES      = { "481", "Permission Denied- You're not an IRC operator" },
    CHANOPRIVSNEEDED  = { "482", "You're not channel operator" },
    CANTKILLSERVER    = { "483", "You can't kill a server!" },
    UMODEUNKNOWNFLAG  = { "501", "Unknown MODE flag" },
    USERSDONTMATCH    = { "502", "Cant change mode for other users" },
}

-- What 005 says the server is.
local function supportTokens(srv)
    return {
        "CASEMAPPING=rfc1459", "CHANTYPES=#", "PREFIX=(ov)@+", "CHANMODES=b,k,l,imnst",
        "NICKLEN=" .. D.NICKLEN, "CHANNELLEN=50", "TOPICLEN=" .. D.TOPICLEN, "AWAYLEN=" .. D.AWAYLEN,
        "CHANLIMIT=#:" .. D.MAXCHANNELS, "MODES=4", "KICKLEN=300", "NETWORK=" .. srv.network,
    }
end

-- The commands whose last param is text, so it always goes after " :".
local TEXT_COMMANDS = { PRIVMSG = true, NOTICE = true, KICK = true, PART = true, QUIT = true, TOPIC = true }

-- A member's prefixes in a channel, highest first.
local MEMBER_PREFIXES = { { field = "op", symbol = "@" }, { field = "voice", symbol = "+" } }

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
function Server:find(nick) return nick and self.nicks[self:fold(nick)] end
function Server:channel(name) return name and self.channels[self:fold(name)] end

function Server:prefixOf(c)
    if c.service then return c.nick .. "!" .. c.user .. "@" .. self.name end
    return (c.nick or "*") .. "!" .. (c.user or "*") .. "@" .. (c.host or "*")
end

function Server:send(c, line)
    if c.send and not c.dead then c.send(line) end
end

-- A message from the server itself: ":name command params..."
function Server:fromServer(c, command, ...)
    self:send(c, ":" .. self.name .. " " .. irc.build(command, ...))
end

-- A numeric reply by its name: ":name 401 nick params... :text", the
-- reply's own text after the params when it has one.
function Server:numeric(c, name, ...)
    local reply = assert(REPLY[name], "no reply " .. tostring(name))
    local params = { ... }
    if reply[2] then params[#params + 1] = reply[2] end
    self:send(c, ":" .. self.name .. " " .. irc.buildTrailing(reply[1], c.nick or "*", table.unpack(params)))
end

-- A line from src (as nick!user@host) for whoever gets it.
function Server:from(src, command, ...)
    local build = (TEXT_COMMANDS[command] and select("#", ...) > 1) and irc.buildTrailing or irc.build
    return ":" .. self:prefixOf(src) .. " " .. build(command, ...)
end

function Server:toChannel(chan, line, except)
    for _, mem in pairs(chan.members) do
        if mem.client ~= except then self:send(mem.client, line) end
    end
end

-- Everyone who shares a channel with c (and c), once each.
function Server:peers(c)
    local seen, out = { [c] = true }, { c }
    for _, chan in pairs(c.channels) do
        for _, mem in pairs(chan.members) do
            if not seen[mem.client] then seen[mem.client] = true; out[#out + 1] = mem.client end
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

-- A service's NOTICE to one user, or its PRIVMSG to a channel.
function Server:notice(svc, c, body) self:send(c, self:from(svc, "NOTICE", c.nick, body)) end
function Server:say(svc, chan, body) self:toChannel(chan, self:from(svc, "PRIVMSG", chan.name, body), svc) end

local function count(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

--------------------------------------------------------------------------
-- Connections
--------------------------------------------------------------------------
local COMMANDS = {}

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

-- One line from a client: its command, if it may run it and gave enough.
function Server:input(c, line)
    if c.dead then return end
    c.heard, c.pingOut = self.clock(), nil
    local m = irc.parse(text.truncate(line, irc.MAX_LINE - 2))
    if not m then return end
    local cmd = COMMANDS[m.command]
    if not cmd then
        if c.registered then self:numeric(c, "UNKNOWNCOMMAND", m.command) end
    elseif not c.registered and not cmd.early then
        self:numeric(c, "NOTREGISTERED")
    elseif #m.params < cmd.min then
        self:numeric(c, "NEEDMOREPARAMS", m.command)
    else
        cmd.run(self, c, m.params)
    end
end

-- The connection went (or the server drops it): QUIT to the others.
function Server:closed(c, why)
    if self.clients[c.id] then self:quit(c, why or "Connection closed") end
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
    if self:find(c.nick) == c then self.nicks[self:fold(c.nick)] = nil end
    self:send(c, "ERROR :Closing link: " .. (c.host or "") .. " (" .. why .. ")")
    self.clients[c.id] = nil
    c.dead = true
end

function Server:kill(c, why) self:quit(c, why) end

-- Each second: a PING for the quiet, the end for those that didn't answer.
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
function Server:sendMotd(c)
    if not self.motd or #self.motd == 0 then return self:numeric(c, "NOMOTD") end
    self:numeric(c, "MOTDSTART", "- " .. self.name .. " Message of the day - ")
    for _, line in ipairs(self.motd) do self:numeric(c, "MOTD", "- " .. line) end
    self:numeric(c, "ENDOFMOTD")
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
    self:numeric(c, "LUSERCLIENT", "There are " .. (users - invisible) .. " users and " .. invisible .. " invisible on 1 servers")
    if opers > 0 then self:numeric(c, "LUSEROP", opers) end
    self:numeric(c, "LUSERCHANNELS", count(self.channels))
    self:numeric(c, "LUSERME", "I have " .. users .. " clients and 0 servers")
end

-- Registered once it has a nick and a user (and CAP is done): the welcome.
local function tryRegister(srv, c)
    if c.registered or not c.nick or not c.user or c.capping then return end
    if srv.password and c.pass ~= srv.password then
        srv:numeric(c, "PASSWDMISMATCH")
        return srv:quit(c, "Bad password")
    end
    c.registered = true
    srv:numeric(c, "WELCOME", "Welcome to the " .. srv.network .. " IRC network " .. srv:prefixOf(c))
    srv:numeric(c, "YOURHOST", "Your host is " .. srv.name .. ", running version " .. srv.version)
    srv:numeric(c, "CREATED", "This server was created " .. srv.created)
    srv:send(c, ":" .. srv.name .. " 004 " .. c.nick .. " " .. srv.name .. " " .. srv.version .. " io biklmnostv")
    srv:numeric(c, "ISUPPORT", table.unpack(supportTokens(srv)))
    srv:sendLusers(c)
    srv:sendMotd(c)
    srv.log(c.nick .. "!" .. c.user .. "@" .. c.host .. " connected")
    srv:emit("registered", c)
end

-- Give c the nick (that it's free is already checked).
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
        chan.members[srv:fold(nick)], chan.members[srv:fold(old)] = chan.members[srv:fold(old)], nil
    end
    if c.registered then srv:emit("nick", c, old) end
end

function Server:forceNick(c, nick)
    if self:find(nick) then return false end
    setNick(self, c, nick)
    return true
end

-- A user name as given, kept to letters, digits, - . and _, ten at most.
local USER_CHAR = scan.oneOf("-._")
local function cleanUserName(given)
    local kept = {}
    for i = 1, #given do
        local ch = given:sub(i, i)
        if scan.isAlnum(ch) or USER_CHAR(ch) then kept[#kept + 1] = ch end
    end
    local user = text.truncate(table.concat(kept), 10)
    return user ~= "" and user or "user"
end

-- CAP's subcommands: there are no capabilities to offer, but a client
-- that asks is answered, and waits for its own CAP END to register.
local CAP = {
    LS = function(srv, c)
        c.capping = not c.registered
        srv:fromServer(c, "CAP", c.nick or "*", "LS", "")
    end,
    LIST = function(srv, c) srv:fromServer(c, "CAP", c.nick or "*", "LIST", "") end,
    REQ = function(srv, c, p) srv:fromServer(c, "CAP", c.nick or "*", "NAK", p[2] or "") end,
    END = function(srv, c)
        c.capping = nil
        tryRegister(srv, c)
    end,
}

--------------------------------------------------------------------------
-- Channels
--------------------------------------------------------------------------
local function member(srv, chan, c) return c and c.nick and chan.members[srv:fold(c.nick)] end

local function isOp(srv, chan, c)
    if c.service then return true end
    local mem = member(srv, chan, c)
    return mem ~= nil and mem.op == true
end

local function isVoiced(mem) return mem ~= nil and (mem.op or mem.voice) == true end

local function memberPrefix(mem)
    local out = {}
    for _, p in ipairs(MEMBER_PREFIXES) do
        if mem[p.field] then out[#out + 1] = p.symbol end
    end
    return table.concat(out)
end

local function isBanned(srv, chan, c)
    local full = srv:prefixOf(c)
    for _, mask in ipairs(chan.bans) do
        if irc.match(mask, full) then return true end
    end
    return false
end

-- Can c see this channel (in a list, its names)?  Not a secret one it isn't in.
local function canSee(srv, chan, c) return not chan.modes.s or member(srv, chan, c) ~= nil end

function Server:countMembers(chan) return count(chan.members) end

function Server:sendNames(c, chan)
    local names = {}
    local inside = member(self, chan, c)
    for _, mem in pairs(chan.members) do
        if inside or not mem.client.modes.i then names[#names + 1] = memberPrefix(mem) .. mem.client.nick end
    end
    table.sort(names)
    -- in lines that stay well under 512 bytes
    local line, size = {}, 0
    local function flush()
        if #line > 0 then self:numeric(c, "NAMREPLY", chan.modes.s and "@" or "=", chan.name, text.join(line, " ")) end
        line, size = {}, 0
    end
    for _, n in ipairs(names) do
        if size + #n > 400 then flush() end
        line[#line + 1] = n
        size = size + #n + 1
    end
    flush()
    self:numeric(c, "ENDOFNAMES", chan.name)
end

function Server:sendTopic(c, chan)
    if not chan.topic or chan.topic == "" then return self:numeric(c, "NOTOPIC", chan.name) end
    self:numeric(c, "TOPIC", chan.name, chan.topic)
    self:numeric(c, "TOPICWHOTIME", chan.name, chan.topicBy or self.name, tostring(chan.topicAt or chan.created))
end

local function newChannel(srv, name)
    local chan = { name = name, members = {}, modes = { n = true, t = true }, bans = {}, invited = {}, created = srv.time() }
    srv.channels[srv:fold(name)] = chan
    srv:emit("create", chan)
    return chan
end

-- c into the channel (made if it isn't there), without the checks.
function Server:join(c, name)
    local chan = self:channel(name)
    local fresh = chan == nil
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

-- c out of the channel, with a PART to everyone in it.
local function part(srv, c, chan, reason)
    srv:toChannel(chan, srv:from(c, "PART", chan.name, reason))
    srv:emit("part", c, chan)
    srv:leave(c, chan)
end

function Server:setTopic(by, chan, topic)
    chan.topic, chan.topicBy, chan.topicAt = text.truncate(topic, D.TOPICLEN), by.nick, self.time()
    self:toChannel(chan, self:from(by, "TOPIC", chan.name, chan.topic))
    self:emit("topic", by, chan)
end

-- The checks a JOIN to a channel that's there goes through, in order:
-- the first that holds refuses it with its reply.  try: { key, invited,
-- banned }.
local JOIN_RULES = {
    { "BADCHANNELKEY",  function(srv, chan, try) return chan.modes.k ~= nil and try.key ~= chan.modes.k end },
    { "INVITEONLYCHAN", function(srv, chan, try) return chan.modes.i and not try.invited end },
    { "CHANNELISFULL",  function(srv, chan, try) return chan.modes.l ~= nil and not try.invited and srv:countMembers(chan) >= chan.modes.l end },
    { "BANNEDFROMCHAN", function(srv, chan, try) return not try.invited and try.banned end },
}

-- Why c can't join name (the reply's name), or nil.
local function joinRefusal(srv, c, name, key)
    if not irc.validChannel(name, "#") then return "NOSUCHCHANNEL" end
    if count(c.channels) >= D.MAXCHANNELS then return "TOOMANYCHANNELS" end
    local chan = srv:channel(name)
    if not chan then return nil end
    local try = { key = key, invited = chan.invited[srv:fold(c.nick)], banned = isBanned(srv, chan, c) }
    for _, rule in ipairs(JOIN_RULES) do
        if rule[2](srv, chan, try) then return rule[1] end
    end
    return nil
end

--------------------------------------------------------------------------
-- Modes
--------------------------------------------------------------------------
-- A ban mask as given, made whole: a nick alone is nick!*@*.
local function wholeMask(arg) return irc.containsAny(arg, "!@") and arg or (arg .. "!*@*") end

local function findBan(chan, mask)
    for i, m in ipairs(chan.bans) do
        if irc.casefold(m) == irc.casefold(mask) then return i end
    end
    return nil
end

-- A mode that's a member's flag (o: op, v: voice): its argument is the nick.
local function memberMode(field)
    return function(srv, c, chan, adding, arg)
        local who = srv:find(arg)
        local mem = who and member(srv, chan, who)
        if not mem then srv:numeric(c, "USERNOTINCHANNEL", arg, chan.name); return nil end
        if (mem[field] or false) == adding then return nil end
        mem[field] = adding or nil
        return who.nick
    end
end

-- A mode that's the channel's flag (i m n s t): on or off.
local function flagMode(srv, c, chan, adding, _, letter)
    if (chan.modes[letter] or false) == adding then return nil end
    chan.modes[letter] = adding or nil
    return ""
end

-- Each channel mode: when it takes an argument ("always", or "set": only
-- being set), and apply(srv, c, chan, adding, arg, letter), which makes
-- the change and returns the argument it goes out with ("" for none), or
-- nil if nothing changed.
local CHANNEL_MODES = {
    o = { arg = "always", apply = memberMode("op") },
    v = { arg = "always", apply = memberMode("voice") },
    b = { arg = "always", apply = function(srv, c, chan, adding, arg)
        local mask = wholeMask(arg)
        local at = findBan(chan, mask)
        if adding == (at ~= nil) then return nil end
        if adding then table.insert(chan.bans, mask) else table.remove(chan.bans, at) end
        return mask
    end },
    k = { arg = "always", apply = function(srv, c, chan, adding, arg)
        if adding then chan.modes.k = arg; return arg end
        if not chan.modes.k then return nil end
        chan.modes.k = nil
        return "*"
    end },
    l = { arg = "set", apply = function(srv, c, chan, adding, arg)
        if not adding then
            if not chan.modes.l then return nil end
            chan.modes.l = nil
            return ""
        end
        local n = convert.toInteger(arg)
        if not n or n < 1 then return nil end
        chan.modes.l = n
        return tostring(chan.modes.l)
    end },
    i = { apply = flagMode }, m = { apply = flagMode }, n = { apply = flagMode },
    s = { apply = flagMode }, t = { apply = flagMode },
}
local CHANNEL_FLAGS = { "i", "m", "n", "s", "t" }      -- (in the order MODE shows them)
D.MAX_MODE_ARGS = 4                                    -- changes with an argument in one MODE

local function takesArg(mode, adding) return mode.arg == "always" or (mode.arg == "set" and adding) end

-- The channel's modes as "+ntk", and their arguments (the key only for members).
local function modeString(chan, showKey)
    local letters, args = { "+" }, {}
    for _, l in ipairs(CHANNEL_FLAGS) do
        if chan.modes[l] then letters[#letters + 1] = l end
    end
    if chan.modes.k then letters[#letters + 1] = "k"; args[#args + 1] = showKey and chan.modes.k or "*" end
    if chan.modes.l then letters[#letters + 1] = "l"; args[#args + 1] = tostring(chan.modes.l) end
    return table.concat(letters), args
end

-- The changes made, as MODE writes them: "+o-v" and the arguments.
local function newChangeList()
    local list = { letters = {}, args = {} }
    function list.add(adding, letter, arg)
        local sign = adding and "+" or "-"
        if sign ~= list.sign then list.letters[#list.letters + 1] = sign; list.sign = sign end
        list.letters[#list.letters + 1] = letter
        if arg ~= "" then list.args[#list.args + 1] = arg end
    end
    return list
end

-- MODE #chan [changes [args]]: show the modes, the ban list, or change them.
local function channelMode(srv, c, chan, p)
    local spec = p[2]
    if not spec then
        local letters, args = modeString(chan, member(srv, chan, c))
        srv:numeric(c, "CHANNELMODEIS", chan.name, letters, table.unpack(args))
        return srv:numeric(c, "CREATIONTIME", chan.name, tostring(chan.created))
    end
    if (spec == "b" or spec == "+b") and not p[3] then           -- (the ban list: anyone may look)
        for _, mask in ipairs(chan.bans) do srv:numeric(c, "BANLIST", chan.name, mask) end
        return srv:numeric(c, "ENDOFBANLIST", chan.name)
    end
    if not isOp(srv, chan, c) then return srv:numeric(c, "CHANOPRIVSNEEDED", chan.name) end
    local adding, nextArg, withArgs = true, 3, 0
    local done = newChangeList()
    for i = 1, #spec do
        local letter = spec:sub(i, i)
        local mode = CHANNEL_MODES[letter]
        if letter == "+" or letter == "-" then
            adding = letter == "+"
        elseif not mode then
            srv:numeric(c, "UNKNOWNMODE", letter)
        elseif not takesArg(mode, adding) then
            local out = mode.apply(srv, c, chan, adding, nil, letter)
            if out then done.add(adding, letter, out) end
        elseif withArgs < D.MAX_MODE_ARGS and p[nextArg] then
            local arg = p[nextArg]
            nextArg, withArgs = nextArg + 1, withArgs + 1
            local out = mode.apply(srv, c, chan, adding, arg, letter)
            if out then done.add(adding, letter, out) end
        end
    end
    if #done.letters > 0 then
        srv:toChannel(chan, srv:from(c, "MODE", chan.name, table.concat(done.letters), table.unpack(done.args)))
    end
end

function Server:setMode(by, chan, spec, ...)
    channelMode(self, by, chan, { chan.name, spec, ... })
end

-- The user modes: whether a user may set and unset each on itself (+o
-- only comes from OPER).
local USER_MODES = {
    i = { set = true, unset = true },
    o = { set = false, unset = true },
}

local function userModeString(c)
    local out = { "+" }
    for _, l in ipairs({ "i", "o" }) do
        if c.modes[l] then out[#out + 1] = l end
    end
    return table.concat(out)
end

-- MODE nick [changes]: one's own modes.
local function userMode(srv, c, p)
    if srv:fold(p[1]) ~= srv:fold(c.nick) then return srv:numeric(c, "USERSDONTMATCH") end
    local spec = p[2]
    if not spec then return srv:numeric(c, "UMODEIS", userModeString(c)) end
    local adding = true
    local done = newChangeList()
    for i = 1, #spec do
        local letter = spec:sub(i, i)
        local mode = USER_MODES[letter]
        if letter == "+" or letter == "-" then
            adding = letter == "+"
        elseif not mode then
            srv:numeric(c, "UMODEUNKNOWNFLAG")
        elseif (adding and mode.set or not adding and mode.unset) and (c.modes[letter] or false) ~= adding then
            c.modes[letter] = adding or nil
            done.add(adding, letter, "")
        end
    end
    if #done.letters > 0 then srv:send(c, srv:from(c, "MODE", c.nick, table.concat(done.letters))) end
end

--------------------------------------------------------------------------
-- Messages
--------------------------------------------------------------------------
-- The checks a message to a channel goes through, in order: the first
-- that holds keeps it out, and says why.
local SEND_RULES = {
    { "no external messages (+n)",    function(chan, mem) return chan.modes.n and mem == nil end },
    { "the channel is moderated (+m)", function(chan, mem) return chan.modes.m and not isVoiced(mem) end },
    { "you are banned (+b)",          function(chan, mem, banned) return banned and not isVoiced(mem) end },
}

-- Why c can't speak in chan, or nil.
local function sendRefusal(srv, chan, c)
    if c.service then return nil end
    local mem, banned = member(srv, chan, c), isBanned(srv, chan, c)
    for _, rule in ipairs(SEND_RULES) do
        if rule[2](chan, mem, banned) then return rule[1] end
    end
    return nil
end

-- PRIVMSG or NOTICE to each target.  A NOTICE never brings an error back.
local function message(srv, c, p, command)
    local notice = command == "NOTICE"
    local function complain(...) if not notice then srv:numeric(c, ...) end end
    if not p[1] then return complain("NORECIPIENT", "No recipient given (" .. command .. ")") end
    local body = p[2]
    if not body or body == "" then return complain("NOTEXTTOSEND") end
    c.idleSince = srv.time()
    for _, target in ipairs(text.split(p[1], ",")) do
        if irc.isChannel(target, "#&") then
            local chan = srv:channel(target)
            local why = chan and sendRefusal(srv, chan, c)
            if not chan then complain("NOSUCHCHANNEL", target)
            elseif why then complain("CANNOTSENDTOCHAN", chan.name, "Cannot send to channel: " .. why)
            else
                srv:toChannel(chan, srv:from(c, command, chan.name, body), c)
                srv:emit("message", c, chan, body, notice)
            end
        else
            local who = srv:find(target)
            if not who then complain("NOSUCHNICK", target)
            elseif who.service then
                if not notice then who.service(c, body) end
            else
                srv:send(who, srv:from(c, command, who.nick, body))
                if who.away then complain("AWAY", who.nick, who.away) end
            end
        end
    end
end

--------------------------------------------------------------------------
-- Who's who
--------------------------------------------------------------------------
-- The lines a WHOIS gives after the user and channel lines, each when
-- it applies: get(srv, who) returns its params, or nil to leave it out.
local WHOIS_LINES = {
    { "WHOISSERVER",   function(srv) return srv.name, srv.network .. " on ccnix" end },
    { "WHOISOPERATOR", function(_, who) return who.modes.o and not who.service and "is an IRC operator" or nil end },
    { "WHOISOPERATOR", function(_, who) return who.service and "is a network service" or nil end },
    { "AWAY",          function(_, who) return who.away end },
    { "WHOISACCOUNT",  function(_, who) return who.account end },
    { "WHOISSPECIAL",  function(_, who) return who.mc and ("is the Minecraft player " .. who.mc) or nil end },
    { "WHOISIDLE",     function(srv, who)
        if who.service then return nil end
        return tostring(srv.time() - who.idleSince), tostring(who.signon)
    end },
}

local function whois(srv, c, who)
    srv:numeric(c, "WHOISUSER", who.nick, who.user or "*", who.service and srv.name or who.host, "*", who.real or "")
    local chans = {}
    for _, chan in pairs(who.channels) do
        if canSee(srv, chan, c) then chans[#chans + 1] = memberPrefix(member(srv, chan, who)) .. chan.name end
    end
    table.sort(chans)
    if #chans > 0 then srv:numeric(c, "WHOISCHANNELS", who.nick, text.join(chans, " ")) end
    for _, line in ipairs(WHOIS_LINES) do
        local params = { line[2](srv, who) }
        if params[1] then srv:numeric(c, line[1], who.nick, table.unpack(params)) end
    end
end

local function whoLine(srv, c, chanName, who, mem)
    local flags = (who.away and "G" or "H") .. (who.modes.o and "*" or "") .. (mem and memberPrefix(mem) or "")
    srv:numeric(c, "WHOREPLY", chanName, who.user or "*", who.service and srv.name or who.host, srv.name, who.nick,
        flags, "0 " .. (who.real or ""))
end

--------------------------------------------------------------------------
-- The commands: COMMANDS.NAME = { min = params it needs, early = it may
-- come before registering, run = function(srv, c, params) }
--------------------------------------------------------------------------
local function command(name, min, run, early)
    COMMANDS[name] = { min = min, run = run, early = early }
end

command("CAP", 1, function(srv, c, p)
    local sub = CAP[p[1]:upper()]
    if sub then sub(srv, c, p) end
end, true)

command("PASS", 1, function(srv, c, p)
    if c.registered then return srv:numeric(c, "ALREADYREGISTERED") end
    c.pass = p[1]
end, true)

command("NICK", 0, function(srv, c, p)
    local nick = p[1]
    if not nick or nick == "" then return srv:numeric(c, "NONICKNAMEGIVEN") end
    if not irc.validNick(nick, D.NICKLEN) then return srv:numeric(c, "ERRONEUSNICKNAME", nick) end
    local holder = srv:find(nick)
    if holder and holder ~= c then return srv:numeric(c, "NICKNAMEINUSE", nick) end
    if holder == c and c.nick == nick then return end
    setNick(srv, c, nick)
    tryRegister(srv, c)
end, true)

command("USER", 4, function(srv, c, p)
    if c.registered then return srv:numeric(c, "ALREADYREGISTERED") end
    c.user, c.real = cleanUserName(p[1]), p[4]
    tryRegister(srv, c)
end, true)

command("PING", 0, function(srv, c, p) srv:fromServer(c, "PONG", srv.name, p[1] or srv.name) end, true)
command("PONG", 0, function() end, true)          -- (input() already noted it)
command("QUIT", 0, function(srv, c, p) srv:quit(c, "Quit: " .. (p[1] or "")) end, true)

command("JOIN", 1, function(srv, c, p)
    if p[1] == "0" then                                -- JOIN 0: out of them all
        for _, chan in pairs(c.channels) do part(srv, c, chan, "Left all channels") end
        return
    end
    local keys = text.split(p[2] or "", ",")
    for i, name in ipairs(text.split(p[1], ",")) do
        local chan = srv:channel(name)
        if not (chan and member(srv, chan, c)) then
            local refused = joinRefusal(srv, c, name, keys[i])
            if refused then srv:numeric(c, refused, name) else srv:join(c, name) end
        end
    end
end)

command("PART", 1, function(srv, c, p)
    for _, name in ipairs(text.split(p[1], ",")) do
        local chan = srv:channel(name)
        if not chan then srv:numeric(c, "NOSUCHCHANNEL", name)
        elseif not member(srv, chan, c) then srv:numeric(c, "NOTONCHANNEL", name)
        else part(srv, c, chan, p[2]) end
    end
end)

command("TOPIC", 1, function(srv, c, p)
    local chan = srv:channel(p[1])
    if not chan then return srv:numeric(c, "NOSUCHCHANNEL", p[1]) end
    if not p[2] then
        if not canSee(srv, chan, c) then return srv:numeric(c, "NOTONCHANNEL", chan.name) end
        return srv:sendTopic(c, chan)
    end
    if not member(srv, chan, c) then return srv:numeric(c, "NOTONCHANNEL", chan.name) end
    if chan.modes.t and not isOp(srv, chan, c) then return srv:numeric(c, "CHANOPRIVSNEEDED", chan.name) end
    srv:setTopic(c, chan, p[2])
end)

command("NAMES", 0, function(srv, c, p)
    if not p[1] then
        for _, chan in pairs(srv.channels) do
            if canSee(srv, chan, c) then srv:sendNames(c, chan) end
        end
        return
    end
    for _, name in ipairs(text.split(p[1], ",")) do
        local chan = srv:channel(name)
        if chan and canSee(srv, chan, c) then srv:sendNames(c, chan) else srv:numeric(c, "ENDOFNAMES", name) end
    end
end)

command("LIST", 0, function(srv, c, p)
    srv:numeric(c, "LISTSTART", "Channel")
    local want
    if p[1] then
        want = {}
        for _, name in ipairs(text.split(p[1], ",")) do want[srv:fold(name)] = true end
    end
    local keys = {}
    for key in pairs(srv.channels) do keys[#keys + 1] = key end
    table.sort(keys)
    for _, key in ipairs(keys) do
        local chan = srv.channels[key]
        if (not want or want[key]) and canSee(srv, chan, c) then
            srv:numeric(c, "LIST", chan.name, tostring(srv:countMembers(chan)), chan.topic or "")
        end
    end
    srv:numeric(c, "LISTEND")
end)

command("INVITE", 2, function(srv, c, p)
    local who, name = srv:find(p[1]), p[2]
    if not who then return srv:numeric(c, "NOSUCHNICK", p[1]) end
    local chan = srv:channel(name)
    if chan then
        if not member(srv, chan, c) then return srv:numeric(c, "NOTONCHANNEL", chan.name) end
        if member(srv, chan, who) then return srv:numeric(c, "USERONCHANNEL", who.nick, chan.name) end
        if chan.modes.i and not isOp(srv, chan, c) then return srv:numeric(c, "CHANOPRIVSNEEDED", chan.name) end
        chan.invited[srv:fold(who.nick)] = true
    end
    srv:numeric(c, "INVITING", who.nick, name)
    srv:send(who, srv:from(c, "INVITE", who.nick, name))
end)

command("KICK", 2, function(srv, c, p)
    local chan, who = srv:channel(p[1]), srv:find(p[2])
    if not chan then return srv:numeric(c, "NOSUCHCHANNEL", p[1]) end
    if not isOp(srv, chan, c) then return srv:numeric(c, "CHANOPRIVSNEEDED", chan.name) end
    if not (who and member(srv, chan, who)) then return srv:numeric(c, "USERNOTINCHANNEL", p[2], chan.name) end
    srv:toChannel(chan, srv:from(c, "KICK", chan.name, who.nick, p[3] or c.nick))
    srv:emit("part", who, chan)
    srv:leave(who, chan)
end)

command("MODE", 1, function(srv, c, p)
    if irc.isChannel(p[1], "#&") then
        local chan = srv:channel(p[1])
        if not chan then return srv:numeric(c, "NOSUCHCHANNEL", p[1]) end
        return channelMode(srv, c, chan, p)
    end
    if not srv:find(p[1]) then return srv:numeric(c, "NOSUCHNICK", p[1]) end
    userMode(srv, c, p)
end)

command("PRIVMSG", 0, function(srv, c, p) message(srv, c, p, "PRIVMSG") end)
command("NOTICE", 0, function(srv, c, p) message(srv, c, p, "NOTICE") end)

command("AWAY", 0, function(srv, c, p)
    if p[1] and p[1] ~= "" then
        c.away = text.truncate(p[1], D.AWAYLEN)
        srv:numeric(c, "NOWAWAY")
    else
        c.away = nil
        srv:numeric(c, "UNAWAY")
    end
end)

command("WHOIS", 0, function(srv, c, p)
    local list = p[2] or p[1]                         -- (WHOIS server nick: the server is this one)
    if not list then return srv:numeric(c, "NONICKNAMEGIVEN") end
    for _, nick in ipairs(text.split(list, ",")) do
        local who = srv:find(nick)
        if who then whois(srv, c, who) else srv:numeric(c, "NOSUCHNICK", nick) end
    end
    srv:numeric(c, "ENDOFWHOIS", list)
end)

command("WHO", 0, function(srv, c, p)
    local mask = p[1] or "*"
    if irc.isChannel(mask, "#&") then
        local chan = srv:channel(mask)
        if chan and canSee(srv, chan, c) then
            for _, mem in pairs(chan.members) do whoLine(srv, c, chan.name, mem.client, mem) end
        end
    else
        for _, who in pairs(srv.clients) do
            local visible = who.registered and (not who.modes.i or who == c)
            if visible and (irc.match(mask, who.nick) or irc.match(mask, who.host or "")) then whoLine(srv, c, "*", who) end
        end
    end
    srv:numeric(c, "ENDOFWHO", mask)
end)

command("ISON", 1, function(srv, c, p)
    local on = {}
    for _, param in ipairs(p) do
        for _, nick in ipairs(text.words(param)) do
            local who = srv:find(nick)
            if who then on[#on + 1] = who.nick end
        end
    end
    srv:numeric(c, "ISON", text.join(on, " "))
end)

command("USERHOST", 1, function(srv, c, p)
    local out = {}
    for i = 1, math.min(5, #p) do
        local who = srv:find(p[i])
        if who then
            out[#out + 1] = who.nick .. (who.modes.o and "*" or "") .. "=" .. (who.away and "-" or "+")
                .. (who.user or "*") .. "@" .. (who.host or "*")
        end
    end
    srv:numeric(c, "USERHOST", text.join(out, " "))
end)

command("MOTD", 0, function(srv, c) srv:sendMotd(c) end)
command("LUSERS", 0, function(srv, c) srv:sendLusers(c) end)
command("VERSION", 0, function(srv, c) srv:numeric(c, "VERSION", srv.version, srv.name, "ccnix") end)
command("TIME", 0, function(srv, c)
    srv:numeric(c, "TIME", srv.name, os.date and os.date("%Y-%m-%d %H:%M:%S", srv.time()) or tostring(srv.time()))
end)

command("OPER", 2, function(srv, c, p)
    if not srv.operPass or p[2] ~= srv.operPass then return srv:numeric(c, "PASSWDMISMATCH") end
    c.modes.o = true
    srv:numeric(c, "YOUREOPER")
    srv:send(c, srv:from(c, "MODE", c.nick, "+o"))
    srv.log(c.nick .. " is an operator now")
end)

command("KILL", 1, function(srv, c, p)
    if not c.modes.o then return srv:numeric(c, "NOPRIVILEGES") end
    local who = srv:find(p[1])
    if not who then return srv:numeric(c, "NOSUCHNICK", p[1]) end
    if who.service then return srv:numeric(c, "CANTKILLSERVER") end
    srv:quit(who, "Killed (" .. c.nick .. " (" .. (p[2] or "") .. "))")
end)

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

D.REPLY, D.COMMANDS, D.CHANNEL_MODES, D.USER_MODES = REPLY, COMMANDS, CHANNEL_MODES, USER_MODES
return D
