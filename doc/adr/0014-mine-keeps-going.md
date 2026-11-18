# ADR-0014: mine keeps going: growing home chests, hauling when full, waiting for supplies

**Status:** Accepted (2026-11-17): D1 to D7 as the user decided them;
D8 and D9 are the user's asks ("use the new turtlelib functions",
"correct the sim where testing showed it wrong"), as the reviews found them
**Date:** 2026-11-17
**Deciders:** Dan Theisen

## Context

An endless 10x10 tunnel (`mine.length=0`, homes every 16) stopped on its
own after three homes. The stop message said:

```
Stopped: 3 homes built, 2 veins (11 ore blocks), 5 fluid blocks sealed, ...
No room to bring back 178 items from home 3 (z=48).
Stopped because: The chest at home 3 (z=48) is full. `mine --resume` carries on.
```

At 10x10, a 16-block segment digs about 1,600 blocks. Each home is one
27-slot chest for valuables and one for bulk:

- **The valuables chest:** it takes everything that isn't bulk (raw
  copper and iron, redstone, lapis, coal), plus the supplies that move
  forward with the homes (chests, fuel, torches, wood).
- **The bulk chest:** it takes about 25 stacks for that segment, which
  mixed stone types can push past 27 slots.
- **The stop message:** it doesn't say which of the two chests was full.

`unload` reports any chest that didn't take everything as "full", and
`unloadOrStop` ends the run there (`turtle/mine.lua`, `unload`,
`unloadOrStop`).

Two more ways a run ends early or wastes its time:

- **Out of chests or fuel:** the run ends at the start, and only a
  person running `mine --resume` after restocking carries it on. The
  autostart leaves a stopped tunnel alone.
- **A new tunnel over an old one:** the supplies stay in the last home
  (by design, for `--resume`). So `mine --new` from the same start finds
  no chests in the start's chest and stops early. It also digs the
  finished segments over again, at full mining speed, through air.

The user asked for:
- a mode that hauls until everything is home and then carries on, as long
  as the start's chest has room;
- home chests that grow as needed, using the fewest chests;
- empty extra chests picked up when hauling;
- a setting to haul every N homes;
- the bulk chest filling never to stop a run;
- mine to use the new turtlelib functions;
- the mine sim corrected where in-game testing showed it wrong (after the
  changes are tested against today's baseline, as their own step).

### What the game does with chests a turtle places

From CC: Tweaked's source (`TurtlePlaceCommand`, `TurtlePlayer`, 1.21.x):

- **No sneaking:** the turtle's player never sneaks.
- **Facing:** placing forward, it faces the target. Placing up or down,
  it keeps the turtle's yaw.
- **Joining:** `ChestBlock.getStateForPlacement` (not sneaking) faces a
  new chest toward the placer. It joins a single chest beside it, to the
  left or right of that facing, if that chest faces the same way, making
  a 54-slot double chest.

At a home, both chests are placed while the turtle faces the wall:
`placeChest(WALL)` turns it, then `placeChest("down")` keeps the facing.
So both face into the tunnel, and a second chest placed the same way at
z-1 (or z+1) joins each of them:
- **valuables:** in the wall, from the tunnel cell at z-1, facing the wall;
- **bulk:** under the floor at z-1 (over the ceiling, going down), from
  the same cell, with the same facing.

Each half of a double chest keeps its own 27 slots. Breaking one half
spills only its own items, so the turtle only breaks a half once the
whole double chest is empty.

## Decision

D1 to D7 below, as the user decided on 2026-11-17 (the recommendations,
with the user's changes: D2 grows chests as needed instead of a
`--double` option, D3 never stops, D1 adds hauling every N homes). D8
(turtlelib) and D9 (the sim) follow from the reviews.

## Options considered

### D1. Haul when full, and every N homes

When a home's valuables chest is full, even after growing (D2), the
turtle doesn't stop. Instead it:
1. walks back to the start collecting, as now, picking up the empty
   extra chests on the way (D2);
2. makes more trips (as `mine haul`) until no home has valuables left;
3. walks straight back out to the home it was working from (no going
   over the segments) with what the start's chest holds for it (chests,
   fuel, torches);
4. carries on where it was.

- **When it stops:** only when the start's chest can't take what it
  brings (the user's "as long as the home valuables chest isn't full").
- **Settings:** `mine.haul` (default true; false stops as before), and
  `mine.haulEvery` = N, which hauls after building every Nth home
  (default 0: only when full).

### D2. Home chests grow as needed

Each home starts with one chest of each kind, as now, so a home uses no
more chests than it needs.

- **Growing:** when one is full, the turtle places a second chest beside
  it, which joins it into a double chest (above). A chest for growing
  comes only from spares beyond the two the next home needs. With none
  spare, valuables go to D1 and bulk goes to D3.
- **Where the second chest goes:**
  - **valuables:** at z-1, or at z+1 when a torch niche is at z-1;
  - **bulk:** at z-1.
- **Checking the join:** the turtle checks the chest's size afterwards
  (54). A chest that didn't join is still used, and the log says so.
- **Saved:** the job file notes each home's grown chests, so `--resume`,
  `reset` and `haul` know them, and they are protected like the first.
- **Picking chests up:** when hauling leaves a grown valuables chest
  empty, its second chest is picked up (dug, the wall cell filled with
  bulk) and goes back with the supplies. Bulk chests are never emptied,
  so theirs stay.
- **A double is the limit:** past it, there is one chest per side the
  turtle can reach from the home's cell. That covers a segment's bulk
  with room to spare at the spacing mine chooses, and up to about twice
  that. Past it, valuables haul (D1) and bulk overflows (D3).
- **Spacing:** the rule stays as it is (a single chest's 75%), so most
  homes stay single.

### D3. A full bulk chest never stops the run

When a home's bulk chest is full and can't grow (no spare chest, or it's
a double already), the bulk that doesn't fit is thrown on the tunnel
floor behind the home. It despawns after five minutes while the chunk is
loaded. The final line counts what was thrown away.

### D4. Waiting for supplies instead of stopping

When the next home can't be built (out of chests), or there isn't enough
fuel to go on, the turtle:
1. goes back to the start, hauling on the way (D1);
2. tells the player what it needs (`T.report`, when `mine.report` is on);
3. looks in the start's chest every minute, refuelling from it;
4. walks out and carries on once there's enough.

- **Setting:** `mine.wait` (default true; false stops as before).
- **Interruptions:** Ctrl+T and `service stop mine` end the wait. A
  reboot while waiting resumes the job, which waits again.

### D5. Carrying on a tunnel instead of digging it again

- **`--new` on the same tunnel:** `mine --new` (or a run from the
  settings) at a start whose saved tunnel has the same width and height
  carries that tunnel on, as `--resume` does. It keeps the tunnel's own
  spacing and says so.
- **A finished tunnel:** `--resume` accepts a finished tunnel when the
  length now asked for is longer, or has no end.

### D6. Supplies come home when the tunnel is finished

When a tunnel reaches its length, the turtle also brings the supplies
back from the last home: chests, fuel, torches, the crafting table and
the bucket. A stop part way leaves them there for `--resume`, as now.
`mine haul --supplies` brings them back on demand.

### D7. The stop message names the chest

"The valuables chest at home 3 (z=48) is full" or "...bulk chest...".
With D1 to D3 this message is rare.

### D8. turtlelib functions in mine

A read-only review checked mine.lua against turtlelib 0.50 to 0.53. It
found three fits that change nothing a player sees:

1. **Crafting through T.craftPlan and T.craftBatch.** mine keeps its own
   policy, `craftPlan` (how many chests and torches, the coal kept back
   for fuel), and hands the counts to the library. That replaces about
   140 lines: `RECIPE_SLOTS`, `emptyOut`, `roomIn`, `craftSteps`,
   `pickaxeOn` and the swap in `craftSupplies`.
   - The library puts the crafting table on through `T.withPeripheral`
     (the chunk controller stays put).
   - It puts each stack back in its slot.
   - It re-raises Ctrl+T.
   - mine first moves the bulk it carries into the bulk chest
     (`unload("bulk")`), and passes the chest's side (`opts.chest`).
2. **`tellPlayer` through `T.report.try`**, with `opts.from` for the chat
   box in the start's chest.
3. **`protected()` through `T.neverDig`**: the same lists, kept in one
   place.

Not a fit:
- **T.stow and T.addChest:** they assume one bulk chest, and never move
  fuel or the crafting table.
- **T.digCell:** it refuses wet ground, which mine digs and dries.
- **T.light and T.darkCells:** they measure the map, and mine plans
  ahead without one. Its target is light 2; theirs is 0 in the overworld.
- **T.attachedTo:** it needs a map on disk. mine's own torch list
  (`torchBy`) already covers the torches it knocks off.

It also found these bugs, fixed with this work (no decision). One more
claim, that `mine.map=false` doesn't keep mine out of the map, isn't a
bug: the setting (and the header) only ever covered the scans, and digs
and moves add to a map other programs started, as they should.
- **A crafting return that strands the scanner and bucket:**
  `craftSupplies` returns early when it can't empty out, leaving the Geo
  Scanner and bucket in the chest. The library path removes that branch.
- **Ctrl+T swallowed while crafting:** a `pcall` around the craft call
  swallowed it. The library path removes that too.
- **`bulkOutOfValuables` and the filler stack:**
  - it drops every stack of the item it moves, including the stack of
    filler the turtle keeps for water on the way back;
  - when the bulk chest is full, it puts that filler into the valuables
    chest, which is bulk in a valuables chest.

  It now moves only what it took.
- **Wide tunnels:** the header says torches go on both walls "wider than
  8"; the code does it from 10. From about 27 wide, the middle of the
  floor stays dark whatever the spacing. The header gets the right
  number, and mine warns before digging a tunnel too wide to light.

### D9. Correcting the mine sim

A read-only review compared `sim/lib/mineworld.lua` (and `mock.lua`
under it) with what in-game testing showed. It drew on the turtle's
reports and notes, the memory of earlier field runs, ADR-0011 to 0013 and
UNTESTED.md.

**Confirmed in game, so corrected (Phase 2):**

1. **Water** spreads evenly and reaches the turtle's block first. In game
   it heads for the nearest drop, and the endless back-and-forth trace
   passes seen in game never happened in the sim. The model gets the
   game's flow toward a drop (shortest path to a hole within 4, as
   `FlowingFluid` does).
2. **Lava** never flows in the sim. In game, digging beside lava sources
   let it pour in from above. Lava gets the same flow as water (reach 4
   in the overworld, slower), and lava meeting water makes stone or
   obsidian.
3. **Rock:** every cell is one of seven stone types. In game a cavern of
   dripstone blocks ran the turtle out of filler. The world gets patches
   of other rock (dripstone block, calcite, clay, moss, mud, tuff).
4. **Players and other entities in the way:** the sim's moves only check
   blocks. In game, players got in the way. A scenario can put an entity
   in a cell, and the move fails with "Movement obstructed" until it
   leaves.
5. **The chunk controller:** in game one is always equipped. It becomes
   the default equipment, with the old free side as the exception.
6. **Scans carry no block state** in game (ADR-0012); the sim's scanner
   stops returning them. mine doesn't read them anyway.
7. **Stops:** a reboot when the chunk unloads can't be held back by
   T.run, so a dig or move can happen with the position not yet saved. A
   knob, `REBOOT_AFTER`, stops a scenario after a move with no save.

**Likely, not yet seen in game: corrected too, each marked in the sim as
needing an in-game check (UNTESTED.md):**
- **Ore drops:** copper 2-5, lapis 4-9, redstone 4-5, gravel's flint
  (the sim gives one each).
- **Coal blocks** burn for 800.
- **Torches:**
  - none placed in water;
  - none on top of a chest;
  - one knocked off by a dig lands on the ground.
- **Gravity:** red sand, suspicious sand and gravel, and concrete powder
  fall too.
- **The scanner's cooldown:** a second scan within a second fails, so
  mine's retry path runs.

Each correction is its own commit. Its changed checks are explained in
the pull request: a check that turns red is a mine bug the correction
found, fixed in mine (never by loosening the check).

What the features above need from the sim is part of their own work:
- chest facing and double chests;
- digging a chest (empty: the item; not empty: its half's items spill,
  counted so a check can say none did);
- dropping into air (an item on the ground, not an error).

The corrections the review finds come after the features, as their own
pull request: the baseline is taken first, the features are tested
against it, and then each correction's changed checks are explained one
by one. That way a correction can't hide a regression.

## Trade-off analysis

- **Throwing bulk away (D3)** loses stone nobody asked to keep, in
  exchange for never stopping. Dropped items despawn, so they don't pile
  up while the chunk stays loaded.
- **Hauling (D1)** costs a round trip of `2 x z` fuel each time. That
  grows with the tunnel, and the fuel check before each trip covers it.
- **Waiting (D4)** keeps a program running with nothing to do, which is
  the point: the autostart and the service already expect long runs.
- **A double is the limit (D2):** more chests would mean stores the
  turtle has to walk between. With hauling and overflow, that isn't
  needed.

## Consequences

- An endless tunnel stops only:
  - when the start's chest is full;
  - at bedrock or something it can't dig;
  - with `mine.wait` off, at what the wait would have covered.
- **What the in-game test should show** (UNTESTED.md):
  - the chests joining;
  - hauling and the walk back out;
  - the extra chests coming back;
  - waiting and carrying on after a restock;
  - `--new` over the old tunnel carrying it on.

## Action items

### Phase 0
1. [x] The baseline: `python sim/run.py` twice, byte for byte, saved.
2. [x] The sim learns chest facing and double chests, digging a chest and
   dropping into air (D9's part for the features). Today's checks are
   unchanged.

### Phase 1: the decisions
1. [x] D7: the stop message names the chest.
2. [x] D2: growing home chests (and picking them up), with scenarios:
   - a segment whose bulk and valuables overflow a single chest;
   - a torch niche at z-1;
   - a 1-wide tunnel.
3. [x] D3: bulk overflow thrown on the floor, counted.
4. [x] D1: hauling when full, and `mine.haulEvery`, with scenarios
   (also the start's chest full).
5. [x] D4: waiting for supplies, with a scenario that restocks while it
   waits.
6. [x] D5: `--new` over the same tunnel, and `--resume` of a finished
   tunnel that is now longer.
7. [x] D6: supplies home at the end, and `mine haul --supplies`.
8. [x] D8: the turtlelib items accepted.
9. [x] Help: `help/mine.txt`, the file's header, `help/autostart.txt`
   where it says what stops a tunnel.

### Phase 2: the sim corrections (D9)
1. [x] Each correction its own commit, with its changed checks explained.
   Three bugs found and fixed: turtlelib hit a player in the way (now it
   waits, `T.cfg.waitBeforeHit`), clay balls were valuables (now bulk),
   and `mine reset` after a reboot mid-move stopped a block from home
   (now it looks a block off). The in-game endless going-over passes
   didn't reproduce with the corrected water: still open.

### Phase 3: release (on the user's ok)
1. [ ] Version bump (minor), UNTESTED.md section with its issue, release.
