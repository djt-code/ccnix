-- ip.lua -- set up and look at the network (lib/net.lua)
--
--   ip                               the interfaces, routes and whether it's up
--   ip up | ip down                  start or stop the network on this computer
--   ip boot [off]                    start it at every boot: the setting net.boot,
--                                    which startup goes by (setup's net and router
--                                    apps turn it on)
--   ip link                          the modems there are, and which are set up
--   ip addr                          the interfaces' addresses and counts
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
--
-- An interface is a modem by its peripheral name ("back", "modem_0"), or a
-- VLAN on one: "back.20" is VLAN 20 on the back modem, its own network on
-- the same wire.  What's set is kept in settings (net.if.<iface>,
-- net.routes, net.forward, net.rpfilter, net.hosts, net.dns) and applies at
-- once if the network is up.  The network runs alongside everything else once `ip up` has
-- started it: see lib/net.lua.  `help network` walks through setting up
-- two networks and a router.

package.path = (ccnix and ccnix.lib or "/" .. fs.getDir(fs.getDir(shell.getRunningProgram())) .. "/lib/?.lua;") .. package.path  -- ccnix's lib/, or the one beside bin/
local cu = require("cu").init("ip", "ip [up|down|boot|link|addr|route|neigh|forward|rpfilter|host|dns] ...")
local net = require("net")
local args = { ... }

local function out(...) io.write(...) io.write("\n") end
local function save() settings.save() end

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
            out(string.format("%-12s %-18s %-14s rx %d tx %d%s", name, net.cidrString(i.ip, i.len), i.mac, i.rx, i.tx,
                i.vlan and (" (vlan " .. i.vlan .. ")") or ""))
        end
    else
        local cfg = net.config()
        local names = {}
        for k in pairs(cfg.ifaces) do names[#names + 1] = k end
        table.sort(names)
        for _, name in ipairs(names) do out(string.format("%-12s %-18s (not up)", name, cfg.ifaces[name])) end
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

local S = net.stack()
local cmd, sub = args[1], args[2]

if cmd == nil then
    out(S and ("up" .. (S.forward and (", forwarding (rpfilter " .. S.rpfilter .. ")") or "")) or "down (ip up starts it)")
    showAddr(S)
    showRoutes(S)
    local dns = net.config().dns
    if #dns > 0 then out("dns " .. table.concat(dns, ", ")) end
elseif cmd == "up" then
    local S2, problems = net.up()
    for _, p in ipairs(problems) do cu.err(p) end
    local n = 0
    for _ in pairs(S2.ifaces) do n = n + 1 end
    out(string.format("up: %d interface%s%s", n, n == 1 and "" or "s", S2.forward and ", forwarding" or ""))
    if #problems > 0 then cu.exit(1) end
elseif cmd == "down" then
    out(net.down() and "down" or "it wasn't up")
elseif cmd == "boot" then
    -- the setting net.boot: startup brings the network up while it's on
    -- (deploy/boot under the ROM, deploy/install's startup line otherwise)
    local on = sub ~= "off"
    settings.set("net.boot", on)
    save()
    out(on and "the network starts at boot" or "the network doesn't start at boot")
elseif cmd == "link" then
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
            out(string.format("%-12s %-9s %s", name, wireless and "wireless" or "wired", used[name] or "(not set up)"))
        end
    end
    if not any then out("no modems") end
elseif cmd == "addr" and (sub == nil or sub == "show") then
    showAddr(S)
elseif cmd == "addr" and sub == "add" and args[3] and args[4] then
    local iface, cidr = args[3], args[4]
    if not net.link(iface) then cu.usageError("bad VLAN in " .. iface .. " (1-4094)") end
    if not net.parseCIDR(cidr) or not cidr:find("/") then cu.usageError("give the address with its prefix: 10.0.1.5/24") end
    settings.set("net.if." .. iface, cidr)
    save()
    if S then
        local modem, channel = net.link(iface)
        if peripheral.getType(modem) ~= "modem" then cu.fail("no modem called " .. modem .. " (saved anyway)")
        else peripheral.call(modem, "open", channel); S.addInterface(iface, cidr) end
    end
    out(iface .. " " .. cidr)
elseif cmd == "addr" and sub == "del" and args[3] then
    settings.unset("net.if." .. args[3])
    save()
    if S and S.ifaces[args[3]] then
        local i = S.ifaces[args[3]]
        S.removeInterface(args[3])
        pcall(peripheral.call, i.modem, "close", i.channel)
    end
    out(args[3] .. " removed")
elseif cmd == "route" and (sub == nil or sub == "show") then
    showRoutes(S)
elseif cmd == "route" and sub == "add" and args[3] and args[4] == "via" and args[5] then
    local r = { net = args[3], gw = args[5], iface = args[6] == "dev" and args[7] or nil }
    if not net.parseCIDR(r.net) then cu.usageError("bad network " .. r.net) end
    if not net.parseIP(r.gw) then cu.usageError("bad gateway " .. r.gw) end
    if S then
        local ok, err = S.addRoute(r.net, r.gw, r.iface)
        if not ok then cu.fail(err); return cu.exit() end
    end
    local list = {}
    for _, x in ipairs(savedRoutes()) do if x.net ~= r.net then list[#list + 1] = x end end
    list[#list + 1] = r
    saveRoutes(list)
    out(r.net .. " via " .. r.gw)
elseif cmd == "route" and sub == "del" and args[3] then
    local list, gone = {}, false
    for _, x in ipairs(savedRoutes()) do if x.net ~= args[3] then list[#list + 1] = x else gone = true end end
    saveRoutes(list)
    if S then gone = S.deleteRoute(args[3]) or gone end
    if not gone then cu.fail("no route " .. args[3]) end
elseif cmd == "neigh" then
    if not S then cu.fail("the network isn't up"); return cu.exit() end
    local any = false
    for iface, cache in pairs(S.arp) do
        for ip, e in pairs(cache) do
            any = true
            out(string.format("%-16s %-14s dev %s", net.ipString(ip), e.mac, iface))
        end
    end
    if not any then out("(empty)") end
elseif cmd == "forward" then
    if sub == "on" or sub == "off" then
        settings.set("net.forward", sub == "on")
        save()
        if S then S.forward = sub == "on" end
    end
    out("forwarding " .. ((settings.get("net.forward") == true) and "on" or "off"))
elseif cmd == "rpfilter" then
    if sub then
        if sub ~= "strict" and sub ~= "loose" and sub ~= "off" then cu.usageError("strict, loose or off") end
        settings.set("net.rpfilter", sub)
        save()
        if S then S.rpfilter = sub end
    end
    out("rpfilter " .. net.rpfilter(settings.get("net.rpfilter")))
elseif cmd == "host" then
    local hosts = net.config().hosts
    if sub and args[3] then
        if not net.parseIP(args[3]) then cu.usageError("bad address " .. args[3]) end
        hosts[sub] = args[3]
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
    if sub == "off" then
        settings.unset("net.dns")
        save()
    elseif sub then
        if #args > 3 then cu.usageError("a primary and a secondary at most") end
        for i = 2, #args do
            if not net.parseIP(args[i]) then cu.usageError("bad address " .. args[i]) end
        end
        settings.set("net.dns", table.concat(args, ", ", 2))
        save()
    end
    local dns = net.config().dns
    if #dns == 0 then out("no DNS servers: names are the hosts' alone (ip host)") end
    for i, ip in ipairs(dns) do out(string.format("%-10s %s", i == 1 and "primary" or "secondary", ip)) end
else
    cu.usageError()
end
return cu.exit()
