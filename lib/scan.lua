-- scan.lua -- reading text a character at a time, for small parsers
--
--   local scan = require("scan")
--   local sc = scan.new([[width = 12 'it\'s']])
--   local key = sc:readName()             -- "width"
--   sc:skipSpaces()
--   sc:expect("=", "= after the name")    -- or an error: "col 7: expected = after the name"
--   sc:skipSpaces()
--   local n = sc:readNumber()             -- 12
--   sc:skipSpaces()
--   local q = sc:readQuoted("'")          -- "it's"
--   assert(sc:atEnd())
--
-- A parser written with it reads like the grammar it reads: look at the
-- next character, decide what it starts, step over it.  The little
-- languages in ccnix (ex command lines in vi, the colourers in
-- lib/syntax, IRC lines, the shell) are read this way rather than with
-- Lua patterns, so each step has a name and a comment saying what it
-- expects.  lib/regex is for regexes the user types.
--
-- The text libraries, each on the one before:
--   lib/scan     characters, the scanner, and what shape a string is
--                (this file)
--   lib/text     strings as wholes: trimming, splitting and joining,
--                prefixes, replacing, padding and wrapping, case
--   lib/convert  text to values and back: numbers, sizes, times, bytes
--                (hex, base64, UTF-8), escapes, quoting
--   lib/getopt   command-line options;  lib/glob  wildcards;
--   lib/path     path strings
--
-- A scanner, from scan.new(text [, pos]), is a place in a string:
--   sc:peek(k)          the k'th character ahead, 1 (the next one) if no k;
--                       "" past the end
--   sc:prev()           the character just stepped over ("" at the start)
--   sc:at(text)         true if text comes next (compared as it is)
--   sc:atEnd()          true if nothing is left
--   sc:advance(n)       step over n characters (1 if no n); returns them
--   sc:accept(text)     step over text if it comes next; true if it did
--   sc:expect(text, what)  the same, or an error: "col 7: expected what"
--   sc:skipSpaces()     step over blanks (isSpace); returns how many
--   sc:readWhile(test)  the characters from here on for which test(ch) is
--                       true, stepped over ("" if the next one isn't)
--   sc:readName()       a name: isNameStart, then isNameChar...; nil (and
--                       nothing stepped over) if no name starts here
--   sc:readNumber()     decimal digits: the number and its text; nil if no
--                       digit is next
--   sc:readInteger()    a sign (+ or -, or none) then digits: the number
--                       and its text; nil, nothing stepped over, if none
--   sc:readFloat()      a decimal number: a sign, digits with a point
--                       ("12", "1.5", ".5", "5."), then an exponent
--                       ("e-3") or not; the number and its text, or nil
--   sc:readTime()       a time of day, H:MM or H:MM:SS (hours 0-23, two
--                       digits for minutes and seconds, each 0-59): the
--                       hours, minutes, seconds (0 if left out) and text;
--                       nil, nothing stepped over, if it isn't one
--   sc:readDateTime()   an ISO 8601 date and time: "2026-10-29T21:04:05Z",
--                       "2026-10-29 21:04:05.5+02:00" (a T or a space
--                       between, a fraction of a second or not, a zone (Z,
--                       +hh:mm, -hhmm) or not): a table { year, month, day,
--                       hour, minute, second, offset } (offset: seconds
--                       east of UTC; nil with no zone) and the text; nil,
--                       nothing stepped over, if it isn't one
--   sc:readQuoted(q)    a string in quotes q (" or '), stepped over: its
--                       text with the escapes made into what they stand
--                       for (\n \t \r, and \ before anything else is that
--                       thing: \\ \' \").  nil if q isn't next; an error
--                       if the string doesn't end.
--   sc:readUntil(d)     the text up to the next d not escaped by a
--                       backslash, then d is stepped over.  \d in the text
--                       comes back as d; other backslash pairs stay as
--                       they are (so a regex's \( \. survive).  Returns
--                       the text and true, or, when no d comes, the text
--                       to the end and false.
--   sc:rest()           the text from here to the end (not stepped over)
--   sc:readRest()       the same, stepping to the end
--   sc:pos()            where it is: the index of the next character (1 at
--                       the start, #text + 1 at the end)
--   sc:setPos(p)        go back (or forward) to p, as pos() gave it
--   sc:fail(message)    raise "col N: message", N the next character's
--
-- Character tests, each true for one character of its kind and false for
-- anything else ("" and longer strings too).  ASCII only, as Lua's own
-- %a %d ... are in the C locale:
--   scan.isDigit     0-9                 scan.isHexDigit  0-9 a-f A-F
--   scan.isOctalDigit 0-7
--   scan.isUpper     A-Z                 scan.isLower     a-z
--   scan.isAlpha     a letter            scan.isAlnum     a letter or digit
--   scan.isNameStart a letter or _       scan.isNameChar  a letter, digit or _
--   scan.isSpace     space, tab, newline, return, vertical tab, form feed
--   scan.isPunct     printable, not a letter, digit or space: ! " # $ ...
--   scan.isPrintable space to ~ (32-126)
--   scan.isControl   the control characters: 0-31 and 127
--   scan.oneOf(chars)    a test: true for any one of the characters in chars
--
-- What shape a whole string is, each true only when all of s is that
-- thing (no blanks around it; false for anything not a string):
--   scan.all(s, test)    test holds for every character of s (true for "")
--   scan.isBlank(s)      s is "" or only blanks
--   scan.isUnsigned(s)   digits: "0", "042"
--   scan.isInteger(s)    a sign or none, then digits: "-3", "+7", "12"
--   scan.isNumber(s)     a decimal number, as readFloat reads one: "-1.5",
--                        "2e10", ".5" (not "0x10", "inf" or " 1", which
--                        Lua's tonumber would take)
--   scan.isNegative(s)   a number below zero ("-0" isn't)
--   scan.isHex(s)        hex digits, at least one: "ff", "0A1"
--   scan.isName(s)       a name: "x", "_tmp2"
--   scan.isTime(s)       a time of day as readTime reads one: "9:05",
--                        "23:59:59"
--   scan.isDateTime(s)   a date and time as readDateTime reads one
-- Turning them into values is lib/convert's.

local scan = {}

--------------------------------------------------------------------------
-- Character tests
--------------------------------------------------------------------------

-- c's byte, or nil if c isn't exactly one character
local function byteOf(c)
    if type(c) ~= "string" or #c ~= 1 then return nil end
    return c:byte()
end

local function inRange(c, lo, hi)
    local b = byteOf(c)
    return b ~= nil and b >= lo:byte() and b <= hi:byte()
end

function scan.isDigit(c) return inRange(c, "0", "9") end
function scan.isOctalDigit(c) return inRange(c, "0", "7") end
function scan.isUpper(c) return inRange(c, "A", "Z") end
function scan.isLower(c) return inRange(c, "a", "z") end
function scan.isAlpha(c) return scan.isUpper(c) or scan.isLower(c) end
function scan.isAlnum(c) return scan.isAlpha(c) or scan.isDigit(c) end
function scan.isHexDigit(c) return scan.isDigit(c) or inRange(c, "a", "f") or inRange(c, "A", "F") end
function scan.isNameStart(c) return scan.isAlpha(c) or c == "_" end
function scan.isNameChar(c) return scan.isAlnum(c) or c == "_" end

-- the blanks Lua's %s knows: space, \t \n \v \f \r (bytes 9 to 13)
function scan.isSpace(c) return c == " " or inRange(c, "\t", "\r") end

-- the printable characters (! to ~) that aren't letters or digits
function scan.isPunct(c) return inRange(c, "!", "~") and not scan.isAlnum(c) end

function scan.isPrintable(c) return inRange(c, " ", "~") end

function scan.isControl(c)
    local b = byteOf(c)
    return b ~= nil and (b < 32 or b == 127)
end

function scan.oneOf(chars)
    local set = {}
    for i = 1, #chars do set[chars:sub(i, i)] = true end
    return function(c) return set[c] == true end
end

--------------------------------------------------------------------------
-- The scanner
--------------------------------------------------------------------------

local Scanner = {}
Scanner.__index = Scanner

function scan.new(text, pos)
    return setmetatable({ text = text, i = pos or 1 }, Scanner)
end

function Scanner:pos() return self.i end

function Scanner:setPos(p) self.i = math.max(1, math.min(p, #self.text + 1)) end

function Scanner:atEnd() return self.i > #self.text end

function Scanner:peek(k)
    local at = self.i + (k or 1) - 1
    return self.text:sub(at, at)
end

function Scanner:prev()
    if self.i <= 1 then return "" end
    return self.text:sub(self.i - 1, self.i - 1)
end

function Scanner:at(s)
    return self.text:sub(self.i, self.i + #s - 1) == s
end

function Scanner:advance(n)
    n = n or 1
    local from = self.i
    self:setPos(from + n)
    return self.text:sub(from, self.i - 1)
end

function Scanner:accept(s)
    if s == "" or not self:at(s) then return false end
    self.i = self.i + #s
    return true
end

function Scanner:fail(message)
    error("col " .. self.i .. ": " .. message, 0)
end

function Scanner:expect(s, what)
    if not self:accept(s) then self:fail("expected " .. (what or s)) end
end

function Scanner:readWhile(test)
    local from = self.i
    while not self:atEnd() and test(self:peek()) do self.i = self.i + 1 end
    return self.text:sub(from, self.i - 1)
end

function Scanner:skipSpaces()
    return #self:readWhile(scan.isSpace)
end

-- name: (letter | "_") (letter | digit | "_")*
function Scanner:readName()
    if not scan.isNameStart(self:peek()) then return nil end
    return self:readWhile(scan.isNameChar)
end

-- number: digit+
function Scanner:readNumber()
    local digits = self:readWhile(scan.isDigit)
    if digits == "" then return nil end
    return tonumber(digits), digits
end

-- the text sc stepped over since `from`, as a number and as it is
local function since(sc, from)
    local text = sc.text:sub(from, sc.i - 1)
    local signless = text:sub(1, 1) == "+" and text:sub(2) or text
    return tonumber(signless), text
end

-- integer: ("+" | "-")? digit+
function Scanner:readInteger()
    local from = self.i
    local _ = self:accept("+") or self:accept("-")
    if self:readWhile(scan.isDigit) == "" then self.i = from; return nil end
    return since(self, from)
end

-- float: ("+" | "-")? (digit+ ("." digit*)? | "." digit+) (("e" | "E") ("+" | "-")? digit+)?
function Scanner:readFloat()
    local from = self.i
    local _ = self:accept("+") or self:accept("-")
    local whole = self:readWhile(scan.isDigit)
    local fraction = self:accept(".") and self:readWhile(scan.isDigit) or ""
    if whole == "" and fraction == "" then self.i = from; return nil end
    local beforeExponent = self.i
    if self:accept("e") or self:accept("E") then
        local _ = self:accept("+") or self:accept("-")
        if self:readWhile(scan.isDigit) == "" then self.i = beforeExponent end   -- ("2e" is 2, then "e")
    end
    return since(self, from)
end

-- exactly n digits next, stepped over: their number; nil (nothing
-- stepped over) if they aren't there
local function readDigits(sc, n)
    local from = sc.i
    for _ = 1, n do
        if not scan.isDigit(sc:peek()) then sc.i = from; return nil end
        sc:advance()
    end
    return tonumber(sc.text:sub(from, sc.i - 1))
end

-- the field after sep: exactly two digits in lo..hi
local function readField(sc, sep, lo, hi)
    if sep and not sc:accept(sep) then return nil end
    local n = readDigits(sc, 2)
    if not n or n < lo or n > hi then return nil end
    return n
end

-- time: digit digit? ":" MM (":" SS)?, hours 0-23, minutes and seconds
-- 0-59
function Scanner:readTime()
    local from = self.i
    local function fail() self.i = from; return nil end
    local hours = self:readWhile(scan.isDigit)
    if hours == "" or #hours > 2 or tonumber(hours) > 23 then return fail() end
    local minutes = readField(self, ":", 0, 59)
    if not minutes then return fail() end
    local seconds = 0
    if self:at(":") and scan.isDigit(self:peek(2)) then
        seconds = readField(self, ":", 0, 59)
        if not seconds then return fail() end
    end
    return tonumber(hours), minutes, seconds, self.text:sub(from, self.i - 1)
end

-- datetime: year "-" MM "-" DD ("T" | " ") hh ":" mm ":" ss fraction? zone?
--   year: 4 digits or more; fraction: ("." | ",") digit+
--   zone: "Z" | ("+" | "-") hh ":"? mm
function Scanner:readDateTime()
    local from = self.i
    local function fail() self.i = from; return nil end
    local year = self:readWhile(scan.isDigit)
    if #year < 4 then return fail() end
    local t = { year = tonumber(year) }
    t.month = readField(self, "-", 1, 12)
    t.day = t.month and readField(self, "-", 1, 31)
    if not t.day or not (self:accept("T") or self:accept(" ")) then return fail() end
    t.hour = readField(self, nil, 0, 23)
    t.minute = t.hour and readField(self, ":", 0, 59)
    t.second = t.minute and readField(self, ":", 0, 60)              -- (60: a leap second)
    if not t.second then return fail() end
    local beforeFraction = self.i
    if (self:accept(".") or self:accept(",")) and self:readWhile(scan.isDigit) == "" then self.i = beforeFraction end
    if self:accept("Z") then
        t.offset = 0
    elseif self:at("+") or self:at("-") then
        local beforeZone = self.i
        local sign = self:advance() == "+" and 1 or -1
        local hh = readField(self, nil, 0, 23)
        local _ = hh and self:accept(":")
        local mm = hh and readField(self, nil, 0, 59)
        if mm then t.offset = sign * (hh * 3600 + mm * 60) else self.i = beforeZone end
    end
    return t, self.text:sub(from, self.i - 1)
end

local ESCAPES = { n = "\n", t = "\t", r = "\r" }

-- quoted: q (any character but q or "\", or "\" then any character)* q
function Scanner:readQuoted(q)
    if not self:at(q) then return nil end
    local start = self.i
    self:advance()
    local out = {}
    while not self:atEnd() do
        local c = self:advance()
        if c == q then return table.concat(out) end
        if c == "\\" and not self:atEnd() then
            local e = self:advance()
            out[#out + 1] = ESCAPES[e] or e
        else
            out[#out + 1] = c
        end
    end
    self.i = start
    self:fail("the string has no closing " .. q)
end

-- delimited: (any character but d or "\", or "\" then any character)* d
function Scanner:readUntil(d)
    local out = {}
    while not self:atEnd() do
        local c = self:peek()
        if c == "\\" and self:peek(2) == d then
            out[#out + 1] = d
            self:advance(2)
        elseif c == "\\" then
            out[#out + 1] = self:advance(2)
        elseif c == d then
            self:advance()
            return table.concat(out), true
        else
            out[#out + 1] = c
            self:advance()
        end
    end
    return table.concat(out), false
end

function Scanner:rest() return self.text:sub(self.i) end

function Scanner:readRest()
    local s = self:rest()
    self.i = #self.text + 1
    return s
end

--------------------------------------------------------------------------
-- The shape of a whole string
--------------------------------------------------------------------------

function scan.all(s, test)
    for i = 1, #s do
        if not test(s:sub(i, i)) then return false end
    end
    return true
end

-- Does `read` (a scanner method) read all of s?
local function whole(s, read)
    if type(s) ~= "string" then return false end
    local sc = scan.new(s)
    return read(sc) ~= nil and sc:atEnd()
end

function scan.isBlank(s) return type(s) == "string" and scan.all(s, scan.isSpace) end
function scan.isUnsigned(s) return whole(s, Scanner.readNumber) end
function scan.isInteger(s) return whole(s, Scanner.readInteger) end
function scan.isNumber(s) return whole(s, Scanner.readFloat) end
function scan.isNegative(s) return scan.isNumber(s) and scan.new(s):readFloat() < 0 end
function scan.isName(s) return whole(s, Scanner.readName) end
function scan.isTime(s) return whole(s, Scanner.readTime) end
function scan.isDateTime(s) return whole(s, Scanner.readDateTime) end

function scan.isHex(s)
    return type(s) == "string" and s ~= "" and scan.all(s, scan.isHexDigit)
end

return scan
