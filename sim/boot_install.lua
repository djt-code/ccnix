-- sim/boot_install.lua
--
-- How ccnix gets on the path at boot, in a shellworld: deploy/boot.lua
-- under a fake /rom/ccnix (the ccnix mod's ROM, with its .manifest and
-- /rom/autorun/ccnix.lua), with no updates, with updates made for this
-- ROM (/ccnix wins, and its own boot.lua takes over), for another ROM
-- (left out), and a whole checkout at /ccnix; what runs at the end of
-- startup (ip up with net.boot; the autoruns after ccnix's, the motd and
-- the startup files, a disk's in place of the computer's, then init
-- alone, or the autostart, ccsh and the
-- stock shell, then shutdown), on a computer and a turtle; the
-- craftix.login shim; an install from before ccnix (/cc-turtles) left
-- alone; setup in ROM mode setting the settings only.  Then, with no
-- ROM (and no HTTP: setup sets up the checkout as it is), deploy/setup's
-- two lines (boot.lua first, `--end` last) in
-- /startup.lua, or in a /startup folder's 00-ccnix.lua and zz-ccnix.lua,
-- run as CraftOS would: the same path, help path, alias and order for a
-- checkout, an earlier install's lines and files gone.
--
-- The programs that wouldn't return (ccsh, init, the autostarts) and ip
-- are noted in RAN and not run; everything else runs for real.
local PROJ = ...
package.path = PROJ .. "/lib/?.lua;" .. PROJ .. "/sim/lib/?.lua;" .. package.path
local M = require("mock")
local SW = require("shellworld")
local check = M.check
local json = M.json
local function show(s) return (tostring(s):gsub("\n", "|")) end

-- settings and help, as boot and setup see them (real globals)
local STORE = {}
settings = {
    get = function(k, d) local v = STORE[k]; if v == nil then return d end return v end,
    set = function(k, v) STORE[k] = v end, unset = function(k) STORE[k] = nil end, save = function() end,
}
-- window, as boot uses it under init on a Computer: each one made, over
-- its parent
WINDOWS = {}
window = {
    create = function(parent)
        local win = setmetatable({ parent = parent, getLine = function() return "", "", "" end }, { __index = parent })
        WINDOWS[#WINDOWS + 1] = win
        return win
    end,
}
local HELP
help ={ path = function() return HELP end, setPath = function(p) HELP = p end }
textutils = textutils or M.textutilsApi()
turtle = nil

local function repoFile(path)
    local f = assert(io.open(PROJ .. "/" .. path, "rb"))
    local text = f:read("a")
    f:close()
    return text
end

-- CraftOS's path on a computer, as it is when the autoruns go
local BASE = ".:/rom/programs:/rom/programs/http"
local COMMIT = "1111111111111111111111111111111111111111"
-- what the ROM holds of the repo (the mod puts it all there; this is
-- what boot, ls and the checks touch)
local ROM_FILES = { "bin/ls.lua", "bin/rm.lua", "bin/mkdir.lua", "bin/ip.lua", "bin/ccsh.lua", "bin/init.lua", "bin/ccnix.lua", "lib/cu.lua", "lib/scan.lua",
                    "turtle/autostart.lua", "pc/router.lua", "help/ls.txt", "deploy/boot.lua", "deploy/setup.lua",
                    "deploy/version" }
local STUB = { ["bin/ip.lua"] = true, ["bin/ccsh.lua"] = true, ["bin/init.lua"] = true,
               ["turtle/autostart.lua"] = true, ["pc/router.lua"] = true }
local RAN = {}

local function reset(W)
    W.shell.setPath(BASE)
    W.aliases.ls, W.aliases.rm = "list", "delete"
    HELP = "/rom/help"
    RAN = {}
    _G.ccnix = nil
end

-- A computer before its autoruns; with a ROM, ccnix in it as the mod
-- puts it: the files, the .manifest and the autorun that runs boot.
local function world(withRom)
    local W = SW.new(PROJ)
    for k in pairs(STORE) do STORE[k] = nil end
    reset(W)
    W:dir("rom/autorun")
    local osRun = W.osRun
    function W.osRun(self, path, args, env)
        RAN[#RAN + 1] = path .. (#args > 0 and (" " .. table.concat(args, " ")) or "")
        local rel = path:match("^rom/ccnix/(.*)$") or path:match("^ccnix/(.*)$")
        if rel and STUB[rel] then return true end
        return osRun(self, path, args, env)
    end
    if withRom then
        local files = {}
        for _, p in ipairs(ROM_FILES) do
            W:file("rom/ccnix/" .. p, repoFile(p))
            files[p] = "blob-" .. p                     -- (a blob sha in the real one)
        end
        W:file("rom/ccnix/.manifest", json.encode({ url = "https://github.com/djt-code/ccnix", branch = "main",
            commit = COMMIT, date = 1793000000, source = "the mod", files = files }))
        W:file("rom/autorun/ccnix.lua", 'shell.run("/rom/ccnix/deploy/boot.lua")   -- ccnix: see that file\n')
    end
    return W
end
-- the updates' .gitlite, as git --lower writes it (lowerCommit: the ROM they were made for)
local function overlay(W, lowerCommit, files)
    W:file("ccnix/.gitlite", json.encode({ url = "https://github.com/djt-code/ccnix", branch = "main",
        commit = "2222222222222222222222222222222222222222", lower = "/rom/ccnix", lowerCommit = lowerCommit, files = files }))
end
-- what the autorun's shell.run ends in
local function boot(W)
    reset(W)
    return W:session({}, function() return W:osRun("rom/autorun/ccnix.lua", {}) end)
end
local function ran() return table.concat(RAN, ", ") end
local function state(W) return W.path .. " | " .. HELP .. " | ls=" .. tostring(W.aliases.ls) end
local function want(root)
    return BASE .. ":" .. root .. "/bin:" .. root .. "/pc | /rom/help:" .. root .. "/help | ls=" .. root .. "/bin/ls.lua"
end

--------------------------------------------------------------------------
-- (a) ROM mode
--------------------------------------------------------------------------
local W = world(true)
local r = boot(W)
check("ROM mode: the ROM's bin/ and pc/ on the path after CraftOS's, help/ on the help path, ls its own",
    state(W) == want("/rom/ccnix"), state(W))
check("_G.ccnix: find gives the ROM's copy (nil for what isn't there), lib the ROM's lib/ and turtle/",
    ccnix ~= nil and ccnix.find("bin/ls.lua") == "/rom/ccnix/bin/ls.lua" and ccnix.find("bin/none.lua") == nil
        and ccnix.lib == "/rom/ccnix/lib/?.lua;/rom/ccnix/turtle/?.lua;", ccnix and ccnix.lib)
check("nothing set for the end of startup: boot returns, CraftOS's startup goes on",
    ran() == "rom/autorun/ccnix.lua, rom/ccnix/deploy/boot.lua" and r.errText == "", ran() .. show(r.errText))
r = W:session({}, function() return W.shell.run("ls", "/rom/ccnix") end)
check("ls at the prompt is ccnix's, its library found through ccnix.lib",
    r.ok and r.out:find("bin") and r.out:find("deploy") and r.errText == "", show(r.out) .. show(r.errText))

-- updates made for this ROM: their copies first, both roots on the path
W = world(true)
W:file("ccnix/bin/ls.lua", repoFile("bin/ls.lua") .. "-- updated\n")
overlay(W, COMMIT, { ["bin/ls.lua"] = "blob-2" })
r = boot(W)
check("updates made for this ROM: /ccnix's copy first, then the ROM's; lib lists /ccnix first, dir by dir",
    ccnix.find("bin/ls.lua") == "/ccnix/bin/ls.lua" and ccnix.find("bin/ip.lua") == "/rom/ccnix/bin/ip.lua"
        and ccnix.lib == "/ccnix/lib/?.lua;/rom/ccnix/lib/?.lua;/ccnix/turtle/?.lua;/rom/ccnix/turtle/?.lua;", ccnix.lib)
check("both on the path and the help path, /ccnix first; ls is the update",
    state(W) == BASE .. ":/ccnix/bin:/rom/ccnix/bin:/ccnix/pc:/rom/ccnix/pc | /rom/help:/ccnix/help:/rom/ccnix/help | ls=/ccnix/bin/ls.lua"
        and r.out == "", state(W) .. show(r.out))
W:file("ccnix/deploy/boot.lua", repoFile("deploy/boot.lua"))
overlay(W, COMMIT, { ["bin/ls.lua"] = "blob-2", ["deploy/boot.lua"] = "blob-3" })
local before = state(W)
r = boot(W)
check("with an updated boot.lua among them, the ROM's hands over to it, to the same end",
    ran() == "rom/autorun/ccnix.lua, rom/ccnix/deploy/boot.lua, ccnix/deploy/boot.lua" and state(W) == before, ran())

-- updates made for another ROM: left out, and said so
W = world(true)
W:file("ccnix/bin/ls.lua", "-- stale\n")
W:file("ccnix/deploy/boot.lua", "error('the stale boot ran')\n")
overlay(W, "0000000000000000000000000000000000000000", { ["bin/ls.lua"] = "blob-2", ["deploy/boot.lua"] = "blob-3" })
r = boot(W)
check("updates made for another ROM: the ROM alone (its boot too), and a line saying `ccnix update` brings them back",
    state(W) == want("/rom/ccnix") and ccnix.lib == "/rom/ccnix/lib/?.lua;/rom/ccnix/turtle/?.lua;"
        and ran() == "rom/autorun/ccnix.lua, rom/ccnix/deploy/boot.lua"
        and r.out:find("made for another ROM; `ccnix update`", 1, true) and r.errText == "", show(r.out) .. show(r.errText))

-- a whole checkout at /ccnix (no ROM under it when it was made): used
W = world(true)
W:file("ccnix/bin/ls.lua", "-- mine\n")
W:file("ccnix/.gitlite", json.encode({ url = "https://github.com/djt-code/ccnix", branch = "main",
    commit = "3333333333333333333333333333333333333333", files = { ["bin/ls.lua"] = "blob-4" } }))
r = boot(W)
check("a whole checkout at /ccnix, made with no ROM under it: used whatever the ROM's commit",
    ccnix.find("bin/ls.lua") == "/ccnix/bin/ls.lua" and W.aliases.ls == "/ccnix/bin/ls.lua" and r.out == "", show(r.out))
check("... and rm points at ccnix's rm, not CraftOS's delete; mkdir at ccnix's", W.aliases.rm ~= "delete"
    and tostring(W.aliases.rm):find("bin/rm.lua$") ~= nil and tostring(W.aliases.mkdir):find("bin/mkdir.lua$") ~= nil,
    tostring(W.aliases.rm) .. " " .. tostring(W.aliases.mkdir))

--------------------------------------------------------------------------
-- (b) the settings, and the end of startup
--------------------------------------------------------------------------
W = world(true)
STORE["net.boot"] = true
r = boot(W)
check("net.boot: ip up, the ROM's ip, once the path is set", ran() == "rom/autorun/ccnix.lua, rom/ccnix/deploy/boot.lua, rom/ccnix/bin/ip.lua up", ran())

local END = "rom/autorun/ccnix.lua, rom/ccnix/deploy/boot.lua, "
W = world(true)
W:file("rom/autorun/aa-before.lua", "")                 -- (CraftOS ran this one before ccnix's)
W:file("rom/autorun/zz-after.lua", "")
W:file("startup.lua", "")
STORE["ccsh.login"], STORE["motd.enable"], STORE["shell.allow_startup"] = true, true, true
r = boot(W)
check("ccsh.login: the autoruns after ccnix's, the motd and startup.lua (the rest of CraftOS's startup), then ccsh, the stock shell, and shutdown",
    ran() == END .. "rom/autorun/zz-after.lua, rom/programs/motd.lua, startup.lua, rom/ccnix/bin/ccsh.lua, rom/programs/shell.lua"
        and r.errText == "os.shutdown called\n", ran() .. " " .. show(r.errText))

W = world(true)
W:dir("startup")
W:file("startup/00-a.lua", "")
W:file("startup/zz-b.lua", "")
STORE["init.boot"], STORE["ccsh.login"], STORE["ccnix.autostart"] = true, true, "router"
STORE["shell.allow_startup"] = true
r = boot(W)
check("init.boot (with ccsh.login and an autostart set too): a /startup folder's files in order, then init --boot alone; the autostart and ccsh are its",
    ran() == END .. "startup/00-a.lua, startup/zz-b.lua, rom/ccnix/bin/init.lua --boot" and r.errText == "os.shutdown called\n",
    ran() .. " " .. show(r.errText))
check("... on a Computer (its screen can't be read back): the rest of startup drawn in a window over the screen, for init to copy, the shell's header written again first",
    #WINDOWS == 1 and WINDOWS[1].parent == term.native() and term.current() == WINDOWS[1] and r.out:sub(1, 12) == "CraftOS 1.9\n",
    #WINDOWS .. " " .. show(r.out))

W = world(true)
STORE["init.boot"], STORE["shell.allow_startup"] = true, true
WINDOWS = {}
term.native().getLine = function(y) return "", "", "" end     -- (multishell's window, an Advanced Computer's)
r = boot(W)
check("... on an Advanced Computer (the shell in multishell's window): no window of boot's, no header again",
    #WINDOWS == 0 and term.current() == term.native() and r.out == "", #WINDOWS .. " " .. show(r.out))

-- disks (shell.allow_disk_startup): drives as peripheral.getNames() lists
-- them; the first disk with data and startup files on it is run in place
-- of the computer's; none with any, the computer's
local DISKS = { top = false, left = "disk", right = "disk2", back = "disk3" }     -- (top: empty; left: data, no startup)
peripheral = { getNames = function() return { "top", "left", "right", "back" } end }
disk = {
    isPresent = function(side) return DISKS[side] ~= nil and DISKS[side] ~= false end,
    hasData = function(side) return type(DISKS[side]) == "string" end,
    getMountPath = function(side) return DISKS[side] end,
}
W = world(true)
W:dir("disk")
W:file("disk/notes.txt", "")
W:file("disk2/startup.lua", "")
W:dir("disk2/startup")
W:file("disk2/startup/a.lua", "")
W:file("disk3/startup.lua", "")
W:file("startup.lua", "")
STORE["ccsh.login"], STORE["shell.allow_startup"], STORE["shell.allow_disk_startup"] = true, true, true
r = boot(W)
check("allow_disk_startup: the first disk with startup files, its program then its folder's, in place of the computer's",
    ran() == END .. "disk2/startup.lua, disk2/startup/a.lua, rom/ccnix/bin/ccsh.lua, rom/programs/shell.lua", ran())
W = world(true)
W:dir("disk")
W:file("startup.lua", "")
STORE["ccsh.login"], STORE["shell.allow_startup"], STORE["shell.allow_disk_startup"] = true, true, true
DISKS.right, DISKS.back = nil, nil
r = boot(W)
check("... no disk with any: the computer's", ran() == END .. "startup.lua, rom/ccnix/bin/ccsh.lua, rom/programs/shell.lua", ran())
W = world(true)
W:file("startup.lua", "")
W:file("disk/startup.lua", "")
STORE["ccsh.login"], STORE["shell.allow_startup"] = true, false
r = boot(W)
check("... and with allow_startup off, not even those; disks only with allow_disk_startup",
    ran() == END .. "rom/ccnix/bin/ccsh.lua, rom/programs/shell.lua", ran())
peripheral, disk = nil, nil

W = world(true)
STORE["ccsh.login"], STORE["ccnix.autostart"] = true, "router"
r = boot(W)
check("no init: ccnix.autostart router on a computer runs pc/router, then ccsh, then the stock shell",
    ran() == END .. "rom/ccnix/pc/router.lua, rom/ccnix/bin/ccsh.lua, rom/programs/shell.lua", ran())
STORE["ccnix.autostart"] = "mine"
r = boot(W)
check("an autostart that isn't router does nothing on a computer (with no ccsh.login, nothing at all)",
    ran() == END .. "rom/ccnix/bin/ccsh.lua, rom/programs/shell.lua", ran())

turtle = {}
W = world(true)
STORE["ccnix.autostart"] = "mine"
r = boot(W)
check("a turtle: turtle/ on the path in place of pc/, and turtle/autostart runs what the setting names, then the stock shell",
    W.path == BASE .. ":/rom/ccnix/bin:/rom/ccnix/turtle"
        and ran() == END .. "rom/ccnix/turtle/autostart.lua, rom/programs/shell.lua", W.path .. " " .. ran())
turtle = nil

W = world(true)
STORE["craftix.login"] = true
r = boot(W)
check("craftix.login (ccsh's old name) becomes ccsh.login, and ccsh runs",
    STORE["ccsh.login"] == true and STORE["craftix.login"] == nil and ran() == END .. "rom/ccnix/bin/ccsh.lua, rom/programs/shell.lua",
    ran())
W = world(true)
STORE["cc-turtles.autostart"] = "router"
r = boot(W)
check("cc-turtles.autostart (the setting's name when the repo was cc-turtles) becomes ccnix.autostart, and the router runs",
    STORE["ccnix.autostart"] == "router" and STORE["cc-turtles.autostart"] == nil and ran() == END .. "rom/ccnix/pc/router.lua, rom/programs/shell.lua",
    ran())

--------------------------------------------------------------------------
-- (c) an install from before ccnix
--------------------------------------------------------------------------
W = world(true)
W:file("cc-turtles/.gitlite", json.encode({ commit = "4444444444444444444444444444444444444444", files = {} }))
STORE["ccsh.login"] = true
r = boot(W)
check("/cc-turtles/.gitlite (an install from before ccnix, its own startup lines): boot steps aside; nothing on the path, no _G.ccnix, nothing run",
    state(W) == BASE .. " | /rom/help | ls=list" and _G.ccnix == nil
        and ran() == "rom/autorun/ccnix.lua, rom/ccnix/deploy/boot.lua" and r.out == "" and r.errText == "", state(W) .. show(r.out))

-- setup run in ROM mode: the settings alone, no startup lines
W = world(true)
r = W:session({}, function() return W:osRun("rom/ccnix/deploy/setup.lua", { "--ccsh", "--net", "--no-reboot" }) end)
check("setup from the ROM: sets ccsh.login and net.boot, writes no startup file, says the settings take effect at the next boot",
    STORE["ccsh.login"] == true and STORE["net.boot"] == true and not W.fs.exists("/startup.lua") and not W.fs.exists("/startup")
        and r.out:find("the settings take effect at the next boot", 1, true), show(r.out) .. show(r.errText))

--------------------------------------------------------------------------
-- (d) no ROM: setup's two lines, run as CraftOS would
--------------------------------------------------------------------------
local FIRST, LAST = 'shell.run("/ccnix/deploy/boot.lua")', 'shell.run("/ccnix/deploy/boot.lua", "--end")'
local function checkout()
    local W = world(false)
    W:file("ccnix/deploy/setup.lua", repoFile("deploy/setup.lua"))
    W:file("ccnix/deploy/boot.lua", repoFile("deploy/boot.lua"))
    for _, p in ipairs({ "ls", "cu", "ip", "ccsh", "init", "router" }) do W:install(p) end
    return W
end
W = checkout()
-- an earlier install's lines, with one of the computer's own between
W:file("startup.lua", "if not (':' .. shell.path() .. ':'):find(':/cc-turtles/bin:', 1, true) then shell.setPath(shell.path() .. ':/cc-turtles/bin') end\n"
    .. "print('mine')\n" .. 'if settings.get("ccsh.login") then shell.run("/cc-turtles/bin/ccsh") end\n')
r = W:session({}, function() return W:osRun("ccnix/deploy/setup.lua", { "--ccsh", "--net", "--no-reboot" }) end)
check("setup --ccsh --net --no-reboot on a checkout (no HTTP: as it is): boot.lua first and `--end` last in /startup.lua, an earlier install's lines gone and the computer's own kept; the settings set; boot ran in this shell (the path, ip up)",
    r.ok and W:read("startup.lua") == FIRST .. "\nprint('mine')\n" .. LAST .. "\n"
        and STORE["ccsh.login"] == true and STORE["net.boot"] == true and state(W) == want("/ccnix")
        and ran() == "ccnix/deploy/setup.lua --ccsh --net --no-reboot, ccnix/deploy/boot.lua --here, ccnix/bin/ip.lua up",
    show(W:read("startup.lua")) .. show(r.out) .. show(r.errText) .. " " .. ran())
local startup = W:read("startup.lua")
r = W:session({}, function() return W:osRun("ccnix/deploy/setup.lua", { "--no-reboot" }) end)
check("setup again: the same two lines, and it says so", W:read("startup.lua") == startup and r.out:find("already", 1, true) ~= nil,
    show(W:read("startup.lua")) .. show(r.out))
reset(W)
r = W:session({}, function() return W:osRun("startup.lua", {}) end)
check("startup.lua at boot: boot leaves what it does in ROM mode, for the checkout (path, help path, ls, _G.ccnix, ip up), the computer's line runs, then `--end` runs ccsh; no shell or shutdown of boot's own",
    state(W) == want("/ccnix") and ccnix.find("bin/ls.lua") == "/ccnix/bin/ls.lua"
        and ccnix.lib == "/ccnix/lib/?.lua;/ccnix/turtle/?.lua;" and r.out == "mine\n" and r.errText == ""
        and ran() == "startup.lua, ccnix/deploy/boot.lua, ccnix/bin/ip.lua up, ccnix/deploy/boot.lua --end, ccnix/bin/ccsh.lua",
    state(W) .. " " .. ran() .. " " .. show(r.out) .. show(r.errText))

-- with a /startup folder: a file of setup's at each end, an earlier
-- install's four gone; run in the folder's order
W = checkout()
W:dir("startup")
for _, old in ipairs({ "00-cc-turtles", "zx-init", "zy-autostart", "zz-ccsh" }) do W:file("startup/" .. old .. ".lua", "-- an earlier install's\n") end
W:file("startup/50-mine.lua", "print('mine')\n")
r = W:session({}, function()
    return W:osRun("ccnix/deploy/setup.lua", { "--init", "--autostart", "router", "--ccsh", "--no-reboot" })
end)
local names = W.fs.list("/startup")
check("setup with a /startup folder: 00-ccnix.lua (boot) and zz-ccnix.lua (--end) around the computer's own file, an earlier install's four gone; the settings set",
    r.ok and table.concat(names, " ") == "00-ccnix.lua 50-mine.lua zz-ccnix.lua"
        and W:read("startup/00-ccnix.lua") == FIRST .. "\n" and W:read("startup/zz-ccnix.lua") == LAST .. "\n"
        and STORE["init.boot"] == true and STORE["ccnix.autostart"] == "router" and STORE["net.forward"] == true,
    table.concat(names, " ") .. show(r.errText))
local function folder()
    reset(W)
    return W:session({}, function()
        for _, name in ipairs(names) do W:osRun("startup/" .. name, {}) end
        return true
    end)
end
r = folder()
check("run in turn: boot (the path, ip up; a window for init to copy, the header again), the computer's own, then `--end`: init --boot alone (the router and ccsh are its): boot's order",
    state(W) == want("/ccnix") and r.out == "CraftOS 1.9\nmine\n" and ran() == "startup/00-ccnix.lua, ccnix/deploy/boot.lua, ccnix/bin/ip.lua up, "
        .. "startup/50-mine.lua, startup/zz-ccnix.lua, ccnix/deploy/boot.lua --end, ccnix/bin/init.lua --boot",
    state(W) .. " " .. ran())
STORE["init.boot"] = nil
r = folder()
check("without init.boot, `--end` runs the autostart (the router), then ccsh",
    ran() == "startup/00-ccnix.lua, ccnix/deploy/boot.lua, ccnix/bin/ip.lua up, startup/50-mine.lua, startup/zz-ccnix.lua, "
        .. "ccnix/deploy/boot.lua --end, ccnix/pc/router.lua, ccnix/bin/ccsh.lua", ran())

-- a turtle with init: its job is a service of its own name, not the console's
turtle = {}
W = checkout()
for k in pairs(STORE) do STORE[k] = nil end
r = W:session({}, function()
    return W:osRun("ccnix/deploy/setup.lua", { "--init", "--autostart", "mine", "--no-reboot" })
end)
check("a turtle with init and --autostart mine: service mine runs `autostart --now`, at boot, not restarted when it ends; syslogd too",
    r.ok and STORE["service.mine.cmd"] == "autostart --now" and STORE["service.mine.restart"] == "no"
        and STORE["service.syslogd.cmd"] == "syslogd" and STORE["service.syslogd.enabled"] == true
        and STORE["service.mine.enabled"] == true and STORE["ccnix.autostart"] == "mine",
    show(STORE["service.mine.cmd"]) .. " " .. show(r.out) .. show(r.errText))
check("... boot run in setup's shell (--no-reboot) is no boot: the screen left alone, no header again",
    not r.out:find("CraftOS", 1, true) and term.current() == term.native(), show(r.out))
STORE["service.mine.cmd"] = "mine --resume --custom"
r = W:session({}, function()
    return W:osRun("ccnix/deploy/setup.lua", { "--no-reboot" })
end)
check("... and a service of that name already set is left as it is",
    r.ok and STORE["service.mine.cmd"] == "mine --resume --custom", show(STORE["service.mine.cmd"]))
for k in pairs(STORE) do STORE[k] = nil end
r = W:session({}, function()
    return W:osRun("ccnix/deploy/setup.lua", { "--autostart", "mine", "--no-reboot" })
end)
check("... without init, no service: the console runs the autostart", r.ok and STORE["service.mine.cmd"] == nil,
    show(STORE["service.mine.cmd"]))
turtle = nil

--------------------------------------------------------------------------
-- ccnix: the version in use, the ROM's and the updates'
--------------------------------------------------------------------------
local VERSION = repoFile("deploy/version"):match("%S+")
local function ccnixSays(W, ...)
    local args = { ... }
    return W:session({}, function() return W:osRun("rom/ccnix/bin/ccnix.lua", args) end)
end
W = world(true)
boot(W)
r = ccnixSays(W)
check("ccnix: the ROM's version (deploy/version) with its commit; no updates",
    r.out:find("ROM: ccnix " .. VERSION:gsub("%.", "%%.") .. ", https://github.com/djt%-code/ccnix main at 1111111")
        and r.out:find("Updates: none"), show(r.out) .. show(r.errText))
r = ccnixSays(W, "version")
check("ccnix version: the ROM's", r.out == "ccnix " .. VERSION .. "\n", show(r.out))
overlay(W, COMMIT, { ["deploy/version"] = "blob-new", ["deploy/boot.lua"] = "blob-boot" })
W:file("ccnix/deploy/version", "9.8.7\n")
W:file("ccnix/deploy/boot.lua", repoFile("deploy/boot.lua"))
r = ccnixSays(W, "version")
local r2 = ccnixSays(W)
check("just updated, not rebooted: the version in use, and what a reboot brings; the updates not yet in use",
    r.out == "ccnix " .. VERSION .. " (9.8.7 after a reboot)\n" and r2.out:find("2222222, in use after a reboot"),
    show(r.out) .. show(r2.out))
boot(W)
r = ccnixSays(W)
check("updates with a newer version: theirs, in use", r.out:find("Updates: ccnix 9%.8%.7, 2 files at 2222222, in use\n"),
    show(r.out))
r = ccnixSays(W, "version")
check("ccnix version: the updates' once they're in use", r.out == "ccnix 9.8.7\n", show(r.out))
local kept = { W:read("ccnix/.gitlite"), W:read("ccnix/deploy/version"), W:read("ccnix/deploy/boot.lua") }
W.fs.delete("ccnix/.gitlite") W.fs.delete("ccnix/deploy")             -- (as ccnix reset leaves it)
r = ccnixSays(W, "version")
r2 = ccnixSays(W)
check("just reset, not rebooted: still the updates' version, the ROM's after a reboot; said that they're still in use",
    r.out == "ccnix 9.8.7 (" .. VERSION .. " after a reboot)\n" and r2.out:find("stay in use until a reboot", 1, true),
    show(r.out) .. show(r2.out))
W:file("ccnix/.gitlite", kept[1]) W:file("ccnix/deploy/version", kept[2]) W:file("ccnix/deploy/boot.lua", kept[3])
boot(W)
W:file("rom/ccnix/deploy/version", nil)
overlay(W, "3333333333333333333333333333333333333333", {})
boot(W)
r = ccnixSays(W, "version")
check("a ROM from before versions (updates made for another ROM aren't used): unversioned",
    r.out == "ccnix unversioned\n", show(r.out))
