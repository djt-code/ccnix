-- telnet.lua -- a telnet client: another computer's shell or screen, here
--
--   telnet host [port]          (port 23, telnet)
--
-- host is an address or a name (lib/netdb: `ip host`, then DNS); port a
-- number or a service's name.  Connects over the network stack (`ip up`) and shows the other side's
-- screen: telnetd on another computer (a shell, or its console), or any
-- Telnet server that draws with ANSI escapes.  What you type goes there,
-- arrows and all; the mouse and pasting too, if the server asks.  A server
-- that echoes (telnetd, most) gets each key as it's typed; one that
-- doesn't (a MUD, nc) gets a line at a time, edited here (Backspace) and
-- sent at Enter, as BSD's telnet does.  Enter is sent as CR LF.  Ctrl+T
-- goes there as Ctrl+T, and under init Ctrl+Z goes there too (it stops
-- what runs over there, as in a raw-mode terminal).  Ctrl+] is telnet's
-- own: then q leaves, t sends an "interrupt process" (what stops a
-- program even on the console), z stops telnet itself here (a job: fg
-- brings it back), any other key goes back.  It ends when the other side
-- closes.  A screen without colour shows the colours as greys.

package.path = (ccnix and ccnix.lib or "/" .. fs.getDir(fs.getDir(shell.getRunningProgram())) .. "/lib/?.lua;") .. package.path  -- ccnix's lib/, or the one beside bin/
local cu = require("cu").init("telnet", "telnet host [port]")
local net = require("net")
local netdb = require("netdb")
local T = require("telnet")
local args = { ... }
if not args[1] or #args > 2 then cu.usageError() end
local host = args[1]
local ai, why = netdb.getaddrinfo(host, args[2] or "telnet", { socktype = netdb.SOCK_STREAM })
if not ai then cu.fail(host .. (args[2] and (" " .. args[2]) or "") .. ": " .. why); return cu.exit() end
local addr, port = ai[1].addr, ai[1].port

print("Connecting to " .. host .. (addr ~= host and (" (" .. addr .. ")") or "") .. " " .. port .. "...")
local conn, err = net.connect(addr, port, 15)
if not conn then cu.fail(host .. " " .. port .. ": " .. err); return cu.exit() end

-- under init: Ctrl+Z is a key for the other side (proc.ignore, as a
-- raw-mode terminal turns off ISIG), Ctrl+] z stops this one
local proc = rawget(_G, "proc")
if proc and not (proc.ignore and proc.getpgid) then proc = nil end
if proc then proc.ignore("TSTP") end

local native = term.current()
local w, h = native.getSize()
local win = window.create(native, 1, 1, w, h, true)
win.clear()
local screen = T.terminal(win, native.isColour())
local remoteEcho, naws = false, false
local replied = {}

local function send(s) conn:send(s) end

-- what's typed while the other side doesn't echo: a line, edited here and
-- sent whole at Enter (Telnet's old line-by-line mode, as BSD's client)
local line = ""
local function flush()
    if line ~= "" then send(T.escape(line)); line = "" end
end

local function reply(c, opt)
    if replied[opt] == c then return end         -- (said it already: no loops)
    replied[opt] = c
    send(T.cmd(c, opt))
end

local parse = T.parser({
    data = function(d) screen.feed(d) end,
    option = function(c, opt)
        if c == T.DO then
            if opt == T.NAWS then
                reply(T.WILL, T.NAWS)
                naws = true
                send(T.naws(w, h))
            elseif opt == T.SGA then reply(T.WILL, T.SGA)
            else reply(T.WONT, opt) end
        elseif c == T.WILL then
            if opt == T.ECHO then remoteEcho = true; flush(); reply(T.DO, T.ECHO)
            elseif opt == T.SGA then reply(T.DO, T.SGA)
            else reply(T.DONT, opt) end
        elseif c == T.WONT and opt == T.ECHO then
            remoteEcho = false
        end
    end,
})

-- what we type: sent as it's typed if the other side echoes; else added
-- to the line and shown here
local function typed(s)
    if remoteEcho then send(T.escape(s)); return end
    line = line .. s
    screen.feed(s)
end
-- Enter: Telnet's end of line, CR LF (after the line, if one's held)
local function enter()
    if remoteEcho then send("\r\n"); return end
    send(T.escape(line) .. "\r\n")
    line = ""
    screen.feed("\r\n")
end
-- Backspace: DEL for the other side, or (a line held here) the last character off it
local function rubout()
    if remoteEcho then send("\127"); return end
    if line == "" then return end
    line = line:sub(1, -2)
    screen.feed("\8 \8")
end

-- Ctrl+]: telnet's own keys, on the bottom line
local function menu()
    native.setCursorPos(1, h)
    native.setBackgroundColour(colours.black)
    native.setTextColour(colours.yellow)
    native.clearLine()
    native.write(((proc and "telnet: q quit, t interrupt, z stop, other: back")
        or "telnet: q quit, t interrupt, other: back"):sub(1, w))
    local quit = false
    while true do
        local ev, a = os.pullEventRaw()
        if ev == "char" and a ~= "]" then               -- (the ] of Ctrl+] may come as a char too)
            if a == "q" then quit = true
            elseif a == "t" then send(string.char(T.IAC, T.IP))
            elseif a == "z" and proc then proc.kill(-proc.getpgid(), "STOP") end   -- (stopped once this yields)
            break
        elseif ev == "terminate" or (ev == "key" and (a == keys.enter or a == keys.backspace)) then
            break
        end
    end
    win.redraw()
    win.restoreCursor()
    return quit
end

local closed
local ok, e = pcall(parallel.waitForAny,
    function()
        while true do
            local data, why = conn:read()
            if not data then closed = why; return end
            parse(data)
        end
    end,
    function()
        local ctrl = false
        while true do
            local ev = table.pack(os.pullEventRaw())
            local name = ev[1]
            if name == "char" then
                typed(ev[2])
            elseif name == "key" then
                local code = ev[2]
                if code == keys.leftCtrl or code == keys.rightCtrl then ctrl = true
                elseif ctrl and code == keys.rightBracket then
                    ctrl = false
                    if menu() then return end
                else
                    local b = T.keyBytes(code, ctrl)
                    if b == "\r" then enter()
                    elseif b == "\127" then rubout()
                    elseif b then flush(); send(b) end      -- (arrows, Ctrl+letters: as they are)
                end
            elseif name == "key_up" then
                if ev[2] == keys.leftCtrl or ev[2] == keys.rightCtrl then ctrl = false end
            elseif name == "terminate" then
                send("\20")                         -- Ctrl+T, for the other side
            elseif name == "paste" then
                if screen.paste then send("\27[200~" .. T.escape(ev[2]) .. "\27[201~")
                else
                    for text, nl in ev[2]:gmatch("([^\n]*)(\n?)") do
                        if text ~= "" then typed((text:gsub("\r$", ""))) end
                        if nl ~= "" then enter() end
                    end
                end
            elseif name:match("^mouse_") and name ~= "mouse_move" then
                if screen.mouse then send(T.mouseBytes(name, ev[2], ev[3], ev[4])) end
            elseif name == "proc_cont" and proc and ev[2] == proc.self() then
                win.redraw()                        -- (back from Ctrl+] z: the shell drew over it)
                win.restoreCursor()
            elseif name == "term_resize" then
                w, h = native.getSize()
                win.reposition(1, 1, w, h)
                screen.resize(w, h)
                if naws then send(T.naws(w, h)) end
            end
        end
    end)
if conn:state() ~= "CLOSED" then conn:close() end
term.redirect(native)
native.setBackgroundColour(colours.black)
native.setTextColour(colours.white)
native.setCursorBlink(false)
native.clear()
native.setCursorPos(1, 1)
if not ok then error(e, 0) end
print("Connection to " .. host .. " closed" .. ((closed and closed ~= "closed") and (": " .. closed) or "."))
return cu.exit()
