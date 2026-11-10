-- farm.lua -- crop farming turtle for CC:Tweaked (wheat, carrots,
-- potatoes, beetroot and sugar cane; any mix of them on one farm)
--
-- Needs a diamond hoe (and a diamond pickaxe for `clone`), equipped or in
-- the inventory.  The program makes the tool it needs the only tool
-- equipped and parks the other in the inventory, so digDown() with the hoe
-- always tills.  Optional: Advanced Peripherals Chunky Turtle upgrade.
--
-- Usage:
--   farm <width> <length> [repeatMinutes]         first run: explore + farm
--   farm [repeatMinutes]                           later runs: saved layout
--   farm learn <width> <length> [repeatMinutes]    re-explore the farm
--   farm repair                                    inspect every tile once and
--                                                  fix damage, then stop
--   farm clone [repeatMinutes]                     build the saved layout HERE,
--                                                  then farm it
--   farm reset                                     return to home after a stop
--   farm reset --here                              turtle is home already (moved
--                                                  by hand): just reset position
--   farm ... --here                                accept current spot as home
--
-- width  = tiles to the RIGHT of the turtle (negative = to the LEFT)
-- length = tiles AHEAD of the turtle (negative = BEHIND)
-- Both are counted OUT from the turtle: its own row and column are not part
-- of the farm, so the box is x = 1..width, z = 1..length.
-- repeatMinutes defaults to 20; 0 = single pass.
--
-- Settings (`sysctl farm.repeat=30`): farm.width and farm.length are the box
-- to learn when none is given (a size given is saved there, so a turtle
-- that boots with no map can learn the same farm again), farm.repeat the
-- minutes between passes.
--
-- Placement: put the turtle diagonally outside one corner of the farm,
-- hovering TWO blocks above the farmland (one block above the crop tops).
-- Put the output chest/barrel directly below the start position (up to 3
-- blocks down, air between; it's found afresh on every visit, so it can be
-- moved up or down later without telling the turtle).  Keep in the chest: what each crop is planted with (wheat
-- or beetroot seeds, carrots, potatoes, sugar cane), dirt, and a bucket or
-- two (water buckets for clone); the turtle restocks from it.
--
-- How it works:
--  * Learning pass: only records the layout; it changes nothing.  Flies
--    over every tile in the box.  A crop below -> crop tile.  Air below ->
--    drops down a block to look at the ground: farmland -> crop tile;
--    water -> lane; other -> left alone.  Missing ground and bare dirt
--    could be either, so they take the kind of the strip they lie in
--    (bare dirt outside any strip is farmed).  Saved to farm.map, which
--    from then on is the farm as it SHOULD be.
--  * Farming pass: serpentines over the crop tiles only, line by line
--    along the lanes, each line from the end nearest the last, lanes
--    skipped.  Untilled dirt is tilled and planted on the way.  Ground
--    missing under a crop tile, or a block in the way, is damage: after
--    the pass the turtle goes home and runs a full repair pass.
--  * Full repair pass (also `farm repair`, and once after clone):
--    inspects every crop tile and dips to crop level over every lane
--    tile to check its water, then rebuilds damaged tiles to match the
--    layout.  Land: dirt, till, plant.  Lane: dirt floor beneath if
--    missing, dirt walls on every side that isn't lane, then water.
--    After learning there's no inspection: learning saw every tile, so
--    just the gaps it found (missing ground, lane water that isn't a
--    source) are rebuilt, and only if there are any.
--  * Clone: builds farm.map at the current position.  Phase 1 (pickaxe)
--    clears the crop level, digs lane trenches and removes stone where
--    land is wanted.  Phase 2 (hoe) fills/tills/plants land, then floors,
--    walls and waters the lanes.  Each lane is bootstrapped with two water
--    buckets at tiles 1 and 3 (tile 2 becomes a source on its own) and the
--    rest is scooped from that regenerating tile.
--  * Crops: learning notes which crop grows on each tile; bare farmland
--    gets the crop most of its strip grows.  The farming pass harvests
--    each crop when ripe (age 7; beetroot 3) and replants the crop the
--    plan wants there (a different crop found growing is harvested when
--    ripe and replaced), and plants bare farmland (tilling through the
--    air gap if it reverted to dirt).  Back home it drops produce,
--    restocks, repairs if needed, composts surplus seeds, runs grow
--    passes when the chest has bone meal to spare, and sleeps.
--  * Sugar cane: grows on dirt, sand, moss, mud and the like, beside a
--    water source, up to 3 high from cruise height upwards, so on a farm
--    with cane the turtle travels at CANE_TRAVEL_Y (learning always does).
--    Cane is worked from one above cruise height: a third block is cut on
--    the way in and the second from above, so every cut block lands in
--    the inventory; the bottom block is never cut, since that is what
--    regrows.  A missing bottom block is replanted with cane; if it won't
--    take (no ground, or no water beside it) that's damage, and the full
--    repair pass rebuilds the lane first, then the cane.
--  * Navigation is at a fixed cruise height (turtlelib.stepFlat) with a
--    learned obstacle map and BFS re-routing.  Position is saved to disk
--    after every move so `farm reset` can bring it home after a Ctrl+T.

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
tables = require("tables")
fileio = require("fileio")

MAP_FILE = T.dataPath("farm.map")

--------------------------------------------------------------------------
-- Arguments
--------------------------------------------------------------------------
-- (T.options: a negative size, -3, is a size, not an option; a flag
-- alone can't be wrong, so there's no error to check)
opts, args = T.options({ ... }, { here = true })
forceLearn, doClone, doRepair, doReset = false, false, false, false
forceHere = opts.here == true
if args[1] == "learn" then forceLearn = true; table.remove(args, 1)
elseif args[1] == "repair" then doRepair = true; table.remove(args, 1)
elseif args[1] == "clone" then doClone = true; forceHere = true; table.remove(args, 1)
elseif args[1] == "reset" then
    if forceHere then T.setHomeHere(); return end
    doReset = true                       -- once the map can be read (below)
end

WIDTH, LENGTH, REPEAT = nil
if #args >= 2 then
    WIDTH, LENGTH, REPEAT = tonumber(args[1]), tonumber(args[2]), tonumber(args[3])
else
    REPEAT = tonumber(args[1])
end
SET = {
    width = T.setting("farm.width", nil, "Farm width to learn: tiles + right / - left of the turtle"),
    length = T.setting("farm.length", nil, "Farm length to learn: tiles + ahead / - behind the turtle"),
    ["repeat"] = T.setting("farm.repeat", 20, "Minutes between farm passes; 0 = a single pass"),
}
if WIDTH and LENGTH then
    savedSize = { ["farm.width"] = WIDTH, ["farm.length"] = LENGTH }   -- saved once it's checked
    if REPEAT then savedSize["farm.repeat"] = REPEAT end
elseif not doClone then
    WIDTH, LENGTH = tonumber(SET.width), tonumber(SET.length)
end
if REPEAT == nil then REPEAT = SET["repeat"] end   -- minutes; 0 = single pass

CRUISE_MOVES_PER_TILE = 1.2
MAX_SEEDS = 256           -- never carry more than this many seeds
ROOM = 3                  -- empty slots to have before working a tile: its
                                -- drops (up to two kinds) plus one for tool swaps

-- Crops grown on farmland: block -> item that plants it, age when ripe.
-- compost: the seed isn't the harvest, so surplus seeds can be composted.
-- meal: bone meal to grow one from seed, near the worst case (each adds
-- 2-5 stages; beetroot only advances one stage, three times in four).
CROPS = {
    ["minecraft:wheat"]     = { seed = "minecraft:wheat_seeds",    ripe = 7, meal = 4, name = "wheat", compost = true },
    ["minecraft:carrots"]   = { seed = "minecraft:carrot",         ripe = 7, meal = 4, name = "carrots" },
    ["minecraft:potatoes"]  = { seed = "minecraft:potato",         ripe = 7, meal = 4, name = "potatoes" },
    ["minecraft:beetroots"] = { seed = "minecraft:beetroot_seeds", ripe = 3, meal = 6, name = "beetroot", compost = true },
}
BONE_MEAL = "minecraft:bone_meal"
MAX_MEAL = 192           -- bone meal carried at once (3 stacks)
MEAL_PER_TILE = 10       -- give up on a tile after this many
DEFAULT_CROP = "minecraft:wheat"   -- for a farm with nothing growing yet

-- Sugar cane is planted with the item itself, on any of these grounds, and
-- only takes with a water source beside the ground block.  Its bottom block
-- is never cut: that is the part that regrows.
CANE = "minecraft:sugar_cane"      -- the block and the item
CANE_GROUND = {
    ["minecraft:dirt"] = true, ["minecraft:grass_block"] = true,
    ["minecraft:coarse_dirt"] = true, ["minecraft:podzol"] = true,
    ["minecraft:rooted_dirt"] = true, ["minecraft:mycelium"] = true,
    ["minecraft:moss_block"] = true, ["minecraft:mud"] = true,
    ["minecraft:muddy_mangrove_roots"] = true, ["minecraft:sand"] = true,
    ["minecraft:red_sand"] = true, ["minecraft:suspicious_sand"] = true,
}
CANE_TRAVEL_Y = 2    -- travel height over a farm with cane: above 3-high cane
LANE_BUCKETS = 4     -- buckets carried for lane work, if the chest has them

SEEDS = { CANE }                   -- planting items, sorted
for _, c in pairs(CROPS) do SEEDS[#SEEDS + 1] = c.seed end
table.sort(SEEDS)
DIRT = "minecraft:dirt"
WATER = "minecraft:water"
FARMLAND = "minecraft:farmland"
CHEST_SIDE = "bottom"    -- the output chest is always below home
BUCKET, WATER_BUCKET = "minecraft:bucket", "minecraft:water_bucket"
HOE, PICKAXE = "minecraft:diamond_hoe", "minecraft:diamond_pickaxe"
TILLABLE = {
    ["minecraft:dirt"] = true, ["minecraft:grass_block"] = true,
    ["minecraft:coarse_dirt"] = true, ["minecraft:dirt_path"] = true,
    ["minecraft:rooted_dirt"] = true,
}

T.step = T.stepFlat
T.mode = "flat"
T.diggable = {}            -- never dig while moving

--------------------------------------------------------------------------
-- Farm layout map: tiles[key] = "crop" | "cane" | "water" | "other", and
-- for crop tiles crops[key] = the crop block planned there.
-- (the learning pass also uses "hole" and "dirt" until resolveLayout)
--------------------------------------------------------------------------
tiles = {}
crops = {}
wet = {}             -- tiles that actually hold water right now
pendingFills = {}    -- holes (or clone targets) still to build

keyXZ = T.keyXZ

-- The crop planned for a tile (maps saved before crops were tracked: wheat).
function cropAt(k) return crops[k] or DEFAULT_CROP end

function saveMap()
    local lines = { WIDTH .. " " .. LENGTH }
    for _, k in ipairs(tables.sortedKeys(tiles)) do
        lines[#lines + 1] = k .. " " .. tiles[k] .. (crops[k] and (" " .. crops[k]) or "")
    end
    fileio.write(MAP_FILE, table.concat(lines, "\n") .. "\n")
end

function loadMap()
    local saved = fileio.read(MAP_FILE)
    if not saved then return false end
    local lines = text.lines(saved)
    -- the first line: "width length"
    local size = text.words(lines[1] or "")
    if not (scan.isInteger(size[1]) and scan.isInteger(size[2])) then return false end
    WIDTH, LENGTH = tonumber(size[1]), tonumber(size[2])
    tiles, crops = {}, {}
    -- then a line a tile: "key kind", and its crop if it has one
    for i = 2, #lines do
        local w = text.words(lines[i])
        if w[2] then
            tiles[w[1]] = w[2]
            if w[3] and CROPS[w[3]] then crops[w[1]] = w[3] end
        end
    end
    return true
end

function countKind(kind)
    local n = 0
    for _, k in pairs(tiles) do if k == kind then n = n + 1 end end
    return n
end

-- "12 wheat, 6 carrots": what the layout grows.
function cropSummary()
    local n, order = {}, {}
    for k, kind in pairs(tiles) do
        if kind == "crop" then
            local c = cropAt(k)
            if not n[c] then n[c] = 0; order[#order + 1] = c end
            n[c] = n[c] + 1
        end
    end
    table.sort(order)
    local parts = {}
    for _, c in ipairs(order) do parts[#parts + 1] = n[c] .. " " .. CROPS[c].name end
    local cane = countKind("cane")
    if cane > 0 then parts[#parts + 1] = cane .. " sugar cane" end
    return #parts > 0 and table.concat(parts, ", ") or "no crops"
end

-- How many tiles planting item `seed` is planted on.
function plantedWith(seed)
    if seed == CANE then return countKind("cane") end
    local n = 0
    for k, kind in pairs(tiles) do
        if kind == "crop" and CROPS[cropAt(k)].seed == seed then n = n + 1 end
    end
    return n
end

-- How many of planting item `seed` to carry: one per tile it grows on
-- plus a margin, capped.  Zero for crops the farm doesn't grow.
function seedTarget(seed)
    local n = plantedWith(seed)
    return n == 0 and 0 or math.min(MAX_SEEDS, n + 16)
end

-- Is a planting item the farm needs completely missing from the inventory?
function lacksSeeds()
    for _, seed in ipairs(SEEDS) do
        if seedTarget(seed) > 0 and T.countItem(seed) == 0 then return true end
    end
    return false
end

--------------------------------------------------------------------------
-- Tile primitives (all start and end at cruise height)
--------------------------------------------------------------------------
below = T.below

-- Is the block below a water SOURCE?  Lanes are all sources; flowing
-- water (level > 0) counts as damage and gets a bucket poured into it.
function sourceBelow()
    local name, d = below()
    return name == WATER and not (d.state and (tonumber(d.state.level) or 0) > 0)
end

function plantDown(seed)
    if not T.selectItem(seed) then return false end
    return turtle.placeDown()
end

function placeDirtDown()
    return T.selectItem(DIRT) and turtle.placeDown()
end

-- Height for getting around: cruise height, or CANE_TRAVEL_Y over a farm
-- with sugar cane, which grows into cruise height.
travelY = 0

-- Travel to (tx,tz) at travel height, then sink to cruise height.
function goToCruise(tx, tz)
    T.toY(travelY)
    return T.goTo(tx, tz) and T.toY(0)
end

-- Fuel to get home and down to the chest from here: up to travel height,
-- across, and back down (the chest is at most 3 below home).
function T.homeCost()
    return math.abs(T.pos.x) + math.abs(T.pos.z) + math.abs(travelY - T.pos.y) + travelY + 4
end

warnedLow = false
function warnLow()
    if not warnedLow then
        warnedLow = true
        print("Note: ground is directly below cruise height; the turtle is one block")
        print("lower than ideal and will bob up to plant. Start it one higher next time.")
    end
end

-- The turtle cruises one block above the crop tops, i.e. two above the
-- farmland.  CC:Tweaked lets a hoe till THROUGH one block of air below the
-- turtle (TurtleTool.useTool), so bare dirt can be tilled from cruise height
-- with a plain digDown(); seeds also place through that gap onto farmland.
-- `crop` is the crop the plan wants here; a different crop found growing
-- is left to ripen, then harvested and replaced with the planned one.
-- harvest = false only plants (repair mode's inspection).
-- Returns: harvested | growing | planted | empty | noseeds | damaged | blocked
-- (damaged: no farmland or dirt to plant on; blocked: something in the way)
function workCrop(harvest, crop)
    local seed = CROPS[crop].seed
    local name, d = below()
    local here = CROPS[name]
    if here then
        local age = d.state and tonumber(d.state.age)
        if harvest and age and age >= here.ripe then
            turtle.digDown()                 -- hoe on a crop: breaks it
            plantDown(seed)
            return "harvested"
        end
        return "growing"
    elseif name == "air" then
        if plantDown(seed) then return "planted" end
        if T.countItem(seed) == 0 then return "noseeds" end
        turtle.digDown()                     -- till through the gap
        if plantDown(seed) then return "planted" end
        return "damaged"
    elseif TILLABLE[name] or name == FARMLAND then
        warnLow()
        if TILLABLE[name] then turtle.digDown() end
        if not T.up() then return "blocked" end
        local r = plantDown(seed) and "planted" or (T.countItem(seed) == 0 and "noseeds" or "empty")
        T.down()
        return r
    end
    return "blocked"
end

-- Work a cane tile from one above cruise height (see visit).  The block
-- below is the cane's second block: cut it, never the bottom one, which
-- regrows.  With no second block, drop down to look at the bottom one and
-- plant it if it's missing.  A planting that fails with cane on board
-- means no ground, or no water next to it: damage.
-- Returns: harvested | growing | planted | noseeds | damaged | blocked
function workCane(harvest)
    local name = below()
    if name == CANE then
        if harvest then turtle.digDown(); return "harvested" end
        return "growing"
    end
    if name ~= "air" or not T.down() then return "blocked" end
    name = below()
    local r = "blocked"
    if name == CANE then r = "growing"
    elseif name == "air" then
        if plantDown(CANE) then r = "planted"
        elseif T.countItem(CANE) == 0 then r = "noseeds"
        else r = "damaged" end
    end
    T.up()
    return r
end

-- Classify the tile below during the learning pass, without changing it.
-- Starts at travel height and comes down, since cane may stand up to it.
-- crop | cane | water | dirt | hole | other  (dirt and hole: see
-- resolveLayout), plus the crop block for a tile with a crop growing on it,
-- plus true for a gap the farming pass won't fix by itself: missing
-- ground, or lane water that isn't a source.
function learnTile()
    while T.pos.y > 0 do
        local name = below()
        if name == CANE then return "cane" end
        if name ~= "air" or not T.down() then return "other" end
    end
    local name = below()
    if CROPS[name] then return "crop", name end
    if name == CANE then return "cane" end
    if name == WATER then return "water" end
    if name == FARMLAND then warnLow(); return "crop" end
    if TILLABLE[name] then warnLow(); return "dirt" end
    if name ~= "air" then return "other" end
    if not T.down() then return "other" end
    local g = below()
    local kind = "other"
    if g == FARMLAND then kind = "crop"
    elseif TILLABLE[g] then kind = "dirt"
    elseif g == WATER then kind = "water"
    elseif CANE_GROUND[g] then kind = "cane"      -- sand, mud...: only cane grows there
    elseif g == "air" then kind = "hole"
    end
    local gap = kind == "hole" or (kind == "water" and not sourceBelow())
    T.up()
    return kind, nil, gap
end

--------------------------------------------------------------------------
-- Home chest: dump produce, restock seeds / dirt / buckets
--------------------------------------------------------------------------
function dirtNeeded()
    local n = 0
    for _, f in ipairs(pendingFills) do n = n + (f.want == "water" and 4 or 1) end
    return math.min(n, 192)
end

wantWaterBuckets = 0     -- buckets the lane builder carries
needWaterBuckets = 0     -- ...of which it can't do without
wantBoneMeal = 0         -- bone meal to carry, during a grow pass
fuelGoal = 0             -- fuel to set out with: about one pass
FUEL_WORK = 100          -- least fuel worth setting out with, beyond the trip

-- What stays on board at every visit home: seeds for a pass, fuel, the
-- tools, and dirt and buckets only while a repair needs them.  Everything
-- else goes into the chest.
function keepPolicy(item, alreadyKept)
    local target = seedTarget(item.name)
    if target > 0 then return math.max(0, target - alreadyKept) end
    if item.name == DIRT then return math.max(0, dirtNeeded() - alreadyKept) end
    if item.name == WATER_BUCKET then return math.max(0, wantWaterBuckets - alreadyKept) end
    if item.name == BONE_MEAL then return math.max(0, wantBoneMeal - alreadyKept) end
    if item.name == BUCKET then
        local filled = math.min(T.countItem(WATER_BUCKET), wantWaterBuckets)
        return math.max(0, wantWaterBuckets - filled - alreadyKept)
    end
    if T.fuel[item.name] then return item.count end
    return 0
end

-- Restock from the chest below, leaving ROOM slots free for drops.
function restockItem(name, target, label, quiet)
    T.restockFrom(CHEST_SIDE, name, target, { label = label, quiet = quiet, room = ROOM })
end


-- Buckets for lane work: wantWaterBuckets of them if the chest has them,
-- warning below needWaterBuckets.  Empty ones will do when a lane tile can
-- refill them; otherwise full ones are fetched first.
warnedBuckets = false
function restockBuckets()
    local want, need = wantWaterBuckets, needWaterBuckets
    if want <= 0 then return end
    local canScoop = regenTile() ~= nil
    if not canScoop then restockItem(WATER_BUCKET, want, "Water buckets", true) end
    if T.countItem(WATER_BUCKET) + T.countItem(BUCKET) < want then
        restockItem(BUCKET, want - T.countItem(WATER_BUCKET), "Buckets", true)
    end
    if T.countItem(WATER_BUCKET) + T.countItem(BUCKET) < want then
        restockItem(WATER_BUCKET, want - T.countItem(BUCKET), "Water buckets", true)
    end
    local full, empty = T.countItem(WATER_BUCKET), T.countItem(BUCKET)
    if (full + empty < need or (not canScoop and full < need)) and not warnedBuckets then
        warnedBuckets = true
        print(string.format("Lane work needs %d %s; on board: %d water, %d empty (none in chest).",
            need, canScoop and "buckets" or "water buckets", full, empty))
    end
end

--------------------------------------------------------------------------
-- Compost hopper: a hopper directly behind the home position, at cruise
-- height, feeding a composter.  Whole stacks of seeds the chest holds more
-- than twice the farm's planting of go into it (only seeds that aren't the
-- harvest: wheat and beetroot).  Bone meal is up to the hopper chain.
--------------------------------------------------------------------------
compostHopper = false
layoutReady = false      -- surplus means nothing until the layout is known

-- Is there a hopper directly behind home?  Called at home, cruise height.
function findCompostHopper()
    T.face(2)
    local ok, d = turtle.inspect()
    T.face(0)
    compostHopper = ok and d.name == "minecraft:hopper"
    return compostHopper
end

-- Empty slots in the compost hopper: how many whole stacks it can take.
-- Called at home facing forward, so the hopper is at the turtle's back.
function hopperSlotsFree()
    local h = peripheral and peripheral.wrap("back")
    if not (h and h.list and h.size) then return 0 end
    local n = h.size()
    for _ in pairs(h.list()) do n = n - 1 end
    return n
end

-- At the chest: take out whole stacks of surplus seeds, no more than
-- `room` stacks (what the hopper has space for).  Returns whether the
-- turtle now carries some for the hopper, and whether there is surplus
-- left in the chest after that.
function pullSurplusSeeds(room)
    local any, more = false, false
    for _, c in pairs(CROPS) do
        local have = c.compost and T.countContainer(CHEST_SIDE, c.seed)
        local surplus = have and math.floor((have - 2 * plantedWith(c.seed)) / 64) or 0
        local stacks = math.min(room, surplus)
        if surplus > stacks then more = true end
        if stacks > 0 then
            room = room - stacks
            local before = T.countItem(c.seed)
            restockItem(c.seed, before + 64 * stacks, c.name .. " seeds", true)
            if T.countItem(c.seed) > before then any = true end
        end
    end
    return any, more
end

-- At home, cruise height: drop everything over the seed target of
-- compostable seeds into the hopper behind, adding what went in to
-- `fed[name]`.  What doesn't fit stays on board and goes back to the
-- chest at the next visit.
function feedCompost(fed)
    T.face(2)
    local full = false
    for _, c in pairs(CROPS) do
        local extra = c.compost and (T.countItem(c.seed) - seedTarget(c.seed)) or 0
        for s = 16, 1, -1 do
            if extra <= 0 or full then break end
            local it = turtle.getItemDetail(s)
            if it and it.name == c.seed then
                local want = math.min(extra, it.count)
                turtle.select(s)
                turtle.drop(want)
                local moved = it.count - turtle.getItemCount(s)
                extra = extra - moved
                fed[c.name] = (fed[c.name] or 0) + moved
                full = moved < want
            end
        end
    end
    turtle.select(1)
    T.face(0)
end

-- From home at cruise height, sink until the chest is below (up to 3),
-- and tidy it up before anything is taken or moved.
function toChest()
    for _ = 1, 3 do
        if T.containerBelow() then break end
        if turtle.detectDown() or not T.down() then break end
    end
    if not T.containerBelow() then return false end
    T.compactContainer(CHEST_SIDE)
    return true
end

function dumpAtHome()
    goToCruise(0, 0)
    T.face(0)
    if toChest() then
        T.dumpDownWait(keepPolicy)               -- a full chest: wait for room
        if fuelGoal > 0 then T.refuelFrom(CHEST_SIDE, fuelGoal) end
        for _, seed in ipairs(SEEDS) do
            restockItem(seed, seedTarget(seed), (text.replace(text.stripPrefix(seed, "minecraft:") or seed, "_", " ")))
        end
        restockItem(DIRT, dirtNeeded(), "Dirt")
        restockBuckets()
        restockItem(BONE_MEAL, wantBoneMeal, "Bone meal")
        T.compactContainer(CHEST_SIDE)             -- leave it tidy too
    else
        print("No chest found below home; keeping items.")
    end
    T.toStartHeight()
end

-- Wait at home until `seconds` have passed, keeping the compost hopper
-- topped up with surplus seeds from the chest meanwhile: every
-- COMPOST_CHECK seconds, if the hopper has an empty slot, fill it.  Once
-- there's no surplus left it just sleeps out the rest.
COMPOST_CHECK = 10
function waitAndCompost(seconds)
    local wake = os.clock() + seconds
    if compostHopper and layoutReady then
        local fed, more = {}, true
        while more and os.clock() < wake do
            local room = hopperSlotsFree()     -- the hopper is behind us up here
            if room > 0 then
                local carrying = false
                if toChest() then
                    carrying, more = pullSurplusSeeds(room)
                    T.compactContainer(CHEST_SIDE)
                end
                T.toStartHeight()
                if carrying then feedCompost(fed) end
            end
            if more then sleep(math.min(COMPOST_CHECK, math.max(0, wake - os.clock()))) end
        end
        local parts = {}
        for _, name in ipairs(tables.sortedKeys(fed)) do
            if fed[name] > 0 then parts[#parts + 1] = fed[name] .. " " .. name .. " seeds" end
        end
        if #parts > 0 then
            print("Composted " .. table.concat(parts, ", ") ..
                (more and "; more to go next time." or "; no surplus left."))
        end
    end
    local left = wake - os.clock()
    if left > 0 then sleep(left) end
end

-- Wait at home until the tank holds `enough`, refuelling from the
-- inventory and the chest whenever something changes (or every 10 s).
function waitForFuel(enough)
    if T.hasFuel(enough) then return end
    print(string.format("Need %d fuel, have %d: put fuel (coal, charcoal, lava...) in the chest or the turtle.",
        enough, turtle.getFuelLevel()))
    while turtle.getFuelLevel() < enough do
        local timer = os.startTimer(10)
        repeat
            local ev, id = os.pullEvent()
        until (ev == "timer" and id == timer) or ev == "turtle_inventory" or ev == "key"
        T.refuelTo(math.max(enough, fuelGoal))
        if turtle.getFuelLevel() < enough and toChest() then
            T.refuelFrom(CHEST_SIDE, math.max(enough, fuelGoal))
        end
        T.toStartHeight()
    end
    print("Fuel: " .. turtle.getFuelLevel())
end

-- During a farming pass: if a fuel trip takes longer than this many
-- seconds, the rest of the pass is stale (crops behind the turtle have
-- ripened again meanwhile), so the trip raises RESTART_PASS instead of
-- going back, and the pass starts over from home.
restartAfter = nil
RESTART_PASS = {}

-- T.ensureFuel calls this before a move that would leave too little fuel
-- to get home: go home, empty out and refuel, then come back to the exact
-- spot and facing so whatever was under way carries on.  With no fuel to
-- be had it waits at home, not out in the field.
function fuelTrip()
    local x, y, z, d = T.pos.x, T.pos.y, T.pos.z, T.dir
    print(string.format("Low on fuel (%d) at %s: going home to refuel.", turtle.getFuelLevel(), T.posString()))
    local started = os.clock()
    dumpAtHome()
    local back = math.abs(x) + math.abs(z) + math.abs(travelY - y) + travelY
    waitForFuel(2 * back + T.cfg.fuelMargin + FUEL_WORK)
    local away = os.clock() - started
    if restartAfter and away >= restartAfter then
        print(string.format("Without fuel for %d min, longer than the %d min between passes: starting the pass over.",
            math.floor(away / 60), math.floor(restartAfter / 60)))
        error(RESTART_PASS, 0)
    end
    T.toY(travelY)
    T.goTo(x, z)
    T.toY(y)
    T.face(d)
    if T.pos.x ~= x or T.pos.y ~= y or T.pos.z ~= z then
        print(string.format("Couldn't get back to (%d,%d,%d) after refuelling; carrying on from %s.",
            x, y, z, T.posString()))
    end
end

-- Make sure the next tile's drops will fit, so nothing is left on the
-- ground: with fewer than `need` empty slots, go home and empty out first.
function ensureRoom(need)
    T.ensureRoom(need or ROOM, keepPolicy, dumpAtHome,
        "No room for more drops and nothing to empty (or no chest); harvest may spill.")
end

--------------------------------------------------------------------------
-- Strips and lanes
--
-- Farms are strips of farmland or cane separated by water lanes.  A learned gap
-- (missing ground, bare dirt) takes the kind of the line it lies in;
-- repair and clone rebuild tiles to match the map.  Lanes are built
-- floor+walls first, then watered.
--------------------------------------------------------------------------
function lineTally(filter)
    local t = { crop = 0, cane = 0, water = 0, other = 0 }
    for k, kind in pairs(tiles) do
        if t[kind] then                      -- gaps don't count
            local x, z = keyXZ(k)
            if filter(x, z) then t[kind] = t[kind] + 1 end
        end
    end
    return t
end

-- The kind a line of tiles is a strip of: crop, cane or water (or nil).
function classifyLine(t)
    local land = t.crop + t.cane
    if t.water == 0 and land > 0 and land >= t.other then
        return t.cane > t.crop and "cane" or "crop"
    end
    if land == 0 and t.water > 0 and t.water >= t.other then return "water" end
    return nil
end

-- Lane axis of a water tile: "z" if its column is water, else "x".
function laneAxis(x, z)
    local col = lineTally(function(px, pz) return px == x and pz ~= z end)
    if col.water > 0 and col.crop + col.cane == 0 then return "z" end
    return "x"
end

function sortFills(list)
    table.sort(list, function(a, b)
        if a.x ~= b.x then return math.abs(a.x) < math.abs(b.x) end
        return math.abs(a.z) < math.abs(b.z)
    end)
end

-- Settle the learning pass's gaps into the layout: a hole or bare dirt
-- takes the kind of the strip it lies in.  Bare dirt outside any strip is
-- farmed; a hole outside any strip is left alone.  Returns the number of
-- gaps settled.
function resolveLayout()
    local settled = {}
    for k, kind in pairs(tiles) do
        if kind == "hole" or kind == "dirt" then
            local x, z = keyXZ(k)
            local want = classifyLine(lineTally(function(px, pz) return px == x and pz ~= z end))
                      or classifyLine(lineTally(function(px, pz) return pz == z and px ~= x end))
            settled[k] = want or ((kind == "dirt") and "crop" or "other")
        end
    end
    local n = 0
    for k, kind in pairs(settled) do tiles[k] = kind; n = n + 1 end
    return n
end

-- Direction the farm's lanes run, "x" or "z" ("z" if it has none).
function farmAxis()
    for k, kind in pairs(tiles) do
        if kind == "water" then return laneAxis(keyXZ(k)) end
    end
    return "z"
end

-- Give every crop tile learned with nothing growing on it (bare farmland,
-- settled gaps) the crop most of its strip grows, else the crop most of
-- the farm grows, else wheat.  Returns the number of tiles assigned.
function assignCrops()
    local function majority(filter)
        local n, best = {}, nil
        for k, c in pairs(crops) do
            local x, z = keyXZ(k)
            if filter(x, z) then
                n[c] = (n[c] or 0) + 1
                if not best or n[c] > n[best] or (n[c] == n[best] and c < best) then best = c end
            end
        end
        return best
    end
    local alongX = farmAxis() == "x"
    local farmWide = majority(function() return true end)
    local assigned = {}
    for k, kind in pairs(tiles) do
        if kind == "crop" and not crops[k] then
            local x, z = keyXZ(k)
            assigned[k] = majority(function(px, pz)
                if alongX then return pz == z else return px == x end
            end) or farmWide or DEFAULT_CROP
        end
    end
    local count = 0
    for k, c in pairs(assigned) do crops[k] = c; count = count + 1 end
    return count
end

-- What each kind of tile is rebuilt as.
BUILD = { crop = "land", cane = "cane", water = "water" }

-- Repair planning: rebuild each damaged tile as the layout says.
function planRepair(damaged)
    pendingFills = {}
    for _, t in ipairs(damaged) do
        local kind = tiles[T.ckey(t.x, t.z)]
        pendingFills[#pendingFills + 1] = {
            x = t.x, z = t.z, want = BUILD[kind],
            axis = (kind == "water") and laneAxis(t.x, t.z) or nil,
        }
    end
    sortFills(pendingFills)
    return #pendingFills
end

-- Clone planning: every mapped tile is a target.
function planClone()
    pendingFills = {}
    for k, kind in pairs(tiles) do
        if BUILD[kind] then
            local x, z = keyXZ(k)
            pendingFills[#pendingFills + 1] = {
                x = x, z = z, want = BUILD[kind],
                axis = (kind == "water") and laneAxis(x, z) or nil,
            }
        end
    end
    sortFills(pendingFills)
    return #pendingFills
end

-- Does the map say (x,z) is lane?  Used to decide where walls go.
function isLane(x, z) return tiles[T.ckey(x, z)] == "water" end

----------------------------------------------------------------- water --
-- Lane tiles left unpoured between two sources, counted on to turn into
-- sources themselves; cleared once one is seen to have.
expected = {}

-- Already down at lane level (y = -1) and (x,z) further along the same
-- lane?  Then go straight there at that height instead of climbing out and
-- back in.  The cells above a lane are clear; crops beside it would block
-- the way, so only a run of lane tiles counts.  True once there.
function laneHop(x, z)
    if T.pos.y ~= -1 then return false end
    local dx, dz = x - T.pos.x, z - T.pos.z
    if dx ~= 0 and dz ~= 0 then return false end
    local n = math.abs(dx) + math.abs(dz)
    local sx = dx > 0 and 1 or dx < 0 and -1 or 0
    local sz = dz > 0 and 1 or dz < 0 and -1 or 0
    for i = 1, n do
        if not isLane(T.pos.x + sx * i, T.pos.z + sz * i) then return false end
    end
    for _ = 1, n do
        T.faceToward(T.pos.x + sx, T.pos.z + sz)
        if not T.forward() then return false end
        local k = T.ckey(T.pos.x, T.pos.z)
        if expected[k] and sourceBelow() then expected[k] = nil end
    end
    return true
end

-- Get down over lane tile (x,z), at y = -1: along the lane if already
-- down in it, else by way of cruise height.
function downAtLane(x, z)
    return laneHop(x, z) or (goToCruise(x, z) and T.down())
end

-- A lane tile that refills when scooped (two source neighbours), the one
-- nearest (nx,nz): the turtle when not given.
function regenTile(nx, nz)
    nx, nz = nx or T.pos.x, nz or T.pos.z
    local best, bestD, bestK
    for k in pairs(wet) do
        local x, z = keyXZ(k)
        local n = 0
        for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
            if wet[T.ckey(x + d[1], z + d[2])] then n = n + 1 end
        end
        local dist = math.abs(x - nx) + math.abs(z - nz)
        -- (ties by key, so it's the same tile every run)
        if n >= 2 and (not best or dist < bestD or (dist == bestD and k < bestK)) then
            best, bestD, bestK = { x = x, z = z }, dist, k
        end
    end
    return best
end

-- Would there be a regenerating tile with addK filled and removeK emptied?
function regenIf(addK, removeK)
    local a, r = wet[addK], wet[removeK]
    wet[addK], wet[removeK] = true, nil
    local ok = regenTile() ~= nil
    wet[addK], wet[removeK] = a, r
    return ok
end

borrowed = {}        -- lane sources emptied, to be refilled afterwards

-- Fill up to `want` empty buckets at (x,z) in one stop.  A regenerating
-- tile is waited on between scoops (the source comes back on the next
-- water tick); otherwise it's scooped once.  A full bucket needs a slot of
-- its own unless it replaces the last empty one, so it stops when there's
-- nowhere to put one.  A regenerating tile that doesn't come back after
-- all goes on `borrowed`.  Stays down at lane level.  Returns how many were
-- filled.
function scoopAt(x, z, want, regen)
    local got = 0
    if downAtLane(x, z) then
        if sourceBelow() then expected[T.ckey(x, z)] = nil end
        for _ = 1, want * 4 do
            if got >= want or not T.selectItem(BUCKET) then break end
            if turtle.getItemCount() > 1 and T.freeSlots() == 0 then break end
            if sourceBelow() and turtle.placeDown() then
                got = got + 1
                if not regen then break end
            elseif regen then
                sleep(0.25)
            else
                break
            end
        end
        if regen and got > 0 and not sourceBelow() then
            sleep(0.5)
            if not sourceBelow() then
                wet[T.ckey(x, z)], expected[T.ckey(x, z)] = nil, nil
                borrowed[#borrowed + 1] = { x = x, z = z, want = "water", axis = laneAxis(x, z) }
            end
        end
    end
    return got
end

-- Hold at least n water buckets: fill empties at the regenerating lane
-- tile nearest `target` (or the turtle), as many as needed in one stop,
-- else fetch water buckets / buckets from the chest.  With a target and no
-- regenerating tile, water is moved from one of the farm's own sources to
-- the target when that creates one; the source it came from goes on
-- `borrowed` to be refilled afterwards.
function ensureWater(n, target)
    local function scoop()
        while T.countItem(WATER_BUCKET) < n and T.countItem(BUCKET) > 0 do
            local r = target and regenTile(target.x, target.z) or regenTile()
            if not r then return end
            if scoopAt(r.x, r.z, n - T.countItem(WATER_BUCKET), true) == 0 then
                wet[T.ckey(r.x, r.z)] = nil
                return
            end
        end
    end
    scoop()
    if T.countItem(WATER_BUCKET) < n and target and T.countItem(BUCKET) > 0 and not regenTile() then
        local tk, best = T.ckey(target.x, target.z), nil
        for k in pairs(wet) do
            if k ~= tk and regenIf(tk, k) then
                local x, z = keyXZ(k)
                local d = math.abs(x - target.x) + math.abs(z - target.z)
                if not best or d < best.d or (d == best.d and k < best.k) then best = { x = x, z = z, d = d, k = k } end
            end
        end
        if best and scoopAt(best.x, best.z, 1, false) > 0 then
            wet[T.ckey(best.x, best.z)] = nil
            borrowed[#borrowed + 1] = { x = best.x, z = best.z, want = "water", axis = laneAxis(best.x, best.z) }
        end
    end
    if T.countItem(WATER_BUCKET) < n then
        wantWaterBuckets = math.max(wantWaterBuckets, n)
        needWaterBuckets = math.max(needWaterBuckets, n)
        dumpAtHome()
        scoop()
    end
    return T.countItem(WATER_BUCKET) >= n
end

newGround = {}       -- crop/cane tiles that got a dirt wall; plant them

-- Prepare a lane tile: ground level clear, dirt floor beneath, dirt walls on
-- every side the map doesn't call lane.  Ends at cruise height.  Returns
-- true when ready for water, "mine" when a block fills the lane or sits
-- above it (see mineLanes), or false.
function prepLane(t)
    if not goToCruise(t.x, t.z) then return false end
    if not T.down() then return "mine" end               -- something above the lane
    local k = T.ckey(t.x, t.z)
    local g = below()
    if sourceBelow() then wet[k] = true; T.up(); return true end
    wet[k] = nil
    if g == WATER then T.up(); return true end           -- flowing: needs a bucket
    if g ~= "air" then T.up(); return "mine" end         -- dirt etc. in the lane
    if not T.down() then T.up(); return false end        -- now inside the trench
    local ok = true
    if below() == "air" then ok = placeDirtDown() end
    if ok then
        for d = 0, 3 do
            local nx, nz = t.x + T.DX[d], t.z + T.DZ[d]
            if not isLane(nx, nz) then
                T.face(d)
                if not turtle.detect() then
                    if T.selectItem(DIRT) and turtle.place() then
                        local nkind = tiles[T.ckey(nx, nz)]
                        if nkind == "crop" or nkind == "cane" then
                            newGround[#newGround + 1] = { x = nx, z = nz, kind = nkind }
                        end
                    else
                        ok = false
                    end
                end
            end
        end
    end
    T.up(); T.up()
    return ok
end

-- Dig out whatever fills these lane tiles, and anything sitting above
-- them, with the pickaxe (the hoe would only till dirt).  Returns the
-- tiles it cleared.
function mineLanes(list)
    if T.countItem(PICKAXE) == 0 then
        print(#list .. " lane tiles are filled in; give the turtle a diamond pickaxe to dig them out.")
        return {}
    end
    local cleared = {}
    T.withTool(PICKAXE, function()
        for _, t in ipairs(list) do
            ensureRoom()
            if goToCruise(t.x, t.z) then
                if turtle.detectDown() then turtle.digDown() end  -- crop level
                if T.down() then
                    local g = below()
                    if g ~= "air" and g ~= WATER then turtle.digDown(); g = below() end
                    if g == "air" or g == WATER then cleared[#cleared + 1] = t end
                    T.up()
                end
            end
        end
    end)
    return cleared
end

-- Pour one bucket at a prepared lane tile.  Pouring into flowing water
-- turns it into a source.  Stays down at lane level, so the next tile
-- along the lane is one move away.
function waterLane(t)
    if not downAtLane(t.x, t.z) then return false end
    local ok = false
    local g = below()
    if sourceBelow() then ok = true
    elseif (g == "air" or g == WATER) and T.selectItem(WATER_BUCKET) then ok = turtle.placeDown() end
    if ok then wet[T.ckey(t.x, t.z)] = true end
    return ok
end

-- Group water targets into lanes (same axis + same line), sorted along the lane.
function groupLanes(list)
    local lanes, order = {}, {}
    for _, t in ipairs(list) do
        local id = (t.axis == "z") and ("z" .. t.x) or ("x" .. t.z)
        if not lanes[id] then lanes[id] = {}; order[#order + 1] = id end
        table.insert(lanes[id], t)
    end
    for _, id in ipairs(order) do
        table.sort(lanes[id], function(a, b)
            if a.axis == "z" then return math.abs(a.z) < math.abs(b.z) end
            return math.abs(a.x) < math.abs(b.x)
        end)
    end
    return lanes, order
end

-- Build all pending water tiles.  Returns list of the ones not completed.
function buildLanes(list)
    local remaining = {}
    local lanes, order = groupLanes(list)
    for _, id in ipairs(order) do
        local lane = lanes[id]
        -- 1. floors and walls for the whole lane first, digging out any
        --    filled-in tiles with the pickaxe in one go
        local status, toMine = {}, {}
        for _, t in ipairs(lane) do
            status[t] = prepLane(t)
            if status[t] == "mine" then toMine[#toMine + 1] = t end
        end
        if #toMine > 0 then
            for _, t in ipairs(mineLanes(toMine)) do status[t] = prepLane(t) end
        end
        local prepped = {}
        for _, t in ipairs(lane) do
            if status[t] == true then prepped[#prepped + 1] = t else remaining[#remaining + 1] = t end
        end
        -- 2. water.  A tile already between two sources fills by itself:
        --    count it as water now (it may be the source to refill from)
        --    and check it at the end.  Need a regenerating source;
        --    bootstrap one if there is none.
        local function sides(t)
            if t.axis == "z" then return T.ckey(t.x, t.z - 1), T.ckey(t.x, t.z + 1) end
            return T.ckey(t.x - 1, t.z), T.ckey(t.x + 1, t.z)
        end
        local todo = {}
        for _, t in ipairs(prepped) do
            local k = T.ckey(t.x, t.z)
            if not wet[k] then
                local a, b = sides(t)
                if wet[a] and wet[b] then wet[k], expected[k] = true, true end
                todo[#todo + 1] = t
            end
        end
        if #todo > 0 and not regenTile() then
            if #todo >= 3 and ensureWater(2) then
                if waterLane(todo[1]) and waterLane(todo[3]) then
                    sleep(1)                                -- let tile 2 become a source
                    local mid = todo[2]
                    if goToCruise(mid.x, mid.z) and T.down() then
                        if sourceBelow() then wet[T.ckey(mid.x, mid.z)] = true end
                        T.up()
                    end
                    if not wet[T.ckey(mid.x, mid.z)] then waterLane(mid) end
                end
            end
        end
        -- Pour every other tile: one between two sources becomes a source
        -- by itself (vanilla infinite water), so with `alternate` a tile is
        -- skipped when the tiles on both sides along the lane hold water or
        -- will be poured.  Out of water, fill every bucket the rest of the
        -- lane can use at the source nearest the next tile: as the lane
        -- fills outward, that's the stretch just poured (often a skipped
        -- tile, which checks it), so each trip is short.
        local function pour(list, alternate)
            local inList, skip = {}, {}
            for _, t in ipairs(list) do inList[T.ckey(t.x, t.z)] = true end
            local function filled(k) return wet[k] or (inList[k] and not skip[k]) end
            if alternate then
                for _, t in ipairs(list) do
                    local a, b = sides(t)
                    local k = T.ckey(t.x, t.z)
                    if not wet[k] and isLane(keyXZ(a)) and isLane(keyXZ(b))
                       and filled(a) and filled(b) then
                        skip[k] = true
                    end
                end
            end
            -- a skipped tile counts as water once both sides are poured
            local function settle(t)
                local a, b = sides(t)
                for _, k in ipairs({ a, b }) do
                    if skip[k] and not wet[k] then
                        local x, z = keyXZ(k)
                        local s1, s2 = sides({ x = x, z = z, axis = t.axis })
                        if wet[s1] and wet[s2] then wet[k] = true; expected[k] = true end
                    end
                end
            end
            for i, t in ipairs(list) do
                local k = T.ckey(t.x, t.z)
                if not wet[k] and not skip[k] then
                    if T.countItem(WATER_BUCKET) == 0 then
                        local left = 0
                        for j = i, #list do
                            local kj = T.ckey(list[j].x, list[j].z)
                            if not wet[kj] and not skip[kj] then left = left + 1 end
                        end
                        local carry = T.countItem(BUCKET) + T.countItem(WATER_BUCKET)
                        ensureWater(math.max(1, math.min(left, carry)), t)
                    end
                    if T.countItem(WATER_BUCKET) > 0 and waterLane(t) then
                        settle(t)
                    else
                        remaining[#remaining + 1] = t
                    end
                end
            end
            -- check the tiles left to fill themselves that nothing has
            -- looked at yet, nearest (the far end, where the turtle is)
            -- first; pour any that didn't take
            local retry = {}
            for i = #list, 1, -1 do
                local t = list[i]
                local k = T.ckey(t.x, t.z)
                if expected[k] or (skip[k] and not wet[k]) then
                    if downAtLane(t.x, t.z) and sourceBelow() then
                        wet[k], expected[k] = true, nil
                    else
                        wet[k], expected[k] = nil, nil
                        retry[#retry + 1] = t
                    end
                end
            end
            if #retry > 0 then pour(retry, false) end
        end
        pour(todo, true)
        local refill = borrowed
        borrowed = {}
        pour(refill, false)
    end
    return remaining
end

------------------------------------------------------------------ land --
-- Make (x,z) farmland with its planned crop on it.  Handles air (needs
-- dirt), water (dirt replaces it), tillable ground and existing farmland.
function buildLand(t)
    if not (goToCruise(t.x, t.z) and T.down()) then return false end
    local g = below()
    if g == "air" or g == WATER then
        if placeDirtDown() then g = DIRT end
    end
    if TILLABLE[g] then turtle.digDown(); g = FARMLAND end
    T.up()
    if g ~= FARMLAND then return false end
    plantDown(CROPS[cropAt(T.ckey(t.x, t.z))].seed)
    return true
end

-- Make (x,z) cane ground with sugar cane planted on it.  Runs after the
-- lanes are rebuilt, since cane only takes with water beside it.
function buildCane(t)
    if not (goToCruise(t.x, t.z) and T.down()) then return false end
    local g = below()
    if g == "air" or g == WATER then
        if placeDirtDown() then g = DIRT end
    end
    T.up()
    if not CANE_GROUND[g] then return false end
    return plantDown(CANE) or below() == CANE
end

-- Work through pendingFills: land first (so lane walls exist), then lanes,
-- then cane (which needs the water).
function buildPending(label)
    if #pendingFills == 0 then return end
    local land, water, cane = {}, {}, {}
    for _, t in ipairs(pendingFills) do
        if t.want == "land" then land[#land + 1] = t
        elseif t.want == "cane" then cane[#cane + 1] = t
        else water[#water + 1] = t end
    end
    -- buckets: two to start a lane from scratch, one with a source to
    -- refill from, and up to LANE_BUCKETS to pour several tiles per trip
    needWaterBuckets = (#water == 0 and 0) or (regenTile() and 1 or 2)
    wantWaterBuckets = math.max(needWaterBuckets, math.min(#water, LANE_BUCKETS))
    if T.countItem(DIRT) < dirtNeeded() or lacksSeeds()
       or T.countItem(WATER_BUCKET) + T.countItem(BUCKET) < wantWaterBuckets then
        dumpAtHome()
    end
    if T.countItem(DIRT) == 0 then
        print(#pendingFills .. " tiles to " .. label .. " but no dirt in chest or inventory.")
        return
    end
    print(string.format("%s: %d land, %d water, %d cane tiles (%d dirt on board)",
        label, #land, #water, #cane, T.countItem(DIRT)))

    local remaining = {}
    for _, t in ipairs(land) do
        if T.countItem(DIRT) == 0 then dumpAtHome() end
        if not buildLand(t) then remaining[#remaining + 1] = t end
    end
    for _, t in ipairs(buildLanes(water)) do remaining[#remaining + 1] = t end
    for _, t in ipairs(cane) do
        if T.countItem(DIRT) == 0 then dumpAtHome() end
        if not buildCane(t) then remaining[#remaining + 1] = t end
    end
    -- a lane wall on a crop or cane tile is new ground: plant it now (from
    -- cruise height, through the air gap) instead of next pass
    for _, t in ipairs(newGround) do
        if goToCruise(t.x, t.z) then
            if t.kind == "cane" then plantDown(CANE)
            else workCrop(false, cropAt(T.ckey(t.x, t.z))) end
        end
    end
    newGround = {}
    pendingFills = remaining
    wantWaterBuckets, needWaterBuckets = 0, 0
    print(string.format("%s done: %d tiles still open.", label, #remaining))
end

--------------------------------------------------------------------------
-- Clone phase 1 (pickaxe): clear crop level, trench lanes, remove stone.
--------------------------------------------------------------------------
function clonePrepare()
    print("Clone phase 1: clearing and trenching with the pickaxe")
    local plan = T.serpentine(WIDTH, LENGTH)
    T.withTool(PICKAXE, function()
        for i, t in ipairs(plan) do
            local kind = tiles[T.ckey(t.x, t.z)]
            if BUILD[kind] then
                ensureRoom()
                if goToCruise(t.x, t.z) then
                    local c = below()
                    if c ~= "air" and not CROPS[c] and c ~= CANE then turtle.digDown() end  -- crop level
                    if T.down() then
                        local g = below()
                        if kind == "water" then
                            if sourceBelow() then wet[T.ckey(t.x, t.z)] = true
                            elseif g ~= "air" and g ~= WATER then turtle.digDown() end  -- trench
                        elseif kind == "cane" then
                            if g ~= "air" and g ~= WATER and not CANE_GROUND[g] then
                                turtle.digDown()                       -- stone etc.
                            end
                        else
                            if g ~= "air" and g ~= WATER and g ~= FARMLAND and not TILLABLE[g] then
                                turtle.digDown()                       -- stone etc.
                            end
                        end
                        T.up()
                    end
                end
            end
            if i % 50 == 0 then print(string.format("%d/%d cleared", i, #plan)) end
        end
    end)
end

--------------------------------------------------------------------------
-- Passes
--------------------------------------------------------------------------
function learnPass()
    print(string.format("Learning layout: %dx%d", WIDTH, LENGTH))
    tiles, crops, wet = {}, {}, {}
    travelY = CANE_TRAVEL_Y              -- cane could be anywhere until we know
    local counts = { crop = 0, cane = 0, water = 0, other = 0, hole = 0, dirt = 0 }
    local plan = T.serpentine(WIDTH, LENGTH)
    local gaps = {}
    for i, t in ipairs(plan) do
        local kind, crop, gap = "other", nil, false
        T.toY(travelY)
        if T.goTo(t.x, t.z) then kind, crop, gap = learnTile() end
        local k = T.ckey(t.x, t.z)
        tiles[k], crops[k] = kind, crop
        if kind == "water" and not gap then wet[k] = true end
        if gap then gaps[#gaps + 1] = { x = t.x, z = t.z } end
        counts[kind] = counts[kind] + 1
        if i % 50 == 0 then
            print(string.format("%d/%d scanned, %d crop tiles", i, #plan, counts.crop))
        end
        if T.inventoryFull() then dumpAtHome() end
    end
    local settled = resolveLayout()
    local guessed = assignCrops()
    saveMap()
    layoutReady = true
    travelY = countKind("cane") > 0 and CANE_TRAVEL_Y or 0
    print(string.format("Layout saved: %d crop, %d cane, %d water, %d other (%d gaps settled from their strips)",
        countKind("crop"), countKind("cane"), countKind("water"), countKind("other"), settled))
    print(string.format("Crops: %s (%d bare tiles given their strip's crop)", cropSummary(), guessed))
    -- gaps that settled into the farm (a hole outside any strip stays "other")
    local toFix = {}
    for _, t in ipairs(gaps) do
        if BUILD[tiles[T.ckey(t.x, t.z)]] then toFix[#toFix + 1] = t end
    end
    return toFix
end

-- Visiting order for a pass: every crop and cane tile (and lane tile, with lanes),
-- one line at a time along the lanes, each line entered from the end
-- nearest the previous line's last tile, so no line is flown back over
-- empty and lines with nothing to visit are skipped.
function passOrder(lanes)
    local alongX = farmAxis() == "x"
    local sx, w = T.sgn(WIDTH)
    local sz, l = T.sgn(LENGTH)
    local lines, span = alongX and l or w, alongX and w or l
    local order, lastJ = {}, 0           -- home sits at j = 0
    for i = 1, lines do
        local line = {}
        for j = 1, span do
            local x, z
            if alongX then x, z = j * sx, i * sz else x, z = i * sx, j * sz end
            local kind = tiles[T.ckey(x, z)]
            if kind == "crop" or kind == "cane" or (lanes and kind == "water") then
                line[#line + 1] = { x = x, z = z, j = j }
            end
        end
        if #line > 0 then
            local a, b, step = 1, #line, 1
            if math.abs(line[#line].j - lastJ) < math.abs(line[1].j - lastJ) then
                a, b, step = #line, 1, -1
            end
            for n = a, b, step do order[#order + 1] = line[n] end
            lastJ = line[b].j
        end
    end
    return order
end

-- Height each kind of tile is worked from: crops from cruise height, lanes
-- from crop level (to see the water), cane from one above cruise height
-- (above its bottom two blocks).
WORK_Y = { crop = 0, water = -1, cane = 1 }

-- Get to tile t at its working height.  Between neighbouring tiles worked
-- from the same height the turtle moves straight across; otherwise it
-- goes by travel height.  A third block of cane in the way is cut (that's
-- harvest, and it lands in the inventory).
function visit(t, kind)
    local y = WORK_Y[kind]
    if T.pos.y == y and math.abs(t.x - T.pos.x) + math.abs(t.z - T.pos.z) == 1 then
        T.faceToward(t.x, t.z)
        if kind == "cane" then
            local ok, d = turtle.inspect()
            if ok and d.name == CANE then turtle.dig() end
        end
        if T.forward() then return true end
    end
    if kind ~= "cane" then return goToCruise(t.x, t.z) end
    T.toY(travelY)
    if not T.goTo(t.x, t.z) then return false end
    while T.pos.y > y do
        if below() == CANE then turtle.digDown() end
        if not T.down() then return false end
    end
    return true
end

-- Is the water still there?  Called over a lane tile at cruise height or
-- already down at crop level.  Returns lane | dry | blocked; dry covers
-- no water, flowing water and a block filling the lane.
function checkLane(t)
    local k = T.ckey(t.x, t.z)
    if T.pos.y == 0 and not T.down() then wet[k] = nil; return "blocked" end
    if sourceBelow() then wet[k] = true; return "lane" end
    wet[k] = nil
    return "dry"
end

-- Bone meal the crop below until it's ripe, or the bone meal on board
-- runs out.  Returns how many were used.
function growCrop()
    local used = 0
    for _ = 1, MEAL_PER_TILE do
        local name, d = below()
        local c = CROPS[name]
        if not c or (d.state and tonumber(d.state.age) or 0) >= c.ripe then break end
        if not (T.selectItem(BONE_MEAL) and turtle.placeDown()) then break end
        used = used + 1
    end
    return used
end

mealUsed = 0             -- bone meal used by the last grow pass

-- One sweep over the farm.  The farming pass (harvest, no lanes) visits
-- crop tiles only; the repair inspection (no harvest, lanes) also checks
-- every lane tile.  Bare farmland and untilled dirt are planted either
-- way; that isn't damage.  With `grow`, crop tiles are bone mealed until
-- ripe before they're harvested and replanted (sugar cane is skipped:
-- bone meal doesn't grow it).  Returns the damaged tiles (ground or
-- water missing, or something in the way).
function farmPass(harvest, lanes, grow)
    local plan = passOrder(lanes)
    if grow then
        local only = {}
        for _, t in ipairs(plan) do
            if tiles[T.ckey(t.x, t.z)] == "crop" then only[#only + 1] = t end
        end
        plan, mealUsed = only, 0
    end
    local stats = { harvested = 0, planted = 0, growing = 0, empty = 0, lane = 0,
                    damaged = 0, dry = 0, blocked = 0, noseeds = 0 }
    local damaged, skipped, triedRestock, bare = {}, 0, {}, {}
    for i, t in ipairs(plan) do
        local k = T.ckey(t.x, t.z)
        local kind = tiles[k]
        if kind ~= "water" then ensureRoom() end
        if grow and T.countItem(BONE_MEAL) == 0 then
            dumpAtHome()                         -- fetch more
            if T.countItem(BONE_MEAL) == 0 then
                print("Out of bone meal; finishing the pass without it.")
                grow = false
            end
        end
        if visit(t, kind) then
            local r
            if kind == "water" then
                r = checkLane(t)
            else
                local work, seed
                if kind == "cane" then
                    work, seed = function() return workCane(harvest) end, CANE
                else
                    local crop = cropAt(k)
                    work, seed = function() return workCrop(harvest, crop) end, CROPS[crop].seed
                    if grow then mealUsed = mealUsed + growCrop() end
                end
                r = work()
                if r == "noseeds" and not triedRestock[seed] then
                    dumpAtHome()
                    triedRestock[seed] = true
                    if visit(t, kind) then r = work() end
                end
                if r == "noseeds" then bare[seed] = (bare[seed] or 0) + 1 end
            end
            stats[r] = stats[r] + 1
            if r == "damaged" or r == "dry" or r == "blocked" then damaged[#damaged + 1] = t end
        else
            skipped = skipped + 1
        end
        if i % 50 == 0 then
            print(string.format("%d/%d tiles, fuel %s", i, #plan, tostring(turtle.getFuelLevel())))
        end
    end
    T.toY(travelY)
    print(string.format("Harvested %d, planted %d, growing %d, empty %d, unreachable %d",
        stats.harvested, stats.planted, stats.growing, stats.empty, skipped))
    if #damaged > 0 then
        print(string.format("Damage: %d crop/cane tiles won't plant, %d lane tiles not a source, %d blocked",
            stats.damaged, stats.dry, stats.blocked))
    end
    for _, seed in ipairs(tables.sortedKeys(bare)) do
        print(string.format("Out of %s: %d tiles left bare. Put some in the chest.",
            (text.replace(text.stripPrefix(seed, "minecraft:") or seed, "_", " ")), bare[seed]))
    end
    return damaged
end

-- Repair mode: rebuild the damaged tiles to match the layout.  Starts and
-- ends at home.
function repair(damaged)
    print(#damaged .. " damaged tiles: repairing.")
    planRepair(damaged)
    buildPending("Repair")
    for n, t in ipairs(pendingFills) do
        if n > 8 then print("  ...and " .. (#pendingFills - 8) .. " more"); break end
        print(string.format("  still open: (%d,%d) %s", t.x, t.z, t.want))
    end
    pendingFills = {}                    -- the next pass finds them again
    dumpAtHome()
end

-- Bone meal the chest holds, counted from home; nil if it can't be read.
function chestBoneMeal()
    local n = toChest() and T.countContainer(CHEST_SIDE, BONE_MEAL)
    T.toStartHeight()
    return n
end

-- Bone meal a grow pass may need: near the worst case for every crop tile.
function mealNeeded()
    local n = 0
    for k, kind in pairs(tiles) do
        if kind == "crop" then n = n + CROPS[cropAt(k)].meal end
    end
    return n
end

-- After a farming pass, at home: while the chest holds enough bone meal
-- to grow the whole farm, do grow passes (bone meal every crop until
-- ripe, harvest, replant).  Stops if a pass uses none.
function growPasses()
    local need = mealNeeded()
    if need == 0 then return end
    while true do
        local have = chestBoneMeal() or 0
        if have < need then
            if have > 0 then
                print(string.format("Bone meal: %d in the chest, a grow pass needs %d.", have, need))
            end
            return
        end
        print(string.format("Grow pass: %d bone meal in the chest, up to %d needed.", have, need))
        wantBoneMeal = math.min(need, MAX_MEAL)
        dumpAtHome()                             -- pick it up
        farmPass(true, false, true)
        wantBoneMeal = 0
        dumpAtHome()                             -- put back what's left
        print("Grow pass used " .. mealUsed .. " bone meal.")
        if mealUsed == 0 then
            print("No bone meal took; not trying again this time.")
            return
        end
    end
end

-- Full repair pass: inspect every crop and lane tile (nothing harvested),
-- then rebuild whatever is damaged.  Starts and ends at home.
function fullRepair()
    print("Full repair pass: inspecting every tile")
    local damaged = farmPass(false, true)
    dumpAtHome()
    if #damaged > 0 then repair(damaged) else print("No damage found.") end
end

--------------------------------------------------------------------------
-- Heading check
--------------------------------------------------------------------------
-- The saved heading is only as good as the last save: a server stop
-- between a turn and its save, or a turtle put back by hand facing the
-- wrong way, leaves it facing other than it thinks, and it would work the
-- farm on the wrong axis.  So before working from a saved map, look at a
-- few farm tiles near the turtle (as learning does, changing nothing) and
-- see which way round they fit the map.
HEADING_PROBES = 5
HEADING_REACH = 4        -- probe tiles at most this far away

-- (x,z) turned r quarter turns to the right about (px,pz).
function turned(x, z, px, pz, r)
    local dx, dz = x - px, z - pz
    for _ = 1, r do dx, dz = dz, -dx end
    return px + dx, pz + dz
end

-- Does what learnTile saw fit a map tile of this kind (nil: off the map)?
-- Anything that isn't crop, cane or water fits the rest.
FARMED = { crop = true, cane = true, water = true }
function fits(seen, kind)
    if FARMED[kind] then return seen == kind end
    return not FARMED[seen]
end

-- The heading that fits: the one whose score is within a tile of all the
-- tiles seen (one off is allowed for: damage, a block left on the farm)
-- and two clear of every other; nil if none does.
function fittingHeading(score, seen)
    if seen < 3 then return nil end
    for r = 0, 3 do
        local clear = score[r] >= seen - 1
        for o = 0, 3 do
            if o ~= r and score[o] > score[r] - 2 then clear = false end
        end
        if clear then return r end
    end
    return nil
end

-- Returns true to carry on, with T.dir corrected if the tiles fit the map
-- only with the turtle facing another way; false if they don't fit any
-- way round.  Either way the turtle ends where it started.
-- The tiles looked at are the farm tiles nearest the turtle, as they lie
-- with the turtle facing each way in turn (from home, the wrong ways all
-- face off the farm), the saved heading first: if those fit, that's it.
function checkHeading()
    local px, py, pz = T.pos.x, T.pos.y, T.pos.z
    local near = {}
    for k, kind in pairs(tiles) do
        if FARMED[kind] then
            local x, z = keyXZ(k)
            local d = math.abs(x - px) + math.abs(z - pz)
            if d <= HEADING_REACH then near[#near + 1] = { x = x, z = z, d = d } end
        end
    end
    if #near < 3 then return true end          -- too few farm tiles nearby to tell
    table.sort(near, function(a, b)
        if a.d ~= b.d then return a.d < b.d end
        if a.x ~= b.x then return a.x < b.x end
        return a.z < b.z
    end)
    local score, seen, looked = { [0] = 0, 0, 0, 0 }, 0, {}
    local r
    local margin = T.cfg.margin
    T.cfg.margin = margin + HEADING_REACH           -- the turned tiles may lie off the farm
    for way = 0, 3 do
        for i = 1, math.min(HEADING_PROBES, #near) do
            -- where this tile is if the turtle faces `way` right of its save
            local x, z = turned(near[i].x, near[i].z, px, pz, (4 - way) % 4)
            local k = T.ckey(x, z)
            if not looked[k] then
                looked[k] = true
                T.toY(travelY)
                if T.goTo(x, z) then
                    local kind = learnTile()
                    seen = seen + 1
                    for o = 0, 3 do
                        if fits(kind, tiles[T.ckey(turned(x, z, px, pz, o))]) then score[o] = score[o] + 1 end
                    end
                end
            end
        end
        r = fittingHeading(score, seen)
        if r == 0 then break end
    end
    T.toY(travelY)
    local back = T.goTo(px, pz) and T.toY(py)
    T.cfg.margin = margin
    T.clearBlocked()
    if back and r == 0 then return true end
    if back and r then
        T.setDir((T.dir + r) % 4)
        print("The turtle faces " .. ({ "right of", "opposite", "left of" })[r]
            .. " the way it had saved; heading corrected from the farm map.")
        return true
    end
    print("The farm here doesn't match the saved map whichever way the turtle")
    print("faces, so its saved position can't be trusted. Carry it home, face it")
    print("along the farm, and run `farm reset --here`.")
    return false
end

--------------------------------------------------------------------------
-- Main
--------------------------------------------------------------------------
-- `farm reset`: home from wherever the saved position says, routing over
-- the saved farm's area at its travel height (above any cane), once the
-- heading is checked against the farm.  With no map yet (stopped while
-- learning) it climbs to cane height to be safe.
if doReset then
    local haveMap = loadMap()
    if haveMap then T.cfg.width, T.cfg.length = WIDTH, LENGTH end
    travelY = (not haveMap or countKind("cane") > 0) and CANE_TRAVEL_Y or 0
    T.goHome({ travelY = travelY, check = haveMap and checkHeading or nil })
    return
end

haveMap = (not forceLearn) and loadMap()
if haveMap and resolveLayout() + assignCrops() > 0 then saveMap() end   -- older maps
if haveMap and countKind("cane") > 0 then travelY = CANE_TRAVEL_Y end
layoutReady = haveMap and true or false
if (doClone or doRepair) and not haveMap then
    print("No saved layout to " .. (doClone and "clone" or "repair") .. ". Learn a farm first.")
    return
end
if not haveMap and not (WIDTH and LENGTH) then
    print("No saved layout. Usage: farm <width> <length> [repeatMinutes]")
    return
end
if forceLearn and not (WIDTH and LENGTH) then
    print("Usage: farm learn <width> <length> [repeatMinutes]")
    return
end

if not T.requireHome(forceHere, "farm") then return end
if savedSize and (forceLearn or not haveMap) then T.saveSettings(savedSize) end

T.cfg.width, T.cfg.length = WIDTH, LENGTH
perTile = doClone and 5 or CRUISE_MOVES_PER_TILE
fuelGoal = math.floor(math.abs(WIDTH * LENGTH) * perTile)
           + 2 * countKind("water")                   -- worst case: a dip per lane tile
           + 2 * countKind("cane")                    -- dropping down to check cane
           + math.abs(WIDTH) + math.abs(LENGTH) + 150
-- Set out with about a pass's worth, from the chest if need be; short of
-- that, go anyway with enough to make headway: the turtle comes home to
-- refuel before it could run dry.
T.refuelTo(fuelGoal)
if not T.hasFuel(fuelGoal) then
    if toChest() then T.refuelFrom(CHEST_SIDE, fuelGoal) end
    T.toStartHeight()
    waitForFuel(T.cfg.fuelMargin + FUEL_WORK)
    if turtle.getFuelLevel() < fuelGoal then
        print(string.format("Fuel %d of the ~%d a pass takes; will come home to refuel as needed.",
            turtle.getFuelLevel(), fuelGoal))
    end
end
-- a cloned layout isn't built yet, so there's nothing to check against
if haveMap and not doClone and not checkHeading() then return end
T.fuelTrip = fuelTrip

if haveMap and not doClone then
    for k, kind in pairs(tiles) do if kind == "water" then wet[k] = true end end
end

T.withTool(HOE, function()
    T.clearBlocked()
    T.inventoryLine("On board")
    if findCompostHopper() then
        print("Compost hopper behind home: surplus wheat and beetroot seeds go into it.")
    end
    if haveMap then print("Farm plan: " .. cropSummary()) end
    if doClone then
        print(string.format("Cloning saved %dx%d layout here (%d crop, %d water tiles)",
            WIDTH, LENGTH, countKind("crop"), countKind("water")))
        planClone()
        dumpAtHome()
        clonePrepare()
        buildPending("Clone")
        pendingFills = {}                -- the first pass finds what's left
    else
        dumpAtHome()
        T.inventoryLine("Kept on board")
        if not haveMap then
            local gaps = learnPass()
            dumpAtHome()
            -- learning saw every tile, so only its gaps need fixing
            if #gaps > 0 then
                T.clearBlocked()
                repair(gaps)
            end
        end
    end
    -- a cloned layout gets checked lanes and all once
    if doRepair or doClone then
        T.clearBlocked()
        fullRepair()
    end
    if doRepair then
        T.inventoryLine("Kept on board")
        return
    end
    while true do
        T.clearBlocked()
        restartAfter = REPEAT > 0 and REPEAT * 60 or nil
        local ok, damaged = pcall(farmPass, true, false)
        restartAfter = nil
        if not ok and damaged ~= RESTART_PASS then error(damaged, 0) end
        if ok then                           -- (else: start over, right away)
            dumpAtHome()
            if #damaged > 0 then
                -- missing ground: check the whole farm, lanes included
                T.clearBlocked()
                fullRepair()
            end
            growPasses()
            print("Pass complete. Fuel: " .. tostring(turtle.getFuelLevel()))
            T.inventoryLine("Kept on board")
            if REPEAT <= 0 then break end
            print("Sleeping " .. REPEAT .. " min (Ctrl+T to stop)")
            waitAndCompost(REPEAT * 60)
        end
    end
end)
