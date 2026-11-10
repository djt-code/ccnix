-- sim/mow_lawn.lua
--
-- mow.lua over a lawn laid on the mine's rock: a 5x4 lawn of grass, a
-- fern and a dead bush with a step up, a dip, a crevasse and a stone
-- pillar in the way (every tile cut, the pillar and the crevasse given
-- up and the tiles past them reached round them, home at the end, a hoe
-- parked and put back); torches on the lattice for a 16x16 lawn, none
-- with `notorch`, a warning with none on board; a chest below home that
-- the seeds end up in, with a trip home mid-pass when down to two empty
-- slots; the settings (a size given is kept, the repeat only if given,
-- nothing when the turtle may not be at home, plain `mow` mows the saved
-- size) and a Ctrl+T in the wait between passes; `mow reset` from a dip
-- out on the lawn.
local PROJ = ...
package.path = PROJ .. "/turtle/?.lua;" .. PROJ .. "/lib/?.lua;" .. PROJ .. "/sim/lib/?.lua;" .. package.path
local M = require("mock")
local Mine = require("mineworld")
local P = Mine.P
local get, set, chestAt = Mine.get, Mine.set, Mine.chestAt
local check, logHas, contents = Mine.check, Mine.logHas, Mine.contents

-- A Ctrl+T in the wait between passes (sleep is a no-op otherwise)
sleep = function(s) if s >= 60 then error("Terminated", 0) end end
-- mow lists the tiles it gave up on with io.write and ends the line with print()
local capture, partial = print, {}
io = { write = function(s) partial[#partial + 1] = s end }
print = function(...) capture(table.concat(partial) .. table.concat({ ... }, " ")); partial = {} end

local run = M.runner(Mine, PROJ .. "/turtle/mow.lua", {
    before = function() DIGS = 0 end,
    stats = function() return "moves: " .. Mine.moves .. ", turns: " .. Mine.turns .. ", digs: " .. DIGS end,
    stopped = function(err) if err == "Terminated" then return "(stopped in the wait between passes, as if by Ctrl+T)" end end,
})

-- A lawn w x l (tiles x = 1..w, z = 1..l): grass blocks at y = -1 with
-- air above, a block round it for detours, the turtle at home on a block
-- of it (or over a chest), a pickaxe on its right and a full tank.
local function block(name) return { name = name } end
local function lawn(w, l, chest)
    Mine.setup({})                                     -- (its chests go under the lawn)
    for x = -1, w + 1 do for z = -1, l + 1 do
        set(x, -1, z, block("minecraft:grass_block"))
        for y = 0, 6 do set(x, y, z, nil) end
    end end
    if chest then set(0, -1, 0, Mine.chest()) end
    Mine.startAt(); Mine.inv, Mine.files = {}, {}
    EQ = { right = "minecraft:diamond_pickaxe" }
    FUEL, LOWEST, DRY = 1000, 1000, 0
end

local GRASS = {}                     -- what was planted, to see it's all cut
local function plant(x, y, z, name)
    set(x, y, z, block(name or "minecraft:short_grass"))
    GRASS[#GRASS + 1] = { x, y, z }
end
local function uncut()
    local n = 0
    for _, g in ipairs(GRASS) do if get(g[1], g[2], g[3]) then n = n + 1 end end
    return n
end

-- The 5x4 lawn with something on every tile but two: a stone pillar at
-- (2,2), a crevasse at (5,2) (four deep: more than it climbs), a step up
-- at (3,2) (a block with grass on it), a dip at (4,3) (the ground a block
-- lower), a fern and a dead bush among the grass.
local function roughLawn()
    lawn(5, 4)
    GRASS = {}
    for x = 1, 5 do for z = 1, 4 do
        if x == 2 and z == 2 then for y = 0, 3 do set(x, y, z, block("minecraft:stone")) end
        elseif x == 5 and z == 2 then for y = -1, -4, -1 do set(x, y, z, nil) end
        elseif x == 3 and z == 2 then set(x, 0, z, block("minecraft:grass_block")); plant(x, 1, z)
        elseif x == 4 and z == 3 then set(x, -1, z, nil); set(x, -2, z, block("minecraft:grass_block")); plant(x, -1, z)
        elseif x == 1 and z == 3 then plant(x, 0, z, "minecraft:fern")
        elseif x == 4 and z == 1 then plant(x, 0, z, "minecraft:dead_bush")
        else plant(x, 0, z) end
    end end
end

local function torchesIn(w, l)          -- the torches standing on the lawn, by column
    local t = {}
    for x = 1, w do for z = 1, l do
        if Mine.isTorch(get(x, 0, z)) then t[#t + 1] = { x, z } end
    end end
    return t
end

--------------------------------------------------------------------------
-- 1. the rough lawn, a hoe on the left, no torches wanted
roughLawn()
EQ.left = "minecraft:diamond_hoe"
run("5", "4", "notorch")
check("every tile cut (18 had something on them)", #GRASS == 18 and uncut() == 0, uncut() .. " left")
check("the pillar and the crevasse given up, the tiles past them reached round them",
    logHas("^Gave up on 2 tiles") and logHas("^%(2,2%) %(5,2%) $") and get(2, 0, 2).name == "minecraft:stone"
    and get(5, -1, 2) == nil and not logHas("Can't reach %(2,1%)") and not logHas("Can't reach %(5,[34]%)"))
check("home again, facing forward", P.x == 0 and P.y == 0 and P.z == 0 and P.d == 0 and logHas("^Pass complete"))
check("fuel: one a move, and the moves fit 20 tiles with the climbs and detours",
    1000 - FUEL == Mine.moves and Mine.moves >= 30 and Mine.moves <= 80, Mine.moves .. " moves")
check("the seeds and the stick stay on board, there being no chest", M.carried(Mine, "minecraft:wheat_seeds") == 17
    and M.carried(Mine, "minecraft:stick") == 1 and (SPILLED or 0) == 0, (M.contents(Mine.inv, 16)))
check("the hoe parked while mowing and back on the left after",
    EQ.left == "minecraft:diamond_hoe" and EQ.right == "minecraft:diamond_pickaxe" and M.carried(Mine, "minecraft:diamond_hoe") == 0)

--------------------------------------------------------------------------
-- 2. torches: a 16x16 lawn with grass here and there and 16 torches on
--    board is lit on the lattice; `notorch` leaves them; none on board
--    is a warning
local function sparseLawn(w, l)
    lawn(w, l)
    GRASS = {}
    for x = 1, w do for z = 1, l do if (x * 3 + z) % 5 == 0 then plant(x, 0, z) end end end
end
sparseLawn(16, 16)
Mine.inv[1] = { name = "minecraft:torch", count = 16 }
run("16", "16")
local torches = torchesIn(16, 16)
local far, at = 0, {}
for x = 1, 16 do for z = 1, 16 do
    local best = 99
    for _, t in ipairs(torches) do best = math.min(best, math.abs(t[1] - x) + math.abs(t[2] - z)) end
    if best > 12 then far = far + 1 end
end end
for _, t in ipairs(torches) do at[#at + 1] = "(" .. t[1] .. "," .. t[2] .. ")" end
check("6 torches on the lattice, every tile within 12 of one", #torches == 6 and far == 0
    and logHas("^Lighting: 6 torch sites %(radius 12%)") and logHas("torches placed: 6$"),
    table.concat(at, " ") .. "; " .. far .. " tiles further off")
check("every tile cut, 10 torches left on board", uncut() == 0 and M.carried(Mine, "minecraft:torch") == 10)
sparseLawn(16, 16)
Mine.inv[1] = { name = "minecraft:torch", count = 16 }
run("16", "16", "notorch")
check("notorch: none placed, the 16 still on board", #torchesIn(16, 16) == 0 and M.carried(Mine, "minecraft:torch") == 16
    and not logHas("^Lighting:"))
sparseLawn(5, 4)
run("5", "4")
check("no torches on board: one warning, none placed", logHas("^No torches in inventory") and #torchesIn(5, 4) == 0
    and logHas("torches placed: 0$"))

--------------------------------------------------------------------------
-- 3. a chest below home: carrying 14 stacks of cobblestone from an earlier
--    job, it is down to one empty slot after the first cut and goes home
--    to empty mid-pass; the seeds end up in the chest
lawn(5, 4, true)
GRASS = {}
for x = 1, 5 do for z = 1, 4 do plant(x, 0, z) end end
for s = 1, 14 do Mine.inv[s] = { name = "minecraft:cobblestone", count = 64 } end
local visits = 0
ONMOVE = function(_, _, _, nx, _, nz) if nx == 0 and nz == 0 then visits = visits + 1 end end
run("5", "4", "notorch")
ONMOVE = nil
local line, n = contents(chestAt(0, -1, 0))
check("the seeds and the cobblestone in the chest, nothing on board",
    n["minecraft:wheat_seeds"] == 20 and n["minecraft:cobblestone"] == 14 * 64 and next(Mine.inv) == nil, line)
check("home twice: once mid-pass to empty, once at the end", visits == 2 and uncut() == 0, visits .. " times")

--------------------------------------------------------------------------
-- 4. the settings: a size given is kept for next time, the repeat only if
--    given, and only once the home check has passed; plain `mow` mows the
--    saved size.  (The stub gives a setting's default where none is set,
--    as CC does.)
local SAVED, DEFAULT = {}, {}
settings = {
    define = function(name, opts) DEFAULT[name] = opts.default end,
    get = function(name) if SAVED[name] == nil then return DEFAULT[name] end return SAVED[name] end,
    set = function(name, v) SAVED[name] = v end,
    save = function() SAVED.saved = true end,
}
lawn(5, 4)
run("5", "4", "7", "notorch")
check("mow 5 4 7: the size and the repeat kept", SAVED["mow.width"] == 5 and SAVED["mow.length"] == 4
    and SAVED["mow.repeat"] == 7 and SAVED.saved == true)
check("and it waited for the next pass", logHas("^Sleeping 7 min") and Mine.files[".turtlepos"] == "0 0 0 0 terrain")
SAVED = {}
lawn(6, 3)
run("6", "3", "notorch")
check("mow 6 3: the size kept, no repeat", SAVED["mow.width"] == 6 and SAVED["mow.length"] == 3
    and SAVED["mow.repeat"] == nil and SAVED.saved == true)
lawn(6, 3)
run("notorch")
check("plain mow: the saved size", logHas("^Mowing 6x3 %(18 tiles%)") and P.x == 0 and P.z == 0)
SAVED = {}
lawn(5, 4)
Mine.files[".turtlepos"] = "3 0 2 0 terrain"
run("5", "4", "notorch")
check("a turtle that may not be at home: told to reset, nothing saved and no move",
    logHas("^Turtle may not be at home") and logHas("`mow reset`") and next(SAVED) == nil and Mine.moves == 0)
settings = nil

--------------------------------------------------------------------------
-- 5. `mow reset` after a Ctrl+T down in the dip at (4,3), facing back
roughLawn()
P.x, P.y, P.z, P.d = 4, -1, 3, 2
Mine.files[".turtlepos"] = "4 -1 3 2 terrain"
run("reset")
check("home again over the terrain", P.x == 0 and P.y == 0 and P.z == 0 and P.d == 0 and logHas("^Home%.$")
    and Mine.files[".turtlepos"] == "0 0 0 0 terrain", Mine.moves .. " moves")
