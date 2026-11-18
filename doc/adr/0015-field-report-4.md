# ADR-0015: What the turtle learned on 0.53: two bases, crafting counts, real seconds, and text the game can show (fourth pass)

**Status:** Accepted (2026-11-17): D1 to D8 as recommended (D7: 150k);
D9 added the same day: the server runs `/tick rate 60` for testing, so
ccnix learns the tick rate
**Date:** 2026-11-17
**Deciders:** Dan Theisen

## Context

The castle turtle ran ccnix 0.53.0 (ADR-0013) from about 13:00 UTC on
2026-11-17 into the next morning, unattended for long stretches. Its
goals were:
- finishing the castle's torch rework, cellar and keep;
- a second castle of nether brick about 110 blocks away, with a forward
  base and a smelting line;
- a road between the two;
- a keep expansion and a declutter.

Its fourth report, `/claude/report_harness_v4.md`, lists the friction it
hit, task by task. The player saw mojibake in its chat: an arrow came
out as "â" and two boxes.

Three read-only reviewers checked the report against the field log, the
library and the harness.

**The log** covers only the last eight hours (23:03 to 01:14):
- one harness session (`claude --steps 200 --cache 1h`), three goals and
  the tail of a fourth;
- 237 API calls and 214 lua calls;
- 27.4M tokens in, 98.9% of them read from the cache, 290k written and
  195k out;
- 3 compactions, all at a goal's end (summaries of 2.3k to 2.7k tokens),
  each leaving the next goal starting at about 33k;
- no "cache: written again", no context edits, no cut-off replies, no
  retries.

The 250k mid-goal mark never fired; the largest ordinary call read 183k.
One web search read 480k, because the server tool re-read a 158k context
three times. The rest of the report (Task 39, the second castle) is
older than the log and rests on the report alone.

**What the reviewers concluded:**

1. **The mojibake** is CC handing Lua strings to Java a byte a character
   (Latin-1). The chat tool showed `convert.fromUTF8`'s text on the
   turtle's screen, but sent the raw UTF-8 to chat. Fixed (Phase 1,
   below).
2. **Timeouts run about 3x fast** on this server:
   - `T.harvest{timeout = 220}` stopped after 73 real seconds;
   - `T.report.ask`'s 90, 300 and 600 s waits ended after 30, 100 and
     200 s.

   Both count game time (`os.clock`, `os.startTimer` ticks), so the
   server is ticking faster than 20 a second (`/tick rate`?). The
   model's notes then said "no reply after 15 min" when 6 had passed.
3. **Two bases confuse the store.**
   - `T.stow` sends an item to any chest whose holds match before a near
     one that already holds it, so glowstone went 110 blocks to the other
     base and back: about 330 fuel for 6 items.
   - `T.sortChests` treats every chest as one store.
   - `T.catalogue(spots)` walks every known chest, not only the spots
     (`store.lua` loads the whole list): 328 fuel for 5 chests side by
     side.
4. **Crafting counts.**
   - A round of `T.craftBatch` that fills a grid cell short crafts fewer
     and gives no reason: "made 85 of the 107 asked: the rest is short"
     with 89 bricks still in the chest, twice at 21.
   - A bare list makes no intermediates: "short of stick: need 21, have
     16". A `T.craftPlan` plan does make them, and the model didn't know.
5. **Placement gaps.**
   - Chain has no axis family.
   - `opts.hanging` isn't a key, and an unknown option is silently
     ignored (a hanging lantern "worked" by luck).
   - `T.placeInfo` says a lantern doesn't hang.
   - A fully tried build with failures blocks the next `T.build`.
6. **Wrong turns in the report.**
   - The "avoiding lantern beside the start" item is wrong: the turtle had
     sealed itself in (the why said so, and its next thought too), and
     its placement-tricks skill now teaches the wrong lesson.
   - `info.rules` does count every lint warning. `info.more` gives the
     cut. Both are in the help, not the index.
   - The 12k of repeated whys was clipped to 6k before the model saw it.
     The repeats were real, and so is a doubled "no route: no route:".
7. **The sandbox has no `load`.** The tool text lists `loadfile`, which
   compiles without running, and the model didn't connect the two.
   `helpers.lua` can't be written through `keep()`, which is how its
   migration was left half done.
8. **The model's own helpers** that would serve every session:
   - a hop loop for far `T.travel` targets;
   - serpentine paving (digDown and placeDown in rows);
   - a 3-per-move tunnel clearer;
   - a greedy light planner over its own light model.

   Its `task41.lua` replaces `T.keep` wholesale and wipes its settings'
   keep list every session.

## Decision

D1 to D8 as recommended (the user, 2026-11-17: "all recommendations
approved"), and D9.

**As built** (where the build had to choose):
- **D1:** "just as close" is within 8 blocks of the nearest chest. Between
  chests that close, the kinds decide (a chest for the item, then one
  holding it, then the bulk chest), so a single base keeps sending items to
  their own chests. The reach is measured from where the stow began.
  `T.sortChests` sorts the site nearest the turtle (or `opts.near`, or the
  sites in `opts.box`).
- **D2:** "more specific" is fewer wildcards, then more letters. The overlap
  warning finds a name both globs take from their letters and the names in
  the chests, so it can miss an overlap; it warns, nothing more.
- **D3:** a dig is refused when no slot is free and no stack of its drop has
  room. The drop is the block itself, or cobblestone for stone and the like.
- **D4:** each leg is about 16 blocks and searches with the default limit.
  A leg that fails tries 3 higher, 3 lower and 6 higher; at most 64 legs.
- **D5:** the check looks for a way out over the map, through cells empty or
  never seen (a cell never seen counts as open), to 12 blocks or to
  `opts.exit`. It runs before each placement; `T.build` passes `opts.exit`
  to every cell and lists the warnings in `info.sealed`.
- **D8:**
  - `T.pave`, `T.clearBox` and `T.sweep` are a new module, `tl.area`.
  - `T.replace` goes through a neighbour with `opts.digBelow`, plain blocks
    only.
  - `T.boxOf`, `T.excludeTest` and `T.dropsItself` became the library's
    (each was a module's own).
- **D9:** the first measure comes 2 real seconds after boot, then every 10 or
  more; a span over a minute is thrown away.
  - What else moved to real seconds: DNS (its timeout and TTLs), httpc,
    httpd's idle cut, IRC, ping, nc, git's backoff, claude's API retries and
    the geo scanner's retries.
  - What stayed on ticks: crops, furnaces, redraws, and the checks that
    give the computer a turn.

## Options considered

### D1. Two bases: stow and sort by distance

- **The problem:** `T.stow` ranks chests by tier (holds, then already
  holding, then bulk) before distance, and `T.sortChests` sorts across
  every chest.
- **A. Nearest within reach first (recommended):**
  - `T.stow` takes the nearest chest that will have the item, in any
    tier, within `opts.maxDistance` (default 48);
  - farther than that, it says where and how far, and goes only with
    `opts.far = true`;
  - `T.sortChests` sorts within groups of chests no more than 48 apart (a
    site), never between them;
  - `opts.near` / `opts.box` scope either.
- **B.** Keep the tiers, add the options only.
- **C.** Leave it.

### D2. Overlapping holds

- **A. The most specific pattern wins, with a warning (recommended):**
  - fewer wildcards, then the longer literal part, so `*brick*` beats
    `*_stairs`;
  - `T.addChest` warns when a new hold overlaps another chest's, naming
    both.
- **B.** The first chest added wins.
- **C.** Warn only.

### D3. A dig with nowhere to put what it drops

Items spill on the ground today. The fix is `T.cfg.digNeedsRoom`: a dig
with no slot for its drop is refused, with a why.
- **A. On in the claude sandbox only, off for programs (recommended):**
  mine, farm and mow already make room their own way.
- **B.** On everywhere.
- **C.** Off; document `T.cfg.autoDump`.

### D4. Far `T.travel` targets

The search limit fails them today.
- **A. Hop on (recommended):** on "search limit", `T.travel` goes in legs
  of about 16 blocks toward the target, scanning (radius 8, free) at
  each, under `opts.maxFuel`. It says it hopped.
- **B.** An `opts.hop` the caller asks for.
- **C.** Only a better why.

### D5. Placements that close the last way out

- **A. Warn (recommended):** `T.placeAt` and `T.build` warn when a
  placement leaves the turtle with no route to `opts.exit` (or out of the
  enclosed region it stands in), checked on the map, and refuse with
  `opts.exit` given.
- **B.** Refuse always.
- **C.** Nothing.

### D6. Digs that destroy what they dig

Glowstone gives dust; with no silk touch, glass and ice give nothing.
- **A. `T.digCell` refuses (recommended):** it names what the block gives
  instead, and digs with `opts.lossy = true`. Raw digs and programs are
  untouched.
- **B.** Warn only.
- **C.** Nothing.

### D7. Compaction mid-goal

The 250k mark (the user's, ADR-0013 D9) never fired; goals peaked at
183k. A mid-goal compaction costs one read and about 3k out, then saves
about 115k of reads on every later call, so it pays back in about 2
calls; the price is the summary's loss of detail.
- **A. Keep 250k:** it acts only as the safety net it was meant to be.
- **B. 150k (recommended):** it would have fired twice in this log.
- **C.** 180k.

The summary instructions also keep "what's new in this release" (the
news is told once).

### D8. New functions from the model's helpers

Each comes with a sim and a help entry, and the turtle retires its copy.
1. **`T.planLights(cells, candidates, opts)`:** greedy cover to light 8
   (overworld) or 12 (nether), over T.light's model, a few calls. The
   model's `roadlights.lua` did this.
2. **`T.pave(box, item, opts)`:** serpentine rows along the long axis,
   digDown and placeDown, 1 move a cell; `opts.exclude`.
3. **`T.clearBox(box, opts)`:** a tunnel or room cleared 3 rows a move
   (dig up, down and ahead), `opts.exclude`, `opts.maxFuel`.
4. **`T.sweep(box)`:** picks up items lying in the box, never sucking
   from a container.
5. **`T.replace` of a trapped cell through a neighbour:** reusing
   placeAt's digBelow (dig a neighbour floor, stand in it, put it back).
6. **`T.walkable{ with = ... }`:** what-if cells, as `T.darkCells` has.
7. **The sandbox:**
   - `check(code)` compiles without running;
   - the tool text names what's absent (load, loadstring, _G,
     coroutine);
   - `helpers()` lists each helper file's globals and those that shadow
     a T function.

All recommended. Left out: a scout line (world-specific).

### D9. The tick rate (added 2026-11-17)

- **The cause:** the dev server runs `/tick rate 60` to speed testing.
- **What it breaks:** CC's timers and `os.clock` count game ticks, so
  every "seconds" in ccnix runs 3x fast there:
  - the turtle's harvest and chat-ask timeouts;
  - lib/net's TCP timers (retransmit, `await` deadlines, the 0.5 s tick,
    lib/net.lua:1145, 1313, 1339);
  - sleeps.

  About 29 files use `os.startTimer` or `os.clock`.
- **Decision (the user's ask: "the tick rate should be known to ccnix"):**
  - ccnix measures it: game seconds (`os.clock`) against real ones
    (`os.epoch("utc")`) since the computer started, settled after a few
    seconds and re-measured now and then. The server's `/tick rate` can
    change while it runs.
  - It's exposed as `ccnix.tickRate()` (20 normally) and a small
    `lib/realtime`:
    - `realtime.now()` gives real seconds;
    - `realtime.timer(s)` is a timer that fires after s real seconds;
    - `realtime.sleep(s)`.
  - Timeouts and protocol timers that mean wall-clock time use it:
    - TCP's retransmit and keepalive (a peer outside the game counts real
      seconds);
    - chat asks;
    - `T.harvest`'s timeout;
    - claude's status line.
  - What means game time stays on ticks: a crop's growth, a furnace, the
    in-game clock.
- **Sims:** a sim clock at 60 ticks a second shows a 600 s ask lasting
  600 real seconds, and TCP's retransmit keeping real time.
- **ccnix-mod:** the gateway's TCP runs in Java on real time, so it needs
  nothing. `/ccnix` could show the tick rate (later).

## Trade-off analysis

- **D1:** distance-first can leave an item in a chest of the wrong kind
  near by. The holds still win when a matching chest is just as close,
  and the far ones are reported, not ignored.
- **D3 and D6:** refusals cost the model a retry with an option, but each
  refusal says why, and that's the lesson. Programs aren't touched.
- **D4:** hops spend fuel the plain search wouldn't. The cap and the
  message keep it visible.
- **D7:** a summary loses detail. The notes and skills hold what must
  survive.

## Consequences

- **Report v5 should show:**
  - no mojibake;
  - timeouts in real seconds;
  - stow and catalogue costs at two bases;
  - craftBatch counts;
  - whether the mid-goal compaction fired and what it cost;
  - whether the new functions replaced its helpers.
- **The model learns from "what's new":**
  - its lantern lesson in placement-tricks is wrong (it sealed itself
    in);
  - `task41.lua` wipes its keep list;
  - which helpers to retire.
- **mine, farm and mow:** D1 and D3 don't change them; the clock fix
  only makes their timeouts real.

## Action items

### Phase 0
1. [x] Baseline twice, byte for byte (done: identical).
2. [x] Each field failure a scenario first, failing on today's code:
   - chat with an arrow;
   - a sign with one;
   - the harvest timeout on a fast clock;
   - stow at two bases;
   - catalogue(spots);
   - a short craft round;
   - chain and a hanging lantern;
   - a fully tried build.

### Phase 1: no decision
1. [x] Chat and sign text through `convert.fromUTF8` (lib/mc's queue,
   place.lua's sign lines).
2. [x] Timeouts in real seconds (`os.epoch("utc")`): `T.harvest`,
   `T.report.ask`, and the others that count seconds by ticks.
3. [x] `T.catalogue(spots)` goes round only the spots.
4. [x] Crafting:
   - a short round says which ingredient came up short and how many;
   - the batch's room check counts every product;
   - the cause of the short rounds found and fixed (suspected:
     `frontStack` borrowing a grid slot when the chest is full; mine and
     farm restock through it, so they get a scenario too).
5. [x] Placement:
   - chain gets an axis family;
   - lanterns get `hanging`;
   - `T.placeInfo` says they hang;
   - an option placeAt doesn't know is named in the why or the info, not
     ignored.
6. [x] A build with every cell tried no longer blocks the next. Its
   failures stay listed, and the refusal of an unfinished one counts
   them.
7. [x] `T.darkCells`:
   - `info.unsure` is a list of cells;
   - the summary says "listed N of M".
8. [x] `T.lint`: `opts.rules` picks the rules, and a limit is shared
   between them, so one rule can't take it all.
9. [x] `T.scanBox` routes with `path = true` and scans from where it got
   to when a tile's centre can't be reached.
10. [x] `T.posKey`, `T.dist` and `T.at` say what they want when given a
    list.
11. [x] Wording: no "no route: no route:".
12. [x] The harness:
    - repeated lines in a lua result shown once, with a count;
    - the "local to this call" note not given for a global;
    - no "(3 characters left out)".

### Phase 2: what the model reads
1. [x] Index lines:
   - digBelow;
   - darkCells' limit and `info.more`;
   - lint's `info.rules` and `info.more`;
   - `T.protections` field names;
   - the catalogue spot format;
   - `T.prepare{ need = plan.base }` before `T.craftBatch`;
   - a bare craft list makes no intermediates (use `T.craftPlan`);
   - scanBox `opts.move`;
   - stow's order.
2. [x] The tool text: what the sandbox lacks, and `loadfile` as a
   compile check.
3. [x] "What's new" for 0.54.0, in the model's terms:
   - the retirements;
   - the wrong lantern lesson;
   - `task41.lua` and T.keep;
   - the server's fast ticks.

### Phase 3: the decisions
1. [x] D1 to D8 as decided.
2. [x] D9: `lib/realtime` and `ccnix.tickRate()`, and the timers that
   mean real time moved onto it (Phase 1 item 2 becomes part of this).

### Phase 4: release (on the user's ok) and hand back
1. [x] News (doc/claude-news.txt 0.54.0) and UNTESTED.md's section with its issue (#102).
2. [ ] Version bump and release: on the owner's ok, with ADR-0014's.
3. [ ] The next goal: "read what's new, retire the helpers it names, fix
   your placement-tricks skill and task41.lua, and keep
   /claude/report_harness_v5.md as you work".
