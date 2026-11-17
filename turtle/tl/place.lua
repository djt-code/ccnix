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
--                the block beyond; a door, gate or chest facing as the turtle does
--   placeDown    stairs and slabs bottom half if there is a block under the target, else top half
--   placeUp      stairs and slabs top half if there is a block over the target, else bottom half
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
-- compass way the turtle's frame points); half and axis do not.  Where the map does not know what is beside the
-- target the approaches are only guesses and go last.  What actually came out is remembered per family, in the data
-- file .placements, but only when the map knew every fact the row depended on: a table row that was wrong is
-- corrected once, for every later placement.  A door goes in after the walls round it, and needs a solid block under it
-- and the cell above free; T.ignite lights a fire from above with flint and steel.  A sign takes its text
-- (opts.text), which the game writes when the turtle places it.

local T = require("turtlelib")
local text = require("text")
local fileio = require("fileio")

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

--------------------------------------------------------------------------
-- Blocks by name: what family, what can be clicked, what holds a torch
--------------------------------------------------------------------------

-- The family of a block, from its name: exact names first, then the end of the name.
local FAMILY_EXACT = {
    torch = "torch", soul_torch = "torch", redstone_torch = "torch", ladder = "ladder", lever = "button",
    chest = "chest", trapped_chest = "chest", furnace = "chest", blast_furnace = "chest", smoker = "chest",
    crimson_stem = "log", warped_stem = "log", hay_block = "log", bone_block = "log", basalt = "log",
    polished_basalt = "log", deepslate = "log",
}
local FAMILY_SUFFIX = {
    { "_stairs", "stairs" }, { "_slab", "slab" }, { "_trapdoor", "trapdoor" }, { "_door", "door" },
    { "_fence_gate", "fence_gate" }, { "_button", "button" }, { "_log", "log" }, { "_wood", "log" },
    { "_hyphae", "log" }, { "_pillar", "log" }, { "_stem", "log" }, { "_fence", "fence" }, { "_pane", "pane" },
    { "_wall", "wall" }, { "_hanging_sign", "block" }, { "_sign", "sign" },
}
-- (a hanging sign is not a sign of the table's: it hangs under a block, and goes in as it comes)

-- The torches and signs that hang on a wall have a name of their own: a torch's by name, a sign's by its ending
local WALL_NAME = { torch = "wall_torch", soul_torch = "soul_wall_torch", redstone_torch = "redstone_wall_torch" }
local WALL_ENDING = { { "_sign", "_wall_sign" } }

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

-- The family a block or item is in: stairs, slab, log, torch, sign, ladder, button, door, trapdoor, fence_gate,
-- chest, fence, pane, wall, or block (anything else).
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
-- a post (a torch, a standing sign); needs: what must be round the target; alias: other names for a state key.  An
-- approach with no rows can not place it.
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
    -- a torch hangs on the block beyond (a wall torch, facing the turtle), or stands on the floor or the block below
    torch = {
        hang = true, onPost = true, sturdy = false,
        front = rows("beyond block=wall facing=back", "floor"),
        down = rows("beyond"),
        up = {},
    },
    -- a sign as a torch: on the wall beyond (the wall form, facing the turtle), or standing on the floor
    sign = {
        hang = true, onPost = true, sturdy = false,
        front = rows("beyond block=wall facing=back", "floor"),
        down = rows("beyond"),
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
        sturdy = false, needs = { below = "sturdy", above = "free" },
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
local WANTED = { "facing", "half", "axis", "face", "type" }

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

-- The value a rule gives on an approach with heading h (a compass name, an axis or a plain word); nil if it needs the
-- compass (base: the compass number of heading 0) and there isn't one.
local function valueOf(rule, h, base)
    local turns = RELATIVE[rule]
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

-- Does the way the turtle faces change what it gets: a state that follows the heading, or a family with rows that
-- look at the side it faces (a ladder from above)?
local function headingMatters(fam, want)
    if want.facing ~= nil or want.axis ~= nil then return true end
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
        if set[key] == nil or valueOf(set[key], h, base) ~= wanted then return false end
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
                if kind == "front" then facts.floor = fact(nameAt(tx, ty - 1, tz), true) else facts.ahead = fact(nameAt(aheadOf(h, tx, ty, tz))) end
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
    front = { beyond = "beyond the target", floor = "under the target" },
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

-- The state keys that follow the way the turtle faces
local TURNING = { facing = true, axis = true }

-- What a row gives of the keys wanted, where it differs: "half=bottom", and true if a key that follows the heading
-- (facing, axis) is among them.
local function givesWords(learned, famName, kind, row, want, h, base)
    local set, parts, keys, turned = specOf(learned, famName, kind, row), {}, {}, false
    for key in pairs(want) do keys[#keys + 1] = key end
    table.sort(keys)
    for _, key in ipairs(keys) do
        local got = set[key] and valueOf(set[key], h, base)
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
-- A second result is true when the stand is what is wrong, whichever way the turtle would face.
local function whyNotOne(famName, fam, learned, want, kind, h, tx, ty, tz, base, dig, fact)
    local sx, sy, sz = standFor(kind, h, tx, ty, tz)
    local stand = nameAt(sx, sy, sz)
    if stand and clickable(stand) and not dig then return "the map has " .. stand .. " there", true end
    local bx, by, bz = beyondFor(kind, h, tx, ty, tz)
    local ax, ay, az = aheadOf(h, tx, ty, tz)
    local cells = { beyond = { bx, by, bz }, floor = { tx, ty - 1, tz }, ahead = { ax, ay, az } }
    local names = { beyond = nameAt(bx, by, bz), floor = nameAt(tx, ty - 1, tz), ahead = nameAt(ax, ay, az) }
    local facts = { beyond = fact(names.beyond, TOP_FACT[kind] == "beyond") }
    if kind == "front" then facts.floor = fact(names.floor, true) else facts.ahead = fact(names.ahead) end
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
        .. tostring(names[needed] or "nothing it knows") .. " at " .. c[1] .. "," .. c[2] .. "," .. c[3]
end

-- Why the approaches the table rules out can't give `want` at the target: a list of "<approach>: <why>", in the order
-- plan goes through them, each said once.
local function whyNot(famName, fam, item, learned, want, tx, ty, tz, base, dig)
    local out, said = {}, {}
    local function fact(name, top)
        if famName == "slab" and name == item then return nil end
        return factAbout(fam, name, top)
    end
    local turning = headingMatters(fam, want)
    for _, kind in ipairs({ "front", "down", "up" }) do
        for h = 0, 3 do
            if (kind == "front" or turning or h == T.dir) and #fam[kind] > 0 then
                local why, standing = whyNotOne(famName, fam, learned, want, kind, h, tx, ty, tz, base, dig, fact)
                local line = why and approachWords(kind, h, tx, ty, tz, base, turning and not standing) .. ": " .. why
                if line and not said[line] then
                    said[line] = true
                    out[#out + 1] = line
                end
            end
        end
    end
    return out
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
    if want.facing and COMPASS_AT[want.facing] == nil then
        return nil, "facing is a compass name: north, east, south or west"
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

-- A sign's text as its lines: opts.text wrapped to SIGN_WIDTH, each newline starting a line; nil and why if it is not
-- a sign, or the text takes more than SIGN_LINES lines.
local function signLines(item, famName, said)
    if famName ~= "sign" then return nil, "only a sign takes text, and " .. item .. " is not one" end
    if type(said) ~= "string" then return nil, "a sign's text is a string" end
    local lines = text.wrap(said, SIGN_WIDTH)
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

-- The name of the wall version of an item (a torch or a sign), or nil if it has none.
local function wallNameOf(item)
    local space, short = text.cut(item, ":")
    if not short then space, short = "minecraft", item end
    if WALL_NAME[short] then return space .. ":" .. WALL_NAME[short] end
    for _, ending in ipairs(WALL_ENDING) do
        local stem = text.stripSuffix(short, ending[1])
        if stem then return space .. ":" .. stem .. ending[2] end
    end
    return nil
end

-- Is the block the item's, or the wall version of it (a torch or a sign)?
local function isItem(item, name)
    return name == item or (name ~= nil and name == wallNameOf(item))
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
    if wallNameOf(item) then keys.block = true end
    local id = rowId(famName, kind, row)
    local set = learned[id] or {}
    local changed = false
    for key in pairs(keys) do
        local seen
        if key == "block" then
            seen = name == item and "item" or (isItem(item, name) and "wall") or nil
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
local AIRS = { [AIR] = true, ["minecraft:cave_air"] = true }
-- The cells beside a cell, as directions
local SIDES = { "up", "down", 0, 1, 2, 3 }

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

-- The ways to place from below with support, for when the plain ones have run out, and why there are none if so (a
-- list, for the message).  A top half (a slab, stair or trapdoor) is placed from below against a block above the
-- target; with nothing there, a temporary block goes there first (opts.temp, or one of TEMP_BLOCKS on board) and is
-- taken away after, from a free cell beside it.  With a floor under the target, only when opts.digBelow says so: the
-- floor is dug to stand in, and put back after with the same block from a free cell beside it (one on board, or for a
-- floor that drops itself a free slot for the one dug).  Each way is an approach as plan gives them, with support =
-- { temp, floor } (the names of the temporary block and of the floor dug).  The notes say every need not met.
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
    if floor then
        if not opts.digBelow then
            notes[#notes + 1] = "from below it needs to stand where the floor is (" .. below .. " at " .. at .. "): opts.digBelow = true " ..
                "digs it, places from there and puts the same block back"
        end
        local itself = dropsItself(below)
        if T.countItem(below) == 0 and not (itself and T.freeSlots() > 0) then
            notes[#notes + 1] = itself and ("opts.digBelow puts the floor back with the " .. below .. " it digs: free a slot for it (or carry one)")
                or ("opts.digBelow puts the floor back with the same block: carry one " .. below .. " (the one dug may drop something else)")
        end
        if not freeBeside(tx, ty - 1, tz, "up") then
            notes[#notes + 1] = "opts.digBelow needs a way out of the floor at " .. at .. " to put it back from, and the map shows " ..
                "no free cell beside the floor"
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
                                support = { temp = tempName, floor = floor and below or nil }, cost = T.turnsTo(h) }
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

-- Place the item from below with an approach's support: the temporary block put above the target (from the target
-- cell), the floor dug and stepped into (from the target cell) or the cell below walked to, the item placed up, a
-- wrong block dug out at once; then the floor put back and the temporary block taken away.  Returns { name, state,
-- good, failed, left }: what is at the target, whether it is as wanted, why it didn't place, and what is left undone
-- (the floor not back, the temporary block still there).
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
    local floor, floorState
    if s.floor then
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
    if floor then
        local notBack = putBack(x, y - 1, z, floor, floorState, move)
        if notBack then undone[#undone + 1] = "the floor dug at " .. x .. "," .. (y - 1) .. "," .. z .. " is not back: " .. notBack end
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

-- What an approach's support is, for a message: " with a cobblestone above it for a moment, in the floor dug out"
local function supportWords(s)
    return (s.temp and (" with a " .. s.temp .. " above it for a moment") or "") .. (s.floor and (", in the floor dug out") or "")
end

--------------------------------------------------------------------------
-- Placing a block with the state wanted
--------------------------------------------------------------------------

-- What placeAt can place this item by: { family, keys, hang, door }, or nil if the item is not a block it knows.
--
-- family is stairs, slab, log, torch, sign, ladder, button, door, trapdoor, fence_gate, chest, fence, pane, wall or block; keys is
-- the set of state names placeAt can be asked for with it (facing, half, type, axis, face: a slab takes half and
-- type, which are the same); hang is true for a family that hangs or stands on a solid block (a torch or a standing
-- sign stands on the post of a fence, a wall or a pane too, though nothing hangs on their sides); door is true for a
-- family of two blocks.  Used by tl.blueprint to order the work and to ask for only the states that can be asked for.
function T.placeInfo(item)
    if type(item) ~= "string" or item == "" then return nil end
    local famName = familyOf(item)
    local fam = FAMILIES[famName]
    local keys = {}
    for key in pairs(keysOf(fam)) do keys[key] = true end
    for name, key in pairs(fam.alias or {}) do
        if keys[key] then keys[name] = true end
    end
    return { family = famName, keys = keys, hang = fam.hang == true, door = fam.needs ~= nil }
end


-- Place item at the cell x, y, z with the state wanted (opts.facing, opts.half, opts.axis; a sign's opts.text): the
-- block, its state and how; nil and why if it can't.
--
-- It works out from the table which approaches (placing sideways, from above or from below, from each side) give the
-- state wanted and the map says are possible, goes to the nearest with T.moveTo, places, inspects, and if the state is
-- wrong digs the block and tries the next approach, learning what the game actually gave (see the overview).
-- opts.facing is a compass name (north, east, south, west) and needs the world origin; opts.half is bottom or top for a
-- stair, slab or trapdoor; opts.axis is x, y or z for a log; opts.face is wall, floor or ceiling for a button or lever.
-- Other opts: move (passed to T.moveTo; default { path = true, scan = false }), inside (a protected area the job may
-- dig and walk in), tries (approaches to try, default 6), text (a sign's: wrapped to 4 lines of 15 characters, a
-- newline starting a line; more is refused), temp (a block to put above the target for a moment, below), digBelow
-- (below).  A cell that already holds the item as wanted comes back as it is; one holding anything else is not
-- touched.  When the plain ways have run out, a top half (a slab, stair or trapdoor) is placed from below with
-- support: with nothing above it to place against, a temporary block goes there first (a cobblestone, dirt, planks or
-- bricks on board, or opts.temp) and is taken away again; with a floor under it, only when opts.digBelow = true, the
-- floor is dug to stand in and put back after with the same block (carry one, unless the floor comes back as itself
-- when dug, as soul soil, planks or bricks do, and a slot is free for it).  Without digBelow the floor is never dug,
-- and the failure says the option is there, with whatever else digging it would need.  Returns the block's name, its
-- state, and { approach, from, heading, tries, lines, support } (approach is front, down or up; from the cell the
-- turtle stood in; lines a sign's text; support { temp, floor }: the names of the block put above and the floor dug).  A failure's why
-- names the approaches tried and what each got, and what the others lack ("from below from 0,0,3: needs a block above
-- the target, and the map has minecraft:air at 0,2,3"; "...: the map has minecraft:stone there": the stand is taken).
function T.placeAt(x, y, z, item, opts)
    opts = opts or {}
    for _, n in ipairs({ x, y, z }) do
        if type(n) ~= "number" or n ~= math.floor(n) then return nil, "placeAt wants a cell of whole numbers: x, y, z" end
    end
    if type(item) ~= "string" or item == "" then return nil, "placeAt wants the item's name, like minecraft:oak_stairs" end
    if not text.contains(item, ":") then item = "minecraft:" .. item end
    local famName = familyOf(item)
    local fam = FAMILIES[famName]
    local want, why = wantsOf(item, famName, fam, opts)
    if not want then return nil, why end
    local base = compassBase()
    if (want.facing or (want.axis and want.axis ~= "y")) and not base then
        return nil, "a compass " .. (want.facing and "facing" or "axis") .. " needs the world origin: T.setOrigin(x, y, z, facing)"
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
                                                  heading = app.h, tries = attempt, lines = lines }
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
        local others = whyNot(famName, fam, item, learned, want, x, y, z, base, move.dig)
        local rest = #others > 0 and (" (the rest: " .. listed(others) .. ")") or ""
        local _, notes = supportPlans(famName, fam, item, learned, want, x, y, z, base, {}, opts)
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
