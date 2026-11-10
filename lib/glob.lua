-- glob.lua -- wildcard patterns: * ? [...]
--
--   local glob = require("glob")
--   glob.match("*.lua", "init.lua")              --> true
--   local isLog = glob.compile("[a-z]*.log")     -- a test, to use again
--   isLog("sys.log")                             --> true
--   glob.match("*!*@*.example", "Bob!b@host.example", { classes = false, fold = string.lower })
--
-- A pattern matches a whole string:
--   pattern: item*
--   item:    "*"             any run of characters (none too)
--            "?"             any one character
--            class           one character in (or not in) the set
--            "\" c           c as it is (unless escapes = false)
--            c               any other character, as it is
--   class:   "[" ("!" | "^")? "]"? member* "]"   (a ] first is a member;
--                                                 with no closing ], "[" is
--                                                 itself)
--   member:  c "-" c (a range, by byte) | c
-- Nothing special about "/" or a leading ".": the shell and find, which
-- care, split paths and look at dots themselves.
--
-- opts, for compile and match:
--   escapes = false   "\" is an ordinary character (IRC masks: nicks have \)
--   classes = false   "[" is an ordinary character (... and [ ])
--   fold = f          both sides go through f first (string.lower, or an
--                     IRC casemapping)
--
-- glob.compile(pattern [, opts])   the pattern as a test: f(s) -> true/false
-- glob.match(pattern, s [, opts])  the same, once
-- glob.hasWildcards(pattern [, opts])  true if pattern has a * ? or class
--                     that isn't escaped (so it's more than a plain name)
-- glob.escape(s)      s with \ before each * ? [ ] and \, so it matches
--                     only itself

local glob = {}

local ANY, ONE = { any = true }, { one = true }

-- A class starting at pattern's index k (the "["): the item and the index
-- of its "]"; nil if no "]" closes it.
local function readClass(pattern, k)
    local j = k + 1
    local neg = pattern:sub(j, j) == "!" or pattern:sub(j, j) == "^"
    if neg then j = j + 1 end
    local e = pattern:sub(j, j) == "]" and j + 1 or j        -- (a ] first is a member)
    while e <= #pattern and pattern:sub(e, e) ~= "]" do e = e + 1 end
    if e > #pattern then return nil end
    local ranges, m = {}, j
    while m < e do
        local lo = pattern:byte(m)
        if pattern:sub(m + 1, m + 1) == "-" and m + 2 < e then
            ranges[#ranges + 1] = { lo, pattern:byte(m + 2) }
            m = m + 3
        else
            ranges[#ranges + 1] = { lo, lo }
            m = m + 1
        end
    end
    return { ranges = ranges, neg = neg }, e
end

-- The pattern as a list of items, and whether any is a wildcard.
local function readItems(pattern, opts)
    local items, wild, k = {}, false, 1
    while k <= #pattern do
        local c = pattern:sub(k, k)
        local class, close
        if c == "[" and opts.classes ~= false then class, close = readClass(pattern, k) end
        if c == "*" then items[#items + 1] = ANY; wild = true
        elseif c == "?" then items[#items + 1] = ONE; wild = true
        elseif class then items[#items + 1] = class; wild = true; k = close
        elseif c == "\\" and opts.escapes ~= false and k < #pattern then
            k = k + 1
            items[#items + 1] = { lit = pattern:sub(k, k) }
        else
            items[#items + 1] = { lit = c }
        end
        k = k + 1
    end
    return items, wild
end

-- true if item (not a *) takes the one character ch
local function takes(item, ch)
    if item.lit then return ch == item.lit end
    if item.one then return true end
    local b, inside = ch:byte(), false
    for _, r in ipairs(item.ranges) do
        if b >= r[1] and b <= r[2] then inside = true; break end
    end
    return inside ~= item.neg
end

-- Do items match all of s?  On a mismatch, the last * takes one more
-- character and the rest is tried again (no recursion, so many *s don't
-- blow up).
local function matches(items, s)
    local p, i = 1, 1
    local starP, starI
    while i <= #s do
        local item = items[p]
        if item == ANY then
            starP, starI, p = p, i, p + 1
        elseif item and takes(item, s:sub(i, i)) then
            p, i = p + 1, i + 1
        elseif starP then
            starI = starI + 1
            p, i = starP + 1, starI
        else
            return false
        end
    end
    while items[p] == ANY do p = p + 1 end
    return p > #items
end

function glob.compile(pattern, opts)
    opts = opts or {}
    local fold = opts.fold
    local items = readItems(fold and fold(pattern) or pattern, opts)
    return function(s)
        return matches(items, fold and fold(s) or s)
    end
end

function glob.match(pattern, s, opts) return glob.compile(pattern, opts)(s) end

function glob.hasWildcards(pattern, opts)
    local _, wild = readItems(pattern, opts or {})
    return wild
end

local SPECIAL = { ["*"] = true, ["?"] = true, ["["] = true, ["]"] = true, ["\\"] = true }

function glob.escape(s)
    local out = {}
    for i = 1, #s do
        local c = s:sub(i, i)
        out[i] = SPECIAL[c] and "\\" .. c or c
    end
    return table.concat(out)
end

return glob
