-- sim/coreutils_head-tail.lua
--
-- head and tail in a shellworld: their options, files against standard
-- input (the keyboard and a pipe), "-", headers for several files, bad
-- files and bad numbers, and tail -f following a file that grows.
local PROJ = ...
package.path = PROJ .. "/lib/?.lua;" .. PROJ .. "/sim/lib/?.lua;" .. package.path
local M = require("mock")
local SW = require("shellworld")
local check = M.check

local W = SW.new(PROJ)
local function lines(a, b)
    local t = {}
    for i = a, b do t[#t + 1] = "l" .. i .. "\n" end
    return table.concat(t)
end
W:file("twelve.txt", lines(1, 12))
W:file("short.txt", "a\nb\nc")              -- no newline at the end
W:file("crlf.txt", "x\r\ny\r\nz\r\n")
W:file("empty.txt", "")
W:dir("sub")

local function ok0(r) return r.ok and r.status == 0 and #r.err == 0 end

--------------------------------------------------------------------------
-- head
--------------------------------------------------------------------------
local r = W:run("head", "twelve.txt")
check("head: 10 lines by default", ok0(r) and r.out == lines(1, 10))
r = W:run("head", "-n", "3", "twelve.txt")
check("head -n 3", ok0(r) and r.out == lines(1, 3))
r = W:run("head", "-n3", "twelve.txt")
check("head -n3 (attached)", ok0(r) and r.out == lines(1, 3))
r = W:run("head", "-2", "twelve.txt")
check("head -2 means -n 2", ok0(r) and r.out == lines(1, 2))
r = W:run("head", "-n", "0", "twelve.txt")
check("head -n 0 writes nothing", ok0(r) and r.out == "")
r = W:run("head", "-n", "50", "short.txt")
check("head: a short file whole, no newline added", ok0(r) and r.out == "a\nb\nc")
r = W:run("head", "-n", "2", "crlf.txt")
check("head: CRLF lines kept byte for byte", ok0(r) and r.out == "x\r\ny\r\n")
r = W:run("head", "-n", "2", { stdin = "k1\nk2\nk3\n" })
check("head: keyboard stops after n lines", ok0(r) and r.out == "k1\nk2\n" and #r.typed == 1)
r = W:run("head", { stdin = "k1\nk2\n" })
check("head: keyboard ended by Ctrl+T", ok0(r) and r.out == "k1\nk2\n")
r = W:run("head", "-n", "1", { stdin = "p1\np2\n", pipe = true })
check("head: from a pipe, to a pipe", ok0(r) and r.out == "p1\n")
r = W:run("head", "-n", "1", "short.txt", "-", "twelve.txt", { stdin = "s1\ns2\n", pipe = true })
check("head: headers for several files, \"-\" named as given",
    ok0(r) and r.out == "==> short.txt <==\na\n\n==> - <==\ns1\n\n==> twelve.txt <==\nl1\n")
r = W:run("head", "-n", "1", "nope", "short.txt", { pipe = true })
check("head: missing file reported, the rest still written, status 1",
    r.ok and r.status == 1 and r.err[1] == "head: nope: No such file or directory"
    and r.out == "==> short.txt <==\na\n")
r = W:run("head", "sub", { pipe = true })
check("head: a directory", r.status == 1 and r.err[1] == "head: sub: Is a directory")
r = W:run("head", "-n", "x", "twelve.txt")
check("head -n x: usage error, status 2", r.ok and r.status == 2 and r.out == ""
    and r.err[1] == "head: bad -n x" and r.err[2] == "usage: head [-c number | -n number] [file...]")
r = W:run("head", "-n", "-1", "twelve.txt")
check("head -n -1 refused", r.status == 2 and r.err[1] == "head: bad -n -1")
r = W:run("head", "-n", "2", "-c", "3", "twelve.txt")
local r2 = W:run("head", "-c", "3", "-n", "2", "twelve.txt")
check("head: the last of -c and -n wins", r.out == "l1\n" and r2.out == "l1\nl2\n", r.out .. "~" .. r2.out)
r = W:run("head", "-q", "twelve.txt")
check("head -q: illegal option", r.status == 2 and r.err[1] == "head: illegal option -- q")
r = W:run("head", "-n")
check("head -n with no number", r.status == 2 and r.err[1] == "head: option requires an argument -- n")
r = W:run("head", "-n", "2", "--", "twelve.txt", { cwd = "" })
check("head: -- ends the options", ok0(r) and r.out == lines(1, 2))
r = W:run("head", "-n", "1", "../twelve.txt", { cwd = "sub" })
W.shell.setDir("")
check("head: operands resolve against the shell's directory", ok0(r) and r.out == "l1\n")
r = W:sh("head -n 1 twelve.txt")
check("head through the shell", ok0(r) and r.out == "l1\n")
r = W:run("head", "-c", "5", "twelve.txt")
check("head -c 5", ok0(r) and r.out == "l1\nl2")
r = W:run("head", "-c", "99", "short.txt")
check("head -c past the end: the whole file", ok0(r) and r.out == "a\nb\nc")
r = W:run("head", "-c", "4", { stdin = "abc\ndef\n" })
check("head -c 4 from the keyboard", ok0(r) and r.out == "abc\n" and #r.typed == 1)
r = W:run("head", "-c", "5", { stdin = "abc\ndef\n" })
check("head -c 5 from the keyboard cuts a line", ok0(r) and r.out == "abc\nd")
r = W:run("head", "-n", "5", "-c", "3", "twelve.txt")
check("head: the last of -n and -c wins", ok0(r) and r.out == "l1\n")
r = W:run("head", "-n", "99999999999999999999", "short.txt")
check("head: a huge count", ok0(r) and r.out == "a\nb\nc")
r = W:run("head", "-c", "99999999999999999999", "short.txt")
check("head -c: a huge count", ok0(r) and r.out == "a\nb\nc")
local big = {}
for i = 1, 3000 do big[i] = ("line %04d\n"):format(i) end
big = table.concat(big)
W:file("big.txt", big)
r = W:run("head", "-n", "2999", "big.txt", { pipe = true })
check("head: 2999 of 3000 lines, yielding as it goes",
    ok0(r) and r.out == big:sub(1, #big - 10) and #W.T.events == 0)
r = W:run("head", "-c", "10005", "big.txt")
check("head -c across read chunks", ok0(r) and r.out == big:sub(1, 10005))

--------------------------------------------------------------------------
-- tail
--------------------------------------------------------------------------
r = W:run("tail", "twelve.txt")
check("tail: last 10 lines by default", ok0(r) and r.out == lines(3, 12))
r = W:run("tail", "-n", "3", "twelve.txt")
check("tail -n 3", ok0(r) and r.out == lines(10, 12))
r = W:run("tail", "-n", "-3", "twelve.txt")
check("tail -n -3 is the same", ok0(r) and r.out == lines(10, 12))
r = W:run("tail", "-3", "twelve.txt")
check("tail -3 means -n 3", ok0(r) and r.out == lines(10, 12))
r = W:run("tail", "-n", "+11", "twelve.txt")
check("tail -n +11 starts at line 11", ok0(r) and r.out == lines(11, 12))
r = W:run("tail", "-n", "+1", "twelve.txt")
check("tail -n +1 is the whole file", ok0(r) and r.out == lines(1, 12))
r = W:run("tail", "-n", "+0", "twelve.txt")
check("tail -n +0 is the whole file too", ok0(r) and r.out == lines(1, 12))
r = W:run("tail", "-n", "+20", "twelve.txt")
check("tail -n +20 past the end: nothing", ok0(r) and r.out == "")
r = W:run("tail", "-n", "0", "twelve.txt")
check("tail -n 0 writes nothing", ok0(r) and r.out == "")
r = W:run("tail", "-n", "50", "twelve.txt")
check("tail -n 50 of 12 lines: all of them", ok0(r) and r.out == lines(1, 12))
r = W:run("tail", "-n", "2", "short.txt")
check("tail: last line without a newline counts", ok0(r) and r.out == "b\nc")
r = W:run("tail", "-c", "4", "twelve.txt")
check("tail -c 4", ok0(r) and r.out == "l12\n")
r = W:run("tail", "-c", "+5", "short.txt")
check("tail -c +5 starts at byte 5", ok0(r) and r.out == "c")
r = W:run("tail", "-c", "0", "short.txt")
check("tail -c 0 writes nothing", ok0(r) and r.out == "")
r = W:run("tail", "-c", "99", "short.txt")
check("tail -c bigger than the file", ok0(r) and r.out == "a\nb\nc")
r = W:run("tail", "-c", "2", "-n", "1", "twelve.txt")
check("tail: the last of -c and -n wins", ok0(r) and r.out == "l12\n")
r = W:run("tail", "empty.txt")
check("tail of an empty file", ok0(r) and r.out == "")
r = W:run("tail", "-n", "2", "crlf.txt")
check("tail: CRLF kept", ok0(r) and r.out == "y\r\nz\r\n")
r = W:run("tail", "-n", "2", { stdin = "k1\nk2\nk3\n" })
check("tail: keyboard until Ctrl+T", ok0(r) and r.out == "k2\nk3\n")
r = W:run("tail", "-n", "1", "-", { stdin = "p1\np2", pipe = true })
check("tail: \"-\" from a pipe", ok0(r) and r.out == "p2")
r = W:run("tail", "-n", "1", "short.txt", "twelve.txt", { pipe = true })
check("tail: headers for several files",
    ok0(r) and r.out == "==> short.txt <==\nc\n==> twelve.txt <==\nl12\n")
r = W:run("tail", "-n", "1", "twelve.txt", "twelve.txt", { pipe = true })
check("tail: a blank line between files",
    ok0(r) and r.out == "==> twelve.txt <==\nl12\n\n==> twelve.txt <==\nl12\n")
r = W:run("tail", "nope", { pipe = true })
check("tail: missing file, status 1",
    r.ok and r.status == 1 and r.out == "" and r.err[1] == "tail: nope: No such file or directory")
r = W:run("tail", "-n", "1.5", "twelve.txt")
check("tail -n 1.5: usage error, status 2", r.status == 2 and r.err[1] == "tail: invalid number: 1.5"
    and r.err[2] == "usage: tail [-f | -r] [-c number | -n number] [file...]")
r = W:run("tail", "-x")
check("tail -x: illegal option", r.status == 2 and r.err[1] == "tail: illegal option -- x")

r = W:run("tail", "-c", "99999999999999999999", "short.txt")
check("tail -c: a huge count", ok0(r) and r.out == "a\nb\nc")
r = W:run("tail", "-n", "-99999999999999999999", "short.txt")
check("tail -n: a huge count", ok0(r) and r.out == "a\nb\nc")
r = W:run("tail", "-n", "+99999999999999999999", "short.txt")
check("tail -n: a huge + count", ok0(r) and r.out == "")
r = W:run("tail", "-r", "short.txt")
check("tail -r: every line, last first", ok0(r) and r.out == "c\nb\na\n")
r = W:run("tail", "-r", "-n", "2", "twelve.txt")
check("tail -r -n 2", ok0(r) and r.out == "l12\nl11\n")
r = W:run("tail", "-r", "empty.txt")
check("tail -r of an empty file", ok0(r) and r.out == "")
r = W:run("tail", "-r", { stdin = "x\ny\n" })
check("tail -r from the keyboard", ok0(r) and r.out == "y\nx\n")
W:file("crlf.txt", "a\r\nb\r\nc")
r = W:run("tail", "-r", "crlf.txt")
check("tail -r: CR LF lines keep their CR; the last line gets a newline", ok0(r) and r.out == "c\nb\r\na\r\n")
r = W:run("tail", "-r", "big.txt", { pipe = true })
check("tail -r of 3000 lines", ok0(r) and r.out:sub(1, 20) == "line 3000\nline 2999\n" and #r.out == #big)
r = W:run("tail", "-r", "-c", "3", "twelve.txt")
check("tail -r -c refused", r.status == 2 and r.err[1] == "tail: -r can't be used with -c")
r = W:run("tail", "-rf", "twelve.txt")
check("tail -r -f refused", r.status == 2 and r.err[1] == "tail: -r can't be used with -f")
r = W:run("tail", "-n", "3", "big.txt")
check("tail of 3000 lines", ok0(r) and r.out == big:sub(-30))

-- -f: each poll the sim appends to the file, then Ctrl+T stops it.
W:file("log.txt", "one\ntwo\n")
local polls = 0
r = W:run("tail", "-f", "-n", "1", "log.txt", { events = {}, onPull = function(w, filter)
    polls = polls + 1
    if polls == 1 then
        w.files["log.txt"] = w.files["log.txt"] .. "three\n"
    elseif polls == 2 then
        w.files["log.txt"] = w.files["log.txt"] .. "four\nfi"
    elseif polls == 4 then
        w.files["log.txt"] = "new\n"                   -- truncated
    end
    if polls == 3 then
        w.files["log.txt"] = w.files["log.txt"] .. "ve\n"
    end
    w.T.events[#w.T.events + 1] = polls < 5 and { "timer", polls } or { "terminate" }
    if filter ~= "timer" then error("tail waited for " .. tostring(filter)) end
end })
check("tail -f: follows appends and a truncation, Ctrl+T ends it with status 0",
    ok0(r) and r.out == "two\nthree\nfour\nfive\nnew\n" and polls == 5)
r = W:run("tail", "-f", "-n", "1", { stdin = "a\nb\n" })
check("tail -f on the keyboard does not follow", ok0(r) and r.out == "b\n")
r = W:run("tail", "-f", "nope", { pipe = true })
check("tail -f on a missing file: reported, no follow", r.status == 1 and r.out == "")
