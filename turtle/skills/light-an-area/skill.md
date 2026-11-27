---
name: light-an-area
description: Light a place so mobs can't spawn, without lights in the player's way: T.darkCells per dimension, what-if lights, flush placement, recheck.
---
# Lighting an area

Use when the player asks that nothing spawns in a place (a base, walls, a room, a path), or when
you change lights (remove torches, swap a fire for a campfire, put furniture over a floor light).

## Facts
- `T.darkCells(box, opts)` floods block light over the map and lists the cells where a mob could
  spawn: feet cell with room (it and the cell over it) above a full, sturdy floor, at or under
  the dimension's limit. Sky light isn't modelled: the result is a roofed place, or any place
  at night.
- The dimension is `T.dimension()`'s (the setting `turtle.dimension`, else the blocks round the
  turtle), which `T.darkCells` and `T.planLights` use on their own; `opts.dimension` overrides it.
  If it says it isn't sure (`info.sure` false), ask the player.
  - Overworld and End: block light 0 spawns, so any light at all makes a cell safe.
  - Nether: 7 or less for skeletons, wither skeletons, endermen; 11 or less for zombified
    piglins, piglins, hoglins, blazes (`info.groups`). Ghasts and magma cubes spawn whatever
    the light: `info.anyLight` lists those cells; only a slab or glass floor, or no room, stops
    them.
- Light levels: torch, end rod 14; lantern, glowstone, shroomlight, sea lantern 15; soul torch,
  soul lantern, soul campfire 10; redstone torch 7. Light drops by 1 a step.
- Mods in a pack can change spawning: the model is a guide, the game decides.

## Steps
1. Box: the area's air and floor cells, at most 65536 cells; several boxes for a big place.
2. Make the map know it: `T.scanBox(box)` (names only). Then `T.darkCells(box)`. Read `info.summary`; `info.unseen` > 0: scan more; `info.unsure` lists cells over a
   slab or stair whose half the map lacks: `T.inspectAll` those (a top one is a floor).
3. Plan where lights go, the player's way first:
   - flush: glowstone, shroomlight or a sea lantern set into the floor or ceiling (swap a block
     with `T.replace(box, pattern, item)` or `T.digCell` then `T.placeAt`);
   - on top of a wall, merlon, fence or post (a torch stands there; `T.placeAt(x, y, z,
     "minecraft:torch")` from above);
   - a lantern standing on a post, or hanging above head height (not in the cell over a walk
     cell's head);
   - not a wall torch sticking into a walkway (T.lint's "light" rule) or a lantern at head
     height ("lantern" rule).
4. Try them before placing: `T.darkCells(box, { with = { { x, y, z, "minecraft:glowstone" },
   ... } })`; `{ x, y, z, "air" }` takes a light away. Fewest lights
   that bring `info.dark` to 0 (Nether: decide with the player which group you light for).
5. Place, then `T.darkCells` again from the map, and `T.lint(box)` for lights in the way.
6. Keep a list of the lights you placed in a file under /claude/ so a later change can be
   checked against it.

## Pitfalls from the field
- Lighting for the count only: wall torches everywhere lit the place and the player found them
  ugly and in the way. Balance looks and light; ask how they want it to look.
- A floor light under furniture or a carpet goes dark above: keep those cells clear, and
  recheck after anything is placed over a light.
- `T.light` and `T.darkCells` count lights up to 14 cells outside the box; a light the map
  never saw doesn't count, so scan round the box too.
- Torches you placed on landings block your own routes (see build-for-player).
- Swapping a light for a weaker one (fire 15 to soul campfire 10) can open dark cells: recheck.

## Tell the player
Dark cells before and after (by group in the Nether), what you placed where, what the model
can't see (sky light, ghasts, mods), and ask them to say where mobs still appear.
