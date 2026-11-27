-- sim/mine_terrain.lua
--
-- `mine` through real Minecraft terrain: each fixture sim/terrain/index.lua
-- lists (boxes of a test world, read by sim/terrain.py) dug with the
-- arguments it gives, water flowing.  The same checks hold for all of
-- them: the program never fails with an error; it never moves on an empty
-- tank; no water or lava is left in the tunnel or touching the open space
-- it reaches (the tunnel, the veins it dug, the caves it broke into);
-- the tunnel is dug but for what it leaves standing; it ends at the start.
-- Each prints its moves, turns, digs and blocks placed.
local PROJ = ...
package.path = PROJ .. "/turtle/?.lua;" .. PROJ .. "/lib/?.lua;" .. PROJ .. "/sim/lib/?.lua;" .. package.path
local Mine = require("mineworld")
local run = Mine.runner(PROJ)
local get, chestAt = Mine.get, Mine.chestAt
local setup, stock = Mine.setup, Mine.stock
local startAt, atStart = Mine.startAt, Mine.atStart
local check, logHas = Mine.check, Mine.logHas
local isWater = Mine.isWater

local DIRS = { { 1, 0, 0 }, { -1, 0, 0 }, { 0, 1, 0 }, { 0, -1, 0 }, { 0, 0, 1 }, { 0, 0, -1 } }
local function fluid(b) return b and (isWater(b) or b.name == "minecraft:lava") end

local index = PROJ .. "/sim/terrain/index.lua"
local ok, fixtures = pcall(dofile, index)
if not ok then fixtures = {} end
check("terrain fixtures listed in sim/terrain/index.lua", #fixtures > 0, #fixtures .. " of them")

for _, f in ipairs(fixtures) do
    local name = f.name
    setup(f.scanner and { { name = SCANNER, count = 1 }, { name = "minecraft:chest", count = 8 },
                          { name = "minecraft:coal", count = 256 } } or stock(8, 256))
    local bulk = chestAt(0, -1, 0)
    for _ = 1, f.bulk or 20 do table.insert(bulk, { name = "minecraft:cobblestone", count = 64 }) end
    local wet, ores = Mine.terrain(PROJ .. "/sim/terrain/" .. f.file)
    startAt(); Mine.inv, Mine.files = {}, {}
    EQ = { left = "advancedperipherals:chunk_controller", right = "minecraft:diamond_pickaxe" }
    FUEL, DRY, PLACED, DIGS = f.fuel or 20000, 0, 0, 0
    WATERY = true
    Mine.settleWater()
    run(table.unpack(f.args))
    WATERY = false
    local w, h, length = tonumber(f.args[1]), tonumber(f.args[2]), tonumber(f.args[3])
    local inTunnel, left = 0, 0
    for x = 0, w - 1 do for y = 0, h - 1 do for z = 1, length do
        local b = get(x, y, z)
        if fluid(b) then inTunnel = inTunnel + 1 end
        if b and not fluid(b) then left = left + 1 end
    end end end
    -- the open space the tunnel reaches (it, the veins and caves it broke
    -- into), within the fixture's box: water or lava touching it isn't sealed
    local bx0, bx1, by0, by1, _, bz1 = table.unpack(dofile(PROJ .. "/sim/terrain/" .. f.file).box)
    local reached, queue, open, where = {}, {}, 0, {}
    local function key(x, y, z) return x .. "," .. y .. "," .. z end
    for x = 0, w - 1 do for y = 0, h - 1 do for z = 1, length do
        if not get(x, y, z) then reached[key(x, y, z)] = true; queue[#queue + 1] = { x, y, z } end
    end end end
    local i = 1
    while queue[i] do
        local c = queue[i]
        i = i + 1
        for _, d in ipairs(DIRS) do
            local x, y, z = c[1] + d[1], c[2] + d[2], c[3] + d[3]
            if x >= bx0 and x <= bx1 and y >= by0 and y <= by1 and z >= 1 and z <= bz1 then
                local b = get(x, y, z)
                if fluid(b) then
                    open = open + 1
                    if #where < 4 then where[#where + 1] = key(x, y, z) .. " " .. b.name .. ":" .. tostring(b.level) end
                elseif not b and not reached[key(x, y, z)] then
                    reached[key(x, y, z)] = true
                    queue[#queue + 1] = { x, y, z }
                end
            end
        end
    end
    local stood = 0
    for _ in (Mine.files["mine.blocked"] or ""):gmatch("[^\n]+") do stood = stood + 1 end
    check(name .. ": no error", not logHas("%.lua:%d+:"), string.format("%d blocks of water or lava, %d of ore", wet, ores))
    check(name .. ": finished", logHas("^Done"), string.format("moves %d, turns %d, digs %d, placed %d",
        Mine.moves, Mine.turns, DIGS or 0, PLACED or 0))
    check(name .. ": never moved on an empty tank", DRY == 0, "tried " .. DRY)
    check(name .. ": no water or lava in the tunnel", inTunnel == 0, inTunnel .. " blocks")
    check(name .. ": none touching the open space the tunnel reaches (sealed off)", open == 0,
        open .. " open faces " .. table.concat(where, "; "))
    check(name .. ": dug, but for what it leaves standing", left <= stood, left .. " blocks left, " .. stood .. " left standing")
    check(name .. ": back at the start", atStart())
end
