-- tcpdump.lua -- watch the frames on the network (lib/net.lua)
--
--   tcpdump [-DenpqSvx] [-t|-tt|-ttt|-tttt] [-c count] [-i iface]...
--           [-r file] [-w file] [expression]
--
-- Prints a line for each frame on the interfaces, in and out, until
-- Ctrl+T (or -c count frames), then how many it caught.  A modem hears
-- every frame on its channel, so frames between other computers on the
-- same wire show up too (-p: only this computer's own and broadcasts).
--
--   -i iface   listen on iface ("back", "back.20"; again for more; "any":
--              all).  None: every interface the network has up, or (it
--              isn't up) every modem's untagged channel.  An interface the
--              network doesn't have is listened to on its own channel, so
--              tcpdump works with the network down too
--   -D         list the interfaces it can listen on
--   -c count   stop after count frames
--   -e         show the link layer: MACs, the frame's type, the VLAN
--   -n         addresses as numbers (else `ip host`'s names for them)
--   -p         only frames to or from this computer, and broadcasts
--   -q         less about each protocol
--   -S         TCP sequence numbers as they are (else from each side's
--              first, as tcpdump counts them)
--   -t         no time; -tt seconds since 1970; -ttt the time since the
--              frame before; -tttt the date too
--   -v         the IP header too (TTL, ID, protocol)
--   -x         and the frame's data as a Lua table
--   -w file    write the frames to file instead of printing them (a Lua
--              table a line, not pcap); -r file prints them again
--
-- The expression picks which frames, as tcpdump's does (a part of it):
--   host <addr|name>, src <addr>, dst <addr>    (IP, or ARP's addresses)
--   net <net/len>, src net ..., dst net ...
--   port <n>, src port <n>, dst port <n>        (TCP and UDP)
--   arp, ip, icmp, udp, tcp
--   ether host <mac>, ether src|dst <mac>, ether broadcast
--   vlan [<n>]                                  (a VLAN interface's frames)
-- joined with and (&&), or (||), not (!) and parentheses; two side by side
-- mean and: `tcpdump -n icmp or udp port 53`, `tcpdump tcp and not port 23`.
-- Exit status 0, 1 for trouble (a bad expression, an interface that isn't
-- there).

package.path = (ccnix and ccnix.lib or "/" .. fs.getDir(fs.getDir(shell.getRunningProgram())) .. "/lib/?.lua;") .. package.path  -- ccnix's lib/, or the one beside bin/
local USAGE = "tcpdump [-DenpqSvx] [-t...] [-c count] [-i iface]... [-r file] [-w file] [expression]"
local cu = require("cu").init("tcpdump", USAGE)
local net = require("net")

local opts, operands, order = cu.getopt({ ... }, "Dc:ei:npqr:Stvw:x", 1)
local tflag, verbose, ifaceArgs = 0, 0, {}
for _, o in ipairs(order) do
    if o[1] == "t" then tflag = tflag + 1
    elseif o[1] == "v" then verbose = verbose + 1
    elseif o[1] == "i" then ifaceArgs[#ifaceArgs + 1] = o[2] end
end
local count = opts.c and cu.int(opts.c)
if opts.c and not (count and count > 0) then cu.usageError("bad count " .. opts.c, 1) end

local S = net.stack()
local hosts = net.config().hosts
local names = {}                    -- address -> name, from `ip host`
for name, ip in pairs(hosts) do names[ip] = names[ip] or name end

--------------------------------------------------------------------------
-- -D: what it can listen on
--------------------------------------------------------------------------
if opts.D then
    local n, used = 0, {}
    if S then
        local list = {}
        for name in pairs(S.ifaces) do list[#list + 1] = name end
        table.sort(list)
        for _, name in ipairs(list) do
            local i = S.ifaces[name]
            n = n + 1
            used[i.modem] = true
            io.write(string.format("%d.%s (%s)\n", n, name, net.cidrString(i.ip, i.len)))
        end
    end
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "modem" and not used[name] then
            n = n + 1
            io.write(string.format("%d.%s (not up: its untagged channel)\n", n, name))
        end
    end
    io.write(string.format("%d.any (all of them)\n", n + 1))
    return cu.exit()
end

--------------------------------------------------------------------------
-- The expression
--------------------------------------------------------------------------
local function ipOf(f) return f.type == "ip" and type(f.data) == "table" and f.data or nil end
local function arpOf(f) return f.type == "arp" and type(f.data) == "table" and f.data or nil end
local function portsOf(f)
    local p = ipOf(f)
    if p and (p.proto == "udp" or p.proto == "tcp") and type(p.data) == "table" then return p.data end
end

-- The frame's addresses on the side asked: "src", "dst" or either (nil).
local function addrs(f, side)
    local p, a = ipOf(f), arpOf(f)
    if p then return side ~= "dst" and p.src, side ~= "src" and p.dst end
    if a then return side ~= "dst" and a.spa, side ~= "src" and a.tpa end
end

local function compile(words)
    local toks = {}
    local text = table.concat(words, " "):gsub("&&", " and "):gsub("||", " or "):gsub("([()!])", " %1 ")
    for t in text:gmatch("%S+") do toks[#toks + 1] = t end
    local pos = 1
    local function peek() return toks[pos] end
    local function take(what)
        local t = toks[pos]
        if t == nil then error((what or "more") .. " expected at the end", 0) end
        pos = pos + 1
        return t
    end
    local function address(s)
        local ip = net.parseIP(s) or (hosts[s] and net.parseIP(hosts[s]))
        if not ip then error("unknown host " .. s, 0) end
        return ip
    end
    local function number(s)
        local n = cu.int(s)
        if not n then error("not a number: " .. s, 0) end
        return n
    end
    local PROTOS = { arp = true, ip = true, icmp = true, udp = true, tcp = true }

    local expr
    local function primitive()
        local t = take("a primitive")
        if PROTOS[t] then
            if t == "arp" or t == "ip" then return function(r) return r.frame.type == t end end
            return function(r) local p = ipOf(r.frame) return p ~= nil and p.proto == t end
        elseif t == "ether" then
            local q = take("host, src, dst or broadcast")
            if q == "broadcast" then return function(r) return r.frame.dst == net.BROADCAST end end
            local m = take("a MAC")
            local mac = net.parseMAC(m)
            if not mac then error("not a MAC: " .. m .. " (02:cc:00:00:0c:05)", 0) end
            if q == "host" then return function(r) return r.frame.src == mac or r.frame.dst == mac end
            elseif q == "src" then return function(r) return r.frame.src == mac end
            elseif q == "dst" then return function(r) return r.frame.dst == mac end end
            error("ether " .. q .. "? (host, src, dst or broadcast)", 0)
        elseif t == "broadcast" then
            return function(r) return r.frame.dst == net.BROADCAST end
        elseif t == "vlan" then
            local n = peek() and cu.int(peek())
            if n then pos = pos + 1 end
            return function(r) local _, _, v = net.link(r.iface) return v ~= nil and (n == nil or v == n) end
        end
        local side
        if t == "src" or t == "dst" then side, t = t, peek() end
        if side and (t == "host" or t == "net" or t == "port") then pos = pos + 1
        elseif side then t = "host"                     -- (src 10.0.1.2: a host)
        elseif t ~= "host" and t ~= "net" and t ~= "port" then
            if net.parseIP(t) or hosts[t] then pos = pos - 1; t = "host"   -- (a bare address: a host)
            else error("unknown word " .. t, 0) end
        end
        if t == "host" then
            local ip = address(take("an address"))
            return function(r) local a, b = addrs(r.frame, side) return a == ip or b == ip end
        elseif t == "net" then
            local spec = take("a network")
            local ip, len = net.parseCIDR(spec)
            if not ip then error("bad network " .. spec, 0) end
            local size = 2 ^ (32 - len)
            local base = math.floor(ip / size) * size
            local function inside(a) return type(a) == "number" and math.floor(a / size) * size == base end
            return function(r) local a, b = addrs(r.frame, side) return inside(a) or inside(b) end
        else
            local n = number(take("a port"))
            return function(r)
                local d = portsOf(r.frame)
                return d ~= nil and ((side ~= "dst" and d.sport == n) or (side ~= "src" and d.dport == n))
            end
        end
    end
    local function factor()
        local t = peek()
        if t == "not" or t == "!" then
            pos = pos + 1
            local f = factor()
            return function(r) return not f(r) end
        elseif t == "(" then
            pos = pos + 1
            local e = expr()
            if take(")") ~= ")" then error(") expected", 0) end
            return e
        end
        return primitive()
    end
    local function term()
        local f = factor()
        while peek() and peek() ~= "or" and peek() ~= ")" do
            if peek() == "and" then pos = pos + 1 end
            local a, b = f, factor()
            f = function(r) return a(r) and b(r) end
        end
        return f
    end
    expr = function()
        local f = term()
        while peek() == "or" do
            pos = pos + 1
            local a, b = f, term()
            f = function(r) return a(r) or b(r) end
        end
        return f
    end
    if #toks == 0 then return function() return true end end
    local f = expr()
    if pos <= #toks then error("unexpected " .. toks[pos], 0) end
    return f
end

local ok, filter = pcall(compile, operands)
if not ok then cu.usageError("expression: " .. filter, 1) end

--------------------------------------------------------------------------
-- Printing a frame
--------------------------------------------------------------------------
local function addr(ip)
    local s = net.ipString(ip)
    return not opts.n and names[s] or s
end
local function hostPort(ip, port) return addr(ip) .. "." .. tostring(port) end

local MOD32 = 4294967296
local bases = {}                    -- a TCP flow ("src.port>dst.port") -> the first seq seen
local function rel(key, n)
    if opts.S or type(n) ~= "number" then return n end
    local b = bases[key]
    if not b then return n end
    return (n - b) % MOD32
end

local function icmpText(d)
    local o = type(d.orig) == "table" and d.orig or {}
    if d.type == "echo" then return string.format("echo request, id %s, seq %s", tostring(d.id), tostring(d.seq))
    elseif d.type == "reply" then return string.format("echo reply, id %s, seq %s", tostring(d.id), tostring(d.seq))
    elseif d.type == "timeexceeded" then return "time exceeded in-transit"
    elseif d.type == "unreachable" then
        local dst = o.dst and addr(o.dst) or "?"
        if d.code == "port" then return string.format("%s %s port %s unreachable", dst, tostring(o.proto), tostring(o.dport))
        elseif d.code == "prohibited" then return "host " .. dst .. " unreachable - admin prohibited"
        else return tostring(d.code) .. " " .. dst .. " unreachable" end
    end
    return "type " .. tostring(d.type)
end

local function tcpText(p, d)
    local len = type(d.data) == "string" and #d.data or 0
    if opts.q then return "tcp " .. len end
    local key, back = p.src .. "." .. tostring(d.sport) .. ">" .. p.dst .. "." .. tostring(d.dport),
                      p.dst .. "." .. tostring(d.dport) .. ">" .. p.src .. "." .. tostring(d.sport)
    local first = bases[key] == nil and type(d.seq) == "number"
    local flags = (d.syn and "S" or "") .. (d.fin and "F" or "") .. (d.rst and "R" or "") .. (d.ack ~= nil and "." or "")
    local out = { "Flags [" .. (flags == "" and "none" or flags) .. "]" }
    if d.syn or d.fin or d.rst or len > 0 then
        local s = first and d.seq or rel(key, d.seq)
        out[#out + 1] = len > 0 and string.format("seq %s:%s", tostring(s), tostring(type(s) == "number" and (s + len) % MOD32 or "?"))
            or ("seq " .. tostring(s))
    end
    if d.ack ~= nil then out[#out + 1] = "ack " .. tostring(rel(back, d.ack)) end
    if d.wnd ~= nil then out[#out + 1] = "win " .. tostring(d.wnd) end
    out[#out + 1] = "length " .. len
    if first then bases[key] = d.seq end
    return table.concat(out, ", ")
end

local function describe(f)
    if type(f) ~= "table" or f.ccnet ~= 1 then
        return "not a ccnet frame: " .. (type(f) == "string" and (#f .. " bytes") or type(f))
    end
    local a, p = arpOf(f), ipOf(f)
    if a then
        if a.op == "request" then return "ARP, Request who-has " .. addr(a.tpa) .. " tell " .. addr(a.spa) end
        if a.op == "reply" then return "ARP, Reply " .. addr(a.spa) .. " is-at " .. tostring(a.sha) end
        return "ARP, " .. tostring(a.op)
    elseif p then
        if type(p.src) ~= "number" or type(p.dst) ~= "number" then return "IP, malformed" end
        local head = "IP "
        if verbose > 0 then
            head = string.format("IP (ttl %s, id %s, proto %s) ", tostring(p.ttl), tostring(p.id), tostring(p.proto))
        end
        local d = type(p.data) == "table" and p.data or {}
        if p.proto == "icmp" then
            return head .. addr(p.src) .. " > " .. addr(p.dst) .. ": ICMP " .. icmpText(d)
        elseif p.proto == "udp" or p.proto == "tcp" then
            local ends = hostPort(p.src, d.sport) .. " > " .. hostPort(p.dst, d.dport) .. ": "
            if p.proto == "tcp" then return head .. ends .. tcpText(p, d) end
            local body = type(d.data) == "string" and ("length " .. #d.data) or (type(d.data) .. " data")
            return head .. ends .. "UDP, " .. body
        end
        return head .. addr(p.src) .. " > " .. addr(p.dst) .. ": " .. tostring(p.proto)
    end
    return "type " .. tostring(f.type)
end

local function clock(ms)
    ms = math.floor(ms)
    local d = ms % 86400000
    return string.format("%02d:%02d:%02d.%03d", math.floor(d / 3600000), math.floor(d / 60000) % 60,
        math.floor(d / 1000) % 60, d % 1000)
end
local last
local function stamp(ms)
    if tflag == 1 then return "" end
    local s
    if tflag == 2 then s = string.format("%d.%03d", math.floor(ms / 1000), math.floor(ms) % 1000)
    elseif tflag == 3 then s = clock(last and ms - last or 0)
    elseif tflag >= 4 then s = os.date("!%Y-%m-%d ", math.floor(ms / 1000)) .. clock(ms)
    else s = clock(ms) end
    last = ms
    return s .. " "
end

--------------------------------------------------------------------------
-- Listening
--------------------------------------------------------------------------
local function now() return os.epoch and os.epoch("local") or math.floor(os.clock() * 1000) end
local function copy(v, depth)
    if type(v) ~= "table" or (depth or 0) > 16 then return v end
    local t = {}
    for k, x in pairs(v) do t[k] = copy(x, (depth or 0) + 1) end
    return t
end

local function serialise(v) return (textutils.serialise(v, { compact = true }):gsub("\\\n", "\\n")) end

local seen, captured = 0, 0
local out, showIface
if opts.w then
    local path = shell and shell.resolve(opts.w) or opts.w
    out = io.open(path, "w")
    if not out then cu.fail("can't write " .. opts.w); return cu.exit() end
    out:write("-- ccnet frames (tcpdump -w): a Lua table a line\n")
end

-- One frame: { t = ms, dir = "in" | "out", iface, frame }.
local function handle(rec)
    seen = seen + 1
    local f = rec.frame
    if opts.p and rec.dir == "in" and type(f) == "table" then
        local mine = (S and S.ifaces[rec.iface] and S.ifaces[rec.iface].mac) or net.mac(os.getComputerID(), (net.link(rec.iface)))
        if f.dst ~= mine and f.dst ~= net.BROADCAST then return end
    end
    local okF, keep = pcall(filter, rec)
    if not (okF and keep) then return end
    captured = captured + 1
    if out then out:write(serialise(rec), "\n"); return end
    local line = stamp(rec.t)
    if showIface then line = line .. rec.iface .. (rec.dir == "out" and " Out " or " In ") end
    if opts.e and type(f) == "table" and f.ccnet == 1 then
        local _, _, vlan = net.link(rec.iface)
        line = line .. string.format("%s > %s, %s%s: ", tostring(f.src), tostring(f.dst), tostring(f.type),
            vlan and (", vlan " .. vlan) or "")
    end
    io.write(line, describe(f), "\n")
    if opts.x and type(f) == "table" then io.write("  ", serialise(f.data), "\n") end
end

local function done() return count and captured >= count end

if opts.r then
    local h = io.open(shell and shell.resolve(opts.r) or opts.r, "r")
    if not h then cu.fail("can't read " .. opts.r); return cu.exit() end
    showIface = true
    for line in h:lines() do
        if done() then break end
        if line:sub(1, 2) ~= "--" and line:find("%S") then
            local rec = textutils.unserialise(line)
            if type(rec) == "table" and rec.iface and rec.t then handle(rec) end
        end
    end
    h:close()
    return cu.exit()
end

-- where to listen: the stack's interfaces (its tap) and modem channels of our own
local tapped, raw, opened, listening, chosen = {}, {}, {}, {}, {}
local function listen(name)
    if chosen[name] then return true end
    if S and S.ifaces[name] then
        tapped[name] = true
    else
        local modem, channel = net.link(name)
        if not modem then return false, "bad VLAN in " .. name .. " (1-4094)" end
        if peripheral.getType(modem) ~= "modem" then return false, "no interface " .. name .. " (tcpdump -D lists them)" end
        if not peripheral.call(modem, "isOpen", channel) then
            peripheral.call(modem, "open", channel)
            opened[#opened + 1] = { modem, channel }
        end
        raw[modem .. "|" .. channel] = name
    end
    listening[#listening + 1] = name
    chosen[name] = true
    return true
end

local any = #ifaceArgs == 0
for _, name in ipairs(ifaceArgs) do if name == "any" then any = true end end
if any then
    if S then
        local list = {}
        for name in pairs(S.ifaces) do list[#list + 1] = name end
        table.sort(list)
        for _, name in ipairs(list) do listen(name) end
    else
        for _, name in ipairs(peripheral.getNames()) do
            if peripheral.getType(name) == "modem" then listen(name) end
        end
    end
end
for _, name in ipairs(ifaceArgs) do
    if name ~= "any" then
        local okL, why = listen(name)
        if not okL then cu.fail(why) end
    end
end
if cu.status ~= 0 then
    for _, o in ipairs(opened) do pcall(peripheral.call, o[1], "close", o[2]) end
    return cu.exit()
end
if #listening == 0 then cu.fail("nothing to listen on: no modems (tcpdump -D lists what there is)"); return cu.exit() end
showIface = #listening > 1 or (#ifaceArgs > 0 and any)
printError("tcpdump: listening on " .. table.concat(listening, ", ") .. (opts.w and (", writing " .. opts.w) or "")
    .. "; Ctrl+T stops")

local buf, woken = {}, false
local key = {}
local function push(dir, iface, f)
    buf[#buf + 1] = { t = now(), dir = dir, iface = iface, frame = copy(f) }
    if not woken then woken = true; os.queueEvent("tcpdump") end
end
if S then
    S.taps[key] = function(dir, iface, f) if tapped[iface] then push(dir, iface, f) end end
end

local okRun, err = pcall(function()
    while not done() do
        local ev = table.pack(os.pullEventRaw())
        if ev[1] == "terminate" then break end
        if ev[1] == "modem_message" then
            local name = raw[tostring(ev[2]) .. "|" .. tostring(ev[3])]
            if name then push("in", name, ev[5]) end
        end
        woken = false
        local batch = buf
        buf = {}
        for _, rec in ipairs(batch) do
            if done() then break end
            handle(rec)
        end
    end
end)
if S then S.taps[key] = nil end
for _, o in ipairs(opened) do pcall(peripheral.call, o[1], "close", o[2]) end
if out then out:close() end
if not okRun then cu.fail(tostring(err)); return cu.exit() end
printError(string.format("%d packet%s captured\n%d packet%s received by filter", captured, captured == 1 and "" or "s",
    seen, seen == 1 and "" or "s"))
return cu.exit()
