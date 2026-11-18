# ADR-0017: GNSS in game: noisy ranges, multilateration, quantization-correctors

**Status:** Proposed
**Date:** 2026-11-17
**Deciders:** Dan Theisen

## Context

ADR-0016 made gpsd, a host for CC's stock GPS. The user asked for more
(2026-11-17):

> can we make less "gps sats" give a fuzzier location than more "gps sats"
> and accuracy localized inside their bubble (if that even matches real
> physics) ... we moved beyond trilateration to multilateration like 40
> years ago. write an ADR to simulate this properly in game with ccnix-mod.

and, on ender modems and dimensions:

> ender modem's only attenuation is cross dimensional, in the form of
> quantization that the game engine already implies, plus a bit more. a
> single gps dimensional anchor (in the nether, for instance, when the main
> 4 units reside in the overworld, resolves much of that fuzz)

and, on what to call it:

> its not a 'nether-anchor' it's a 'quantization-corrector' in the
> opposite dimension that most of the gps system is built in

### Does it match physics? Yes.

- **What a receiver measures.** A real GNSS receiver times a signal from
  each satellite. Its own clock is cheap and off by an unknown bias `b`, so
  each measurement is a *pseudorange* `ρᵢ = |sᵢ − r| + c·b + εᵢ`. That is
  four unknowns (x, y, z, b), so it needs four satellites at least.
- **How it solves.** It solves by least squares over every satellite in
  view, iterated (Gauss-Newton: linearize at a guess, solve, repeat). It
  doesn't pick three and intersect spheres. Weighting each range by
  `1/σᵢ²` makes it the best linear estimate for independent errors.
- **How good the fix is.** Precision is the range error (UERE, σ) times a
  geometry factor, the DOP.
  - `H` has a row per satellite: the unit vector from the receiver to it,
    and a 1 for the clock.
  - `Q = (HᵀH)⁻¹`.
  - `GDOP = √trace Q`, `PDOP = √(Qxx+Qyy+Qzz)`, `HDOP` the two horizontal
    axes (x and z in Minecraft), `VDOP` the vertical (y), `TDOP` the
    clock.
  - Position error ≈ σ × PDOP (1σ, for equal, independent errors).
- **The user's two effects follow from that.**
  - **Fewer satellites, fuzzier fix:** more satellites and a wider spread
    of directions mean a smaller DOP.
  - **The bubble:** far outside the constellation the directions to it
    bunch together, so the matrix nears singular and the DOP climbs fast.
- **Up versus down.** Satellites all on one side (overhead) make the
  vertical worse than the horizontal: VDOP > HDOP, as on Earth.
- **The in-game analogue.** It is ground transmitters (pseudolites, a
  local positioning system) more than orbiting satellites. The receiver
  can stand inside or outside the constellation, and the bubble is real
  there.
- **Integrity (RAIM).** The residuals of an over-determined fix show a bad
  measurement:
  - with the clock unknown, five ranges detect one fault and six can name
    and exclude it (by leaving each out in turn);
  - without the clock term, four and five.
- **Nothing has to be faked.** Noisy ranges plus least squares produce
  every effect the user named. No fuzz is scaled by hand to the host count.
- **The bubble already exists in CC, for errors in host positions.** CC's
  ranges are exact, but a host's claimed position is only as right as
  whoever typed it, and the geometry amplifies that error the same way a
  DOP amplifies range noise. A check with textbook trilateration, for four
  hosts at (0,200,0), (300,150,0), (0,180,300) and (300,250,300):
  - **Exact ranges, four hosts not in one plane:** the fix is exact to
    1e-10 anywhere, even 5000 blocks out.
  - **Four hosts in one plane:** two mirror candidates both fit the
    fourth range. It can't be resolved.
  - **The fourth host 1 block off the plane, the client 3000 out:** still
    exact, but the fourth range separates the two candidates by only 0.07.
    Any noise at all makes that a coin toss.
  - **One host's claimed position 1 block off (a typo):** the worst fix
    error is
    - 0.98 to 1.89 blocks inside the hull;
    - 47 blocks at about 1000 out;
    - 243 blocks at about 5000 out.

  So noisy ranges add a second error source to a geometry that already
  amplifies the first. Weighted least squares and RAIM (D8) deal with both.
- **Not simulated:**
  - multipath;
  - signals blocked by terrain (modems go through blocks);
  - elevation masks;
  - atmosphere beyond a storm factor;
  - Doppler and velocity.

### What CC does today (CC: Tweaked 1.120.2, read from its jar)

- **A distance is exact.** `WirelessNetwork.tryTransmit` computes
  `receiver.getPosition().distanceToSqr(sender.getPosition())` and calls
  `receiveSameDimension(packet, Math.sqrt(distanceSq))`, the range being
  `max(range, receiver.getRange())`. The distance reaches Lua as the fifth
  value of `modem_message` (`ModemPeripheral.receiveSameDimension`). So
  stock trilateration is exact, and any fuzz has to come from somewhere.
- **What a position is:**
  - **A modem block:** `WirelessModemBlockEntity`'s `getPosition` is
    `Vec3.atLowerCornerOf(entity.getBlockPos().relative(entity.
    getDirection()))`. `WirelessModemBlock` sets `FACING` to
    `getClickedFace().getOpposite()`, so it points into the block the modem
    is attached to. A modem's position is therefore the lower corner of its
    computer's block: exactly the computer's integer F3 coordinates. (A
    modem stuck to some other block gives that block's corner.)
  - **A turtle's modem:** `TurtleModem`'s `getPosition` is the turtle's
    block coordinates, with no +0.5.
  - **So:** between computers and turtles, ranges are corner to corner and
    exact. A host's configured position can be checked to a tenth of a
    block.
  - A pocket computer's modem uses its holder's position, so its distances
    have fractions.
- **Across dimensions there is no distance at all.** When the sender and
  the receiver are in different levels, and either side is
  interdimensional (an ender modem), `tryTransmit` calls
  `receiveDifferentDimension(packet)`. That queues `modem_message` with
  four values: side, channel, reply channel, message. So the distance is
  nil. The stock client ignores a reply without a distance, so GPS doesn't
  work across dimensions now.
- **Ender modems in one dimension** get a distance whatever the range
  (`tryTransmit` skips the range check for an interdimensional sender or
  receiver).
- **The stock client** keeps three fixes and stops at the first single
  point. It never uses a fourth or later reply to improve the answer, and
  never averages. Its reply check is a table whose length (`#`) is 3, with
  three numbers. Named keys beside the three numbers don't change that.
- **gpsd (ADR-0016)** answers the stock protocol: a `"PING"` on 65534,
  answered with `{x, y, z}` on the ping's reply channel. Its accepted D3
  checks its configured position against each reply's measured distance,
  within 0.1 block. That is tight because ranges are corner to corner and
  exact.

### What ccnix-mod has to work with

- **Mixins:** `ccnix.mixins.json` is optional (`"required": false`).
  `PasteLimitMixin` is one into CC's own classes, with `require = 0` so it
  does nothing if CC changes.
- **A CC network node:** the gateway already runs one, with a
  `PacketReceiver` that hears every packet (`GatewayBlockEntity.Receiver`).
- **Config:** `config/ccnix-server.toml` has `[gateway]`, `[nat]` and
  `[tun]` sections, and edits take effect while the server runs.
- **Tests:** they run ccnix's Lua in Cobalt against the Java side
  (`CcWorld`, `LibNetTest`).
- **No Lua API of its own:** nothing a computer can call to ask the mod
  for its settings.

## Decision

Simulate GNSS faithfully where it costs little:

- **The noise:** the mod adds it to the ranges where CC hands them to
  computers (D2 to D6).
- **The solving:** a ccnix library solves by weighted least squares, with
  DOP, an accuracy and RAIM (D7, D8).
- **What a fix says:** the solution's own statistics. Fewer hosts, a
  narrow spread, being outside the bubble, crossing dimensions or bad
  weather each give a larger accuracy figure because of the geometry and
  the noise, not because of a rule.
- **Stock clients** stay exact unless the server says otherwise (D3).
- **Without ccnix-mod,** the library works on exact ranges, with the DOP
  still reported.

## Options considered

### D1. How the fuzz arises

- **(a) Noisy ranges, weighted least squares. Recommended.** The DOP and
  the bubble come from the geometry, as in the real thing.
- **(b) Fuzz scaled by the number of hosts in range.** Easy, but not
  physics. It has no bubble, no geometry and no reason a poor spread is
  worse.
- **(c) A receiver block or turtle upgrade that solves on the server.** It
  is faithful, but needs a new item, recipe, texture and peripheral API.
  The solving would be Java nobody can see from a computer.

### D2. Where the noise is added

- **(a) The mod perturbs the distance as CC delivers it. Recommended.**
  - **The hook:** a mixin at the `receiveSameDimension` and
    `receiveDifferentDimension` calls in `WirelessNetwork.tryTransmit`.
    MixinExtras' `@WrapOperation` hands the hook the receiver, the packet
    and the distance; NeoForge bundles MixinExtras (to check against
    NeoForge 21.1.252). A plain `@Redirect` works too, but clashes with
    any other mod redirecting the same call.
  - **The model:** the hook calls one pure class (`ccnix.gnss.core.
    RangeModel`), tested apart.
  - **If CC changes:** with `require = 0` it does nothing, and ranges are
    exact again.
  - **Coverage:** one hook covers every wireless modem: block, turtle,
    pocket and ender.
- **(b) gpsd adds a noisy range to its reply** and the client trusts it.
  It's all Lua, but an honour system: the client still gets the exact
  distance from CC and can ignore the noisy one. Stock hosts wouldn't do
  it.
- **(c) The receiver peripheral of D1 (c).**

### D3. Which replies get the noise

A GNSS receiver (D8) pings on 65534 like any client, but asks for replies
on **65532**. Hosts, stock ones and gpsd alike, answer on whatever reply
channel the ping gives, so they need no change. 65532 looks free: rednet
uses 0 to 65499 for computer IDs, plus 65533 and 65535; ccnix's network
uses 60000 to 64094.

- **(a) GNSS replies get the full model; stock replies follow a setting.
  Recommended.**
  - GNSS replies are those on 65532, with reply channel 65534 and three
    numbers.
  - Replies on 65534 follow `[gnss] stock = "exact" | "noisy"`, default
    `"exact"`. "noisy" gives them D5's range noise, never D4's clock bias
    or D6's cross-dimension ranges, which stock clients can't solve or map.
  - Stock programs keep working everywhere. A server that wants everyone
    in the simulation sets "noisy" (the dev server, say).
- **(b) Every GPS reply gets the full model.** The clock bias makes stock
  `gps.locate` simply wrong.
- **(c) Only GNSS replies, no setting.**

Cheating stays possible on any choice: commands computers, or a private
ranging protocol on another channel, get exact distances. The model sits
on the GPS channels only. The game is cooperative, so the ADR doesn't fight
that.

### D4. The receiver clock bias

- **(a) Model it, on GNSS replies only. Recommended.**
  - **What it is:** each receiving modem has an offset added to every
    range it is given. It wanders a little each game tick, and stays
    within a few blocks.
  - **What it does:** that makes the measurements pseudoranges, so four
    hosts are the least and the client solves for b, as in the real thing.
  - **Why it's cheap:** the client solves for it anyway, so its size
    doesn't matter.
- **(b) No clock.** CC's ranging is really two-way (ping, then reply), more
  like aviation's DME than GPS. Three unknowns, three hosts plus one to
  pick between the two points. It is simpler, but less like the real
  thing the user asked for.

### D5. Noise within one dimension, by the host's modem

The kind of modem that sent the reply decides the noise:

- **A wireless modem:**
  - σ = 0.25 block + 1 block per 200 blocks of range;
  - × 2 in rain or thunder, the same weather that already shortens a
    modem's range in CC;
  - a fresh Gaussian draw each delivery.
- **An ender modem: no range noise within a dimension (the user's input).**
  Ender hosts in one dimension give exact ranges (plus D4's clock bias,
  which the client solves away). So four of them give exact fixes, and the
  bubble shows only with wireless hosts or across dimensions (D6).

Every draw is keyed by the world seed, the sender's and the receiver's
positions, and the game tick. That makes it reproducible: the same request
in the same tick gets the same answer (one epoch), and averaging over ticks
works. Ticks, not real seconds: the epoch is a game thing (ADR-0016 D8).

The config, `[gnss]` in `ccnix-server.toml`:

- `enabled`;
- `stock`;
- `wirelessSigma`;
- `wirelessSigmaPer200`;
- `stormFactor`;
- `clockBias`;
- `crossSigma` (D6).

- **(a) As above. Recommended.**
- **(b) A small σ for ender modems too:** more fuzz, but against the
  user's call.
- **(c) One flat σ for all:** simpler, no distance or weather effects.

### D6. Across dimensions: quantization plus a little

Today a reply across dimensions has no distance (Context). For GNSS
replies only, the mod makes one, the user's quantization:

1. **Map the host's position into the receiver's dimension** by the
   dimensions' coordinate scale, the one portals use: nether to overworld
   ×8 on x and z, y unchanged. That this is Minecraft's
   `DimensionType.coordinateScale` is to check. A dimension pair with no
   scale between them (the End) gets none: a scale of 1.
2. **Quantize it.** In the receiver's frame a block of the host's
   dimension spans `q = max(1, s)` blocks, where `s` is the scale from the
   host's dimension to the receiver's: 8 for a nether host seen from the
   overworld, 1 for an overworld host seen from the nether (which is
   floored to a nether block). The mapped point gets a fixed offset,
   uniform within that span on x and z. "Fixed" means seeded by the host's
   position and the two dimensions, so σ = q/√12 per axis and it does
   *not* average away. That is how a real ephemeris error behaves: a floor
   no amount of waiting beats.
3. **A bit more:** a Gaussian σ = `crossSigma` (0.5 block) per delivery,
   which does average.
4. **Deliver it** as `receiveSameDimension` with that distance.
5. **Stamp the reply** (D7) with the host's dimension and the scale, so
   the client maps the host's claimed `{x, y, z}` the same way. The claim
   is in the host's own coordinates.

Stock replies never get this: a stock client would take an overworld
host's coordinates as nether ones. Only ender modems carry across
dimensions, as now.

- **(a) As above. Recommended.**
- **(b) No ranges across dimensions** (as today): then a nether base needs
  its own four hosts.

### D7. Quantization-correctors, and mixing ranges

- **What a quantization-corrector is:** a host in the dimension opposite
  the one most of the GPS system is built in. With the constellation in
  the overworld, it is in the nether; with the constellation in the
  nether, it is in the overworld.
  - It corrects D6's quantization fuzz for clients in its own dimension.
  - Its range to them is a same-dimension range: clean from an ender
    modem (D5).
  - The constellation's ranges reach those clients across dimensions, and
    carry the quantization.
- **How the client mixes them:** by weight, from the solution's
  covariance:
  - the mod stamps each delivered reply with its σ, plus the host's
    dimension and the scale (D8's keys);
  - the client weights by `1/σ²`, so a corrector counts for far more than
    a quantized host across dimensions;
  - the accuracy comes from `(HᵀWH)⁻¹` directly.
- **How much one corrector resolves** (the user's "much of that fuzz"):
  - It removes the error along its own line of sight, and helps the clock
    term.
  - Error across that line still comes from the constellation's quantized
    positions, at their geometry.
  - A second corrector at a different angle removes most of the rest.
    Four in that dimension are a constellation of their own.
  - `gnss -v` (D8) prints how much each host contributed, so a player sees
    where a corrector helps.
- **(a) Weighted least squares as above. Recommended.**
- **(b) Correctors first:** use correctors alone when there are four, and
  the hosts across dimensions only to make up the numbers. It is simpler
  to explain but wastes information. (a) gives the same answer when the
  correctors are enough, because their weight dominates.
- **The name in the code:** gpsd needs no setting for it. A host is a
  corrector by where it stands relative to the client, and `gnss -v`
  labels it so ("corrector") when a fix mixes dimensions.

### D8. The client, and the protocol's extra keys

- **`lib/gnss`.** `gnss.locate(opts)` gives a fix, or nil and a reason.
  - **The fix:**
    - `x, y, z`;
    - `accuracy`, a 95% radius in blocks;
    - `sigma = { x, y, z }`;
    - `pdop, hdop, vdop, tdop, gdop`;
    - `bias`;
    - `hosts`: a list of `{ id, x, y, z, dim, range, sigma, residual,
      used }`;
    - `excluded`, with RAIM's reason;
    - `epochs`.
  - **The options:**
    - `timeout` in ticks, as stock;
    - `epochs = n`, to average n ticks while standing still;
    - `side`, the modem;
    - `min`.
  - **The solver:**
    - weighted Gauss-Newton from the hosts' centroid, 10 iterations at
      most;
    - nearly singular geometry (all the hosts in one plane, or one line)
      says so instead of giving a point;
    - RAIM as in the Context: a χ² test on the weighted residuals with
      n − 4 degrees of freedom (n − 3 when there is no clock), excluding
      by leaving each host out once there are two spare.
  - **The 95% radius:** taken from the covariance. For three equal axes
    it is about 1.6 × the 3D RMS error, an approximation that assumes
    Gaussian errors.
  - **Without the mod:** with no stamps it treats the ranges as exact and
    the clock as absent. It still reports the DOP, with an accuracy of 0.
- **`bin/gnss`:** `gnss`, `gnss -n 20` (average), `gnss -w` (watch), and
  `gnss -v` (the host table and the DOPs). `gps` stays stock.
- **The extra keys:** named keys in the reply table, which stock clients
  never read, since their check counts only the three numbers.
  - gpsd adds `id` (its computer ID), so RAIM names a host.
  - The mod adds `gnss = { sigma, dim, scale }` to the copy each receiver
    gets.
- **(a) As above. Recommended.**
- **(b) Patch `gps.locate`** to do this: it would change every stock
  program at once, and with the clock bias that is wrong (D3).

### D9. `T.setOrigin` with an accuracy

`gpsFix` in `turtle/tl/world.lua` calls `gps.locate(2)` and rounds.

- **(a) Use `lib/gnss` when it can, and check the accuracy. Recommended.**
  - Average 5 epochs (the turtle stands still).
  - Refuse when the 95% radius is over 0.5 block, as the cell might be
    the wrong one, and say how far off it could be and why (few hosts,
    outside the bubble, across dimensions). `opts.coarse = true` accepts
    it.
  - Fall back to `gps.locate` with no GNSS replies.
  - A turtle needs the cell exactly once; it keeps track by moving from
    then on.
- **(b) Round whatever comes:** a wrong cell, silently, a block off.

### D10. gpsd's position check (ADR-0016 D3) under noise

- **(a) Tolerance `max(0.1, 4σ)` per reply, from the stamp.
  Recommended.**
  - gpsd checks against the replies on 65534 it hears. Those are exact
    unless `stock = "noisy"`, and never carry a clock bias.
  - Replies across dimensions are left out of the check.
- **(b) Keep 0.1 flat:** with `stock = "noisy"`, every honest host would
  look wrong.

## Trade-off analysis

- **The mixin is the cost.** It is one hook into a private CC method, so a
  CC update can move it. With `require = 0` the world then falls back to
  exact ranges, which is today's behaviour, not a crash. A test that loads
  CC and looks for the hook would catch the move in CI.
- **Splitting GNSS replies from stock (D3, the 65532 reply channel)** buys
  the clock bias and the ranges across dimensions without breaking a
  single stock program. The price is a second channel open on GNSS
  receivers (well inside CC's 128) and a server setting to decide how
  noisy stock GPS is.
- **Ender modems clean within a dimension (D5)** follows the user and
  keeps a home constellation of ender modems exact. The bubble and the
  fuzz then belong to wireless hosts and to other dimensions, where the
  user put them.

## Consequences

- **Easier:**
  - Players see real GNSS behaviour, and `gnss -v` explains it: add a
    host and the DOP falls; walk out of the bubble and it climbs; go to
    the other dimension and the accuracy jumps until a
    quantization-corrector goes up.
  - RAIM names a misconfigured host, a neighbour's included. That
    answers the trust problem ADR-0016 raised.
- **Harder:**
  - The mod depends on a CC internal, for this feature only.
  - The noise model has parameters to tune.
- **Unchanged:** stock `gps`, stock hosts and stock programs (with the
  default `stock = "exact"`).
- **To revisit:**
  - the parameters, after play;
  - whether `stock = "noisy"` should become the default;
  - signals blocked underground, if the user wants caves to lose the fix.

## Action items

### Phase 0: the oracles (ccnix)

1. [ ] `sim/gnss.lua`, failing first. A Lua stand-in for D5 and D6, seeded
   by the runner, feeds `lib/gnss`. The scenarios:
   - exact ranges give the exact point;
   - four wireless hosts round the receiver give a small PDOP, and outside
     them it grows with distance;
   - fewer hosts or a flatter spread give a larger accuracy;
   - all the hosts in one plane are refused;
   - the clock bias is solved;
   - RAIM detects one bad host with five and excludes it with six,
     naming its `id`;
   - foreign-dimension hosts give the quantization floor, which averaging
     doesn't beat, and one quantization-corrector shrinks the error along
     its line, whichever dimension holds the constellation;
   - no stamps behaves as exact;
   - `T.setOrigin` refuses a 0.5+ block fix and accepts `coarse`.

### Phase 1: ccnix (pull request, released first)

2. [ ] `lib/gnss.lua`, `bin/gnss.lua` and `help/gnss.txt`.
3. [ ] gpsd adds `id` to its replies, and D10's tolerance.
4. [ ] `T.setOrigin` per D9 (turtlelib and the index line).
5. [ ] UNTESTED.md section and its issue; `deploy/version` minor, on the
   user's ok.

### Phase 2: ccnix-mod (pull request, label `lockstep`)

6. [ ] `ccnix.gnss.core.RangeModel`: D4 to D6, pure and seeded. JUnit
   tests for its statistics (σ by distance and weather, the fixed
   quantization, the clock walk staying bounded, reproducibility by seed
   and tick).
7. [ ] The mixin (D2), the `[gnss]` config (D5), and the stamp (D8).
8. [ ] `GnssTest` in Cobalt: `lib/gnss` from the `ccnix/` submodule
   against `RangeModel` in a `CcWorld`, for the bubble, a
   quantization-corrector, and a
   stock client under `stock = "exact"` and `"noisy"`.
9. [ ] `ccnix/` at the Phase 1 release's tag; `mod_version` minor; then
   this repo's `mod/` bump.

### Phase 3: in game

10. [ ] The dev server: four wireless hosts and four ender hosts, walking
    out of the bubble, a quantization-corrector in the other dimension,
    and `stock` both ways. The
    findings go into UNTESTED.md.
