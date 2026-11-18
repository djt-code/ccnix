-- gpsd.lua -- a GPS host: answers CC's GPS, where computers ask where they are
--
--   gpsd                    serve (run it as a service: see below)
--
-- Any computer, turtle or pocket computer with a wireless modem finds its
-- position with gps.locate() (or `gps locate`), from the GPS hosts in
-- range: it pings, each host answers with its position, and the distances
-- its modem measured to the answers fix where it is.  gpsd is such a host,
-- as `gps host` is, but run by init: it starts at boot, starts again if
-- it ends, and logs.  It answers on every wireless modem (ender modems
-- too), and on modems attached later.
--
-- Where it is: gpsd.x, gpsd.y and gpsd.z, the computer's own block (F3's
-- "Targeted Block" while you look at it): CC measures distances from the
-- block the modem is on, exactly, so a block off is wrong.  Without them, a command computer knows its own; another
-- locates itself from the other hosts (tried every 10 s until there's a
-- fix; not saved: a computer moved locates again at boot).  A position
-- from the settings is checked when it starts: it pings, and weighs each
-- host's answer, the distance measured against the distance between the
-- two positions.  If most of the hosts that answer disagree (two or more),
-- the position is wrong, or the computer was moved, and gpsd doesn't serve:
-- it says so in red on the console and checks again every minute.  A host
-- that disagrees while most agree is named in the log: its position, or
-- this one, is wrong.  If no host answers (they all started at once), it
-- serves, and checks again every minute until one does.  gpsd.check=false
-- skips the check.
--
-- A constellation: four hosts at least, not all at one height (four in one
-- plane leave two answers), as far apart as the modems reach, high up (a
-- wireless modem reaches farther the higher it is; an ender modem reaches
-- the whole dimension, but not another).  Around where the turtles work,
-- not off to one side: outside the hosts a small error grows (a host one
-- block out moves a fix 1000 blocks away by tens of blocks).  A client
-- needs four in range.  Pocket computers and turtles can't host: they move.
--
-- Settings: gpsd.x, gpsd.y, gpsd.z; gpsd.check (true: check the position
-- at start); gpsd.facility (daemon: the system log's facility).
--
-- To keep it running in the background, with init (`help init`):
--   service add gpsd gpsd
--   service enable gpsd             (at boot)
--   service start gpsd
-- deploy/setup gpsd does all that (`setup gpsd --at x,y,z` sets the
-- position too).  It logs when it starts serving, what the check found,
-- and every 10 minutes how many requests it has answered, if any: `service
-- status gpsd` shows the last of it (`help syslog`).

package.path = (ccnix and ccnix.lib or "/" .. fs.getDir(fs.getDir(shell.getRunningProgram())) .. "/lib/?.lua;") .. package.path  -- ccnix's lib/, or the one beside bin/
local G = require("gpsd")
local R = require("realtime")

if #{ ... } > 0 then
    printError("Usage: gpsd   (the position from gpsd.x, gpsd.y and gpsd.z: `help gpsd`)")
    return
end
local syslog = require("log").new("gpsd", settings.get("gpsd.facility") or "daemon", { perror = true })
local d, why = G.new({
    peripheral = peripheral,
    settings = settings,
    log = function(sev, msg) syslog.log(sev, msg) end,
    startTimer = os.startTimer,
    realTimer = R.timer,
    locate = gps and gps.locate,
    commands = commands,
    kind = pocket and "pocket" or turtle and "turtle" or "computer",
})
if not d then
    printError("gpsd: " .. why)
    error("", 0)
end
local ok, err = d:start()
if ok == nil and err then error("", 0) end
while true do
    d:handle(os.pullEvent())
end
