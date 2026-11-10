-- sim/coreutils_compare.lua
--
-- cmp and diff in a shellworld: every option, files and standard input
-- (the keyboard and a pipe), "-", missing files, usage errors, and the
-- POSIX output formats line for line.
local PROJ = ...
package.path = PROJ .. "/lib/?.lua;" .. PROJ .. "/sim/lib/?.lua;" .. package.path
local M = require("mock")
local SW = require("shellworld")
local check = M.check

local W = SW.new(PROJ)
local function show(s)
    return (tostring(s):gsub("[%c\128-\255]", function(c) return c == "\n" and "|" or "\\" .. c:byte() end))
end
local function lines(t) return table.concat(t, "\n") .. "\n" end

--------------------------------------------------------------------------
-- cmp
--------------------------------------------------------------------------
W:file("a.txt", "one\ntwo\nthree\n")
W:file("same.txt", "one\ntwo\nthree\n")
W:file("b.txt", "one\ntwX\nthrea\n")
W:file("short.txt", "one\ntw")
W:file("bin1", "A\0\255")
W:file("bin2", "A\1\255")

local r = W:run("cmp", "a.txt", "same.txt")
check("cmp: identical files: status 0, no output", r.ok and r.status == 0 and r.out == "" and #r.err == 0)
r = W:run("cmp", "a.txt", "b.txt")
check("cmp: first difference as 'differ: char N, line L', status 1",
    r.status == 1 and r.out == "a.txt b.txt differ: char 7, line 2\n", show(r.out))
r = W:run("cmp", "-l", "a.txt", "b.txt")
check("cmp -l: every difference as '%d %o %o'",
    r.status == 1 and r.out == "7 157 130\n13 145 141\n", show(r.out))
r = W:run("cmp", "-l", "bin1", "bin2")
check("cmp -l on binary bytes", r.out == "2 0 1\n", show(r.out))
r = W:run("cmp", "-s", "a.txt", "b.txt")
check("cmp -s: no output, status 1", r.status == 1 and r.out == "" and #r.err == 0)
r = W:run("cmp", "-s", "a.txt", "same.txt")
check("cmp -s: identical, status 0", r.status == 0 and r.out == "")
r = W:run("cmp", "a.txt", "short.txt")
check("cmp: one file is the start of the other: EOF on the shorter, status 1",
    r.status == 1 and r.out == "" and r.err[1] == "cmp: EOF on short.txt after byte 6", show(r.errText))
r = W:run("cmp", "-s", "short.txt", "a.txt")
check("cmp -s: EOF is silent too", r.status == 1 and #r.err == 0 and r.out == "")
W:file("short2.txt", "onE\ntw")
r = W:run("cmp", "-l", "b.txt", "short2.txt")
check("cmp -l: the differences, then EOF", r.out == "3 145 105\n" and r.err[1] == "cmp: EOF on short2.txt after byte 6",
    show(r.out) .. " " .. show(r.errText))
r = W:run("cmp", "a.txt", "-", { pipe = true, stdin = "one\ntwo\nthreE\n" })
check("cmp: '-' is a pipe", r.status == 1 and r.out == "a.txt - differ: char 13, line 3\n", show(r.out))
r = W:run("cmp", "-", "a.txt", { stdin = "one\ntwo\nthree\n" })
check("cmp: '-' is the keyboard (Ctrl+T ends it)", r.status == 0 and r.out == "")
r = W:run("cmp", "-", "-", { pipeIn = true, stdin = "x\n" })
check("cmp - -: the same stream, so the same", r.status == 0)
r = W:run("cmp", "a.txt", "nope")
check("cmp: missing file: status 2", r.status == 2 and r.err[1] == "cmp: nope: No such file or directory"
    and r.out == "", show(r.errText))
r = W:run("cmp", "a.txt")
check("cmp: one operand: usage, status 2", r.status == 2 and r.err[1] == "usage: cmp [-l|-s] file1 file2")
r = W:run("cmp", "-l", "-s", "a.txt", "b.txt")
check("cmp: -l with -s: status 2", r.status == 2)
r = W:run("cmp", "-x", "a.txt", "b.txt")
check("cmp: unknown option: status 2", r.status == 2 and r.err[1] == "cmp: illegal option -- x")
r = W:sh("cmp -l a.txt b.txt")
check("cmp through the shell", r.out == "7 157 130\n13 145 141\n")

--------------------------------------------------------------------------
-- diff
--------------------------------------------------------------------------
W:file("o.txt", "a\nb\nc\nd\ne\nf\ng\nh\ni\nj\nk\nl\nm\n")
W:file("n.txt", "a\nB\nc\nd\ne\nf\ng\nh\ni\nj\nl\nm\nn\nnew\n")
W:file("p.txt", "x\ny")
W:file("q.txt", "x\nz")
W:file("empty", "")
-- fixed times for the -c and -u headers: 2026-10-28 12:00:00.250 and 12:01:05 UTC
for _, f in ipairs({ "o.txt", "p.txt", "empty" }) do W.mtime[f] = 1793188800250 end
for _, f in ipairs({ "n.txt", "q.txt" }) do W.mtime[f] = 1793188865000 end

r = W:run("diff", "o.txt", "o.txt")
check("diff: no differences: status 0, no output", r.status == 0 and r.out == "" and #r.err == 0)
r = W:run("diff", "o.txt", "n.txt")
check("diff: normal format (c, d and a commands), status 1", r.status == 1 and r.out == lines({
    "2c2", "< b", "---", "> B", "11d10", "< k", "13a13,14", "> n", "> new" }), show(r.out))
r = W:run("diff", "n.txt", "o.txt")
check("diff: the other way round", r.out == lines({
    "2c2", "< B", "---", "> b", "10a11", "> k", "13,14d13", "< n", "< new" }), show(r.out))
r = W:run("diff", "-u", "o.txt", "n.txt")
check("diff -u: unified format with headers and hunks", r.status == 1 and r.out == lines({
    "--- o.txt\t2026-10-28 12:00:00.250000000 +0000",
    "+++ n.txt\t2026-10-28 12:01:05.000000000 +0000",
    "@@ -1,5 +1,5 @@", " a", "-b", "+B", " c", " d", " e",
    "@@ -8,6 +8,7 @@", " h", " i", " j", "-k", " l", " m", "+n", "+new" }), show(r.out))
r = W:run("diff", "-U0", "o.txt", "n.txt")
check("diff -U0: no context, empty ranges as N,0", r.out:match("\n(@@.*)$") == lines({
    "@@ -2 +2 @@", "-b", "+B", "@@ -11 +10,0 @@", "-k", "@@ -13,0 +13,2 @@", "+n", "+new" }), show(r.out))
r = W:run("diff", "-c", "o.txt", "n.txt")
check("diff -c: context format", r.status == 1 and r.out == lines({
    "*** o.txt Wed Oct 28 12:00:00 2026", "--- n.txt Wed Oct 28 12:01:05 2026",
    "***************", "*** 1,5 ****", "  a", "! b", "  c", "  d", "  e",
    "--- 1,5 ----", "  a", "! B", "  c", "  d", "  e",
    "***************", "*** 8,13 ****", "  h", "  i", "  j", "- k", "  l", "  m",
    "--- 8,14 ----", "  h", "  i", "  j", "  l", "  m", "+ n", "+ new" }), show(r.out))
W:file("day7.txt", "x\n")
W.mtime["day7.txt"] = 1794052800000         -- Sat 2026-11-07 12:00:00 UTC: a one-digit day
r = W:run("diff", "-c", "o.txt", "day7.txt")
local head7 = lines({ "*** o.txt Wed Oct 28 12:00:00 2026", "--- day7.txt Sat Nov  7 12:00:00 2026" })
check("diff -c: a one-digit day padded with a space", r.out:sub(1, #head7) == head7, show(r.out))
r = W:run("diff", "-C", "1", "o.txt", "n.txt")
check("diff -C 1: one line of context", r.out:match("\n(%*%*%*%*.*)$") == lines({
    "***************", "*** 1,3 ****", "  a", "! b", "  c", "--- 1,3 ----", "  a", "! B", "  c",
    "***************", "*** 10,13 ****", "  j", "- k", "  l", "  m",
    "--- 10,14 ----", "  j", "  l", "  m", "+ n", "+ new" }), show(r.out))
r = W:run("diff", "-e", "o.txt", "n.txt")
check("diff -e: an ed script, last change first", r.out == lines({
    "13a", "n", "new", ".", "11d", "2c", "B", "." }), show(r.out))
r = W:run("diff", "-f", "o.txt", "n.txt")
check("diff -f: forwards, letter first", r.out == lines({
    "c2", "B", ".", "d11", "a13", "n", "new", "." }), show(r.out))
r = W:run("diff", "-u", "-c", "o.txt", "n.txt")
check("diff: the last format option wins", r.out:sub(1, 4) == "*** ")
r = W:run("diff", "p.txt", "q.txt")
check("diff: a last line with no newline is noted", r.out == lines({
    "2c2", "< y", "\\ No newline at end of file", "---", "> z", "\\ No newline at end of file" }), show(r.out))
W:file("p2.txt", "x\ny\n")
r = W:run("diff", "p.txt", "p2.txt")
check("diff: 'y' and 'y\\n' differ", r.status == 1 and r.out == lines({
    "2c2", "< y", "\\ No newline at end of file", "---", "> y" }), show(r.out))
r = W:run("diff", "-u", "empty", "p.txt")
check("diff -u from an empty file: -0,0", r.out:match("\n(@@.*)$") == lines({
    "@@ -0,0 +1,2 @@", "+x", "+y", "\\ No newline at end of file" }), show(r.out))
r = W:run("diff", "-c", "p.txt", "empty")
check("diff -c to an empty file", r.out:match("\n(%*%*%*%*.*)$") == lines({
    "***************", "*** 1,2 ****", "- x", "- y", "\\ No newline at end of file", "--- 0 ----" }), show(r.out))

W:file("s1.txt", "a  b\nc\t\nd\n")
W:file("s2.txt", "a b\nc\nd x\n")
r = W:run("diff", "-b", "s1.txt", "s2.txt")
check("diff -b: blank runs and trailing blanks don't count", r.status == 1 and r.out == lines({
    "3c3", "< d", "---", "> d x" }), show(r.out))
W:file("s3.txt", "a b \nc\nd\n")
r = W:run("diff", "-b", "s1.txt", "s3.txt")
check("diff -b: only blank differences: status 0", r.status == 0 and r.out == "")
r = W:run("diff", "-q", "o.txt", "n.txt")
check("diff -q: just says so", r.status == 1 and r.out == "Files o.txt and n.txt differ\n", show(r.out))
r = W:run("diff", "-q", "o.txt", "o.txt")
check("diff -q: same: silent, status 0", r.status == 0 and r.out == "")
r = W:run("diff", "bin1", "bin2")
check("diff: binary files", r.status == 1 and r.out == "Files bin1 and bin2 differ\n", show(r.out))

r = W:run("diff", "o.txt", "-", { pipe = true, stdin = "a\nb\nc\nd\ne\nf\ng\nh\ni\nj\nk\nl\nM\n" })
check("diff: '-' is a pipe", r.status == 1 and r.out == lines({ "13c13", "< m", "---", "> M" }), show(r.out))
r = W:run("diff", "-", "p2.txt", { stdin = "x\nY\n" })
check("diff: '-' is the keyboard", r.out == lines({ "2c2", "< Y", "---", "> y" }), show(r.out))
r = W:run("diff", "-", "-", { pipeIn = true, stdin = "x\n" })
check("diff - -: the same stream", r.status == 0 and r.out == "")
r = W:run("diff", "o.txt", "nope")
check("diff: missing file: status 2", r.status == 2 and r.out == ""
    and r.err[1] == "diff: nope: No such file or directory", show(r.errText))
r = W:run("diff", "o.txt")
check("diff: one operand: usage, status 2", r.status == 2
    and r.err[1] == "usage: diff [-c|-e|-f|-u|-C n|-U n] [-bqr] file1 file2", show(r.errText))
r = W:run("diff", "-U", "x", "o.txt", "n.txt")
check("diff -U x: status 2", r.status == 2 and r.err[1] == "diff: bad context length: x")
r = W:run("diff", "-z", "o.txt", "n.txt")
check("diff: unknown option: status 2", r.status == 2 and r.err[1] == "diff: illegal option -- z")

-- directories
W:file("d1/same", "s\n")
W:file("d1/chg", "old\n")
W:file("d1/only1", "1\n")
W:file("d1/sub/deep", "x\n")
W:file("d2/same", "s\n")
W:file("d2/chg", "new\n")
W:file("d2/only2", "2\n")
W:file("d2/sub/deep", "y\n")
W:file("chg", "new\n")
r = W:run("diff", "d1", "chg")
check("diff dir file: the file of that name in the dir", r.status == 1
    and r.out == lines({ "1c1", "< old", "---", "> new" }), show(r.out))
r = W:run("diff", "d1", "d2")
check("diff dir dir: by name, 'Only in', 'Common subdirectories'", r.status == 1 and r.out == lines({
    "diff d1/chg d2/chg", "1c1", "< old", "---", "> new",
    "Only in d1: only1", "Only in d2: only2", "Common subdirectories: d1/sub and d2/sub" }), show(r.out))
r = W:run("diff", "-r", "-u", "d1", "d2")
check("diff -r: into subdirectories, the options on the 'diff' line",
    r.out:find("diff -r -u d1/sub/deep d2/sub/deep\n--- d1/sub/deep\t", 1, true) ~= nil
    and r.out:find("\n-x\n+y\n", 1, true) ~= nil, show(r.out))
r = W:run("diff", "-rq", "d1", "d2")
check("diff -rq", r.out == lines({ "Files d1/chg and d2/chg differ", "Only in d1: only1", "Only in d2: only2",
    "Files d1/sub/deep and d2/sub/deep differ" }), show(r.out))
r = W:run("diff", "d1/same", "d2/same", { cwd = "" })
check("diff: same files in dirs: 0", r.status == 0)

-- through the shell, from a subdirectory, with an absolute path
r = W:sh("diff -u ../o.txt /n.txt", { cwd = "d1" })
W.shell.setDir("")
check("diff through the shell from a subdirectory", r.status == 1 and r.out:find("+++ /n.txt\t", 1, true) ~= nil,
    show(r.out))

-- a bigger one stays quick: 2000 lines, a few edits, and two unrelated files
local big1, big2, other = {}, {}, {}
for i = 1, 2000 do big1[i] = "line " .. i; big2[i] = "line " .. i; other[i] = "other " .. i end
big2[500], big2[1500] = "changed", "changed too"
table.remove(big2, 1000)
W:file("big1", lines(big1)); W:file("big2", lines(big2)); W:file("other", lines(other))
local t0 = os.clock()
r = W:run("diff", "big1", "big2")
check("diff: 2000 lines, 3 edits", r.out == lines({ "500c500", "< line 500", "---", "> changed",
    "1000d999", "< line 1000", "1500c1499", "< line 1500", "---", "> changed too" }), show(r.out))
r = W:run("diff", "big1", "other")
check("diff: 2000 lines, all different: one change", r.out:sub(1, 16) == "1,2000c1,2000\n< ", show(r.out:sub(1, 30)))
check("diff: both quick (under 2 s)", os.clock() - t0 < 2)

-- a clock that runs 1s per call: the long loops must yield (queue an
-- event and pull it back) and still give the same output
local realClock, tick, pulls = W.os.clock, 0, 0
W.os.clock = function() tick = tick + 1; return tick end
local function counted(o) o.onPull = function() pulls = pulls + 1 end; return o end
r = W:run("diff", "big1", "other", counted({ pipe = true }))
check("diff: yields during a long output", r.ok and r.status == 1 and #r.out > 30000 and #r.events == 0
    and pulls > 3, tostring(r.error) .. " pulls " .. pulls)
pulls = 0
local fwd, rev = {}, {}
for i = 1, 400 do fwd[i] = "line " .. i; rev[401 - i] = "line " .. i end
W:file("fwd", lines(fwd)); W:file("rev", lines(rev))
r = W:run("diff", "fwd", "rev", counted({ pipe = true }))
local _, kept = r.out:gsub("\n[<>] ", "")
check("diff: yields while searching a file against its reverse", r.ok and r.status == 1 and pulls > 0
    and kept == 798, "pulls " .. pulls .. " changed lines " .. kept)
pulls = 0
r = W:run("cmp", "-l", "big1", "other", counted({ pipe = true }))
check("cmp -l: yields during a long output", r.ok and r.status == 1 and #r.events == 0 and pulls > 3,
    tostring(r.error) .. " pulls " .. pulls)
W.os.clock = realClock

-- ed scripts: a line of just "." is written as "..", then s/.// puts it back
W:file("dot0", "x\n")
W:file("dot1", "x\n.\ny\n")
W:file("dot2", ".\n")
r = W:run("diff", "-e", "dot0", "dot1")
check("diff -e: a '.' line in the middle of the text", r.out == lines({
    "1a", "..", ".", "s/.//", "a", "y", "." }), show(r.out))
r = W:run("diff", "-e", "dot0", "dot2")
check("diff -e: a '.' line at the end of the text", r.out == lines({ "1c", "..", ".", "s/.//" }), show(r.out))

-- -C 0 is allowed (GNU output)
r = W:run("diff", "-C", "0", "o.txt", "n.txt")
check("diff -C 0", r.status == 1 and r.out:match("\n(%*%*%*%*.*)$") == lines({
    "***************", "*** 2 ****", "! b", "--- 2 ----", "! B",
    "***************", "*** 11 ****", "- k", "--- 10 ----",
    "***************", "*** 13 ****", "--- 13,14 ----", "+ n", "+ new" }), show(r.out))
r = W:run("diff", "-C", "-1", "o.txt", "n.txt")
check("diff -C -1: status 2", r.status == 2 and r.err[1] == "diff: bad context length: -1")

-- "--" is not repeated on the "diff <options>" line
r = W:run("diff", "-r", "--", "d1", "d2")
check("diff -r -- d1 d2", r.out:find("diff -r d1/chg d2/chg\n", 1, true) ~= nil, show(r.out))

-- CRLF lines differ from LF ones, except under -b
W:file("crlf", "a\r\nb\r\n")
W:file("lf", "a\nb\n")
r = W:run("diff", "crlf", "lf")
check("diff: CRLF against LF differs", r.status == 1 and r.out == "1,2c1,2\n< a\r\n< b\r\n---\n> a\n> b\n", show(r.out))
r = W:run("diff", "-b", "crlf", "lf")
check("diff -b: a trailing CR is white space", r.status == 0 and r.out == "")
r = W:run("cmp", "crlf", "lf")
check("cmp: CRLF against LF", r.out == "crlf lf differ: char 2, line 1\n", show(r.out))

-- directory operands that cmp can't read; diff with a file and a dir inside dirs
r = W:run("cmp", "d1", "a.txt")
check("cmp: a directory: status 2", r.status == 2 and r.err[1] == "cmp: d1: Is a directory", show(r.errText))
W:file("e1/x", "1\n"); W:file("e2/x/y", "1\n")
r = W:run("diff", "e1", "e2")
check("diff: a file against a directory inside directories", r.status == 1
    and r.out == "File e1/x is a regular file while file e2/x is a directory\n", show(r.out))
r = W:run("diff", "nope1", "nope2")
check("diff: both missing: both reported, status 2", r.status == 2 and #r.err == 2, show(r.errText))
r = W:run("cmp", "empty", "a.txt")
check("cmp: an empty file is the start of any other", r.status == 1 and r.err[1] == "cmp: EOF on empty after byte 0",
    show(r.errText))
