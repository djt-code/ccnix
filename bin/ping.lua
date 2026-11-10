-- ping.lua -- send ICMP echo requests and time the replies
--
--   ping [-q] [-c count] [-i seconds] [-t ttl] [-W seconds] [-w deadline] [-s size] [-I iface|addr] host
--
-- host is an address (10.0.2.5) or a name: lib/netdb looks it up (`ip
-- host`'s names, then DNS: `ip dns`).  Sends echo requests `-i` (1)
-- seconds apart, each waiting up to `-W` (2) seconds for its reply, and
-- says what came back: a reply (its TTL, and the round trip in
-- milliseconds), "destination unreachable" from a router or this
-- computer (no route: net; no ARP answer: host), "administratively
-- prohibited" (a filter: a Network Gateway in NAT mode carries no ICMP
-- past it, though it answers ping itself), or time exceeded (the TTL ran
-- out on the way: a routing loop, or -t too small).
--
-- It goes on until Ctrl+T, or until `-c` requests have gone (-c 0: no
-- limit), then says how many went and came back, and the round trips'
-- least, mean and most, and their standard deviation (min/avg/max/mdev).
-- -w stops it after deadline seconds, however many have gone; with -c
-- too, it stops as soon as count replies are in.  -q prints only the
-- first line and the summary.
--
-- -s puts size bytes of data in each request (0 to 65507; none unless
-- given): the far side sends them back, so each reply shows its size
-- (bytes=), and one that comes back short or changed says so.  Large
-- ones test a path's limits (the ccnix mod's gateway carries the data as
-- a real ICMP payload).
--
-- -I sends from an interface ("back.20": its address, and out of it only,
-- whatever the routes would otherwise pick) or from one of this computer's
-- addresses (the routes pick the way, as ever).  The answer comes back to
-- that address, so it shows whether the far side can reach it.
-- Exit status 0 if any reply came (with -w and -c: if count came), 1 if
-- not, 2 for trouble (the network isn't up, a name that can't be looked
-- up).

package.path = (ccnix and ccnix.lib or "/" .. fs.getDir(fs.getDir(shell.getRunningProgram())) .. "/lib/?.lua;") .. package.path  -- ccnix's lib/, or the one beside bin/
local cu = require("cu").init("ping",
    "ping [-q] [-c count] [-i seconds] [-t ttl] [-W seconds] [-w deadline] [-s size] [-I iface|addr] host")
local net = require("net")
local netdb = require("netdb")
local convert = require("convert")
local opts, operands = cu.getopt({ ... }, "qc:i:t:W:w:s:I:")
if #operands ~= 1 then cu.usageError() end

-- a number option's value (absent: dflt), at least `least` (0), or a
-- usage error
local function number(letter, dflt, least)
    if opts[letter] == nil then return dflt end
    local n = convert.toNumber(opts[letter])
    if not n or n < (least or 0) then cu.usageError("bad -" .. letter .. " " .. opts[letter]) end
    return n
end
local count = math.floor(number("c", 0))            -- (0: until Ctrl+T)
local interval, wait = number("i", 1), number("W", 2)
local ttl = opts.t and math.floor(number("t", nil, 1))
local deadline = number("w", nil)
local size = opts.s and math.floor(number("s", nil))
if size and size > 65507 then cu.usageError("-s " .. size .. ": at most 65507") end
local quiet = opts.q

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

-- -s: the data, size printable characters in a run (! to ~, again and
-- again), so a reply cut short or changed shows
local payload
if size then
    local chars = {}
    for k = 1, size do chars[k] = string.char(33 + (k - 1) % 94) end
    payload = table.concat(chars)
end

local function say(...) if not quiet then io.write(...) end end

local id = math.random(1, 65535)
local sent, got = 0, 0
local times = {}            -- each reply's round trip, in ms
-- said once, after the first "administratively prohibited"
local HINT = "a Network Gateway in NAT mode carries TCP and UDP only, no ICMP past it; it answers ping itself"
local told = false
io.write(string.format("PING %s (%s)%s%s\n", host, net.ipString(dst),
    src and (" from " .. net.ipString(src) .. (iface and (" " .. iface) or "")) or "",
    size and (": " .. size .. " data bytes") or ""))

local started = os.clock()
-- seconds left before the deadline (nil: there's none)
local function remaining() return deadline and deadline - (os.clock() - started) end

-- What came back for request seq, said and counted.  (A reply: its TTL
-- and data; an error: its code.)
local function answer(seq, kind, from, code, replyTtl, data, ms)
    if kind == "reply" then
        got = got + 1
        times[#times + 1] = ms
        local bytes = ""
        if payload then
            local n = type(data) == "string" and #data or 0
            bytes = " bytes=" .. n
            if n ~= #payload then bytes = bytes .. " (sent " .. #payload .. ")"
            elseif data ~= payload then bytes = bytes .. " (changed on the way)" end
        end
        say(string.format("reply from %s:%s seq=%d ttl=%d time=%d ms\n", from, bytes, seq, replyTtl, ms))
    elseif kind == "unreachable" and code == "prohibited" then
        say(string.format("from %s: seq=%d administratively prohibited\n", from, seq))
        if not told then say("  (" .. HINT .. ")\n"); told = true end
    elseif kind == "unreachable" then
        say(string.format("from %s: seq=%d destination %s unreachable\n", from, seq, code))
    elseif kind == "timeexceeded" then
        say(string.format("from %s: seq=%d time to live exceeded\n", from, seq))
    else
        say(string.format("no reply: seq=%d\n", seq))
    end
end

-- Whether request seq should go: the deadline not past, and the count
-- not reached (with -w: the replies not all in).
local function more(seq)
    local left = remaining()
    if left and left <= 0 then return false end
    if count == 0 then return true end
    if deadline then return got < count end
    return seq <= count
end

-- The requests, until done or Ctrl+T (which ends them, not ping: the
-- summary still comes).
local function pings()
    local seq = 1
    while more(seq) do
        local t0 = os.epoch("utc")
        local ok, err = S.echo(dst, id, seq, ttl, src, iface, payload)
        if not ok then cu.fail(err, 2); return end
        sent = sent + 1
        local left = remaining()
        local w = left and math.min(wait, math.max(left, 0)) or wait
        -- (a reply: kind, from, id, seq, ttl, data; an error: kind, from, code, the packet it's about)
        local kind, from, a, _, c, data = net.awaitEcho(id, seq, w)
        local ms = os.epoch("utc") - t0
        answer(seq, kind, from, a, c, data, ms)
        seq = seq + 1
        if more(seq) then
            local pause = interval - ms / 1000
            left = remaining()
            if left then pause = math.min(pause, left) end
            if pause > 0 then sleep(pause) end
        end
    end
end
local ok, err = pcall(pings)
if not ok and err ~= "Terminated" then error(err, 0) end

-- the summary: how many, and the round trips (mdev: the square root of
-- the mean square less the square of the mean)
io.write(string.format("--- %s ping statistics ---\n", host))
io.write(string.format("%d sent, %d received, %d%% lost\n", sent, got,
    sent > 0 and math.floor((sent - got) * 100 / sent + 0.5) or 0))
if got > 0 then
    local least, most, sum, squares = math.huge, 0, 0, 0
    for _, t in ipairs(times) do
        least, most = math.min(least, t), math.max(most, t)
        sum, squares = sum + t, squares + t * t
    end
    local mean = sum / got
    local mdev = math.sqrt(math.max(squares / got - mean * mean, 0))
    io.write(string.format("rtt min/avg/max/mdev = %d/%.1f/%d/%.1f ms\n", least, mean, most, mdev))
end
if cu.status == 0 and (got == 0 or (deadline and count > 0 and got < count)) then return cu.exit(1) end
return cu.exit()
