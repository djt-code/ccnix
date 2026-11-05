# ADR-0005: Programs as processes, jobs as process groups: job control split between init and ccsh

**Status:** Accepted (2026-11-05). Phase 1 built in ccnix 0.15.0; phase 2
(in game) to verify
**Date:** 2026-11-05
**Deciders:** Dan Theisen

## Context

Under init (lib/proc), ccsh is one process. Every command line is a job
coroutine that ccsh's own scheduler steps, and a program is a coroutine
nested inside that, so init knows nothing of it. The user, telnetted into a
computer whose console was running `telnet towel.blinkenlights.nl`, saw no
telnet in `ps`. ccsh numbered its jobs with `proc.reservePid()` IDs, but
nothing was registered.

There were two ways to go:

1. **Every job a real process.** Real processes, but builtins and compound
   commands would have to run apart from the shell whose state they change
   (`cd`, `X=1`, functions).
2. **Entries ccsh registers.** Visibility only. Init still couldn't
   schedule, signal or stop what it lists; it's Linux's `ps -L` threads
   without the kernel behind them.

The user asked for the Unix split, which lies between those two
(2026-11-05: "implement this middle path"). The stock CraftOS shell is out
of scope: "this should be focused on ccnix and ccsh".

Forces:

- **Unix splits job control between the kernel and the shell.** The kernel
  owns processes, process groups, sessions, each terminal's foreground
  group (`tcsetpgrp`), the terminal driver's Ctrl+Z (SIGTSTP to the
  foreground group), stop and continue, `waitpid` and SIGCHLD, and the
  hangup when a session leader exits. The shell owns the job table (`%n`,
  `jobs`, "Done"), `fg` and `bg` (tcsetpgrp plus SIGCONT), and runs its
  builtins in-process. bash forks only for external commands and
  subshells.
- **CC's limits.** It's one Lua VM, with one 256-event queue per computer.
  Every process shares `_G`, so a program's io swaps (`io.output`,
  `_G.write`, `term`) must be in place only while it runs, as ccsh's
  `enter` and `leave` already do. Neither option touches the queue. Moving
  a program out of ccsh removes a layer: init resumes it directly instead
  of init→ccsh→job→program.
- **Keep it simple.** Pipes stay as they are (each stage runs to its end,
  then the next reads what it wrote); streaming pipes are later work this
  leaves room for.

## Decision

**lib/proc (the kernel):**

- **Sessions.** A process spawned by init, or with a tty its parent isn't
  on, or with `session = true`, leads a session. If it has a terminal it
  owns it (`K.ttys[tty] = { sid, fg }`) and is in front.
- **Process groups.** A child is in its parent's group, session and
  terminal, unless spawned with `pgid` (true: its own group; a number:
  that group).
- **Foreground groups.** `proc.foreground()` and `proc.setForeground(pgid)`
  (`tcgetpgrp`/`tcsetpgrp`, for the caller's own terminal and session).
  The console's keyboard and mouse, and `proc.input(tty, ...)` (telnetd's
  pty), go to the terminal's foreground group; with no one left in it,
  they go to the session leader.
- **Ctrl+Z** on a terminal sends TSTP to its foreground group. TSTP
  doesn't stop the session leader's own group (POSIX's orphaned group) or
  a process that ignores it (`proc.ignore("TSTP")`: an interactive ccsh).
  If nothing stops, the keys go on.
- **Signals.** STOP (19), TSTP (20) and CONT (18) join HUP, INT, KILL and
  TERM. A stopped process keeps its events (up to 256) and gets them first,
  in order, on CONT. `kill(-pgid, sig)` signals a group.
- **Events.** `proc_stop`, `proc_cont`, and `proc_exit` with the status
  and whether Ctrl+T reached the process.
- **Hangup and orphans.** When a session leader ends, its terminal goes
  and what's left of the session gets HUP, then CONT. Orphans go to init.
- **`enter(p)` / `leave(p, saved)`** run around each of a process's turns:
  a ccsh command's io, put in place by the kernel.
- **Capture.** A service's child on the service's own terminal is
  captured as the service is (journald's cgroup, more or less); one with a
  terminal or session of its own isn't.

**ccsh (the shell), under such an init** (an older init, or none: as
before):

- **Programs are processes.** A program from the path runs as a process,
  ccsh's child: `proc.spawn` of a function that calls `shell.execute`,
  with the command's io as `enter`/`leave`. ccsh waits for its
  `proc_exit`; a KILLed one is status 137.
- **Builtins stay in ccsh.** Builtins, functions, compound commands and
  `( )` subshells run in ccsh, as today.
- **At the prompt, each job is a process group** whose ID is the job's
  (`$!`, `jobs -l`), reserved when its first program starts. ccsh puts
  the group in front while the job is the job in front, and takes the
  terminal back when the program ends or stops. It does this only at
  those moments, so nested shells don't fight over the terminal.
- **Stopping and continuing.** A `proc_stop` from one of a job's
  processes stops the job. `fg`, `bg` and `kill -CONT` send CONT to the
  group.
- **Signals.** `kill %n` signals the group (and CONT if it was stopped).
  `kill -STOP %n` stops the group and the job. A number that's no job's
  goes to init, and `-n` to a group. At exit, the jobs' processes get HUP.
- **Scripts and `-c`** do no job control. Their programs stay in the
  script's group, so Ctrl+T reaches the script and its programs alike.
- **Ctrl+Z.** An interactive ccsh ignores TSTP, so Ctrl+Z at its prompt,
  or during a builtin-only job, is still ccsh's own to handle, as before.

**The rest:**

- telnetd's sessions lead sessions on `pts/n`, and what's typed goes
  through `proc.input`.
- init's console is `session = true`, and so is each service.
- `ps` shows `T` (stopped) and `+` (in front), and `-l` adds PGID.
- `kill` takes the new signals and `-- -pgid`.

## Options considered

| | 1: every job a process | 2: registered entries | Chosen: Unix's split |
|---|---|---|---|
| ps shows programs | yes | yes | yes |
| kill/Ctrl+T reach them from anywhere | yes | forwarded through ccsh | yes, by the kernel |
| builtins change the shell | needs IPC back | yes | yes |
| Ctrl+Z | the kernel | ccsh | the kernel for processes, ccsh for in-shell jobs |
| scheduling layers per program | 1 | 2 | 1 |
| size | large (ccsh's state split) | ~100 lines | ~400 lines (proc, ccsh, telnetd, ps, kill) |

## Consequences

- **Easier:** `ps` and `kill` see every program on every terminal.
  Ctrl+T and Ctrl+Z work on the program in front, whichever session typed
  them. A telnet session's leftovers get HUP when it drops. Other
  daemons can use process groups and foreground groups.
- **Harder:** a program's io now depends on the kernel calling
  `enter`/`leave` faithfully. Events reach a job's program through init,
  not ccsh, so ccsh learns of stops and ends asynchronously (`proc_stop`,
  `proc_exit` on CC's queue): `jobs` right after `bg` can say Running
  for a job that has just ended, as in Unix.
- **To revisit:** streaming pipes (stages as concurrent processes, a
  kernel-mediated pipe), SIGTTIN for background reads, a `setsid`/`nohup`
  for jobs meant to outlive a shell (today: `service`, or `bg prog`).

## Action items

Phase 1 (built, ccnix 0.15.0):

1. [x] lib/proc: sessions, groups, terminals, foreground, Ctrl+Z, STOP,
   TSTP and CONT with held events, `kill(-pgid)`, `proc_stop`,
   `proc_cont`, `proc_exit`'s status, hangup, orphans, `enter`/`leave`,
   capture inheritance, the API.
2. [x] ccsh: programs as processes, job groups, `toFront` at the
   transitions, `proc_*` routed to their job, `kill`, `fg`, `bg` and
   endJobs on groups; the drive path kept for no init.
3. [x] telnetd (`proc.input`, `pts/n` sessions), init (sessions), ps
   (STAT, PGID), kill (signals, groups).
4. [x] sims: sim/proc.lua section 8; sim/jobs.lua (ccsh under the
   kernel); sim/ccsh.lua unchanged (no init); help regenerated.

Phase 2 (in game, by the user):

5. [ ] On the console: `ps -l` while `telnet towel.blinkenlights.nl` runs
   (from a telnet session), Ctrl+Z, `jobs`, `fg`, `bg`, `kill %1`.
6. [ ] In a telnet session: the same, and Ctrl+] t (interrupt) reaching
   the program, not the shell; dropping the connection ending its jobs.
7. [ ] A ccsh script as a service: its programs' output captured.
