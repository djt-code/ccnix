-- seq.lua -- print a sequence of numbers (as GNU's seq; not in POSIX)
--
--   seq [-w] [-s sep] [-f format] [first [increment]] last
--
-- Prints the numbers from first (1) to last, increment (1) apart, one a
-- line: `seq 3` is 1 2 3, `seq 0 5 20` 0 5 10 15 20, `seq 5 -1 1` counts
-- down.  Decimals and negative numbers work (`seq -1 0.5 1`); the numbers
-- are printed with as many decimal places as first or increment has.
-- Nothing is printed if last comes before first.
--   -s sep     between the numbers instead of a newline (one still ends
--              the line).  C's escapes in it count: \t a tab, \n a
--              newline, \\ a backslash, \ooo octal, and \a \b \f \r \v
--              (GNU's seq leaves that to the shell).
--   -w         the same width for all: leading zeros (seq -w 8 10: 08 09 10)
--   -f format  each number through a printf floating-point format, such as
--              %.2f, %g or %05.1f (one %e, %f or %g, and %% for a %)
-- Exit status 1 for a bad number, a zero increment or bad options.

package.path = (ccnix and ccnix.lib or "/" .. fs.getDir(fs.getDir(shell.getRunningProgram())) .. "/lib/?.lua;") .. package.path  -- ccnix's lib/, or the one beside bin/
local cu = require("cu").init("seq", "seq [-w] [-s sep] [-f format] [first [increment]] last")
local scan = require("scan")
local text = require("text")
local convert = require("convert")

-- Options come first; a negative number ends them (seq -2 2) unless it's
-- -s's or -f's argument (seq -s -1 5).  cu.getopt would take it for an
-- option, so a "--" goes in before it.
local function isNegativeNumber(a) return text.startsWith(a, "-") and scan.isNumber(a) end
local function isOption(a) return text.startsWith(a, "-") and #a > 1 and not isNegativeNumber(a) end
local args, i = { ... }, 1
while args[i] and isOption(args[i]) and args[i] ~= "--" do
    i = i + ((args[i] == "-s" or args[i] == "-f") and 2 or 1)
end
if args[i] and isNegativeNumber(args[i]) then table.insert(args, i, "--") end
local opts, ops = cu.getopt(args, "ws:f:", 1)
if #ops == 0 then cu.usageError("missing operand", 1) end
if #ops > 3 then cu.usageError("extra operand '" .. ops[4] .. "'", 1) end
if opts.w and opts.f then cu.usageError("-f and -w can't go together", 1) end

-- The decimal places of number s (a decimal, scan.isNumber): the digits
-- after its point, less its exponent.
--   number: sign? digit* ("." digit*)? (("e" | "E") sign? digit+)?
local function decimalPlaces(s)
    local sc = scan.new(s)
    local _ = sc:accept("+") or sc:accept("-")
    sc:readWhile(scan.isDigit)
    local fraction = sc:accept(".") and sc:readWhile(scan.isDigit) or ""
    local exponent = (sc:accept("e") or sc:accept("E")) and sc:readInteger() or 0
    return #fraction - exponent
end

-- a number, and its decimal places
local function number(s)
    local v = convert.toNumber(s)
    if not v or v ~= v or v == math.huge or v == -math.huge then
        cu.fail("invalid floating point argument: '" .. s .. "'")
        cu.exit()
    end
    return v, math.max(0, decimalPlaces(s))
end

local first, step, last = 1, 1, nil
local p1, p2 = 0, 0
if #ops == 1 then last = number(ops[1])
elseif #ops == 2 then first, p1 = number(ops[1]); last = number(ops[2])
else first, p1 = number(ops[1]); step, p2 = number(ops[2]); last = number(ops[3]) end
if step == 0 then cu.fail("invalid Zero increment value: '" .. ops[2] .. "'"); return cu.exit() end

local isFlag = scan.oneOf("-+ #0")
local isFloatConversion = scan.oneOf("eEfgG")

-- format with each %% taken out (read left to right, as printf does)
local function withoutPercents(format)
    local out, sc = {}, scan.new(format)
    while not sc:atEnd() do
        if not sc:accept("%%") then out[#out + 1] = sc:advance() end
    end
    return table.concat(out)
end

-- does a % in format start a conversion: % flags* digit* ("." digit*)? and
-- one of e E f g G?
local function isConversion(sc)
    if not sc:accept("%") then return false end
    sc:readWhile(isFlag)
    sc:readWhile(scan.isDigit)
    if sc:accept(".") then sc:readWhile(scan.isDigit) end
    return isFloatConversion(sc:peek())
end

-- one % in it (after the %% are out), starting a floating-point conversion?
local function oneFloatConversion(format)
    local probe = withoutPercents(format)
    local at = probe:find("%", 1, true)
    if not at or probe:find("%", at + 1, true) then return false end
    return isConversion(scan.new(probe, at))
end

local format = opts.f
if format then
    if not oneFloatConversion(format) then
        cu.fail("format '" .. format .. "' needs exactly one %e, %f or %g")
        return cu.exit()
    end
end
local places = math.max(p1, p2)
local function show(v)
    if format then return string.format(format, v) end
    local s = string.format("%." .. places .. "f", v)
    -- (no "-0": "-0", then a point or not, then only zeros)
    local afterZero = s:sub(3)
    afterZero = text.stripPrefix(afterZero, ".") or afterZero
    if text.startsWith(s, "-0") and scan.all(afterZero, scan.oneOf("0")) then s = s:sub(2) end
    return s
end
local width = opts.w and math.max(#show(first), #show(last)) or 0
local function padded(v)
    local s = show(v)
    if #s >= width then return s end
    local digits = text.stripPrefix(s, "-")
    if digits then return "-" .. text.padLeft(digits, width - 1, "0") end
    return text.padLeft(s, width, "0")
end

-- -s's text with C's escapes (\t \n \\ \ooo ...) made into what they
-- stand for
local sep = opts.s and convert.unescape(opts.s) or "\n"
-- first + k * step, not a running sum, so no error creeps in
local slack = math.abs(step) * 1e-9
local n = 0
while true do
    local v = first + n * step
    if (step > 0 and v > last + slack) or (step < 0 and v < last - slack) then break end
    if n > 0 then io.write(sep) end
    io.write(padded(v))
    n = n + 1
    if n % 1000 == 0 then os.queueEvent("seq"); os.pullEvent("seq") end
end
if n > 0 then io.write("\n") end
return cu.exit()
