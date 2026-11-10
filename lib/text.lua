-- text.lua -- strings as wholes: blanks, pieces, ends, widths and case
--
--   local text = require("text")
--   text.split("#a, #b,", ",")          --> { "#a", "#b" }
--   text.join({ 1, 2, 3 }, ", ")        --> "1, 2, 3"
--   text.stripPrefix("--port=6667", "--port=")   --> "6667"
--   text.replace("a.b.c", ".", "/")     --> "a/b/c"
--   text.padRight("ok", 6) .. "|"       --> "ok    |"
--
-- Everything here takes its separators, prefixes and parts as plain
-- strings, compared as they are: nothing is a pattern, so "." is a dot
-- and "%" is a percent sign.  It sits on lib/scan (characters and the
-- shape of a string); lib/convert turns text into values.
--
-- Blanks (scan.isSpace: space, tab, newline, return, vt, ff):
--   text.trim(s)          s without the blanks at either end
--   text.trimStart(s)     ... at its start;  text.trimEnd(s)  ... at its end
--   text.squeeze(s)       trimmed, every run of blanks inside as one space
--   text.words(s)         the words of s between blanks, as a list
--
-- Pieces:
--   text.split(s, sep)    the pieces of s between each sep, each trimmed,
--                         the empty ones left out.  text.split(s, sep, true)
--                         keeps them as they are, empty ones and blanks too.
--   text.join(list, sep)  the items (tostring'd) with sep between them
--                         ("" if no sep)
--   text.cut(s, sep)      the text before the first sep and after it:
--                         text.cut("host:6667", ":") is "host", "6667";
--                         s and nil when there's no sep
--   text.cutLast(s, sep)  the same at the last sep
--   text.lines(s)         s's lines (after LF or CR LF; a last line without
--                         one too), as a list
--
-- Ends and insides:
--   text.startsWith(s, prefix), text.endsWith(s, suffix)
--   text.stripPrefix(s, prefix)   the rest of s after prefix, or nil if s
--                         doesn't start with it
--   text.stripSuffix(s, suffix)   s before suffix, or nil
--   text.find(s, part [, from])   where part first is in s (from `from`
--                         on): its first and last index, or nil
--   text.findLast(s, part)        the same for the last one
--   text.contains(s, part)        true if part is in s
--   text.count(s, part)   how many times part is in s, not overlapping
--   text.replace(s, old, new [, n])   s with each old (the first n, if n)
--                         made new; and how many were
--
-- Widths (in characters, as CC's terminals count them):
--   text.padRight(s, w [, ch])  s, then ch (a space) up to w wide;
--                               longer s is cut to w
--   text.padLeft(s, w [, ch])   the same with the padding before
--   text.center(s, w)           s in the middle of w
--   text.truncate(s, w [, mark])  s cut to w, mark (none) at its end
--                               when cut: truncate("abcdef", 4, "~") is "abc~"
--   text.wrap(s, w)             s as lines of at most w, broken at blanks
--                               (a word longer than w is broken where it
--                               must); each newline in s ends a line
--
-- Case (ASCII, as string.upper and string.lower):
--   text.equalFold(a, b)  a and b the same but for case
--   text.capitalize(s)    the first character in upper case
--   text.swapCase(s)      upper case letters lower and lower ones upper

local scan = require("scan")

local text = {}

--------------------------------------------------------------------------
-- Blanks
--------------------------------------------------------------------------

function text.trimStart(s)
    local from = 1
    while from <= #s and scan.isSpace(s:sub(from, from)) do from = from + 1 end
    return s:sub(from)
end

function text.trimEnd(s)
    local to = #s
    while to >= 1 and scan.isSpace(s:sub(to, to)) do to = to - 1 end
    return s:sub(1, to)
end

function text.trim(s) return text.trimEnd(text.trimStart(s)) end

function text.words(s)
    local sc, out = scan.new(s), {}
    sc:skipSpaces()
    while not sc:atEnd() do
        out[#out + 1] = sc:readWhile(function(c) return not scan.isSpace(c) end)
        sc:skipSpaces()
    end
    return out
end

function text.squeeze(s) return table.concat(text.words(s), " ") end

--------------------------------------------------------------------------
-- Pieces
--------------------------------------------------------------------------

function text.find(s, part, from)
    return s:find(part, from or 1, true)
end

function text.findLast(s, part)
    local first, last
    local from = 1
    while true do
        local a, b = s:find(part, from, true)
        if not a then return first, last end
        first, last, from = a, b, a + 1
    end
end

function text.split(s, sep, keep)
    local out, from = {}, 1
    local function piece(p)
        if keep then out[#out + 1] = p; return end
        p = text.trim(p)
        if p ~= "" then out[#out + 1] = p end
    end
    while true do
        local at = s:find(sep, from, true)
        if not at then break end
        piece(s:sub(from, at - 1))
        from = at + #sep
    end
    piece(s:sub(from))
    return out
end

function text.join(list, sep)
    local parts = {}
    for i = 1, #list do parts[i] = tostring(list[i]) end
    return table.concat(parts, sep or "")
end

function text.cut(s, sep)
    local at = s:find(sep, 1, true)
    if not at then return s, nil end
    return s:sub(1, at - 1), s:sub(at + #sep)
end

function text.cutLast(s, sep)
    local at = text.findLast(s, sep)
    if not at then return s, nil end
    return s:sub(1, at - 1), s:sub(at + #sep)
end

function text.lines(s)
    local out = {}
    for _, piece in ipairs(text.split(s, "\n", true)) do
        out[#out + 1] = text.stripSuffix(piece, "\r") or piece
    end
    if out[#out] == "" then out[#out] = nil end     -- (the newline at the end ends a line; it doesn't start one)
    return out
end

--------------------------------------------------------------------------
-- Ends and insides
--------------------------------------------------------------------------

function text.startsWith(s, prefix) return s:sub(1, #prefix) == prefix end
function text.endsWith(s, suffix) return suffix == "" or s:sub(-#suffix) == suffix end

function text.stripPrefix(s, prefix)
    if not text.startsWith(s, prefix) then return nil end
    return s:sub(#prefix + 1)
end

function text.stripSuffix(s, suffix)
    if not text.endsWith(s, suffix) then return nil end
    return s:sub(1, #s - #suffix)
end

function text.contains(s, part) return s:find(part, 1, true) ~= nil end

function text.count(s, part)
    if part == "" then return 0 end
    local n, from = 0, 1
    while true do
        local _, last = s:find(part, from, true)
        if not last then return n end
        n, from = n + 1, last + 1
    end
end

function text.replace(s, old, new, n)
    if old == "" then return s, 0 end
    local out, from, done = {}, 1, 0
    while not n or done < n do
        local a, b = s:find(old, from, true)
        if not a then break end
        out[#out + 1] = s:sub(from, a - 1)
        out[#out + 1] = new
        from, done = b + 1, done + 1
    end
    out[#out + 1] = s:sub(from)
    return table.concat(out), done
end

--------------------------------------------------------------------------
-- Widths
--------------------------------------------------------------------------

function text.padRight(s, w, ch)
    s = tostring(s)
    if #s >= w then return s:sub(1, w) end
    return s .. (ch or " "):rep(w - #s)
end

function text.padLeft(s, w, ch)
    s = tostring(s)
    if #s >= w then return s:sub(1, w) end
    return (ch or " "):rep(w - #s) .. s
end

function text.center(s, w)
    s = tostring(s)
    if #s >= w then return s:sub(1, w) end
    local left = math.floor((w - #s) / 2)
    return (" "):rep(left) .. s .. (" "):rep(w - #s - left)
end

function text.truncate(s, w, mark)
    s, mark = tostring(s), mark or ""
    if #s <= w then return s end
    if #mark >= w then return mark:sub(1, w) end
    return s:sub(1, w - #mark) .. mark
end

-- one line (no newlines in it) as lines of at most w
local function wrapLine(line, w, out)
    local cur = ""
    for _, word in ipairs(text.words(line)) do
        while #word > w do                              -- (too long for any line: broken)
            if cur ~= "" then out[#out + 1] = cur; cur = "" end
            out[#out + 1] = word:sub(1, w)
            word = word:sub(w + 1)
        end
        if cur == "" then cur = word
        elseif #cur + 1 + #word <= w then cur = cur .. " " .. word
        else out[#out + 1] = cur; cur = word end
    end
    out[#out + 1] = cur
end

function text.wrap(s, w)
    local out = {}
    for _, line in ipairs(text.split(s, "\n", true)) do wrapLine(line, math.max(1, w), out) end
    return out
end

--------------------------------------------------------------------------
-- Case
--------------------------------------------------------------------------

function text.equalFold(a, b) return #a == #b and a:lower() == b:lower() end

function text.capitalize(s) return s:sub(1, 1):upper() .. s:sub(2) end

function text.swapCase(s)
    local out = {}
    for i = 1, #s do
        local c = s:sub(i, i)
        if scan.isUpper(c) then c = c:lower() elseif scan.isLower(c) then c = c:upper() end
        out[i] = c
    end
    return table.concat(out)
end

return text
