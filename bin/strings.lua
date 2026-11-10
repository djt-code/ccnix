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
local scan = require("scan")
local opts, files = cu.getopt({ ... }, "an:t:")

local min = cu.number(opts, "n", 4, 1, true)     -- (the shortest run written)
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

-- the runs of printable characters (scan.isPrintable: space to ~) in s
cu.each(files, function(h)
    local s = cu.readAll(h)
    local runStart = nil
    for i = 1, #s + 1 do
        local printable = scan.isPrintable(s:sub(i, i))     -- ("" past the end, which ends a run)
        if printable and not runStart then
            runStart = i
        elseif not printable and runStart then
            found(s, runStart, i - 1)
            runStart = nil
        end
        -- a big file takes a while (cu.breathe each 64K bytes, not each one)
        if i % 65536 == 0 then cu.breathe() end
    end
end)
return cu.exit()
