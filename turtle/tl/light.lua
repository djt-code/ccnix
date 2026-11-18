-- light.lua -- block light over the map, and the cells where a mob could spawn in the dark
--
-- Loaded by turtlelib the first time T.light or T.darkCells is used.  Cells are the turtle's own (the frame it counts in).
--
-- A flood fill of block light over the map (tl.world), as the game spreads it: a light gives its level in its own cell,
-- and each step to a side, up or down loses 1, so a torch (14) lights the cells beside it to 13 and nothing 14 steps
-- away.  What light goes through comes from the lint's kinds (T.blockKind): what a player passes through, railings,
-- lanterns, stairs and slabs; a solid block stops it unless the table of exceptions says it is clear (glass, leaves,
-- ice, a chest, a plant).  A slab or a stair lets light through sideways but not through its full face (a bottom one's
-- underside, a top one's top); one whose half the map lacks is taken as a bottom one.  Lights up to 14 cells outside
-- the box count (the box is grown by 14 to look for them), and so does light that goes round a wall outside the box.
-- A cell the map never saw stops light.  Sky light isn't modelled: the dark cells are those of a roofed place, or of
-- any place at night.
--
-- A monster spawns with its feet in a cell with room (that cell and the one over it: nothing it collides with, so air,
-- a torch or a sign, but not a rail, a carpet, a pressure plate, a button, a lever or redstone, which stop spawning)
-- over a floor with a full, sturdy top (a solid block, a top slab, an upside-down stair; not a bottom slab, glass,
-- leaves, ice, a block that isn't a full one such as a chest or farmland, or one giving light 14 or more such as
-- glowstone), when the block light in its feet cell is at or under the dimension's limit (Java 1.21.1's code, checked
-- 2026-11-17):
--   overworld, end  0 (the dimension's monster_spawn_block_light_limit)
--   nether          7 for skeletons, wither skeletons and endermen (monster_spawn_light_level); 11 for zombified
--                   piglins, piglins, hoglins and blazes (the walk-target check every pathfinding monster passes,
--                   MC-156004); ghasts and magma cubes whatever the light: only the floor or the room stops them
-- The turtle can't tell which dimension it is in: opts.dimension says, else the setting T.cfg.dimension, else it is
-- the overworld.  Only two cells of room are asked for (an enderman wants three, a ghast more, a spider a wider
-- space), and the game's chances (sky light at night, the distance from a player) aren't modelled.  Mods in a pack can
-- change spawning, and a block the tables don't know is taken as a solid one: check in game, comparing the dark cells
-- with where mobs appeared.

local T = require("turtlelib")
local text = require("text")
local tables = require("tables")

local REACH = 14                  -- the farthest a light outside the box reaches into it (15 falls to 1 in 14 steps)
local MAX_CELLS = 65536           -- the biggest box looked at
local LIMIT = 50                  -- cells listed at most (opts.limit); the rest are counted
local MAX_LIGHTS = 20000          -- lights read at most (the most map.find holds)
local BREATHE_EVERY = 64          -- cells between looks at the clock
local FLOOR_GLOW = 14             -- a block giving this much light or more is no floor for a spawn

-- The light the blocks give (Java 1.21.1).  A number is the level; a table is a level that goes by a state:
-- { prop, on = the level while it is true (times: the state counting how many, plus: added), value = true: the state
-- is the level, levels = the level by the state's value; default = the game's default state, taken when the map
-- lacks it }
local LIT = function(level, default) return { "lit", on = level, default = default or false } end
local EMIT = {
    ["minecraft:torch"] = 14, ["minecraft:wall_torch"] = 14, ["minecraft:soul_torch"] = 10, ["minecraft:soul_wall_torch"] = 10,
    ["minecraft:redstone_torch"] = LIT(7, true), ["minecraft:redstone_wall_torch"] = LIT(7, true),
    ["minecraft:lantern"] = 15, ["minecraft:soul_lantern"] = 10, ["minecraft:end_rod"] = 14,
    ["minecraft:glowstone"] = 15, ["minecraft:shroomlight"] = 15, ["minecraft:sea_lantern"] = 15,
    ["minecraft:jack_o_lantern"] = 15, ["minecraft:ochre_froglight"] = 15, ["minecraft:verdant_froglight"] = 15,
    ["minecraft:pearlescent_froglight"] = 15, ["minecraft:beacon"] = 15, ["minecraft:conduit"] = 15,
    ["minecraft:lava"] = 15, ["minecraft:fire"] = 15, ["minecraft:soul_fire"] = 10,
    ["minecraft:campfire"] = LIT(15, true), ["minecraft:soul_campfire"] = LIT(10, true),
    ["minecraft:magma_block"] = 3, ["minecraft:crying_obsidian"] = 10, ["minecraft:glow_lichen"] = 7,
    ["minecraft:respawn_anchor"] = { "charges", levels = { [0] = 0, 3, 7, 11, 15 }, default = 0 },
    ["minecraft:redstone_lamp"] = LIT(15), ["minecraft:redstone_ore"] = LIT(9), ["minecraft:deepslate_redstone_ore"] = LIT(9),
    ["minecraft:furnace"] = LIT(13), ["minecraft:smoker"] = LIT(13), ["minecraft:blast_furnace"] = LIT(13),
    ["minecraft:nether_portal"] = 11, ["minecraft:end_portal"] = 15, ["minecraft:end_gateway"] = 15,
    ["minecraft:enchanting_table"] = 7, ["minecraft:ender_chest"] = 7, ["minecraft:sculk_catalyst"] = 6,
    ["minecraft:amethyst_cluster"] = 5, ["minecraft:large_amethyst_bud"] = 4, ["minecraft:medium_amethyst_bud"] = 2,
    ["minecraft:small_amethyst_bud"] = 1, ["minecraft:brewing_stand"] = 1, ["minecraft:brown_mushroom"] = 1,
    ["minecraft:dragon_egg"] = 1, ["minecraft:end_portal_frame"] = 1, ["minecraft:sculk_sensor"] = 1,
    ["minecraft:calibrated_sculk_sensor"] = 1,
    ["minecraft:light"] = { "level", value = true, default = 15 },
    ["minecraft:sea_pickle"] = { "waterlogged", on = 3, times = "pickles", plus = 3, default = true },
    ["minecraft:cave_vines"] = { "berries", on = 14, default = false },
    ["minecraft:cave_vines_plant"] = { "berries", on = 14, default = false },
    ["minecraft:candle"] = { "lit", on = 3, times = "candles", default = false },
    ["minecraft:candle_cake"] = LIT(3),
}
for _, colour in ipairs({ "white", "orange", "magenta", "light_blue", "yellow", "lime", "pink", "gray", "light_gray",
                          "cyan", "purple", "blue", "brown", "green", "red", "black" }) do
    EMIT["minecraft:" .. colour .. "_candle"] = EMIT["minecraft:candle"]
    EMIT["minecraft:" .. colour .. "_candle_cake"] = EMIT["minecraft:candle_cake"]
end
for age, level in pairs({ copper = 15, exposed_copper = 12, weathered_copper = 8, oxidized_copper = 4 }) do
    EMIT["minecraft:" .. age .. "_bulb"] = LIT(level)
    EMIT["minecraft:waxed_" .. age .. "_bulb"] = LIT(level)
end
local LIGHT_NAMES = {}
for name in pairs(EMIT) do LIGHT_NAMES[#LIGHT_NAMES + 1] = name end
table.sort(LIGHT_NAMES)

-- Light and spawning by the lint's kind (T.blockKind).  opaque: light stops; room: a mob may be in it; floor: a mob
-- spawns on it; shaped: a slab or stair, by this state ("half" or "type")
local BY_KIND = {
    open = { room = true }, walltorch = { room = true }, ladder = {}, water = {}, hot = {}, gate = {}, railing = {},
    lantern = {}, stairs = { shaped = "half" }, slab = { shaped = "type" }, solid = { opaque = true, floor = true },
}
-- What the kinds get wrong for light or spawning, the first that matches winning: the facts it changes
local EXCEPT = {
    { { "tinted_glass" }, { floor = false } },                                         -- stops light; glass is no floor
    { { "*glass", "*leaves", "ice", "frosted_ice", "barrier" }, { opaque = false, floor = false } },
    { { "bedrock" }, { floor = false } },
    { { "magma_block" }, { floor = "fireproof" } },                                     -- only fire-proof mobs spawn on it
    { { "slime_block" }, { opaque = false } },
    { { "honey_block", "*chest", "*_bed", "enchanting_table", "*anvil", "hopper", "cauldron", "*_cauldron",
        "brewing_stand", "farmland", "dirt_path", "*_head", "*_skull", "flower_pot", "potted_*", "end_rod",
        "lightning_rod", "chain", "cactus", "daylight_detector", "stonecutter", "lectern", "bell", "grindstone",
        "conduit", "beacon", "*candle", "*candle_cake", "cake", "sea_pickle", "*amethyst_bud", "amethyst_cluster",
        "pointed_dripstone", "turtle_egg", "composter", "scaffolding", "cocoa", "azalea", "flowering_azalea",
        "lily_pad", "nether_portal", "end_portal", "end_gateway" }, { opaque = false, floor = false } },
    { { "dandelion", "poppy", "blue_orchid", "allium", "azure_bluet", "*_tulip", "oxeye_daisy", "cornflower",
        "lily_of_the_valley", "wither_rose", "torchflower", "sunflower", "lilac", "rose_bush", "peony", "pink_petals",
        "*_sapling", "*_mushroom", "*_fungus", "crimson_roots", "warped_roots", "hanging_roots", "nether_sprouts", "wheat", "carrots", "potatoes",
        "beetroots", "sweet_berry_bush", "nether_wart", "sugar_cane", "*_coral", "*_coral_fan", "*_coral_wall_fan",
        "seagrass", "tall_seagrass", "kelp", "kelp_plant", "*_vines", "*_vines_plant", "glow_lichen", "spore_blossom",
        "sculk_vein", "melon_stem", "pumpkin_stem", "attached_melon_stem", "attached_pumpkin_stem",
        "torchflower_crop", "pitcher_crop", "pitcher_plant", "small_dripleaf", "big_dripleaf_stem" },
      { opaque = false, floor = false, room = true } },
    -- (in the open, but a mob doesn't spawn in their cell: a rail and redstone stop it, the rest it collides with)
    { { "*rail", "*_pressure_plate", "*_button", "lever", "redstone_wire", "redstone_torch", "redstone_wall_torch",
        "tripwire", "tripwire_hook", "*_carpet", "*_door", "*_trapdoor", "repeater", "comparator" }, { room = false } },
}
for _, row in ipairs(EXCEPT) do row.test = T.nameTest(row[1]) end

-- A slab or a stair by its half: which full face it has (down: the underside, up: the top) and whether it is a
-- floor; a double slab is a full block.  The map lacking the state, a bottom one (unsure).
local SHAPED = {
    half = { bottom = { down = true }, top = { up = true, floor = true } },
    type = { bottom = { down = true }, top = { up = true, floor = true }, double = { opaque = true, floor = true } },
}
local UNSURE = { down = true, unsure = true }
local UNSEEN = { opaque = true, unseen = true }

-- The six steps light takes
local SIX = { { 1, 0, 0 }, { -1, 0, 0 }, { 0, 0, 1 }, { 0, 0, -1 }, { 0, 1, 0 }, { 0, -1, 0 } }

-- What spawns where, by dimension: the light limit (cells at or under it are dark), the groups of mobs by the light
-- they need, and those that spawn whatever the light
local DIMENSIONS = {
    overworld = { max = 0, groups = { { max = 0, mobs = "monsters" } } },
    ["end"] = { max = 0, groups = { { max = 0, mobs = "endermen" } } },
    nether = { max = 11, groups = { { max = 7, mobs = "skeletons, wither skeletons, endermen" },
                                    { max = 11, mobs = "zombified piglins, piglins, hoglins, blazes" } },
               anyLight = "ghasts, magma cubes", fireproof = true },
}
local DIMENSION_NAMES = { overworld = "overworld", nether = "nether", the_nether = "nether", ["end"] = "end",
                          the_end = "end" }

local S = { lastYield = 0 }

-- Give the rest of the computer a turn when this has run for a while.
local function breathe()
    local t = os.clock()
    if t - S.lastYield > 0.4 then
        S.lastYield = t
        sleep(0)
    end
end

local function whole(n) return type(n) == "number" and n == math.floor(n) end
local function key(x, y, z) return x .. "," .. y .. "," .. z end
local function fullName(name) return text.contains(name, ":") and name or "minecraft:" .. name end

-- A dimension's name as DIMENSIONS has it ("minecraft:the_nether" is the nether), or nil.
local function dimensionOf(name)
    local s = tostring(name)
    local _, after = text.cut(s, ":")
    return DIMENSION_NAMES[after or s]
end

-- The light a block gives: its level, and true if it went by a state the map lacks (the game's default taken).
local function emission(name, state)
    local e = EMIT[name]
    if type(e) ~= "table" then return e or 0, false end
    local v, guessed = state and state[e[1]], false
    if v == nil then v, guessed = e.default, true end
    local level = 0
    if e.levels then level = e.levels[v] or 0
    elseif e.value then level = tonumber(v) or 0
    elseif v == true then level = (e.plus or 0) + e.on * (e.times and tonumber(state and state[e.times]) or 1) end
    return math.max(0, math.min(15, level)), guessed
end

-- What a block is to light and spawning, by name (worked out once a name): a table of the facts above.
local baseCache = {}
local function baseOf(name)
    local c = baseCache[name]
    if c then return c end
    c = {}
    for k, v in pairs(BY_KIND[(T.blockKind(name))] or BY_KIND.solid) do c[k] = v end
    for _, row in ipairs(EXCEPT) do
        if row.test(name) then
            for k, v in pairs(row[2]) do c[k] = v end
            break
        end
    end
    baseCache[name] = c
    return c
end

-- ...and with its state: a slab or a stair by its half.
local function classOf(name, state)
    local c = baseOf(name)
    if not c.shaped then return c end
    local v = state and state[c.shaped]
    return SHAPED[c.shaped][v] or UNSURE
end

-- A box as x1, y1, z1, x2, y2, z2 (the low corner first), or nil and why.
local function boxOf(box)
    local v = box
    if type(box) == "table" and box.x1 ~= nil then v = { box.x1, box.y1, box.z1, box.x2, box.y2, box.z2 } end
    if type(v) ~= "table" then return nil, "a box is { x1, y1, z1, x2, y2, z2 }" end
    for i = 1, 6 do
        if not whole(v[i]) then return nil, "a box is { x1, y1, z1, x2, y2, z2 }, whole numbers" end
    end
    return math.min(v[1], v[4]), math.min(v[2], v[5]), math.min(v[3], v[6]),
           math.max(v[1], v[4]), math.max(v[2], v[5]), math.max(v[3], v[6])
end

-- The light over a box: { x1..z2 (the box), at(x, y, z) (a cell's class), level(x, y, z), glow(x, y, z), info };
-- nil and why.
local function flood(box, opts)
    local x1, y1, z1, x2, y2, z2 = boxOf(box)
    if not x1 then return nil, y1 end
    local cells = (x2 - x1 + 1) * (y2 - y1 + 1) * (z2 - z1 + 1)
    if cells > MAX_CELLS then return nil, "the box is " .. cells .. " cells; the light model reads " .. MAX_CELLS .. " at most" end
    -- the box grown by the reach of a light: where the lights that reach it are, and the ways their light goes
    local gx1, gy1, gz1, gx2, gy2, gz2 = x1 - REACH, y1 - REACH, z1 - REACH, x2 + REACH, y2 + REACH, z2 + REACH
    local NY, NZ = gy2 - gy1 + 1, gz2 - gz1 + 1
    local found, cut = T.map.find(LIGHT_NAMES, { gx1, gy1, gz1, gx2, gy2, gz2 }, MAX_LIGHTS)
    if not found then return nil, cut end
    local with = {}
    for _, w in ipairs(opts.with or {}) do
        local x, y, z = w.x or w[1], w.y or w[2], w.z or w[3]
        local name = w.name or w[4]
        if not (whole(x) and whole(y) and whole(z) and type(name) == "string") then
            return nil, "opts.with is a list of { x, y, z, name, state }"
        end
        with[key(x, y, z)] = { name = fullName(name), state = w.state or w[5] }
        found[#found + 1] = { x = x, y = y, z = z }
    end
    local anyWith = next(with) ~= nil
    local info = { cells = cells, sources = 0, guessed = 0, cut = cut or nil }
    local class, glow, L = {}, {}, {}
    local function inside(x, y, z)
        return x >= gx1 and x <= gx2 and y >= gy1 and y <= gy2 and z >= gz1 and z <= gz2
    end
    local function id(x, y, z) return ((x - gx1) * NY + (y - gy1)) * NZ + (z - gz1) end
    -- a cell's class, read once (and the light it gives)
    local function at(x, y, z)
        local i = id(x, y, z)
        local c = class[i]
        if c then return c end
        local w = anyWith and with[key(x, y, z)]
        local name, state
        if w then name, state = w.name, w.state else name, state = T.map.get(x, y, z) end
        if type(name) ~= "string" then
            c = UNSEEN
        else
            if type(state) ~= "table" then state = nil end
            c = classOf(name, state)
            if EMIT[name] then
                local level, guessed = emission(name, state)
                glow[i] = level
                if guessed then info.guessed = info.guessed + 1 end
            end
        end
        class[i] = c
        return c
    end
    local buckets = {}
    for l = 1, 15 do buckets[l] = {} end
    local function light(i, l)
        if l > (L[i] or 0) then
            L[i] = l
            local b = buckets[l]
            b[#b + 1] = i
        end
    end
    for _, f in ipairs(found) do
        if inside(f.x, f.y, f.z) then
            at(f.x, f.y, f.z)
            local i = id(f.x, f.y, f.z)
            if (glow[i] or 0) > 0 and L[i] ~= glow[i] then
                info.sources = info.sources + 1
                light(i, glow[i])
            end
        end
    end
    -- brightest first, so each cell spreads once, at its own level
    local steps = 0
    for l = 15, 2, -1 do
        local b = buckets[l]
        for n = 1, #b do
            local i = b[n]
            if L[i] == l then
                local z = i % NZ
                local rest = math.floor((i - z) / NZ)
                local y = rest % NY
                local x = math.floor((rest - y) / NY) + gx1
                y, z = y + gy1, z + gz1
                local c = at(x, y, z)
                for _, d in ipairs(SIX) do
                    local nx, ny, nz = x + d[1], y + d[2], z + d[3]
                    if inside(nx, ny, nz) and (L[id(nx, ny, nz)] or 0) < l - 1 then
                        local nc = at(nx, ny, nz)
                        if not nc.opaque and not (d[2] == 1 and (c.up or nc.down)) and not (d[2] == -1 and (c.down or nc.up)) then
                            light(id(nx, ny, nz), l - 1)
                        end
                    end
                end
                steps = steps + 1
                if steps % BREATHE_EVERY == 0 then breathe() end
            end
        end
    end
    local function inBox(x, y, z)
        return whole(x) and whole(y) and whole(z) and x >= x1 and x <= x2 and y >= y1 and y <= y2 and z >= z1 and z <= z2
    end
    return {
        x1 = x1, y1 = y1, z1 = z1, x2 = x2, y2 = y2, z2 = z2, info = info, at = at,
        level = function(x, y, z)
            if not inBox(x, y, z) then return nil end
            return L[id(x, y, z)] or 0
        end,
        glow = function(x, y, z) return glow[id(x, y, z)] or 0 end,
    }
end

-- The block light in a box from the map: a function level(x, y, z) giving a cell's light (0 to 15; nil for a cell
-- outside the box), and info; nil and why.
--
-- `box` is { x1, y1, z1, x2, y2, z2 } (or the fields), 65536 cells at most.  Lights up to 14 cells outside it count;
-- what light passes and what stops it is in the overview (a cell the map never saw stops it).  opts.with = a list of
-- { x, y, z, name, state } read in place of the map's cells: what a torch there would do ({ 3, 1, 4, "torch" }), or a
-- light taken away ({ 3, 1, 4, "air" }).  Info is { cells, sources (the lights that reached the grown box), guessed
-- (lights whose level goes by a state the map lacks, such as a redstone lamp's lit: the game's default taken), cut
-- (more than 20000 lights: some left out) }.  Block light only, as the game spreads it in Java 1.21.1: check in game.
function T.light(box, opts)
    local f, why = flood(box, opts or {})
    if not f then return nil, why end
    return f.level, f.info
end

-- The cell a mob could spawn in and why not, by its feet cell: "ok"; "unsure" (a floor of a slab or stair whose half
-- the map lacks); or nil.
local function spawnable(f, x, y, z, fireproof)
    if not (f.at(x, y, z).room and f.at(x, y + 1, z).room) then return nil end
    local floor = f.at(x, y - 1, z)
    if floor.unsure then return "unsure" end
    if not (floor.floor == true or (floor.floor == "fireproof" and fireproof)) then return nil end
    if f.glow(x, y - 1, z) >= FLOOR_GLOW then return nil end
    return "ok"
end

-- Where a mob could spawn in a box: a list of { x, y, z, light } (the feet cell) at or under the dimension's limit,
-- darkest first, opts.limit at most (50; info.more the rest), and info (info.unsure: cells to inspect); nil and why.
--
-- A cell is spawnable with room for a mob (it and the cell over it: air, a torch, a sign; not a rail, carpet, button,
-- pressure plate or redstone) over a full, sturdy floor (a solid block, a top slab, an upside-down stair; not a bottom
-- slab, glass, leaves, ice, glowstone or a block that isn't a full one).  The limit (see the overview): the overworld's
-- and the end's 0; the nether's 11, in two groups, light 7 or less (skeletons, wither skeletons, endermen) and 11 or
-- less (zombified piglins, piglins, hoglins, blazes), and the spawnable cells lit over it listed apart in
-- info.anyLight, since ghasts and magma cubes spawn whatever the light (only a slab or glass floor, or no room, stops
-- them).  opts: dimension ("overworld", "nether", "end"; else the setting T.cfg.dimension, else the overworld: the
-- turtle can't tell), max (the limit, overriding the dimension's), limit (cells listed, default 50), with (as T.light).
-- Info is { dimension, max, spawnable (cells), dark (cells at or under the limit), more (past the limit), groups (a
-- list of { max, mobs, count }), anyLight and anyLightCount (the nether), unsure (a list of the cells, { x, y, z },
-- over a slab or stair whose half the map lacks, taken as a bottom one: inspect them, since a top one is a floor),
-- unseen (cells of the box the map never saw), sources, guessed, cut (as T.light), summary (a line, which says "listed
-- the darkest N of M" when the list is cut) }.  Mods can change spawning: check in game.
function T.darkCells(box, opts)
    opts = opts or {}
    local asked = opts.dimension or T.cfg.dimension or "overworld"
    local dimName = dimensionOf(asked)
    if not dimName then return nil, "no such dimension: " .. tostring(asked) .. " (overworld, nether or end)" end
    local dim = DIMENSIONS[dimName]
    local max, groups = dim.max, dim.groups
    if opts.max ~= nil then
        if not whole(opts.max) then return nil, "opts.max is a light level, 0 to 15" end
        max, groups = opts.max, { { max = opts.max, mobs = "monsters" } }
    end
    local f, why = flood(box, opts)
    if not f then return nil, why end
    local limit = opts.limit or LIMIT
    local info = { dimension = dimName, max = max, spawnable = 0, dark = 0, more = 0, groups = {}, unsure = {}, unseen = 0,
                   sources = f.info.sources, guessed = f.info.guessed, cut = f.info.cut }
    local dark, lit = {}, {}
    for y = f.y1, f.y2 do
        for z = f.z1, f.z2 do
            for x = f.x1, f.x2 do
                if f.at(x, y, z).unseen then info.unseen = info.unseen + 1 end
                local can = spawnable(f, x, y, z, dim.fireproof)
                if can == "unsure" then
                    info.unsure[#info.unsure + 1] = { x = x, y = y, z = z }
                elseif can then
                    info.spawnable = info.spawnable + 1
                    local cell = { x = x, y = y, z = z, light = f.level(x, y, z) }
                    if cell.light <= max then dark[#dark + 1] = cell else lit[#lit + 1] = cell end
                end
            end
            breathe()
        end
    end
    local function darkest(a, b)
        if a.light ~= b.light then return a.light < b.light end
        if a.y ~= b.y then return a.y < b.y end
        if a.x ~= b.x then return a.x < b.x end
        return a.z < b.z
    end
    table.sort(dark, darkest)
    info.dark = #dark
    for _, g in ipairs(groups) do
        local n = 0
        for _, c in ipairs(dark) do if c.light <= g.max then n = n + 1 end end
        info.groups[#info.groups + 1] = { max = g.max, mobs = g.mobs, count = n }
    end
    local out = {}
    for i, c in ipairs(dark) do
        if i <= limit then out[i] = c else info.more = info.more + 1 end
    end
    if dim.anyLight then
        table.sort(lit, darkest)
        info.anyLightCount, info.anyLight = #lit, {}
        for i = 1, math.min(#lit, limit) do info.anyLight[i] = lit[i] end
    end
    -- the line
    local parts = {}
    if info.spawnable == 0 then
        parts[1] = "no cell in the box where a mob could spawn (no floor with room over it)"
    elseif #dark == 0 then
        parts[1] = "no dark cells: all " .. info.spawnable .. " spawnable cells have block light over " .. max
    else
        local words = {}
        for _, g in ipairs(info.groups) do
            words[#words + 1] = g.count .. " at light " .. g.max .. " or less (" .. g.mobs .. ")"
        end
        parts[1] = dimName .. ": of " .. info.spawnable .. " spawnable cells, " .. table.concat(words, ", ")
            .. "; the darkest " .. key(dark[1].x, dark[1].y, dark[1].z) .. " at " .. dark[1].light
    end
    if info.more > 0 then
        parts[#parts + 1] = "listed the darkest " .. limit .. " of " .. #dark .. " (opts.limit; info.more " .. info.more .. ")"
    end
    if dim.anyLight and #lit > 0 then
        parts[#parts + 1] = #lit .. " more take " .. dim.anyLight .. " whatever the light (a slab or glass floor, or no room, stops them)"
    end
    if #info.unsure > 0 then
        parts[#parts + 1] = #info.unsure .. " over a slab or stair whose half the map lacks (info.unsure: T.inspectAll them; a top one is a floor)"
    end
    if info.guessed > 0 then parts[#parts + 1] = info.guessed .. " lights at the game's default state (the map lacks theirs)" end
    if info.unseen > 0 then parts[#parts + 1] = info.unseen .. " cells of the box the map never saw" end
    if info.cut then parts[#parts + 1] = "over " .. MAX_LIGHTS .. " lights: some left out" end
    info.summary = table.concat(parts, "; ")
    return out, info
end

-- (ADR-0015 D8.1) The light planLights lights cells to by default: a level over the nether's limit (11), and in the
-- overworld and the end what a player calls lit (8: crops grow, and the spawning limit, 0, is far under it)
local PLAN_MIN = { overworld = 8, ["end"] = 8, nether = 12 }

-- The fewest lights, of the places given, that bring every cell to opts.min (8; 12 in the nether): a list of
-- { x, y, z, name } to place, nearest first, and info; nil and why.
--
-- `cells` are the cells to light ({ x, y, z }: a walkway's feet cells, T.darkCells' list); `candidates` the cells a
-- light may go in ({ x, y, z } or { x, y, z, name }: in the wall beside a path, the floor under it).  It reads the map
-- and T.light's model (what passes light and what stops it, the lights already there): a cell already at opts.min is
-- done; then, again and again, the candidate that brings the most cells still dark to opts.min is taken (a greedy
-- cover: few lights, not always the fewest), until all are lit or no candidate helps.  The light is opts.item
-- (default minecraft:lantern, 15; a torch 14, glowstone 15, a soul lantern 10), or a candidate's own name.  opts:
-- min, item, dimension (the default min: T.cfg.dimension, else the overworld).  Info is { lit (already at min), covered
-- (by the lights chosen), left (a list of the cells no candidate reaches), lights, summary }.  Nothing is placed:
-- T.placeAt them (a lantern's opts.hanging, a torch on a wall) and T.darkCells to check.
function T.planLights(cells, candidates, opts)
    opts = opts or {}
    if type(cells) ~= "table" or #cells == 0 then return nil, "planLights wants a list of cells { x, y, z } to light" end
    if type(candidates) ~= "table" or #candidates == 0 then return nil, "planLights wants a list of candidate cells { x, y, z } for lights" end
    local dimName = dimensionOf(opts.dimension or T.cfg.dimension or "overworld")
    if not dimName then return nil, "opts.dimension is overworld, nether or end" end
    local min = opts.min or PLAN_MIN[dimName]
    if not (whole(min) and min >= 1 and min <= 15) then return nil, "opts.min is a light level, 1 to 15" end
    local item = fullName(opts.item or "lantern")
    local function xyz(c) return c.x or c[1], c.y or c[2], c.z or c[3] end
    -- the box round them all, for the model
    local bx1, by1, bz1, bx2, by2, bz2
    for _, list in ipairs({ cells, candidates }) do
        for i, c in ipairs(list) do
            local x, y, z = xyz(c)
            if not (whole(x) and whole(y) and whole(z)) then return nil, "cell " .. i .. " isn't { x, y, z }: whole numbers" end
            bx1, by1, bz1 = math.min(bx1 or x, x), math.min(by1 or y, y), math.min(bz1 or z, z)
            bx2, by2, bz2 = math.max(bx2 or x, x), math.max(by2 or y, y), math.max(bz2 or z, z)
        end
    end
    for _, c in ipairs(candidates) do
        local name = fullName(c.name or c[4] or item)
        if (emission(name)) < 1 then return nil, name .. " gives no light" end
    end
    local f, why = flood({ bx1, by1, bz1, bx2, by2, bz2 }, { with = opts.with })
    if not f then return nil, why end
    local need, needN, info = {}, 0, { lit = 0, covered = 0, left = {}, lights = 0 }
    for _, c in ipairs(cells) do
        local x, y, z = xyz(c)
        local k = key(x, y, z)
        if not need[k] then
            if (f.level(x, y, z) or 0) >= min then info.lit = info.lit + 1
            else need[k] = { x = x, y = y, z = z }; needN = needN + 1 end
        end
    end
    -- what each candidate alone lights to min: the same spread as the model's, from the candidate's cell
    local function reach(cx, cy, cz, name)
        local level = emission(name)
        local got, L, queue, head = {}, { [key(cx, cy, cz)] = level }, { { cx, cy, cz, level, classOf(name) } }, 1
        while queue[head] do
            local q = queue[head]
            head = head + 1
            local x, y, z, l, c = q[1], q[2], q[3], q[4], q[5]
            if l >= min and need[key(x, y, z)] then got[#got + 1] = key(x, y, z) end
            if l - 1 >= min then
                for _, d in ipairs(SIX) do
                    local nx, ny, nz = x + d[1], y + d[2], z + d[3]
                    local nk = key(nx, ny, nz)
                    if (L[nk] or 0) < l - 1 and nx >= bx1 - 15 and nx <= bx2 + 15 and ny >= by1 - 15 and ny <= by2 + 15
                        and nz >= bz1 - 15 and nz <= bz2 + 15 then
                        local nc = f.at(nx, ny, nz)
                        if not nc.opaque and not (d[2] == 1 and (c.up or nc.down)) and not (d[2] == -1 and (c.down or nc.up)) then
                            L[nk] = l - 1
                            queue[#queue + 1] = { nx, ny, nz, l - 1, nc }
                        end
                    end
                end
            end
            if head % BREATHE_EVERY == 0 then breathe() end
        end
        return got
    end
    local covers = {}
    for i, c in ipairs(candidates) do
        local x, y, z = xyz(c)
        covers[i] = reach(x, y, z, fullName(c.name or c[4] or item))
    end
    local picks, used = {}, {}
    while needN > 0 do
        local best, bestN = nil, 0
        for i, list in ipairs(covers) do
            if not used[i] then
                local n = 0
                for _, k in ipairs(list) do if need[k] then n = n + 1 end end
                if n > bestN then best, bestN = i, n end
            end
        end
        if not best then break end
        used[best] = true
        local c = candidates[best]
        local x, y, z = xyz(c)
        picks[#picks + 1] = { x = x, y = y, z = z, name = fullName(c.name or c[4] or item) }
        for _, k in ipairs(covers[best]) do
            if need[k] then need[k], needN = nil, needN - 1; info.covered = info.covered + 1 end
        end
    end
    for _, k in ipairs(tables.sortedKeys(need)) do info.left[#info.left + 1] = need[k] end
    info.lights = #picks
    local here = T.pos
    table.sort(picks, function(a, b)
        local da, db = T.dist(here, a), T.dist(here, b)
        if da ~= db then return da < db end
        return key(a.x, a.y, a.z) < key(b.x, b.y, b.z)
    end)
    info.summary = #picks .. " lights bring " .. info.covered .. " cells to light " .. min .. " (" .. info.lit .. " were already)"
        .. (#info.left > 0 and ("; " .. #info.left .. " no candidate reaches (info.left)") or "")
    return picks, info
end

return T
