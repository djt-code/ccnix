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
local scan = require("scan")
local text = require("text")
local opts, files, order = cu.getopt({ ... }, "vA:j:N:t:bcdosx")

-- A -j or -N number: decimal, 0x hex or 0 octal, with an optional
-- multiplier suffix when `mult` is allowed.
local MULT = { b = 512, k = 1024, m = 1048576 }
local isOctal = scan.oneOf("01234567")
local function number(s, mult)
    -- the body, then b, k or m (none after 0x: "b" is a hex digit there)
    local hex = text.startsWith(s, "0x") or text.startsWith(s, "0X")
    local body, suf = s, ""
    if not hex and MULT[s:sub(-1)] then body, suf = s:sub(1, -2), s:sub(-1) end
    if suf ~= "" and not mult then return nil end
    -- the body: "0x" hex digits, "0" octal digits, or decimal digits
    local n
    if hex and #body > 2 and scan.all(body:sub(3), scan.isHexDigit) then n = tonumber(body:sub(3), 16)
    elseif text.startsWith(body, "0") then n = scan.all(body, isOctal) and tonumber(body, 8) or nil
    elseif body ~= "" and scan.all(body, scan.isDigit) then n = tonumber(body) end
    return n and n * (MULT[suf] or 1)
end

-- the output types, in order: { letter, size }
local SIZES = { C = 1, S = 2, I = 4, L = 8 }
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
                if size ~= 1 and size ~= 2 and size ~= 4 and size ~= 8 then
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

-- The digits of the little-endian unsigned number in s, in base b: long
-- division over the bytes, so 8-byte values stay exact.
local DIG = "0123456789abcdef"
local function digits(s, b)
    local n = { s:byte(1, -1) }
    local out = {}
    repeat
        local rem, zero = 0, true
        for i = #n, 1, -1 do
            local v = rem * 256 + n[i]
            n[i] = math.floor(v / b)
            rem = v % b
            if n[i] ~= 0 then zero = false end
        end
        out[#out + 1] = DIG:sub(rem + 1, rem + 1)
    until zero
    return string.reverse(table.concat(out))
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
    return WIDTH[t[1]][({ 1, 2, nil, 3, nil, nil, nil, 4 })[t[2]]]
end

-- one field of type t holding the bytes s
local function field(t, s)
    local c, b = t[1], s:byte(1)
    if c == "a" then
        b = b % 128
        return NAMES[b] or string.char(b)
    elseif c == "c" then
        if ESC[b] then return ESC[b] end
        if b >= 32 and b < 127 then return string.char(b) end
        return string.format("%03o", b)
    elseif c == "d" and s:byte(#s) >= 128 then
        return "-" .. digits(negate(s), 10)
    end
    local v = digits(s, c == "o" and 8 or c == "x" and 16 or 10)
    if c == "o" or c == "x" then v = string.rep("0", width(t) - #v) .. v end
    return v
end

-- Each field gets one space plus its width; types with fewer, wider
-- fields are padded so that all the lines of a block are the same width.
local lineW = 0
for _, t in ipairs(types) do lineW = math.max(lineW, (width(t) + 1) * 16 / t[2]) end
local addrW = base == "n" and 0 or #string.format(ADDR[base], 0)

local prev, starred = nil, false
for pos = 1, #data, 16 do
    -- a big dump takes a while: yield now and then, or CC stops us
    if pos % 4096 == 1 then os.queueEvent("od"); os.pullEvent("od") end
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
                s = s .. string.rep("\0", t[2] - #s)    -- a short last field: zero-filled
                local f = field(t, s)
                line[#line + 1] = string.rep(" ", fw - #f) .. f
            end
            io.write(table.concat(line), "\n")
        end
    end
    prev = block
end
if base ~= "n" then io.write(string.format(ADDR[base], skip + #data), "\n") end
return cu.exit()
