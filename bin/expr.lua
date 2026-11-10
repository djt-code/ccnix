-- expr.lua -- evaluate an expression and print the result (POSIX expr)
--
--   expr operand...
--
-- Every number, string and operator is its own argument (expr 1 + 2, not
-- expr 1+2).  The operators, loosest first, all left-associative:
--   a | b    a if it is neither empty nor 0, else b if that holds, else 0
--   a & b    a if neither a nor b is empty or 0, else 0
--   a = b, a != b, a < b, a <= b, a > b, a >= b
--            1 or 0; compared as integers when both are, else as strings
--   a + b, a - b, a * b, a / b, a % b    integers; / and % truncate
--   a : re   matches the basic regular expression re (regex.lua) at the
--            start of a: the number of bytes matched (0 if none), or with
--            \( \) the text the first group matched ("" if none)
--   ( expr ) grouping
-- An integer is digits with an optional leading "-".  A leading "--" is
-- skipped, so "expr -- -1 + 2" works.  The result is printed with a
-- newline; the exit status is 0 if it is neither empty nor 0, 1 if it is,
-- 2 for a bad expression (syntax, a non-integer in arithmetic, dividing by
-- zero, arithmetic beyond 2^53).  The stock shell's * is not a wildcard, so it needs no quoting.

package.path = (ccnix and ccnix.lib or "/" .. fs.getDir(fs.getDir(shell.getRunningProgram())) .. "/lib/?.lua;") .. package.path  -- ccnix's lib/, or the one beside bin/
local cu = require("cu").init("expr", "expr operand...")
local scan = require("scan")
local text = require("text")
local args = { ... }
if args[1] == "--" and #args > 1 then table.remove(args, 1) end
if #args == 0 then cu.usageError("missing operand") end

local function bad(msg) cu.err(msg); cu.exit(2) end
-- an integer: an optional "-", then digits
local function isInt(s)
    local digits = text.startsWith(s, "-") and s:sub(2) or s
    return digits ~= "" and scan.all(digits, scan.isDigit)
end
-- Lua numbers are doubles on CraftOS: past 2^53 they lose digits, so
-- arithmetic refuses them rather than print a wrong answer
local MAX = 2 ^ 53
local function num(s)
    local n = isInt(s) and tonumber(s) or bad("non-integer argument")
    if math.abs(n) >= MAX then bad(s .. ": integer out of range") end
    return n
end
local function str(n)
    if math.abs(n) >= MAX then bad("result out of range") end
    return n == 0 and "0" or string.format("%d", n)
end
local function zero(s) return s == "" or (isInt(s) and tonumber(s) == 0) end

-- an integer's sign ("-" or "") and its digits without the leading zeros
local function signAndDigits(s)
    local sign = ""
    if text.startsWith(s, "-") then sign, s = "-", s:sub(2) end
    local from = 1
    while s:sub(from, from) == "0" do from = from + 1 end
    return sign, s:sub(from)
end

-- compare two integers as text, -1, 0 or 1, exact at any length
local function icmp(a, b)
    local sa, da = signAndDigits(a)
    local sb, db = signAndDigits(b)
    local na, nb = sa == "-" and da ~= "", sb == "-" and db ~= ""
    if na ~= nb then return na and -1 or 1 end
    local c = 0
    if #da ~= #db then c = #da < #db and -1 or 1
    elseif da ~= db then c = da < db and -1 or 1 end
    return na and -c or c
end

local function compare(test)
    return function(a, b)
        local x, y = a, b
        if isInt(a) and isInt(b) then x, y = icmp(a, b), 0 end
        return test(x, y) and "1" or "0"
    end
end

-- math.fmod is exact, so the quotient is too (it truncates toward zero)
local function divide(a, b)
    local x, y = num(a), num(b)
    if y == 0 then bad("division by zero") end
    return str((x - math.fmod(x, y)) / y)
end

local function remainder(a, b)
    local y = num(b)
    if y == 0 then bad("division by zero") end
    return str(math.fmod(num(a), y))
end

-- a : re, a basic regular expression anchored at the start: the length of
-- the match, or with \( \) the text of the first group ("" if none)
local function match(s, re)
    local ok, regex = pcall(require, "regex")
    if not ok then cu.err("the : operator needs regex.lua"); cu.exit(3) end
    local r, err = regex.compile(re:sub(1, 1) == "^" and re or "^" .. re)
    if not r then bad(re .. ": " .. err) end
    local st, stop, caps = r:find(s)
    if r.ngroups > 0 then return st and caps[1] or "" end
    return st and str(stop - st + 1) or "0"
end

local pos = 1
local orExpr

local function primary()
    local t = args[pos]
    if t == nil then bad("syntax error") end
    pos = pos + 1
    if t == "(" and args[pos] ~= nil then
        local v = orExpr()
        if args[pos] ~= ")" then bad("syntax error") end
        pos = pos + 1
        return v
    end
    return t
end

-- one precedence level: sub { op sub }, folded left to right
local function level(sub, ops)
    return function()
        local v = sub()
        while ops[args[pos]] do
            local op = ops[args[pos]]
            pos = pos + 1
            v = op(v, sub())
        end
        return v
    end
end

local matchExpr = level(primary, { [":"] = match })
local mulExpr = level(matchExpr, {
    ["*"] = function(a, b) return str(num(a) * num(b)) end,
    ["/"] = divide,
    ["%"] = remainder,
})
local addExpr = level(mulExpr, {
    ["+"] = function(a, b) return str(num(a) + num(b)) end,
    ["-"] = function(a, b) return str(num(a) - num(b)) end,
})
local cmpExpr = level(addExpr, {
    ["="] = compare(function(x, y) return x == y end),
    ["!="] = compare(function(x, y) return x ~= y end),
    ["<"] = compare(function(x, y) return x < y end),
    ["<="] = compare(function(x, y) return x <= y end),
    [">"] = compare(function(x, y) return x > y end),
    [">="] = compare(function(x, y) return x >= y end),
})
local andExpr = level(cmpExpr, {
    ["&"] = function(a, b) return (zero(a) or zero(b)) and "0" or a end,
})
orExpr = level(andExpr, {
    ["|"] = function(a, b)
        if not zero(a) then return a end
        return not zero(b) and b or "0"
    end,
})

local v = orExpr()
if args[pos] ~= nil then bad("syntax error") end
io.write(v, "\n")
return cu.exit(zero(v) and 1 or 0)
