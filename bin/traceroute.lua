-- traceroute.lua -- the routers on the way to a host
--
--   traceroute [-n] [-m hops] [-q queries] [-w seconds] host
--
-- Sends echo requests with a TTL of 1, then 2, and so on (up to -m, 30):
-- each router on the way drops the one whose TTL runs out there and says
-- so (ICMP time exceeded), so each line is the next hop: its address and
-- how long each of -q (3) tries took, "*" for one with no answer in -w (2)
-- seconds.  A hop with a name (lib/netdb: `ip host`, else DNS's PTR
-- record) shows it with the address in brackets; -n: addresses alone, no
-- lookups for the hops.  host is an address or a name.  It stops at the host (its echo reply), or at "!N" (a router
-- has no route on), "!H" (no ARP answer: no such host on the last
-- network), "!X" (administratively prohibited: a filter, such as a Network
-- Gateway in NAT mode, which carries no ICMP past it) or "!P".  Exit status 0 if it got to the host, 1 if not, 2
-- for trouble.

package.path = (ccnix and ccnix.lib or "/" .. fs.getDir(fs.getDir(shell.getRunningProgram())) .. "/lib/?.lua;") .. package.path  -- ccnix's lib/, or the one beside bin/
local cu = require("cu").init("traceroute", "traceroute [-n] [-m hops] [-q queries] [-w seconds] host")
local net = require("net")
local netdb = require("netdb")
local convert = require("convert")
local opts, operands = cu.getopt({ ... }, "nm:q:w:")
if #operands ~= 1 then cu.usageError() end
local maxHops, queries, wait = convert.toNumber(opts.m or "30"), convert.toNumber(opts.q or "3"), convert.toNumber(opts.w or "2")
if not (maxHops and queries and wait) then cu.usageError("bad number") end

local S, why = net.stack()
if not S then cu.fail(why, 2); return cu.exit() end
local host = operands[1]
local ai, why2 = netdb.getaddrinfo(host, nil, { socktype = netdb.SOCK_RAW })
if not ai then cu.fail(host .. ": " .. why2, 2); return cu.exit() end
local target = ai[1].addr
local dst = net.parseIP(target)

-- a hop as it's shown: "name (a.b.c.d)", or the address
local shown = {}
local function hopName(ip)
    if opts.n then return ip end
    if not shown[ip] then
        local name = netdb.getnameinfo(ip, nil, netdb.NI_NAMEREQD)
        shown[ip] = name and (name .. " (" .. ip .. ")") or ip
    end
    return shown[ip]
end

local MARK = { net = "!N", host = "!H", port = "!P", prohibited = "!X" }
local HINT = "a Network Gateway in NAT mode carries TCP and UDP only, no ICMP past it; it answers ping itself"
local id = math.random(1, 65535)
io.write(string.format("traceroute to %s (%s), %d hops at most\n", host, target, maxHops))
local arrived, stopped, prohibited = false, false, false
for ttl = 1, maxHops do
    local line, hop = { string.format("%2d ", ttl) }, nil
    for q = 1, queries do
        local seq = ttl * 100 + q
        local t0 = os.epoch("utc")
        local ok, err = S.echo(dst, id, seq, ttl)
        if not ok then cu.fail(err, 2); return cu.exit() end
        -- (a reply: kind, from, id, seq, ttl; an error: kind, from, code, the packet it's about)
        local kind, from, a = net.awaitEcho(id, seq, wait)
        local ms = os.epoch("utc") - t0
        if kind then
            if from ~= hop then line[#line + 1] = " " .. hopName(from); hop = from end
            line[#line + 1] = string.format("  %d ms", ms)
            if kind == "reply" then arrived = true
            elseif kind == "unreachable" then
                line[#line + 1] = " " .. (MARK[a] or "!")
                stopped, prohibited = true, prohibited or a == "prohibited"
            end
        else
            line[#line + 1] = "  *"
        end
    end
    io.write(table.concat(line), "\n")
    if arrived or stopped then break end
end
if prohibited then io.write("  (" .. HINT .. ")\n") end
if cu.status == 0 and not arrived then return cu.exit(1) end
return cu.exit()
