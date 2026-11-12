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
--                with a block beyond (standing with only a floor); a torch, ladder, button or lever hung on the
--                block beyond; a door, gate or chest facing as the turtle does
--   placeDown    stairs and slabs bottom half if there is a block under the target, else top half
--   placeUp      stairs and slabs top half if there is a block over the target, else bottom half
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
-- and the cell above free; T.ignite lights a fire from above with flint and steel.

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
    { "_wall", "wall" },
}

-- The torches that hang on a wall have a name of their own
local WALL_NAME = { torch = "wall_torch", soul_torch = "soul_wall_torch", redstone_torch = "redstone_wall_torch" }

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

-- The family a block or item is in: stairs, slab, log, torch, ladder, button, door, trapdoor, fence_gate, chest,
-- fence, pane, wall, or block (anything else).
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
-- block to click beyond the target), "floor" (sideways only: a block under the target to click on its top) or
-- "always" (the turtle's own block is clicked).  The rule for a key is a word, or heading, back, right, left,
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
local function plain(sturdy)
    return { sturdy = sturdy, front = rows("always"), down = rows("always"), up = rows("always") }
end

-- Per family.  hang: it hangs on or stands on a solid block (beyond and floor then mean a block that can hold it, not
-- just one that can be clicked); sturdy = false: nothing hangs on it; needs: what must be round the target;
-- alias: other names for a state key.  An approach with no rows can not place it.
local FAMILIES = {
    block = plain(true),
    fence = plain(false),
    pane = plain(false),
    wall = plain(false),
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
        hang = true, sturdy = false,
        front = rows("beyond block=wall facing=back", "floor"),
        down = rows("beyond"),
        up = {},
    },
    ladder = { hang = true, sturdy = false, front = rows("beyond facing=back"), down = {}, up = {} },
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

-- A fact the table asks about, as true, false, or nil (the map has never seen the cell).
local function factAbout(fam, name)
    if name == nil then return nil end
    if fam.hang then return sturdy(name) end
    return clickable(name)
end

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
local function plan(famName, fam, learned, want, tx, ty, tz, base, tried, dig)
    local apps = {}
    local headingMatters = want.facing ~= nil or want.axis ~= nil
    for _, kind in ipairs({ "front", "down", "up" }) do
        for h = 0, 3 do
            if (kind == "front" or headingMatters or h == T.dir) and #fam[kind] > 0 then
                local sx, sy, sz = standFor(kind, h, tx, ty, tz)
                local bx, by, bz = beyondFor(kind, h, tx, ty, tz)
                local facts = { beyond = factAbout(fam, nameAt(bx, by, bz)) }
                if kind == "front" then facts.floor = factAbout(fam, nameAt(tx, ty - 1, tz)) end
                local stand = nameAt(sx, sy, sz)
                if not (stand and clickable(stand) and not dig) then
                    for _, c in ipairs(rowsFor(fam, kind, facts)) do
                        if gives(learned, famName, kind, c.row, want, h, base) then
                            -- (the heading only tells approaches apart when the state depends on it)
                            local key = kind .. " " .. sx .. "," .. sy .. "," .. sz .. " " .. c.row.when
                                .. (headingMatters and (" " .. h) or "")
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

--------------------------------------------------------------------------
-- Looking at what came out, and taking it back
--------------------------------------------------------------------------

-- Look at the target from the stand: the block's name and state, or nil if nothing is there.
local function lookAtTarget(kind, h)
    local ok, data = T.look(dirOf(kind, h))
    if ok and type(data) == "table" and data.name then return data.name, data.state or {} end
    return nil
end

-- Is the block the item's, or the wall version of it (a torch)?
local function isItem(item, name)
    local wall = WALL_NAME[shortName(item)]
    return name == item or (wall ~= nil and name == "minecraft:" .. wall)
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
    if WALL_NAME[shortName(item)] then keys.block = true end
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

-- Dig the block in the target cell that this call has just placed.  It is the library's own work, so a protected
-- area round it, or a chest that the digs refuse, doesn't stop it.  True, or false and why.
local function takeBack(kind, h, x, y, z)
    local area = T.guarded(x, y, z)
    local before = T.cfg.digContainers
    T.cfg.digContainers = true
    local ok, dug, why = pcall(function()
        if area then return T.inside(area, T.digDir, dirOf(kind, h)) end
        return T.digDir(dirOf(kind, h))
    end)
    T.cfg.digContainers = before
    if not ok then error(dug, 0) end
    return dug, why
end

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
-- Placing a block with the state wanted
--------------------------------------------------------------------------

-- What placeAt can place this item by: { family, keys, hang, door }, or nil if the item is not a block it knows.
--
-- family is stairs, slab, log, torch, ladder, button, door, trapdoor, fence_gate, chest, fence, pane, wall or block; keys is
-- the set of state names placeAt can be asked for with it (facing, half, type, axis, face: a slab takes half and
-- type, which are the same); hang is true for a family that hangs or stands on a solid block; door is true for a
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


-- Place item at the cell x, y, z with the state wanted (opts.facing, opts.half, opts.axis): the block, its state and
-- how; nil and why if it can't.
--
-- It works out from the table which approaches (placing sideways, from above or from below, from each side) give the
-- state wanted and the map says are possible, goes to the nearest with T.moveTo, places, inspects, and if the state is
-- wrong digs the block and tries the next approach, learning what the game actually gave (see the overview).
-- opts.facing is a compass name (north, east, south, west) and needs the world origin; opts.half is bottom or top for a
-- stair, slab or trapdoor; opts.axis is x, y or z for a log; opts.face is wall, floor or ceiling for a button or lever.
-- Other opts: move (passed to T.moveTo; default { path = true, scan = false }), inside (a protected area the job may
-- dig and walk in), tries (approaches to try, default 6).  A cell that already holds the item as wanted comes back
-- as it is; one holding anything else is not touched.  Returns the block's name, its state, and { approach, from,
-- heading, tries } (approach is front, down or up; from the cell the turtle stood in).
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
        local tries = opts.tries or TRIES
        for attempt = 1, tries do
            local apps = plan(famName, fam, learned, want, x, y, z, base, tried, move.dig)
            local app = apps[1]
            if not app then break end
            tried[app.key] = true
            local ok, reason = T.moveTo(app.sx, app.sy, app.sz, move)
            if not ok then
                lastWhy = "couldn't get to " .. app.sx .. "," .. app.sy .. "," .. app.sz .. ": " .. tostring(reason)
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
                local placed, placeWhy = T.placeDir(dirOf(app.kind, app.h))
                if not placed then
                    lastWhy = "the game would not place " .. shortName(item) .. " from " .. app.sx .. "," .. app.sy .. "," ..
                        app.sz .. " (" .. app.kind .. "): " .. tostring(placeWhy)
                else
                    local name, state = lookAtTarget(app.kind, app.h)
                    if not name then
                        lastWhy = "placed " .. shortName(item) .. " but nothing is there to inspect"
                    else
                        noteInMap(x, y, z, name, state)
                        if app.certain and learnFrom(learned, famName, app.kind, app.row, app.h, base, item, name, state) then
                            saveLearned(learned)
                        end
                        if accepted(item, want, name, state) then
                            return name, state, { approach = app.kind, from = { x = app.sx, y = app.sy, z = app.sz },
                                                  heading = app.h, tries = attempt }
                        end
                        lastWhy = "got " .. describe(name, state) .. " from " .. app.sx .. "," .. app.sy .. "," ..
                            app.sz .. " (" .. app.kind .. ")"
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
        if lastWhy then return nil, "couldn't place " .. what .. ": " .. lastWhy end
        return nil, "no way to place " .. what .. ": nothing in the table gives it with what the map shows round it"
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
