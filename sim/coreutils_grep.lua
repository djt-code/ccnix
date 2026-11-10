-- sim/coreutils_grep.lua
--
-- grep in a shellworld: BRE, ERE and fixed strings, every option, pattern
-- lists from -e and -f, files, "-" and standard input (keyboard and pipe),
-- missing files, the output formats and the exit statuses.
local PROJ = ...
package.path = PROJ .. "/lib/?.lua;" .. PROJ .. "/sim/lib/?.lua;" .. package.path
local M = require("mock")
local SW = require("shellworld")
local check = M.check

local W = SW.new(PROJ)
local function show(s)
    return (tostring(s):gsub("\n", "|"))
end
W:file("fruit.txt", "apple\nBanana\ncherry pie\napple pie\n\ngrape\n")
W:file("nums.txt", "1\n22\n333\na.b\n")
W:file("pats.txt", "^ch\nnana$\n")
W:file("sub/dos.txt", "one\r\ntwo\r\n")

-- grep's output for these arguments (stdin piped in when given)
local function g(...)
    local args = { ... }
    local o = { pipe = true }
    if type(args[#args]) == "table" then o = args[#args]; args[#args] = nil end
    args[#args + 1] = o
    return W:run("grep", table.unpack(args))
end
local function want(name, r, out, status)
    check(name, r.out == out and r.status == status,
        show(r.out) .. " status " .. tostring(r.status) .. " " .. show(r.errText))
end

-- basics and exit statuses
want("BRE match prints the lines", g("pie", "fruit.txt"), "cherry pie\napple pie\n", 0)
want("no match: status 1, no output", g("kiwi", "fruit.txt"), "", 1)
want("BRE: + is literal", g("p+", "fruit.txt"), "", 1)
want("BRE anchors and groups", g("^\\(ap\\)p.*e$", "fruit.txt"), "apple\napple pie\n", 0)
want("BRE interval", g("^[0-9]\\{2,3\\}$", "nums.txt"), "22\n333\n", 0)
want("BRE . matches any character", g("a.b", "nums.txt"), "a.b\n", 0)
want("-E: + ? | and ()", g("-E", "^(apple|grape)( pie)?$", "fruit.txt"), "apple\napple pie\ngrape\n", 0)
want("-E interval", g("-E", "^3{3}$", "nums.txt"), "333\n", 0)
want("-F: . is literal", g("-F", "a.b", "nums.txt"), "a.b\n", 0)
want("-F: nothing special at all", g("-F", "^ch", "fruit.txt"), "", 1)
want("-E then -F: the last wins", g("-E", "-F", "a|b", "fruit.txt"), "", 1)
want("-i", g("-i", "banana", "fruit.txt"), "Banana\n", 0)
want("-i with -F", g("-iF", "APPLE", "fruit.txt"), "apple\napple pie\n", 0)
want("-v", g("-v", "p", "fruit.txt"), "Banana\n\n", 0)
want("-x", g("-x", "apple", "fruit.txt"), "apple\n", 0)
want("-x with -F", g("-xF", "apple pie", "fruit.txt"), "apple pie\n", 0)
want("-x with -E alternation covers the whole line", g("-xE", "apple|apple pie", "fruit.txt"), "apple\napple pie\n", 0)
want("-n: number:line", g("-n", "pie", "fruit.txt"), "3:cherry pie\n4:apple pie\n", 0)
want("-c: the count", g("-c", "p", "fruit.txt"), "4\n", 0)
want("-c with no match: 0 and status 1", g("-c", "kiwi", "fruit.txt"), "0\n", 1)
want("-cv counts the others", g("-cv", "p", "fruit.txt"), "2\n", 0)
want("empty pattern matches every line", g("", "nums.txt"), "1\n22\n333\na.b\n", 0)
want("-v empty pattern selects nothing", g("-v", "", "nums.txt"), "", 1)
want("CRLF lines match at $", g("e$", "sub/dos.txt"), "one\n", 0)

-- several files: name prefixes
want("several files: file:line", g("a", "nums.txt", "fruit.txt"),
    "nums.txt:a.b\nfruit.txt:apple\nfruit.txt:Banana\nfruit.txt:apple pie\nfruit.txt:grape\n", 0)
want("several files with -n: file:number:line", g("-n", "^2", "nums.txt", "fruit.txt"), "nums.txt:2:22\n", 0)
want("several files with -c: file:count", g("-c", "2", "nums.txt", "fruit.txt"), "nums.txt:1\nfruit.txt:0\n", 0)
want("-l: the names of matching files", g("-l", "pie", "nums.txt", "fruit.txt", "pats.txt"), "fruit.txt\n", 0)
want("-l wins over -c", g("-lc", "1", "nums.txt", "fruit.txt"), "nums.txt\n", 0)
want("-q: no output, status 0", g("-q", "pie", "fruit.txt"), "", 0)
want("-q: status 1 without a match", g("-q", "kiwi", "fruit.txt"), "", 1)

-- pattern lists
want("-e twice", g("-e", "^1$", "-e", "333", "nums.txt"), "1\n333\n", 0)
want("-e with the pattern operand gone: all operands are files",
    g("-e", "22", "nums.txt", "fruit.txt"), "nums.txt:22\n", 0)
want("-e pattern starting with -", g("-e", "-x", { pipe = true, stdin = "a-x\nb\n" }), "a-x\n", 0)
want("-f pattern file", g("-f", "pats.txt", "fruit.txt"), "Banana\ncherry pie\n", 0)
want("-f and -e together", g("-f", "pats.txt", "-e", "grape", "fruit.txt"), "Banana\ncherry pie\ngrape\n", 0)
W:file("empty.txt", "")
want("-f with an empty file matches nothing", g("-f", "empty.txt", "fruit.txt"), "", 1)
local r = g("-f", "nope.txt", "fruit.txt")
check("-f missing file: message and status 2",
    r.status == 2 and r.err[1] == "grep: nope.txt: No such file or directory", show(r.errText))
r = g("-f", "nope.txt", "-s", "fruit.txt")
check("-f missing file is reported even with -s", r.status == 2 and #r.err == 1)

-- standard input
want("no file: reads the pipe", g("b", { pipe = true, stdin = "abc\nxyz\nb\n" }), "abc\nb\n", 0)
want("- reads the pipe", g("-c", "x", "-", { pipe = true, stdin = "x\nxx\ny\n" }), "2\n", 0)
want("- among files is (standard input)", g("22", "nums.txt", "-", { pipe = true, stdin = "122\n" }),
    "nums.txt:22\n(standard input):122\n", 0)
want("-l names standard input", g("-l", "q", "-", { pipe = true, stdin = "q\n" }), "(standard input)\n", 0)
r = W:run("grep", "o", { stdin = "foo\nbar\nboo\n" })
check("the keyboard until Ctrl+T", r.status == 0 and r.out == "foo\nboo\n" and #r.err == 0, show(r.out))

-- missing files and errors
r = g("a", "nope.txt", "nums.txt")
check("missing file: message, other files still searched, status 2",
    r.status == 2 and r.out == "nums.txt:a.b\n" and r.err[1] == "grep: nope.txt: No such file or directory",
    show(r.out) .. show(r.errText))
r = g("-s", "a", "nope.txt", "nums.txt")
check("-s hides it, status still 2", r.status == 2 and #r.err == 0 and r.out == "nums.txt:a.b\n")
r = g("-q", "a", "nope.txt", "nums.txt")
check("-q with a match despite the error: status 0", r.status == 0 and r.out == "")
r = g("-q", "a", "nums.txt", "nope.txt")
check("-q stops at the first match", r.status == 0 and #r.err == 0)
r = g("x", "sub")
check("a directory is reported", r.status == 2 and r.err[1] == "grep: sub: Is a directory", show(r.errText))
r = g("-E", "(ab", "nums.txt")
check("bad ERE: message and status 2", r.status == 2 and r.err[1] == "grep: parentheses not balanced", show(r.errText))
r = g("[a", "nums.txt")
check("bad BRE: status 2", r.status == 2 and r.err[1] == "grep: brackets ([ ]) not balanced")
r = g()
check("no pattern: usage, status 2", r.status == 2 and r.err[1]:match("^usage: grep") ~= nil, show(r.errText))
r = g("-z", "a")
check("bad option: status 2", r.status == 2 and r.err[1] == "grep: illegal option -- z")

-- option and input corner cases
W:file("nonl.txt", "first\nlast")
want("a last line with no newline gets one", g("last", "nonl.txt"), "last\n", 0)
want("-- ends the options: a pattern starting with -", g("--", "-x", { pipe = true, stdin = "a-x\n" }), "a-x\n", 0)
want("-cv on an empty file: 0, status 1", g("-cv", "a", "empty.txt"), "0\n", 1)
want("-n is ignored with -c", g("-nc", "2", "nums.txt"), "1\n", 0)
want("BRE ^* is a literal star at the start", g("^*", { pipe = true, stdin = "a*\n*b\n" }), "*b\n", 0)
want("-i -x with a BRE", g("-ix", "APPLE", "fruit.txt"), "apple\n", 0)
r = g("-s", "a", "nope.txt")
check("-s with only a missing file: silent, status 2", r.status == 2 and #r.err == 0 and r.out == "")

-- a big file: every match found, and grep yields now and then so CC does
-- not stop it for running too long (the clock here runs fast)
local big = {}
for i = 1, 3000 do big[i] = ("line %04d of a fairly ordinary file\n"):format(i) end
W:file("big.txt", table.concat(big))
local clock, yields = W.os.clock, 0
W.os.clock = function() W.clock = W.clock + 0.5; return W.clock end
r = g("-c", "-E", "[0-9]+7 of", "big.txt", { pipe = true, onPull = function(_, f) if f == "cu_breathe" then yields = yields + 1 end end })
W.os.clock = clock
check("3000 lines: the count, yielding as it goes", r.out == "300\n" and r.status == 0 and yields > 0 and #W.T.events == 0,
    show(r.out) .. " yields " .. yields .. " " .. show(r.errText))

-- through the stock shell, from another directory
W.shell.setDir("sub")
r = W:sh('grep "two" dos.txt')
check("through the shell, relative to the directory", r.out == "two\n" and r.status == 0, show(r.out))
r = W:sh('grep -n pie /fruit.txt')
check("absolute path", r.out == "3:cherry pie\n4:apple pie\n", show(r.out))
W.shell.setDir("")
r = W:sh('grep "cherry pie" fruit.txt')
check("a quoted pattern with a space", r.out == "cherry pie\n")
