-- telnet.lua -- Telnet (RFC 854) and an ANSI terminal, for telnet and telnetd
--
-- The two ends speak real Telnet, so any telnet client can use telnetd,
-- and the screen goes as ANSI/VT100 escapes (xterm's 256 colours):
--
--   server -> client  ANSI that redraws the rows that changed: a CC
--                     window, read back with getLine, as a terminal shows it
--   client -> server  what a terminal sends: characters, CR for Enter,
--                     DEL/BS, ESC [ A.. for arrows and the like, bracketed
--                     paste, SGR mouse reports; byte 20 (Ctrl+T) is
--                     Ctrl+T, IAC IP (Telnet's "interrupt process") too
--
-- Options: ECHO and SUPPRESS-GO-AHEAD (character at a time, the server
-- echoes) and NAWS (the client's screen size).
--
-- Characters: CC's 32-126 are ASCII, 160-255 Latin-1 (sent as UTF-8),
-- 128-159 its 2x3 block graphics (sent as Unicode's sextants, U+1FB00).

local T = {}
T.IAC, T.DONT, T.DO, T.WONT, T.WILL, T.SB, T.SE = 255, 254, 253, 252, 251, 250, 240
T.IP, T.AYT, T.NOP = 244, 246, 241
T.ECHO, T.SGA, T.NAWS = 1, 3, 31

function T.cmd(c, opt) return string.char(255, c, opt) end
function T.escape(s) return (s:gsub("\255", "\255\255")) end
function T.sub(opt, payload) return string.char(255, 250, opt) .. T.escape(payload) .. string.char(255, 240) end
function T.naws(w, h)
    return T.sub(T.NAWS, string.char(math.floor(w / 256), w % 256, math.floor(h / 256), h % 256))
end

-- A parser for bytes off the wire: h.data(s) for what isn't Telnet,
-- h.option(cmd, opt) for WILL/WONT/DO/DONT, h.sub(opt, payload), and
-- h.command(c) for the rest (IP, AYT...).
function T.parser(h)
    local state, cmd, sbOpt, sb = "data", nil, nil, {}
    return function(s)
        local data, i, n = {}, 1, #s
        local function flush()
            local d = table.concat(data)
            data = {}
            if #d > 0 and h.data then h.data(d) end
        end
        while i <= n do
            if state == "data" then
                local j = s:find("\255", i, true)
                if not j then data[#data + 1] = s:sub(i); break end
                data[#data + 1] = s:sub(i, j - 1)
                i, state = j + 1, "iac"
            else
                local b = s:byte(i)
                i = i + 1
                if state == "iac" then
                    if b == 255 then data[#data + 1] = "\255"; state = "data"
                    elseif b >= 251 then cmd, state = b, "opt"
                    elseif b == 250 then state = "sbopt"
                    else
                        flush()
                        if h.command then h.command(b) end
                        state = "data"
                    end
                elseif state == "opt" then
                    flush()
                    if h.option then h.option(cmd, b) end
                    state = "data"
                elseif state == "sbopt" then
                    sbOpt, sb, state = b, {}, "sb"
                elseif state == "sb" then
                    if b == 255 then state = "sbiac" else sb[#sb + 1] = string.char(b) end
                elseif state == "sbiac" then
                    if b == 240 then
                        flush()
                        if h.sub then h.sub(sbOpt, table.concat(sb)) end
                        state = "data"
                    else
                        if b == 255 then sb[#sb + 1] = "\255" end
                        state = "sb"
                    end
                end
            end
        end
        flush()
    end
end

--------------------------------------------------------------------------
-- Characters and colours
--------------------------------------------------------------------------
local function utf8(cp)
    if cp < 0x80 then return string.char(cp)
    elseif cp < 0x800 then return string.char(0xC0 + math.floor(cp / 64), 0x80 + cp % 64)
    elseif cp < 0x10000 then
        return string.char(0xE0 + math.floor(cp / 4096), 0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
    end
    return string.char(0xF0 + math.floor(cp / 262144), 0x80 + math.floor(cp / 4096) % 64,
        0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
end

-- The sextant for a 2x3 pattern (bit 0 top left ... bit 5 bottom right).
local function sextant(p)
    if p == 0 then return 0x20 elseif p == 63 then return 0x2588
    elseif p == 21 then return 0x258C elseif p == 42 then return 0x2590 end
    return 0x1FB00 + p - 1 - (p > 21 and 1 or 0) - (p > 42 and 1 or 0)
end

local OUT, IN = {}, {}       -- CC character -> UTF-8; code point -> { char, inverted }
for c = 0, 255 do
    if c >= 32 and c < 127 then OUT[c] = string.char(c)
    elseif c >= 160 then OUT[c] = utf8(c)
    elseif c >= 128 then OUT[c] = utf8(sextant(c - 128))
    else OUT[c] = " " end
end
for c = 160, 255 do IN[c] = { c } end
for p = 0, 63 do
    local cp = sextant(p)
    if cp ~= 0x20 then
        if p < 32 then IN[cp] = { 128 + p } else IN[cp] = { 128 + 63 - p, true } end
    end
end

-- CC text as UTF-8.
function T.toUTF8(s) return (s:gsub(".", function(ch) return OUT[ch:byte()] end)) end

-- CC's palette, and the xterm-256 colour nearest each (all different).
T.XTERM = { [0] = 255, 215, 176, 111, 185, 112, 218, 239, 246, 67, 134, 62, 95, 71, 167, 233 }
local CCRGB = { [0] = 0xF0F0F0, 0xF2B233, 0xE57FD8, 0x99B2F2, 0xDEDE6C, 0x7FCC19, 0xF2B2CC, 0x4C4C4C, 0x999999,
    0x4C99B2, 0xB266E5, 0x3366CC, 0x7F664C, 0x57A64E, 0xCC4C4C, 0x111111 }
local ANSI16 = { [0] = 0x000000, 0xCD0000, 0x00CD00, 0xCDCD00, 0x0000EE, 0xCD00CD, 0x00CDCD, 0xE5E5E5,
    0x7F7F7F, 0xFF0000, 0x00FF00, 0xFFFF00, 0x5C5CFF, 0xFF00FF, 0x00FFFF, 0xFFFFFF }
local function rgbOf256(n)
    if n < 16 then return ANSI16[n] end
    if n >= 232 then local v = 8 + 10 * (n - 232); return v * 65536 + v * 256 + v end
    n = n - 16
    local lv = { [0] = 0, 95, 135, 175, 215, 255 }
    return lv[math.floor(n / 36)] * 65536 + lv[math.floor(n / 6) % 6] * 256 + lv[n % 6]
end
-- The CC colour (0-15) nearest an xterm colour (exact for T.XTERM's).
local NEAREST = {}
for n = 0, 255 do
    local rgb, best, bd = rgbOf256(n), 0, math.huge
    for c = 0, 15 do
        local d = 0
        for _, sh in ipairs({ 65536, 256, 1 }) do
            local a, b = math.floor(rgb / sh) % 256, math.floor(CCRGB[c] / sh) % 256
            d = d + (a - b) ^ 2
        end
        if d < bd then best, bd = c, d end
    end
    NEAREST[n] = best
end
for c = 0, 15 do NEAREST[T.XTERM[c]] = c end
T.NEAREST = NEAREST

--------------------------------------------------------------------------
-- The server's side: a window as ANSI
--------------------------------------------------------------------------
-- The ANSI that brings a terminal that shows `last` up to what win shows
-- now (last is kept for next time; {} to begin).  "" when nothing changed.
function T.render(win, last)
    local w, h = win.getSize()
    local out = {}
    if last.w ~= w or last.h ~= h then
        out[1] = "\27[0m\27[2J"
        last.rows, last.w, last.h, last.cursor = {}, w, h, nil
    end
    for y = 1, h do
        local text, fg, bg = win.getLine(y)
        local key = text .. fg .. bg
        if last.rows[y] ~= key then
            last.rows[y] = key
            out[#out + 1] = "\27[" .. y .. ";1H"
            local cf, cb, x = nil, nil, 1
            while x <= #text do
                local f, b = fg:sub(x, x), bg:sub(x, x)
                local e = x
                while e < #text and fg:sub(e + 1, e + 1) == f and bg:sub(e + 1, e + 1) == b do e = e + 1 end
                if f ~= cf or b ~= cb then
                    out[#out + 1] = "\27[38;5;" .. T.XTERM[tonumber(f, 16) or 0] .. ";48;5;" .. T.XTERM[tonumber(b, 16) or 15] .. "m"
                    cf, cb = f, b
                end
                out[#out + 1] = T.toUTF8(text:sub(x, e))
                x = e + 1
            end
        end
    end
    local cx, cy = win.getCursorPos()
    local blink = win.getCursorBlink()
    local cur = cx .. ";" .. cy .. ";" .. tostring(blink)
    if #out > 0 or last.cursor ~= cur then
        out[#out + 1] = blink and "\27[?25h" or "\27[?25l"
        if cx >= 1 and cx <= w and cy >= 1 and cy <= h then out[#out + 1] = "\27[" .. cy .. ";" .. cx .. "H" end
        last.cursor = cur
    end
    return table.concat(out)
end

-- Ask the terminal for mouse reports (SGR) and bracketed paste.
T.MODES_ON = "\27[?1000h\27[?1002h\27[?1006h\27[?2004h"
T.MODES_OFF = "\27[?1000l\27[?1002l\27[?1006l\27[?2004l\27[0m\27[?25h"

--------------------------------------------------------------------------
-- The server's side: what a terminal sends, as CraftOS events
--------------------------------------------------------------------------
local DIGITS = { [0] = "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine" }
local PUNCT = { [" "] = "space", ["-"] = "minus", ["="] = "equals", ["["] = "leftBracket", ["]"] = "rightBracket",
    ["\\"] = "backslash", [";"] = "semicolon", ["'"] = "apostrophe", ["`"] = "grave", [","] = "comma",
    ["."] = "period", ["/"] = "slash" }
local CSI_KEYS = { A = "up", B = "down", C = "right", D = "left", H = "home", F = "end" }
local TILDE_KEYS = { ["1"] = "home", ["7"] = "home", ["4"] = "end", ["8"] = "end", ["2"] = "insert",
    ["3"] = "delete", ["5"] = "pageUp", ["6"] = "pageDown" }

-- feed(bytes) turns what a terminal typed into events, emit(name, ...);
-- byte 20 (Ctrl+T) comes out as emit("ctrl-t").  keysT: CraftOS's keys.
function T.decoder(emit, keysT)
    keysT = keysT or keys
    local state, buf, paste, lastCR = "ground", "", nil, false
    local function press(name)
        local code = name and keysT[name]
        if code then emit("key", code, false); emit("key_up", code) end
    end
    local function char(ch)
        local lower = ch:lower()
        local name = (lower:match("^%a$") and lower) or (ch:match("^%d$") and DIGITS[tonumber(ch)]) or PUNCT[ch]
        local code = name and keysT[name]
        if code then emit("key", code, false) end
        emit("char", ch)
        if code then emit("key_up", code) end
    end
    local function csi(params, final)
        if final == "~" then
            if params == "200" then paste = {}; return end
            press(TILDE_KEYS[params:match("^%d+")])
        elseif params:sub(1, 1) == "<" and (final == "M" or final == "m") then
            local b, x, y = params:match("^<(%d+);(%d+);(%d+)$")
            b, x, y = tonumber(b), tonumber(x), tonumber(y)
            if not b then return end
            if b >= 64 then emit("mouse_scroll", b % 2 == 0 and -1 or 1, x, y)
            elseif b >= 32 then emit("mouse_drag", b % 4 + 1, x, y)
            else emit(final == "M" and "mouse_click" or "mouse_up", (b % 4 == 1 and 3) or (b % 4 == 2 and 2) or 1, x, y) end
        elseif CSI_KEYS[final] then
            press(CSI_KEYS[final])
        end
    end
    return function(s)
        for i = 1, #s do
            local ch = s:sub(i, i)
            local b = ch:byte()
            if paste then
                paste[#paste + 1] = ch
                local tail = table.concat(paste, "", math.max(1, #paste - 5))
                if tail == "\27[201~" then
                    local text = table.concat(paste, "", 1, #paste - 6)
                    paste = nil
                    if text ~= "" then emit("paste", text) end
                end
            elseif state == "esc" then
                if ch == "[" then state, buf = "csi", ""
                elseif ch == "O" then state = "ss3"
                else state = "ground"; char(ch) end
            elseif state == "csi" then
                if b >= 0x40 and b <= 0x7E then
                    state = "ground"
                    csi(buf, ch)
                else
                    buf = buf .. ch
                    if #buf > 32 then state = "ground" end
                end
            elseif state == "ss3" then
                state = "ground"
                press(CSI_KEYS[ch])
            elseif b == 27 then
                state = "esc"
            elseif b == 13 then
                press("enter")
            elseif b == 10 or b == 0 then
                if not lastCR then press("enter") end
            elseif b == 8 or b == 127 then
                press("backspace")
            elseif b == 9 then
                press("tab")
            elseif b == 20 then
                emit("ctrl-t")
            elseif b < 32 then
                -- Ctrl+letter: Ctrl down, the letter, Ctrl up
                local letter = string.char(b + 96)
                local ctrl = keysT.leftCtrl
                if ctrl then emit("key", ctrl, false) end
                press(letter)
                if ctrl then emit("key_up", ctrl) end
            else
                char(ch)
            end
            lastCR = b == 13
        end
    end
end

--------------------------------------------------------------------------
-- The client's side: an ANSI terminal on a CC window
--------------------------------------------------------------------------
-- feed(s) draws what a server sent on win (UTF-8 and escapes); the
-- terminal's state is t (t.mouse, t.paste: what the server asked for).
T.HISTORY = 500                 -- lines of scrollback a terminal keeps

function T.terminal(win, colour)
    local t = { mouse = false, paste = false }
    local w, h = win.getSize()
    local x, y, fg, bg, bold, rev = 1, 1, 0, 15, false, false
    local state, buf, utf, need, cp = "ground", "", nil, 0, 0
    local function grey(c)                       -- (a basic screen: white, light grey, grey, black)
        if colour then return c end
        local rgb = CCRGB[c]
        local l = (math.floor(rgb / 65536) + math.floor(rgb / 256) % 256 + rgb % 256) / 3
        return l > 200 and 0 or l > 120 and 8 or l > 50 and 7 or 15
    end
    -- the scrollback: rows that scroll off the top (a line feed at the
    -- bottom, CSI S), oldest first, { text, fg, bg } as getLine gives them;
    -- a redraw in place (towel's film, a full-screen program) adds nothing
    local history = {}
    local function keep(n)
        if not win.getLine then return end
        for r = 1, math.min(n, h) do history[#history + 1] = { win.getLine(r) } end
        if #history > T.HISTORY then
            local drop, n = #history - T.HISTORY, #history
            for i = 1, n - drop do history[i] = history[i + drop] end
            for i = n - drop + 1, n do history[i] = nil end
        end
    end
    t.history = history
    local function scroll()
        if y > h then keep(y - h); win.scroll(y - h); y = h end
    end
    local function put(ch, inverted)
        if x > w then x, y = 1, y + 1; scroll() end
        local f, b = fg, bg
        if bold and f < 8 then f = f end
        if rev then f, b = b, f end
        if inverted then f, b = b, f end
        win.setCursorPos(x, y)
        win.setTextColour(2 ^ grey(f))
        win.setBackgroundColour(2 ^ grey(b))
        win.write(ch)
        x = x + 1
    end
    local function sgr(params)
        local p, i = {}, 1
        for v in (params .. ";"):gmatch("([^;]*);") do p[#p + 1] = tonumber(v) or 0 end
        if #p == 0 then p[1] = 0 end
        while i <= #p do
            local v = p[i]
            if v == 0 then fg, bg, bold, rev = 0, 15, false, false
            elseif v == 1 then bold = true
            elseif v == 22 then bold = false
            elseif v == 7 then rev = true
            elseif v == 27 then rev = false
            elseif v >= 30 and v <= 37 then fg = NEAREST[v - 30 + (bold and 8 or 0)]
            elseif v >= 90 and v <= 97 then fg = NEAREST[v - 90 + 8]
            elseif v >= 40 and v <= 47 then bg = NEAREST[v - 40]
            elseif v >= 100 and v <= 107 then bg = NEAREST[v - 100 + 8]
            elseif v == 39 then fg = 0
            elseif v == 49 then bg = 15
            elseif (v == 38 or v == 48) and p[i + 1] == 5 and p[i + 2] then
                if v == 38 then fg = NEAREST[p[i + 2] % 256] else bg = NEAREST[p[i + 2] % 256] end
                i = i + 2
            elseif (v == 38 or v == 48) and p[i + 1] == 2 and p[i + 4] then
                -- true colour: the nearest CC colour, by way of the 256 cube
                local function lv(c) return c < 48 and 0 or c < 115 and 1 or math.floor((c - 35) / 40) end
                local n = 16 + 36 * lv(p[i + 2]) + 6 * lv(p[i + 3]) + lv(p[i + 4])
                if v == 38 then fg = NEAREST[n] else bg = NEAREST[n] end
                i = i + 4
            end
            i = i + 1
        end
    end
    local function clearLine(from, to)
        win.setBackgroundColour(2 ^ grey(bg))
        win.setCursorPos(from, y)
        win.write((" "):rep(math.max(0, to - from + 1)))
    end
    local function csi(params, final)
        local priv = params:sub(1, 1) == "?"
        if priv then params = params:sub(2) end
        local a, b = params:match("^(%d*);?(%d*)")
        local n1, n2 = tonumber(a), tonumber(b)
        if final == "H" or final == "f" then y, x = n1 or 1, n2 or 1
        elseif final == "A" then y = y - (n1 or 1)
        elseif final == "B" then y = y + (n1 or 1)
        elseif final == "C" then x = x + (n1 or 1)
        elseif final == "D" then x = x - (n1 or 1)
        elseif final == "G" then x = n1 or 1
        elseif final == "d" then y = n1 or 1
        elseif final == "J" then
            if (n1 or 0) == 2 or (n1 or 0) == 3 then
                win.setBackgroundColour(2 ^ grey(bg))
                win.clear()
            elseif (n1 or 0) == 0 then
                clearLine(x, w)
                for r = y + 1, h do win.setCursorPos(1, r); win.write((" "):rep(w)) end
            end
        elseif final == "K" then
            local m = n1 or 0
            if m == 0 then clearLine(x, w) elseif m == 1 then clearLine(1, x) else clearLine(1, w) end
        elseif final == "m" then sgr(params)
        elseif (final == "h" or final == "l") and priv then
            for v in params:gmatch("%d+") do
                if v == "25" then t.cursor = final == "h"
                elseif v == "1000" or v == "1002" or v == "1006" then t.mouse = final == "h"
                elseif v == "2004" then t.paste = final == "h" end
            end
        elseif final == "S" then keep(n1 or 1); win.scroll(n1 or 1)
        elseif final == "T" then win.scroll(-(n1 or 1))
        end
        x, y = math.max(1, math.min(w, x)), math.max(1, math.min(h, y))
    end
    t.cursor = true
    function t.feed(s)
        local i, n = 1, #s
        while i <= n do
            local b = s:byte(i)
            if state == "ground" then
                if b >= 32 and b < 127 then
                    local j = i
                    while j < n and s:byte(j + 1) >= 32 and s:byte(j + 1) < 127 do j = j + 1 end
                    for k = i, j do put(s:sub(k, k)) end
                    i = j
                elseif b >= 0xC0 then utf, need, cp = true, b >= 0xF0 and 3 or b >= 0xE0 and 2 or 1, b % (b >= 0xF0 and 8 or b >= 0xE0 and 16 or 32)
                    state = "utf"
                elseif b >= 0x80 then put("?")
                elseif b == 27 then state = "esc"
                elseif b == 13 then x = 1
                elseif b == 10 then y = y + 1; scroll()
                elseif b == 8 then x = math.max(1, x - 1)
                elseif b == 9 then x = math.min(w, (math.floor((x - 1) / 8) + 1) * 8 + 1)
                end
            elseif state == "utf" then
                cp = cp * 64 + b % 64
                need = need - 1
                if need == 0 then
                    state = "ground"
                    local m = IN[cp]
                    if m then put(string.char(m[1]), m[2]) else put("?") end
                end
            elseif state == "esc" then
                if b == 91 then state, buf = "csi", ""                      -- [
                elseif b == 93 then state = "osc"                             -- ]
                elseif b == 40 or b == 41 then state = "charset"             -- ( )
                elseif b == 99 then win.clear(); x, y, fg, bg = 1, 1, 0, 15; state = "ground"   -- c
                else state = "ground" end
            elseif state == "charset" then
                state = "ground"
            elseif state == "osc" then
                if b == 7 or b == 27 then state = "ground" end
            elseif state == "csi" then
                if b >= 0x40 and b <= 0x7E then
                    state = "ground"
                    csi(buf, string.char(b))
                else
                    buf = buf .. string.char(b)
                end
            end
            i = i + 1
        end
        win.setCursorPos(math.min(x, w), y)
        win.setTextColour(2 ^ grey(fg))
        win.setCursorBlink(t.cursor)
    end
    function t.resize(nw, nh) w, h = nw, nh end
    return t
end

--------------------------------------------------------------------------
-- The client's side: CraftOS keys as a terminal sends them
--------------------------------------------------------------------------
-- The bytes for key `code` (with Ctrl held: ctrl), or nil if it's one
-- that types a character (that comes as a char event).
function T.keyBytes(code, ctrl, keysT)
    keysT = keysT or keys
    local name = keysT.getName and keysT.getName(code)
    if not name then return nil end
    if ctrl and #name == 1 and name:match("%a") then return string.char(name:byte() - 96) end
    local SEQ = { enter = "\r", numPadEnter = "\r", backspace = "\127", tab = "\t",
        up = "\27[A", down = "\27[B", right = "\27[C", left = "\27[D", home = "\27[H", ["end"] = "\27[F",
        insert = "\27[2~", delete = "\27[3~", pageUp = "\27[5~", pageDown = "\27[6~" }
    return SEQ[name]
end

-- A mouse event as an SGR report: mouse_click/up/drag/scroll.
function T.mouseBytes(ev, button, x, y)
    if ev == "mouse_scroll" then return "\27[<" .. (button < 0 and 64 or 65) .. ";" .. x .. ";" .. y .. "M" end
    local b = (button == 2 and 2) or (button == 3 and 1) or 0
    if ev == "mouse_drag" then return "\27[<" .. (32 + b) .. ";" .. x .. ";" .. y .. "M" end
    return "\27[<" .. b .. ";" .. x .. ";" .. y .. (ev == "mouse_up" and "m" or "M")
end

return T
