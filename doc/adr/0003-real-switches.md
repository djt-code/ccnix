# ADR-0003: Real switches: software switches, one spanning tree, a trunk to Open vSwitch

**Status:** Proposed
**Date:** 2026-10-31
**Deciders:** Dan Theisen

## Context

A CC network cable is a hub: every modem on it hears every frame. lib/net
gives VLANs on one cable (VLAN n rides channel 4040+n, untagged on 4040), and
the gateway exchange (ccnix-mod 0.11.0) joins cables through gateway blocks,
each with an allowed VLAN list and a native VLAN. Nothing else splits a cable
into segments, and two paths between cables are a loop nothing breaks.

The user wants to weigh real 802.1Q switches in software, (a) a ccnix app on
a computer, one wired modem per side, or (b) mod blocks (a multiblock of
controller, chassis and ports with access ports, trunks and STP), against a
switch tied into a host Open vSwitch, so VMs and VLANs can share CC VLANs.

Forces:

- **The simplest thing that works**, with real-protocol compatibility: ports
  follow the gateway blocks' vendor model (access: one untagged VLAN; trunk:
  a list and a native VLAN or none); the tree reads like `show spanning-tree`.
- **The gateway is transport only.** A switch is layer 2, below it; nothing
  here parses above lib/net's frame, or above IPv4/TCP/UDP toward a host.
- **CC's limits** (CC: Tweaked 1.120.2, checked in the jar). A modem opens
  at most 128 channels. A computer's 256-event queue drops every kind beyond
  that, timers included. Two modems of one computer on one cable hear each
  other. Lua receivers get fresh tables (no dedup by identity); frames carry
  no TTL. A switch port is one of the computer's own sides (remote modems
  aren't ports, to verify). Sending is synchronous
  (`WiredNetworkImpl.transmitPacket` queues the receivers' events at once):
  nothing queues on the wire; a frame sent across a broken cable is lost. A modem hears nothing
  of a cut, but a wired element hears peripherals leave its network
  (`WiredElement.networkChanged`, with only `peripheralsRemoved()` and
  `peripheralsAdded()`, on connect, disconnect, remove and
  `updatePeripherals`), and a wired modem queues `peripheral_detach`. The mod
  uses neither `networkChanged` nor `WiredNode.updatePeripherals` today.
- **The exchange is already a switch, and L3 to the host.** `Gateway`
  (ccnix-mod's `gateway/core/Gateway.java`, :161-300; bare line numbers below
  are this file's unless a file is named) has per-VLAN learning keyed `"vlan mac"`, native/tagged
  translation, `carries()`/`nativeVlan()` on `Gateway.Port`, flooding to one
  block per cable, a 64-entry identity ring (`seen`) and stats; co-cabled
  blocks find each other by beacons and all but one stand by. The kernel sees
  only `Ipv4`'s bytes; MACs are free strings (`"12:back.20"`, `"*"`).
- **Admin, ops, owners.** The admin owns config, Ansible and host; ops get
  bounded `/ccnix` commands; a block's owner or a level-2 op sets it.
- **Two codependent repos**, `deploy/version` 0.3.4, `mod_version` 0.11.0;
  ccnix's sims (`python sim/run.py`, `--check`, whose segment harness detects
  frames going round) and the mod's JUnit tests with `CcWorld`.

Method: four read-only analyses citing `path:line`, CC's jar via javap, OVS
against `ovs-vswitchd.conf.db(5)`, two review rounds. Found along the way:

- `Gateway.fromCc` calls `seen()` (:241) before the standby check (:245): if
  the standby block hears a frame first, the active block's copy is lost.
- lib/net's hook never re-arms a tick whose timer event was dropped
  (`lib/net.lua:796-808`: `timer` stays set, so `wantTick` does nothing):
  with a full queue, ARP retries, ARP expiry and TCP retransmission stop.

## Decision

1. **Both software switches, in order, around one spanning tree** (D1 C):
   the Lua switch first (sims only; it pins down the BPDU format), then the
   blocks after `core/Switch` is pulled out of `Gateway`.
2. **One tree for all VLANs, a simplified RSTP** (D2 B): 802.1w roles and
   states, proposal/agreement on point-to-point links, edge ports, topology
   change as a flag; no 802.1D compatibility, per-VLAN trees or MSTP. On by
   default: a loop through a Lua switch storms until queues fill.
3. **A BPDU is a lib/net frame**, `dst="stp"`, `type="stp"`, untagged. Its
   channel (D4) and IDs (D5) are open.
4. **One pure engine written twice**, `lib/stp.lua` and `core/Stp.java`,
   kept equal by one table of vectors a sim and a JUnit test both run.
5. **The exchange becomes one bridge** (D3 A), its ports the gateway blocks,
   its host an internal port on VLAN 1; the beacons retire. Until then it
   passes BPDUs on like a hub (The exchange).
6. **The Lua switch**: `lib/switch.lua`, `lib/stp.lua`, `pc/switch.lua`
   (like `pc/router.lua`), run from an `os.pullEventRaw` hook. Settings
   `switch.port.<modem>`: `"access 10"`, `"trunk 10,20,30-40 [native
   1|none]"` or `"off"`, then options `edge`, `cost <n>`, `priority <n>`,
   `bpduguard`, `rootguard`; at most 127 tagged VLANs.
7. **The switch blocks**: a controller (registry ID, owner, bridge priority,
   every port's role and state), chassis and ports (one face each, like
   `GatewayBlockEntity`) joined by a bounded flood fill; a port sets mode,
   access VLAN, list, native VLAN, STP priority, cost, edge and the BPDU and
   root guards; `[switch]`.
8. **Storm guards in the mod.** A port's `receive` only enqueues, onto a
   capped executor queue with a drop counter. A block drops data frames from
   its own bridge's elements but hands their BPDUs to the engine; today
   `GatewayBlockEntity.receive` (`GatewayBlockEntity.java:281-283`) drops every packet from any
   block, so that test must narrow or switch-to-gateway links are cut.
9. **A neighbour-gone signal.** Every Java bridge port element (switch port
   blocks, gateway blocks) registers one `ccnix_port` peripheral on its wired
   node (`updatePeripherals`), named `ccnix_port_<kind>_<number>_<port>`
   (IDs without priorities). On a cut, `networkChanged` lists the far side's
   port peripherals as removed; one naming the port's stored neighbour gives
   the engine `linkLost(port)`: that info expires and roles are re-selected
   at once. Lua switches use `peripheral_detach` (Healing). Ageing after 3
   missed hellos stays the fallback.
10. **lib/net's frame and behaviour don't change for switches:** only its
    header and `doc/network.txt` reserve `"stp"`. The tick fix is separate.
11. **Open vSwitch is a neighbour** (D6 B): later and optional, one host
    trunk from the exchange, a TAP the admin plugs into OVS or a
    VLAN-filtering Linux bridge; admin-only, off by default, Linux only, in
    either `gateway.mode` (The host trunk).

Items 4, 10 and 3's frame shape are decided unless objected to; the rest
have choices, below.

## Options Considered

### D1. Where switching runs

| | A: Lua switch app | B: mod multiblock | C: both, one BPDU format |
|---|---|---|---|
| Complexity | `lib/switch.lua` ~450 lines, `pc/switch.lua` ~200, sims ~400; forwarding copied from `Gateway` | 20-25 files, ~2500-3500 Java lines plus assets; the `core/Switch` extraction | A, then B, plus the engine in two languages |
| Cost | 1-1.5 days; mod: the interim pass-through and executor cap (~50 lines, 0.12.0) | several days; two pack-wide updates (payload protocol "3", then "4") | the sum, over releases |
| Scalability | 6 ports at most (fewer with a monitor, drive or turtle); 127 tagged VLANs per trunk; a 256-event queue shared with the computer | ports to `switch.maxPorts`; every channel; one executor | each where it fits |

**C.** A alone is the weakest bridge in a tree (each port a hub, no "all"
trunks, a queue that drops frames and timers, no identity check); B is the
real switch but costs the most. C gets a switch soon and builds B on a
format the sims have proved, at the cost of two engines tied by vectors.

### D2. The protocol

| | A: 802.1D | **B: simplified RSTP, one instance** | C: per-VLAN (PVST+ style) | D: MSTP | E: none (identity ring, hop counts) |
|---|---|---|---|---|---|
| Convergence | 30-50 s | edge at once; see Healing | as B, but 127 BPDUs every 2 s on a full Lua trunk | as B, with regions and digests | — |
| Loop safety | yes | yes | yes | yes | no: Lua re-sends fresh tables |

**B.** 802.1D's outages are miserable in a game; C eats the event queue; D
fails keep-it-simple (`inst` is reserved); E fails once a Lua switch is in
the loop. One instance blocks every VLAN on a blocked port: redundant links
must carry the same VLANs, and as the exchange joins every gateway cable
into one segment, a switch on two of them blocks one even with no shared VLAN.

### D3. The exchange's role

| | **A: runs RSTP as one bridge** | B: passes BPDUs on, like a hub | C: blocks BPDUs |
|---|---|---|---|
| Effort | the extraction the blocks (D1 B) need anyway (about a day), standby tests rewritten | ~20-30 lines in `fromCc`, 2-3 tests | none |
| Loops through it | cut; the gateway can be root | cut by outside bridges, which see it as one segment | unseen: a storm on both networks and the TUN path |
| Standby | the backup role, also through another switch | beacons | beacons |

**A** as the target, **B** as the interim while only the Lua switch exists.

### D4. The BPDU channel

**A: 4040 with dst "stp"**, over B, a channel no host opens (e.g. 4039). A
costs hosts on 4040 an event per BPDU (~0.5/s per designated port on their
segment; in Phase 1 the interim exchange repeats every gateway cable's to
all of them), dropped at the destination check as ARP broadcasts already are; B costs every Lua switch one of a
port's 128 channels and widens the mod's window (`receive` drops `channel <
base`).

### D5. Bridge identity and the root tie-break

**A kind field in the bridge ID** (item 4) puts the exchange, then a
multiblock, then a Lua switch first at equal priority with no setting, and
keeps computer 5 and controller 5 apart; a standard ID would get the same
order only by setting `gateway.bridgePriority` (24576) and needs a prefix
anyway. The priority key stays (item 12), for admins who want another root.

### D6. Software switch vs Open vSwitch

| | A: software only | **B: one TAP trunk from the exchange** | C: a TAP per port, OVS is the switch | D: the mod as OVS controller | E: one VXLAN trunk |
|---|---|---|---|---|---|
| Host privilege | none | root once a boot for a user-owned TAP; none at run time | a privileged helper acting on game events | OVSDB: root-equivalent; OpenFlow on an admin-made bridge: none | none; a UDP port |
| Who touches the host | nobody | the admin, once (playbook) | block placement and owners' dialogs | the mod, always; with `fail_mode=secure` host VMs depend on Minecraft (`standalone` falls back to MAC learning) | the admin |
| CC-to-CC traffic | Lua tables, lossless | stays in the software switch | crosses Ethernet: lossy, or a private encapsulation | as C | as B |
| Spanning tree | ours | ours; the TAP is an edge port, no shared tree | one tree with OVS's RSTP, BPDUs translated | as C | as B |
| Platforms | everywhere | Linux with host setup, like TUN | Linux | OVSDB: Linux; OpenFlow: any OVS | any OS |
| Effort | — | ~2-3 days | 1.5-3 weeks plus security review | weeks | ~1 day on top of B |

**A everywhere, B beside it where an admin wants it.** B keeps the rules: no
game event touches the host, OVS's `trunks=` is a boundary outside the game,
one attachment closes no physical loop, and any L2 taking a VLAN trunk works.
C lets players drive root config and needs RSTP interop. D over OVSDB is
root-equivalent; over OpenFlow it is unprivileged but a large protocol with
C's interop: rejected for complexity. E (unauthenticated UDP, may clash with
OVS's VXLAN port) is a later transport under the same port, at most.

## The spanning tree

**Protocol.** Roles root, designated, alternate, backup, disabled; states
discarding, learning, forwarding; priority vectors {root ID, root path cost,
sender bridge ID, sender port ID, receiving port ID}. The engine is a
deterministic `step(state, event, now)` (events: BPDU, tick, port up or
down, `linkLost`) returning state, BPDUs out and port states, with per-port
fdWhile, rrWhile, rbWhile, tcWhile, rcvdInfoWhile and flags proposing,
proposed, sync, synced, agreed; roles are a pure function of stored vectors.

**BPDUs** go on channel 4040 untagged, fields and IDs as in item 4; `src` is
for display ("12:back", "s7:3", "g:5"), identity is the bridge and port ID.
STP bridges consume them; non-STP elements (the interim exchange, a Lua
switch with STP off) pass them on like a hub; hosts drop them at the
destination check (`lib/net.lua:428`). Bridges don't learn from BPDUs, drop
them on other channels and skip VLAN filtering for them (native "none"
still hears 4040). Designated ports send a hello every 2 s; other ports send
only agreements, TCs and one BPDU when they come up, whatever their role.

**Numbers, costs, timers.** A Lua switch numbers sides top 1 to back 6; a
multiblock keeps the controller's number (port NBT); the exchange gives a
joining block the lowest free number, not persisted (a restart may swap two
co-cabled blocks' roles). A port costs 20000 (802.1t's 1 Gb/s), wireless or
ender 200000. Set at the root: hello 2 s, forward delay 6 s, max age 10 s;
info lost after 3 hellos; at most 6 BPDUs a second per port. Java timers
count server ticks, not `System.nanoTime`, if CC's Lua timers do (item 11).

**Link type and edges.** Root and alternate ports are mostly silent, so the
receiving port judges: it sets `p2p` in its agreement only if, since its
link came up, it has heard exactly one other bridge port. A discarding
designated port proposes and forwards at once only on a `p2p` agreement
from that port; a second agreement or bridge port, or no `p2p`, makes the
link shared (12 s) until the port goes down or its info ages out. Sound:
every port announces itself on coming up and forwarding designated ports
send hellos, so no bridge port joins unheard, and an agreeing port is
discarding or toward the root. A backup port that has heard no bridge port
but its sibling forwards at once when the sibling goes. Access ports use
auto-edge on every switch (discarding one hello, edge if no BPDU heard,
cleared by the first); trunks are edge only if set; BPDU and root guard are
optional per port.

**Healing.** A bridge reacts at once to losing its own port (block broken,
chunk unloaded, modem detached) or to a neighbour's port peripheral leaving
(Decision 9), else when the neighbour's info ages out, ~6 s. So a cut or a
broken block between two Java ports heals in under 1 s; a cut whose reacting
side has no signal (Lua to Lua, a Java root port facing a Lua switch) in
~6 s; a shared cable in up to 18 s. A Lua switch maps a `ccnix_port_*`
detach to the port whose modem listed it (`getNamesRemote`) and, as in
Decision 9, raises `linkLost` only if it names that port's stored neighbour; sharing its own modem as `computer_N` would signal Lua-to-Lua cuts
but lets anyone on the cable `shutdown` it: not recommended. Computers on
the cable see `ccnix_port_*` in `peripheral.getNames()` (harmless).

**Topology change.** Only a non-edge port going to forwarding starts one: the
bridge sets `tc` on its root and designated ports for 2 hellos and flushes
MACs on its other non-edge ports; a bridge hearing `tc` flushes all but that
port and its edge ports and passes it on. The exchange flushes `macs`, not
ARP.

**The exchange.** Target: each block a port, the gateway host an internal
port always forwarding; floods go to every forwarding port but the ingress,
replacing `onePerNetwork()`; two blocks on one cable are designated and
backup. Interim (D3 B): in `fromCc`, after the standby check (and item 1's
fix), before VLAN mapping and learning, a BPDU on the base channel goes out
untagged through `onePerNetwork(from)`, and a `tc` flushes `macs` but for
the ingress port. Without it a BPDU rides the ingress block's native VLAN n
(:246): tagged at blocks with another native (native none included), dropped
at blocks not carrying n (:283), filtered when heard on a native-none cable
(:246-247), and its src is learned (:253).

**A Lua switch in the tree.** Non-edge ports start discarding; loop guard
(a root or alternate port that stops hearing BPDUs discards) is on, and
Java bridges use it toward kind 2, since a time-sliced Lua switch can stall
for seconds; one that sees a gap over a hello between events discards its
non-edge ports and re-syncs first. The hook buffers each `modem_message`,
handles BPDUs at once, forwards at most N frames per event, schedules the
rest with `os.queueEvent("switch_drain")`, returns every event to the
program below (lib/net included) and re-checks `os.clock()` on each. Floods
are capped per port (50/s); it warns if root while hearing kind 0 or 1.

## The host trunk

**Shape.** One optional exchange port, `TapPort implements Gateway.Port`, on
a TAP the admin plugs into an OVS bridge (or a `vlan_filtering` Linux
bridge) as an 802.1Q trunk. Host frames enter `fromCc` like a block's:
untagged at base+0, VID n at base+n, `TapPort.nativeVlan()` = `[l2].native`
(0 for none), so a tagged native frame is refused (:246) and `out()` (:292)
tags the same way. CC-to-CC traffic never reaches it.

**Setup.** A second `TunHelper` instance runs `<tun.helper> --tap
<[l2].device>` (beside the TUN one in TUN mode, shown apart in `/ccnix`);
`ccnix-tun.c` gains `--tap` (IFF_TAP for IFF_TUN at :88, same framing, room
for 1518-byte tagged frames). `ccnix-tap-setup` (item 25), as root once per
boot, makes the TAP the server user's and sets Port keys only: on OVS
`vlan_mode=trunk` for native 0 or `native-untagged tag=<n>`, `trunks=` with
ranges expanded, `rstp-port-admin-edge`; never Bridge keys (`forward-bpdu`,
default false, already stops reserved multicast floods). Under 802.1D or
kernel STP (no edge setting) each link-up waits twice the forward delay
(30 s by default). A Linux bridge must filter VLANs; the TAP loses PVID 1.

**Config,** `[l2]`: `device = ""` (off), `vlans = ""`, `native = 0`, `mtu =
1500`, a MAC cap (256), inbound rate limits; `vlans` within `gateway.vlans`,
never VLAN 1; one device per server. `/ccnix` shows the helper, per-VLAN
counts, drops by reason, host MACs and (information only) the host's root
bridge ID last heard.

**Addressing.** A bridged VLAN's subnet must not overlap `gateway.networks`
or the gateway's network, so real hosts can't go out through a player's CC
router and the gateway: NAT mode already drops their sources (`Nat.java:155`);
in TUN mode `ccnix-tun-setup` gains a FORWARD drop (item 25) for packets from
the TUN device whose source is outside the gateway's network and
`gateway.networks`. CC hosts on a bridged VLAN reach outside
through the lab's routing; CC routers can still route lab to CC networks.

**Translation**, an allowlist both ways like `Ipv4`. Only ARP (sha and tha
mapped) and IPv4 (through `Ipv4.fromCc`/`toCc`) cross; other CC types
(`"stp"` too), other ethertypes, IPv4 multicast, packets over `[l2].mtu` and
host fragments are dropped and counted (TCP fine at MSS 536, big UDP fails).
A CC source seen on a carried VLAN maps to `02:cc:` plus a hash of a
per-world salt and the string (stable without state; a collision with a
live entry refused and counted; a capped reverse table). `"*"` is broadcast,
a real MAC is `"eth:aa:bb:cc:dd:ee:ff"` in CC, any other CC dst is dropped.
`fromCc` drops frames from non-TAP ports whose src or ARP sha starts `eth:`,
before learning; the TapPort drops host frames from multicast or `02:cc` MACs.

**Spanning tree.** No shared tree: the TapPort is an edge port passing no
BPDUs (01:80:c2:00:00:00-0f dropped, counted), safe before Phase 2. No BPDU
guard: a host bridge on (R)STP sends BPDUs out edge ports every hello, and
one trunk has no second path to find. VLAN-merging loops (bridged VLANs
joined on the host and again in CC, say by Lua re-sending 4050 on 4060) are
seen by neither tree; rate limits and the MAC cap bound them, and `/ccnix`
counts host frames whose src was learned on a CC port.

**Guards.** OVS's `trunks=` is the hard boundary (empty means all VLANs, so
the playbook refuses it); the mod's list is a second check. Bridged VLANs
must be dedicated lab segments, never the host's management or LAN: CC Lua
can send any UDP (rogue DHCP, ARP claims, scans).

## Trade-off Analysis

The plan spends its risk on the spanning tree and buys it down where tests
are cheap (a pure engine, shared vectors, sims that notice frames going
round), does the cheap part first, and heals fast with what CC offers (a
peripheral per Java port) rather than faster hellos. It declines per-VLAN
trees, MSTP and changes to lib/net for switches. It meets Open vSwitch at
one edge the admin sets up: CC traffic stays lossless and off the host.

## Consequences

- **Easier:** separate segments on one network; redundant links that heal;
  big custom switches in survival; a standby that works through another
  switch; on Linux hosts the admin sets up, CC VLANs shared with real VMs.
- **Harder:** two STP engines; ~0.5 BPDU events a second per designated port a host hears (every gateway
  cable's until the exchange runs STP); two
  pack-wide updates; redundant trunks must carry the same VLANs, and a
  switch spanning two gateway cables blocks one port even with no shared
  VLAN; a switch in an unloaded chunk partitions the network; `ccnix_port_*`
  peripherals visible on bridge cables; an Ethernet translator; bridged VLANs
  open host segments to CC players, and CC routers can route into them.
- **Revisit:** MSTP-lite on `inst`; an L3 switch or in-band management
  (lib/net hard-codes `transmit` in `N.fromConfig`); six-way port faces; a
  hop count if loop guard isn't enough; VXLAN; IPv4 fragmentation on the
  host trunk; TAP uplinks on switch blocks; methods on the port peripheral.

## Open decisions for the user

1. **Which switches (D1).** Recommended: C, the Lua switch first (ccnix
   0.4.0), then the exchange as a bridge, then the blocks; B only if small
   networks don't matter.
2. **The protocol (D2).** Recommended: simplified RSTP, one instance; hello
   2 s, forward delay 6 s, max age 10 s; proposal/agreement with the `p2p`
   flag in the first engine (without it, 12 s on non-edge ports).
3. **The exchange (D3), identity (D5).** Recommended: interim pass-through,
   then one bridge with the extraction; the fixed-width ID with a kind.
4. **Multiblock size and UI.** Recommended: `switch.maxBlocks` 64,
   `switch.maxPorts` 32; ports face horizontally; a port dialog on
   right-click, a controller dialog with a scrolling port list; an unformed
   port carries nothing; two ports of one switch facing each other ignored.
5. **The neighbour-gone signal (Decision 9).** Recommended: yes, on switch
   ports and gateway blocks too, so a backup block takes over at once on a
   cable cut; no methods on the peripheral at first.
6. **Interop (D4).** Recommended: 4040 with dst "stp"; no hop count in data
   frames; wireless ports at cost 200000.
7. **Limits, recipes, look.** Recommended: only controllers count against
   `switch.maxPerPlayer` (5), ports and chassis capped per switch; any
   player's port may join, settings are the controller owner's and level-2
   ops'. Chassis: iron and stone (4); port: a full wired modem, iron, gold;
   controller: a computer or full wired modem, gold, a comparator. The port
   reuses the gateway block's model and plugged state in its own colour;
   chassis and controller get plain textures.
8. **Storm guard.** Recommended: 4096 frames pending on the executor at
   most, the rest counted in `/ccnix`; a cap on `Gateway.macs` (:109,
   uncapped today, so a Lua host can flood it).
9. **Lua switch defaults.** Recommended: the hook (`service` possible), STP
   and loop guard on, 50 floods a second, BPDU and root guard off; with STP
   off it floods BPDUs like a hub.
10. **The two bugs found.** Recommended: fixed first (items 1 and 2).
11. **Open vSwitch (D6).** Recommended: B, here rather than in ADR-0004, as
    Phase 4 after Phase 2; C and D rejected, E later if ever. One TAP, on
    the exchange; salted-hash MACs, real ones as `eth:`; bridged VLANs
    op-only (level 2) on gateway blocks (any owner picks any VLAN today);
    oversize and fragments dropped; the playbook attaches to the admin's
    named bridge and creates none.

## Action Items

Every commit: `python sim/run.py` and `--check` in ccnix, `./gradlew test`
in ccnix-mod. Pointers bumped after every release in either repo, ccnix-mod's
`ccnix/` first, then ccnix's `mod/`. Versions assume this phase order.

### Phase 0: the safety net (no decision needed): ccnix-mod 0.11.2, ccnix 0.3.6

1. [ ] ccnix-mod 0.11.2: `seen()` after the standby check; a test where the standby block hears the same payload object first.
2. [ ] ccnix 0.3.6: lib/net's hook re-arms a tick whose timer was dropped (the clock re-checked on each event); a sim with a full queue checking ARP retries and TCP retransmission.
3. [ ] `sim/lib/networld.lua` lifted from the copies in `sim/net_stack.lua`, `net_tools.lua` and `net_dns.lua`, with a modem model (`open()`, the 128 limit, a computer's modems hearing each other, own sends ignored, remote peripherals and `peripheral_detach`) and a 256-event queue that drops timers too. Existing sims unchanged.

### Phase 1: engine and Lua switch: ccnix 0.4.0, ccnix-mod 0.12.0

4. [ ] The vectors format: event sequences in (BPDUs, ticks, port up and down, `linkLost`), roles and states out, a Lua table file the JUnit test reads from the `ccnix/` submodule. Its first cases fix the BPDU, `{ ccnet=1, dst="stp", src=<port MAC>, type="stp", data={ v=2, inst=0, root, cost, bridge, port, role, proposal, agreement, p2p, learning, forwarding, tc, age, maxAge, hello, fwdDelay } }`, and the IDs: bridge `"%05d.%d.%010d"`, priority (0-61440 in steps of 4096, default 32768), kind (0 the exchange, number 0; 1 a multiblock, the controller's registry ID; 2 a Lua switch, the computer ID) and number, fixed width so string order is numeric order in both languages without CC's integer/double ambiguity; port `"%03d.%04d"`, priority (default 128, steps of 16) and number 1-4095.
5. [ ] `lib/stp.lua` (~400 lines) and `sim/stp.lua` on the vectors: root by priority then ID, a ring of three, two ports on one cable (backup and its takeover), auto-edge and its loss, the `p2p` agreement (a second agreement or bridge port makes it shared; announce on port up), rrWhile and rbWhile, info ageing (~6 s), `linkLost` (alternate to root in under 1 s), TC flush, loop guard.
6. [ ] `lib/switch.lua` and `sim/net_switch.lua` with lib/net hosts: access isolation, learning and ageing, a trunk between two switches (channel rewritten, tagged-native dropped, unlisted VLAN filtered), router on a stick, the channel budget (127 accepted, 128 refused, lib/net interfaces counted), a loop with STP off trips the harness and with STP on heals after a cut, hosts' rx unchanged by BPDUs, hellos survive a full queue, `switch_drain` leftovers with lib/net on the same computer still served, a `ccnix_port_*` detach naming a port's stored neighbour raises `linkLost`, while another bridge port's on the same cable and other detaches don't, a switch stalled 8 s then resumed, config parsing.
7. [ ] `pc/switch.lua`, help from its top comment; `switch.boot` in `deploy/boot.lua`, autostart in `bin/init.lua`, `deploy/setup.lua`, `deploy/install.lua`; lib/net's header reserves `"stp"`; a Switches paragraph in `doc/network.txt` (the `ccnix_port_*` peripherals included); `deploy/version` 0.4.0.
8. [ ] ccnix-mod 0.12.0: the interim pass-through (The exchange); the executor cap with a counter in `/ccnix`; tests: a BPDU crosses blocks with different natives and native none, is never learned, isn't relayed twice via a standby block, and a `tc` flushes.
9. [ ] In game: two modems of one computer on one cable end as backup; a loop between two Lua switches is cut and heals in ~6 s when a cable is broken; a Lua switch with ports on two gateway networks blocks one, even when the blocks share no VLAN; `switch` counters under traffic.

### Phase 2: the exchange as a bridge: ccnix-mod 0.13.0, ccnix 0.4.1

10. [ ] Extract `core/Switch`; `Gateway` keeps the host role behind its facade; every existing test passes unchanged (the oracle).
11. [ ] `core/Stp.java` on the shared vectors, on a server-tick clock (first confirm in the jar that CC's Lua timers count ticks).
12. [ ] The exchange runs RSTP; beacons and `onePerNetwork()` retire; blocks hand each other's BPDUs to the engine; port numbers lowest free on join, with a test that renumbering on reload still leaves one designated and one backup; loop guard toward kind 2; standby tests become backup-port and TC tests; the dialog shows role and state and takes cost, priority, edge and the guards; payload protocol "3"; `gateway.stp` and `gateway.bridgePriority` in the config and the playbook.
13. [ ] Gateway blocks register `ccnix_port_0_0_<n>` through `updatePeripherals` and turn `networkChanged` removals of a stored neighbour's name into `linkLost`; a test that unrelated peripherals are ignored.
14. [ ] ccnix 0.4.1: `help network` and `doc/network.txt` describe a gateway block's STP role, state, cost, priority and edge, and its port peripheral.
15. [ ] In game: two blocks on one cable, one backup, taking over at once when the designated block is broken and in under 1 s when the cable between them is cut; a Lua switch whose root port faces a block sees its detach; two blocks whose cables meet through a Lua switch no longer storm.

### Phase 3: switch blocks: ccnix-mod 0.14.0, ccnix 0.4.2

16. [ ] `Structure.java`, pure, and `StructureTest`: limits, two controllers, a split on break, unloaded neighbours.
17. [ ] The blocks, block entities, registry, controller item, `[switch]` config, assets, loot tables and recipes; `ccnix_switch_*` variables in the playbook; each port registers its `ccnix_port_1_<id>_<n>` peripheral.
18. [ ] Storm guards (Decision 8): a port's `receive` only enqueues and drops data only from its own switch's elements; test: a switch port and a gateway block on one cable exchange frames.
19. [ ] Port and controller dialogs reading a status snapshot (not `Service.portStatus`'s blocking wait); payload protocol "4"; `/ccnix switches` and `/ccnix switch <id>` (level 2), `/ccnix switches forget <id>` (level 3).
20. [ ] `SwitchTest`, `StpTest` (a triangle and a square of switches, failover, edge, TC, `linkLost`), with the identity ring off; a `CcWorld` scenario with lib/net hosts on VLAN 10 access ports across two switches and a trunk to the gateway.
21. [ ] ccnix 0.4.2: switch blocks in `help network` and `doc/network.txt`.
22. [ ] In game: build, configure from the controller, a loop of three switches with a Lua switch in it, a cable cut between two switch blocks (alternate to root in under 1 s), a chunk unload and reload keeping port numbers; mark this ADR Accepted (Phase 4 is verified on its own).

### Phase 4: the host trunk (optional, after Phase 2): ccnix-mod 0.15.0, ccnix 0.4.3

23. [ ] `ccnix-tun --tap` (usage check and hint updated) and a second `TunHelper` instance for `[l2].device`; `core/Eth.java` (frame, 802.1Q, ARP, padding, MTU, ethertype and multicast policy) and the MAC mapper (salted hash, collision refusal, reverse table, cap, dst policy); `EthTest`, both spoof refusals included.
24. [ ] `TapPort`, `[l2]` (`mtu` included), rate limits and MAC cap, bridged VLANs op-only on blocks, `eth:` sources refused from blocks before learning, `/ccnix` status; `GatewayTest` with a fake TapPort (untagged at base+0, VLAN mapping, native none, learning, VLAN 1 refused, `02:cc` and multicast sources refused, cap and rate); a `CcWorld` scenario: a lib/net host pings a fake real host through the TAP.
25. [ ] Ansible: `ccnix_l2_device` ("": off), `ccnix_l2_bridge`, `ccnix_l2_vlans` (refused empty when a device is set), `ccnix_l2_native` (0), `ccnix_l2_mtu` (1500, the TAP's and `[l2].mtu`), `ccnix_l2_ovs` (true, else a Linux bridge), the OVS service name. `ccnix-tap-setup`: `ip tuntap add dev <tap> mode tap user <server user>`, MTU, up; on OVS `ovs-vsctl --timeout=10 --may-exist add-port <bridge> <tap> -- set port <tap> vlan_mode=trunk trunks=<list> other_config:rstp-port-admin-edge=true` (native 0) or `... vlan_mode=native-untagged tag=<n> trunks=<list> ...` (native n, refused if 1), `<list>` with ranges expanded and the native kept in it (OVS passes it either way, and the list never ends up empty, which OVS reads as all VLANs); on a Linux bridge, refuse unless `/sys/class/net/<bridge>/bridge/vlan_filtering` is 1, `bridge vlan del dev <tap> vid 1`, `bridge vlan add dev <tap> vid <v>` per VLAN, `vid <n> pvid untagged` for the native. A `ccnix-tap.service` oneshot After= and Wants= the OVS service, before `minecraft.service`; `--remove` (`ovs-vsctl --if-exists del-port`, then `ip link del`) when unset. In TUN mode, the FORWARD drop from the TUN device for sources outside the gateway's network and `gateway.networks`. An `[l2]` section line (as `[nat]` is added) and `{ section: l2, ... }` entries in the settings loop; `[l2]` in the template for new installs.
26. [ ] ccnix 0.4.3: `doc/network.txt` and `help network` on bridged VLANs, the addressing rule, the `eth:` MAC form and the MTU limit; `ip neigh` widths checked.
27. [ ] On the VM: a netns on an OVS VLAN pings, telnets and nc's a CC computer through a gateway block, `[l2].native` set and unset; `ovs-appctl fdb/show` lists the `02:cc` MACs; a host broadcast storm is limited; the TAP's link-up delay with the bridge on RSTP and on 802.1D; the port's carrier across helper restarts.
