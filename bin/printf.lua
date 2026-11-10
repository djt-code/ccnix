-- printf.lua -- write formatted output (POSIX printf)
--
--   printf format [argument...]
--
-- Writes the format with its conversions filled in from the arguments, as
-- C's printf does: %s a string, %b a string with backslash escapes, %c its
-- first character, %d %i signed and %o %u %x %X unsigned integers, %e %E
-- %f %F %g %G floating point, %% a percent sign.  Flags (- + space # 0), a
-- field width and a .precision can come between % and the letter.  The
-- format's own escapes are \\ \a \b \f \n \r \t \v and \ddd (octal); %b's
-- argument has the same but \0ddd for octal, and \c, which ends all output.
-- Numeric arguments can be decimal, 0x hex, 0 octal, or 'c (or "c) for
-- the code of the character c.  When arguments are left over the format
-- is used again; missing ones count as "" or 0.  A bad number is reported,
-- counts as what could be read of it, and printf exits 1.

package.path = (ccnix and ccnix.lib or "/" .. fs.getDir(fs.getDir(shell.getRunningProgram())) .. "/lib/?.lua;") .. package.path  -- ccnix's lib/, or the one beside bin/
local cu = require("cu").init("printf", "printf format [argument...]")
local scan = require("scan")
local text = require("text")
local convert = require("convert")
local args = { ... }
if args[1] == "--" then table.remove(args, 1) end
if #args == 0 then cu.usageError() end
local format = table.remove(args, 1)

-- The numeric value of argument a (nil: missing, 0); `int` takes whole
-- numbers only.  A bad one is reported and gives what could be read of it.
local isQuote = scan.oneOf("'\"")
local function num(a, int)
    if a == nil or a == "" then return 0 end
    -- 'c or "c: the code of c
    if isQuote(a:sub(1, 1)) and #a > 1 then return a:byte(2) end
    local sc = scan.new(a)
    sc:skipSpaces()
    local s = sc:rest()
    local n
    if int then
        -- a sign, then 0x hex, 0 octal or decimal; all of s must be used
        -- ("09" is not)
        local negative = sc:accept("-")
        if not negative then sc:accept("+") end
        local digits, base = sc:readCInteger()
        n = digits and convert.toInteger(digits, base)
        if n and negative then n = -n end
        if n and sc:atEnd() then return n end
    else
        n = tonumber(s)                 -- (C's strtod takes 0x hex too)
        if n then return n end
        n = scan.new(s):readFloat()     -- (the decimal number s starts with)
    end
    cu.fail(a .. (n and ": not completely converted" or ": expected numeric value"))
    return n or 0
end

-- pad s to the width (flags "-": on the right); never cut
local function pad(s, flags, width)
    width = tonumber(width) or 0
    if text.contains(flags, "-") then return text.padRight(s, width) end
    return text.padLeft(s, width)
end

-- each integer conversion's base (d i u: 10)
local INTEGER_BASE = { o = 8, x = 16, X = 16 }

-- An integer conversion done by hand, so that it means the same in
-- CraftOS and elsewhere: digits, precision, sign, # prefix, zero fill.
local function integer(conv, flags, width, prec, n)
    n = n < 0 and math.ceil(n) or math.floor(n)
    local neg = n < 0 and (conv == "d" or conv == "i")
    local m = neg and -n or n
    -- (a negative unsigned one is its 64-bit two's complement)
    local d = convert.toBase(m, INTEGER_BASE[conv] or 10)
    if conv == "X" then d = d:upper() end
    m = (m == 0) and 0 or 1
    if prec ~= "" then
        local p = tonumber(prec) or 0
        if p == 0 and m == 0 then d = "" end
        d = text.padLeft(d, p, "0")
    end
    local pre = neg and "-" or text.contains(flags, "+") and (conv == "d" or conv == "i") and "+"
        or text.contains(flags, " ") and (conv == "d" or conv == "i") and " " or ""
    if text.contains(flags, "#") then
        if conv == "o" and not text.startsWith(d, "0") then d = "0" .. d
        elseif (conv == "x" or conv == "X") and m ~= 0 then pre = pre .. "0" .. conv end
    end
    width = tonumber(width) or 0
    if text.contains(flags, "0") and not text.contains(flags, "-") and prec == "" then
        d = text.padLeft(d, width - #pre, "0")
    end
    return pad(pre .. d, flags, width)
end

local isIntConversion = scan.oneOf("diouxX")
local isFloatConversion = scan.oneOf("eEfFgG")

-- Write the format once, taking arguments from args[ai...].  Returns the
-- next argument's index, and true when output must stop (%b's \c, or a
-- bad conversion).
local function once(ai)
    local p, out = 1, {}
    local function emit(s) out[#out + 1] = s end
    local function nextArg() ai = ai + 1; return args[ai - 1] end
    while p <= #format do
        local pc = text.find(format, "%", p)
        local literal = format:sub(p, (pc or #format + 1) - 1)
        local s, stop = convert.unescape(literal)       -- (the format's escapes: \ooo octal, no \c)
        emit(s)
        if not pc then break end
        -- "%" flags width .precision letter (the letter "" at the end)
        local spec = convert.readFormatSpec(scan.new(format, pc))
        local flags, width, prec, conv, whole = spec.flags, spec.width, spec.precision, spec.letter, spec.text
        p = pc + #whole
        if conv == "%" then emit("%")
        elseif conv == "s" or conv == "b" or conv == "c" then
            local a = nextArg() or ""
            if conv == "b" then
                a, stop = convert.unescape(a, true)     -- (%b's: \0ooo octal, \c stops)
            elseif conv == "c" then a = a:sub(1, 1) end
            if prec then a = a:sub(1, tonumber(prec) or 0) end
            emit(pad(a, flags, width))
            if stop then io.write(table.concat(out)); return ai, true end
        elseif isIntConversion(conv) then
            emit(integer(conv, flags, width, prec and (prec ~= "" and prec or "0") or "",
                num(nextArg(), true)))
        elseif isFloatConversion(conv) then
            local v = num(nextArg(), false)
            if conv == "F" then conv = "f" end
            -- Lua refuses some specs C takes (a width over 99, repeated flags)
            local ok, s = pcall(string.format, "%" .. flags .. width .. (prec and "." .. prec or "") .. conv, v)
            if not ok then
                io.write(table.concat(out))
                cu.fail(whole .. ": invalid conversion")
                return ai, true
            end
            emit(s)
        else
            io.write(table.concat(out))
            cu.fail(whole .. ": invalid conversion")
            return ai, true
        end
    end
    io.write(table.concat(out))
    return ai, false
end

local ai, stop = 1, false
repeat
    local before = ai
    ai, stop = once(ai)
until stop or ai > #args or ai == before
return cu.exit()
