-- host.lua -- ask DNS for a name's addresses, or an address's name
--
--   host [-v] [-t type] name [server]
--
-- A name's addresses (its A records), or an address's name (the PTR
-- record at d.c.b.a.in-addr.arpa), with the aliases (CNAMEs) on the way.
-- -t asks for A, CNAME or PTR records instead.  The DNS servers asked
-- are net.dns's (`ip dns`), primary then secondary, or server alone.
-- DNS only, as the real host does it: names from `ip host` aren't looked
-- at (ping, nc and the rest look at both: lib/netdb).  Exit status 1 if
-- there's no such name or record, 2 for trouble (no servers, none
-- answered, the network isn't up).
--
-- -v shows the question and the answer as a zone file has them (name,
-- TTL, IN, type, data), with the seconds the TTL has left, and who
-- answered: the server and how long it took, or, from the cache (`ip
-- dns cache`), which server answered and how long ago.  `ip dns flush`
-- empties the cache, to ask again.

package.path = (ccnix and ccnix.lib or "/" .. fs.getDir(fs.getDir(shell.getRunningProgram())) .. "/lib/?.lua;") .. package.path  -- ccnix's lib/, or the one beside bin/
local cu = require("cu").init("host", "host [-v] [-t type] name [server]")
local net = require("net")
local netdb = require("netdb")
local text = require("text")
local opts, operands = cu.getopt({ ... }, "vt:")
if #operands < 1 or #operands > 2 then cu.usageError() end
local name, server = operands[1], operands[2]
if server and not net.parseIP(server) then cu.usageError("bad server address " .. server) end
local qtype = opts.t and opts.t:upper()
if net.parseIP(name) then
    local o = text.split(net.ipString(net.parseIP(name)), ".", true)     -- (its four numbers)
    name = o[4] .. "." .. o[3] .. "." .. o[2] .. "." .. o[1] .. ".in-addr.arpa"
    qtype = qtype or "PTR"
end
qtype = qtype or "A"
local verbose = opts.v

-- -v: the question, then (after the query) each record as a zone file
-- has it, and who answered
if verbose then io.write('Trying "', name, '"\n', ";; QUESTION SECTION:\n", ";", name, ".  IN  ", qtype, "\n") end
local t0 = os.epoch("utc")
local answers, why, kind, nxInfo = netdb.res_query(name, qtype, server and { server })
local ms = os.epoch("utc") - t0
local info = answers and why or nxInfo           -- (where the answer came from)

-- the last -v line: the server that answered, or the cache's word for it
local function whoAnswered()
    if not (verbose and info) then return end
    if info.cached then
        io.write(string.format("\n;; from the cache: %s#53 answered %d s ago\n", info.server, math.floor(info.age)))
    else
        io.write(string.format("\nReceived from %s#53 in %d ms\n", info.server, ms))
    end
end

if not answers then
    if kind == "NXDOMAIN" then
        if verbose then io.write(";; status: NXDOMAIN\n") end
        io.write("Host ", name, " not found: 3(NXDOMAIN)\n")
        whoAnswered()
        return cu.exit(1)
    end
    cu.fail(why, 2)
    return cu.exit()
end

if verbose then
    -- name. TTL IN type data, the TTL less the time it's been kept
    io.write(";; status: NOERROR, answers: ", #answers, "\n")
    if #answers > 0 then io.write("\n;; ANSWER SECTION:\n") end
    for _, rr in ipairs(answers) do
        local data = tostring(rr.data) .. ((rr.type == "CNAME" or rr.type == "PTR") and "." or "")
        local ttl = math.max(0, rr.ttl - math.floor(info.age))
        io.write(string.format("%-28s %6d  IN  %-5s %s\n", rr.name .. ".", ttl, tostring(rr.type), data))
    end
    whoAnswered()
    if #answers == 0 then return cu.exit(1) end
    return cu.exit()
end

-- each record type host shows: the words before its data, and after
local SAYS = { A = { " has address ", "" }, CNAME = { " is an alias for ", "." }, PTR = { " domain name pointer ", "." } }
local said = 0
for _, rr in ipairs(answers) do
    local says = SAYS[rr.type]
    if says then
        io.write(rr.name, says[1], rr.data, says[2], "\n")
        said = said + 1
    end
end
if said == 0 then
    io.write(name, " has no ", qtype, " record\n")
    return cu.exit(1)
end
return cu.exit()
