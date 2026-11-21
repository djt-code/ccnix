# ADR-0020: What the turtle's v6 test pass found: craft rounds, recipes, bulk chests per base, seals, unseen cells, the clock, and the prompt (sixth pass)

**Status:** Accepted (2026-11-20): D1 to D4 decided; the release waits for the owner's ok
**Date:** 2026-11-20
**Deciders:** Dan Theisen

## Context

The castle turtle ran the v6 test plan (`/claude/tests-v6.md`) against ccnix 0.54.0 from 13:12 to 13:40 UTC on
2026-11-20, with a reboot check at its end. It wrote its results in `/claude/test-v6-results.md` and its
seventh report in `/claude/report_harness_v7.md`. Its tally: 22 PASS, 0 FAIL, 2 SKIP and 2 INCONCLUSIVE.
The 20 checks that passed were closed with their evidence. Its findings on the side became issues #344 to
#351. Its lighthouse build, the day before, had found #340 to #342.

This pass takes those issues, and the two prompt stories still open for claude: #339 (the prompt edits
lines as a shell does) and #93 (goals longer than one line). #343 (scheduled drivers) is ADR-0021.

Three read-only reviewers checked the findings against the field log, the library and the harness.

**The log** covers the whole pass:
- two goals (the test plan, then its resume after the reboot): 130 API requests, 118 lua calls, 9 memory
  calls, 10 chat messages (6 asks);
- 11.26M tokens in, 98.6% read from the cache, 152k written, 58k out (21k of it thinking);
- the largest context was 131k, so no compaction; no retries;
- two code errors, one the plan's own (`settings` isn't in the sandbox).

**What the reviewers found:**

1. **#340, short craft rounds: CC: Tweaked's suck takes more than asked.** `turtle.suck(k)` moves items
   through CC:T's container transfer. When the first chest slot doesn't cover `k`, it carries on to the next
   slot of the same item and asks it for the full `k` again, not what is left. So one suck can bring up to the
   slot's room. `T.takeInto` asks for `n - have` and checks only `have >= n`, so a cell whose front stack was
   short ends with more than it needs, and the chest runs dry before the last cell. "0 still in it" was
   true: the missing items were in the earlier cells, and the stash put them back after the round. This
   accounts for all four field cases exactly (for example the quartz round: stacks of 64, 64, 64 and 48 for 60
   a cell gave 60, 64, 64 and 52). `T.pull` has the same overtake. The sim's suck took from the first stack
   only, so no sim could see it.
2. **#341, "No matching recipes": not the chat box.** The model added a wrong pillar recipe (from quartz
   blocks) and later the right one (from cut quartz). `T.addRecipe` puts a new row first but keeps the old one.
   With too few cut blocks for the whole count, `choose` fell back to the stale row, which the table refused.
   It failed the same way with the chat box in the chest. `T.recipe` shows only the newest row, which hid it.
3. **#342, the turtle sealed into a plan cell.** A corner cell held a world block, so the first pass failed
   it (a build never digs a cell it fills). The model dug it by hand after building above and below. On the
   retry pass a wall neighbour went in from inside the hole and closed it. `T.placeAt` only warns of a seal
   unless `opts.exit` is given, and `T.build` passes none, so the seal was a line in `info.sealed`.
4. **#346:** `T.craftPlan{iron_ingot = 1}` with 21 ingots in the chests planned a block from 9 ingots and 9
   ingots from the block. The loop check runs after an inner name is taken from stock, so ingot, block, ingot
   isn't seen as a loop.
5. **#347, the bulk flag "lost":** `T.addChest` with `bulk = true` clears the flag on every other chest, at
   every base. The second base's bulk chest, added on 11-18, unmarked home's. A base is a site in the code
   (chests chained within 48 blocks).
6. **#348:** lint and pave read a cell the map has never seen as nothing. Wall-top drops over unscanned
   space were never reported, and pave's room check (ADR-0019 D8) went ahead and stopped half done.
7. **#349:** `T.digDrop` lacks glowstone, sea lanterns, glass, ice and the ores (it returns the block). Its
   lossy check has its own list and was right. A dug block lands in the first empty slot after the selected
   one, as CC:T stores drops from the selected slot on, so it doesn't join a part stack before it.
8. **#350:** `T.craftBatch`'s `info.left` lists only the asked-for products, as its doc says. Spare
   intermediates (planks and sticks made and not used) are worked out and kept nowhere.
9. **#345, the first sleep of a call 1.1 s long:** not the chat listener. `lib/realtime` sleeps by the tick
   rate it last measured, and measures again only once its window reaches 10 real seconds. After the player
   set the tick rate from 60 to 20, a window spanning the change gave a blend (about 27 a second), and the
   next sleep waited 4.1 game seconds for 3 real ones. The log shows `os.clock` moving 4.10 in that sleep: the
   wait was computed long, nothing stalled. `R.sleep` corrects a short wait but never a long one.
10. **#344, the put-back line names the wrong item:** the line is built when the dig takes the chat box
   off, before the dig puts the pickaxe on (D3 of ADR-0019). It says what the side held then, in the present
   tense, and arrives after the call, when the side holds the pickaxe.
11. **Smaller:**
    - `T.addChest`'s overlap warning names chests at the other base, which sorting never mixes.
    - The harness doesn't log where a session's options came from (`claude.options`, `--resume`, the
      command line), so the reboot check had no evidence in the log.
    - The model dated three of its files 2026-11-22 for work done on 11-19 and 11-20: nothing tells it the
      date but the tidy goal.
    - `T.blueprint.put` refuses a cell outside the plan's layers; its index line doesn't say so.
    - `T.undo(n)` counts journal entries, and a paved cell is two (a dig and a place).
    - `T.build()` after `T.undo` of the build still says "finished": the undo journal doesn't change the
      build's record.
12. **Wording (#351):** "1 lights"; `T.gpsHere`'s second value ("a scan" or "a step") undocumented; `T.pull`
    reorders the chest's slots; a clean tool has `damage = 0`, not nil; `T.sortChests` moves every misplaced
    stack in the site, which its why doesn't sum up.

**The test plan's own mistakes** (a global the sandbox lacks, a predicate that couldn't tell a clean tool
from a worn one, a player in the turtle's way) went into the `/turtle-test-pass` skill's tips.

## Decision

Accepted 2026-11-20: D1 A, D2 C, D3 A and D4 A. #339 and #93 are built as their acceptance criteria say,
#93 with options 1 and 3 (the owner's comment on it). Phases 0 to 2 go ahead with them.

## Options considered

### D1. A placement that seals the turtle in, in `T.build`

ADR-0015 D5 chose "warn, and refuse only with `opts.exit`". `T.build` passes no exit, so it only warned.
- **A. Refuse, and try the next way (recommended, decided):** `T.build` refuses a placement after which the
  map shows no way out of the region the turtle stands in, tries the cell's next approach, and fails the
  cell with the why when none is safe. `T.placeAt` called directly is unchanged.
- **B.** Warn as today, louder in the result.

### D2. `T.build`'s one record

`T.build` keeps the last plan and its progress. It already refuses a new plan while the record has untried
cells (unless `restart = true`), and lists a replaced build's failed cells in `info.previous`. On turtle 10
the replaced record was a finished build (4 of 4 cells).
- **A.** Note any replaced record in `info.replaced`.
- **B.** One record per plan name: builds paused and resumed by name, `T.builds()`.
- **C. Leave it, and say how it works (recommended, decided):** the help says `T.build()` carries on the
  last plan given, an unfinished one is never replaced without `restart = true`, and `T.undo` doesn't change
  the record.

### D3. `T.pave` and cells the map hasn't seen

- **A. Count them as one more kind (recommended, decided):** unseen cells in the box need one more free slot.
  Short, it refuses with "N cells not in the map: scan first or free a slot".
- **B.** Go, and say how many were unseen.
- **C.** Refuse until the box is scanned.

### D4. `settings` in the sandbox

- **A. Read-only (recommended, decided):** `settings.get` and `settings.getNames`. Writes still go through
  `T.saveSettings`.
- **B.** Leave it out; the help says to read `/.settings`.

## Trade-off analysis

- **D1 A** turns a seal into a failed cell with a why, which the model can act on, instead of a turtle in a
  hole. It costs a map search a placement, which `T.placeAt` already does for its warning.
- **D2 C** changes nothing: the record behaved as designed, and per-name records cost a folder, a migration
  and a cap for a need the field hasn't shown.
- **D3 A** is the cautious reading of what the map doesn't know. One slot is often enough (an unseen box of
  stone is one kind); when it isn't, the stop half done is what the field saw.
- **D4 A** removes a trap the plan fell into, with nothing the sandbox can change.

## Consequences

- **Report v8 should show:**
  - craft rounds that make the whole count, and a recipe added twice that replaces its first row;
  - one bulk chest at each base;
  - no seal in a build; a refusal with a why instead;
  - lint and pave speaking of unseen cells;
  - real-second sleeps right after a tick-rate change;
  - the prompt's keys: history, Ctrl+A/E/K/Y, Ctrl+R, Tab, multi-line goals.
- **The model learns from "what's new":** the date comes with each goal; `settings.get` is there; a recipe
  added again replaces its row; `info.spare`; `T.digDrop` knows glowstone.
- **mine, farm and mow:** none of them calls `T.takeInto`, `T.pull`, `T.addRecipe` or `T.build`. mine's
  bulk chest is its own (home chest sides), not `T.addChest`'s. The dig that joins a part stack is
  turtlelib's wrapped dig, which mine doesn't use for its tunnel.
- **ccnix-mod:** nothing (#93's mod option was declined); the usual lockstep bump with the release.

## Action items

### Phase 0
1. [x] Baseline twice, byte for byte.
2. [x] Each field failure a scenario first, failing on today's code: the CC:T suck in the mock, then a round
   over uneven stacks; a recipe added twice; the iron loop; two bases' bulk chests; a seal on a build's retry;
   unseen cells for lint and pave; glowstone's drop; spare intermediates; a sleep after a tick-rate change; the
   put-back line after a dig.

### Phase 1: no decision (#353, #354, #355)
1. [x] `T.takeInto` and `T.pull` suck no more than the front stack holds (#340).
2. [x] `T.addRecipe` replaces a row it added for the same product and cells; a refusal names the recipe it
   tried (#341).
3. [x] `T.craftPlan` sees a loop through stock and takes the name from stock (#346).
4. [x] One bulk chest a site; "no bulk chest" counts the site (#347). `T.addChest`'s overlap warning keeps to
   the site.
5. [x] Lint reads an unseen cell above a plan cell as air and counts other unseen cells in `info.unseen`
   (#348).
6. [x] `T.digDrop` gets glowstone, sea lanterns, glass, ice and the ores; the wrapped dig selects a part stack
   of the drop first (#349).
7. [x] `T.craftBatch`'s `info.spare` (#350).
8. [x] `lib/realtime`: a sleep measured as it goes, so a stale rate can't make it long, and a measure that
   disagrees replaces the stored rate (#345).
9. [x] The put-back line says when it was true, and what the side holds after the call (#344).
10. [x] The log's `start:` line says where the options came from; today's date at the end of the system prompt (it
    changes the cached prompt once a day, at midnight UTC).

### Phase 2: what the model reads (#356)
1. [x] Help and index (#351): "1 light"; `T.gpsHere`'s second value; `T.pull` reorders the chest; `damage =
   0`; `T.sortChests`' summary; `T.undo(n)` counts entries; `T.blueprint.put` and the plan's layers;
   `T.build()`'s record (D2).
2. [x] News lines for this pass.

### Phase 3: the decisions and the stories (#354, #355, #357)
1. [x] D1, D3, D4 as decided.
2. [x] #339: the prompts read with lib/readline: its keys, a history file, Ctrl+C and Ctrl+D, Tab for the
   commands, the pager on PgUp and the wheel.
3. [x] #93: Shift+Enter (and Alt+Enter, for telnet) continue a goal on the next line; `/goal <path>` and
   `--goal-file` read one from a file.

### Phase 4: release (on the owner's ok) and hand back
1. [x] The in-game checks: #358, a sub-issue a check (#359 to #379).
2. [ ] Version bump and release: 0.55.0.
3. [ ] The v7 test plan (`/turtle-test-pass`), with #200, #210 and #217 set up again.
