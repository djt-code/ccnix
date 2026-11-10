-- irc.lua -- IRC's messages and text, for the client (bin/irc) and the server (bin/ircd)
--
--   local irc = require("irc")
--   local m = irc.parse("@time=x :nick!user@host PRIVMSG #ccnix :hello there")
--   -- m.tags.time, m.source, m.nick, m.user, m.host, m.command ("PRIVMSG"),
--   -- m.params ({ "#ccnix", "hello there" })
--   irc.build("PRIVMSG", "#ccnix", "hello there")   -- "PRIVMSG #ccnix :hello there"
--
-- Messages (RFC 1459 and 2812, with IRCv3's tags): a line of at most 512
-- bytes with its CR LF, [@tags] [:source] command params..., the last
-- param after " :" when it holds spaces or starts with ":".  parse()
-- takes a line without its line ending; the command comes back in upper
-- case (a numeric as its three digits).  build() puts the ":" where it's
-- needed (buildTrailing: always on the last, as servers write text).
-- lines(buf) splits what's come in so far into whole lines and
-- what's left over (CR LF, or a bare LF as some servers send).
--
-- Names: casefold(s, mapping) as the server's CASEMAPPING folds them
-- ("rfc1459", the default: A-Z and []\~ are a-z and {}|^; "strict-rfc1459"
-- without ~ ^; "ascii" letters only), so names compare as the server
-- compares them.  isChannel(name, types), validNick(nick) (isNickStart(c)
-- and isNickChar(c): the characters a nick starts with and holds),
-- splitSource ("nick!user@host").  match(mask, s, mapping): a ban or ignore mask, *
-- and ? wildcards, folded (lib/glob's, with \ [ ] as plain characters:
-- nicks have them); compileMask(mask, mapping) the same as a test to
-- use again.
--
-- Modes: modeChanges(spec, args, takesArg) walks a MODE line's changes
-- ("+o-v" and its arguments, a list): a list of { set = true (+) or
-- false (-), letter = "o", arg = "nick" (or nil) }, each letter for which
-- takesArg(letter, set) is true taking the next argument (nil when they've
-- run out).  The server and the client each decide what a letter means.
--
-- CTCP: ctcp(text) is the command and its argument when a PRIVMSG or
-- NOTICE is \1CMD args\1 (ACTION, VERSION, PING...), else nil; ctcpQuote
-- makes one.
--
-- Text: mIRC's formatting codes in a message: \2 bold, \3 colour
-- (\3fg[,bg], two digits at most each; \3 alone ends it), \15 plain
-- again, \22 reverse, \29 italic, \30 strike, \31 underline, \17
-- monospace, \4 hex colour (read and dropped).  runs(text) splits it into
-- { text, fg, bg, bold, italic, underline, reverse } runs (fg and bg as
-- mIRC numbers 0-15, or nil); strip(text) leaves the words.  MIRC_BLIT is
-- each mIRC colour as CC's blit digit (CC has 16 colours, close enough).
--
-- Bytes: IRC is UTF-8 now; a CC screen shows one byte a character,
-- Latin-1 above 160.  fromUTF8 turns UTF-8 into that (what CC can't show
-- becomes "?"; bytes that aren't UTF-8 are taken as Latin-1 already), and
-- toUTF8 goes back.  base64 is for SASL PLAIN.  (All three are
-- lib/convert's, here by these names for the client and its scripts.)

local scan = require("scan")
local text = require("text")
local convert = require("convert")
local glob = require("glob")

local I = {}

I.MAX_LINE = 512            -- with CR LF

--------------------------------------------------------------------------
-- Reading a message
--------------------------------------------------------------------------
-- A tag's value with its escapes undone: \: is ;, \s a space, \\ a
-- backslash, \r and \n themselves; \ before anything else is that thing.
local TAG_ESCAPES = { [":"] = ";", s = " ", ["\\"] = "\\", r = "\r", n = "\n" }
local function unescapeTag(value)
    local out, sc = {}, scan.new(value)
    while not sc:atEnd() do
        local c = sc:advance()
        if c == "\\" then
            local nxt = sc:advance()
            out[#out + 1] = TAG_ESCAPES[nxt] or nxt
        else
            out[#out + 1] = c
        end
    end
    return table.concat(out)
end

-- tags = tag *( ";" tag ); tag = key [ "=" value ]
local function readTags(sc)
    local tags = {}
    local raw = sc:readWhile(function(c) return c ~= " " end)
    for _, item in ipairs(text.split(raw, ";")) do
        local key, value = text.cut(item, "=")
        tags[key] = value and unescapeTag(value) or true
    end
    return tags
end

local function notSpace(c) return c ~= " " end

-- CR and LF as spaces: a param can't hold a line break.
local function oneLine(s)
    local flat = text.replace(tostring(s), "\r", " ")
    return (text.replace(flat, "\n", " "))
end

-- nick!user@host (or a server's name, with neither ! nor @).
function I.splitSource(source)
    if not source then return nil end
    local bang = text.find(source, "!")
    local at = text.find(source, "@", (bang or 0) + 1)
    if not bang and not at then return source end
    local nick = source:sub(1, (bang or at) - 1)
    local user = bang and source:sub(bang + 1, (at or 0) - 1) or nil
    local host = at and source:sub(at + 1) or nil
    return nick, user, host
end

-- A line, without its CR LF: the message, or nil and why.
function I.parse(line)
    local sc = scan.new(line)
    local m = { tags = {}, params = {} }
    sc:skipSpaces()
    if sc:accept("@") then
        m.tags = readTags(sc)
        sc:skipSpaces()
    end
    if sc:accept(":") then
        m.source = sc:readWhile(notSpace)
        m.nick, m.user, m.host = I.splitSource(m.source)
        sc:skipSpaces()
    end
    local command = sc:readWhile(notSpace)
    if command == "" then return nil, "no command" end
    m.command = command:upper()
    -- params: middle words, then (after " :") the trailing one, spaces and all
    while true do
        sc:skipSpaces()
        if sc:atEnd() then break end
        if sc:accept(":") then
            m.params[#m.params + 1] = sc:readRest()
            break
        end
        m.params[#m.params + 1] = sc:readWhile(notSpace)
    end
    return m
end

--------------------------------------------------------------------------
-- Writing one
--------------------------------------------------------------------------
-- command and params as a line (no CR LF): the last param gets its ":"
-- when it's empty, holds a space or starts with ":".  A nil param ends
-- the list.  Line breaks in a param become spaces (one can't split a
-- message into two commands).
function I.build(command, ...)
    local parts = { command }
    local n = select("#", ...)
    local params = { ... }
    for i = 1, n do
        local p = params[i]
        if p == nil then break end
        p = oneLine(p)
        local last = (i == n) or params[i + 1] == nil
        if last and (p == "" or text.contains(p, " ") or text.startsWith(p, ":")) then
            p = ":" .. p
        end
        parts[#parts + 1] = p
    end
    return table.concat(parts, " ")
end

-- The same, the last param always after " :" (as servers write a
-- numeric's text, or a message's, even one word long).
function I.buildTrailing(command, ...)
    local n = select("#", ...)
    if n == 0 then return command end
    local params = { ... }
    local last = oneLine(params[n])
    local head = n > 1 and I.build(command, table.unpack(params, 1, n - 1)) or command
    if n > 1 and text.contains(head, " :") then        -- (a middle param can't hold " :"; built as it is then)
        return I.build(command, ...)
    end
    return head .. " :" .. last
end

-- What's come in so far: the whole lines in it, and the rest.
function I.lines(buf)
    local out, from = {}, 1
    while true do
        local nl = text.find(buf, "\n", from)
        if not nl then break end
        local line = buf:sub(from, nl - 1)
        line = text.stripSuffix(line, "\r") or line
        if line ~= "" then out[#out + 1] = line end
        from = nl + 1
    end
    return out, buf:sub(from)
end

--------------------------------------------------------------------------
-- Names
--------------------------------------------------------------------------
local FOLD = {
    rfc1459 = { ["["] = "{", ["]"] = "}", ["\\"] = "|", ["~"] = "^" },
    ["strict-rfc1459"] = { ["["] = "{", ["]"] = "}", ["\\"] = "|" },
    ascii = {},
}

function I.casefold(s, mapping)
    local extra = FOLD[mapping or "rfc1459"] or FOLD.rfc1459
    local lower = s:lower()
    local out = {}
    for i = 1, #lower do
        local c = lower:sub(i, i)
        out[i] = extra[c] or c
    end
    return table.concat(out)
end

-- Does s hold any one of the characters in chars?
I.containsAny = text.containsAny
I.afterWords = text.afterWords

function I.isChannel(name, types)
    if type(name) ~= "string" or name == "" then return false end
    return text.contains(types or "#&", name:sub(1, 1))
end

-- A nick: a letter or one of []\`_^{|} first, then those, digits and -,
-- at most `most` long (30).
local NICK_FIRST = scan.oneOf("[]\\`_^{|}")
function I.isNickStart(c) return scan.isAlpha(c) or NICK_FIRST(c) end
function I.isNickChar(c) return I.isNickStart(c) or scan.isDigit(c) or c == "-" end
function I.validNick(nick, most)
    if type(nick) ~= "string" or nick == "" or #nick > (most or 30) then return false end
    return I.isNickStart(nick:sub(1, 1)) and scan.all(nick:sub(2), I.isNickChar)
end

-- modes: (("+" | "-") letter*)*, a "+" before the first sign; each
-- letter that takes an argument has the next of args.
local MODE_SIGNS = { ["+"] = true, ["-"] = false }
function I.modeChanges(spec, args, takesArg)
    local changes, set, nextArg = {}, true, 1
    for i = 1, #spec do
        local letter = spec:sub(i, i)
        if MODE_SIGNS[letter] ~= nil then
            set = MODE_SIGNS[letter]
        else
            local arg
            if takesArg(letter, set) then arg = args[nextArg]; nextArg = nextArg + 1 end
            changes[#changes + 1] = { set = set, letter = letter, arg = arg }
        end
    end
    return changes
end

-- A channel's name: # or & then no space, comma or BEL, at most 50.
function I.validChannel(name, types)
    if not I.isChannel(name, types) or #name < 2 or #name > 50 then return false end
    return not I.containsAny(name, " ,\7")
end

-- A mask (* any run, ? any one character) as a test of a string, both
-- folded.  Only * and ? are wildcards: a nick may hold \ [ and ], so
-- neither escapes nor classes are read.
function I.compileMask(mask, mapping)
    local function fold(s) return I.casefold(s, mapping) end
    return glob.compile(mask, { escapes = false, classes = false, fold = fold })
end

-- Does the mask match s?
function I.match(mask, s, mapping) return I.compileMask(mask, mapping)(s) end

--------------------------------------------------------------------------
-- CTCP
--------------------------------------------------------------------------
-- ctcp = "\1" command [ " " args ] [ "\1" ]   (the closing \1 may be lost)
function I.ctcp(message)
    if type(message) ~= "string" or #message < 2 then return nil end
    local body = text.stripPrefix(message, "\1")
    if not body then return nil end
    body = text.stripSuffix(body, "\1") or body
    local command, args = text.cut(body, " ")
    return command:upper(), args or ""
end

function I.ctcpQuote(cmd, args)
    return "\1" .. cmd:upper() .. ((args and args ~= "") and (" " .. args) or "") .. "\1"
end

--------------------------------------------------------------------------
-- Formatting codes
--------------------------------------------------------------------------
I.BOLD, I.COLOUR, I.HEX, I.PLAIN, I.MONO = "\2", "\3", "\4", "\15", "\17"
I.REVERSE, I.ITALIC, I.STRIKE, I.UNDERLINE = "\22", "\29", "\30", "\31"

-- mIRC's colours 0-15 as CC blit digits: white, black, navy, green, red,
-- brown (maroon), purple, orange, yellow, light green, teal, light cyan,
-- light blue, pink, grey, light grey
I.MIRC_BLIT = { [0] = "0", "f", "b", "d", "e", "c", "a", "1", "4", "5", "9", "9", "3", "6", "7", "8" }

local function copyStyle(st)
    return { fg = st.fg, bg = st.bg, bold = st.bold, italic = st.italic, underline = st.underline,
        reverse = st.reverse, strike = st.strike }
end

-- Up to two digits: the number, or nil (and nothing read).
local function readColourNumber(sc)
    local digits = ""
    while #digits < 2 and scan.isDigit(sc:peek()) do digits = digits .. sc:advance() end
    return convert.toInteger(digits)
end

-- \3 [fg [, bg]]: the colours it sets; \3 alone resets them.
local function readColour(sc, st)
    local fg = readColourNumber(sc)
    if not fg then st.fg, st.bg = nil, nil; return end
    st.fg = fg <= 15 and fg or nil
    if sc:peek() == "," and scan.isDigit(sc:peek(2)) then
        sc:advance()
        local bg = readColourNumber(sc)
        st.bg = bg <= 15 and bg or nil
    end
end

-- \4 RRGGBB [, RRGGBB]: read and dropped (CC can't show it).
local function skipHexColour(sc)
    local function six()
        for k = 1, 6 do if not scan.isHexDigit(sc:peek(k)) then return false end end
        sc:advance(6)
        return true
    end
    if six() and sc:peek() == "," and scan.isHexDigit(sc:peek(2)) then
        sc:advance()
        six()
    end
end

local TOGGLES = { [I.BOLD] = "bold", [I.ITALIC] = "italic", [I.UNDERLINE] = "underline",
    [I.REVERSE] = "reverse", [I.STRIKE] = "strike" }

-- The text as runs of one style each.
function I.runs(message)
    local out, st, sc = {}, {}, scan.new(message or "")
    local buf = {}
    local function flush()
        if #buf == 0 then return end
        local run = copyStyle(st)
        run.text = table.concat(buf)
        out[#out + 1] = run
        buf = {}
    end
    while not sc:atEnd() do
        local c = sc:advance()
        if TOGGLES[c] then
            flush()
            st[TOGGLES[c]] = not st[TOGGLES[c]]
        elseif c == I.COLOUR then
            flush()
            readColour(sc, st)
        elseif c == I.HEX then
            flush()
            skipHexColour(sc)
        elseif c == I.PLAIN then
            flush()
            st = {}
        elseif c == I.MONO then
            -- (monospace: a CC screen is nothing but)
        else
            buf[#buf + 1] = c
        end
    end
    flush()
    return out
end

function I.strip(message)
    local plain = {}
    for _, r in ipairs(I.runs(message)) do plain[#plain + 1] = r.text end
    return table.concat(plain)
end

--------------------------------------------------------------------------
-- Bytes (lib/convert's)
--------------------------------------------------------------------------
I.fromUTF8, I.toUTF8, I.base64 = convert.fromUTF8, convert.toUTF8, convert.toBase64

return I
