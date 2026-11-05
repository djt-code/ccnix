# ADR-0004: Logging: a syslogd under init, lib/log, captured service output, RFC 5424 forwarding

**Status:** Accepted (2026-11-03). Phase 1 built in ccnix 0.14.0; phase 2
(in game) to verify
**Date:** 2026-11-03
**Deciders:** Dan Theisen

## Context

CraftOS and CC: Tweaked's Lua APIs have no logging facility: no syslog, no
levels, nothing that reaches the Minecraft server's log from Lua. A program
draws on a terminal object (`write`, `setCursorPos`, `scroll`); there is no
stdout stream. What ccnix logs today:

- `httpd` and `telnetd` `print` lines stamped `HH:MM` on their own screen.
- lib/net's stack keeps its last 50 notes (dropped packets, ARP failures, a
  hook's errors) in memory, `S.log`, and hands each to `opts.log` if set.
- Services run under init (lib/proc) on a hidden window each; `service
  status` reads back what's still on it. Nothing reaches a disk, nothing
  outlasts a reboot, and nothing leaves the computer.

The user wants a logging facility in the Unix shape: programs call a small
API, a daemon routes what they send by `/etc/syslog.conf`, logs go to files,
and they can be forwarded to a real syslog server (rsyslog on the VM, say)
over the ccnix network.

Forces:

- **The Unix model, kept small.** `syslog(3)` sends a datagram to `/dev/log`;
  syslogd matches `facility.severity` selectors and writes, prints or
  forwards; `logger(1)` is the shell's way in; newsyslog or logrotate rotate.
  Real-protocol compatibility is welcome (RFC 5424 on the wire), but no more
  of rsyslog than ccnix needs.
- **CC's limits.** A computer's event queue holds 256 events and drops
  every kind beyond that, timers included, so a program logging in a loop
  must not fill it. Disks are small (1 MB a computer by default). Time is
  `os.epoch("utc")` (real milliseconds) or the game's; logs want the real one.
- **lib/proc already has the plumbing.** `K.current` is the process running;
  `K.inject(pid, ...)` hands one process an event through `K.inbox`, a Lua
  table, never CC's queue; each process has its own terminal and a
  `service` name when init started it as one.
- **How CraftOS writes text** (CC: Tweaked's `rom/apis/io.lua` and
  `bios.lua`): `print` and `printError` go through the global `write`, looked
  up at each call; `io.stderr`'s handle calls `_G.write` at each call;
  `io.stdout`'s handle took its own copy of `_G.write` when io loaded at
  boot (`make_file({ write = _G.write })`), so wrapping `_G.write` later
  misses `io.write`. Its handle keeps that function in `io.stdout._handle.write`.
- **The gateway is transport only.** A UDP datagram to port 514 crosses it
  like any other: TUN routes it; NAT admits it as its config says. The mod
  needs nothing for this (checked: `Nat.udpOut`, `Ipv4.bytes`; only a
  string payload crosses, which syslog's is).
- **Two codependent repos**, ccnix 0.13.0, ccnix-mod 0.15.5; ccnix's sims
  (`python sim/run.py`, `--check`) with fakes of lib/proc and the network.

## Decision

### D1. A daemon (decided)

`syslogd` is a service under init. Programs reach it through `lib/log`,
which hands each message to syslogd's process with `proc.inject` (an
in-memory inbox, not CC's event queue). syslogd routes it by
`/etc/syslog.conf`. Without init running, lib/log appends to
`/var/log/messages` itself, in the same format, so a program never has to
care.

### D2. Service output: explicit logging plus capture (decided: option B on A)

- **A: ccnix's own daemons log through lib/log**, with real severities and
  facilities: `httpd` (daemon, its access lines info, a page's error err),
  `telnetd` (its own facility: logins notice, a wrong password warning;
  decision 5), init itself, and lib/net's stack (kern, tag `net`, only
  under init: a router without init keeps its notes in memory as before).
- **B: init captures every service's prints**, the way journald takes a
  unit's stdout. Init wraps `_G.write`, `_G.printError` and
  `io.stdout._handle.write` once, at start. Each wrapper draws as before
  (the hidden window and `service status` still work), and if `K.current`
  is a service process with capture on, gathers the text into lines and
  logs each one under the service's name: facility daemon, severity info,
  err for `printError` and `io.stderr`. A line starting `<N>` (0-7) is
  logged at severity N with the prefix taken off, as journald reads it.
  A partial line is logged when it reaches 1 KiB or the process ends.
- **Not captured:** console processes (the user's shell; `cmd | logger`
  covers that), a service's children (telnetd's sessions), anything drawn
  with `term.*` directly (`edit`, menus, progress bars), and what lib/log
  itself echoes to a screen (`perror`, below), so nothing is logged twice.
  `service.<name>.log = false` turns capture off for one service.

Init's own messages go to the log too: a service started (pid), ended,
failed (its error), restarting in n seconds, stopped.

### D3. Forwarding (decided)

An `@host[:port]` action sends each matching message as an RFC 5424
datagram over UDP (RFC 5426), port 514 unless given. syslogd can also
listen on UDP 514 (off by default) and take RFC 5424 or RFC 3164 messages
from other computers, so one CC computer can be the loghost for others.

## The pieces

### lib/log (the syslog(3) of ccnix)

```lua
local log = require("log")
log.open("httpd", "daemon", { pid = true, perror = false })   -- openlog
log.info("listening on port %d", 80)                          -- printf-style
log.err("%s: %s", path, why)
log.log("warning", "...")                                     -- syslog(priority, ...)
log.mask("info")                                              -- setlogmask(LOG_UPTO(LOG_INFO))
```

- Severities `emerg alert crit err warning notice info debug` (0-7);
  facilities `kern user mail daemon auth syslog lpr news uucp cron authpriv
  ftp` and `local0`-`local7`, numbered as RFC 5424 numbers them. The
  default is `user`; a message's PRI is facility * 8 + severity.
- A message is `{ pri, time (os.epoch "utc"), host, app, pid, msg }`. The
  host is the computer's label, or its ID when it has none (as ccsh's
  `$HOSTNAME`).
- `perror = true` also writes it to the program's own screen (LOG_PERROR).
- Without `log.open`, the app is the running program's name and the pid
  the process's.

### syslogd

- Runs as a service (`setup init` defines it and enables it). It
  registers with init (`proc.register("syslog")`); lib/log hands every
  message to `proc.log`, and init passes it to whichever process
  registered. Messages logged before it runs (boot, init's first lines)
  wait in init, at most 200, and are handed over when it registers.
- Reads `/etc/syslog.conf` when it starts: `service restart syslogd`
  after a change. (`kill -HUP` is Ctrl+T under lib/proc, so it ends
  syslogd, and init starts it again a second later, which rereads the
  rules too.) Without the file it uses the defaults below.
- **Selectors**, as BSD's and rsyslog's: `facility.severity` (that severity
  and worse), `facility.=severity` (that one alone), `facility.none`, `*`,
  lists with `,`, several selectors with `;`; `!prog` starts a block for
  one program, `!*` ends it. Every matching line gets the message.
- **Actions:** a file (append); `/dev/console` (printed on the console,
  red from err); `@host[:port]`.
- **Defaults** (no syslog.conf):

```
*.info;auth,authpriv.none;local6,local7.none    /var/log/messages
auth,authpriv.*                                 /var/log/auth.log
local6.*                                        /var/log/telnetd.log
local7.*                                        /var/log/httpd.log
*.crit                                          /dev/console
```

  telnetd logs as `local6` and httpd as `local7` (nginx's default), each
  changeable (`telnetd.facility`, `httpd.facility`; the rules must follow).

- **Files:** a line each, `2026-11-03T14:02:11Z host app[pid]: msg` (the
  RFC 3339 form rsyslog writes). A file past `syslog.maxSize` bytes
  (default 32768) is renamed `<name>.1`, the old `.1` dropped, as
  logrotate's `rotate 1` (`syslog.keep` says how many to keep, default 1).
- **Rate limit:** at most `syslog.burst` messages (default 100) per app in
  10 seconds; past that, one `syslogd: n messages from app suppressed`
  when the window ends, as journald does. This also breaks the loop of a
  forward that fails (no ARP answer from the loghost) and logs its own
  failure, which is then forwarded.
- **Backlog:** past 500 events waiting in init's inbox, init drops new
  messages and counts them; the count goes to syslogd ahead of the next
  one it takes.
- **The wire** (RFC 5424): `<PRI>1 2026-11-03T14:02:11.123Z host app pid - - msg`,
  no structured data; a datagram at most 2048 bytes, the message cut to fit.

### logger

`logger [-p facility.severity] [-t tag] [-s] [message...]`, as logger(1):
the message from its words, or each line read from its input when it has
none (`cmd | logger -t backup`); `-s` also prints it on stderr. Default
`user.notice`, tag `$USER` when it's set, else `logger` (logger(1) uses
the login name). `-i` adds logger's process ID (under init).

### Reading the logs

`tail`, `more` and `grep` on `/var/log/*` as on Unix. `service status
<name>` keeps its screen lines.

## Options Considered

### Where messages go first

| Option | Assessment |
|---|---|
| **proc.inject into syslogd's inbox** (chosen) | In memory, ordered, never CC's 256-event queue; needs init. |
| `os.queueEvent("syslog", ...)` | Works without init, but every message is a CC event: a loop of logs drops timers and modem messages. |
| Each program appends to the file itself | No daemon, so no routing or forwarding; several programs writing one file. Kept as the fallback without init. |

### Capturing service output

| Option | Assessment |
|---|---|
| **A: explicit lib/log only** | Simplest; programs that don't know lib/log leave nothing. Part of the choice. |
| **B: wrap `write`, `printError`, `io.stdout`** (chosen, on A) | Real text with real line ends, err from printError; screen UIs log nothing (right). Shared globals: the wrappers must do nothing outside a service process. Depends on io.lua's `_handle` field. |
| C: wrap each service's terminal | Catches `term.write` too, but lines are guessed from cursor moves: a progress bar is hundreds of messages, a full-screen program nonsense. |
| D: read the hidden window back | Loses what scrolls off between polls; costs every tick. |
| E: `service.<name>.output` to a file | A second log path beside syslogd, with no routing; covered by lib/log's fallback. |

### The config

| Option | Assessment |
|---|---|
| **`/etc/syslog.conf`** (chosen) | The real syntax, which anyone who's run syslogd reads; one file to copy between computers. The first file ccnix keeps in `/etc`. |
| settings (`syslog.rule.1 = ...`) | ccnix's usual place, but rules are an ordered list of lines, which settings hold badly. |

Plain numbers (`syslog.maxSize`, `syslog.keep`, `syslog.burst`,
`syslog.listen`) stay settings, as ccnix's others are.

## Trade-off Analysis

The daemon costs a service and a hop through init for every message, and
in return gives one place that routes, rate-limits, rotates and forwards,
the way Unix programs never write their own log files. Capturing prints
makes every service log something without touching it, at the price of
three wrapped globals and a dependence on how io.lua stores stdout's
writer: if a later CC: Tweaked changes that, `io.write` from services goes
uncaptured (still drawn), and the sims and an in-game check catch it.
Keeping RFC 5424 on the wire, and nothing of rsyslog's beyond selectors
and `@host`, keeps a real rsyslog able to receive without ccnix needing its
template or module system.

## Consequences

- Services' output outlasts a reboot and can be read with `tail`; logins,
  page errors and dropped packets have one place to look.
- A real syslog server can collect every CC computer's logs through the
  gateway; the mod changes nothing.
- ccnix gains `/etc` and `/var/log` on each computer that runs syslogd.
- The wrappers make every `write` a little slower under init (a check of
  `K.current`), console included.
- The disk fills only to `syslog.maxSize * (keep + 1)` per file.
- To revisit: TCP or TLS transport (RFC 6587, 5425), structured data,
  `|program` actions, a `dmesg` for lib/net's ring, `service log <name>`
  (a `journalctl -u`), a mod-side way into the server's log.

## Decisions (the user, 2026-11-03)

1. **syslogd on by default:** `setup init` (and `setup telnetd` or
   `httpd`) defines and enables it, unless it's set up already.
2. **The default rules:** messages, auth.log, crit to the console.
3. **Rotation:** 32 KiB by default, configurable (`syslog.maxSize`,
   `syslog.keep`).
4. **Receiving off by default** (`syslog.listen = false`).
5. **httpd and telnetd get facilities of their own**, routed by the
   default rules into their own files: `local7` to `/var/log/httpd.log`,
   `local6` to `/var/log/telnetd.log`, and out of `messages`.

## Action Items

### Phase 1: ccnix 0.14.0

1. [x] lib/log: severities, facilities, open/new/log/mask, the message
   record, the line and RFC 5424/3164 forms, the fallback (files by the
   same rules), perror.
2. [x] lib/proc: `register`, `log`, `uncaptured`; the early-boot hold
   (200), the inbox backlog limit (500), init's service messages; the
   capture wrappers (write, printError, io.stdout, io.stderr), line
   gathering, `<N>`, `service.<name>.log`.
3. [x] lib/syslogd (the rules and the engine) and bin/syslogd: parsing,
   routing, files, rotation, console, rate limit, `@host` RFC 5424 over
   UDP (names looked up in a child process), `syslog.listen`.
4. [x] bin/logger.
5. [x] httpd, telnetd and lib/net (`N.syslog`) through the log.
6. [x] setup: syslogd with init (decision 1). `help syslog` shows a
   syslog.conf rather than a sample file in deploy/examples.
7. [x] Docs: `help syslog` (doc/syslog.txt), help for the new programs,
   README, `help init` and `help service` on capture.
8. [x] Sims: sim/syslog.lua (lib/log, the rules, rotation, the engine,
   logger, syslogd under a fake init); sim/proc.lua (register, hold,
   capture, backlog); sim/net_tools.lua (httpd filing its requests;
   syslogd forwarding to B and taking B's as a loghost).
9. [x] ccnix-mod: no code change; `ccnix/` and `mod_version` (patch)
   bumped for the ROM, then this repo's `mod/`.

### Phase 2: in game (the user validates)

1. [ ] `logger hello` lands in `/var/log/messages`; a service's prints
   and a failing service's error are captured; the console's aren't. All
   but the failing service's error verified by the user (2026-11-05). That
   test's `service add boom ccsh -c 'cat /nope'` lost its quotes (fixed in
   0.16.0); to retest.
2. [x] Forwarding to rsyslog on the VM (`imudp` on 514, through the
   gateway in TUN mode; NAT mode not tried); a CC loghost receiving from
   another computer (2026-11-05). Found: syslogd's start and "listening"
   line went only to its hidden screen (now logged too), and the defaults
   weren't written out to /etc/syslog.conf (now they are, the first time).
