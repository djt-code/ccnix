-- sim/telnet.lua
--
-- lib/telnet.lua: the Telnet parser (data, IAC IAC, options, NAWS, IP,
-- a command split across reads); the server's renderer (a whole screen
-- first, then only what changed, the cursor); the client's terminal fed
-- that output, ending up showing the same text and colours (Latin-1 and
-- the block graphics too, an inverted one with its colours swapped);
-- 16-colour and true-colour SGR from other servers; the server's decoder
-- (characters with their keys, Enter from CR, LF or CR LF once, arrows
-- and the other keys, Ctrl+letter, Ctrl+T, bracketed paste, SGR mouse);
-- the client's keys and mouse decoded back to what was pressed.
local PROJ = ...
package.path = PROJ .. "/lib/?.lua;" .. PROJ .. "/sim/lib/?.lua;" .. package.path
local M = require("mock")
local check = M.check
local T = require("telnet")
local function show(s)
    return (tostring(s):gsub("\27", "^["):gsub("\r", "\\r"):gsub("\n", "\\n")
        :gsub("[%z\1-\31\128-\255]", function(c) return "\\" .. c:byte() end))
end

-- a CC window, enough of one: text and blit colours per row
local LOG2 = {}
for i = 0, 15 do LOG2[2 ^ i] = i end
local function window(w, h)
    local win, rows, fgs, bgs = {}, {}, {}, {}
    local x, y, fg, bg, blink = 1, 1, "0", "f", false
    local function blank(r) rows[r], fgs[r], bgs[r] = (" "):rep(w), ("0"):rep(w), ("f"):rep(w) end
    for r = 1, h do blank(r) end
    function win.getSize() return w, h end
    function win.getLine(r) return rows[r], fgs[r], bgs[r] end
    function win.setCursorPos(nx, ny) x, y = nx, ny end
    function win.getCursorPos() return x, y end
    function win.setCursorBlink(b) blink = b end
    function win.getCursorBlink() return blink end
    function win.setTextColour(c) fg = string.format("%x", LOG2[c]) end
    function win.setBackgroundColour(c) bg = string.format("%x", LOG2[c]) end
    function win.write(s)
        if y < 1 or y > h then x = x + #s; return end
        for i = 1, #s do
            if x >= 1 and x <= w then
                rows[y] = rows[y]:sub(1, x - 1) .. s:sub(i, i) .. rows[y]:sub(x + 1)
                fgs[y] = fgs[y]:sub(1, x - 1) .. fg .. fgs[y]:sub(x + 1)
                bgs[y] = bgs[y]:sub(1, x - 1) .. bg .. bgs[y]:sub(x + 1)
            end
            x = x + 1
        end
    end
    function win.blit(s, f, b)
        for i = 1, #s do
            fg, bg = f:sub(i, i), b:sub(i, i)
            win.write(s:sub(i, i))
        end
    end
    function win.clear() for r = 1, h do blank(r) end end
    function win.scroll(n)
        for _ = 1, n do
            table.remove(rows, 1); table.remove(fgs, 1); table.remove(bgs, 1)
            blank(h)
        end
    end
    return win
end

-- 1. the parser
local got = {}
local feed = T.parser({
    data = function(d) got[#got + 1] = "D:" .. d end,
    option = function(c, o) got[#got + 1] = "O:" .. c .. "," .. o end,
    sub = function(o, p) got[#got + 1] = "S:" .. o .. ":" .. p:byte(1) .. "," .. p:byte(2) .. "," .. p:byte(3) .. "," .. p:byte(4) end,
    command = function(c) got[#got + 1] = "C:" .. c end,
})
feed("ab\255\255c" .. T.cmd(T.DO, T.NAWS) .. "x" .. T.naws(80, 24) .. "\255")
feed("\244yz")
check("parser: data (IAC IAC is a 255), options, NAWS, IP split across reads",
    table.concat(got, " ") == "D:ab\255c O:253,31 D:x S:31:0,80,0,24 C:244 D:yz", show(table.concat(got, " ")))
got = {}
feed(T.sub(T.NAWS, string.char(0, 255, 0, 10)))
check("a 255 inside a subnegotiation, escaped and back", got[1] == "S:31:0,255,0,10", show(got[1]))

-- 2. the server renders a window; the client's terminal shows it
local src = window(12, 3)
src.setTextColour(2 ^ 14); src.setBackgroundColour(2 ^ 11)       -- red on blue
src.setCursorPos(1, 1); src.write("Hi \233t\233")                   -- (Latin-1: e acute)
src.setTextColour(2 ^ 0); src.setBackgroundColour(2 ^ 15)
src.setCursorPos(2, 2); src.write("x" .. string.char(128 + 5) .. string.char(128 + 31))   -- block graphics
src.setCursorPos(1, 3)
for c = 0, 11 do src.setTextColour(2 ^ c); src.setBackgroundColour(2 ^ (15 - c)); src.write("#") end
src.setCursorPos(5, 2); src.setCursorBlink(true)
local last = {}
local out = T.render(src, last)
check("render: the whole screen first (cleared), xterm 256 colours, UTF-8, the cursor",
    out:find("^\27%[0m\27%[2J") and out:find("\27[1;1H\27[38;5;167;48;5;62mHi \195\169t\195\169", 1, true)
        and out:find("\27[?25h\27[2;5H", 1, true), show(out:sub(1, 120)))
check("nothing changed: nothing to send", T.render(src, last) == "")
src.setCursorPos(1, 2); src.write("y")
local again = T.render(src, last)
check("one row changed: only it", again:find("\27[2;1H", 1, true) and not again:find("\27[1;1H", 1, true)
    and not again:find("\27[3;1H", 1, true), show(again))

local dst = window(12, 3)
local term = T.terminal(dst, true)
term.feed(out)
term.feed(again)
local same = true
for r = 1, 3 do
    local a, af, ab = src.getLine(r)
    local b, bf, bb = dst.getLine(r)
    if a ~= b or af ~= bf or ab ~= bb then same = false; print("   row " .. r .. " " .. show(a) .. " " .. af .. " " .. ab .. " | " .. show(b) .. " " .. bf .. " " .. bb) end
end
check("the client's terminal ends up showing the same text and colours", same)
check("and the cursor where the server's is", select(1, dst.getCursorPos()) == 2 and select(2, dst.getCursorPos()) == 2
    and dst.getCursorBlink())

-- an inverted block (bit 5 set) comes back as its complement, colours swapped
local inv = window(3, 1)
local ti = T.terminal(inv, true)
ti.feed("\27[38;5;255;48;5;233m" .. T.toUTF8(" ") .. "\240\159\172\187")   -- U+1FB3B: all but the top left
local text, fg, bg = inv.getLine(1)
check("a sextant CC can't draw as is: its complement, colours swapped",
    text:byte(2) == 128 + 1 and fg:sub(2, 2) == "f" and bg:sub(2, 2) == "0", show(text) .. " " .. fg .. " " .. bg)

-- what other servers send: 16 colours, bright, true colour, clear to end of line
local o = window(10, 2)
local to = T.terminal(o, true)
to.feed("\27[31mR\27[92mG\27[1;34mB\27[0m\27[38;2;240;240;240mW\r\n\27[44m  \27[K")
local t1, f1 = o.getLine(1)
local _, _, b2 = o.getLine(2)
check("16-colour and true-colour SGR, CR LF, erase to end of line",
    t1:sub(1, 4) == "RGBW" and f1:sub(1, 4) == "e5b0" and b2 == ("b"):rep(10), f1 .. " " .. b2)
local g = window(4, 1)
local tg = T.terminal(g, false)
tg.feed("\27[38;5;167mr")
check("a screen without colour: greys", select(2, g.getLine(1)):sub(1, 1) == "7", select(2, g.getLine(1)))

-- 3. the server decodes what a terminal sends
local fakeKeys = { a = 30, b = 48, enter = 28, up = 200, delete = 211, backspace = 14, tab = 15, leftCtrl = 29,
    space = 57, one = 2, pageDown = 209, home = 199 }
fakeKeys.getName = function(code) for k, v in pairs(fakeKeys) do if v == code then return k end end end
local evs = {}
local decode = T.decoder(function(...)
    local t = table.pack(...)
    for i = 1, t.n do t[i] = tostring(t[i]) end
    evs[#evs + 1] = table.concat(t, ",", 1, t.n)
end, fakeKeys)
local function decoded(s) evs = {}; decode(s); return table.concat(evs, " ") end
check("characters with their keys (Shift isn't sent: the char says it)",
    decoded("aB1") == "key,30,false char,a key_up,30 key,48,false char,B key_up,48 key,2,false char,1 key_up,2",
    decoded("aB1"))
check("Enter: CR, LF, or CR LF once; CR NUL too",
    decoded("\r\n\n\r\0") == "key,28,false key_up,28 key,28,false key_up,28 key,28,false key_up,28", decoded("\r\n\n\r\0"))
check("arrows, Delete, Page Down, Home (both forms), Backspace, Tab",
    decoded("\27[A\27[3~\27[6~\27OH\27[1~\127\t")
        == "key,200,false key_up,200 key,211,false key_up,211 key,209,false key_up,209 key,199,false key_up,199 "
        .. "key,199,false key_up,199 key,14,false key_up,14 key,15,false key_up,15", decoded("\27[A\27[3~\27[6~\27OH\27[1~\127\t"))
check("Ctrl+A: Ctrl down, a, Ctrl up; Ctrl+T on its own", decoded("\1\20")
    == "key,29,false key,30,false key_up,30 key_up,29 ctrl-t", decoded("\1\20"))
evs = {}
decode("\27[200~two\r")
decode("lines\27[201~")
check("bracketed paste, across reads: one paste event", table.concat(evs, " ") == "paste,two\rlines", show(table.concat(evs, " ")))
check("SGR mouse: left click and release, right click, drag, wheel",
    decoded("\27[<0;5;3M\27[<0;5;3m\27[<2;1;1M\27[<32;6;3M\27[<65;2;2M")
        == "mouse_click,1,5,3 mouse_up,1,5,3 mouse_click,2,1,1 mouse_drag,1,6,3 mouse_scroll,1,2,2",
    decoded("\27[<0;5;3M\27[<0;5;3m\27[<2;1;1M\27[<32;6;3M\27[<65;2;2M"))

-- 4. the client's keys and mouse, decoded back
check("keyBytes: Up, Enter, Ctrl+B; a letter is left to its char event",
    T.keyBytes(200, false, fakeKeys) == "\27[A" and T.keyBytes(28, false, fakeKeys) == "\r"
        and T.keyBytes(48, true, fakeKeys) == "\2" and T.keyBytes(30, false, fakeKeys) == nil)
check("mouseBytes round trip: a right click at 7,4 and a wheel up",
    decoded(T.mouseBytes("mouse_click", 2, 7, 4) .. T.mouseBytes("mouse_scroll", -1, 3, 3))
        == "mouse_click,2,7,4 mouse_scroll,-1,3,3")

-- the scrollback: rows a line feed at the bottom (or CSI S) pushes off the
-- top, oldest first, with their colours; a redraw in place adds nothing;
-- only the last T.HISTORY kept
local sb = window(6, 2)
local tsb = T.terminal(sb, true)
tsb.feed("one\r\ntwo\r\n\27[31mthree\27[0m\r\nfour")
check("scrollback: the rows scrolled off the top, oldest first, colours and all",
    #tsb.history == 2 and tsb.history[1][1] == "one   " and tsb.history[2][1] == "two   "
        and sb.getLine(1) == "three " and sb.getLine(2) == "four  ", #tsb.history .. " " .. show(sb.getLine(1)))
tsb.feed("\27[H\27[2Jredraw\27[2;1Hin pl")
check("a redraw in place (towel's way) adds nothing to it", #tsb.history == 2, #tsb.history)
tsb.feed("\27[1S")
check("CSI S scrolls a row into it too", #tsb.history == 3 and tsb.history[3][1] == "redraw", show(tsb.history[3] and tsb.history[3][1]))
local was = T.HISTORY
T.HISTORY = 3
local sm = window(4, 1)
local tsm = T.terminal(sm, true)
tsm.feed("a\r\nb\r\nc\r\nd\r\ne")
T.HISTORY = was
check("only the last T.HISTORY rows are kept", #tsm.history == 3 and tsm.history[1][1] == "b   " and tsm.history[3][1] == "d   ",
    #tsm.history .. " " .. tostring(tsm.history[1] and tsm.history[1][1]))
