-- craft.lua -- crafting and smelting: recipes as data, T.craft, T.canCraft, T.smelt, and what burns and smelts
--
-- Loaded by turtlelib the first time one of its functions is used (T.craft, T.canCraft, T.recipe, T.addRecipe,
-- T.smelt, T.fuelTicks, T.smeltsTo).
--
-- Recipes are written as the game's data packs write them: up to three rows of letters (a dot is an empty cell), what
-- each letter stands for (a name, a list of names or a glob like "*_planks", minecraft: assumed), what comes out and
-- how many.  A family is one entry: "minecraft:{}_stairs" over a list of blocks makes every one's stairs, the {} being
-- the block's name without its ending (oak_planks gives oak, stone_bricks gives stone_brick); a map entry gives the
-- block each result is made from (chiseled forms from their slabs).  T.addRecipe adds more, for modded items.  The
-- table is T.RECIPES (it exists once this module has loaded), the newest first.
--
-- A turtle crafts through the crafting table as a peripheral, and only when every slot outside the grid is empty.  So
-- T.craft works from a chest: it checks the chest has room for the whole inventory, puts the crafting table on (through
-- T.withPeripheral: a chunk controller stays on), stashes everything in the chest, the pickaxe too, pulls each round's
-- ingredients into the grid's slots (1-3, 5-7 and 9-11), crafts, stashes again, and at the end puts the inventory back
-- and the product with it.  What it made is never junk (T.markCrafted).  T.canCraft says what is short, from the
-- inventory and the chest.  A craft does the recipe asked for; an ingredient that is itself crafted (planks from logs,
-- sticks from planks) is made first with its own T.craft.
--
-- T.smelt runs a furnace: a furnace takes fuel through its sides, the item through its top, and gives the result
-- through its underside only.  It sets the furnace up in front of the turtle, one block up, so the cell under it is
-- free to stand in, drops the fuel from beside, the item from above, sucks the results from below as they cook (ten
-- seconds an item), and takes the furnace back.  What burns and how long (T.fuelTicks; the nether's woods do not) and
-- what smelts into what (T.smeltsTo) are tables: T.FURNACE_FUEL and T.SMELTS.

local T = require("turtlelib")
local text = require("text")
local glob = require("glob")
local tables = require("tables")

local NS = "minecraft:"
local TABLE = "minecraft:crafting_table"
local FURNACE = "minecraft:furnace"
local SIDES = { "front", "top", "bottom" }           -- where a chest may be, as for turtle.suck
local STACK = 64
local SMELT_TICKS = 200                              -- ticks a furnace takes to cook an item (ten seconds)

-- A name with its namespace (minecraft: if it has none).
local function full(name)
    if text.contains(name, ":") then return name end
    return NS .. name
end

-- The name without its namespace.
local function shortName(name)
    local _, after = text.cut(name, ":")
    return after or name
end

local function isWhole(n) return type(n) == "number" and n == math.floor(n) end

-- A copy of a list or table of counts.
local function copyOf(t)
    local out = {}
    for k, v in pairs(t) do out[k] = v end
    return out
end

--------------------------------------------------------------------------
-- Materials: the woods, the stones and what is made of them
--------------------------------------------------------------------------

local LOG_WOODS = { "oak", "spruce", "birch", "jungle", "acacia", "dark_oak", "mangrove", "cherry", "pale_oak" }
local STEM_WOODS = { "crimson", "warped" }            -- the nether's: stems and hyphae, and they do not burn
local PLANK_WOODS = {}                                -- every wood with planks
for _, list in ipairs({ LOG_WOODS, { "bamboo" }, STEM_WOODS }) do
    for _, w in ipairs(list) do PLANK_WOODS[#PLANK_WOODS + 1] = w end
end

-- Full names from a form with {} for the wood or stone: each(LOG_WOODS, "{}_planks")
local function each(list, form)
    local out = {}
    for i, w in ipairs(list) do out[i] = NS .. text.replace(form, "{}", w) end
    return out
end

-- Lists put end to end.
local function joined(...)
    local out = {}
    for _, list in ipairs({ ... }) do
        for _, v in ipairs(list) do out[#out + 1] = v end
    end
    return out
end

local PLANKS = each(PLANK_WOODS, "{}_planks")
local LOG_PLANKS = each(LOG_WOODS, "{}_planks")
-- Everything planks are made from: logs and wood, stripped or not; the nether's stems and hyphae
local LOGS = joined(each(LOG_WOODS, "{}_log"), each(LOG_WOODS, "{}_wood"), each(LOG_WOODS, "stripped_{}_log"),
    each(LOG_WOODS, "stripped_{}_wood"), each(STEM_WOODS, "{}_stem"), each(STEM_WOODS, "{}_hyphae"),
    each(STEM_WOODS, "stripped_{}_stem"), each(STEM_WOODS, "stripped_{}_hyphae"))

-- The blocks that have stairs, slabs and walls (without the namespace)
local STAIR_STONES = {
    "cobblestone", "mossy_cobblestone", "stone", "stone_bricks", "mossy_stone_bricks", "andesite", "polished_andesite",
    "diorite", "polished_diorite", "granite", "polished_granite", "sandstone", "smooth_sandstone", "red_sandstone",
    "smooth_red_sandstone", "bricks", "nether_bricks", "red_nether_bricks", "quartz_block", "smooth_quartz",
    "purpur_block", "prismarine", "prismarine_bricks", "dark_prismarine", "end_stone_bricks", "blackstone",
    "polished_blackstone", "polished_blackstone_bricks", "cobbled_deepslate", "polished_deepslate", "deepslate_bricks",
    "deepslate_tiles", "mud_bricks", "tuff", "polished_tuff", "tuff_bricks",
}
local SLAB_STONES = joined(STAIR_STONES, { "smooth_stone", "cut_sandstone", "cut_red_sandstone" })
local WALL_STONES = {
    "cobblestone", "mossy_cobblestone", "stone_bricks", "mossy_stone_bricks", "andesite", "diorite", "granite",
    "sandstone", "red_sandstone", "bricks", "nether_bricks", "red_nether_bricks", "end_stone_bricks", "prismarine",
    "blackstone", "polished_blackstone", "polished_blackstone_bricks", "cobbled_deepslate", "polished_deepslate",
    "deepslate_bricks", "deepslate_tiles", "mud_bricks", "tuff", "polished_tuff", "tuff_bricks",
}
local STAIR_BLOCKS = joined(each(STAIR_STONES, "{}"), PLANKS, { NS .. "bamboo_mosaic" })
local SLAB_BLOCKS = joined(each(SLAB_STONES, "{}"), PLANKS, { NS .. "bamboo_mosaic" })
local WALL_BLOCKS = each(WALL_STONES, "{}")

-- Blocks made of four (or one) of another, 2 by 2: result = what it is made of
local SQUARE_OF_4 = {
    stone_bricks = "stone", polished_andesite = "andesite", polished_diorite = "diorite", polished_granite = "granite",
    polished_blackstone = "blackstone", polished_blackstone_bricks = "polished_blackstone",
    polished_deepslate = "cobbled_deepslate", deepslate_bricks = "polished_deepslate",
    deepslate_tiles = "deepslate_bricks", polished_tuff = "tuff", tuff_bricks = "polished_tuff",
    cut_sandstone = "sandstone", cut_red_sandstone = "red_sandstone", end_stone_bricks = "end_stone",
    mud_bricks = "packed_mud", quartz_bricks = "quartz_block", purpur_block = "popped_chorus_fruit",
}
local SQUARE_OF_1 = {
    sandstone = "sand", red_sandstone = "red_sand", bricks = "brick", nether_bricks = "nether_brick",
    quartz_block = "quartz", prismarine = "prismarine_shard", glowstone = "glowstone_dust",
}
-- Chiseled and pillar forms: two of the slab, one over the other
local CHISELED = {
    chiseled_stone_bricks = "stone_brick_slab", chiseled_sandstone = "sandstone_slab",
    chiseled_red_sandstone = "red_sandstone_slab", chiseled_quartz_block = "quartz_slab",
    chiseled_nether_bricks = "nether_brick_slab", chiseled_polished_blackstone = "polished_blackstone_slab",
    chiseled_deepslate = "cobbled_deepslate_slab", chiseled_tuff = "tuff_slab", chiseled_tuff_bricks = "tuff_brick_slab",
    purpur_pillar = "purpur_slab",
}

--------------------------------------------------------------------------
-- Fuel and smelting: what burns for how long, what smelts into what
--------------------------------------------------------------------------

-- Ticks a furnace burns each fuel (20 a second; an item smelts in 200).  Wood things are filled in below from
-- WOOD_FUEL; the nether's woods are not in it, and burn nowhere.
local FURNACE_FUEL = {
    ["minecraft:coal"] = 1600, ["minecraft:charcoal"] = 1600, ["minecraft:coal_block"] = 16000,
    ["minecraft:lava_bucket"] = 20000, ["minecraft:blaze_rod"] = 2400, ["minecraft:dried_kelp_block"] = 4000,
    ["minecraft:stick"] = 100, ["minecraft:bamboo"] = 50, ["minecraft:scaffolding"] = 50,
    ["minecraft:bamboo_mosaic"] = 300, ["minecraft:ladder"] = 300, ["minecraft:chest"] = 300,
    ["minecraft:trapped_chest"] = 300, ["minecraft:barrel"] = 300, ["minecraft:crafting_table"] = 300,
    ["minecraft:bookshelf"] = 300, ["minecraft:lectern"] = 300, ["minecraft:jukebox"] = 300,
    ["minecraft:note_block"] = 300, ["minecraft:loom"] = 300, ["minecraft:composter"] = 300,
    ["minecraft:cartography_table"] = 300, ["minecraft:fletching_table"] = 300, ["minecraft:smithing_table"] = 300,
    ["minecraft:bowl"] = 300, ["minecraft:bow"] = 300, ["minecraft:crossbow"] = 300, ["minecraft:fishing_rod"] = 300,
    ["minecraft:daylight_detector"] = 300, ["minecraft:wooden_sword"] = 200, ["minecraft:wooden_pickaxe"] = 200,
    ["minecraft:wooden_axe"] = 200, ["minecraft:wooden_shovel"] = 200, ["minecraft:wooden_hoe"] = 200,
}
-- What each form of wood burns for, and the woods that do (with logs, with boats)
local WOOD_FUEL = {
    planks = 300, stairs = 300, slab = 150, fence = 300, fence_gate = 300, door = 200, trapdoor = 300,
    button = 100, pressure_plate = 300, sign = 200,
}
local LOG_FUEL = { log = 300, wood = 300, stripped_log = 300, stripped_wood = 300, boat = 1200 }
for _, w in ipairs(joined(LOG_WOODS, { "bamboo" })) do
    for form, ticks in pairs(WOOD_FUEL) do FURNACE_FUEL[NS .. w .. "_" .. form] = ticks end
end
for _, w in ipairs(LOG_WOODS) do
    FURNACE_FUEL[NS .. w .. "_log"], FURNACE_FUEL[NS .. w .. "_wood"] = LOG_FUEL.log, LOG_FUEL.wood
    FURNACE_FUEL[NS .. "stripped_" .. w .. "_log"] = LOG_FUEL.stripped_log
    FURNACE_FUEL[NS .. "stripped_" .. w .. "_wood"] = LOG_FUEL.stripped_wood
    FURNACE_FUEL[NS .. w .. "_boat"] = LOG_FUEL.boat
    FURNACE_FUEL[NS .. w .. "_sapling"] = 100
end

-- What a furnace smelts, result by item.  Wood and logs of the overworld make charcoal; the nether's stems do not.
local SMELTS = {
    cobblestone = "stone", stone = "smooth_stone", sand = "glass", red_sand = "glass", clay_ball = "brick",
    clay = "terracotta", netherrack = "nether_brick", cobbled_deepslate = "deepslate", stone_bricks = "cracked_stone_bricks",
    deepslate_bricks = "cracked_deepslate_bricks", deepslate_tiles = "cracked_deepslate_tiles",
    nether_bricks = "cracked_nether_bricks", polished_blackstone_bricks = "cracked_polished_blackstone_bricks",
    sandstone = "smooth_sandstone", red_sandstone = "smooth_red_sandstone", quartz_block = "smooth_quartz",
    basalt = "smooth_basalt", cactus = "green_dye", kelp = "dried_kelp", sea_pickle = "lime_dye",
    wet_sponge = "sponge", chorus_fruit = "popped_chorus_fruit",
    raw_iron = "iron_ingot", iron_ore = "iron_ingot", deepslate_iron_ore = "iron_ingot",
    raw_gold = "gold_ingot", gold_ore = "gold_ingot", deepslate_gold_ore = "gold_ingot", nether_gold_ore = "gold_ingot",
    raw_copper = "copper_ingot", copper_ore = "copper_ingot", deepslate_copper_ore = "copper_ingot",
    ancient_debris = "netherite_scrap", coal_ore = "coal", deepslate_coal_ore = "coal", lapis_ore = "lapis_lazuli",
    deepslate_lapis_ore = "lapis_lazuli", redstone_ore = "redstone", deepslate_redstone_ore = "redstone",
    diamond_ore = "diamond", deepslate_diamond_ore = "diamond", emerald_ore = "emerald",
    deepslate_emerald_ore = "emerald", nether_quartz_ore = "quartz",
    beef = "cooked_beef", porkchop = "cooked_porkchop", mutton = "cooked_mutton", chicken = "cooked_chicken",
    rabbit = "cooked_rabbit", cod = "cooked_cod", salmon = "cooked_salmon", potato = "baked_potato",
}
for name, result in pairs(copyOf(SMELTS)) do
    SMELTS[name] = nil
    SMELTS[NS .. name] = NS .. result
end
for _, log in ipairs(joined(each(LOG_WOODS, "{}_log"), each(LOG_WOODS, "{}_wood"), each(LOG_WOODS, "stripped_{}_log"),
    each(LOG_WOODS, "stripped_{}_wood"))) do
    SMELTS[log] = NS .. "charcoal"
end

T.FURNACE_FUEL = FURNACE_FUEL
T.SMELTS = SMELTS
T.SMELT_TICKS = SMELT_TICKS

-- Fuels to try first for a smelt, when none is named (never the chest or the crafting table, which burn too)
local FUEL_PREFER = { "minecraft:charcoal", "minecraft:coal", "minecraft:coal_block", "minecraft:blaze_rod",
    "minecraft:dried_kelp_block", "*_planks", "*_log" }

--------------------------------------------------------------------------
-- Recipes: the table, and finding the ones that make an item
--------------------------------------------------------------------------

-- The end of a name to take off for a family's {}, and what goes in its place.  One rule is applied (the first that
-- fits), after a "stripped_" start is taken off.
local STEM_ENDS = {
    { "_planks", "" }, { "_bricks", "_brick" }, { "_tiles", "_tile" }, { "_block", "" }, { "_log", "" },
    { "_wood", "" }, { "_stem", "" }, { "_hyphae", "" },
}

-- The stem of an item name, for a family's {}: oak_planks gives oak, stone_bricks gives stone_brick.
local function stem(item)
    local s = shortName(item)
    s = text.stripPrefix(s, "stripped_") or s
    if s == "bricks" then return "brick" end
    for _, rule in ipairs(STEM_ENDS) do
        local base = text.stripSuffix(s, rule[1])
        if base then return base .. rule[2] end
    end
    return s
end

-- A test on item names from a spec: a name, a glob (minecraft: assumed) or a list of those.
local function matcher(spec)
    local list = type(spec) == "table" and spec or { spec }
    local exact, tests = {}, {}
    for _, s in ipairs(list) do
        local g = full(s)
        if glob.hasWildcards(g) then tests[#tests + 1] = glob.compile(g) else exact[g] = true end
    end
    return function(name)
        if exact[name] then return true end
        for _, test in ipairs(tests) do
            if test(name) then return true end
        end
        return false
    end
end

-- A spec in words for a message: "oak_planks", "*_planks", "coal or charcoal".
local function labelOf(spec)
    if type(spec) ~= "table" then return shortName(spec) end
    local parts = {}
    for i = 1, math.min(#spec, 3) do parts[i] = shortName(spec[i]) end
    return table.concat(parts, " or ") .. (#spec > 3 and " or ..." or "")
end

-- The recipes, newest first.  A row: out (a name, or with {} for a family), count, shape (rows of letters),
-- key (letter = spec), mixed (one letter may stand for different items), and for a family of: the letter whose item
-- gives the {}, with from (the list of items) or map (result = item).
local rows = {}

-- Check a recipe spec: nil if it is a recipe, else why not.
local function checkRow(spec)
    if type(spec) ~= "table" then return "a recipe is a table: { out, count, shape, key }" end
    if type(spec.out) ~= "string" or spec.out == "" then return "a recipe needs out, the name of what it makes" end
    if spec.count ~= nil and not (isWhole(spec.count) and spec.count >= 1) then
        return "a recipe's count is a whole number of 1 or more, not " .. tostring(spec.count)
    end
    local shape = spec.shape
    if type(shape) ~= "table" or #shape < 1 or #shape > 3 then return "a recipe's shape is 1 to 3 rows of letters" end
    local letters, any = {}, false
    for i, line in ipairs(shape) do
        if type(line) ~= "string" or #line < 1 or #line > 3 then
            return "a recipe's shape rows are 1 to 3 characters wide, not row " .. i
        end
        for c = 1, #line do
            local ch = line:sub(c, c)
            if ch ~= "." and ch ~= " " then letters[ch] = true; any = true end
        end
    end
    if not any then return "a recipe's shape has no ingredient in it" end
    local derived = spec.from ~= nil or spec.map ~= nil
    if derived then
        if type(spec.of) ~= "string" or not letters[spec.of] then
            return "a family names the letter of the shape it is made of: of = \"X\""
        end
        if (spec.from == nil) == (spec.map == nil) then return "a family has from (a list) or map (result = item), not both" end
        if spec.from ~= nil and (type(spec.from) ~= "table" or #spec.from < 1) then return "from is a list of item names" end
        if spec.from ~= nil and not text.contains(spec.out, "{}") then return "a family's out has {} in it: \"minecraft:{}_stairs\"" end
    end
    for letter in pairs(letters) do
        local k = (spec.key or {})[letter]
        local made = derived and spec.of == letter
        if not made then
            if type(k) == "table" then
                if #k < 1 then return "key " .. letter .. " is an empty list" end
                for _, s in ipairs(k) do
                    if type(s) ~= "string" then return "key " .. letter .. " lists names, as text" end
                end
            elseif type(k) ~= "string" then
                return "the shape uses " .. letter .. " but the key does not say what it is"
            end
        end
    end
    return nil
end

-- A recipe row from a spec, with the names in full.  (Not checked: see checkRow.)
local function rowOf(spec)
    local row = { out = full(spec.out), count = spec.count or 1, shape = copyOf(spec.shape), key = {},
                  mixed = spec.mixed == true, of = spec.of, tests = {} }
    for letter, k in pairs(spec.key or {}) do row.key[letter] = type(k) == "table" and copyOf(k) or k end
    if spec.from then
        row.from = {}
        for i, item in ipairs(spec.from) do row.from[i] = full(item) end
    end
    if spec.map then
        row.map = {}
        for result, item in pairs(spec.map) do row.map[full(result)] = full(item) end
    end
    return row
end

local function define(spec)
    rows[#rows + 1] = rowOf(spec)
end

-- The built-in recipes: vanilla's building and tool basics.
-- Wood
define { out = "{}_planks", count = 4, shape = { "L" }, of = "L", from = LOGS }
define { out = "stick", count = 4, shape = { "P", "P" }, key = { P = "*_planks" }, mixed = true }
define { out = "crafting_table", shape = { "PP", "PP" }, key = { P = "*_planks" }, mixed = true }
define { out = "chest", shape = { "PPP", "P.P", "PPP" }, key = { P = "*_planks" }, mixed = true }
define { out = "ladder", count = 3, shape = { "S.S", "SSS", "S.S" }, key = { S = "stick" } }
define { out = "{}_door", count = 3, shape = { "XX", "XX", "XX" }, of = "X", from = PLANKS }
define { out = "{}_trapdoor", count = 2, shape = { "XXX", "XXX" }, of = "X", from = PLANKS }
define { out = "{}_fence", count = 3, shape = { "XSX", "XSX" }, key = { S = "stick" }, of = "X", from = PLANKS }
define { out = "{}_fence_gate", shape = { "SXS", "SXS" }, key = { S = "stick" }, of = "X", from = PLANKS }
define { out = "{}_button", shape = { "X" }, of = "X", from = PLANKS }
define { out = "{}_pressure_plate", shape = { "XX" }, of = "X", from = PLANKS }
define { out = "{}_sign", count = 3, shape = { "XXX", "XXX", ".S." }, key = { S = "stick" }, of = "X", from = PLANKS }
define { out = "{}_boat", shape = { "X.X", "XXX" }, of = "X", from = LOG_PLANKS }
-- Stairs, slabs and walls: of each wood's planks and each stone (the bamboo mosaic too)
define { out = "{}_stairs", count = 4, shape = { "X..", "XX.", "XXX" }, of = "X", from = STAIR_BLOCKS }
define { out = "{}_slab", count = 6, shape = { "XXX" }, of = "X", from = SLAB_BLOCKS }
define { out = "{}_wall", count = 6, shape = { "XXX", "XXX" }, of = "X", from = WALL_BLOCKS }
-- Stone
define { out = "furnace", shape = { "CCC", "C.C", "CCC" }, key = { C = { "cobblestone", "blackstone", "cobbled_deepslate" } }, mixed = true }
do
    local four, one, pillars = {}, {}, {}
    for result, item in pairs(SQUARE_OF_4) do four[result] = item end
    for result, item in pairs(SQUARE_OF_1) do one[result] = item end
    for result, item in pairs(CHISELED) do pillars[result] = item end
    define { out = "bricks", count = 4, shape = { "XX", "XX" }, of = "X", map = four }
    define { out = "bricks", count = 1, shape = { "XX", "XX" }, of = "X", map = one }
    define { out = "chiseled", shape = { "X", "X" }, of = "X", map = pillars }
    define { out = "quartz_pillar", count = 2, shape = { "X", "X" }, key = { X = "quartz_block" } }
end
-- Light and metal
define { out = "torch", count = 4, shape = { "C", "S" }, key = { C = { "coal", "charcoal" }, S = "stick" } }
define { out = "soul_torch", count = 4, shape = { "C", "S", "X" },
         key = { C = { "coal", "charcoal" }, S = "stick", X = { "soul_sand", "soul_soil" } } }
define { out = "lantern", shape = { "NNN", "NTN", "NNN" }, key = { N = "iron_nugget", T = "torch" } }
define { out = "soul_lantern", shape = { "NNN", "NTN", "NNN" }, key = { N = "iron_nugget", T = "soul_torch" } }
define { out = "iron_nugget", count = 9, shape = { "I" }, key = { I = "iron_ingot" } }
define { out = "chain", shape = { "N", "I", "N" }, key = { N = "iron_nugget", I = "iron_ingot" } }
define { out = "iron_bars", count = 16, shape = { "III", "III" }, key = { I = "iron_ingot" } }
define { out = "glass_pane", count = 16, shape = { "GGG", "GGG" }, key = { G = "glass" } }
define { out = "bucket", shape = { "I.I", ".I." }, key = { I = "iron_ingot" } }
define { out = "nether_brick_fence", count = 6, shape = { "NIN", "NIN" }, key = { N = "nether_bricks", I = "nether_brick" } }

-- (A map row's out is only a placeholder: what it makes is the map's keys.)
T.RECIPES = rows

-- The recipes that make `outName`, each { row, fixed = { letter = item } }: fixed is the item the family's letter
-- stands for.  Newest first.
local function candidatesFor(outName)
    local found = {}
    for _, row in ipairs(rows) do
        if row.map then
            local item = row.map[outName]
            if item then found[#found + 1] = { row = row, fixed = { [row.of] = item } } end
        elseif row.from then
            for _, item in ipairs(row.from) do
                if text.replace(row.out, "{}", stem(item)) == outName then
                    found[#found + 1] = { row = row, fixed = { [row.of] = item } }
                    break
                end
            end
        elseif row.out == outName then
            found[#found + 1] = { row = row, fixed = {} }
        end
    end
    return found
end

-- The cells of a recipe's shape that hold an item: a list of { slot, letter }, in reading order.  The turtle's grid is
-- the top left 3 by 3 of its 4 by 4 inventory: slots 1-3, 5-7 and 9-11.
local function cellsOf(row)
    local cells = {}
    for r, line in ipairs(row.shape) do
        for c = 1, #line do
            local ch = line:sub(c, c)
            if ch ~= "." and ch ~= " " then cells[#cells + 1] = { slot = (r - 1) * 4 + c, letter = ch } end
        end
    end
    return cells
end

-- The test for the items a letter may be (cached on the row).
local function testFor(row, letter)
    local test = row.tests[letter]
    if not test then
        test = matcher(row.key[letter])
        row.tests[letter] = test
    end
    return test
end

--------------------------------------------------------------------------
-- Working out a craft from a stock of items
--------------------------------------------------------------------------

-- The item in `left` (counts by name, `sorted` its names) that passes `test`, has at least `need` and the most.
local function pick(test, need, left, sorted)
    local best
    for _, name in ipairs(sorted) do
        local have = left[name]
        if have >= need and test(name) and (not best or have > left[best]) then best = name end
    end
    return best
end

-- Lay a recipe out for p crafts from `left` (counts by name, taken from as it goes): the item in each cell as a list of
-- { slot, item }, or nil if the stock cannot give every cell p of something.  A letter that is not "mixed" is one item
-- all through.
local function lay(cand, cells, p, left, sorted)
    local row = cand.row
    local count, chosen, layout = {}, {}, {}
    for _, c in ipairs(cells) do count[c.letter] = (count[c.letter] or 0) + 1 end
    for _, c in ipairs(cells) do
        local item = cand.fixed[c.letter]
        if not item then
            item = chosen[c.letter]
            if not (item and (not row.mixed or left[item] >= p)) then
                item = pick(testFor(row, c.letter), row.mixed and p or p * count[c.letter], left, sorted)
            end
            if not item then return nil end
            chosen[c.letter] = item
        end
        if (left[item] or 0) < p then return nil end
        left[item] = left[item] - p
        layout[#layout + 1] = { slot = c.slot, item = item }
    end
    return layout
end

-- The rounds of crafting that make `crafts` crafts from the stock: a list of { p, layout } (p crafts at once, at most 64
-- and as many as the free slots can hold the product of), and how many crafts they come to.
local function plan(cand, cells, crafts, stock)
    local left = copyOf(stock)
    local sorted = tables.sortedKeys(left)
    local cap = math.max(1, math.floor(STACK * (15 - #cells) / cand.row.count))
    local rounds, done = {}, 0
    while done < crafts do
        local p, layout
        for try = math.min(crafts - done, STACK, cap), 1, -1 do
            local trial = copyOf(left)
            layout = lay(cand, cells, try, trial, sorted)
            if layout then p, left = try, trial; break end
        end
        if not p then break end
        rounds[#rounds + 1] = { p = p, layout = layout }
        done = done + p
    end
    return rounds, done
end

-- What is short for `crafts` crafts of a candidate: a list of { item, need, have, short } (item in words).
local function shortOf(cand, cells, crafts, stock)
    local row, count, order, out = cand.row, {}, {}, {}
    for _, c in ipairs(cells) do
        if not count[c.letter] then order[#order + 1] = c.letter; count[c.letter] = 0 end
        count[c.letter] = count[c.letter] + 1
    end
    for _, letter in ipairs(order) do
        local need, item, have = count[letter] * crafts, cand.fixed[letter], 0
        if item then
            have = stock[item] or 0
        else
            local test = testFor(row, letter)
            for name, n in pairs(stock) do
                if test(name) then
                    if row.mixed then have = have + n elseif n > have then have = n end
                end
            end
        end
        if have < need then
            out[#out + 1] = { item = item and shortName(item) or labelOf(row.key[letter]), need = need, have = have,
                              short = need - have }
        end
    end
    return out
end

-- The short list in a sentence: "short of oak_planks: need 6, have 4; stick: ...".
local function shortText(short)
    local parts = {}
    for i, s in ipairs(short) do parts[i] = s.item .. ": need " .. s.need .. ", have " .. s.have end
    return "short of " .. table.concat(parts, "; ")
end

-- How many of each item the turtle carries, plus what the container on `side` holds (if any).
local function stockOf(side)
    local n = {}
    for s = 1, 16 do
        local it = turtle.getItemDetail(s)
        if it then n[it.name] = (n[it.name] or 0) + it.count end
    end
    for name, count in pairs((side and T.containerCounts(side)) or {}) do n[name] = (n[name] or 0) + count end
    return n
end

-- Which candidate to use for n of the item: the first that can be made in full; with partial, the one that makes
-- the most; else nil, why and what is short.  Returns cand, cells, rounds, crafts wanted, crafts it makes.
local function choose(cands, n, stock, partial)
    local best, bestShort, bestWhy
    for _, cand in ipairs(cands) do
        local cells = cellsOf(cand.row)
        local need = math.ceil(n / cand.row.count)
        local rounds, done = plan(cand, cells, need, stock)
        if done >= need then return cand, cells, rounds, need, done end
        if partial and done > 0 and (not best or done > best.done) then
            best = { cand = cand, cells = cells, rounds = rounds, need = need, done = done }
        end
        local short = shortOf(cand, cells, need, stock)
        local total = 0
        for _, s in ipairs(short) do total = total + s.short end
        if #short == 0 then short = { { item = "room in the grid", need = need, have = done, short = need - done } } end
        if not bestShort or total < bestShort.total then bestShort = { list = short, total = total } end
    end
    if best then return best.cand, best.cells, best.rounds, best.need, best.done end
    return nil, shortText(bestShort.list), bestShort.list
end

--------------------------------------------------------------------------
-- Reading and adding recipes, and asking what is short
--------------------------------------------------------------------------

-- Add a recipe (modded items, say): out (the item made), count, shape, key, mixed, and for a family of, from or map.
-- True, or nil and why not.
--
-- spec = { out = "mod:widget", count = 2, shape = { "AA", "B." }, key = { A = "minecraft:iron_ingot", B = "*_planks" } }.
-- A letter in the shape is a name, a list of names or a glob (a name with no namespace is minecraft:'s); a dot is an
-- empty cell; mixed = true lets one letter stand for different items (any planks).  A family has out with {} in it and
-- of = "X" for the letter that is the block, with from = a list of blocks, or map = { result = block }.  The newest
-- recipe is tried first.  Kept in memory only: put the calls in /claude/helpers.lua to have them each session.
function T.addRecipe(spec)
    local why = checkRow(spec)
    if why then return nil, why end
    table.insert(rows, 1, rowOf(spec))
    return true
end

-- The first recipe that makes an item: { out, count, shape, key, mixed } or nil and why.
--
-- shape is the rows of letters, key what each letter is (a name, a glob, a list of names; for a family the block this
-- item is made from), mixed whether one letter may be several items.  There may be more than one recipe for it; this
-- is the first (the newest added, else the built-in).
function T.recipe(name)
    if type(name) ~= "string" then return nil, "T.recipe wants an item name, like minecraft:chest" end
    name = full(name)
    local cands = candidatesFor(name)
    if #cands == 0 then return nil, "no recipe for " .. name .. " (T.addRecipe adds one)" end
    local row, cand = cands[1].row, cands[1]
    local key = {}
    for _, c in ipairs(cellsOf(row)) do
        key[c.letter] = cand.fixed[c.letter] or (type(row.key[c.letter]) == "table" and copyOf(row.key[c.letter])) or row.key[c.letter]
    end
    return { out = name, count = row.count, shape = copyOf(row.shape), key = key, mixed = row.mixed }
end

-- Is n a count of items to make?
local function isCount(n) return isWhole(n) and n >= 1 end

-- The container to craft from without going anywhere: opts.chest if it is a side ("front", "top", "bottom") with
-- a container on it, else the first of those with one.  Nil if none.
local function chestSide(opts)
    if type(opts.chest) == "string" then
        if T.containerOn(opts.chest) then return opts.chest end
        return nil
    end
    if opts.chest ~= nil then return nil end
    for _, side in ipairs(SIDES) do
        if T.containerOn(side) then return side end
    end
    return nil
end

-- Can the item be crafted: true, or false, why and the short list.  Counts the inventory and the chest.
--
-- name is the item, n how many to have (default 1; whole crafts, so more may come out).  The chest is the container
-- opts.chest names (front, top or bottom) or the first there is; nothing moves.  Returns true and { crafts,
-- makes }; or false, a sentence ("short of oak_planks: need 6, have 4") and the list of { item, need, have, short }.
-- It does the one recipe asked for: an ingredient that is itself crafted, planks from logs, counts as short.
function T.canCraft(name, n, opts)
    opts = opts or {}
    if type(name) ~= "string" then return false, "T.canCraft wants an item name, like minecraft:chest" end
    n = n == nil and 1 or n
    if not isCount(n) then return false, "how many to make is a whole number of 1 or more" end
    name = full(name)
    local cands = candidatesFor(name)
    if #cands == 0 then return false, "no recipe for " .. name .. " (T.addRecipe adds one)" end
    local stock = stockOf(chestSide(opts))
    local cand, cells, rounds, need, done = choose(cands, n, stock, false)
    if not cand then return false, cells, rounds end
    return true, { crafts = need, makes = need * cand.row.count }
end

--------------------------------------------------------------------------
-- Crafting from a chest
--------------------------------------------------------------------------

-- Put every stack the turtle carries into the container on `side`.  True, or false and why (it filled up).
local function stashAll(side)
    local left = 0
    for s = 1, 16 do
        local n = turtle.getItemCount(s)
        if n > 0 then
            turtle.select(s)
            T.dropSide(side, n)
            left = left + turtle.getItemCount(s)
        end
    end
    if left > 0 then return false, "the chest filled up with " .. left .. " items still in the turtle" end
    return true
end

-- One round: fill the grid from the chest for r.p crafts and craft.  Returns how many of the item that made, and why it
-- stopped short (a cell ran dry, the crafting refused) or nil.
local function oneRound(bench, side, outName, r)
    for _, c in ipairs(r.layout) do T.takeInto(side, c.item, r.p, c.slot) end
    local most = r.p
    for _, c in ipairs(r.layout) do most = math.min(most, turtle.getItemCount(c.slot)) end
    if most < 1 then return 0, "the chest ran out of an ingredient" end
    turtle.select(16)                                    -- (what is made goes in from here)
    local before = T.countItem(outName)
    local ok, res, msg = pcall(bench.craft, most)
    local made = T.countItem(outName) - before
    if not ok then
        if res == "Terminated" then error(res, 0) end
        return made, "the crafting failed: " .. tostring(res)
    end
    if res == false then return made, "the crafting table would not craft: " .. tostring(msg or "no recipe matched") end
    return made
end

-- Put back what the stash held: each stack into the slot it came from (what was used up is not there to come back),
-- then the product.  Returns how many of the product are not aboard.
local function unstash(side, snap, outName, made)
    for _, e in ipairs(snap) do T.takeInto(side, e.name, e.count, e.slot) end
    local left = 0
    if made > 0 then
        local got = T.pull(side, outName, made)
        left = made - got
    end
    return left
end

-- Crafting with the table on: the stash, the rounds, the stash again, the putting back.  Returns the number made,
-- why it stopped, and how many are still in the chest.
local function workWith(bench, side, outName, rounds)
    local snap = {}
    for s = 1, 16 do
        local it = turtle.getItemDetail(s)
        if it then snap[#snap + 1] = { slot = s, name = it.name, count = it.count } end
    end
    local made, why = 0, nil
    local sel = turtle.getSelectedSlot()
    local ok, err = pcall(function()
        local stashed, stashWhy = stashAll(side)
        if not stashed then why = stashWhy; return end
        for _, r in ipairs(rounds) do
            local m, roundWhy = oneRound(bench, side, outName, r)
            made = made + m
            local again, againWhy = stashAll(side)
            if roundWhy then why = roundWhy; break end
            if not again then why = againWhy; break end
        end
    end)
    local left = unstash(side, snap, outName, made)
    turtle.select(sel)
    if not ok then error(err, 0) end
    return made, why, left
end

-- Craft with the chest on `side`: all of it but the walking.  See T.craft.
local function craftAt(side, name, n, cands, opts)
    local chest = peripheral.wrap(side)
    if not (chest and chest.list and chest.size and chest.pushItems) then
        return nil, "no container I can read on the " .. side
    end
    local stock = stockOf(side)
    local cand, cells, rounds, need, done = choose(cands, n, stock, opts.partial)
    if not cand then
        return nil, cells, rounds
    end
    local count = cand.row.count
    -- the crafting table: on a side already, in the turtle, or in the chest
    local equippedTable = T.equipped("left") == TABLE or T.equipped("right") == TABLE
    local inChest = T.countContainer(side, TABLE) or 0
    local pulled = false
    if not equippedTable and T.countItem(TABLE) == 0 and inChest == 0 then
        return nil, "no crafting table on the turtle or in the chest"
    end
    -- room in the chest for the whole inventory and the product (checked first, before anything moves)
    local used = 0
    for s = 1, 16 do
        if turtle.getItemCount(s) > 0 then used = used + 1 end
    end
    local free = chest.size()
    for _ in pairs(chest.list()) do free = free - 1 end
    local products = math.ceil(done * count / STACK)
    if free < used + products + 1 then
        return nil, "no room in the chest to work in: it needs " .. (used + products + 1) .. " free slots (the inventory " ..
            "is " .. used .. " stacks, the product " .. products .. ", and one spare), it has " .. free
    end
    if not equippedTable and T.countItem(TABLE) == 0 then
        local got, why = T.pull(side, TABLE, 1)
        if got < 1 then return nil, "couldn't take the crafting table out of the chest: " .. tostring(why) end
        pulled = true
    end
    local sel = turtle.getSelectedSlot()
    local ran, made, why, left = T.withPeripheral(TABLE, function(bench) return workWith(bench, side, name, rounds) end)
    if pulled then                                       -- the table goes back where it came from
        if T.selectItem(TABLE) then T.dropSide(side, 1) end
    end
    turtle.select(sel)
    if not ran then return nil, "couldn't put the crafting table on: " .. tostring(made) end
    if made > 0 then T.markCrafted(name) end
    if why then return false, why .. " (made " .. made .. " of " .. need * count .. ")", made end
    if left > 0 then
        return false, left .. " of the " .. made .. " are in the chest: no room for them in the turtle", made
    end
    if done < need then
        return false, "made " .. made .. ", short of the " .. need * count .. " asked: " ..
            shortText(shortOf(cand, cells, need, stock)), made
    end
    return true, made
end

-- Where a chest to work from is, other than at hand: opts.chest as { x, y, z, side } (side "up", "down" or a heading
-- 0 to 3, as T.setJunkChest takes it), else the junk chest.  Nil if there is none.
local function chestSpot(opts)
    if type(opts.chest) == "table" then return opts.chest end
    if opts.chest == nil then return T.junkChest() end
    return nil
end

-- Go to the cell p: up or down first, else along the ground first (a way in is not always a way out).
local function walkTo(p, opts)
    local ok, why = T.moveTo(p.x, p.y, p.z, opts.move)
    if ok then return true end
    local move = copyOf(opts.move or {})
    move.order = "xzy"
    if T.moveTo(p.x, p.y, p.z, move) then return true end
    return false, why
end

-- Go to the chest at `spot`, run fn(side) there and come back facing as before.
local function atSpot(spot, opts, fn)
    local from, dir = T.here(), T.dir
    local ok, why = walkTo(spot, opts)
    if not ok then
        walkTo(from, opts); T.face(dir)
        return nil, "can't get to the chest at " .. T.posKey(spot) .. ": " .. tostring(why)
    end
    local side = spot.side == "up" and "top" or spot.side == "down" and "bottom" or "front"
    if side == "front" then T.face(spot.side) end
    if not T.containerOn(side) then
        walkTo(from, opts); T.face(dir)
        return nil, "no chest at " .. T.posKey(spot) .. " (on its " .. side .. ")"
    end
    local a, b, c = fn(side)
    local back, backWhy = walkTo(from, opts)
    T.face(dir)
    if not back then return false, "crafted, but can't get back: " .. tostring(backWhy), c end
    return a, b, c
end

-- Craft n of an item from a chest (stash the inventory, fill the grid, craft, put it all back): true and how many, or
-- false/nil and why.
--
-- It works from a chest: the container in front, above or below, or opts.chest (a side, or { x, y, z, side } to walk
-- to), else the junk chest.  The chest needs room for the whole inventory; that is checked first, and so are the
-- ingredients (inventory plus chest) and a crafting table (on board, equipped or in the chest).  Then the table goes on
-- (a chunk controller stays on), everything is stashed in the chest, the grid is filled from it and crafted, round after
-- round, and the inventory comes back with the product.  n is rounded up to whole crafts.  opts: chest, partial (craft
-- what the ingredients allow), move (for T.moveTo).
--
-- Returns true, made; or false, why, made (it made some, or could not carry them); or nil, why (nothing was touched):
-- no recipe, short of an ingredient (the third value is the list from T.canCraft), no chest, no room in the chest, no
-- crafting table.  What it made is marked as crafted, so T.isJunk never says it is junk.
function T.craft(name, n, opts)
    opts = opts or {}
    if type(name) ~= "string" then return nil, "T.craft wants an item name, like minecraft:chest" end
    n = n == nil and 1 or n
    if not isCount(n) then return nil, "how many to make is a whole number of 1 or more" end
    name = full(name)
    local cands = candidatesFor(name)
    if #cands == 0 then return nil, "no recipe for " .. name .. " (T.addRecipe adds one)" end
    local side = chestSide(opts)
    if side then return craftAt(side, name, n, cands, opts) end
    local spot = chestSpot(opts)
    if not spot then
        return nil, "no chest to craft from: put one in front, above or below the turtle, or give opts.chest, or set a junk chest"
    end
    return atSpot(spot, opts, function(there) return craftAt(there, name, n, cands, opts) end)
end

--------------------------------------------------------------------------
-- Fuel and smelting
--------------------------------------------------------------------------

-- How many ticks a furnace burns the item for (20 a second; it smelts an item in 200), or nil if it is not a fuel.
--
-- Coal and charcoal 1600, a block of coal 16000, a lava bucket 20000, planks, logs and wooden things 300 or less. The
-- nether's woods (crimson and warped stems, planks and the rest) do not burn.  The table is T.FURNACE_FUEL.
function T.fuelTicks(name)
    return FURNACE_FUEL[full(name)]
end

-- What the item smelts into in a furnace, or nil if it does not smelt.
--
-- Ores and raw metals to ingots, cobblestone to stone, sand to glass, clay to bricks, logs to charcoal (not the nether's
-- stems), raw food to cooked.  The table is T.SMELTS.
function T.smeltsTo(name)
    return SMELTS[full(name)]
end

-- The fuel on board to smelt n items with when none is named: the first of FUEL_PREFER there is enough of, not the item.
local function chooseFuel(item, n)
    for _, spec in ipairs(FUEL_PREFER) do
        local test = matcher(spec)
        local have = {}
        for s = 1, 16 do
            local it = turtle.getItemDetail(s)
            if it and it.name ~= item and test(it.name) and FURNACE_FUEL[it.name] then
                have[it.name] = (have[it.name] or 0) + it.count
            end
        end
        for _, name in ipairs(tables.sortedKeys(have)) do
            if have[name] * FURNACE_FUEL[name] >= n * SMELT_TICKS then return name end
        end
    end
    return nil
end

-- Why an item does not burn, in words.
local function noFuelWhy(name)
    for _, wood in ipairs(STEM_WOODS) do
        if text.contains(name, wood) then return name .. " is nether wood, which does not burn in a furnace" end
    end
    return name .. " is not a furnace fuel (T.FURNACE_FUEL lists them)"
end

-- Smelt n of an item in a furnace the turtle carries, set up in front of it: true and how many came out, or false/nil and
-- why.
--
-- The furnace goes up in front of the turtle, one block above it, so the cell under it is free to stand in.  Five
-- cells must be free: the two over the turtle, the one in front of it, and the two over that (where the furnace stands
-- and above it); opts.move = { dig = true } lets it dig them (opts.move is for T.moveTo).  Fuel goes in from beside,
-- the item from above, and the results are sucked from below as they cook (ten seconds an item, at most 64 at a time);
-- then the furnace is taken back and the turtle comes home, facing as before.  fuel is an item name (default: charcoal, coal,
-- then planks or logs, whichever there is enough of).  What it makes is marked as crafted.
--
-- Returns true, got; false, why, got (it did not all come out in time); or nil, why (nothing started): not smeltable,
-- short of the item or the fuel, not a fuel, no furnace on board.
function T.smelt(item, n, fuel, opts)
    opts = opts or {}
    if type(item) ~= "string" then return nil, "T.smelt wants an item name, like minecraft:cobblestone" end
    item = full(item)
    n = n == nil and 1 or n
    if not (isCount(n) and n <= STACK) then return nil, "how many to smelt is a whole number from 1 to " .. STACK end
    local result = SMELTS[item]
    if not result then return nil, item .. " does not smelt into anything (T.SMELTS lists what does)" end
    if T.countItem(item) < n then return nil, "short of " .. item .. ": need " .. n .. ", have " .. T.countItem(item) end
    if T.countItem(FURNACE) < 1 then return nil, "no furnace on the turtle (T.craft makes one from 8 cobblestone)" end
    if fuel == nil then
        fuel = chooseFuel(item, n)
        if not fuel then return nil, "no fuel on the turtle to smelt " .. n .. " with (charcoal, coal, planks or logs)" end
    else
        fuel = full(fuel)
    end
    local ticks = FURNACE_FUEL[fuel]
    if not ticks then return nil, noFuelWhy(fuel) end
    local fuelCount = math.ceil(n * SMELT_TICKS / ticks)
    local haveFuel = T.countItem(fuel) - (fuel == item and n or 0)
    if haveFuel < fuelCount then
        return nil, "short of " .. fuel .. " to burn: " .. n .. " items need " .. fuelCount .. ", have " .. math.max(haveFuel, 0)
    end
    local start, heading = T.here(), T.dir
    local v = T.DELTA[heading]
    local stand = { x = start.x, y = start.y + 1, z = start.z }                           -- beside the furnace
    local furnace = { x = stand.x + v[1], y = stand.y, z = stand.z + v[3] }
    local over = { x = furnace.x, y = furnace.y + 1, z = furnace.z }                      -- above it, to drop the item
    local clear = { x = stand.x, y = stand.y + 1, z = stand.z }                           -- the way over to it
    local under = { x = furnace.x, y = furnace.y - 1, z = furnace.z }                     -- under it, to take the results
    local routes = {                                                                      -- from where the turtle is to under
        stand = { start, under }, over = { clear, stand, start, under }, under = {},
    }
    local where, placed = "start", false
    local function go(cell)
        return T.moveTo(cell.x, cell.y, cell.z, opts.move)
    end
    local function visit(cells)
        for _, cell in ipairs(cells) do
            local ok, why = go(cell)
            if not ok then return false, why end
        end
        return true
    end
    -- the furnace back and the turtle home; returns an extra sentence if something stayed behind
    local function cleanUp()
        local note = ""
        if placed then
            local ok, why = visit(routes[where] or {})
            if ok then
                ok, why = turtle.digUp()
            else                                          -- (the way under is shut: take it from the side)
                local side = T.moveTo(stand.x, stand.y, stand.z, { order = "xzy", dig = opts.move and opts.move.dig })
                if side then
                    T.face(heading)
                    ok, why = turtle.dig()
                end
            end
            if not ok then
                note = " (and the furnace is still up at " .. T.posKey(furnace) .. ": " .. tostring(why) .. ")"
            end
        end
        local home, homeWhy = go(start)
        T.face(heading)
        if not home then note = note .. " (and can't get home: " .. tostring(homeWhy) .. ")" end
        return note
    end
    local function dropAll(name, count, how)
        local before = T.countItem(name)
        T.selectItem(name)
        how(count)
        return before - T.countItem(name)
    end
    -- the steps, each returning nil and why when it cannot go on
    local function steps()
        local ok, why = go(stand)
        if not ok then return nil, "no room to set the furnace up: " .. tostring(why) end
        where = "stand"
        T.face(heading)
        T.selectItem(FURNACE)
        local put, putWhy = turtle.place()
        if not put then return nil, "couldn't put the furnace down in front: " .. tostring(putWhy) end
        placed = true
        local took = dropAll(fuel, fuelCount, turtle.drop)
        if took < fuelCount then return nil, "the furnace took only " .. took .. " of the " .. fuelCount .. " " .. fuel end
        ok, why = visit({ clear, over })
        if not ok then return nil, "can't get above the furnace: " .. tostring(why) end
        where = "over"
        took = dropAll(item, n, turtle.dropDown)
        if took < n then return nil, "the furnace took only " .. took .. " of the " .. n .. " " .. item end
        ok, why = visit(routes.over)
        if not ok then return nil, "can't get under the furnace: " .. tostring(why) end
        where = "under"
        return true
    end
    local ok, why = steps()
    local got, waited = 0, 0
    if ok then
        local limit = n * (SMELT_TICKS / 20) + 30
        while got < n and waited <= limit do
            local before = T.countItem(result)
            turtle.suckUp()
            got = got + T.countItem(result) - before
            if got >= n then break end
            sleep(5)
            waited = waited + 5
        end
    end
    local note = cleanUp()
    if got > 0 then T.markCrafted(result) end
    if not ok then return nil, tostring(why) .. note end
    if got < n then
        return false, "got " .. got .. " of " .. n .. " " .. result .. " in " .. waited .. " seconds (out of fuel, or the furnace was slow)" .. note, got
    end
    if note ~= "" then return false, "smelted " .. got .. " but" .. note, got end
    return true, got
end

return T
