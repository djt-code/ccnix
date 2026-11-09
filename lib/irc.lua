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
-- compares them.  isChannel(name, types), validNick(nick), splitSource
-- ("nick!user@host").  match(mask, s, mapping): a ban or ignore mask, *
-- and ? wildcards, folded.
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
-- toUTF8 goes back.  base64 is for SASL PLAIN.

local scan = require("scan")

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
    local text = sc:readWhile(function(c) return c ~= " " end)
    for _, item in ipairs(scan.split(text, ";")) do
        local key, value = scan.cut(item, "=")
        tags[key] = value and unescapeTag(value) or true
    end
    return tags
end

local function notSpace(c) return c ~= " " end

-- CR and LF as spaces: a param can't hold a line break.
local function oneLine(s) return (tostring(s):gsub("\r", " "):gsub("\n", " ")) end

-- nick!user@host (or a server's name, with neither ! nor @).
function I.splitSource(source)
    if not source then return nil end
    local bang = source:find("!", 1, true)
    local at = source:find("@", (bang or 0) + 1, true)
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
        if last and (p == "" or p:find(" ", 1, true) or p:sub(1, 1) == ":") then
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
    if n > 1 and head:find(" :", 1, true) then        -- (a middle param can't hold " :"; built as it is then)
        return I.build(command, ...)
    end
    return head .. " :" .. last
end

-- What's come in so far: the whole lines in it, and the rest.
function I.lines(buf)
    local out, from = {}, 1
    while true do
        local nl = buf:find("\n", from, true)
        if not nl then break end
        local line = buf:sub(from, nl - 1)
        if line:sub(-1) == "\r" then line = line:sub(1, -2) end
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
function I.containsAny(s, chars)
    for i = 1, #chars do
        if s:find(chars:sub(i, i), 1, true) then return true end
    end
    return false
end

-- The text after the first n words (and the blanks after them), as it
-- is: afterWords("TELL steve hi there", 2) is "hi there"; nil if there
-- aren't n words and something after.
function I.afterWords(s, n)
    local sc = scan.new(s)
    sc:skipSpaces()
    for _ = 1, n do
        if sc:readWhile(function(c) return not scan.isSpace(c) end) == "" then return nil end
        sc:skipSpaces()
    end
    local rest = sc:readRest()
    return rest ~= "" and rest or nil
end

function I.isChannel(name, types)
    if type(name) ~= "string" or name == "" then return false end
    return (types or "#&"):find(name:sub(1, 1), 1, true) ~= nil
end

-- A nick: a letter or one of []\`_^{|} first, then those, digits and -,
-- at most `most` long (30).
local NICK_FIRST = scan.oneOf("[]\\`_^{|}")
local function nickFirst(c) return scan.isAlpha(c) or NICK_FIRST(c) end
local function nickChar(c) return nickFirst(c) or scan.isDigit(c) or c == "-" end
function I.validNick(nick, most)
    if type(nick) ~= "string" or nick == "" or #nick > (most or 30) then return false end
    return nickFirst(nick:sub(1, 1)) and scan.all(nick:sub(2), nickChar)
end

-- A channel's name: # or & then no space, comma or BEL, at most 50.
function I.validChannel(name, types)
    if not I.isChannel(name, types) or #name < 2 or #name > 50 then return false end
    return not I.containsAny(name, " ,\7")
end

-- Does the mask (* any run, ? any one character) match s?  Both folded.
function I.match(mask, s, mapping)
    mask, s = I.casefold(mask, mapping), I.casefold(s, mapping)
    -- the classic backtracking matcher: on a mismatch after a *, the *
    -- takes one more character and the rest is tried again
    local mi, si, starM, starS = 1, 1, nil, nil
    while si <= #s do
        local mc = mask:sub(mi, mi)
        if mc == "*" then
            starM, starS = mi, si
            mi = mi + 1
        elseif mc == "?" or (mc ~= "" and mc == s:sub(si, si)) then
            mi, si = mi + 1, si + 1
        elseif starM then
            starS = starS + 1
            mi, si = starM + 1, starS
        else
            return false
        end
    end
    while mask:sub(mi, mi) == "*" do mi = mi + 1 end
    return mi > #mask
end

--------------------------------------------------------------------------
-- CTCP
--------------------------------------------------------------------------
function I.ctcp(text)
    if type(text) ~= "string" or #text < 2 or text:sub(1, 1) ~= "\1" then return nil end
    local body = text:sub(2)
    if body:sub(-1) == "\1" then body = body:sub(1, -2) end
    local sp = body:find(" ", 1, true)
    if not sp then return body:upper(), "" end
    return body:sub(1, sp - 1):upper(), body:sub(sp + 1)
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
    return digits ~= "" and tonumber(digits) or nil
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
function I.runs(text)
    local out, st, sc = {}, {}, scan.new(text or "")
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

function I.strip(text)
    local words = {}
    for _, r in ipairs(I.runs(text)) do words[#words + 1] = r.text end
    return table.concat(words)
end

--------------------------------------------------------------------------
-- Bytes
--------------------------------------------------------------------------
-- How many bytes follow a UTF-8 lead byte b (nil: not a lead byte).
local function utf8Tail(b)
    if b >= 0xC2 and b <= 0xDF then return 1 end
    if b >= 0xE0 and b <= 0xEF then return 2 end
    if b >= 0xF0 and b <= 0xF4 then return 3 end
    return nil
end

local function isContinuation(b) return b and b >= 0x80 and b <= 0xBF end

-- Is any byte of s past ASCII?
local function hasHighBytes(s)
    for i = 1, #s do
        if s:byte(i) >= 128 then return true end
    end
    return false
end

function I.fromUTF8(s)
    if not hasHighBytes(s) then return s end
    local out, i, n = {}, 1, #s
    while i <= n do
        local b = s:byte(i)
        local tail = b >= 0x80 and utf8Tail(b)
        local whole = tail
        if tail then
            for k = 1, tail do
                if not isContinuation(s:byte(i + k)) then whole = false; break end
            end
        end
        if whole then
            local code = b % (2 ^ (6 - tail))
            for k = 1, tail do code = code * 64 + s:byte(i + k) % 64 end
            -- Latin-1 shows as itself; CC's 128-159 are its own graphics, not these
            out[#out + 1] = (code >= 160 and code <= 255) and string.char(code) or "?"
            i = i + tail + 1
        else
            out[#out + 1] = s:sub(i, i)         -- (not UTF-8: taken as Latin-1)
            i = i + 1
        end
    end
    return table.concat(out)
end

function I.toUTF8(s)
    if not hasHighBytes(s) then return s end
    local out = {}
    for i = 1, #s do
        local b = s:byte(i)
        out[i] = b < 128 and string.char(b) or string.char(0xC0 + math.floor(b / 64), 0x80 + b % 64)
    end
    return table.concat(out)
end

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
function I.base64(s)
    local out = {}
    for i = 1, #s, 3 do
        local a, b, c = s:byte(i, i + 2)
        local n = a * 65536 + (b or 0) * 256 + (c or 0)
        local quad = {}
        for k = 3, 0, -1 do
            local v = math.floor(n / 64 ^ k) % 64
            quad[#quad + 1] = B64:sub(v + 1, v + 1)
        end
        if not b then quad[3], quad[4] = "=", "="
        elseif not c then quad[4] = "=" end
        out[#out + 1] = table.concat(quad)
    end
    return table.concat(out)
end

return I
