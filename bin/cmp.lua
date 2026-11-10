-- cmp.lua -- compare two files byte by byte (POSIX cmp)
--
--   cmp [-l|-s] file1 file2
--
-- Says nothing and exits 0 when the files are the same.  Otherwise it
-- writes "file1 file2 differ: char N, line L" for the first byte that
-- differs and exits 1.  -l lists every differing byte instead, as its
-- position (decimal) and the two bytes (octal); -s writes nothing and
-- only the status tells.  When one file is the start of the other,
-- "cmp: EOF on <shorter>" goes to the error output (status 1).  Either
-- file can be "-", standard input.  A file that can't be read: status 2.

package.path = (ccnix and ccnix.lib or "/" .. fs.getDir(fs.getDir(shell.getRunningProgram())) .. "/lib/?.lua;") .. package.path  -- ccnix's lib/, or the one beside bin/
local cu = require("cu").init("cmp", "cmp [-l|-s] file1 file2")
local text = require("text")
local opts, ops = cu.getopt({ ... }, "ls", 2)
if #ops ~= 2 then cu.usageError() end
if opts.l and opts.s then cu.usageError("-l and -s can't be used together") end

local function slurp(name)
    local h = cu.open(name)
    if not h then cu.exit(2) end
    local s = cu.readAll(h)
    cu.close(h)
    return s
end
local a = slurp(ops[1])
-- "-" twice is one stream, so the same file
local b = (ops[1] == "-" and ops[2] == "-") and a or slurp(ops[2])
local n = math.min(#a, #b)

-- the first position from i on where the files differ (n + 1 if none):
-- skip equal blocks a whole string compare at a time, then byte by byte
local function nextDiff(i)
    while i + 255 <= n and a:sub(i, i + 255) == b:sub(i, i + 255) do i = i + 256 end
    while i <= n and a:byte(i) == b:byte(i) do i = i + 1 end
    return i
end

local i = nextDiff(1)
if i <= n then
    if opts.l then
        local count, lastYield = 0, os.clock()
        while i <= n do
            io.write(string.format("%d %o %o\n", i, a:byte(i), b:byte(i)))
            i = nextDiff(i + 1)
            -- two big, quite different files: yield now and then, or CC
            -- stops the program for running too long without yielding
            count = count + 1
            if count % 200 == 0 and os.clock() - lastYield > 2 then
                os.queueEvent("cmp")
                os.pullEvent("cmp")
                lastYield = os.clock()
            end
        end
    elseif not opts.s then
        local lines = text.count(a:sub(1, i - 1), "\n")
        io.write(string.format("%s %s differ: char %d, line %d\n", ops[1], ops[2], i, lines + 1))
    end
    cu.status = 1
end
if #a ~= #b then
    if not opts.s and (opts.l or cu.status == 0) then
        cu.err(string.format("EOF on %s after byte %d", #a < #b and ops[1] or ops[2], n))
    end
    cu.status = 1
end
return cu.exit()
