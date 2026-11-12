-- sim/turtlelib_store.lua
--
-- tl.store (ADR-0008 phase 4): the chests at home, on sim/lib/buildworld's mock world (chests with their slots and the
-- peripheral that lists them).
--   * T.addChest / T.forgetChest / T.chests: the places kept in a data file other copies of the library read, whole
--     numbers and a real side asked for, one bulk chest;
--   * T.catalogue: goes round the chests nearest first, writes down what each holds, comes back facing as before; a
--     chest that is gone or unreachable is reported and the rest are read; chests given as places are remembered;
--     opts.find adds the chests the map shows in a box;
--   * T.where: the chests with an item (a name, a glob, no namespace), nearest first, with the total;
--   * T.fetch: goes to the chest that has it, takes the count (across chests when it must), keeps the list right, tries
--     the next chest when one is empty behind its back, stops for no room, comes back;
--   * T.stow: an item into the chest that holds it, the rest into the bulk chest; what the job keeps, tools, fuel and
--     peripherals stay aboard unless opts.all (never the tools); a full chest and a missing bulk chest leave the item
--     aboard and say so; nothing is ever dropped in the world;
--   * T.cfg.autoDump: setting it loads the module; the room running out on a dig sends the turtle to the chests and
--     back; with no chests it takes the junk chest's trip; a dump that did nothing is not tried again at once.
local PROJ = ...
package.path = PROJ .. "/turtle/?.lua;" .. PROJ .. "/lib/?.lua;" .. PROJ .. "/sim/lib/?.lua;" .. package.path
local M = require("mock")
local B = require("buildworld")
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
    check("...a barrel counts, and what was known stays", ok == true and #T.chests() == 3 and info.chests == 3 and (function()
        for _, c in ipairs(T.chests()) do if c.items["minecraft:wheat"] == 12 then return true end end
    end)())
    check("...and the turtle ends where it began", here())
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

    setUp()
    T.forgetChest(C.x, C.y, C.z, C.side)
    T.addChest(C.x, C.y, C.z, C.side)
    T.catalogue()
    W.give(1, "minecraft:gravel", 10)
    W.give(2, COBBLE, 10)
    ok, why, info = T.stow()
    check("no bulk chest: what a chest holds goes in, the rest stays aboard and is reported", ok == false and chestHas(3, 0, 1, COBBLE) == 74 and carrying(COBBLE) == 0
        and carrying("minecraft:gravel") == 10 and info.left["minecraft:gravel"] == 10 and next(info.left, "minecraft:gravel") == nil, tostring(why))
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
