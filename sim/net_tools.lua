-- sim/net_tools.lua
--
-- ip, ping, traceroute, nc, tcpdump and curl in a shellworld, against stacks (lib/net.lua)
-- joined by mock wires that answer at once:
--
--     this computer 10.0.1.2 --- [left] R 10.0.1.1 | 10.0.2.1 [right] --- B 10.0.2.5
--
-- ip: interfaces, routes, forwarding and hosts kept in settings, shown
-- down and up, `ip up` and `ip down`; ping (replies, TTL, summary, an
-- unknown host, the network down); traceroute (the router, then the
-- host); nc -l printing datagrams.
local PROJ = ...
package.path = PROJ .. "/lib/?.lua;" .. PROJ .. "/sim/lib/?.lua;" .. package.path
local M = require("mock")
local SW = require("shellworld")
local N = require("net")
local check = M.check

local W = SW.new(PROJ)
local function show(s) return (tostring(s):gsub("\n", "|")) end

-- settings and modems, as the programs see them (real globals)
local STORE = {}
settings = {
    get = function(k) return STORE[k] end, set = function(k, v) STORE[k] = v end,
    unset = function(k) STORE[k] = nil end, save = function() end,
    getNames = function() local t = {} for k in pairs(STORE) do t[#t + 1] = k end table.sort(t) return t end,
}
local OPENED = {}
peripheral = {
    getNames = function() return { "back", "top" } end,
    getType = function(n) return (n == "back" or n == "top") and "modem" or nil end,
    call = function(n, m, a)
        if m == "open" then OPENED[n .. ":" .. a] = true end
        if m == "close" then OPENED[n .. ":" .. a] = nil end
        if m == "isWireless" then return n == "top" end
    end,
}
os.getComputerID = os.getComputerID or function() return 1 end
textutils = textutils or M.textutilsApi()

--------------------------------------------------------------------------
-- ip with the network down: what's set
--------------------------------------------------------------------------
local r = W:run("ip")
check("ip, nothing set: down, and how to start", r.out:find("down") and r.out:find("ip addr add"), show(r.out))
r = W:run("ip", "addr", "add", "back", "10.0.1.2/24")
local r2 = W:run("ip", "addr", "add", "back.20", "10.0.20.2/24")
check("ip addr add: kept in settings (a VLAN too)", STORE["net.if.back"] == "10.0.1.2/24"
    and STORE["net.if.back.20"] == "10.0.20.2/24" and r.status == 0 and r2.status == 0)
r = W:run("ip", "addr", "add", "back", "10.0.1.2")
check("an address without its prefix: a usage error", r.status == 2, show(r.errText))
W:run("ip", "route", "add", "default", "via", "10.0.1.1")
W:run("ip", "route", "add", "10.0.9.0/24", "via", "10.0.1.7")
W:run("ip", "route", "del", "10.0.9.0/24")
check("ip route add/del: kept in settings", STORE["net.routes"] == "default via 10.0.1.1", tostring(STORE["net.routes"]))
W:run("ip", "host", "b", "10.0.2.5")
check("ip host: a name kept", tostring(STORE["net.hosts"]):find("b=10.0.2.5") ~= nil)
r = W:run("ip", "link")
check("ip link: the modems, wired or wireless, their MACs, and what's set on them",
    r.out:find("back%s+wired%s+02:cc:00:00:01:05 back back.20")
        and r.out:find("top%s+wireless%s+02:cc:00:00:01:00 %(not set up%)"), show(r.out))
r = W:run("ip", "addr")
r2 = W:run("ip", "-d", "addr")
check("ip addr while down: no MACs; ip -d addr: each one's MAC (VLANs share their modem's)",
    not r.out:find("02:cc") and r2.out:find("back%s+10%.0%.1%.2/24%s+02:cc:00:00:01:05 %(not up%)")
        and r2.out:find("back%.20%s+10%.0%.20%.2/24%s+02:cc:00:00:01:05 %(not up%)"), show(r.out) .. show(r2.out))
r = W:run("ip", "-x", "addr")
r2 = W:run("ip", "--detail", "a")
check("ip -x: no such option, status 2, the usage; --detail is -d cut short",
    r.status == 2 and r.errText:find('ip: no option "%-x"') and r.errText:find("usage: ip %[%-d%[etails%]%]")
        and r2.status == 0 and r2.out:find("02:cc:00:00:01:05"), show(r.errText) .. show(r2.out))
-- words cut short, as far as they stay clear
r = W:run("ip", "r", "a", "10.0.8.0/24", "v", "10.0.1.6")
r2 = W:run("ip", "ro", "d", "10.0.8.0/24")
check("ip r a <net> v <gw>, then ip ro d <net>: route add and del, cut short",
    r.status == 0 and r.out == "10.0.8.0/24 via 10.0.1.6\n" and r2.status == 0
        and STORE["net.routes"] == "default via 10.0.1.1", show(r.out) .. show(r.errText) .. show(r2.errText))
r = W:run("ip", "a", "a", "back.30", "10.0.30.2/24")
r2 = W:run("ip", "addr", "del", "back.30")
check("ip a a, ip addr del: address add and del", r.status == 0 and r2.status == 0 and STORE["net.if.back.30"] == nil
    and r.out == "back.30 10.0.30.2/24\n", show(r.out) .. show(r.errText))
r = W:run("ip", "rp", "s")
r2 = W:run("ip", "RPFILTER", "loose")
check("ip rp s: rpfilter strict; capitals too", r.out == "rpfilter strict\n" and r2.out == "rpfilter loose\n"
    and STORE["net.rpfilter"] == "loose", show(r.out) .. show(r2.out))
r = W:run("ip", "d")
check("ip d: down or dns? refused, with how to say each", r.status == 2
    and r.errText:find('ip: "d" could be down or dns: say do%[wn%] or dn%[s%]'), show(r.errText))
r = W:run("ip", "rout")
r2 = W:run("ip", "routes")
check("ip rout is route; ip routes isn't, and says what was meant, and the commands",
    r.status == 0 and r2.status == 2 and r2.errText:find('no command "routes" %(did you mean "route"%?%)')
        and r2.errText:find("commands: u%[p%] do%[wn%] b%[oot%] l%[ink%] a%[ddress%] r%[oute%]"), show(r2.errText))
r = W:run("ip", "route", "add", "10.0.8.0/24")
r2 = W:run("ip", "addr", "frob")
check("a command's words wrong: why, then that command's usage",
    r.status == 2 and r.errText:find("ip: route: add takes via and the router")
        and r.errText:find("usage: ip r%[oute%] %[show | add <net/len|default> via <gw>")
        and r2.status == 2 and r2.errText:find('ip: address: no "frob"'), show(r.errText) .. show(r2.errText))
r = W:run("ip", "help")
check("ip help: each command, as short as it may be, and what it does",
    r.status == 0 and r.out:find("  rp%[filter%]%s+which sources a router passes on") and r.out:find("  n%[eighbour%]"),
    show(r.out))
r = W:run("ip", "route")
check("ip route while down: the saved routes", r.out:find("default%s+via 10%.0%.1%.1 %(not up%)"), show(r.out))

-- ip neigh add/del: permanent ARP entries, kept in settings
r = W:run("ip", "neigh", "add", "10.0.1.7", "lladdr", "02:CC:00:00:07:05")
check("ip neigh add while down: kept in settings, its interface the one whose network it's on",
    r.status == 0 and STORE["net.neigh"] == "10.0.1.7 lladdr 02:cc:00:00:07:05 dev back"
        and r.out == "10.0.1.7 lladdr 02:cc:00:00:07:05 dev back permanent\n", show(r.out) .. show(r.errText))
r = W:run("ip", "n", "a", "10.0.99.9", "lladdr", "02:cc:00:00:63:05")
r2 = W:run("ip", "neigh", "add", "10.0.1.8", "lladdr", "nope")
check("... none on its network: says to give dev; a bad MAC refused", r.status ~= 0 and r.errText:find("dev")
    and r2.status == 2 and r2.errText:find("bad MAC"), show(r.errText) .. show(r2.errText))
r = W:run("ip", "neigh", "add", "10.0.20.9", "lladdr", "02:cc:00:00:09:05", "dev", "back.20")

--------------------------------------------------------------------------
-- ip up / down
--------------------------------------------------------------------------
r = W:run("ip", "up")
check("ip up: two interfaces, the channels opened (VLAN 20: 60020)", r.out:find("up: 2 interfaces")
    and OPENED["back:60000"] and OPENED["back:60020"] and _G.ccnet ~= nil, show(r.out) .. show(r.errText))
r = W:run("ip")
check("ip: up, the interfaces (no MACs) and routes", r.out:find("^up") and r.out:find("back%s+10%.0%.1%.2/24%s+rx 0")
    and not r.out:find("02:cc") and r.out:find("back%.20.*vlan 20") and r.out:find("default%s+via 10%.0%.1%.1 dev back"),
    show(r.out))
r = W:run("ip", "-d", "a")
check("ip -d a while up: the MACs", r.out:find("back%s+10%.0%.1%.2/24%s+02:cc:00:00:01:05 rx 0"), show(r.out))
r = W:run("ip", "neigh")
check("ip neigh after ip up: the permanent entries, marked so", r.out:find("10%.0%.1%.7%s+02:cc:00:00:07:05 dev back permanent")
    and r.out:find("10%.0%.20%.9%s+02:cc:00:00:09:05 dev back%.20 permanent")
    and _G.ccnet.arp.back[N.parseIP("10.0.1.7")].permanent, show(r.out))
r = W:run("ip", "neigh", "del", "10.0.20.9")
r2 = W:run("ip", "neigh", "del", "10.0.20.9")
check("ip neigh del: gone from the cache and the settings; again: no such neighbour",
    r.status == 0 and not _G.ccnet.arp["back.20"][N.parseIP("10.0.20.9")]
        and STORE["net.neigh"] == "10.0.1.7 lladdr 02:cc:00:00:07:05 dev back"
        and r2.status ~= 0 and r2.errText:find("no neighbour 10%.0%.20%.9"), show(r.errText) .. show(r2.errText))
r = W:run("ip", "down")
check("ip down: channels closed", r.out:find("down") and not OPENED["back:60000"] and _G.ccnet == nil)
r = W:run("ping", "10.0.1.1")
check("ping with the network down: says so, status 2", r.status == 2 and r.errText:find("ip up"), show(r.errText))

--------------------------------------------------------------------------
-- stacks on mock wires that answer at once
--------------------------------------------------------------------------
local segments, wires = {}, {}
local function copy(v)
    if type(v) ~= "table" then return v end
    local t = {}
    for k, x in pairs(v) do t[k] = copy(x) end
    return t
end
local function computer(id, forward, queue)
    local S
    S = N.new({ id = id, forward = forward, clock = function() return W.clock end,
        queue = queue or function() end,
        transmit = function(ifc, frame)
            for _, m in ipairs(segments[wires[id .. ":" .. ifc.modem]] or {}) do
                if not (m[1] == S and m[2] == ifc.modem) then m[1].receive(m[2], ifc.channel, copy(frame)) end
            end
        end })
    return S
end
local function plug(S, iface, cidr, seg)
    assert(S.addInterface(iface, cidr))
    wires[S.id .. ":" .. iface] = seg
    segments[seg] = segments[seg] or {}
    table.insert(segments[seg], { S, iface })
end
-- (codeAs: a code to put in place of "net" in the ICMP errors ME gets, as
-- a NAT-mode gateway's "prohibited")
local codeAs
local ME = computer(1, false, function(ev, kind, from, code, ...)
    if codeAs and ev == "net_icmp" and code == "net" then code = codeAs end
    W.os.queueEvent(ev, kind, from, code, ...)
end)
local R, B = computer(10, true), computer(2)
plug(ME, "back", "10.0.1.2/24", "lan1")
plug(R, "left", "10.0.1.1/24", "lan1")
plug(R, "right", "10.0.2.1/24", "lan2")
plug(B, "back", "10.0.2.5/24", "lan2")
assert(ME.addRoute("default", "10.0.1.1"))
assert(B.addRoute("default", "10.0.2.1"))
_G.ccnet = ME                       -- (b is `ip host`'s, above)

r = W:run("ping", "-c", "2", "b")
check("ping by name, through the router: 2 replies, TTL 63, the summary",
    r.status == 0 and r.out:find("PING b %(10%.0%.2%.5%)") and select(2, r.out:gsub("reply from 10%.0%.2%.5", "")) == 2
        and r.out:find("ttl=63") and r.out:find("2 sent, 2 received, 0%% lost"), show(r.out))
r = W:run("ping", "-c", "1", "-t", "1", "10.0.2.5")
check("ping -t 1: time exceeded at the router, status 1", r.status == 1
    and r.out:find("from 10%.0%.1%.1: seq=1 time to live exceeded") and r.out:find("1 sent, 0 received"), show(r.out))
r = W:run("ping", "-c", "1", "172.16.0.9")
check("ping where the router has no route: net unreachable from it", r.status == 1
    and r.out:find("from 10%.0%.1%.1: seq=1 destination net unreachable"), show(r.out))
r = W:run("ping", "nowhere")
check("ping an unknown name: status 2", r.status == 2 and r.errText:find("nowhere: Name or service not known"),
    show(r.errText))

-- ping -I: from an interface (out of it only) or from one of this computer's addresses
assert(ME.addInterface("top", "10.0.50.2/24"))          -- (on no wire: nothing beyond it)
assert(R.addRoute("10.0.50.0/24", "10.0.1.2"))          -- (so B's answers to 10.0.50.2 come back)
r = W:run("ping", "-c", "1", "-I", "back", "b")
check("ping -I back: from back's address, out of back", r.status == 0
    and r.out:find("^PING b %(10%.0%.2%.5%) from 10%.0%.1%.2 back\n") and r.out:find("reply from 10%.0%.2%.5"), show(r.out))
r = W:run("ping", "-c", "1", "-I", "top", "10.0.2.5")
check("ping -I top, where top has no way there: no route via top (the default route is back's), status 2",
    r.status == 2 and r.errText:find("no route to 10%.0%.2%.5 via top"), show(r.out) .. show(r.errText))
local srcSeen
B.taps.t = function(dir, _, f)
    if dir == "in" and f.type == "ip" and f.data.proto == "icmp" and f.data.data.type == "echo" then srcSeen = f.data.src end
end
r = W:run("ping", "-c", "1", "-I", "10.0.50.2", "b")
B.taps.t = nil
check("ping -I <one of ours>: that source (top's), the way the routes say (back), and the reply comes back to it",
    r.status == 0 and r.out:find("^PING b %(10%.0%.2%.5%) from 10%.0%.50%.2\n") and srcSeen == N.parseIP("10.0.50.2")
        and r.out:find("reply from 10%.0%.2%.5"), show(r.out) .. show(r.errText))
r = W:run("ping", "-I", "nowhere", "b")
r2 = W:run("ping", "-I", "10.9.9.9", "b")
check("ping -I with no such interface, or an address not this computer's: a usage error",
    r.status == 2 and r.errText:find("no interface nowhere") and r2.status == 2
        and r2.errText:find("10%.9%.9%.9 isn't one of this computer's addresses"), show(r.errText) .. show(r2.errText))
ME.removeInterface("top")
R.deleteRoute("10.0.50.0/24")

r = W:run("traceroute", "-q", "1", "b")
local lines = {}
for l in r.out:gmatch("[^\n]+") do lines[#lines + 1] = l end
check("traceroute: the router, then the host (by its name from ip host)",
    r.status == 0 and #lines == 3 and lines[2]:find("^ 1%s+10%.0%.1%.1  ") and lines[3]:find("^ 2%s+b %(10%.0%.2%.5%)"),
    show(r.out))
r = W:run("traceroute", "-q", "1", "172.16.0.9")
check("traceroute to a network nobody routes: !N at the router", r.status == 1 and r.out:find("10%.0%.1%.1.*!N"),
    show(r.out))
codeAs = "prohibited"
r = W:run("ping", "-c", "2", "172.16.0.9")
check("ping refused by a filter (a NAT-mode gateway): administratively prohibited, and why, once",
    r.status == 1 and select(2, r.out:gsub("from 10%.0%.1%.1: seq=%d administratively prohibited", "")) == 2
        and select(2, r.out:gsub("Network Gateway in NAT mode carries TCP and UDP only, no ICMP past it; it answers ping itself", "")) == 1, show(r.out))
r = W:run("traceroute", "-q", "1", "172.16.0.9")
check("traceroute: !X there, and why", r.status == 1 and r.out:find("10%.0%.1%.1.*!X")
    and r.out:find("Network Gateway in NAT mode", 1, true), show(r.out))
codeAs = nil

-- nc -l: what B sends to port 7 here, printed (until Ctrl+T)
local pb = B.udpOpen(1234)
local function sendLater() B.udpSend(pb, "10.0.1.2", 7, "hello"); B.udpSend(pb, "10.0.1.2", 7, { n = 1 }) end
r = W:run("nc", "-u", "-l", "-v", "7", {        -- (B sends once nc waits; then Ctrl+T)
    onPull = function(w)
        if sendLater then
            local f = sendLater
            sendLater = nil
            f()
            w.T.events[#w.T.events + 1] = { "terminate" }
        end
    end,
    events = {} })
check("nc -u -l -v: each datagram, with who sent it, a table serialised",
    r.out:find("from 10%.0%.2%.5:1234: hello") and r.out:find("from 10%.0%.2%.5:1234: {n=1,?}")
        and not r.out:find("nil"), show(r.out) .. show(r.errText))
check("and the port is free again after", ME.sockets[7] == nil)

-- tcpdump: what goes in and out of ME's interface, as it happens
local function once(fn)
    return function(w) if fn then local f = fn; fn = nil; f(w) end end
end
r = W:run("tcpdump", "-n", "-t", "-c", "2", { events = {}, onPull = once(function() ME.echo("10.0.2.5", 5, 1) end) })
check("tcpdump -n -t -c 2: a ping out and its reply in, then how many",
    r.out == "IP 10.0.1.2 > 10.0.2.5: ICMP echo request, id 5, seq 1\nIP 10.0.2.5 > 10.0.1.2: ICMP echo reply, id 5, seq 1\n"
        and r.status == 0 and r.errText:find("listening on back") and r.errText:find("2 packets captured"),
    show(r.out) .. show(r.errText))
check("and its tap is gone after", next(ME.taps) == nil)
W.now = 3723.25                     -- (01:02:03.250)
r = W:run("tcpdump", "-c", "1", "udp", "port", "7", { events = {}, onPull = once(function()
    ME.echo("10.0.2.5", 6, 1)
    B.udpSend(pb, "10.0.1.2", 7, "hello")
end) })
check("tcpdump udp port 7: the ping left out, the datagram shown with `ip host`'s name, the time of day",
    r.out == "01:02:03.250 IP b.1234 > 10.0.1.2.7: UDP, length 5\n" and r.errText:find("1 packet captured\n3 packets received"),
    show(r.out) .. show(r.errText))
assert(B.tcpListen(9))
r = W:run("tcpdump", "-n", "-t", "-c", "3", "tcp", "and", "(", "port", "9", "or", "port", "10", ")", { events = {},
    onPull = once(function() ME.tcpConnect("10.0.2.5", 9) end) })
local tl = {}
for l in r.out:gmatch("[^\n]+") do tl[#tl + 1] = l end
check("tcpdump tcp: the handshake, the SYN's seq as it is, then counted from it (ack 1)",
    #tl == 3 and tl[1]:find("^IP 10%.0%.1%.2%.%d+ > 10%.0%.2%.5%.9: Flags %[S%], seq %d+, win 4096, length 0$")
        and tl[2]:find("^IP 10%.0%.2%.5%.9 > 10%.0%.1%.2%.%d+: Flags %[S%.%], seq %d+, ack 1, win 4096, length 0$")
        and tl[3]:find("^IP 10%.0%.1%.2%.%d+ > 10%.0%.2%.5%.9: Flags %[%.%], ack 1, win 4096, length 0$"), show(r.out))
for _, c in pairs(ME.tcbs or {}) do ME.tcpAbort(c) end
B.tcpUnlisten(9)
r = W:run("tcpdump", "-c", "2", "-w", "cap", "icmp", { events = {}, onPull = once(function() ME.echo("10.0.2.5", 7, 1) end) })
check("tcpdump -w: written, not printed", r.out == "" and (W:read("cap") or ""):find("^%-%- ccnet frames"), show(r.out))
r = W:run("tcpdump", "-r", "cap", "-n", "-t", "-e")
check("tcpdump -r: read back, with the interface, the way, and (-e) the MACs",
    r.out:find("^back Out 02:cc:00:00:01:05 > 02:cc:00:00:0a:02, ip: IP 10%.0%.1%.2 > 10%.0%.2%.5: ICMP echo request, id 7, seq 1\n")
        and r.out:find("back In 02:cc:00:00:0a:02 > 02:cc:00:00:01:05, ip: IP 10%.0%.2%.5 > 10%.0%.1%.2: ICMP echo reply", 1, false), show(r.out))
r = W:run("tcpdump", "-n", "-t", "-c", "1", "-i", "top", { events = { { "modem_message", "top", N.CHANNEL, N.CHANNEL,
    { ccnet = 1, src = N.mac(7, "back"), dst = N.BROADCAST, type = "arp",
      data = { op = "request", sha = N.mac(7, "back"), spa = N.parseIP("10.0.1.7"), tpa = N.parseIP("10.0.1.9") } }, 5 } } })
check("tcpdump -i top (not one of the network's): its own channel, opened and closed again",
    r.out == "ARP, Request who-has 10.0.1.9 tell 10.0.1.7\n" and not OPENED["top:60000"], show(r.out) .. show(r.errText))
r = W:run("tcpdump", "-D")
check("tcpdump -D: the network's interfaces, the other modems, any",
    r.out == "1.back (10.0.1.2/24)\n2.top (not up: its untagged channel)\n3.any (all of them)\n", show(r.out))
r = W:run("tcpdump", "tcp", "port")
local r3 = W:run("tcpdump", "-i", "nowhere")
local r4 = W:run("tcpdump", "frobnicate")
check("tcpdump: a broken expression, an interface that isn't there, a word it doesn't know: status 1, and why",
    r.status == 1 and r.errText:find("a port expected at the end") and r3.status == 1 and r3.errText:find("no interface nowhere")
        and r4.status == 1 and r4.errText:find("unknown word frobnicate"), show(r.errText) .. show(r3.errText) .. show(r4.errText))

-- nc over TCP.  parallel as CraftOS has it, over the world's os
local parallelWas = parallel
parallel = { waitForAny = function(...)
    local cos, filters = {}, {}
    for i, f in ipairs({ ... }) do cos[i] = coroutine.create(f) end
    local ev = { n = 0 }
    while true do
        for i, co in ipairs(cos) do
            if filters[i] == nil or filters[i] == ev[1] or ev[1] == "terminate" then
                local ok, f = coroutine.resume(co, table.unpack(ev, 1, ev.n))
                if not ok then error(f, 0) end
                if coroutine.status(co) == "dead" then return i end
                filters[i] = f
            end
        end
        ev = table.pack(W.os.pullEventRaw())
    end
end }
W.yieldEvents = true
assert(B.tcpListen(7))
local cb, heard
r = W:run("nc", "10.0.2.5", "7", { stdin = "hi\n", events = {},
    onPull = function()
        cb = cb or B.tcpAccept(7)
        if cb and not heard and cb.peerFin then         -- (nc has sent its line and closed its half)
            heard = B.tcpRead(cb)
            B.tcpSend(cb, "pong\r\n")
            B.tcpClose(cb)
        end
    end })
check("nc host port (TCP): the line goes, the answer is printed (no \\r), both sides close",
    heard == "hi\n" and r.out == "pong\n" and r.status == 0 and cb.state == "CLOSED", show(r.out) .. show(r.errText))
B.tcpUnlisten(7)
local cl
r = W:run("nc", "-l", "-v", "8", { events = {},
    onPull = function()
        if not cl then
            cl = B.tcpConnect("10.0.1.2", 8)
            B.tcpSend(cl, "from b\n")
            B.tcpClose(cl)
        end
    end })
check("nc -l -v port: one connection, who it's from, what it sent, then the end",
    r.out == "from b\n" and r.status == 0 and r.err[1] == "connection from 10.0.2.5:" .. cl.lport
        and r.err[2] == "closed" and ME.listeners[8] == nil, show(r.out) .. show(r.errText))
r = W:run("nc", "10.0.2.5", "99", { events = {} })
check("nc to a port nobody listens on: connection refused, status 1",
    r.status == 1 and r.err[1] == "nc: 10.0.2.5 99: connection refused", show(r.errText))

--------------------------------------------------------------------------
-- netstat: this computer's sockets (with the process that opened each,
-- under a fake init), routes, interfaces and counters
--------------------------------------------------------------------------
local fakeInit = { self = function() return 7 end, list = function() return { { pid = 7, name = "telnetd" } } end }
_G.proc = fakeInit
assert(ME.tcpListen(23))
local u514 = assert(ME.udpOpen(514))
assert(B.tcpListen(80))
local out80 = assert(ME.tcpConnect("10.0.2.5", 80))
_G.proc = nil
local function rowWith(out, ...)
    for line in out:gmatch("[^\n]+") do
        local all = true
        for _, w in ipairs({ ... }) do if not line:find(w, 1, true) then all = false end end
        if all then return line end
    end
end
r = W:run("netstat")
check("netstat: connections only (w/o servers): the one to B, established, from this end's address",
    r.status == 0 and r.out:find("^Active Internet connections %(w/o servers%)\nProto Recv%-Q Send%-Q Local Address")
        and rowWith(r.out, "tcp", "10.0.1.2:" .. out80.lport, "10.0.2.5:80", "ESTABLISHED")
        and not r.out:find("LISTEN"), show(r.out))
r = W:run("netstat", "-l")
check("netstat -l: the TCP listener and the UDP socket, not the connection",
    rowWith(r.out, "tcp", "0.0.0.0:23", "0.0.0.0:*", "LISTEN") and rowWith(r.out, "udp", "0.0.0.0:514")
        and not r.out:find("ESTABLISHED") and r.out:find("%(only servers%)"), show(r.out))
_G.proc = fakeInit
r = W:run("netstat", "-atp")
_G.proc = nil
check("netstat -atp: TCP only, all of it, with PID/Program name (- for one no process opened)",
    rowWith(r.out, "tcp", "0.0.0.0:23", "LISTEN", "7/telnetd") and rowWith(r.out, "ESTABLISHED", "7/telnetd")
        and rowWith(r.out, "TIME_WAIT", " -")
        and not r.out:find("udp") and r.out:find("PID/Program name", 1, true), show(r.out))
r = W:run("netstat", "-lun")
check("netstat -lun: UDP only (-n taken)", rowWith(r.out, "udp", "0.0.0.0:514") and not r.out:find("tcp "), show(r.out))
r = W:run("netstat", "-r")
check("netstat -r: the routes, the default via the router (UG), the connected one (U)",
    rowWith(r.out, "0.0.0.0", "10.0.1.1", "0.0.0.0", "UG", "back") and rowWith(r.out, "10.0.1.0", "255.255.255.0", "U", "back"),
    show(r.out))
r = W:run("netstat", "-i")
check("netstat -i: each interface, its frames in and out", rowWith(r.out, "back", "10.0.1.2/24")
    and r.out:find("Iface RX%-OK TX%-OK"), show(r.out))
r = W:run("netstat", "-s")
check("netstat -s: the counters", r.out:find("Ip:\n") and r.out:find("1 listening") and r.out:find("1 sockets"), show(r.out))
ME.tcpAbort(out80)
ME.tcpUnlisten(23)
ME.udpClose(u514)
B.tcpUnlisten(80)
local was = _G.ccnet
_G.ccnet = nil
r = W:run("netstat")
_G.ccnet = was
check("netstat with the network down: says so, status 1", r.status == 1 and r.errText:find("isn't up"), show(r.errText))

--------------------------------------------------------------------------
-- curl (lib/httpc), against a small HTTP server on B
--------------------------------------------------------------------------
local httpc = require("httpc")
check("httpc.parseURL: scheme, user, host, port, path and query; no scheme is http; https refused",
    httpc.parseURL("http://u:p%40w@Wiki:8080/a/b?x=1#top").url == "http://wiki:8080/a/b?x=1"
        and httpc.parseURL("http://u:p%40w@wiki:8080/").user == "u:p@w" and httpc.parseURL("10.0.2.5").path == "/"
        and httpc.parseURL("b?q").path == "/?q" and select(3, httpc.parseURL("https://x/")) == "protocol"
        and select(3, httpc.parseURL("http://")) == "url" and select(3, httpc.parseURL("http://x:0/")) == "url")
check("httpc.resolve: absolute, //host, /path, relative, ?query and .. against the URL redirected from",
    httpc.resolve("http://a/b/c", "http://z/") == "http://z/" and httpc.resolve("http://a:81/b/c", "//z/y") == "http://z/y"
        and httpc.resolve("http://a:81/b/c", "/y") == "http://a:81/y" and httpc.resolve("http://a/b/c", "d") == "http://a/b/d"
        and httpc.resolve("http://a/b/c?q", "?r") == "http://a/b/c?r" and httpc.resolve("http://a/b/c/d", "../e") == "http://a/b/e"
        and httpc.resolve("http://a/b/c", "./") == "http://a/b/", httpc.resolve("http://a/b/c/d", "../e"))
check("httpc.base64 (RFC 4648's examples)", httpc.base64("") == "" and httpc.base64("f") == "Zg==" and httpc.base64("fo") == "Zm8="
    and httpc.base64("foo") == "Zm9v" and httpc.base64("foobar") == "Zm9vYmFy" and httpc.base64("user:pass") == "dXNlcjpwYXNz")

-- B answers on port 80: each request (head, body) is kept, and answered
-- from PAGES by its path, then closed.
local PAGES = {
    ["/"] = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 6\r\n\r\nhello\n",
    ["/chunked"] = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n7;x=y\r\n world\n\r\n0\r\nX-Trailer: 1\r\n\r\n",
    ["/old"] = "HTTP/1.0 200 OK\r\nServer: an old one\r\n\r\nuntil it closes\n",
    ["/moved"] = "HTTP/1.1 302 Found\r\nLocation: /dir/../new?from=moved\r\nContent-Length: 0\r\n\r\n",
    ["/new?from=moved"] = "HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\nnew\n",
    ["/loop"] = "HTTP/1.1 301 Moved Permanently\r\nLocation: http://b/loop\r\nContent-Length: 0\r\n\r\n",
    ["/missing"] = "HTTP/1.1 404 Not Found\r\nContent-Length: 10\r\n\r\nnot here!\n",
    ["/short"] = "HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\nonly this",
    ["/silent"] = "",
    ["/continue"] = "HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 201 Created\r\nContent-Length: 3\r\n\r\nok\n",
}
local requests = {}
local serving = {}
assert(B.tcpListen(80))
local function server()
    local c = B.tcpAccept(80)
    if c then serving[#serving + 1] = { c = c, buf = "" } end
    for _, k in ipairs(serving) do
        if not k.done then
            k.buf = k.buf .. (B.tcpRead(k.c) or "")
            local head, rest = k.buf:match("^(.-)\r\n\r\n(.*)$")
            local len = head and tonumber(head:lower():match("\r\ncontent%-length:%s*(%d+)")) or 0
            if head and #rest >= len then
                k.done = true
                requests[#requests + 1] = { head = head, body = rest:sub(1, len) }
                local method, path = head:match("^(%u+) (%S+)")
                local page = PAGES[path] or PAGES["/missing"]
                if method == "HEAD" then page = page:match("^(.-\r\n\r\n)") or page end
                if method == "POST" or method == "PUT" then
                    page = "HTTP/1.1 200 OK\r\nContent-Length: " .. #rest .. "\r\n\r\n" .. rest:sub(1, len)
                end
                if path == "/hang" then return end      -- (never a word, never closed)
                if page ~= "" then B.tcpSend(k.c, page) end
                B.tcpClose(k.c)
            end
        end
    end
end
local function curl(...)
    local args = table.pack(...)
    args[args.n + 1] = { events = {}, onPull = server }
    return W:run("curl", table.unpack(args, 1, args.n + 1))
end
local function sent(n) return requests[#requests - (n or 0)] end

r = curl("http://10.0.2.5/")
check("curl url: the body; the request a plain HTTP/1.1 GET with Host, User-Agent, Accept and Connection: close",
    r.status == 0 and r.out == "hello\n" and sent().head
        == "GET / HTTP/1.1\r\nHost: 10.0.2.5\r\nUser-Agent: ccnix-curl\r\nAccept: */*\r\nConnection: close",
    show(r.out) .. show(r.errText) .. show(sent() and sent().head))
r = curl("b/chunked")
check("curl b/chunked: no scheme is http, the name from ip host, a chunked body joined (an extension and trailer skipped)",
    r.status == 0 and r.out == "hello world\n" and sent().head:find("^GET /chunked HTTP/1%.1\r\nHost: b\r\n"), show(r.out) .. show(r.errText))
r = curl("http://b/old")
check("curl: an HTTP/1.0 answer with no length: the body until it closes", r.status == 0 and r.out == "until it closes\n",
    show(r.out) .. show(r.errText))
r = curl("-i", "http://b/")
r2 = curl("-i", "-o", "raw", "http://b/")
check("curl -i: the status line and headers first, then a blank line (on the screen without \\r; to a file as they came)",
    r.status == 0 and r.out == "HTTP/1.1 200 OK\nContent-Type: text/plain\nContent-Length: 6\n\nhello\n"
        and W:read("raw") == "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 6\r\n\r\nhello\n", show(r.out))
r = curl("http://b/", "--head")
check("curl url --head (options after the URL, long ones too): HEAD, the headers alone",
    r.status == 0 and sent().head:find("^HEAD / ") and r.out == "HTTP/1.1 200 OK\nContent-Type: text/plain\nContent-Length: 6\n\n",
    show(r.out) .. show(r.errText))
r = curl("http://b/moved")
r2 = curl("-L", "-v", "http://b/moved")
check("curl: a redirect not followed (its empty body), then -L: followed to the resolved Location; -v shows both ways",
    r.status == 0 and r.out == "" and r2.status == 0 and r2.out == "new\n" and sent().head:find("^GET /new%?from=moved ")
        and r2.errText:find("> GET /moved HTTP/1%.1") and r2.errText:find("< HTTP/1%.1 302 Found")
        and r2.errText:find("%* Issue another request to this URL: 'http://b/new%?from=moved'"),
    show(r2.out) .. show(r2.errText))
r = curl("-L", "http://b/loop")
check("curl -L round and round: 50 redirects followed, then (47)", r.status == 47
    and r.errText:find("curl: %(47%) maximum %(50%) redirects followed"), show(r.errText))
r = curl("-d", "a=1", "--data", "b=2", "http://b/form")
check("curl -d a=1 --data b=2: a POST of a=1&b=2, form-encoded, with its length",
    r.status == 0 and r.out == "a=1&b=2" and sent().head:find("^POST /form HTTP/1%.1\r\n")
        and sent().head:find("\r\nContent%-Type: application/x%-www%-form%-urlencoded")
        and sent().head:find("\r\nContent%-Length: 7") and sent().body == "a=1&b=2", show(r.out) .. show(sent().head))
W:file("msg.txt", "line one\nline two\n")
r = curl("-X", "PUT", "-H", "Content-Type: text/plain", "-H", "Accept:", "-H", "X-Empty;", "-d", "@msg.txt", "http://b/doc")
check("curl -X PUT -H ... -d @file: the method, a Content-Type kept, Accept left out, an empty header, the file less its newlines",
    r.status == 0 and sent().head:find("^PUT /doc ") and sent().head:find("\r\nContent%-Type: text/plain")
        and not sent().head:find("form%-urlencoded") and not sent().head:find("Accept") and sent().head:find("\r\nX%-Empty: ")
        and sent().body == "line oneline two", show(sent().head) .. show(sent().body))
r = curl("-u", "user:pass", "-A", "probe/1", "http://b/")
check("curl -u user:pass -A probe/1: Basic authentication and the agent",
    sent().head:find("\r\nAuthorization: Basic dXNlcjpwYXNz") and sent().head:find("\r\nUser%-Agent: probe/1"), show(sent().head))
r = curl("http://b/missing")
r2 = curl("-f", "http://b/missing")
check("curl: a 404 prints its body; -f: nothing, (22), status 22",
    r.status == 0 and r.out == "not here!\n" and r2.status == 22 and r2.out == ""
        and r2.errText:find("curl: %(22%) the requested URL returned error: 404"), show(r2.out) .. show(r2.errText))
r = curl("-o", "page.txt", "http://b/")
r2 = curl("-O", "http://b/chunked")
check("curl -o file, -O: the body written to the file, nothing printed",
    r.status == 0 and r.out == "" and W:read("page.txt") == "hello\n" and r2.status == 0 and W:read("chunked") == "hello world\n",
    show(r.out) .. show(W:read("page.txt")))
r = curl("http://b/continue")
check("curl: a 100 Continue passed over for the answer after it", r.status == 0 and r.out == "ok\n", show(r.out) .. show(r.errText))
r = curl("http://b/short")
r2 = curl("http://b/silent")
check("curl: closed short of Content-Length (18); closed without a word (52)",
    r.status == 18 and r.out == "only this" and r.errText:find("%(18%) it closed with 91 of 100 bytes to come")
        and r2.status == 52 and r2.errText:find("%(52%)"), show(r.errText) .. show(r2.errText))
local bad = { curl("https://b/"), curl("http://:80/"), curl("http://nowhere/"), curl("http://10.0.2.5:99/"), curl("-s", "http://10.0.2.5:99/"),
              curl(), curl("-Z", "b"), curl("--frob", "b") }
check("curl: https (1), a bad URL (3), no such host (6), refused (7; -s quiet), no URL or a bad option (2)",
    bad[1].status == 1 and bad[1].errText:find('protocol "https" not supported') and bad[2].status == 3 and bad[3].status == 6
        and bad[4].status == 7 and bad[4].errText:find("curl: %(7%) failed to connect to 10%.0%.2%.5 port 99: connection refused")
        and bad[5].status == 7 and bad[5].errText == "" and bad[6].status == 2 and bad[7].status == 2 and bad[8].status == 2
        and bad[8].errText:find("option %-%-frob: is unknown"),
    show(bad[1].errText) .. show(bad[3].errText) .. show(bad[4].errText) .. show(bad[5].errText))
r = curl("-m", "0", "http://b/hang")
check("curl -m 0 and no answer: (28), the deadline past (the sim has no time going by)", r.status == 28 and r.errText:find("curl: %(28%) timed out"),
    show(r.errText))
r = curl("-h")
check("curl -h: the usage, and whose curl is", r.status == 0 and r.out:find("usage: curl") and r.out:find("Daniel Stenberg"), show(r.out))
B.tcpUnlisten(80)

--------------------------------------------------------------------------
-- httpd (lib/httpd): B serves a folder of this computer's (static), and
-- curl fetches from it; then httpd itself runs here and B asks it
--------------------------------------------------------------------------
local httpd = require("httpd")
W:file("www/index.html", "<h1>home</h1>\n")
W:file("www/docs/a.txt", "alpha\n")
W:file("www/docs/my file.txt", "spaced\n")
W:file("www/docs/sub/b.txt", "beta\n")
W:file("www/old/index.htm", "old style\n")
W:file("www/pic.png", "\137PNG\r\n\26\n\0\1")
W:dir("www/empty")
local web = httpd.new():use(httpd.lua({ dir = "www/cgi", prefix = "/cgi", fs = W.fs, debug = true }))
    :use(httpd.static({ root = "www", fs = W.fs }))
local shut = httpd.new():use(httpd.static({ root = "www", fs = W.fs, listing = false }))
assert(B.tcpListen(8080))
assert(B.tcpListen(8081))
local webConns = {}
local function webServer()
    for port, srv in pairs({ [8080] = web, [8081] = shut }) do
        local c = B.tcpAccept(port)
        if c then webConns[#webConns + 1] = { c = c, buf = "", srv = srv } end
    end
    for _, k in ipairs(webConns) do
        if not k.done then
            k.buf = k.buf .. (B.tcpRead(k.c) or "")
            local out = k.srv:dispatch(k.buf, "10.0.1.2")
            if out then k.done = true; B.tcpSend(k.c, out); B.tcpClose(k.c) end
        end
    end
end
local function fetch(...)
    local args = table.pack(...)
    args[args.n + 1] = { events = {}, onPull = webServer }
    return W:run("curl", table.unpack(args, 1, args.n + 1))
end

r = fetch("http://b:8080/")
r2 = fetch("http://b:8080/old/")
check("httpd: a folder's index.html, else its index.htm", r.status == 0 and r.out == "<h1>home</h1>\n" and r2.out == "old style\n",
    show(r.out) .. show(r.errText) .. show(r2.out))
r = fetch("-i", "http://b:8080/docs?v=1")
r2 = fetch("-L", "http://b:8080/docs")
check("httpd: a folder without its slash: 301 to it (the query kept); there, no index: a listing, folders first, names escaped",
    r.out:find("^HTTP/1%.1 301 Moved Permanently\n") and r.out:find("\nLocation: /docs/%?v=1\n") and r2.status == 0
        and r2.out:find("<title>Index of /docs/</title>") and r2.out:find('<li><a href="%.%./">%.%./</a></li>')
        and r2.out:find('<a href="sub/">sub/</a>.*<a href="a%.txt">a%.txt</a> 6 bytes')
        and r2.out:find('<a href="my%%20file%.txt">my file%.txt</a> 7 bytes'), show(r.out) .. show(r2.out))
r = fetch("http://b:8080/docs/my%20file.txt?x=1")
r2 = fetch("-I", "http://b:8080/docs/a.txt")
check("httpd: a file (its name decoded, the query no matter); HEAD: its headers, length and type, no body",
    r.out == "spaced\n" and r2.out:find("^HTTP/1%.1 200 OK\n") and r2.out:find("\nContent%-Length: 6\n")
        and r2.out:find("\nContent%-Type: text/plain; charset=utf%-8\n") and r2.out:find("\nServer: ccnix%-httpd\n")
        and r2.out:find("\nConnection: close\n\n$"), show(r2.out))
r = fetch("-i", "http://b:8080/pic.png")
r2 = fetch("-o", "pic", "http://b:8080/pic.png")
check("httpd: a binary file, its type by its extension, byte for byte", r.out:find("\nContent%-Type: image/png\n")
    and W:read("pic") == "\137PNG\r\n\26\n\0\1", show(r.out))
r = fetch("-i", "http://b:8080/nope")
r2 = fetch("-f", "http://b:8080/nope")
local r3 = fetch("-i", "http://b:8080/%2e%2e/secret")
local r4 = fetch("-i", "-X", "DELETE", "http://b:8080/")
check("httpd: not there 404 (-f: 22); .. in a path 403; DELETE 405, with Allow",
    r.out:find("^HTTP/1%.1 404 Not Found\n") and r.out:find("<h1>404 Not Found</h1>") and r2.status == 22
        and r3.out:find("^HTTP/1%.1 403 Forbidden\n") and r4.out:find("^HTTP/1%.1 405 Method Not Allowed\n")
        and r4.out:find("\nAllow: GET, HEAD\n"), show(r.out) .. show(r3.out) .. show(r4.out))
r = fetch("http://b:8080/empty/")
r2 = fetch("-i", "http://b:8081/empty/")
r3 = fetch("http://b:8081/")
check("httpd: an empty folder lists nothing; with listings off, a folder with no index is 403, an index still served",
    r.out:find("<h1>Index of /empty/</h1>") and r2.out:find("^HTTP/1%.1 403 Forbidden\n") and r2.out:find("listings are off")
        and r3.out == "<h1>home</h1>\n", show(r2.out))
B.tcpUnlisten(8080)
B.tcpUnlisten(8081)

local function status(out) return tonumber(out and out:match("^HTTP/1%.1 (%d+)")) end
check("httpd.parse: not all there yet nil; refused: 400, 413, 431, 501, 505",
    web:dispatch("GET / HTTP/1.1\r\nHost: x\r\n") == nil and web:dispatch("POST / HTTP/1.1\r\nContent-Length: 5\r\n\r\nabc") == nil
        and status(web:dispatch("BLAH\r\n\r\n")) == 400 and status(web:dispatch("GET / HTTP/1.1\r\nbad line\r\n\r\n")) == 400
        and status(web:dispatch("POST / HTTP/1.1\r\nContent-Length: 99999999\r\n\r\n")) == 413
        and status(web:dispatch("GET / HTTP/1.1\r\nX: " .. ("y"):rep(9000))) == 431
        and status(web:dispatch("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n")) == 501
        and status(web:dispatch("GET / HTTP/2.0\r\n\r\n")) == 505)
local app = httpd.new()
    :use(function(req)
        if req.path == "/hello" then return 200, { ["Content-Type"] = "text/plain" }, "hi " .. (req.args.name or "") end
    end)
    :use(function(req) if req.path == "/boom" then error("boom") end end)
local logged = {}
app.log = function(s) logged[#logged + 1] = s end
local out, st = app:dispatch("GET /hello?name=a+b%21 HTTP/1.1\r\nHost: x\r\n\r\n", "10.0.0.9")
local out2, st2 = app:dispatch("GET /boom HTTP/1.1\r\n\r\n")
local out3, st3 = app:dispatch("GET /else HTTP/1.1\r\n\r\n")
check("httpd handlers: one answers (its query decoded), one throws (500, logged), none answers (404)",
    st == 200 and out:find("\r\n\r\nhi a b!$") and st2 == 500 and logged[1]:find("boom") and st3 == 404, show(out))

-- Lua pages (httpd.lua), on B's 8080 again
assert(B.tcpListen(8080))
W:file("www/cgi/hello.lua", [[write("<h1>Hello, ", html(req.params.name or "world"), "</h1>")]])
W:file("www/cgi/index.lua", [[return "the index of " .. req.script]])
W:file("www/cgi/made.lua", [[return 201, { ["X-Made"] = "yes" }, "made"]])
W:file("www/cgi/boom.lua", [[local x = nil; error("kaboom")]])
W:file("www/cgi/counter.lua", [[
state.n = (state.n or 0) + 1
cookie("seen", state.n, { maxAge = 60 })
cookie("other", "x")
header("Content-Type", "text/plain")
write(state.n, " ", req.cookies.x or "-")]])
W:file("www/cgi/notes.lua", [[
state.notes = state.notes or {}
local r = router()
r:get("/", function() return render("notes.etlua", { notes = state.notes }) end)
r:get("/:id", function(req, p)
    local n = state.notes[tonumber(p.id)]
    if not n then return 404, {}, "no such note" end
    write("<p>", html(n), "</p>")
end)
r:post("/", function(req)
    table.insert(state.notes, req.params.text)
    return redirect(req.script .. "/" .. #state.notes)
end)
r:get("/files/*", function(req, p) return "file " .. p.splat end)
return r]])
W:file("www/cgi/notes.etlua", [[<h1>Notes</h1><ul><% for i, n in ipairs(notes) do %><li><a href="<%= req.script %>/<%= i %>"><%= n %></a></li><% end %></ul>]])

r = fetch("http://b:8080/cgi/hello?name=%3CAnn%3E")
r2 = fetch("-d", "name=Bo+B%21", "http://b:8080/cgi/hello.lua")
check("Lua pages: /cgi/hello runs hello.lua (with or without .lua); the query, a POSTed form; html() escapes",
    r.status == 0 and r.out == "<h1>Hello, &lt;Ann&gt;</h1>" and r2.out == "<h1>Hello, Bo B!</h1>", show(r.out) .. show(r2.out) .. show(r.errText))
r = fetch("-i", "http://b:8080/cgi")
r2 = fetch("http://b:8080/cgi/")
r3 = fetch("-i", "http://b:8080/cgi/made")
check("Lua pages: /cgi redirected to /cgi/, which runs index.lua; a script returning status, headers, body",
    r.out:find("^HTTP/1%.1 301 ") and r.out:find("\nLocation: /cgi/\n") and r2.out == "the index of /cgi"
        and r3.out:find("^HTTP/1%.1 201 Created\n") and r3.out:find("\nX%-Made: yes\n") and r3.out:find("\n\nmade$"),
    show(r.out) .. show(r2.out) .. show(r3.out))
r = fetch("http://b:8080/cgi/notes/")
r2 = fetch("-i", "-d", "text=first <one>", "http://b:8080/cgi/notes")
r3 = fetch("-L", "-d", "text=second", "http://b:8080/cgi/notes")
r4 = fetch("http://b:8080/cgi/notes")
check("Lua pages: a router; a template; POST, then 303 to the new note (-L follows it as a GET)",
    r.out == "<h1>Notes</h1><ul></ul>" and r2.out:find("^HTTP/1%.1 303 See Other\n") and r2.out:find("\nLocation: /cgi/notes/1\n")
        and r3.out == "<p>second</p>"
        and r4.out == '<h1>Notes</h1><ul><li><a href="/cgi/notes/1">first &lt;one&gt;</a></li><li><a href="/cgi/notes/2">second</a></li></ul>',
    show(r.out) .. show(r2.out) .. show(r3.out) .. show(r4.out))
r = fetch("http://b:8080/cgi/notes/9")
r2 = fetch("-i", "-X", "DELETE", "http://b:8080/cgi/notes/1")
r3 = fetch("http://b:8080/cgi/notes/files/a/b.txt")
r4 = fetch("-I", "http://b:8080/cgi/notes/1")
check("Lua pages: a route's own 404; no route for the method 405, with Allow; * the rest of the path; HEAD takes GET",
    r.out == "no such note" and r2.out:find("^HTTP/1%.1 405 ") and r2.out:find("\nAllow: GET\n")
        and r3.out == "file a/b.txt" and r4.out:find("^HTTP/1%.1 200 OK\n") and r4.out:find("\nContent%-Length: 24\n"),
    show(r.out) .. show(r2.out) .. show(r3.out) .. show(r4.out))
r = fetch("http://b:8080/cgi/counter")
r2 = fetch("-i", "-H", "Cookie: x=7; y=8", "http://b:8080/cgi/counter")
check("Lua pages: state kept between requests; cookies read, and set (one Set-Cookie line each)",
    r.out == "1 -" and r2.out:find("\n\n2 7$") and r2.out:find("\nSet%-Cookie: seen=2; Path=/; Max%-Age=60; HttpOnly; SameSite=Lax\n")
        and r2.out:find("\nSet%-Cookie: other=x; Path=/; HttpOnly; SameSite=Lax\n") and r2.out:find("\nContent%-Type: text/plain\n"),
    show(r2.out))
r = fetch("-i", "http://b:8080/cgi/boom")
r2 = fetch("-i", "http://b:8080/cgi/notes.etlua")
r3 = fetch("-i", "http://b:8080/cgi/%2e%2e/index.html")
r4 = fetch("http://b:8080/cgi/nothing/here")
check("Lua pages: a script that fails 500 (debug: its traceback); nothing but scripts served there (404); .. 403",
    r.out:find("^HTTP/1%.1 500 ") and r.out:find("kaboom") and r.out:find("boom%.lua:1") and r2.out:find("^HTTP/1%.1 404 ")
        and r3.out:find("^HTTP/1%.1 403 ") and r4.out:find("404 Not Found"), show(r.out) .. show(r2.out))
B.tcpUnlisten(8080)
check("httpd.parse: a form only from a form's Content-Type; params the query and form, the form's winning; cookies",
    (function()
        local q = httpd.parse("POST /x?a=1&b=2 HTTP/1.1\r\nContent-Type: application/x-www-form-urlencoded; charset=utf-8\r\n"
            .. "Cookie: s=\"q r\"; t=1\r\nContent-Length: 7\r\n\r\nb=3&c=4")
        local j = httpd.parse("POST /x HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: 7\r\n\r\nb=3&c=4")
        return q.form.c == "4" and q.params.a == "1" and q.params.b == "3" and q.args.b == "2" and q.cookies.s == "q r"
            and q.cookies.t == "1" and next(j.form) == nil and j.body == "b=3&c=4"
    end)())

-- the guestbook (deploy/examples, which setup httpd --example copies in)
for _, n in ipairs({ "guestbook.lua", "guestbook.etlua" }) do
    local h = assert(io.open(PROJ .. "/deploy/examples/" .. n, "rb"))
    W:file("www/cgi/" .. n, h:read("a"))
    h:close()
end
local function book() return httpd.new():use(httpd.lua({ dir = "www/cgi", prefix = "/cgi", fs = W.fs })) end
local function ask(srv, raw) local o, s = srv:dispatch(raw, "10.0.0.9") return s, o end
local function sign(srv, body)
    return ask(srv, "POST /cgi/guestbook HTTP/1.1\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: "
        .. #body .. "\r\n\r\n" .. body)
end
local gb = book()
local s1, o1 = ask(gb, "GET /cgi/guestbook HTTP/1.1\r\n\r\n")
local s2, o2 = sign(gb, "name=+&message=hi")
local s3, o3 = sign(gb, "name=Ann+%3Cb%3E&message=hello%0Athere")
local s4, o4 = ask(gb, "GET /cgi/guestbook HTTP/1.1\r\n\r\n")
local s5, o5 = ask(book(), "GET /cgi/guestbook HTTP/1.1\r\n\r\n")      -- (httpd started again: from guestbook.db)
local s6 = ask(web, "GET /cgi/guestbook.db HTTP/1.1\r\n\r\n")
check("the example guestbook: empty; a blank name refused (400, the message kept); signed (303 back); shown escaped;"
    .. " kept in guestbook.db past a restart, which isn't served",
    s1 == 200 and o1:find("No one has signed yet") and s2 == 400 and o2:find("A name and a message, please")
        and o2:find(">hi</textarea>") and s3 == 303 and o3:find("\r\nLocation: /cgi/guestbook\r\n") and s4 == 200
        and o4:find("<b>Ann &lt;b&gt;</b>") and o4:find("<p>hello\nthere</p>") and o4:find("1 entry")
        and W:read("www/cgi/guestbook.db") and s5 == 200 and o5:find("Ann &lt;b&gt;") and s6 == 404,
    show(o2) .. show(o4))

local cl, got, asked = nil, "", false
r = W:run("httpd", "-p", "80", "www", { events = {}, onPull = function(w)
    if not cl then
        cl = B.tcpConnect("10.0.1.2", 80)
        B.tcpSend(cl, "GET /docs/a.txt HTTP/1.1\r\nHost: me\r\n\r\n")
    end
    got = got .. (B.tcpRead(cl) or "")
    if cl.peerFin and not asked then
        asked = true
        w.T.events[#w.T.events + 1] = { "terminate", n = 1 }
    end
end })
check("httpd -p 80 www: serves, logs each request, and stops at Ctrl+T, its port closed",
    r.status == 0 and r.out:find("serving /www on port 80") and r.out:find("Lua pages: /cgi/ runs /www/cgi")
        and r.out:find('10%.0%.2%.5 "GET /docs/a%.txt" 200 6')
        and got:find("^HTTP/1%.1 200 OK\r\n") and got:find("\r\n\r\nalpha\n$") and ME.listeners[80] == nil,
    show(r.out) .. show(r.errText) .. show(got))
check("... each request in the system log too: without init, lib/log files it, local7 into /var/log/httpd.log",
    (W:read("var/log/httpd.log") or ""):find(' httpd: 10%.0%.2%.5 "GET /docs/a%.txt" 200 6\n'), show(W:read("var/log/httpd.log")))
r = W:run("httpd", "nowhere", { events = {} })
check("httpd with no such folder: says so, status 1", r.status == 1 and r.errText:find("no folder"), show(r.errText))

-- syslogd (under a fake init) over the network: forwarding to B as RFC
-- 5424 (to an address, and to a name looked up aside), and a loghost,
-- filing what B sends (RFC 3164 with its host; bare, under B's address)
W:file("etc/syslog.conf", "*.* /var/log/all.log\n*.notice @10.0.2.5\n*.err @b:5514\n")
STORE["syslog.listen"] = true
local b514, b5514 = B.udpOpen(514), B.udpOpen(5514)
_G.proc = { self = function() return 5 end, console = function() return nil end, register = function() return true end,
    log = function() end, spawn = function(spec) spec.fn() end,
    inject = function(_, ...) W.T.events[#W.T.events + 1] = table.pack(...) end }
local fromB = false
local function rec(sev, msg) return { fac = 3, sev = sev, time = 1793188800000, host = "base", app = "web", pid = 3, msg = msg } end
r = W:run("syslogd", { events = { { "syslog", rec(5, "noticed"), n = 2 }, { "syslog", rec(3, "broke"), n = 2 } },
    onPull = function(w)
        if not fromB then
            fromB = true
            B.udpSend(pb, "10.0.1.2", 514, "<34>Oct 11 22:14:15 bhost su: from b")
            B.udpSend(pb, "10.0.1.2", 514, "<13>bare")
        elseif #w.T.events == 0 then
            w.T.events[1] = { "terminate", n = 1 }
        end
    end })
_G.proc = nil
STORE["syslog.listen"] = nil
local f1, f2, f3 = B.udpTake(b514), B.udpTake(b514), B.udpTake(b5514)
local all = W:read("var/log/all.log") or ""
check("syslogd: @10.0.2.5 gets notice and worse, @b:5514 err (b looked up), as RFC 5424",
    r.status == 0 and r.tty:find("listening on UDP 514") and f1 and f1.data == "<29>1 2026-10-28T12:00:00.000Z base web 3 - - noticed"
        and f2 and f2.data:find("^<27>1 .* broke$") and f3 and f3.data:find("^<27>1 .* broke$"),
    show(r.tty) .. show(r.errText) .. show(f1 and f1.data) .. " / " .. show(f2 and f2.data) .. " / " .. show(f3 and f3.data))
local f4 = B.udpTake(b514)
check("syslogd -- syslog.listen: B's messages filed, under the host they name, else B's address; relayed by the rules too",
    all:find(" bhost su: from b\n") and all:find(" 10%.0%.2%.5 %-: bare\n") and f4 and f4.data:find("^<34>1 %S+ bhost su %- %- %- from b$"),
    show(all) .. show(f4 and f4.data))
B.udpClose(b514)
B.udpClose(b5514)
W.fs.delete("etc")
W.yieldEvents = false
parallel = parallelWas
_G.ccnet = nil

--------------------------------------------------------------------------
-- deploy/setup --autostart router on a computer: the network up at boot,
-- forwarding on, and with --autostart router the router's screen at boot
--------------------------------------------------------------------------
for _, f in ipairs({ "setup", "boot" }) do
    local hf = assert(io.open(PROJ .. "/deploy/" .. f .. ".lua", "rb"))
    W:file("ccnix/deploy/" .. f .. ".lua", hf:read("a"))
    hf:close()
end
W:install("ip")
help = help or { path = function() return "/rom/help" end, setPath = function() end }
local turtleWas = turtle
turtle = nil
STORE["net.boot"], STORE["net.forward"] = nil, nil
r = W:session({}, function() return W:osRun("ccnix/deploy/setup.lua", { "--autostart", "router", "--no-reboot" }) end)
local startup = W:read("startup.lua") or ""
check("setup --autostart router on a computer: net.boot and forwarding on, the router at boot; startup runs boot.lua first and `--end` last",
    STORE["net.boot"] == true and STORE["net.forward"] == true and STORE["ccnix.autostart"] == "router"
        and startup == 'shell.run("/ccnix/deploy/boot.lua")\nshell.run("/ccnix/deploy/boot.lua", "--end")\n',
    show(startup) .. show(r.out) .. show(r.errText))
check("and, not rebooting, the network came up in this shell (forwarding)", _G.ccnet ~= nil and _G.ccnet.forward == true,
    show(r.out))
r = W:session({}, function() return W:osRun("ccnix/deploy/setup.lua", { "--no-reboot" }) end)
check("setup again: the same startup", W:read("startup.lua") == startup, show(W:read("startup.lua")))
r = W:run("ip", "boot", "off")
check("ip boot off: net.boot off", STORE["net.boot"] == false and r.out:find("doesn't start"))
r = W:run("ip", "boot")
check("ip boot: on again, and no line of its own (setup's is there)", STORE["net.boot"] == true
    and W:read("startup.lua") == startup)
N.down()
turtle = turtleWas
