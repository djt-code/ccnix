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
--                                 completions instead while one shows)
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

local R = {}

R.killed = ""                   -- what was cut last, for Ctrl+Y
R.lastSearch = nil              -- the last Ctrl+R text: Ctrl+R on an empty one searches it again
local pending                   -- the char of the Ctrl+letter that ended the last line, if it comes after

local LETTERS = "abcdefghijklmnopqrstuvwxyz"

--------------------------------------------------------------------------
-- Characters and words
--------------------------------------------------------------------------
local function isSpace(c) return c == " " or c == "\t" end

-- A letter or a digit: what Alt+B, Alt+F and Alt+D take as a word.
local function isWordChar(c)
    local b = c:byte()
    if not b then return false end
    return (b >= 48 and b <= 57) or (b >= 65 and b <= 90) or (b >= 97 and b <= 122)
end

-- The character at position i (1-based) of s, "" past either end.
local function at(s, i) return s:sub(i, i) end

-- Where a word back from cursor position pos starts: over what isn't a
-- word, then over the word.  (pos counts the characters before the
-- cursor, 0 to #line.)
local function wordBack(line, pos)
    while pos > 0 and not isWordChar(at(line, pos)) do pos = pos - 1 end
    while pos > 0 and isWordChar(at(line, pos)) do pos = pos - 1 end
    return pos
end

-- Where a word forward from pos ends.
local function wordForward(line, pos)
    while pos < #line and not isWordChar(at(line, pos + 1)) do pos = pos + 1 end
    while pos < #line and isWordChar(at(line, pos + 1)) do pos = pos + 1 end
    return pos
end

-- Ctrl+W's word: back over spaces, then over what isn't a space.
local function spacedWordBack(line, pos)
    while pos > 0 and isSpace(at(line, pos)) do pos = pos - 1 end
    while pos > 0 and not isSpace(at(line, pos)) do pos = pos - 1 end
    return pos
end

-- A paste's text, as typed: up to its first line break.
local function firstLine(text)
    local cut = text:find("\n", 1, true)
    if cut then text = text:sub(1, cut - 1) end
    if at(text, #text) == "\r" then text = text:sub(1, -2) end
    return text
end

--------------------------------------------------------------------------
-- The screen
--------------------------------------------------------------------------
-- e is the editor's state: line, pos (characters before the cursor),
-- scroll (characters scrolled off the left), x and y (where the line
-- starts on the screen), comps and ci (completions and the one shown),
-- search (Ctrl+R's, or nil).

local function setColour(c) if c then term.setTextColour(c) end end

-- Write the prompt, and note where the line starts after it.
local function writePrompt(e)
    if e.prompt and e.prompt ~= "" then
        if e.promptColour and term.isColour() then term.setTextColour(e.promptColour) end
        write(e.prompt)
        setColour(e.colour)
    end
    e.x, e.y = term.getCursorPos()
    local w = term.getSize()
    if e.x > w then                         -- (the prompt filled the row: the line goes on the next)
        write("\n")
        e.x, e.y = term.getCursorPos()
    end
end

-- What's drawn before the line: Ctrl+R's (search)`text': while searching.
local function lead(e)
    if not e.search then return "" end
    return "(" .. (e.search.failed and "failed " or "") .. "search)`" .. e.search.query .. "': "
end

-- Draw the line from e.x, scrolled so the cursor shows, the completion
-- after it in grey, and put the cursor there.
local function draw(e)
    local w = term.getSize()
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
    term.write(shown)
    local left = room - #shown
    local comp = e.comps and e.comps[e.ci]
    if comp and left > 0 then
        term.setTextColour(colours.lightGrey)
        local part = comp:sub(1, left)
        term.write(part)
        left = left - #part
        setColour(e.colour or colours.white)
    end
    if left > 0 then term.write(string.rep(" ", left)) end
    term.setCursorPos(x + e.pos - e.scroll, e.y)
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

local function insert(e, text)
    if text == "" then return end
    e.line = e.line:sub(1, e.pos) .. text .. e.line:sub(e.pos + 1)
    e.pos = e.pos + #text
    changed(e)
end

-- Take out the characters between positions from and to.
local function remove(e, from, to)
    if to <= from then return end
    e.line = e.line:sub(1, from) .. e.line:sub(to + 1)
    e.pos = from
    changed(e)
end

-- Cut them: kept for Ctrl+Y.
local function cut(e, from, to)
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
    changed(e)
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
        local found = e.history[k]:find(s.query, 1, true)
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

-- The letter of each letter key's code.
local function letterKeys()
    local t = {}
    for i = 1, #LETTERS do
        local l = LETTERS:sub(i, i)
        if keys[l] then t[keys[l]] = l end
    end
    return t
end

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
    local bound = (ctrl and letter and CTRL[letter]) or ((e.alt or e.meta) and letter and META[letter])
        or e.plain[code]
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
            local fn = CTRL[letter]
            return fn and fn(e)
        end
        if code == keys.leftBracket then e.swallow = "["; e.meta = true; return end
    elseif (e.alt and not e.ctrl) or e.meta then
        e.meta = false
        local fn = letter and META[letter]
        if fn then e.swallow = letter; return fn(e) end
        if code == keys.backspace then cut(e, wordBack(e.line, e.pos), e.pos); return end
    end
    local fn = e.plain[code]
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
function R.read(opts)
    opts = opts or {}
    local e = {
        line = "", pos = 0, scroll = 0, ci = 1,
        prompt = opts.prompt, promptColour = opts.promptColour,
        colour = opts.colour or (term.getTextColour and term.getTextColour()) or colours.white,
        history = opts.history or {}, complete = opts.complete,
        letters = letterKeys(), plain = plainKeys(),
        ctrl = false, alt = false, meta = false, swallow = pending,
    }
    pending = nil
    e.at = #e.history + 1
    writePrompt(e)
    setColour(e.colour)
    changed(e)
    draw(e)
    term.setCursorBlink(true)

    local why
    while not why do
        local ev = table.pack(os.pullEventRaw())
        local name = ev[1]
        if name == "key" then
            why = onKey(e, ev[2])
        elseif name == "key_up" then
            if isKey(ev[2], "leftCtrl", "rightCtrl") then e.ctrl = false
            elseif isKey(ev[2], "leftAlt", "rightAlt") then e.alt = false end
        elseif name == "char" then
            onChar(e, ev[2])
        elseif name == "paste" then
            e.swallow, e.meta = nil, false
            local text = firstLine(ev[2])
            if e.search then
                e.search.query = e.search.query .. text
                searchFrom(e, e.search.found or #e.history)
            else
                insert(e, text)
            end
        elseif name == "terminate" then
            why = "terminate"
        end
        if not why then draw(e) end
    end

    -- the line as it ends: no completion, no search, the cursor at its end
    if e.search then searchEnd(e, true) end
    e.comps = nil
    e.pos = #e.line
    draw(e)
    term.setCursorBlink(false)
    pending = e.swallow                     -- (Ctrl+C's or Ctrl+D's char may come yet)
    if why == "interrupt" then term.write("^C") end
    if why == "enter" or why == "interrupt" then print() end
    if why == "enter" then return e.line end
    return nil, why
end

return R
