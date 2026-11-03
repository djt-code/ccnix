# ccnix

A small Unix-like distribution for [CC: Tweaked](https://tweaked.cc/)
computers and turtles: a POSIX-style shell (ccsh) and utilities, git, a
network stack (routing, TCP, telnet), init and services, and turtle programs
built around a shared navigation library, written for a single cheap turtle
that swaps its tool upgrade in software. The ccnix mod ([mod/](mod/)) puts it
in every computer's ROM; on a server without the mod, `deploy/setup`
installs it.

The repo was called cc-turtles, and installed to `/cc-turtles`, until
2026-10-29; `setup` moves such an install to `/ccnix`.

The programs are in four folders (and `deploy/` installs them, `help/`
is their help, `sim/` tests them):

- `turtle/`: the turtle programs and `turtlelib`, the library they share;
- `pc/`: programs for a plain computer;
- `bin/`: the shell's utilities, `git` and ccsh, for any computer;
- `lib/`: the modules the programs require (`cu`, `regex`, `pager`, `net`,
  `proc`, `telnet`, `jbod`).

`deploy/install` puts `bin/` and `turtle/` (or `pc/`) on the path; see
[Install](#install). On a server with the ccnix mod, they're in every
computer's ROM instead: see [ccnix](#ccnix-in-every-computers-rom).

| Program | What it does |
|---|---|
| `turtle/mow.lua` | Mows every grass/fern/dead-bush tile in a rectangle, following rough terrain and routing around walls, chests and holes. |
| `turtle/farm.lua` | Learns the layout of a crop farm inside a bounding box, including which crop (wheat, carrots, potatoes, beetroot, sugar cane) grows on each tile, then loops: harvest ripe crops, replant, repair damage, dump into a chest, sleep. |
| `turtle/mine.lua` | Digs a tunnel of any width and height, as long as asked or as long as its supplies last, following every ore vein it touches. It builds a new home from chests every so often, carries its supplies forward, and brings the valuables back to the start at the end. |
| `turtle/turtlelib.lua` | Shared library: dead-reckoned position, mid-task refuelling, obstacle map + BFS routing, terrain/flat stepping, six-direction look/dig/place/move, inventory helpers, tool hot-swap, chest dumping/restocking/tidying. |
| `turtle/home.lua` | Sends the turtle back to its start after a Ctrl+T or reboot (same as `mow reset` / `farm reset`; for `mine`, use `mine reset`). |
| `bin/ccnix.lua` | ccnix, these programs in every computer's ROM (the ccnix mod): `ccnix` says what's in use, `ccnix update` pulls updates over the ROM's into `/ccnix` (only the files that differ), `ccnix reset` goes back to the ROM. See [ccnix](#ccnix-in-every-computers-rom). |
| `bin/git.lua` | Minimal git client: `clone`, `pull`, `status` and `log` for one branch over HTTP, via the Forgejo/Gitea or GitHub REST API. |
| `bin/cat.lua`, `bin/more.lua` | `cat` writes files out whole (POSIX `cat`); `more` shows them a screenful at a time in the pager: `more claude.log`. |
| `lib/pager.lua` | Library: a `less`-style viewer for `more`, `git log` and `claude`. Space/PgDn/`f` and `b`/PgUp page (11 lines on a turtle), the mouse wheel 3 lines, `j`/`k`/arrows/Enter go a line, `d`/`u` half a page, `g`/`G`/Home/End top and bottom, `h`/`l`/arrows 8 columns sideways (lines aren't wrapped), `0`/`$` left edge and far right, `q` back to the shell. The bottom line shows where you are. Text that fits is just printed. A program that colours its output can hand it lines as `{ text, fg }` (`fg` one blit digit per character, as `term.blit` takes them), and on a colour screen they're shown in those colours. |
| `bin/echo.lua` | Prints its arguments, or writes them to a file with `>` (replace) or `>>` (append), which the CraftOS shell can't do itself. The shell strips double quotes, so use single quotes for Lua strings. |
| POSIX utilities (`bin/`) | `ls` `head` `tail` `grep` `wc` `sort` `uniq` `cut` `tr` `tee` `od` `strings` `printf` `cmp` `diff` `find` `du` `df` `touch` `pwd` `basename` `dirname` `test`/`[` `expr` `true` `false` `sleep` `xargs` `env`, plus `which` and `seq`: the basic options of each, for the commands CraftOS lacks (and `ls`, which replaces CraftOS's). `lib/cu.lua` is their shared option parser and exit status; `lib/regex.lua` the POSIX regular expressions behind `grep` and `expr`. See [Utilities](#utilities). |
| `bin/ccsh.lua` | ccsh, a POSIX-style shell that runs inside the stock one: pipes, redirects, `&&`/`\|\|`/`;`, quoting, variables and an environment for programs, globs, `$(...)`, background jobs with `fg`/`bg`/Ctrl+Z, `/.profile`, and history kept in `/.ccsh_history`. See [ccsh](#ccsh). |
| `turtle/claude.lua` | Lets Claude drive the turtle: you type a goal, the model writes Lua that runs on the turtle (with `turtlelib` in scope), sees what came of it, and carries on until it's done or asks you something. |
| `turtle/autocompost.lua` | A stationary turtle on top of a composter: composts everything compostable in its inventory, forever. |
| Network (`bin/ip.lua`, `bin/ping.lua`, `bin/traceroute.lua`, `bin/nc.lua`, `bin/host.lua`, `bin/tcpdump.lua`, `lib/net.lua`, `lib/netdb.lua`) | A small network stack over modems, in layers: frames on a modem channel (VLANs: one channel each), ARP, IP with routing and ICMP, UDP and TCP, and names (the host database, then DNS: getaddrinfo and friends). `ip` sets it up, `ping` and `traceroute` diagnose it, `tcpdump` shows the frames on the wire, `nc` makes TCP connections (and `nc -u` sends datagrams), `host` asks DNS. See [Network](#network). |
| Telnet (`bin/telnet.lua`, `bin/telnetd.lua`, `lib/telnet.lua`) | Another computer's shell, or its console (the miner's screen), over the network, in real Telnet with ANSI, so any telnet client works too. See [Telnet](#telnet). |
| Processes (`bin/init.lua`, `bin/ps.lua`, `bin/kill.lua`, `bin/service.lua`, `lib/proc.lua`) | `init` runs every program as a process (an ID, its own terminal and environment) and keeps services running in the background, on any computer or turtle. `ps` lists the processes, `kill` signals them, `service` starts, stops and sets up services. See [Processes and services](#processes-and-services). |
| `pc/router.lua` | Runs on a computer with an interface on each of several networks (modems, or VLANs on one): forwards between them, and shows a live status screen. |
| `pc/fileserver.lua` | Runs on a plain computer: every floppy in its disk drives (beside it or over wired modems) as one folder, `/jbod`, that grows as drives and disks are added; files too big for one floppy are split across several. The layer is `lib/jbod.lua`. |
| `pc/diskclone.lua` | Runs on a plain computer: copies a directory onto every floppy a dispenser feeds into its disk drive, labels each one and ejects it. |

## Hardware

One **basic turtle** (no need for the advanced one). Two layouts work:

- **Hoe + pickaxe**, one on each side. Each program makes its own tool the
  *only* tool equipped while it runs (`T.usePrimaryTool`): the other tool is
  parked in the inventory and re-equipped on exit, including after Ctrl+T. This
  matters because `turtle.dig()` tries the left tool first, so a left-hand pickaxe
  would otherwise break the dirt the hoe was meant to till. Keep one inventory slot
  free for the swap. No chunk loading, so it only runs while the area is loaded.
- **Chunky + one tool**: Advanced Peripherals *Chunk Controller* on one side so it
  keeps working when you're away, the tool on the other; the second tool can live
  in the inventory and gets swapped in the same way. CC:Tweaked only accepts
  diamond or netherite tools as upgrades.

Fuel burns only on movement (about one per tile per pass). Lava buckets (1,000
each, bucket returned) are the cheapest fuel if you have a dripstone lava farm;
coal blocks (800) and dried kelp blocks (200) are the renewable alternatives.

## Coordinates, home and reset

Everything is relative to where the turtle starts: that spot is home `(0,0,0)`,
facing is `+z`. **Width** and **length** are counted *out from the turtle*: stand
at the turtle, count `width` blocks to its right and `length` blocks ahead, and
that is the box. The turtle's own row and column are not part of it, so it parks
diagonally outside one corner (over its chest) and never mows or farms the tile
it sits on. Negative width means the area is on its left; negative length means
behind. A lawn to the left and behind is `mow -70 -40`. The exception is `mine`:
a tunnel includes the turtle's own column and row (see [mine](#mine)).

Position is saved to `.turtlepos` after every move. If a job is interrupted
(Ctrl+T, reboot, server restart), `home`, `mow reset` or `farm reset` navigates
back to the start, from anywhere: a farm or lawn of any size or direction, or
past its edge. `farm reset` routes over the saved farm, flying above sugar cane
when the farm has some (or when it stopped while still learning, before a map
was saved).

A server stop in the instant between a turn and its save, or a turtle put
back by hand facing the wrong way, leaves it facing other than it thinks.
So before `farm reset` sets off, and before any farm run from a saved map,
the turtle looks at a few farm tiles near it, changing nothing, and checks
which way round they fit the map. If they fit another heading, it corrects
its own and carries on. If they fit none, it stops and asks you to place it
by hand. With the heading right, this costs about a dozen moves per start.

Starting a job while the saved position isn't home prints a
warning and stops; add `--here` to declare the current spot as the new home.
If you carried the turtle back yourself, `farm reset --here` / `mow reset --here`
just marks where it is as home without moving it or starting a job (the saved
farm layout is kept).

## Install

### ccnix: in every computer's ROM

On a server running the ccnix mod ([mod/](mod/), a submodule), every
computer has all of this in its ROM already, at `/rom/ccnix`: nothing to
install, and no disk used. At each boot `deploy/boot.lua` (run from
`/rom/autorun`) puts `bin/` and `turtle/` or `pc/` on the path, `help/`
on the help path, makes `ls` ours, and brings the network up while
`net.boot` is on. With `init.boot`, `ccsh.login` or
`ccnix.autostart` set, it runs those at the end of startup, after the
computer's own startup files. Programs find their libraries through
`_G.ccnix`.

Updates come without the server's admin. `ccnix update` pulls the latest
from the repo into `/ccnix`, keeping only the files that differ from the
ROM's: a few files, not the whole repo.
- **From the next boot**, each program, library and help page comes from
  `/ccnix` if it's there, else from the ROM. `ccnix` says what's in use
  (each layer's version, and commit), `ccnix version` the version alone,
  and `ccnix reset` goes back to the ROM.
- **Versions** are semantic (major.minor.patch), kept in `deploy/version`;
  a ROM from before there was one shows as "unversioned".
- **When the server's copy changes** (the mod, or the server's own
  checkout), updates made against the old one are left out until
  `ccnix update` makes them again. They could pair a program with another
  version's library.
- **When the ROM is newer than the branch,** an update keeps nothing.
- **Files deleted upstream** are still in the ROM until the server's copy
  catches up.

The server's ops update the ROM itself while the server runs, with
`/ccnix rom update` (a git pull of the server's checkout, then a reload):
the mod's README says more.

`setup` on such a server clones nothing:
- it sets what the apps named want;
- it moves an install from before ccnix (`/cc-turtles`) over: its startup
  lines and files go, and a turtle's job files move to `/ccnix/turtle`
  the next time the program looks for them;
- it runs `ccnix update`.

### Without the mod: `setup`

On the turtle or computer, with HTTP enabled on the server:

```
wget run https://raw.githubusercontent.com/djt-code/ccnix/main/deploy/setup.lua
```

That fetches `git`, clones the repo into `/ccnix` and runs
`deploy/install` (below), then reboots. With nothing named it takes
everything the device runs: a computer's disk holds 1 MB and the whole
repo nearly fills it, so it leaves out `sim/` always, `pc/` on a turtle
and `turtle/` on a computer (`--all` for everything). Name apps to take
just those, with what they need and their help:

| App | What comes |
|---|---|
| `mine` `farm` `mow` `autocompost` `claude` | the program, with `turtlelib`, `home` and `autostart` |
| `coreutils` | the utilities in `bin/` and their modules in `lib/` |
| `ccsh` | [ccsh](#ccsh), started at every boot |
| `diskclone` | for a computer with a disk drive |
| `fileserver` | its disk drives as one folder, `/jbod` |
| `net` | the network: `ip`, `ping`, `traceroute`, `nc`, `host`, `tcpdump`, up at every boot |
| `router` | the network, and `router` to route between networks: forwarding on, up at every boot |
| `init` | [processes and services](#processes-and-services): `init` at boot, `ps`, `kill`, `service` |
| `telnet` | the [telnet](#telnet) client, and the network |
| `telnetd` | the [telnet](#telnet) server as a service, with `init` and the network (then `set telnetd.password ...`) |

`git`, `deploy/`, the pager and the help index always come. Options: `--autostart <app>` (a turtle
runs it at every boot, see [Autostart](#autostart); on a computer,
`router`: its status screen), `--ccsh` (ccsh at boot without naming
it), `--no-reboot`, `--all`, `--skip <dir>`. For example, `setup router
--autostart router` makes a router that's routing, its screen up, after
every boot; `setup net` a computer on the network.

```
wget run .../deploy/setup.lua mine --autostart mine     a miner that carries on after reboots
wget run .../deploy/setup.lua farm coreutils ccsh    a farmer you can also work in
```

Run it again to update: naming apps again changes what's there, naming
none keeps the choice. It also finishes a clone that filled the disk: it
pulls an existing checkout, and clears what a half-done clone left in
the folders it leaves out.

By hand, the same is:

```
wget https://raw.githubusercontent.com/djt-code/ccnix/main/bin/git.lua /git-boot.lua
git-boot clone https://github.com/djt-code/ccnix /ccnix
rm git-boot.lua
ccnix/deploy/install
```

Later, `git pull` inside the directory fetches only the files that changed.
`git status` shows the checked-out commit and whether the remote has moved on;
`git log` lists recent commits on the branch, marking the one checked out,
in the pager (see `pager.lua` above; `q` quits).
If HTTP is disabled on the server, drop the files into
`<world>/computercraft/computer/<id>/ccnix/` by hand.

To run the programs from any directory, put them on the shell's search
path:

```
ccnix/deploy/install
```

It writes two lines into `/startup.lua` (or, if `/startup` is a
directory, into `/startup/00-ccnix.lua` and `/startup/zz-ccnix.lua`) that
run `deploy/boot.lua`: one at the top, where it does from the checkout
what the ROM's boot does ([above](#ccnix-in-every-computers-rom): the
path, the help path (`help mine`, `help grep`; `help ccnix` lists them
all), `ls`, the [network](#network) while `net.boot` is on), and
`--end` at the bottom, where it runs what doesn't return: with `--init`
(the setting `init.boot`), [init](#processes-and-services), which starts
the services and then runs the two below itself; else the
[autostart](#autostart) (`--autostart <app>`: a turtle's job, or a
computer's router screen), then ccsh with `--ccsh`. `--net` turns
`net.boot` on (`--router` forwarding too; `ip boot` and `ip boot off`
later). Then it reboots; `--no-reboot` runs boot in the current shell
instead. Lines an earlier install wrote go (every line naming the repo's
folder), yours stay, and running it again changes nothing. `deploy/` and
`lib/` aren't on the path, so `install` and `cu` don't become commands.

The shell looks a program name up in each directory on the path in turn,
`.lua` optional. Run from anywhere, a program still finds its modules
(`turtlelib` beside the turtle programs, `cu` and the rest in `lib/`) and
keeps its files (`.turtlepos`, `mine.job`, `farm.map`, `claude.key` ...)
next to itself in `turtle/`, not in the current directory.

## Settings and autostart

`mine`, `farm` and `mow` keep their sizes in CraftOS's settings, so
`set` lists them with what they mean and `set mine.length 64` changes one:

| Setting | Default | |
|---|---|---|
| `mine.width`, `mine.height`, `mine.length` | 3, 3, 32 | the tunnel `mine` digs when given no size (length 0: until it can't go on) |
| `mine.spacing`, `mine.lights` | 0, true | blocks between homes (0: chosen from the size); torches in the walls |
| `farm.width`, `farm.length` | none | the box `farm` learns when there's no saved farm |
| `farm.repeat` | 20 | minutes between passes (0: one) |
| `mow.width`, `mow.length`, `mow.repeat`, `mow.torches` | 16, 16, 0, true | the lawn, minutes between passes (0: one), torches |
| `ccnix.autostart` | "" | what a turtle runs at boot |
| `ccsh.login` | false | ccsh at boot |
| `init.boot` | false | [init](#processes-and-services) at boot: processes, services |

A size given on the command line is saved: after `farm learn 9 12` or
`mine 5 3 64`, plain `farm` or `mine` (and the autostart) uses it again.

### Autostart

A turtle restarts whenever its chunk loads again (a player comes back, the
server restarts), and a job then stops where it was. With
`ccnix.autostart` set (`setup ... --autostart mine`, `install
--autostart mine`, or `set ccnix.autostart mine`), startup runs
`turtle/autostart`, which waits 5 seconds (any key cancels, for the
prompt) and then:

- `mine`: a tunnel it was digging when it went down: back to the last home
  if it's elsewhere, then `mine --resume`. No tunnel yet: one as the
  settings say (3x3, 32 long unless changed). A tunnel it finished, or
  stopped itself (out of chests or fuel): it says so and waits for you, so
  a reboot doesn't send it off on a trip that can't go anywhere.
- `farm`: a saved farm: `farm reset` if it's away from home, then `farm`.
  No farm yet: `farm`, which learns the box in `farm.width`/`farm.length`.
- `mow`: a pass cut short: `mow reset`, then `mow`. On repeat
  (`mow.repeat` > 0): `mow`. Otherwise nothing: the lawn was mowed.
- `autocompost`: `autocompost`.

On a computer the one choice is `router` (`setup router --autostart
router`, `install --autostart router`): the network comes up with
forwarding on, then the router's status screen (`q` leaves it; routing
goes on).

`set ccnix.autostart ""` turns it off. (The setting was
`cc-turtles.autostart` until 2026-10-29; boot renames it.)

## git

```
git clone <url> [dir] [-b <branch>] [--token <token>] [--skip <dir>]... [--all]
git pull   [dir]
git status [dir]
git log    [dir] [-n <count>]
```

Not real git: it talks to the host's REST API (branch -> commit -> recursive
tree -> raw blobs), so there is no packfile decoding and it runs fast on the
CC VM. It records the commit and per-file blob SHAs in `.gitlite`; `pull`
downloads only blobs whose SHA changed, deletes tracked files removed
upstream, and never touches untracked files (so `farm.map` survives).
Works with GitHub and Forgejo/Gitea (any host). `--token` is only needed for
private repos and is saved in `.gitlite` for later pulls.

A clone leaves out `sim/`, and `pc/` on a turtle or `turtle/` on a
computer; `--skip <dir>` leaves out more, `--all` nothing. The choice is
saved in `.gitlite` and `pull` keeps to it. A checkout made before this
gets the device's rule on its next `pull`, which deletes those folders.
Before writing a file it checks the disk has room (CC counts every file as
at least 500 bytes), and if not it stops, saying so, with what it got
recorded: free some space and `git pull` fetches the rest. `pull` deletes
files removed upstream before fetching new ones, so files that moved
don't need room twice.

## Utilities

CraftOS has `ls`, `cp`, `mv`, `rm`, `mkdir`, `cd`, `edit` and not much
else for working with files. These fill the gap with the basic options of
the POSIX.1-2024 utilities: the ones you'd reach for, not every one in the
standard. Each file's header comment lists what it supports and where it
departs from POSIX.

| Utility | Options |
|---|---|
| `ls` | `-a -A -d -F -h -l -p -R -r -S -t -1`; `ls -lah` as on Linux; replaces CraftOS's `ls` (see below) |
| `cat` | `-u`; files byte for byte |
| `more` | `-c -s -u`; pages in the pager, a `::::` header per file |
| `echo` | no options; XSI escapes (`\n \t \c \0num` ...); `> file` and `>> file` (outside ccsh) |
| `head` | `-n N`, `-c N` (and `-N`) |
| `tail` | `-n [+-]N`, `-c [+-]N`, `-f` (polls once a second), `-r` |
| `grep` | `-E -F -c -e -f -i -l -n -q -s -v -x`; basic regexes by default |
| `wc` | `-c -l -m -w` |
| `sort` | `-b -c -C -d -f -i -k -m -n -o -r -t -u` |
| `uniq` | `-c -d -u -f N -s N`, `[input [output]]` |
| `cut` | `-b -c -f` lists, `-d -s -n` |
| `tr` | `-c -C -d -s`; ranges, `[:class:]`, `[c*n]`, `\ooo` |
| `tee` | `-a -i` |
| `od` | `-A d/o/x/n`, `-t a c d o u x` with sizes, `-j -N -v`, `-b -c -d -o -s -x` |
| `strings` | `-a -n N -t d/o/x` |
| `printf` | `%b %c %d %i %o %u %x %X %e %f %g %s %%`, widths, precision, escapes |
| `cmp` | `-l -s` |
| `diff` | normal, `-u`/`-U n`, `-c`/`-C n`, `-e`, `-f`, `-b`, `-q`, `-r` |
| `find` | `-name -path -type -size -mtime -newer -print -print0 -prune -depth -xdev -exec -ok -maxdepth -mindepth`, `! -a -o ( )` |
| `du` | `-a -s -k -x` |
| `df` | `-k -P` |
| `touch` | `-a -c -m -r -t -d` |
| `pwd` | `-L -P` |
| `basename`, `dirname` | none |
| `test`, `[` | `-e -f -d -s -r -w -x -n -z -t -nt -ot -ef`, `= != < >`, `-eq -ne -lt -le -gt -ge`, `! -a -o ( )` |
| `expr` | `\| & = != < <= > >= + - * / %`, `:` with a basic regex, `( )` |
| `true`, `false` | none |
| `sleep` | seconds, decimals allowed |
| `xargs` | `-0 -E -I -L -n -p -r -s -t -x` |
| `env` | `-i -u name`, `name=value`; the environment ccsh gives programs (none outside it) |
| `which` | `-a` (not POSIX: which file the shell would run) |
| `seq` | `-s sep -w -f format`, `[first [increment]] last`, decimals and negatives (not POSIX: GNU's) |

They all work the same way, so [ccsh](#ccsh) can join them up with
pipes. With no file operands, or the operand `-`, a utility reads standard
input (`io.input()`, the keyboard in the stock shell). The keyboard has no
end of file: hold Ctrl+T to end the input (inside these programs Ctrl+T
ends the input, not the program). Output goes through `io.write`, so to
`io.output()`; messages are `name: message` through `printError`. Options
follow the POSIX syntax guidelines: `-abc` groups flags, `-n5` and `-n 5`
both work, `--` ends the options. The exit status is 0 for success, 1
for a file that couldn't be read (or "false", "no match", "different"),
and 2 for a usage error; `grep`, `cmp`, `diff`, `sort`, `test` and `expr`
use 2 for any trouble, as POSIX has them. It is left in
`_G.POSIX_STATUS`, and any status but 0 makes `shell.run` return false.
`cu.lua` holds all this; `regex.lua` is a POSIX regex engine (basic and
extended, bracket expressions and classes, intervals, back-references)
that `grep` and `expr` share.

What CraftOS can't do:

- The stock shell has no pipes, redirects, globbing, single quotes or
  backslash escapes. It splits words on spaces and strips double quotes,
  so `grep "two words" notes.txt` works but `*` reaches the program as is.
  `echo` does `>` and `>>` itself, since that's how you'd write a file at
  the prompt. [ccsh](#ccsh) adds all of these.
- The ROM's programs come first on the path, so `cp`, `mv`, `rm`,
  `mkdir`, `cd`, `clear`, `edit`, `type`, `set` and `alias` are always the
  CraftOS ones; there is no POSIX version of those here. `ls` is the
  exception: CraftOS's `ls` is only an alias for `list` (which shows
  hidden files only with the setting `list.show_hidden`), and aliases come
  before the path, so `deploy/install` makes `ls` an alias for `bin/ls`.
  `dir` stays CraftOS's `list`; `alias ls list` brings the old `ls` back
  until the next boot.
- `ls -l` has no owner, group or link-count columns (CraftOS has none):
  the mode (`d`, and no `w` on read-only files such as `/rom`), the size,
  the modification time and the name.
- There is no separate stderr: messages go to the screen (in red on an
  advanced computer).
- No file times can be set, no permissions, owners, links or devices:
  `touch` creates a missing file and rewrites an existing one to bump its
  modified time; `-r`/`-t`/`-d` are checked but can't be applied. `test -r`
  is any existing file, `-w` anything outside `/rom`, `-x` a directory or a
  `.lua`/extensionless file. `find` has no `-perm`, `-user`, `-links` or
  `-atime`.
- Bytes are characters (C locale only): `-m` is `-c`, ranges and sorting
  go by byte value, and `-i` folds ASCII letters only.
- Lua numbers are doubles: `printf` and `expr` are exact up to 2^53.
- `[` is a ccsh builtin that runs `test` (a ROM path can't hold `[`, so
  there is no `[.lua`); the stock shell has `test` only.

`cat` is the POSIX one now: it writes the files out whole, with no paging,
the same on the screen as anywhere else. `more` is the pager (what `cat`
used to be): it shows a long file a screenful at a time with `pager.lua`'s
keys, prints text that fits, and copies its input like `cat` when the
output isn't the screen.

## ccsh

A POSIX-style shell for CraftOS. Type `ccsh` to start it, and `exit`
(or hold Ctrl+T at its prompt) to get back to the stock shell.
`deploy/install --ccsh` starts it at every boot, until you
`set ccsh.login false`.

```
/$ wc -l *.lua | sort -n | tail -n 3
/$ grep -c diamond mine.log > count.txt 2>/dev/null || echo none
/$ echo "$(wc -l < farm.map) lines in the map"
/$ cd ccnix && git pull && cd /
```

| | |
|---|---|
| Pipes | `a \| b \| c` |
| Redirects | `< f`, `> f`, `>> f`, `2> f`, `2>> f`, `2>&1`, `>&2`, `n>&-`; `/dev/null` |
| Lists | `a ; b`, `a && b`, `a \|\| b`, `! a`; a newline is a `;` |
| Quoting | `'single'`, `"double $X"`, `\x`; `#` comments |
| Variables | `X=value`, `$X`, `${X}`, `${X:-default}`, `$?`, `$#`, `$1`..`$9`, `$@`, `"$@"`, `$*`, `$$`, `$!`, `$0`; `$PATH` is the shell's path (setting it changes the path), `$PWD` its directory, `$HOSTNAME` the computer's label (or ID), `$!` the last background job's process ID |
| Environment | `export X`, `export X=1`, `export -n X`, `export -p`, `unset X`; `X=1 cmd` for one command. Programs read it with `os.getenv("X")`, and change their own copy with `os.setenv(name, value)`; `os.environ()` lists it. It holds the exported variables (`PS1` is one), `PATH`, `PWD` and `HOSTNAME`. A ccsh started from ccsh takes it over, and `env` shows it |
| Jobs | `a &` in the background (its own copy of the variables); `jobs [-l\|-p]`; `fg [%n]`, `bg [%n]`; `wait [%n\|pid]`; `kill [-9] %n\|pid`; Ctrl+Z at the prompt stops the job in front. `fg prog` and `bg prog` open a multishell tab as CraftOS's do, with the environment |
| Startup | `/.profile` runs when ccsh starts at the prompt: set `PS1`, `export` variables |
| History | Up and down go through the lines typed before, kept in `$HISTFILE` (`/.ccsh_history`; unset or empty, none) across sessions and tabs, the last `$HISTSIZE` of them (1000; `0` keeps none). Both are shell variables, set before `/.profile` runs so it can change them |
| Prompt | `PS1`, an exported variable: it starts as `'\h:\w\$ '` (`label:/dir$ `) on a computer with a label, `'\w\$ '` (`/dir$ `) without, unless the environment brought one. Set it with `\h` (label, or ID), `\w` (directory), `\W` (its last part), `\i` (ID), `\$`, `\n`: `PS1='\h \W\$ '` |
| Globs | `*`, `?`, `[abc]`, `[!a-z]`; names starting with `.` only match an explicit dot |
| Substitution | `$(cmd)`, `` `cmd` `` (a subshell) |
| Compound commands | `if a; then b; elif c; then d; else e; fi`, `while`/`until a; do b; done`, `for x in words; do b; done` (without `in`: `"$@"`), `case w in a\|b*) x;; *) y;; esac`, `{ a; b; }`, `( a; b )` (a subshell: its variables, functions, `exit` and `cd` are its own), `break [n]`, `continue [n]`. Each can be piped and redirected whole: `for f in *.lua; do wc -l $f; done \| sort -n`, `while read l; do ...; done < file` |
| Functions | `name() { body; }` (or `function name { body; }`): `$1`... are its arguments, `return [n]`, `local x=1` until it returns |
| Builtins | `exit [n]`, `:`, `true`, `false`, `[ expression ]` (`test`), `read [-r] name...`, `shift [n]`, `unset`, `export`, `. file`, `jobs`, `fg`, `bg`, `wait`, `kill`, `break`, `continue`, `return`, `local` |
| Scripts | `ccsh file [args]`, `ccsh -c 'commands' [name [args]]`, or a file starting `#!/ccnix/bin/ccsh` run by name |

A line ending in `\`, `|`, `&&` or `||`, or inside quotes, carries on at a
`>` prompt. Tab completes as in the stock shell, for the command after
the last `|`, `;` or `&`. Ctrl+T while a command runs stops it and the
rest of the line, with status 130.

```
/$ cat /.profile
PS1='\h:\W\$ '
export EDITOR=edit
/$ tail -f mine.log > tail.txt &
[1] 1
/$ lua                      (then Ctrl+Z)
[2]+ Stopped  lua
/$ jobs
[1]- Running  tail -f mine.log > tail.txt &
[2]+ Stopped  lua
/$ fg %2
/$ X=1 env | grep X
X=1
```

Background jobs get every event except the keyboard's and the mouse's,
which go to the job in front. Their output shares the screen with the
prompt. A stopped job keeps up to 256 of the events it misses (timers,
rednet...) and gets them when `fg` or `bg` starts it again. A job can't
outlive the shell: `exit` with jobs left warns once, then ends them, and
a script or `ccsh -c` waits for its jobs before it ends. For one that
should keep running, `bg prog` puts it in its own tab.

How it works: ccsh runs inside the stock shell and has it find and run
programs, so the path, aliases, `cd`, `alias`, `set` and the programs'
`shell` API are the stock ones. A pipe runs each command to the end and
then hands what it wrote to the next one. While a command runs, its
`io.input()`, `io.output()`, `print`, `write`, `term` and `printError` point
at its pipe or file, and `os.getenv` at its environment. They are put back whenever it waits, so other
multishell tabs don't see them. That lets stock programs be piped as
well as the utilities.

Not yet: here-documents, `$(( ))` arithmetic (`expr` does sums), `~`.
And what CraftOS rules out:

- Nothing streams: `a | head` still runs all of `a`, holding its output
  in memory.
- CraftOS has no environment: `os.getenv` exists only for programs
  ccsh runs (and what they run in turn). The stock shell's programs
  and other tabs don't see it.
- `/dev/null` only works in redirects; there's no such file.
- Stock programs lay out text as they would on the screen: `ls` writes
  columns, so `ls | wc -l` counts rows, not files.
- Full-screen programs (`edit`, `paint`) need the screen; don't pipe them.
- From the stock shell, `ccsh -c 'a; b'` works (ccsh joins the
  pieces back up), but use double quotes for anything with double quotes
  or runs of spaces in it.
- `exit` is ccsh's own: the stock `exit` program would end the stock
  shell under it, which shuts the computer down.

## mow

```
mow <width> <length> [repeatMinutes] [notorch] [--here]
mow reset
```

Place the turtle on the ground at grass level diagonally outside one corner of the
lawn, facing along the *length* axis. An optional chest below the start position
collects seeds.

- Only cuts blocks in the `T.diggable` list (short/tall grass, ferns, dead bushes).
  Everything else is terrain or an obstacle.
- Climbs steps up to 3 blocks, follows dips, and treats drops deeper than 3 as a
  crevasse to be routed around rather than entered.
- Tiles it can't reach are retried at the end of the pass from whatever side it
  can get to; anything still unreachable is printed as coordinates.
- When it's down to two empty slots it goes home, empties the seeds it collected
  into the chest and carries on, so cut grass doesn't drop seeds on the ground. A
  full chest makes it wait at home until there's room. Without a chest it warns
  once and keeps mowing.
- Grass doesn't regrow naturally, so a single pass is usually enough; the repeat
  argument is there if a mod on your server spreads it.
- **Lighting:** with torches in its inventory it places them as it mows, on a
  diamond lattice so every tile is within taxicab distance 12 of a torch (mobs need
  block light 0 to spawn since 1.18; a torch is light 14, so 13 is the limit and 12
  leaves a margin). That's about one torch per 313 tiles — 18 for a 70×40 lawn. The
  startup line tells you how many sites there are. Pass `notorch` to disable, or
  set `TORCH_RADIUS = 6` for a pre-1.18 server. Torches already present are left
  alone on repeat passes.

## farm

```
farm <width> <length> [repeatMinutes]        first run: learn layout, then farm
farm [repeatMinutes]                         later runs: use saved layout
farm learn <width> <length> [repeatMinutes]  save a new layout after changing the farm
farm repair                                  inspect every tile once, fix damage, stop
farm clone [repeatMinutes]                   build the last learned farm HERE
farm reset                                   go home after an interruption
```

Hover the turtle **two blocks above the farmland** (one above the crop tops),
diagonally outside one corner of the farm, facing along the length axis. Put the
output chest directly below the start position with what each crop is planted
with in it (wheat seeds, carrots, potatoes, beetroot seeds, sugar cane): the turtle restocks
them from the chest at the start of every pass and whenever it runs out mid-pass
(up to one per tile of that crop, max 256), so you never need to hand them to it
directly.

The chest (or barrel) can be anywhere from 1 to 3 blocks below the start
position, with only air between it and the turtle. The turtle doesn't remember
where the chest is. Each visit home, it moves down until it finds the chest, so
you can raise or lower the chest on an existing farm without telling the turtle,
even while it's running. Don't move the start position itself. The saved farm
map is measured from it, and it must stay two blocks above the farmland. If no
chest is found within 3 blocks, the turtle prints "No chest found below home;
keeping items." and carries on.

Farms can grow **wheat, carrots, potatoes, beetroot and sugar cane**, in any mix:
strips of different crops, or crops mixed within a strip.

**Sugar cane** grows on dirt, grass, sand, moss, mud and similar ground (same level
as the farmland), and only next to a water source, so plant it along the lanes. It
stands up to three blocks tall, reaching past the turtle's cruise height, so on a
farm with cane the turtle gets around two blocks higher than usual (and the
learning pass always scans from there). It works cane from one block above cruise
height, cutting a third block on the way in and the second from above, so every
cut block goes straight into its inventory and nothing falls to the ground. The
bottom block is never cut, because that's what regrows. A missing bottom block is
replanted with cane from the chest; if it won't take, there's no ground or no water
beside it, which counts as damage and sends the turtle into a full repair pass that
fixes the lane first and then replants.

- **Learning** only records the layout; it doesn't touch the farm. A crop or
  farmland → crop tile, and the crop growing there becomes that tile's crop;
  sugar cane, or bare sand/mud/moss → cane tile;
  water → lane; anything else → left alone. Bare farmland, and gaps settled as
  land, get the crop most of their strip grows (else the farm's most common crop,
  else wheat). A missing
  ground block or bare dirt could be either, so it takes the kind of the strip it
  lies in (a column or row that is otherwise all land, or all water); bare dirt
  outside any strip is farmed. Saved to `farm.map`, which from then on is the farm
  as it *should* be. Re-learn only when you change the farm on purpose.
- **Farming pass** serpentines over the crop tiles only, one line at a time
  along the lanes, entering each line from the end nearest the last; lanes are
  skipped. It harvests each crop when ripe (age 7; beetroot at 3) and replants
  the tile's planned crop immediately, plants any bare farmland, and re-tills
  farmland that reverted to dirt, all from cruise height (CC:Tweaked lets a hoe
  till through one block of air below the turtle). A different crop found growing
  on a tile is left to ripen, then harvested and replaced with the planned one.
  Then it goes home, dumps the harvest and surplus planting items, tops them back
  up, and sleeps
  (default 20 min; `0` for a single pass).
- **Full repair pass.** Ground missing under a crop tile, or a block in the way,
  makes the turtle go home after the farming pass and run a full repair pass
  before sleeping (untilled dirt doesn't: the farming pass fixes that itself). The
  full pass inspects every crop tile and drops to crop level over every lane tile
  to check its water, then fixes everything it found. Lane damage counts there: a
  lane tile that isn't a water *source* (dry, flowing, or filled in). It also runs
  once after `clone`, and `farm repair` runs it on demand and stops. After `learn`
  there's no extra pass: learning has just looked at every tile, so the turtle
  only rebuilds the gaps it found (missing ground, lane water that isn't a source),
  and goes straight to farming when there are none.
  - Land gets dirt, tilling and its planned crop right away.
  - A filled-in lane tile (dirt or anything else in it or on top of it) is dug
    out with a **diamond pickaxe**, which the turtle swaps in for the hoe; keep one
    in its inventory.
  - A lane tile then gets a dirt floor beneath if that's missing, dirt walls on
    every side the map doesn't call lane, and a bucket of water, which also turns
    flowing water back into a source. A wall that lands on a crop tile is tilled
    and planted on the spot.
  - Water comes from empty buckets refilled at a lane tile with two or more
    source neighbours (it regenerates), always the one nearest the tile being
    filled. When it runs dry the turtle fills every bucket it carries that the
    rest of the lane can use in one stop (up to 4, if the chest has that many
    buckets), and it stays down at lane level while pouring along a lane, so a
    long lane is filled in a few short trips. If a lane is broken up so that no
    refilling tile exists, the turtle moves one of the lane's own sources into a
    gap that creates one, and refills the borrowed tile afterwards. Water buckets
    in the chest are only needed to start a lane from nothing.
  - Only every other lane tile is poured: a tile between two sources becomes a
    source by itself, so an empty lane takes about half the buckets, and a gap
    between two intact sources takes none. The skipped tiles are checked once
    the lane is done (or on the way past while refilling), and any that didn't
    take get a bucket after all.
  - Anything it can't fix is listed and found again on the next pass.
- **Inventory.** At the start of a run and after every pass the turtle prints
  what it carries, then puts everything it doesn't need right now into the chest:
  it keeps planting items for one pass, fuel and its tools, plus dirt and buckets only
  while a repair is using them. Keep **seeds, dirt and a bucket or two in the
  chest**.
- **Fuel.** Keep **fuel in the chest** too. Every visit home tops the tank up
  from it to about one pass's worth. Before any move that would leave too
  little fuel to get home (plus a margin of 30 for detours), the turtle stops
  what it's doing, flies home, empties out, refuels from the chest, flies back
  to the exact spot and carries on, mid-learn, mid-clone or mid-pass. If the
  chest has no fuel either, it waits **at home** and says so, checking again
  whenever you put fuel in the chest or the turtle (or every 10 seconds). If a
  trip home in the middle of a farming pass took longer than the time between
  passes, the crops it already did have had time to ripen again, so it starts
  the pass over from the beginning instead of going back. A run
  starts with whatever fuel it can get, as long as it has enough to make
  headway.
- **Compost hopper (optional).** Put a hopper **directly behind the turtle's start
  position**, at the turtle's height, feeding a composter. The turtle looks for it
  at the start of every run. Composting happens while the turtle waits for its
  next pass: every 10 seconds, if the hopper has an empty slot and the chest holds
  more than twice as many wheat or beetroot seeds as the farm has tiles of that
  crop, it takes the surplus out in whole stacks (only as many as the hopper has
  empty slots for, and never taking the chest below that limit) and drops them
  into the hopper. It stops when there's no surplus left or when the next pass is
  due, whichever comes first. A single pass (`farm 0`) doesn't compost. Carrots,
  potatoes and sugar cane are never composted, since the seed is the harvest. Route
  the bone meal back however you like, e.g. a hopper under the composter into the
  farm chest.
- **Grow passes (bone meal).** After each farming pass, if the chest holds enough
  bone meal to grow the whole farm from seed (near the worst case: 4 per crop
  tile, 6 per beetroot tile, since one bone meal adds 2-5 growth stages but
  beetroot only advances one stage three times in four), the turtle does a grow
  pass: it bone meals every crop until it's ripe, harvests it and replants it.
  It repeats while there's still enough, carrying up to three stacks and fetching
  more mid-pass, and returns what's left to the chest. Sugar cane is skipped (bone
  meal doesn't grow it). If a pass uses no bone meal at all, it stops trying until
  the next cycle.
- **Tidy chest.** At every visit, before taking or moving anything and again
  before leaving, the turtle merges part stacks of the same item in the chest
  (hoppers and its own partial takes leave them scattered), so each item fills as
  few slots as possible. Then it sorts the chest, packed against its last
  slot. Each item's stacks sit together, fullest first. Similar items sit side
  by side, grouped by the last word of the item's name: all the seeds, then all
  the buckets. The empty slots come first, because slot 1 is the working slot:
  hoppers fill it and the turtle takes from it. Stacks already in place
  aren't moved, so a chest that's already in order costs nothing. A full chest
  gets sorted too: the turtle holds one stack while it shuffles the rest.
- **Full inventory, full chest.** Before working each tile the turtle checks it
  has room for that tile's drops (three empty slots). If not, it goes home to
  empty what it doesn't need, then carries on where it was, so harvest never
  spills onto the ground. Restocking also leaves those slots free. If the chest
  is full, the turtle stops at home and waits, checking every 30 seconds, until
  there is room.

### Cloning a farm

`farm clone` rebuilds the last learned layout wherever the turtle is now, then
farms it. Park the turtle the same way you would for a new farm (two blocks
above ground level, diagonally outside the corner, chest below) with a pickaxe
and a hoe on board, and **dirt, seeds and two water buckets in the chest**. It
runs two phases: with the pickaxe it clears the crop level, digs the lane
trenches and removes stone where land is wanted; with the hoe it fills, tills
and plants the land, then floors and walls each lane and waters it. Lanes are
walled on every side the map doesn't call lane, including the ends, so nothing
runs out of the box. Each lane is bootstrapped by pouring the two buckets at
tiles 1 and 3 — Minecraft turns tile 2 into a source — and the rest is scooped
from that regenerating tile, so two buckets build any number of lanes; only
every other tile needs pouring. The site
should be roughly level with the turtle's starting height; it won't terraform
more than one block.

## mine

```
mine <width> <height> [length] [--spacing N] [--no-lights] [--here]
mine --resume
mine haul
mine ... --new
mine reset [--home N | --to-start | --here]
```

Digs a tunnel `width` blocks wide (to the right; negative: to the left) and
`height` blocks tall (up; negative: down), `length` blocks long. Without a
length, it keeps going until it can't. The turtle's own column and row are
part of the tunnel: put the turtle where one bottom corner of the tunnel
should start (top corner, for a negative height), facing along it. The tunnel
starts with the block in front of it. `mine 3 3 32` digs a 3x3 tunnel 32
long, up and to the right of the turtle; `mine 3 3` digs one as long as its
supplies last.

Put **two chests** at the start: one directly **above** the turtle for
valuables and supplies, and one directly **below** it for bulk. Stock the top
one with **fuel and chests**, **torches** if you want the tunnel lit, and a
**crafting table** so it can make more chests and torches from wood it finds. Bulk is stone, cobblestone, deepslate,
andesite, diorite, granite, tuff, dirt, gravel, sand, netherrack and the
like. Everything else counts as a valuable, including anything it doesn't
recognise. Needs a pickaxe, equipped or in the inventory.

- **Homes:** the tunnel is dug a segment at a time. At the end of each
  segment the turtle builds a new home from two chests:
  - one set into the wall beside its start column, for valuables and supplies;
  - one under the floor (over the ceiling, for a downward tunnel) for bulk.

  Its trips to unload or refuel only ever go back to the nearest home, never
  all the way to the start. The spacing is chosen so a segment's bulk fits
  in one chest, at most 64 blocks (64 for a 3x3 tunnel); `--spacing N`
  overrides it.
- **Supplies move forward:** building a home, the turtle carries the spare
  chests and the fuel from the old home to the new one, in as many trips
  as it takes, leaving a stock of 8 fuel items in every home along the
  way, so a resume from any home finds fuel there. Coal it mines goes into
  the home's chest and fuels it too: coal ore is ore like any other, so
  every coal vein the tunnel touches (and, with a scanner, every one in
  reach) ends up in the chests, and the surplus travels forward with the
  supplies. All the wood it mines (logs, planks, sticks) and the crafting
  table travel forward too. Bulk stays in the home it was mined near, and
  only ever goes in bulk chests: walking back (at the end of a job, or in
  `mine haul`) it leaves the bulk it carries in the bulk chest of each home
  it passes, keeping one stack of filler for sealing water on the way until
  home 1, so no bulk reaches the start; it never swaps bulk into a
  valuables chest to make room, and bulk it finds in a valuables chest goes
  down into that home's bulk chest. Valuables stay in their home's chest
  until the end. It checks every chest
  it places is really there: a minecart standing where a chest goes (in a
  mineshaft) only gets right-clicked by `turtle.place`, which still reports
  success, so the turtle breaks the minecart, picks it and whatever spilled
  out of it up, and places the chest again.
- **Crafting:** at the newest home, when it has fewer chests than two more
  homes need, or fewer torches than two segments need, it crafts. Its wood
  becomes as many chests as it can make, less the planks for the sticks of
  the torches that light the segments those chests start. The torches are
  made from coal it can spare beyond the fuel to build the next home and get
  back. To craft, it swaps the crafting table in for the pickaxe (as with
  the Geo Scanner) and puts everything it carries in the home's chests,
  because a turtle crafts from its own inventory and it must hold only the
  recipe. Afterwards the pickaxe goes back on and the table goes in the
  chest with the supplies. Without a crafting table it says so, and when it
  runs out of chests the stop message says there's wood for more.
- **Seeking wood:** with a crafting table (on board, equipped, or in its
  working home), it keeps a stock of wood for chests and torches. While
  the wood and chests at its working home and on board would build fewer
  than 8 more homes (`WOOD_HOMES`), logs and planks (mineshafts are built
  of planks) count as ore of the kind it goes out of its way for, like coal
  and diamonds. Without a Geo Scanner, wood it sees while looking at the
  tunnel's walls, floor and ceiling is followed to the end of its run,
  however far out. With one, wood a scan shows is fetched from anywhere in
  the scan. It reads its working home's chest each time it's there, and
  counts what it carries, so it stops seeking once it has enough. The
  summary at the end says how much wood it dug.
- **Fuel is coal and the like, never wood:** it only burns what turtlelib's
  `T.fuel` lists (coal, charcoal, coal blocks, lava buckets, blaze rods,
  dried kelp blocks). Logs, planks, sticks, chests and crafting tables would
  burn too, but they're what chests and torches are made from.
- **Mineshafts:** rails in the tunnel, its walls or its floor are dug out
  (the wall or floor is filled where they were), and minecarts in its way
  are broken. Both are valuables and come back to the start.
- **Stopping:** it stops when:
  - it runs out of chests for the next home;
  - it doesn't have enough fuel to go on and still get back;
  - a home's chest is full or missing;
  - it reaches something it can't dig through (bedrock).

  Then, or once the tunnel is as long as asked, it walks back to the start.
  On the way it collects the valuables from every home: the most valuable
  first when it can't carry them all (diamonds and netherite before gold
  before iron, and so on), swapping out cheaper things for better ones. It
  leaves what it brings in the top chest at the start, and says what it had
  to leave behind and in which home. The tank always keeps enough fuel for
  this walk back.
- **Resume:** supplies left over stay in the last home. After a stop, top up
  the start's top chest with chests and fuel and run `mine --resume`. It
  carries the new supplies out to the last home and carries on from there.
  On the way out it goes over each segment for repairs, as it does when
  resuming from an earlier home: it walks the floor along the lit wall,
  putting back any torch that's missing and leaving the ones that are there
  alone, and any water it meets (flowing or a source) it follows to where it
  gets into the tunnel and seals there. At each home it passes, bulk in the
  valuables chest goes down into the bulk chest, as on the way back.
  A torch spot that's under flowing water is lit once the water is sealed
  off.
  Run from the last home (where `mine reset` leaves it), it just carries on
  from there. It keeps a log of how far it got with the segment it's
  digging (`mine.seg`: the lane, and the block along it), so it carries on
  from where it stopped. It doesn't dig or look over the lanes it finished
  again. Run from an earlier home (`mine reset --home N`), it goes over the
  segments from that home on, which are dug already, without digging them
  again, and passes the homes already built without building them again.
  Then it carries on past the last one. Use this when part of the tunnel
  has flooded.
- **Fixing water on resume:** water in tunnel it dug before is getting in
  from somewhere. So whatever it goes over again on a resume (the segments
  from an earlier home, and the finished part of the segment it carries on
  with) it walks first along the floor of the middle column (the middle of
  every three, for a wider tunnel; along the lit wall, with lights). Water
  getting into the tunnel from anywhere ends up on the floor and spreads
  across it (up to 7 blocks on the flat, and on down any slope), so it
  reaches the floor it walks. If the middle column's floor isn't dug yet
  (it was stopped partway), it walks a side column's floor that is. If it
  finds water, it walks the floor again, back the other way, to see it's
  dry (twice at most). Only if the floor is still wet after that, because
  it couldn't follow the water up from the floor (a tunnel full of water
  coming in high up), does it walk the other lanes. It follows any water it finds
  to where it comes in, a hole in the ceiling or a waterlogged block say,
  and seals that. It also fills any hole or water in the floor it walks
  over, and puts back torches that were washed away. Once it has sealed
  a leak it waits a moment for what's left to drain, so it doesn't chase
  that. (The turtle stirs water up as it moves: it pushes flowing water
  out of the block it moves into, and a block it leaves between two
  sources becomes one.) To start a fresh tunnel somewhere
  else instead, add `--new`.
- **Haul:** `mine haul` shuttles the valuables in the homes back to the start
  whenever you like. Run it from the start or from the last home. It walks
  out to the last home, then back collecting from every home (the most
  valuable first when it can't carry everything), and leaves them in the
  start's top chest. It repeats until the homes are empty, refuelling from
  the top chest at the start; it stops if there isn't enough fuel for another
  trip. Supplies stay where they are, so `mine --resume` still finds them.
- **Room above the valuables chest:** a chest can't be opened with a solid
  block on top. So the turtle digs out the block above each home's
  valuables chest, from the tunnel row above the home. If that lets water
  in, it steps in and seals what feeds it. Homes built before this get it
  when the turtle next starts from them or passes them on a resume. It
  isn't done for a tunnel 1 high, or one going down, where the bulk chest
  is above the home.
- **Lanes:** each segment is dug in lanes along it: every row of the two side
  columns, and every third row plus the top and bottom ones in the columns
  between. The rows in between are dug from above and below. So the turtle
  touches every block of the walls, floor, ceiling and far end, and looks at
  each one.
- **Veins:** an ore it touches is mined along with its whole vein. That means
  anything tagged as an ore (so modded ores too), any `*_ore` block, and
  ancient debris. The turtle follows the vein block by block, looking all round
  each one. It goes at most 4 blocks (`VEIN_REACH`) out from the tunnel, and
  never back past its start.
- **Lava and water:** a turtle can't be hurt by lava, and only by explosions
  that aren't caused by mobs (TNT, beds in the Nether) if it's a normal turtle.
  But lava burns any item that falls into it, and it makes the tunnel deadly
  for you later. So lava or water touching the tunnel or a vein is sealed with
  a bulk block (the turtle keeps a stack, and fetches more if it runs out).
  Falling gravel and sand are dug until they stop coming.
- **Water in the tunnel:** water can't just be dug out. It flows back into
  an open block from any water beside or above it. A block with two sources
  beside it becomes a source itself. A turtle that moves into a source leaves
  the source behind when it moves on. So the turtle fills a source in the
  tunnel with a bulk block and digs it out. If water comes back (from a lake
  above the ceiling, or an aquifer), something next to that block feeds it.
  The turtle steps in and seals the water touching it outside the tunnel.
  It fills the sources touching it inside, steps back, and tries again.
  Those fillings are dug out again later: ahead by the lanes, behind at the
  end of the segment, by when what fed them is sealed. Flowing water that
  nothing beside it feeds, in tunnel it's digging, is from what it's
  digging through: left over and draining, or from sources the lanes will
  reach. But falling water always has water above feeding it, and water in
  tunnel dug before (going over it on a resume, or on a trip) is getting in
  from somewhere. That it follows upstream through the tunnel to where it
  comes in, and seals. It goes up while the water's falling, else toward
  stronger water, looking ahead, above and below before it turns to look
  sideways. Through dug tunnel it wades through flowing water (the turtle
  pushes it out of the block it moves into) and only looks at the walls,
  floor and ceiling, rather than stepping in and out of each wet block.
  It doesn't put a torch where it has just stepped through water until it
  has stopped the water, so the torch isn't washed away.
- **Hidden water:** a waterlogged block holds water but doesn't look like
  it. Glow lichen, pointed dripstone, hanging roots and sculk veins are
  examples. To the turtle it's just a block, but it's a water source that
  never stops. Water plants (seagrass, kelp) are water too. Thin blocks
  that aren't solid (glow lichen, vines, grass, snow layers) don't keep
  water out either. So any of these in the tunnel's walls, floor or
  ceiling is dug out and replaced with a bulk block, waterlogged or not.
  A scan reports them, so with a scanner it turns to them as it does to
  water.
- **Keeping fluid out as it digs:** a turtle in a block keeps fluid out of
  it, and only a block touching the walls, floor or ceiling can let fluid
  in. Every such block is on one of its lanes, and it only opens them from
  inside: it doesn't clear them from the lane beside. So it's always
  standing in a block when it first opens it to the outside. If the dig
  lets water in, it moves in, pushing the water out, and seals where it
  came from before it spreads. That matters most for lava, which is too
  slow to show up right after a dig. With a scanner, it also seals lava and
  water the scan saw:
  - next to the ways it digs out to veins and to ore further out;
  - next to a torch niche, from inside the niche, before the torch goes in.

  Water washes torches away, and lava burns any item it touches. The ways it dug out to veins are sealed too if
  water got into them. In tests through an underground lake and under one,
  it left the tunnel dry with nothing leaking in.
- **Trips home:** before a dig with fewer than 2 empty slots, or a move that
  would leave too little fuel, it goes to its home. There it sorts its
  inventory into the two chests (tidying the valuables chest), refuels, and
  comes back to the same spot, up the vein if it was in one. It only travels
  through blocks it has already dug, so nothing is dug, and nothing can
  spill, on the way. It never drops items on the ground. Whenever a slot
  fills, it first merges part stacks of the same item, which often saves
  the trip (see [Library](#library)). It carries up to 32 fuel items (coal)
  from its home and burns them as it goes, so a low tank seldom means a
  trip; the fuel it carries counts whenever it works out whether it can
  afford a trip. It also carries 64 bulk blocks for sealing, or 192 once
  drying out water has used them up. Resumed from the start of a long
  tunnel, it fills its tank from the start's chest for the walk out to the
  last home and back before setting off. Resumed from an earlier home than
  the last, it first fetches fuel from the last home, where the supplies
  are. Going on to a home that's already built only needs the fuel to get
  there, since the supplies are there.
- **Geo Scanner:** put an Advanced Peripherals Geo Scanner in the start's
  top chest and the turtle takes it along and uses it instead of checking
  every wall block by hand. There's no slot to spare for it: one side holds
  the pickaxe, the other the chunk controller. So every 15 blocks it swaps
  the scanner in for the pickaxe, scans, and swaps back. The chunk
  controller never moves, so its chunk stays loaded. With the scanner:
  - **Lining up:** a scan reports blocks along the world's directions
    (north, east...), which a turtle doesn't know. So the turtle tries all
    four ways round, and keeps the one that puts none of the scanned blocks
    where it knows it has already dug. A scanner that gives offsets from
    the turtle's own facing (Advanced Peripherals 0.8) needs no lining up.
    It's only skipped as "heading looks off" if another heading would fit
    the dug blocks far better. Water and lava don't count, since what it
    dug can fill with them, and a few stray blocks (fallen gravel) don't
    matter.
  - **Walls and veins:** it only turns to look at blocks the scan says are
    ore, lava or water, both in the walls and round each block of a vein.
    In tests it turned about a fifth as often.
  - **Ore further out:** right after each scan, it collects what that scan
    found. It tunnels out to ore up to 6 blocks from the tunnel
    (`SCAN_REACH`) and mines the whole vein, then goes on with the tunnel.
    It goes from one deposit straight to the nearest one left, rather than
    back to the tunnel between them. It goes back only part of the way it
    came, or back to the tunnel, when that's shorter (digging counts double,
    since a step through what's dug is quicker). It steps the way it already
    faces where it can, and backs out of dead ends without turning round. It
    refills any floor it dug through, and seals lava on the way.
  - **Diamonds and coal:** it always mines any diamond or coal a scan shows,
    however far out: diamonds for their worth, coal because it's the
    turtle's fuel. Otherwise it goes no further than the scan reached (8
    blocks along any direction from where the scan was taken). The exception
    is a diamond or coal vein: that's followed to its end, past the scan if
    need be. With or without a scanner, a diamond or coal vein the turtle
    finds is always followed all the way.
  - **Coal first when fuel is low:** when its fuel gets low, it fetches the
    coal a scan found first, and burns it.
  - **Cost:** scans are radius 8, which costs no fuel (Advanced Peripherals'
    defaults: free up to 8, 2 seconds between scans).

  At the end the scanner goes back into the start chest with the valuables.
- **A floor you can walk on:** the turtle doesn't need a floor, but you do.
  Every block under the tunnel's bottom row is filled with a bulk block if
  it's any of these:
  - a hole: a crevasse, a cave, or where ore in the floor was mined out;
  - lava or water;
  - something you shouldn't stand on: grass, snow, cobwebs, pointed dripstone.

  A crevasse across the tunnel gets a bridge one block thick. The turtle tops
  its stack of bulk blocks up from each home's bulk chest, and goes back for
  more if it runs out halfway across. Openings in the walls and ceiling (into
  caves) are left open, apart from lava and water.
- **Lighting:** given torches, the turtle lights the tunnel so mobs can't spawn
  on its floor (since 1.18 they need block light 0), using as few torches as
  that takes:
  - It aims for light 2 or more on every floor block, one level of margin.
  - Each torch goes in a niche it digs into the wall at floor level, beside its
    start column, outside the tunnel, so the turtle never digs it up again.
  - A 3-wide tunnel gets one every 19 blocks; narrower tunnels need fewer.
  - Wider than 8, both walls get them.
  - A torch that would land on a home's wall chest moves one block along.
  - If a niche opens into a cave, with nothing behind or under it to hold a
    torch, the turtle steps into the niche, puts a bulk block under it, and
    stands the torch on that.
  - Torches are supplies: they move forward with the homes, and it keeps up to
    64 on board.
  - Lighting is optional. With no torches it says so once and keeps mining.
    `--no-lights` turns it off altogether; torches are then treated like any
    other valuable.
  - Light doesn't stop slimes, which spawn in slime chunks at any light level.

  Torches *you* place inside the tunnel get dug up wherever the turtle's path
  crosses them. That's everywhere in the stretch it's still digging, and the
  start column's bottom row on its way back. It keeps them and reuses them.
  Behind it, torches higher up the walls are safe.
- **Never dug:** chests, barrels, shulker boxes, spawners and ComputerCraft
  blocks (other turtles, computers).
- **Reset:** position is saved after every move. After a Ctrl+T or a server
  restart, `mine reset` brings the turtle to the **last home it built**, even
  from inside a vein: it digs straight back into the tunnel, then follows it.
  From there `mine --resume` carries on, or `mine haul` brings the valuables
  back. `mine reset --home N` goes to home N instead (0 is the start; homes
  are numbered from the start, every `--spacing` blocks), and
  `mine reset --to-start` all the way back to the start.
  It only counts as arrived if the home's chests are there; if not, its
  saved position or heading must be wrong and it stops and says so.
  - **Ctrl+T is safe:** a turtle command (a move or a turn) waits for the
    game to do it. A plain Ctrl+T in that wait stops the program, but the
    turtle still moves or turns, without the program recording it. So `mine`
    holds a Ctrl+T back until the move or turn is saved (`T.run` in
    turtlelib).
  - **Checking its heading:** before setting off, `mine reset` looks all
    round. It compares what it sees with what it knows of the tunnel there:
    finished segments are dug, walls are solid. If exactly one way round
    fits, it goes by that.
  - **Stopping if lost:** if the way back starts digging through far more
    rock than it should, its position or heading must be wrong, so it stops
    instead of wandering off.
  - **Recovering by hand:** give it a label (`label set miner`, or it loses
    its files when picked up). Empty it, pick it up, and place it back at the
    start, facing down the tunnel. Then run `mine reset --here`.

A second turtle working as a courier is planned: it would shuttle between
the start and the newest home, bringing chests and fuel out and valuables
back, so the miner can go on for as long as the start is kept stocked.

## claude

```
claude [goal words...] [--model id] [--effort low|medium|high] [--steps N] [--confirm]
claude dig a 3 by 3 tunnel 20 blocks ahead and come back
```

Claude (the model, over the Anthropic API) drives the turtle. It gets one
tool that matters, `lua`: the code it writes runs on the turtle with
`turtle`, `peripheral` and `turtlelib` as `T` in scope, and whatever the
code prints or returns goes back to it. Two more tools: `status` (where it
is, fuel, what's in front, above and below, the inventory) and `ask_user`
(it asks you at the keyboard). It works at the goal call by call, says what
it did when it stops, and then waits for the next thing to do; an empty
line quits. When more comes out than fits on the screen, it opens in the
pager before the next prompt, at the first line you haven't seen (the
mouse wheel, arrows or space to scroll, `q` back to the prompt); at an
empty prompt the wheel up or PgUp opens the whole session. On an advanced
computer or turtle the output is in colour: the code it runs highlighted
as in `edit`, what the code prints in grey, prompts in yellow, errors in
red, and the pager shows it in the same colours. Ctrl+T stops it, and because it runs under `T.run` the saved
position stays right, so `home` works afterwards. It picks up `.turtlepos`
from the last job if there is one; otherwise where it starts is `(0,0,0)`
facing `+z`.

Setup:

- Put an API key in `claude.key` next to the program (`edit claude.key`,
  paste, save). Make it a key of its own with a spending limit: anything on
  a computer's disk can be read by whoever can open the turtle or the
  server's save folder. The file is in `.gitignore` and `git pull` never
  touches untracked files.
- The server's CC:Tweaked config must let HTTP reach `api.anthropic.com`,
  the same `http.rules` allow-list that lets `git` reach your host.

Each tool call is one API round trip carrying the whole conversation, so a
long job is many calls; the system prompt and tools are marked for prompt
caching, and the token totals are printed when a goal ends. The defaults
are `claude-opus-5-5` at `medium` effort and at most 60 tool calls per goal
(it's then told to stop and sum up); `--confirm` shows each piece of code
and asks before running it. A refusal by the model's safety classifiers is
retried server-side on a fallback model (the API's `fallbacks: "default"`),
so an odd phrasing doesn't end the job. Replies are streamed, with the
thinking summarised as it goes (it's written to `claude.log`): CC gives up
on a request after 60 s with nothing coming in, at most, and a long think
sent as one reply would be that long a silence. The code it runs can read any file
but the API key (through `fs`, `io`, `loadfile` or `dofile`), write only
under `/claude/` (its notes, maps, programs between goals), and `require`
CraftOS's `cc.*` modules (`cc.strings`, `cc.pretty`, `cc.base64`,
`cc.expect`, `cc.completion`, `cc.shell.completion`, `cc.image.nft`,
`cc.audio.dfpwm`, `cc.require`); it can't reach `http` or `shell`, so a
slip can't leak the key or rewrite the programs. Everything it reads goes
to the API, so keep secrets other than the key (a `.gitlite` with a
token) off the turtle. It can do anything the turtle can, though, so keep valuables out of reach
the first few times, and `claude.log` keeps every piece of code it ran
and what came back.

## autocompost

```
autocompost
```

Put the turtle directly **on top of a composter**, with a **hopper under the
composter** to take the bone meal out. Fill the turtle with anything; it never
moves. It drops compostable items in one at a time (a composter only takes one
per drop), waits while the composter is full and turning to bone meal, and when
it has nothing left to compost it sleeps until you give it more.

- What's compostable is learned, not listed, so modded items work too: an item
  the composter refuses while it isn't full isn't compostable. Those go into a
  chest **in front of the turtle** if there is one, otherwise they stay in the
  turtle.
- If the composter stays full for 10 seconds it asks whether the hopper below is
  full or missing, and keeps waiting.
- To start it at boot: `deploy/install --autostart autocompost` (or `set
  ccnix.autostart autocompost`; see [Autostart](#autostart)).

## Network

```
ip                                 what's set up, and whether it's up
ip help                            the commands; words cut short as far as they're clear: ip a, ip r a ... v ...
ip addr add <iface> <addr/len>     ip route add <net/len|default> via <gw>
ip up | ip down | ip boot          ip link | ip neigh | ip forward on|off | ip host <name> <addr>
ip rpfilter strict|loose|off       (on a router: which sources it passes on, BCP 38)
ip dns <primary> [<secondary>]     host name | host address    (DNS)
ping [-c n] [-t ttl] [-I if] host  traceroute [-n] host
tcpdump [-env] [-i iface] [expr]   the frames on the wire, in and out (tcp port 23, icmp or arp...)
nc host port | nc -l port          (TCP)    nc -u host port | nc -u -l port   (UDP)
router                             (on a router: forwarding on, and a status screen)
```

A small network stack over ComputerCraft modems, built in layers as the
real thing is, so networks can be joined by routers instead of every
computer hearing everything (as with rednet):

- **Link (layer 2):** an interface is a modem by its peripheral name
  (`back`, `top`, `modem_0`), wired or wireless. It sends and listens on
  channel 60000, which works like an Ethernet segment: every computer on
  that wire (or in wireless range) hears a frame, and only the one it's
  addressed to takes it. A MAC address is a locally administered one,
  `02:cc:` then the computer's ID in three bytes and a port byte: top 0,
  bottom 1, left 2, right 3, front 4, back 5, a remote `modem_N` 6 + N
  (computer 12's back is `02:cc:00:00:0c:05`). VLANs share their modem's
  MAC. `02:cc:ff` is the mod's (the gateway is `02:cc:ff:00:00:00`);
  broadcast is `ff:ff:ff:ff:ff:ff`.
- **VLANs:** `back.20` is VLAN 20 on the back modem: channel 60000 + 20, a
  network of its own on the same wire, that the untagged one (and every
  other VLAN) doesn't hear. One modem can carry several networks: a router
  with `back.10` and `back.20` routes between two VLANs on one cable (a
  trunk). VLANs 1-4094.
- **ARP:** to send to an address on its own network, a computer asks "who
  has 10.0.1.5?" (a broadcast) and the owner answers with its MAC. Answers
  are kept 5 minutes. No answer after 3 tries a second apart: "host
  unreachable".
- **IP (layer 3):** addresses as `10.0.1.5/24`. Each interface's own
  network is routed directly; other networks by static routes (`ip route
  add 10.0.3.0/24 via 10.0.1.1`, or `default via ...`), the longest prefix
  winning. A packet carries a TTL (64), one less at each router. A router
  (`ip forward on`, or `router`) passes on packets for other addresses;
  a host takes only its own, `127.x.x.x`, and broadcasts
  (`255.255.255.255`, or its network's last address). `255.255.255.255`
  never crosses a router; a broadcast addressed to another network's last
  address is routed there and broadcast on arrival. A packet from a source
  that can't be real (`0.x`, `127.x`, `224.x` and up, the network's
  broadcast address, the computer's own) is dropped, and a router passes a
  packet on only if its source passes the reverse-path filter, as BCP 38
  asks (`ip rpfilter`): *loose*, the default, wants a route back to the
  source; *strict* wants that route to leave by the interface the packet
  came in on, which stops a network's hosts forging another network's
  addresses, but breaks asymmetric routing (where the way back isn't the
  way in); *off* passes anything. Forged
  packets are dropped silently, never answered with an ICMP error.
- **ICMP:** echo and reply (`ping`), destination unreachable (no route:
  *net*, from the router that has none; no ARP answer: *host*; no program
  on that UDP port: *port*), and time exceeded when a TTL runs out (a
  routing loop; `traceroute` uses it to list the routers on the way).
- **UDP (layer 4):** datagrams between ports. A datagram can carry anything
  a modem can: a string, a number, a table. In Lua:

  ```lua
  local net = require("net")            -- lib/ on package.path
  local sock = net.udp(7)                -- port 7 (nil: any free port)
  local data, from, port = sock:receive(5)   -- nil after 5 s
  sock:send(from, port, data)            -- echo it back
  ```
- **TCP (layer 4):** connections carrying bytes, in order, sent again until
  they're acknowledged: the least of real TCP (RFC 9293) that still works
  with a real TCP stack. Sequence numbers count bytes, segments are at
  most 536 bytes, the receiver advertises a 4 KB window, anything that
  arrives out of order is dropped and sent again, the wait before sending
  again doubles each time, keepalive probes find a side that's gone (about
  40 s), and each side closes its half on its own. `nc host port` and
  `nc -l port` use it; in Lua:

  ```lua
  local conn = net.connect("10.0.2.5", 23)   -- or net.listen(23):accept()
  conn:send("hello\r\n")
  local s, why = conn:read(5)            -- what came; nil and "closed" at the end
  conn:close()
  ```
- **Names (`lib/netdb.lua`):** C's `netdb.h` in Lua: `getaddrinfo`,
  `getnameinfo`, `gethostbyname`, `gethostbyaddr`, `getservbyname`,
  `getservbyport`, `gai_strerror`, and `res_query` for DNS alone. A name
  is looked up as `hosts: files dns` would: the host database first
  (`net.hosts`, set with `ip host`, and `localhost`), then DNS, through
  the servers `ip dns` sets (`net.dns`: a primary and, optionally, a
  secondary). A question goes to the primary. If it doesn't answer in 2 s,
  sends back an ICMP error or answers SERVFAIL or REFUSED, the secondary
  is asked, and for the next minute the secondary goes first. A "no such
  name" answer is final. Answers are kept for their TTL (5 minutes at
  most). With no servers set, the host database is all there is. The DNS
  is the least of RFC 1035: A, CNAME and PTR records over UDP, recursion
  asked of a real resolver (reached through the mod's gateway). `ping`,
  `traceroute`, `nc` and `telnet` take names (nc and telnet take service
  names for ports too, `nc host http`), and so does `net.connect`;
  `traceroute` shows each hop's name (`-n`: addresses only); `host` asks
  DNS by hand. In Lua:

  ```lua
  local netdb = require("netdb")
  local ai, why = netdb.getaddrinfo("example.com", "http", { socktype = netdb.SOCK_STREAM })
  local conn = ai and net.connect(ai[1].addr, ai[1].port)
  local name = netdb.getnameinfo("1.1.1.1")   -- "one.one.one.one"
  ```
- **Watching it:** `tcpdump` prints a line for each frame on the
  interfaces, in and out (Ctrl+T stops): ARP, ICMP, UDP, and TCP with its
  flags, sequence numbers counted from each side's first, ack and window.
  A modem hears every frame on its channel, so it shows other computers'
  frames on the wire too (`-p`: only this computer's). An expression picks
  the frames as tcpdump's does (`tcpdump -n tcp port 23 and not host b`);
  `-e` adds the MACs and VLAN, `-v` the TTL and ID, `-x` the frame as Lua;
  `-w file` keeps the frames and `-r file` prints them again (a Lua table a
  line, not pcap). With the network down, `tcpdump -i back` listens on the
  modem's channel itself. In Lua, `S.taps[key] = fn(dir, iface, frame)`.

**Bridging to a real network:** packets are Lua tables, but each field is
the real header's (IP addresses as numbers, TCP's seq, ack, flags, window
and payload bytes), so a bridge can turn them into real IPv4 and back. The
header of `lib/net.lua` lists the mapping. Only string payloads can cross:
UDP datagrams carrying tables stay in ComputerCraft.
The ccnix mod, ccnix-mod ([mod/](mod/), a submodule), is that bridge. It
adds a Network Gateway block for CC cables, with an address on its network
(`10.0.0.1/24`). Routers on the cable route at it. Behind it, one of two
modes, the server admin's choice:
- **NAT** (the default): the server process carries CC computers' TCP and
  UDP as its own connections, with nothing to set up. Ping and traceroute
  stop at the gateway ("administratively prohibited"); private addresses and port 25
  are refused; the outside gets in only through port forwards
  (`/ccnix forward`); `ip dns 10.0.0.1` asks the server's resolver.
- **TUN**: a TUN device on the server (Linux) carries their packets as
  real IPv4: a real machine can `telnet` to a CC computer, and CC computers
  reach whatever the server reaches.

Either way it only carries packets; everything above TCP and UDP is done
by the programs here. Its README has the server's setup.

ccnix-mod has this repo as a submodule too (`ccnix/`, the ROM it builds).
So `mod/` is set `update = none`, which keeps recursive submodule commands
from going round for ever. `git submodule update --init --checkout mod`
gets it. A device's `git clone` never fetches it: the submodule is a link,
not files.

**How it runs:** a plain computer can't run programs in the background, so
`ip up` hooks the network into `os.pullEventRaw`, which every program's
`os.pullEvent`, `sleep`, `read` and `parallel` go through. The network is
handled (ARP answered, pings replied to, packets forwarded, datagrams put
in sockets) whenever anything on the computer waits for an event, which is
nearly always, and `ip up` returns at once: the shell, ccsh, a farm or
the router's screen carry on as usual. A program that computes for a long
time without waiting holds the network up meanwhile. `ip boot` sets the
setting `net.boot`, which startup goes by to bring it up at every boot.

**Setting up two networks and a router**, for example:

```
-- the router, with a wired modem on each network (back and right):
ip addr add back 10.0.1.1/24
ip addr add right 10.0.2.1/24
router boot
router

-- a computer on the first network:
ip addr add back 10.0.1.5/24
ip route add default via 10.0.1.1
ip boot
ip up

-- and one on the second:
ip addr add top 10.0.2.7/24
ip route add default via 10.0.2.1
ip boot
ip up
ping 10.0.2.7          (from 10.0.1.5: through the router, TTL 63)
traceroute 10.0.2.7
```

What's set is kept in settings (`net.if.<iface>`, `net.routes`,
`net.forward`, `net.rpfilter`, `net.hosts`, `net.dns`), and changes apply at once while
it's up. `ip host router 10.0.1.1` lets `ping router` work; with a way out
(the gateway), `ip dns 1.1.1.1 9.9.9.9` lets real names work too. There's
no DHCP: addresses are set by hand. `help network` on a computer walks through a lab
of three computers, two networks and a router (with the one-cable VLAN
variant and what to look at when it doesn't work); it's `doc/network.txt`.

## Telnet

```
telnet host [port]          another computer's shell or screen, here (Ctrl+] then q leaves)
telnetd                     the server: run it as a service (setup telnetd does)
```

`telnetd` serves Telnet on port 23 over [TCP](#network), so any telnet
client can use it as well as ours. After the password, a connection gets
a shell of its own, sized to the client's screen (ccsh if
`ccsh.login` is on, else the CraftOS shell), or, with `telnetd.attach`
set to `console`, the computer's console, whatever runs there: the miner's
or the farmer's screen, which you then see and type into as if you were
standing at it. On the console Ctrl+T isn't passed on, so a stray one
doesn't stop the miner. Our client's Ctrl+] then t (Telnet's "interrupt
process") does stop it.

The screen goes as ANSI escapes in xterm's 256 colours, a row at a time
as it changes. CC's Latin-1 characters go as UTF-8, and its block
graphics as Unicode's sextants. Keys come back as a terminal sends them:
arrows and the rest, Ctrl+letters, pastes and the mouse. The client
(`telnet`) is that terminal on a CC screen, with greys for colours on a
basic computer.

Settings: `telnetd.password` (typed at `Password:`; it crosses the
network as typed, as with any telnet); `telnetd.open` (`true`: no
password); `telnetd.attach` (`console`, or unset for a shell each);
`telnetd.port` (23). telnetd needs [init](#processes-and-services), which
runs the shells, and the network up. `setup telnetd` sets it all up as a
service started at boot; then `set telnetd.password ...`. `service status
telnetd` shows who has connected.

## Processes and services

```
ps [-l]                            the processes: ID, terminal, state, time, command
kill [-s signal | -9] pid...       signal one: TERM (Ctrl+T for it), KILL, INT, HUP
service                            the services, and whether they're running
service add <name> <command...>    service start|stop|restart|status <name>
service enable|disable <name>      at boot, or not
init boot [off]                    init at every boot (deploy/install --init does it too)
```

CraftOS has no processes: a program is a coroutine its shell resumes, and
only an advanced computer's multishell runs more than one at a time.
`init` is a small kernel in the same spirit, for every computer and
turtle. With `init.boot` on, startup runs it last, and from then on it
runs everything:

- **Processes:** each program is a coroutine with a process ID, its own
  terminal (the screen's, or a hidden one) and its own environment
  (`os.getenv`), resumed with the events it waits for. The keyboard and
  mouse go to the console's process; every other event (timers, modems,
  redstone) to every process. A command runs in a CraftOS shell of its
  own, with the usual path, aliases and directory.
- **The console:** the autostart first, if `ccnix.autostart` names one
  (the miner, the farmer, the router's screen), then ccsh if
  `ccsh.login` is on, then the CraftOS shell, each when the one before
  ends. Leaving that last shell shuts the computer down, as leaving
  CraftOS's does.
- **Services:** commands kept running in the background, each in a hidden
  terminal (`service status` shows the last of what it printed). One that
  ends is started again after 1 s, 2 s, 4 s and so on, up to a minute
  (back to 1 s once it has run for 30 s). A service is three settings:
  `service.<name>.cmd`, `service.<name>.enabled` (start at boot) and
  `service.<name>.restart` (`always`, or `no`).
- **Programs** reach it through `_G.proc`: `proc.spawn{cmd = "..."}`,
  `proc.kill(pid)`, `proc.list()`, `proc.self()`, `proc.wait(pid)`,
  `proc.inject(pid, event, ...)` (an event for one process alone),
  `proc.term(pid)` (its terminal: `getLine` reads it back).

ccsh's `&` jobs belong to the shell: they end with it. A service is
the way to keep something running. Under `init`, ccsh numbers its jobs
with process IDs no process will get, and its `kill` passes any other
number on to `init`. As in CraftOS, a program that computes for a long
time without waiting for an event holds everything up meanwhile.

## fileserver

```
fileserver                 what's in the pool: each disk, its space, the total
fileserver mount           put the pool at /jbod
fileserver add <drive>     make a disk that has files on it part of the pool
fileserver startup         mount it at every boot
```

Puts the floppies in every disk drive a computer can reach together as one
folder, `/jbod` ("just a bunch of disks"). Drives count whether they're
beside the computer or on a wired network: put a wired modem on each drive
and on the computer, join them with networking cable, and right-click each
drive's modem to connect it (`peripherals` lists them as `drive_0`,
`drive_1`...).

- **Size:** a floppy holds 125,000 bytes (the server's
  `floppy_space_limit`), and CC charges every file and folder at least
  500 bytes, so four drives give about 500 KB. `fileserver` shows each
  disk's free space and the total; `fs.getFreeSpace("/jbod")` and
  `fs.getCapacity("/jbod")` give the pool's.
- **It grows by itself:** a blank floppy put in any drive joins the pool
  (labelled `jbod` if it has no label), and the pool looks for drives and
  disks again at most once a second, so a drive added or a disk put in is
  in `/jbod` straight away. A disk with files on it is left alone until
  `fileserver add drive_N`; then its files join the pool where they are.
  Each member has a `.jbod` file at its root.
- **How files are kept:** folders are shared: a folder is in the pool if
  it's on any disk, and lists what's in it on all of them. A file goes on
  the disk with the most room when it's written; one too big for any
  single disk is split across several (the first part at its path, the
  rest in `.jbod.parts/` on the others). A file is written when it's
  closed, held in memory until then, so it goes where it fits as a whole;
  writing more than the pool has room for is an "Out of space" error with
  nothing half written.
- **How it works:** ComputerCraft can't mount a file system from Lua, so
  `fileserver mount` changes the computer's `fs` functions in place: a
  path under `/jbod` goes to the pool, and every other path where it always
  did. Every program, `io`, `edit` and tab completion see it, until the
  computer reboots; `fileserver startup` adds the mount to startup.
- **Taking a disk out** takes its files with it until it's back, and a
  split file with a part on it says so when opened. The disk is still an
  ordinary floppy with ordinary files on it. Files written straight onto
  a member's own mount (`/disk2/...`) are in the pool too.
- **The members' own mounts are hidden:** with the pool mounted, `ls`
  treats `/disk`, `/disk2`... of member disks like dot files (`ls -a` or
  `ls -A` shows them), and ccsh's `*` and `?` skip them unless the
  pattern starts with a plain character (`disk*` matches them, `*` doesn't),
  as `.*` is needed for dot files. A disk that isn't a member shows as
  usual.

## diskclone

```
diskclone <dir> [count] [--force]
```

Runs on an ordinary computer (not a turtle) with a **disk drive on its bottom**
and a **dispenser wired to its back**. Each cycle it sends a short redstone pulse
out the back, the dispenser drops one floppy into the hopper that feeds the
drive, and the program copies `<dir>` onto the disk, labels it and ejects it into
the collecting hopper. It keeps going until no disk arrives (the dispenser is
empty) or `count` disks have been written.

- `<dir>` must have a file named `LABEL` in its root. Its first line becomes each
  disk's label; `LABEL` itself is not copied.
- A disk that already has a label or any files on it is ejected without being
  written. With `--force` it is wiped and written like a blank one.
- Anything that isn't a floppy is ejected untouched.
- Each copy is checked against the source (same files, same sizes) before the disk
  is labelled. If the directory doesn't fit on a floppy, it stops at the first
  disk without touching it.

## Library

`turtle/turtlelib.lua` is self-contained. A program next to it in
`turtle/` just requires it (CC's `require` looks in the program's own
folder first). A minimal program:

```lua
local T = require("turtlelib")
T.cfg.width, T.cfg.length = 10, 10
T.step = T.stepTerrain          -- or T.stepFlat for a fixed height
T.diggable = { ["minecraft:short_grass"] = true }

for _, t in ipairs(T.serpentine()) do
    if T.goTo(t.x, t.z) then T.settle() end
end
T.goTo(0, 0)
```

Everything is relative to the start: `(0,0,0)` facing `+z`, `+x` to the right.

A turtle puts what it picks up into the first slot, counting on from the
selected one, that is empty *or* holds the same item. So an empty slot ahead
of a part stack starts a second stack of that item. `T.tidyInventory()`
merges part stacks of the same item, moves part stacks into empty slots
ahead of them, and selects slot 1, so the next pickup joins its stack. It
costs nothing when there's nothing to do. `T.ensureRoom` and `T.dumpDown`
call it, so mow and farm tidy before every tile and after emptying, and the
miner does whenever a slot fills. Each move between slots takes as long as a
step (moves, turns, digs and transfers all take 8 ticks).
`T.goTo` learns obstacles as it bumps into them and re-plans with BFS; it returns
`false` only when no route exists through the known map.

Beyond columns, the library has six directions: `0..3` as `T.dir` plus
`"up"` and `"down"`. `T.look(d)`, `T.digDir(d)`, `T.placeDir(d)`,
`T.attackDir(d)`, `T.suckDir(d)` and `T.moveDir(d)` face `d` first (up and
down need no turn); `T.turnsTo(d)` says how many turns that takes,
`T.eachAround(skip, fn)` goes round the turtle fewest turns first,
`T.stepToward(p)` picks the step toward a position that turns least.
Positions are `{ x, y, z }` tables: `T.here()`,
`T.at(p)`, `T.neighbour(d)`, `T.dirTo(p)`, `T.dist(a, b)`, `T.posKey(p)`.
Chest sides are CC's `"front"`, `"top"` and `"bottom"`: `T.dropSide`,
`T.suckSide`, `T.inspectSide`, `T.containerOn(side)`, `T.sideDir(side)`.
Items are named or picked by a test: `T.selectItem(what)`,
`T.countItem(what)` and `T.findSlot(what)` take a name or a
`function(name, item)`; `T.containerCounts(side)` gives everything a chest
holds; `T.findTool("_pickaxe$")` finds the equipped or carried tool.
`T.hasFuel(n)` is the "unlimited or at least n" check, `T.setDir(d)` fixes
a heading a program has worked out, `T.lookAround()` turns on the spot to
see all four sides, and `T.sortedKeys(t)` gives a table's keys in a set
order (so what a program does doesn't depend on `pairs`).

### Big programs: no top-level locals

`mine.lua` and `farm.lua` start with

```lua
local _ENV = setmetatable({}, { __index = _ENV })
```

and then define everything at the top level as plain names: `function
go(d)`, `SCAN_RADIUS = 8`, not `local`. Those go into the file's own
table (which falls back to the shell's environment and `_G` for
everything else), so they cost no local-variable slots, and inside the
file they read exactly as before. The reason is a quirk of CC's Lua: it
counts every local still in scope in the enclosing functions against the
200 a function may have, where standard Lua counts each function on its
own. A 2,000-line program with 180 top-level locals leaves 20 for every
function inside it, and `mine.lua` hit that. `python sim/run.py --check`
counts the way CC does and fails a file before a turtle would. Write new
programs of any size this way; small ones can stay as they are.

### Programs in bin/

CC's `require` looks in the running program's own folder, so a program in
`bin/` that uses a module in `lib/` adds that folder to its search path
first, in one line before the first `require`: ccnix's `lib/` when the
ROM's boot has set `ccnix.lib` (the updates in `/ccnix` first, then the
ROM's), else the one beside `bin/`:

```lua
package.path = (ccnix and ccnix.lib or "/" .. fs.getDir(fs.getDir(shell.getRunningProgram())) .. "/lib/?.lua;") .. package.path
local cu = require("cu").init("cat", "cat [-u] [file...]")
```

## Simulators

`sim/` holds offline simulators: each sets a scenario up in a mock world
(a farm, rock to tunnel through, a composter, a CraftOS computer with its
shell), runs the real program and prints what happened. `python
sim/run.py` runs them all (`pip install lupa` first); `sim/runsim` runs
them on a CC computer, and `sim/watchsim` plays one out on a monitor.
[sim/README.md](sim/README.md) says what each covers and what to build.
They're tests for the code, not for the game: the mock world only models
the vanilla mechanics the programs rely on, so confirm anything new in
game too.

## License

BSD 3-Clause, copyright (c) 2026 Dan Theisen <dan@wi7fi.dev>. See
[LICENSE](LICENSE).
