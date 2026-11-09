-- regex.lua -- POSIX regular expressions (BRE and ERE) for the utilities
--
--   local regex = require("regex")
--   local re, err = regex.compile(pattern, { ere = true, icase = true })
--   re:test(s [, whole])     true if s has a match (whole: s matches entirely)
--   re:find(s [, init])      start, stop, captures: the leftmost-longest match
--
-- Lua patterns are not POSIX regexes, so this is a small backtracking
-- matcher of its own.  Both kinds have literals, ".", bracket expressions
-- ([a-z], [^...], [[:alpha:]], [[.x.]], [=x=]), the anchors ^ and $, "*"
-- and back-references \1..\9.  A BRE adds \( \) groups and \{m,n\}
-- intervals; "^" is an anchor only at the start (or after "\("), "$" only
-- at the end (or before "\)"), and "*" at the start is a literal.  An ERE
-- has ( ) groups, | alternation, + ? and {m,n}.  Captures come back as a
-- list of strings (false for a group that took no part).  Matching is by
-- bytes in the C locale.

local scan = require("scan")

local regex = {}
local byte, char = string.byte, string.char

-- The [:class:] names, as tests on a one-character string (ASCII, as in
-- the C locale).
local function isGraph(c) return scan.isAlnum(c) or scan.isPunct(c) end
local CLASS = {
    alpha = scan.isAlpha,
    digit = scan.isDigit,
    alnum = scan.isAlnum,
    upper = scan.isUpper,
    lower = scan.isLower,
    space = scan.isSpace,
    blank = function(c) return c == " " or c == "\t" end,
    punct = scan.isPunct,
    cntrl = function(c) return byte(c) < 32 or byte(c) == 127 end,
    xdigit = scan.isHexDigit,
    graph = isGraph,
    print = function(c) return isGraph(c) or c == " " end,
}

--------------------------------------------------------------------------
-- Parsing: the pattern becomes a tree of nodes
--   { t = "set", set = {[byte] = true} }  one character (literals too)
--   { t = "bol" } { t = "eol" }           anchors
--   { t = "cat", ... } { t = "alt", ... } sequence, alternatives
--   { t = "group", n = n, node }          a capturing group
--   { t = "rep", node, min = m, max = n } a repetition (max nil: no limit)
--   { t = "ref", n = n }                  a back-reference
--------------------------------------------------------------------------
local function parse(pat, ere, icase)
    local pos, len, groups, closed = 1, #pat, 0, {}
    local function peek(k) return pat:sub(pos + (k or 0), pos + (k or 0)) end
    local function fail(msg) error(msg, 0) end
    -- the decimal digits from pos on ("" if none), not stepped over
    local function digitsHere() return scan.new(pat, pos):readWhile(scan.isDigit) end

    -- a one-character set, both cases of a letter when icase
    local function setOf(set)
        if icase then
            local extra = {}
            for b in pairs(set) do
                local c = char(b)
                extra[byte(c:lower())], extra[byte(c:upper())] = true, true
            end
            for b in pairs(extra) do set[b] = true end
        end
        return { t = "set", set = set }
    end
    local function lit(c) return setOf({ [byte(c)] = true }) end

    -- one element of a bracket expression: a character, [.x.] or [=x=]
    local function elem()
        local c, d = peek(), peek(1)
        if c == "[" and (d == "." or d == "=") then
            local close = pat:find(d .. "]", pos + 2, true)
            if not close then fail("brackets ([ ]) not balanced") end
            local name = pat:sub(pos + 2, close - 1)
            if #name ~= 1 then fail("invalid collating element") end
            pos = close + 2
            return byte(name)
        end
        pos = pos + 1
        return byte(c)
    end

    -- a bracket expression; pos is just past the "["
    local function bracket()
        local set, neg, first = {}, false, true
        if peek() == "^" then neg = true; pos = pos + 1 end
        while true do
            if pos > len then fail("brackets ([ ]) not balanced") end
            if peek() == "]" and not first then pos = pos + 1; break end
            first = false
            if peek() == "[" and peek(1) == ":" then
                local close = pat:find(":]", pos + 2, true)
                if not close then fail("brackets ([ ]) not balanced") end
                local f = CLASS[pat:sub(pos + 2, close - 1)]
                if not f then fail("invalid character class") end
                for b = 0, 255 do if f(char(b)) then set[b] = true end end
                pos = close + 2
            else
                local lo = elem()
                if peek() == "-" and peek(1) ~= "]" and peek(1) ~= "" then
                    pos = pos + 1
                    local hi = elem()
                    if hi < lo then fail("invalid range end") end
                    for b = lo, hi do set[b] = true end
                else
                    set[lo] = true
                end
            end
        end
        local node = setOf(set)
        if neg then
            local inv = {}
            for b = 0, 255 do if not set[b] then inv[b] = true end end
            node.set = inv
        end
        return node
    end

    -- {m}, {m,} or {m,n}; pos is just past the "{" (or "\{")
    local function interval()
        local m = digitsHere()
        if m == "" then fail("invalid interval") end
        pos = pos + #m
        local lo, hi = tonumber(m), tonumber(m)
        if peek() == "," then
            pos = pos + 1
            local n = digitsHere()
            hi = tonumber(n)        -- (nil when there are none: no limit)
            pos = pos + #n
        end
        local close = ere and "}" or "\\}"
        if pat:sub(pos, pos + #close - 1) ~= close then fail("braces not balanced") end
        pos = pos + #close
        if (hi and hi < lo) or lo > 255 or (hi or 0) > 255 then fail("invalid interval") end
        return lo, hi
    end

    local alt

    -- one atom; start is true at the start of a branch (or after a BRE ^)
    local function atom(start)
        local c, d = peek(), peek(1)
        pos = pos + 1
        if c == "." then return { t = "set", set = setmetatable({}, { __index = function() return true end }) } end
        if c == "[" then return bracket() end
        if ere then
            if c == "(" then
                groups = groups + 1
                local n = groups
                local node = alt(1)
                if peek() ~= ")" then fail("parentheses not balanced") end
                pos = pos + 1
                closed[n] = true
                return { t = "group", n = n, node }
            end
            if c == "^" then return { t = "bol" } end
            if c == "$" then return { t = "eol" } end
        else
            if c == "^" and start then return { t = "bol" } end
            if c == "$" and (pos > len or pat:sub(pos, pos + 1) == "\\)") then return { t = "eol" } end
        end
        if c ~= "\\" then return lit(c) end
        pos = pos + 1
        if d == "" then fail("trailing backslash") end
        if not ere and d == "(" then
            groups = groups + 1
            local n = groups
            local node = alt(1)
            if pat:sub(pos, pos + 1) ~= "\\)" then fail("parentheses not balanced") end
            pos = pos + 2
            closed[n] = true
            return { t = "group", n = n, node }
        end
        if not ere and (d == ")" or d == "{" or d == "}") then fail("unmatched \\" .. d) end
        if scan.isDigit(d) and d ~= "0" then
            if not closed[tonumber(d)] then fail("invalid back reference") end
            return { t = "ref", n = tonumber(d) }
        end
        return lit(d)
    end

    -- a branch: atoms each followed by any repetitions
    local function branch(depth)
        local node, start = { t = "cat" }, true
        while pos <= len do
            local c, d = peek(), peek(1)
            if ere and (c == "|" or (c == ")" and depth > 0)) then break end
            if not ere and c == "\\" and d == ")" and depth > 0 then break end
            local a
            if start and (c == "*" or (ere and (c == "+" or c == "?"))) then
                pos = pos + 1
                a = lit(c)   -- nothing to repeat: a literal
            else
                a = atom(start)
            end
            -- (a BRE "^*" is an anchor and a literal "*", taken next time round)
            while ere or a.t ~= "bol" do
                c, d = peek(), peek(1)
                local lo, hi
                if c == "*" then pos = pos + 1; lo = 0
                elseif ere and c == "+" then pos = pos + 1; lo = 1
                elseif ere and c == "?" then pos = pos + 1; lo, hi = 0, 1
                elseif ere and c == "{" and scan.isDigit(d) then pos = pos + 1; lo, hi = interval()
                elseif not ere and c == "\\" and d == "{" then pos = pos + 2; lo, hi = interval()
                else break end
                a = { t = "rep", a, min = lo, max = hi }
            end
            node[#node + 1] = a
            start = not ere and a.t == "bol"
        end
        return node
    end

    -- alternatives (ERE only; a BRE has one branch)
    alt = function(depth)
        local node = { t = "alt", branch(depth) }
        while ere and peek() == "|" do
            pos = pos + 1
            node[#node + 1] = branch(depth)
        end
        return #node == 1 and node[1] or node
    end

    local tree = alt(0)
    if pos <= len then fail("parentheses not balanced") end
    return tree, groups
end

--------------------------------------------------------------------------
-- Matching: each node becomes m(i, k), which matches at position i of the
-- subject and calls the continuation k(j) with the position after it,
-- backtracking when k returns false.
--------------------------------------------------------------------------
function regex.compile(pat, opts)
    opts = opts or {}
    local ok, tree, ngroups = pcall(parse, pat, opts.ere, opts.icase)
    if not ok then return nil, tree end
    local S, LEN, caps = "", 0, {}

    local build
    local function cat(node, from)
        if from > #node then return function(i, k) return k(i) end end
        if from == #node then return build(node[from]) end
        local a, rest = build(node[from]), cat(node, from + 1)
        return function(i, k) return a(i, function(j) return rest(j, k) end) end
    end

    build = function(node)
        local t = node.t
        if t == "set" then
            local set = node.set
            return function(i, k)
                local b = byte(S, i)
                if b and set[b] then return k(i + 1) end
                return false
            end
        elseif t == "bol" then
            return function(i, k) if i == 1 then return k(i) end return false end
        elseif t == "eol" then
            return function(i, k) if i == LEN + 1 then return k(i) end return false end
        elseif t == "cat" then
            return cat(node, 1)
        elseif t == "alt" then
            local ms = {}
            for n, b in ipairs(node) do ms[n] = build(b) end
            return function(i, k)
                for _, m in ipairs(ms) do
                    local r = m(i, k)
                    if r then return r end
                end
                return false
            end
        elseif t == "group" then
            local m, a, b = build(node[1]), 2 * node.n - 1, 2 * node.n
            return function(i, k)
                return m(i, function(j)
                    local oa, ob = caps[a], caps[b]
                    caps[a], caps[b] = i, j
                    local r = k(j)
                    if not r then caps[a], caps[b] = oa, ob end
                    return r
                end)
            end
        elseif t == "ref" then
            local a, b = 2 * node.n - 1, 2 * node.n
            return function(i, k)
                if not caps[a] then return false end
                local want = S:sub(caps[a], caps[b] - 1)
                local got = S:sub(i, i + #want - 1)
                if opts.icase then want, got = want:lower(), got:lower() end
                if want == got then return k(i + #want) end
                return false
            end
        end
        -- a repetition
        local min, max, sub = node.min, node.max, node[1]
        if sub.t == "set" then
            -- one character at a time: take as many as allowed, then give back
            local set = sub.set
            return function(i, k)
                local j, lim = i, max and i + max or math.huge
                while j < lim and j <= LEN and set[byte(S, j)] do j = j + 1 end
                for e = j, i + min, -1 do
                    local r = k(e)
                    if r then return r end
                end
                return false
            end
        end
        local m = build(sub)
        return function(i, k)
            local function step(j, n)
                if not max or n < max then
                    local r = m(j, function(e)
                        -- an empty pass can stand for all the passes still needed
                        if e == j then return n < min and k(e) end
                        return step(e, n + 1)
                    end)
                    if r then return r end
                end
                if n >= min then return k(j) end
                return false
            end
            return step(i, 0)
        end
    end

    -- The bytes a match can start with, or nil if any (or none) can: lets
    -- the search skip start positions without trying the whole matcher.
    local function first(node)
        local t = node.t
        if t == "set" then return getmetatable(node.set) == nil and node.set or nil end
        if t == "group" or (t == "rep" and node.min > 0) then return first(node[1]) end
        if t == "cat" then
            for _, n in ipairs(node) do
                if n.t ~= "bol" then return first(n) end
            end
        elseif t == "alt" then
            local u = {}
            for _, b in ipairs(node) do
                local f = first(b)
                if not f then return nil end
                for c in pairs(f) do u[c] = true end
            end
            return u
        end
        return nil
    end

    local m, starts = build(tree), first(tree)
    local anchored = tree.t == "bol" or (tree.t == "cat" and tree[1] and tree[1].t == "bol")
    local re = { ngroups = ngroups }

    -- the next position from st on where a match could start, or nil
    local function nextStart(st, last)
        if starts then
            while st <= last and not starts[byte(S, st)] do st = st + 1 end
        end
        if st <= last then return st end
    end

    function re:test(s, whole)
        S, LEN, caps = s, #s, {}
        local k = whole and function(j) return j == LEN + 1 end or function() return true end
        local st, last = 1, (whole or anchored) and 1 or LEN + 1
        while true do
            st = nextStart(st, last)
            if not st then return false end
            if m(st, k) then return true end
            st = st + 1
        end
    end

    function re:find(s, init)
        S, LEN, caps = s, #s, {}
        local st, last = init or 1, anchored and 1 or LEN + 1
        while true do
            st = nextStart(st, last)
            if not st then return nil end
            local best, bestCaps
            m(st, function(j)
                if not best or j > best then
                    best, bestCaps = j, {}
                    for n = 1, 2 * ngroups do bestCaps[n] = caps[n] end
                end
                return j == LEN + 1
            end)
            if best then
                local list = {}
                for n = 1, ngroups do
                    local a = bestCaps[2 * n - 1]
                    list[n] = a and s:sub(a, bestCaps[2 * n] - 1) or false
                end
                return st, best - 1, list
            end
            st = st + 1
        end
    end

    return re
end

return regex
