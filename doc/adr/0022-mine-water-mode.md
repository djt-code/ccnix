# ADR-0022: mine through open water: the shell first, then fill and dig

**Status:** Proposed (2026-11-26)
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

## Options considered (the owner's calls)

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

## Action items

### Phase 0
1. [ ] The scenarios above, with today's numbers as the baseline.

### Phase 1 (once D1 to D5 are decided)
1. [ ] The shell walk with placements and no looks, for exposed faces only (D2).
2. [ ] The fill in chunks, with the cap between them, then the dig.
3. [ ] The end cap and the bulkhead (D3).
4. [ ] The trigger (D1) in `mineSegment` and `repair`.
5. [ ] Blocks from behind and the start (D4).
6. [ ] The header and help text, and the in-game checks.
