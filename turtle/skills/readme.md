# Skills for claude

Procedures for the model that drives a turtle through `turtle/claude.lua`
(ADR-0013 D10). Each is written from the in-game model's field reports:
what to do for a kind of goal, which `T` calls to use, the checks before
and after, and the pitfalls the field found.

The model isn't sent these files whole. A session lists each skill's name
and description (about 20 tokens a skill), and the model reads a body
with `fs` when a goal fits it, so a body costs nothing until it's read.

## Format

One folder a skill, `turtle/skills/<name>/skill.md`, the shape of Claude
Code's skills (`SKILL.md` there; the name is lowercase here because the
mod's ROM is a data pack, whose paths take no capitals: `sim/run.py
--check` says so):

```
---
name: <name, the folder's name: lowercase words and hyphens>
description: <one line: what it's for and when to use it>
---
<the procedure>
```

- The description is all the model sees until it opens the file, so it
  says when to reach for the skill, in under about 150 characters.
- The body is for a capable reader that writes Lua against turtlelib: the
  steps, the real signatures and options (check each against
  `help/turtlelib.txt`), what to check before and after, the pitfalls,
  and what to tell the player. 40 to 90 lines.
- Nothing about one world: no coordinates, player names or places. These
  ship in the ROM to every server.

## The model's own skills

The model keeps its own in `/claude/skills/<name>/skill.md` on the
turtle. One of the same name as a shipped skill wins, so it can refine
ours for its world; the shipped one stays in the ROM, untouched.

## Shipped

| Skill | For |
|---|---|
| `build-for-player` | stairs, walkways, rooms and signs a two-tall player uses |
| `light-an-area` | lighting a place so mobs can't spawn, per dimension |
| `redstone-and-doors` | doors, buttons, levers, dust, repeaters and locks |
| `big-jobs` | scope, estimates, batches and caps for long digs, harvests and builds |
| `storage` | chest categories, sorting, stowing and fresh counts |
| `field-report` | keeping `/claude/report_harness_v<N>.md` for the next pass |
