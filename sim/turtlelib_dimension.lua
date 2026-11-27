-- sim/turtlelib_dimension.lua
--
-- The dimension (ADR-0023 D1), on sim/lib/buildworld's mock world.
--   * T.dimension under auto: netherrack round the turtle says the nether, stone the overworld, end stone the end,
--     each sure, from the blocks next to it (up, down, ahead: nothing turns, no fuel); nothing round it, or a near
--     tie, is the overworld and not sure, info.why saying so; a look that doesn't decide goes by the map's blocks
--     near it; the setting turtle.dimension overrides the blocks; a ccnixmod global with a dimension function wins
--     under auto, and one naming a dimension it doesn't know falls back to the blocks, saying so;
--   * the decision is kept (blocks changed round it, the same answer) until opts.again; T.cfg.dimension follows it;
--   * T.darkCells and T.planLights use the nether's limit in the nether with no opts.dimension.
local PROJ = ...
package.path = PROJ .. "/turtle/?.lua;" .. PROJ .. "/lib/?.lua;" .. PROJ .. "/sim/lib/?.lua;" .. package.path
local M = require("mock")
local B = require("buildworld")
local realCheck = M.check
-- (a check's detail is only shown when it fails)
local function check(label, ok, detail) realCheck(label, ok, (not ok) and detail or nil) end

os.epoch = function() return 1000 * 1000 end
local CLK = 0
os.clock = function() CLK = CLK + 0.001; return CLK end
local SETTINGS, DEFAULTS = {}, {}
settings = {
    define = function(name, opts) DEFAULTS[name] = opts.default end,
    get = function(name) if SETTINGS[name] ~= nil then return SETTINGS[name] end return DEFAULTS[name] end,
}
print = function() end

local NETHERRACK, STONE, END_STONE = "minecraft:netherrack", "minecraft:stone", "minecraft:end_stone"
local AIR = "minecraft:air"
local W, T
local MODULES = { "turtlelib", "tl.world", "tl.path", "tl.lint", "tl.light", "tl.attach" }

-- A new world with the turtle at 0,0,0 facing +z and the library loaded afresh; `round` is the block over, under and
-- ahead of it (nil: air).
local function fresh(round)
    W = B.new({ facing = "north" })
    W.install()
    SETTINGS = {}
    ccnixmod = nil
    for _, name in ipairs(MODULES) do package.loaded[name] = nil end
    T = require("turtlelib")
    if round then
        W.set(0, 1, 0, round)
        W.set(0, -1, 0, round)
        W.set(0, 0, 1, round)
    end
    return W, T
end
-- The map told what the world holds in a box (air included).
local function know(x1, y1, z1, x2, y2, z2)
    for x = x1, x2 do for y = y1, y2 do for z = z1, z2 do
        local b = W.get(x, y, z)
        T.map.set(x, y, z, b and b.name or AIR, b and b.state or nil)
    end end end
end
-- T.dimension(opts), whatever happens: dim, how, info (or nil and the error).
local function dim(opts)
    local ok, d, how, info = pcall(function() return T.dimension(opts) end)
    if not ok then return nil, d, {} end
    return d, how, info or {}
end

--------------------------------------------------------------------------
-- Auto, by the blocks
--------------------------------------------------------------------------
do
    fresh(NETHERRACK)
    local turns, moves = W.S.turns, W.S.moves
    local d, how, info = dim()
    check("auto in netherrack: the nether, sure, from the blocks next to it", d == "nether" and how == "auto"
        and info.sure == true and info.said == "in the nether, from the blocks round it", tostring(d) .. " " .. tostring(how)
        .. " " .. tostring(info.said))
    check("...it only looked: no turn, no move", W.S.turns == turns and W.S.moves == moves)
    check("...and T.cfg.dimension follows it", T.cfg.dimension == "nether", tostring(T.cfg.dimension))
    fresh(STONE)
    d, how, info = dim()
    check("auto in stone: the overworld, sure", d == "overworld" and how == "auto" and info.sure == true, tostring(d))
    fresh(END_STONE)
    d, how, info = dim()
    check("auto on end stone: the end, sure", d == "end" and info.sure == true, tostring(d))
    fresh()
    d, how, info = dim()
    check("nothing round it: the overworld, not sure, and why", d == "overworld" and info.sure == false
        and tostring(info.why):find("too few blocks round it to tell", 1, true) ~= nil, tostring(d) .. " " .. tostring(info.why))
    check("...the line says it isn't sure", tostring(info.said):find("not sure", 1, true) ~= nil, tostring(info.said))
end

do
    -- a look that doesn't decide: netherrack under, stone over; the map's blocks near it count then
    fresh()
    W.set(0, -1, 0, NETHERRACK)
    W.set(0, 1, 0, STONE)
    W.fill(2, -1, 2, 4, -1, 4, NETHERRACK)            -- 9 netherrack in the map
    W.fill(-4, -1, -4, -2, -1, -2, STONE)             -- 9 stone
    know(-5, -2, -5, 5, 2, 5)
    local d, how, info = dim({ again = true })
    check("a near tie (the look split, the map 10 to 10): the overworld, not sure, \"a near tie\"", d == "overworld"
        and info.sure == false and tostring(info.why):find("a near tie", 1, true) ~= nil, tostring(d) .. " " .. tostring(info.why))
    W.fill(-4, -1, -4, -2, -1, -2, nil)
    know(-5, -2, -5, 5, 2, 5)
    d, how, info = dim({ again = true })
    check("...the map's netherrack near it decides when the look doesn't", d == "nether" and info.sure == true
        and info.near and info.near.nether == 10, tostring(d) .. " " .. tostring(info.why))
end

do
    -- kept: the blocks change, the answer doesn't, until opts.again
    fresh(NETHERRACK)
    dim()
    W.set(0, 1, 0, STONE)
    W.set(0, -1, 0, STONE)
    W.set(0, 0, 1, STONE)
    local d = dim()
    check("the decision is kept: stone round it now, still the nether", d == "nether", tostring(d))
    d = dim({ again = true })
    check("...opts.again decides again: the overworld", d == "overworld", tostring(d))
end

--------------------------------------------------------------------------
-- The setting and the mod
--------------------------------------------------------------------------
do
    fresh(NETHERRACK)
    SETTINGS["turtle.dimension"] = "end"
    local d, how, info = dim()
    check("the setting turtle.dimension overrides the blocks: the end, \"set\"", d == "end" and how == "set"
        and info.said == "in the end (turtle.dimension)", tostring(d) .. " " .. tostring(how) .. " " .. tostring(info.said))
    SETTINGS["turtle.dimension"] = "the_nether"
    d, how = dim()
    check("...the game's name too", d == "nether" and how == "set", tostring(d))
    SETTINGS["turtle.dimension"] = "moon"
    d, how, info = dim({ again = true })
    check("...a name it doesn't know: by the blocks, and it says so", d == "nether" and how == "auto"
        and tostring(info.setting):find("not overworld, nether, end or auto", 1, true) ~= nil, tostring(info.setting))
end

do
    fresh(STONE)
    local asked = 0
    ccnixmod = { dimension = function() asked = asked + 1; return "minecraft:the_nether" end }
    local d, how, info = dim()
    check("a ccnixmod global wins under auto: the nether in stone, from the mod", d == "nether" and how == "auto"
        and info.from == "the mod" and info.said == "in the nether, from the mod", tostring(d) .. " " .. tostring(info.said))
    SETTINGS["turtle.dimension"] = "overworld"
    d, how = dim()
    check("...the setting still goes first", d == "overworld" and how == "set", tostring(d))
    fresh(STONE)
    ccnixmod = { dimension = function() return "twilightforest:twilight_forest" end }
    d, how, info = dim()
    check("...a dimension the mod names that isn't one of the three: by the blocks, and it says so", d == "overworld"
        and tostring(info.modWhy):find("twilightforest:twilight_forest", 1, true) ~= nil, tostring(d) .. " " .. tostring(info.modWhy))
    ccnixmod = nil
end

--------------------------------------------------------------------------
-- Lighting goes by it
--------------------------------------------------------------------------
do
    -- a corridor of netherrack, a torch at one end: 20 feet cells, x 1..20 at y 1
    fresh()
    for x = -1, 21 do for y = 0, 3 do for z = -1, 1 do
        if not (x >= 0 and x <= 20 and y >= 1 and y <= 2 and z == 0) then W.set(x, y, z, NETHERRACK) end
    end end end
    W.set(0, 1, 0, "minecraft:torch")
    know(-1, 0, -1, 21, 3, 1)
    local cells, info = T.darkCells({ 1, 1, 0, 20, 1, 0 })
    check("T.darkCells in the nether with no opts.dimension: the nether's limit, 11", cells and info.dimension == "nether"
        and info.max == 11 and cells.dimension == "nether", tostring(info and info.dimension))
    local candidates = {}
    for x = 1, 20 do candidates[#candidates + 1] = { x, 2, 1 } end
    local _, plan = T.planLights({ { x = 5, y = 1, z = 0 } }, candidates)
    check("...and T.planLights the nether's 12", plan and plan.summary:find("to light 12", 1, true) ~= nil, plan and plan.summary)
end
