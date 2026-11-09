-- screen.lua -- sessions of windows that outlive the terminal they started on (bin/screen)
--
--   local screen = require("screen")
--   local s = screen.newSession(proc, { name = "main", w = 51, h = 18, cmd = nil })
--   local d = screen.display(s, term.current(), proc)  -- show it here
--   d:event(table.unpack(ev))     -- nil, or "detach" / "gone" when it's over here
--   d:draw()                      -- what changed, onto this screen
--   screen.sessions(), screen.find(name), screen.reap()
--
-- A session is a few windows, each a shell (or a command) that init runs
-- as a process leading a session of its own, on a terminal of its own
-- (proc.newTerm, out of sight) and a tty of its own ("scr/main.0"), so
-- it doesn't end when the terminal that started it goes: a telnet
-- connection dropping, or detaching.  The sessions are kept where every
-- program on this computer finds them (_G.ccnixScreens), so `screen -r`
-- from another shell, or another telnet connection, picks one up again.
--
-- A display is a session shown on a terminal: it copies the current
-- window's rows there as they change, and a status bar under them (the
-- windows, the session's name, the time), and passes what's typed to
-- the window (proc.input to its tty: what's in front there gets it, as
-- on the console).  Several displays can show one session (screen -x):
-- each draws it, and what any of them types goes to the window.  The
-- windows take the size of the display that attached last.
--
-- The command key is Ctrl+A (screen.prefix sets another letter), then:
--   c       a new window             n, space   the next window
--   p       the window before        0-9        window 0-9
--   "  w    the windows, listed      A          name this window
--   k       kill this window (y to be sure)
--   d       detach (the windows go on; screen -r brings them back)
--   [       the scrollback: PgUp/PgDn, Up/Down, the wheel; q or Esc leaves
--   a       a Ctrl+A for the window  t          a Ctrl+T for the window
--   l       draw it again            ?          these keys
-- Ctrl+T on the display (or a hangup: the telnet connection going) detaches.
-- Shift+PgUp is the scrollback too.  A window whose command ends closes;
-- the session ends with its last window.

local scan = require("scan")
local readline = require("readline")

local M = {}
M.HISTORY = 500             -- rows each window keeps of what scrolled off its top
M.MESSAGE_TIME = 2          -- seconds a message stays on the status bar

-- The sessions, shared by every program on this computer.
function M.registry()
    local r = rawget(_G, "ccnixScreens")
    if not r then
        r = { sessions = {}, next = 0 }
        rawset(_G, "ccnixScreens", r)
    end
    return r
end

function M.sessions()
    local r = M.registry()
    local out = {}
    for _, s in pairs(r.sessions) do out[#out + 1] = s end
    table.sort(out, function(a, b) return a.created < b.created end)
    return out
end

function M.find(name) return M.registry().sessions[name] end

local Session = {}
Session.__index = Session

-- What ccnix logs in to: ccsh if ccsh.login is on (as telnetd has it),
-- else the CraftOS shell (nil).
local function loginShell()
    if not (settings and settings.get("ccsh.login")) then return nil end
    local path = ccnix and ccnix.find and ccnix.find("bin/ccsh.lua")
    if not path then return nil end
    return scan.endsWith(path, ".lua") and path:sub(1, -5) or path
end

function M.newSession(proc, opts)
    local r = M.registry()
    local name = opts.name
    if not name then
        name = tostring(r.next)
        r.next = r.next + 1
    end
    local s = setmetatable({ name = name, windows = {}, proc = proc, w = opts.w or 51, h = opts.h or 18,
        created = opts.clock and opts.clock() or os.clock(), displays = {}, clock = opts.clock or os.clock }, Session)
    r.sessions[name] = s
    s:newWindow(opts.cmd)
    return s
end

-- Keep what scrolls off the top of a window's terminal.
local function keepHistory(win)
    local t = win.term
    local scroll = t.scroll
    t.scroll = function(n)
        for row = 1, math.min(n, select(2, t.getSize())) do
            local text, fg, bg = t.getLine(row)
            win.hist[#win.hist + 1] = { text, fg, bg }
            if #win.hist > M.HISTORY then table.remove(win.hist, 1) end
        end
        return scroll(n)
    end
end

-- The lowest window number not in use.
function Session:freeNumber()
    local used = {}
    for _, w in ipairs(self.windows) do used[w.n] = true end
    local n = 0
    while used[n] do n = n + 1 end
    return n
end

function Session:newWindow(cmd, name)
    local proc = self.proc
    local n = self:freeNumber()
    local win = { n = n, name = name, cmd = cmd, hist = {}, tty = "scr/" .. self.name .. "." .. n }
    win.term = proc.newTerm(self.w, self.h, true)
    keepHistory(win)
    win.pid = proc.spawn({ cmd = cmd or loginShell(), term = win.term, tty = win.tty, session = true,
        onExit = function() win.dead = true end })
    self.windows[#self.windows + 1] = win
    table.sort(self.windows, function(a, b) return a.n < b.n end)
    self.previous = self.current
    self.current = win
    return win
end

function Session:window(n)
    for _, w in ipairs(self.windows) do if w.n == n then return w end end
    return nil
end

function Session:index(win)
    for i, w in ipairs(self.windows) do if w == win then return i end end
    return nil
end

function Session:select(win)
    if not win or win == self.current then return end
    self.previous = self.current
    self.current = win
end

-- The next (step 1) or previous (-1) window.
function Session:step(step)
    local i = self:index(self.current) or 1
    self:select(self.windows[(i - 1 + step) % #self.windows + 1])
end

function Session:kill(win)
    if win and not win.dead then self.proc.kill(win.pid, "TERM") end
end

-- A window's title: its name if it has one, else what runs in front on
-- its tty (the newest process there), else "shell".
function Session:title(win)
    if win.name then return win.name end
    local newest
    for _, p in ipairs(self.proc.list()) do
        if p.tty == win.tty and (not newest or p.pid > newest.pid) then newest = p end
    end
    return newest and newest.name or "shell"
end

-- The windows a new size, each told (term_resize) as a terminal is.
function Session:resize(w, h)
    if w == self.w and h == self.h then return end
    self.w, self.h = w, h
    for _, win in ipairs(self.windows) do
        win.term.reposition(1, 1, w, h)
        self.proc.input(win.tty, "term_resize")
    end
end

-- Take away the windows that ended; the session goes with its last one.
-- True if it's still there.
function Session:sweep()
    local alive = {}
    for _, w in ipairs(self.windows) do if not w.dead then alive[#alive + 1] = w end end
    self.windows = alive
    if self.current and self.current.dead then
        self.current = (self.previous and not self.previous.dead) and self.previous or alive[1]
    end
    if self.previous and self.previous.dead then self.previous = nil end
    if #alive == 0 then
        M.registry().sessions[self.name] = nil
        return false
    end
    return true
end

-- Is a display (by its process) still showing this session?
function Session:attached()
    local live = {}
    for _, p in ipairs(self.proc.list()) do live[p.pid] = true end
    local n = 0
    for pid in pairs(self.displays) do
        if live[pid] then n = n + 1 else self.displays[pid] = nil end
    end
    return n
end

function M.reap()
    for _, s in ipairs(M.sessions()) do s:sweep() end
end

--------------------------------------------------------------------------
-- A display
--------------------------------------------------------------------------
local Display = {}
Display.__index = Display

local HELP = {
    "screen's keys: Ctrl+A, then",
    "  c  a new window         n, space  the next",
    "  p  the one before       0-9       window 0-9",
    "  \"  the windows          A         name this one",
    "  k  kill this one        d         detach",
    "  [  the scrollback       l         draw it again",
    "  a  a Ctrl+A for it      t         a Ctrl+T for it",
    "Ctrl+T detaches too.  A key: back.",
}

function M.display(session, native, proc, opts)
    opts = opts or {}
    local d = setmetatable({ s = session, t = native, proc = proc, last = {}, prefix = opts.prefix or "a",
        status = opts.status ~= false, pid = opts.pid or (proc.self and proc.self()) or 0, clock = session.clock }, Display)
    session.displays[d.pid] = true
    d:fit()
    return d
end

-- The windows sized to this display (less the status bar).
function Display:fit()
    local w, h = self.t.getSize()
    self.w, self.h = w, h
    self.s:resize(w, self.status and h - 1 or h)
    self.last = {}
end

function Display:message(text)
    self.msg, self.msgUntil = text, self.clock() + M.MESSAGE_TIME
end

function Display:detach()
    self.s.displays[self.pid] = nil
end

-- The status bar: the windows (* the current, - the one before), then
-- the session's name and the time at the right.
function Display:statusText()
    if self.msg and self.clock() < self.msgUntil then return " " .. self.msg end
    local s = self.s
    local parts = {}
    for _, win in ipairs(s.windows) do
        local mark = (win == s.current and "*") or (win == s.previous and "-") or " "
        parts[#parts + 1] = win.n .. mark .. s:title(win)
    end
    local left = " " .. table.concat(parts, "  ")
    local right = "[" .. s.name .. "] " .. (os.date and os.date("%H:%M") or "") .. " "
    local room = self.w - #right
    if #left > room then left = left:sub(1, math.max(0, room - 1)) .. ">" end
    return left .. (" "):rep(math.max(0, room - #left)) .. right
end

function Display:drawStatus()
    if not self.status then return end
    local text = self:statusText()
    text = (text .. (" "):rep(self.w)):sub(1, self.w)
    local fg, bg = ("f"):rep(self.w), ("d"):rep(self.w)
    -- the current window's name, white behind it
    local s = self.s
    if not (self.msg and self.clock() < self.msgUntil) and s.current then
        local key = s.current.n .. "*"
        local at = text:find(key, 1, true)
        if at then
            local len = #key + #s:title(s.current)
            bg = bg:sub(1, at - 1) .. ("0"):rep(len) .. bg:sub(at + len)
            bg = bg:sub(1, self.w)
        end
    end
    self.t.setCursorPos(1, self.h)
    self.t.blit(text, fg, bg)
end

-- Rows from the window's scrollback and screen, `back` rows up.
function Display:drawBack()
    local win = self.s.current
    local rows = self.status and self.h - 1 or self.h
    local hist = win.hist
    self.back = math.max(0, math.min(self.back, #hist))
    for r = 1, rows do
        local i = #hist + r - self.back
        local text, fg, bg
        if i <= #hist then text, fg, bg = hist[i][1], hist[i][2], hist[i][3]
        else text, fg, bg = win.term.getLine(i - #hist) end
        if #text ~= self.w then
            text = (text .. (" "):rep(self.w)):sub(1, self.w)
            fg = (fg .. ("0"):rep(self.w)):sub(1, self.w)
            bg = (bg .. ("f"):rep(self.w)):sub(1, self.w)
        end
        self.t.setCursorPos(1, r)
        self.t.blit(text, fg, bg)
    end
    self.last = {}
end

function Display:drawHelp()
    local t = self.t
    t.setBackgroundColour(colours.black)
    t.setTextColour(colours.white)
    t.clear()
    for i, line in ipairs(HELP) do
        t.setCursorPos(1, i)
        t.write(line:sub(1, self.w))
    end
    self.last = {}
end

-- What changed in the window, onto this screen; the cursor where the
-- window has it.
function Display:draw()
    local s, t = self.s, self.t
    local w, h = t.getSize()
    if w ~= self.w or h ~= self.h then self:fit() end
    t.setCursorBlink(false)
    if self.mode == "help" then return self:drawHelp() end
    local win = s.current
    if not win then return end
    if self.mode == "back" then
        self:drawBack()
        self:message("scrollback: " .. self.back .. " up; PgUp/PgDn, q leaves")
        self:drawStatus()
        return
    end
    if self.shown ~= win then self.shown, self.last = win, {} end
    local rows = self.status and h - 1 or h
    for r = 1, rows do
        local text, fg, bg = win.term.getLine(r)
        local prev = self.last[r]
        if text and not (prev and prev[1] == text and prev[2] == fg and prev[3] == bg) then
            t.setCursorPos(1, r)
            t.blit(text, fg, bg)
            self.last[r] = { text, fg, bg }
        end
    end
    self:drawStatus()
    if self.prompt then
        self.prompt:draw()
        t.setCursorPos(self.prompt:cursor())
        t.setCursorBlink(true)
        return
    end
    local x, y = win.term.getCursorPos()
    t.setTextColour(win.term.getTextColour())
    t.setCursorPos(x, y)
    t.setCursorBlink(win.term.getCursorBlink())
end

-- Send a Ctrl+letter to the window, as a keyboard would.
function Display:sendCtrl(letter)
    local tty = self.s.current.tty
    self.proc.input(tty, "key", keys.leftCtrl, false)
    self.proc.input(tty, "key", keys[letter], false)
    self.proc.input(tty, "key_up", keys[letter])
    self.proc.input(tty, "key_up", keys.leftCtrl)
end

-- The command after Ctrl+A: the character typed.
function Display:command(c)
    local s = self.s
    if c == "c" then
        s:newWindow(nil)
        self:message("window " .. s.current.n)
    elseif c == "n" or c == " " then s:step(1)
    elseif c == "p" then s:step(-1)
    elseif scan.isDigit(c) then
        local win = s:window(tonumber(c))
        if win then s:select(win) else self:message("no window " .. c) end
    elseif c == "\"" or c == "w" then
        local list = {}
        for _, win in ipairs(s.windows) do list[#list + 1] = win.n .. (win == s.current and "*" or " ") .. s:title(win) end
        self:message(table.concat(list, "  "))
    elseif c == "k" then
        self.confirm = "kill"
        self:message("kill window " .. s.current.n .. " (" .. s:title(s.current) .. ")? y/n")
    elseif c == "d" then
        return "detach"
    elseif c == "[" then
        self.mode, self.back = "back", 0
    elseif c == "a" or c == self.prefix then
        self:sendCtrl(self.prefix)
    elseif c == "t" then
        self.proc.input(s.current.tty, "terminate")
    elseif c == "l" then
        self.last = {}
        self.t.clear()
    elseif c == "?" then
        self.mode = "help"
    elseif c == "A" then
        local w, h = self.t.getSize()
        self.prompt = readline.editor({ term = self.t, x = 1, y = h, width = w, prompt = "name: ",
            colour = colours.white, promptColour = colours.yellow })
        self.prompt:set(s.current.name or "")
    else
        self:message("Ctrl+A " .. c .. ": no such key (Ctrl+A ? lists them)")
    end
    return nil
end

local function isCtrl(code) return code == keys.leftCtrl or code == keys.rightCtrl end

-- One event; nil, or why this display is done ("detach", "gone").
function Display:event(name, ...)
    local a, b, c = ...
    local s = self.s
    if not s:sweep() then return "gone" end
    if not s.displays[self.pid] then return "taken" end   -- (screen -d -r elsewhere took it)
    if name == "term_resize" then self:fit(); return nil end
    if name == "terminate" then return "detach" end          -- (Ctrl+T here, or the terminal hung up)
    if name == "key" and isCtrl(a) then self.ctrl = true end
    if name == "key_up" and isCtrl(a) then self.ctrl = false end

    if self.prompt then                                    -- naming a window
        local why = self.prompt:event(name, a)
        if why == "enter" then
            local text = scan.trim(self.prompt.line)
            s.current.name = text ~= "" and text or nil
            self.prompt = nil
        elseif why then
            self.prompt = nil
        end
        if name == "key" and a == keys.escape then self.prompt = nil end
        self.last = {}
        return nil
    end
    if self.mode == "help" then
        if name == "char" or (name == "key" and not isCtrl(a)) then self.mode = nil; self.t.clear(); self.last = {} end
        return nil
    end
    if self.mode == "back" then
        local rows = self.status and self.h - 1 or self.h
        if name == "key" then
            if a == keys.pageUp then self.back = self.back + rows - 1
            elseif a == keys.pageDown then self.back = self.back - (rows - 1)
            elseif a == keys.up then self.back = self.back + 1
            elseif a == keys.down then self.back = self.back - 1
            elseif a == keys.q or a == keys.escape or a == keys.enter then self.mode = nil; self.msg = nil end
            if self.mode == "back" and self.back <= 0 and (a == keys.pageDown or a == keys.down) then self.mode = nil; self.msg = nil end
        elseif name == "mouse_scroll" then
            self.back = self.back - a * 3
            if self.back <= 0 then self.mode = nil; self.msg = nil end
        end
        self.last = {}
        return nil
    end
    if self.confirm then                                   -- "kill window n? y/n": the next character says
        if name == "char" then
            if a == "y" then s:kill(s.current) end
            self.confirm, self.msg = nil, nil
        end
        return nil
    end
    if self.awaiting then                                  -- after Ctrl+A
        if name == "char" then
            if self.swallow and a == self.swallow then self.swallow = nil; return nil end
            self.awaiting = nil
            return self:command(a)
        end
        if name == "key" and a == keys.escape then self.awaiting = nil end
        if name == "key" and a == keys.backspace then self.awaiting = nil; s:step(-1) end
        return nil                                         -- (keys and key_ups for the command's char: not the window's)
    end
    if name == "key" and self.ctrl and a == keys[self.prefix] then
        self.awaiting, self.swallow = true, self.prefix   -- (the letter's char may follow: not the command)
        self.proc.input(s.current.tty, "key_up", keys.leftCtrl)   -- (the window saw Ctrl go down: let it up)
        return nil
    end
    if name == "key" and (a == keys.pageUp or a == keys.pageDown) and self.shift then
        if a == keys.pageUp then self.mode, self.back = "back", self.h - 2 end
        return nil
    end
    if name == "key" and (a == keys.leftShift or a == keys.rightShift) then self.shift = true end
    if name == "key_up" and (a == keys.leftShift or a == keys.rightShift) then self.shift = false end
    -- everything else is the window's
    if name == "key" or name == "key_up" or name == "char" or name == "paste" or scan.startsWith(name, "mouse_") then
        local rows = self.status and self.h - 1 or self.h
        if scan.startsWith(name, "mouse_") and c and c > rows then return nil end   -- (on the status bar)
        self.proc.input(s.current.tty, name, ...)
    end
    return nil
end

return M
