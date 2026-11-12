-- sim/turtlelib_junk.lua
--
-- The junk policy (ADR-0008, D5): T.isJunk never calls crafted items, T.keep
-- items, tools, fuel or peripherals junk; T.dumpJunk goes to the junk chest
-- and back, and nothing is ever dropped into the world: no chest there, no
-- way there, or a full chest leaves everything in the turtle.
local PROJ = ...
package.path = PROJ .. "/turtle/?.lua;" .. PROJ .. "/lib/?.lua;" .. PROJ .. "/sim/lib/?.lua;" .. package.path
local M = require("mock")
local check = M.check

local S = M.state()
fs = M.fsApi(S)
textutils = M.textutilsApi()
shell = M.shellApi("x.lua")
sleep = function() end

local W, CH = {}, {}                    -- blocks by cell; the chests' contents by cell
local function get(x, y, z) return W[M.key(x, y, z)] or (CH[M.key(x, y, z)] and { name = "minecraft:chest" }) or nil end
S.get = get
local GROUND = 0                        -- items the turtle has thrown into the world

local function inspectAt(x, y, z)
    local b = get(x, y, z)
    if not b then return false, "No block to inspect" end
    return true, { name = b.name, state = {} }
end
turtle = M.merge(
    M.inventoryApi(S), M.fuelApi(S), M.noAttackApi(),
    M.movementApi(S, function(b) return b == nil end),
    M.lookingApi(S, inspectAt, function(b) return b ~= nil end),
    M.actingApi(S, "dig", function() return false, "Nothing to dig here" end),
    M.actingApi(S, "drop", function(x, y, z, _, n)
        local c = CH[M.key(x, y, z)]
        if c then return M.dropInto(S, c, 27, n) end
        local it = S.inv[S.sel]
        if not it then return false end
        local k = math.min(n or it.count, it.count)
        GROUND = GROUND + k                       -- (no chest there: it lands in the world)
        it.count = it.count - k
        if it.count == 0 then S.inv[S.sel] = nil end
        return true
    end))

package.loaded.turtlelib = nil
local T = require("turtlelib")
local function put(slot, name, count) S.inv[slot] = name and { name = name, count = count or 1 } or nil end
local function carrying(name)
    local n = 0
    for s = 1, 16 do
        if S.inv[s] and S.inv[s].name == name then n = n + S.inv[s].count end
    end
    return n
end
local function inChest(c, name)
    local n = 0
    for q = 1, 27 do
        if c[q] and c[q].name == name then n = n + c[q].count end
    end
    return n
end
local function home(x, y, z, d)
    S.P.x, S.P.y, S.P.z, S.P.d = x or 0, y or 0, z or 0, d or 0
    T.pos.x, T.pos.y, T.pos.z, T.dir = x or 0, y or 0, z or 0, d or 0
    S.moves, S.turns = 0, 0
end
local function at() return string.format("(%d,%d,%d) facing %d", T.pos.x, T.pos.y, T.pos.z, T.dir) end

local COBBLE, DIRT, GRAVEL, COAL = "minecraft:cobblestone", "minecraft:dirt", "minecraft:gravel", "minecraft:coal"
local BRICKS, SCANNER = "minecraft:stone_bricks", "advancedperipherals:geo_scanner"
local PICK = "minecraft:diamond_pickaxe"

--------------------------------------------------------------------------
-- What is junk
--------------------------------------------------------------------------
T.keep[COBBLE] = true                    -- the job builds with it
check("junk is what nothing keeps", T.isJunk(DIRT) and T.isJunk(GRAVEL) and T.isJunk("minecraft:netherrack"))
check("T.keep items are not junk", not T.isJunk(COBBLE) and not T.isJunk("minecraft:torch"))
check("fuel is not junk", not T.isJunk(COAL) and not T.isJunk("minecraft:lava_bucket"))
check("tools are not junk", not T.isJunk(PICK) and not T.isJunk("minecraft:iron_hoe"))
check("peripherals, buckets and a crafting table are not junk", not T.isJunk(SCANNER) and not T.isJunk("computercraft:wireless_modem_normal")
    and not T.isJunk("minecraft:bucket") and not T.isJunk("minecraft:crafting_table"))
check("what T.craft made is junk before it is marked, and not after", T.isJunk(BRICKS))
T.markCrafted(BRICKS)
check("...marked: not junk", not T.isJunk(BRICKS))
T.clearCrafted()
check("...T.clearCrafted starts a new job", T.isJunk(BRICKS))
T.markCrafted(BRICKS)

--------------------------------------------------------------------------
-- The junk chest's place
--------------------------------------------------------------------------
check("no junk chest to begin with", T.junkChest() == nil)
local ok, why = T.dumpJunk()
check("T.dumpJunk with none set: false and why", ok == false and why and why:find("no junk chest set", 1, true), tostring(why))
ok, why = T.setJunkChest(3, 0, 0, "front")
check("a side that is not up, down or a heading: nil and why", ok == nil and why and why:find("heading 0 to 3", 1, true), tostring(why))
ok, why = T.setJunkChest(3.5, 0, 0, "up")
check("whole numbers", ok == nil and why and why:find("whole numbers", 1, true), tostring(why))
check("T.setJunkChest keeps the place in a data file", T.setJunkChest(3, 0, 0, "up") == true and S.files[".junkchest"] == "3 0 0 up",
    tostring(S.files[".junkchest"]))
local spot = T.junkChest()
check("T.junkChest reads it back", spot and spot.x == 3 and spot.y == 0 and spot.z == 0 and spot.side == "up")
package.loaded.turtlelib = nil
local T2 = require("turtlelib")
local spot2 = T2.junkChest()
check("another copy of turtlelib reads the same one", spot2 and spot2.x == 3 and spot2.side == "up")
T = T2
T.keep[COBBLE] = true
T.markCrafted(BRICKS)
check("\"top\" and \"bottom\" are the same as up and down", T.setJunkChest(3, 0, 0, "top") == true and S.files[".junkchest"] == "3 0 0 up"
    and T.setJunkChest(3, 0, 0, "bottom") == true and S.files[".junkchest"] == "3 0 0 down")
T.setJunkChest(3, 0, 0, "up")

--------------------------------------------------------------------------
-- Going to the chest
--------------------------------------------------------------------------
local function stock()
    S.inv, S.sel = {}, 1
    put(1, PICK); put(2, COBBLE, 64); put(3, DIRT, 64); put(4, GRAVEL, 20); put(5, COAL, 5)
    put(6, BRICKS, 8); put(7, SCANNER); put(8, "minecraft:bucket")
end
local chest = {}
CH["3,1,0"] = chest
stock(); home(0, 0, 0, 2); GROUND = 0
local dropped, left
ok, dropped, left = T.dumpJunk()
check("T.dumpJunk: true, how many went in, how many didn't", ok == true and dropped == 84 and left == 0, tostring(ok) .. " " .. tostring(dropped) .. " " .. tostring(left))
check("the junk is in the chest", inChest(chest, DIRT) == 64 and inChest(chest, GRAVEL) == 20)
check("what is kept stays: the tool, T.keep, fuel, what was crafted, the scanner, the bucket",
    carrying(PICK) == 1 and carrying(COBBLE) == 64 and carrying(COAL) == 5 and carrying(BRICKS) == 8 and carrying(SCANNER) == 1
    and carrying("minecraft:bucket") == 1 and carrying(DIRT) == 0 and carrying(GRAVEL) == 0)
check("it came back to where it was, facing as it did", at() == "(0,0,0) facing 2" and S.P.x == 0 and S.P.d == 2, at())
check("nothing was thrown into the world", GROUND == 0)
check("the selected slot is as it was", S.sel == 1)

local moves = S.moves
ok, dropped, left = T.dumpJunk()
check("with no junk aboard it goes nowhere", ok == true and dropped == 0 and left == 0 and S.moves == moves, S.moves .. " moves")

-- crafted things stop being safe when the job ends
T.clearCrafted()
ok, dropped = T.dumpJunk()
check("once T.clearCrafted starts a new job, the old crafted stack is junk too", ok and dropped == 8 and inChest(chest, BRICKS) == 8)

--------------------------------------------------------------------------
-- When it can't be done, nothing goes into the world
--------------------------------------------------------------------------
T.markCrafted(BRICKS)
-- the chest is gone
stock(); home(0, 0, 0, 1); GROUND = 0
CH["3,1,0"] = nil
ok, why = T.dumpJunk()
check("the junk chest is gone: false and why, nothing dropped", ok == false and why and why:find("no chest at the junk chest's place", 1, true)
    and GROUND == 0 and carrying(DIRT) == 64 and carrying(GRAVEL) == 20, tostring(why))
check("...and the turtle came home", at() == "(0,0,0) facing 1", at())

-- a full chest
local full = {}
for q = 1, 27 do full[q] = { name = "minecraft:gold_ingot", count = 64 } end
CH["3,1,0"] = full
stock(); home(0, 0, 0, 0); GROUND = 0
ok, dropped, left = T.dumpJunk()
check("a full chest: everything stays in the turtle, and it says how many didn't fit",
    ok == true and dropped == 0 and left == 84 and carrying(DIRT) == 64 and GROUND == 0, tostring(ok) .. " " .. tostring(dropped) .. " " .. tostring(left))
-- room for part of it
full[27] = nil
full[26] = { name = "minecraft:gold_ingot", count = 64 }
ok, dropped, left = T.dumpJunk()
check("a chest with room for one stack takes that and the rest stays", ok and dropped == 64 and left == 20 and GROUND == 0
    and carrying(GRAVEL) + carrying(DIRT) == 20, tostring(dropped) .. " in, " .. tostring(left) .. " left")

-- no way there
CH["3,1,0"] = {}
for _, d in ipairs({ { 1, 0, 0 }, { -1, 0, 0 }, { 0, 1, 0 }, { 0, -1, 0 }, { 0, 0, 1 }, { 0, 0, -1 } }) do
    W[M.key(d[1], d[2], d[3])] = { name = "minecraft:stone" }
end
stock(); home(0, 0, 0, 3); GROUND = 0
ok, why = T.dumpJunk()
check("walled in (it never digs): false and why, nothing dropped, still here",
    ok == false and why and why:find("can't get to the junk chest", 1, true) and GROUND == 0 and carrying(DIRT) == 64 and at() == "(0,0,0) facing 3",
    tostring(why) .. " " .. at())
W = {}

-- a chest in a heading
CH = { ["1,0,0"] = {} }
T.setJunkChest(0, 0, 0, 1)
stock(); home(0, 0, 0, 3); GROUND = 0
ok, dropped = T.dumpJunk()
check("a chest in front (side = a heading): turns to it, drops, and turns back",
    ok and dropped == 84 and inChest(CH["1,0,0"], DIRT) == 64 and GROUND == 0 and at() == "(0,0,0) facing 3", at())
