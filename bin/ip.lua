-- ip.lua -- set up and look at the network (lib/net.lua)
--
--   ip                               the interfaces, routes and whether it's up
--   ip up | ip down                  start or stop the network on this computer
--   ip boot [off]                    start it at every boot: the setting net.boot,
--                                    which startup goes by (setup's net and router
--                                    apps turn it on)
--   ip link                          the modems there are, their MACs, and which
--                                    are set up
--   ip addr                          the interfaces' addresses and counts
--                                    (-d: their MACs too)
--   ip addr add <iface> <addr/len>   give an interface an address
--   ip addr del <iface>
--   ip route                         the routing table
--   ip route add <net/len|default> via <gw> [dev <iface>]
--   ip route del <net/len|default>
--   ip route get <addr> [dev <iface>]
--                                    the way a packet to addr would go: the
--                                    next hop (via), interface, source
--                                    address, the route that picked them,
--                                    and what ARP knows of the next hop
--   ip neigh                         the ARP cache: addresses, their MACs and
--                                    the seconds each is kept for yet
--                                    (permanent: set by hand); and those
--                                    being asked for, not yet answered
--                                    (INCOMPLETE), with the packets waiting
--   ip neigh add <addr> lladdr <mac> [dev <iface>]
--                                    a permanent entry: addr is at mac (never
--                                    asked for, never expires, not changed by
--                                    what ARP hears); dev: the interface, if
--                                    not the one whose network addr is on
--   ip neigh del <addr> [dev <iface>]
--                                    forget addr's entry, permanent or learned
--   ip forward [on|off]              route between interfaces (a router)
--   ip rpfilter [strict|loose|off]   which sources a router passes on (BCP 38):
--                                    loose (the default) any it has a route
--                                    back to, strict only those whose route
--                                    back leaves by the interface the packet
--                                    came in on, off all.  A packet from a
--                                    source that can't be (0.x, 127.x, 224.x
--                                    and up, the network's broadcast
--                                    address, this computer's own) is
--                                    dropped whatever it's set to.  On a
--                                    router whose default route covers
--                                    everything, loose stops only those:
--                                    strict is the one that keeps a
--                                    network's hosts from forging another's
--                                    addresses
--   ip host [<name> <addr>]          names for addresses (ping router)
--   ip host del <name>               forget one
--   ip dns [<primary> [<secondary>] | off]
--                                    the DNS servers names are looked up at
--                                    after the hosts (lib/netdb); none: the
--                                    hosts alone
--   ip dns cache                     the answers kept (each name's, "no such
--                                    name" too, for the seconds its TTL
--                                    says) and the servers asked last for
--                                    now, having failed
--   ip dns flush                     forget them all: the next lookup asks
--   ip help                         the commands, and how short each may be
--
-- Words may be shortened, as iproute2's may, as far as they stay clear:
-- `ip a` is ip address, `ip r a 10.0.3.0/24 v 10.0.1.1` ip route add ...
-- via, `ip n` ip neighbour, `ip rp strict` ip rpfilter; `ip help` shows how
-- short each command may be.  One too short to tell apart (`ip d`: down or
-- dns?) is refused, with what it could be.
--
-- Options go before the command: -d (-details, or any cut between) adds
-- the details, as iproute2's does: the MACs in `ip -d addr` and plain `ip`.
--
-- An interface is a modem by its peripheral name ("back", "modem_0"), or a
-- VLAN on one: "back.20" is VLAN 20 on the back modem, its own network on
-- the same wire.  What's set is kept in settings (net.if.<iface>,
-- net.routes, net.neigh, net.forward, net.rpfilter, net.hosts, net.dns) and applies at
-- once if the network is up.  The network runs alongside everything else once `ip up` has
-- started it: see lib/net.lua.  `help network` walks through setting up
-- two networks and a router.

package.path = (ccnix and ccnix.lib or "/" .. fs.getDir(fs.getDir(shell.getRunningProgram())) .. "/lib/?.lua;") .. package.path  -- ccnix's lib/, or the one beside bin/
local cu = require("cu").init("ip", nil)
local net = require("net")
local scan = require("scan")
local text = require("text")
local args = { ... }

-- options, before the command: -d[etails] (one or two dashes, any cut)
local details = false
-- an option: "-" or "--", then a name starting with a letter; the name, or nil
local function optionName(a)
    if type(a) ~= "string" then return nil end
    local sc = scan.new(a)
    if not sc:accept("-") then return nil end
    sc:accept("-")
    if not scan.isAlpha(sc:peek()) then return nil end
    return sc:rest()
end
while optionName(args[1]) do
    local o = table.remove(args, 1)
    local name = optionName(o):lower()
    if text.startsWith("details", name) then details = true
    else
        cu.err('no option "' .. o .. '"')
        printError("usage: ip [-d[etails]] [<command> ...]  (ip help lists the commands)")
        return cu.exit(2)
    end
end

local function out(...) io.write(...) io.write("\n") end
local function save() settings.save() end

--------------------------------------------------------------------------
-- Words, and how short each may be
--------------------------------------------------------------------------
-- A word: { name, shortest, aliases... }: it's taken as any prefix of its
-- name (or an alias) at least `shortest` letters long, chosen so no two
-- words of a list share one.
local COMMANDS = {
    { "up", 1, args = "", what = "start the network on this computer" },
    { "down", 2, args = "", what = "stop it" },
    { "boot", 1, args = "[off]", what = "start it at every boot (or not)" },
    { "link", 1, args = "", what = "the modems, their MACs, which are set up" },
    { "address", 1, args = "[show | add <iface> <addr/len> | del <iface>]",
      what = "the interfaces' addresses (-d: MACs)" },
    { "route", 1, args = "[show | add <net/len|default> via <gw> [dev <iface>] | del <net/len|default> | get <addr> [dev <iface>]]",
      what = "the routing table" },
    { "neighbour", 1, "neighbor", args = "[show | add <addr> lladdr <mac> [dev <iface>] | del <addr> [dev <iface>]]",
      what = "the ARP cache" },
    { "forward", 1, args = "[on|off]", what = "route between interfaces (a router)" },
    { "rpfilter", 2, args = "[strict|loose|off]", what = "which sources a router passes on (BCP 38)" },
    { "host", 1, args = "[<name> <addr> | del <name>]", what = "names for addresses" },
    { "dns", 2, args = "[<primary> [<secondary>] | off | cache | flush]", what = "the DNS servers" },
    { "help", 2, args = "", what = "this list" },
}
local SHOW = { { "show", 1, "list", "ls" } }
local ADDR_SUBS = { SHOW[1], { "add", 1 }, { "delete", 1 } }
local ROUTE_SUBS = { SHOW[1], { "add", 1 }, { "delete", 1 }, { "get", 1 } }
local NEIGH_SUBS = ADDR_SUBS
local HOST_SUBS = { { "delete", 1 } }
local DNS_WORDS = { { "off", 2 }, { "cache", 1 }, { "flush", 1 } }
local ONOFF = { { "on", 2 }, { "off", 2 } }
local RPMODES = { { "strict", 1 }, { "loose", 1 }, { "off", 1 } }

-- "a[ddress]": the word as short as it may be, then the rest.
local function shortForm(w) return w[1]:sub(1, w[2]) .. (#w[1] > w[2] and ("[" .. w[1]:sub(w[2] + 1) .. "]") or "") end
local function shortForms(list)
    local t = {}
    for _, w in ipairs(list) do t[#t + 1] = shortForm(w) end
    return table.concat(t, " ")
end

local function distance(a, b)
    local prev = {}
    for j = 0, #b do prev[j] = j end
    for i = 1, #a do
        local cur = { [0] = i }
        for j = 1, #b do
            cur[j] = math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a:sub(i, i) == b:sub(j, j) and 0 or 1))
        end
        prev = cur
    end
    return prev[#b]
end

-- The word in `list` that `s` stands for; else nil and why.
local function pick(s, list)
    if type(s) ~= "string" or s == "" then return nil, "nothing" end
    s = s:lower()
    local found, short = {}, {}
    for _, w in ipairs(list) do
        for k = 1, #w do
            local name = k == 1 and w[1] or w[k + 1]
            if type(name) == "string" and text.startsWith(name, s) then
                if #s >= w[2] then found[#found + 1] = w else short[#short + 1] = w end
                break
            end
        end
    end
    if #found == 1 then return found[1][1] end
    if #short > 0 then
        local names, forms = {}, {}
        for _, w in ipairs(short) do names[#names + 1] = w[1]; forms[#forms + 1] = shortForm(w) end
        return nil, string.format('"%s" could be %s: say %s', s, table.concat(names, " or "), table.concat(forms, " or "))
    end
    local best, bestD
    for _, w in ipairs(list) do
        local d = distance(s, w[1])
        if d <= 2 and d < #w[1] and (not bestD or d < bestD) then best, bestD = w[1], d end
    end
    return nil, string.format('no "%s"', s) .. (best and string.format(' (did you mean "%s"?)', best) or "")
end

local function usageLine(cmd)
    for _, w in ipairs(COMMANDS) do
        if w[1] == cmd then return "ip " .. shortForm(w) .. (w.args ~= "" and (" " .. w.args) or "") end
    end
end

-- A mistake with a command's words: why, then that command's usage.
local function badWords(cmd, why)
    cu.err(cmd .. ": " .. why)
    printError("usage: " .. usageLine(cmd))
    cu.exit(2)
end

local function help(to)
    to("usage: ip [-d[etails]] [<command> ...]; each word may be cut short, to its part")
    to("outside the brackets or longer (ip a, ip r a ... v ..., ip n):")
    for _, w in ipairs(COMMANDS) do
        local use = shortForm(w) .. (w.args ~= "" and (" " .. w.args) or "")
        if #use <= 24 then to(string.format("  %-24s %s", use, w.what))
        else to(string.format("  %-24s %s", shortForm(w), w.what)); to("    " .. w.args) end
    end
    to("ip alone: whether it's up, the interfaces and routes.  help ip says more.")
end

--------------------------------------------------------------------------
-- Showing
--------------------------------------------------------------------------
-- the routes setting, as a list of { net, gw, iface }
local function savedRoutes() return net.config().routes end
local function saveRoutes(list)
    local t = {}
    for _, r in ipairs(list) do t[#t + 1] = r.net .. " via " .. r.gw .. (r.iface and (" dev " .. r.iface) or "") end
    settings.set("net.routes", table.concat(t, ", "))
    save()
end

local function showAddr(S)
    if S then
        local names = {}
        for k in pairs(S.ifaces) do names[#names + 1] = k end
        table.sort(names)
        for _, name in ipairs(names) do
            local i = S.ifaces[name]
            out(string.format("%-12s %-18s %srx %d tx %d%s", name, net.cidrString(i.ip, i.len),
                details and (i.mac .. " ") or "", i.rx, i.tx, i.vlan and (" (vlan " .. i.vlan .. ")") or ""))
        end
    else
        local cfg = net.config()
        local names = {}
        for k in pairs(cfg.ifaces) do names[#names + 1] = k end
        table.sort(names)
        for _, name in ipairs(names) do
            local modem = net.link(name)
            out(string.format("%-12s %-18s %s(not up)", name, cfg.ifaces[name],
                details and modem and (net.mac(os.getComputerID(), modem) .. " ") or ""))
        end
        if #names == 0 then out("no interfaces: ip addr add <iface> <addr/len>  (ip link lists the modems)") end
    end
end

local function showRoutes(S)
    if S then
        local list = {}
        for _, r in ipairs(S.routes) do list[#list + 1] = r end
        table.sort(list, function(a, b) if a.len ~= b.len then return a.len > b.len end return a.net < b.net end)
        for _, r in ipairs(list) do
            local dest = r.len == 0 and "default" or net.cidrString(r.net, r.len)
            out(string.format("%-18s %s dev %s", dest, r.gw and ("via " .. net.ipString(r.gw)) or "direct", r.iface))
        end
    else
        for _, r in ipairs(savedRoutes()) do
            out(string.format("%-18s via %s%s (not up)", r.net, r.gw, r.iface and (" dev " .. r.iface) or ""))
        end
    end
end

-- What ARP knows of a neighbour (S.neighbour's), after its interface:
-- permanent, the seconds it's kept for yet, or the packets waiting on it.
local function neighState(n)
    if n.state == "permanent" then return "permanent" end
    if n.state == "reachable" then return string.format("%d s left", math.ceil(n.left)) end
    return string.format("%d queued, asked %d time%s", n.queued, n.tries, n.tries == 1 and "" or "s")
end

--------------------------------------------------------------------------
-- The commands
--------------------------------------------------------------------------
local S = net.stack()
local cmd
if args[1] ~= nil then
    local why
    cmd, why = pick(args[1], COMMANDS)
    if not cmd then
        local unknown = text.stripPrefix(why, 'no "')
        cu.err(unknown and ('no command "' .. unknown) or why)
        printError("commands: " .. shortForms(COMMANDS))
        printError("ip help says what each does")
        return cu.exit(2)
    end
end
-- the n-th word as one of `list` (absent: nil), or a usage error
local function word(n, list, default)
    if args[n] == nil then return default end
    local w, why = pick(args[n], list)
    if not w then badWords(cmd, why) end
    return w
end
local function noMore(n) if args[n] ~= nil then badWords(cmd, 'what\'s "' .. args[n] .. '"?') end end

if cmd == nil then
    out(S and ("up" .. (S.forward and (", forwarding (rpfilter " .. S.rpfilter .. ")") or "")) or "down (ip up starts it)")
    showAddr(S)
    showRoutes(S)
    local dns = net.config().dns
    if #dns > 0 then out("dns " .. table.concat(dns, ", ")) end
elseif cmd == "help" then
    help(out)
elseif cmd == "up" then
    noMore(2)
    local S2, problems = net.up()
    for _, p in ipairs(problems) do cu.err(p) end
    local n = 0
    for _ in pairs(S2.ifaces) do n = n + 1 end
    out(string.format("up: %d interface%s%s", n, n == 1 and "" or "s", S2.forward and ", forwarding" or ""))
    if #problems > 0 then cu.exit(1) end
elseif cmd == "down" then
    noMore(2)
    out(net.down() and "down" or "it wasn't up")
elseif cmd == "boot" then
    -- the setting net.boot: startup brings the network up while it's on
    -- (deploy/boot, from the ROM's autorun or the startup lines setup writes)
    local on = word(2, ONOFF, "on") == "on"
    noMore(3)
    settings.set("net.boot", on)
    save()
    out(on and "the network starts at boot" or "the network doesn't start at boot")
elseif cmd == "link" then
    noMore(2)
    local cfg = net.config()
    local used, names = {}, {}
    for name in pairs(cfg.ifaces) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
        local modem = net.link(name)
        if modem then used[modem] = (used[modem] and (used[modem] .. " ") or "") .. name end
    end
    local any = false
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "modem" then
            any = true
            local wireless = peripheral.call(name, "isWireless")
            out(string.format("%-12s %-9s %s %s", name, wireless and "wireless" or "wired",
                net.mac(os.getComputerID(), name), used[name] or "(not set up)"))
        end
    end
    if not any then out("no modems") end
elseif cmd == "address" then
    local sub = word(2, ADDR_SUBS, "show")
    if sub == "show" then
        noMore(3)
        showAddr(S)
    elseif sub == "add" then
        local iface, cidr = args[3], args[4]
        if not (iface and cidr) then badWords(cmd, "add takes an interface and its address") end
        noMore(5)
        if not net.link(iface) then badWords(cmd, "bad VLAN in " .. iface .. " (1-4094)") end
        if not net.parseCIDR(cidr) or not text.contains(cidr, "/") then badWords(cmd, "give the address with its prefix: 10.0.1.5/24") end
        settings.set("net.if." .. iface, cidr)
        save()
        if S then
            local modem, channel = net.link(iface)
            if peripheral.getType(modem) ~= "modem" then cu.fail("no modem called " .. modem .. " (saved anyway)")
            else peripheral.call(modem, "open", channel); S.addInterface(iface, cidr) end
        end
        out(iface .. " " .. cidr)
    else
        local iface = args[3]
        if not iface then badWords(cmd, "del takes the interface") end
        noMore(4)
        settings.unset("net.if." .. iface)
        save()
        if S and S.ifaces[iface] then
            local i = S.ifaces[iface]
            S.removeInterface(iface)
            pcall(peripheral.call, i.modem, "close", i.channel)
        end
        out(iface .. " removed")
    end
elseif cmd == "route" then
    local sub = word(2, ROUTE_SUBS, "show")
    if sub == "show" then
        noMore(3)
        showRoutes(S)
    elseif sub == "get" then
        -- ip route get <addr> [dev <iface>]: the way sendIP would send to addr
        local addr, dev = args[3], nil
        if not addr then badWords(cmd, "get takes an address") end
        local n = 4
        while args[n] ~= nil do
            word(n, { { "dev", 1 } })
            if args[n + 1] == nil then badWords(cmd, "dev takes an interface") end
            dev = args[n + 1]
            n = n + 2
        end
        if not S then cu.fail("the network isn't up (ip up)"); return cu.exit() end
        local dst, why = net.parseIP(addr), nil
        if not dst then dst, why = net.resolve(addr) end
        if not dst then cu.fail(why); return cu.exit() end
        if dev and not S.ifaces[dev] then cu.fail("no interface " .. dev .. " (ip addr lists them)"); return cu.exit() end
        local way, err = S.routeGet(dst, dev)
        if not way then cu.fail(err .. " (network unreachable)"); return cu.exit() end
        local ip = net.ipString
        if way.kind == "local" then
            out("local " .. ip(dst) .. " dev lo src " .. ip(way.src))
        elseif way.kind == "broadcast" and not way.iface then
            out("broadcast " .. ip(dst) .. ": out of every interface, each from its own address")
        elseif way.kind == "broadcast" then
            out("broadcast " .. ip(dst) .. " dev " .. way.iface .. " src " .. ip(way.src))
        else
            out(ip(dst) .. (way.gw and (" via " .. ip(way.gw)) or "") .. " dev " .. way.iface .. " src " .. ip(way.src))
            local r = way.route
            out("    route " .. (r.len == 0 and "default" or net.cidrString(r.net, r.len))
                .. (r.gw and (" via " .. ip(r.gw)) or " direct") .. " dev " .. r.iface)
            local nb = way.neigh
            if nb.state == "incomplete" then
                out("    neigh " .. ip(way.hop) .. " INCOMPLETE: " .. neighState(nb) .. ", no answer yet")
            elseif nb.state then
                out("    neigh " .. ip(way.hop) .. " lladdr " .. nb.mac .. " " .. neighState(nb))
            else
                out("    neigh " .. ip(way.hop) .. " not in the ARP cache: the first packet asks for it")
            end
        end
    elseif sub == "add" then
        local dest, gw, dev = args[3], nil, nil
        if not dest then badWords(cmd, "add takes a network, via and the router") end
        local n = 4
        while args[n] ~= nil do
            local k = word(n, { { "via", 1 }, { "dev", 1 } })
            if args[n + 1] == nil then badWords(cmd, k .. " takes " .. (k == "via" and "the router's address" or "an interface")) end
            if k == "via" then gw = args[n + 1] else dev = args[n + 1] end
            n = n + 2
        end
        if not gw then badWords(cmd, "add takes via and the router: ip route add " .. dest .. " via <gw>") end
        local r = { net = dest, gw = gw, iface = dev }
        if not net.parseCIDR(r.net) then badWords(cmd, "bad network " .. r.net) end
        if not net.parseIP(r.gw) then badWords(cmd, "bad gateway " .. r.gw) end
        if S then
            local ok, err = S.addRoute(r.net, r.gw, r.iface)
            if not ok then cu.fail(err); return cu.exit() end
        end
        local list = {}
        for _, x in ipairs(savedRoutes()) do if x.net ~= r.net then list[#list + 1] = x end end
        list[#list + 1] = r
        saveRoutes(list)
        out(r.net .. " via " .. r.gw)
    else
        local dest = args[3]
        if not dest then badWords(cmd, "del takes the network") end
        noMore(4)
        local list, gone = {}, false
        for _, x in ipairs(savedRoutes()) do if x.net ~= dest then list[#list + 1] = x else gone = true end end
        saveRoutes(list)
        if S then gone = S.deleteRoute(dest) or gone end
        if not gone then cu.fail("no route " .. dest) end
    end
elseif cmd == "neighbour" then
    local sub = word(2, NEIGH_SUBS, "show")
    -- the permanent entries kept in the settings, and saving them
    local function saved() return net.config().neigh end
    local function keep(list)
        local t = {}
        for _, e in ipairs(list) do t[#t + 1] = e.ip .. " lladdr " .. e.mac .. (e.iface and (" dev " .. e.iface) or "") end
        settings.set("net.neigh", table.concat(t, ", "))
        save()
    end
    -- addr dev iface: dev and the interface, after the address
    local function devFrom(n)
        local dev
        while args[n] ~= nil do
            word(n, { { "dev", 1 } })
            if args[n + 1] == nil then badWords(cmd, "dev takes an interface") end
            dev = args[n + 1]
            n = n + 2
        end
        return dev
    end
    if sub == "show" then
        noMore(3)
        if S then
            -- address, MAC (INCOMPLETE: asked for, no answer yet), interface,
            -- then permanent, the seconds left, or what's waiting
            local list = S.neighbours()
            for _, n in ipairs(list) do
                out(string.format("%-16s %-17s dev %s %s", net.ipString(n.ip),
                    n.state == "incomplete" and "INCOMPLETE" or n.mac, n.iface, neighState(n)))
            end
            if #list == 0 then out("(empty)") end
        else
            for _, e in ipairs(saved()) do
                out(string.format("%-16s %-17s dev %s permanent", e.ip, net.parseMAC(e.mac) or e.mac, e.iface or "?"))
            end
            cu.fail("the network isn't up")
        end
    elseif sub == "add" then
        local addr = args[3]
        if not addr then badWords(cmd, "add takes an address, lladdr and its MAC") end
        local mac, dev
        local n = 4
        while args[n] ~= nil do
            local k = word(n, { { "lladdr", 1 }, { "dev", 1 } })
            if args[n + 1] == nil then badWords(cmd, k .. " takes " .. (k == "lladdr" and "a MAC" or "an interface")) end
            if k == "lladdr" then mac = args[n + 1] else dev = args[n + 1] end
            n = n + 2
        end
        if not mac then badWords(cmd, "add takes lladdr and the MAC: ip neigh add " .. addr .. " lladdr <mac>") end
        local ip = net.parseIP(addr)
        if not ip then badWords(cmd, "bad address " .. addr) end
        if not net.parseMAC(mac) then badWords(cmd, "bad MAC " .. mac .. " (02:cc:00:00:07:05, say)") end
        if not dev then                    -- the interface whose network it's on
            local ifaces = S and {} or net.config().ifaces
            if S then for name, i in pairs(S.ifaces) do ifaces[name] = net.cidrString(i.ip, i.len) end end
            for name, cidr in pairs(ifaces) do
                local nip, len = net.parseCIDR(cidr)
                local size = nip and 2 ^ (32 - len)
                if nip and math.floor(ip / size) == math.floor(nip / size) then dev = name end
            end
            if not dev then cu.fail("no interface on " .. addr .. "'s network: say which, with dev"); return cu.exit() end
        end
        if S then
            local ok, err = S.addNeighbour(addr, mac, dev)
            if not ok then cu.fail(err); return cu.exit() end
        end
        local list = {}
        for _, e in ipairs(saved()) do
            if not (net.parseIP(e.ip) == ip and (e.iface or dev) == dev) then list[#list + 1] = e end
        end
        list[#list + 1] = { ip = net.ipString(ip), mac = net.parseMAC(mac), iface = dev }
        keep(list)
        out(net.ipString(ip) .. " lladdr " .. net.parseMAC(mac) .. " dev " .. dev .. " permanent")
    else
        local addr = args[3]
        if not addr then badWords(cmd, "del takes the address") end
        local ip = net.parseIP(addr)
        if not ip then badWords(cmd, "bad address " .. addr) end
        local dev = devFrom(4)
        local list, gone = {}, false
        for _, e in ipairs(saved()) do
            if net.parseIP(e.ip) == ip and (not dev or e.iface == nil or e.iface == dev) then gone = true
            else list[#list + 1] = e end
        end
        if gone then keep(list) end
        if S then gone = S.deleteNeighbour(ip, dev) or gone end
        if not gone then cu.fail("no neighbour " .. addr .. (dev and (" on " .. dev) or "")) end
    end
elseif cmd == "forward" then
    local v = word(2, ONOFF)
    noMore(3)
    if v then
        settings.set("net.forward", v == "on")
        save()
        if S then S.forward = v == "on" end
    end
    out("forwarding " .. ((settings.get("net.forward") == true) and "on" or "off"))
elseif cmd == "rpfilter" then
    local v = word(2, RPMODES)
    noMore(3)
    if v then
        settings.set("net.rpfilter", v)
        save()
        if S then S.rpfilter = v end
    end
    out("rpfilter " .. net.rpfilter(settings.get("net.rpfilter")))
elseif cmd == "host" then
    local hosts = net.config().hosts
    noMore(4)
    -- del and a name (a second word that isn't an address), or a name and its address
    if args[3] and not net.parseIP(args[3]) and pick(args[2], HOST_SUBS) == "delete" then
        if not hosts[args[3]] then cu.fail("no host " .. args[3] .. " (ip host lists them)"); return cu.exit() end
        hosts[args[3]] = nil
    elseif args[2] then
        if not args[3] then badWords(cmd, "give a name and its address, or del and a name") end
        if not net.parseIP(args[3]) then badWords(cmd, "bad address " .. args[3]) end
        hosts[args[2]] = args[3]
    end
    if args[2] then
        local t = {}
        for k, v in pairs(hosts) do t[#t + 1] = k .. "=" .. v end
        table.sort(t)
        if #t == 0 then settings.unset("net.hosts") else settings.set("net.hosts", table.concat(t, ", ")) end
        save()
    end
    local names = {}
    for k in pairs(hosts) do names[#names + 1] = k end
    table.sort(names)
    for _, k in ipairs(names) do out(string.format("%-16s %s", k, hosts[k])) end
elseif cmd == "dns" then
    local w = args[2] and not net.parseIP(args[2]) and pick(args[2], DNS_WORDS)
    if w == "cache" or w == "flush" then
        noMore(3)
        local netdb = require("netdb")
        if w == "flush" then
            local n, why = netdb.flush()
            if not n then cu.fail(why); return cu.exit() end
            out(string.format("forgot %d answer%s, and which servers had failed", n, n == 1 and "" or "s"))
            return cu.exit()
        end
        local kept, why = netdb.cache()
        if not kept then cu.fail(why); return cu.exit() end
        -- each answer: name, type, seconds left, what it said, who said it
        for _, e in ipairs(kept.entries) do
            local said = {}
            for _, rr in ipairs(e.answers) do said[#said + 1] = tostring(rr.type) .. " " .. tostring(rr.data) end
            if e.rcode == 3 then said = { "no such name (NXDOMAIN)" }
            elseif #said == 0 then said = { "no " .. tostring(e.type) .. " record" } end
            out(string.format("%-24s %-5s %4d s  %s  (from %s)", e.name, tostring(e.type), math.ceil(e.left),
                table.concat(said, ", "), tostring(e.server)))
        end
        for _, d in ipairs(kept.down) do
            out(string.format("server %s failed: asked last for %d s more", d.server, math.ceil(d.left)))
        end
        if #kept.entries == 0 and #kept.down == 0 then out("the cache is empty") end
        return cu.exit()
    elseif w == "off" then
        noMore(3)
        settings.unset("net.dns")
        save()
    elseif args[2] then
        if #args > 3 then badWords(cmd, "a primary and a secondary at most") end
        for i = 2, #args do
            if not net.parseIP(args[i]) then badWords(cmd, "bad address " .. args[i]) end
        end
        settings.set("net.dns", table.concat(args, ", ", 2))
        save()
    end
    local dns = net.config().dns
    if #dns == 0 then out("no DNS servers: names are the hosts' alone (ip host)") end
    for i, ip in ipairs(dns) do out(string.format("%-10s %s", i == 1 and "primary" or "secondary", ip)) end
end
return cu.exit()
