# ADR-0023: What the turtle's v7 test pass found: mod blocks, lava in the nether, the dimension, the log and the cold cache (eighth pass)

**Status:** Accepted (2026-11-27): D1 to D8 as recommended (D1: `auto` by default, the mod's answer next, as B); released as ccnix 0.56.0 (2026-11-27)
**Date:** 2026-11-27
**Deciders:** Dan Theisen

## Context

The castle turtle, now based in the nether, ran the v7 test plan (`/claude/tests-v7.md`) against ccnix 0.55.0
and ccnix-mod 0.27.5 from 02:06 to 02:29 UTC on 2026-11-27, with a reboot check at its end. It wrote its results
in `/claude/test-v7-results.md` and its eighth report in `/claude/report_harness_v8.md`. Its tally: 21 PASS,
1 FAIL (G1), 0 SKIP and 2 INCONCLUSIVE (A2, C8). The 21 checks that passed were closed with their evidence,
the facade bug (#392, ccnix-mod#27) among them: `true nil 1` twice. After the pass, the player gave it a
statue and a bigger grove to build.

This pass takes the pass's FAIL and INCONCLUSIVEs, the friction in its report, and three issues left from the
fetch before it: #393 (picking stacks by item detail), #394 (what the web tools' code execution can see) and
#395 (the cold cache before a goal).

Three read-only reviewers checked the findings against the field log, the library and the harness.

**The log** covers everything since the last fetch: two sessions (the second after the reboot), six goals.
- 149 API requests: 131 lua calls, 9 memory calls, 16 chat messages (13 asks).
- 11.69M tokens in, 98.4% read from the cache, 185k written, 75.5k out (31k of it thinking).
- The test plan alone: 112 requests, 8.95M in (20% less than v6's 11.26M), 139k written, 48.7k out.
- The largest context was 119k, at the reboot, so no compaction. No retries, no cold-cache rewrites: the 1h
  cache survived the reboot (31k read on its first call).
- Three code errors, all the model's own (a nil slot, a nil peripheral, `T.pos[2]`).

**What the reviewers found:**

1. **G1, the start line after a reboot: the plan expected the wrong source.** On `--resume`, the options come
   from `resume.txt`'s `options:` line first (`turtle/claude.lua`, the resume block), so `claude.options`
   supplies none and the line rightly doesn't name it. What it doesn't do is name `resume.txt` (#404).
   On the way: `--confirm` is written into `resume.txt` and comes back on an unattended resume, against
   the rule `claude.options` follows (whoever is at the turtle now decides).
2. **`T.placeAt` can't place an AE2 cable.** It accepts a placement only when the block's name is the item's,
   or the vanilla tables map one to the other (`isItem` in `turtle/tl/place.lua`). AE2 places every cable and
   part as `ae2:cable_bus`, so each placement looked wrong, was dug back, and six ways were tried: 23 fuel.
   `T.build` (blueprint `isBlockOf`) and `T.lint` (through `blockOfItem`) test the same way. AE2 maps many items
   to one block, so a fixed block-to-item row can't work; item to block can.
3. **C8, `T.refuelFromLava`: a design gap, and a test that couldn't work.**
   - Candidates are the map's lava cells by name, less those whose known state has a level other than 0. A
     Geo Scanner scan records names without states, so a lava fall looks like three sources: it walked 108
     fuel out of the test area and found three flowing cells down one column.
   - It has no distance limit: only `exclude`, `tries` and `move`.
   - The flowing cell B was never a candidate, because the model's own look had recorded its level. Its
     `T.map.set(B, "minecraft:lava")` kept that state, as documented: a nil state keeps the old one, `{}`
     clears it.
   - The owner's direction (2026-11-27): in the nether, lava is everywhere at the bottom. A turtle there only
     needs to go down to the lava sea, through whatever layers are in the way, and take it.
4. **The dimension is a per-call option.** `T.darkCells` and `T.planLights` take `opts.dimension`, else
   `T.cfg.dimension`, else the overworld. The model ran its first lighting plan at the overworld's limit,
   then set `T.cfg.dimension = "nether"` for the session. Nothing keeps it, and nothing else knows it.
   The owner (2026-11-27): the claude turtle should know which dimension it is in, maybe as a turtlelib
   setting. The map and the saved position have the same blind spot: one map for every dimension, and GPS is
   per dimension (`turtle/tl/world.lua` says it can't tell).
5. **`T.craftPlan` names the wrong shortage when only a loop is left.** Asked for an iron ingot with none in
   reach, it planned 9 ingots from an iron block and named the block as short. The loop guard (#346) works
   only when the ingot is in stock: an inner trial's loop isn't marked in the outer one, so the block's
   "short 1" beats the nuggets' "short 9". The symmetric case is in the sims: a coal block with no coal names
   "coal 9" today, and the fix would make it "coal_block 1".
6. **`T.moveTo` after `T.placeAt` went into the placed block,** twice. `moveTo` goes in straight runs (y, x,
   z) and routes round only with `opts.path`, which the model didn't pass. `placeAt` had climbed onto the
   block to place it from above rather than turn round: its cost counts a move the same as a turn.
7. **`turtle.drop` with nothing in front dropped 30 nuggets on the ground** (the knock-on of 6). `turtle.drop`
   isn't wrapped, and can't be: `mine` throws junk away on purpose, and composters aren't inventories. There is
   no T function that drops into a container and refuses when there isn't one.
8. **#393 mostly exists.** `T.pull` and `T.fetch` take `opts.pick(detail)`, with the chest's item detail
   (display name, components). The index doesn't say so. `T.takeInto` has no `pick`, and the slot searches
   (`T.findSlot`, `T.selectItem`, `T.countItem`) see only the basic detail.
9. **The log: harness lines and the model's text look alike.** `log()` stamps an entry's first line only, and
   code, results and thinking go in verbatim, so a result that prints an old start line, or thinking that
   says "start:", reads as an entry. The model's search for its start line found its own code twice.
10. **#394 and #395, with numbers.** The web tools' code execution is logged as a bare name. The "64k" and
    "323k" calls of the last fetch were sums of the server tool's passes, mostly cache reads, not context.
    For #395, the goals ended at 51k to 69k: a boundary lowered to 60k would have compacted a statue
    conversation 76 s before the next goal about the same grove, on a warm cache. Compacting before a goal on
    a cold cache (A) only saves if the compaction request doesn't itself write the whole conversation at the
    1h price.
11. **Smaller things.**
    - A `turtle.dig()` with nothing in front still swaps the pickaxe on (and the chat box off).
    - `T.stow({only = ...})` of kept items moves nothing and says nothing.
    - `T.build` placed a torch as a wall torch where nothing was asked of its state; `T.verify` then called it
      wrong.
    - Lint warnings go to the player's chat during a build ("(and 23 more like it)").
    - The skills nudge offers unrelated skills for "great work buddy!" (any one shared word fits), and six on a
      resumed goal, matched on the resume wrapper's words.
    - A dug block whose drops aren't its own name (a cable bus gives a cable and a facade) doesn't join the
      part stack.

## Decision

### Phase 1: defects (no decision needed)

1. **Mod blocks placed under another name.** After a place into an empty cell with no state wanted, when the
   item count dropped by one and the item has no known block, `T.placeAt` accepts the block and learns the
   pair (item to block) in its learned placements; `T.blockOfItem` reads the learned pairs, and `isItem`,
   blueprint `isBlockOf` and lint accept `T.blockOfItem(item) == name`. `how.placedAs` names the block.
   (Limit, said in the help: a cable bus of another colour passes too; AE2's block state doesn't carry the
   cable kind.)
2. **`T.placeAt`'s cost weighs a move above a turn,** so it doesn't climb onto a block to place it from
   above when turning round would do.
3. **`T.moveTo`'s "blocked by" names `opts.path`** ("blocked by X at ...; opts.path = true routes round it").
4. **The start line names `resume.txt`** when the options came from it: "; resuming the goal in resume.txt,
   with its options: ..." (#404).
5. **The log:** an entry's later lines are indented with a tab, so only harness entries start at column 0
   with a time. The help and the news say so.
6. **`T.stow({only = ...})` says what it left:** the kept items it skipped, by name, in its why.
7. **`T.verify` accepts the wall form of an item** where the plan asked no state, as `T.placeAt` does.
8. **The skills nudge:** "work", "great", "buddy" and the like are stop words, and a resumed goal is matched
   on the goal, not the resume wrapper.
9. **A failed dig doesn't swap tools:** the tool hook looks before it swaps.

### Phase 2: what the model knows (no decision needed)

1. The index: `T.pull`'s and `T.fetch`'s `opts.pick` (#393), `T.takeInto` takes `pick` too.
2. The help: `T.map.set(x, y, z, name, {})` clears a cell's state.
3. The system prompt (#394): the code execution that comes with the web tools runs on Anthropic's side and
   can't see the turtle, its files or the world; the log names `code_execution` and `bash_code_execution`
   with their input.
4. The next test plan: A2 with a blocker that obstructs (an armor stand, or a mob); C8 as the nether case
   (D3); G1's expected line; B3's question asks for the mod's version by name.

### Decisions (the owner's)

- **D1. The dimension.** The owner (2026-11-27): the turtle can tell from the blocks it sees, so the default
  is `auto`.
  - **A (recommended):** a turtlelib setting, `turtle.dimension`: `auto` (the default), `overworld`,
    `nether` or `end`. A named dimension is used as it is. `auto` goes by the blocks round the turtle: what it
    sees next to it (a look up, down and ahead, no fuel) and what the map has near its position. Blocks that
    occur naturally in one dimension only count for it: netherrack, basalt, blackstone, soul sand and soul
    soil, the nylium, nether ores for the nether; end stone for the end; stone, deepslate, tuff, dirt, grass
    and water (which can't be placed in the nether) for the overworld. A clear majority decides; with too
    few, or a near tie, it is the overworld, and it says it isn't sure. `T.dimension()` gives the dimension and
    how it was decided (`"set"`, or `"auto"` with the counts); `T.cfg.dimension` follows it, so everything
    that asks (lighting, D3's lava) has it. The claude harness says it on the start line and in the prompt
    ("in the nether, from the blocks round it"). A build of nether blocks in the overworld is the case `auto`
    can get wrong: the setting is there for it.
  - **B:** A, plus the mod tells it: ccnix-mod gives the computer's dimension to Lua (needs checking: a Lua
    API from the mod, through CC: Tweaked's API factory and the computer's level). Under `auto`, the mod's
    answer comes before the blocks; `auto` by the blocks stays for a turtle without the mod; a named setting
    that disagrees with the mod gets a warning, as GPS does for the saved position. A lockstep change.
  - **C:** A, plus an Advanced Peripherals Environment Detector when one is attached (needs checking: its
    dimension method's name and value).
  - Recommendation: A now, B next (the mod is on every server ccnix runs on, and it can't be wrong).
- **D2. The map per dimension.** Today one map holds every dimension, so a portal trip mixes them. Recommended:
  once D1 says which, the map and the saved position are kept per dimension (`.map/<dimension>/`); the map
  there now becomes the dimension D1 gives when it is first read. With `auto`, the look next to the turtle
  comes first (the map it would read is the question), and a change of dimension switches maps.
- **D3. `T.refuelFromLava` (C8).**
  - **A (recommended):** a distance limit, `opts.within` (default 64 from where it starts; a new limit, so
    yours); sources it has seen at level 0 before cells known by name only; after a "flowing" find, the rest
    of that column is skipped. And in the nether (D1), with no source within reach: down to the lava sea,
    digging through what's in the way (never into a protected area), dropping through caverns, taking sources
    at the surface, and back up. In the overworld, as now.
  - **B:** only the limit and the ranking; the nether case left to the model.
- **D4. `T.craftPlan`'s shortage when every recipe goes round through the item.**
  - **A (recommended):** name the item asked for: "iron_ingot 1", and "coal_block 1" for the coal block (the
    sim check changes), with the recipe it would have used in the why ("from 9 coal").
  - **B:** keep naming the input ("coal 9"), and special-case only the uncrafting direction (the ingot from a
    block), which is asymmetric.
- **D5. `T.dropInto(side, n)`:** a drop that refuses, with why, when nothing on that side holds items;
  `turtle.drop` stays as it is. Recommended: yes, with an index line pointing at it.
- **D6. #395, the cold cache before a goal.**
  - **A (recommended):** before a goal, if the cache has gone cold (the last reply older than the cache's
    lifetime, less a margin) and the conversation is over 50k, compact first, with the compaction request
    sent without the top-level cache mark (needs checking: that the next request still finds the system
    prompt cached).
  - **B:** lower the boundary from 100k: the field numbers above say it would compact warm conversations for
    nothing.
- **D7. `--confirm` on a resume:** no longer kept in `resume.txt`, as `claude.options` doesn't keep it.
  Recommended: yes.
- **D8. Lint warnings during a build:** only the count to the player's chat ("lint: 24 warnings, in the
  result"), the list in the result. Recommended: yes.

## Consequences

- Placing a mod block that sits under another name works the first time, and is learned; the 23 fuel of a
  failed cable is gone. A wrong item that happens to place a known block still fails as before.
- The turtle knows its dimension across sessions; the lighting limit and lava follow it. With D2, a portal
  trip no longer mixes maps.
- `T.refuelFromLava` stops wandering: it stays within reach, and in the nether it goes where the lava is.
- The log can be searched for harness entries at column 0.
- **What the next report should watch:** placing other mods' blocks (Create, AE2 parts other than cables);
  whether the dimension is ever wrong; how far a nether refuel goes and what it digs; how often a goal
  starts on a cold cache, and what compacting first saves.

## Action items

- [ ] Phase 1, items 1 to 9 (turtlelib, claude), each with a sim check that fails before it.
- [ ] Phase 2, items 1 to 4.
- [ ] D1 to D8 as decided.
- [ ] The news lines, the release, the in-game checks and the v8 test plan.
