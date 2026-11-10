-- sim/text.lua
--
-- The libraries on lib/scan: lib/text (blanks, pieces, ends, widths,
-- case), lib/convert (numbers, sizes, times, bytes, escapes, quoting),
-- lib/getopt, lib/glob and lib/path.  Each is plain functions on strings,
-- so each check is a call and the answer it should give.
local PROJ = ...
package.path = PROJ .. "/lib/?.lua;" .. PROJ .. "/sim/lib/?.lua;" .. package.path
local M = require("mock")
local check = M.check
local text = require("text")
local scan = require("scan")
local convert = require("convert")
local getopt = require("getopt")
local glob = require("glob")
local path = require("path")

local function show(v)
    if type(v) == "string" then return (string.format("%q", v):gsub("\\\n", "\\n")) end
    return tostring(v)
end
local function same(label, got, want)
    check(label, got == want, "got " .. show(got) .. ", want " .. show(want))
end
local function list(t) return "{" .. table.concat(t, "|") .. "}" end

-- 1. lib/text: blanks
same("trim", text.trim("  a b \t\r\n"), "a b")
same("trim: all blanks", text.trim("   "), "")
same("trimStart", text.trimStart("  a b  "), "a b  ")
same("trimEnd", text.trimEnd("  a b  "), "  a b")
same("squeeze: runs of blanks as one space, the ends too", text.squeeze("  a \t b\n\nc "), " a b c ")
same("afterWords: the rest as it is", text.afterWords("TELL steve hi  there", 2), "hi  there")
check("afterWords: nil when nothing follows", text.afterWords("TELL steve ", 2) == nil and text.afterWords("x", 2) == nil)
check("hasWord", text.hasWord("sasl tls", "tls") and not text.hasWord("sasltls", "tls"))
same("words: split at blanks", list(text.words("  set nu\tts=4  ")), "{set|nu|ts=4}")
check("words of nothing but blanks: none", #text.words(" \t ") == 0 and #text.words("") == 0)

-- 2. pieces
same("split: trimmed, empties dropped", list(text.split(" #a, #b,, ", ",")), "{#a|#b}")
same("split, keep: as they are", list(text.split("a,,b ", ",", true)), "{a||b }")
same("split: a separator longer than one character, not a pattern", list(text.split("a.-b.-c", ".-")), "{a|b|c}")
same("join: tostring'd, sep between", text.join({ 1, "b", true }, ", "), "1, b, true")
same("join: no sep", text.join({ "a", "b" }), "ab")
same("join: nothing", text.join({}, ","), "")
local before, after = text.cut("host:6667:x", ":")
same("cut: at the first", before .. "|" .. after, "host|6667:x")
local b2, a2 = text.cutLast("host:6667:x", ":")
same("cutLast: at the last", b2 .. "|" .. a2, "host:6667|x")
local b3, a3 = text.cut("nosep", ":")
check("cut: no separator: s and nil", b3 == "nosep" and a3 == nil)
same("lines: LF, CR LF, a last line without one", list(text.lines("a\r\nb\n\nc")), "{a|b||c}")
same("lines: a newline at the end starts no line", list(text.lines("a\nb\n")), "{a|b}")
same("lines, keepReturns", list(text.lines("a\r\nb\n", true)), "{a\r|b}")

-- 3. ends and insides
check("startsWith, endsWith", text.startsWith("network.lab", "network.") and not text.startsWith("net", "network")
    and text.endsWith("x.lua", ".lua") and text.endsWith("x", "") and not text.endsWith("lua", ".lua"))
same("stripPrefix", text.stripPrefix("--port=6667", "--port="), "6667")
check("stripPrefix: nil when it isn't there", text.stripPrefix("-p", "--port=") == nil)
same("stripSuffix", text.stripSuffix("init.lua", ".lua"), "init")
check("stripSuffix: nil when it isn't there", text.stripSuffix("init", ".lua") == nil)
local f1, f2 = text.find("a.b.c", ".")
check("find: plain, not a pattern", f1 == 2 and f2 == 2)
local l1 = text.findLast("a.b.c", ".")
check("findLast", l1 == 4)
check("containsAny", text.containsAny("n!u@h", "!@") and not text.containsAny("nick", "!@"))
check("contains: % and . as themselves", text.contains("100%.", "%.") and not text.contains("100x", "%."))
same("count: not overlapping", text.count("aaaa", "aa"), 2)
same("count: of nothing", text.count("abc", ""), 0)
local r, n = text.replace("a.b.c", ".", "/")
check("replace: every one, and how many", r == "a/b/c" and n == 2, show(r) .. " " .. tostring(n))
same("replace: the first n", (text.replace("a.b.c", ".", "%", 1)), "a%b.c")
same("replace: a % in new is itself", (text.replace("x", "x", "%1")), "%1")

-- 4. widths
same("padRight", text.padRight("ok", 6) .. "|", "ok    |")
same("padRight: longer stays as it is (as %-3s)", text.padRight("abcdef", 3), "abcdef")
same("a column exactly w wide", text.padRight(text.truncate("abcdef", 3), 3) .. text.padRight("a", 3) .. "|", "abca  |")
same("padLeft with a fill", text.padLeft(7, 3, "0"), "007")
same("center", "[" .. text.center("ab", 6) .. "]", "[  ab  ]")
same("truncate with a mark", text.truncate("abcdef", 4, "~"), "abc~")
same("truncate: short enough stays", text.truncate("abc", 4, "~"), "abc")
same("wrap: at blanks", list(text.wrap("the quick brown fox", 10)), "{the quick|brown fox}")
same("wrap: a long word is broken", list(text.wrap("abcdefghij xy", 4)), "{abcd|efgh|ij|xy}")
same("wrap: newlines end lines, empty ones stay", list(text.wrap("a\n\nb", 5)), "{a||b}")
same("wrap: blanks inside kept, the one broken at dropped", list(text.wrap("a  b c d", 4)), "{a  b|c d}")
local _, spans = text.wrap("ab cd\nef", 3)
check("wrap: where each line is in s", #spans == 3 and spans[1][1] == 1 and spans[1][2] == 2 and spans[2][1] == 4
    and spans[2][2] == 5 and spans[3][1] == 7 and spans[3][2] == 8)

-- 5. case
check("equalFold", text.equalFold("NickServ", "nickserv") and not text.equalFold("a", "ab"))
same("capitalize", text.capitalize("hello world"), "Hello world")
same("swapCase", text.swapCase("aB1c"), "Ab1C")

-- 6. lib/convert: numbers
check("toInteger: decimal, signed", convert.toInteger("-42") == -42 and convert.toInteger("+7") == 7)
check("toInteger: other bases", convert.toInteger("ff", 16) == 255 and convert.toInteger("FF", 16) == 255
    and convert.toInteger("777", 8) == 511 and convert.toInteger("101", 2) == 5)
check("toInteger: the whole string or nil", convert.toInteger("12x") == nil and convert.toInteger(" 1") == nil
    and convert.toInteger("") == nil and convert.toInteger("-") == nil and convert.toInteger("8", 8) == nil)
check("toInteger: past 2^63, a float, not wrapped", convert.toInteger("99999999999999999999") == 1e20)
check("compareIntegers: exact at any length", convert.compareIntegers("99999999999999999999", "99999999999999999998") == 1
    and convert.compareIntegers("-007", "-7") == 0 and convert.compareIntegers("-0", "+0") == 0
    and convert.compareIntegers("-12", "3") == -1 and convert.compareIntegers("x", "1") == nil)
local esc = scan.new([[\tx]])
check("readEscape: one, stepped over", convert.readEscape(esc) == "\t" and esc:peek() == "x")
esc = scan.new([[\qx]])
check("readEscape: not one: nil, nothing stepped over", convert.readEscape(esc) == nil and esc:pos() == 1)
check("toNumber", convert.toNumber("1.5e3") == 1500 and convert.toNumber("-.5") == -0.5
    and convert.toNumber("0x10") == nil and convert.toNumber("inf") == nil and convert.toNumber(" 1") == nil)

-- 7. sizes and times
same("humanSize: bytes", convert.humanSize(1023), "1023")
same("humanSize: one decimal below 10", convert.humanSize(1536), "1.5K")
same("humanSize: rounded up", convert.humanSize(23 * 1024 + 1), "24K")
same("humanSize: megabytes", convert.humanSize(4 * 1024 * 1024), "4.0M")
same("duration", convert.duration(3725), "1h 2m 5s")
same("duration: zero parts left out", convert.duration(3 * 86400 + 4 * 3600), "3d 4h")
same("duration: none", convert.duration(0), "0s")
same("clock", convert.clock(3723004), "01:02:03.004")
same("clock: wraps at a day", convert.clock(86400000 + 1), "00:00:00.001")
same("timeOfDay", convert.timeOfDay("1:02:03"), 3723)
check("timeOfDay: nil for a bad one", convert.timeOfDay("25:00") == nil)
same("fromDateTime: the epoch", convert.fromDateTime("1970-01-01T00:00:00Z"), 0)
same("fromDateTime: a zone east of UTC", convert.fromDateTime("2026-10-29T23:04:05+02:00"), 1793307845)
same("fromDateTime: no zone is UTC, the fraction dropped", convert.fromDateTime("2026-10-29 21:04:05.9"), 1793307845)
same("fromDateTime: a leap day", convert.fromDateTime("2024-02-29T00:00:00Z"), 1709164800)
check("fromDateTime: nil for a bad one", convert.fromDateTime("2026-02-30") == nil)

-- 8. bytes
same("toHex", convert.toHex("\0\255A"), "00ff41")
same("fromHex", convert.fromHex("00FF41"), "\0\255A")
check("fromHex: nil for odd or non-hex", convert.fromHex("abc") == nil and convert.fromHex("zz") == nil)
same("toBase64", convert.toBase64("\0user\0pass"), "AHVzZXIAcGFzcw==")
same("toBase64: one byte over", convert.toBase64("ab"), "YWI=")
for _, s in ipairs({ "", "a", "ab", "abc", "abcd", "\0\255\128 x" }) do
    local back = s                                  -- (the loop variable is const)
    same("base64 round trip: " .. show(back), convert.fromBase64(convert.toBase64(back)), back)
end
same("fromBase64: blanks skipped", convert.fromBase64("YW\nI="), "ab")
check("fromBase64: nil for what isn't", convert.fromBase64("a$b=") == nil)
same("utf8: two bytes", convert.utf8(0xE9), "\195\169")
same("utf8: three bytes", convert.utf8(0x2588), "\226\150\136")
same("fromUTF8: Latin-1 as itself, others ?", convert.fromUTF8("caf\195\169 \226\150\136"), "caf\233 ?")
same("fromUTF8: not UTF-8 taken as Latin-1", convert.fromUTF8("caf\233"), "caf\233")
same("toUTF8", convert.toUTF8("caf\233"), "caf\195\169")

-- 9. escapes and quoting
same("unescape: letters and octal", convert.unescape([[a\tb\101\\]]), "a\tbA\\")
same("unescape: \\ before anything else stays", convert.unescape([[a\qb]]), [[a\qb]])
local e, stopped = convert.unescape([[x\0101y\cz]], true)
check("unescape, echo: \\0ooo and \\c", e == "xAy" and stopped == true, show(e))
same("unescape, echo: \\101 isn't octal", (convert.unescape([[\101]], true)), [[\101]])
same("escape", convert.escape("a\tb\\\1"), [[a\tb\\\001]])
same("urlEncode", convert.urlEncode("a b/c~"), "a%20b%2Fc~")
same("urlDecode", convert.urlDecode("a%20b%2fc%zz"), "a b/c%zz")
same("urlDecode, form: + is a space", convert.urlDecode("a+b%2B", true), "a b+")
same("html", convert.html([[<a href="x">&'</a>]]), "&lt;a href=&quot;x&quot;&gt;&amp;&#39;&lt;/a&gt;")
same("shellQuote", convert.shellQuote("it's"), [['it'\''s']])

-- 10. lib/getopt
local opts, ops, order = getopt.parse({ "-vn", "3", "--output=x", "a", "-z" }, "vn:o:", { output = "o" })
check("getopt: flags together, an argument after, a long alias", opts.v == true and opts.n == "3" and opts.o == "x"
    and list(ops) == "{a|-z}" and #order == 3)
opts = getopt.parse({ "-n3", "--max-time", "5", "--quiet" }, "n:", { ["max-time"] = "=", quiet = true })
check("getopt: inline argument, long ones of their own", opts.n == "3" and opts["max-time"] == "5" and opts.quiet == true)
opts, ops = getopt.parse({ "-v", "--", "-n" }, "vn:")
check("getopt: -- ends the options", opts.v and list(ops) == "{-n}")
opts, ops = getopt.parse({ "-", "-v" }, "v")
check("getopt: - alone is an operand", not opts.v and list(ops) == "{-|-v}")
local none, err = getopt.parse({ "-x" }, "v")
check("getopt: an unknown letter", none == nil and err == "illegal option -- x", tostring(err))
none, err = getopt.parse({ "-n" }, "n:")
check("getopt: an argument missing", none == nil and err == "option requires an argument -- n", tostring(err))
none, err = getopt.parse({ "--nope" }, "v")
check("getopt: an unknown long one", none == nil and err == "unrecognized option '--nope'", tostring(err))
none, err = getopt.parse({ "--quiet=1" }, "", { quiet = true })
check("getopt: a flag given a value", none == nil and err == "option '--quiet' doesn't allow an argument", tostring(err))

opts, ops, order = getopt.parseMixed({ "clone", "url", "--only", "lib/", "dir", "--only=bin/", "-b", "dev", "--", "-x" }, "b:",
    { only = "=", branch = "b" })
check("getopt.parseMixed: operands between options, -- still ends them", opts and opts.b == "dev"
    and list(ops) == "{clone|url|dir|-x}" and #order == 3 and order[1][2] == "lib/" and order[2][2] == "bin/")
opts, ops = getopt.parse({ "a", "-v" }, "v")
check("getopt.parse: the first operand ends the options", not opts.v and list(ops) == "{a|-v}")

-- 11. lib/glob
check("glob: * and ?", glob.match("*.lua", "init.lua") and glob.match("?x", "ax") and not glob.match("*.lua", "init.luac"))
check("glob: * matches nothing too", glob.match("a*", "a") and glob.match("*", ""))
check("glob: classes", glob.match("[a-c]x", "bx") and not glob.match("[a-c]x", "dx") and glob.match("[!a-c]x", "dx")
    and glob.match("[]]", "]") and glob.match("[^0-9]", "a"))
check("glob: POSIX classes", glob.match("[[:digit:]]x", "7x") and glob.match("[![:alpha:]]", "1")
    and not glob.match("[[:upper:][:digit:]]", "a") and glob.match("[[:graph:]]", "!"))
check("glob: escapes inside a class", glob.match("[\\]a]", "]") and glob.match("[\\]a]", "a") and glob.match("[a\\-z]", "-")
    and not glob.match("[a\\-z]", "m"))
check("glob: an unclosed [ is itself", glob.match("[ab", "[ab"))
check("glob: \\ escapes", glob.match("\\*", "*") and not glob.match("\\*", "x"))
check("glob: many stars stay fast", glob.match("*a*a*a*a*a*b", ("a"):rep(60)) == false)
check("glob: IRC masks (no escapes, no classes, folded)",
    glob.match("*!*@*.example", "Bob!b@host.EXAMPLE", { escapes = false, classes = false, fold = string.lower })
    and glob.match("[x]\\*", "[X]\\y", { escapes = false, classes = false, fold = string.lower }))
check("glob.hasWildcards", glob.hasWildcards("a*") and glob.hasWildcards("[ab]") and not glob.hasWildcards("a\\*")
    and not glob.hasWildcards("plain") and not glob.hasWildcards("[ab", {}))
local esc = glob.escape("a*[b]?\\")
check("glob.escape: matches only itself", glob.match(esc, "a*[b]?\\") and not glob.match(esc, "aX[b]?\\"))

-- 12. lib/path
same("basename", path.basename("/usr/lib/x.lua"), "x.lua")
same("basename: with a suffix", path.basename("/usr/lib/x.lua", ".lua"), "x")
same("basename: the suffix isn't all of it", path.basename(".lua", ".lua"), ".lua")
same("basename: trailing slashes", path.basename("a/b//"), "b")
same("basename: only slashes", path.basename("///"), "/")
same("basename: empty", path.basename(""), "")
same("dirname", path.dirname("/usr/lib/x.lua"), "/usr/lib")
same("dirname: no slash", path.dirname("x"), ".")
same("dirname: at the top", path.dirname("/x"), "/")
same("dirname: slashes kept inside", path.dirname("//a//b//"), "//a")
same("stripSlashes", path.stripSlashes("a/b//"), "a/b")
same("stripSlashes: only slashes", path.stripSlashes("//"), "/")
same("segments", list(path.segments("/a//b/c/")), "{a|b|c}")
same("join", path.join("/etc", "net", "hosts"), "/etc/net/hosts")
same("join: an absolute part starts over", path.join("a", "/b", "c"), "/b/c")
same("join: no doubled slash", path.join("a/", "b"), "a/b")
same("normalize", path.normalize("a//b/./c/../d/"), "a/b/d")
same("normalize: nothing above /", path.normalize("/../x"), "/x")
same("normalize: leading .. kept when relative", path.normalize("../a/../../b"), "../../b")
same("normalize: nothing left", path.normalize("a/.."), ".")
same("resolve", path.resolve("/home/me", "../lib"), "/home/lib")
same("extension", path.extension("a/b.tar.gz"), "gz")
same("extension: a dotfile has none", path.extension(".profile"), "")
same("extension: none", path.extension("Makefile"), "")


-- 13. the helpers the second audit asked for
local tables = require("tables")
same("keep", text.keep("a1b2", scan.isDigit), "12")
same("columns: widths, right-aligned numbers, the last cell ragged",
    table.concat(text.columns({ { "name", "n", "x" }, { "ab", "123", "" } }, { [2] = true }), "|"), "name   n x|ab   123")
check("isNot and isTabOrSpace", scan.isNot(scan.isSpace)("x") and not scan.isNot(scan.isSpace)(" ")
    and scan.isTabOrSpace("\t") and not scan.isTabOrSpace("\n"))
same("sortedKeys: numbers as numbers, then strings", table.concat(tables.sortedKeys({ [10] = 1, [9] = 1, b = 1, a = 1 }), ","), "9,10,a,b")
same("sortedKeys: a comparator", table.concat(tables.sortedKeys({ a = 1, b = 1 }, function(x, y) return x > y end), ","), "b,a")
local orig = { a = 1, t = {} }
local cp = tables.copy(orig)
check("copy: shallow", cp ~= orig and cp.a == 1 and cp.t == orig.t)
local fileio = require("fileio")
textutils = textutils or { unserialiseJSON = function(d) if d == '{"k":1}' then return { k = 1 } end error("not JSON") end }
local fake = { files = { ["/a"] = "x" } }
local fakeFs = {
    exists = function(p) return fake.files[p] ~= nil end, isDir = function() return false end,
    open = function(p, mode)
        if mode == "w" then return { write = function(d) fake.files[p] = d end, close = function() end } end
        return fake.files[p] and { readAll = function() return fake.files[p] end, close = function() end } or nil
    end,
}
local on = fileio.on(fakeFs)
check("fileio.on: read, write and readJSON over another fs", on.read("/a") == "x" and on.read("/b") == nil
    and on.write("/j", '{"k":1}') and on.readJSON("/j") and on.readJSON("/j").k == 1 and on.readJSON("/a") == nil)
