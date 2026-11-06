-- sim/net_dns.lua
--
-- lib/netdb (getaddrinfo and friends, the DNS client), ip dns, host, and
-- ping, traceroute and nc by name, against stacks on mock wires that
-- answer at once:
--
--     this computer 10.0.1.2 --- [left] R 10.0.1.1 | 10.0.2.1 [right] --- B 10.0.2.5
--                                                                       |- NS 10.0.2.53 (answers)
--                                                                       |- SF 10.0.2.54 (SERVFAIL)
--                                                                       '- MUTE 10.0.2.55 (never answers)
--
-- B has nothing on port 53, so it answers a question with ICMP "port
-- unreachable".  NS answers with replies 1.1.1.1 really gave (a CNAME
-- chain with compressed names, a PTR, an NXDOMAIN with its SOA), its own
-- for lab names, and NXDOMAIN for the rest.  Timers fire only when
-- nothing else is left to happen: a server that never answers times out.
local PROJ = ...
package.path = PROJ .. "/lib/?.lua;" .. PROJ .. "/sim/lib/?.lua;" .. package.path
local M = require("mock")
local SW = require("shellworld")
local N = require("net")
local D = require("netdb")
local check = M.check

local W = SW.new(PROJ)
local function show(s) return (tostring(s):gsub("\n", "|")) end
local function hex(s) return (s:gsub("%x%x", function(h) return string.char(tonumber(h, 16)) end)) end

local STORE = {}
settings = {
    get = function(k) return STORE[k] end, set = function(k, v) STORE[k] = v end,
    unset = function(k) STORE[k] = nil end, save = function() end,
    getNames = function() local t = {} for k in pairs(STORE) do t[#t + 1] = k end table.sort(t) return t end,
}
peripheral = { getNames = function() return {} end, getType = function() end, call = function() end }
os.getComputerID = os.getComputerID or function() return 1 end
textutils = textutils or M.textutilsApi()

-- timers: pending until nothing else can happen (see onPull)
local timers, lastTimer = {}, 0
W.os.startTimer = function() lastTimer = lastTimer + 1; timers[lastTimer] = true; return lastTimer end
W.os.cancelTimer = function(id) timers[id] = nil end

--------------------------------------------------------------------------
-- The wire format, against what 1.1.1.1 sent
--------------------------------------------------------------------------
local Q_GITHUB = "123401000001000000000000037777770667697468756203636f6d0000010001"
local R_GITHUB = "123481800001000200000000037777770667697468756203636f6d0000010001c00c0005000100000b380002c010c010000100010000000f00048c527403"
local R_PTR = "234581800001000100000000013101310131013107696e2d61646472046172706100000c0001c00c000c0001000002c20011036f6e65036f6e65036f6e65036f6e6500"
local R_NX = "345681830001000000010000076e6f776865726507696e76616c69640000010001000006000100015180004001610c726f6f742d73657276657273036e657400056e73746c640c766572697369676e2d67727303636f6d0078c3e0d9000007080000038400093a8000015180"

check("dnsQuery: byte for byte the question a real resolver library sends", D.dnsQuery(0x1234, "www.github.com", "A") == hex(Q_GITHUB))
check("dnsQuery: a trailing dot is the same name; an empty label or a 64-byte one isn't a name",
    D.dnsQuery(1, "a.b.", "A") == D.dnsQuery(1, "a.b", "A") and D.dnsQuery(1, "a..b", "A") == nil
        and D.dnsQuery(1, string.rep("x", 64) .. ".com", "A") == nil)
local m = D.dnsParse(hex(R_GITHUB))
check("dnsParse: a CNAME and its A, the names compressed",
    m and m.id == 0x1234 and m.qr and m.rcode == 0 and #m.answers == 2
        and m.answers[1].type == "CNAME" and m.answers[1].name == "www.github.com" and m.answers[1].data == "github.com"
        and m.answers[1].ttl == 2872 and m.answers[2].type == "A" and m.answers[2].data == "140.82.116.3")
m = D.dnsParse(hex(R_PTR))
check("dnsParse: a PTR record", m and m.answers[1].type == "PTR" and m.answers[1].data == "one.one.one.one"
    and m.questions[1].name == "1.1.1.1.in-addr.arpa" and m.questions[1].type == "PTR")
m = D.dnsParse(hex(R_NX))
check("dnsParse: NXDOMAIN (no answers; the SOA in authority isn't read)", m and m.rcode == 3 and #m.answers == 0)
local short = hex(R_GITHUB):sub(1, -3)
local loop = hex("000081800001000000000000c00c00010001")
check("dnsParse: cut short, or a name pointing at itself: not a message", D.dnsParse(short) == nil and D.dnsParse(loop) == nil
    and D.dnsParse("hello") == nil and D.dnsParse(nil) == nil)

check("getservbyname / getservbyport: from the table, by protocol",
    D.getservbyname("telnet").port == 23 and D.getservbyname("www", "tcp").port == 80
        and D.getservbyname("telnet", "udp") == nil and D.getservbyport(53, "udp").name == "domain"
        and D.getservbyport(9999) == nil)
check("gai_strerror and hstrerror: glibc's words", D.gai_strerror(D.EAI_NONAME) == "Name or service not known"
    and D.hstrerror(D.HOST_NOT_FOUND) == "Unknown host")

--------------------------------------------------------------------------
-- The network
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
            for _, x in ipairs(segments[wires[id .. ":" .. ifc.modem]] or {}) do
                if not (x[1] == S and x[2] == ifc.modem) then x[1].receive(x[2], ifc.channel, copy(frame)) end
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
local ME = computer(1, false, function(...) W.os.queueEvent(...) end)
local R, B = computer(10, true), computer(2)
local NS, SF, MUTE = computer(3), computer(4), computer(5)
plug(ME, "back", "10.0.1.2/24", "lan1")
plug(R, "left", "10.0.1.1/24", "lan1")
plug(R, "right", "10.0.2.1/24", "lan2")
plug(B, "back", "10.0.2.5/24", "lan2")
plug(NS, "back", "10.0.2.53/24", "lan2")
plug(SF, "back", "10.0.2.54/24", "lan2")
plug(MUTE, "back", "10.0.2.55/24", "lan2")
assert(ME.addRoute("default", "10.0.1.1"))
for _, S in ipairs({ B, NS, SF, MUTE }) do assert(S.addRoute("default", "10.0.2.1")) end
assert(NS.udpOpen(53)); assert(SF.udpOpen(53)); assert(MUTE.udpOpen(53))
assert(B.udpOpen(7))

-- NS's answers: question name -> reply (the id is put in)
local function rr(name, rtype, data)
    local rdata = rtype == 1 and string.char(data:match("(%d+)%.(%d+)%.(%d+)%.(%d+)")) or D.dnsQuery(0, data, 1):sub(13, -5)
    local nm = D.dnsQuery(0, name, 1):sub(13, -5)
    return nm .. string.char(0, rtype, 0, 1, 0, 0, 0, 60, math.floor(#rdata / 256), #rdata % 256) .. rdata
end
local function reply(q, rcode, answers)
    local qs = q:sub(13)
    return q:sub(1, 2) .. string.char(0x81, 0x80 + rcode, 0, 1, 0, #answers, 0, 0, 0, 0) .. qs .. table.concat(answers)
end
local ZONE = {            -- name -> { type -> the reply to a question }
    ["lab.example"] = { A = function(q) return reply(q, 0, { rr("lab.example", 1, "10.0.2.5") }) end },
    ["5.2.0.10.in-addr.arpa"] = { PTR = function(q) return reply(q, 0, { rr("5.2.0.10.in-addr.arpa", 12, "lab.example") }) end },
    ["two.example"] = { A = function(q) return reply(q, 0, { rr("two.example", 1, "10.0.2.5"), rr("two.example", 1, "10.0.2.6") }) end },
    ["www.github.com"] = { A = function(q) return q:sub(1, 2) .. hex(R_GITHUB):sub(3) end },
    ["1.1.1.1.in-addr.arpa"] = { PTR = function(q) return q:sub(1, 2) .. hex(R_PTR):sub(3) end },
}
local asked = { NS = 0, SF = 0, MUTE = 0 }
local function serve()
    while true do
        local d = NS.udpTake(53)
        if not d then break end
        asked.NS = asked.NS + 1
        local q = D.dnsParse(d.data).questions[1]
        local z = ZONE[q.name]
        local answer = z and (z[q.type] or function(x) return reply(x, 0, {}) end)     -- (no such record)
        if q.name == "nowhere.invalid" then answer = function(x) return x:sub(1, 2) .. hex(R_NX):sub(3) end end
        answer = answer or function(x) return reply(x, 3, {}) end                       -- (no such name)
        NS.udpSend(53, d.src, d.sport, answer(d.data))
    end
    while true do
        local d = SF.udpTake(53)
        if not d then break end
        asked.SF = asked.SF + 1
        SF.udpSend(53, d.src, d.sport, reply(d.data, 2, {}))
    end
    while MUTE.udpTake(53) do asked.MUTE = asked.MUTE + 1 end
end
-- before each event a program waits for: the servers answer; if nothing
-- is left to happen, the earliest timer fires (time passes to it)
local function onPull(w)
    serve()
    if #w.T.events == 0 then
        local first
        for id in pairs(timers) do if not first or id < first then first = id end end
        if first then
            timers[first] = nil
            W:advance(2)
            w.T.events[1] = { "timer", first }
        end
    end
end
local function call(fn) return W:call(fn, { onPull = onPull, events = {} }) end
local function run(...)
    local args = { ... }
    local opts = type(args[#args]) == "table" and table.remove(args) or {}
    opts.onPull, opts.events = onPull, {}
    args[#args + 1] = opts
    return W:run(table.unpack(args))
end

--------------------------------------------------------------------------
-- No DNS servers: the host database alone
--------------------------------------------------------------------------
_G.ccnet = ME
STORE["net.hosts"] = "b=10.0.2.5, router=10.0.1.1"
local r = call(function(env)
    local nd = env.require("netdb")
    local ai = nd.getaddrinfo("b", "telnet")
    local lo = nd.getaddrinfo("localhost", 7, { socktype = nd.SOCK_DGRAM })
    local _, why, code = nd.getaddrinfo("lab.example", nil)
    local host, serv = nd.getnameinfo("10.0.2.5", 23)
    local num = nd.getnameinfo("10.9.9.9", nil)
    local _, _, code2 = nd.getnameinfo("10.9.9.9", nil, nd.NI_NAMEREQD)
    return { ai = ai, lo = lo, why = why, code = code, host = host, serv = serv, num = num, code2 = code2 }
end)
local v = r.value
check("getaddrinfo from net.hosts: one stream address (telnet is tcp only), the port from the services table",
    v and #v.ai == 1 and v.ai[1].addr == "10.0.2.5" and v.ai[1].port == 23 and v.ai[1].socktype == "stream"
        and v.ai[1].protocol == "tcp", show(r.errText))
check("localhost is 127.0.0.1", v and v.lo[1].addr == "127.0.0.1" and v.lo[1].port == 7 and v.lo[1].protocol == "udp")
check("a name the hosts don't have, and no DNS servers: EAI_NONAME, nothing sent",
    v and v.code == D.EAI_NONAME and v.why == "Name or service not known" and asked.NS == 0, v and v.why)
check("getnameinfo from net.hosts: the name and the service's",
    v and v.host == "b" and v.serv == "telnet" and v.num == "10.9.9.9" and v.code2 == D.EAI_NONAME)

r = run("ping", "-c", "1", "b")
check("ping a name from net.hosts", r.status == 0 and r.out:find("PING b %(10%.0%.2%.5%)"), show(r.out) .. show(r.errText))
r = run("ping", "lab.example")
check("ping a name nobody knows: the reason, status 2", r.status == 2
    and r.errText:find("ping: lab.example: Name or service not known"), show(r.errText))
r = run("host", "lab.example")
check("host with no DNS servers: says so, status 2", r.status == 2 and r.errText:find("no DNS servers"), show(r.errText))

--------------------------------------------------------------------------
-- ip dns
--------------------------------------------------------------------------
r = run("ip", "dns", "10.0.2.53")
check("ip dns <primary>: kept in net.dns", STORE["net.dns"] == "10.0.2.53" and r.out:find("primary%s+10%.0%.2%.53"),
    show(r.out))
r = run("ip", "dns", "10.0.2.53", "10.0.2.54", "10.0.2.55")
check("ip dns with three: a usage error, net.dns as it was", r.status == 2 and STORE["net.dns"] == "10.0.2.53")
r = run("ip", "dns", "nameserver")
check("ip dns with a name: a usage error", r.status == 2 and r.errText:find("bad address"))
r = run("ip", "dns", "off")
check("ip dns off: none, and it says what that means", STORE["net.dns"] == nil and r.out:find("hosts' alone"), show(r.out))
r = run("ip", "dns", "10.0.2.53", "10.0.2.54")
check("ip dns <primary> <secondary>: both, in order",
    STORE["net.dns"] == "10.0.2.53, 10.0.2.54" and r.out:find("primary%s+10%.0%.2%.53") and r.out:find("secondary%s+10%.0%.2%.54"))

--------------------------------------------------------------------------
-- DNS
--------------------------------------------------------------------------
STORE["net.dns"] = "10.0.2.53"
r = call(function(env)
    local nd = env.require("netdb")
    return { nd.getaddrinfo("www.github.com", "https", { flags = nd.AI_CANONNAME }) }
end)
v = r.value and r.value[1]
check("getaddrinfo over DNS: the CNAME followed, the canonical name, https's port, tcp only",
    v and #v == 1 and v[1].addr == "140.82.116.3" and v[1].port == 443 and v[1].canonname == "github.com" and asked.NS == 1,
    show(r.errText) .. tostring(r.value and r.value[2]))
r = call(function(env) return env.require("netdb").getaddrinfo("WWW.GitHub.com.", nil, { socktype = "stream" }) end)
check("asked again (another case, a trailing dot): from the cache, nothing sent",
    r.value and r.value[1].addr == "140.82.116.3" and asked.NS == 1)
r = call(function(env)
    local nd = env.require("netdb")
    local two = nd.getaddrinfo("two.example", nil, { socktype = nd.SOCK_DGRAM })
    local h = nd.gethostbyname("www.github.com")
    local _, why, code = nd.getaddrinfo("nowhere.invalid", "http")
    local _, _, hcode = nd.gethostbyname("nowhere.invalid")
    local name, serv = nd.getnameinfo("1.1.1.1", 53, nd.NI_DGRAM)
    local short = nd.getnameinfo("10.0.2.5", nil, nd.NI_NOFQDN)
    local h2 = nd.gethostbyaddr("1.1.1.1")
    return { two = two, h = h, why = why, code = code, hcode = hcode, name = name, serv = serv, short = short, h2 = h2 }
end)
v = r.value
check("two A records: two addrinfos, in order", v and #v.two == 2 and v.two[1].addr == "10.0.2.5" and v.two[2].addr == "10.0.2.6",
    show(r.errText))
check("gethostbyname: the canonical name, the alias, the address list",
    v and v.h.name == "github.com" and v.h.aliases[1] == "www.github.com" and v.h.addr_list[1] == "140.82.116.3"
        and v.h.addrtype == "inet" and v.h.length == 4)
check("NXDOMAIN: EAI_NONAME (HOST_NOT_FOUND)", v and v.code == D.EAI_NONAME and v.hcode == D.HOST_NOT_FOUND, v and v.why)
check("getnameinfo over DNS: the PTR record's name, udp's service", v and v.name == "one.one.one.one" and v.serv == "domain")
check("getnameinfo NI_NOFQDN, and the hosts first: b", v and v.short == "b")
check("gethostbyaddr", v and v.h2.name == "one.one.one.one" and v.h2.addr_list[1] == "1.1.1.1")

--------------------------------------------------------------------------
-- A broken primary: the secondary
--------------------------------------------------------------------------
local function lookup(name)
    return call(function(env) return { env.require("netdb").getaddrinfo(name, nil, { socktype = "raw" }) } end)
end
STORE["net.dns"] = "10.0.2.5, 10.0.2.53"               -- B: nothing on 53
local before, c0 = asked.NS, W.clock
r = lookup("lab.example")
check("primary answers ICMP port unreachable: the secondary is asked, at once (no timer)",
    r.value and r.value[1] and r.value[1][1].addr == "10.0.2.5" and asked.NS == before + 1 and W.clock == c0,
    show(r.errText) .. tostring(r.value and r.value[2]))
check("and the primary is marked broken for a while", ME.dnsDown["10.0.2.5"] ~= nil)
ME.dnsCache = nil
before = asked.NS
local bRx = B.ifaces.back.rx
r = lookup("lab.example")
check("next time the secondary goes first: the broken primary isn't asked",
    r.value and r.value[1] and asked.NS == before + 1 and B.ifaces.back.rx == bRx, B.ifaces.back.rx - bRx)

STORE["net.dns"] = "10.0.2.54, 10.0.2.53"               -- SF: SERVFAIL
r = lookup("two.example")
check("primary answers SERVFAIL: the secondary's answer", r.value and r.value[1] and #r.value[1] == 2 and asked.SF == 1)

STORE["net.dns"] = "10.0.2.55, 10.0.2.53"               -- MUTE: never answers
ME.dnsCache = nil
local clock0 = W.clock
r = lookup("lab.example")
check("primary never answers: after its timeout, the secondary's answer",
    r.value and r.value[1] and r.value[1][1].addr == "10.0.2.5" and asked.MUTE == 1 and W.clock == clock0 + 2,
    show(r.errText))

STORE["net.dns"] = "10.0.2.54"                          -- the only one, broken
ME.dnsDown, ME.dnsCache = nil, nil
r = lookup("lab.example")
check("every server broken: EAI_AGAIN after two rounds, and what each said",
    r.value and r.value[1] == nil and r.value[3] == D.EAI_AGAIN and asked.SF == 3
        and tostring(r.value[2]):find("10%.0%.2%.54: SERVFAIL"), r.value and tostring(r.value[2]))
STORE["net.dns"] = "10.0.2.53, 10.0.2.54"
ME.dnsDown, ME.dnsCache = nil, nil
local sf = asked.SF
r = lookup("nowhere.invalid")
check("the primary's NXDOMAIN is the answer: the secondary isn't asked",
    r.value and r.value[3] == D.EAI_NONAME and asked.SF == sf)
r = call(function(env) return { env.require("netdb").getaddrinfo("lab.example", nil, { flags = env.require("netdb").AI_NUMERICHOST }) } end)
check("AI_NUMERICHOST: a name isn't looked up", r.value and r.value[3] == D.EAI_NONAME)

--------------------------------------------------------------------------
-- The programs
--------------------------------------------------------------------------
STORE["net.dns"] = "10.0.2.53"
ME.dnsDown, ME.dnsCache = nil, nil
r = run("ping", "-c", "2", "lab.example")
check("ping a name DNS has", r.status == 0 and r.out:find("PING lab%.example %(10%.0%.2%.5%)")
    and r.out:find("2 sent, 2 received"), show(r.out) .. show(r.errText))
STORE["net.hosts"] = "router=10.0.1.1"
r = run("traceroute", "-q", "1", "lab.example")
local lines = {}
for l in r.out:gmatch("[^\n]+") do lines[#lines + 1] = l end
check("traceroute: hops by name (net.hosts, then a PTR record)", r.status == 0 and #lines == 3
    and lines[1]:find("traceroute to lab%.example %(10%.0%.2%.5%)") and lines[2]:find("^ 1%s+router %(10%.0%.1%.1%)")
    and lines[3]:find("^ 2%s+lab%.example %(10%.0%.2%.5%)"), show(r.out))
r = run("traceroute", "-n", "-q", "1", "lab.example")
check("traceroute -n: addresses alone", r.status == 0 and r.out:find(" 1%s+10%.0%.1%.1  ") and not r.out:find("router"),
    show(r.out))
r = run("host", "www.github.com")
check("host: the alias, then the address", r.status == 0
    and r.out == "www.github.com is an alias for github.com.\ngithub.com has address 140.82.116.3\n", show(r.out))
r = run("host", "1.1.1.1")
check("host <address>: its PTR record",
    r.status == 0 and r.out == "1.1.1.1.in-addr.arpa domain name pointer one.one.one.one.\n", show(r.out))
r = run("host", "nowhere.invalid")
check("host: NXDOMAIN, status 1", r.status == 1 and r.out == "Host nowhere.invalid not found: 3(NXDOMAIN)\n", show(r.out))
r = run("host", "-t", "PTR", "lab.example")
check("host -t PTR on a name with no PTR record: says so, status 1",
    r.status == 1 and r.out == "lab.example has no PTR record\n", show(r.out))
r = run("host", "lab.example", "10.0.2.54")
check("host name server: that server alone (SERVFAIL: trouble, status 2)", r.status == 2 and r.errText:find("SERVFAIL"),
    show(r.errText))
-- nc's UDP mode reads and prints at once: parallel as CraftOS has it, over the world's os
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
r = run("nc", "-u", "lab.example", "echo", { stdin = "hi\n" })
W.yieldEvents = false
parallel = parallelWas
local got = B.udpTake(7)
check("nc -u name service: the datagram goes to its address and port", got and got.data == "hi" and r.status == 0,
    show(r.errText))
r = run("nc", "-u", "-n", "lab.example", "7", { stdin = "hi\n" })
check("nc -n: no lookups, so a name is an error (status 2)", r.status == 2 and r.errText:find("Name or service not known"),
    show(r.errText))
r = run("nc", "-u", "10.0.2.5", "nosuchservice", { stdin = "hi\n" })
check("nc with a service nobody's heard of: the reason, status 2",
    r.status == 2 and r.errText:find("Servname not supported"), show(r.errText))
r = call(function(env) local n = env.require("net"); return { n.resolve("lab.example"), n.connect("nowhere.invalid", 80) } end)
check("net.resolve (and so connect, and a socket's send) go through netdb",
    r.value and r.value[1] == N.parseIP("10.0.2.5") and r.value[2] == nil
        and r.value[3] == "nowhere.invalid: Unknown host", show(r.errText) .. tostring(r.value and r.value[3]))

--------------------------------------------------------------------------
-- The cache: ip dns flush, host -v (asked, then from the cache), ip dns
-- cache (answers, "no such name", a server that failed)
--------------------------------------------------------------------------
STORE["net.dns"] = "10.0.2.53"
r = run("ip", "dns", "flush")
local r2 = run("ip", "dns", "cache")
check("ip dns flush: how many answers it forgot; then ip dns cache: empty",
    r.status == 0 and r.out:find("^forgot %d+ answers?, and which servers had failed\n$")
        and r2.status == 0 and r2.out == "the cache is empty\n", show(r.out) .. show(r2.out))
local nsWas = asked.NS
r = run("host", "-v", "lab.example")
check("host -v: the question, the answer as a zone file has it (TTL 60), who answered and how long it took",
    r.status == 0 and r.out:find('^Trying "lab%.example"\n;; QUESTION SECTION:\n;lab%.example%.  IN  A\n')
        and r.out:find(";; ANSWER SECTION:\nlab%.example%.%s+60%s+IN%s+A%s+10%.0%.2%.5\n")
        and r.out:find("\nReceived from 10%.0%.2%.53#53 in %d+ ms\n$") and asked.NS == nsWas + 1, show(r.out))
W:advance(10)
r = run("host", "-v", "lab.example")
check("host -v again, 10 s on: from the cache (nothing asked), the TTL 10 less, who answered and when",
    r.status == 0 and r.out:find("lab%.example%.%s+50%s+IN%s+A%s+10%.0%.2%.5\n")
        and r.out:find("\n;; from the cache: 10%.0%.2%.53#53 answered 10 s ago\n$") and asked.NS == nsWas + 1, show(r.out))
r = run("host", "-v", "nowhere.invalid")
check("host -v, no such name: NXDOMAIN, status 1, and who said so",
    r.status == 1 and r.out:find(";; status: NXDOMAIN\nHost nowhere%.invalid not found: 3%(NXDOMAIN%)\n")
        and r.out:find("Received from 10%.0%.2%.53#53"), show(r.out))
STORE["net.dns"] = "10.0.2.5, 10.0.2.53"                -- B: nothing on 53, so it fails
lookup("two.example")
r = run("ip", "dns", "cache")
local cacheLines = {}
for l in r.out:gmatch("[^\n]+") do cacheLines[#cacheLines + 1] = l end
check("ip dns cache: each answer kept, by name: its type, seconds left, what it said, who said it; then the failed server",
    r.status == 0 and #cacheLines == 4
        and cacheLines[1]:find("^lab%.example%s+A%s+50 s  A 10%.0%.2%.5  %(from 10%.0%.2%.53%)$")
        and cacheLines[2]:find("^nowhere%.invalid%s+A%s+30 s  no such name %(NXDOMAIN%)  %(from 10%.0%.2%.53%)$")
        and cacheLines[3]:find("^two%.example%s+A%s+60 s  A 10%.0%.2%.5, A 10%.0%.2%.6  %(from 10%.0%.2%.53%)$")
        and cacheLines[4] == "server 10.0.2.5 failed: asked last for 60 s more", show(r.out))
W:advance(31)
r = run("ip", "dns", "cache")
check("... 31 s on: the no-such-name answer gone, the others kept", not r.out:find("nowhere", 1, true)
    and r.out:find("lab%.example%s+A%s+19 s"), show(r.out))
r = run("ip", "dns", "f")
check("ip dns f[lush]: the two still kept forgotten, and the failed server",
    r.out == "forgot 2 answers, and which servers had failed\n" and next(ME.dnsDown) == nil, show(r.out))
STORE["net.dns"] = "10.0.2.53"
nsWas = asked.NS
r = run("host", "-v", "lab.example")
check("and the next lookup asks again", r.out:find("Received from 10%.0%.2%.53#53") and asked.NS == nsWas + 1, show(r.out))

_G.ccnet = nil
r = run("ip", "dns", "cache")
check("ip dns cache with the network down: says so, status 1", r.status == 1 and r.errText:find("isn't up"), show(r.errText))
