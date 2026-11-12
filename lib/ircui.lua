-- ircui.lua -- the screen of bin/irc: buffers drawn, keys and the mouse taken
--
--   local ui = require("ircui").new(client, term.current())
--   ui:event(table.unpack(ev))      -- keys, the mouse, a resize
--   ui:draw()                        -- when client.dirty or ui.dirty
--
-- The layout, weechat's with BitchX's colours:
--
--   +----------------------------------------------------+
--   | the title: the channel's topic                     |  blue
--   | 1.ccnix   | 12:34     alice | hello there    | @bob |
--   | 2.local   | 12:34  --> carol has joined      |  alice|
--   |   #ccnix  |                                  |      |
--   | [12:34] [alice(+i)] [3:local/#ccnix(+nt)] [Act: 2] |  blue: the status bar
--   | [#ccnix] what you type_                            |
--   +----------------------------------------------------+
--
-- The buffer list (left) and the nick list (right) show on a screen
-- wide enough (/set buflist and nicklist: on, off, auto).  Lines wrap
-- under their text, the nicks lined up in prefix_width columns (0: as
-- irssi, <nick> text).  A narrow screen (a pocket computer) leaves the
-- time out.
--
-- Keys: lib/readline's for the line (Ctrl+A/E/K/U/W/Y, Alt+B/F, Up and
-- Down the history, Ctrl+R searches it), and:
--   Enter                   send the line (a /command, or text)
--   Alt+1..9, Alt+0         buffer 1..9, 10 (or Esc then the digit)
--   Alt+Left/Right, Ctrl+P/N    the buffer before / after
--   Alt+A                   the next buffer with something new (hilights first)
--   PgUp/PgDn, the wheel    scroll back / forward (End: to the bottom, with the line empty)
--   Tab                     complete a nick, a #channel or a /command (again: the next)
--   Ctrl+C then b c u r i o     bold, colour (then the digits), underline, reverse,
--                           italic, plain: mIRC's codes, in the line
--   Ctrl+L                  draw the screen again
-- The mouse: click a buffer in the list to go to it, a nick to put it in
-- the line; the wheel scrolls the chat, or the nick list under it.

local irc = require("irc")
local scan = require("scan")
local text = require("text")
local readline = require("readline")
local ircclient = require("ircclient")

local U = {}
U.BUFLIST_W, U.NICKLIST_W = 15, 13
U.BUFLIST_AUTO, U.NICKLIST_AUTO = 80, 60

-- Blit colours
local BAR_BG, BAR_FG, BAR_DIM = "b", "0", "9"
-- the chat's text light grey, so bold (which CC's font hasn't) can show
-- as white, as a terminal's bright bold does
local TEXT_FG, BOLD_FG, BG = "8", "0", "f"
local ACT_COLOUR = { [0] = "8", "0", "4", "2" }     -- none, joins, messages, hilights
local FORMAT_KEYS = { b = irc.BOLD, c = irc.COLOUR, u = irc.UNDERLINE, r = irc.REVERSE, i = irc.ITALIC,
    o = irc.PLAIN, ["_"] = irc.UNDERLINE }

local UI = {}
UI.__index = UI

function U.new(client, t, opts)
    opts = opts or {}
    local ui = setmetatable({ client = client, t = t, dirty = true, history = client.history,
        nickScroll = 0, alt = false, ctrl = false }, UI)
    local w, h = t.getSize()
    ui.ed = readline.editor({
        term = t, x = 1, y = h, width = w, prompt = "", history = ui.history,
        promptColour = colours.cyan, colour = colours.white,
        ctrl = {
            c = function() ui.formatting = true end,
            n = function() client:command("/window next") end,
            p = function() client:command("/window prev") end,
            l = function() ui.dirty = true end,
        },
        meta = ui:metaBindings(),
        keys = { [keys.tab] = function(e) ui:complete(e) end },
    })
    ui:layout()
    return ui
end

function UI:metaBindings()
    local client = self.client
    local m = {}
    for d = 0, 9 do
        local n = d == 0 and 10 or d
        m[tostring(d)] = function()
            local b = client.buffers[n]
            if b then client:switch(b) end
        end
    end
    m.a = function() self:nextActive() end
    return m
end

-- The buffer with the most activity (hilights first), after the current.
function UI:nextActive()
    local client = self.client
    local best, bestAct = nil, 0
    local n = #client.buffers
    local at = client:bufferNumber(client.current) or 1
    for k = 1, n do
        local b = client.buffers[(at - 1 + k) % n + 1]
        if b.activity > bestAct then best, bestAct = b, b.activity end
    end
    if best then client:switch(best) end
end

--------------------------------------------------------------------------
-- Layout
--------------------------------------------------------------------------
local function shown(setting, w, auto)
    if setting == "on" then return true end
    if setting == "off" then return false end
    return w >= auto
end

function UI:layout()
    local w, h = self.t.getSize()
    local client = self.client
    self.w, self.h = w, h
    local cur = client.current
    self.bw = shown(client:setting("buflist"), w, U.BUFLIST_AUTO) and U.BUFLIST_W or 0
    self.nw = (cur.kind == "channel" and shown(client:setting("nicklist"), w, U.NICKLIST_AUTO)) and U.NICKLIST_W or 0
    if w - self.bw - self.nw < 20 then self.bw = 0 end
    if w - self.bw - self.nw < 20 then self.nw = 0 end
    self.cx, self.cw = self.bw + 1, w - self.bw - self.nw
    self.top, self.bottom = 2, h - 2
    self.ed:place(1, h, w)
end

--------------------------------------------------------------------------
-- Lines as rows
--------------------------------------------------------------------------
-- A line's text as cells: characters and their blit colours.
local function cellsOf(message, defaultFg, out)
    out = out or { ch = {}, fg = {}, bg = {} }
    for _, r in ipairs(irc.runs(message)) do
        local fg = r.fg and irc.MIRC_BLIT[r.fg] or (r.bold and defaultFg == TEXT_FG and BOLD_FG) or defaultFg
        local bg = r.bg and irc.MIRC_BLIT[r.bg] or BG
        if r.reverse then fg, bg = bg, fg end
        if fg == bg then fg = (bg == "f") and "0" or "f" end
        local s = r.text
        for i = 1, #s do
            local ch = s:sub(i, i)
            if ch == "\t" then ch = " " elseif scan.isControl(ch) then ch = "?" end     -- (DEL too)
            local n = #out.ch + 1
            out.ch[n], out.fg[n], out.bg[n] = ch, fg, bg
        end
    end
    return out
end

-- Where each row of n cells starts and ends, wrapped at spaces in width.
local function wrapRanges(chs, n, width)
    local rows, i = {}, 1
    while i <= n do
        local j = i + width - 1
        if j >= n then rows[#rows + 1] = { i, n }; break end
        local cut
        for k = j + 1, i + 1, -1 do
            if chs[k] == " " then cut = k; break end
        end
        if cut then
            rows[#rows + 1] = { i, cut - 1 }
            i = cut + 1
        else
            rows[#rows + 1] = { i, j }
            i = j + 1
        end
    end
    if #rows == 0 then rows[1] = { 1, 0 } end
    return rows
end

local function blitColour(mirc, fallback)
    return mirc and irc.MIRC_BLIT[mirc] or fallback
end

-- The prefix cut or padded to pw columns, right-aligned (weechat's "+"
-- when cut).
local function fitPrefix(prefix, pw) return text.padLeft(text.truncate(prefix, pw, "+"), pw) end

-- A line's rows for a chat this wide: each { text, fg, bg }, width long.
function UI:rowsOf(line, width, pw, showTime)
    if line._w == width and line._pw == pw and line._st == showTime then return line._rows end
    local lead = { ch = {}, fg = {}, bg = {} }
    local function push(cells, fg, bg)
        for i = 1, #cells do
            local n = #lead.ch + 1
            lead.ch[n], lead.fg[n], lead.bg[n] = cells:sub(i, i), fg, bg or BG
        end
    end
    if showTime and line.time ~= "" then push(line.time .. " ", "8") end
    local msg
    local pfg = blitColour(line.prefixColour, "0")
    if pw > 0 then
        local p = fitPrefix(line.prefix, pw)
        local sym = line.nick and text.stripSuffix(line.prefix, line.nick)
        if line.hilight then push(p, "f", "4")
        elseif sym and sym ~= "" then
            -- a mode symbol before the nick: its own colour
            local pad = #p - #line.prefix
            if pad >= 0 then
                push((" "):rep(pad), pfg)
                push(sym, sym:sub(1, 1) == "@" and "5" or "4")
                push(line.nick, pfg)
            else
                push(p, pfg)
            end
        else
            push(p, pfg)
        end
        push(" ", "7")
        msg = cellsOf(line.text, TEXT_FG)
    else
        msg = { ch = {}, fg = {}, bg = {} }
        if line.prefix ~= "" then
            local shownPrefix = line.nick and ("<" .. line.prefix .. ">") or line.prefix
            cellsOf(shownPrefix .. " ", line.hilight and "4" or pfg, msg)
        end
        cellsOf(line.text, TEXT_FG, msg)
    end
    local leadW = #lead.ch
    local room = math.max(4, width - leadW)
    local rows = {}
    for k, r in ipairs(wrapRanges(msg.ch, #msg.ch, room)) do
        local ch, fg, bg = {}, {}, {}
        for i = 1, leadW do
            if k == 1 then ch[i], fg[i], bg[i] = lead.ch[i], lead.fg[i], lead.bg[i]
            else ch[i], fg[i], bg[i] = " ", TEXT_FG, BG end
        end
        for i = r[1], r[2] do
            local n = #ch + 1
            ch[n], fg[n], bg[n] = msg.ch[i], msg.fg[i], msg.bg[i]
        end
        while #ch < width do
            local n = #ch + 1
            ch[n], fg[n], bg[n] = " ", TEXT_FG, BG
        end
        rows[k] = { table.concat(ch, "", 1, width), table.concat(fg, "", 1, width), table.concat(bg, "", 1, width) }
    end
    line._w, line._pw, line._st, line._rows = width, pw, showTime, rows
    return rows
end

--------------------------------------------------------------------------
-- Drawing
--------------------------------------------------------------------------
function UI:blitAt(x, y, chars, fg, bg)
    self.t.setCursorPos(x, y)
    self.t.blit(chars, fg, bg)
end

-- Text with mIRC codes as one bar row, w wide, on bg.
function UI:barRow(x, y, w, message, fg, bg)
    local cells = cellsOf(message, fg)
    local ch, f, b = {}, {}, {}
    for i = 1, w do
        local c = cells.ch[i]
        ch[i] = c or " "
        f[i] = c and cells.fg[i] or fg
        b[i] = (c and cells.bg[i] ~= BG) and cells.bg[i] or bg
    end
    self:blitAt(x, y, table.concat(ch), table.concat(f), table.concat(b))
end

function UI:titleText()
    local client, b = self.client, self.client.current
    if b.kind == "channel" then
        return b.name .. ": " .. (b.topic and b.topic ~= "" and b.topic or "(no topic)")
    elseif b.kind == "server" then
        local s = b.server
        return s.name .. ": " .. s.address .. " port " .. s.port .. (s.network and (" (" .. s.network .. ")") or "")
            .. (s.registered and "" or (s.conn and " - logging in" or (s.connecting and " - connecting" or " - not connected")))
    elseif b.kind == "query" then
        return "talking with " .. b.name .. (b.server and (" on " .. b.server.name) or "")
    end
    return "ccnix irc " .. ircclient.VERSION .. " - " .. #client.servers .. " server(s); /help"
end

-- The status bar, BitchX's: [time] [nick(+modes)] [n:server/buffer(+modes)] [Act: ...] [Lag] [-MORE-]
function UI:statusText()
    local client, b = self.client, self.client.current
    local s = b.server or client:activeServer(b)
    local parts = {}
    local function item(shown) parts[#parts + 1] = ircclient.colour(9, "[") .. shown .. ircclient.colour(9, "]") end
    item(os.date and os.date("%H:%M") or "")
    if s then
        local nick = s.nick or client:setting("nick")
        item(nick .. ((s.umodes or "") ~= "" and ("(" .. s.umodes .. ")") or "") .. (s.away and ircclient.colour(8, " zZ") or ""))
    end
    local where = tostring(client:bufferNumber(b) or "?") .. ":"
        .. ((b.server and b.kind ~= "server") and (b.server.name .. "/") or "") .. b.name
    if b.kind == "channel" and b.modes then where = where .. "(" .. b.modes .. ")" end
    if b.kind == "channel" and not b.joined then where = where .. ircclient.colour(8, " (out)") end
    item(where)
    local act = {}
    for i, x in ipairs(client.buffers) do
        if x.activity > 0 and x ~= b then
            local mirc = ({ 15, 0, 8, 13 })[x.activity + 1]
            act[#act + 1] = ircclient.colour(mirc, tostring(i))
        end
    end
    if #act > 0 then item("Act: " .. table.concat(act, ",")) end
    if s and s.lag and s.lag >= 0.5 then item(string.format("Lag %.1f", s.lag)) end
    for _, it in ipairs(client.statusItems) do
        local ok, shown = pcall(it.fn, b)
        if ok and shown and shown ~= "" then item(tostring(shown)) end
    end
    if b.scroll > 0 then item(ircclient.colour(8, "-MORE(" .. b.scroll .. ")-")) end
    return " " .. table.concat(parts, " ")
end

function UI:drawChat()
    local client, b = self.client, self.client.current
    local width = self.cw
    local showTime = width >= 40 and client:setting("timestamp_format") ~= ""
    local pw = client:setting("prefix_width") or 9
    if pw > 0 then pw = math.max(3, math.min(pw, math.floor(width / 4))) end
    local y = self.bottom
    local index = #b.lines - b.scroll
    while y >= self.top and index >= 1 do
        local rows = self:rowsOf(b.lines[index], width, pw, showTime)
        for r = #rows, 1, -1 do
            if y >= self.top then self:blitAt(self.cx, y, rows[r][1], rows[r][2], rows[r][3]) end
            y = y - 1
        end
        index = index - 1
    end
    local blank, fgs, bgs = (" "):rep(width), (TEXT_FG):rep(width), (BG):rep(width)
    while y >= self.top do
        self:blitAt(self.cx, y, blank, fgs, bgs)
        y = y - 1
    end
end

-- The buffer list: "n.name", channels under their server, coloured by
-- activity; the current one shown reversed.
function UI:drawBuflist()
    local client, bw = self.client, self.bw
    self.buflistRows = {}
    local y = self.top
    for i, b in ipairs(client.buffers) do
        if y > self.bottom then break end
        local indent = (b.kind == "channel" or b.kind == "query") and " " or ""
        local label = text.padRight(text.truncate(indent .. i .. "." .. b.name, bw - 1), bw - 1)
        local fg = ACT_COLOUR[b.activity] or "8"
        local bg = BG
        if b == client.current then fg, bg = "f", "8" end
        if b.kind == "channel" and not b.joined then fg = (b == client.current) and "7" or "7" end
        self:blitAt(1, y, label .. "|", fg:rep(bw - 1) .. "7", bg:rep(bw - 1) .. BG)
        self.buflistRows[y] = b
        y = y + 1
    end
    while y <= self.bottom do
        self:blitAt(1, y, (" "):rep(bw - 1) .. "|", ("0"):rep(bw - 1) .. "7", (BG):rep(bw))
        y = y + 1
    end
end

function UI:drawNicklist()
    local client, nw = self.client, self.nw
    local b = client.current
    local x = self.w - nw + 1
    local list = b:nickList()
    local rows = self.bottom - self.top + 1
    self.nickScroll = math.max(0, math.min(self.nickScroll, #list - rows))
    self.nicklistRows = {}
    for r = 0, rows - 1 do
        local n = list[r + 1 + self.nickScroll]
        local y = self.top + r
        if n then
            local sym = n.prefix:sub(1, 1)
            local symFg = sym == "@" and "5" or (sym == "+" and "4" or "0")
            local fg = irc.MIRC_BLIT[ircclient.nickColour(n.nick)]
            local row = "|" .. (sym ~= "" and sym or " ") .. text.padRight(text.truncate(n.nick, nw - 2), nw - 2)
            self:blitAt(x, y, row, "7" .. symFg .. fg:rep(nw - 2), (BG):rep(nw))
            self.nicklistRows[y] = n.nick
        else
            self:blitAt(x, y, "|" .. (" "):rep(nw - 1), "7" .. ("0"):rep(nw - 1), (BG):rep(nw))
        end
    end
    if #list > rows then                         -- (more than fit: how many, at the bottom)
        local more = "+" .. (#list - rows - self.nickScroll)
        if #list - rows - self.nickScroll > 0 then
            self:blitAt(self.w - #more + 1, self.bottom, more, ("8"):rep(#more), ("7"):rep(#more))
        end
    end
end

function UI:prompt()
    local b = self.client.current
    if b.kind == "core" then return "[ccnix] " end
    return "[" .. b.name .. "] "
end

function UI:draw()
    local t = self.t
    local w, h = t.getSize()
    if w ~= self.w or h ~= self.h then self:layout() end
    local client = self.client
    local wantNw = (client.current.kind == "channel" and shown(client:setting("nicklist"), w, U.NICKLIST_AUTO)) and U.NICKLIST_W or 0
    local wantBw = shown(client:setting("buflist"), w, U.BUFLIST_AUTO) and U.BUFLIST_W or 0
    if wantNw ~= self.nw or wantBw ~= self.bw then self:layout() end
    t.setCursorBlink(false)
    self:barRow(1, 1, w, self:titleText(), BAR_FG, BAR_BG)
    self:drawChat()
    if self.bw > 0 then self:drawBuflist() end
    if self.nw > 0 then self:drawNicklist() end
    self:barRow(1, h - 1, w, self:statusText(), BAR_FG, BAR_BG)
    t.setBackgroundColour(colours.black)
    self.ed.prompt = self:prompt()
    self.ed:draw()
    t.setCursorPos(self.ed:cursor())
    t.setTextColour(colours.white)
    t.setCursorBlink(true)
    self.dirty = false
    client.dirty = false
end

--------------------------------------------------------------------------
-- Completion: Tab, then Tab again for the next
--------------------------------------------------------------------------
function UI:candidates(word, first)
    local client, b = self.client, self.client.current
    local out, seen = {}, {}
    local lw = word:lower()
    local function add(c)
        if text.startsWith(c:lower(), lw) and not seen[c:lower()] then
            seen[c:lower()] = true
            out[#out + 1] = c
        end
    end
    if first and text.startsWith(word, "/") then
        local names = {}
        for n in pairs(client.commands) do names[#names + 1] = n end
        for n in pairs(client.aliases) do names[#names + 1] = n end
        table.sort(names)
        lw = text.stripPrefix(lw, "/")
        for _, n in ipairs(names) do
            if text.startsWith(n, lw) and not seen[n] then seen[n] = true; out[#out + 1] = "/" .. n end
        end
        return out
    end
    local s = b.server
    if s and s:isChannel(word) then
        for _, x in ipairs(client.buffers) do if x.server == s and x.kind == "channel" then add(x.name) end end
        return out
    end
    if b.kind == "channel" then
        local list = b:nickList()
        table.sort(list, function(x, y) return x.nick:lower() < y.nick:lower() end)
        local mine = s and s.nick and s.nick:lower()
        for _, n in ipairs(list) do
            if n.nick:lower() ~= mine then add(n.nick) end      -- (your own last, below)
        end
    elseif b.kind == "query" then
        add(b.name)
    end
    if s and s.nick then add(s.nick) end
    return out
end

function UI:complete(e)
    local c = self.comp
    if c and c.line == e.line and c.pos == e.pos then
        c.i = c.i % #c.list + 1
    else
        local line, pos = e.line, e.pos
        local from = text.findLast(line:sub(1, pos), " ") or 0
        local word = line:sub(from + 1, pos)
        local first = from == 0
        local list = self:candidates(word, first)
        if #list == 0 then self.comp = nil; return end
        c = { list = list, i = 1, from = from, after = line:sub(pos + 1), before = line:sub(1, from), first = first }
        self.comp = c
    end
    local pick = c.list[c.i]
    local suffix = " "
    if c.first and not text.startsWith(pick, "/") and not (self.client.current.server and self.client.current.server:isChannel(pick)) then
        suffix = ": "
    end
    local typed = c.before .. pick .. suffix
    e:set(typed .. c.after, #typed)
    c.line, c.pos = e.line, e.pos
end

--------------------------------------------------------------------------
-- Input
--------------------------------------------------------------------------
function UI:scroll(lines)
    local b = self.client.current
    b.scroll = math.max(0, math.min(b.scroll + lines, math.max(0, #b.lines - 1)))
    self.dirty = true
end

function UI:submit(line)
    local client = self.client
    if line ~= "" and self.history[#self.history] ~= line then
        self.history[#self.history + 1] = line
        if #self.history > 200 then table.remove(self.history, 1) end
    end
    self.ed:take()
    self.client.current.scroll = 0
    client:command(line, client.current)
end

local function isMod(code, a, b) return code == keys[a] or code == keys[b] end

function UI:event(name, a, b, c)
    local ed = self.ed
    if name == "term_resize" then
        self:layout(); self.dirty = true
        return
    end
    if name == "key" then
        if isMod(a, "leftAlt", "rightAlt") then self.alt = true end
        if isMod(a, "leftCtrl", "rightCtrl") then self.ctrl = true end
        if a ~= keys.tab and not isMod(a, "leftShift", "rightShift") and not isMod(a, "leftAlt", "rightAlt")
            and not isMod(a, "leftCtrl", "rightCtrl") then self.comp = nil end
        local half = math.max(1, math.floor((self.bottom - self.top + 1) / 2))
        if a == keys.pageUp then self:scroll(half); return end
        if a == keys.pageDown then self:scroll(-half); return end
        if a == keys["end"] and ed.line == "" then self.client.current.scroll = 0; self.dirty = true; return end
        if self.alt and not self.ctrl and (a == keys.left or a == keys.right) then
            self.client:command(a == keys.left and "/window prev" or "/window next")
            return
        end
    elseif name == "key_up" then
        if isMod(a, "leftAlt", "rightAlt") then self.alt = false end
        if isMod(a, "leftCtrl", "rightCtrl") then self.ctrl = false end
    elseif name == "char" then
        self.comp = nil
        if self.formatting and not (ed.swallow and a:lower() == ed.swallow) then   -- (Ctrl+C's own c: the editor's)
            self.formatting = false
            local code = FORMAT_KEYS[a:lower()]
            if code then ed:insert(code) end
            self.dirty = true
            return
        end
    elseif name == "paste" then
        local lines = text.lines(a)
        while lines[#lines] == "" do lines[#lines] = nil end
        if #lines > 1 then
            if #lines > 10 then
                self.client:err(self.client.current, "a paste of " .. #lines .. " lines: too many to send (10 at most)")
                return
            end
            for i = 1, #lines - 1 do
                ed:insert(lines[i])
                self:submit(ed.line)
            end
            ed:insert(lines[#lines])
            self.dirty = true
            return
        end
    elseif name == "mouse_click" then
        local buf = self.buflistRows and self.bw > 0 and b <= self.bw and self.buflistRows[c]
        if buf then self.client:switch(buf); return end
        local nick = self.nicklistRows and self.nw > 0 and b > self.w - self.nw and self.nicklistRows[c]
        if nick then
            if ed.line == "" then ed:set(nick .. ": ") else ed:insert(nick .. " ") end
            self.dirty = true
        end
        return
    elseif name == "mouse_scroll" then
        if self.nw > 0 and b > self.w - self.nw then
            self.nickScroll = math.max(0, self.nickScroll + a * 3)
        else
            self:scroll(-a * 2)
        end
        self.dirty = true
        return
    else
        return
    end
    local why = ed:event(name, a)
    if why == "enter" then
        self:submit(ed.line)
    end
    self.dirty = true
end

return U
