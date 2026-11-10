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
--   member:  "[:" name ":]"   a POSIX class: alpha digit alnum upper lower
--                             space blank punct print graph cntrl xdigit
--            c "-" c          a range, by byte
--            c                (c may be "" and a character, as outside)
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
-- glob.escape(s)      s with \ before each * ? [ ] \ - ! and ^, so it
--                     matches only itself, inside a class too (a shell
--                     escapes its quoted characters so)

local scan = require("scan")

local glob = {}

local ANY, ONE = { any = true }, { one = true }

-- one member character: "\" and the character after it (when escapes are
-- on), or the character
local function readMemberChar(sc, opts)
    if opts.escapes ~= false and sc:at("\\") and sc:peek(2) ~= "" then sc:advance() end
    return sc:advance()
end

-- A class starting at pattern's index k (the "["): the item, a list of
-- tests on one character, and the index of its "]"; nil if no "]"
-- closes it.
local function readClass(pattern, k, opts)
    local sc = scan.new(pattern, k + 1)
    local neg = sc:accept("!") or sc:accept("^")
    local tests, first = {}, true
    while not sc:atEnd() do
        if sc:at("]") and not first then return { tests = tests, neg = neg }, sc:pos() end
        first = false
        local close = sc:at("[:") and pattern:find(":]", sc:pos() + 2, true)
        local named = close and scan.posixClasses[pattern:sub(sc:pos() + 2, close - 1)]
        if named then
            tests[#tests + 1] = named
            sc:setPos(close + 2)
        else
            local lo = readMemberChar(sc, opts)
            if sc:at("-") and sc:peek(2) ~= "]" and sc:peek(2) ~= "" then
                sc:advance()
                local hi = readMemberChar(sc, opts)
                tests[#tests + 1] = function(c) return c >= lo and c <= hi end
            else
                tests[#tests + 1] = function(c) return c == lo end
            end
        end
    end
    return nil
end

-- The pattern as a list of items, and whether any is a wildcard.
local function readItems(pattern, opts)
    local items, wild, k = {}, false, 1
    while k <= #pattern do
        local c = pattern:sub(k, k)
        local class, close
        if c == "[" and opts.classes ~= false then class, close = readClass(pattern, k, opts) end
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
    local inside = false
    for _, test in ipairs(item.tests) do
        if test(ch) then inside = true; break end
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

local SPECIAL = { ["*"] = true, ["?"] = true, ["["] = true, ["]"] = true, ["\\"] = true,
                  ["-"] = true, ["!"] = true, ["^"] = true }

function glob.escape(s)
    local out = {}
    for i = 1, #s do
        local c = s:sub(i, i)
        out[i] = SPECIAL[c] and "\\" .. c or c
    end
    return table.concat(out)
end

return glob
