# ADR-0018: the turtle programs take their position from GPS

**Status:** Accepted (2026-11-19): every recommendation (the user: "all recommendations accepted");
D7 amended the same day (below)
**Date:** 2026-11-19
**Deciders:** Dan Theisen

## Context

The user's ask: the turtle programs (claude, mine, farm, mow and the rest)
use a GPS fix for their world position when GPS is available, and
otherwise fall back to dead reckoning and the position the player gave.

### How a turtle knows where it is today

- **Dead reckoning.** turtlelib wraps every move and turn. `T.pos` and
  `T.dir` are in the turtle's own frame: (0,0,0) where its job started,
  facing +z. They are saved to `.turtlepos` after every move, and `T.run`
  holds Ctrl+T back until the move is saved.
- **The world origin.** `T.setOrigin(x, y, z, facing)` ties that frame to
  the world. It is saved in `.map/frame`, relative to the map's frame, so
  it survives re-zeroing. It comes from the player (`mine --origin`, or
  claude asking), or from `T.setOrigin()` with no arguments: x, y, z from
  `gps.locate` and the facing from a geo scan (`tl/world.lua`, `gpsFix`
  and `compassFromScan`). Nothing calls it on its own.
- **When the position is wrong.** The turtle was carried, a move was
  lost, or `.turtlepos` is gone. The programs find out only when the saved
  position isn't home at a start (`T.requireHome`: "Turtle may not be at
  home ... `reset`, or --here"). They don't find out at all when the
  turtle was moved and the file still says home. A lost file re-zeroes
  the frame, and the map is marked unaligned until `T.alignMap`.

### The GPS facts it rests on (verified in ADR-0016 and in game)

- A turtle's fix is its block, exactly: a turtle modem's position is its
  block corner. In game, `gps locate` gave whole numbers, and
  `T.setOrigin()` gave the origin `T.toWorld(T.pos)` agreed with. A pocket
  computer's fix is the player's eyes instead (feet + 1.62), but no
  program runs on one.
- GPS gives no facing.
- GPS is per dimension. A wireless modem doesn't hear another dimension,
  and an ender modem's message from one has no distance. The turtle can't
  tell which dimension it is in. A turtle carried into the Nether, with
  hosts there, gets a fix in Nether coordinates.
- Hosts can be wrong together. Four Nether hosts typed in as x, z, y
  agreed with each other and gave every client a fix with y and z
  swapped.
- `gps.locate(2)` returns as soon as it has a fix, which is a tick or two
  with hosts in range. With none, it waits the full 2 s.

### What the shared code offers

- Every start goes through `T.startAtHome` (in `T.requireHome`). mine,
  farm and mow call those.
- `reset` and `home` go through `T.goHome`.
- claude takes the saved position at session start (`takeSavedPos`).
- autostart reads it to choose what to run.

## Decision

turtlelib checks the dead-reckoned position against a GPS fix at those
shared points (D1), and corrects what GPS shows wrong (D2 to D5).
Without GPS, everything is as today. The options and recommendations
follow; the user decides each.

## Options considered

### D1. When it asks GPS

- **a. At the shared points** (recommended):
  - a job's start (`T.startAtHome`, so mine, farm and mow);
  - `reset` and `home` (`T.goHome`);
  - claude's session start and each new goal;
  - autostart's look at the saved position.

  That's one locate per start, often under a second.
- b. As (a), and at every home trip of mine and farm. This catches a
  turtle moved mid-job too.
- c. On every move: correct all the time, but a locate per move. No.

Recommendation: a. Mid-job errors are rare under `T.run`, and (b) can come
later if a field report shows the need.

### D2. What a fix must be to count

Recommendation: whole numbers to within 0.1, from an equipped or
attached wireless or ender modem. Otherwise the fix is set aside with a
note, and dead reckoning stands.

A turtle's fix is exact. A fractional one means something is off, such
as ADR-0017's noisy ranges once they exist (its D9 averaging would go
here).

### D3. How far a correction may go

When GPS and dead reckoning disagree:

- **a. Within 16 blocks** (recommended): `T.pos` is corrected to the fix,
  saved, and the program says "the saved position was N blocks off:
  corrected from GPS".
- **Farther:** nothing is corrected. The turtle was carried off, or it is
  in another dimension (the GPS facts above), and dead reckoning can't say which.
  - A program stops as `T.requireHome` does now, naming where GPS puts
    it, in the world and in its frame.
  - claude gets the same as a line in its context.
  - `reset` doesn't head home from there either: walking 500 blocks, or
    toward a cell in another dimension, isn't what "go home" meant.
- b. Any distance is corrected. That breaks in another dimension.
- c. Never correct, only warn. That's the safest choice, but not what was
  asked.

### D4. The facing

GPS gives no facing. Dead reckoning's heading is trusted unless the
position was off, was lost, or there's no origin yet. In those cases:

- **First choice:** a geo scan, if a scanner is equipped or aboard (as
  `T.setOrigin()` does now).
- **Second choice (recommended):** a step. Move forward into a free cell
  (or back), locate, and step back. That costs 2 fuel and digs nothing;
  if every way is blocked, there's no step.
- **Otherwise:** keep dead reckoning's heading with a note, or leave the
  origin unset.

### D5. Which wins: GPS or the origin the player gave

A disagreement looks the same whether the turtle moved (dead reckoning
wrong) or the origin was typed wrong (the origin wrong). The
recommendation: GPS anchors the frame once, then corrects the dead
reckoning.

- **No origin yet:** the first good fix sets it, with the facing from D4.
- **An origin the player gave:** at the first fix after it is set, a
  disagreement moves the origin to match GPS. `T.pos` is kept: the turtle
  hasn't moved since it was told. A warning names both positions, so a
  constellation set up wrong (y and z swapped) shows.
- **An origin set from GPS:** later disagreements correct `T.pos` (D3).
- Where the origin came from is saved with it (`gps` or `player`).

Alternatives:
- b. The player's origin always wins. GPS only checks it, and warns.
- c. GPS always wins: the player's origin is ignored while there's a fix.

### D6. Lost position

`.turtlepos` is gone, or the map is unaligned. With an origin and a good
fix:

- the position comes from GPS (in the frame, through the origin);
- the facing comes from D4;
- the frame and the map are kept, rather than re-zeroed and marked
  unaligned.

Without both, it does what it does today. Recommendation: yes. Fixing
this is most of what GPS is for.

### D7. Turning it off

Recommendation: a setting, `turtle.gps`, defaulting to true; false is
dead reckoning only. With no wireless modem it is skipped, and costs
nothing.

A modem in the inventory isn't swapped in. A turtle's two slots are
usually the tool and the scanner, and swapping one costs a slot's
juggling at every start. That could come later, as `T.withPeripheral`
does for the scanner.

**Amended (2026-11-19, the user: "yes change D7 so it swaps the modem in
for position checks"):** in game, a mine turtle carries the pickaxe and
the chunk controller, so its modem rides in the inventory. Not
swapping it in meant no GPS for mine at all, and a `mine reset` after
a lost count went to the wrong place. A check now swaps a wireless
modem (the ender modem first) in from the inventory with
`T.withPeripheral`, as a scan does the geo scanner, in place of the
tool; the chunk controller never comes off. It swaps back after the
check. With no side free to swap onto, there's no check.

### D8. What each program shows

- **mine, farm and mow:** carry on after a correction, with one line about
  it; stop beyond D3, naming the cell.
- **`reset` and `home`:** head home from the corrected position.
- **claude:** a context line, "position: from GPS" or "corrected by
  ...". The Frames paragraph of the system prompt says GPS keeps the
  position right when there is one.
- **The help:** `help turtlelib` and each program's help say it.

## Trade-off analysis

- **The cost:** a locate per start, with no GPS here nothing (D7). With
  hosts and no answer, 2 s.
- **The risk:** a wrong constellation moving a right frame. D5's warning
  and D3's limit bound it. `turtle.gps=false` turns it off.
- **Left out:** the step in D4 is the only motion added, and only when the
  facing is unknown. Mid-job checks (D1 b) and a swapped-in modem (D7, since amended)
  are left for a later report to ask for.

## Consequences

- "Turtle may not be at home" and the unaligned map mostly go away where
  there's GPS. `--here` stays for where there isn't.
- An origin comes for free at the first start with GPS. Building with
  compass facings no longer waits on the player.
- Programs started in another dimension, or far from where they were,
  stop and say so instead of digging in the wrong place.
- ccnix-mod needs nothing: this is Lua over CC's stock GPS. ADR-0017 would
  change only what a fix is (D2).

## Action items

### Phase 0

1. [x] The sims' turtle world answers `gps.locate` from the turtle's true
   cell (`sim/turtlelib_world.lua` has a stub). A sim switch moves the
   turtle without telling turtlelib, and turns GPS off.
2. [x] Scenarios that fail today:
   - a desync of one block;
   - a turtle carried 3 blocks before a start;
   - one carried 100 blocks;
   - a lost `.turtlepos` with an origin;
   - no origin, with a scanner and with a free cell ahead;
   - a player's origin GPS disagrees with;
   - no modem;
   - `turtle.gps=false`.

### Phase 1: build (on the user's answers)

3. [x] turtlelib: `T.gpsCheck()`, which checks, corrects and explains.
   Called from `T.startAtHome` and `T.goHome`. The origin's source saved
   with it.
4. [x] claude: at session start and per goal; the context line; the
   prompt.
5. [x] autostart: its look at the saved position goes through the check.
6. [x] The help, `turtle/tl/index.txt`, and UNTESTED.md with a
   `needs-in-game-test` issue (#116).

### Phase 2: release

7. [ ] With the next release, on the user's ok.
