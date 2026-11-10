-- convert.lua -- text to values and values to text
--
--   local convert = require("convert")
--   convert.toInteger("-42")            --> -42
--   convert.toInteger("ff", 16)         --> 255
--   convert.toNumber("1.5e3")           --> 1500.0
--   convert.humanSize(1536)             --> "1.5K"
--   convert.duration(3725)              --> "1h 2m 5s"
--   convert.unescape([[a\tb\101]])      --> "a<tab>bA"
--   convert.shellQuote("it's")          --> 'it'\''s'
--
-- Each reader takes the whole string or nothing: nil, never half a value,
-- and none of Lua's tonumber leniencies (blanks around it, "0x10", "inf").
-- What a well-formed string looks like is lib/scan's (scan.isNumber ...).
--
-- Numbers:
--   convert.toInteger(s [, base])  s, a sign or none then digits in base
--                       (2-36, 10 if none; letters either case), as an
--                       integer; nil if s isn't one
--   convert.toNumber(s) s, a decimal number (scan.isNumber), or nil
--
-- Sizes and times:
--   convert.humanSize(bytes)   1023, 1.5K, 23K, 4.0M ...: one decimal below
--                       10, rounded up, as GNU's -h does
--   convert.duration(seconds)  "3d 4h", "2m 5s", "0s": the parts that
--                       aren't 0, largest first (whole seconds)
--   convert.clock(ms)   the time of day of ms past midnight (or past the
--                       epoch): "HH:MM:SS.mmm"
--   convert.timeOfDay(s)  "H:MM" or "H:MM:SS" (scan.isTime) as seconds
--                       past midnight; nil if s isn't one
--
-- Bytes:
--   convert.toHex(s)    each byte as two lower case hex digits
--   convert.fromHex(s)  the bytes back; nil if s isn't pairs of hex digits
--   convert.toBase64(s), convert.fromBase64(s)   (fromBase64: nil if s
--                       isn't base64; blanks in it are skipped)
--   convert.utf8(code)  the UTF-8 bytes for one code point
--   convert.fromUTF8(s) UTF-8 as CC shows text: Latin-1 (160-255) as
--                       itself, any other character past ASCII as "?";
--                       bytes that aren't UTF-8 are taken as Latin-1
--   convert.toUTF8(s)   CC's text (Latin-1) as UTF-8
--
-- Escapes and quoting:
--   convert.unescape(s [, echo])   C's backslash escapes made into what
--                       they stand for: \a \b \f \n \r \t \v \\ and \ooo
--                       (one to three octal digits).  With echo (printf's
--                       %b, echo -e) octal is \0ooo, and \c ends the
--                       text: then it returns the text and true.  A
--                       backslash before anything else stays as it is.
--   convert.escape(s)   the other way: \\, \n \t \r ..., and \ooo for the
--                       other control characters
--   convert.urlEncode(s)  each byte but letters, digits and - _ . ~ as %XX
--   convert.urlDecode(s [, form])  %XX back to the byte (any other % stays);
--                       with form, + is a space too
--   convert.html(s)     & < > " ' as HTML entities
--   convert.shellQuote(s)  s in single quotes, for a POSIX shell (and ccsh)

local scan = require("scan")

local convert = {}

--------------------------------------------------------------------------
-- Numbers
--------------------------------------------------------------------------

-- the value of digit character c, or nil (0-9 then a/A = 10 ... z/Z = 35)
local function digitValue(c)
    if scan.isDigit(c) then return c:byte() - 48 end
    if scan.isLower(c) then return c:byte() - 87 end
    if scan.isUpper(c) then return c:byte() - 55 end
    return nil
end

function convert.toInteger(s, base)
    base = base or 10
    if type(s) ~= "string" then return nil end
    local sc, sign = scan.new(s), 1
    if sc:accept("-") then sign = -1 else sc:accept("+") end
    if sc:atEnd() then return nil end
    local n = 0
    while not sc:atEnd() do
        local d = digitValue(sc:advance())
        if not d or d >= base then return nil end
        n = n * base + d
    end
    return sign * n
end

function convert.toNumber(s)
    if not scan.isNumber(s) then return nil end
    return (scan.new(s):readFloat())
end

--------------------------------------------------------------------------
-- Sizes and times
--------------------------------------------------------------------------

local SIZE_UNITS = { "K", "M", "G", "T" }

function convert.humanSize(n)
    if n < 1024 then return tostring(n) end
    local i = 1
    n = n / 1024
    while n >= 1024 and i < #SIZE_UNITS do n, i = n / 1024, i + 1 end
    if n < 10 then
        local v = math.ceil(n * 10) / 10
        if v < 10 then return string.format("%.1f%s", v, SIZE_UNITS[i]) end
    end
    local v = math.ceil(n)
    if v >= 1024 and i < #SIZE_UNITS then return "1.0" .. SIZE_UNITS[i + 1] end
    return v .. SIZE_UNITS[i]
end

local DURATION_PARTS = { { 86400, "d" }, { 3600, "h" }, { 60, "m" }, { 1, "s" } }

function convert.duration(seconds)
    local left, parts = math.floor(seconds), {}
    for _, part in ipairs(DURATION_PARTS) do
        local n = math.floor(left / part[1])
        if n > 0 then parts[#parts + 1] = n .. part[2] end
        left = left - n * part[1]
    end
    if #parts == 0 then return "0s" end
    return table.concat(parts, " ")
end

function convert.clock(ms)
    local d = math.floor(ms) % 86400000
    return string.format("%02d:%02d:%02d.%03d", math.floor(d / 3600000), math.floor(d / 60000) % 60,
        math.floor(d / 1000) % 60, d % 1000)
end

function convert.timeOfDay(s)
    if not scan.isTime(s) then return nil end
    local h, m, sec = scan.new(s):readTime()
    return h * 3600 + m * 60 + sec
end

--------------------------------------------------------------------------
-- Bytes
--------------------------------------------------------------------------

function convert.toHex(s)
    local out = {}
    for i = 1, #s do out[i] = string.format("%02x", s:byte(i)) end
    return table.concat(out)
end

function convert.fromHex(s)
    if #s % 2 ~= 0 or not scan.all(s, scan.isHexDigit) then return nil end
    local out = {}
    for i = 1, #s, 2 do out[#out + 1] = string.char(convert.toInteger(s:sub(i, i + 1), 16)) end
    return table.concat(out)
end

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64_VALUE = {}
for i = 1, #B64 do B64_VALUE[B64:sub(i, i)] = i - 1 end

function convert.toBase64(s)
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

function convert.fromBase64(s)
    local values = {}
    for i = 1, #s do
        local c = s:sub(i, i)
        if B64_VALUE[c] then values[#values + 1] = B64_VALUE[c]
        elseif c == "=" then break
        elseif not scan.isSpace(c) then return nil end
    end
    if #values % 4 == 1 then return nil end
    local out = {}
    for i = 1, #values, 4 do
        local n, have = 0, 0
        for k = 0, 3 do
            local v = values[i + k]
            if v then have = have + 1 end
            n = n * 64 + (v or 0)
        end
        local bytes = { math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256 }
        for k = 1, have - 1 do out[#out + 1] = string.char(bytes[k]) end
    end
    return table.concat(out)
end

function convert.utf8(code)
    if code < 0x80 then return string.char(code)
    elseif code < 0x800 then return string.char(0xC0 + math.floor(code / 64), 0x80 + code % 64)
    elseif code < 0x10000 then
        return string.char(0xE0 + math.floor(code / 4096), 0x80 + math.floor(code / 64) % 64, 0x80 + code % 64)
    end
    return string.char(0xF0 + math.floor(code / 262144), 0x80 + math.floor(code / 4096) % 64,
        0x80 + math.floor(code / 64) % 64, 0x80 + code % 64)
end

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

function convert.fromUTF8(s)
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

function convert.toUTF8(s)
    if not hasHighBytes(s) then return s end
    local out = {}
    for i = 1, #s do out[i] = convert.utf8(s:byte(i)) end
    return table.concat(out)
end

--------------------------------------------------------------------------
-- Escapes and quoting
--------------------------------------------------------------------------

-- each escape letter, and the character it stands for
local C_ESCAPES = { a = "\a", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t", v = "\v", ["\\"] = "\\" }
-- and the other way, for escape
local C_NAMES = {}
for letter, c in pairs(C_ESCAPES) do C_NAMES[c] = "\\" .. letter end

-- up to three octal digits from the scanner ("" if none come)
local function readOctal(sc)
    local digits = ""
    while #digits < 3 and scan.isOctalDigit(sc:peek()) do digits = digits .. sc:advance() end
    return digits
end

function convert.unescape(s, echo)
    local sc, out = scan.new(s), {}
    while not sc:atEnd() do
        local c = sc:advance()
        if c ~= "\\" or sc:atEnd() then
            out[#out + 1] = c
        elseif echo and sc:accept("c") then
            return table.concat(out), true
        elseif C_ESCAPES[sc:peek()] then
            out[#out + 1] = C_ESCAPES[sc:advance()]
        elseif (echo and sc:accept("0")) or (not echo and scan.isOctalDigit(sc:peek())) then
            local digits = readOctal(sc)
            out[#out + 1] = string.char((tonumber(digits ~= "" and digits or "0", 8)) % 256)
        else
            out[#out + 1] = "\\"                    -- (\ before anything else stays)
        end
    end
    return table.concat(out), false
end

function convert.escape(s)
    local out = {}
    for i = 1, #s do
        local c = s:sub(i, i)
        if C_NAMES[c] then c = C_NAMES[c]
        elseif scan.isControl(c) then c = string.format("\\%03o", c:byte()) end
        out[i] = c
    end
    return table.concat(out)
end

local URL_SAFE = scan.oneOf("-_.~")

function convert.urlEncode(s)
    local out = {}
    for i = 1, #s do
        local c = s:sub(i, i)
        out[i] = (scan.isAlnum(c) or URL_SAFE(c)) and c or string.format("%%%02X", c:byte())
    end
    return table.concat(out)
end

function convert.urlDecode(s, form)
    local sc, out = scan.new(s), {}
    while not sc:atEnd() do
        if sc:at("%") and scan.isHexDigit(sc:peek(2)) and scan.isHexDigit(sc:peek(3)) then
            sc:advance()
            out[#out + 1] = string.char(convert.toInteger(sc:advance(2), 16))
        elseif form and sc:accept("+") then
            out[#out + 1] = " "
        else
            out[#out + 1] = sc:advance()
        end
    end
    return table.concat(out)
end

local HTML = { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ['"'] = "&quot;", ["'"] = "&#39;" }

function convert.html(s)
    local out = {}
    for i = 1, #s do
        local c = s:sub(i, i)
        out[i] = HTML[c] or c
    end
    return table.concat(out)
end

function convert.shellQuote(s)
    local out = {}
    for i = 1, #s do
        local c = s:sub(i, i)
        out[i] = c == "'" and "'\\''" or c
    end
    return "'" .. table.concat(out) .. "'"
end

return convert
