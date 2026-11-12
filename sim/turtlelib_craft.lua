-- sim/turtlelib_craft.lua
--
-- tl.craft (ADR-0008 phase 4): recipes as data, T.craft, T.canCraft, the fuel and smelting tables, T.smelt, on
-- sim/lib/buildworld's mock world (a crafting grid behind the crafting table peripheral, chests, a furnace with its
-- faces and its ten seconds an item).
--   * stairs from blocks with the chunk controller kept on: the turtle's stuff stashed in the chest, the grid filled from it,
--     the inventory and the equipment back as they were, the product aboard and never junk;
--   * the families: every wood's and stone's forms from one entry (doors, slabs, walls, stairs, a mixed chest), rounds of
--     64 crafts; the table checked against the mock's own independent recipes;
--   * short materials reported before anything moves; room in the chest checked first; no table, no chest; the table
--     taken from the chest and put back; the table already on; a chest to walk to; a partial craft;
--   * T.addRecipe (checked, newest first, crafted); T.canCraft (inventory plus chest);
--   * the fuel and smelting tables against the mock's (nether woods do not burn), and T.smelt: a furnace set up in front
--     one up, fuel from beside, the item from above, the results from below, taken back, the turtle home; the refusals,
--     and a block in the way that makes it take the furnace back from the side.
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

local PICK, CONTROLLER = "minecraft:diamond_pickaxe", "advancedperipherals:chunk_controller"
local TABLE, FURNACE = "minecraft:crafting_table", "minecraft:furnace"
local W, T
local RIGHT_EQUIPS = 0
local CRAFT_SLOTS = {}                    -- the slot selected at each call of the crafting table's craft

-- The modules to load afresh.
local MODS = { "turtlelib", "tl.world", "tl.path", "tl.place", "tl.craft" }

-- A new world: stone underfoot, the pickaxe on the left and the chunk controller on the right, a chest in front
-- (0,0,1) unless `chest` is false; the library loaded afresh.
local function fresh(chest)
    W = B.new({ facing = "north" })
    W.install()
    EQ.left, EQ.right = PICK, CONTROLLER
    RIGHT_EQUIPS, CRAFT_SLOTS = 0, {}
    local rawWrap = peripheral.wrap
    peripheral.wrap = function(side)
        local p = rawWrap(side)
        if p and p.craft then
            local rawCraft = p.craft
            p.craft = function(...) CRAFT_SLOTS[#CRAFT_SLOTS + 1] = turtle.getSelectedSlot(); return rawCraft(...) end
        end
        return p
    end
    local rawRight = turtle.equipRight
    turtle.equipRight = function() RIGHT_EQUIPS = RIGHT_EQUIPS + 1; return rawRight() end
    for x = -3, 3 do for z = -3, 3 do W.set(x, -1, z, "minecraft:stone") end end
    if chest ~= false then W.set(0, 0, 1, "minecraft:chest") end
    for _, name in ipairs(MODS) do package.loaded[name] = nil end
    T = require("turtlelib")
    return W, T
end
-- What a chest holds: slot by slot.
local function fill(x, y, z, items)
    local inv = W.get(x, y, z).inv
    for slot, it in pairs(items) do inv[slot] = { name = it[1], count = it[2] } end
end
local function chestHas(name, x, y, z)
    local n = 0
    for _, it in pairs(W.get(x or 0, y or 0, z or 1).inv) do
        if it.name == name then n = n + it.count end
    end
    return n
end
local function chestStacks(x, y, z)
    local n = 0
    for _ in pairs(W.get(x or 0, y or 0, z or 1).inv) do n = n + 1 end
    return n
end
local function carrying(name) return W.carrying(name) end
-- The inventory as one line, to compare before and after.
local function inventory()
    local parts = {}
    for s = 1, 16 do
        local it = W.S.inv[s]
        if it then parts[#parts + 1] = s .. "=" .. it.count .. " " .. it.name end
    end
    return table.concat(parts, ", ")
end
local function chestLine(x, y, z)
    local parts = {}
    for s = 1, 27 do
        local it = W.get(x or 0, y or 0, z or 1).inv[s]
        if it then parts[#parts + 1] = s .. "=" .. it.count .. " " .. it.name end
    end
    return table.concat(parts, ", ")
end
local function here() return W.S.P.x == 0 and W.S.P.y == 0 and W.S.P.z == 0 and W.S.P.d == 0 and T.pos.x == 0 and T.pos.y == 0 and T.pos.z == 0 and T.dir == 0 end

--------------------------------------------------------------------------
-- Stairs from blocks, the controller kept on
--------------------------------------------------------------------------
do
    fresh()
    fill(0, 0, 1, { [1] = { "minecraft:stone_bricks", 20 }, [5] = { "minecraft:oak_planks", 10 }, [9] = { "minecraft:coal", 3 } })
    W.give(1, TABLE, 1)
    W.give(3, "minecraft:coal", 7)
    W.give(7, "minecraft:diamond", 2)
    W.give(16, "minecraft:bucket", 1)
    local before = inventory()
    local junkBefore = T.isJunk("minecraft:stone_brick_stairs")
    local ok, made = T.craft("minecraft:stone_brick_stairs", 8)
    check("stairs from blocks: 8 stairs, 12 bricks used", ok == true and made == 8 and carrying("minecraft:stone_brick_stairs") == 8
        and chestHas("minecraft:stone_bricks") == 8, tostring(ok) .. " " .. tostring(made) .. " / " .. inventory() .. " / " .. chestLine())
    check("...the game's own crafting made them (the mock's independent table)", W.crafted and W.crafted["minecraft:stone_brick_stairs"] == 8,
        tostring(W.crafted and W.crafted["minecraft:stone_brick_stairs"]))
    check("...the chunk controller never came off, the pickaxe is back on the left, the table back in its slot",
        RIGHT_EQUIPS == 0 and EQ.right == CONTROLLER and EQ.left == PICK and W.S.inv[1] and W.S.inv[1].name == TABLE, tostring(EQ.left) .. " " .. tostring(EQ.right))
    local after = {}
    for s = 1, 16 do
        local it = W.S.inv[s]
        if it and it.name ~= "minecraft:stone_brick_stairs" then after[#after + 1] = s .. "=" .. it.count .. " " .. it.name end
    end
    local want = {}
    for s = 1, 16 do
        local it = ({ [1] = { TABLE, 1 }, [3] = { "minecraft:coal", 7 }, [7] = { "minecraft:diamond", 2 }, [16] = { "minecraft:bucket", 1 } })[s]
        if it then want[#want + 1] = s .. "=" .. it[2] .. " " .. it[1] end
    end
    check("...everything else is in the slot it was in", table.concat(after, ", ") == table.concat(want, ", "), table.concat(after, ", ") .. " vs " .. before)
    check("...the chest's own stock is untouched (planks, coal)", chestHas("minecraft:oak_planks") == 10 and chestHas("minecraft:coal") == 3)
    check("...it stayed where it was, facing as before", here())
    check("...what it made is not junk any more (it was before)", junkBefore == true and T.isJunk("minecraft:stone_brick_stairs") == false)
    -- one craft makes 4: asking for 1 gives 4
    ok, made = T.craft("minecraft:stone_brick_stairs", 1)
    local allSixteen = #CRAFT_SLOTS > 0
    for _, slot in ipairs(CRAFT_SLOTS) do allSixteen = allSixteen and slot == 16 end
    check("...each craft is made with slot 16 selected: the product goes in from outside the grid", allSixteen, table.concat(CRAFT_SLOTS, ","))
    check("asking for 1 makes a whole craft (4)", ok == true and made == 4 and carrying("minecraft:stone_brick_stairs") == 12, tostring(made))
end

--------------------------------------------------------------------------
-- The families: one entry each, and rounds
--------------------------------------------------------------------------
do
    fresh()
    fill(0, 0, 1, { [1] = { "minecraft:birch_planks", 12 }, [2] = { "minecraft:polished_blackstone_bricks", 12 },
                    [3] = { "minecraft:stone_bricks", 12 }, [4] = { "minecraft:oak_planks", 5 }, [5] = { "minecraft:spruce_planks", 3 },
                    [6] = { "minecraft:cobblestone", 8 } })
    W.give(1, TABLE, 1)
    local ok, made = T.craft("minecraft:birch_door", 3)
    check("a wood's door from its planks (6 planks, 3 doors)", ok == true and made == 3 and carrying("minecraft:birch_door") == 3 and chestHas("minecraft:birch_planks") == 6,
        tostring(made) .. " / " .. inventory())
    ok, made = T.craft("minecraft:polished_blackstone_brick_stairs", 4)
    check("a stone's stairs from its block (castle blackstone)", ok == true and made == 4 and chestHas("minecraft:polished_blackstone_bricks") == 6, tostring(made))
    ok, made = T.craft("minecraft:stone_brick_wall", 6)
    check("a wall from stone bricks (6 bricks, 6 walls)", ok == true and made == 6 and chestHas("minecraft:stone_bricks") == 6, tostring(made))
    ok, made = T.craft("minecraft:birch_slab", 6)
    check("slabs: 3 planks make 6", ok == true and made == 6 and chestHas("minecraft:birch_planks") == 3, tostring(made))
    ok, made = T.craft("minecraft:furnace", 1)
    check("a furnace from cobblestone", ok == true and made == 1 and chestHas("minecraft:cobblestone") == 0, tostring(made))
    ok, made = T.craft("minecraft:jungle_slab", 6)
    check("no jungle planks: refused, short", ok == nil and made:find("short of jungle_planks: need 3, have 0", 1, true), tostring(made))
    ok, made = T.craft("minecraft:oak_slab", 12)
    check("...12 slabs is two crafts of 3 planks each: only 5 oak planks, short", ok == nil and made:find("short of oak_planks: need 6, have 5", 1, true), tostring(made))
end

do
    fresh()
    fill(0, 0, 1, { [1] = { "minecraft:oak_planks", 5 }, [2] = { "minecraft:spruce_planks", 3 }, [3] = { "minecraft:birch_planks", 2 } })
    W.give(1, TABLE, 1)
    local ok, made = T.craft("minecraft:chest", 1)
    check("a chest from mixed planks (5 oak, 3 spruce, 2 birch): 8 of them, any mix, the most plentiful first", ok == true and made == 1 and carrying("minecraft:chest") == 1
        and chestHas("minecraft:oak_planks") == 0 and chestHas("minecraft:spruce_planks") + chestHas("minecraft:birch_planks") == 2, tostring(made) .. " " .. chestLine())
    ok, made = T.craft("minecraft:crafting_table", 1)
    check("a crafting table from what is left (2 planks is not enough for 4)", ok == nil and made:find("short of", 1, true), tostring(made))
end

do
    fresh()
    -- 150 planks: 300 sticks is 75 crafts, 64 and then 11
    fill(0, 0, 1, { [1] = { "minecraft:oak_planks", 64 }, [2] = { "minecraft:oak_planks", 64 }, [3] = { "minecraft:oak_planks", 22 },
                    [4] = { "minecraft:coal", 9 } })
    W.give(1, TABLE, 1)
    local ok, made = T.craft("minecraft:stick", 300)
    check("300 sticks: two rounds (64 crafts and 11)", ok == true and made == 300 and carrying("minecraft:stick") == 300 and chestHas("minecraft:oak_planks") == 0,
        tostring(made) .. " / " .. inventory())
    ok, made = T.craft("minecraft:torch", 8)
    check("torches from coal and sticks on board (sticks came out of the chest again)", ok == true and made == 8 and carrying("minecraft:torch") == 8 and chestHas("minecraft:coal") == 7,
        tostring(made) .. " " .. chestLine())
    ok, made = T.craft("minecraft:stick", 8)
    check("...and nothing to make sticks of: refused", ok == nil and made:find("planks", 1, true) ~= nil, tostring(made))
end

--------------------------------------------------------------------------
-- Short, no room, no table, no chest
--------------------------------------------------------------------------
do
    fresh()
    fill(0, 0, 1, { [1] = { "minecraft:stone_bricks", 4 } })
    W.give(1, TABLE, 1)
    W.give(2, "minecraft:stone_bricks", 1)
    local inv, chestBefore = inventory(), chestLine()
    local ok, why, short = T.craft("minecraft:stone_brick_stairs", 4)
    check("short: refused with what is short (6 needed, 5 on board and in the chest)", ok == nil and why == "short of stone_bricks: need 6, have 5"
        and short and short[1].item == "stone_bricks" and short[1].short == 1, tostring(why))
    check("...and nothing was touched", inventory() == inv and chestLine() == chestBefore and EQ.left == PICK and here())
    local can, cwhy, clist = T.canCraft("minecraft:stone_brick_stairs", 4)
    check("canCraft says the same: false, the sentence, the list", can == false and cwhy == "short of stone_bricks: need 6, have 5" and clist[1].need == 6 and clist[1].have == 5,
        tostring(cwhy))
    W.give(3, "minecraft:stone_bricks", 1)
    local can2, info = T.canCraft("minecraft:stone_brick_stairs", 4)
    check("canCraft counts the inventory and the chest together", can2 == true and info.crafts == 1 and info.makes == 4)
    check("canCraft: no recipe, a bad count", T.canCraft("minecraft:dirt", 1) == false and select(2, T.canCraft("minecraft:dirt", 1)):find("no recipe", 1, true)
        and T.canCraft("minecraft:chest", 0) == false)
    -- partial
    local ok2, made2
    fill(0, 0, 1, { [1] = { "minecraft:stone_bricks", 8 } })
    ok2, why, made2 = T.craft("minecraft:stone_brick_stairs", 8, { partial = true })
    check("partial: crafts what it can (one craft of two), and says it was short", ok2 == false and made2 == 4 and why:find("short of", 1, true) ~= nil
        and carrying("minecraft:stone_brick_stairs") == 4, tostring(ok2) .. " " .. tostring(why) .. " " .. tostring(made2))
end

do
    fresh()
    local items = {}
    for s = 1, 27 do items[s] = { "minecraft:item_" .. s, 1 } end
    items[27] = nil
    items[26] = { "minecraft:stone_bricks", 12 }
    fill(0, 0, 1, items)
    W.give(1, TABLE, 1)
    for s = 2, 6 do W.give(s, "minecraft:coal", 5) end
    local inv, chestBefore = inventory(), chestLine()
    local ok, why = T.craft("minecraft:stone_brick_stairs", 4)
    check("a nearly full chest: refused before anything moves (6 stacks and the product need free slots, 1 is free)",
        ok == nil and why:find("no room in the chest", 1, true) and inventory() == inv and chestLine() == chestBefore and EQ.left == PICK, tostring(why))
end

do
    fresh()
    fill(0, 0, 1, { [1] = { "minecraft:stone_bricks", 12 } })
    local ok, why = T.craft("minecraft:stone_brick_stairs", 4)
    check("no crafting table anywhere: refused", ok == nil and why:find("no crafting table", 1, true), tostring(why))
    -- the table in the chest: taken, used, put back
    fill(0, 0, 1, { [2] = { TABLE, 1 } })
    W.give(5, "minecraft:coal", 4)
    ok, why = T.craft("minecraft:stone_brick_stairs", 4)
    check("the table in the chest: pulled, used and put back; the pickaxe still on", ok == true and carrying("minecraft:stone_brick_stairs") == 4 and carrying(TABLE) == 0
        and chestHas(TABLE) == 1 and EQ.left == PICK and EQ.right == CONTROLLER and carrying("minecraft:coal") == 4 and RIGHT_EQUIPS == 0,
        tostring(why) .. " / " .. inventory() .. " / " .. chestLine())
    -- the table already on the left (the pickaxe in the inventory)
    fresh()
    fill(0, 0, 1, { [1] = { "minecraft:stone_bricks", 12 } })
    EQ.left = TABLE
    W.give(4, PICK, 1)
    ok, why = T.craft("minecraft:stone_brick_stairs", 4)
    check("the table already on: used, and still on after; the pickaxe stays in its slot", ok == true and EQ.left == TABLE and W.S.inv[4] and W.S.inv[4].name == PICK
        and carrying("minecraft:stone_brick_stairs") == 4, tostring(why) .. " / " .. inventory())
    -- no chest
    fresh(false)
    W.give(1, TABLE, 1)
    ok, why = T.craft("minecraft:stone_brick_stairs", 4)
    check("no chest: refused, saying what to do", ok == nil and why:find("no chest", 1, true), tostring(why))
    -- a chest below
    fresh(false)
    W.set(0, -1, 0, "minecraft:chest")
    fill(0, -1, 0, { [1] = { "minecraft:stone_bricks", 12 } })
    W.give(1, TABLE, 1)
    ok, why = T.craft("minecraft:stone_brick_stairs", 4)
    check("a chest below the turtle works as well as one in front", ok == true and carrying("minecraft:stone_brick_stairs") == 4 and chestHas("minecraft:stone_bricks", 0, -1, 0) == 6,
        tostring(why))
    -- a chest to walk to (opts.chest as a cell and a side), and the junk chest as the default
    fresh(false)
    W.set(2, 0, 0, "minecraft:chest")
    fill(2, 0, 0, { [1] = { "minecraft:stone_bricks", 12 } })
    W.give(1, TABLE, 1)
    ok, why = T.craft("minecraft:stone_brick_stairs", 4, { chest = { x = 2, y = 1, z = 0, side = "down" } })
    check("a chest to walk to: crafted there, and back at the start facing as before", ok == true and carrying("minecraft:stone_brick_stairs") == 4 and here(),
        tostring(why) .. " " .. W.S.P.x .. "," .. W.S.P.y .. "," .. W.S.P.z)
    check("...the junk chest is the default one", (function()
        fresh(false)
        W.set(2, 0, 0, "minecraft:chest")
        fill(2, 0, 0, { [1] = { "minecraft:stone_bricks", 12 } })
        W.give(1, TABLE, 1)
        T.setJunkChest(2, 1, 0, "down")
        local good, w = T.craft("minecraft:stone_brick_stairs", 4)
        return good == true and carrying("minecraft:stone_brick_stairs") == 4 and here() and w == 4
    end)())
    fresh(false)
    W.give(1, TABLE, 1)
    ok, why = T.craft("minecraft:stone_brick_stairs", 4, { chest = { x = 2, y = 1, z = 0, side = "down" } })
    check("a spot with no chest: refused, and back home", ok == nil and why:find("no chest at", 1, true) and here(), tostring(why))
end

--------------------------------------------------------------------------
-- T.addRecipe, T.recipe, T.canCraft's inputs
--------------------------------------------------------------------------
do
    fresh()
    fill(0, 0, 1, { [1] = { "minecraft:iron_ingot", 6 }, [2] = { "minecraft:birch_planks", 4 } })
    W.give(1, TABLE, 1)
    local bad = {
        { "not a table", "a table" }, { {}, "needs out" }, { { out = "a:b", shape = {} }, "shape" },
        { { out = "a:b", shape = { "ABCD" }, key = {} }, "wide" }, { { out = "a:b", shape = { "A" }, key = {} }, "does not say what" },
        { { out = "a:b", shape = { ".." }, key = {} }, "no ingredient" }, { { out = "a:b", count = 0, shape = { "A" }, key = { A = "x" } }, "count" },
        { { out = "a:{}", shape = { "A" }, of = "A", map = {}, from = { "x" } }, "from" },
        { { out = "a:b", shape = { "A" }, of = "B", from = { "x" } }, "letter" },
    }
    local allBad = true
    local detail
    for _, b in ipairs(bad) do
        local ok, why = T.addRecipe(b[1])
        if ok or not why:find(b[2], 1, true) then allBad = false; detail = tostring(b[2]) .. ": " .. tostring(why) end
    end
    check("addRecipe: a spec that is not a recipe is refused, saying why", allBad, detail)
    -- the mock's table learns the same widget, written independently
    table.insert(B.RECIPES, 1, { name = "widget", shape = { "AA", "B." },
        key = { A = function(n) return n == "iron_ingot" end, B = function(n) return n:sub(-7) == "_planks" end }, mixed = false,
        out = function() return "mod:widget", 2 end })
    local ok = T.addRecipe { out = "mod:widget", count = 2, shape = { "AA", "B." }, key = { A = "minecraft:iron_ingot", B = "*_planks" } }
    check("addRecipe: a new recipe is taken", ok == true)
    local r = T.recipe("mod:widget")
    check("T.recipe reads it back (the shape, the key, the count)", r and r.count == 2 and r.shape[1] == "AA" and r.key.A == "minecraft:iron_ingot" and r.key.B == "*_planks" and r.out == "mod:widget",
        r and tostring(r.key.B))
    local good, made = T.craft("mod:widget", 4)
    check("...and crafted: a glob letter takes the planks that are there", good == true and made == 4 and carrying("mod:widget") == 4 and chestHas("minecraft:iron_ingot") == 2
        and chestHas("minecraft:birch_planks") == 2, tostring(made) .. " " .. chestLine())
    -- a letter that is not mixed is one item all through: one oak and one birch plank are not a pair
    table.insert(B.RECIPES, 1, { name = "pair", shape = { "AA" }, key = { A = function(n) return n:sub(-7) == "_planks" end }, mixed = false,
        out = function() return "mod:pair", 1 end })
    fresh()
    T.addRecipe { out = "mod:pair", shape = { "AA" }, key = { A = "*_planks" } }
    fill(0, 0, 1, { [1] = { "minecraft:oak_planks", 1 }, [2] = { "minecraft:birch_planks", 1 } })
    W.give(1, TABLE, 1)
    local pairOk, pairWhy, pairShort = T.craft("mod:pair", 1)
    check("a letter that is not mixed is one item: one oak and one birch plank are short for a pair, reported as such",
        pairOk == nil and pairWhy == "short of *_planks: need 2, have 1" and pairShort[1].have == 1, tostring(pairWhy))
    fill(0, 0, 1, { [3] = { "minecraft:oak_planks", 2 } })
    pairOk, pairWhy = T.craft("mod:pair", 1)
    check("...with 3 oak planks (and the birch) a pair is made of the oak", pairOk == true and carrying("mod:pair") == 1 and chestHas("minecraft:oak_planks") == 1
        and chestHas("minecraft:birch_planks") == 1, tostring(pairWhy) .. " " .. chestLine())
    -- the newest recipe is tried first
    T.addRecipe { out = "minecraft:stick", count = 1, shape = { "P" }, key = { P = "minecraft:coal" } }
    local stick = T.recipe("minecraft:stick")
    check("the newest recipe for an item is the first", stick.shape[1] == "P" and stick.key.P == "minecraft:coal")
    check("an item with no recipe: nil and why", select(2, T.recipe("minecraft:dirt")):find("no recipe", 1, true) ~= nil)
    -- every built-in row passes the check that addRecipe makes (they are written as a person would add them)
    fresh()
    T.recipe("minecraft:chest")
    local rows = T.RECIPES
    local copies, bads = {}, {}
    for i, row in ipairs(rows) do
        local spec = { out = row.out, count = row.count, shape = row.shape, key = row.key, mixed = row.mixed, of = row.of, from = row.from, map = row.map }
        copies[i] = spec
    end
    for i, spec in ipairs(copies) do
        local good2, why = T.addRecipe(spec)
        if not good2 then bads[#bads + 1] = i .. ": " .. tostring(why) end
    end
    check("every built-in recipe is a valid spec", #bads == 0 and #rows == 2 * #copies, table.concat(bads, "; "))
end

--------------------------------------------------------------------------
-- The table against the mock's independent recipes
--------------------------------------------------------------------------
do
    fresh()
    local REP = { ["*_planks"] = "minecraft:oak_planks" }
    local function itemFor(spec)
        if type(spec) == "table" then return spec[1] end
        return REP[spec] or spec
    end
    local outs = {
        "minecraft:oak_planks", "minecraft:crimson_planks", "minecraft:stick", "minecraft:torch", "minecraft:chest", "minecraft:crafting_table", "minecraft:furnace",
        "minecraft:oak_stairs", "minecraft:stone_brick_stairs", "minecraft:polished_blackstone_brick_stairs", "minecraft:cobblestone_stairs",
        "minecraft:oak_slab", "minecraft:stone_brick_slab", "minecraft:sandstone_slab", "minecraft:stone_brick_wall", "minecraft:cobblestone_wall",
        "minecraft:oak_door", "minecraft:dark_oak_door", "minecraft:birch_trapdoor", "minecraft:ladder", "minecraft:oak_fence_gate", "minecraft:oak_fence",
        "minecraft:stone_bricks", "minecraft:iron_bars", "minecraft:glass_pane", "minecraft:bucket", "minecraft:chain",
        "minecraft:cobbled_deepslate_wall", "minecraft:mud_brick_slab", "minecraft:bamboo_door",
    }
    local compared, wrong, notKnown = 0, {}, {}
    for _, out in ipairs(outs) do
        local r = T.recipe(out)
        if not r then
            wrong[#wrong + 1] = out .. ": no recipe"
        else
            local grid = { {}, {}, {} }
            for rr, line in ipairs(r.shape) do
                for c = 1, #line do
                    local ch = line:sub(c, c)
                    if ch ~= "." then grid[rr][c] = itemFor(r.key[ch]) end
                end
            end
            local name, count = B.recipeFor(grid)
            if not name then
                notKnown[#notKnown + 1] = out
            else
                compared = compared + 1
                if name ~= out or count ~= r.count then wrong[#wrong + 1] = out .. " is " .. tostring(name) .. " x" .. tostring(count) .. " in the game, " .. r.count .. " here" end
            end
        end
    end
    check("the recipe table agrees with the game's rules (the mock's own table) on name and count for every one it knows", #wrong == 0 and compared >= 23,
        table.concat(wrong, "; ") .. " (compared " .. compared .. ", unknown to the mock: " .. table.concat(notKnown, " ") .. ")")
    -- a block with no stairs, a family built from a name nobody listed
    check("an item with no stairs has no stair recipe (dirt, iron blocks)", T.recipe("minecraft:dirt_stairs") == nil and T.recipe("minecraft:iron_block_stairs") == nil)
    check("a stone's chiseled and brick forms come from their parts", T.recipe("minecraft:chiseled_stone_bricks").key.X == "minecraft:stone_brick_slab"
        and T.recipe("minecraft:stone_bricks").key.X == "minecraft:stone" and T.recipe("minecraft:bricks").key.X == "minecraft:brick")
    check("planks from any log (stripped, wood, or the nether's stems); the stairs' stem for bricks and quartz",
        T.recipe("minecraft:warped_planks").key.L == "minecraft:warped_stem" and T.recipe("minecraft:quartz_stairs").key.X == "minecraft:quartz_block"
        and T.recipe("minecraft:nether_brick_stairs").key.X == "minecraft:nether_bricks" and T.recipe("minecraft:brick_stairs").key.X == "minecraft:bricks"
        and T.recipe("minecraft:deepslate_tile_wall").key.X == "minecraft:deepslate_tiles")
    -- blueprint's materials check asks canCraft(item, missing) and keeps its first result
    fresh()
    fill(0, 0, 1, { [1] = { "minecraft:stone_bricks", 12 } })
    check("T.canCraft(item, n) first result is true when it can be made (what tl.blueprint keeps)", (T.canCraft("minecraft:stone_brick_stairs", 3)) == true)
end

--------------------------------------------------------------------------
-- Fuel and smelting: the tables against the mock's
--------------------------------------------------------------------------
do
    fresh()
    local wrong, n = {}, 0
    local names = {}
    for name in pairs(B.FUEL_TICKS) do names[#names + 1] = name end
    for _, w in ipairs({ "oak", "spruce", "birch", "jungle", "acacia", "dark_oak", "mangrove", "cherry", "crimson", "warped" }) do
        for _, form in ipairs({ "_planks", "_log", "_wood", "_stem", "_hyphae", "stripped_" .. w .. "_log" }) do
            names[#names + 1] = form:sub(1, 1) == "s" and form or (w .. form)
        end
    end
    table.sort(names)
    for _, name in ipairs(names) do
        n = n + 1
        local mine, theirs = T.fuelTicks("minecraft:" .. name), B.fuelTicks(name)
        if mine ~= theirs then
            -- (the mock treats every _log and _wood as wood and has no stems: only the nether prefixes matter)
            if not (theirs == nil and (name:sub(-5) == "_stem" or name:sub(-7) == "_hyphae") and mine == nil) then
                wrong[#wrong + 1] = name .. " " .. tostring(mine) .. " vs " .. tostring(theirs)
            end
        end
    end
    check("what burns and for how long agrees with the game's (the mock's table), nether woods do not", #wrong == 0 and n > 40, table.concat(wrong, "; "))
    check("coal 1600, a block of coal 16000, lava 20000, planks 300; crimson planks, warped stems and stone: nothing",
        T.fuelTicks("minecraft:coal") == 1600 and T.fuelTicks("coal_block") == 16000 and T.fuelTicks("minecraft:lava_bucket") == 20000
        and T.fuelTicks("minecraft:oak_planks") == 300 and T.fuelTicks("minecraft:crimson_planks") == nil and T.fuelTicks("minecraft:warped_stem") == nil
        and T.fuelTicks("minecraft:stone") == nil and T.fuelTicks("minecraft:crimson_stairs") == nil)
    check("wooden things by what the game gives: slabs 150, doors 200, signs 200, buttons 100, boats 1200, saplings 100, a stick 100, nether fences nothing",
        T.fuelTicks("minecraft:oak_slab") == 150 and T.fuelTicks("minecraft:birch_door") == 200 and T.fuelTicks("minecraft:oak_sign") == 200
        and T.fuelTicks("minecraft:oak_button") == 100 and T.fuelTicks("minecraft:oak_boat") == 1200 and T.fuelTicks("minecraft:oak_sapling") == 100
        and T.fuelTicks("minecraft:stick") == 100 and T.fuelTicks("minecraft:warped_fence") == nil and T.fuelTicks("minecraft:bamboo_planks") == 300)
    local sw = {}
    for name, result in pairs(B.SMELTS) do
        if T.smeltsTo("minecraft:" .. name) ~= "minecraft:" .. result then sw[#sw + 1] = name end
    end
    check("what smelts into what agrees with the game's (the mock's table)", #sw == 0, table.concat(sw, " "))
    check("logs give charcoal, the nether's stems nothing; a log a mod made, nothing", T.smeltsTo("minecraft:oak_log") == "minecraft:charcoal" and T.smeltsTo("minecraft:crimson_stem") == nil
        and T.smeltsTo("minecraft:diamond") == nil and T.smeltsTo("some:log") == nil and T.smeltsTo("minecraft:raw_iron") == "minecraft:iron_ingot")
end

--------------------------------------------------------------------------
-- T.smelt
--------------------------------------------------------------------------
do
    fresh(false)
    W.give(1, FURNACE, 1)
    W.give(2, "minecraft:cobblestone", 5)
    W.give(3, "minecraft:coal", 4)
    local ok, got = T.smelt("minecraft:cobblestone", 5, "minecraft:coal")
    check("smelt 5 cobblestone with coal: 5 stone back, taken a furnace's time (50 s)", ok == true and got == 5 and carrying("minecraft:stone") == 5 and carrying("minecraft:cobblestone") == 0
        and W.time >= 50, tostring(got) .. " " .. tostring(ok) .. " t=" .. W.time .. " / " .. inventory())
    check("...one coal burnt, the furnace taken back (nothing left standing), the turtle home", carrying("minecraft:coal") == 3 and carrying(FURNACE) == 1 and W.get(0, 1, 1) == nil
        and here(), inventory())
    check("...and the stone it made is not junk", T.isJunk("minecraft:stone") == false)

    -- default fuel, logs to charcoal with planks
    fresh(false)
    W.give(1, FURNACE, 1)
    W.give(2, "minecraft:oak_log", 2)
    W.give(3, "minecraft:oak_planks", 5)
    ok, got = T.smelt("minecraft:oak_log", 2, "minecraft:oak_planks")
    check("2 logs to charcoal burning planks (2 planks for 400 ticks)", ok == true and got == 2 and carrying("minecraft:charcoal") == 2 and carrying("minecraft:oak_planks") == 3
        and carrying("minecraft:oak_log") == 0, inventory())
    fresh(false)
    W.give(1, FURNACE, 1)
    W.give(2, "minecraft:raw_iron", 3)
    W.give(3, "minecraft:stick", 9)
    W.give(4, "minecraft:charcoal", 1)
    ok, got = T.smelt("minecraft:raw_iron", 3)
    check("no fuel named: charcoal is chosen first", ok == true and carrying("minecraft:iron_ingot") == 3 and carrying("minecraft:charcoal") == 0 and carrying("minecraft:stick") == 9,
        inventory())

    -- refusals
    fresh(false)
    W.give(2, "minecraft:cobblestone", 5)
    W.give(3, "minecraft:coal", 4)
    local why
    ok, why = T.smelt("minecraft:cobblestone", 5, "minecraft:coal")
    check("no furnace on board: refused", ok == nil and why:find("no furnace", 1, true), tostring(why))
    W.give(1, FURNACE, 1)
    ok, why = T.smelt("minecraft:dirt", 1, "minecraft:coal")
    check("an item that does not smelt: refused", ok == nil and why:find("does not smelt", 1, true), tostring(why))
    ok, why = T.smelt("minecraft:cobblestone", 6, "minecraft:coal")
    check("short of the item: refused", ok == nil and why:find("short of minecraft:cobblestone: need 6, have 5", 1, true), tostring(why))
    W.give(4, "minecraft:crimson_planks", 9)
    ok, why = T.smelt("minecraft:cobblestone", 5, "minecraft:crimson_planks")
    check("nether planks as fuel: refused, saying they do not burn", ok == nil and why:find("nether wood", 1, true), tostring(why))
    ok, why = T.smelt("minecraft:cobblestone", 5, "minecraft:stone")
    check("a fuel that is no fuel: refused", ok == nil and why:find("not a furnace fuel", 1, true), tostring(why))
    ok, why = T.smelt("minecraft:cobblestone", 5, "minecraft:stick")
    check("short of the fuel: refused (sticks: 10 needed, none)", ok == nil and why:find("short of minecraft:stick to burn", 1, true), tostring(why))
    ok, why = T.smelt("minecraft:cobblestone", 65, "minecraft:coal")
    check("more than a stack: refused", ok == nil and why:find("1 to 64", 1, true), tostring(why))
    check("...none of that touched the inventory or the world", carrying("minecraft:cobblestone") == 5 and carrying("minecraft:coal") == 4 and carrying(FURNACE) == 1 and here())
    W.give(3, nil)
    ok, why = T.smelt("minecraft:cobblestone", 5)
    check("no fuel named and none on board that burns (crimson planks do not): refused", ok == nil and why:find("no fuel on the turtle", 1, true), tostring(why))
end

do
    -- a block over the turtle: no room to set it up
    fresh(false)
    W.give(1, FURNACE, 1); W.give(2, "minecraft:cobblestone", 2); W.give(3, "minecraft:coal", 2)
    W.set(0, 1, 0, "minecraft:stone")
    local ok, why = T.smelt("minecraft:cobblestone", 2, "minecraft:coal")
    check("a block over the turtle: no room, nothing placed, home", ok == nil and why:find("no room to set the furnace up", 1, true) and carrying(FURNACE) == 1 and here(), tostring(why))
    -- a block where the furnace goes
    fresh(false)
    W.give(1, FURNACE, 1); W.give(2, "minecraft:cobblestone", 2); W.give(3, "minecraft:coal", 2)
    W.set(0, 1, 1, "minecraft:stone")
    ok, why = T.smelt("minecraft:cobblestone", 2, "minecraft:coal")
    check("a block where the furnace would stand: refused, the turtle back where it began", ok == nil and why:find("couldn't put the furnace down", 1, true) and carrying(FURNACE) == 1 and here(), tostring(why))
    -- a block in the cell under the furnace: the furnace is taken back from the side, with what was put in it
    fresh(false)
    W.give(1, FURNACE, 1); W.give(2, "minecraft:cobblestone", 5); W.give(3, "minecraft:coal", 4)
    W.set(0, 0, 1, "minecraft:stone")
    ok, why = T.smelt("minecraft:cobblestone", 5, "minecraft:coal")
    check("a block under where the furnace stands: cannot get under, says so", ok == nil and why:find("can't get under the furnace", 1, true), tostring(why))
    check("...the furnace is taken back from the side with the item and fuel in it, the turtle home",
        carrying(FURNACE) == 1 and carrying("minecraft:cobblestone") == 5 and carrying("minecraft:coal") == 4 and W.get(0, 1, 1) == nil and here(), inventory())
    -- a block over where the furnace goes: cannot get above
    fresh(false)
    W.give(1, FURNACE, 1); W.give(2, "minecraft:cobblestone", 5); W.give(3, "minecraft:coal", 4)
    W.set(0, 2, 1, "minecraft:stone")
    ok, why = T.smelt("minecraft:cobblestone", 5, "minecraft:coal")
    check("a block over the furnace: cannot get above it, the fuel in the furnace comes back with it", ok == nil and why:find("can't get above the furnace", 1, true)
        and carrying(FURNACE) == 1 and carrying("minecraft:coal") == 4 and carrying("minecraft:cobblestone") == 5 and W.get(0, 1, 1) == nil and here(), tostring(why) .. " / " .. inventory())
    -- allowed to dig the way
    fresh(false)
    W.give(1, FURNACE, 1); W.give(2, "minecraft:cobblestone", 2); W.give(3, "minecraft:coal", 2)
    W.set(0, 0, 1, "minecraft:stone")
    ok, why = T.smelt("minecraft:cobblestone", 2, "minecraft:coal", { move = { dig = true } })
    check("with opts.move.dig it digs the block under and carries on (2 stone smelted and the one dug)", ok == true and carrying("minecraft:stone") == 3 and W.get(0, 0, 1) == nil
        and here(), tostring(why) .. " " .. inventory())
    -- an item the furnace takes but never cooks (the mock's table lacks raw beef): it waits its time, then gives up, with everything back
    fresh(false)
    W.give(1, FURNACE, 1); W.give(2, "minecraft:beef", 1); W.give(3, "minecraft:coal", 2)
    local t0 = W.time
    local partial
    ok, why, partial = T.smelt("minecraft:beef", 1, "minecraft:coal")
    check("nothing cooks in time: it waits (10 s an item and 30 over), says how many came out, and takes the furnace back with the beef", ok == false and partial == 0
        and why:find("got 0 of 1", 1, true) and W.time - t0 >= 40 and W.time - t0 <= 50 and carrying("minecraft:beef") == 1 and carrying(FURNACE) == 1 and W.get(0, 1, 1) == nil and here(),
        tostring(why) .. " t=" .. (W.time - t0) .. " " .. inventory())
    -- facing another way: the furnace goes up in front of where it faces
    fresh(false)
    W.give(1, FURNACE, 1); W.give(2, "minecraft:sand", 3); W.give(3, "minecraft:coal", 2)
    T.turnRight()
    ok, why = T.smelt("minecraft:sand", 3, "minecraft:coal")
    check("facing east: the furnace is set up that way, glass out, the turtle faces east again", ok == true and carrying("minecraft:glass") == 3 and T.dir == 1 and W.S.P.d == 1
        and W.S.P.x == 0 and W.S.P.z == 0 and W.get(1, 1, 0) == nil, tostring(why) .. " / " .. inventory())
end

--------------------------------------------------------------------------
-- Planks from any of a wood's logs; a product that stacks to one; a smelt from stacks split over slots
--------------------------------------------------------------------------
do
    for _, log in ipairs({ "minecraft:stripped_oak_log", "minecraft:oak_wood" }) do
        fresh()
        fill(0, 0, 1, { [1] = { log, 2 } })
        W.give(1, TABLE, 1)
        local ok, made = T.craft("minecraft:oak_planks", 8)
        check("oak planks from " .. log .. ", as the game takes them", ok == true and made == 8 and carrying("minecraft:oak_planks") == 8, tostring(made))
    end
    fresh()
    W.give(2, "minecraft:crimson_hyphae", 1)
    check("...and crimson planks from crimson hyphae", T.canCraft("minecraft:crimson_planks", 1) == true,
        tostring(select(2, T.canCraft("minecraft:crimson_planks", 1))))

    fresh()
    fill(0, 0, 1, { [1] = { "minecraft:oak_planks", 64 }, [2] = { "minecraft:oak_planks", 36 } })
    W.give(1, TABLE, 1)
    SPILLED = 0
    local limits = {}
    local rawWrap = peripheral.wrap
    peripheral.wrap = function(side)
        local p = rawWrap(side)
        if p and p.craft then
            local rawCraft = p.craft
            p.craft = function(n) limits[#limits + 1] = n; return rawCraft(n) end
        end
        return p
    end
    local ok, why, made = T.craft("minecraft:oak_boat", 20)
    if ok == true then made = why end
    peripheral.wrap = rawWrap
    local most = 0
    for _, n in ipairs(limits) do most = math.max(most, n) end
    check("boats stack to one: the crafts go in rounds the free slots hold, nothing spills (the rest wait in the chest)", made == 20 and SPILLED == 0 and most <= 10,
        tostring(ok) .. " " .. tostring(made) .. ", rounds " .. table.concat(limits, ",") .. ", spilled " .. tostring(SPILLED))
    check("a bowl burns 100 ticks and a dried kelp block 4001, as vanilla's fuel list says",
        T.fuelTicks("minecraft:bowl") == 100 and T.fuelTicks("minecraft:dried_kelp_block") == 4001)

    fresh(false)
    W.give(1, FURNACE, 1)
    W.give(2, "minecraft:cobblestone", 5); W.give(4, "minecraft:cobblestone", 15)
    W.give(3, "minecraft:coal", 1); W.give(5, "minecraft:coal", 9)
    ok, made = T.smelt("minecraft:cobblestone", 20, "minecraft:coal")
    check("a smelt takes the item and the fuel from every slot they are in", ok == true and made == 20 and carrying("minecraft:stone") == 20,
        tostring(ok) .. " " .. tostring(made) .. " / " .. inventory())
end
