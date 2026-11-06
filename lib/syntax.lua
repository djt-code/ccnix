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
    for w in list:gmatch("%S+") do t[w] = true end
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

function S.detect(path, first)
    first = first or ""
    if first:sub(1, 2) == "#!" then
        if first:find("lua") then return "lua" end
        if first:find("sh") then return "sh" end
    end
    local name = (path or ""):match("[^/]*$")
    if name == "" then return nil end
    local ext = name:match("^.+%.([^.]+)$")
    if ext == "lua" then return "lua" end
    if ext == "sh" or ext == "ccsh" or ext == "bash" or name == ".profile" or name == ".ccshrc" then
        return "sh"
    end
    if not ext and name:sub(1, 1) ~= "." then return "lua" end
    return nil
end

--------------------------------------------------------------------------
-- Lua
--------------------------------------------------------------------------

-- The end of a long bracket of level `eq` ("]==]") from i, or nil.
local function longEnd(text, i, eq)
    local _, stop = text:find("]" .. string.rep("=", eq) .. "]", i, true)
    return stop
end

local function luaLine(text, state)
    local C = S.COLOURS
    local out, n, i = {}, #text, 1
    local function paint(a, b, c) if b >= a then out[#out + 1] = string.rep(c, b - a + 1) end end
    if state then
        if state.long then
            local stop = longEnd(text, 1, state.eq)
            local c = state.long == "comment" and C.comment or C.string
            if not stop then paint(1, n, c); return table.concat(out), state end
            paint(1, stop, c)
            i = stop + 1
        elseif state.quote then
            -- a string continued past a backslash at the end of the last line
            local j, closed = 1, false
            while j <= n do
                local ch = text:sub(j, j)
                if ch == "\\" then j = j + 2
                elseif ch == state.quote then closed = true; break
                else j = j + 1 end
            end
            if not closed then
                paint(1, n, C.string)
                return table.concat(out), text:sub(-1) == "\\" and state or nil
            end
            paint(1, j, C.string)
            i = j + 1
        end
    end
    while i <= n do
        local ch = text:sub(i, i)
        local open = text:match("^%[(=*)%[", i)
        if text:sub(i, i + 1) == "--" then
            local eq = text:match("^%-%-%[(=*)%[", i)
            if eq then
                local stop = longEnd(text, i + 4 + #eq, #eq)
                if not stop then paint(i, n, C.comment); return table.concat(out), { long = "comment", eq = #eq } end
                paint(i, stop, C.comment)
                i = stop + 1
            else
                paint(i, n, C.comment)
                i = n + 1
            end
        elseif open then
            local stop = longEnd(text, i + 2 + #open, #open)
            if not stop then paint(i, n, C.string); return table.concat(out), { long = "string", eq = #open } end
            paint(i, stop, C.string)
            i = stop + 1
        elseif ch == '"' or ch == "'" then
            local j = i + 1
            while j <= n do
                local c2 = text:sub(j, j)
                if c2 == "\\" then j = j + 2
                elseif c2 == ch then break
                else j = j + 1 end
            end
            if j > n then
                paint(i, n, C.string)
                return table.concat(out), text:sub(-1) == "\\" and { quote = ch } or nil
            end
            paint(i, j, C.string)
            i = j + 1
        elseif ch:match("%d") or (ch == "." and text:sub(i + 1, i + 1):match("%d")) then
            local num = text:match("^%.?%d[%w%.]*", i)
            local after = i + #num
            while num:match("[eEpP]$") and text:sub(after, after):match("[%+%-]") do
                local more = text:match("^[%+%-][%w%.]*", after)
                num, after = num .. more, after + #more
            end
            paint(i, after - 1, C.constant)
            i = after
        elseif ch:match("[%a_]") then
            local word = text:match("^[%w_]+", i)
            local c = (LUA_KEYWORDS[word] and C.keyword) or (LUA_CONSTANTS[word] and C.constant)
                or (LUA_BUILTINS[word] and text:sub(i - 1, i - 1) ~= "." and text:sub(i - 1, i - 1) ~= ":" and C.builtin)
                or C.text
            paint(i, i + #word - 1, c)
            i = i + #word
        else
            paint(i, i, C.text)
            i = i + 1
        end
    end
    return table.concat(out), nil
end

--------------------------------------------------------------------------
-- sh (ccsh)
--------------------------------------------------------------------------

-- A $ expansion at i: its length (0 if this $ is just a character).
local function dollar(text, i)
    local nxt = text:sub(i + 1, i + 1)
    if nxt == "{" then
        local stop = text:find("}", i + 2, true)
        return (stop or #text) - i + 1
    elseif nxt == "(" then
        return 2
    elseif nxt:match("[%a_]") then
        return 1 + #text:match("^[%w_]+", i + 1)
    elseif nxt:match("[%d%?#%$!%*@%-]") then
        return 2
    end
    return 0
end

local function shLine(text, state)
    local C = S.COLOURS
    local out, n, i = {}, #text, 1
    local cmdpos = true
    local function paint(a, b, c) if b >= a then out[#out + 1] = string.rep(c, b - a + 1) end end
    -- the inside of a double-quoted string from i: ends at the quote (its
    -- index) or runs off the line (nil)
    local function dq(j)
        while j <= n do
            local ch = text:sub(j, j)
            if ch == "\\" then paint(j, math.min(j + 1, n), C.string); j = j + 2
            elseif ch == '"' then paint(j, j, C.string); return j
            elseif ch == "$" and dollar(text, j) > 0 then
                local len = dollar(text, j)
                paint(j, j + len - 1, C.var); j = j + len
            else paint(j, j, C.string); j = j + 1 end
        end
        return nil
    end
    if state then
        if state.quote == "'" then
            local stop = text:find("'", 1, true)
            if not stop then paint(1, n, C.string); return table.concat(out), state end
            paint(1, stop, C.string)
            i, cmdpos = stop + 1, false
        else
            local stop = dq(1)
            if not stop then return table.concat(out), state end
            i, cmdpos = stop + 1, false
        end
    end
    while i <= n do
        local ch = text:sub(i, i)
        local before = i == 1 and " " or text:sub(i - 1, i - 1)
        if ch == "#" and before:match("[%s;&|()]") then
            paint(i, n, C.comment)
            i = n + 1
        elseif ch == "'" then
            local stop = text:find("'", i + 1, true)
            if not stop then paint(i, n, C.string); return table.concat(out), { quote = "'" } end
            paint(i, stop, C.string)
            i, cmdpos = stop + 1, false
        elseif ch == '"' then
            paint(i, i, C.string)
            local stop = dq(i + 1)
            if not stop then return table.concat(out), { quote = '"' } end
            i, cmdpos = stop + 1, false
        elseif ch == "\\" then
            paint(i, math.min(i + 1, n), C.text)
            i = i + 2
        elseif ch == "$" and dollar(text, i) > 0 then
            local len = dollar(text, i)
            paint(i, i + len - 1, C.var)
            if text:sub(i + 1, i + 1) == "(" then cmdpos = true else cmdpos = false end
            i = i + len
        elseif ch:match("[;&|()<>`]") then
            local op = text:match("^[;&|()<>`]+", i)
            paint(i, i + #op - 1, C.op)
            if not op:match("^[<>]+$") then cmdpos = true end
            i = i + #op
        elseif ch:match("%s") then
            paint(i, i, C.text)
            i = i + 1
        else
            local word = text:match("^[^%s;&|()<>`'\"$\\]+", i) or ch
            local name = word:match("^([%a_][%w_]*)=")
            if name and cmdpos then
                -- NAME=value: an assignment, and a command may still follow
                paint(i, i + #name, C.var)
                paint(i + #name + 1, i + #word - 1, C.text)
                i = i + #word
            else
                local c = C.text
                if cmdpos and SH_KEYWORDS[word] then c = C.keyword
                elseif cmdpos and SH_BUILTINS[word] then c = C.builtin
                elseif word:match("^%d+$") then c = C.constant end
                if word == "in" or word == "do" then c = C.keyword end
                paint(i, i + #word - 1, c)
                cmdpos = cmdpos and SH_LEAD[word] or false
                i = i + #word
            end
        end
    end
    return table.concat(out), nil
end

-- The colours of one line of `lang` (nil: all plain), and the state for
-- the next.
function S.line(lang, text, state)
    if lang == "lua" then return luaLine(text, state) end
    if lang == "sh" then return shLine(text, state) end
    return string.rep(S.COLOURS.text, #text), nil
end

return S
