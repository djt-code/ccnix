-- nc.lua -- netcat: TCP connections and UDP datagrams over the network stack
--
--   nc [-nv] [-w seconds] host port         connect (TCP); typed lines go, what comes is printed
--   nc -l [-nv] [-p port | port]            wait for one connection, then the same
--   nc -u [-nv] [-p port] [-w seconds] host port     send each line as a UDP datagram
--   nc -u -l [-nv] port                              print the datagrams that come to port
--   nc -z [-nv] [-w seconds] host port[-port]          is anything listening? (TCP; a range: each)
--
-- host is an address or a name, port a number or a service's name (http,
-- echo...): lib/netdb looks them up (`ip host`, then DNS).  -n: numbers
-- only, no lookups.
--
-- TCP (the default): each line of standard input goes down the connection
-- with "\n" after it, and whatever comes back is printed as it arrives.
-- When the input ends (Ctrl+T at the keyboard), nc closes its half and
-- prints on until the other side closes; with -w, at most that many
-- seconds more (-w also limits how long connecting may take).  It also
-- ends when the other side closes.  -l listens on
-- port for one connection.  -v says who connected, and how it ended.
-- Carriage returns before a newline aren't printed to the screen.
--
-- UDP (-u): lines go as datagrams to host:port (from -p port, else any
-- free one); what comes back to that port is printed meanwhile, and for
-- -w (1) seconds after the input ends.  -l prints every datagram that
-- comes to port until Ctrl+T.  -v puts "from address:port" first.  A
-- datagram that's a string prints as it is; anything else (a table)
-- serialised.
--
-- Scanning (-z): connect to each port (a range, 20-25, is each port in
-- it, in order), then close at once, sending nothing.  Quiet, unless -v
-- says how each went: open, refused (nobody is listening: the far side
-- reset it), timed out (no answer in -w seconds, or until TCP gave up),
-- or why it couldn't be tried (no route).  Exit status 0 if any port was
-- open, 1 if none, as with BSD's netcat: `nc -z router 23 && telnet
-- router` in a script.
--
-- The network must be up (`ip up`).  Exit status 1 if the connection
-- couldn't be made or broke.

package.path = (ccnix and ccnix.lib or "/" .. fs.getDir(fs.getDir(shell.getRunningProgram())) .. "/lib/?.lua;") .. package.path  -- ccnix's lib/, or the one beside bin/
local cu = require("cu").init("nc",
    "nc [-nv] [-w seconds] host port | nc -l [-nv] [-p port | port] | nc -u [-nv] [-p port] [-w seconds] host port"
        .. " | nc -u -l [-nv] port | nc -z [-nv] [-w seconds] host port[-port]")
local net = require("net")
local netdb = require("netdb")
local text = require("text")
local convert = require("convert")
local opts, operands = cu.getopt({ ... }, "ulnvzp:w:")
local socktype = opts.u and netdb.SOCK_DGRAM or netdb.SOCK_STREAM
local numeric = opts.n and netdb.AI_NUMERICHOST + netdb.AI_NUMERICSERV or 0

-- host and port (port alone: this computer's, to listen on), looked up:
-- the address and port number, or nil after saying why.
local function lookup(host, port)
    local ai, why = netdb.getaddrinfo(host, port, { socktype = socktype, flags = numeric + (host and 0 or netdb.AI_PASSIVE) })
    if ai then return ai[1].addr, ai[1].port end
    cu.fail((host and (host .. " ") or "") .. tostring(port) .. ": " .. why, 2)
end

local S, why = net.stack()
if not S then cu.fail(why, 2); return cu.exit() end
local wait = opts.w and convert.toNumber(opts.w)
if opts.w and not wait then cu.usageError("bad -w " .. opts.w) end

-- Run fn, taking Ctrl+T (here, after the input) as the end.
local function guarded(fn, ...)
    local ok, e = pcall(fn, ...)
    if not ok and e ~= "Terminated" then error(e, 0) end
end

--------------------------------------------------------------------------
-- Scanning: -z
--------------------------------------------------------------------------
-- A port operand "port" or "low-high": the first and last port number
-- (a service's name stands for its port, alone, not in a range), or nil
-- after saying why.
local function portRange(s)
    local dash = text.find(s, "-", 2)               -- (after the first character)
    if not dash then
        local _, port = lookup(nil, s)
        return port, port
    end
    local low, high = convert.toInteger(s:sub(1, dash - 1)), convert.toInteger(s:sub(dash + 1))
    if not (low and high) or low < 1 or high > 65535 or low > high then
        cu.fail("bad port range " .. s .. " (low-high, 1-65535)", 2)
        return nil
    end
    return low, high
end

if opts.z then
    if opts.u or opts.l then cu.usageError("-z scans TCP ports: not with -u or -l") end
    if #operands ~= 2 then cu.usageError() end
    local host = lookup(operands[1], 0)
    if not host then return cu.exit() end
    local low, high = portRange(operands[2])
    if not low then return cu.exit() end
    local name = operands[1] .. (host ~= operands[1] and (" (" .. host .. ")") or "")
    local open = 0
    guarded(function()
        for port = low, high do
            local conn, err = net.connect(host, port, wait)
            local serv = netdb.getservbyport(port, "tcp")
            local what = name .. " " .. port .. (serv and (" (" .. serv.name .. ")") or "")
            if conn then
                open = open + 1
                conn:close()                -- (nothing sent; the close finishes on its own)
                if opts.v then printError(what .. ": open") end
            elseif opts.v then
                local said = err == "connection refused" and "refused"
                    or err == "connection timed out" and "timed out" or err
                printError(what .. ": " .. said)
            end
        end
    end)
    return cu.exit(cu.status > 0 and cu.status or (open > 0 and 0 or 1))
end

--------------------------------------------------------------------------
-- UDP
--------------------------------------------------------------------------
if opts.u then
    local function show(data, from, port)
        if opts.v then io.write(string.format("from %s:%s: ", tostring(from), tostring(port))) end
        local s = type(data) == "string" and data or textutils.serialise(data, { compact = true })
        io.write(s, text.endsWith(s, "\n") and "" or "\n")
    end
    local function printing(sock)
        while true do
            local data, from, p = sock:receive()
            if data ~= nil then show(data, from, p) end
        end
    end

    if opts.l then
        if not (operands[1] or opts.p) or #operands > 1 then cu.usageError() end
        local _, port = lookup(nil, operands[1] or opts.p)
        if not port then return cu.exit() end
        local sock, err = net.udp(port)
        if not sock then cu.fail(err, 2); return cu.exit() end
        guarded(printing, sock)
        sock:close()
        return cu.exit()
    end

    if #operands ~= 2 then cu.usageError() end
    local host, port = lookup(operands[1], operands[2])
    if not host then return cu.exit() end
    local from = opts.p and select(2, lookup(nil, opts.p))
    if opts.p and not from then return cu.exit() end
    local sock, err = net.udp(from)
    if not sock then cu.fail(err, 2); return cu.exit() end
    guarded(parallel.waitForAny,
        function()
            for line in cu.lines({}) do
                local sent, why2 = sock:send(host, port, line)
                if not sent then cu.fail(why2) end
            end
            sleep(wait or 1)
        end,
        function() printing(sock) end)
    sock:close()
    return cu.exit()
end

--------------------------------------------------------------------------
-- TCP
--------------------------------------------------------------------------
local conn
if opts.l then
    if not (operands[1] or opts.p) or #operands > 1 then cu.usageError() end
    local _, port = lookup(nil, operands[1] or opts.p)
    if not port then return cu.exit() end
    local l, err = net.listen(port)
    if not l then cu.fail(err, 2); return cu.exit() end
    guarded(function() conn = l:accept() end)
    l:close()
    if not conn then return cu.exit() end
    if opts.v then
        local ip, p = conn:remote()
        printError("connection from " .. ip .. ":" .. p)
    end
else
    if #operands ~= 2 then cu.usageError() end
    local host, port = lookup(operands[1], operands[2])
    if not host then return cu.exit() end
    local err
    conn, err = net.connect(host, port, wait)
    if not conn then cu.fail(operands[1] .. " " .. port .. ": " .. err); return cu.exit() end
    if opts.v then printError("connected to " .. operands[1] .. (host ~= operands[1] and (" (" .. host .. ")") or "") .. " " .. port) end
end

local screen = cu.isTerminal()
local broke
guarded(parallel.waitForAny,
    function()
        for line in cu.lines({}) do
            if not conn:send(line .. "\n") then return end
        end
        conn:close()
        if wait then sleep(wait) else while true do os.pullEvent("never") end end
    end,
    function()
        while true do
            local s, e = conn:read()
            if not s then
                if e ~= "closed" then broke = e end
                return
            end
            io.write(screen and (text.replace(s, "\r\n", "\n")) or s)
        end
    end)
local state = conn:state()
if state ~= "CLOSED" then conn:close() end
if broke then cu.fail(broke) elseif opts.v then printError("closed") end
return cu.exit()
