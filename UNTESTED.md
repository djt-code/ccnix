# Untested in game

What's built and passes the sims but hasn't been tried in a real game yet.
A scenario goes in when the change ships, and moves to **Tested** (with the
date and what happened) once someone has run it. Newest first in each
section.

## Editors

- **`vi` on a computer** (0.25.0). `vi notes`, type with `i`, leave insert
  mode with Ctrl+[ and with Ctrl+C (Esc closes the screen), `:wq`; the file
  has the text. Ctrl+R (a tap) redoes after `u` without rebooting; Ctrl+A
  adds one to a number. `dd`, `p`, `.`, `/word`, `:%s/a/b/g` behave as
  in vi. Mouse wheel scrolls, a click moves the cursor, Ctrl+V pastes.
  On a turtle (39 columns) and a pocket computer (26) the bottom line
  still fits.
- **`vim` colours on an Advanced Computer** (0.25.0). `vim
  /rom/ccnix/bin/ls.lua` (or any Lua file): keywords yellow, strings red,
  comments green; a ccsh script with `#!/ccnix/bin/ccsh` gets the shell's
  colours. On a basic computer it's plain vi. `:set nu`, `:set hls`.
- **`vi` over telnet** (0.25.0). The client's Esc key leaves insert mode
  (lib/telnet now sends a lone Esc as the Esc key); arrows and Ctrl
  keys work.
- **`nano`** (0.25.0) opens CraftOS's `edit`.

## Processes and services

- **A crashing service fails with a traceback** (0.26.0). `service add boom
  lua -e "error('x')"` (or a script with a runtime error) shows `failed:
  <file>:<line>: <msg>` instead of `ended`; `service status boom` shows
  `(status 1, Ns ago)` and the indented traceback; `/var/log/messages` has
  `boom[pid]: crashed: ...` and the traceback lines at err. Restart backoff
  still applies. A syntax error or a missing command now ends `failed: exit
  status 1`; Ctrl+T or `kill -TERM` from outside `service stop` shows
  `failed: Terminated` with no traceback.
- **Commands run through lib/procrun** (0.26.0). Services, telnet sessions
  and the console chain (autostart, ccsh) still start and get their quoted
  arguments as before; `shell.getRunningProgram()` and `arg` inside them are
  unchanged; a cu utility's own non-zero exit still shows as `failed: exit
  status N` with no "crashed" line.
- **Sockets closed at reap** (0.26.0). `kill -9` a service that listens
  (telnetd, or httpd on 80), let it restart: it binds its port again without
  a reboot; `netstat -p` no longer lists the dead pid; a telnet client
  connected to a killed telnetd gets a close or reset.
- **An init panic** (0.26.0). Hard to trigger (a temporary `error()` in a
  K.after callback in lib/proc.lua): `/var/log/panic` has the error,
  traceback, ps table and unfiled log lines; it prints "Rebooting in 10 s"
  and reboots; holding Ctrl+T during the wait shuts down instead; `set
  init.panic 0` shuts down at once, as before. After the reboot,
  `/var/log/messages` has a kern.crit "the last boot ended in a panic: ..."
  line and the report is at `/var/log/panic.1`.
- **init under xpcall and the coroutine.resume swap** (0.26.0). init runs
  normally (services, the console, telnet), so yielding across xpcall works
  under Cobalt; programs that use `parallel` (telnet, httpd, the miner under
  init) show no cost or side effects from the per-turn swap.

## Network

- **`ip neigh add` / `ip neigh del`** (ccnix 0.24.0). On a lab computer,
  `ip neigh add <addr> lladdr <mac>` for a host on its network, with the
  network down and again up: `ip neigh` shows it `permanent`; a ping to that
  host sends no ARP request (`tcpdump -i <iface> arp` shows no who-has); it
  survives `ip down` / `ip up` and a reboot (setting `net.neigh`); a wrong
  MAC breaks pings to that host; `ip neigh del <addr>` brings ARP back.
  `dev <iface>` for an address off every interface's network.
- **Source checking on the host's TUN chain** (`ccnix0-src`): needs
  `gateway.sourceCheck` off, then a forged source from inside is dropped by
  the host instead.
- **Syslog forwarding in NAT mode**: `@host` rules forwarding out through a
  NAT-mode gateway.

## mine

- **Resuming from an earlier home walks out in one go** (0.22.0). `mine
  reset --home N` (N a few homes back), then `mine --resume`: one pass to the
  last home, valuables kept on board (none left in home N), useful supplies
  picked up from each home passed, no shuttling back and forth; where water
  gets in it stops, seals it (trips for bulk blocks go to the home ahead), and
  carries on; the block above the last home's valuables chest is cleared.
- **Torch look-round only with water in front** (0.21.9): in a dry tunnel no
  extra turns at torch spots; next to water, no torch that gets washed away.
- **Floor beside old patches checked only near water** (0.21.8): a long walk
  out over dry tunnel doesn't cross to the other columns at cobblestone
  patches; near water it does, and fills open floor there.
- **Sweep fallback for water it can't trace** (0.21.6): a stretch still wet
  after going back over it gets every outside face of the tunnel there looked
  at and sealed.
- **Lava burned with a bucket** (0.21.0, logged per source since 0.21.7):
  `grep "Burned a lava" /var/log/messages` after it meets lava sources; the
  bucket stays on board and comes back to the start chest at the end.
- **The water-after-survey path** (0.19.0): water getting in while a segment
  is dug with a scanner is sealed after the survey and the floor walked again.
- **A real cavern** (0.18.2): bulk blocks fetched from the homes behind when
  a cavern runs it out; scans still trusted in a cavern.
- **Floor holes reported** (0.21.4): `Left N floor holes open at z=a..b` when
  it runs out of bulk blocks, and the next pass filling them.

## Setup and boot

- **The rest of CraftOS's startup after ccnix** (0.25.1, rewritten from the
  documented behaviour). With `ccsh.login` (or `init.boot`) set from the
  ROM, the computer's `/startup.lua` or `/startup/` folder still runs before
  ccsh; with `shell.allow_disk_startup` on and a disk holding `startup.lua`
  in a drive, the disk's startup runs instead of the computer's; the MOTD
  shows with `motd.enable` on.

- **`wget run …/deploy/setup.lua` on a bare old install** (0.20.0): a
  computer that still has only `/cc-turtles` (from before ccnix): moved to
  `/ccnix`, pointed at the ccnix repo, pulled, old startup lines swapped.
  (`git pull` then `deploy/setup` on such a turtle worked.)
- **`ccnix setup` on a server with the ccnix mod** (0.20.0): settings and
  apps chosen through the ROM's setup.
- **`syslog.maxSize` with K/M** (0.21.0): `set syslog.maxSize 2M`, and a log
  rotating at that size.

## Fileserver

- **Tab completion in /jbod** (0.25.1). On a fileserver with the pool at
  `/jbod`, Tab in the CraftOS shell and in ccsh completes `/jbod`, its
  folders and the files in them (`cd /jb<Tab>`, `cat /jbod/docs/<Tab>`,
  `cd <Tab>` inside `/jbod` offers `../`). This now goes through CraftOS's
  own `fs.complete`, loaded again from `/rom/apis/fs.lua` over the patched
  fs; the sims only cover a stand-in of that file and jbod's fallback.

- **Disk labels** (0.18.1): each pooled disk labelled `<computer label>
  <drive>`; labels it didn't set left alone.

## The mod

- **Credits in the mod list** (ccnix-mod 0.15.39): the ccnix entry in the
  mod list shows the new Credits text (from `credits=` in mods.toml).
- **The ansible EULA gate** (ccnix-mod 0.15.39): a run with
  `minecraft_eula_accepted` unset skips the eula.txt task and leaves an
  existing eula.txt alone; on a fresh host the server doesn't start until
  eula.txt says true; `-e minecraft_eula_accepted=true` writes it.

- **Everything since ROM 0.19.1 on a modded server**: the dev server still
  runs ccnix-mod 0.15.22. Deploying a newer jar brings the ROM up to date;
  then `ccnix version` there, and the items above that need the mod.

## Help pages

- **Trademark and wording notes** (0.25.2): `help git`, `help tcpdump`,
  `help claude`, `help vi` and `help vim` end with the new trademark,
  credit and wording paragraphs. Docs only; just read them.

## Known issues seen, not yet looked at

- The first boot's lines can appear twice in `/var/log/messages`, the first
  copy cut short.

## Tested

- 2026-11-06 — `mine where` (0.23.0): last home, next home and the reset
  line shown, while mine ran as a service.
- 2026-11-06 — mine as a service under init (0.21.0): started at boot,
  logged to `/var/log/messages`, `service stop` / `service start` resumed it.
- 2026-11-06 — Going back over just where water was (0.21.5): fixed a leak
  through the far wall on a long walk out.
- 2026-11-06 — Lava pouring in from above sealed round while digging.
