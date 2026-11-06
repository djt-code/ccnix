-- sim/coreutils_cu.lua
--
-- cu.lua, the utilities' shared core: getopt as the POSIX Utility Syntax
-- Guidelines have it, reading lines from files, the keyboard and a pipe,
-- exit statuses; then cat, more and echo run in a shellworld.
local PROJ = ...
package.path = PROJ .. "/lib/?.lua;" .. PROJ .. "/sim/lib/?.lua;" .. package.path
local M = require("mock")
local SW = require("shellworld")
local check = M.check

local W = SW.new(PROJ)
local function show(s)
    return (tostring(s):gsub("[%c\128-\255]", function(c) return c == "\n" and "|" or "\\" .. c:byte() end))
end
local function same(a, b)
    if #a ~= #b then return false end
    for i = 1, #a do if a[i] ~= b[i] then return false end end
    return true
end

-- getopt on these arguments with this spec, inside the world
local function getopt(spec, args, status)
    return W:call(function(env)
        local cu = env.require("cu").init("t", "t [-abc] [-n num] [file...]")
        local o, ops, order = cu.getopt(args, spec, status)
        return { o = o, ops = ops, order = order }
    end)
end

--------------------------------------------------------------------------
-- 1. getopt
--------------------------------------------------------------------------
local r = getopt("abc", { "-abc", "x" })
check("grouped flags -abc", r.value.o.a == true and r.value.o.b == true and r.value.o.c == true
    and same(r.value.ops, { "x" }))
r = getopt("an:", { "-n5", "f" })
check("option-argument attached: -n5", r.value.o.n == "5" and same(r.value.ops, { "f" }))
r = getopt("an:", { "-n", "5", "f" })
check("option-argument separate: -n 5", r.value.o.n == "5" and same(r.value.ops, { "f" }))
r = getopt("an:", { "-an5" })
local r2 = getopt("an:", { "-an", "-5" })
check("in a group, the rest is the argument: -an5, -an -5", r.value.o.a and r.value.o.n == "5"
    and r2.value.o.a and r2.value.o.n == "-5" and #r2.value.ops == 0)
r = getopt("ab", { "-a", "--", "-b" })
check("-- ends the options", r.value.o.a and not r.value.o.b and same(r.value.ops, { "-b" }))
r = getopt("ab", { "-a", "-", "-b" })
check("- is an operand, and the options end there", r.value.o.a and not r.value.o.b
    and same(r.value.ops, { "-", "-b" }))
r = getopt("ab", { "x", "-a", "--" })
check("nothing after the first operand is an option", not r.value.o.a and same(r.value.ops, { "x", "-a", "--" }))
r = getopt("e:v", { "-e", "one", "-v", "-etwo" })
check("repeated option: last wins, all kept in order", r.value.o.e == "two" and #r.value.order == 3
    and r.value.order[1][2] == "one" and r.value.order[2][1] == "v" and r.value.order[3][2] == "two")
r = getopt("ab", { "-az" })
check("unknown option: status 2, message and usage", r.ok and r.status == 2
    and r.err[1] == "t: illegal option -- z" and r.err[2] == "usage: t [-abc] [-n num] [file...]", show(r.errText))
r = getopt("an:", { "-a", "-n" })
check("missing option-argument: status 2", r.status == 2 and r.err[1] == "t: option requires an argument -- n")
r = getopt("a", { "-q" }, 1)
check("the caller can choose the usage status", r.status == 1)
r = W:call(function(env)
    local cu = env.require("cu")
    return { cu.int("12"), cu.int("-3"), cu.int("+4"), cu.int("1.5"), cu.int("x"), cu.int("") }
end)
check("cu.int: whole numbers only", r.value[1] == 12 and r.value[2] == -3 and r.value[3] == 4
    and r.value[4] == nil and r.value[5] == nil and r.value[6] == nil)

--------------------------------------------------------------------------
-- 2. reading lines
--------------------------------------------------------------------------
W:file("one.txt", "a1\na2\n")
W:file("two.txt", "b1\r\nb2")          -- CRLF, no newline at the end
W:dir("sub")
local function lines(ops, keep, opts)
    return W:call(function(env)
        local cu = env.require("cu").init("t")
        local got = {}
        for l, name in cu.lines(ops, keep) do got[#got + 1] = name .. ":" .. l end
        cu.exit()
        return got
    end, opts)
end
r = lines({ "one.txt", "two.txt" })
check("lines of files in turn, CR of CRLF dropped", r.status == 0
    and same(r.value or {}, { "one.txt:a1", "one.txt:a2", "two.txt:b1", "two.txt:b2" }), show(table.concat(r.value or {}, ",")))
r = lines({ "two.txt" }, true)
check("keep: newlines kept byte for byte", same(r.value or {}, { "two.txt:b1\r\n", "two.txt:b2" }))
r = lines({ "one.txt", "nope", "sub", "two.txt" })
check("missing file and directory reported, the rest still read, status 1", r.status == 1 and r.ok
    and r.err[1] == "t: nope: No such file or directory" and r.err[2] == "t: sub: Is a directory"
    and r.tty == "" and r.events and #r.err == 2)
r = lines({}, false, { stdin = "k1\nk2\n" })
check("no operands: the keyboard, Ctrl+T ends it", r.ok and r.status == 0
    and same(r.value or {}, { "-:k1", "-:k2" }), r.error)
r = lines({ "one.txt", "-", "-" }, true, { stdin = "k1\n" })
check("- among files; the keyboard stays ended", same(r.value or {}, { "one.txt:a1\n", "one.txt:a2\n", "-:k1\n" }))
r = lines({ "-" }, false, { stdin = "p1\np2", pipeIn = true })
check("a pipe on io.input() reads to its end", r.ok and same(r.value or {}, { "-:p1", "-:p2" }))
r = W:call(function(env)
    local cu = env.require("cu").init("t")
    return { cu.readAll(env.io.input()), env.io.read("a") }
end, { stdin = "x\ny\n" })
check("readAll of the keyboard (io.read('a') there is nil, as in CraftOS)", r.value[1] == "x\ny\n" and r.value[2] == nil)
r = W:call(function(env)
    local it, e = env.io.stdin:lines()
    local ok, msg = pcall(env.io.read, "L")
    return { it, e, ok, msg }
end, { stdin = "x\n" })
check("CraftOS quirks kept: io.stdin:lines() is nil, io.read('L') errors",
    r.value[1] == nil and r.value[2] == "file is not readable" and r.value[3] == false, show(r.value[4]))
r = W:call(function(env) for _ in env.io.lines() do end end, { stdin = "x\n" })
check("so io.lines() on the keyboard fails", not r.ok)
r = W:call(function(env) while true do env.io.read() end end, { stdin = "x\n" })
check("reading the keyboard without cu: Ctrl+T stops the program", not r.ok and r.error == "Terminated")

--------------------------------------------------------------------------
-- 3. exit statuses
--------------------------------------------------------------------------
r = W:call(function(env) local cu = env.require("cu").init("t"); cu.exit(3); return "not here" end)
check("cu.exit(3): status 3, nothing printed, not an error", r.ok and r.status == 3 and #r.err == 0 and r.value == nil)
r = W:call(function(env) local cu = env.require("cu").init("t"); cu.exit(0); return "here" end)
check("cu.exit(0) returns", r.ok and r.status == 0 and r.value == "here")
r = W:call(function(env) local cu = env.require("cu").init("t"); cu.fail("x"); cu.fail("y"); cu.exit() end)
check("cu.fail remembers status 1; cu.exit() uses it", r.status == 1 and same(r.err, { "t: x", "t: y" }))
r = W:call(function(env) env.require("cu").init("t"); error("boom", 0) end)
check("a real error: not ok, status 1, the message on stderr", not r.ok and r.status == 1 and r.err[1] == "boom")
r = W:call(function(env) local cu = env.require("cu"); return { cu.isTerminal(), cu.isKeyboard() } end)
local r3 = W:call(function(env) local cu = env.require("cu"); return { cu.isTerminal(), cu.isKeyboard() } end, { pipe = true })
check("isTerminal / isKeyboard: the screen and keyboard unless piped",
    r.value[1] == true and r.value[2] == true and r3.value[1] == false and r3.value[2] == false)

--------------------------------------------------------------------------
-- 4. cat
--------------------------------------------------------------------------
W:file("bin.dat", "x\0y\r\n\255z")
r = W:run("cat", "one.txt", "two.txt", "bin.dat")
check("cat: files byte for byte", r.ok and r.status == 0 and r.out == "a1\na2\nb1\r\nb2x\0y\r\n\255z", show(r.out))
r = W:run("cat", { stdin = "typed\nlines\n" })
check("cat: no files reads the keyboard", r.status == 0 and r.out == "typed\nlines\n", show(r.out))
r = W:run("cat", "one.txt", "-", "two.txt", { stdin = "mid\n" })
check("cat: - in the middle", r.out == "a1\na2\nmid\nb1\r\nb2", show(r.out))
r = W:run("cat", "-u", "-", { stdin = "p\nq", pipe = true })
check("cat -u from a pipe, to a pipe", r.status == 0 and r.out == "p\nq" and r.tty == "", show(r.out))
r = W:run("cat", "nope", "one.txt", "sub")
check("cat: missing file and directory reported, status 1", r.status == 1 and r.out == "a1\na2\n"
    and same(r.err, { "cat: nope: No such file or directory", "cat: sub: Is a directory" }), show(r.errText))
r = W:run("cat", "-x", "one.txt")
check("cat -x: usage error, status 2, no output", r.status == 2 and r.out == ""
    and same(r.err, { "cat: illegal option -- x", "usage: cat [-u] [file...]" }), show(r.errText))
W:file("sub/in.txt", "inside\n")
r = W:run("cat", "in.txt", "/one.txt", { cwd = "sub" })
check("cat: paths relative to the shell's directory", r.out == "inside\na1\na2\n", show(r.out))
W.shell.setDir("")

--------------------------------------------------------------------------
-- 5. more (the pager itself: sim/pager.lua)
--------------------------------------------------------------------------
W:file("blank.txt", "\n\na\n\n\n\nb\n\n")
r = W:run("more", "-s", "blank.txt", { pipeOut = true })
check("more -s squeezes blank lines (piped: like cat)", r.out == "\na\n\nb\n\n", show(r.out))
r = W:run("more", { stdin = "x\ny", pipe = true })
check("more from a pipe to a pipe", r.out == "x\ny" and r.status == 0)
r = W:run("more", "one.txt", { stdin = "" })
check("more on the screen: a short file just printed", r.out == "a1\na2\n" and #r.events == 0)
r = W:run("more", "-e", "one.txt")
check("more -e: not supported, status 2", r.status == 2 and r.err[1] == "more: illegal option -- e")

--------------------------------------------------------------------------
-- 6. echo
--------------------------------------------------------------------------
r = W:run("echo", "hello", "there")
check("echo: words and a newline", r.status == 0 and r.out == "hello there\n", show(r.out))
r = W:run("echo")
check("echo: no words, just the newline", r.out == "\n")
r = W:run("echo", "-n", "--", "x")
check("echo: no options, -n and -- printed", r.out == "-n -- x\n", show(r.out))
r = W:run("echo", "a\\tb\\nc\\\\d\\0101\\q")
check("echo: XSI escapes; unknown ones kept", r.out == "a\tb\nc\\dA\\q\n", show(r.out))
r = W:run("echo", "stop\\chere")
check("echo: \\c ends the output, newline included", r.out == "stop", show(r.out))
r = W:run("echo", "x", "y", ">", "f.txt")
local r4 = W:run("echo", "z", ">>f.txt")
check("echo > and >> write and append the file", r.out == "" and r4.out == "" and W:read("f.txt") == "x y\nz\n",
    show(W:read("f.txt")))
r = W:run("echo", "new", ">", "../f.txt", { cwd = "sub" })
check("echo >: relative to the shell's directory, replaces", W:read("f.txt") == "new\n", show(W:read("f.txt")))
W.shell.setDir("")
r = W:run("echo", "x", ">", "sub")
check("echo > a directory: status 1", r.status == 1 and r.err[1] == "echo: sub: Is a directory")
r = W:run("echo", "x", ">")
check("echo > with no file: usage error, status 2", r.status == 2 and r.err[1] == "echo: > needs a file name")
r = W:run("echo", "piped", { pipeOut = true })
check("echo to a pipe", r.out == "piped\n" and r.tty == "")
r = W:sh('echo "a  b" c')
check("through the shell: double quotes make one word", r.out == "a  b c\n", show(r.out))
r = W:sh("ls")
check("shell: ls is the rom's list (stub), aliases and path work", r.ok and r.err[1] == nil
    and W.shell.resolveProgram("ls") == "rom/programs/list.lua" and W.shell.resolveProgram("echo") == "ccnix/bin/echo.lua")

-- the fixtures themselves: shell.run's words, and io's read formats
local function words(...) return table.concat(SW.tokenise(...), "|") end
check("shell words: blanks split, quotes keep spaces, an empty pair is a word, an open quote runs to the end",
    words("a  b\tc") == "a|b|c" and words('x "y  z" w') == "x|y  z|w" and words('p ""') == "p|"
        and words('a"b c"d') == "a|b c|d" and words('q "open end') == "q|open end" and words("") == "",
    words('x "y  z" w') .. " / " .. words('a"b c"d') .. " / " .. words('q "open end'))
check("shell words: shell.run's arguments are joined with spaces first", words("cat", '"a', 'b"') == "cat|a b")
W:file("lines.txt", "one\ntwo\nthree")
r = W:call(function(env)
    local f = env.io.open("lines.txt")
    local a, b = f:read("l", "*L")
    local c, d = f:read(2, "a")
    local e, g = f:read("a", "l")
    f:close()
    local ok, msg = pcall(f.read, f)
    local h = env.io.open("lines.txt")
    local bad = { pcall(h.read, h, "x") }
    local none = { h:read("n", "l") }
    h:close()
    local got = {}
    for l in env.io.lines("lines.txt") do got[#got + 1] = l end
    return { a, b, c, d, e, g, ok, msg, bad[2], none[1], none[2], table.concat(got, ",") }
end)
local v = r.value or {}
check("io read: l, *L, a count, a; \"\" at the end and nil after; closed; a bad format; n is nil; io.lines",
    v[1] == "one" and v[2] == "two\n" and v[3] == "th" and v[4] == "ree" and v[5] == "" and v[6] == nil
        and v[7] == false and tostring(v[8]):find("closed file") and tostring(v[9]):find("invalid format")
        and v[10] == nil and v[11] == nil and v[12] == "one,two,three",
    show(v[3]) .. " " .. show(v[4]) .. " " .. tostring(v[8]) .. " " .. tostring(v[9]) .. " " .. tostring(v[12]))
