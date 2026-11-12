# Simulators

Offline tests for the programs: the turtle's, the utilities, the network,
init and telnet. Each `.lua` file here is a
scenario: it sets up one of the mock worlds in `lib/`, runs the real
program from the repo (`turtle/`, `bin/`, `pc/`), and prints the program's output plus a summary
of the world afterwards (lanes, crops, chest contents, moves). The mocks
replace the CC:Tweaked APIs the programs use (`turtle`, `peripheral`,
`fs`, `sleep`, `os.pullEvent`, ...) around a small block world in memory;
nothing is written to disk.

```
pip install lupa
python sim/run.py                  # all of them, then an ok/ERROR summary
python sim/run.py farm_clone       # by name, ".lua" optional
python sim/run.py --check          # syntax-check the programs and these files
```

`--check` also counts locals as CC's Lua does (`locals.py`): no function
may have more than 200 in scope, counting those of the functions around
it, so a big program's top-level locals use up the allowance of every
function inside it. Standard Lua counts each function on its own, so the
simulators never hit this; on a turtle the program won't load. It warns
within 15 of the limit. `mine.lua` and `farm.lua` stay far under it by
defining their top-level names in a private `_ENV` table instead of
locals (see the README's Library section).

The help files in `help/` are made from each program's top comment by
`python sim/mkhelp.py`; `--check` fails if one is out of date, so change
the comment and run it again rather than editing `help/`. The same goes for
`help/turtlelib.txt` and `turtle/tl/index.txt` (one line a function, for claude's
system prompt), made from the comment above each `function T.name(` in
`turtle/turtlelib.lua` and `turtle/tl/*.lua`; `--check` also fails for a
public function with no comment, or an index line over 260 characters. Topics that
aren't a program's (`help network`) are written by hand in `doc/<topic>.txt`
and copied in as they are.

Or on a ComputerCraft computer or turtle, no Python needed. A clone
leaves sim/ out, so name what the simulators need:

```
wget https://raw.githubusercontent.com/djt-code/ccnix/main/bin/git.lua /git-boot.lua
git-boot clone https://github.com/djt-code/ccnix /ccnix --only sim/ --only turtle/ --only bin/ --only lib/
rm git-boot.lua
cd /ccnix
```

That's about 890 KB, and the logs of a full run another 140 KB, more than
CC's default 1 MB disk: raise `computer_space_limit` in the server's
`computercraft-server.toml`, or take just what the watched ones need
(about 670 KB): `--only sim/ --only turtle/turtlelib.lua --only
turtle/farm.lua --only turtle/mine.lua --only bin/git.lua`.
`bin/git pull` updates it.

```
sim/runsim                         # all of them, then a summary
sim/runsim farm_clone              # by name
sim/runsim --list                  # what there is
```

`runsim` runs each simulator in a sandbox (`lib/sandbox.lua`: its own globals, its own `os`,
its own `loadfile`/`require`), so the mocks never touch the real computer,
and yields about once a second so CC doesn't stop it for running too long
without yielding. Full output goes to `sim/logs/<name>.log`; the screen
scrolls it past as it runs. Ctrl+T stops it.

## Watching one on a monitor

`sim/watchsim <name>` plays a simulator out move by move on an attached
monitor:

- for a farm, a **top-down view** of it (+z up the screen, +x to the
  right), the turtle as a yellow arrow;
- for the mine (`mine_tunnel`), a **plan** instead: a level slice through
  the rock at the turtle's height, so you see the tunnel open up lane by
  lane and the turtle wander off into ore veins;
- a **side view**, a slice through the turtle's current x (z across, y up),
  so you see it dip into lanes, dig and climb. For the mine, both views
  follow the turtle along the tunnel;
- the move count, position, facing and fuel, and the program's own messages
  as it prints them. The computer's screen shows the simulator's report.

Keys on the computer: **space** pause/resume (or tap the monitor),
**right** one move while paused, **up/down** faster/slower (from 1 s down
to one move per tick), **f** skip to the end of the current farm run,
**q** quit. `sim/watchsim` on its own lists the simulators it can show
(those built on `farmworld` or `mineworld`: the farm ones, `mine_tunnel`,
`turtlelib_refuel`, `claude_drive` and `mow_lawn`; the others have no
world to draw).

What to build:

- An **Advanced Computer** (or advanced turtle) with the simulators on it
  (the clone above, which needs HTTP enabled on the server).
- An **Advanced Monitor** wall: plain monitors have no colour, and the
  views rely on it. Monitors join into one screen when placed edge to edge
  in a flat rectangle. Size it for the largest farm you'll watch (the
  viewer runs at text scale 0.5):

  | Simulators | Needs (characters) | Smallest monitor |
  |---|---|---|
  | `farm_reset` (5x22) | 65x27 | 4 wide x 3 tall |
  | `farm_clone`, `farm_clone_lane_fallback`, `farm_fuel` (7x16) | 57x21 | 3 wide x 2 tall |
  | `farm_pass_moves` (9x8) | 45x15 | 3 wide x 2 tall |
  | every other `farm_*` (5x6) | 33x15 | 2 wide x 2 tall |
  | `mine_tunnel` (follows the turtle) | 51x20 | 3 wide x 2 tall |

  **4x3 (78x38) shows all of them, with room for plenty of the
  messages; 3x2 shows all but `farm_reset`.** The mine's views grow with
  the monitor: a bigger one shows more of the tunnel at once. A monitor that's too small gets a message naming the
  size to build.
- Put the monitor against any side of the computer, or connect it with
  wired modems (right-click each modem to connect it). With more than one
  monitor attached, name the one to use: `sim/watchsim farm_clone
  monitor_0`.

What the colours mean: in the mine, `##` rock in its own shade (stone,
deepslate, andesite, diorite, granite, tuff), ores by symbol on the
metal's colour (`Fe` iron, `Au` gold, `Di` diamond, `Em` emerald, `Co`
coal, `La` lapis, `Rs` redstone, `Cu` copper, `**` a modded ore), red on
orange `~~` lava, `..` gravel, `BB` bedrock, yellow `!!` torch, black
open space. On a farm:
blue `~~` water source, light blue `~n` flowing
water, brown `::` farmland, brown dirt, green grass, crops as letter and
age (`w3` wheat at stage 3) on green, lime once ripe, `||` sugar cane,
`..` sand, orange `[]` chest, gray `\/` hopper, gray `##` stone, yellow
the turtle (`^^ >> vv <<` top-down; `>> <<` along z or `+x -x` across, side
on).

A simulator counts as failing if the program raised an error (`ERROR:` in
its output), it crashed, or (with `run.py`) it ran past 5 minutes. Everything
else is for
reading: compare the numbers before and after a change (`git stash`, run,
`git stash pop`, run).

| Simulator | Program | What it covers |
|---|---|---|
| `farm_repair` | farm | learn with existing damage; holes, dry/flowing lane water, dirt in a lane, a block over a lane, untilled dirt; what a farming pass fixes vs. what triggers a full repair; `farm repair` |
| `farm_full_chest` | farm | a turtle full of coal, a nearly full chest, a full chest: nothing spills, the turtle waits for room |
| `farm_mixed_crops` | farm | wheat, carrots, potatoes and beetroot learned per tile; a wrong crop planted on a tile |
| `farm_reset` | farm | `farm reset` after a stop out on a 5x22 farm with cane: past the default routing area, over cane, down in a lane, at travel height, with no map yet, left of home; facing other than saved, at home and mid-farm, and a farming run started at home facing the wrong way |
| `farm_sugar_cane` | farm | a cane strip: harvest above the bottom block, replant a cane lost when its lane dried up |
| `farm_bone_meal` | farm | grow passes with bone meal from the chest |
| `farm_compost_while_waiting` | farm | surplus seeds go into the compost hopper during the wait between runs; a short wait runs out of time |
| `farm_chest_tidy` | farm | the farm chest tidied on every visit: part stacks merged, then sorted with like items together at the end of the chest (slot 1 left free); no moves when already in order; a full chest |
| `farm_clone` | farm | `farm clone` of a 7x16 farm with two lanes; moves, buckets scooped/poured, lane tiles that aren't sources |
| `farm_clone_lane_fallback` | farm | as `farm_clone`, but two lane tiles never fill on their own and must be poured |
| `farm_fuel` | farm | real fuel levels: learn and clone starting nearly empty with little coal in the chest; trips home to refuel and back, waiting at home for the "player" to add coal; never a move on an empty tank; a farming pass 5 min apart that waits longer than that for fuel starts over, a short wait carries on |
| `farm_pass_moves` | farm | moves for one plain farming pass on a 9x8 farm (`ALONGX=1`: lane along x) |
| `mine_tunnel` | mine | tunnels through mixed rock: veins out of the walls, floor and ceiling (part of one beyond reach), ore inside the tunnel, a tag-only modded ore, lava, falling gravel, a floor solid all along (the hole floor ore leaves filled); a crevasse across the tunnel bridged; torches in wall niches with no floor block dark enough for mobs (one wall, both walls for a tunnel 10 wide, one at the end of a short tunnel, a niche opening into a cave given a block to stand the torch on); `--no-lights` leaving the torches in the chest; a Geo Scanner swapped in for the pickaxe beside a chunk controller (the scan lined up with the tunnel though the mock reports along world axes turned from it, ore 5-6 out fetched, a diamond 8 out mined and its vein followed on past the scan, gold 8 out left, a fifth of the turns; a field of small deposits off one wall fetched one after another, not back to the tunnel between each); water that flows back as in the game: a tunnel through an underground lake and under one above its ceiling left dry and sealed off, without going round in circles placing blocks, and with little fuel going for coal as soon as a scan finds it; homes every 16 with supplies carried forward, room left above each valuables chest, and valuables collected on the way back, picked-up items joining their stacks (the mock stores them as the game does); a tunnel with no length that runs out of chests, then `--resume` (twice, the second time with more valuables in a home than it can carry: the most valuable come back); bedrock; running short of fuel (gets back with its margin); `mine reset` from inside a vein; `mine reset` to the last home (and `--to-start`) with a wrong saved heading (corrected from the tunnel's walls; where it can't tell, stopped on finding no home chests); with a crafting table and few chests, wood sought like coal (a line of logs out of the wall followed past an ordinary vein's reach; with a scanner, logs that don't touch the tunnel fetched), and not sought without a table or with chests enough; resumed from the start through a lit tunnel flooded from a hole in the ceiling out of sight of the home's lane: the hole found and sealed on the way out, and the missing and washed-away torches put back once the water's gone; the same walk through a dry tunnel leaving the torches that are up alone (the mock names a torch hung on a wall `wall_torch`, as the game does) and moving bulk in home 1's valuables chest down to its bulk chest; `mine haul` bringing back what one trip couldn't, with no bulk carried to the start or swapped into a valuables chest to make room, and bulk found in a valuables chest moved down to its bulk chest; `mine reset` to the last home from inside the tunnel and `--resume` from there; the last home and its segment flooded: `mine reset --home 1` back a home and `--resume` drying the segment out and going on past home 2 without building it again (fetching fuel from home 2 first, with little in the tank); water standing behind the home not taken for a wrong scan heading, and a scan really turned from the heading skipped; water from a source in the wall spread along the tunnel floor followed upstream and sealed; stopped (as if by Ctrl+T) partway through a segment and resumed from its log, without going over the finished lanes again; then the same with a hole in the ceiling letting water in meanwhile, which the resume follows up to and seals, putting back the torches it washed away; and stopped before the middle column's floor is dug, with lichen leaking into the finished side column, which the resume goes over instead; waterlogged glow lichen in the walls and ceiling with water behind it, and dry lichen, all replaced so no water gets in (with and without a scanner); a segment dug already with lichen leaking water along its floor, gone over from the home before and the lichen found and replaced, and the same with lichen in the ceiling at the far end, its water falling and spreading back along the floor; an aquifer beside the tunnel at every height: no water past the block being dug and no torch washed away (with and without a scanner). Water flows with the game's timing: it reacts 5 ticks after a change next to it, each turtle action takes 8, a turtle pushes flowing water out of the block it moves into, and torches it reaches are washed away; a tunnel to the left and down; a mineshaft: a chest minecart standing where home 1's wall chest goes broken and picked up with what it spills (placing a chest at it only right-clicks it, as in game), rails taken from the tunnel and its floor, and, low on chests and torches, chests and torches crafted from oak logs and mined planks with a crafting table swapped in for the pickaxe, the wood and table carried forward to the last home and none of it burnt |
| `mow_lawn` | mow | a lawn laid on the mine's rock: a 5x4 pass over grass, a fern and a dead bush with a step up, a dip, a crevasse and a stone pillar (every tile cut, the pillar and crevasse given up and the tiles past them reached round them, home at the end, a hoe parked and put back); torches on the lattice for 16x16 (6, every tile within 12 of one), none with `notorch`, a warning with none on board; a chest below home: a trip home mid-pass when down to two empty slots, the seeds in the chest; the settings (a size given kept, the repeat only if given, nothing when the turtle may not be at home, plain `mow` using the saved size) and a Ctrl+T in the wait between passes; `mow reset` from a dip out on the lawn |
| `turtlelib_stop` | turtlelib | Ctrl+T during a turn: without `T.run` the saved heading is a turn behind; with it the program stops once the turn is saved |
| `turtlelib_restock` | turtlelib | `T.restockFrom` reaching items behind other stacks in a chest |
| `turtlelib_refuel` | turtlelib | `T.refuelTo` and `T.totalFuelAvailable` burn and count only `T.fuel` items, never the wood and chests on board |
| `turtlelib_protect` | turtlelib | the turtle API wrapped once: moves and turns made straight through `turtle.*` keep `T.pos` right, protected areas refuse `turtle.dig()` and `T.digDir` alike, chests and computers are not dug, and `T.onChange` hears digs, placements and moves |
| `turtlelib_equip` | turtlelib | `T.withPeripheral` and `T.equipPeripheral`: a scanner swapped in on the side without the chunk controller (or a kept side), waited for, and put back even when the code using it errors; no side left, no free slot, a tool, never showing up; `T.pull` of a count out of a mixed chest across stacks, a part stack topped up first, a full chest, no room, not enough |
| `turtlelib_moveto` | turtlelib | `T.moveTo` in the order of axes asked for, and why it stopped: blocked by a block, a protected area (and `opts.inside`), a chest, bedrock, lava, fire or a door avoided, a mob in the way, no fuel; digging only what `opts.dig` allows; a route finder (`opts.path`, or the path module's `T.travel`, loaded only when a run is blocked) |
| `turtlelib_world` | turtlelib | `tl.world`: a scan from each heading lands in the right cells, a radius over 8 refused unless forced, the cooldown retried; a map cube written and read back byte for byte, and written in batches; digs, placements and moves noting themselves; the map surviving `T.setHomeHere`, a corrected heading and `T.clearPos`, and unaligned (until `T.alignMap`) when the position was lost; `T.setOrigin` from the player, GPS and a scan in all four ways the start can face, `T.toWorld`/`T.toLocal`; `map.get/top/find/count/heights/slice`; the cap (setting or a quarter of the disk, the cube unseen longest dropped first); `T.inspectAt` recording a state, `T.inspectAll` nearest first, `T.scanBox` |
| `turtlelib_path` | turtlelib | `tl.path`: A* over the map round a protected box (and through it with `opts.inside`), lava, fire, doors, chests, bedrock and `opts.avoidCells`; through a wall only where `opts.dig` allows; through the unseen at a cost; a sealed goal, a goal in a protected solid, the node limit, each saying why; a long search yielding on a clock; the map in a turned frame, or unaligned; reading cubes whole, never cell by cell; `T.travel` over a wall under a roof along the clear layer, scanning first when the map does not know, a search when there is no layer, a block it did not expect noted in the map and planned round (bounded), a mob kept out of the next plan, `T.moveTo`'s `opts.path` |
| `turtlelib_place` | turtlelib | `tl.place` on the build mock (`sim/lib/buildworld`): stairs and slabs each way (sideways always the bottom half facing the heading, placeDown the bottom half iff a block is below the target, placeUp the top half iff one is above), in each facing and in a world whose heading 0 is not north; a log's axis; a torch on a wall (both ways round, one reached round its support), standing, not hung on a fence; ladder, button, lever, trapdoor, gate, chest; a door (a block below, the cell above free, set into a wall, refused without moving otherwise); the table wrong about a row, corrected by the retry, the wrong block dug out (in a protected area too), kept in `.placements` and used after a restart, not learnt from a guess; rules relative to the heading (right, left, back); a cell in use, no item, a state the family lacks, a facing without the origin, a block already there as wanted; `T.ignite` from above (no flint, nothing solid under, a block in the cell, already burning); `T.placeInfo` (family, state keys, hangs, two-block) |
| `turtlelib_blueprint` | turtlelib | `tl.blueprint` on the build mock: the plan format (text and table forms, errors naming the line, written out and read back), `fill`/`box`/`walls`/`fromMap`/`put`/`at`; a small building (floor, walls, a stair bench, a torch, a door) built in order (walls, then the stair, the torch, the door last), stopped at a limit, resumed after a restart of the computer and after a Ctrl+T in the middle of a cell with no cell placed twice, and verified clean; the materials check (short refused before any move, what could be crafted asked of a craft module only if registered, partial, a block in the way failing one cell, the failed cell tried again), one build at a time (restart), a facing without the origin refused, `opts.protect`, a build inside an owned area; `T.verify` (a wrong stair found by its state, a plain block only with `inspect = "all"`, a stray block in an air cell, a cell it cannot reach listed as unverified); `T.replace` (a wall swapped from free sides, the block inside reported and not dug to, a protected area refusing unless owned, a stateful block, short of blocks, a block changed since the map) |
| `buildworld` | the mock `lib/buildworld.lua` | the mock a building simulator trusts: `turtle.place*` in the order CC:Tweaked 1.120.2 tries (the cell's own block if replaceable, the block beyond, the floor under it for a sideways place, the turtle's own block), a sideways click at 0.45 (bottom half), and Minecraft's rules for each family: stairs (half, facing, corner shape), slabs (half, double), logs (axis), torches, ladders, buttons and levers (what they hang on), doors (two blocks, a floor, the hinge), trapdoors, fence gates, chests and furnaces; into water, grass, stone, past an entity; digging and what pops off; the 3x3 crafting grid and the workbench; a chest, and a furnace by its faces with the time it takes |
| `turtlelib_junk` | turtlelib | `T.isJunk` (never keep items, tools, fuel, peripherals or what `T.craft` made), `T.setJunkChest` kept in a data file, `T.dumpJunk` to the chest and back facing as before; a missing chest, no way there or a full chest leaves everything aboard and nothing on the ground |
| `turtlelib_lazy` | turtlelib | the loader for the modules in `turtle/tl/`: a function `T` lacks is looked up in `T.registry`, its module required once and only when used, handed the very `T` that asked; a module that is broken, missing, lacking the name, or asking for its own function while it loads |
| `autostart_boot` | autostart | `turtle/autostart.lua` at boot: for each program it can start, what it runs from the job's files and the saved position (resume a tunnel it went down in, from the last home; leave a finished or self-stopped one; start one from the settings; farm reset then farm; learn from the settings' size; mow only when cut short or on repeat), a key cancelling, --now, a failed step stopping the rest |
| `git_space` | git | `bin/git.lua` against a mock GitHub and a small disk: a clone leaving out `sim/` and the other device's folder (`--all`, `--skip`), a disk that fills mid-clone and `git pull` finishing it, a checkout from before the device rule losing `sim/`, files moving between folders on a nearly full disk; `--lower`, an overlay on ccnix's ROM: only what differs fetched, the overlay's copies dropped when the ROM catches up and fetched again under an older one, nothing kept under a ROM newer than the branch (commit times with an offset), a whole checkout with no manifest; a busy server (5xx) tried again after 2, 4 and 8 s, a 404 not, the API's hourly limit used up saying until when |
| `boot_install` | boot, install | in a shellworld: `deploy/boot.lua` under a fake `/rom/ccnix` with its `.manifest` and `/rom/autorun/ccnix.lua` (the ROM's `bin/` and `pc/` or `turtle/` on the path, `help/` on the help path, `ls` its own, `_G.ccnix.find` and `.lib`; updates at `/ccnix` made for this ROM coming first and their `boot.lua` taking over, ones made for another ROM left out with a line saying so, a whole checkout at `/ccnix`); the end of startup (`ip up` with `net.boot`; the autoruns after ccnix's, the motd and the startup file or folder, a disk's in place of the computer's with `shell.allow_disk_startup`, then `init --boot` alone (on a Computer, whose screen can't be read back, the rest of startup in a window for init to copy, the shell's header again; not on an Advanced Computer, nor when setup runs boot in its shell), or the autostart, ccsh and the stock shell, then shutdown), `craftix.login` renamed; `/cc-turtles/.gitlite` leaving boot out; `install` from the ROM setting the settings only; then, with no ROM, `deploy/install`'s two lines (`boot.lua` first, `--end` last) in `/startup.lua`, or in a `/startup` folder's `00-ccnix.lua` and `zz-ccnix.lua`, run as CraftOS would, leaving the same path, help path, alias and order for a checkout, an earlier install's lines and files gone |
| `turtlelib_datapath` | turtlelib | `T.dataPath` moving a job's file left in the repo's top folder (from before `turtle/`) down next to the program, and nothing else |
| `pager` | pager, more, cat | on the turtle's 39 x 13 screen with scripted keys: what fits is printed, 12 lines and a status line, every paging, line and sideways key, no wrapping, `q` leaving the next key for the shell, `more` over several files with headers and a missing one, `more` into a pipe copying like `cat`, `cat`'s plain output |
| `coreutils_cu` | cu, cat, more, echo | `cu.getopt` against the Utility Syntax Guidelines (grouped flags, attached and separate option-arguments, `--`, `-` as an operand, bad options), reading lines from files, the keyboard (Ctrl+T as end of input) and a pipe, exit statuses through `shell.run`; `cat`, `more` and `echo` (escapes, `>` and `>>`); shellworld's word splitting and `io` read formats |
| `coreutils_head-tail` | head, tail | `-n`, `-c`, `-N`, `+N`, several files with headers, the keyboard and a pipe, huge counts, 3000-line files (yielding), `tail -r`, `tail -f` following appends and a truncation until Ctrl+T, bad counts and options |
| `coreutils_regex` | regex | basic and extended regexes: literals, `.`, brackets with ranges, negation and classes, anchors, `* + ?` and intervals, alternation, groups, back-references, leftmost-longest `find`, case folding, the first-byte skip, a 6000-character line, bad patterns |
| `coreutils_grep` | grep | every option, several pattern lists and `-f`, file prefixes, `-c`/`-l`/`-q`, statuses 0/1/2, `-s`, a missing last newline, yielding on 3000 lines |
| `coreutils_text` | wc, sort, uniq, cut, tr | each option, keys and modifiers for `sort`, `sort -o` over its own input, `uniq`'s output operand, `cut` lists, `tr` ranges, classes, `[=c=]` and `[c*n]`, the keyboard against a pipe, missing files, usage errors, 3000-line runs that yield |
| `coreutils_small` | touch, pwd, basename, dirname, true, false, sleep, which, xargs, seq, sysctl | POSIX's own `basename`/`dirname` examples, `touch` dates and odd operands, `sleep` moving the clock, `which` with aliases and `-a`, `xargs` `-n -L -I -s -x -p -t -r -E -0`, statuses 1, 127 and 255, quoting, long arguments, yielding; `seq` counting up and down, negatives, decimals (0.1 steps ending exactly, exponents), `-w -s -f`, bad numbers, a zero increment, bad formats, a long run; `sysctl` over CC:T's settings (`-a` sorted, `-n`, `-d`, an unknown key, `name=value` by each one's type, a wrong type refused, `name=` back to the default, usage) |
| `coreutils_ls` | ls | hidden files left out and shown (`-a`, `-A`), `-l` and `-lah` (total line, mode, sizes like 4.9K, times; no `w` on `/rom`), `-t -S -r -F -d -R`, file operands before directories with headers, columns to the screen and one per line into a pipe, a missing operand (status 2), a bad option, `ls` at the prompt running CraftOS's `list` until install's alias makes it ours, and, with the fileserver's pool mounted, its member disks' mounts hidden from `ls` (shown with `-a`) and from ccsh's `*` (matched by `d*`) |
| `coreutils_fs` | df, du, find | `df` and `df -P` over the root and `/rom`, `du -a -s -k`, `find`'s expression grammar and primaries, globs with ranges and classes, `-prune`, `-xdev`, `-exec ;` and `+`, `-ok` from a pipe, a 450-file tree that yields |
| `coreutils_compare` | cmp, diff | `cmp -l -s` and EOF, `diff` normal, `-u`, `-c`, `-e` (with `.` lines), `-f`, `-b`, `-q`, `-r` over directories, no final newline, CRLF, a 400-line file against its reverse (minimal, and yielding), statuses 0/1/2 |
| `coreutils_bytes` | tee, od, strings, printf | `tee -a` and unwritable files, `od` types, sizes, bases, `-j`/`-N` and long files, `strings -n -t`, `printf` format reuse, every conversion, widths and precision, escapes, bad numbers and conversions |
| `coreutils_test` | test, [, expr | every `test` primary, the argument-count rules, `-nt`/`-ot`/`-ef`, `-t` with pipes, `[` through the shell, integers past 2^53; `expr` operators, `:` with and without groups, statuses |
| `ccsh` | ccsh, echo, env | quoting, variables, field splitting and `${X:-default}`; pipes of utilities and of programs that `print`, `write`, `term.write` (columns by cursor position) and `printError`; every redirect, `2>&1` in both orders, `/dev/null`, files that can't be made or read; `&& \|\| ! ;` and `$?`, a missing program (127), one that errors, `exit`; globs (`* ? [..] [!..]`, dot files, across directories, absolute, a trailing `/`, quoted, from `$X`); `$(...)` and backticks, nested, `exit` inside one; `read`, `$PATH`, `.`; syntax errors (status 2); a command waiting for an event with its io swapped out meanwhile, Ctrl+T (130, the rest of the line skipped); the prompt, a quote carried to a second line, keyboard input under a pipe; scripts with `$0 $# "$@" shift`, `-c` with arguments and as the stock shell splits it; compound commands (`if`/`elif`/`else`, `while` counting with `expr`, `until`, `for` over words, a glob, `$(seq)` and `"$@"`, `break`/`continue` and `break 2`/`continue 2`, `case` with `|`, globs, quoted and expanded patterns, `(pat)`, empty bodies, no match; functions with arguments, `return`, `local`, recursion, `function`, a redirect on the definition, piped; a `for` piped, `{ }` and `2>` redirected, `while read` from a file and a pipe; subshells keeping their variables, `exit`, directory and functions, `$(...)` as one; continuing at the prompt; syntax errors; Ctrl+T in a loop of builtins; `break`/`return` misplaced); the environment (`os.getenv` sees only exported variables, `X=1 cmd` for one command, `unset`, `PATH`/`PWD`, `os.setenv` a program's own copy, `export -p`/`-n`, a ccsh in ccsh inheriting it, `env -u -i name=value` and `env` outside ccsh); jobs (`&` with `$!` and `wait`, `jobs -l`, a script waiting for its jobs, `kill`, `fg %1`, a job's own variables and `exit`, Ctrl+T ending `wait`, Ctrl+Z at the prompt then `jobs` and `fg`, a stopped job's missed events delivered on `bg`, `exit` warning about jobs); `/.profile` at the prompt only; `fg prog`/`bg prog` opening a tab that runs it with the environment, and without multishell; nothing left behind (`os.getenv` included); `set` (POSIX's): the positional parameters (`set --`), the variables listed, `-e` (and where it lets a failure be), `-u`, `-f`, `-x`, `-o` and `+o`, `$-`, options refused, not hidden by a function; `"$@"` of no parameters as no field; `>` into a folder that isn't there (no disk in the drive) or onto a folder: an error, no folder made, Read-only file system |
| `claude_drive` | claude | against a scripted API (canned replies, no network): the system prompt carrying turtlelib's index, status with protected areas, the request shape, tool results going back, the Lua sandbox (no `fs`/`http`/`shell`, errors as error results, definitions persisting), retries and refusals, the step budget, `--confirm`, `ask_user`, a second goal, no key |
| `autocompost_with_chest` | autocompost | composts what it can, rejects the rest into the chest in front |
| `autocompost_no_chest` | autocompost | no chest and a backed-up composter: ends idle instead of spinning |
| `net_stack` | net (lib/net.lua) | stacks on several computers over mock modem wires (each frame copied, as CC does), a router between two networks and VLAN 20 on one wire: ARP, UDP on a segment and through the router and back, tables carried, ping with the TTL one less, no ARP answer (host unreachable after 3 tries), no route at the router (net unreachable from it), a routing loop between two routers (time exceeded), traceroute's TTLs, broadcasts kept to their segment and VLAN, a VLAN reaching the untagged network only through the router's trunk, a closed port, loopback, frames for other MACs ignored, the `os.pullEventRaw` hook handling a frame once however many coroutines see it, the settings; TCP: the handshake and the header's fields, bytes both ways in segments of at most 536, a lost segment and a lost ACK (sent again, taken once), out of order (dropped, then go back N), the receive window filling and opening, keepalive on an idle connection, an orderly close each side in turn (CLOSE_WAIT, FIN_WAIT_2, TIME_WAIT), refused, reset by a side that forgot it, lost when nothing gets through, timed out connecting, sequence numbers wrapping at 2^32, abort, and loopback; a process gone (`closeOwned`): its socket and listener closed, another process's kept, its connection closed in order, one with unread data reset, one not yet accepted reset, its ports free again |
| `telnet` | telnet (lib/telnet.lua) | the Telnet parser (data, IAC IAC, options, NAWS, IP, a command split across reads, 255 in a subnegotiation); the renderer (the whole screen first, xterm 256 colours, UTF-8, the cursor; nothing when nothing changed; one changed row alone); the client's terminal fed that, showing the same text and colours (Latin-1, block graphics) and cursor, an inverted sextant as its complement with colours swapped, 16-colour and true-colour SGR, CR LF and erase to end of line, greys without colour; the decoder (characters with their keys, Enter from CR, LF, CR LF or CR NUL once, arrows, Delete, Page Down, both Homes, Backspace, Tab, Ctrl+letter, Ctrl+T, bracketed paste across reads, SGR mouse clicks, drags and the wheel); the client's keys and mouse decoded back |
| `jobs` | ccsh, ps, kill, lib/proc | ccsh under init's kernel: a program as a process (the shell's child, on its terminal, in front; in `-c` in the shell's group, at the prompt its job's own), pipes, statuses, an error and a command's own environment as before, Ctrl+T reaching the program; `&` with `$!` and `wait`, `kill %1`, Ctrl+Z stopping the job's process and the job, `fg` continuing it in front with the events it missed, `bg` in the background then Done, `kill -STOP`/`-CONT`/`-9 %1`, a background job's process (its own group, not in front) ended with the shell, Ctrl+T at the prompt ending the program, not the shell; Ctrl+C sending INT to the group in front, a program that ignores INT getting the key, and Ctrl+C at the prompt reaching the shell's line editor; nothing left behind |
| `readline` | lib/readline, ccsh | the line editor on a fake 51 x 19 screen: typing and the prompt's colour, Ctrl+A/E/B/F and the arrows, Home/End, Backspace, Delete, Ctrl+H/D; Alt+B/F/D, Alt+Backspace, Esc and Ctrl+[ as Alt; Ctrl+W/K/U and Ctrl+Y (kept for the next line); Ctrl+D on an empty line, Ctrl+C (^C), the terminate event, a paste, AltGr typing, unbound Ctrl keys; Ctrl+L (a prompt of two lines); history with Up/Down and Ctrl+P/N, the line being typed kept; Ctrl+R (again, Backspace, Ctrl+G, a failed search, the last search again, another key keeping the match); completion shown in grey, Tab, Up/Down through it; a line wider than the screen scrolling sideways, a prompt as wide as the screen; the same keys from lib/telnet's decoder; ccsh at the prompt with it: Ctrl+C (status 130, also at a > line), Ctrl+C on a running command, Ctrl+D leaving, Up, Ctrl+Z doing nothing; a line from the history showing no completion, so Up goes on back, until it's changed |
| `proc` | proc (lib/proc.lua) | init's kernel over a fake os, terminal, window API and settings: processes started at once and (spawned by a process) after it yields, the keyboard to the console only and other events to all as each one's filter lets them, inject, the environment and terminal of each in place only while it runs (and inherited by a child), ps, signals (TERM as a terminate event, KILL, 0, init refused, an unknown process), proc_exit and `proc.wait`; services from the settings (the enabled one started at boot), started again after 1 s then 2 s, restarts counted, what one showed last, `restart = no`, stop (Ctrl+T, then KILL 3 s later for one that ignores it), start while running, an unknown service, restart; the system log: init's messages held until syslogd registers, then handed over, what services print captured a line each (print, write, printError and io.stderr at err, io.write, `<N>`, blanks and `uncaptured` left out, a partial line at the end, past 1 KiB), not a console process, syslogd itself or a service with `.log false`, the 500-event backlog dropped and counted, the last 200 held once syslogd is gone, the capture undone; sessions and process groups: a leader in front of its terminal, children in its session and group or one of their own, what's typed going to the group in front, Ctrl+Z stopping it (proc_stop, `T` in ps) but not the leader's own group nor one ignoring TSTP, STOP not ignored, a stopped process keeping its events and getting them first on `kill -pgid CONT` (proc_cont), a group with no one in it, Ctrl+T to the group in front, an end's status and Ctrl+T in proc_exit, the leader getting what's typed with no one in front, the leader gone (its terminal too, HUP for the rest), orphans to init, `enter`/`leave` around each turn, capture passed to a service's child on its terminal only; crashes, with commands run through lib/procrun.lua under a shell that catches errors as CraftOS's does: the command's words passed on, a crashing service failed with status 1 and its error (proc_exit too), the traceback kept and logged at err, `service status`'s exit; a program's own non-zero status, one that ends well, no such program (status 1), a coroutine's failure caught and got over, Ctrl+T (no traceback), none of them a crash; a failing function's traceback, a CC:T exception's message and thread; `onReap` before `onExit` (a failing hook logged), `proc.exited()` keeping the last 32; a panic's report (the error and where, the processes, the log's messages not yet filed), the next boot logging it at crit and moving it to `.1`, once; the mouse wheel over the scrollback (up, down to the live screen, then the program's), kept by one in front that owns it |
| `syslog` | lib/log, lib/syslogd, logger, syslogd | names and aliases, a log file's line, RFC 5424 out (fields, the 2048-byte cut) and in (structured data, BOM), RFC 3164 in; syslog.conf (severities with `=`, `!`, `none`, each selector naming a facility deciding, program blocks, comments, bad lines told by number); rotation (`.1`, `.2`, keep 0); the engine by the default rules (the files, the console, forwarding), the rate limit and its count, files only; lib/log in a program without init (files, by `/etc/syslog.conf` when there is one, perror) and under init (`proc.log`, a logger apart); logger (words, `-p -t -i -s`, input lines, bad priorities); syslogd under a fake init (registers, its rules, a bad line, `syslog.burst`, one at a time, not without init) |
| `net_tools` | ip, ping, traceroute, nc | in a shellworld against stacks that answer at once: `ip addr`/`route`/`host`/`link` kept in settings and shown down and up, `ip up` opening the channels (VLANs too) and `ip down` closing them; `ping` by name through a router (replies, TTL, summary), with `-t 1` (time exceeded), to a network nobody routes (net unreachable), an unknown host, the network down; `traceroute` (the router, then the host; `!N`); `nc -u -l -v` printing datagrams and tables; `nc` over TCP to a listening stack (the line sent, the answer printed without `\r`, both sides closed), `nc -l -v` taking one connection, and a refused port; httpd's requests filed in `/var/log/httpd.log`; syslogd forwarding to B as RFC 5424 (an address, a name looked up aside) and, as a loghost, filing B's messages (RFC 3164 with its host; bare, under B's address) and relaying them |
| `fileserver_jbod` | fileserver (lib/jbod) | a mock file system with a 125 KB floppy in each of several drives: blank disks joining by themselves, `/jbod` in the root listing, capacity and free space added up, shared folders, a 300 KB file split across three disks and read back the same, out of space as an error with nothing half written, a fifth drive growing the pool, a disk with files waiting for `add`, copy and move in and out, `fs.find`, a disk with part of a split file taken out and put back, deleting every part, append; Tab completion in the pool, jbod's own and, with a ROM, CraftOS's `fs.complete` loaded over the patched table |
| `diskclone_disks` | diskclone | blank, labelled and non-empty disks, `--force`, a too-small disk, a disk already in the drive, no `LABEL` file |
| `net_dns` | host, lib/netdb | the resolver against scripted DNS servers: names, CNAMEs, NXDOMAIN and SERVFAIL, timeouts and the next server, the cache and its negative entries, `ip dns cache`/`flush`, `host -v` |
| `vi` | vi, vim (lib/vi.lua, lib/syntax.lua) | on a 51 x 19 screen with an in-memory disk, keys sent as events (Esc as Ctrl+[ and as the Esc key): inserting, counts, every operator and motion, put, registers, marks, undo and redo, `.`, search, `:s`, `:g`, `:m`, `:t`, `:r`, the files kept (CRLF, read-only, a new file), Ctrl+C as Esc and its hint, the screen (line numbers, tabs, the ruler, the mode) and vim's colours for Lua and ccsh; the colourers on their own |
| `scan` | lib/scan | the character tests, peeking and stepping, names, numbers, quoted strings, delimited text with backslashes, and the column in errors |

## The library

The mocks live in `lib/`, apart from the scenarios:

| File | What it holds |
|---|---|
| `lib/mock.lua` | The pieces every world is built from: the turtle's inventory stored as the game stores it (a pickup goes into the first slot from the selected one that is empty or matches; `SPLIT` counts second stacks it starts, `SPILLED` what didn't fit), containers (drop merges first, suck takes the first stack, `pushItems`), moving and turning with fuel (`FUEL`, `LOWEST`, `DRY`), looking, acting each way, upgrades (`EQ`), `fs` over a table of files, print capture, the `==` report line (`M.runner`) and `M.check`; also `textutils` JSON, a scripted `http` (`M.httpApi`: canned replies off a queue, every request kept), a scripted keyboard (`M.consoleApi`) and a screen (`M.termApi`: `term` drawing into rows of text, `os.pullEvent` taking scripted key events). |
| `lib/farmworld.lua` | A farm for farm.lua: `F.build{width, length, lanes, crops}` lays out strips of crops or `"cane"` between water lanes over a dirt floor, with the chest under home; the hoe harvests, cuts cane and tills through the gap; seeds, bone meal, dirt, water buckets and empty buckets place as in the game; water at lane level follows the infinite-source rule (`F.STUCK` keeps a cell from refilling); a hopper behind home takes compost; `sleep` runs the clock (`CLOCK`, `STOP_AT`). `F.stock`, `F.ripen`, `F.show`, `F.chestLine`, `F.cropCount`, `F.badLaneTiles`, `F.caneHeights` for scenarios. |
| `lib/buildworld.lua` | A world of blocks with states and the game's placing rules for the building library (ADR-0008): `B.new{ facing }` then `w.install()`; `w.set(x, y, z, name, state)`, `w.get`, `w.state`, `w.show` ("oak_stairs[facing=north,half=top,...]"), `w.give(slot, name, n)`, `w.stand(x, y, z, compass)`, `w.addEntity`, `w.settle` (what hangs on a block that went), `w.advance(seconds)` (the furnaces cook; `sleep` calls it), `w.craft` and `B.recipeFor(grid)` (its own recipe table, `B.RECIPES`, to check the library's against), `B.FUEL_TICKS` and `B.SMELTS`. The rules are rows of data (`B.FAMILIES`); the header of the file names the source of each. To add a block family or a recipe, add a row. |
| `lib/mineworld.lua` | Rock for mine.lua: mixed stone wherever nothing is set, chests, ore (`Mine.features` for the standard veins, lava and gravel), falling gravel, water that flows with the game's timing (`WATERY`), a Geo Scanner (`SCANNER`, `SCAN_TURN`, `WORLD_COORDS`), minecarts (`Mine.ENTITIES`; what they spill lies in `Mine.GROUND`), a crafting table that crafts the recipes mine.lua uses (`CRAFTED`), wood and chests that burn as in game (`BURNT`), and the checks: `leftIn`, `checkFloor`, `checkLight`, `checkOres`, `checkLava`, `checkStart`, `checkHomes`, `wetIn`, `torchesIn`. `STOP_AT_DIG` stops a run as Ctrl+T would. |
| `lib/composter.lua` | A turtle on a composter for autocompost.lua: the composter, the hopper under it (`HOPPER_STOPS_AT` backs it up) and an optional chest in front. |
| `lib/shellworld.lua` | A CraftOS computer for the utilities: `SW.new(PROJ)` gives an in-memory file system (directories, a read-only `/rom` with stubs of the stock programs, the repo's programs copied into `/ccnix/bin` (or `lib/`, `turtle/`, `pc/`, as in the repo) as they run; `/ccnix/bin` and `/ccnix/turtle` on the path), the stock shell's path, aliases and word splitting, `io`, `term`, `os`, `printError`. `W:file`, `W:dir`, `W:read` set and read files; `W:run(prog, args..., opts)` runs a program, `W:sh(line)` a command line as typed, `W:call(fn)` code inside the world; each gives `r.out`, `r.err`, `r.status`, `r.ok`. Standard input is typed lines (`stdin`, then Ctrl+T) or a pipe (`pipe`, `pipeIn`, `pipeOut`); `events` and `onPull` script `os.pullEvent`. `print`, `write`, `printError` and `read` are in `_G` while a run goes on (so a shell can swap them, as on CraftOS), `term.redirect` works, and `W.yieldEvents` makes `os.pullEvent` inside a coroutine yield as the real one does. |
| `lib/sandbox.lua` | What `runsim` and `watchsim` run a simulator in on a CC computer. |

Each world is a module (`local F = require("farmworld")`) that installs the
mocked globals when loaded and returns its state: `F.inv` (the turtle's
slots), `F.chest`, `F.files`, `F.P` (where it is and faces), `F.moves`,
`F.get`/`F.set` for blocks. Knobs and counters the scenarios set and read
(`FUEL`, `EQ`, `WATERY`, `SPILLED`, ...) are globals, listed at the top of
each file. A scenario builds a world, puts things in it, runs the program
(`F.runner(PROJ)` gives the `run(...)` that prints the `==` line) and
prints or checks what came of it. `git_space`, `diskclone_disks`,
`fileserver_jbod`, `proc`, `net_stack` and `telnet` need no world: each
fakes what its library sits on (a GitHub and a small disk, a drive and
dispenser, drives with floppies, an os and terminal, modem wires, a
terminal) with `lib/mock.lua`'s pieces where they fit.

All the farm scenarios share one layout: home at `(0,0,0)` facing `+z`,
the chest below home, farmland at `y=-2`, crops at `y=-1`, the dirt floor
at `y=-3`.
