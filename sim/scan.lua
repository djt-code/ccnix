-- sim/scan.lua
--
-- lib/scan.lua, the character scanner the small parsers are written on
-- (vi's ex command lines, lib/syntax's colourers): the character tests,
-- peeking and stepping, names, numbers, quoted strings, delimited text
-- with its backslashes, and the column in its errors.
local PROJ = ...
package.path = PROJ .. "/lib/?.lua;" .. PROJ .. "/sim/lib/?.lua;" .. package.path
local M = require("mock")
local check = M.check
local scan = require("scan")

local function show(v)
    if type(v) == "string" then return (string.format("%q", v):gsub("\\\n", "\\n")) end
    return tostring(v)
end
local function same(label, got, want)
    check(label, got == want, "got " .. show(got) .. ", want " .. show(want))
end
-- the error message f raises ("no error" if it doesn't)
local function errorOf(f)
    local ok, e = pcall(f)
    if ok then return "no error" end
    return e
end

-- 1. the character tests
local function every(test, chars)
    for i = 1, #chars do if not test(chars:sub(i, i)) then return false end end
    return true
end
local function none(test, chars)
    for i = 1, #chars do if test(chars:sub(i, i)) then return false end end
    return true
end
check("isDigit: 0-9 and nothing else", every(scan.isDigit, "0123456789") and none(scan.isDigit, "aZ_ .-/:"))
check("isHexDigit: 0-9 a-f A-F", every(scan.isHexDigit, "09afAF") and none(scan.isHexDigit, "gG_ x"))
check("isUpper and isLower", every(scan.isUpper, "AMZ") and none(scan.isUpper, "amz0@[")
    and every(scan.isLower, "amz") and none(scan.isLower, "AMZ0`{"))
check("isAlpha and isAlnum", every(scan.isAlpha, "aZ") and none(scan.isAlpha, "0_ ")
    and every(scan.isAlnum, "aZ09") and none(scan.isAlnum, "_ -"))
check("isNameStart: a letter or _, not a digit", every(scan.isNameStart, "a_Z") and none(scan.isNameStart, "0 -"))
check("isNameChar: letters, digits, _", every(scan.isNameChar, "a_Z09") and none(scan.isNameChar, " -.$"))
check("isSpace: space, tab, newline, return, vt, ff", every(scan.isSpace, " \t\n\r\v\f") and none(scan.isSpace, "a_\0"))
check("isPunct: printable, not a letter, digit or blank", every(scan.isPunct, "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~")
    and none(scan.isPunct, "aZ0 \t\127"))
check("a test is false for \"\" and for longer strings", not scan.isDigit("") and not scan.isDigit("12")
    and not scan.isSpace("") and not scan.isAlpha("ab"))
check("bytes past 127 are none of them (ASCII only)", none(scan.isAlpha, "\200\233\255") and none(scan.isSpace, "\160")
    and none(scan.isPunct, "\200"))
local isOp = scan.oneOf(";&|")
check("oneOf: a test for any of the characters", isOp(";") and isOp("|") and not isOp("x") and not isOp("")
    and not isOp(";&"))
check("all: every character passes (true for \"\")", scan.all("123", scan.isDigit) and not scan.all("1a", scan.isDigit)
    and scan.all("", scan.isDigit))
local w = scan.words("  set nu\tts=4  ")
check("words: split at blanks", #w == 3 and w[1] == "set" and w[2] == "nu" and w[3] == "ts=4", table.concat(w, "|"))
check("words of nothing but blanks: none", #scan.words(" \t ") == 0 and #scan.words("") == 0)

-- 2. peeking and stepping
local sc = scan.new("ab cd")
same("peek: the next character", sc:peek(), "a")
same("peek(2): the one after", sc:peek(2), "b")
same("prev at the start is \"\"", sc:prev(), "")
same("advance returns what it stepped over", sc:advance(2), "ab")
same("prev: the character just stepped over", sc:prev(), "b")
same("pos: the index of the next character", sc:pos(), 3)
check("at: what comes next, compared as it is", sc:at(" c") and not sc:at("cd"))
same("skipSpaces counts the blanks", sc:skipSpaces(), 1)
check("accept steps over text that's next", sc:accept("c") and sc:pos() == 5)
check("accept leaves text that isn't next", not sc:accept("x") and sc:pos() == 5)
same("rest: from here to the end", sc:rest(), "d")
same("rest doesn't step", sc:pos(), 5)
same("readRest steps to the end", sc:readRest(), "d")
check("atEnd at the end; peek is \"\" there", sc:atEnd() and sc:peek() == "")
same("advance at the end steps nowhere", sc:advance(3), "")
same("pos at the end: #text + 1", sc:pos(), 6)
sc:setPos(2)
same("setPos goes back", sc:advance(), "b")
sc:setPos(99)
same("setPos past the end stops at the end", sc:pos(), 6)
same("scan.new(text, pos) starts at pos", scan.new("hello", 4):rest(), "lo")
check("accept(\"\") never matches", not scan.new("x"):accept(""))
same("peek(3) across the end", scan.new("ab"):peek(3), "")

-- 3. readWhile, names and numbers
sc = scan.new("12ab_3 rest")
same("readWhile takes characters while the test holds", sc:readWhile(scan.isDigit), "12")
same("readWhile with nothing to take is \"\"", sc:readWhile(scan.isDigit), "")
same("readName: a letter, then letters, digits, _", sc:readName(), "ab_3")
sc = scan.new("9lives")
same("readName doesn't start on a digit", sc:readName(), nil)
same("and steps over nothing", sc:pos(), 1)
sc = scan.new("_x1=2")
same("readName starts on _", sc:readName(), "_x1")
sc = scan.new("0042x")
local n, digits = sc:readNumber()
check("readNumber: the number and its digits", n == 42 and digits == "0042" and sc:peek() == "x", show(n) .. " " .. show(digits))
sc = scan.new("-5")
same("readNumber: nil when no digit is next", sc:readNumber(), nil)
same("and steps over nothing", sc:pos(), 1)

-- 4. quoted strings
sc = scan.new([['it\'s' tail]])
same("readQuoted: an escaped quote inside", sc:readQuoted("'"), "it's")
same("and steps past the closing quote", sc:rest(), " tail")
same("\\n \\t \\r and \\\\ are what they stand for", scan.new([["a\nb\tc\rd\\e"]]):readQuoted('"'), "a\nb\tc\rd\\e")
same("a backslash before anything else is that thing", scan.new([["\q\""]]):readQuoted('"'), 'q"')
same("the other quote inside needs no backslash", scan.new([["it's"]]):readQuoted('"'), "it's")
same("readQuoted is nil when the quote isn't next", scan.new("x'a'"):readQuoted("'"), nil)
same("an empty string", scan.new("''"):readQuoted("'"), "")
same("a string that doesn't end is an error, at its quote", errorOf(function()
    local s2 = scan.new("ab 'open")
    s2:advance(3)
    s2:readQuoted("'")
end), "col 4: the string has no closing '")
same("a string ending in a lone backslash doesn't end", errorOf(function() scan.new("'a\\"):readQuoted("'") end),
    "col 1: the string has no closing '")

-- 5. delimited text (as :s/pat/rep/ reads it)
sc = scan.new([[a\/b/c\.d/g]])
local t1, c1 = sc:readUntil("/")
check("readUntil: \\/ is the delimiter in the text", t1 == "a/b" and c1 == true, show(t1))
local t2, c2 = sc:readUntil("/")
check("other backslash pairs stay as they are", t2 == [[c\.d]] and c2 == true, show(t2))
same("the delimiter is stepped over", sc:rest(), "g")
local t3, c3 = scan.new("abc"):readUntil("/")
check("no delimiter: the text to the end, and false", t3 == "abc" and c3 == false)
local t4, c4 = scan.new("/x"):readUntil("/")
check("a delimiter straight away: \"\"", t4 == "" and c4 == true)
local t5, c5 = scan.new("ab\\"):readUntil("#")
check("a backslash at the very end stays", t5 == "ab\\" and c5 == false, show(t5))
local t6 = scan.new("a#b\\#c#"):readUntil("#")
same("any delimiter works", t6, "a")
local s7 = scan.new([[x\\/y]])
local t7 = s7:readUntil("/")
same("\\\\ is a pair kept as it is, so the / after it ends the text", t7, [[x\\]])

-- 6. expect and errors
sc = scan.new("width = 12")
sc:readName()
sc:skipSpaces()
same("expect steps over what it expects", errorOf(function() sc:expect("=") end), "no error")
same("expect names the column it wanted it at", errorOf(function() sc:expect("=", "= after the name") end),
    "col 8: expected = after the name")
same("expect without a what names the text", errorOf(function() scan.new("x"):expect(";") end), "col 1: expected ;")
same("fail: an error with the column", errorOf(function() scan.new("abc", 3):fail("bad") end), "col 3: bad")

-- 7. a small parser on it: the example in the header
sc = scan.new([[width = 12 'it\'s']])
local key = sc:readName()
sc:skipSpaces()
sc:expect("=", "= after the name")
sc:skipSpaces()
local num = sc:readNumber()
sc:skipSpaces()
local q = sc:readQuoted("'")
check("the header's example", key == "width" and num == 12 and q == "it's" and sc:atEnd(),
    show(key) .. " " .. show(num) .. " " .. show(q))

-- the whole-string helpers
local function list(t) return "{" .. table.concat(t, "|") .. "}" end
same("trim", scan.trim("  a b \t\r\n"), "a b")
same("trim: all blanks", scan.trim("   "), "")
same("split: trimmed, empties dropped", list(scan.split(" #a, #b,, ", ",")), "{#a|#b}")
same("split, keep: as they are", list(scan.split("a,,b ", ",", true)), "{a||b }")
same("split: a separator longer than one character, not a pattern", list(scan.split("a.-b.-c", ".-")), "{a|b|c}")
local before, after = scan.cut("host:6667:x", ":")
same("cut: at the first", before .. "|" .. after, "host|6667:x")
local b2, a2 = scan.cutLast("host:6667:x", ":")
same("cutLast: at the last", b2 .. "|" .. a2, "host:6667|x")
local b3, a3 = scan.cut("nosep", ":")
check("cut: no separator: s and nil", b3 == "nosep" and a3 == nil)
check("startsWith, endsWith", scan.startsWith("network.lab", "network.") and not scan.startsWith("net", "network")
    and scan.endsWith("x.lua", ".lua") and scan.endsWith("x", "") and not scan.endsWith("lua", ".lua"))
same("lines: LF, CR LF, a last line without one", list(scan.lines("a\r\nb\n\nc")), "{a|b||c}")
same("lines: a newline at the end starts no line", list(scan.lines("a\nb\n")), "{a|b}")
