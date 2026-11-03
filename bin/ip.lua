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
--   ip neigh                         the ARP cache: addresses and their MACs
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
--   ip dns [<primary> [<secondary>] | off]
--                                    the DNS servers names are looked up at
--                                    after the hosts (lib/netdb); none: the
--                                    hosts alone
--   ip help                          the commands, and how short each may be
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
-- net.routes, net.forward, net.rpfilter, net.hosts, net.dns) and applies at
-- once if the network is up.  The network runs alongside everything else once `ip up` has
-- started it: see lib/net.lua.  `help network` walks through setting up
-- two networks and a router.

package.path = (ccnix and ccnix.lib or "/" .. fs.getDir(fs.getDir(shell.getRunningProgram())) .. "/lib/?.lua;") .. package.path  -- ccnix's lib/, or the one beside bin/
local cu = require("cu").init("ip", nil)
local net = require("net")
local args = { ... }

-- options, before the command: -d[etails] (one or two dashes, any cut)
local details = false
while type(args[1]) == "string" and args[1]:find("^%-%-?%a") do
    local o = table.remove(args, 1)
    local name = o:gsub("^%-%-?", ""):lower()
    if ("details"):sub(1, #name) == name then details = true
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
    { "route", 1, args = "[show | add <net/len|default> via <gw> [dev <iface>] | del <net/len|default>]",
      what = "the routing table" },
    { "neighbour", 1, "neighbor", args = "[show]", what = "the ARP cache" },
    { "forward", 1, args = "[on|off]", what = "route between interfaces (a router)" },
    { "rpfilter", 2, args = "[strict|loose|off]", what = "which sources a router passes on (BCP 38)" },
    { "host", 1, args = "[<name> <addr>]", what = "names for addresses" },
    { "dns", 2, args = "[<primary> [<secondary>] | off]", what = "the DNS servers" },
    { "help", 2, args = "", what = "this list" },
}
local SHOW = { { "show", 1, "list", "ls" } }
local ADDR_SUBS = { SHOW[1], { "add", 1 }, { "delete", 1 } }
local NEIGH_SUBS = SHOW
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
            if type(name) == "string" and name:sub(1, #s) == s then
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

--------------------------------------------------------------------------
-- The commands
--------------------------------------------------------------------------
local S = net.stack()
local cmd
if args[1] ~= nil then
    local why
    cmd, why = pick(args[1], COMMANDS)
    if not cmd then
        cu.err((why:gsub('^no "', 'no command "', 1)))
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
    -- (deploy/boot under the ROM, deploy/install's startup line otherwise)
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
        if not net.parseCIDR(cidr) or not cidr:find("/") then badWords(cmd, "give the address with its prefix: 10.0.1.5/24") end
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
    local sub = word(2, ADDR_SUBS, "show")
    if sub == "show" then
        noMore(3)
        showRoutes(S)
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
    word(2, NEIGH_SUBS)
    noMore(3)
    if not S then cu.fail("the network isn't up"); return cu.exit() end
    local any = false
    for iface, cache in pairs(S.arp) do
        for ip, e in pairs(cache) do
            any = true
            out(string.format("%-16s %-17s dev %s", net.ipString(ip), e.mac, iface))
        end
    end
    if not any then out("(empty)") end
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
    if args[2] and not args[3] then badWords(cmd, "give a name and its address") end
    noMore(4)
    if args[2] then
        if not net.parseIP(args[3]) then badWords(cmd, "bad address " .. args[3]) end
        hosts[args[2]] = args[3]
        local t = {}
        for k, v in pairs(hosts) do t[#t + 1] = k .. "=" .. v end
        table.sort(t)
        settings.set("net.hosts", table.concat(t, ", "))
        save()
    end
    local names = {}
    for k in pairs(hosts) do names[#names + 1] = k end
    table.sort(names)
    for _, k in ipairs(names) do out(string.format("%-16s %s", k, hosts[k])) end
elseif cmd == "dns" then
    if args[2] and not net.parseIP(args[2]) and pick(args[2], { { "off", 2 } }) == "off" then
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
