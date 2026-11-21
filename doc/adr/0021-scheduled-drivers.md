# ADR-0021: Scheduled drivers: an `at` queue on the turtle, one lock on its motors and its thought, and caps no prompt can lift

**Status:** Withdrawn (2026-11-20). The owner chose a central controller for scheduled work (D1's option B),
so the queue lives on ADR-0006's turtled, not on the turtle. What this ADR proposed is folded into
[ADR-0006](0006-turtle-fleet-control.md), "Scheduled drivers". It is kept as the record of the options and
of what ccnix had when it was written (its Context and Sims sections, which ADR-0006 cites).
**Date:** 2026-11-20
**Deciders:** Dan Theisen

## Context

Issue #343. The model driving turtle 10 wrote a letter "to the VS Code agent" on 2026-11-20, and the player
refined it. The ask, in the player's words:

> the agentic "supervisor" work isn't over the next 12 hours, you should use system facilities like cron for
> that, but with the ability (and framework) to schedule individual "agentic drivers" on to the turtle at a
> specified future time which take an exclusive lock over motor functions and primary "thought" within the
> turtle, with specified model params and specific prompts per invocation. maybe we need more of an `at`
> command than `cron` for this.

Some words used below:

- **A driver** is one run of the claude harness (`turtle/claude.lua`) with one goal, started by the queue
  rather than by a player at the keyboard. It ends when the goal ends.
- **A job** is an entry in the queue: when to run, what command, and with what limits. `at` is the POSIX
  command that queues one-off jobs (`cron` repeats them; this ADR doesn't).
- **Motor functions** are the turtle calls that change the world or the turtle: moves, turns, digs,
  placements, attacks, drops, sucks, equipping, refuelling, crafting and the selected slot.
- **Primary thought** is what one model at a time should own: the chat box it listens through, the memory
  files (`/claude/memories`), the goal file (`/claude/resume.txt`) and turtlelib's job journal (`.job`).
- **A chore** is a driver with tighter rules: read-only memory, digs only in its box, no lifting of the
  protected-area checks.

### What ccnix has today

**Processes and services (lib/proc, init, service).**
- init runs every program as a process with an ID, a terminal and a process group (`lib/proc.lua:1-37`).
  Every process shares `_G`, so there is one `turtle` table on a turtle whatever runs
  (`doc/adr/0005-processes-and-job-control.md`, "CC's limits").
- A service is a command kept in the settings: `service.<name>.cmd`, `.enabled`, `.restart`
  (`lib/proc.lua:45-51`, `P.serviceDef` at `lib/proc.lua:207-214`). There are no service files in an
  `etc/` folder; `setup` writes the settings (`deploy/setup.lua:275-300`).
- init restarts a service that ends after 1 s, 2 s, 4 s, up to a minute (`lib/proc.lua:1058-1078`).
  `service stop` sends TERM (Ctrl+T), then KILL after 3 s (`lib/proc.lua:1105-1118`).
- `K.spawn` takes `session`, `pgid`, `capture` and `onExit` (`lib/proc.lua:584-594`). `K.kill` signals a
  process or a whole group (`lib/proc.lua:752-772`). The signals are HUP, INT, KILL, TERM, CONT, STOP and
  TSTP (`lib/proc.lua:114`). A stopped process keeps its events until CONT (ADR-0005).
- `K.onReap(fn)` runs as each process ends; init uses it to close a dead process's sockets
  (`lib/proc.lua:791`, `bin/init.lua:85-88`).
- `K.after(seconds, fn)` is a kernel timer (`lib/proc.lua:577`).
- With init, a turtle's autostart job (mine, farm, claude...) runs as a service of its own name, not on the
  console (`deploy/setup.lua:346-358`, `bin/init.lua:91-100`).

**The system log (ADR-0004).** `lib/log` is syslog(3): `log.open(app, facility)`, severities and
facilities as RFC 5424 numbers them, `cron` among them (`lib/log.lua:16-20`, `:44`). Under init a message
goes to syslogd in memory, not through CC's event queue. A service's prints are captured a line each unless
`service.<name>.log` is false.

**Time.** CraftOS timers and `sleep` count game ticks. `lib/realtime` gives real seconds at any tick rate:
`realtime.now()`, `realtime.timer(s)`, `realtime.sleep(s)` (`lib/realtime.lua:9-33`, `:88-105`). `bin/sleep`
uses it (`bin/sleep.lua:5-8`). Nothing in `bin/` or `pc/` schedules anything: there is no `at`, `cron` or
`crontab` in the repo.

**The claude harness (turtle/claude.lua).**
- **Starting:** `claude [goal] [--model] [--effort] [--steps N] [--cache 5m|1h] [--confirm] [--resume]`
  (`turtle/claude.lua:9-29`, parsed at `:385-441`). Model aliases are opus, sonnet and haiku
  (`:378`). The defaults are opus, effort medium, 60 steps and a 5-minute cache (`:435-439`).
- **Saved options:** each session saves its `--model --effort --steps --cache` in the setting
  `claude.options`, and a plain `claude` starts with them (`:31-36`, `:417`, saved at `:2862`).
- **resume.txt:** while a goal runs, `/claude/resume.txt` holds the options and the goal. It is written at
  a goal's start (`:2915`) and deleted at its end (`:2923`) or on Ctrl+T (`:2933`). `--resume` reads it
  (`:399-414`).
- **Autostart:** with `ccnix.autostart=claude`, `turtle/autostart.lua` runs `claude --resume` when
  `claude.resume` is true and the file is there, else a plain `claude` waiting for a goal
  (`turtle/autostart.lua:27-33`, `:109-112`).
- **A goal:** `converse(goal)` loops request, tool calls, results, until the model ends its reply
  (`:2686`). The step budget: at `MAX_STEPS` the model is told to stop and sum up, and later tool calls
  are not run (`:2742-2747`). After a goal the harness waits at the `> ` prompt (`:2924`).
- **The chat listener:** while a request is out and while code runs, a chat box goes on the free side and
  the chat is heard, until the first dig or attack puts the pickaxe back (`:112-122`, `:1594-1665`).
  `listen.note` keeps what `turtle.player` says (anyone, when unset) for the next results (`:1653-1665`).
- **The key:** `claude.key` beside the program, readable by nothing in the sandbox (`:236-238`,
  `:842-847`).
- **The sandbox:** the model's code gets `turtle`, `T`, `os`, `http` and the rest, but no `settings`
  (`:895-905`). It writes only under `/claude/` (`:849-852`).
- **Accounting:** each call's tokens are logged (in, from the cache, written, new, out, thinking), and each
  goal's sum (`:2404-2425`). Nothing counts money: there is no price table.
- **The log:** `claude.log` beside the program, rotated at 256 KB (`:124-133`, `:242-248`).
- **Size:** claude.lua is "near CC's 200 locals" (`:242`, `:1603`), so new code wants a module of its own.

**turtlelib (turtle/turtlelib.lua).**
- **The wrap:** loading turtlelib replaces the moves, turns, digs, placements and attacks in the one
  `turtle` table, once per boot. The originals go in a shared marker, `turtle._ccnixWrap`
  (`:523-547`, `WRAPPED` at `:549-551`, installed at `:580-602`). The marker is the one place every
  program's copy of turtlelib meets.
- **T.raw** holds the originals. turtlelib's own moves and turns call them directly: `T.turnRight`
  (`:1051`), the step loop (`:1618`), `T.back` (`:1656`), another mover (`:1993`). So a check placed only
  in the installed wrappers misses `T.forward` and friends.
- **Not wrapped:** `drop`, `suck`, `select`, `transferTo`, `equipLeft/Right`, `refuel`, `craft`.
- **Hooks:** `T.hooks.tool` and `T.hooks.heard` (`:604-621`). `T.claim()` makes a copy of turtlelib
  the one whose `T.pos` the wrapped calls update (`:623-627`).
- **Protection:** the wrapped dig refuses protected areas and containers (`:977-1013`). `T.inside` and
  `T.withUnprotected` lift an area for a function (`:886-905`). `T.cfg.digContainers` lifts the
  container rule. `T.unprotect` removes an area (`:791`).
- **T.run** holds back a Ctrl+T that comes during a turtle command until the move is saved
  (`:236-282`). mine runs under it (`turtle/mine.lua:3812`), and so does claude (`turtle/claude.lua:2929`).
  farm, mow and home do not.
- **Programs call the turtle directly too:** mine calls `turtle.select`, `turtle.drop` and
  `turtle.refuel` straight (`turtle/mine.lua:909-934`, `:1422-1423`); farm has 21 such calls.
- **Settings:** `T.saveSettings` writes any setting (`:2505-2510`), and the sandbox has `T`.
- **Journal:** `T.job` keeps a job in `.job` beside the program (`turtle/tl/journal.lua:33`, `:136`).
  `T.report` and `T.report.ask` talk in chat (`turtle/tl/journal.lua:242`, `:394`).

### Forces

- **Keep it simple.** The owner prefers small designs, and real protocols where they fit. POSIX
  `at`, `atq` and `atrm` are the model for the commands.
- **Money spent with nobody there.** `claude.resume` is off by default for that reason
  (`turtle/claude.lua:251-253`). Drivers spend more of it.
- **One turtle, one body.** Two programs moving one turtle ruin each other's position.
- **Not a security boundary.** The sandbox has `T`, `os` and `rawset`. A model set on lifting a cap could
  find a way. The caps keep honest mistakes and runaway loops in bounds. The API key's own spending limit,
  set in Anthropic's console, is the hard backstop.
- **No mod changes needed.** ccnix-mod's ROM is built from this repo's `bin lib turtle pc help deploy`, so
  new programs ride the usual lockstep bump. Checked: the mod has no program list to update, only its
  store listing (`ccnix-mod/doc/listing.md`) if the feature is to be named there.

## Decision

Proposed: an `atd` service on the turtle runs one-off jobs from a POSIX-style queue. A lock in turtlelib's
shared marker lets one process group at a time use the motor functions. `claude --once` runs a single goal
under the job's limits and the day's caps, and hands the lock back. D1 to D11 are the choices, each with
a recommendation.

## Options considered

### D1. Where the queue lives, and its format

- **A. On the turtle, a file a job (recommended).** `/var/spool/at/<id>`, as POSIX keeps `atjobs`. The
  next ID is in `/var/spool/at/.seq`. Plain text, a field a line, then the command:
  ```
  id: 7
  queue: c
  at: 2026-11-21T06:00:00Z
  queued: 2026-11-20T22:14:05Z by console
  window: 60
  rerun: no
  cmd: claude --once --model haiku --steps 40 --minutes 15 --cost 0.50 --chore --box 0,60,0,20,70,20 sort the chests at the base
  ```
  - `at` is UTC, as `claude.log` stamps its lines.
  - `window` is how many minutes late the job may still start (D4).
  - `queued ... by` is `console`, a telnet session, or `job 6` (a follow-up, D7).
  - When the job starts, atd adds `started: <time> pid <n>`. When it ends, the file is removed, as POSIX
    does, and the run's line goes to the ledger (D9).
  - The sandbox can read the spool and can't write it (it writes only under `/claude/`).
- **B. On a server computer.** One queue for a fleet, sent over the network (ADR-0006's turtled). A
  turtle often has no modem on (ADR-0006: two upgrade sides, pickaxe and chunk controller). And ADR-0006
  is still Proposed.
- **C. In the settings,** as services are. Settings are one file rewritten whole on each save, and a
  queue changes often. Fine for a few fixed things, poor for a list.

### D2. The commands

- **A. POSIX `at`, `atq`, `atrm`, plus `claude --at` and `claude --once` (recommended).**
  - `at [-q letter] [-f file] [-w minutes] [-r] time...` reads command lines from standard input (or
    `-f`), as POSIX does: `echo "mine 3 3 32" | at now + 2 hours`. ccsh's pipes feed `io.input` already.
  - `at -c id` shows a job (Linux's `at -c`). `at -l` is `atq`, `at -r id` is `atrm`, as POSIX names them.
  - `atq [-q letter]` lists jobs: ID, time, queue, who queued it. A running job shows queue `=`, as Linux's
    atq shows it, with its process ID and group, for `kill -STOP` (D8).
  - `atrm id...` removes waiting jobs. On a running job it sends TERM to its group, then KILL after 3 s,
    as `service stop` does. (POSIX leaves a running job alone; ccnix's choice, said in `help at`.)
  - **Time:** a subset of POSIX's: `now + N minutes|hours|days`, `HH:MM` (today, or tomorrow if past),
    `noon`, `midnight`, `tomorrow`, and `YYYY-MM-DD HH:MM`. In UTC.
  - `claude --at TIME [options] goal words` is the short way: it queues
    `claude --once [options] goal words` in queue `c`, quoting the words as `service add` does
    (`bin/service.lua:85-93`). `atq -q c` lists only drivers.
  - `claude --once` runs one goal and exits. It never asks at the keyboard, never writes `resume.txt` or
    `claude.options`, and logs to the job's transcript (D9). `--goal-file path` takes a long prompt from a
    file.
  - `atd` is the service. `setup at` installs it with init and syslogd, as `setup gpsd` does.
- **B. A claude-only queue** (`claude queue`, `claude jobs`, `claude cancel`). Smaller, but a queue that
  can only run claude, and new verbs where POSIX already has some.
- **C. cron.** Repeating jobs. The letter asked for `at`; a repeat can be a job that queues its follow-up
  (D7).

### D3. The lock: what holds it, where it lives, what it covers

- **A. In turtlelib's shared marker, held by a process group (recommended).**
  - **Where:** `turtle._ccnixWrap` (`turtle/turtlelib.lua:580-602`) gets a `lock` record:
    `{ pgid, by, job, since, rules }`. It lives in memory, so a reboot clears it, which is right: after a
    reboot nobody holds the turtle.
  - **Who holds it:** a process group (`proc.getpgid()`, `lib/proc.lua:1143`). A group covers what the
    holder runs inside itself: claude's code and `run_program` run in claude's own process.
  - **The gate:** one check in front of every motor function, for both the installed `turtle.*`
    functions and `T.raw`, since turtlelib's own moves call `T.raw` (`:1051`, `:1618`, `:1656`, `:1993`).
    The list grows from the 15 wrapped functions to the motor functions above. Reading calls (`inspect`,
    `detect`, `getItemDetail`, `getFuelLevel`) stay open, so `status` and `ps` can look.
  - **The rule:** free, anyone may move the turtle (as today). Held, only the holder's group may. Any other
    call returns `false, "the turtle is held by at job 7 (claude, pid 23): atq"`.
  - **Taking and giving back:** `T.lock(by, rules)` and `T.unlock()`. `T.lock` fails with the holder's
    name if another live group holds it. A lock whose group has no process left is free: init's
    `K.onReap` frees it, and `T.lock` checks with `proc.kill(pid, 0)` too.
  - **Without init:** one program runs at a time (bar multishell), and the lock is held by "this
    program". `atd` needs init, as `service` does.
  - **Who takes it:**
    - `claude --once`: for its whole run.
    - An interactive `claude`: when a goal starts, given back when it ends. At the `> ` prompt it holds
      nothing, so an idle `claude` left by autostart doesn't block the queue forever.
    - mine, farm and mow: at their start (mine inside `T.run`; farm and mow get one line). A program that
      finds the turtle held refuses to start, with the holder's name, rather than meeting "held" mid-run
      and taking it for a wall.
    - Programs that never call `T.lock` (a stock `excavate`) work while the lock is free and fail while it
      is held. atd loads turtlelib at boot, so the gate is in place before anything else runs.
  - **Primary thought** rides on the same lock. The harness checks the lock before it:
    - listens on the chat box;
    - writes `/claude/memories` (the memory tool, and the sandbox's `fs`);
    - writes `resume.txt` or `.job` (`turtle/tl/journal.lua:33`).

    A `claude` that doesn't hold the lock reads all of them and writes none.
- **B. A lock file** (`/var/run/turtle.lock`, a PID inside). Unix's way, but a reboot leaves it stale, so
  boot must clear it, and every motor call would read a file.
- **C. In the harness only.** claude refuses to drive while another claude drives. mine, farm and a
  player's own program would still move the turtle under a driver, which the letter asked to prevent.

### D4. Who comes first

- **A. The player first, asked; jobs wait (recommended).**
  - **A job comes due while the lock is held** (an interactive goal, or mine as a service): it waits. atd
    tries again each minute until the job's `window` (default 60 minutes) runs out. Then the job is
    "missed": logged, said in chat, and removed.
  - **One driver at a time.** Jobs due together run one after the other, by due time.
  - **The player starts a goal while a job drives:** claude asks at the keyboard: "at job 7 (sort the
    chests, haiku) is driving, 4 min in. Stop it and take over? [y/N]". Yes: atd stops the job as `atrm`
    does (TERM, which `T.run` holds until the move is saved, `turtle/turtlelib.lua:264-282`). The job
    ends "preempted" and is not run again. No: claude goes back to the prompt.
  - **A player's program while a job drives** (`mine` typed at the console): refuses, naming the job and
    `atrm 7`.
  - **Handing back the position:** a driver moves the turtle, so the next holder reads the saved
    position again (`.turtlepos`) and calls `T.claim()` (`:623-627`) when it takes the lock.
- **B. Refuse.** The player stops the job first (`atrm`, or "claude stop"). Simpler, but the letter
  said the player comes first.
- **C. Pause the job** (`kill -STOP`) through the player's goal and continue it after. The turtle has
  moved under it by then, so its plan and its cache are both stale.

### D5. A job's own model, prompt and limits

- **A. Options on the command line, with defaults in settings (recommended).**
  - **Model and effort:** `--model` and `--effort`, as today. Any alias or model ID.
  - **Prompt:** the goal words, or `--goal-file`.
  - **Limits:**
    - `--steps N`: tool calls (exists);
    - `--minutes N`: real minutes, by `lib/realtime`;
    - `--fuel N`: fuel used;
    - `--cost D`: dollars (D6 says how it's counted).

    The defaults are the settings `claude.job.steps`, `claude.job.minutes`, `claude.job.fuel` and
    `claude.job.cost`, kept tight: 40 steps, 20 minutes, 500 fuel, $0.50.
  - **Cache:** a job is a one-off, so the 5-minute cache. Writing an hour's cache costs 2x the input
    price, and 1.25x for five minutes (`turtle/claude.lua:353-355`).
  - **How a limit ends a run:**
    - **Soft:** as the step budget does today (`:2742-2747`). After the call that crosses any limit, the
      model is told which one and to stop and sum up. Later tool calls are not run.
    - **Hard:** atd sends TERM at `minutes` + 5. That covers a single long lua call, which the harness
      can't cut short.
    - Cost and fuel are known only after a call, so a run can overshoot by one call. `help at` says so.
  - **Nobody at the keyboard:**
    - `ask_user` isn't offered to a job;
    - `review = true` and `--confirm` are refused;
    - the chat tool's `ask` works, with its timeout counted in the job's minutes.
- **B. A job file of its own** (YAML-like, a field per limit). More to parse, and `at -c` shows the
  command anyway.
- **C. Limits in the prompt only.** The model keeps to them or doesn't.

### D6. Caps no prompt can lift

- **A. Caps in settings, a ledger the sandbox can't write, and chore rules at the gate (recommended).**
  - **Daily caps:** `claude.job.dailyRuns` and `claude.job.dailyCost`, both 0 by default. 0 means
    drivers are off: `claude --once` refuses until the player sets both (as `claude.resume` is off by
    default). A UTC day.
  - **Where they're counted:** the ledger, `/var/log/at.ledger` (D9), outside `/claude/`. `claude --once`
    sums today's lines before it starts and refuses past either cap. A running driver also stops (soft)
    when today's cost would cross the cap.
  - **Interactive sessions** are written to the ledger, for the record, but not capped. The player at the
    keyboard is the cap.
  - **How cost is counted:** a price table, a setting per model,
    `claude.price.<model> = "in,out"` (dollars a million tokens). Cache writes and reads are priced from
    the input price by the multipliers the code already notes (`turtle/claude.lua:353-355`: 1.25x or 2x to
    write; 0.05x to read on Opus 5.5), checked per model. The shipped values are taken from Anthropic's
    price list when this is built. A model with no price can't run as a job, since its cost can't be capped.
    The goal's end line (`tokenLine`, `:2418`) gains the cost.
  - **Chore rules** (`--chore`), set by the harness in the lock's `rules`, so the gate checks them, not
    `T.cfg`:
    - containers are never dug, whatever `T.cfg.digContainers` says;
    - protected areas hold, whatever `T.cfg.inside` says (`T.inside` and `T.withUnprotected` change
      nothing), and `T.unprotect` and `T.protect` refuse;
    - with `--box x1,y1,z1,x2,y2,z2`, a dig or placement outside the box is refused. The box is in the
      turtle's frame, or in world coordinates when the origin is set (`T.toLocal`);
    - memory is read-only (the memory tool's writes refuse, and so does `fs` under `/claude/memories`);
      the chore writes in `/claude/jobs/<id>/` instead;
    - `T.job` uses a journal of its own, so a chore never overwrites the player's.
  - **Settings from the sandbox:** `T.saveSettings` refuses `claude.*` and `at.*` names while a driver
    holds the lock. The sandbox has no `settings` (`:895-905`), so that closes the plain way in.
  - **Not a wall:** a model could still `rawset` its way round the gate. The API key's spending limit is
    the backstop, and `help at` says to set one.
- **B. Daily caps only.** No chore rules: every driver may do what an interactive session may.
- **C. The API key's limit only.** Nothing in ccnix. A runaway loop then spends up to the key's limit.

### D7. The model's own scheduling

- **A. One tool, `at`, with an action, under rules (recommended).**
  - `at { action = "queue", when, goal, model?, effort?, limits? }`, `at { action = "list" }`,
    `at { action = "remove", id }`. It calls the same code as the commands.
  - **One follow-up per run.** A second "queue" in the same run is refused.
  - **No more than its parent:** a follow-up's limits are at most the queuing run's, and its model no
    dearer. A follow-up of a chore is a chore. The daily caps bound any chain.
  - **Its own jobs only:** the model lists every job, and removes only those it queued (`queued ... by
    job N` or by a session).
  - **Off until the last phase** (the letter's roll-out order): the setting `claude.job.schedule`,
    false by default.
  - The prompt says what the tool is for, in a paragraph, and that the player sees each job in chat.
- **B. Through `run_program`.** Add `at` to the programs it may run (`turtle/claude.lua:370-371`). No
  new tool, but no place to enforce one follow-up or the parent's limits.
- **C. No model scheduling.** The player queues everything.

### D8. Kill switches and pause

- **A. A stop file, "claude stop" in chat, and ADR-0005's STOP and CONT (recommended).**
  - **`/claude/STOP`:** while it exists, atd starts nothing and a driver stops before its next request or
    tool call (the soft stop of D5, without the last reply). `touch /claude/STOP` and `rm /claude/STOP`
    at the console. It is in `/claude/` because the letter asked for it there. So the sandbox, which
    writes under `/claude/`, refuses to write, move or delete that one file, the way it refuses to read the
    key (`:842-847`).
  - **"claude stop" in chat:** from `turtle.player` (anyone, when it isn't set). `listen.note`
    (`:1653-1665`) sees it. The driver ends at once (no further request; TERM-safe under `T.run`) and
    writes `/claude/STOP`, so nothing else starts until the player removes it. The limit, said in
    `help at`: the chat box is off while code digs, so a stop said then is heard at the next request,
    within one tool call.
  - **Pause:**
    - the queue: the STOP file;
    - a running driver: `kill -STOP -<pgid>` and `kill -CONT -<pgid>` (ADR-0005), with the group from
      `atq`. A paused driver keeps the lock. A pause longer than the cache's 5 minutes makes the next
      call write the conversation to the cache again, which `help at` says.
  - **"claude pause" in chat** isn't offered: a stopped process can't hear "claude resume".
- **B. The STOP file only.** One switch, but the player in game must open the turtle.
- **C. A chat listener in atd** that hears pause and resume itself. atd would need the chat box, which
  the driver is using.

### D9. What's logged

- **A. Syslog, a ledger, a transcript, and chat (recommended).**
  - **syslog**, facility `cron` (`lib/log.lua:44`), tag `at`:
    - `job 7 queued for 06:00Z by console: claude --once ...`
    - `job 7 started (pid 23)`
    - `job 7 ended: done|limit steps|stopped|preempted|failed|missed|interrupted; 12 calls, 7m, fuel 40, $0.18`
  - **The ledger**, `/var/log/at.ledger`: one tab-separated line a run: date, job, model, how it ended,
    calls, minutes, fuel, tokens (in, cached, written, out) and dollars. D6 sums it. Interactive goals
    are written there too, as job `-`.
  - **The transcript:** what `claude.log` gets today, in `/var/log/at/<id>.log`. Outside `/claude/`, so
    the model can read past runs and not rewrite them. The last 20 are kept (`at.keepLogs`).
  - **Chat:** the harness, not the model, says a line at each start ("at job 7: sort the chests (haiku,
    40 steps, 20 min, $0.50). 'claude stop' stops it.") and each end (the syslog line's tail). No chat
    box aboard: logged only.
  - **The next interactive goal is told:** jobs run since the last goal, a line each from the ledger,
    with the turtle's move, in the goal's start notes (`startNotes`, `:2474`).
  - atd's own prints are not captured (`capture = false` in its spawn of the driver), so the transcript
    doesn't flood syslog.
- **B. syslog only.** No per-run record for the caps to sum, and no transcript to read back.

### D10. A reboot mid-run, and jobs that came due while the turtle was down

- **A. Not run again unless the job says so (recommended).**
  - At boot atd reads the spool. A file with `started:` and no live process was interrupted.
  - `rerun: no` (the default): it ends "interrupted": logged, said in chat, removed.
  - `rerun: yes` (`at -r`, `claude --at ... --rerun`): it is run once more, from its goal, told "you were
    interrupted (reboot); read /claude/jobs/<id>/ and carry on". It counts against the daily caps again.
    A second interruption ends it.
  - **Jobs whose time passed while the turtle was down** (server off, chunk unloaded) run at boot if
    still inside their window, else end "missed".
  - **resume.txt stays the interactive session's.** A driver never writes it, so autostart's
    `claude --resume` (`turtle/autostart.lua:109-112`) never takes up a job as a player's goal.
  - atd's timer is `realtime.timer`, capped at 60 s and re-armed, so a changed tick rate or a skipped
    timer makes a job at most a minute late.
- **B. Always run again.** Money spent unattended after every server restart.
- **C. Never run again.** `rerun` gone; simpler, and a long chore lost to a restart is lost.

### D11. Which release

- **A. Its own minor release, after the roll-out's Phase 3 (recommended).** A new feature: ccnix's minor
  version. The mod gets the usual lockstep patch bump, nothing else. Phases 4 and 5 ship in later
  releases.
- **B. All phases in one release.** Waits for the in-game watched chore and the overlap tests.

## Trade-off analysis

- **D1 A and D2 A** are POSIX's own shape. A player who knows `at` knows these. A general `at` also
  queues `mine` or `farm` runs, not only claude. The cost is a time parser and four small programs.
- **D3 A** puts the lock where every program already meets: the marker in the one `turtle` table. B
  costs a file read on every move and a stale-lock sweep at boot. C doesn't stop mine.
  - **The cost of A:** the gate must cover `T.raw` too, and the list of gated functions grows from 15 to
    about 25.
  - **The risk:** a program that runs without `T.lock` and meets a held lock mid-run. mine, farm and mow
    take the lock at their start to avoid it.
- **D4 A** keeps the player first without leaving a job half-run under them unasked. Jobs that wait cost
  nothing. A window keeps a 06:00 chore from running at 15:00.
- **D5 A and D6 A** keep every limit in ccnix's own settings and files, where `sysctl` and `cat` show
  them. The price table can go stale when prices change; a stale price errs one way or the other, and the
  key's own limit holds regardless. Tokens alone (no table) would be exact, but a player thinks in
  dollars.
- **D6 A's chore rules** are four checks at the gate and the memory tool. B leaves an unattended model the
  same reach as one the player watches.
- **D7 A** makes the model's scheduling one place to enforce one follow-up and "no more than the parent".
- **D8 A** gives the player in game a stop that needs no console, and the console a pause that already
  exists. A chat pause (C) needs a second chat listener.
- **D9 A** writes three things per run. The ledger is what makes the caps work; the transcript is what
  makes a report about a run possible.
- **D10 A** spends nothing after a reboot unless the player asked for it per job.

## Consequences

- **Easier:**
  - A chore at a set time, on a cheaper model, with nobody at the keyboard and a known worst-case spend.
  - `mine` or `farm` queued for later with the same `at`.
  - One answer to "who is moving the turtle": `atq`, and the gate's message.
- **Harder:**
  - Every motor call gains a table lookup: whether a lock is held, and by whom.
  - farm and mow gain a `T.lock` at their start; mine takes it in `T.run`.
  - claude.lua grows. Its locals are near CC's 200, so the job code (limits, ledger, price table, the
    `at` tool) goes in a module, `turtle/tl/job.lua` or `lib/atjob.lua`, as tl/ modules do.
- **Changed for the player:**
  - An idle interactive `claude` no longer owns the turtle between goals. A job may move it, and the next
    goal is told.
  - A `claude --once` never changes `claude.options`.
- **Unchanged:** the API, the mod (only the lockstep bump), the network stack, ADR-0006's open questions.
- **To watch:**
  - Two claude processes in one Lua VM (an idle interactive one, a driver): memory use on a turtle.
  - How often "claude stop" goes unheard during digs.
  - Whether a 60-minute window is right for most chores.

## Sims

What exists that a fake driver can build on (`python sim/run.py <name>`):

- **`sim/claude_drive.lua`:** claude.lua against canned API replies (`M.httpApi`, `M.sse`), on the mine's
  rock world (`sim/lib/mineworld.lua`). 46 scenarios. The ones to extend:
  - 4, the step budget: the pattern for the time, fuel and cost limits;
  - 17, run_program;
  - 32, the chat tool, and 36, the chat listener: "claude stop" heard;
  - 37, resume.txt: that `--once` never writes it.

  `claude --once` with a queue of canned replies is the fake driver: no network, no tokens.
- **`sim/proc.lua`:** lib/proc over a fake os, its own event list, timers and clock. It covers services,
  restarts, signals, `onReap` and the log. The place for atd as a service: due times, the wait-then-retry
  on a held lock, the window, `atrm` on a running job (TERM, then KILL), and the reboot sweep.
- **`sim/jobs.lua`:** ccsh under the kernel on a shellworld turtle (`sim/lib/shellworld.lua`), with
  process groups, `kill -STOP` and `kill -CONT`. The place for the commands at the prompt:
  `echo "mine" | at now + 1 minute`, `atq`, `at -c`, `atrm`, a paused driver.
- **`sim/realtime.lua`:** the two-handed clock (game time and real time at a set tick rate). The place
  for at's times at 60 ticks a second, and a timer capped at 60 s.
- **`sim/syslog.lua`:** lib/log and syslogd: the `cron.info` lines.
- **`sim/autostart_boot.lua`:** autostart at boot. The place to check `claude --resume` never takes up a
  job, and a rerun after a reboot.
- **`sim/turtlelib_stop.lua`:** `T.run` holding Ctrl+T during a turtle command. The place to check that
  a preempted driver stops with its position saved.
- **`sim/turtlelib_protect.lua`:** the wrap made once, protected areas, `T.inside`. The place for the
  gate: a held lock refusing `turtle.forward()` and `T.forward` (through `T.raw`) from another group,
  and the chore rules (no containers, no `T.inside`, the box).
- **`sim/mine_tunnel.lua`, `sim/farm_*.lua`, `sim/mow_lawn.lua`:** the programs. Each gains a case: the
  turtle held at start, and the program refusing with the holder's name.
- **`sim/lib/mock.lua`:** the shared fakes: `fsApi`, `shellApi`, `httpApi`, `consoleApi`, `termApi`,
  `runner`.

A new `sim/at.lua` would bring these together: a fake driver that is a small Lua program in
`sim/lib/` (takes the lock, moves a few cells, writes a ledger line, ends), run by atd under the
`sim/proc.lua` kernel. That tests the queue and the lock before claude is involved.

## Action items

### Phase 0: sims first, failing on today's code
1. [ ] `sim/at.lua`: the fake driver, atd under the kernel: queue, run at time, one at a time, wait on a
   held lock, the window, `atrm` waiting and running, the STOP file, the reboot sweep (interrupted,
   rerun, missed).
2. [ ] `sim/turtlelib_protect.lua`: the gate, both ways in (`turtle.*` and `T.raw`), the reading calls
   left open, the lock freed when its group ends, the chore rules.
3. [ ] `sim/claude_drive.lua`: `--once` (no prompt, no resume.txt, no claude.options), each limit's soft
   stop, the daily caps from a ledger, "claude stop", the start and end chat lines, ask_user withheld.
4. [ ] `sim/jobs.lua` and `sim/realtime.lua`: the commands at the prompt; times at 60 ticks a second.

### Phase 1: the queue and the lock (no claude)
1. [ ] `bin/at.lua`, `bin/atq.lua`, `bin/atrm.lua`, `bin/atd.lua` (a `lib/at.lua` for the spool and the
   time parser, shared), `help/at.txt` from their comments, `setup at`.
2. [ ] The lock in turtlelib: `T.lock`, `T.unlock`, the gate on the motor functions and `T.raw`, freed
   by `K.onReap`.
3. [ ] mine, farm and mow take the lock at their start.

### Phase 2: `claude --once` (on the owner's answers)
1. [ ] `--once`, `--goal-file`, `--at`, `--minutes`, `--fuel`, `--cost`, `--chore`, `--box`, `--rerun`;
   the job module; the price table; the ledger; the transcript path.
2. [ ] The STOP file guarded in the sandbox; "claude stop" in `listen.note`; `T.saveSettings`'
   refusal while a driver holds the lock.
3. [ ] An interactive goal takes the lock, asks to preempt, and gets the start note of jobs since.
4. [ ] News lines for the model (`doc/claude-news.txt`): the lock's message, what a chore may not do.

### Phase 3: one real chore, the player watching
1. [ ] A needs-in-game-test issue per check: a haiku chore queued for five minutes ahead, watched from
   the start chat line to the end line; "claude stop" during it; `rm /claude/STOP` and the next job.
2. [ ] Release (D11), on the owner's ok.

### Phase 4: overlapping jobs
1. [ ] Two jobs due together; a job due while mine runs as a service; a player's goal preempting a
   driver; a reboot mid-run with and without `--rerun`. In-game checks as issues.

### Phase 5: the model's own scheduling
1. [ ] The `at` tool (D7), behind `claude.job.schedule`; one follow-up per run; no more than the parent.
2. [ ] Its in-game checks, then a release.
