---
name: redstone-and-doors
description: Doors, buttons, levers, dust, repeaters, locks: restate the ask, T.attachedTo before any dig, place by state, inspect, and have the player test.
---
# Redstone and doors

Use for doors, gates, trapdoors, buttons, levers, pressure plates, dust, repeaters, comparators,
pistons, and any rework of machinery that already works.

## What a turtle can't do
It can't open doors or trapdoors, press buttons, set a repeater's delay or a comparator's mode,
or walk through a nether portal ("Movement obstructed"). Routes avoid doors, so a room behind a
door is reachable only another way. Every test of an input is the player's: plan for it.

## Steps
1. **Restate the ask** in chat before touching anything that works: each input (which side,
   which block), what it must do, and what must not work (a lock). "Outside button opens the
   door; lever inside disables both buttons; nothing else outside" and wait for a yes
   (`chat` with `ask = true`, or `T.report.ask`). A misread ask once cost a door four versions.
2. **Survey** a small box: `T.scan(5)` for names, then `T.inspectAll(cells)` for states
   (facing, face, half, hinge, powered). The map holds states only for inspected cells.
3. **Design on paper first**, in /claude/<job>.md: each signal path as a list of cells from
   source to target. Check that no path bypasses the lock, that dust doesn't also power a
   block you didn't mean, and that hidden wiring has blocks to run behind.
   - A repeater's or comparator's `facing` state is the side its signal comes in from; it
     outputs the opposite way. It needs a sturdy block under it.
   - Dust powers the block under it and the block it points into, and a powered block opens
     a door beside it: check every block your dust touches.
4. **Materials**: `T.canCraft` / `T.craft` know redstone torch, repeater, lever, stone button,
   iron door. A repeater needs stone (smelt cobblestone: `T.smelt`). Short of something the
   place lacks (no stone in the Nether), ask the player.
5. **Before any dig** in or near the machine: `T.attachedTo(x, y, z)` names the dust, torches,
   buttons, levers, ladders and doors that would drop (`sure = false`: inspect those cells).
   Dig with `T.digCell(x, y, z, { attached = "refuse" })`. Turn on `T.cfg.undo = true` and take
   `local mark = T.undoMark()` first: `T.undo(nil, { since = mark })` puts it back.
6. **Place by state** with `T.placeAt` (needs `T.setOrigin` for compass facings):
   - repeater, comparator: `{ facing = "north" }` (the input side, as above);
   - button, lever: `{ face = "wall" | "floor" | "ceiling", facing = ... }`;
   - door: after the walls round it, a solid block under it and the cell above free; its
     hinge comes from the blocks beside it, not from placeAt: inspect it after;
   - piston, observer, dispenser, dropper: `{ facing = "up" }` and the like (no origin needed
     for up and down);
   - dust: `T.placeAt(x, y, z, "minecraft:redstone")` lays it (the block is `redstone_wire`,
     taken as the redstone asked for; it needs a sturdy block under it). In a blueprint name
     the block, `minecraft:redstone_wire`: `T.build` carries and places redstone for it. Then
     `T.inspectAt(x, y, z)`: its connections come from its neighbours, not from placeAt.
   In a blueprint, name only the states the turtle sets: no `delay`, no dust connections, or
   `T.verify` lists them as differing.
7. **Check**: `T.inspectAll` every cell you placed and compare with the design (facing, face,
   hinge). A small `T.scan` round it catches a block one cell off.
8. **Ask the player to test**, with a list of what each input should do, including what must
   not happen. Note the design in your notes as untested until they say it works.

## Pitfalls from the field
- Dust fell when its support block was dug: always `T.attachedTo` first.
- An exit button placed where it powered the door directly bypassed the lock.
- A restore placed up from inside the hole landed a cell off, in the tunnel: put blocks back
  with `T.placeAt`, which stands outside the cell.
- "Only a lever and a button inside" was read as "take the outside button away": when an
  instruction reads two ways, ask which before you change anything.
- Modded machines may refuse what a turtle drops into them; ask the player to insert it.

## Tell the player
Before: the design in one line. After: where each input is, what it should do, and that you
couldn't test it yourself; ask them to try each and report.
