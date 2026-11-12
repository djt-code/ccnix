-- screen.lua -- windows that stay when you go: detach, and pick them up again later
--
--   screen [-S name] [command...]   a new session: its first window runs command (else a shell)
--   screen -ls                      the sessions: their windows, attached or detached
--   screen -r [name]                back to a detached session (the only one, if no name)
--   screen -d -r [name]             the same, detaching it from wherever it's shown first
--   screen -x [name]                show a session that's shown elsewhere as well
--
-- As GNU screen and tmux do, for ccnix: a session is a few windows, each
-- a shell (ccsh if ccsh.login is on) that init runs on a terminal of its
-- own, so it keeps running when you detach, or when the telnet
-- connection you started it from drops.  Telnet in again (or go to the
-- console) and `screen -r` puts you back where you were, programs still
-- running, screens as they are.  It needs init (`help init`).
--
-- The command key is Ctrl+A, then:
--   c       a new window             n, space   the next window
--   p       the window before        0-9        window 0-9
--   "  w    the windows, listed      A          name this window
--   k       kill this window (y to be sure)
--   d       detach (screen -r brings it back)
--   [       the scrollback: PgUp/PgDn, Up/Down, the wheel; q or Esc leaves
--   a       a Ctrl+A for the window (readline's start of the line)
--   t       a Ctrl+T for the window (to stop what runs there)
--   l       draw it again            ?          these keys
-- Ctrl+T itself detaches, and so does the terminal hanging up.
-- Shift+PgUp is the scrollback too.  The status bar at the bottom shows
-- the windows (* the one shown, - the one before), the session's name and
-- the time; a click on a window there goes to it.  A window whose command ends closes; the session ends with
-- its last window.  Ctrl+C and Ctrl+Z go to the window.
--
-- Settings: screen.prefix (the command key's letter: a; b for tmux's),
-- screen.status (false: no status bar).
--
--   telnet lab                      (on the computer, log in)
--   screen -S work                  a session called work
--   irc lab                         (Ctrl+A c: another window, a shell)
--   ...Ctrl+A d, or the connection drops...
--   telnet lab; screen -r work      back in, irc still connected

package.path = (ccnix and ccnix.lib or "/" .. fs.getDir(fs.getDir(shell.getRunningProgram())) .. "/lib/?.lua;") .. package.path  -- ccnix's lib/, or the one beside bin/
local cu = require("cu").init("screen", "screen [-S name] [command...] | -ls | -r [name] | -d -r [name] | -x [name]")
local screen = require("screen")
local text = require("text")

local proc = rawget(_G, "proc")
if not (proc and proc.newTerm and proc.input) then
    cu.fail("init isn't running (`help init`): it runs the windows")
    return cu.exit()
end

-- The options, read by hand, not getopt: -ls and -list are words of
-- their own, as screen has them, not -l -s.  Each word and what it sets.
local WORDS = { ["-ls"] = { "ls" }, ["-list"] = { "ls" }, ["-r"] = { "r" }, ["-d"] = { "d" }, ["-x"] = { "x" },
                ["-dr"] = { "d", "r" }, ["-rd"] = { "d", "r" } }
local args = { ... }
local opt = {}
local i = 1
while i <= #args do
    local a = args[i]
    if WORDS[a] then
        for _, o in ipairs(WORDS[a]) do opt[o] = true end
    elseif a == "-S" then
        i = i + 1
        opt.name = args[i]
        if not opt.name then cu.usageError("-S needs a name") end
    elseif a == "--" then
        i = i + 1
        break
    elseif text.startsWith(a, "-") and a ~= "-" then
        cu.usageError("unknown option " .. a)
    else
        break
    end
    i = i + 1
end
local rest = { table.unpack(args, i) }

screen.reap()

-- screen -ls
if opt.ls then
    local list = screen.sessions()
    if #list == 0 then print("No screen sessions."); return cu.exit() end
    print("Screen sessions:")
    for _, s in ipairs(list) do
        local n = s:attached()
        print(string.format("  %-12s %d window%s, %s", s.name, #s.windows, #s.windows == 1 and "" or "s",
            n > 0 and ("attached" .. (n > 1 and (" (" .. n .. " displays)") or "")) or "detached"))
    end
    return cu.exit()
end

-- The session to attach to (-r, -x): by name, else the only one that can be.
local function pick(name, wantDetached)
    if name then return screen.find(name) end
    local found
    for _, s in ipairs(screen.sessions()) do
        if not wantDetached or s:attached() == 0 then
            if found then return nil, "more than one: screen -ls, then screen -r <name>" end
            found = s
        end
    end
    return found
end

local native = term.current()
local w, h = native.getSize()
local status = settings.get("screen.status") ~= false
local session
if opt.r or opt.x then
    local why
    session, why = pick(opt.name or rest[1], opt.r and not opt.d and not opt.x)
    if not session then
        cu.fail(why or ((opt.name or rest[1]) and ("no session " .. (opt.name or rest[1])) or "no detached session (screen -ls)"))
        return cu.exit()
    end
    if session:attached() > 0 then
        if opt.d then
            for pid in pairs(session.displays) do session.displays[pid] = nil end
        elseif not opt.x then
            cu.fail(session.name .. " is attached elsewhere: screen -d -r " .. session.name .. " (take it), or -x (share it)")
            return cu.exit()
        end
    end
else
    if opt.name and screen.find(opt.name) then
        cu.fail("there's a session " .. opt.name .. " already: screen -r " .. opt.name)
        return cu.exit()
    end
    session = screen.newSession(proc, { name = opt.name, w = w, h = status and h - 1 or h,
        cmd = #rest > 0 and table.concat(rest, " ") or nil })
end

-- Ctrl+C and Ctrl+Z are the window's; Shift+PgUp is this scrollback
proc.ignore("INT")
proc.ignore("TSTP")
if proc.ownScrollback then proc.ownScrollback() end

native.setBackgroundColour(colours.black)
native.clear()
local display = screen.display(session, native, proc, { prefix = settings.get("screen.prefix") or "a", status = status })
local FRAME = 0.1
local why
local ok, err = pcall(function()
    display:draw()
    local timer = os.startTimer(FRAME)
    while not why do
        local ev = table.pack(os.pullEventRaw())
        if ev[1] == "timer" and ev[2] == timer then
            timer = os.startTimer(FRAME)
        else
            why = display:event(table.unpack(ev, 1, ev.n))
        end
        if not why then display:draw() end
    end
end)
display:detach()
native.setBackgroundColour(colours.black)
native.setTextColour(colours.white)
native.clear()
native.setCursorPos(1, 1)
native.setCursorBlink(true)
if not ok then error(err, 0) end
if why == "gone" then print("[screen is terminating]")
elseif why == "taken" then print("[" .. session.name .. " was taken by another display]")
else print("[detached from " .. session.name .. "]") end
return cu.exit()
