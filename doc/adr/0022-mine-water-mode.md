# ADR-0022: mine through open water: the shell first, then fill and dig

**Status:** Accepted (2026-11-26): D1 to D5 all A; built (see As built)
**Date:** 2026-11-26
**Deciders:** Dan Theisen

## Context

`mine` digs wet ground one block at a time (`dry`, `stopFlow`, `cutOff` in `turtle/mine.lua`). Before each dig
it looks at the block. A water source is filled and then dug again. Flowing water is followed upstream to
where it comes in, and sealed there. In game this keeps water out well: when it opens a water block, only a
small packet of water gets through before it moves to block it. But it is slow, and costly in turns, looks,
and bulk blocks wherever the water is not a seep but a body:

- a segment through an ocean, a lake or an aquifer;
- a segment the turtle finds flooded when it goes over it again (sim scenario 13c: the segment and the rock
  round it all water);
- a lava lake under or over the tunnel.

There, nearly every block it digs is wet, and the turtle spends its time turning to look round each one.
`sweep`, the last resort for water it couldn't trace, looks at all six sides of every block along the shell,
which means four turns for each block.

The owner (2026-11-26):
- **Open water:** for segments that are entirely flooded, or built through an ocean, the turtle builds the
  tunnel shell first, then fills the shell inwards one block at a time. Once it has found that it's tunnelling
  through water, it makes no unnecessary turns or checks.
- **Rock:** it builds the shell even where it has to tunnel through rock to do so.
- **End cap:** a segment that ends submerged gets an end cap, and stays sealed as much as possible. This
  protects the tunnel behind the last home from the segment under construction.
- **Half wet:** a tunnel with water only in its top or bottom half gets a shell only on the parts exposed to
  water or lava.
- **Both modes:** the careful mode stays for scattered water. This one is for bodies of it: "the best of both
  worlds".

## Decision

A **water mode** for a stretch of a segment. It is the same work in a new order:

1. **The shell.** The turtle walks the outer lanes of the box: the side columns, and the floor and ceiling
   rows. It digs any rock in its way. It places a bulk block into each outside face that is exposed. A
   placement into rock simply fails, so it uses no block and needs no look first. The moves are chosen to
   avoid turning:
   - **Floor and ceiling:** it places down and up while walking along each row: no turns.
   - **Walls:** it faces the wall and works each column up and down, placing ahead. That is two turns per
     block of length, whatever the height. `sweep` makes four turns per block, in every row.
2. **The end cap.** Where the segment's far end is in water, a wall goes across the box just past `z2`.
3. **Filling and digging.** Inside the closed shell the water is still there, as sources. The turtle fills
   it lane by lane, from the shell inwards. It goes to the far end of a lane through the water, then backs out
   with `turtle.back()`, placing a block ahead after each step: no turns, and no looks. Once a stretch is
   solid, the ordinary lanes dig it out dry, and the blocks it placed come back to its inventory.
   - **Chunks:** a 10x10 segment holds up to 1,600 blocks of water, more than the turtle carries. So it fills
     and digs in chunks of the length its blocks allow.
   - **Caps between chunks:** each chunk ends at one filled slice, left in place until the next chunk is full,
     so digging never opens onto a face of water.
4. **The bulkhead.** While a segment is in water mode, the end cap of the segment before it (or a wall at
   the home's end) stays up as a bulkhead.
   - **Passing through:** the turtle opens one block of it to pass, and closes it behind itself (two turns
     each way).
   - **Taking it down:** the bulkhead comes down only once the segment beyond is dry, with its own end cap
     up, so that a breach floods only the segment under construction.

The careful block-by-block mode stays for scattered water: a seep, one source, a waterlogged block.

## Options considered (the owner's calls: all A, 2026-11-26)

### D1. When water mode starts

- **A. Scanner, or a count of sources met (recommended).**
  - **With a Geo Scanner:** the scans of the segment ahead show fluid in the box or its shell over more than
    a set share of a stretch (say a third of its faces). That stretch goes into water mode before it is dug.
  - **Without a scanner:** N water or lava sources met within a few blocks of a lane (say 6 in 4 blocks)
    switch the rest of the segment to water mode.
  - **Going over a dug segment:** the same count applies (13c).
- **B.** Only with a scanner; without one, the careful mode as today.
- **C.** A switch (`--water`) the player sets for a tunnel they know goes through water.

### D2. Which faces get a shell

- **A. The faces it knows are exposed, plus a margin (recommended).**
  - **With a scanner:** each face a scan shows as fluid, and one block either side.
  - **Without a scanner:** each side it met fluid on while digging that stretch (top half, bottom half or
    walls), along the whole stretch.

  A half-wet tunnel gets only its wet half shelled (the owner's ask).
- **B.** Every face in the stretch, always. Placements into rock fail at no block cost, but the walk along
  each lane costs time and fuel.

### D3. The end cap's life

- **A. It stays until the next segment is dug and dry; that segment starts in water mode (recommended).**
- **B.** It stays for good, with a doorway the turtle reseals behind itself: a hatch to the open water.

### D4. Where the blocks come from

The shell consumes blocks for good: up to 2 × (width + height) per block of length (40 for a 10x10), and an
ocean gives almost nothing to dig. The fill blocks are only borrowed.
- **A. The homes behind, then the start's bulk chest, and stop with a message when there are none
  (recommended).** The existing `fillerFromBehind` goes all the way to the start. It stops with "Out of bulk
  blocks for the shell: put cobblestone in the start's bottom chest" rather than leaving a face open.
- **B.** Wait at the start for blocks (as the fuel wait does), then carry on.

### D5. Glass

- **A. No: any bulk block will do (recommended; keep it simple).**
- **B.** Glass from the start's chest for the walls, when given, so the tunnel looks out into the water.

## Trade-off analysis

- **Cost in open water.** The careful mode costs at least one look and often four turns per block. Water
  mode costs about two turns per block of length for the walls, none for the floor, ceiling and fill, and one
  placement per wet face. Digging the filled stretch is the ordinary dry lane work, the fastest thing mine
  does.
- **The price** is blocks: the shell's, consumed, and the fill's, borrowed. That is D4.
- **Safety.** The end cap and the bulkhead keep a breach to one segment. Today a breach floods back to
  the last home and beyond, until a going-over finds it.
- **The careful mode stays** where it is cheaper: scattered water costs a few looks, not a shell.

## Consequences

- **mine.lua:** a new section (shell, cap, fill, bulkhead) beside the water section, with a stretch-in-water
  test (D1) wired into `mineSegment` and `repair`. `sweep` becomes the shell walk for a dug stretch.
- **Sims first** (Phase 0), each failing or slow on today's code, with moves, turns and blocks reported:
  - a segment through open water (an ocean: water above, beside and below);
  - a tunnel with a lava lake under its bottom half only;
  - a segment that ends submerged (the end cap, the bulkhead, a breach that floods only that segment);
  - 13c redone in water mode;
  - a dry tunnel and the seep scenarios unchanged.

  The sim already makes a source of an empty block with two sources beside it, which the fill order relies
  on.
- **In game:** one `needs-in-game-test` check per item.
- **ccnix-mod:** nothing.

## As built

- **The trigger (D1):** 6 sources met within 4 blocks of each other in a segment's lanes; the segment before
  left an end cap at its start; or, with a scanner, a scan from the home showing a third of the sides it saw
  in the segment's first 8 blocks in fluid. Not in the first segment: there's no open side to work from.
  Going over a dug segment isn't switched yet: the careful mode, with `seal` now going for blocks (#388),
  dries a flooded one (13c).
- **Faces (D2):** a scan or a look says; what neither has seen counts as wet. With a scanner, a chunk goes no
  further than the scan from its open side sees.
- **The fill's lanes:** one row in three; a lane on the bottom row when the floor is wet, and on the top row
  when the ceiling is. Going out, a lane shells the floor or ceiling. Backing out, it fills above, below and
  ahead.
  - **The end cap:** at the segment's end, the lane places ahead into the next slice where there's water
    (it looks first, facing along, so with no turn), and does the rows above and below it too.
  - **Where the water ends:** a lane, or a wall column, stops once it has dug through two blocks of rock
    after meeting water. A chunk whose last slice met no water ends open-water mode, and the rest of the
    segment is dug as ever.
- **The dig:** a lane every third row in every column, as with a scanner, since the walls are shelled. The
  walls it has just shelled aren't looked at again.
- **The bulkhead:** a wall across the tunnel one block behind the home, put up at the start of a segment's
  open-water work. `go` closes it behind anything that passes through it. It comes down once the segment is
  dug. In place of the door the Decision describes, the end cap and each chunk's filled last slice stand
  between the dry tunnel and the water. Only the lane being filled is open, and a packet that gets through
  stops at the bulkhead.
- **Blocks (D4):** 6 stacks are carried in open water. Short, it goes to the home, then the homes behind and
  the start (`fillerFromBehind`, as many as needed). With none anywhere it stops: "Out of bulk blocks for the
  shell ... put cobblestone ... in the start's bottom chest".

**The sims** (`sim/mine_water.lua`). The count is moves, turns, digs and blocks placed, each about 8 ticks in
game. Looks take about one tick, and the careful mode makes many more of them, but they aren't counted
here.

| scenario | careful mode (before) | open-water mode |
|---|---|---|
| W1: a 5x5 tunnel into a lake (13 of its 16 blocks wet, past its end) | 982 + 1832 + 853 + 662 = 4329 | 1766 + 628 + 931 + 740 = 4065 |
| W2: carried on through the end cap, 8 wet blocks then rock | 610 + 1022 + 421 + 359 = 2412 | 1268 + 380 + 524 + 462 = 2634 |
| W3: water under the bottom half only (scanner) | 762 + 486 + 825 + 233 = 2306 | 1284 + 268 + 933 + 341 = 2826 |

- **Turns:** open water costs a third of the turns.
- **Moves:** it costs about twice the moves, so more fuel. Each fill lane is walked out through the water and
  backed out again.
- **Overall:** in the sim it is a little cheaper in a lake and dearer where only a few rows are wet.
- **In game,** the careful mode chases water that keeps flowing back. The sim's water settles at once, so the
  sim is kinder to the careful mode than the game is. Field numbers decide whether the trigger should be
  stricter.

## Action items

### Phase 0
1. [x] The scenarios above, with today's numbers as the baseline.

### Phase 1 (once D1 to D5 are decided)
1. [x] The shell walk with placements and no looks, for exposed faces only (D2).
2. [x] The fill in chunks, with the cap between them, then the dig.
3. [x] The end cap and the bulkhead (D3).
4. [x] The trigger (D1) in `mineSegment` (`repair` keeps the careful mode for now).
5. [x] Blocks from behind and the start (D4).
6. [x] The header and help text, and the in-game checks.

## Amendment (2026-11-27): the bulkhead only where the tunnel is mostly water

The owner, from the field (turtle 23, a 10x10 with a Geo Scanner, building a bulkhead for a segment that wasn't
fully under water): if the next stretch isn't fully submerged, the bulkhead is a waste of time. It should go up
only when the tunnel ahead is more than half water (source blocks). It shouldn't go up for sporadic water.

- **With a scanner:** open-water mode starts as before (D1). The bulkhead goes up only when more than half of the
  tunnel cells the scans cover in the first `SCAN_RADIUS` slices ahead hold fluid (`BULKHEAD_SHARE`). Otherwise
  it says `No bulkhead: N of the M cells ahead a scan saw are water or lava (P%: it takes more than half).`, and
  the shell and fill do the work.
- **Without a scanner** (the owner's design):
  1. **Counting:** it counts the water it is next to, by column of the tunnel's cross-section (x, y). A source
     counts 1 and flowing water 0.25. One lane running along a wet floor meets water in few columns, so
     sporadic water and a wet floor stay under the threshold.
  2. **Probing:** past the threshold (`WATER_COLUMNS`, within `WATER_SPAN` slices), it digs a few blocks
     (`PROBE_LEN`) along the outside of the tunnel ahead: the top row and the two side columns. Those cells are
     the tunnel's own, so the digging isn't wasted. It counts what it meets there, by the same weights.
  3. **The decision:** more than half water, and it switches to open-water mode with the bulkhead (shell, fill,
     dig). Otherwise it carries on tunnelling as before, sealing as it goes.
- A segment that starts at an end cap (the one before ended under water) is open water with a bulkhead, as
  before.

### As built (the amendment)

- **With a scanner:** as above; `waterAhead` in `turtle/mine.lua`. The trigger is D1's, unchanged.
- **Counting (no scanner):** every look goes through `noteWater`: a source (or a waterlogged block) weighs 1,
  flowing water a quarter (`FLOWING_WEIGHT`), filed by the cell's column (x, y) across the tunnel, walls and
  floor included. A column counts its heaviest once. Not counted: looks on a trip, going over dug tunnel, or in
  open-water mode. `WATER_COLUMNS = 4` within `WATER_SPAN` (4) slices starts a probe. A lone source the turtle
  fills is one column. A fed source has it step in and seal round it: the source's own column and the four
  round it, so a body of water passes 4 at its first wet block.
- **The probe:** from the first source of that water (`columnsAt`), `PROBE_LEN = 4` blocks of up to five
  lanes of the box: the top row's corners and middle, and the side columns half way up. They're dug as the
  lanes dig them (`go`, then `scanHere`: water dried, filled or sealed, walls looked at). Every block it looks
  at in that stretch counts, and the share is their weight over their number.
  - **Getting there and back:** it goes out and back the way it went (in `trail`, as for a vein), so a trip
    home meanwhile retraces its steps. It digs no new way from the water to the tunnel behind (the first
    build dug one, and W1 flooded behind the home).
  - **Bulk blocks first:** it carries enough to seal round every block (5 a block), or goes for them first, so
    it isn't short with water left unsealed behind it.
- **The decision:** over half, it prints `Water at z=N: the probe met P% (over half): working it as open
  water.` and it's open water from the home, with the bulkhead (`No bulkhead: the probe met P% water ...` can't
  follow a probe like that). Under half, it prints `... (under half): tunnelling on, sealing as it goes.`,
  carries on with the lane it was on, and doesn't count again the water in the stretch it probed.
- **--resume:** a stop mid-probe resumes the lane from its last saved block, which is before the probe. It
  counts afresh, and probes again if it meets the water again.

| scenario (no scanner) | before (49f7b6d) | now |
|---|---|---|
| W1: the lake | 1702 + 602 + 904 + 713, no bulkhead, 30 blocks of water behind home 1 | 1890 + 738 + 1030 + 839 = 4497, probe 98%, bulkhead, dry behind (main, before the amendment: 4065) |
| W4: water under the bottom half | 1594 + 656 + 1059 + 467 = 3776, open water | 1012 + 1174 + 825 + 233 = 3244, three probes at 6%, careful mode |
| W5: sporadic sources (7 lone ones, 6 of them two each in 3 columns) | 1856 + 882 + 1261 + 467 = 4466, open water and a bulkhead | 738 + 704 + 803 + 9 = 2254, no probe |
