# ADR-0006: Reaching turtles at work: status, logs and commands (turtled and turtlec)

**Status:** Proposed (2026-11-06): decisions D1 to D10 below are the user's
to make
**Date:** 2026-11-06; scheduled drivers folded in 2026-11-20 (from
ADR-0021, withdrawn; issue #343)
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

**Scheduled drivers (added 2026-11-20, issue #343).** The model driving
turtle 10 passed on a request from the player: run "agentic drivers" on a
turtle at set future times, each with its own model, prompt and limits,
holding an exclusive lock on the turtle's motor functions and its
"primary thought" while it runs. More an `at` than a `cron`. ADR-0021
designed that as a queue on each turtle. The owner chose instead that
scheduled work runs from a central controller, and turtled is that
controller, so the queue joins this ADR. ADR-0021 (withdrawn) keeps the
long form: what ccnix had then, with file and line references, the
options for each question, and the sims to build on.

Some words used below:

- **A driver** is one run of the claude harness (`turtle/claude.lua`)
  with one goal, started by a job rather than by a player at the
  keyboard. It ends when the goal ends.
- **A job** is a command queued on turtled for one turtle, with a time to
  run it.
- **Motor functions** are the turtle calls that change the world or the
  turtle: moves, turns, digs, placements, attacks, drops, sucks,
  equipping, refuelling, crafting and the selected slot.
- **Primary thought** is what one model at a time should own on a
  turtle: the memory files (`/claude/memories`), the goal file
  (`/claude/resume.txt`) and turtlelib's job journal (`.job`).
- **A chore** is a driver with tighter rules: read-only memory, digs only
  in its box, no lifting of the protected-area checks.

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

### Scheduled drivers

turtled keeps the time and the queue; a turtle runs what it's handed and
reports back. A job is a queued command with a time on it, so it rides
the check-in that already carries commands.

**On turtled (the controller):**

- **The queue:** a file a job, `/var/turtled/jobs/<id>`, a field a line:
  ```
  id: 7
  turtle: miner-3
  at: 2026-11-21T06:00:00Z
  window: 60
  rerun: no
  queued: 2026-11-20T22:14:05Z by console
  cmd: claude --once --model haiku --steps 40 --minutes 15 --cost 0.50 --chore --box 0,60,0,20,70,20 sort the chests at the base
  ```
  Times are UTC, by turtled's own clock (`lib/realtime`, so the tick rate
  doesn't matter). Turtles keep no time for the queue.
- **The commands** are `turtlectl`'s, named after POSIX's `at`, `atq` and
  `atrm`:
  - `turtlectl at [-w minutes] [-r] <turtle> <time> <command...>` queues
    a job. The times are a subset of POSIX `at`'s: `now + N
    minutes|hours|days`, `HH:MM`, `noon`, `midnight`, `tomorrow`,
    `YYYY-MM-DD HH:MM`.
  - `turtlectl atq [turtle]` lists jobs: ID, turtle, time, who queued
    it, and for a running one its process group on the turtle.
  - `turtlectl atrm <id>...` removes waiting jobs, and stops a running
    one (as `stop` below).
  - `turtlectl stop <turtle>` stops what that turtle's driver is doing;
    `turtlectl hold [turtle]` and `turtlectl release [turtle]` pause and
    resume handing out jobs, for one turtle or the fleet.
- **Handing a job out:** at a turtle's check-in, a due job goes out as a
  command. If the turtle answers "busy" (its lock is held, below), the job
  stays and goes out again at the next check-in, until its `window`
  (default 60 minutes) runs out. Then it's "missed": logged, said in chat,
  removed. One driver per turtle at a time; turtles run theirs side by
  side.
- **A turtle that's down** (server off, chunk unloaded) doesn't check in,
  so its jobs wait inside their windows like any other.
- **The ledger**, `/var/turtled/ledger`: one tab-separated line a run
  (date, job, turtle, model, how it ended, calls, minutes, fuel, tokens
  and dollars), from the result the turtle sends back. It lives on the
  controller, so a driver's sandbox can't touch it.
- **Daily caps:** `turtled.dailyRuns` and `turtled.dailyCost`, for the
  fleet, both 0 by default, which means no drivers until the player sets
  them. turtled sums today's ledger before handing a job out and holds
  the job past either cap.
- **Prices:** a price table in turtled's settings (`turtled.price.<model>
  = "in,out"`, dollars a million tokens, cache reads and writes priced by
  their multipliers). turtled puts the model's price on the command it
  sends (`--price in,out`), so the turtle needs no table of its own. A
  model with no price can't run as a job.
- **Chat:** the base's chat box (Phase 2, item 10) says each start ("job
  7 on miner-3: sort the chests (haiku, 40 steps, 15 min, $0.50). 'claude
  stop' stops it.") and each end. It hears "claude stop" (all turtles) or
  "claude stop <turtle>", from `turtle.player` or anyone when that isn't
  set, and does what `turtlectl stop` and `hold` do.
- **Logs:** syslog on turtled, facility `cron`, tag `at`: queued,
  started, ended (and how), missed.

**On the turtle:**

- **turtlec runs a job** as a process group of its own (`K.spawn`), and
  checks in every 5 s while it runs (D5's interval otherwise), so a stop
  lands within 5 s. A stop is TERM to the group, then KILL after 3 s, as
  `service stop` does; `T.run` holds the TERM until the move is saved.
  turtlec also ends a driver past its `--minutes` + 5, which covers a
  single long lua call, even when turtled can't be reached.
- **The result:** how the run ended (done, a limit, stopped, preempted,
  failed, interrupted) and its numbers go back at the next check-in that
  gets through, as the log lines do.
- **The lock** lives in turtlelib's shared marker (`turtle._ccnixWrap`,
  in memory, so a reboot frees it), held by a process group:
  - One check in front of every motor function, both the installed
    `turtle.*` and `T.raw` (turtlelib's own moves call `T.raw`). Reading
    calls (`inspect`, `detect`, `getItemDetail`, `getFuelLevel`) stay
    open.
  - Free, anyone may move the turtle, as today. Held, any other group
    gets `false, "the turtle is held by job 7 (claude, pid 23)"`.
  - `T.lock(by, rules)` and `T.unlock()`. A lock whose group has no
    process left is free (init's `K.onReap`).
  - Who takes it: `claude --once` for its whole run; an interactive
    `claude` for each goal (not at its idle prompt, so autostart's
    waiting `claude` doesn't block jobs); mine, farm and mow at their
    start, refusing to start when it's held rather than meeting it
    mid-run.
  - Primary thought rides on the same lock: a `claude` that doesn't hold
    it reads the memory files, `resume.txt` and `.job`, and writes none.
  - When the lock passes on, the next holder reads the saved position
    again (`T.claim()`), since the last one moved the turtle.
- **The player first:** a player who starts a goal while a job drives is
  asked "job 7 (sort the chests, haiku) is driving, 4 min in. Stop it and
  take over? [y/N]". Yes ends the job "preempted", not run again. A
  program typed at the console (mine) refuses, naming the job.
- **`claude --once`:** one goal, then exit. It never asks at the
  keyboard (no `ask_user`, no `review`, no `--confirm`; the chat tool's
  `ask` works, its wait counted in the job's minutes), never writes
  `resume.txt` or `claude.options`, and writes its transcript to
  `/var/log/claude/<job>.log` (the last 20 kept), outside `/claude/`.
  Its limits, soft as the step budget is today (the model is told which
  one and to sum up; later tool calls aren't run): `--steps`,
  `--minutes`, `--fuel`, `--cost` (by `--price`). Cost and fuel are
  known after a call, so a run can go one call over.
- **Chores** (`--chore`): rules set in the lock, so the gate checks them,
  not `T.cfg`:
  - containers are never dug, whatever `T.cfg.digContainers` says;
  - protected areas hold (`T.inside`, `T.withUnprotected` change nothing;
    `T.protect` and `T.unprotect` refuse);
  - with `--box x1,y1,z1,x2,y2,z2`, a dig or placement outside the box is
    refused;
  - memory is read-only; the chore writes under `/claude/jobs/<id>/`, and
    `T.job` keeps a journal of its own.
- **A reboot mid-run:** the turtle's next check-in doesn't list the job
  as running, so turtled ends it "interrupted", or, with `-r`, hands it
  out once more (told "you were interrupted (reboot); read
  /claude/jobs/<id>/ and carry on"), against the caps again. A second
  interruption ends it.
- **Not a wall:** the sandbox has `T`, `os` and `rawset`, so a model set
  on it could get round the gate. The caps live on the controller, out of
  its reach, and the API key's own spending limit (Anthropic's console)
  is the backstop; `help turtlectl` says to set one.

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

The scheduled drivers (ADR-0021's D1 is settled: the queue is on the
controller):

- **D6. The queue and its commands:** jobs as timed commands on turtled,
  with `turtlectl at`, `atq`, `atrm`, `stop`, `hold` and `release`, a
  60-minute window and UTC times (recommended). The other way: POSIX `at`
  on the controller's computer, its jobs being `turtlectl send` lines.
  That's a general `at`, but the window, "busy" and the caps would have
  nowhere to live.
- **D7. The lock:** in turtlelib's shared marker, held by a process group,
  covering every motor function and primary thought; mine, farm and mow
  take it at their start; the player first, asked (recommended). The
  other ways: a lock file (a file read on every move, stale after a
  reboot), or a lock in the harness only (mine would still move the
  turtle under a driver).
- **D8. Limits and caps:** each run's limits on `claude --once`'s command
  line (defaults in turtled's settings, tight: 40 steps, 20 minutes, 500
  fuel, $0.50); the daily caps, ledger and price table on turtled, caps 0
  (off) by default; the chore rules at the gate (recommended). Or daily
  caps only, with no chore rules.
- **D9. Stopping, and reboots:** "claude stop" through the base's chat
  box, `turtlectl stop` and `hold`, Ctrl+T at the turtle, check-ins every
  5 s while a driver runs; a job cut by a reboot isn't run again unless
  queued with `-r` (recommended). Pausing a driver is ADR-0005's `kill
  -STOP`, at the turtle or by `turtlectl send <t> run kill -STOP -<pgid>`
  (D4).
- **D10. A model's own scheduling:** only the controller model (item 11),
  never the bots, and off (`turtled.schedule = false`) until that phase
  (recommended). A bot that wants a follow-up says so in its result, and
  the controller or the player queues it. ADR-0021's D7 had each driver
  queue one follow-up itself.

## Consequences

- Turtles can be watched and steered from the base or a browser, with no
  extra hardware or slot, as long as the server runs in TUN mode.
- Turtles need init, syslogd and turtlec running (setup does that), and
  mine as a service rather than run from the shell.
- It leans on CC's HTTP API and one rule in the server's config; a server
  with HTTP off or in NAT mode needs the modem transport (later).
- No live console over HTTP: `run` gives command output, not a terminal.
  telnet to a turtle still needs a modem.
- **Scheduled drivers:**
  - Need turtled reachable to start: no jobs go out while it's down.
    A running driver keeps to its own limits, and turtlec's hard stop,
    without it.
  - The caps and the ledger are out of every turtle's reach, which a
    queue on the turtle (ADR-0021) couldn't promise.
  - A stop needs no chat box on the turtle, so it isn't lost while the
    turtle digs (ADR-0021's chat box went off during digs).
  - Every motor call gains a lookup: is the lock held, and by whom.
  - An idle interactive `claude` no longer owns the turtle between
    goals: a job may move it, and the next goal is told (the jobs since,
    a line each, in its start notes).
  - claude.lua is near CC's 200 locals, so `--once`, its limits and the
    lock's use go in a module of their own.
  - ccnix-mod needs nothing for them beyond item 1's HTTP rule.

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
10. [ ] turtled tells the game's chat about the turtles (`lib/mc`: a job
    done, stuck, out of fuel), and, optionally, `ircd`'s `#minecraft` or
    a channel of its own. One chat box at the base speaks for the fleet;
    the turtles needn't carry one. (Noted 2026-11-15: a chat box doesn't
    hear another chat box, so a turtle's own `T.report` never reaches
    IRC.)
11. [ ] Claude bots under turtled (noted 2026-11-17, from ADR-0013 D2): a
    controller model (Opus by default, selectable) drives agent bots
    (claude turtles on Sonnet by default, selectable; optionally other
    kinds of bot), and the player's chat reaches them over CC's `http`
    through the gateway (option 1 above), so no turtle carries a chat
    box to listen.
12. [ ] The `http` path in NAT mode too (noted 2026-11-17): a computer's
    `http` request to an in-game address reaches it when the server
    runs the gateway in NAT mode, not only in TUN mode (today: "NAT mode
    would need a port forward"). Mostly ccnix-mod's gateway: a lockstep
    change.

### Phase 3: scheduled drivers (once D6 to D9 are decided; needs Phase 1, and item 10 for chat)

13. [ ] Sims first, failing on today's code (ADR-0021's Sims section lists
    what to build on): turtled's queue against a fake clock (due, busy
    then retried, the window, missed, caps from a ledger, `-r` after a
    reboot); the lock in `sim/turtlelib_protect.lua` (both ways in, the
    reading calls open, freed when its group ends, the chore rules);
    `claude --once` in `sim/claude_drive.lua` (no prompt, no resume.txt,
    each limit's soft stop); mine, farm and mow refusing a held turtle.
14. [ ] The lock in turtlelib; mine, farm and mow take it.
15. [ ] turtled's queue, ledger, caps and prices; `turtlectl at`, `atq`,
    `atrm`, `stop`, `hold`, `release`; `help turtlectl`.
16. [ ] turtlec: jobs as process groups, the 5 s check-in while one runs,
    the hard stop, results.
17. [ ] `claude --once`, its limits, `--price`, `--chore`, `--box`; an
    interactive goal takes the lock, asks to preempt, hears of the jobs
    since; news lines for the model (`doc/claude-news.txt`).
18. [ ] "claude stop" through the base's chat box.
19. [ ] In game, as needs-in-game-test issues: a haiku chore queued five
    minutes ahead, watched from its start line to its end; "claude stop"
    during one; two turtles' jobs at once; a job due while mine runs; a
    player's goal preempting a driver; a reboot mid-run, with and without
    `-r`.
20. [ ] Release: its own minor version, on the owner's ok.

### Phase 4: a model's own scheduling

21. [ ] With item 11: the controller model queues, lists and removes jobs
    (D10), behind `turtled.schedule`; its in-game checks; a release.
