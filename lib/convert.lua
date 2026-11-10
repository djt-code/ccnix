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
--   convert.compareIntegers(a, b)  -1, 0 or 1 as integer a (scan.isInteger)
--                       is below, equal to or above b, exactly at any
--                       length (past 2^53 too, where Lua's numbers lose
--                       digits); nil if either isn't an integer
--   convert.toBase(n, base [, high])  whole number n as its digits in base
--                       (2-36, lower case letters): toBase(255, 16) is
--                       "ff".  A negative n is its 64-bit two's complement,
--                       as C's %x and %o write one.  With high, the number
--                       is high * 2^32 + n (each 0 to 2^32 - 1), so all 64
--                       bits are exact where a Lua number in CC keeps 53.
--   convert.readFormatSpec(sc)  one printf conversion at scanner sc (at its
--                       "%"): "%" flags* width ("." precision)? letter,
--                       stepped over.  A table { flags (some of - + space
--                       # 0, as written), width (its digits, "" if none),
--                       precision (the digits after the ".", "" for a "."
--                       alone, nil with no "."), letter ("" at the end of
--                       the text), text (all of it, from the "%") }; nil
--                       (nothing stepped over) if no "%" is next.  Which
--                       letters mean something is up to the caller.
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
--   convert.fromDateTime(s)  an ISO 8601 date and time (scan.isDateTime)
--                       as seconds since 1970 UTC (no zone is UTC; the
--                       fraction of a second dropped); nil if s isn't one
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
--   convert.readEscape(sc [, echo])  the one escape at scanner sc (at its
--                       "\"), as unescape reads it: what it stands for,
--                       stepped over; "\c" (echo) gives nil and true;
--                       nil (nothing stepped over) if what follows the
--                       backslash isn't an escape
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
    local digits = sc:rest()
    if digits == "" then return nil end
    for i = 1, #digits do
        local d = digitValue(digits:sub(i, i))
        if not d or d >= base then return nil end
    end
    -- (tonumber, which turns to a float before an integer would wrap)
    if base == 10 then return sign * tonumber(digits) end
    return sign * tonumber(digits, base)
end

-- an integer's digits, without its sign and leading zeros ("" for 0)
local function magnitude(s)
    local sc = scan.new(s)
    local _ = sc:accept("+") or sc:accept("-")
    sc:readWhile(scan.oneOf("0"))
    return sc:rest()
end

function convert.compareIntegers(a, b)
    if not (scan.isInteger(a) and scan.isInteger(b)) then return nil end
    local da, db = magnitude(a), magnitude(b)
    local na, nb = da ~= "" and a:sub(1, 1) == "-", db ~= "" and b:sub(1, 1) == "-"
    if na ~= nb then return na and -1 or 1 end
    local c = 0
    if #da ~= #db then c = #da < #db and -1 or 1
    elseif da ~= db then c = da < db and -1 or 1 end
    return na and -c or c
end

function convert.toNumber(s)
    if not scan.isNumber(s) then return nil end
    return (scan.new(s):readFloat())
end

-- The digits of hi * 2^32 + lo, by long division on the two halves: each
-- step's partial value stays below 36 * 2^32, so it's exact as a double.
local DIGITS = "0123456789abcdefghijklmnopqrstuvwxyz"
function convert.toBase(n, base, high)
    local hi, lo = high, n
    if not hi then
        hi = math.floor(n / 2 ^ 32)
        lo = n - hi * 2 ^ 32
        if hi < 0 then hi = hi + 2 ^ 32 end     -- (negative: two's complement)
    end
    local out = {}
    repeat
        local r = hi % base
        hi = math.floor(hi / base)
        local v = r * 2 ^ 32 + lo
        lo = math.floor(v / base)
        r = math.floor(v % base)
        out[#out + 1] = DIGITS:sub(r + 1, r + 1)
    until hi == 0 and lo == 0
    return string.reverse(table.concat(out))
end

-- printf's flags: left-justify, sign, space for a sign, alternate form, zeros
local isFormatFlag = scan.oneOf("-+ #0")

function convert.readFormatSpec(sc)
    if not sc:accept("%") then return nil end
    local spec = { flags = sc:readWhile(isFormatFlag), width = sc:readWhile(scan.isDigit) }
    if sc:accept(".") then spec.precision = sc:readWhile(scan.isDigit) end
    spec.letter = sc:advance()
    spec.text = "%" .. spec.flags .. spec.width .. (spec.precision and "." .. spec.precision or "") .. spec.letter
    return spec
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

-- days from 1970-01-01 to year-month-day (the civil calendar's arithmetic,
-- the year counted from March so the leap day comes last)
local function daysFromEpoch(year, month, day)
    if month <= 2 then year, month = year - 1, month + 12 end
    return 365 * year + math.floor(year / 4) - math.floor(year / 100) + math.floor(year / 400)
        + math.floor((153 * (month - 3) + 2) / 5) + day - 719469
end

function convert.fromDateTime(s)
    if not scan.isDateTime(s) then return nil end
    local t = scan.new(s):readDateTime()
    return daysFromEpoch(t.year, t.month, t.day) * 86400 + t.hour * 3600 + t.minute * 60 + t.second
        - (t.offset or 0)
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

function convert.readEscape(sc, echo)
    if not sc:at("\\") or sc:peek(2) == "" then return nil end
    local from = sc:pos()
    sc:advance()
    if echo and sc:accept("c") then return nil, true end
    if C_ESCAPES[sc:peek()] then return C_ESCAPES[sc:advance()] end
    if (echo and sc:accept("0")) or (not echo and scan.isOctalDigit(sc:peek())) then
        local digits = readOctal(sc)
        return string.char((tonumber(digits ~= "" and digits or "0", 8)) % 256)
    end
    sc:setPos(from)
    return nil
end

function convert.unescape(s, echo)
    local sc, out = scan.new(s), {}
    while not sc:atEnd() do
        local c, stop = convert.readEscape(sc, echo)
        if stop then return table.concat(out), true end
        out[#out + 1] = c or sc:advance()           -- (\ before anything else stays)
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
