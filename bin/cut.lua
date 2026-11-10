-- cut.lua -- write selected parts of each line (POSIX cut)
--
--   cut -b list [-n] [file...]
--   cut -c list [file...]
--   cut -f list [-d delim] [-s] [file...]
--
-- list is numbers and ranges separated by commas: 3, 2-5, -4 (1 to 4) or
-- 6- (6 to the end), counting from 1.  The parts come out in line order,
-- each once, whatever order the list gives them in.
--   -b  bytes; -c characters (the same thing in CraftOS); -n is accepted
--   -f  fields separated by delim (a tab unless -d says otherwise); they
--       are written with the same delimiter between them.  A line with no
--       delimiter is written whole, unless -s, which drops it.
-- With no files, or for "-", standard input is read.

package.path = (ccnix and ccnix.lib or "/" .. fs.getDir(fs.getDir(shell.getRunningProgram())) .. "/lib/?.lua;") .. package.path  -- ccnix's lib/, or the one beside bin/
local cu = require("cu").init("cut", "cut -b list [-n] | -c list | -f list [-d delim] [-s] [file...]")
local scan = require("scan")
local text = require("text")
local opts, files = cu.getopt({ ... }, "b:c:d:f:ns")

local n = (opts.b and 1 or 0) + (opts.c and 1 or 0) + (opts.f and 1 or 0)
if n ~= 1 then cu.usageError("give exactly one of -b, -c and -f") end
if not opts.f and (opts.d or opts.s) then cu.usageError("-d and -s need -f") end
local delim = opts.d or "\t"
if #delim ~= 1 then cu.usageError("the delimiter must be one character") end

local isListSep = scan.oneOf(", \t")
local function notListSep(c) return not isListSep(c) end

-- the parts of a list: what's between commas and blanks, empty ones left out
local function listParts(spec)
    local parts, sc = {}, scan.new(spec)
    sc:readWhile(isListSep)
    while not sc:atEnd() do
        parts[#parts + 1] = sc:readWhile(notListSep)
        sc:readWhile(isListSep)
    end
    return parts
end

-- a part: digits? "-" digits?, or digits alone (n is n-n); its two ends as
-- text, "" where one is left out, or nil if it's neither
local function readRange(part)
    local sc = scan.new(part)
    local a = sc:readWhile(scan.isDigit)
    if sc:atEnd() then
        if a == "" then return nil end
        return a, a
    end
    if not sc:accept("-") then return nil end
    local b = sc:readWhile(scan.isDigit)
    if not sc:atEnd() then return nil end
    return a, b
end

-- the list as ranges { from, to } (to = huge for "n-")
local ranges = {}
local spec = opts.b or opts.c or opts.f
for _, part in ipairs(listParts(spec)) do
    local a, b = readRange(part)
    if not a or a .. b == "" then cu.usageError("bad list: " .. spec) end
    a, b = tonumber(a ~= "" and a or "1"), tonumber(b ~= "" and b or nil) or math.huge
    if a < 1 or b < a then cu.usageError("bad list: " .. spec) end
    ranges[#ranges + 1] = { a, b }
end
if #ranges == 0 then cu.usageError("bad list: " .. spec) end

local function wanted(i)
    for _, r in ipairs(ranges) do if i >= r[1] and i <= r[2] then return true end end
    return false
end

local done = 0     -- lines since the last yield
for l in cu.lines(files) do
    -- yield now and then so a big file can't run "too long without yielding"
    done = done + 1
    if done % 1000 == 0 then os.queueEvent("cut_yield"); os.pullEvent("cut_yield") end
    local t = {}
    if opts.f then
        if not l:find(delim, 1, true) then
            if not opts.s then io.write(l, "\n") end
        else
            local i = 0
            for _, f in ipairs(text.split(l, delim, true)) do
                i = i + 1
                if wanted(i) then t[#t + 1] = f end
            end
            io.write(table.concat(t, delim), "\n")
        end
    else
        for i = 1, #l do if wanted(i) then t[#t + 1] = l:sub(i, i) end end
        io.write(table.concat(t), "\n")
    end
end
return cu.exit()
