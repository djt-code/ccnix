# Untested in game

What's built and passes the sims but hasn't been tried in a real game yet.
A scenario goes in when the change ships, and moves to **Tested** (with the
date and what happened) once someone has run it. Newest first in each
section.

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

- **The rest of CraftOS's startup after ccnix** (0.25.1, rewritten from the
  documented behaviour). With `ccsh.login` (or `init.boot`) set from the
  ROM, the computer's `/startup.lua` or `/startup/` folder still runs before
  ccsh; with `shell.allow_disk_startup` on and a disk holding `startup.lua`
  in a drive, the disk's startup runs instead of the computer's; the MOTD
  shows with `motd.enable` on.  Tried 2026-11-06 on 0.30.0 under init:
  none of it showed, as init's console window started blank over it.
  0.30.1 copies the screen into the console (and on a plain Computer
  boot draws in a window first, so there's something to copy).  Try again
  on Lab-A/B, and on a plain Computer with `init.boot`.

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

- **The Network Tester and the gateway's new dialog** (ccnix-mod 0.19.0).
  Craft the tester in Survival (iron, glass pane, iron / iron, redstone,
  iron / cable in the middle): it shows in the recipe book's equipment
  tab. Right-click a gateway empty-handed: the action bar says it takes a
  tester; with the tester (main hand, or off hand with the main empty) the
  dialog opens: a grey container panel, a green lamp and Working (amber
  Standing by on a spare block). With `ping` running through it the frame
  counts climb each second with a rate beside them; the pointer over MACs
  heard lists them all. Type in the VLANs box and wait: the refresh leaves
  the text alone; Enter saves ("Saved" in green). Walk away (8 blocks) or
  break the block: it closes. An old client is refused by the new server.

- **The exchange at 10.1.0.0/24** (ccnix-mod 0.18.0). The gateway's default
  address is 10.1.0.1/24, inside the CC networks (10.1.0.0/16), so one LAN
  route reaches every CC computer. On the dev server, after redeploying:
  `ip -br addr show ccnix0` on the host shows 10.1.0.1/24 alone (the old
  10.0.0.1 gone); routers' back addresses moved to 10.1.0.x with `default
  via 10.1.0.1`; `/ccnix route add 10.1.0.0/16 via 10.1.0.2` is accepted
  (a route around the exchange) and `10.1.0.0/25 via 10.1.0.2` refused;
  a computer straight on the exchange (no router) reaches the internet.

- **`/ccnix rom update` asks before the reload** (ccnix-mod 0.16.0): it only
  pulls, then warns that loading pauses the server (with the last reload's
  time) and offers `[Load it]`; `confirm` reloads; nothing new, no reload.
  On 0.15.39 the reload ran at once and paused the server about 15 s.

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
