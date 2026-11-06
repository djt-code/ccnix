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
-- lib/syntax) are read this way rather than with Lua patterns, so each
-- step has a name and a comment saying what it expects.  Lua patterns
-- still do for plain-text finds; lib/regex is for regexes the user types.
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
--   scan.isUpper     A-Z                 scan.isLower     a-z
--   scan.isAlpha     a letter            scan.isAlnum     a letter or digit
--   scan.isNameStart a letter or _       scan.isNameChar  a letter, digit or _
--   scan.isSpace     space, tab, newline, return, vertical tab, form feed
--   scan.isPunct     printable, not a letter, digit or space: ! " # $ ...
--   scan.oneOf(chars)    a test: true for any one of the characters in chars
--
-- And on whole strings:
--   scan.all(s, test)    true if test holds for every character of s
--                        (true for "")
--   scan.words(s)        the words of s between blanks, as a list

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

function scan.oneOf(chars)
    local set = {}
    for i = 1, #chars do set[chars:sub(i, i)] = true end
    return function(c) return set[c] == true end
end

function scan.all(s, test)
    for i = 1, #s do
        if not test(s:sub(i, i)) then return false end
    end
    return true
end

function scan.words(s)
    local sc, out = scan.new(s), {}
    sc:skipSpaces()
    while not sc:atEnd() do
        out[#out + 1] = sc:readWhile(function(c) return not scan.isSpace(c) end)
        sc:skipSpaces()
    end
    return out
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

return scan
