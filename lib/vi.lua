-- vi.lua -- the editor behind vi and vim (bin/vi.lua lists the commands)
--
--   require("vi").main(args, { vim = true })
--
-- vim is the same editor with colours on a colour screen: syntax
-- highlighting (lib/syntax.lua) for Lua and ccsh scripts, coloured line
-- numbers and the matches of the last search (:set hlsearch).
--
-- How it works.  Every key, wherever it came from (the keyboard, a telnet
-- client, a paste, a count or `.` replaying keys), becomes a token: a
-- character ("x", " ", "$") or a name in angle brackets ("<Esc>", "<CR>",
-- "<C-r>", "<Up>").  getKey() hands out the next one, drawing the screen
-- first when none is waiting, so each command is plain code that reads
-- the keys it needs as it goes.  `.` puts the tokens of the last change
-- back in the queue.  Undo keeps a copy of the line list from before each
-- change.  The editor's state lives in this file's own environment (the
-- prelude below), so it has no locals to run out of.

local _ENV = setmetatable({}, { __index = _ENV })
local regex = require("regex")
local scan = require("scan")
local text = require("text")
local syntax = require("syntax")
local fileio = require("fileio")
local tables = require("tables")
local V = {}

UNDO_MAX = 200
PAIR = { ["("] = { ")", 1 }, [")"] = { "(", -1 }, ["["] = { "]", 1 }, ["]"] = { "[", -1 },
    ["{"] = { "}", 1 }, ["}"] = { "{", -1 } }

-- commands that change the text: undone as one, repeated by `.`
CHANGE = {}
for _, k in ipairs({ "x", "X", "d", "c", "s", "S", "C", "D", "p", "P", "r", "J", "~", "i", "a",
    "I", "A", "o", "O", "R", ">", "<", "&", "<C-a>", "<C-x>", "<Insert>" }) do CHANGE[k] = true end

-- :set's options: full name -> { short name, kind }
OPTIONS = {
    number = { "nu", "bool" }, tabstop = { "ts", "num" }, shiftwidth = { "sw", "num" },
    expandtab = { "et", "bool" }, autoindent = { "ai", "bool" }, ignorecase = { "ic", "bool" },
    smartcase = { "scs", "bool" }, wrapscan = { "ws", "bool" }, readonly = { "ro", "bool" },
    hlsearch = { "hls", "bool" }, syntax = { "syn", "str" }, filetype = { "ft", "str" },
}
VIM_ONLY = { hlsearch = true, syntax = true, filetype = true }
-- :set syntax= and filetype= values: the language, false for none, or
-- "detect" to go by the file again
LANG_VALUES = { [""] = false, off = false, none = false, on = "detect",
    lua = "lua", sh = "sh", ccsh = "sh", bash = "sh" }

--------------------------------------------------------------------------
-- Little helpers
--------------------------------------------------------------------------

function clamp(v, a, b)
    if v < a then return a elseif v > b then return b end
    return v
end

function fail(e) error(e, 0) end

function beep() bad = true end

function say(message, isErr) msg, msgErr = message, isErr or false end

function nextVer() verCounter = verCounter + 1; return verCounter end

-- Characters, as vi sees them (lib/scan's tests).  A word (w b e, *,
-- Ctrl+W) is letters, digits and _; a big word (W B E) anything but blanks.
isDigit, isAlpha, isAlnum, isSpace = scan.isDigit, scan.isAlpha, scan.isAlnum, scan.isSpace
isUpper = scan.isUpper
isWordChar = scan.isNameChar

-- the blanks at the start of s: its indent
function indentOf(s) return scan.new(s):readWhile(isSpace) end

-- the index of the first character of s that isn't blank (nil if none is)
function firstNonSpace(s)
    local sc = scan.new(s)
    sc:skipSpaces()
    if sc:atEnd() then return nil end
    return sc:pos()
end

-- the word starting at index i of s ("" if no word character is there)
function wordAt(s, i) return scan.new(s, i):readWhile(isWordChar) end

-- s has a capital letter in it (with smartcase, a search then minds case)
function hasUpper(s)
    for i = 1, #s do
        if isUpper(s:sub(i, i)) then return true end
    end
    return false
end

function viewHeight()
    local _, h = term.getSize()
    return math.max(1, h - 1)
end

function firstNonBlank(y)
    local s = lines[y]
    return firstNonSpace(s) or math.max(#s, 1)
end

function clampCursor()
    cy = clamp(cy, 1, #lines)
    local most = (mode == "insert" or mode == "replace") and #lines[cy] + 1 or math.max(1, #lines[cy])
    cx = clamp(cx, 1, most)
end

-- Tabs: the display column (from 0) where byte x of s starts, and the
-- byte under display column dc.
function dispCol(s, x)
    if not text.contains(s, "\t") then return x - 1 end
    local col, ts = 0, opt.tabstop
    for i = 1, math.min(x - 1, #s) do
        if s:byte(i) == 9 then col = col + ts - col % ts else col = col + 1 end
    end
    if x - 1 > #s then col = col + (x - 1 - #s) end
    return col
end

function colAt(s, dc)
    local col, ts = 0, opt.tabstop
    for i = 1, #s do
        local w = s:byte(i) == 9 and (ts - col % ts) or 1
        if dc < col + w then return i end
        col = col + w
    end
    return #s + 1
end

-- s with its tabs as spaces, and fg and bg (blit digits, one per byte)
-- widened to match.
function expand(s, fg, bg)
    if not text.contains(s, "\t") then return s, fg, bg end
    local t, f, b, col, ts = {}, {}, {}, 0, opt.tabstop
    for i = 1, #s do
        local c = s:sub(i, i)
        local n = c == "\t" and (ts - col % ts) or 1
        t[#t + 1] = c == "\t" and string.rep(" ", n) or c
        if fg then f[#f + 1] = string.rep(fg:sub(i, i), n); b[#b + 1] = string.rep(bg:sub(i, i), n) end
        col = col + n
    end
    return table.concat(t), fg and table.concat(f), bg and table.concat(b)
end

-- Where the cursor goes on its new line after an up/down move.
function applyWant()
    if want == math.huge then cx = math.max(1, #lines[cy])
    else cx = colAt(lines[cy], want) end
    clampCursor()
end

function setWant() want = dispCol(lines[cy], cx) end

--------------------------------------------------------------------------
-- Changing the text: everything goes through these
--------------------------------------------------------------------------

function changed(y)
    ver = nextVer()
    if y < synValid then synValid = y end
end

function setLine(y, s)
    if lines[y] ~= s then lines[y] = s; changed(y) end
    if s ~= "" then noLines = false end
end

-- Put the lines of list before line `at`.
function insertLines(at, list)
    local n, k = #lines, #list
    if k == 0 then return end
    for i = n, at, -1 do lines[i + k] = lines[i] end
    for i = 1, k do lines[at + i - 1] = list[i] end
    noLines = false
    changed(at)
end

function removeLines(a, b)
    local n, k = #lines, b - a + 1
    for i = a, n - k do lines[i] = lines[i + k] end
    for i = n - k + 1, n do lines[i] = nil end
    if #lines == 0 then lines[1], noLines = "", true end    -- (written as an empty file)
    changed(a)
end

-- Put text (newlines split it) at (y, x); returns the place after it.
function insertAt(y, x, body)
    local s = lines[y]
    local before, after = s:sub(1, x - 1), s:sub(x)
    local parts = text.split(body, "\n", true)
    if text.endsWith(body, "\n") then parts[#parts + 1] = "" end
    if #parts == 1 then
        setLine(y, before .. parts[1] .. after)
        return y, x + #parts[1]
    end
    setLine(y, before .. parts[1])
    local new = {}
    for i = 2, #parts do new[#new + 1] = parts[i] end
    local lastLen = #new[#new]
    new[#new] = new[#new] .. after
    insertLines(y + 1, new)
    return y + #parts - 1, lastLen + 1
end

-- The text from (y1, x1) to (y2, x2), both ends included.
function textOf(y1, x1, y2, x2)
    if y1 == y2 then return lines[y1]:sub(x1, x2) end
    local t = { lines[y1]:sub(x1) }
    for y = y1 + 1, y2 - 1 do t[#t + 1] = lines[y] end
    t[#t + 1] = lines[y2]:sub(1, x2)
    return table.concat(t, "\n")
end

function deleteText(y1, x1, y2, x2)
    local head, tail = lines[y1]:sub(1, x1 - 1), lines[y2]:sub(x2 + 1)
    if y2 > y1 then removeLines(y1 + 1, y2) end
    setLine(y1, head .. tail)
end

function insertText(typed)
    cy, cx = insertAt(cy, cx, typed)
end

--------------------------------------------------------------------------
-- Undo
--------------------------------------------------------------------------

function beginChange()
    changeDepth = changeDepth + 1
    if changeDepth > 1 then return end
    local copy = {}
    for i = 1, #lines do copy[i] = lines[i] end
    undoStack[#undoStack + 1] = { lines = copy, cy = cy, cx = cx, ver = ver, noLines = noLines }
    if #undoStack > UNDO_MAX then table.remove(undoStack, 1) end
end

function endChange()
    changeDepth = changeDepth - 1
    if changeDepth > 0 then return end
    local u = undoStack[#undoStack]
    if u and u.ver == ver then undoStack[#undoStack] = nil     -- nothing changed after all
    elseif u then redoStack = {} end
end

function withChange(f, ...)
    beginChange()
    local ok, e = pcall(f, ...)
    endChange()
    if not ok then error(e, 0) end
end

-- Move one state from `from` to `to`, keeping the present one in `to`.
function swapState(from, to)
    local u = table.remove(from)
    if not u then return false end
    to[#to + 1] = { lines = lines, cy = cy, cx = cx, ver = ver, noLines = noLines }
    lines, cy, cx, ver, noLines = u.lines, u.cy, u.cx, u.ver, u.noLines
    synValid = 1
    return true
end

function undo(n)
    local done = 0
    for _ = 1, n do
        if not swapState(undoStack, redoStack) then break end
        done = done + 1
    end
    if done == 0 then say("Already at oldest change") end
    clampCursor()
end

function redo(n)
    local done = 0
    for _ = 1, n do
        if not swapState(redoStack, undoStack) then break end
        done = done + 1
    end
    if done == 0 then say("Already at newest change") end
    clampCursor()
end

--------------------------------------------------------------------------
-- Registers
--------------------------------------------------------------------------

function setReg(name, value, linewise, yank)
    if name == "_" then return end
    local r = { text = value, linewise = linewise }
    if name and isUpper(name) then
        local lower = name:lower()
        local old = regs[lower]
        if old then
            r = { text = old.text .. ((old.linewise or linewise) and "\n" or "") .. value,
                linewise = old.linewise or linewise }
        end
        name = lower
    end
    if name and name ~= '"' then regs[name] = r end
    regs['"'] = r
    if yank and (not name or name == '"') then regs["0"] = r end
end

--------------------------------------------------------------------------
-- Keys
--------------------------------------------------------------------------

function keyTokens()
    local t = {}
    for name, tok in pairs({ enter = "<CR>", numPadEnter = "<CR>", backspace = "<BS>", tab = "<Tab>",
        delete = "<Del>", up = "<Up>", down = "<Down>", left = "<Left>", right = "<Right>",
        home = "<Home>", ["end"] = "<End>", pageUp = "<PageUp>", pageDown = "<PageDown>",
        insert = "<Insert>", escape = "<Esc>" }) do
        if keys[name] then t[keys[name]] = tok end
    end
    return t
end

-- An event as a token, or nil (it was taken care of, or means nothing).
-- Ctrl+letter comes as the Ctrl key's event, then the letter's (and
-- maybe its char event, which is dropped).  Ctrl with Alt is AltGr,
-- which types a character.  Ctrl+[ and Ctrl+C stand in for Esc, which
-- closes the computer's screen in the game.
function translate(ev, a, b, c)
    if ev == "char" then
        local s = swallow
        swallow = nil
        if s and a:lower() == s then return nil end
        return a
    elseif ev == "key" then
        swallow = nil
        if a == keys.leftCtrl or a == keys.rightCtrl then ctrlDown = true; return nil end
        if a == keys.leftAlt or a == keys.rightAlt then altDown = true; return nil end
        if ctrlDown and not altDown then
            local name = keys.getName and keys.getName(a)
            if name and #name == 1 then swallow = name; return "<C-" .. name .. ">" end
            if a == keys.leftBracket then swallow = "["; return "<Esc>" end
        end
        return KEYTOK[a]
    elseif ev == "key_up" then
        if a == keys.leftCtrl or a == keys.rightCtrl then ctrlDown = false
        elseif a == keys.leftAlt or a == keys.rightAlt then altDown = false end
    elseif ev == "paste" then
        pasted = a
        return "<Paste>"
    elseif ev == "terminate" then
        return "<C-c>"
    elseif ev == "mouse_scroll" then
        if not cmdline then scrollBy(a * 3); needRender = true end
    elseif ev == "mouse_click" then
        if a == 1 and not cmdline then click(b, c); needRender = true end
    elseif ev == "term_resize" then
        needRender = true
    end
    return nil
end

function nextToken()
    if #queue > 0 then return table.remove(queue, 1) end
    while true do
        if needRender then render(); needRender = false end
        local t = translate(os.pullEventRaw())
        if t then needRender = true; return t end
    end
end

function getKey()
    local t = nextToken()
    rec[#rec + 1] = t
    if mode == "normal" and not cmdline then
        showcmd = (showcmd .. (#t == 1 and t or "")):sub(-10)
    end
    return t
end

function readCount(k)
    local n
    while isDigit(k) and (n or k ~= "0") do
        n = math.min((n or 0) * 10 + tonumber(k), 99999)
        k = getKey()
    end
    return n, k
end

--------------------------------------------------------------------------
-- The screen
--------------------------------------------------------------------------

function colourScreen()
    return vimMode and term.isColour ~= nil and term.isColour() and term.blit ~= nil
end

function currentLang()
    if not vimMode or not opt.syntax then return nil end
    if langSet ~= nil then return langSet or nil end
    return detected
end

-- The colours of line i (computing the lines above it first, as a long
-- string or comment carries from one line to the next).
function fgOf(i)
    local lang = currentLang()
    if lang ~= synLang then synLang, synValid, synStates = lang, 1, {} end
    if not lang then return nil end
    while synValid <= i do
        local fg, st = syntax.line(lang, lines[synValid], synStates[synValid])
        synFg[synValid] = fg
        synStates[synValid + 1] = st
        synValid = synValid + 1
    end
    return synFg[i]
end

-- The last search's matches on line y, as { start, stop } pairs.
function matchesOf(y)
    if not (opt.hlsearch and vimMode and lastSearch and not hlHidden) then return nil end
    local ok, re = pcall(compile, lastSearch.pat)
    if not ok then return nil end
    local s, init, out = lines[y], 1, {}
    while init <= #s do
        local a, b = re:find(s, init)
        if not a then break end
        if b >= a then out[#out + 1] = { a, b } end
        init = math.max(b, a) + 1
    end
    return out
end

-- The line and column, and where the view is; tight leaves out the padding
-- between them (for a narrow screen).
function ruler(tight)
    local s = lines[cy]
    local col
    if #s == 0 then col = "0-1"
    else
        local d = dispCol(s, cx) + 1
        col = d == cx and tostring(cx) or (cx .. "-" .. d)
    end
    local v = viewHeight()
    local where
    if #lines <= v then where = "All"
    elseif top <= 1 then where = "Top"
    elseif top + v - 1 >= #lines then where = "Bot"
    else where = math.floor((top - 1) * 100 / (#lines - v)) .. "%" end
    return string.format(tight and "%s %s" or "%-8s %s", cy .. "," .. col, where)
end

function render()
    local w, h = term.getSize()
    local view = math.max(1, h - 1)
    gutter = opt.number and math.max(3, #tostring(#lines)) + 1 or 0
    local tw = math.max(1, w - gutter)
    clampCursor()
    if cy < top then top = cy elseif cy > top + view - 1 then top = cy - view + 1 end
    top = clamp(top, 1, #lines)
    local dc = dispCol(lines[cy], cx)
    if dc < leftcol then leftcol = math.max(0, dc - math.floor(tw / 2))
    elseif dc >= leftcol + tw then leftcol = dc - math.floor(tw / 2) end
    local colour = colourScreen()
    term.setBackgroundColour(colours.black)
    term.setTextColour(colours.white)
    term.setCursorBlink(false)
    for r = 1, view do
        local y = top + r - 1
        local s = lines[y]
        term.setCursorPos(1, r)
        if s then
            local gut = gutter > 0 and string.format("%" .. (gutter - 1) .. "d ", y) or ""
            if colour then
                local fg = fgOf(y) or string.rep("0", #s)
                local bg = string.rep("f", #s)
                for _, m in ipairs(matchesOf(y) or {}) do
                    local a, b = m[1], m[2]
                    fg = fg:sub(1, a - 1) .. string.rep("f", b - a + 1) .. fg:sub(b + 1)
                    bg = bg:sub(1, a - 1) .. string.rep("4", b - a + 1) .. bg:sub(b + 1)
                end
                local shown, f, bk = expand(s, fg, bg)
                shown, f, bk = shown:sub(leftcol + 1, leftcol + tw), f:sub(leftcol + 1, leftcol + tw), bk:sub(leftcol + 1, leftcol + tw)
                term.blit(gut .. text.padRight(shown, tw), string.rep("4", #gut) .. text.padRight(f, tw, "0"),
                    string.rep("f", #gut) .. text.padRight(bk, tw, "f"))
            else
                local shown = (expand(s)):sub(leftcol + 1, leftcol + tw)
                term.write(gut .. text.padRight(shown, tw))
            end
        elseif colour then
            term.blit("~" .. string.rep(" ", w - 1), "b" .. string.rep("0", w - 1), string.rep("f", w))
        else
            term.write("~" .. string.rep(" ", w - 1))
        end
    end
    term.setCursorPos(1, h)
    if cmdline then
        local s = cmdline.prefix .. cmdline.text
        local cur = #cmdline.prefix + cmdline.pos
        local off = math.max(0, cur - w + 1)
        term.write(text.padRight(s:sub(off + 1, off + w), w))
        term.setCursorPos(cur - off + 1, h)
    else
        local left = msg or (mode == "insert" and "-- INSERT --") or (mode == "replace" and "-- REPLACE --") or ""
        local right = ruler()
        if #left + 1 + #right > w then right = ruler(true) end
        -- (the keys of a command still being typed: not once it's put vi in insert mode)
        if showcmd ~= "" and mode == "normal" then right = showcmd .. "  " .. right end
        if #right >= w or (msg and #msg + #right + 1 > w) then right = "" end    -- a long message gets the line
        local room = w - #right - (right ~= "" and 1 or 0)
        left = left:sub(1, room)
        local line = text.padRight(left, w - #right) .. right
        if colour and msg and msgErr then
            term.blit(line, string.rep("e", #left) .. string.rep("0", w - #left), string.rep("f", w))
        else
            term.write(line)
        end
        term.setCursorPos(gutter + dc - leftcol + 1, cy - top + 1)
    end
    term.setCursorBlink(true)
end

-- Scroll the view d lines, keeping the cursor on it.
function scrollBy(d)
    local v = viewHeight()
    top = clamp(top + d, 1, math.max(1, #lines))
    if cy < top then cy = top elseif cy > top + v - 1 then cy = top + v - 1 end
    cy = clamp(cy, 1, #lines)
    applyWant()
end

function click(x, y)
    local _, h = term.getSize()
    if y >= h then return end
    cy = clamp(top + y - 1, 1, #lines)
    cx = colAt(lines[cy], math.max(0, leftcol + x - 1 - (gutter or 0)))
    clampCursor()
    setWant()
end

--------------------------------------------------------------------------
-- Motions
--------------------------------------------------------------------------

-- 0 blank (or past the end), 1 punctuation, 2 a word character; for the
-- big-word motions (W B E) anything not blank is 1.
function cls(s, x, big)
    local c = s:sub(x, x)
    if c == "" or isSpace(c) then return 0 end
    if big or not isWordChar(c) then return 1 end
    return 2
end

function wordFwd(y, x, big)
    local s = lines[y]
    local c = cls(s, x, big)
    if c ~= 0 then while x <= #s and cls(s, x, big) == c do x = x + 1 end end
    while true do
        while x <= #s and cls(s, x, big) == 0 do x = x + 1 end
        if x <= #s then return y, x end
        if y >= #lines then return y, #s + 1, true end
        y, x = y + 1, 1
        s = lines[y]
        if s == "" then return y, 1 end
    end
end

function wordEnd(y, x, big)
    local s = lines[y]
    x = x + 1
    while true do
        while x <= #s and cls(s, x, big) == 0 do x = x + 1 end
        if x <= #s then break end
        if y >= #lines then return y, math.max(#s, 1), true end
        y, x = y + 1, 1
        s = lines[y]
    end
    local c = cls(s, x, big)
    while x < #s and cls(s, x + 1, big) == c do x = x + 1 end
    return y, x
end

function wordBack(y, x, big)
    local s = lines[y]
    x = x - 1
    while true do
        while x >= 1 and cls(s, x, big) == 0 do x = x - 1 end
        if x >= 1 then break end
        if y <= 1 then return 1, 1, true end
        y = y - 1
        s = lines[y]
        x = #s
        if s == "" then return y, 1 end
    end
    local c = cls(s, x, big)
    while x > 1 and cls(s, x - 1, big) == c do x = x - 1 end
    return y, x
end

function findChar(kind, ch, n)
    local s, x = lines[cy], cx
    local dir = (kind == "f" or kind == "t") and 1 or -1
    if (kind == "t" or kind == "T") and s:sub(x + dir, x + dir) == ch and repeating then x = x + dir end
    for _ = 1, n do
        local i = x + dir
        while i >= 1 and i <= #s and s:sub(i, i) ~= ch do i = i + dir end
        if i < 1 or i > #s then return nil end
        x = i
    end
    if kind == "f" then return cy, x, "incl" end
    if kind == "t" then return cy, x - 1, "incl" end
    if kind == "F" then return cy, x, "excl" end
    return cy, x + 1, "excl"
end

function matchPair()
    local s = lines[cy]
    -- the first bracket from the cursor on
    local x = cx
    while x <= #s and not PAIR[s:sub(x, x)] do x = x + 1 end
    if x > #s then return nil end
    local c = s:sub(x, x)
    local other, dir = PAIR[c][1], PAIR[c][2]
    local depth, y = 0, cy
    while y >= 1 and y <= #lines do
        local l = lines[y]
        local i = (y == cy) and x or (dir > 0 and 1 or #l)
        while i >= 1 and i <= #l do
            local ch = l:sub(i, i)
            if ch == c then depth = depth + 1
            elseif ch == other then
                depth = depth - 1
                if depth == 0 then return y, i end
            end
            i = i + dir
        end
        y = y + dir
    end
    return nil
end

function compile(pat)
    local ic = opt.ignorecase and not (opt.smartcase and hasUpper(pat))
    local ok, re, e = pcall(regex.compile, pat, { icase = ic })
    if not ok or not re then fail("E383: Invalid search string: " .. pat) end
    return re
end

-- The n'th match of pat from (y, x) going dir (1 forward, -1 back), or
-- an error.  Says so when the search went round the end.
function search(pat, dir, y, x, n)
    local re = compile(pat)
    local nl, wrapped = #lines, false
    for _ = 1, n do
        local fy, fx
        for step = 0, nl do
            local raw = y + dir * step
            if raw < 1 or raw > nl then
                if not opt.wrapscan then break end
                wrapped = true
            end
            local ly = (raw - 1) % nl + 1
            local s = lines[ly]
            if dir > 0 then
                local init = step == 0 and x + 1 or 1
                local a = init <= #s + 1 and re:find(s, init)
                if a and (step < nl or a <= x) then fy, fx = ly, a; break end
            else
                local hi = step == 0 and x - 1 or math.huge
                local lo = step == nl and x or 1
                local best, init = nil, 1
                while init <= #s + 1 do
                    local a = re:find(s, init)
                    if not a or a > hi then break end
                    if a >= lo then best = a end
                    init = a + 1
                end
                if best then fy, fx = ly, best; break end
            end
        end
        if not fy then
            if not opt.wrapscan then
                fail((dir > 0 and "E385: Search hit BOTTOM without match for: " or "E384: Search hit TOP without match for: ") .. pat)
            end
            fail("E486: Pattern not found: " .. pat)
        end
        y, x = fy, fx
    end
    if wrapped then say(dir > 0 and "search hit BOTTOM, continuing at TOP" or "search hit TOP, continuing at BOTTOM", true)
    else say((dir > 0 and "/" or "?") .. pat) end
    return y, x
end

-- The characters with a meaning in a search pattern, and its delimiter /.
REGEX_SPECIAL = scan.oneOf(".[]*^$\\/")

-- s as a pattern that finds it as it is: a backslash before each of those.
function escapePattern(s)
    local out = {}
    for i = 1, #s do
        local c = s:sub(i, i)
        if REGEX_SPECIAL(c) then out[#out + 1] = "\\" end
        out[#out + 1] = c
    end
    return table.concat(out)
end

-- Where motion k (count n) goes from the cursor: y, x, the kind
-- ("excl", "incl" or "line") and how the cursor lands ("want": the
-- column it had; "fnb": the first non-blank; "eol"; nil: at x).
-- nil if it can't go.  op: an operator is waiting for it.
function motion(k, n, op)
    local cnt = n or 1
    local s = lines[cy]
    if k == "h" or k == "<Left>" or k == "<BS>" or k == "<C-h>" then
        if cx <= 1 then return nil end
        return cy, math.max(1, cx - cnt), "excl"
    elseif k == "l" or k == "<Right>" or k == " " then
        if op then
            if #s == 0 then return nil end
            return cy, math.min(cx + cnt, #s + 1), "excl"
        end
        if cx >= #s then return nil end
        return cy, math.min(cx + cnt, #s), "excl"
    elseif k == "j" or k == "<Down>" or k == "<C-n>" or k == "<C-j>" then
        if cy >= #lines then return nil end
        return math.min(cy + cnt, #lines), cx, "line", "want"
    elseif k == "k" or k == "<Up>" or k == "<C-p>" then
        if cy <= 1 then return nil end
        return math.max(cy - cnt, 1), cx, "line", "want"
    elseif k == "+" or k == "<CR>" then
        if cy >= #lines then return nil end
        return math.min(cy + cnt, #lines), 1, "line", "fnb"
    elseif k == "-" then
        if cy <= 1 then return nil end
        return math.max(cy - cnt, 1), 1, "line", "fnb"
    elseif k == "_" then
        return math.min(cy + cnt - 1, #lines), 1, "line", "fnb"
    elseif k == "0" or k == "<Home>" then
        return cy, 1, "excl"
    elseif k == "^" then
        return cy, firstNonBlank(cy), "excl"
    elseif k == "$" or k == "<End>" then
        local y = math.min(cy + cnt - 1, #lines)
        return y, math.max(#lines[y], 1), "incl", "eol"
    elseif k == "|" then
        return cy, math.min(colAt(s, cnt - 1), math.max(#s, 1)), "excl"
    elseif k == "w" or k == "W" or k == "b" or k == "B" or k == "e" or k == "E" then
        local big = k == "W" or k == "B" or k == "E"
        local f = (k == "w" or k == "W") and wordFwd or (k == "e" or k == "E") and wordEnd or wordBack
        local y, x, stuck = cy, cx, false
        for _ = 1, cnt do y, x, stuck = f(y, x, big) end
        if y == cy and x == cx then return nil end
        if stuck and not op and (k == "w" or k == "W") then x = math.max(#lines[y], 1) end
        return y, x, (k == "e" or k == "E") and "incl" or "excl"
    elseif k == "G" or k == "gg" then
        jumpFrom = { cy, cx }
        return clamp(n or (k == "G" and #lines or 1), 1, #lines), 1, "line", "fnb"
    elseif k == "H" or k == "L" or k == "M" then
        local bottom = math.min(#lines, top + viewHeight() - 1)
        local y = k == "H" and math.min(top + cnt - 1, bottom) or k == "L" and math.max(bottom - cnt + 1, top)
            or top + math.floor((bottom - top) / 2)
        return y, 1, "line", "fnb"
    elseif k == "f" or k == "F" or k == "t" or k == "T" then
        local ch = getKey()
        if #ch ~= 1 then return nil end
        lastFind = { k, ch }
        return findChar(k, ch, cnt)
    elseif k == ";" or k == "," then
        if not lastFind then return nil end
        local kind = lastFind[1]
        if k == "," then kind = ({ f = "F", F = "f", t = "T", T = "t" })[kind] end
        repeating = true
        local y, x, kd = findChar(kind, lastFind[2], cnt)
        repeating = false
        return y, x, kd
    elseif k == "%" then
        if n then
            jumpFrom = { cy, cx }
            return clamp(math.ceil(n * #lines / 100), 1, #lines), 1, "line", "fnb"
        end
        local y, x = matchPair()
        if not y then return nil end
        jumpFrom = { cy, cx }
        return y, x, "incl"
    elseif k == "}" or k == "{" then
        local dir, y = k == "}" and 1 or -1, cy
        for _ = 1, cnt do
            y = y + dir
            while y >= 1 and y <= #lines and lines[y] == "" do y = y + dir end
            while y >= 1 and y <= #lines and lines[y] ~= "" do y = y + dir end
        end
        jumpFrom = { cy, cx }
        if y > #lines then return #lines, math.max(#lines[#lines], 1), "incl" end
        if y < 1 then return 1, 1, "excl" end
        return y, 1, "excl"
    elseif k == "/" or k == "?" then
        local pat = readCmdline(k, "", searchHist)
        if not pat then return nil end
        if pat == "" then
            if not lastSearch then fail("E35: No previous regular expression") end
            pat = lastSearch.pat
        end
        lastSearch, hlHidden = { pat = pat, dir = k == "/" and 1 or -1 }, false
        jumpFrom = { cy, cx }
        local y, x = search(pat, lastSearch.dir, cy, cx, cnt)
        return y, x, "excl"
    elseif k == "n" or k == "N" then
        if not lastSearch then fail("E35: No previous regular expression") end
        hlHidden = false
        jumpFrom = { cy, cx }
        local y, x = search(lastSearch.pat, k == "n" and lastSearch.dir or -lastSearch.dir, cy, cx, cnt)
        return y, x, "excl"
    elseif k == "*" or k == "#" then
        -- the word under the cursor (from its start), else the next one on the line
        local a = cx
        while a > 1 and isWordChar(s:sub(a - 1, a - 1)) do a = a - 1 end
        local word = wordAt(s, a)
        if word == "" then
            local b = cx
            while b <= #s and not isWordChar(s:sub(b, b)) do b = b + 1 end
            word = wordAt(s, b)
        end
        if word == "" then fail("E348: No string under cursor") end
        lastSearch, hlHidden = { pat = escapePattern(word), dir = k == "*" and 1 or -1 }, false
        jumpFrom = { cy, cx }
        local y, x = search(lastSearch.pat, lastSearch.dir, cy, a, cnt)
        return y, x, "excl"
    elseif k == "'" or k == "`" then
        local c = getKey()
        local m = (c == "'" or c == "`") and marks["'"] or marks[c]
        if not m then fail("E20: Mark not set") end
        jumpFrom = { cy, cx }
        local y = clamp(m[1], 1, #lines)
        if k == "'" then return y, 1, "line", "fnb" end
        return y, clamp(m[2], 1, math.max(#lines[y], 1)), "excl"
    end
    return nil
end

-- Move the cursor by motion k.
function move(k, n)
    local y, x, kind, how = motion(k, n)
    if not y then return beep() end
    if jumpFrom then marks["'"], jumpFrom = jumpFrom, nil end
    cy = y
    if how == "want" then applyWant()
    elseif how == "fnb" then cx = firstNonBlank(cy); clampCursor(); setWant()
    elseif how == "eol" then cx = x; clampCursor(); want = math.huge
    else cx = x; clampCursor(); setWant() end
end

--------------------------------------------------------------------------
-- Operators: d c y > <
--------------------------------------------------------------------------

function shiftLines(y1, y2, dir, times)
    local sw = opt.shiftwidth
    for y = y1, y2 do
        local s = lines[y]
        if s ~= "" then
            local ws = indentOf(s)
            local width = dispCol(ws .. "x", #ws + 1)
            local new = math.max(0, width + dir * sw * (times or 1))
            local indent = opt.expandtab and string.rep(" ", new)
                or string.rep("\t", math.floor(new / opt.tabstop)) .. string.rep(" ", new % opt.tabstop)
            setLine(y, indent .. s:sub(#ws + 1))
        end
    end
    local k = y2 - y1 + 1
    if k > 2 then say(k .. " lines " .. (dir > 0 and ">" or "<") .. "ed 1 time") end
end

function linesReport(k, what)
    if k > 2 then say(k .. " " .. what) end
end

-- Do operator op over a span: lines y1..y2 (kind "line") or the text
-- (y1, x1)..(y2, x2) with both ends in.
function apply(op, reg, y1, x1, y2, x2, kind)
    if kind == "line" then
        local k = y2 - y1 + 1
        if op == ">" or op == "<" then
            shiftLines(y1, y2, op == ">" and 1 or -1)
            cy = y1; cx = firstNonBlank(cy)
            return
        end
        local taken = table.concat(lines, "\n", y1, y2)
        if op == "y" then
            setReg(reg, taken, true, true)
            if y1 < cy then cy = y1 end
            linesReport(k, "lines yanked")
        elseif op == "d" then
            setReg(reg, taken, true)
            removeLines(y1, y2)
            cy = math.min(y1, #lines); cx = firstNonBlank(cy)
            linesReport(k, "fewer lines")
        elseif op == "c" then
            setReg(reg, taken, true)
            local indent = opt.autoindent and indentOf(lines[y1]) or ""
            if y2 > y1 then removeLines(y1 + 1, y2) end
            setLine(y1, indent)
            cy, cx = y1, #indent + 1
            mode = "insert"
            return insertMode()
        end
    else
        if op == ">" or op == "<" then
            shiftLines(y1, y2, op == ">" and 1 or -1)
            cy = y1; cx = firstNonBlank(cy)
            return
        end
        local taken = textOf(y1, x1, y2, x2)
        if op == "y" then
            setReg(reg, taken, false, true)
            cy, cx = y1, x1
        elseif op == "d" then
            setReg(reg, taken, false)
            deleteText(y1, x1, y2, x2)
            cy, cx = y1, x1
        elseif op == "c" then
            setReg(reg, taken, false)
            deleteText(y1, x1, y2, x2)
            cy, cx = y1, x1
            mode = "insert"
            return insertMode()
        end
    end
    clampCursor()
    setWant()
end

function operate(op, n, reg)
    local k = getKey()
    local m
    m, k = readCount(k)
    if n or m then n = (n or 1) * (m or 1) end
    if k == "<Esc>" or k == "<C-c>" then return end
    if k == op then                                   -- dd cc yy >> <<
        local last = cy + (n or 1) - 1
        if last > #lines then
            if op ~= "y" and op ~= "d" and op ~= "c" then last = #lines else last = #lines end
        end
        return apply(op, reg, cy, 1, last, 0, "line")
    end
    if k == "g" then
        if getKey() ~= "g" then return beep() end
        k = "gg"
    end
    local s = lines[cy]
    -- cw on a word changes just that word (like ce)
    if op == "c" and (k == "w" or k == "W") and cls(s, cx, k == "W") ~= 0 then
        local c, x = cls(s, cx, k == "W"), cx
        local cnt = n or 1
        local y = cy
        if cnt == 1 and cls(s, cx + 1, k == "W") ~= c then
            return apply("c", reg, cy, cx, cy, cx, "incl")
        end
        y, x = wordEnd(y, x - 1, k == "W")
        for _ = 2, cnt do y, x = wordEnd(y, x, k == "W") end
        return apply("c", reg, cy, cx, y, x, "incl")
    end
    local y, x, kind = motion(k, n, op)
    if jumpFrom then marks["'"], jumpFrom = jumpFrom, nil end
    if not y then return beep() end
    -- dw at a line's last word stops at the end of the line
    if (k == "w" or k == "W") and y > cy and scan.isBlank(lines[y]:sub(1, x - 1)) then
        y, x = y - 1, #lines[y - 1] + 1
        if y < cy then y, x = cy, #lines[cy] + 1 end
    end
    local y1, x1, y2, x2 = cy, cx, y, x
    if y2 < y1 or (y2 == y1 and x2 < x1) then y1, x1, y2, x2 = y2, x2, y1, x1 end
    if kind == "excl" then
        if x2 == 1 and y2 > y1 then
            -- an exclusive motion ending at the start of a later line
            y2 = y2 - 1
            x2 = #lines[y2]
            kind = "incl"
            if scan.isBlank(lines[y1]:sub(1, x1 - 1)) then kind = "line" end
        else
            x2 = x2 - 1
        end
    end
    if kind == "line" then return apply(op, reg, y1, 1, y2, 0, "line") end
    return apply(op, reg, y1, x1, y2, x2, kind)
end

--------------------------------------------------------------------------
-- Insert mode
--------------------------------------------------------------------------

-- Open a new line below (or above) the cursor, indented like this one.
function openLine(below)
    local indent = opt.autoindent and indentOf(lines[cy]) or ""
    local at = below and cy + 1 or cy
    insertLines(at, { indent })
    cy, cx = at, #indent + 1
    aiLine = indent ~= "" and cy or nil
end

-- Type into the text until Esc.  kind "replace": typing overwrites.  cnt:
-- what was typed goes in cnt times; again(text) puts in each extra copy
-- (the default: at the cursor).
function insertMode(kind, cnt, again)
    mode = kind or "insert"
    clampCursor()
    local typed, moved = {}, false
    local orig, origY = lines[cy], cy
    while true do
        local k = getKey()
        local s = lines[cy]
        if k == "<Esc>" or k == "<C-c>" then break
        elseif k == "<CR>" then
            local indent = opt.autoindent and indentOf(s) or ""
            local before, after = s:sub(1, cx - 1), s:sub(cx)
            if aiLine == cy and scan.isBlank(before) then before = "" end
            if indent ~= "" then after = text.trimStart(after) end
            setLine(cy, before)
            insertLines(cy + 1, { indent .. after })
            cy, cx = cy + 1, #indent + 1
            aiLine = indent ~= "" and cy or nil
            typed[#typed + 1] = "\n"
            orig, origY = lines[cy], cy
        elseif k == "<BS>" or k == "<C-h>" then
            if mode == "replace" then
                if cx > 1 then
                    cx = cx - 1
                    if cy == origY then
                        local o = orig:sub(cx, cx)
                        setLine(cy, s:sub(1, cx - 1) .. o .. s:sub(cx + 1))
                    end
                end
            elseif cx > 1 then
                local before = s:sub(1, cx - 1)
                local del = 1
                -- in an indent of spaces, back to the last shiftwidth stop
                local spaces = before ~= "" and before == string.rep(" ", #before)
                if opt.expandtab and spaces then del = (#before - 1) % opt.shiftwidth + 1 end
                setLine(cy, before:sub(1, #before - del) .. s:sub(cx))
                cx = cx - del
            elseif cy > 1 then
                local prev = lines[cy - 1]
                setLine(cy - 1, prev .. s)
                removeLines(cy, cy)
                cy, cx = cy - 1, #prev + 1
            end
            if typed[#typed] and typed[#typed] ~= "\n" then typed[#typed] = nil else moved = true end
        elseif k == "<Del>" then
            if cx <= #s then setLine(cy, s:sub(1, cx - 1) .. s:sub(cx + 1))
            elseif cy < #lines then
                setLine(cy, s .. lines[cy + 1])
                removeLines(cy + 1, cy + 1)
            end
            moved = true
        elseif k == "<Tab>" then
            local t = "\t"
            if opt.expandtab then
                local sw = opt.shiftwidth
                t = string.rep(" ", sw - dispCol(s, cx) % sw)
            end
            if mode == "replace" then setLine(cy, s:sub(1, cx - 1) .. t .. s:sub(cx + #t))
            else setLine(cy, s:sub(1, cx - 1) .. t .. s:sub(cx)) end
            cx = cx + #t
            typed[#typed + 1] = t
            aiLine = nil
        elseif k == "<C-w>" then
            local a = cx
            while a > 1 and isSpace(s:sub(a - 1, a - 1)) do a = a - 1 end
            if a > 1 then
                local c = cls(s, a - 1)
                while a > 1 and cls(s, a - 1) == c do a = a - 1 end
            end
            setLine(cy, s:sub(1, a - 1) .. s:sub(cx))
            cx = a
            moved = true
        elseif k == "<C-u>" then
            local keep = indentOf(s)
            if cx - 1 <= #keep then keep = "" end
            setLine(cy, keep .. s:sub(cx))
            cx = #keep + 1
            moved = true
        elseif k == "<C-r>" then
            local r = regs[getKey()]
            if r then insertText(r.text .. (r.linewise and "\n" or "")) end
            moved = true
        elseif k == "<Paste>" then
            insertText(pasted or "")
            moved = true
        elseif k == "<Left>" or k == "<Right>" or k == "<Up>" or k == "<Down>" or k == "<Home>" or k == "<End>" then
            if k == "<Left>" then cx = math.max(1, cx - 1)
            elseif k == "<Right>" then cx = math.min(#s + 1, cx + 1)
            elseif k == "<Up>" then cy = math.max(1, cy - 1)
            elseif k == "<Down>" then cy = math.min(#lines, cy + 1)
            elseif k == "<Home>" then cx = 1
            else cx = #s + 1 end
            clampCursor()
            moved = true
            aiLine = nil
            orig, origY = lines[cy], cy
        elseif #k == 1 then
            if mode == "replace" and cx <= #s then setLine(cy, s:sub(1, cx - 1) .. k .. s:sub(cx + 1))
            else setLine(cy, s:sub(1, cx - 1) .. k .. s:sub(cx)) end
            cx = cx + 1
            typed[#typed + 1] = k
            aiLine = nil
        end
    end
    if aiLine == cy and lines[cy] ~= "" and scan.isBlank(lines[cy]) then setLine(cy, ""); cx = 1 end
    aiLine = nil
    if cnt and cnt > 1 and not moved then
        local t = table.concat(typed)
        for _ = 2, cnt do
            if again then again(t) else insertText(t) end
        end
    end
    mode = "normal"
    if cx > 1 then cx = cx - 1 end
    clampCursor()
    setWant()
end

--------------------------------------------------------------------------
-- Normal-mode commands
--------------------------------------------------------------------------

function put(reg, after, n)
    local r = regs[reg or '"']
    if not r then fail("E353: Nothing in register " .. (reg or '"')) end
    if r.linewise then
        local list, one = {}, text.split(r.text, "\n", true)
        for _ = 1, n do for _, l in ipairs(one) do list[#list + 1] = l end end
        local at = after and cy + 1 or cy
        insertLines(at, list)
        cy = at; cx = firstNonBlank(cy)
        linesReport(#list, "more lines")
    else
        local copies = string.rep(r.text, n)
        local x = (after and #lines[cy] > 0) and cx + 1 or cx
        local y2, x2 = insertAt(cy, x, copies)
        if y2 == cy then cx = x2 - 1 else cx = x end
    end
    clampCursor()
    setWant()
end

function join(y, count, spaces)
    for _ = 1, count - 1 do
        if y >= #lines then return beep() end
        local a, b = lines[y], lines[y + 1]
        local sep = ""
        if spaces then
            b = text.trimStart(b)
            if a ~= "" and b ~= "" and not isSpace(a:sub(-1)) and b:sub(1, 1) ~= ")" then sep = " " end
        end
        removeLines(y + 1, y + 1)
        setLine(y, a .. sep .. b)
        cx = math.max(1, #a + (sep == "" and 0 or 1))
    end
    cy = y
    clampCursor()
    setWant()
end

function increment(delta)
    local s = lines[cy]
    -- the number under the cursor (from its first digit), else the next one on the line
    local i = cx
    if isDigit(s:sub(i, i)) then
        while i > 1 and isDigit(s:sub(i - 1, i - 1)) do i = i - 1 end
    end
    while i <= #s and not isDigit(s:sub(i, i)) do i = i + 1 end
    if i > #s then return beep() end
    local a = i
    local b = a + #scan.new(s, a):readWhile(isDigit) - 1
    if a > 1 and s:sub(a - 1, a - 1) == "-" then a = a - 1 end
    local str = string.format("%d", tonumber(s:sub(a, b)) + delta)
    setLine(cy, s:sub(1, a - 1) .. str .. s:sub(b + 1))
    cx = a + #str - 1
    setWant()
end

function fileInfo()
    local pct = math.floor(cy * 100 / #lines)
    say('"' .. (name or "[No Name]") .. '"' .. (ver ~= savedVer and " [Modified]" or "")
        .. (opt.readonly and " [readonly]" or "") .. " " .. #lines .. " line" .. (#lines == 1 and "" or "s")
        .. " --" .. pct .. "%--")
end

function repeatChange(n)
    local c = lastChange
    if not c then return beep() end
    local t = {}
    if c.reg then t[#t + 1] = '"'; t[#t + 1] = c.reg end
    local cnt = n or c.n
    if cnt then
        local digits = tostring(cnt)
        for i = 1, #digits do t[#t + 1] = digits:sub(i, i) end
    end
    for _, k in ipairs(c.keys) do t[#t + 1] = k end
    for i = #t, 1, -1 do table.insert(queue, 1, t[i]) end
end

function doCommand(k, n, reg)
    local cnt = n or 1
    local s = lines[cy]
    if k == "i" or k == "<Insert>" then
        insertMode("insert", cnt)
    elseif k == "a" then
        if #s > 0 then cx = cx + 1 end
        mode = "insert"
        insertMode("insert", cnt)
    elseif k == "I" then
        cx = firstNonSpace(s) or #s + 1
        mode = "insert"
        insertMode("insert", cnt)
    elseif k == "A" then
        cx = #s + 1
        mode = "insert"
        insertMode("insert", cnt)
    elseif k == "o" or k == "O" then
        openLine(k == "o")
        mode = "insert"
        insertMode("insert", cnt, function(t)
            openLine(true); aiLine = nil
            insertText(t)
        end)
    elseif k == "R" then
        insertMode("replace")
    elseif k == "x" or k == "s" then
        if #s > 0 then
            local x2 = math.min(cx + cnt - 1, #s)
            setReg(reg, s:sub(cx, x2), false)
            setLine(cy, s:sub(1, cx - 1) .. s:sub(x2 + 1))
        elseif k == "x" then return beep() end
        if k == "s" then mode = "insert"; return insertMode() end
        clampCursor()
    elseif k == "X" then
        if cx <= 1 then return beep() end
        local x1 = math.max(1, cx - cnt)
        setReg(reg, s:sub(x1, cx - 1), false)
        setLine(cy, s:sub(1, x1 - 1) .. s:sub(cx))
        cx = x1
    elseif k == "S" then
        apply("c", reg, cy, 1, math.min(cy + cnt - 1, #lines), 0, "line")
    elseif k == "C" or k == "D" then
        local y2 = math.min(cy + cnt - 1, #lines)
        apply(k == "C" and "c" or "d", reg, cy, cx, y2, #lines[y2], "incl")
        if k == "D" then clampCursor(); want = math.huge end
    elseif k == "Y" then
        apply("y", reg, cy, 1, math.min(cy + cnt - 1, #lines), 0, "line")
    elseif k == "d" or k == "c" or k == "y" or k == ">" or k == "<" then
        operate(k, n, reg)
    elseif k == "p" or k == "P" then
        put(reg, k == "p", cnt)
    elseif k == "r" then
        local c = getKey()
        if c == "<CR>" then
            if #s == 0 then return beep() end
            setLine(cy, s:sub(1, cx - 1))
            insertLines(cy + 1, { s:sub(cx + 1) })
            cy, cx = cy + 1, 1
        elseif #c == 1 then
            if cx + cnt - 1 > #s then return beep() end
            setLine(cy, s:sub(1, cx - 1) .. string.rep(c, cnt) .. s:sub(cx + cnt))
            cx = cx + cnt - 1
        end
    elseif k == "J" then
        join(cy, math.max(2, cnt), true)
    elseif k == "~" then
        if #s == 0 then return beep() end
        local x2 = math.min(cx + cnt - 1, #s)
        local part = text.swapCase(s:sub(cx, x2))
        setLine(cy, s:sub(1, cx - 1) .. part .. s:sub(x2 + 1))
        cx = math.min(x2 + 1, #s)
        setWant()
    elseif k == "u" or k == "U" then
        undo(cnt)
    elseif k == "<C-r>" then
        redo(cnt)
    elseif k == "." then
        repeatChange(n)
    elseif k == ":" then
        local cmd = readCmdline(":", n and (n == 1 and "." or ".,.+" .. (n - 1)) or "", exHist)
        if cmd then ex(cmd) end
    elseif k == "&" then
        exRun("s")
    elseif k == "Z" then
        local k2 = getKey()
        if k2 == "Z" then ex("x") elseif k2 == "Q" then ex("q!") else beep() end
    elseif k == "m" then
        local c = getKey()
        if isAlpha(c) then marks[c] = { cy, cx } else beep() end
    elseif k == "z" then
        local k2 = getKey()
        local v = viewHeight()
        if k2 == "t" or k2 == "<CR>" then top = cy
        elseif k2 == "z" or k2 == "." then top = math.max(1, cy - math.floor(v / 2))
        elseif k2 == "b" or k2 == "-" then top = math.max(1, cy - v + 1)
        else return beep() end
        if k2 == "<CR>" or k2 == "." or k2 == "-" then cx = firstNonBlank(cy) end
    elseif k == "g" then
        local k2 = getKey()
        if k2 == "J" then withChange(join, cy, math.max(2, cnt), false)
        elseif k2 == "g" then move("gg", n)
        else beep() end
    elseif k == "<C-f>" or k == "<PageDown>" or k == "<C-b>" or k == "<PageUp>" then
        local v = viewHeight()
        local down = k == "<C-f>" or k == "<PageDown>"
        for _ = 1, cnt do
            if down then top = math.min(#lines, top + math.max(1, v - 2))
            else top = math.max(1, top - math.max(1, v - 2)) end
        end
        cy = down and top or math.min(#lines, top + v - 1)
        cx = firstNonBlank(cy)
    elseif k == "<C-d>" or k == "<C-u>" then
        local half = n or math.max(1, math.floor(viewHeight() / 2))
        local d = k == "<C-d>" and half or -half
        if (d > 0 and cy >= #lines) or (d < 0 and cy <= 1) then return beep() end
        top = clamp(top + d, 1, math.max(1, #lines - viewHeight() + 1))
        cy = clamp(cy + d, 1, #lines)
        cx = firstNonBlank(cy)
    elseif k == "<C-e>" then
        scrollBy(cnt)
    elseif k == "<C-y>" then
        scrollBy(-cnt)
    elseif k == "<C-g>" then
        fileInfo()
    elseif k == "<C-a>" then
        increment(cnt)
    elseif k == "<C-x>" then
        increment(-cnt)
    elseif k == "<Paste>" then
        withChange(insertText, pasted or "")
        clampCursor()
    elseif k == "<C-c>" then
        -- Ctrl+C is Esc; in normal mode it also says how to get out
        if modified() then say(":wq saves and exits, :q! exits unsaved")
        else say("Type :q and Enter to exit") end
    elseif k == "<Esc>" or k == "<C-l>" then
        return
    else
        move(k, n)
    end
end

function normalCommand()
    rec, showcmd, bad = {}, "", false
    local k = getKey()
    msg = nil
    local reg
    if k == '"' then
        reg = getKey()
        if not (isWordChar(reg) or reg == '"') then return beep() end
        k = getKey()
    end
    local n
    n, k = readCount(k)
    local from = #rec
    local isChange = CHANGE[k]
    if isChange then beginChange() end
    local ok, e = pcall(doCommand, k, n, reg)
    mode = "normal"
    cmdline = nil
    if isChange then
        endChange()
        local keysOf = {}
        for i = from, #rec do keysOf[#keysOf + 1] = rec[i] end
        lastChange = { n = n, reg = reg, keys = keysOf }
    end
    clampCursor()
    showcmd = ""
    if not ok then say(tostring(e), true) end
end

--------------------------------------------------------------------------
-- The command line (: / ?)
--------------------------------------------------------------------------

function readCmdline(prefix, init, hist)
    cmdline = { prefix = prefix, text = init or "", pos = #(init or "") }
    local hi = #hist + 1
    while true do
        local k = getKey()
        local c = cmdline
        local t, p = c.text, c.pos
        if k == "<CR>" then break
        elseif k == "<Esc>" or k == "<C-c>" then cmdline = nil; return nil
        elseif k == "<BS>" or k == "<C-h>" then
            if t == "" then cmdline = nil; return nil end
            if p > 0 then c.text, c.pos = t:sub(1, p - 1) .. t:sub(p + 1), p - 1 end
        elseif k == "<Del>" then c.text = t:sub(1, p) .. t:sub(p + 2)
        elseif k == "<Left>" then c.pos = math.max(0, p - 1)
        elseif k == "<Right>" then c.pos = math.min(#t, p + 1)
        elseif k == "<Home>" or k == "<C-b>" then c.pos = 0
        elseif k == "<End>" or k == "<C-e>" then c.pos = #t
        elseif k == "<Up>" or k == "<Down>" then
            hi = clamp(hi + (k == "<Up>" and -1 or 1), 1, #hist + 1)
            c.text = hist[hi] or ""
            c.pos = #c.text
        elseif k == "<C-u>" then c.text, c.pos = t:sub(p + 1), 0
        elseif k == "<C-w>" then
            local a = p
            while a > 0 and isSpace(t:sub(a, a)) do a = a - 1 end
            while a > 0 and not isSpace(t:sub(a, a)) do a = a - 1 end
            c.text, c.pos = t:sub(1, a) .. t:sub(p + 1), a
        elseif k == "<Tab>" then
            -- the word before the cursor: back to a blank
            local a = p
            while a > 0 and not isSpace(t:sub(a, a)) do a = a - 1 end
            local word = t:sub(a + 1, p)
            local got = fs.complete and fs.complete(word, shell and shell.dir() or "", true, true) or {}
            if got[1] then c.text, c.pos = t:sub(1, p) .. got[1] .. t:sub(p + 1), p + #got[1] end
        elseif k == "<C-r>" then
            local r = regs[getKey()]
            local add = r and (text.cut(r.text, "\n")) or ""
            c.text, c.pos = t:sub(1, p) .. add .. t:sub(p + 1), p + #add
        elseif k == "<Paste>" then
            local add = (text.cut(pasted or "", "\n"))
            c.text, c.pos = t:sub(1, p) .. add .. t:sub(p + 1), p + #add
        elseif #k == 1 then
            c.text, c.pos = t:sub(1, p) .. k .. t:sub(p + 1), p + 1
        end
    end
    local typed = cmdline.text
    cmdline = nil
    if typed ~= "" and hist[#hist] ~= typed then hist[#hist + 1] = typed end
    return typed
end

--------------------------------------------------------------------------
-- Files
--------------------------------------------------------------------------

function resolve(p)
    if shell and shell.resolve then return shell.resolve(p) end
    return p
end

function loadFile(arg)
    lines, cy, cx, want, top, leftcol = { "" }, 1, 1, 0, 1, 0
    undoStack, redoStack, marks = {}, {}, {}
    synValid, synStates, synFg = 1, {}, {}
    ver = nextVer()
    savedVer = ver
    crlf, langSet, detected, noLines = false, nil, nil, true
    opt.readonly = false
    name, path = arg, arg and resolve(arg) or nil
    if not path then return end
    if fs.exists(path) and fs.isDir(path) then
        say('"' .. arg .. '" is a directory', true)
    elseif fs.exists(path) then
        local body = fileio.read(path)
        if not body then
            say('"' .. arg .. '" [Permission Denied]', true)
        else
            -- every line ended by CR LF: written back so
            if text.contains(body, "\r\n") and not text.contains((text.replace(body, "\r\n", "")), "\n") then
                crlf = true
                body = text.replace(body, "\r\n", "\n")
            end
            lines = text.lines(body, true)      -- (a CR left before a LF stays: not every line had one)
            if body == "" then lines = { "" } else noLines = false end
            opt.readonly = fs.isReadOnly(path)
            say('"' .. arg .. '"' .. (opt.readonly and " [readonly]" or "") .. " " .. #lines .. "L, " .. #body .. "B")
        end
    else
        opt.readonly = fs.isReadOnly(path)
        say('"' .. arg .. '" [New]')
    end
    detected = syntax.detect(path, lines[1])
end

function writeFile(target, bang, a1, a2, whole)
    local p = target ~= "" and resolve(target) or path
    if not p then fail("E32: No file name") end
    if p == path and opt.readonly and not bang then fail("E45: 'readonly' option is set (add ! to override)") end
    if p ~= path and fs.exists(p) and not bang then fail("E13: File exists (add ! to override)") end
    if fs.exists(p) and fs.isDir(p) then fail('E502: "' .. (target ~= "" and target or name) .. '" is a directory') end
    local nl, out = crlf and "\r\n" or "\n", {}
    local empty = whole and noLines
    if not empty then
        for y = a1, a2 do out[#out + 1] = lines[y] .. nl end
    end
    local body = table.concat(out)
    if not fileio.write(p, body) then fail("E212: Can't open file for writing") end
    local bytes = #body
    local shown = target ~= "" and target or name
    if whole and (p == path or not path) then
        if not path then
            name, path = target, p
            detected = syntax.detect(path, lines[1])
        end
        savedVer = ver
    end
    say('"' .. shown .. '" ' .. (empty and 0 or a2 - a1 + 1) .. "L, " .. bytes .. "B written")
end

function modified() return ver ~= savedVer end

function editFile(arg, bang)
    if modified() and not bang then fail("E37: No write since last change (add ! to override)") end
    if arg == "" then
        if not name then fail("E32: No file name") end
        arg = name
    end
    loadFile(arg)
end

--------------------------------------------------------------------------
-- Ex commands
--------------------------------------------------------------------------

-- A line address at the scanner sc: the line (nil if there's none).  sc
-- is left after it.  An address is a base and then any offsets:
--   base:    .  this line       $  the last      a number
--            'x  mark x ('' where the last jump was from)
--            /pat/  ?pat?  the next line that matches, forward or back
--                          (the closing delimiter may be left off)
--   offset:  + or -, then a number (1 if there's none)
-- Offsets with no base count from this line.
function address(sc)
    local y
    local c = sc:peek()
    if sc:accept(".") then
        y = cy
    elseif sc:accept("$") then
        y = #lines
    elseif isDigit(c) then
        y = sc:readNumber()
    elseif sc:accept("'") then
        local m = sc:advance()
        local mk = m == "'" and marks["'"] or marks[m]
        if not mk then fail("E20: Mark not set") end
        y = mk[1]
    elseif c == "/" or c == "?" then
        sc:advance()
        local pat = sc:readUntil(c)
        if pat == "" then
            if not lastSearch then fail("E35: No previous regular expression") end
            pat = lastSearch.pat
        end
        lastSearch, hlHidden = { pat = pat, dir = c == "/" and 1 or -1 }, false
        y = search(pat, lastSearch.dir, cy, c == "/" and #lines[cy] or 1, 1)
        msg = nil
    end
    while sc:peek() == "+" or sc:peek() == "-" do
        local sign = sc:advance()
        local num = sc:readNumber() or 1
        y = (y or cy) + (sign == "+" and num or -num)
    end
    return y
end

-- what \n \r and \t stand for in :s's replacement (\r makes a new line too)
REP_ESCAPES = { n = "\n", r = "\n", t = "\t" }

function expandRep(rep, whole, caps)
    local out, i = {}, 1
    while i <= #rep do
        local c = rep:sub(i, i)
        if c == "\\" then
            local d = rep:sub(i + 1, i + 1)
            if isDigit(d) then out[#out + 1] = d == "0" and whole or (caps[tonumber(d)] or "")
            else out[#out + 1] = REP_ESCAPES[d] or d end
            i = i + 2
        elseif c == "&" then
            out[#out + 1] = whole
            i = i + 1
        else
            out[#out + 1] = c
            i = i + 1
        end
    end
    return table.concat(out)
end

-- What can be the delimiter of :s and :g: one character, not a letter,
-- digit or blank, and not " or | (and for :s not &: that's :s&, below).
function isPatternDelimiter(c)
    return c ~= "" and not isAlnum(c) and not isSpace(c) and c ~= '"' and c ~= "|"
end

-- :s/pat/rep/flags (any delimiter for the /; \/ is one in the text), or
-- :s [flags] and :& [&][flags] to do the last one again: a "&" first keeps
-- its flags.
function substitute(a1, a2, arg)
    local pat, rep, flags
    local d = arg:sub(1, 1)
    if d == "&" or not isPatternDelimiter(d) then
        if not lastSub then fail("E35: No previous regular expression") end
        pat, rep = lastSub.pat, lastSub.rep
        if d == "&" then flags = lastSub.flags .. arg:sub(2) else flags = arg end
    else
        local sc = scan.new(arg, 2)
        local closed
        pat, closed = sc:readUntil(d)
        if closed then
            rep, closed = sc:readUntil(d)
            flags = closed and sc:readRest() or ""
        else
            rep, flags = "", ""
        end
        if pat == "" then
            if not lastSearch then fail("E35: No previous regular expression") end
            pat = lastSearch.pat
        end
        lastSub = { pat = pat, rep = rep, flags = flags }
    end
    local g = text.contains(flags, "g")
    local saveIc = opt.ignorecase
    if text.contains(flags, "i") then opt.ignorecase = true
    elseif text.contains(flags, "I") then opt.ignorecase = false end
    local ok, re = pcall(compile, pat)
    opt.ignorecase = saveIc
    if not ok then error(re, 0) end
    lastSearch, hlHidden = { pat = pat, dir = lastSearch and lastSearch.dir or 1 }, false
    local subs, nl, lastY = 0, 0, nil
    local y = a1
    while y <= a2 do
        local s = lines[y]
        local out, init, did = {}, 1, false
        while init <= #s + 1 do
            local a, b, caps = re:find(s, init)
            if not a then break end
            out[#out + 1] = s:sub(init, a - 1)
            out[#out + 1] = expandRep(rep, s:sub(a, b), caps)
            subs, did = subs + 1, true
            if b < a then
                out[#out + 1] = s:sub(a, a)
                init = a + 1
            else
                init = b + 1
            end
            if not g then break end
        end
        if did then
            out[#out + 1] = s:sub(init)
            local new = table.concat(out)
            nl, lastY = nl + 1, y
            if text.contains(new, "\n") then
                local parts = text.split(new, "\n", true)
                if text.endsWith(new, "\n") then parts[#parts + 1] = "" end
                setLine(y, parts[1])
                local rest = {}
                for i = 2, #parts do rest[#rest + 1] = parts[i] end
                insertLines(y + 1, rest)
                y, a2 = y + #rest, a2 + #rest
                lastY = y
            else
                setLine(y, new)
            end
        end
        y = y + 1
    end
    if subs == 0 then fail("E486: Pattern not found: " .. pat) end
    cy = lastY
    cx = firstNonBlank(cy)
    if nl > 1 then say(subs .. " substitution" .. (subs == 1 and "" or "s") .. " on " .. nl .. " lines") end
end

-- :g/pat/cmd (any delimiter, as for :s): cmd, p if none, on each line that
-- matches (invert: that doesn't).
function global(a1, a2, arg, invert)
    local d = arg:sub(1, 1)
    if not isPatternDelimiter(d) then fail("E476: Invalid command") end
    local sc = scan.new(arg, 2)
    local pat, closed = sc:readUntil(d)
    local cmd = closed and sc:readRest() or ""
    if scan.isBlank(cmd) then cmd = "p" end
    if pat == "" then
        if not lastSearch then fail("E35: No previous regular expression") end
        pat = lastSearch.pat
    end
    lastSearch, hlHidden = { pat = pat, dir = 1 }, false
    local re = compile(pat)
    local marked = {}
    for y = a1, a2 do
        if (re:find(lines[y]) ~= nil) ~= invert then marked[#marked + 1] = y end
    end
    if #marked == 0 then fail("E486: Pattern not found: " .. pat) end
    local shift = 0
    for _, y0 in ipairs(marked) do
        local y = y0 + shift
        if y >= 1 and y <= #lines then
            cy, cx = y, 1
            local before = #lines
            exRun(cmd)
            shift = shift + (#lines - before)
        end
    end
    clampCursor()
end

function setOption(word)
    if word == "" then
        local t = {}
        for full, o in pairs(OPTIONS) do
            local v = opt[full]
            if v ~= DEFAULTS[full] and (vimMode or not VIM_ONLY[full]) then
                t[#t + 1] = o[2] == "bool" and ((v and "" or "no") .. full) or (full .. "=" .. tostring(v))
            end
        end
        table.sort(t)
        say(table.concat(t, " "))
        return
    end
    -- word: name, name=value, name:value, name? (show it) or name! (flip
    -- it); a name is letters and digits.  Anything else is a name too, to
    -- be refused below.
    local key, val, query, bang
    local sc = scan.new(word)
    local name = sc:readWhile(isAlnum)
    if name ~= "" then
        local after = sc:rest()
        if sc:accept("=") or sc:accept(":") then key, val = name, sc:readRest()
        elseif after == "?" then query = name
        elseif after == "!" then bang = name end
    end
    key = key or query or bang or word
    local no = false
    local function lookup(k)
        for full, o in pairs(OPTIONS) do
            if (k == full or k == o[1]) and (vimMode or not VIM_ONLY[full]) then return full, o[2] end
        end
    end
    local full, kind = lookup(key)
    local noKey, invKey = text.stripPrefix(key, "no"), text.stripPrefix(key, "inv")
    if not full and noKey then full, kind = lookup(noKey); no = true end
    local inv = false
    if not full and invKey then full, kind = lookup(invKey); inv = true end
    if not full then fail("E518: Unknown option: " .. word) end
    if query or (kind ~= "bool" and not val and not no) then
        local v = opt[full]
        if full == "filetype" or full == "syntax" then v = currentLang() or "" end
        say(kind == "bool" and ((v and "  " or "no") .. full) or ("  " .. full .. "=" .. tostring(v)))
        return
    end
    if kind == "bool" then
        if val then fail("E474: Invalid argument: " .. word) end
        if bang or inv then opt[full] = not opt[full] else opt[full] = not no end
    elseif kind == "num" then
        local v = tonumber(val)
        if not v or v < 1 or v ~= math.floor(v) then fail("E487: Argument must be positive: " .. word) end
        opt[full] = v
    else
        local lang = LANG_VALUES[val]
        if lang == nil then fail("E474: Invalid argument: " .. word) end
        if lang == "detect" then langSet = nil else langSet = lang end
    end
end

function is(name, full, min) return #name >= min and text.startsWith(full, name) end

isExSymbol = scan.oneOf("!&<>=#")
isOneLetterName = scan.oneOf("sgv")
isSpaceOrColon = function(c) return isSpace(c) or c == ":" end
isShiftChar = scan.oneOf("<>")

-- The name at the start of an ex command (after its range) and the text
-- after it.  A name is a run of letters, or one of ! & < > = #.  s, g or v
-- with a delimiter straight after is the whole name: :s/a/b/, :g!x!d.
function commandName(rest)
    local first, second = rest:sub(1, 1), rest:sub(2, 2)
    if isOneLetterName(first) and second ~= "" and not isAlnum(second) and not isSpace(second) then
        return first, rest:sub(2)
    end
    local sc = scan.new(rest)
    local name = sc:readWhile(isAlpha)
    if name == "" and isExSymbol(sc:peek()) then name = sc:advance() end
    return name, sc:rest()
end

-- The number at the end of s (blanks may follow it), or nil.
function trailingNumber(s)
    local stop = #s
    while stop >= 1 and isSpace(s:sub(stop, stop)) do stop = stop - 1 end
    local start = stop
    while start >= 1 and isDigit(s:sub(start, start)) do start = start - 1 end
    if start == stop then return nil end
    return tonumber(s:sub(start + 1, stop))
end

-- :kx, the mark command with its letter run on
function isMarkK(name) return #name == 2 and text.startsWith(name, "k") and isAlpha(name:sub(2)) end

function shellCommand(cmd)
    term.setCursorBlink(false)
    term.setBackgroundColour(colours.black)
    term.setTextColour(colours.white)
    term.clear()
    term.setCursorPos(1, 1)
    if shell and shell.run then shell.run(cmd) end
    write("\nPress ENTER to continue")
    while true do
        local k = nextToken()
        if k == "<CR>" or k == "<Esc>" or k == "<C-c>" or k == " " then break end
    end
    needRender = true
end

-- An ex command line:  [range] name[!] [argument]
--   range:  %  every line;  address  one line;  address,address  from one
--           to the other;  address;address  the same, but the cursor goes
--           to the first before the second is read.  An address left out
--           of a pair is this line.
-- Blanks and colons before it are skipped; " starts a comment.
function exRun(line)
    local sc = scan.new(line)
    sc:readWhile(isSpaceOrColon)
    if sc:atEnd() or sc:peek() == '"' then return end
    local a1, a2, ranged
    if sc:accept("%") then
        a1, a2, ranged = 1, #lines, true
    else
        local first = address(sc)
        local second
        local sep = sc:peek()
        if sep == "," or sep == ";" then
            if sep == ";" and first then cy = clamp(first, 1, #lines) end
            sc:advance()
            second = address(sc)
            second = second or cy
            first = first or cy
        end
        ranged = first ~= nil
        a1, a2 = first or cy, second or first or cy
    end
    if a1 > a2 then a1, a2 = a2, a1 end
    sc:skipSpaces()
    local rest = sc:rest()
    if rest == "" then
        if ranged then
            if a2 < 1 or a2 > #lines then a2 = clamp(a2, 1, #lines) end
            marks["'"] = { cy, cx }
            cy = a2
            cx = firstNonBlank(cy)
            setWant()
        end
        return
    end
    if ranged and (a1 < 1 or a2 > #lines) then fail("E16: Invalid range") end
    local name, after = commandName(rest)
    local bang = false
    local afterBang = text.stripPrefix(after, "!")
    if name ~= "!" and afterBang then bang, after = true, afterBang end
    local arg = text.trimStart(after)
    if name == "!" then
        shellCommand(after)
    elseif name == "wq" or name == "x" or is(name, "xit", 2) or name == "wqa" or name == "xa" or is(name, "exit", 3) then
        if text.startsWith(name, "w") or modified() then writeFile(arg, bang, 1, #lines, true) end
        quitting = true
    elseif is(name, "write", 1) then
        if ranged then writeFile(arg, bang, a1, a2, a1 == 1 and a2 == #lines)
        else writeFile(arg, bang, 1, #lines, true) end
    elseif is(name, "quit", 1) or is(name, "qall", 2) or is(name, "quitall", 5) then
        if modified() and not bang then fail("E37: No write since last change (add ! to override)") end
        quitting = true
    elseif is(name, "edit", 1) then
        editFile(arg, bang)
    elseif is(name, "next", 1) or is(name, "Next", 1) or is(name, "previous", 4) then
        local step = text.startsWith(name, "n") and 1 or -1
        local j = argIdx + step
        if j > #argList then fail("E165: Cannot go beyond last file") end
        if j < 1 then fail("E164: Cannot go before first file") end
        editFile(argList[j], bang)
        argIdx = j
    elseif is(name, "read", 1) then
        if arg == "" then fail("E32: No file name") end
        local body = fileio.read(resolve(arg))
        if not body then fail('E484: Can\'t open file ' .. arg) end
        -- its lines: CR LF ends one as LF does; a CR alone stays, as when
        -- a file is opened.  An empty file adds none, as in vim.
        local list = text.lines(text.replace(body, "\r\n", "\n"), true)
        if #list > 0 then
            insertLines(a2 + 1, list)
            cy = a2 + 1
            cx = firstNonBlank(cy)
        end
    elseif is(name, "set", 2) then
        if arg == "" then setOption("") end
        for _, word in ipairs(text.words(arg)) do setOption(word) end
    elseif is(name, "syntax", 2) and vimMode then
        if arg == "on" or arg == "enable" then opt.syntax = true
        elseif arg == "off" then opt.syntax = false
        elseif arg == "" then say("syntax " .. (opt.syntax and "on" or "off") .. (currentLang() and (", " .. currentLang()) or ""))
        else fail("E28: No such highlight group name: " .. arg) end
    elseif is(name, "nohlsearch", 3) then
        hlHidden = true
    elseif is(name, "substitute", 1) or name == "&" then
        substitute(a1, a2, arg)
    elseif is(name, "global", 1) or is(name, "vglobal", 1) then
        if not ranged then a1, a2 = 1, #lines end
        global(a1, a2, arg, text.startsWith(name, "v") or bang)
    elseif is(name, "delete", 1) or is(name, "yank", 1) then
        -- :d [x] [count]: a register (a letter, " or _), a count at the end
        local c = arg:sub(1, 1)
        local reg = (isAlpha(c) or c == '"' or c == "_") and c or nil
        local num = trailingNumber(arg)
        if num then a1 = a2; a2 = math.min(#lines, a1 + num - 1) end
        apply(text.startsWith(name, "d") and "d" or "y", reg, a1, 1, a2, 0, "line")
    elseif is(name, "put", 2) then
        cy = a2
        local c = arg:sub(1, 1)
        put((c ~= "" and not isSpace(c)) and c or nil, not bang, 1)
    elseif is(name, "join", 1) then
        join(a1, math.max(2, a2 - a1 + 1), not bang)
    elseif name == ">" or name == "<" then
        local times = 1 + #scan.new(after):readWhile(isShiftChar)
        shiftLines(a1, a2, name == ">" and 1 or -1, times)
    elseif is(name, "move", 1) or is(name, "copy", 2) or name == "t" then
        local dest = address(scan.new(arg))
        if not dest or dest < 0 or dest > #lines then fail("E14: Invalid address") end
        local chunk = {}
        for y = a1, a2 do chunk[#chunk + 1] = lines[y] end
        if text.startsWith(name, "m") then
            if dest >= a1 and dest < a2 then fail("E134: Cannot move a range of lines into itself") end
            if dest >= a2 then
                insertLines(dest + 1, chunk)
                removeLines(a1, a2)
                cy = dest
            else
                removeLines(a1, a2)
                insertLines(dest + 1, chunk)
                cy = dest + #chunk
            end
        else
            insertLines(dest + 1, chunk)
            cy = dest + #chunk
        end
        cx = firstNonBlank(cy)
    elseif name == "=" then
        say(tostring(ranged and a2 or #lines))
    elseif is(name, "print", 1) or name == "#" or is(name, "number", 2) then
        cy = a2
        say(((name == "#" or text.startsWith(name, "n")) and (a2 .. " ") or "") .. lines[a2])
    elseif isMarkK(name) or is(name, "mark", 2) then
        local m = isMarkK(name) and name:sub(2) or (isAlpha(arg:sub(1, 1)) and arg:sub(1, 1)) or nil
        if not m then fail("E471: Argument required") end
        marks[m] = { a2, 1 }
    elseif is(name, "undo", 1) then
        undo(1)
    elseif is(name, "redo", 3) then
        redo(1)
    elseif is(name, "file", 1) then
        fileInfo()
    elseif is(name, "help", 1) then
        say("For help, run `help " .. (vimMode and "vim" or "vi") .. "` at the shell")
    elseif is(name, "version", 2) then
        say((vimMode and "vim" or "vi") .. " (ccnix)")
    else
        fail("E492: Not an editor command: " .. rest)
    end
    clampCursor()
end

function ex(line)
    beginChange()
    local ok, e = pcall(exRun, line)
    endChange()
    if not ok then say(tostring(e), true) end
end

--------------------------------------------------------------------------
-- Starting and stopping
--------------------------------------------------------------------------

DEFAULTS = {
    number = false, tabstop = 4, shiftwidth = 4, expandtab = true, autoindent = true,
    ignorecase = false, smartcase = false, wrapscan = true, readonly = false, hlsearch = false,
    syntax = true, filetype = true,
}

-- What to do when the editor itself breaks: keep the text if it was changed.
function rescue(err)
    term.setBackgroundColour(colours.black)
    term.setTextColour(colours.white)
    term.clear()
    term.setCursorPos(1, 1)
    if lines and modified and modified() then
        if fileio.write("/.vi-recover", table.concat(lines, "\n") .. "\n") then
            print("vi: the text so far is in /.vi-recover")
        end
    end
    error(err, 0)
end

function V.main(args, o)
    vimMode = o and o.vim or false
    opt = tables.copy(DEFAULTS)
    regs, queue, rec, exHist, searchHist = {}, {}, {}, {}, {}
    verCounter, changeDepth, mode, msg, msgErr, showcmd = 0, 0, "normal", nil, false, ""
    lastSearch, lastSub, lastFind, lastChange, hlHidden = nil, nil, nil, nil, false
    ctrlDown, altDown, swallow, quitting, needRender = false, false, nil, false, true
    synLang, gutter, cmdline, aiLine, jumpFrom, repeating, pasted = nil, 0, nil, nil, nil, false, nil
    KEYTOK = keyTokens()
    -- under init, Ctrl+C is a key here (Esc's stand-in), not an interrupt,
    -- and the wheel scrolls the file, not the console's scrollback
    local kernel = rawget(_G, "proc")
    if type(kernel) == "table" and kernel.ignore then kernel.ignore("INT") end
    if type(kernel) == "table" and kernel.ownScrollback then kernel.ownScrollback(true) end

    local files, startCmd, ro = {}, nil, false
    for _, a in ipairs(args or {}) do
        local cmd = text.stripPrefix(a, "+")
        if cmd then startCmd = cmd == "" and "$" or cmd
        elseif a == "-R" then ro = true
        else files[#files + 1] = a end
    end
    argList, argIdx = files, 1
    loadFile(files[1])
    local opening = msg
    local rc = vimMode and (fs.exists("/.vimrc") and "/.vimrc" or "/.exrc") or "/.exrc"
    local commands = fileio.read(rc)
    if commands then
        -- one per line (ended by LF, CR LF or CR), blank ones skipped
        for _, l in ipairs(text.split(text.replace(commands, "\r", "\n"), "\n")) do
            local ok, e = pcall(exRun, l)
            if not ok then opening = rc .. ": " .. tostring(e) end
        end
    end
    msg = opening
    if ro then opt.readonly = true end
    if startCmd then ex(startCmd) end
    term.setBackgroundColour(colours.black)
    term.setTextColour(colours.white)
    term.clear()
    local fails = 0
    while not quitting do
        local ok, e = pcall(normalCommand)
        if ok then fails = 0
        else
            fails = fails + 1
            if fails > 3 then rescue(e) end
            say("vi: " .. tostring(e), true)
        end
    end
    term.setCursorBlink(false)
    term.setBackgroundColour(colours.black)
    term.setTextColour(colours.white)
    term.clear()
    term.setCursorPos(1, 1)
end

return V
