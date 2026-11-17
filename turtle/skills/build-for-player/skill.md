---
name: build-for-player
description: Build stairs, walkways, rooms or trim a two-tall player uses: a blueprint, T.lint before, T.build, then T.verify{player=true} and T.walkable.
---
# Building for a player

Use for anything a player walks on, climbs or reads: stairs, landings, balconies, wall walks,
rooms, railings, signs. The turtle is one block tall and the player two (1.8, steps up one
block), so a build the turtle gets round can still stop a player.

## Before
1. Say the design back to the player in one or two lines (where, size, materials) and wait for
   a yes when it changes something of theirs. Never "fix" their designs; ask first.
2. Site: `T.map.heights(box)`, `T.map.slice(y, box)`, `T.protections()`. `T.scan(8)` or
   `T.scanBox(box)` where the map is `?`. Stay out of the player's furnished spaces.
3. `T.setOrigin(...)` must be known: compass facings (stairs, doors, signs) need it.
4. Write a blueprint (text or table, see the plan format in the manual: search "anchor"):
   - a stair's `facing` is the way a player walks up it; 3 air above its walking line, 2 at
     the top step when the way off is level;
   - a free approach cell before the first stair and a floor plus 2 air past the last;
     a landing and a turn where a flight would meet a wall;
   - railings at every drop over 3; where two railings meet only on a diagonal, a corner
     piece; on 1:1 stairs railing posts two high so each meets its neighbour level;
   - a top slab under a stair is ordered for you; other dependencies take a legend hint:
     `t = oak_slab[type=top] after 0,1,0` (built after the cell one above);
   - lights flush or out of the way (see light-an-area), never a wall torch in a walk cell.
5. `T.lint(plan)`: act on the warnings with `where == "plan"` (`info.planSummary`); those
   `"around"` are terrain or other buildings: tell the player, don't fix them unasked.
   `info.unchecked` stairs lack states: `T.inspectAll` them.
6. `T.fuelFor{ build = plan, back = true }`; materials: `T.craftPlan`, then `T.prepare{ need = ... }`.

## Build
`T.build(plan, opts)`. Useful opts:
- `inside = "area"` (or a list) to work in a protected area; `protect = true` (or a name) when
  every cell went in;
- `order = "column"` for walls and anything tall: layer by layer circles the shape every layer
  (field: about 6 times the fuel);
- `temp = "minecraft:cobblestone"`: the block held above a top slab for a moment;
- `digBelow = true` only when the player agreed the floor may be dug and put back (a top slab
  on a floor; on solid ground it digs a neighbour too and refills both);
- `limit = n` for a big plan, then `T.build()` carries on; `partial = true` builds what it can.

A failed cell is in `info.failed` with its why: read the whole why (what to do is often at its
end) before cutting it. Finish one by hand with `T.placeAt(x, y, z, item, { facing, half,
text, toward, rotation, digBelow })`, which stands outside the cell; never place up from the
hole (the block lands a cell off). `T.build()` again takes it as done.

## After
1. `T.verify(plan, { player = true })`: an empty list and `info.warnings` read.
2. `T.walkable(entrance, eachPlaceTheyGo)`: a path, and `info.falls` empty.
3. A lint gap the map can't explain (it says air where you placed a block): `T.inspectAt` the
   cell, which notes it in the map, and lint again.
4. Protect it; go home; `T.stow()`.

## Signs
`T.signFor(readerCell, text, { look = "north" })` puts a sign in front of where the reader
stands, facing them; or `T.placeAt(x, y, z, "minecraft:oak_sign", { text = ..., toward =
readerCell })`. Text: 4 lines of 15 characters, `\n` starts a line. Put it where the reader
looks along their path, not off to one side.

## Pitfalls from the field
- `T.moveTo` goes y first and hits your own rails: near builds use `T.travel` or
  `T.moveTo(x, y, z, { path = true })`.
- Your own torches and ladders block your routes; the why says "a way exists through ... (lift
  it and put it back)": `T.digCell` it, pass, `T.placeAt` it back.
- A trapdoor placed up from below came out a bottom one: ask `T.placeAt` for `half = "top"`.
- Tidy beats maximal: match the materials already there; a top slab under each stair reads well.

## Tell the player
What you built and where (`T.toWorld` for their coordinates), the walk you tested (from, to),
what lint still warns about around it, and ask them to walk it.
