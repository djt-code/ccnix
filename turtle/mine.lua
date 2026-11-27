-- mine.lua -- tunnel-mining turtle for CC:Tweaked
--
-- Needs a pickaxe (any *_pickaxe upgrade), equipped or in the inventory.
-- Any other tool is parked in the inventory while it runs and put back
-- afterwards.  Optional: Advanced Peripherals Chunky Turtle upgrade so it
-- keeps running unattended.
--
-- Usage:  mine [<width> <height> [length]] [--spacing N] [--no-lights] [--here]
--              [--origin x,y,z[,facing]]
--         mine --resume          keep digging the tunnel it stopped in (from
--                                the start, or from the last home)
--         mine ... --new         start a fresh tunnel, forgetting the old one
--         mine haul              shuttle the valuables in the homes back to
--                                the start, as many trips as it takes
--         mine haul --supplies   ...and the supplies in the last home too
--         mine reset             back to the last home it built, after a
--                                Ctrl+T or restart (to the start, when the
--                                tunnel is finished)
--         mine reset --to-start  back to the start instead
--         mine reset --here      turtle was put back at the start by hand
--         mine where             where it is along the tunnel: at which home,
--                                or between which two; the tunnel's homes
--                                (it reads the saved job and position, so it
--                                works while mine runs, as a service say)
--
-- --origin gives the world cell of the start (what F3 shows for the block
-- the turtle stands in) and the compass way it faces, north, east, south or
-- west (left out, it is worked out from a Geo Scanner scan), for a run from
-- the start.  The map then knows where it is in the world (T.toWorld,
-- T.toLocal), for claude and the other programs.  GPS overrides it, with a
-- warning, where they disagree.
--
-- With a wireless modem on the turtle (or in its inventory: it's swapped
-- in for the check) and GPS hosts in range, its saved
-- position is checked against GPS when it starts and at `reset`: put
-- right if it's up to 16 blocks off, found if it was lost; farther off
-- (carried away, or another dimension) it stops and says where GPS
-- puts it.  The first check sets the world origin, if there's none
-- (`help turtlelib`; sysctl turtle.gps=false turns it off).
--
-- A tunnel saved before a re-zero that moved the start (another program
-- started away from home, T.clearPos) is in the old frame: --resume, haul
-- and reset refuse it, say why and mark it stale; a fresh tunnel replaces it.
--
-- width  = blocks to the RIGHT of the turtle (negative = to the LEFT)
-- height = blocks UP from the turtle (negative = DOWN)
-- length = blocks the tunnel runs ahead; leave it out to keep going until
--          the turtle can't (the start's chest full, bedrock)
--
-- With no size, it digs the one in the settings: 3x3, 32 long unless
-- changed (`sysctl mine.width=5`, `sysctl mine.length=0` for no end; also
-- mine.height, mine.spacing, mine.lights).  A size given here is saved
-- there, so the next `mine` (or the autostart) digs the same.
--
-- Asked for again from the same start (`mine 10 10 --new`, or the
-- settings' tunnel), a tunnel of the same width and height is carried on
-- from its last home, as `--resume` does, keeping its own spacing: the
-- part dug already is gone over, not dug again.  A finished tunnel is
-- carried on when the length asked for now is longer (or has no end).
--
-- It keeps going rather than stopping (each a setting):
--  * A home's chest that fills grows into a double chest: a second chest
--    put beside it joins it (only from chests to spare beyond the next
--    home's two).  When a haul empties a grown valuables chest, its second
--    chest is picked up again, so homes use as few chests as they can.
--  * A home's valuables chest full with nothing to grow it: the turtle
--    hauls every home's valuables to the start (as many trips as it
--    takes), goes straight back out and carries on (`sysctl
--    mine.haul=false` stops instead).  Only the start's chest being full
--    stops it.  `sysctl mine.haulEvery=N` hauls after every N homes too.
--  * A bulk chest full with nothing to grow it: what doesn't fit is
--    thrown on the floor behind the home (it despawns), and the run goes
--    on.
--  * Out of chests for the next home, or of fuel: it goes back to the
--    start (hauling on the way, and taking fuel from the homes it passes),
--    says what it needs (and tells the player, with mine.report), and
--    looks in the top chest every minute until it's there, then goes back
--    out and on (`sysctl mine.wait=false` stops instead).
--  * A finished tunnel brings its last home's supplies (chests, fuel,
--    torches, wood, the crafting table) back to the start, for the next
--    tunnel; one that stopped leaves them there for `--resume`.
--
-- A spawner in the way (a dungeon's) doesn't stop it either: it's left
-- standing (never dug), lit with a torch beside each of its sides that's
-- in the tunnel and one on top, and the tunnel goes round it.  So do a
-- chest, barrel or shulker box in the way.  Only a 1x1 tunnel, with no
-- way round, stops there.
--
-- Through open water (an ocean, a lake, an aquifer, a lava lake), where
-- nearly every block is wet, it works another way: from the home, a
-- chunk at a time, it puts a shell of bulk blocks round the tunnel first
-- (on the floor, walls and ceiling where water or lava may touch them:
-- a scan says, else what it has seen), then fills the water inside in
-- and digs it out dry, the blocks coming back.  Meanwhile, when more
-- than half of the tunnel ahead is water, a bulkhead across the tunnel
-- behind the home keeps the tunnel behind it dry, and a segment that
-- ends in water gets an end cap, which the next one starts from.  It
-- needs bulk blocks for that (cobblestone, from the homes behind, then
-- the start's bottom chest).  With a Geo Scanner, the scans say where
-- that is and how much of it is water.  Without one, it counts the water
-- it digs next to, by where it is across the tunnel (a source counts
-- far more than flowing water), so that a few stray sources don't count
-- for much; once there's enough of it close together, it digs the next
-- few blocks of the tunnel's top row and sides first (they're dug
-- anyway), to see how full of water the tunnel is there.  More than
-- half, and it goes on in open water; less, and it tunnels on as ever,
-- sealing the water as it meets it.
--
-- Water coming into the tunnel from outside it (falling through a hole
-- in the ceiling, or running in through a wall) is followed out, the way
-- it flows (up a falling column, then along to stronger water), to its
-- source, which is filled, so it stops for good.  It goes only through
-- the water (no digging), never into a protected area, and no more than
-- 16 blocks out, and comes back the way it went.  Where that doesn't
-- stop it (a body of water, more than one source) or can't be done,
-- water falling in through the ceiling is caught right over the hole in
-- a bowl of bulk blocks: four sides (and a rim on them, where it's open
-- round them), the hole filled as its bottom.  The water lands in it and
-- stays there (water never overflows: it only runs down).  Falling
-- columns side by side get one trough round them all.  Water it can't
-- trace that runs in through a wall, a source, and lava are sealed where
-- they come in, as before.
--
-- The turtle's own column and row are part of the tunnel: it stands in
-- the mouth at one bottom (or top, for negative heights) corner, and the
-- tunnel starts with the block in front of it.  `mine 3 3 32` digs a 3x3
-- tunnel 32 long, up and to the right of the turtle.
--
-- Placement: put the turtle where the tunnel's corner should start,
-- facing along it.  Put a chest directly ABOVE the start for valuables and
-- one directly BELOW it for bulk (stone, cobblestone, deepslate, dirt,
-- gravel, sand...).  Stock the top chest with fuel and with CHESTS: the
-- turtle builds a new home out of two of them every `spacing` blocks.
-- Torches in it too, and it lights the tunnel (unless --no-lights).  And a
-- crafting table, so it can craft more chests and torches from wood it
-- finds (see Crafting below).  And an empty bucket, so it burns the lava
-- it meets for fuel (see Lava below).
--
-- How it works:
--  * Homes: the tunnel is dug a segment at a time.  At the end of each
--    segment the turtle builds a home there: a chest set into the wall
--    beside its start column (valuables and supplies) and one under the
--    floor (bulk; over the ceiling for a downward tunnel).  Spacing is
--    chosen so a segment's bulk fits in its home's chest (at most 64), and
--    trips to unload or refuel only ever go back to the nearest home.
--  * Supplies move forward: building a home, the turtle carries the spare
--    chests, the fuel, the torches, all the wood it has mined (logs,
--    planks, sticks) and the crafting table from the old home to the new
--    one, as many trips as it takes.  Bulk stays in the home it was mined
--    near (bulk only ever goes in bulk chests): walking back, it leaves
--    the bulk it carries at each home it passes, keeping a stack of
--    filler for water on the way until home 1, so none reaches the start;
--    bulk found in a valuables chest goes down into the bulk chest.
--    Valuables stay in their home's chest until the end.  It checks
--    each chest it places is really there: in a mineshaft, a minecart
--    standing where a chest goes is broken and picked up first.
--  * Crafting: at the newest home, when it has fewer chests than two more
--    homes take, or fewer torches than two segments do, it crafts its wood
--    into as many chests as it can, keeping back planks for the torches
--    those homes' segments need, and crafts the torches from coal it can
--    spare.  It swaps the crafting table in for the pickaxe to craft, and
--    empties its inventory into the home's chests for it (a turtle crafts
--    from its inventory); then everything goes back.  No table: it says
--    so, and stops when it's out of chests.
--  * Seeking wood: with a crafting table (on board, equipped, or in its
--    working home), while the wood and chests at its working home and on
--    board would build fewer than WOOD_HOMES (8) more homes, it treats
--    logs and planks (mineshafts) like coal: one it touches is followed
--    to the end of its run, and with a Geo Scanner one a scan shows is
--    fetched from anywhere in the scan.  It notes what its working home
--    holds each time it's there.
--  * Stopping: the start's chest full, a home chest missing, or something
--    it can't dig through (and, with mine.wait or mine.haul off, out of
--    chests or fuel, or a home's valuables chest full).  Then (or once
--    the tunnel is as long as asked) it
--    walks back to the start, collecting the valuables from every home on
--    the way, the most valuable first when it can't carry them all, and
--    leaves them in the top chest at the start.  Supplies stay in the last
--    home, so `mine --resume` can carry on from there (bringing any new
--    chests and fuel from the start's top chest with it).  Resumed from an
--    earlier home (after `mine reset --home N`), it walks out the same
--    way.  On that walk out, in one go, it keeps the valuables it carries
--    on board, takes what's useful from each home it passes (fuel,
--    torches, chests, wood, the crafting table, as much as fits: the rest
--    stays there; and bulk blocks, for sealing water and filling holes),
--    and goes over each segment on the way, in one straight walk along
--    the middle of its floor (water getting in anywhere ends up on the
--    floor and spreads across it to there), filling any hole under it.
--    Only where it meets water does it stop to work: it follows the water
--    to where it gets in and seals that (water coming from the segment
--    after is left to that one, gone over next, rather than chased, or
--    the segment walked again for it), then goes over the stretch round
--    it along the floor by the lit wall, putting back any torch the water
--    washed off (one that's there, a wall torch as the game calls it once
--    hung, is left alone); where the floor there has a hole, or a patch
--    (cobblestone: a hole filled before, a bridge), it goes along the
--    other columns' floor there too and fills what's open.  Torches in
--    the dry part aren't looked at;
--    at each home it moves any bulk in the valuables chest down into the
--    bulk chest.  It stops to work only where water gets in (trips then
--    for bulk blocks or fuel go to the home ahead).
--  * Fuel: the tank always keeps enough to get back to the start; the
--    turtle refuels from each home's chest, and coal it mines lands there.
--    Going back to the start to haul or for supplies, it tops up from the
--    homes it passes (their fuel stock too) for the trip back out, and
--    only asks for fuel at the start when the tunnel has none left.  The
--    stock it took is put back on the way out, from the start's top chest.
--    It only burns coal, charcoal and the like, never wood or chests.
--  * Mineshafts: rails in the tunnel, its walls or floor are dug out (and
--    the wall or floor filled), and minecarts in its way broken; both are
--    valuables, brought back to the start.
--  * Lanes: each segment is mined in lanes running along it, every third
--    row (plus the top and bottom ones) of each column, digging the rows
--    in between up and down; without a Geo Scanner, one per row in the
--    two side columns, so it can turn to look at every wall block from
--    beside it.  The floor and ceiling it looks at from the bottom and top
--    lanes as it goes.
--  * Geo Scanner (Advanced Peripherals): put one in the start's top chest
--    and the turtle takes it along and uses it instead of looking at the
--    walls.  It digs a segment out first (fewer lanes, no turning to the
--    walls), then surveys it: it swaps the scanner in for its pickaxe (a
--    chunk controller on the other side stays put), scans (radius 8, no
--    fuel) from spots that cover the segment's walls, floor and ceiling
--    (the tunnel's middle when it's no more than 9 across and up; spots
--    round its sides, at its corners, when it's wider or taller, so they
--    see less of the dug-out air and more of the rock past the walls: a
--    10x10 scans from its four corners), and swaps back.  Then it seals the lava, water and
--    waterlogged or thin blocks the scans show in the walls, looks by hand
--    at any wall block no scan covered, and tunnels out to the ore they
--    found, up to SCAN_REACH (6) from the tunnel, and diamonds and coal
--    however far out as long as a scan saw them.  It goes no further than
--    the scan reached, except to follow a diamond or coal vein to its end.
--    If water got in while it dug, it walks the floor after, as on a
--    resume, for any still getting in.  Low on fuel, it scans as it digs
--    and fetches the coal first.  See the Geo Scanner section for how it
--    lines the scan's world directions up with the tunnel.  What a scan
--    sees also goes in the map (T.map, kept on the disk, so later runs,
--    `--resume` and the other programs know what has been seen); `sysctl
--    mine.map=false` leaves it out.  A scan whose directions mine had to
--    work out from the dug tunnel (an older scanner without right, up and
--    forward) is not kept.
--  * Veins: an ore it touches (anything tagged as an ore, *_ore blocks,
--    ancient debris) is mined along with its whole vein: the turtle
--    follows it block by block, looking all round each one, up to
--    VEIN_REACH blocks out from the tunnel, never back past the start.
--  * Lava and water touching the tunnel or a vein are sealed with a bulk
--    block, and so is anything that lets them through: waterlogged blocks
--    (glow lichen, dripstone... with water in them, which look like blocks
--    but are water sources), water plants, and thin things that aren't
--    solid (lichen, vines, grass) in the walls, floor or ceiling: those are
--    dug out first.  The bulk comes from the inventory (it keeps a stack
--    for this).  With an empty bucket on board (it takes one from the
--    start's top chest and keeps it), a lava source is taken up and
--    burned first, 1000 fuel each, when the tank has room for it: inside
--    the tunnel that's all it takes, and in a wall the hole it leaves is
--    filled as any other.  Flowing lava can't be taken up: it's sealed.
--    Turtles take
--    no harm from lava, but lava burns any item that falls in it and
--    makes the tunnel deadly for players.  Lava or water inside the
--    tunnel is dried out (see dry): filled and dug out, and if it comes
--    back, what feeds it is sealed first.
--  * Floor: the turtle doesn't need one, but a player does.  Every block
--    under the tunnel's bottom row that's a hole (a crevasse, a cave, where
--    floor ore was), a fluid, or something not to stand on (grass, snow,
--    cobwebs, dripstone) is filled with a bulk block; a crevasse across the
--    tunnel gets a bridge.  The turtle tops its stack of bulk up from each
--    home's bulk chest, and fetches more if it runs out mid-crevasse:
--    from the homes behind, when a cavern has left its own home's chest
--    without any.
--  * Lighting: with torches, it keeps every floor block of the tunnel at
--    block light 2 or more (mobs spawn at 0, since 1.18), using as few as
--    that takes: one in a niche dug into the wall at floor level every
--    19 blocks or so for a 3-wide tunnel (fewer the narrower), on both
--    walls when it's wider than 9 (wider than about 24, the middle of the
--    floor can't be kept at 2: it says so).  In the niche the torch is out of the
--    tunnel's way; a niche that opens into a cave gets a bulk block under
--    it to stand the torch on.  A scan's fetch or a vein can still go
--    through a niche, or dig the block a torch rests on: it notes that and
--    puts the torch back afterwards (after the fetch, and at the end of
--    the segment).  With water beside it (above, along or across the
--    tunnel), it leaves the torch out, since the water would flow in and
--    wash it away once the turtle moved on, and puts it in at the end of
--    the segment, or the next, once the water's seen to.  Torches are
--    supplies: they move forward with the homes, and it keeps up to 64 on
--    board.  Lighting is optional: with no torches it just keeps mining,
--    and --no-lights turns it off (torches are then just valuables).
--  * Never digs chests, barrels, shulker boxes, spawners or ComputerCraft
--    blocks (other turtles, computers).  A spawner, chest, barrel or
--    shulker box in the tunnel is left standing and the tunnel goes round
--    it (a dungeon's spawner and its chests, say).  A spawner gets a torch
--    beside each of its sides that opens into the tunnel and one on top, so
--    no mobs come from it; a torch that would wall the tunnel off is left
--    out, and a 1x1 tunnel, with no way round, stops there.  What it left
--    standing, and those torches, are kept (mine.blocked), so later trips
--    and runs go round them too.  A ComputerCraft block in the way still
--    stops it.  While it runs, the chests of the
--    start and of every home are also protected areas (T.protect, named
--    "mine home K chest" and "mine home K bulk"), so no other program on the
--    turtle digs them either; they are let go of when it ends, however it
--    ends (`sysctl mine.protect=false` protects nothing).
--  * Telling the player: with `sysctl mine.report=true`, mine tells the
--    player named in turtle.player (`sysctl turtle.player=<name>`), or
--    everyone in the chat when none is, through a chat box when it ends
--    or stops and why, with where the
--    turtle is and its fuel (T.report).  A chat box in the start's top chest
--    is taken out for the telling and put back; one on board is put on for
--    the moment, beside a chunk controller.
--  * Position is saved after every move, so `mine reset` can bring it to
--    its last home (`--home N`: home N; `--to-start`: the start) after a Ctrl+T or a server
--    restart, checking the home's chests are there when it arrives.  It runs under T.run, so a
--    Ctrl+T in the middle of a move or turn waits for it to be saved.
--    `mine reset` checks the heading against the tunnel first, and stops
--    if the way back digs through far more rock than it should.

-- What this file defines at the top level goes in a table of its own,
-- not in local variables: CC's Lua counts every local still in scope in
-- the enclosing functions against the 200 a function may have, and a
-- program this size runs out.  Names read as before; anything not
-- defined here comes from the shell's environment and _G.
local _ENV = setmetatable({}, { __index = _ENV })

package.path = (ccnix and ccnix.lib or "") .. package.path    -- (ccnix's turtlelib, the updates' first)
T = require("turtlelib")
scan = require("scan")
text = require("text")
fileio = require("fileio")
tables = require("tables")
convert = require("convert")

PROGRESS_FILE = T.dataPath("mine.seg")
GROWN_FILE = T.dataPath("mine.grown")
GROW_CHEST = "minecraft:chest"   -- (only a chest joins another into a double chest)
CHEST_SLOTS = 27
VEIN_REACH = 4       -- how far a vein is followed out from the tunnel
SCAN_RADIUS = 8      -- Geo Scanner radius (free of fuel up to 8)
SCAN_REACH = 6       -- with a scanner: how far out from the tunnel ore is fetched
ROOM = 2             -- empty slots wanted before each dig
FILLER_KEEP = 64     -- bulk blocks kept on board for sealing...
FILLER_KEEP_WET = 192 -- ...once it has run out drying out water
FUEL_KEEP = 32       -- fuel items carried, so it tops up on the way instead of going home
FUEL_STOCK = 8       -- fuel items left in each home when moving on: a stock along the tunnel
FUEL_WORK = 100      -- fuel for some work after a trip back out
MAX_SPACING = 64     -- most blocks between homes

--------------------------------------------------------------------------
-- Arguments
--------------------------------------------------------------------------
-- The compass ways --origin may name the start's facing (T.setOrigin takes these).
FACINGS = { north = true, east = true, south = true, west = true, n = true, e = true, s = true, w = true }

-- --origin x,y,z[,facing]: the world cell of the start and the way it faces.
-- { x, y, z, facing } (facing nil if left out), or nil and why.
function parseOrigin(arg)
    local parts = text.split(arg, ",")
    local x, y, z = convert.toInteger(parts[1] or ""), convert.toInteger(parts[2] or ""), convert.toInteger(parts[3] or "")
    if not (x and y and z and (#parts == 3 or #parts == 4)) then
        return nil, "--origin wants x,y,z or x,y,z,facing (the world cell of the start; whole numbers)"
    end
    local facing = parts[4] and parts[4]:lower()
    if facing and not FACINGS[facing] then
        return nil, "--origin's facing is north, east, south or west"
    end
    return { x = x, y = y, z = z, facing = facing }
end

-- (T.options: a negative size, -3, is a size, not an option)
opts, args = T.options({ ... }, { here = true, resume = true, new = true, ["no-lights"] = true,
    spacing = "=", home = "=", ["to-start"] = true, origin = "=", supplies = true })
if not opts then
    print("mine: " .. args)
    args, badOption = {}, true                  -- (the usage, below)
    opts = {}
end
if opts.origin then
    originArg, originWhy = parseOrigin(opts.origin)
    if not originArg then
        print("mine: " .. originWhy)
        badOption = true
    end
end
forceHere, resume, fresh, toStart = opts.here == true, opts.resume == true, opts.new == true, opts["to-start"] == true
lights = not opts["no-lights"]
    and T.setting("mine.lights", true, "Light mined tunnels with torches in wall niches")
reportEnd = T.setting("mine.report", false, "Tell the player (turtle.player, through a chat box) when mine ends or stops")
guardHomes = T.setting("mine.protect", true, "Protect mine's home chests (T.protect) while it runs, so no other program digs them")
keepMap = T.setting("mine.map", true, "Keep mine's Geo Scanner scans in the map (T.map), so later runs know what they saw")
haulWhenFull = false ~= T.setting("mine.haul", true, "A home's valuables chest full: haul them all to the start and carry on (false: stop)")
haulEvery = tonumber(T.setting("mine.haulEvery", 0, "Haul the valuables to the start after every N homes built (0: only when a chest is full)")) or 0
waitSupplies = false ~= T.setting("mine.wait", true, "Out of chests or fuel: wait at the start for more, looking every minute (false: stop)")
spacingArg, homeArg = opts.spacing and tonumber(opts.spacing), opts.home and tonumber(opts.home)
doReset = args[1] == "reset"
doHaul = args[1] == "haul"
doWhere = args[1] == "where"
WIDTH, HEIGHT, LENGTH = tonumber(args[1]), tonumber(args[2]), tonumber(args[3])
SET = {
    width = T.setting("mine.width", 3, "Tunnel width for mine: + right, - left"),
    height = T.setting("mine.height", 3, "Tunnel height for mine: + up, - down"),
    length = T.setting("mine.length", 32, "Tunnel length for mine; 0 = until it can't go on"),
    spacing = T.setting("mine.spacing", 0, "Blocks between mine's homes; 0 = chosen from the size"),
}
if not (doReset or doHaul or doWhere) and args[1] == nil then
    -- no size given: the settings' tunnel
    WIDTH, HEIGHT = SET.width, SET.height
    LENGTH = SET.length ~= 0 and SET.length or nil
    if not spacingArg and SET.spacing ~= 0 then spacingArg = SET.spacing end
elseif not (doReset or doHaul or doWhere or resume) and WIDTH and HEIGHT then
    local keep = { ["mine.width"] = WIDTH, ["mine.height"] = HEIGHT, ["mine.length"] = LENGTH or 0 }
    if spacingArg then keep["mine.spacing"] = spacingArg end
    savedSize = keep                   -- saved once the size is checked
end

function usage()
    print("Usage: mine [<width> <height> [length]] [--spacing N] [--no-lights] [--here] [--origin x,y,z[,facing]]")
    print("       mine --resume | mine haul [--supplies] | mine where | mine reset [--home N | --to-start | --here]")
    print("width: + right / - left; height: + up / - down;")
    print("no length: dig until out of chests, fuel or room")
end
if badOption or not (doReset or resume or doHaul or doWhere) and (not (WIDTH and HEIGHT) or WIDTH == 0 or HEIGHT == 0
        or (args[3] and not (LENGTH and LENGTH >= 1))) then
    usage()
    return
end
if savedSize then T.saveSettings(savedSize) end

--------------------------------------------------------------------------
-- Blocks and items
--------------------------------------------------------------------------
LAVA, WATER = "minecraft:lava", "minecraft:water"
FLUID = { [LAVA] = true, [WATER] = true }
ORE_EXTRA = { ["minecraft:ancient_debris"] = true }

function isOre(data)
    if text.endsWith(data.name, "_ore") or ORE_EXTRA[data.name] then return true end
    for tag in pairs(data.tags or {}) do
        if tag == "c:ores" or tag == "forge:ores" or text.endsWith(tag, "_ores") then return true end
    end
    return false
end

-- Blocks never to dig: storage, spawners and ComputerCraft blocks.
function protected(name) return T.neverDig(name) end

-- Bulk items go in a home's bulk chest; everything else is a valuable.
BULK = {}
for _, n in ipairs({ "cobblestone", "cobbled_deepslate", "stone", "deepslate", "dirt",
        "coarse_dirt", "rooted_dirt", "gravel", "sand", "red_sand", "sandstone",
        "red_sandstone", "andesite", "diorite", "granite", "tuff", "calcite",
        "dripstone_block", "pointed_dripstone", "netherrack", "blackstone", "basalt",
        "smooth_basalt", "soul_sand", "soul_soil", "end_stone", "flint", "mud",
        "clay", "clay_ball", "moss_block", "terracotta", "magma_block" }) do      -- (clay dug gives clay balls)
    BULK["minecraft:" .. n] = true
end
BULK_TAGS = {
    ["c:stones"] = true, ["forge:stone"] = true, ["c:cobblestones"] = true,
    ["forge:cobblestone"] = true, ["minecraft:stone_tool_materials"] = true,
    ["minecraft:stone_crafting_materials"] = true, ["minecraft:dirt"] = true,
    ["c:gravels"] = true, ["forge:gravel"] = true, ["c:sands"] = true,
    ["forge:sand"] = true, ["minecraft:sand"] = true,
}
function isBulk(it)
    if BULK[it.name] then return true end
    for tag in pairs(it.tags or {}) do
        if BULK_TAGS[tag] then return true end
    end
    return false
end

-- Bulk blocks that can seal lava and water (solid, and they don't fall).
-- What a hole in the floor is filled with that doesn't come out of the
-- ground as it is: a floor block of one of these is a hole filled before.
PATCH = { ["minecraft:cobblestone"] = true, ["minecraft:cobbled_deepslate"] = true }
FILLER = {}
for _, n in ipairs({ "cobblestone", "cobbled_deepslate", "netherrack", "dirt", "andesite",
        "diorite", "granite", "tuff", "calcite", "blackstone", "basalt", "end_stone",
        "stone", "deepslate", "dripstone_block", "smooth_basalt", "sandstone",
        "red_sandstone", "terracotta", "clay", "moss_block", "coarse_dirt", "rooted_dirt" }) do
    FILLER["minecraft:" .. n] = true
end

-- Blocks a player can't stand on (or shouldn't): a floor of these is
-- dug out and filled like a hole.
SOFT = {}
for _, n in ipairs({ "short_grass", "grass", "tall_grass", "fern", "large_fern", "dead_bush",
        "vine", "glow_lichen", "snow", "moss_carpet", "sculk_vein", "cobweb",
        "pointed_dripstone", "hanging_roots", "cave_vines", "cave_vines_plant",
        "spore_blossom", "small_dripleaf", "big_dripleaf", "big_dripleaf_stem", "sea_pickle",
        "seagrass", "tall_seagrass", "kelp", "kelp_plant",
        -- a mineshaft's rails in the walls or floor: taken (they're
        -- valuables) and the block filled
        "rail", "powered_rail", "detector_rail", "activator_rail" }) do
    SOFT["minecraft:" .. n] = true
end
-- Water plants: water blocks with something growing in them.
WATER_PLANTS = {}
for _, n in ipairs({ "seagrass", "tall_seagrass", "kelp", "kelp_plant", "bubble_column" }) do
    WATER_PLANTS["minecraft:" .. n] = true
end

-- Thin or soft things (glow lichen, vines, grass, dripstone...): not solid,
-- so in the tunnel's walls, floor or ceiling they're replaced with bulk.
function soft(data)
    return SOFT[data.name] or (data.tags and data.tags["minecraft:replaceable"]) or false
end

-- Holding water without being water: a waterlogged block (glow lichen,
-- dripstone, roots... with water in it: as good as a water source, but it
-- doesn't look like one) or a water plant.
function waterIn(data)
    return WATER_PLANTS[data.name] or (data.state and data.state.waterlogged == true) or false
end

-- Supplies: what homes are built from, fuel and torches, and the wood and
-- crafting table more chests and torches are crafted with (see Crafting;
-- wood is never burnt).  They travel forward to the newest home.
CHEST_ITEMS = { ["minecraft:chest"] = true, ["minecraft:barrel"] = true }
TORCHES = { ["minecraft:torch"] = true, ["minecraft:soul_torch"] = true }
-- A torch as a block: hung on a wall (as in its niche) the game calls it a
-- wall torch.  One there already is left alone.
TORCH_BLOCKS = { ["minecraft:torch"] = true, ["minecraft:wall_torch"] = true,
                 ["minecraft:soul_torch"] = true, ["minecraft:soul_wall_torch"] = true }
CRAFTING_TABLE, STICK = "minecraft:crafting_table", "minecraft:stick"
COAL = { ["minecraft:coal"] = true, ["minecraft:charcoal"] = true }   -- what torches are lit with
function isLog(name)
    return text.endsWith(name, "_log") or text.endsWith(name, "_wood") or text.endsWith(name, "_stem")
        or text.endsWith(name, "_hyphae")
end
function isPlanks(name) return text.endsWith(name, "_planks") end
function isWood(name) return isLog(name) or isPlanks(name) or name == STICK end
-- The Advanced Peripherals Geo Scanner: kept on board, never unloaded.
function isScanner(name) return text.contains(name, "geo_scanner") end
-- A turtle upgrade or computer part (a wireless modem, a chunk controller, a chat box): the turtle's own, which an
-- unload keeps aboard (T.isEssential's peripherals).  Not the geo scanner: that is the start chest's kit, and goes back.
function isUpgrade(name)
    return not isScanner(name) and (text.startsWith(name, "computercraft:") or text.startsWith(name, "advancedperipherals:"))
end
-- A bucket: kept on board (one), for taking up lava to burn (see scoop).
BUCKET, LAVA_BUCKET = "minecraft:bucket", "minecraft:lava_bucket"
function isSupply(name)
    return CHEST_ITEMS[name] or T.fuel[name] or (lights and TORCHES[name]) or isWood(name)
        or name == CRAFTING_TABLE
end

-- What's worth carrying back first when the turtle can't carry it all.
-- Anything not listed: 40 if it looks like an ore's drop, else 10.
VALUE = {
    ["minecraft:netherite_scrap"] = 100, ["minecraft:ancient_debris"] = 100,
    ["minecraft:diamond"] = 90, ["minecraft:emerald"] = 80, ["minecraft:raw_gold"] = 60,
    ["minecraft:gold_nugget"] = 30, ["minecraft:amethyst_shard"] = 35,
    ["minecraft:lapis_lazuli"] = 45, ["minecraft:raw_iron"] = 50, ["minecraft:raw_copper"] = 25,
    ["minecraft:redstone"] = 30, ["minecraft:quartz"] = 30,
    -- from mineshafts: rails dug out of the tunnel and its walls, and
    -- minecarts it breaks that are in its way
    ["minecraft:rail"] = 20, ["minecraft:powered_rail"] = 30, ["minecraft:detector_rail"] = 20,
    ["minecraft:activator_rail"] = 20, ["minecraft:minecart"] = 25, ["minecraft:chest_minecart"] = 25,
}
function value(name)
    if VALUE[name] then return VALUE[name] end
    if text.contains(name, "raw_") or text.contains(name, "ore") or text.contains(name, "gem") then return 40 end
    return 10
end

T.cfg.maxHeight, T.cfg.maxDrop = 1000, 1000    -- the tunnel sets the limits
T.diggable = { [LAVA] = true, [WATER] = true }  -- move into fluids (digging them does nothing)

--------------------------------------------------------------------------
-- Tunnel geometry: x in X0..X1, y in Y0..Y1, z in 1..LENGTH; homes every
-- SPACING blocks along it.
--------------------------------------------------------------------------
X0, X1, Y0, Y1, SPACING, WALL = nil
segEnd = 0           -- last block of the segment being mined

-- Lighting.  Since 1.18 mobs spawn only at block light 0; a torch is 14
-- and light drops by 1 a block, so a floor block within 13 of a torch is
-- safe.  Torches go in niches dug into the wall at floor level (out of
-- the tunnel's way; relight puts back any that digging reaches anyway),
-- every torchEvery blocks, and on both walls when the tunnel is too wide
-- to light from one.  LIGHT_REACH leaves a margin: every floor block gets
-- light 2.
LIGHT_REACH = 12
TORCH_KEEP = lights and 64 or 0    -- torches carried (--no-lights: none)
torchEvery, torchWalls, torchAlong = nil

function setBox()
    X0, X1 = math.min(0, WIDTH - T.sgn(WIDTH)), math.max(0, WIDTH - T.sgn(WIDTH))
    Y0, Y1 = math.min(0, HEIGHT - T.sgn(HEIGHT)), math.max(0, HEIGHT - T.sgn(HEIGHT))
    LENGTH = LENGTH or math.huge
    -- a segment's bulk fits in one chest, with room to spare
    SPACING = SPACING or spacingArg
        or math.max(8, math.min(MAX_SPACING, math.floor(27 * 64 * 0.75 / math.abs(WIDTH * HEIGHT))))
    WALL = WIDTH > 0 and 3 or 1             -- the wall beside the start column
    -- how far along z a torch may be from the darkest floor block: one
    -- wall reaches across the width; two walls meet in the middle
    local w = math.abs(WIDTH)
    local along = LIGHT_REACH - w           -- 1 into the niche, w - 1 across
    torchWalls = 1
    if along < 3 then
        torchWalls = 2
        along = math.max(0, LIGHT_REACH - 1 - math.floor((w - 1) / 2))
    end
    torchEvery, torchAlong = 2 * along + 1, along
    -- wider than two walls' torches reach: the middle of the floor stays
    -- dimmer than it aims for (light 2), however close the torches
    tooWide = torchWalls == 2 and LIGHT_REACH - 1 - math.floor((w - 1) / 2) < 0
end

-- Is z where a torch goes?  Every torchEvery blocks, the first lighting
-- the tunnel's mouth; one that would land on a home's wall chest moves
-- one block on.  The last block of a tunnel that ends too far past the
-- last of those (or before the first) gets one too.
function torchAt(z)
    local first = torchAlong + 1
    local function due(n) return n >= 1 and (n - first) % torchEvery == 0 end
    if due(z) and (z % SPACING ~= 0 or z == LENGTH) then return true end   -- (no home at the very end)
    if due(z - 1) and (z - 1) % SPACING == 0 then return true end
    if z == LENGTH then
        local last = z >= first and z - (z - first) % torchEvery or nil
        return not last or z - last > torchAlong
    end
    return false
end

function inBox(p)
    return p.x >= X0 and p.x <= X1 and p.y >= Y0 and p.y <= Y1 and p.z >= 1 and p.z <= LENGTH
end

-- How far a block is outside the tunnel dug so far (0: in it).
function outside(p)
    local dx = math.max(X0 - p.x, 0, p.x - X1)
    local dy = math.max(Y0 - p.y, 0, p.y - Y1)
    local dz = math.max(0, p.z - math.min(LENGTH, segEnd))
    return math.max(dx, dy, dz)
end

hasScanner = false   -- a Geo Scanner on board: ore is fetched from further out

-- Within reach of the tunnel dug so far (VEIN_REACH; SCAN_REACH with a
-- scanner), and not back past its start.
-- While ore a scan found is being fetched: the spot in the tunnel the
-- scan was taken from.  The turtle goes no further from it than the
-- scan reached (SCAN_RADIUS, along each axis).
bound = nil

function inScan(p)
    return not bound or math.max(math.abs(p.x - bound.x), math.abs(p.y - bound.y),
        math.abs(p.z - bound.z)) <= SCAN_RADIUS
end

function inReach(p)
    return p.z >= 1 and outside(p) <= (hasScanner and SCAN_REACH or VEIN_REACH) and inScan(p)
end

-- Wood (logs, and planks: mineshafts are built of them) is sought like
-- ore while the turtle can craft (a crafting table on board, equipped, or
-- in its working home) and the wood and chests it has, there and on
-- board, would build fewer than WOOD_HOMES more homes (and their torches'
-- sticks).  woodNeed is how many planks' worth it still wants; homeStock
-- what its working home's valuables chest held when it was last there.
WOOD_HOMES = 8
woodNeed, homeStock, canCraft = 0, {}, false
function isWoodBlock(name) return isLog(name) or isPlanks(name) end

-- What's followed like a vein and fetched when a scan shows it: ore, and
-- wood while it's wanted.
function isTarget(data) return isOre(data) or (woodNeed > 0 and isWoodBlock(data.name)) end

-- Work out woodNeed again: from the home's chest too when `atHome` (it's
-- at its working home), else from what it carries and homeStock.
function updateWoodNeed(atHome)
    if atHome then
        homeStock = chestCounts(home.val)
        canCraft = (homeStock[CRAFTING_TABLE] or 0) > 0 or T.equipped("left") == CRAFTING_TABLE
            or T.equipped("right") == CRAFTING_TABLE
    end
    local planks, chests, onBoard = 0, 0, false
    local function add(name, n)
        if isLog(name) then planks = planks + 4 * n
        elseif isPlanks(name) then planks = planks + n
        elseif name == STICK then planks = planks + n / 2
        elseif CHEST_ITEMS[name] then chests = chests + n
        elseif name == CRAFTING_TABLE then onBoard = true end
    end
    for name, n in pairs(homeStock) do add(name, n) end
    for sl = 1, 16 do
        local it = turtle.getItemDetail(sl)
        if it then add(it.name, it.count) end
    end
    woodNeed = (canCraft or onBoard) and math.max(0, WOOD_HOMES * 18 - 8 * chests - planks) or 0
end

-- Diamonds and coal a scan shows are mined however far out, as long as
-- they're in the scan, and their veins followed to the end: diamonds for
-- their worth, coal because the turtle runs on it, and wood while it's
-- wanted, for chests and torches.
function goesFar(name)
    return text.contains(name, "diamond") or text.contains(name, "coal") or (woodNeed > 0 and isWoodBlock(name))
end

--------------------------------------------------------------------------
-- Homes.  Home 0 is the start: valuables chest above, bulk below.  Home
-- k sits at z = k * SPACING in the start column, top row 0: valuables and
-- supplies in a chest in the wall, bulk in one under the floor (over the
-- ceiling, for a tunnel going down).
--------------------------------------------------------------------------
function homeAt(k)
    if k == 0 then return { k = 0, x = 0, y = 0, z = 0, face = 0, val = "top", bulk = "bottom" } end
    return { k = k, x = 0, y = 0, z = k * SPACING, face = WALL, val = "front",
             bulk = HEIGHT > 0 and "bottom" or "top" }
end
home = nil          -- the home the turtle works from
lastHome = 0         -- the furthest home built (the supplies are there)
-- A home's chests grown into double chests (see grow): grown[k] = { val = z, bulk = z }, the z of
-- the second chest; false: it was tried and didn't join (not again this run).
grown = {}

-- The job, saved so `mine --resume` and `mine reset` know the tunnel
-- (and autostart, whether to resume it): T.saveMineJob's file.
function saveJob(state)
    T.saveMineJob({ width = WIDTH, height = HEIGHT, length = LENGTH ~= math.huge and LENGTH or nil,
                    spacing = SPACING, homes = lastHome, state = state })
end

-- How far the segment being dug has got, so `mine --resume` carries on
-- from there instead of going over it all again: the home it's dug from,
-- the lane it's on, and the last block of that lane it finished.
function saveProgress(lane, z)
    fileio.write(PROGRESS_FILE, string.format("%d %d %d %d", home.k, lane, z, laneCount))
end

function loadProgress()
    local saved = fileio.read(PROGRESS_FILE)
    if not saved then return nil end
    -- "home lane z lanes", as saveProgress writes it (files from before
    -- the lane count have the first three)
    local w = text.words(saved)
    if not (scan.isUnsigned(w[1]) and scan.isUnsigned(w[2]) and scan.isInteger(w[3])) then return nil end
    return { k = tonumber(w[1]), lane = tonumber(w[2]), z = tonumber(w[3]),
             lanes = scan.isUnsigned(w[4]) and tonumber(w[4]) or nil }
end

function clearProgress()
    if fs.exists(PROGRESS_FILE) then fs.delete(PROGRESS_FILE) end
end

-- The homes' grown chests, a line each ("k val z", "k bulk z"), so `--resume`, `reset` and `haul` know them.
function saveGrown()
    local lines = {}
    for _, k in ipairs(tables.sortedKeys(grown)) do
        for _, kind in ipairs({ "val", "bulk" }) do
            local z = grown[k][kind]
            if type(z) == "number" then lines[#lines + 1] = string.format("%d %s %d", k, kind, z) end
        end
    end
    if #lines == 0 then clearGrown() else fileio.write(GROWN_FILE, table.concat(lines, "\n") .. "\n") end
end

function loadGrown()
    local out, saved = {}, fileio.read(GROWN_FILE)
    for _, line in ipairs(saved and text.lines(saved) or {}) do
        local w = text.words(line)
        if scan.isUnsigned(w[1] or "") and (w[2] == "val" or w[2] == "bulk") and scan.isInteger(w[3] or "") then
            local k = tonumber(w[1])
            out[k] = out[k] or {}
            out[k][w[2]] = tonumber(w[3])
        end
    end
    return out
end

function clearGrown()
    if fs.exists(GROWN_FILE) then fs.delete(GROWN_FILE) end
end

loadJob = T.loadMineJob

--------------------------------------------------------------------------
-- Directions: turtlelib's six (0..3 as T.dir, 0 = +z ahead, 1 = +x
-- right, plus "up" and "down"), and its sides for chests ("front",
-- "top", "bottom").
--------------------------------------------------------------------------
DELTA, OPP = T.DELTA, T.OPP
neighbour, key, here, dist = T.neighbour, T.posKey, T.here, T.dist
look, placeDir, moveDir, attackDir, suckDir = T.look, T.placeDir, T.moveDir, T.attackDir, T.suckDir

-- The torches it has placed, by the block each is in and the blocks it
-- may rest on (the one behind it and the one under it); digging any of
-- those can knock it off (a scanner fetch or a vein going through a
-- niche), and `broken` keeps those to put back (see relight).
torchBy, broken = {}, {}
function digDir(d)
    local n = key(neighbour(d))
    if blocked[n] then return false end    -- (left standing: see there)
    local ok = T.digDir(d)
    if ok and torchBy[n] then broken[torchBy[n]] = true end
    return ok
end
turnsTo, eachAround, dirTo, stepToward = T.turnsTo, T.eachAround, T.dirTo, T.stepToward
dropSide, containerOn = T.dropSide, T.containerOn

--------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------
opened = {}          -- key(p) = true: known to be air (dug or visited)
trail = {}           -- directions moved out of the tunnel into a vein
inTrip = false
fuelGoal = 0
filled = {}          -- blocks it has put back where it dug (floors, seals, chests, torches)
fillerDry = false    -- no filler on board, at its home or behind: don't go looking again till it unloads
fillerKeep = FILLER_KEEP  -- FILLER_KEEP_WET once water has used it up
stats = { veins = 0, ore = 0, sealed = 0, filled = 0, torches = 0, relit = 0, homes = 0, fetched = 0, wet = 0,
          wood = 0, lava = 0, grown = 0, pickedUp = 0, thrown = 0, hauls = 0, waits = 0,
          standing = 0, spawners = 0, spawnerTorches = 0, shell = 0, fill = 0, cap = 0, bulkhead = 0,
          traced = 0, bowls = 0, bowlBlocks = 0 }
-- From the Geo Scanner (see there): the world direction of the tunnel's +z
-- once lined up, this segment's blocks touching the tunnel ("rock",
-- "ore", "fluid" or "air"), and its ore further out.
facing = nil
known, targets = {}, {}
-- And, for following veins without turning to look: where this
-- segment's scans were taken, and the ore and fluid they saw.
scanFrom, scanned = {}, {}
-- What this segment's scans say is at p: "ore" or "fluid", "clear" (a
-- scan covered it and saw neither), or nil (none covered it).
function scanSays(p)
    local k = scanned[key(p)]
    if k then return k end
    for _, o in ipairs(scanFrom) do
        if math.max(math.abs(p.x - o.x), math.abs(p.y - o.y), math.abs(p.z - o.z)) <= SCAN_RADIUS then
            return "clear"
        end
    end
end
pickaxe = nil              -- the pickaxe mined with (found at the start)

-- Stop the job: unwinds to the top, which walks back to the start.
function stop(reason) error({ stop = reason }, 0) end

-- Fuel to get to the current home (back down the vein, then along the
-- tunnel) and from there back to the start: the tank never holds less.
function T.homeCost()
    return math.abs(T.pos.x - home.x) + math.abs(T.pos.y - home.y) + math.abs(T.pos.z - home.z)
        + 2 * #trail + 2 + home.z
end

--------------------------------------------------------------------------
-- Moving and digging
--------------------------------------------------------------------------

-- Make room before a dig: when a slot has filled or emptied since the
-- last look (a new stack started, maybe one that could have joined
-- another, or a gap opened ahead of a part stack), tidy the inventory;
-- then a trip home if fewer than ROOM slots are free.
freeBefore = 0
function room()
    local free = T.freeSlots()
    if free ~= freeBefore or free < ROOM then
        T.tidyInventory()
        free = T.freeSlots()
    end
    freeBefore = free
    if not inTrip and free < ROOM then trip("Inventory nearly full") end
end

function isSource(data)
    return (FLUID[data.name] and data.state and tonumber(data.state.level) == 0) or waterIn(data)
end

-- Fluid, or anything that lets it through: what the tunnel's walls, floor
-- and ceiling mustn't have in them.
function leaky(data)
    return FLUID[data.name] or waterIn(data) or soft(data)
end


digLimit = nil             -- `mine reset`: blocks it may dig on the way back (nil: any)
repairing = false    -- going over tunnel dug before: any water in it is getting in from somewhere
sealedZ = {}         -- (going over it) z of each place it sealed water getting in
wetAt, wetLevel = nil      -- the block it last moved into through water or lava, and its level
plugs = {}           -- key -> position: dug tunnel blocks it filled again (see dry)

-- Step one block in direction d, digging what's there (falling gravel
-- and sand included).  In the tunnel, lava or water there (or let in by
-- the dig) is dried out first (see dry), so none is left behind.  False
-- if it can't: a protected or unbreakable block, or something that won't
-- move out of the way.
function go(d)
    local n = neighbour(d)
    if blocked[key(n)] then return false, blocked[key(n)].name end
    local inside = inBox(n) and not digLimit
    local wet = false
    for _ = 1, 30 do
        room()                     -- first: a trip changes what's there
        -- through tunnel dug before (going over it, or on a trip), flowing
        -- water ahead is getting in somewhere: wade in (the turtle pushes
        -- it out of the block) rather than step in and out again to dry
        -- it, and follow it from there.  Where it's digging through wet
        -- ground, it dries each block (sources next to it are filled as
        -- it goes).
        local wade = repairing or inTrip or surveying
        local ok, data = look(d)
        if ok and inside and (isSource(data) or (FLUID[data.name] and not wade)) then
            dry(d)
            ok, data = look(d)
        end
        if ok and inside and wade and FLUID[data.name] and not wet then
            wet = data
            stats.wet = stats.wet + 1
        end
        if ok and not FLUID[data.name] then
            if protected(data.name) then
                standing(n, data.name)
                return false, data.name
            end
            if digLimit then
                if digLimit <= 0 then error({ lost = true }, 0) end
                digLimit = digLimit - 1
            end
            if not digDir(d) then return false, data.name end
            local okw, w = look(d)         -- the dig let water in
            if inside and okw and FLUID[w.name] then
                if isSource(w) then dry(d) else wet = w; stats.wet = stats.wet + 1 end
            end
        end
        local into = wet or (ok and FLUID[data.name] and data)
        if moveDir(d) then
            -- through the bulkhead (see openWater): closed again behind it
            if bulkheadZ and n.z ~= bulkheadZ and n.z - DELTA[d][3] == bulkheadZ and d ~= "up" and d ~= "down"
                    and inBox({ x = n.x, y = n.y, z = bulkheadZ }) then
                putFiller(OPP[d])
            end
            wetAt, wetLevel = nil, nil
            if into then
                wetAt = key(T.pos)
                wetLevel = type(into) == "table" and tonumber(into.state and into.state.level) or 1
            end
            opened[key(T.pos)] = true
            plugs[key(T.pos)] = nil
            -- in it, the turtle keeps fluid out of the block: seal what
            -- let it in before it spreads, from here, or follow it to
            -- where it comes in
            -- (through tunnel dug before, only where that's outside the
            -- tunnel: above, below, and a wall beside it, no turning to
            -- look into the tunnel; where it's digging, all round, for the
            -- sources next to it too)
            if wet then
                local cut = 0
                eachAround(OPP[d], function(e)
                    if (not wade or e == "up" or e == "down" or not inBox(neighbour(e))) and cutOff(e) then
                        cut = cut + 1
                    end
                end)
                local level = tonumber(wet.state and wet.state.level) or 0
                if cut == 0 and level > 0 then stem(level) end
            end
            return true
        end
    end
    return false, "something in the way"
end

-- Step back the way it came in direction d: backwards, facing d (no
-- turning round), unless facing the other way is fewer turns.
function retreat(d)
    if d ~= "up" and d ~= "down" and turnsTo(d) <= turnsTo(OPP[d]) then
        T.face(d)
        if T.back() then return true end
    end
    return go(OPP[d])
end

-- Put a bulk block in direction d (into air or a fluid; with nothing to
-- place it against, a turtle places it against itself).
function putFiller(d)
    if not T.selectItem(function(n) return FILLER[n] end) then return false end
    local ok = placeDir(d)
    turtle.select(1)
    if ok then filledIn(d) end
    return ok
end

-- A block put in direction d: where it was dug isn't open any more (a
-- scan that shows a block there isn't turned, see takeScan).
function filledIn(d)
    local p = neighbour(d)
    opened[key(p)] = nil
    filled[key(p)] = true
end

-- With an empty bucket on board and room in the tank, a lava source in
-- direction d is taken up and burned (1000 fuel): the lava's gone, and
-- the tank fuller.  True if it was.
function scoop(d)
    local ok, data = look(d)
    if not (ok and data.name == LAVA and isSource(data)) then return false end
    local level, limit = turtle.getFuelLevel(), turtle.getFuelLimit()
    if type(level) ~= "number" or type(limit) ~= "number" or limit - level < 1000 then return false end
    if not T.selectItem(BUCKET) then return false end
    placeDir(d)                            -- (an empty bucket takes up the source)
    local it = turtle.getItemDetail()
    local burned = it and it.name == LAVA_BUCKET and turtle.refuel(1)
    turtle.select(1)
    if burned then
        stats.lava = stats.lava + 1
        print(string.format("Burned a lava source at (%s) for fuel (fuel %s).", key(neighbour(d)),
            tostring(turtle.getFuelLevel())))
    end
    return burned
end

-- Seal lava or water in direction d with a bulk block.  Lava a bucket
-- takes up (see scoop) is gone: inside the tunnel that's the end of it;
-- in a wall, floor or ceiling the hole it leaves is filled as before.
-- Out of bulk blocks, it goes for more first (as drying and filling do).
-- Flowing water coming in from outside the tunnel is followed to its
-- source first, or caught in a bowl (see traceIn).
function seal(d)
    if traceIn(d) then return true end
    if scoop(d) and inBox(neighbour(d)) then return true end
    if not fillerDry and not T.selectItem(function(n) return FILLER[n] end) then
        fillerKeep = FILLER_KEEP_WET       -- wet ground: carry more from now on
        trip("Out of blocks to seal water with")
    end
    local okb, b = look(d)
    if okb and not FLUID[b.name] and (soft(b) or waterIn(b)) and not protected(b.name) then digDir(d) end
    local ok = putFiller(d)
    if ok then
        stats.sealed = stats.sealed + 1
        opened[key(neighbour(d))] = nil
        if repairing then sealedZ[#sealedZ + 1] = neighbour(d).z end
    end
    return ok
end

-- After stepping back out of a block in direction d: if water or lava
-- has got into it, seal it, so the way out isn't a channel into the
-- tunnel (only if it can look without turning).
function sealBehind(d)
    if d ~= "up" and d ~= "down" and T.dir ~= d then return end
    local ok, data = look(d)
    if ok and FLUID[data.name] then seal(d) end
end

-- Seal the fluid in direction e if it feeds the tunnel: any outside it,
-- a source inside it (a filling, dug out again later).  True if sealed.
function cutOff(e)
    local m = neighbour(e)
    local ok, data = look(e)
    if not (ok and leaky(data) and (isSource(data) or not inBox(m))) then return false, ok and data end
    local was = opened[key(m)]
    if isSource(data) then noteSource(m) end
    if not seal(e) then return false end
    if inBox(m) and (was or repairing) then plugs[key(m)] = m end
    return true
end

-- Water and lava in the tunnel.  A source can't just be dug out: water
-- flows back into an open block from any water beside or above it, a
-- block with two sources beside it becomes a source itself, and a turtle
-- that moves into a source leaves it behind when it moves on.  So the
-- turtle fills a source with a bulk block and digs it out.  If a fluid
-- comes back, something next to that block feeds it (water from above,
-- an aquifer): it steps in, seals the lava and water touching it outside
-- the tunnel (flowing water there is followed to its source first, see
-- traceIn), and fills the sources touching it inside, steps back, and
-- tries again.  Those fillings in the tunnel are dug out again in their
-- turn (ahead, by the lanes; behind, at the end of the segment), by when
-- what fed them is sealed.  Flowing water nothing feeds drains away.
-- How strong flowing water or lava is: 0 for a source or falling (level 8
-- and up), else its level (1 next to a source, weaker further on).
function strength(data)
    local level = tonumber(data.state and data.state.level) or 0
    return level >= 8 and 0 or level
end

-- The turtle is in flowing water (or lava) of the given level that nothing
-- beside it feeds: it comes from further off, along the tunnel.  Follow it
-- upstream through the tunnel (up, if it's falling; else to stronger
-- water beside it), as far as water spreads and falls, to where it comes
-- in from outside, and come back.  There, flowing water is followed on
-- out of the tunnel to its source, which is filled (see traceIn); where
-- it's still coming after that, or the source is out of reach, water
-- falling in through the ceiling is caught in a bowl over the hole (see
-- bowl), and anything else (a source, lava, water from a wall) is
-- sealed where it comes in.  A source in the tunnel is left for drying
-- out when it's reached.  True if it sealed something.
-- Going over part of the tunnel (repair), it follows water no further
-- than that part's far end: water from the next part (dug) is that
-- part's to see to, when it's gone over in turn (fromOutside notes it
-- was met); water from past the end of what's dug is sealed for good,
-- there.  (Behind it, gone over already, is followed as ever.)
unfed = {}           -- key: true, flowing water found here with nothing beside it feeding it; "traced"
repairRange = nil    -- while going over z1..z2: { z1, z2, aheadDug }
fromOutside = false  -- water met there came from past its ends
function stopFlow(level)
    local path, sealed = {}, false
    unfed[key(T.pos)] = "traced"
    if not T.hasFuel(T.homeCost() + T.cfg.fuelMargin + 40) then return false end
    for _ = 1, 24 do
        local up, upLevel, source = nil, nil, false
        -- look the fewest turns away first (up, down, ahead), and once it
        -- knows the way upstream, don't turn to look any further
        local todo = {}
        for _, e in ipairs({ "up", "down", 0, 1, 2, 3 }) do
            if e ~= (path[#path] and OPP[path[#path]]) then todo[#todo + 1] = e end   -- not back downstream
        end
        while #todo > 0 and not (sealed or source) do
            local best = 1
            for i = 2, #todo do
                if turnsTo(todo[i]) < turnsTo(todo[best]) then best = i end
            end
            if up and turnsTo(todo[best]) > 0 then break end
            local e = table.remove(todo, best)
            local m = neighbour(e)
            local ok, data = look(e)
            local r = repairRange
            local past = r and m.z > r.z2
            if ok and (FLUID[data.name] or waterIn(data)) then
                if past and r.aheadDug then
                    fromOutside = true
                elseif not inBox(m) or past then
                    if seal(e) then sealed = true end
                elseif isSource(data) then
                    -- going over tunnel dug before, it's water getting in: fill it
                    if repairing and cutOff(e) then sealed = true else source = true end
                else
                    local s = (e == "up" and level >= 8) and -1 or strength(data)
                    if s < (level >= 8 and 0 or level) and (not upLevel or s < upLevel) then
                        up, upLevel = e, s
                    end
                end
            end
        end
        if sealed or source or not up then break end
        local ok, data = look(up)
        level = ok and tonumber(data.state and data.state.level) or 0
        if not moveDir(up) then break end
        path[#path + 1] = up
        unfed[key(T.pos)] = "traced"
    end
    for i = #path, 1, -1 do moveDir(OPP[path[i]]) end
    return sealed
end

-- The turtle is in flowing water (level `level`) with nothing beside it
-- to cut off.  Falling water always has something above feeding it, and
-- water in tunnel dug before (repairing) is getting in from somewhere:
-- those are followed to where they come in.  Other water, in tunnel it's
-- digging, is from what it's digging through (left over and draining, or
-- from sources the lanes will reach).  Once it has sealed where water came
-- in, it gives what's left a moment to drain, so it doesn't go chasing
-- that.  True if it sealed it.
function stem(level)
    local k = key(T.pos)
    local sealed = false
    if (level >= 8 or repairing) and unfed[k] == nil and stopFlow(level) then
        sealed = true
        sleep(3)
    end
    unfed[k] = unfed[k] or true
    return sealed
end

-- Water from outside the tunnel (ADR-0022's amendment).  Plugging the
-- block it comes in by isn't the end of water from above: it lands on the
-- plug, spreads along the top of the ceiling and comes in somewhere else.
-- So flowing water coming in from outside is followed out of the tunnel
-- to its source, the way it flows: up a falling column, then along to
-- stronger water, and the source is filled.  The turtle moves only
-- through the water (no digging), never into a protected area, and no
-- more than TRACE_REACH blocks out, and comes back the way it went.  If
-- it's still coming after that (a body of water, more than one source),
-- or the source is out of reach, water falling in through the ceiling is
-- caught in a bowl right above the hole (see bowl), and the rest is
-- sealed where it comes in, as before.
-- Lava is sealed where it comes in, as ever: it's slow (a block every 30
-- ticks), so what's left of a column after its source is filled looks
-- like more coming, and while the turtle is out it flows into the block
-- the turtle left.
-- TRACE_REACH: water runs at most 7 blocks on the flat from a source, so
-- 16 is a 9-block fall and the longest stream there is.  A trace that
-- turns back has cost twice that in moves (about 13 s); a bowl is 5 to 9
-- blocks and a few moves, so further out than that the bowl is cheaper.
TRACE_REACH = 16
TROUGH_MAX = 8       -- falling columns side by side caught in one trough, at most
tracing = false      -- following water out of the tunnel (its looks aren't the tunnel's water)
tracedAt = {}        -- key -> true: water coming in there has been traced once (not again)
function isFiller(n) return FILLER[n] end

-- The turtle is in fluid `name` of `level` outside the tunnel: the way
-- upstream (up, if it's falling; else the neighbour with stronger flow,
-- not back the way it came, the fewest turns first and no more turning
-- once it knows a way), and what's there.  Nil if nothing feeds it.
function upstream(name, level, back)
    if level >= 8 then
        local ok, data = look("up")
        if ok and data.name == name then return "up", data end
        return nil
    end
    local todo, best, bestData = {}, nil, nil
    for e = 0, 3 do if e ~= back then todo[#todo + 1] = e end end
    while #todo > 0 do
        local i = 1
        for j = 2, #todo do if turnsTo(todo[j]) < turnsTo(todo[i]) then i = j end end
        if best and turnsTo(todo[i]) > 0 then break end
        local e = table.remove(todo, i)
        local ok, data = look(e)
        if ok and data.name == name then
            if isSource(data) then return e, data end
            if strength(data) < level and (not bestData or strength(data) < strength(bestData)) then
                best, bestData = e, data
            end
        end
    end
    return best, bestData
end

-- Follow the fluid in direction e (outside the tunnel, `data`) upstream
-- to its source and fill it, then come back the way it went.  Up a
-- falling column the turtle blocks it, so the water above lands on the
-- turtle and spreads round the column a block up while it's there; the
-- game keeps water beside falling water flowing for good.  Going up,
-- the turtle takes that with it (what it left drains: nothing falls
-- under it).  But coming down a column that's still falling (out of
-- reach, a protected area, more than one source), each block it stops
-- in would leave water spread round the one above it, where it's open (a
-- cave).  So where the way it faces is open (air, or water spread there;
-- it turns from falling water, another column), it steps out of the
-- column and climbs down beside it, as far as it's open below, then backs
-- into it again; where it's rock, it goes on down the column.  True if
-- it filled the source; how far up and across that was from the tunnel;
-- else why not.
function traceOut(e, data)
    local name, path, filledIt, reached = data.name, {}, false, nil
    local from = here()
    tracing = true
    local why
    local d, cur = e, data
    while true do
        local n = neighbour(d)
        local area = T.guarded(n.x, n.y, n.z)
        if #path >= TRACE_REACH then why = "its source is more than " .. TRACE_REACH .. " blocks out"; break end
        if area then why = "it comes through the protected area " .. area; break end
        if n.z < 1 or (#path > 0 and inBox(n)) then why = "it comes from the tunnel"; break end
        if not moveDir(d) then why = "something is in its way"; break end
        path[#path + 1] = d
        trail[#trail + 1] = d
        local nd, nData = upstream(name, tonumber(cur.state and cur.state.level) or 0, OPP[d])
        if not nd then why = "nothing feeds it now"; break end
        if isSource(nData) then
            reached = neighbour(nd)
            area = T.guarded(reached.x, reached.y, reached.z)
            if area then why = "its source is in the protected area " .. area; break end
            filledIt = seal(nd)
            if not filledIt then why = "out of bulk blocks" end
            break
        end
        d, cur = nd, nData
    end
    reached = reached or here()
    local up, across = reached.y - from.y, math.abs(reached.x - from.x) + math.abs(reached.z - from.z)
    -- still falling (not filled, or more feeds it than the source it filled)?
    local falling = #path > 0 and (not filledIt or upstream(name, tonumber(cur.state and cur.state.level) or 0, OPP[path[#path]]) ~= nil)
    local i = #path
    while i >= 1 do
        -- still falling: down beside the column where it's open (the way it
        -- faces, or round from falling water there: another column), to
        -- the lowest block it climbed it from (or the floor), and back in
        if falling and path[i] == "up" and i > 1 and path[i - 1] == "up" then
            local out
            for _ = 1, 4 do
                local q = neighbour(T.dir)
                local ok, side = look(T.dir)
                local level = ok and tonumber(side.state and side.state.level) or 0
                if ok and not FLUID[side.name] then break end          -- (rock: shut in here)
                if not ok or (level > 0 and level < 8) then
                    if not inBox(q) and q.z >= 1 and not T.guarded(q.x, q.y, q.z) then out = T.dir end
                    break
                end
                T.face((T.dir + 1) % 4)
            end
            if out and moveDir(out) then
                -- (open below: air, or water spread there)
                local down = 0
                while i - down > 1 and path[i - down - 1] == "up" do
                    local ok, below = look("down")
                    local level = ok and tonumber(below.state and below.state.level) or 0
                    if ok and not (FLUID[below.name] and level > 0 and level < 8) then break end
                    if not moveDir("down") then break end
                    down = down + 1
                end
                if not T.back() then go(OPP[out]) end
                for _ = 1, down do trail[#trail] = nil end
                i = i - down
            end
        end
        local s = path[i]
        if not (s ~= "up" and s ~= "down" and T.dir == s and T.back()) and not moveDir(OPP[s]) then go(OPP[s]) end
        trail[#trail] = nil
        i = i - 1
    end
    tracing = false
    return filledIt, up, across, why
end

-- Before sealing the fluid in direction d: if it's water flowing in from
-- outside the tunnel, follow it to its source and fill that (once for
-- each place it comes in).  Still coming, or out of reach: a bowl for
-- water falling in through the ceiling.  True if it's seen to (no seal
-- needed there); false to seal it as before.
function traceIn(d)
    -- (water under the floor doesn't flow up into the tunnel: it's draining out)
    if d == "down" or waterMode or digLimit or tracing or #trail > 0 or not inBox(T.pos) then return false end
    local m = neighbour(d)
    if inBox(m) or tracedAt[key(m)] then return false end
    local ok, data = look(d)
    if not (ok and data.name == WATER) or isSource(data) then return false end
    tracedAt[key(m)] = true
    if T.countItem(isFiller) < 1 or not T.hasFuel(T.homeCost() + T.cfg.fuelMargin + 2 * TRACE_REACH + 8) then
        return false
    end
    local at = "(" .. key(m) .. ")"
    local filledIt, up, across, why = traceOut(d, data)
    local okm, now = look(d)
    local coming = okm and now.name == data.name
    if filledIt and not coming then
        stats.traced = stats.traced + 1
        print(string.format("Traced the water at %s to its source %d blocks up%s: filled.", at, up,
            across > 0 and string.format(" and %d across", across) or ""))
        return true
    end
    if filledIt then
        print(string.format("Filled the source of the water at %s, but it's still coming (more than one source).", at))
    elseif coming then
        print(string.format("Couldn't trace the water at %s: %s.", at, why))
    else
        return true                        -- (it stopped meanwhile: nothing to seal)
    end
    if d == "up" and (tonumber(now.state and now.state.level) or 0) >= 8 then return bowl() end
    return false
end

-- Water is falling into the tunnel through the ceiling, above the turtle
-- (in the top row): catch it right above the hole.  The block over the
-- hole gets four solid sides (bulk blocks where there's water, air or a
-- soft block; rock is left), and the hole is filled as its bottom: 5
-- blocks for one falling column.  The water lands in it and stays there:
-- water doesn't overflow, it only runs down.  Where a side is open, it
-- gets a block on top too (a rim: from the side's block, before it's put
-- in), as water landing on the turtle while it stood in the bowl spread
-- round the column there, and the game keeps water beside falling water
-- flowing for good: 9 blocks in a cave.  Falling columns beside it, over
-- the tunnel and falling through the ceiling, are caught with it in one
-- closed trough (TROUGH_MAX): the turtle goes along the trough's blocks,
-- putting in each one's outer sides, and fills each one's hole from
-- above, but the one it came up through, which it fills from the tunnel,
-- last.  True if it did.
function bowl()
    local hole = neighbour("up")
    local c = { x = hole.x, y = hole.y + 1, z = hole.z }
    if T.countItem(isFiller) < 9 or T.guarded(hole.x, hole.y, hole.z) or T.guarded(c.x, c.y, c.z) then return false end
    if not moveDir("up") then return false end
    trail[#trail + 1] = "up"
    if not moveDir("up") then
        moveDir("down")
        trail[#trail] = nil
        return false
    end
    trail[#trail + 1] = "up"
    tracing = true
    local placed, cells, count = 0, { [key(T.pos)] = true }, 1
    -- a block put in direction d, keeping one back for the hole it came up through
    local function add(d)
        if T.countItem(isFiller) > 1 and putFiller(d) then placed = placed + 1 end
    end
    local function visit(entry)
        local sides = {}                   -- (the fewest turns first)
        for e = 0, 3 do sides[#sides + 1] = { e = e, q = neighbour(e) } end
        table.sort(sides, function(a, b)
            if turnsTo(a.e) ~= turnsTo(b.e) then return turnsTo(a.e) < turnsTo(b.e) end
            return a.e < b.e
        end)
        for _, s in ipairs(sides) do
            if not cells[key(s.q)] and not T.guarded(s.q.x, s.q.y, s.q.z) then
                local ok, data = look(s.e)
                local level = ok and tonumber(data.state and data.state.level) or 0
                local column = false
                -- falling water beside it, over the tunnel: another column
                -- falling in, if the ceiling under it is open (else it's
                -- water landing on the ceiling, which a side keeps out)
                if ok and data.name == WATER and level >= 8 and count < TROUGH_MAX and s.q.x >= X0 and s.q.x <= X1
                        and s.q.z >= 1 and s.q.z <= LENGTH and moveDir(s.e) then
                    trail[#trail + 1] = s.e
                    local okd, below = look("down")
                    if not okd or FLUID[below.name] then
                        column, cells[key(s.q)], count = true, true, count + 1
                        visit(false)
                    end
                    if not moveDir(OPP[s.e]) then go(OPP[s.e]) end
                    trail[#trail] = nil
                end
                if not column and (not ok or FLUID[data.name] or waterIn(data) or soft(data)) then
                    if ok and not FLUID[data.name] and not protected(data.name) then digDir(s.e) end
                    -- the rim: water from above landed on the turtle while
                    -- it stood here and spread round the column a block up,
                    -- where the column keeps it flowing for good (as the
                    -- game has it): a block on top of the side keeps it in
                    if moveDir(s.e) then
                        add("up")
                        if not T.back() then go(OPP[s.e]) end
                    end
                    add(s.e)
                end
            end
        end
        if not entry then add("down") end
    end
    visit(true)
    tracing = false
    for _ = 1, 2 do
        if not moveDir("down") then go("down") end
        trail[#trail] = nil
    end
    if putFiller("up") then placed = placed + 1 end
    stats.bowls = stats.bowls + 1
    stats.bowlBlocks = stats.bowlBlocks + placed
    if count > 1 then
        print(string.format("Caught the water falling in at (%s): a trough over %d columns, %d blocks above the ceiling.",
            key(hole), count, placed))
    else
        print(string.format("Caught the water falling in at (%s): a bowl of %d blocks above the ceiling.", key(hole), placed))
    end
    return true
end

warnedWet = false
function dry(d)
    for _ = 1, 4 do
        local ok, data = look(d)
        if not (ok and FLUID[data.name]) then return true end
        stats.wet = stats.wet + 1
        if not T.selectItem(function(n) return FILLER[n] end) then
            fillerKeep = FILLER_KEEP_WET   -- wet ground: carry more from now on
            trip("Out of blocks to seal water with")
            ok, data = look(d)
            if not (ok and FLUID[data.name]) then return true end
        end
        turtle.select(1)
        if isSource(data) then
            noteSource(neighbour(d))
            if not seal(d) then break end
            digDir(d)
            ok, data = look(d)
            if not (ok and FLUID[data.name]) then return true end
        end
        -- something feeds it: step in and cut it off, or, with nothing
        -- beside it to cut off, follow the flow to where it comes in
        local level = tonumber(data.state and data.state.level) or 0
        if not moveDir(d) then break end
        local cut = 0
        eachAround(OPP[d], function(e)
            if cutOff(e) then cut = cut + 1 end
        end)
        if cut == 0 and level > 0 and stem(level) then cut = 1 end
        local backed = false
        if d ~= "up" and d ~= "down" then T.face(d); backed = T.back() end
        if not backed then moveDir(OPP[d]) end
        if cut == 0 then return true end   -- nothing feeds it: it drains away
    end
    if not warnedWet then
        warnedWet = true
        print("Couldn't stop the water at " .. T.posString() .. " (out of bulk blocks?); working through it.")
    end
    return false
end

-- The tunnel's floor: the blocks under its bottom row.
function isFloor(p)
    return p.y == Y0 - 1 and p.x >= X0 and p.x <= X1 and p.z >= 1 and p.z <= LENGTH
end

-- Make the floor block in direction d something a player can walk on:
-- fill a hole (a crevasse, a cave, where floor ore was) or a fluid with a
-- bulk block, digging out grass, cobwebs and the like first.  Out of
-- bulk blocks, it fetches more from its home.
warnedFloor = false
function fill(d)
    local ok, data = look(d)
    if ok and not leaky(data) then return true end
    if ok and not FLUID[data.name] then room(); digDir(d) end
    if not fillerDry and not T.selectItem(function(n) return FILLER[n] end) then
        trip("Out of blocks to fill the floor")
    end
    if putFiller(d) then
        stats.filled = stats.filled + 1
        return true
    end
    local n = neighbour(d)
    if not warnedFloor then
        warnedFloor = true
        print("Couldn't fill a hole in the floor at (" .. key(n) .. "); no bulk blocks left.")
    end
    holesLeft[#holesLeft + 1] = n.z
    return false
end

-- Floor holes left open for want of bulk blocks since the last report:
-- said at the end of each segment (the next time it goes over the
-- tunnel, it fills them).
holesLeft = {}
function reportHoles()
    if #holesLeft == 0 then return end
    table.sort(holesLeft)
    print(string.format("Left %d floor holes open at z=%d..%d (no bulk blocks to fill them): going over the tunnel again fills them.",
        #holesLeft, holesLeft[1], holesLeft[#holesLeft]))
    holesLeft = {}
end


-- Clear the tunnel block in direction d without moving into it: dig it
-- out (again while gravel keeps falling), follow it if it's ore, or fill
-- and dig out a fluid source.
function clearCell(d)
    local n = neighbour(d)
    if blocked[key(n)] then return end
    for _ = 1, 30 do
        room()                     -- first: a trip changes what's there
        local ok, data = look(d)
        if not ok then break end
        if isTarget(data) then mineVein(d); break end
        if FLUID[data.name] then
            if digLimit then break end
            dry(d)
            ok, data = look(d)
            if not ok or FLUID[data.name] then break end
        end
        if protected(data.name) then
            standing(n, data.name)
            return
        end
        if not digDir(d) then return end
    end
    plugs[key(n)] = nil
    opened[key(n)] = true
end

-- Look at the block in direction d outside the tunnel: follow ore, seal
-- fluids.
function examine(d)
    local n = neighbour(d)
    if opened[key(n)] or not inReach(n) then return end
    local ok, data = look(d)
    if not ok then opened[key(n)] = true
    elseif isTarget(data) then mineVein(d)
    elseif leaky(data) then seal(d)
    end
end

-- The block in direction d is ore: dig into it, look all round, follow
-- any more ore, then come back.  Ore is followed within reach (and
-- within the scan, fetching what one found); diamond and coal further:
-- anywhere a scan saw, and from such a block on to the next however far
-- out, so their veins are followed to the end.
function mineVein(d)
    local ok0, data0 = look(d)
    local far = ok0 and goesFar(data0.name)
    if #trail == 0 then stats.veins = stats.veins + 1 end
    if not go(d) then return end
    stats.ore = stats.ore + 1
    if ok0 and isWoodBlock(data0.name) then
        stats.wood = stats.wood + 1
        updateWoodNeed(false)              -- (enough now: it stops seeking it)
    end
    trail[#trail + 1] = d
    -- Look round, the fewest turns away first; not where a scan saw
    -- neither ore nor fluid (no turning to look at plain rock).
    local todo = { "up", "down", 0, 1, 2, 3 }
    local wet = false
    while true do
        local best, near
        for i, e in ipairs(todo) do
            local m = neighbour(e)
            local n = inReach(m)
            local fluid = scanSays(m) == "fluid"
            if not opened[key(m)] and (fluid or n or (m.z >= 1 and (far or (bound and inScan(m)))))
                    and scanSays(m) ~= "clear" and (not best or turnsTo(e) < turnsTo(todo[best])) then
                best, near = i, n
            end
        end
        if not best then break end
        local e = table.remove(todo, best)
        local ok, data = look(e)
        if not ok then opened[key(neighbour(e))] = true
        elseif isTarget(data) and (near or goesFar(data.name)) then mineVein(e)
        elseif FLUID[data.name] or waterIn(data) then seal(e); wet = true
        end
    end
    local here = { x = T.pos.x, y = T.pos.y, z = T.pos.z }
    retreat(d)
    trail[#trail] = nil
    if wet then sealBehind(d) end
    if isFloor(here) then fill(d) end      -- ore out of the floor: fill the hole
end

--------------------------------------------------------------------------
-- What it leaves standing in the tunnel
--------------------------------------------------------------------------
-- A spawner, chest, barrel or shulker box in the tunnel's way is never
-- dug (see protected): it's left standing, and the tunnel goes round it.
-- A spawner gets a torch beside each of its sides and on its top, where
-- that's in the tunnel (nothing spawns in the rock round it), so no mobs
-- come from it; a torch that would wall the tunnel off is left out.  What
-- it left, and the torches round a spawner, are kept in BLOCKED_FILE
-- ("x y z name" a line; "dark" after a spawner not lit yet), so every
-- walk, trip and later run goes round them (going through a torch would
-- dig it).
BLOCKED_FILE = T.dataPath("mine.blocked")
SPAWNER = "minecraft:spawner"
WAY_PAD = 3          -- how far past the ends of a way round it may look
blocked = {}         -- key -> { x, y, z, name, dark }: what it goes round

-- Is a block called this left standing for the tunnel to go round?  (A
-- ComputerCraft block may be another turtle passing: that still stops it.)
function leftStanding(name)
    return protected(name) and not text.startsWith(name, "computercraft:")
end

function saveBlocked()
    local lines = {}
    for _, k in ipairs(tables.sortedKeys(blocked)) do
        local b = blocked[k]
        lines[#lines + 1] = string.format("%d %d %d %s%s", b.x, b.y, b.z, b.name, b.dark and " dark" or "")
    end
    if #lines == 0 then clearBlocked() else fileio.write(BLOCKED_FILE, table.concat(lines, "\n") .. "\n") end
end

function loadBlocked()
    local out, saved = {}, fileio.read(BLOCKED_FILE)
    for _, line in ipairs(saved and text.lines(saved) or {}) do
        local w = text.words(line)
        if scan.isInteger(w[1] or "") and scan.isInteger(w[2] or "") and scan.isInteger(w[3] or "") and w[4] then
            local b = { x = tonumber(w[1]), y = tonumber(w[2]), z = tonumber(w[3]), name = w[4] }
            if w[5] == "dark" then b.dark = true end
            out[key(b)] = b
        end
    end
    return out
end

function clearBlocked()
    if fs.exists(BLOCKED_FILE) then fs.delete(BLOCKED_FILE) end
end

-- The block at p, called `name`, is one it leaves standing (if p is in
-- the tunnel): noted, and said.
function standing(p, name)
    local k = key(p)
    if blocked[k] or not (inBox(p) and leftStanding(name)) then return end
    blocked[k] = { x = p.x, y = p.y, z = p.z, name = name }
    if name == SPAWNER then
        blocked[k].dark = true
        stats.spawners = stats.spawners + 1
    end
    opened[k] = nil
    stats.standing = stats.standing + 1
    saveBlocked()
    print(string.format("Leaving the %s at (%s) standing: the tunnel goes round it.", name, k))
end

-- The way from here to p through the tunnel, round what's left standing
-- in it: a list of directions, the cheapest (a block not dug yet costing
-- 3 steps), or nil if there's none.  It keeps to the stretch of tunnel
-- between here and p and WAY_PAD blocks either side.
function wayRound(p)
    local zlo = math.max(1, math.min(T.pos.z, p.z) - WAY_PAD)
    local zhi = math.max(T.pos.z, p.z) + WAY_PAD
    local goal = key(p)
    local function free(c)
        local k = key(c)
        if k == goal then return true end
        return inBox(c) and c.z >= zlo and c.z <= zhi and not blocked[k]
    end
    local start = here()
    local cost, from = { [key(start)] = 0 }, {}
    local queue, top = { [0] = { start } }, 0      -- the cells to look on from, by what it cost to get there
    local c = 0
    while c <= top do
        local list = queue[c] or {}
        local i = 1
        while list[i] do                           -- (one costing as much can join while it's walked)
            local p0 = list[i]
            i = i + 1
            local k0 = key(p0)
            if cost[k0] == c then
                if k0 == goal then
                    local way, k = {}, k0
                    while from[k] do
                        table.insert(way, 1, from[k].d)
                        k = from[k].k
                    end
                    return way
                end
                for _, d in ipairs({ 0, 2, 1, 3, "up", "down" }) do
                    local v = DELTA[d]
                    local n = { x = p0.x + v[1], y = p0.y + v[2], z = p0.z + v[3] }
                    local kn = key(n)
                    if free(n) then
                        local nc = c + (knownAir(n) and 1 or 3)
                        if not cost[kn] or nc < cost[kn] then
                            cost[kn], from[kn] = nc, { k = k0, d = d }
                            queue[nc] = queue[nc] or {}
                            table.insert(queue[nc], n)
                            top = math.max(top, nc)
                        end
                    end
                end
            end
        end
        c = c + 1
    end
    return nil
end

-- Go to p round what's left standing (see wayRound), going round any it
-- finds on the way too.  True once there.
function goRound(p)
    for _ = 1, 4 do
        if T.at(p) then return true end
        local way = wayRound(p)
        if not way then return false end
        for _, d in ipairs(way) do
            if not go(d) then
                if not blocked[key(neighbour(d))] then return false end
                break                              -- (one more found: a new way round)
            end
        end
    end
    return T.at(p)
end

-- Past what's left standing next to it in direction d (along `axis`,
-- toward `target`): round it, to the first block beyond that isn't.
-- False and "end" if all of it up to `target` is left standing; false
-- and "no way round" if there isn't one.
function passBy(d, axis, target)
    local p = here()
    lightSpawners()                        -- (its torches are gone round too)
    local v = DELTA[d]
    local c = { x = p.x + v[1], y = p.y + v[2], z = p.z + v[3] }
    while blocked[key(c)] do
        if c[axis] == target then return false, "end" end
        c = { x = c.x + v[1], y = c.y + v[2], z = c.z + v[3] }
    end
    if goRound(c) then return true end
    return false, "no way round"
end

-- One block on along a lane (direction d, toward z = to), or past what's
-- left standing there, round it, to the first block beyond.  True, short
-- of `to`, if the rest of the lane is all left standing.
function onAlong(d, to)
    local ok, what = go(d)
    if ok or not blocked[key(neighbour(d))] then return ok, what end
    local passed, why = passBy(d, "z", to)
    if passed or why == "end" then return true end
    return false, tostring(what) .. ": no way round it in a tunnel this size"
end

-- Would a torch at c still leave a way through the tunnel round the
-- spawner at s?  (Every block of the tunnel near it, but what it goes
-- round, still joined up.)
function stillThrough(s, c)
    local zlo, zhi = math.max(1, s.z - WAY_PAD), math.min(LENGTH, s.z + WAY_PAD)
    local kc = key(c)
    local function free(p)
        return inBox(p) and p.z >= zlo and p.z <= zhi and not blocked[key(p)] and key(p) ~= kc
    end
    local cells, first = 0, nil
    for z = zlo, zhi do
        for y = Y0, Y1 do
            for x = X0, X1 do
                local p = { x = x, y = y, z = z }
                if free(p) then
                    cells = cells + 1
                    first = first or p
                end
            end
        end
    end
    if not first then return false end
    local seen, queue, head = { [key(first)] = true }, { first }, 1
    while queue[head] do
        local p = queue[head]
        head = head + 1
        for _, d in ipairs({ 0, 1, 2, 3, "up", "down" }) do
            local v = DELTA[d]
            local n = { x = p.x + v[1], y = p.y + v[2], z = p.z + v[3] }
            if free(n) and not seen[key(n)] then
                seen[key(n)] = true
                queue[#queue + 1] = n
            end
        end
    end
    return #queue == cells
end

-- A torch at c, beside the spawner at s on its side f: put from the block
-- beyond c, so it hangs on the spawner (or stands on it, on top), else
-- from beside c (hanging on what's across it, or standing on what's under
-- it).  True once there's one there.
function torchBeside(s, f, c)
    local function isTorch(n) return TORCHES[n] end
    local v = DELTA[f]
    local spots = { { x = c.x + v[1], y = c.y + v[2], z = c.z + v[3] } }
    for _, e in ipairs({ 0, 1, 2, 3 }) do
        if e ~= f and e ~= OPP[f] then
            local u = DELTA[e]
            spots[#spots + 1] = { x = c.x + u[1], y = c.y, z = c.z + u[3] }
        end
    end
    for _, p in ipairs(spots) do
        if inBox(p) and not blocked[key(p)] and goRound(p) then
            local d = dirTo(c)
            clearCell(d)                   -- (dug out if it isn't yet: ore followed, fluid dried)
            local ok, data = look(d)
            if ok and leftStanding(data.name) then
                standing(c, data.name)
                return false
            end
            local there = ok and TORCH_BLOCKS[data.name]
            if not ok and T.selectItem(isTorch) and placeDir(d) then
                there = true
                stats.spawnerTorches = stats.spawnerTorches + 1
            end
            turtle.select(1)
            if there then
                blocked[key(c)] = { x = c.x, y = c.y, z = c.z, name = "minecraft:torch" }
                opened[key(c)] = nil
                return true
            end
        end
    end
    return false
end

-- Light the spawner at s: a torch beside each of its sides and on top,
-- where that's in the tunnel and leaves a way through it.
function lightSpawner(s)
    local lit, left = 0, 0
    for _, f in ipairs({ 2, 3, 1, "up", 0 }) do
        local v = DELTA[f]
        local c = { x = s.x + v[1], y = s.y + v[2], z = s.z + v[3] }
        local b = blocked[key(c)]
        if b and TORCH_BLOCKS[b.name] then lit = lit + 1
        elseif inBox(c) and not b then
            if not stillThrough(s, c) then left = left + 1
            elseif torchBeside(s, f, c) then lit = lit + 1 end
        end
    end
    s.dark = nil
    saveBlocked()
    if lit == 0 and left > 0 then
        print(string.format("No torch can go by the spawner at (%s) without walling the tunnel off.", key(s)))
    else
        print(string.format("Lit the spawner at (%s) with %d torches%s.", key(s), lit,
            left > 0 and string.format(" (%d more would have walled the tunnel off)", left) or ""))
    end
end

-- Light the spawners found and not lit yet (on a trip, or going back,
-- they wait), then back to where it was, unless a torch went there.
warnedSpawner = false
function lightSpawners()
    if inTrip or digLimit then return end
    local list = {}
    for _, b in pairs(blocked) do
        if b.dark then list[#list + 1] = b end
    end
    if #list == 0 then return end
    if T.countItem(function(n) return TORCHES[n] end) == 0 then
        if not warnedSpawner then
            warnedSpawner = true
            print("No torches to light the spawner at (" .. key(list[1]) .. ") with: it's lit once there are.")
        end
        return
    end
    table.sort(list, function(a, b) return key(a) < key(b) end)
    local back, facing = here(), T.dir
    for _, s in ipairs(list) do lightSpawner(s) end
    if not blocked[key(back)] and goRound(back) then T.face(facing) end
end

--------------------------------------------------------------------------
-- Getting around inside the tunnel, through blocks already dug (a trip
-- home is made with a nearly full inventory): over to `via`, a finished
-- lane, if the turtle's own lane isn't dug back to the segment's first
-- slice yet; back to that slice; along its row to the start column
-- (columns are finished in order), up or down it (finished first) to row
-- 0, then back along the start column to the home.  Going back out
-- reverses that.
--------------------------------------------------------------------------
via = nil                  -- the lane before, while the turtle's lane runs back toward the home

function alongAxis(axis, target)
    while T.pos[axis] ~= target do
        local up = T.pos[axis] < target
        local d
        if axis == "x" then d = up and 1 or 3
        elseif axis == "y" then d = up and "up" or "down"
        else d = up and 0 or 2 end
        local ok, what = go(d)
        -- (past what's left standing in the way, round it)
        if not ok and not (blocked[key(neighbour(d))] and passBy(d, axis, target)) then return false, what end
    end
    return true
end

function tunnelHome()
    local first = home.z + 1
    if T.pos.z >= first then
        if via then
            alongAxis("y", via.y)
            alongAxis("x", via.x)
        end
        alongAxis("z", first)
    end
    alongAxis("x", 0)
    alongAxis("y", 0)
    alongAxis("z", home.z)
    if not T.at(home) then goRound(home) end   -- (a block on the way left standing)
    T.face(home.face)
    return T.at(home)
end

function tunnelTo(p)
    if T.pos.z < home.z + 1 then alongAxis("z", home.z + 1) end
    local lane = via or p
    alongAxis("y", lane.y)
    alongAxis("x", lane.x)
    alongAxis("z", p.z)
    alongAxis("x", p.x)
    alongAxis("y", p.y)
    if not T.at(p) then goRound(p) end         -- (a block on the way left standing)
end

--------------------------------------------------------------------------
-- At a home
--------------------------------------------------------------------------
-- How many of each item the chest on `side` holds (none if it can't be read).
function chestCounts(side) return T.containerCounts(side) or {} end

-- Top up what the turtle works with from the home's chests: a stack of
-- filler from the bulk chest (floors and seals), torches from the
-- valuables chest.
function restockKit()
    restockSet(home.bulk, FILLER, fillerKeep)
    restockSet(home.val, TORCHES, TORCH_KEEP)
    restockSet(home.val, T.fuel, FUEL_KEEP)
    updateWoodNeed(true)
end

-- Up to `keep` of the items in `set` on board, from the chest on `side`.
function restockSet(side, set, keep)
    local test = function(n) return set[n] end
    local counts = chestCounts(side)
    for _, name in ipairs(tables.sortedKeys(counts)) do
        local n = counts[name]
        local have = T.countItem(test)
        if have >= keep then break end
        if set[name] then
            T.restockFrom(side, name, T.countItem(name) + math.min(n, keep - have), { quiet = true, room = ROOM })
        end
    end
end

-- Put what the turtle carries in the home's chests: bulk in the bulk
-- chest, the rest (supplies included) in the valuables chest, keeping
-- tools, a stack of filler and its torches; then restock those.  `only`
-- limits it to "bulk", or makes it "everything".  Returns true if
-- everything fit.
function unload(only)
    if not (containerOn(home.val) and containerOn(home.bulk)) then return false, "missing" end
    fillerDry = false                    -- (what it brings may be filler, or the chest may have some now)
    local fits, kept, torches, fuel, buckets = true, 0, 0, 0, 0
    for s = 1, 16 do
        local it = turtle.getItemDetail(s, true)
        if it and not T.isTool(it.name) then
            local keep = 0
            if FILLER[it.name] and kept < fillerKeep and only ~= "everything" then
                keep = math.min(it.count, fillerKeep - kept)
                kept = kept + keep
            elseif TORCHES[it.name] and torches < TORCH_KEEP and only ~= "everything" then
                keep = math.min(it.count, TORCH_KEEP - torches)
                torches = torches + keep
            elseif T.fuel[it.name] and fuel < FUEL_KEEP and only ~= "everything" then
                keep = math.min(it.count, FUEL_KEEP - fuel)
                fuel = fuel + keep
            elseif isScanner(it.name) and only ~= "everything" then
                keep = it.count
            elseif isUpgrade(it.name) then
                keep = it.count                  -- (a modem, a chunk controller: the turtle's own, never left in a chest)
            elseif it.name == BUCKET and buckets < 1 and only ~= "everything" then
                keep, buckets = 1, 1
            end
            local bulk = isBulk(it)
            if it.count > keep and (bulk or only == nil or only == "everything") then
                local side = bulk and home.bulk or home.val
                turtle.select(s)
                dropSide(side, it.count - keep)
                -- the chest is full: it grows into a double chest, if it can
                if turtle.getItemCount(s) > keep and grow(home, bulk and "bulk" or "val") then
                    turtle.select(s)
                    dropSide(side, turtle.getItemCount(s) - keep)
                end
                if turtle.getItemCount(s) > keep then
                    -- a full bulk chest never stops the run: what doesn't fit is thrown away
                    if bulk then throwAway(s, turtle.getItemCount(s) - keep) else fits = false end
                end
            end
        end
    end
    T.tidyInventory()
    if home.val ~= "front" or home.face == T.dir then T.compactContainer(home.val) end
    if only == nil then restockKit() end
    return fits, "full"
end

-- Out of filler at a home whose bulk chest has none: a home's bulk chest
-- holds what the segment after it dug, so a cavern there leaves little.
-- Take a load from the homes behind, the nearest first, and come back.
-- Found none anywhere: fillerDry, so filling the floor doesn't send it
-- looking again for every hole (till it next unloads).
fillerWant = nil     -- (open water) how many it needs: fetched from behind if the home is short
function fillerFromBehind()
    local function isFiller(n) return FILLER[n] end
    local want = fillerWant or 1
    if T.countItem(isFiller) >= want then return end
    local working = home
    for k = working.k - 1, 0, -1 do
        if not fuelToGoOn(2 * (working.z - homeAt(k).z)) then break end
        home = homeAt(k)
        if not tunnelHome() then break end
        restockSet(home.bulk, FILLER, fillerKeep)
        if T.countItem(isFiller) >= want then
            print(string.format("Took %d bulk blocks from home %d.", T.countItem(isFiller), k))
            break
        end
    end
    home = working
    if not tunnelHome() then stop("Couldn't get back to home " .. home.k .. " from " .. T.posString()) end
    fillerDry = T.countItem(isFiller) == 0
end

-- unload, or stop the job if a chest is missing or full.  A home's
-- valuables chest that's full (grown, or with no chest to grow it) sends
-- the turtle hauling to the start and back (mine.haul), and only the
-- start's being full stops it.
function unloadOrStop(only)
    local ok, why = unload(only)
    if not ok and why == "full" and haulWhenFull and home.k > 0 then
        viaStart(string.format("The valuables chest at home %d (z=%d) is full", home.k, home.z))
        ok, why = unload(only)
    end
    if not ok then
        local where = home.k == 0 and "the start" or string.format("home %d (z=%d)", home.k, home.z)
        stop(why == "missing" and ("The chests at " .. where .. " are missing.")
            or ("The valuables chest at " .. where .. " is full."))
    end
end

-- Throw n of slot s away, back along the tunnel (bulk with no room for it
-- anywhere: it despawns in five minutes).
function throwAway(s, n)
    local facing = T.dir
    T.face(2)
    turtle.select(s)
    turtle.drop(n)
    T.face(facing)
    stats.thrown = stats.thrown + n
end

-- Whether a chest's counts hold supplies beyond a home's fuel stock (the
-- last home's, still to be fetched or moved forward).
function hasSupplies(counts)
    local fuel = 0
    for name, n in pairs(counts) do
        if T.fuel[name] then fuel = fuel + n
        elseif isSupply(name) then return true end
    end
    return fuel > FUEL_STOCK
end

-- How many slots the container on `side` has (0 if none).
function containerSize(side)
    local ok, n = pcall(peripheral.call, side, "size")
    return ok and tonumber(n) or 0
end

-- Dig the chest in direction d: mine digs no chest otherwise.  `area`,
-- the protected area it's in, is let go of for it.  True if it was dug.
function digChestAt(d, area)
    local before = T.cfg.digContainers
    T.cfg.digContainers = true
    local ok, dug = pcall(function()
        if guardHomes and area then return T.withUnprotected(area, T.digDir, d) end
        return T.digDir(d)
    end)
    T.cfg.digContainers = before
    if not ok then error(dug, 0) end
    if dug and guardHomes and area then T.unprotect(area) end
    return dug
end

-- A home's chest (kind "val" or "bulk") is full: put a second chest beside
-- it, which joins it into a double chest.  Both of a home's chests were
-- placed facing the wall, so they face into the tunnel, and a chest
-- placed the same way one block along the tunnel joins them: the
-- valuables one at z-1 (z+1 when a torch niche is at z-1), the bulk one
-- at z-1.  Only with a chest to spare beyond the two the next home takes,
-- and only at a home (not the start).  One that doesn't join (a barrel
-- there, or one placed some other way) is taken back.  The turtle starts
-- and ends at the home, facing its wall.  True once the chest has grown.
function grow(h, kind)
    if h.k == 0 or (grown[h.k] and grown[h.k][kind] ~= nil) then return false end
    local spare = T.countItem(GROW_CHEST) + (chestCounts(h.val)[GROW_CHEST] or 0) - (h.k == lastHome and 2 or 0)
    if spare < 1 then return false end
    if T.countItem(GROW_CHEST) == 0 then T.restockFrom(h.val, GROW_CHEST, 1, { quiet = true, room = 0 }) end
    if T.countItem(GROW_CHEST) == 0 then return false end
    local wasTrip = inTrip
    inTrip = true                  -- (no trips home from here: it's at home)
    local d = kind == "val" and h.face or T.sideDir(h.bulk)
    local at
    for _, z in ipairs(kind == "val" and { h.z - 1, h.z + 1 } or { h.z - 1 }) do
        if z >= 1 and z <= LENGTH and alongAxis("z", z) then
            T.face(h.face)
            local ok, data = look(d)
            if not (ok and (TORCH_BLOCKS[data.name] or protected(data.name))) and placeChest(d, GROW_CHEST) then
                at = z
                break
            end
        end
    end
    local joined = at and containerSize(sideOf(d)) >= 2 * CHEST_SLOTS
    local name = kind == "val" and "valuables" or "bulk"
    if at and not joined then
        digChestAt(d)
        print(string.format("The chest put beside home %d's %s chest didn't join it; took it back.", h.k, name))
    end
    if joined and kind == "val" then roomAboveChest(h, at) end
    alongAxis("z", h.z)
    T.face(h.face)
    inTrip = wasTrip
    grown[h.k] = grown[h.k] or {}
    if not joined then
        grown[h.k][kind] = false
        return false
    end
    grown[h.k][kind] = at
    saveGrown()
    protectHome(h)
    stats.grown = stats.grown + 1
    print(string.format("Home %d's %s chest is a double chest now (z=%d and %d).", h.k, name, h.z, at))
    return true
end

-- The second chest of home h's valuables chest, once that's empty: dug
-- (the chest goes back with the supplies) and the wall filled.  The
-- turtle starts and ends at the home, facing its wall.
function pickUpGrown(h)
    local z = grown[h.k] and grown[h.k].val
    if type(z) ~= "number" then return end
    -- what's left (a home's fuel stock) comes out first: which half holds
    -- which slots can't be seen, and a dug half spills its own
    local left = chestCounts("front")
    local okList, slots = pcall(peripheral.call, "front", "list")
    local stacks = 0
    for _ in pairs(okList and slots or {}) do stacks = stacks + 1 end
    if stacks + 1 > T.freeSlots() then return end
    local taken = {}
    for _, name in ipairs(tables.sortedKeys(left)) do
        local before = T.countItem(name)
        T.restockFrom("front", name, before + left[name], { quiet = true, room = 0 })
        taken[name] = T.countItem(name) - before
    end
    local dug = false
    if next(chestCounts("front")) == nil then
        -- a block to fill the wall with, from the bulk chest below
        if T.countItem(function(n) return FILLER[n] end) == 0 and containerOn(h.bulk) then
            restockSet(h.bulk, FILLER, 1)
        end
        alongAxis("z", z)
        T.face(h.face)
        local ok, data = look(h.face)
        if ok and data.name == GROW_CHEST and digChestAt(h.face, HOME_AREA .. h.k .. " chest2") then
            dug = true
            putFiller(h.face)
            grown[h.k].val = nil
            saveGrown()
            stats.pickedUp = stats.pickedUp + 1
        end
        alongAxis("z", h.z)
        T.face(h.face)
    end
    for _, name in ipairs(tables.sortedKeys(taken)) do       -- back in, into the chest that's left
        local n = taken[name]
        for s = 16, 1, -1 do
            if n <= 0 then break end
            local it = turtle.getItemDetail(s)
            if it and it.name == name then
                turtle.select(s)
                local was = it.count
                dropSide("front", math.min(n, was))
                n = n - (was - turtle.getItemCount(s))
            end
        end
    end
    turtle.select(1)
    return dug
end

function refuel() T.refuelFrom(home.val, fuelGoal + home.z) end

-- Enough fuel to do some work and still get back to the start?  The fuel
-- it carries counts: the tank is topped up from it on the way (T.ensureFuel).
function fuelToGoOn(extra)
    local need = home.z + T.cfg.fuelMargin + (extra or FUEL_WORK)
    return T.hasFuel(need) or T.totalFuelAvailable() >= need
end

-- Go home, unload and refuel, and come back to this exact spot and
-- facing (up the vein too, if in one).
function trip(why)
    if inTrip then return end
    inTrip = true
    local back, facing = here(), T.dir
    local path = trail
    print(string.format("%s at %s: back to home %d.", why, T.posString(), home.k))
    for i = #path, 1, -1 do retreat(path[i]) end
    trail = {}                     -- out of the vein (also if the job stops here)
    local spot = here()
    if not tunnelHome() then stop("Couldn't get back to home " .. home.k .. " from " .. T.posString()) end
    unloadOrStop()
    fillerFromBehind()
    refuel()
    if not fuelToGoOn() then
        if not waitSupplies then stop("Not enough fuel left to go on and still get back.") end
        viaStart("Low on fuel", { fuel = FUEL_WORK })
    end
    tunnelTo(spot)
    for _, d in ipairs(path) do go(d) end
    trail = path
    T.face(facing)
    if not T.at(back) then
        print("Couldn't get back to (" .. key(back) .. "); carrying on from " .. T.posString())
    end
    inTrip = false
end

-- Take supplies (chests and fuel) from the home's valuables chest while
-- there's room, leaving a stock of FUEL_STOCK fuel items in every home but
-- the start, so there's fuel along the tunnel for a resume from any home
-- (and the next tunnel's turtle).  `room`: slots to leave free (1).
-- Returns how many it took, and whether any are left to come back for
-- (the stock doesn't count).
function takeSupplies(room)
    local took, stock = 0, home.k > 0 and FUEL_STOCK or 0
    local counts = chestCounts(home.val)
    local function leaveOf(name, n)
        if not T.fuel[name] then return 0 end
        local leave = math.min(n, stock)
        stock = stock - leave
        return leave
    end
    for _, name in ipairs(tables.sortedKeys(counts)) do
        local n = counts[name]
        if isSupply(name) then
            local want = n - leaveOf(name, n)
            if want > 0 then
                local before = T.countItem(name)
                T.restockFrom(home.val, name, before + want, { quiet = true, room = room or 1 })
                took = took + T.countItem(name) - before
            end
        end
    end
    counts, stock = chestCounts(home.val), home.k > 0 and FUEL_STOCK or 0
    for _, name in ipairs(tables.sortedKeys(counts)) do
        if isSupply(name) and counts[name] > leaveOf(name, counts[name]) then return took, true end
    end
    return took, false
end

-- Put the supplies the turtle carries in the valuables chest in front.
-- False (keeping them) if there's no chest there: dropped at nothing,
-- they'd land on the ground, and at a minecart, in it.
function leaveSupplies()
    if not containerOn("front") then return false end
    for s = 1, 16 do
        local it = turtle.getItemDetail(s)
        if it and isSupply(it.name) then
            turtle.select(s)
            turtle.drop()
        end
    end
    turtle.select(1)
    return true
end

-- The side ("front", "top" or "bottom") that is direction d.
function sideOf(d) return d == "up" and "top" or d == "down" and "bottom" or "front" end

-- Clear what isn't a block out of the space in direction d: a minecart
-- there (mineshafts have them) is hit until it breaks, and the minecart
-- and anything it spills are picked up.
function clearEntities(d)
    for _ = 1, 20 do
        if not attackDir(d) then break end
    end
    for _ = 1, 30 do
        if T.freeSlots() == 0 or not suckDir(d) then break end
    end
    turtle.select(1)
end

-- Dig out the block on side `d` (outside the tunnel) and put a chest there.
-- True once a chest is really there: placing a chest where a minecart
-- stands only right-clicks the minecart, which turtle.place counts as
-- placed.
function placeChest(d, only)
    for _ = 1, 10 do
        local ok, data = look(d)
        if not ok then break end
        if protected(data.name) then return T.isContainer(data.name) end
        if FLUID[data.name] then
            dry(d)
            ok, data = look(d)
            if not ok or FLUID[data.name] then break end
        end
        if not digDir(d) then return false end
    end
    for _ = 1, 3 do
        clearEntities(d)
        if not T.selectItem(function(n) if only then return n == only end return CHEST_ITEMS[n] end) then
            return false
        end
        placeDir(d)
        turtle.select(1)
        if containerOn(sideOf(d)) then filledIn(d); return true end
    end
    return false
end

-- A chest can't be opened with a solid block on top.  The valuables chest
-- is in the wall by the home's bottom row, so clear the block above it,
-- from the tunnel row above the home, drying out any water that lets in.
-- (Not in a tunnel 1 high, or going down: the bulk chest is above the
-- home there.)  The turtle starts and ends at the home, facing the chest.
function roomAboveChest(h, z)
    z = z or h.z                           -- (a grown chest's second half: its own z, the turtle there)
    if h.k == 0 or Y1 < 1 or not inBox({ x = 0, y = 1, z = z }) then return end
    if not go("up") then return end
    T.face(h.face)
    for _ = 1, 10 do                       -- (again while gravel falls into it)
        local ok, data = look(h.face)
        if not ok then break end
        if FLUID[data.name] or waterIn(data) then dry(h.face); break end
        if protected(data.name) or not digDir(h.face) then break end
        local okw, w = look(h.face)        -- the dig let water in
        if okw and FLUID[w.name] then dry(h.face); break end
    end
    go("down")
    T.face(h.face)
end

--------------------------------------------------------------------------
-- Crafting chests and torches
--------------------------------------------------------------------------
-- The wood it mines (mineshafts' planks, trees' logs) travels forward
-- with the supplies.  At the newest home, when chests or torches run low,
-- it crafts the wood into as many chests as it can (two build a home),
-- keeping back the planks for the sticks of the torches that light the
-- segments those chests start, and crafts those torches from coal it can
-- spare.  It needs a crafting table, kept with the supplies; turtlelib's
-- T.craftBatch does the crafting at the home's valuables chest (see
-- craftSupplies).

-- Torches to light one segment.
function torchesPerSegment()
    if not lights then return 0 end
    return torchWalls * math.ceil(SPACING / torchEvery)
end

-- What the home's valuables chest and the turtle hold, by name.
function atHand()
    local n = chestCounts(home.val)
    for s = 1, 16 do
        local it = turtle.getItemDetail(s)
        if it then n[it.name] = (n[it.name] or 0) + it.count end
    end
    return n
end

-- What there is to craft with, and what to make: { logs (to cut into
-- planks), sticks, torches, chests } (crafting steps: 4 planks, 4 sticks,
-- 4 torches or 1 chest each).  Coal for torches is what's left over the
-- fuel to build the next home and get back, and the stock left in homes.
function craftPlan(n)
    local have = { logs = 0, planks = 0, sticks = n[STICK] or 0, chests = 0, torches = 0, coal = 0 }
    for name, c in pairs(n) do
        if isLog(name) then have.logs = have.logs + c
        elseif isPlanks(name) then have.planks = have.planks + c
        elseif CHEST_ITEMS[name] then have.chests = have.chests + c
        elseif TORCHES[name] then have.torches = have.torches + c
        elseif COAL[name] then have.coal = have.coal + c end
    end
    local level = turtle.getFuelLevel()
    local need = 2 * (home.z + SPACING) + T.cfg.fuelMargin + FUEL_WORK
    local reserve = (level == "unlimited" and 0 or math.max(0, math.ceil((need - level) / 80))) + FUEL_STOCK
    local spare = math.max(0, have.coal - reserve)
    local wood = have.planks + 4 * have.logs
    local per = torchesPerSegment()
    for chests = math.floor(wood / 8 / 2) * 2, 0, -2 do
        local homes = math.floor((have.chests + chests) / 2)
        local torches = math.ceil(math.min(math.max(0, homes * per - have.torches), 4 * spare) / 4)
        local sticks = math.ceil(math.max(0, torches - have.sticks) / 4)
        local left = wood - 8 * chests
        if 2 * sticks > left then              -- (only with no chests: fewer torches)
            sticks = math.floor(left / 2)
            torches = math.min(torches, have.sticks + 4 * sticks)
        end
        if 8 * chests + 2 * sticks <= wood then
            local planks = 8 * chests + 2 * sticks
            return { logs = math.max(0, math.ceil((planks - have.planks) / 4)), sticks = sticks,
                     torches = torches, chests = chests }, have
        end
    end
    return { logs = 0, sticks = 0, torches = 0, chests = 0 }, have
end

-- Craft what craftPlan says, at the home's valuables chest, with
-- turtlelib's crafting (T.craftPlan, T.craftBatch): it stashes the
-- inventory in the chest once (the bulk goes down into the bulk chest
-- first, for room), puts the crafting table on (from the chest or the
-- inventory; the chunk controller stays put) and each stack back in its
-- slot after; the chests and torches stay in the chest, with the
-- supplies.  The turtle is at the home, facing it.
warnedTable = false
function craftSupplies()
    if home.val == "front" then T.face(home.face) end
    local n = atHand()
    local plan, have = craftPlan(n)
    if plan.chests + plan.torches == 0 then return end
    local equipped = T.equipped("left") == CRAFTING_TABLE or T.equipped("right") == CRAFTING_TABLE
    if (n[CRAFTING_TABLE] or 0) == 0 and not equipped then
        if not warnedTable then
            warnedTable = true
            print(string.format("There's wood for %d chests, but no crafting table: put one in the start's top chest.",
                plan.chests))
        end
        return
    end
    unload("bulk")                         -- (room in the valuables chest to work in)
    local targets = {}
    if plan.torches > 0 then targets[#targets + 1] = { "minecraft:torch", 4 * plan.torches } end
    if plan.chests > 0 then targets[#targets + 1] = { "minecraft:chest", plan.chests } end
    print(string.format("Crafting %d chests and %d torches at home %d.", plan.chests, 4 * plan.torches, home.k))
    local steps, why = T.craftPlan(targets, { chest = home.val })
    if steps then
        local ok, info
        ok, why, info = T.craftBatch(steps, { chest = home.val, partial = true })
        if ok == nil then print("Not crafting: " .. tostring(why) .. ".") end
    else
        print("Not crafting: " .. tostring(why) .. ".")
    end
    restockKit()                           -- filler, torches and fuel back on board
    local _, now = craftPlan(atHand())
    print(string.format("Crafted %d chests and %d torches.", now.chests - have.chests, now.torches - have.torches))
end

-- Running low: fewer chests than two more homes take, or torches than
-- two segments do (none needed with --no-lights).
function suppliesLow()
    local _, have = craftPlan(atHand())
    return have.chests < 4 or have.torches < 2 * torchesPerSegment()
end

-- The cell of the chest on a home's `side` ("top", "bottom" or "front").
function chestCell(h, side)
    if side == "top" then return h.x, h.y + 1, h.z end
    if side == "bottom" then return h.x, h.y - 1, h.z end
    local v = DELTA[h.face]
    return h.x + v[1], h.y + v[2], h.z + v[3]
end

-- While mine runs, the start's chests and each home's two are protected
-- areas (T.protect), so no other program on the turtle digs them (the
-- wrapped dig refuses).  mine itself never digs a chest.  They are named
-- "mine home K chest" and "mine home K bulk" (the start is home 0), and
-- let go of when it ends, or are replaced when a run that was cut off
-- starts again.
HOME_AREA = "mine home "
function protectHome(h)
    if not guardHomes then return end
    for _, kind in ipairs({ "chest", "bulk" }) do
        local x, y, z = chestCell(h, kind == "chest" and h.val or h.bulk)
        local ok, why = T.protect(HOME_AREA .. h.k .. " " .. kind, x, y, z, x, y, z)
        if not ok and not warnedGuard then
            warnedGuard = true
            print("Not protecting the home chests (" .. tostring(why) .. ").")
        end
    end
    for _, kind in ipairs({ "val", "bulk" }) do        -- a grown chest's second half (see grow)
        local z2 = grown[h.k] and grown[h.k][kind]
        if type(z2) == "number" then
            local x, y = chestCell(h, kind == "val" and h.val or h.bulk)
            T.protect(HOME_AREA .. h.k .. " " .. (kind == "val" and "chest2" or "bulk2"), x, y, z2, x, y, z2)
        end
    end
end

-- Tell the player how the run ended (T.report: where the turtle is, its
-- fuel), if mine.report is on.  A chat box in the start's top chest is
-- taken out for the telling and put back (T.report puts one on for the
-- moment, beside a chunk controller).  Never stops the end of the run.
CHAT_BOX = "advancedperipherals:chat_box"
function tellPlayer(said)
    if not reportEnd then return end
    local atStart = T.pos.x == 0 and T.pos.y == 0 and T.pos.z == 0
    local done, why = T.report.try(said, { from = atStart and "top" or nil })
    if not done then print("Couldn't tell the player (" .. tostring(why) .. ").") end
end

-- Let go of every area of this program's (the ones of an earlier run
-- that was cut off too).
function releaseHomes()
    for _, a in ipairs(T.protections()) do
        if text.startsWith(a.name, HOME_AREA) then T.unprotect(a.name) end
    end
end

-- The segment is done: build the next home at its end and move the
-- supplies there from this one.  The turtle starts and ends at a home.
function advance(tries)
    tries = tries or 0
    local next = homeAt(home.k + 1)
    local exists = next.k <= lastHome  -- going over the tunnel again (resumed from an earlier home)
    if not exists and suppliesLow() then craftSupplies() end
    local plan, have = craftPlan(atHand())
    -- out of chests or fuel: back to the start to wait for more (mine.wait),
    -- then on (again, if what it brought out wasn't enough, up to 3 times)
    if have.chests < 2 and not exists then
        local why = "Out of chests to build the next home (needs 2)."
            .. (plan.chests > 0 and " There's wood for more: put a crafting table in the start's top chest." or "")
        if not waitSupplies or tries >= 3 then stop(why) end
        viaStart("Out of chests to build the next home", { chests = 2 - have.chests })
        return advance(tries + 1)
    end
    -- onto a home that's there already, the supplies (fuel among them) are
    -- there: only the fuel to get there is needed
    local fuelNeed = next.z - home.z + (exists and 0 or 4 * SPACING)
    if not fuelToGoOn(fuelNeed) then
        if not waitSupplies or tries >= 3 then stop("Not enough fuel to build the next home and still get back.") end
        viaStart("Not enough fuel to build the next home", { fuel = fuelNeed })
        return advance(tries + 1)
    end
    inTrip = true                  -- no unloading trips while carrying supplies
    local built = false
    while true do
        local took, more = takeSupplies()
        alongAxis("z", next.z)
        if not built then
            if not (placeChest(next.face) and placeChest(T.sideDir(next.bulk))) then
                stop(string.format("Couldn't build home %d at z=%d.", next.k, next.z))
            end
            built = true
        end
        roomAboveChest(next)               -- (homes built before this get it too)
        T.face(next.face)
        if not leaveSupplies() then
            stop(string.format("Home %d's valuables chest isn't there (z=%d).", next.k, next.z))
        end
        if not more then break end
        if took == 0 then
            print("Can't carry the rest of the supplies (no room); leaving them in home " .. home.k .. ".")
            break
        end
        if not fuelToGoOn(2 * (next.z - home.z) + next.z) then
            print("Not enough fuel to fetch the rest of the supplies; leaving them in home " .. home.k .. ".")
            break
        end
        alongAxis("z", home.z)     -- back for the rest
        T.face(home.face)
    end
    home = next
    protectHome(home)
    if exists then
        print(string.format("On to home %d at z=%d.", home.k, home.z))
    else
        lastHome = home.k
        stats.homes = stats.homes + 1
        saveJob("active")
        clearProgress()
        print(string.format("Built home %d at z=%d.", home.k, home.z))
    end
    refuel()
    restockKit()                   -- the torches went in with the supplies
    inTrip = false
    if not exists and haulEvery > 0 and home.k % haulEvery == 0 then
        viaStart(string.format("Home %d built (hauling every %d homes)", home.k, haulEvery))
    end
end

--------------------------------------------------------------------------
-- Lanes
--------------------------------------------------------------------------
-- Rows a middle column runs lanes in: every third, plus the last, so each
-- row is a lane or next to one and the top and bottom rows are lanes.
function coverRows(n)
    local rows = {}
    for r = 0, n - 2, 3 do rows[#rows + 1] = r end
    if rows[#rows] ~= n - 1 then rows[#rows + 1] = n - 1 end
    return rows
end

-- The side columns: a lane in every row, to look at each wall block from
-- beside it; with a Geo Scanner every third row, as the middle (the walls
-- are seen by the survey's scans once the segment is dug), or `cover`
-- (open water: the walls are shelled already).
function planLanes(cover)
    local xs, xn = T.sgn(WIDTH)
    local ys, yn = T.sgn(HEIGHT)
    local lanes = {}
    for c = 0, xn - 1 do
        local rows
        if (c == 0 or c == xn - 1) and not hasScanner and not cover then
            rows = {}
            for r = 0, yn - 1 do rows[#rows + 1] = r end
        else
            rows = coverRows(yn)
        end
        if c % 2 == 1 then                          -- serpentine through the rows
            local rev = {}
            for i = #rows, 1, -1 do rev[#rev + 1] = rows[i] end
            rows = rev
        end
        for _, r in ipairs(rows) do lanes[#lanes + 1] = { x = c * xs, y = r * ys } end
    end
    return lanes
end

-- At a lane block: clear the tunnel blocks above and below, look at every
-- block outside the tunnel that this one touches, and make sure the floor
-- under it is solid.
laneAt = {}          -- "x,y" of this segment's lanes
function scanHere()
    for _, d in ipairs({ "up", "down" }) do
        local n = neighbour(d)
        if not opened[key(n)] then
            -- a lane block (every block touching the walls, floor or
            -- ceiling is one) is left for when the turtle is in it, so it
            -- can seal what's beyond before fluid gets in
            if inBox(n) then
                if not laneAt[n.x .. "," .. n.y] then clearCell(d) end
            else examine(d) end
        end
        if isFloor(n) then fill(d) end    -- something to walk on
    end
    -- the walls (and the tunnel's end): with a scanner, left to the
    -- survey once the segment is dug; without, turned to and looked at
    if hasScanner then return end
    for _, d in ipairs({ 1, 3, 0 }) do
        local n = neighbour(d)
        if not inBox(n) and not (waterMode and filled[key(n)]) then examine(d) end
    end
end

-- The niche in direction d has nothing to hang a torch on or stand it on
-- (it opens into a cave): step into it, put a bulk block under it, and
-- step back.
function supportNiche(d)
    if not go(d) then return false end
    trail[#trail + 1] = d                  -- out of the tunnel, as in a vein
    local ok, data = look("down")
    local put = false
    if not ok or FLUID[data.name] or SOFT[data.name] then
        if ok and SOFT[data.name] then digDir("down") end
        put = putFiller("down")
    end
    retreat(d)
    trail[#trail] = nil
    return put
end

-- Light the tunnel from here, if this is a floor-level block by a wall
-- and z is where a torch goes: dig a niche in the wall and put a torch
-- in it, against the block behind or on the one below (one put there if
-- there's neither).  No torches, or --no-lights: it just keeps mining.
-- A torch into the niche in direction d (a block put under it first if
-- it has nothing to rest on); filed in torchBy.
function placeTorch(d)
    local function isTorch(n) return TORCHES[n] end
    local placed = T.selectItem(isTorch) and placeDir(d)
    if not placed and supportNiche(d) then placed = T.selectItem(isTorch) and placeDir(d) end
    turtle.select(1)
    if not placed then return false end
    local niche, v = neighbour(d), DELTA[d]
    local t = { at = here(), d = d }
    torchBy[key(niche)] = t
    torchBy[key({ x = niche.x + v[1], y = niche.y, z = niche.z + v[3] })] = t
    torchBy[key({ x = niche.x, y = niche.y - 1, z = niche.z })] = t
    broken[t] = nil
    filledIn(d)
    return true
end

warnedTorch = false
function lightHere()
    if not lights or T.pos.y ~= Y0 or not torchAt(T.pos.z) then return end
    local d
    if T.pos.x == 0 then d = WALL
    elseif torchWalls == 2 and T.pos.x == (WIDTH > 0 and X1 or X0) then d = (WALL + 2) % 4
    else return end
    local wetFront = wetAhead()            -- (before it turns to the niche)
    local function isTorch(n) return TORCHES[n] end
    if T.countItem(isTorch) == 0 then
        if not warnedTorch then
            warnedTorch = true
            if stats.torches == 0 then
                print("No torches: the tunnel isn't being lit (put some in the start's top chest).")
            else
                print(string.format("Out of torches at z=%d: the tunnel is dark from here.", T.pos.z))
            end
        end
        return
    end
    for _ = 1, 10 do                       -- the niche (again while gravel falls into it)
        room()
        local ok, data = look(d)
        if not ok then break end
        if TORCH_BLOCKS[data.name] or protected(data.name) then return end
        if FLUID[data.name] then
            dry(d)
            ok, data = look(d)
            if not ok or FLUID[data.name] then break end
        end
        if not digDir(d) then return end
    end
    -- it came into this block through water: that would wash the torch
    -- away, so stop it first (and leave the torch out if it can't)
    if wetAt == key(T.pos) then
        if not stopFlow(math.max(1, wetLevel or 1)) then
            print("Water's flowing at " .. T.posString() .. "; no torch there for now.")
            unlit[key(T.pos)] = here()     -- (relight comes back once the water's seen to)
            return
        end
        wetAt = nil
        sleep(2)                           -- what's left drains away
    end
    -- lava or water a scan saw next to the niche would get in and put the
    -- torch out: step in and seal it first
    local niche, wet = neighbour(d), false
    for _, v in pairs(DELTA) do
        local m = { x = niche.x + v[1], y = niche.y + v[2], z = niche.z + v[3] }
        if not (m.x == T.pos.x and m.y == T.pos.y and m.z == T.pos.z) and scanSays(m) == "fluid" then wet = true end
    end
    if wet and go(d) then
        eachAround(OPP[d], cutOff)
        retreat(d)
    end
    if wetFront and wetBeside(d) then
        print("Water next to " .. T.posString() .. "; no torch there for now.")
        unlit[key(T.pos)] = here()
        return
    end
    if placeTorch(d) then
        stats.torches = stats.torches + 1
    else
        print("Couldn't place a torch at " .. T.posString() .. "; carrying on.")
    end
end

-- Water beside the turtle's block (above it, or along or across the
-- tunnel; d is the niche): standing there it keeps the water out of its
-- own block, but once it moves on the water flows in, and on into the
-- niche, washing the torch away.  (Fewest turns first: up, the two
-- along the tunnel, then across.)  It's looked for only when there's
-- water in front of the turtle (wetAhead, no turning): turning to look
-- all round at every torch costs more than it's worth in a dry tunnel.
function wetAhead()
    local ok, data = look(T.dir)
    return ok and (FLUID[data.name] or waterIn(data)) or false
end
function wetBeside(d)
    for _, e in ipairs({ "up", (d + 1) % 4, (d + 3) % 4, (d + 2) % 4 }) do
        local ok, data = look(e)
        if ok and (FLUID[data.name] or waterIn(data)) then return true end
    end
    return false
end

-- Put back the torches digging has knocked off or dug up since they were
-- placed, going back along the tunnel to each (in order along it).  A
-- scan's fetch can go through a niche lit before the scan, and a vein
-- through the block a torch rests on.
unlit = {}           -- key -> where lightHere left a torch out for flowing water
function relight()
    local list = {}
    for t in pairs(broken) do list[#list + 1] = t end
    table.sort(list, function(a, b)
        if a.at.z ~= b.at.z then return a.at.z < b.at.z end
        return key(a.at) < key(b.at)
    end)
    for _, t in ipairs(list) do
        broken[t] = nil
        alongAxis("y", t.at.y); alongAxis("x", t.at.x); alongAxis("z", t.at.z)
        if not (T.at(t.at) or blocked[key(t.at)]) then goRound(t.at) end
        local wetFront = wetAhead()
        local ok, data = look(t.d)
        if T.at(t.at) and not (ok and TORCH_BLOCKS[data.name]) then
            if ok and not FLUID[data.name] and not protected(data.name) then digDir(t.d) end
            if wetFront and wetBeside(t.d) then
                unlit[key(T.pos)] = here()     -- (back once the water's seen to)
            elseif placeTorch(t.d) then
                stats.relit = stats.relit + 1
            else
                print("Couldn't put the torch back at " .. T.posString() .. "; carrying on.")
            end
        end
    end
    -- and the torches left out while water flowed there, now it's sealed
    -- off: tried here, and once more at the next relight (the water may
    -- come from the next segment, seen to by then); still wet after that,
    -- it's left for the next run rather than walked back to every time
    local spots = {}
    for _, p in pairs(unlit) do spots[#spots + 1] = p end
    table.sort(spots, function(a, b) return a.z ~= b.z and a.z < b.z or key(a) < key(b) end)
    unlit = {}
    for _, p in ipairs(spots) do
        alongAxis("y", p.y); alongAxis("x", p.x); alongAxis("z", p.z)
        if not (T.at(p) or blocked[key(p)]) then goRound(p) end
        if T.at(p) then lightHere() end
        local again = unlit[key(p)]
        if again then
            if (p.tries or 0) >= 1 then unlit[key(p)] = nil else again.tries = (p.tries or 0) + 1 end
        end
    end
end

--------------------------------------------------------------------------
-- Geo Scanner (Advanced Peripherals), when there's one on board.  A scan
-- lists every block that isn't air within SCAN_RADIUS, at offsets along
-- the world's axes, which the turtle doesn't know: it lines them up with
-- the tunnel by finding the one way round that puts none of them where it
-- knows there's air (what it has dug).  The scans are taken once a
-- segment is dug (see survey): then it knows what's in the walls without
-- turning to look at them, and where ore lies further out, and tunnels
-- out to it, up to SCAN_REACH from the tunnel (diamonds and coal however
-- far, as long as a scan saw them); it goes no further than the scan
-- reached from where it was taken, except to follow a diamond or coal
-- vein to its end.  Low on fuel, it scans as it digs, fetches the coal
-- first, and burns it.
--------------------------------------------------------------------------
warnedScan = false

-- The item name of a Geo Scanner, equipped or in the inventory: nil if there is none.
function scannerItem()
    for _, sd in ipairs({ "left", "right" }) do
        local name = T.equipped(sd)
        if name and isScanner(name) then return name end
    end
    for s = 1, 16 do
        local it = turtle.getItemDetail(s)
        if it and isScanner(it.name) then return it.name end
    end
end

-- Scan with the Geo Scanner, putting it on for the scan if it is in the
-- inventory (T.withPeripheral: it goes on a side without a chunk
-- controller, waits until it shows up as a peripheral, and puts back
-- what was there, even if the scan fails).  Returns the blocks, or nil
-- and why.
function scanBlocks()
    local name = scannerItem()
    if not name then return nil, "no scanner on board" end
    local blocks, err
    local ok, why = T.withPeripheral(name, function(p)
        -- The method is scan in Advanced Peripherals' docs, scanBlocks in
        -- some versions: whichever this one has.
        local method = (p.scanBlocks and "scanBlocks") or (p.scan and "scan")
        if not method then
            local methods = tables.sortedKeys(p, function(a, b) return tostring(a) < tostring(b) end)
            err = string.format("the %s has no scan method (its methods: %s)", name,
                #methods > 0 and text.join(methods, ", ") or "none")
            return
        end
        for _ = 1, 3 do
            local good, a, b = pcall(p[method], SCAN_RADIUS)
            if good then blocks, err = a, b else err = a end
            if blocks then break end
            if err == "Terminated" then error(err, 0) end
            sleep(1)                       -- the scanner's cooldown
        end
    end)
    if not ok then return nil, why end
    turtle.select(1)
    return blocks, err
end

-- A scan's blocks at offsets from the turtle: as they come, or, if they
-- come as world coordinates (any further off than the scan reaches),
-- less the turtle's own (the one turtle in the scan).  nil and why if
-- they can't be made sense of.
function relative(blocks)
    local first = blocks[1]
    if first and not (type(first.x) == "number" and type(first.y) == "number"
            and type(first.z) == "number" and type(first.name) == "string") then
        local keys = tables.sortedKeys(first, function(a, b) return tostring(a) < tostring(b) end)
        return nil, "scan entries aren't {x, y, z, name, tags} (they have: " .. text.join(keys, ", ") .. ")"
    end
    -- whole numbers (they come as 3.0, which "3.0" .. keys wouldn't match),
    -- with the turtle-relative r, u, f (right, up, forward) when given
    local function round(v) return v and math.floor(v + 0.5) end
    local whole = {}
    for _, e in ipairs(blocks) do
        whole[#whole + 1] = { x = round(e.x), y = round(e.y), z = round(e.z), name = e.name, tags = e.tags,
                              r = round(e.r), u = round(e.u), f = round(e.f) }
    end
    blocks = whole
    local far = false
    for _, e in ipairs(blocks) do
        if math.abs(e.x) > SCAN_RADIUS or math.abs(e.y) > SCAN_RADIUS or math.abs(e.z) > SCAN_RADIUS then
            far = true
            break
        end
    end
    if not far then return blocks end
    local me
    for _, e in ipairs(blocks) do
        if text.startsWith(e.name, "computercraft:turtle") then
            if me then return nil, "scan gives world coordinates, and there's more than one turtle in range" end
            me = e
        end
    end
    if not me then return nil, "scan gives world coordinates, and the turtle can't find itself in them" end
    local out = {}
    for _, e in ipairs(blocks) do
        out[#out + 1] = { x = e.x - me.x, y = e.y - me.y, z = e.z - me.z, name = e.name, tags = e.tags,
                          r = e.r, u = e.u, f = e.f }
    end
    return out
end

-- Tags as a set, whichever way round they come.
function tagSet(list)
    local t = {}
    for k, v in pairs(list or {}) do
        if type(k) == "number" then t[v] = true else t[k] = true end
    end
    return t
end

-- Where a scanned block is in the tunnel's coordinates, if the tunnel's
-- +z points along world direction f (its +x is f turned right).
function toTunnel(f, e)
    local rx, rz = -f.z, f.x
    return { x = T.pos.x + e.x * rx + e.z * rz, y = T.pos.y + e.y, z = T.pos.z + e.x * f.x + e.z * f.z }
end

function knownAir(p)
    if filled[key(p)] or blocked[key(p)] then return false end
    return opened[key(p)] or (inBox(p) and p.z <= home.z)
end

-- The one way round the scan fits what's been dug, or nil if it can't
-- tell yet (too little dug, or caves everywhere).
WORLD_DIRS = { { x = 0, z = 1 }, { x = 1, z = 0 }, { x = 0, z = -1 }, { x = -1, z = 0 } }
function lineUp(blocks)
    local best, bestHits, nextHits = nil, math.huge, math.huge
    for _, f in ipairs(WORLD_DIRS) do
        local hits = 0
        for _, e in ipairs(blocks) do
            if (e.x ~= 0 or e.y ~= 0 or e.z ~= 0) and not FLUID[e.name] and knownAir(toTunnel(f, e)) then
                hits = hits + 1
            end
        end
        if hits < bestHits then best, nextHits, bestHits = f, bestHits, hits
        elseif hits < nextHits then nextHits = hits end
    end
    if bestHits <= 1 and nextHits >= bestHits + 4 then return best end
end

-- File a scan: the blocks touching the tunnel's walls, floor and ceiling
-- (absent ones are air), and ore further out for this segment.
scans = 0
function record(blocks, z1, z2, toCell)
    local seen = {}
    scans = scans + 1
    local from = { x = T.pos.x, y = T.pos.y, z = T.pos.z }
    scanFrom[#scanFrom + 1] = from
    for _, e in ipairs(blocks) do
        local p = toCell(e)
        local k = key(p)
        seen[k] = true
        local data = { name = e.name, tags = tagSet(e.tags), state = e.state }
        local kind = isTarget(data) and "ore" or (leaky(data) and "fluid") or "rock"
        if kind ~= "rock" then scanned[k] = kind end
        local out = outside(p)
        if out == 1 then known[k] = kind end
        local zTop = z2 == LENGTH and z2 + SCAN_REACH or z2
        if kind == "ore" and out >= 1 and p.z >= z1 and p.z <= zTop and not opened[k]
                and (inReach(p) or goesFar(e.name)) then
            targets[k] = { x = p.x, y = p.y, z = p.z, coal = text.contains(e.name, "coal"),
                           from = from, scan = scans }
        end
    end
    -- the blocks touching the tunnel that the scan saw no block in: air
    local function air(x, y, z)
        if math.abs(x - T.pos.x) > SCAN_RADIUS or math.abs(y - T.pos.y) > SCAN_RADIUS then return end
        local k = key({ x = x, y = y, z = z })
        if not seen[k] then known[k] = "air" end
    end
    for z = math.max(z1, T.pos.z - SCAN_RADIUS), math.min(z2, T.pos.z + SCAN_RADIUS) do
        for y = Y0, Y1 do air(X0 - 1, y, z); air(X1 + 1, y, z) end
        for x = X0, X1 do air(x, Y0 - 1, z); air(x, Y1 + 1, z) end
    end
end

function fuelLow() return not T.hasFuel(home.z + fuelGoal / 2) end

-- Fetch ore found by the scanner, `which` picking it (nil: all, which
-- mops up any a stop for room or fuel left).  It goes from each deposit
-- to the nearest one left (coal first when fuel is low), by whichever is
-- shorter: back part of the way it came and digging on from there, or
-- back to the tunnel and along it (through what's dug, or dug now: it's
-- tunnel) to the block nearest it.  Ore met on the way is mined too;
-- lava and water are sealed; floor it dug through is filled on the way
-- back.  It gives up on what it can't dig to, and ends where it started.
function fetchTargets(which)
    local list = {}
    for _, t in pairs(targets) do
        if not opened[key(t)] and (not which or which(t)) then list[#list + 1] = t end
    end
    if #list == 0 then return end
    table.sort(list, function(a, b) return key(a) < key(b) end)   -- ties the same every run
    local start, base = here(), #trail
    -- where it has been since leaving the tunnel: way[i] after trail[base + i]
    local way = { [0] = start }
    local function out() return #trail - base end
    local function stepBack()
        local d, from = trail[#trail], here()
        retreat(d)
        trail[#trail] = nil
        way[out() + 1] = nil
        sealBehind(d)
        if isFloor(from) then fill(d) end
    end
    local function nearest(t)
        return { x = math.max(X0, math.min(X1, t.x)), y = math.max(Y0, math.min(Y1, t.y)),
                 z = math.max(1, math.min(segEnd, t.z)) }
    end
    -- the cheapest way to t, as how far back along the way to go first (0:
    -- to the tunnel, and along it); digging costs twice a step through
    -- what's dug
    local function plan(t)
        local q = nearest(t)
        local cost, at = out() + dist(way[0], q) + 2 * dist(q, t), 0
        for i = 1, out() do
            local c = out() - i + 2 * dist(way[i], t)
            if c < cost then cost, at = c, i end
        end
        return cost, at
    end
    local left = {}
    for _, t in ipairs(list) do left[#left + 1] = t end
    while true do
        local coal = fuelLow()
        local pick, pickCost, pickAt
        for i, t in ipairs(left) do
            if not opened[key(t)] then
                local c, at = plan(t)
                if coal and t.coal then c = c - 1000 end
                if not pick or c < pickCost then pick, pickCost, pickAt = i, c, at end
            end
        end
        if not pick then break end
        local t = table.remove(left, pick)
        while out() > pickAt do stepBack() end
        if pickAt == 0 then
            local q = nearest(t)
            alongAxis("z", q.z); alongAxis("x", q.x); alongAxis("y", q.y)
            way = { [0] = here() }
        end
        bound = t.from
        local ore = stats.ore
        for _ = 1, 3 * SCAN_RADIUS do
            if opened[key(t)] then break end
            if dist(T.pos, t) <= 1 then
                local ok, data = look(dirTo(t))
                if ok and isTarget(data) then mineVein(dirTo(t)) end
                break
            end
            local d = stepToward(t)
            local ok, data = look(d)
            if ok and isTarget(data) then mineVein(d)
            elseif ok and FLUID[data.name] and not seal(d) then break end
            if not go(d) then break end
            trail[#trail + 1] = d
            way[out()] = here()
            eachAround(OPP[d], function(e)
                if scanSays(neighbour(e)) == "fluid" then cutOff(e) end
            end)
        end
        bound = nil
        if stats.ore > ore then stats.fetched = stats.fetched + 1 end
        if t.coal and fuelLow() then T.refuelTo(home.z + fuelGoal) end
    end
    while out() > 0 do stepBack() end
    for _, t in ipairs(list) do targets[key(t)] = nil end
    relight()
    alongAxis("y", start.y); alongAxis("x", start.x); alongAxis("z", start.z)
    if not T.at(start) then goRound(start) end
end

-- Put a scan in the map (T.mergeScan), so a later run, `--resume` and
-- other programs know what it saw.  The map is a convenience: if it
-- won't take the scan, say so once and carry on mining.
warnedMap = false
function mapScan(blocks)
    if not keepMap then return end
    local ok, done, why = pcall(T.mergeScan, blocks, SCAN_RADIUS)
    if not ok and done == "Terminated" then error(done, 0) end
    if ok and done then return end
    if not warnedMap then
        warnedMap = true
        print("Map: not keeping the scans (" .. tostring(ok and why or done) .. ").")
    end
end

-- Scan from here (a block of the segment) and file what it finds: true
-- if it did.
function takeScan(z1, z2)
    local blocks, err = scanBlocks()
    if blocks then blocks, err = relative(blocks) end
    if not blocks then
        if not warnedScan then
            warnedScan = true
            print("Geo scanner: " .. tostring(err) .. "; checking the walls by hand until it works.")
        end
        return false
    end
    if warnedScan then
        warnedScan = false
        print("Geo scanner working again.")
    end
    local toCell
    if blocks[1] and blocks[1].f and blocks[1].r and blocks[1].u then
        -- right, up, forward from the turtle (Advanced Peripherals 0.8):
        -- straight into tunnel coordinates by its heading.  If that puts
        -- blocks where it knows it has dug, and some other heading would
        -- fit far better, its heading is off: skip it.  (A few blocks
        -- where it dug are no sign: gravel falls, and water and lava,
        -- which don't count, flow in.)
        local function cellsFor(dir)
            local ahead, right = DELTA[dir], DELTA[(dir + 1) % 4]
            return function(e)
                return { x = T.pos.x + e.f * ahead[1] + e.r * right[1], y = T.pos.y + e.u,
                         z = T.pos.z + e.f * ahead[3] + e.r * right[3] }
            end
        end
        local function hitsFor(cell)
            local hits = 0
            for _, e in ipairs(blocks) do
                if (e.r ~= 0 or e.u ~= 0 or e.f ~= 0) and not FLUID[e.name] and knownAir(cell(e)) then
                    hits = hits + 1
                end
            end
            return hits
        end
        toCell = cellsFor(T.dir)
        local hits, other = hitsFor(toCell), math.huge
        if hits >= 4 then
            for k = 1, 3 do other = math.min(other, hitsFor(cellsFor((T.dir + k) % 4))) end
        end
        if hits >= 4 and other * 2 < hits then
            if not warnedScan then
                warnedScan = true
                print("Geo scanner: the scan puts blocks where it has dug, so its heading looks off; skipping scans.")
            end
            return false
        end
        if not facing then
            facing = true
            print("Geo scanner lined up with the tunnel.")
        end
        mapScan(blocks)
    else
        -- world axes only: line them up with the tunnel from what's dug
        if not facing then
            facing = lineUp(blocks)
            if not facing then return false end   -- try again from the next spot
            print("Geo scanner lined up with the tunnel.")
        end
        toCell = function(e) return toTunnel(facing, e) end
    end
    record(blocks, z1, z2, toCell)
    return true
end

-- Tunnel blocks filled to cut water off behind the lanes: dig them out,
-- now what fed them is sealed (nearest first, a few rounds, as digging one
-- out can mean filling another).
function unplug()
    for _ = 1, 4 do
        local list = {}
        for _, q in pairs(plugs) do list[#list + 1] = q end
        if #list == 0 then break end
        table.sort(list, function(a, b)
            local da, db = dist(a, T.pos), dist(b, T.pos)
            if da ~= db then return da < db end
            return key(a) < key(b)             -- ties the same every run
        end)
        for _, q in ipairs(list) do
            if plugs[key(q)] then
                alongAxis("z", q.z); alongAxis("x", q.x); alongAxis("y", q.y)
                plugs[key(q)] = nil
            end
        end
    end
    plugs = {}
end

-- Go over part of the tunnel dug before, from the home, for water getting
-- in: in one straight walk along the middle of the floor (one walk for
-- every SPREAD_COLS columns, in a tunnel wider than that), checking the
-- floor under it too.  Water getting in from anywhere (walls, ceiling,
-- floor) ends up on the floor and spreads across it, up to 7 blocks on the
-- flat and on down any slope, so it reaches the middle (if the middle
-- column's floor isn't dug yet, the nearest one that is).  Water it
-- finds is getting in, so it follows it to where it comes in and seals
-- that (see dry).  Then it goes over the stretch round where it found
-- water (as far as water spreads either side) more closely: along the
-- floor of the middle of every three columns, tracing it afresh, till
-- that's dry (twice at most), rather than the whole length again.  Only if it's
-- still wet there (it couldn't follow the water to where it gets in:
-- coming in high up, or by many ways) does it look at every side of the
-- tunnel there (sweep).  Where it met water and the floor lane's floor
-- had a hole or a patch (a hole filled before, a bridge), it goes along
-- the other columns' floor there too.  With
-- lights, the closer walk goes along the floor by the lit wall (both, in
-- a tunnel lit from both) instead of that group's middle, and every torch
-- missing there (the water washes them off) is put back (or put in, where
-- there never was one).  Nothing else is looked at again.  `done` picks the lanes dug before
-- (nil: all); `aheadDug`: the tunnel past z2 is dug, and gone over after
-- (water from there is left to that).  It ends at `home`.
WET_REACH = 8        -- how far either side of where it found water it looks again
SPREAD_COLS = 13     -- columns one floor walk covers: water getting in through a wall
                     -- spreads 7 blocks, to 6 columns either side of the walk's
function repair(z1, z2, done, aheadDug)
    local lanes = planLanes()
    repairing = true
    repairRange, fromOutside = { z1 = z1, z2 = z2, aheadDug = aheadDug }, false
    sealedZ = {}
    local marks = {}                       -- z where the floor lane found a hole, or a patch
    local wetZ = {}                        -- z where it waded into water
    local wetAll = {}                      -- (all of them, every walk)
    -- the stretches round the given z (pad either side; near ones joined)
    local function spansOf(zs, pad)
        table.sort(zs)
        local spans = {}
        for _, z in ipairs(zs) do
            local lo, hi = math.max(z1, z - pad), math.min(z2, z + pad)
            local sp = spans[#spans]
            if lo > hi then                -- (out of this part's reach)
            elseif sp and lo <= sp.hi + 1 then sp.hi = math.max(sp.hi, hi) else spans[#spans + 1] = { lo = lo, hi = hi } end
        end
        return spans
    end
    -- along the picked lanes, over the given stretches (nil: z1..z2)
    local function walk(pick, spans)
        for _, sp in ipairs(spans or { { lo = z1, hi = z2 } }) do
            -- (starting from the end it's nearer)
            local n = math.abs(T.pos.z - sp.hi) < math.abs(T.pos.z - sp.lo) and 1 or 0
            for i, lane in ipairs(lanes) do
                if (not done or done(i)) and pick(lane) then
                    local from, to = sp.lo, sp.hi
                    if n % 2 == 1 then from, to = sp.hi, sp.lo end
                    n = n + 1
                    alongAxis("z", from); alongAxis("x", lane.x); alongAxis("y", lane.y)
                    local dz = to >= from and 1 or -1
                    for z = from, to, dz do
                      if T.at({ x = lane.x, y = lane.y, z = z }) then   -- (what it went round skipped)
                        if isFloor(neighbour("down")) then         -- the floor too (no turning)
                            local filled0 = stats.filled
                            local ok, b = look("down")
                            fill("down")
                            -- (a patch it put there itself this time isn't one from before)
                            local patch = ok and PATCH[b.name] and not filled[key(neighbour("down"))]
                            if stats.filled > filled0 or patch then marks[#marks + 1] = z end
                        end
                        lightHere()
                        if z ~= to then
                            local wet0 = stats.wet
                            onAlong(dz > 0 and 0 or 2, to)
                            if stats.wet > wet0 then
                                wetZ[#wetZ + 1] = T.pos.z
                                wetAll[#wetAll + 1] = T.pos.z
                            end
                        end
                      end
                    end
                end
            end
        end
    end
    local xs, xn = T.sgn(WIDTH)
    local floorDug = {}                    -- x of the columns whose bottom lane is dug
    for i, lane in ipairs(lanes) do
        if lane.y == Y0 and (not done or done(i)) then floorDug[lane.x] = true end
    end
    local middle = {}
    for g = 0, xn - 1, 3 do                -- each three columns: the middle, else a side
        local order = { g + 1, g, g + 2 }
        if lights and g == 0 then order = { 0, 1, 2 }                -- the wall torches are on
        elseif lights and torchWalls == 2 and g + 2 >= xn - 1 then  -- and the far wall's
            order = { xn - 1, g + 1, g }
        end
        for _, c in ipairs(order) do
            if c <= xn - 1 and floorDug[c * xs] then middle[c * xs] = true; break end
        end
    end
    local function first(lane) return lane.y == Y0 and middle[lane.x] end
    -- the straight walk: the dug floor column nearest the middle of each
    -- SPREAD_COLS (the nearer the home's side, of two)
    local centre, same = {}, true
    for g = 0, xn - 1, SPREAD_COLS do
        local hi = math.min(g + SPREAD_COLS, xn) - 1
        local mid, best = math.floor((g + hi) / 2), nil
        for c = g, hi do
            if floorDug[c * xs] and (not best or math.abs(c - mid) < math.abs(best - mid)) then best = c end
        end
        if best then centre[best * xs] = true end
    end
    for x in pairs(centre) do if not middle[x] then same = false end end
    for x in pairs(middle) do if not centre[x] then same = false end end
    local before, sealed = stats.wet, stats.sealed
    walk(function(lane) return lane.y == Y0 and centre[lane.x] end)
    -- it met water: the stretch round it more closely, and round where
    -- it got in, as far as it spreads (the torches it washed off)
    if stats.wet > before and not same then
        local zs = {}
        for _, z in ipairs(wetZ) do zs[#zs + 1] = z end
        for _, z in ipairs(sealedZ) do zs[#zs + 1] = z end
        walk(first, spansOf(zs, WET_REACH))
    end
    -- found water and sealed where some got in: back over just where it
    -- was, till it's dry, tracing it afresh (what it sealed changes where
    -- the rest comes from).  Sealed nothing: going over it again would
    -- find the same.
    for _ = 1, 2 do
        if stats.wet == before or stats.sealed == sealed then break end
        before, sealed = stats.wet, stats.sealed
        local where = spansOf(wetZ, WET_REACH)
        -- traced afresh from each end of each wet stretch (every block
        -- again would follow the same water to the same place)
        local ends = {}
        for _, sp in ipairs(spansOf(wetZ, 0)) do ends[sp.lo], ends[sp.hi] = true, true end
        for k in pairs(unfed) do
            local _, _, z = T.keyPos(k)
            if ends[z] then unfed[k] = nil end
        end
        wetZ = {}
        walk(first, where)
    end
    -- still wet there: it couldn't follow all the water to where it gets
    -- in: chase it down by looking at every side of the tunnel there
    -- (see sweep); not for water from past the ends, out of its reach
    if stats.wet > before and not fromOutside then
        for _, sp in ipairs(spansOf(wetZ, WET_REACH)) do sweep(sp.lo, sp.hi) end
    end
    -- a hole under the floor lane, or a patch (a hole filled before, a
    -- bridge), where it met water: the floor under the other columns may
    -- be open there too (a crevasse, a cave, water getting in from under
    -- it), so along their bottom lanes there.  Patches where it's dry are
    -- left be: an older run filled where ore was dug out of the floor all
    -- along, and going across for each would cost more than it's worth.
    local near = {}
    for _, z in ipairs(marks) do
        for _, w in ipairs(wetAll) do
            if math.abs(z - w) <= WET_REACH then near[#near + 1] = z; break end
        end
    end
    if #near > 0 then
        walk(function(lane) return lane.y == Y0 and not first(lane) end, spansOf(near, 1))
    end
    unplug()
    repairing, repairRange = false, nil
    relight()                              -- torches left out while water flowed
    tunnelHome()
end

-- Every side of the tunnel from z=lo to hi that's outside it (walls,
-- floor, ceiling), looked at from the tunnel block beside it, and what
-- lets water in sealed (a fluid, a waterlogged or thin block; a hole in
-- the floor filled): along every row of the side columns, and the floor
-- and ceiling rows of the ones between, back and forth.  For water it
-- couldn't follow to where it gets in.
function sweep(lo, hi)
    local xs, xn = T.sgn(WIDTH)
    local cols = {}
    for c = 0, xn - 1 do cols[#cols + 1] = c * xs end
    if math.abs(T.pos.x - cols[#cols]) < math.abs(T.pos.x - cols[1]) then   -- (the nearer side first)
        local rev = {}
        for i = #cols, 1, -1 do rev[#rev + 1] = cols[i] end
        cols = rev
    end
    local back = math.abs(T.pos.z - hi) < math.abs(T.pos.z - lo)
    for _, x in ipairs(cols) do
        local rows = {}
        if x == X0 or x == X1 then
            for y = Y0, Y1 do rows[#rows + 1] = y end
        else
            rows = Y0 == Y1 and { Y0 } or { Y0, Y1 }
        end
        if math.abs(T.pos.y - rows[#rows]) < math.abs(T.pos.y - rows[1]) then
            local rev = {}
            for i = #rows, 1, -1 do rev[#rev + 1] = rows[i] end
            rows = rev
        end
        for _, y in ipairs(rows) do
            local from, to = lo, hi
            if back then from, to = hi, lo end
            back = not back
            alongAxis("z", from); alongAxis("x", x); alongAxis("y", y)
            local dz = to >= from and 1 or -1
            for z = from, to, dz do
              if T.at({ x = x, y = y, z = z }) then           -- (what it went round skipped)
                for _, e in ipairs({ "up", "down", 0, 1, 2, 3 }) do
                    local m = neighbour(e)
                    if not inBox(m) then
                        local ok, data = look(e)
                        if isFloor(m) then
                            if not (ok and not leaky(data)) then fill(e) end
                        elseif ok and leaky(data) and not TORCH_BLOCKS[data.name] then
                            seal(e)
                        end
                    end
                end
                if z ~= to then onAlong(dz > 0 and 0 or 2, to) end
              end
            end
        end
    end
end

-- Go over a segment dug already (resumed from an earlier home than the
-- last), fixing where water gets in.
function repairSegment(z1, z2, aheadDug)
    print(string.format("Going over z=%d..%d (dug already) for water getting in.", z1, z2))
    repair(z1, z2, nil, aheadDug)
    reportHoles()
end

--------------------------------------------------------------------------
-- Open water (ADR-0022)
--------------------------------------------------------------------------
-- Dug a block at a time (dry, stopFlow), wet ground lets water in only in
-- small packets, but in a body of it (an ocean, a lake, an aquifer, a
-- segment that flooded) nearly every block is wet, and the turtle spends
-- its time turning to look round each one.  There it works another way,
-- from the open side of the stretch (the home, or the part it has dug
-- dry), a chunk of it at a time (as long as the bulk blocks it carries
-- will fill):
--  1. the shell: up and down each wall's column, facing the wall, a bulk
--     block put into every row of the wall that water may touch (two
--     turns a block along the tunnel, whatever its height);
--  2. the fill: lanes along the tunnel, one row in three, from the open
--     side to the chunk's end and back.  Going, it puts a block under the
--     bottom row (the floor) and over the top one (the ceiling); coming
--     back (backing up, so no turning), a block above, below and ahead of
--     it, so the chunk ends up solid, and the slice past it too: the cap
--     that keeps the water off what it digs.  At the end of the segment,
--     the cap goes past it, where there's water there: the end cap,
--     which the next segment starts from (in this mode);
--  3. the dig: the chunk's lanes dug out as ever, dry, the blocks it put
--     coming back to it.
-- Nothing is looked at first: a block put against rock just isn't put.
-- Only the rows and sides that may have water are shelled and filled: a
-- scan says, or a look; what neither has seen counts as wet.  It starts
-- where the segment before left an end cap, and:
--  - with a Geo Scanner: where a scan from the home shows a third of the
--    segment's sides in fluid, or WATER_SOURCES water or lava sources
--    turn up in the tunnel within WATER_SPAN blocks;
--  - without one: where the water it has been next to, counted by
--    column of the tunnel's cross-section (see noteWater), reaches
--    WATER_COLUMNS within WATER_SPAN blocks.  It probes first (see
--    probeWater): PROBE_LEN blocks of the top row and the side columns
--    from the water's edge on, dug as ever, counting the water it meets
--    there.  More than half water (BULKHEAD_SHARE), and it's open water;
--    else it tunnels on as ever, sealing as it goes.
-- While a segment is worked so, and the tunnel ahead is more than half
-- water (BULKHEAD_SHARE: a scan or the probe says, see waterAhead), a
-- bulkhead (a wall across the tunnel just behind the home) keeps what
-- water gets past off the tunnel behind: what goes through it closes it
-- again behind itself (see go), and it comes down once the segment is
-- dry.  Where less of it is water (a lake bed along one side), the shell
-- and the fill keep it out, and a bulkhead would be time spent for
-- nothing.
WATER_SOURCES = 6    -- (with a scanner) sources met within...
WATER_SPAN = 4       -- ...this many blocks of each other: open water
-- (without one) the water it has been next to, by column: a source 1,
-- flowing water a quarter; within WATER_SPAN blocks, this much and it
-- probes.  A lone source it fills is one column, and a lane along a wet
-- floor or wall meets one or two; a source with water beside it (a body
-- of water) has the turtle step in and seal round it, which shows it
-- the source's own column and the four round it: 5 at its first wet
-- block.  4 takes a body of water, or four sources in four columns close
-- together.
WATER_COLUMNS = 4
FLOWING_WEIGHT = 1 / 4
PROBE_LEN = 4        -- blocks of each probe lane, from the water's edge on
WATER_SHARE = 1 / 3  -- (a scan from the home) share of the segment's sides in fluid: open water
BULKHEAD_SHARE = 1 / 2   -- more than this share of the tunnel ahead water: a bulkhead behind the home
FILLER_KEEP_WATER = 6 * 64   -- bulk blocks carried while it works in open water
WATER_FILE = T.dataPath("mine.water")
sourcesMet = {}      -- z of the sources it has met in the tunnel this segment
waterCols = {}       -- "x,y" -> { [z] = weight }: the water it has been next to this segment, by column
probing = nil        -- while it probes: { a, b (the stretch), cells = { key -> weight } }
probed = nil         -- the last probe this segment: { a, b (the stretch), share, met (blocks) }
probedZ = {}         -- { a, b } of each stretch probed this segment (the water there is counted)
seenOut = {}         -- key -> true (wet) or false: blocks outside the tunnel looked at this segment
waterMode = false    -- working a stretch in open water
wetTo = nil          -- (a chunk's fill) the furthest z it went into water
bulkheadZ = nil      -- z of the bulkhead across the tunnel, while there is one
capZ = nil           -- z of the end cap the last segment left, while it's there

-- "bulkhead z" and "cap z", a line each, so --resume knows them.
function saveWater()
    local lines = {}
    if bulkheadZ then lines[#lines + 1] = "bulkhead " .. bulkheadZ end
    if capZ then lines[#lines + 1] = "cap " .. capZ end
    if #lines == 0 then
        if fs.exists(WATER_FILE) then fs.delete(WATER_FILE) end
    else
        fileio.write(WATER_FILE, table.concat(lines, "\n") .. "\n")
    end
end

function loadWater()
    bulkheadZ, capZ = nil, nil
    local saved = fileio.read(WATER_FILE)
    for _, line in ipairs(saved and text.lines(saved) or {}) do
        local w = text.words(line)
        if scan.isInteger(w[2] or "") then
            if w[1] == "bulkhead" then bulkheadZ = tonumber(w[2])
            elseif w[1] == "cap" then capZ = tonumber(w[2]) end
        end
    end
end

-- Every look is noted: is water there?  (Outside the tunnel, in seenOut;
-- and how wet, by column, see noteWater.)
rawLook = look
function look(d)
    local ok, data = rawLook(d)
    local n = neighbour(d)
    local wet = ok and (FLUID[data.name] or waterIn(data)) and true or false
    if not inBox(n) then seenOut[key(n)] = wet end
    noteWater(n, wet and (isSource(data) and 1 or FLOWING_WEIGHT) or 0)
    return ok, data
end

-- A look at p found water or lava of weight w there (1 a source, a
-- quarter flowing, 0 none).  Probing, every block it looks at in the
-- stretch counts (see probeWater).  Else, digging the segment (not on a
-- trip, nor going over tunnel dug before), water goes in waterCols under
-- its column: one column counts its most, however often it's met there.
-- What it meets in a stretch it has probed is counted already.
function noteWater(p, w)
    if tracing then return end             -- (water outside, followed to its source: not the tunnel's)
    if probing and p.z >= probing.a and p.z <= probing.b then
        probing.cells[key(p)] = math.max(probing.cells[key(p)] or 0, w)
    end
    if w == 0 or probing or waterMode or inTrip or repairing then return end
    for _, s in ipairs(probedZ) do
        if p.z >= s[1] and p.z <= s[2] then return end
    end
    local c = p.x .. "," .. p.y
    waterCols[c] = waterCols[c] or {}
    waterCols[c][p.z] = math.max(waterCols[c][p.z] or 0, w)
end

-- The water by column within WATER_SPAN blocks of z (see noteWater), and
-- where it starts: the first z of a source there (what flows out of it
-- may come back a block or two), else of any of it.
function columnsAt(z)
    local sum, edge, flows = 0, nil, nil
    for _, c in pairs(waterCols) do
        local most = 0
        for wz, w in pairs(c) do
            if math.abs(wz - z) <= WATER_SPAN then
                most = math.max(most, w)
                if w >= 1 then edge = math.min(edge or wz, wz) else flows = math.min(flows or wz, wz) end
            end
        end
        sum = sum + most
    end
    return sum, edge or flows
end

-- A source of water or lava met at p (filled, or cut off).
function noteSource(p)
    if inBox(p) then sourcesMet[#sourcesMet + 1] = p.z end
end

-- Has it met enough water round z to call it open water (or, without a
-- scanner, to probe)?
function openWaterAt(z)
    if waterMode then return false end
    if not hasScanner then return columnsAt(z) >= WATER_COLUMNS end
    local n = 0
    for _, s in ipairs(sourcesMet) do
        if math.abs(s - z) <= WATER_SPAN then n = n + 1 end
    end
    return n >= WATER_SOURCES
end

-- The probe (no scanner), once water's met round z: how much of the
-- tunnel there is water?  From the water's edge, PROBE_LEN blocks along
-- the tunnel's top row (its middle and corners) and its side columns
-- (half way up), dug as the lanes dig them (water dried, filled or
-- sealed as it's met, the walls looked at), so the blocks it digs are
-- the tunnel's own, and the lanes go through them later.  It counts the
-- blocks it looks at there, in the tunnel and round it, by noteWater's
-- weights: the share is their water over how many there are.  It goes
-- and comes back the way it went (in trail, as in a vein: a trip home
-- meanwhile goes that way too), so the only way from the water to the
-- tunnel behind is the one it has sealed as it went; and back in lane i
-- (of lanes), where it met the water, it prints what it found and
-- whether it's open water: true if it is (more than half).  A stop
-- meanwhile is safe: the lane's progress is as saved before, and a
-- --resume counts and probes again from there.
function probeWater(z, za, z2, lanes, i)
    local _, edge = columnsAt(z)
    local a = math.max(za, math.min(edge or z, z2))
    local b = math.min(a + PROBE_LEN - 1, z2)
    local ymid = Y0 + math.floor((Y1 - Y0) / 2)
    local xmid = X0 + math.floor((X1 - X0) / 2)
    local want, seen = {}, {}
    for _, p in ipairs({ { X0, ymid }, { X0, Y1 }, { xmid, Y1 }, { X1, Y1 }, { X1, ymid } }) do
        local c = p[1] .. "," .. p[2]
        if laneAt[c] and not seen[c] then
            seen[c] = true
            want[#want + 1] = { x = p[1], y = p[2] }
        end
    end
    via = i % 2 == 0 and lanes[i - 1] or nil   -- (the way home from lane i, as digLanes has it)
    -- the bulk blocks to seal round every block of it first (wet ground:
    -- it carries more from now on, as dry does), so it isn't short half
    -- way, with water it can't seal behind it
    local function isFiller(n) return FILLER[n] end
    local need = 5 * PROBE_LEN * #want
    fillerKeep = math.max(fillerKeep, FILLER_KEEP_WET, need)
    if T.countItem(isFiller) < need then
        fillerWant = need
        trip("Short of bulk blocks to probe the water")
        fillerWant = nil
    end
    probing = { a = a, b = b, cells = {} }
    local base = #trail
    local function step(d)
        if not go(d) then return false end
        trail[#trail + 1] = d
        return true
    end
    local function to(axis, v)                 -- (as alongAxis, a step at a time)
        while T.pos[axis] ~= v do
            local up = T.pos[axis] < v
            local d = axis == "y" and (up and "up" or "down") or axis == "x" and (up and 1 or 3) or (up and 0 or 2)
            if not step(d) then return false end
        end
        return true
    end
    for j, lane in ipairs(want) do
        local ahead = j % 2 == 1
        local first, last = ahead and a or b, ahead and b or a
        if to("y", lane.y) and to("x", lane.x) and to("z", first) then
            scanHere()
            while T.pos.z ~= last and to("z", T.pos.z + (ahead and 1 or -1)) do scanHere() end
        end
    end
    for k = #trail, base + 1, -1 do            -- back the way it came, to lane i
        retreat(trail[k])
        trail[k] = nil
    end
    local wet, met = 0, 0
    for _, w in pairs(probing.cells) do
        wet, met = wet + w, met + 1
    end
    probing = nil
    probedZ[#probedZ + 1] = { a, b }
    waterCols = {}                         -- (counted afresh from here)
    local share = met > 0 and wet / met or 0
    probed = { a = a, b = b, share = share, met = met }
    local pct = math.floor(share * 100 + 0.5)
    if share > BULKHEAD_SHARE then
        print(string.format("Water at z=%d: the probe met %d%% (over half): working it as open water.", a, pct))
        return true
    end
    print(string.format("Water at z=%d: the probe met %d%% (under half): tunnelling on, sealing as it goes.", a, pct))
    return false
end

-- How much of the tunnel ahead, from z = a on, is water: a share (0 to 1)
-- and how it knows, or nil and why.  With scans covering at least half of
-- its first SCAN_RADIUS slices: the share of the cells they cover that
-- hold fluid.  Without them, the probe's share (see probeWater).  A
-- segment that starts at an end cap is taken as under water (the one
-- before ended so).
function waterAhead(a, b)
    local fluid, seen, cells = 0, 0, 0
    for z = a, math.min(b, a + SCAN_RADIUS - 1) do
        for x = X0, X1 do
            for y = Y0, Y1 do
                cells = cells + 1
                local said = scanSays({ x = x, y = y, z = z })
                if said then
                    seen = seen + 1
                    if said == "fluid" then fluid = fluid + 1 end
                end
            end
        end
    end
    if seen > 0 and seen * 2 >= cells then
        return fluid / seen, string.format("%d of the %d cells ahead a scan saw are water or lava", fluid, seen)
    end
    if capZ == a then return 1, "the segment before ended under water (its end cap)" end
    if probed then
        return probed.share, string.format("the probe met %d%% water (in the %d blocks it looked at, z=%d..%d)",
            math.floor(probed.share * 100 + 0.5), probed.met, probed.a, probed.b)
    end
    return nil, "nothing says how much of it is water"
end

-- May there be water or lava at p, as far as it knows?  (A scan or a
-- look says; a block of the tunnel it has dug, no; one neither has seen,
-- yes.)
function mayBeWet(p)
    local s = scanSays(p)
    if s then return s == "fluid" end
    if inBox(p) then return not opened[key(p)] end
    local seen = seenOut[key(p)]
    if seen ~= nil then return seen end
    return true
end

-- The direction from column x (X0 or X1) out through the wall beside it.
function wallDir(x)
    local want = x == X0 and -1 or 1
    for _, d in ipairs({ 1, 3 }) do
        if DELTA[d][1] == want then return d end
    end
end

-- What of a..b may have water: { floor, ceiling, lo, hi (the tunnel's
-- rows to fill), walls = { { x, d, lo, hi } } (the rows of each wall to
-- shell) }, a row either side of what's wet; nil if none of it.  allWet:
-- all of it (a flooded stretch dug before).
function waterPlan(a, b, allWet)
    local function wet(p) return allWet or mayBeWet(p) end
    local plan, walls = { floor = false, ceiling = false, walls = {} }, {}
    local function row(y) plan.lo, plan.hi = math.min(plan.lo or y, y), math.max(plan.hi or y, y) end
    for z = a, b do
        for x = X0, X1 do
            if wet({ x = x, y = Y0 - 1, z = z }) then plan.floor = true; row(Y0) end
            if wet({ x = x, y = Y1 + 1, z = z }) then plan.ceiling = true; row(Y1) end
            for y = Y0, Y1 do
                if wet({ x = x, y = y, z = z }) then row(y) end
            end
        end
        for _, x in ipairs(X0 == X1 and { X0 } or { X0, X1 }) do
            for _, d in ipairs(X0 == X1 and { 1, 3 } or { wallDir(x) }) do
                for y = Y0, Y1 do
                    if wet({ x = x + DELTA[d][1], y = y, z = z }) then
                        local k = x .. "," .. d
                        walls[k] = walls[k] or { x = x, d = d }
                        walls[k].lo, walls[k].hi = math.min(walls[k].lo or y, y), math.max(walls[k].hi or y, y)
                        row(y)
                    end
                end
            end
        end
    end
    if not plan.lo then return nil end
    plan.lo, plan.hi = math.max(Y0, plan.lo - 1), math.min(Y1, plan.hi + 1)
    for _, k in ipairs(tables.sortedKeys(walls)) do
        local w = walls[k]
        w.lo, w.hi = math.max(Y0, w.lo - 1), math.min(Y1, w.hi + 1)
        plan.walls[#plan.walls + 1] = w
    end
    return plan
end

-- The rows the fill's lanes go along: one in three over lo..hi, the
-- bottom row if the floor's wet, the top if the ceiling is (it shells
-- them from there).
function fillRows(plan)
    local b = plan.floor and Y0 or math.min(plan.lo + 1, plan.hi)
    local t = plan.ceiling and Y1 or math.max(plan.hi - 1, b)
    local rows = { b }
    while t - rows[#rows] > 3 do rows[#rows + 1] = rows[#rows] + 3 end
    if t ~= rows[#rows] then rows[#rows + 1] = t end
    return rows
end

-- One block on in direction d, digging what's there first (not what it
-- leaves standing); water and lava it just goes into.  False if it can't;
-- true and whether it dug its way (rock) or went into fluid (or open
-- tunnel) if it did.
function push(d)
    local n = neighbour(d)
    if blocked[key(n)] then return false end
    local dug = false
    for _ = 1, 10 do
        if moveDir(d) then
            opened[key(T.pos)] = true
            return true, dug
        end
        local ok, data = look(d)
        if ok and not FLUID[data.name] then
            if protected(data.name) then
                standing(n, data.name)
                return false
            end
            digDir(d)
            dug = true
        elseif not ok then
            T.attackDir(d)                 -- (something in the way: a mob)
        end
    end
    return false
end

-- To p, along z first (out of a lane), then y, then x.
function pushTo(p)
    for _, axis in ipairs({ "z", "y", "x" }) do
        while T.pos[axis] ~= p[axis] do
            local d
            if axis == "y" then d = p.y > T.pos.y and "up" or "down"
            else
                for _, e in ipairs({ 0, 1, 2, 3 }) do
                    local v = DELTA[e][axis == "x" and 1 or 3]
                    if v ~= 0 and (v > 0) == (p[axis] > T.pos[axis]) then d = e end
                end
            end
            if not push(d) then return false end
        end
    end
    return true
end

-- A bulk block put in direction d without looking: true if it went in
-- (into water, lava or air), counted.
function put(d, what)
    if putFiller(d) then
        stats[what] = stats[what] + 1
        return true
    end
    return false
end

-- Before a stretch of work: the fuel, room and bulk blocks for it, a trip
-- home first if they're short.  No bulk blocks anywhere: it stops.
function readyFor(moves, blocks)
    local function isFiller(n) return FILLER[n] end
    if not T.hasFuel(T.homeCost() + T.cfg.fuelMargin + moves + 10) then trip("Low on fuel")
    elseif T.freeSlots() < 2 then trip("Inventory nearly full") end
    if T.countItem(isFiller) < blocks then
        fillerWant = blocks
        trip("Out of blocks for the shell")
        fillerWant = nil
        if T.countItem(isFiller) < blocks then
            stop(string.format("Out of bulk blocks for the shell at z=%d (needs %d): put cobblestone (or any bulk"
                .. " block) in the start's bottom chest, then `mine --resume`.", T.pos.z, blocks))
        end
    end
end

-- The bulkhead: a wall across the tunnel just behind the home, from the
-- home's slice, column by column.
function bulkheadUp()
    local z = home.z - 1
    readyFor(4 * math.abs(WIDTH * HEIGHT), math.abs(WIDTH * HEIGHT))
    local up = true
    for x = X0, X1 do
        if not pushTo({ x = x, y = up and Y0 or Y1, z = home.z }) then return end
        T.face(2)
        for y = up and Y0 or Y1, up and Y1 or Y0, up and 1 or -1 do
            if y ~= (up and Y0 or Y1) and not push(up and "up" or "down") then return end
            put(2, "bulkhead")
        end
        up = not up
    end
    bulkheadZ = z
    saveWater()
    print(string.format("Bulkhead across the tunnel at z=%d: the tunnel behind home %d stays dry.", z, home.k))
end

function bulkheadDown()
    if not bulkheadZ then return end
    local up = true
    for x = X0, X1 do
        if not pushTo({ x = x, y = up and Y0 or Y1, z = bulkheadZ + 1 }) then return end
        for y = up and Y0 or Y1, up and Y1 or Y0, up and 1 or -1 do
            if y ~= (up and Y0 or Y1) and not push(up and "up" or "down") then return end
            local ok, data = look(2)
            if ok and FILLER[data.name] then digDir(2) end
        end
        up = not up
    end
    print(string.format("Bulkhead at z=%d taken down: the segment is dry.", bulkheadZ))
    bulkheadZ = nil
    saveWater()
    pushTo({ x = 0, y = 0, z = home.z })
end

-- 1. The walls' shell from a to b: each wall's column, up and down.
function shellWalls(a, b, plan)
    for _, w in ipairs(plan.walls) do
        local rows = w.hi - w.lo + 1
        readyFor(2 * (b - a + 2) * rows, (b - a + 1) * rows)
        if not pushTo({ x = w.x, y = w.lo, z = a - 1 }) then return false end
        local up, dry = true, nil     -- (slices running with rock behind the wall, once it's met water)
        for z = a, b do
            T.face(0)
            if not push(0) then return false end
            T.face(w.d)
            local shelled = false
            for y = up and w.lo or w.hi, up and w.hi or w.lo, up and 1 or -1 do
                if y ~= (up and w.lo or w.hi) and not push(up and "up" or "down") then return false end
                if put(w.d, "shell") then shelled = true end
            end
            up = not up
            -- (rock behind the wall two slices running: the water's ended)
            if shelled then dry = 0 elseif dry then dry = dry + 1 end
            if dry and dry >= 2 then break end
        end
        if not pushTo({ x = w.x, y = T.pos.y, z = a - 1 }) then return false end
    end
    return true
end

-- 2. The fill of a..b (and the slice past it: the cap), lane by lane from
-- the outside in.  last: b is the segment's end, and the end cap goes
-- past it, where there's water.
function fillChunk(a, b, last, plan)
    local rows = fillRows(plan)
    local isRow = {}
    for _, r in ipairs(rows) do isRow[r] = true end
    local lanes = {}
    for x = X0, X1 do
        for _, r in ipairs(rows) do lanes[#lanes + 1] = { x = x, y = r } end
    end
    local function ring(p) return math.min(p.x - X0, X1 - p.x, p.y - Y0, Y1 - p.y) end
    table.sort(lanes, function(p, q)
        if ring(p) ~= ring(q) then return ring(p) < ring(q) end
        if p.x ~= q.x then return p.x < q.x end
        return p.y < q.y
    end)
    local far = last and b or b + 1
    local function capAhead()                  -- (facing along: no turn to look)
        local ok, data = look(0)
        if ok and (FLUID[data.name] or waterIn(data)) then put(0, "cap") end
    end
    for _, l in ipairs(lanes) do
        local up = l.y < Y1 and not isRow[l.y + 1]
        local down = l.y > Y0 and not isRow[l.y - 1]
        readyFor(2 * (far - a + 4), 3 * (far - a + 2))
        if not pushTo({ x = l.x, y = l.y, z = a - 1 }) then return false end
        wetTo = wetTo or a - 1
        T.face(0)
        -- going: along the lane, the floor or ceiling shelled, as far as
        -- there's water (two blocks of rock running: the water's ended,
        -- and the rock past is as good as a fill)
        local rock, stop = nil, far      -- (blocks of rock running, once it's met water)
        for z = a, far do
            local ok, dug = push(0)
            if not ok then return false end
            if l.y == Y0 and plan.floor then put("down", "shell") end
            if l.y == Y1 and plan.ceiling then put("up", "shell") end
            if not dug then rock = 0; wetTo = math.max(wetTo, z) elseif rock then rock = rock + 1 end
            if rock and rock >= 2 then stop = z; break end
        end
        if last and stop == far then               -- the end cap, past the end
            capAhead()
            if up and l.y + 1 <= plan.hi and push("up") then capAhead(); push("down") end
            if down and l.y - 1 >= plan.lo and push("down") then capAhead(); push("up") end
        end
        -- coming back, backing up: above, below and ahead filled
        for _ = stop, a, -1 do
            if up then put("up", "fill") end
            if down then put("down", "fill") end
            if not T.back() then
                if not push(2) then return false end
                T.face(0)
            end
            put(0, "fill")
        end
    end
    return true
end

-- A stretch z1..z2 in open water (see above): from its open side (z1 - 1,
-- the home's slice or dug tunnel), chunk by chunk.  opts.allWet: it's all
-- water (a flooded stretch dug before); opts.bulkhead: a bulkhead behind
-- the home meanwhile; opts.seg: the segment's ends (for scans).  Returns
-- the last z it has dug (short of z2 where the water ended: the rest is
-- dug the usual way), or nil if it couldn't (something in the way it
-- leaves standing).
function openWater(z1, z2, opts)
    opts = opts or {}
    local keep, wasMode = fillerKeep, waterMode
    waterMode = true
    fillerKeep = math.max(fillerKeep, FILLER_KEEP_WATER)
    local seg = opts.seg or { z1, z2 }
    if opts.bulkhead and home.k > 0 and not bulkheadZ then
        local share, how = waterAhead(z1, z2)
        if share and share > BULKHEAD_SHARE then
            bulkheadUp()
        else
            print(string.format("No bulkhead: %s%s.", how,
                share and string.format(" (%d%%: it takes more than half)", math.floor(share * 100 + 0.5)) or ""))
        end
    end
    if capZ and capZ >= z1 and capZ <= z2 then capZ = nil; saveWater() end
    local a, done = z1, true
    local upTo = z1 - 1
    while a <= z2 and done do
        if not pushTo({ x = 0, y = 0, z = a - 1 }) then done = false; break end
        if hasScanner then takeScan(seg[1], seg[2]) end
        local reach = hasScanner and math.min(z2, a + SCAN_RADIUS - 1) or z2
        -- (with a scanner, as far as the scan from here sees: past it, all
        -- would count as wet)
        local plan = waterPlan(a, hasScanner and reach or math.min(z2 + 1, LENGTH), opts.allWet)
        if not plan then break end                 -- (dry from here: dug as ever)
        -- as long a chunk as the blocks it can carry fill: a slice takes
        -- its wet rows, the walls' and the floor and ceiling
        local slice = (plan.hi - plan.lo + 1) * math.abs(WIDTH)
            + (plan.floor and math.abs(WIDTH) or 0) + (plan.ceiling and math.abs(WIDTH) or 0)
        for _, w in ipairs(plan.walls) do slice = slice + w.hi - w.lo + 1 end
        readyFor(0, math.min(math.floor(fillerKeep / 2), slice * (z2 - a + 2)))
        local function isFiller(n) return FILLER[n] end
        local k = math.max(1, math.floor(T.countItem(isFiller) / slice) - 1)
        local b = math.min(a + k - 1, reach)
        local last = b == z2
        print(string.format("Open water at z=%d..%d: rows %d to %d%s%s.", a, b, plan.lo - Y0, plan.hi - Y0,
            plan.floor and ", the floor" or "", plan.ceiling and ", the ceiling" or ""))
        local cap0 = stats.cap
        wetTo = nil
        done = shellWalls(a, b, plan) and fillChunk(a, b, last and b == seg[2], plan)
        if stats.cap > cap0 then capZ = b + 1; saveWater() end
        -- 3. the dig: as ever, dry
        if done then
            local lanes, was = planLanes(true), laneAt
            laneAt = {}
            for _, lane in ipairs(lanes) do laneAt[lane.x .. "," .. lane.y] = true end
            pushTo({ x = lanes[1].x, y = lanes[1].y, z = a - 1 })
            digLanes(lanes, a, b, { seg = seg })
            laneAt = was
            upTo = b
        end
        a = b + 1
        -- (no water met in the chunk's last slice: it's ended)
        if done and (wetTo or 0) < b then break end
    end
    waterMode, fillerKeep = wasMode, keep
    return done and upTo or nil
end

-- The lanes from z1 to z2 (dug, from the open side behind z1).
-- opts.from: how far it got before (resuming); opts.save: progress saved
-- as it goes; opts.watch: open water met (see openWaterAt) stops it, with
-- "water" and the lane and z it got to; opts.seg: the segment's ends (z1,
-- z2 if not given).
function digLanes(lanes, z1, z2, opts)
    local from, seg = opts.from, opts.seg or { z1, z2 }
    local startLane, startZ = from and from.lane or 1, from and from.z
    for i, lane in ipairs(lanes) do
        if i >= startLane then
            local ahead = i % 2 == 1
            local first, to, dz = z1, z2, 1
            if not ahead then first, to, dz = z2, z1, -1 end
            local ok, what = true, nil
            if i == startLane and from and startZ then first = startZ end
            -- (a lane that starts at what's left standing starts past it)
            local function standsAt(z) return blocked[key({ x = lane.x, y = lane.y, z = z })] end
            local wanted = first
            while standsAt(first) and first ~= to do first = first + dz end
            if standsAt(first) then
                -- all of it is left standing: nothing to dig
            elseif first ~= wanted then
                via = i > 1 and lanes[i - 1] or nil
                ok = goRound({ x = lane.x, y = lane.y, z = first })
                what = "no way round what's left standing"
            elseif i == startLane and from then
                -- back out to where it stopped, through what's dug
                via = i > 1 and lanes[i - 1] or nil
                tunnelTo({ x = lane.x, y = lane.y, z = first })
            elseif i == 1 then ok, what = alongAxis("z", z1)
            else
                via = lanes[i - 1]         -- finished: the way home meanwhile
                ok, what = alongAxis("y", lane.y)
                if ok then ok, what = alongAxis("x", lane.x) end
            end
            if ahead then via = nil end    -- this lane is dug back to the segment's start
            for z = first, to, dz do
                if not ok then break end
                -- (past what's left standing in the lane, the blocks it went round are skipped)
                if T.at({ x = lane.x, y = lane.y, z = z }) then
                    if hasScanner and fuelLow() then coalScan(seg[1], seg[2]) end
                    scanHere()
                    if opts.watch and openWaterAt(z) then
                        via = nil
                        return "water", i, z
                    end
                    lightSpawners()        -- (one found above or below)
                    lightHere()
                    if opts.save then saveProgress(i, z) end
                    if z ~= to then ok, what = onAlong(ahead and 0 or 2, to) end
                end
            end
            if not ok then stop(string.format("Can't get through at %s (%s).", T.posString(), tostring(what))) end
        end
    end
    via = nil
    return true
end

-- Do the scans show a share of z1..z2's sides in fluid (WATER_SHARE)?
-- (Only the sides a scan saw count.)
function scansSayWater(z1, z2)
    local seen, wet = 0, 0
    local function side(p)
        local s = scanSays(p)
        if s then
            seen = seen + 1
            if s == "fluid" then wet = wet + 1 end
        end
    end
    for z = z1, z2 do
        for x = X0, X1 do side({ x = x, y = Y0 - 1, z = z }); side({ x = x, y = Y1 + 1, z = z }) end
        for y = Y0, Y1 do side({ x = X0 - 1, y = y, z = z }); side({ x = X1 + 1, y = y, z = z }) end
    end
    return seen >= 8 and wet / seen >= WATER_SHARE
end

-- Mine the segment from z1 to z2, starting and ending at the home.
-- `from`: how far it got before (resuming): its finished lanes are gone
-- over only for water getting in, and it carries on from there.  In open
-- water (see openWater), from the home, a chunk at a time.
laneCount = 0        -- lanes in this segment's plan (saved with the progress)
function mineSegment(z1, z2, from)
    local lanes = planLanes()
    laneCount = #lanes
    laneAt = {}
    for _, lane in ipairs(lanes) do laneAt[lane.x .. "," .. lane.y] = true end
    print(string.format("Segment z=%d..%d from home %d: %d lanes, fuel %s.", z1, z2, home.k, #lanes,
        tostring(turtle.getFuelLevel())))
    known, targets, scanFrom, scanned = {}, {}, {}, {}
    sourcesMet, waterCols, probed, probedZ, seenOut = {}, {}, nil, {}, {}
    local wet0 = stats.wet
    local startLane, startZ = 1, nil
    if from then
        startLane, startZ = from.lane, from.z
        -- what it finished: dug (open), and gone over only for water
        for i, lane in ipairs(lanes) do
            local ahead = i % 2 == 1
            for z = z1, z2 do
                if i < startLane or (i == startLane and (ahead and z <= startZ or not ahead and z >= startZ)) then
                    opened[key({ x = lane.x, y = lane.y, z = z })] = true
                end
            end
        end
        print(string.format("Carrying on with lane %d of %d at z=%d.", math.min(startLane, #lanes), #lanes, startZ))
        repair(z1, z2, function(i) return i < startLane end)
    end
    -- open water from the start (the segment before left an end cap, or
    -- the scans from the home say so), or met on the way: worked from the
    -- home, the other way.  (Not from the start: no open side to work from.)
    local water = false
    if home.k > 0 and not from then
        water = capZ == z1 or (hasScanner and takeScan(z1, z2) and scansSayWater(z1, z1 + SCAN_RADIUS - 1))
    end
    local za = z1
    while true do
        if not water then
            if za > z1 then tunnelTo({ x = lanes[1].x, y = lanes[1].y, z = za - 1 }) end
            -- (without a scanner, water met is probed first: under half
            -- water, it carries on from where it was)
            local at = za == z1 and from or nil
            repeat
                local how, i, z = digLanes(lanes, za, z2, { from = at, save = true, watch = home.k > 0 })
                water, at = how == "water", nil
                if water and not hasScanner and not probeWater(z, za, z2, lanes, i) then
                    water, at = false, { lane = i, z = z }
                end
            until not at
        end
        if not water then break end
        -- open water: from the home (or the end of what it has dug dry)
        saveProgress(1, za)
        if za == z1 then tunnelHome() end
        via = nil
        local upTo = openWater(za, z2, { bulkhead = true, seg = { z1, z2 } })
        if not upTo then                       -- (something in the way: the rest as ever)
            tunnelHome()
            digLanes(lanes, za, z2, {})
            break
        end
        if upTo >= z2 then break end
        za, water, sourcesMet, waterCols = upTo + 1, false, {}, {}
    end
    via = nil
    saveProgress(#lanes + 1, z2)
    unplug()
    if hasScanner then survey(z1, z2) end
    fetchTargets()                         -- the scanner's ore further out
    relight()                              -- what veins knocked off
    -- water got in while it dug (walls aren't looked at till the survey):
    -- go over the floor for any still getting in
    if hasScanner and stats.wet > wet0 then repair(z1, z2) end
    reportHoles()
    tunnelHome()
    bulkheadDown()                         -- (dry now: the tunnel's open again)
end

--------------------------------------------------------------------------
-- The survey (with a Geo Scanner), once a segment is dug
--------------------------------------------------------------------------
-- Spots along one axis to scan from: as few as cover lo..hi with
-- SCAN_RADIUS either side of each (one: in the middle), each within a..b
-- (dug).  `outward`: what reach they have to spare goes beyond lo and hi,
-- half each side, so they see as far past the walls as they can (side
-- to side, up and down); else it stays inside (along the tunnel: past a
-- segment's ends is the next segment's, or the last one's, to scan).
-- Outward across a tunnel wider (or taller) than SCAN_RADIUS + 1, at
-- least two, at its edges: one in the middle would see the whole width
-- of dug-out air, where one at an edge leaves some out and sees that
-- much more rock past its own wall.
function scanSpots(lo, hi, a, b, outward)
    local R, w = SCAN_RADIUS, 2 * SCAN_RADIUS + 1
    local n = math.max(1, math.ceil((hi - lo + 1) / w))
    if outward and b - a + 1 > R + 1 then n = math.max(n, 2) end
    local spare = n * w - (hi - lo + 1)
    local out = {}
    for i = 0, n - 1 do
        local c
        if n == 1 then c = math.floor((lo + hi) / 2)
        elseif outward then c = lo + R - math.floor(spare / 2) + i * w
        else c = lo + R + math.floor(i * (hi - lo - 2 * R) / (n - 1) + 0.5) end
        out[#out + 1] = math.max(a, math.min(b, c))
    end
    return out
end

-- The walls aren't looked at while a segment is dug with a scanner.
-- Once it's dug, scans that cover its walls, floor and ceiling (and the
-- tunnel's end): from the middle of the tunnel while it's no more than
-- SCAN_RADIUS + 1 across and up (anywhere, a scan would hold all of its
-- dug air), from spots round its sides when it's wider or taller (at
-- its corners: a 10x10 scans from all four; none in the middle, that
-- would reach no wall), gone round in a serpentine.  What they show as lava or water,
-- or a waterlogged or thin block, in a wall is sealed or replaced from
-- beside it; a wall block no scan covered (one that failed) is looked at
-- by hand; ore they found is fetched after (fetchTargets).  The floor and
-- ceiling were looked at while digging (from the bottom and top lanes).
surveying = false    -- in survey: through the dug segment, wading water
function survey(z1, z2)
    surveying = true
    local R, last = SCAN_RADIUS, z2 == LENGTH
    local zEnd = last and z2 + 1 or z2
    local xs, ys = scanSpots(X0 - 1, X1 + 1, X0, X1, true), scanSpots(Y0 - 1, Y1 + 1, Y0, Y1, true)
    local spots, rows = {}, 0
    for _, z in ipairs(scanSpots(z1, zEnd, z1, z2)) do
        for _, y in ipairs(ys) do
            -- (back and forth across: each row the way the last one ended)
            local row = {}
            rows = rows + 1
            for i = 1, #xs do row[i] = xs[rows % 2 == 0 and #xs + 1 - i or i] end
            for _, x in ipairs(row) do
                if x - R <= X0 - 1 or x + R >= X1 + 1 or y - R <= Y0 - 1 or y + R >= Y1 + 1
                        or (last and z + R >= zEnd) then
                    spots[#spots + 1] = { x = x, y = y, z = z }
                end
            end
        end
    end
    local cornered = false
    for _, p in ipairs(spots) do
        alongAxis("z", p.z); alongAxis("x", p.x); alongAxis("y", p.y)
        if not takeScan(z1, z2) and not facing and not cornered then
            -- not lined up: a scanner that gives only world coordinates is
            -- lined up from what's dug, and from the middle of a dug tunnel
            -- that looks the same turned round.  From a corner it can't.
            cornered = true
            alongAxis("x", X0); alongAxis("y", Y0)
            if takeScan(z1, z2) then
                alongAxis("x", p.x); alongAxis("y", p.y)
                takeScan(z1, z2)
            end
        end
    end
    if fuelLow() then
        for _, t in pairs(targets) do
            if t.coal then
                print(string.format("Low on fuel (%s): going for the coal the scanner found first.",
                    tostring(turtle.getFuelLevel())))
                break
            end
        end
    end
    -- the wall blocks to see to, from the tunnel block beside each: a
    -- row at a time, back and forth along it
    local rows = {}
    local function want(p, at)
        local k = known[key(p)]
        if opened[key(p)] or (k ~= nil and k ~= "fluid") then return end
        local r = at.x .. "," .. at.y
        if not rows[r] then rows[r] = { x = at.x, y = at.y, list = {} }; rows[#rows + 1] = rows[r] end
        local list = rows[r].list
        list[#list + 1] = { p = p, at = at }
    end
    for _, side in ipairs({ { X0 - 1, X0 }, { X1 + 1, X1 } }) do
        for y = Y0, Y1 do
            for z = z1, z2 do want({ x = side[1], y = y, z = z }, { x = side[2], y = y, z = z }) end
        end
    end
    if last then
        for x = X0, X1 do for y = Y0, Y1 do want({ x = x, y = y, z = zEnd }, { x = x, y = y, z = z2 }) end end
    end
    local back = false
    for _, row in ipairs(rows) do
        table.sort(row.list, function(a, b)
            if a.at.z ~= b.at.z then return (a.at.z < b.at.z) ~= back end
            return key(a.p) < key(b.p)
        end)
        for _, w in ipairs(row.list) do
            alongAxis("z", w.at.z); alongAxis("x", w.at.x); alongAxis("y", w.at.y)
            examine(dirTo(w.p))
        end
        back = not back
    end
    surveying = false
end

-- Low on fuel while digging: scan here (if no scan this segment reached
-- this far along) and go for the coal it shows.
function coalScan(z1, z2)
    for _, o in ipairs(scanFrom) do
        if math.abs(T.pos.z - o.z) <= SCAN_RADIUS then return end
    end
    if not takeScan(z1, z2) then return end
    local this = scans
    for _, t in pairs(targets) do
        if t.coal and t.scan == this then
            print(string.format("Low on fuel (%s): going for the coal the scanner found first.",
                tostring(turtle.getFuelLevel())))
            fetchTargets(function(c) return c.coal and c.scan == this end)
            return
        end
    end
end

--------------------------------------------------------------------------
-- The way back: collect the valuables from every home, most valuable
-- first when there's no room for them all, and leave them at the start.
--------------------------------------------------------------------------
leftBehind = {}      -- home number -> items left in it

-- The lowest-valued valuable carried that's worth less than `than` (bulk
-- never goes in a valuables chest).
function cheapestSlot(than)
    local slot, low
    for s = 1, 16 do
        local it = turtle.getItemDetail(s, true)
        if it and not T.isTool(it.name) and not isSupply(it.name) and not isScanner(it.name)
            and it.name ~= BUCKET and not isBulk(it) then
            local v = value(it.name)
            if v < than and (not low or v < low) then slot, low = s, v end
        end
    end
    return slot
end

-- Leave the bulk the turtle carries in home h's bulk chest: all of it, or
-- all but a stack of filler (for drying out water on the way) when
-- `keepFiller`.  Bulk stays at the home it was mined near; it's never
-- carried back to the start.
function leaveBulk(h, keepFiller)
    if not containerOn(h.bulk) then return end
    local kept = 0
    for s = 1, 16 do
        local it = turtle.getItemDetail(s, true)
        if it and isBulk(it) then
            local keep = 0
            if keepFiller and FILLER[it.name] then
                keep = math.min(it.count, FILLER_KEEP - kept)
                kept = kept + keep
            end
            if it.count > keep then
                turtle.select(s)
                dropSide(h.bulk, it.count - keep)
            end
        end
    end
    turtle.select(1)
end

-- Bulk in home h's valuables chest (put there before bulk was kept out of
-- them) goes down into its bulk chest, while there's room.
function bulkOutOfValuables(h)
    if not (containerOn(h.val) and containerOn(h.bulk)) then return end
    for name, n in pairs(chestCounts(h.val)) do
        if isBulk({ name = name }) and not isSupply(name) then
            for _ = 1, math.ceil(n / 64) do
                if T.freeSlots() == 0 then break end
                local before = T.countItem(name)
                T.restockFrom(h.val, name, before + math.min(64, chestCounts(h.val)[name] or 0), { quiet = true, room = 0 })
                if T.countItem(name) == before then break end
                -- down it goes, what it took and no more (a stack of the
                -- same kept as filler stays on board)
                local function move(to)
                    local left = T.countItem(name) - before
                    for s = 16, 1, -1 do
                        if left <= 0 then break end
                        local it = turtle.getItemDetail(s)
                        if it and it.name == name then
                            turtle.select(s)
                            dropSide(to, math.min(left, it.count))
                            left = left - (it.count - turtle.getItemCount(s))
                        end
                    end
                end
                move(h.bulk)
                if T.countItem(name) > before then           -- the bulk chest is full: back it goes
                    move(h.val)
                    turtle.select(1)
                    return
                end
            end
        end
    end
    turtle.select(1)
end

-- Take the valuables from the valuables chest on `side` (not supplies, not
-- bulk), the most valuable first, swapping cheaper ones carried for them
-- when it's full.  Returns how many valuables are left in it.
function collect(side)
    local counts = chestCounts(side)
    local names = {}
    for name in pairs(counts) do
        if not isSupply(name) and not isBulk({ name = name }) then names[#names + 1] = name end
    end
    table.sort(names, function(a, b)
        if value(a) ~= value(b) then return value(a) > value(b) end
        return a < b
    end)
    for _, name in ipairs(names) do
        while (chestCounts(side)[name] or 0) > 0 do
            if T.freeSlots() == 0 then
                local s = cheapestSlot(value(name))
                if not s then break end
                turtle.select(s)
                if not dropSide(side) then break end   -- swap it for something better
            end
            local before = T.countItem(name)
            T.restockFrom(side, name, before + chestCounts(side)[name], { quiet = true, room = 0 })
            if T.countItem(name) == before then break end
        end
    end
    turtle.select(1)
    local left = 0
    for name, n in pairs(chestCounts(side)) do
        if not isSupply(name) and not isBulk({ name = name }) then left = left + n end
    end
    return left
end

-- From the home the turtle is at, walk back to the start collecting the
-- valuables from every home on the way, and leave them at the start.
-- `keep`: fuel to have in the tank at the start (for the trip back out):
-- short of it, it tops up from each home's chest as it passes, the one it
-- works from first, the fuel stock a home keeps too (noted in `drained`,
-- to put back on the way out: see refillStocks).  The start's top chest
-- is the last resort.  True if it got there and the start's chests took
-- everything.
function walkBackCollecting(keep)
    leftBehind = {}
    print("Walking back to the start, collecting valuables.")
    local was, took = turtle.getFuelLevel(), 0
    for k = home.k, 1, -1 do
        local h = homeAt(k)
        alongAxis("x", 0); alongAxis("y", 0)
        alongAxis("z", h.z)
        if not T.at(h) then goRound(h) end
        T.face(h.face)
        leaveBulk(h, k > 1)                -- (home 1: the last of it; none goes to the start)
        if containerOn("front") then
            bulkOutOfValuables(h)
            if keep and was ~= "unlimited" and not T.hasFuel(h.z + T.cfg.fuelMargin + keep) then
                local before = turtle.getFuelLevel()     -- (before the valuables fill the inventory)
                T.refuelFrom("front", h.z + T.cfg.fuelMargin + keep)
                took = took + turtle.getFuelLevel() - before
                if drained and fuelIn("front") < FUEL_STOCK then drained[k] = true end
            end
            local left = collect("front")
            if left > 0 then leftBehind[k] = left end
            if left == 0 and not hasSupplies(chestCounts("front")) then pickUpGrown(h) end
        end
    end
    if took > 0 then
        print(string.format("Fuel from the homes on the way: %d (fuel %s).", took, tostring(turtle.getFuelLevel())))
    end
    alongAxis("x", 0); alongAxis("y", 0)
    alongAxis("z", 0)
    if not T.at(homeAt(0)) then goRound(homeAt(0)) end
    T.face(0)
    home = homeAt(0)
    local ok = unload("everything")
    if not ok then print("The chests at the start are full or missing: the rest is still in the turtle.") end
    return ok and T.pos.x == 0 and T.pos.y == 0 and T.pos.z == 0
end

-- At the start: the tank filled from the top chest to `need`; with too
-- little there, wait for more (mine.wait), looking every minute, or stop.
function fuelAtStart(need, why)
    local told = false
    while true do
        if not T.hasFuel(need) then T.refuelFrom("top", need) end
        if T.hasFuel(need) then return end
        waitOrStop(string.format("%s: it needs %d fuel and has %d; put fuel in the start's top chest.", why, need,
            turtle.getFuelLevel()), told)
        told = true
    end
end

-- Waiting at the start for supplies: said once (and told to the player,
-- with mine.report), then a minute's wait.  mine.wait off: it stops.
function waitOrStop(msg, told)
    if not waitSupplies then stop(msg) end
    if not told then
        stats.waits = stats.waits + 1
        print(msg .. " Waiting at the start (it looks every minute).")
        tellPlayer("mine is waiting at the start. " .. msg)
    end
    sleep(60)
end

-- The chests at the start's top chest and on board.
function chestsAtStart()
    local n = T.countItem(function(name) return CHEST_ITEMS[name] end)
    for name, c in pairs(chestCounts("top")) do
        if CHEST_ITEMS[name] then n = n + c end
    end
    return n
end

-- The Geo Scanner and the bucket from the start's top chest, if it has
-- them and none is on board.
function takeKit()
    for name in pairs(chestCounts("top")) do
        if isScanner(name) and T.countItem(isScanner) == 0 then
            T.restockFrom("top", name, 1, { quiet = true, room = 1 })
        end
    end
    if chestCounts("top")[BUCKET] and T.countItem(BUCKET) == 0 then
        T.restockFrom("top", BUCKET, 1, { quiet = true, room = 1 })
    end
end

-- Fuel items in the container on `side`.
function fuelIn(side)
    local n = 0
    for name, c in pairs(chestCounts(side)) do
        if T.fuel[name] then n = n + c end
    end
    return n
end

-- Homes whose fuel stock a walk back took (see walkBackCollecting); nil
-- outside a trip to the start.
drained = nil

-- On the way back out (from the start, facing along the tunnel), the
-- fuel stock taken from the homes before `upTo` put back, from the fuel
-- it brings from the start's top chest, as far as that goes.
function refillStocks(upTo)
    local short = 0
    for k = 1, upTo - 1 do
        if drained and drained[k] then
            local h = homeAt(k)
            alongAxis("z", h.z)
            T.face(h.face)
            local have = containerOn("front") and fuelIn("front") or FUEL_STOCK
            for s = 1, 16 do
                if have >= FUEL_STOCK then break end
                local it = turtle.getItemDetail(s)
                if it and T.fuel[it.name] then
                    turtle.select(s)
                    turtle.drop(math.min(it.count, FUEL_STOCK - have))
                    have = have + it.count - turtle.getItemCount(s)
                end
            end
            turtle.select(1)
            if have < FUEL_STOCK then short = short + 1 end
        end
    end
    if short > 0 then
        print(string.format("%d homes are short of their fuel stock (%d each): none left to put back.", short, FUEL_STOCK))
    end
    drained = nil
end

-- From the home it works from, back to the start hauling every home's
-- valuables there (as many trips as it takes, the emptied grown chests
-- picked up on the way), then, once the start has what it needs
-- (need.chests more chests, need.fuel fuel to work with on top of the
-- way there and back; it waits for them, see waitOrStop), straight back
-- out to that home with what the start's top chest holds for it (chests,
-- fuel, torches, wood), and on.  Starts and ends at the home.
function viaStart(why, need)
    need = need or {}
    local working = home
    local was = { inTrip = inTrip, lowFuel = T.cfg.lowFuel, fuelTrip = T.fuelTrip }
    inTrip, T.fuelTrip = true, nil
    T.cfg.lowFuel = 1                       -- (the tank keeps enough to get back; each trip out is checked first)
    print(why .. ": back to the start with the valuables.")
    local full = "The chests at the start are full: no room for what it brings back."
    local outAndBack = 2 * working.z + T.cfg.fuelMargin + (need.fuel or FUEL_WORK)
    drained = {}
    if not walkBackCollecting(outAndBack) then stop(full) end
    for _ = 1, 20 do                        -- what didn't fit on board: more trips, the furthest first
        local far = 0
        for k in pairs(leftBehind) do far = math.max(far, k) end
        if far == 0 then break end
        local h = homeAt(far)
        fuelAtStart(2 * h.z + T.cfg.fuelMargin + FUEL_WORK, "To fetch the rest from home " .. far)
        print(string.format("Out to home %d (z=%d) for the rest.", far, h.z))
        alongAxis("z", h.z)
        T.face(h.face)
        home = h
        if not walkBackCollecting(outAndBack) then stop(full) end
    end
    stats.hauls = stats.hauls + 1
    local told = false
    while need.chests and chestsAtStart() < need.chests do
        waitOrStop(string.format("%s: it needs %d more chests; put them in the start's top chest.", why,
            need.chests - chestsAtStart()), told)
        told = true
    end
    fuelAtStart(outAndBack, why)
    home = homeAt(0)
    takeSupplies(ROOM + 2)
    takeKit()
    print(string.format("Back out to home %d (z=%d).", working.k, working.z))
    refillStocks(working.k)
    alongAxis("z", working.z)
    T.face(working.face)
    home = working
    leaveSupplies()
    T.cfg.lowFuel, T.fuelTrip, inTrip = was.lowFuel, was.fuelTrip, was.inTrip
    refuel()
    restockKit()
end

-- The supplies in the last home (chests, fuel, torches, wood, the crafting
-- table) back to the start, as many trips as it takes: at the end of a
-- tunnel that's finished, and `mine haul --supplies`.  The fuel stock
-- each home keeps stays.  Starts and ends at the start.
function haulSupplies()
    if lastHome == 0 then return end
    local last = homeAt(lastHome)
    for _ = 1, 10 do
        local need = 2 * last.z + T.cfg.fuelMargin + FUEL_WORK
        if not T.hasFuel(need) then T.refuelFrom("top", need) end
        if not T.hasFuel(need) then
            print(string.format("Not enough fuel to fetch the supplies from home %d; they stay there.", last.k))
            return
        end
        print(string.format("Out to home %d (z=%d) for the supplies.", last.k, last.z))
        alongAxis("z", last.z)
        T.face(last.face)
        home = last
        local took, more = 0, false
        if containerOn("front") then
            took, more = takeSupplies(0)
            if not more then pickUpGrown(last) end
        end
        alongAxis("z", 0)
        T.face(0)
        home = homeAt(0)
        unload("everything")
        if not more then
            print("The supplies are at the start.")
            return
        end
        if took == 0 then
            print(string.format("No room to carry the rest of the supplies; they stay in home %d.", last.k))
            return
        end
    end
end

function returnToStart()
    inTrip, T.fuelTrip, bound = true, nil, nil
    T.cfg.lowFuel = 1                       -- the tank was kept for this
    for i = #trail, 1, -1 do retreat(trail[i]) end
    trail = {}
    tunnelHome()
    return walkBackCollecting()
end

-- `mine haul`: shuttle the valuables in the homes back to the start,
-- walking out to the last home and back collecting, as many trips as it
-- takes (the most valuable come first), refuelling at the start.
-- Supplies stay where they are, for `mine --resume`.
function haul()
    inTrip, T.fuelTrip = true, nil
    T.cfg.lowFuel = 1                       -- each trip's fuel is checked first
    local last = homeAt(lastHome)
    for _ = 1, 20 do
        if home.k == 0 then
            local need = 2 * last.z + T.cfg.fuelMargin + FUEL_WORK
            if not T.hasFuel(need) then T.refuelFrom("top", need) end
            if not T.hasFuel(need) then
                print(string.format("A trip out to home %d and back takes %d fuel; it has %d. Put fuel in the top chest.",
                    last.k, need, turtle.getFuelLevel()))
                return
            end
            print(string.format("Out to home %d (z=%d).", last.k, last.z))
            alongAxis("z", 1); alongAxis("z", last.z)
            T.face(last.face)
            home = last
        end
        if not walkBackCollecting() then return end
        if next(leftBehind) == nil then
            print("All the valuables are at the start.")
            return
        end
    end
end

--------------------------------------------------------------------------
-- Main
--------------------------------------------------------------------------
function useJob(job)
    WIDTH, HEIGHT, LENGTH, SPACING = job.width, job.height, job.length, job.spacing
    setBox()
    blocked = loadBlocked()
    loadWater()
end

-- `mine reset` trusts the saved position but checks the heading first:
-- it looks all round (turning on the spot is safe whichever way it
-- really faces) and keeps the way round that fits what it knows of the
-- tunnel here: the finished segments are dug (air), the walls solid.
-- Returns the heading, or nil if it can't tell (it then keeps the saved
-- one; the dig limit catches it if that's wrong).
function checkHeading(dugTo)
    local solid = {}
    for a, seen in pairs(T.lookAround()) do      -- a quarter turns right of the way it faces
        solid[a] = seen and not FLUID[seen.name]
    end
    local function expect(t)
        local v = DELTA[t]
        local n = { x = T.pos.x + v[1], y = T.pos.y, z = T.pos.z + v[3] }
        if n.z < 1 then return nil end
        if inBox(n) then return n.z <= dugTo and "air" or nil end
        return "solid"
    end
    local score, best = {}, nil
    for h = 0, 3 do                        -- if it really faces tunnel direction h
        local strong, weak = 0, 0
        for a = 0, 3 do
            local e = expect((h + a) % 4)
            if e == "air" and solid[a] then strong = strong + 1 end
            if e == "solid" and not solid[a] then weak = weak + 1 end   -- a cave, a vein
        end
        score[h] = strong * 10 + weak
        if not best or score[h] < score[best] then best = h end
    end
    for h = 0, 3 do
        if h ~= best and score[h] == score[best] then return nil end
    end
    if score[best] >= 10 then return nil end
    return best
end

-- `mine where`: where the turtle is along the tunnel, from the saved job
-- and position (nothing moves: safe while mine runs): the last home it
-- passed (behind it, or the one it's at), and the next.
function where()
    local job, p = loadJob(), T.loadPos()
    if not job then print("No saved job: there's no tunnel to be in."); return end
    useJob(job)
    local built = job.homes
    local away = false          -- (between homes: --resume wants it at one, `mine reset` first)
    if not p then
        print("No saved position: it hasn't moved since its last job.")
    elseif p.z <= 0 then
        away = not (p.z == 0 and p.x == 0 and p.y == 0)
        print(not away and "At the start (home 0)." or
            string.format("At the start end, x=%d y=%d z=%d.", p.x, p.y, p.z))
    else
        local k = math.min(math.floor(p.z / SPACING), built)
        local at = p.z == k * SPACING and p.x == 0 and p.y == 0
        away = not at
        if at then
            print(string.format("At home %d (z=%d).", k, p.z))
        else
            print(string.format("At z=%d (x=%d, y=%d).", p.z, p.x, p.y))
            print(string.format("Last home: %d (z=%d), %d blocks back%s.", k, k * SPACING, p.z - k * SPACING,
                k == built and ", the furthest built" or ""))
        end
        if k < built then
            print(string.format("Next home: %d (z=%d), %d blocks on.", k + 1, (k + 1) * SPACING, (k + 1) * SPACING - p.z))
        end
        if k > 0 and not at then
            print(string.format("`mine reset --home %d` takes it back to home %d.", k, k))
        end
    end
    local carryOn = away and "`mine reset`, then `mine --resume`, carries on" or "`mine --resume` carries on"
    local state = job.state == "done" and "finished" or job.state == "stopped" and ("stopped itself (" .. carryOn .. ")")
        or ("under way, or stopped part way (" .. carryOn .. ")")
    print(string.format("The tunnel: %dx%d, %s, homes every %d blocks, %d built (the furthest at z=%d; `mine reset` goes there); %s.",
        math.abs(WIDTH), math.abs(HEIGHT), job.length and (job.length .. " long") or "no end", SPACING, built,
        built * SPACING, state))
    print("Fuel: " .. tostring(turtle.getFuelLevel()) .. ".")
end

-- Home h's chests where the turtle is (it faces the home's way first).
function chestsAt(h)
    T.face(h.face)
    if h.k == 0 then return containerOn("top") and containerOn("bottom") end
    return containerOn("front") and containerOn(h.bulk)
end

-- Not at home h's chests where it thinks it is: a block off each way
-- (through open cells only, nothing dug), looking for them.  Found, the
-- position is put right (and saved): true.  Not found, it's back where it
-- began: false.
function homeNearby(h)
    for _, d in ipairs({ 2, 0, 1, 3, "up", "down" }) do
        local ok = look(d)
        if not ok and T.moveDir(d) then
            if chestsAt(h) then
                print(string.format("The chests are a block off from where it thought: its position is put right"
                    .. " (it went down before saving a move)."))
                T.pos.x, T.pos.y, T.pos.z = h.x, h.y, h.z
                T.savePos()
                return true
            end
            T.moveDir(OPP[d])
            T.face(h.face)
        end
    end
    return false
end

function main()
if doWhere then where(); return end
if doReset and forceHere then T.setHomeHere(); return end
pickaxe = T.findTool("_pickaxe")      -- one equipped, else one in the inventory
if not pickaxe then print("Needs a pickaxe, equipped or in the inventory."); return end
job = loadJob()

-- a tunnel saved before a re-zero is in the old frame: going back along it or digging on would be in the wrong
-- place, so it is marked stale and left (a fresh tunnel replaces it)
if job and job.stale and (doReset or doHaul or resume) then
    print("The saved tunnel can't be carried on: " .. job.stale .. ".")
    if job.state ~= "stale" then
        job.state = "stale"
        T.saveMineJob(job)
        print("It is marked stale; `mine --new` starts a fresh tunnel.")
    end
    return
end

if doReset then
    if not job then print("No saved job; nothing to go back along."); return end
    useJob(job)
    home = homeAt(0)
    segEnd = LENGTH
    local saved, note, far = T.checkedPos()        -- (checked against GPS where there is GPS: ADR-0018)
    if note then print(note) end
    if far then print("Not heading back from there."); return end
    if not saved then print("No saved position; the turtle hasn't moved since its last job."); return end
    T.pos.x, T.pos.y, T.pos.z, T.dir = saved.x, saved.y, saved.z, saved.dir
    -- where to: the last home it built, the one asked for (--home N), or
    -- the start (asked for, no homes yet, it's at the start already, or the
    -- tunnel is finished: there's nothing to resume from a home)
    local target = homeAt(job.homes)
    if homeArg then
        if homeArg ~= math.floor(homeArg) or homeArg < 0 or homeArg > job.homes then
            print(string.format("There's no home %s: they go from 0 (the start) to %d.", tostring(homeArg), job.homes))
            return
        end
        target = homeAt(homeArg)
    elseif toStart or saved.z <= 0 or job.state == "done" then target = homeAt(0) end
    if T.at(target) then
        T.face(target.face)
        print(target.k == 0 and "At the start already." or ("At home " .. target.k .. " already."))
        return
    end
    print(string.format("Last position %s facing %d. Heading back to %s.", T.posString(), T.dir,
        target.k == 0 and "the start" or string.format("home %d (z=%d)", target.k, target.z)))
    inTrip = true                       -- no trips: just get back
    local h = checkHeading(job.homes * SPACING)
    if h and h ~= T.dir then
        print(string.format("It really faces %d, not %d (the tunnel says so): going by that.", h, T.dir))
        T.setDir(h)
    end
    -- the way back digs at most out of a vein and across the segment it
    -- was in; much more than that and its position or heading is wrong
    digLimit = outside(T.pos) + (X1 - X0) + (Y1 - Y0) + 8
    local ok, err = pcall(T.withTool, pickaxe, function()
        -- out of a vein first: straight back to the nearest tunnel block
        if not inBox(T.pos) and T.pos.z >= 1 then
            alongAxis("y", math.max(Y0, math.min(Y1, T.pos.y)))
            alongAxis("x", math.max(X0, math.min(X1, T.pos.x)))
            alongAxis("z", math.max(1, math.min(LENGTH, T.pos.z)))
        end
        alongAxis("x", 0); alongAxis("y", 0); alongAxis("z", target.z)
        if not T.at(target) then goRound(target) end
        T.face(target.face)
    end)
    digLimit = nil
    -- there means its chests are there
    local there = ok and T.pos.x == 0 and T.pos.y == 0 and T.pos.z == target.z and chestsAt(target)
    -- the computer going down right after a move, before it was saved (a
    -- chunk unloading), leaves the saved position a block behind: the
    -- chests are then a block off, the way of that move
    if ok and not there and T.pos.x == 0 and T.pos.y == 0 and T.pos.z == target.z then
        there = homeNearby(target)
    end
    if not ok or not there then
        if not ok and (type(err) ~= "table" or not err.lost) then error(err, 0) end
        print(not ok and "It's digging through far more rock than the way back should take, so its saved"
            or "There are no home chests where it ended up, so its saved")
        print("position or heading must be wrong (it thinks it's at " .. T.posString() .. "). Stopped.")
        print("Pick it up, put it back at the start facing down the tunnel, and run `mine reset --here`.")
        return
    end
    if T.pos.x == 0 and T.pos.y == 0 and T.pos.z == target.z then
        if target.k == 0 then print("At the start.")
        else
            print(string.format("At home %d (z=%d). `mine --resume` carries on from here%s;", target.k, target.z,
                target.k < job.homes and " (going over the tunnel to the last home again, drying out any water)" or ""))
            print("`mine haul` brings the valuables back to the start.")
        end
    else
        print("Couldn't get there; stopped at " .. T.posString())
    end
    return
end

-- Where a run starts: at the start, or (resuming or hauling) at the home
-- `mine reset` left it at (the last, or one asked for with --home).  nil
-- (having said why) if neither.
function startingHome(fromLast)
    local saved, note, far = T.checkedPos()        -- (checked against GPS where there is GPS: ADR-0018)
    if note then print(note) end
    if far then return nil end
    local last
    if fromLast and saved and saved.x == 0 and saved.y == 0 and saved.z > 0 and saved.z % SPACING == 0
            and saved.z / SPACING <= lastHome then
        last = homeAt(math.floor(saved.z / SPACING))
    end
    if last then
        T.pos.x, T.pos.y, T.pos.z, T.dir = 0, 0, last.z, saved.dir
        T.face(last.face)
        if not (containerOn("front") and containerOn(last.bulk)) then
            print("Home " .. last.k .. "'s chests are missing.")
            return nil
        end
        return last
    end
    if not T.requireHome(forceHere, "mine") then return nil end
    if not (containerOn("top") and containerOn("bottom")) then
        print("Needs a chest above the turtle (valuables) and one below it (bulk).")
        return nil
    end
    return homeAt(0)
end

if doHaul then
    if not (job and job.homes > 0) then print("No homes yet: everything is at the start already."); return end
    useJob(job)
    lastHome = job.homes
    segEnd = LENGTH
    home = startingHome(true)
    if not home then return end
    grown = loadGrown()
    T.withTool(pickaxe, function()
        haul()
        if opts.supplies and T.pos.x == 0 and T.pos.y == 0 and T.pos.z == 0 then haulSupplies() end
    end)
    for _, k in ipairs(tables.sortedKeys(leftBehind)) do
        print(string.format("Still %d items in home %d (z=%d).", leftBehind[k], k, homeAt(k).z))
    end
    return
end

-- The tunnel asked for again (its width and height, from the same start):
-- carried on as `--resume` does, rather than dug again; and a finished
-- tunnel is carried on when the length asked for now is longer.
asked = LENGTH or math.huge
sameTunnel = job and not job.stale and job.homes > 0 and not resume and not forceHere
    and WIDTH == job.width and HEIGHT == job.height
if sameTunnel then
    if job.state == "done" and asked <= (job.length or math.huge) then
        print(string.format("The %dx%d tunnel here is dug to its length (%d) already: give a longer one, or none.",
            math.abs(job.width), math.abs(job.height), job.length or 0))
        return
    end
    print(string.format("The %dx%d tunnel saved here is the same one: carrying it on from home %d (homes every %d, as built).",
        math.abs(job.width), math.abs(job.height), job.homes, job.spacing))
    resume = true
    if job.state == "done" then         -- (dug to its old length: gone over, not dug again)
        finishedTo, job.state = job.length, "stopped"
    end
    job.length = asked ~= math.huge and asked or nil
elseif resume and job and job.state == "done" and not job.stale and job.homes > 0 and asked > (job.length or math.huge) then
    finishedTo = job.length                 -- (dug to there: gone over, not dug again)
    job.length = asked ~= math.huge and asked or nil
    job.state = "stopped"
    print("Carrying the finished tunnel on: " .. (job.length and ("to " .. job.length) or "with no end") .. ".")
end
if resume then
    if not (job and (job.state == "active" or job.state == "stopped")) then
        print("No stopped tunnel to resume.")
        return
    end
    useJob(job)
    lastHome = job.homes
elseif job and job.state ~= "done" and not job.stale and job.homes > 0 and not fresh then
    print(string.format("A %dx%d tunnel with %d homes was stopped here.", job.width, job.height, job.homes))
    print("Run `mine --resume` to keep digging it, or add --new to start a fresh tunnel.")
    return
else
    setBox()
end
if resume then grown = loadGrown() else clearGrown(); clearBlocked(); bulkheadZ, capZ = nil, nil; saveWater() end

home = startingHome(resume)
if not home then return end
lanes = #planLanes()
fuelGoal = lanes * SPACING + 4 * SPACING + 300
saveJob("active")
if originArg then
    if T.pos.x == 0 and T.pos.y == 0 and T.pos.z == 0 then
        local ok, why = T.setOrigin(originArg.x, originArg.y, originArg.z, originArg.facing)
        if ok then
            print(string.format("World origin: the start is at %d,%d,%d%s.", originArg.x, originArg.y, originArg.z,
                originArg.facing and (", facing " .. originArg.facing) or ""))
        else
            print("Not setting the origin (" .. tostring(why) .. ").")
        end
    else
        print("Not setting the origin: --origin is for a run from the start.")
    end
end
releaseHomes()
for k = 0, lastHome do protectHome(homeAt(k)) end

stopped = nil
T.withTool(pickaxe, function()
    local ok, err = pcall(function()
        -- resuming behind the last home: out to it first (see below)
        local walkOut = resume and job and job.homes > 0 and home.k < job.homes
        unloadOrStop(walkOut and home.k > 0 and "bulk" or nil)   -- (valuables stay on board till then)
        refuel()
        if not fuelToGoOn() then stop("Not enough fuel to start: put fuel in the top chest.") end
        roomAboveChest(home)               -- a home built before chests got room above them
        -- a Geo Scanner in the top chest (or on board): use it
        -- and a bucket (see scoop)
        takeKit()
        hasScanner = T.countItem(isScanner) > 0 or isScanner(T.equipped("left") or "")
            or isScanner(T.equipped("right") or "")
        if hasScanner then
            print("Geo scanner on board: scanning instead of checking every wall block.")
        end
        T.fuelTrip = function() trip("Low on fuel") end
        print(string.format("Mining a %dx%d tunnel, %s, homes every %d blocks.", math.abs(WIDTH),
            math.abs(HEIGHT), LENGTH == math.huge and "as long as it can" or (LENGTH .. " long"), SPACING))
        if lights and tooWide then
            print(string.format("A tunnel %d wide is too wide to light from its walls: the middle of the floor stays dimmer"
                .. " than light 2 (mobs may spawn there from about 27 wide).", math.abs(WIDTH)))
        end
        -- resuming from the start or an earlier home: out to the last home
        -- in one go, the valuables it carries kept on board, taking what's
        -- useful (fuel, torches, chests, wood, the crafting table; bulk
        -- blocks to patch with) from each home it passes, straight along
        -- the middle of the floor, stopping to work only where water gets in
        if walkOut then
            local here, last = home, homeAt(job.homes)
            -- the walk out (and back to the start, should it have to) is
            -- longer than a segment's work: fill the tank for it first
            T.refuelFrom(home.val, 2 * last.z - home.z + T.cfg.fuelMargin + FUEL_WORK)
            if not fuelToGoOn(2 * (last.z - home.z)) then
                stop("Not enough fuel to get back out to home " .. last.k .. "."
                    .. (home.k > 0 and (" Put some in home " .. home.k .. ".") or ""))
            end
            -- on the way, each segment is gone over: water in it is
            -- followed to where it gets in and sealed, and torches it
            -- washed off put back (room left for what that digs)
            inTrip = true
            takeSupplies(ROOM + 2)
            print(string.format("Out to home %d along the middle of the floor, stopping only where water gets in.", last.k))
            for k = here.k, last.k - 1 do
                local from = homeAt(k)
                if k > here.k then
                    -- a home it passes: bulk down into its bulk chest, and
                    -- what's useful in it along
                    home = from
                    T.face(from.face)
                    if containerOn("front") and containerOn(from.bulk) then
                        unload("bulk")
                        takeSupplies(ROOM + 2)
                    end
                end
                -- bulk blocks for sealing water and filling holes on the way
                restockSet(from.bulk, FILLER, fillerKeep)
                home = homeAt(k + 1)               -- (repair ends at home)
                -- going over it, trips for bulk blocks or fuel (water to
                -- seal) go to this segment's far home, on the way: what
                -- it leaves there it takes again passing it
                inTrip = false
                repair(from.z + 1, home.z, nil, k + 1 < last.k)
                inTrip = true
                bulkOutOfValuables(home)           -- (at each home anyway: bulk down where it belongs)
            end
            T.face(last.face)
            if not (containerOn("front") and containerOn(last.bulk)) then
                stop("Home " .. last.k .. "'s chests are missing.")
            end
            home = last
            lastHome = last.k
            roomAboveChest(last)               -- (a home built before chests got room above them)
            leaveSupplies()
            refuel()
            restockKit()
            inTrip = false
            reportHoles()
            print(string.format("Back at home %d (z=%d).", home.k, home.z))
        end
        if not resume then clearProgress() end
        local progress = resume and loadProgress()
        if not (progress and progress.k == lastHome) then progress = nil end
        -- lanes planned another way since (an update, a scanner added or
        -- taken away): "lane N" means something else now, so the segment
        -- starts again from its first lane (what's dug is just walked through)
        if progress and progress.lanes ~= #planLanes() then
            if home.k == lastHome then
                print("The lanes are planned differently from when it stopped: going over this segment from its first lane.")
            end
            progress = nil
        end
        while home.z < LENGTH do
            segEnd = math.min(home.z + SPACING, LENGTH)
            if home.k < lastHome or (finishedTo and segEnd <= finishedTo) then
                repairSegment(home.z + 1, segEnd, home.k + 1 < lastHome)
            else
                mineSegment(home.z + 1, segEnd, progress)
                progress = nil
            end
            unloadOrStop()
            refuel()
            if segEnd >= LENGTH then break end
            advance()
        end
    end)
    T.fuelTrip = nil
    inTrip = false
    if not ok then
        if err == "Terminated" then releaseHomes(); error(err, 0) end
        stopped = type(err) == "table" and err.stop or tostring(err)
        print("Stopping: " .. stopped)
    end
    returnToStart()
    -- a finished tunnel: its supplies come home too (stopped, they stay for --resume)
    if not stopped and T.pos.x == 0 and T.pos.y == 0 and T.pos.z == 0 then haulSupplies() end
    releaseHomes()
end)
-- "stopped": it stopped itself and came back, so the autostart leaves it;
-- "active" left behind means it went down mid-job, and the autostart resumes
saveJob(stopped and "stopped" or "done")
if not stopped then clearProgress() end
final = string.format("%s: %d homes built, %d veins (%d ore blocks), %d fluid blocks sealed, %d floor holes filled%s%s.",
    stopped and "Stopped" or "Done", stats.homes, stats.veins, stats.ore, stats.sealed, stats.filled,
    lights and (", " .. stats.torches .. " torches placed"
        .. (stats.relit > 0 and (" (" .. stats.relit .. " put back after digging knocked them off)") or "")) or "",
    hasScanner and (", " .. stats.fetched .. " deposits fetched from further out") or "")
    .. (stats.wood > 0 and string.format(" Dug %d blocks of wood for chests and torches.", stats.wood) or "")
    .. (stats.lava > 0 and string.format(" Burned %d lava sources for fuel.", stats.lava) or "")
    .. (stats.grown > 0 and string.format(" Grew %d home chests into double chests.", stats.grown) or "")
    .. (stats.pickedUp > 0 and string.format(" Picked up %d emptied ones.", stats.pickedUp) or "")
    .. (stats.hauls > 0 and string.format(" Hauled to the start %d times.", stats.hauls) or "")
    .. (stats.waits > 0 and string.format(" Waited for supplies %d times.", stats.waits) or "")
    .. (stats.thrown > 0 and string.format(" Threw away %d bulk blocks no chest had room for.", stats.thrown) or "")
    .. (stats.shell + stats.fill > 0 and string.format(" Through open water: %d blocks of shell, %d filled in and dug"
        .. " out again%s.", stats.shell, stats.fill, stats.cap > 0 and string.format(", an end cap of %d", stats.cap) or "") or "")
    .. (stats.traced > 0 and string.format(" Traced water coming in to its source and filled it %d times.", stats.traced) or "")
    .. (stats.bowls > 0 and string.format(" Caught water falling in through the ceiling in %d bowls (%d blocks).", stats.bowls,
        stats.bowlBlocks) or "")
    .. (stats.standing > 0 and string.format(" Went round %d blocks it doesn't dig%s.", stats.standing,
        stats.spawners > 0 and string.format(" (%d spawners, lit with %d torches)", stats.spawners, stats.spawnerTorches) or "") or "")
print(final)
for _, k in ipairs(tables.sortedKeys(leftBehind)) do
    print(string.format("No room to bring back %d items from home %d (z=%d).", leftBehind[k], k, homeAt(k).z))
end
if stopped then print("Stopped because: " .. stopped .. " `mine --resume` carries on.") end
tellPlayer("mine " .. final .. (stopped and (" Stopped because: " .. stopped) or ""))
end

-- Under T.run, Ctrl+T never leaves the saved position or heading wrong.
T.run(main)
