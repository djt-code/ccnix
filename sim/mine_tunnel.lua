-- sim/mine_tunnel.lua
--
-- `mine` digging tunnels through mixed rock: ore veins running out of the
-- walls, floor and ceiling (part of one beyond the reach the turtle may
-- stray), ore inside the tunnel, a tag-only modded ore, lava in a wall and
-- inside the tunnel, gravel that falls in from above.  Checks the tunnel
-- is clear, every ore in reach is mined and none beyond it, no lava
-- touches open space, valuables end up at the start and bulk in the
-- homes, and it never moves on an empty tank.  Then homes along a longer
-- tunnel (supplies carried forward, valuables collected on the way
-- back), lit by torches in wall niches with no floor block dark enough
-- for mobs (one niche opening into a cave gets a block to stand its torch
-- on); --no-lights; a Geo Scanner (lined up with the tunnel from the scan,
-- fetching ore further out, far fewer turns, coal first when low on
-- fuel); a crevasse across the tunnel, which it bridges so a player can
-- walk the floor; the survey (with a scanner: fewer lanes, then scans from
-- as few spots as cover the walls, floor and ceiling, all round a 6x6 and
-- two across a 24-wide tunnel); a cavern filling the last segment, bridged with filler
-- from the homes behind (and its scans still trusted); the far end of a
-- tunnel whose length is a multiple of the spacing lit; the walk out past water standing in the next
-- segment (left to that one's going-over, no walking the one before again); a tunnel with no length that runs out of chests, then
-- `mine --resume` once more chests are added (twice: the second time a
-- home holds more valuables than fit, and the most valuable come back),
-- `mine haul` bringing the rest back, `mine reset` to the last home and
-- `--resume` from there; bedrock; running short of fuel; `mine reset` from inside a vein; and a
-- tunnel to the left and down.
local PROJ = ...
package.path = PROJ .. "/turtle/?.lua;" .. PROJ .. "/sim/lib/?.lua;" .. package.path
local Mine = require("mineworld")
local run = Mine.runner(PROJ)
local P = Mine.P
local get, set, chest, ore, chestAt = Mine.get, Mine.set, Mine.chest, Mine.ore, Mine.chestAt
local setup, features, remember, stock = Mine.setup, Mine.features, Mine.remember, Mine.stock
local startAt, atStart, jobState = Mine.startAt, Mine.atStart, Mine.jobState
local check, logHas, contents = Mine.check, Mine.logHas, Mine.contents
local leftIn, checkFloor, checkLight = Mine.leftIn, Mine.checkFloor, Mine.checkLight
local checkOres, checkLava, checkStart, checkHomes = Mine.checkOres, Mine.checkLava, Mine.checkStart, Mine.checkHomes
local flow, settleWater, isWater, isOreBlock = Mine.flow, Mine.settleWater, Mine.isWater, Mine.isOreBlock

--------------------------------------------------------------------------
-- Scenarios
--------------------------------------------------------------------------
-- 1. a 12x3x3 tunnel, no homes (12 is under the spacing)
setup(stock(4, 64)); features(); remember()
startAt(); Mine.inv, Mine.files = {}, {}
FUEL, LOWEST, DRY, SPILLED = 1000, 1000, 0, 0
run("3", "3", "12")
check("tunnel clear", leftIn(0, 2, 0, 2, 1, 12) == 0, leftIn(0, 2, 0, 2, 1, 12) .. " blocks left")
checkOres(); checkLava(12); checkStart()
checkFloor(0, 2, -1, 1, 12)                         -- the gold ore was in it, at (2,-1,10)
check("back at the start", atStart())
check("never moved on an empty tank", DRY == 0, "tried " .. DRY)
check("nothing spilled", (SPILLED or 0) == 0, tostring(SPILLED or 0))
check("job done", jobState() == "done", tostring(jobState()))

-- 1l. the same with a bucket in the start chest: the lava sources, one in
--     the right wall and one in the tunnel, are taken up and burned (the
--     wall's hole filled as ever); the bucket comes back to the start
local stockB = stock(4, 64)
stockB[#stockB + 1] = { name = "minecraft:bucket", count = 1 }
setup(stockB); features(); remember()
startAt(); Mine.inv, Mine.files = {}, {}
FUEL, LOWEST, DRY, SPILLED = 1000, 1000, 0, 0
local burntBefore = BURNT["minecraft:lava_bucket"] or 0
run("3", "3", "12")
check("with a bucket: both lava sources burned for fuel", (BURNT["minecraft:lava_bucket"] or 0) - burntBefore == 2
    and logHas("Burned 2 lava sources"), tostring((BURNT["minecraft:lava_bucket"] or 0) - burntBefore))
check("the wall's lava spot filled, the tunnel's left open", get(3, 0, 3) ~= nil and get(3, 0, 3).name ~= "minecraft:lava"
    and get(1, 2, 9) == nil, tostring((get(3, 0, 3) or {}).name) .. ", " .. tostring((get(1, 2, 9) or {}).name))
check("tunnel clear", leftIn(0, 2, 0, 2, 1, 12) == 0, leftIn(0, 2, 0, 2, 1, 12) .. " blocks left")
checkLava(12)
local _, bt = contents(chestAt(0, 1, 0))
check("the bucket back in the start chest, empty", (bt["minecraft:bucket"] or 0) == 1 and not bt["minecraft:lava_bucket"],
    tostring(bt["minecraft:bucket"]) .. " buckets, " .. tostring(bt["minecraft:lava_bucket"]) .. " full")
check("back at the start", atStart())

-- 1b. no size: the settings' tunnel, 3x3 and 32 long unless they say
--     otherwise; a size given is saved in them
setup(stock(4, 64)); remember()
startAt(); Mine.inv, Mine.files = {}, {}
FUEL, LOWEST, DRY, SPILLED = 1000, 1000, 0, 0
run()
check("no size, no settings API: a 3x3 tunnel 32 long", leftIn(0, 2, 0, 2, 1, 32) == 0 and get(0, 0, 33) ~= nil,
    leftIn(0, 2, 0, 2, 1, 32) .. " blocks left")
local SAVED = {}
settings = {
    define = function() end,
    get = function(name) return SAVED[name] end,
    set = function(name, v) SAVED[name] = v end,
    save = function() SAVED.saved = true end,
}
SAVED["mine.width"], SAVED["mine.height"], SAVED["mine.length"], SAVED["mine.spacing"], SAVED["mine.lights"] = 2, 2, 6, 0, true
setup(stock(4, 64)); remember()
startAt(); Mine.inv, Mine.files = {}, {}
run()
check("no size: the one in the settings (2x2, 6 long)", leftIn(0, 1, 0, 1, 1, 6) == 0 and get(0, 0, 7) ~= nil
    and get(2, 0, 1) ~= nil and get(0, 2, 1) ~= nil)
setup(stock(4, 64)); remember()
startAt(); Mine.inv, Mine.files = {}, {}
run("2", "3", "5")
check("a size given is kept in the settings", SAVED["mine.width"] == 2 and SAVED["mine.height"] == 3
    and SAVED["mine.length"] == 5 and SAVED.saved)
setup(stock(4, 64)); remember()
startAt(); Mine.inv, Mine.files = {}, {}
run("2", "2")
check("and no length given is kept as 0, no end", SAVED["mine.length"] == 0)
settings = nil

-- 2. 50 long with homes every 16: supplies go forward, valuables come back
setup(stock(8, 128, 64)); features()
set(-1, 1, 20, ore("minecraft:diamond_ore"))       -- in the wall near home 1
set(3, 0, 40, ore("minecraft:emerald_ore"))        -- in the wall near home 2
set(-2, 0, 10, nil); set(-1, -1, 10, nil)          -- a cave behind and under the niche at z=10
remember()
startAt(); Mine.inv, Mine.files = {}, {}
FUEL, LOWEST, DRY, SPILLED, TRAVEL_DIGS = 200, 200, 0, 0, 0
run("3", "3", "50", "--spacing", "16")
check("tunnel clear", leftIn(0, 2, 0, 2, 1, 50) == 0, leftIn(0, 2, 0, 2, 1, 50) .. " blocks left")
check("room above each home's valuables chest, so a player can open it",
    not get(-1, 1, 16) and not get(-1, 1, 32) and not get(-1, 1, 48))
check("what it picked up joined its stack (it keeps its slots tidy)", SPLIT <= 2,
    SPLIT .. " pickups started a second part stack")
checkOres(); checkLava(50); checkFloor(0, 2, -1, 1, 50)
local tn = checkStart()
check("diamonds and emerald brought back", (tn["minecraft:diamond"] or 0) == 3 and (tn["minecraft:emerald"] or 0) == 1,
    (tn["minecraft:diamond"] or 0) .. " diamond, " .. (tn["minecraft:emerald"] or 0) .. " emerald")
checkHomes(16, 3)
checkLight(0, 2, -1, 1, 50)
local niches = {}
for z = 1, 50 do
    local b = get(-1, 0, z)
    if Mine.isTorch(b) then niches[#niches + 1] = z end
end
check("torches in wall niches every 19, none on a home", table.concat(niches, ",") == "10,29,49",
    "at z=" .. table.concat(niches, ","))
check("the niche over the cave got a block to stand the torch on", get(-1, -1, 10) ~= nil,
    tostring((get(-1, -1, 10) or {}).name))
check("back at the start", atStart())
check("never moved on an empty tank", DRY == 0, "tried " .. DRY)
check("nothing spilled", (SPILLED or 0) == 0, tostring(SPILLED or 0))
check("dug nothing on trips home and back", (TRAVEL_DIGS or 0) == 0, tostring(TRAVEL_DIGS or 0) .. " blocks")
check("job done", jobState() == "done", tostring(jobState()))

-- 3. no length, homes every 8, 5 chests: two homes, then out of chests
setup(stock(5, 64))
startAt(); Mine.inv, Mine.files = {}, {}
FUEL, LOWEST, DRY, SPILLED = 100, 100, 0, 0
run("2", "2", "--spacing", "8")
check("stopped: out of chests", logHas("Out of chests"))
check("tunnel dug to z=24", leftIn(0, 1, 0, 1, 1, 24) == 0 and get(0, 0, 25) ~= nil, leftIn(0, 1, 0, 1, 1, 24) .. " blocks left")
checkHomes(8, 2)
check("back at the start", atStart())
check("never moved on an empty tank", DRY == 0, "tried " .. DRY)
check("job can be resumed (stopped by itself)", jobState() == "stopped", tostring(jobState()))

-- 4. four more chests in the start chest: `mine --resume` takes them out
--    to home 2 and carries on, two more homes
for _, it in ipairs(stock(4, 0)) do table.insert(chestAt(0, 1, 0), it) end
startAt()
run("--resume")
check("resumed from home 2", logHas("Back at home 2"))
check("stopped: out of chests again", logHas("Out of chests"))
check("tunnel dug to z=40", leftIn(0, 1, 0, 1, 1, 40) == 0, leftIn(0, 1, 0, 1, 1, 40) .. " blocks left")
checkHomes(8, 4)
check("back at the start", atStart())
check("never moved on an empty tank", DRY == 0, "tried " .. DRY)

-- 4b. home 1 holds more than the turtle can carry: 10 stacks of string,
--     6 of raw iron and 2 of diamonds.  With two more chests it builds one
--     more home, then on the way back brings the diamonds and the iron and
--     as much string as fits, and says what it left
local h1 = chestAt(-1, 0, 8)
for i = 1, 10 do table.insert(h1, { name = "minecraft:string", count = 64 }) end
for i = 1, 6 do table.insert(h1, { name = "minecraft:raw_iron", count = 64 }) end
for i = 1, 2 do table.insert(h1, { name = "minecraft:diamond", count = 64 }) end
for _, it in ipairs(stock(2, 0)) do table.insert(chestAt(0, 1, 0), it) end
startAt()
run("--resume")
local _, got = contents(chestAt(0, 1, 0))
check("brought back every diamond and all the iron", (got["minecraft:diamond"] or 0) == 128 and (got["minecraft:raw_iron"] or 0) == 384,
    (got["minecraft:diamond"] or 0) .. " diamond, " .. (got["minecraft:raw_iron"] or 0) .. " raw iron, "
    .. (got["minecraft:string"] or 0) .. " string")
check("said what it left in home 1", logHas("No room to bring back %d+ items from home 1"))
local h1bulk = 0
for name, n in pairs(select(2, contents(chestAt(-1, 0, 8)))) do
    if not (name:find("string") or name:find("raw_iron") or name:find("diamond") or name:find("coal")
        or name:find("chest") or name:find("torch")) then h1bulk = h1bulk + n end
end
check("swapped nothing bulk into home 1's valuables chest to make room", h1bulk == 0, h1bulk .. " other items there")
check("back at the start", atStart())

-- 4c. `mine haul`: out to the last home (5) and back collecting, as many
--     trips as it takes, until home 1's string is all at the start.  Bulk
--     never goes in a valuables chest, nor back to the start: cobblestone
--     put in home 3's valuables chest goes down into its bulk chest
local BULK_NAMES = { cobblestone = true, cobbled_deepslate = true, andesite = true, diorite = true,
                     granite = true, tuff = true, gravel = true, stone = true, deepslate = true }
local function bulkIn(c)
    local n = 0
    for name, count in pairs(select(2, contents(c))) do
        if BULK_NAMES[name:gsub("^%a+:", "")] then n = n + count end
    end
    return n
end
table.insert(chestAt(-1, 0, 24), { name = "minecraft:cobblestone", count = 40 })
local h3bulk = bulkIn(chestAt(0, -1, 24))
local startBulk = bulkIn(chestAt(0, -1, 0))
FUEL = 500
run("haul")
local inVal = {}
for k = 1, 5 do
    local n = bulkIn(chestAt(-1, 0, k * 8))
    if n > 0 then inVal[#inVal + 1] = n .. " in home " .. k end
end
check("no bulk in any home's valuables chest", #inVal == 0, table.concat(inVal, ", "))
check("home 3's cobblestone went down into its bulk chest", bulkIn(chestAt(0, -1, 24)) == h3bulk + 40,
    h3bulk .. " -> " .. bulkIn(chestAt(0, -1, 24)))
check("carried no bulk back to the start", bulkIn(chestAt(0, -1, 0)) == startBulk
    and bulkIn(chestAt(0, 1, 0)) == 0, startBulk .. " -> " .. bulkIn(chestAt(0, -1, 0)))
local _, got2 = contents(chestAt(0, 1, 0))
local _, h1left = contents(chestAt(-1, 0, 8))
check("hauled the rest of home 1's string back", (got2["minecraft:string"] or 0) == 640 and not h1left["minecraft:string"],
    (got2["minecraft:string"] or 0) .. " string at the start")
check("said everything's at the start", logHas("All the valuables are at the start"))
local coalOut = 0
for k = 1, 5 do coalOut = coalOut + (select(2, contents(chestAt(-1, 0, k * 8)))["minecraft:coal"] or 0) end
check("left the supplies (the fuel stocks) in the homes", coalOut > 0, coalOut .. " coal in the homes")
check("back at the start", atStart())

-- 4d. stopped between homes 4 and 5: `mine reset` goes on to home 5 (the
--     last), and `mine --resume` carries on from there, not the start
P.x, P.y, P.z, P.d = 1, 1, 36, 0
Mine.files[".turtlepos"] = "1 1 36 0 flat"
run("reset")
check("reset to home 5 (z=40), facing its wall", P.x == 0 and P.y == 0 and P.z == 40 and P.d == 3)
for _, it in ipairs(stock(2, 0)) do table.insert(chestAt(-1, 0, 40), it) end   -- two more chests, out there
run("--resume")
check("resumed from home 5, not the start", not logHas("Back at home") and logHas("Built home 6"))
check("tunnel dug to z=48", leftIn(0, 1, 0, 1, 1, 48) == 0, leftIn(0, 1, 0, 1, 1, 48) .. " blocks left")
check("back at the start", atStart())

-- 5. bedrock across the tunnel at z=13: stops there and comes back
setup(stock(10, 64))
for x = 0, 1 do for y = 0, 1 do set(x, y, 13, { name = "minecraft:bedrock" }) end end
startAt(); Mine.inv, Mine.files = {}, {}
FUEL, DRY = 100, 0
run("2", "2", "--spacing", "8", "--new")
check("stopped at the bedrock", logHas("Can't get through at %(%d,%d,12%) %(minecraft:bedrock%)"))
check("back at the start", atStart())

-- 6. only a little fuel: stops while it can still get back
setup(stock(10, 6))
startAt(); Mine.inv, Mine.files = {}, {}
FUEL, LOWEST, DRY = 0, math.huge, 0                -- empty: all it has is 6 coal
run("3", "3", "--spacing", "16")
check("stopped: not enough fuel", logHas("Not enough fuel"))
check("back at the start", atStart())
check("never moved on an empty tank", DRY == 0, "tried " .. DRY)
check("got back with its margin of 30 left", LOWEST >= 30, "lowest after a move " .. LOWEST)

-- 6b. a crevasse 11 blocks across cuts through the tunnel, 20 deep and
--     open above: the turtle bridges it with bulk so a player can walk
--     across, and a cave pocket under the floor further on is filled too
setup(stock(6, 64))
for x = -6, 8 do for y = -20, 10 do for z = 20, 30 do set(x, y, z, nil) end end end
for x = 0, 2 do set(x, -1, 34, nil); set(x, -2, 34, nil) end
startAt(); Mine.inv, Mine.files = {}, {}
FUEL, DRY = 1000, 0
run("3", "3", "36", "--spacing", "16")
checkFloor(0, 2, -1, 1, 36)
check("back at the start", atStart())
check("never moved on an empty tank", DRY == 0, "tried " .. DRY)

-- 6c. as in game: a cavern takes up the whole last segment (z=33..48, 20
--     deep), with a Geo Scanner on board.  The rock its own segment gives
--     home 2's bulk chest is dripstone, so bridging the 5-wide floor
--     takes more filler than it carries and that chest has: it fetches
--     more from the homes behind; dripstone blocks are filler too; the
--     blocks it puts where it dug (floor fillings) don't make the scan
--     look turned; and the tunnel's last block, at a multiple of the
--     spacing with no home there, still gets its torch
do
    local st = stock(6, 64, 16)
    st[#st + 1] = { name = SCANNER, count = 1 }
    setup(st)
end
for x = -6, 10 do for y = -20, 10 do for z = 33, 48 do set(x, y, z, nil) end end end
for x = -6, 10 do for z = 33, 48 do set(x, 11, z, { name = "minecraft:dripstone_block" }) end end
for x = 0, 4 do set(x, -1, 34, { name = "minecraft:pointed_dripstone" }) end   -- stalagmites where it bridges
startAt(); Mine.inv, Mine.files = {}, {}
EQ = { left = "advancedperipherals:chunk_controller", right = "minecraft:diamond_pickaxe" }
FUEL, DRY, SCANS = 3000, 0, 0
run("5", "3", "48", "--spacing", "16")
checkFloor(0, 4, -1, 1, 48)
check("never short of filler: took more from the homes behind", not logHas("no bulk blocks left"))
check("the scan wasn't taken for turned by its own floor fillings", not logHas("heading looks off"))
checkLight(0, 4, -1, 1, 48)
check("back at the start", atStart())

-- 6d. 3x3, 48 long, homes every 16 (as in game): the last torch is due
--     at z=48, a multiple of the spacing, but no home is built at the
--     tunnel's end, so it goes there; the far end isn't left dark
setup(stock(6, 64, 16))
startAt(); Mine.inv, Mine.files = {}, {}
FUEL, DRY = 2000, 0
run("3", "3", "48", "--spacing", "16")
checkLight(0, 2, -1, 1, 48)

-- 7. stopped inside a vein (a server restart): `mine reset` digs back to
--    the tunnel and goes home
Mine.files["mine.job"] = "3 3 12 64 0 active"
P.x, P.y, P.z, P.d = -3, 1, 4, 3
Mine.files[".turtlepos"] = "-3 1 4 3 flat"
FUEL = 500
run("reset")
check("reset from a vein got home", atStart())

-- 8. a tunnel to the left and down: `mine -2 -2 6`
setup(stock(4, 64, 8)); features()
startAt(); Mine.inv, Mine.files = {}, {}
FUEL, DRY = 1000, 0
run("-2", "-2", "6")
checkLight(-1, 0, -2, 1, 6)
check("left-and-down tunnel clear", leftIn(-1, 0, -1, 0, 1, 6) == 0, leftIn(-1, 0, -1, 0, 1, 6) .. " blocks left")
checkFloor(-1, 0, -2, 1, 6)
check("nothing dug right of or above it", get(1, 0, 3) ~= nil and get(0, 1, 3) ~= nil)
check("back at the start", atStart())

-- 9. a tunnel 10 wide is too wide to light from one wall: torches on both
setup(stock(4, 64, 16))
startAt(); Mine.inv, Mine.files = {}, {}
FUEL, DRY = 2000, 0
run("10", "2", "30")
checkLight(0, 9, -1, 1, 30)
local left, right = 0, 0
for z = 1, 30 do
    if Mine.isTorch(get(-1, 0, z)) then left = left + 1 end
    if Mine.isTorch(get(10, 0, z)) then right = right + 1 end
end
check("torches on both walls", left > 0 and left == right, left .. " left, " .. right .. " right")
check("back at the start", atStart())

-- 10. --no-lights: torches in the chest, but it leaves them there and
--     says nothing about lighting
setup(stock(4, 64, 16))
startAt(); Mine.inv, Mine.files = {}, {}
FUEL, DRY = 1000, 0
run("3", "3", "20", "--no-lights")
local placed = 0
for x = -2, 4 do for z = 1, 20 do
    if Mine.isTorch(get(x, 0, z)) then placed = placed + 1 end
end end
local _, top = contents(chestAt(0, 1, 0))
check("no torches placed, all 16 still in the chest", placed == 0 and (top["minecraft:torch"] or 0) == 16,
    placed .. " placed, " .. (top["minecraft:torch"] or 0) .. " in the chest")
check("nothing said about lighting", not logHas("torch"))
check("back at the start", atStart())

-- 11. a Geo Scanner in the start chest (and a chunk controller on the
--     other side): the turtle swaps it in to scan, lines the scan up with
--     the tunnel, and fetches ore that doesn't touch the walls, up to 6
--     out, diamonds and coal as far as a scan reaches and their veins on
--     from there however far they go; it turns
--     far less than the same tunnel without one
local function scanWorld(withScanner)
    local st = stock(4, 64)
    if withScanner then st[#st + 1] = { name = SCANNER, count = 1 } end
    setup(st)
    set(-1, 1, 5, ore("minecraft:iron_ore"))                   -- touching the left wall
    set(-5, 1, 12, ore("minecraft:deepslate_gold_ore")); set(-5, 2, 12, ore("minecraft:deepslate_gold_ore"))
    set(7, 0, 20, ore("minecraft:coal_ore")); set(8, 0, 20, ore("minecraft:coal_ore"))
    set(-9, 1, 25, ore("minecraft:diamond_ore"))               -- 9 out: no scan reaches it
    -- (scans are from the tunnel's middle, x=1: they reach x=-7 and x=9)
    set(-7, 1, 22, ore("minecraft:deepslate_diamond_ore"))     -- 7 out: the edge of a scan
    set(-8, 1, 22, ore("minecraft:deepslate_diamond_ore"))     -- its vein goes on past the scan
    set(-9, 1, 22, ore("minecraft:deepslate_diamond_ore"))
    set(-9, 2, 22, ore("minecraft:deepslate_diamond_ore"))
    set(9, 1, 16, ore("minecraft:diamond_ore"))                -- 7 out of the right wall: the other edge
    set(-7, 1, 8, ore("minecraft:deepslate_gold_ore"))         -- 7 out, not diamond: too far
    set(-9, 1, 3, ore("minecraft:coal_ore"))                   -- 9 out: no scan reaches it
    set(-7, 1, 10, ore("minecraft:deepslate_coal_ore"))        -- 7 out: the edge of a scan
    set(-8, 1, 10, ore("minecraft:deepslate_coal_ore"))        -- its vein goes on past the scan
    set(-9, 1, 10, ore("minecraft:deepslate_coal_ore"))
    set(-9, 0, 10, ore("minecraft:deepslate_coal_ore"))
    set(3, 1, 15, { name = "minecraft:lava", level = 0 })       -- in the right wall
    set(-1, 0, 18, nil); set(-2, 0, 18, nil)                    -- a cave opening in the left wall
    startAt(); Mine.inv, Mine.files = {}, {}
    EQ = { left = "advancedperipherals:chunk_controller", right = "minecraft:diamond_pickaxe" }
    FUEL, DRY, SCANS = 2000, 0, 0
    run("3", "3", "30")
    return Mine.turns
end
local without = scanWorld(false)
WORLD_COORDS = true                     -- a scanner that gives world coordinates
scanWorld(true)
check("made sense of a scan in world coordinates, with no r/u/f (lined up from what's dug)",
    logHas("lined up") and not logHas("Geo scanner:"))
WORLD_COORDS = false
local withIt = scanWorld(true)
local function oreGone(x, y, z) return not isOreBlock(get(x, y, z)) end
check("lined the scan up with the tunnel", logHas("lined up"), SCANS .. " scans")
check("waited for the scanner to show up after equipping it", not logHas("Geo scanner:"))
check("iron touching the wall mined", oreGone(-1, 1, 5))
check("gold 5 out and coal 5-6 out fetched", oreGone(-5, 1, 12) and oreGone(-5, 2, 12) and oreGone(7, 0, 20) and oreGone(8, 0, 20))
check("diamond 9 out left", not oreGone(-9, 1, 25))
check("diamond 7 out (in the scan) mined, and its vein followed on past the scan",
    oreGone(-7, 1, 22) and oreGone(-8, 1, 22) and oreGone(-9, 1, 22) and oreGone(-9, 2, 22))
check("diamond 7 out of the right wall mined too (the scans are from the middle)", oreGone(9, 1, 16))
check("coal 9 out left", not oreGone(-9, 1, 3))
check("coal 7 out (in the scan) mined, and its vein followed on past the scan",
    oreGone(-7, 1, 10) and oreGone(-8, 1, 10) and oreGone(-9, 1, 10) and oreGone(-9, 0, 10))
check("gold 7 out left (only diamonds and coal go past 6)", not oreGone(-7, 1, 8))
checkLava(30)
check("tunnel clear", leftIn(0, 2, 0, 2, 1, 30) == 0, leftIn(0, 2, 0, 2, 1, 30) .. " blocks left")
checkFloor(0, 2, -1, 1, 30)
check("far fewer turns with the scanner", withIt < without * 0.6, withIt .. " turns, " .. without .. " without")
check("chunk controller still on, pickaxe back", EQ.left == "advancedperipherals:chunk_controller" and EQ.right == "minecraft:diamond_pickaxe")
local _, top = contents(chestAt(0, 1, 0))
check("scanner back in the start chest", (top[SCANNER] or 0) == 1)
check("back at the start", atStart())

-- 11c. a field of small deposits off the left wall, all in one scan:
--      it goes from one to the next where that's shorter than going back
--      to the tunnel in between, and picked-up items join their stacks
setup({ { name = SCANNER, count = 1 }, { name = "minecraft:chest", count = 4 }, { name = "minecraft:coal", count = 64 } })
local FIELD = { { -4, 1, 6 }, { -5, 1, 8 }, { -4, 0, 10 }, { -6, 2, 11 }, { -5, 1, 13 }, { -3, 2, 14 }, { -6, 0, 15 } }
for _, o in ipairs(FIELD) do set(o[1], o[2], o[3], ore("minecraft:iron_ore")) end
startAt(); Mine.inv, Mine.files = {}, {}
EQ = { right = "minecraft:diamond_pickaxe" }
FUEL, DRY, SCANS = 2000, 0, 0
local entries = 0
ONMOVE = function(x, y, z, nx, ny, nz)
    if x < 0 and nx >= 0 and nz >= 1 then entries = entries + 1 end
end
run("3", "3", "16")
ONMOVE = nil
local all = true
for _, o in ipairs(FIELD) do all = all and oreGone(o[1], o[2], o[3]) end
check("mined every deposit in the field", all)
check("went back into the tunnel from the field at most twice", entries <= 2, entries .. " times")
check("tunnel clear", leftIn(0, 2, 0, 2, 1, 16) == 0, leftIn(0, 2, 0, 2, 1, 16) .. " blocks left")
checkFloor(0, 2, -1, 1, 16)
check("back at the start", atStart())

-- 11e. torches knocked off after they're placed: a scan's fetch going
--      through a niche lit before the scan (gold 4 out level with the
--      z=48 niche, fetched by the scan at z=53), and a vein through the
--      block the z=48 torch hangs on (with and without a scanner; without,
--      it's found from a lane dug after the torch).  Each torch is put
--      back, and no floor block is left dark
local THROUGH = { { -4, 0, 48, "minecraft:gold_ore" } }
local UNDER = { { -1, 1, 48, "minecraft:iron_ore" }, { -2, 1, 48, "minecraft:iron_ore" },
                { -2, 0, 48, "minecraft:iron_ore" } }
for _, case in ipairs({ { "a fetch through a lit niche", true, THROUGH, "TORCHES_DUG" },
                        { "a vein under a torch, with a scanner", true, UNDER, "TORCHES_DROPPED" },
                        { "a vein under a torch, no scanner", false, UNDER, "TORCHES_DROPPED" } }) do
    setup(stock(4, 64, 64))
    if case[2] then table.insert(chestAt(0, 1, 0), { name = SCANNER, count = 1 }) end
    for _, o in ipairs(case[3]) do set(o[1], o[2], o[3], ore(o[4])) end
    startAt(); Mine.inv, Mine.files = {}, {}
    EQ = { right = "minecraft:diamond_pickaxe" }
    FUEL, DRY, SCANS, TORCHES_DUG, TORCHES_DROPPED = 2000, 0, 0, 0, 0
    run("3", "3", "60")
    local gone = 0
    for _, o in ipairs(case[3]) do if not isOreBlock(get(o[1], o[2], o[3])) then gone = gone + 1 end end
    check(case[1] .. ": the torch was knocked off, and put back", _G[case[4]] == 1
        and Mine.isTorch(get(-1, 0, 48)) and logHas("1 put back"),
        "dug " .. TORCHES_DUG .. ", dropped " .. TORCHES_DROPPED .. ", z=48: " .. tostring((get(-1, 0, 48) or {}).name))
    check(case[1] .. ": the ore mined", gone == #case[3], gone .. " of " .. #case[3])
    checkLight(0, 2, -1, 1, 60); checkFloor(0, 2, -1, 1, 60)
    check("back at the start", atStart())
end

-- 11d. water: the tunnel runs through an underground lake (its own
--      blocks water sources, with more round them) and then under a lake
--      above its ceiling.  Water flows back into what it digs, so it
--      fills the sources and seals what feeds them, and leaves a dry
--      tunnel that no water gets into, without going round in circles.
--      With a scanner, the water in what it dug doesn't make it think its
--      heading is off; with a little fuel in the tank and coal in the
--      chest, the coal it carries keeps it from going home to refuel
setup(stock(4, 64))
table.insert(chestAt(0, 1, 0), { name = SCANNER, count = 1 })
for x = -3, 5 do for y = -2, 4 do for z = 8, 13 do set(x, y, z, { name = "minecraft:water", level = 0 }) end end end
for x = -2, 4 do for y = 3, 5 do for z = 18, 23 do set(x, y, z, { name = "minecraft:water", level = 0 }) end end end
for x = -3, 5 do for z = 7, 24 do set(x, 6, z, { name = "minecraft:stone" }) end end
for _, it in ipairs({ { name = "minecraft:cobblestone", count = 64 }, { name = "minecraft:cobblestone", count = 64 } }) do
    table.insert(chestAt(0, -1, 0), it)                 -- bulk to seal with
end
startAt(); Mine.inv, Mine.files = {}, {}
EQ = { right = "minecraft:diamond_pickaxe" }
FUEL, DRY, PLACED, SCANS = 300, 0, 0, 0
WATERY = true
run("3", "3", "30")
WATERY = false
check("scanned, and never thought its heading was off", SCANS > 0 and not logHas("heading looks off"), SCANS .. " scans")
check("no trips home to refuel (it carries coal)", not logHas("Low on fuel"))
local wetIn, wetOpen = 0, 0
for x = -4, 6 do for y = -3, 6 do for z = 1, 31 do
    local b = get(x, y, z)
    if isWater(b) then
        if x >= 0 and x <= 2 and y >= 0 and y <= 2 then wetIn = wetIn + 1 end
        for _, d in ipairs({ { 1, 0, 0 }, { -1, 0, 0 }, { 0, 1, 0 }, { 0, -1, 0 }, { 0, 0, 1 }, { 0, 0, -1 } }) do
            if not get(x + d[1], y + d[2], z + d[3]) then wetOpen = wetOpen + 1 end
        end
    end
end end end
check("no water left in the tunnel", wetIn == 0, wetIn .. " blocks")
check("no water touching open space (sealed off)", wetOpen == 0, wetOpen .. " open faces")
check("tunnel clear", leftIn(0, 2, 0, 2, 1, 30) == 0, leftIn(0, 2, 0, 2, 1, 30) .. " blocks left")
checkFloor(0, 2, -1, 1, 30)
check("didn't go round in circles placing blocks", PLACED < 400, PLACED .. " blocks placed")
check("finished", logHas("^Done"))
check("back at the start", atStart())

-- 11e. a scan whose forward is really the turtle's right (as if its
--      heading were off): it says so and stops trusting scans
setup({ { name = SCANNER, count = 1 }, { name = "minecraft:chest", count = 4 }, { name = "minecraft:coal", count = 64 } })
startAt(); Mine.inv, Mine.files = {}, {}
EQ = { right = "minecraft:diamond_pickaxe" }
FUEL, DRY, SCANS = 2000, 0, 0
SCAN_TURN = 1
run("3", "3", "30")
SCAN_TURN = 0
check("a scan turned from its heading: said so, and skipped it", logHas("heading looks off"))
check("still dug the tunnel, by hand", leftIn(0, 2, 0, 2, 1, 30) == 0)
check("back at the start", atStart())

-- 11f. tunnelling past water in the walls (an aquifer right of it, at
--      every height) with torches: it never opens a block that touches
--      the water without standing in it, so water hardly gets in, and no
--      torch is washed away; with and without a scanner
local function wetWalls(withScanner)
    setup(stock(4, 64, 64))
    if withScanner then table.insert(chestAt(0, 1, 0), { name = SCANNER, count = 1 }) end
    table.insert(chestAt(0, -1, 0), { name = "minecraft:cobblestone", count = 64 })
    for x = 3, 6 do for y = -1, 3 do for z = 6, 30 do set(x, y, z, { name = "minecraft:water", level = 0 }) end end end
    for x = -1, 7 do for z = 5, 31 do set(x, 4, z, { name = "minecraft:stone" }); set(x, -2, z, { name = "minecraft:stone" }) end end
    startAt(); Mine.inv, Mine.files = {}, {}
    EQ = { right = "minecraft:diamond_pickaxe" }
    FUEL, DRY, PLACED, SCANS, WASHED, INGRESS = 3000, 0, 0, 0, 0, 0
    WATERY, BOX = true, { 0, 2, 0, 2 }
    run("3", "3", "36")
    WATERY, BOX = false, nil
    local wetIn = 0
    for x = 0, 2 do for y = 0, 2 do for z = 1, 36 do if isWater(get(x, y, z)) then wetIn = wetIn + 1 end end end end
    local torches = 0
    for x = -1, 3 do for z = 1, 36 do if Mine.isTorch(get(x, 0, z)) then torches = torches + 1 end end end
    check("no water got into the tunnel past the block being dug", INGRESS <= 3,
        INGRESS .. " times water flowed into an open tunnel block")
    check("no torch washed away", WASHED == 0 and torches >= 2, WASHED .. " washed away, " .. torches .. " up")
    check("no water left in the tunnel", wetIn == 0, wetIn .. " blocks")
    check("tunnel clear", leftIn(0, 2, 0, 2, 1, 36) == 0, leftIn(0, 2, 0, 2, 1, 36) .. " blocks left")
    check("back at the start", atStart())
end
wetWalls(false)
wetWalls(true)

-- 11g. glow lichen in the walls and ceiling, waterlogged, with water
--      behind it: it looks like a block, but it's a water source.  The
--      turtle replaces it with a bulk block (dry lichen too, as it isn't
--      solid), so no water gets in; with and without a scanner
local function lichenWorld(withScanner)
    setup(stock(4, 64, 64))
    if withScanner then table.insert(chestAt(0, 1, 0), { name = SCANNER, count = 1 }) end
    table.insert(chestAt(0, -1, 0), { name = "minecraft:cobblestone", count = 64 })
    local LICHEN = { name = "minecraft:glow_lichen", waterlogged = true }
    set(3, 1, 10, LICHEN); set(4, 1, 10, { name = "minecraft:water", level = 0 })
    set(4, 0, 10, { name = "minecraft:water", level = 0 }); set(4, 2, 10, { name = "minecraft:water", level = 0 })
    set(-1, 0, 16, { name = "minecraft:glow_lichen", waterlogged = true })     -- in the left wall at floor level
    set(1, 3, 22, { name = "minecraft:glow_lichen", waterlogged = true })      -- in the ceiling, water above
    set(1, 4, 22, { name = "minecraft:water", level = 0 }); set(1, 5, 22, { name = "minecraft:water", level = 0 })
    set(3, 0, 26, { name = "minecraft:glow_lichen" })                          -- dry, in the right wall
    startAt(); Mine.inv, Mine.files = {}, {}
    EQ = { right = "minecraft:diamond_pickaxe" }
    FUEL, DRY, WASHED, INGRESS, SCANS = 3000, 0, 0, 0, 0
    WATERY, BOX = true, { 0, 2, 0, 2 }
    run("3", "3", "30")
    WATERY, BOX = false, nil
    local wet, lichen = 0, 0
    for x = -2, 4 do for y = -1, 3 do for z = 1, 30 do
        local b = get(x, y, z)
        local touching = (x == -1 or x == 3 or y == -1 or y == 3) and (x >= -1 and x <= 3 and y >= -1 and y <= 3)
        if x >= 0 and x <= 2 and y >= 0 and y <= 2 and isWater(b) then wet = wet + 1 end
        if touching and b and b.name == "minecraft:glow_lichen" then lichen = lichen + 1 end
    end end end
    check("no lichen left in the walls, floor or ceiling", lichen == 0, lichen .. " left")
    check("no water got into the tunnel past the block being dug, and none's in it",
        INGRESS <= 3 and wet == 0, INGRESS .. " times water flowed in, " .. wet .. " blocks wet")
    check("no torch washed away", WASHED == 0)
    check("tunnel clear", leftIn(0, 2, 0, 2, 1, 30) == 0, leftIn(0, 2, 0, 2, 1, 30) .. " blocks left")
    check("back at the start", atStart())
end
lichenWorld(false)
lichenWorld(true)

-- 12. low on fuel with a scanner: the only fuel is coal 5 out from the
--     tunnel, which it goes for as soon as a scan finds it, and burns
setup({ { name = SCANNER, count = 1 }, { name = "minecraft:chest", count = 4 } })
for x = -5, -6, -1 do for y = 0, 1 do set(x, y, 10, ore("minecraft:coal_ore")) end end
startAt(); Mine.inv, Mine.files = {}, {}
EQ = { right = "minecraft:diamond_pickaxe" }
FUEL, LOWEST, DRY = 250, math.huge, 0
run("3", "3", "40")
check("went for the coal when low", logHas("going for the coal"))
check("mined all 4 coal ore", oreGone(-5, 0, 10) and oreGone(-6, 0, 10) and oreGone(-5, 1, 10) and oreGone(-6, 1, 10))
check("finished the tunnel on it", logHas("^Done"), logHas("Stopped") and "stopped" or "")
check("never moved on an empty tank", DRY == 0, "tried " .. DRY)
check("back at the start", atStart())

-- 13. `mine reset` when the saved heading is wrong (a turn the program
--     never recorded): by a wall in a finished part of the tunnel it sees
--     which way it really faces, and gets home
local function dugTunnel()
    setup(stock(4, 64))
    for x = 0, 2 do for y = 0, 2 do for z = 1, 40 do set(x, y, z, nil) end end end
    for _, z in ipairs({ 16, 32 }) do set(-1, 0, z, chest()); set(0, -1, z, chest()) end
    Mine.files = { ["mine.job"] = "3 3 0 16 2 active" }    -- homes at 16 and 32: dug to 32
    Mine.inv = {}
    EQ = { right = "minecraft:diamond_pickaxe" }
    FUEL, DRY = 500, 0
end
dugTunnel()
P.x, P.y, P.z, P.d = 0, 1, 20, 1                      -- really faces +x ...
Mine.files[".turtlepos"] = "0 1 20 0 flat"                 -- ... saved as facing ahead
local before = leftIn(-3, 5, -3, 5, 1, 41)
run("reset")
check("saw it really faces right, and corrected it", logHas("really faces 1, not 0"))
check("went to the last home (z=32), facing its wall", P.x == 0 and P.y == 0 and P.z == 32 and P.d == 3)
check("dug nothing on the way", leftIn(-3, 5, -3, 5, 1, 41) == before)
-- 13b. the same with --to-start: all the way back to the start
dugTunnel()
P.x, P.y, P.z, P.d = 0, 1, 20, 1
Mine.files[".turtlepos"] = "0 1 20 0 flat"
run("reset", "--to-start")
check("--to-start went to the start", atStart())
-- 13c. the last home (2, z=32) flooded: `mine reset --home 1` takes it
--      back a home, and `mine --resume` carries on from there, going over
--      the flooded segment again, drying it out and sealing it, on past
--      home 2 (there already: not built again) to the end
dugTunnel()
Mine.files["mine.job"] = "3 3 40 16 2 active"
for x = -2, 4 do for y = -1, 4 do for z = 22, 36 do
    if not chestAt(x, y, z) then set(x, y, z, { name = "minecraft:water", level = 0 }) end
end end end
for x = -2, 4 do for z = 21, 37 do set(x, 5, z, { name = "minecraft:stone" }) end end
for _, it in ipairs(stock(2, 64)) do table.insert(chestAt(-1, 0, 32), it) end     -- the supplies, out there
for _ = 1, 3 do table.insert(chestAt(0, -1, 16), { name = "minecraft:cobblestone", count = 64 }) end
P.x, P.y, P.z, P.d = 0, 0, 32, 3
set(0, 0, 32, nil)
Mine.files[".turtlepos"] = "0 0 32 3 flat"
FUEL = 3000
run("reset", "--home", "1")
FUEL = 400                              -- low: the fuel is out in home 2
check("reset --home 1 went back to home 1 (z=16), facing its wall", P.x == 0 and P.y == 0 and P.z == 16 and P.d == 3)
run("reset", "--home", "3")
check("there's no home 3: said so", logHas("no home 3"))
WATERY, PLACED = true, 0
run("--resume")
WATERY = false
check("resumed from home 1, and went on to home 2 without building it again",
    logHas("On to home 2") and not logHas("Built home 2"))
local wetIn, wetOpen = 0, 0
for x = -3, 5 do for y = -2, 6 do for z = 1, 41 do
    local b = get(x, y, z)
    if isWater(b) then
        if x >= 0 and x <= 2 and y >= 0 and y <= 2 then wetIn = wetIn + 1 end
        for _, d in ipairs({ { 1, 0, 0 }, { -1, 0, 0 }, { 0, 1, 0 }, { 0, -1, 0 }, { 0, 0, 1 }, { 0, 0, -1 } }) do
            if not get(x + d[1], y + d[2], z + d[3]) then wetOpen = wetOpen + 1 end
        end
    end
end end end
check("no water left in the tunnel", wetIn == 0, wetIn .. " blocks")
check("no water touching open space (sealed off)", wetOpen == 0, wetOpen .. " open faces")
check("tunnel dug to the end", leftIn(0, 2, 0, 2, 1, 40) == 0, leftIn(0, 2, 0, 2, 1, 40) .. " blocks left")
check("home 2's chests still there", chestAt(-1, 0, 32) and chestAt(0, -1, 32))
check("room above home 2's valuables chest (dug out of the flood, and dry)",
    not get(-1, 1, 32), tostring((get(-1, 1, 32) or {}).name))
check("fetched fuel from home 2 first, and carried some: no trips home to refuel",
    logHas("Fetching fuel from home 2") and not logHas("Low on fuel"))
check("finished", logHas("^Done"))
check("back at the start", atStart())
-- 13d. resumed at home 1 with water standing in the tunnel behind it
--      (flood water spreads back along the floor) and a scanner on board:
--      scans show the water where it dug, which is no sign its heading's off
dugTunnel()
Mine.files["mine.job"] = "3 3 40 16 2 active"
for x = 0, 2 do for y = 0, 2 do for z = 10, 16 do
    if not (x == 0 and y == 0 and z == 16) then set(x, y, z, { name = "minecraft:water", level = 0 }) end
end end end
for _, it in ipairs(stock(2, 64)) do table.insert(chestAt(-1, 0, 16), it) end
P.x, P.y, P.z, P.d = 0, 0, 16, 3
Mine.files[".turtlepos"] = "0 0 16 3 flat"
Mine.inv = { { name = SCANNER, count = 1 } }
FUEL, SCANS = 3000, 0
run("--resume")
check("scanned, and the water behind didn't make it think its heading was off",
    SCANS > 0 and not logHas("heading looks off"), SCANS .. " scans")
check("finished", logHas("^Done"))
-- 13e. a source in the right wall at floor level near home 2, its water
--      spread along the tunnel floor: walking out to home 2 (resumed from
--      the start) it follows the flow back to where it comes in and seals it
dugTunnel()
Mine.files["mine.job"] = "3 3 40 16 2 active"
for _, it in ipairs(stock(2, 64)) do table.insert(chestAt(0, 1, 0), it) end
table.insert(chestAt(0, -1, 0), { name = "minecraft:cobblestone", count = 64 })
set(3, 0, 26, { name = "minecraft:water", level = 0 })
WATERY = true
flow(3, 0, 26)
settleWater()
local spread = 0
for x = 0, 2 do for z = 1, 40 do if isWater(get(x, 0, z)) then spread = spread + 1 end end end
startAt()
Mine.files[".turtlepos"] = "0 0 0 0 flat"
FUEL = 3000
run("--resume")
WATERY = false
local left = 0
for x = 0, 2 do for y = 0, 2 do for z = 1, 40 do if isWater(get(x, y, z)) then left = left + 1 end end end end
check("followed the flow to the wall and sealed it: no water in the tunnel",
    spread > 5 and left == 0 and not isWater(get(3, 0, 26)), spread .. " floor blocks wet before, " .. left .. " after")
check("finished", logHas("^Done"))

-- 13k. resumed from the start, out to home 2 through a lit tunnel: the
--      torch at z=29 is gone (its niche empty), and water pours in through
--      a hole in the ceiling at the far side (x=2, z=22), out of sight of
--      the home's lane, flooding the tunnel and washing away the torch at
--      z=10.  On the way out it follows the water up to the hole and seals
--      it, and once the water's gone puts both torches back
dugTunnel()
Mine.files["mine.job"] = "3 3 40 16 2 active"
for _, it in ipairs(stock(2, 64, 16)) do table.insert(chestAt(0, 1, 0), it) end
table.insert(chestAt(0, -1, 0), { name = "minecraft:cobblestone", count = 64 })
set(-1, 0, 10, { name = "minecraft:wall_torch", on = "-2,0,10" }); set(-1, 0, 29, nil)
set(2, 3, 22, { name = "minecraft:water", level = 0 })
WATERY = true
flow(2, 3, 22)
settleWater()
local wetBefore = 0
for x = 0, 2 do for y = 0, 2 do for z = 1, 40 do if isWater(get(x, y, z)) then wetBefore = wetBefore + 1 end end end end
startAt()
Mine.files[".turtlepos"] = "0 0 0 0 flat"
FUEL = 3000
run("--resume")
WATERY = false
local wetAfter = 0
for x = 0, 2 do for y = 0, 2 do for z = 1, 40 do if isWater(get(x, y, z)) then wetAfter = wetAfter + 1 end end end end
check("said it's going over the tunnel on the way out", logHas("going over the tunnel for water getting in and lights out"))
check("both torches back, once the water was sealed off",
    Mine.isTorch(get(-1, 0, 29)) and Mine.isTorch(get(-1, 0, 10)))
checkLight(0, 2, -1, 1, 40)
check("followed the water to the hole in the ceiling and sealed it",
    wetBefore > 5 and wetAfter == 0 and not isWater(get(2, 3, 22)), wetBefore .. " tunnel blocks wet before, " .. wetAfter .. " after")
check("finished", logHas("^Done"))
check("back at the start", atStart())

-- 13l. the same walk out through a dry tunnel whose torches are all up
--      (hung in their niches: wall torches, as the game names them): it
--      leaves them be, digging none; and cobblestone in home 1's
--      valuables chest goes down into its bulk chest as it passes (stopped,
--      as if by Ctrl+T, at its first dig: past home 2, before the walk back,
--      which would move it too)
dugTunnel()
Mine.files["mine.job"] = "3 3 48 16 2 active"                -- (dug to 40: rock from 41)
for _, it in ipairs(stock(2, 64, 16)) do table.insert(chestAt(0, 1, 0), it) end
table.insert(chestAt(0, -1, 0), { name = "minecraft:cobblestone", count = 64 })
for _, z in ipairs({ 10, 29 }) do set(-1, 0, z, { name = "minecraft:wall_torch", on = "-2,0," .. z }) end
table.insert(chestAt(-1, 0, 16), { name = "minecraft:cobblestone", count = 20 })
startAt()
Mine.files[".turtlepos"] = "0 0 0 0 flat"
FUEL, TORCHES_DUG, STOP_AT_DIG = 3000, 0, 1
run("--resume")
STOP_AT_DIG = nil
check("stopped past home 2, at the first block of new tunnel", P.z > 32, "at z=" .. P.z)
check("left the torches that were up alone: none dug", (TORCHES_DUG or 0) == 0
    and Mine.isTorch(get(-1, 0, 10)) and Mine.isTorch(get(-1, 0, 29)), tostring(TORCHES_DUG) .. " dug")
local _, h1val = contents(chestAt(-1, 0, 16))
local _, h1bulk = contents(chestAt(0, -1, 16))
check("home 1's cobblestone moved down into its bulk chest on the way out",
    not h1val["minecraft:cobblestone"] and (h1bulk["minecraft:cobblestone"] or 0) >= 20,
    (h1val["minecraft:cobblestone"] or 0) .. " in the valuables chest, " .. (h1bulk["minecraft:cobblestone"] or 0) .. " below")

-- 13n. the walk out with a pool of water sources standing in home 2's
--      segment, just past home 1 (z=17..19), its water flowing back into
--      the segment before: going over that one it doesn't chase the water
--      into the next or walk its own again and again (the next segment's
--      going-over sees to it, straight after), and the tunnel ends up dry
dugTunnel()
Mine.files["mine.job"] = "3 3 32 16 2 active"
for _, it in ipairs(stock(2, 64, 16)) do table.insert(chestAt(0, 1, 0), it) end
table.insert(chestAt(0, -1, 0), { name = "minecraft:cobblestone", count = 64 })
table.insert(chestAt(0, -1, 16), { name = "minecraft:cobblestone", count = 64 })
for _, z in ipairs({ 10, 29 }) do set(-1, 0, z, { name = "minecraft:wall_torch", on = "-2,0," .. z }) end
for x = 0, 2 do for z = 17, 19 do set(x, 0, z, { name = "minecraft:water", level = 0 }) end end
WATERY = true
flow(1, 0, 18)
settleWater()
local function wetIn()
    local n = 0
    for x = 0, 2 do for y = 0, 2 do for z = 1, 40 do if isWater(get(x, y, z)) then n = n + 1 end end end end
    return n
end
local poolWet = wetIn()
startAt()
Mine.files[".turtlepos"] = "0 0 0 0 flat"
FUEL = 3000
run("--resume")
WATERY = false
check("water from the next segment: the tunnel dry after the walk out", poolWet > 20 and wetIn() == 0,
    poolWet .. " wet before, " .. wetIn() .. " after")
check("... without going over the segment before again and again (a dry walk out and back: 64 moves)",
    Mine.moves < 200, Mine.moves .. " moves")
check("finished", logHas("^Done"))

-- 13o. the walk out, its torch at z=29 gone, with water getting in through
--      the far wall beside that spot at two places (x=3, z=28 and 31),
--      so sealing one leaves water flowing from the other: standing there
--      the turtle keeps the water out of its own block, but it would flow
--      in once it moves on, and into the niche: no torch is put there
--      while water's beside it (none washed away), and once the water's
--      seen to, the torch goes back
dugTunnel()
Mine.files["mine.job"] = "3 3 32 16 2 active"
for _, it in ipairs(stock(2, 64, 16)) do table.insert(chestAt(0, 1, 0), it) end
table.insert(chestAt(0, -1, 0), { name = "minecraft:cobblestone", count = 64 })
table.insert(chestAt(0, -1, 16), { name = "minecraft:cobblestone", count = 64 })
set(-1, 0, 10, { name = "minecraft:wall_torch", on = "-2,0,10" })
set(3, 0, 28, { name = "minecraft:water", level = 0 }); set(3, 0, 31, { name = "minecraft:water", level = 0 })
WATERY, WASHED = true, 0
flow(3, 0, 28); flow(3, 0, 31)
settleWater()
startAt()
Mine.files[".turtlepos"] = "0 0 0 0 flat"
FUEL = 3000
run("--resume")
WATERY = false
check("water beside a torch spot: no torch put where the water washed it away", (WASHED or 0) == 0,
    tostring(WASHED) .. " washed")
check("... and the torch there once the water was seen to", Mine.isTorch(get(-1, 0, 29)),
    tostring((get(-1, 0, 29) or {}).name))
check("finished", logHas("^Done"))

-- 13g. dug already, with waterlogged glow lichen in the right wall at
--      floor level near z=24, its water spread along the floor: `mine
--      reset --home 1` and `mine --resume` go over the segment, follow
--      the water to the lichen and replace it, without going back and
--      forth over it
dugTunnel()
Mine.files["mine.job"] = "3 3 40 16 2 active"
for _, it in ipairs(stock(2, 64)) do table.insert(chestAt(-1, 0, 32), it) end
for _ = 1, 2 do table.insert(chestAt(0, -1, 16), { name = "minecraft:cobblestone", count = 64 }) end
set(3, 0, 24, { name = "minecraft:glow_lichen", waterlogged = true })
WATERY = true
flow(3, 0, 24)
settleWater()
P.x, P.y, P.z, P.d = 0, 0, 32, 3
Mine.files[".turtlepos"] = "0 0 32 3 flat"
FUEL = 3000
run("reset", "--home", "1")
run("--resume")
WATERY = false
local wetLeft = 0
for x = 0, 2 do for y = 0, 2 do for z = 1, 40 do if isWater(get(x, y, z)) then wetLeft = wetLeft + 1 end end end end
check("followed the water to the lichen and replaced it", wetLeft == 0 and (get(3, 0, 24) or {}).name ~= "minecraft:glow_lichen",
    wetLeft .. " tunnel blocks wet")
LICHEN_MOVES, LICHEN_TURNS = Mine.moves, Mine.turns
check("finished", logHas("^Done"))

-- 13h. dug already, with waterlogged lichen in the ceiling at the far end
--      of the segment (z=31), its water falling and spreading back along
--      the floor: going over the segment it wades through the water and
--      follows it to the lichen, rather than stepping back and forth
dugTunnel()
Mine.files["mine.job"] = "3 3 40 16 2 active"
for _, it in ipairs(stock(2, 64)) do table.insert(chestAt(-1, 0, 32), it) end
for _ = 1, 2 do table.insert(chestAt(0, -1, 16), { name = "minecraft:cobblestone", count = 64 }) end
set(1, 3, 31, { name = "minecraft:glow_lichen", waterlogged = true })
WATERY = true
flow(1, 3, 31)
settleWater()
local spreadH = 0
for x = 0, 2 do for z = 1, 40 do if isWater(get(x, 0, z)) then spreadH = spreadH + 1 end end end
P.x, P.y, P.z, P.d = 0, 0, 32, 3
Mine.files[".turtlepos"] = "0 0 32 3 flat"
FUEL = 3000
run("reset", "--home", "1")
run("--resume")
WATERY = false
local wetH = 0
for x = 0, 2 do for y = 0, 2 do for z = 1, 40 do if isWater(get(x, y, z)) then wetH = wetH + 1 end end end end
check("followed the water to the lichen in the ceiling and replaced it",
    spreadH > 5 and wetH == 0 and (get(1, 3, 31) or {}).name ~= "minecraft:glow_lichen",
    spreadH .. " floor blocks wet before, " .. wetH .. " after")
check("finished", logHas("^Done"))

-- 13f. stopped (Ctrl+T) partway through a segment; then a hole opens in
--      the ceiling over what's dug, with water above, which pours in and
--      spreads (washing torches away).  `mine reset` and `mine --resume`:
--      it carries on from where it stopped (from its log of the segment,
--      not going over the lanes it finished), and on the way along the
--      bottom of what it dug it follows the water up to the hole and
--      seals it, and puts the torches back
local function holeWorld()
    setup(stock(4, 64, 64))
    for _ = 1, 3 do table.insert(chestAt(0, -1, 0), { name = "minecraft:cobblestone", count = 64 }) end
    startAt(); Mine.inv, Mine.files = {}, {}
    EQ = { right = "minecraft:diamond_pickaxe" }
    FUEL, DRY = 3000, 0
end
holeWorld()
run("3", "3", "40")
local fullTurns = Mine.turns
-- stopped and resumed with no water about: about the turns of the whole
-- tunnel between the two runs (it doesn't go over the finished lanes again)
holeWorld()
STOP_AT_DIG = 200
run("3", "3", "40")
STOP_AT_DIG = nil
local firstTurns = Mine.turns
run("reset")
run("--resume")
check("stopped and resumed: about the turns of the whole tunnel, not more",
    firstTurns + Mine.turns < fullTurns * 1.25, firstTurns .. " + " .. Mine.turns .. " turns, " .. fullTurns .. " in one go")
check("tunnel clear", leftIn(0, 2, 0, 2, 1, 40) == 0, leftIn(0, 2, 0, 2, 1, 40) .. " blocks left")
holeWorld()
STOP_AT_DIG = 200
run("3", "3", "40")
STOP_AT_DIG = nil
for x = -1, 3 do for z = 5, 11 do set(x, 4, z, { name = "minecraft:stone" }) end end
set(1, 3, 8, { name = "minecraft:water", level = 0 })   -- the hole, water standing in it
set(1, 4, 8, { name = "minecraft:water", level = 0 })
WATERY, WASHED = true, 0
flow(1, 3, 8)
settleWater()
local wetBefore = 0
for x = 0, 2 do for z = 1, 40 do if isWater(get(x, 0, z)) then wetBefore = wetBefore + 1 end end end
run("reset")
WASHED = 0
run("--resume")
WATERY = false
local wetAfter = 0
for x = 0, 2 do for y = 0, 2 do for z = 1, 40 do if isWater(get(x, y, z)) then wetAfter = wetAfter + 1 end end end end
check("carried on from its log of the segment", logHas("Carrying on with lane"))
check("found the water from the ceiling, followed it up and sealed the hole",
    wetBefore > 3 and wetAfter == 0 and not isWater(get(1, 3, 8)),
    wetBefore .. " floor blocks wet before, " .. wetAfter .. " tunnel blocks after")
local torches = 0
for x = -1, 3 do for z = 1, 40 do if Mine.isTorch(get(x, 0, z)) then torches = torches + 1 end end end
check("no torch washed away after the resume, and they're all up", WASHED == 0 and torches >= 2,
    WASHED .. " washed away, " .. torches .. " up")
check("tunnel clear", leftIn(0, 2, 0, 2, 1, 40) == 0, leftIn(0, 2, 0, 2, 1, 40) .. " blocks left")
check("back at the start", atStart())

-- 13i. stopped before the middle column's bottom lane is done (lane 4 of
--      8), then lichen in the left wall at floor level leaks into the
--      finished left column: the resume goes over that column's floor
--      instead (the middle one's isn't dug yet), finds the water, and
--      seals the lichen
holeWorld()
STOP_AT_DIG = 200
run("3", "3", "40")
STOP_AT_DIG = nil
set(-1, 0, 10, { name = "minecraft:glow_lichen", waterlogged = true })
WATERY = true
flow(-1, 0, 10)
settleWater()
run("reset")
run("--resume")
WATERY = false
local wetI = 0
for x = 0, 2 do for y = 0, 2 do for z = 1, 40 do if isWater(get(x, y, z)) then wetI = wetI + 1 end end end end
check("went over the finished left column's floor, found the leak and sealed it",
    logHas("Carrying on with lane 4") and wetI == 0 and (get(-1, 0, 10) or {}).name ~= "minecraft:glow_lichen",
    wetI .. " tunnel blocks wet")

-- 13m. stopped partway through a segment by an older mine.lua, whose
--      progress file names a lane of another plan (no lane count in it):
--      the resume goes over the segment from its first lane instead, and
--      digs all of it
holeWorld()
STOP_AT_DIG = 200
run("3", "3", "40")
STOP_AT_DIG = nil
Mine.files["mine.seg"] = (Mine.files["mine.seg"] or ""):match("^(%d+ %d+ %-?%d+)")
run("reset")
run("--resume")
check("an older progress file (no lane count): the segment again from its first lane, all dug",
    logHas("planned differently") and not logHas("Carrying on with lane") and leftIn(0, 2, 0, 2, 1, 40) == 0,
    leftIn(0, 2, 0, 2, 1, 40) .. " blocks left")
check("back at the start", atStart())

-- 13j. resuming from the start of a long tunnel (6 homes 64 apart, all
--      dug): the walk out to home 6 and back takes more than a segment's
--      fuel, so the tank is filled from the start's chest for it rather
--      than giving up; the fuel stocks left in homes 1-5 are untouched
setup(stock(2, 64))
for x = 0, 2 do for y = 0, 2 do for z = 1, 384 do set(x, y, z, nil) end end end
for k = 1, 6 do
    set(-1, 0, k * 64, chest({ { name = "minecraft:coal", count = 8 } }))
    set(0, -1, k * 64, chest())
end
Mine.files = { ["mine.job"] = "3 3 384 64 6 active" }
Mine.inv = {}
EQ = { right = "minecraft:diamond_pickaxe" }
startAt()
Mine.files[".turtlepos"] = "0 0 0 0 flat"
FUEL, DRY = 500, 0
run("--resume")
check("filled up at the start and walked out to home 6 instead of giving up",
    logHas("Back at home 6") and not logHas("Not enough fuel"))
local stocks = 0
for k = 1, 5 do stocks = stocks + (select(2, contents(chestAt(-1, 0, k * 64)))["minecraft:coal"] or 0) end
check("the fuel stocks in homes 1-5 are still there", stocks == 40, stocks .. " coal")
check("finished and back at the start", logHas("^Done") and atStart())
check("never moved on an empty tank", DRY == 0, "tried " .. DRY)

-- 14. in the middle of a 3-wide tunnel every way is open, so it can't
--     tell: it goes by the (wrong) saved heading, but stops, finding no
--     home chests where it ends up (or digging through far more rock than
--     the way back could take)
dugTunnel()
P.x, P.y, P.z, P.d = 1, 1, 20, 1
Mine.files[".turtlepos"] = "1 1 20 0 flat"
before = leftIn(-20, 20, -3, 5, 1, 41)
run("reset")
local dug = before - leftIn(-20, 20, -3, 5, 1, 41)
check("stopped, saying its position or heading must be wrong", logHas("position or heading must be wrong"))
check("dug no more than its limit (12)", dug <= 12, dug .. " blocks")

-- 15. through a mineshaft: oak planks and a rail in the tunnel, a rail in
--     the floor, and a chest minecart standing where home 1's wall chest
--     goes (placing a chest at it only right-clicks it).  2 chests, 1
--     torch, 16 oak logs and a crafting table in the start chest: after
--     home 1 it's low on both, so it swaps the table in for the pickaxe
--     and crafts chests, and torches for the segments they start; the
--     wood goes forward, never into the tank
local st = stock(2, 128, 1)
st[#st + 1] = { name = "minecraft:oak_log", count = 16 }
st[#st + 1] = { name = "minecraft:crafting_table", count = 1 }
setup(st); remember()
for z = 5, 8 do set(1, 1, z, { name = "minecraft:oak_planks" }) end
set(1, 0, 12, { name = "minecraft:rail" })
set(2, -1, 14, { name = "minecraft:rail" })
set(-1, 0, 16, nil)
Mine.ENTITIES["-1,0,16"] = { item = "minecraft:chest_minecart",
    inv = { { name = "minecraft:iron_ingot", count = 3 }, { name = "minecraft:rail", count = 5 } } }
startAt(); Mine.inv, Mine.files = {}, {}
EQ = { left = "advancedperipherals:chunk_controller", right = "minecraft:diamond_pickaxe" }
FUEL, LOWEST, DRY, SPILLED = 200, 200, 0, 0
run("3", "3", "50", "--spacing", "16")
check("tunnel clear", leftIn(0, 2, 0, 2, 1, 50) == 0, leftIn(0, 2, 0, 2, 1, 50) .. " blocks left")
check("broke the minecart, so home 1's wall chest is a real chest", chestAt(-1, 0, 16) ~= nil
    and not Mine.ENTITIES["-1,0,16"])
checkHomes(16, 3)
tn = checkStart()
check("the chest minecart, what it held and the rails brought back",
    (tn["minecraft:chest_minecart"] or 0) == 1 and (tn["minecraft:iron_ingot"] or 0) == 3
        and (tn["minecraft:rail"] or 0) == 7,
    (tn["minecraft:chest_minecart"] or 0) .. " minecart, " .. (tn["minecraft:iron_ingot"] or 0) .. " iron, "
        .. (tn["minecraft:rail"] or 0) .. " rails")
check("crafted chests and torches", (CRAFTED["minecraft:chest"] or 0) >= 4 and (CRAFTED["minecraft:torch"] or 0) >= 2,
    (CRAFTED["minecraft:chest"] or 0) .. " chests, " .. (CRAFTED["minecraft:torch"] or 0) .. " torches")
checkLight(0, 2, -1, 1, 50)
local burnt = {}
for name, n in pairs(BURNT) do
    if not (name == "minecraft:coal" or name == "minecraft:charcoal") then burnt[#burnt + 1] = n .. " " .. name end
end
check("burnt nothing but coal", #burnt == 0, table.concat(burnt, ", "))
local _, last = contents(chestAt(-1, 0, 48))
check("the crafting table and the spare wood are in the last home",
    last["minecraft:crafting_table"] == 1 and ((last["minecraft:oak_log"] or 0) + (last["minecraft:oak_planks"] or 0)) > 0)
check("pickaxe back on, chunk controller still on",
    EQ.left == "advancedperipherals:chunk_controller" and EQ.right == "minecraft:diamond_pickaxe")
check("back at the start", atStart())
check("never moved on an empty tank", DRY == 0, "tried " .. DRY)
check("nothing spilled", (SPILLED or 0) == 0, tostring(SPILLED or 0))
check("job done", jobState() == "done", tostring(jobState()))

-- 16. wood: with a crafting table and few chests it seeks wood as it does
--     coal: a line of logs out of the left wall is followed to its end,
--     past the reach of an ordinary vein (no scanner), and with a scanner
--     logs that don't touch the tunnel are fetched.  Without a table, or
--     with chests enough for many homes, the logs are left
local function woodWorld(chests, withTable, withScanner)
    local st = stock(chests, 64, 16)
    if withTable then st[#st + 1] = { name = "minecraft:crafting_table", count = 1 } end
    if withScanner then st[#st + 1] = { name = SCANNER, count = 1 } end
    setup(st)
    for x = -1, -7, -1 do set(x, 1, 5, { name = "minecraft:oak_log" }) end   -- 7 out of the left wall
    set(-6, 0, 9, { name = "minecraft:spruce_log" }); set(-6, 1, 9, { name = "minecraft:spruce_log" })  -- 6 out, apart
    startAt(); Mine.inv, Mine.files = {}, {}
    EQ = { left = "advancedperipherals:chunk_controller", right = "minecraft:diamond_pickaxe" }
    FUEL, DRY, SPILLED, SCANS = 2000, 0, 0, 0
    run("3", "3", "12")
end
local function logsLeft(name, cells)
    local n = 0
    for _, c in ipairs(cells) do if (get(c[1], c[2], c[3]) or {}).name == name then n = n + 1 end end
    return n
end
local LINE = {}
for x = -1, -7, -1 do LINE[#LINE + 1] = { x, 1, 5 } end
local APART = { { -6, 0, 9 }, { -6, 1, 9 } }

woodWorld(4, true, false)
local _, top = contents(chestAt(0, 1, 0))
check("table, 4 chests, no scanner: followed the logs out of the wall to the end, 7 out",
    logsLeft("minecraft:oak_log", LINE) == 0 and (top["minecraft:oak_log"] or 0) >= 7,
    logsLeft("minecraft:oak_log", LINE) .. " left, " .. (top["minecraft:oak_log"] or 0) .. " in the start chest")
check("and without a scanner, nothing it didn't touch", logsLeft("minecraft:spruce_log", APART) == 2)
check("said how much wood it dug", logHas("Dug %d+ blocks of wood"))
check("nothing spilled", (SPILLED or 0) == 0, tostring(SPILLED or 0))

woodWorld(4, true, true)
check("with a scanner: fetched the logs that don't touch the tunnel too",
    logsLeft("minecraft:spruce_log", APART) == 0 and logsLeft("minecraft:oak_log", LINE) == 0,
    logsLeft("minecraft:spruce_log", APART) .. " spruce, " .. logsLeft("minecraft:oak_log", LINE) .. " oak left")

woodWorld(4, false, true)
check("no crafting table: no wood sought, the logs stay",
    logsLeft("minecraft:oak_log", LINE) == 7 and logsLeft("minecraft:spruce_log", APART) == 2)

woodWorld(64, true, true)
check("chests enough for many more homes: no wood sought",
    logsLeft("minecraft:oak_log", LINE) == 7 and logsLeft("minecraft:spruce_log", APART) == 2)

-- 17. the survey (with a Geo Scanner): the walls aren't looked at while
--     digging, so every column gets lanes every third row only (a 6x6:
--     18 lanes, not 24); once dug, it's scanned from as few spots as
--     cover its walls, floor and ceiling: a 6x6 from its middle, twice
--     along 24 blocks, reaching 5 past both walls, the floor and the
--     ceiling; lava behind a wall block in a row with no lane is sealed,
--     waterlogged lichen in another is replaced.  A tunnel 24 wide takes
--     two scans across, their spare reach out past the walls
local function surveyWorld(w, h, len, extra)
    local st = stock(8, 128, 32)
    st[#st + 1] = { name = SCANNER, count = 1 }
    setup(st)
    extra()
    startAt(); Mine.inv, Mine.files = {}, {}
    EQ = { left = "advancedperipherals:chunk_controller", right = "minecraft:diamond_pickaxe" }
    FUEL, DRY, SCANS = 6000, 0, 0
    run(tostring(w), tostring(h), tostring(len))
end
surveyWorld(6, 6, 24, function()
    set(-5, 2, 12, ore("minecraft:iron_ore"))                  -- 5 out of the left wall
    set(10, 3, 12, ore("minecraft:iron_ore"))                  -- 5 out of the right wall
    set(2, 10, 12, ore("minecraft:iron_ore"))                  -- 5 over the ceiling
    set(3, -5, 12, ore("minecraft:iron_ore"))                  -- 5 under the floor
    set(-1, 1, 6, { name = "minecraft:lava", level = 0 })      -- behind the left wall, row 1: no lane
    set(6, 4, 18, { name = "minecraft:glow_lichen", waterlogged = true })   -- the right wall, row 4
end)
check("6x6 with a scanner: 18 lanes, every third row in every column", logHas("18 lanes"))
check("scanned twice, from the middle", SCANS == 2, SCANS .. " scans")
check("ore 5 out past both walls, over the ceiling and under the floor fetched",
    oreGone(-5, 2, 12) and oreGone(10, 3, 12) and oreGone(2, 10, 12) and oreGone(3, -5, 12))
checkLava(24)
check("the waterlogged lichen in a row with no lane replaced", (get(6, 4, 18) or {}).name ~= "minecraft:glow_lichen"
    and get(6, 4, 18) ~= nil, tostring((get(6, 4, 18) or {}).name))
check("tunnel clear", leftIn(0, 5, 0, 5, 1, 24) == 0, leftIn(0, 5, 0, 5, 1, 24) .. " blocks left")
checkFloor(0, 5, -1, 1, 24)
checkLight(0, 5, -1, 1, 24)
check("back at the start", atStart())

surveyWorld(24, 3, 16, function()
    set(-5, 1, 8, ore("minecraft:iron_ore"))                   -- 5 out of the left wall
    set(28, 1, 8, ore("minecraft:iron_ore"))                   -- 5 out of the right wall
    set(11, -4, 8, ore("minecraft:iron_ore"))                  -- under the middle of the floor
end)
check("24 wide: two scans across it", SCANS == 2, SCANS .. " scans")
check("their spare reach past the walls: ore 5 out of each fetched, and under the middle",
    oreGone(-5, 1, 8) and oreGone(28, 1, 8) and oreGone(11, -4, 8))
checkFloor(0, 23, -1, 1, 16)
check("back at the start", atStart())
