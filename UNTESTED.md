# Untested in game

What's built and passes the sims but hasn't been tried in a real game yet.
A scenario goes in when the change ships, and moves to **Tested** (with the
date and what happened) once someone has run it. Newest first in each
section.

## A turtle with no map yet (ccnix 0.50.2)

- **claude starts on a turtle with no `.map`**: the first `status` no longer stops claude with
  `tl/world.lua:567: .../.map: No such file` (0.50.1 listed the map's folder before checking it was there).
  `status` works, and no `.map` folder appears. Also: any fault inside `status` now goes back to the model as
  a tool error ("status failed: ...") instead of ending the session.

## ADR-0008 after review: frames, owners, building fixes (ccnix 0.50.1)

In-game order for all of ADR-0008 (the ADR's own list): 1. phase 1 with claude on the castle turtle (a helper
kept over a cleared conversation, the log rotating, a protected area refusing a dig); 2. a scan in the turtle's
frame and a route round the moat; 3. stairs and slabs both ways, a small blueprint built, stopped, resumed and
verified; 4. a craft (stairs from blocks) with the controller kept on, a smelt, a fetch from the chest wall;
5. mine, farm and mow runs, as before. The fixes below ride along with those.

- **`--here` moves what is kept in the turtle's frame**: protect a box (`T.protect`), set a junk chest and add a
  chest (`T.addChest`), walk away ten blocks and turn, run `mine --here`: `T.protections()`, `T.junkChest()` and
  `T.chests()` should name the same blocks in the new frame (a dig into the real box refused, the new home's
  tunnel not). An unfinished `T.build` and the undo journal are not moved: finish or restart them first.
- **`reset --here` and a heading correction leave the frames alone**: carry the turtle home by hand and run
  `farm reset --here` (or `mine reset --here`): the map, areas and chests stay where they were (no shift by the
  stale saved position). Lose a turn (Ctrl+T outside T.run) and let farm or mine correct the heading: the map
  is not turned.
- **An ended program's moves**: after `mine` ends, `go forward 2` (or excavate): no `/programs/turtle` folder
  appears, and `ccnix/turtle/.turtlepos` follows the moves (mine's copy of turtlelib keeps tracking them).
- **autoDump and undo belong to claude's code**: with `T.cfg.autoDump = true` and `T.cfg.undo = true` in
  claude, `run_program mine`: no stow trip during mine's digs, mine's digs not in `.undo`; after it, claude's
  own digs are journalled again and a full inventory makes the trip.
- **No map from asking**: on a turtle with no `.map`, claude's `status` makes none, and mine/farm don't start
  loading tl.world afterwards.
- **Farm digs and bone meal in the map**: with a map kept, a hoe's till leaves farmland in the map (not air),
  seeds leave wheat, bone meal leaves the crop. Costs one more inspect after each placement and after digging
  dirt or grass, only while something listens (a map, undo, autoDump).
- **Ctrl+T during a scan** (`T.scan(16, { force = true })` in claude): stops it; no second scan is made.
- **mow under a tree / with a protected base**: a tile under leaves the map knows is still mowed; with a
  protected area over home, mow crosses it to get out and back, leaving its tiles alone.
- **Slabs and wall torches**: a slab placed over a half slab of its kind (`T.placeAt`) writes nothing to
  `.placements`; `T.forgetPlacements()` empties it. A plan with `torch[facing=south]` builds a wall torch and
  `T.verify` is clean; `T.blueprint.fromMap` over it writes `torch[...]`; a double slab in a plan is built as a
  bottom slab plus a second placed down on it (two slabs counted). `T.build(plan, { name = "hut" })` given again
  carries on.
- **Crafting**: oak planks from stripped logs and oak wood; 20 boats crafted in rounds of at most ten, none
  dropped; `T.smelt` with the cobblestone split 5 + 15 over two slots. A sparse `setup mine` install has
  `lib/mc.lua`, so `sysctl mine.report=true` can tell the player.
- **Placement facts in the mock** (to compare with the game): a torch from placeDown over leaves, with blocks
  ahead of and right of the target, hangs on the one ahead; a ladder is not placed against a ladder's front.

## farm and mow on the shared pieces (ADR-0008 phase 5, ccnix 0.50.0)

- **Protected areas hold for farm's crop digs**: `T.protect("garden", x1, y, z1, x2, y, z2)` over a few ripe crop
  tiles (in a Lua prompt or claude's code, in the turtle's frame; the crops are one below the cruise height), then
  `farm`: the crops in the box are left standing, the pass says "N tiles left alone: they are in a protected
  area" and counts them neither harvested nor damaged, and no repair pass starts. `T.unprotect("garden")` and the
  next pass takes them. The same for a protected sugar cane strip (the cut of the second block is refused). Check
  a real hoe on a crop in a protected cell comes back `false, "protected: garden"` through the wrapped digDown.
- **farm keeps the obstacles in the map** (`sysctl farm.map=false` turns it off): put a block (a post) at the cruise
  height somewhere on the route, in a column that is not a crop tile, e.g. right in front of home, and run `farm`:
  it bumps into it once, and `T.map.get(x, 0, z)` (in a Lua prompt, in the turtle's frame) names it. Run `farm`
  again (a new run, or the next pass): it goes round without the bump. Take the post away and run again: if it
  leaves no other way, farm forgets the remembered obstacles for that trip and goes through, and the map
  says air there afterwards. A clean farm should leave no `.map` folder behind. Check the map's frame stays right
  across `farm reset --here`, and that the extra look at the block in front (an inspect after a failed step) costs
  nothing visible.
- **mow's heights and gardens** (`sysctl mow.map=false` turns the heights off): on rough ground, `mow` writes the
  ground under each tile into the map; a second pass (`mow 16 16 1`) or the next run does not run into the
  same pillar again, and a step the turtle cannot make (ground more than 3 up or down from the next column) is
  not planned. Check `T.map.heights()` shows the lawn afterwards, and that the extra inspect and map write
  per tile does not slow a big lawn much (a 16 x 16 lawn writes 256 cells, some cubes). A protected area over a
  garden (flowers, a crop plot) is kept out of: "Keeping out of N tiles in a protected area (name)", the grass in
  it stands, the route goes round. Unknown ground is taken level with where the turtle stands; a column that
  something solid blocked stays out for the rest of the run (restart `mow` to try it again).
- **farm.report and mow.report** (off by default): `sysctl farm.report=true`, `sysctl mow.report=true`,
  `sysctl turtle.player=<your name>`, a chat box in the chest below home (or on board, or on a side). A single
  `farm 5 6 0` / `mow 5 4` pass ends with one chat message with the turtle's place and fuel; `farm repair` says
  "done"; a repeating run says nothing for a clean pass and tells the player after one with damaged or unreachable
  tiles, out of seeds or (mow) tiles given up; an error that stops farm is told, and the error goes on. The chat
  box comes out of the chest for the telling and goes back; check the hoe or pickaxe is back on its side
  afterwards, the chunk controller never came off, and with no chat box the run ends as ever after a line
  "Couldn't tell the player".
- **T.report(text, { from = "bottom" })** and **T.report.try(text)**: the chat box taken from the container
  on that side for the telling, and a version that never raises; both used by the two reports above.

## mine on the shared pieces (ADR-0008 phase 5)

- **The Geo Scanner through T.withPeripheral**: `mine` with a scanner in the start's top chest and a chunk
  controller on one side: the scanner goes on the side without the controller (an empty side first, then the
  pickaxe's), the scan is made, and the pickaxe is back on afterwards. Before, the scanner always took the
  pickaxe's place; with an empty side the pickaxe now stays on. Check the controller never comes off, and a
  scan that comes back "cooling down" is asked again.
- **`mine --origin x,y,z,facing`**: stand the turtle on a block, read its cell off F3 (the block it stands in), and
  `mine 3 3 10 --origin <x>,<y>,<z>,<north|east|south|west>` (the way the tunnel runs). Then `T.origin()` and
  `T.toWorld(0, 0, 5)` (in claude's code) should give the F3 cell five blocks along the tunnel. Without the facing
  and with a scanner on board the facing is worked out from a scan: check it names the way you know it faces.
- **mine tells the player**: `sysctl mine.report=true`, `sysctl turtle.player=<your name>`, a chat box in the
  start's top chest (or on board, or on a side), then a short `mine` run: at the end you get one chat message
  "mine Done: ..." with the turtle's place and fuel; stopped by bedrock or no fuel it says why. mine takes the
  chat box out of the top chest for the telling and puts it back. Check the pickaxe is back on afterwards, the
  chunk controller never came off, and with no chat box you get "Couldn't tell the player" and the run ends as
  ever.
- **Home chests protected**: run `mine` with homes; in claude's code (or a Lua prompt) `T.protections()` lists
  "mine home 0 chest", "mine home 0 bulk" and one pair for each home built, and `turtle.dig()` facing a home's
  chest comes back `false, "protected: mine home 1 chest"` (or "won't dig" for the chest itself). When mine ends,
  or stops with Ctrl+T, the list is empty again (`mine --resume` puts them back). If a run is killed some other way
  they stay until the next `mine` run starts and ends; `T.unprotect(name)` lifts one by hand.
  `sysctl mine.protect=false` switches it off. Check mine behaves as before otherwise (no dig of its own is refused).
- **Scans in the map**: after a `mine` run with a scanner, `T.map.get(x, y, z)` (in claude's code, or a Lua
  prompt with `require("turtlelib")`) names the wall blocks the scans looked at and says air in the tunnel;
  `T.map.stats()` shows the cubes. A scan costs the merge's time (4913 cells at radius 8; the loop yields every
  0.4 s): time one on a real turtle, and `sysctl mine.map=false` if it is too slow. Check a second tunnel from the
  same start adds to the map, and that `mine --here` somewhere else does not leave the map wrong (it takes
  the new spot for the old one: `T.map.clear()` before a start somewhere new).

## tl.journal: T.job, T.undo and T.report (ADR-0008 phase 4, ccnix 0.49.0)

- **T.job.start(goal, steps)** then **T.job.done()** as each step finishes; reboot the computer (or Ctrl+T and
  start again) and **T.job.resume()** gives the step to do now (`job.next`, `job.step`). The job is the data file
  `.job`. Check that a `T.build` and a `T.harvest` run with a job on show their progress in `T.job.status()`
  (`build: keep: 40 of 300 cells tried`) and that without a job no `.job` file appears. claude's `status`
  shows the world origin and the job line.
- **T.cfg.undo = true**, then dig and place a few blocks (by hand-written code or claude), then `T.undo(3)`:
  the placed blocks are dug out and the dug one is placed again with the item aboard (stairs through `T.placeAt`,
  facing and half as they were). Check on a real block with a state (a stair, a log), that `T.undoMark()` and
  `T.undo(nil, { since = mark })` undo a stretch of work, and the file `.undo` (cut at 2000 entries, the setting
  `undo.max`). The dig has always looked at the block first, so the state costs nothing extra.
- **T.report("text")** with `sysctl turtle.player=<your name>` and a chat box in the inventory (not on a side):
  the turtle equips it on the side without the chunk controller, speaks, and puts the pickaxe back. Check the
  message: where it is (the world cell when the origin is set), fuel, the job's line. Check what the chat
  box does when it is busy (the retry waits a second, five times), and with the chat box already attached.
  **T.report.every(2)** with a job: a message on every second `T.job.done()`.

## tl.harvest: T.harvest, T.refuelFromLava, T.fuelFor (ADR-0008 phase 4)

- **T.harvest(glob, box, target)** digs the blocks matching in a box (scanned as
  needed), nearest first and top down. Check it on a tree and an ore vein: that it
  leaves a block with sand or gravel over it, one that lava touches, one in a
  protected area and chests, and says why (`info`); that it stops at the target;
  and that a scan whose centre is solid needs `opts.move.dig`.
- **T.refuelFromLava(target)** takes up the nearest lava source the map knows with
  an empty bucket (a placed empty bucket scoops a source: confirm in game, as mine's
  `scoop` does), burns it for 1000 fuel and walks back. Check the net gain it
  reports against the tank.
- **T.fuelFor(plan)** adds up route, build and scans against the tank and fuel on
  board. The scan cost is an estimate from the r=16 figure; set
  `T.cfg.scanFuel = { [8] = cost }` from what `T.scan` reports in `info.fuel`.

## tl.store: the chests at home, fetching, stowing and T.cfg.autoDump (ADR-0008 phase 4)

`T.addChest(x, y, z, side, bulk)` tells the turtle where a chest is (the cell it
stands in and the side the chest is on, as `T.setJunkChest` does); the list and
what each chest held is in the data file `.chests`. Start with two or three
chests in a row and the turtle at home:

- **T.catalogue()**: goes round the chests nearest first, reads each one
  (`peripheral.wrap(side).list()`), writes down what is in it, and comes back
  facing as it was. A chest that was broken or can't be reached is reported
  (`false, why, info`) and the rest are read. Check that it works on a barrel
  too, and that `T.catalogue(nil, { find = box })` (the chests the map shows in a
  box) stands in a sensible cell beside each.
- **T.where(name)** lists the chests with an item (a name or a glob), nearest
  first, with the total, and moves nothing. **T.fetch(name, n)** goes there, takes
  the count with `T.pull` (a mixed chest, a part stack, across two chests), reads
  the chest again and comes back; a chest someone emptied since is put right and
  the next one tried.
- **T.stow()** puts away what is not kept (not in `T.keep`, not crafted this job,
  no tool, fuel, bucket or peripheral): into a chest that already holds the item,
  else into the bulk chest. `T.stow({ all = true })` puts away the kept things
  too, never the tools or fuel. What does not fit stays aboard and is told.
  Check that nothing is ever dropped in the world (a chest that is full, a chest
  that is gone).
- **T.cfg.autoDump = true** (or a number of free slots; true is 2): after a dig
  that leaves that few free slots the turtle goes to the chests (or the junk chest,
  with no chests) and comes back where it was. Check it in the middle of a dig run
  (`T.moveTo` with digging, or mine with it set): that the position is right afterwards, that
  it does not loop when there is nothing to put away, and that Ctrl+T stops it.

## tl.craft: T.craft, T.canCraft, T.smelt and the fuel and smelting tables (ADR-0008 phase 4)

Recipes are data (`T.RECIPES`, `T.recipe(name)`, `T.addRecipe(spec)`); `T.craft(name, n)`
works from a chest in front of, above or below the turtle (or `opts.chest`,
or the junk chest). Start with a chest in front holding 12 stone bricks and a
crafting table on the turtle, a chunk controller on one side:

- **Stairs from blocks, the controller kept on**: `T.craft("minecraft:stone_brick_stairs", 8)`
  puts the crafting table on (the side that does not hold the chunk
  controller), stashes the whole inventory in the chest (the pickaxe too),
  fills the grid slots 1-3, 5-7 and 9-11 from it, crafts, and puts everything
  back: the pickaxe on its side, the other stacks in their slots, 8 stairs
  aboard. The chunk controller must not come off (watch the right side).
  Check the real `workbench.craft(limit)`: that it takes the limit as the number of
  crafts, what it returns, and that it needs every slot outside the grid empty.
- **The product lands outside the grid**: the turtle selects slot 16 before
  each craft (mine did the same); check that stairs do not turn up in the
  grid slots, and that a craft of more than a stack (`T.craft("minecraft:stick", 300)`,
  75 crafts in two rounds) does not drop items in the world.
- **Room in the chest** is checked first (the inventory's stacks, the product and
  one spare); a chest short of room is refused with nothing moved. The
  ingredients (inventory plus chest) are checked first as well: `short of
  minecraft:stone_bricks: need 6, have 5`. `T.canCraft(name, n)` says the same
  without moving; its first result is `true` when it can be made (tl.blueprint's
  materials check now uses the real one).
- **The table in the chest** is pulled, used and put back; **already on** it is used
  and left on.
- **Families**: `minecraft:birch_door`, `minecraft:polished_blackstone_brick_stairs`,
  `minecraft:stone_brick_wall`, `minecraft:oak_slab`, a mixed `minecraft:chest`
  from any planks. The table is from memory of the vanilla recipes (1.21): check
  a few against the recipe book, above all the counts (a wall 6 from 6, stairs 4
  from 6, a door 3 from 6, a trapdoor 2 from 6, iron bars 16 from 6, a fence 3
  from 4 planks and 2 sticks, a boat, a sign 3).
- **`T.smelt(item, n, fuel)`**: with a furnace on board, five free cells (the two
  over the turtle, the one in front, the two over that), it sets the furnace up in
  front of the turtle, one block up, drops the fuel from beside and the item from
  above, waits under it and sucks the results out as they cook (10 seconds
  each), digs the furnace up and comes home facing as before. Check that a
  turtle can place a furnace in mid-air (the turtle's own block is the last thing
  it clicks), that fuel dropped from the side goes in the fuel slot, the item
  dropped down in the input slot, and `suckUp` takes the result from below.
  `opts.move = { dig = true }` lets it dig the way free.
- **Tables**: `T.fuelTicks` (coal 1600, planks 300, a lava bucket 20000, wooden
  slabs 150, doors and signs 200, boats 1200; the nether's woods nothing) and
  `T.smeltsTo`; the nether woods really do not burn or make charcoal.

Not done here: crafting an ingredient first (planks from logs for a chest): call
`T.craft` for each step. Recipes added by `T.addRecipe` are kept in memory only;
put the calls in `/claude/helpers.lua`. mine, farm and mow still do their own crafting.

## tl.blueprint: T.build, T.verify, T.replace (ADR-0008 phase 3, ccnix 0.48.0)

A plan is layers of text with a legend (`T.blueprint.parse`, or a table, or
`T.blueprint.fill/box/walls/fromMap`); `T.build(plan)` puts it up. Needs the
world origin only for a stair or the like that names a `facing`. Start with a
small plan (a 5 by 5 floor, walls, a stair bench, a torch, a door) beside the
turtle, with the items on board:

- **The text and the cells**: the first line of a layer is the highest z, a
  column goes toward +x, the next layer is up; the anchor is the turtle-frame
  cell of the first character. Build a 3 by 3 plan and compare with F3 that
  the corners are where `T.blueprint.at(plan, x, y, z)` says.
- **Build order and stand**: layer by layer from the bottom; each plain block
  placed downward from the cell over it; in a layer, plain blocks, then stairs
  and slabs, then torches, ladders, buttons, trapdoors and gates, then doors.
  Watch that the door goes in last and sits right in its gap, and that the
  upper half is not placed separately (a door's upper cell in the plan is
  written `half=upper`, or just the same door again over the lower cell).
- **Materials**: with less of an item than the plan needs, `T.build` should
  refuse with `short of ...` before moving (`opts.partial` builds what it can).
- **Stop and carry on**: `T.build(plan, { limit = 20 })` stops after 20 cells;
  `T.build()` carries on, also after Ctrl+T or a reboot (the files are
  `.build`, the plan as text, and `.build.progress`, in the data folder). A
  cell the map says is already there is taken as done without a look;
  `opts.look = true` looks at each.
- **`T.verify()`**: after the build, clean (no plan = the saved build). Turn a
  stair round by hand and see it listed with `facing=` both ways; break a plain
  block and see that only `{ inspect = "all" }` finds it (the map is trusted for
  plain blocks). Cells it cannot reach to look at are listed as `unverified`.
- **`T.replace(box, "stone", "minecraft:stone_bricks")`** on a thick wall: each
  block dug from a free side and replaced; one with every neighbour solid in
  the map is listed in `trapped` and left alone. The map has to know the box
  (scan it first, or pass `scan = true`). In a protected area it needs
  `inside = "<area>"`.
- **`opts.protect = "keep"`** on a finished build protects its box under the
  plan's name; check a `turtle.dig()` into it comes back `protected: <name>`.
- Fuel is not checked before a build (moves ask for fuel as they go); a big plan
  on a thirsty turtle stops at "out of fuel" with the cell failed.

## tl.place: T.placeAt and T.ignite (ADR-0008 phase 3)

`T.placeAt(x, y, z, item, { facing, half, axis })` places a block with the state
wanted: it picks, from a table of what each way of placing gives (sideways,
from above, from below; `T.PLACE_TABLE`), the way the map says is possible,
goes there, places, inspects, and digs and retries if the state is wrong. The
table is the building mock's (read from CC:Tweaked's source), so the facts under
"The building mock's placement rules" below are what to check first; then:

- **Stairs and slabs both ways**: with the origin set (`T.setOrigin`),
  `T.placeAt(x, y, z, "minecraft:oak_stairs", { facing = "north", half = "top" })`
  in the open (placeDown, nothing below: top half), then under a ceiling block
  (placeUp: top half), then sideways onto a wall (bottom half). Inspect each
  (`turtle.inspect*`, or `T.map.get`). The result's third value says which way
  was used.
- **Facing needs the compass**: a stair `facing` is a compass name, so
  `T.setOrigin(x, y, z, facing)` first (or a geo scan or GPS gives it). Place one
  in each of the four facings and compare with F3.
- **A wrong table row is learnt**: if the game gives something the table does
  not say, the first try is dug out and the next approach used, and the row is
  noted in the data file `.placements` (a line like `stairs down always half=top`);
  the next placement of that kind goes right the first time. A guess on cells
  the map has never seen is not noted. Look at the file after a placement that
  took a second try, and delete it to forget.
- **A wrong try inside a protected area** is dug out all the same (the library's
  own block); check the area still refuses `turtle.dig()` of anything else.
- **Logs, torches, doors**: a log's `axis` (standing, along the heading, across);
  a torch with `facing` on a wall (it walks round to the far side if the wall is
  between) and with nothing asked on a floor; a ladder, button, lever, trapdoor,
  fence gate and chest by `facing`/`half`/`face`; a door needs a solid block under
  it and the cell above free (the map is asked; a door with air under it is
  refused before any move) and goes in after the walls round it.
- **`T.ignite(x, y, z)`**: flint and steel from above: the turtle goes to the
  cell over it and uses the flint and steel downward on the block under, which
  should put the fire in the cell between (netherrack, say). Inside an obsidian
  frame that lights a portal and `T.ignite` should report `minecraft:nether_portal`.
  The fire cell is sideways-lit by the mock the same way (a click on the block
  beyond); only the downward one is used. Confirm CC lets a turtle light fire
  this way and the flint and steel is not used up.
- **The map's name for what was placed**: after a placement the map holds the
  block as inspected (`wall_torch`, with its state), not the item's name.

## The building mock's placement rules (ADR-0008 phase 3, sim/lib/buildworld.lua)

The mock models `turtle.place*` from the source of CC:Tweaked 1.120.2
(TurtlePlaceCommand and TurtlePlayer, read for this) and from Minecraft's
rules as remembered; the pieces on top (tl.place, tl.blueprint) will trust it,
so these are the facts to see once in game. Place each with the item in hand,
then `turtle.inspect*` from beside it.

- **The last resort faces back**: a stair placed sideways with no block beyond
  and no floor under the target (in mid-air) should come out `facing` the
  OPPOSITE of the turtle's heading (the placer is put in the target cell
  looking back at the turtle). With a floor under the target, or a block
  beyond, `facing` is the heading. placeDown and placeUp always give the
  heading.
- **Halves and axes**: sideways stairs/slabs always bottom half; placeDown top
  half when nothing is under the target, bottom with a block below it;
  placeUp the reverse; a log sideways lies along the heading with a block
  beyond, stands with only a floor.
- **Torches**: sideways onto a block beyond: a wall torch hung on it;
  floor only: standing; placeUp: refused. With no block beyond, no floor and a
  wall to one side the mock hangs it on that wall. A torch on a bottom slab or
  the side of a bottom slab is refused. When two supports compete for a
  torch, ladder, button or lever, the mock uses the clicked side first, then
  Direction.orderedByNearest's order as worked out from Minecraft's float
  sine table: looking down (placeDown), down, ahead, right, left, behind, up;
  level, facing south or west, ahead, down, right, left, up, behind; facing
  north or east, ahead, right, down, up, left, behind. A ladder is never
  placed against the front of another ladder.
- **Doors**: refused with no solid block under the target (even with one
  beyond) or something in the cell above; a door beside a full block gets
  its hinge on that side (the click is always the middle, so left otherwise).
- **Slab on a slab**: placeDown with a slab onto a bottom slab of its kind
  makes a double slab; with another kind it is refused.
- **Stair corners**: the `shape` (inner/outer, left/right) the game gives two
  stairs at right angles, and the neighbour changing shape when the second goes
  in, against the mock's.
- **Furnace**: fuel dropped from the side or the underside goes in the fuel
  slot, items dropped from above in the input slot, the result comes out of
  the underside by `suckUp`; a stone block dropped from the side is refused;
  crimson and warped planks are not accepted as fuel.

## tl.path: routes over the map (ADR-0008 phase 2, 0.47.0)

- **A route and its cost**: with a scanned area, `T.path(x, y, z)` in claude's
  code returns a list of cells and `{ nodes, cost, digs, unknown }`; the turtle
  does not move. Ask for a cell behind a lava pool or a protected box and see
  the route go round. How long a search takes on a real turtle (Cobalt is
  slow) is only known here: `T.path` over 30 or 40 blocks of scanned air, and
  the same over empty map (everything unseen). The default limit is 20000
  cells searched; "no route: gave up after searching ..." says it hit it.
- **Yielding**: a long search must not be killed by CC ("too long without
  yielding"); it gives the computer a turn about every half second. Try a
  search over a big unscanned stretch and press Ctrl+T during it: it should
  stop at once with "Terminated".
- **Travel over a wall**: in a place with a roof (the Nether), put the turtle
  by a high wall with the other side scanned in the map: `T.travel(x, y, z)`
  climbs to a layer between the wall's top and the roof, crosses and comes down,
  without digging. Without the map it scans the route's box first (up to 27
  scans, each fuel; `opts.scan = false` skips it, and a box over 27 scans is
  refused, then the search takes over).
- **Re-planning**: send it through ground the map has never seen, with stone in
  the way and `dig` off: it stops at the stone ("blocked by ..."), notes it in
  the map (`T.map.get` agrees), and goes round. A mob standing still in a
  corridor is kept out of the next plan. After 6 re-plans it gives up and says
  so.
- **moveTo and routes**: `T.moveTo(x, y, z, { path = true })` blocked by a wall
  asks `T.travel` to take it the rest of the way.
- **Protected areas**: a route never enters a protected area's solid cells; its
  empty cells are open only to a route that starts or ends in that area (a
  turtle inside the castle's walls can walk its courtyard). `opts.inside =
  name` lets a job dig in the area it owns.

## tl.world: the map, the frames, scans and inspects (ADR-0008 phase 2)

- **A scan in the turtle's frame**: `T.scan(8)` in claude's code with the Geo
  Scanner in the inventory (a chunk controller on one side, a pickaxe on the
  other): the scanner goes on for the scan and the pickaxe comes back, the
  result is `{ ["x,y,z"] = name }`, and the blocks are where `T.look` agrees
  they are from each of the four headings. The info table's `fuel` is what
  the scan cost on this server. `T.scan(9)` is refused; `{ force = true }`
  allows it. If the scanner reports its cooldown another way than an error
  return, the retry (5 asks, a second apart) may not trigger: see what it
  says.
- **Entries without r/u/f**: the scan relies on each entry carrying `r`, `u`
  and `f` (Advanced Peripherals 0.8, as mine.lua uses); an older one gets "the
  scan's entries carry no r, u and f".
- **Air in the map**: the cells inside a scan that the scanner lists no block
  for are noted as air (`opts.air = false` leaves that out). If the scanner
  leaves out some blocks (the castle turtle thought stairs and slabs), the map
  will say air there; `T.inspectAt` is the check.
- **The map on disk**: after a scan, look in the data folder (`/ccnix/turtle`
  on a ROM turtle) for `.map/` with `frame` and files named `cx_cy_cz`, each a
  few KB. `T.map.stats()` says cubes, bytes and the cap (the smaller of 512 KB
  and a quarter of the disk; `sysctl map.maxBytes=...` changes the first).
  Walk, dig and place with other programs (`mine`, `farm`): the map follows,
  written in batches (a minute of work may leave a few changes unwritten if the
  turtle is stopped with Ctrl+T: `T.map.flush()` writes them).
- **The frames**: scan, walk off, run `mine --here` (`T.startAtHome(true)`),
  scan again: `T.map.get` in the new frame should still agree with the first
  scan, and `T.map.frame()` shows the quarter turns and shift. Delete
  `.turtlepos` and start a program: `T.map.get` answers "the map is
  unaligned" until `T.alignMap(dx, dy, dz, turns)` (or `T.map.clear()`).
  (`reset --here`, `T.setHomeHere`, and `T.setDir`, mine's and farm's heading
  correction, leave the map where it is: see the integration entry above.)
- **The origin**: `T.setOrigin(x, y, z, "north")` with the coordinates from F3,
  then `T.toWorld(...)` against what F3 says at another place; `T.setOrigin(x,
  y, z)` (the facing from a scan) and `T.setOrigin()` (GPS too, if the world
  has one) should give the same facing as the F3 one. The scanner's x and z are
  the world's, mirrored against the turtle's right: the facing is worked out
  from that and was only checked against the mock.
- **Inspecting**: `T.inspectAt` on a stair or a slab: its `facing`, `half` and
  `shape` come back and are kept (`T.map.get` after a restart). A cell
  boxed in by solid blocks is "couldn't get next to"; `T.inspectAt` does not
  use the path module yet.
- **scanBox**: `T.scanBox({0, 0, 0, 30, 10, 10}, { move = { dig = true } })`
  makes two or three scans, walking to each centre.
- **Views**: `print(T.map.heights(box))` and `print(T.map.slice(y, box))` on a
  scanned area read sensibly (rows run from the high z down to the low z).

## turtlelib's reference and claude's prompt (ADR-0008 phase 1, 0.46.0)

- **The index in the prompt**: start `claude` on a turtle with the ROM (or an
  updated checkout): the first request's system prompt should hold the
  "What you can call in turtlelib" section with a line a function, and a path
  for the reference. Ask it "what does T.moveTo return?" without letting it
  read anything: it should answer from the index. If `turtle/tl/index.txt`
  is not on the computer, claude prints a yellow line at start and the prompt
  says the index is missing (try it by moving the file away).
- **The reference on the turtle**: `help turtlelib` pages the full reference
  (about 20 KB, so check the pager copes), and `help ccnix` lists it under
  the turtle programs. In claude, ask it to read what T.pull does in more
  detail than the index: it should open `help/turtlelib.txt` through fs and
  print only the part it needs (the prompt gives it the path and an example).
- **setup and update**: `ccnix setup claude` (and mine, farm, mow) on a
  checkout install brings `turtle/tl/` (just `index.txt` until the first
  module lands) and `help/turtlelib.txt`; `ccnix update` on a ROM turtle
  fetches them (the update takes the whole `turtle/` folder).
- **status and protection**: `T.protect("home", ...)` around the turtle in
  claude's code, then `status`: "protected areas near: home (...) - the
  turtle is inside it". A far area is only counted.
- **The prompt's new prose** (frames, safety, cost, how to work): read a
  session's first replies for anything that no longer fits what the turtle
  really does; the prompt is cached, so a long session pays for it once.

## turtlelib: withPeripheral, pull, moveTo, junk, the module loader (ADR-0008)

- **withPeripheral**: with a chunk controller on one side and a pickaxe on
  the other, `T.withPeripheral("advancedperipherals:geo_scanner", function(p)
  return p.scanBlocks(8) end)` in claude's code: the scanner goes on the
  pickaxe's side (the controller stays on, so the chunks stay loaded), the
  scan comes back, and the pickaxe is back on after, also when the function
  errors. Try the chat box the same way, and with the controller on the other
  side. Check the wait for the peripheral is long enough (2 s) on a real
  server, and that an upgrade swap leaves no stray item.
- **pull**: `T.pull("bottom", "minecraft:cobblestone", 150)` from a chest of
  mixed stacks gives 150 across slots and leaves everything else; from a full
  chest (the wanted stack at the back) it puts the stack it moved aside back.
- **moveTo**: `T.moveTo(x, y, z, { dig = true })` over a few blocks of stone
  and gravel; `false, "blocked by ..."` with dig off; lava, fire and a door
  stopped at ("avoiding ..."); a protected area refusing the dig
  ("protected: ..."); `inside` digging in it. Its fuel top-up at under 50
  fuel, and "something is in the way" for a mob.
- **junk**: `T.setJunkChest(x, y, z, "up")` (the chest above the cell),
  `T.dumpJunk()` with junk aboard: it walks there, drops only into the chest,
  and walks back facing as before; with the chest broken it drops nothing.
  Needs the job's building materials in `T.keep` first.
- **Modules loaded on first use**: nothing in `turtle/tl/` yet (the first
  module comes with the next piece); the loader and the path (`require
  "tl.x"` finding `turtle/tl/x.lua` through ccnix's `turtle/?.lua`) are tested
  only on a fixture in the sims. In game, the first module is the test.

## turtlelib: the turtle API wrapped, protected areas, change hooks (ADR-0008)

- **The wrap**: after turtlelib loads, `turtle.forward()`, `back`, `up`,
  `down`, `turnLeft`, `turnRight` called straight keep `T.pos` and `T.dir`
  right (and save them), and mine, farm and mow behave as before. Try
  `lua` in claude: `turtle.dig() turtle.forward()` then `status`. Running
  `mine` from claude (run_program) and then moving straight through
  `turtle.*` should still update claude's `T.pos` (claude takes the wrap
  back after a program).
- **Protected areas**: `T.protect("castle", x1, y1, z1, x2, y2, z2)` in
  claude's code, then `turtle.dig()` into the box returns `false,
  "protected: castle"`; so do `T.digDir` and `T.forward` with the block in
  `T.diggable`; the file `.protected` beside the programs keeps it over a
  reboot and a second program (mine, farm) on the turtle respects it.
  `T.inside("castle", fn)` digs inside it; `T.unprotect("castle")` lifts it.
- **Chests and computers**: `turtle.dig()` at a chest, barrel, shulker box,
  spawner or ComputerCraft block returns `false, "won't dig ..."` unless
  `T.cfg.digContainers = true` (real block names, e.g. a modded chest, are
  caught by "chest" in the name).
- **Hooks**: `T.onChange(fn)` hears digs (with the block's name and state),
  placements (with the item) and moves.

## claude: http, the network, programs, memory, the web, the rest (0.39.0)

- **The log** (0.45.0): a session, then claude.log. Each entry starts
  with its time (UTC); the first is `start: claude --cache 1h (model ...,
  effort ..., steps 60, cache 1h; at ... facing ..., fuel ...)`; after
  each call a `tokens: N in (R from the cache, W written to it, U new), O
  out; Ss` line; when a goal ends `goal done: [...]`, as printed; a retry
  and a failed request are logged too.
- **Log rotation**: past 256 KB (setting `claude.logSize`, bytes) claude.log
  becomes claude.log.1, replacing any older one, and a new claude.log starts.
- **Kept helpers**: `/claude/helpers.lua`, if there, is run in the code's
  world at the start of a session, so its functions are there in every lua
  call; a broken file is told to the model with its first goal, and the
  session carries on. The prompt tells the model to keep helpers there.

- `--cache 15m`: refused (0.44.0).

## claude: ccnix's libraries in its code, the rest (0.38.0)

- `require("turtlelib")` and `require("fs")` (0.43.5) say the code has
  them already, as the globals T and fs.

## Everything: the text libraries, what's left (0.36.1-0.37.0)

Every program's parsing moved from Lua patterns to lib/scan (0.36.1),
then onto the shared lib/text, convert, getopt, glob and path (0.37.0).
The two smoke rounds of 2026-11-12 (Tested) covered the shell, globs,
numbers, the text tools and the network tools. Still to try:

- **setup run alone, on a stock CC: Tweaked computer** (no mod): `wget
  run .../deploy/setup.lua`. It fetches lib/scan, text, convert, path and
  getopt into memory before git. Then `ccnix update`; `ccnix setup` once
  on an install made before 0.37.0 adds the text libraries to a checkout
  cloned with `--only` paths; `ccnix setup --autostart=router`; setup's
  migration from an old /cc-turtles, if one is left anywhere.
- **The turtles:** `farm` on a real farm (options through lib/getopt),
  its saved layout read back after a reboot.
- **Text on screen:** the pager wrapping a long coloured line (`vim` on a
  long line).
- **The rest:** a panic report (one row layout); jbod on the
  fileserver; a log message received over the network (syslogd with
  `syslog.listen`, another computer forwarding to it): its line end and
  the blanks before it dropped (a message logged on the computer itself
  keeps them, as util-linux logger does).

## Editors

- **Esc through telnet** (0.43.6): with the ccnix mod on the client,
  `telnet 10.1.1.10`, `vi /tmp/x`, `i`, text, Esc: insert mode left (the
  client now sends Esc as a lone ESC; before, it sent nothing). From a
  real terminal (PuTTY) Esc does the same.

## ccsh

- **Background output while typing, the rest** (0.30.0). A full-screen
  program in the background isn't disturbed; the same over telnet.
- **Ctrl+C left to programs that use it, the rest** (0.29.1). `telnet`
  from a computer without init: Ctrl+C reaches the far side's program.
- **The line editor, the rest** (0.28.0, lib/readline). `read x` at the
  keyboard has the same keys; Ctrl+C there stops the rest of the line.
- **Tab and long lines, the rest** (0.28.0): the completion in grey on a
  basic computer; Up/Down cycle the suggestions. A coloured prompt redraws
  correctly after Ctrl+L. AltGr (Ctrl+Alt) characters on a non-US layout
  type normally and trigger no bindings.
- **Ctrl+C, the rest** (0.28.0): a computer without init; under init it doesn't reach
  ccsh itself when ccsh was started from ccsh.
- **The editor over telnetd** (0.28.0): the same keys from a real terminal
  client (PuTTY, xterm); Alt+B/F arrive as Esc+letter; Ctrl+C at the remote
  prompt drops the line.
- **`$$`, the rest** (0.27.0). Without init (plain CraftOS), `$$` is the
  computer ID and `$PPID` empty.
- **`&>>` and the other `${...}` forms, the rest** (0.27.0). A stock
  program's printError output lands in f with `&>`. `${U:?gone}` in a
  script ends the script with status 1. Plain `unset f` leaves a
  function.

## Processes and services

- **Panics in a row stop rebooting** (0.29.1). With init.boot on and a
  fault init hits at every boot (a temporary `error()` near the top of
  `K.run`), it reboots after each of the first three panics, then the
  fourth shuts the computer down with "panicked 4 times in a row" on the
  screen; `/var/log/panic.count` holds the count. Remove the fault, boot:
  no panic; a panic more than ten minutes later counts from 1 again.

- **Commands run through lib/procrun** (0.26.0). Services, telnet sessions
  and the console chain (autostart, ccsh) still start and get their quoted
  arguments as before; `shell.getRunningProgram()` and `arg` inside them are
  unchanged; a cu utility's own non-zero exit still shows as `failed: exit
  status N` with no "crashed" line.
- **An init panic** (0.26.0). Hard to trigger (a temporary `error()` in a
  K.after callback in lib/proc.lua): `/var/log/panic` has the error,
  traceback, ps table and unfiled log lines; it prints "Rebooting in 10 s"
  and reboots; holding Ctrl+T during the wait shuts down instead; `set
  init.panic 0` shuts down at once, as before. After the reboot,
  `/var/log/messages` has a kern.crit "the last boot ended in a panic: ..."
  line and the report is at `/var/log/panic.1`.
- **init's per-turn swap with `parallel`** (0.26.0). Programs that use
  `parallel` (telnet, httpd, the miner under init) show no cost or side
  effects.

## Network

- **ping, the rest** (0.29.0). `ping -s 65507` through the gateway, in
  NAT mode (the gateway's own address) and in TUN mode (a real host).
- **`netstat -s` on a router, a forged source** (0.29.0): the drop counted
  by reason (martian or rpfilter), and the router screen's spoofed count
  agreeing.
- **`ip neigh add ... dev <iface>`** (ccnix 0.24.0) for an address off
  every interface's network.
- **Source checking on the host's TUN chain** (`ccnix0-src`): needs
  `gateway.sourceCheck` off, then a forged source from inside is dropped by
  the host instead.
- **Syslog forwarding in NAT mode**: `@host` rules forwarding out through a
  NAT-mode gateway.

## mine

- **`mine where` between homes** (0.43.4): after a Ctrl+T part way, it
  says "`mine reset`, then `mine --resume`, carries on" (it said `mine
  --resume`, which wants the turtle at a home); at a home, `mine
  --resume` alone.

- **Resuming from an earlier home walks out in one go** (0.22.0). `mine
  reset --home N` (N a few homes back), then `mine --resume`: one pass to the
  last home, valuables kept on board (none left in home N), useful supplies
  picked up from each home passed, no shuttling back and forth; where water
  gets in it stops, seals it (trips for bulk blocks go to the home ahead), and
  carries on; the block above the last home's valuables chest is cleared.
- **Torch look-round only with water in front** (0.21.9): in a dry tunnel no
  extra turns at torch spots; next to water, no torch that gets washed away.
- **Floor beside old patches checked only near water** (0.21.8): a long walk
  out over dry tunnel doesn't cross to the other columns at cobblestone
  patches; near water it does, and fills open floor there.
- **Sweep fallback for water it can't trace** (0.21.6): a stretch still wet
  after going back over it gets every outside face of the tunnel there looked
  at and sealed.
- **Lava burned with a bucket** (0.21.0, logged per source since 0.21.7):
  `grep "Burned a lava" /var/log/messages` after it meets lava sources; the
  bucket stays on board and comes back to the start chest at the end.
- **The water-after-survey path** (0.19.0): water getting in while a segment
  is dug with a scanner is sealed after the survey and the floor walked again.
- **A real cavern** (0.18.2): bulk blocks fetched from the homes behind when
  a cavern runs it out; scans still trusted in a cavern.
- **Floor holes reported** (0.21.4): `Left N floor holes open at z=a..b` when
  it runs out of bulk blocks, and the next pass filling them.

## Setup and boot

- **`syslog.maxSize` with K/M** (0.21.0): `sysctl syslog.maxSize=2M`
  (taken, tested), then a log rotating at that size.

- **`ccnix update` on many computers at once** (0.30.2): GitHub answered
  some with 504; git now tries a 5xx again after 2, 4 and 8 s.  If the
  API's hourly limit for the server's address runs out, it says until when.

- **`wget run …/deploy/setup.lua` on a bare old install** (0.20.0): a
  computer that still has only `/cc-turtles` (from before ccnix): moved to
  `/ccnix`, pointed at the ccnix repo, pulled, old startup lines swapped.
  (`git pull` then `deploy/setup` on such a turtle worked.)
- **`ccnix setup` on a server with the ccnix mod** (0.20.0): settings and
  apps chosen through the ROM's setup.

## screen

- **Ctrl+A a with one a** (0.43.6): in screen, Ctrl+A then a gives ccsh
  its Ctrl+A (the start of the line) at once; it wanted a second a (a char
  for Ctrl+A itself was waited for, and CC sends none while Ctrl is held).

## IRC

- **A real client through the gateway** (0.35.0). From the VM:
  `irssi -c 10.1.1.6 -n vm`, /join #minecraft, talk with B. On Libera,
  `/set network.<name>.sasl_user` and `sasl_pass` for SASL (a channel
  that wants a NickServ account, as #minecraft there does).

## The mod

- **The exchange at 10.1.0.0/24** (ccnix-mod 0.18.0). The gateway's default
  address is 10.1.0.1/24, inside the CC networks (10.1.0.0/16), so one LAN
  route reaches every CC computer. On the dev server, after redeploying:
  `ip -br addr show ccnix0` on the host shows 10.1.0.1/24 alone (the old
  10.0.0.1 gone); `/ccnix route add 10.1.0.0/16 via 10.1.0.2` is accepted
  (a route around the exchange) and `10.1.0.0/25 via 10.1.0.2` refused;
  a computer straight on the exchange (no router) reaches the internet.

- **The ansible EULA gate** (ccnix-mod 0.15.39): a run with
  `minecraft_eula_accepted` unset skips the eula.txt task and leaves an
  existing eula.txt alone; on a fresh host the server doesn't start until
  eula.txt says true; `-e minecraft_eula_accepted=true` writes it.


## Known issues seen, not yet looked at

- The first boot's lines can appear twice in `/var/log/messages`, the first
  copy cut short.
- `ip up` on a turtle (2026-11-11, ROM 0.40.3) seemed not to bring the
  network up: pings worked only after `ip boot` and a reboot. `ip up` was
  run before the routes and DNS were set, which apply at once anyway.
  One cause found: claude had swapped the turtle's modem out and back for
  mine's pickaxe, which leaves its channels shut (reopened since
  0.41.1).
- httpd on Lab-B (2026-11-11, ROM 0.40.3), started at boot and logging
  "listening on port 80", later had no listener (`netstat -al` empty,
  "connection refused") while `service status` said running; `service
  restart httpd` brought it back. Before it: the 8.5 network tests
  (`ip neigh add`, a reboot, `ping -c 0` stopped with Ctrl+C, a `ping &`
  stopped with Ctrl+T after `fg`, `nc -w 3` to a host that was down).
  Not found by reading lib/net, lib/proc, lib/httpd yet. After the next
  reboot it was listening (`netstat -tnl`).

## Tested

- 2026-11-12 — ROM 0.44.0, claude caching the conversation: hours of the
  castle build with `--cache 1h`. The Console's usage for one hour: 5.96M
  tokens read from the cache, 81k written to it (all 1-hour), 902 new,
  69k out: 98% of what went in came from the cache, and no context clears
  in those sessions.

- 2026-11-12 — ROM 0.43.5: vim colours a ccsh script (a string over two
  lines, comments after `;`); `*` from a space searches the next word.
  irc: a hilight chimed on Lab-B's speaker; `irc irc.libera.chat`
  connected and joined #minecraft there (speaking needs a NickServ
  account); ccsh's Ctrl+A/E, Ctrl+R, Tab, history.  screen: `screen -x`
  over telnet with Lab-A's console (both showing and typing),
  `screen.prefix=b`.  `help git/tcpdump/claude/vi/vim` end with their
  trademark notes.  Not right (fixed in 0.43.6): Esc in a telnet session
  didn't reach the far side's vi, and Ctrl+A a in screen wanted a second
  a.

- 2026-11-12 — ROM 0.43.3, claude's long session: it equipped a chat box
  from its inventory in the modem's place and said "hello from the
  turtle" in the game's chat (shown as [AP], mc.say given no name), then
  read 47 help pages before its 60 tool calls ran out, said so, and
  carried on when asked; claude.log showed "context: 51 old tool results
  cleared (31278 tokens)" on each request past the threshold (the API
  clears afresh each time). 1.4M tokens in for the goal, half cached.

- 2026-11-12 — ROM 0.43.4, claude: told to dig with mine, Ctrl+T stopped
  both; asked, it found the job unfinished, said where the turtle was,
  and `mine reset --to-start` brought it back.  `require("turtlelib")` and
  `require("fs")` refused, listing what it may have (it worked out T and
  fs itself; the error names them since 0.43.5).

- 2026-11-12 — ROM 0.43.3, the turtle: `mine -3 3 8 --no-lights --new`
  (-3 the width), Ctrl+T, `mine where` the same after a reboot, `mine
  reset` back to the start; `mine 3 3 6 --spacing=4 --new` (homes every
  4); `mow 3 3 notorch` (no torches); `farm --bogus` with no farm (the
  usage); `claude go -5 blocks` (5 back; its Lua in colour).  Not right:
  `mine where` said `mine --resume` carries on, but --resume wants the
  turtle at a home (`mine reset` first; fixed in 0.43.4).

- 2026-11-12 — ROM 0.43.3: `sysctl ccsh.login=yes` refused ("ccsh.login
  is a boolean: not yes", status 1); `sysctl ccsh.login=true` taken.

- 2026-11-12 — ROM 0.43.2: a /startup.lua's output kept on the console
  under init; the wheel scrolls the console's scrollback (ping's output
  waits below while it's open), vi keeps the wheel; Up through the
  history doesn't loop; `> /nodir/f` (no folder made), `> /rom/x`, `>
  /rom` errors; `sysctl -a`, `-n`, `-d`, an unknown name (1), `name=2M`,
  `name=` (not set); ccsh's `set --`, `-x`, `$-`, `-o`, `-f`, `-e` in a
  script (status 1), `-u`.  Not right: `sysctl ccsh.login=yes` was taken
  as the text "yes" (ccnix's settings aren't defined with a type; fixed
  in 0.43.3).

- 2026-11-12 — ROM 0.43.2: irc's hilightwin (a "hilight" buffer with the
  hilight and the kick), autorejoin (kicked, back at once), `/script
  autorun slap` (loaded at the next start), Alt+A to the buffer with
  something new.  `service disable ircd` and a reboot: not running;
  enabled and started again.  The gateway's dialog through the Network
  Configurator (labels in their column, the VLANs box, Done), and
  ccnix's Credits and Authors in the mod list (0.26.0).

- 2026-11-12 — the exchange at 10.1.0.0/24, in game: a router's back.1 is
  10.1.0.2/24 with `default via 10.1.0.1`, and the internet answers
  through it (`host example.com`).

- 2026-11-12 — ROM 0.43.2: `ping -c 1 10.1.2.99 &` then `ip neigh`:
  INCOMPLETE, 1 queued, asked 2 times; gone a moment later (three asks a
  second apart).  Services: a syntax error and a missing command each
  `failed: exit status 1` with the error in the last lines; `kill -TERM`
  of a service's process, `failed: Terminated`, no traceback (each then
  restarting, as services do).

- 2026-11-12 — ROM 0.43.2, the network: `ping -s 65507` to a host across
  the router and to the router (bytes=65507, no note); `ip route get
  example.com` (the address, via, dev, src, the route and the neighbour);
  `ip neigh add` of a wrong MAC with the network down (permanent, pings
  fail), `ip neigh del` (pings back); `nc -zv 10.1.1.10 23` open, and
  telnetd logged nothing for it; `netstat -s` on the router agreeing with
  its screen (forwarded 7791, dropped 0).  `ip neigh` after `ping -w 2`
  of a missing host showed no INCOMPLETE: by then the three asks (a
  second apart) were over; asked again in the background.  Shift+PgUp
  on a router without init: nothing (the scrollback is init's); with
  init.boot on, it works there too.

- 2026-11-12 — ROM 0.43.2 with ccnix-mod 0.26.0 on the client: Esc
  leaves vi's insert mode, Esc then b moves ccsh's cursor a word back,
  Esc then 2 goes to irc's buffer 2, Esc leaves screen's scrollback; the
  same on a turtle and a pocket computer.

- 2026-11-12 — ccnix-mod 0.26.0 on the client (the server at 0.25.1):
  Esc no longer closes a computer's, turtle's or pocket computer's
  screen, and Shift+Esc does; the inventory, a chest and the gateway
  dialog still close on Esc.  Not right (fixed in ccnix 0.43.2): vi
  didn't leave insert mode and ccsh's Esc then b typed a b. The key
  arrived, but CC's keys table has no escape (the game never let it
  through), so nothing knew it as Esc; telnet's Esc had the same gap.

- 2026-11-12 — ROM 0.43.0, vi's commands: `:.,+2>`, `:/beta/;+1d`,
  `:ka`/`:kb` then `:'a,'bm$`, `:s/a/A/` then `:&&` then `&` (E486),
  `:set ts=8 nu? noai invnu`, `:d a 3` and `"ap`, Ctrl+A on `x = -7`,
  `%` from before a bracket, `#` (wrapping, "search hit TOP"), an /.exrc
  with a blank line and CRLF endings.  `vim` on a basic computer is plain
  vi.  Over in-game telnet, vi works (Ctrl+C leaves insert mode, arrows
  move; Esc closes the screen: asked for, in ccnix-mod 0.26.0), and
  Ctrl+C stops a ping on the far side, telnet staying.

- 2026-11-12 — ROM 0.43.0: `ccnix update` (the boot message about
  another ROM gone after the reboot); `git pull /ccnix --only lib/`;
  `curl --bogus` and `git pull --bogus` refused; a Lua page using
  `text.trim` and `fileio.read` with a query (`<p>[bob] 111</p>`); `wc`
  and `sort` on a 10225-line file; `$HOSTNAME` with the label cleared
  (the ID); a 600-character paste in irc sent as two messages split at a
  space; `help ccsh` on a pocket computer; `host example.com` through the
  gateway.

- 2026-11-12 — ROM 0.43.0: `grep -r` (apis/<file> names in order, `-rl`
  from inside without `./`, `-rc` on a folder; a folder without -r: "Is
  a directory").  `strings -n x` and `xargs -s 0` ("bad ..."), `mkdir`,
  `rmdir`, `tee` errors without a path in front; `od -j 0x10 -N 8`; vi
  `:r` of an empty file adds nothing.  irc: `/mode #ccnix +ov Lab-A
  Lab-A` (shown on both), `/ignore *!*@<address>` hides that host's lines
  (a client on the ircd's own computer comes from 127.0.0.1), `/whois`
  idle "1m 12s".  `ip host laba 10.1.1.10`, `ping -c1 laba`, `ip addr`.

- 2026-11-12 — ROM 0.42.3, the smoke test's second round on Lab-B: `ip
  route`, `netstat -r`, `tcpdump -c 4 net 10.0.0.0/8 &` with a ping (4
  packets, then Done), `curl` of httpd's listing (a file named `!` linked
  as `%21`), `ps -l`, `export -p`, `$HOSTNAME`, `telnet` to Lab-A (its
  password prompt), `git log /ccnix -n 3` (dates), `df`, `cat
  /rom/apis/*.lua | grep -c local`, `find / | wc -l` (no "Too long
  without yielding"), `printf "%5.2f|\n" 3.14159`.  Asked for: `grep -r`
  (0.43.0).

- 2026-11-12 — ROM 0.42.3, the text libraries' smoke test on Lab-B:
  `ls *.lua`, `ls [[:upper:]]*`, `find . -name "[[:digit:]]*"`, `case b
  in [a"-"c])` (no), `test` on 20-digit numbers, `expr +5 + 1` (6),
  `printf "%d %x\n" 0x1f 255`, `printf "%x %o %#08X\n" -1 8 255`, `seq -s
  "\t" 3 | od -c`, `tr -d "[:punct:]"`, `cut -d: -f1`, `sort -n`, `head -n
  x` (bad -n x), `sleep +1`, a `for` loop into `wc -l`, `diff -b` (leading
  blanks still differ, as GNU's), `od -d`: all as expected.  `touch -d
  <date>` parses it (CraftOS can't set a file's time, as touch's help
  says); grep has no -r (nor has POSIX's).

- 2026-11-12 — ROM 0.42.3: `/mc tell nobody hi`: "Can't: nobody isn't in
  the game"; a tell with the player's name in another case still told
  them.  irc on an advanced monitor (`monitor scale <side> 0.5`, then
  `monitor <side> irc`): the buffer list and nick list need 5 blocks
  wide (4 is under 80 columns); a tap on a buffer switches to it, a tap on
  a nick puts it in the line; typing goes through the computer.  irc on a
  pocket computer: readable, no time column, Alt+digits switch buffers.

- 2026-11-12 — ROM 0.42.2, the Minecraft bridge on AP 0.8.2a: the game's
  chat comes into #minecraft as `<player> text` (é as itself, in CC's
  small font); #minecraft reaches the game as "[Lab-A] hi"; `/mc tell
  <player> hi` arrives in the game; `/ns verify`'s code is whispered in
  the game, `/ns confirm` takes it, `/whois` says "is the Minecraft player
  <player>"; leaving and joining the game show in #minecraft (with a
  chunk loader keeping Lab-A loaded).  Not right: `/mc tell nobody`
  said "Told nobody." (fixed in 0.42.3).

- 2026-11-12 — ROM 0.42.1: hello.lua's "!ping" answer now shows on the
  sender's own screen too.  The Minecraft bridge on AP 0.8.2a: a Chat Box,
  Player Detector and Environment Detector beside Lab-A, `service restart
  ircd`: its log names all three.  #minecraft from Lab-A reaches the game
  as "[Lab-A] hello".  `/mc players`, `/mc time`, `/mc weather` answer.
  Not right (fixed in 0.42.2): the game's chat came in as `<uuid>
  player`, with the text lost; `/mc tell` and `/ns verify` said sent but
  nothing arrived.

- 2026-11-12 — ROM 0.42.0: `sysctl ircd.oper=...`, `service restart
  ircd`, `/quote OPER x <password>`: "You are now an IRC operator", +o,
  and /kill works.  `help irc-scripts`' hello.lua in /.irc/scripts:
  `/script load hello`, `/hello Lab-A`, `/set hello_word hey`, and
  Lab-A's "!ping" answered "Lab-A: pong" (seen by Lab-A; not shown on the
  sender's own screen: known issues).  A click on a window's label in
  screen's status bar switches to it.  `ps aux` lists as `ps -l`.

- 2026-11-12 — IRC on ROM 0.41.2 (ircd on Lab-A, irc on Lab-B and in
  screen on Lab-A): `/ns register`, back without identifying: Guest1
  after 60 s; back again with `/ns identify`: kept.  `/topic`, `/cs
  register #ccnix`, `/part`, `/join`: the topic kept, ChanServ opped the
  founder.  `/script load slap`, `/slap`.  `service stop ircd`: "Closing
  link ... (Server shutting down)", "Connecting again in 30 seconds",
  `service start ircd`: back in #ccnix.  A screen session started over
  telnet taken up on Lab-A's console with `screen -r`.  OPER refused:
  the password was set as irc.oper, not ircd.oper.  Asked for then: a
  click on screen's status bar to switch, `ps aux` (0.42.0).

- 2026-11-11 — ROM 0.41.2: irc's Tab offers the others before your own
  nick; Ctrl+C b shows a reversed B in the line, bold white in the chat.
  `screen` over telnet (Lab-B into Lab-A): `screen -S work`, a ping in
  window 0, Ctrl+A c and `irc localhost` in 1, Ctrl+A 0/1, the status bar
  (`0-ping 1*irc`), Ctrl+A A to rename, Ctrl+A [ scrollback (q leaves),
  Ctrl+C stopping the ping and not screen, Ctrl+A d ("[detached from
  work]"), `screen -ls` (2 windows, detached), `screen -r`; telnet closed
  with Ctrl+] q, in again, `screen -r`: as it was; Ctrl+A k then y.

- 2026-11-11 — IRC on ROM 0.41.1: `/rom/ccnix/deploy/setup ircd` on Lab-A
  (setup isn't on the path: `ccnix setup` or its full path), reboot:
  ircd running, "listening on port 6667; the game: the clock only".
  `irc 10.1.1.10` from Lab-B: the banner, the welcome and MOTD, `/join
  #ccnix` as @; `irc localhost` on Lab-A's console joined too (seen by
  Lab-B); messages both ways; Lab-B's nick in Lab-A's line hilighted
  (yellow behind the nick); the wheel, PgUp/PgDn, Alt+number, Tab on a
  nick; `/quit` seen by the other as a quit with its message.  Seen then:
  Tab offered your own nick first; Ctrl+C b showed as the font's smiley
  and bold didn't show in the chat (0.41.2).

- 2026-11-11 — CraftOS's startup after ccnix on a plain (basic) Computer
  under init (ROM 0.41.1, `init.boot`, `ccsh.login`, `motd.enable` on):
  the tip of the day, then `/startup.lua`'s and `/startup/a`'s output
  (their errors: they were written from CraftOS's shell, whose quoting
  knows only `"`), above the ccsh prompt and kept; `ps` (init, ccsh) and
  Shift+Page Up's scrollback.

- 2026-11-11 — ROM 0.41.1: PrintScreen in init's scrollback leaves it
  where it is; claude's ping through run_program ran as `ping -c 4` and
  ended; a turtle's modem taken off and put back (`turtle.equipLeft()`
  twice) and `ping` worked with no `ip up`.

- 2026-11-11 — claude on ROM 0.41.0: "×" shown as itself, a web search
  after it in the same session with no error, its code steps shown as
  `--- code execution`; the network set up through run_program `ip`
  (addr del/add, boot) and checked with ping (which ran until stopped:
  -c 4 added since 0.41.1).

- 2026-11-11 — claude on ROM 0.40.3 (a turtle with a wireless modem and a
  chunk controller): `claude fetch https://example.com and tell me its
  title` (CC's http, "Example Domain"); httpc to Lab-B's httpd at
  10.1.2.10 over the CC network; its status (equipped, attached, the
  network's address); `mine 3 3 5 --here` through run_program after the
  person gave it chests (it swapped the modem for the pickaxe and back),
  `where are you` agreeing; memory (notes in /claude/memories/notes.md,
  looked at first); a web search for the mining turtle's recipe; ores
  around it by name, sorted (Geo Scanner); notes written under /claude/,
  claude.key unreadable every way it tried.  Seen then: it couldn't set
  the network up (no settings; ip through run_program since 0.41.0); "×"
  shown as "Ã" and a block, and once an "Invalid signature in thinking
  block" error after a web search (UTF-8 sent back wrong, fixed in
  0.41.0).

- 2026-11-11 — The network on ROM 0.40.3 (Lab-B): `ip host gone <addr>`,
  `ping gone`, `ip host del gone` (gone from the list, "Name or service
  not known"), and again: "no host gone", status 1.  `ip neigh add` of the
  router's address: `permanent`, no who-has from Lab-B for it while
  pinging past it (the router's own who-has for Lab-B seen), kept over `ip
  down`/`ip up` and a reboot.  `ip dns cache` listing an NXDOMAIN, `ip dns
  flush`, then `host -v` "Received from".  `ping -c 0 -q` quiet until
  Ctrl+C, then the summary (-c 0 is no limit, as in BSD's ping); Ctrl+T on
  a `ping &` brought back with `fg`; `nc -w 3` to a host that's down gives
  up after 3 s.

- 2026-11-11 — ccsh on ROM 0.40.3: Ctrl+C stops `ping` and `tail -f`, and
  at a `>` prompt drops the command; `paint` keeps Ctrl+C; `kill -0 $$`
  gives 0; `(echo $$)`, `echo $$ &` and `echo $$` the same pid; `&>` then
  `&>>` into a file; `${U:=x}`, `${PS1:+set}`, `${NOPE:?gone}` (the message,
  the rest of the line skipped, `$?` 1); a two-row PS1 whole after a
  background `ping`'s output, with what was typed kept; `unset PS1` back
  to the default.

- 2026-11-11 — ROM 0.40.3: a #! typed into a new file colours it as ccsh
  at once, the `)` of a `$(` light blue, `1` after `x=` magenta.  The ccsh
  line editor: Ctrl+B/F, Home/End and the arrows, Alt+B/F/D and
  Alt+Backspace (the game sends Alt), Ctrl+K, Ctrl+D, Ctrl+P/N; Ctrl+R
  and again for an older match, Ctrl+G or an arrow to leave; the grey
  completion on a colour computer; a long line scrolling sideways on a
  turtle; a two-row PS1 (`\h\n\$ `) whole after Ctrl+L.

- 2026-11-11 — vi and vim on ROM 0.40.2: on a pocket computer and a
  turtle `-- INSERT --` and `-- REPLACE --` whole beside the ruler, and the
  Ctrl+C hint fits; `vim` on lib/vi.lua (2,041 lines) coloured and not
  slow, `G` and the wheel; `:set hls` and `/x` with search wrapping;
  `:2,3d`, `u`, `:g!/keep/d`, `:%s#a#X#g`; Ctrl+A on X1, `~`, `*`. Esc
  closes the computer's screen, as CC does: Ctrl+C or Ctrl+[ leave insert
  mode. Seen then, fixed in 0.40.3: a #! typed into a new file with no
  extension coloured as Lua until it was saved and opened again.

- 2026-11-11 — vi on ROM 0.40.1: Ctrl+A on a number, `yyp`, `dd`, `p`,
  `.` repeating Ctrl+A, `:%s/x/y/g` ("2 substitutions on 2 lines"), the
  mouse wheel, a click moving the cursor, Ctrl+V pasting; Ctrl+C on a `:`
  line drops it, and on a saved file says "Type :q and Enter to exit".
  Seen then, fixed in 0.40.2: on a pocket computer `-- INSERT --` cut to
  `-- INSERT`, the `i` that started insert mode still shown.

- 2026-11-11 — The mod on 0.25.1: walking with the gateway dialog open
  (W/A/S/D with no box focused), closing it by walking off, typing in a
  box doesn't move, a click off the box walks again; the keys as ever
  after it closes; no ccnix clash in Controls (the red ones there are
  another mod's rail keys).

- 2026-11-11 — The mod on 0.25.0, ROM 0.40.1: the mod list's author "Dan
  Theisen [WI7FI]"; the cable network dialog on a short network (2 cables,
  2 modems, the computers beside them with their labels, the empty
  "Shared on it" note) and on the 198-cable run (the amber unloaded chunk,
  the tooltips); typing W in the gateway dialog's boxes.  Under ccsh,
  `textutils.pagedTabulate({"a"}, {"b"})` in `lua` with no error, and
  CraftOS's `help index`.  Walking with a dialog open didn't (0.25.1).

- 2026-11-11 — The mod on 0.23.0, ROM 0.40.0: the mod list's description
  (NAT and TUN) and credits (the inspirations); the gateway dialog laid
  out right (the label column, Gateway, Mode, Untagged, Exchange, Standing
  by), its tooltips, the native VLAN saved ("Saved"), the cursor left
  where it was in a box across refreshes; the configurator on a cable
  listing 198 cables and the unloaded chunk it ran into (in chat then: a
  dialog since 0.25.0); `help git` in the pager with its trademark note,
  and after q its command line still in the scrollback; `help index` in columns, `help gi<Tab>` completing.

- 2026-11-11 — The mod, on 0.22.2: the mod list's Credits (CC: Tweaked,
  Daniel Ratcliffe, NeoForge, etlua); the Network Tester's recipe (iron,
  glass pane, iron / iron, redstone, iron / cable); empty-handed on a
  gateway the action bar asks for the tester; with it, the dialog: green
  Working on the working block, amber Standing by on the spare, frame
  counts climbing with their rates while `ping` ran, the MACs heard on
  the pointer; what's typed in the VLANs box kept across refreshes.  Seen
  then, fixed in 0.23.0: a label running into its value, values cut
  short, the refresh moving the box's cursor.  `help git` and `help
  tcpdump` shown; the prompt that ran `help git` was missing from the
  scrollback (CraftOS's help viewer draws over the screen): ccnix 0.40.0.

- 2026-11-11 — Fileserver on ROM 0.39.0 (FS, 4 disks pooled at `/jbod`):
  Tab completion of `/jbod`, its files and `..` in ccsh and in CraftOS's
  own shell; each pooled disk labelled `FS drive_N`.

- 2026-11-11 — `/ccnix rom update` asks before the reload (ccnix-mod
  0.22.2): it pulled, offered [Load it], and loading brought the server's
  ROM to 0.39.0.
- 2026-11-11 — A disk's startup in place of the computer's (ROM 0.39.0,
  Lab-B, `shell.allow_disk_startup` on): "from the disk" alone, the
  computer's `/startup.lua` skipped, under init with ccsh and under
  stock CraftOS alike.  The first try looked like a failure: a plain
  `/disk` folder on the computer (left by the `>` bug before 0.33.0) had
  pushed the floppy's mount to `/disk2`, so the file was never on it.

- 2026-11-11 — CraftOS's startup after ccnix, under init (ROM 0.39.0,
  Lab-B, `init.boot` and `ccsh.login` on), test 5's third try: `/startup.lua`
  then `startup/a` and `startup/b` printed above the ccsh prompt and stayed
  there (0.30.0 had drawn them over blank); with `motd.enable` on, the
  tip of the day before them.  `/ccnix rom update` and [Load it] brought
  the server's ROM to 0.39.0 (mod 0.22.2 on the client and the server).

- 2026-11-06 — Background output while typing (0.30.0, by `ccnix update`
  on Lab-A): `ping -c 5 10.0.0.1 &`, then commands typed while replies
  came: each reply took the prompt's place, the prompt and the typed line
  came back below, nothing jumbled; the job's Done reported before the
  next prompt.
- 2026-11-06 — Network diagnostics on Lab-A (ROM 0.29.1): `ping` running
  until Ctrl+T then its summary with rtt min/avg/max/mdev, `-c 3 -q`, `-w
  2` stopping on time, `-s 1000` through R and the TUN gateway
  (bytes=1000); `ip route get` through the router (via, dev, src, the
  router's MAC and seconds left) and for its own address (local, dev lo);
  `ip neigh` showing an unanswered address as INCOMPLETE, 1 queued, asked
  2 times; `netstat -s` grouped by protocol; `host -v` twice (from
  4.2.2.1#53, then from the cache with the TTL counting down), `ip dns
  cache` and `ip dns flush`; `nc -z -v` refused, open and timed out.
- 2026-11-06 — Backspace at the start of the line and on an empty one
  (0.29.2, by `ccnix update`): no more doubled or jumbled lines.
- 2026-11-06 — Services under init (ROM 0.29.1): a crashing service
  (`error('boom')`) shown as failed with its error, status 1 and a
  traceback in `service status` and `/var/log/messages`, restarting with a
  doubling wait (16 s, 32 s); `kill -9` of telnetd: its port 23 freed and
  bound again by the new process, the open session from Lab-B closed. It
  found the Backspace bug fixed in 0.29.2.
- 2026-11-06 — ccsh on the dev server (ROM 0.29.1, under init): the line
  editor's Ctrl+A/E, Ctrl+W, Ctrl+U then Ctrl+Y; Ctrl+R finding an old
  command; Tab completing a file name; Ctrl+L; Ctrl+C at the prompt (^C,
  `$?` 130), on `sleep 30` (stopped, 130) and left to `lua` (still open);
  Ctrl+D leaving a nested ccsh; `$$` and `$PPID` matching `ps -l` (4 and
  1); `cat nope &> /tmp/e` filing the error with no job started;
  `${U:-$X}`; `unset -f`.
- 2026-11-06 — On the dev server with ROM 0.29.1: `vi` (i, Ctrl+[, `yyp`,
  `u` and a tapped Ctrl+R, Ctrl+C leaving insert mode and in normal mode
  giving the ":wq / :q!" hint without quitting, `:wq`); `vim` on
  bin/ls.lua with Lua colours (keywords, strings, comments, numbers,
  library names, fields plain), `:set nu`, `/local` and `n`; `nano` opening
  CraftOS's edit, and Ctrl+C in it leaving edit open with the text kept.
- 2026-11-06 — `mine where` (0.23.0): last home, next home and the reset
  line shown, while mine ran as a service.
- 2026-11-06 — mine as a service under init (0.21.0): started at boot,
  logged to `/var/log/messages`, `service stop` / `service start` resumed it.
- 2026-11-06 — Going back over just where water was (0.21.5): fixed a leak
  through the far wall on a long walk out.
- 2026-11-06 — Lava pouring in from above sealed round while digging.
