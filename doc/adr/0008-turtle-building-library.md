# ADR-0008: A building library for turtles: map, paths, placing, blueprints, crafting and storage

**Status:** Proposed (2026-11-12): decisions D1 to D10 below are the user's
to make
**Date:** 2026-11-12
**Deciders:** Dan Theisen

## Context

`claude` (turtle/claude.lua) built a castle in the Nether over most of a
day: walls, towers, a keep, a lava moat and a drawbridge. When it was
done it wrote a report, `/claude/helper_api_report.md`, on what got in
its way and what turtlelib should offer. The user asked (2026-11-12) for
everything in it that can be done in Lua, the big asks included; for
mine, farm and mow to keep working, and to do better where the new pieces
allow; and for claude's system prompt to tell the model what it can call
and what each thing does.

What the report says, in its own order of use:

1. Placing stairs, slabs and doors the right way up and facing the right
   way, then checking them.
2. A world map kept on disk, and block states (facing, half) for blocks
   it can't stand next to.
3. Building from a blueprint, with a progress file and a final check.
4. Crafting, and taking one particular item out of a chest.
5. Protected areas no move may dig through, and route-finding that keeps
   out of them.
6. Log rotation and a job journal.

And, besides those: a 3D `moveTo` that says why it stopped; geo scans in
its own coordinates; a fuel guard on scans; height maps and slices as
text; harvesting by name, nearest first; a junk policy that can't throw
away crafted items; trips to a junk chest; a catalogue of the chests at
home; smelting; equipping a peripheral without touching the chunk
controller; refuelling from lava; real-world coordinates; progress
reports to the player; an undo journal.

What it costs it today:

- **Helpers die with the conversation.** Its moveTo, grabFrom,
  craft2x2, buildCells and the rest lived in the session or in
  `/claude/castle.lua`. Each time old tool results were cleared it
  rewrote them, in calls, and the copies drifted.
- **The log filled the disk.** `claude.log` has no limit; it reached
  ~800 KB on the old 1 MB disk mid-job, and the turtle lost its plan. It's
  975 KB now (the disk is 8 MB since 2026-11-12, but 0.45.0 writes more
  per call).
- **It never heard of what exists.** `T.takeInto` (one item out of a
  chest), `T.refuelFrom`, `T.keep` and the scanner's `r/u/f` fields (the
  scan in the turtle's own frame, which mine.lua uses) aren't in the
  system prompt, so it worked them out again.
- **Tool swaps don't fit its turtle.** `T.withTool` swaps tools (the
  pickaxe) only; it gives up when both sides hold upgrades, which is a
  turtle with a chunk controller and a scanner or chat box.

What's there to build on:

- turtlelib (1565 lines): position and heading, fuel, moves that dig only
  `T.diggable`, the six directions, a learned 2D obstacle map with BFS
  (`T.goTo`, at one height), inventory and chest helpers (dump with a
  keep policy, counts, restock, `takeInto`, compact), settings and
  options, mine's job file.
- mine.lua already has the hard parts of three of the asks, private to
  it: the scanner swap that waits for the peripheral and retries the
  cooldown (`scanBlocks`), scans lined up in the turtle's frame
  (`takeScan`), and crafting through the workbench peripheral, stashing
  into a chest and filling the grid from it (`craftSteps`,
  `craftSupplies`). These become the shared modules, not copies of them.
- mine and mow dig only through turtlelib (no `turtle.dig` of their
  own); farm digs crops directly (13 places). So a protected-area check
  at turtlelib's dig is seen by mine and mow at once, and by farm once
  its digs go through it.
- The sims: mineworld, farmworld, the mock and the sandbox; mine has dozens
  of scenarios whose moves, chest contents and output are compared run to
  run.

What can't be done from Lua:

- **Block states in a scan.** Advanced Peripherals' `scanBlocks` gives
  names (and tags), not states. A state is read only by `inspect` from
  the cell beside the block. So: a batched check that plans one route
  past all the blocks to look at (below), not states from a distance.
- **A peripheral used from the inventory.** CC only attaches an equipped
  upgrade. Equipping one costs two swaps; `T.withPeripheral` makes that
  one call and safe. In the world, a chat box or scanner on a wired modem
  at home works without swaps, but only while the turtle is there.
- **Pushing items into a turtle over a wired network.** Not known to work:
  whether a chest's `pushItems` can name a turtle as the target is to be
  tried in game before anything relies on it. Taking one item from a chest
  beside the turtle (`T.pull`) doesn't need it.

## Options considered

1. **Everything in turtlelib.** One file, nothing new to install. It
   would pass 6000 lines; every program would load the A* search, the
   recipe table and the map to mine a tunnel, on computers with little
   memory, and it nears Cobalt's 200-locals limit.
2. **A small core plus modules loaded when first used** (recommended).
   turtlelib keeps the core and grows only what every program needs
   (3D moves with reasons, protected areas, `withPeripheral`, `pull`);
   the rest are modules beside it, each required lazily through `T` so
   `T.craft(...)` loads the crafting module the first time.
3. **A library for claude alone** (`/claude/helpers.lua`-style, shipped).
   Quick, but mine, farm and mow couldn't use it, and the user wants
   them to.
4. **A planner on another computer** (a base computer computes routes and
   build orders over the network). More memory and speed, but needs the
   network up and a second machine; against "keep it simple".

## Decision (proposed)

**Option 2.** The modules live in `turtle/tl/` (`require("tl.world")`),
next to turtlelib. ccnix's boot already puts `turtle/` on the path, and
Lua's `require` turns the dot into a folder. setup's turtle file list
gets `turtle/tl/` (a whole folder). `T` loads a module the first time one
of its functions is used, so a program that never crafts never loads the
recipes.

Every function returns what happened: `true`, or `false` / `nil` and a
reason a person can read ("blocked by minecraft:obsidian at 3,12,-4",
"protected: the castle", "short of minecraft:stick: need 4, have 1").
Nothing prints unless asked to (the programs print; claude reads results).

### In turtlelib itself (the core)

- `T.moveTo(x, y, z, opts)`: a 3D move with an axis order (`"yxz"`
  default), `dig` (true, false, or a glob of what it may dig), `avoid`
  (lava, fire and doors by default), and on failure the reason, the
  block and where. When a straight run is blocked it asks the path module
  (below) for a route, if one's loaded or `opts.path` is set.
- **Protected areas:** `T.protect(name, x1, y1, z1, x2, y2, z2)`,
  `T.unprotect(name)`, `T.protected(x, y, z)`. Kept in a data file so
  every program sees the same list. turtlelib's dig (`clearWay`,
  `T.digDir` and the rest) refuses a block inside one, as it refuses
  chests and computers today. farm's direct digs move to turtlelib's so it
  sees them too.
- `T.withPeripheral(name, fn)` (and `T.equipPeripheral(name)` returning a
  restore): equips the item on the side that doesn't hold the chunk
  controller (or a side named in `T.cfg.keepSide`), waits until it shows
  up as a peripheral (mine's wait), passes it to `fn` wrapped, and puts
  back what was there even if `fn` errors. It never unequips a chunk
  controller. `T.withTool` stays for tools.
- `T.pull(side, name, n)`: `T.takeInto` for a whole count, into any
  slots. And `T.junk`: a junk chest's place (`T.setJunkChest(x, y, z,
  side)`) and a junk test, where nothing crafted by `T.craft` this job and
  nothing in `T.keep` is junk; `T.dumpJunk()` goes there and back.
- `T.dig*` and `T.place*` report each change to the map and the journals
  (below) through a hook list, so a module can listen without turtlelib
  knowing it.

### `tl.world`: the map and the frames

- **Frames.** The turtle's frame is what it is now. The world frame is an
  origin: the world position and compass facing of the turtle's
  (0,0,0). `T.setOrigin(x, y, z, facing)`; `gps.locate` when there's a GPS
  network; the facing worked out from one scan (scanBlocks gives world
  `x/z` and turtle `r/f` for the same block). Then `T.toWorld(p)` and
  `T.toLocal(p)` convert. Kept in a data file, not in notes.
- **The map:** what scans saw and what the turtle dug, placed and
  inspected, by cell, with when. Kept in a file per 16-block cube of
  space under the data folder, loaded when used, written when changed.
  Queries: `map.get(x, y, z)` -> name, state (if inspected), when;
  `map.top(x, z)`; `map.find(glob, box)`; `map.count(glob, box)`;
  `map.heights(box)` and `map.slice(y, box)` as compact text.
- **Scans:** `T.scan(r)` -> `{ ["x,y,z"] = name }` in the turtle's frame
  (from `r/u/f` and the heading), merged into the map. Radius over 8 is
  refused without `{ force = true }` (the turtle once paid ~5300 fuel for
  r=16); `T.scanBox(box)` tiles r=8 scans to cover a box.
- `T.inspectAt(x, y, z)`: goes to a free neighbour, inspects, records the
  state. `T.inspectAll(list)`: one route past them all, ordered nearest
  first.

### `tl.path`: routes

- A* in 3D over the map: known air is cheap, unknown cells cost more,
  diggable blocks cost a dig, and protected areas, lava, fire, doors and
  anything the caller lists are walls. It yields every few hundred nodes
  (CC stops a program that runs too long without yielding) and gives up
  past a node limit with the reason.
- `T.travel(x, y, z)`: the "safe altitude" move: the lowest clear height
  between here and there from the map's height map, scanned for first if
  the map doesn't know.
- On a block it didn't expect, it marks it and plans again.

### `tl.place`: blocks the right way round

- A table of block families (stairs, slabs, doors, trapdoors, torches and
  wall torches, logs and pillars, buttons, ladders, fence gates): for each,
  which state it takes from the approach (from above, from below, from
  which side) and the heading. The first table comes from the castle
  turtle's findings (`placeDown` over air gives top-half stairs and slabs,
  onto a solid block bottom-half; facing follows the heading; a side
  placement hits at y 0.5, the bottom half) and Minecraft's placement
  rules.
- `T.placeAt(x, y, z, item, { facing, half, axis })`: picks an approach
  the table says gives that state and that the map says is reachable,
  places, inspects, and if the state's wrong, digs it and tries the next
  approach; returns what it got. What worked is remembered per family, so
  a wrong guess in the table is learnt once.
- Doors want the cell above free and a block below, and go in after the
  walls around them. `T.ignite(x, y, z)` with flint and steel from above.

### `tl.blueprint`: build and check

- **The format:** a Lua table or a text file of layers, bottom up, with a
  legend (`B = minecraft:polished_blackstone_bricks`, `s =
  minecraft:polished_blackstone_brick_stairs[facing=north,half=bottom]`,
  `. = air`, space = leave alone), and an anchor in the turtle's frame.
  Also from code: `bp.box`, `bp.walls`, `bp.fill`, `bp.fromMap(box)` (copy
  what's there).
- `T.build(bp, opts)`: checks materials first (counts per item, what's
  short, what can be crafted from what's on hand); builds layer by layer
  from above (`placeDown` from y+1, what worked best); blocks that hang on
  others (stairs, doors, torches) after their supports; and keeps a
  progress file (the blueprint's name and the cells done) so a crash, a
  reboot or a cleared conversation carries on where it was.
- `T.verify(bp)` -> the cells that differ, states included (through
  `T.inspectAll` for the ones whose state matters).
- `T.replace(box, glob, item)`: every block matching in the box swapped,
  each from its nearest reachable side (the castle's ~410 side swaps).
- A finished build can protect itself (`opts.protect = "keep"`).

### `tl.craft`: crafting and smelting

- A recipe table for vanilla's building and tool basics: planks, sticks,
  torches, chests, crafting tables, furnaces, stairs, slabs and walls of
  each stone and wood, bricks, polished and chiseled forms, doors,
  trapdoors, ladders, fences, iron bars, glass panes, buckets. Any
  ingredient may be a list or a tag-like glob (`*_planks`).
  `T.addRecipe(...)` for more (claude can look one up and add it).
- `T.craft(name, n, opts)`: needs a chest to work from (the one in front,
  or `opts.chest`, or the junk/work chest): stashes everything else in
  it, the pickaxe included; pulls the ingredients into the grid; crafts
  through the workbench peripheral; repeats to n; puts the inventory and
  the equipment back as they were. The workbench is equipped through
  `T.withPeripheral`, so it never touches the chunk controller. This is
  mine's `craftSteps` and `craftSupplies`, generalised.
- `T.canCraft(name, n)` -> what's short, from the inventory and the chest.
- Fuel and smelting facts as tables: what burns and for how long (nether
  stems and their planks don't), what smelts into what.
  `T.smelt(item, n, fuel)` runs a furnace beside it: fuel in the side,
  items in the top, results out of the bottom, waiting as it cooks.

### `tl.store`: chests at home

- `T.catalogue()`: walks the chests it's told about (or finds them next
  to a route) and records what's where, in a file; `T.where(name)`.
- `T.fetch(name, n)`: goes to the chest that has it, pulls it, comes back.
- `T.stow()`: puts what it carries into the chests that already hold that
  item, the rest into the bulk chest.
- When the inventory nearly fills during a job, `T.cfg.autoDump` sends it
  to stow and come back.

### `tl.harvest` and fuel

- `T.harvest(glob, where, target)`: nearest first, top down (no digging
  out from under falling blocks), lava checked, protected areas kept,
  counting as it goes, stopping at the target. `where` is a box (scanned
  as needed) or a scan result. The castle turtle's `gather` loop, made
  general.
- `T.refuelFromLava(target)`: the nearest lava source the map knows, the
  buckets filled, burned, and back. mine's `scoop` is the same idea at
  arm's length.
- `T.fuelFor(plan)`: what a route or build will cost, scans included,
  against what's in the tank and on board.

### `tl.journal`: jobs, undo and reports

- **The job journal** (`T.job`): the goal, the plan's steps, which are
  done, free notes, in one file. `T.job.start(goal, steps)`,
  `T.job.done(step)`, `T.job.resume()`. Blueprints and harvests write
  theirs through it, so a reset or crash resumes at the step.
- **The undo journal**, opt-in (`T.cfg.undo = true`): each block dug or
  placed, with its state (an inspect before each dig), so
  `T.undo(n)` or `T.undo(since)` puts back what it can (with the items on
  hand).
- **Reports:** `T.report(text)` tells the player through the chat box
  (equipped through `withPeripheral`, retried), adding where it is, its
  fuel, and the job's progress; `T.report.every(n)` once every n steps.
  The player to tell is a setting (`turtle.player`), never in the code.

### mine, farm and mow

The rule: each keeps passing its sims with the same results (moves, chest
contents, what it prints) after moving onto the shared pieces, before it
gets anything new. Then, where the new pieces make it better:

- **mine:**
  - Its scanner swap becomes `T.withPeripheral`, which keeps a chunk
    controller on.
  - Its scans go into the map, so `--resume` and later runs know what's
    already been seen.
  - Its crafting becomes `T.craft` (it can then craft more than chests
    and torches).
  - It protects its homes and the start's chests while it runs.
- **farm:** its digs go through turtlelib, so protected areas hold. Its
  learnt obstacles (2D, kept per run today) can be kept in the map
  between runs.
- **mow:** routes over the map's height map across rough ground, not
  only by stepping. A protected area keeps it out of a garden.
- **All three:** `T.report` for a job's end and its trouble (an
  opt-in setting), and the job journal where it's simpler than their
  own files. Their own files stay where they already work.

### claude

- **The log:** rotated at 256 KB (a setting), one old copy kept
  (`claude.log.1`).
- **Its helpers kept:** `/claude/helpers.lua` is loaded into the code's
  world at the start of each session if it's there, and the prompt tells
  it to keep reusable helpers there, not only in the conversation.
- **The system prompt:** turtlelib and each module get a reference
  written in their header comments, like the programs' manuals.
  `sim/mkhelp.py` makes two things from it:
  - `help/turtlelib.txt`: the whole reference, which the model can read
    with fs when it needs the details.
  - `turtle/tl/index.txt`: one line per function (name, arguments, what
    it does and returns).

  claude puts the index in the system prompt at start. It's cached with
  the rest of the prompt, so it costs a write once, then cache reads. And
  it's made from the code, so it can't drift: `--check` fails if a public
  function is missing from it. The prompt's prose shrinks to how to work
  (frames, safety, cost), with the "what can I call" part from the index.
- `status` adds the origin, protected areas near by, and the job journal's
  step.

## Decisions for the user

- **D1. Layout:** modules in `turtle/tl/`, loaded on first use through `T`
  (recommended); or all in turtlelib.
- **D2. The map's disk budget:** files per 16-block cube, capped at 512 KB
  by default (a setting), the longest-unseen cubes dropped first
  (recommended; a stock CC disk is 1 MB); or no cap.
- **D3. Scan radius:** over 8 refused unless forced (recommended); or
  allowed with a printed cost.
- **D4. Recipes:** the built-in vanilla table plus `T.addRecipe`
  (recommended); modded recipes only through `T.addRecipe`.
- **D5. Junk:** nothing is dropped on the ground or in lava by the
  library; junk goes to a junk chest, or stays (recommended). The
  programs' own dumping (mine's bulk chest) is unchanged.
- **D6. The undo journal:** opt-in (recommended: it costs an inspect per
  dig); or on for claude by default.
- **D7. mine, farm, mow:** first the refactor with identical sim results,
  then the improvements listed above (recommended); or the refactor only;
  or leave them alone and only claude uses the new pieces.
- **D8. The prompt:** the generated index in the system prompt and the
  full reference on disk (recommended); or the full reference in the
  prompt (about 3 to 4 times the tokens, cached).
- **D9. The log:** 256 KB and one old copy (recommended), or another size.
- **D10. The origin:** asked for once (claude asks the player; the
  programs take `--origin x,y,z,facing`), `gps.locate` when there's GPS,
  the facing from a scan (recommended).

## Consequences

- claude gets a maintained library with fixed names; what it learnt the
  hard way (placement states, crafting's empty slots, scanner frames) is
  in code and tables rather than its notes.
- turtlelib's core grows a little; the bulk is in modules the mining and
  farming turtles load only if they use them.
- Protected areas bind every program on that turtle, including the user
  running mine by hand next to the castle. `T.unprotect` or a setting lifts
  them.
- The data folder holds more: the map, the journals, the catalogue, the
  learnt placements. A cap and a `T.forget(...)` keep it bounded.
- More to test: a new mock world with block states, placement rules,
  furnaces and a crafting grid; the A* search's speed on a real turtle
  (CC's Lua is slow) is only measurable in game.
- The in-game list in UNTESTED.md gets long; the tests go in the order of
  the phases.

## Action items

### Phase 1: what costs claude most today

1. [ ] claude: log rotation; `/claude/helpers.lua` loaded each session;
   the prompt names `T.takeInto`, `T.refuelFrom`, `T.keep` and the scan's
   `r/u/f` until the index replaces it.
2. [ ] turtlelib: `T.withPeripheral`, `T.pull`, `T.moveTo` with reasons,
   protected areas in the dig path, the change hooks.
3. [ ] The header-comment reference, `mkhelp` making `help/turtlelib.txt`
   and `turtle/tl/index.txt`, the index in claude's prompt, `--check` for
   drift.
4. [ ] Sims: protected areas refuse a dig in mineworld; `withPeripheral`
   keeps a controller on; `moveTo`'s reasons; the log rotates.

### Phase 2: seeing and moving

5. [ ] `tl.world`: frames and origin, the map files and cap, `T.scan`,
   `T.scanBox`, `T.inspectAt`, `T.inspectAll`, heights and slices.
6. [ ] `tl.path`: A*, `T.travel`, re-planning, yielding.
7. [ ] Sims: a scan in each heading lands in the right cells; A* around a
   protected box and lava; the cap drops the oldest cube.

### Phase 3: building

8. [ ] `tl.place` with its table and the learnt approaches; `T.ignite`.
9. [ ] `tl.blueprint`: the format, `T.build` with materials and progress,
   `T.verify`, `T.replace`.
10. [ ] A mock world with block states (buildworld) and the placement
    rules as the game has them; sims for stairs and slabs each way, a door,
    a build resumed after a stop, verify finding a wrong stair.

### Phase 4: materials

11. [ ] `tl.craft`: recipes, `T.craft`, `T.canCraft`, fuel and smelting
    tables, `T.smelt`.
12. [ ] `tl.store`: catalogue, fetch, stow, auto-dump; `T.junk`.
13. [ ] `tl.harvest`, `T.refuelFromLava`, `T.fuelFor`.
14. [ ] `tl.journal`: job, undo, `T.report`.
15. [ ] Sims for each (a mock furnace and grid; mine's crafting scenario
    moved onto `T.craft` with the same result).

### Phase 5: the programs

16. [ ] mine, farm, mow onto the shared pieces, sims identical.
17. [ ] Their improvements, as D7 decides, each with a sim.
18. [ ] UNTESTED.md entries, help regenerated, versions bumped (ccnix's
    minor per phase), ccnix-mod's ROM bumped with each.

### In game, in order

19. [ ] Phase 1 with claude on the castle turtle: a helper kept over a
    cleared conversation, the log rotating, a protected area refusing a
    dig.
20. [ ] A scan in the turtle's frame and a route around the moat.
21. [ ] Stairs and slabs both ways; a small blueprint built, stopped,
    resumed, verified.
22. [ ] A craft (stairs from blocks) with the controller kept on; a
    smelt; a fetch from the chest wall.
23. [ ] mine, farm and mow runs after phase 5, as before.
