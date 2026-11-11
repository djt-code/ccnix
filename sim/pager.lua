-- sim/pager.lua
--
-- pager.lua (and more, which uses it) on the turtle's 39 x 13 screen, with
-- scripted key presses: what each key does to the view, the status line,
-- sideways scrolling without wrapping, and q giving the keyboard back.
local PROJ = ...
package.path = PROJ .. "/lib/?.lua;" .. PROJ .. "/sim/lib/?.lua;" .. package.path
local M = require("mock")
local check = M.check

local S = M.state()
local T = M.termApi(39, 13)
M.capturePrint(S)
local pager = require("pager")

-- 40 lines, line 5 of them 100 wide
local LONG = ""
for i = 1, 10 do LONG = LONG .. string.rep(tostring(i % 10), 10) end
local text = {}
for i = 1, 40 do text[i] = string.format("line %02d", i) .. (i == 5 and (" " .. LONG) or "") end

-- Page `lines` with these key presses (then q), and return the view after
-- each one: { top = first line shown, row1 = its text, status = ... }.
local function press(lines, ...)
    local seen = {}
    local evs = { ... }
    for _, e in ipairs(evs) do T.events[#T.events + 1] = e end
    T.events[#T.events + 1] = { "char", "q" }
    T.events[#T.events + 1] = { "char", "MARK" }     -- must still be there after q
    local pull = os.pullEvent
    os.pullEvent = function()
        seen[#seen + 1] = { row1 = T.text(1), row5 = T.rows[5], status = T.text(13), inv = T.inverse[13] }
        return pull()
    end
    pager.page(lines, OPTS)
    os.pullEvent = pull
    local left = T.events[1]
    T.events = {}
    return seen, left
end
local function topOf(v) return tonumber(v.row1:match("^line (%d+)")) end

-- 1. what fits is just printed: no viewer, no keys taken
S.log = {}
T.events = { { "char", "MARK" } }
pager.page("one\r\ntwo\tthree\n")
check("short text printed as it is (CR dropped, tab as spaces)",
    S.log[1] == "one" and S.log[2] == "two    three" and #S.log == 2, table.concat(S.log, "|"))
check("and no key waited for", #T.events == 1)
T.events = {}

-- 2. paging: 12 lines of text, the 13th the status line
local v, left = press(text)
check("shows lines 1-12 and the status line", topOf(v[1]) == 1 and T.text(12):find("^line 12") ~= nil
    and v[1].status:find("1%-12/40") ~= nil and v[1].inv, v[1].status)
check("q quits, and leaves the next key for the shell", left and left[2] == "MARK")
check("status line cleared on the way out", T.text(13) == "")

v = press(text, { "char", " " }, { "key", keys.pageDown }, { "char", "f" }, { "char", "b" }, { "key", keys.pageUp })
check("space, PgDn and f go 11 lines down; b and PgUp 11 up",
    topOf(v[2]) == 12 and topOf(v[3]) == 23 and topOf(v[4]) == 29 and topOf(v[5]) == 18 and topOf(v[6]) == 7,
    topOf(v[2]) .. " " .. topOf(v[3]) .. " " .. topOf(v[4]) .. " " .. topOf(v[5]) .. " " .. topOf(v[6]))
check("can't page past the end (the last screen is lines 29-40) and says END", v[4].status:find("29%-40/40 col 1 END") ~= nil, v[4].status)

v = press(text, { "char", "j" }, { "key", keys.down }, { "key", keys.enter }, { "char", "k" }, { "key", keys.up }, { "key", keys.up })
check("j, down and Enter a line down; k and up a line up, not above the top",
    topOf(v[2]) == 2 and topOf(v[3]) == 3 and topOf(v[4]) == 4 and topOf(v[5]) == 3 and topOf(v[6]) == 2 and topOf(v[7]) == 1)

v = press(text, { "char", "G" }, { "char", "g" }, { "key", keys["end"] }, { "key", keys.home }, { "char", "d" }, { "char", "u" })
check("G/End to the bottom, g/Home to the top, d/u half a page",
    topOf(v[2]) == 29 and topOf(v[3]) == 1 and topOf(v[4]) == 29 and topOf(v[5]) == 1 and topOf(v[6]) == 7 and topOf(v[7]) == 1)

-- 3. sideways: line 5 is 108 wide; nothing wraps
v = press(text, { "char", "l" }, { "key", keys.right }, { "char", "$" }, { "char", "h" }, { "key", keys.left }, { "char", "0" }, { "char", "h" })
local full = text[5]
local function shows(i, from) return v[i].row5 == full:sub(from, from + 38) end
check("not wrapped: line 5 fills its row and line 6 is on the next", T.rows[5] and #v[1].row5 == 39 and shows(1, 1))
check("l and right 8 columns right, $ to the end of the widest line",
    shows(2, 9) and shows(3, 17) and shows(4, #full - 38) and v[2].status:find("col 9") ~= nil)
check("h and left 8 back, 0 to the left edge, not past it",
    shows(5, #full - 46) and shows(6, #full - 54) and shows(7, 1) and shows(8, 1))

-- 3b. the mouse wheel: 3 lines a notch, not past either end
v = press(text, { "mouse_scroll", 1, 5, 5 }, { "mouse_scroll", 1, 5, 5 }, { "mouse_scroll", -1, 5, 5 },
    { "mouse_scroll", -1, 5, 5 }, { "mouse_scroll", -1, 5, 5 }, { "key", keys["end"] }, { "mouse_scroll", 1, 5, 5 })
check("the wheel down 3 lines a notch, up 3, not above the top or past the end",
    topOf(v[2]) == 4 and topOf(v[3]) == 7 and topOf(v[4]) == 4 and topOf(v[5]) == 1 and topOf(v[6]) == 1
        and topOf(v[8]) == 29, topOf(v[2]) .. " " .. topOf(v[3]) .. " " .. topOf(v[4]) .. " " .. topOf(v[8]))

-- 3c. wrapping: at word breaks, a word longer than a row cut, an empty
--     line kept
local rows, first = pager.wrap({ "aaa bbb ccc", "", string.rep("x", 20), "dd  ee" }, 7)
check("wrap: at spaces, a long word cut, empty lines kept, where each line starts",
    table.concat(rows, "|") == "aaa bbb|ccc||xxxxxxx|xxxxxxx|xxxxxx|dd  ee"
        and table.concat(first, ",") == "1,3,4,7", table.concat(rows, "|") .. " / " .. table.concat(first, ","))
local prose = {}
for i = 1, 8 do prose[i] = "para " .. i .. ": " .. string.rep("word ", 15) end
OPTS = { wrap = true }
v = press(prose, { "char", "G" })
local widestRow = 0
for r = 1, 12 do widestRow = math.max(widestRow, #T.text(r)) end
check("wrap = true: long lines wrap to the screen, no sideways scroll",
    v[1].row1:find("^para 1: word") and widestRow <= 39 and T.text(1):find("^%w") and not v[1].status:find("col"), v[1].status)
OPTS = { from = 20 }
v = press(text)
check("from = 20 opens at line 20", topOf(v[1]) == 20, v[1].row1)
OPTS = { from = math.huge }
v = press(text)
check("from = math.huge opens at the end", topOf(v[1]) == 29 and v[1].status:find("END"), v[1].status)
OPTS = { from = math.huge, up = 3 }
v = press(text)
check("up = 3: 3 rows above where from lands", topOf(v[1]) == 26, v[1].row1)
OPTS = { wrap = true, from = 3 }
v = press(prose)
check("with wrap, from counts lines, not rows", v[1].row1:find("^para 3:") ~= nil, v[1].row1)
OPTS = { always = true }
v = press({ "just one line" })
check("always = true: the viewer even for text that fits", v[1].row1 == "just one line" and v[1].status:find("1%-1/1"), v[1].status)
OPTS = nil

-- 3d. colour: a line { text, fg } wraps with its colours, is drawn with
--     term.blit on a colour screen, and as plain text on any other
rows = pager.wrap({ { "red words then", "eeeeeeeeeeeeee" }, "plain" }, 9)
check("a coloured line's rows keep their colours; a plain line stays a string",
    type(rows[1]) == "table" and rows[1][1] == "red words" and rows[1][2] == "eeeeeeeee"
        and rows[2][1] == "then" and rows[2][2] == "eeee" and rows[3] == "plain",
    string.format("%s/%s | %s/%s | %s", tostring(rows[1][1]), tostring(rows[1][2]),
        tostring(rows[2] and rows[2][1]), tostring(rows[2] and rows[2][2]), tostring(rows[3])))
check("blitOf: a colour's blit digit",
    pager.blitOf(16384) == "e" and pager.blitOf(1) == "0" and pager.blitOf(32768) == "f")
local coloured = {}
for i = 1, 20 do coloured[i] = i % 2 == 0 and { "red " .. i, string.rep("e", #("red " .. i)) } or ("plain " .. i) end
local blits = {}
term.isColour = function() return true end
term.blit = function(t, fg, bg) blits[#blits + 1] = t .. "/" .. fg .. "/" .. bg end
v = press(coloured)
term.isColour, term.blit = function() return false end, nil
local b = table.concat(blits, "|")
check("on a colour screen: coloured lines blitted in their colours on black, plain ones written",
    b:find("red 2/eeeee/fffff", 1, true) and not b:find("plain", 1, true) and v[1].row1 == "plain 1", b)
v = press(coloured)
check("on a plain screen: the same lines as plain text", v[1].row1 == "plain 1" and T.text(2) == "red 2")

-- 3b. what was on the screen goes up, as if scrolled off (so the console's
--     scrollback keeps the command that opened it), not drawn over
for r = 1, 13 do T.rows[r] = string.rep(" ", 39) end
T.rows[1] = string.format("%-39s", "earlier output")
T.rows[2] = string.format("%-39s", "$ more notes")
T.x, T.y, T.scrolledOff = 1, 3, {}
press(text)
check("the screen above the cursor is scrolled up before the viewer draws",
    #T.scrolledOff == 2 and T.scrolledOff[1] == "earlier output" and T.scrolledOff[2] == "$ more notes",
    table.concat(T.scrolledOff, "|"))
T.x, T.y, T.scrolledOff = 5, 1, {}
press(text)
check("a cursor partway along its row: that row goes up too", #T.scrolledOff == 1, #T.scrolledOff)

-- 4. more: files one after another in the pager (cat just copies them)
local SW = require("shellworld")
local W = SW.new(PROJ)
W:file("a.txt", "first\n")
local b = ""
for i = 1, 30 do b = b .. "b" .. i .. "\n" end
W:file("b.txt", b)
local atQ
local r = W:run("more", "a.txt", "nope", "b.txt", { events = { { "char", "G" }, { "char", "q" } },
    onPull = function(w) if #w.T.events == 1 then atQ = w.T.text(13) end end })
-- 3 header lines + "first" + 3 header lines + 30 lines = 37
check("more pages the files together, each under its name",
    W.T.text(1) == "b19" and W.T.text(12) == "b30" and atQ:find("26%-37/37") ~= nil, atQ)
check("and names a file that isn't there, exit status 1",
    r.err[1] == "more: nope: No such file or directory" and r.status == 1, r.err[1])
r = W:run("more", "a.txt")
check("a short file is just printed", r.out == "first\n" and r.status == 0, (r.out:gsub("\n", "|")))
r = W:run("more", "a.txt", "b.txt", { pipeOut = true })
check("not to the screen: copied like cat", r.out == "first\n" .. b and #r.events == 0)
r = W:run("cat", "a.txt", "nope", "b.txt")
check("cat copies the files with no paging", r.out == "first\n" .. b and r.status == 1
    and r.err[1] == "cat: nope: No such file or directory")

-- 5. help: the help pages through the pager (CraftOS's help API, a stand-in)
help = {
    lookup = function(t) return t == "git" and "/rom/help/git.txt" or nil end,
    topics = function() return { "ls", "git", "cat" } end,
}
W:file("rom/help/git.txt", "git: a small client\n")
r = W:run("help", "git")
check("help prints a page that fits", r.out == "git: a small client\n" and r.status == 0, (r.out:gsub("\n", "|")))
r = W:run("help", "nope")
check("no page: says so, status 1", r.err[1] == "help: No help available for nope" and r.status == 1, r.err[1])
r = W:run("help", "index", { pipeOut = true })
check("help index, not to the screen: the topics a line each, sorted", r.out == "cat\ngit\nls\n", (r.out:gsub("\n", "|")))
r = W:run("help", "index")
check("help index on the screen: a heading, then the topics in columns",
    r.out == "Help topics available:\ncat  git  ls\n", (r.out:gsub("\n", "|")))
help = nil
