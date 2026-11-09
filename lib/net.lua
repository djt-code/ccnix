-- net.lua -- a small layered network stack over ComputerCraft modems
--
--   local net = require("net")
--   local s = net.stack()                  -- the running one (`ip up` starts it)
--   local sock = net.udp()                 -- a UDP socket, any free port
--   sock:send("10.0.2.5", 7, "hello")
--   local data, from, port = sock:receive(5)
--
-- Layers, as on Ethernet and IPv4, kept small:
--
--  * Link (layer 2): an interface is a modem (wired or wireless, named as
--    a peripheral: "back", "modem_0") and a channel, like an Ethernet
--    segment.  "back" sends and listens on net.CHANNEL (60000), untagged;
--    "back.20" is VLAN 20 on the same modem, channel 60000 + 20: each
--    channel is its own segment (and broadcast domain) on the shared wire,
--    so one modem can carry several networks, a router's trunk.  VLANs
--    1-4094.  A frame is { ccnet = 1, dst = MAC, src = MAC, type = "arp" |
--    "ip", data = ... }.  A MAC is a locally administered one, 02:cc: then
--    the computer's ID (3 bytes) and the modem's port byte: the sides
--    top 0, bottom 1, left 2, right 3, front 4, back 5, a remote modem
--    "modem_N" 6 + N ("02:cc:00:00:0c:05" is computer 12's back).  VLANs
--    share their modem's MAC, as on a real router.  02:cc:ff is the ccnix
--    mod's (the gateway is 02:cc:ff:00:00:00); the broadcast MAC is
--    ff:ff:ff:ff:ff:ff.  A frame for another MAC is ignored.
--  * ARP: who has 10.0.1.5?  A request is broadcast; the owner answers
--    with its MAC.  Answers are kept ARP_TTL seconds.  Packets wait while
--    an address is asked for (ARP_TRIES requests, a second apart), then
--    are dropped as "host unreachable".
--  * IP (layer 3): addresses "a.b.c.d" with a prefix length ("10.0.1.5/24"),
--    a packet { src, dst, ttl, proto = "icmp" | "udp" | "tcp", data, id }.  Routes:
--    each interface's own network, and static ones ("10.0.2.0/24 via
--    10.0.1.1"; "default" is 0.0.0.0/0); the longest prefix wins.  A host
--    takes packets for its addresses, 127.x.x.x, 255.255.255.255 and its
--    networks' broadcast addresses; a router (forward = true) passes the
--    rest on, one less TTL.  A packet from a source that can't be real
--    (0.x, 127.x, 224.x and up, the network's broadcast address, one of
--    this computer's own) is dropped, and a router passes a packet on
--    only if its source passes the reverse-path filter (BCP 38, RFC
--    3704): rpfilter "loose" (the default) wants a route back to the
--    source, "strict" one out of the interface the packet came in on,
--    "off" nothing.
--  * ICMP: echo and echo reply (ping), destination unreachable (no route:
--    "net"; no ARP answer: "host"; no UDP socket: "port") and time exceeded
--    (TTL ran out: traceroute uses it).  Never an error about an error.
--  * UDP (layer 4): { sport, dport, data }; data is any value a modem can
--    carry (strings, numbers, tables).  Sockets queue what comes in.
--  * TCP (layer 4): connections carrying bytes, in order, sent again
--    until acknowledged.  The least of RFC 9293 that still works with a
--    real TCP stack: see "TCP" below for what's left out.
--  * Names: lib/netdb.lua looks them up (net.hosts, then DNS) as C's
--    netdb.h does, getaddrinfo and friends; net.resolve, and so connect
--    and a socket's send, take a name wherever they take an address.
--
-- Under init, a socket, listening port or connection belongs to the
-- process that opened it (netstat -p shows it; an accepted connection is
-- its listener's), and init closes them when that process ends
-- (S.closeOwned), so a port a killed service had is free again.
--
--   local conn = net.connect("10.0.2.5", 23)   -- or net.listen(23):accept()
--   conn:send("hello\r\n"); local s = conn:read(5); conn:close()
--
-- Bridging to a real network.  Packets are Lua tables, but laid out so a
-- bridge (a TUN device in the server, say, on one modem channel) can turn
-- them into real IPv4 and back field for field: the bridge is a host (or
-- router) on that channel, answering ARP for its address, with routes
-- pointing at it.  mod/ (the ccnix mod, a submodule) is one: a
-- block on CC cables, and a TUN device on the Minecraft server.
--   ARP   frame data { op = "request" | "reply", sha, spa, tpa, tha }: the
--         sender's MAC and address, the target's address and (in a reply)
--         MAC.
--   IP    { src, dst (numbers: a.b.c.d as a*2^24 + ...), ttl, id, proto,
--         data }; proto "icmp" = 1, "tcp" = 6, "udp" = 17.  No options,
--         fragments or TOS (the bridge reassembles, and fills in 0).
--   TCP   { sport, dport, seq, ack, syn, fin, rst, wnd, data }: ack is
--         present exactly when the ACK flag is; data is the payload as a
--         string; no options are sent or needed (MSS 536).  The bridge
--         adds the checksum, data offset and flag bits (PSH as it likes).
--   UDP   { sport, dport, data }: only a string payload can cross.
--   ICMP  { type = "echo" | "reply", id, seq, data } (8 and 0),
--         { type = "unreachable", code = "net" | "host" | "port" |
--         "prohibited", orig } (3: 0, 1, 3, 13: a filter, or a NAT-mode
--         Network Gateway refusing ping or a datagram) and { type = "timeexceeded", code = "ttl", orig }
--         (11: 0); orig holds the original packet's addresses, proto,
--         ports and ICMP id/seq rather than its first bytes.
--
-- What the stack counts, in S.counters (netstat -s prints them grouped):
-- forwarded, dropped (every packet thrown away, whatever the reason) and
-- spoofed (martian + rpfilter), as the router screen shows them; each
-- drop by its reason too (dropMalformed, dropMartian, dropRpfilter,
-- dropNotForwarding, dropTtl, dropNoRoute, dropArpQueue, dropNoArp,
-- dropUdpQueue); ipIn, ipDelivered, ipOut, outNoRoute; icmpIn<Type> and
-- icmpOut<Type> (Echo, Reply, Unreachable, TimeExceeded); udpIn, udpOut,
-- udpNoPort; tcpActiveOpens, tcpPassiveOpens, tcpSegsIn, tcpSegsOut,
-- tcpRetransmits, tcpResetsIn, tcpResetsOut; arpRequestsIn/Out,
-- arpRepliesIn/Out, arpTimeouts (addresses that never answered).  A
-- counter not counted yet is nil (read it as 0).
--
-- ComputerCraft has no background programs on a plain computer, so the
-- running stack lives in _G.ccnet and handles the network as events pass:
-- net.hook() wraps os.pullEventRaw, which every program's os.pullEvent,
-- sleep, read and parallel go through.  It answers ARP and ping, forwards,
-- and fills sockets whenever anything on the computer is waiting for an
-- event, which is nearly always.  A program that computes for a long time
-- without waiting holds it up (CC queues up to 256 events meanwhile).

local scan = require("scan")

local N = {}
N.CHANNEL = 60000             -- (VLANs up to 64094: clear of CC's own, 65533-65535, and of
                               -- rednet's, a computer's ID, but for IDs past 60000)
N.BROADCAST = "ff:ff:ff:ff:ff:ff"
N.TTL = 64
N.ALL = 4294967295              -- 255.255.255.255
local ARP_TTL = 300
local ARP_RETRY, ARP_TRIES = 1, 3
local QUEUE_MAX = 32            -- packets waiting on one ARP answer
local SOCKET_MAX = 64           -- datagrams a socket holds unread
local EPHEMERAL = 49152
local MSS = 536                 -- TCP: bytes in a segment (the default, with no options)
local RCV_WND = 4096            -- bytes a connection holds unread
local TCP_RTO, TCP_RTO_MAX = 1, 16   -- seconds before sending again, doubling
local TCP_RETRIES = 8
local TCP_KEEPIDLE = 10         -- quiet this long: a keepalive probe
local TCP_KEEPCNT = 3           -- probes unanswered: the connection is lost
local TCP_TIMEWAIT = 4

--------------------------------------------------------------------------
-- Addresses
--------------------------------------------------------------------------
function N.parseIP(s)
    if type(s) == "number" then return s end
    if type(s) ~= "string" then return nil end
    -- address: digits "." digits "." digits "." digits, each 0-255
    local parts = scan.split(s, ".", true)
    if #parts ~= 4 then return nil end
    local n = 0
    for _, part in ipairs(parts) do
        if part == "" or not scan.all(part, scan.isDigit) then return nil end
        local octet = tonumber(part)
        if octet > 255 then return nil end
        n = n * 256 + octet
    end
    return n
end

function N.ipString(n)
    if type(n) ~= "number" then return tostring(n) end
    local d = n % 256; n = (n - d) / 256
    local c = n % 256; n = (n - c) / 256
    local b = n % 256
    local a = (n - b) / 256
    return string.format("%d.%d.%d.%d", a, b, c, d)
end

-- "10.0.1.5/24" -> ip, 24 ("default" is 0.0.0.0/0; no /len: 32).
function N.parseCIDR(s)
    if s == "default" then return 0, 0 end
    -- cidr: address ["/" digits]
    local ip, len = scan.cut(tostring(s), "/")
    if len == nil then
        ip, len = s, "32"
    elseif len == "" or not scan.all(len, scan.isDigit) then
        return nil
    end
    ip, len = N.parseIP(ip), tonumber(len)
    if not ip or not len or len > 32 then return nil end
    return ip, len
end

-- An interface name's modem and channel: "back" -> "back", 60000;
-- "back.20" -> "back", 60020 (VLAN 20).  nil for a bad VLAN.
function N.link(name)
    -- name: modem ["." digits]
    local modem, vlan = scan.cutLast(name, ".")
    if vlan == nil or vlan == "" or not scan.all(vlan, scan.isDigit) then return name, N.CHANNEL, nil end
    vlan = tonumber(vlan)
    if vlan < 1 or vlan > 4094 then return nil end
    return modem, N.CHANNEL + vlan, vlan
end

-- MACs: 02:cc:<computer ID, 3 bytes>:<port byte> (see the top).
N.SIDES = { top = 0, bottom = 1, left = 2, right = 3, front = 4, back = 5 }

-- A modem's port byte: its side's, 6 + N for a remote "modem_N" (N up to
-- 249), else a hash of its name into 6-255.
function N.port(modem)
    if N.SIDES[modem] then return N.SIDES[modem] end
    local digits = scan.startsWith(modem, "modem_") and modem:sub(#"modem_" + 1)
    local n = digits and digits ~= "" and scan.all(digits, scan.isDigit) and tonumber(digits)
    if n and n <= 249 then return 6 + n end
    local h = 0
    for i = 1, #modem do h = (h * 31 + modem:byte(i)) % 250 end
    return 6 + h
end

-- Computer id's MAC on a modem (an ID past 0xfeffff wraps: 02:cc:ff is the mod's).
function N.mac(id, modem)
    local n = math.floor(tonumber(id) or 0) % 0xff0000
    return string.format("02:cc:%02x:%02x:%02x:%02x", math.floor(n / 65536), math.floor(n / 256) % 256, n % 256,
        N.port(modem))
end

-- "02:CC:00:00:0C:05" or "02-cc-00-00-0c-05" -> "02:cc:00:00:0c:05"; nil if not a MAC.
function N.parseMAC(s)
    if type(s) ~= "string" then return nil end
    -- mac: 6 pairs of hex digits, between each a ":" or "-"
    local sc, b = scan.new(s:lower()), {}
    for i = 1, 6 do
        if i > 1 and not (sc:accept(":") or sc:accept("-")) then return nil end
        if not (scan.isHexDigit(sc:peek(1)) and scan.isHexDigit(sc:peek(2))) then return nil end
        b[i] = sc:advance(2)
    end
    if not sc:atEnd() then return nil end
    return table.concat(b, ":")
end

local function netOf(ip, len)
    if len <= 0 then return 0 end
    local size = 2 ^ (32 - len)
    return math.floor(ip / size) * size
end
local function broadcastOf(ip, len) return netOf(ip, len) + 2 ^ (32 - len) - 1 end

function N.cidrString(ip, len) return N.ipString(ip) .. "/" .. len end

-- A reverse-path filter mode: "strict", "loose" or "off" (on or true:
-- loose, false: off); anything else, unset included, is "loose".
function N.rpfilter(v)
    if v == "strict" or v == "off" then return v end
    if v == false then return "off" end
    return "loose"
end

--------------------------------------------------------------------------
-- The stack
--------------------------------------------------------------------------
-- opts: id (the computer's), transmit(ifc, frame) (ifc.modem, ifc.channel),
-- queue(event, ...)
-- (os.queueEvent), clock() (seconds), forward (a router), rpfilter
-- ("loose", "strict" or "off"; see N.rpfilter), log(msg, severity) (each
-- note: a dropped packet, no ARP answer; severity 3 for the hook's own
-- errors, else nil).
function N.new(opts)
    local S = {
        id = opts.id, forward = opts.forward or false, rpfilter = N.rpfilter(opts.rpfilter),
        ifaces = {}, links = {}, routes = {}, arp = {}, pending = {}, sockets = {}, tcpPorts = {},
        counters = { forwarded = 0, dropped = 0, spoofed = 0 },
        log = {},
        taps = {},          -- fn(dir, iface, frame): every frame in ("in") or out ("out"), as tcpdump wants
    }
    local clock = opts.clock or os.clock
    -- the process that opens a socket (under init), for netstat -p
    local owner = opts.owner or function()
        local proc = rawget(_G, "proc")
        return proc and proc.self and proc.self() or nil
    end
    local transmit = opts.transmit
    local queue = opts.queue or os.queueEvent
    local nextId, nextPort = 0, EPHEMERAL
    S.wantTick = function() end         -- the hook asks for a tick soon
    S.clock = clock                     -- (for ip neigh's seconds left)

    -- Counting (see the top): one more of `name`; a drop, by its reason.
    local counters = S.counters
    local function count(name) counters[name] = (counters[name] or 0) + 1 end
    local function drop(why)
        counters.dropped = counters.dropped + 1
        count(why)
    end

    local function note(msg, sev)
        S.log[#S.log + 1] = msg
        if #S.log > 50 then table.remove(S.log, 1) end
        if opts.log then opts.log(msg, sev) end
    end
    S.note = note

    ----------------------------------------------------------------------
    -- Configuration
    ----------------------------------------------------------------------
    local function rebuildConnected()
        local keep = {}
        for _, r in ipairs(S.routes) do if not r.connected then keep[#keep + 1] = r end end
        for _, ifc in pairs(S.ifaces) do
            keep[#keep + 1] = { net = netOf(ifc.ip, ifc.len), len = ifc.len, iface = ifc.name, connected = true }
        end
        S.routes = keep
    end

    function S.addInterface(name, cidr)
        local ip, len = N.parseCIDR(cidr)
        if not ip then return false, "bad address " .. tostring(cidr) end
        local modem, channel, vlan = N.link(name)
        if not modem then return false, "bad VLAN in " .. name .. " (1-4094)" end
        if S.ifaces[name] then S.links[S.ifaces[name].modem .. "|" .. S.ifaces[name].channel] = nil end
        S.ifaces[name] = { name = name, ip = ip, len = len, mac = N.mac(S.id, modem), rx = 0, tx = 0,
                           modem = modem, channel = channel, vlan = vlan }
        S.links[modem .. "|" .. channel] = name
        S.arp[name] = S.arp[name] or {}
        rebuildConnected()
        return true
    end

    function S.removeInterface(name)
        local ifc = S.ifaces[name]
        if ifc then S.links[ifc.modem .. "|" .. ifc.channel] = nil end
        S.ifaces[name] = nil
        S.arp[name] = nil
        local keep = {}
        for _, r in ipairs(S.routes) do if r.iface ~= name then keep[#keep + 1] = r end end
        S.routes = keep
        rebuildConnected()
    end

    -- A static route: cidr via gw (the interface whose network has gw, or
    -- `iface`).
    function S.addRoute(cidr, gw, iface)
        local net, len = N.parseCIDR(cidr)
        if not net then return false, "bad network " .. tostring(cidr) end
        local g = gw and N.parseIP(gw)
        if gw and not g then return false, "bad gateway " .. tostring(gw) end
        if not iface and g then
            for _, ifc in pairs(S.ifaces) do
                if netOf(g, ifc.len) == netOf(ifc.ip, ifc.len) then iface = ifc.name end
            end
        end
        if not iface or not S.ifaces[iface] then
            return false, "no interface on " .. (gw and ("the gateway's network (" .. gw .. ")") or "that network")
        end
        S.deleteRoute(cidr)
        S.routes[#S.routes + 1] = { net = netOf(net, len), len = len, gw = g, iface = iface }
        return true
    end

    function S.deleteRoute(cidr)
        local net, len = N.parseCIDR(cidr)
        if not net then return false end
        local keep, gone = {}, false
        for _, r in ipairs(S.routes) do
            if not r.connected and r.net == netOf(net, len) and r.len == len then gone = true
            else keep[#keep + 1] = r end
        end
        S.routes = keep
        return gone
    end

    -- The route to dst: the longest prefix that holds it (of those by
    -- interface iface, if given).
    function S.route(dst, iface)
        local best
        for _, r in ipairs(S.routes) do
            if netOf(dst, r.len) == r.net and (not best or r.len > best.len) and S.ifaces[r.iface]
                and (iface == nil or r.iface == iface) then best = r end
        end
        return best
    end

    local function isMine(ip)
        if math.floor(ip / 16777216) == 127 then return true end
        for _, ifc in pairs(S.ifaces) do if ifc.ip == ip then return true end end
        return false
    end
    S.isMine = isMine

    ----------------------------------------------------------------------
    -- Link
    ----------------------------------------------------------------------
    -- Each tap sees the frame (one that fails is dropped from the taps).
    local function tapped(dir, iface, f)
        for k, fn in pairs(S.taps) do
            if not pcall(fn, dir, iface, f) then S.taps[k] = nil end
        end
    end

    local function sendFrame(ifc, dst, kind, data)
        ifc.tx = ifc.tx + 1
        local f = { ccnet = 1, dst = dst, src = ifc.mac, type = kind, data = data }
        if next(S.taps) then tapped("out", ifc.name, f) end
        transmit(ifc, f)
    end

    local function arpAsk(p)
        local ifc = S.ifaces[p.iface]
        if not ifc then return end
        p.tries, p.next = p.tries + 1, clock() + ARP_RETRY
        count("arpRequestsOut")
        sendFrame(ifc, N.BROADCAST, "arp", { op = "request", sha = ifc.mac, spa = ifc.ip, tpa = p.ip })
        S.wantTick()
    end

    -- Learn ip -> mac on an interface, and send what was waiting for it
    -- (a permanent entry, set by hand, stays as it is).
    local function learn(ifc, ip, mac)
        local e = S.arp[ifc.name][ip]
        if not (e and e.permanent) then S.arp[ifc.name][ip] = { mac = mac, expires = clock() + ARP_TTL } end
        local key = ifc.name .. "|" .. ip
        local p = S.pending[key]
        if p then
            S.pending[key] = nil
            for _, q in ipairs(p.packets) do sendFrame(ifc, mac, "ip", q.pkt) end
        end
    end

    -- A permanent ARP entry (`ip neigh add`): ip -> mac on iface (nil: the
    -- interface whose network ip is on), never expiring, never replaced
    -- by what ARP hears.  True, or false and why.
    function S.addNeighbour(ip, mac, iface)
        local n = type(ip) == "number" and ip or N.parseIP(ip)
        if not n then return false, "bad address " .. tostring(ip) end
        local m = N.parseMAC(mac)
        if not m then return false, "bad MAC " .. tostring(mac) end
        if not iface then
            for name, ifc in pairs(S.ifaces) do
                if netOf(n, ifc.len) == netOf(ifc.ip, ifc.len) then iface = name end
            end
            if not iface then return false, "no interface on " .. N.ipString(n) .. "'s network (give dev)" end
        end
        local ifc = S.ifaces[iface]
        if not ifc then return false, "no interface " .. iface end
        S.arp[iface][n] = { mac = m, expires = math.huge, permanent = true }
        learn(ifc, n, m)                    -- (what was waiting for it goes)
        return true
    end

    -- Forget ip's ARP entry, permanent or learned, on iface (nil: all).
    -- True if there was one.
    function S.deleteNeighbour(ip, iface)
        local n = type(ip) == "number" and ip or N.parseIP(ip)
        if not n then return false end
        local gone = false
        for name, cache in pairs(S.arp) do
            if (not iface or name == iface) and cache[n] then cache[n] = nil; gone = true end
        end
        return gone
    end

    -- What ARP knows of ip on iface: { iface, ip, state, mac, left,
    -- queued, tries }.  state is "permanent" (set by hand), "reachable"
    -- (learned: left is the seconds it has to go), "incomplete" (asked
    -- for, no answer yet: queued packets wait, tries requests sent so far)
    -- or nil (nothing: the next packet there asks).
    function S.neighbour(iface, ip)
        local e = S.arp[iface] and S.arp[iface][ip]
        local n = { iface = iface, ip = ip }
        if e and e.permanent then
            n.state, n.mac = "permanent", e.mac
        elseif e and e.expires > clock() then
            n.state, n.mac, n.left = "reachable", e.mac, e.expires - clock()
        end
        local p = S.pending[iface .. "|" .. ip]
        if p and not n.state then n.state, n.queued, n.tries = "incomplete", #p.packets, p.tries end
        return n
    end

    -- Every neighbour ARP has or is asking for (S.neighbour's), by
    -- interface then address.
    function S.neighbours()
        local list, seen = {}, {}
        local function add(iface, ip)
            local key = iface .. "|" .. ip
            if seen[key] then return end
            seen[key] = true
            local n = S.neighbour(iface, ip)
            if n.state then list[#list + 1] = n end
        end
        for iface, cache in pairs(S.arp) do
            for ip in pairs(cache) do add(iface, ip) end
        end
        for _, p in pairs(S.pending) do add(p.iface, p.ip) end
        table.sort(list, function(a, b)
            if a.iface ~= b.iface then return a.iface < b.iface end
            return a.ip < b.ip
        end)
        return list
    end

    local icmpError                 -- (below)

    -- Send pkt out of route r's interface: to the gateway or, on the
    -- interface's own network, straight to dst (asking ARP first).
    local function output(pkt, r, mine)
        local ifc = S.ifaces[r.iface]
        if pkt.dst == N.ALL or pkt.dst == broadcastOf(ifc.ip, ifc.len) then
            return sendFrame(ifc, N.BROADCAST, "ip", pkt)
        end
        local hop = r.gw or pkt.dst
        local e = S.arp[ifc.name][hop]
        if e and e.expires > clock() then return sendFrame(ifc, e.mac, "ip", pkt) end
        local key = ifc.name .. "|" .. hop
        local p = S.pending[key]
        if not p then
            p = { iface = ifc.name, ip = hop, packets = {}, tries = 0, next = 0 }
            S.pending[key] = p
        end
        if #p.packets < QUEUE_MAX then p.packets[#p.packets + 1] = { pkt = pkt, mine = mine }
        else drop("dropArpQueue") end
        if p.tries == 0 then arpAsk(p) end
    end

    ----------------------------------------------------------------------
    -- IP out
    ----------------------------------------------------------------------
    local deliver                   -- (below)

    -- the counter for an ICMP message of each type, in and out
    local ICMP_IN = { echo = "icmpInEcho", reply = "icmpInReply", unreachable = "icmpInUnreachable",
                      timeexceeded = "icmpInTimeExceeded" }
    local ICMP_OUT = { echo = "icmpOutEcho", reply = "icmpOutReply", unreachable = "icmpOutUnreachable",
                       timeexceeded = "icmpOutTimeExceeded" }

    -- Send data to dst (an address, as a string or number).  True, or
    -- false and why (no route).  An ARP that gets no answer comes back
    -- later as a net_unreachable event.  The source is src if it's one of
    -- this computer's addresses (an answer comes from the address it was
    -- sent to, as RFC 1122 has it), else the outgoing interface's.  With
    -- iface, it goes out of that interface or not at all (ping -I).
    function S.sendIP(dst, proto, data, ttl, src, iface)
        dst = N.parseIP(dst)
        if not dst then return false, "bad address" end
        nextId = nextId + 1
        count("ipOut")
        if proto == "icmp" and type(data) == "table" and ICMP_OUT[data.type] then count(ICMP_OUT[data.type]) end
        if isMine(dst) then
            deliver({ src = dst, dst = dst, ttl = ttl or N.TTL, proto = proto, data = data, id = nextId }, "lo")
            return true
        end
        if dst == N.ALL then
            local any = false
            for _, ifc in pairs(S.ifaces) do
                if iface == nil or ifc.name == iface then
                    sendFrame(ifc, N.BROADCAST, "ip",
                        { src = ifc.ip, dst = dst, ttl = ttl or N.TTL, proto = proto, data = data, id = nextId })
                    any = true
                end
            end
            return any, not any and "no interfaces" or nil
        end
        local r = S.route(dst, iface)
        if not r then
            count("outNoRoute")
            return false, "no route to " .. N.ipString(dst) .. (iface and (" via " .. iface) or "")
        end
        local ifc = S.ifaces[r.iface]
        if not (src and src ~= N.ALL and math.floor(src / 16777216) ~= 127 and isMine(src)) then src = ifc.ip end
        output({ src = src, dst = dst, ttl = ttl or N.TTL, proto = proto, data = data, id = nextId }, r, true)
        return true
    end

    -- The way sendIP would send a packet to dst (out of iface, if given),
    -- as `ip route get` shows it: { dst, kind, iface, src, route, gw,
    -- hop, neigh }, or nil and why (no route).  kind is "local" (this
    -- computer: iface "lo"), "broadcast" (255.255.255.255: every
    -- interface, iface nil; or a network's broadcast address) or
    -- "unicast": route the one picked, gw its gateway (nil: dst is on the
    -- interface's own network), hop the address ARP is asked for, neigh
    -- what ARP knows of it (S.neighbour).
    function S.routeGet(dst, iface)
        dst = N.parseIP(dst)
        if not dst then return nil, "bad address" end
        if isMine(dst) then return { dst = dst, kind = "local", iface = "lo", src = dst } end
        if dst == N.ALL then return { dst = dst, kind = "broadcast" } end
        local r = S.route(dst, iface)
        if not r then return nil, "no route to " .. N.ipString(dst) .. (iface and (" via " .. iface) or "") end
        local ifc = S.ifaces[r.iface]
        local way = { dst = dst, kind = "unicast", iface = r.iface, src = ifc.ip, route = r, gw = r.gw }
        if dst == broadcastOf(ifc.ip, ifc.len) then
            way.kind = "broadcast"
            return way
        end
        way.hop = r.gw or dst
        way.neigh = S.neighbour(r.iface, way.hop)
        return way
    end

    -- An ICMP error about pkt, to its sender (or, if this computer sent
    -- it, an event for the program that did).
    icmpError = function(pkt, kind, code, mine)
        if pkt.proto == "icmp" and type(pkt.data) == "table" and pkt.data.type ~= "echo" then return end
        local d = type(pkt.data) == "table" and pkt.data or {}
        local orig = { src = pkt.src, dst = pkt.dst, proto = pkt.proto, id = d.id, seq = d.seq,
                       sport = d.sport, dport = d.dport }
        if mine or isMine(pkt.src) then
            queue("net_icmp", kind, N.ipString(pkt.dst), code, orig)
            return
        end
        S.sendIP(pkt.src, "icmp", { type = kind, code = code, orig = orig })
    end

    ----------------------------------------------------------------------
    -- In
    ----------------------------------------------------------------------
    local function udpIn(pkt, iface)
        local d = pkt.data
        if type(d) ~= "table" or type(d.dport) ~= "number" then return end
        local sock = S.sockets[d.dport]
        if not sock then
            count("udpNoPort")
            if pkt.dst ~= N.ALL and isMine(pkt.dst) then icmpError(pkt, "unreachable", "port") end
            return
        end
        if #sock.queue >= SOCKET_MAX then return drop("dropUdpQueue") end
        count("udpIn")
        sock.queue[#sock.queue + 1] = { data = d.data, src = N.ipString(pkt.src), sport = d.sport, iface = iface }
        queue("net_udp", d.dport)
    end

    deliver = function(pkt, iface)
        count("ipDelivered")
        if pkt.proto == "icmp" and type(pkt.data) == "table" then
            local d = pkt.data
            if ICMP_IN[d.type] then count(ICMP_IN[d.type]) end
            if d.type == "echo" then
                if pkt.dst ~= N.ALL then
                    S.sendIP(pkt.src, "icmp", { type = "reply", id = d.id, seq = d.seq, data = d.data }, nil, pkt.dst)
                end
            elseif d.type == "reply" then
                queue("net_icmp", "reply", N.ipString(pkt.src), d.id, d.seq, pkt.ttl, d.data)
            elseif d.type == "unreachable" or d.type == "timeexceeded" then
                queue("net_icmp", d.type, N.ipString(pkt.src), d.code, d.orig or {})
            end
        elseif pkt.proto == "udp" then
            udpIn(pkt, iface)
        elseif pkt.proto == "tcp" then
            S.tcpIn(pkt)
        end
    end

    -- A source no packet can honestly come from (RFC 1812, 5.3.7): 0.x,
    -- 127.x, 224.x and up (255.255.255.255 too), the network's broadcast
    -- address, or one of this computer's addresses.
    local function martian(ifc, src)
        local a = math.floor(src / 16777216)
        return a == 0 or a == 127 or a >= 224 or isMine(src)
            or (ifc.len < 31 and src == broadcastOf(ifc.ip, ifc.len))
    end

    -- BCP 38: may a packet from src, in on ifc, be passed on?  Loose: if
    -- there's a route back to src; strict: if that route leaves by ifc.
    local function sourceOk(ifc, src)
        if S.rpfilter == "off" then return true end
        local r = S.route(src)
        return r ~= nil and (S.rpfilter ~= "strict" or r.iface == ifc.name)
    end

    -- Dropped, silently (an error would go to the forged source); reason:
    -- the counter, why: the note.
    local function spoofed(ifc, pkt, reason, why)
        drop(reason)
        counters.spoofed = counters.spoofed + 1
        note(string.format("dropped %s > %s in on %s: %s", N.ipString(pkt.src), N.ipString(pkt.dst), ifc.name, why))
    end

    local function ipIn(ifc, pkt)
        if type(pkt) ~= "table" or type(pkt.src) ~= "number" or type(pkt.dst) ~= "number"
            or type(pkt.ttl) ~= "number" then return drop("dropMalformed") end
        count("ipIn")
        if martian(ifc, pkt.src) then return spoofed(ifc, pkt, "dropMartian", "a source that can't be") end
        if pkt.dst == N.ALL or isMine(pkt.dst) or pkt.dst == broadcastOf(ifc.ip, ifc.len) then
            return deliver(pkt, ifc.name)
        end
        if not S.forward then return drop("dropNotForwarding") end
        if not sourceOk(ifc, pkt.src) then
            return spoofed(ifc, pkt, "dropRpfilter", "the source fails rpfilter " .. S.rpfilter)
        end
        if pkt.ttl <= 1 then
            drop("dropTtl")
            return icmpError(pkt, "timeexceeded", "ttl")
        end
        local r = S.route(pkt.dst)
        if not r then
            drop("dropNoRoute")
            return icmpError(pkt, "unreachable", "net")
        end
        local copy = {}
        for k, v in pairs(pkt) do copy[k] = v end
        copy.ttl = pkt.ttl - 1
        counters.forwarded = counters.forwarded + 1
        output(copy, r, false)
    end

    local function arpIn(ifc, a)
        if type(a) ~= "table" or type(a.spa) ~= "number" or type(a.sha) ~= "string" then return end
        count(a.op == "request" and "arpRequestsIn" or "arpRepliesIn")
        local known = S.arp[ifc.name][a.spa]
        if a.tpa == ifc.ip then
            learn(ifc, a.spa, a.sha)
            if a.op == "request" then
                count("arpRepliesOut")
                sendFrame(ifc, a.sha, "arp", { op = "reply", sha = ifc.mac, spa = ifc.ip, tha = a.sha, tpa = a.spa })
            end
        elseif known then
            learn(ifc, a.spa, a.sha)        -- (it moved: keep up)
        end
    end

    -- A frame from interface `iface`.
    function S.handleFrame(iface, f)
        if type(f) ~= "table" or f.ccnet ~= 1 then return end
        local ifc = S.ifaces[iface]
        if not ifc or f.src == ifc.mac then return end
        if f.dst ~= ifc.mac and f.dst ~= N.BROADCAST then return end
        ifc.rx = ifc.rx + 1
        if f.type == "arp" then arpIn(ifc, f.data)
        elseif f.type == "ip" then ipIn(ifc, f.data) end
    end

    -- A modem_message: the interface that's modem `side` on `channel`
    -- takes it (none: not the stack's).  True if it was the stack's.  The
    -- taps see it first, even a frame for another MAC (a modem hears every
    -- frame on its channel, as a promiscuous NIC does).
    function S.receive(side, channel, f)
        local name = S.links[side .. "|" .. tostring(channel)]
        if not name then return false end
        if next(S.taps) then tapped("in", name, f) end
        S.handleFrame(name, f)
        return true
    end

    -- ARP retries and expiry; true while something is still waiting.
    function S.tick()
        local now = clock()
        for key, p in pairs(S.pending) do
            if now >= p.next then
                if p.tries >= ARP_TRIES then
                    S.pending[key] = nil
                    count("arpTimeouts")
                    note("no ARP answer from " .. N.ipString(p.ip) .. " on " .. p.iface)
                    for _, q in ipairs(p.packets) do
                        drop("dropNoArp")
                        icmpError(q.pkt, "unreachable", "host", q.mine)
                    end
                else
                    arpAsk(p)
                end
            end
        end
        for _, cache in pairs(S.arp) do
            for ip, e in pairs(cache) do if e.expires <= now then cache[ip] = nil end end
        end
        local tcp = S.tcpTick(now)
        return next(S.pending) ~= nil or tcp
    end

    ----------------------------------------------------------------------
    -- UDP sockets and ping
    ----------------------------------------------------------------------
    -- An ephemeral port no socket, connection or listener has; nil if none.
    local function freePort()
        for _ = 1, 16384 do
            nextPort = nextPort >= 65535 and EPHEMERAL or nextPort + 1
            if not S.sockets[nextPort] and not S.tcpPorts[nextPort] and not S.listeners[nextPort] then return nextPort end
        end
    end

    function S.udpOpen(port)
        if port then
            if S.sockets[port] then return nil, "port " .. port .. " is in use" end
        else
            port = freePort()
            if not port then return nil, "no free port" end
        end
        S.sockets[port] = { queue = {}, pid = owner() }
        return port
    end
    function S.udpClose(port) S.sockets[port] = nil end
    function S.udpSend(sport, dst, dport, data)
        count("udpOut")
        return S.sendIP(dst, "udp", { sport = sport, dport = dport, data = data })
    end
    function S.udpTake(port)
        local sock = S.sockets[port]
        if sock and sock.queue[1] then return table.remove(sock.queue, 1) end
    end

    -- An echo request (src and iface as sendIP's), carrying data (a string,
    -- or nil): the reply brings it back (ping -s).
    function S.echo(dst, id, seq, ttl, src, iface, data)
        return S.sendIP(dst, "icmp", { type = "echo", id = id, seq = seq, data = data }, ttl, src, iface)
    end

    ----------------------------------------------------------------------
    -- TCP: the least of RFC 9293 that still talks to a real stack
    ----------------------------------------------------------------------
    -- A segment is { sport, dport, seq, ack, syn, fin, rst, wnd, data }:
    -- the TCP header's fields (ack present = the ACK flag; data a string
    -- of bytes).  Sequence numbers count bytes, mod 2^32; SYN and FIN take
    -- one each.  Kept simple:
    --   * no options: segments of up to MSS (536) bytes, the default;
    --   * a fixed receive window (RCV_WND bytes, less what's unread);
    --   * only the next byte expected is taken: a segment out of order is
    --     dropped and the last ACK sent again (the sender resends);
    --   * after an RTO everything unacked goes again (go back N), the RTO
    --     doubling each time, up to TCP_RETRIES tries; a zero window gets
    --     an empty probe (seq one before snd.una) instead, for as long as
    --     the other side answers;
    --   * keepalive: quiet for TCP_KEEPIDLE, a probe (seq one before
    --     snd.nxt, which any stack answers with an ACK); TCP_KEEPCNT
    --     unanswered and the connection is lost;
    --   * TIME_WAIT lasts TCP_TIMEWAIT seconds, not 2 MSL.
    S.listeners, S.tcbs = {}, {}
    local M32 = 4294967296
    local nextConn = 0

    local function add(a, n) return (a + n) % M32 end
    local function minus(a, b)          -- a - b, signed, mod 2^32
        local d = (a - b) % M32
        return d >= M32 / 2 and d - M32 or d
    end
    local function key(lport, rip, rport) return lport .. "|" .. rip .. "|" .. rport end
    local function window(c) return math.max(0, RCV_WND - #c.inbox) end
    local function event(c) queue("net_tcp", c.id) end

    local function emit(c, seg)
        seg.sport, seg.dport, seg.wnd, seg.data = c.lport, c.rport, window(c), seg.data or ""
        if seg.ack == nil then seg.ack = c.rcvNxt end   -- (nil before the SYN: no ACK flag)
        c.lastSent = clock()
        count("tcpSegsOut")
        if seg.rst then count("tcpResetsOut") end
        return S.sendIP(c.rip, "tcp", seg, nil, c.lip)        -- (lip: the address a SYN came in on)
    end

    local function newTcb(lport, rip, rport, state)
        nextConn = nextConn + 1
        local iss = math.random(0, 65535) * 65536 + math.random(0, 65535)
        local c = { id = nextConn, lport = lport, rip = rip, rport = rport, state = state, iss = iss,
                    sndUna = iss, sndNxt = add(iss, 1), sndMax = add(iss, 1), sndWnd = MSS,
                    out = "", inbox = "", rto = TCP_RTO, tries = 0, probes = 0,
                    lastHeard = clock(), lastSent = clock(), rtxAt = clock() }
        S.tcbs[key(lport, rip, rport)] = c
        S.wantTick()
        return c
    end

    -- Over: why (nil: closed in order).
    local function finish(c, why)
        if c.state == "CLOSED" then return end
        c.state, c.err = "CLOSED", why
        S.tcbs[key(c.lport, c.rip, c.rport)] = nil
        if S.tcpPorts[c.lport] == c then S.tcpPorts[c.lport] = nil end
        event(c)
    end

    local function sent(c, n)
        if c.sndUna == c.sndNxt then c.rtxAt = clock() end     -- (the timer starts with the first unacked)
        c.sndNxt = add(c.sndNxt, n)
        if minus(c.sndNxt, c.sndMax) > 0 then c.sndMax = c.sndNxt end
    end

    -- Send from snd.nxt what the peer's window allows; then, everything
    -- out and our side closing, the FIN.  (c.out: bytes from snd.una on.)
    local function push(c)
        if c.state == "SYN_SENT" or c.state == "SYN_RCVD" or c.state == "CLOSED" then return end
        while true do
            local off = minus(c.sndNxt, c.sndUna)
            local room = minus(add(c.sndUna, c.sndWnd), c.sndNxt)
            local chunk = c.out:sub(off + 1, off + math.min(MSS, room))
            if #chunk == 0 then break end
            local seq = c.sndNxt
            sent(c, #chunk)                             -- (first: the answer can come back at once, on loopback)
            emit(c, { seq = seq, data = chunk })
        end
        if c.closing and not c.finAcked and c.sndNxt == add(c.sndUna, #c.out) then
            local seq = c.sndNxt
            sent(c, 1)
            emit(c, { seq = seq, fin = true })
        end
    end

    -- The state from the two halves: ours (FIN acked) and theirs (FIN in).
    local function settle(c)
        if c.state == "SYN_SENT" or c.state == "SYN_RCVD" or c.state == "CLOSED" or c.state == "TIME_WAIT" then return end
        if c.peerFin and c.finAcked then
            if c.passive then return finish(c, nil) end     -- (LAST_ACK: done)
            c.state, c.timeWait = "TIME_WAIT", clock()
            event(c)
        elseif c.peerFin then c.state = c.closing and "LAST_ACK" or "CLOSE_WAIT"
        elseif c.closing then c.state = c.finAcked and "FIN_WAIT_2" or "FIN_WAIT_1"
        else c.state = "ESTABLISHED" end
    end

    -- A reset for a segment with no connection (RFC 9293 3.10.7.1).
    local function resetFor(pkt, d)
        if d.rst then return end
        count("tcpSegsOut")
        count("tcpResetsOut")
        local seg = { sport = d.dport, dport = d.sport, rst = true, wnd = 0, data = "" }
        if d.ack then
            seg.seq = d.ack
        else
            seg.seq = 0
            seg.ack = add(d.seq, #(d.data or "") + (d.syn and 1 or 0) + (d.fin and 1 or 0))
        end
        S.sendIP(pkt.src, "tcp", seg, nil, pkt.dst)
    end

    function S.tcpIn(pkt)
        local d = pkt.data
        if type(d) ~= "table" or type(d.dport) ~= "number" or type(d.sport) ~= "number"
            or type(d.seq) ~= "number" or (d.data ~= nil and type(d.data) ~= "string") then return end
        local data = d.data or ""
        count("tcpSegsIn")
        if d.rst then count("tcpResetsIn") end
        local c = S.tcbs[key(d.dport, pkt.src, d.sport)]

        if not c then                                   -- LISTEN, or nothing there
            local l = S.listeners[d.dport]
            if l and d.syn and not d.ack and not d.rst then
                count("tcpPassiveOpens")
                c = newTcb(d.dport, pkt.src, d.sport, "SYN_RCVD")
                c.listener, c.rcvNxt, c.sndWnd, c.lip = d.dport, add(d.seq, 1), d.wnd or MSS, pkt.dst
                c.pid = l.pid
                emit(c, { seq = c.iss, syn = true })
            else
                resetFor(pkt, d)
            end
            return
        end
        c.lastHeard, c.probes = clock(), 0

        if c.state == "SYN_SENT" then
            if d.ack and d.ack ~= c.sndNxt then return resetFor(pkt, d) end
            if d.rst then
                if d.ack then finish(c, "connection refused") end
            elseif d.syn and d.ack then
                c.rcvNxt, c.sndUna, c.sndWnd = add(d.seq, 1), d.ack, d.wnd or MSS
                c.state, c.tries, c.rto = "ESTABLISHED", 0, TCP_RTO
                emit(c, { seq = c.sndNxt })
                push(c)
                event(c)
            end
            return
        end

        -- only what starts at or before rcv.nxt and reaches past it (or an
        -- empty segment right at it) is taken
        local off = minus(d.seq, c.rcvNxt)
        local len = #data + (d.syn and 1 or 0) + (d.fin and 1 or 0)
        local ok = (len == 0 and off == 0) or (off <= 0 and off + len > 0)
        if d.rst then
            if off == 0 then finish(c, (c.closing or c.peerFin) and nil or "connection reset") end
            return
        end
        if d.syn then                                   -- (their SYN again: our SYN-ACK was lost)
            emit(c, c.state == "SYN_RCVD" and { seq = c.iss, syn = true } or { seq = c.sndNxt })
            return
        end
        if not ok then return emit(c, { seq = c.sndNxt }) end      -- (a repeat, a probe, out of order)
        if not d.ack then return end

        if c.state == "SYN_RCVD" then
            if d.ack ~= add(c.iss, 1) then return resetFor(pkt, d) end
            c.sndUna, c.state = d.ack, "ESTABLISHED"
            local l = S.listeners[c.listener]
            if l then l[#l + 1] = c; queue("net_accept", c.listener) end
        end
        local acked = minus(d.ack, c.sndUna)
        if acked > 0 and minus(d.ack, c.sndMax) <= 0 then
            if c.closing and acked > #c.out then c.finAcked = true end
            c.out = c.out:sub(math.min(acked, #c.out) + 1)
            c.sndUna, c.tries, c.rto, c.rtxAt = d.ack, 0, TCP_RTO, clock()
            if minus(c.sndNxt, d.ack) < 0 then c.sndNxt = d.ack end
        end
        c.sndWnd = d.wnd or c.sndWnd
        if c.sndWnd == 0 then c.tries = 0 end           -- (they're there, just full: keep probing)

        if c.state ~= "TIME_WAIT" and not c.peerFin then
            local skip = -off                           -- (bytes we have already)
            local take = data:sub(skip + 1, skip + window(c))
            if #take > 0 then
                c.inbox = c.inbox .. take
                c.rcvNxt = add(c.rcvNxt, #take)
            end
            if d.fin and skip + #take == #data then
                c.peerFin, c.passive, c.rcvNxt = true, not c.closing, add(c.rcvNxt, 1)
            end
            if len > 0 then emit(c, { seq = c.sndNxt }) end
            if #take > 0 or c.peerFin then event(c) end
        end
        push(c)
        settle(c)
    end

    -- The timers: sending again, keepalive, TIME_WAIT.  True while any
    -- connection is open.
    function S.tcpTick(now)
        for _, c in pairs(S.tcbs) do
            local waiting = c.state == "SYN_SENT" or c.state == "SYN_RCVD" or #c.out > 0
                or (c.closing and not c.finAcked)
            if c.state == "TIME_WAIT" then
                if now - c.timeWait >= TCP_TIMEWAIT then finish(c, nil) end
            elseif waiting and now - c.rtxAt >= c.rto then
                c.tries, c.rtxAt, c.rto = c.tries + 1, now, math.min(c.rto * 2, TCP_RTO_MAX)
                if c.tries > TCP_RETRIES then
                    finish(c, c.state == "SYN_SENT" and "connection timed out" or "connection lost")
                elseif c.state == "SYN_SENT" or c.state == "SYN_RCVD" then
                    count("tcpRetransmits")
                    emit(c, { seq = c.iss, syn = true })
                elseif c.sndWnd == 0 and c.sndNxt == c.sndUna then
                    emit(c, { seq = add(c.sndUna, -1) })     -- a window probe: their ACK says the window
                else
                    count("tcpRetransmits")
                    c.sndNxt = c.sndUna                 -- go back N
                    push(c)
                end
            elseif not waiting and now - math.max(c.lastHeard, c.lastSent) >= TCP_KEEPIDLE then
                c.probes = c.probes + 1
                if c.probes > TCP_KEEPCNT then finish(c, "connection lost")
                else emit(c, { seq = add(c.sndNxt, -1) }) end
            end
        end
        return next(S.tcbs) ~= nil
    end

    function S.tcpListen(port)
        if S.listeners[port] then return nil, "port " .. port .. " is in use" end
        S.listeners[port] = { pid = owner() }           -- (and the connections made, waiting, in order)
        return true
    end
    function S.tcpUnlisten(port) S.listeners[port] = nil end
    -- The next connection made to port (established), or nil.
    function S.tcpAccept(port)
        local l = S.listeners[port]
        return l and table.remove(l, 1)
    end

    -- Open a connection to dst:dport: c.state is "SYN_SENT" until a
    -- net_tcp event (c.id) finds it "ESTABLISHED", or "CLOSED" (c.err).
    function S.tcpConnect(dst, dport)
        dst = N.parseIP(dst)
        if not dst then return nil, "bad address" end
        local lport = freePort()
        if not lport then return nil, "no free port" end
        count("tcpActiveOpens")
        local c = newTcb(lport, dst, dport, "SYN_SENT")
        c.pid = owner()
        S.tcpPorts[lport] = c
        local ok, err = emit(c, { seq = c.iss, syn = true })
        if not ok then finish(c, err); return nil, err end
        return c
    end

    -- Queue bytes on c.
    function S.tcpSend(c, s)
        if c.state == "CLOSED" then return false, c.err or "closed" end
        if c.closing then return false, "closed" end
        c.out = c.out .. s
        push(c)
        return true
    end

    -- What has come in on c (a string, maybe ""), and whether the other
    -- side has closed (no more will come).
    function S.tcpRead(c)
        local s, wasLow = c.inbox, window(c) < MSS
        c.inbox = ""
        if wasLow and #s > 0 and c.state ~= "CLOSED" then emit(c, { seq = c.sndNxt }) end   -- (the window opens)
        return s, c.peerFin == true or c.state == "CLOSED"
    end

    -- Close our half: what's queued still goes, then a FIN.
    function S.tcpClose(c)
        if c.state == "SYN_SENT" then return finish(c, nil) end
        if c.state == "CLOSED" or c.closing then return end
        c.closing = true
        push(c)
        settle(c)
    end

    -- Drop c at once, telling the other side (RST).
    function S.tcpAbort(c)
        if c.state == "CLOSED" then return end
        if c.state ~= "SYN_SENT" then emit(c, { seq = c.sndNxt, rst = true }) end
        finish(c, nil)
    end

    ----------------------------------------------------------------------
    -- A process gone
    ----------------------------------------------------------------------
    -- Process pid has ended (init's kernel says so as it reaps it): let go
    -- of what it had open, as Unix closes a dead process's files.  Its UDP
    -- sockets and listening ports close, with the connections waiting on
    -- them to be accepted (reset); its connections close as conn:close()
    -- does, or are reset if what came in was never read or they aren't
    -- open yet, as Linux does.  How many it let go.
    function S.closeOwned(pid)
        if pid == nil then return 0 end
        local n = 0
        for port, sock in pairs(S.sockets) do
            if sock.pid == pid then S.sockets[port] = nil; n = n + 1 end
        end
        for port, l in pairs(S.listeners) do
            if l.pid == pid then
                S.listeners[port] = nil
                for _, c in ipairs(l) do S.tcpAbort(c) end      -- (made, never accepted)
                n = n + 1
            end
        end
        local mine = {}
        for _, c in pairs(S.tcbs) do
            local done = c.closing or c.state == "TIME_WAIT" or c.state == "CLOSED"
            if c.pid == pid and not done then mine[#mine + 1] = c end
        end
        table.sort(mine, function(a, b) return a.id < b.id end)        -- (in the order they were made)
        for _, c in ipairs(mine) do
            local early = c.state == "SYN_SENT" or c.state == "SYN_RCVD"
            if c.inbox ~= "" or early then S.tcpAbort(c) else S.tcpClose(c) end
            n = n + 1
        end
        return n
    end

    return S
end

--------------------------------------------------------------------------
-- Running it: the hook over os.pullEventRaw
--------------------------------------------------------------------------
-- Install S into `osT` (os): every event any program waits for passes it
-- first.  A modem_message is handled once however many coroutines see it
-- (parallel hands each the same event).  Returns an uninstall function.
function N.hook(S, osT)
    local raw = osT.pullEventRaw
    local seen = setmetatable({}, { __mode = "k" })
    local timer
    S.wantTick = function() if not timer then timer = osT.startTimer(0.5) end end
    local function handle(ev, a, b, c, d)
        if S.dead then return end           -- (taken down, but something hooked on top of it)
        if ev == "modem_message" then
            if type(d) == "table" and not seen[d] and S.links[tostring(a) .. "|" .. tostring(b)] then
                seen[d] = true
                S.receive(a, b, d)
            end
        elseif ev == "timer" and a == timer then
            timer = nil
            if S.tick() then S.wantTick() end
        end
    end
    local function pull(filter)
        while true do
            local ev = table.pack(raw())
            local ok, err = pcall(handle, table.unpack(ev, 1, ev.n))
            if not ok then S.note("net: " .. tostring(err), 3) end
            if filter == nil or ev[1] == filter or ev[1] == "terminate" then return table.unpack(ev, 1, ev.n) end
        end
    end
    osT.pullEventRaw = pull
    S.unhook = function() if osT.pullEventRaw == pull then osT.pullEventRaw = raw end end
    return S.unhook
end

--------------------------------------------------------------------------
-- Configuration, kept in CraftOS's settings
--------------------------------------------------------------------------
-- net.if.<iface> = "10.0.1.5/24"; net.routes = "10.0.2.0/24 via 10.0.1.1,
-- default via 10.0.1.1"; net.forward = true on a router; net.rpfilter =
-- "strict" | "loose" | "off" (unset: loose); net.hosts =
-- "router=10.0.1.1, b=10.0.2.5"; net.dns = "1.1.1.1, 9.9.9.9" (the DNS
-- servers lib/netdb asks, primary first); net.neigh = "10.0.1.7 lladdr
-- 02:cc:00:00:07:05 dev back, ..." (permanent ARP entries).
function N.config(st)
    st = st or settings
    local cfg = { ifaces = {}, routes = {}, forward = st.get("net.forward") == true,
                  rpfilter = N.rpfilter(st.get("net.rpfilter")), hosts = {}, dns = {}, neigh = {} }
    for _, name in ipairs(st.getNames()) do
        local iface = scan.startsWith(name, "net.if.") and name:sub(#"net.if." + 1)
        if iface and iface ~= "" and st.get(name) and st.get(name) ~= "" then cfg.ifaces[iface] = st.get(name) end
    end
    -- a list item's "dev <iface>" at the end: words from the first'th on,
    -- exactly "dev" and a name, else nil
    local function devAt(w, first)
        if #w == first + 1 and w[first] == "dev" then return w[first + 1] end
        return nil
    end
    -- route: net "via" gw ["dev" iface]
    for _, item in ipairs(scan.split(tostring(st.get("net.routes") or ""), ",")) do
        local w = scan.words(item)
        if #w >= 3 and w[2] == "via" then
            cfg.routes[#cfg.routes + 1] = { net = w[1], gw = w[3], iface = devAt(w, 4) }
        end
    end
    -- host: name "=" address (the name without blanks or "=")
    for _, item in ipairs(scan.split(tostring(st.get("net.hosts") or ""), ",")) do
        local name, ip = scan.cut(item, "=")
        if ip then
            name, ip = scan.trim(name), scan.trim(ip)
            if name ~= "" and #scan.words(name) == 1 and ip ~= "" and #scan.words(ip) == 1 then cfg.hosts[name] = ip end
        end
    end
    -- dns: addresses between commas or blanks
    for _, item in ipairs(scan.split(tostring(st.get("net.dns") or ""), ",")) do
        for _, ip in ipairs(scan.words(item)) do cfg.dns[#cfg.dns + 1] = ip end
    end
    -- neighbour: address "lladdr" mac ["dev" iface]
    for _, item in ipairs(scan.split(tostring(st.get("net.neigh") or ""), ",")) do
        local w = scan.words(item)
        if #w >= 3 and w[2] == "lladdr" then
            cfg.neigh[#cfg.neigh + 1] = { ip = w[1], mac = w[3], iface = devAt(w, 4) }
        end
    end
    return cfg
end

-- The stack's notes to the system log under init (`help syslog`): kern,
-- as "net", notice unless said.  Without init they're only kept in S.log.
function N.syslog(msg, sev)
    local proc = rawget(_G, "proc")
    if proc and proc.log then proc.log({ fac = 0, sev = sev or 5, app = "net", msg = msg }) end
end

-- A stack set up as cfg says, on this computer's modems.
function N.fromConfig(cfg)
    local S = N.new({
        id = os.getComputerID(), forward = cfg.forward, rpfilter = cfg.rpfilter,
        transmit = function(ifc, frame) peripheral.call(ifc.modem, "transmit", ifc.channel, ifc.channel, frame) end,
        log = N.syslog,
    })
    local problems = {}
    for iface, cidr in pairs(cfg.ifaces) do
        local modem, channel = N.link(iface)
        if not modem then
            problems[#problems + 1] = iface .. ": bad VLAN (1-4094)"
        elseif peripheral.getType(modem) ~= "modem" then
            problems[#problems + 1] = iface .. ": no modem called " .. modem
        else
            peripheral.call(modem, "open", channel)
            local ok, err = S.addInterface(iface, cidr)
            if not ok then problems[#problems + 1] = iface .. ": " .. err end
        end
    end
    for _, r in ipairs(cfg.routes) do
        local ok, err = S.addRoute(r.net, r.gw, r.iface)
        if not ok then problems[#problems + 1] = r.net .. " via " .. r.gw .. ": " .. err end
    end
    for _, e in ipairs(cfg.neigh or {}) do
        local ok, err = S.addNeighbour(e.ip, e.mac, e.iface)
        if not ok then problems[#problems + 1] = "neighbour " .. e.ip .. ": " .. err end
    end
    return S, problems
end

-- Bring the network up as the settings say (again, if it's up already:
-- the old stack is unhooked first).  Returns the stack and a list of
-- problems with the configuration.
function N.up()
    N.down()
    local S, problems = N.fromConfig(N.config())
    N.hook(S, os)
    _G.ccnet = S
    return S, problems
end

-- Take it down.
function N.down()
    local S = _G.ccnet
    if not S then return false end
    S.dead = true
    if S.unhook then S.unhook() end
    for _, ifc in pairs(S.ifaces) do pcall(peripheral.call, ifc.modem, "close", ifc.channel) end
    _G.ccnet = nil
    return true
end

--------------------------------------------------------------------------
-- For programs
--------------------------------------------------------------------------
-- The running stack, or nil and why.
function N.stack()
    if _G.ccnet then return _G.ccnet end
    return nil, "the network isn't up: run `ip up`"
end

-- The address (a number) "a.b.c.d" is, or a name's: lib/netdb's lookup
-- (net.hosts, then DNS).  nil and why if there's none.
function N.resolve(name)
    if N.parseIP(name) then return N.parseIP(name) end
    local ok, netdb = pcall(require, "netdb")
    if not ok or type(netdb) ~= "table" then return nil, "unknown host " .. tostring(name) end
    local h, why = netdb.gethostbyname(tostring(name))
    if not h then return nil, tostring(name) .. ": " .. why end
    return N.parseIP(h.addr_list[1])
end

-- Wait up to `timeout` seconds (nil: for ever) for an event `name` that
-- `want(...)` accepts; its values, or nil on timeout.
function N.await(name, want, timeout)
    local timer = timeout and os.startTimer(timeout)
    while true do
        local ev = table.pack(os.pullEvent())
        if ev[1] == name and (not want or want(table.unpack(ev, 2, ev.n))) then
            if timer then os.cancelTimer(timer) end
            return table.unpack(ev, 2, ev.n)
        elseif ev[1] == "timer" and ev[2] == timer then
            return nil
        end
    end
end

-- The ICMP answer to echo request id/seq (S.echo), waiting up to timeout
-- seconds: the net_icmp event's values (a reply: "reply", from, id, seq,
-- ttl, the data it brought back; an error: its kind, from, code, the packet it's about), or nil.
function N.awaitEcho(id, seq, timeout)
    return N.await("net_icmp", function(k, _, x, y)
        if k == "reply" then return x == id and y == seq end
        return type(y) == "table" and y.id == id and y.seq == seq
    end, timeout)
end

-- take() until it gives something (or timeout seconds pass: nil), waiting
-- between tries for an event `name` about `v` (one can be about something
-- already taken: try again).
local function poll(take, name, v, timeout)
    local deadline = timeout and os.clock() + timeout
    while true do
        local got = take()
        if got then return got end
        local left = deadline and deadline - os.clock()
        if left and left <= 0 then return nil end
        N.await(name, function(x) return x == v end, left)
    end
end

-- A UDP socket on `port` (nil: any free one).
local Socket = {}
Socket.__index = Socket
function N.udp(port)
    local S, why = N.stack()
    if not S then return nil, why end
    local p, err = S.udpOpen(port)
    if not p then return nil, err end
    return setmetatable({ port = p, S = S }, Socket)
end
function Socket:send(host, port, data)
    local dst, why = N.resolve(host)
    if not dst then return false, why end
    return self.S.udpSend(self.port, dst, port, data)
end
-- The next datagram's data, sender's address and port; nil on timeout.
function Socket:receive(timeout)
    local d = poll(function() return self.S.udpTake(self.port) end, "net_udp", self.port, timeout)
    if not d then return nil end
    return d.data, d.src, d.sport
end
function Socket:close() self.S.udpClose(self.port) end

-- TCP.  A connection: conn:send(bytes), conn:read(timeout) (what's come
-- in; nil and why at the end), conn:close() (our half), conn:abort().
local Conn = {}
Conn.__index = Conn

local function waitConn(conn, done, timeout)
    return poll(done, "net_tcp", conn.c.id, timeout) or false
end

-- Connect to host:port; the connection, or nil and why.  Waits up to
-- timeout seconds (default: until TCP gives up).
function N.connect(host, port, timeout)
    local S, why = N.stack()
    if not S then return nil, why end
    local dst, why2 = N.resolve(host)
    if not dst then return nil, why2 end
    local c, err = S.tcpConnect(dst, port)
    if not c then return nil, err end
    local conn = setmetatable({ S = S, c = c }, Conn)
    if not waitConn(conn, function() return c.state ~= "SYN_SENT" end, timeout) then
        S.tcpAbort(c)
        return nil, "connection timed out"
    end
    if c.state == "CLOSED" then return nil, c.err or "connection closed" end
    return conn
end

-- Send bytes; false and why if the connection is gone.
function Conn:send(s) return self.S.tcpSend(self.c, tostring(s)) end

-- What has come in, waiting up to timeout seconds (nil: as long as it
-- takes) for something: a string, or nil and "timeout", or nil and
-- "closed" (they closed: nothing more will come) or why it broke.
function Conn:read(timeout)
    local S, c = self.S, self.c
    local s, ended
    waitConn(self, function()
        s, ended = S.tcpRead(c)
        return #s > 0 or ended
    end, timeout)
    if #s > 0 then return s end
    if ended then return nil, c.err or "closed" end
    return nil, "timeout"
end

function Conn:close() self.S.tcpClose(self.c) end
function Conn:abort() self.S.tcpAbort(self.c) end
-- "ESTABLISHED", "CLOSE_WAIT"... as TCP names them; and why it closed.
function Conn:state() return self.c.state, self.c.err end
-- Bytes sent and not yet acknowledged (or not yet sent).
function Conn:pending() return #self.c.out end
function Conn:remote() return N.ipString(self.c.rip), self.c.rport end
-- The event (net_tcp) and value that say something happened on it.
function Conn:id() return self.c.id end

-- Listen on a TCP port: listener:accept(timeout) -> a connection.
local Listener = {}
Listener.__index = Listener
function N.listen(port)
    local S, why = N.stack()
    if not S then return nil, why end
    local ok, err = S.tcpListen(port)
    if not ok then return nil, err end
    return setmetatable({ S = S, port = port }, Listener)
end
-- The next connection made (nil after timeout seconds).
function Listener:accept(timeout)
    local c = poll(function() return self.S.tcpAccept(self.port) end, "net_accept", self.port, timeout)
    return c and setmetatable({ S = self.S, c = c }, Conn)
end
-- A connection if one is waiting, without waiting.
function Listener:poll()
    local c = self.S.tcpAccept(self.port)
    return c and setmetatable({ S = self.S, c = c }, Conn)
end
function Listener:close() self.S.tcpUnlisten(self.port) end

return N
