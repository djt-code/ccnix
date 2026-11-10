-- ircclient.lua -- an IRC client's heart: servers, buffers, commands, settings, scripts (bin/irc)
--
--   local ircclient = require("ircclient")
--   local client = ircclient.new({ home = "/.irc" })
--   client:command("/connect irc.libera.chat")   -- what's typed, a command or text
--   client:event(table.unpack(ev))               -- each CC event (the servers' coroutines, timers)
--   -- client.buffers, client.current, client.dirty (redraw): lib/ircui draws them
--
-- Nothing here draws.  The screen (lib/ircui) shows client.buffers and
-- passes typed lines to client:command().  Each server connection runs
-- in a coroutine of its own (connecting and reading wait, the screen
-- doesn't): client:event() steps them with every event, as parallel
-- does.  opts: home (where config, scripts/ and scripts/autorun/ are),
-- scriptDirs (more folders to find scripts in: the ones that come with
-- ccnix), connect(host, port, timeout) (lib/net's, by default), speaker
-- (a speaker peripheral, for the hilight bell), noConfig (start empty,
-- write nothing: for tests).
--
-- Buffers (weechat's word; irssi's windows): the core buffer (1, what the
-- client itself says), one for each server, channel and query.  Each has
-- lines ({ time, prefix, prefixColour, text, level, hilight }), the text
-- with mIRC formatting codes (lib/irc), an activity (0 none, 1 joins and
-- such, 2 messages, 3 your nick or a private message) while it isn't
-- the one shown, a topic and nicks for a channel.
--
-- Scripts, irssi's way: a Lua file that registers what it wants with the
-- irc table it's given (`help irc` has the list):
--   irc.signal_add("message public", function(server, text, nick, address, target) ... end)
--   irc.command_bind("hello", function(args, server, buffer) buffer:print("hi " .. args) end, "say hi")
--   irc.settings_add_str("hello_word", "hi", "what hello says")
--   irc.timeout_add(5000, function() ... end)
-- and unloading takes all of it away again.  Signals are emitted with
-- client:emit(name, ...); a handler calling irc.signal_stop() stops the
-- rest, and the client's own handling of "event <command>" and "send
-- text"/"send command" too.

local irc = require("irc")
local scan = require("scan")
local text = require("text")
local convert = require("convert")
local glob = require("glob")
local path = require("path")
local tables = require("tables")
local fileio = require("fileio")

local C = {}
C.VERSION = "1.0"
C.SCROLLBACK = 500

-- The activity each level of message gives a buffer not on the screen.
C.ACTIVITY = { crap = 1, joins = 1, parts = 1, quits = 1, nicks = 1, modes = 1, topics = 1, kicks = 1,
    notices = 2, public = 2, actions = 2, private = 3, hilight = 3, error = 1, own = 0 }

-- Colours for nicks (mIRC numbers): a nick always gets the same one
C.NICK_COLOURS = { 3, 4, 5, 6, 7, 8, 9, 10, 12, 13 }

-- The settings, with their types, defaults and what they do.
C.SETTINGS = {
    { "nick", "str", nil, "your nick (the computer's label, else cc<ID>)" },
    { "alt_nick", "str", nil, "the nick to try when that one's taken (nick_)" },
    { "user_name", "str", "ccnix", "the user name the server is told" },
    { "real_name", "str", "ccnix irc on ComputerCraft", "the real name WHOIS shows" },
    { "quit_message", "str", "ccnix irc: IRC from inside Minecraft", "what /quit says" },
    { "part_message", "str", "", "what /part says when it's given nothing" },
    { "away_message", "str", "away", "what /away says when it's given nothing" },
    { "timestamp_format", "str", "%H:%M", "the time before each line (os.date's format; \"\" for none)" },
    { "timestamp_clock", "str", "real", "real, or game: the world's clock" },
    { "prefix_width", "int", 9, "the column nicks are lined up in (0: <nick> text, as irssi)" },
    { "hilight_words", "str", "", "words that hilight a line, besides your nick (spaces between)" },
    { "beep_on_hilight", "bool", true, "a speaker, if there's one, chimes at a hilight or a private message" },
    { "scrollback", "int", C.SCROLLBACK, "lines kept in each buffer" },
    { "buflist", "str", "auto", "the buffer list on the left: on, off, or auto (a wide screen)" },
    { "nicklist", "str", "auto", "the nick list on the right: on, off, or auto (a wide screen)" },
    { "reconnect_time", "int", 30, "seconds before connecting again after a lost connection (0: never)" },
    { "autojoin_on_invite", "bool", false, "join a channel you're invited to" },
    { "show_banner", "bool", true, "the banner at the start" },
    { "scripts", "str", "", "scripts loaded at the start (spaces between), besides scripts/autorun/" },
    { "ctcp_version", "str", nil, "the answer to CTCP VERSION" },
}

-- Aliases that come with it ($0 the first word given, $1- the rest from
-- the second, $* all of it, $C the channel, $N your nick).
C.ALIASES = {
    j = "join $*", wc = "window close", q = "query $*", w = "whois $*", t = "topic $*",
    k = "kick $*", m = "msg $*", n = "names $*", ns = "msg NickServ $*", cs = "msg ChanServ $*",
    mc = "msg MC $*", wi = "whois $0 $0", ws = "window $*", leave = "part $*", exit = "quit $*",
    raw = "quote $*", bye = "quit $*", signoff = "quit $*", ["umode"] = "mode $N $*",
}

local Client = {}
Client.__index = Client
local Server = {}
Server.__index = Server
local Buffer = {}
Buffer.__index = Buffer
local EVENTS = {}               -- what the client does with each command from a server
local COMMANDS = {}             -- the built-in /commands: name -> { fn, usage, help }

--------------------------------------------------------------------------
-- Small things
--------------------------------------------------------------------------
-- The first word and the rest, as typed (the blanks between left out).
local function splitWord(s) return text.words(s)[1] or "", irc.afterWords(s, 1) or "" end

-- A file's name without .lua: the script it holds (nil if it isn't one).
local function scriptName(file)
    local name = text.stripSuffix(file, ".lua")
    if name == "" then return nil end
    return name
end

-- A setting's name for a network: network.<name>.<key>, the network's
-- name and key, or nil.
local function networkKey(name)
    local parts = text.split(name, ".", true)
    if #parts ~= 3 or parts[1] ~= "network" or parts[2] == "" or parts[3] == "" then return nil end
    if not scan.all(parts[3], scan.isNameChar) then return nil end
    return parts[2], parts[3]
end

-- A numeric reply's command: three digits.
local function isNumeric(command) return #command == 3 and scan.isUnsigned(command) end

-- Does the list (words with blanks between) have this word?
local hasWord = text.hasWord

-- mIRC colour n around s.
-- (it ends with \15, plain: a "\3" end would take digits after it as a colour)
local function colour(n, s) return string.format("\3%02d", n) .. s .. "\15" end
C.colour = colour

function C.nickColour(nick)
    local h = 0
    for i = 1, #nick do h = (h * 31 + nick:byte(i)) % 65536 end
    return C.NICK_COLOURS[h % #C.NICK_COLOURS + 1]
end

local function home()
    local getenv = os.getenv
    local h = getenv and getenv("HOME")
    return path.join((h and h ~= "") and h or "/", ".irc")
end

--------------------------------------------------------------------------
-- Making one
--------------------------------------------------------------------------
function C.new(opts)
    opts = opts or {}
    local self = setmetatable({
        home = opts.home or home(),
        scriptDirs = opts.scriptDirs or {},
        connect = opts.connect,
        speaker = opts.speaker,
        noConfig = opts.noConfig,
        buffers = {}, servers = {}, tasks = {}, timers = {},
        signals = {}, commands = {}, scripts = {}, statusItems = {},
        settingDefs = {}, values = {}, aliases = {}, ignores = {},
        history = {}, dirty = true, nextId = 1,
        clock = opts.clock or os.clock,
    }, Client)
    for _, d in ipairs(C.SETTINGS) do self:defineSetting(d[1], d[2], d[3], d[4]) end
    for name, exp in pairs(C.ALIASES) do self.aliases[name] = exp end
    for name, def in pairs(COMMANDS) do self.commands[name] = { fn = def[1], usage = def[2], help = def[3] } end
    self.core = self:newBuffer("ccnix", "core")
    self.current = self.core
    if not self.noConfig then self:loadConfig() end
    return self
end

function Client:defaultNick()
    local label = os.getComputerLabel and os.getComputerLabel()
    -- the label's letters, digits and the other characters a nick may have
    local nick = text.keep(label or "", irc.isNickChar)
    if nick == "" or not irc.validNick(nick) then nick = "cc" .. (os.getComputerID and os.getComputerID() or 0) end
    return nick
end

--------------------------------------------------------------------------
-- Settings and the config file
--------------------------------------------------------------------------
function Client:defineSetting(name, kind, default, help, script)
    self.settingDefs[name] = { kind = kind, default = default, help = help, script = script }
end

function Client:setting(name)
    local v = self.values[name]
    if v ~= nil then return v end
    local d = self.settingDefs[name]
    if name == "nick" then return self:defaultNick() end
    if name == "alt_nick" then return self:setting("nick") .. "_" end
    if name == "ctcp_version" then return "ccnix irc " .. C.VERSION .. " on ComputerCraft (Minecraft)" end
    return d and d.default
end

-- The words a bool setting takes, and what each means.
local BOOL_WORDS = { on = true, ["true"] = true, yes = true, ["1"] = true,
    off = false, ["false"] = false, no = false, ["0"] = false }

-- Each kind of setting: its value from what's typed, or nil and why.
local SETTING_KINDS = {
    int = function(typed)
        local n = convert.toInteger(typed)
        if not n then return nil, "a whole number, please" end
        return n
    end,
    bool = function(typed)
        local v = BOOL_WORDS[typed:lower()]
        if v == nil then return nil, "on or off, please" end
        return v
    end,
    str = function(typed) return typed end,
}

local function parseValue(kind, typed) return (SETTING_KINDS[kind] or SETTING_KINDS.str)(typed) end

-- Set a setting (its value as typed, or nil: back to its default); true,
-- or nil and why.  network.<name>.<key>, alias.<name> are free-form.
function Client:set(name, typed)
    local d = self.settingDefs[name]
    if not d and not networkKey(name) then return nil, "no setting " .. name end
    if typed == nil then
        self.values[name] = nil
    else
        local v, why = parseValue(d and d.kind or "str", typed)
        if v == nil then return nil, why end
        self.values[name] = v
    end
    self:saveConfig()
    self:emit("setup changed", name)
    self.dirty = true
    return true
end

function Client:configPath() return self.home .. "/config" end

function Client:loadConfig()
    local contents = fileio.read(self:configPath())
    if not contents then return end
    -- line = key " = " value, or a "#" comment
    for _, raw in ipairs(text.lines(contents)) do
        local line = text.trim(raw)
        local key, value = text.cut(line, " = ")
        if value and not text.startsWith(line, "#") then
            local alias, ignore = text.stripPrefix(key, "alias."), text.stripPrefix(key, "ignore.")
            if alias then
                self.aliases[alias] = value ~= "" and value or nil
            elseif ignore then
                self.ignores[#self.ignores + 1] = { mask = ignore, levels = value }
            else
                local d = self.settingDefs[key]
                local v = parseValue(d and d.kind or "str", value)
                if v ~= nil then self.values[key] = v end
            end
        end
    end
end

function Client:saveConfig()
    if self.noConfig then return end
    local out = { "# ccnix irc's settings: name = value (/set changes them; this file is rewritten)" }
    for _, k in ipairs(tables.sortedKeys(self.values)) do
        local v = self.values[k]
        if type(v) == "boolean" then v = v and "on" or "off" end
        out[#out + 1] = k .. " = " .. tostring(v)
    end
    local names = {}
    for name, exp in pairs(self.aliases) do
        if C.ALIASES[name] ~= exp then names[#names + 1] = name end
    end
    for name in pairs(C.ALIASES) do
        if not self.aliases[name] then names[#names + 1] = name end   -- (one taken away: kept away)
    end
    table.sort(names)
    for _, name in ipairs(names) do out[#out + 1] = "alias." .. name .. " = " .. (self.aliases[name] or "") end
    for _, ig in ipairs(self.ignores) do out[#out + 1] = "ignore." .. ig.mask .. " = " .. ig.levels end
    if not fs.exists(self.home) then fs.makeDir(self.home) end
    fileio.write(self:configPath(), table.concat(out, "\n") .. "\n")
end

--------------------------------------------------------------------------
-- Signals
--------------------------------------------------------------------------
function Client:signalAdd(name, fn, script, first)
    local list = self.signals[name] or {}
    self.signals[name] = list
    local entry = { fn = fn, script = script }
    if first then table.insert(list, 1, entry) else list[#list + 1] = entry end
    return entry
end

function Client:signalRemove(name, fn)
    local list = self.signals[name]
    if not list then return end
    for i = #list, 1, -1 do
        if list[i].fn == fn then table.remove(list, i) end
    end
end

-- Emit: each handler in turn, until one calls signal_stop.  True if
-- stopped.
function Client:emit(name, ...)
    local list = self.signals[name]
    if not list or #list == 0 then return false end
    local outer = self.stopped
    self.stopped = false
    for _, entry in ipairs({ table.unpack(list) }) do
        local ok, err = pcall(entry.fn, ...)
        if not ok then
            self:print(nil, "script " .. (entry.script and entry.script.name or "?") .. ", signal \"" .. name .. "\": " .. tostring(err),
                { level = "error", prefix = "=!=", prefixColour = 4 })
        end
        if self.stopped then break end
    end
    local stopped = self.stopped
    self.stopped = outer
    return stopped
end

--------------------------------------------------------------------------
-- Coroutines and timers
--------------------------------------------------------------------------
function Client:step(task, ...)
    local ok, filter = coroutine.resume(task.co, ...)
    if not ok then
        task.dead = true
        self:print(nil, "error: " .. tostring(filter), { level = "error", prefix = "=!=", prefixColour = 4 })
    elseif coroutine.status(task.co) == "dead" then
        task.dead = true
    else
        task.filter = filter
    end
    self.dirty = true
end

function Client:spawn(fn, ...)
    local task = { co = coroutine.create(fn) }
    self.tasks[#self.tasks + 1] = task
    self:step(task, ...)
    return task
end

-- Script timers: irc.timeout_add(ms, fn); each fires through a CC timer.
function Client:timeoutAdd(ms, fn, once, script)
    local t = { ms = ms, fn = fn, once = once, script = script }
    t.timer = os.startTimer(math.max(0.05, ms / 1000))
    self.timers[t.timer] = t
    return t
end

function Client:timeoutRemove(t)
    if not t then return end
    if self.timers[t.timer] == t then self.timers[t.timer] = nil end
    if os.cancelTimer then os.cancelTimer(t.timer) end
end

-- Each CC event: the coroutines that wait for it, the timers.
function Client:event(name, ...)
    if name == "terminate" then return end      -- (the program's own; os.pullEvent would raise it in them)
    if name == "timer" then
        local id = ...
        local t = self.timers[id]
        if t then
            self.timers[id] = nil
            if not t.once then
                t.timer = os.startTimer(math.max(0.05, t.ms / 1000))
                self.timers[t.timer] = t
            end
            local ok, err = pcall(t.fn)
            if not ok then self:print(nil, "timeout: " .. tostring(err), { level = "error", prefix = "=!=", prefixColour = 4 }) end
            self.dirty = true
            return
        end
        if id == self.tickTimer then
            self.tickTimer = nil
            self:tick()
            return
        end
    end
    local alive = {}
    for _, task in ipairs(self.tasks) do
        if not task.dead and (task.filter == nil or task.filter == name) then self:step(task, name, ...) end
    end
    for _, task in ipairs(self.tasks) do if not task.dead then alive[#alive + 1] = task end end
    self.tasks = alive
end

-- Each second: lag pings, connecting again, the clock.
function Client:startTicking()
    if not self.tickTimer then self.tickTimer = os.startTimer(1) end
end

function Client:tick()
    self.tickTimer = os.startTimer(1)
    local now = self.clock()
    for _, s in ipairs(self.servers) do
        if s.registered and now - (s.pingAt or 0) >= 30 and not s.pingOut then
            s.pingOut = now
            s.pingAt = now
            s:send("PING :ccnix-lag")
        end
        if s.reconnectAt and now >= s.reconnectAt then
            s.reconnectAt = nil
            s:start()
        end
    end
    local minute = os.date and os.date("%H:%M")
    if minute ~= self.lastMinute then self.lastMinute = minute; self.dirty = true end
end

--------------------------------------------------------------------------
-- Buffers
--------------------------------------------------------------------------
function Client:newBuffer(name, kind, server)
    local b = setmetatable({ id = self.nextId, name = name, kind = kind, server = server, lines = {},
        activity = 0, scroll = 0, nicks = {}, client = self }, Buffer)
    self.nextId = self.nextId + 1
    -- after the last of its server's buffers, so they stay together
    local at = #self.buffers + 1
    if server then
        for i, x in ipairs(self.buffers) do
            if x.server == server then at = i + 1 end
        end
    end
    table.insert(self.buffers, at, b)
    self.dirty = true
    return b
end

function Client:findBuffer(server, name)
    local key = server and server:fold(name) or name:lower()
    for _, b in ipairs(self.buffers) do
        if b.server == server and (server and server:fold(b.name) or b.name:lower()) == key then return b end
    end
    return nil
end

function Client:bufferNumber(b)
    for i, x in ipairs(self.buffers) do if x == b then return i end end
    return nil
end

function Client:switch(b)
    if not b or b == self.current then return end
    self.current = b
    b.activity = 0
    self.dirty = true
    self:emit("window changed", b)
end

function Client:closeBuffer(b)
    if b == self.core then return nil, "the core buffer stays" end
    if b.kind == "server" then
        if b.server.conn then return nil, "disconnect first (/disconnect)" end
        for i = #self.buffers, 1, -1 do
            local x = self.buffers[i]
            if x.server == b.server and x ~= b then table.remove(self.buffers, i) end
        end
        for i, s in ipairs(self.servers) do if s == b.server then table.remove(self.servers, i) end end
    elseif b.kind == "channel" and b.joined and b.server.registered then
        b.server:send(irc.build("PART", b.name, self:setting("part_message")))
    end
    local n = self:bufferNumber(b)
    if n then table.remove(self.buffers, n) end
    if self.current == b then
        self.current = self.buffers[math.min(n or 1, #self.buffers)] or self.core
        self.current.activity = 0
    end
    self.dirty = true
    return true
end

-- A line into a buffer (nil: the core one).  opts: prefix, prefixColour
-- (mIRC), level (C.ACTIVITY's), hilight, time.
function Client:print(buffer, body, opts)
    opts = opts or {}
    buffer = buffer or self.core
    local line = { time = opts.time or self:timestamp(), prefix = opts.prefix or "", prefixColour = opts.prefixColour,
        text = body or "", level = opts.level or "crap", hilight = opts.hilight }
    local lines = buffer.lines
    lines[#lines + 1] = line
    local most = self:setting("scrollback") or C.SCROLLBACK
    while #lines > most do table.remove(lines, 1) end
    if buffer.scroll > 0 then buffer.scroll = math.min(buffer.scroll + 1, #lines - 1) end
    if buffer ~= self.current then
        local act = line.hilight and 3 or (C.ACTIVITY[line.level] or 1)
        if act > buffer.activity then buffer.activity = act end
    end
    if line.hilight or line.level == "private" then self:bell() end
    self.dirty = true
    self:emit("print text", buffer, line)
    return line
end

function Client:timestamp()
    local fmt = self:setting("timestamp_format")
    if not fmt or fmt == "" then return "" end
    if self:setting("timestamp_clock") == "game" then
        local t = os.time("ingame")
        local h = math.floor(t)
        return string.format("%02d:%02d", h, math.floor((t - h) * 60))
    end
    return os.date and os.date(fmt) or ""
end

function Client:bell()
    if not self:setting("beep_on_hilight") then return end
    local sp = self.speaker
    if sp == nil and peripheral then sp = peripheral.find("speaker") or false; self.speaker = sp end
    if sp then pcall(sp.playNote, "bell", 1, 18) end
end

-- What the client says itself, in a buffer: "-- text" in light blue.
function Client:note(buffer, body, level)
    return self:print(buffer, body, { prefix = "--", prefixColour = 12, level = level or "crap" })
end

function Client:err(buffer, body)
    return self:print(buffer, body, { prefix = "=!=", prefixColour = 4, level = "error" })
end

--------------------------------------------------------------------------
-- Buffer methods (for scripts too)
--------------------------------------------------------------------------
function Buffer:print(body, opts) return self.client:print(self, body, opts) end
function Buffer:command(line) return self.client:command(line, self) end
function Buffer:number() return self.client:bufferNumber(self) end

-- The nicks in a channel buffer, sorted by their rank (@ before +) then name.
function Buffer:nickList()
    local list = {}
    for _, n in pairs(self.nicks) do list[#list + 1] = n end
    local server = self.server
    table.sort(list, function(a, b)
        local ra, rb = server and server:rank(a.prefix) or 99, server and server:rank(b.prefix) or 99
        if ra ~= rb then return ra < rb end
        return a.nick:lower() < b.nick:lower()
    end)
    return list
end

function Buffer:setNick(nick, prefix)
    self.nicks[self.server:fold(nick)] = { nick = nick, prefix = prefix or "" }
end

function Buffer:removeNick(nick)
    local key = self.server:fold(nick)
    local had = self.nicks[key]
    self.nicks[key] = nil
    return had
end

function Buffer:getNick(nick) return self.nicks[self.server:fold(nick)] end

--------------------------------------------------------------------------
-- Servers
--------------------------------------------------------------------------
-- A server from a network's settings, or a host.
function Client:newServer(name, address, port)
    local s = setmetatable({ client = self, name = name, address = address, port = port or 6667,
        isupport = { CASEMAPPING = "rfc1459", CHANTYPES = "#&", PREFIX = "(ov)@+" },
        prefixModes = "ov", prefixSymbols = "@+", umodes = "" }, Server)
    self.servers[#self.servers + 1] = s
    s.buffer = self:newBuffer(name, "server", s)
    return s
end

function Client:findServer(name)
    for _, s in ipairs(self.servers) do
        if text.equalFold(s.name, name) then return s end
    end
    return nil
end

-- The server the current buffer belongs to (else the only one, or the
-- first connected).
function Client:activeServer(buffer)
    buffer = buffer or self.current
    if buffer.server then return buffer.server end
    for _, s in ipairs(self.servers) do if s.registered then return s end end
    return self.servers[1]
end

function Server:net(key)
    return self.client.values["network." .. self.name .. "." .. key]
end

function Server:fold(s) return irc.casefold(s, self.isupport.CASEMAPPING) end
function Server:isChannel(name) return irc.isChannel(name, self.isupport.CHANTYPES) end
function Server:isMe(nick) return self.nick and nick and self:fold(nick) == self:fold(self.nick) end

-- Where a prefix (one or more of @+...) ranks: 1 for the highest symbol,
-- 99 for none.
function Server:rank(prefix)
    if not prefix or prefix == "" then return 99 end
    return text.find(self.prefixSymbols, prefix:sub(1, 1)) or 99
end

-- Send a raw line (lib/irc builds them); nothing if not connected.
function Server:send(line)
    if not self.conn then return false end
    self.conn:send(irc.toUTF8(line) .. "\r\n")
    return true
end
Server.send_raw = Server.send

-- PRIVMSG (or NOTICE) text to target, cut into pieces that fit a line.
function Server:message(target, body, command)
    command = command or "PRIVMSG"
    local room = 400 - #target
    local pieces = text.wrap(body, room)              -- (at the last space that fits)
    for _, p in ipairs(pieces) do self:send(irc.build(command, target, p)) end
    return pieces
end
Server.send_message = function(self, target, body) return self:message(target, body) end

-- A command as typed, for this server (a script's server:command("msg x hi")).
function Server:command(line)
    return self.client:command("/" .. line, self.buffer)
end

-- Connect (in a coroutine of its own).
function Server:start()
    if self.conn or self.connecting then return end
    self.wantQuit = nil
    self.client:spawn(function() self:run() end)
end

function Server:run()
    local client = self.client
    self.connecting = true
    client:note(self.buffer, "Connecting to " .. self.address .. " port " .. self.port .. "...", "crap")
    client:emit("server connecting", self)
    local connect = client.connect
    if not connect then
        local net = require("net")
        connect = net.connect
    end
    local conn, why = connect(self.address, self.port, 20)
    self.connecting = nil
    if not conn then
        client:err(self.buffer, "Can't connect to " .. self.address .. " port " .. self.port .. ": " .. tostring(why))
        self:lost(why)
        return
    end
    self.conn = conn
    self.registered = false
    self.nick = self:net("nick") or client:setting("nick")
    self.triedAlt = nil
    client:note(self.buffer, "Connected; logging in as " .. self.nick)
    self:send("CAP LS 302")
    local pass = self:net("password")
    if pass and pass ~= "" then self:send("PASS " .. pass) end
    self:send(irc.build("NICK", self.nick))
    self:send(irc.build("USER", self:net("user_name") or client:setting("user_name"), "0", "*",
        client:setting("real_name")))
    local buf = ""
    while true do
        local data, err = conn:read()
        if not data then
            self:lost(err)
            return
        end
        local lines
        lines, buf = irc.lines(buf .. data)
        for _, line in ipairs(lines) do
            local ok, e = pcall(self.handle, self, line)
            if not ok then client:err(self.buffer, "while handling \"" .. line:sub(1, 60) .. "\": " .. tostring(e)) end
        end
        if #buf > 8192 then buf = "" end
    end
end

-- The connection's gone: say so, and connect again later unless asked
-- to go.
function Server:lost(why)
    local client = self.client
    local was = self.conn
    if was and was:state() ~= "CLOSED" then was:close() end
    self.conn, self.registered, self.pingOut, self.lag = nil, false, nil, nil
    for _, b in ipairs(client.buffers) do
        if b.server == self and b.kind == "channel" and b.joined then
            b.joined = false
            b.nicks = {}
            client:note(b, "Disconnected from " .. self.name, "crap")
        end
    end
    if was then client:note(self.buffer, "Disconnected" .. ((why and why ~= "closed") and (": " .. why) or "")) end
    client:emit("server disconnected", self, why)
    local wait = client:setting("reconnect_time")
    if not self.wantQuit and wait and wait > 0 then
        self.reconnectAt = client.clock() + wait
        client:note(self.buffer, "Connecting again in " .. wait .. " seconds (/disconnect stops it)")
    end
    client.dirty = true
end

function Server:quit(message)
    self.wantQuit = true
    self.reconnectAt = nil
    if self.conn then
        self:send(irc.build("QUIT", message or self.client:setting("quit_message")))
        self.conn:close()
    end
end

-- One line from the server.
function Server:handle(line)
    line = irc.fromUTF8(line)
    local m = irc.parse(line)
    if not m then return end
    local client = self.client
    if client:emit("event " .. m.command:lower(), self, m, line) then return end
    local h = EVENTS[m.command]
    if h then
        h(self, m)
    elseif isNumeric(m.command) then
        EVENTS.numeric(self, m)
    else
        client:print(self.buffer, line, { level = "crap" })
    end
    client.dirty = true
end

--------------------------------------------------------------------------
-- What servers send
--------------------------------------------------------------------------
-- The buffer for a message to target (a channel, or us: a query with the
-- sender), made if need be.
function Server:bufferFor(target, nick, make)
    local client = self.client
    local name = self:isChannel(target) and target or nick
    local b = client:findBuffer(self, name)
    if not b and make then
        b = client:newBuffer(name, self:isChannel(target) and "channel" or "query", self)
    end
    return b
end

function Server:isHilight(body)
    local plain = irc.strip(body):lower()
    local function has(word)
        word = word:lower()
        local from = 1
        while true do
            local i, j = text.find(plain, word, from)
            if not i then return false end
            local before, after = plain:sub(i - 1, i - 1), plain:sub(j + 1, j + 1)
            if not scan.isNameChar(before) and not scan.isNameChar(after) then return true end
            from = i + 1
        end
    end
    if self.nick and has(self.nick) then return true end
    for _, w in ipairs(text.words(self.client:setting("hilight_words") or "")) do
        if has(w) then return true end
    end
    return false
end

-- A nick in its colour, aligned or as <nick>: the line's prefix.
local function nickPrefix(nick, mode)
    return (mode or "") .. nick
end

function Client:ignored(nick, address, level)
    local full = (nick or "") .. "!" .. (address or "")
    for _, ig in ipairs(self.ignores) do
        local mask = irc.containsAny(ig.mask, "!@") and ig.mask or (ig.mask .. "!*")
        if irc.match(mask, full) and (ig.levels == "all" or hasWord(ig.levels, level)) then
            return true
        end
    end
    return false
end

EVENTS.PING = function(s, m) s:send(irc.build("PONG", m.params[1] or "")) end

EVENTS.PONG = function(s)
    if s.pingOut then
        s.lag = s.client.clock() - s.pingOut
        s.pingOut = nil
    end
end

EVENTS.ERROR = function(s, m) s.client:err(s.buffer, m.params[1] or "ERROR") end

-- SASL PLAIN's account, when the network has one set.
local function saslAccount(s)
    local user, pass = s:net("sasl_user"), s:net("sasl_pass")
    if user and pass then return user, pass end
    return nil
end

-- The capabilities asked for when a server offers them: each with
-- whether it's wanted on this server.
local WANTED_CAPS = {
    ["multi-prefix"] = function() return true end,
    ["away-notify"] = function() return true end,
    sasl = function(s) return saslAccount(s) ~= nil end,
}

-- CAP's subcommands from the server (IRCv3 capability negotiation).
local CAP_REPLIES = {
    -- LS: what it offers; ask for the ones wanted (302: a "*" before the
    -- last param means more lines follow)
    LS = function(s, m)
        s.capOffered = (s.capOffered or "") .. " " .. (m.params[#m.params] or "")
        if m.params[3] == "*" then return end
        local want = {}
        for _, cap in ipairs(text.words(s.capOffered)) do
            local name = text.cut(cap, "=")
            if WANTED_CAPS[name] and WANTED_CAPS[name](s) then want[#want + 1] = name end
        end
        s.capOffered = nil
        if #want > 0 then s:send(irc.build("CAP", "REQ", text.join(want, " "))) else s:send("CAP END") end
    end,
    -- ACK: what it agreed to; SASL logs in before CAP END
    ACK = function(s, m)
        if hasWord(m.params[#m.params] or "", "sasl") and saslAccount(s) then
            s:send("AUTHENTICATE PLAIN")
        else
            s:send("CAP END")
        end
    end,
    NAK = function(s) s:send("CAP END") end,
}

EVENTS.CAP = function(s, m)
    local reply = CAP_REPLIES[(m.params[2] or ""):upper()]
    if reply then reply(s, m) end
end

EVENTS.AUTHENTICATE = function(s, m)
    if m.params[1] == "+" then
        local user, pass = s:net("sasl_user") or "", s:net("sasl_pass") or ""
        s:send("AUTHENTICATE " .. convert.toBase64(user .. "\0" .. user .. "\0" .. pass))
    end
end

EVENTS["903"] = function(s) s.client:note(s.buffer, "SASL: logged in"); s:send("CAP END") end
EVENTS["904"] = function(s, m)
    s.client:err(s.buffer, "SASL: " .. (m.params[#m.params] or "failed"))
    s:send("CAP END")
end
EVENTS["905"], EVENTS["906"] = EVENTS["904"], EVENTS["904"]

EVENTS["001"] = function(s, m)
    local client = s.client
    s.registered = true
    s.nick = m.params[1]
    s.pingAt = client.clock()
    client:print(s.buffer, m.params[2] or "", { prefix = "--", prefixColour = 12 })
    client:emit("server connected", s)
    for _, cmd in ipairs(text.split(s:net("commands") or "", ";")) do client:command("/" .. cmd, s.buffer) end
    local chans = {}
    for _, chan in ipairs(text.split(s:net("autojoin") or "", ",")) do chans[#chans + 1] = chan end
    for _, b in ipairs(client.buffers) do      -- (back after a lost connection: the channels it was in)
        if b.server == s and b.kind == "channel" and b.wanted then chans[#chans + 1] = b.name end
    end
    if #chans > 0 then s:send(irc.build("JOIN", table.concat(chans, ","))) end
end

-- The ISUPPORT tokens the client does more with than keep.
local ISUPPORT_TOKENS = {
    -- PREFIX=(modes)symbols: (ov)@+
    PREFIX = function(s, value)
        if type(value) ~= "string" then return end
        local sc = scan.new(value)
        if sc:accept("(") then
            local modes, closed = sc:readUntil(")")
            if closed then s.prefixModes, s.prefixSymbols = modes, sc:readRest() end
        end
    end,
    NETWORK = function(s, value) s.network = value end,
}

EVENTS["005"] = function(s, m)
    -- each token: KEY or KEY=value
    for i = 2, #m.params - 1 do
        local key, value = text.cut(m.params[i], "=")
        key = key:upper()
        if value == nil then value = true end
        s.isupport[key] = value
        if ISUPPORT_TOKENS[key] then ISUPPORT_TOKENS[key](s, value) end
    end
    s.client:print(s.buffer, table.concat(m.params, " ", 2, #m.params), { prefix = "--", prefixColour = 12 })
end

-- Nick in use while logging in: the other nick, then that with _'s.
local function nickTaken(s, m)
    if s.registered then
        return s.client:err(s.client.current.server == s and s.client.current or s.buffer,
            (m.params[2] or "") .. ": " .. (m.params[3] or "nick in use"))
    end
    local alt = s.client:setting("alt_nick")
    local nick = (not s.triedAlt and alt ~= s.nick) and alt or (s.nick .. "_")
    s.triedAlt = true
    s.client:note(s.buffer, (m.params[2] or s.nick) .. " is taken; trying " .. nick)
    s.nick = nick
    s:send(irc.build("NICK", nick))
end
EVENTS["433"] = nickTaken
EVENTS["432"] = nickTaken
EVENTS["437"] = nickTaken

EVENTS.NICK = function(s, m)
    local client, new, old = s.client, m.params[1], m.nick
    if s:isMe(old) then s.nick = new end
    local me = s:isMe(new)
    for _, b in ipairs(client.buffers) do
        if b.server == s then
            local had = b.kind == "channel" and b:removeNick(old)
            if had then b:setNick(new, had.prefix) end
            if b.kind == "query" and s:fold(b.name) == s:fold(old) then b.name = new; had = true end
            if had or (me and b.kind == "server") then
                local said = me and ("You're now known as " .. colour(C.nickColour(new), new))
                    or (colour(C.nickColour(old), old) .. " is now known as " .. colour(C.nickColour(new), new))
                if not client:ignored(old, m.user and (m.user .. "@" .. (m.host or "")), "nicks") then
                    client:print(b, said, { prefix = "--", prefixColour = 12, level = "nicks" })
                end
            end
        end
    end
    client:emit("message nick", s, new, old, m.user and (m.user .. "@" .. (m.host or "")))
end

EVENTS.JOIN = function(s, m)
    local client, chan, nick = s.client, m.params[1], m.nick
    local address = (m.user or "") .. "@" .. (m.host or "")
    if s:isMe(nick) then
        local b = s:bufferFor(chan, nil, true)
        b.name, b.joined, b.wanted, b.nicks = chan, true, true, {}
        b.namesDone = false
        if s.joining and s:fold(s.joining) == s:fold(chan) then client:switch(b); s.joining = nil end
        client:print(b, "You joined " .. colour(14, chan), { prefix = "-->", prefixColour = 9, level = "joins" })
        client:emit("channel joined", b)
        return
    end
    local b = client:findBuffer(s, chan)
    if not b then return end
    b:setNick(nick, "")
    b.hosts = b.hosts or {}
    b.hosts[s:fold(nick)] = m.host
    if not client:ignored(nick, address, "joins") then
        client:print(b, colour(C.nickColour(nick), nick) .. " " .. colour(14, "(" .. address .. ")") .. " has joined "
            .. colour(14, chan), { prefix = "-->", prefixColour = 9, level = "joins" })
    end
    client:emit("message join", s, chan, nick, address)
end

EVENTS.PART = function(s, m)
    local client, chan, nick, reason = s.client, m.params[1], m.nick, m.params[2]
    local address = (m.user or "") .. "@" .. (m.host or "")
    local b = client:findBuffer(s, chan)
    if not b then return end
    if s:isMe(nick) then
        b.joined, b.wanted, b.nicks = false, false, {}
        client:print(b, "You left " .. colour(14, chan), { prefix = "<--", prefixColour = 4, level = "parts" })
    else
        b:removeNick(nick)
        if not client:ignored(nick, address, "parts") then
            client:print(b, colour(C.nickColour(nick), nick) .. " " .. colour(14, "(" .. address .. ")") .. " has left "
                .. colour(14, chan) .. ((reason and reason ~= "") and (" (" .. reason .. "\15)") or ""),
                { prefix = "<--", prefixColour = 4, level = "parts" })
        end
    end
    client:emit("message part", s, chan, nick, address, reason)
end

EVENTS.KICK = function(s, m)
    local client, chan, victim, reason = s.client, m.params[1], m.params[2], m.params[3]
    local b = client:findBuffer(s, chan)
    if not b then return end
    b:removeNick(victim)
    local by = colour(C.nickColour(m.nick or "?"), m.nick or "?")
    if s:isMe(victim) then
        b.joined, b.nicks = false, {}
        client:print(b, "You were kicked from " .. chan .. " by " .. by .. " (" .. (reason or "") .. "\15)",
            { prefix = "<--", prefixColour = 4, level = "kicks", hilight = true })
    else
        client:print(b, colour(C.nickColour(victim), victim) .. " was kicked by " .. by .. " (" .. (reason or "") .. "\15)",
            { prefix = "<--", prefixColour = 4, level = "kicks" })
    end
    client:emit("message kick", s, chan, victim, m.nick, (m.user or "") .. "@" .. (m.host or ""), reason)
end

EVENTS.QUIT = function(s, m)
    local client, nick, reason = s.client, m.nick, m.params[1]
    local address = (m.user or "") .. "@" .. (m.host or "")
    local quiet = client:ignored(nick, address, "quits")
    for _, b in ipairs(client.buffers) do
        if b.server == s then
            local had = b.kind == "channel" and b:removeNick(nick)
            if b.kind == "query" and s:fold(b.name) == s:fold(nick) then had = true end
            if had and not quiet then
                client:print(b, colour(C.nickColour(nick), nick) .. " " .. colour(14, "(" .. address .. ")") .. " has quit"
                    .. ((reason and reason ~= "") and (" (" .. reason .. "\15)") or ""),
                    { prefix = "<--", prefixColour = 4, level = "quits" })
            end
        end
    end
    client:emit("message quit", s, nick, address, reason)
end

EVENTS.TOPIC = function(s, m)
    local client, chan, topic = s.client, m.params[1], m.params[2] or ""
    local b = client:findBuffer(s, chan)
    if not b then return end
    b.topic = topic
    client:print(b, colour(C.nickColour(m.nick or "?"), m.nick or "?") .. " changed the topic to: " .. topic,
        { prefix = "--", prefixColour = 12, level = "topics" })
    client:emit("message topic", s, chan, topic, m.nick, (m.user or "") .. "@" .. (m.host or ""))
end

EVENTS.INVITE = function(s, m)
    local client, chan = s.client, m.params[2]
    client:print(client.current.server == s and client.current or s.buffer,
        colour(C.nickColour(m.nick or "?"), m.nick or "?") .. " invites you to " .. colour(14, chan or "?")
        .. " (/join " .. (chan or "") .. ")", { prefix = "--", prefixColour = 12, level = "private", hilight = true })
    if client:setting("autojoin_on_invite") and chan then s:send(irc.build("JOIN", chan)) end
end

-- PRIVMSG and NOTICE: CTCP (ACTION, and the questions answered), or a message.
local CTCP_ANSWERS = {
    VERSION = function(s) return s.client:setting("ctcp_version") end,
    PING = function(_, args) return args end,
    TIME = function() return os.date and os.date("%Y-%m-%d %H:%M:%S") or "" end,
    CLIENTINFO = function() return "ACTION CLIENTINFO PING TIME VERSION" end,
}

-- What a PRIVMSG or NOTICE is, by what its text holds (a CTCP ACTION,
-- another CTCP, or plain text) and its command.
local MESSAGE_KIND = {
    plain  = { PRIVMSG = "message", NOTICE = "notice" },
    action = { PRIVMSG = "action", NOTICE = "notice" },
    ctcp   = { PRIVMSG = "ctcpQuery", NOTICE = "ctcpReply" },
}

local function messageKind(command, ctcp)
    local holds = (ctcp == nil and "plain") or (ctcp == "ACTION" and "action") or "ctcp"
    return MESSAGE_KIND[holds][command]
end

-- The buffer a notice goes in: its channel's, the sender's query, or
-- the one on the screen (if it's this server's).
local function noticeBuffer(s, msg)
    local client = s.client
    return (msg.toChannel and s:bufferFor(msg.target, msg.nick, false)) or client:findBuffer(s, msg.nick)
        or (client.current.server == s and client.current) or s.buffer
end

-- The buffer a message goes in: its channel's or the sender's query, made if need be.
local function messageBuffer(s, msg) return s:bufferFor(msg.target, msg.nick, true) end

-- How each kind is handled.  A CTCP has handle(s, msg), all of it; the
-- others go through the ignores and hilights first, then
--   levels    the level in a channel and in private (ignores, activity)
--   buffer(s, msg)              where it's shown
--   show(s, b, msg, level)      the line, and the script signal
local MESSAGES = {
    ctcpReply = { handle = function(s, msg)
        local client = s.client
        client:print(client.current.server == s and client.current or s.buffer,
            "CTCP " .. msg.ctcp .. " reply from " .. colour(C.nickColour(msg.nick), msg.nick) .. ": " .. msg.args,
            { prefix = "--", prefixColour = 12, level = "notices" })
    end },
    ctcpQuery = { handle = function(s, msg)
        local client, nick = s.client, msg.nick
        if client:emit("ctcp msg", s, msg.ctcp, msg.args, nick, msg.address, msg.target) then return end
        local answer = CTCP_ANSWERS[msg.ctcp]
        if answer and not client:ignored(nick, msg.address, "ctcps") then
            s:send(irc.build("NOTICE", nick, irc.ctcpQuote(msg.ctcp, answer(s, msg.args))))
        end
        client:note(s.buffer, "CTCP " .. msg.ctcp .. " from " .. colour(C.nickColour(nick), nick)
            .. (msg.args ~= "" and (": " .. msg.args) or ""))
    end },
    notice = { levels = { channel = "notices", private = "notices" }, buffer = noticeBuffer,
        show = function(s, b, msg, level)
            s.client:print(b, msg.body, { prefix = "-" .. msg.nick .. "-", prefixColour = 7, level = level,
                hilight = msg.hilight })
            s.client:emit("message irc notice", s, msg.body, msg.nick, msg.address, msg.target)
        end },
    action = { levels = { channel = "actions", private = "private" }, buffer = messageBuffer,
        show = function(s, b, msg, level)
            s.client:print(b, colour(C.nickColour(msg.nick), msg.nick) .. " " .. msg.args,
                { prefix = " *", prefixColour = 0, level = level, hilight = msg.hilight })
            s.client:emit("message irc action", s, msg.args, msg.nick, msg.address, msg.target)
        end },
    message = { levels = { channel = "public", private = "private" }, buffer = messageBuffer,
        show = function(s, b, msg, level)
            local mode = ""
            if msg.toChannel and b.kind == "channel" then
                local entry = b:getNick(msg.nick)
                mode = entry and entry.prefix:sub(1, 1) or ""
            end
            s.client:print(b, msg.body, { prefix = nickPrefix(msg.nick, mode), prefixColour = C.nickColour(msg.nick),
                level = level, hilight = msg.hilight, nick = msg.nick })
            if msg.toChannel then s.client:emit("message public", s, msg.body, msg.nick, msg.address, msg.target)
            else s.client:emit("message private", s, msg.body, msg.nick, msg.address) end
        end },
}

local function privmsg(s, m)
    local client = s.client
    local msg = { target = m.params[1], body = m.params[2] or "", nick = m.nick or m.source or "?",
        address = (m.user or "") .. "@" .. (m.host or "") }
    msg.toChannel = s:isChannel(msg.target)
    msg.ctcp, msg.args = irc.ctcp(msg.body)
    local kind = MESSAGES[messageKind(m.command, msg.ctcp)]
    if kind.handle then return kind.handle(s, msg) end
    if not m.nick or (not s.registered and not msg.toChannel) then          -- (the server's own NOTICE)
        client:print(s.buffer, msg.body, { prefix = "-" .. (m.source or s.name) .. "-", prefixColour = 7, level = "notices" })
        return
    end
    local level = kind.levels[msg.toChannel and "channel" or "private"]
    if client:ignored(msg.nick, msg.address, level) then return end
    msg.hilight = (msg.toChannel and s:isHilight(msg.body)) or false
    kind.show(s, kind.buffer(s, msg), msg, level)
end

EVENTS.PRIVMSG = privmsg
EVENTS.NOTICE = privmsg

-- A channel mode's arguments: which letters take one (PREFIX's always;
-- CHANMODES' lists A always, B always, C when set, D never).
local function modeTakesArg(s, letter, adding)
    if text.contains(s.prefixModes, letter) then return true end
    local groups = text.split(s.isupport.CHANMODES or "b,k,l,imnst", ",", true)
    local function inGroup(k) return text.contains(groups[k] or "", letter) end
    if inGroup(1) or inGroup(2) then return true end
    if inGroup(3) then return adding end
    return false
end

-- The prefix for a nick's modes, its highest symbol first (multi-prefix:
-- all of them).
local function addPrefix(s, prefix, symbol, adding)
    local has = {}
    for i = 1, #prefix do has[prefix:sub(i, i)] = true end
    has[symbol] = adding or nil
    local out = ""
    for i = 1, #s.prefixSymbols do
        local sym = s.prefixSymbols:sub(i, i)
        if has[sym] then out = out .. sym end
    end
    return out
end

EVENTS.MODE = function(s, m)
    local client, target = s.client, m.params[1]
    local by = m.nick or m.source or s.name
    if not s:isChannel(target) then
        if s:isMe(target) then s.umodes = m.params[2] or "" end
        client:note(s.buffer, "Mode " .. target .. " [" .. table.concat(m.params, " ", 2) .. "] by " .. by, "modes")
        return
    end
    local b = client:findBuffer(s, target)
    if not b then return end
    local function takesArg(letter, adding) return modeTakesArg(s, letter, adding) end
    for _, ch in ipairs(irc.modeChanges(m.params[2] or "", { table.unpack(m.params, 3) }, takesArg)) do
        local at = text.find(s.prefixModes, ch.letter)
        if at and ch.arg then
            local entry = b:getNick(ch.arg)
            if entry then entry.prefix = addPrefix(s, entry.prefix, s.prefixSymbols:sub(at, at), ch.set) end
        end
    end
    client:print(b, "Mode " .. colour(14, target) .. " [" .. table.concat(m.params, " ", 2) .. "] by "
        .. colour(C.nickColour(by), by), { prefix = "--", prefixColour = 12, level = "modes" })
end

-- Names: 353 lines gathered, then 366 shows them (BitchX's [@nick] [+nick] boxes).
EVENTS["353"] = function(s, m)
    local b = s.client:findBuffer(s, m.params[3] or "")
    if not b then
        return s.client:note(s.client.current, "Names " .. (m.params[3] or "") .. ": " .. (m.params[4] or ""))
    end
    if b.namesDone ~= false then b.nicks, b.namesDone = {}, false end
    for _, entry in ipairs(text.words(m.params[4] or "")) do
        local i = 1
        while i <= #entry and text.contains(s.prefixSymbols, entry:sub(i, i)) do i = i + 1 end
        local nick = text.cut(entry:sub(i), "!")    -- (userhost-in-names: nick!user@host)
        b:setNick(nick, entry:sub(1, i - 1))
    end
end

EVENTS["366"] = function(s, m)
    local client = s.client
    local b = client:findBuffer(s, m.params[2] or "")
    if not b then return end
    b.namesDone = true
    local list, ops, voices = b:nickList(), 0, 0
    local shown = {}
    for _, n in ipairs(list) do
        local p = n.prefix:sub(1, 1)
        if p == "@" then ops = ops + 1 elseif p == "+" then voices = voices + 1 end
        shown[#shown + 1] = colour(14, "[") .. (p ~= "" and colour(p == "@" and 9 or 8, p) or " ")
            .. colour(C.nickColour(n.nick), n.nick) .. colour(14, "]")
    end
    if #list <= 40 then client:print(b, table.concat(shown, " "), { prefix = "--", prefixColour = 12, level = "crap" }) end
    client:note(b, "Channel " .. colour(14, b.name) .. ": " .. #list .. " nicks (" .. ops .. " ops, " .. voices
        .. " voices, " .. (#list - ops - voices) .. " normal)")
end

EVENTS["332"] = function(s, m)
    local b = s.client:findBuffer(s, m.params[2] or "")
    if not b then return end
    b.topic = m.params[3] or ""
    s.client:print(b, "Topic for " .. colour(14, b.name) .. ": " .. b.topic, { prefix = "--", prefixColour = 12, level = "topics" })
end

EVENTS["331"] = function(s, m)
    local b = s.client:findBuffer(s, m.params[2] or "")
    if b then b.topic = ""; s.client:note(b, "No topic is set for " .. b.name, "topics") end
end

EVENTS["333"] = function(s, m)
    local b = s.client:findBuffer(s, m.params[2] or "")
    local when = convert.toInteger(m.params[4])
    if b then
        s.client:note(b, "Topic set by " .. colour(C.nickColour(m.params[3] or "?"), m.params[3] or "?")
            .. (when and os.date and (" on " .. os.date("%Y-%m-%d %H:%M", when)) or ""), "topics")
    end
end

EVENTS["324"] = function(s, m)
    local b = s.client:findBuffer(s, m.params[2] or "")
    if b then
        b.modes = table.concat(m.params, " ", 3)
        s.client:note(b, "Channel " .. b.name .. " modes: " .. b.modes, "modes")
    end
end

EVENTS["329"] = function() end      -- (when the channel was made: not worth a line)

-- WHOIS, in a BitchX-style box in the buffer it was asked from.
local function whoisLine(s, line)
    local w = s.whois
    local b = (w and w.buffer) or s.client.current
    s.client:print(b, colour(14, "|") .. " " .. line, { prefix = "", level = "crap" })
end

EVENTS["311"] = function(s, m)
    local b = (s.client.current.server == s) and s.client.current or s.buffer
    s.whois = { buffer = b }
    s.client:print(b, colour(14, ".--[ ") .. colour(C.nickColour(m.params[2]), m.params[2]) .. colour(14, " ]" .. ("-"):rep(20)),
        { prefix = "", level = "crap" })
    whoisLine(s, (m.params[3] or "") .. "@" .. (m.params[4] or "") .. " (" .. (m.params[6] or "") .. "\15)")
end
EVENTS["319"] = function(s, m) whoisLine(s, "channels: " .. (m.params[3] or "")) end
EVENTS["312"] = function(s, m) whoisLine(s, "server: " .. (m.params[3] or "") .. " (" .. (m.params[4] or "") .. ")") end
EVENTS["313"] = function(s, m) whoisLine(s, m.params[3] or "is an operator") end
EVENTS["301"] = function(s, m)
    if s.whois then return whoisLine(s, "away: " .. (m.params[3] or "")) end
    local b = s.client:findBuffer(s, m.params[2] or "") or s.client.current
    s.client:note(b, (m.params[2] or "") .. " is away: " .. (m.params[3] or ""))
end
EVENTS["330"] = function(s, m) whoisLine(s, "account: " .. (m.params[3] or "")) end
EVENTS["320"] = function(s, m) whoisLine(s, m.params[3] or "") end
EVENTS["671"] = function(s, m) whoisLine(s, m.params[3] or "") end
EVENTS["317"] = function(s, m)
    local idle = convert.toInteger(m.params[3]) or 0
    local line = "idle: " .. convert.duration(idle)
    local signon = convert.toInteger(m.params[4])
    if signon and os.date then line = line .. ", on since " .. os.date("%Y-%m-%d %H:%M", signon) end
    whoisLine(s, line)
end
EVENTS["318"] = function(s)
    local b = (s.whois and s.whois.buffer) or s.client.current
    s.client:print(b, colour(14, "`" .. ("-"):rep(30)), { prefix = "", level = "crap" })
    s.whois = nil
end

EVENTS["305"] = function(s, m) s.away = nil; s.client:note(s.client.current, m.params[2] or "You're back") end
EVENTS["306"] = function(s, m) s.away = true; s.client:note(s.client.current, m.params[2] or "You're away") end

-- MOTD and the rest of the welcome: into the server's buffer.
local function serverText(s, m)
    s.client:print(s.buffer, m.params[#m.params] or "", { prefix = "--", prefixColour = 12, level = "crap" })
end
for _, n in ipairs({ "002", "003", "372", "375", "376", "251", "255", "265", "266", "250" }) do EVENTS[n] = serverText end
EVENTS["004"] = function() end
EVENTS["252"] = function(s, m) serverText(s, { params = { m.params[2] .. " " .. (m.params[3] or "") } }) end
EVENTS["254"] = EVENTS["252"]

EVENTS["322"] = function(s, m)
    s.client:print(s.listBuffer or s.buffer, colour(14, string.format("%-16s", m.params[2] or "")) .. " "
        .. string.format("%4s", m.params[3] or "") .. "  " .. (m.params[4] or ""), { prefix = "--", prefixColour = 12 })
end
EVENTS["321"] = function() end
EVENTS["323"] = function(s) s.client:note(s.listBuffer or s.buffer, "End of the list"); s.listBuffer = nil end

-- WHO's last param, "hops realname": the real name.
local function realName(last)
    local hops, rest = text.cut(last, " ")
    if rest and scan.isUnsigned(hops) then return rest end
    return last
end

EVENTS["352"] = function(s, m)
    s.client:note(s.client.current, string.format("%-12s %-12s %-3s %s@%s (%s)", m.params[2] or "", m.params[6] or "",
        m.params[7] or "", m.params[3] or "", m.params[4] or "", realName(m.params[8] or "")))
end
EVENTS["315"] = function() end

-- Any other numeric: an error in the buffer it's about (4xx, 5xx) or the
-- server's.
EVENTS.numeric = function(s, m)
    local client = s.client
    local about = table.concat(m.params, " ", 2, #m.params - 1)
    local line = (about ~= "" and (about .. ": ") or "") .. (m.params[#m.params] or "")
    if #m.params < 2 then line = m.params[1] or "" end
    local code = convert.toInteger(m.command) or 0
    if code >= 400 and code < 600 then
        local b = (client.current.server == s) and client.current or s.buffer
        client:err(b, line)
    else
        client:print(s.buffer, line, { prefix = "--", prefixColour = 12, level = "crap" })
    end
end

--------------------------------------------------------------------------
-- What's typed
--------------------------------------------------------------------------
-- What $<character> stands for in an alias ($ and a digit, the words,
-- is read in expandAlias).
local ALIAS_VARS = {
    ["*"] = function(at) at.usedArgs = true; return at.args end,
    N = function(at) return (at.server and at.server.nick) or at.client:setting("nick") end,
    C = function(at)
        local b = at.buffer
        return (b.kind == "channel" or b.kind == "query") and b.name or ""
    end,
    ["$"] = function() return "$" end,
}

-- alias = { "$" digit [ "-" ] | "$" var | character }
-- $0 $1... words, $0- $1-... from that word on, $* all, $N nick, $C
-- channel, $$ a $; a $ before anything else is itself.
function Client:expandAlias(exp, args, buffer)
    local w = text.words(args)
    local at = { args = args, buffer = buffer, client = self, server = buffer.server or self:activeServer(buffer) }
    local sc, out = scan.new(exp), {}
    while not sc:atEnd() do
        local ch = sc:advance()
        local var = sc:peek()
        if ch == "$" and scan.isDigit(var) then
            sc:advance()
            local n = convert.toInteger(var)
            if sc:accept("-") then out[#out + 1] = table.concat(w, " ", n + 1)
            else out[#out + 1] = w[n + 1] or "" end
            at.usedArgs = true
        elseif ch == "$" and ALIAS_VARS[var] then
            sc:advance()
            out[#out + 1] = ALIAS_VARS[var](at)
        else
            out[#out + 1] = ch
        end
    end
    local line = table.concat(out)
    if not at.usedArgs and args ~= "" then line = line .. " " .. args end
    return text.trim(line)
end

-- A line as typed in a buffer: a /command, or text for the channel or
-- query there.  "//text" sends "/text".
function Client:command(line, buffer, depth)
    buffer = buffer or self.current
    depth = depth or 0
    if depth > 10 then return self:err(buffer, "aliases nested too deep") end
    local typed = text.stripPrefix(line, "/")
    if not typed or text.startsWith(typed, "/") then
        local said = typed or line
        if self:emit("send text", said, buffer.server, buffer) then return end
        return self:say(buffer, said)
    end
    local name, args = splitWord(typed)
    name = name:lower()
    if name == "" then return end
    if self:emit("send command", line, buffer.server, buffer) then return end
    if scan.isUnsigned(name) then return self:command("/window " .. name, buffer, depth + 1) end
    local alias = self.aliases[name]
    if alias then
        for _, part in ipairs(text.split(alias, ";")) do
            local expanded = self:expandAlias(part, args, buffer)
            self:command("/" .. expanded, buffer, depth + 1)
        end
        return
    end
    local cmd = self.commands[name]
    if cmd then
        local server = buffer.server or self:activeServer(buffer)
        local ok, err = pcall(cmd.fn, args, server, buffer, self)
        if not ok then self:err(buffer, "/" .. name .. ": " .. tostring(err)) end
        self.dirty = true
        return
    end
    -- anything else goes to the server as it is (/stats, /admin, /knock...)
    local server = buffer.server or self:activeServer(buffer)
    if not server or not server.registered then return self:err(buffer, "no such command: /" .. name) end
    server:send(name:upper() .. (args ~= "" and (" " .. args) or ""))
end

-- Text typed in a buffer: to its channel or query.
function Client:say(buffer, typed)
    if typed == "" then return end
    local s = buffer.server
    if buffer.kind ~= "channel" and buffer.kind ~= "query" then
        return self:err(buffer, "this isn't a channel or query: /join #channel, or /msg nick text")
    end
    if not s or not s.registered then return self:err(buffer, "not connected") end
    if buffer.kind == "channel" and not buffer.joined then return self:err(buffer, "you're not in " .. buffer.name .. " (/join)") end
    for _, piece in ipairs(s:message(buffer.name, typed)) do
        local mode = ""
        if buffer.kind == "channel" then
            local entry = buffer:getNick(s.nick)
            mode = entry and entry.prefix:sub(1, 1) or ""
        end
        self:print(buffer, piece, { prefix = mode .. s.nick, prefixColour = 0, level = "own", nick = s.nick })
    end
    self:emit(buffer.kind == "channel" and "message own_public" or "message own_private", s, typed, buffer.name)
end

--------------------------------------------------------------------------
-- The built-in commands: COMMANDS.name = { fn(args, server, buffer, client), usage, help }
--------------------------------------------------------------------------
local function needServer(server, buffer, client)
    if not server or not server.registered then
        client:err(buffer, "not connected (/connect <network or host>)")
        return false
    end
    return true
end

-- The channel a command is about: the one named first in args, or the
-- buffer's.  The channel and the rest of args.
local function channelArg(server, buffer, args)
    local first, rest = splitWord(args)
    if server and first ~= "" and server:isChannel(first) then return first, rest end
    if buffer.kind == "channel" then return buffer.name, args end
    return nil, args
end

COMMANDS.help = { function(args, _, buffer, client)
    local name = text.words(args)[1]
    if name then name = text.stripPrefix(name, "/") or name end
    if name then
        name = name:lower()
        local cmd = client.commands[name]
        if cmd then
            client:note(buffer, "/" .. name .. " " .. (cmd.usage or ""))
            if cmd.help then client:note(buffer, cmd.help) end
        elseif client.aliases[name] then
            client:note(buffer, "/" .. name .. " is an alias for /" .. client.aliases[name])
        else
            client:err(buffer, "no command /" .. name)
        end
        return
    end
    local names = tables.sortedKeys(client.commands)
    client:note(buffer, "Commands (/help <command> for more; anything else goes to the server as it is):")
    local row = {}
    for _, n in ipairs(names) do
        row[#row + 1] = n
        if #row == 8 then client:note(buffer, table.concat(row, " ")); row = {} end
    end
    if #row > 0 then client:note(buffer, table.concat(row, " ")) end
    client:note(buffer, "Keys: Alt+1..9 buffers, Alt+Left/Right or Ctrl+P/N, Alt+A next active, PgUp/PgDn scroll, "
        .. "Tab completes, Ctrl+C then b/c/u/r/o: bold, colour, underline, reverse, plain")
end, "[command]", "the commands, or one's help" }

-- A network's settings, or a host[:port] given as it is.
local function serverFor(client, target, port)
    local s = client:findServer(target)
    if s then return s end
    local address = client.values["network." .. target .. ".address"]
    if address then
        local p = convert.toInteger(client.values["network." .. target .. ".port"]) or 6667
        return client:newServer(target, address, p)
    end
    -- host:port, or a host alone
    local host, p = text.cutLast(target, ":")
    if not scan.isUnsigned(p) then host, p = target, nil end
    p = convert.toInteger(port or p) or 6667
    return client:findServer(host) or client:newServer(host, host, p)
end

COMMANDS.connect = { function(args, _, buffer, client)
    local w = text.words(args)
    if not w[1] then
        local names = client:networks()
        if #names == 0 then return client:err(buffer, "connect where? /connect <host> [port], or /network add <name> <host> [port]") end
        return client:note(buffer, "Networks: " .. table.concat(names, ", ") .. " (/connect <name>)")
    end
    local s = serverFor(client, w[1], w[2])
    if w[3] then client.values["network." .. s.name .. ".nick"] = w[3] end
    if s.conn then return client:note(s.buffer, "Connected to " .. s.name .. " already (/reconnect)") end
    client:switch(s.buffer)
    s:start()
end, "<network | host[:port]> [port] [nick]", "connect to a network (see /network) or a server" }
COMMANDS.server = COMMANDS.connect

COMMANDS.disconnect = { function(args, server, buffer, client)
    if not server then return client:err(buffer, "not connected") end
    server:quit(args ~= "" and args or nil)
    server.reconnectAt = nil
    client:note(server.buffer, "Disconnecting from " .. server.name)
end, "[message]", "leave this buffer's server" }

COMMANDS.reconnect = { function(args, server, buffer, client)
    if not server then return client:err(buffer, "no server here") end
    if server.conn then server:quit(args ~= "" and args or "Reconnecting") end
    server.wantQuit = nil
    server.reconnectAt = client.clock() + 1
end, "[message]", "connect to this buffer's server again" }

COMMANDS.quit = { function(args, _, _, client)
    for _, s in ipairs(client.servers) do s:quit(args ~= "" and args or nil) end
    client.quitting = true
end, "[message]", "leave every server, and irc" }

function Client:networks()
    local names, seen = {}, {}
    for k in pairs(self.values) do
        local n, key = networkKey(k)
        if key ~= "address" then n = nil end
        if n and not seen[n] then seen[n] = true; names[#names + 1] = n end
    end
    table.sort(names)
    return names
end

-- /network's subcommands: fn(w, buffer, client), w the words given.
local NETWORK_SUBCOMMANDS = {
    list = function(_, buffer, client)
        local names = client:networks()
        if #names == 0 then return client:note(buffer, "No networks yet: /network add <name> <host> [port]") end
        for _, n in ipairs(names) do
            local function v(k) return client.values["network." .. n .. "." .. k] end
            client:note(buffer, colour(14, n) .. ": " .. v("address") .. " " .. (v("port") or "6667")
                .. (v("autojoin") and (", joins " .. v("autojoin")) or "") .. (v("autoconnect") == "on" and ", at the start" or ""))
        end
        client:note(buffer, "Keys: /set network.<name>.<key>: address port password nick user_name autojoin autoconnect "
            .. "sasl_user sasl_pass commands")
    end,
    add = function(w, buffer, client)
        if not w[3] then return client:err(buffer, "/network add <name> <host> [port]") end
        client:set("network." .. w[2] .. ".address", w[3])
        if w[4] then client:set("network." .. w[2] .. ".port", w[4]) end
        client:note(buffer, "Network " .. w[2] .. " is " .. w[3] .. " " .. (w[4] or "6667") .. ": /connect " .. w[2])
    end,
    del = function(w, buffer, client)
        if not w[2] then return client:err(buffer, "/network del <name>") end
        local gone = 0
        for k in pairs(client.values) do
            if text.startsWith(k, "network." .. w[2] .. ".") then client.values[k] = nil; gone = gone + 1 end
        end
        client:saveConfig()
        client:note(buffer, gone > 0 and ("Network " .. w[2] .. " is forgotten") or ("No network " .. w[2]))
    end,
}
NETWORK_SUBCOMMANDS.remove = NETWORK_SUBCOMMANDS.del

COMMANDS.network = { function(args, _, buffer, client)
    local w = text.words(args)
    local sub = NETWORK_SUBCOMMANDS[(w[1] or "list"):lower()]
    if not sub then return client:err(buffer, "/network [list | add <name> <host> [port] | del <name>]") end
    sub(w, buffer, client)
end, "[list | add <name> <host> [port] | del <name>]", "the networks you connect to by name" }

COMMANDS.join = { function(args, server, buffer, client)
    if not needServer(server, buffer, client) then return end
    local chans, key = splitWord(args)
    if chans == "" then return client:err(buffer, "/join #channel [key]") end
    local list = {}
    for _, name in ipairs(text.split(chans, ",")) do
        local c = server:isChannel(name) and name or ("#" .. name)
        list[#list + 1] = c
        local b = client:findBuffer(server, c)
        if b and b.joined then client:switch(b) end
    end
    server.joining = list[1]
    server:send(irc.build("JOIN", table.concat(list, ","), key ~= "" and key or nil))
end, "#channel[,#more] [key]", "join channels" }

COMMANDS.part = { function(args, server, buffer, client)
    if not needServer(server, buffer, client) then return end
    local chan, reason = channelArg(server, buffer, args)
    if not chan then return client:err(buffer, "/part [#channel] [message]") end
    if reason == "" then reason = client:setting("part_message") end
    server:send(irc.build("PART", chan, reason ~= "" and reason or nil))
end, "[#channel] [message]", "leave a channel (this one)" }

COMMANDS.cycle = { function(args, server, buffer, client)
    if not needServer(server, buffer, client) then return end
    local chan, reason = channelArg(server, buffer, args)
    if not chan then return client:err(buffer, "/cycle [#channel]") end
    server:send(irc.build("PART", chan, reason ~= "" and reason or nil))
    server:send(irc.build("JOIN", chan))
end, "[#channel] [message]", "leave a channel and join it again" }

COMMANDS.msg = { function(args, server, buffer, client)
    if not needServer(server, buffer, client) then return end
    local target, body = splitWord(args)
    if body == "" then return client:err(buffer, "/msg <nick | #channel> <text>") end
    server:message(target, body)
    local b = client:findBuffer(server, target)
    client:print(b or buffer, (b and "" or (colour(14, "->") .. " " .. colour(C.nickColour(target), target) .. ": ")) .. body,
        { prefix = b and server.nick or "", prefixColour = 0, level = "own" })
    client:emit(server:isChannel(target) and "message own_public" or "message own_private", server, body, target)
end, "<nick | #channel> <text>", "a message to someone (or a channel), without a query buffer" }

COMMANDS.query = { function(args, server, buffer, client)
    if not server then return client:err(buffer, "not connected") end
    local nick, body = splitWord(args)
    if nick == "" then return client:err(buffer, "/query <nick> [text]") end
    local b = client:findBuffer(server, nick) or client:newBuffer(nick, "query", server)
    client:switch(b)
    if body ~= "" then client:say(b, body) end
end, "<nick> [text]", "a buffer for talking with someone" }

COMMANDS.me = { function(args, server, buffer, client)
    if buffer.kind ~= "channel" and buffer.kind ~= "query" then return client:err(buffer, "/me is for a channel or query") end
    if not needServer(server, buffer, client) then return end
    server:send(irc.build("PRIVMSG", buffer.name, irc.ctcpQuote("ACTION", args)))
    client:print(buffer, colour(0, server.nick) .. " " .. args, { prefix = " *", prefixColour = 0, level = "own" })
    client:emit("message own_public", server, irc.ctcpQuote("ACTION", args), buffer.name)
end, "<text>", "an action: * you text" }

COMMANDS.notice = { function(args, server, buffer, client)
    if not needServer(server, buffer, client) then return end
    local target, body = splitWord(args)
    if body == "" then return client:err(buffer, "/notice <nick | #channel> <text>") end
    server:message(target, body, "NOTICE")
    client:print(buffer, body, { prefix = "-> -" .. target .. "-", prefixColour = 7, level = "own" })
end, "<nick | #channel> <text>", "a notice (no automatic replies to it)" }

COMMANDS.ctcp = { function(args, server, buffer, client)
    if not needServer(server, buffer, client) then return end
    local w = text.words(args)
    if not w[2] then return client:err(buffer, "/ctcp <nick> <command> [args]") end
    local rest = irc.afterWords(args, 2) or ""
    if w[2]:upper() == "PING" and rest == "" then rest = tostring(math.floor(client.clock() * 1000)) end
    server:send(irc.build("PRIVMSG", w[1], irc.ctcpQuote(w[2], rest)))
    client:note(buffer, "CTCP " .. w[2]:upper() .. " to " .. w[1])
end, "<nick> <command> [args]", "ask a client something (VERSION, PING, TIME)" }

COMMANDS.ping = { function(args, server, buffer, client)
    return client:command("/ctcp " .. (args ~= "" and args or (buffer.name or "")) .. " PING", buffer)
end, "<nick>", "how long a CTCP PING takes to come back" }
COMMANDS.version = { function(args, server, buffer, client)
    if args == "" then
        return client:note(buffer, "ccnix irc " .. C.VERSION .. ": BitchX's look, weechat's buffers, irssi's scripts")
    end
    return client:command("/ctcp " .. args .. " VERSION", buffer)
end, "[nick]", "this client's version, or someone's" }

COMMANDS.nick = { function(args, server, buffer, client)
    local nick = text.words(args)[1]
    if not nick then return client:note(buffer, "Your nick: " .. ((server and server.nick) or client:setting("nick"))) end
    if server and server.conn then server:send(irc.build("NICK", nick)) else client:set("nick", nick) end
end, "<nick>", "change your nick" }

COMMANDS.topic = { function(args, server, buffer, client)
    if not needServer(server, buffer, client) then return end
    local chan, topic = channelArg(server, buffer, args)
    if not chan then return client:err(buffer, "/topic [#channel] [new topic]") end
    if topic == "" then
        local b = client:findBuffer(server, chan)
        if b and b.topic then return client:note(buffer, "Topic for " .. chan .. ": " .. b.topic) end
        return server:send(irc.build("TOPIC", chan))
    end
    server:send(irc.build("TOPIC", chan, topic))
end, "[#channel] [topic]", "show or set a channel's topic" }

COMMANDS.names = { function(args, server, buffer, client)
    if not needServer(server, buffer, client) then return end
    local chan = channelArg(server, buffer, args)
    if not chan then return client:err(buffer, "/names [#channel]") end
    local b = client:findBuffer(server, chan)
    if b then b.namesDone = true end
    server:send(irc.build("NAMES", chan))
end, "[#channel]", "who's in a channel" }

local function passThrough(command, usage, help, need)
    return { function(args, server, buffer, client)
        if not needServer(server, buffer, client) then return end
        if need and args == "" then return client:err(buffer, "/" .. command:lower() .. " " .. usage) end
        server:send(command .. (args ~= "" and (" " .. args) or ""))
    end, usage, help }
end
COMMANDS.whois = passThrough("WHOIS", "<nick>", "who someone is", true)
COMMANDS.who = passThrough("WHO", "<mask | #channel>", "the users matching", true)
COMMANDS.motd = passThrough("MOTD", "", "the server's message of the day")
COMMANDS.lusers = passThrough("LUSERS", "", "how many are on the server")
COMMANDS.invite = { function(args, server, buffer, client)
    if not needServer(server, buffer, client) then return end
    local w = text.words(args)
    local chan = w[2] or (buffer.kind == "channel" and buffer.name)
    if not w[1] or not chan then return client:err(buffer, "/invite <nick> [#channel]") end
    server:send(irc.build("INVITE", w[1], chan))
end, "<nick> [#channel]", "ask someone into a channel" }

COMMANDS.list = { function(args, server, buffer, client)
    if not needServer(server, buffer, client) then return end
    server.listBuffer = server.buffer
    client:switch(server.buffer)
    server:send("LIST" .. (args ~= "" and (" " .. args) or ""))
end, "[#channels]", "the channels on the server" }

COMMANDS.mode = { function(args, server, buffer, client)
    if not needServer(server, buffer, client) then return end
    local first = text.words(args)[1]
    if not first or (not server:isChannel(first) and not server:isMe(first)) then
        if buffer.kind ~= "channel" then return client:err(buffer, "/mode <#channel | nick> [modes]") end
        args = buffer.name .. (args ~= "" and (" " .. args) or "")
    end
    server:send("MODE " .. args)
end, "[#channel | nick] <modes> [args]", "a channel's modes or yours" }

-- /op /deop /voice /devoice: "+ooo a b c" for the nicks given.
local function modeNicks(sign, letter)
    return { function(args, server, buffer, client)
        if not needServer(server, buffer, client) then return end
        if buffer.kind ~= "channel" then return client:err(buffer, "this is for a channel") end
        local nicks = text.words(args)
        if #nicks == 0 then return client:err(buffer, "which nicks?") end
        for i = 1, #nicks, 4 do
            local group = { table.unpack(nicks, i, math.min(i + 3, #nicks)) }
            server:send("MODE " .. buffer.name .. " " .. sign .. letter:rep(#group) .. " " .. table.concat(group, " "))
        end
    end, "<nick> [nick...]", (sign == "+" and "give " or "take ") .. (letter == "o" and "operator (@)" or "voice (+)") }
end
COMMANDS.op, COMMANDS.deop = modeNicks("+", "o"), modeNicks("-", "o")
COMMANDS.voice, COMMANDS.devoice = modeNicks("+", "v"), modeNicks("-", "v")

COMMANDS.kick = { function(args, server, buffer, client)
    if not needServer(server, buffer, client) then return end
    local chan, rest = channelArg(server, buffer, args)
    local nick, reason = splitWord(rest)
    if not chan or nick == "" then return client:err(buffer, "/kick [#channel] <nick> [reason]") end
    server:send(irc.build("KICK", chan, nick, reason ~= "" and reason or nil))
end, "[#channel] <nick> [reason]", "throw someone out of a channel" }

-- The ban mask for a nick in the channel (*!*@host), or what's given.
local function banMask(buffer, server, who)
    if irc.containsAny(who, "!@*") then return who end
    local host = buffer.hosts and buffer.hosts[server:fold(who)]
    return host and ("*!*@" .. host) or (who .. "!*@*")
end

COMMANDS.ban = { function(args, server, buffer, client)
    if not needServer(server, buffer, client) then return end
    if buffer.kind ~= "channel" then return client:err(buffer, "this is for a channel") end
    local who = text.words(args)[1]
    if not who then return server:send("MODE " .. buffer.name .. " +b") end
    server:send("MODE " .. buffer.name .. " +b " .. banMask(buffer, server, who))
end, "[nick | mask]", "ban someone (no mask: the ban list)" }
COMMANDS.unban = { function(args, server, buffer, client)
    if not needServer(server, buffer, client) then return end
    if buffer.kind ~= "channel" then return client:err(buffer, "this is for a channel") end
    local who = text.words(args)[1]
    if not who then return client:err(buffer, "/unban <mask>") end
    server:send("MODE " .. buffer.name .. " -b " .. banMask(buffer, server, who))
end, "<mask>", "lift a ban" }
COMMANDS.kb = { function(args, server, buffer, client)
    local nick, reason = splitWord(args)
    if nick == "" then return client:err(buffer, "/kb <nick> [reason]") end
    COMMANDS.ban[1](nick, server, buffer, client)
    COMMANDS.kick[1](nick .. (reason ~= "" and (" " .. reason) or ""), server, buffer, client)
end, "<nick> [reason]", "ban and kick" }

COMMANDS.away = { function(args, server, buffer, client)
    local message = args ~= "" and args or client:setting("away_message")
    for _, s in ipairs(client.servers) do if s.registered then s:send(irc.build("AWAY", message)) end end
end, "[message]", "say you're away, on every server" }
COMMANDS.back = { function(_, _, _, client)
    for _, s in ipairs(client.servers) do if s.registered then s:send("AWAY") end end
end, "", "say you're back" }

COMMANDS.quote = { function(args, server, buffer, client)
    if not server or not server.conn then return client:err(buffer, "not connected") end
    if args == "" then return client:err(buffer, "/quote <a line for the server>") end
    server:send(args)
end, "<line>", "send a line to the server as it is" }

COMMANDS.clear = { function(_, _, buffer) buffer.lines = {}; buffer.scroll = 0 end, "", "empty this buffer" }
COMMANDS.close = { function(_, _, buffer, client)
    local ok, why = client:closeBuffer(buffer)
    if not ok then client:err(buffer, why) end
end, "", "close this buffer (and leave its channel)" }

COMMANDS.echo = { function(args, _, buffer, client) client:print(buffer, args, { level = "crap" }) end,
    "<text>", "show text here (mIRC codes and all)" }

-- /window's subcommands: fn(w, buffer, client), w the words given.
local function stepBuffer(step)
    return function(_, _, client)
        local i = client:bufferNumber(client.current) or 1
        client:switch(client.buffers[(i - 1 + step) % #client.buffers + 1])
    end
end
local WINDOW_SUBCOMMANDS = {
    close = function(w, buffer, client)
        local b = w[2] and client.buffers[convert.toInteger(w[2]) or 0] or buffer
        local ok, why = client:closeBuffer(b)
        if not ok then client:err(buffer, why) end
    end,
    next = stepBuffer(1),
    prev = stepBuffer(-1),
    move = function(w, buffer, client)
        local to = convert.toInteger(w[2])
        if not to or to < 1 or to > #client.buffers then return client:err(buffer, "/window move <n>") end
        table.remove(client.buffers, client:bufferNumber(buffer))
        table.insert(client.buffers, to, buffer)
    end,
    list = function(_, buffer, client)
        for i, b in ipairs(client.buffers) do
            client:note(buffer, string.format("%2d. %s%s", i, b.name, b.server and b.kind ~= "server" and (" (" .. b.server.name .. ")") or ""))
        end
    end,
}

-- /window <n> | name | close | list | move <n> | next | prev (weechat's /buffer too)
COMMANDS.window = { function(args, _, buffer, client)
    local w = text.words(args)
    local sub = (w[1] or "list"):lower()
    local n = convert.toInteger(sub)
    if n then
        local b = client.buffers[n]
        if not b then return client:err(buffer, "no buffer " .. n) end
        return client:switch(b)
    end
    if WINDOW_SUBCOMMANDS[sub] then return WINDOW_SUBCOMMANDS[sub](w, buffer, client) end
    local b
    for _, x in ipairs(client.buffers) do if text.equalFold(x.name, sub) then b = x end end
    if not b then return client:err(buffer, "/window <n | name | close | list | move <n> | next | prev>") end
    client:switch(b)
end, "<n | name | close [n] | list | move <n> | next | prev>", "go to, close or move buffers" }
COMMANDS.buffer = COMMANDS.window
COMMANDS.next = { function(_, _, buffer, client) client:command("/window next", buffer) end, "", "the next buffer" }
COMMANDS.prev = { function(_, _, buffer, client) client:command("/window prev", buffer) end, "", "the buffer before" }

-- /set's wildcards: * and ?, in any case (no [ ] or \: names are plain)
local SETTING_PATTERN = { escapes = false, classes = false, fold = string.lower }

COMMANDS.set = { function(args, _, buffer, client)
    local name, value = splitWord(args)
    if name == "" or glob.hasWildcards(name, SETTING_PATTERN) then
        local wanted = name == "" and function() return true end or glob.compile(name, SETTING_PATTERN)
        local names = {}
        for k in pairs(client.settingDefs) do names[#names + 1] = k end
        for k in pairs(client.values) do if not client.settingDefs[k] then names[#names + 1] = k end end
        table.sort(names)
        for _, k in ipairs(names) do
            if wanted(k) then
                local v = client:setting(k)
                if type(v) == "boolean" then v = v and "on" or "off" end
                client:note(buffer, colour(14, k) .. " = " .. tostring(v == nil and "" or v)
                    .. (client.values[k] == nil and colour(14, " (default)") or ""))
            end
        end
        return
    end
    if name == "-default" or name == "-clear" then
        local ok, why = client:set(value, nil)
        if not ok then return client:err(buffer, why) end
        return client:note(buffer, value .. " is back to its default")
    end
    if value == "" then
        local d = client.settingDefs[name]
        local v = client:setting(name)
        if type(v) == "boolean" then v = v and "on" or "off" end
        client:note(buffer, name .. " = " .. tostring(v == nil and "" or v))
        if d and d.help then client:note(buffer, d.help) end
        return
    end
    local ok, why = client:set(name, value)
    if not ok then return client:err(buffer, name .. ": " .. why) end
    client:note(buffer, name .. " = " .. value)
end, "[name [value]] | -default <name>", "show or change settings (wildcards list them)" }

COMMANDS.alias = { function(args, _, buffer, client)
    local name, exp = splitWord(args)
    if name == "" then
        for _, n in ipairs(tables.sortedKeys(client.aliases)) do client:note(buffer, colour(14, "/" .. n) .. " = /" .. client.aliases[n]) end
        return
    end
    name = name:lower()
    name = text.stripPrefix(name, "/") or name
    if exp == "" then return client:note(buffer, "/" .. name .. " = " .. (client.aliases[name] or "(none)")) end
    client.aliases[name] = text.stripPrefix(exp, "/") or exp
    client:saveConfig()
    client:note(buffer, "/" .. name .. " = /" .. client.aliases[name])
end, "[name [expansion]]", "a command of your own: $0 $1- $* $N $C; ; between commands" }
COMMANDS.unalias = { function(args, _, buffer, client)
    local name = (text.words(args)[1] or ""):lower()
    name = text.stripPrefix(name, "/") or name
    if not client.aliases[name] then return client:err(buffer, "no alias " .. name) end
    client.aliases[name] = nil
    client:saveConfig()
    client:note(buffer, "/" .. name .. " is gone")
end, "<name>", "forget an alias" }

COMMANDS.ignore = { function(args, _, buffer, client)
    local mask, levels = splitWord(args)
    if mask == "" then
        if #client.ignores == 0 then return client:note(buffer, "Ignoring nobody") end
        for _, ig in ipairs(client.ignores) do client:note(buffer, "Ignoring " .. ig.mask .. ": " .. ig.levels) end
        return
    end
    client.ignores[#client.ignores + 1] = { mask = mask, levels = levels ~= "" and levels:lower() or "all" }
    client:saveConfig()
    client:note(buffer, "Ignoring " .. mask .. " (" .. (levels ~= "" and levels or "all") .. ")")
end, "[mask [levels]]", "ignore someone: levels public private notices actions joins parts quits nicks ctcps, or all" }
COMMANDS.unignore = { function(args, _, buffer, client)
    local mask = text.words(args)[1]
    for i, ig in ipairs(client.ignores) do
        if mask and text.equalFold(ig.mask, mask) then
            table.remove(client.ignores, i)
            client:saveConfig()
            return client:note(buffer, "Not ignoring " .. ig.mask .. " now")
        end
    end
    client:err(buffer, "not ignoring " .. tostring(mask))
end, "<mask>", "stop ignoring someone" }

COMMANDS.lastlog = { function(args, _, buffer, client)
    if args == "" then return client:err(buffer, "/lastlog <text>") end
    local want, found = args:lower(), {}
    for _, line in ipairs(buffer.lines) do
        if text.contains(irc.strip(line.text):lower(), want) or text.contains(line.prefix:lower(), want) then
            found[#found + 1] = line
        end
    end
    client:note(buffer, "Lastlog for \"" .. args .. "\": " .. #found .. " lines")
    for i = math.max(1, #found - 20), #found do
        local l = found[i]
        client:print(buffer, l.text, { prefix = l.prefix, prefixColour = l.prefixColour, time = l.time, level = "crap" })
    end
end, "<text>", "the lines in this buffer holding text (the last 20)" }

-- /script's subcommands: fn(w, buffer, client), w the words given.
local SCRIPT_SUBCOMMANDS = {
    list = function(_, buffer, client)
        local loaded = {}
        for name, sc in pairs(client.scripts) do loaded[#loaded + 1] = name .. (sc.info.version and (" " .. sc.info.version) or "") end
        table.sort(loaded)
        client:note(buffer, "Loaded: " .. (#loaded > 0 and text.join(loaded, ", ") or "none"))
        client:note(buffer, "There to load: " .. text.join(client:availableScripts(), ", "))
    end,
    load = function(w, buffer, client)
        if not w[2] then return client:err(buffer, "/script load <name>") end
        if client.scripts[w[2]] then client:unloadScript(w[2]) end
        local ok, why = client:loadScript(w[2])
        if ok then client:note(buffer, "Loaded " .. w[2]) else client:err(buffer, why) end
    end,
    unload = function(w, buffer, client)
        if not w[2] or not client.scripts[w[2]] then return client:err(buffer, "no script " .. tostring(w[2]) .. " loaded") end
        client:unloadScript(w[2])
        client:note(buffer, "Unloaded " .. w[2])
    end,
    autorun = function(w, buffer, client)
        if not w[2] then return client:err(buffer, "/script autorun <name>") end
        local list = text.words(client:setting("scripts") or "")
        for _, n in ipairs(list) do if n == w[2] then return client:note(buffer, w[2] .. " loads at the start already") end end
        list[#list + 1] = w[2]
        client:set("scripts", text.join(list, " "))
        client:note(buffer, w[2] .. " loads at the start now")
    end,
}
SCRIPT_SUBCOMMANDS.reload = SCRIPT_SUBCOMMANDS.load

COMMANDS.script = { function(args, _, buffer, client)
    local w = text.words(args)
    local sub = SCRIPT_SUBCOMMANDS[(w[1] or "list"):lower()]
    if not sub then
        return client:err(buffer, "/script [list | load <name> | unload <name> | reload <name> | autorun <name>]")
    end
    sub(w, buffer, client)
end, "[list | load | unload | reload | autorun <name>]", "Lua scripts (irssi's way): scripts/ in ~/.irc, and those that come with it" }

--------------------------------------------------------------------------
-- Scripts
--------------------------------------------------------------------------
function Client:scriptPath(name)
    local dirs = { self.home .. "/scripts", self.home .. "/scripts/autorun" }
    for _, d in ipairs(self.scriptDirs) do dirs[#dirs + 1] = d end
    for _, d in ipairs(dirs) do
        local p = d .. "/" .. name .. ".lua"
        if fs.exists(p) and not fs.isDir(p) then return p end
    end
    return nil
end

function Client:availableScripts()
    local seen, out = {}, {}
    local dirs = { self.home .. "/scripts", self.home .. "/scripts/autorun" }
    for _, d in ipairs(self.scriptDirs) do dirs[#dirs + 1] = d end
    for _, d in ipairs(dirs) do
        if fs.exists(d) and fs.isDir(d) then
            for _, f in ipairs(fs.list(d)) do
                local n = scriptName(f)
                if n and not seen[n] then seen[n] = true; out[#out + 1] = n end
            end
        end
    end
    table.sort(out)
    return out
end

-- The irc table a script is given: everything it registers is noted on
-- its record, so unloading can take it all away.
function Client:scriptApi(sc)
    local client = self
    local api = {}
    api.VERSION = C.VERSION
    function api.signal_add(name, fn)
        local e = client:signalAdd(name, fn, sc)
        sc.signals[#sc.signals + 1] = { name = name, fn = fn, entry = e }
    end
    function api.signal_add_first(name, fn)
        client:signalAdd(name, fn, sc, true)
        sc.signals[#sc.signals + 1] = { name = name, fn = fn }
    end
    function api.signal_remove(name, fn) client:signalRemove(name, fn) end
    function api.signal_emit(name, ...) return client:emit(name, ...) end
    function api.signal_stop() client.stopped = true end
    function api.command_bind(name, fn, help, usage)
        name = name:lower()
        sc.commands[#sc.commands + 1] = { name = name, old = client.commands[name] }
        client.commands[name] = {
            fn = function(args, server, buffer) return fn(args, server, buffer) end,
            usage = usage or "", help = (help or "") .. " (script " .. sc.name .. ")", script = sc }
    end
    function api.command_unbind(name)
        name = name:lower()
        for _, c in ipairs(sc.commands) do
            if c.name == name then client.commands[name] = c.old end
        end
    end
    function api.command(line, buffer) return client:command(line, buffer or client.current) end
    local function addSetting(kind)
        return function(name, default, help)
            if not client.settingDefs[name] then client:defineSetting(name, kind, default, help, sc) end
        end
    end
    api.settings_add_str, api.settings_add_int, api.settings_add_bool = addSetting("str"), addSetting("int"), addSetting("bool")
    api.settings_get_str = function(n) local v = client:setting(n); return v ~= nil and tostring(v) or nil end
    api.settings_get_int = function(n) return tonumber(client:setting(n)) end
    api.settings_get_bool = function(n) return client:setting(n) == true end
    api.settings_set = function(n, v) return client:set(n, v ~= nil and tostring(v) or nil) end
    function api.print(body, buffer, level)
        return client:print(buffer or client.core, tostring(body), { level = level or "crap" })
    end
    function api.timeout_add(ms, fn)
        local t = client:timeoutAdd(ms, fn, false, sc)
        sc.timers[#sc.timers + 1] = t
        return t
    end
    function api.timeout_add_once(ms, fn)
        local t = client:timeoutAdd(ms, fn, true, sc)
        sc.timers[#sc.timers + 1] = t
        return t
    end
    function api.timeout_remove(t) client:timeoutRemove(t) end
    function api.statusbar_item(name, fn)
        client.statusItems[#client.statusItems + 1] = { name = name, fn = fn, script = sc }
    end
    function api.active_buffer() return client.current end
    function api.active_server() return client:activeServer() end
    function api.buffers() return { table.unpack(client.buffers) } end
    function api.servers() return { table.unpack(client.servers) } end
    function api.buffer_find(name, server) return client:findBuffer(server, name) end
    function api.buffer_new(name) return client:newBuffer(name, "script") end
    function api.server_find(name) return client:findServer(name) end
    function api.switch(buffer) client:switch(buffer) end
    api.strip, api.colour, api.parse, api.build = irc.strip, C.colour, irc.parse, irc.build
    api.casefold, api.match, api.nick_colour = irc.casefold, irc.match, C.nickColour
    -- (lib/text's, as a script can't require it)
    api.words, api.split, api.trim, api.join, api.contains = text.words, text.split, text.trim, text.join, text.contains
    return api
end

function Client:loadScript(name)
    local file = self:scriptPath(name)
    if not file then return nil, "no script " .. name .. " (/script list)" end
    local src = fileio.read(file)
    if not src then return nil, "can't read " .. file end
    local sc = { name = name, path = file, signals = {}, commands = {}, timers = {}, info = {} }
    local env = setmetatable({}, { __index = _G })
    env.irc = self:scriptApi(sc)
    env.script = sc.info
    env.print = function(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
        self:print(self.core, table.concat(parts, " "), { level = "crap" })
    end
    sc.env = env
    local fn, err = load(src, "@" .. name, "t", env)
    if not fn then return nil, err end
    self.scripts[name] = sc
    local ok, e = pcall(fn)
    if not ok then
        self:unloadScript(name)
        return nil, name .. ": " .. tostring(e)
    end
    self.dirty = true
    return true
end

function Client:unloadScript(name)
    local sc = self.scripts[name]
    if not sc then return end
    if type(sc.env.unload) == "function" then pcall(sc.env.unload) end
    for _, s in ipairs(sc.signals) do self:signalRemove(s.name, s.fn) end
    for i = #sc.commands, 1, -1 do
        local c = sc.commands[i]
        if self.commands[c.name] and self.commands[c.name].script == sc then self.commands[c.name] = c.old end
    end
    for _, t in ipairs(sc.timers) do self:timeoutRemove(t) end
    for i = #self.statusItems, 1, -1 do
        if self.statusItems[i].script == sc then table.remove(self.statusItems, i) end
    end
    self.scripts[name] = nil
    self.dirty = true
end

-- At the start: scripts/autorun/, the scripts setting, the banner, the
-- networks marked autoconnect.
function Client:start()
    self:startTicking()
    if self:setting("show_banner") then self:banner() end
    local auto = self.home .. "/scripts/autorun"
    local names = {}
    if fs.exists(auto) and fs.isDir(auto) then
        for _, f in ipairs(fs.list(auto)) do
            local n = scriptName(f)
            if n then names[#names + 1] = n end
        end
    end
    for _, n in ipairs(text.words(self:setting("scripts") or "")) do names[#names + 1] = n end
    for _, n in ipairs(names) do
        if not self.scripts[n] then
            local ok, why = self:loadScript(n)
            if not ok then self:err(self.core, why) end
        end
    end
    for _, n in ipairs(self:networks()) do
        if self.values["network." .. n .. ".autoconnect"] == "on" then
            serverFor(self, n):start()
        end
    end
end

function Client:banner()
    local b = self.core
    local art = {
        { 11, "   ___ ___ _ __  (_)_  __    (_)_ __ ___" },
        { 10, "  / __/ __| '_ \\ | \\ \\/ /    | | '__/ __|" },
        { 12, " | (_| (__| | | || |>  <     | | | | (__" },
        { 2, "  \\___\\___|_| |_||_/_/\\_\\    |_|_|  \\___|" },
    }
    for _, row in ipairs(art) do self:print(b, colour(row[1], row[2]), { prefix = "", time = "", level = "crap" }) end
    self:print(b, colour(14, "  ccnix irc " .. C.VERSION .. ": BitchX's looks, weechat's buffers, irssi's scripts"),
        { prefix = "", time = "", level = "crap" })
    local nets = self:networks()
    if #nets > 0 then
        self:note(b, "Networks: " .. table.concat(nets, ", ") .. "   /connect <name>")
    else
        self:note(b, "/connect <host> to start (an ircd on the network, or a real server through the gateway);")
        self:note(b, "/network add <name> <host> keeps one by name. /help for the rest.")
    end
end

C.Client, C.Server, C.Buffer, C.EVENTS, C.COMMANDS = Client, Server, Buffer, EVENTS, COMMANDS
return C
