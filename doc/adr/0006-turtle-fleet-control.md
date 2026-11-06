# ADR-0006: Reaching turtles at work: status, logs and commands (turtled and turtlec)

**Status:** Proposed (2026-11-06): decisions D1 to D5 below are the user's
to make
**Date:** 2026-11-06
**Deciders:** Dan Theisen

## Context

The user asked (2026-11-06) whether `mine` can run as a ccnix service, how
its logs could reach a log server, and how turtles could be controlled
remotely. Their own sketch: a `turtled` that takes queued stats and logs
and hands out commands, and a `turtlec` on each turtle; or network cable
and wired modems strung along the mine as access points.

What makes this hard:

- **A mining turtle has no free slot.** It has two upgrade sides. One holds
  the pickaxe, the other the Advanced Peripherals chunk controller that
  keeps its chunk loaded; without that, the turtle stops when no player is
  near. The Geo Scanner and crafting table are already swapped in for the
  pickaxe for a moment and swapped back. A modem would have to be too, so
  a turtle on a modem is online only now and then.
- **Wired networks stop at unloaded chunks.** In CC:Tweaked, a cable or
  wired modem whose chunk unloads leaves its network
  (`CableBlockEntity.setRemoved` calls `node.remove()`), so a cable down the
  tunnel only connects while every chunk along it is loaded. Only the
  turtle's own chunk is.
- **Wireless range.** A wireless modem reaches 64 blocks (more high up),
  so not far down a mine. An ender modem reaches any distance, in any
  dimension, but whatever it talks to must be in a loaded chunk too.
- **CC has a real HTTP client, and it needs no modem.** The `http` API
  makes its requests from the Minecraft server itself. In TUN mode
  (ADR-0002) the server's host routes the in-game networks (10.1.0.0/16)
  into the game through the gateway; the user has already loaded Lab-B's
  Lua pages (httpd) from a browser that way. So a turtle can reach an
  in-game web server with no modem at all, from anywhere it's loaded. CC's
  default rules deny private addresses (`$private`), so the server needs
  one rule allowing 10.1.0.0/16 ahead of that.
- **What's there already:** init and services (ADR-0005), with a
  service's output captured into syslog; syslogd, which writes local files
  and forwards to log hosts (ADR-0004); httpd with Lua pages; the network
  stack, telnetd. mine saves its progress (`mine.seg`) and job state, and
  `mine --resume` and `mine reset` carry on after a stop; Ctrl+T (a
  terminate) is safe for it.

## Options considered

1. **CC's HTTP API, through the gateway, to an in-game turtled.** Always
   connected, no slot used, nothing to carry. Needs TUN mode and the HTTP
   rule; turtled's computer must be loaded. NAT mode would need a port
   forward (later, if wanted).
2. **An ender modem swapped in for the pickaxe now and then** (as the
   scanner is), store-and-forward over the ccnet stack. Works without TUN
   or HTTP. Costs a slot's swap each time, an ender modem per turtle, and
   it's offline between windows (no live telnet unless it stays online).
   lib/net would have to cope with a modem coming and going (today an
   interface is bound to a modem side that's always there).
3. **Access points at the homes:** a full-block wired modem in each home's
   wall, joined to a computer with an ender modem there. The home's chunk
   is loaded only while the turtle is in it, so it's online only at homes,
   for a computer and an ender modem per home: option 2 does the same with
   one ender modem per turtle.
4. **Cable along the tunnel back to the base.** Broken by every unloaded
   chunk between (above), and a cable a block to lay and keep clear.
   Rejected.
5. **A modem in place of the chunk controller or the pickaxe for good.**
   The turtle freezes when you leave, or can't dig. Rejected.

## Decision (proposed)

**Option 1 first, behind a transport that option 2 can plug into later.**

### turtled (on a base computer)

- An httpd Lua page, `/turtled`, takes each turtle's check-in (an HTTP POST,
  form-encoded: its ID and label, a sequence number, its status, new log
  lines, results of commands it ran) and answers with the commands queued
  for it and how soon to check in again.
- It keeps, per turtle, the last status, when it was last seen, its
  command queue and recent results (files under `/var/turtled/`).
- It writes the turtles' log lines into syslog under the turtle's name, so
  they land where everything else's does (and are forwarded to the real
  log host, as ADR-0004 does).
- `turtlectl` on that computer (or over telnet): `turtlectl` lists the
  turtles (label, job, where, fuel, last seen), `turtlectl status <t>`,
  `turtlectl log <t>`, `turtlectl send <t> <command...>`.
- Later: a `/turtles` page showing the same in a browser.
- Its computer has to stay loaded: a `/forceload` on its chunk (an op
  command), or a stationary turtle with a chunk controller as the server.

### turtlec (on each turtle, a service under init)

- Checks in every `turtlec.every` seconds (and straight after a command
  ends): status, logs, results out; commands in. A check-in that fails
  (turtled's chunk unloaded, the server down) is just tried again; nothing
  is lost.
- **Logs: the local log file is the queue.** syslogd already writes the
  turtle's log (a service's output is captured); turtlec sends the lines
  added since the last check-in that got through (an offset it saves, which
  survives reboots and outages, bounded by syslogd's rotation).
- **Status:** mine (and later farm, mow) writes a small status file when it
  saves its progress (job, state, home, lane and block, fuel, chests left,
  stats); turtlec sends it.
- **Commands** it runs and reports on: `service start|stop|restart <name>`;
  `mine reset`, `mine haul`; `update` (`ccnix update`, then reboot, after
  which the job carries on as after any reboot); `reboot`; and `run
  <command line>` (its output sent back, cut short). mine runs as a
  service (`service add mine "mine --resume"`), so "stop" is `service
  stop mine`, the same terminate as Ctrl+T.

### The server

- One `[[http.rules]]` entry ahead of the `$private` deny: host
  `10.1.0.0/16`, allow. ccnix-mod's ansible sets it in TUN mode.

### Later: the modem transport (option 2)

If wanted for servers without TUN: turtlec swaps an ender modem in at safe
points (homes, segment ends, every few minutes), checks in over ccnet, and
swaps the pickaxe back; lib/net brings an interface up and down with its
modem.

## Decisions for the user

- **D1. Transport:** HTTP through the gateway (recommended), the ender
  modem, or both.
- **D2. The HTTP rule:** allow 10.1.0.0/16 for every computer on the
  server (recommended; they can reach those hosts over ccnet anyway).
- **D3. Where turtled runs:** on Lab-B, with httpd and the loghost
  (recommended for the lab), or a computer of its own; and how its chunk
  stays loaded (`/forceload` or a chunky turtle).
- **D4. `run <command line>`:** allow any command remotely (recommended:
  it's the user's own server), or only the fixed set.
- **D5. Check-in interval:** 15 s by default.

## Consequences

- Turtles can be watched and steered from the base or a browser, with no
  extra hardware or slot, as long as the server runs in TUN mode.
- Turtles need init, syslogd and turtlec running (setup does that), and
  mine as a service rather than run from the shell.
- It leans on CC's HTTP API and one rule in the server's config; a server
  with HTTP off or in NAT mode needs the modem transport (later).
- No live console over HTTP: `run` gives command output, not a terminal.
  telnet to a turtle still needs a modem.

## Action items

### Phase 1 (once D1 to D5 are decided)

1. [ ] ccnix-mod ansible: the HTTP rule in TUN mode (and its README).
2. [ ] mine: write the status file; run cleanly as a service.
3. [ ] turtled: the `/turtled` page, its store, syslog of turtle logs,
   `turtlectl`.
4. [ ] turtlec: the service, the log offset, status, commands and results.
5. [ ] setup: `setup turtlec` on a turtle, `setup turtled` on the base.
6. [ ] Sims: a fake `http` for turtlec; the page's handler for turtled; a
   round trip (log lines, status, a command and its result).
7. [ ] In game: a turtle mining as a service, its logs on the loghost, a
   `turtlectl send` that stops it and one that updates it.

### Phase 2

8. [ ] The `/turtles` page.
9. [ ] The modem transport, if D1 wants it.
