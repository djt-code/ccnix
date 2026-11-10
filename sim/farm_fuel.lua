-- sim/farm_fuel.lua
--
-- Fuel: a turtle that starts nearly empty, with only a little coal in the
-- chest, learns and then clones a 7x16 farm.  It must never run dry out in
-- the field: before the tank gets too low to reach home it goes back,
-- refuels from the chest and returns to the same spot; with the chest out
-- of coal it waits at home until the "player" adds more.  Reports moves
-- tried on an empty tank (must be 0), trips home, waits and the lowest
-- fuel level seen.  The world is the farm_clone one.  Then farming passes
-- 5 min apart, where a wait for fuel longer than that starts the pass
-- over and a short one carries on.
local PROJ = ...
package.path = PROJ .. "/turtle/?.lua;" .. PROJ .. "/lib/?.lua;" .. PROJ .. "/sim/lib/?.lua;" .. package.path
local F = require("farmworld")
local run0 = F.runner(PROJ)

-- Waiting for fuel: on wait COAL_AT (the first, unless set), the "player"
-- puts 16 coal in the chest; each wait takes WAIT_SECONDS.
WAITS, COAL_AT, WAIT_SECONDS = 0, 1, 0
os.pullEvent = function()
    WAITS = WAITS + 1
    CLOCK = CLOCK + WAIT_SECONDS
    if WAITS > 50 then error("waited for fuel forever") end
    if WAITS == COAL_AT then
        for s = 1, F.CHEST_SIZE do
            if not F.chest[s] then F.chest[s] = { name = "minecraft:coal", count = 16 }; break end
        end
    end
    return "turtle_inventory"
end

-- A run, counting its trips home for fuel.
local function run(...)
    run0(...)
    TRIPS = 0
    for _, l in ipairs(F.log) do
        if l:find("going home to refuel") then TRIPS = TRIPS + 1 end
    end
end

local function report(what)
    local crops = F.cropCount()
    F.print(string.format("%s: moves=%d tried-on-empty=%d trips=%d waits=%d lowest=%d fuel now=%d bad lane tiles=%d crops=%d",
        what, F.moves, DRY, TRIPS, WAITS, LOWEST, FUEL, F.badLaneTiles(), crops))
end

local function noCoal()
    for s = 1, F.CHEST_SIZE do if F.chest[s] and F.chest[s].name == "minecraft:coal" then F.chest[s] = nil end end
    for s = 1, 16 do if F.inv[s] and F.inv[s].name == "minecraft:coal" then F.inv[s] = nil end end
end

F.build({ width = 7, length = 16, lanes = { 3, 6 } })
F.chest = { { name = "minecraft:wheat_seeds", count = 64 }, { name = "minecraft:wheat_seeds", count = 64 },
            { name = "minecraft:dirt", count = 64 }, { name = "minecraft:water_bucket", count = 1 },
            { name = "minecraft:water_bucket", count = 1 }, { name = "minecraft:bucket", count = 4 },
            { name = "minecraft:coal", count = 4 } }
F.inv = { { name = "minecraft:diamond_pickaxe", count = 1 } }
-- 1. learn with 20 fuel in the tank and 4 coal (320) in the chest: far
--    short of a pass
FUEL, LOWEST, DRY, WAITS = 20, 20, 0, 0
run("7", "16", "0")
report("LEARN")
-- 2. wipe the farm back to grass and clone it: 30 fuel, 6 coal in the chest
for x = 1, F.WIDTH do for z = 1, F.LENGTH do
    F.set(x, -2, z, { name = "minecraft:grass_block" }); F.set(x, -1, z, nil)
end end
noCoal()
for s = 1, F.CHEST_SIZE do if not F.chest[s] then F.chest[s] = { name = "minecraft:coal", count = 6 }; break end end
FUEL, LOWEST, DRY, WAITS = 30, 30, 0, 0
run("clone", "0")
report("CLONE")
-- 3-4. farming passes 5 min apart on the cloned farm, every crop ripe, with
--    fuel for about half a pass (130: just what it needs to set off) and no
--    coal in the chest: the trip home waits for the "player".  Waiting
--    longer than the 5 min between passes starts the pass over (the crops
--    it already did have ripened again); a short wait goes back to where it
--    left off.
local function passWithWait(label, coalAt)
    F.ripen()
    noCoal()
    FUEL, LOWEST, DRY, WAITS, COAL_AT, WAIT_SECONDS = 130, 130, 0, 0, coalAt, 10
    STOP_AT = CLOCK + coalAt * 10 + 60             -- stop in the first sleep after a pass
    run("5")
    STOP_AT, WAIT_SECONDS = nil, 0
    local over, passes = 0, 0
    for _, l in ipairs(F.log) do
        if l:find("starting the pass over") then over = over + 1 end
        if l:find("Pass complete") then passes = passes + 1 end
    end
    report(label)
    local _, ripe = F.cropCount()
    F.print(string.format("%s: waited %d s, started over %d, passes completed %d, ripe crops left %d",
        label, coalAt * 10, over, passes, ripe))
end
passWithWait("LONG WAIT", 40)
passWithWait("SHORT WAIT", 2)
