# ADR-0013: What the turtle learned on 0.52: the cost of clearing, chat while it works, and building for the player, third pass

**Status:** Accepted (2026-11-17): D1, D2 and D4 to D8 as recommended;
D3 as option C (everything that reports speaks to everyone unless
`turtle.player` is set); D2 with the longer-term path through ADR-0006;
D6's light threshold checked against the game's code (below); D9 added
the same day (compaction and tidy notes), amending D1's deep clear, and
settled as B and C together (below); D10 added the same day (skills)
**Date:** 2026-11-17
**Deciders:** Dan Theisen

## Context

The same turtle that ADR-0011 and ADR-0012 learned from ran ccnix 0.52.0
on 2026-11-17 (UTC) for about ten hours. That was two `claude --steps
200 --cache 1h` sessions on Opus 5.5 at medium effort, and 16 goals:

- an example staircase;
- signs, a walk-through audit, a tower ladder and lighting;
- a balcony built from a blueprint, and top slabs under the gate stairs;
- a settings helper and storage sorting;
- the keep's fit-out and a locked bunker door (four versions);
- a cross-dimension storage install and a portal test.

Its third report, `/claude/report_harness_v3.md`, lists what worked and
what got in its way, ending in seven "top improvements". The user
fetched the turtle's files and logs and asked for the next pass, and
separately asked whether a recent spike in API spend was a regression or
bigger tasks.

**Method.** The turtle-field-report skill.

- Three read-only reviewers went over:
  - the field evidence (the report, the notes, the helpers, four rotated
    logs covering the whole run, the state files);
  - turtlelib against every library claim;
  - claude.lua against every harness claim, and the logs' token lines.
- The claims this ADR rests on were checked in the code, and the API
  facts in Anthropic's docs (context editing, prompt caching).
- The sims repeat byte for byte on main at 0.52.0, which is the baseline.

### What the log says

The day had 428 API calls and 353 code runs.

**Spend.** The weights below are Opus 5.5's prices relative to one
uncached input token: a cache read 0.05, a 1-hour cache write 2, output 5.

| | calls | input a call (median) | weighted cost a call |
|---|---|---|---|
| 0.50, 2026-11-15 (before ADR-0011) | 129 | 256k | about 20k |
| 0.52, 2026-11-17 | 428 | 124k | about 32k |

- The spike is both causes. The day was long, and each call cost about
  57% more than on 0.50.
- **The extra is cache rewrites.** 41 calls read only the system prompt
  and tools from the cache (27,773 tokens) and wrote the rest of the
  conversation again, 65k to 150k tokens each.
  - That was 3.9M of the day's 4.5M tokens written, and about 57% of
    the day's cost.
  - About 20 of them came from the thinking edit. It keeps the last 3
    "thinking turns", and every user message (a new goal, a heard chat,
    a reminder) starts a new turn. So the oldest turn's thinking is
    cleared and the cache breaks from there.
  - About 16 came from the tool-result clear, which fires every 8 to 10
    calls and frees about 30k (`CLEAR_AT_LEAST`, claude.lua:228).
  - One came after a five-hour stop on the workspace's usage limit.
- **0.50 never rewrote.** Its clear was stuck at the same 115 results
  (ADR-0011): the input was large but always cached.
- **0.51 made clearing work.** It added old code and thinking to what is
  cleared, so clearing now fires, and at this size each firing costs
  more than it saves.
  - A rewrite of about 100k costs 200k.
  - Freeing 30k saves 1.5k a call for the 8 calls until the next one.
- Anthropic's guidance matches: context editing "is a context-window
  tool, not a savings lever ... set the trigger high enough that clears
  stay infrequent, and clear in a few large batches". Their docs also
  say clearing thinking "invalidates the cache at the point where
  clearing occurs".
- The log hid this:
  - the thinking edit is logged as "0 old tool results cleared (N
    tokens)" (claude.lua:1969-1973 reads only the tool edit's fields);
  - the two edits' lines alternate, so the "log only when it differs"
    check never holds.

**Size.** ADR-0012 asked whether calls were still 300k.

- No. The median is 124k, and ordinary calls stay between 100k and
  158k. The calls up to 419k were replies with web searches, whose usage
  adds up several passes.
- The trimmer isn't needed.
- The floor after a clear is about 100k:
  - the system prompt, 28k;
  - the model's `notes.md`, which is 80 KB, viewed once a session
    (28k tokens) and never cleared, since memory is excluded;
  - 76 kept memory edits;
  - the kept thinking.

**Chat.**

- The listener heard every message it could: 9, all while the model
  thought. The chunk controller was never touched.
- But code ran 6,010 s against 5,226 s of model time, so it listened
  through only about 46% of the busy time, not "most of a step" as
  ADR-0012 D3 assumed.
- The missed messages fell in a six-minute window of 26 to 111 s stow
  trips.
- **The first session couldn't speak at all.** With `turtle.player`
  unset:
  - the chat tool, whose description says it goes "to everyone when
    none is set" (claude.lua:444), called `T.report.now`, which refuses
    (journal.lua:308-311);
  - the refusal wasn't logged (the line is written before the send);
  - the start-of-job `T.report.try` failed silently.
  - The player restarted claude after setting it.

**One reply hit `max_tokens`.** That was 32,000 tokens, all thinking,
over 327 s, after the player said the door was broken.

- It isn't logged.
- A second cut-off in the same goal would end the goal as if it were
  done (claude.lua:2006-2017).

**Routes** got into every enclosed building with `opts.inside` lists and
`T.diggable = {}`, which answers ADR-0012's first question for v3.

- The report's "says only 'no path'" is wrong. All 8 search-limit
  failures said "gave up after searching 20000 cells ... (opts.limit
  raises that)". The model cut its own results to 200 characters, and
  the same cut hid a digBelow reason later in the day.

**The lint** is right but noisy, which answers ADR-0012's third
question.

- It found railing gaps above a 15 to 18 block drop, a diagonal railing
  and a head-height lantern, and confirmed each fix.
- But:
  - terrain and rooftop drops round a plan fill T.build's `player:`
    lines;
  - benches made of stairs are taken for flights;
  - the model learned to filter out `rule ~= "drop"`.

**Confirmed in the code:**

- **The map misses placements.** An "already there" placeAt return
  doesn't correct the map (place.lua:1019-1021), and neither does
  T.build's plain-block path (blueprint.lua:876-881).
  - `T.look` notes only turtlelib's short cache, never the map
    (turtlelib.lua:1396-1410).
  - Seen in the field: the map said air under a wall that placeAt had
    just found there, and the lint reported a gap.
- **Torches and standing signs can't go on top of a wall or fence.** The
  "hang" families need a sturdy block below, and walls and fences are
  marked not sturdy (place.lua:135-137, 369-380). In the game both stand
  on them. Two of the balcony's 28 cells failed this way, and the model
  placed signs by hand with `turtle.placeDown(text)`.
- **digBelow told the model its needs one call at a time:** "digBelow
  digs it", then "carry one soul_soil", then "no free cell beside the
  floor".
  - It asks for a floor block on board even when the block dug comes
    back as itself (place.lua:794-796).
  - On solid ground it has no exit (place.lua:797-800).
- **`T.isEssential` makes every tool essential** (turtlelib.lua:2874),
  so `T.stow` kept looted swords, axes and crossbows aboard. The player
  pointed it out.
- **`T.stow` keeps per-item reasons to itself.** With chests nearly full
  its why names only the first item (store.lua:694, 712-717).
- **Crafting leaves the chest counts stale.** It never updates `.chests`
  (craft.lua:851). Neither did the model's own drops: "catalogue said 8,
  got 4".
- **`T.addChest` on the other half of a known double chest returns `true,
  nil` and adds nothing.** The model was confused by it four times.
- **A nether portal is neither unbreakable nor avoided** (path.lua:60-65,
  turtlelib.lua:1468), so a `dig = true` route could plan through one.
  The turtle got "Movement obstructed" walking into one.
- **Recipes the model added itself:** barrel, redstone torch, repeater,
  lever, stone button, iron door, respawn anchor and soul campfire. None
  of them are built in.

**What the model built itself** (claude/helpers/):

- **A light model** (a block-light flood fill and the dark cells where
  mobs can spawn). Its first version tripped CC's "too long without
  yielding". It bounds the flood to the box, so it misses lights outside.
- **Chest categories with a sorting job.**
- **Its settings** (keep items, diggable, cfg), which is where they
  should be.
- The rest of `helpers.lua` duplicates what turtlelib has: `say`,
  `askPlayer`, `batchCraft`, `digCell` and `furnaceSmelt`.

**Not seen.** Resume (D4 of ADR-0012) was never set up, so it is still
untested in game. `T.placeDir(d, text)` and `T.frameId` were never used.

## Decision

1. **Context editing tuned for cost:** keep all thinking while the
   conversation grows, then one deep clear of thinking and old tool
   results together at a high mark (D1).
2. **Chat heard while code runs:** the chat box stays on through a run,
   and the pickaxe comes back only when something digs (D2).
3. **Reports speak to everyone unless `turtle.player` is set:** the chat
   tool, `T.report` and the programs that use it, and a claude session
   says at its start that none is set (D3).
4. **`max_tokens` 64,000.** A second cut-off in a goal ends the goal with
   the reason (D4).
5. **Which tools are essential:** `T.cfg.tools` (D5).
6. **New functions:**
   - T.darkCells and T.light;
   - T.attachedTo with `T.digCell{attached}`;
   - signs placed toward a reader;
   - chest categories and T.sortChests (D6).
7. **digBelow's two-cell exit** on solid ground (D7).
8. **No automatic search-limit retry** in T.travel (D8).
9. **Compaction instead of the deep clear, and tidy notes** (D9, added
   after the user's question: clearing is a bulldozer, and the turtle
   did worse this round): at a goal's end over 100k, and inside a goal
   at 250k keeping the last turns; clearing only when no summary comes.
10. **Skills:** shipped procedures and the turtle's own, listed by name
    and read when a goal needs them (D10).
9. **Phase 1 (defects and feedback, no decision):**
   - the map records what `T.look` and placeAt find;
   - torches and signs on top of walls and fences;
   - digBelow takes a floor block that drops itself, and lists every
     need at once;
   - the lint split into "in the plan" and "around it", plus a rule for
     lights in walkways;
   - a route failure names the furnishings that blocked it;
   - per-item stow reasons, chest recounts after crafting, and
     `T.addChest` on a double chest's other half;
   - a nether portal is unbreakable for routes;
   - placing repeaters, comparators, observers and pistons by facing;
   - the missing recipes;
   - the harness's log lines (context edits by type, chat refusals,
     cut-offs, cache rewrites);
   - a session-start warning when the memory files are large.
10. **Phase 2 (the model's knowledge):**
    - a turtle can't open doors, press buttons, set a repeater's delay
      or pass a portal;
    - put a block back with `T.placeAt`, not by placing up from the hole;
    - `T.moveTo{path = true}`;
    - read a result's whole why before cutting it;
    - keep `notes.md` short.

## Options considered

### D1. Context editing and the cache

| | A: as now | B: rarer, bigger clears | C: keep thinking, one deep clear at a high mark |
|---|---|---|---|
| What | thinking: the last 3 turns kept; tools: clear from 100k, at least 30k | the same, with the trigger 160k and at least 80k | thinking kept (`keep: "all"`) and no tool clear while the last call's input is under a mark (180k); at the mark, one request clears both (thinking kept 1 turn; the old tool uses, the last 6 kept, at least 0) |
| Rewrites (this day's work) | 41 | about 25: one a goal remains | about 1 per 25 to 30 calls, about 15 |
| Weighted cost a call (model) | 32k | about 24k | about 16k |
| Lines | 0 | 1 | about 25: the mark, the per-request edits, the sim |
| Verification | | claude_drive's config checks | claude_drive: under the mark the request carries no tool clear and keeps all thinking; over it, both clear; sim 19 with both edits in one reply |
| Needs checking | | | whether changing the edit settings on one request leaves the cache alone apart from what it clears (the docs say clearing invalidates "at the point where clearing occurs"); the thinking count's field name (`cleared_thinking_turns`, as the docs' example has it) |

**C.**
- The thinking edit is what costs a rewrite at every goal, and only
  keeping all thinking avoids it.
- One deep clear at a mark pays one rewrite down to the floor (about
  60k to 100k) for 25 or more cheap calls.
- The hard clear after "prompt is too long" stays as it is.
- The `/new` command (a fresh conversation) is still the cheapest break
  between unrelated goals. The prompt can say so to the player through
  the model.

### D2. Hearing chat while code runs

| | A: as now (B' of ADR-0012) | B: a lazy pickaxe | C: the mod relays chat |
|---|---|---|---|
| What | the chat box is on the free side only while the model thinks | the chat box stays on through the code run, and the run is wrapped in `parallel.waitForAny` with the listener (parallel gives every coroutine the events it waits for, so turtle commands lose nothing). turtlelib's wrapped dig and attack, and `T.usePrimaryTool`, put the pickaxe back on first need and leave it there until the run ends. `run_program` gets the pickaxe first. | ccnix-mod queues a `chat` event to opted-in computers on the server's chat event, so nothing is equipped; it still needs B's parallel listener |
| Heard | 46% of the busy time | everything in runs that don't dig (the long ones are travel and stow trips); runs that dig, until the first dig | everything |
| Lines | 0 | ~20 turtlelib, ~30 claude.lua | ~80 Java, ~20 Lua, two lockstep pull requests, and a server setting |
| Blast radius | | the model's `T.equipped()` shows the chat box during a run (the status line says so); a raw `turtle.dig()` with no pickaxe fails with "No tool to dig with", and the prompt says to use T.dig | a computer can read all chat (gated by config) |
| Verification | sim 36 | new claude_drive scenarios: chat during a run with no dig is heard; a dig mid-run gets the pickaxe back and the run carries on; `run_program` gets the pickaxe | a mod test and a sim with fake events |

**B.** It hears most of what's missed today and never touches the chunk
controller (equip parks only tools, as in ADR-0012). It is all in this
repo. C stays named for later, if B still misses too much.

**Accepted, and the better path is ADR-0006's** (the user, 2026-11-17):
when turtled gains control of claude bots, an Opus (selectable) model
drives Sonnet (selectable) agent bots, or other kinds of bot, and the
player's chat reaches them over CC's `http` through the gateway (ADR-0006
option 1), with no chat box on any turtle. That path is to work in NAT
mode too, not only TUN. B is what a lone turtle has until then. With B
or C:

- every result says how long its run took ("took 91 s");
- a `chatHeard()` in the code's world returns what was heard so far, so
  a long loop can react;
- `T.report.ask`'s wait passes on the player's other messages instead of
  dropping them.

### D3. The chat tool with no player set

| | A: fix the description only | B: the chat tool speaks to everyone | C: B, and programs too |
|---|---|---|---|
| What | the description says it needs `turtle.player` | `T.report.now{everyone = true}` from the chat tool (the ask path and the listener already do this); programs keep "no player to tell" | `T.report` broadcasts by default |
| Blast radius | the model can't speak until someone sets it | claude's words reach everyone on the server when no player is set | mine and mow messages reach everyone |

**C (the user's choice), with a start note.** With `turtle.player`
unset, everything that reports (the chat tool, `T.report`, and mine,
farm and mow through it) speaks to everyone; set, only that player. A
claude session with none set says so on screen and in its first result:
"reports go to everyone; `sysctl turtle.player=<name>` makes them
private".

### D4. `max_tokens`

**64,000 (from 32,000).** That is Anthropic's recommendation for agentic
work, and the request already streams.

- On a cut-off the model is told it ran out of room, while thinking or
  writing: "decide with what you have and take a smaller step".
- The log says `cut off at max_tokens (N out, M thinking)`.
- A second cut-off in the same goal ends the goal with that reason
  (today it ends as if done).
- Cost: one runaway reply can cost twice as much as today. It hit the
  cap once in 428 calls.

### D5. Essential tools

| | A: as now | B: `T.cfg.tools`, default nil | C: equipped kinds only, by default |
|---|---|---|---|
| What | every tool is essential (never stowed or dumped) | a set or globs of the tools a job keeps: with it set, only the equipped tools and those listed are essential; nil keeps today's behaviour | B with the default the equipped tools' kinds |
| Blast radius | | none until set; the model's settings helper sets it, and the prompt and news say so | farm and mow (through `T.dumpJunk`) would stow looted tools; mine uses `T.isTool` and is unaffected |

**B.** It fixes what the player saw without changing any program, in
keeping with "keep defaults tight".

### D6. New functions

Each has a sim and a help entry. The model's own copy then goes, and
the news says which.

1. **`T.darkCells(box, opts)` and `T.light(box, opts)`:**
   - a block-light flood fill over the map, from the model's
     `lightmodel.lua`, with three fixes:
     - lights up to 14 cells outside the box count;
     - what light passes through comes from the lint's kinds;
     - it yields;
   - the dark cells where mobs could spawn;
   - the threshold is a parameter, with defaults by dimension from the
     game's code (Java 1.21.1, checked 2026-11-17):
     - **Overworld:** block light 0 (`monster_spawn_block_light_limit`
       0).
     - **Nether:**
       - skeletons, wither skeletons and endermen need a light level of
         7 or less (the Nether's `monster_spawn_light_level` 7 since
         22w46a);
       - zombified piglins, piglins, hoglins and blazes need 11 or less
         (the generic walk-target check that every pathfinding monster
         passes, Mojira MC-156004, still open);
       - ghasts and magma cubes ignore light (they aren't pathfinding
         mobs): only the surface stops them.
       - So the model's "11" holds for most Nether mobs: a cell lit to
         12 or more is safe from all but ghasts and magma cubes, which
         `T.darkCells` names apart ("spawnable whatever the light: a
         slab or glass floor, or no room").
     - Mods in a pack can change spawning, so the first in-game check
       compares the dark cells with where mobs appeared.
   - About 80 lines, in a new `tl/light.lua`, with a new sim.
2. **`T.attachedTo(x, y, z)`:**
   - what in the map hangs on or stands on a block: torches, redstone,
     rails, ladders, signs, buttons, levers, doors, lanterns;
   - "maybe" where the map has no state;
   - `T.digCell(x, y, z, {attached = "refuse"})` refuses a dig that
     would drop them, and says what;
   - the wrapped dig that mine and farm use is unchanged.
   - About 60 lines.
3. **Signs toward a reader:**
   - `opts.toward = {x, y, z}` on a sign: a wall sign when a sturdy
     block stands behind the cell, else a standing sign turned (its
     `rotation`) to face the reader;
   - `T.signFor(reader, text)` finds the cell in front of the reader.
   - About 35 lines.
4. **Chest categories:**
   - `T.addChest(..., {holds = globs})`;
   - `T.stow` prefers a chest that holds the item's kind;
   - `T.sortChests()` moves what's in the wrong chest;
   - the model's `storage.lua` without its world-specific stands.
   - About 50 lines.

**All four.** Each is a field request with a working helper or a field
failure behind it.

### D7. digBelow on solid ground

With digBelow asked for and no free cell beside the floor:

1. dig a neighbouring floor cell that has air above it, isn't protected
   and has no liquid beside it;
2. step in, dig the target's floor sideways, step in;
3. place up;
4. step back, refill the target's floor, step up, refill the neighbour.

It digs two of the player's floor cells, not one. Both go back as they
were, and only when the job asked for digBelow. About 50 lines.
**Recommended.** The model did exactly this by hand in Part 1.

### D8. Search-limit retry

**No automatic retry.** The message already says what to do; the model
cut it off itself. Phase 2's "read the whole why" is the fix, and a
retry would double the worst case of a search that can't succeed.

### D9. Compaction and tidy notes (added 2026-11-17)

The user asked for "context compaction" on the notes and the rest of the
turtle's memory instead of clearing ("a bulldozer move"), having seen
the turtle do worse this round.
- Since 0.51 a clear deletes the model's own old code and thinking and
  leaves placeholders, so mid-goal it loses the trail of what it tried
  and why.
- The log can't prove that's why it did worse, but Anthropic's
  compaction docs say the same thing: "response quality degrades as a
  conversation grows".

**The API's on-demand compaction** (beta `compact-2026-09-04`, Opus 5.5
and Sonnet 5.5 among its models):
- It is a request of its own, carrying the conversation as it stands
  and a `compaction` parameter.
- The reply is one signed block: a summary the model writes, having read
  everything, thinking included.
- The block then goes first in `messages`, in place of what it
  summarizes. Recent turns can be kept word for word. `instructions`
  replace the summary prompt (up to 16,384 characters; they must say
  "no tool calls").
- `cache_control` on the block puts a breakpoint after it. The call is
  billed as a request (`usage.iterations`).
- It can't carry `context_management` itself.

| | A: D1 as accepted (one deep clear at a mark) | B: compaction at goal boundaries, clearing as backstop | C: B, and compaction mid-goal too |
|---|---|---|---|
| What | thinking kept; at 180k, thinking and old tool results cleared | when a goal ends with the conversation over a mark (100k), the harness compacts it while it waits for the next goal, with our own summary prompt; D1's "keep all thinking" stays; a clear only at a hard high mark inside one long goal | also at the hard mark inside a goal, keeping the last few turns word for word |
| What the model keeps | placeholders where its code, results and thinking were | a summary of everything: open tasks, the player's words and corrections, places, what's built and how, lessons, helper names | the same |
| Cost a time | a rewrite of the floor (~100-200k weighted) | the summary call (~6k reading the conversation from the cache, ~5k written: ~30k weighted) and a small new prefix | the same, more often |
| Lines | done in D1 | ~80 claude.lua, the claude_drive mock's compaction reply | +~40 (the keep-recent split) |

**B and C (the user, 2026-11-17).**
- At a goal boundary nobody waits, since the harness is waiting for the
  player anyway: when a goal ends with the last call's input over 100k,
  the conversation is compacted while the player types, and before
  their goal is sent if they're quicker.
- Inside a goal, once a call's input reaches 250k, it's compacted right
  after a batch of tool results (never with a reply still waiting on
  its results), the last 3 turns kept word for word.
- This replaces D1's deep clear at 180k as the mid-goal step: under the
  mark all thinking is kept and no tool call cleared. Clearing stays as
  the emergency fallback: the hard clear after "prompt is too long", and
  D1's deep clear when a compaction brings no summary.
- The summary prompt is ours: the goal and how far it got, open tasks,
  the player's words, preferences and corrections, places, what's built
  and how, lessons, helper and skill names, the T calls that worked; no
  tool calls, short.
- The model starts each goal on a summary instead of a heap of
  placeholders.

**Tidy notes.** The memory file `notes.md` was 80 KB, about 28k tokens
every session, and is never cleared. When the notes pass 32 KB at a
session's start (#43 already warns), the session's first task is to tidy
them:
- the model rewrites `notes.md` as the current state (about 12 KB);
- it moves the rest to `/claude/notes-archive/<date>.md`, which it can
  read with `fs` and which isn't loaded.

The model does it, not a cheaper summarizer, because it knows what
matters. Nothing is lost. The task runs before the player's goal, or as
`/tidy`. Stable procedures it finds go into skills (D10).

### D10. Skills (added 2026-11-17)

The user asked to give the turtle skills, and to let it write its own.

**Today** there are two half-measures:
- `keep(name, code)` keeps Lua helpers that load every session.
- The model writes plans and lessons to loose files (`bunker.md`, an
  install plan, a job-errors report). It finds them again only if its
  notes point there, and their lessons never reach the next session's
  first thought.

**A skill** is a folder holding `skill.md`, the same shape as Claude
Code's skills:
- the frontmatter has a `name` and a one-line `description`;
- the body is a procedure: steps, rules, pitfalls, which `T` calls to
  use;
- it may name helpers kept with `keep()`.

**Two sources:**
- **Shipped in the ROM** (`turtle/skills/<name>/skill.md`; lowercase,
  not Claude Code's `SKILL.md`, since the ROM is a data pack and its
  paths take no capitals), written from
  the field reports. The first set:
  - `build-for-player`: headroom, railings, top slabs, T.lint and
    T.walkable;
  - `light-an-area`: T.darkCells, flush lights, the Nether spawn groups;
  - `redstone-and-doors`: restate the ask, T.attachedTo before a dig,
    verify states, the player tests buttons;
  - `big-jobs`: a box not a filter, estimate first, batches, budgets
    (its own rules after the runaway harvest);
  - `storage`: categories and T.sortChests;
  - `field-report`: keeping `report_harness_vN.md`.
- **Its own** (`/claude/skills/<name>/skill.md`):
  - `skill(name, description, body)` in the code's world writes one, as
    `keep()` writes a helper, and refuses a bad name or a missing
    description;
  - its own skill of the same name wins over a shipped one, so it can
    refine ours;
  - the prompt says to write one when a task taught a procedure worth
    repeating. D9's notes tidy is when stable procedures move out of the
    notes into skills.

**Loading:**
- Only names and descriptions are listed, about 20 tokens a skill.
- The list goes in the session's first message, not the system prompt,
  so a skill written mid-session doesn't break the cache.
- The model reads a body with `fs` when a goal fits it.
- Procedural paragraphs of today's system prompt can move into shipped
  skills, which makes every call cheaper.

**Not the API's own Skills.** Those run in Anthropic's code-execution
sandbox, which can't reach the turtle.

**Accepted.** About 100 lines in claude.lua, a claude_drive scenario, and
the seed skills as text.

## Trade-off analysis

- **The spend:** the largest item (D1) is a harness setting with no
  effect on what the turtle does, and it halves the cost of a call. It
  goes first.
- **Chat:** chat is the player's channel, and D2 hears it without the
  mod or the chunk controller. Two swaps a digging run is the price.
- **No changes to programs:** every default that touches mine, farm or
  mow stays (D3 B, D5 B).
- **What this pass declines:**
  - the trimmer (calls are 124k);
  - named routes (routes got in);
  - a `T.restore` (`T.placeAt` already stands outside the cell);
  - a scan with states (`T.inspectAt` and `T.inspectAll` exist);
  - the travel retry.

## Consequences

- A call costs about half of today, and the log says when the cache was
  written again and why.
- The player's chat is heard through travel and stow trips. A session
  with no player set says so and can still speak.
- Builds of walls with torches or signs on them, and top slabs on solid
  ground, need no hand placing.
- **The next field report (v4) should say:**
  - the weighted cost a call and the rewrites a day (the log's new
    lines);
  - whether chat was missed during runs;
  - whether the light model's dark cells matched where mobs spawned;
  - whether the lint's split quieted the noise.

## Action items

### Phase 0

1. [x] The baseline (two runs byte for byte the same) on main at 0.52.0.
2. [ ] Each field failure as a sim scenario that fails today:
   - a torch on a wall;
   - placeAt "already there" leaving the map air;
   - the chat tool with no player;
   - digBelow on soul soil;
   - a portal on a dig route;
   - `T.addChest` on a double chest's second half;
   - a second cut-off.

### Phase 1: no decision

1. [ ] `T.look` notes into the map when the world module is loaded;
   placeAt's "already there" and "in the way", and T.build's plain path,
   correct the map.
2. [ ] Walls and fences hold a torch or a standing sign on top: a "holds
   on top" test apart from "sturdy".
3. [ ] digBelow:
   - takes no carried block when the floor drops itself (TEMP_BLOCKS
     and soul soil, soul sand, basalt) and a slot is free;
   - lists every need at once.
4. [ ] The lint:
   - T.build's `player:` lines show the plan's warnings and "N more
     round it";
   - a lone stair with no flight isn't a flight;
   - a "light" rule: a wall torch or hanging lantern in a walk cell's
     feet or head cell.
5. [ ] A route that fails with furnishings in the way names the cells
   ("a way exists through minecraft:wall_torch at x,y,z: lift and put it
   back").
6. [ ] Storage:
   - `T.stow`'s why per item ("chest at x,y,z full");
   - `T.recount(side)` after crafting or smelting at a known chest;
   - `T.addChest` on a known double chest's other half says so.
7. [ ] `minecraft:nether_portal` unbreakable for routes.
8. [ ] A directional family in tl.place: repeater, comparator, observer,
   piston, dispenser, dropper, placed by facing.
9. [ ] Recipes: barrel (any wood), redstone torch, repeater, lever,
   stone button, iron door, respawn anchor, soul campfire.
10. [ ] The harness log:
    - the context edits by type ("old thinking cleared");
    - "cache written again: N (why)" when a call reads only the system
      prompt;
    - chat refusals;
    - cut-offs.
11. [ ] At a session's start, when `/claude/memories` is over 32 KB:
    "your notes cost N tokens every call: move the old to an archive".

### Phase 2: the model's knowledge

1. [ ] Prompt and manual lines:
   - a turtle can't open doors or trapdoors, press buttons, set a
     repeater's delay or pass a nether portal: ask the player to test
     them;
   - put a block back with `T.placeAt`;
   - read a result's whole why before you shorten it;
   - keep `notes.md` short.
2. [ ] Index lines for `T.moveTo{path = true}`, and `T.inspectAll` as
   the scan with states.

### Phase 3: the decisions

1. [ ] D1 to D10 as decided.

### Phase 4: release and hand back

1. [ ] `doc/claude-news.txt`, which tells the model which helpers to
   retire:
   - `say` and `askPlayer` (the chat tool, `T.report`);
   - `batchCraft` (`T.craftBatch`);
   - `digCell` (`T.digCell`);
   - the recipe files;
   - `lightmodel` (D6.1, if accepted);
   - `storage` (D6.4, if accepted).
2. [ ] The version bump (minor), UNTESTED.md and the lockstep bump.
3. [ ] Mark this ADR Accepted.

### Later (named, not planned)

- The mod's chat relay (D2 C), or rather ADR-0006's bot control (the
  D2 note), with its `http` path made to work in NAT mode.
- A redstone-aware build: wiring as a blueprint.
- `T.canEnter(name)`.
- A stop flag a long run checks: "claude stop" in chat.
