-- sim/screen.lua
--
-- lib/screen, what bin/screen runs on, with a fake init (terminals,
-- spawn, input, kill, the process list): a session's first window on a
-- tty of its own in a session of its own; a display copying it and the
-- status bar; typing passed to the window; Ctrl+A c, n, p, digits,
-- naming, kill (with y), the scrollback, detach and attach again at
-- another size (the windows resized and told), -d -r taking a session
-- from another display, -x sharing it, a window's title from what runs
-- in it, the session ending with its last window.
local PROJ = ...
package.path = PROJ .. "/lib/?.lua;" .. PROJ .. "/sim/lib/?.lua;" .. package.path
local M = require("mock")
local check = M.check

keys = { enter = 257, tab = 258, backspace = 259, delete = 261, right = 262, left = 263, down = 264, up = 265,
    pageUp = 266, pageDown = 267, home = 268, ["end"] = 269, escape = 256,
    leftCtrl = 341, rightCtrl = 345, leftAlt = 342, rightAlt = 346, leftShift = 340, rightShift = 344,
    leftBracket = 91, numPadEnter = 335 }
for i = 0, 25 do keys[string.char(97 + i)] = 65 + i end
colours = { white = 1, orange = 2, magenta = 4, lightBlue = 8, yellow = 16, lime = 32, pink = 64, grey = 128,
    lightGrey = 256, cyan = 512, purple = 1024, blue = 2048, brown = 4096, green = 8192, red = 16384, black = 32768 }
colors = colours
local CLOCK = 0
os.clock = function() return CLOCK end

-- a terminal, enough of CC's window: text and colours per row, scroll, reposition
local LOG2 = {}
for i = 0, 15 do LOG2[2 ^ i] = i end
local function window(w, h)
    local win, rows, fgs, bgs = {}, {}, {}, {}
    local x, y, fg, bg, blink, tc = 1, 1, "0", "f", false, colours.white
    local function blank(r) rows[r], fgs[r], bgs[r] = (" "):rep(w), ("0"):rep(w), ("f"):rep(w) end
    for r = 1, h do blank(r) end
    function win.getSize() return w, h end
    function win.isColour() return true end
    function win.getLine(r) return rows[r], fgs[r], bgs[r] end
    function win.setCursorPos(nx, ny) x, y = nx, ny end
    function win.getCursorPos() return x, y end
    function win.setCursorBlink(b) blink = b end
    function win.getCursorBlink() return blink end
    function win.setTextColour(c) tc = c; fg = string.format("%x", LOG2[c]) end
    function win.getTextColour() return tc end
    function win.setBackgroundColour(c) bg = string.format("%x", LOG2[c]) end
    function win.write(s)
        for i = 1, #s do
            if y >= 1 and y <= h and x >= 1 and x <= w then
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
            rows[h], fgs[h], bgs[h] = (" "):rep(w), ("0"):rep(w), ("f"):rep(w)
        end
    end
    function win.reposition(_, _, nw, nh)
        for r = 1, nh do
            rows[r] = ((rows[r] or "") .. (" "):rep(nw)):sub(1, nw)
            fgs[r] = ((fgs[r] or "") .. ("0"):rep(nw)):sub(1, nw)
            bgs[r] = ((bgs[r] or "") .. ("f"):rep(nw)):sub(1, nw)
        end
        for r = nh + 1, h do rows[r], fgs[r], bgs[r] = nil, nil, nil end
        w, h = nw, nh
    end
    -- a line as a program prints it: at the cursor, then down, scrolling at the bottom
    function win.say(text)
        win.write(text)
        if y >= h then win.scroll(1); x = 1 else x, y = 1, y + 1 end
    end
    function win.row(r) return rows[r] end
    return win
end

-- the fake init
local procs, inputs, nextPid = {}, {}, 10
local proc = {}
function proc.newTerm(w, h) return window(w, h) end
function proc.spawn(spec)
    local pid = nextPid
    nextPid = nextPid + 1
    procs[pid] = { pid = pid, tty = spec.tty, name = "ccsh", spec = spec }
    inputs[spec.tty] = inputs[spec.tty] or {}
    return pid
end
function proc.input(tty, ...)
    inputs[tty] = inputs[tty] or {}
    local ev = table.pack(...)
    local parts = {}
    for i = 1, ev.n do parts[#parts + 1] = tostring(ev[i]) end
    table.insert(inputs[tty], table.concat(parts, " "))
end
function proc.kill(pid)
    local p = procs[pid]
    if not p then return end
    procs[pid] = nil
    if p.spec and p.spec.onExit then p.spec.onExit(p) end
end
local selfPid = 1
function proc.self() return selfPid end
function proc.list()
    local out = { { pid = 1, tty = "pts/1", name = "screen" }, { pid = 2, tty = "pts/2", name = "screen" } }
    for _, p in pairs(procs) do out[#out + 1] = { pid = p.pid, tty = p.tty, name = p.name } end
    return out
end

local screen = require("screen")
local function inputsOf(tty) return table.concat(inputs[tty] or {}, ", ") end
local function clearInputs() for k in pairs(inputs) do inputs[k] = {} end end
local function ctrlA(d, letter)
    d:event("key", keys.leftCtrl, false)
    d:event("key", keys.a, false)
    d:event("char", "a")                 -- (CC may send the letter's char too: swallowed)
    d:event("key_up", keys.a)
    d:event("key_up", keys.leftCtrl)
    return d:event("char", letter)
end

-- 1. a session and a display
local native = window(51, 19)
local s = screen.newSession(proc, { name = "work", w = 51, h = 18 })
local w0 = s.windows[1]
check("a session: window 0 on its own tty, in a session of its own, a terminal the size less the status bar",
    w0.n == 0 and w0.tty == "scr/work.0" and procs[w0.pid].spec.session == true and select(2, w0.term.getSize()) == 18
    and screen.find("work") == s)
local d = screen.display(s, native, proc, { pid = 1 })
w0.term.setCursorPos(1, 1)
w0.term.say("hello from window 0")
d:draw()
check("the display: the window's rows, the status bar (the windows, the name)", native.row(1):find("hello from window 0", 1, true)
    and native.row(19):find("0*ccsh", 1, true) and native.row(19):find("[work]", 1, true), native.row(19))
d:event("char", "x")
d:event("key", keys.enter, false)
check("typing goes to the window's tty, as it came", inputsOf("scr/work.0") == "char x, key " .. keys.enter .. " false",
    inputsOf("scr/work.0"))

-- 2. Ctrl+A commands
clearInputs()
ctrlA(d, "c")
local w1 = s.current
check("Ctrl+A c: window 1, shown; only Ctrl reached window 0 (down, then let up), nothing window 1",
    w1.n == 1 and #s.windows == 2 and inputsOf("scr/work.1") == ""
    and inputsOf("scr/work.0") == "key " .. keys.leftCtrl .. " false, key_up " .. keys.leftCtrl,
    inputsOf("scr/work.0") .. " / " .. inputsOf("scr/work.1"))
d:draw()
check("a message on the status bar for a moment", native.row(19):find("window 1", 1, true))
CLOCK = CLOCK + 3
d:draw()
check("the status bar: 0- (the one before) and 1* (this one)", native.row(19):find("0-ccsh", 1, true)
    and native.row(19):find("1*ccsh", 1, true), native.row(19))
ctrlA(d, "0")
check("Ctrl+A 0", s.current == w0)
ctrlA(d, "n")
check("Ctrl+A n", s.current == w1)
ctrlA(d, "p")
check("Ctrl+A p", s.current == w0)
ctrlA(d, " ")
check("Ctrl+A space: the next", s.current == w1)
clearInputs()
ctrlA(d, "a")
check("Ctrl+A a: a Ctrl+A for the window", inputsOf("scr/work.1"):find("key " .. keys.leftCtrl .. " false, key " .. keys.a, 1, true))
ctrlA(d, "t")
check("Ctrl+A t: a terminate for the window", inputsOf("scr/work.1"):find("terminate", 1, true))
procs[w1.pid + 100] = { pid = w1.pid + 100, tty = w1.tty, name = "irc" }
d:draw()
check("a window's title: what runs newest on its tty", native.row(19):find("1*irc", 1, true), native.row(19))
procs[w1.pid + 100] = nil
ctrlA(d, "A")
for _, ch in ipairs({ "c", "h", "a", "t" }) do d:event("char", ch) end
d:event("key", keys.enter, false)
CLOCK = CLOCK + 3
d:draw()
check("Ctrl+A A: the window named", w1.name == "chat" and native.row(19):find("1*chat", 1, true), native.row(19))

clearInputs()
local labels = d:labels()
d:event("mouse_click", 1, labels[1].from + 1, 19)
check("a click on a window's label on the status bar goes to that window", s.current == w0, labels[1].text)
d:event("mouse_click", 1, labels[2].to, 19)
check("  ... and on the other's, back", s.current == w1, labels[2].text)
d:event("mouse_click", 1, labels[2].to + 1, 19)
check("  ... between the labels, nothing", s.current == w1)
d:event("mouse_click", 1, 5, 3)
check("a click on the status bar isn't the window's; one above it is", inputsOf(s.current.tty) == "mouse_click 1 5 3",
    inputsOf(s.current.tty))

-- 3. the scrollback
s:select(w0)
for i = 1, 40 do w0.term.say("line " .. i) end
d:draw()
check("what scrolled off the top is kept", #w0.hist >= 20 and native.row(18):find("line 40", 1, true) == nil
    and native.row(17):find("line 40", 1, true), native.row(17))
ctrlA(d, "[")
d:event("key", keys.pageUp, false)
d:draw()
check("Ctrl+A [, PgUp: 17 rows back (older lines on the screen), the status bar says so",
    native.row(1):sub(1, 7) == "line 7 " and native.row(19):find("scrollback: 17 up", 1, true), native.row(1) .. " / " .. native.row(19))
d:event("key", keys.q, false)
d:draw()
check("q leaves it", not d.mode and native.row(17):find("line 40", 1, true))

-- 4. detach, attach again elsewhere
check("Ctrl+T (or a hangup) detaches", d:event("terminate") == "detach")
check("Ctrl+A d detaches", ctrlA(d, "d") == "detach")
d:detach()
check("detached: no display", s:attached() == 0)
clearInputs()
local small = window(40, 15)
selfPid = 2
local d2 = screen.display(s, small, proc, { pid = 2 })
check("attached again at another size: the windows resized, each told", select(1, w0.term.getSize()) == 40
    and select(2, w1.term.getSize()) == 14 and inputsOf("scr/work.0") == "term_resize" and inputsOf("scr/work.1") == "term_resize")
d2:draw()
check("it shows the window (its top rows, as CC's windows keep them when they shrink)", small.row(1):sub(1, 5) == "line ",
    small.row(1))
local d3 = screen.display(s, window(40, 15), proc, { pid = 1 })
check("-x: two displays share it", s:attached() == 2)
for pid in pairs(s.displays) do s.displays[pid] = nil end      -- (what -d -r does)
s.displays[1] = true
check("-d -r: the other display is told it was taken", d2:event("char", "z") == "taken" and d3:event("char", "z") == nil)
s.displays[2] = true

-- 5. kill, and the end
ctrlA(d3, "k")
d3:draw()
check("Ctrl+A k asks first", d3.confirm == "kill")
d3:event("char", "n")
check("n: nothing killed", #s.windows == 2 and procs[s.current.pid])
local killed = s.current
ctrlA(d3, "k")
d3:event("char", "y")
d3:event("char", "q")
check("y: the window's process killed, the window gone, the other shown", procs[killed.pid] == nil and #s.windows == 1
    and s.current ~= killed)
local last = s.current
proc.kill(last.pid)
check("the last window ending ends the session", d3:event("char", "q") == "gone" and screen.find("work") == nil)
