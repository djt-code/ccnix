-- sim/lib/buildworld.lua -- a world of blocks WITH STATES, and the game's rules for placing
-- them, for the simulators of the building library (ADR-0008, tl.place and what is built on it)
--
--     local B = require("buildworld")
--     local w = B.new({ facing = "north" })     -- (the compass way the turtle's heading 0 points)
--     w.install()                               -- turtle, peripheral, fs, sleep, ... as globals
--     w.set(0, -1, 0, "minecraft:stone")        -- blocks: name, then a state table if it has one
--     w.give(1, "minecraft:oak_stairs", 8)      -- the turtle's inventory
--     turtle.placeDown()                        -- the stair lands as the game would place it
--     w.state(0, 0, 0)                          -- { facing = "north", half = "top", shape = "straight", ... }
--
-- What it models
--   * Blocks with states.  w.get(x, y, z) is nil (air) or { name, state, inv?, ... }.  turtle.inspect*
--     gives name and state as CC does (booleans as booleans, the rest strings).
--   * turtle.place* as CC:Tweaked 1.120.2 runs it (TurtlePlaceCommand.deploy, read from the source, see
--     "The order" below), and Minecraft's own rules for each family of block (stairs, slabs, logs and
--     pillars, torches, ladders, buttons and levers, doors, trapdoors, fence gates, chests and furnaces;
--     everything else is a plain full block).  The rules are DATA, in FAMILIES below.
--   * Items carry the block they place (the item's name is the block's; a water or lava bucket places its
--     liquid).  A cell that is not replaceable refuses.
--   * Digging: the drops go to the turtle; what hung on a dug block pops off.
--   * A crafting grid and the workbench peripheral (the recipes in RECIPES, an independent table so that
--     the library's own can be checked against it), chests, and a furnace (fuel through the sides and the
--     underside, items through the top, the result out of the underside, ten seconds an item, w.sleep(t)
--     passes the time).  Seams for more: add rows to RECIPES, SMELTS, FUEL_TICKS and FAMILIES.
--
-- The frame.  Like the other mock worlds, the turtle's own: it starts at (0,0,0), heading 0 is +z and a
-- right turn goes to +x.  A state's facing is a compass name, so the world needs to know which way heading
-- 0 points: opts.facing (default "north"; "east" and the rest turn the compass round).  Only the cyclic
-- order (a right turn is north to east to south to west) and opposites matter, so the frame being a
-- mirror of Minecraft's changes nothing.  Left and right are always the placer's.
--
-- The order a turtle places in (CC:Tweaked 1.120.2, TurtlePlaceCommand.deploy and TurtlePlayer.setPosition;
-- the ADR's "tl.place" section has the summary).  Each attempt puts the fake player in the cell
-- beside the block it clicks, facing it; the first that places something wins:
--   0. an entity in the target cell, if it takes the item (an item frame): the item is used on it;
--   1. the TARGET cell itself, clicked on the face toward the turtle ("adjacent"): only a block that is
--      not air and, for a block item, not a liquid; it may be replaceable (tall grass, snow, a half slab
--      of the same kind): the new block replaces it;
--   2. the block BEYOND the target, clicked on its near face (the cell it places into is the target);
--      not air, not a liquid, and NOT replaceable;
--   3. only for a sideways place: the block UNDER the target, clicked on its top face;
--   4. the turtle's own block, clicked on the face toward the target.
-- The click lands on the middle of the face, except that a sideways click's height is 0.45 (not 0.5), so
-- it counts as the bottom half.  The placer's horizontal facing is the way it looks at the clicked block:
-- in 1 and 2 the turtle's heading; in 3 the heading (looking down); in 4 the OPPOSITE of the place
-- direction for a sideways place (so a stair placed that way faces back at the turtle), and the heading
-- for placeDown/placeUp.  The same for "the nearest looking directions" torches, ladders, buttons and
-- levers use: the placer's order with the direction opposite the clicked face moved to the front.  The
-- order is Direction.orderedByNearest's, worked out with Mth's float sine table for the yaws and pitches
-- CC gives: looking down, down, heading, right, left, behind, up (up first and down last looking up); a
-- level look facing south or west, heading, down, right, left, up, behind; facing north or east, heading,
-- right, down, up, left, behind (the float rounding of a quarter turn).  It matters only for a torch,
-- ladder, button or lever with no support on the side clicked.  UNVERIFIED in game.
--
-- Simplifications (what it leaves out): waterlogging (always false), double chests, fence and wall
-- connections, redstone, blocks falling, fluids flowing, entities moving.  A bucket of water or lava
-- places a source block in the target cell; an empty one placed on a source in the target cell takes it
-- up (the bucket comes back full, in the selected slot as CC puts it) and does nothing on flowing liquid.  Flint and steel puts a fire in the cell
-- the click lands in (an empty one with something solid under it); the item is not used up.

local M = require("mock")
local B = {}

--------------------------------------------------------------------------
-- Directions
--------------------------------------------------------------------------
B.COMPASS = { "north", "east", "south", "west" }
local COMPASS = B.COMPASS
local CIDX = { north = 1, east = 2, south = 3, west = 4 }
local OPP = { north = "south", south = "north", east = "west", west = "east", up = "down", down = "up" }
local VERT = { up = { 0, 1, 0 }, down = { 0, -1, 0 } }
local AXIS = { north = "z", south = "z", east = "x", west = "x", up = "y", down = "y" }
local function cw(d) return COMPASS[CIDX[d] % 4 + 1] end                 -- a quarter turn to the right
local function ccw(d) return COMPASS[(CIDX[d] + 2) % 4 + 1] end          -- ... to the left
B.opposite, B.clockwise, B.counterclockwise = OPP, cw, ccw

--------------------------------------------------------------------------
-- Names
--------------------------------------------------------------------------
local function short(name) return name:sub((name:find(":", 1, true) or 0) + 1) end
local function endsWith(s, suffix) return #s >= #suffix and s:sub(-#suffix) == suffix end
local function startsWith(s, prefix) return s:sub(1, #prefix) == prefix end
B.short = short

local LIQUID = { ["minecraft:water"] = true, ["minecraft:lava"] = true }
-- A cell a block is placed into without digging it first.
local REPLACEABLE = { short_grass = true, tall_grass = true, fern = true, large_fern = true, dead_bush = true,
                      vine = true, seagrass = true, fire = true, snow = true }
-- Items that are not blocks.
local NOT_BLOCK_EXACT = { stick = true, coal = true, charcoal = true, diamond = true, emerald = true, flint = true,
                          flint_and_steel = true, bucket = true, apple = true, bread = true, string = true,
                          clay_ball = true, brick = true, lapis_lazuli = true, quartz = true, redstone = true }
local NOT_BLOCK_SUFFIX = { "_pickaxe", "_axe", "_shovel", "_hoe", "_sword", "_ingot", "_nugget", "_dye", "_helmet" }
local ITEM_LIQUID = { ["minecraft:water_bucket"] = "minecraft:water", ["minecraft:lava_bucket"] = "minecraft:lava" }
-- The full bucket an empty one makes of each liquid
local LIQUID_BUCKET = { ["minecraft:water"] = "minecraft:water_bucket", ["minecraft:lava"] = "minecraft:lava_bucket" }
-- Torches: the standing block and the one that hangs on a wall.
local WALL_OF = { torch = "wall_torch", soul_torch = "soul_wall_torch", redstone_torch = "redstone_wall_torch" }
local IS_WALL_TORCH = {}
for _, wall in pairs(WALL_OF) do IS_WALL_TORCH[wall] = true end

-- The family of a block, from its name: exact names first, then the end of the name.
local FAMILY_EXACT = {
    torch = "torch", soul_torch = "torch", redstone_torch = "torch", wall_torch = "torch",
    soul_wall_torch = "torch", redstone_wall_torch = "torch",
    turtle_normal = "turtle", turtle_advanced = "turtle", ladder = "ladder", lever = "lever", chest = "chest", trapped_chest = "chest", furnace = "furnace",
    crimson_stem = "log", warped_stem = "log", hay_block = "log", bone_block = "log", basalt = "log",
    polished_basalt = "log", deepslate = "log",
    short_grass = "plant", tall_grass = "plant", fern = "plant", large_fern = "plant", dead_bush = "plant",
    vine = "plant", seagrass = "plant", fire = "plant", snow = "plant",
}
local FAMILY_SUFFIX = {
    { "_stairs", "stairs" }, { "_slab", "slab" }, { "_trapdoor", "trapdoor" }, { "_door", "door" },
    { "_fence_gate", "fence_gate" }, { "_button", "button" }, { "_log", "log" }, { "_wood", "log" },
    { "_hyphae", "log" }, { "_pillar", "log" }, { "_leaves", "leaves" }, { "_pane", "pane" },
    { "_fence", "fence" }, { "_wall", "wall" },
}
local function familyOf(name)
    local s = short(name)
    if LIQUID[name] then return "liquid" end
    if FAMILY_EXACT[s] then return FAMILY_EXACT[s] end
    for _, row in ipairs(FAMILY_SUFFIX) do
        if endsWith(s, row[1]) then return row[2] end
    end
    return "block"
end
B.familyOf = familyOf

-- Is this item a block at all?
local function isBlockItem(name)
    local s = short(name)
    if NOT_BLOCK_EXACT[s] then return false end
    if endsWith(s, "_bucket") then return false end
    for _, suffix in ipairs(NOT_BLOCK_SUFFIX) do
        if endsWith(s, suffix) then return false end
    end
    return true
end

-- What a block gives when dug (default: itself).
local DROP_AS = { wall_torch = "torch", soul_wall_torch = "soul_torch", redstone_wall_torch = "redstone_torch",
                  trapped_chest = "trapped_chest" }

--------------------------------------------------------------------------
-- Support: does a block have a full face (or, for a torch on top, a centre) to hang or stand on?
--------------------------------------------------------------------------
local FAMILIES                      -- (below)
-- face: the face of THIS block that is asked about; center: a post in the middle will do (a fence top).
local function sturdy(b, face, center)
    if not b or LIQUID[b.name] then return false end
    return FAMILIES[familyOf(b.name)].sturdy(b, face, center)
end
local function fullBlock(b)
    if not b or LIQUID[b.name] then return false end
    return FAMILIES[familyOf(b.name)].full(b)
end
local function yes() return true end
local function no() return false end
local function centerOnly(_, face, center) return center == true and face == "up" end

--------------------------------------------------------------------------
-- Replaceable: may a block of `item` be placed into this block's cell?
--   rel: the height the click landed at in the CLICKED block (0 bottom, 1 top, 0.45 on a side);
--   replacing: Minecraft's BlockPlaceContext.replaceClicked, true while it is being worked out.
-- A half slab of the item's own kind takes another (making it double) from the right side, and the
-- game's second ask (canDeployOnBlock's) with replacing false says yes whatever the side.
--------------------------------------------------------------------------
local function replaceable(b, item, face, rel, replacing)
    if not b or LIQUID[b.name] then return true end
    if REPLACEABLE[short(b.name)] then return true end
    if familyOf(b.name) == "slab" and item == b.name and b.state.type ~= "double" then
        if not replacing then return true end
        local up, side = rel > 0.5, CIDX[face] ~= nil
        if b.state.type == "bottom" then return face == "up" or (up and side) end
        return face == "down" or (not up and side)
    end
    return false
end

--------------------------------------------------------------------------
-- The looking order ("the nearest looking directions" of a placement), see the header
--------------------------------------------------------------------------
local function lookOrder(facing, pitch, face, replaceClicked)
    local order
    -- (Direction.orderedByNearest, worked out with Mth's float sine table for each yaw and pitch CC gives)
    if pitch == "down" then order = { "down", facing, cw(facing), ccw(facing), OPP[facing], "up" }
    elseif pitch == "up" then order = { "up", facing, cw(facing), ccw(facing), OPP[facing], "down" }
    elseif facing == "north" or facing == "east" then order = { facing, cw(facing), "down", "up", ccw(facing), OPP[facing] }
    else order = { facing, "down", cw(facing), ccw(facing), "up", OPP[facing] } end
    if replaceClicked then return order end
    local front = OPP[face]                       -- the way back to the block that was clicked
    local out = { front }
    for _, d in ipairs(order) do
        if d ~= front then out[#out + 1] = d end
    end
    return out
end

--------------------------------------------------------------------------
-- The families.  Each row:
--   place(ctx) -> state [, blockName] | nil     the state a placement gives, nil if the block can't go there
--   after(w, x, y, z, block)                    what else changes when it is set (a door's other half)
--   survives(w, x, y, z, block) -> bool         does it stay when a neighbour goes?
--   sturdy(block, face, center), full(block)    support it gives
--   passable                                    a turtle can move into it (no collision)
--   inventory                                   a container: its slot count
-- ctx: w, x y z (where it goes), face (the clicked face), clicked (that block), replaceClicked,
-- horizontal (the placer's compass facing), look (the order above), hitRel (the click's height above
-- the cell it goes into), item (the item's name), below/above/near(dir) (the blocks around it).
--------------------------------------------------------------------------
local function stairShape(w, x, y, z, st)
    local function stairAt(dir)
        local b = w.near(x, y, z, dir)
        return b and familyOf(b.name) == "stairs" and b or nil
    end
    local function canTake(dir)                 -- StairBlock.canTakeShape
        local s = stairAt(dir)
        return not s or s.state.facing ~= st.facing or s.state.half ~= st.half
    end
    local f = st.facing
    local s1 = stairAt(f)
    if s1 and s1.state.half == st.half then
        local d1 = s1.state.facing
        if AXIS[d1] ~= AXIS[f] and canTake(OPP[d1]) then return d1 == ccw(f) and "outer_left" or "outer_right" end
    end
    local s2 = stairAt(OPP[f])
    if s2 and s2.state.half == st.half then
        local d2 = s2.state.facing
        if AXIS[d2] ~= AXIS[f] and canTake(d2) then return d2 == ccw(f) and "inner_left" or "inner_right" end
    end
    return "straight"
end

local function doorHinge(ctx)                    -- DoorBlock.getHinge (a turtle always clicks the middle)
    local f = ctx.horizontal
    local l, r = ccw(f), cw(f)
    local function full(dir, dy)
        local b = ctx.w.near(ctx.x, ctx.y + dy, ctx.z, dir)
        return fullBlock(b)
    end
    local function lowerDoor(dir)
        local b = ctx.near(dir)
        return b and familyOf(b.name) == "door" and b.state.half == "lower"
    end
    local i = (full(l, 0) and -1 or 0) + (full(l, 1) and -1 or 0) + (full(r, 0) and 1 or 0) + (full(r, 1) and 1 or 0)
    local lowerL, lowerR = lowerDoor(l), lowerDoor(r)
    if (not lowerL or lowerR) and i <= 0 then
        return "left"          -- (with i >= 0 too the game looks at where the click landed: the middle, so left)
    end
    return "right"
end

-- A torch, ladder, button or lever hangs where the first direction in the looking order has support.
local function hangs(ctx, dir) return sturdy(ctx.near(dir), OPP[dir]) end

FAMILIES = {
    block = { sturdy = yes, full = yes, place = function() return {} end },
    -- (the turtle is a small cube in its cell: nothing hangs on it and a door needs more than it)
    turtle = { sturdy = no, full = no, place = function() return {} end },
    liquid = { sturdy = no, full = no, passable = true, place = function() return {} end },
    plant = { sturdy = no, full = no, passable = true, place = function() return {} end },
    leaves = { sturdy = no, full = yes, place = function() return { persistent = true } end },
    pane = { sturdy = centerOnly, full = no, place = function() return {} end },
    fence = { sturdy = centerOnly, full = no, place = function() return {} end },
    wall = { sturdy = centerOnly, full = no, place = function() return {} end },
    chest = { sturdy = no, full = no, inventory = 27,
              place = function(ctx) return { facing = OPP[ctx.horizontal], type = "single", waterlogged = false } end },
    furnace = { sturdy = yes, full = yes, inventory = 3,
                place = function(ctx) return { facing = OPP[ctx.horizontal], lit = false } end },

    -- a stair: facing is the placer's, half from the clicked face (a side: by the height the click landed at)
    stairs = {
        full = no,
        sturdy = function(b, face)
            local half = b.state.half
            return face == b.state.facing or (face == "down" and half == "bottom") or (face == "up" and half == "top")
        end,
        place = function(ctx)
            local half = "bottom"
            if ctx.face == "down" or (CIDX[ctx.face] and ctx.hitRel > 0.5) then half = "top" end
            local st = { facing = ctx.horizontal, half = half, waterlogged = false }
            st.shape = stairShape(ctx.w, ctx.x, ctx.y, ctx.z, st)
            return st
        end,
        after = function(w, x, y, z)             -- the stairs beside it change shape too
            for _, d in ipairs(COMPASS) do
                local nb, nx, ny, nz = w.near(x, y, z, d)
                if nb and familyOf(nb.name) == "stairs" then nb.state.shape = stairShape(w, nx, ny, nz, nb.state) end
            end
        end,
    },

    -- a slab: on top of a half slab of its own kind it becomes a double; else the half from the clicked face
    slab = {
        full = function(b) return b.state.type == "double" end,
        sturdy = function(b, face)
            local t = b.state.type
            return t == "double" or (t == "bottom" and face == "down") or (t == "top" and face == "up")
        end,
        place = function(ctx)
            local here = ctx.w.get(ctx.x, ctx.y, ctx.z)
            if here and here.name == ctx.item then return { type = "double", waterlogged = false } end
            local t = "bottom"
            if ctx.face == "down" or (CIDX[ctx.face] and ctx.hitRel > 0.5) then t = "top" end
            return { type = t, waterlogged = false }
        end,
    },

    -- a log or pillar lies along the axis of the face that was clicked
    log = { sturdy = yes, full = yes, place = function(ctx) return { axis = AXIS[ctx.face] } end },

    -- a torch: a wall torch on the first side in the looking order that has support, else standing on the floor
    torch = {
        sturdy = no, full = no, passable = true,
        place = function(ctx)
            local wall
            for _, d in ipairs(ctx.look) do
                if CIDX[d] and hangs(ctx, d) then wall = { facing = OPP[d] }; break end
            end
            for _, d in ipairs(ctx.look) do
                if d == "down" then
                    if sturdy(ctx.near("down"), "up", true) then return {}, ctx.item end
                elseif d ~= "up" and wall then
                    return wall, "minecraft:" .. WALL_OF[short(ctx.item)]
                end
            end
        end,
        survives = function(w, x, y, z, b)
            if IS_WALL_TORCH[short(b.name)] then
                return sturdy(w.near(x, y, z, OPP[b.state.facing]), b.state.facing)
            end
            return sturdy(w.near(x, y, z, "down"), "up", true)
        end,
    },

    -- a ladder hangs on a side; never on the front of another ladder
    ladder = {
        sturdy = no, full = no,
        place = function(ctx)
            local c = ctx.clicked
            -- (LadderBlock: never against the front of a ladder that faces the clicked side)
            if not ctx.replaceClicked and c and familyOf(c.name) == "ladder" and c.state.facing == ctx.face then
                return nil
            end
            for _, d in ipairs(ctx.look) do
                if CIDX[d] and hangs(ctx, d) then return { facing = OPP[d], waterlogged = false } end
            end
        end,
        survives = function(w, x, y, z, b) return sturdy(w.near(x, y, z, OPP[b.state.facing]), b.state.facing) end,
    },

    -- a door: two blocks, a solid block below and the cell above free; hinge from the neighbours
    door = {
        sturdy = no, full = no,
        place = function(ctx)
            if not sturdy(ctx.near("down"), "up") then return nil end
            local above = ctx.w.at(ctx.x, ctx.y + 1, ctx.z)
            if not replaceable(above, ctx.item, "down", 0, true) then return nil end
            return { facing = ctx.horizontal, half = "lower", hinge = doorHinge(ctx), open = false, powered = false }
        end,
        after = function(w, x, y, z, b)
            local upper = {}
            for k, v in pairs(b.state) do upper[k] = v end
            upper.half = "upper"
            w.put(x, y + 1, z, { name = b.name, state = upper })
        end,
        survives = function(w, x, y, z, b)
            if b.state.half == "upper" then
                local lower = w.near(x, y, z, "down")
                return lower ~= nil and lower.name == b.name and lower.state.half == "lower"
            end
            return sturdy(w.near(x, y, z, "down"), "up")
        end,
    },

    -- a trapdoor: on a side face it is attached to that block (half by the height of the click); else
    -- facing back at the placer, bottom half when clicked on a top face, top half otherwise
    trapdoor = {
        sturdy = no, full = no,
        place = function(ctx)
            if not ctx.replaceClicked and CIDX[ctx.face] then
                return { facing = ctx.face, half = ctx.hitRel > 0.5 and "top" or "bottom", open = false,
                         powered = false, waterlogged = false }
            end
            return { facing = OPP[ctx.horizontal], half = ctx.face == "up" and "bottom" or "top", open = false,
                     powered = false, waterlogged = false }
        end,
    },

    -- a fence gate: facing the placer's, set into a wall when walls stand to its sides
    fence_gate = {
        sturdy = no, full = no,
        place = function(ctx)
            local function wallAt(d)
                local b = ctx.near(d)
                return b ~= nil and familyOf(b.name) == "wall"
            end
            return { facing = ctx.horizontal, in_wall = wallAt(cw(ctx.horizontal)) or wallAt(ccw(ctx.horizontal)),
                     open = false, powered = false }
        end,
    },
}
-- A button or lever: on the floor, a wall or the ceiling, whichever the looking order finds support on first
-- (FaceAttachedHorizontalDirectionalBlock.getStateForPlacement).
local function faceAttached(ctx)
    for _, d in ipairs(ctx.look) do
        local st
        if VERT[d] then st = { face = d == "up" and "ceiling" or "floor", facing = ctx.horizontal, powered = false }
        else st = { face = "wall", facing = OPP[d], powered = false } end
        if hangs(ctx, d) then return st end
    end
end
local function faceSurvives(w, x, y, z, b)
    local sup = b.state.face == "ceiling" and "up" or (b.state.face == "floor" and "down" or OPP[b.state.facing])
    return sturdy(w.near(x, y, z, sup), OPP[sup])
end
FAMILIES.button = { sturdy = no, full = no, passable = true, place = faceAttached, survives = faceSurvives }
FAMILIES.lever = FAMILIES.button
B.FAMILIES = FAMILIES
for name, f in pairs(FAMILIES) do
    f.passable = f.passable or false
    f.sturdy = f.sturdy or yes
    f.full = f.full or yes
    f.name = name
end

--------------------------------------------------------------------------
-- Fuel and smelting (the furnace)
--------------------------------------------------------------------------
-- Ticks a fuel burns (20 a second).  The nether woods are not fuel.
B.FUEL_TICKS = { coal = 1600, charcoal = 1600, coal_block = 16000, lava_bucket = 20000, blaze_rod = 2400,
                 stick = 100, crafting_table = 300, chest = 300, bamboo = 50 }
local WOOD_FUEL = { "_planks", "_log", "_wood" }
local NO_FUEL_PREFIX = { "crimson_", "warped_", "stripped_crimson", "stripped_warped" }
function B.fuelTicks(name)
    local s = short(name)
    for _, p in ipairs(NO_FUEL_PREFIX) do
        if startsWith(s, p) then return nil end
    end
    if B.FUEL_TICKS[s] then return B.FUEL_TICKS[s] end
    for _, suffix in ipairs(WOOD_FUEL) do
        if endsWith(s, suffix) then return 300 end
    end
end
-- What smelts into what.
B.SMELTS = { cobblestone = "stone", stone = "smooth_stone", sand = "glass", raw_iron = "iron_ingot",
             raw_gold = "gold_ingot", raw_copper = "copper_ingot", clay_ball = "brick", clay = "terracotta",
             netherrack = "nether_brick", cobbled_deepslate = "deepslate", iron_ore = "iron_ingot",
             oak_log = "charcoal", birch_log = "charcoal", spruce_log = "charcoal" }
B.SMELT_TICKS = 200
function B.smeltsTo(name)
    local r = B.SMELTS[short(name)]
    return r and ("minecraft:" .. r) or nil
end

--------------------------------------------------------------------------
-- Crafting: the 3x3 and the recipes
--------------------------------------------------------------------------
-- Names for a group of items a recipe takes.
local STONES = { cobblestone = true, stone = true, stone_bricks = true, bricks = true, blackstone = true,
                 polished_blackstone = true, polished_blackstone_bricks = true, cobbled_deepslate = true,
                 sandstone = true, nether_bricks = true, quartz_block = true }
local TAGS = {
    log = function(n) return endsWith(n, "_log") or endsWith(n, "_wood") end,
    planks = function(n) return endsWith(n, "_planks") end,
    coal = function(n) return n == "coal" or n == "charcoal" end,
    stick = function(n) return n == "stick" end,
    stone = function(n) return STONES[n] == true end,
    building = function(n) return STONES[n] == true or endsWith(n, "_planks") end,
    cobble = function(n) return n == "cobblestone" or n == "blackstone" or n == "cobbled_deepslate" end,
    iron_ingot = function(n) return n == "iron_ingot" end,
    iron_nugget = function(n) return n == "iron_nugget" end,
    glass = function(n) return n == "glass" end,
    plain_stone = function(n) return n == "stone" end,
}
-- The name a block's stairs, slab or wall take: oak_planks -> oak_<x>, stone_bricks -> stone_brick_<x>.
local function derive(name, kind)
    local s = short(name)
    if endsWith(s, "_planks") then s = s:sub(1, #s - 7)
    elseif endsWith(s, "_bricks") then s = s:sub(1, #s - 1) end
    return "minecraft:" .. s .. "_" .. kind
end
B.derive = derive
-- Each recipe: a name, a shape (rows of letters, "." empty), what each letter is (a tag), out(ingredients by
-- letter) -> name, count, and mixed: whether one letter may stand for different items (any planks).  Shaped
-- recipes also match mirrored left to right.
local function woodOf(name)                      -- stripped_oak_log, oak_wood, oak_log -> oak
    local s = short(name)
    if startsWith(s, "stripped_") then s = s:sub(10) end
    if endsWith(s, "_log") then return s:sub(1, #s - 4) end
    return s:sub(1, #s - 5)
end
B.RECIPES = {
    { name = "planks", shape = { "L" }, key = { L = "log" }, out = function(i) return "minecraft:" .. woodOf(i.L) .. "_planks", 4 end },
    { name = "sticks", shape = { "P", "P" }, key = { P = "planks" }, mixed = true, out = function() return "minecraft:stick", 4 end },
    { name = "torches", shape = { "C", "S" }, key = { C = "coal", S = "stick" }, mixed = true, out = function() return "minecraft:torch", 4 end },
    { name = "chest", shape = { "PPP", "P.P", "PPP" }, key = { P = "planks" }, mixed = true, out = function() return "minecraft:chest", 1 end },
    { name = "crafting table", shape = { "PP", "PP" }, key = { P = "planks" }, mixed = true, out = function() return "minecraft:crafting_table", 1 end },
    { name = "furnace", shape = { "CCC", "C.C", "CCC" }, key = { C = "cobble" }, mixed = true, out = function() return "minecraft:furnace", 1 end },
    { name = "stairs", shape = { "X..", "XX.", "XXX" }, key = { X = "building" }, out = function(i) return derive(i.X, "stairs"), 4 end },
    { name = "slabs", shape = { "XXX" }, key = { X = "building" }, out = function(i) return derive(i.X, "slab"), 6 end },
    { name = "walls", shape = { "XXX", "XXX" }, key = { X = "stone" }, out = function(i) return derive(i.X, "wall"), 6 end },
    { name = "doors", shape = { "PP", "PP", "PP" }, key = { P = "planks" }, out = function(i) return derive(i.P, "door"), 3 end },
    { name = "trapdoors", shape = { "PPP", "PPP" }, key = { P = "planks" }, out = function(i) return derive(i.P, "trapdoor"), 2 end },
    { name = "ladders", shape = { "S.S", "SSS", "S.S" }, key = { S = "stick" }, out = function() return "minecraft:ladder", 3 end },
    { name = "fence gates", shape = { "SPS", "SPS" }, key = { S = "stick", P = "planks" }, out = function(i) return derive(i.P, "fence_gate"), 1 end },
    { name = "fences", shape = { "PSP", "PSP" }, key = { S = "stick", P = "planks" }, out = function(i) return derive(i.P, "fence"), 3 end },
    { name = "stone bricks", shape = { "SS", "SS" }, key = { S = "plain_stone" }, out = function() return "minecraft:stone_bricks", 4 end },
    { name = "iron bars", shape = { "III", "III" }, key = { I = "iron_ingot" }, out = function() return "minecraft:iron_bars", 16 end },
    { name = "glass panes", shape = { "GGG", "GGG" }, key = { G = "glass" }, out = function() return "minecraft:glass_pane", 16 end },
    { name = "bucket", shape = { "I.I", ".I." }, key = { I = "iron_ingot" }, out = function() return "minecraft:bucket", 1 end },
    { name = "chain", shape = { "N", "I", "N" }, key = { N = "iron_nugget", I = "iron_ingot" }, out = function() return "minecraft:chain", 1 end },
}

-- The recipe a 3x3 of names (grid[row][col], row 1..3 and col 1..3, nil empty) makes: name, count, recipe
-- name -- or nil.
function B.recipeFor(grid)
    local r1, c1, r2, c2 = 9, 9, 0, 0
    for r = 1, 3 do
        for c = 1, 3 do
            if grid[r] and grid[r][c] then
                r1, c1, r2, c2 = math.min(r1, r), math.min(c1, c), math.max(r2, r), math.max(c2, c)
            end
        end
    end
    if r2 == 0 then return nil end
    for _, rec in ipairs(B.RECIPES) do
        local shape, key = rec.shape, rec.key
        if #shape == r2 - r1 + 1 and #shape[1] == c2 - c1 + 1 then
            for _, mirror in ipairs({ false, true }) do
                local ing, ok = {}, true
                for r = 1, #shape do
                    for c = 1, #shape[1] do
                        local col = mirror and (#shape[1] + 1 - c) or c
                        local ch = shape[r]:sub(col, col)
                        local have = grid[r1 + r - 1] and grid[r1 + r - 1][c1 + c - 1]
                        if ch == "." then
                            if have then ok = false end
                        elseif not have or not (type(key[ch]) == "function" and key[ch] or TAGS[key[ch]])(short(have)) then
                            ok = false
                        elseif ing[ch] and ing[ch] ~= have and not rec.mixed then
                            ok = false
                        else
                            ing[ch] = ing[ch] or have
                        end
                    end
                end
                if ok then
                    local name, count = rec.out(ing)
                    return name, count, rec.name
                end
            end
        end
    end
end

--------------------------------------------------------------------------
-- The world
--------------------------------------------------------------------------
-- opts.facing: the compass way heading 0 points (default north).
function B.new(opts)
    opts = opts or {}
    local w = { S = M.state(), W = {}, entities = {}, ground = {}, time = 0, facing = opts.facing or "north",
                frames = {}, placed = 0 }
    local S, W = w.S, w.W
    local c0 = CIDX[w.facing] - 1
    S.get = function(x, y, z) return W[M.key(x, y, z)] end
    S.dirs = {}

    -- the compass name of a heading, and the vector of a direction name
    function w.compass(h) return COMPASS[(h + c0) % 4 + 1] end
    function w.heading(compass) return (CIDX[compass] - 1 - c0) % 4 end
    function w.vec(dir)
        if VERT[dir] then return VERT[dir][1], VERT[dir][2], VERT[dir][3] end
        local h = w.heading(dir)
        return M.DX[h], 0, M.DZ[h]
    end
    local TURTLE_BLOCK = { name = "computercraft:turtle_advanced", state = { facing = "north" } }
    -- the block in a cell (the turtle's own cell holds the turtle)
    function w.at(x, y, z)
        if x == S.P.x and y == S.P.y and z == S.P.z then return TURTLE_BLOCK end
        return W[M.key(x, y, z)]
    end
    -- the block next to a cell, with where that was
    function w.near(x, y, z, dir)
        local dx, dy, dz = w.vec(dir)
        return w.at(x + dx, y + dy, z + dz), x + dx, y + dy, z + dz
    end
    function w.get(x, y, z) return W[M.key(x, y, z)] end

    -- Set a cell: block (a table), or a name and a state; nil for air.  A chest or furnace gets its slots.
    function w.put(x, y, z, block)
        if block and FAMILIES[familyOf(block.name)].inventory and not block.inv then
            block.inv = {}
            if familyOf(block.name) == "furnace" then block.burn, block.burnMax, block.cook = 0, 0, 0 end
        end
        W[M.key(x, y, z)] = block
    end
    function w.set(x, y, z, name, state)
        if not name then w.put(x, y, z, nil); return end
        w.put(x, y, z, { name = name, state = state or {} })
    end
    -- the state of a block (a copy), or nil for air
    function w.state(x, y, z)
        local b = W[M.key(x, y, z)]
        if not b then return nil end
        local c = {}
        for k, v in pairs(b.state) do c[k] = v end
        return c
    end
    -- a box of one block
    function w.fill(x1, y1, z1, x2, y2, z2, name, state)
        for x = math.min(x1, x2), math.max(x1, x2) do
            for y = math.min(y1, y2), math.max(y1, y2) do
                for z = math.min(z1, z2), math.max(z1, z2) do
                    local st = {}
                    for k, v in pairs(state or {}) do st[k] = v end
                    w.set(x, y, z, name, st)
                end
            end
        end
    end
    -- "name[k=v,k=v]" with the keys sorted, or "air"
    function w.show(x, y, z)
        local b = W[M.key(x, y, z)]
        if not b then return "air" end
        local keys = {}
        for k in pairs(b.state) do keys[#keys + 1] = k end
        table.sort(keys)
        local parts = {}
        for _, k in ipairs(keys) do parts[#parts + 1] = k .. "=" .. tostring(b.state[k]) end
        return short(b.name) .. (#parts > 0 and ("[" .. table.concat(parts, ",") .. "]") or "")
    end
    -- the turtle's inventory
    function w.give(slot, name, count)
        S.inv[slot] = name and { name = name, count = count or 1 } or nil
    end
    function w.carrying(name) return M.carried(S, name) end
    -- put the turtle somewhere: x, y, z and a COMPASS facing
    function w.stand(x, y, z, compass)
        S.P.x, S.P.y, S.P.z = x, y, z
        S.P.d = w.heading(compass or w.facing)
    end
    function w.addEntity(x, y, z, name, accepts)
        w.entities[M.key(x, y, z)] = { name = name, accepts = accepts == true, item = nil }
    end

    ----------------------------------------------------------------------
    -- Settling: what hung on a block that went falls off
    ----------------------------------------------------------------------
    local function drop(x, y, z, name, n)
        local k = M.key(x, y, z)
        w.ground[k] = w.ground[k] or {}
        w.ground[k][#w.ground[k] + 1] = { name = name, count = n or 1 }
    end
    local DIRS6 = { "up", "down", "north", "east", "south", "west" }
    local function itemOf(b)
        local s = short(b.name)
        return "minecraft:" .. (DROP_AS[s] or s)
    end
    local settle
    local function pop(x, y, z)
        local b = W[M.key(x, y, z)]
        W[M.key(x, y, z)] = nil
        if b and not (b.state.half == "upper") then drop(x, y, z, itemOf(b), b.state.type == "double" and 2 or 1) end
        settle(x, y, z)
    end
    function settle(x, y, z)
        for _, d in ipairs(DIRS6) do
            local nb, nx, ny, nz = w.near(x, y, z, d)
            if nb and W[M.key(nx, ny, nz)] then
                local fam = FAMILIES[familyOf(nb.name)]
                if fam.survives and not fam.survives(w, nx, ny, nz, nb) then pop(nx, ny, nz) end
            end
        end
    end
    w.settle = settle

    ----------------------------------------------------------------------
    -- Placing one item against one face
    ----------------------------------------------------------------------
    -- Hit height above the clicked block's floor: a top face 1, a bottom face 0, a side 0.45
    local function hitFrac(face) return VERT[face] and (face == "up" and 1 or 0) or 0.45 end

    -- Use the item in the selected slot on the block at cx,cy,cz, clicked on `face`, with the placer
    -- facing `facing` (compass) and looking `pitch` (nil, "down" or "up").  True if something was placed.
    local function useOn(item, cx, cy, cz, face, facing, pitch)
        local clicked = w.at(cx, cy, cz)
        local rel = hitFrac(face)
        local replaceClicked = replaceable(clicked, item, face, rel, true)
        local fx, fy, fz = w.vec(face)
        local px, py, pz = cx, cy, cz
        if not replaceClicked then px, py, pz = cx + fx, cy + fy, cz + fz end
        local into = w.at(px, py, pz)
        if not replaceable(into, item, face, rel, replaceClicked) then return false end
        if w.entities[M.key(px, py, pz)] and not w.entities[M.key(px, py, pz)].accepts then return false end   -- (a minecart, say)
        -- a bucket: a liquid source in the cell
        if ITEM_LIQUID[item] then
            w.set(px, py, pz, ITEM_LIQUID[item], { level = 0 })
            S.inv[S.sel] = { name = "minecraft:bucket", count = 1 }
            return true
        end
        -- flint and steel: a fire in the cell the click lands in, if it is empty and has something solid under it
        -- (the item is damaged, not used up)
        if short(item) == "flint_and_steel" then
            if into ~= nil or not sturdy(w.at(px, py - 1, pz), "up") then return false end
            w.put(px, py, pz, { name = "minecraft:fire", state = { age = 0 } })
            return true
        end
        if not isBlockItem(item) then return false end
        local fam = FAMILIES[familyOf(item)]
        local ctx = {
            w = w, x = px, y = py, z = pz, face = face, clicked = clicked, replaceClicked = replaceClicked,
            horizontal = facing, item = item, hitRel = cy + rel - py,
            look = lookOrder(facing, pitch, face, replaceClicked),
        }
        function ctx.near(dir) return (w.near(px, py, pz, dir)) end
        local state, name = fam.place(ctx)
        if not state then return false end
        local block = { name = name or item, state = state }
        w.put(px, py, pz, block)
        if fam.after then fam.after(w, px, py, pz, block) end
        w.placed = w.placed + 1
        local it = S.inv[S.sel]
        it.count = it.count - 1
        if it.count <= 0 then S.inv[S.sel] = nil end
        return true
    end

    -- turtle.place in a direction ("front", "up", "down"): the attempts of TurtlePlaceCommand.deploy
    local function deploy(where)
        local it = S.inv[S.sel]
        if not it then return false, "No items to place" end
        local heading = w.compass(S.P.d)
        local dir = where == "front" and heading or where
        local x, y, z = S.P.x, S.P.y, S.P.z
        local dx, dy, dz = w.vec(dir)
        local tx, ty, tz = x + dx, y + dy, z + dz                  -- the target cell
        local item = it.name
        -- an empty bucket takes up a liquid source in the target cell
        if item == "minecraft:bucket" then
            local b = w.at(tx, ty, tz)
            if not (b and LIQUID[b.name] and tonumber(b.state.level or 0) == 0) then return false, "Cannot place item here" end
            W[M.key(tx, ty, tz)] = nil
            it.count = it.count - 1
            if it.count <= 0 then S.inv[S.sel] = nil end
            M.addItem(S, LIQUID_BUCKET[b.name], 1)
            return true
        end
        local block = isBlockItem(item)
        local function usable(cx, cy, cz, adjacent, face)
            local b = w.at(cx, cy, cz)
            if not b then return false end                         -- air
            if block and LIQUID[b.name] then return false end
            local rel = hitFrac(face)
            local rep = replaceable(b, item, face, rel, true)
            rep = replaceable(b, item, face, rel, rep)
            if not adjacent and rep then return false end
            return true
        end
        -- how the placer looks at the block it clicks: facing it from the other side
        local function placer(face)
            local look = OPP[face]
            if VERT[look] then return heading, look end
            return look, nil
        end
        -- 0. an entity in the target cell that takes the item
        local e = w.entities[M.key(tx, ty, tz)]
        if e and e.accepts then
            e.item = item
            it.count = it.count - 1
            if it.count <= 0 then S.inv[S.sel] = nil end
            return true
        end
        local attempts = {
            { tx, ty, tz, true, OPP[dir] },                                    -- 1. the target itself
            { tx + dx, ty + dy, tz + dz, false, OPP[dir] },                    -- 2. the block beyond it
        }
        if not VERT[dir] then attempts[#attempts + 1] = { tx, ty - 1, tz, false, "up" } end      -- 3. the floor under it
        attempts[#attempts + 1] = { x, y, z, false, dir }                      -- 4. the turtle itself
        for _, a in ipairs(attempts) do
            if usable(a[1], a[2], a[3], a[4], a[5]) then
                local facing, pitch = placer(a[5])
                if useOn(item, a[1], a[2], a[3], a[5], facing, pitch) then return true end
            end
        end
        return false, block and "Cannot place block here" or "Cannot place item here"
    end

    ----------------------------------------------------------------------
    -- Digging, inspecting
    ----------------------------------------------------------------------
    local function dig(x, y, z)
        local b = w.at(x, y, z)
        if not b or LIQUID[b.name] or b == TURTLE_BLOCK then return false, "Nothing to dig here" end
        if b.name == "minecraft:bedrock" then return false, "Unbreakable block detected" end
        local dropName, n = itemOf(b), b.state.type == "double" and 2 or 1
        if b.state.half == "upper" then dropName = nil end
        W[M.key(x, y, z)] = nil
        if familyOf(b.name) == "door" then            -- both halves go
            local oy = b.state.half == "upper" and y - 1 or y + 1
            local o = W[M.key(x, oy, z)]
            if o and o.name == b.name then W[M.key(x, oy, z)] = nil end
        end
        if b.inv then                                  -- what a container held
            for _, s in pairs(b.inv) do M.addItem(S, s.name, s.count) end
        end
        if dropName then M.addItem(S, dropName, n) end
        w.dug = (w.dug or 0) + 1
        settle(x, y, z)
        return true
    end
    local function inspectAt(x, y, z)
        local b = W[M.key(x, y, z)]
        if not b then return false, "No block to inspect" end
        local st = {}
        for k, v in pairs(b.state) do st[k] = v end
        return true, { name = b.name, state = st, tags = {} }
    end
    local function passable(b)
        return b == nil or LIQUID[b.name] ~= nil or FAMILIES[familyOf(b.name)].passable
    end
    local function solid(b) return b ~= nil and not LIQUID[b.name] end

    ----------------------------------------------------------------------
    -- Containers: chests, and the furnace by its faces
    ----------------------------------------------------------------------
    -- Which slots a face of a furnace shows (vanilla's getSlotsForFace): the top the input, the
    -- underside the output (and a bucket from the fuel slot), the sides the fuel.  Slot 1 input, 2 fuel, 3 output.
    local FURNACE_PUT = { up = { 1 }, down = { 2 }, side = { 2 } }          -- (the output slot takes nothing)
    local FURNACE_TAKE = { up = { 1 }, down = { 3, 2 }, side = { 2 } }
    local function faceKind(face) return VERT[face] and face or "side" end
    local function stackMax(name) return M.stackSize(name) end

    -- the turtle puts n of the selected slot into the block at x,y,z, through the face of it nearest
    -- the turtle: `face` is the block's face being touched.  True if any went in.
    local function dropInto(x, y, z, face, n)
        local b = W[M.key(x, y, z)]
        local it = S.inv[S.sel]
        if not (b and b.inv and it) then return false end
        local fam = familyOf(b.name)
        if fam == "chest" then return M.dropInto(S, b.inv, 27, n) end
        local want = math.min(n or it.count, it.count)
        local moved = 0
        for _, slot in ipairs(FURNACE_PUT[faceKind(face)]) do
            if slot == 2 and not B.fuelTicks(it.name) then goto continue end
            do
                local d = b.inv[slot]
                if not d or d.name == it.name then
                    local room = stackMax(it.name) - (d and d.count or 0)
                    local k = math.min(want - moved, room)
                    if k > 0 then
                        b.inv[slot] = { name = it.name, count = (d and d.count or 0) + k }
                        moved = moved + k
                    end
                end
            end
            ::continue::
        end
        it.count = it.count - moved
        if it.count == 0 then S.inv[S.sel] = nil end
        return moved > 0
    end
    local function suckFrom(x, y, z, face, n)
        local b = W[M.key(x, y, z)]
        if not (b and b.inv) then return false end
        if familyOf(b.name) == "chest" then return M.suckFrom(S, b.inv, 27, n) end
        for _, slot in ipairs(FURNACE_TAKE[faceKind(face)]) do
            local d = b.inv[slot]
            local bucketOnly = faceKind(face) == "down" and slot == 2
            if d and (not bucketOnly or short(d.name) == "bucket" or short(d.name) == "water_bucket") then
                local c = { d }
                local got = M.suckFrom(S, c, 1, n)
                if c[1] then b.inv[slot] = c[1] else b.inv[slot] = nil end
                return got
            end
        end
        return false
    end

    -- Time passes in the furnaces (vanilla's AbstractFurnaceBlockEntity.serverTick, per tick)
    local function tickFurnace(b)
        local inv = b.inv
        local input, fuel, out = inv[1], inv[2], inv[3]
        local result = input and B.smeltsTo(input.name)
        local canSmelt = result ~= nil and (not out or (out.name == result and out.count < stackMax(result)))
        if b.burn > 0 then b.burn = b.burn - 1 end
        if b.burn == 0 and canSmelt and fuel then
            local t = B.fuelTicks(fuel.name)
            if t then
                b.burn, b.burnMax = t, t
                if short(fuel.name) == "lava_bucket" then inv[2] = { name = "minecraft:bucket", count = 1 }
                else
                    fuel.count = fuel.count - 1
                    if fuel.count == 0 then inv[2] = nil end
                end
            end
        end
        if b.burn > 0 and canSmelt then
            b.cook = b.cook + 1
            if b.cook >= B.SMELT_TICKS then
                b.cook = 0
                input.count = input.count - 1
                if input.count == 0 then inv[1] = nil end
                inv[3] = { name = result, count = (out and out.count or 0) + 1 }
            end
        elseif b.cook > 0 then
            b.cook = math.max(b.cook - 2, 0)
        end
        b.state.lit = b.burn > 0
    end
    -- seconds pass: the furnaces cook
    function w.advance(seconds)
        w.time = w.time + seconds
        local ticks = math.floor(seconds * 20 + 0.5)
        for _, b in pairs(W) do
            if b.burn then
                for _ = 1, ticks do tickFurnace(b) end
            end
        end
    end

    ----------------------------------------------------------------------
    -- The workbench: turtle.craft's grid is a 3x3 window of the 4x4 inventory with every other slot empty
    ----------------------------------------------------------------------
    local function craft(limit)
        local inv = S.inv
        local window
        for r0 = 0, 1 do
            for c0 = 0, 1 do
                if not window then
                    local ok, any = true, false
                    for s = 1, 16 do
                        local r, c = math.floor((s - 1) / 4), (s - 1) % 4
                        local inside = r >= r0 and r < r0 + 3 and c >= c0 and c < c0 + 3
                        if inv[s] then
                            any = true
                            if not inside then ok = false end
                        end
                    end
                    if ok and any then window = { r0, c0 } end
                end
            end
        end
        if not window then return false, "No matching recipes" end
        local grid, slots = { {}, {}, {} }, {}
        for r = 1, 3 do
            for c = 1, 3 do
                local s = (window[1] + r - 1) * 4 + window[2] + c
                if inv[s] then grid[r][c] = inv[s].name; slots[#slots + 1] = s end
            end
        end
        local name, count = B.recipeFor(grid)
        if not name then return false, "No matching recipes" end
        local steps = math.min(limit or 64, 64)
        for _, s in ipairs(slots) do steps = math.min(steps, inv[s].count) end
        for _, s in ipairs(slots) do
            inv[s].count = inv[s].count - steps
            if inv[s].count == 0 then inv[s] = nil end
        end
        M.addItem(S, name, steps * count)
        w.crafted = w.crafted or {}
        w.crafted[name] = (w.crafted[name] or 0) + steps * count
        return true
    end
    w.craft = craft

    ----------------------------------------------------------------------
    -- The turtle and the peripherals
    ----------------------------------------------------------------------
    w.TABLE = "minecraft:crafting_table"
    local function sideBlock(side)
        if side == "front" then return w.at(M.front(S)), M.front(S) end
        if side == "top" then return w.at(M.above(S)), M.above(S) end
        if side == "bottom" then return w.at(M.below(S)), M.below(S) end
    end
    local function wrapSide(side)
        if side == "left" or side == "right" then
            if EQ[side] == w.TABLE then return { craft = craft }, "workbench" end
            return nil
        end
        local b = sideBlock(side)
        if b and b.inv then
            local size = FAMILIES[familyOf(b.name)].inventory
            return M.containerPeripheral(b.inv, size, side), b.name
        end
    end
    w.peripheral = {
        wrap = function(side) return (wrapSide(side)) end,
        getType = function(side) local _, t = wrapSide(side); return t end,
        isPresent = function(side) return wrapSide(side) ~= nil end,
        getName = function(p) return p._name end,
        getMethods = function(side)
            local p = wrapSide(side)
            if not p then return nil end
            local names = {}
            for name, f in pairs(p) do
                if type(f) == "function" then names[#names + 1] = name end
            end
            table.sort(names)
            return names
        end,
        call = function(side, name, ...)
            local p = wrapSide(side)
            if not (p and p[name]) then error("No such method " .. name, 0) end
            return p[name](...)
        end,
        getNames = function()
            local out = {}
            for _, side in ipairs({ "bottom", "front", "left", "right", "top" }) do
                if wrapSide(side) then out[#out + 1] = side end
            end
            return out
        end,
        find = function(kind)
            for _, side in ipairs({ "front", "left", "right", "top", "bottom" }) do
                local p, t = wrapSide(side)
                if p and t == kind then return p end
            end
        end,
    }

    local acting = M.merge(
        M.actingApi(S, "place", function(_, _, _, where) return deploy(where) end),
        M.actingApi(S, "dig", function(x, y, z) return dig(x, y, z) end),
        M.actingApi(S, "drop", function(x, y, z, where, n)
            local b = w.at(x, y, z)
            if b and b.inv then
                local ok = dropInto(x, y, z, OPP[where == "front" and w.compass(S.P.d) or where], n)
                return ok, (not ok) and "No space for items" or nil
            end
            local it = S.inv[S.sel]                  -- nothing to take it: it lands in the world
            if not it then return false, "No items to drop" end
            local k = math.min(n or it.count, it.count)
            drop(x, y, z, it.name, k)
            w.thrown = (w.thrown or 0) + k
            it.count = it.count - k
            if it.count == 0 then S.inv[S.sel] = nil end
            return true
        end),
        M.actingApi(S, "suck", function(x, y, z, where, n)
            return suckFrom(x, y, z, OPP[where == "front" and w.compass(S.P.d) or where], n)
        end))
    w.turtle = M.merge(
        M.inventoryApi(S), M.fuelApi(S), M.noAttackApi(), M.equipmentApi(S),
        M.movementApi(S, passable),
        M.lookingApi(S, inspectAt, solid),
        acting)

    function w.install()
        EQ = EQ or {}
        turtle = w.turtle
        peripheral = w.peripheral
        fs = M.fsApi(S)
        textutils = textutils or M.textutilsApi()
        shell = M.shellApi("x.lua")
        sleep = function(t) w.advance(t or 0) end
        return w
    end
    return w
end

return B
