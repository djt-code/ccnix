-- test.lua -- evaluate a condition and exit 0 (true) or 1 (false) (POSIX test)
--
--   test [expression]
--   [ [expression] ]          (in ccsh, a builtin that runs this with the last ] dropped)
--
-- Nothing is printed: the answer is the exit status, 0 true, 1 false, 2 for
-- an error.  Files are relative to the shell's directory.
--   -e f  f exists           -f f  a file          -d f  a directory
--   -s f  a file, not empty  -r f  exists          -w f  exists, not read-only
--   -x f  a directory, or a program (a file named *.lua or with no extension)
--   -n s  s is not empty     -z s  s is empty      s     s is not empty
--   -t fd fd 0 is the keyboard, 1 the screen (not redirected), 2 always
--   -b -c -p -S -h -L -g -u -k: always false (CraftOS has no such files)
--   s1 = s2, s1 != s2, s1 < s2, s1 > s2       strings (byte order)
--   n1 -eq -ne -lt -le -gt -ge n2             integers
--   f1 -nt f2, f1 -ot f2 (modification time), f1 -ef f2 (the same path)
--   ! expr, expr -a expr, expr -o expr, ( expr )
-- One to four arguments follow the POSIX rules by count; -a, -o and the
-- parentheses (removed from POSIX.1-2024, kept for old scripts) and longer
-- expressions go through a parser where ! binds tightest, then -a, then -o.
-- Remember the stock shell splits on spaces: quote "" for an empty string.

package.path = (ccnix and ccnix.lib or "/" .. fs.getDir(fs.getDir(shell.getRunningProgram())) .. "/lib/?.lua;") .. package.path  -- ccnix's lib/, or the one beside bin/
local cu = require("cu").init("test", "test [expression]")
local scan = require("scan")
local args = { ... }

local function bad(msg) cu.err(msg); cu.exit(2) end

-- fs calls that answer false for a path CraftOS rejects (above the root);
-- "" names no file, though shell.resolve would make it the current folder
local function try(f, p)
    if p == "" then return false end
    local ok, r = pcall(f, shell.resolve(p))
    return ok and r
end
local function isFile(p) return try(fs.exists, p) and not try(fs.isDir, p) end
local function mtime(p)
    local a = try(fs.attributes, p)
    if a then return a.modified or a.modification end
end
local function int(s) return cu.int(s) or bad(s .. ": integer expression expected") end
local function no() return false end

-- an integer's sign ("+", "-" or "") and its digits without the leading zeros
local function signAndDigits(s)
    local sign = ""
    if scan.startsWith(s, "+") or scan.startsWith(s, "-") then sign, s = s:sub(1, 1), s:sub(2) end
    local from = 1
    while s:sub(from, from) == "0" do from = from + 1 end
    return sign, s:sub(from)
end

-- compare two integers as text, -1, 0 or 1, so that numbers past 2^53
-- (where Lua's doubles lose digits) still compare exactly
local function icmp(a, b)
    int(a); int(b)
    local sa, da = signAndDigits(a)
    local sb, db = signAndDigits(b)
    local na, nb = sa == "-" and da ~= "", sb == "-" and db ~= ""
    if na ~= nb then return na and -1 or 1 end
    local c = 0
    if #da ~= #db then c = #da < #db and -1 or 1
    elseif da ~= db then c = da < db and -1 or 1 end
    return na and -c or c
end

local UNARY = {
    ["-e"] = function(p) return try(fs.exists, p) end,
    ["-f"] = isFile,
    ["-d"] = function(p) return try(fs.isDir, p) end,
    ["-s"] = function(p) return isFile(p) and try(fs.getSize, p) > 0 end,
    ["-r"] = function(p) return try(fs.exists, p) end,
    ["-w"] = function(p) return try(fs.exists, p) and not try(fs.isReadOnly, p) end,
    ["-x"] = function(p)
        if try(fs.isDir, p) then return true end
        local n = fs.getName(shell.resolve(p))
        return isFile(p) and (scan.endsWith(n, ".lua") or not n:find(".", 1, true))
    end,
    ["-n"] = function(s) return s ~= "" end,
    ["-z"] = function(s) return s == "" end,
    ["-t"] = function(fd)
        fd = int(fd)
        if fd == 0 then return cu.isKeyboard() end
        if fd == 1 then return cu.isTerminal() end
        return fd == 2
    end,
    ["-b"] = no, ["-c"] = no, ["-p"] = no, ["-S"] = no, ["-h"] = no, ["-L"] = no,
    ["-g"] = no, ["-u"] = no, ["-k"] = no,
}

local BINARY = {
    ["="] = function(a, b) return a == b end,
    ["!="] = function(a, b) return a ~= b end,
    ["<"] = function(a, b) return a < b end,
    [">"] = function(a, b) return a > b end,
    ["-eq"] = function(a, b) return icmp(a, b) == 0 end,
    ["-ne"] = function(a, b) return icmp(a, b) ~= 0 end,
    ["-lt"] = function(a, b) return icmp(a, b) < 0 end,
    ["-le"] = function(a, b) return icmp(a, b) <= 0 end,
    ["-gt"] = function(a, b) return icmp(a, b) > 0 end,
    ["-ge"] = function(a, b) return icmp(a, b) >= 0 end,
    ["-nt"] = function(a, b)
        local x, y = mtime(a), mtime(b)
        return x ~= nil and (y == nil or x > y)
    end,
    ["-ot"] = function(a, b)
        local x, y = mtime(a), mtime(b)
        return y ~= nil and (x == nil or x < y)
    end,
    ["-ef"] = function(a, b)
        return try(fs.exists, a) and try(fs.exists, b)
            and fs.combine(shell.resolve(a)) == fs.combine(shell.resolve(b))
    end,
    ["-a"] = function(a, b) return a ~= "" and b ~= "" end,
    ["-o"] = function(a, b) return a ~= "" or b ~= "" end,
}

-- The POSIX rules for one to four arguments; nil where they leave it open.
local function two(a, b)
    if a == "!" then return b == "" end
    if UNARY[a] then return UNARY[a](b) end
end
local function three(a, b, c)
    if BINARY[b] then return BINARY[b](a, c) end
    if a == "!" then
        local r = two(b, c)
        if r ~= nil then return not r end
    end
    if a == "(" and c == ")" then return b ~= "" end
end
local function four(a, b, c, d)
    if a == "!" then
        local r = three(b, c, d)
        if r ~= nil then return not r end
    end
    if a == "(" and d == ")" then return two(b, c) end
end

-- The general parser: or := and { -o and }, and := not { -a not },
-- not := ! not | primary, primary := ( or ) | s1 op s2 | -x s | s.
local pos = 1
local orExpr
local function primary()
    local a = args[pos]
    if a == nil then bad("argument expected") end
    if a == "(" and args[pos + 1] ~= nil then
        pos = pos + 1
        local r = orExpr()
        if args[pos] ~= ")" then bad("missing )") end
        pos = pos + 1
        return r
    end
    local op = args[pos + 1]
    if BINARY[op] and op ~= "-a" and op ~= "-o" and args[pos + 2] ~= nil then
        pos = pos + 3
        return BINARY[op](a, args[pos - 1])
    end
    if UNARY[a] and op ~= nil then
        pos = pos + 2
        return UNARY[a](op)
    end
    pos = pos + 1
    return a ~= ""
end
local function notExpr()
    if args[pos] == "!" and args[pos + 1] ~= nil then
        pos = pos + 1
        return not notExpr()
    end
    return primary()
end
local function andExpr()
    local r = notExpr()
    while args[pos] == "-a" do
        pos = pos + 1
        local r2 = notExpr()
        r = r and r2
    end
    return r
end
function orExpr()
    local r = andExpr()
    while args[pos] == "-o" do
        pos = pos + 1
        local r2 = andExpr()
        r = r or r2
    end
    return r
end

local n, r = #args, nil
if n == 0 then r = false
elseif n == 1 then r = args[1] ~= ""
elseif n == 2 then
    r = two(args[1], args[2])
    if r == nil then bad(args[1] .. ": unary operator expected") end
elseif n == 3 then r = three(args[1], args[2], args[3])
elseif n == 4 then r = four(args[1], args[2], args[3], args[4])
end
if r == nil then
    r = orExpr()
    if args[pos] ~= nil then bad(args[pos] .. ": unexpected argument") end
end
return cu.exit(r and 0 or 1)
