-- sim/turtlelib_copies.lua
--
-- Two programs on one turtle (ADR-0008): each program the shell runs loads a copy of turtlelib (and of the modules) of
-- its own, but there is one turtle.  On sim/lib/buildworld's mock world, as claude does with run_program:
--   * T.cfg.autoDump turned on by one program (claude) doesn't make the stow trip on another's digs, from its own
--     out-of-date position; it acts again once its program owns the turtle (T.claim);
--   * T.cfg.undo turned on by one program keeps journalling its own work after another program loaded tl.journal (a
--     report does), and the other program's digs aren't in its journal;
--   * claude's `status` asking T.origin() makes no map on disk, so no program starts loading tl.world and writing one;
--     a T.map.set starts one, and from then the moves are noted;
--   * a Ctrl+T while the geo scanner works stops the scan; it isn't asked again.
local PROJ = ...
package.path = PROJ .. "/turtle/?.lua;" .. PROJ .. "/lib/?.lua;" .. PROJ .. "/sim/lib/?.lua;" .. package.path
local M = require("mock")
local B = require("buildworld")
local check = M.check

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

local MODS = { "turtlelib", "tl.world", "tl.path", "tl.store", "tl.journal" }
local STONE, DIRT = "minecraft:stone", "minecraft:dirt"

-- A new world with a floor and a chest at (0,0,-3), the pickaxe on the left.
local function world()
    local W = B.new({ facing = "north" })
    W.install()
    EQ.left = "minecraft:diamond_pickaxe"
    for x = -5, 5 do for z = -5, 5 do W.set(x, -1, z, STONE) end end
    W.set(0, 0, -3, "minecraft:chest")
    return W
end
-- The library as a program the shell runs loads it: a copy of its own (the turtle and its wrap stay).
local function program()
    for _, m in ipairs(MODS) do package.loaded[m] = nil end
    return require("turtlelib")
end
local function chestHolds(W, name)
    local n = 0
    for _, it in pairs(W.get(0, 0, -3).inv or {}) do
        if it.name == name then n = n + it.count end
    end
    return n
end

--------------------------------------------------------------------------
-- autoDump belongs to the program that turned it on
--------------------------------------------------------------------------
local W = world()
local A = program()                        -- claude
A.addChest(0, 0, -2, 2, true)
A.cfg.autoDump = true
local Bp = program()                       -- the program claude runs
Bp.forward(); Bp.forward(); Bp.forward()
for s = 1, 13 do W.give(s, "minecraft:item_" .. s, 64) end
W.set(0, 0, 4, DIRT)
local moves = W.S.moves
turtle.dig()
check("another program's dig doesn't set off the first's autoDump", W.S.moves == moves and Bp.pos.z == 3 and W.S.P.z == 3,
    (W.S.moves - moves) .. " moves")
check("...and the position file is the running program's", fs.open(Bp.dataPath(".turtlepos"), "r").readAll() == "0 0 3 0 flat")
-- claude takes the turtle back (after run_program), and knows where it is (as claude does: takeSavedPos)
A.claim()
A.pos.x, A.pos.y, A.pos.z, A.dir = 0, 0, 3, 0
W.set(0, 0, 4, DIRT)
turtle.dig()
check("once its program owns the turtle again, the dig makes the trip: the chest gets the junk",
    chestHolds(W, "minecraft:item_1") == 64 and W.S.P.z == 3 and A.pos.z == 3, chestHolds(W, "minecraft:item_1") .. " in the chest")

--------------------------------------------------------------------------
-- The undo journal belongs to the program that turned it on
--------------------------------------------------------------------------
W = world()
A = program()
A.cfg.undo = true
A.undoClear()
W.set(0, 0, 1, DIRT)
turtle.dig()
check("the program's own dig is journalled", A.undoMark() == 1, tostring(A.undoMark()))
local C = program()                        -- another program; a report loads tl.journal in it
C.job.status()
W.set(0, 0, 1, DIRT)
turtle.dig()
check("another program's dig isn't in the first one's journal", A.undoMark() == 1, tostring(A.undoMark()))
A.claim()
W.set(0, 0, 1, DIRT)
turtle.dig()
check("...and the first one's journal goes on after the other loaded tl.journal", A.undoMark() == 2, tostring(A.undoMark()))

--------------------------------------------------------------------------
-- Asking about the map makes none
--------------------------------------------------------------------------
W = world()
A = program()
local origin, why = A.origin()
check("T.origin() with no map: nil and why", origin == nil and why ~= nil, tostring(why))
check("...and no map on disk", not fs.exists(A.dataPath(A.MAP_DIR)))
A.forward()
A.map.flush()
check("moves with no map on disk write none", not fs.exists(A.dataPath(A.MAP_DIR)))
program()
check("...so the next program doesn't load tl.world at start", package.loaded["tl.world"] == nil)
A = program()
A.map.set(0, -1, 0, STONE)
A.forward()
A.map.flush()
check("T.map.set starts a map, and from then the moves are noted", fs.exists(A.dataPath(A.MAP_DIR))
    and A.map.get(0, 0, 1) == "minecraft:air", tostring(A.map.get(0, 0, 1)))

--------------------------------------------------------------------------
-- Ctrl+T during a scan
--------------------------------------------------------------------------
W = world()
A = program()
local calls = 0
W.give(16, "advancedperipherals:geo_scanner", 1)
local SCANNER = "advancedperipherals:geo_scanner"
local realPeripheral = peripheral
-- (a scanner whose call is interrupted by Ctrl+T)
peripheral = setmetatable({
    getType = function(side) if EQ[side] == SCANNER then return "geoScanner" end return realPeripheral.getType(side) end,
    getMethods = function(side) if EQ[side] == SCANNER then return { "scanBlocks" } end return realPeripheral.getMethods(side) end,
    wrap = function(side)
        if EQ[side] == SCANNER then return { scanBlocks = function() calls = calls + 1; error("Terminated", 0) end } end
        return realPeripheral.wrap(side)
    end,
}, { __index = realPeripheral })
local ok, err = pcall(A.scan, 2)
peripheral = realPeripheral
check("a Ctrl+T while the scanner works stops the scan", not ok and err == "Terminated", tostring(err))
check("...and the scanner isn't asked again", calls == 1, calls .. " scans")
