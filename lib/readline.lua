-- readline.lua -- a line editor for a prompt: read() with a shell's keys
--
--   local readline = require("readline")
--   local line, why = readline.read(opts)
--
-- Reads a line typed at the keyboard, as read() does, with the keys of
-- a Unix shell's line editor.  opts (all optional):
--
--   prompt = text         written first (with write, so it wraps and can
--                         hold "\n"s); Ctrl+L writes it again
--   promptColour = c      its colour, on a colour screen
--   colour = c            the line's colour (else whatever was set)
--   history = { ... }     the lines typed before, oldest first (read, not
--                         changed: the caller adds the new one)
--   complete = fn(line)   Tab completion, as read()'s: a list of what
--                         could follow the line, the first one shown
--                         in grey after the cursor
--
-- Returns the line, or nil and why: "eof" (Ctrl+D on an empty line),
-- "interrupt" (Ctrl+C: "^C" is shown and a new line started) or
-- "terminate" (Ctrl+T held, the terminate event).
--
--   Left, Right, Ctrl+B, Ctrl+F   a character back / forward
--   Home, End, Ctrl+A, Ctrl+E     the start / the end of the line
--   Alt+B, Alt+F                  a word back / forward
--   Backspace, Ctrl+H             the character before the cursor out
--   Delete, Ctrl+D                the character under the cursor out
--                                 (Ctrl+D on an empty line: end of input)
--   Ctrl+K, Ctrl+U                cut to the end / to the start
--   Ctrl+W                        cut the word before (up to a space)
--   Alt+D, Alt+Backspace          cut the word after / before
--   Ctrl+Y                        put back what was cut last
--   Up, Down, Ctrl+P, Ctrl+N      the line before / after in the history
--                                 (Up and Down go through the
--                                 completions instead while one shows;
--                                 a line from the history shows none
--                                 until it's changed)
--   Ctrl+R                        search back through the history as you
--                                 type: (search)`text': shows it; Ctrl+R
--                                 again an older match, Backspace a letter
--                                 off, Enter takes the line, Ctrl+G puts
--                                 back the one there was, any other key
--                                 keeps the match and goes on editing
--   Tab                           the completion shown, added
--   Ctrl+L                        clear the screen, the line drawn again
--   Ctrl+C                        drop the line
--   Enter                         done
--
-- Keys as CraftOS sends them: Ctrl+letter is the Ctrl key's event, then
-- the letter's (and maybe its char, which is dropped).  Ctrl with Alt is
-- AltGr, typing a character, so not a binding.  A word key (Alt+B...) can
-- also be Esc and then the letter, as a telnet client sends it, or
-- Ctrl+[ and the letter.  A paste is typed in, up to its first line
-- break.  A line wider than the space after the prompt scrolls sideways
-- in it, as read()'s does.  What was cut stays for the next line's
-- Ctrl+Y.
--
--   readline.guard(t)     t, for what a shell runs: while a line is being
--                         typed, the first thing written to it takes the
--                         prompt and the line off the screen, so that a
--                         background job's output goes where they were;
--                         the editor then writes them again below it
--                         (as zsh does)
--
-- An editor, for a program with more to do than wait for the line (an
-- IRC client's input row, drawn under what comes in meanwhile):
--
--   local ed = readline.editor{ term = t, x = 1, y = h, width = w,
--       prompt = "[#ccnix] ", history = lines,
--       ctrl = { n = fn }, meta = { ["1"] = fn }, keys = { [keys.tab] = fn } }
--   local why = ed:event(table.unpack(ev))   -- each event; nil, or why the line is done
--   ed:draw()                                -- the prompt and line on row y
--   local line = ed:take()                   -- the line, and a fresh empty one
--
-- It has the same keys as read(); ctrl, meta (Alt or Esc and the key)
-- and keys (by key code) add bindings or replace them: each is
-- fn(ed), returning nil to go on or why the line is done (any string:
-- event() returns it).  Ctrl and Alt bindings take letters and digits.
-- The prompt is drawn on row y from x, and the line scrolls sideways in
-- what's left of width.  ed.line and ed.pos are the line and how many
-- characters are before the cursor; ed:set(line [, pos]) replaces it,
-- ed:insert(text) types at the cursor, ed:cursor() is where the cursor
-- belongs (to put it back after drawing elsewhere), ed.prompt can be
-- changed (then draw).  Ctrl+L and Ctrl+C are a program's to bind:
-- unbound, Ctrl+L does nothing and Ctrl+C returns "interrupt".

local scan = require("scan")
local text = require("text")

local R = {}

R.killed = ""                   -- what was cut last, for Ctrl+Y
R.lastSearch = nil              -- the last Ctrl+R text: Ctrl+R on an empty one searches it again
local pending                   -- the char of the Ctrl+letter that ended the last line, if it comes after

local LETTERS = "abcdefghijklmnopqrstuvwxyz"

--------------------------------------------------------------------------
-- Characters and words
--------------------------------------------------------------------------
-- (A word for Alt+B, Alt+F and Alt+D: letters and digits, scan.isAlnum;
-- Ctrl+W's: what isn't a blank, scan.isSpace.)

-- The character at position i (1-based) of s, "" past either end.
local function at(s, i) return s:sub(i, i) end

-- Where a word back from cursor position pos starts: over what isn't a
-- word, then over the word.  (pos counts the characters before the
-- cursor, 0 to #line.)
local function wordBack(line, pos)
    while pos > 0 and not scan.isAlnum(at(line, pos)) do pos = pos - 1 end
    while pos > 0 and scan.isAlnum(at(line, pos)) do pos = pos - 1 end
    return pos
end

-- Where a word forward from pos ends.
local function wordForward(line, pos)
    while pos < #line and not scan.isAlnum(at(line, pos + 1)) do pos = pos + 1 end
    while pos < #line and scan.isAlnum(at(line, pos + 1)) do pos = pos + 1 end
    return pos
end

-- Ctrl+W's word: back over spaces, then over what isn't a space.
local function spacedWordBack(line, pos)
    while pos > 0 and scan.isSpace(at(line, pos)) do pos = pos - 1 end
    while pos > 0 and not scan.isSpace(at(line, pos)) do pos = pos - 1 end
    return pos
end

-- A paste's text, as typed: up to its first line break.
local function firstLine(s)
    local first = text.cut(s, "\n")
    return text.stripSuffix(first, "\r") or first
end

--------------------------------------------------------------------------
-- The screen
--------------------------------------------------------------------------
-- e is the editor's state: line, pos (characters before the cursor),
-- scroll (characters scrolled off the left), x and y (where the line
-- starts on the screen), comps and ci (completions and the one shown),
-- search (Ctrl+R's, or nil).

local function setColour(c) if c then term.setTextColour(c) end end

-- Write the prompt, and note where the line starts after it, and the
-- row the prompt starts on (top: a "\n" in it, or a full row, makes it
-- more than one).
local function writePrompt(e)
    local rows = 1
    if e.prompt and e.prompt ~= "" then
        if e.promptColour and term.isColour() then term.setTextColour(e.promptColour) end
        write(e.prompt)
        setColour(e.colour)
        rows = rows + text.count(e.prompt, "\n")
    end
    e.x, e.y = term.getCursorPos()
    local w = term.getSize()
    if e.x > w then                         -- (the prompt filled the row: the line goes on the next)
        write("\n")
        e.x, e.y = term.getCursorPos()
        rows = rows + 1
    end
    e.top = math.max(1, e.y - rows + 1)
end

-- What's drawn before the line: Ctrl+R's (search)`text': while searching.
local function lead(e)
    if not e.search then return "" end
    return "(" .. (e.search.failed and "failed " or "") .. "search)`" .. e.search.query .. "': "
end

-- An editor's prompt, on its row from its x: where the line then starts.
local function drawRegionPrompt(e)
    local t = e.term
    local prompt = (e.prompt or ""):sub(1, math.max(0, e.width - 2))
    t.setCursorPos(e.left, e.y)
    if prompt ~= "" then
        if e.promptColour and t.isColour() then t.setTextColour(e.promptColour) end
        t.write(prompt)
    end
    t.setTextColour(e.colour or colours.white)
    e.x = e.left + #prompt
end

-- Write s, a control character in it as its letter reversed (Ctrl+B's
-- \2 as a reversed B, as irssi shows IRC's formatting codes), one cell
-- each as any character is.
local function writeShown(t, s, colour)
    colour = colour or colours.white
    local from = 1
    for i = 1, #s do
        local b = s:byte(i)
        if b < 32 then
            if i > from then t.write(s:sub(from, i - 1)) end
            local bg = t.getBackgroundColour and t.getBackgroundColour() or colours.black
            t.setBackgroundColour(colour)
            t.setTextColour(bg)
            t.write(string.char(b + 64))
            t.setBackgroundColour(bg)
            t.setTextColour(colour)
            from = i + 1
        end
    end
    if from <= #s then t.write(s:sub(from)) end
end

-- Draw the line from e.x, scrolled so the cursor shows, the completion
-- after it in grey, and put the cursor there.
local function draw(e)
    local term = e.term or term
    local w = term.getSize()
    if e.region then
        drawRegionPrompt(e)
        w = e.left + e.width - 1
    end
    local before = lead(e)
    local x = math.min(e.x + #before, w)
    local room = math.max(1, w - x + 1)    -- the columns the line has
    -- as much of the line as fits, then the cursor in view
    local most = math.max(0, #e.line + 1 - room)
    if e.scroll > most then e.scroll = most end
    if e.pos < e.scroll then e.scroll = e.pos end
    if e.pos - e.scroll > room - 1 then e.scroll = e.pos - room + 1 end

    term.setCursorPos(e.x, e.y)
    if before ~= "" then term.write(before:sub(1, x - e.x)) end
    term.setCursorPos(x, e.y)
    local shown = e.line:sub(e.scroll + 1, e.scroll + room)
    writeShown(term, shown, e.colour)
    local left = room - #shown
    local comp = e.comps and e.comps[e.ci]
    if comp and left > 0 then
        term.setTextColour(colours.lightGrey)
        local part = comp:sub(1, left)
        term.write(part)
        left = left - #part
        term.setTextColour(e.colour or colours.white)
    end
    if left > 0 then term.write(string.rep(" ", left)) end
    e.restX, e.restY = x + e.pos - e.scroll, e.y
    term.setCursorPos(e.restX, e.restY)
end

--------------------------------------------------------------------------
-- Output from elsewhere while a line is typed
--------------------------------------------------------------------------
-- What a background job prints shouldn't land in the middle of the line
-- being typed.  While R.read waits, `showing` is its state (the prompt's
-- rows, top to y, and where it left the cursor, restX and restY).  A
-- terminal made by R.guard clears those rows before the first thing
-- written to it, so the output goes where the prompt was; the editor
-- notices (e.cleared, and a REDRAW event to wake it) and writes the
-- prompt and the line again below the output, as zsh does.
local showing
local REDRAW = "readline_redraw"

local function takePromptOff(t)
    local e = showing
    if not e or e.cleared then return end
    local x, y = t.getCursorPos()
    if x ~= e.restX or y ~= e.restY then return end     -- (the writer moved the cursor itself: let it be)
    for row = e.top, e.y do
        t.setCursorPos(1, row)
        t.clearLine()
    end
    t.setCursorPos(1, e.top)
    e.cleared = true
    os.queueEvent(REDRAW)
end

-- A terminal that is t, but takes the line being typed off the screen
-- before anything is written to it.  For the commands a shell runs.  t's
-- methods are its own keys too, not only through __index: CraftOS's
-- textutils.pagedPrint copies the terminal with pairs() and redirects to
-- the copy, which has to have them all.
function R.guard(t)
    local g = setmetatable({}, { __index = t })
    for k, v in pairs(t) do g[k] = v end
    for _, name in ipairs({ "write", "blit", "clear", "clearLine", "scroll" }) do
        local f = t[name]
        if f then
            g[name] = function(...)
                takePromptOff(t)
                return f(...)
            end
        end
    end
    return g
end

-- After output took the prompt off: it again, on a line of its own.
local function reprompt(e)
    local x = term.getCursorPos()
    if x ~= 1 then print() end               -- (output that didn't end its line)
    writePrompt(e)
    setColour(e.colour)
    e.cleared = false
end

--------------------------------------------------------------------------
-- Editing
--------------------------------------------------------------------------
-- The line changed or the cursor moved: the completions again (only
-- with the cursor at the end, as read() has them).
local function changed(e)
    e.comps, e.ci = nil, 1
    if e.complete and not e.search and e.pos == #e.line then
        local got = e.complete(e.line)
        if type(got) == "table" and #got > 0 then e.comps = got end
    end
end

local function moveTo(e, pos)
    e.pos = math.max(0, math.min(#e.line, pos))
    changed(e)
end

local function insert(e, s)
    if s == "" then return end
    e.line = e.line:sub(1, e.pos) .. s .. e.line:sub(e.pos + 1)
    e.pos = e.pos + #s
    changed(e)
end

-- Take out the characters between positions from and to (kept inside the
-- line: Backspace at its start asks for -1, and line:sub(1, -1) would be
-- the whole line, not none of it).
local function remove(e, from, to)
    from, to = math.max(0, from), math.min(#e.line, to)
    if to <= from then return end
    e.line = e.line:sub(1, from) .. e.line:sub(to + 1)
    e.pos = from
    changed(e)
end

-- Cut them: kept for Ctrl+Y.
local function cut(e, from, to)
    from, to = math.max(0, from), math.min(#e.line, to)
    if to <= from then return end
    R.killed = e.line:sub(from + 1, to)
    remove(e, from, to)
end

-- History line i (#history + 1: the line being typed, kept as it was).
local function historyTo(e, i)
    local n = #e.history
    if i < 1 or i > n + 1 or i == e.at then return end
    if e.at == n + 1 then e.typed = e.line end
    e.at = i
    e.line = (i == n + 1) and (e.typed or "") or e.history[i]
    e.pos, e.scroll = #e.line, 0
    e.comps, e.ci = nil, 1              -- (none for a line from the history, so Up and Down go on through it)
end

-- Up or Down: through the completions while there are some, else the
-- history.
local function upDown(e, step)
    if e.comps then
        e.ci = (e.ci - 1 + step) % #e.comps + 1
    else
        historyTo(e, e.at + step)
    end
end

--------------------------------------------------------------------------
-- Ctrl+R
--------------------------------------------------------------------------
-- The newest history line from i back that holds the search text: the
-- line shown, the cursor at the match.  None: the search failed, the
-- line stays.
local function searchFrom(e, i)
    local s = e.search
    if s.query == "" then s.failed = false; return end
    for k = math.min(i, #e.history), 1, -1 do
        local found = text.find(e.history[k], s.query)
        if found then
            s.found, s.failed = k, false
            e.line, e.pos = e.history[k], found - 1
            return
        end
    end
    s.failed = true
end

local function searchStart(e)
    e.search = { query = "", line = e.line, pos = e.pos }
    e.comps = nil
end

-- Ctrl+R while searching: an older match (or the last search again).
local function searchOlder(e)
    local s = e.search
    if s.query == "" then
        if not R.lastSearch then return end
        s.query = R.lastSearch
        searchFrom(e, #e.history)
    else
        searchFrom(e, (s.found or #e.history + 1) - 1)
    end
end

-- Leave the search with the line it found (keep) or the one there was.
local function searchEnd(e, keep)
    local s = e.search
    e.search = nil
    if s.query ~= "" then R.lastSearch = s.query end
    if keep and s.found and not s.failed then
        if e.at == #e.history + 1 then e.typed = s.line end
        e.at = s.found
    elseif not keep then
        e.line, e.pos = s.line, s.pos
    end
    changed(e)
end

--------------------------------------------------------------------------
-- The keys
--------------------------------------------------------------------------
-- Each returns why the line is done ("enter", "eof", "interrupt"), or
-- nil to go on.
local CTRL = {
    a = function(e) moveTo(e, 0) end,
    e = function(e) moveTo(e, #e.line) end,
    b = function(e) moveTo(e, e.pos - 1) end,
    f = function(e) moveTo(e, e.pos + 1) end,
    h = function(e) remove(e, e.pos - 1, e.pos) end,
    d = function(e)
        if e.line == "" then return "eof" end
        remove(e, e.pos, e.pos + 1)
    end,
    k = function(e) cut(e, e.pos, #e.line) end,
    u = function(e) cut(e, 0, e.pos) end,
    w = function(e) cut(e, spacedWordBack(e.line, e.pos), e.pos) end,
    y = function(e) insert(e, R.killed) end,
    p = function(e) historyTo(e, e.at - 1) end,
    n = function(e) historyTo(e, e.at + 1) end,
    r = function(e) searchStart(e) end,
    l = function(e)
        if e.region then return end         -- (an editor's program draws the screen)
        term.clear()
        term.setCursorPos(1, 1)
        writePrompt(e)
    end,
    c = function() return "interrupt" end,
}

-- Alt+letter, or Esc then the letter
local META = {
    b = function(e) moveTo(e, wordBack(e.line, e.pos)) end,
    f = function(e) moveTo(e, wordForward(e.line, e.pos)) end,
    d = function(e) cut(e, e.pos, wordForward(e.line, e.pos)) end,
}

-- The keys that need no Ctrl, by key code.
local function plainKeys()
    local t = {}
    local function bind(name, fn) if keys[name] then t[keys[name]] = fn end end
    bind("left", CTRL.b)
    bind("right", CTRL.f)
    bind("home", CTRL.a)
    bind("end", CTRL.e)
    bind("backspace", CTRL.h)
    bind("delete", function(e) remove(e, e.pos, e.pos + 1) end)
    bind("up", function(e) upDown(e, -1) end)
    bind("down", function(e) upDown(e, 1) end)
    bind("tab", function(e)
        local comp = e.comps and e.comps[e.ci]
        if comp then insert(e, comp) end
    end)
    bind("enter", function() return "enter" end)
    bind("numPadEnter", function() return "enter" end)
    bind("escape", function(e) e.meta = true end)
    return t
end

-- The letter of each letter key's code, and the digit of each digit key's
-- (for a program's Alt+1...).
local DIGIT_KEYS = { "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine" }
local function letterKeys()
    local t = {}
    for i = 1, #LETTERS do
        local l = LETTERS:sub(i, i)
        if keys[l] then t[keys[l]] = l end
    end
    for i, name in ipairs(DIGIT_KEYS) do
        if keys[name] then t[keys[name]] = tostring(i - 1) end
    end
    return t
end

-- What a Ctrl+key, Alt+key or plain key is bound to: the program's
-- binding, else the editor's own.
local function ctrlBinding(e, letter) return (e.ctrlBinds and e.ctrlBinds[letter]) or CTRL[letter] end
local function metaBinding(e, letter) return (e.metaBinds and e.metaBinds[letter]) or META[letter] end
local function keyBinding(e, code) return (e.keyBinds and e.keyBinds[code]) or e.plain[code] end

local function isKey(code, a, b) return code ~= nil and (code == keys[a] or code == keys[b]) end

-- A key while Ctrl+R searches: true if the search took it, else the
-- search ends (keeping its line) and the key goes on as usual.  A key
-- with nothing bound to it (a letter's, Shift) stays in the search: its
-- char is what's typed.
local function searchKey(e, code, letter)
    local ctrl = e.ctrl and not e.alt
    if ctrl and letter == "r" then searchOlder(e); return true end
    if ctrl and letter == "g" then searchEnd(e, false); return true end
    if code == keys.backspace or (ctrl and letter == "h") then
        local s = e.search
        if s.query ~= "" then
            s.query = s.query:sub(1, -2)
            searchFrom(e, #e.history)
        end
        return true
    end
    local bound = (ctrl and letter and ctrlBinding(e, letter)) or ((e.alt or e.meta) and letter and metaBinding(e, letter))
        or keyBinding(e, code)
    if not bound then return true end
    searchEnd(e, true)
    return false
end

-- A key went down.
local function onKey(e, code)
    if isKey(code, "leftCtrl", "rightCtrl") then e.ctrl = true; return end
    if isKey(code, "leftAlt", "rightAlt") then e.alt = true; return end
    e.swallow = nil
    local letter = e.letters[code]
    if e.search then
        if letter and e.ctrl and not e.alt then e.swallow = letter end
        if searchKey(e, code, letter) then return end
    end
    if e.ctrl and not e.alt then
        if letter then
            e.swallow = letter                  -- (its char, if one comes, isn't typed)
            e.meta = false
            local fn = ctrlBinding(e, letter)
            return fn and fn(e)
        end
        if code == keys.leftBracket then e.swallow = "["; e.meta = true; return end
    elseif (e.alt and not e.ctrl) or e.meta then
        e.meta = false
        local fn = letter and metaBinding(e, letter)
        if fn then e.swallow = letter; return fn(e) end
        if code == keys.backspace then cut(e, wordBack(e.line, e.pos), e.pos); return end
    end
    local fn = keyBinding(e, code)
    if fn then return fn(e) end
end

-- A character typed.
local function onChar(e, c)
    local s = e.swallow
    e.swallow = nil
    if s and c:lower() == s then return end
    e.meta = false
    if e.search then
        e.search.query = e.search.query .. c
        searchFrom(e, e.search.found or #e.history)
        return
    end
    insert(e, c)
end

--------------------------------------------------------------------------
-- Reading a line
--------------------------------------------------------------------------
-- A new editor's state, from read()'s or editor()'s opts.
local function newState(opts)
    local e = {
        line = "", pos = 0, scroll = 0, ci = 1,
        prompt = opts.prompt, promptColour = opts.promptColour,
        history = opts.history or {}, complete = opts.complete,
        letters = letterKeys(), plain = plainKeys(),
        ctrlBinds = opts.ctrl, metaBinds = opts.meta, keyBinds = opts.keys,
        ctrl = false, alt = false, meta = false,
    }
    e.at = #e.history + 1
    return e
end

-- One event: why the line is done, or nil.
local function onEvent(e, name, a)
    if name == "key" then
        return onKey(e, a)
    elseif name == "key_up" then
        if isKey(a, "leftCtrl", "rightCtrl") then e.ctrl = false
        elseif isKey(a, "leftAlt", "rightAlt") then e.alt = false end
    elseif name == "char" then
        onChar(e, a)
    elseif name == "paste" then
        e.swallow, e.meta = nil, false
        local pasted = firstLine(a)
        if e.search then
            e.search.query = e.search.query .. pasted
            searchFrom(e, e.search.found or #e.history)
        else
            insert(e, pasted)
        end
    elseif name == "terminate" then
        return "terminate"
    end
end

-- The line as it ends: no completion, no search, the cursor at its end.
local function finish(e)
    if e.search then searchEnd(e, true) end
    e.comps = nil
    e.pos = #e.line
end

function R.read(opts)
    opts = opts or {}
    local e = newState(opts)
    e.colour = opts.colour or (term.getTextColour and term.getTextColour()) or colours.white
    e.swallow = pending
    pending = nil
    writePrompt(e)
    setColour(e.colour)
    changed(e)
    draw(e)
    term.setCursorBlink(true)
    local outer = showing
    showing = e

    local why
    while not why do
        local ev = table.pack(os.pullEventRaw())
        if e.cleared then reprompt(e) end
        why = onEvent(e, ev[1], ev[2])
        if not why then draw(e) end
    end

    showing = outer
    if e.cleared then reprompt(e) end
    finish(e)
    draw(e)
    term.setCursorBlink(false)
    pending = e.swallow                     -- (Ctrl+C's or Ctrl+D's char may come yet)
    if why == "interrupt" then term.write("^C") end
    if why == "enter" or why == "interrupt" then print() end
    if why == "enter" then return e.line end
    return nil, why
end

--------------------------------------------------------------------------
-- An editor: a line edited an event at a time (see the top)
--------------------------------------------------------------------------
local Editor = {}
Editor.__index = Editor

function R.editor(opts)
    opts = opts or {}
    local e = newState(opts)
    e.term = opts.term or term.current()
    local w = e.term.getSize()
    e.region = true
    e.left, e.y = opts.x or 1, opts.y or 1
    e.width = opts.width or (w - e.left + 1)
    e.colour = opts.colour or colours.white
    e.x = e.left
    changed(e)
    return setmetatable(e, Editor)
end

function Editor:event(name, a) return onEvent(self, name, a) end
function Editor:draw() draw(self) end
function Editor:cursor() return self.restX or self.left, self.y end

-- Move it: a new row, x and width (the screen was resized, say).
function Editor:place(x, y, width)
    self.left, self.y, self.width = x, y, width
end

function Editor:set(line, pos)
    self.line = line
    self.pos = math.max(0, math.min(#line, pos or #line))
    changed(self)
end

function Editor:insert(text) insert(self, text) end

-- The line typed, and a fresh one; the history position starts again
-- after the newest line (add the taken one to the history first if it
-- should be there).
function Editor:take()
    finish(self)
    local line = self.line
    self.line, self.pos, self.scroll = "", 0, 0
    self.typed = nil
    self.at = #self.history + 1
    changed(self)
    return line
end

return R
