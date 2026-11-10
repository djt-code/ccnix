-- sim/coreutils_text.lua
--
-- The text filters wc, sort, uniq, cut and tr in a shellworld: their
-- options, files against standard input (the keyboard and a pipe), "-",
-- missing files, and the output formats POSIX gives.
local PROJ = ...
package.path = PROJ .. "/lib/?.lua;" .. PROJ .. "/sim/lib/?.lua;" .. package.path
local M = require("mock")
local SW = require("shellworld")
local check = M.check

local W = SW.new(PROJ)
local function show(s)
    return (tostring(s):gsub("[%c\128-\255]", function(c) return c == "\n" and "|" or "\\" .. c:byte() end))
end
-- run and check the output (and status 0)
local function out(label, want, prog, ...)
    local r = W:run(prog, ...)
    check(label, r.ok and r.status == 0 and r.out == want and #r.err == 0,
        show(r.out) .. " status " .. tostring(r.status) .. " " .. show(r.errText))
    return r
end

W:file("a.txt", "one two\nthree\n\n  four  five six\n")
W:file("b.txt", "x\ny")     -- no newline at the end
W:file("sub/c.txt", "c\n")
W:dir("adir")

--------------------------------------------------------------------------
-- wc
--------------------------------------------------------------------------
out("wc: lines words bytes and the name", "4 6 32 a.txt\n", "wc", "a.txt")
out("wc -l / -w / -c", "4 a.txt\n", "wc", "-l", "a.txt")
out("wc -w", "6 a.txt\n", "wc", "-w", "a.txt")
out("wc -cl: always lines then bytes", "4 32 a.txt\n", "wc", "-cl", "a.txt")
out("wc -m counts characters (bytes here)", "32 a.txt\n", "wc", "-m", "a.txt")
out("wc: no newline at the end isn't a line", "1 2 3 b.txt\n", "wc", "b.txt")
out("wc: several files and a total", "4 6 32 a.txt\n1 2 3 b.txt\n5 8 35 total\n", "wc", "a.txt", "b.txt")
out("wc: standard input has no name", "2 3 6\n", "wc", { stdin = "a b\nc\n" })
out("wc: a pipe", "2 3 6\n", "wc", { pipe = true, stdin = "a b\nc\n" })
out("wc -: named -", "1 1 4 -\n1 2 3 b.txt\n2 3 7 total\n", "wc", "-", "b.txt", { stdin = "abc\n" })
out("wc: tabs and runs of blanks split words", "1 3 9\n", "wc", { pipe = true, stdin = "a\t\tb   c\n" })
out("wc: relative to the shell's directory", "1 1 2 c.txt\n", "wc", "c.txt", { cwd = "sub" })
W.shell.setDir("")
local r = W:run("wc", "nope", "b.txt", { pipe = true })
check("wc: missing file reported, the rest counted, status 1", r.ok and r.status == 1
    and r.err[1] == "wc: nope: No such file or directory" and r.out == "1 2 3 b.txt\n1 2 3 total\n", show(r.out))
r = W:run("wc", "adir")
check("wc: a directory", r.status == 1 and r.err[1] == "wc: adir: Is a directory")
r = W:run("wc", "-x")
check("wc: bad option, status 2", r.status == 2 and r.err[1] == "wc: illegal option -- x"
    and r.err[2] == "usage: wc [-c|-m] [-lw] [file...]")

--------------------------------------------------------------------------
-- sort
--------------------------------------------------------------------------
W:file("s.txt", "pear\nApple\nbanana\napple\nCherry\n")
out("sort: by bytes", "Apple\nCherry\napple\nbanana\npear\n", "sort", "s.txt")
out("sort -r", "pear\nbanana\napple\nCherry\nApple\n", "sort", "-r", "s.txt")
out("sort -f: case folded", "Apple\napple\nbanana\nCherry\npear\n", "sort", "-f", "s.txt")
out("sort -fu: one of each, the first kept", "Apple\nbanana\nCherry\npear\n", "sort", "-fu", "s.txt")
W:file("n.txt", "10\n9\n-3\n2.5\nx\n  7\n")
out("sort -n: numbers, non-numbers count as 0", "-3\nx\n2.5\n  7\n9\n10\n", "sort", "-n", "n.txt")
out("sort -nr", "10\n9\n  7\n2.5\nx\n-3\n", "sort", "-nr", "n.txt")
W:file("ne.txt", "5\n\n-1\n")
out("sort -n: an empty line counts as 0", "-1\n\n5\n", "sort", "-n", "ne.txt")
out("sort -k2 -n: a line without the field counts as 0", "b -1\na\nc 3\n", "sort", "-k2", "-n", { pipe = true, stdin = "c 3\na\nb -1\n" })
out("sort: plain sort of numbers is by bytes", "  7\n-3\n10\n2.5\n9\nx\n", "sort", "n.txt")
out("sort -u: exact duplicates dropped", "a\nb\n", "sort", "-u", { pipe = true, stdin = "b\na\nb\na\n" })
W:file("p.txt", "root:x:0:root\nbin:x:1:bin\nzed:x:20:z\nadm:x:3:adm\n")
out("sort -t: -k3n", "root:x:0:root\nbin:x:1:bin\nadm:x:3:adm\nzed:x:20:z\n", "sort", "-t", ":", "-k3n", "p.txt")
out("sort -t: -k 3,3 (bytes)", "root:x:0:root\nbin:x:1:bin\nzed:x:20:z\nadm:x:3:adm\n", "sort", "-t:", "-k", "3,3", "p.txt")
out("sort -t: -k3nr", "zed:x:20:z\nadm:x:3:adm\nbin:x:1:bin\nroot:x:0:root\n", "sort", "-t:", "-k3nr", "p.txt")
W:file("k.txt", "b 2\na 2\nc 1\n")
out("sort -k2: ties broken by the whole line", "c 1\na 2\nb 2\n", "sort", "-k2", "k.txt")
out("sort -k2,2 -k1r: a second key", "c 1\nb 2\na 2\n", "sort", "-k2,2", "-k1r", "k.txt")
out("sort -k1.2: past the field's end is the end", "c 1\na 2\nb 2\n", "sort", "-k1.2", "k.txt")
out("sort -k1.2: from the second character", "ya\nxb\n", "sort", "-k1.2", { pipe = true, stdin = "xb\nya\n" })
out("sort -t, -k2.2,2.2", "q,zb\nq,ac\n", "sort", "-t,", "-k2.2,2.2", { pipe = true, stdin = "q,ac\nq,zb\n" })
W:file("bl.txt", "  b\n a\nc\n")
out("sort: leading blanks count", "  b\n a\nc\n", "sort", "bl.txt")
out("sort -b: leading blanks ignored", " a\n  b\nc\n", "sort", "-b", "bl.txt")
W:file("f2.txt", "x   b\ny a\n")
out("sort -k2: the field's blanks count", "x   b\ny a\n", "sort", "-k2", "f2.txt")
out("sort -k2b: unless b", "y a\nx   b\n", "sort", "-k2b", "f2.txt")
out("sort -d: punctuation ignored", "ab\na-c\n", "sort", "-d", { pipe = true, stdin = "ab\na-c\n" })
out("sort: several files and -", "Apple\nb\nm\nx\ny\n", "sort", "b.txt", "-", { stdin = "m\nb\nApple\n" })
out("sort: the keyboard", "a\nb\n", "sort", { stdin = "b\na\n" })
out("sort -m accepted", "a\nb\nc\n", "sort", "-m", "-", { pipe = true, stdin = "a\nc\nb\n" })
r = W:run("sort", "-o", "s.txt", "s.txt")
check("sort -o onto its own input", r.status == 0 and r.out == ""
    and W:read("s.txt") == "Apple\nCherry\napple\nbanana\npear\n", show(W:read("s.txt")))
out("sort -c: sorted, silent", "", "sort", "-c", "s.txt")
r = W:run("sort", "-c", "k.txt")
check("sort -c: disorder reported, status 1", r.ok and r.status == 1 and r.out == ""
    and r.err[1] == "sort: k.txt:2: disorder: a 2", show(r.errText))
r = W:run("sort", "-C", "k.txt")
check("sort -C: status 1, no message", r.status == 1 and #r.err == 0)
r = W:run("sort", "-cu", "-", { pipe = true, stdin = "a\na\n" })
check("sort -cu: a repeat is disorder", r.status == 1 and r.err[1] == "sort: -:2: disorder: a")
r = W:run("sort", "nope", "k.txt", { pipe = true })
check("sort: missing file is status 2", r.ok and r.status == 2
    and r.err[1] == "sort: nope: No such file or directory", show(r.errText))
r = W:run("sort", "-k", "0", "k.txt")
check("sort: bad key, status 2", r.status == 2 and r.err[1] == "sort: bad key: 0")
r = W:run("sort", "-t", "ab", "k.txt")
check("sort: -t takes one character", r.status == 2)

--------------------------------------------------------------------------
-- uniq
--------------------------------------------------------------------------
W:file("u.txt", "a\na\nb\nc\nc\nc\na\n")
out("uniq: adjacent repeats collapsed", "a\nb\nc\na\n", "uniq", "u.txt")
out("uniq -c: count, a space, the line", "2 a\n1 b\n3 c\n1 a\n", "uniq", "-c", "u.txt")
out("uniq -d: only repeated lines", "a\nc\n", "uniq", "-d", "u.txt")
out("uniq -u: only unrepeated lines", "b\na\n", "uniq", "-u", "u.txt")
out("uniq -cd", "2 a\n3 c\n", "uniq", "-cd", "u.txt")
W:file("uf.txt", "1 x Asame\n2  y Bsame\n3 z other\n")
out("uniq -f 2: fields skipped", "1 x Asame\n2  y Bsame\n3 z other\n", "uniq", "-f", "2", "uf.txt")
out("uniq -f2 -s2: the blank after the fields counts", "1 x Asame\n3 z other\n", "uniq", "-f2", "-s", "2", "uf.txt")
out("uniq -s 2", "ab\n", "uniq", "-s", "2", { pipe = true, stdin = "ab\nxb\n" })
out("uniq: the keyboard", "q\nr\n", "uniq", { stdin = "q\nq\nr\n" })
out("uniq -: a pipe, no last newline", "q\n", "uniq", "-", { pipe = true, stdin = "q\nq" })
r = W:run("uniq", "u.txt", "uo.txt")
check("uniq: output file operand", r.status == 0 and r.out == "" and W:read("uo.txt") == "a\nb\nc\na\n")
r = W:run("uniq", "nope")
check("uniq: missing file, status 1", r.status == 1 and r.err[1] == "uniq: nope: No such file or directory")
r = W:run("uniq", "a", "b", "c")
check("uniq: three operands is a usage error", r.status == 2 and r.err[2]:find("^usage: uniq") ~= nil)
r = W:run("uniq", "-f", "x", "u.txt")
check("uniq: bad -f, status 2", r.status == 2 and r.err[1] == "uniq: bad -f x")

--------------------------------------------------------------------------
-- cut
--------------------------------------------------------------------------
W:file("t.txt", "a\tb\tc\td\nno tabs\n")
out("cut -f 2", "b\nno tabs\n", "cut", "-f", "2", "t.txt")
out("cut -f 3,1: in line order, tab between", "a\tc\nno tabs\n", "cut", "-f3,1", "t.txt")
out("cut -f 2- -s: lines without the delimiter dropped", "b\tc\td\n", "cut", "-s", "-f", "2-", "t.txt")
out("cut -d: -f 1,3-", "root:0:root\nbin:1:bin\n", "cut", "-d:", "-f1,3-",
    { pipe = true, stdin = "root:x:0:root\nbin:x:1:bin\n" })
out("cut -d . -f2 (a magic character)", "b\n", "cut", "-d", ".", "-f2", { pipe = true, stdin = "a.b.c\n" })
out("cut -f 5: past the end is empty", "\n", "cut", "-d,", "-f5", { pipe = true, stdin = "a,b\n" })
out("cut -c 2-4", "bcd\nbc\n", "cut", "-c", "2-4", { pipe = true, stdin = "abcdef\nabc\n" })
out("cut -c -2,5-: open ranges", "abef\n", "cut", "-c-2,5-", { pipe = true, stdin = "abcdef\n" })
out("cut -c 3,1,3: each once, in order", "ac\n", "cut", "-c", "3,1,3", { pipe = true, stdin = "abc\n" })
out("cut -b 1 -n", "a\nn\n", "cut", "-nb", "1", "t.txt")
out("cut: the keyboard and a file", "k\nc\n", "cut", "-c1", "-", "sub/c.txt", { stdin = "kk\n" })
r = W:run("cut", "-c1", "nope", "sub/c.txt")
check("cut: missing file, status 1", r.status == 1 and r.err[1] == "cut: nope: No such file or directory"
    and r.out == "c\n")
r = W:run("cut", "t.txt")
check("cut: no list is a usage error", r.status == 2 and r.err[2]:find("^usage: cut") ~= nil)
r = W:run("cut", "-c", "1", "-f", "1", "t.txt")
check("cut: -c and -f together", r.status == 2)
r = W:run("cut", "-c", "0", "t.txt")
check("cut: list from 0 is bad", r.status == 2 and r.err[1] == "cut: bad list: 0")
r = W:run("cut", "-c", "3-2", "t.txt")
check("cut: decreasing range is bad", r.status == 2)
r = W:run("cut", "-c1", "-d:", "t.txt")
check("cut: -d needs -f", r.status == 2)

--------------------------------------------------------------------------
-- tr
--------------------------------------------------------------------------
local function tr(label, want, input, ...)
    local args = { ... }
    args[#args + 1] = { pipe = true, stdin = input }
    return out(label, want, "tr", table.unpack(args))
end
tr("tr abc xyz", "xyz yzx\n", "abc bca\n", "abc", "xyz")
tr("tr a-z A-Z: ranges", "HELLO, WORLD\n", "hello, world\n", "a-z", "A-Z")
tr("tr [:lower:] [:upper:]", "HELLO 1\n", "hello 1\n", "[:lower:]", "[:upper:]")
tr("tr [:upper:] [:lower:]", "mixed\n", "MiXeD\n", "[:upper:]", "[:lower:]")
tr("tr: string2 short, last char repeats", "axxx\n", "abcd\n", "bcd", "x")
tr("tr -d", "hll wrld\n", "hello world\n", "-d", "aeiou")
tr("tr -d [:digit:]", "abc\n", "a1b22c333\n", "-d", "[:digit:]")
tr("tr -s: squeeze string1", "a b c\n", "a   b    c\n", "-s", " ")
tr("tr -s across lines", "a\nb\n", "a\n\n\nb\n", "-s", "\\n")
tr("tr -s with translation squeezes string2", "x-y\n", "x  ;; y\n", "-s", " ;", "--")
tr("tr -ds", "aabb c\n", "aa1bb  2c\n", "-ds", "0-9", " ")
tr("tr -c: the complement", "abc___", "abc123", "-c", "a-z", "_")
tr("tr -C", "aa\n", "a1a!\n", "-Cd", "a\\n")
tr("tr -cs: words one per line", "one\ntwo\nthree\n", "one, two;  three\n", "-cs", "[:alpha:]", "\\n")
tr("tr octal escapes", "a-b\n", "a\tb\n", "\\011", "\\055")
tr("tr \\\\ is a backslash", "a/b\n", "a\\b\n", "\\\\", "/")
tr("tr [x*] fills string2", "xxxd\n", "abcd\n", "abc", "[x*]")
tr("tr [x*2]y", "xxyd\n", "abcd\n", "abc", "[x*2]y")
tr("tr [=a=]", "Xbc\n", "abc\n", "[=a=]", "X")
tr("tr [:space:] to _", "a_b_c_", "a b\tc\n", "[:space:]", "_")
tr("tr: a dash at the end is itself", "a_b\n", "a-b\n", "a-", "a_")
tr("tr -d [:cntrl:] (newlines too)", "ab", "a\1b\127\n", "-d", "[:cntrl:]")
tr("tr -cd [:print:]: the unprintable go", "a b", "a\1 b\n", "-cd", "[:print:]")
tr("tr [:graph:] to #", "## \1\n", "a! \1\n", "[:graph:]", "#")
out("tr: the keyboard", "AB\nC\n", "tr", "a-z", "A-Z", { stdin = "ab\nc\n" })
r = W:run("tr", "a")
check("tr: translating needs string2, status 2", r.status == 2 and r.err[1] == "tr: missing operand"
    and r.err[2]:find("^usage: tr") ~= nil)
r = W:run("tr", "-d", "a", "b")
check("tr -d takes one string", r.status == 2 and r.err[1] == "tr: extra operand")
r = W:run("tr", "z-a", "x", { pipe = true, stdin = "" })
check("tr: reversed range", r.status == 1 and r.err[1]:find("reverse order") ~= nil)
r = W:run("tr", "[:nope:]", "x", { pipe = true, stdin = "" })
check("tr: unknown class", r.status == 1 and r.err[1] == "tr: invalid class: nope")

--------------------------------------------------------------------------
-- found in review
--------------------------------------------------------------------------
tr("tr [=a=] is only a", "X=[]\n", "a=[]\n", "[=a=]", "X")
tr("tr [=\\r=] takes an escape", "ab\n", "a\rb\n", "-d", "[=\\r=]")
r = W:run("cut", "-f", "x", { pipe = true, stdin = "a\tb\n" })
check("cut: a list that isn't numbers is bad", r.status == 2 and r.err[1] == "cut: bad list: x", show(r.errText))
r = W:run("cut", "-c", "-", { pipe = true, stdin = "abc\n" })
check("cut: a lone - is bad", r.status == 2 and r.err[1] == "cut: bad list: -", show(r.errText))
r = W:run("sort", "-o", "/rom/x", { pipe = true, stdin = "b\na\n" })
check("sort -o: unwritable, path once, status 2", r.status == 2 and r.err[1] == "sort: /rom/x: Access denied",
    show(r.errText))
r = W:run("uniq", "-", "/rom/x", { pipe = true, stdin = "b\na\n" })
check("uniq: unwritable output, path once, status 1", r.status == 1 and r.err[1] == "uniq: /rom/x: Access denied",
    show(r.errText))
out("wc: empty input", "0 0 0\n", "wc", { pipe = true, stdin = "" })
-- a few thousand lines: every filter yields as it goes (each yield is a
-- queued event the program pulls straight back) and gets the right answer.
-- (cu.breathe yields once a second at most: here the clock runs half a
-- second each time it's read)
local big = {}
for i = 1, 3000 do big[i] = tostring(3001 - i) end
big = table.concat(big, "\n") .. "\n"
local function yields(label, want, ...)
    local args = { ... }
    local pulls = 0
    args[#args + 1] = { pipe = true, stdin = big, onPull = function() pulls = pulls + 1 end }
    local realClock, tick = W.os.clock, 0
    W.os.clock = function() tick = tick + 0.5; return tick end
    local res = W:run(table.unpack(args))
    W.os.clock = realClock
    check(label, res.status == 0 and want(res.out) and pulls >= 1, "pulls " .. pulls .. " status " .. tostring(res.status))
end
yields("sort -n of 3000 lines yields", function(o) return o:sub(1, 8) == "1\n2\n3\n4\n" end, "sort", "-n")
yields("uniq of 3000 lines yields", function(o) return o == big end, "uniq")
yields("cut of 3000 lines yields", function(o) return #o == #big end, "cut", "-c1-")
yields("tr of 3000 lines yields", function(o) return o == big:gsub("1", "x") end, "tr", "1", "x")
out("wc of 3000 lines", "3000 3000 " .. #big .. "\n", "wc", { pipe = true, stdin = big })

--------------------------------------------------------------------------
-- through the stock shell, from another directory
--------------------------------------------------------------------------
r = W:sh("wc -l a.txt")
check("wc through the shell", r.ok and r.out == "4 a.txt\n", show(r.out))
r = W:sh('tr "a b" "x_y"', { pipe = true, stdin = "a b\n" })
check("tr through the shell, quotes keep the space", r.ok and r.out == "x_y\n", show(r.out))
r = W:sh("cut -c1 nope")
check("a failing utility: status 1, only its own message", r.status == 1 and #r.err == 1,
    show(r.errText))
r = W:call(function(env)
    env.shell.setDir("")
    return env.shell.run("cut", "-c1", "nope")
end)
check("... and shell.run returns false", r.value == false)
