# Untested in game

What's built and passes the sims but hasn't been tried in a real game yet.
A scenario goes in when the change ships, and moves to **Tested** (with the
date and what happened) once someone has run it. Newest first in each
section.

## claude: http, the network, programs, memory, the web, the rest (0.39.0)

- **status after Ctrl+T in `mine`**: the `mine` job under way shows.
  Ctrl+T while `mine` runs stops claude too, the position saved.
- **A long session** (60k+ tokens): `claude.log` should show "context: N
  old tool results cleared" and the session should carry on sensibly.

## claude: ccnix's libraries in its code, the rest (0.38.0)

- With a chat box attached, `claude say hello in the chat` (mc.say).
  `require("turtlelib")` and `require("fs")` are still refused, naming
  what it may have.

## Everything: the text libraries (0.37.0)

- **A regression pass, the second.** Every program now uses lib/scan,
  lib/text, lib/convert, lib/getopt, lib/glob and lib/path rather than a
  copy of its own (the turtle programs, git and setup too). Sims pass and
  each swap was run against the old code on edge cases (about two million
  of them), but none of it has run in game. The same quick pass as below,
  plus:
  - **setup run alone, on a stock CC: Tweaked computer** (no mod): `wget
    run .../deploy/setup.lua`. It now fetches lib/scan, text, convert,
    path and getopt into memory before git. Then `ccnix update`, then
    `ccnix setup` once on an install made before this: that adds the text
    libraries to a checkout that was cloned with `--only` paths.
  - **git:** `git pull /ccnix --only lib/` (options after operands), `git
    log` (the dates, now read by convert.fromDateTime).
  - **globs:** `ls *.lua`, `ls [[:upper:]]*`, `case b in [a"-"c])` (a
    quoted `-` in a bracket is now itself: no match), `find . -name
    "[[:digit:]]*"`, an IRC `/ignore *!*@host`.
  - **numbers:** `test 99999999999999999999 -gt 99999999999999999998`,
    `expr +5 + 1` (now 6), `sleep +1`, `printf "%d %x\n" 0x1f 255`, `seq -s
    "\t" 3`, `tr -d "[:punct:]"`, `touch -d "2026-01-02 03:04:05+02:00" f`.
  - **text:** `diff -b` on lines with leading blanks, the pager wrapping a
    long coloured line (`vim` on a long line, `help` in a narrow window),
    a long IRC message split in two (now at the last space that fits, with
    the rest's spacing kept), the irc nick list and buffer list columns.
  - **the second pass (one implementation per job):** `mine -3 3 32` and
    `mine --spacing=4`, `farm`, `mow notorch`, `claude go -5 blocks` (the
    turtles' options now go through lib/getopt); claude's Lua in lib/syntax's
    colours; `ccnix setup --autostart=router`; `ps -l` and a panic report
    (one row layout); `export -p`, `$HOSTNAME` on an unlabelled computer
    (the ID); telnetd's banner; `ip route`, `netstat -r`, `tcpdump net
    10.0.0.0/8` (lib/net's prefix math); an IRC `MODE #c +ov a b` both
    ways; vi `:r` of an empty file (adds nothing, as vim); a Lua page
    using `text` and `fileio`; jbod on the fileserver (reads through the
    disk under the pool).
  - **coreutils, second pass:** a long `sort`, `grep -r`, `find /` and
    `wc` on a big file don't get "Too long without yielding" (cu.breathe
    now yields once a second); `od -j 0x10 -N 8` and `od -d`; `printf "%x
    %o %#08X\n" -1 8 255`; `touch` a file; `df` (its columns);
    `mkdir`/`rmdir`/`tee` errors without the path in front.
  - **behaviour that changed on purpose:** WHOIS idle reads "5m 3s";
    `head -n x`, `uniq -f x`, `strings -n x`, `xargs -s 0` say "bad -n x"
    (and so on);
    curl and git refuse an unknown or misused `--option`; httpd listing
    links percent-encode `!$&'()*+,;=:@`; a syslog line's trailing blanks
    are dropped.

## Everything: parsing without patterns (0.36.1)

- **A regression pass.** Every program's parsing moved from Lua patterns
  to lib/scan (or, for git, setup, boot and the turtle programs, small
  helpers of their own). The sims pass and each part was compared with
  the old code on edge cases, but nothing has run in game. Worth a
  quick pass: a ccsh line with a pipe, quotes, globs (`ls *.lua`,
  `[a-c]*`), `$(...)` and a `for` loop; `ip addr`, `ip route`, `ping`
  a name, `host`; `curl` a page from httpd (a Lua page, a query); `git
  pull` / `ccnix update`; a syslog line in /var/log; `sort -n`, `cut
  -d: -f1`, `printf "%5.2f\n" 3.14159`, `seq 1 3`, `find . -name
  "*.lua"`; `telnet` in (keys, mouse, paste); a farm or mine run
  (tool names, its saved job read back after a reboot); setup's
  migration from an old /cc-turtles, if one is left anywhere.

## Editors

- **Ctrl+C in `vi`, the rest** (0.29.1). Over telnet Ctrl+C does the
  same.

- **vi and vim parse with lib/scan, the rest** (0.27.1, no change
  meant). `vim` on a ccsh script: quotes over several lines, comments
  after `;`. Ex commands: `:.,+2>`, `:/pat/;+1d`, `:'a,'bm$`, `:s/x/y/`
  then `:&&` and `&`, `:set ts=8 nu? noai invnu`, `:d a 3`, `:ka`, and an
  /.exrc with blank lines and a CRLF ending. Normal mode: `#` on a word,
  `*` from just before one, Ctrl+A on `x = -7`, `%` from before a
  bracket.

- **`vim`, the rest** (0.25.0). On a basic computer it's plain vi.
- **`vi` over telnet** (0.25.0). The client's Esc key leaves insert mode
  (lib/telnet now sends a lone Esc as the Esc key); arrows and Ctrl
  keys work.

## ccsh

- **Background output while typing, the rest** (0.30.0). A full-screen
  program in the background isn't disturbed; the same over telnet.
- **Ctrl+C left to programs that use it, the rest** (0.29.1). In `telnet
  <host>` Ctrl+C reaches the far side's program (a `ping` there stops), not
  the local telnet; all of it again on a computer without init.
- **The line editor, the rest** (0.28.0, lib/readline). `read x` at the
  keyboard has the same keys; Ctrl+C there stops the rest of the line.
- **Tab and long lines, the rest** (0.28.0): the completion in grey on a
  basic computer; Up/Down cycle the suggestions. A coloured prompt redraws
  correctly after Ctrl+L. AltGr (Ctrl+Alt) characters on a non-US layout
  type normally and trigger no bindings.
- **Ctrl+C, the rest** (0.28.0): a computer without init; under init it doesn't reach
  ccsh itself when ccsh was started from ccsh. In telnet under init,
  Ctrl+C goes to the remote side and the local telnet keeps running.
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

- **A crashing service, the rest** (0.26.0). A syntax error or a missing
  command ends `failed: exit status 1`; Ctrl+T or `kill -TERM` from outside
  `service stop` shows `failed: Terminated` with no traceback.
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
  NAT mode (the gateway's own address) and in TUN mode (a real host):
  replies show bytes=N with no "(sent ...)" or "changed" note.
- **`ip route get` and `ip neigh`, the rest** (0.29.0). `ip route get` for
  a name; the INCOMPLETE entry gone about 3 s after the last try.
- **`netstat -s` on a router** (0.29.0) after some forwarding and a forged
  source: drops by reason, and the router screen's forwarded/dropped/spoofed
  agreeing with it.
- **`nc`, the rest** (0.29.0). The far side's telnetd shows no error for
  the empty connection `nc -z` makes.

- **`ip neigh add` / `ip neigh del`, the rest** (ccnix 0.24.0). Added
  with the network down; a wrong MAC breaks pings to that host; `ip neigh
  del <addr>` brings ARP back; `dev <iface>` for an address off every
  interface's network.
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

- **0.33.0, from test 5's second try:** init copies the screen before
  making its console window (0.30.1 made the window first, which drew it
  blank, so the startup files' output was still lost).  Retry 5.1-5.4.
- **The mouse wheel scrolls the console's scrollback** (0.33.0), at the
  prompt and under programs that don't scroll with it (ping, cat); vi,
  vim, more, git log and edit/nano keep the wheel; the wheel down at the
  live screen still reaches the program.
- **Up through the history doesn't loop** (0.33.0): a recalled line shows
  no grey completion, so Up goes on back.
- **`> /disk/f` with no disk in** (0.33.0): `ccsh: /disk/f: No such file
  or directory`, status 1, and no `/disk` folder made (CC's fs.open makes
  folders; 0.32.0 and before made one).  `> /rom/x`: Read-only file
  system; `> /rom`: Is a directory.

- **`sysctl`** (0.32.0): `sysctl -a`, `sysctl name`, `-n`, `-d`, an unknown
  name (status 1); `sysctl name=value` (a boolean setting refusing `yes`),
  `sysctl name=` back to its default, kept across a reboot; `help sysctl`.
- **ccsh's `set`** (0.32.0, POSIX's): `set` lists the variables; `set --
  a b` then `echo $1 $2`; `set -x`, `set -e` in a script, `set -u`, `set
  -f`, `set -o`, `echo $-`.  CraftOS's `set` is still there outside ccsh.

- **`ccnix update` on many computers at once** (0.30.2): GitHub answered
  some with 504; git now tries a 5xx again after 2, 4 and 8 s.  If the
  API's hourly limit for the server's address runs out, it says until when.

- **`wget run …/deploy/setup.lua` on a bare old install** (0.20.0): a
  computer that still has only `/cc-turtles` (from before ccnix): moved to
  `/ccnix`, pointed at the ccnix repo, pulled, old startup lines swapped.
  (`git pull` then `deploy/setup` on such a turtle worked.)
- **`ccnix setup` on a server with the ccnix mod** (0.20.0): settings and
  apps chosen through the ROM's setup.
- **`syslog.maxSize` with K/M** (0.21.0): `set syslog.maxSize 2M`, and a log
  rotating at that size.

## screen

- **screen over telnet** (0.36.0). On A with init: `telnet A` from B,
  `screen -S work`, then `ping 10.1.0.1` (it runs on). Ctrl+A c, `irc
  ...`; Ctrl+A 0 and 1 go back and forth; the status bar shows
  `0-ping  1*irc` style titles. Ctrl+A d: "[detached from work]". `screen
  -ls`: work, 2 windows, detached. `screen -r`: both windows as they were.
- **A dropped connection** (0.36.0). Inside screen on a telnet session,
  close B's telnet (Ctrl+] q, or break the cable). Telnet in again:
  `screen -ls` shows work detached (or attached until the hangup lands:
  `screen -d -r work` takes it), and `screen -r` brings it back with the
  programs still running.
- **The rest of screen** (0.36.0). Ctrl+A A names a window; Ctrl+A k then
  y kills one; Ctrl+A [ and Shift+PgUp scroll back through a window's
  past; Ctrl+A a gives ccsh its Ctrl+A; Ctrl+C stops a ping in a window
  (not screen); `screen -x` from the console while B has it: both
  show it, both type into it; a different-sized screen resizes the
  windows. `sysctl screen.prefix=b`, then Ctrl+B is the key.

## IRC

- **ircd as a service** (0.35.0). On A: `setup ircd`, reboot: `service`
  shows ircd running, `service status ircd` its "listening on port 6667;
  the game: ..." line (what it found: chat box, players, weather).
  `service stop ircd` with a client connected: the client sees "Server
  shutting down". `service disable ircd`, reboot: not running.
  `sysctl ircd.oper=pw`, `service restart ircd`, then `/quote OPER x pw`
  from a client gives +o.
- **irc against ircd, two computers** (0.35.0). B: `irc 10.1.1.6` (A's
  address). The banner, then the server buffer (2) with the welcome and
  MOTD. `/join #ccnix`: you're @, the buffer switches. C does the same:
  B sees C join; messages both ways, B's nick in C's line hilights it
  (yellow behind the nick, Act in the status bar, a speaker's chime if
  one is attached). Alt+1/2/3, Ctrl+N/P, Alt+A, PgUp/PgDn, the wheel,
  Tab on a nick, Ctrl+C b for bold. `/quit`: the shell comes back clean.
- **irc on a monitor or a wide screen** (0.35.0). On a computer with an
  80-column monitor redirected (`monitor right irc ...`, or a big
  advanced monitor): the buffer list on the left, the nick list on the
  right; a click on a buffer goes there. A pocket computer: no time,
  shorter nick column, still readable.
- **NickServ and ChanServ** (0.35.0). `/ns register pw`, `/quit`, back
  as the same nick without identifying: after 60 s you're Guest1. Back
  again, `/ns identify pw`: kept. `/cs register #ccnix` (while @), all
  leave, rejoin: the topic's kept and the founder is opped by ChanServ.
- **The Minecraft bridge** (0.35.0). An Advanced Peripherals Chat Box
  beside A (and a Player Detector): `/join #minecraft` from B, say
  something: it shows in the game's chat as [nick] text. Say something
  in the game: it comes into #minecraft as <player> text; a player
  joining or leaving the game shows too. `/mc players`, `/mc time`,
  `/mc weather` (with an Environment Detector), `/mc tell <player> hi`
  (a whisper). `/ns verify <your player>`: a code is whispered to you
  in the game; `/ns confirm <code>`, then `/whois` shows "is the
  Minecraft player ...". Untried: which of AP 0.8's ways of calling the
  chat box answers (the options table or the old arguments), and the
  event names for join and leave (both are listened for).
- **A real client and server through the gateway** (0.35.0). From the
  VM: `irssi -c 10.1.1.6 -n vm`, /join #minecraft, talk with B. From B,
  with the network reaching out: `irc irc.libera.chat` (plain 6667),
  /join a channel; `/set network.<name>.sasl_user` and `sasl_pass` for
  SASL.
- **Scripts** (0.35.0). `/script list`; `/script load slap`, `/slap bob`;
  `/script load hilightwin` (a hilight buffer gathers hilights);
  `/script load autorejoin`, get kicked: back in 3 s; a script of your
  own in /.irc/scripts (`help irc-scripts`' hello example);
  `/script autorun slap`, restart irc: loaded at the start.
- **Reconnecting** (0.35.0). Stop ircd while B is in channels: B says
  disconnected and counts 30 s; start ircd: B is back in its channels.
- **readline's editor** (0.35.0): ccsh's prompt is unchanged (Ctrl+A/E,
  Ctrl+R, Tab completion, history), since read() is now built on it.

## The mod

- **The Network Configurator** (ccnix-mod 0.23.0; it was the Network
  Tester). An old Network Tester in an inventory is a Network Configurator
  after the update. On a gateway, the dialog's labels fit their column
  ("From other blocks" no longer runs into its value), long values wrap
  instead of being cut, and the rows say one thing each: Gateway (the
  address), Mode (TUN or NAT), Untagged, Exchange (untagged, or tagged as
  back.1), Standing by. Click into the VLANs box and type slowly: the
  refresh each second no longer moves the cursor. Escape, Done, or the
  block broken closes it.

- **The exchange at 10.1.0.0/24** (ccnix-mod 0.18.0). The gateway's default
  address is 10.1.0.1/24, inside the CC networks (10.1.0.0/16), so one LAN
  route reaches every CC computer. On the dev server, after redeploying:
  `ip -br addr show ccnix0` on the host shows 10.1.0.1/24 alone (the old
  10.0.0.1 gone); routers' back addresses moved to 10.1.0.x with `default
  via 10.1.0.1`; `/ccnix route add 10.1.0.0/16 via 10.1.0.2` is accepted
  (a route around the exchange) and `10.1.0.0/25 via 10.1.0.2` refused;
  a computer straight on the exchange (no router) reaches the internet.

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
