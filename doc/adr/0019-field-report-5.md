# ADR-0019: What the turtle's 0.54 test pass found: put-back peripherals, reach for fetch and crafting, lint on plans, and the sandbox's clock (fifth pass)

**Status:** Accepted (2026-11-19)
**Date:** 2026-11-19
**Deciders:** Dan Theisen

## Context

The castle turtle ran an in-game test pass of what 0.54.0 (ADR-0014, 0015, 0016 and 0018) and the earlier
claude ADRs built. It ran from 01:22 to 02:00 UTC on 2026-11-20, then did a few short goals after a reboot. The
plan was a file the player gave it, `/claude/tests-0.54.md`, with an ID and an expected result for each check.
It wrote its results per check in `test-0.54-results.md` and its fifth report in
`/claude/report_harness_v5.md`. Its tally: 50 PASS, 4 FAIL and 1 SKIP, plus about twenty findings on the side.

Three read-only reviewers checked the report against the field log, the library and the harness.

**The log** covers the whole pass (four rotated files, 2026-11-17 23:03 to 11-20 02:14):
- the test goal took 38 minutes: 195 API calls, 177 lua calls, 7 chat messages, 6 heard back;
- 17.2M tokens in, 98.8% read from the cache, 205k written, 98.5k out (38k of it thinking);
- one compaction, mid-goal at 150,427 tokens (the 150k mark of ADR-0015 D7): 265 messages into a
  2,509-token summary in 24 s, and the next call read 40k;
- no retries, no cut-off replies; 8 code errors, two of them the model reaching for `fileio` and `gps`
  as globals.

**Three of the four FAILs are the test plan's, not the code's:**
- **01, no 0.54.0 news:** the news is sent when `deploy/version` moves past `/claude/.version`. The
  version is still 0.53.0, because the bump is the release that waits for the owner's ok. The harness
  did as written.
- **A2, `sleep(10)` took 3.3 s at 60 ticks a second:** the sandbox's `sleep` is CraftOS's, in game
  ticks. The prompt and the 0.54.0 news both say so; the plan expected real seconds. All the same,
  every helper the model writes means seconds (D1).
- **G10, no resume after a reboot:** the model asked the player to reboot and then ended its reply.
  That ended the goal (`goal done` at 02:00:35), and a goal's end deletes `resume.txt`. The reboot
  came after, with nothing left to resume. Nothing in the prompt says that ending a reply ends the goal
  (Phase 2). Autostart's plain `claude` also dropped the session's `--steps 400 --cache 1h` (D4).

**What the reviewers found, beyond those:**
1. **The real FAIL, F10:** `T.lint`'s light rule never fires for a plan's wall torch. A plan stores
   every block under its item name (`T.itemOfBlock`), so `wall_torch[facing=north]` is linted as a
   plain `torch`, the "open" kind, not "walltorch". The sims lint only map boxes.
2. **Peripherals put back blindly:**
   - `T.equipPeripheral`'s restore re-equips the remembered item by name without checking that the
     side still holds what it put on.
   - With that item gone, it falls through to an empty slot, which takes off whatever is there.
   - It ignores whether the equip worked.

   In the log, the model equipped the modem by hand over the chat box claude listens with. At the
   goal's end claude's put-back took the modem off. A cursed pickaxe ahead of a good one would fail
   the put-back silently.

   The modem the session started with was put on by hand (the shell history has `gps locate` just
   before), not by the GPS check: that check swaps only when no modem is on, and puts back on every
   path but a Ctrl+T or a reboot mid-check.
3. **Digs don't equip the tool:** with the pickaxe in the inventory and a modem on, `T.harvest` walked
   to 19 cells and failed each with "No tool to dig with" (74 fuel). Programs wrap their work in
   `T.withTool`; the library's digs never equip one (D3).
4. **`T.fetch` has no reach:** of seven small fetches in one call, one went to the other base and back:
   343 fuel, 66 s, no word. `T.stow` stops at 48 blocks (ADR-0015 D1). `T.prepare` and `T.craftPlan`
   count every base's chests too (D2).
5. **`T.fetch` and globs:** `T.where("*_sword")` finds 5; `T.fetch("*_sword")` gets 0, because
   `T.pull` compares names exactly.
6. **Smaller bugs:**
   - `T.placeAt` with `opts.exit` the target cell itself "reaches" the exit through the block it is
     placing: no warning, no refusal, and the turtle sealed in.
   - The result's (xN) folding folds every repeated line anywhere in the output, so printed code
     reads `end (x4)` with the other ends gone.
   - `T.craftBatch{take = true}` says "no room" for intermediates that later recipes used up.
   - `T.addChest`'s overlap warning made up 25 names like `coalbrick`, 4.5k characters.
   - `T.stow`'s far note names the other base's bulk chest as "the chest for it".
   - `T.sortChests`' "no chest is for it" doesn't say "at this site".
   - `T.planLights` ignores that `T.darkCells`' cells are in the nether.
   - A sign's text as a list of lines is refused.
   - `T.refuelFromLava`'s "gave up after 5 tries" doesn't say what the tries found.
   - Two waits meant in real seconds still count ticks: the 3 s before hitting a player
     (`waitBeforeHit`) and the chat box's cooldown.
7. **Asked for:**
   - `T.pave` checking room for the drops before it starts (it stopped half done);
   - a sideways chain placed in the open (`opts.temp` only props from below);
   - `T.pull` and `T.fetch` choosing which of several same-named items. The cursed pickaxe is not a
     valid upgrade, and it was taken ahead of a clean one.
8. **Wrong in the report:**
   - E5's "plain nil": every nil from `T.placeAt` carries a why. The model's code kept only the first
     value.
   - "No GPS hosts": the sandbox has no `gps`, and `T.gpsHere` had in fact returned a fix.

## Decision

Accepted 2026-11-19: the owner took every recommendation: D1 A, D2 A, D3 A, D4 A, D5 A, D6 A, D7 B, D8 A and
D9 A (one release, 0.54.0). Phases 0 to 2 went ahead meanwhile (#130 to #132).

## Options considered

### D1. The sandbox's clock and `gps`

- **A. Real seconds and `gps` (recommended):**
  - the sandbox's `sleep` is `realtime.sleep`; `os.clock` and `os.startTimer` stay game time, as
    CraftOS has them;
  - `gps` is a global there, with `T.gpsHere()` named in the prompt as the way that swaps a modem in.
- **B.** Keep CraftOS's `sleep`, and say it louder.
- **C.** `gps` only.

### D2. How far fetching and crafting go for materials

- **A. One reach for all (recommended):** `T.fetch`, `T.prepare` and `T.craftPlan`'s stock count only
  chests within `opts.maxDistance` (default 48, from where the call began), as `T.stow` does.
  - Farther, the why names the chest and the distance.
  - `opts.far = true` goes there.
  - `T.craftPlan` lists what's short here and what's only at the far base.

  mine passes its own chest (`opts.chest`), so it's unchanged.
- **B.** A warning when a fetch goes past 48, but it goes.
- **C.** Leave it.

### D3. A dig when the tool is aboard but not on

- **A. Equip it, in claude sessions (recommended):** a dig that fails "No tool to dig with", with a
  `T.cfg.tools` tool aboard, puts the tool on the side not holding the chunk controller (taking a
  modem or scanner off into the inventory), digs again, and says so once. `T.cfg.equipToDig`,
  on in the sandbox and off for programs, which use `T.withTool`.
- **B.** On everywhere.
- **C.** Only a better why ("the pickaxe is in slot 4: T.withTool").

### D4. Autostart's options after a reboot

`claude --resume` carries the session's options; a plain `claude` (nothing to resume) starts on the
defaults: 60 steps, a 5-minute cache.
- **A. Carry them (recommended):** each session saves its options (`claude.options`, a setting), and
  autostart's plain `claude` starts with them.
- **B.** Leave it: the defaults after a reboot.

### D5. `T.build`'s lint lines on the tops of walls

`T.build` prints lint's `player:` lines at the end. Lint walks the layer above the plan on purpose, so
every wall three or more high gets a "drop ... no railing" line for its top.
- **A. One counted line (recommended):** drops on the plan's top layer are summed into one line ("N
  drops on the plan's top: wall tops, unless players walk there"), the cells in the info. Other lines
  stay as they are.
- **B.** Skip the drop rule on a top cell one block wide.
- **C.** Leave it.

### D6. Which of several same-named items `T.pull` and `T.fetch` take

The lowest slot today.
- **A. Usable tools first, and `opts.pick` (recommended):**
  - for a tool, an undamaged and unenchanted one first, since only those equip as turtle upgrades;
  - `opts.pick(detail)` chooses by the chest's item detail.

  mine and farm restock fuel and blocks, not tools, so they're unchanged.
- **B.** `opts.pick` only.
- **C.** Leave it.

### D7. A sideways placement in the open (a chain along x)

- **A.** `opts.temp` also puts a block beyond the target, places, and takes it away.
- **B. Say so (recommended):** the why says `opts.temp` props only from below, and to put a block
  beyond first. It is one call for the model, and a temp block beyond means a dig back.

### D8. `T.pave` and the room for what it digs

- **A. Check first (recommended):** `T.pave` counts the kinds of block the map shows in the box
  against the free slots (with `T.cfg.digNeedsRoom` on), and refuses with the counts before it moves.
  Room enough, or blocks the map hasn't seen, and it goes as today.
- **B.** Warn and go.
- **C.** Leave it: it stops with a why at the first full dig.

### D9. Which release

0.54.0 isn't out yet.
- **A. One release, 0.54.0 (recommended):** this pass ships with ADR-0014, 0015, 0016 and 0018. Its
  news lines go in 0.54.0's section, and the in-game checks in a section of their own.
- **B.** 0.54.0 as it is, and this pass as 0.55.0.

## Trade-off analysis

- **D1 A** makes the sandbox match what the model writes: every wait in its helpers means seconds. It
  breaks nothing, since tick-based waits (crops, furnaces) go through turtlelib, which keeps CraftOS's
  clock. B keeps a trap the model fell into twice this pass.
- **D2 A** is the same rule `T.stow` has, so one sentence teaches all four. B still spends the fuel.
- **D3 A** fixes the 74-fuel walk, but a library dig that changes the turtle's equipment surprises a
  program. So it stays in the sandbox, as `digNeedsRoom` does.
- **D4 A** costs a setting. B costs a cold cache write and a 60-step goal after every reboot.
- **D5 A** keeps the warning for a wall players do walk (a castle's walls) without a screen of it.
- **D6 A** follows the game's rule: a damaged or enchanted tool isn't a valid upgrade.
- **D7 B** is the simple one. A adds a support plan and a dig back to every sideways placement.
- **D8 A** refuses only when the map is sure. It can't foresee what it hasn't seen.

## Consequences

- **Report v6 should show:**
  - no hand-equipped peripheral taken off at a goal's end;
  - fetches staying at their base;
  - lint warning about a plan's wall torches;
  - helpers' waits in real seconds;
  - after a reboot, a resumed goal with its options.
- **The model learns from "what's new":**
  - ending a reply ends the goal: for a planned reboot, stay in it;
  - `gps` is there now;
  - `T.cfg.dimension` once for the nether, or the lists say so;
  - `T.fetch` takes globs and stays at its base.
- **mine, farm and mow:** D2, D3 and D6 leave them alone. The peripheral put-back fix makes their
  `T.withPeripheral` swaps safer. The waits moved to real seconds lengthen the wait before hitting a
  player at 60 ticks a second to the 3 s it says.

## Action items

### Phase 0
1. [x] Baseline twice, byte for byte (done: identical).
2. [x] Each field failure a scenario first, failing on today's code:
   - a plan's wall torch in a walkway (lint);
   - `opts.exit` the target cell;
   - code printed with repeated `end` lines;
   - a hand-equipped modem over the listening chat box at a goal's end;
   - a put-back with the item gone;
   - `craftBatch{take = true}` with a used intermediate;
   - the overlap warning's made-up names;
   - stow's far note at two bases;
   - fetch with a glob;
   - planLights over nether cells;
   - a sign's lines as a list.

### Phase 1: no decision
1. [x] Lint reads a plan's torch, lantern or sign with a facing as its wall form (`T.blockOfItem`),
   in `T.lint` and `T.build`'s lint.
2. [x] `T.placeAt` refuses `opts.exit` equal to the target cell, and the closed-in search never counts
   the cell being placed as a way out.
3. [x] The (xN) folding folds only adjacent runs of three or more identical lines, and never a short
   line (four characters or fewer trimmed, like `end`).
4. [x] `T.equipPeripheral`'s restore:
   - puts back only when the side still holds what it put on, otherwise leaves the side and says why;
   - the empty-slot fallback only when the side was empty;
   - checks the equip, trying the other slots of the same name.

   `T.withPeripheral` and claude's put-back report a failed restore instead of dropping it.
5. [x] `T.craftBatch{take = true}`: an intermediate used by a later recipe isn't "no room"; the why is
   pull's own.
6. [x] `T.addChest`'s overlap warning tests only real names (the chests' contents, the inventory,
   recipe outputs), groups them by chest, and caps the list at three and "N more".
7. [x] `T.stow`'s far note ranks a chest for the item before a bulk chest and names which it is.
   `T.sortChests` says "at this site".
8. [x] `T.fetch` takes the globs `T.where` takes: a matching name from each holder's contents.
9. [x] `T.darkCells` tags its list with the dimension, and `T.planLights` reads it before
   `T.cfg.dimension`.
10. [x] A sign's text may be a list of lines.
11. [x] `T.refuelFromLava`'s why and info list what each try found (flowing, out of reach) and where.
12. [x] Real-second waits: `waitBeforeHit` and the chat box's cooldown move to `lib/realtime`.
13. [x] claude's version reads `deploy/version` from the ROM each start, not only the value boot kept
    (a `/ccnix rom update` without a reboot otherwise keeps the old one).

### Phase 2: what the model reads
1. [x] The prompt:
   - ending a reply ends the goal and deletes `resume.txt`: for a planned reboot, stay in the goal
     (a chat ask, or a call that waits);
   - `resume.txt` is the harness's: add lines under its first, don't rewrite it.
2. [x] Index and help:
   - `T.trail`'s entries are `{x=, y=, z=}`;
   - `T.cfg.dimension = "nether"` once covers the light functions;
   - `fileio` only through `require`;
   - a sideways placement needs a block beyond (D7 B).
3. [ ] News lines for this pass, in the model's terms.

### Phase 3: the decisions
1. [ ] D1 to D8 as decided.

### Phase 4: release (on the owner's ok) and hand back
1. [ ] UNTESTED.md's section with its issue.
2. [ ] Version bump and release, as D9 says.
3. [ ] The next goal: "read what's new, retire `resume()` in testlog.lua if the harness's file is
   enough, and keep /claude/report_harness_v6.md as you work". Then the checks this pass couldn't do:
   - 01 after the version bump;
   - G10 with the goal kept open across the reboot.
