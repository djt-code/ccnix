-- sim/net_tools.lua
--
-- ip, ping, traceroute and nc in a shellworld, against stacks (lib/net.lua)
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
check("ip link: the modems, wired or wireless, and what's set on them",
    r.out:find("back%s+wired%s+back back.20") and r.out:find("top%s+wireless%s+%(not set up%)"), show(r.out))
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

--------------------------------------------------------------------------
-- ip up / down
--------------------------------------------------------------------------
r = W:run("ip", "up")
check("ip up: two interfaces, the channels opened (VLAN 20: 4060)", r.out:find("up: 2 interfaces")
    and OPENED["back:4040"] and OPENED["back:4060"] and _G.ccnet ~= nil, show(r.out) .. show(r.errText))
r = W:run("ip")
check("ip: up, the interfaces and routes", r.out:find("^up") and r.out:find("back%s+10%.0%.1%.2/24%s+1:back")
    and r.out:find("back%.20.*vlan 20") and r.out:find("default%s+via 10%.0%.1%.1 dev back"), show(r.out))
r = W:run("ip", "down")
check("ip down: channels closed", r.out:find("down") and not OPENED["back:4040"] and _G.ccnet == nil)
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
    r.out:find("^back Out 1:back > 10:left, ip: IP 10%.0%.1%.2 > 10%.0%.2%.5: ICMP echo request, id 7, seq 1\n")
        and r.out:find("back In 10:left > 1:back, ip: IP 10%.0%.2%.5 > 10%.0%.1%.2: ICMP echo reply", 1, false), show(r.out))
r = W:run("tcpdump", "-n", "-t", "-c", "1", "-i", "top", { events = { { "modem_message", "top", 4040, 4040,
    { ccnet = 1, src = "7:back", dst = "*", type = "arp",
      data = { op = "request", sha = "7:back", spa = N.parseIP("10.0.1.7"), tpa = N.parseIP("10.0.1.9") } }, 5 } } })
check("tcpdump -i top (not one of the network's): its own channel, opened and closed again",
    r.out == "ARP, Request who-has 10.0.1.9 tell 10.0.1.7\n" and not OPENED["top:4040"], show(r.out) .. show(r.errText))
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
W.yieldEvents = false
parallel = parallelWas
_G.ccnet = nil

--------------------------------------------------------------------------
-- deploy/install --router on a computer: the network up at boot,
-- forwarding on, and with --autostart router the router's screen at boot
--------------------------------------------------------------------------
for _, f in ipairs({ "install", "boot" }) do
    local hf = assert(io.open(PROJ .. "/deploy/" .. f .. ".lua", "rb"))
    W:file("ccnix/deploy/" .. f .. ".lua", hf:read("a"))
    hf:close()
end
W:install("ip")
help = help or { path = function() return "/rom/help" end, setPath = function() end }
local turtleWas = turtle
turtle = nil
STORE["net.boot"], STORE["net.forward"] = nil, nil
r = W:session({}, function() return W:osRun("ccnix/deploy/install.lua", { "--autostart", "router", "--no-reboot" }) end)
local startup = W:read("startup.lua") or ""
check("install --autostart router on a computer: net.boot and forwarding on, the router at boot; startup runs boot.lua first and `--end` last",
    STORE["net.boot"] == true and STORE["net.forward"] == true and STORE["ccnix.autostart"] == "router"
        and startup == 'shell.run("/ccnix/deploy/boot.lua")\nshell.run("/ccnix/deploy/boot.lua", "--end")\n',
    show(startup) .. show(r.out) .. show(r.errText))
check("and, not rebooting, the network came up in this shell (forwarding)", _G.ccnet ~= nil and _G.ccnet.forward == true,
    show(r.out))
r = W:session({}, function() return W:osRun("ccnix/deploy/install.lua", { "--no-reboot" }) end)
check("install again: the same startup", W:read("startup.lua") == startup, show(W:read("startup.lua")))
r = W:run("ip", "boot", "off")
check("ip boot off: net.boot off", STORE["net.boot"] == false and r.out:find("doesn't start"))
r = W:run("ip", "boot")
check("ip boot: on again, and no line of its own (install's is there)", STORE["net.boot"] == true
    and W:read("startup.lua") == startup)
N.down()
turtle = turtleWas
