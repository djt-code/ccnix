-- find.lua -- find files by name, type, size or age (POSIX find)
--
--   find [-H|-L] [path...] [expression]
--
-- Walks each path (default ".") and every file and directory under it,
-- and evaluates the expression on each; with no -print, -exec or -ok in
-- it, the paths that match are printed one per line.  Primaries:
--   -name pat     the last part of the path matches the glob pat (* ? [a-z]
--                 [!a-z] and \ quoting; a leading "." is nothing special)
--   -path pat     the whole path matches pat (* also matches "/")
--   -type c       f a file, d a directory (b c l p s never match)
--   -size n[c]    n blocks of 512 bytes, rounded up, or n bytes with c
--   -mtime n      last modified n days ago (whole days)
--   -newer file   modified more recently than file
--   -print        write the path; -print0 ends it with a NUL instead
--   -prune        don't go into this directory
--   -exec cmd [arg...] ;    run cmd, "{}" standing for the path; true if
--                 it succeeded.  With + instead of ;, run cmd once at the
--                 end with all the paths in place of the "{}"
--   -ok cmd [arg...] ;      like -exec ;, but asks first (y to run); the
--                 question goes to stderr, the answer comes from the input
--   -depth        list a directory's contents before the directory
--   -xdev         don't go into other drives (/rom, disks are still tested)
--   -maxdepth n, -mindepth n   (common extensions) only test entries at
--                 most / at least n levels below the path
-- n can be +n (more than n) or -n (less than n).  Combine them with
-- ( expr ), ! expr, expr -a expr (or just side by side) and expr -o expr.
-- The shell has no backslashes, so end -exec with a plain ; (\; works too).
--   find . -name "*.lua" -size +4
--   find /disk -type f -exec rm {} ;

package.path = (ccnix and ccnix.lib or "/" .. fs.getDir(fs.getDir(shell.getRunningProgram())) .. "/lib/?.lua;") .. package.path  -- ccnix's lib/, or the one beside bin/
local cu = require("cu").init("find", "find [-H|-L] [path...] [expression]")
local scan = require("scan")
local text = require("text")
local args = { ... }
local i = 1
while args[i] == "-H" or args[i] == "-L" do i = i + 1 end     -- no links in CraftOS
if args[i] == "--" then i = i + 1 end
local paths = {}
while args[i] and not (args[i]:sub(1, 1) == "-" and #args[i] > 1) and args[i] ~= "!" and args[i] ~= "(" do
    paths[#paths + 1] = args[i]
    i = i + 1
end
if #paths == 0 then paths = { "." } end

local function bad(msg) cu.usageError(msg, 1) end

--------------------------------------------------------------------------
-- globs: a POSIX pattern read into a list of steps, then matched against
-- a whole name.  A step is "*" (any run of characters, "/" too) or a test
-- on one character: ? any, [set], or the character itself.
--------------------------------------------------------------------------
local CLASS = { alpha = scan.isAlpha, digit = scan.isDigit, alnum = scan.isAlnum, upper = scan.isUpper,
                lower = scan.isLower, space = scan.isSpace, punct = scan.isPunct, xdigit = scan.isHexDigit,
                cntrl = function(c) return c:byte() < 32 or c:byte() == 127 end }

local function anyChar() return true end
local function noChar() return false end
local function literal(ch) return function(c) return c == ch end end
local function byteRange(lo, hi) return function(c) return c:byte() >= lo and c:byte() <= hi end end

-- "[:" letters ":]" at k in pat: the class's name, or nil
local function className(pat, k)
    local sc = scan.new(pat, k)
    if not sc:accept("[:") then return nil end
    local name = sc:readWhile(scan.isAlpha)
    if name == "" or not sc:accept(":]") then return nil end
    return name
end

-- a bracket expression starting at j (the "["): its test and the index of
-- its "]", or nil if no "]" ends it (the "[" is then a plain character).
-- set: ("!" | "^")? item item*  "]", where an item is [:class:], c-c (a
-- range) or a character, and a "]" first in the set is a character.
local function bracket(pat, j)
    local k = j + 1
    local neg = pat:sub(k, k) == "!" or pat:sub(k, k) == "^"
    if neg then k = k + 1 end
    local tests, first = {}, true
    while k <= #pat and (first or pat:sub(k, k) ~= "]") do
        local cls = className(pat, k)
        local c, dash, hi = pat:sub(k, k), pat:sub(k + 1, k + 1), pat:sub(k + 2, k + 2)
        if cls and CLASS[cls] then
            tests[#tests + 1] = CLASS[cls]; k = k + #cls + 4
        elseif dash == "-" and hi ~= "" and hi ~= "]" then
            if c:byte() <= hi:byte() then tests[#tests + 1] = byteRange(c:byte(), hi:byte()) end
            k = k + 3
        else
            tests[#tests + 1] = literal(c); k = k + 1
        end
        first = false
    end
    if k > #pat then return nil end
    if #tests == 0 then return neg and anyChar or noChar, k end     -- an empty range such as [z-a]
    return function(ch)
        local inSet = false
        for _, test in ipairs(tests) do
            if test(ch) then inSet = true; break end
        end
        return inSet ~= neg
    end, k
end

-- the steps of a glob: "*" for a star, else a test on one character
local function readGlob(pat)
    local steps, j = {}, 1
    while j <= #pat do
        local c = pat:sub(j, j)
        if c == "*" then steps[#steps + 1] = "*"
        elseif c == "?" then steps[#steps + 1] = anyChar
        elseif c == "\\" and j < #pat then j = j + 1; steps[#steps + 1] = literal(pat:sub(j, j))
        elseif c == "[" then
            local test, close = bracket(pat, j)
            steps[#steps + 1] = test or literal("[")
            j = close or j
        else steps[#steps + 1] = literal(c) end
        j = j + 1
    end
    return steps
end

-- do steps k on match s from i to its end?  (a star tries every length)
local function matchSteps(steps, k, s, i)
    while k <= #steps do
        local step = steps[k]
        if step == "*" then
            for at = i, #s + 1 do
                if matchSteps(steps, k + 1, s, at) then return true end
            end
            return false
        end
        if i > #s or not step(s:sub(i, i)) then return false end
        i, k = i + 1, k + 1
    end
    return i > #s
end

-- glob pat as a test on a whole name
local function glob(pat)
    local steps = readGlob(pat)
    return function(s) return matchSteps(steps, 1, s, 1) end
end

--------------------------------------------------------------------------
-- the expression: parsed into functions of the entry e
--------------------------------------------------------------------------
local hasAction, depthFirst, xdev = false, false, false
local minDepth, maxDepth = 0, math.huge
local batches = {}      -- -exec ... + commands: { cmd, paths }

-- "+n", "-n" or "n" to a test on a number
-- number: ("+" | "-")? digit+ letter?; the sign, the digits and the
-- letter ("" when left out), or nil
local function readNumber(s)
    local sc, sign = scan.new(s), ""
    if sc:accept("+") then sign = "+" elseif sc:accept("-") then sign = "-" end
    local n = sc:readWhile(scan.isDigit)
    local suf = scan.isAlpha(sc:peek()) and sc:advance() or ""
    if n == "" or not sc:atEnd() then return nil end
    return sign, n, suf
end

local function compare(s, what, suffix)
    local sign, n, suf = readNumber(s or "")
    if not n or (suf ~= "" and suf ~= suffix) then bad(what .. ": bad number -- " .. tostring(s)) end
    n = tonumber(n)
    local f
    if sign == "+" then f = function(x) return x > n end
    elseif sign == "-" then f = function(x) return x < n end
    else f = function(x) return x == n end end
    return f, suf ~= ""
end

local function mtime(p) return fs.attributes(p).modified end
local started = os.epoch("utc")     -- -mtime counts days back from here

local function nextArg(what)
    i = i + 1
    if args[i] == nil then bad("missing argument to " .. what) end
    return args[i]
end

-- the words of an -exec/-ok command up to ; or +
local function command(what)
    local words, plus = {}, false
    i = i + 1
    while true do
        local a = args[i]
        if a == nil then bad("missing ; after " .. what) end
        if a == ";" or a == "\\;" then break end
        if a == "+" and words[#words] == "{}" and what == "-exec" then plus = true; break end
        words[#words + 1] = a
        i = i + 1
    end
    if #words == 0 then bad("missing command after " .. what) end
    return words, plus
end

local function run(words, path)
    local t = {}
    for k, w in ipairs(words) do t[k] = w == "{}" and path or w end
    return shell.execute(table.unpack(t))
end

local primary = {}
function primary.name()
    local matches = glob(nextArg("-name"))
    return function(e) return matches(e.name) end
end
function primary.path()
    local matches = glob(nextArg("-path"))
    return function(e) return matches(e.path) end
end
primary["type"] = function()
    local c = nextArg("-type")
    if not ("bcdflps"):find(c, 1, true) or #c ~= 1 then bad("-type: unknown type -- " .. c) end
    return function(e)
        if c == "d" then return e.dir end
        return c == "f" and not e.dir
    end
end
function primary.size()
    local test, bytes = compare(nextArg("-size"), "-size", "c")
    return function(e)
        local n = e.dir and 0 or fs.getSize(e.p)
        return test(bytes and n or math.ceil(n / 512))
    end
end
function primary.mtime()
    local test = compare(nextArg("-mtime"), "-mtime")
    return function(e) return test(math.floor((started - mtime(e.p)) / 86400000)) end
end
function primary.newer()
    local f = nextArg("-newer")
    local p = shell.resolve(f)
    if not fs.exists(p) then cu.fail(f .. ": No such file or directory"); cu.exit() end
    local t = mtime(p)
    return function(e) return mtime(e.p) > t end
end
function primary.print()
    hasAction = true
    return function(e) io.write(e.path, "\n"); return true end
end
function primary.print0()
    hasAction = true
    return function(e) io.write(e.path, "\0"); return true end
end
function primary.prune() return function(e) e.prune = true; return true end end
function primary.depth() depthFirst = true; return function() return true end end
function primary.xdev() xdev = true; return function() return true end end
local function count(what)
    local n = cu.int(nextArg(what))
    if not n or n < 0 then bad(what .. ": bad number -- " .. args[i]) end
    return n
end
function primary.maxdepth() maxDepth = count("-maxdepth"); return function() return true end end
function primary.mindepth() minDepth = count("-mindepth"); return function() return true end end
primary.exec = function()
    hasAction = true
    local words, plus = command("-exec")
    if not plus then return function(e) return run(words, e.path) end end
    local b = { words = words, paths = {} }
    batches[#batches + 1] = b
    return function(e) b.paths[#b.paths + 1] = e.path; return true end
end
function primary.ok()
    hasAction = true
    local words = command("-ok")
    return function(e)
        local t = {}
        for k, w in ipairs(words) do t[k] = w == "{}" and e.path or w end
        io.stderr:write("< " .. table.concat(t, " ") .. " > ? ")
        local answer = cu.readLine(io.input()) or ""
        local first = answer:sub(1, 1)
        return (first == "y" or first == "Y") and run(words, e.path)
    end
end

local orExpr
local function unary()
    local a = args[i]
    if a == "!" then
        i = i + 1
        local f = unary()
        return function(e) return not f(e) end
    elseif a == "(" then
        i = i + 1
        local f = orExpr()
        if args[i] ~= ")" then bad("missing )") end
        i = i + 1
        return f
    elseif a == nil or a == ")" or a == "-o" or a == "-a" then
        bad("expression expected" .. (a and " before " .. a or ""))
    end
    local make = a:sub(1, 1) == "-" and primary[a:sub(2)]
    if not make then bad("unknown primary -- " .. a) end
    local f = make()
    i = i + 1
    return f
end
local function andExpr()
    local f = unary()
    while args[i] and args[i] ~= "-o" and args[i] ~= ")" do
        if args[i] == "-a" then i = i + 1 end
        local l, r = f, unary()
        f = function(e) return l(e) and r(e) end
    end
    return f
end
function orExpr()
    local f = andExpr()
    while args[i] == "-o" do
        i = i + 1
        local l, r = f, andExpr()
        f = function(e) return l(e) or r(e) end
    end
    return f
end

local expr = function() return true end
if args[i] then
    expr = orExpr()
    if args[i] then bad("unexpected " .. args[i]) end
end
if not hasAction then
    local test = expr
    expr = function(e)
        if test(e) then io.write(e.path, "\n") end
        return true
    end
end

--------------------------------------------------------------------------
-- the walk
--------------------------------------------------------------------------
local seen = 0
local function visit(p, path, depth, drive)
    -- yield now and then, or a big tree trips "Too long without yielding"
    seen = seen + 1
    if seen % 200 == 0 then os.queueEvent("find"); os.pullEvent("find") end
    local e = { p = p, path = path, depth = depth, dir = fs.isDir(p) }
    local to = #path
    while to > 0 and path:sub(to, to) == "/" do to = to - 1 end     -- (the slashes at the end dropped)
    local trimmed = path:sub(1, to)
    local _, last = text.cutLast(trimmed, "/")
    e.name = trimmed == "" and "/" or last or trimmed
    local test = depth >= minDepth and depth <= maxDepth
    if test and not depthFirst then expr(e) end
    -- -xdev: a mount point (/rom, a disk) is tested but not gone into
    if e.dir and (depthFirst or not e.prune) and depth < maxDepth and not (xdev and fs.getDrive(p) ~= drive) then
        local ok, names = pcall(fs.list, p)
        if not ok then cu.fail(path .. ": " .. tostring(names)); names = {} end
        for _, name in ipairs(names) do
            visit(fs.combine(p, name), (path:sub(-1) == "/" and path or path .. "/") .. name, depth + 1, drive)
        end
    end
    if test and depthFirst then expr(e) end
end

for _, path in ipairs(paths) do
    local p = shell.resolve(path)
    if fs.exists(p) then visit(p, path, 0, fs.getDrive(p))
    else cu.fail(path .. ": No such file or directory") end
end
for _, b in ipairs(batches) do
    if #b.paths > 0 then
        -- the last word is the "{}" before the +: the paths go there
        local t = { table.unpack(b.words, 1, #b.words - 1) }
        for _, path in ipairs(b.paths) do t[#t + 1] = path end
        if not shell.execute(table.unpack(t)) then cu.status = math.max(cu.status, 1) end
    end
end
return cu.exit()
