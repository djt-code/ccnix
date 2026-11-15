# ADR-0010: Mechs: a computer drives a glued body, and turtles are its arms

**Status:** Proposed (2026-11-15): decisions D1 to D9 below are the user's
to make
**Date:** 2026-11-15
**Deciders:** Dan Theisen

## Context

The user super-glued a block onto a turtle and asked it to move up:
"Movement obstructed". Turtles never carry other blocks. Create moves
glued blocks only as one of its contraptions, and a computer in a
contraption restarts when the contraption stops. The user asked
(2026-11-15) how a claude robot could build itself a mech and then move
around in it: one block drives, and further glued turtles become extra
slots and hardpoints (to interact with the world and act on it) that the
driver can use. They asked whether fluids can be glued too. And they
proposed making the driving block an advanced computer.

What the code says (CC: Tweaked 1.120.2, Create 6.0.10, and the dev
server's pack):

- **A moving turtle keeps running.** `TurtleBrain.teleportTo` places a new
  turtle block, copies the old one into it
  (`AbstractComputerBlockEntity.transferStateFrom`, which hands over the
  running computer's instance and clears it from the old block so its
  removal doesn't shut it down), and then removes the old block.
  `transferStateFrom` belongs to every computer's block entity, so plain
  and advanced computers can be moved the same way. CC itself never
  does that, but nothing stops a mod from doing it.
- **Create's contraptions restart computers.** A contraption keeps its
  blocks as saved data while it moves and places them again when it
  stops. A computer comes back as a new block entity with no running
  instance, so it boots again ("On" is saved, the session isn't). A
  program driving the contraption from inside it can't survive its own
  move.
- **Create's glue** is an entity with a box (`SuperGlueEntity`).
  `SuperGlueEntity.isGlued(level, pos, direction, cache)` says whether two
  neighbours are stuck together. Contraptions move the glue entities with
  their blocks.
- **Fluids aren't glued, in Create.** A block needs moving only if it has
  a collision shape (`BlockMovementChecksImpl.isMovementNecessaryFallback`).
  Water and lava have none, so a contraption leaves them where they are.
  A waterlogged block leaves a water source behind when it's lifted and
  takes up whatever water it lands in. Fluid in a tank's block entity
  goes along with the tank.
- **The pack has Create Aeronautics, Sable and CC: Sable.** Sable turns a
  structure into a sub-level: real blocks in their own grid ("plot"),
  moved by physics. Blocks there keep ticking, so a computer on an
  Aeronautics ship keeps running.
  - **Sable's compatibility code.** It lets Create's drills, saws,
    harvesters, deployers and arms on a ship act on the world. For CC it
    patches only the wireless network (range between a ship and the
    world).
  - **What a computer gets from CC: Sable.** It can read its ship (pose,
    velocity, mass, centre of mass) through the `sublevel` API, and the
    air through `aero`. It can't move the ship.
  - **What can move a ship.** Create: Propulsion makes its thrusters,
    vector thrusters and tilt adapters CC peripherals.
  - **Untested:** a turtle on a ship most likely digs and places into
    the ship's plot, not the world.
- **What ccnix has to build on:**
  - claude drives a turtle (turtle/claude.lua).
  - turtlelib's map, paths, protected areas and blueprints (ADR-0008)
    work on the block grid.
  - ccnix's network runs over wired modems.
  - A full-block wired modem touching a turtle makes it a peripheral
    (`turtle_N`) that a chest's `pushItems` can name. So a chest on the
    same network can push items straight into an arm (ADR-0008's context).

Forces: keep it simple (one mechanism per job, tight defaults);
everything a program does returns a reason; claude must be able to use
it from what its prompt says; both repos move in lockstep.

## Decision (proposed)

1. A **Mech Drive** block in ccnix-mod moves the glued body it's part of
   one block at a time on the grid, with every block in it, computers and
   turtles included, still running (D1).
2. The **pilot** is a computer (an advanced one, as the user proposed)
   glued into the body beside the drive. The drive is its peripheral,
   `mech` (D2).
3. **The body** is what Create's super glue holds to the drive (D3).
4. **Arms** are turtles glued into the body, each touching a full-block
   wired modem on the body's network. Each runs `armd`, which carries out
   the pilot's commands, and each stays where it was glued (D6).
5. **Fluids** ride only in tanks and in waterlogged blocks. Loose water or
   lava is never part of the body (D7).
6. **Aeronautics ships** are a separate path for flying, with no mod code.
   It's tried in game first (Phase 0), and only built on if a turtle on a
   ship reaches the world (D9).

## Options considered

### D1. What moves the body

| | A: Create contraptions | B: Aeronautics ships (Sable) | C: a Mech Drive in ccnix-mod |
|---|---|---|---|
| Computers keep running | no: rebooted when it stops | yes | yes (CC's own handover, as turtles move) |
| How it moves | pistons, gantries, bearings, rotated by Create | physics: thrusters, gravity, momentum, any angle | one block at a time on the grid, like a turtle |
| Turtles on it reach the world | yes, once it stops | probably not (the ship's own grid; untested) | yes: it's never anywhere but the world |
| Fits claude and turtlelib | no | poorly: a pose and velocities, not cells | yes: the map, paths and blueprints are cells |
| New code | none, but nothing drives it from inside | Lua only: a pilot library over thrusters and `sublevel` | Java: a block, a peripheral, the mover; Lua: lib/mech, armd |
| Needs | Create | Create, Aeronautics, Sable, Propulsion, CC: Sable | Create (for the glue; D3) |
| Verification | — | in game only | a GameTest if the mod gets them, sims for the Lua, in game |

**C**, with B kept as a cheap experiment. A can't run its own driver. B
already exists and flies, but its turtles probably can't touch the
world, and claude thinks in cells. C keeps every block real and on the
grid, so an arm digs what's in front of it and the map stays true.

### D2. The pilot: an advanced computer or a turtle

An **advanced computer** (recommended; the user's idea). It never moves by
itself, so nothing it does can tear it out of the body. It has no fuel or
tool slots to compete with the drive and the arms, and its colour screen
can show a monitor of the mech. A turtle pilot would have its own moves
disabled anyway (they'd leave the body), and it would be one fewer arm.
The drive moves the pilot the same way it moves turtles. claude then runs
on a computer for the first time (Phase 3): its tools become the drive and
the arms, not `turtle.*`.

### D3. What the body is

- **A: Create's super glue** (recommended). Starting from the drive, the
  body is every block reached across glued faces (`isGlued`). The drive
  moves the glue entities too. It's what the user already does, and it's
  visible in game. Create becomes an optional dependency of ccnix-mod
  (compile only; no Create, no mechs, and the drive says so).
- **B: ccnix's own frame block or glue.** No dependency, but it's a second
  glue in a pack that has one.
- **C: everything touching the drive.** No glue at all, but a mech parked
  against a hill would try to take the hill with it.

### D4. Moves

**Translation first** (recommended): `mech.move("up"|"down"|"north"|...)`
moves the whole body one block, or returns false and a reason ("blocked
by minecraft:stone at 120,64,-30", "too heavy: 140 blocks, the limit is
128", "out of fuel"). It's like a turtle's move, but with absolute
directions, because a body has no front until it can turn.

The move happens in two phases within one tick, as a Create contraption
assembles and disassembles:

1. Every target cell outside the body must be empty or replaceable (air,
   grass, a fluid).
2. Lift: save every block and block entity, and hand each computer over
   (CC's `transferStateFrom`, as `teleportTo` does).
3. Place: set the blocks again one cell over, with no drops and no
   neighbour updates until all of them are down.

Blocks that can't move are refused before anything is touched:

- unbreakable blocks;
- the `c:relocation_not_supported` tag;
- Create's own non-movable tag.

Entities standing on the body, and those inside it, move along with it.

Yaw turns (90° about the drive) come later, as their own decision: block
states rotate with `BlockState.rotate`, but some modded block entities
keep their facing in their saved data.

### D5. Cost and limits

- **Fuel.** It follows CC's own `need_fuel` setting: off, and the mech is
  free. On, and a move costs 1 + blocks / 8 (a 32-block mech pays 5 per
  move; a turtle pays 1). The drive has its own fuel level and
  `mech.refuel()` burns items from a chest in the body, as a turtle
  does.
- **Size.** At most 128 blocks.
- **Speed.** One move per 8 ticks, a turtle's pace.
- All three are settings in `config/ccnix-server.toml`.
- **Chunk loading.** While the pilot is on, the drive keeps the chunks
  under the body loaded (a ticket per chunk, at most 4 chunks), so a mech
  doesn't stop half-loaded at a chunk border. A move into an unloaded or
  out-of-border cell is refused.

### D6. Arms and slots

- **How the pilot reaches an arm.** Each arm turtle touches a full-block
  wired modem in the body. The body's cables make one network, and ccnix's
  stack runs on it.
- **armd** is a service on each arm. It takes Lua from the pilot, runs it
  with turtlelib, and sends back what came of it, as claude's own Lua
  tool does today. lib/mech on the pilot wraps that: `arm("left").dig()`,
  `arm(2).run(code)`.
- **No moving.** An arm never moves itself: armd refuses turtle moves.
  turtlelib's protected areas cover the body's cells, so no arm digs its
  own mech.
- **Positions.** After each move the pilot tells every arm the offset, so
  their positions stay true.
- **Slots.** Chests and barrels on the body's network are the hold. The
  pilot moves items between them with `pushItems`/`pullItems`, and
  straight into an arm too (a turtle is `turtle_N` to the wired modem
  touching it). So an arm's 16 slots are refilled from the hold without
  the arm moving. Each arm also adds its own 16 slots and its two upgrade
  sides (pickaxe, chat box, scanner...): a mech with four arms has four
  tools and 64 more slots.

### D7. Fluids

Can fluids be glued? Not in Create, and not here (recommended). A loose
source block moved along would spill a flow behind it at every step, and
lava would burn the mech. Instead:

- **tanks** carry their fluid in their block entity, so it moves with
  them (Create's fluid tank, or any modded tank);
- **a waterlogged block** keeps its water as it moves and leaves none
  behind (unlike Create, which leaves a source behind). It works like a
  bucket.

### D8. Who may drive

Anyone who can use the pilot computer, as with any computer. The drive
has no owner (unlike the gateway's VLAN screen, which wants its owner or
an op). If the server wants mechs off, a setting turns the drive off.

### D9. Aeronautics ships

**Experiment first, build later.** Phase 0 tries a ship in game: a
computer on it, a Propulsion thruster driven from it, and a turtle on it
digging.

- **If the turtle digs the world:** a `lib/aero` pilot library and claude
  tools for flying could follow, with no mod code.
- **If it digs the ship's own plot:** ships stay for travel, the arms
  don't work there, and the grid mech is the one that works the world.

Teaching CC turtles on Sable ships to reach the world is Sable's or
CC: Sable's business, and out of scope here.

## Trade-off analysis

- **Most of the risk is in C's mover:** moving any block entity by its
  saved data, as Create does, works for most blocks, and Create's years of
  special cases show where it doesn't. So the mover:
  - refuses what's tagged as unmovable;
  - starts small (a refusal list in the server's config);
  - lists the blocks it carried in `mech.blocks()`, so a surprise shows.
- **Cells, not physics.** It hovers like a turtle: no gravity, no
  momentum. That's the point (claude plans in cells), but it means a
  mech never looks like it walks. Legs would be animation, and they're
  out of scope.
- **Declined:**
  - rotation in the first version;
  - gravity;
  - a ccnix glue (D3 B);
  - teaching Sable ships to let turtles reach the world.

## Consequences

**Easier:**
- A claude can build and drive something bigger than a turtle: arms with
  four tools, a hold of many chests, a chunk loader of its own.
- The building library (ADR-0008) carries over: the body is a shape on
  the map, and paths need room for it.

**Harder:**
- ccnix-mod gains its first dependency on another content mod (Create,
  optional), and a block that moves other mods' blocks. Each new Create
  release is a reason to retest the mover.
- claude's prompt grows a mech section, and its sandbox must not reach
  `turtle` on a computer.

**Revisit:**
- yaw turns (D4);
- an Aeronautics pilot (D9);
- whether the 128-block and 4-chunk limits are right once someone has
  built a real mech.

## Action items

### Phase 0: in game, before any code (the user)

1. An Aeronautics ship with an advanced computer and a turtle on it:
   - does the computer keep running through a flight?
   - what does `sublevel.getLogicalPose()` give?
   - does the turtle's `dig()` reach a world block next to the ship?
2. A Propulsion thruster on the ship, driven from the computer
   (`peripheral.getMethods`).
3. Two turtles touching one full-block wired modem, and a chest on it:
   does `chest.pushItems("turtle_N", 1)` fill the turtle?

### Phase 1: ccnix (pull request first; lockstep)

1. `lib/mech`: the pilot's side. It wraps the drive and the arms, and
   returns a reason on every failure. Sims run it against a mock drive and
   mock arms: moves, refusals, offsets sent to the arms, the hold.
2. `bin/armd`: the arm service (an init service; `setup armd`).
3. `help mech`, `help armd`, and UNTESTED.md entries.
4. `deploy/version`: minor.

### Phase 2: ccnix-mod

1. Create as a compile-only optional dependency.
2. The Mech Drive block and item:
   - the `mech` peripheral: `move`, `blocks`, `fuel`, `refuel`, `limits`;
   - the glue walk (D3 A);
   - the two-phase mover, with CC's computer handover;
   - entities moved along;
   - chunk tickets;
   - settings in `ccnix-server.toml`;
   - JEI info, the creative tab, the README.
3. `mod_version`: minor. `ccnix/` is pointed at Phase 1's release tag
   (labelled `lockstep`).

### Phase 3: claude as a pilot

1. claude runs on an advanced computer. On a computer, its tools are
   `mech` and the arms. Its prompt says what each one does and what each
   costs.
2. tl.path learns a body's shape: a route keeps the whole body clear, not
   one cell.

### Phase 4

1. Mark this ADR Accepted with the answers.
2. Yaw turns (D4) and an Aeronautics pilot (D9), each as its own ADR if
   it's wanted.
