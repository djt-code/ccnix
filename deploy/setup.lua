-- setup.lua -- ccnix on a turtle or computer: put it there, choose what it
-- runs, update it
--
--   wget run https://raw.githubusercontent.com/djt-code/ccnix/main/deploy/setup.lua [app...] [options]
--   ccnix setup [app...] [options]       (once ccnix is there)
--
-- Apps (any number; none means everything for this kind of device):
--   mine farm mow autocompost claude   turtle programs (with turtlelib,
--                                      home and autostart)
--   coreutils                          cat, grep, ls-style utilities...
--   ccsh                               the POSIX-style shell, started at boot
--   diskclone                          for a computer with a disk drive
--   fileserver                         its disk drives as one folder, /jbod
--   net                                the network: ip, ping, traceroute, nc, host, netstat, tcpdump, curl;
--                                      up at every boot
--   router                             the network, and routing between
--                                      networks: forwarding on, up at boot
--   init                               processes and services: init at
--                                      boot, ps, kill, service; the system
--                                      log (syslogd as a service, logger)
--   telnet                             the telnet client, and the network
--   telnetd                            the telnet server as a service, with
--                                      init and the network (then set
--                                      telnetd.password)
--   httpd                              the web server as a service, with
--                                      init and the network: serves /www,
--                                      Lua pages in /www/cgi
-- git and deploy/ always come; so do the help files of what you pick.
--
-- Options: --autostart <app> (a turtle runs it at every boot: resumes its
-- job, or starts one from the settings; see turtle/autostart.lua; on a
-- computer: router, its status screen at every boot), --example (httpd,
-- and a guestbook in its script root: /cgi/guestbook), --ccsh, --net,
-- --router, --init (what ccsh, net, router and init set, without
-- naming them), --no-reboot, --all (everything, sim/ too), --skip <dir>
-- (leave out more).
--
--   setup mine --autostart mine        a miner that carries on after reboots
--   setup farm coreutils ccsh          a farmer you can also use as a shell
--   setup router --autostart router    a router, its screen up at boot
--
-- There are two ways ccnix runs, and setup does what each needs:
--
--  * On a server with the ccnix mod, every program is in the ROM
--    (/rom/ccnix) and the ROM's autorun runs deploy/boot.lua at every
--    boot: nothing to clone.  setup moves an install from before ccnix
--    over (/cc-turtles: its startup lines and files go; a turtle's job
--    files move the first time they're used), brings this computer's
--    updates up to date (ccnix update), and sets the settings the apps
--    want.
--  * On a server without it (stock CC: Tweaked), setup fetches the latest
--    git, clones the repo into /ccnix, or pulls it if it's there (an
--    install at /cc-turtles, the folder until 2026-10-29, is moved there
--    first, and its saved remote, the repo's name before it was ccnix,
--    is pointed at ccnix), sets the settings, and writes two lines into
--    the computer's startup that run deploy/boot.lua from the checkout:
--    `boot.lua` at the top of /startup.lua, `boot.lua --end` at the
--    bottom (or, with a /startup folder, /startup/00-ccnix.lua and
--    zz-ccnix.lua, which run first and last).  Lines an earlier install
--    wrote (any naming the checkout, or /cc-turtles) and its old startup
--    files go; your own lines stay.  A clone leaves out what the device
--    doesn't run (sim/, and pc/ on a turtle or turtle/ on a computer):
--    see bin/git.lua.  With HTTP off on the server, a checkout put there
--    by hand (in /ccnix, or wherever this setup.lua runs from) is set up
--    as it is.
--
-- Then it reboots (--no-reboot: from a checkout, boot runs in this shell
-- instead).  Run it again any time: naming apps again changes what's
-- there, naming none keeps the choice; `ccnix update` updates either
-- way.  It's also the way out of a clone that filled the disk part way:
-- what that left in the folders a clone leaves out, and Lua files in the
-- top folder from before bin/ and turtle/, are deleted; the rest is kept
-- and finished.  git runs from memory, so a full disk is no bar to
-- starting.  An old bootstrap copy of git at /git.lua is removed, since
-- the repo has its own in bin/.
--
-- deploy/boot.lua is apart from this on purpose: it runs at every boot
-- (from the ROM's autorun, or from the startup lines this writes) and
-- says what startup does; setup runs once, to put things in place.

local REPO = "https://github.com/djt-code/ccnix"
local RAW = "https://raw.githubusercontent.com/djt-code/ccnix/main/"
local DIR = "/ccnix"

-- What each app needs.  A path ending in / is a whole folder.
local TURTLE = { "turtle/turtlelib.lua", "turtle/home.lua", "turtle/autostart.lua" }
local NET = { "bin/ip.lua", "bin/ping.lua", "bin/traceroute.lua", "bin/nc.lua", "bin/host.lua", "bin/netstat.lua", "bin/tcpdump.lua", "bin/curl.lua", "lib/net.lua",
              "lib/netdb.lua", "lib/httpc.lua", "lib/cu.lua", "help/network.txt" }
local INIT = { "bin/init.lua", "bin/ps.lua", "bin/kill.lua", "bin/service.lua", "lib/proc.lua", "lib/cu.lua",
               "bin/syslogd.lua", "bin/logger.lua", "lib/log.lua", "lib/syslogd.lua", "help/syslog.txt" }
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
    httpd = { "bin/httpd.lua", "lib/httpd.lua", "lib/etlua.lua", "lib/etlua-license.txt", "help/httpd-pages.txt", NET, INIT },
}
local ALWAYS = { "bin/git.lua", "lib/pager.lua", "deploy/", "help/ccnix.txt", "help/setup.txt" }
local AUTOSTART = turtle and { mine = true, farm = true, mow = true, autocompost = true } or { router = true }

local cloneArgs, apps = {}, {}
local autostart, example, noReboot, login, netBoot, router, initBoot
local args = { ... }
local i = 1
while i <= #args do
    local a = args[i]
    if a == "--ccsh" then login = true
    elseif a == "--net" then netBoot = true
    elseif a == "--router" then netBoot, router = true, true
    elseif a == "--init" then initBoot = true
    elseif a == "--no-reboot" then noReboot = true
    elseif a == "--all" then cloneArgs[#cloneArgs + 1] = a
    elseif a == "--skip" and args[i + 1] then
        cloneArgs[#cloneArgs + 1] = a
        cloneArgs[#cloneArgs + 1] = args[i + 1]
        i = i + 1
    elseif a == "--example" then
        example = true
    elseif a == "--autostart" and AUTOSTART[args[i + 1]] then
        autostart = args[i + 1]
        if autostart == "router" then netBoot, router = true, true end
        i = i + 1
    elseif APPS[a] then
        apps[#apps + 1] = a
    else
        print("Usage: setup [app...] [--autostart app] [--example] [--ccsh] [--net] [--router] [--init] [--no-reboot] [--all] [--skip dir]...")
        local names = {}
        for name in pairs(APPS) do names[#names + 1] = name end
        table.sort(names)
        print("Apps: " .. table.concat(names, " "))
        print("--autostart: " .. (turtle and "mine, farm, mow or autocompost" or "router"))
        return
    end
    i = i + 1
end
if example then                    -- (the guestbook is httpd's)
    local named = false
    for _, a in ipairs(apps) do named = named or a == "httpd" end
    if not named then apps[#apps + 1] = "httpd" end
end
if autostart and #apps > 0 then
    local named = false
    for _, a in ipairs(apps) do named = named or a == autostart end
    if not named then apps[#apps + 1] = autostart end
end
-- what the apps want set
for _, a in ipairs(apps) do
    if a == "ccsh" then login = true end
    if a == "net" or a == "telnet" or a == "telnetd" or a == "httpd" then netBoot = true end
    if a == "router" then netBoot, router = true, true end
    if a == "init" or a == "telnetd" or a == "httpd" then initBoot = true end
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

-- syslogd, telnetd, httpd: services init starts at every boot (syslogd
-- with init, unless it's set up already; httpd's root made, with a first
-- page, if it isn't there; --example: the guestbook in its script root).
-- from(path): a repo file's path on this computer.
local function services(from)
    local list = { table.unpack(apps) }
    if initBoot then list[#list + 1] = "init" end      -- (--init, the app unnamed: syslogd too)
    for _, a in ipairs(list) do
        if (a == "init" or a == "telnetd" or a == "httpd") and not settings.get("service.syslogd.cmd") then
            settings.set("service.syslogd.cmd", "syslogd")
            settings.set("service.syslogd.enabled", true)
            settings.save()
            print("syslogd keeps the system log (/var/log): `help syslog`")
        end
        if a == "telnetd" or a == "httpd" then
            settings.set("service." .. a .. ".cmd", a)
            settings.set("service." .. a .. ".enabled", true)
            settings.save()
        end
        if a == "telnetd" and not settings.get("telnetd.password") then
            print("telnetd needs a password: set telnetd.password <password> (then reboot, or service start telnetd)")
        end
        if a == "httpd" then
            local root = settings.get("httpd.root") or "/www"
            if not fs.exists(root) then
                fs.makeDir(root)
                local f = fs.open(fs.combine(root, "index.html"), "w")
                f.write("<!DOCTYPE html>\n<html><head><meta charset=\"utf-8\"><title>" .. (os.getComputerLabel() or ("computer " .. os.getComputerID()))
                    .. "</title></head>\n<body><h1>It works</h1><p>ccnix's httpd, serving " .. root .. ".</p>"
                    .. "<p>A Lua page: <a href=\"cgi/hello\">cgi/hello</a>.</p></body></html>\n")
                f.close()
                f = fs.open(fs.combine(root, "cgi/hello.lua"), "w")
                f.write("-- a Lua page (help httpd-pages): /cgi/hello\n"
                    .. "write(\"<h1>Hello, \", html(req.params.name or \"world\"), \"</h1>\")\n"
                    .. "write(\"<form method=post><input name=name> <button>Hi</button></form>\")\n")
                f.close()
                print("httpd serves " .. root .. " (a first index.html is there, and cgi/hello.lua)")
            end
            if example then
                -- the script root, as httpd finds it
                local cgi = settings.get("httpd.cgi")
                if cgi == nil then cgi = "cgi" end
                if cgi == "" or cgi == false then
                    print("httpd.cgi is \"\" (no Lua pages): no guestbook")
                else
                    cgi = tostring(cgi)
                    local dir = fs.combine(cgi:sub(1, 1) == "/" and cgi or fs.combine(root, cgi), "")
                    for _, name in ipairs({ "guestbook.lua", "guestbook.etlua" }) do
                        local src = fs.open(from("deploy/examples/" .. name), "r")
                        local text = src.readAll()
                        src.close()
                        local dst = fs.open(fs.combine(dir, name), "w")
                        dst.write(text)
                        dst.close()
                    end
                    -- its URL: its path in the document root, or /<its name> outside it
                    local top = fs.combine(root, "")
                    local url = top == "" and dir or (dir:sub(1, #top + 1) == top .. "/" and dir:sub(#top + 2) or fs.getName(dir))
                    print("A guestbook in /" .. dir .. ": http://<this computer>/" .. url .. "/guestbook")
                end
            end
        end
    end
    -- with init, a turtle's job is a service of its own name, not the
    -- console's: what it prints goes in the system log, and the console
    -- is free.  `autostart --now` picks the job up as at boot; when the
    -- job ends, it isn't started again.
    local job = autostart or settings.get("ccnix.autostart")
    if turtle and AUTOSTART[job] and (initBoot or settings.get("init.boot") == true)
            and not settings.get("service." .. job .. ".cmd") then
        settings.set("service." .. job .. ".cmd", "autostart --now")
        settings.set("service." .. job .. ".restart", "no")
        settings.set("service." .. job .. ".enabled", true)
        settings.save()
        print(job .. " runs as a service under init: `service status " .. job .. "`, its log in /var/log/messages (`tail -f`).")
    end
end

-- The settings the apps want; from a checkout, the two startup lines
-- that run its deploy/boot.lua (repo: the checkout); then the reboot.
local function configure(repo, romMode)
    local boot = repo .. "/deploy/boot.lua"
    local first = string.format('shell.run("%s")', boot)
    local last = string.format('shell.run("%s", "--end")', boot)

    local function read(path)
        if not fs.exists(path) then return nil end
        local f = fs.open(path, "r")
        local s = f.readAll()
        f.close()
        return s
    end

    local function write(path, s)
        local f = fs.open(path, "w")
        if not f then printError("Can't write " .. path); error("", 0) end
        f.write(s)
        f.close()
    end

    -- a startup file's lines less an earlier install's: ours, or any from
    -- before (the path lines, the shell's, the autostart's) name the repo
    local function kept(path)
        local lines = {}
        for line in ((read(path) or "") .. "\n"):gmatch("(.-)\n") do
            if not (line:find(repo .. "/", 1, true) or line:find("/cc-turtles/", 1, true)) then lines[#lines + 1] = line end
        end
        if lines[#lines] == "" then lines[#lines] = nil end         -- (the file's own last newline)
        return lines
    end

    if not romMode then
        local target
        if fs.isDir("/startup") then
            target = "/startup/00-ccnix.lua"
            for _, old in ipairs({ "00-cc-turtles", "zx-init", "zy-autostart", "zz-ccsh", "zz-craftix" }) do
                if fs.exists("/startup/" .. old .. ".lua") then fs.delete("/startup/" .. old .. ".lua") end
            end
            if read(target) == first .. "\n" and read("/startup/zz-ccnix.lua") == last .. "\n" then
                print(target .. " and zz-ccnix.lua run " .. boot .. " already.")
            else
                write(target, first .. "\n")
                write("/startup/zz-ccnix.lua", last .. "\n")
                print("Put " .. boot .. " in " .. target .. " and, with --end, /startup/zz-ccnix.lua.")
            end
        else
            target = "/startup.lua"
            local lines = kept(target)
            table.insert(lines, 1, first)
            lines[#lines + 1] = last
            local text = table.concat(lines, "\n") .. "\n"
            if text == read(target) then
                print(target .. " runs " .. boot .. " already.")
            else
                write(target, text)
                print("Put " .. boot .. " first in " .. target .. ", and with --end last.")
            end
        end
    end
    if login then
        settings.set("ccsh.login", true)
        settings.save()
        print("ccsh starts at boot.")
    end
    if netBoot then
        settings.set("net.boot", true)
        if router then settings.set("net.forward", true) end
        settings.save()
        print("The network comes up at boot" .. (router and ", forwarding (a router)" or "") .. ": `help network` says how to set it up.")
    end
    if initBoot then
        settings.set("init.boot", true)
        settings.save()
        print("init starts at boot: `help init`; ps, kill and service work then.")
    end
    if autostart then
        settings.set("ccnix.autostart", autostart)
        settings.save()
        print("At boot this " .. (turtle and "turtle" or "computer") .. " runs " .. autostart
            .. (turtle and ": `help autostart` says how." or " (its status screen; q leaves it, routing goes on)."))
    end

    if noReboot then
        -- this shell gets it now; others after a reboot
        if not romMode then shell.run(boot) end
        print(romMode and "Not rebooting: the settings take effect at the next boot."
            or "Not rebooting: on the path in this shell now, everywhere after a reboot.")
        if login then print("Type ccsh to start it now.") end
        return
    end
    print("Rebooting in 3 seconds (Ctrl+T to cancel)...")
    sleep(3)
    os.reboot()
end

-- ccnix in ROM: the settings, an old install moved over, the updates
if fs.exists("/rom/ccnix/.manifest") then
    local function find(path)
        return ccnix and ccnix.find and ccnix.find(path) or "/rom/ccnix/" .. path
    end
    print("ccnix is in this server's ROM: nothing to clone.")
    if fs.exists("/cc-turtles/.gitlite") then
        -- its startup lines: the ones setup wrote (and ip's, the old Craftix's) go;
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
    services(find)
    if http then shell.run(find("bin/ccnix.lua"), "update")
    else print("HTTP is off here: no updates over the ROM's.") end
    configure("/rom/ccnix", true)
    return
end

-- A checkout this setup.lua runs from (one put there by hand), if any
local here = "/" .. fs.getDir(fs.getDir(shell.getRunningProgram() or ""))
if not (fs.exists(fs.combine(here, "deploy/boot.lua")) and here ~= "/rom/ccnix") then here = nil end

if not http then
    local repo = here or (fs.exists(fs.combine(DIR, "deploy/boot.lua")) and DIR)
    if not repo then
        die("HTTP is disabled on this server, and there's no checkout to set up: put the repo in " .. DIR .. " by hand (the README says how), then run " .. DIR .. "/deploy/setup.")
    end
    print("HTTP is off here: setting up the checkout in " .. repo .. " as it is.")
    services(function(p) return fs.combine(repo, p) end)
    configure(repo, false)
    return
end

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
-- moved (configure swaps its startup lines; a turtle's job files come along)
if fs.exists("/cc-turtles/.gitlite") and not fs.exists(DIR) then
    fs.move("/cc-turtles", DIR)
    print("Moved /cc-turtles to " .. DIR .. ", where ccnix lives now.")
end
-- and the repo was cc-turtles then: a checkout from then pulls from ccnix
do
    local p = fs.combine(DIR, ".gitlite")
    if fs.exists(p) then
        local f = fs.open(p, "r")
        local state = (textutils.unserialiseJSON or textutils.unserializeJSON)(f.readAll() or "")
        f.close()
        if type(state) == "table" and type(state.url) == "string" and state.url:find("/djt%-code/cc%-turtles") then
            state.url = REPO
            f = fs.open(p, "w")
            f.write((textutils.serialiseJSON or textutils.serializeJSON)(state))
            f.close()
            print("Pointed " .. DIR .. " at the repo's new name, ccnix.")
        end
    end
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

services(function(p) return fs.combine(DIR, p) end)
configure(DIR, false)
