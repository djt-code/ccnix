# ADR-0011: What the turtle learned building for days: turtlelib and claude, second pass

**Status:** Accepted (2026-11-15): the user took every recommendation,
D1 to D10
**Date:** 2026-11-15
**Deciders:** Dan Theisen

## Context

`claude` (turtle/claude.lua) has driven one turtle in the Nether since
ADR-0008 shipped (ccnix 0.50), building a keep, walls, a cellar, a
bunker and bridges round a lava moat. Its second report,
`/claude/report_harness_v2.md`, covers its tasks 14 to 31: what went
wrong while using ADR-0008's map, placing, blueprints, crafting, storage
and protections for real, and what would help in any world. The user
fetched the turtle's `/claude` folder and its `claude.log` from the
server (2026-11-15) and asked for a general improvement pass on
turtlelib and the harness from it, and for the loop itself (fetch,
review, decide, build, hand back) to become a skill.

**Method.** The sims were made repeatable first (#21: a pinned clock and
seed, so two runs are byte for byte the same; 72 simulators pass). Three
read-only reviewers then went over the evidence: the turtle's files and
log, turtlelib against every claim in the report's sections 1 to 11, and
claude.lua against section 12. Each claim was checked in the code; where
the report misread the code it says so below.

**What the log says** (claude.log.1 and claude.log, 127 calls over
about three hours on 2026-11-15):

- The conversation grew from 200k to 341k input tokens a call. Every
  call logs `context: 115 old tool results cleared (~31k tokens)`: the
  server-side clearing (ADR-0008, `clear_tool_uses_20250919`) took the
  same oldest 115 results each time and never more, most likely because
  a clear must free at least `clear_at_least` (30k) and the results since
  the first never add up to that. Tool results are small (about 270
  tokens each, none clipped); what fills the context is the model's own
  side: its code, thinking and text.
- One goal (the bunker) read 13.6M input tokens, 98% from the cache; the
  session read 62.6M in all. The cache held across a 17-minute `lua`
  call (the session ran with `--steps 400 --cache 1h`).
- Only two tools were used: `lua` (117 calls) and `memory` (23). No
  retries, API failures, refusals or cut-off replies.
- The model's own rule of at most about five minutes a call was broken
  (17 and 11 minutes), and the chat went quiet for 25 and 28 minutes.

**What the reviewers found**, in short:

- **Confirmed defects.** `T.up` refuses silently at `T.cfg.maxHeight`
  (16 by default; turtlelib.lua:1099). `T.moveTo` with `dig=` digs any
  matching cell on the route it picks, with no check for lava or water
  beside the cell it opens; that is how the moat leaked into a
  stairwell. `T.refuelFromLava` takes lava from protected areas
  (harvest.lua:429). autoDump's failures are swallowed (store.lua:551)
  and its retry rule let a full inventory trigger a trip on nearly every
  dig (about 700 fuel for 76 digs). `T.report` appends a finished job's
  progress forever (journal.lua:258), which reaches mine, farm and mow's
  reports too since they share the journal file. The chest catalogue
  counts a double chest twice (store.lua:317, 377): bricks catalogued
  195, really about 128. `T.inside` takes one area, so a cell in two
  can't be dug (15 of the turtle's 18 areas overlap another; 47 of 117
  calls were wrapped in `T.inside`). `placeAt`'s failure doesn't say
  what was missing (place.lua:689), and "no route: gave up after
  searching 20000 cells" doesn't say a protected area or a door was the
  reason, so the model raised the limit and burned time.
- **Lists and sets.** `moveTo`'s `dig` wants a list (a set dug nothing),
  `T.keep` wants a set (a list made everything junk), and globs work in
  recipes but not in dig lists. The model met all three.
- **Smaller ones.** `T.fetch`'s error repeats its suffix; `T.smelt` can't
  take its furnace back inside a protected area; `mine.job` stayed
  "active" in the frame from before the origin was reset; `--model`
  takes no aliases (`sonnet`).
- **The report was wrong in places.** `T.harvest` already skips
  protected areas, lava-touching cells and falling blocks. Protection
  doesn't block placing, only digging. `T.moveTo` already enters
  protected air; it's the route planner that walls protected boxes
  off. `T.inspectAt` already tries all six neighbours; it's the default
  straight-line approach that fails.
- **What it didn't know.** The index never says `T.keep` is a set (a
  list makes everything junk), that `maxHeight` is 16, or that
  `T.job.clear` ends a job. The prompt says "variables and functions you
  define persist", but a `local` ends with its call (each call is its
  own chunk); the model learnt that by losing helpers.
- **Its own helpers** (`/claude/helpers.lua`): `digCell`, `batchCraft`,
  `furnaceSmelt`, `retrace`, `scoutLine`, `askPlayer` and three
  block-to-nine recipes. All but `scoutLine` are general and belong in
  turtlelib.
- **The harness.** `ask_user` reads the keyboard; the player is usually
  in game, so the model built `askPlayer` on lib/mc and had to be
  reminded twice to keep the player told; its `askPlayer` takes a reply
  from any player. Once it told the player a cellar was "torch-lit" in
  the same call that failed to place a torch. `io.write`, `write`,
  `setmetatable` and a few more are missing from the sandbox. A
  top-level `print` in helpers.lua fails the whole file (`env.print`
  isn't set yet), and one error loses every helper.

## Decision

1. Make failures loud and refusals explained, everywhere the model met
   a silent one (Phase 1, no decision needed).
2. Tell the model what it didn't know: the index, the help and the
   system prompt (Phase 2, no decision needed).
3. Guard digs next to liquids by default (D1).
4. Let routes pass through known air in protected areas (D2).
5. Fold the model's general helpers into turtlelib, with sims (D7).
6. In the harness: a chat tool for the player in game (D4), reminders to
   keep them told (D5), helpers kept one to a file (D6), a short status
   line on each result (D8), and a smaller conversation (D3).
7. Close the loop: at session start the harness tells the model what
   changed since the version it last ran (D9).

## Options considered

### D1. Digging next to lava or water

| | A: as now | B: a guard on by default | C: a guard, opt-in |
|---|---|---|---|
| What | `dig=` opens any cell on the route | `T.moveTo`, `T.travel`, `T.harvest` and a new `T.digCell` refuse to open a cell with lava or a water source beside or above it, as far as the map or `inspect` knows: "would release lava at x,y,z"; `opts.liquid = true` lets a job go ahead | the same, only when asked |
| Lines | 0 | ~60 (guard, `T.digCell`, `opts.digOnly`, A* treats such cells as walls) | ~60 |
| Verification | untested | new turtlelib_moveto and turtlelib_path scenarios: a moat beside a channel | same |
| Blast radius | | mine and farm dig with `T.forward`/`T.dig`, not the route digger: unchanged. A claude job digging by a lake gets refusals it has to answer | none |

**B.** The leak was one call away from flooding the cellar, and the model
asked for exactly this. A refusal with the cell named is something the
model can act on; a flood isn't.

### D2. Routes through protected areas

| | A: as now | B: known air passes | C: B, plus a `noEnter` flag |
|---|---|---|---|
| What | the planner walls every protected box (path.lua:171) except the ends | cells the map knows are air count as open inside protected boxes; solid ones stay walls (moveTo never digs there anyway) | an area can still be marked no-entry |
| Lines | 0 | ~5 | ~25 (a notes file beside `.protected`) |
| Verification | turtlelib_path "protected areas kept out of" | that check changes to "...not dug, but crossed through known air" | same |
| Blast radius | | a route may now go through the player's protected house's open door | |

**B now, C if wanted later.** Protection is about not breaking things;
walking through an open hall breaks nothing.

### D3. The conversation's size

| | A: as now | B: clear the tool inputs too | C: the harness trims itself |
|---|---|---|---|
| What | results cleared server-side; the code and thinking stay | add `clear_tool_inputs = true` to the edit, so old `lua` code goes with its result, and a `clear_thinking_20251015` edit keeping the last few turns' thinking | the harness replaces old results and code with a pointer to a file in /claude/out/ |
| Lines | 0 | ~5 | ~50 |
| Verification | | claude_drive checks the request body; the effect is measured in game (the log's `tokens:` lines) | claude_drive scenarios |
| Blast radius | 200 to 340k re-read a call | each clear rewrites the cache once | the same, and a file ring on the turtle's disk |

**B, then measure.** The API's own semantics for when a clear repeats
aren't documented (the log shows one clear of 115 results reapplied, not
new ones); `clear_tool_inputs` goes after what actually fills the
context. If the next log still shows 300k a call, C is the next step,
in its own ADR. Plus, regardless: a context-overflow error is answered
by a smaller retry, and `/new` at the goal prompt starts a fresh
conversation (memory and plan files carry over).

### D4. Talking with the player in game

| | A: as now | B: `T.report.ask` in turtlelib | C: B, and a `chat` tool in the harness |
|---|---|---|---|
| What | `ask_user` reads the keyboard; the model's own `askPlayer` | ask in chat, wait for a reply starting with "claude" (a timeout, a reminder), return the text, player and time | the model says or asks without writing code; the keyboard answers too, whichever is first |
| Lines | 0 | ~45 (journal.lua, on lib/mc) | +~55 (claude.lua) |
| Verification | | turtlelib_journal with chat events | claude_drive with a mock chat box |
| Blast radius | | the chat box is equipped for the wait (a tool swapped out); it doesn't hear other chat boxes | |

**C.** Programs get `T.report.ask`; the model gets a tool, which needs no
event loop of its own. The wait is capped below the cache TTL unless the
model asks for longer, and the result says so. A reply counts only from
the player in the setting `turtle.player` (anyone's when it isn't set).

### D5. Reminders to keep the player told

**Yes, a setting `claude.remindChat` (minutes, default 15, 0 for off).**
When that long passes without a chat message, the harness adds one line
after the tool results, as it does for the step budget. The player asked
twice; the model agreed it should.

### D6. The model's helpers

| | A: one helpers.lua | B: one file a helper, `keep(name, code)` |
|---|---|---|
| What | the model edits one file with text replaces; one error loses all | `keep` compiles, runs and writes /claude/helpers/<name>.lua; each file loads under its own pcall, the broken ones named |
| Lines | 0 | ~40 |
| Verification | claude_drive section 21 | extended: a broken file beside a good one |

**B**, helpers.lua still loaded first. And after a call whose top level
declares a `local`, the result notes "NAME was local to this call and is
gone" (a heuristic: unindented `local` lines, read with lib/scan).

### D7. Which new library pieces now

Each comes with a sim and a help entry. Recommended now:

1. `T.digCell(x, y, z, opts)` (with D1's guard) and `moveTo`'s
   `opts.digOnly`.
2. `T.inside` and `T.withUnprotected` taking a list of areas.
3. A breadcrumb trail and `T.retrace(n)` (the last ~200 cells crossed).
4. Crafting: `T.craftBatch(list)` (one stash for many recipes, the tool
   kept in the chest), block-to-nine recipes built in, `T.smeltAt(cell,
   item, n, fuel)` at a placed furnace, `T.craftPlan(targets)` (the
   recipe tree against the chests).
5. Storage: one record per chest (double chests and two stands merged),
   `T.where` with the age of each count, `T.fetch{stay=true}`,
   `T.inventoryReport()`, `T.prepare{need=, freeSlots=}`.
6. `T.build{order="column"}` (column by column; 807 fuel for 58 blocks
   layer by layer against 128 for 72), and a fuel watch that stops a
   build at 3 times its estimate.
7. The map keeps cubes in protected areas and round home when it evicts,
   and `T.map.pin(box)`.
8. `T.harvest{maxFuel=, timeout=, exclude=}`; `T.refuelFromLava`
   skips protected lava and takes `exclude`.

Later, in their own pass: a player-walkability checker (`T.walkable`,
stair and railing lint: ~250 lines, the biggest ask), sign text, and
placing with temporary scaffolding.

### D8. A status line on each result

**Yes:** each `lua` result ends with `[at x,y,z facing d, fuel f (-n),
k slots free]`, and "lava below/ahead/above" when the turtle sees it.
About 30 tokens a call against 300k re-read.

### D9. Telling the model what changed

**Yes:** the harness keeps the ROM version the model last ran in
/claude/.version. When it differs, the first goal carries the changes
since then from a hand-written `doc/claude-news.txt` (short, in the
model's terms: "T.digCell exists now: your helpers.lua digCell can go").
That is how a pass reaches the turtle without anyone editing its files.

### D10. The harness's own settings

- `T.cfg.maxHeight` in a claude session: 256 (relative to the start;
  mine sets 1000; farm relies on 16, so the default stays).
- An optional `review = true` on a `lua` call: show the code and ask
  before it runs (at the keyboard or by D4's chat).

## Trade-off analysis

The pass spends its risk on D1 (refusals where there were none) and D2
(a planner change with a sim expectation that changes), and on the size
of D7. It declines the walkability checker and scaffolding for now:
they're big, untested, and the model can work round them with care; the
liquid guard and the loud failures it can't work round. D3 takes the
cheap server-side step before building a trimmer whose cache cost isn't
known.

## Consequences

- The model gets reasons instead of false, and fewer ways to flood,
  starve or loop silently. Programs keep their defaults.
- mine, farm and mow reports stop carrying claude's finished job.
- The model's helpers.lua shrinks as turtlelib takes them over; D9
  tells it which.
- **The next report should watch:** whether the liquid guard refuses too
  often; tokens a call after D3; whether reminders nag; column-order
  fuel against the old figures.

## Action items

### Phase 0: the safety net

1. [x] Repeatable sims (#21).
2. [ ] A failing scenario for each confirmed defect, before its fix:
   the dig beside a moat, autoDump inside a protected area, the stale
   job line, the double chest, `T.up` at maxHeight, refuelFromLava in a
   protected area.

### Phase 1: defects (one commit each, no decision)

1. [ ] `T.up`, `T.down`, `T.forward`, `T.back` return `false, why`
   ("maxHeight 16 reached (T.cfg.maxHeight)", "blocked by X").
2. [ ] `T.keep` takes a list or a set; a warning when it's empty at the
   start of a dig job.
3. [ ] A finished job no longer rides on `T.report`; `T.job.done` on the
   last step finishes it.
4. [ ] autoDump: tidy before counting, a failure noted in the job and
   told to the caller, off after two failures in a row; `T.dumpJunk`
   walks with the path finder.
5. [ ] `T.refuelFromLava` skips protected lava.
6. [ ] The catalogue: one record per chest; `T.where` gives each count's
   age.
7. [ ] `placeAt` says which approaches it tried and what each lacked.
8. [ ] `T.inspectAt` approaches with the path finder by default.
9. [ ] `T.scanBox`'s refusal says the cost; r8 is cheap.
10. [ ] Lists and sets: `dig`, `T.keep` and the other item lists take
    either, and globs (`"*netherrack"`) wherever item names are matched.
11. [ ] "no route" says what walled it off when the search gives up
    (the protected areas and doors it met).
12. [ ] `T.fetch`'s doubled suffix; `T.smelt` takes its own furnace back
    inside a protected area (it placed it); `T.setOrigin` warns of saved
    jobs (`mine.job`, `.build`) in the old frame.
13. [x] claude (#23): `--model` takes `opus`, `sonnet`, `haiku`; `env.print`
    set before helpers.lua loads; the `context:`
    line logged only when it changes; `io.write`, `write`,
    `printError`, `setmetatable`, `getmetatable`, `rawget`, `rawset`,
    `xpcall`, `keys`, `colours` in the sandbox.

### Phase 2: what the model is told (no decision)

1. [ ] index and help: `T.keep` is a set, `maxHeight` 16, `T.job.clear`,
   protection blocks digs (not placing), harvest skips protected areas.
2. [x] The prompt (#23): globals persist and `local` doesn't; clearing doesn't
   remove definitions; plan files before a big job; a pre-flight check
   (fuel, slots, materials, protections, route, liquids); caps on every
   long loop and a call of more than a few minutes; check each result
   before telling the player it's done; short summaries; keep the
   memory notes pruned (what's current first, the rest archived to a
   file); the TTL in effect and what a longer wait
   costs; the player's preferences (keep them told, honestly; don't
   undo their changes; ask before big holes or replacing their things;
   restore floors with the same block; tidy; build for a 2-tall player:
   3 air above a stair's walking line, landings, railing corners, rails
   at drops over 3).

### Phase 3: the decisions, after acceptance

D1 to D10 as decided, one pull request per module, each with its sims.

### Phase 4: release and hand back

1. [ ] `doc/claude-news.txt` for this release; version bump (minor);
   UNTESTED.md entries; the lockstep bump in ccnix-mod.
2. [ ] The user runs `/ccnix rom update` and gives the turtle a goal:
   read what's new, retire replaced helpers, keep
   `/claude/report_harness_v3.md`.
3. [ ] Mark this ADR Accepted.
