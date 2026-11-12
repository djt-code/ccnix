-- sim/coreutils_small.lua
--
-- The small utilities in a shellworld: touch, pwd, basename, dirname,
-- true, false, sleep, which, xargs, seq, and sysctl (settings) --
-- their options, operands, output formats, diagnostics and exit statuses.
local PROJ = ...
package.path = PROJ .. "/lib/?.lua;" .. PROJ .. "/sim/lib/?.lua;" .. package.path
local M = require("mock")
local SW = require("shellworld")
local check = M.check
textutils = textutils or M.textutilsApi()      -- (lib/fileio, which touch uses, and sysctl)

local W = SW.new(PROJ)
local function show(s)
    return (tostring(s):gsub("[%c\128-\255]", function(c) return c == "\n" and "|" or "\\" .. c:byte() end))
end

--------------------------------------------------------------------------
-- true, false
--------------------------------------------------------------------------
local r = W:run("true", "-x", "anything")
check("true: status 0, ignores its arguments", r.ok and r.status == 0 and r.out == "" and #r.err == 0)
r = W:run("false", "--help")
check("false: status 1, silent", r.ok and r.status == 1 and r.out == "" and #r.err == 0, show(r.errText))
r = W:call(function(env)
    env.require("cu")
    W:install("true"); W:install("false")
    return { env.shell.run("true"), env.shell.run("false") }
end)
check("shell.run: true gives true, false gives false", r.value[1] == true and r.value[2] == false)

--------------------------------------------------------------------------
-- pwd
--------------------------------------------------------------------------
r = W:run("pwd")
check("pwd at the root: /", r.status == 0 and r.out == "/\n", show(r.out))
W:dir("a/b")
r = W:run("pwd", "-P", { cwd = "a/b" })
local r2 = W:run("pwd", "-L")
check("pwd in a/b: /a/b (-P and -L alike)", r.out == "/a/b\n" and r2.out == "/a/b\n", show(r.out))
W.shell.setDir("")
r = W:run("pwd", "x")
check("pwd with an operand: usage error 2", r.status == 2 and r.err[1] == "pwd: too many arguments"
    and r.err[2] == "usage: pwd [-L|-P]")
r = W:run("pwd", "-z")
check("pwd -z: illegal option", r.status == 2 and r.err[1] == "pwd: illegal option -- z")

--------------------------------------------------------------------------
-- basename, dirname (the POSIX examples and edge cases)
--------------------------------------------------------------------------
local function out1(prog, ...) local x = W:run(prog, ...); return x.out, x.status end
local cases = {
    { { "/usr/src/cmd/cat.c" }, "cat.c" }, { { "/usr/src/cmd/cat.c", ".c" }, "cat" },
    { { "cat.c", "cat.c" }, "cat.c" }, { { "a/b/" }, "b" }, { { "//" }, "/" }, { { "/" }, "/" },
    { { "" }, "" }, { { "abc" }, "abc" }, { { "a//b//" }, "b" }, { { "x.lua", "" }, "x.lua" },
    { { "--", "-x" }, "-x" }, { { "-" }, "-" },
}
local bad = {}
for _, c in ipairs(cases) do
    local o, st = out1("basename", table.unpack(c[1]))
    if o ~= c[2] .. "\n" or st ~= 0 then bad[#bad + 1] = table.concat(c[1], ",") .. "=" .. show(o) end
end
check("basename: strips slashes, directories and the suffix", #bad == 0, table.concat(bad, " "))
r = W:run("basename")
r2 = W:run("basename", "a", "b", "c")
check("basename: 0 or 3 operands is a usage error", r.status == 2 and r2.status == 2
    and r.err[2] == "usage: basename string [suffix]")

cases = {
    { "/usr/src/cmd/cat.c", "/usr/src/cmd" }, { "cat.c", "." }, { "a/b/", "a" }, { "/a", "/" },
    { "//", "/" }, { "/", "/" }, { "", "." }, { "a//b//", "a" }, { "/a//b", "/a" }, { "a/", "." },
    { "../x", ".." },
}
bad = {}
for _, c in ipairs(cases) do
    local o, st = out1("dirname", c[1])
    if o ~= c[2] .. "\n" or st ~= 0 then bad[#bad + 1] = c[1] .. "=" .. show(o) end
end
check("dirname: the POSIX steps", #bad == 0, table.concat(bad, " "))
r = W:run("dirname", "a", "b")
check("dirname with two operands: usage error 2", r.status == 2 and r.err[1] == "dirname: extra operand")

--------------------------------------------------------------------------
-- sleep
--------------------------------------------------------------------------
local t0 = W.clock
r = W:run("sleep", "2")
check("sleep 2 waits 2 seconds", r.status == 0 and r.out == "" and W.clock - t0 == 2, tostring(W.clock - t0))
t0 = W.clock
r = W:run("sleep", "0.5")
r2 = W:run("sleep", ".25")
check("sleep takes decimals", r.status == 0 and r2.status == 0 and math.abs(W.clock - t0 - 0.75) < 1e-9)
t0 = W.clock
r = W:run("sleep", "+1")
r2 = W:run("sleep", "1e0")
check("sleep takes a sign and an exponent, as GNU's", r.status == 0 and r2.status == 0 and W.clock - t0 == 2)
r = W:run("sleep", "abc")
check("sleep abc: invalid, status 2", r.status == 2 and r.err[1] == "sleep: invalid time interval 'abc'")
r = W:run("sleep", "-1")
r2 = W:run("sleep")
check("sleep -1 / no operand: usage errors", r.status == 2 and r.err[1] == "sleep: illegal option -- 1"
    and r2.status == 2 and r2.err[1] == "sleep: missing operand")

--------------------------------------------------------------------------
-- touch
--------------------------------------------------------------------------
r = W:run("touch", "new.txt", "a/b/also")
check("touch creates empty files", r.status == 0 and r.out == "" and W:read("new.txt") == ""
    and W:read("a/b/also") == "")
W:file("old.txt", "keep me\r\n\0bytes")
local m0 = W.mtime["old.txt"]
W:advance(60)
r = W:run("touch", "old.txt")
check("touch an existing file: same bytes, modified now", r.status == 0
    and W:read("old.txt") == "keep me\r\n\0bytes" and W.mtime["old.txt"] == m0 + 60000)
W:advance(60)
r = W:run("touch", "-m", "old.txt")
check("touch -m: modified now", W.mtime["old.txt"] == m0 + 120000)
W:advance(60)
r = W:run("touch", "-a", "old.txt")
check("touch -a alone: no access time in CraftOS, nothing changes", r.status == 0
    and W.mtime["old.txt"] == m0 + 120000)
r = W:run("touch", "-c", "ghost", "old.txt")
check("touch -c: a missing file stays missing, quietly", r.status == 0 and #r.err == 0
    and W:read("ghost") == nil and W.mtime["old.txt"] == m0 + 180000)
r = W:run("touch", "-ac", "ghost")
check("touch -ac grouped", r.status == 0 and W:read("ghost") == nil)
r = W:run("touch", "nodir/x", "fine")
check("touch in a missing directory: reported, status 1, the rest done", r.status == 1
    and r.err[1] == "touch: nodir/x: No such file or directory" and W:read("fine") == ""
    and not W.dirs["nodir"], show(r.errText))
r = W:run("touch", "old.txt/x")
check("touch under a file: Not a directory", r.status == 1 and r.err[1] == "touch: old.txt/x: Not a directory")
r = W:run("touch", "/rom/new")
check("touch in rom: Access denied", r.status == 1 and r.err[1] == "touch: /rom/new: Access denied", show(r.errText))
r = W:run("touch", "a")
check("touch a directory: left alone, status 0", r.status == 0 and W.dirs["a"])
W:advance(60)
local m1 = W.mtime["old.txt"]
r = W:run("touch", "-t", "202601021530.45", "old.txt", "dated")
check("touch -t: creates the missing file, leaves the existing one", r.status == 0
    and W:read("dated") == "" and W.mtime["old.txt"] == m1)
r = W:run("touch", "-d", "2026-01-02T15:30:00Z", "dated2")
r2 = W:run("touch", "-r", "old.txt", "dated3")
check("touch -d and -r: create", r.status == 0 and r2.status == 0 and W:read("dated2") == ""
    and W:read("dated3") == "")
r = W:run("touch", "-t", "1530", "x")
r2 = W:run("touch", "-d", "yesterday", "x")
check("touch -t / -d with a bad time: status 2, nothing created", r.status == 2 and r2.status == 2
    and r.err[1] == "touch: invalid date format '1530'" and W:read("x") == nil)
r = W:run("touch", "-r", "nope", "x")
check("touch -r missing reference: status 1", r.status == 1
    and r.err[1] == "touch: nope: No such file or directory" and W:read("x") == nil)
r = W:run("touch")
check("touch with no file: usage error", r.status == 2 and r.err[1] == "touch: missing file operand")
r = W:run("touch", "rel", { cwd = "a" })
W.shell.setDir("")
check("touch resolves against the shell's directory", W:read("a/rel") == "")

--------------------------------------------------------------------------
-- which
--------------------------------------------------------------------------
W:install("cat")
r = W:run("which", "cat", "edit")
check("which: absolute paths on the shell's path", r.status == 0
    and r.out == "/ccnix/bin/cat.lua\n/rom/programs/edit.lua\n", show(r.out))
r = W:run("which", "ls")
check("which follows an alias", r.out == "/rom/programs/list.lua\n", show(r.out))
W:file("cat.lua", "-- mine")
r = W:run("which", "-a", "cat")
check("which -a: every match in path order (. first)", r.status == 0
    and r.out == "/cat.lua\n/ccnix/bin/cat.lua\n", show(r.out))
W.files["cat.lua"] = nil
W:file("bin/tool.lua", "-- tool")
r = W:run("which", "bin/tool", "./bin/tool.lua")
check("which with a slash: relative to the directory", r.out == "/bin/tool.lua\n/bin/tool.lua\n", show(r.out))
r = W:run("which", "nosuch", "edit")
check("which unknown: reported, status 1, the rest still shown", r.status == 1
    and r.err[1] == "which: nosuch: not found" and r.out == "/rom/programs/edit.lua\n")
r = W:run("which")
check("which with no name: usage error", r.status == 2 and r.err[2] == "usage: which [-a] name...")

-- kill -l: the signal names, sorted (no init needed)
r = W:run("kill", "-l")
check("kill -l: the signal names, sorted", r.status == 0 and r.out == "CONT HUP INT KILL STOP TERM TSTP\n", show(r.out .. r.errText))

--------------------------------------------------------------------------
-- xargs
--------------------------------------------------------------------------
W:install("echo"); W:install("false"); W:install("true")
r = W:run("xargs", { pipe = true, stdin = "one two\n  three\n" })
check("xargs: echo by default, all arguments in one run", r.status == 0 and r.out == "one two three\n", show(r.out))
r = W:run("xargs", "echo", "x:", { stdin = "a b\nc\n" })
check("xargs from the keyboard (Ctrl+T ends)", r.status == 0 and r.out == "x: a b c\n", show(r.out))
r = W:run("xargs", "-n", "2", "echo", { pipe = true, stdin = "1 2 3\n4 5\n" })
check("xargs -n 2", r.out == "1 2\n3 4\n5\n", show(r.out))
r = W:run("xargs", "-n1", { pipe = true, stdin = [[a "b c" 'd "e"' f\ g h\'i]] .. "\n" })
check("xargs: quotes and backslashes", r.out == 'a\nb c\nd "e"\nf g\nh\'i\n', show(r.out))
r = W:run("xargs", "-I", "{}", "echo", "[{}]", "x{}y{}", { pipe = true, stdin = "  one two\n\nthree\n" })
check("xargs -I: one run per line, leading blanks dropped, every {} replaced",
    r.out == "[one two] xone twoyone two\n[three] xthreeythree\n", show(r.out))
r = W:run("xargs", "-I%", "echo", "%%", { pipe = true, stdin = "50\n" })
check("xargs -I with a pattern character, attached", r.out == "5050\n", show(r.out))
r = W:run("xargs", "-t", "echo", "hi", { pipe = true, stdin = "a\n" })
check("xargs -t traces to stderr", r.out == "hi a\n" and r.err[1] == "echo hi a", show(r.errText))
r = W:run("xargs", "echo", "empty", { pipe = true, stdin = "" })
r2 = W:run("xargs", "-r", "echo", "empty", { pipe = true, stdin = "\n" })
check("xargs: empty input runs once; -r not at all", r.out == "empty\n" and r2.out == "" and r2.status == 0)
r = W:run("xargs", "-E", "STOP", { pipe = true, stdin = "a b STOP c\nd\n" })
check("xargs -E: input ends at eofstr", r.out == "a b\n", show(r.out))
r = W:run("xargs", "-0", "-n1", { pipe = true, stdin = "a b\0c\nd\0e" })
check("xargs -0: NUL-separated, no quoting", r.out == "a b\nc\nd\ne\n", show(r.out))
r = W:run("xargs", "false", { pipe = true, stdin = "x\n" })
check("xargs: a failing run gives status 1", r.ok and r.status == 1, r.status)
r = W:run("xargs", "-n1", "nosuchprog", { pipe = true, stdin = "x\n" })
check("xargs: unknown utility gives 127", r.status == 127 and r.err[1] == "xargs: nosuchprog: No such program")
W:file("ccnix/bin/die.lua", "_G.POSIX_STATUS = 255; error('', 0)")
r = W:run("xargs", "-n1", "die", { pipe = true, stdin = "a b\n" })
check("xargs: a 255 status stops it", r.status == 1 and #r.err == 1
    and r.err[1] == "xargs: die: exited with status 255; aborting", show(r.errText))
W:file("ccnix/bin/tally.lua", "_G.TALLY = (_G.TALLY or 0) + 1")
_G.TALLY = 0
r = W:run("xargs", "-n", "1", "tally", { pipe = true, stdin = "a b c\n" })
check("xargs runs non-cu programs", r.status == 0 and _G.TALLY == 3)
r = W:run("xargs", { pipe = true, stdin = 'a "b\n' })
check("xargs: unmatched quote is an error", r.status == 1 and r.err[1] == "xargs: unmatched double quote"
    and r.out == "")
r = W:run("xargs", "-n", "0")
r2 = W:run("xargs", "-q")
check("xargs -n 0 / bad option: usage error 2", r.status == 2 and r.err[1] == "xargs: invalid number '0'"
    and r2.status == 2)
r = W:run("xargs", "-n", "1", "-I", "@", "echo", "<@>", { pipe = true, stdin = "a b\nc\n" })
check("xargs: -I after -n wins", r.out == "<a b>\n<c>\n", show(r.out))
r = W:sh("xargs -n 1 echo", { pipe = true, stdin = "p q\n" })
check("xargs through the shell", r.out == "p\nq\n", show(r.out))

--------------------------------------------------------------------------
-- review additions
--------------------------------------------------------------------------
r = W:run("touch", "-t", "202613011200", "x")
r2 = W:run("touch", "-t", "01021530.61", "x")
local r3 = W:run("touch", "-t", "01021530.60", "leap")
check("touch -t: month 13 and second 61 rejected, leap second 60 fine", r.status == 2 and r2.status == 2
    and W:read("x") == nil and r3.status == 0 and W:read("leap") == "")
r = W:run("touch", "-d", "2026-01-02T15:30:00junk", "x")
r2 = W:run("touch", "-d", "2026-01-02 15:30:00,25Z", "frac")
check("touch -d: trailing junk rejected, frac and Z accepted", r.status == 2 and W:read("x") == nil
    and r2.status == 0 and W:read("frac") == "")
r = W:run("touch", "old.txt/", "newdir/", "")
check("touch: file/ and missing/ and empty name fail", r.status == 1 and r.err[1] == "touch: old.txt/: Not a directory"
    and r.err[2] == "touch: newdir/: No such file or directory" and r.err[3] == "touch: : No such file or directory"
    and W:read("newdir") == nil, show(r.errText))
r = W:run("touch", "-c", "newdir/")
check("touch -c missing/: quiet", r.status == 0 and #r.err == 0)

W.shell.setAlias("zz", "nosuchthing")
r = W:run("which", "zz")
check("which: an alias to a missing program is not found (as the shell sees it)", r.status == 1
    and r.out == "" and r.err[1] == "which: zz: not found", show(r.out))
W.shell.setAlias("cat", "edit")
r = W:run("which", "cat")
r2 = W:run("which", "-a", "cat")
check("which: an alias shadows the path; -a lists both", r.out == "/rom/programs/edit.lua\n"
    and r2.out == "/rom/programs/edit.lua\n/ccnix/bin/cat.lua\n", show(r2.out))
W.shell.clearAlias("cat"); W.shell.clearAlias("zz")

r = W:run("xargs", "-L", "2", "echo", { pipe = true, stdin = "a b\n\nc \nd\ne\n" })
check("xargs -L 2: a line is an argument, a trailing blank continues it", r.status == 0
    and r.out == "a b cd\ne\n", show(r.out))
r = W:run("xargs", "-s", "11", "echo", { pipe = true, stdin = "aa bb cc dd\n" })
check("xargs -s 11: command lines kept short", r.out == "aa bb\ncc dd\n", show(r.out))
r = W:run("xargs", "-s", "5", "echo", { pipe = true, stdin = "aaaa\n" })
check("xargs -s too small: argument line too long, status 1", r.status == 1 and r.out == ""
    and r.err[1] == "xargs: argument line too long", show(r.errText))
r = W:run("xargs", "-x", "-n", "3", "-s", "11", "echo", { pipe = true, stdin = "aa bb cc\n" })
check("xargs -x: -n's arguments don't fit, stop", r.status == 1 and r.out == "", show(r.out))
r = W:run("xargs", "-s", "0")
check("xargs -s 0: usage error", r.status == 2 and r.err[1] == "xargs: bad -s 0")
r = W:run("xargs", "-p", "-n1", "echo", { stdin = "a b\ny\nn\n" })
check("xargs -p: y runs, anything else skips", r.status == 0 and r.out == "a\n"
    and r.errText == "echo a ?...echo b ?...", show(r.out) .. " / " .. show(r.errText))
-- (that the answers aren't read as input also shows a full -n run starts
-- without reading ahead)
r = W:run("xargs", "-n", "2", "echo", { stdin = "a b\nc d\n" })
check("xargs -n 2 from the keyboard: two runs", r.out == "a b\nc d\n", show(r.out))
W:file("ccnix/bin/crash.lua", "package.path = '/ccnix/lib/?.lua;' .. package.path; require('cu').init('crash'); error('boom')")
r = W:run("xargs", "crash", { pipe = true, stdin = "a\n" })
check("xargs: a cu program that crashes counts as a failure", r.ok and r.status == 1, r.status)
W:file("ccnix/bin/slow.lua", "sleep(3)")
r = W:run("xargs", "-n1", "slow", { pipe = true, stdin = "a b c\n" })
check("xargs yields during long runs", r.ok and r.status == 0 and #r.events == 0, tostring(r.error))
local long = string.rep("x", 20000)
r = W:run("xargs", "-n1", { pipe = true, stdin = long .. " '" .. long .. "' b\\ c\n" })
check("xargs: long arguments", r.out == long .. "\n" .. long .. "\nb c\n")
local many = {}
for i = 1, 3000 do many[i] = "w" .. i end
_G.TALLY = 0
r = W:run("xargs", "-0", "-n", "1000", "tally", { pipe = true, stdin = table.concat(many, "\0") .. "\0" })
check("xargs -0: 3000 arguments in runs of 1000", r.status == 0 and _G.TALLY == 3)
r = W:run("xargs", "-0", "echo", { pipe = true, stdin = "a\0\0b" })
check("xargs -0: empty argument kept, unterminated last one used", r.out == "a  b\n", show(r.out))

--------------------------------------------------------------------------
-- seq
--------------------------------------------------------------------------
local function seq(...) return W:run("seq", ...) end
local function lines(...) return (seq(...).out:gsub("\n", " ")) end
check("seq last; first last; first increment last", lines("3") == "1 2 3 " and lines("2", "4") == "2 3 4 "
    and lines("0", "5", "20") == "0 5 10 15 20 ", lines("0", "5", "20"))
check("counting down; negatives (not taken for options)", lines("5", "-2", "0") == "5 3 1 "
    and lines("-2", "0") == "-2 -1 0 " and lines("-1", "0.5", "1") == "-1.0 -0.5 0.0 0.5 1.0 ", lines("-1", "0.5", "1"))
check("decimals: first's or increment's places; 0.1 steps reach the end exactly",
    lines("0", "0.1", "0.3") == "0.0 0.1 0.2 0.3 " and lines("1.25", "3") == "1.25 2.25 "
        and lines("1e1", "1e1", "3e1") == "10 20 30 ", lines("0", "0.1", "0.3"))
r = seq("3", "1")
check("last before first: nothing, status 0", r.out == "" and r.status == 0)
check("-w: leading zeros (a minus first)", lines("-w", "8", "10") == "08 09 10 " and lines("-w", "-1", "1") == "-1 00 01 ",
    lines("-w", "-1", "1"))
check("-s: the separator, a newline at the end; \t is a tab",
    seq("-s", ", ", "3").out == "1, 2, 3\n" and seq("-s\t", "2").out == "1\t2\n", show(seq("-s\t", "2").out))
check("-s: C's escapes (a tab, octal, a backslash); a backslash before anything else kept",
    seq("-s", "\\t", "2").out == "1\t2\n" and seq("-s", "\\101", "2").out == "1A2\n"
    and seq("-s", "\\\\", "2").out == "1\\2\n" and seq("-s", "\\q", "2").out == "1\\q2\n", show(seq("-s", "\\101", "2").out))
check("-f: a printf floating-point format", lines("-f", "%.2f", "1", "0.5", "2") == "1.00 1.50 2.00 "
    and lines("-f", "%05.1f", "2") == "001.0 002.0 " and lines("-f", "n=%g%%", "2") == "n=1% n=2% ")
r = seq("x")
check("a bad number: status 1", r.status == 1 and r.err[1] == "seq: invalid floating point argument: 'x'", show(r.errText))
r = seq("1", "0", "3")
check("a zero increment: status 1", r.status == 1 and r.err[1] == "seq: invalid Zero increment value: '0'", show(r.errText))
r = seq("-f", "%d", "3")
local r2 = seq("-w", "-f", "%g", "3")
local r3 = seq()
check("-f without one float conversion, -f with -w, no operand: status 1",
    r.status == 1 and r.errText:find("exactly one") and r2.status == 1 and r3.status == 1
        and r3.err[1] == "seq: missing operand", show(r.errText) .. " " .. show(r3.errText))
r = seq("2500")
check("a long run (yielding as it goes)", select(2, r.out:gsub("\n", "")) == 2500 and r.out:sub(-5) == "2500\n")

--------------------------------------------------------------------------
-- rm, rmdir
--------------------------------------------------------------------------
local function tree()
    W:file("t/a.txt", "a") W:file("t/sub/b.txt", "b") W:dir("t/empty") W:file("t/c.txt", "c")
end
tree()
r = W:run("rm", "t/a.txt", "t/sub", "t/nope")
check("rm: a file goes; a directory without -r stays (is a directory); a missing one said; status 1",
    W:read("t/a.txt") == nil and W.fs.exists("t/sub/b.txt") and r.status == 1
        and r.err[1] == "rm: t/sub: is a directory" and r.err[2] == "rm: t/nope: No such file or directory",
    show(r.errText))
r = W:run("rm", "-d", "t/empty", "t/sub")
check("rm -d: an empty directory goes, a full one stays", not W.fs.exists("t/empty") and W.fs.exists("t/sub")
    and r.status == 1 and r.err[1] == "rm: t/sub: is a directory", show(r.errText))
r = W:run("rm", "-f", "t/nope", "t/c.txt")
check("rm -f: no word for a missing one, status 0", r.status == 0 and #r.err == 0 and W:read("t/c.txt") == nil)
r = W:run("rm", "-r", "t/sub")
check("rm -r: the directory and what's in it", r.status == 0 and not W.fs.exists("t/sub"))
tree()
r = W:run("rm", "-ri", "t", { stdin = "y\ny\nn\ny\ny\ny\ny\n" })
check("rm -i: asks before each (y removes); a directory something was kept in stays, unasked",
    W:read("t/a.txt") == nil and W:read("t/c.txt") == "c" and not W.fs.exists("t/sub") and not W.fs.exists("t/empty")
        and not r.errText:find("remove directory 't'", 1, true), show(r.errText))
r = W:run("rm", "-r", ".", "..", "/", "/rom/programs")
check("rm never removes . .. or /, nor what's read-only", r.status == 1 and #r.err == 4 and W.fs.exists("rom/programs"),
    show(r.errText))
r = W:run("rm")
local rf = W:run("rm", "-f")
check("rm alone: usage (status 2); rm -f alone: nothing, 0", r.status == 2 and rf.status == 0)
W.fs.delete("t")
W:file("p/q/r/f.txt", "x")
r = W:run("rmdir", "p/q/r")
check("rmdir: not empty is said, status 1", r.status == 1 and r.err[1] == "rmdir: p/q/r: Directory not empty", show(r.errText))
W.fs.delete("p/q/r/f.txt")
r = W:run("rmdir", "-p", "p/q/r/")
check("rmdir -p: the directory and the ones above it as they empty", r.status == 0 and not W.fs.exists("p"), show(r.errText))
W:dir("p/q/r")
r = W:run("rmdir", "-p", "p//q/r")
check("rmdir -p: a doubled slash doesn't stop it going up", r.status == 0 and not W.fs.exists("p"), show(r.errText))
W:file("x.txt", "x")
r = W:run("rmdir", "x.txt", "nope")
check("rmdir: a file, a missing one", r.status == 1 and r.err[1] == "rmdir: x.txt: Not a directory"
    and r.err[2] == "rmdir: nope: No such file or directory" and W:read("x.txt") == "x", show(r.errText))
r = W:run("mkdir", "m1", "m2/sub")
check("mkdir: one made; one whose parent isn't there isn't (status 1)", W.fs.isDir("m1") and not W.fs.exists("m2")
    and r.status == 1 and r.err[1] == "mkdir: m2/sub: No such file or directory", show(r.errText))
r = W:run("mkdir", "m1", "x.txt")
check("mkdir: one that's there already, a folder or a file: File exists", r.status == 1
    and r.err[1] == "mkdir: m1: File exists" and r.err[2] == "mkdir: x.txt: File exists", show(r.errText))
r = W:run("mkdir", "-p", "-m", "755", "m2/a/b", "m1")
check("mkdir -p: the parents too, and nothing said of one that's there (-m taken)", r.status == 0 and #r.err == 0
    and W.fs.isDir("m2/a/b") and not W.fs.exists("-p") and not W.fs.exists("755"), show(r.errText))
r = W:run("mkdir", "-p", "x.txt/in", "/rom/new")
check("mkdir -p: a file on the way, a read-only place", r.status == 1 and r.err[1] == "mkdir: x.txt/in: Not a directory"
    and r.err[2] == "mkdir: /rom/new: Permission denied" and not W.fs.exists("rom/new"), show(r.errText))
W.fs.delete("m1") W.fs.delete("m2")
W:file("deep/a/b/c.txt", "c") W:file("deep/d.txt", "d")
r = W:run("rm", "-rf", "/deep", "/not-there")
check("rm -rf /dir: the directory and everything in it, no questions, nothing said of what's missing",
    r.status == 0 and #r.err == 0 and not W.fs.exists("deep"), show(r.errText))


--------------------------------------------------------------------------
-- sysctl (settings, as CC:T's API keeps them: getDetails' value falls
-- back to the default, changed says it's set; type and description from
-- settings.define)
--------------------------------------------------------------------------
local DEFS = { ["motd.enable"] = { default = false, type = "boolean", description = "Show a message of the day." },
               ["shell.allow_disk_startup"] = { default = true, type = "boolean" },
               ["host.name"] = { type = "string" } }
local VALS, saved = { ["motd.enable"] = true, ["my.list"] = { 1, 2 } }, 0
settings = {
    get = function(k) local v = VALS[k]; if v == nil then return DEFS[k] and DEFS[k].default end return v end,
    set = function(k, v) VALS[k] = v end,
    unset = function(k) VALS[k] = nil end,
    save = function() saved = saved + 1 end,
    getNames = function()
        local n, seen = {}, {}
        for k in pairs(DEFS) do n[#n + 1] = k; seen[k] = true end
        for k in pairs(VALS) do if not seen[k] then n[#n + 1] = k end end
        return n
    end,
    getDetails = function(k)
        local d, v = DEFS[k] or {}, VALS[k]
        return { default = d.default, type = d.type, description = d.description,
                 value = v == nil and d.default or v, changed = v ~= nil }
    end,
}
r = W:run("sysctl", "-a")
check("sysctl -a: every setting there is, set or defined, sorted, name = value (a table on one line)", r.status == 0
    and r.out:sub(1, 43) == "host.name = \nmotd.enable = true\nmy.list = {"
    and r.out:sub(-34) == "}\nshell.allow_disk_startup = true\n" and select(2, r.out:gsub("\n", "")) == 4, show(r.out))
r = W:run("sysctl", "-n", "shell.allow_disk_startup", "nope", "motd.enable")
check("sysctl -n: the values alone; an unknown key an error (status 1), the rest still shown", r.status == 1
    and r.out == "true\ntrue\n" and r.err[1] == "sysctl: nope: unknown key", show(r.out) .. show(r.errText))
r = W:run("sysctl", "-d", "motd.enable")
check("sysctl -d: the description", r.status == 0 and r.out == "motd.enable: Show a message of the day.\n", show(r.out))
r = W:run("sysctl", "motd.enable=false", "my.count=12", "host.name=42", "my.word=hello there")
check("sysctl name=value: as each one's type has it (a string-typed one keeps 42 as text), new ones guessed; shown; saved once",
    r.status == 0 and VALS["motd.enable"] == false and VALS["my.count"] == 12 and VALS["host.name"] == "42"
    and VALS["my.word"] == "hello there" and saved == 1
    and r.out == "motd.enable = false\nmy.count = 12\nhost.name = 42\nmy.word = hello there\n", show(r.out))
r = W:run("sysctl", "motd.enable=yes")
check("a value of the wrong type: refused, status 1, nothing saved", r.status == 1 and VALS["motd.enable"] == false
    and saved == 1 and r.err[1] == "sysctl: motd.enable is a boolean: not yes", show(r.errText))
VALS["my.switch"] = true
r = W:run("sysctl", "my.switch=yes", "my.count=lots", "my.word=42")
check("an undefined setting holding true/false or a number keeps that kind (text stays free): refused, status 1",
    r.status == 1 and VALS["my.switch"] == true and VALS["my.count"] == 12 and VALS["my.word"] == 42
    and r.err[1] == "sysctl: my.switch is a boolean: not yes" and r.err[2] == "sysctl: my.count is a number: not lots",
    show(r.errText))
VALS["my.switch"], VALS["my.word"], saved = nil, "hello there", 1
r = W:run("sysctl", "motd.enable=", "my.list=")
check("sysctl name=: back to the default, or not set with none; saved", r.status == 0 and VALS["motd.enable"] == nil
    and VALS["my.list"] == nil and saved == 2 and r.out == "motd.enable = false (its default)\nmy.list: not set\n", show(r.out))
r = W:run("sysctl")
local r2 = W:run("sysctl", "-a", "motd.enable")
check("sysctl with nothing, or -a and a name: usage, status 2", r.status == 2 and r2.status == 2
    and r.err[#r.err] == "usage: sysctl [-n | -d] -a | name[=value]...", show(r.errText))
settings = nil
