-- netdb.lua -- names for addresses: getaddrinfo(3), getnameinfo(3) and
-- friends, as C's netdb.h has them, over a small DNS client
--
--   local netdb = require("netdb")
--   local ai, why = netdb.getaddrinfo("example.com", "http", { socktype = netdb.SOCK_STREAM })
--   if not ai then error(why) end
--   local conn = net.connect(ai[1].addr, ai[1].port)
--   local host, serv = netdb.getnameinfo("10.0.2.5", 23)     -- "b", "telnet"
--
-- A name is looked up as a C library's "hosts: files dns" does it:
--  * files: the host database, the setting net.hosts (`ip host b
--    10.0.2.5`), and localhost (127.0.0.1);
--  * dns: then the DNS servers in the setting net.dns, "primary,
--    secondary" (`ip dns 1.1.1.1 9.9.9.9`; the secondary can be left out).
--    With none set, the host database is all there is.
-- A question goes to the primary first.  If it's broken (no answer in
-- TIMEOUT seconds, an ICMP error or no route to it, an answer that's
-- SERVFAIL, REFUSED or garbled) the secondary is asked, and for DOWN_FOR
-- seconds after that the secondary goes first.  ROUNDS of that, then
-- EAI_AGAIN.  A server's "no such name" (NXDOMAIN) or "no address" is
-- the answer: nobody else is asked.  Answers are kept in the running
-- stack for their TTL (at most CACHE_MAX seconds; "no such name" for
-- NEGATIVE_TTL), so a name looked up again costs nothing.
--
-- The DNS is RFC 1035's least: A, CNAME and PTR records, asked over UDP
-- port 53 with recursion desired, so a real resolver does the rest (the
-- ccnix mod's gateway, mod/, reaches public ones).  No TCP, EDNS, DNSSEC,
-- search domains or AAAA (the stack is IPv4).
--
-- The C calls, as Lua has them.  Errors are nil, why (gai_strerror's or
-- hstrerror's text, with what went wrong if there's more to say) and the
-- C code:
--   getaddrinfo(node, service, hints) -> { addrinfo... }
--       node: a name, "a.b.c.d" or nil (AI_PASSIVE: 0.0.0.0, else
--       127.0.0.1); service: a port, a name from the services table
--       (getservbyname), or nil; hints: { family = AF_INET, socktype =
--       SOCK_STREAM | SOCK_DGRAM | SOCK_RAW, protocol = "tcp" | "udp" |
--       "icmp", flags = AI_PASSIVE + AI_CANONNAME + AI_NUMERICHOST +
--       AI_NUMERICSERV }.  An addrinfo is { family, socktype, protocol,
--       addr ("a.b.c.d"), port, canonname (the first one's, with
--       AI_CANONNAME) }, one for each address and socket type (no
--       socktype: stream and dgram).  Errors EAI_NONAME, EAI_AGAIN,
--       EAI_FAIL, EAI_SERVICE, EAI_FAMILY, EAI_SOCKTYPE, EAI_BADFLAGS,
--       EAI_SYSTEM (the network isn't up).
--   getnameinfo(addr, port, flags) -> host, serv
--       addr's name (net.hosts, then DNS's PTR record), or "a.b.c.d" if it
--       has none (NI_NAMEREQD: EAI_NONAME instead); port's service name
--       (tcp's; NI_DGRAM: udp's), or the number.  NI_NUMERICHOST and
--       NI_NUMERICSERV: no lookup.  NI_NOFQDN: the name's first label.
--   gethostbyname(name), gethostbyaddr(addr) -> hostent { name, aliases,
--       addrtype = AF_INET, length = 4, addr_list }.  Errors
--       HOST_NOT_FOUND, TRY_AGAIN, NO_RECOVERY, NO_DATA.
--   getservbyname(name, proto), getservbyport(port, proto) -> servent
--       { name, aliases, port, proto }, from SERVICES below (proto nil:
--       either)
--   gai_strerror(code), hstrerror(code) -> the text
-- and resolv.h's res_query, for DNS alone:
--   res_query(name, type, servers) -> { { name, type, ttl, data }... }
--       type "A" (the default), "CNAME" or "PTR"; data an address or a
--       name.  servers: a list of addresses to ask instead of net.dns.
--       Every answer comes back (the CNAMEs on the way too), and where
--       from: { server (the one that answered), cached (true: from the
--       cache), age (seconds since it answered) }.  Errors: nil, why, and
--       "NXDOMAIN" (and where from, as above), "again" (no server
--       answered), "noservers" or "system" (the network isn't up).
--   cache() -> { entries, down }, flush() -> how many were kept: the
--       answers kept in the running stack, and the servers asked last
--       for now (see below).
--
-- The wire format is netdb.dnsQuery(id, name, type) -> bytes and
-- netdb.dnsParse(bytes) -> { id, qr, tc, rcode, questions, answers }, for
-- tests and tools.

local net = require("net")
local D = {}

local TIMEOUT, ROUNDS = 2, 2    -- seconds a server has to answer; times round them all
local DOWN_FOR = 60             -- seconds a broken server is asked last
local CACHE_MAX, NEGATIVE_TTL, CACHE_SIZE = 300, 30, 64

D.AF_INET = "inet"
D.SOCK_STREAM, D.SOCK_DGRAM, D.SOCK_RAW = "stream", "dgram", "raw"
D.AI_PASSIVE, D.AI_CANONNAME, D.AI_NUMERICHOST, D.AI_NUMERICSERV = 1, 2, 4, 1024
D.NI_NUMERICHOST, D.NI_NUMERICSERV, D.NI_NOFQDN, D.NI_NAMEREQD, D.NI_DGRAM = 1, 2, 4, 8, 16
D.EAI_BADFLAGS, D.EAI_NONAME, D.EAI_AGAIN, D.EAI_FAIL = -1, -2, -3, -4
D.EAI_FAMILY, D.EAI_SOCKTYPE, D.EAI_SERVICE, D.EAI_SYSTEM = -6, -7, -8, -11
D.HOST_NOT_FOUND, D.TRY_AGAIN, D.NO_RECOVERY, D.NO_DATA = 1, 2, 3, 4

-- (glibc's words)
local GAI_TEXT = {
    [D.EAI_BADFLAGS] = "Bad value for ai_flags", [D.EAI_NONAME] = "Name or service not known",
    [D.EAI_AGAIN] = "Temporary failure in name resolution", [D.EAI_FAIL] = "Non-recoverable failure in name resolution",
    [D.EAI_FAMILY] = "ai_family not supported", [D.EAI_SOCKTYPE] = "ai_socktype not supported",
    [D.EAI_SERVICE] = "Servname not supported for ai_socktype", [D.EAI_SYSTEM] = "System error",
}
local H_TEXT = { "Unknown host", "Host name lookup failure", "Unknown server error", "No address associated with name" }
function D.gai_strerror(code) return GAI_TEXT[code] or ("Unknown error " .. tostring(code)) end
function D.hstrerror(code) return H_TEXT[code] or "Resolver internal error" end

local PROTO = { stream = "tcp", dgram = "udp", raw = "icmp" }

local function has(flags, f) return math.floor((flags or 0) / f) % 2 == 1 end
local function lower(name) return (tostring(name):lower():gsub("%.$", "")) end

--------------------------------------------------------------------------
-- Services: a few of /etc/services
--------------------------------------------------------------------------
local SERVICES = {          -- name, port, protocols, aliases
    { "echo", 7, "tcp udp" }, { "discard", 9, "tcp udp", { "sink", "null" } }, { "daytime", 13, "tcp udp" },
    { "ftp", 21, "tcp" }, { "ssh", 22, "tcp" }, { "telnet", 23, "tcp" }, { "smtp", 25, "tcp", { "mail" } },
    { "domain", 53, "tcp udp" }, { "http", 80, "tcp", { "www" } }, { "pop3", 110, "tcp" }, { "ntp", 123, "udp" },
    { "imap", 143, "tcp", { "imap2" } }, { "snmp", 161, "udp" }, { "https", 443, "tcp" },
}

local function servent(s, proto)
    for p in s[3]:gmatch("%S+") do
        if proto == nil or p == proto then return { name = s[1], aliases = s[4] or {}, port = s[2], proto = p } end
    end
end

function D.getservbyname(name, proto)
    for _, s in ipairs(SERVICES) do
        local named = s[1] == name
        for _, a in ipairs(s[4] or {}) do named = named or a == name end
        if named then
            local e = servent(s, proto)
            if e then return e end
        end
    end
end

function D.getservbyport(port, proto)
    for _, s in ipairs(SERVICES) do
        if s[2] == tonumber(port) then
            local e = servent(s, proto)
            if e then return e end
        end
    end
end

--------------------------------------------------------------------------
-- The wire format (RFC 1035 4.1)
--------------------------------------------------------------------------
local TYPES = { A = 1, CNAME = 5, PTR = 12 }
local TYPE_NAMES = { [1] = "A", [5] = "CNAME", [12] = "PTR" }
local RCODES = { [0] = "NOERROR", "FORMERR", "SERVFAIL", "NXDOMAIN", "NOTIMP", "REFUSED" }

local function u16(n) return string.char(math.floor(n / 256) % 256, n % 256) end

-- A name as labels, or nil if it can't be one.
local function encodeName(name)
    name = tostring(name):gsub("%.$", "")
    if #name == 0 or #name > 253 then return nil end
    local out = {}
    for label in (name .. "."):gmatch("([^.]*)%.") do
        if #label == 0 or #label > 63 then return nil end
        out[#out + 1] = string.char(#label) .. label
    end
    return table.concat(out) .. "\0"
end

-- A question with recursion desired, or nil for a name that can't be one.
function D.dnsQuery(id, name, qtype)
    local qname = encodeName(name)
    if not qname then return nil end
    return u16(id) .. u16(0x0100) .. u16(1) .. u16(0) .. u16(0) .. u16(0) .. qname .. u16(TYPES[qtype] or qtype) .. u16(1)
end

-- The name at pos (pointers followed), and where what follows it starts.
local function readName(s, pos)
    local labels, after, jumps = {}, nil, 0
    while true do
        local len = s:byte(pos)
        if not len then return nil end
        if len >= 192 then
            local low = s:byte(pos + 1)
            if not low or jumps >= 32 then return nil end
            after = after or pos + 2
            pos, jumps = (len - 192) * 256 + low + 1, jumps + 1
        elseif len >= 64 then
            return nil
        elseif len == 0 then
            return table.concat(labels, "."), after or pos + 1
        else
            local label = s:sub(pos + 1, pos + len)
            if #label < len then return nil end
            labels[#labels + 1] = label
            pos = pos + 1 + len
        end
    end
end

-- A message: { id, qr, tc, rcode, questions = { { name, type } },
-- answers = { { name, type, ttl, data } } } (type a name for A, CNAME and
-- PTR, else its number; data only for those), or nil if it isn't one.
function D.dnsParse(s)
    if type(s) ~= "string" or #s < 12 then return nil end
    local function r16(p)
        local a, b = s:byte(p, p + 1)
        return b and a * 256 + b
    end
    local flags = r16(3)
    local m = { id = r16(1), qr = flags >= 32768, tc = math.floor(flags / 512) % 2 == 1, rcode = flags % 16,
                questions = {}, answers = {} }
    local pos = 13
    for _ = 1, r16(5) do
        local name
        name, pos = readName(s, pos)
        if not name or not r16(pos + 2) then return nil end
        m.questions[#m.questions + 1] = { name = name, type = TYPE_NAMES[r16(pos)] or r16(pos) }
        pos = pos + 4
    end
    for _ = 1, r16(7) do
        local name
        name, pos = readName(s, pos)
        local len = name and r16(pos + 8)
        if not len or pos + 9 + len > #s then return nil end
        local t, at = r16(pos), pos + 10
        local rr = { name = name, type = TYPE_NAMES[t] or t, ttl = r16(pos + 4) * 65536 + r16(pos + 6) }
        if t == 1 and len == 4 then
            rr.data = string.format("%d.%d.%d.%d", s:byte(at, at + 3))
        elseif t == 5 or t == 12 then
            rr.data = readName(s, at)
            if not rr.data then return nil end
        end
        m.answers[#m.answers + 1] = rr
        pos = at + len
    end
    return m
end

--------------------------------------------------------------------------
-- Asking
--------------------------------------------------------------------------
-- One question to one server: its reply, or nil and why.
local function ask(S, server, name, qtype)
    local dst = net.parseIP(server)
    if not dst then return nil, "not an address" end
    local port, err = S.udpOpen()
    if not port then return nil, err end
    local id = math.random(0, 65535)
    local sent, why = S.udpSend(port, dst, 53, D.dnsQuery(id, name, qtype))
    local reply
    if sent then
        local timer = os.startTimer(TIMEOUT)
        local ok, e = pcall(function()
            while true do
                local d = S.udpTake(port)
                if d then
                    local m = net.parseIP(d.src) == dst and d.sport == 53 and D.dnsParse(d.data)
                    local q = m and m.questions[1]
                    if q and m.qr and m.id == id and lower(q.name) == name and q.type == qtype then
                        reply = m
                        return
                    end
                else
                    -- (an ICMP error: its kind, from, code, the packet it's about)
                    local ev, a, _, c, orig = os.pullEvent()
                    if ev == "timer" and a == timer then
                        why = "no answer"
                        return
                    elseif ev == "net_icmp" and a ~= "reply" and type(orig) == "table" and orig.proto == "udp"
                        and orig.sport == port and orig.dport == 53 then
                        why = a ~= "unreachable" and "time exceeded"
                            or c == "prohibited" and "administratively prohibited" or (tostring(c) .. " unreachable")
                        return
                    end
                end
            end
        end)
        os.cancelTimer(timer)
        if not ok then S.udpClose(port); error(e, 0) end      -- (Ctrl+T)
    end
    S.udpClose(port)
    if reply then return reply end
    return nil, why
end

-- DNS's reply to name/qtype (rcode NOERROR or NXDOMAIN), from the cache
-- or the servers (net.dns unless given), and where it came from: { server
-- (the one that answered), cached (true: from the cache), age (seconds
-- since it answered) }.  Or nil, why and a kind: "noservers", "again",
-- "system".
local function query(name, qtype, servers)
    servers = servers or net.config().dns
    if #servers == 0 then return nil, "no DNS servers are set (ip dns)", "noservers" end
    local S, why = net.stack()
    if not S then return nil, why, "system" end
    local now = os.clock()
    S.dnsCache, S.dnsDown = S.dnsCache or { n = 0 }, S.dnsDown or {}
    local key = table.concat(servers, ",") .. " " .. qtype .. " " .. name
    local hit = S.dnsCache[key]
    if hit and hit.expires > now then return hit.m, { server = hit.server, cached = true, age = now - hit.at } end
    local order = {}
    for _, broken in ipairs({ false, true }) do
        for _, s in ipairs(servers) do
            if ((S.dnsDown[s] or 0) > now) == broken then order[#order + 1] = s end
        end
    end
    local problems = {}
    for _ = 1, ROUNDS do
        for _, server in ipairs(order) do
            local m, err = ask(S, server, name, qtype)
            if m and (m.rcode == 0 or m.rcode == 3) and not (m.tc and #m.answers == 0) then
                S.dnsDown[server] = nil
                local ttl = (m.rcode == 3 or #m.answers == 0) and NEGATIVE_TTL or CACHE_MAX
                for _, rr in ipairs(m.answers) do ttl = math.min(ttl, rr.ttl) end
                if S.dnsCache.n >= CACHE_SIZE then S.dnsCache = { n = 0 } end
                local at = os.clock()
                S.dnsCache[key] = { m = m, expires = at + ttl, at = at, server = server, name = name, qtype = qtype,
                                    servers = servers }
                S.dnsCache.n = S.dnsCache.n + 1
                return m, { server = server, cached = false, age = 0 }
            end
            S.dnsDown[server] = os.clock() + DOWN_FOR
            problems[server] = err or (m.tc and "truncated") or RCODES[m.rcode] or ("rcode " .. m.rcode)
        end
    end
    local said = {}
    for _, s in ipairs(order) do said[#said + 1] = s .. ": " .. problems[s] end
    return nil, table.concat(said, ", "), "again"
end

-- The records of qtype for name in a reply, CNAMEs followed: their data,
-- the name they're for, and the names on the way.
local function follow(m, name, qtype)
    local at, aliases = name, {}
    for _ = 1, 8 do
        local nextName
        for _, rr in ipairs(m.answers) do
            if rr.type == "CNAME" and lower(rr.name) == at then nextName = lower(rr.data) end
        end
        if not nextName then break end
        aliases[#aliases + 1] = at
        at = nextName
    end
    local data = {}
    for _, rr in ipairs(m.answers) do
        if rr.type == qtype and lower(rr.name) == at then data[#data + 1] = rr.data end
    end
    return data, at, aliases
end

-- The host database, net.hosts with localhost: name -> "a.b.c.d".
local function hostsDb()
    local h = net.config().hosts
    h.localhost = h.localhost or "127.0.0.1"
    return h
end

-- How a DNS failure reads as h_errno.
local H_OF = { again = D.TRY_AGAIN, system = D.TRY_AGAIN, noservers = D.HOST_NOT_FOUND }

-- A name's addresses: { name, aliases, addrs }, or nil, why and an h_errno.
local function lookup(name)
    local key = lower(name)
    local hosts = hostsDb()
    if hosts[name] then return { name = name, aliases = {}, addrs = { hosts[name] } } end
    for n, ip in pairs(hosts) do
        if lower(n) == key then return { name = n, aliases = {}, addrs = { ip } } end
    end
    if not encodeName(key) then return nil, "not a name", D.HOST_NOT_FOUND end
    local m, why, kind = query(key, "A")
    if not m then return nil, why, H_OF[kind] end
    if m.rcode == 3 then return nil, "NXDOMAIN", D.HOST_NOT_FOUND end
    local addrs, at, aliases = follow(m, key, "A")
    if #addrs == 0 then return nil, "no A record", D.NO_DATA end
    return { name = at, aliases = aliases, addrs = addrs }
end

-- An address's name, or nil, why and an h_errno.
local function reverse(ip)
    local hosts = hostsDb()
    local names = {}
    for n, a in pairs(hosts) do if net.parseIP(a) == net.parseIP(ip) then names[#names + 1] = n end end
    table.sort(names)
    if names[1] then return names[1] end
    local a, b, c, d = ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    local qname = d .. "." .. c .. "." .. b .. "." .. a .. ".in-addr.arpa"
    local m, why, kind = query(qname, "PTR")
    if not m then return nil, why, H_OF[kind] end
    if m.rcode == 3 then return nil, "NXDOMAIN", D.HOST_NOT_FOUND end
    local found = follow(m, qname, "PTR")
    if not found[1] then return nil, "no PTR record", D.NO_DATA end
    return (found[1]:gsub("%.$", ""))
end

--------------------------------------------------------------------------
-- netdb.h
--------------------------------------------------------------------------
local function gaiFail(code, detail)
    return nil, D.gai_strerror(code) .. (detail and (" (" .. detail .. ")") or ""), code
end
local EAI_OF = { [D.HOST_NOT_FOUND] = D.EAI_NONAME, [D.NO_DATA] = D.EAI_NONAME, [D.TRY_AGAIN] = D.EAI_AGAIN,
                 [D.NO_RECOVERY] = D.EAI_FAIL }

function D.getaddrinfo(node, service, hints)
    hints = hints or {}
    local flags = hints.flags or 0
    if type(flags) ~= "number" then return gaiFail(D.EAI_BADFLAGS) end
    if hints.family ~= nil and hints.family ~= D.AF_INET then return gaiFail(D.EAI_FAMILY) end
    if node == nil and service == nil then return gaiFail(D.EAI_NONAME) end
    local types = {}
    for _, t in ipairs(hints.socktype and { hints.socktype } or { D.SOCK_STREAM, D.SOCK_DGRAM }) do
        if not PROTO[t] then return gaiFail(D.EAI_SOCKTYPE) end
        if hints.protocol == nil or hints.protocol == PROTO[t] then types[#types + 1] = t end
    end
    if #types == 0 then return gaiFail(D.EAI_SOCKTYPE) end

    local ports = {}            -- by socket type
    if service ~= nil then
        local n = tonumber(service)
        local kept = {}
        for _, t in ipairs(types) do
            local port = n
            if t == D.SOCK_RAW then return gaiFail(D.EAI_SERVICE) end
            if not n then
                if has(flags, D.AI_NUMERICSERV) then return gaiFail(D.EAI_NONAME) end
                local s = D.getservbyname(tostring(service), PROTO[t])
                port = s and s.port
            end
            if port then
                if port ~= math.floor(port) or port < 0 or port > 65535 then return gaiFail(D.EAI_SERVICE) end
                kept[#kept + 1], ports[t] = t, port
            end
        end
        if #kept == 0 then return gaiFail(D.EAI_SERVICE) end
        types = kept
    end

    local addrs, canon
    if node == nil then
        addrs = { has(flags, D.AI_PASSIVE) and "0.0.0.0" or "127.0.0.1" }
    elseif net.parseIP(node) then
        addrs = { net.ipString(net.parseIP(node)) }
        canon = addrs[1]
    elseif has(flags, D.AI_NUMERICHOST) then
        return gaiFail(D.EAI_NONAME)
    else
        local h, why, code = lookup(node)
        if not h then
            if code == D.TRY_AGAIN and not net.stack() then return gaiFail(D.EAI_SYSTEM, why) end
            return gaiFail(EAI_OF[code] or D.EAI_FAIL, code ~= D.HOST_NOT_FOUND and why or nil)
        end
        addrs, canon = h.addrs, h.name
    end
    local res = {}
    for _, a in ipairs(addrs) do
        for _, t in ipairs(types) do
            res[#res + 1] = { family = D.AF_INET, socktype = t, protocol = PROTO[t], addr = a, port = ports[t] }
        end
    end
    if has(flags, D.AI_CANONNAME) then res[1].canonname = canon or tostring(node) end
    return res
end

function D.getnameinfo(addr, port, flags)
    flags = flags or 0
    local ip = net.parseIP(addr)
    if not ip then return gaiFail(D.EAI_NONAME, "not an address: " .. tostring(addr)) end
    local host = net.ipString(ip)
    if not has(flags, D.NI_NUMERICHOST) then
        local name, why, code = reverse(host)
        if name then
            host = has(flags, D.NI_NOFQDN) and name:match("^[^.]+") or name
        elseif has(flags, D.NI_NAMEREQD) then
            return gaiFail(code == D.TRY_AGAIN and D.EAI_AGAIN or D.EAI_NONAME, code == D.TRY_AGAIN and why or nil)
        end
    end
    local serv
    if port ~= nil then
        serv = tostring(port)
        local s = not has(flags, D.NI_NUMERICSERV) and D.getservbyport(port, has(flags, D.NI_DGRAM) and "udp" or "tcp")
        if s then serv = s.name end
    end
    return host, serv
end

local function hostent(name, aliases, addrs)
    return { name = name, aliases = aliases, addrtype = D.AF_INET, length = 4, addr_list = addrs }
end
local function hFail(code, detail)
    return nil, D.hstrerror(code) .. (detail and (" (" .. detail .. ")") or ""), code
end

function D.gethostbyname(name)
    local ip = net.parseIP(name)
    if ip then return hostent(tostring(name), {}, { net.ipString(ip) }) end
    local h, why, code = lookup(tostring(name))
    if not h then return hFail(code, code ~= D.HOST_NOT_FOUND and why or nil) end
    return hostent(h.name, h.aliases, h.addrs)
end

function D.gethostbyaddr(addr)
    local ip = net.parseIP(addr)
    if not ip then return hFail(D.HOST_NOT_FOUND, "not an address") end
    local name, why, code = reverse(net.ipString(ip))
    if not name then return hFail(code, code ~= D.HOST_NOT_FOUND and why or nil) end
    return hostent(name, {}, { net.ipString(ip) })
end

--------------------------------------------------------------------------
-- resolv.h
--------------------------------------------------------------------------
function D.res_query(name, qtype, servers)
    qtype = tostring(qtype or "A"):upper()
    if not TYPES[qtype] then return nil, "can't ask for " .. qtype .. " records (A, CNAME, PTR)" end
    local key = lower(name)
    if not encodeName(key) then return nil, "not a name: " .. tostring(name) end
    local m, info, kind = query(key, qtype, servers)
    if not m then return nil, info, kind end            -- (info: why it failed)
    if m.rcode == 3 then return nil, "no such name", "NXDOMAIN", info end
    return m.answers, info
end

--------------------------------------------------------------------------
-- The cache (ip dns cache, ip dns flush)
--------------------------------------------------------------------------
-- What the running stack has kept: { entries, down }.  An entry is
-- { name, type, rcode, answers, server (the one that answered), servers
-- (the list asked), left (seconds it's kept for yet) }, by name then type;
-- down is { server, left }: a server that failed, asked last for left
-- seconds more.  nil and why if the network isn't up.
function D.cache()
    local S, why = net.stack()
    if not S then return nil, why end
    local now = os.clock()
    local entries, down = {}, {}
    for key, e in pairs(S.dnsCache or {}) do
        if key ~= "n" and e.expires > now then
            entries[#entries + 1] = { name = e.name, type = e.qtype, rcode = e.m.rcode, answers = e.m.answers,
                                      server = e.server, servers = e.servers, left = e.expires - now }
        end
    end
    table.sort(entries, function(a, b)
        if a.name ~= b.name then return tostring(a.name) < tostring(b.name) end
        return tostring(a.type) < tostring(b.type)
    end)
    for server, untilT in pairs(S.dnsDown or {}) do
        if untilT > now then down[#down + 1] = { server = server, left = untilT - now } end
    end
    table.sort(down, function(a, b) return a.server < b.server end)
    return { entries = entries, down = down }
end

-- Forget every answer kept, "no such name" too, and which servers failed.
-- How many answers were still kept; nil and why if the network isn't up.
function D.flush()
    local S, why = net.stack()
    if not S then return nil, why end
    local n, now = 0, os.clock()
    for key, e in pairs(S.dnsCache or {}) do
        if key ~= "n" and e.expires > now then n = n + 1 end
    end
    S.dnsCache, S.dnsDown = { n = 0 }, {}
    return n
end

return D
