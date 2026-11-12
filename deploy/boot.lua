-- boot.lua -- ccnix at boot: from the ROM, or from a checkout's startup
--
-- Two ways in.  On a server with the ccnix mod, this repo is in every
-- computer's ROM, at /rom/ccnix, and /rom/autorun runs this at each
-- boot: no install.  On a server without it, deploy/setup clones the
-- repo and writes two lines into the computer's startup that run this
-- from the checkout: `boot.lua` first, `boot.lua --end` last.  Either way
-- it's the one place startup's work is written down (setup only puts
-- things in place, once).
--
-- Under the ROM, two layers.  /rom/ccnix is the server's copy (what the
-- mod shipped, or the server's own git checkout).  /ccnix is this
-- computer's updates over it: `ccnix update` pulls the latest with git
-- and keeps only the files that differ from the ROM's, so it costs a few
-- files of disk, not the whole repo.  Each program, library and help
-- page comes from /ccnix if it's there, else from the ROM.  Updates made
-- against another ROM (the server's copy has changed since) are left out
-- until `ccnix update` does them again, as they could pair a program
-- with another version's library.  The updates' own boot.lua takes over
-- from the ROM's, so a fix to this file arrives the same way.  From a
-- checkout there's one layer: the checkout.
--
-- It puts bin/ (and turtle/ on a turtle, pc/ on a computer) on the shell's
-- path after CraftOS's own, help/ on the help path, ls, rm and mkdir on
-- ccnix's (aliases, as CraftOS's ls and rm are: `alias ls list` brings
-- that back), nano on CraftOS's edit, and brings
-- the network up while net.boot is on.  Programs find their libraries
-- through _G.ccnix.
--
-- What doesn't return goes at the end of startup: init (which runs the
-- rest as processes) with init.boot set, or else the autostart
-- (ccnix.autostart), then ccsh (ccsh.login).  From the ROM, with any
-- of those set, this runs the rest of startup itself (the other autoruns,
-- the motd, the computer's startup files), then them, then a CraftOS
-- shell; when that shell exits the computer shuts down, as it would have
-- anyway.  From a checkout, startup goes on by itself, and `--end`, its
-- last line, runs them; the stock shell follows startup as ever.
--
-- A computer with an install from before ccnix (/cc-turtles, which its
-- own startup lines run) is left to it by the ROM's boot: deploy/setup
-- moves it over.

local ROM, OVER = "/rom/ccnix", "/ccnix"
local unjson = textutils.unserialiseJSON or textutils.unserializeJSON
local ending = ... == "--end"
local here = ... == "--here"            -- (setup's, in its shell: not a boot)
local romMode = fs.exists(ROM .. "/.manifest")

-- boot loads no library, on purpose: the .manifest and .gitlite read here
-- decide which lib/ is used (the updates' or the ROM's), an update's boot
-- can run over a ROM from before a library was there, and a library that
-- fails to load here would leave the computer without ccnix at all.  So
-- this is lib/fileio's readJSON written out again (as bin/ccnix, the
-- repair tool, has it), and the few string jobs below are done in place.
local function readJSON(path)
    if not fs.exists(path) or fs.isDir(path) then return nil end
    local f = fs.open(path, "r")
    local text = f.readAll()
    f.close()
    local ok, v = pcall(unjson, text or "")
    return ok and type(v) == "table" and v or nil
end

local roots, stale
if romMode then
    if fs.exists("/cc-turtles/.gitlite") then return end
    local manifest = readJSON(ROM .. "/.manifest") or {}
    local state = readJSON(OVER .. "/.gitlite")
    -- the updates are used if they were made against this ROM (or are a whole
    -- checkout, made with no ROM under it)
    local current = state ~= nil and (state.lower == nil or state.lowerCommit == manifest.commit)
    if current and shell.getRunningProgram():sub(1, 4) == "rom/" and fs.exists(OVER .. "/deploy/boot.lua") then
        return shell.run(OVER .. "/deploy/boot.lua", ...)
    end
    roots = current and { OVER, ROM } or { ROM }
    stale = state ~= nil and not current
else
    -- a checkout's own startup lines run this: the checkout is the one layer
    roots = { "/" .. fs.getDir(fs.getDir(shell.getRunningProgram())) }
end
for i = #roots, 1, -1 do if not fs.isDir(roots[i]) then table.remove(roots, i) end end

local function find(path)
    for _, r in ipairs(roots) do
        local p = r .. "/" .. path
        if fs.exists(p) then return p end
    end
end
local lib = {}
for _, d in ipairs({ "lib", "turtle" }) do               -- (turtlelib is in turtle/)
    for _, r in ipairs(roots) do lib[#lib + 1] = r .. "/" .. d .. "/?.lua;" end
end
-- the version this boot uses (`ccnix version` tells it from what the next would)
local version
local vf = find("deploy/version")
if vf then
    local h = fs.open(vf, "r")
    version = h and h.readLine()                         -- (the file is the version and a newline)
    if version == "" then version = nil end
    if h then h.close() end
end
_G.ccnix = { find = find, lib = table.concat(lib), version = version or "unversioned",
             updates = roots[1] == OVER and romMode }   -- (whether this boot took the updates)

-- CC's keys table has no Esc: in the game the key closes the computer's
-- screen, so it never came.  It does now (the ccnix mod's client gives it
-- to the computer; telnet makes it from a lone ESC byte), as GLFW numbers
-- it; vi, readline, irc and screen look it up as keys.escape.
if type(keys) == "table" and keys.escape == nil then keys.escape = 256 end

if settings.get("craftix.login") ~= nil then            -- (the setting from when ccsh was Craftix)
    if settings.get("ccsh.login") == nil then settings.set("ccsh.login", settings.get("craftix.login")) end
    settings.unset("craftix.login")
    settings.save()
end
if settings.get("cc-turtles.autostart") ~= nil then     -- (from when the repo was cc-turtles)
    if settings.get("ccnix.autostart") == nil then settings.set("ccnix.autostart", settings.get("cc-turtles.autostart")) end
    settings.unset("cc-turtles.autostart")
    settings.save()
end

if not ending then
    -- init draws the console in a window over the screen, and a new
    -- window starts blank: it copies what was on the screen into it first.
    -- An Advanced Computer's shell is in multishell's window already, which
    -- can be read back; a Computer's draws straight on the screen, which
    -- can't, so from here boot's output (and the rest of startup's: the
    -- MOTD, the startup files) goes to a window too, with the shell's
    -- header, written before it, written again.
    if not here and settings.get("init.boot") and find("bin/init.lua") and not term.current().getLine then
        local w, h = term.getSize()
        term.redirect(window.create(term.current(), 1, 1, w, h, true))
        term.setTextColour(term.isColour() and colours.yellow or colours.white)
        print(os.version())
        term.setTextColour(colours.white)
    end

    local function addTo(path, dir)
        if (":" .. path .. ":"):find(":" .. dir .. ":", 1, true) then return path end
        return path .. ":" .. dir
    end
    local path, helpPath = shell.path(), help.path()
    for _, d in ipairs({ "bin", turtle and "turtle" or "pc" }) do
        for _, r in ipairs(roots) do path = addTo(path, r .. "/" .. d) end
    end
    for _, r in ipairs(roots) do helpPath = addTo(helpPath, r .. "/help") end
    shell.setPath(path)
    help.setPath(helpPath)
    -- CraftOS's ls and rm are aliases (for list and delete), and an alias
    -- wins over the path: ours take their place; and mkdir's and help's,
    -- ahead of them on the path
    for _, name in ipairs({ "ls", "rm", "mkdir", "help" }) do
        local prog = find("bin/" .. name .. ".lua")
        if prog then shell.setAlias(name, prog) end
    end
    -- help's topics complete on Tab, as CraftOS's help's do
    local helpProg = find("bin/help.lua")
    if helpProg then
        shell.setCompletionFunction(helpProg:sub(2), function(_, index, typed)
            if index == 1 then return help.completeTopic(typed) end
        end)
    end
    shell.setAlias("nano", "edit")      -- CraftOS's editor, by the name people reach for
    if stale then
        print("ccnix: this computer's updates were made for another ROM; `ccnix update` brings them back")
    end

    if settings.get("net.boot") and find("bin/ip.lua") then shell.run(find("bin/ip.lua"), "up") end
    -- from a checkout, startup goes on by itself; its last line is `--end`
    if not romMode then return end
end

-- The end of startup, if anything there doesn't return
local auto = settings.get("ccnix.autostart", "")
local autostart = auto ~= "" and (turtle and find("turtle/autostart.lua")
    or (not turtle and auto == "router" and find("pc/router.lua"))) or nil
local init = settings.get("init.boot") and find("bin/init.lua") or nil
local login = settings.get("ccsh.login") and find("bin/ccsh.lua") or nil
if not (init or autostart or login) then return end

if not ending then
    -- Does what CraftOS's startup does after the autoruns, which it won't
    -- get to now: the rest of the /rom/autorun files (those after ours),
    -- the MOTD (motd.enable), then the startup files.  Written from that
    -- documented behaviour.
    for _, name in ipairs(fs.list("/rom/autorun")) do
        local autorun = "/rom/autorun/" .. name
        local after = name > "ccnix.lua" and name:sub(1, 1) ~= "."
        if after and not fs.isDir(autorun) then shell.run(autorun) end
    end
    if settings.get("motd.enable") then shell.run("/rom/programs/motd") end

    -- Where startup files can be, in the order they're looked at: each
    -- disk with data on it (shell.allow_disk_startup), as
    -- peripheral.getNames() lists their drives, then the computer's own
    -- root (shell.allow_startup).  The first that has any is the one run,
    -- so a disk's take the place of the computer's.
    local places = {}
    if settings.get("shell.allow_disk_startup") then
        for _, side in ipairs(peripheral.getNames()) do
            if disk.isPresent(side) and disk.hasData(side) then places[#places + 1] = disk.getMountPath(side) end
        end
    end
    if settings.get("shell.allow_startup") then places[#places + 1] = "/" end

    -- A place's startup files: its startup program (startup or
    -- startup.lua), then the files in its startup/ folder, in the order
    -- fs.list gives them.  nil if it has neither (an empty folder still
    -- counts: it has them, none).
    local function startupFilesIn(place)
        local named = "/" .. fs.combine(place, "startup")
        local program = shell.resolveProgram(named)
        local folder = fs.isDir(named)
        if not program and not folder then return nil end
        local list = { program }
        if folder then
            for _, name in ipairs(fs.list(named)) do
                local file = "/" .. fs.combine(named, name)
                if not fs.isDir(file) then list[#list + 1] = file end
            end
        end
        return list
    end
    for _, place in ipairs(places) do
        local list = startupFilesIn(place)
        if list then
            for _, file in ipairs(list) do shell.run(file) end
            break
        end
    end
end

if init then
    shell.run(init, "--boot")                           -- (the autostart and ccsh are its)
else
    if autostart then shell.run(autostart) end
    if login then shell.run(login) end
    if not ending then shell.run("/rom/programs/shell.lua") end
end
if not ending then os.shutdown() end                    -- (`--end`: the stock shell follows startup)
