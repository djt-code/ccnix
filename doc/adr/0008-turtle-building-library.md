# ADR-0008: A building library for turtles: map, paths, placing, blueprints, crafting and storage

**Status:** Accepted (2026-11-12): the user took every recommendation,
D1 to D11
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
- No program moves or turns the turtle except through turtlelib (checked:
  none calls turtle.forward/back/up/down/turnLeft/turnRight). Digging and
  placing is mixed: mine places once and digs only through turtlelib,
  farm digs crops and places at 19 places, mow places once, and claude's
  model calls turtle.dig() and turtle.place() straight, as its prompt
  tells it to (the sandbox hands it the real `turtle` table). So a check
  put in T.digDir alone would miss most digs; one put on the turtle API
  itself, once, catches them all (below).
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
- **Pushing items into a turtle over a wired network.** A turtle is a
  peripheral (`turtle_N`) only to a full-block wired modem touching it;
  a chest's `pushItems` can name it then and only then, and a turtle
  can't carry a wired modem. So the chest wall at home could push into a
  parked turtle; nothing else can. `T.pull` (the chest's `pushItems` to
  itself, putting the wanted stack first, then `suck`: what `T.takeInto`
  and mine's restock do today, and the castle turtle's `fetch`) is the
  general case and needs no network.

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

## Decision

**Option 2.** The modules live in `turtle/tl/` (`require("tl.world")`),
next to turtlelib. ccnix's boot already puts `turtle/` on the path, and
Lua's `require` turns the dot into a folder. setup's turtle file list
gets `turtle/tl/` (a whole folder). `T` loads a module the first time one
of its functions is used (a metatable on T: a name T lacks is looked up
in a list of which module defines it, that module is required and fills
T in; a module's own `require("turtlelib")` gets the same T, loaded
already), so a program that never crafts never loads the recipes.

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
- **The turtle API wrapped, once.** When turtlelib loads it replaces
  `turtle.dig/digUp/digDown`, `turtle.place/placeUp/placeDown` and the
  six moves and turns with versions that know the cell they act on (from
  T.pos and T.dir), keeping the originals for its own use. A dig into a
  protected area, a chest or a computer returns false and why; a move
  that succeeds updates T.pos and saves it; every dig and placement is
  told to the map and the journals. So the rule "never call
  turtle.forward yourself: T.pos would be wrong" goes away, farm's crop
  digs and claude's `turtle.dig()` are covered without a line changed in
  them, and the sims' mock `turtle` is wrapped the same way. T.forward
  and the rest keep their extras (fuel, diggable, attacking) on top of
  the raw calls. (Checked: no program calls the moves or turns directly,
  so nothing double-counts.)
- **Protected areas:** `T.protect(name, x1, y1, z1, x2, y2, z2)`,
  `T.unprotect(name)`, `T.protected(x, y, z)`. Kept in a data file so
  every program on the turtle sees the same list. A job may work inside
  an area it owns: `T.build`, `T.replace`, `T.harvest` and `T.moveTo`
  take `inside = name`. Protection is only as right as T.pos; the
  wrapped moves are what keep that right.
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

### `tl.world`: the map and the frames

- **Frames.** The turtle's frame is what it is now, and it isn't fixed:
  `--here`, `T.setHomeHere`, `T.clearPos` and a run with no saved
  position all make the spot the turtle stands on (0,0,0) again. So the
  map keeps a frame of its own, the one it was started in, with the
  transform (shift and quarter turns) from the turtle's current frame;
  whenever a program re-zeroes, turtlelib knows the old position and
  heading of that very spot and updates the transform. A frame lost
  without that (the position file deleted) leaves the map kept but
  marked unaligned, until `T.alignMap(dx, dy, dz, turns)` or a fresh
  start. The world frame is one more transform: `T.setOrigin(x, y, z,
  facing)` from the player, `gps.locate` when there's a GPS network, and
  the facing worked out from one scan (scanBlocks gives world `x/z` and
  turtle `r/f` for the same block). `T.toWorld(p)` and `T.toLocal(p)`
  convert. All of it in a data file, not in notes.
- **The map:** what scans saw and what the turtle dug, placed and
  inspected, by cell. Kept in a file per 16-block cube of space under
  the data folder: a palette of the names the cube holds and one byte a
  cell (4 KB a cube, written in binary mode), the cube's "seen when" per
  scan rather than per cell, and inspected states as a short list beside
  (a state per cell would cost more than the cube). Names per cell as
  text would be thirty times the size, and CC charges a file at least
  500 bytes (`MountConstants.MINIMUM_FILE_SIZE`) and a folder the same,
  so many small files are the wrong shape too. Cubes are loaded when
  used and written when changed. Queries: `map.get(x, y, z)` -> name,
  state (if inspected), when;
  `map.top(x, z)`; `map.find(glob, box)`; `map.count(glob, box)`;
  `map.heights(box)` and `map.slice(y, box)` as compact text.
- **Scans:** `T.scan(r)` -> `{ ["x,y,z"] = name }` in the turtle's frame
  (from `r/u/f` and the heading), merged into the map. Radius over 8 is
  refused without `{ force = true }` (the turtle once paid ~5300 fuel for
  r=16); `T.scanBox(box)` tiles r=8 scans to cover a box.
- `T.inspectAt(x, y, z)`: goes to a free neighbour, inspects, records the
  state. `T.inspectAll(list)`: one route past them all, each the nearest
  next (greedy, not the shortest tour: good enough, and cheap to find).

### `tl.path`: routes

- A* in 3D over the map with a binary heap: known air costs a move, a
  diggable block a move and a dig, an unknown cell a move and a dig when
  digging is allowed and a move with a penalty when it isn't (so a route
  through the unseen is possible, and checked as it's walked); protected
  areas, lava, fire, doors and anything the caller lists are walls. It
  yields on a clock (CC aborts code that runs about seven seconds
  without yielding; every half second is plenty) and gives up past a
  node limit with the reason. Cubes are read as strings (`string.byte`),
  not expanded into tables, so a big search stays cheap in memory.
- `T.travel(x, y, z)`: the "safe altitude" move: from the map, a clear
  layer over the route's box, between the floor's highest and the
  ceiling's lowest (the Nether has a roof: a fixed height hit bastion
  ceilings), scanned for first if the map doesn't know; A* when there's
  none.
- On a block it didn't expect, it marks it and plans again.

### `tl.place`: blocks the right way round

- What a turtle's place does, from CC:Tweaked's `TurtlePlaceCommand`
  (1.120.2, read for this): it tries, in order, an entity in the target
  cell (so never place where a minecart or item frame is), the block
  beyond the target (clicked on its near face), for a sideways place the
  block under the target (clicked on top), and last the turtle's own
  block (clicked on the face toward the target); a sideways click lands
  at the face's middle, nudged to y 0.45. With Minecraft's rules for the
  blocks (a stair or slab clicked on a top face is bottom-half, on an
  underside top-half, on a side by whether the click is above the
  middle; facing is the placer's, which is the turtle's heading; a log's
  axis is the clicked face's; a torch or ladder on a side face hangs on
  that block), that gives a table of block families (stairs, slabs,
  doors, trapdoors, torches, logs and pillars, buttons and levers,
  ladders, fence gates) and what each approach yields:
  - sideways: always bottom-half, facing the turtle's heading; a log
    lies along the heading if there's a block beyond, else stands; a
    torch or ladder needs the block beyond.
  - placeDown: bottom-half if there's a block below the target, else
    top-half (the castle turtle's finding, now explained).
  - placeUp: top-half if there's a block above the target, else
    bottom-half.

  The table is data, and the sims' build world models `deploy`'s order,
  so a wrong row shows up there before it does in game.
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
  progress file so a crash, a reboot or a cleared conversation carries on
  where it was. The build order is fixed by the blueprint, so the
  progress is the index of the last cell done and the list of the ones
  that failed, not a set of cells; the blueprint itself is kept as its
  layer strings, not a table per cell (a 40 by 30 by 40 build is 48,000
  cells).
- `T.verify(bp)` -> the cells that differ, states included (through
  `T.inspectAll` for the ones whose state matters).
- `T.replace(box, glob, item)`: every block matching in the box swapped,
  each from its nearest reachable side (the castle's ~410 side swaps);
  the ones with no free side (inside a wall) are reported, not dug out to.
- A finished build can protect itself (`opts.protect = "keep"`).

### `tl.craft`: crafting and smelting

- A recipe table for vanilla's building and tool basics: planks, sticks,
  torches, chests, crafting tables, furnaces, stairs, slabs and walls of
  each stone and wood, bricks, polished and chiseled forms, doors,
  trapdoors, ladders, fences, iron bars, glass panes, buckets. Recipes
  are shaped, written as the game's data packs write them: up to three
  rows of letters and a legend, a letter standing for a name, a list of
  names or a glob (`*_planks`), and how many come out. Families (every
  stone's stairs from its block) are one entry with the name as a
  pattern, not a row each. `T.addRecipe(...)` for more (claude can look
  one up and add it).
- `T.craft(name, n, opts)`: needs a chest to work from (the one in front,
  or `opts.chest`, or the junk/work chest) with room for the whole
  inventory, up to sixteen stacks (checked first, as mine does): stashes
  everything else in it, the pickaxe included, since a turtle crafts only
  with every slot outside the grid empty; pulls the ingredients into the
  grid's slots (1-3, 5-7, 9-11); crafts through the workbench peripheral,
  the output into the slots from the selected one; repeats to n; puts
  the inventory and the equipment back as they were. The workbench is
  equipped through `T.withPeripheral`, so it never touches the chunk
  controller. This is mine's `craftSteps` and `craftSupplies`,
  generalised; mine's crafting scenario is the first test of it.
- `T.canCraft(name, n)` -> what's short, from the inventory and the chest.
- Fuel and smelting facts as tables: what burns and for how long (nether
  stems and their planks don't), what smelts into what.
  `T.smelt(item, n, fuel)` runs a furnace: a furnace takes fuel through
  its sides, items through its top, and gives results through its
  underside only, so the turtle drops in from beside and above and sucks
  from below, which needs the furnace to stand with a free cell above
  and below it (`T.smelt` places it so, on a pillar if need be, and
  takes it back after); it waits as it cooks (ten seconds an item).

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
- **farm:** nothing to move: the wrapped API makes protected areas hold
  for its crop digs as they are. Its learnt obstacles (2D, kept per run
  today) can be kept in the map between runs.
- **mow:** routes over the map's height map across rough ground, not
  only by stepping. A protected area keeps it out of a garden.
- **All three:** `T.report` for a job's end and its trouble (an
  opt-in setting), and the job journal where it's simpler than their
  own files. Their own files stay where they already work.

### claude

- **The log:** rotated at 256 KB (a setting), one old copy kept
  (`claude.log.1`).
- **Its helpers kept:** `/claude/helpers.lua` is loaded into the code's
  world at the start of each session if it's there (under pcall: a broken
  file is reported to the model as the first thing it sees, not a dead
  session), and the prompt tells it to keep reusable helpers there, not
  only in the conversation. The modules aren't `require`d by its code
  (the sandbox's require is a fixed list); they come through `T`.
- **The system prompt:** turtlelib and each module get a reference
  written in their header comments, like the programs' manuals.
  `sim/mkhelp.py` makes two things from it:
  - `help/turtlelib.txt`: the whole reference, which the model can read
    with fs when it needs the details.
  - `turtle/tl/index.txt`: one line per function (name, arguments, what
    it does and returns).

  claude puts the index in the system prompt at start (found as the
  manuals are, with `ccnix.find`). It's cached with the rest of the
  prompt, so it costs a write once, then cache reads. And it's made from
  the code, so it can't drift: `--check` fails if a public function has
  no comment above it or the index is stale. mkhelp today makes manuals
  from a program's top comment and leaves turtlelib out; it gets a
  library mode (the top comment as the overview, then each `function
  T.name(...)` with the comment above it), and both it and `--check`
  learn to look in `turtle/tl/` (they glob `bin`, `turtle` and `pc`
  only). The prompt's prose shrinks to how to work (frames, safety,
  cost), with the "what can I call" part from the index.
- `status` adds the origin, protected areas near by, and the job journal's
  step.

## Decisions (taken 2026-11-12: each as recommended)

- **D1. Layout:** modules in `turtle/tl/`, loaded on first use through `T`
  (recommended); or all in turtlelib.
- **D2. The map's disk budget:** a file per 16-block cube (4 KB each, so
  about 100 cubes, a 160 by 80 by 160 space, in 512 KB), capped at the
  smaller of 512 KB and a quarter of the disk (a setting), the
  longest-unseen cubes dropped first (recommended; a stock CC disk is
  1 MB, and claude's log takes up to 512 KB of it); or no cap.
- **D3. Scan radius:** over 8 refused unless forced (recommended); or
  allowed with a printed cost.
- **D4. Recipes:** the built-in vanilla table plus `T.addRecipe`
  (recommended); modded recipes only through `T.addRecipe`.
- **D5. Junk:** nothing is dropped on the ground or in lava by the
  library; junk goes to a junk chest, or stays (recommended). The
  programs' own dumping (mine's bulk chest) is unchanged.
- **D6. The undo journal:** opt-in (recommended: the state has to be read
  before each dig, free on moves, which look first, an inspect on the
  others; and it grows with every block); or on for claude by default.
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
- **D11. Wrapping the turtle API:** the moves and turns too, so T.pos
  stays right whatever the code calls (recommended; nothing calls them
  directly today, so nothing changes for the programs); or only the
  digs and placements, keeping the "move through T" rule for claude.

## Consequences

- claude gets a maintained library with fixed names; what it learnt the
  hard way (placement states, crafting's empty slots, scanner frames) is
  in code and tables rather than its notes.
- turtlelib's core grows a little; the bulk is in modules the mining and
  farming turtles load only if they use them.
- The turtle API on a turtle that has loaded turtlelib is turtlelib's: a
  dig comes back false with a reason where the game would have dug.
  Every program on the turtle gets that, and the sims prove the three
  programs behave the same before anything else lands.
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

1. [x] claude: log rotation; `/claude/helpers.lua` loaded each session;
   the prompt names `T.takeInto`, `T.refuelFrom`, `T.keep` and the scan's
   `r/u/f` until the index replaces it.
2. [x] turtlelib: the turtle API wrapped (digs, placements, moves and
   turns as D11 says), protected areas, `T.withPeripheral`, `T.pull`,
   `T.moveTo` with reasons.
3. [x] The header-comment reference, `mkhelp` making `help/turtlelib.txt`
   and `turtle/tl/index.txt`, the index in claude's prompt, `--check` for
   drift.
4. [x] Sims: every existing scenario unchanged with the API wrapped (the
   first check, before anything else is added); a protected area
   refusing `turtle.dig()` called straight and `T.digDir` alike;
   `withPeripheral` keeping a controller on; `moveTo`'s reasons; the log
   rotating; `--check` and mkhelp over `turtle/tl/`.

### Phase 2: seeing and moving

5. [x] `tl.world`: frames and origin, the map files and cap, `T.scan`,
   `T.scanBox`, `T.inspectAt`, `T.inspectAll`, heights and slices.
6. [x] `tl.path`: A*, `T.travel`, re-planning, yielding.
7. [x] Sims: a scan in each heading lands in the right cells; the map
   survives a `--here` (the transform updated) and says so when it
   can't; a cube written and read back byte for byte; A* around a
   protected box and lava, and through unseen cells with a re-plan on a
   bump; the cap drops the oldest cube.

### Phase 3: building

8. [x] `tl.place` with its table and the learnt approaches; `T.ignite`.
9. [x] `tl.blueprint`: the format, `T.build` with materials and progress,
   `T.verify`, `T.replace`.
10. [x] A mock world with block states (buildworld) whose `place` follows
    `TurtlePlaceCommand`'s order and the blocks' rules; sims for stairs
    and slabs each way (sideways always bottom, placeDown by the block
    below, placeUp by the block above), a log's axis, a door, a build
    resumed after a stop, verify finding a wrong stair.

### Phase 4: materials

11. [x] `tl.craft`: recipes, `T.craft`, `T.canCraft`, fuel and smelting
    tables, `T.smelt`.
12. [x] `tl.store`: catalogue, fetch, stow, auto-dump; `T.junk`.
13. [x] `tl.harvest`, `T.refuelFromLava`, `T.fuelFor`.
14. [x] `tl.journal`: job, undo, `T.report`.
15. [x] Sims for each (a mock furnace and grid). Mine's crafting scenario
    was not moved onto `T.craft`: mine's chain (one chest, the table and
    pickaxe left in it, bulk sent to the bulk chest) cannot give the same
    result there, so mine keeps its own crafting.

### Phase 5: the programs

16. [x] mine, farm, mow onto the shared pieces, sims identical (mine's
    scanner swap is `T.withPeripheral`; its crafting stays its own, see 15).
17. [x] Their improvements, as D7 decides, each with a sim.
18. [ ] UNTESTED.md entries, help regenerated, versions bumped (ccnix's
    minor per phase), ccnix-mod's ROM bumped with each. (ccnix's side is
    done, 0.50.0; the ROM bump in ccnix-mod is left.)

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
