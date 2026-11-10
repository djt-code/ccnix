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
local args = { ... }
if args[1] == "--" then table.remove(args, 1) end
if #args == 0 then cu.usageError() end
local format = table.remove(args, 1)

local ESC = { a = "\a", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t", v = "\v", ["\\"] = "\\" }
local isOctal = scan.oneOf("01234567")

-- up to three octal digits at s's index at ("" if none come)
local function readOctal(s, at)
    local sc, digits = scan.new(s, at), ""
    while #digits < 3 and isOctal(sc:peek()) do digits = digits .. sc:advance() end
    return digits
end

-- Expand the backslash escapes in s.  For %b (isB) octal is \0ddd and \c
-- stops; returns the text and whether \c was met.
local function escapes(s, isB)
    local out, p = {}, 1
    while p <= #s do
        local b = s:find("\\", p, true)
        if not b then out[#out + 1] = s:sub(p); break end
        out[#out + 1] = s:sub(p, b - 1)
        local c = s:sub(b + 1, b + 1)
        -- octal: for %b "0" and up to three digits, else one to three digits
        local oct
        if isB then
            if c == "0" then oct = readOctal(s, b + 2) end
        else
            oct = readOctal(s, b + 1)
            if oct == "" then oct = nil end
        end
        if oct then
            out[#out + 1] = string.char((tonumber(oct ~= "" and oct or "0", 8) or 0) % 256)
            p = b + 1 + #oct + (isB and 1 or 0)
        elseif isB and c == "c" then
            return table.concat(out), true
        elseif ESC[c] then
            out[#out + 1] = ESC[c]
            p = b + 2
        else
            out[#out + 1] = "\\"
            p = b + 1
        end
    end
    return table.concat(out), false
end

-- The digits of a whole number at the start of body: "0x" and hex digits
-- (base 16), "0" and octal digits (base 8, the 0 counted in), or decimal
-- digits.  The digits, the base, and how long a prefix came before them;
-- nil if body starts with none of these.
local function leadingInteger(body)
    local sc = scan.new(body)
    if sc:accept("0x") or sc:accept("0X") then
        local hex = sc:readWhile(scan.isHexDigit)
        if hex ~= "" then return hex, 16, 2 end
    end
    sc:setPos(1)
    if sc:at("0") then return sc:readWhile(isOctal), 8, 0 end
    local digits = sc:readWhile(scan.isDigit)
    if digits ~= "" then return digits, 10, 0 end
    return nil
end

-- The longest start of s that reads as a decimal number: sign? digit*
-- ("." digit*)? (("e" | "E") sign? digit+)?
local function decimalPrefix(s)
    local sc = scan.new(s)
    local _ = sc:accept("+") or sc:accept("-")
    sc:readWhile(scan.isDigit)
    if sc:accept(".") then sc:readWhile(scan.isDigit) end
    local mantissaEnd = sc:pos()
    if sc:accept("e") or sc:accept("E") then
        local _ = sc:accept("+") or sc:accept("-")
        if sc:readWhile(scan.isDigit) == "" then sc:setPos(mantissaEnd) end    -- (no exponent after all)
    end
    return s:sub(1, sc:pos() - 1)
end

-- The numeric value of argument a (nil: missing, 0); `int` takes whole
-- numbers only.  A bad one is reported and gives what could be read of it.
local function num(a, int)
    if a == nil or a == "" then return 0 end
    -- 'c or "c: the code of c
    if (a:sub(1, 1) == "'" or a:sub(1, 1) == '"') and #a > 1 then return a:byte(2) end
    local sc = scan.new(a)
    sc:skipSpaces()
    local s = sc:rest()
    local n
    if int then
        -- 0x hex, 0 octal or decimal; all of s must be used ("09" is not)
        local sign, body = "", s
        if text.startsWith(s, "+") or text.startsWith(s, "-") then sign, body = s:sub(1, 1), s:sub(2) end
        local d, base, pre = leadingInteger(body)
        n = d and tonumber(d, base)
        if n and sign == "-" then n = -n end
        if n and #sign + pre + #d == #s then return n end
    else
        n = tonumber(s)
        if n then return n end
        n = tonumber(decimalPrefix(s))
    end
    cu.fail(a .. (n and ": not completely converted" or ": expected numeric value"))
    return n or 0
end

-- pad s to the width (flags "-": on the right)
local function pad(s, flags, width)
    width = tonumber(width) or 0
    if #s >= width then return s end
    if flags:find("-", 1, true) then return s .. string.rep(" ", width - #s) end
    return string.rep(" ", width - #s) .. s
end

-- An integer conversion done by hand, so that it means the same in
-- CraftOS and elsewhere: digits, precision, sign, # prefix, zero fill.
local function integer(conv, flags, width, prec, n)
    n = n < 0 and math.ceil(n) or math.floor(n)
    local neg = n < 0 and (conv == "d" or conv == "i")
    local m = neg and -n or n
    -- the value as two 32-bit halves; a negative unsigned one becomes its
    -- 64-bit two's complement
    local hi = math.floor(m / 2 ^ 32)
    local lo = m - hi * 2 ^ 32
    if hi < 0 then hi = hi + 2 ^ 32 end
    local b = (conv == "o" and 8) or ((conv == "x" or conv == "X") and 16) or 10
    local t = {}
    repeat
        local r = hi % b
        hi = math.floor(hi / b)
        local v = r * 2 ^ 32 + lo
        lo = math.floor(v / b)
        r = math.floor(v % b)
        t[#t + 1] = ("0123456789abcdef"):sub(r + 1, r + 1)
    until hi == 0 and lo == 0
    local d = string.reverse(table.concat(t))
    if conv == "X" then d = d:upper() end
    m = (m == 0) and 0 or 1
    if prec ~= "" then
        local p = tonumber(prec) or 0
        if p == 0 and m == 0 then d = "" end
        d = string.rep("0", p - #d) .. d
    end
    local pre = neg and "-" or flags:find("+", 1, true) and (conv == "d" or conv == "i") and "+"
        or flags:find(" ", 1, true) and (conv == "d" or conv == "i") and " " or ""
    if flags:find("#", 1, true) then
        if conv == "o" and d:sub(1, 1) ~= "0" then d = "0" .. d
        elseif (conv == "x" or conv == "X") and m ~= 0 then pre = pre .. "0" .. conv end
    end
    width = tonumber(width) or 0
    if flags:find("0", 1, true) and not flags:find("-", 1, true) and prec == "" then
        d = string.rep("0", width - #pre - #d) .. d
    end
    return pad(pre .. d, flags, width)
end

-- Write the format once, taking arguments from args[ai...].  Returns the
-- next argument's index, and true when output must stop (%b's \c, or a
-- bad conversion).
local isFlag = scan.oneOf("-+ #0")
local isIntConversion = scan.oneOf("diouxX")
local isFloatConversion = scan.oneOf("eEfFgG")

-- a conversion at pc: "%" flags* width ("."? precision) and its letter
-- (flags - + space # 0, width and precision digits, any of them left out,
-- the letter too at the end of the format).  The five parts as text.
local function readConversion(pc)
    local sc = scan.new(format, pc + 1)
    local flags = sc:readWhile(isFlag)
    local width = sc:readWhile(scan.isDigit)
    local dot = sc:accept(".") and "." or ""
    local prec = sc:readWhile(scan.isDigit)
    return flags, width, dot, prec, sc:advance()
end

local function once(ai)
    local p, out = 1, {}
    local function emit(s) out[#out + 1] = s end
    local function nextArg() ai = ai + 1; return args[ai - 1] end
    while p <= #format do
        local pc = format:find("%", p, true)
        local text = format:sub(p, (pc or #format + 1) - 1)
        local s, stop = escapes(text, false)
        emit(s)
        if not pc then break end
        local flags, width, dot, prec, conv = readConversion(pc)
        local whole = format:sub(pc, pc + #flags + #width + #dot + #prec + #conv)
        p = pc + #whole
        if conv == "%" then emit("%")
        elseif conv == "s" or conv == "b" or conv == "c" then
            local a = nextArg() or ""
            if conv == "b" then
                a, stop = escapes(a, true)
            elseif conv == "c" then a = a:sub(1, 1) end
            if dot ~= "" then a = a:sub(1, tonumber(prec) or 0) end
            emit(pad(a, flags, width))
            if stop then io.write(table.concat(out)); return ai, true end
        elseif isIntConversion(conv) then
            emit(integer(conv, flags, width, dot ~= "" and (prec ~= "" and prec or "0") or "",
                num(nextArg(), true)))
        elseif isFloatConversion(conv) then
            local v = num(nextArg(), false)
            if conv == "F" then conv = "f" end
            -- Lua refuses some specs C takes (a width over 99, repeated flags)
            local ok, s = pcall(string.format, "%" .. flags .. width .. dot .. prec .. conv, v)
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
