-- sim/mine_homes.lua
--
-- `mine` keeping going (ADR-0014): a home chest that fills grows into a
-- double chest (a second chest beside it joins it), the valuables one
-- picked up again once a haul has emptied it; a full bulk chest with no
-- chest to spare throws the overflow away instead of stopping; a full
-- valuables chest with nothing to grow sends it hauling to the start and
-- back out, and only a full start stops it; hauling every N homes;
-- waiting at the start for chests, carrying on once they're there; the
-- same tunnel asked for again carried on (not dug again), and a finished
-- one carried on when the length asked for is longer; and the supplies
-- coming home, at the end of a finished tunnel and with `mine haul
-- --supplies`.
local PROJ = ...
package.path = PROJ .. "/turtle/?.lua;" .. PROJ .. "/lib/?.lua;" .. PROJ .. "/sim/lib/?.lua;" .. package.path
local Mine = require("mineworld")
local run = Mine.runner(PROJ)
local get, set, chestAt = Mine.get, Mine.set, Mine.chestAt
local setup, stock = Mine.setup, Mine.stock
local startAt, atStart, jobState = Mine.startAt, Mine.atStart, Mine.jobState
local check, logHas, contents, leftIn = Mine.check, Mine.logHas, Mine.contents, Mine.leftIn

local function withSettings(chosen, fn)
    local defaults = {}
    settings = { define = function(name, o) defaults[name] = o.default end,
                 get = function(name) if chosen[name] ~= nil then return chosen[name] end return defaults[name] end,
                 set = function() end, save = function() end }
    fn()
    settings = nil
end

local function fresh(chests, coal, opts)
    opts = opts or {}
    setup(stock(chests, coal))
    if opts.bigStart then
        set(0, 1, 0, Mine.bigChest(chestAt(0, 1, 0)))
        set(0, -1, 0, Mine.bigChest())
    end
    startAt(); Mine.inv, Mine.files = {}, {}
    FUEL, LOWEST, DRY, SPILLED = 2000, 2000, 0, 0
end

local function count(c, name)
    local _, n = contents(c)
    return n[name] or 0
end

local function logCount(pat)
    local n = 0
    for _, l in ipairs(Mine.log) do if l:find(pat) then n = n + 1 end end
    return n
end

-- 30 kinds of ore in the last segment's floor-level lane, a stack each
-- of their own: more kinds than a single chest has slots, with the
-- supplies in it too
local KINDS = 30
local function oreField(z0)
    for i = 1, KINDS do
        local z = z0 + (i - 1) % 8
        local x = math.floor((i - 1) / 8) % 2
        local y = math.floor((i - 1) / 16)
        set(x, y, z, { name = "modded:gem" .. i .. "_ore" })
    end
end
local function oresAt(c)
    local _, n = contents(c)
    local k = 0
    for name in pairs(n) do if name:find("^modded:gem%d+_ore$") then k = k + 1 end end
    return k
end

--------------------------------------------------------------------------
-- 1. a 6x6 tunnel, homes every 48: the second segment's bulk (6x6x48,
--    over 1700 blocks) is more than one chest holds; with chests to
--    spare, home 1's bulk chest grows into a double chest (z=47 and 48),
--    nothing is thrown away, and it isn't a stop
fresh(10, 64, { bigStart = true })
run("6", "6", "96", "--spacing", "48")
local bulk1, bulk2 = chestAt(0, -1, 48), chestAt(0, -1, 47)
check("bulk chest grown: a double chest under the floor at z=47 and 48", bulk1 and bulk1 == bulk2 and Mine.sizeOf(bulk1) == 54
    and logHas("Home 1's bulk chest is a double chest now"), tostring(bulk1 and Mine.sizeOf(bulk1)))
check("its first half fuller than one chest holds", bulk1 and (function()
    local n = 0
    for s = 1, 54 do if bulk1[s] then n = n + 1 end end
    return n > 27
end)())
check("nothing thrown away, nothing spilled", (THROWN or 0) == 0 and (CHEST_SPILLED or 0) == 0,
    (THROWN or 0) .. " thrown, " .. (CHEST_SPILLED or 0) .. " spilled")
check("done, not stopped", jobState() == "done" and logHas("^Done") and logHas("Grew 1 home chests"), tostring(jobState()))
check("tunnel dug", leftIn(0, 5, 0, 5, 1, 96) == 0, leftIn(0, 5, 0, 5, 1, 96) .. " blocks left")
check("back at the start", atStart())
check("never moved on an empty tank", DRY == 0, "tried " .. DRY)

-- 2. the same with only the chests the home takes: nothing to grow it
--    with, so the bulk that doesn't fit is thrown away behind the home
--    (it would despawn) and the run goes on to the end
fresh(2, 64, { bigStart = true })
run("6", "6", "96", "--spacing", "48")
local thrownAt = Mine.GROUND["0,0,47"] or {}
check("no chest to spare: the bulk chest stays single", chestAt(0, -1, 47) == nil and Mine.sizeOf(chestAt(0, -1, 48)) == 27)
check("the overflow thrown away behind the home, and said", (THROWN or 0) > 0 and #thrownAt > 0
    and logHas("Threw away %d+ bulk blocks"), (THROWN or 0) .. " thrown")
check("done, not stopped", jobState() == "done" and not logHas("is full"), tostring(jobState()))
check("back at the start", atStart())

-- 3. 2x2, homes every 8, 24 long, 30 kinds of ore in the last segment
--    and 10 chests: home 2's valuables chest (supplies and all) runs out
--    of slots, grows into a double chest in the wall at z=15, and the
--    run ends done; what the turtle can't carry back stays in it
fresh(10, 64, { bigStart = true })
oreField(17)
run("2", "2", "24", "--spacing", "8")
local val2, val2b = chestAt(-1, 0, 16), chestAt(-1, 0, 15)
check("valuables chest grown: a double chest in the wall at z=15 and 16", val2 and val2 == val2b and Mine.sizeOf(val2) == 54
    and logHas("Home 2's valuables chest is a double chest now"))
check("room above the new half cleared, for a player to open it", get(-1, 1, 15) == nil)
check("done", jobState() == "done", tostring(jobState()))
check("every ore mined", leftIn(0, 1, 0, 1, 17, 24) == 0)
local atStart3 = oresAt(chestAt(0, 1, 0))
check("some kinds back at the start, the rest still in home 2 (more than it carries)",
    atStart3 > 0 and atStart3 < KINDS and logHas("No room to bring back %d+ items from home 2"), atStart3 .. " kinds at the start")

-- 3h. `mine haul`: the rest comes back, and home 2's valuables chest,
--     empty now, gives back its second half (the wall filled, nothing
--     spilled); the chest goes to the start with the supplies
local chestsBefore = count(chestAt(0, 1, 0), "minecraft:chest")
startAt()
run("haul")
check("all 30 kinds at the start", oresAt(chestAt(0, 1, 0)) == KINDS, oresAt(chestAt(0, 1, 0)) .. " kinds")
check("the grown half picked up, the wall filled", chestAt(-1, 0, 15) == nil and get(-1, 0, 15) ~= nil
    and Mine.sizeOf(chestAt(-1, 0, 16)) == 27, tostring((get(-1, 0, 15) or {}).name))
check("nothing spilled from it", (CHEST_SPILLED or 0) == 0, tostring(CHEST_SPILLED))
check("the chest back at the start", count(chestAt(0, 1, 0), "minecraft:chest") == chestsBefore + 1,
    chestsBefore .. " before, " .. count(chestAt(0, 1, 0), "minecraft:chest") .. " after")
check("back at the start", atStart())

-- 4. the same with only the 4 chests the two homes take: home 2's
--    valuables chest can't grow, so when it's full the turtle hauls
--    everything to the start and goes back out to carry on (mine.haul)
fresh(4, 64, { bigStart = true })
oreField(17)
run("2", "2", "24", "--spacing", "8")
check("full: hauled to the start and back out, then on", logHas("The valuables chest at home 2 %(z=16%) is full: back to the start")
    and logHas("Back out to home 2") and logHas("Hauled to the start %d+ times"))
check("done, not stopped", jobState() == "done" and logHas("^Done"), tostring(jobState()))
check("all 30 kinds at the start", oresAt(chestAt(0, 1, 0)) == KINDS, oresAt(chestAt(0, 1, 0)) .. " kinds")
check("back at the start", atStart())
check("never moved on an empty tank", DRY == 0, "tried " .. DRY)

-- 4s. ...with a single chest at the start, the haul can't put it all
--     there: the start's chest being full is what stops it
fresh(4, 64)
oreField(17)
run("2", "2", "24", "--spacing", "8")
check("the start full: stopped, saying so", jobState() == "stopped" and logHas("The chests at the start are full"),
    tostring(jobState()))

-- 4n. mine.haul off: a full valuables chest stops it, as before, and the
--     message names the chest
fresh(4, 64, { bigStart = true })
oreField(17)
withSettings({ ["mine.haul"] = false }, function() run("2", "2", "24", "--spacing", "8") end)
check("mine.haul off: stopped, naming the valuables chest", jobState() == "stopped"
    and logHas("The valuables chest at home 2 %(z=16%) is full%."), tostring(jobState()))

-- 5. mine.haulEvery = 1: after each home it builds, it hauls to the start
--    and goes back out
fresh(10, 64, { bigStart = true })
withSettings({ ["mine.haulEvery"] = 1 }, function() run("2", "2", "24", "--spacing", "8") end)
check("hauled after home 1 and after home 2", logCount("hauling every 1 homes") == 2 and logHas("Hauled to the start 2 times"),
    logCount("hauling every 1 homes") .. " hauls")
check("done", jobState() == "done", tostring(jobState()))
check("back at the start", atStart())

-- 6. out of chests for home 2: back to the start to wait (it says so),
--    two chests put in while it waits, and it goes back out and carries
--    on to the end
fresh(2, 64, { bigStart = true })
ONSLEEP = function()
    table.insert(chestAt(0, 1, 0), { name = "minecraft:chest", count = 2 })
    ONSLEEP = nil
end
run("2", "2", "24", "--spacing", "8")
check("waited at the start for chests, once", logHas("it needs 2 more chests") and logHas("Waiting at the start")
    and SLEPT == 60, tostring(SLEPT) .. " s")
check("then on: home 2 built, done", logHas("Built home 2") and jobState() == "done", tostring(jobState()))
check("tunnel dug", leftIn(0, 1, 0, 1, 1, 24) == 0, leftIn(0, 1, 0, 1, 1, 24) .. " blocks left")
check("back at the start", atStart())

-- 6n. mine.wait off: it stops instead, as before
fresh(2, 64, { bigStart = true })
withSettings({ ["mine.wait"] = false }, function() run("2", "2", "24", "--spacing", "8") end)
check("mine.wait off: out of chests stops it", jobState() == "stopped" and logHas("Stopped because: Out of chests"),
    tostring(jobState()))

-- 7. the same tunnel asked for again with --new: carried on from its
--    last home, the finished part gone over, not dug again; then a
--    fresh 32-long tunnel for comparison
fresh(10, 64, { bigStart = true })
run("2", "2", "16", "--spacing", "8")
check("first: 16 long, done", jobState() == "done")
startAt()
run("2", "2", "32", "--spacing", "8", "--new")
local carriedMoves = Mine.workMoves()
check("--new on the same tunnel: carried on, not started again", logHas("is the same one: carrying it on from home 1"))
check("its finished segment gone over, not dug again", logHas("Going over z=9..16"))
check("dug to 32, done", leftIn(0, 1, 0, 1, 1, 32) == 0 and jobState() == "done", tostring(jobState()))
fresh(10, 64, { bigStart = true })
run("2", "2", "32", "--spacing", "8")
check("...in fewer moves than digging all 32 afresh", carriedMoves < Mine.workMoves(),
    carriedMoves .. " carried on, " .. Mine.workMoves() .. " afresh")

-- 7d. dug to its length already: the same tunnel again says so and
--     nothing moves
startAt()
run("2", "2", "32", "--spacing", "8", "--new")
check("same tunnel, no longer: says it's dug already", logHas("dug to its length %(32%) already") and Mine.moves == 0)

-- 7r. `mine --resume` of the finished tunnel with a longer length in the
--     settings carries it on
startAt()
withSettings({ ["mine.width"] = 2, ["mine.height"] = 2, ["mine.length"] = 40 },
    function() run("--resume") end)
check("--resume, longer now: carried on to 40", logHas("Carrying the finished tunnel on: to 40")
    and leftIn(0, 1, 0, 1, 1, 40) == 0 and jobState() == "done", tostring(jobState()))

-- 8. supplies: a finished tunnel brings its last home's supplies back to
--    the start (but the fuel stock a home keeps); one that stopped
--    leaves them for --resume, and `mine haul --supplies` brings them
fresh(10, 64, { bigStart = true })
run("2", "2", "24", "--spacing", "8")
check("finished: the spare chests back at the start, none in the last home",
    count(chestAt(-1, 0, 16), "minecraft:chest") == 0 and count(chestAt(0, 1, 0), "minecraft:chest") == 6
    and logHas("The supplies are at the start"), count(chestAt(0, 1, 0), "minecraft:chest") .. " at the start")
check("the last home keeps its fuel stock", count(chestAt(-1, 0, 16), "minecraft:coal") == 8,
    tostring(count(chestAt(-1, 0, 16), "minecraft:coal")))
fresh(6, 64, { bigStart = true })
for x = 0, 1 do for y = 0, 1 do set(x, y, 21, { name = "minecraft:bedrock" }) end end
run("2", "2", "--spacing", "8")
check("stopped (bedrock): the supplies stay in the last home", jobState() == "stopped"
    and count(chestAt(-1, 0, 16), "minecraft:chest") == 2, tostring(count(chestAt(-1, 0, 16), "minecraft:chest")))
startAt()
run("haul", "--supplies")
check("`mine haul --supplies`: they come to the start", count(chestAt(-1, 0, 16), "minecraft:chest") == 0
    and count(chestAt(0, 1, 0), "minecraft:chest") == 2 and logHas("The supplies are at the start"),
    count(chestAt(0, 1, 0), "minecraft:chest") .. " at the start")
check("back at the start", atStart())

-- 9. walking back with its stack of filler kept (for water on the way),
--    at a home whose valuables chest holds bulk of the same kind and whose
--    bulk chest is full: what it took out of the valuables chest goes back
--    in, and no more (its own filler isn't put in a valuables chest)
fresh(4, 64, { bigStart = true })
for x = 0, 1 do for y = 0, 1 do set(x, y, 21, { name = "minecraft:bedrock" }) end end
withSettings({ ["mine.wait"] = false }, function() run("2", "2", "--spacing", "8") end)
local bulkHome2 = chestAt(0, -1, 16)
for s = 1, 27 do bulkHome2[s] = { name = "minecraft:dirt", count = 64 } end
table.insert(chestAt(-1, 0, 16), { name = "minecraft:cobblestone", count = 64 })
startAt()
withSettings({ ["mine.wait"] = false }, function() run("--resume") end)
check("bulk in a valuables chest, bulk chest full: only what it took goes back",
    count(chestAt(-1, 0, 16), "minecraft:cobblestone") == 64, tostring(count(chestAt(-1, 0, 16), "minecraft:cobblestone")))
check("back at the start", atStart())

-- 10. hauling far out (every 16 homes, z=256), carrying no coal (in the
--     field it goes into torches) and the start's top chest out of it (it
--     all went out with the supplies): the fuel in the tunnel's homes fills
--     the tank on the way back, and it goes back out without asking for
--     more at the start; the stock it took from a home is put back on the
--     way out from the start's top chest; only a tunnel with none left has
--     it ask
local function farHaul(emptyHomes, topUp)
    fresh(40, 200, { bigStart = true })
    FUEL, LOWEST = 300, 300
    local hauling = false
    ONPRINT = function(line)
        if hauling or not line:find("back to the start with the valuables", 1, true) then return end
        hauling = true
        for s = 1, 16 do
            if Mine.inv[s] and Mine.inv[s].name == "minecraft:coal" then Mine.inv[s] = nil end
        end
        for k = 1, 16 do
            if emptyHomes(k) then
                local c = chestAt(-1, 0, 16 * k)
                for s = 1, Mine.SIZE do
                    if c[s] and c[s].name == "minecraft:coal" then c[s] = nil end
                end
            end
        end
        if topUp then table.insert(chestAt(0, 1, 0), { name = "minecraft:coal", count = topUp }) end
    end
    withSettings({ ["mine.haulEvery"] = 16, ["mine.wait"] = false },
        function() run("2", "2", "264", "--spacing", "16") end)
    ONPRINT = nil
    return hauling
end
local function homeCoal(k) return count(chestAt(-1, 0, 16 * k), "minecraft:coal") end
local function never() return false end

local hauled = farHaul(never)
check("far haul, no coal on board: the supplies in its home take it back out, no wait at the start",
    hauled and logHas("Fuel from the homes on the way") and not logHas("put fuel in the start's top chest")
    and jobState() == "done", tostring(jobState()))
check("...the homes behind keep their stock", homeCoal(1) == 8 and homeCoal(15) == 8, homeCoal(1) .. ", " .. homeCoal(15))
check("back at the start", atStart())

hauled = farHaul(function(k) return k == 16 end)
check("its home out of fuel too: the stocks along the way take it back out",
    hauled and logHas("Fuel from the homes on the way") and not logHas("put fuel in the start's top chest")
    and jobState() == "done", tostring(jobState()))
check("...the furthest homes' stock used first, said to be short with none at the start to put back",
    homeCoal(15) < 8 and homeCoal(1) == 8 and logHas("short of their fuel stock"), homeCoal(15) .. ", " .. homeCoal(1))

hauled = farHaul(function(k) return k == 16 end, 64)
check("...with coal in the start's top chest, the stock is put back on the way out",
    hauled and logHas("Fuel from the homes on the way") and homeCoal(15) == 8 and not logHas("short of their fuel stock")
    and jobState() == "done", homeCoal(15) .. " in home 15")

hauled = farHaul(function() return true end)
check("no fuel left in the tunnel: it asks at the start", hauled
    and logHas("put fuel in the start's top chest") and jobState() == "stopped", tostring(jobState()))
