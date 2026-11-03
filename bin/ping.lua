-- ping.lua -- send ICMP echo requests and time the replies
--
--   ping [-c count] [-i seconds] [-t ttl] [-W seconds] [-I iface|addr] host
--
-- host is an address (10.0.2.5) or a name: lib/netdb looks it up (`ip
-- host`'s names, then DNS: `ip dns`).  Sends `count`
-- (4) echo requests, `-i` (1) seconds apart, each waiting up to `-W` (2)
-- seconds for its reply, and says what came back: a reply (its TTL, and
-- the round trip in milliseconds), "destination unreachable" from a
-- router or this computer (no route: net; no ARP answer: host), "administratively
-- prohibited" (a filter: a Network Gateway in NAT mode carries no ICMP past it, though it answers ping itself),
-- or time exceeded (the TTL ran out on the way: a routing loop, or -t too small).
-- -I sends from an interface ("back.20": its address, and out of it only,
-- whatever the routes would otherwise pick) or from one of this computer's
-- addresses (the routes pick the way, as ever).  The answer comes back to
-- that address, so it shows whether the far side can reach it.
-- Exit status 0 if any reply came, 1 if none, 2 for trouble (the network
-- isn't up, a name that can't be looked up).

package.path = (ccnix and ccnix.lib or "/" .. fs.getDir(fs.getDir(shell.getRunningProgram())) .. "/lib/?.lua;") .. package.path  -- ccnix's lib/, or the one beside bin/
local cu = require("cu").init("ping", "ping [-c count] [-i seconds] [-t ttl] [-W seconds] [-I iface|addr] host")
local net = require("net")
local netdb = require("netdb")
local opts, operands = cu.getopt({ ... }, "c:i:t:W:I:")
if #operands ~= 1 then cu.usageError() end
local count = tonumber(opts.c or 4)
local interval, wait, ttl = tonumber(opts.i or 1), tonumber(opts.W or 2), opts.t and tonumber(opts.t)
if not (count and interval and wait) or (opts.t and not ttl) then cu.usageError("bad number") end

local S, why = net.stack()
if not S then cu.fail(why, 2); return cu.exit() end
local host = operands[1]
local ai, why2 = netdb.getaddrinfo(host, nil, { socktype = netdb.SOCK_RAW })
if not ai then cu.fail(host .. ": " .. why2, 2); return cu.exit() end
local dst = net.parseIP(ai[1].addr)

-- -I: an interface (its address, and out of it only) or one of ours
local src, iface
if opts.I then
    if S.ifaces[opts.I] then
        iface = opts.I
        src = S.ifaces[iface].ip
    else
        src = net.parseIP(opts.I)
        if not src then cu.usageError("no interface " .. opts.I .. " (ip addr lists them)") end
        if not S.isMine(src) or math.floor(src / 16777216) == 127 then
            cu.usageError(opts.I .. " isn't one of this computer's addresses (ip addr lists them)")
        end
    end
end

local id = math.random(1, 65535)
local sent, got, total, told = 0, 0, 0, false
-- said once, after the first "administratively prohibited"
local HINT = "a Network Gateway in NAT mode carries TCP and UDP only, no ICMP past it; it answers ping itself"
io.write(string.format("PING %s (%s)%s\n", host, net.ipString(dst),
    src and (" from " .. net.ipString(src) .. (iface and (" " .. iface) or "")) or ""))
for seq = 1, count do
    local t0 = os.epoch("utc")
    local ok, err = S.echo(dst, id, seq, ttl, src, iface)
    if not ok then cu.fail(err, 2); break end
    sent = sent + 1
    -- (a reply: kind, from, id, seq, ttl; an error: kind, from, code, the packet it's about)
    local kind, from, a, b, c = net.awaitEcho(id, seq, wait)
    local ms = os.epoch("utc") - t0
    if kind == "reply" then
        got, total = got + 1, total + ms
        io.write(string.format("reply from %s: seq=%d ttl=%d time=%d ms\n", from, seq, c, ms))
    elseif kind == "unreachable" and a == "prohibited" then
        io.write(string.format("from %s: seq=%d administratively prohibited\n", from, seq))
        if not told then io.write("  (" .. HINT .. ")\n"); told = true end
    elseif kind == "unreachable" then
        io.write(string.format("from %s: seq=%d destination %s unreachable\n", from, seq, a))
    elseif kind == "timeexceeded" then
        io.write(string.format("from %s: seq=%d time to live exceeded\n", from, seq))
    else
        io.write(string.format("no reply: seq=%d\n", seq))
    end
    if seq < count then
        local left = interval - ms / 1000
        if left > 0 then sleep(left) end
    end
end
io.write(string.format("%d sent, %d received, %d%% lost%s\n", sent, got,
    sent > 0 and math.floor((sent - got) * 100 / sent + 0.5) or 0,
    got > 0 and string.format(", average %d ms", math.floor(total / got + 0.5)) or ""))
if cu.status == 0 and got == 0 then return cu.exit(1) end
return cu.exit()
