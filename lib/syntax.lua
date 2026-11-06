-- syntax.lua -- colours for source text, a line at a time (vim's highlighting)
--
--   local syntax = require("syntax")
--   local lang = syntax.detect(path, firstLine)   -- "lua", "sh" or nil
--   local fg, state = syntax.line(lang, text, state)
--
-- fg has one blit digit per byte of text ("4" yellow, "e" red ...), as
-- term.blit takes them.  state is what carries over to the next line (a
-- long string or comment still open, a quote not yet closed): pass the
-- previous line's state in, nil for the first line.  syntax.COLOURS holds
-- the digit of each kind of word, to change the look.
--
-- Lua: keywords, the constants (nil, true, false), numbers, strings (long
-- brackets too), comments, and the standard and CraftOS library names.
-- sh is ccsh's (and the POSIX shell's) language: reserved words and
-- builtins where a command can start, variables ($x, ${x}, $(, NAME=),
-- quotes, comments and the operators.
--
-- detect: a #! line naming lua or a shell; else the extension (.lua, .sh,
-- .ccsh), and /.profile; a name with no extension is a CraftOS program,
-- which is Lua.
--
-- Each colourer reads its line with a scanner (lib/scan): it looks at the
-- next character, decides what it starts (a comment, a string, a number,
-- a word ...), steps over the whole of it and paints what it stepped over.

local scan = require("scan")
local isDigit, isAlnum, isSpace = scan.isDigit, scan.isAlnum, scan.isSpace
local isNameStart, isNameChar = scan.isNameStart, scan.isNameChar

local S = {}

S.COLOURS = {
    text = "0",        -- white
    keyword = "4",     -- yellow
    constant = "2",    -- magenta: nil true false, numbers
    string = "e",      -- red
    comment = "d",     -- green
    builtin = "9",     -- cyan: library names, shell builtins
    var = "3",         -- light blue: $x, NAME=
    op = "1",          -- orange: | & ; < > ( )
}

local function set(list)
    local t = {}
    for _, w in ipairs(scan.words(list)) do t[w] = true end
    return t
end

local LUA_KEYWORDS = set([[and break do else elseif end for function goto if in local not or
    repeat return then until while]])
local LUA_CONSTANTS = set("nil true false")
local LUA_BUILTINS = set([[assert collectgarbage dofile error getmetatable ipairs load loadfile
    loadstring next pairs pcall print rawequal rawget rawlen rawset require select setmetatable
    tonumber tostring type unpack xpcall _G _ENV self string table math os io coroutine utf8 debug
    package bit32 fs term shell peripheral rednet colours colors keys textutils turtle settings
    http parallel vector paintutils window redstone multishell disk gps help commands pocket
    printError read sleep write]])

local SH_KEYWORDS = set("if then else elif fi for while until do done case esac in function select time !")
local SH_BUILTINS = set([[alias bg break cd continue echo eval exec exit export false fg getopts
    jobs kill local printf pwd read readonly return set shift source test true type umask
    unalias unset wait . : [ ]])
-- after these a new command starts
local SH_LEAD = set("if then else elif while until do ! time {")

-- The last part of a path: what follows its last "/".
local function baseName(path)
    local from = 1
    while true do
        local slash = path:find("/", from, true)
        if not slash then return path:sub(from) end
        from = slash + 1
    end
end

-- A file name's extension: what follows its last ".", if that dot has
-- something before it and something after ("a.lua"; not ".profile" or "a.").
local function extension(name)
    local dot
    for i = #name, 2, -1 do
        if name:sub(i, i) == "." then dot = i; break end
    end
    if not dot or dot == #name then return nil end
    return name:sub(dot + 1)
end

function S.detect(path, first)
    first = first or ""
    if first:sub(1, 2) == "#!" then
        if first:find("lua", 1, true) then return "lua" end
        if first:find("sh", 1, true) then return "sh" end
    end
    local name = baseName(path or "")
    if name == "" then return nil end
    local ext = extension(name)
    if ext == "lua" then return "lua" end
    if ext == "sh" or ext == "ccsh" or ext == "bash" or name == ".profile" or name == ".ccshrc" then
        return "sh"
    end
    if not ext and name:sub(1, 1) ~= "." then return "lua" end
    return nil
end

-- A line's colours, built up as the scanner goes: paint(a, b, c) colours
-- bytes a..b with c, paintFrom(a, c) from a up to where the scanner is.
local function painter(sc)
    local out = {}
    local p = {}
    function p.paint(a, b, c) if b >= a then out[#out + 1] = string.rep(c, b - a + 1) end end
    function p.paintFrom(a, c) p.paint(a, sc:pos() - 1, c) end
    function p.result() return table.concat(out) end
    return p
end

--------------------------------------------------------------------------
-- Lua
--------------------------------------------------------------------------

-- The level of a long bracket opening at the scanner, "[" then "="s then
-- "[" (its level is how many "="s), or nil if there isn't one there.
-- Steps over nothing: the opening is level + 2 characters long.
local function longOpenAt(sc)
    local start = sc:pos()
    local level
    if sc:accept("[") then
        local eqs = sc:readWhile(function(c) return c == "=" end)
        if sc:accept("[") then level = #eqs end
    end
    sc:setPos(start)
    return level
end

-- Steps to just past the long bracket's close of this level ("]==]" for
-- 2): true, or false (at the end of the line) if it isn't on this line.
local function skipLongClose(sc, level)
    local close = "]" .. string.rep("=", level) .. "]"
    local _, stop = sc.text:find(close, sc:pos(), true)
    if not stop then sc:readRest(); return false end
    sc:setPos(stop + 1)
    return true
end

-- Steps over the inside of a quoted string up to its closing quote q
-- (stepped over too; a backslash takes the next character with it):
-- true, or false if the line ended first.
local function skipQuoted(sc, q)
    while not sc:atEnd() do
        local c = sc:advance()
        if c == "\\" then sc:advance()
        elseif c == q then return true end
    end
    return false
end

-- The state after a line whose string in quotes q ran off its end: it
-- carries on only if the line ends in a backslash.
local function quoteCarries(text, q)
    if text:sub(-1) == "\\" then return { quote = q } end
    return nil
end

local function isNumberChar(c) return isAlnum(c) or c == "." end
local isExponentMark = scan.oneOf("eEpP")
local isSign = scan.oneOf("+-")

-- Steps over a number: digits, or "." then a digit; then any letters,
-- digits and dots (hex digits, "x", the exponent's "e" or "p" and the
-- digits after it).  A sign straight after an exponent's mark goes too.
local function skipNumber(sc)
    sc:accept(".")
    sc:readWhile(isNumberChar)
    while isExponentMark(sc:prev()) and isSign(sc:peek()) do
        sc:advance()
        sc:readWhile(isNumberChar)
    end
end

local function startsNumber(sc)
    return isDigit(sc:peek()) or (sc:peek() == "." and isDigit(sc:peek(2)))
end

local function luaLine(text, state)
    local C = S.COLOURS
    local sc = scan.new(text)
    local p = painter(sc)
    if state then
        if state.long then
            -- inside a long string or comment from the line before
            local c = state.long == "comment" and C.comment or C.string
            local closed = skipLongClose(sc, state.eq)
            p.paintFrom(1, c)
            if not closed then return p.result(), state end
        elseif state.quote then
            -- a string continued past a backslash at the end of the last line
            local closed = skipQuoted(sc, state.quote)
            p.paintFrom(1, C.string)
            if not closed then return p.result(), quoteCarries(text, state.quote) end
        end
    end
    while not sc:atEnd() do
        local start = sc:pos()
        local ch = sc:peek()
        local open = longOpenAt(sc)
        if sc:accept("--") then
            -- a comment: --[[ long ]] (maybe running on), or to the line's end
            local level = longOpenAt(sc)
            if level then
                sc:advance(level + 2)
                local closed = skipLongClose(sc, level)
                p.paintFrom(start, C.comment)
                if not closed then return p.result(), { long = "comment", eq = level } end
            else
                sc:readRest()
                p.paintFrom(start, C.comment)
            end
        elseif open then
            -- a long string [[ ... ]] or [==[ ... ]==]
            sc:advance(open + 2)
            local closed = skipLongClose(sc, open)
            p.paintFrom(start, C.string)
            if not closed then return p.result(), { long = "string", eq = open } end
        elseif ch == '"' or ch == "'" then
            sc:advance()
            local closed = skipQuoted(sc, ch)
            p.paintFrom(start, C.string)
            if not closed then return p.result(), quoteCarries(text, ch) end
        elseif startsNumber(sc) then
            skipNumber(sc)
            p.paintFrom(start, C.constant)
        elseif isNameStart(ch) then
            -- a library name counts only on its own, not as a field (x.string, s:len)
            local before = sc:prev()
            local word = sc:readName()
            local field = before == "." or before == ":"
            local c = (LUA_KEYWORDS[word] and C.keyword) or (LUA_CONSTANTS[word] and C.constant)
                or (LUA_BUILTINS[word] and not field and C.builtin)
                or C.text
            p.paintFrom(start, c)
        else
            sc:advance()
            p.paintFrom(start, C.text)
        end
    end
    return p.result(), nil
end

--------------------------------------------------------------------------
-- sh (ccsh)
--------------------------------------------------------------------------

local isSpecialParam = scan.oneOf("?#$!*@-")
local isOpChar = scan.oneOf(";&|()<>`")
local isRedirectChar = scan.oneOf("<>")
local endsWord = scan.oneOf(";&|()<>`'\"$\\")
-- a "#" starts a comment only at a word's start: after these or a blank
local beforeComment = scan.oneOf(";&|()")

local function isWordChar(c) return not isSpace(c) and not endsWord(c) end

-- How long the $ expansion at the scanner is (0 if this $ is just a
-- character); steps over nothing.  The expansions:
--   ${ ... }   to the "}" (or the end of the line)
--   $(         just the two: the command inside is coloured as one
--   $name      a name
--   $1 $? $# $$ $! $* $@ $-   the special parameters
local function dollarLength(sc)
    local start = sc:pos()
    sc:advance()
    local len = 0
    if sc:accept("{") then
        sc:readWhile(function(c) return c ~= "}" end)
        sc:accept("}")
        len = sc:pos() - start
    elseif sc:peek() == "(" then
        len = 2
    elseif sc:readName() then
        len = sc:pos() - start
    elseif isDigit(sc:peek()) or isSpecialParam(sc:peek()) then
        len = 2
    end
    sc:setPos(start)
    return len
end

-- NAME=: the length of the name and its "=" at the start of word (0 if
-- the word isn't an assignment)
local function assignmentLength(word)
    local w = scan.new(word)
    if w:readName() and w:accept("=") then return w:pos() - 1 end
    return 0
end

local function isNumber(word) return word ~= "" and scan.all(word, isDigit) end

local function shLine(text, state)
    local C = S.COLOURS
    local sc = scan.new(text)
    local p = painter(sc)
    local cmdpos = true
    -- the inside of a double-quoted string, from the scanner: true when it
    -- ended (its quote stepped over), false if it ran off the line
    local function dq()
        while not sc:atEnd() do
            local at = sc:pos()
            local ch = sc:peek()
            if ch == "\\" then
                sc:advance(2)
                p.paintFrom(at, C.string)
            elseif ch == '"' then
                sc:advance()
                p.paintFrom(at, C.string)
                return true
            elseif ch == "$" and dollarLength(sc) > 0 then
                sc:advance(dollarLength(sc))
                p.paintFrom(at, C.var)
            else
                sc:advance()
                p.paintFrom(at, C.string)
            end
        end
        return false
    end
    if state then
        if state.quote == "'" then
            sc:readWhile(function(c) return c ~= "'" end)
            local closed = sc:accept("'")
            p.paintFrom(1, C.string)
            if not closed then return p.result(), state end
        else
            if not dq() then return p.result(), state end
        end
        cmdpos = false
    end
    while not sc:atEnd() do
        local start = sc:pos()
        local ch = sc:peek()
        local before = sc:prev()
        if ch == "#" and (before == "" or isSpace(before) or beforeComment(before)) then
            sc:readRest()
            p.paintFrom(start, C.comment)
        elseif ch == "'" then
            sc:advance()
            sc:readWhile(function(c) return c ~= "'" end)
            local closed = sc:accept("'")
            p.paintFrom(start, C.string)
            if not closed then return p.result(), { quote = "'" } end
            cmdpos = false
        elseif ch == '"' then
            sc:advance()
            p.paintFrom(start, C.string)
            if not dq() then return p.result(), { quote = '"' } end
            cmdpos = false
        elseif ch == "\\" then
            sc:advance(2)
            p.paintFrom(start, C.text)
        elseif ch == "$" and dollarLength(sc) > 0 then
            -- after $( a new command starts
            cmdpos = sc:peek(2) == "("
            sc:advance(dollarLength(sc))
            p.paintFrom(start, C.var)
        elseif isOpChar(ch) then
            -- operators; a command follows them, except after < and >
            local op = sc:readWhile(isOpChar)
            p.paintFrom(start, C.op)
            if not scan.all(op, isRedirectChar) then cmdpos = true end
        elseif isSpace(ch) then
            sc:advance()
            p.paintFrom(start, C.text)
        else
            local word = sc:readWhile(isWordChar)
            if word == "" then word = sc:advance() end
            local assign = assignmentLength(word)
            if assign > 0 and cmdpos then
                -- NAME=value: an assignment, and a command may still follow
                p.paint(start, start + assign - 1, C.var)
                p.paintFrom(start + assign, C.text)
            else
                local c = C.text
                if cmdpos and SH_KEYWORDS[word] then c = C.keyword
                elseif cmdpos and SH_BUILTINS[word] then c = C.builtin
                elseif isNumber(word) then c = C.constant end
                if word == "in" or word == "do" then c = C.keyword end
                p.paintFrom(start, c)
                cmdpos = cmdpos and SH_LEAD[word] or false
            end
        end
    end
    return p.result(), nil
end

-- The colours of one line of `lang` (nil: all plain), and the state for
-- the next.
function S.line(lang, text, state)
    if lang == "lua" then return luaLine(text, state) end
    if lang == "sh" then return shLine(text, state) end
    return string.rep(S.COLOURS.text, #text), nil
end

return S
