-- sim/readline.lua
--
-- lib/readline, the line editor ccsh's prompt uses, on a 51 x 19 screen:
-- keys go in as CC events, written out as "abc<C-a>X<CR>" (<C-x> Ctrl,
-- <M-x> Alt, <C-M-x> Ctrl+Alt, i.e. AltGr), and each check looks at the
-- line it returned or at the screen.  Then the same keys as a telnet
-- client sends them (through lib/telnet's decoder), and ccsh on a
-- shellworld computer with the real editor: Ctrl+C at the prompt and on
-- a command, Ctrl+D, history.
local PROJ = ...
package.path = PROJ .. "/lib/?.lua;" .. PROJ .. "/sim/lib/?.lua;" .. package.path
local M = require("mock")
local check = M.check

-- CC:Tweaked's key codes (GLFW's)
keys = { enter = 257, tab = 258, backspace = 259, insert = 260, delete = 261, right = 262, left = 263,
    down = 264, up = 265, pageUp = 266, pageDown = 267, home = 268, ["end"] = 269, escape = 256,
    leftCtrl = 341, rightCtrl = 345, leftAlt = 342, rightAlt = 346, leftShift = 340, leftBracket = 91,
    rightBracket = 93, numPadEnter = 335, space = 32, minus = 45, period = 46, slash = 47 }
for i = 0, 25 do keys[string.char(97 + i)] = 65 + i end
local DIGITS = { "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine" }
for i, name in ipairs(DIGITS) do keys[name] = 47 + i end
function keys.getName(code)
    for k, v in pairs(keys) do if v == code and type(v) == "number" then return k end end
end
colours = { white = 1, orange = 2, magenta = 4, lightBlue = 8, yellow = 16, lime = 32, pink = 64, grey = 128,
    lightGrey = 256, cyan = 512, purple = 1024, blue = 2048, brown = 4096, green = 8192, red = 16384, black = 32768 }
colors = colours

-- the screen: text and each cell's colour (a letter: w white, y yellow,
-- g light grey)
local W, H = 51, 19
local LETTER = { [colours.white] = "w", [colours.yellow] = "y", [colours.lightGrey] = "g" }
local T = { rows = {}, fg = {}, x = 1, y = 1, colour = colours.white, isColour = true }
local function blank() for r = 1, H do T.rows[r] = string.rep(" ", W); T.fg[r] = string.rep("w", W) end end
blank()
local function put(s)
    local row = T.rows[T.y]
    if row then
        local from, to = math.max(T.x, 1), math.min(T.x + #s - 1, W)
        if to >= from then
            local f = string.rep(LETTER[T.colour] or "?", to - from + 1)
            T.rows[T.y] = row:sub(1, from - 1) .. s:sub(from - T.x + 1, to - T.x + 1) .. row:sub(to + 1)
            T.fg[T.y] = T.fg[T.y]:sub(1, from - 1) .. f .. T.fg[T.y]:sub(to + 1)
        end
    end
    T.x = T.x + #s
end
local function scroll()
    table.remove(T.rows, 1); table.remove(T.fg, 1)
    T.rows[H], T.fg[H] = string.rep(" ", W), string.rep("w", W)
end
term = {
    getSize = function() return W, H end,
    setCursorPos = function(x, y) T.x, T.y = x, y end,
    getCursorPos = function() return T.x, T.y end,
    setCursorBlink = function() end,
    setTextColour = function(c) T.colour = c end,
    getTextColour = function() return T.colour end,
    setBackgroundColour = function() end,
    isColour = function() return T.isColour end,
    clear = blank,
    clearLine = function()
        if T.rows[T.y] then T.rows[T.y], T.fg[T.y] = string.rep(" ", W), string.rep("w", W) end
    end,
    write = function(s) put(tostring(s)) end,
}
term.setTextColor, term.getTextColor, term.isColor = term.setTextColour, term.getTextColour, term.isColour
-- write and print as the BIOS has them: "\n" starts the next row,
-- scrolling at the bottom
write = function(s)
    s = tostring(s)
    local i = 1
    while i <= #s do
        local nl = s:find("\n", i, true)
        put(s:sub(i, (nl or #s + 1) - 1))
        if not nl then break end
        T.x, T.y = 1, T.y + 1
        if T.y > H then scroll(); T.y = H end
        i = nl + 1
    end
end
print = function(...) write(table.concat({ ... }, " ") .. "\n") end
local function text(r) return (T.rows[r]:gsub("%s+$", "")) end

-- "abc<C-a>X<CR>" as events.  A letter or digit typed is its key's event
-- and its char; Ctrl+letter is Ctrl down, the letter's key, a char (in
-- case one comes: it mustn't type) and the keys up.
local SPECIAL = { CR = "enter", BS = "backspace", Tab = "tab", Del = "delete", Up = "up", Down = "down",
    Left = "left", Right = "right", Home = "home", End = "end", Esc = "escape" }
local function keyOf(c)
    local l = c:lower()
    if keys[l] and #l == 1 then return keys[l] end
    if c:match("%d") then return keys[DIGITS[tonumber(c) + 1]] end
    return ({ [" "] = keys.space, ["-"] = keys.minus, ["."] = keys.period, ["/"] = keys.slash, ["["] = keys.leftBracket })[c]
end
local function events(s)
    local out = {}
    local function add(...) out[#out + 1] = table.pack(...) end
    local i = 1
    while i <= #s do
        local close = s:sub(i, i) == "<" and s:find(">", i + 1, true)
        local inner = close and s:sub(i + 1, close - 1)
        if inner and #inner > 1 then
            i = close + 1
            local mods, ch = {}, inner
            while ch:sub(2, 2) == "-" and #ch > 2 and (ch:sub(1, 1) == "C" or ch:sub(1, 1) == "M") do
                mods[ch:sub(1, 1)] = true
                ch = ch:sub(3)
            end
            if inner:sub(1, 6) == "Paste:" then
                add("paste", (inner:sub(7):gsub("|", "\n")))
            elseif inner == "Term" then
                add("terminate")
            elseif SPECIAL[inner] then
                add("key", keys[SPECIAL[inner]], false)
                add("key_up", keys[SPECIAL[inner]])
            elseif mods.C and mods.M then          -- AltGr: Ctrl and Alt, typing a character
                add("key", keys.leftCtrl, false); add("key", keys.rightAlt, false)
                add("key", keys.q, false); add("char", ch); add("key_up", keys.q)
                add("key_up", keys.rightAlt); add("key_up", keys.leftCtrl)
            else
                local mod = mods.C and keys.leftCtrl or keys.leftAlt
                local code = keyOf(ch) or keys[SPECIAL[ch] or ch]
                add("key", mod, false); add("key", code, false)
                if #ch == 1 then add("char", ch) end
                add("key_up", code); add("key_up", mod)
            end
        else
            local c = s:sub(i, i)
            local code = keyOf(c)
            if code then add("key", code, false) end
            add("char", c)
            if code then add("key_up", code) end
            i = i + 1
        end
    end
    return out
end

local RL = require("readline")
local queue, screens = {}, {}
os.pullEventRaw = function()
    -- a function in the queue is something else running meanwhile (a
    -- background job writing); what it queues comes next
    while type(queue[1]) == "function" do table.remove(queue, 1)() end
    screens[#screens + 1] = { rows = { table.unpack(T.rows) }, fg = { table.unpack(T.fg) }, x = T.x, y = T.y }
    if #queue == 0 then error("no more events: the editor wanted another key", 0) end
    return table.unpack(table.remove(queue, 1))
end

-- Read a line with these keys (or events), on a cleared screen with the
-- prompt "$ " unless opts say otherwise; the line, or nil and why.
local function edit(keyText, opts)
    opts = opts or {}
    blank()
    T.x, T.y, T.colour = 1, opts.row or 1, colours.white
    queue = type(keyText) == "table" and keyText or events(keyText)
    screens = {}
    local o = { prompt = opts.prompt or "$ ", promptColour = colours.yellow, colour = colours.white,
        history = opts.history, complete = opts.complete }
    local ok, line, why = pcall(RL.read, o)
    if not ok then return nil, "error: " .. tostring(line) end
    -- (left over, the keys let go after the last one pressed, and the
    -- char of a last Ctrl+letter: the next line's to drop)
    for _, ev in ipairs(queue) do
        if ev[1] ~= "key_up" and ev[1] ~= "char" then return nil, "left over: " .. #queue .. " events" end
    end
    return line, why
end
local function show(v) return (tostring(v):gsub("\n", "\\n")) end
os.queueEvent = function(...) table.insert(queue, 1, table.pack(...)) end

-- Output from a background job while a line is typed, through
-- readline.guard: it goes where the prompt was, the prompt and the line
-- come back below it.
local function withOutput(before, writer, after)
    local evs = events(before)
    evs[#evs + 1] = writer
    for _, ev in ipairs(events(after)) do evs[#evs + 1] = ev end
    return evs
end
local guarded = RL.guard(term)
local line = edit(withOutput("ab", function()
    guarded.write("PING 10.1.1.99")
    guarded.setCursorPos(1, 2)
end, "c<CR>"))
check("background output while typing: it takes the prompt's place, the prompt and the line come back below",
    line == "abc" and text(1) == "PING 10.1.1.99" and text(2) == "$ abc", show(text(1)) .. " / " .. show(text(2)))
line = edit(withOutput("ab<Left>", function() guarded.write("partial") end, "X<CR>"))
check("output that doesn't end its line: the prompt starts a new one; the cursor's place in the line kept",
    line == "aXb" and text(1) == "partial" and text(2) == "$ aXb", show(text(1)) .. " / " .. show(text(2)))
line = edit(withOutput("ab", function()
    guarded.setCursorPos(1, 5)
    guarded.write("status line")
end, "c<CR>"))
check("a writer that puts the cursor somewhere first is left alone, and so is the prompt",
    line == "abc" and text(1) == "$ abc" and text(5) == "status line", show(text(1)) .. " / " .. show(text(5)))
line = edit(withOutput("ab", function()
    guarded.write("one")
    guarded.setCursorPos(1, 2)
    guarded.write("two")
    guarded.setCursorPos(1, 3)
end, "c<CR>"), { prompt = "> \n$ " })
check("a prompt of two rows comes off whole; several writes in one turn take it off once",
    line == "abc" and text(1) == "one" and text(2) == "two" and text(3) == ">" and text(4) == "$ abc",
    show(text(1)) .. " / " .. show(text(2)) .. " / " .. show(text(3)) .. " / " .. show(text(4)))
local function same(label, want, got, why)
    check(label, got == want, "got " .. show(got) .. (why and (" (" .. show(why) .. ")") or "") .. ", want " .. show(want))
end

-- 1. typing, moving, Enter
same("typing, and Enter", "echo hi", edit("echo hi<CR>"))
check("the prompt in its colour, the line after it, then a new line",
    text(1) == "$ echo hi" and T.fg[1]:sub(1, 2) == "yy" and T.fg[1]:sub(3, 9) == "wwwwwww" and T.y == 2 and T.x == 1,
    text(1) .. " " .. T.fg[1]:sub(1, 9) .. " at " .. T.x .. "," .. T.y)
same("Ctrl+A and Ctrl+E: the start and the end (their chars don't type)", "XabcY", edit("abc<C-a>X<C-e>Y<CR>"))
same("Home and End", "XabcY", edit("abc<Home>X<End>Y<CR>"))
same("Ctrl+B and Ctrl+F, Left and Right", "abYXc",edit("abc<C-b>X<Left><Left><C-f>Y<CR>"))
same("Left at the start and Right at the end stay put", "Xab", edit("ab<Home><Left>X<End><Right><CR>"))
same("Backspace and Ctrl+H: the character before", "abc", edit("abXYc<Left><BS><C-h><CR>"))
same("Backspace takes the one before the cursor", "abd", edit("abcd<Left><BS><CR>"))
same("Backspace at the start of the line does nothing; typing goes on in order", "xab",
    edit("ab<Home><BS><BS>x<CR>"))
same("Backspace on an empty line, then typing", "xyz", edit("<BS><BS>xyz<CR>"))
same("Delete at the end of the line does nothing", "abc", edit("ab<Del><Del>c<CR>"))
same("Ctrl+H, Ctrl+D, Ctrl+W, Ctrl+U at the edges do nothing", "ok", edit("<C-h><C-w><C-u>o<End><C-d>k<CR>"))
same("Delete and Ctrl+D the one under the cursor", "bd", edit("abcd<Home><Del><Right><C-d><CR>"))

-- 2. words
same("Alt+B: a word back, twice", "one Xtwo three", edit("one two three<M-b><M-b>X<CR>"))
same("Alt+F: to a word's end", "oneX two", edit("one two<C-a><M-f>X<CR>"))
same("Esc then b (a telnet client's Alt+B), and Ctrl+[ then f", "one Xtwo threeY",
    edit("one two three<Esc>b<Esc>bX<C-[>f<C-[>f<C-[>fY<CR>"))
same("Alt+B over punctuation: words are letters and digits", "a.b/Xc9", edit("a.b/c9<M-b>X<CR>"))

-- 3. cutting and putting back
same("Ctrl+W: the word before, up to a space", "ls -l ", edit("ls -l /rom/x<C-w><CR>"))
same("Ctrl+K: to the end", "ab", edit("abcdef<C-a><C-f><C-f><C-k><CR>"))
same("Ctrl+Y puts back what Ctrl+K cut", "cdefab", edit("abcdef<C-a><C-f><C-f><C-k><C-a><C-y><CR>"))
same("Ctrl+U: to the start, and Ctrl+Y", "efabcd", edit("abcdef<Left><Left><C-u><End><C-y><CR>"))
same("what was cut stays for the next line", "abcd", edit("<C-y><CR>"))
same("Alt+D: the word after", " two", edit("one two<C-a><M-d><CR>"))
same("Alt+Backspace: the word before", "one ", edit("one two<M-BS><CR>"))
same("Ctrl+W at the start cuts nothing", "abc", edit("abc<C-a><C-w><CR>"))

-- 4. Ctrl+D, Ctrl+C, Ctrl+T, paste, AltGr, keys bound to nothing
same("Ctrl+D on an empty line: the end of input", nil, edit("<C-d>"))
local l, why = edit("<C-d>")
check("  ... why: eof, no new line", l == nil and why == "eof" and T.y == 1, show(why) .. " at " .. T.y)
same("Ctrl+D on a line with text deletes", "bc", edit("abc<C-a><C-d><CR>"))
l, why = edit("abc<Left><C-c>")
check("Ctrl+C drops the line: ^C shown after it, a new line started",
    l == nil and why == "interrupt" and text(1) == "$ abc^C" and T.y == 2 and T.x == 1, show(why) .. " " .. text(1))
l, why = edit("ab<Term>")
check("the terminate event (Ctrl+T held): nil, terminate", l == nil and why == "terminate", show(why))
same("a paste is typed in, up to its first line break", "x pasted y", edit("x <Paste:pasted|more> y<CR>"))
same("Ctrl with Alt is AltGr: its character is typed, not a binding", "a@b", edit("a<C-M-@>b<CR>"))
same("Ctrl+Z, Ctrl+S, Ctrl+T taps do nothing (and type nothing)", "ab", edit("a<C-z><C-s><C-t>b<CR>"))

-- 5. Ctrl+L
edit("<C-l>abc<CR>", { row = 7 })
local before = screens[1]
same("Ctrl+L clears the screen: the prompt and the line at the top", "$ abc", text(1))
check("  ... and nothing of the old screen left", before.rows[7]:sub(1, 2) == "$ " and text(7) == "", text(7))
edit("ls<C-l><CR>", { prompt = "one\ntwo$ " })
check("a prompt of two lines is drawn again whole", text(1) == "one" and text(2) == "two$ ls", text(1) .. "|" .. text(2))

-- 6. history
local hist = { "first", "second" }
same("Up: the line before", "second", edit("<Up><CR>", { history = hist }))
same("Up twice, Up at the oldest stays", "first", edit("<Up><Up><Up><CR>", { history = hist }))
same("Ctrl+P and Ctrl+N", "second", edit("<C-p><C-p><C-n><CR>", { history = hist }))
same("Down back to the line being typed: as it was left", "draft", edit("draft<Up><Up><Down><Down><CR>", { history = hist }))
same("a line from the history can be edited", "second!", edit("<Up>!<CR>", { history = hist }))
check("  ... the history isn't changed", hist[1] == "first" and hist[2] == "second" and #hist == 2)
same("no history: Up does nothing", "x", edit("x<Up><CR>"))

-- 7. Ctrl+R
hist = { "echo one", "ls -l", "echo two" }
same("Ctrl+R: the newest line holding what's typed; Enter takes it", "echo two", edit("<C-r>echo<CR>", { history = hist }))
same("Ctrl+R again: an older one", "echo one", edit("<C-r>echo<C-r><CR>", { history = hist }))
edit("<C-r>ech<CR>", { history = hist })
local shown = screens[#screens].rows[1]:gsub("%s+$", "")
same("it shows (search)`text': and the match", "$ (search)`ech': echo two", shown)
same("another key leaves the search with the line, the cursor at the match", "lXs -l",
    edit("<C-r>ls<Right>X<CR>", { history = hist }))
same("Ctrl+G puts back the line there was", "draft", edit("draft<C-r>ls<C-g><CR>", { history = hist }))
edit("<C-r>zzz<CR>", { history = hist })
shown = screens[#screens].rows[1]:gsub("%s+$", "")
check("no match: (failed search), the line as it was", shown == "$ (failed search)`zzz':", shown)
same("Backspace takes a letter off the search", "ls -l", edit("<C-r>lsx<BS><CR>", { history = hist }))
same("Ctrl+R on an empty search: the last one again", "ls one", edit("<C-r><C-r><CR>", { history = { "x", "ls one", "echo two" } }))
same("after a search, Up goes on from the line found", "echo one", edit("<C-r>ls<Up><CR>", { history = hist }))
l, why = edit("<C-r>echo<C-c>", { history = hist })
check("Ctrl+C in a search drops the line", l == nil and why == "interrupt", show(why))

-- 8. completion
local function complete(line)
    if line == "ec" then return { "ho", "ho2" } end
    if line == "echo" then return { "2" } end
    return nil
end
same("Tab adds the completion shown", "echo", edit("ec<Tab><CR>", { complete = complete }))
edit("ec<CR>", { complete = complete })
local s = screens[#screens]
check("it shows in grey after the cursor, while the cursor's at the end",
    s.rows[1]:sub(1, 6) == "$ echo" and s.fg[1]:sub(5, 6) == "gg" and s.x == 5, s.rows[1]:sub(1, 8) .. " " .. s.fg[1]:sub(1, 8))
check("  ... and goes when the line's done", text(1) == "$ ec", text(1))
same("Down and Up go through the completions while they show", "echo2", edit("ec<Down><Tab><CR>", { complete = complete }))
same("  ... round to the first again", "echo2", edit("ec<Up><Tab><CR>", { complete = complete }))
same("Tab again completes from there", "echo2", edit("ec<Tab><Tab><CR>", { complete = complete }))
edit("ecc<Left><BS><CR>", { complete = complete })
s = screens[#screens]
check("none with the cursor before the end", s.rows[1]:sub(1, 7) == "$ ec   " and s.x == 4, s.rows[1]:sub(1, 8))
same("Up with no completion showing walks the history", "old", edit("x<Up><CR>", { complete = complete, history = { "old" } }))
same("a line from the history shows no completion: Up goes on back, past one that would have one", "first",
    edit("<Up><Up><Up><CR>", { complete = complete, history = { "first", "ec", "echo" } }))
same("  ... until it's changed: then they show again", "echo2",
    edit("<Up><BS>c<Down><Tab><CR>", { complete = complete, history = { "x", "ec" } }))

-- 9. a line wider than the screen
local long = string.rep("abcdefghij", 7)       -- 70 characters on 49 columns
edit(long .. "<CR>")
s = screens[#screens]
check("a long line scrolls sideways: its end shows, the cursor at the last column",
    s.rows[1] == "$ " .. long:sub(70 - 48 + 1) .. " " and s.x == 51, s.rows[1] .. " at " .. s.x)
same("Enter leaves its end shown", "$ " .. long:sub(70 - 48 + 1), text(1))
edit(long .. "<C-a><CR>")
s = screens[#screens]
check("Ctrl+A: back to its start", s.rows[1] == "$ " .. long:sub(1, 49) and s.x == 3, s.rows[1] .. " at " .. s.x)
same("editing a long line in the middle", long:sub(1, 30) .. "X" .. long:sub(31),
    edit(long .. "<C-a>" .. string.rep("<C-f>", 30) .. "X<CR>"))
edit("abc<CR>", { prompt = string.rep("p", 51) })
check("a prompt as wide as the screen: the line goes on the next row", text(1) == string.rep("p", 51) and text(2) == "abc",
    text(1) .. "|" .. text(2))

-- 10. the same keys from a telnet client: lib/telnet's decoder makes them
local TL = require("telnet")
local function telnet(bytes)
    local evs = {}
    TL.decoder(function(...) evs[#evs + 1] = table.pack(...) end, keys)(bytes)
    return evs
end
same("over telnet: Ctrl+A (byte 1), Enter (CR)", "Xabc", edit(telnet("abc\1X\r")))
same("over telnet: Esc b is Alt+B", "one Xtwo", edit(telnet("one two\27bX\r")))
same("over telnet: Ctrl+W, Ctrl+Y", "ba ", edit(telnet("a b\23\1\25\r")))
same("over telnet: an arrow, the history", "old", edit(telnet("\27[A\r"), { history = { "old" } }))
l, why = edit(telnet("abc\3"))
check("over telnet: Ctrl+C", l == nil and why == "interrupt", show(why))
l, why = edit(telnet("\4"))
check("over telnet: Ctrl+D on an empty line", l == nil and why == "eof", show(why))
same("over telnet: Ctrl+R", "ls -l", edit(telnet("\18ls\r"), { history = { "ls -l", "echo" } }))

-- 11. ccsh at the prompt, with the real editor
local SW = require("shellworld")
local sw = SW.new(PROJ)
for _, u in ipairs({ "echo" }) do sw:install(u) end
sw:file("ccnix/bin/waitT.lua", [[os.pullEvent("never")]])
sw.modules.readline = nil
sw.yieldEvents = true
local function typed(keyText, opts)
    opts = opts or {}
    opts.events = events(keyText)
    return sw:run("ccsh", opts)
end
local r = typed("echo hi<CR>abc<C-c>echo $?<CR><C-d>")
check("ccsh: a line typed runs; Ctrl+C drops one, status 130; Ctrl+D on an empty line leaves",
    r.ok and r.out:find("hi\n", 1, true) ~= nil and r.out:find("130\n", 1, true) ~= nil and r.errText == "",
    show(r.out) .. " " .. show(r.errText))
r = typed("echo one<CR><Up><CR><C-d>")
check("ccsh: Up brings the line before back", r.out:find("/$ \none\n/$ \none\n", 1, true) ~= nil, show(r.out))
r = typed("waitT<CR><C-c>echo $?<CR><C-d>")
check("ccsh: Ctrl+C while a command runs ends it as Ctrl+T does, status 130",
    r.out:find("130\n", 1, true) ~= nil, show(r.out) .. " " .. show(r.errText))
sw:file("ccnix/bin/adventure.lua", [[local _, k repeat _, k = os.pullEvent("key") until k == keys.c os.pullEvent("char") print("got c")]])
r = typed("adventure<CR><C-c>echo $?<CR><C-d>")
check("ccsh: a program that uses Ctrl+C as a key (edit, lua, vi, telnet...) gets it, and isn't ended",
    r.out:find("got c\n", 1, true) ~= nil and r.out:find("\n0\n", 1, true) ~= nil, show(r.out) .. " " .. show(r.errText))
r = typed("echo 'a<CR>b<C-c>echo $?<CR><C-d>")
check("ccsh: Ctrl+C at the > of a line going on drops it all", r.out:find("130\n", 1, true) ~= nil
    and r.out:find("a\nb", 1, true) == nil, show(r.out))
r = typed("<C-z><C-d>")
check("ccsh: Ctrl+Z at the prompt is nothing", r.ok and r.out:find("Stopped", 1, true) == nil, show(r.out))
