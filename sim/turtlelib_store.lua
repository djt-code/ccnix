-- sim/turtlelib_store.lua
--
-- tl.store (ADR-0008 phase 4): the chests at home, on sim/lib/buildworld's mock world (chests with their slots and the
-- peripheral that lists them).
--   * T.addChest / T.forgetChest / T.chests: the places kept in a data file other copies of the library read, whole
--     numbers and a real side asked for, one bulk chest; a chest known already (the same place, another stand, the
--     other half of a double chest) adds nothing and says which; holds that overlap another chest's said with the real
--     names both take (never ones made up from the globs), by chest, three of each list at most;
--   * T.catalogue: goes round the chests nearest first, writes down what each holds, comes back facing as before; a
--     chest that is gone or unreachable is reported and the rest are read; chests given as places are remembered;
--     opts.find adds the chests the map shows in a box;
--   * T.where: the chests with an item (a name, a glob, no namespace), nearest first, with the total;
--   * T.fetch: goes to the chest that has it, takes the count (across chests when it must), keeps the list right, tries
--     the next chest when one is empty behind its back, stops for no room, comes back;
--   * T.stow: an item into the chest that holds it, the rest into the bulk chest; what the job keeps, tools, fuel and
--     peripherals stay aboard unless opts.all (never the tools); a full chest and a missing bulk chest leave the item
--     aboard and say so, each item with its reason (every chest it was tried at: full, gone; no bulk chest) in info and
--     the why; nothing is ever dropped in the world;
--   * T.fetch and T.stow with opts.stay stay at the chest, T.stow's opts.keep;
--   * T.cfg.tools (ADR-0013 D5): T.stow and opts.all put away the looted tools it doesn't list, never the one
--     equipped, nor the pickaxe parked in the inventory while a crafting table or a hoe is on its side;
--   * T.recount: the known chest on a side read again into the list, with the time; no known chest there, a bad side;
--   * T.inventoryReport: every item across the chests and the turtle, totalled, with each count's age, as lines too,
--     sorted by name or count, matched; it moves nothing;
--   * T.prepare: one trip that puts away what isn't needed and fetches what is (home only at the end), refused before
--     moving when the chests' list is short, spec.partial, too few free slots after;
--   * chest categories (ADR-0013 D6.4): T.addChest's holds kept in the file (an old file without them still read, kept
--     through a re-zero), set, changed and cleared on a known chest; T.stow puts an item in a chest for it first, then
--     one that holds it already (never a chest for other things), then the bulk chest, a full one falling through;
--     T.sortChests moves what is in the wrong chest to where it belongs, says what moved and what couldn't (no room
--     where it belongs: put back), stops at opts.limit stacks, and goes nowhere when nothing is out of place;
--   * T.cfg.autoDump: setting it loads the module; the room running out on a dig sends the turtle to the chests and
--     back; with no chests it takes the junk chest's trip; a dump that did nothing is not tried again at once.
local PROJ = ...
package.path = PROJ .. "/turtle/?.lua;" .. PROJ .. "/lib/?.lua;" .. PROJ .. "/sim/lib/?.lua;" .. package.path
local M = require("mock")
local B = require("buildworld")
local text = require("text")
local realCheck = M.check
-- (a check's detail is only shown when it fails)
local function check(label, ok, detail) realCheck(label, ok, (not ok) and detail or nil) end

local CLOCK = 1000
os.epoch = function() return CLOCK * 1000 end
local CLK = 0
os.clock = function() CLK = CLK + 0.001; return CLK end
local SETTINGS, DEFAULTS = {}, {}
settings = {
    define = function(name, opts) DEFAULTS[name] = opts.default end,
    get = function(name) if SETTINGS[name] ~= nil then return SETTINGS[name] end return DEFAULTS[name] end,
}
print = function() end

local PICK = "minecraft:diamond_pickaxe"
local COBBLE, DIRT, PLANKS, STONE, IRON = "minecraft:cobblestone", "minecraft:dirt", "minecraft:oak_planks", "minecraft:stone", "minecraft:iron_ingot"
local W, T
local MODS = { "turtlelib", "tl.world", "tl.path", "tl.store" }

-- A new world with a floor, the pickaxe on the left and the library loaded afresh.  The chests, each with the cell the
-- turtle stands in and the side the chest is on:
--   A (3,0,1)   from (3,0,0) side 0      B (-3,0,1)  from (-3,0,0) side 0
--   C (0,0,-3)  from (0,0,-2) side 2     D (2,-1,-2) from (2,0,-2) side "down"
local function fresh(skipChests)
    W = B.new({ facing = "north" })
    W.install()
    EQ.left, EQ.right = PICK, nil
    for x = -5, 5 do for z = -5, 5 do W.set(x, -1, z, "minecraft:stone") end end
    if not skipChests then
        W.set(3, 0, 1, "minecraft:chest"); W.set(-3, 0, 1, "minecraft:chest")
        W.set(0, 0, -3, "minecraft:chest"); W.set(2, -1, -2, "minecraft:chest")
    end
    for _, name in ipairs(MODS) do package.loaded[name] = nil end
    T = require("turtlelib")
    return W, T
end
local A = { x = 3, y = 0, z = 0, side = 0 }
local Bc = { x = -3, y = 0, z = 0, side = 0 }
local C = { x = 0, y = 0, z = -2, side = 2 }
local D = { x = 2, y = 0, z = -2, side = "down" }
local function fill(x, y, z, items)
    local inv = W.get(x, y, z).inv
    for k in pairs(inv) do inv[k] = nil end
    for slot, it in pairs(items) do inv[slot] = { name = it[1], count = it[2] } end
end
local function chestHas(x, y, z, name)
    local n = 0
    for _, it in pairs(W.get(x, y, z).inv) do
        if it.name == name then n = n + it.count end
    end
    return n
end
local function carrying(name) return W.carrying(name) end
local function here(x, y, z, d)
    local P = W.S.P
    return P.x == (x or 0) and P.y == (y or 0) and P.z == (z or 0) and P.d == (d or 0)
        and T.pos.x == (x or 0) and T.pos.y == (y or 0) and T.pos.z == (z or 0) and T.dir == (d or 0)
end
local function stocked()
    fill(3, 0, 1, { [1] = { COBBLE, 64 }, [2] = { PLANKS, 40 } })
    fill(-3, 0, 1, { [1] = { STONE, 10 }, [2] = { PLANKS, 5 } })
    fill(0, 0, -3, { [1] = { DIRT, 30 } })
    fill(2, -1, -2, { [1] = { IRON, 7 } })
end
local function setUp()
    fresh()
    stocked()
    check("addChest A", T.addChest(A.x, A.y, A.z, A.side))
    T.addChest(Bc.x, Bc.y, Bc.z, Bc.side)
    T.addChest(C.x, C.y, C.z, C.side, true)
    T.addChest(D.x, D.y, D.z, D.side)
end
local function fileText()
    local f = fs.open(T.dataPath(".chests"), "r")
    if not f then return nil end
    local s = f.readAll()
    f.close()
    return s
end
local function line(chests, x, z, side)
    for _, c in ipairs(chests) do
        if c.x == x and c.z == z and c.side == side then return c end
    end
end

--------------------------------------------------------------------------
-- The list of chests
--------------------------------------------------------------------------
do
    fresh()
    check("no chests to begin with", #T.chests() == 0)
    local ok, why = T.addChest(1.5, 0, 0, 0)
    check("whole numbers", ok == nil and why:find("whole numbers", 1, true), tostring(why))
    ok, why = T.addChest(1, 0, 0, "front")
    check("a side that is not up, down or a heading: nil and why", ok == nil and why:find("heading 0 to 3", 1, true), tostring(why))
    check("T.addChest keeps the place in a data file", T.addChest(3, 0, 0, 0) == true and fileText() == "chest 3 0 0 0 plain 0\n", tostring(fileText()))
    check("\"top\" and \"bottom\" are up and down", T.addChest(1, 0, 0, "top") == true and T.addChest(2, 0, 0, "bottom") == true
        and fileText():find("chest 1 0 0 up plain", 1, true) and fileText():find("chest 2 0 0 down plain", 1, true))
    check("adding a chest again changes nothing", (function()
        T.addChest(3, 0, 0, 0)
        return #T.chests() == 3
    end)())
    T.addChest(3, 0, 0, 0, true)
    T.addChest(1, 0, 0, "up", true)
    local list = T.chests()
    local bulks = 0
    for _, c in ipairs(list) do if c.bulk then bulks = bulks + 1 end end
    check("one bulk chest: the last one named", bulks == 1 and line(list, 1, 0, "up").bulk == true and line(list, 3, 0, 0).bulk == false)
    package.loaded.turtlelib = nil
    local T2 = require("turtlelib")
    check("another copy of turtlelib reads the same list", #T2.chests() == 3)
    T = T2
    ok, why = T.forgetChest(9, 9, 9, 0)
    check("forgetting a chest that is not there: false and why", ok == false and why:find("no chest is known", 1, true), tostring(why))
    check("T.forgetChest removes it from the list and the file", T.forgetChest(2, 0, 0, "bottom") == true and #T.chests() == 2
        and not fileText():find("chest 2 0 0", 1, true))
    check("T.chests gives copies: changing one does not touch the file", (function()
        local l = T.chests()
        l[1].items.junk = 5
        return not fileText():find("junk", 1, true)
    end)())
end

--------------------------------------------------------------------------
-- T.catalogue
--------------------------------------------------------------------------
do
    setUp()
    W.S.moves = 0
    T.dir = 0
    local ok, info = T.catalogue()
    check("T.catalogue reads all four chests", ok == true and info.chests == 4 and #info.failed == 0 and info.kinds == 5 and info.items == 64 + 40 + 10 + 5 + 30 + 7,
        tostring(ok) .. " " .. tostring(info and info.chests) .. " " .. tostring(info and info.items))
    check("...and comes back to where it was, facing as before", here())
    local list = T.chests()
    check("it wrote down what each holds", line(list, 3, 0, 0).items[COBBLE] == 64 and line(list, 3, 0, 0).items[PLANKS] == 40
        and line(list, -3, 0, 0).items[STONE] == 10 and line(list, 0, -2, 2).items[DIRT] == 30 and line(list, 2, -2, "down").items[IRON] == 7)
    check("...with the time it was read", line(list, 3, 0, 0).seen == 1000, tostring(line(list, 3, 0, 0).seen))
    check("the bulk chest is still the bulk chest", line(list, 0, -2, 2).bulk == true)
    -- it was told, so it kept it up: a change in a chest shows at the next catalogue
    fill(3, 0, 1, { [1] = { COBBLE, 3 } })
    CLOCK = 2000
    T.dir = 0
    ok = T.catalogue()
    check("catalogue again reads what changed", ok == true and line(T.chests(), 3, 0, 0).items[COBBLE] == 3 and line(T.chests(), 3, 0, 0).items[PLANKS] == nil
        and line(T.chests(), 3, 0, 0).seen == 2000)
end

do
    -- nearest next, not the order of the file
    setUp()
    local visited = {}
    local rawFace = T.face
    W.S.moves = 0
    local stands = { ["3,0,0"] = "A", ["-3,0,0"] = "B", ["0,0,-2"] = "C", ["2,0,-2"] = "D" }
    local rawContainer = T.containerOn
    T.containerOn = function(side)
        visited[#visited + 1] = stands[T.pos.x .. "," .. T.pos.y .. "," .. T.pos.z]
        return rawContainer(side)
    end
    T.catalogue()
    T.containerOn = rawContainer
    -- from (0,0,0): C is 2 away, D 4, A 3, B 3 (A before B: the list order breaks the tie by key); D from C is 2
    check("nearest first from where the turtle is", visited[1] == "C" and visited[2] == "D", table.concat(visited, " "))
end

do
    -- a chest that is gone, and one that cannot be reached: reported, the rest read
    setUp()
    W.set(-3, 0, 1, nil)
    W.fill(2, 0, -3, 2, 3, -3, "minecraft:bedrock")
    W.fill(1, 0, -2, 1, 3, -2, "minecraft:bedrock")
    W.fill(3, 0, -2, 3, 3, -2, "minecraft:bedrock")
    W.fill(2, 0, -1, 2, 3, -1, "minecraft:bedrock")
    W.fill(2, 2, -2, 2, 3, -2, "minecraft:bedrock")
    local ok, why, info = T.catalogue()
    check("a missing chest and an unreachable one: false, the first reason, the failures listed", ok == false and info.chests == 2 and #info.failed == 2
        and why:find("2 chests read, 2 not", 1, true), tostring(why))
    local reasons = info.failed[1].why .. " | " .. info.failed[2].why
    check("...each says why", reasons:find("no chest on the front", 1, true) and reasons:find("can't get to 2,0,-2", 1, true), reasons)
    check("...and the turtle is home", here())
    check("...the ones that could be read were written down", line(T.chests(), 3, 0, 0).items[COBBLE] == 64 and line(T.chests(), 0, -2, 2).items[DIRT] == 30)
end

do
    -- places given are remembered; with none known and none given, nothing to do
    fresh()
    stocked()
    local ok, why = T.catalogue()
    check("no chest known and none given: nil and why", ok == nil and why:find("no chests to go round", 1, true), tostring(why))
    ok, why = T.catalogue({ { x = 3, y = 0, z = 0, side = 0 }, { x = 1, y = 0, z = 0, side = "sideways" } })
    check("a bad place in the list: nil and why, nothing walked", ok == nil and why:find("heading 0 to 3", 1, true) and here(), tostring(why))
    local info
    ok, info = T.catalogue({ { x = 3, y = 0, z = 0, side = 0 }, { x = 0, y = 0, z = -2, side = 2, bulk = true } })
    check("chests given as places are visited and remembered", ok == true and info.chests == 2 and #T.chests() == 2 and line(T.chests(), 0, -2, 2).bulk == true
        and line(T.chests(), 0, -2, 2).items[DIRT] == 30)
    -- ADR-0015: the spots given are the ones gone round, not every chest known (328 fuel for 5 chests side by side, the
    -- others a base away)
    T.addChest(Bc.x, Bc.y, Bc.z, Bc.side)
    fill(3, 0, 1, { [1] = { COBBLE, 9 } })
    fill(-3, 0, 1, { [1] = { STONE, 3 } })
    ok, info = T.catalogue({ { x = 3, y = 0, z = 0, side = 0 } })
    check("T.catalogue(spots): only the spots are read, not every chest known", ok == true and info.chests == 1
        and line(T.chests(), 3, 0, 0).items[COBBLE] == 9 and line(T.chests(), -3, 0, 0).items[STONE] == nil and here(),
        tostring(info and info.chests))
end

do
    -- chests and barrels the map shows in a box (here one the map calls a barrel)
    fresh()
    stocked()
    W.set(-2, 0, 3, "minecraft:trapped_chest")
    fill(-2, 0, 3, { [1] = { "minecraft:wheat", 12 } })
    T.setOrigin(0, 0, 0, "north")
    for x = -5, 5 do for y = 0, 2 do for z = -4, 4 do
        local b = W.get(x, y, z)
        T.map.set(x, y, z, b and b.name or "minecraft:air")
    end end end
    T.map.set(-2, 0, 3, "minecraft:barrel")           -- (the map was told it is a barrel; the game has a container there)
    local ok, info = T.catalogue(nil, { find = { 2, 0, 0, 4, 0, 4 } })
    check("opts.find: the chest the map shows in the box, from a free cell beside it", ok == true and info.chests == 1 and #T.chests() == 1
        and line(T.chests(), 3, 0, 0) and line(T.chests(), 3, 0, 0).items[COBBLE] == 64, tostring(ok) .. " " .. tostring(info and info.chests) .. " " .. #T.chests())
    ok, info = T.catalogue(nil, { find = { -4, 0, 1, -1, 0, 4 } })
    check("...a barrel counts, and what was known stays (and isn't read again: only the box's are)", ok == true and #T.chests() == 3
        and info.chests == 2 and (function()
        for _, c in ipairs(T.chests()) do if c.items["minecraft:wheat"] == 12 then return true end end
    end)())
    check("...and the turtle ends where it began", here())
end

do
    -- one record per chest: two stands for the same chest, and the two halves of a double chest (each half is a peripheral
    -- listing the whole of it), are one chest
    local BRICKS = "minecraft:bricks"
    local function double(x1, x2, items)
        W.set(x1, 0, 1, "minecraft:chest", { facing = "south", type = "right" })
        W.set(x2, 0, 1, "minecraft:chest", { facing = "south", type = "left" })
        W.get(x2, 0, 1).inv = W.get(x1, 0, 1).inv
        fill(x1, 0, 1, items)
    end
    fresh()
    double(3, 4, { [1] = { BRICKS, 64 }, [2] = { BRICKS, 64 } })
    T.addChest(3, 0, 0, 0); T.addChest(4, 0, 0, 0)
    local ok, info = T.catalogue()
    local found, total = T.where(BRICKS)
    check("a double chest whose halves were both added is one chest: its bricks counted once", ok == true and #T.chests() == 1
        and total == 128 and #found == 1, tostring(#T.chests()) .. " chests, " .. tostring(total) .. " bricks")
    check("...and the catalogue says one chest", info.chests == 1, tostring(info and info.chests))
    local kept = T.chests()[1]
    local otherX = kept.x == 3 and 4 or 3
    local keptAt = kept.x .. ",0,1, reached from " .. kept.x .. ",0,0 side 0"
    local added, said = T.addChest(otherX, 0, 0, 0)
    check("T.addChest on the other half of the known double chest: true, and it says so", added == true and #T.chests() == 1
        and said == "already known: the other half of the double chest at " .. keptAt, tostring(said))
    added, said = T.addChest(3, 1, 1, "down")
    check("a second stand for a chest already known is the same chest", #T.chests() == 1 and select(2, T.where(BRICKS)) == 128,
        tostring(#T.chests()))
    check("...and T.addChest says which", added == true and said == (kept.x == 3 and "already known: the chest at " .. keptAt
        or "already known: the other half of the double chest at " .. keptAt), tostring(said))
    added, said = T.addChest(kept.x, 0, 0, 0)
    check("...the same place again: already known", added == true and said == "already known: the chest at " .. keptAt, tostring(said))
    T.addChest(3, 1, 1, "down", true)
    check("...and naming it the bulk chest from there marks the one record", #T.chests() == 1 and T.chests()[1].bulk == true)
    check("...and forgetting it from there forgets it", T.forgetChest(3, 1, 1, "down") == true and #T.chests() == 0)
    local f = fs.open(T.dataPath(".chests"), "w")
    f.write("chest 3 0 0 0 plain 0\nitem 5 minecraft:dirt\nchest 3 1 1 down bulk 0\nitem 5 minecraft:dirt\n")
    f.close()
    check("a file from before with two stands for one chest reads as one, the bulk chest if either was", #T.chests() == 1
        and T.chests()[1].bulk == true and select(2, T.where(DIRT)) == 5)

    -- with the world origin known, the halves are told by their facing: two double chests side by side, both empty, stay two
    fresh()
    T.setOrigin(0, 0, 0, "north")
    double(3, 4, {})
    double(5, 6, {})
    for x = 3, 6 do T.addChest(x, 0, 0, 0) end
    T.catalogue()
    local cells = {}
    for _, c in ipairs(T.chests()) do cells[#cells + 1] = c.x end
    table.sort(cells)
    check("...two double chests side by side, empty, are two chests, not one or three", #cells == 2 and cells[1] == 3 and cells[2] == 5,
        table.concat(cells, " "))
end

--------------------------------------------------------------------------
-- T.where
--------------------------------------------------------------------------
do
    fresh()
    local list, why = T.where(PLANKS)
    check("no chests known: nil and why", list == nil and why:find("no chests are known", 1, true), tostring(why))
    setUp()
    T.catalogue()
    local moves = W.S.moves
    local found, total = T.where(PLANKS)
    check("the chests with an item, nearest first, and the total", #found == 2 and found[1].x == -3 and found[1].count == 5 and found[2].x == 3 and found[2].count == 40 and total == 45,
        tostring(#found) .. " " .. tostring(total))
    found, total = T.where("oak_planks")
    check("the namespace may be left out", total == 45)
    found, total = T.where("*planks")
    check("a glob", total == 45 and #found == 2)
    local readAt = CLOCK
    CLOCK = CLOCK + 60
    found = T.where(PLANKS)
    check("each count says when it was read, and how long ago (seen, age)", found[1].seen == readAt and found[1].age == 60,
        tostring(found[1].seen) .. " " .. tostring(found[1].age))
    CLOCK = readAt
    found, total = T.where("minecraft:*")
    check("a glob over everything", total == 64 + 40 + 10 + 5 + 30 + 7 and #found == 4, tostring(total))
    found, total = T.where("minecraft:diamond")
    check("an item no chest holds: none, total 0", #found == 0 and total == 0)
    check("it moves nothing", here() and W.S.moves == moves)
    T.addChest(5, 0, 5, 0)
    found = T.where(COBBLE)
    check("a chest never read holds nothing as far as the list knows", #found == 1 and found[1].x == 3)
end

--------------------------------------------------------------------------
-- T.fetch
--------------------------------------------------------------------------
do
    setUp()
    T.catalogue()
    local got, why = T.fetch(COBBLE, 20)
    check("T.fetch goes to the chest that has it and takes the count", got == 20 and why == nil and carrying(COBBLE) == 20 and chestHas(3, 0, 1, COBBLE) == 44,
        tostring(got) .. " " .. tostring(why))
    check("...comes back facing as before", here())
    check("...the list says what is left", line(T.chests(), 3, 0, 0).items[COBBLE] == 44)
    got, why = T.fetch("oak_planks", 42)
    check("across two chests: the nearer first, then the next; the namespace may be left out", got == 42 and carrying(PLANKS) == 42 and chestHas(-3, 0, 1, PLANKS) == 0
        and chestHas(3, 0, 1, PLANKS) == 3, tostring(got) .. " " .. tostring(why))
    got, why = T.fetch(PLANKS, 20)
    check("short: what there is, and why", got == 3 and why:find("got 3 of 20", 1, true) and carrying(PLANKS) == 45, tostring(got) .. " " .. tostring(why))
    got, why = T.fetch("minecraft:diamond", 1)
    check("an item no chest holds: nothing, and no trip", got == 0 and why:find("no chest is known to hold minecraft:diamond", 1, true) and here())
    got, why = T.fetch(IRON, 0)
    check("a count that is not a whole number from 1: refused", got == 0 and why:find("whole number", 1, true))
    got = T.fetch(IRON)
    check("the count is 1 by default", got == 1 and carrying(IRON) == 1)
    -- the list is stale: the chest was emptied behind its back
    setUp()
    T.catalogue()
    fill(-3, 0, 1, {})
    got, why = T.fetch(PLANKS, 10)
    check("a chest emptied behind its back: found out, put right, the next chest tried", got == 10 and chestHas(3, 0, 1, PLANKS) == 30 and not line(T.chests(), -3, 0, 0).items[PLANKS],
        tostring(got) .. " " .. tostring(why))
    -- no room in the turtle
    setUp()
    T.catalogue()
    for s = 1, 16 do W.give(s, "minecraft:item_" .. s, 64) end
    got, why = T.fetch(COBBLE, 5)
    check("no room in the turtle: nothing, and it says", got == 0 and why:find("no room", 1, true) and here(), tostring(got) .. " " .. tostring(why))
    local first = why:find("(got ", 1, true)
    check("...saying how many it got once", first ~= nil and why:find("(got ", first + 1, true) == nil and why:find("(got 0 of 5)", 1, true) ~= nil,
        tostring(why))
    -- a chest that is not there any more
    setUp()
    T.catalogue()
    W.set(3, 0, 1, nil)
    got, why = T.fetch(COBBLE, 5)
    check("a chest that is gone: nothing, and why", got == 0 and why:find("no chest on the front", 1, true) and here(), tostring(got) .. " " .. tostring(why))
    -- the item is in the bulk chest of a chest further away; heading is restored
    setUp()
    T.catalogue()
    T.face(1)
    T.fetch(IRON, 7)
    check("facing as before, whatever way the last chest was faced", here(0, 0, 0, 1) and carrying(IRON) == 7)
end

--------------------------------------------------------------------------
-- T.stow
--------------------------------------------------------------------------
do
    fresh()
    local ok, why = T.stow()
    check("no chests known: nil and why", ok == nil and why:find("no chests are known", 1, true), tostring(why))
    setUp()
    T.catalogue()
    T.keep[COBBLE] = false
    W.give(1, PICK, 1)
    W.give(2, COBBLE, 30)
    W.give(3, DIRT, 64)
    W.give(4, DIRT, 10)
    W.give(5, "minecraft:coal", 4)
    W.give(6, "minecraft:gravel", 12)
    W.give(7, "advancedperipherals:geo_scanner", 1)
    W.give(8, "minecraft:bucket", 1)
    W.give(9, "minecraft:torch", 8)
    W.give(10, STONE, 5)
    local info
    ok, info = T.stow()
    check("T.stow: true and how many went in", ok == true and info.stowed == 30 + 74 + 12 + 5 and next(info.left) == nil and info.chests == 3, tostring(ok) .. " " .. tostring(info and info.stowed))
    check("...an item into the chest that holds it", chestHas(3, 0, 1, COBBLE) == 94 and chestHas(-3, 0, 1, STONE) == 15)
    check("...the rest into the bulk chest", chestHas(0, 0, -3, DIRT) == 30 + 74 and chestHas(0, 0, -3, "minecraft:gravel") == 12)
    check("...the tool, fuel, torches, bucket and scanner stay aboard", carrying(PICK) == 1 and carrying("minecraft:coal") == 4 and carrying("minecraft:torch") == 8
        and carrying("minecraft:bucket") == 1 and carrying("advancedperipherals:geo_scanner") == 1)
    check("...the turtle is home, facing as before", here())
    check("...the list is right", line(T.chests(), 0, -2, 2).items[DIRT] == 104 and line(T.chests(), 3, 0, 0).items[COBBLE] == 94)
    check("nothing was thrown into the world", (W.thrown or 0) == 0)
    local moves = W.S.moves
    ok, info = T.stow()
    check("with nothing to put away it goes nowhere", ok == true and info.stowed == 0 and W.S.moves == moves)
end

do
    -- the nearest chest that wants something next
    setUp()
    T.catalogue()
    W.give(1, COBBLE, 5)
    W.give(2, DIRT, 5)
    W.give(3, STONE, 5)
    local visited = {}
    local stands = { ["3,0,0"] = "A", ["-3,0,0"] = "B", ["0,0,-2"] = "C" }
    local rawContainer = T.containerOn
    T.containerOn = function(side)
        visited[#visited + 1] = stands[T.pos.x .. "," .. T.pos.y .. "," .. T.pos.z]
        return rawContainer(side)
    end
    T.stow()
    T.containerOn = rawContainer
    check("T.stow goes to the nearest chest that wants something first (C is 2 away, A and B 3)", visited[1] == "C" and #visited == 3, table.concat(visited, " "))
end

do
    -- what the job keeps, and opts.all
    setUp()
    T.catalogue()
    T.keep[DIRT] = true
    W.give(1, DIRT, 20)
    W.give(2, COBBLE, 10)
    W.give(3, PICK, 1)
    W.give(4, "minecraft:coal", 3)
    T.markCrafted(STONE)
    W.give(5, STONE, 4)
    local ok, info = T.stow()
    check("T.keep items and what the job crafted stay aboard", ok == true and carrying(DIRT) == 20 and carrying(STONE) == 4 and carrying(COBBLE) == 0 and info.stowed == 10)
    ok, info = T.stow({ all = true })
    check("opts.all puts those away too, but never a tool or fuel", ok == true and info.stowed == 24 and carrying(DIRT) == 0 and carrying(STONE) == 0
        and carrying(PICK) == 1 and carrying("minecraft:coal") == 3)
    check("...the crafted stone went to the chest that holds stone", chestHas(-3, 0, 1, STONE) == 14)
    T.keep[DIRT] = nil
    T.clearCrafted()
end

do
    -- T.cfg.tools: the tools a job keeps (ADR-0013 D5)
    local SWORD, HOE, IRONPICK = "minecraft:iron_sword", "minecraft:iron_hoe", "minecraft:iron_pickaxe"
    setUp()
    T.catalogue()
    W.give(1, SWORD, 1)
    W.give(2, IRONPICK, 1)
    W.give(3, HOE, 1)
    W.give(4, DIRT, 5)
    local ok, info = T.stow()
    check("T.cfg.tools unset: T.stow leaves every tool aboard, looted ones too", ok == true and info.stowed == 5 and carrying(SWORD) == 1
        and carrying(IRONPICK) == 1 and carrying(HOE) == 1)
    T.cfg.tools = { "*_hoe" }
    ok, info = T.stow()
    check("T.cfg.tools set: the looted sword and pickaxe go to the bulk chest, the hoe it lists stays", ok == true and info.stowed == 2
        and chestHas(0, 0, -3, SWORD) == 1 and chestHas(0, 0, -3, IRONPICK) == 1 and carrying(HOE) == 1 and EQ.left == PICK)
    T.cfg.tools = {}
    ok, info = T.stow()
    check("...T.cfg.tools = {} (only what is equipped): the hoe goes too, the pickaxe equipped stays on", ok == true and info.stowed == 1
        and carrying(HOE) == 0 and chestHas(0, 0, -3, HOE) == 1 and EQ.left == PICK)
    -- a crafting table on the pickaxe's side (a chunk controller on the other): the pickaxe is parked aboard, and kept
    EQ.right = "advancedperipherals:chunk_controller"
    W.give(1, "minecraft:crafting_table", 1)
    W.give(2, SWORD, 1)
    local inside, during
    T.withPeripheral("minecraft:crafting_table", function()
        inside = EQ.left == "minecraft:crafting_table" and carrying(PICK) == 1
        during = T.isEssential(PICK) and T.stow({ all = true }) == true and carrying(PICK) == 1 and carrying(SWORD) == 0
    end)
    check("...a pickaxe parked aboard by T.equipPeripheral is kept, the sword is not", inside and during and EQ.left == PICK
        and chestHas(0, 0, -3, SWORD) == 2, tostring(inside) .. " " .. tostring(during))
    W.give(1, HOE, 1)
    T.withTool(HOE, function()
        inside = EQ.left == HOE and carrying(PICK) == 1 and T.isEssential(PICK) and T.isEssential(HOE)
    end)
    check("...and one parked by T.withTool; the hoe, back aboard, is not kept", inside and EQ.left == PICK and not T.isEssential(HOE))
    T.cfg.tools, EQ.right = nil, nil
end

do
    -- a full chest, and no bulk chest
    setUp()
    T.catalogue()
    local items = {}
    for s = 1, 27 do items[s] = { "minecraft:filler_" .. s, 64 } end
    items[1] = { COBBLE, 64 }
    fill(3, 0, 1, items)
    T.catalogue()
    W.give(1, COBBLE, 64)
    local ok, why, info = T.stow()
    check("a chest that is full: what does not fit goes to the bulk chest", ok == true and chestHas(0, 0, -3, COBBLE) == 64 and carrying(COBBLE) == 0, tostring(why))
    fill(0, 0, -3, (function()
        local f = {}
        for s = 1, 27 do f[s] = { "minecraft:filler_" .. s, 64 } end
        return f
    end)())
    T.catalogue()
    W.give(1, COBBLE, 64)
    W.give(2, DIRT, 5)
    ok, why, info = T.stow()
    check("...a bulk chest that is full too: false, it says so, the items stay aboard", ok == false and why:find("stayed aboard", 1, true) and info.left[COBBLE] == 64 and info.left[DIRT] == 5
        and carrying(COBBLE) == 64 and carrying(DIRT) == 5 and here(), tostring(why))
    check("...nothing was thrown", (W.thrown or 0) == 0)
    check("...each item left aboard has its reason in info: every chest it was tried at, and that each was full",
        info.reasons and info.reasons[COBBLE] == "chest at 3,0,1 full, bulk chest at 0,0,-3 full" and info.reasons[DIRT] == "bulk chest at 0,0,-3 full",
        tostring(info.reasons and info.reasons[COBBLE]) .. " / " .. tostring(info.reasons and info.reasons[DIRT]))
    check("...and the why says them all, not the first item only",
        why == "some stayed aboard: 64 cobblestone (chest at 3,0,1 full, bulk chest at 0,0,-3 full); 5 dirt (bulk chest at 0,0,-3 full)", tostring(why))

    -- a chest with room for part of it, and no bulk chest: the part that fits is counted
    setUp()
    T.forgetChest(C.x, C.y, C.z, C.side)
    local part = {}
    for s2 = 1, 26 do part[s2] = { "minecraft:filler_" .. s2, 64 } end
    part[27] = { COBBLE, 40 }
    fill(3, 0, 1, part)
    T.catalogue()
    W.give(1, COBBLE, 64)
    ok, why, info = T.stow()
    check("a chest with room for part of it: the part that fits goes in and is counted, the rest stays aboard", ok == false and info.stowed == 24 and info.left[COBBLE] == 40
        and carrying(COBBLE) == 40 and chestHas(3, 0, 1, COBBLE) == 64, tostring(info.stowed) .. " " .. tostring(carrying(COBBLE)))
    check("...its reason: the chest full, and no bulk chest", info.reasons and info.reasons[COBBLE] == "chest at 3,0,1 full; no bulk chest"
        and why == "some stayed aboard: 40 cobblestone (chest at 3,0,1 full; no bulk chest)", tostring(why))

    setUp()
    T.forgetChest(C.x, C.y, C.z, C.side)
    T.addChest(C.x, C.y, C.z, C.side)
    T.catalogue()
    W.give(1, "minecraft:gravel", 10)
    W.give(2, COBBLE, 10)
    ok, why, info = T.stow()
    check("no bulk chest: what a chest holds goes in, the rest stays aboard and is reported", ok == false and chestHas(3, 0, 1, COBBLE) == 74 and carrying(COBBLE) == 0
        and carrying("minecraft:gravel") == 10 and info.left["minecraft:gravel"] == 10 and next(info.left, "minecraft:gravel") == nil, tostring(why))
    check("...its reason: no chest holds it and no bulk chest", info.reasons and info.reasons["minecraft:gravel"] == "no chest holds it and no bulk chest"
        and why == "some stayed aboard: 10 gravel (no chest holds it and no bulk chest)", tostring(why))
    -- the dirt is in a chest: the one that holds it, not the bulk chest
    setUp()
    T.catalogue()
    T.addChest(0, 0, 3, 0)
    W.set(0, 0, 4, "minecraft:chest")
    fill(0, 0, 4, { [1] = { "minecraft:gravel", 1 } })
    T.catalogue()
    W.give(1, "minecraft:gravel", 10)
    ok = T.stow()
    check("an item goes to a chest that holds it before the bulk chest, even one further away", ok == true and chestHas(0, 0, 4, "minecraft:gravel") == 11
        and chestHas(0, 0, -3, "minecraft:gravel") == 0)
    -- a chest that is gone
    setUp()
    T.catalogue()
    W.set(3, 0, 1, nil)
    W.give(1, COBBLE, 10)
    ok, why = T.stow()
    check("the chest that held it is gone: the bulk chest takes it", ok == true and chestHas(0, 0, -3, COBBLE) == 10 and here(), tostring(why))
    -- a chest that is gone, and no bulk chest: the reason is the trip's
    setUp()
    T.forgetChest(C.x, C.y, C.z, C.side)
    T.catalogue()
    W.set(3, 0, 1, nil)
    W.give(1, COBBLE, 10)
    local info2
    ok, why, info2 = T.stow()
    check("...gone, and no bulk chest: the item stays aboard, its reason what went wrong there", ok == false and carrying(COBBLE) == 10
        and info2.reasons[COBBLE] == "no chest on the front of 3,0,0; no bulk chest", tostring(info2 and info2.reasons and info2.reasons[COBBLE]))
end

--------------------------------------------------------------------------
-- Chest categories: holds, T.stow's order, T.sortChests (ADR-0013 D6.4)
--------------------------------------------------------------------------
local OAKLOG, BIRCH = "minecraft:oak_log", "minecraft:birch_planks"
do
    setUp()
    check("an old file without holds is read: no chest is for anything", T.chests()[1].holds == nil and not fileText():find("holds", 1, true))
    local ok, note = T.addChest(D.x, D.y, D.z, D.side, { holds = { "*_planks", "*_log" } })
    check("T.addChest with holds on a known chest sets them, and the note says so (not \"already known\")", ok == true
        and type(note) == "string" and note:find("*_log *_planks", 1, true) and not note:find("already known", 1, true), tostring(note))
    check("...kept in the file on a line after the chest's", fileText():find("chest 2 0 -2 down plain 0\nholds *_log *_planks\n", 1, true),
        tostring(fileText()))
    local d = line(T.chests(), 2, -2, "down")
    check("...T.chests gives them, sorted", d.holds and d.holds[1] == "*_log" and d.holds[2] == "*_planks" and #d.holds == 2)
    ok, note = T.addChest(D.x, D.y, D.z, D.side, { holds = { ["*_log"] = true, ["*_planks"] = true } })
    check("the same holds again (a set this time): \"already known\", as before", ok == true and note:find("already known", 1, true), tostring(note))
    ok, note = T.addChest(D.x, D.y, D.z, D.side)
    check("...and no holds given leaves them as they are", ok == true and note:find("already known", 1, true) and #line(T.chests(), 2, -2, "down").holds == 2)
    ok, note = T.addChest(D.x, D.y, D.z, D.side, true, { holds = "cobblestone" })
    check("bulk and holds as the fifth and sixth arguments", ok == true and line(T.chests(), 2, -2, "down").bulk == true
        and line(T.chests(), 2, -2, "down").holds[1] == "cobblestone" and line(T.chests(), 0, -2, 2).bulk == false, tostring(note))
    ok, note = T.addChest(D.x, D.y, D.z, D.side, { holds = false })
    check("holds = false clears them", ok == true and line(T.chests(), 2, -2, "down").holds == nil and not fileText():find("holds", 1, true)
        and type(note) == "string" and note:find("anything", 1, true), tostring(note))
    T.addChest(C.x, C.y, C.z, C.side, true)
    ok, note = T.addChest(D.x, D.y, D.z, D.side, { holds = { "oak planks" } })
    check("a glob with a space in it: nil and why, nothing changed", ok == nil and note:find("holds", 1, true) and line(T.chests(), 2, -2, "down").holds == nil,
        tostring(note))
    ok, note = T.addChest(D.x, D.y, D.z, D.side, { holds = 5 })
    check("...holds that are not names: nil and why", ok == nil and type(note) == "string", tostring(note))
    ok, note = T.addChest(1, 0, 3, 0, { holds = "*_log" })
    check("a new chest with holds: true and no note", ok == true and note == nil and line(T.chests(), 1, 3, 0).holds[1] == "*_log")
    T.forgetChest(1, 0, 3, 0)
    T.addChest(D.x, D.y, D.z, D.side, { holds = "*_planks" })
    T.reframeChests(function(x, y, z) return x + 10, y, z end, 1)
    local moved = line(T.chests(), 12, -2, "down")
    check("a re-zero keeps a chest's holds", moved and moved.holds and moved.holds[1] == "*_planks")
    for _, name in ipairs(MODS) do package.loaded[name] = nil end
    T = require("turtlelib")
    check("...and another copy of the library reads them", line(T.chests(), 12, -2, "down").holds[1] == "*_planks")
end

do
    -- T.stow: a chest for the item first, then one that holds it already, then the bulk chest
    setUp()
    T.addChest(D.x, D.y, D.z, D.side, { holds = "*_planks" })
    T.catalogue()
    W.give(1, PLANKS, 10)
    local ok, why = T.stow()
    check("T.stow puts planks in the chest for planks, not in A or B that hold some already", ok == true and chestHas(2, -1, -2, PLANKS) == 10
        and chestHas(3, 0, 1, PLANKS) == 40 and chestHas(-3, 0, 1, PLANKS) == 5, tostring(why))
    T.addChest(A.x, A.y, A.z, A.side, { holds = "cobblestone" })
    T.addChest(D.x, D.y, D.z, D.side, { holds = false })
    W.give(1, PLANKS, 3)
    ok, why = T.stow()
    check("...not in a chest for other things though it holds some (A, for cobblestone): in B, which holds planks", ok == true
        and chestHas(3, 0, 1, PLANKS) == 40 and chestHas(-3, 0, 1, PLANKS) == 8, tostring(why))
    -- a full chest for planks: on to one that holds them
    local items = {}
    for s = 1, 27 do items[s] = { BIRCH, 64 } end
    fill(2, -1, -2, items)
    T.addChest(D.x, D.y, D.z, D.side, { holds = "*_planks" })
    T.catalogue()
    W.give(1, PLANKS, 4)
    ok, why = T.stow()
    check("...a full chest for planks falls through to a chest that holds them", ok == true and chestHas(-3, 0, 1, PLANKS) == 12, tostring(why))
    W.give(1, OAKLOG, 6)
    ok, why = T.stow()
    check("...and something no chest is for or holds goes to the bulk chest", ok == true and chestHas(0, 0, -3, OAKLOG) == 6, tostring(why))
end

do
    -- ADR-0015 D1: two bases.  A chest for glowstone at the far base (100 blocks east) and the bulk chest here: what
    -- goes in stays here (it went the 100 blocks, and back, for 6 glowstone); with no chest for it here it stays
    -- aboard, the why saying where the far one is; opts.far goes
    local GLOW = "minecraft:glowstone"
    setUp()
    W.set(100, 0, 1, "minecraft:chest")
    T.addChest(100, 0, 0, 0, { holds = "*glowstone*" })
    T.catalogue()
    W.give(1, GLOW, 6)
    local moves = W.S.moves
    local ok, why, info = T.stow()
    check("two bases: an item whose chest is at the far base goes to the bulk chest here, not 100 blocks off", ok == true
        and chestHas(0, 0, -3, GLOW) == 6 and chestHas(100, 0, 1, GLOW) == 0 and W.S.moves - moves < 20, tostring(why))
    T.forgetChest(C.x, C.y, C.z, C.side)
    W.give(1, GLOW, 6)
    ok, why, info = T.stow()
    check("...with nowhere for it here: aboard, the why naming the far chest, how far and opts.far", ok == false and carrying(GLOW) == 6
        and why:find("the nearest chest for it is at 100,0,1, 100 blocks off (over opts.maxDistance 48: opts.far = true goes)", 1, true) ~= nil,
        tostring(why))
    ok, why = T.stow({ far = true })
    check("...opts.far = true goes there", ok == true and chestHas(100, 0, 1, GLOW) == 6 and carrying(GLOW) == 0 and here(), tostring(why))
    -- sorting stays within a site: the far base's chest for glowstone doesn't pull it from the bulk chest here
    T.addChest(C.x, C.y, C.z, C.side, true)
    fill(0, 0, -3, { [1] = { GLOW, 5 } })
    T.catalogue({ { x = C.x, y = C.y, z = C.z, side = C.side } })
    moves = W.S.moves
    ok, why = T.sortChests()
    check("T.sortChests sorts the site the turtle is at: the glowstone in the bulk chest here stays, nowhere far gone",
        ok == true and chestHas(0, 0, -3, GLOW) == 5 and chestHas(100, 0, 1, GLOW) == 6 and W.S.moves == moves, tostring(why))
end

do
    -- ADR-0015 D2: holds that overlap: the most specific glob wins (fewer wildcards, then more letters), and
    -- T.addChest says so
    local STAIRS = "minecraft:stone_brick_stairs"
    setUp()
    T.catalogue()
    W.give(1, STAIRS, 8)
    W.give(2, "minecraft:bricks", 4)
    local _, note1 = T.addChest(D.x, D.y, D.z, D.side, { holds = "*_stairs" })
    local _, note2 = T.addChest(A.x, A.y, A.z, A.side, { holds = "*brick*" })
    check("T.addChest: holds that overlap another chest's are said, with an item both take (one aboard) and which wins",
        not tostring(note1):find("warning", 1, true) and note2 == "the chest at 3,0,1 is now for *brick*; warning: \"*brick*\" overlaps the chest at 2,-1,-2's \"*_stairs\" " ..
        "(both take stone_brick_stairs): the more specific glob wins, \"*_stairs\" (that chest's)", tostring(note2))
    local ok, why = T.stow()
    check("...stone brick stairs go to the chest for *_stairs, bricks to the one for *brick*", ok == true
        and chestHas(2, -1, -2, STAIRS) == 8 and chestHas(3, 0, 1, STAIRS) == 0 and chestHas(3, 0, 1, "minecraft:bricks") == 4, tostring(why))
end

do
    -- ADR-0019: the overlap warning tests only real names (what the known chests hold, the inventory), never names made
    -- by joining the globs' letters ("coalbrick"), groups by chest, and caps its lists at three
    local function stairs(kind) return "minecraft:" .. kind .. "_stairs" end
    setUp()
    fill(-3, 0, 1, { [1] = { stairs("stone_brick"), 4 }, [2] = { stairs("brick"), 4 }, [3] = { stairs("mud_brick"), 4 },
        [4] = { stairs("nether_brick"), 4 }, [5] = { "minecraft:stone_brick_slab", 4 } })
    T.catalogue()
    T.addChest(D.x, D.y, D.z, D.side, { holds = { "*coal*", "*_stairs", "*_slab" } })
    local _, note = T.addChest(A.x, A.y, A.z, A.side, { holds = "*brick*" })
    check("overlapping holds: only real names, one warning for the chest, its names capped at three", note ==
        "the chest at 3,0,1 is now for *brick*; warning: \"*brick*\" overlaps the chest at 2,-1,-2's \"*_slab\" (both take stone_brick_slab): the more specific glob wins, " ..
        "\"*_slab\" (that chest's); \"*brick*\" overlaps its \"*_stairs\" (both take brick_stairs, mud_brick_stairs, nether_brick_stairs " ..
        "and 1 more): the more specific glob wins, \"*_stairs\" (that chest's)", tostring(note))
    check("...no name made up from the globs' letters (\"*coal*\" and \"*brick*\" take no real item both)",
        not text.contains(tostring(note), "coal"), tostring(note))
    -- four chests it overlaps: three said, and how many more
    T.addChest(Bc.x, Bc.y, Bc.z, Bc.side, { holds = "*brick_*" })
    T.addChest(C.x, C.y, C.z, C.side, { holds = "*_stairs" })
    _, note = T.addChest(0, 0, 2, 0, { holds = "*brick*" })
    check("...overlapping four chests: the first three said, then how many more", text.count(tostring(note), "warning: ") == 3
        and text.endsWith(tostring(note), "; and 1 more chest overlaps it"), tostring(note))
    -- six pairs of globs overlapping one chest: three said, and how many more
    setUp()
    fill(-3, 0, 1, { [1] = { stairs("stone_brick"), 4 }, [2] = { "minecraft:stone_brick_slab", 4 } })
    T.catalogue()
    T.addChest(D.x, D.y, D.z, D.side, { holds = { "*_stairs", "*_slab" } })
    _, note = T.addChest(A.x, A.y, A.z, A.side, { holds = { "*brick*", "*stone*", "*_stairs", "*_slab" } })
    check("...six pairs of globs with one chest: the first three said, then how many more", text.count(tostring(note), " overlaps ") == 3
        and text.endsWith(tostring(note), "; and 3 more of its globs overlap"), tostring(note))
end

do
    -- T.sortChests
    setUp()
    T.catalogue()
    local moves = W.S.moves
    local ok, info = T.sortChests()
    check("T.sortChests with no chest for anything: true, nothing moved, nowhere gone", ok == true and next(info.moved) == nil
        and info.stacks == 0 and W.S.moves == moves)
    T.addChest(A.x, A.y, A.z, A.side, { holds = "cobblestone" })
    T.addChest(D.x, D.y, D.z, D.side, { holds = "*_planks" })
    local why
    ok, why, info = T.sortChests()
    if ok then info = why end
    check("T.sortChests: the planks out of A (for cobblestone) and B (plain) into D (for planks), D's iron to the bulk chest",
        ok == true and chestHas(2, -1, -2, PLANKS) == 45 and chestHas(3, 0, 1, PLANKS) == 0 and chestHas(-3, 0, 1, PLANKS) == 0
        and chestHas(0, 0, -3, IRON) == 7 and chestHas(2, -1, -2, IRON) == 0, tostring(why))
    check("...what stays put stays: A's cobblestone, B's stone, the bulk chest's dirt", chestHas(3, 0, 1, COBBLE) == 64
        and chestHas(-3, 0, 1, STONE) == 10 and chestHas(0, 0, -3, DIRT) == 30)
    check("...info says what moved and how many stacks", info and info.moved[PLANKS] == 45 and info.moved[IRON] == 7 and info.stacks == 3
        and #info.left == 0 and info.more == false)
    check("...the turtle is home, facing as before, carrying nothing it took", here() and carrying(PLANKS) == 0 and carrying(IRON) == 0)
    check("...the list is right", line(T.chests(), 2, -2, "down").items[PLANKS] == 45 and line(T.chests(), 3, 0, 0).items[PLANKS] == nil)
    check("nothing was thrown into the world", (W.thrown or 0) == 0)
    moves = W.S.moves
    ok, info = T.sortChests()
    check("sorted already: nothing to do, nowhere gone", ok == true and info.stacks == 0 and W.S.moves == moves)

    -- opts.limit
    setUp()
    T.addChest(A.x, A.y, A.z, A.side, { holds = "cobblestone" })
    T.addChest(D.x, D.y, D.z, D.side, { holds = "*_planks" })
    T.catalogue()
    ok, info = T.sortChests({ limit = 1 })
    check("opts.limit = 1: one stack moved, info.more says there is more", ok == true and info.stacks == 1 and info.more == true
        and chestHas(2, -1, -2, PLANKS) + chestHas(0, 0, -3, IRON) > 0 and here())
    ok, why = T.sortChests({ limit = 0 })
    check("...a limit that is not a whole number of stacks: nil and why", ok == nil and type(why) == "string" and why:find("limit", 1, true), tostring(why))

    -- no room where it belongs: put back, and said
    setUp()
    T.addChest(A.x, A.y, A.z, A.side, { holds = "cobblestone" })
    local items = {}
    for s = 1, 27 do items[s] = { BIRCH, 64 } end
    fill(2, -1, -2, items)
    T.addChest(D.x, D.y, D.z, D.side, { holds = "*_planks" })
    T.catalogue()
    ok, why, info = T.sortChests()
    check("the chest for planks is full: false, the planks back where they were, and why", ok == false and chestHas(3, 0, 1, PLANKS) == 40
        and chestHas(-3, 0, 1, PLANKS) == 5 and carrying(PLANKS) == 0 and here() and type(why) == "string"
        and why:find("oak_planks", 1, true) and why:find("full", 1, true), tostring(why))
    check("...info.left has each with its chest and why", info and #info.left == 2 and info.left[1].name == PLANKS and info.left[1].why
        and info.left[1].why:find("chest at 2,-1,-2 full", 1, true), info and info.left[1] and tostring(info.left[1].why))

    -- nowhere for it at all: not taken out
    setUp()
    T.forgetChest(C.x, C.y, C.z, C.side)
    T.addChest(D.x, D.y, D.z, D.side, { holds = "*_planks" })
    T.catalogue()
    ok, why, info = T.sortChests()
    check("iron in the chest for planks with no bulk chest: left there and said, the planks still moved", ok == false
        and chestHas(2, -1, -2, IRON) == 7 and carrying(IRON) == 0 and chestHas(2, -1, -2, PLANKS) == 45 and why:find("iron_ingot", 1, true)
        and why:find("no bulk chest", 1, true), tostring(why))

    -- a chest that is gone
    setUp()
    T.addChest(A.x, A.y, A.z, A.side, { holds = "cobblestone" })
    T.addChest(D.x, D.y, D.z, D.side, { holds = "*_planks" })
    T.catalogue()
    W.set(3, 0, 1, nil)
    ok, why, info = T.sortChests()
    check("a chest that is gone: said, the rest sorted", ok == false and why:find("no chest on the front of 3,0,0", 1, true)
        and chestHas(2, -1, -2, PLANKS) == 5 and chestHas(0, 0, -3, IRON) == 7 and here(), tostring(why))
end

--------------------------------------------------------------------------
-- T.recount
--------------------------------------------------------------------------
do
    -- the known chest on a side read again, as after the turtle's own drops or a craft there
    setUp()
    T.catalogue()
    T.moveTo(3, 0, 0)
    T.face(0)
    fill(3, 0, 1, { [1] = { COBBLE, 8 } })
    CLOCK = 1500
    local c, why = T.recount("front")
    check("T.recount reads the known chest in front again: the list is right, with the time", c and c.items[COBBLE] == 8 and c.items[PLANKS] == nil
        and c.x == 3 and c.side == 0 and line(T.chests(), 3, 0, 0).items[COBBLE] == 8 and line(T.chests(), 3, 0, 0).seen == 1500, tostring(why))
    T.moveTo(2, 0, -2)
    fill(2, -1, -2, { [1] = { IRON, 1 } })
    c = T.recount("down")
    check("...below (\"bottom\" or \"down\")", c and c.items[IRON] == 1 and line(T.chests(), 2, -2, "down").items[IRON] == 1)
    local none
    none, why = T.recount("top")
    check("no known chest on that side: nil and why", none == nil and type(why) == "string" and why:find("no known chest on the top", 1, true) ~= nil, tostring(why))
    none, why = T.recount("left")
    check("a side that is not front, top or bottom: nil and why", none == nil and type(why) == "string" and why:find("front", 1, true) ~= nil, tostring(why))
    CLOCK = 1000
end

--------------------------------------------------------------------------
-- Staying at the chest; the report of everything; getting ready in one trip
--------------------------------------------------------------------------
do
    setUp()
    T.catalogue()
    local got = T.fetch(COBBLE, 5, { stay = true })
    check("T.fetch with opts.stay takes the count and stays at the chest (no walk back)", got == 5 and carrying(COBBLE) == 5 and here(3, 0, 0, 0),
        W.S.P.x .. "," .. W.S.P.y .. "," .. W.S.P.z)
    W.give(9, DIRT, 3)
    local ok = T.stow({ stay = true })
    check("T.stow with opts.stay stays at the last chest too", ok == true and carrying(DIRT) == 0 and here(0, 0, -2, 2), W.S.P.x .. "," .. W.S.P.z)
    W.give(9, DIRT, 3); W.give(10, STONE, 2)
    ok = T.stow({ keep = { "dirt" } })
    check("T.stow's opts.keep leaves what it names aboard (a list, no namespace)", ok == true and carrying(DIRT) == 3 and carrying(STONE) == 0)
end

do
    fresh()
    local report, info = T.inventoryReport()
    check("the report with no chests: what is aboard only, empty here", #report == 0 and info.kinds == 0 and info.chests == 0)
    setUp()
    T.catalogue()
    W.give(1, COBBLE, 6)
    CLOCK = CLOCK + 300
    T.fetch(PLANKS, 1)                                  -- (B is read again now: its count is new, A's is 5 minutes old)
    local moves = W.S.moves
    report, info = T.inventoryReport()
    local names = {}
    for i, r in ipairs(report) do names[i] = r.name:sub(11) .. " " .. r.total end
    check("T.inventoryReport: every item across the chests and the turtle, totalled, by name", table.concat(names, ", ")
        == "cobblestone 70, dirt 30, iron_ingot 7, oak_planks 45, stone 10" and info.kinds == 5 and info.items == 162 and info.chests == 4,
        table.concat(names, ", "))
    check("...each with what is aboard, in the chests and in how many, and the oldest count's age", report[1].turtle == 6 and report[1].chests == 64
        and report[1].places == 1 and report[1].age == 300 and report[4].turtle == 1 and report[4].places == 2 and report[4].age == 300 and report[5].age == 0
        and info.oldest == 300, tostring(report[1].age) .. " " .. tostring(report[5].age))
    check("...as lines too", info.text:find("cobblestone 70: turtle 6, 1 chest, read 5m ago\n", 1, true) ~= nil
        and info.text:find("oak_planks 45: turtle 1, 2 chests, read 5m ago", 1, true) ~= nil and info.text:find("stone 10: 1 chest, read 0s ago", 1, true) ~= nil,
        info.text)
    check("...and it moves nothing", W.S.moves == moves and here())
    report = T.inventoryReport({ sort = "count" })
    check("opts.sort = \"count\": the most first", report[1].name == COBBLE and report[2].name == PLANKS and report[5].name == IRON)
    report = T.inventoryReport({ match = "*planks" })
    check("opts.match: only what it names", #report == 1 and report[1].total == 45)
    CLOCK = 1000
end

do
    setUp()
    T.catalogue()
    W.give(1, DIRT, 10)
    W.give(2, "minecraft:torch", 5)
    W.give(3, "minecraft:coal", 3)
    W.give(4, STONE, 4)
    W.give(5, "minecraft:gravel", 2)
    local homes = 0
    local remove = T.onChange(function(e) if e.kind == "move" and e.x == 0 and e.y == 0 and e.z == 0 then homes = homes + 1 end end)
    local ok, info = T.prepare({ need = { cobblestone = 20, [STONE] = 4, [IRON] = 3 }, freeSlots = 10 })
    remove()
    check("T.prepare: the dirt, the gravel and the torches put away, 20 cobblestone and 3 iron fetched, the stone kept", ok == true
        and carrying(COBBLE) == 20 and carrying(IRON) == 3 and carrying(STONE) == 4 and carrying(DIRT) == 0 and carrying("minecraft:gravel") == 0
        and carrying("minecraft:torch") == 0 and info.fetched[COBBLE] == 20 and info.stowed == 17, tostring(ok) .. " " .. tostring(info and info.stowed))
    check("...fuel stays aboard, and the room asked for is there", carrying("minecraft:coal") == 3 and info.free >= 10, tostring(info.free))
    check("...in one trip: home only at the end, facing as before", homes == 1 and here(), tostring(homes))
    check("...the chests' list says where it all went", line(T.chests(), 0, -2, 2).items[DIRT] == 40 and line(T.chests(), 3, 0, 0).items[COBBLE] == 44)

    -- short in the chests' list: refused before it moves
    local moves = W.S.moves
    local why
    ok, why, info = T.prepare({ need = { diamond = 2, [COBBLE] = 30 } })
    check("T.prepare short of something (as the chests were last read): refused before moving, naming what and how much", ok == nil
        and why == "short of diamond: need 2, have 0 (aboard and in the chests as last read; T.catalogue reads them again, spec.partial goes for what there is)"
        and info.short[1].item == "minecraft:diamond" and W.S.moves == moves, tostring(why))
    -- spec.partial: what there is, and it says what is still short
    ok, why, info = T.prepare({ need = { [IRON] = 10 }, partial = true })
    check("...spec.partial goes for what there is, then fails loudly with what is still short", ok == false and why:find("short of iron_ingot: need 10, have 7", 1, true)
        and carrying(IRON) == 7 and here(), tostring(why))
    -- not the room asked for
    for s = 6, 16 do W.give(s, "minecraft:iron_pickaxe", 1) end
    ok, why, info = T.prepare({ need = {}, freeSlots = 8 })
    check("...and too few slots free after: false, saying how many", ok == false and why:find("only 4 slots free, 8 wanted", 1, true) and info.free == 4,
        tostring(why))
    check("bad arguments: nil and why", T.prepare({ need = { stone = -1 } }) == nil and T.prepare({ freeSlots = 17 }) == nil)
end

--------------------------------------------------------------------------
-- T.cfg.autoDump
--------------------------------------------------------------------------
do
    setUp()
    T.catalogue()
    check("the store module was loaded by the catalogue", package.loaded["tl.store"] ~= nil)
    for _, name in ipairs(MODS) do package.loaded[name] = nil end
    T = require("turtlelib")
    T.keep[PICK] = true
    check("the store is not loaded at start", package.loaded["tl.store"] == nil)
    T.cfg.autoDump = true
    check("setting T.cfg.autoDump loads it", package.loaded["tl.store"] ~= nil)
    -- 13 slots full of things; two free; a wall of dirt in front: the dig leaves one free
    for s = 1, 13 do W.give(s, "minecraft:item_" .. s, 64) end
    W.give(14, DIRT, 10)
    W.fill(0, 0, 1, 0, 0, 3, "minecraft:dirt")
    W.set(0, 0, 1, "minecraft:dirt")
    local moves = W.S.moves
    local ok = turtle.dig()
    check("a dig that leaves the room at the limit sends the turtle to the chests and back", ok and W.S.moves > moves and here()
        and carrying(DIRT) == 0 and chestHas(0, 0, -3, DIRT) == 30 + 11 and T.freeSlots() >= 2 and chestHas(0, 0, -3, "minecraft:item_1") == 64,
        tostring(W.S.moves - moves) .. " / " .. tostring(carrying(DIRT)))
    check("...it dumps the not-kept stuff only (the pickaxe's name is in T.keep)", carrying(PICK) == 0)
    -- room enough: no trip
    for s = 1, 16 do W.give(s, nil) end
    for s = 1, 11 do W.give(s, "minecraft:item_" .. s, 64) end
    W.set(0, 0, 1, "minecraft:dirt")
    moves = W.S.moves
    turtle.dig()
    check("with true the limit is two free slots: five free is room enough, no trip", W.S.moves == moves and carrying(DIRT) == 1)
    -- a move is not a dig
    for s = 1, 16 do W.give(s, "minecraft:item_" .. s, 64) end
    T.forward()
    check("only a dig starts the trip: a move with the inventory full goes on", W.S.moves == moves + 1 and T.pos.z == 1)
    T.back()
    for s = 1, 16 do W.give(s, nil) end
    -- nothing to stow: not tried again until there is less room
    for s = 1, 16 do W.give(s, nil) end
    T.keep[DIRT] = true
    for s = 1, 14 do T.keep["minecraft:kept_" .. s] = true; W.give(s, "minecraft:kept_" .. s, 64) end
    local calls = 0
    local rawDump = T.autoDump
    T.autoDump = function(...) calls = calls + 1; return rawDump(...) end
    W.set(0, 0, 1, "minecraft:dirt")
    turtle.dig()
    local first = calls
    W.set(0, 0, 1, "minecraft:dirt")
    turtle.dig()
    local second = calls
    W.give(16, "minecraft:kept_15", 1)
    T.keep["minecraft:kept_15"] = true
    W.set(0, 0, 1, "minecraft:dirt")
    turtle.dig()
    check("a dump that finds nothing to put away is not tried again until there is less room", first == 1 and second == 1 and calls == 2 and carrying(DIRT) == 3,
        first .. " " .. second .. " " .. calls)
    T.autoDump = rawDump
    T.keep[DIRT] = nil
    -- the number form
    setUp()
    T.catalogue()
    for _, name in ipairs(MODS) do package.loaded[name] = nil end
    T = require("turtlelib")
    T.cfg.autoDump = 5
    for s = 1, 10 do W.give(s, "minecraft:item_" .. s, 64) end
    W.set(0, 0, 1, "minecraft:dirt")
    moves = W.S.moves
    turtle.dig()
    check("T.cfg.autoDump = 5 dumps at five free slots", W.S.moves > moves and carrying("minecraft:item_1") == 0 and here())
    T.cfg.autoDump = false
    for s = 1, 15 do W.give(s, "minecraft:item_" .. s, 64) end
    W.set(0, 0, 1, "minecraft:dirt")
    moves = W.S.moves
    turtle.dig()
    check("turned off: nothing happens", W.S.moves == moves)
end

do
    -- part stacks are merged before the free slots are counted: a tidy that makes the room makes no trip
    setUp()
    T.catalogue()
    T.cfg.autoDump = true
    for s = 1, 10 do W.give(s, "minecraft:item_" .. s, 64) end
    W.give(11, COBBLE, 10); W.give(12, COBBLE, 10); W.give(13, PLANKS, 5); W.give(14, PLANKS, 5)
    W.set(0, 0, 1, "minecraft:dirt")
    local moves = W.S.moves
    turtle.dig()
    check("a dig at the limit with part stacks aboard: merged first, room enough, no trip", W.S.moves == moves and T.freeSlots() == 3
        and carrying(COBBLE) == 20 and carrying(DIRT) == 1, W.S.moves - moves .. " moves, " .. T.freeSlots() .. " free")
    T.cfg.autoDump = false
    for s = 1, 16 do W.give(s, nil) end

    -- a dump that fails is said and noted in the job; two in a row turn autoDump off
    local said = {}
    local quiet = print
    print = function(...) said[#said + 1] = table.concat({ ... }, " ") end
    T.job.start("dig the cellar", { "dig" })
    T.cfg.autoDump = true
    local calls = 0
    local rawDump = T.autoDump
    T.autoDump = function() calls = calls + 1; return false, "the chests are full" end
    for s = 1, 13 do W.give(s, "minecraft:item_" .. s, 64) end
    W.set(0, 0, 1, "minecraft:dirt")
    turtle.dig()
    local notes = T.job.resume().notes
    check("a failed dump: said, and noted in the job", calls == 1 and said[1] == "autoDump: the chests are full"
        and notes[#notes] == "autoDump: the chests are full" and T.cfg.autoDump == true, tostring(said[1]) .. " / " .. tostring(notes[#notes]))
    W.give(15, "minecraft:item_15", 64)
    W.set(0, 0, 1, "minecraft:dirt")
    turtle.dig()
    notes = T.job.resume().notes
    check("...a second in a row turns it off, and says so", calls == 2 and T.cfg.autoDump == false
        and said[2] == "autoDump is off after two failures in a row: the chests are full (set T.cfg.autoDump again once that is put right)"
        and notes[#notes] == said[2], tostring(said[2]))
    W.give(15, nil)
    W.set(0, 0, 1, "minecraft:dirt")
    turtle.dig()
    check("...and then it is not tried", calls == 2)
    T.autoDump = rawDump
    print = quiet
    T.job.clear()
end

do
    -- no chests: the junk chest's trip
    fresh()
    W.set(3, 0, 1, "minecraft:chest")
    T.setJunkChest(3, 0, 0, 0)
    T.cfg.autoDump = true
    for s = 1, 14 do W.give(s, "minecraft:item_" .. s, 64) end
    W.give(15, DIRT, 5)
    W.set(0, 0, 1, "minecraft:dirt")
    local moves = W.S.moves
    turtle.dig()
    check("with no chests it takes the junk to the junk chest", W.S.moves > moves and chestHas(3, 0, 1, DIRT) == 6 and here())
    local ok, why = T.autoDump()
    check("T.autoDump says what it did", ok == true)
    fresh()
    ok, why = T.autoDump()
    check("with neither: nil and why", ok == nil and why:find("nowhere to dump", 1, true), tostring(why))
end

do
    -- other copies of the library share one dump, not one each
    setUp()
    T.catalogue()
    package.loaded.turtlelib = nil
    package.loaded["tl.store"] = nil
    local T2 = require("turtlelib")
    T2.cfg.autoDump = true
    T = T2
    T.claim()
    for s = 1, 14 do W.give(s, "minecraft:item_" .. s, 64) end
    W.give(15, DIRT, 5)
    W.set(0, 0, 1, "minecraft:dirt")
    turtle.dig()
    check("a second copy of the library: one dump, the dirt in the bulk chest once", chestHas(0, 0, -3, DIRT) == 36 and here())
end
