-- uniq.lua -- report or filter out repeated lines (POSIX uniq)
--
--   uniq [-c|-d|-u] [-f fields] [-s chars] [input [output]]
--
-- Reads input (standard input if it's missing or "-") and writes one copy
-- of each run of identical adjacent lines to output (standard output if
-- it's missing).  Sort the input first to catch repeats anywhere.
--   -c  put the number of times each line occurred, and a space, before it
--   -d  write only the lines that were repeated
--   -u  write only the lines that were not repeated
--   -f  ignore the first fields fields of each line when comparing (a
--       field is blanks then non-blanks)
--   -s  ignore that many characters more, after the fields

package.path = (ccnix and ccnix.lib or "/" .. fs.getDir(fs.getDir(shell.getRunningProgram())) .. "/lib/?.lua;") .. package.path  -- ccnix's lib/, or the one beside bin/
local cu = require("cu").init("uniq", "uniq [-c|-d|-u] [-f fields] [-s chars] [input [output]]")
local scan = require("scan")
local opts, ops = cu.getopt({ ... }, "cdf:s:u")
if #ops > 2 then cu.usageError("too many operands") end
local nf, ns = cu.int(opts.f or "0"), cu.int(opts.s or "0")
if not nf or nf < 0 then cu.usageError("bad field count: " .. opts.f) end
if not ns or ns < 0 then cu.usageError("bad character count: " .. opts.s) end

local isBlank = scan.oneOf(" \t")
local function notBlank(c) return not isBlank(c) end

-- the part of a line that is compared: past nf fields (blanks, then
-- non-blanks), then ns characters more
local function key(l)
    local sc = scan.new(l)
    for _ = 1, nf do
        sc:readWhile(isBlank)
        sc:readWhile(notBlank)
    end
    return l:sub(sc:pos() + ns)
end

-- io.open's message starts with the path and ": ": keep just the reason
local function reason(e)
    local _, rest = scan.cut(e, ":")
    if rest and scan.startsWith(rest, " ") then return rest:sub(2) end
    return e
end

local h = cu.open(ops[1] or "-")
if not h then return cu.exit() end
local out = io.output()
if ops[2] then
    local e
    out, e = io.open(shell.resolve(ops[2]), "wb")
    if not out then cu.close(h); cu.fail(ops[2] .. ": " .. reason(tostring(e))); return cu.exit() end
end

local function emit(l, n)
    if (opts.d and n < 2) or (opts.u and n > 1) then return end
    if opts.c then out:write(tostring(n), " ") end
    out:write(l, "\n")
end

local prev, pkey, n = nil, nil, 0
local done = 0     -- lines since the last yield
for l in function() return cu.readLine(h) end do
    -- yield now and then so a big file can't run "too long without yielding"
    done = done + 1
    if done % 1000 == 0 then os.queueEvent("uniq_yield"); os.pullEvent("uniq_yield") end
    local k = key(l)
    if prev and k == pkey then
        n = n + 1
    else
        if prev then emit(prev, n) end
        prev, pkey, n = l, k, 1
    end
end
if prev then emit(prev, n) end
cu.close(h)
if ops[2] then out:close() end
return cu.exit()
