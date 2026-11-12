# Untested in game

What's built and passes the sims but hasn't been tried in a real game yet.
A scenario goes in when the change ships, and moves to **Tested** (with the
date and what happened) once someone has run it. Newest first in each
section.

## claude: http, the network, programs, memory, the web, the rest (0.39.0)

- **The log** (0.45.0): a session, then claude.log. Each entry starts
  with its time (UTC); the first is `start: claude --cache 1h (model ...,
  effort ..., steps 60, cache 1h; at ... facing ..., fuel ...)`; after
  each call a `tokens: N in (R from the cache, W written to it, U new), O
  out; Ss` line; when a goal ends `goal done: [...]`, as printed; a retry
  and a failed request are logged too.
- `--cache 15m`: refused (0.44.0).

## claude: ccnix's libraries in its code, the rest (0.38.0)

- `require("turtlelib")` and `require("fs")` (0.43.5) say the code has
  them already, as the globals T and fs.

## Everything: the text libraries, what's left (0.36.1-0.37.0)

Every program's parsing moved from Lua patterns to lib/scan (0.36.1),
then onto the shared lib/text, convert, getopt, glob and path (0.37.0).
The two smoke rounds of 2026-11-12 (Tested) covered the shell, globs,
numbers, the text tools and the network tools. Still to try:

- **setup run alone, on a stock CC: Tweaked computer** (no mod): `wget
  run .../deploy/setup.lua`. It fetches lib/scan, text, convert, path and
  getopt into memory before git. Then `ccnix update`; `ccnix setup` once
  on an install made before 0.37.0 adds the text libraries to a checkout
  cloned with `--only` paths; `ccnix setup --autostart=router`; setup's
  migration from an old /cc-turtles, if one is left anywhere.
- **The turtles:** `farm` on a real farm (options through lib/getopt),
  its saved layout read back after a reboot.
- **Text on screen:** the pager wrapping a long coloured line (`vim` on a
  long line).
- **The rest:** a panic report (one row layout); jbod on the
  fileserver; a log message received over the network (syslogd with
  `syslog.listen`, another computer forwarding to it): its line end and
  the blanks before it dropped (a message logged on the computer itself
  keeps them, as util-linux logger does).

## Editors

- **Esc through telnet** (0.43.6): with the ccnix mod on the client,
  `telnet 10.1.1.10`, `vi /tmp/x`, `i`, text, Esc: insert mode left (the
  client now sends Esc as a lone ESC; before, it sent nothing). From a
  real terminal (PuTTY) Esc does the same.

## ccsh

- **Background output while typing, the rest** (0.30.0). A full-screen
  program in the background isn't disturbed; the same over telnet.
- **Ctrl+C left to programs that use it, the rest** (0.29.1). `telnet`
  from a computer without init: Ctrl+C reaches the far side's program.
- **The line editor, the rest** (0.28.0, lib/readline). `read x` at the
  keyboard has the same keys; Ctrl+C there stops the rest of the line.
- **Tab and long lines, the rest** (0.28.0): the completion in grey on a
  basic computer; Up/Down cycle the suggestions. A coloured prompt redraws
  correctly after Ctrl+L. AltGr (Ctrl+Alt) characters on a non-US layout
  type normally and trigger no bindings.
- **Ctrl+C, the rest** (0.28.0): a computer without init; under init it doesn't reach
  ccsh itself when ccsh was started from ccsh.
- **The editor over telnetd** (0.28.0): the same keys from a real terminal
  client (PuTTY, xterm); Alt+B/F arrive as Esc+letter; Ctrl+C at the remote
  prompt drops the line.
- **`$$`, the rest** (0.27.0). Without init (plain CraftOS), `$$` is the
  computer ID and `$PPID` empty.
- **`&>>` and the other `${...}` forms, the rest** (0.27.0). A stock
  program's printError output lands in f with `&>`. `${U:?gone}` in a
  script ends the script with status 1. Plain `unset f` leaves a
  function.

## Processes and services

- **Panics in a row stop rebooting** (0.29.1). With init.boot on and a
  fault init hits at every boot (a temporary `error()` near the top of
  `K.run`), it reboots after each of the first three panics, then the
  fourth shuts the computer down with "panicked 4 times in a row" on the
  screen; `/var/log/panic.count` holds the count. Remove the fault, boot:
  no panic; a panic more than ten minutes later counts from 1 again.

- **Commands run through lib/procrun** (0.26.0). Services, telnet sessions
  and the console chain (autostart, ccsh) still start and get their quoted
  arguments as before; `shell.getRunningProgram()` and `arg` inside them are
  unchanged; a cu utility's own non-zero exit still shows as `failed: exit
  status N` with no "crashed" line.
- **An init panic** (0.26.0). Hard to trigger (a temporary `error()` in a
  K.after callback in lib/proc.lua): `/var/log/panic` has the error,
  traceback, ps table and unfiled log lines; it prints "Rebooting in 10 s"
  and reboots; holding Ctrl+T during the wait shuts down instead; `set
  init.panic 0` shuts down at once, as before. After the reboot,
  `/var/log/messages` has a kern.crit "the last boot ended in a panic: ..."
  line and the report is at `/var/log/panic.1`.
- **init's per-turn swap with `parallel`** (0.26.0). Programs that use
  `parallel` (telnet, httpd, the miner under init) show no cost or side
  effects.

## Network

- **ping, the rest** (0.29.0). `ping -s 65507` through the gateway, in
  NAT mode (the gateway's own address) and in TUN mode (a real host).
- **`netstat -s` on a router, a forged source** (0.29.0): the drop counted
  by reason (martian or rpfilter), and the router screen's spoofed count
  agreeing.
- **`ip neigh add ... dev <iface>`** (ccnix 0.24.0) for an address off
  every interface's network.
- **Source checking on the host's TUN chain** (`ccnix0-src`): needs
  `gateway.sourceCheck` off, then a forged source from inside is dropped by
  the host instead.
- **Syslog forwarding in NAT mode**: `@host` rules forwarding out through a
  NAT-mode gateway.

## mine

- **`mine where` between homes** (0.43.4): after a Ctrl+T part way, it
  says "`mine reset`, then `mine --resume`, carries on" (it said `mine
  --resume`, which wants the turtle at a home); at a home, `mine
  --resume` alone.

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

- **`syslog.maxSize` with K/M** (0.21.0): `sysctl syslog.maxSize=2M`
  (taken, tested), then a log rotating at that size.

- **`ccnix update` on many computers at once** (0.30.2): GitHub answered
  some with 504; git now tries a 5xx again after 2, 4 and 8 s.  If the
  API's hourly limit for the server's address runs out, it says until when.

- **`wget run …/deploy/setup.lua` on a bare old install** (0.20.0): a
  computer that still has only `/cc-turtles` (from before ccnix): moved to
  `/ccnix`, pointed at the ccnix repo, pulled, old startup lines swapped.
  (`git pull` then `deploy/setup` on such a turtle worked.)
- **`ccnix setup` on a server with the ccnix mod** (0.20.0): settings and
  apps chosen through the ROM's setup.

## screen

- **Ctrl+A a with one a** (0.43.6): in screen, Ctrl+A then a gives ccsh
  its Ctrl+A (the start of the line) at once; it wanted a second a (a char
  for Ctrl+A itself was waited for, and CC sends none while Ctrl is held).

## IRC

- **A real client through the gateway** (0.35.0). From the VM:
  `irssi -c 10.1.1.6 -n vm`, /join #minecraft, talk with B. On Libera,
  `/set network.<name>.sasl_user` and `sasl_pass` for SASL (a channel
  that wants a NickServ account, as #minecraft there does).

## The mod

- **The exchange at 10.1.0.0/24** (ccnix-mod 0.18.0). The gateway's default
  address is 10.1.0.1/24, inside the CC networks (10.1.0.0/16), so one LAN
  route reaches every CC computer. On the dev server, after redeploying:
  `ip -br addr show ccnix0` on the host shows 10.1.0.1/24 alone (the old
  10.0.0.1 gone); `/ccnix route add 10.1.0.0/16 via 10.1.0.2` is accepted
  (a route around the exchange) and `10.1.0.0/25 via 10.1.0.2` refused;
  a computer straight on the exchange (no router) reaches the internet.

- **The ansible EULA gate** (ccnix-mod 0.15.39): a run with
  `minecraft_eula_accepted` unset skips the eula.txt task and leaves an
  existing eula.txt alone; on a fresh host the server doesn't start until
  eula.txt says true; `-e minecraft_eula_accepted=true` writes it.


## Known issues seen, not yet looked at

- The first boot's lines can appear twice in `/var/log/messages`, the first
  copy cut short.
- `ip up` on a turtle (2026-11-11, ROM 0.40.3) seemed not to bring the
  network up: pings worked only after `ip boot` and a reboot. `ip up` was
  run before the routes and DNS were set, which apply at once anyway.
  One cause found: claude had swapped the turtle's modem out and back for
  mine's pickaxe, which leaves its channels shut (reopened since
  0.41.1).
- httpd on Lab-B (2026-11-11, ROM 0.40.3), started at boot and logging
  "listening on port 80", later had no listener (`netstat -al` empty,
  "connection refused") while `service status` said running; `service
  restart httpd` brought it back. Before it: the 8.5 network tests
  (`ip neigh add`, a reboot, `ping -c 0` stopped with Ctrl+C, a `ping &`
  stopped with Ctrl+T after `fg`, `nc -w 3` to a host that was down).
  Not found by reading lib/net, lib/proc, lib/httpd yet. After the next
  reboot it was listening (`netstat -tnl`).

## Tested

- 2026-11-12 — ROM 0.44.0, claude caching the conversation: hours of the
  castle build with `--cache 1h`. The Console's usage for one hour: 5.96M
  tokens read from the cache, 81k written to it (all 1-hour), 902 new,
  69k out: 98% of what went in came from the cache, and no context clears
  in those sessions.

- 2026-11-12 — ROM 0.43.5: vim colours a ccsh script (a string over two
  lines, comments after `;`); `*` from a space searches the next word.
  irc: a hilight chimed on Lab-B's speaker; `irc irc.libera.chat`
  connected and joined #minecraft there (speaking needs a NickServ
  account); ccsh's Ctrl+A/E, Ctrl+R, Tab, history.  screen: `screen -x`
  over telnet with Lab-A's console (both showing and typing),
  `screen.prefix=b`.  `help git/tcpdump/claude/vi/vim` end with their
  trademark notes.  Not right (fixed in 0.43.6): Esc in a telnet session
  didn't reach the far side's vi, and Ctrl+A a in screen wanted a second
  a.

- 2026-11-12 — ROM 0.43.3, claude's long session: it equipped a chat box
  from its inventory in the modem's place and said "hello from the
  turtle" in the game's chat (shown as [AP], mc.say given no name), then
  read 47 help pages before its 60 tool calls ran out, said so, and
  carried on when asked; claude.log showed "context: 51 old tool results
  cleared (31278 tokens)" on each request past the threshold (the API
  clears afresh each time). 1.4M tokens in for the goal, half cached.

- 2026-11-12 — ROM 0.43.4, claude: told to dig with mine, Ctrl+T stopped
  both; asked, it found the job unfinished, said where the turtle was,
  and `mine reset --to-start` brought it back.  `require("turtlelib")` and
  `require("fs")` refused, listing what it may have (it worked out T and
  fs itself; the error names them since 0.43.5).

- 2026-11-12 — ROM 0.43.3, the turtle: `mine -3 3 8 --no-lights --new`
  (-3 the width), Ctrl+T, `mine where` the same after a reboot, `mine
  reset` back to the start; `mine 3 3 6 --spacing=4 --new` (homes every
  4); `mow 3 3 notorch` (no torches); `farm --bogus` with no farm (the
  usage); `claude go -5 blocks` (5 back; its Lua in colour).  Not right:
  `mine where` said `mine --resume` carries on, but --resume wants the
  turtle at a home (`mine reset` first; fixed in 0.43.4).

- 2026-11-12 — ROM 0.43.3: `sysctl ccsh.login=yes` refused ("ccsh.login
  is a boolean: not yes", status 1); `sysctl ccsh.login=true` taken.

- 2026-11-12 — ROM 0.43.2: a /startup.lua's output kept on the console
  under init; the wheel scrolls the console's scrollback (ping's output
  waits below while it's open), vi keeps the wheel; Up through the
  history doesn't loop; `> /nodir/f` (no folder made), `> /rom/x`, `>
  /rom` errors; `sysctl -a`, `-n`, `-d`, an unknown name (1), `name=2M`,
  `name=` (not set); ccsh's `set --`, `-x`, `$-`, `-o`, `-f`, `-e` in a
  script (status 1), `-u`.  Not right: `sysctl ccsh.login=yes` was taken
  as the text "yes" (ccnix's settings aren't defined with a type; fixed
  in 0.43.3).

- 2026-11-12 — ROM 0.43.2: irc's hilightwin (a "hilight" buffer with the
  hilight and the kick), autorejoin (kicked, back at once), `/script
  autorun slap` (loaded at the next start), Alt+A to the buffer with
  something new.  `service disable ircd` and a reboot: not running;
  enabled and started again.  The gateway's dialog through the Network
  Configurator (labels in their column, the VLANs box, Done), and
  ccnix's Credits and Authors in the mod list (0.26.0).

- 2026-11-12 — the exchange at 10.1.0.0/24, in game: a router's back.1 is
  10.1.0.2/24 with `default via 10.1.0.1`, and the internet answers
  through it (`host example.com`).

- 2026-11-12 — ROM 0.43.2: `ping -c 1 10.1.2.99 &` then `ip neigh`:
  INCOMPLETE, 1 queued, asked 2 times; gone a moment later (three asks a
  second apart).  Services: a syntax error and a missing command each
  `failed: exit status 1` with the error in the last lines; `kill -TERM`
  of a service's process, `failed: Terminated`, no traceback (each then
  restarting, as services do).

- 2026-11-12 — ROM 0.43.2, the network: `ping -s 65507` to a host across
  the router and to the router (bytes=65507, no note); `ip route get
  example.com` (the address, via, dev, src, the route and the neighbour);
  `ip neigh add` of a wrong MAC with the network down (permanent, pings
  fail), `ip neigh del` (pings back); `nc -zv 10.1.1.10 23` open, and
  telnetd logged nothing for it; `netstat -s` on the router agreeing with
  its screen (forwarded 7791, dropped 0).  `ip neigh` after `ping -w 2`
  of a missing host showed no INCOMPLETE: by then the three asks (a
  second apart) were over; asked again in the background.  Shift+PgUp
  on a router without init: nothing (the scrollback is init's); with
  init.boot on, it works there too.

- 2026-11-12 — ROM 0.43.2 with ccnix-mod 0.26.0 on the client: Esc
  leaves vi's insert mode, Esc then b moves ccsh's cursor a word back,
  Esc then 2 goes to irc's buffer 2, Esc leaves screen's scrollback; the
  same on a turtle and a pocket computer.

- 2026-11-12 — ccnix-mod 0.26.0 on the client (the server at 0.25.1):
  Esc no longer closes a computer's, turtle's or pocket computer's
  screen, and Shift+Esc does; the inventory, a chest and the gateway
  dialog still close on Esc.  Not right (fixed in ccnix 0.43.2): vi
  didn't leave insert mode and ccsh's Esc then b typed a b. The key
  arrived, but CC's keys table has no escape (the game never let it
  through), so nothing knew it as Esc; telnet's Esc had the same gap.

- 2026-11-12 — ROM 0.43.0, vi's commands: `:.,+2>`, `:/beta/;+1d`,
  `:ka`/`:kb` then `:'a,'bm$`, `:s/a/A/` then `:&&` then `&` (E486),
  `:set ts=8 nu? noai invnu`, `:d a 3` and `"ap`, Ctrl+A on `x = -7`,
  `%` from before a bracket, `#` (wrapping, "search hit TOP"), an /.exrc
  with a blank line and CRLF endings.  `vim` on a basic computer is plain
  vi.  Over in-game telnet, vi works (Ctrl+C leaves insert mode, arrows
  move; Esc closes the screen: asked for, in ccnix-mod 0.26.0), and
  Ctrl+C stops a ping on the far side, telnet staying.

- 2026-11-12 — ROM 0.43.0: `ccnix update` (the boot message about
  another ROM gone after the reboot); `git pull /ccnix --only lib/`;
  `curl --bogus` and `git pull --bogus` refused; a Lua page using
  `text.trim` and `fileio.read` with a query (`<p>[bob] 111</p>`); `wc`
  and `sort` on a 10225-line file; `$HOSTNAME` with the label cleared
  (the ID); a 600-character paste in irc sent as two messages split at a
  space; `help ccsh` on a pocket computer; `host example.com` through the
  gateway.

- 2026-11-12 — ROM 0.43.0: `grep -r` (apis/<file> names in order, `-rl`
  from inside without `./`, `-rc` on a folder; a folder without -r: "Is
  a directory").  `strings -n x` and `xargs -s 0` ("bad ..."), `mkdir`,
  `rmdir`, `tee` errors without a path in front; `od -j 0x10 -N 8`; vi
  `:r` of an empty file adds nothing.  irc: `/mode #ccnix +ov Lab-A
  Lab-A` (shown on both), `/ignore *!*@<address>` hides that host's lines
  (a client on the ircd's own computer comes from 127.0.0.1), `/whois`
  idle "1m 12s".  `ip host laba 10.1.1.10`, `ping -c1 laba`, `ip addr`.

- 2026-11-12 — ROM 0.42.3, the smoke test's second round on Lab-B: `ip
  route`, `netstat -r`, `tcpdump -c 4 net 10.0.0.0/8 &` with a ping (4
  packets, then Done), `curl` of httpd's listing (a file named `!` linked
  as `%21`), `ps -l`, `export -p`, `$HOSTNAME`, `telnet` to Lab-A (its
  password prompt), `git log /ccnix -n 3` (dates), `df`, `cat
  /rom/apis/*.lua | grep -c local`, `find / | wc -l` (no "Too long
  without yielding"), `printf "%5.2f|\n" 3.14159`.  Asked for: `grep -r`
  (0.43.0).

- 2026-11-12 — ROM 0.42.3, the text libraries' smoke test on Lab-B:
  `ls *.lua`, `ls [[:upper:]]*`, `find . -name "[[:digit:]]*"`, `case b
  in [a"-"c])` (no), `test` on 20-digit numbers, `expr +5 + 1` (6),
  `printf "%d %x\n" 0x1f 255`, `printf "%x %o %#08X\n" -1 8 255`, `seq -s
  "\t" 3 | od -c`, `tr -d "[:punct:]"`, `cut -d: -f1`, `sort -n`, `head -n
  x` (bad -n x), `sleep +1`, a `for` loop into `wc -l`, `diff -b` (leading
  blanks still differ, as GNU's), `od -d`: all as expected.  `touch -d
  <date>` parses it (CraftOS can't set a file's time, as touch's help
  says); grep has no -r (nor has POSIX's).

- 2026-11-12 — ROM 0.42.3: `/mc tell nobody hi`: "Can't: nobody isn't in
  the game"; a tell with the player's name in another case still told
  them.  irc on an advanced monitor (`monitor scale <side> 0.5`, then
  `monitor <side> irc`): the buffer list and nick list need 5 blocks
  wide (4 is under 80 columns); a tap on a buffer switches to it, a tap on
  a nick puts it in the line; typing goes through the computer.  irc on a
  pocket computer: readable, no time column, Alt+digits switch buffers.

- 2026-11-12 — ROM 0.42.2, the Minecraft bridge on AP 0.8.2a: the game's
  chat comes into #minecraft as `<player> text` (é as itself, in CC's
  small font); #minecraft reaches the game as "[Lab-A] hi"; `/mc tell
  <player> hi` arrives in the game; `/ns verify`'s code is whispered in
  the game, `/ns confirm` takes it, `/whois` says "is the Minecraft player
  <player>"; leaving and joining the game show in #minecraft (with a
  chunk loader keeping Lab-A loaded).  Not right: `/mc tell nobody`
  said "Told nobody." (fixed in 0.42.3).

- 2026-11-12 — ROM 0.42.1: hello.lua's "!ping" answer now shows on the
  sender's own screen too.  The Minecraft bridge on AP 0.8.2a: a Chat Box,
  Player Detector and Environment Detector beside Lab-A, `service restart
  ircd`: its log names all three.  #minecraft from Lab-A reaches the game
  as "[Lab-A] hello".  `/mc players`, `/mc time`, `/mc weather` answer.
  Not right (fixed in 0.42.2): the game's chat came in as `<uuid>
  player`, with the text lost; `/mc tell` and `/ns verify` said sent but
  nothing arrived.

- 2026-11-12 — ROM 0.42.0: `sysctl ircd.oper=...`, `service restart
  ircd`, `/quote OPER x <password>`: "You are now an IRC operator", +o,
  and /kill works.  `help irc-scripts`' hello.lua in /.irc/scripts:
  `/script load hello`, `/hello Lab-A`, `/set hello_word hey`, and
  Lab-A's "!ping" answered "Lab-A: pong" (seen by Lab-A; not shown on the
  sender's own screen: known issues).  A click on a window's label in
  screen's status bar switches to it.  `ps aux` lists as `ps -l`.

- 2026-11-12 — IRC on ROM 0.41.2 (ircd on Lab-A, irc on Lab-B and in
  screen on Lab-A): `/ns register`, back without identifying: Guest1
  after 60 s; back again with `/ns identify`: kept.  `/topic`, `/cs
  register #ccnix`, `/part`, `/join`: the topic kept, ChanServ opped the
  founder.  `/script load slap`, `/slap`.  `service stop ircd`: "Closing
  link ... (Server shutting down)", "Connecting again in 30 seconds",
  `service start ircd`: back in #ccnix.  A screen session started over
  telnet taken up on Lab-A's console with `screen -r`.  OPER refused:
  the password was set as irc.oper, not ircd.oper.  Asked for then: a
  click on screen's status bar to switch, `ps aux` (0.42.0).

- 2026-11-11 — ROM 0.41.2: irc's Tab offers the others before your own
  nick; Ctrl+C b shows a reversed B in the line, bold white in the chat.
  `screen` over telnet (Lab-B into Lab-A): `screen -S work`, a ping in
  window 0, Ctrl+A c and `irc localhost` in 1, Ctrl+A 0/1, the status bar
  (`0-ping 1*irc`), Ctrl+A A to rename, Ctrl+A [ scrollback (q leaves),
  Ctrl+C stopping the ping and not screen, Ctrl+A d ("[detached from
  work]"), `screen -ls` (2 windows, detached), `screen -r`; telnet closed
  with Ctrl+] q, in again, `screen -r`: as it was; Ctrl+A k then y.

- 2026-11-11 — IRC on ROM 0.41.1: `/rom/ccnix/deploy/setup ircd` on Lab-A
  (setup isn't on the path: `ccnix setup` or its full path), reboot:
  ircd running, "listening on port 6667; the game: the clock only".
  `irc 10.1.1.10` from Lab-B: the banner, the welcome and MOTD, `/join
  #ccnix` as @; `irc localhost` on Lab-A's console joined too (seen by
  Lab-B); messages both ways; Lab-B's nick in Lab-A's line hilighted
  (yellow behind the nick); the wheel, PgUp/PgDn, Alt+number, Tab on a
  nick; `/quit` seen by the other as a quit with its message.  Seen then:
  Tab offered your own nick first; Ctrl+C b showed as the font's smiley
  and bold didn't show in the chat (0.41.2).

- 2026-11-11 — CraftOS's startup after ccnix on a plain (basic) Computer
  under init (ROM 0.41.1, `init.boot`, `ccsh.login`, `motd.enable` on):
  the tip of the day, then `/startup.lua`'s and `/startup/a`'s output
  (their errors: they were written from CraftOS's shell, whose quoting
  knows only `"`), above the ccsh prompt and kept; `ps` (init, ccsh) and
  Shift+Page Up's scrollback.

- 2026-11-11 — ROM 0.41.1: PrintScreen in init's scrollback leaves it
  where it is; claude's ping through run_program ran as `ping -c 4` and
  ended; a turtle's modem taken off and put back (`turtle.equipLeft()`
  twice) and `ping` worked with no `ip up`.

- 2026-11-11 — claude on ROM 0.41.0: "×" shown as itself, a web search
  after it in the same session with no error, its code steps shown as
  `--- code execution`; the network set up through run_program `ip`
  (addr del/add, boot) and checked with ping (which ran until stopped:
  -c 4 added since 0.41.1).

- 2026-11-11 — claude on ROM 0.40.3 (a turtle with a wireless modem and a
  chunk controller): `claude fetch https://example.com and tell me its
  title` (CC's http, "Example Domain"); httpc to Lab-B's httpd at
  10.1.2.10 over the CC network; its status (equipped, attached, the
  network's address); `mine 3 3 5 --here` through run_program after the
  person gave it chests (it swapped the modem for the pickaxe and back),
  `where are you` agreeing; memory (notes in /claude/memories/notes.md,
  looked at first); a web search for the mining turtle's recipe; ores
  around it by name, sorted (Geo Scanner); notes written under /claude/,
  claude.key unreadable every way it tried.  Seen then: it couldn't set
  the network up (no settings; ip through run_program since 0.41.0); "×"
  shown as "Ã" and a block, and once an "Invalid signature in thinking
  block" error after a web search (UTF-8 sent back wrong, fixed in
  0.41.0).

- 2026-11-11 — The network on ROM 0.40.3 (Lab-B): `ip host gone <addr>`,
  `ping gone`, `ip host del gone` (gone from the list, "Name or service
  not known"), and again: "no host gone", status 1.  `ip neigh add` of the
  router's address: `permanent`, no who-has from Lab-B for it while
  pinging past it (the router's own who-has for Lab-B seen), kept over `ip
  down`/`ip up` and a reboot.  `ip dns cache` listing an NXDOMAIN, `ip dns
  flush`, then `host -v` "Received from".  `ping -c 0 -q` quiet until
  Ctrl+C, then the summary (-c 0 is no limit, as in BSD's ping); Ctrl+T on
  a `ping &` brought back with `fg`; `nc -w 3` to a host that's down gives
  up after 3 s.

- 2026-11-11 — ccsh on ROM 0.40.3: Ctrl+C stops `ping` and `tail -f`, and
  at a `>` prompt drops the command; `paint` keeps Ctrl+C; `kill -0 $$`
  gives 0; `(echo $$)`, `echo $$ &` and `echo $$` the same pid; `&>` then
  `&>>` into a file; `${U:=x}`, `${PS1:+set}`, `${NOPE:?gone}` (the message,
  the rest of the line skipped, `$?` 1); a two-row PS1 whole after a
  background `ping`'s output, with what was typed kept; `unset PS1` back
  to the default.

- 2026-11-11 — ROM 0.40.3: a #! typed into a new file colours it as ccsh
  at once, the `)` of a `$(` light blue, `1` after `x=` magenta.  The ccsh
  line editor: Ctrl+B/F, Home/End and the arrows, Alt+B/F/D and
  Alt+Backspace (the game sends Alt), Ctrl+K, Ctrl+D, Ctrl+P/N; Ctrl+R
  and again for an older match, Ctrl+G or an arrow to leave; the grey
  completion on a colour computer; a long line scrolling sideways on a
  turtle; a two-row PS1 (`\h\n\$ `) whole after Ctrl+L.

- 2026-11-11 — vi and vim on ROM 0.40.2: on a pocket computer and a
  turtle `-- INSERT --` and `-- REPLACE --` whole beside the ruler, and the
  Ctrl+C hint fits; `vim` on lib/vi.lua (2,041 lines) coloured and not
  slow, `G` and the wheel; `:set hls` and `/x` with search wrapping;
  `:2,3d`, `u`, `:g!/keep/d`, `:%s#a#X#g`; Ctrl+A on X1, `~`, `*`. Esc
  closes the computer's screen, as CC does: Ctrl+C or Ctrl+[ leave insert
  mode. Seen then, fixed in 0.40.3: a #! typed into a new file with no
  extension coloured as Lua until it was saved and opened again.

- 2026-11-11 — vi on ROM 0.40.1: Ctrl+A on a number, `yyp`, `dd`, `p`,
  `.` repeating Ctrl+A, `:%s/x/y/g` ("2 substitutions on 2 lines"), the
  mouse wheel, a click moving the cursor, Ctrl+V pasting; Ctrl+C on a `:`
  line drops it, and on a saved file says "Type :q and Enter to exit".
  Seen then, fixed in 0.40.2: on a pocket computer `-- INSERT --` cut to
  `-- INSERT`, the `i` that started insert mode still shown.

- 2026-11-11 — The mod on 0.25.1: walking with the gateway dialog open
  (W/A/S/D with no box focused), closing it by walking off, typing in a
  box doesn't move, a click off the box walks again; the keys as ever
  after it closes; no ccnix clash in Controls (the red ones there are
  another mod's rail keys).

- 2026-11-11 — The mod on 0.25.0, ROM 0.40.1: the mod list's author "Dan
  Theisen [WI7FI]"; the cable network dialog on a short network (2 cables,
  2 modems, the computers beside them with their labels, the empty
  "Shared on it" note) and on the 198-cable run (the amber unloaded chunk,
  the tooltips); typing W in the gateway dialog's boxes.  Under ccsh,
  `textutils.pagedTabulate({"a"}, {"b"})` in `lua` with no error, and
  CraftOS's `help index`.  Walking with a dialog open didn't (0.25.1).

- 2026-11-11 — The mod on 0.23.0, ROM 0.40.0: the mod list's description
  (NAT and TUN) and credits (the inspirations); the gateway dialog laid
  out right (the label column, Gateway, Mode, Untagged, Exchange, Standing
  by), its tooltips, the native VLAN saved ("Saved"), the cursor left
  where it was in a box across refreshes; the configurator on a cable
  listing 198 cables and the unloaded chunk it ran into (in chat then: a
  dialog since 0.25.0); `help git` in the pager with its trademark note,
  and after q its command line still in the scrollback; `help index` in columns, `help gi<Tab>` completing.

- 2026-11-11 — The mod, on 0.22.2: the mod list's Credits (CC: Tweaked,
  Daniel Ratcliffe, NeoForge, etlua); the Network Tester's recipe (iron,
  glass pane, iron / iron, redstone, iron / cable); empty-handed on a
  gateway the action bar asks for the tester; with it, the dialog: green
  Working on the working block, amber Standing by on the spare, frame
  counts climbing with their rates while `ping` ran, the MACs heard on
  the pointer; what's typed in the VLANs box kept across refreshes.  Seen
  then, fixed in 0.23.0: a label running into its value, values cut
  short, the refresh moving the box's cursor.  `help git` and `help
  tcpdump` shown; the prompt that ran `help git` was missing from the
  scrollback (CraftOS's help viewer draws over the screen): ccnix 0.40.0.

- 2026-11-11 — Fileserver on ROM 0.39.0 (FS, 4 disks pooled at `/jbod`):
  Tab completion of `/jbod`, its files and `..` in ccsh and in CraftOS's
  own shell; each pooled disk labelled `FS drive_N`.

- 2026-11-11 — `/ccnix rom update` asks before the reload (ccnix-mod
  0.22.2): it pulled, offered [Load it], and loading brought the server's
  ROM to 0.39.0.
- 2026-11-11 — A disk's startup in place of the computer's (ROM 0.39.0,
  Lab-B, `shell.allow_disk_startup` on): "from the disk" alone, the
  computer's `/startup.lua` skipped, under init with ccsh and under
  stock CraftOS alike.  The first try looked like a failure: a plain
  `/disk` folder on the computer (left by the `>` bug before 0.33.0) had
  pushed the floppy's mount to `/disk2`, so the file was never on it.

- 2026-11-11 — CraftOS's startup after ccnix, under init (ROM 0.39.0,
  Lab-B, `init.boot` and `ccsh.login` on), test 5's third try: `/startup.lua`
  then `startup/a` and `startup/b` printed above the ccsh prompt and stayed
  there (0.30.0 had drawn them over blank); with `motd.enable` on, the
  tip of the day before them.  `/ccnix rom update` and [Load it] brought
  the server's ROM to 0.39.0 (mod 0.22.2 on the client and the server).

- 2026-11-06 — Background output while typing (0.30.0, by `ccnix update`
  on Lab-A): `ping -c 5 10.0.0.1 &`, then commands typed while replies
  came: each reply took the prompt's place, the prompt and the typed line
  came back below, nothing jumbled; the job's Done reported before the
  next prompt.
- 2026-11-06 — Network diagnostics on Lab-A (ROM 0.29.1): `ping` running
  until Ctrl+T then its summary with rtt min/avg/max/mdev, `-c 3 -q`, `-w
  2` stopping on time, `-s 1000` through R and the TUN gateway
  (bytes=1000); `ip route get` through the router (via, dev, src, the
  router's MAC and seconds left) and for its own address (local, dev lo);
  `ip neigh` showing an unanswered address as INCOMPLETE, 1 queued, asked
  2 times; `netstat -s` grouped by protocol; `host -v` twice (from
  4.2.2.1#53, then from the cache with the TTL counting down), `ip dns
  cache` and `ip dns flush`; `nc -z -v` refused, open and timed out.
- 2026-11-06 — Backspace at the start of the line and on an empty one
  (0.29.2, by `ccnix update`): no more doubled or jumbled lines.
- 2026-11-06 — Services under init (ROM 0.29.1): a crashing service
  (`error('boom')`) shown as failed with its error, status 1 and a
  traceback in `service status` and `/var/log/messages`, restarting with a
  doubling wait (16 s, 32 s); `kill -9` of telnetd: its port 23 freed and
  bound again by the new process, the open session from Lab-B closed. It
  found the Backspace bug fixed in 0.29.2.
- 2026-11-06 — ccsh on the dev server (ROM 0.29.1, under init): the line
  editor's Ctrl+A/E, Ctrl+W, Ctrl+U then Ctrl+Y; Ctrl+R finding an old
  command; Tab completing a file name; Ctrl+L; Ctrl+C at the prompt (^C,
  `$?` 130), on `sleep 30` (stopped, 130) and left to `lua` (still open);
  Ctrl+D leaving a nested ccsh; `$$` and `$PPID` matching `ps -l` (4 and
  1); `cat nope &> /tmp/e` filing the error with no job started;
  `${U:-$X}`; `unset -f`.
- 2026-11-06 — On the dev server with ROM 0.29.1: `vi` (i, Ctrl+[, `yyp`,
  `u` and a tapped Ctrl+R, Ctrl+C leaving insert mode and in normal mode
  giving the ":wq / :q!" hint without quitting, `:wq`); `vim` on
  bin/ls.lua with Lua colours (keywords, strings, comments, numbers,
  library names, fields plain), `:set nu`, `/local` and `n`; `nano` opening
  CraftOS's edit, and Ctrl+C in it leaving edit open with the text kept.
- 2026-11-06 — `mine where` (0.23.0): last home, next home and the reset
  line shown, while mine ran as a service.
- 2026-11-06 — mine as a service under init (0.21.0): started at boot,
  logged to `/var/log/messages`, `service stop` / `service start` resumed it.
- 2026-11-06 — Going back over just where water was (0.21.5): fixed a leak
  through the far wall on a long walk out.
- 2026-11-06 — Lava pouring in from above sealed round while digging.
