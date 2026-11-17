---
name: storage
description: Set up and keep the chests at home: find them, give each a category (holds), sort with T.sortChests, stow with reasons, keep counts fresh.
---
# Storage

Use when the player asks to sort or tidy the chests, when `T.stow` leaves things aboard, before
a job that plans on what the chests hold, and after crafting or dropping by hand.

## Setting up
1. Ask which chests are the turtle's to use; leave the player's own alone.
2. Find them: `T.scanBox(box)`, then `T.catalogue(nil, { find = box })` adds the chests and
   barrels the map shows in the box and reads them. Or tell it one at a time:
   `T.addChest(x, y, z, side)` (x, y, z where the turtle stands; side "up", "down" or a
   heading 0 to 3). Adding the other half of a known double chest, or another stand for the
   same chest, keeps one record and says so in the note.
3. Agree the categories with the player, then give each chest what it is for (globs):
   `T.addChest(x, y, z, side, { holds = { "*_log", "*_planks", "stick" } })`. Typical sets:
   building blocks, wood, ores and metals, redstone and machines, food and farming, tools and
   loot, fuel, and one chest of the most used items. One bulk chest for the rest:
   `T.addChest(x, y, z, side, true)` or `{ bulk = true }`. `holds = false` makes a chest for
   anything again.
4. Sort: `T.sortChests{ limit = 32 }` until `info.more` is nil. Read `info.moved` and
   `info.left` (each with the chest it is in and why). Run `T.catalogue()` first if anyone
   changed the chests by hand.
5. Put the settings in a kept helper so every session has them, e.g. `keep("settings", ...)`
   setting `T.keep` (the current job's materials only), `T.cfg.tools` (the tools the turtle
   uses, such as `{ "*_pickaxe" }`; unset, every tool counts as essential and looted swords
   and axes never get stowed), `T.cfg.autoDump`, `T.diggable`.

## Day to day
- `T.stow()` puts away what isn't kept: a chest for the item first, else one that holds it,
  else the bulk chest. `T.stow{ all = true }` at a job's end. When something stays aboard,
  `info.reasons[name]` says why for each item ("chest at 3,0,1 full, bulk chest ... full");
  don't guess from the first.
- Full chests: tell the player, or place a new one (`T.placeAt(x, y, z, "minecraft:chest")`)
  and `T.addChest` it with a category.
- `T.where(name)` lists the chests with an item and the age of each count; `T.fetch(name, n)`
  goes and takes it; `T.prepare{ need = { ... }, freeSlots = k }` does a job's trip at once.
- Counts go stale: after your own `turtle.drop`/`suck` at a known chest, call
  `T.recount(side)` while still beside it. `T.craft` and `T.craftBatch` recount for you.
  Before a plan that depends on counts (`T.craftPlan`, a big build), `T.catalogue()`.
- What there is: `T.inventoryReport{ sort = "count" }`, `info.text` as lines;
  `{ match = "*_ingot" }` for a kind.

## Pitfalls from the field
- The catalogue said 8, the chest had 4: someone (or your own drops) changed it since.
  `T.fetch` re-reads as it goes and says when it comes up short; believe it.
- A chest for other things never takes an item, even when it has room: that is by design;
  give the item a category or a bulk chest.
- Modded inventories (an AE2 interface, a quantum link chamber) may refuse a turtle's drop with
  "no space": ask the player to insert it by hand.
- Your own helper copies of storage, fetching or crafting drift from the library: use T's.

## Tell the player
Which chest is for what (a sign on each helps: see build-for-player), what moved, what has
nowhere to go, and when chests are close to full.
