-- sim/vi.lua
--
-- lib/vi.lua (vi and vim) and lib/syntax.lua on a 51 x 19 screen with
-- an in-memory disk: keys go in as CC events, written out in vi's own
-- notation ("ihello<Esc>:wq<CR>", "<C-r>"), and each check looks at the
-- file that was written or at the screen.  Esc is sent as Ctrl+[ (what a
-- player has: the real Esc closes the computer's screen), <RealEsc> as the
-- Esc key (a telnet client's).
local PROJ = ...
package.path = PROJ .. "/lib/?.lua;" .. PROJ .. "/sim/lib/?.lua;" .. package.path
local M = require("mock")
local check = M.check

-- CC:Tweaked's key codes (GLFW's)
keys = { enter = 257, tab = 258, backspace = 259, insert = 260, delete = 261, right = 262, left = 263,
    down = 264, up = 265, pageUp = 266, pageDown = 267, home = 268, ["end"] = 269, escape = 256,
    leftCtrl = 341, rightCtrl = 345, leftAlt = 342, rightAlt = 346, leftBracket = 91, numPadEnter = 335,
    space = 32 }
for i = 0, 25 do keys[string.char(97 + i)] = 65 + i end
function keys.getName(code)
    for k, v in pairs(keys) do if v == code and type(v) == "number" then return k end end
end
colours = { white = 1, orange = 2, magenta = 4, lightBlue = 8, yellow = 16, lime = 32, pink = 64, grey = 128,
    lightGrey = 256, cyan = 512, purple = 1024, blue = 2048, brown = 4096, green = 8192, red = 16384, black = 32768 }
colors = colours

-- the screen: text and colours per row
local W, H = 51, 19
local T = { rows = {}, fg = {}, colour = false, x = 1, y = 1 }
local function blank() for r = 1, H do T.rows[r] = string.rep(" ", W); T.fg[r] = string.rep("0", W) end end
blank()
local function put(s, f)
    local row = T.rows[T.y]
    if not row then return end
    local from, to = math.max(T.x, 1), math.min(T.x + #s - 1, W)
    if to >= from then
        T.rows[T.y] = row:sub(1, from - 1) .. s:sub(from - T.x + 1, to - T.x + 1) .. row:sub(to + 1)
        T.fg[T.y] = T.fg[T.y]:sub(1, from - 1) .. f:sub(from - T.x + 1, to - T.x + 1) .. T.fg[T.y]:sub(to + 1)
    end
    T.x = T.x + #s
end
term = {
    getSize = function() return W, H end,
    setCursorPos = function(x, y) T.x, T.y = x, y end,
    getCursorPos = function() return T.x, T.y end,
    setCursorBlink = function() end,
    setBackgroundColour = function() end,
    setTextColour = function() end,
    isColour = function() return T.colour end,
    clear = blank,
    clearLine = function() T.rows[T.y] = string.rep(" ", W) end,
    write = function(s) s = tostring(s); put(s, string.rep("0", #s)) end,
    blit = function(s, f, b)
        assert(#s == #f and #f == #b, "blit with strings of different lengths")
        put(s, f)
    end,
}
term.setBackgroundColor, term.setTextColor, term.isColor = term.setBackgroundColour, term.setTextColour, term.isColour
local function text(r) return (T.rows[r]:gsub("%s+$", "")) end
write = function(s) term.write(s) end

-- the disk
local files = {}
fs = {
    exists = function(p) return files[p] ~= nil end,
    isDir = function(p) return files[p] == true end,
    isReadOnly = function(p) return p:sub(1, 4) == "rom/" end,
    complete = function() return {} end,
    open = function(p, m)
        if m == "r" then
            local data = files[p]
            if type(data) ~= "string" then return nil end
            return { readAll = function() return data end, close = function() end }
        end
        if p:sub(1, 4) == "rom/" then return nil end
        local parts = {}
        return { write = function(s) parts[#parts + 1] = s end,
            close = function() files[p] = table.concat(parts) end }
    end,
}
shell = { resolve = function(p) return (p:gsub("^/", "")) end, dir = function() return "" end, run = function() end }

-- "ihello<Esc>" as events
local SPECIAL = { CR = "enter", BS = "backspace", Tab = "tab", Del = "delete", Up = "up", Down = "down",
    Left = "left", Right = "right", Home = "home", End = "end", PageUp = "pageUp", PageDown = "pageDown",
    Insert = "insert", RealEsc = "escape" }
local function events(s)
    local out = {}
    local i = 1
    while i <= #s do
        local tok = s:match("^<[%w%-]+>", i)
        if tok and #tok > 2 then
            local inner = tok:sub(2, -2)
            local ctrl = inner:match("^C%-(.)$")
            if inner == "Esc" then
                out[#out + 1] = { "key", keys.leftCtrl }
                out[#out + 1] = { "key", keys.leftBracket }
                out[#out + 1] = { "key_up", keys.leftBracket }
                out[#out + 1] = { "key_up", keys.leftCtrl }
            elseif ctrl then
                out[#out + 1] = { "key", keys.leftCtrl }
                out[#out + 1] = { "key", keys[ctrl] }
                out[#out + 1] = { "char", ctrl }          -- (in case one comes: it mustn't type)
                out[#out + 1] = { "key_up", keys[ctrl] }
                out[#out + 1] = { "key_up", keys.leftCtrl }
            elseif inner == "Paste" then
                out[#out + 1] = { "paste", "pasted\ntext" }
            elseif inner == "Term" then
                out[#out + 1] = { "terminate" }
            else
                out[#out + 1] = { "key", keys[SPECIAL[inner]] }
            end
            i = i + #tok
        else
            local c = s:sub(i, i)
            if keys[c:lower()] then out[#out + 1] = { "key", keys[c:lower()] } end
            out[#out + 1] = { "char", c }
            i = i + 1
        end
    end
    return out
end

local queue, screens = {}, {}
os.pullEventRaw = function()
    if #queue == 0 then error("no more events: the editor wanted another key", 0) end
    return table.unpack(table.remove(queue, 1))
end

-- Edit file `name` holding `content` (nil: a new file) with these keys;
-- returns what's in the file after, and the error if vi failed.
local function edit(content, keyText, opts)
    opts = opts or {}
    local name = opts.name or "t.lua"
    for k in pairs(files) do files[k] = nil end
    files[name] = content
    for k, v in pairs(opts.files or {}) do files[k] = v end
    T.colour = opts.colour or false
    queue = events(keyText)
    -- the screen as each event is waited for
    screens = {}
    local pull = os.pullEventRaw
    os.pullEventRaw = function()
        screens[#screens + 1] = { rows = { table.unpack(T.rows) }, fg = { table.unpack(T.fg) } }
        return pull()
    end
    package.loaded.vi = nil
    local ok, e = pcall(require("vi").main, opts.args or { name }, { vim = opts.vim })
    os.pullEventRaw = pull
    return files[name], (not ok) and e or nil
end
-- the bottom line of any screen shown that matches pat
local function bottomHas(pat)
    for _, s in ipairs(screens) do if s.rows[H]:find(pat) then return s.rows[H] end end
end
-- the screen before a final ":q<CR>" was typed (its four events)
local function beforeQuit() return screens[#screens - 3] end

local function show(v) return (tostring(v):gsub("\r", "\\r"):gsub("\n", "\\n")) end
local function same(label, got, want, e)
    check(label, got == want and not e, "got " .. show(got) .. ", want " .. show(want) .. (e and (" (" .. e .. ")") or ""))
end

-- 1. inserting, Esc both ways, writing
same("i, typing, Ctrl+[ as Esc, :wq writes", edit(nil, "ihello<Esc>:wq<CR>"), "hello\n")
same("the Esc key (a telnet client's) works too", edit(nil, "ihi<RealEsc>:wq<CR>"), "hi\n")
same("a, A, I, o, O", edit("b\n", "ac<Esc>Ad<Esc>Ia<Esc>oe<Esc>Ox<Esc>:wq<CR>"), "abcd\nx\ne\n")
same("3ihi: a count repeats an insert", edit("\n", "3ihi<Esc>:wq<CR>"), "hihihi\n")
same("3oab: and an o", edit("x\n", "3oab<Esc>:wq<CR>"), "x\nab\nab\nab\n")
same("Enter splits a line, Backspace joins it back", edit("abcd\n", "llia<CR>b<Esc>:wq<CR>"), "aba\nbcd\n")
same("Backspace at a line's start joins", edit("ab\ncd\n", "jI<BS><Esc>:wq<CR>"), "abcd\n")

-- 2. deleting, yanking, putting
same("dd p swaps lines", edit("a\nb\nc\n", "ddp:wq<CR>"), "b\na\nc\n")
same("2dd", edit("a\nb\nc\n", "2dd:wq<CR>"), "c\n")
same("dw, then cw changes just the word", edit("one two three\n", "dwcwTWO<Esc>:wq<CR>"), "TWO three\n")
same("dw on the last word stops at the end of the line", edit("a b\nc\n", "wdw:wq<CR>"), "a \nc\n")
same("d$ and D", edit("abc def\nxyz\n", "wDj0d$:wq<CR>"), "abc \n\n")
same("x, 3x, X", edit("abcdefg\n", "x3x$X:wq<CR>"), "eg\n")
same("yl p puts after the cursor", edit("abc\n", "ylp:wq<CR>"), "aabc\n")
same("yy P puts a line above", edit("a\nb\n", "jyyP:wq<CR>"), "a\nb\nb\n")
same('"a register: yank, delete something else, put a', edit("one\ntwo\n", '"ayyjdd"ap:wq<CR>'), "one\none\n")
same("dj deletes two lines, dG to the end", edit("1\n2\n3\n4\n5\n", "djjdG:wq<CR>"), "3\n")
same("dgg to the top", edit("1\n2\n3\n", "Gdgg:wq<CR>"), "")
same("dt, and 2f, then x", edit("a,b,c,d\n", "dt,2f,x:wq<CR>"), ",b,cd\n")
same("d% deletes to the matching bracket", edit("f(a(b)c)d\n", "ld%:wq<CR>"), "fd\n")
same("d} deletes a paragraph's lines", edit("a\nb\n\nc\n", "d}:wq<CR>"), "\nc\n")
same("cc keeps the indent", edit("    old\n", "ccnew<Esc>:wq<CR>"), "    new\n")
same("C and s", edit("abcdef\n", "lllCX<Esc>0sY<Esc>:wq<CR>"), "YbcX\n")

-- 3. the other changes
same("r, and 3r", edit("abcde\n", "rx$hh3rz:wq<CR>"), "xbzzz\n")
same("~ swaps case", edit("abc\n", "3~:wq<CR>"), "ABC\n")
same("J joins with a space, gJ without", edit("a\n   b\nc\n", "JgJ:wq<CR>"), "a bc\n")
same(">> and << shift by 4", edit("x\n    y\n", ">>j<<:wq<CR>"), "    x\ny\n")
same("Ctrl+A adds one (its char event doesn't type)", edit("x = 41\n", "<C-a>:wq<CR>"), "x = 42\n")
same("5 Ctrl+X takes five", edit("n=3\n", "5<C-x>:wq<CR>"), "n=-2\n")
same("R overtypes, Backspace brings the old text back", edit("abcdef\n", "RXYZ<BS><Esc>:wq<CR>"), "XYcdef\n")
same("autoindent: o under an indented line", edit("    if x then\n", "oy = 1<Esc>:wq<CR>"), "    if x then\n    y = 1\n")
same("an indent left empty is taken back", edit("    a\n", "o<Esc>:wq<CR>"), "    a\n\n")
same("Tab puts spaces to the next stop", edit("\n", "i<Tab>x<Esc>:wq<CR>"), "    x\n")
same("Ctrl+V pasting in insert mode", edit("\n", "i<Paste><Esc>:wq<CR>"), "pasted\ntext\n")

-- 4. undo, redo, repeat
same("u undoes one change", edit("abc\n", "xxu:wq<CR>"), "bc\n")
same("Ctrl+R redoes", edit("abc\n", "xxuu<C-r>:wq<CR>"), "bc\n")
same("an insert is undone as one", edit("a\n", "Afoo bar<Esc>u:wq<CR>"), "a\n")
same(". repeats x on the next lines", edit("a1\na2\na3\n", "xj.j.:wq<CR>"), "1\n2\n3\n")
same(". repeats dw with its count", edit("a b c d e\n", "2dw.:wq<CR>"), "e\n")
same(". repeats an insert", edit("x\ny\n", "A!<Esc>j.:wq<CR>"), "x!\ny!\n")
same(". repeats cw", edit("foo foo\n", "cwbar<Esc>w.:wq<CR>"), "bar bar\n")

-- 5. searching and ex commands
same("/pattern then D", edit("x\nfind me here\n", "/me<CR>D:wq<CR>"), "x\nfind \n")
same("n finds the next, wrapping round", edit("a\nb a\nc\n", "/a<CR>nx:wq<CR>"), "\nb a\nc\n")
same("?pattern goes back", edit("ab\nab\n", "j$?a<CR>x:wq<CR>"), "ab\nb\n")
same("* searches for the word under the cursor", edit("foo x foo\n", "*x:wq<CR>"), "foo x oo\n")
same(":%s///g", edit("foo\nboo\n", ":%s/o/0/g<CR>:wq<CR>"), "f00\nb00\n")
same(":s with groups and &", edit("ab\n", [[:s/\(a\)\(b\)/\2\1&/<CR>:wq<CR>]]), "baab\n")
same(":s with \\r splits the line", edit("a,b\n", [[:s/,/\r/<CR>:wq<CR>]]), "a\nb\n")
same(":g/pat/d", edit("keep\ndrop 1\nkeep\ndrop 2\n", ":g/drop/d<CR>:wq<CR>"), "keep\nkeep\n")
same(":v/pat/d", edit("keep\ndrop\n", ":v/keep/d<CR>:wq<CR>"), "keep\n")
same(":2,3d and :1 then dd", edit("1\n2\n3\n4\n", ":2,3d<CR>:1<CR>dd:wq<CR>"), "4\n")
same(":m and :t", edit("a\nb\nc\n", ":1m$<CR>:1t0<CR>:wq<CR>"), "b\nb\nc\na\n")
same(":m and :t past the last line are refused (E14), the text left as it was",
    edit("a\nb\n", ":1m9<CR>:1t-5<CR>:wq<CR>"), "a\nb\n")
same(":3 and 2G and G go to lines", edit("1\n2\n3\n", ":3<CR>x2GxGx:wq<CR>"), "1\n\n\n")
same("& repeats the last :s", edit("aa\naa\n", ":s/a/b/<CR>j&:wq<CR>"), "ba\nba\n")
same("marks: ma, then d'a", edit("1\n2\n3\n4\n", "jmajjd'a:wq<CR>"), "1\n")
same("+N on the command line starts there", edit("1\n2\n3\n", "x:wq<CR>", { args = { "+2", "t.lua" } }), "1\n\n3\n")
same(":r reads a file in", edit("a\n", ":r other<CR>:wq<CR>", { files = { other = "x\ny\n" } }), "a\nx\ny\n")
same(":r of a CRLF file reads its lines", edit("a\n", ":r other<CR>:wq<CR>", { files = { other = "x\r\ny\r\n" } }),
    "a\nx\ny\n")
same(":r of an empty file adds no lines (as vim)", edit("a\nb\n", ":r other<CR>:wq<CR>", { files = { other = "" } }), "a\nb\n")
same(":r keeps a CR alone at the end, as opening a file does", edit("a\n", ":r other<CR>:wq<CR>", { files = { other = "x\r" } }),
    "a\nx\r\n")
same("+ alone starts at the end", edit("1\n2\n3\n", "x:wq<CR>", { args = { "+", "t.lua" } }), "1\n2\n\n")
same(":s: \\t and \\n in the replacement", edit("a,b\n", [[:s/,/\t\n/<CR>:wq<CR>]]), "a\t\nb\n")
same(".exrc: CR LF and blank lines, blanks around a command",
    edit("\n", "i<Tab>x<Esc>:wq<CR>", { files = { ["/.exrc"] = "set noet\r\n\r\n   set ts=8   \r\n" } }), "\tx\n")
same(":wq! writes a read-only file", edit("a\n", "x:set ro<CR>:wq!<CR>"), "\n")

-- 6. files: what's kept, what's refused
same("CRLF files stay CRLF", edit("a\r\nb\r\n", "x:wq<CR>"), "\r\nb\r\n")
same("ZZ writes, :x too", edit("ab\n", "xZZ"), "b\n")
local before, e = edit("ab\n", "x:q<CR>:q!<CR>")
check(":q with changes is refused, :q! quits without writing", before == "ab\n" and not e and bottomHas("E37"), e)
local _, e2 = edit("x\n", ":w other<CR>:q<CR>", { files = { other = "keep" } })
check(":w onto a file that's there needs !", files.other == "keep" and not e2 and bottomHas("E13"), e2)
same("a new file is created on :w", edit(nil, "inew<Esc>:w<CR>:q<CR>"), "new\n")
local ro, e3 = edit("r\n", "x:w<CR>:q!<CR>", { name = "rom/x" })
check("a read-only file isn't written", ro == "r\n" and not e3 and bottomHas("E45"), e3)
same("Ctrl+T (terminate) doesn't quit", edit("a\n", "<Term>x:wq<CR>"), "\n")
same("Ctrl+C is Esc: it leaves insert mode and doesn't quit", edit("a\n", "Ab<C-c>Ac<C-c>:wq<CR>"), "abc\n")
local kept, e5 = edit("a\n", "x:wq<C-c>:q!<CR>")
check("Ctrl+C on the command line drops it", kept == "a\n" and not e5, show(kept))
edit("a\n", "<C-c>:q<CR>")
check("Ctrl+C in normal mode on a saved file says :q exits", bottomHas("^Type :q and Enter to exit") ~= nil)
edit("a\n", "x<C-c>:q!<CR>")
check("and with unsaved changes, :wq or :q!", bottomHas("^:wq saves and exits, :q! exits unsaved") ~= nil)
same("a mistake in one command doesn't stop the editor", edit("a\n", ":nonsense<CR>:s/zzz/y/<CR>x:wq<CR>"), "\n")

-- 7. the screen
edit("local x = 1\n\tindented\n", ":set nu<CR>:q<CR>")
local sc = beforeQuit()
check("line numbers with :set nu", sc and sc.rows[1]:find("^  1 local x = 1") ~= nil, sc and sc.rows[1])
check("a tab shows as spaces to the next stop", sc and sc.rows[2]:find("^  2     indented") ~= nil, sc and sc.rows[2])
check("~ past the end of the text", sc and sc.rows[3]:sub(1, 1) == "~", sc and sc.rows[3])
check("vi has no colours", sc and not sc.fg[1]:find("[^0]"), sc and sc.fg[1])
edit("local x = \"s\" -- c\n", ":q<CR>", { vim = true, colour = true })
sc = beforeQuit()
check("vim colours Lua: keyword, string, comment", sc and sc.fg[1]:sub(1, 18) == "4444400000eee0dddd", sc and sc.fg[1])
check("and the ~ lines blue", sc and sc.fg[2]:sub(1, 1) == "b", sc and sc.fg[2])
edit("#!/ccnix/bin/ccsh\necho $HOME | grep x # c\n", ":q<CR>", { vim = true, colour = true, name = "run" })
sc = beforeQuit()
check("a #! ccsh script gets the shell's colours", sc and sc.fg[2]:sub(1, 25) == "99990333330100000000ddd00", sc and sc.fg[2])
edit("local a\n", ":q<CR>", { vim = true, colour = false })
sc = beforeQuit()
check("vim on a screen without colours is plain", sc and not sc.fg[1]:find("[^0]"), sc and sc.fg[1])
edit("a\nb\n", "lll:q<CR>")
sc = beforeQuit()
check("the ruler shows line and column", sc and sc.rows[H]:find("1,1") ~= nil, sc and sc.rows[H])
edit("x\n", "i")
sc = beforeQuit()
check("-- INSERT -- shows in insert mode", bottomHas("^%-%- INSERT %-%-") ~= nil)

-- 8. syntax.lua on its own
local syntax = require("syntax")
local fg, st = syntax.line("lua", "x = [[open", nil)
local fg2, st2 = syntax.line("lua", "still]] y", st)
check("a long string carries to the next line", fg:sub(5) == "eeeeee" and fg2 == "eeeeeee00" and st2 == nil, fg .. " / " .. fg2)
fg, st = syntax.line("lua", "--[==[ c", nil)
fg2 = syntax.line("lua", "]] no ]==] end", st)
check("a long comment ends only at its own level", fg2 == "dddddddddd0444", fg2)
check("numbers: hex, exponents", syntax.line("lua", "0x1F 1e-3") == "222202222", (syntax.line("lua", "0x1F 1e-3")))
check("string.format: the library is cyan, the field isn't", syntax.line("lua", "string.format") == "9999990000000",
    (syntax.line("lua", "string.format")))
check("sh: a quoted string spans lines", select(2, syntax.line("sh", "echo 'a")) ~= nil)
check("sh: NAME=value, then a reserved word", syntax.line("sh", "X=1 if") == "330044", (syntax.line("sh", "X=1 if")))
check("detect", syntax.detect("a.lua") == "lua" and syntax.detect("x.sh") == "sh" and syntax.detect("startup") == "lua"
    and syntax.detect("run", "#!/ccnix/bin/ccsh") == "sh" and syntax.detect("notes.txt") == nil and syntax.detect(".profile") == "sh")
for _, case in ipairs({ { "ft=sh", "sh" }, { "ft=bash", "sh" }, { "ft=lua", "lua" }, { "ft=off", "" },
    { "ft=none", "" }, { "ft=on", "lua" } }) do
    edit("x\n", ":set " .. case[1] .. "<CR>:set ft?<CR>:q<CR>", { vim = true })
    local shown = bottomHas("filetype=")
    check(":set " .. case[1] .. " then ft? says " .. case[2], shown and shown:find("filetype=" .. case[2] .. " ", 1, true) ~= nil,
        shown)
end
edit("x\n", ":set ft=perl<CR>:q<CR>", { vim = true })
check(":set ft=perl: E474", bottomHas("E474") ~= nil)
check("detect: by the last name's extension, or its name", syntax.detect("/a.d/x.bash") == "sh"
    and syntax.detect("/h/.ccshrc") == "sh" and syntax.detect("a.lua.bak") == nil and syntax.detect(".lua") == nil
    and syntax.detect("/rom/programs/edit") == "lua" and syntax.detect("x.sh", "#!/bin/lua") == "lua"
    and syntax.detect("") == nil and syntax.detect(nil) == nil)
