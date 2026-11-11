# Untested in game

What's built and passes the sims but hasn't been tried in a real game yet.
A scenario goes in when the change ships, and moves to **Tested** (with the
date and what happened) once someone has run it. Newest first in each
section.

## Paged output under ccsh (0.40.1)

- **CraftOS programs that page their output** (`textutils.pagedPrint` and
  `pagedTabulate`: CraftOS's own `help index` did, ccnix's doesn't now)
  failed under ccsh with "Redirect object is missing method getSize": the
  terminal ccsh gives a command had its methods only through a metatable,
  and pagedPrint copies it with pairs().  Try `lua` then
  `textutils.pagedTabulate({"a"}, {"b"})` and `textutils.pagedPrint(("x
"):rep(40))`:
  "Press any key to continue" and no error.

## claude: http, the network, programs, memory, the web (0.39.0)

- **http in the code**, preferred over ccnix's stack: `claude fetch
  https://example.com and tell me its title` (CC's http.get; the host must
  be in `http.rules`). With `ip up` on a networked turtle, `claude get
  http://<a 10.x host>/ with httpc` and `claude what's my address`
  (`status` shows the network's addresses).
- **run_program:** `claude read mine's manual, then mine a 3 by 3 tunnel
  10 long here` (it should pass `--here`, the output should come back, and
  `claude where are you` afterwards should agree with `.turtlepos`).
  Ctrl+T while `mine` runs should stop claude too, the position saved.
- **memory:** `claude remember that the fuel chest is behind the start`,
  quit, run `claude where's the fuel?` (it should look in its memory
  first). The notes are in `/claude/memories/`.
- **web search and fetch:** `claude look up the crafting recipe for a
  mining turtle` (shown as `--- web search: ...`; the answer may quote its
  source). Needs web search turned on for the API key's organization.
- **status:** the equipped tools, attached peripherals, the label, and a
  `mine` job under way after Ctrl+T in `mine`.
- **A long session** (60k+ tokens): `claude.log` should show "context: N
  old tool results cleared" and the session should carry on sensibly.

## claude: ccnix's libraries in its code (0.38.0)

- **The code's `require` loads ccnix's libraries:** text, scan, convert,
  path, glob, regex, tables, fileio, getopt and mc, beside the cc.*
  modules, and the system prompt lists what's in them (and more of
  turtlelib: goHome, dumpDown, the chest helpers, the mine job). Try
  `claude list the ores around you by name, sorted` (it should reach for
  glob.match and tables.sortedKeys), `claude keep notes in
  /claude/notes.txt` (fileio.write there works; anywhere else, and a read
  of claude.key, give nil and why), and, with a chat box attached, `claude
  say hello in the chat` (mc.say). `require("turtlelib")` and
  `require("fs")` are still refused, naming what it may have.

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

- **Ctrl+C in `vi`, the rest** (0.29.1). On a `:` line it drops the line;
  on a saved file the hint says "Type :q and Enter to exit"; the hint fits
  on a turtle (39 columns); over telnet Ctrl+C does the same.

- **vi and vim parse with lib/scan** (0.27.1, no change meant). `vim` on a
  big Lua file (lib/vi.lua, about 2,000 lines): `G`, then scroll back up;
  the colours look as before (keywords, strings, `--[[ ]]` comments, `0x1F`
  and `1e-3` numbers, `string.format` with the field plain) and it doesn't
  feel slower (the colourer now builds a small scanner per line). `vim` on
  a ccsh script: `$x`, `${x}`, `$(`, `NAME=value`, comments after `;`,
  quotes over several lines. Ex commands: `:2,4d`, `:.,+2>`, `:/pat/;+1d`,
  `:'a,'bm$`, `:%s#a/b#X#g`, `:s/x/y/` then `:&&` and `&`, `:g!/keep/d`,
  `:set ts=8 nu? noai invnu`, `:d a 3`, `:ka`, and an /.exrc with blank
  lines and a CRLF ending. Normal mode: `*` and `#` on a word and from just
  before one, Ctrl+A on `x = -7`, `~` over mixed case, `%` from before a
  bracket.

- **`vi`, the rest** (0.25.0). Ctrl+A adds one to a number; `dd`, `p`,
  `.`, `:%s/a/b/g` behave as in vi. Mouse wheel scrolls, a click moves
  the cursor, Ctrl+V pastes. On a turtle (39 columns) and a pocket
  computer (26) the bottom line still fits.
- **`vim`, the rest** (0.25.0). A ccsh script with `#!/ccnix/bin/ccsh`
  gets the shell's colours; on a basic computer it's plain vi; `:set
  hls`.
- **`vi` over telnet** (0.25.0). The client's Esc key leaves insert mode
  (lib/telnet now sends a lone Esc as the Esc key); arrows and Ctrl
  keys work.

## ccsh

- **Background output while typing, the rest** (0.30.0). A two-row PS1
  (`PS1='\h\n\$ '`) comes back whole; a full-screen program in the
  background isn't disturbed; the same over telnet.
- **Ctrl+C left to programs that use it, the rest** (0.29.1). `paint x`
  keeps Ctrl+C; in `telnet <host>` Ctrl+C reaches the far side's program
  (a `ping` there stops), not the local telnet; `ping <host>` and `tail -f`
  stop on Ctrl+C; all of it again on a computer without init.
- **The line editor, the rest** (0.28.0, lib/readline). Ctrl+B/F, Home/End
  and the arrows; Alt+B/F/D and Alt+Backspace (first check that the game
  sends Alt key events at all); Ctrl+K; Ctrl+P/N and Up/Down; Ctrl+D
  deleting on a line with text. `read x` at the keyboard has the same
  keys; Ctrl+C there stops the rest of the line.
- **Ctrl+R, the rest** (0.28.0): tap it again for an older match; Ctrl+G
  or an arrow to leave the search.
- **Tab and long lines** (0.28.0): the completion shows in grey after the
  cursor on a colour computer and on a basic one; Up/Down cycle the
  suggestions. A line longer than the screen scrolls sideways on a turtle
  (39 wide) and a computer (51 wide). PS1 with `\n`, and a coloured
  prompt, redraw correctly after Ctrl+L. AltGr (Ctrl+Alt) characters on a
  non-US layout type normally and trigger no bindings.
- **Ctrl+C, the rest** (0.28.0): at a `>` continuation prompt it drops the
  whole command; a computer without init; under init it doesn't reach
  ccsh itself when ccsh was started from ccsh. In telnet under init,
  Ctrl+C goes to the remote side and the local telnet keeps running.
- **The editor over telnetd** (0.28.0): the same keys from a real terminal
  client (PuTTY, xterm); Alt+B/F arrive as Esc+letter; Ctrl+C at the remote
  prompt drops the line.
- **`$$`, the rest** (0.27.0). `kill -0 $$` succeeds; `(echo $$)` and `echo
  $$ &` print the same pid. Without init (plain CraftOS), `$$` is the
  computer ID and `$PPID` empty.
- **`&>>` and the other `${...}` forms** (0.27.0). `echo x &>> f`
  appends; a stock program's printError output lands in f with `&>`.
  `echo ${U:=x}; echo $U`, `echo ${PS1:+set}`, `echo ${U:?gone}`: at the
  prompt the last prints `ccsh: U: gone`, skips the rest of the line and
  gives `$?` 1; in a script it ends the script with status 1. Plain
  `unset f` leaves a function.

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

- **`ip host del`** (0.34.0). `ip host gone 10.1.2.9`, `ping gone` (the
  address), `ip host del gone`: the list leaves it out, `ping gone` can't
  find it, and `ip host del gone` again says "no host gone" with status 1.
  Deleting the last one leaves `sysctl net.hosts` unset.

- **ping, the rest** (0.29.0). Ctrl+T on a `ping` running inside a
  background job brought to the front (`fg`); `ping -c 0 -q`; `ping -s
  65507` through the gateway, in NAT mode (the gateway's own address) and
  in TUN mode (a real host): replies show bytes=N with no "(sent ...)" or
  "changed" note.
- **`ip route get` and `ip neigh`, the rest** (0.29.0). `ip route get` for
  a name; the INCOMPLETE entry gone about 3 s after the last try.
- **`netstat -s` on a router** (0.29.0) after some forwarding and a forged
  source: drops by reason, and the router screen's forwarded/dropped/spoofed
  agreeing with it.
- **The DNS cache, the rest** (0.29.0). An NXDOMAIN listed in `ip dns
  cache`; after `ip dns flush`, the next `host -v` says "Received from".
- **`nc`, the rest** (0.29.0). The far side's telnetd shows no error for
  the empty connection `nc -z` makes; `nc -w 3 <host> 23` (no `-z`) to a
  host that's down gives up after 3 s.

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

- **CraftOS's startup after ccnix on a plain Computer** with `init.boot`
  (0.30.1: boot draws in a window first, so init has something to copy):
  the startup files' output and the MOTD above the prompt.

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
- **Walking with the dialog open** (ccnix-mod 0.24.0, the client's jar):
  with no box focused, W/A/S/D, jump, sneak and sprint move the player
  (the view stays still: the mouse is the dialog's); walking 8 blocks off
  closes it. Clicking into a box stops that (typing W types W); clicking
  anywhere else (the panel, a label, a button) leaves the box and walking
  works again. Space with nothing focused jumps, and presses no button.
- **The cable network dialog** (ccnix-mod 0.25.0; 0.23.0 said it in
  chat). Right-click a CC cable or wired modem with the configurator: a
  dialog like the gateway's, with Cables, Modems and Gateway blocks; a
  "Shared on it" section (each peripheral by the name computers use, its
  type, the block and where; the pointer says `peripheral.wrap("...")`);
  "Beside its modems, not shared" (computers using a modem, with their
  labels); and, in amber, "Into chunks that aren't loaded" (each chunk and
  the cable that runs into it). A network with many peripherals scrolls
  with the wheel (a bar at the right). You can walk while it's open; it
  closes 8 blocks away, or when the clicked cable goes. Client and server
  both need 0.25.0 (a new packet): an older one is refused.
- **The mod list's author** (ccnix-mod 0.25.0): "Dan Theisen [WI7FI]".

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

## Tested

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
