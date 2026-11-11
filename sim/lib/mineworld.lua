-- sim/lib/mineworld.lua -- rock for mine.lua to tunnel through, as the
-- simulators see it: a world of mixed stone that's rock wherever nothing
-- else is set (and open space behind the start), chests, ore, lava,
-- gravel that falls, water that flows (roughly as Minecraft runs it), a
-- Geo Scanner, and the checks the scenarios make on what's left.
--
--     local Mine = require("mineworld")
--     Mine.setup(Mine.stock(4, 64)); Mine.features(); Mine.remember()
--     Mine.startAt(); Mine.inv, Mine.files = {}, {}
--     FUEL = 1000
--     Mine.run("3", "3", "12")
--
-- The turtle starts at (0,0,0) facing +z with chests above (valuables and
-- supplies) and below (bulk).  State the scenarios read and set: Mine.inv,
-- Mine.files, Mine.P, Mine.moves, Mine.turns, blocks through Mine.get/set.
-- Knobs and counters, as globals: FUEL/LOWEST/DRY, EQ, SCANNER, SCANS,
-- SCAN_TURN (a scanner whose idea of forward is turned), WORLD_COORDS (one
-- that gives world coordinates), WATERY (water flows) and BOX {x0,x1,y0,y1}
-- (the tunnel, for INGRESS: water flowing into it where it's open, past
-- the block just dug), WASHED (torches water took), PLACED, DIGS, SPLIT,
-- SPILLED, TRAVEL_DIGS (digging on a trip home and back), STOP_AT_DIG (a
-- Ctrl+T after so many digs), ONMOVE(ox, oy, oz, nx, ny, nz).  Minecarts:
-- Mine.ENTITIES[key] = { item = name, inv = {...} } (a chest minecart has
-- an inv); what they spill lies in Mine.GROUND[key].  BURNT[name]: what
-- refuelling burnt; CRAFTED[name]: what a crafting table made.

local M = require("mock")
local Mine = M.state()

--------------------------------------------------------------------------
-- World: W[key] = block, false = air; unset = the default rock
--------------------------------------------------------------------------
local W = {}
local k = M.key
local ROCK = { "minecraft:stone", "minecraft:stone", "minecraft:deepslate", "minecraft:andesite",
               "minecraft:diorite", "minecraft:granite", "minecraft:tuff" }
local function get(x, y, z)
    local b = W[k(x, y, z)]
    if b ~= nil then return b or nil end
    if z < 1 then return nil end                    -- open space behind the tunnel face
    return { name = ROCK[(x * 31 + y * 17 + z * 13) % #ROCK + 1] }
end
local function set(x, y, z, b) W[k(x, y, z)] = b or false end
Mine.get, Mine.set = get, set
Mine.print = M.realPrint

function Mine.chest(items) return { name = "minecraft:chest", inv = items or {} } end
function Mine.ore(name) return { name = name } end
local ORE_TAGS = { ["c:ores"] = true }
local DROP = {
    ["minecraft:stone"] = "minecraft:cobblestone", ["minecraft:deepslate"] = "minecraft:cobbled_deepslate",
    ["minecraft:iron_ore"] = "minecraft:raw_iron", ["minecraft:diamond_ore"] = "minecraft:diamond",
    ["minecraft:coal_ore"] = "minecraft:coal", ["minecraft:deepslate_gold_ore"] = "minecraft:raw_gold",
    ["minecraft:emerald_ore"] = "minecraft:emerald", ["modded:tin_vein"] = "modded:raw_tin",
    ["minecraft:wall_torch"] = "minecraft:torch",
    -- what mow.lua cuts: a seed from every tile (in game one in eight), a stick from a dead bush
    ["minecraft:short_grass"] = "minecraft:wheat_seeds", ["minecraft:tall_grass"] = "minecraft:wheat_seeds",
    ["minecraft:fern"] = "minecraft:wheat_seeds", ["minecraft:large_fern"] = "minecraft:wheat_seeds",
    ["minecraft:dead_bush"] = "minecraft:stick",
}
local FALLS = { ["minecraft:gravel"] = true, ["minecraft:sand"] = true }
-- A torch block: standing (minecraft:torch) or, hung on a wall, as the
-- game names it then, minecraft:wall_torch.
local TORCH_BLOCK = { ["minecraft:torch"] = true, ["minecraft:wall_torch"] = true }
local function isTorch(b) return type(b) == "table" and TORCH_BLOCK[b.name] == true end
Mine.isTorch = isTorch
local WATER_NAME = "minecraft:water"
local SIZE = 27                -- a chest's slots
Mine.SIZE = SIZE

-- The start (chests above and below), with the top one stocked.
function Mine.setup(stock)
    for key in pairs(W) do W[key] = nil end
    Mine.ENTITIES, Mine.GROUND, BURNT, CRAFTED = {}, {}, {}, {}
    set(0, 1, 0, Mine.chest(stock))                 -- valuables and supplies
    set(0, -1, 0, Mine.chest())                     -- bulk
end

-- Ore, lava and gravel for the first tunnel (3x3, x 0..2, y 0..2).
function Mine.features()
    local ore = Mine.ore
    -- vein A: iron out of the left wall at y=1, z=4, running to x=-5
    -- (x=-5 is 5 out: beyond the reach of 4, must stay)
    for x = -1, -5, -1 do set(x, 1, 4, ore("minecraft:iron_ore")) end
    set(-2, 2, 4, ore("minecraft:iron_ore"))
    -- vein B: diamond in the ceiling, going up
    set(1, 3, 8, ore("minecraft:diamond_ore")); set(1, 4, 8, ore("minecraft:diamond_ore"))
    -- coal inside the tunnel (middle column, middle row), on its own
    set(1, 1, 6, ore("minecraft:coal_ore"))
    -- gold in the floor, two deep
    set(2, -1, 10, ore("minecraft:deepslate_gold_ore")); set(2, -2, 10, ore("minecraft:deepslate_gold_ore"))
    -- a modded ore known only by its tag, in the far end's face
    set(0, 0, 13, { name = "modded:tin_vein", tags = ORE_TAGS })
    -- lava: a source in the right wall, and one inside the tunnel
    set(3, 0, 3, { name = "minecraft:lava", level = 0 })
    set(1, 2, 9, { name = "minecraft:lava", level = 0 })
    -- gravel in the tunnel with more above the ceiling, which falls in
    for y = 1, 5 do set(2, y, 7, { name = "minecraft:gravel" }) end
end

local ORES = {}                -- where ore was, for checking
local function isOreBlock(b)
    return b and (b.name:find("_ore$") or (b.tags and b.tags["c:ores"])) and true or false
end
Mine.isOreBlock = isOreBlock
function Mine.remember()
    ORES = {}
    for key, b in pairs(W) do
        if b and isOreBlock(b) then
            local x, y, z = key:match("(-?%d+),(-?%d+),(-?%d+)")
            ORES[#ORES + 1] = { x = tonumber(x), y = tonumber(y), z = tonumber(z) }
        end
    end
end

local function passable(b) return b == nil or b.name == "minecraft:lava" or b.name == WATER_NAME end
local function inspectAt(x, y, z)
    local b = get(x, y, z)
    if not b then return false, "No block to inspect" end
    local tags = {}
    if b.tags then for t in pairs(b.tags) do tags[t] = true end end
    if b.name:find("_ore$") then tags["c:ores"] = true end
    return true, { name = b.name, state = { level = b.level, waterlogged = b.waterlogged }, tags = tags }
end

-- Gravel and sand above (x,y,z) fall into it once it's empty.
local function gravity(x, y, z)
    while not get(x, y, z) do
        local above = get(x, y + 1, z)
        if not (above and FALLS[above.name]) then return end
        set(x, y, z, above); set(x, y + 1, z, nil); y = y + 1
    end
end

--------------------------------------------------------------------------
-- Water, roughly as Minecraft runs it: an open block (not the turtle's)
-- beside or under water fills: a source if two sources sit beside it on
-- something solid or a source, falling water under water, flowing water
-- beside water that isn't spent; flowing water nothing feeds drains away.
-- It takes time: water reacts to a change next to it 5 ticks on, and each
-- turtle move, turn, dig or place takes 8.  A turtle moving into flowing
-- water pushes it out; one moving into a source is waterlogged and leaves
-- the source behind when it moves on.  Torches the water reaches are
-- washed away.  Only with WATERY set.
--------------------------------------------------------------------------
local P = Mine.P
local function isWater(b) return b and b.name == WATER_NAME end
Mine.isWater = isWater
-- Water a block holds, as a level: 0 for a source (a waterlogged block is
-- one), nil for none.
local function wlevel(b)
    if not b then return nil end
    if b.waterlogged then return 0 end
    if b.name == WATER_NAME then return b.level end
end
local function waterFor(x, y, z)
    local sources, feed = 0, nil
    for _, d in ipairs(M.SIDES4) do
        local lv = wlevel(get(x + d[1], y, z + d[2]))
        if lv then
            if lv == 0 then sources = sources + 1 end
            local l = lv >= 8 and 0 or lv
            if l < 7 then feed = math.min(feed or 99, l + 1) end
        end
    end
    local below = get(x, y - 1, z)
    if sources >= 2 and below and (below.name ~= WATER_NAME or below.level == 0)
            and below.name ~= "minecraft:lava" then
        return { name = WATER_NAME, level = 0 }
    end
    if wlevel(get(x, y + 1, z)) then return { name = WATER_NAME, level = 8 } end
    if feed then return { name = WATER_NAME, level = feed } end
    return nil
end
local pending = {}             -- key -> { due tick, x, y, z }: water blocks due a tick
local clock = 0                -- ticks
local function due(a, b, c, t)
    if not wlevel(get(a, b, c)) then return end
    local key = k(a, b, c)
    local q = pending[key]
    if not q or q[1] > t then pending[key] = { t, a, b, c } end
end
-- Something changed at (x,y,z) now: the water there and next to it ticks
-- 5 ticks on.
local function flow(x, y, z)
    due(x, y, z, clock + 5)
    for _, d in ipairs(M.SIDES6) do due(x + d[1], y + d[2], z + d[3], clock + 5) end
end
Mine.flow = flow
-- The open block (not the turtle's) at (a,b,c) gets the water due it.
local function fillAt(a, b, c, t)
    local cur = get(a, b, c)
    local torch = isTorch(cur)
    if c < 1 or (a == P.x and b == P.y and c == P.z) or not (cur == nil or torch) then return end
    local new = waterFor(a, b, c)
    if not new then return end
    if torch then WASHED = (WASHED or 0) + 1 end    -- water washes a torch away
    -- INGRESS: water getting into the tunnel (BOX) where it's open, past
    -- the block just dug (which the turtle moves into, pushing it out)
    if BOX and a >= BOX[1] and a <= BOX[2] and b >= BOX[3] and b <= BOX[4]
            and k(a, b, c) ~= LAST_DUG then
        INGRESS = (INGRESS or 0) + 1
    end
    set(a, b, c, new)
    due(a, b, c, t + 5)
end
-- Let `ticks` pass (a turtle action's 8 by default).  A water block that
-- ticks drains if nothing feeds it (or changes level), and spreads into
-- the open blocks next to it, which tick 5 ticks later.
local function waterStep(ticks)
    clock = clock + (ticks or 8)
    for _ = 1, 100000 do
        local first
        for key, q in pairs(pending) do      -- the earliest; ties by place, so runs repeat
            if q[1] <= clock and (not first or q[1] < first[1] or (q[1] == first[1] and key < first[5])) then
                first = q
                q[5] = key
            end
        end
        if not first then return end
        local t, a, b, c = first[1], first[2], first[3], first[4]
        pending[k(a, b, c)] = nil
        local cur = get(a, b, c)
        if wlevel(cur) and not (a == P.x and b == P.y and c == P.z) then
            if wlevel(cur) ~= 0 then
                local new = waterFor(a, b, c)
                if (new and new.level) ~= cur.level then
                    set(a, b, c, new)
                    for _, d in ipairs(M.SIDES6) do due(a + d[1], b + d[2], c + d[3], t + 5) end
                end
            end
            if wlevel(get(a, b, c)) then
                for _, d in ipairs(M.SIDES6) do fillAt(a + d[1], b + d[2], c + d[3], t) end
            end
        end
    end
end
-- Let the water settle (at the end of a run).
function Mine.settleWater()
    for _ = 1, 400 do
        if next(pending) == nil then return end
        waterStep(5)
    end
end

--------------------------------------------------------------------------
-- The turtle
--------------------------------------------------------------------------
local function chestAt(x, y, z)
    local b = get(x, y, z)
    return b and b.inv
end
Mine.chestAt = chestAt

local function dig(x, y, z)
    if STOP_AT_DIG and (DIGS or 0) >= STOP_AT_DIG then    -- as if Ctrl+T
        STOP_AT_DIG = nil
        STOPPED_HERE = true
        error("Terminated", 0)
    end
    local b = get(x, y, z)
    if not b or passable(b) or b.inv or b.name == "minecraft:bedrock" then return false end
    set(x, y, z, b.waterlogged and { name = WATER_NAME, level = 0 } or nil)
    if isTorch(b) then TORCHES_DUG = (TORCHES_DUG or 0) + 1 end
    -- a torch hanging on this block, or standing on it, drops off (onto
    -- the ground: the turtle doesn't get it)
    for _, d in ipairs(M.SIDES6) do
        local t = get(x + d[1], y + d[2], z + d[3])
        if isTorch(t) and t.on == k(x, y, z) then
            set(x + d[1], y + d[2], z + d[3], nil)
            TORCHES_DROPPED = (TORCHES_DROPPED or 0) + 1
        end
    end
    LAST_DUG = k(x, y, z)
    if TRAVELLING then TRAVEL_DIGS = (TRAVEL_DIGS or 0) + 1 end
    DIGS = (DIGS or 0) + 1
    if b.name ~= "minecraft:glow_lichen" then M.addItem(Mine, DROP[b.name] or b.name, 1) end   -- (lichen needs shears)
    gravity(x, y, z)
    if WATERY then flow(x, y, z); waterStep() end
    return true
end

local function solid(b) return b and not passable(b) and not isTorch(b) end
-- A torch needs something under it or, in front, the block beyond to
-- hang on.  Ore drops, fuel and gems aren't blocks.
local function place(x, y, z, dir)
    local it = Mine.inv[Mine.sel]
    if not it then return false end
    if Mine.ENTITIES[k(x, y, z)] then return true end   -- as in game: right-clicks the minecart
    if it.name == "minecraft:bucket" then           -- an empty bucket takes up a source
        local b = get(x, y, z)
        if not (b and b.name == "minecraft:lava" and b.level == 0) then return false end
        set(x, y, z, nil)
        M.useSel(Mine)
        M.addItem(Mine, "minecraft:lava_bucket", 1)
        return true
    end
    if not passable(get(x, y, z)) then return false end
    local on, hangsOn                      -- what a torch hangs on or stands on; hung on a wall
    if it.name == "minecraft:torch" then
        local bx, bz = x + M.DX[P.d], z + M.DZ[P.d]
        local hangs = dir == "front" and solid(get(bx, y, bz))
        hangsOn = hangs
        if hangs then on = k(bx, y, bz)
        elseif solid(get(x, y - 1, z)) then on = k(x, y - 1, z)
        else return false end
    end
    if it.name:find("raw_") or M.FUEL_VALUE[it.name] or it.name == "minecraft:diamond"
        or it.name == "minecraft:emerald" then return false end
    if it.name == "minecraft:chest" then set(x, y, z, Mine.chest())
    elseif it.name == "minecraft:torch" and hangsOn then set(x, y, z, { name = "minecraft:wall_torch", on = on })
    else set(x, y, z, { name = it.name, on = on }) end
    M.useSel(Mine)
    PLACED = (PLACED or 0) + 1
    if WATERY then flow(x, y, z); waterStep() end
    return true
end

local function drop(x, y, z, _, n)
    local c = chestAt(x, y, z)
    local e = Mine.ENTITIES[k(x, y, z)]
    if not c and e and e.inv then c = e.inv end     -- a turtle drops into a chest minecart too
    if not c then error("dropped on the ground") end
    return M.dropInto(Mine, c, SIZE, n)
end

local function suck(x, y, z, _, n)
    local c = chestAt(x, y, z)
    local e = Mine.ENTITIES[k(x, y, z)]
    if not c and e and e.inv then c = e.inv end
    if c then return M.suckFrom(Mine, c, SIZE, n) end
    local items = Mine.GROUND[k(x, y, z)]          -- items lying there: one stack
    if not (items and items[1]) then return false end
    local it = table.remove(items, 1)
    M.addItem(Mine, it.name, it.count)
    return true
end

-- Hitting a minecart breaks it: the turtle gets the minecart, and what
-- was in it falls on the ground.
local function attack(x, y, z)
    local key = k(x, y, z)
    local e = Mine.ENTITIES[key]
    if not e then return false end
    Mine.ENTITIES[key] = nil
    M.addItem(Mine, e.item, 1)
    Mine.GROUND[key] = Mine.GROUND[key] or {}
    for _, it in pairs(e.inv or {}) do table.insert(Mine.GROUND[key], it) end
    return true
end

-- A crafting table equipped: the 3x3 at one of the four corners of the
-- inventory, every other slot empty, as CC:Tweaked has it.  The recipes
-- mine.lua uses: a log -> 4 planks; planks over planks -> 4 sticks; coal
-- over a stick -> 4 torches; 8 planks round an empty middle -> a chest.
local function isPlanksItem(n) return n:find("_planks$") ~= nil end
local function craft(limit)
    local inv = Mine.inv
    local cells
    for r0 = 0, 1 do for c0 = 0, 1 do
        if not cells then
            local ok, got = true, {}
            for s = 1, 16 do
                local r, c = math.floor((s - 1) / 4), (s - 1) % 4
                local inside = r >= r0 and r < r0 + 3 and c >= c0 and c < c0 + 3
                if inv[s] and not inside then ok = false end
                if inv[s] and inside then got[#got + 1] = { s = s, r = r, c = c, name = inv[s].name } end
            end
            if ok and #got > 0 then cells = got end
        end
    end end
    if not cells then return false, "No matching recipes" end
    local r1, c1, r2, c2 = 9, 9, -1, -1
    for _, cl in ipairs(cells) do
        r1, c1, r2, c2 = math.min(r1, cl.r), math.min(c1, cl.c), math.max(r2, cl.r), math.max(c2, cl.c)
    end
    local function name(r, c)
        for _, cl in ipairs(cells) do if cl.r == r1 + r and cl.c == c1 + c then return cl.name end end
    end
    local out, per
    if #cells == 1 and (cells[1].name:find("_log$") or cells[1].name:find("_wood$")) then
        out, per = cells[1].name:gsub("_log$", "_planks"):gsub("_wood$", "_planks"), 4
    elseif #cells == 2 and c1 == c2 and r2 == r1 + 1 then
        local top, bottom = name(0, 0), name(1, 0)
        if isPlanksItem(top) and isPlanksItem(bottom) then out, per = "minecraft:stick", 4
        elseif (top == "minecraft:coal" or top == "minecraft:charcoal") and bottom == "minecraft:stick" then
            out, per = "minecraft:torch", 4
        end
    elseif #cells == 8 and r2 - r1 == 2 and c2 - c1 == 2 and not name(1, 1) then
        local all = true
        for _, cl in ipairs(cells) do if not isPlanksItem(cl.name) then all = false end end
        if all then out, per = "minecraft:chest", 1 end
    end
    if not out then return false, "No matching recipes" end
    local steps = math.min(limit or 64, 64)
    for _, cl in ipairs(cells) do steps = math.min(steps, inv[cl.s].count) end
    for _, cl in ipairs(cells) do
        inv[cl.s].count = inv[cl.s].count - steps
        if inv[cl.s].count == 0 then inv[cl.s] = nil end
    end
    M.addItem(Mine, out, steps * per)
    CRAFTED[out] = (CRAFTED[out] or 0) + steps * per
    return true
end
Mine.TABLE = "minecraft:crafting_table"

local function moved(ox, oy, oz)
    if WATERY then
        local b = get(P.x, P.y, P.z)
        if isWater(b) and b.level ~= 0 then set(P.x, P.y, P.z, nil) end   -- pushed out
        flow(ox, oy, oz)
        waterStep()
    end
    if TRAVELLING then                  -- a trip ends back where it started
        if P.x ~= BACK[1] or P.y ~= BACK[2] or P.z ~= BACK[3] then LEFT_SPOT = true
        elseif LEFT_SPOT then TRAVELLING = false end
    end
end

-- What burns, as in game: coal and the rest, and wood (logs, planks,
-- sticks, chests, crafting tables: a furnace takes them all), which
-- mine.lua must never burn.  BURNT counts what was.
BURNS = setmetatable({}, { __index = function(_, name)
    if M.FUEL_VALUE[name] then return M.FUEL_VALUE[name] end
    if name:find("_log$") or name:find("_planks$") or name == "minecraft:chest"
        or name == "minecraft:crafting_table" then return 15 end
    if name == "minecraft:stick" then return 5 end
end })
local fuelApi = M.fuelApi
function M.fuelApi(S, values)
    local api = fuelApi(S, values)
    local refuel = api.refuel
    api.refuel = function(n)
        local it = S.inv[S.sel]
        local name, before = it and it.name, it and it.count or 0
        local ok = refuel(n)
        local now = S.inv[S.sel]
        local used = before - ((now and now.name == name) and now.count or 0)
        if ok and name and used > 0 then BURNT[name] = (BURNT[name] or 0) + used end
        return ok
    end
    return api
end

-- Upgrades on each side; equipping swaps the selected slot with one.
EQ = { right = "minecraft:diamond_pickaxe" }
SCANNER = "advancedperipherals:geo_scanner"
SCAN_TURN = 0
SCANS = 0

turtle = M.merge(
    M.movementApi(Mine, passable, {
        onMove = function(...) if ONMOVE then ONMOVE(...) end end,
        moved = moved,
        turned = function() if WATERY then waterStep() end end,
    }),
    M.lookingApi(Mine, inspectAt, function(b) return not passable(b) end),
    M.actingApi(Mine, "dig", dig),
    M.actingApi(Mine, "place", place),
    M.actingApi(Mine, "drop", drop),
    M.actingApi(Mine, "suck", suck),
    M.actingApi(Mine, "attack", attack),
    M.inventoryApi(Mine),
    -- (as in game, a freshly equipped scanner may not show up as a
    -- peripheral at once: here not until it's been asked for once)
    M.equipmentApi(Mine, function(side) if EQ[side] == SCANNER then ATTACHING = side end end),
    M.fuelApi(Mine, BURNS)
)

--------------------------------------------------------------------------
-- The Geo Scanner: every block that isn't air within the radius (the
-- turtle itself included), at offsets along the WORLD's axes.  The sim's
-- world is turned so the tunnel's +z runs east: world x = the tunnel's z,
-- world z = its x.
--------------------------------------------------------------------------
local function geoScanner()
    return {
        scanBlocks = function(r)                -- `scan` in AP's docs; this on the user's server
            SCANS = SCANS + 1
            local out = {}
            for tx = -r, r do for ty = -r, r do for tz = -r, r do
                local b = (tx == 0 and ty == 0 and tz == 0) and { name = "computercraft:turtle_normal" }
                    or get(P.x + tx, P.y + ty, P.z + tz)
                if b then
                    local tags = {}
                    if b.tags then for t in pairs(b.tags) do tags[#tags + 1] = t end end
                    if b.name:find("_ore$") then tags[#tags + 1] = "c:ores" end
                    -- as AP 0.8.2a gives them: offsets along the world's axes, as
                    -- decimals, and right/up/forward from the turtle's real facing;
                    -- the variant gives world coordinates and no r/u/f
                    if WORLD_COORDS then
                        out[#out + 1] = { x = tz + 1000, y = ty + 1000, z = tx + 1000, name = b.name, tags = tags }
                    else
                        local f, rt = (P.d + SCAN_TURN) % 4, (P.d + SCAN_TURN + 1) % 4
                        out[#out + 1] = { x = tz + 0.0, y = ty + 0.0, z = tx + 0.0, name = b.name, tags = tags,
                            state = { waterlogged = b.waterlogged, level = b.level },
                            -- SCAN_TURN: a scanner whose idea of forward is turned
                            f = tx * M.DX[f] + tz * M.DZ[f] + 0.0, u = ty + 0.0,
                            r = tx * M.DX[rt] + tz * M.DZ[rt] + 0.0 }
                    end
                end
            end end end
            return out
        end,
        cost = function() return 0 end,
    }
end

peripheral = {
    wrap = function(side)
        if side == "left" or side == "right" then
            if ATTACHING == side then ATTACHING = nil; return nil end
            if EQ[side] == Mine.TABLE then return { craft = craft } end
            return EQ[side] == SCANNER and geoScanner() or nil
        end
        local c
        if side == "front" then c = chestAt(M.front(Mine))
        elseif side == "top" then c = chestAt(M.above(Mine))
        elseif side == "bottom" then c = chestAt(M.below(Mine)) end
        if not c then return nil end
        return M.containerPeripheral(c, SIZE, side)
    end,
    getName = function(p) return p._name end,
    getType = function(side)
        if not (side == "left" or side == "right") then return nil end
        if EQ[side] == Mine.TABLE then return "workbench" end
        return EQ[side] == SCANNER and "geo_scanner" or nil
    end,
}
-- methods by name, as CC has them: through wrap, as the scanner shows up
peripheral.getMethods = function(side)
    local p = peripheral.wrap(side)
    if not p then return nil end
    local m = {}
    for name, f in pairs(p) do if type(f) == "function" then m[#m + 1] = name end end
    return m
end
-- the sides with something on them: an upgrade with a peripheral, a chest
peripheral.getNames = function()
    local out = {}
    for _, side in ipairs({ "bottom", "front", "left", "right", "top" }) do
        if peripheral.getType(side) or ((side == "front" or side == "top" or side == "bottom") and peripheral.wrap(side)) then
            out[#out + 1] = side
        end
    end
    return out
end
peripheral.call = function(side, name, ...)
    local p = peripheral.wrap(side)
    if not (p and p[name]) then error("No such method " .. name, 0) end
    return p[name](...)
end

fs = M.fsApi(Mine)
textutils = textutils or M.textutilsApi()   -- (lib/fileio, under turtlelib, reads JSON with it)
shell = M.shellApi("mine.lua")
sleep = function() end
os.startTimer = function() return 1 end
os.getComputerID = function() return 7 end
os.getComputerLabel = function() return nil end
os.pullEvent = function() error("waited for an event: the turtle should never wait here") end

-- what watchsim.lua draws: the world and the turtle, and the slices of a
-- mine to show (x and y take in the tunnels and their veins; z runs along
-- them, the view following the turtle)
SIM_WORLD = { W = { get = get }, P = P, moves = function() return Mine.moves end,
              view = { x = { -5, 7 }, y = { -5, 7 }, z = { -1, 70 } } }

-- The program's output; a trip home ("... at (x,y,z): back to home") is
-- noted, to count what's dug on it (TRAVEL_DIGS)
M.capturePrint(Mine, function(line)
    local bx, by, bz = line:match("at %((-?%d+),(-?%d+),(-?%d+)%): back to home")
    if bx then TRAVELLING, LEFT_SPOT, BACK = true, false, { tonumber(bx), tonumber(by), tonumber(bz) } end
end)

--------------------------------------------------------------------------
-- Running and checking
--------------------------------------------------------------------------
Mine.check = M.check
function Mine.logHas(pat) return M.logHas(Mine, pat) end
function Mine.contents(c) return M.contents(c, SIZE) end

-- Run mine.lua with these arguments (see mock.runner): the water settles
-- afterwards; the "Segment ..." lines are left out of the report.
function Mine.runner(proj)
    local stoppedHere
    return M.runner(Mine, proj .. "/turtle/mine.lua", {
        before = function() SPLIT, DIGS = 0, 0 end,
        after = function()
            if WATERY then Mine.settleWater() end
            stoppedHere, STOPPED_HERE = STOPPED_HERE, nil
        end,
        stats = function()
            return "moves: " .. Mine.moves .. ", turns: " .. Mine.turns .. ", digs: " .. DIGS .. ", split stacks: " .. SPLIT
        end,
        keep = function(l) return not l:find("^Segment ") end,
        stopped = function(err)
            if stoppedHere and err == "Terminated" then return "(stopped, as if by Ctrl+T)" end
        end,
    })
end

local BULKY = { cobblestone = true, cobbled_deepslate = true, andesite = true, diorite = true,
                granite = true, tuff = true, gravel = true }
local SUPPLY = { chest = true, coal = true, torch = true, crafting_table = true, oak_log = true,
                 oak_planks = true, stick = true }

function Mine.startAt() P.x, P.y, P.z, P.d = 0, 0, 0, 0 end
function Mine.atStart() return P.x == 0 and P.y == 0 and P.z == 0 and P.d == 0 end

-- Supplies for the start chest: so many chests and coal, and torches.
function Mine.stock(chests, coal, torches)
    local t = {}
    if torches then t[#t + 1] = { name = "minecraft:torch", count = torches } end
    for _ = 1, math.floor(chests / 64) do t[#t + 1] = { name = "minecraft:chest", count = 64 } end
    if chests % 64 > 0 then t[#t + 1] = { name = "minecraft:chest", count = chests % 64 } end
    while coal > 0 do t[#t + 1] = { name = "minecraft:coal", count = math.min(64, coal) }; coal = coal - 64 end
    return t
end

function Mine.jobState() return (Mine.files["mine.job"] or ""):match("(%a+)$") end

-- How many blocks are left in the tunnel x0..x1, y0..y1, z1..z2.
function Mine.leftIn(x0, x1, y0, y1, z1, z2)
    local n = 0
    for x = x0, x1 do for y = y0, y1 do for z = z1, z2 do
        if get(x, y, z) then n = n + 1 end
    end end end
    return n
end

-- Holes in the floor y = fy under x0..x1, z1..z2: blocks a player can't
-- stand on (air, fluid).
local function floorHoles(x0, x1, fy, z1, z2)
    local holes = {}
    for x = x0, x1 do for z = z1, z2 do
        local b = get(x, fy, z)
        if not b or passable(b) then holes[#holes + 1] = k(x, fy, z) end
    end end
    return holes
end
function Mine.checkFloor(x0, x1, fy, z1, z2)
    local holes = floorHoles(x0, x1, fy, z1, z2)
    M.check("floor solid all along", #holes == 0, #holes .. " holes" .. (#holes > 0 and (": " .. table.concat(holes, " ", 1, math.min(#holes, 6))) or ""))
end

-- Block light on the tunnel's floor-level blocks x0..x1, y = fy + 1,
-- z1..z2: flood from every torch through open space (14 at the torch, one
-- less each block).  Mobs spawn at 0; the darkest is reported.
function Mine.checkLight(x0, x1, fy, z1, z2)
    local light, queue, head = {}, {}, 1
    for key, b in pairs(W) do
        if isTorch(b) then
            light[key] = 14
            local x, y, z = key:match("(-?%d+),(-?%d+),(-?%d+)")
            queue[#queue + 1] = { tonumber(x), tonumber(y), tonumber(z) }
        end
    end
    while queue[head] do
        local c = queue[head]; head = head + 1
        local l = light[k(c[1], c[2], c[3])]
        if l > 1 then
            for _, d in ipairs(M.SIDES6) do
                local x, y, z = c[1] + d[1], c[2] + d[2], c[3] + d[3]
                local key = k(x, y, z)
                if not get(x, y, z) and (light[key] or 0) < l - 1 then
                    light[key] = l - 1
                    queue[#queue + 1] = { x, y, z }
                end
            end
        end
    end
    local darkest, where = 99, ""
    for x = x0, x1 do for z = z1, z2 do
        local l = light[k(x, fy + 1, z)] or 0
        if l < darkest then darkest, where = l, k(x, fy + 1, z) end
    end end
    M.check("no floor block dark enough for mobs", darkest >= 1, "darkest " .. darkest .. " at " .. where)
    return darkest
end

-- Ore within 4 of the first tunnel mined, ore beyond left.
function Mine.checkOres()
    local mined, kept, wrong = 0, 0, {}
    for _, o in ipairs(ORES) do
        local reach = math.max(-o.x, o.x - 2, 0) <= 4 and math.max(-o.y, o.y - 2, 0) <= 4
        local gone = not isOreBlock(get(o.x, o.y, o.z))
        if reach and gone then mined = mined + 1
        elseif not reach and not gone then kept = kept + 1
        else wrong[#wrong + 1] = k(o.x, o.y, o.z) .. (gone and " mined" or " left") end
    end
    M.check("ore in reach mined, beyond reach left", #wrong == 0,
        mined .. " mined, " .. kept .. " left beyond reach" .. (#wrong > 0 and ("; wrong: " .. table.concat(wrong, " ")) or ""))
end

function Mine.checkLava(L)
    local hot = 0
    for x = -6, 8 do for y = -6, 8 do for z = 1, L + 5 do
        local b = get(x, y, z)
        if b and b.name == "minecraft:lava" then
            for _, d in ipairs(M.SIDES6) do
                if not get(x + d[1], y + d[2], z + d[3]) then hot = hot + 1 end
            end
        end
    end end end
    M.check("no lava touching open space", hot == 0, hot .. " open faces")
end

-- The start chests: valuables on top (and supplies), bulk below.
function Mine.checkStart()
    local top, tn = Mine.contents(chestAt(0, 1, 0))
    local bottom, bn = Mine.contents(chestAt(0, -1, 0))
    M.realPrint("   start top:    " .. top)
    M.realPrint("   start bottom: " .. bottom)
    local misplaced = {}
    for name in pairs(tn) do if BULKY[name:gsub("^%a+:", "")] then misplaced[#misplaced + 1] = name .. " on top" end end
    for name in pairs(bn) do if not BULKY[name:gsub("^%a+:", "")] then misplaced[#misplaced + 1] = name .. " below" end end
    M.check("valuables on top, bulk below at the start", #misplaced == 0, table.concat(misplaced, ", "))
    return tn
end

-- Homes every `sp` blocks, for a tunnel up and right: a wall chest at
-- x=-1 and a floor chest at y=-1.  Supplies only in the last home, apart
-- from a small stock of coal (1 to FUEL_STOCK) in each earlier one; no
-- valuables left in any, only bulk in the floor chests.
Mine.FUEL_STOCK = 8
function Mine.checkHomes(sp, count)
    local bad = {}
    for h = 1, count do
        local z = h * sp
        local wall, floor = chestAt(-1, 0, z), chestAt(0, -1, z)
        if not (wall and floor) then bad[#bad + 1] = "home " .. h .. " missing a chest"
        else
            local _, wn = Mine.contents(wall)
            for name, n in pairs(wn) do
                local short = name:gsub("^%a+:", "")
                if h < count and SUPPLY[short] and not (short == "coal" and n <= Mine.FUEL_STOCK) then
                    bad[#bad + 1] = short .. " left in home " .. h
                end
                if not SUPPLY[short] then bad[#bad + 1] = short .. " not brought back from home " .. h end
            end
            if h < count and not wn["minecraft:coal"] then bad[#bad + 1] = "no fuel stock in home " .. h end
            local _, fn = Mine.contents(floor)
            for name in pairs(fn) do
                if not BULKY[name:gsub("^%a+:", "")] then bad[#bad + 1] = name .. " in home " .. h .. "'s bulk chest" end
            end
        end
    end
    if chestAt(-1, 0, (count + 1) * sp) then bad[#bad + 1] = "a home past the last one" end
    M.check(count .. " homes, supplies only in the last, valuables brought back", #bad == 0, table.concat(bad, "; "))
    if count > 0 then M.realPrint("   last home: " .. (Mine.contents(chestAt(-1, 0, count * sp)))) end
end

-- Water in the tunnel x0..x1, y0..y1, z1..z2, and faces of water anywhere
-- in the area round it (x0-3..x1+3 and so on) open to air.
function Mine.wetFaces(x0, x1, y0, y1, z1, z2)
    local wetIn, wetOpen = 0, 0
    for x = x0 - 3, x1 + 3 do for y = y0 - 3, y1 + 4 do for z = 1, z2 + 1 do
        local b = get(x, y, z)
        if isWater(b) then
            if x >= x0 and x <= x1 and y >= y0 and y <= y1 and z >= z1 then wetIn = wetIn + 1 end
            for _, d in ipairs(M.SIDES6) do
                if not get(x + d[1], y + d[2], z + d[3]) then wetOpen = wetOpen + 1 end
            end
        end
    end end end
    return wetIn, wetOpen
end

-- Water blocks in the tunnel x0..x1, y0..y1, z1..z2.
function Mine.wetIn(x0, x1, y0, y1, z1, z2)
    local n = 0
    for x = x0, x1 do for y = y0, y1 do for z = z1, z2 do
        if isWater(get(x, y, z)) then n = n + 1 end
    end end end
    return n
end

-- Torches standing at floor level, x0..x1, z1..z2.
function Mine.torchesIn(x0, x1, y, z1, z2)
    local n = 0
    for x = x0, x1 do for z = z1, z2 do
        if isTorch(get(x, y, z)) then n = n + 1 end
    end end
    return n
end

return Mine
