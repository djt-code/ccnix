-- attach.lua -- what hangs on a block or stands on it, and would drop if the block were dug
--
-- Loaded by turtlelib the first time T.attachedTo is used (T.digCell's opts.attached asks for it).  Cells are the
-- turtle's own (the frame it counts in).
--
-- A torch on a block, a ladder on its side, a lantern hanging under it: in the game they break and drop when the block
-- that holds them goes.  T.attachedTo reads the six cells round a block in the map and names what the block holds, by a
-- table of names and a rule a name saying where its support is:
--   top          it stands on the block under it: a torch, redstone dust, a repeater, a rail, a carpet, a pressure plate,
--                a standing sign or banner, snow, a candle, a cake, a plant
--   below        it hangs from the block over it: a hanging sign, a spore blossom, hanging roots, weeping or cave vines
--   wall         it hangs on the block behind it, its facing pointing away: a wall torch, a ladder, a wall sign or
--                banner, a tripwire hook, a coral fan on a wall
--   face         a button or a lever, by its face: floor (top), ceiling (below) or wall (as wall)
--   hanging      a lantern: hanging from the block over it, else standing on the one under it
--   lower        a door or a tall plant: its lower half stands on the block under it (the upper half goes too)
--   toward       cocoa: its facing points at the log it grows on
--   multiface    vines, glow lichen, sculk veins: each face it has (north, up, ...) clings to the block that way
--   vertical     pointed dripstone: up stands on the block under it, down hangs from the one over it
--   directional  amethyst buds and clusters: on the block their facing points away from
--   bell         by its attachment: floor, ceiling; on a wall, which wall the rule leaves open (maybe)
--   sides        a wall hanging sign: on a block beside it, which one the rule leaves open (maybe)
-- The map has a block's state only when it was inspected (T.inspectAt, T.inspectAll; a scan gives names alone), and a
-- compass facing needs the world origin (T.setOrigin): a block that could be held but whose state or origin is lacking
-- is listed as maybe (sure = false).  What stands on what the block holds (a sugar cane's column, a door's upper half)
-- goes with it and isn't listed.  Java 1.21.1's blocks; a mod's blocks the table doesn't know aren't listed.

local T = require("turtlelib")

local COMPASS = { [0] = "north", "east", "south", "west" }
local COMPASS_AT = { north = 0, east = 1, south = 2, west = 3 }

-- Block names to rules, the first that matches winning (a name without a namespace matches any mod's)
local NAMES = {
    { "sides", { "*_wall_hanging_sign" } },
    { "below", { "*_hanging_sign", "spore_blossom", "hanging_roots", "weeping_vines", "weeping_vines_plant", "cave_vines",
                 "cave_vines_plant" } },
    { "wall", { "*wall_torch", "ladder", "*_wall_sign", "*_wall_banner", "tripwire_hook", "*_coral_wall_fan" } },
    { "hanging", { "lantern", "soul_lantern" } },
    { "face", { "*_button", "lever" } },
    { "lower", { "*_door", "tall_grass", "large_fern", "sunflower", "lilac", "rose_bush", "peony", "pitcher_plant",
                 "tall_seagrass", "small_dripleaf" } },
    { "toward", { "cocoa" } },
    { "multiface", { "vine", "glow_lichen", "sculk_vein" } },
    { "vertical", { "pointed_dripstone" } },
    { "directional", { "*amethyst_bud", "amethyst_cluster" } },
    { "bell", { "bell" } },
    { "top", { "torch", "soul_torch", "redstone_torch", "redstone_wire", "repeater", "comparator", "*rail", "*_carpet",
               "*_pressure_plate", "*_sign", "*_banner", "snow", "*candle", "*candle_cake", "cake", "*_sapling",
               "short_grass", "grass", "fern", "dead_bush", "dandelion", "poppy", "blue_orchid", "allium", "azure_bluet",
               "*_tulip", "oxeye_daisy", "cornflower", "lily_of_the_valley", "wither_rose", "torchflower", "pink_petals",
               "*_mushroom", "*_fungus", "crimson_roots", "warped_roots", "nether_sprouts", "wheat", "carrots", "potatoes",
               "beetroots", "melon_stem", "pumpkin_stem", "attached_melon_stem", "attached_pumpkin_stem",
               "torchflower_crop", "pitcher_crop", "sweet_berry_bush", "nether_wart", "sugar_cane", "cactus", "bamboo",
               "bamboo_sapling", "kelp", "kelp_plant", "seagrass", "sea_pickle", "*_coral", "*_coral_fan",
               "twisting_vines", "twisting_vines_plant", "azalea", "flowering_azalea", "big_dripleaf",
               "big_dripleaf_stem", "turtle_egg" } },
}
local TESTS = {}
for i, row in ipairs(NAMES) do TESTS[i] = { rule = row[1], test = T.nameTest(row[2]) } end

-- The cells round a block, and how what is there would be held by it
local AROUND = {
    { d = "up", how = "on top" }, { d = 0, how = "on the side" }, { d = 1, how = "on the side" },
    { d = 2, how = "on the side" }, { d = 3, how = "on the side" }, { d = "down", how = "below" },
}

-- Is a state's value the one wanted: true, false, or nil when either isn't known.
local function same(value, want)
    if value == nil or want == nil then return nil end
    return value == want
end

-- The rules: is the block in a cell held by the block it is `how` (on top, on the side, below) of?  True, false or
-- nil (can't tell).  s is its state (nil if the map lacks it); c.away is the compass way from the holding block to it,
-- c.back the way back (nil up and down, or with no origin).
local RULES = {}
function RULES.top(how) return how == "on top" end
function RULES.below(how) return how == "below" end
function RULES.wall(how, s, c) return how == "on the side" and same(s and s.facing, c.away) end
function RULES.face(how, s, c)
    local face = s and s.face
    if face == nil then return nil end
    if face == "floor" then return how == "on top" end
    if face == "ceiling" then return how == "below" end
    return RULES.wall(how, s, c)
end
function RULES.hanging(how, s)
    if how == "on the side" then return false end
    if not s or s.hanging == nil then return nil end
    return (s.hanging == true) == (how == "below")
end
function RULES.lower(how, s) return how == "on top" and same(s and s.half, "lower") end
function RULES.toward(how, s, c) return how == "on the side" and same(s and s.facing, c.back) end
function RULES.multiface(how, s, c)
    local face = (how == "on top" and "down") or (how == "below" and "up") or c.back
    if not s or face == nil then return nil end
    return s[face] == true
end
function RULES.vertical(how, s)
    if how == "on the side" then return false end
    return same(s and s.vertical_direction, how == "on top" and "up" or "down")
end
function RULES.directional(how, s, c)
    local want = (how == "on top" and "up") or (how == "below" and "down") or c.away
    return same(s and s.facing, want)
end
function RULES.bell(how, s)
    local a = s and s.attachment
    if a == "floor" then return how == "on top" end
    if a == "ceiling" then return how == "below" end
    if a ~= nil and how ~= "on the side" then return false end
    return nil
end
function RULES.sides(how) return how == "on the side" and nil end

-- The rule of a block name, or nil (it needs no support).
local ruleCache = {}
local function ruleOf(name)
    local r = ruleCache[name]
    if r == nil then
        r = false
        for _, t in ipairs(TESTS) do
            if t.test(name) then r = t.rule; break end
        end
        ruleCache[name] = r
    end
    return r or nil
end

local function whole(n) return type(n) == "number" and n == math.floor(n) end
local function key(x, y, z) return x .. "," .. y .. "," .. z end

-- What in the map hangs on or stands on the block at x, y, z and would drop if it were dug: a list of { x, y, z, name,
-- how ("on top", "on the side", "below"), sure }, and info; nil and why.
--
-- A torch, redstone, a rail, a carpet, a standing sign or a door on top; a wall torch, a ladder, a wall sign, a button
-- or a lever on a side, facing away from it; a lantern, a hanging sign or a button under it (the overview has the
-- table).  One the block may hold whose state the map lacks (or, for a facing, with no origin) is listed with sure =
-- false and why (T.inspectAll the cells to be sure).  Info is { sure, maybe (the counts), what (the list in words),
-- summary (a line) }.  T.digCell(x, y, z, { attached = "refuse" }) refuses a dig that would drop them.
function T.attachedTo(x, y, z)
    if not (whole(x) and whole(y) and whole(z)) then return nil, "attachedTo wants a cell of whole numbers: x, y, z" end
    local _, why = T.map.get(x, y, z)
    if why and why ~= "not in the map" then return nil, why end
    local origin = T.origin()
    local base = origin and COMPASS_AT[origin.facing]
    local function compass(d)
        if type(d) ~= "number" or not base then return nil end
        return COMPASS[(base + d) % 4]
    end
    local list, info, words = {}, { sure = 0, maybe = 0 }, {}
    for _, a in ipairs(AROUND) do
        local v = T.DELTA[a.d]
        local ax, ay, az = x + v[1], y + v[2], z + v[3]
        local name, state = T.map.get(ax, ay, az)
        local rule = type(name) == "string" and ruleOf(name)
        if rule then
            if type(state) ~= "table" then state = nil end
            local held = RULES[rule](a.how, state, { away = compass(a.d), back = compass(T.OPP[a.d]) })
            if held ~= false then
                local item = { x = ax, y = ay, z = az, name = name, how = a.how, sure = held == true }
                local text = name .. " at " .. key(ax, ay, az) .. " (" .. a.how
                if item.sure then
                    info.sure = info.sure + 1
                else
                    info.maybe = info.maybe + 1
                    item.why = state and "no origin for its facing (T.setOrigin)" or "the map has no state for it (T.inspectAt)"
                    text = text .. ", maybe: " .. item.why
                end
                list[#list + 1] = item
                words[#words + 1] = text .. ")"
            end
        end
    end
    info.what = table.concat(words, ", ")
    if #list == 0 then
        info.summary = "nothing in the map hangs on or stands on " .. key(x, y, z)
    else
        info.summary = "digging " .. key(x, y, z) .. " would drop " .. info.what
    end
    return list, info
end

return T
