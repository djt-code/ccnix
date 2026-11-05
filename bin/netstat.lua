-- netstat.lua -- the network's sockets, routes and interfaces
--
--   netstat [-atulnpe]          sockets
--   netstat -r                  the routing table
--   netstat -i                  the interfaces, with their frame counts
--   netstat -s                  the stack's counters
--
-- As BSD's and Linux's netstat: one line a socket, its protocol, the
-- bytes waiting to be read (Recv-Q: for UDP, datagrams; for a listener,
-- connections not yet accepted) and to be sent and acknowledged
-- (Send-Q), its local and foreign address, and TCP's state.  Without -a
-- or -l only connections are listed; -l lists the listening sockets (TCP
-- listeners, and UDP sockets, which wait for anyone), -a both.  -t and -u
-- keep to TCP or UDP.  -p adds the process that opened it, as PID/name
-- (under init; see ps).  Addresses are always numbers: -n is taken and
-- changes nothing (looking names up would wait on DNS).  -e is taken too.
-- Over this computer's network stack (`ip up`); exit status 1 if it isn't
-- up.  `ip` sets the routes and interfaces -r and -i show.

package.path = (ccnix and ccnix.lib or "/" .. fs.getDir(fs.getDir(shell.getRunningProgram())) .. "/lib/?.lua;") .. package.path  -- ccnix's lib/, or the one beside bin/
local cu = require("cu").init("netstat", "netstat [-atulnpe] | -r | -i | -s")
local net = require("net")
local opts, operands = cu.getopt({ ... }, "atulnpersi")
if #operands > 0 then cu.usageError("unexpected operand " .. operands[1]) end

local S, why = net.stack()
if not S then cu.fail(why); return cu.exit() end
local ip = net.ipString

-- rows as columns, each as wide as its widest cell (the last one left ragged)
local function columns(rows, right)
    local widths = {}
    for _, r in ipairs(rows) do
        for k, cell in ipairs(r) do widths[k] = math.max(widths[k] or 0, #cell) end
    end
    for _, r in ipairs(rows) do
        local parts = {}
        for k, cell in ipairs(r) do
            if k == #r then parts[k] = cell
            elseif right and right[k] then parts[k] = (" "):rep(widths[k] - #cell) .. cell
            else parts[k] = cell .. (" "):rep(widths[k] - #cell) end
        end
        io.write((table.concat(parts, " "):gsub("%s+$", "")), "\n")
    end
end

local function sorted(t)
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    return keys
end

if opts.r then
    io.write("Kernel IP routing table\n")
    local rows = { { "Destination", "Gateway", "Genmask", "Flags", "Iface" } }
    local routes = {}
    for _, r in ipairs(S.routes) do routes[#routes + 1] = r end
    table.sort(routes, function(a, b) if a.len ~= b.len then return a.len > b.len end return a.net < b.net end)
    for _, r in ipairs(routes) do
        local mask = r.len == 0 and 0 or math.floor(4294967296 - 2 ^ (32 - r.len))
        rows[#rows + 1] = { ip(r.net), r.gw and ip(r.gw) or "0.0.0.0", ip(mask), "U" .. (r.gw and "G" or ""), r.iface }
    end
    columns(rows)
    return cu.exit()
end

if opts.i then
    io.write("Kernel Interface table\n")
    local rows = { { "Iface", "RX-OK", "TX-OK", "Address" } }
    for _, name in ipairs(sorted(S.ifaces)) do
        local ifc = S.ifaces[name]
        rows[#rows + 1] = { name, tostring(ifc.rx), tostring(ifc.tx), net.cidrString(ifc.ip, ifc.len) }
    end
    columns(rows, { [2] = true, [3] = true })
    return cu.exit()
end

if opts.s then
    local c = S.counters
    local n = { tcp = 0, udp = 0, listen = 0 }
    for _ in pairs(S.tcbs or {}) do n.tcp = n.tcp + 1 end
    for _ in pairs(S.sockets) do n.udp = n.udp + 1 end
    for _ in pairs(S.listeners or {}) do n.listen = n.listen + 1 end
    io.write("Ip:\n", "    ", c.forwarded, " forwarded\n", "    ", c.dropped, " dropped\n",
        "    ", c.spoofed, " dropped as spoofed (martian or failing rpfilter)\n",
        "Tcp:\n", "    ", n.tcp, " connections\n", "    ", n.listen, " listening\n",
        "Udp:\n", "    ", n.udp, " sockets\n")
    return cu.exit()
end

-- sockets
local both = not opts.t and not opts.u
local wantTcp, wantUdp = both or opts.t, both or opts.u
local listening, connected = opts.a or opts.l, opts.a or not opts.l
local names = {}
if opts.p then
    local proc = rawget(_G, "proc")
    for _, p in ipairs(proc and proc.list() or {}) do names[p.pid] = p.name end
end
local function who(pid)
    if not pid then return "-" end
    return pid .. "/" .. (names[pid] or "?")
end
-- the address this end of a connection to rip has: the one it came in
-- on, else the one the route out gives
local function localIP(c)
    if c.lip then return c.lip end
    local r = S.route(c.rip)
    local ifc = r and S.ifaces[r.iface]
    return ifc and ifc.ip or 0
end

local rows = { { "Proto", "Recv-Q", "Send-Q", "Local Address", "Foreign Address", "State" } }
if opts.p then rows[1][7] = "PID/Program name" end
local function add(row, pid)
    if opts.p then row[6] = row[6] ~= "" and row[6] or "-"; row[7] = who(pid) end
    rows[#rows + 1] = row
end
if wantTcp and listening then
    for _, port in ipairs(sorted(S.listeners or {})) do
        local l = S.listeners[port]
        add({ "tcp", tostring(#l), "0", "0.0.0.0:" .. port, "0.0.0.0:*", "LISTEN" }, l.pid)
    end
end
if wantTcp and connected then
    local conns = {}
    for _, c in pairs(S.tcbs or {}) do conns[#conns + 1] = c end
    table.sort(conns, function(a, b) return a.id < b.id end)
    for _, c in ipairs(conns) do
        add({ "tcp", tostring(#c.inbox), tostring(#c.out), ip(localIP(c)) .. ":" .. c.lport,
              ip(c.rip) .. ":" .. c.rport, c.state }, c.pid)
    end
end
if wantUdp and listening then
    for _, port in ipairs(sorted(S.sockets)) do
        local sock = S.sockets[port]
        add({ "udp", tostring(#sock.queue), "0", "0.0.0.0:" .. port, "0.0.0.0:*", "" }, sock.pid)
    end
end
io.write("Active Internet connections" .. ((opts.a and " (servers and established)") or (opts.l and " (only servers)")
    or " (w/o servers)") .. "\n")
columns(rows, { [2] = true, [3] = true })
return cu.exit()
