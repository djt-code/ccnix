# ADR-0001: Consolidating the stack after the October 2026 additions

**Status:** Accepted (2026-10-29)
**Date:** 2026-10-29
**Deciders:** Dan Theisen

**Decided 2026-10-29:** D4a, D4b and D4d yes; item 4 (`.gitattributes`) yes; the
git example URL replaced by a placeholder; item 34's two old-git paths in
`setup` stay (not decided); item 20 skipped (untested). D4d still to be
verified on one real device: the steps are at the end.

## Context

Between 2026-10-28 (`03fcfc8`, the last review pass) and 2026-10-29 (`f95b64d`),
53 commits added most of what ccnix is now: the folder layout (`bin/ lib/
turtle/ pc/ deploy/`), `deploy/setup` and `install`, git's device rule, the
network stack with TCP, `init` and processes, telnet, ccsh's environment, jobs
and compound commands, `fileserver`/jbod, `ls`, `seq`, `env`, `which`, the
Claude driver's pager and colours, a third of `mine.lua`, help generated from
each program's top comment, and the ccnix mod (its own repo, `ccnix-mod`) with
the ROM, `boot.lua` and `ccnix update`. The repo was renamed from cc-turtles
and the shell from Craftix on the last day.

Forces:

- **The user wants the simplest thing that works.** Merging what exists is
  welcome; new abstractions are not.
- **Two codependent repos.** Each is a submodule of the other; the mod's ROM
  packs `bin lib turtle pc help deploy` from ccnix's commit; the gateway
  converts `lib/net.lua`'s frames. A change on one side must be checked on the
  other (`CLAUDE.md`).
- **Installed devices.** Computers in the field have `/cc-turtles`, the setting
  `cc-turtles.autostart`, `/startup/00-cc-turtles.lua`, and a few still have
  Craftix-era lines. Some turtles are mid-job.
- **The safety net.** 41 sim scenarios (`python sim/run.py`, 9 s, repeatable
  except for one printed table address) and the mod's 36 Java tests. Not
  covered: `deploy/boot.lua`, `deploy/setup.lua`, `bin/ccnix.lua`, `mow`,
  `init`, `telnetd`, `service`, `kill`, `ps`, `pc/fileserver.lua`; farm sims
  run with `settings == nil`.
- **CC's Lua.** Cobalt's 200-locals limit (mine/farm use the `_ENV` prelude);
  `package.path` is rebuilt per program, so library lookup can't be set once at
  boot. The index is LF; seven working-tree files carry CR.

Method: six read-only reviews, one per area (boot/deploy/ROM, process/shell/
telnet, network + gateway, turtle programs, coreutils/libs/fileserver, sims/
help/docs), each citing `path:line`, quoting duplicates side by side, and
naming the sim or test that covers each proposal. Their conclusions:

- **One structural duplication:** `deploy/install.lua` generates, as string
  templates, the same seven startup steps `deploy/boot.lua` performs (path,
  help path, `ls` alias, `net.boot`, the craftix.login shim, the autostart
  choice, init/ccsh order), plus 60 lines of machinery to edit those lines in
  and out of startup files.
- **Three "run a program with swapped globals" mechanisms** (ccsh's
  per-command `enter/leave` and job scheduler, `lib/proc`'s processes,
  telnetd's sessions) and **two terminal implementations** (ccsh's
  line-flushing stream, proc's hidden window), which differ for reasons: pipes
  and interpreter state on one side, retained bounded screens and services on
  the other.
- **No structural duplication in the network layer:** one send path, one
  timer, one `N.up()`; the Lua and Java wire formats match field for field.
- **About 25 mechanical duplicates** (the same helper or idiom written twice
  or three times) worth roughly 300 lines, and **8 defects** the duplication
  hid or the move left behind.
- **Naming leftovers** of two kinds: live compatibility (must stay or be
  migrated) and plain text (rename now).

## Decision

1. **Startup logic lives in `deploy/boot.lua` only.** `install` writes two
   `shell.run(.../deploy/boot.lua)` lines (top and `--end`) instead of
   generating the logic; boot.lua learns to run from a checkout as well as the
   ROM.
2. **The two schedulers and the terminals stay as they are.** The one thing
   they share, signal names, becomes `proc.signal`, which also fixes ccsh's
   `kill -INT`.
3. **Names:** the autostart setting becomes `ccnix.autostart` with a migration
   shim beside the existing `craftix.login` one (both deleted together once the
   devices are moved); the help index folds into `help ccnix`; install's
   startup file becomes `00-ccnix.lua`. **Moving the install folder
   `/cc-turtles` to `/ccnix` is the one open choice** (Options, D4d).
4. **`setup` stays the wget-run bootstrap**, separate from `ccnix`; it loses a
   duplicated block and two migration paths for a git that no longer exists.
5. **The library-lookup one-liner stays** in every program (it can't be
   centralised); `mow` gets the line it's missing and `claude` loses its
   second.
6. **`lib/net.lua`'s "Bridging to a real network" section is the wire-format
   source**; the Java Javadoc and both READMEs point at it.
7. **The mechanical consolidations and defect fixes in Action Items**, one
   commit each, each verified by running the sim suite before and after and
   diffing all output.

## Options Considered

### D1. Startup: `install.lua` vs `boot.lua`

| | A: keep both | **B: install writes boot.lua lines** | C: drop the no-mod path |
|---|---|---|---|
| Complexity | Two copies to keep in step | boot.lua gains a checkout mode and `--end` (+20) | Lowest |
| Lines | 0 | install ~235 → ~110 | install, setup mostly go |
| Verification | — | New shellworld scenario running boot.lua with and without a fake ROM; `sim/net_tools` install checks adjusted | — |
| Blast radius | None | Installed devices: old generated lines replaced on next `install` by "drop every line containing `<repo>/`" (the rule `setup`'s ROM migration already uses); `ip boot`'s detection; every install gains `_G.ccnix` | Servers without the mod lose ccnix |
| Familiarity | As is | Both files are the user's | — |

B. Install's templates are boot's logic written a second time as strings;
the editing machinery exists only to manage those strings. C breaks the
no-mod install the README promises.

### D2. Schedulers: ccsh jobs vs `lib/proc` processes

| | **A: keep both, share `signal`** | B: jobs as processes | C: processes as jobs |
|---|---|---|---|
| Complexity | As is | High: proc grows a stopped state with a bounded event queue, keyboard routing to an `fg` chain, a hook to swap ccsh's interpreter state per resume, `fg`/`wait` blocking; ccsh gains a `require` and a per-shell kernel | Fails: init runs without ccsh, proc has no pipes |
| Lines | −7 | −100 to −150 net, rewriting ccsh's 275-line jobs section | — |
| Verification | `sim/proc`, `sim/ccsh` §13 | Same sims, but multishell and `term.redirect` under a nested kernel are only imitated by shellworld | — |
| Blast radius | None | Every ccsh user; init | — |

A. The accounting in B is honest and the win is small against the rewrite of
working, tested code. The two terminal implementations stay for the same
reason: ccsh needs unbounded ordered text out of cursor motion with no retained
screen (and a 10000-row `getSize` so pagers never prompt); proc and telnetd
need a retained, bounded screen to diff and show.

### D3. Terminals

Keep (see D2). Three fake windows in the sims could share one in `sim/lib`;
optional.

### D4. Naming leftovers

| Item | Keep | **Rename now** | Notes |
|---|---|---|---|
| a. `cc-turtles.autostart` | Accept the name | **`ccnix.autostart` + 4-line shim in boot.lua next to craftix.login's** | Read in 5 files, documented in 9; `sim/autostart_boot` covers the reader. Mod README:20 follows. Both shims deleted together later |
| b. `help/cc-turtles.txt` index | — | **Fold into `help/ccnix.txt`** (mkhelp appends the index after the program's text; `setup`'s ALWAYS list follows) | `help ccnix` is then the distro's page. Alternative: `help/index.txt` (CC's ROM has none) |
| c. `/startup/00-cc-turtles.lua` | — | **`00-ccnix.lua`**, with D1 | install removes the old name |
| d. `/cc-turtles` install folder | Deferred on purpose (README:11-12) | Move to `/ccnix`: `setup` does `fs.move` once + rewrites startup lines (its ROM-mode migration is already that logic); `bin/ccnix.lua`'s `CHECKOUT` constant and the second root name go; sims' `progDir` (2 constants, ~25 literals) follow | **Accepted.** The code already anticipates a whole checkout at `/ccnix` (`boot.lua:49-51`, `ccnix.lua:71-72`). `setup` has no sim: verify on one device first |
| e. jbod marker text, git.lua example URL, `sim/git_space` repo name | — | **Rename** (text never read / examples) | Free |
| f. `craftix.login`, `zz-craftix.lua`, `/cc-turtles/.gitlite` guards, job-file move | **Keep** until the devices are moved | — | Live compatibility; delete together |

### D5. `setup` vs `ccnix`

Keep separate: `setup` must run from `wget` before anything exists (it fetches
git into memory); `ccnix` is a program of the install. Hoist the duplicated
telnetd block (−10), delete the half-clone cleanup and `/git.lua` removal
(−28; both serve a git from before `c308ad5`, which wrote state last), keep
the `/cc-turtles` migration until D4d is done.

### D6. Library lookup

Keep the one-liner in each program. CC's `cc/require.lua` builds a fresh
`package.path` for every program the shell runs, so nothing set at boot
survives; `/rom/modules/main/` would let ROM copies win over `/ccnix` updates.
The 43 identical `bin/`/`pc/` lines and 5 turtle lines are the two idioms
for two situations. Fix `turtle/mow.lua` (missing: it loads the ROM's
`turtlelib` after `ccnix update`) and `turtle/claude.lua` (two lines).

### D7. Wire format

`lib/net.lua:43-61` is the source (the mod's tests load that file). Add ARP's
fields there; trim `Ipv4.java`'s Javadoc to the Java-specific facts and a
pointer. `doc/network.txt` → `help/network.txt` is a generator step, not a
copy: keep.

## Trade-off Analysis

The pass spends its risk where one copy is literally derived from the other
(D1: strings that reproduce boot.lua's logic) and where a name is text nobody
reads (D4e). It declines to spend risk where two mechanisms serve different
runtimes (D2, D3) or where the only gain is a constant (D6). D4a–c cost a
shim each but ride on a pattern already in the code and are deleted together.
D4d is the natural end state and the pieces exist, but it touches every device
through an untested program; that's the user's call.

## Consequences

- **Easier:** one place to change what a boot does; every installed device
  gets `_G.ccnix`, so the `if ccnix` branches in `ip boot` and `fileserver
  startup` cover installs too; one name for the distro in settings, help and
  startup files; a sim suite that's byte-for-byte repeatable and covers `mow`
  and boot.
- **Harder:** `boot.lua` has two modes (ROM, checkout) and `--end`; two
  migration shims to remember to delete.
- **Revisit:** delete the shims and `setup`'s `/cc-turtles` migration once the
  devices are confirmed moved; D4d if deferred; a sim for `setup` and `ccnix`.

## Action Items

Verification for every commit: `python sim/run.py` before and after, diff all
output (ignoring `table: 0x…`), `python sim/run.py --check`; `./gradlew test`
for the mod. One logical change per commit; both repos pushed; pointers bumped
(mod's `ccnix/` first, then ccnix's `mod/`).

### Phase 0: the safety net

1. [x] `sim/pager.lua`: don't print the table's address (the one unrepeatable line).
2. [x] `sim/mow_*.lua`: a pass, settings saved after the home check, `reset`. mow has no scenario.
3. [x] `sim/boot_install.lua` (shellworld): `boot.lua` under a fake `/rom/ccnix` with `.manifest` and without; `install`'s lines run; `--end`. Prerequisite for D1.
4. [x] Optional: `.gitattributes` `* text=auto eol=lf`, renormalise (the index is LF already).

### Phase 1: defects (one commit each)

5. [x] `turtle/mow.lua`: the `ccnix.lib` prelude line (D6).
6. [x] `lib/proc.lua` `P.signal`; `bin/kill.lua` and ccsh's `kill` use it. Fixes `kill -INT 5` → "no such job" in ccsh. `sim/proc`, `sim/ccsh` §13.
7. [x] `pc/fileserver.lua`: a failed `add` sets status 1 (today it prints and returns success).
8. [x] `lib/pager.lua`: the fits-on-screen branch draws the wrapped rows with `P.drawLine` (today it measures wrapped, prints unwrapped); `printLine` goes (−10). `sim/pager.lua` §1 adjusted to read term rows.
9. [x] `turtle/mow.lua`: `T.saveSettings` after `T.requireHome` (a "no" at the prompt has already overwritten the settings).
10. [x] `sim/mkhelp.py`: the index's "Settings:" line (missing `init.boot`, `net.*`, `telnetd.*`, `service.*`), with D4b.
11. [x] `deploy/setup.lua:183`: the migration regex keeps single-quoted `shell.run('/cc-turtles/…')` lines too.
12. [x] README facts: directed broadcasts do cross a router (README:1140); `ip boot` sets a setting (1197); `lib/` is seven modules (19); "four folders" (14); what `setup` always fetches (128); the `## Programs in bin/` prelude snippet (1451). `doc/network.txt:3` lists TCP.

### Phase 2: mechanical consolidations (each covered by an existing sim unless noted)

Network (`sim/net_stack`, `sim/net_tools`):
13. [x] `bin/ip.lua:101-126`: drop `ip boot`'s startup-file surgery; it sets `net.boot` and boot/install do the rest (−25).
14. [x] `lib/net.lua:561`: rename the TCP `output` (shadows the IP one at 285) to `push`.
15. [x] `lib/net.lua`: one `poll(take, timeout)` for `Socket:receive`, `waitConn`, `Listener:accept`; one `freePort()` for UDP and TCP (−18).
16. [x] `N.awaitEcho(id, seq, timeout)`; `ping` and `traceroute` drop their identical matcher (−8).
17. [x] Drop unexported-in-practice `N.netOf`/`N.broadcastOf`, `fromConfig`'s unused `env`, and either show or drop the `rx/tx/arpAsked` counters; `pc/router.lua:27-28` → `ip forward on` (−10).

Process and shell (`sim/proc`, `sim/ccsh`):
18. [x] `lib/proc.lua`: `serviceDef`/`serviceNames`/`serviceStatus` as module functions; `bin/service.lua` uses them (−14; `service` itself untested).
19. [x] `bin/ccsh.lua`: delete the `os.getenv`-without-`environ` fallback (−5; unreachable).
20. [x] Skip: telnetd's password reader via `T.decoder` (−12) unless telnetd is touched for another reason; untested in sims. (Closed as skipped, 2026-11-17: the reader works in game as it is, a password typed over telnet doesn't show.)

Turtle (`sim/mine_tunnel`, `sim/claude_drive`, `sim/turtlelib_refuel`, `sim/farm_fuel`):
21. [x] `firstEmpty()` → `T.emptySlot()` (−5).
22. [x] `T.attackDir`, `T.suckDir` beside `T.digDir`; mine aliases them in its prelude line (0 net).
23. [x] mine's five chest/torch tallies → `craftPlan(atHand())` (−12).
24. [x] `T.popValue(args, flag)`; mine's `--spacing`/`--home` and claude's `--model`/`--effort`/`--steps` use it (−8).
25. [x] `T.fuel` derived from `T.FUEL_VALUE` (−4; they can drift today).
26. [x] claude's `blit()` → `pager and pager.blitOf(c) or "0"`; drop `P.colourLine` and its sim check (−8).

Coreutils and libs (`sim/ccsh` §12, `sim/coreutils_small`, `sim/fileserver_jbod`, `sim/coreutils_ls`):
27. [x] `bin/env.lua`: `cu.getopt("iu:", 125)` (−16).
28. [x] `bin/seq.lua`: insert `--` before a leading negative, then `cu.getopt("ws:f:")` (−15).
29. [x] `lib/jbod.lua`: marker text "ccnix jbod member"; `full()` moved up and used at 5 sites; local `isMember` → `marked` (0 net).
30. [x] `bin/ls.lua:10`: rewrap the 127-column header line; regenerate help.

Sims and docs:
31. [x] `sim/lib/mock.lua` `fsApi.getDir` real; `autostart_boot`, `turtlelib_datapath`, `turtlelib_stop` use `M.fsApi`/`M.shellApi` (−30).
32. [x] `sim/README.md`: own-mocks list, "turtle programs" intro, watchable list.
33. [x] `deploy/boot.lua`: drop the unread `_G.ccnix` fields (`rom, overlay, roots, commit, updates`) (−3).
34. [x] `deploy/setup.lua`: hoist the telnetd block (−10) (done); delete the half-clone cleanup and `/git.lua` removal (−28) once no device is in that state.

### Phase 3: the decisions (after acceptance)

35. [x] D1: `boot.lua` checkout mode and `--end`; `install` writes two lines and strips `<repo>/` lines; `--no-reboot` runs boot; craftix shim stays in boot only (−100 net). Verified by item 3.
36. [x] D4a: `ccnix.autostart` + shim; readers, headers, README, mod README:20; regenerate help.
37. [x] D4b: index into `help/ccnix.txt`; `setup`'s ALWAYS; README:171.
38. [x] D4c: `00-ccnix.lua` (with 35).
39. [x] D4d if accepted: `setup` clones to `/ccnix`, moves `/cc-turtles` once; `CHECKOUT` goes; sims' `progDir`.

### Phase 4: docs and the sibling

40. [x] README: Install section tells the startup story once and leads with the ROM path (−30); "Upgrading from before the folders" goes; "Simulators" defers to `sim/README.md` (−19).
41. [x] `lib/net.lua`: ARP fields in the wire-format section; mod `Ipv4.java` Javadoc trimmed to a pointer plus Java facts; `RomTest.java:37` uses `Rom.DIRS`; a test that every `.index` path starts with a `Rom.DIRS` entry.
42. [x] Bump `ccnix-mod`'s `ccnix/`, then ccnix's `mod/`; push all three repos.
43. [x] Mark this ADR Accepted with what was decided for D4d; write the architecture-decision skill into `ccnix-claude` from what this pass taught.

## Verifying D4d on a device

A computer or turtle installed at `/cc-turtles`, on a server without the mod:

1. `wget run https://raw.githubusercontent.com/djt-code/ccnix/main/deploy/setup.lua`
   (the same apps as before, or none). Expect "Moved /cc-turtles to /ccnix,
   where ccnix lives now.", "Updating /ccnix", install's "Put
   /ccnix/deploy/boot.lua first in /startup.lua, and with --end last." (or
   the `/startup/00-ccnix.lua` and `zz-ccnix.lua` form), then the reboot.
2. After the reboot: `ls /` shows `ccnix` and no `cc-turtles`; `/startup.lua`
   is the two `shell.run("/ccnix/deploy/boot.lua" ...)` lines and nothing
   naming `/cc-turtles/` (folder: `00-ccnix.lua`, `zz-ccnix.lua`, none of the
   old names).
3. `which cat` → `/ccnix/bin/cat.lua`; `ls -a` shows dot files; `help ccnix`
   ends with the command index; `ccnix` prints "/ccnix: a whole checkout at
   …"; `set` lists `ccnix.autostart`, not `cc-turtles.autostart`.
4. A turtle mid-job: `ls -a /ccnix/turtle` has `.turtlepos` and the job
   files; the autostart resumes 5 s after boot; `mine --resume` / `farm
   reset` find them.
5. `ccnix update` runs `git pull /ccnix` and says to reboot.
