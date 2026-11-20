-- place.lua -- placing blocks the right way round: stairs, slabs, logs, torches, doors and the rest, and lighting a fire
--
-- Loaded by turtlelib the first time T.placeAt or T.ignite is used.  Cells are the turtle's own (the frame it
-- counts in).
--
-- A turtle does not choose how a block lands.  What it gets depends on how the turtle places it, because the game
-- has the turtle's fake player click a block, and the block's state comes from the click (CC:Tweaked's
-- TurtlePlaceCommand, and Minecraft's rules for each block).  The game tries, in order: a block already in the
-- target cell, the block BEYOND the target (clicked on the face toward the turtle), for a sideways place the
-- block under the target (clicked on its top), and last the turtle's own block.  A sideways click lands just
-- below the middle of a face, so what that gives is, in short:
--   sideways     stairs and slabs bottom half, the stair facing the turtle's heading; a log lying along the heading
--                with a block beyond (standing with only a floor); a torch, sign, ladder, button or lever hung on
--                the block beyond; a door, gate or chest facing as the turtle does; a piston, dispenser or dropper
--                facing back at the turtle (an observer away from it), up onto a floor (an observer down); a
--                repeater or comparator, on a floor, facing back at the turtle
--   placeDown    stairs and slabs bottom half if there is a block under the target, else top half; a piston up
--                onto a block, else down (an observer the other way)
--   placeUp      stairs and slabs top half if there is a block over the target, else bottom half; a piston down
--                onto a block, else up (an observer the other way)
--   (from above or below a ladder hangs on the block beside the target the way the turtle faces)
-- (With nothing to click but the turtle's own block, a sideways stair faces back at the turtle.)
-- The table of what each approach yields is data (T.PLACE_TABLE): per family of block, per approach (front, down,
-- up), rows that say "if there is a block beyond (or a floor under the target), these state values".  A row's
-- value is a plain word (half=bottom) or relative to the turtle's heading: facing=heading, back, right or left,
-- and axis=along (the heading's) or across.  The rest of this comment is how it is used.
--
-- T.placeAt(x, y, z, item, { facing, half, axis }) works out which approaches the table says give that state and
-- the map (tl.world) says are possible, goes to the nearest, places, inspects, and if the state came out wrong digs
-- the block and tries the next.  Facing is a compass name, so it needs the world origin (T.setOrigin: the
-- compass way the turtle's frame points); half and axis do not, nor a piston's or observer's facing up or down.  Where the map does not know what is beside the
-- target the approaches are only guesses and go last.  What actually came out is remembered per family, in the data
-- file .placements, but only when the map knew every fact the row depended on: a table row that was wrong is
-- corrected once, for every later placement.  A door goes in after the walls round it, and needs a solid block under it
-- and the cell above free; T.ignite lights a fire from above with flint and steel.  A sign takes its text
-- (opts.text), which the game writes when the turtle places it, and opts.toward turns it to a reader (T.signFor finds
-- the cell in front of one).

local T = require("turtlelib")
local text = require("text")
local convert = require("convert")
local fileio = require("fileio")
local tables = require("tables")

local LEARN_FILE = ".placements"             -- what came out, where the table was wrong, in the data folder
local TRIES = 6                              -- approaches tried before giving up (opts.tries)
local AIR = "minecraft:air"

-- The compass, clockwise from north.  The turtle's heading h is the compass way T.origin().facing turned h
-- quarter turns to the right.
local COMPASS = { [0] = "north", "east", "south", "west" }
local COMPASS_AT = { north = 0, east = 1, south = 2, west = 3 }
local AXIS_OF = { north = "z", south = "z", east = "x", west = "x" }
-- Turns to the right from the heading, for a rule that is relative to it
local RELATIVE = { heading = 0, right = 1, back = 2, left = 3 }
local RELATIVE_NAMES = { "heading", "right", "back", "left" }
-- The facings that are not a compass way (a piston's, an observer's)
local VERTICAL = { up = true, down = true }
-- A standing sign's rotation: sixteenths of a turn, 0 its face looking south, 4 west, 8 north, 12 east (Minecraft's
-- StandingSignBlock, set from the placer's look turned half round: RotationSegment.convertToSegment(yaw + 180)).  A
-- turtle's fake player looks along a compass way, so these four are the only ones a turtle gives.
local ROTATION_FACING = { south = 0, west = 4, north = 8, east = 12 }
local ROTATIONS = { 0, 4, 8, 12 }

--------------------------------------------------------------------------
-- Blocks by name: what family, what can be clicked, what holds a torch
--------------------------------------------------------------------------

-- The family of a block, from its name: exact names first, then the end of the name.
local FAMILY_EXACT = {
    torch = "torch", soul_torch = "torch", redstone_torch = "torch", ladder = "ladder", lever = "button",
    chest = "chest", trapped_chest = "chest", furnace = "chest", blast_furnace = "chest", smoker = "chest",
    crimson_stem = "log", warped_stem = "log", hay_block = "log", bone_block = "log", basalt = "log",
    polished_basalt = "log", deepslate = "log",
    piston = "piston", sticky_piston = "piston", dispenser = "piston", dropper = "piston", observer = "observer",
    repeater = "diode", comparator = "diode",
    chain = "chain", lantern = "lantern", soul_lantern = "lantern",
    sea_lantern = "block", jack_o_lantern = "block",        -- (whole blocks, whatever their names end in)
}
local FAMILY_SUFFIX = {
    { "_stairs", "stairs" }, { "_slab", "slab" }, { "_trapdoor", "trapdoor" }, { "_door", "door" },
    { "_fence_gate", "fence_gate" }, { "_button", "button" }, { "_log", "log" }, { "_wood", "log" },
    { "_hyphae", "log" }, { "_pillar", "log" }, { "_stem", "log" }, { "_fence", "fence" }, { "_pane", "pane" },
    { "_wall", "wall" }, { "_hanging_sign", "block" }, { "_sign", "sign" }, { "_chain", "chain" },
    { "copper_lantern", "lantern" },
}
-- (a hanging sign is not a sign of the table's: it hangs under a block, and goes in as it comes)

-- Blocks whose item has another name (vanilla Minecraft 1.21): the block, the item that places it, and the form.
-- "placed" is what the item places; "wall" is the form that hangs on the side of a block (placeAt's block=wall); "also"
-- is another form the block takes (the body of a vine, kelp or dripleaf, a stem that has made its fruit, bamboo grown
-- from its shoot), still the item's.  T.itemOfBlock and T.blockOfItem read it, and tl.blueprint through them.
-- (Left out: what a bucket places, which placeAt does not carry; blocks no item places.)
local BLOCK_ITEM = {
    { "redstone_wire", "redstone", "placed" },
    { "tripwire", "string", "placed" },
    { "wall_torch", "torch", "wall" },
    { "soul_wall_torch", "soul_torch", "wall" },
    { "redstone_wall_torch", "redstone_torch", "wall" },
    { "wheat", "wheat_seeds", "placed" },
    { "carrots", "carrot", "placed" },
    { "potatoes", "potato", "placed" },
    { "beetroots", "beetroot_seeds", "placed" },
    { "torchflower_crop", "torchflower_seeds", "placed" },
    { "pitcher_crop", "pitcher_pod", "placed" },
    { "melon_stem", "melon_seeds", "placed" },
    { "attached_melon_stem", "melon_seeds", "also" },
    { "pumpkin_stem", "pumpkin_seeds", "placed" },
    { "attached_pumpkin_stem", "pumpkin_seeds", "also" },
    { "cocoa", "cocoa_beans", "placed" },
    { "sweet_berry_bush", "sweet_berries", "placed" },
    { "cave_vines", "glow_berries", "placed" },
    { "cave_vines_plant", "glow_berries", "also" },
    { "kelp_plant", "kelp", "also" },
    { "twisting_vines_plant", "twisting_vines", "also" },
    { "weeping_vines_plant", "weeping_vines", "also" },
    { "big_dripleaf_stem", "big_dripleaf", "also" },
    { "bamboo_sapling", "bamboo", "also" },
}
-- The same by the end of the name, for every wood, colour, coral and head: the block's ending and the item's, all
-- wall forms.  (In order: a hanging sign's before a sign's, which would take it too going from item to block.)
local BLOCK_ITEM_ENDING = {
    { "_wall_hanging_sign", "_hanging_sign" },
    { "_wall_sign", "_sign" },
    { "_wall_banner", "_banner" },
    { "_wall_skull", "_skull" },
    { "_wall_head", "_head" },
    { "_coral_wall_fan", "_coral_fan" },
}
local ITEM_OF_BLOCK, BLOCK_OF_ITEM = {}, {}
for _, row in ipairs(BLOCK_ITEM) do
    local block, item, form = row[1], row[2], row[3]
    ITEM_OF_BLOCK[block] = item
    if form ~= "also" then
        BLOCK_OF_ITEM[item] = BLOCK_OF_ITEM[item] or {}
        BLOCK_OF_ITEM[item][form] = block
    end
end

-- A sign's text: lines of 15 characters at most, 4 lines at most (as CC:Tweaked writes it)
local SIGN_WIDTH, SIGN_LINES = 15, 4

-- Blocks you cannot click to place against, because they are not there or the next block replaces them
local NOT_CLICKABLE = {}
for _, short in ipairs({ "air", "cave_air", "void_air", "water", "flowing_water", "lava", "flowing_lava", "fire",
                         "soul_fire", "short_grass", "tall_grass", "fern", "large_fern", "dead_bush", "vine",
                         "seagrass", "tall_seagrass", "snow", "light", "bubble_column" }) do
    NOT_CLICKABLE["minecraft:" .. short] = true
end

-- The part of a name after the namespace.
local function shortName(name)
    local _, rest = text.cut(name, ":")
    return rest or name
end

-- The family a block or item is in: stairs, slab, log, chain, torch, lantern, sign, ladder, button, door, trapdoor,
-- fence_gate, chest, piston, observer, diode, fence, pane, wall, or block (anything else).
local function familyOf(name)
    local s = shortName(name)
    if FAMILY_EXACT[s] then return FAMILY_EXACT[s] end
    for _, row in ipairs(FAMILY_SUFFIX) do
        if text.endsWith(s, row[1]) then return row[2] end
    end
    return "block"
end

--------------------------------------------------------------------------
-- The table: what each way of placing gives
--------------------------------------------------------------------------

-- Rows from "when key=rule key=rule" strings.  `when` is what the game finds, in the order it looks: "beyond" (a
-- block to click beyond the target), "floor" (sideways only: a block under the target to click on its top),
-- "ceiling" (sideways only: a block above the target, for what hangs under one: a lantern),
-- "ahead" (from above or below only: a block beside the target the way the turtle faces, the first side a ladder
-- looks for to hang on) or "always" (the turtle's own block is clicked).  The rule for a key is a word, or heading, back, right, left,
-- along and across (see above), or for `block`: wall (the torch hangs on a wall) or item.
local function rows(...)
    local out = {}
    for i, line in ipairs({ ... }) do
        local words = text.words(line)
        local row = { when = words[1], set = {} }
        for w = 2, #words do
            local key, rule = text.cut(words[w], "=")
            row.set[key] = rule
        end
        out[i] = row
    end
    return out
end

-- A block with no state to speak of: any approach does, from any side
local function plain(sturdy, post)
    return { sturdy = sturdy, post = post, front = rows("always"), down = rows("always"), up = rows("always") }
end

-- Per family.  hang: it hangs on or stands on a solid block (beyond and floor then mean a block that can hold it, not
-- just one that can be clicked); onPost: standing, a post will hold it up too; sturdy = false: nothing hangs on it;
-- post: a post in the middle (a fence, a wall, a pane), which nothing hangs on but holds up on its top what stands on
-- a post (a torch, a standing sign); needs: what must be round the target; tall: two blocks (a door); vertical: it
-- may face up or down too; alias: other names for a state key.  An approach with no rows can not place it.
local FAMILIES = {
    block = plain(true),
    fence = plain(false, true),
    pane = plain(false, true),
    wall = plain(false, true),
    -- a stair faces the way the placer looks; the half is the click's: a top face or the side's lower part is the
    -- bottom half, an underside the top; with only the turtle's own block to click it faces back at the turtle
    stairs = {
        sturdy = false,
        front = rows("beyond facing=heading half=bottom", "floor facing=heading half=bottom", "always facing=back half=bottom"),
        down = rows("beyond facing=heading half=bottom", "always facing=heading half=top"),
        up = rows("beyond facing=heading half=top", "always facing=heading half=bottom"),
    },
    slab = {
        sturdy = false, alias = { half = "type" },
        front = rows("always type=bottom"),
        down = rows("beyond type=bottom", "always type=top"),
        up = rows("beyond type=top", "always type=bottom"),
    },
    -- a log lies along the axis of the face that was clicked
    log = {
        front = rows("beyond axis=along", "floor axis=y", "always axis=along"),
        down = rows("always axis=y"),
        up = rows("always axis=y"),
    },
    -- a chain lies along the axis of the face clicked, as a log does; it holds up and holds under a lantern or a torch
    chain = {
        sturdy = false, post = true,
        front = rows("beyond axis=along", "floor axis=y", "always axis=along"),
        down = rows("always axis=y"),
        up = rows("always axis=y"),
    },
    -- a lantern stands on the block below it if that holds it, else hangs under the block above (Minecraft looks
    -- down before up whatever is clicked; placed up it looks up first, and the turtle below holds nothing up)
    lantern = {
        hang = true, onPost = true, sturdy = false,
        front = rows("floor hanging=false", "ceiling hanging=true"),
        down = rows("beyond hanging=false"),
        up = rows("beyond hanging=true"),
    },
    -- a torch hangs on the block beyond (a wall torch, facing the turtle), or stands on the floor or the block below
    torch = {
        hang = true, onPost = true, sturdy = false,
        front = rows("beyond block=wall facing=back", "floor"),
        down = rows("beyond"),
        up = {},
    },
    -- a sign as a torch: on the wall beyond (the wall form, facing the turtle), or standing on the floor, its face
    -- turned back at the turtle (a rotation, see ROTATION_FACING)
    sign = {
        hang = true, onPost = true, sturdy = false,
        front = rows("beyond block=wall facing=back", "floor rotation=back"),
        down = rows("beyond rotation=back"),
        up = {},
    },
    -- a ladder hangs on a side: placed from above or below it goes on the side the turtle faces, if that holds it
    ladder = { hang = true, sturdy = false, front = rows("beyond facing=back"), down = rows("ahead facing=back"),
               up = rows("ahead facing=back") },
    button = {
        hang = true, sturdy = false,
        front = rows("beyond face=wall facing=back", "floor face=floor facing=heading"),
        down = rows("beyond face=floor facing=heading"),
        up = rows("beyond face=ceiling facing=heading"),
    },
    -- a door is two blocks: a solid block under it and the cell above free; it faces the way the placer does.
    -- It can only be placed sideways (from above or below the turtle is in the cell the upper half needs).
    door = {
        sturdy = false, tall = true, needs = { below = "sturdy", above = "free" },
        front = rows("beyond facing=heading", "floor facing=heading", "always facing=back"),
        down = {}, up = {},
    },
    trapdoor = {
        sturdy = false,
        front = rows("beyond facing=back half=bottom", "floor facing=back half=bottom", "always facing=heading half=bottom"),
        down = rows("beyond facing=back half=bottom", "always facing=back half=top"),
        up = rows("beyond facing=back half=top", "always facing=back half=bottom"),
    },
    fence_gate = {
        sturdy = false,
        front = rows("beyond facing=heading", "floor facing=heading", "always facing=back"),
        down = rows("always facing=heading"),
        up = rows("always facing=heading"),
    },
    -- chests and furnaces face back at the placer
    chest = {
        sturdy = false,
        front = rows("beyond facing=back", "floor facing=back", "always facing=heading"),
        down = rows("always facing=back"),
        up = rows("always facing=back"),
    },
    -- a piston, sticky piston, dispenser or dropper faces back at the placer, the opposite of the way it looks most
    -- nearly, up and down too: placing onto a floor or down onto a block it looks down; down with nothing below it
    -- looks up at the turtle, and with nothing beyond sideways it looks back at the turtle
    piston = {
        vertical = true,
        front = rows("beyond facing=back", "floor facing=up", "always facing=heading"),
        down = rows("beyond facing=up", "always facing=down"),
        up = rows("beyond facing=down", "always facing=up"),
    },
    -- an observer the other way round: its face looks where the placer looks
    observer = {
        vertical = true,
        front = rows("beyond facing=heading", "floor facing=down", "always facing=back"),
        down = rows("beyond facing=down", "always facing=up"),
        up = rows("beyond facing=up", "always facing=down"),
    },
    -- a repeater or comparator stands on a block and faces back at the placer, level (its delay or mode is not the
    -- turtle's to set); from below the turtle would be its floor
    diode = {
        sturdy = false, needs = { below = "sturdy" },
        front = rows("beyond facing=back", "floor facing=back", "always facing=heading"),
        down = rows("beyond facing=back"),
        up = {},
    },
}
T.PLACE_TABLE = FAMILIES                 -- (a plain field: a sim, or a person, may correct a row)

-- The state keys a family has, from its rows (alias names included)
local function keysOf(fam)
    local keys = {}
    for _, kind in ipairs({ "front", "down", "up" }) do
        for _, row in ipairs(fam[kind] or {}) do
            for key in pairs(row.set) do
                if key ~= "block" then keys[key] = true end
            end
        end
    end
    return keys
end

-- Keys a caller may name in opts, and the state key each one is for
local WANTED = { "facing", "half", "axis", "face", "type", "rotation", "hanging" }
-- Every option T.placeAt takes (one it doesn't is named, not ignored)
local PLACE_OPTS = { facing = true, half = true, axis = true, face = true, type = true, rotation = true, hanging = true,
                     toward = true, move = true, inside = true, tries = true, text = true, temp = true, digBelow = true,
                     exit = true }

--------------------------------------------------------------------------
-- What the game found out, kept
--------------------------------------------------------------------------

-- A row's id in the data file: family, approach and what it looks for
local function rowId(famName, kind, row) return famName .. " " .. kind .. " " .. row.when end

-- The learned rules: { [rowId] = { key = rule } }, read from the file (it is small; other programs may have added to it).
local function loadLearned()
    local learned = {}
    local data = fileio.read(T.dataPath(LEARN_FILE))
    for _, line in ipairs(data and text.lines(data) or {}) do
        local words = text.words(line)
        if #words >= 4 then
            local set = {}
            for w = 4, #words do
                local key, rule = text.cut(words[w], "=")
                if rule then set[key] = rule end
            end
            learned[words[1] .. " " .. words[2] .. " " .. words[3]] = set
        end
    end
    return learned
end

-- Write the learned rules back (or delete the file when there are none).
local function saveLearned(learned)
    local path = T.dataPath(LEARN_FILE)
    local lines = {}
    for id, set in pairs(learned) do
        local keys = {}
        for key in pairs(set) do keys[#keys + 1] = key end
        table.sort(keys)
        if #keys > 0 then
            local parts = {}
            for i, key in ipairs(keys) do parts[i] = key .. "=" .. set[key] end
            lines[#lines + 1] = id .. " " .. table.concat(parts, " ")
        end
    end
    table.sort(lines)
    if #lines == 0 then
        if fs.exists(path) then fs.delete(path) end
        return true
    end
    return fileio.write(path, table.concat(lines, "\n") .. "\n")
end

-- The rules of a row, with what was learned laid over the table's.
local function specOf(learned, famName, kind, row)
    local set = {}
    for key, rule in pairs(row.set) do set[key] = rule end
    for key, rule in pairs(learned[rowId(famName, kind, row)] or {}) do set[key] = rule end
    return set
end

--------------------------------------------------------------------------
-- Rules and values
--------------------------------------------------------------------------

-- The value a rule for the state key `key` gives on an approach with heading h (a compass name, a sign's rotation, an
-- axis or a plain word); nil if it needs the compass (base: the compass number of heading 0) and there isn't one.
local function valueOf(rule, h, base, key)
    local turns = RELATIVE[rule]
    if turns and key == "rotation" then return base and tostring(ROTATION_FACING[COMPASS[(base + h + turns) % 4]]) end
    if turns then return base and COMPASS[(base + h + turns) % 4] end
    if rule == "along" then return base and AXIS_OF[COMPASS[(base + h) % 4]] end
    if rule == "across" then return base and AXIS_OF[COMPASS[(base + h + 1) % 4]] end
    return rule
end

-- The rule that gives the observed value of a key on an approach with heading h, or nil if it can't be told.
local function ruleOf(key, value, h, base)
    if value == nil then return nil end
    value = tostring(value)
    if key == "facing" then
        if VERTICAL[value] then return value end
        if not base then return nil end
        for _, rule in ipairs(RELATIVE_NAMES) do
            if COMPASS[(base + h + RELATIVE[rule]) % 4] == value then return rule end
        end
        return nil
    end
    if key == "axis" then
        if value == "y" then return "y" end
        if not base then return nil end
        return value == AXIS_OF[COMPASS[(base + h) % 4]] and "along" or "across"
    end
    if key == "rotation" then
        -- (a rotation between the four a turtle gives can't be told as a rule)
        if not base then return nil end
        for _, rule in ipairs(RELATIVE_NAMES) do
            if ROTATION_FACING[COMPASS[(base + h + RELATIVE[rule]) % 4]] == tonumber(value) then return rule end
        end
        return nil
    end
    return value
end

-- The cell an approach acts on or stands in.  kind: front (stand level with the target, heading h, the block beyond
-- further on), down (stand over it), up (stand under it).
local function standFor(kind, h, x, y, z)
    if kind == "front" then
        local v = T.DELTA[h]
        return x - v[1], y, z - v[3]
    end
    return x, kind == "down" and y + 1 or y - 1, z
end
local function beyondFor(kind, h, x, y, z)
    if kind == "front" then
        local v = T.DELTA[h]
        return x + v[1], y, z + v[3]
    end
    return x, kind == "down" and y - 1 or y + 1, z
end
-- The direction the turtle looks and places in on an approach.
local function dirOf(kind, h) return kind == "front" and h or kind end
-- The cell beside the target the way the turtle faces (heading h): what a ladder placed from above or below hangs on.
local function aheadOf(h, x, y, z)
    local v = T.DELTA[h]
    return x + v[1], y, z + v[3]
end

-- The state keys that follow the way the turtle faces
local TURNING = { facing = true, axis = true, rotation = true }

-- Does the way the turtle faces change what it gets: a state that follows the heading, or a family with rows that
-- look at the side it faces (a ladder from above)?
local function headingMatters(fam, want)
    for key in pairs(want) do
        if TURNING[key] then return true end
    end
    for _, kind in ipairs({ "down", "up" }) do
        for _, row in ipairs(fam[kind]) do
            if row.when == "ahead" then return true end
        end
    end
    return false
end

--------------------------------------------------------------------------
-- What the map says
--------------------------------------------------------------------------

-- The map, if tl.world loads; nil otherwise.
local function mapOf()
    local map = T.need("map")
    return type(map) == "table" and map or nil
end

-- The block the map holds at x, y, z, or nil if it has never seen the cell.
local function nameAt(x, y, z)
    local map = mapOf()
    if not map then return nil end
    return (map.get(x, y, z))
end

local function clickable(name) return not NOT_CLICKABLE[name] end
-- Is the block one things hang on (a whole face to hold them)?
local function sturdy(name)
    if not clickable(name) then return false end
    local fam = FAMILIES[familyOf(name)]
    return fam.sturdy ~= false
end

-- Does the block hold up a block of family fam standing on its top: a whole face, or for a family that stands on a
-- post (a torch, a standing sign) a fence's, a wall's or a pane's post?
local function holdsOnTop(fam, name)
    if sturdy(name) then return true end
    return fam.onPost == true and clickable(name) and FAMILIES[familyOf(name)].post == true
end

-- A fact the table asks about, as true, false, or nil (the map has never seen the cell).  top: the block is the one
-- under the target (a floor, or beyond a placing down), which holds up what stands on it.
local function factAbout(fam, name, top)
    if name == nil then return nil end
    if fam.hang then return (top and holdsOnTop(fam, name)) or sturdy(name) end
    return clickable(name)
end

-- Which of the facts the table asks about is the block under the target, by approach
local TOP_FACT = { front = "floor", down = "beyond" }

-- The compass number of heading 0, from the world origin; nil with none set.
local function compassBase()
    local origin = T.need("origin")
    local o = origin and origin()
    return o and COMPASS_AT[o.facing] or nil
end

--------------------------------------------------------------------------
-- Planning: which approaches give the state wanted
--------------------------------------------------------------------------

-- The row an approach lands on, from the facts: { row, certain } and any rows it might land on if a fact is not
-- known; the first is the likeliest.  Rows that a fact rules out are left out.
local function rowsFor(fam, kind, facts)
    local out, certain = {}, true
    for _, row in ipairs(fam[kind]) do
        local f
        if row.when == "always" then f = true else f = facts[row.when] end
        if f == true then
            out[#out + 1] = { row = row, certain = certain }
            break
        elseif f == nil then
            out[#out + 1] = { row = row, certain = false }
            certain = false
        end
    end
    return out
end

-- Does the row, with what was learned, give every key of `want` on an approach with heading h?
local function gives(learned, famName, kind, row, want, h, base)
    local set = specOf(learned, famName, kind, row)
    for key, wanted in pairs(want) do
        if set[key] == nil or valueOf(set[key], h, base, key) ~= wanted then return false end
    end
    return true
end

-- Every approach that can give `want` at the target, nearest first, the sure ones before the guesses.  Each is
-- { kind, h, sx, sy, sz, row, certain, key }.  tried: the keys of the approaches already used.
local function plan(famName, fam, item, learned, want, tx, ty, tz, base, tried, dig)
    local apps = {}
    -- A half slab of the item's own kind may be one the game takes as replaceable and skips (then it clicks the
    -- next block): not a fact to plan on for sure, nor to learn from.
    local function fact(name, top)
        if famName == "slab" and name == item then return nil end
        return factAbout(fam, name, top)
    end
    local turning = headingMatters(fam, want)
    for _, kind in ipairs({ "front", "down", "up" }) do
        for h = 0, 3 do
            if (kind == "front" or turning or h == T.dir) and #fam[kind] > 0 then
                local sx, sy, sz = standFor(kind, h, tx, ty, tz)
                local bx, by, bz = beyondFor(kind, h, tx, ty, tz)
                local facts = { beyond = fact(nameAt(bx, by, bz), TOP_FACT[kind] == "beyond") }
                if kind == "front" then
                    facts.floor, facts.ceiling = fact(nameAt(tx, ty - 1, tz), true), fact(nameAt(tx, ty + 1, tz), true)
                else
                    facts.ahead = fact(nameAt(aheadOf(h, tx, ty, tz)))
                end
                local stand = nameAt(sx, sy, sz)
                if not (stand and clickable(stand) and not dig) then
                    for _, c in ipairs(rowsFor(fam, kind, facts)) do
                        if gives(learned, famName, kind, c.row, want, h, base) then
                            -- (the heading only tells approaches apart when the state depends on it)
                            local key = kind .. " " .. sx .. "," .. sy .. "," .. sz .. " " .. c.row.when
                                .. (turning and (" " .. h) or "")
                            if not tried[key] then
                                apps[#apps + 1] = { kind = kind, h = h, sx = sx, sy = sy, sz = sz, row = c.row,
                                                    certain = c.certain, key = key,
                                                    cost = T.dist(T.pos, { x = sx, y = sy, z = sz }) + T.turnsTo(h) }
                            end
                            break
                        end
                    end
                end
            end
        end
    end
    table.sort(apps, function(a, b)
        if a.certain ~= b.certain then return a.certain end
        if a.cost ~= b.cost then return a.cost < b.cost end
        return a.key < b.key
    end)
    return apps
end

-- Words for an approach and for where the block it needs is, in a message
local KIND_WORDS = { front = "sideways", down = "from above", up = "from below" }
local FACT_WORDS = {
    front = { beyond = "beyond the target", floor = "under the target", ceiling = "above the target" },
    down = { beyond = "under the target", ahead = "beside the target the way the turtle faces" },
    up = { beyond = "above the target", ahead = "beside the target the way the turtle faces" },
}
local SHOWN = 6                              -- approaches a message names, at most

-- An approach to the target in words: "sideways from 0,0,2", with the way the turtle faces when that matters ("...
-- facing north").
local function approachWords(kind, h, tx, ty, tz, base, turning)
    local sx, sy, sz = standFor(kind, h, tx, ty, tz)
    local words = KIND_WORDS[kind] .. " from " .. sx .. "," .. sy .. "," .. sz
    if turning then words = words .. " facing " .. (base and COMPASS[(base + h) % 4] or ("heading " .. h)) end
    return words
end

-- What a row gives of the keys wanted, where it differs: "half=bottom", and true if a key that follows the heading
-- (facing, axis) is among them.
local function givesWords(learned, famName, kind, row, want, h, base)
    local set, parts, keys, turned = specOf(learned, famName, kind, row), {}, {}, false
    for key in pairs(want) do keys[#keys + 1] = key end
    table.sort(keys)
    for _, key in ipairs(keys) do
        local got = set[key] and valueOf(set[key], h, base, key)
        if got ~= want[key] then
            parts[#parts + 1] = key .. "=" .. tostring(got or "none")
            turned = turned or TURNING[key] == true
        end
    end
    return table.concat(parts, " "), turned
end

-- Why one approach can't give `want`, in words, or nil if the table says it can (or may: a fact the map doesn't know).
-- The stand is taken; or the row that would give it needs a block the map says isn't there; or it lands on a row that
-- gives something else.  An approach that only faces the wrong way is nil too: the one facing the right way says more.
-- A second result is true when the stand is what is wrong, whichever way the turtle would face; a third, the fact the
-- row needs ("beyond", "floor", ...) when a missing block is what is wrong.
local function whyNotOne(famName, fam, learned, want, kind, h, tx, ty, tz, base, dig, fact)
    local sx, sy, sz = standFor(kind, h, tx, ty, tz)
    local stand = nameAt(sx, sy, sz)
    if stand and clickable(stand) and not dig then return "the map has " .. stand .. " there", true end
    local bx, by, bz = beyondFor(kind, h, tx, ty, tz)
    local ax, ay, az = aheadOf(h, tx, ty, tz)
    local cells = { beyond = { bx, by, bz }, floor = { tx, ty - 1, tz }, ceiling = { tx, ty + 1, tz }, ahead = { ax, ay, az } }
    local names = { beyond = nameAt(bx, by, bz), floor = nameAt(tx, ty - 1, tz), ceiling = nameAt(tx, ty + 1, tz),
                    ahead = nameAt(ax, ay, az) }
    local facts = { beyond = fact(names.beyond, TOP_FACT[kind] == "beyond") }
    if kind == "front" then
        facts.floor, facts.ceiling = fact(names.floor, true), fact(names.ceiling, true)
    else
        facts.ahead = fact(names.ahead)
    end
    local needed
    for _, row in ipairs(fam[kind]) do
        local f = row.when == "always" or facts[row.when]
        if gives(learned, famName, kind, row, want, h, base) then
            if f ~= false then return nil end
            needed = needed or row.when
        elseif f == true then
            if needed then break end
            local words, turned = givesWords(learned, famName, kind, row, want, h, base)
            if turned then return nil end
            return "gives " .. words
        end
    end
    if not needed then return nil end
    local c = cells[needed]
    return "needs " .. (fam.hang and "a block to hang it on " or "a block ") .. FACT_WORDS[kind][needed] .. ", and the map has "
        .. tostring(names[needed] or "nothing it knows") .. " at " .. c[1] .. "," .. c[2] .. "," .. c[3], false, needed
end

-- Why the approaches the table rules out can't give `want` at the target: a list of "<approach>: <why>", in the order
-- plan goes through them, each said once; and true if a sideways one wants a block beyond the target that isn't there.
local function whyNot(famName, fam, item, learned, want, tx, ty, tz, base, dig)
    local out, said, beyond = {}, {}, false
    local function fact(name, top)
        if famName == "slab" and name == item then return nil end
        return factAbout(fam, name, top)
    end
    local turning = headingMatters(fam, want)
    for _, kind in ipairs({ "front", "down", "up" }) do
        for h = 0, 3 do
            if (kind == "front" or turning or h == T.dir) and #fam[kind] > 0 then
                local why, standing, needed = whyNotOne(famName, fam, learned, want, kind, h, tx, ty, tz, base, dig, fact)
                beyond = beyond or (kind == "front" and needed == "beyond")
                local line = why and approachWords(kind, h, tx, ty, tz, base, turning and not standing) .. ": " .. why
                if line and not said[line] then
                    said[line] = true
                    out[#out + 1] = line
                end
            end
        end
    end
    return out, beyond
end

-- A list in a message: the first SHOWN, joined with "; ", and how many more.
local function listed(list)
    local shown = {}
    for i = 1, math.min(#list, SHOWN) do shown[i] = list[i] end
    local s = table.concat(shown, "; ")
    if #list > SHOWN then s = s .. "; and " .. (#list - SHOWN) .. " more" end
    return s
end

-- The state keys asked for in opts, as { stateKey = value }, or nil and why.
local function wantsOf(item, famName, fam, opts)
    local keys, want = keysOf(fam), {}
    for _, name in ipairs(WANTED) do
        local value = opts[name]
        if value ~= nil then
            local key = fam.alias and fam.alias[name] or name
            if not keys[key] then
                local have = {}
                for k in pairs(keys) do have[#have + 1] = k end
                table.sort(have)
                return nil, item .. " has no " .. name .. " to place by" ..
                    (#have > 0 and (" (it has: " .. table.concat(have, ", ") .. ")") or " (it has no state)")
            end
            want[key] = tostring(value)
        end
    end
    if want.facing and COMPASS_AT[want.facing] == nil and not (fam.vertical and VERTICAL[want.facing]) then
        return nil, fam.vertical and "facing is a compass name (north, east, south or west), up or down"
            or "facing is a compass name: north, east, south or west"
    end
    if want.rotation then
        local n = tonumber(want.rotation)
        local ok = false
        for _, r in ipairs(ROTATIONS) do ok = ok or r == n end
        if not ok then
            return nil, "a turtle turns a standing sign only in quarter turns: rotation 0 (its face south), 4 (west), 8 (north) " ..
                "or 12 (east); opts.toward picks the nearest to a reader"
        end
        want.rotation = tostring(math.floor(n))
    end
    return want
end

-- What a door needs round the target, from the map: nil if all is well or not known, else why not.
local function needsMet(fam, tx, ty, tz)
    local needs = fam.needs
    if not needs then return nil end
    local below, above = nameAt(tx, ty - 1, tz), nameAt(tx, ty + 1, tz)
    if needs.below == "sturdy" and below and not sturdy(below) then
        return "needs a solid block under it, and the map has " .. below .. " at " .. tx .. "," .. (ty - 1) .. "," .. tz
    end
    if needs.above == "free" and above and clickable(above) then
        return "needs the cell above free, and the map has " .. above .. " at " .. tx .. "," .. (ty + 1) .. "," .. tz
    end
    return nil
end

-- A sign's text as its lines: opts.text (a string, or a list of strings taken as joined by newlines) wrapped to
-- SIGN_WIDTH, each newline starting a line; nil and why if it is not a sign, or the text takes more than SIGN_LINES lines.
local function signLines(item, famName, said)
    if famName ~= "sign" then return nil, "only a sign takes text, and " .. item .. " is not one" end
    if type(said) == "table" then
        for i, line in ipairs(said) do
            if type(line) ~= "string" then return nil, "line " .. i .. " of a sign's text is a " .. type(line) .. ", not a string" end
        end
        said = table.concat(said, "\n")
    end
    if type(said) ~= "string" then return nil, "a sign's text is a string, or a list of lines" end
    local lines = text.wrap(convert.fromUTF8(said), SIGN_WIDTH)   -- (as the game shows it: CC passes a byte a character)
    if #lines > SIGN_LINES then
        return nil, "a sign holds " .. SIGN_LINES .. " lines of " .. SIGN_WIDTH .. " characters, and this text wraps to " .. #lines
            .. " (\"" .. table.concat(lines, "|") .. "\")"
    end
    return lines
end

--------------------------------------------------------------------------
-- Looking at what came out, and taking it back
--------------------------------------------------------------------------

-- Look at the target from the stand: the block's name and state, or nil if nothing is there.
local function lookAtTarget(kind, h)
    local ok, data = T.look(dirOf(kind, h))
    if ok and type(data) == "table" and data.name then return data.name, data.state or {} end
    return nil
end

-- Is the block the item's: its own name, or one the item places or the block becomes (a wall torch, redstone dust)?
local function isItem(item, name)
    return name ~= nil and (name == item or T.itemOfBlock(name) == item)
end

-- Does the block at the target have the item's name (or the wall version of it) and every state wanted?
local function accepted(item, want, name, state)
    if not isItem(item, name) then return false end
    for key, wanted in pairs(want) do
        if tostring(state[key]) ~= wanted then return false end
    end
    return true
end

-- Learn from what came out: for the row the approach used, note every key where it differs from the table's rule
-- (or drop a note that has become the table's rule).  True if the notes changed.
local function learnFrom(learned, famName, kind, row, h, base, item, name, state)
    local keys = {}
    for key in pairs(row.set) do keys[key] = true end
    local wallForm = T.blockOfItem(item, "wall")
    if wallForm then keys.block = true end
    local id = rowId(famName, kind, row)
    local set = learned[id] or {}
    local changed = false
    for key in pairs(keys) do
        local seen
        if key == "block" then
            seen = (name == wallForm and "wall") or (isItem(item, name) and "item") or nil
        else
            seen = ruleOf(key, state[key], h, base)
        end
        if seen then
            local builtin = row.set[key] or (key == "block" and "item" or nil)
            local keep = seen ~= builtin and seen or nil
            if set[key] ~= keep then
                set[key] = keep
                changed = true
            end
        end
    end
    local any = false
    for _ in pairs(set) do any = true end
    learned[id] = any and set or nil
    return changed
end

-- Forget what T.placeAt has learnt (the data file .placements), for one family ("stairs", "slab", "torch", ... as
-- T.placeInfo names them) or for all.  True, or false and why.
--
-- A wrong row learnt (say from a block the map had wrong) is laid over the table from then on; this puts the table's
-- rows back.
function T.forgetPlacements(family)
    local learned = loadLearned()
    if family == nil then
        learned = {}
    else
        if not FAMILIES[family] then return false, "no family called " .. tostring(family) end
        for id in pairs(learned) do
            if text.startsWith(id, family .. " ") then learned[id] = nil end
        end
    end
    if not saveLearned(learned) then return false, "couldn't write the learnt placements" end
    return true
end

-- Dig the block at x, y, z, in direction d from the turtle, that this call has just placed.  It is the library's own
-- work, so a protected area round it, or a chest that the digs refuse, doesn't stop it.  True, or false and why.
local function digOwn(d, x, y, z)
    local area = T.guarded(x, y, z)
    local before = T.cfg.digContainers
    T.cfg.digContainers = true
    local ok, dug, why = pcall(function()
        if area then return T.inside(area, T.digDir, d) end
        return T.digDir(d)
    end)
    T.cfg.digContainers = before
    if not ok then error(dug, 0) end
    return dug, why
end
-- The same for the block in the target cell, from the stand of an approach.
local function takeBack(kind, h, x, y, z) return digOwn(dirOf(kind, h), x, y, z) end

-- Note the block that is now at the target in the map (the map hears a placement by the item's name only).
local function noteInMap(x, y, z, name, state)
    local map = mapOf()
    if map then map.set(x, y, z, name, state) end
end

-- "key=value, key=value" of a state, for a message.
local function describe(name, state)
    local keys = {}
    for key in pairs(state or {}) do keys[#keys + 1] = key end
    table.sort(keys)
    local parts = {}
    for i, key in ipairs(keys) do parts[i] = key .. "=" .. tostring(state[key]) end
    return shortName(name) .. (#parts > 0 and ("[" .. table.concat(parts, ",") .. "]") or "")
end

--------------------------------------------------------------------------
-- Support: a block to place against put there for a moment, the floor dug to stand in
--------------------------------------------------------------------------

-- What a temporary block may be, the first found on board (opts.temp names another): plain blocks that come back as
-- themselves when dug
local TEMP_BLOCKS = { "cobblestone", "cobbled_deepslate", "dirt", "netherrack", "blackstone", "*_planks", "*bricks" }
-- Floors that come back as themselves when dug (with a pickaxe), so digBelow can put back the one it dug: those, and
-- these.  (Stone gives cobblestone, deepslate cobbled deepslate, grass dirt: those must be carried.)
local SELF_DROPS = { "soul_soil", "soul_sand", "basalt", "polished_basalt", "smooth_basalt", "mossy_cobblestone",
                     "andesite", "diorite", "granite", "polished_*", "tuff", "calcite", "end_stone", "smooth_stone",
                     "sandstone", "red_sandstone", "terracotta", "*_terracotta", "*_concrete", "*_wool", "*_log", "*_wood",
                     "*_stem", "*_hyphae", "quartz_block", "purpur_block", "obsidian", "crying_obsidian" }
for _, g in ipairs(TEMP_BLOCKS) do SELF_DROPS[#SELF_DROPS + 1] = g end
local dropsItself = T.nameTest(SELF_DROPS)

-- Does digging the block give the block back (planks, bricks, a log: yes; stone, grass, glowstone: no)?  The list
-- placeAt's opts.digBelow and T.replace's go by to put a dug floor back; a block it doesn't know is a no.
function T.dropsItself(name)
    return type(name) == "string" and dropsItself(name)
end
local AIRS = { [AIR] = true, ["minecraft:cave_air"] = true }
-- The cells beside a cell, as directions
local SIDES = { "up", "down", 0, 1, 2, 3 }

-- A cell as { x, y, z } or { x =, y =, z = }: its x, y, z, or nil if it isn't one of whole numbers.
local function cellOf(c)
    if type(c) ~= "table" then return nil end
    local xyz = { c.x or c[1], c.y or c[2], c.z or c[3] }
    for i = 1, 3 do
        if type(xyz[i]) ~= "number" or xyz[i] ~= math.floor(xyz[i]) then return nil end
    end
    return xyz[1], xyz[2], xyz[3]
end

-- (ADR-0015 D5) Would a block at x, y, z close the turtle in: no way out, through cells the map shows empty (air or
-- water) or has never seen, to `exit` ({ x, y, z }), or with none to a cell OPEN_AT blocks from where it stands?
-- Why, if so; nil if there is a way, or the search can't tell (it looks at SEAL_CELLS cells at most).  A way out that
-- needs a dig (through the build) isn't one.
local OPEN_AT, SEAL_CELLS = 12, 4000
local PASSES = { [AIR] = true, ["minecraft:cave_air"] = true, ["minecraft:water"] = true }
local function closesIn(x, y, z, exit)
    local start = T.here()
    local key = function(a, b, c) return a .. "," .. b .. "," .. c end
    local target = key(x, y, z)
    local seen, queue, head = { [key(start.x, start.y, start.z)] = true, [target] = true }, { start }, 1
    local goal = exit and key(cellOf(exit))
    while queue[head] do
        local c = queue[head]
        head = head + 1
        if head > SEAL_CELLS then return nil end
        for _, d in ipairs(SIDES) do
            local v = T.DELTA[d]
            local nx, ny, nz = c.x + v[1], c.y + v[2], c.z + v[3]
            local k = key(nx, ny, nz)
            if k == goal and k ~= target then return nil end          -- (the cell being placed is no way out)
            if not seen[k] then
                seen[k] = true
                local name = nameAt(nx, ny, nz)
                if name == nil or PASSES[name] then
                    if not goal and (name == nil or math.max(math.abs(nx - start.x), math.abs(ny - start.y), math.abs(nz - start.z)) >= OPEN_AT) then
                        return nil
                    end
                    queue[#queue + 1] = { x = nx, y = ny, z = nz }
                end
            end
        end
    end
    if goal then
        return "no way from " .. T.posKey(start) .. " to opts.exit " .. goal .. " after it (the map shows none round)"
    end
    return "the turtle at " .. T.posKey(start) .. " is closed in after it: the map shows no way out of the " .. (head - 1) ..
        " cells it's in but by digging"
end

-- A block on board to put somewhere for a moment, not the item being placed: its name, or nil.
local function tempBlock(item, choice)
    for _, g in ipairs(choice and { choice } or TEMP_BLOCKS) do
        local test = T.nameTest(g)
        local slot = T.findSlot(function(name) return name ~= item and test(name) end)
        if slot then return turtle.getItemDetail(slot).name end
    end
    return nil
end

-- A cell beside x, y, z that the map says is air, but not the one in direction `but`: its x, y, z, or nil.
local function freeBeside(x, y, z, but)
    for _, d in ipairs(SIDES) do
        local v = T.DELTA[d]
        local name = nameAt(x + v[1], y + v[2], z + v[3])
        if d ~= but and name and AIRS[name] then return x + v[1], y + v[2], z + v[3] end
    end
    return nil
end

-- A floor cell beside the floor at fx, fy, fz to go in by when nothing beside the floor is free (ADR-0013 D7): one with
-- air above it (the cell beside the target), a block the digs take, not protected (T.guarded) and with no liquid
-- beside it (T.liquidNear); the nearest to the turtle.  { x, y, z, name }, or nil and why each one won't do (a list).
local function neighbourExit(fx, fy, fz)
    local best, bestCost, whys = nil, nil, {}
    for h = 0, 3 do
        local v = T.DELTA[h]
        local nx, nz = fx + v[1], fz + v[3]
        local name, above = nameAt(nx, fy, nz), nameAt(nx, fy + 1, nz)
        local why
        if not (name and above) then why = "the map doesn't know it or the cell above it"
        elseif not AIRS[above] then why = "the map has " .. above .. " above it"
        elseif not clickable(name) then why = "the map has " .. name .. " there"
        elseif T.neverDig(name) then why = name .. " is never dug"
        elseif T.guarded(nx, fy, nz) then why = "in the protected area " .. T.guarded(nx, fy, nz)
        else
            local lq, lx, ly, lz = T.liquidNear(nx, fy, nz)
            if lq then why = lq .. " beside it at " .. lx .. "," .. ly .. "," .. lz end
        end
        if why then
            whys[#whys + 1] = nx .. "," .. fy .. "," .. nz .. ": " .. why
        else
            local cost = T.dist(T.pos, { x = nx, y = fy + 1, z = nz })
            if not bestCost or cost < bestCost then best, bestCost = { x = nx, y = fy, z = nz, name = name }, cost end
        end
    end
    if best then return best end
    return nil, whys
end

local COUNT_WORDS = { "one", "two" }

-- What putting back the floor cells dug (names: the floor's, and a neighbour's dug with it) needs that isn't there, added
-- to notes, every need at once: a block that drops itself comes back from the dig (a free slot for it, unless some are
-- on board already); any other must be carried, one for each cell.
local function floorNeeds(names, notes)
    local count, order = {}, {}
    for _, name in ipairs(names) do
        if not count[name] then order[#order + 1] = name end
        count[name] = (count[name] or 0) + 1
    end
    local slots, theirs = 0, {}
    for _, name in ipairs(order) do
        local have = T.countItem(name)
        if dropsItself(name) then
            if have == 0 then slots, theirs[#theirs + 1] = slots + 1, name end
        elseif have < count[name] then
            local more = count[name] - have
            notes[#notes + 1] = "opts.digBelow puts the floor back with the same block: carry " .. COUNT_WORDS[more] .. " " .. name ..
                (more == 1 and " (the one dug may drop something else)" or " (the ones dug may drop something else)")
        end
    end
    if slots > T.freeSlots() then
        notes[#notes + 1] = "opts.digBelow puts the floor back with the " .. table.concat(theirs, " and the ") .. " it digs: free " ..
            (slots == 1 and "a slot for it" or (slots .. " slots for them")) .. " (or carry one)"
    end
end

-- The ways to place from below with support, for when the plain ones have run out, and why there are none if so (a
-- list, for the message).  A top half (a slab, stair or trapdoor) is placed from below against a block above the
-- target; with nothing there, a temporary block goes there first (opts.temp, or one of TEMP_BLOCKS on board) and is
-- taken away after, from a free cell beside it.  With a floor under the target, only when opts.digBelow says so: the
-- floor is dug to stand in, and put back after with the same block from a free cell beside it (one on board, or for a
-- floor that drops itself a free slot for the one dug).  On solid ground, with no free cell beside the floor, a floor
-- cell beside it (neighbourExit) is dug and stood in too, the floor dug from there, and both put back.  Each way is an
-- approach as plan gives them, with support = { temp, floor, exit } (the names of the temporary block and of the floor
-- dug; the neighbour's cell and name).  The notes say every need not met.
local function supportPlans(famName, fam, item, learned, want, tx, ty, tz, base, tried, opts)
    local apps, notes = {}, {}
    local above, below = nameAt(tx, ty + 1, tz), nameAt(tx, ty - 1, tz)
    local temp, floor = above ~= nil and AIRS[above] == true, below ~= nil and clickable(below)
    if fam.hang or #fam.up == 0 or not (temp or floor) or not (temp or clickable(above or AIR)) then return apps, notes end
    local turning, rowFor = headingMatters(fam, want), {}
    for h = 0, 3 do
        for _, row in ipairs(fam.up) do
            if (turning or h == T.dir) and not rowFor[h] and row.when == "beyond" and gives(learned, famName, "up", row, want, h, base) then
                rowFor[h] = row
            end
        end
    end
    if next(rowFor) == nil then return apps, notes end
    local at = tx .. "," .. (ty - 1) .. "," .. tz
    local exit
    if floor then
        if not opts.digBelow then
            notes[#notes + 1] = "from below it needs to stand where the floor is (" .. below .. " at " .. at .. "): opts.digBelow = true " ..
                "digs it, places from there and puts the same block back"
        end
        local whys
        if not freeBeside(tx, ty - 1, tz, "up") then exit, whys = neighbourExit(tx, ty - 1, tz) end
        floorNeeds({ below, exit and exit.name or nil }, notes)
        if whys then
            notes[#notes + 1] = "opts.digBelow needs a way out of the floor at " .. at .. " to put it back from, and the map shows " ..
                "no free cell beside the floor, nor a floor cell beside it to dig and put back too (" .. table.concat(whys, "; ") .. ")"
        end
    end
    local tempName = temp and tempBlock(item, opts.temp) or nil
    if temp and not tempName then
        notes[#notes + 1] = "from below it needs a block to put above it for a moment, and there is none on board (cobblestone, " ..
            "dirt, planks, bricks; opts.temp names another)"
    elseif temp and not freeBeside(tx, ty + 1, tz, "down") then
        notes[#notes + 1] = "from below it needs a block above it for a moment, and the map shows no free cell beside " .. tx .. "," ..
            (ty + 1) .. "," .. tz .. " to take it away from"
    end
    if #notes > 0 then return apps, notes end
    for h, row in pairs(rowFor) do
        local key = "up support " .. h
        if not tried[key] then
            apps[#apps + 1] = { kind = "up", h = h, sx = tx, sy = ty - 1, sz = tz, row = row, certain = false, key = key,
                                support = { temp = tempName, floor = floor and below or nil, exit = exit }, cost = T.turnsTo(h) }
        end
    end
    table.sort(apps, function(a, b) return a.cost < b.cost or (a.cost == b.cost and a.h < b.h) end)
    return apps, notes
end

-- Take away a block this call put at x, y, z for a moment, from a free cell beside it.  nil, or why it is still there.
local function takeAway(x, y, z, move)
    local bx, by, bz = freeBeside(x, y, z)
    if not bx then return "no free cell beside it to dig it from" end
    local ok, why = T.moveTo(bx, by, bz, move)
    if not ok then return "couldn't get beside it: " .. tostring(why) end
    local dug, digWhy = digOwn(T.dirTo({ x = x, y = y, z = z }), x, y, z)
    if not dug then return "couldn't dig it: " .. tostring(digWhy) end
    return nil
end

-- Put back the floor dug at x, y, z: the same block, the way round it was (the state placeAt can be asked for), or
-- failing that the same block as it comes.  nil, or why it isn't back.
local function putBack(x, y, z, name, state, move)
    local opts = { move = move }
    for key in pairs(T.placeInfo(name).keys) do
        if state and state[key] ~= nil then opts[key] = tostring(state[key]) end
    end
    local placed, why = T.placeAt(x, y, z, name, opts)
    if placed then return nil end
    placed = T.placeAt(x, y, z, name, { move = move })
    if placed then return nil end
    return why
end

-- Into the floor's cell at fx, fy, fz by way of the neighbour e (ADR-0013 D7): from the cell above it, dig it and step
-- down; dig the floor sideways (it should be floorName) and step in.  Returns what was dug, { n, f } ({ name, state } of
-- the neighbour and of the floor, nil if not dug), and why it stopped, if it did.  Both digs are the wrapped dig's, so
-- a protected area holds and the undo journal writes them down.
local function inByNeighbour(e, floorName, fx, fy, fz, move)
    local dug, where = {}, e.x .. "," .. e.y .. "," .. e.z
    local ok, why = T.moveTo(e.x, e.y + 1, e.z, move)
    if not ok then return dug, "couldn't get over the floor beside it at " .. where .. ": " .. tostring(why) end
    local seen, data = T.look("down")
    local name = seen and type(data) == "table" and data.name or nil
    if name ~= e.name then return dug, "the floor beside it at " .. where .. " is " .. tostring(name) .. " now, not " .. e.name end
    local done, digWhy = T.digDir("down")
    if not done then return dug, "couldn't dig the floor beside it at " .. where .. ": " .. tostring(digWhy) end
    dug.n = { name = name, state = data.state }
    if not T.moveDir("down") then return dug, "couldn't step into the floor beside it at " .. where end
    local toFloor = T.dirTo({ x = fx, y = fy, z = fz })
    seen, data = T.look(toFloor)
    name = seen and type(data) == "table" and data.name or nil
    if name ~= floorName then return dug, "the floor is " .. tostring(name) .. " now, not " .. floorName end
    done, digWhy = T.digDir(toFloor)
    if not done then return dug, "couldn't dig the floor: " .. tostring(digWhy) end
    dug.f = { name = name, state = data.state }
    if not T.moveDir(toFloor) then return dug, "couldn't step into the floor's cell" end
    return dug
end

-- Place the item from below with an approach's support: the temporary block put above the target (from the target
-- cell), the floor dug and stepped into (from the target cell, or on solid ground by way of a neighbour dug too) or the
-- cell below walked to, the item placed up, a wrong block dug out at once; then the floor put back (and the neighbour,
-- from above it) and the temporary block taken away.  Returns { name, state, good, failed, left }: what is at the
-- target, whether it is as wanted, why it didn't place, and what is left undone (a floor not back, the temporary block
-- still there).
local function placeWithSupport(app, item, want, message, move, x, y, z)
    local s, out = app.support, {}
    local ok, why = T.moveTo(x, y, z, move)
    if not ok then out.failed = "couldn't get to " .. x .. "," .. y .. "," .. z .. ": " .. tostring(why); return out end
    local placed, placeWhy
    if s.temp then
        T.selectItem(s.temp)
        placed, placeWhy = T.placeDir("up")
        if not placed then out.failed = "couldn't put a " .. s.temp .. " above it: " .. tostring(placeWhy); return out end
    end
    local floor, floorState, besideDug
    if s.floor and s.exit then
        local dug, failed = inByNeighbour(s.exit, s.floor, x, y - 1, z, move)
        if dug.f then floor, floorState = dug.f.name, dug.f.state end
        besideDug, out.failed = dug.n, failed
    elseif s.floor then
        local seen, data = T.look("down")
        floor = seen and type(data) == "table" and data.name or nil
        floorState = floor and data.state
        if floor ~= s.floor then
            out.failed, floor = "the floor is " .. tostring(floor) .. " now, not " .. s.floor, nil
        else
            local dug, digWhy = T.digDir("down")
            if not dug then
                out.failed, floor = "couldn't dig the floor: " .. tostring(digWhy), nil
            elseif not T.moveDir("down") then
                out.failed = "couldn't step into the floor's cell"
            end
        end
    else
        ok, why = T.moveTo(x, y - 1, z, move)
        if not ok then out.failed = "couldn't get under it: " .. tostring(why) end
    end
    if not out.failed then
        T.face(app.h)
        T.selectItem(item)
        placed, placeWhy = T.placeDir("up", message)
        if placed then out.name, out.state = lookAtTarget("up") end
        if not out.name then
            out.failed = placed and "nothing there after" or ("the game refused (" .. tostring(placeWhy) .. ")")
        else
            noteInMap(x, y, z, out.name, out.state)
            out.good = accepted(item, want, out.name, out.state)
            if not out.good and not takeBack("up", app.h, x, y, z) then out.left = "couldn't dig out the wrong " .. out.name end
        end
    end
    local undone = { out.left }
    local e = s.exit
    if floor then
        -- (by way of a neighbour: from its cell, the only one free beside the floor)
        if e then T.moveTo(e.x, e.y, e.z, move) end
        local notBack = putBack(x, y - 1, z, floor, floorState, move)
        if notBack then undone[#undone + 1] = "the floor dug at " .. x .. "," .. (y - 1) .. "," .. z .. " is not back: " .. notBack end
    end
    if besideDug then
        T.moveTo(e.x, e.y + 1, e.z, move)
        local notBack = putBack(e.x, e.y, e.z, besideDug.name, besideDug.state, move)
        if notBack then undone[#undone + 1] = "the floor dug beside it at " .. e.x .. "," .. e.y .. "," .. e.z .. " is not back: " .. notBack end
    end
    if s.temp then
        local left = takeAway(x, y + 1, z, move)
        if left then
            undone[#undone + 1] = "the " .. s.temp .. " put at " .. x .. "," .. (y + 1) .. "," .. z .. " for a moment is still there: " .. left
        end
    end
    out.left = #undone > 0 and table.concat(undone, "; ") or nil
    return out
end

-- What an approach's support is, for a message: " with a cobblestone above it for a moment, in the floor dug out (by way
-- of 0,-1,2, dug too)"
local function supportWords(s)
    return (s.temp and (" with a " .. s.temp .. " above it for a moment") or "") .. (s.floor and (", in the floor dug out") or "")
        .. (s.exit and (" (by way of " .. s.exit.x .. "," .. s.exit.y .. "," .. s.exit.z .. ", dug too)") or "")
end

--------------------------------------------------------------------------
-- A sign turned toward a reader
--------------------------------------------------------------------------

-- The headings nearest the way dx, dz (in the turtle's frame) points: one, or two when it is a diagonal.
local function headingsToward(dx, dz)
    local hx, hz = dx > 0 and 1 or 3, dz > 0 and 0 or 2
    if math.abs(dz) > math.abs(dx) then return { hz } end
    if math.abs(dx) > math.abs(dz) then return { hx } end
    return { hz, hx }
end

local atan2 = math.atan2 or math.atan       -- (Lua 5.2 has atan2; 5.3 on takes two numbers in atan)

-- opts with opts.toward (the reader's cell) turned into the state that shows a sign's face to the reader: a wall sign's
-- facing when the map shows a sturdy block behind the cell (on the far side from the reader), else a standing sign's
-- rotation, the nearest of the four a turtle gives.  Returns the opts and what was decided: { form = "wall", facing,
-- behind } or { form = "standing", rotation, wanted (the reader's way in sixteenths), off (degrees), note }; or nil and why.
local function towardOpts(x, y, z, item, opts)
    if familyOf(item) ~= "sign" then return nil, "opts.toward turns a sign toward a reader, and " .. item .. " is not one" end
    if opts.facing ~= nil or opts.rotation ~= nil then
        return nil, "opts.toward sets the sign's facing or rotation itself: leave those out"
    end
    local rx, _, rz = cellOf(opts.toward)
    if not rx then return nil, "opts.toward is the reader's cell: { x, y, z }, whole numbers" end
    local base = compassBase()
    if not base then return nil, "opts.toward needs the world origin: T.setOrigin(x, y, z, facing)" end
    local dx, dz = rx - x, rz - z
    if dx == 0 and dz == 0 then
        return nil, "the reader is straight above or below the sign at " .. x .. "," .. y .. "," .. z .. ": a sign can't face up or down"
    end
    local out = {}
    for k, v in pairs(opts) do out[k] = v end
    out.toward = nil
    for _, h in ipairs(headingsToward(dx, dz)) do
        local v = T.DELTA[h]
        local bx, bz = x - v[1], z - v[3]
        local behind = nameAt(bx, y, bz)
        if behind and sturdy(behind) then
            out.facing = COMPASS[(base + h) % 4]
            return out, { form = "wall", facing = out.facing, behind = { x = bx, y = y, z = bz } }
        end
    end
    -- the reader's way in quarter turns clockwise from north (heading 0 is +z, a right turn +x), then in sixteenths as
    -- a rotation is counted (from south)
    local turns = (base + atan2(dx, dz) / (math.pi / 2)) % 4
    local ideal = (8 + 4 * turns) % 16
    local best, off
    for _, r in ipairs(ROTATIONS) do
        local d = math.abs(ideal - r)
        d = math.min(d, 16 - d)
        if not off or d < off - 1e-9 then best, off = r, d end
    end
    out.rotation = best
    local aim = { form = "standing", rotation = best, wanted = math.floor(ideal + 0.5) % 16, off = math.floor(off * 22.5 + 0.5) }
    if aim.off > 0 then
        local way
        for name, r in pairs(ROTATION_FACING) do if r == best then way = name end end
        aim.note = "a standing sign turned to rotation " .. best .. " (its face " .. way .. "), " .. aim.off .. " degrees off the " ..
            "reader's way (rotation " .. aim.wanted .. "): a turtle turns one only in quarter turns"
    end
    return out, aim
end

--------------------------------------------------------------------------
-- Placing a block with the state wanted
--------------------------------------------------------------------------

-- A name cut at its namespace: the part to put back before a short name ("minecraft:", or "" for a name without
-- one) and the short name.
local function namespaced(name)
    local space, short = text.cut(name, ":")
    if not short then return "", name end
    return space .. ":", short
end

-- The item that places the block `name`: "minecraft:redstone" for "minecraft:redstone_wire", "minecraft:torch" for a
-- wall_torch, a crop's seeds; any other block's name as it is.
--
-- Covers the vanilla 1.21 blocks whose item has another name: redstone dust, tripwire (string), the wall forms of
-- torches, signs, hanging signs, banners, heads and skulls and coral fans, crops and stems, cocoa, sweet berries, glow
-- berries, and the grown parts of kelp, vines and big dripleaf (not what a bucket places).  T.placeAt takes the block
-- it finds as the item's by it, and a plan (tl.blueprint) names the item.
function T.itemOfBlock(name)
    if type(name) ~= "string" then return name end
    local prefix, short = namespaced(name)
    if ITEM_OF_BLOCK[short] then return prefix .. ITEM_OF_BLOCK[short] end
    for _, row in ipairs(BLOCK_ITEM_ENDING) do
        local stem = text.stripSuffix(short, row[1])
        if stem then return prefix .. stem .. row[2] end
    end
    return name
end

-- The block the item `item` places ("minecraft:redstone_wire" for "minecraft:redstone", else the item's own name), or
-- with form "wall" the one it makes hung on a block's side (a wall_torch for a torch), nil if none.
--
-- The other way round from T.itemOfBlock.  The wall forms are those of torches, signs, hanging signs, banners, heads
-- and skulls, and coral fans ("minecraft:oak_wall_sign" for an oak_sign).
function T.blockOfItem(item, form)
    if type(item) ~= "string" then return nil end
    local prefix, short = namespaced(item)
    form = form or "placed"
    local own = BLOCK_OF_ITEM[short]
    if own and own[form] then return prefix .. own[form] end
    if form ~= "wall" then return item end
    for _, row in ipairs(BLOCK_ITEM_ENDING) do
        local stem = text.stripSuffix(short, row[2])
        if stem then return prefix .. stem .. row[1] end
    end
    return nil
end

-- What placeAt can place this item by: { family, keys, hang, door }, or nil if the item is not a block it knows.
--
-- family is stairs, slab, log, chain, torch, lantern, sign, ladder, button, door, trapdoor, fence_gate, chest, piston
-- (and dispenser and dropper), observer, diode (a repeater or comparator), fence, pane, wall or block; keys is
-- the set of state names placeAt can be asked for with it (facing, half, type, axis, face, rotation, hanging: a slab
-- takes half and type, which are the same); hang is true for a family that hangs or stands on a solid block (a torch,
-- lantern or standing sign stands on the post of a fence, a wall, a pane or a chain too, though nothing hangs on their
-- sides; a lantern hangs under one, opts.hanging); door is true for a family of two blocks.  Used by tl.blueprint to order the work and to ask for only the states that can be asked for.
function T.placeInfo(item)
    if type(item) ~= "string" or item == "" then return nil end
    local famName = familyOf(item)
    local fam = FAMILIES[famName]
    local keys = {}
    for key in pairs(keysOf(fam)) do keys[key] = true end
    for name, key in pairs(fam.alias or {}) do
        if keys[key] then keys[name] = true end
    end
    return { family = famName, keys = keys, hang = fam.hang == true, door = fam.tall == true }
end


-- Place item at the cell x, y, z with the state wanted (opts.facing, half, axis, hanging; a sign's opts.text;
-- opts.digBelow lets it dig a floor to stand in and put it back): the block, its state and how; nil and why if it can't.
--
-- It works out from the table which approaches (placing sideways, from above or from below, from each side) give the
-- state wanted and the map says are possible, goes to the nearest with T.moveTo, places, inspects, and if the state is
-- wrong digs the block and tries the next approach, learning what the game actually gave (see the overview).
-- opts.facing is a compass name (north, east, south, west) and needs the world origin (up or down too for a piston,
-- dispenser, dropper or observer, which need none; a repeater or comparator stands on a block); opts.half is bottom or top for a
-- stair, slab or trapdoor; opts.axis is x, y or z for a log; opts.face is wall, floor or ceiling for a button or lever;
-- opts.rotation is a standing sign's, 0 (its face south), 4 (west), 8 (north) or 12 (east): the only four a turtle
-- gives; opts.hanging is a lantern's: true hangs it under the block above (placed from below, or sideways with nothing
-- under the cell to stand on), false stands it on the block below; opts.axis is a chain's too.  opts.toward = { x, y, z }, the cell a reader stands in, turns a sign to them: a wall sign when the map shows a
-- sturdy block behind the cell (on the far side from the reader), else a standing sign at the nearest of the four
-- rotations (how.toward says which, and how many degrees off the reader's way it is).  Other opts: move (passed to T.moveTo; default { path = true, scan = false }), inside (a protected area the job may
-- dig and walk in), tries (approaches to try, default 6), text (a sign's, a string or a list of lines: wrapped to 4
-- lines of 15 characters, a newline or a new entry starting a line; more is refused), temp (a block to put above the target for a moment, below), digBelow
-- (below), exit ({ x, y, z }: below).  A cell that already holds the item as wanted comes back as it is; one holding
-- anything else is not touched.  A placement that closes the turtle in (no way, through what the map shows empty or
-- unknown, out of where it stands: a dozen blocks, or to opts.exit) is made with how.warning saying so; with
-- opts.exit it's refused (and an opts.exit that is the target cell itself, which is no way out).  When the plain ways have run out, a top half (a slab, stair or trapdoor) is placed from below with
-- support: with nothing above it to place against, a temporary block goes there first (a cobblestone, dirt, planks or
-- bricks on board, or opts.temp) and is taken away again; with a floor under it, only when opts.digBelow = true, the
-- floor is dug to stand in and put back after with the same block (carry one, unless the floor comes back as itself
-- when dug, as soul soil, planks or bricks do, and a slot is free for it); on solid ground, with no free cell beside
-- the floor, a floor cell beside it with air above (not protected, no liquid beside it) is dug and stood in too, the
-- floor dug from there, and both put back as they were (its block needed too).  Without digBelow the floor is never dug,
-- and the failure says the option is there, with whatever else digging it would need.  Returns the block's name, its
-- state, and { approach, from, heading, tries, lines, support } (approach is front, down or up; from the cell the
-- turtle stood in; lines a sign's text; support { temp, floor, exit }: the names of the block put above and the floor
-- dug, and the neighbour dug too ({ x, y, z, name });
-- toward, with opts.toward: { form = "wall", facing, behind } or { form = "standing", rotation, wanted, off, note }).  A failure's why
-- names the approaches tried and what each got, and what the others lack ("from below from 0,0,3: needs a block above
-- the target, and the map has minecraft:air at 0,2,3"; "...: the map has minecraft:stone there": the stand is taken).
-- An option it doesn't take is refused, named.
function T.placeAt(x, y, z, item, opts)
    opts = opts or {}
    for _, key in ipairs(tables.sortedKeys(opts)) do
        if not PLACE_OPTS[key] then
            return nil, "placeAt has no option " .. tostring(key) .. " (it takes " .. table.concat(tables.sortedKeys(PLACE_OPTS), ", ") .. ")"
        end
    end
    for _, n in ipairs({ x, y, z }) do
        if type(n) ~= "number" or n ~= math.floor(n) then return nil, "placeAt wants a cell of whole numbers: x, y, z" end
    end
    if type(item) ~= "string" or item == "" then return nil, "placeAt wants the item's name, like minecraft:oak_stairs" end
    if not text.contains(item, ":") then item = "minecraft:" .. item end
    if opts.exit ~= nil then
        local ex, ey, ez = cellOf(opts.exit)
        if not ex then return nil, "opts.exit is a cell { x, y, z }, whole numbers" end
        if ex == x and ey == y and ez == z then
            return nil, "opts.exit " .. x .. "," .. y .. "," .. z .. " is the cell being placed: the exit is a cell the turtle "
                .. "can still get to after it (beside it, or beyond)"
        end
    end
    if opts.toward ~= nil then
        local aimed, aim = towardOpts(x, y, z, item, opts)
        if not aimed then return nil, aim end
        local name, state, how = T.placeAt(x, y, z, item, aimed)
        if name and type(how) == "table" then how.toward = aim end
        return name, state, how
    end
    local famName = familyOf(item)
    local fam = FAMILIES[famName]
    local want, why = wantsOf(item, famName, fam, opts)
    if not want then return nil, why end
    local base = compassBase()
    if ((want.facing and not VERTICAL[want.facing]) or (want.axis and want.axis ~= "y") or want.rotation) and not base then
        return nil, "a compass " .. (want.facing and "facing" or want.axis and "axis" or "rotation")
            .. " needs the world origin: T.setOrigin(x, y, z, facing)"
    end
    local lines, message
    if opts.text ~= nil then
        lines, why = signLines(item, famName, opts.text)
        if not lines then return nil, why end
        message = table.concat(lines, "\n")
    end
    if T.countItem(item) == 0 then return nil, "no " .. item .. " on board" end
    local blocked = needsMet(fam, x, y, z)
    if blocked then return nil, item .. " " .. blocked end
    local here = nameAt(x, y, z)
    if here and clickable(here) and not isItem(item, here) and familyOf(here) ~= famName then
        return nil, here .. " is in the way at " .. x .. "," .. y .. "," .. z
    end

    local move = {}
    for k, v in pairs(opts.move or { path = true, scan = false }) do move[k] = v end
    local function run()
        local learned, tried, lastWhy = loadLearned(), {}, nil
        local attempts = {}
        local tries = opts.tries or TRIES
        for attempt = 1, tries do
            local apps = plan(famName, fam, item, learned, want, x, y, z, base, tried, move.dig)
            if #apps == 0 then apps = supportPlans(famName, fam, item, learned, want, x, y, z, base, tried, opts) end
            local app = apps[1]
            if not app then break end
            tried[app.key] = true
            local words = KIND_WORDS[app.kind] .. " from " .. app.sx .. "," .. app.sy .. "," .. app.sz
            local ok, reason = true, nil
            if not app.support then ok, reason = T.moveTo(app.sx, app.sy, app.sz, move) end
            if app.support then
                words = words .. supportWords(app.support)
                local got = placeWithSupport(app, item, want, message, move, x, y, z)
                if got.good and not got.left then
                    return got.name, got.state, { approach = "up", from = { x = app.sx, y = app.sy, z = app.sz }, heading = app.h,
                                                  tries = attempt, lines = lines, support = app.support }
                end
                if got.left then
                    return nil, (got.name and ("placed " .. describe(got.name, got.state) .. " at " .. x .. "," .. y .. "," .. z .. ", but ")
                        or "") .. got.left
                end
                lastWhy = got.failed or ("got " .. describe(got.name, got.state) .. " from " .. app.sx .. "," .. app.sy .. "," .. app.sz)
                attempts[#attempts + 1] = words .. ": " .. lastWhy
            elseif not ok then
                lastWhy = "couldn't get to " .. app.sx .. "," .. app.sy .. "," .. app.sz .. ": " .. tostring(reason)
                attempts[#attempts + 1] = words .. ": couldn't get there (" .. tostring(reason) .. ")"
            else
                T.face(app.h)
                local was, wasState = lookAtTarget(app.kind, app.h)
                if was and accepted(item, want, was, wasState) then
                    return was, wasState, { approach = "already there", tries = attempt - 1 }
                end
                if was and clickable(was) then
                    return nil, was .. " is in the way at " .. x .. "," .. y .. "," .. z
                end
                local sealed = closesIn(x, y, z, opts.exit)
                if sealed and opts.exit then
                    return nil, "won't place " .. shortName(item) .. " at " .. x .. "," .. y .. "," .. z .. ": " .. sealed
                end
                T.selectItem(item)
                local placed, placeWhy = T.placeDir(dirOf(app.kind, app.h), message)
                if not placed then
                    lastWhy = "the game would not place " .. shortName(item) .. " from " .. app.sx .. "," .. app.sy .. "," ..
                        app.sz .. " (" .. app.kind .. "): " .. tostring(placeWhy)
                    attempts[#attempts + 1] = words .. ": the game refused (" .. tostring(placeWhy) .. ")"
                else
                    local name, state = lookAtTarget(app.kind, app.h)
                    if not name then
                        lastWhy = "placed " .. shortName(item) .. " but nothing is there to inspect"
                        attempts[#attempts + 1] = words .. ": nothing there after"
                    else
                        noteInMap(x, y, z, name, state)
                        if app.certain and learnFrom(learned, famName, app.kind, app.row, app.h, base, item, name, state) then
                            saveLearned(learned)
                        end
                        if accepted(item, want, name, state) then
                            return name, state, { approach = app.kind, from = { x = app.sx, y = app.sy, z = app.sz },
                                                  heading = app.h, tries = attempt, lines = lines,
                                                  warning = sealed and ("warning: placed " .. shortName(item) .. " at " .. x .. ","
                                                      .. y .. "," .. z .. ", but " .. sealed) or nil }
                        end
                        lastWhy = "got " .. describe(name, state) .. " from " .. app.sx .. "," .. app.sy .. "," ..
                            app.sz .. " (" .. app.kind .. ")"
                        attempts[#attempts + 1] = words .. ": got " .. describe(name, state)
                        local dug, digWhy = takeBack(app.kind, app.h, x, y, z)
                        if not dug then
                            return nil, lastWhy .. ", and couldn't dig it out: " .. tostring(digWhy)
                        end
                    end
                end
            end
        end
        local asked = {}
        for key, value in pairs(want) do asked[#asked + 1] = key .. "=" .. value end
        table.sort(asked)
        local what = shortName(item) .. (#asked > 0 and (" with " .. table.concat(asked, " ")) or "") ..
            " at " .. x .. "," .. y .. "," .. z
        local others, beyond = whyNot(famName, fam, item, learned, want, x, y, z, base, move.dig)
        local rest = #others > 0 and (" (the rest: " .. listed(others) .. ")") or ""
        local _, notes = supportPlans(famName, fam, item, learned, want, x, y, z, base, {}, opts)
        -- (ADR-0019 D7) a sideways placement that wants a block beyond: opts.temp won't put one there
        if beyond then notes[#notes + 1] = "opts.temp props only from below, so put a block beyond first to place it sideways" end
        local noted = #notes > 0 and (" (" .. table.concat(notes, "; ") .. ")") or ""
        if lastWhy then
            return nil, "couldn't place " .. what .. ": " .. lastWhy .. " (" .. #attempts .. (#attempts == 1 and " way" or " ways")
                .. " tried: " .. listed(attempts) .. ")" .. rest .. noted
        end
        if #others == 0 then
            return nil, "no way to place " .. what .. ": nothing in the table gives it with what the map shows round it" .. noted
        end
        return nil, "no way to place " .. what .. ": nothing in the table gives it with what the map shows round it (" .. listed(others) .. ")"
            .. noted
    end
    if opts.inside then return T.inside(opts.inside, run) end
    return run()
end

--------------------------------------------------------------------------
-- A sign in front of a reader
--------------------------------------------------------------------------

-- Where T.signFor puts a sign, in order: { cells in front of the reader, height above the reader's feet, what holds it }
local SIGN_SPOTS = {
    { 1, 1, "wall" }, { 2, 1, "wall" },          -- at eye level, on a wall behind it
    { 1, 0, "floor" }, { 2, 0, "floor" },        -- standing on the floor in front
    { 1, 1, "floor" }, { 2, 1, "floor" },        -- at eye level, standing on a block in front
}
local WALL_REACH = 3                             -- how far in front of the reader T.signFor looks for a wall

-- The first sign on board (a standing or wall sign's item, not a hanging sign's): its name, or nil.
local function signOnBoard()
    local slot = T.findSlot(function(name) return familyOf(name) == "sign" end)
    return slot and turtle.getItemDetail(slot).name or nil
end

-- The heading in which the map shows the nearest wall at the reader's eye level, 2 to WALL_REACH cells away (a sign
-- goes on its face, between); ties go north, east, south, west.  nil and why if there is none.
local function nearestWall(rx, ry, rz, base)
    local best, bestAt
    for c = 0, 3 do
        local h = (c - base) % 4
        local v = T.DELTA[h]
        for d = 1, WALL_REACH do
            local name = nameAt(rx + v[1] * d, ry + 1, rz + v[3] * d)
            if name and clickable(name) then
                if d >= 2 and sturdy(name) and (not bestAt or d < bestAt) then best, bestAt = h, d end
                break
            end
        end
    end
    if best then return best end
    return nil, "the map shows no wall 2 to " .. WALL_REACH .. " cells from the reader at " .. rx .. "," .. ry .. "," .. rz ..
        " at eye level: opts.look names the way they look (north, east, south or west)"
end

-- Why a spot can't hold the sign, from the map: nil if it can.  c the cell, v the way the reader looks, mid the cell
-- between it and the reader (a spot 2 cells away).
local function spotWhyNot(cx, cy, cz, need, v, mid)
    local here = nameAt(cx, cy, cz)
    if here and not AIRS[here] then return "the map has " .. here .. " there" end
    if mid then
        local between = nameAt(mid[1], mid[2], mid[3])
        if between and clickable(between) then return "the map has " .. between .. " in the way at " .. table.concat(mid, ",") end
    end
    if need == "wall" then
        local bx, bz = cx + v[1], cz + v[3]
        local behind = nameAt(bx, cy, bz)
        if not (behind and sturdy(behind)) then
            return "no wall behind it (the map has " .. tostring(behind or "nothing it knows") .. " at " .. bx .. "," .. cy .. "," .. bz .. ")"
        end
    else
        local under = nameAt(cx, cy - 1, cz)
        if not (under and holdsOnTop(FAMILIES.sign, under)) then
            return "nothing to stand on (the map has " .. tostring(under or "nothing it knows") .. " at " .. cx .. "," .. (cy - 1) .. "," .. cz .. ")"
        end
    end
    return nil
end

-- Put a sign in front of a reader standing at reader = { x, y, z }, its face toward them, with text on it: the sign's
-- name, its state and how ({ at, look, toward, ... } as T.placeAt's); nil and why if it can't.
--
-- The way the reader looks is opts.look (a compass way), else toward the nearest wall the map shows at their eye level,
-- 2 or 3 cells away.  The sign goes, the first the map allows: at eye level (the reader's y + 1) on a wall 1 or 2 cells
-- in front, standing on the floor 1 or 2 cells in front, at eye level standing on a block in front; T.placeAt with
-- opts.toward = reader places it (a wall sign facing them, or a standing one turned the nearest a turtle can).  The
-- sign is opts.item, else the first on board.  Needs the world origin.  Other opts go to T.placeAt (move, inside,
-- tries).  A refusal names each cell and why it wouldn't do.
function T.signFor(reader, said, opts)
    opts = opts or {}
    local rx, ry, rz = cellOf(reader)
    if not rx then return nil, "signFor wants the reader's cell: { x, y, z }, whole numbers" end
    local base = compassBase()
    if not base then return nil, "signFor needs the world origin: T.setOrigin(x, y, z, facing)" end
    local item = opts.item or signOnBoard()
    if not item then return nil, "no sign on board (oak_sign, spruce_sign, ...: not a hanging sign)" end
    local h, why
    if opts.look ~= nil then
        if COMPASS_AT[opts.look] == nil then return nil, "opts.look is the compass way the reader looks: north, east, south or west" end
        h = (COMPASS_AT[opts.look] - base) % 4
    else
        h, why = nearestWall(rx, ry, rz, base)
        if not h then return nil, why end
    end
    local v, whys, tried = T.DELTA[h], {}, {}
    local place = {}
    for k, value in pairs(opts) do place[k] = value end
    place.look, place.item, place.text, place.toward = nil, nil, said, { rx, ry, rz }
    for _, spot in ipairs(SIGN_SPOTS) do
        local d, up, need = spot[1], spot[2], spot[3]
        local cx, cy, cz = rx + v[1] * d, ry + up, rz + v[3] * d
        local at = cx .. "," .. cy .. "," .. cz
        local mid = d == 2 and { rx + v[1], ry + up, rz + v[3] } or nil
        local no = not tried[at] and spotWhyNot(cx, cy, cz, need, v, mid)
        if no then
            whys[#whys + 1] = at .. ": " .. no
        elseif not tried[at] then
            tried[at] = true
            local name, state, how = T.placeAt(cx, cy, cz, item, place)
            if name then
                how.at, how.look = { x = cx, y = cy, z = cz }, COMPASS[(base + h) % 4]
                return name, state, how
            end
            whys[#whys + 1] = at .. ": " .. tostring(state)
        end
    end
    return nil, "no place for a sign in front of the reader at " .. rx .. "," .. ry .. "," .. rz .. " looking " .. COMPASS[(base + h) % 4]
        .. ": " .. listed(whys)
end

--------------------------------------------------------------------------
-- Lighting a fire
--------------------------------------------------------------------------
local FLINT = "minecraft:flint_and_steel"
local BURNING = { ["minecraft:fire"] = true, ["minecraft:soul_fire"] = true, ["minecraft:nether_portal"] = true }

-- Light a fire in the cell x, y, z with flint and steel, from above: the fire's name, or nil and why.
--
-- The turtle goes to the cell over it and uses the flint and steel downward on the block under it, which puts the fire
-- in the cell between (so there must be a solid block under the cell, and the cell empty).  Inside an obsidian
-- frame that lights a nether portal, and what it finds is nether_portal.  opts.move and opts.inside are as for
-- T.placeAt.  Returns the name of what burns there (minecraft:fire, soul_fire or nether_portal), and true if it was
-- already burning.
function T.ignite(x, y, z, opts)
    opts = opts or {}
    for _, n in ipairs({ x, y, z }) do
        if type(n) ~= "number" or n ~= math.floor(n) then return nil, "ignite wants a cell of whole numbers: x, y, z" end
    end
    if T.countItem(FLINT) == 0 then return nil, "no " .. FLINT .. " on board" end
    local under = nameAt(x, y - 1, z)
    if under and not clickable(under) then
        return nil, "nothing solid to light it from: the map has " .. under .. " at " .. x .. "," .. (y - 1) .. "," .. z
    end
    local move = {}
    for k, v in pairs(opts.move or { path = true, scan = false }) do move[k] = v end
    local function run()
        local ok, why = T.moveTo(x, y + 1, z, move)
        if not ok then return nil, "couldn't get to " .. x .. "," .. (y + 1) .. "," .. z .. ": " .. tostring(why) end
        local found, data = T.look("down")
        local name = found and type(data) == "table" and data.name or nil
        if name and BURNING[name] then return name, true end
        if name and clickable(name) then return nil, name .. " is in the cell at " .. x .. "," .. y .. "," .. z end
        T.selectItem(FLINT)
        local placed, placeWhy = T.placeDir("down")
        if not placed then
            return nil, "the flint and steel would not light " .. x .. "," .. y .. "," .. z .. ": " .. tostring(placeWhy)
        end
        found, data = T.look("down")
        name = found and type(data) == "table" and data.name or nil
        noteInMap(x, y, z, name or AIR, name and data.state or nil)
        if not (name and BURNING[name]) then
            return nil, "used the flint and steel but there is no fire at " .. x .. "," .. y .. "," .. z
        end
        return name, false
    end
    if opts.inside then return T.inside(opts.inside, run) end
    return run()
end

return T
