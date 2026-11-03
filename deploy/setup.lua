-- setup.lua -- put ccnix (this repo) on a turtle or computer in one go
--
--   wget run https://raw.githubusercontent.com/djt-code/ccnix/main/deploy/setup.lua [app...]
--
-- Apps (any number; none means everything for this kind of device):
--   mine farm mow autocompost claude   turtle programs (with turtlelib,
--                                      home and autostart)
--   coreutils                          cat, grep, ls-style utilities...
--   ccsh                            the POSIX-style shell, started at boot
--   diskclone                          for a computer with a disk drive
--   fileserver                         its disk drives as one folder, /jbod
--   net                                the network: ip, ping, traceroute, nc, host, tcpdump, curl;
--                                      up at every boot
--   router                             the network, and routing between
--                                      networks: forwarding on, up at boot
--   init                               processes and services: init at
--                                      boot, ps, kill, service
--   telnet                             the telnet client, and the network
--   telnetd                            the telnet server as a service, with
--                                      init and the network (then set
--                                      telnetd.password)
-- git and deploy/ always come; so do the help files of what you pick.
--
-- Options: --autostart <app> (a turtle runs it at every boot: resumes its
-- job, or starts one from the settings; see turtle/autostart.lua; on a
-- computer: router, its status screen at every boot),
-- --ccsh (ccsh at boot without naming it), --no-reboot, --all
-- (everything, sim/ too), --skip <dir> (leave out more).
--
--   setup mine --autostart mine        a miner that carries on after reboots
--   setup farm coreutils ccsh       a farmer you can also use as a shell
--   setup router --autostart router    a router, its screen up at boot
--
-- It fetches the latest git, then clones the repo into /ccnix, or pulls
-- it if it's there already (an install at /cc-turtles, the folder until
-- 2026-10-29, is moved there first), and runs deploy/install to put the
-- programs on the path.  A clone leaves out what the device doesn't run
-- (sim/, and pc/ on a turtle or turtle/ on a computer): see bin/git.lua.
-- Run it again any time to update (naming apps again changes what's
-- there; naming none keeps the choice); it's also the way out of a clone that
-- filled the disk part way: what that left in the folders a clone leaves
-- out, and Lua files in the top folder from before bin/ and turtle/, are
-- deleted; the rest is kept and finished.  (A pull deletes moved files
-- itself; the git from before did that only after fetching everything,
-- so a pull that filled the disk left both copies.  setup's pull, with
-- the new git, clears them.)  git runs from memory, so a full disk is no
-- bar to starting.  An old bootstrap copy of git at /git.lua is removed,
-- since the repo has its own in bin/.
--
-- On a server with ccnix in ROM (the ccnix mod: every program is in
-- /rom/ccnix already) there's nothing to clone: setup moves an install
-- from before ccnix over (/cc-turtles: its startup lines and files go; a
-- turtle's job files move to /ccnix the first time they're used),
-- brings this computer's updates up to date (ccnix update), and sets what
-- the apps named want (deploy/install).  The apps' files are all there
-- either way.

local REPO = "https://github.com/djt-code/ccnix"
local RAW = "https://raw.githubusercontent.com/djt-code/ccnix/main/"
local DIR = "/ccnix"

-- What each app needs.  A path ending in / is a whole folder.
local TURTLE = { "turtle/turtlelib.lua", "turtle/home.lua", "turtle/autostart.lua" }
local NET = { "bin/ip.lua", "bin/ping.lua", "bin/traceroute.lua", "bin/nc.lua", "bin/host.lua", "bin/tcpdump.lua", "bin/curl.lua", "lib/net.lua",
              "lib/netdb.lua", "lib/httpc.lua", "lib/cu.lua", "help/network.txt" }
local INIT = { "bin/init.lua", "bin/ps.lua", "bin/kill.lua", "bin/service.lua", "lib/proc.lua", "lib/cu.lua" }
local APPS = {
    mine = { "turtle/mine.lua", TURTLE },
    farm = { "turtle/farm.lua", TURTLE },
    mow = { "turtle/mow.lua", TURTLE },
    autocompost = { "turtle/autocompost.lua", TURTLE },
    claude = { "turtle/claude.lua", TURTLE },
    coreutils = { "bin/", "lib/" },
    ccsh = { "bin/ccsh.lua" },
    diskclone = { "pc/diskclone.lua" },
    fileserver = { "pc/fileserver.lua", "lib/jbod.lua" },
    net = { NET },
    router = { "pc/router.lua", NET },
    init = { INIT },
    telnet = { "bin/telnet.lua", "lib/telnet.lua", NET },
    telnetd = { "bin/telnetd.lua", "lib/telnet.lua", NET, INIT },
}
local ALWAYS = { "bin/git.lua", "lib/pager.lua", "deploy/", "help/ccnix.txt" }
local AUTOSTART = turtle and { mine = true, farm = true, mow = true, autocompost = true } or { router = true }

local cloneArgs, installArgs, apps = {}, {}, {}
local autostart
local args = { ... }
local i = 1
while i <= #args do
    local a = args[i]
    if a == "--ccsh" or a == "--no-reboot" then installArgs[#installArgs + 1] = a
    elseif a == "--all" then cloneArgs[#cloneArgs + 1] = a
    elseif a == "--skip" and args[i + 1] then
        cloneArgs[#cloneArgs + 1] = a
        cloneArgs[#cloneArgs + 1] = args[i + 1]
        i = i + 1
    elseif a == "--autostart" and AUTOSTART[args[i + 1]] then
        autostart = args[i + 1]
        i = i + 1
    elseif APPS[a] then
        apps[#apps + 1] = a
    else
        print("Usage: setup [app...] [--autostart app] [--ccsh] [--no-reboot] [--all] [--skip dir]...")
        local names = {}
        for name in pairs(APPS) do names[#names + 1] = name end
        table.sort(names)
        print("Apps: " .. table.concat(names, " "))
        print("--autostart: " .. (turtle and "mine, farm, mow or autocompost" or "router"))
        return
    end
    i = i + 1
end
if autostart and #apps > 0 then
    local named = false
    for _, a in ipairs(apps) do named = named or a == autostart end
    if not named then apps[#apps + 1] = autostart end
end
if autostart then
    installArgs[#installArgs + 1] = "--autostart"
    installArgs[#installArgs + 1] = autostart
end

-- The paths the named apps need, with their help files, as --only options
local function paths()
    local seen, out = {}, {}
    local function add(p)
        if seen[p] then return end
        seen[p] = true
        out[#out + 1] = "--only"
        out[#out + 1] = p
        local name = p:match("([^/]+)%.lua$")
        if name and p:sub(1, 4) ~= "lib/" then add("help/" .. name .. ".txt") end
        if p == "bin/" then add("help/") end
    end
    local function addAll(list)
        for _, p in ipairs(list) do
            if type(p) == "table" then addAll(p) else add(p) end
        end
    end
    addAll(ALWAYS)
    for _, a in ipairs(apps) do
        addAll(APPS[a])
        if a == "ccsh" then installArgs[#installArgs + 1] = "--ccsh" end
        if a == "net" or a == "telnet" or a == "telnetd" then installArgs[#installArgs + 1] = "--net" end
        if a == "router" then installArgs[#installArgs + 1] = "--router" end
        if a == "init" or a == "telnetd" then installArgs[#installArgs + 1] = "--init" end
    end
    return out
end
if #apps > 0 then
    for _, o in ipairs(paths()) do cloneArgs[#cloneArgs + 1] = o end
end

local function die(msg)
    printError(msg)
    error("", 0)
end

-- telnetd: a service init starts at every boot
local function telnetdService()
    for _, a in ipairs(apps) do
        if a == "telnetd" then
            settings.set("service.telnetd.cmd", "telnetd")
            settings.set("service.telnetd.enabled", true)
            settings.save()
            if not settings.get("telnetd.password") then
                print("telnetd needs a password: set telnetd.password <password> (then reboot, or service start telnetd)")
            end
        end
    end
end

-- ccnix in ROM: the settings, an old install moved over, the updates
if fs.exists("/rom/ccnix/.manifest") then
    local function find(path)
        return ccnix and ccnix.find and ccnix.find(path) or "/rom/ccnix/" .. path
    end
    print("ccnix is in this server's ROM: nothing to clone.")
    if fs.exists("/cc-turtles/.gitlite") then
        -- its startup lines: install's (and ip's, the old Craftix's) go;
        -- one that runs a program of its own, fileserver mount say, runs it
        -- by name now (ccnix puts it on the path), but not ip up (ccnix's
        -- boot starts the network)
        local files = { "/startup.lua" }
        if fs.isDir("/startup") then
            for _, name in ipairs(fs.list("/startup")) do files[#files + 1] = "/startup/" .. name end
        end
        for _, f in ipairs(files) do
            if fs.exists(f) and not fs.isDir(f) and f ~= "/startup" then
                local h = fs.open(f, "r")
                local text = h.readAll() or ""
                h.close()
                local out, changed = {}, false
                for line in (text .. "\n"):gmatch("(.-)\n") do
                    if line:find("/cc-turtles", 1, true) then
                        changed = true
                        local prog, rest = line:match('^shell%.run%(["\']/cc%-turtles/%w+/([%w%-]+)(.-)["\']%)$')
                        if prog and prog ~= "ip" then out[#out + 1] = 'shell.run("' .. prog .. rest .. '")' end
                    else
                        out[#out + 1] = line
                    end
                end
                if changed then
                    local new = table.concat(out, "\n"):gsub("\n+$", "")
                    if new == "" then fs.delete(f)
                    else local h2 = fs.open(f, "w"); h2.write(new .. "\n"); h2.close() end
                end
            end
        end
        -- its files, as its .gitlite lists them (what else is there stays)
        local h = fs.open("/cc-turtles/.gitlite", "r")
        local state = (textutils.unserialiseJSON or textutils.unserializeJSON)(h.readAll()) or {}
        h.close()
        for path in pairs(state.files or {}) do
            local p = "/cc-turtles/" .. path
            if fs.exists(p) then fs.delete(p) end
            local dir = fs.getDir(p)
            while dir ~= "cc-turtles" and dir ~= "" and fs.isDir(dir) and #fs.list(dir) == 0 do
                fs.delete(dir)
                dir = fs.getDir(dir)
            end
        end
        fs.delete("/cc-turtles/.gitlite")
        if #fs.list("/cc-turtles") == 0 then fs.delete("/cc-turtles") end
        print("Moved off /cc-turtles (an install from before ccnix): its startup lines and files are gone.")
    end
    telnetdService()
    if http then shell.run(find("bin/ccnix.lua"), "update")
    else print("HTTP is off here: no updates over the ROM's.") end
    shell.run(find("deploy/install.lua"), table.unpack(installArgs))
    return
end

if not http then die("HTTP is disabled on this server.") end

-- the latest git, wherever the repo is at, kept in memory: the disk may
-- be full
local h, err = http.get(RAW .. "bin/git.lua")
if not h then die("Can't fetch git: " .. tostring(err)) end
local gitFn, loadErr = load(h.readAll(), "@git", "t", _ENV)
h.close()
if not gitFn then die("Can't load git: " .. tostring(loadErr)) end
local function git(...)
    local ok, e = pcall(gitFn, ...)
    if not ok and e ~= "" then printError(tostring(e)) end      -- "": git said why
    return ok
end

-- the install folder was /cc-turtles until 2026-10-29: the same checkout,
-- moved (install swaps its startup lines; a turtle's job files come along)
if fs.exists("/cc-turtles/.gitlite") and not fs.exists(DIR) then
    fs.move("/cc-turtles", DIR)
    print("Moved /cc-turtles to " .. DIR .. ", where ccnix lives now.")
end

local ok
if fs.exists(fs.combine(DIR, ".gitlite")) then
    print("Updating " .. DIR)
    ok = git("pull", DIR, table.unpack(cloneArgs))
else
    if fs.exists(DIR) then
        -- a clone that never finished: drop what it got in the folders a
        -- clone now leaves out, keep the rest (clone overwrites it).  Lua
        -- files in the top folder are left from before bin/ and turtle/
        -- and nothing records them, so they'd never go: delete them too
        -- (a job's files there aren't .lua, and turtlelib moves them).
        for _, name in ipairs(fs.list(DIR)) do
            local p = fs.combine(DIR, name)
            if name:match("%.lua$") and not fs.isDir(p) then print("Removing " .. p); fs.delete(p) end
        end
        local all = false
        for _, a in ipairs(cloneArgs) do all = all or a == "--all" end
        if not all then
            for _, d in ipairs({ "sim", turtle and "pc" or "turtle" }) do
                local p = fs.combine(DIR, d)
                if fs.exists(p) then print("Removing " .. p); fs.delete(p) end
            end
        end
    end
    print("Cloning into " .. DIR)
    ok = git("clone", REPO, DIR, table.unpack(cloneArgs))
end
if not ok then die("git stopped; fix what it says and run setup again.") end

-- the README used to fetch git to /git.lua: that copy is out of date now
if fs.exists("/git.lua") and not fs.isDir("/git.lua") then
    local g = fs.open("/git.lua", "r")
    local head = g.readLine() or ""
    g.close()
    if head:find("minimal git client", 1, true) then
        fs.delete("/git.lua")
        print("Removed the old /git.lua (git is in " .. DIR .. "/bin now)")
    end
end

telnetdService()
shell.run(fs.combine(DIR, "deploy/install"), table.unpack(installArgs))
