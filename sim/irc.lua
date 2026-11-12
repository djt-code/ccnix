-- sim/irc.lua
--
-- IRC: lib/irc (messages, names, masks, CTCP, mIRC codes, UTF-8, base64);
-- lib/mc with fake Advanced Peripherals (both ways of calling a chat
-- box, the cooldown queue, player events, a command computer's list);
-- lib/ircd and lib/ircserv with clients that are just line queues
-- (registration, channels and their modes, messages, WHOIS, a ping
-- timeout; NickServ, its 60 seconds, ChanServ's auto-op; MC and the
-- bridge to a fake game); then lib/ircclient connected to that server
-- in memory (autojoin, hilights, queries, nick changes, CTCP, WHOIS's
-- box, scripts loaded and unloaded, aliases, ignores, the reconnect);
-- and lib/ircui drawing it on a fake 51 x 19 screen and a wide one
-- (the bars, the buffer list, the nick list), typing, Tab, Alt+digit.
local PROJ = ...
package.path = PROJ .. "/lib/?.lua;" .. PROJ .. "/sim/lib/?.lua;" .. package.path
local M = require("mock")
local scan = require("scan")
local text = require("text")
local check = M.check

-- CC:Tweaked's key codes and colours
keys = { enter = 257, tab = 258, backspace = 259, insert = 260, delete = 261, right = 262, left = 263,
    down = 264, up = 265, pageUp = 266, pageDown = 267, home = 268, ["end"] = 269, escape = 256,
    leftCtrl = 341, rightCtrl = 345, leftAlt = 342, rightAlt = 346, leftShift = 340, rightShift = 344,
    leftBracket = 91, rightBracket = 93, numPadEnter = 335, space = 32 }
for i = 0, 25 do keys[string.char(97 + i)] = 65 + i end
local DIGITS = { "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine" }
for i, name in ipairs(DIGITS) do keys[name] = 47 + i end
colours = { white = 1, orange = 2, magenta = 4, lightBlue = 8, yellow = 16, lime = 32, pink = 64, grey = 128,
    lightGrey = 256, cyan = 512, purple = 1024, blue = 2048, brown = 4096, green = 8192, red = 16384, black = 32768 }
colors = colours

-- the computer: files, a clock, timers
local S = { files = {}, dirs = {} }
fs = M.fsApi(S)
textutils = M.textutilsApi()
local CLOCK = 0
local timers, nextTimer = {}, 1
os.clock = function() return CLOCK end
os.epoch = function() return (1700000000 + CLOCK) * 1000 end
os.startTimer = function(t) local id = nextTimer; nextTimer = nextTimer + 1; timers[id] = CLOCK + t; return id end
os.cancelTimer = function(id) timers[id] = nil end
os.getComputerLabel = function() return nil end
os.getComputerID = function() return 7 end
local realTime = os.time
os.time = function(which) if which == "ingame" then return 14.5 end return realTime(which) end
os.day = function() return 12 end

-- the scripts that come with the client, into the fake disk
for _, name in ipairs({ "autoaway", "autorejoin", "hilightwin", "nickserv", "slap" }) do
    local h = io.open(PROJ .. "/lib/ircscripts/" .. name .. ".lua", "r")
    if h then
        S.files["lib/ircscripts/" .. name .. ".lua"] = h:read("a")
        h:close()
    end
end
S.dirs["lib/ircscripts"] = true
fs.list = function(dir)
    local out = {}
    dir = fs.combine(dir)
    for p in pairs(S.files) do
        local d, n = text.cutLast(p, "/")
        if n and d == dir then out[#out + 1] = n end
    end
    table.sort(out)
    return out
end

local irc = require("irc")

--------------------------------------------------------------------------
-- 1. lib/irc
--------------------------------------------------------------------------
local m = irc.parse("@time=2024-01-01T00:00:00Z;x=a\\sb\\:c :alice!al@host.lab PRIVMSG #ccnix :hello there :)")
check("parse: tags (escapes undone), source split, command, the trailing param",
    m.tags.time == "2024-01-01T00:00:00Z" and m.tags.x == "a b;c" and m.nick == "alice" and m.user == "al"
    and m.host == "host.lab" and m.command == "PRIVMSG" and m.params[1] == "#ccnix" and m.params[2] == "hello there :)")
m = irc.parse(":irc.lab 005 bob CHANTYPES=# PREFIX=(ov)@+ :are supported")
check("parse: a numeric, middle params, a server source", m.command == "005" and m.nick == "irc.lab" and not m.user
    and #m.params == 4 and m.params[3] == "PREFIX=(ov)@+")
m = irc.parse("ping :x")
check("parse: no source, the command in upper case", m.command == "PING" and m.params[1] == "x" and not m.source)
check("build: a : on the last param only when it needs one",
    irc.build("PRIVMSG", "#a", "hi there") == "PRIVMSG #a :hi there" and irc.build("JOIN", "#a") == "JOIN #a"
    and irc.build("PRIVMSG", "#a", ":)") == "PRIVMSG #a ::)" and irc.build("TOPIC", "#a", "") == "TOPIC #a :"
    and irc.build("PRIVMSG", "x", "two\r\nlines") == "PRIVMSG x :two  lines")
local lines, rest = irc.lines("PING :a\r\nNOTICE x :y\nPART")
check("lines: CR LF and a bare LF, the rest kept", #lines == 2 and lines[2] == "NOTICE x :y" and rest == "PART")
check("casefold: rfc1459's []\\~ are {}|^; ascii folds letters only",
    irc.casefold("Nick[a]\\~") == "nick{a}|^" and irc.casefold("A[]", "ascii") == "a[]")
check("validNick, validChannel", irc.validNick("Bob_[1]") and not irc.validNick("1bob") and not irc.validNick("a b")
    and irc.validChannel("#ccnix") and not irc.validChannel("ccnix") and not irc.validChannel("#a,b"))
check("isNickStart, isNickChar: a letter or []\\`_^{|} first; digits and - after",
    irc.isNickStart("a") and irc.isNickStart("[") and irc.isNickStart("|") and not irc.isNickStart("1")
    and not irc.isNickStart("-") and irc.isNickChar("1") and irc.isNickChar("-") and irc.isNickChar("\\")
    and not irc.isNickChar(" ") and not irc.isNickChar("!") and not irc.isNickChar("ab"))
local function changesText(spec, args, takes)
    local out = {}
    for _, ch in ipairs(irc.modeChanges(spec, args, takes)) do
        out[#out + 1] = (ch.set and "+" or "-") .. ch.letter .. (ch.arg and ("=" .. ch.arg) or "")
    end
    return table.concat(out, " ")
end
local function takesOLK(letter, set) return letter == "o" or letter == "k" or (letter == "l" and set) end
check("modeChanges: + first, signs toggle, each letter that takes one has the next argument (nil when none are left)",
    changesText("o-o+nl-lk", { "bob", "al", "5", "key" }, takesOLK) == "+o=bob -o=al +n +l=5 -l -k=key"
    and changesText("+oo", { "x" }, takesOLK) == "+o=x +o" and changesText("", {}, takesOLK) == ""
    and changesText("+-", { "x" }, takesOLK) == "", changesText("o-o+nl-lk", { "bob", "al", "5", "key" }, takesOLK))
check("match: * and ?, folded",irc.match("*!*@*.lab", "Bob!b@HOST.lab") and irc.match("b?b!*", "bob!x@y")
    and not irc.match("*!*@other", "bob!b@host.lab") and irc.match("*", ""))
local cmd, args = irc.ctcp("\1ACTION waves\1")
check("ctcp: ACTION and its text; a quote made", cmd == "ACTION" and args == "waves"
    and irc.ctcpQuote("version") == "\1VERSION\1" and irc.ctcp("plain") == nil)
local runs = irc.runs("a\2b\0034,2c\3d\15e\22f")
check("runs: bold, colour fg,bg, colour off, plain, reverse",
    #runs == 6 and runs[2].bold and runs[3].fg == 4 and runs[3].bg == 2 and runs[3].bold and runs[4].fg == nil
    and runs[5].bold == nil and runs[6].reverse, tostring(#runs))
check("strip; \\3 with digits after a comma that isn't a bg", irc.strip("\0034hi\3 \2there\2") == "hi there"
    and irc.strip("\0034,x") == ",x")
check("fromUTF8: Latin-1 shows as itself, the rest as ?; toUTF8 back",
    irc.fromUTF8("caf\195\169 \226\130\172") == "caf\233 ?" and irc.toUTF8("caf\233") == "caf\195\169"
    and irc.fromUTF8("ok\233") == "ok\233")
check("base64 (SASL PLAIN)", irc.base64("\0bob\0pw") == "AGJvYgBwdw==" and irc.base64("ab") == "YWI=")
check("match: a nick's \\ [ ] are plain characters (no escapes, no classes), folded as rfc1459",
    irc.match("nick\\*!*@*", "Nick|Away!u@h") and irc.match("[x]*", "{x}!u@h") and irc.match("\\*", "|x")
    and not irc.match("[a-z]*", "b") and irc.match("[a-z]*", "[A-Z]!x@y") and not irc.match("a\\b", "a*b"))
check("match: ascii casemapping keeps [ and { apart; compileMask is the same test, made once",
    not irc.match("[x]", "{x}", "ascii") and irc.match("[X]", "[x]", "ascii")
    and irc.compileMask("*!*@*.LAB")("bob!b@host.lab") and not irc.compileMask("b?b")("bb"))

--------------------------------------------------------------------------
-- 2. lib/mc
--------------------------------------------------------------------------
local mcLib = require("mc")
local said = {}
local busy = 0
local chatNew = {                       -- AP 0.8: an options table (player in it: no sendMessageToPlayer)
    sendMessage = function(text, o)
        if type(o) ~= "table" then error("bad argument #2 (table expected)") end
        if busy > 0 then busy = busy - 1; return false, "cooldown" end
        if o.player and o.player ~= "Steve" and o.player ~= "Alex" then error("player not found") end
        said[#said + 1] = (o.player and (o.player .. " <- ") or "") .. "[" .. tostring(o.prefix) .. "] " .. text
        return true
    end,
}
local game = mcLib.new({ chatBox = chatNew, playerDetector = { getOnlinePlayers = function() return { "Steve", "Alex" } end },
    environmentDetector = { isThunder = function() return false end, isRaining = function() return true end } })
check("mc: the world's time from os.time/os.day, the weather, the players",
    game.time() == "day 12, 14:30" and game.weather() == "rain" and #game.players() == 2)
game.say("hello", "bob")
busy = 1
game.say("second", "bob")
check("mc: a chat box with an options table; one refused (cooldown) waits for flush",
    said[1] == "[bob] hello" and #said == 1 and game.waiting() == 1)
game.flush()
check("mc: flush sends what waited", said[2] == "[bob] second" and game.waiting() == 0)
local old = {}
local gameOld = mcLib.new({ chatBox = { sendMessage = function(text, prefix)
    if type(prefix) == "table" then error("bad argument #2 (string expected)") end
    old[#old + 1] = "[" .. prefix .. "] " .. text
    return true
end } })
gameOld.say("hi", "amy")
check("mc: an older chat box (arguments in a row) works too", old[1] == "[amy] hi")
local toldOk = game.tell("Steve", "psst", "MC")
local toldBad, whyBad = game.tell("Nobody", "psst", "MC")
game.say("after", "bob")
check("mc: AP 0.8's tell is sendMessage with the player; one it can't send is dropped, says why, and doesn't hold up the rest",
    toldOk and said[3] == "Steve <- [MC] psst" and not toldBad and text.find(tostring(whyBad), "player not found")
    and said[4] == "[bob] after" and game.waiting() == 0, text.join(said, " | "))
local toldOld = {}
local gameOld2 = mcLib.new({ chatBox = {
    sendMessage = function() error("a tell must not go to everyone") end,
    sendMessageToPlayer = function(t, who, prefix)
        if type(prefix) == "table" then error("bad argument #3 (string expected)") end
        toldOld[#toldOld + 1] = who .. " <- [" .. prefix .. "] " .. t
        return true
    end } })
check("mc: an older chat box's tell is sendMessageToPlayer", gameOld2.tell("Alex", "hey", "MC") and toldOld[1] == "Alex <- [MC] hey")
local uuid = "1883d3ba-cf30-4e5c-ad96-e7bf6b8ade44"
local n1 = game.event("chat", uuid, "Steve", "caf?", false, "caf\195\169")
local n2 = game.event("chat", uuid, "Steve", "$psst", true, "$psst")
local n3, n4 = game.event("player_join", uuid, "Alex", "minecraft:overworld"), game.event("player_death", uuid, "Alex", "lava")
check("mc: AP 0.8's events (the UUID first; chat's UTF-8 bytes as CC's text)",
    n1.player == "Steve" and n1.text == "caf\233" and n2 == nil and n3.kind == "join" and n3.player == "Alex"
    and n4.kind == "death" and n4.player == "Alex", n1 and (tostring(n1.player) .. " " .. tostring(n1.text)))
local e1 = game.event("chat", "Steve", "yo", "uuid", false)
local e2 = game.event("chat", "Steve", "$secret", "uuid", true)
local e3, e4 = game.event("playerJoin", "Alex", "overworld"), game.event("player_leave", "Alex")
check("mc: events: chat, hidden chat ($) left out, joins and leaves by either name",
    e1.kind == "chat" and e1.player == "Steve" and e1.text == "yo" and e2 == nil and e3.kind == "join" and e4.kind == "leave")
local listed = { "There are 1 of a max of 20 players online: Steve" }
local cmdGame = mcLib.new({ commands = { exec = function(c)
    if c == "list" then return true, listed end
    return true, {}
end } })
check("mc: a command computer: list for players, no hearing", cmdGame.players()[1] == "Steve"
    and cmdGame.has.chat == "commands" and not cmdGame.has.hears)
cmdGame.poll()
listed = { "There are 1 of a max of 20 players online: Alex" }
local polled = cmdGame.poll()
check("mc: poll notices who came and went", #polled == 2 and polled[1].player == "Alex" and polled[1].kind == "join"
    and polled[2].kind == "leave")

--------------------------------------------------------------------------
-- 3. lib/ircd and lib/ircserv
--------------------------------------------------------------------------
local ircd, ircserv = require("ircd"), require("ircserv")

local function newServer(bridgeGame)
    local srv = ircd.new({ name = "irc.lab", network = "lab", motd = { "hello, lab" }, oper = "opw",
        clock = function() return CLOCK end, time = function() return 1700000000 + math.floor(CLOCK) end })
    local saved
    local seq = 0
    local services = ircserv.attach(srv, { save = function(db) saved = db end, mc = bridgeGame, bridge = "#minecraft",
        random = function(lo, hi) seq = seq + 1; return math.min(hi, lo + 123456 + seq) end })
    return srv, services, function() return saved end
end

local function fake(srv, host)
    local c = { out = {} }
    c.c = srv:connect(function(l) c.out[#c.out + 1] = l end, host or "10.1.1.9")
    function c.say(line) srv:input(c.c, line) end
    function c.has(text)
        for _, l in ipairs(c.out) do if l:find(text, 1, true) then return true end end
        return false
    end
    function c.clear() c.out = {} end
    -- the lines holding text, for a failed check's detail
    function c.dump(text)
        local got = {}
        for _, l in ipairs(c.out) do if l:find(text, 1, true) then got[#got + 1] = l end end
        return table.concat(got, " | ")
    end
    function c.login(nick)
        c.say("NICK " .. nick)
        c.say("USER " .. nick .. " 0 * :" .. nick .. " the tester")
    end
    return c
end

local fakeGame = { has = { chat = "chat box", hears = true, players = "player detector" }, said = {}, told = {} }
function fakeGame.say(text, from) fakeGame.said[#fakeGame.said + 1] = (from and ("[" .. from .. "] ") or "") .. text; return true end
function fakeGame.tell(who, text) fakeGame.told[#fakeGame.told + 1] = who .. ": " .. text; return true end
function fakeGame.players() return { "Steve" } end
function fakeGame.time() return "day 12, 14:30" end
function fakeGame.weather() return nil, "no environment detector" end
function fakeGame.flush() end

local srv, services, savedDb = newServer(fakeGame)
local alice, bob, carol = fake(srv), fake(srv), fake(srv)
alice.login("alice")
check("ircd: registered: 001 welcome, 005 ISUPPORT, the MOTD",
    alice.has(" 001 alice :Welcome to the lab IRC network alice!alice@10.1.1.9") and alice.has("PREFIX=(ov)@+")
    and alice.has(" 372 alice :- hello, lab") and alice.has(" 376 "))
do
    local odd = fake(srv)
    odd.say("NICK oddname")
    odd.say("USER a~b$c.d-e_fghijkl 0 * :odd")
    local blank = fake(srv)
    blank.say("NICK blankname")
    blank.say("USER ~!$ 0 * :blank")
    check("ircd: a user name kept to letters, digits, - . _ and ten at most; none left: user",
        odd.has("oddname!abc.d-e_fg@10.1.1.9") and blank.has("blankname!user@10.1.1.9"), odd.dump(" 001 ") .. blank.dump(" 001 "))
    odd.say("QUIT"); blank.say("QUIT")
end
bob.say("PRIVMSG alice :early")
check("ircd: before registering, 451", bob.has(" 451 "))
bob.login("bob")
carol.say("NICK Alice")
check("ircd: a nick taken (in rfc1459 case), 433", carol.has(" 433 * Alice :Nickname is already in use"))
carol.login("carol")
alice.say("JOIN #ccnix")
check("ircd: JOIN: the first in is @, NAMES and their end", alice.has(":alice!alice@10.1.1.9 JOIN #ccnix")
    and alice.has(" 353 alice = #ccnix :@alice") and alice.has(" 366 alice #ccnix "), alice.dump("#ccnix"))
bob.say("JOIN #ccnix")
check("ircd: the second: JOIN to both, no topic (331), NAMES with both",
    alice.has(":bob!bob@10.1.1.9 JOIN #ccnix") and bob.has(" 331 bob #ccnix") and bob.has(":@alice bob"))
alice.clear(); bob.clear()
bob.say("PRIVMSG #ccnix :hi all")
check("ircd: a channel message to the others, not back", alice.has(":bob!bob@10.1.1.9 PRIVMSG #ccnix :hi all")
    and not bob.has("PRIVMSG #ccnix"))
bob.say("TOPIC #ccnix :bob's topic")
check("ircd: +t: TOPIC only for operators (482)", bob.has(" 482 bob #ccnix "))
alice.say("MODE #ccnix +o bob")
bob.say("TOPIC #ccnix :bob's topic")
check("ircd: MODE +o; then the TOPIC", alice.has("MODE #ccnix +o bob") and alice.has("TOPIC #ccnix :bob's topic"))
alice.say("MODE #ccnix +k sekrit")
carol.say("JOIN #ccnix")
check("ircd: +k: no key, 475", carol.has(" 475 carol #ccnix "))
carol.say("JOIN #ccnix sekrit")
check("ircd: the key: in", carol.has(":carol!carol@10.1.1.9 JOIN #ccnix"))
alice.clear()
alice.say("KICK #ccnix carol :out")
carol.say("PRIVMSG #ccnix :still here?")
check("ircd: KICK, then +n keeps the kicked one out", alice.has("KICK #ccnix carol :out")
    and carol.has(" 404 carol #ccnix "), alice.dump("KICK") .. " / " .. carol.dump("#ccnix"))
alice.say("MODE #ccnix +b carol!*@*")
alice.say("MODE #ccnix -k *")
carol.say("JOIN #ccnix")
check("ircd: +b: banned, 474", carol.has(" 474 carol #ccnix "))
bob.clear()
bob.say("WHOIS alice")
check("ircd: WHOIS: 311, channels with @, 318", bob.has(" 311 bob alice alice 10.1.1.9 * :alice the tester")
    and bob.has(" 319 bob alice :@#ccnix") and bob.has(" 318 bob alice "), bob.dump("alice"))
bob.say("MODE #ccnix")
check("ircd: MODE #chan: its modes (324)", bob.has(" 324 bob #ccnix :+nt"), bob.dump("324"))
carol.clear()
carol.say("LIST")
check("ircd: LIST: the channels and how many are in them", carol.has(" 322 carol #ccnix 2 :bob's topic")
    and carol.has(" 322 carol #minecraft 1 ") and carol.has(" 323 "))
carol.say("OPER carol opw")
check("ircd: OPER with the password: +o", carol.has(" 381 carol "))

-- NickServ and ChanServ
alice.clear()
alice.say("PRIVMSG NickServ :REGISTER hunter2")
check("NickServ: REGISTER, kept hashed (no password in the data)",
    alice.has(":NickServ!nickserv@irc.lab NOTICE alice :alice is registered to you now")
    and savedDb().nicks.alice and savedDb().nicks.alice.hash ~= "hunter2" and #savedDb().nicks.alice.hash == 8)
alice.say("PRIVMSG ChanServ :REGISTER #ccnix")
check("ChanServ: REGISTER by an identified operator", alice.has("#ccnix is registered to alice"))
alice.say("QUIT :bye")
bob.say("PART #ccnix")
check("ircd: QUIT closes the link (dead: the program closes it)", alice.c.dead and alice.has("ERROR :Closing link"))
local eve = fake(srv)
eve.login("alice")
check("NickServ: a registered nick, not identified: told so", eve.has("This nick is registered"))
CLOCK = CLOCK + 61
srv:tick()
check("NickServ: 60 seconds on, renamed Guest1", eve.has(":alice!alice@10.1.1.9 NICK Guest1") and eve.c.nick == "Guest1")
local al2 = fake(srv)
al2.login("alice")
al2.say("PRIVMSG NickServ :IDENTIFY wrong")
al2.say("PRIVMSG NickServ :IDENTIFY hunter2")
CLOCK = CLOCK + 61
srv:tick()
check("NickServ: the wrong password refused; the right one keeps the nick",
    al2.has("Wrong password") and al2.has("identified as alice") and al2.c.nick == "alice")
eve.say("JOIN #ccnix")
check("ChanServ: a registered channel keeps its topic; its first joiner isn't @ by right",
    eve.has(" 332 Guest1 #ccnix :bob's topic") and eve.has(" 353 Guest1 = #ccnix :Guest1"), eve.dump("#ccnix"))
al2.say("JOIN #ccnix")
check("ChanServ: its founder, identified, is opped on joining", eve.has("ChanServ!chanserv@irc.lab MODE #ccnix +o alice"))

-- MC: the bridge
bob.clear()
bob.say("JOIN #minecraft")
check("MC: in #minecraft with its topic", bob.has(":@MC bob") or bob.has(":bob @MC") or bob.has("@MC"))
bob.say("PRIVMSG #minecraft :hello game")
bob.say("PRIVMSG #minecraft :\1ACTION waves\1")
check("MC: what's said there goes into the game, actions as * nick", fakeGame.said[1] == "[bob] hello game"
    and fakeGame.said[2] == "* bob waves")
services.mcEvent({ kind = "chat", player = "Steve", text = "hi irc" })
services.mcEvent({ kind = "join", player = "Alex" })
check("MC: the game's chat and joins into the channel", bob.has(":MC!mc@irc.lab PRIVMSG #minecraft :<Steve> hi irc")
    and bob.has("PRIVMSG #minecraft :* Alex joined the game"))
bob.say("PRIVMSG MC :players")
bob.say("PRIVMSG MC :time")
bob.say("PRIVMSG MC :weather")
check("MC: PLAYERS, TIME, WEATHER (none: says why)", bob.has("1 in the game: Steve") and bob.has("day 12, 14:30")
    and bob.has("Can't tell: no environment detector"), bob.dump("MC"))
al2.clear()
al2.say("PRIVMSG NickServ :VERIFY steve")
local code = fakeGame.told[1] and text.words(select(2, text.cut(fakeGame.told[1], "CONFIRM ")) or "")[1]
al2.say("PRIVMSG NickServ :CONFIRM " .. tostring(code))
bob.clear()
bob.say("WHOIS alice")
check("NickServ: VERIFY whispers a code to the player (named as the game has it); CONFIRM ties them; WHOIS says so",
    code ~= nil and fakeGame.told[1]:sub(1, 7) == "Steve: " and al2.has("is the Minecraft player Steve now")
    and bob.has(" 320 bob alice :is the Minecraft player Steve") and bob.has(" 330 bob alice alice "))
local realTell = fakeGame.tell
fakeGame.tell = function() return nil, "player not found" end
al2.clear()
al2.say("PRIVMSG NickServ :VERIFY steve")
al2.say("PRIVMSG NickServ :CONFIRM 000000")
fakeGame.tell = realTell
check("NickServ: VERIFY says so when the whisper can't be sent, and no code waits",
    al2.has("Can't whisper to Steve: player not found") and al2.has("No code is waiting"), al2.dump and al2.dump("NickServ"))

-- a ping timeout
CLOCK = CLOCK + 91
srv:tick()
check("ircd: quiet 90 seconds: PING", eve.has("PING :irc.lab"))
bob.say("PONG :irc.lab")
CLOCK = CLOCK + 91
srv:tick()
check("ircd: no PONG in 90 more: dropped; one that answered stays", eve.c.dead and eve.has("Ping timeout") and not bob.c.dead)

--------------------------------------------------------------------------
-- 4. lib/ircclient, against a server in memory
--------------------------------------------------------------------------
local ircclient = require("ircclient")
local srv2 = newServer(nil)
local connects = 0
local live = {}
local function connector(host, port)
    if host ~= "lab.test" then return nil, "no route to host" end
    connects = connects + 1
    local conn = { inbox = {}, closed = false }
    local sc = srv2:connect(function(line) conn.inbox[#conn.inbox + 1] = line .. "\r\n" end, "10.1.1.7")
    local buf = ""
    function conn:send(data)
        local got
        got, buf = irc.lines(buf .. data)
        for _, l in ipairs(got) do srv2:input(sc, l) end
        return true
    end
    function conn:read()
        while #self.inbox == 0 do
            if sc.dead or self.closed then return nil, "closed" end
            coroutine.yield("fake_net")
        end
        local d = table.concat(self.inbox)
        self.inbox = {}
        return d
    end
    function conn:close() self.closed = true; if not sc.dead then srv2:closed(sc, "Connection closed") end end
    function conn:state() return self.closed and "CLOSED" or "ESTABLISHED" end
    live[#live + 1] = { conn = conn, sc = sc }
    return conn
end
local function pump() for _ = 1, 10 do client_event("fake_net") end end
local client = ircclient.new({ noConfig = true, connect = connector, home = "/.irc", scriptDirs = { "lib/ircscripts" },
    speaker = false })
function client_event(...) client:event(...) end
do
    local labelled = {}
    for _, label in ipairs({ "My Turtle #3!", "[x]-y_z", "!!!", "1abc" }) do
        os.getComputerLabel = function() return label end
        labelled[#labelled + 1] = client:defaultNick()
    end
    os.getComputerLabel = function() return nil end
    labelled[#labelled + 1] = client:defaultNick()
    check("client: the default nick, the label's nick characters (else cc and the ID)",
        table.concat(labelled, " ") == "MyTurtle3 [x]-y_z cc7 cc7 cc7", table.concat(labelled, " "))
end
local function lastLine(b) local l = b.lines[#b.lines]; return l and irc.strip(l.text) or "" end
local function bufferHas(b, part)
    for _, l in ipairs(b.lines) do if text.contains(irc.strip(l.text), part) then return l end end
    return nil
end

local dan = fake(srv2)
dan.login("dan")
dan.say("JOIN #ccnix")
client:command("/network add lab lab.test")
client:command("/set network.lab.autojoin #ccnix")
client:command("/connect lab")
pump()
local lab = client:findServer("lab")
local chan = client:findBuffer(lab, "#ccnix")
check("client: /network add, /connect: logged in as cc7 (the default nick), autojoined, NAMES taken",
    lab and lab.registered and lab.nick == "cc7" and chan and chan.joined and chan:getNick("dan")
    and chan:getNick("dan").prefix == "@" and chan:getNick("cc7"), lab and lab.nick)
check("client: the ISUPPORT taken (NETWORK, PREFIX)", lab.network == "lab" and lab.prefixSymbols == "@+")
check("client: the server's buffer comes after the core one, the channel after it",
    client.buffers[1] == client.core and client.buffers[2] == lab.buffer and client.buffers[3] == chan)
dan.say("PRIVMSG #ccnix :hey cc7, look")
pump()
check("client: a message with my nick: hilighted, activity 3 (not on screen)", chan.lines[#chan.lines].hilight
    and chan.activity == 3 and lastLine(chan) == "hey cc7, look" and chan.lines[#chan.lines].prefix == "@dan")
dan.say("PRIVMSG #ccnix :nothing for you")
pump()
check("client: a plain message isn't", not chan.lines[#chan.lines].hilight)
client:command("/join #two")
pump()
local two = client:findBuffer(lab, "#two")
check("client: /join switches to the channel once in it", two and client.current == two and two.joined)
dan.clear()
client:command("/msg dan psst")
client:command("/2")
client:command("/window 3")
client:command("hello channel")
pump()
check("client: /msg; /2 and /window 3 switch; text to the channel", dan.has(":cc7!ccnix@10.1.1.7 PRIVMSG dan :psst")
    and client.current == chan and dan.has("PRIVMSG #ccnix :hello channel") and lastLine(chan) == "hello channel")
dan.say("PRIVMSG cc7 :a secret")
pump()
local q = client:findBuffer(lab, "dan")
check("client: a private message opens a query buffer", q and q.kind == "query" and lastLine(q) == "a secret"
    and q.activity == 3)
dan.say("NICK dan2")
pump()
check("client: a nick change: the channel's list and the query's name", chan:getNick("dan2") and not chan:getNick("dan")
    and q.name == "dan2" and bufferHas(chan, "dan is now known as dan2"))
dan.clear()
dan.say("PRIVMSG cc7 :\1VERSION\1")
pump()
check("client: CTCP VERSION answered", dan.has("NOTICE dan2 :\1VERSION ccnix irc"))
client:command("/whois dan2")
pump()
check("client: WHOIS drawn as a box", bufferHas(chan, ".--[ dan2 ]") and bufferHas(chan, "| dan@10.1.1.9")
    and bufferHas(chan, "`---"))
check("client: WHOIS's idle time as a duration (0s; 5m 3s ...)", bufferHas(chan, "| idle: 0s, on since "))
client:command("/topic a new topic")
pump()
check("client: /topic sets it (an operator? no: 482 shown as an error)", bufferHas(chan, "You're not channel operator"))
dan.say("MODE #ccnix +v cc7")
pump()
check("client: MODE +v: the prefix in the nick list", chan:getNick("cc7").prefix == "+")

-- PRIVMSG and NOTICE by kind (MESSAGE_KIND, MESSAGES)
dan.say("PRIVMSG #ccnix :\1ACTION waves\1")
dan.say("NOTICE #ccnix :heads up")
dan.say("NOTICE cc7 :\1VERSION mIRC 6\1")
pump()
local action, notice = bufferHas(chan, "dan2 waves"), bufferHas(chan, "heads up")
check("client: an ACTION as * nick text, a channel NOTICE as -nick-, a CTCP reply said",
    action and action.prefix == " *" and action.level == "actions"
    and notice and notice.prefix == "-dan2-" and notice.level == "notices"
    and (bufferHas(client.current, "CTCP VERSION reply from dan2: mIRC 6") or bufferHas(lab.buffer, "CTCP VERSION reply from dan2: mIRC 6")))

-- CAP (CAP_REPLIES, WANTED_CAPS) and SASL, with a server that only records
local capNet, capSent = { sasl_user = "bob", sasl_pass = "pw" }, {}
local capServer = { net = function(_, k) return capNet[k] end, send = function(_, l) capSent[#capSent + 1] = l end }
local EV = ircclient.EVENTS
EV.CAP(capServer, irc.parse(":irc.x CAP * LS * :multi-prefix sasl=PLAIN,EXTERNAL"))
EV.CAP(capServer, irc.parse(":irc.x CAP * LS :away-notify chghost"))
EV.CAP(capServer, irc.parse(":irc.x CAP * ACK :multi-prefix sasl away-notify"))
EV.AUTHENTICATE(capServer, irc.parse("AUTHENTICATE +"))
EV.CAP(capServer, irc.parse(":irc.x CAP * NAK :sasl"))
check("client: CAP LS over two lines, REQ for the wanted ones; ACK with sasl: AUTHENTICATE PLAIN; NAK: END",
    capSent[1] == "CAP REQ :multi-prefix sasl away-notify" and capSent[2] == "AUTHENTICATE PLAIN"
    and capSent[3] == "AUTHENTICATE " .. irc.base64("bob\0bob\0pw") and capSent[4] == "CAP END", text.join(capSent, " | "))
capNet, capSent = {}, {}
EV.CAP(capServer, irc.parse(":irc.x CAP * LS :sasl chghost"))
EV.CAP(capServer, irc.parse(":irc.x CAP * FOO :bar"))
check("client: without a SASL account, sasl isn't wanted (CAP END); an unknown subcommand is nothing",
    #capSent == 1 and capSent[1] == "CAP END", text.join(capSent, " | "))

-- /set with wildcards (lib/glob: * and ?, any case)
client:command("/set REAL*")
client:command("/set ?ick")
check("client: /set with * or ? lists the settings matching",
    bufferHas(client.current, "real_name = ") and bufferHas(client.current, "nick = cc7"))

-- scripts
dan.clear()
client:command("/script load slap")
client:command("/slap dan2")
pump()
check("client: a script's command (slap): /me through it", dan.has("PRIVMSG #ccnix :\1ACTION slaps dan2 around a bit with a large trout\1"))
client:command("/script unload slap")
check("client: unloaded, its command is gone", client.commands.slap == nil)
client:command("/script load hilightwin")
local hl = client:findBuffer(nil, "hilight")
dan.say("PRIVMSG #ccnix :cc7: ping")
pump()
check("client: hilightwin copies a hilight into its buffer", hl and lastLine(hl) == "cc7: ping" and hl.lines[#hl.lines].prefix:find("#ccnix", 1, true))
client:command("/script unload hilightwin")
check("client: unloading hilightwin closes its buffer", client:findBuffer(nil, "hilight") == nil)
client:command("/script load autorejoin")
dan.say("MODE #ccnix +o dan2")
dan.say("KICK #ccnix cc7 :bye")
pump()
check("client: kicked: not in the channel", not chan.joined and bufferHas(chan, "You were kicked from #ccnix by dan2"))
CLOCK = CLOCK + 4
for id, at in pairs(timers) do
    if at <= CLOCK then timers[id] = nil; client:event("timer", id) end
end
pump()
check("client: autorejoin joins again after its delay", chan.joined)
S.files[".irc/scripts/pong.lua"] = "irc.signal_add(\"message public\", function(server, text, nick, address, target)\n"
    .. "    if text == \"!ping\" then server:send_message(target, nick .. \": pong\") end\nend)\n"
client:command("/script load pong")
dan.clear()
dan.say("PRIVMSG #ccnix :!ping")
pump()
check("client: a script's server:send_message goes out and shows in the buffer, as yours",
    dan.has("PRIVMSG #ccnix :dan2: pong") and lastLine(chan) == "dan2: pong" and chan.lines[#chan.lines].prefix == "cc7")
client:command("/script unload pong")
local failing = "irc.signal_add(\"message public\", function() error(\"boom\") end)\n"
S.files[".irc/scripts/bad.lua"] = failing
client:command("/script load bad")
dan.say("PRIVMSG #ccnix :trigger")
pump()
check("client: a script's error is shown, the message still is", bufferHas(client.core, "script bad, signal \"message public\": ")
    and lastLine(chan) == "trigger")
client:command("/script unload bad")
S.files[".irc/scripts/stopper.lua"] = "irc.signal_add(\"send text\", function(line) if line:find('secret') then irc.signal_stop() end end)\n"
client:command("/script load stopper")
dan.clear()
client:command("my secret")
pump()
check("client: signal_stop on \"send text\" keeps the line from being sent", not dan.has("my secret"))
client:command("/script unload stopper")

-- aliases, ignores
client:command("/alias hi msg $0 hello from $N")
dan.clear()
client:command("/hi dan2")
check("client: an alias with $0 and $N", dan.has("PRIVMSG dan2 :hello from cc7"))
client:command("/ignore dan2 public")
local before = #chan.lines
dan.say("PRIVMSG #ccnix :ignored?")
pump()
check("client: /ignore public: the channel message not shown", #chan.lines == before)
client:command("/unignore dan2")

-- a lost connection, and back
for _, l in ipairs(live) do if not l.sc.dead then srv2:quit(l.sc, "Killed (test)") end end
pump()
check("client: the connection lost: said, channels out, a reconnect planned", not lab.registered and not chan.joined
    and lab.reconnectAt ~= nil)
CLOCK = CLOCK + 31
client:tick()
pump()
check("client: connected again after reconnect_time, the channel joined again", lab.registered and chan.joined
    and connects == 2)

--------------------------------------------------------------------------
-- 5. lib/ircui
--------------------------------------------------------------------------
local LOG2 = {}
for i = 0, 15 do LOG2[2 ^ i] = i end
local function window(w, h)
    local win, rows, fgs, bgs = {}, {}, {}, {}
    local x, y, fg, bg = 1, 1, "0", "f"
    for r = 1, h do rows[r], fgs[r], bgs[r] = (" "):rep(w), ("0"):rep(w), ("f"):rep(w) end
    function win.getSize() return w, h end
    function win.isColour() return true end
    function win.row(r) return rows[r] end
    function win.colours(r) return fgs[r], bgs[r] end
    function win.setCursorPos(nx, ny) x, y = nx, ny end
    function win.getCursorPos() return x, y end
    function win.setCursorBlink() end
    function win.setTextColour(c) fg = string.format("%x", LOG2[c]) end
    function win.setBackgroundColour(c) bg = string.format("%x", LOG2[c]) end
    function win.write(s)
        for i = 1, #s do
            if y >= 1 and y <= h and x >= 1 and x <= w then
                rows[y] = rows[y]:sub(1, x - 1) .. s:sub(i, i) .. rows[y]:sub(x + 1)
                fgs[y] = fgs[y]:sub(1, x - 1) .. fg .. fgs[y]:sub(x + 1)
                bgs[y] = bgs[y]:sub(1, x - 1) .. bg .. bgs[y]:sub(x + 1)
            end
            x = x + 1
        end
    end
    function win.blit(s, f, b)
        for i = 1, #s do
            fg, bg = f:sub(i, i), b:sub(i, i)
            win.write(s:sub(i, i))
        end
    end
    function win.screen()
        local out = {}
        for r = 1, h do out[r] = rows[r] end
        return table.concat(out, "\n")
    end
    return win
end
local function rowHas(win, text, from, to)
    for r = from or 1, to or 100 do
        local row = win.row(r)
        if row and row:find(text, 1, true) then return r end
    end
    return nil
end

local ircui = require("ircui")
local win = window(51, 19)
client:switch(chan)
local ui = ircui.new(client, win)
ui:draw()
check("ui: 51 x 19: the title is the topic, the status bar BitchX's, the prompt the channel",
    win.row(1):find("#ccnix:", 1, true) and rowHas(win, "[cc7", 18, 18) and rowHas(win, ":lab/#ccnix", 18, 18)
    and win.row(19):sub(1, 9) == "[#ccnix] ", "\n" .. win.screen())
check("ui: no buffer list or nick list on a narrow screen", ui.bw == 0 and ui.nw == 0)
check("ui: the bars are blue", select(2, win.colours(1)):sub(1, 5) == "bbbbb" and select(2, win.colours(18)):sub(1, 5) == "bbbbb")
check("ui: the chat: the last line at the bottom, its nick lined up", rowHas(win, "dan2 trigger", 2, 17), "\n" .. win.screen())
dan.clear()
for _, ch in ipairs({ "h", "e", "y", " ", "d", "a" }) do ui:event("char", ch) end
ui:event("key", keys.tab)
ui:draw()
check("ui: Tab completes a nick (mid-line: a space after)", ui.ed.line == "hey dan2 ", ui.ed.line)
ui:event("key", keys.enter)
pump()
check("ui: Enter sends the line", dan.has("PRIVMSG #ccnix :hey dan2"))
ui:event("char", "d"); ui:event("key", keys.tab)
check("ui: Tab at the start: nick: ", ui.ed.line == "dan2: ", ui.ed.line)
local cc9 = fake(srv2)
cc9.login("cc9")
cc9.say("JOIN #ccnix")
pump()
ui:event("key", keys.leftCtrl); ui:event("key", keys.u); ui:event("key_up", keys.leftCtrl)
ui:event("char", "c"); ui:event("key", keys.tab)
check("ui: Tab offers the others before your own nick (cc9, then cc7)", ui.ed.line == "cc9: ", ui.ed.line)
ui:event("key", keys.tab)
check("ui:   ... then your own", ui.ed.line == "cc7: ", ui.ed.line)
ui:event("key", keys.leftCtrl); ui:event("key", keys.u); ui:event("key_up", keys.leftCtrl)
check("ui: readline's keys: Ctrl+U cuts the line", ui.ed.line == "")
ui:event("key", keys.leftCtrl); ui:event("key", keys.c); ui:event("char", "c"); ui:event("key_up", keys.leftCtrl)
ui:event("key", keys.b); ui:event("char", "b")
ui:event("char", "x")
check("ui: Ctrl+C then b puts in bold's code", ui.ed.line == "\2x", require("convert").escape(ui.ed.line))
ui:draw()
local inFg, inBg = win.colours(19)
check("ui: and the line shows it as a reversed B (as irssi does), not the font's character 2",
    win.row(19):sub(10, 11) == "Bx" and inBg:sub(10, 10) == "0" and inFg:sub(10, 10) == "f" and inBg:sub(11, 11) ~= "0",
    win.row(19) .. " / " .. tostring(inFg) .. " / " .. tostring(inBg))
ui:event("key", keys.leftCtrl); ui:event("key", keys.u); ui:event("key_up", keys.leftCtrl)
ui:event("key", keys.leftAlt); ui:event("key", keys.one); ui:event("char", "1"); ui:event("key_up", keys.leftAlt)
check("ui: Alt+1: the core buffer (the 1 not typed)", client.current == client.core and ui.ed.line == "")
ui:event("key", keys.escape); ui:event("key", keys.three); ui:event("char", "3")
check("ui: Esc then 3 (as over telnet): buffer 3", client.current == chan)
ui:event("key", keys.leftCtrl); ui:event("key", keys.n); ui:event("key_up", keys.leftCtrl)
check("ui: Ctrl+N: the next buffer", client.current == client.buffers[4])
for _, b in ipairs(client.buffers) do b.activity = 0 end
dan.say("PRIVMSG #ccnix :cc7 over here")
pump()
ui:draw()
check("ui: activity in the status bar: [Act: 3] in the hilight colour", rowHas(win, "Act: 3", 18, 18))
ui:event("key", keys.leftAlt); ui:event("key", keys.a); ui:event("char", "a"); ui:event("key_up", keys.leftAlt)
check("ui: Alt+A: to the buffer with the hilight", client.current == chan and chan.activity == 0)
dan.say("PRIVMSG #ccnix :plain \2bold\2 end")
pump()
ui:draw()
local boldRow = rowHas(win, "plain bold end", 2, 17)
local boldFg = boldRow and win.colours(boldRow) or ""
local at = boldRow and win.row(boldRow):find("plain bold end", 1, true)
check("ui: chat text light grey, bold white (CC's font has no bold)",
    at and boldFg:sub(at, at + 4) == "88888" and boldFg:sub(at + 6, at + 9) == "0000" and boldFg:sub(at + 11, at + 13) == "888",
    boldRow and (win.row(boldRow) .. " / " .. boldFg))
for i = 1, 30 do client:print(chan, "line " .. i) end
ui:draw()
ui:event("key", keys.pageUp)
ui:draw()
check("ui: PgUp scrolls back: -MORE- in the status bar, the last line gone from the bottom",
    chan.scroll > 0 and rowHas(win, "-MORE(", 18, 18) and not rowHas(win, "line 30", 2, 17))
ui:event("key", keys["end"])
ui:draw()
check("ui: End (the line empty): back at the bottom", chan.scroll == 0 and rowHas(win, "line 30", 2, 17))
client:print(chan, "a long line that has to wrap because it is much wider than the chat area of this little screen")
ui:draw()
local r1 = rowHas(win, "a long line", 2, 17)
check("ui: a long line wraps under its text (the nick column kept clear)", r1 and scan.isBlank(win.row(r1 + 1):sub(1, 15)),
    "\n" .. win.screen())

local wide = window(100, 30)
local ui2 = ircui.new(client, wide)
ui2:draw()
check("ui: 100 wide: the buffer list and the nick list", ui2.bw > 0 and ui2.nw > 0 and rowHas(wide, "1.ccnix", 2, 3)
    and rowHas(wide, "3.#ccnix", 2, 8) and rowHas(wide, "@dan2", 2, 4), "\n" .. wide.screen())
ui2:event("mouse_click", 1, 3, rowHas(wide, "2.lab", 2, 8))
check("ui: a click in the buffer list goes there", client.current == lab.buffer)
ui2:draw()
check("ui: a server's buffer: no nick list", ui2.nw == 0)

-- /quit
dan.clear()
client:command("/quit leaving now")
pump()
check("client: /quit: QUIT sent, quitting", client.quitting and dan.has(":cc7!ccnix@10.1.1.7 QUIT :Quit: leaving now"))

-- the screens as they ended, to look at
M.realPrint("-- 51 x 19:\n" .. win.screen())
M.realPrint("-- 100 x 30:\n" .. wide.screen())
