# ADR-0002: A NAT mode for the gateway, in userland, beside TUN

**Status:** Accepted (2026-10-30); built in ccnix-mod 0.3.0, verified in game (item 14, 2026-11)
**Date:** 2026-10-30
**Deciders:** Dan Theisen

**Decided 2026-10-30:** the jar defaults to NAT; the mode is changed in the
config and Ansible only; a forwarded connection comes from the client's real
address; ops forward only ports in a range the admin sets (none by default),
and the commands tell them the range; no forwards in TUN mode (the admin's
firewall does that); the protection defaults as proposed, every value the
admin's to change, and they apply only to CC computers' connections through
a Network Gateway. The gateway is transport only, with one exception: on
Windows, where there's no resolver to relay to, the gateway answers DNS at
its own address from the Windows resolver.

## Context

The Network Gateway (ccnix-mod 0.2.0) joins CC's wired network to the real
one through a TUN device: `helper/ccnix-tun.c` holds the device, and the
server's kernel routes, forwards and (optionally) masquerades. That needs, once
per boot and as root: `/dev/net/tun`, `CAP_NET_ADMIN` for the device, its
address and routes, the policy rules and table 4040, `ip_forward`, and
iptables for NAT. On a machine we run (the dev VM) that's one systemd unit. On
the hosts most servers run on (game panels such as Pterodactyl/Pelican,
hosted providers, cloud containers) none of it is granted, and a native helper
in a mod jar is awkward to ship through CurseForge. Singleplayer worlds on
Windows or macOS can't have it at all.

Forces:

- **The user wants the simplest thing that works**, and real-protocol
  compatibility: CC hosts keep speaking lib/net's IPv4/TCP/UDP to the gateway
  whatever is behind it.
- **The gateway is transport only** (the user, 2026-10-30): layers 3 and 4,
  no application-layer gateway. Anything above TCP and UDP (DNS, telnet,
  HTTP) is done by ccnix's ROM on the computers; the server doesn't parse or
  answer application protocols for them. **In TUN mode** the mod is the IP
  and transport adapter and nothing else: the gateway's address is the
  server's own on the TUN device, so whatever the host listens on there
  answers, and the mod adds no service of its own. **In NAT mode** the
  gateway's own address may relay port 53 to the server's resolver, at the
  transport layer (bytes and datagrams passed through unread); DNS sent to
  any other address is never intercepted. The one exception to the rule:
  on Windows, which has no resolver address to relay to, the gateway
  answers A and PTR queries at its own address from the Windows resolver.
- **The gateway's seam is already there.** `Gateway` speaks real IPv4 bytes to
  one interface, `Gateway.Tun` (`write(byte[])` out, `fromTun(byte[])` in).
  `TunHelper` is one implementation; the tests' `CcWorld.kernel()` is another,
  a fake kernel that answers ping at the gateway, hairpins CC traffic and
  collects the rest. A userspace network can be a third, with `Gateway`,
  `Ipv4`, ARP, ports and lib/net unchanged.
- **Nothing in the game may harm the host.** Settled in 0.2.0: ops' routes
  never reach the kernel. A NAT mode makes every CC
  computer a client on the server's own IP, so abuse (scans, spam, the cloud
  metadata service at 169.254.169.254) has to be designed out, not left to
  the admin.
- **Admin vs ops.** 0.2.0 split them: the admin (config, Ansible) owns what
  touches the host; ops (permission 3) get bounded, opt-in commands
  (`gateway.opRoutes`, off by default).
- **The safety net.** ccnix-mod's 45 tests, among them `LibNetTest`, which runs
  lib/net in Cobalt against the gateway and a fake kernel; ccnix's sims (1452
  checks). Neither touches a real socket today.

Method: the 0.2.0 code read in full (the gateway, `Ipv4`, `TunHelper`,
`Service`, `OpRoutes`, `CcnixCommand`, the play), and the userland options
compared below. No reviewer fan-out: the decision is one subsystem.

## Decision

1. The gateway gets two **modes**, `gateway.mode = "tun" | "nat"`: TUN as now,
   and NAT, a network in the server process with no privileges, no helper and
   no host setup.
2. **NAT is a userspace kernel behind `Gateway.Tun`** (`ccnix.gateway.core.Nat`),
   in Java, and **transport only**. It terminates CC's TCP connections and UDP
   flows and re-makes them as ordinary Java sockets (`Socket`,
   `DatagramChannel`) from the server, as slirp and passt do, carrying the
   bytes and datagrams as they are: it never looks inside them. It also
   answers ping at the gateway's address and forwards between CC networks
   (what the kernel does in TUN mode). DNS from CC to any resolver it names
   is a UDP flow like any other, never redirected.
3. **What NAT mode can't do, it says:** no ICMP to the outside (Java has no
   ICMP or per-socket TTL): an echo for an outside address gets "net
   unreachable" from the gateway, so ping says so and traceroute ends at the
   gateway with !N; one public address, the server's; nothing from outside
   gets in except through port forwards.
4. **Outbound policy, on by default in NAT mode:** destinations denied unless
   allowed: 0.0.0.0/8, 10/8, 100.64/10, 127/8, 169.254/16, 172.16/12,
   192.168/16, 224/4, 240/4, and port 25 (`nat.deny`, `nat.allow`, CIDR with
   optional ports, as CC:T's `http.rules` think about it); at most 16 open
   connections and flows per CC address (`nat.maxPerComputer`) and 256 in all
   (`nat.maxTotal`); idle TCP closed after 10 minutes (`nat.tcpIdle`), UDP
   after 60 seconds (`nat.udpIdle`). Every value is the admin's (config,
   Ansible). They apply only to CC computers' connections through a Network
   Gateway, never to the server's own or its players'; the config says so.
   Only CC sources in `gateway.networks` (and the gateway's own network) are
   carried.
5. **Port forwards (NAT mode):** `nat.forwards = ["25570/tcp -> 10.1.1.10:23"]`.
   The server listens on the port; a connection that comes in is made on the
   CC side to the target, from the real client's address (the CC host's
   default route brings the replies back to the gateway). UDP forwards keep a
   flow per outside peer.
6. **Ops' forwards:** `/ccnix forward` (level 2) lists them; `/ccnix forward
   add <port>[/tcp|/udp] <address>:<port>` and `/ccnix forward del
   <port>[/tcp|/udp]` (level 3) change them, saved to the config, only with
   `nat.opForwards` (default **false**) and only on ports in
   `nat.opForwardPorts` (a range such as `"25570-25579"`; default empty:
   none, until the admin names the ports the host allocated). The commands
   tell ops the range: `/ccnix forward` lists it, and a refused `add` says
   which ports are allowed. Targets must be in `gateway.networks`. **No
   forwards in TUN mode**, the admin's or ops': the commands say so, and an
   admin who wants them configures the host's firewall.
7. **The mode is the admin's:** config (`gateway.mode`), set by Ansible
   (`ccnix_gateway_mode`); `/ccnix` shows it. In NAT mode the play doesn't set
   up the TUN device (and takes an existing one down with a new
   `ccnix-tun-setup --remove`); `Service` starts no helper.
8. **One list of CC networks for both modes:** `gateway.networks` (Ansible
   `ccnix_cc_networks`, which replaces `ccnix_tun_networks` and is also what
   `ccnix-tun-setup` is given). Ops' routes must be inside it in either mode;
   in TUN mode the kernel's routes are still checked as now.
9. The jar's default mode is **NAT**: a fresh install works anywhere, safely,
   with nothing to set up. The playbook defaults to TUN, as the dev VM is now.
10. **A DNS relay at the gateway's address, NAT mode only** (the user,
    2026-10-30): UDP and TCP to `<gateway>:53` are relayed, unread, to the
    server's configured resolver (`nat.dnsRelay = "system"`: the first
    `nameserver` in `/etc/resolv.conf`, such as systemd-resolved's 127.0.0.53
    or Docker's 127.0.0.11; or an address; `""` turns it off). It's a port
    relay like a forward, not a DNS server: the mod never parses a query.
    The relay's target is the admin's, so the outbound deny list doesn't
    apply to it; CC can't choose it. `ip dns 10.0.0.1` then works on hosts
    whose provider blocks outbound DNS. With no resolver found (no
    `resolv.conf` and no address set) port 53 answers port unreachable and
    CC computers name a resolver themselves. **On Windows** (the user,
    2026-10-30; the only exception to transport-only) there's no resolver
    address to relay to, so the gateway answers A and PTR queries at its
    own address from the Windows resolver (Java's `InetAddress`, which asks
    it), and anything else with NOTIMP. TUN mode has no relay: what the
    host serves at the gateway's address is what there is.

Items 1–4, 7, 8 and 10 are decided unless objected to; 5, 6 and 9 have
choices, below and in the chat.

## Options Considered

### D1. Where the userland network runs

| | A: Java userspace kernel behind `Gateway.Tun` | B: Go helper with gVisor's netstack, over the helper pipe | C: passt / slirp4netns as the helper | D: DPDK | E: a proxy protocol in lib/net (CC programs ask the gateway to connect) |
|---|---|---|---|---|---|
| Complexity | a TCP endpoint mirroring lib/net's (no options, MSS 536, go-back-N), UDP flows, ICMP echo, policy: ~700 lines | small glue; gVisor does TCP | none of ours | very high | moderate, in both repos |
| Privileges | none | none | none (user namespaces, often blocked in containers) | root, hugepages, a NIC bound to VFIO | none |
| Ships as | the mod jar | a native binary per OS and CPU in the jar, run from a folder hosts often mount `noexec` | a distro package the host lacks | — | the jar and ccnix |
| Platforms | everywhere Java runs, singleplayer too | where we build binaries | Linux | Linux, dedicated NIC | everywhere |
| Verification | `LibNetTest`-style: lib/net in Cobalt, through the gateway, to real loopback sockets | the same, plus a binary to build in CI | integration only | — | sims and tests, new protocol |
| Blast radius | new files; `Gateway` and lib/net unchanged | a build toolchain | none | — | every program that connects: `net.connect` stops being TCP |
| Familiarity | lib/net's TCP, ported | Go, gVisor's API | — | — | ours |

**A.** It's the only one that needs nothing from the host and ships in the jar.
B's netstack is better TCP than ours, but our peer is always lib/net, whose TCP
is deliberately small, so the endpoint we need is small too; native binaries
are the cost A avoids. C is Linux-only and rarely installed. D solves
throughput with more privilege, the opposite problem. E breaks the rule that CC
speaks real protocols (and `nc` to a real host stops being TCP).

### D2. Where NAT plugs in

| | A: a `Gateway.Tun` implementation, IPv4 bytes in and out | B: inside `Gateway`, on lib/net's tables before `Ipv4.fromCc` |
|---|---|---|
| Complexity | checksums on the way out (`Ipv4` has them) | no byte conversion |
| Blast radius | `Gateway` untouched; `Service` picks the implementation | `Gateway` grows a second path for every packet |
| Verification | the existing tests run unchanged against TUN; NAT gets its own | every gateway test needs both modes |

**A.** The seam exists and is tested; the fake kernel in `CcWorld` proves the
shape. The cost (computing checksums we then check) is nothing at CC's rates.

### D3. ICMP to the outside in NAT mode

| | A: none (ping times out beyond the gateway) | B: answer echoes for outside addresses from the gateway | C: unprivileged ICMP sockets |
|---|---|---|---|
| Honesty | true | lies about reachability | true |
| Feasible | yes | yes | not from Java; and `ping_group_range` is usually closed in containers |

**A**, made explicit: the gateway answers an outside echo with "net
unreachable" rather than silence, so ping and traceroute say where they
stop. Documented in `help network`: in NAT mode `nc host port` tests
reachability. (`ping 10.0.0.1` still answers: the gateway is real.)

### D4. Inbound

| | A: port forwards (config, ops opt-in) | B: none | C: the whole server address mapped to one CC host |
|---|---|---|---|
| Use | telnet into a lab PC, a CC web server | outbound only | one host only, every port |
| Risk on a shared host | ports the admin allows, bound by the server's process | none | binds everything |

**A**, with the user's shape: ops add forwards only if the admin allows it
(`nat.opForwards`, off) and only on ports the admin lists, because hosts
allocate specific ports and the server's own (game, query, RCON, voice) must
stay out of reach.

### D5. Mode selection

| | A: config + Ansible only | B: also `/ccnix mode` at level 4 (console/admin), editing the config |
|---|---|---|
| Matches 0.2.0's split | yes: host-facing settings are the admin's | partly: a level-4 op could switch, and the next play run switches back |
| Effort | a key and a variable | plus a command |

**A** recommended: switching to TUN needs the host set up first, which no
command can do; the user's call (question 2).

## Trade-off Analysis

The pass spends its risk on one new piece of code, the userspace TCP endpoint,
and buys it down with tests that are cheap here: lib/net in Cobalt talking
through the real gateway to real loopback sockets (Phase 0 builds that
harness before the endpoint exists). It declines to touch lib/net, the frame
format, `Gateway` or `Ipv4`: CC hosts can't tell the modes apart except by
what the outside can do. It declines a better TCP (gVisor) because the only
peer is lib/net, and it declines every application-layer helper: those belong to the ROM,
where they can be updated with `ccnix update` instead of a mod release. The
one service at the gateway's address in NAT mode, the port-53 relay, is a
transport relay to a resolver the admin already runs, not a DNS
implementation; TUN mode has none. Security is designed in rather than configurable-to-safe:
the deny list, limits and opt-in forwards are defaults, because the people
most likely to run NAT mode (hosted servers) are the least likely to read the
config.

## Consequences

- **Easier:** the gateway on any host, in a container, in singleplayer; no
  helper, no root, no setup script for most users; CurseForge distribution of
  a mod that just works; DNS through the host's own resolver (the relay) where
  a provider blocks outbound DNS.
- **Harder:** a second TCP implementation to keep in step with lib/net's
  (shared test scenarios keep them honest); two modes to document, with
  different answers to "can I ping it?" and "can I reach it from outside?";
  a policy surface to maintain; in TUN mode, DNS at the gateway's address
  is only there if the host serves it on that address.
- **Revisit:** IPv6 outbound (the server's sockets may prefer it: the VM's
  broken IPv6 route says pick IPv4 explicitly); bandwidth limits if limits by
  count aren't enough; whether TUN mode wants forwards too (it can route, so
  probably not); retiring `ccnix_tun_networks` after one release.

## Action Items

Phase 0, safety net (no decision needed)
1. [x] `CcWorld` grows an "internet" on loopback: a real echo TCP server, a UDP echo, a DNS stub; tests allow loopback in policy explicitly. ~120 lines. Repeatable twice before anything else.
2. [x] A test that today's `LibNetTest` passes byte-for-byte with `Tun` behind an interface the mode picks (the refactor's oracle).

Phase 1, the seam (no decision needed)
3. [x] `Service` chooses the `Gateway.Tun` implementation from `gateway.mode`; TUN behaviour unchanged; `/ccnix` shows the mode. ~40 lines; tests: all 45 unchanged.
4. [x] `gateway.networks` in the config (default `10.1.0.0/16`); `OpRoutes` checks it in both modes, plus the kernel in TUN mode. ~30 lines; `OpRoutesTest` extended.

Phase 2, NAT (after acceptance)
5. [x] `Nat`: ICMP echo at the gateway, hairpin between CC networks, UDP flows to `DatagramChannel`s. ~200 lines; tests: ping the gateway, A to B through the gateway, `nc -u` to the loopback echo.
6. [x] `Nat`: the TCP endpoint (SYN only after the outside socket connects, RST if it can't; data both ways in order; FIN each way; keepalive answered; idle timeout). ~400 lines; tests: lib/net's own scenarios (3000 bytes each way, half-close, refused, the far side vanishing) against the loopback server.
7. [x] Policy and limits (decision 4). ~100 lines; tests: each denied range and port refused (RST / port unreachable), the limits, an allowed connection; ccnix's netdb through NAT to a loopback DNS stub (a UDP flow like any other).
Phase 3, forwards (after acceptance)
8. [x] The DNS relay (decision 10): `nat.dnsRelay`, the resolver from `/etc/resolv.conf`, UDP and TCP relayed unread, exempt from the deny list; on Windows, A and PTR answered from the Windows resolver. ~150 lines; tests: ccnix's netdb with `ip dns <gateway>` through the relay to a loopback DNS stub; a query to another address isn't touched; no resolver found: port unreachable; the Windows answerer with a stub resolver.
9. [x] `nat.forwards`: TCP and UDP, the real client's address kept. ~200 lines; tests: a loopback client reaches telnetd-like listener on a CC host.
10. [x] `/ccnix forward` commands with `nat.opForwards` and `nat.opForwardPorts` (decision 6). ~120 lines; tests: the checks as `OpRoutesTest` does them.

Phase 4, admin, docs, siblings
11. [x] Ansible: `ccnix_gateway_mode` (default `tun`), `ccnix_cc_networks` (replaces `ccnix_tun_networks`), `ccnix_nat_op_forwards` (false), `ccnix_nat_op_forward_ports` ([]), `ccnix_nat_forwards` and `ccnix_ansible_forwards` (as routes), `ccnix_nat_dns_relay` ("system"), the limits and deny/allow lists; in NAT mode the TUN unit is disabled and `ccnix-tun-setup --remove` run.
12. [x] Docs: the mod's README and runbook (the two modes side by side: what works in each), ccnix's `help network` and README (no ping beyond the gateway in NAT mode; `ip dns <gateway>` in NAT mode, a real resolver in TUN mode unless the host serves DNS on the gateway's address). ccnix itself: no code change expected.
13. [x] ccnix-mod 0.3.0; pointers bumped (ccnix-mod's `ccnix/`, then ccnix's `mod/`).
14. [x] Verified on the dev VM in both modes, and in a singleplayer world (NAT); mark Accepted. 2026-10-31: the VM in TUN mode, and singleplayer on Windows (an op route, DNS A and PTR through the Windows answer, TCP out, the deny list, an op port forward, ping: the gateway answers, past it "administratively prohibited" and the note); then the VM in NAT mode (reported by the user 2026-11-05).
