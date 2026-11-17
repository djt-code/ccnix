---
name: big-jobs
description: Any job that digs, harvests, builds or travels a lot: scope as a box, count and estimate first, small capped batches, report each batch.
---
# Big jobs

Use before a harvest, a clearing, a long build, a scouting trip, or any loop that could run
more than a few minutes or spend more than a few hundred fuel. These rules come from a harvest
that ran 33 minutes in one call and burned 13,400 fuel for 24 ores, because "under the castle"
became "every ore below y70" and nothing in the call could stop it but an empty tank.

## Rules
1. **Scope is a box, not a filter.** Take the box from the goal's own words and write it down.
   Never a height or name filter over the whole map.
2. **Count before you dig.** `T.map.count(pattern, box)` and `T.map.find(pattern, box, limit)`;
   print the count and the box's size. If the count is far from what the goal implies, stop and
   look again (or ask).
3. **Estimate.** `T.fuelFor{ route = cells, back = true }` (or `build = plan`, or `box = ...,
   radius = 8` for scans): `info.need` against `turtle.getFuelLevel()` and
   `T.totalFuelAvailable()`. More than about 2,000 fuel or 30% of the tank: ask the player
   first, with the numbers.
4. **Small batches.** About 10 targets or 5 minutes a call, then look at fuel used, blocks got
   and where the turtle is before the next. Long calls also miss the player's chat and let the
   cache expire.
5. **Caps in the code**, always all three:
   - `T.harvest(pattern, box, n, { maxFuel = 400, timeout = 240, limit = 200 })`: read
     `info.stopped`, `info.got`, `info.spent`, `info.skipped`;
   - `T.build(plan, { limit = 40 })`, then `T.build()` carries on; `T.replace(box, pattern,
     item, { limit = 64 })`; `T.sortChests{ limit = 16 }`;
   - your own loops: fuel at the start, `os.clock()` at the start, a count; stop on any.
6. **Efficiency check.** Blocks got per 100 fuel; when it falls (the field case was 0.2), stop
   and report instead of paying on.
7. **Narrow digging.** Keep `T.diggable = {}`; give digging only for the job: `opts.move =
   { path = true, dig = true, digOnly = cellsInTheBox }`, `opts.exclude` for areas a harvest
   must leave, `T.protect` what must not be touched. Keep a fuel floor away from home (`T.homeCost()` plus a
   margin, never below about 3,000 in a hostile place).
8. **Keep the player told.** `T.job.start(goal, steps)` and `T.job.done()` per step,
   `T.report.every(n)`, and a line per batch ("quartz 8/20, fuel 12.1k"). A silent long job
   looks like a hang, and the player may stop it.
9. **Re-read the step** in `T.job.resume()` before each batch, and put the box and caps in
   `T.job.note(...)` so a later session can check the code against the words.

## Before starting
- Inventory: `T.prepare{ need = { ... }, freeSlots = 8 }`; `T.keep` holds only the job's
  materials so `T.cfg.autoDump = true` stows the rest; `T.tidyInventory()` merges split stacks
  (split stacks filled the inventory and sent autoDump on a trip every few digs).
- A pickaxe equipped for digging jobs; `T.equipped("left")`, `T.equipped("right")`.
- Write the plan to /claude/<job>.md; `T.cfg.undo = true` and `T.undoMark()` where a dig could
  need putting back.
- Scans: radius 8 or less (wider costs thousands); `T.scanBox` refuses over 27 scans.

## Pitfalls from the field
- Walls built layer by layer circled the whole shape every layer: 807 fuel for 58 blocks;
  column by column took 128 fuel for 72 (`T.build`'s `order = "column"`).
- `T.travel` into unknown terrain wandered onto an overhang; `T.retrace(n)` walks the trail
  back. Ask the player where things are before a blind scouting trip: it is cheaper.
- A route search that gives up says "no route: gave up after searching N cells without
  reaching it (opts.limit raises that)": read the whole why; raise `limit` once, on purpose.
- `T.refuelFromLava` and `T.harvest` take the nearest: exclude a moat or a decoration
  (`opts.exclude`, or protect it).

## Tell the player
Before: the box, the count, the fuel estimate and the batch size. Each batch: progress and
fuel. After: totals, fuel spent, what was skipped and why, where the turtle is.
