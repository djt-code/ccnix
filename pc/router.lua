-- router.lua -- a computer that routes between its networks
--
--   router          turn forwarding on, bring the network up, and watch it
--   router boot     route from every boot (the network starts at boot,
--                   forwarding on); `setup router --autostart router`
--                   (or `ccnix setup --autostart router`) brings this
--                   screen up at boot too
--
-- A router is a computer with an interface on each network it joins: a
-- modem each (wired or wireless), or VLANs on one modem ("back.10",
-- "back.20": a trunk).  Set them up with `ip addr add`, then `router`.
-- Hosts on each network point their default route at the router's
-- address there (`ip route add default via 10.0.1.1`); for networks behind
-- another router, `ip route add 10.0.3.0/24 via <that router>` here.
-- `help network` walks through a lab: two networks and a router.
--
-- The screen shows each interface (address, frames in and out), the
-- routes, packets forwarded and dropped (spoofed: from a source that
-- can't be, or one `ip rpfilter` refuses), and the latest messages (ARP
-- with no answer...); it updates every second.  q leaves the screen: the
-- routing carries on (it runs alongside whatever the computer does, see
-- lib/net.lua), until `ip down` or a reboot.

package.path = (ccnix and ccnix.lib or "/" .. fs.getDir(fs.getDir(shell.getRunningProgram())) .. "/lib/?.lua;") .. package.path  -- ccnix's lib/, or the one beside pc/
local net = require("net")
local args = { ... }

shell.run("ip", "forward", "on")

if args[1] == "boot" then
    shell.run("ip", "boot")
    print("Forwarding is on: this computer routes from boot.")
    return
elseif args[1] then
    print("Usage: router [boot]")
    return
end

local S = net.stack()
if not S then
    local problems
    S, problems = net.up()
    for _, p in ipairs(problems) do printError(p) end
end
S.forward = true

local function line(y, text, colour)
    local w = term.getSize()
    term.setCursorPos(1, y)
    term.clearLine()
    if colour and term.isColour() then term.setTextColour(colour) end
    term.write(text:sub(1, w))
    term.setTextColour(colours.white)
end

local function draw()
    local _, h = term.getSize()
    term.clear()
    local c = S.counters
    line(1, string.format("router %d: forwarded %d, dropped %d (spoofed %d)", os.getComputerID(), c.forwarded,
        c.dropped, c.spoofed or 0), colours.yellow)
    local y = 2
    local names = {}
    for k in pairs(S.ifaces) do names[#names + 1] = k end
    table.sort(names)
    for _, name in ipairs(names) do
        local i = S.ifaces[name]
        line(y, string.format("%-9s %-18s in %d out %d", name, net.cidrString(i.ip, i.len), i.rx, i.tx))
        y = y + 1
    end
    if #names == 0 then line(y, "no interfaces: ip addr add <iface> <addr/len>", colours.red); y = y + 1 end
    for _, r in ipairs(S.routes) do
        if not r.connected and y < h - 2 then
            line(y, string.format("%-18s via %s", r.len == 0 and "default" or net.cidrString(r.net, r.len),
                net.ipString(r.gw)), colours.lightGrey)
            y = y + 1
        end
    end
    for k = math.max(1, #S.log - (h - y - 1) + 1), #S.log do
        if y >= h then break end
        line(y, S.log[k], colours.orange)
        y = y + 1
    end
    line(h, "q: leave this screen (it keeps routing)", colours.grey)
end

local timer = os.startTimer(1)
draw()
while true do
    local ev, a = os.pullEvent()
    if ev == "char" and a == "q" then break
    elseif ev == "timer" and a == timer then draw(); timer = os.startTimer(1) end
end
term.clear()
term.setCursorPos(1, 1)
print("Still routing (ip down stops it).")
