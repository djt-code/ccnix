-- sim/lib/farmworld.lua -- a farm for farm.lua to work, as the simulators
-- see it: a block world with strips of crops (or sugar cane) between
-- water lanes, a chest under the start, a hoe that tills and harvests, a
-- hopper behind home if the scenario puts one there, and the clock.
--
--     local F = require("farmworld")
--     F.build({ width = 5, length = 6, lanes = { 3 }, crops = { ... } })
--     F.chest = { { name = "minecraft:wheat_seeds", count = 64 } }
--     F.run("5", "6", "0")
--
-- The turtle starts at (0,0,0) facing +z, two above the farmland (y=-2);
-- crops stand at y=-1 and the dirt floor is at y=-3.  State the
-- scenarios read and set: F.inv (the turtle's slots), F.chest (the home
-- chest's, 1..F.CHEST_SIZE), F.files, F.P, F.moves, F.get/F.set for
-- blocks.  Knobs and counters, as globals: FUEL/LOWEST/DRY (see mock),
-- EQ, CLOCK and STOP_AT (sleep raises "STOP" past it), HOPPER/HOPPED (the
-- compost hopper's load and what went in), MEAL (bone meal used), POURS/
-- SCOOPS/FIRSTPOUR/LASTPOUR (buckets), LOST (cane knocked to the ground),
-- SPILLED, SPLIT, PUSHES.
--
-- Water follows the vanilla infinite-source rule at lane level: an open
-- (or flowing) cell on a floor with two source neighbours becomes a
-- source, after every change.  F.STUCK["x,z"] = true keeps a cell from
-- doing so (a lane the turtle has to pour itself).

local M = require("mock")
local F = M.state()
math.randomseed(42)            -- bone meal grows crops by chance: the same way every run

F.CANE = "minecraft:sugar_cane"
F.PLANT = { ["minecraft:wheat_seeds"] = "minecraft:wheat", ["minecraft:carrot"] = "minecraft:carrots",
            ["minecraft:potato"] = "minecraft:potatoes", ["minecraft:beetroot_seeds"] = "minecraft:beetroots" }
F.RIPE = { ["minecraft:wheat"] = 7, ["minecraft:carrots"] = 7, ["minecraft:potatoes"] = 7, ["minecraft:beetroots"] = 3 }
F.DROPS = { ["minecraft:wheat"] = { "minecraft:wheat", "minecraft:wheat_seeds" },
            ["minecraft:carrots"] = { "minecraft:carrot", "minecraft:carrot" },
            ["minecraft:potatoes"] = { "minecraft:potato", "minecraft:potato" },
            ["minecraft:beetroots"] = { "minecraft:beetroot", "minecraft:beetroot_seeds" } }
local TILL = { ["minecraft:dirt"] = true, ["minecraft:grass_block"] = true }
local CANE_GROUND = { ["minecraft:sand"] = true, ["minecraft:dirt"] = true, ["minecraft:grass_block"] = true }
local WATER = "minecraft:water"

--------------------------------------------------------------------------
-- The world
--------------------------------------------------------------------------
local W = {}                   -- W["x,y,z"] = { name = , age = , level = }
F.WIDTH, F.LENGTH = 0, 0
F.LANES = {}                   -- x (or z, along x) -> true
F.CHEST_SIZE = 27
F.STUCK = {}
EQ = { right = "minecraft:diamond_hoe" }
CLOCK, HOPPER, HOPPED = 0, 0, {}

function F.get(x, y, z) return W[M.key(x, y, z)] end
F.print = M.realPrint          -- the simulator's own output (print is the program's)

local function isSource(b) return b and b.name == WATER and not b.level end

-- Vanilla infinite water at lane level (y=-2): an open or flowing cell on
-- a floor with two source neighbours becomes a source, until nothing
-- changes.
local function settleWater()
    local changed = true
    while changed do
        changed = false
        for x = -1, F.WIDTH + 2 do
            for z = -1, F.LENGTH + 2 do
                local c = F.get(x, -2, z)
                if (not c or (c.name == WATER and c.level)) and F.get(x, -3, z) and not F.STUCK[x .. "," .. z] then
                    local n = 0
                    for _, d in ipairs(M.SIDES4) do
                        if isSource(F.get(x + d[1], -2, z + d[2])) then n = n + 1 end
                    end
                    if n >= 2 then W[M.key(x, -2, z)] = { name = WATER }; changed = true end
                end
            end
        end
    end
end
F.settleWater = settleWater

function F.set(x, y, z, b)
    W[M.key(x, y, z)] = b
    settleWater()
end

-- Lay the farm out.  opts: width, length (tiles out from the start),
-- lanes (list of x, or of z with alongX), crops (x -> crop block name or
-- "cane"; wheat where unsaid), unripe (the age of unripe crops, 1).
-- Crops alternate ripe and unripe by (x + z); cane stands (z % 3) + 1
-- high on sand.
function F.build(opts)
    opts = opts or {}
    F.WIDTH, F.LENGTH = opts.width or 5, opts.length or 6
    F.LANES = {}
    for _, l in ipairs(opts.lanes or { 3 }) do F.LANES[l] = true end
    local crops = opts.crops or {}
    for key in pairs(W) do W[key] = nil end
    W[M.key(0, -1, 0)] = { name = "minecraft:chest" }
    for x = 0, F.WIDTH + 1 do
        for z = 0, F.LENGTH + 1 do
            W[M.key(x, -3, z)] = { name = "minecraft:dirt" }
            local inside = x >= 1 and x <= F.WIDTH and z >= 1 and z <= F.LENGTH
            if not inside then
                if not (x == 0 and z == 0) then W[M.key(x, -2, z)] = { name = "minecraft:grass_block" } end
            elseif (opts.alongX and F.LANES[z]) or (not opts.alongX and F.LANES[x]) then
                W[M.key(x, -2, z)] = { name = WATER }
            elseif crops[x] == "cane" then
                W[M.key(x, -2, z)] = { name = "minecraft:sand" }
                for h = 1, (z % 3) + 1 do W[M.key(x, -2 + h, z)] = { name = F.CANE } end
            else
                local c = crops[x] or "minecraft:wheat"
                W[M.key(x, -2, z)] = { name = "minecraft:farmland" }
                W[M.key(x, -1, z)] = { name = c, age = (x + z) % 2 == 0 and F.RIPE[c] or (opts.unripe or 1) }
            end
        end
    end
    settleWater()
end

-- Every crop ripe.
function F.ripen()
    for x = 1, F.WIDTH do for z = 1, F.LENGTH do
        local b = F.get(x, -1, z)
        if b and F.RIPE[b.name] then b.age = F.RIPE[b.name] end
    end end
end

-- How many crops stand on the farm, and how many of them are ripe.
function F.cropCount()
    local n, ripe = 0, 0
    for x = 1, F.WIDTH do for z = 1, F.LENGTH do
        local b = F.get(x, -1, z)
        if b and F.RIPE[b.name] then
            n = n + 1
            if b.age >= F.RIPE[b.name] then ripe = ripe + 1 end
        end
    end end
    return n, ripe
end

-- Lane tiles that aren't a water source.
function F.badLaneTiles()
    local bad = 0
    for x in pairs(F.LANES) do for z = 1, F.LENGTH do
        if not isSource(F.get(x, -2, z)) then bad = bad + 1 end
    end end
    return bad
end

-- Cane heights along column x, "3 1 2 ...".
function F.caneHeights(x)
    local h = {}
    for z = 1, F.LENGTH do
        local n = 0
        while (F.get(x, -2 + n + 1, z) or {}).name == F.CANE do n = n + 1 end
        h[#h + 1] = n
    end
    return table.concat(h, " ")
end

-- Cane standing on top of a cut cane pops off as items on the ground.
local function caneAbove(x, y, z)
    y = y + 1
    while (F.get(x, y, z) or {}).name == F.CANE do
        W[M.key(x, y, z)] = nil
        LOST = (LOST or 0) + 1
        y = y + 1
    end
end

local function waterBeside(x, y, z)
    for _, d in ipairs(M.SIDES4) do
        if isSource(F.get(x + d[1], y, z + d[2])) then return true end
    end
    return false
end

-- Does water at (x,y,z) come back when scooped (two source neighbours)?
local function regen(x, y, z)
    local n = 0
    for _, d in ipairs(M.SIDES4) do
        if isSource(F.get(x + d[1], y, z + d[2])) then n = n + 1 end
    end
    return n >= 2
end

--------------------------------------------------------------------------
-- The turtle
--------------------------------------------------------------------------
local function passable(b) return b == nil or b.name == WATER end
local function inspectAt(x, y, z)
    local b = F.get(x, y, z)
    if not b then return false end
    return true, { name = b.name, state = { age = b.age, level = b.level or (b.name == WATER and 0 or nil) } }
end
local function atHome() return F.P.x == 0 and F.P.y == 0 and F.P.z == 0 end
local function hasPickaxe() return EQ.right == "minecraft:diamond_pickaxe" or EQ.left == "minecraft:diamond_pickaxe" end

-- Digging: a pickaxe takes any block (farmland comes up as dirt); the hoe
-- harvests crops, cuts cane, and tills dirt, through one block of air
-- below the turtle as CC lets it.
local function dig(x, y, z, dir)
    local b = F.get(x, y, z)
    if hasPickaxe() then
        if not b or b.name == WATER then return false end
        F.set(x, y, z, nil)
        if b.name == F.CANE then caneAbove(x, y, z) end
        M.addItem(F, b.name == "minecraft:farmland" and "minecraft:dirt" or b.name, 1)
        return true
    end
    if b and b.name == F.CANE then
        F.set(x, y, z, nil)
        caneAbove(x, y, z)
        M.addItem(F, F.CANE, 1)
        return true
    end
    if dir ~= "down" then return false end
    if b and F.RIPE[b.name] then
        F.set(x, y, z, nil)
        local d = F.DROPS[b.name]
        if b.age >= F.RIPE[b.name] then M.addItem(F, d[1], 1) end
        M.addItem(F, d[2], 1)
        return true
    end
    if not b then y = y - 1; b = F.get(x, y, z) end         -- through the gap
    if b and TILL[b.name] then F.set(x, y, z, { name = "minecraft:farmland" }); return true end
    return false
end

-- Placing: bone meal on a crop, seeds and cane on their ground, dirt into
-- an open or wet block, water from a bucket, and a bucket scooping a
-- source (which stays if two sources feed it).
local function place(x, y, z, dir)
    local it = F.inv[F.sel]
    if not it then return false end
    local b = F.get(x, y, z)
    if dir ~= "down" then
        if it.name ~= "minecraft:dirt" or not passable(b) then return false end
        F.set(x, y, z, { name = "minecraft:dirt" })
        M.useSel(F)
        return true
    end
    if it.name == "minecraft:bone_meal" then
        if not (b and F.RIPE[b.name]) or b.age >= F.RIPE[b.name] then return false end
        if b.name == "minecraft:beetroots" then
            if math.random(4) > 1 then b.age = b.age + 1 end
        else
            b.age = math.min(F.RIPE[b.name], b.age + math.random(2, 5))
        end
        M.useSel(F)
        MEAL = (MEAL or 0) + 1
        return true
    elseif F.PLANT[it.name] then
        local g = F.get(x, y - 1, z)
        if b or not (g and g.name == "minecraft:farmland") then return false end
        F.set(x, y, z, { name = F.PLANT[it.name], age = 0 })
        M.useSel(F)
        return true
    elseif it.name == F.CANE then
        local g = F.get(x, y - 1, z)
        if b or not (g and CANE_GROUND[g.name] and waterBeside(x, y - 1, z)) then return false end
        F.set(x, y, z, { name = F.CANE })
        M.useSel(F)
        return true
    elseif it.name == "minecraft:dirt" then
        if not passable(b) then return false end
        F.set(x, y, z, { name = "minecraft:dirt" })
        M.useSel(F)
        return true
    elseif it.name == "minecraft:water_bucket" then
        if not passable(b) then return false end
        F.inv[F.sel] = { name = "minecraft:bucket", count = 1 }
        POURS = (POURS or 0) + 1
        FIRSTPOUR = FIRSTPOUR or F.moves
        LASTPOUR = F.moves
        F.set(x, y, z, { name = WATER })
        return true
    elseif it.name == "minecraft:bucket" then
        if not isSource(b) then return false end
        if not regen(x, y, z) then F.set(x, y, z, nil) end
        SCOOPS = (SCOOPS or 0) + 1
        -- the filled bucket replaces a lone empty one, else needs a slot
        if it.count == 1 then F.inv[F.sel] = { name = "minecraft:water_bucket", count = 1 }; return true end
        M.useSel(F)
        M.addItem(F, "minecraft:water_bucket", 1)
        return true
    end
    return false
end

local function hopperAt(x, y, z) return (F.get(x, y, z) or {}).name == "minecraft:hopper" end
local HOPPER_ROOM = 320          -- five stacks

-- Dropping: down into the home chest (over it), forward into a hopper.
local function drop(x, y, z, dir, n)
    if dir == "down" then
        if not atHome() then return false end
        return M.dropInto(F, F.chest, F.CHEST_SIZE, n)
    end
    if dir ~= "front" or not hopperAt(x, y, z) then return false end
    local it = F.inv[F.sel]
    if not it then return false end
    n = math.min(n or it.count, it.count, HOPPER_ROOM - HOPPER)
    if n <= 0 then return false end
    HOPPER = HOPPER + n
    HOPPED[it.name] = (HOPPED[it.name] or 0) + n
    M.useSel(F, n)
    return true
end

local function suck(x, y, z, dir, n)
    if dir ~= "down" or not atHome() then return false end
    return M.suckFrom(F, F.chest, F.CHEST_SIZE, n)
end

turtle = M.merge(
    M.movementApi(F, passable),
    M.lookingApi(F, inspectAt, function(b) return b ~= nil end),
    M.actingApi(F, "dig", dig),
    M.actingApi(F, "place", place),
    M.actingApi(F, "drop", drop),
    M.actingApi(F, "suck", suck),
    M.noAttackApi(),
    M.inventoryApi(F),
    M.equipmentApi(F),
    M.fuelApi(F)
)

--------------------------------------------------------------------------
-- The computer and the world around it
--------------------------------------------------------------------------
fs = M.fsApi(F)
textutils = textutils or M.textutilsApi()   -- (lib/fileio, under turtlelib, reads JSON with it)
shell = M.shellApi("farm.lua")
peripheral = {
    wrap = function(side)
        if side == "back" then
            if not hopperAt(M.behind(F)) then return nil end
            return {
                size = function() return 5 end,
                list = function()
                    local t = {}
                    for i = 1, math.ceil(HOPPER / 64) do t[i] = { name = "x", count = 64 } end
                    return t
                end,
            }
        end
        if side == "bottom" and atHome() then return M.containerPeripheral(F.chest, F.CHEST_SIZE, "bottom") end
        return nil
    end,
    getName = function(p) return p._name end,
}
os.clock = function() return CLOCK end
os.startTimer = function() return 1 end
os.pullEvent = function() error("blocked waiting for a key") end
-- Sleeping moves the clock on; the composter drains the hopper meanwhile;
-- past STOP_AT the simulator stops the program ("STOP").
sleep = function(t)
    t = t or 0
    CLOCK = CLOCK + t
    HOPPER = math.max(0, HOPPER - 2.5 * t)
    if STOP_AT and CLOCK > STOP_AT then error("STOP", 0) end
end

-- what watchsim.lua draws: the world, the turtle and the farm's size
SIM_WORLD = { W = { get = F.get, set = F.set }, P = F.P, moves = function() return F.moves end }
setmetatable(SIM_WORLD, { __index = function(_, k) if k == "width" then return F.WIDTH elseif k == "length" then return F.LENGTH end end })

F.chest = {}
M.capturePrint(F)

--------------------------------------------------------------------------
-- Running and reporting
--------------------------------------------------------------------------
F.check = M.check
function F.logHas(pat) return M.logHas(F, pat) end

-- Run farm.lua with these arguments (see mock.runner).
function F.runner(proj, opts)
    opts = opts or {}
    opts.stopped = opts.stopped or function(err)
        if err == "STOP" then return "(stopped by the simulator)" end
    end
    return M.runner(F, proj .. "/turtle/farm.lua", opts)
end

-- The home chest: "64 dirt, 128 wheat seeds" (sorted), and the totals.
function F.chestLine() return M.contents(F.chest, F.CHEST_SIZE) end

-- Stock the home chest: wheat seeds and dirt; with `carrots`, carrots and
-- beetroot seeds; with `cane` (a count), sugar cane and beetroot seeds;
-- and `water` water buckets (two).
function F.stock(opts)
    opts = opts or {}
    F.chest = { { name = "minecraft:wheat_seeds", count = 64 }, { name = "minecraft:dirt", count = 64 } }
    if opts.carrots then F.chest[#F.chest + 1] = { name = "minecraft:carrot", count = 64 } end
    if opts.cane then F.chest[#F.chest + 1] = { name = F.CANE, count = opts.cane } end
    if opts.carrots or opts.cane then F.chest[#F.chest + 1] = { name = "minecraft:beetroot_seeds", count = 64 } end
    for _ = 1, opts.water or 2 do
        F.chest[#F.chest + 1] = { name = "minecraft:water_bucket", count = 1 }
    end
end

-- The farm as two maps by row z: the ground (F farmland, ~ water, d dirt,
-- s sand) and what grows on it (w c p b, | cane).
function F.show(label)
    M.realPrint("-- " .. label .. ": y=-2 / y=-1 by row z (x=1.." .. F.WIDTH .. ")")
    local G = { ["minecraft:farmland"] = "F", [WATER] = "~", ["minecraft:dirt"] = "d", ["minecraft:sand"] = "s" }
    local C = { ["minecraft:wheat"] = "w", ["minecraft:carrots"] = "c", ["minecraft:potatoes"] = "p",
                ["minecraft:beetroots"] = "b", [F.CANE] = "|" }
    for z = F.LENGTH, 1, -1 do
        local g, c = {}, {}
        for x = 1, F.WIDTH do
            local b = F.get(x, -2, z)
            g[#g + 1] = b and (G[b.name] or "?") or " "
            local w = F.get(x, -1, z)
            c[#c + 1] = w and (C[w.name] or "?") or "."
        end
        M.realPrint("   z=" .. z .. "  " .. table.concat(g) .. "   " .. table.concat(c))
    end
end

return F
