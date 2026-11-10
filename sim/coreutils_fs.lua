-- sim/coreutils_fs.lua
--
-- df, du and find in a shellworld: their options, the POSIX output
-- formats, missing operands (a message and status 1) and bad usage.
local PROJ = ...
package.path = PROJ .. "/lib/?.lua;" .. PROJ .. "/sim/lib/?.lua;" .. package.path
local M = require("mock")
local SW = require("shellworld")
local check = M.check

local function show(s)
    return (tostring(s):gsub("[%c\128-\255]", function(c) return c == "\n" and "|" or "\\" .. c:byte() end))
end

local W = SW.new(PROJ)
W:file("a/one.txt", ("x"):rep(600))       -- 2 blocks of 512, 1 of 1024
W:file("a/two.lua", "print(2)\n")         -- 1 block
W:file("a/b/three.lua", ("y"):rep(1100))  -- 3 blocks of 512, 2 of 1024
W:file("a/b/.hidden", "")                 -- 0 blocks
W:dir("a/empty")
W:file("[x].txt", "brackets")

--------------------------------------------------------------------------
-- df
--------------------------------------------------------------------------
local r = W:run("df", "-P")
-- the figures the world reports, once df and cu are installed
local free, cap = W.fs.getFreeSpace(""), W.fs.getCapacity("")
local romBytes = 0
for k, v in pairs(W.files) do if k:sub(1, 4) == "rom/" then romBytes = romBytes + #v end end
local function line(unit, name, total, used, avail, mount)
    local u, a = math.ceil(used / unit), math.floor(avail / unit)
    return name .. " " .. math.ceil(total / unit) .. " " .. u .. " " .. a .. " "
        .. math.ceil(u * 100 / (u + a)) .. "% " .. mount
end
local want = "Filesystem 512-blocks Used Available Capacity Mounted on\n"
    .. line(512, "hdd", cap, cap - free, free, "/") .. "\n"
    .. line(512, "rom", romBytes, romBytes, 0, "/rom") .. "\n"
check("df -P: POSIX header, root and rom", r.ok and r.status == 0 and r.out == want, show(r.out))
r = W:run("df", "-kP")
check("df -kP: 1024-blocks", r.out:match("^Filesystem 1024%-blocks Used Available Capacity Mounted on\n")
    and r.out:find(line(1024, "hdd", cap, cap - free, free, "/"), 1, true), show(r.out))
r = W:run("df", "-P", "a/one.txt", "/rom/programs")
check("df file operands: the drive each is on", r.out == "Filesystem 512-blocks Used Available Capacity Mounted on\n"
    .. line(512, "hdd", cap, cap - free, free, "/") .. "\n"
    .. line(512, "rom", romBytes, romBytes, 0, "/rom") .. "\n", show(r.out))
r = W:run("df")
local widest = 0
for l in r.out:gmatch("[^\n]+") do widest = math.max(widest, #l) end
check("df: aligned columns that fit 39 wide", r.out:match("^Drive +512%-blk +Used +Avail +Use%% Mount\n")
    and r.out:find("\nhdd ", 1, true) and r.out:find(" /rom\n", 1, true) and widest <= 39, show(r.out))
r = W:run("df", "-k")
widest = 0
for l in r.out:gmatch("[^\n]+") do widest = math.max(widest, #l) end
check("df -k still fits 39 wide", widest <= 39 and r.out:find("1024-blk", 1, true), show(r.out))
check("df: no line ends in a blank", not r.out:find(" \n", 1, true), show(r.out))
r = W:run("df", "-P", "nope", "a")
check("df missing file: message, status 1, the rest still listed", r.status == 1
    and r.err[1] == "df: nope: No such file or directory" and select(2, r.out:gsub("\n", "")) == 2, show(r.errText))
r = W:run("df", "-z")
check("df bad option: status 2 and usage", r.status == 2 and r.err[1] == "df: illegal option -- z"
    and r.err[2] == "usage: df [-k] [-P] [file...]")
r = W:run("df", "-P", "a", { pipe = true })
check("df writes to io.output (a pipe)", r.out:match("^Filesystem") and r.tty == "", show(r.tty))

--------------------------------------------------------------------------
-- du
--------------------------------------------------------------------------
r = W:run("du", "a")
check("du: directories after their contents, 512-blocks", r.status == 0
    and r.out == "3 a/b\n0 a/empty\n6 a\n", show(r.out))
r = W:run("du", "-a", "a")
check("du -a: files too", r.out == "0 a/b/.hidden\n3 a/b/three.lua\n3 a/b\n0 a/empty\n2 a/one.txt\n1 a/two.lua\n6 a\n",
    show(r.out))
r = W:run("du", "-sk", "a", "a/one.txt")
check("du -sk: one total per operand, 1024-blocks, file operand", r.out == "4 a\n1 a/one.txt\n", show(r.out))
r = W:run("du", "a/two.lua")
check("du on a file lists it", r.out == "1 a/two.lua\n", show(r.out))
r = W:run("du", { cwd = "a" })
W.shell.setDir("")
check("du with no operand is du .", r.out == "3 ./b\n0 ./empty\n6 .\n", show(r.out))
r = W:run("du", "-s", "/")
local r2 = W:run("du", "-sx", "/")
check("du -x stays off /rom", r.status == 0 and r2.status == 0
    and tonumber(r.out:match("^%d+")) > tonumber(r2.out:match("^%d+")) and r2.out:match(" /\n$"), show(r.out .. r2.out))
r = W:run("du", "-s", "nope", "a")
check("du missing file: message, status 1, carries on", r.status == 1
    and r.err[1] == "du: nope: No such file or directory" and r.out == "6 a\n", show(r.errText))
r = W:run("du", "-as", "a")
check("du -a with -s: usage error", r.status == 2 and r.err[2] == "usage: du [-a|-s] [-kx] [-H|-L] [file...]",
    show(r.errText))

--------------------------------------------------------------------------
-- find
--------------------------------------------------------------------------
r = W:run("find", "a")
check("find: every entry, parents first, prints by default", r.status == 0 and r.out ==
    "a\na/b\na/b/.hidden\na/b/three.lua\na/empty\na/one.txt\na/two.lua\n", show(r.out))
r = W:run("find", "a", "-name", "*.lua")
check("find -name glob", r.out == "a/b/three.lua\na/two.lua\n", show(r.out))
r = W:run("find", "a", "-name", "*")
check("-name *: a leading dot is not special", r.out:find("a/b/.hidden\n", 1, true) ~= nil)
r = W:run("find", "a", "-name", "t??.*")
local r3 = W:run("find", "a", "-name", "[!t]*", "-type", "f")
local r4 = W:run("find", ".", "-name", "\\[x].txt")
local r5 = W:run("find", "a", "-name", "[[:lower:]]n[a-f]*")
check("-name ? [!...] \\ quoting and [[:class:]]", r.out == "a/two.lua\n" and r3.out == "a/b/.hidden\na/one.txt\n"
    and r4.out == "./[x].txt\n" and r5.out == "a/one.txt\n", show(r.out .. "~" .. r3.out .. "~" .. r4.out .. "~" .. r5.out))
W:file("p/+.txt", ""); W:file("p/-.txt", ""); W:file("p/x.txt", "")
r = W:run("find", "p", "-name", "[*-/]*")
r2 = W:run("find", "p", "-name", "[z-a]*")
r3 = W:run("find", "--", "p", "-name", "[!-.]*")
check("-name ranges over punctuation, an empty range, -- before the paths",
    r.out == "p/+.txt\np/-.txt\n" and r2.status == 0 and r2.out == "" and r3.out == "p\np/+.txt\np/x.txt\n",
    show(r.out .. "~" .. r2.errText .. "~" .. r3.out .. r3.errText))
W:dir("big")
for n = 1, 450 do W.files["big/f" .. n] = "z" end
-- (cu.breathe yields once a second at most: here the clock runs a second
-- each time it's read)
local realClock, tick, pulls, pulls2 = W.os.clock, 0, 0, 0
W.os.clock = function() tick = tick + 1; return tick end
r = W:run("find", "big", "-name", "f450", { onPull = function() pulls = pulls + 1 end })
r2 = W:run("du", "-s", "big", { onPull = function() pulls2 = pulls2 + 1 end })
W.os.clock = realClock
check("a big tree: find and du yield as they go", r.out == "big/f450\n" and r2.out == "450 big\n"
    and pulls > 100 and pulls2 > 100, show(r.out .. r2.out .. pulls .. " " .. pulls2))
W.fs.delete("big")
r = W:run("find", "a", "-maxdepth", "-1")
check("-maxdepth -1: bad number", r.status == 1 and r.err[1] == "find: -maxdepth: bad number -- -1", show(r.errText))
r = W:run("find", "a", "-path", "a/*.lua")
check("-path: * crosses /", r.out == "a/b/three.lua\na/two.lua\n", show(r.out))
r = W:run("find", "a", "-type", "d")
r2 = W:run("find", "a", "-type", "f")
check("-type d / f", r.out == "a\na/b\na/empty\n" and r2.out == "a/b/.hidden\na/b/three.lua\na/one.txt\na/two.lua\n")
r = W:run("find", "a", "-type", "f", "-size", "+1")
r2 = W:run("find", "a", "-type", "f", "-size", "-1")
r3 = W:run("find", "a", "-size", "9c")
check("-size +n -n and c (bytes)", r.out == "a/b/three.lua\na/one.txt\n" and r2.out == "a/b/.hidden\n"
    and r3.out == "a/two.lua\n", show(r.out .. "~" .. r2.out .. "~" .. r3.out))
r = W:run("find", "a", "!", "-type", "d", "-a", "(", "-name", "o*", "-o", "-name", "t*", ")")
check("! ( ) -a -o", r.out == "a/b/three.lua\na/one.txt\na/two.lua\n", show(r.out))
r = W:run("find", "a", "-name", "b", "-prune", "-o", "-print")
check("-prune -o -print skips a directory", r.out == "a\na/empty\na/one.txt\na/two.lua\n", show(r.out))
r = W:run("find", "a", "-depth", "-type", "d")
check("-depth: contents before the directory", r.out == "a/b\na/empty\na\n", show(r.out))
r = W:run("find", "a", "-maxdepth", "1")
r2 = W:run("find", "a", "-mindepth", "2")
check("-maxdepth / -mindepth", r.out == "a\na/b\na/empty\na/one.txt\na/two.lua\n"
    and r2.out == "a/b/.hidden\na/b/three.lua\n", show(r.out .. "~" .. r2.out))
r = W:run("find", "/", "-xdev", "-name", "list.lua")
r2 = W:run("find", "/", "-name", "list.lua")
r3 = W:run("find", "/", "-xdev", "-name", "rom")
check("-xdev tests /rom but stays out of it", r.out == "" and r2.out == "/rom/programs/list.lua\n"
    and r3.out == "/rom\n", show(r.out .. "~" .. r2.out .. "~" .. r3.out))
r = W:run("find", "-name", "two.lua")
check("no path: searches .", r.out == "./a/two.lua\n", show(r.out))
r = W:run("find", "a/one.txt", "a/two.lua", "-print0")
check("-print0", r.out == "a/one.txt\0a/two.lua\0", show(r.out))
-- time: a/new.txt written a day and a half after everything else
W:advance(86400 * 3 / 2)
W:file("a/new.txt", "n")
r = W:run("find", "a", "-type", "f", "-newer", "a/one.txt")
r2 = W:run("find", "a", "-type", "f", "-mtime", "+0")
r3 = W:run("find", "a", "-newer", "nope")
check("-newer and -mtime", r.out == "a/new.txt\n" and r2.out == "a/b/.hidden\na/b/three.lua\na/one.txt\na/two.lua\n"
    and r3.status == 1 and r3.err[1] == "find: nope: No such file or directory" and r3.out == "",
    show(r.out .. "~" .. r2.out .. "~" .. r3.errText))
W.files["a/new.txt"] = nil
W:install("echo")
W:install("cat")
r = W:run("find", "a/b", "-type", "f", "-exec", "echo", "found", "{}", ";")
check("-exec cmd {} ; runs it for each match, no default print", r.status == 0
    and r.out == "found a/b/.hidden\nfound a/b/three.lua\n", show(r.out))
r = W:run("find", "a", "-maxdepth", "1", "-exec", "cat", "{}", "\\;", "-name", "t*", "-print")
check("-exec is true only when the command succeeds (\\; ends it too)", r.out == ("x"):rep(600) .. "print(2)\na/two.lua\n"
    and r.err[1] == "cat: a: Is a directory", show(r.out .. "~" .. r.errText))
r = W:run("find", "a", "-name", "*.lua", "-exec", "echo", "{}", "+")
check("-exec ... {} +: once with every path", r.out == "a/b/three.lua a/two.lua\n", show(r.out))
r = W:run("find", "a", "-name", "*.lua", "-ok", "echo", "yes", "{}", ";", { stdin = "y\nn\n" })
check("-ok asks on stderr and runs on y", r.out == "yes a/b/three.lua\n"
    and r.errText == "< echo yes a/b/three.lua > ? < echo yes a/two.lua > ? ", show(r.out .. "~" .. r.errText))
r = W:run("find", "a", "-name", "*.lua", "-ok", "echo", "{}", ";", { stdin = "n\nyes\n", pipeIn = true })
check("-ok reads its answers from the input", r.out == "a/two.lua\n", show(r.out .. "~" .. r.errText))
r = W:sh("find a -name \"*.txt\"")
check("through the shell, quotes stripped", r.out == "a/one.txt\n", show(r.out))
r = W:run("find", "nope", "a/one.txt")
check("find missing path: message, status 1, carries on", r.status == 1
    and r.err[1] == "find: nope: No such file or directory" and r.out == "a/one.txt\n", show(r.errText))
r = W:run("find", "a", "-bogus")
r2 = W:run("find", "a", "-type", "x")
r3 = W:run("find", "a", "(", "-name", "x")
r4 = W:run("find", "a", "-exec", "echo")
check("bad expressions: message, usage, status 1", r.status == 1 and r.err[1] == "find: unknown primary -- -bogus"
    and r.err[2] == "usage: find [-H|-L] [path...] [expression]" and r2.status == 1 and r3.err[1] == "find: missing )"
    and r4.err[1] == "find: missing ; after -exec" and r.out == "", show(r.errText .. "~" .. r3.errText))
r = W:run("find", "a", "-name", "one.txt", { pipe = true })
check("find writes to io.output (a pipe)", r.out == "a/one.txt\n" and r.tty == "", show(r.tty))
