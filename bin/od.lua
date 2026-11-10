-- od.lua -- dump files in octal and other formats (POSIX od)
--
--   od [-v] [-A d|o|x|n] [-j skip] [-N count] [-t type]... [-bcdosx] [file...]
--
-- Reads the files one after another as one stream ("-" or none: standard
-- input) and writes 16 bytes a line: the offset, then the bytes in each
-- output type, one line per type.  The default is -t o2 with octal
-- offsets.  A type is a letter, and for d o u x an optional size:
--   a  named characters (nul, sp, del...)    c  characters, \n-style escapes
--   d  signed decimal     o  octal     u  unsigned decimal     x  hex
--   sizes: 1 2 4 8, or C (1), S (2), I (4), L (8); the default is 4.
-- Several types can be given together (-t x1c) or with more -t options.
-- -b -c -d -o -s -x are short for -t o1, c, u2, o2, d2 and x2.
-- Words are little-endian.  -A picks the offset base (n: no offsets).
-- -j skips bytes first (decimal, 0x hex or 0 octal, then b k or m for
-- 512, 1024 or 1048576 bytes); -N stops after count bytes.  A line equal
-- to the one before is written as "*" unless -v is given.  The last line
-- holds the offset just past the data.

package.path = (ccnix and ccnix.lib or "/" .. fs.getDir(fs.getDir(shell.getRunningProgram())) .. "/lib/?.lua;") .. package.path  -- ccnix's lib/, or the one beside bin/
local cu = require("cu").init("od", "od [-v] [-A base] [-j skip] [-N count] [-t type]... [-bcdosx] [file...]")
local convert = require("convert")
local scan = require("scan")
local text = require("text")
local opts, files, order = cu.getopt({ ... }, "vA:j:N:t:bcdosx")

-- A -j or -N number: "0x" hex digits, "0" octal digits or decimal
-- digits; with `mult`, the octal or decimal ones may end in b, k or m
-- (not the hex: "b" is a hex digit there).  The number, or nil.
local MULT = { b = 512, k = 1024, m = 1048576 }
local function number(s, mult)
    local sc = scan.new(s)
    local digits, base = sc:readCInteger()
    if not digits then return nil end
    local suffix = sc:readRest()
    local factor = suffix == "" and 1 or (mult and base ~= 16 and MULT[suffix])
    return factor and convert.toInteger(digits, base) * factor or nil
end

-- the output types, in order: { letter, size }
local SIZES = { C = 1, S = 2, I = 4, L = 8 }
-- the sizes there are, each as its column in WIDTH below
local SIZE_COLUMN = { [1] = 1, [2] = 2, [4] = 3, [8] = 4 }
local SHORT = { b = "o1", c = "c", d = "u2", o = "o2", s = "d2", x = "x2" }
local isSized = scan.oneOf("doux")     -- (the types that take a size)
local types = {}
for _, o in ipairs(order) do
    local spec = o[1] == "t" and o[2] or SHORT[o[1]]
    if spec then
        if spec == "" then cu.usageError("empty type string") end
        local p = 1
        while p <= #spec do
            local c = spec:sub(p, p)
            p = p + 1
            if c == "a" or c == "c" then
                types[#types + 1] = { c, 1 }
            elseif isSized(c) then
                local size = 4
                local digits = scan.new(spec, p):readWhile(scan.isDigit)
                if digits ~= "" then size = tonumber(digits); p = p + #digits
                elseif SIZES[spec:sub(p, p)] then size = SIZES[spec:sub(p, p)]; p = p + 1 end
                if not SIZE_COLUMN[size] then
                    cu.usageError("invalid type size in " .. spec)
                end
                types[#types + 1] = { c, size }
            elseif c == "f" then
                cu.usageError("floating point types are not supported")
            else
                cu.usageError("invalid type string: " .. spec)
            end
        end
    end
end
if #types == 0 then types[1] = { "o", 2 } end

local base = opts.A or "o"
local ADDR = { o = "%07o", d = "%07d", x = "%06x", n = "" }
if not ADDR[base] then cu.usageError("invalid address base: " .. base) end
local skip, count = 0, nil
if opts.j then skip = number(opts.j, true) or cu.usageError("invalid skip: " .. opts.j) end
if opts.N then count = number(opts.N) or cu.usageError("invalid count: " .. opts.N) end

-- the bytes: every operand in turn, then the skip and count applied
local data = {}
cu.each(files, function(h) data[#data + 1] = cu.readAll(h) end)
data = table.concat(data)
if skip > #data then
    cu.fail("cannot skip past end of combined input")
    return cu.exit()
end
data = data:sub(skip + 1, count and skip + count or nil)

-- The digits of the little-endian unsigned number in s (1 to 8 bytes), in
-- base b: given to convert.toBase as its two 32-bit halves, so 8-byte
-- values stay exact.
local function digits(s, b)
    local lo, hi = 0, 0
    for i = math.min(#s, 4), 1, -1 do lo = lo * 256 + s:byte(i) end
    for i = #s, 5, -1 do hi = hi * 256 + s:byte(i) end
    return convert.toBase(lo, b, hi)
end

-- two's complement negation of the little-endian bytes in s
local function negate(s)
    local n, carry = {}, 1
    for i = 1, #s do
        local v = 255 - s:byte(i) + carry
        n[i] = string.char(v % 256)
        carry = math.floor(v / 256)
    end
    return table.concat(n)
end

local NAMES = { [0] = "nul", "soh", "stx", "etx", "eot", "enq", "ack", "bel", "bs", "ht", "nl",
    "vt", "ff", "cr", "so", "si", "dle", "dc1", "dc2", "dc3", "dc4", "nak", "syn", "etb",
    "can", "em", "sub", "esc", "fs", "gs", "rs", "us", "sp", [127] = "del" }
local ESC = { [0] = "\\0", [7] = "\\a", [8] = "\\b", [9] = "\\t", [10] = "\\n",
    [11] = "\\v", [12] = "\\f", [13] = "\\r" }

-- the widest value of each kind of field, by letter and size
local WIDTH = { o = { 3, 6, 11, 22 }, u = { 3, 5, 10, 20 }, d = { 4, 6, 11, 20 }, x = { 2, 4, 8, 16 } }
local function width(t)
    if t[1] == "a" or t[1] == "c" then return 3 end
    return WIDTH[t[1]][SIZE_COLUMN[t[2]]]
end

-- each number type's base, and the ones written with leading zeros
local BASE = { o = 8, x = 16, d = 10, u = 10 }
local ZERO_FILLED = { o = true, x = true }

-- one field of type t holding the bytes s
local function field(t, s)
    local c, b = t[1], s:byte(1)
    if c == "a" then
        b = b % 128
        return NAMES[b] or string.char(b)
    elseif c == "c" then
        if ESC[b] then return ESC[b] end
        local ch = s:sub(1, 1)
        if scan.isPrintable(ch) then return ch end
        return string.format("%03o", b)
    elseif c == "d" and s:byte(#s) >= 128 then
        return "-" .. digits(negate(s), 10)
    end
    local v = digits(s, BASE[c])
    if ZERO_FILLED[c] then v = text.padLeft(v, width(t), "0") end
    return v
end

-- Each field gets one space plus its width; types with fewer, wider
-- fields are padded so that all the lines of a block are the same width.
local lineW = 0
for _, t in ipairs(types) do lineW = math.max(lineW, (width(t) + 1) * 16 / t[2]) end
local addrW = base == "n" and 0 or #string.format(ADDR[base], 0)

local prev, starred = nil, false
for pos = 1, #data, 16 do
    cu.breathe()        -- (a big dump takes a while)
    local block = data:sub(pos, pos + 15)
    if not opts.v and block == prev then
        if not starred then io.write("*\n"); starred = true end
    else
        starred = false
        for i, t in ipairs(types) do
            local line = {}
            line[1] = base == "n" and "" or
                (i == 1 and string.format(ADDR[base], skip + pos - 1) or string.rep(" ", addrW))
            local fw = math.floor(lineW / (16 / t[2]))
            for p = 1, #block, t[2] do
                local s = block:sub(p, p + t[2] - 1)
                s = text.padRight(s, t[2], "\0")    -- a short last field: zero-filled
                line[#line + 1] = text.padLeft(field(t, s), fw)
            end
            io.write(table.concat(line), "\n")
        end
    end
    prev = block
end
if base ~= "n" then io.write(string.format(ADDR[base], skip + #data), "\n") end
return cu.exit()
