-- strings.lua -- find printable strings in files (POSIX strings)
--
--   strings [-a] [-t d|o|x] [-n number] [file...]
--
-- Writes every run of at least 4 (or -n number) printable characters
-- (space to ~) found in the files, one per line.  -t puts the run's byte
-- offset from the start of its file in front, in decimal, octal or hex,
-- followed by a space.  Whole files are always scanned, so -a changes
-- nothing.  "-" or no files reads standard input.

package.path = (ccnix and ccnix.lib or "/" .. fs.getDir(fs.getDir(shell.getRunningProgram())) .. "/lib/?.lua;") .. package.path  -- ccnix's lib/, or the one beside bin/
local cu = require("cu").init("strings", "strings [-a] [-t format] [-n number] [file...]")
local opts, files = cu.getopt({ ... }, "an:t:")

local min = 4
if opts.n then
    min = cu.int(opts.n)
    if not min or min < 1 then cu.usageError("invalid minimum string length: " .. opts.n) end
end
local fmt = nil
if opts.t then
    fmt = ({ d = "%d ", o = "%o ", x = "%x " })[opts.t]
    if not fmt then cu.usageError("invalid radix: " .. opts.t) end
end

-- a run of printable characters, s from a to b: written if it's long enough
local function found(s, a, b)
    if b - a + 1 >= min then
        if fmt then io.write(string.format(fmt, a - 1)) end
        io.write(s:sub(a, b), "\n")
    end
end

-- the runs of printable characters (space to ~, bytes 32 to 126) in s
cu.each(files, function(h)
    local s = cu.readAll(h)
    local runStart = nil
    for i = 1, #s + 1 do
        local b = s:byte(i)     -- (nil past the end, which ends a run)
        local printable = b ~= nil and b >= 32 and b <= 126
        if printable and not runStart then
            runStart = i
        elseif not printable and runStart then
            found(s, runStart, i - 1)
            runStart = nil
        end
        -- a big file takes a while: yield now and then, or CC stops us
        if i % 65536 == 0 then os.queueEvent("strings"); os.pullEvent("strings") end
    end
end)
return cu.exit()
