-- ircd.lua -- an IRC server, with services and a bridge to the game's chat
--
--   ircd [-p port]                  serve IRC until Ctrl+T
--
-- A small IRC server in the manner of ngIRCd: one server (no links to
-- others), the commands clients use (lib/ircd: NICK, JOIN, PRIVMSG,
-- MODE, TOPIC, KICK, WHOIS, WHO, LIST, AWAY, OPER...), channels with
-- their operators, bans, keys and limits.  Any IRC client works: irc
-- here, or HexChat or irssi on a real machine through the ccnix mod's
-- gateway.
--
-- Services come with it (lib/ircserv), as users:
--   NickServ   REGISTER, IDENTIFY, GHOST... keeps nicks for their owners;
--              VERIFY <player> ties a nick to a Minecraft player (a code
--              whispered in the game, CONFIRM <code> in IRC)
--   ChanServ   REGISTER #chan keeps a channel's founder, topic and
--              auto-ops (OP, DEOP, AOP)
--   MC         the game: PLAYERS, TIME, WEATHER, TELL <player> <text>
-- MC sits in the bridge channel, #minecraft: what's said there goes into
-- the game's chat, and the game's chat (and joins, leaves, deaths) comes
-- back.  It uses what's attached to this computer: an Advanced
-- Peripherals Chat Box (chat both ways), Player Detector (who's on,
-- joins and leaves) and Environment Detector (weather); a command
-- computer can speak and list players without them.  The world's clock
-- needs nothing.
--
-- As a service (init keeps it running, and starts it again if it ends):
--   setup ircd                      all of it at once: the files, the network
--                                   and init at boot, the service enabled
-- or by hand:
--   service add ircd ircd           the service (-p port can follow)
--   service enable ircd             started at every boot
--   service start ircd              started now
--   service status ircd             running?  its last lines, how it last ended
--   service stop ircd               stopped (QUIT to everyone: "Server shutting down")
--   service disable ircd            not at boot any more
--   service remove ircd             gone (its settings and data stay)
-- Its log is the system log's (`help syslog`): connections, operators,
-- what it found to talk to the game with, under the name ircd.  Change a
-- setting with sysctl, then `service restart ircd`:
--   sysctl ircd.oper=hunter2        an operator password
--   sysctl ircd.bridge=             no bridge channel
--   sysctl ircd.name=irc.lab        the server's name
--
-- Settings, which -p overrides:
--   ircd.port       the TCP port (6667)
--   ircd.name       the server's name (irc.<this computer's label>, or irc.ccnix)
--   ircd.network    the network's name (ccnix)
--   ircd.motd       the message of the day, a file (/etc/ircd.motd)
--   ircd.password   a password every client must give (PASS); unset: none
--   ircd.oper       OPER's password (OPER <any name> <password>); unset: no operators
--   ircd.bridge     the channel bridged to the game's chat (#minecraft; "" for none)
--   ircd.data       where the services keep nicks and channels (/etc/ircd.db)
--   ircd.facility   the system log's facility (daemon; `help syslog`)
--
-- The message of the day is the file, a line each; edit it and restart.
-- The services' data is textutils.serialize'd; deleting the file forgets
-- every registered nick and channel.
--
-- It needs the network (`ip up`).  Then `irc <this computer>` from any
-- computer on the network (`ip host irc 10.1.1.5` gives it a name), or
-- from a real machine through the gateway.  Run in the foreground (just
-- `ircd`), it logs to the screen too, and Ctrl+T stops it.

package.path = (ccnix and ccnix.lib or "/" .. fs.getDir(fs.getDir(shell.getRunningProgram())) .. "/lib/?.lua;") .. package.path  -- ccnix's lib/, or the one beside bin/
local cu = require("cu").init("ircd", "ircd [-p port]")
local net = require("net")
local irc = require("irc")
local scan = require("scan")
local ircd = require("ircd")
local ircserv = require("ircserv")
local mcLib = require("mc")

local opts, operands = cu.getopt({ ... }, "p:")
if #operands > 0 then cu.usageError() end
local port = tonumber(opts.p or settings.get("ircd.port") or 6667)
if not port or port < 1 or port > 65535 or port % 1 ~= 0 then cu.usageError("bad port " .. tostring(opts.p or settings.get("ircd.port"))) end

local syslog = require("log").new("ircd", settings.get("ircd.facility") or "daemon", { perror = true })
local label = os.getComputerLabel and os.getComputerLabel()
-- irc.<the label>, its characters other than letters, digits and - as -
local function hostPart(s)
    local out = {}
    for i = 1, #s do
        local c = s:sub(i, i)
        out[i] = (scan.isAlnum(c) or c == "-") and c or "-"
    end
    return table.concat(out)
end
local defaultName = label and ("irc." .. hostPart(label:lower())) or "irc.ccnix"

local function readLines(path)
    if not fs.exists(path) then return nil end
    local h = fs.open(path, "r")
    if not h then return nil end
    local out = scan.lines(h.readAll() or "")
    h.close()
    while out[#out] == "" do out[#out] = nil end
    return out
end

local motdPath = settings.get("ircd.motd") or "/etc/ircd.motd"
local motd = readLines(motdPath) or {
    "Welcome to ccnix's ircd, on a ComputerCraft computer.",
    "NickServ, ChanServ and MC are here: /msg them HELP.",
    "#minecraft is the game's chat.",
}

local dataPath = settings.get("ircd.data") or "/etc/ircd.db"
local function loadDb()
    if not fs.exists(dataPath) then return nil end
    local h = fs.open(dataPath, "r")
    local text = h and h.readAll()
    if h then h.close() end
    return text and textutils.unserialize(text)
end
local function saveDb(db)
    local dir = fs.getDir(dataPath)
    if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
    local h = fs.open(dataPath, "w")
    if not h then syslog.err("can't write " .. dataPath); return end
    h.write(textutils.serialize(db))
    h.close()
end

local srv = ircd.new({
    name = settings.get("ircd.name") or defaultName,
    network = settings.get("ircd.network") or "ccnix",
    motd = motd,
    password = settings.get("ircd.password"),
    oper = settings.get("ircd.oper"),
    log = function(s) syslog.info(s) end,
})
local mc = mcLib.new()
local bridge = settings.get("ircd.bridge")
if bridge == nil then bridge = "#minecraft" end
local services = ircserv.attach(srv, { load = loadDb, save = saveDb, mc = mc, bridge = bridge })

local listener, err = net.listen(port)
if not listener then cu.fail("port " .. port .. ": " .. err); return cu.exit() end
local can = {}
for k, v in pairs(mc.has) do can[#can + 1] = k .. " (" .. tostring(v) .. ")" end
table.sort(can)
syslog.info(srv.name .. " listening on port " .. port .. "; the game: " .. (#can > 0 and table.concat(can, ", ") or "the clock only"))

local conns = {}            -- connection id -> { conn, client, buf }

local function drop(id)
    local k = conns[id]
    conns[id] = nil
    if k and k.conn:state() ~= "CLOSED" then k.conn:close() end
end

-- Close the connections the server is done with (QUIT, KILL, ping timeout).
local function sweep()
    for id, k in pairs(conns) do
        if k.client.dead then drop(id) end
    end
end

local function serve(id)
    local k = conns[id]
    while k do
        local data, why = k.conn:read(0)
        if data then
            local lines
            lines, k.buf = irc.lines(k.buf .. data)
            for _, line in ipairs(lines) do srv:input(k.client, line) end
            if #k.buf > 4096 then k.buf = "" end            -- (no line end in sight: dropped)
        elseif why == "timeout" then
            break
        else
            srv:closed(k.client, why == "closed" and "Connection closed" or ("Read error: " .. tostring(why)))
            break
        end
    end
end

local POLL_EVERY = 10       -- seconds between asking who's on (without a detector's events)
local ticks = 0
local timer = os.startTimer(1)
local ok, e = pcall(function()
    while true do
        local ev = table.pack(os.pullEventRaw())
        local name = ev[1]
        if name == "terminate" then return
        elseif name == "net_accept" and ev[2] == port then
            local c = listener:poll()
            while c do
                local conn = c
                local client = srv:connect(function(line) conn:send(line .. "\r\n") end, (conn:remote()))
                conns[conn:id()] = { conn = conn, client = client, buf = "" }
                c = listener:poll()
            end
        elseif name == "net_tcp" and conns[ev[2]] then
            serve(ev[2])
        elseif name == "timer" and ev[2] == timer then
            srv:tick()
            ticks = ticks + 1
            if ticks % POLL_EVERY == 0 then
                for _, game in ipairs(mc.poll()) do services.mcEvent(game) end
            end
            timer = os.startTimer(1)
        else
            services.mcEvent(mc.event(table.unpack(ev, 1, ev.n)))
        end
        sweep()
    end
end)
for _, k in pairs(conns) do
    if not k.client.dead then srv:quit(k.client, "Server shutting down") end
end
sweep()
listener:close()
if not ok then error(e, 0) end
syslog.info("stopped")
return cu.exit()
