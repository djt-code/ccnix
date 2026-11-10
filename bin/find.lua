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
local convert = require("convert")
local glob = require("glob")
local path = require("path")
local args = { ... }
local i = 1
while args[i] == "-H" or args[i] == "-L" do i = i + 1 end     -- no links in CraftOS
if args[i] == "--" then i = i + 1 end
local paths = {}
while args[i] and not (text.startsWith(args[i], "-") and #args[i] > 1) and args[i] ~= "!" and args[i] ~= "(" do
    paths[#paths + 1] = args[i]
    i = i + 1
end
if #paths == 0 then paths = { "." } end

local function bad(msg) cu.usageError(msg, 1) end

--------------------------------------------------------------------------
-- the expression: parsed into functions of the entry e
--------------------------------------------------------------------------
local hasAction, depthFirst, xdev = false, false, false
local minDepth, maxDepth = 0, math.huge
local batches = {}      -- -exec ... + commands: { cmd, paths }

-- what a sign before n asks of a number x: more than n, less than n (and
-- with none, n itself)
local SIGN_TESTS = {
    ["+"] = function(n) return function(x) return x > n end end,
    ["-"] = function(n) return function(x) return x < n end end,
}

-- "+n", "-n" or "n", then the unit letter suffix or none, as a test on a
-- number; and whether the suffix was there.
--   number: ("+" | "-")? digit+ letter?
local function compare(s, what, suffix)
    local sc = scan.new(s or "")
    local value, written = sc:readInteger()
    local unit = scan.isAlpha(sc:peek()) and sc:advance() or ""
    if not value or not sc:atEnd() or (unit ~= "" and unit ~= suffix) then
        bad(what .. ": bad number -- " .. tostring(s))
    end
    local n = math.abs(value)
    local signed = SIGN_TESTS[written:sub(1, 1)]
    return signed and signed(n) or function(x) return x == n end, unit ~= ""
end

local function mtime(p) return cu.mtime(p) or 0 end
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

-- an -exec/-ok command's words with each "{}" made the path found
local function withPath(words, found)
    local t = {}
    for k, w in ipairs(words) do t[k] = w == "{}" and found or w end
    return t
end
local function run(words, found) return shell.execute(table.unpack(withPath(words, found))) end

local primary = {}
function primary.name()
    local matches = glob.compile(nextArg("-name"))
    return function(e) return matches(e.name) end
end
function primary.path()
    local matches = glob.compile(nextArg("-path"))
    return function(e) return matches(e.path) end
end
-- -type's letters, each as a test on an entry (CraftOS has no block or
-- character devices, links, pipes or sockets)
local function never() return false end
local FILE_TYPES = {
    d = function(e) return e.dir end,
    f = function(e) return not e.dir end,
    b = never, c = never, l = never, p = never, s = never,
}
primary["type"] = function()
    local c = nextArg("-type")
    if not FILE_TYPES[c] then bad("-type: unknown type -- " .. c) end
    return FILE_TYPES[c]
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
    local n = convert.toInteger(nextArg(what))
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
        io.stderr:write("< " .. table.concat(withPath(words, e.path), " ") .. " > ? ")
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
    local name = text.stripPrefix(a, "-")
    local make = name and primary[name]
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
-- p the entry on disk, shown the path it is printed as
local function visit(p, shown, depth, drive)
    cu.breathe()        -- (a big tree takes a while)
    local e = { p = p, path = shown, depth = depth, dir = fs.isDir(p), name = path.basename(shown) }
    local test = depth >= minDepth and depth <= maxDepth
    if test and not depthFirst then expr(e) end
    -- -xdev: a mount point (/rom, a disk) is tested but not gone into
    if e.dir and (depthFirst or not e.prune) and depth < maxDepth and not (xdev and fs.getDrive(p) ~= drive) then
        local ok, names = pcall(fs.list, p)
        if not ok then cu.fail(shown .. ": " .. tostring(names)); names = {} end
        for _, name in ipairs(names) do
            visit(fs.combine(p, name), path.join(shown, name), depth + 1, drive)
        end
    end
    if test and depthFirst then expr(e) end
end

for _, start in ipairs(paths) do
    local p = shell.resolve(start)
    if fs.exists(p) then visit(p, start, 0, fs.getDrive(p))
    else cu.fail(start .. ": No such file or directory") end
end
for _, b in ipairs(batches) do
    if #b.paths > 0 then
        -- the last word is the "{}" before the +: the paths go there
        local t = { table.unpack(b.words, 1, #b.words - 1) }
        for _, found in ipairs(b.paths) do t[#t + 1] = found end
        if not shell.execute(table.unpack(t)) then cu.status = math.max(cu.status, 1) end
    end
end
return cu.exit()
