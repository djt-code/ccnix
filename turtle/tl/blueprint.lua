-- blueprint.lua -- plans of what to build: the format, building it, checking it, and swapping blocks in a place
--
-- Loaded by turtlelib the first time T.blueprint, T.build, T.verify or T.replace is used.  Cells are the turtle's
-- own (the frame it counts in).
--
-- A plan is layers of text with a legend, bottom layer first.  As a file it reads:
--
--   name: tower
--   anchor: 10 64 -3
--   B = minecraft:stone_bricks
--   s = minecraft:stone_brick_stairs[facing=north,half=bottom]
--   layer 1:
--   BBBB
--   B..B
--   layer 2:
--   ssss
--
-- Each character is a cell: "." is air, a space is "leave alone" (not built, not checked), anything else is
-- looked up in the legend.  The text is a map seen from above with +z at the top, as T.map.slice shows one: the
-- first line of a layer is the highest z, a column goes toward +x, the next layer is one up.  The anchor is the
-- turtle-frame cell of the first character of the first line of the first layer.  A state is in brackets after
-- the name, key=value separated by commas; a name without a namespace is minecraft:'s.  The same plan as a Lua
-- table: { name, anchor = {x, y, z}, legend = { B = "minecraft:stone_bricks", s = "...[facing=north]" }, layers = {
-- "BBBB\nB..B", { "ssss" } } } (a layer is a string of lines or a list of lines).  The helpers fill, box, walls and
-- fromMap make one from code; put changes a cell.  A legend entry may give an order hint: "t = oak_slab[type=top]
-- after 0,1,0" (as a table, { name = ..., after = { 0, 1, 0 } }) builds each of its cells after the cell that far from
-- it (here the one above), whatever the order would have been.
--
-- T.build puts a plan up.  It checks the materials first (what is short, and what could be crafted if the
-- craft module is there), then goes layer by layer from the bottom, standing over each cell and placing down; in a
-- layer the plain blocks come first, then stairs and slabs, then what hangs on others (torches, ladders, buttons,
-- trapdoors, gates), then doors, so a thing goes in after its support; a top slab with a stair on it goes in after the
-- stair (then it is placed from below, against it), and the legend's hints are followed.  With order = "column" the
-- blocks, stairs and slabs go up column by column instead, each column from the bottom, the columns in a serpentine (on to the nearest
-- one left), so a wall costs a climb a column rather than a lap a layer; then what hangs and the doors, layer by
-- layer.  A stair, slab, log, torch or door goes through T.placeAt for the state it names.  The plan is kept as text
-- in the data file .build, and how far the build has got (the number of the last cell tried, the cells that failed,
-- with why, and the order) in .build.progress, so a stop, a crash or a reboot carries on where it was, in the same
-- order, with a plain T.build(): the last plan given, finished or not (T.undo doesn't change it).  An unfinished one is
-- never replaced by a new plan without opts.restart; a finished one is, its failed cells in info.previous.  A build that spends over three times the fuel T.fuelFor gives for its cells stops
-- and says it is circling.  A build never digs a block out of a cell it fills (T.replace swaps blocks).  A finished
-- build can protect itself (opts.protect).
--
-- T.verify walks the plan and says which cells differ, states included: a cell with a state to match, or that the
-- map has never seen, is looked at with T.inspectAll; the rest is read from the map.  T.replace swaps every block
-- matching a glob in a box for another, each from its nearest free side; one with no free side is reported, never
-- dug to.

local T = require("turtlelib")
local text = require("text")
local fileio = require("fileio")
local tables = require("tables")
local convert = require("convert")

T.blueprint = {}
local bp = T.blueprint

local PLAN_FILE = ".build"                    -- the plan being built, as text, in the data folder
local PROGRESS_FILE = ".build.progress"       -- how far it has got
local AIR = "minecraft:air"
local AIRS = { [AIR] = true, ["minecraft:cave_air"] = true, ["minecraft:void_air"] = true }
-- The characters a plan's legend is drawn from when code makes one (no ".", no space)
local SYMBOLS = "BCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789#$%&*+-/:;<>?@^_~|!"
-- What T.placeAt can be asked for
local PLACE_KEYS = { facing = true, half = true, axis = true, face = true, type = true }
-- The families with no state to place by: put in from above, no questions
local PLAIN_FAMILIES = { block = true, fence = true, pane = true, wall = true }
-- A block whose item has another name (tl.place's table, through T.itemOfBlock and T.blockOfItem): a plan names the
-- item (what is carried and placed), and the block found is taken as that item's (a torch hung on a wall is a
-- wall_torch, facing away from the wall; redstone dust is redstone_wire)
-- The order of building inside a layer, by family: what others hang on first, doors last
local RANK = { block = 0, fence = 0, pane = 0, wall = 0, log = 0, stairs = 1, slab = 1, chest = 1, piston = 1, observer = 1,
               torch = 2, sign = 2, ladder = 2, button = 2, trapdoor = 2, fence_gate = 2, diode = 2, door = 3 }
local RANKS = 3                                -- (0 to 3)

local S = { lastYield = 0 }

-- Give the rest of the computer a turn when this has run for a while (CC stops code that goes seven seconds
-- without yielding).
local function breathe()
    local t = os.clock()
    if t - S.lastYield > 0.4 then
        S.lastYield = t
        sleep(0)
    end
end

local function whole(n) return type(n) == "number" and n == math.floor(n) end

--------------------------------------------------------------------------
-- Blocks: "minecraft:oak_stairs[facing=north,half=bottom]"
--------------------------------------------------------------------------

-- A block as text: name and state in brackets, the keys in order.
local function itemText(name, state)
    local keys = tables.sortedKeys(state or {})
    if #keys == 0 then return name end
    local parts = {}
    for i, key in ipairs(keys) do parts[i] = key .. "=" .. tostring(state[key]) end
    return name .. "[" .. table.concat(parts, ",") .. "]"
end

-- Read "name" or "name[key=value,key=value]": the name (the minecraft: namespace if it has none) and the state
-- table (nil if none), or nil and why.
local function parseItem(source)
    if type(source) ~= "string" then return nil, "a block is its name as text, like minecraft:stone" end
    local name, rest = text.cut(text.trim(source), "[")
    name = text.trim(name)
    if name == "" then return nil, "no block name in \"" .. source .. "\"" end
    if not text.contains(name, ":") then name = "minecraft:" .. name end
    local state
    if rest then
        local inner = text.stripSuffix(text.trimEnd(rest), "]")
        if not inner then return nil, "a state is [key=value,key=value]: \"" .. source .. "\"" end
        state = {}
        for _, pair in ipairs(text.split(inner, ",")) do
            local key, value = text.cut(pair, "=")
            key = text.trim(key)
            if value == nil or key == "" then return nil, "a state is key=value, not \"" .. pair .. "\"" end
            state[key] = text.trim(value)
        end
        if next(state) == nil then state = nil end
    end
    return name, state
end

-- An order hint: { dx, dy, dz } from "1,0,0" or a table ({ 1, 0, 0 } or { x =, y =, z = }); nil and why if it isn't
-- three whole numbers.
local function hintOf(value)
    local v = value
    if type(value) == "string" then
        local parts = text.split(value, ",")
        v = {}
        if #parts == 3 then
            for i = 1, 3 do v[i] = convert.toInteger(parts[i]) end
        end
    end
    if type(v) ~= "table" then v = {} end
    local dx, dy, dz = v.x or v[1], v.y or v[2], v.z or v[3]
    if not (whole(dx) and whole(dy) and whole(dz)) then
        return nil, "after is three whole numbers, the way to the cell it goes after: after 0,1,0"
    end
    return { dx, dy, dz }
end

-- A legend entry from a string or a table: { name, state, after } or nil and why.
local function entryOf(value)
    if type(value) == "string" then
        local item, hint = text.cut(value, " after ")
        local name, state = parseItem(item)
        if not name then return nil, state end
        local after, why
        if hint then
            after, why = hintOf(text.trim(hint))
            if not after then return nil, why end
        end
        return { name = T.itemOfBlock(name), state = state, after = after }
    end
    if type(value) == "table" then
        local name, state = value.name or value.item or value[1], value.state
        if type(name) ~= "string" then return nil, "a legend entry needs a name" end
        local parsed, parsedState = parseItem(name)
        if not parsed then return nil, parsedState end
        local copy = {}
        for key, v in pairs(state or parsedState or {}) do copy[key] = tostring(v) end
        local after, why
        if value.after ~= nil then
            after, why = hintOf(value.after)
            if not after then return nil, why end
        end
        return { name = T.itemOfBlock(parsed), state = next(copy) and copy or nil, after = after }
    end
    return nil, "a legend entry is a block as text, like minecraft:stone[...]"
end

-- A legend entry as text: the block, and its hint if it has one.
local function entryText(entry)
    local s = itemText(entry.name, entry.state)
    if entry.after then s = s .. " after " .. table.concat(entry.after, ",") end
    return s
end

-- placeAt's view of an entry: its family, the state keys that can be asked for, whether it hangs.
local function infoOf(entry)
    if not entry.info then
        entry.info = T.placeInfo(entry.name) or { family = "block", keys = {}, hang = false, door = false }
    end
    return entry.info
end

-- Is the block found the one a plan's entry asks for: the same name, or a block of its item (redstone_wire for
-- redstone, or the block T.placeAt learnt a mod item places: ae2:cable_bus for an AE2 cable)?  The wall form is when
-- the entry asks no state, as T.placeAt takes it (a torch it hung on a wall), or a facing; not when it asks a state
-- without one.
local function isBlockOf(found, entry)
    if found == entry.name then return true end
    if found == nil then return false end
    if T.blockOfItem(entry.name) == found then return true end
    if T.itemOfBlock(found) ~= entry.name then return false end
    return found ~= T.blockOfItem(entry.name, "wall") or entry.state == nil or entry.state.facing ~= nil
end

-- Is the item a mod's whose block isn't known (no table has it, and T.placeAt hasn't learnt it)?  Such a cell goes
-- through T.placeAt, which learns the block if it has another name (an AE2 cable goes in as ae2:cable_bus).
local function unlearnt(item)
    return not text.startsWith(item, "minecraft:") and T.blockOfItem(item) == item
end

-- Is the entry a double slab (two slab items in one cell)?
local function isDouble(entry)
    return entry.state ~= nil and entry.state.type == "double"
end

-- Does a block's state hold every key the plan names?
local function stateHolds(want, found)
    for key, value in pairs(want or {}) do
        if found == nil or tostring(found[key]) ~= tostring(value) then return false end
    end
    return true
end

-- The options for T.placeAt that an entry's state asks for (only the keys its family can be asked for), and how
-- many there are.
local function wantsOf(entry)
    local want, n = {}, 0
    local info = infoOf(entry)
    for key, value in pairs(entry.state or {}) do
        if PLACE_KEYS[key] and info.keys[key] then want[key] = value; n = n + 1 end
    end
    return want, n
end

--------------------------------------------------------------------------
-- Plans: reading, writing, making
--------------------------------------------------------------------------

-- Rows without the spaces at the end, and no empty rows at the end (a space is "leave alone", as is nothing).
local function tidyRows(rows)
    local out = {}
    for i, row in ipairs(rows) do out[i] = text.trimEnd(row) end
    while #out > 0 and out[#out] == "" do out[#out] = nil end
    return out
end

-- A plan from a table: a copy, checked; or nil and why.
local function normalize(spec)
    if type(spec) ~= "table" then return nil, "a plan is a table (or the text of one)" end
    local plan = { legend = {}, layers = {} }
    if spec.name ~= nil then
        if type(spec.name) ~= "string" or spec.name == "" or text.contains(spec.name, "\n") then
            return nil, "a plan's name is one line of text"
        end
        plan.name = spec.name
    end
    local a = spec.anchor or { 0, 0, 0 }
    local ax, ay, az = a.x or a[1], a.y or a[2], a.z or a[3]
    if not (whole(ax) and whole(ay) and whole(az)) then return nil, "a plan's anchor is { x, y, z }, whole numbers" end
    plan.anchor = { x = ax, y = ay, z = az }
    for ch, value in pairs(spec.legend or {}) do
        if type(ch) ~= "string" or #ch ~= 1 or ch == " " then
            return nil, "a legend symbol is one character, not a space"
        end
        local entry, why = entryOf(value)
        if not entry then return nil, "legend " .. ch .. ": " .. tostring(why) end
        if ch == "." then
            if not AIRS[entry.name] then return nil, "legend \".\" is air" end
        else
            plan.legend[ch] = entry
        end
    end
    if type(spec.layers) ~= "table" or #spec.layers == 0 then return nil, "a plan needs layers" end
    for li, layer in ipairs(spec.layers) do
        local rows
        if type(layer) == "string" then rows = text.lines(layer)
        elseif type(layer) == "table" then rows = layer
        else return nil, "layer " .. li .. " is lines of text" end
        local out = {}
        for ri, row in ipairs(rows) do
            if type(row) ~= "string" then return nil, "layer " .. li .. ", line " .. ri .. " is not text" end
            for ci = 1, #row do
                local ch = row:sub(ci, ci)
                if ch ~= " " and ch ~= "." and not plan.legend[ch] then
                    return nil, "layer " .. li .. ", line " .. ri .. ", column " .. ci .. ": \"" .. ch .. "\" is not in the legend"
                end
            end
            out[ri] = row
            breathe()
        end
        plan.layers[li] = tidyRows(out)
    end
    return plan
end

-- A plan as text, the format above.
local function formatPlan(plan)
    local out = {}
    if plan.name then out[#out + 1] = "name: " .. plan.name end
    out[#out + 1] = "anchor: " .. plan.anchor.x .. " " .. plan.anchor.y .. " " .. plan.anchor.z
    for _, ch in ipairs(tables.sortedKeys(plan.legend)) do
        out[#out + 1] = ch .. " = " .. entryText(plan.legend[ch])
    end
    for li, rows in ipairs(plan.layers) do
        out[#out + 1] = "layer " .. li .. ":"
        for _, row in ipairs(rows) do out[#out + 1] = row end
    end
    return table.concat(out, "\n") .. "\n"
end

-- Is this line "layer 3:" (a layer's start)?
local function isLayerLine(line)
    local words = text.words(line)
    return words[1] == "layer" and text.endsWith(text.trimEnd(line), ":")
end

-- Read a plan from text: the table, or nil and why (with the line).
local function parsePlan(source)
    local spec = { legend = {}, layers = {} }
    local rows
    for number, line in ipairs(text.lines(source)) do
        if isLayerLine(line) then
            rows = {}
            spec.layers[#spec.layers + 1] = rows
        elseif rows then
            rows[#rows + 1] = line
        elseif text.trim(line) ~= "" then
            local rest = text.stripPrefix(line, "name:")
            local numbers = text.stripPrefix(line, "anchor:")
            if rest then
                spec.name = text.trim(rest)
            elseif numbers then
                local parts = text.words(text.replace(numbers, ",", " "))
                local a = {}
                for i = 1, 3 do a[i] = convert.toInteger(parts[i] or "") end
                if #parts ~= 3 or not (a[1] and a[2] and a[3]) then
                    return nil, "line " .. number .. ": an anchor is three whole numbers: anchor: x y z"
                end
                spec.anchor = a
            else
                local ch = line:sub(1, 1)
                local value = text.stripPrefix(text.trim(line:sub(2)), "=")
                if ch == " " or value == nil then
                    return nil, "line " .. number .. ": a legend line is a symbol, =, then the block (B = minecraft:stone)"
                end
                spec.legend[ch] = text.trim(value)
            end
        end
    end
    if #spec.layers == 0 then return nil, "no layers: a layer starts with a line like \"layer 1:\"" end
    local plan, why = normalize(spec)
    if not plan then return nil, why end
    return plan
end

-- A plan from a table, or from text.
local function planOf(source)
    if type(source) == "string" then return parsePlan(source) end
    return normalize(source)
end

-- Where a cell is in a plan: its layer, row and column, or nil if it is above or below the layers, or before the
-- anchor's row or column.
local function locate(plan, x, y, z)
    local li, ri, ci = y - plan.anchor.y + 1, plan.anchor.z - z + 1, x - plan.anchor.x + 1
    if li < 1 or li > #plan.layers or ri < 1 or ci < 1 then return nil end
    return li, ri, ci
end

-- The entry a character stands for: nil for "leave alone", the air entry for ".".
local AIR_ENTRY = { name = AIR }
local function entryAt(plan, ch)
    if ch == "" or ch == " " then return nil end
    if ch == "." then return AIR_ENTRY end
    return plan.legend[ch]
end

-- A new plan, one cell a getter(x, y, z) -> name, state tells (nil: leave alone; air: "."), over the box.
local function render(x1, y1, z1, x2, y2, z2, getter)
    local plan = { anchor = { x = x1, y = y1, z = z2 }, legend = {}, layers = {} }
    local symbolOf, used = {}, 0
    for y = y1, y2 do
        local rows = {}
        for z = z2, z1, -1 do
            local cells = {}
            for x = x1, x2 do
                local name, state = getter(x, y, z)
                local ch = " "
                if name ~= nil and AIRS[name] then
                    ch = "."
                elseif name ~= nil then
                    local key = itemText(name, state)
                    ch = symbolOf[key]
                    if not ch then
                        used = used + 1
                        ch = SYMBOLS:sub(used, used)
                        if ch == "" then
                            return nil, "more than " .. #SYMBOLS .. " different blocks in one plan"
                        end
                        symbolOf[key] = ch
                        local copy
                        if state and next(state) then
                            copy = {}
                            for k, v in pairs(state) do copy[k] = tostring(v) end
                        end
                        plan.legend[ch] = { name = name, state = copy }
                    end
                end
                cells[#cells + 1] = ch
            end
            rows[#rows + 1] = table.concat(cells)
            breathe()
        end
        plan.layers[#plan.layers + 1] = tidyRows(rows)
    end
    return plan
end

-- The six numbers of a box in order (corners either way), or nil and why.
local function corners(x1, y1, z1, x2, y2, z2)
    local v = { x1, y1, z1, x2, y2, z2 }
    for i = 1, 6 do
        if not whole(v[i]) then return nil, "a box is x1, y1, z1, x2, y2, z2: whole numbers" end
    end
    return math.min(x1, x2), math.min(y1, y2), math.min(z1, z2), math.max(x1, x2), math.max(y1, y2), math.max(z1, z2)
end

-- A plan of one block over a box, kind "fill" (all of it), "box" (its six faces) or "walls" (its four sides).
local function shape(kind, x1, y1, z1, x2, y2, z2, item)
    local ax, ay, az, bx, by, bz = corners(x1, y1, z1, x2, y2, z2)
    if not ax then return nil, ay end
    local name, state = parseItem(item)
    if not name then return nil, state end
    return render(ax, ay, az, bx, by, bz, function(x, y, z)
        local side = x == ax or x == bx or z == az or z == bz
        if kind == "fill" or (kind == "walls" and side) or (kind == "box" and (side or y == ay or y == by)) then
            return name, state
        end
        return nil
    end)
end

-- Make a plan that is the whole box x1, y1, z1 to x2, y2, z2 (corners either way) filled with the block `item` (a
-- name, with a state in brackets if it has one).  Returns the plan, or nil and why.
function T.blueprint.fill(x1, y1, z1, x2, y2, z2, item)
    return shape("fill", x1, y1, z1, x2, y2, z2, item)
end

-- Make a plan that is the six faces of the box (floor, roof and walls) in the block `item`; the inside is left alone.
-- Returns the plan, or nil and why.
function T.blueprint.box(x1, y1, z1, x2, y2, z2, item)
    return shape("box", x1, y1, z1, x2, y2, z2, item)
end

-- Make a plan that is the four walls of the box, from its bottom to its top, in the block `item` (no floor or roof).
-- Returns the plan, or nil and why.
function T.blueprint.walls(x1, y1, z1, x2, y2, z2, item)
    return shape("walls", x1, y1, z1, x2, y2, z2, item)
end

-- Make a plan from what the map holds in the box (six numbers in a table, or {x1 =, ...}); returns it, or nil and why.
--
-- The blocks are as the map has them, with their states if they were inspected, air as ".", cells the map has never
-- seen left alone.
function T.blueprint.fromMap(box)
    local v = box
    if type(box) == "table" and box.x1 ~= nil then v = { box.x1, box.y1, box.z1, box.x2, box.y2, box.z2 } end
    if type(v) ~= "table" then return nil, "a box is { x1, y1, z1, x2, y2, z2 }" end
    local ax, ay, az, bx, by, bz = corners(v[1], v[2], v[3], v[4], v[5], v[6])
    if not ax then return nil, ay end
    local failure
    local plan, why = render(ax, ay, az, bx, by, bz, function(x, y, z)
        local name, state = T.map.get(x, y, z)
        if not name then
            if state ~= "not in the map" then failure = failure or state end
            return nil
        end
        return T.itemOfBlock(name), state
    end)
    if not plan then return nil, why end
    if failure then return nil, failure end
    return plan
end

-- Make a plan from a table or from the text of a plan file (the format in the overview), checked: every symbol in
-- the legend, the anchor whole numbers.  Returns the plan, or nil and why (with the line for text).
function T.blueprint.new(source)
    return planOf(source)
end

-- Read a plan from the text of a plan file.  Returns the plan, or nil and why, with the line.
function T.blueprint.parse(source)
    if type(source) ~= "string" then return nil, "parse wants the text of a plan" end
    return parsePlan(source)
end

-- A plan as text in the file format (what T.blueprint.parse reads).
function T.blueprint.format(plan)
    local p, why = normalize(plan)
    if not p then return nil, why end
    return formatPlan(p)
end

-- The block a plan has at x, y, z (turtle frame): its name and state table; "minecraft:air" for ".", nil for a cell it
-- leaves alone or does not reach.
function T.blueprint.at(plan, x, y, z)
    local li, ri, ci = locate(plan, x, y, z)
    if not li then return nil end
    local entry = entryAt(plan, (plan.layers[li][ri] or ""):sub(ci, ci))
    if not entry then return nil end
    return entry.name, entry.state
end

-- The box a plan covers: x1, y1, z1, x2, y2, z2 of the turtle's frame (the cells its text reaches).
function T.blueprint.extent(plan)
    local width, depth = 0, 0
    for _, rows in ipairs(plan.layers) do
        depth = math.max(depth, #rows)
        for _, row in ipairs(rows) do width = math.max(width, #row) end
    end
    local a = plan.anchor
    return a.x, a.y, a.z - math.max(depth, 1) + 1, a.x + math.max(width, 1) - 1, a.y + #plan.layers - 1, a.z
end

-- Set one cell of a plan, in its layers, to a block (`item`, with a state in brackets if it has one; "air" for air; nil
-- or " " to leave it alone).  Returns true, or nil and why.
--
-- (A plan from T.blueprint.fill of air makes room for any cell of its box.)
--
-- The cell must be in one of the plan's layers, and no lower in x or higher in z than the anchor; the lines of the layer
-- grow to hold it.
function T.blueprint.put(plan, x, y, z, item)
    local li, ri, ci = locate(plan, x, y, z)
    if not li then return nil, x .. "," .. y .. "," .. z .. " is outside the plan: above or below its layers, or before its anchor" end
    local ch = " "
    if item ~= nil and item ~= " " then
        local name, state = parseItem(item)
        if not name then return nil, state end
        if AIRS[name] then
            ch = "."
        else
            local wanted = itemText(name, state)
            for symbol, entry in pairs(plan.legend) do
                if not entry.after and itemText(entry.name, entry.state) == wanted then ch = symbol end
            end
            if ch == " " then
                for i = 1, #SYMBOLS do
                    local symbol = SYMBOLS:sub(i, i)
                    if not plan.legend[symbol] then ch = symbol; break end
                end
                if ch == " " then return nil, "the legend is full: " .. #SYMBOLS .. " different blocks" end
                plan.legend[ch] = { name = name, state = state }
            end
        end
    end
    local rows = plan.layers[li]
    while #rows < ri do rows[#rows + 1] = "" end
    local row = rows[ri]
    if #row < ci then row = row .. string.rep(" ", ci - #row) end
    rows[ri] = text.trimEnd(row:sub(1, ci - 1) .. ch .. row:sub(ci + 1))
    plan.layers[li] = tidyRows(rows)
    return true
end

--------------------------------------------------------------------------
-- The cells of a plan, in the order they are built
--------------------------------------------------------------------------

-- Is this cell the upper half of a door?  A door's state says (half=upper); with no state it is a door cell over a cell
-- of the same door.
local function isUpperHalf(plan, li, ri, ci, entry)
    if not infoOf(entry).door then return false end
    if entry.state and entry.state.half then return entry.state.half == "upper" end
    if li == 1 then return false end
    local below = entryAt(plan, (plan.layers[li - 1][ri] or ""):sub(ci, ci))
    return below ~= nil and below.name == entry.name
end

-- Call fn(cell) for each cell to place, in the order they are built, until fn returns true.  A cell is { n (its
-- number, from 1), x, y, z, name, state, entry }.  Layer by layer from the bottom; in a layer by rank (see RANK),
-- each rank in a snake over the lines.  Air, leave-alone cells and a door's upper half are not placed.  Returns true if
-- fn stopped it.
local function eachLayerCell(plan, fn)
    local n = 0
    local a = plan.anchor
    for li, rows in ipairs(plan.layers) do
        local buckets = {}
        for rank = 0, RANKS do buckets[rank] = {} end
        for ri, row in ipairs(rows) do
            for k = 1, #row do
                local ci = ri % 2 == 1 and k or (#row - k + 1)
                local entry = entryAt(plan, row:sub(ci, ci))
                if entry and not AIRS[entry.name] and not isUpperHalf(plan, li, ri, ci, entry) then
                    local rank = RANK[infoOf(entry).family] or 0
                    local bucket = buckets[rank]
                    bucket[#bucket + 1] = { ri, ci, entry }
                end
            end
            breathe()
        end
        for rank = 0, RANKS do
            for _, c in ipairs(buckets[rank]) do
                n = n + 1
                local cell = { n = n, x = a.x + c[2] - 1, y = a.y + li - 1, z = a.z - c[1] + 1,
                               name = c[3].name, state = c[3].state, entry = c[3] }
                if fn(cell) then return true end
            end
        end
    end
    return false
end

-- The ranks built column by column: what holds others up (blocks, logs, fences, walls, panes) and stairs, slabs and chests
local COLUMN_RANKS = 1
-- The column order of each plan, worked out once (the plan tables are kept while a build runs)
local columnCache = setmetatable({}, { __mode = "k" })

-- The cells of a plan in column order, as a list: first every block, stair and slab (the ranks to COLUMN_RANKS),
-- column by column, each column from the bottom up, the columns in a serpentine that goes on to the nearest column not
-- yet built (the first is the first the layer order meets); then what hangs on them and the doors, layer by layer as
-- the layer order has them.  So everything is still placed after what holds it.
local function columnList(plan)
    if columnCache[plan] then return columnCache[plan] end
    local a = plan.anchor
    local columns, byKey, late = {}, {}, {}
    for li, rows in ipairs(plan.layers) do
        local after = {}
        for rank = COLUMN_RANKS + 1, RANKS do after[rank] = {} end
        for ri, row in ipairs(rows) do
            for k = 1, #row do
                local ci = ri % 2 == 1 and k or (#row - k + 1)
                local entry = entryAt(plan, row:sub(ci, ci))
                if entry and not AIRS[entry.name] and not isUpperHalf(plan, li, ri, ci, entry) then
                    local rank = RANK[infoOf(entry).family] or 0
                    local cell = { x = a.x + ci - 1, y = a.y + li - 1, z = a.z - ri + 1, name = entry.name, state = entry.state, entry = entry }
                    if rank <= COLUMN_RANKS then
                        local key = ri .. "," .. ci
                        local col = byKey[key]
                        if not col then
                            col = { ri = ri, ci = ci, index = #columns + 1, cells = {} }
                            byKey[key] = col
                            columns[#columns + 1] = col
                        end
                        col.cells[#col.cells + 1] = cell
                    else
                        local bucket = after[rank]
                        bucket[#bucket + 1] = cell
                    end
                end
            end
            breathe()
        end
        for rank = COLUMN_RANKS + 1, RANKS do
            for _, cell in ipairs(after[rank]) do late[#late + 1] = cell end
        end
    end
    -- the serpentine: from the first column, on to the nearest one left (the earliest met on a tie)
    local list, left, at = {}, {}, nil
    for i, col in ipairs(columns) do left[i] = col end
    while #left > 0 do
        local best = 1
        if at then
            local bestD
            for i, col in ipairs(left) do
                local d = math.abs(col.ri - at.ri) + math.abs(col.ci - at.ci)
                if not bestD or d < bestD then best, bestD = i, d end
            end
        end
        at = table.remove(left, best)
        for _, cell in ipairs(at.cells) do list[#list + 1] = cell end
        breathe()
    end
    for _, cell in ipairs(late) do list[#list + 1] = cell end
    for n, cell in ipairs(list) do cell.n = n end
    columnCache[plan] = list
    return list
end

-- The cells in column order (see columnList), as eachLayerCell gives them.
local function eachColumnCell(plan, fn)
    for _, cell in ipairs(columnList(plan)) do
        if fn({ n = cell.n, x = cell.x, y = cell.y, z = cell.z, name = cell.name, state = cell.state, entry = cell.entry }) then return true end
    end
    return false
end

-- The orders a build can go in: "layer" (the default) or "column"
local ORDERS = { layer = eachLayerCell, column = eachColumnCell }

-- The hints a build follows with none given, by the family of a cell: when the cell's state is as named and the cell
-- at the offset holds the family named, the cell goes after that one.  A top slab under a stair goes after the
-- stair, so it is placed from below against it (the player's flights have a top slab under each stair).
local DEFAULT_HINTS = {
    slab = { state = { type = "top" }, offset = { 0, 1, 0 }, family = "stairs" },
}

-- The cell a cell is to go after, by its entry's hint or a default one, among the cells to place (byKey); nil for none.
local function afterOf(cell, byKey)
    local entry = cell.entry
    local offset, family = entry.after, nil
    if not offset then
        local rule = DEFAULT_HINTS[infoOf(entry).family]
        if not (rule and stateHolds(rule.state, entry.state)) then return nil end
        offset, family = rule.offset, rule.family
    end
    local other = byKey[(cell.x + offset[1]) .. "," .. (cell.y + offset[2]) .. "," .. (cell.z + offset[3])]
    if other == nil or other == cell or (family and infoOf(other.entry).family ~= family) then return nil end
    return other
end

-- The cells of a list with the hints followed: a cell whose hint names a cell later in the list goes right after it
-- (cells waiting for the same one in the list's order).  Hints that go round in a circle are let be: those cells go
-- in at the end, in the list's order.
local function followHints(list)
    local byKey, waitFor, hinted = {}, {}, false
    for _, cell in ipairs(list) do byKey[cell.x .. "," .. cell.y .. "," .. cell.z] = cell end
    for _, cell in ipairs(list) do
        waitFor[cell] = afterOf(cell, byKey)
        hinted = hinted or waitFor[cell] ~= nil
    end
    if not hinted then return list end
    local out, done, waiting = {}, {}, {}
    local function emit(first)
        local queue, i = { first }, 1
        while queue[i] do
            local cell = queue[i]
            i = i + 1
            if not done[cell] then
                out[#out + 1] = cell
                done[cell] = true
                for _, c in ipairs(waiting[cell] or {}) do queue[#queue + 1] = c end
                waiting[cell] = nil
            end
        end
    end
    for _, cell in ipairs(list) do
        local other = waitFor[cell]
        if other and not done[other] then
            waiting[other] = waiting[other] or {}
            table.insert(waiting[other], cell)
        else
            emit(cell)
        end
        breathe()
    end
    for _, cell in ipairs(list) do
        if not done[cell] then emit(cell) end
    end
    return out
end

-- The cells of each plan in each order, hints followed, numbered from 1 (worked out once: the plan tables are kept
-- while a build runs)
local buildLists = setmetatable({}, { __mode = "k" })

-- Call fn(cell) for each cell to place, in the order `order` builds them ("layer" if nil), until fn returns true.
local function eachBuildCell(plan, fn, order)
    order = order or "layer"
    local lists = buildLists[plan] or {}
    buildLists[plan] = lists
    if not lists[order] then
        local base = {}
        ORDERS[order](plan, function(cell) base[#base + 1] = cell end)
        lists[order] = followHints(base)
        for n, cell in ipairs(lists[order]) do cell.n = n end
    end
    for _, cell in ipairs(lists[order]) do
        if fn({ n = cell.n, x = cell.x, y = cell.y, z = cell.z, name = cell.name, state = cell.state, entry = cell.entry }) then
            return true
        end
        breathe()
    end
    return false
end

--------------------------------------------------------------------------
-- The saved build
--------------------------------------------------------------------------

local function dataFile(name) return T.dataPath(name) end

-- The saved build: { plan, text, order, done, failed = { [n] = why }, total, frame }, or nil.  frame is the T.frameId it was
-- saved in ("stale" once found in another; nil from before frames were numbered).
local function loadSaved()
    local planText = fileio.read(dataFile(PLAN_FILE))
    if not planText then return nil end
    local plan = parsePlan(planText)
    if not plan then return nil end
    local saved = { plan = plan, text = planText, order = "layer", done = 0, failed = {} }
    local progress = fileio.read(dataFile(PROGRESS_FILE))
    for _, line in ipairs(progress and text.lines(progress) or {}) do
        local kind, rest = text.cut(line, " ")
        if kind == "done" then
            saved.done = convert.toInteger(rest or "") or 0
        elseif kind == "order" and ORDERS[rest] then
            saved.order = rest
        elseif kind == "frame" then
            saved.frame = rest == "stale" and "stale" or convert.toInteger(rest or "")
        elseif kind == "failed" and rest then
            local number, why = text.cut(rest, " ")
            number = convert.toInteger(number)
            if number then saved.failed[number] = why or "failed" end
        end
    end
    local total = 0
    eachBuildCell(plan, function() total = total + 1 end, saved.order)
    saved.total = total
    return saved
end

-- Tell the job journal how far the build has got, if a job is on (without one nothing is loaded or written).
local function tellJob(job)
    if not fs.exists(dataFile(".job")) then return end
    local failed = #tables.sortedKeys(job.failed)
    local line = (job.plan.name or "build") .. ": " .. job.done .. " of " .. job.total .. " cells tried"
    if failed > 0 then line = line .. ", " .. failed .. " failed" end
    if job.done >= job.total and failed == 0 then line = line .. " (finished)" end
    local ok, err = pcall(T.job.progress, "build", line)
    if not ok and err == "Terminated" then error(err, 0) end
end

-- Write how far the build has got, and the frame it is in (job.frame, else this one).
local function writeProgress(job)
    local out = { "name " .. (job.plan.name or ""), "done " .. job.done, "frame " .. tostring(job.frame or T.frameId()) }
    if job.order ~= "layer" then out[#out + 1] = "order " .. job.order end      -- (no line: the layer order)
    for _, n in ipairs(tables.sortedKeys(job.failed)) do
        out[#out + 1] = "failed " .. n .. " " .. text.replace(tostring(job.failed[n]), "\n", " ")
    end
    return fileio.write(dataFile(PROGRESS_FILE), table.concat(out, "\n") .. "\n")
end

-- Write how far the build has got (and tell the job journal).
local function saveProgress(job)
    tellJob(job)
    return writeProgress(job)
end

-- Does the map say the cell already holds its block, with the state asked for (so it needs none of that block)?
local function mapHolds(cell, want)
    local name, state = T.map.get(cell.x, cell.y, cell.z)
    return isBlockOf(name, cell.entry) and stateHolds(want, state)
end

-- How many of each block the cells still to do need: { name = count }, how many cells, and whether any wants a compass
-- facing or axis (which needs the world origin).
local function tally(plan, job)
    local need, cells, compass = {}, 0, false
    eachBuildCell(plan, function(cell)
        if cell.n > job.done or job.failed[cell.n] then
            cells = cells + 1
            local want = wantsOf(cell.entry)
            if (want.facing and want.facing ~= "up" and want.facing ~= "down") or (want.axis and want.axis ~= "y") then compass = true end
            if not mapHolds(cell, want) then need[cell.name] = (need[cell.name] or 0) + (isDouble(cell.entry) and 2 or 1) end
        end
    end, job.order)
    return need, cells, compass
end

--------------------------------------------------------------------------
-- Building
--------------------------------------------------------------------------

-- Put one cell in place: true, or false and why; the second answer is true when it was there already.  support: the
-- build's opts that T.placeAt takes on (digBelow, temp).
local function putCell(cell, move, look, support)
    local want, asked = wantsOf(cell.entry)
    if isDouble(cell.entry) then
        -- a double slab: a bottom half, then a second slab placed down onto it from above
        want.type = nil
        if not look and mapHolds(cell, { type = "double" }) then return true, true end
        if T.countItem(cell.name) < 2 then return false, "a double " .. cell.name .. " takes two, and there are fewer on board" end
        local opts = { move = move, half = "bottom" }
        local name, why = T.placeAt(cell.x, cell.y, cell.z, cell.name, opts)
        if not name then return false, why end
        local ok, moveWhy = T.moveTo(cell.x, cell.y + 1, cell.z, move)
        if not ok then return false, "couldn't get over the half slab: " .. tostring(moveWhy) end
        T.selectItem(cell.name)
        T.placeDir("down")
        local found, data = T.look("down")
        if found and type(data) == "table" and data.state and data.state.type == "double" then return true end
        return false, "the second half didn't go onto the slab at " .. cell.x .. "," .. cell.y .. "," .. cell.z
    end
    local plain = asked == 0 and PLAIN_FAMILIES[infoOf(cell.entry).family] and not unlearnt(cell.name)
    -- (the map says it is there: a cell done before a crash, or a plan built over itself; opts.look goes to see)
    if not look and mapHolds(cell, want) then return true, true end
    if T.countItem(cell.name) == 0 then return false, "no " .. cell.name .. " on board" end
    if plain then
        local ok = T.moveTo(cell.x, cell.y + 1, cell.z, move)
        if ok then
            local found, data = T.look("down")
            local here = found and type(data) == "table" and data.name or nil
            if isBlockOf(here, cell.entry) then return true, true end
            T.selectItem(cell.name)
            if T.placeDir("down") then return true end
            if here then return false, here .. " is in the way at " .. cell.x .. "," .. cell.y .. "," .. cell.z end
            -- (nothing seen there: some other way in may do)
        end
    end
    local opts = { move = move, digBelow = support.digBelow, temp = support.temp, exit = support.exit,
                   refuseSeal = support.refuseSeal ~= false }
    for key, value in pairs(want) do opts[key] = value end
    local name, stateOrWhy, how = T.placeAt(cell.x, cell.y, cell.z, cell.name, opts)
    if not name then return false, stateOrWhy end
    return true, how.approach == "already there", how.warning
end

-- The shortfall of a tally against what is on board: a list of { item, need, have, short }, sorted by name, each with
-- what the craft module says if it is there.
local function shortOf(need)
    local short = {}
    for _, name in ipairs(tables.sortedKeys(need)) do
        local have = T.countItem(name)
        if have < need[name] then
            short[#short + 1] = { item = name, need = need[name], have = have, short = need[name] - have }
        end
    end
    if #short > 0 and T.registry.canCraft then
        local canCraft = T.need("canCraft")
        for _, row in ipairs(short) do
            if canCraft then
                local ok, result = pcall(canCraft, row.item, row.short)
                if ok then row.craft = result end
            end
        end
    end
    return short
end

-- The shortfall as a sentence.
local function shortText(short)
    local parts = {}
    for i, row in ipairs(short) do
        local note = ""
        if row.craft == true then note = ", can be crafted"
        elseif type(row.craft) == "string" then note = ", " .. row.craft end
        parts[i] = text.replace(row.item, "minecraft:", "") .. ": need " .. row.need .. ", have " .. row.have .. note
    end
    return "short of " .. table.concat(parts, "; ")
end

-- A name for the area a finished build protects: opts.protect if it is a name, else the plan's.
local function protectName(plan, opts)
    if type(opts.protect) == "string" and opts.protect ~= "keep" then return opts.protect end
    return plan.name or "build"
end

-- The fuel watch: a build stops when it has spent more than WATCH_LIMIT times what T.fuelFor says its cells so far should
-- cost, once WATCH_AFTER cells are tried (a few cells may cost more than their share)
local WATCH_LIMIT, WATCH_AFTER = 3, 8

-- What T.fuelFor says a plan costs: its info, or nil if there is no estimate.  (It answers true, info or false, why, info.)
local function estimateOf(fuelFor, plan)
    local ok, first, second, third = pcall(fuelFor, plan)
    if not ok then
        if first == "Terminated" then error(first, 0) end
        return nil
    end
    if first == true then return second end
    if first == false then return third end
    return nil
end

-- The fuel watch for a build: { approach (the way to the first cell to try), perCell, spent = 0 } from T.fuelFor's
-- estimates (a cell's share of the whole plan's, less the way to it), or nil if there are none.
local function fuelWatch(job)
    local fuelFor = T.need("fuelFor")
    if not fuelFor or job.total < 1 then return nil end
    local x1, y1, z1 = bp.extent(job.plan)
    local first
    eachBuildCell(job.plan, function(cell)
        if cell.n > job.done or job.failed[cell.n] then first = cell end
        return first ~= nil
    end, job.order)
    first = first or { x = x1, y = y1, z = z1 }
    local all = estimateOf(fuelFor, { build = job.text })
    local corner = estimateOf(fuelFor, { route = { { x = x1, y = y1, z = z1 } } })
    local way = estimateOf(fuelFor, { route = { { x = first.x, y = first.y, z = first.z } } })
    if not (all and corner and way) then return nil end
    return { approach = way.route, perCell = math.max(all.build - corner.route, job.total) / job.total, spent = 0 }
end

-- Build a plan (opts.order = "column": walls for less fuel), materials checked first, progress kept, stopping if it
-- circles.  Returns true, info; false, why, info when it stopped or cells failed; nil, why when it couldn't begin.
--
-- `plan` is a plan (table or text); nil carries on the build saved in the data file after a stop, a crash or a
-- reboot.  The same plan again carries on too (its failed cells tried again); a different plan while one has cells
-- not yet tried is refused unless opts.restart (the refusal counts what was tried and what failed).  One whose every
-- cell was tried, some failing, doesn't stand in the way: the new plan starts, and info.previous = { name, failed }
-- lists the old one's failures.  It first counts what the cells still to do need against what is on board, and refuses if anything is
-- short (the reply's third value lists { item, need, have, short }, and what T.canCraft says if there is such a
-- function) unless opts.partial; cells with no item left fail one by one.  A cell that fails is noted and the build goes
-- on; the failed ones are tried again at the end of a later run (opts.retry = false leaves them).  Nothing is dug
-- out of a cell it fills: a block in the way is a failure.
-- A cell the map already shows holding the block (with its state) is taken as done without a look, so a plan built
-- over itself, or carried on after a crash, goes quickly; opts.look goes and looks at every cell instead.
-- opts.order is "layer" (the default) or "column" (see the overview: cheaper for walls); a build carried on keeps the
-- order it began with.  A build saved before a re-zero (T.frameStale) is not carried on: T.build() says why and marks it
-- stale, and a plan given starts afresh.  The fuel watch counts the moves and stops the build, progress kept, when after 8 cells they
-- come to over 3 times T.fuelFor's estimate for the cells so far: "circling: N fuel for M cells, estimate E";
-- opts.fuelWatch = false turns it off.
-- opts: at ({ x, y, z }: build with the plan's anchor here), look, move (for T.moveTo; default { path = true, scan =
-- false }), inside (a protected area the job owns), limit (the most cells to try in this run), restart,
-- partial, retry, protect ("keep", true or an area name: protect the finished build under the plan's name, or
-- that name; only when no cell failed), order, fuelWatch, player (false: no T.lint at the end), digBelow, temp and exit
-- (for T.placeAt: a top slab on a floor is placed from where the floor is, dug and put back, only with digBelow; a
-- cell that would cut the way to exit is refused), refuseSeal (ADR-0020 D1: by default a placement after which the map
-- shows no way out for the turtle is refused, and the cell's next way in tried; a cell with none fails, saying why;
-- false only warns, in info.sealed).
-- Info is { name, done, total, failed = list of { n, x, y, z, item, why }, placed (cells put in this run), there
-- (cells found already in place), finished, resumed, protected, short, order, fuel = { spent, estimate, perCell },
-- warnings, topDrops, previous, sealed (a line for each placement that closed the turtle in: T.placeAt's warning;
-- opts.exit refuses those instead, each cell failing with why) }.
-- Once every cell has been tried, the plan is put through T.lint (what stops a two-tall player): its warnings are
-- info.warnings (each tagged where = "plan" or "around"); the plan's own are printed, a line a rule ("player: headroom
-- at 3,1,4: ..."), drops on the plan's top (wall tops) as one count (their cells info.topDrops), and those round it
-- (terrain, other buildings) as one count ("player: 4 more round it"); they never change the result.
function T.build(plan, opts)
    opts = opts or {}
    local saved = loadSaved()
    -- a build saved before a re-zero is in the old frame: its cells would go in the wrong place, so it is marked stale
    -- and never carried on (a plan given starts afresh)
    local stale = saved and T.frameStale(saved.frame)
    if stale then
        if saved.frame ~= "stale" then
            saved.frame = "stale"
            writeProgress(saved)
        end
        if plan == nil then
            return nil, "the build \"" .. (saved.plan.name or "build") .. "\" can't be carried on: " .. stale
                .. "; give T.build a plan to start one here"
        end
        saved = nil
    end
    if opts.order ~= nil and not ORDERS[opts.order] then return nil, "opts.order is \"layer\" or \"column\", not " .. tostring(opts.order) end
    local job, previous
    if plan == nil then
        if not saved then return nil, "no build in progress: give T.build a plan" end
        job = { plan = saved.plan, text = saved.text, order = saved.order, done = saved.done, failed = saved.failed, total = saved.total,
                resumed = true }
    else
        local p, why = planOf(plan)
        if not p then return nil, why end
        if opts.at then
            local at = opts.at
            local ax, ay, az = at.x or at[1], at.y or at[2], at.z or at[3]
            if not (whole(ax) and whole(ay) and whole(az)) then return nil, "opts.at is { x, y, z }, whole numbers" end
            p.anchor = { x = ax, y = ay, z = az }
        end
        -- (the name is part of the plan as it is kept, so it goes in before the plan is compared with the saved one)
        if opts.name then p.name = opts.name end
        local planText = formatPlan(p)
        local untried = saved and saved.done < saved.total
        local unfinished = saved and (untried or next(saved.failed) ~= nil)
        if saved and saved.text == planText and unfinished and not opts.restart then
            job = { plan = saved.plan, text = saved.text, order = saved.order, done = saved.done, failed = saved.failed, total = saved.total,
                    resumed = true }
        else
            local failedBefore = {}
            for _, n in ipairs(saved and tables.sortedKeys(saved.failed) or {}) do
                failedBefore[#failedBefore + 1] = { n = n, why = saved.failed[n] }
            end
            if untried and not opts.restart then
                return nil, "the build \"" .. (saved.plan.name or "build") .. "\" is unfinished (" .. saved.done .. " of " .. saved.total ..
                    " cells tried" .. (#failedBefore > 0 and (", " .. #failedBefore .. " failed") or "") ..
                    "): T.build() carries it on, or pass restart = true to start this plan instead"
            end
            if #failedBefore > 0 then previous = { name = saved.plan.name or "build", failed = failedBefore } end
            local order = opts.order or "layer"
            local total = 0
            eachBuildCell(p, function() total = total + 1 end, order)
            job = { plan = p, text = planText, order = order, done = 0, failed = {}, total = total }
        end
    end
    local target = job.plan
    if opts.name then target.name = opts.name end
    local need, remaining, compass = tally(target, job)
    if compass and not T.origin() then
        return nil, "this plan names a compass facing or axis, which needs the world origin: T.setOrigin(x, y, z, facing)"
    end
    local info = { name = target.name, done = job.done, total = job.total, failed = {}, placed = 0, there = 0, resumed = job.resumed == true,
                   finished = false, order = job.order, previous = previous, sealed = {} }
    local short = shortOf(need)
    if #short > 0 and not opts.partial then
        info.short = short
        return nil, shortText(short) .. " (opts.partial builds what it can)", info
    end
    local wrote, err = fileio.write(dataFile(PLAN_FILE), formatPlan(target))
    if not wrote then return nil, "couldn't save the plan: " .. tostring(err), info end
    saveProgress(job)
    local move = opts.move or { path = true, scan = false }
    if job.order == "column" and move.order == nil then      -- (from the top of one column across to the next, then down)
        move = tables.copy(move)
        move.order = "xzy"
    end
    local attempted, limit = 0, opts.limit or math.huge
    local sinceSave = 0
    local startDone = job.done
    local watch = opts.fuelWatch ~= false and fuelWatch(job) or nil
    info.fuel = watch and { estimate = math.ceil(watch.approach), spent = 0, perCell = watch.perCell } or nil

    local function attempt(cell)
        local good, extra, sealed = putCell(cell, move, opts.look, opts)      -- (extra: already there, or why not)
        if sealed then info.sealed[#info.sealed + 1] = cell.x .. "," .. cell.y .. "," .. cell.z .. ": " .. sealed end
        attempted = attempted + 1
        if good then
            job.failed[cell.n] = nil
            if extra then info.there = info.there + 1 else info.placed = info.placed + 1 end
        else
            job.failed[cell.n] = extra or "failed"
        end
        sinceSave = sinceSave + 1
        if sinceSave >= 8 then sinceSave = 0; saveProgress(job) end
        if watch then
            local estimate = math.ceil(watch.approach + watch.perCell * attempted)
            info.fuel.estimate, info.fuel.spent = estimate, watch.spent
            if attempted >= WATCH_AFTER and watch.spent > WATCH_LIMIT * estimate then
                job.circling = "circling: " .. watch.spent .. " fuel for " .. attempted .. " cells, estimate " .. estimate
                return true
            end
        end
        return attempted >= limit
    end
    local function run()
        local stopped = eachBuildCell(target, function(cell)
            if cell.n <= job.done then return false end
            local stop = attempt(cell)
            job.done = cell.n
            return stop
        end, job.order)
        if stopped or opts.retry == false then return stopped end
        return eachBuildCell(target, function(cell)
            if cell.n > startDone or not job.failed[cell.n] then return false end
            return attempt(cell)
        end, job.order)
    end
    local function go()
        local stopWatching = watch and T.onChange(function(e)
            if e.kind == "move" then watch.spent = watch.spent + 1 end
        end)
        local ok, result = pcall(run)
        if stopWatching then stopWatching() end
        saveProgress(job)
        if not ok then error(result, 0) end
        return result
    end
    local stopped
    if opts.inside then stopped = T.inside(opts.inside, go) else stopped = go() end

    info.done = job.done
    for _, n in ipairs(tables.sortedKeys(job.failed)) do info.failed[#info.failed + 1] = { n = n, why = job.failed[n] } end
    local byNumber = {}
    for _, f in ipairs(info.failed) do byNumber[f.n] = f end
    if #info.failed > 0 then
        eachBuildCell(target, function(cell)
            local f = byNumber[cell.n]
            if f then f.x, f.y, f.z, f.item = cell.x, cell.y, cell.z, cell.name end
        end, job.order)
    end
    info.finished = job.done >= job.total and #info.failed == 0
    if info.finished and opts.protect then
        local x1, y1, z1, x2, y2, z2 = bp.extent(target)
        local area = protectName(target, opts)
        local ok, why = T.protect(area, x1, y1, z1, x2, y2, z2)
        info.protected = ok and area or nil
        if not ok then info.protectWhy = why end
    end
    -- how a player meets the build, once every cell is tried: warnings beside the result, which they don't change
    if job.done >= job.total and opts.player ~= false then
        local ok, warnings, lint = pcall(T.lint, target)
        if not ok and warnings == "Terminated" then error(warnings, 0) end
        if ok and warnings then
            info.warnings, info.topDrops = warnings, lint.topDrops
            for _, line in ipairs(lint.planSummary or lint.summary) do print("player: " .. line) end
            if (lint.around or 0) > 0 then print("player: " .. lint.around .. " more round it (T.lint(box) lists them)") end
        end
    end
    if info.finished then return true, info end
    if job.circling then
        local hint = job.order == "layer" and "order = \"column\" may cost less; " or ""
        return false, job.circling .. ": stopped after " .. job.done .. " of " .. job.total .. " cells (" .. hint .. "T.build() carries on, " ..
            "opts.fuelWatch = false turns the watch off)", info
    end
    if stopped and job.done < job.total then
        return false, "stopped after " .. attempted .. " cells (" .. job.done .. " of " .. job.total .. " tried): T.build() carries on", info
    end
    local first = info.failed[1]
    return false, #info.failed .. " cells failed, the first " .. tostring(first.item) .. " at " .. tostring(first.x) .. "," ..
        tostring(first.y) .. "," .. tostring(first.z) .. ": " .. tostring(first.why), info
end

--------------------------------------------------------------------------
-- Checking
--------------------------------------------------------------------------

-- The plan to check or build: the one given, else the saved build's.
local function planToUse(plan, opts)
    local p, why
    if plan == nil then
        local saved = loadSaved()
        if not saved then return nil, "no plan given and no build saved" end
        p = saved.plan
    else
        p, why = planOf(plan)
        if not p then return nil, why end
    end
    if opts and opts.at then
        local at = opts.at
        local ax, ay, az = at.x or at[1], at.y or at[2], at.z or at[3]
        if not (whole(ax) and whole(ay) and whole(az)) then return nil, "opts.at is { x, y, z }, whole numbers" end
        p.anchor = { x = ax, y = ay, z = az }
    end
    return p
end

-- Check a plan against the world: the cells that differ, as a list of { x, y, z, want, wantState, found,
-- foundState, why, unverified }, and { checked, inspected, differing, unverified }; nil and why if it can't start.
--
-- `plan` is a plan; nil checks the saved build.  Every cell the plan does not leave alone is compared: the block's name,
-- and each key of the state the plan names.  A cell with a state to match, or that the map has never seen, is looked
-- at with T.inspectAll (opts.inspect = "all" looks at every cell); the rest is read from the map, which the
-- build keeps right.  A cell that could not be looked at is listed too, with unverified = true.  An empty list means the
-- build is as planned.  opts: at ({ x, y, z }), scan (true: scan the box with T.scanBox first), inspect, move
-- (for the walking), inside, player (true: T.lint the plan's box of the map as well, after the look, for what stops a
-- two-tall player: its warnings are info.warnings, and why it couldn't info.playerWhy).
function T.verify(plan, opts)
    opts = opts or {}
    local p, why = planToUse(plan, opts)
    if not p then return nil, why end
    local move = opts.move or { path = true, scan = false }
    local cells, look = {}, {}
    local a = p.anchor
    for li, rows in ipairs(p.layers) do
        for ri, row in ipairs(rows) do
            for ci = 1, #row do
                local entry = entryAt(p, row:sub(ci, ci))
                if entry then
                    local cell = { x = a.x + ci - 1, y = a.y + li - 1, z = a.z - ri + 1, entry = entry }
                    cells[#cells + 1] = cell
                end
            end
            breathe()
        end
    end
    if opts.scan then
        local x1, y1, z1, x2, y2, z2 = bp.extent(p)
        T.scanBox({ x1 = x1, y1 = y1, z1 = z1, x2 = x2, y2 = y2, z2 = z2 }, { move = move })
    end
    for _, cell in ipairs(cells) do
        local name, state = T.map.get(cell.x, cell.y, cell.z)
        cell.name, cell.state = name, state
        if opts.inspect == "all" or name == nil or next(cell.entry.state or {}) ~= nil then
            look[#look + 1] = { x = cell.x, y = cell.y, z = cell.z }
            cell.inspect = true
        end
        breathe()
    end
    local failed = {}
    local function verifyAll()
        if #look == 0 then return end
        local found, couldNot = T.inspectAll(look, { move = move })
        for _, cell in ipairs(cells) do
            local got = cell.inspect and found[cell.x .. "," .. cell.y .. "," .. cell.z]
            if got then cell.name, cell.state = got.name, got.state end
        end
        for _, f in ipairs(couldNot or {}) do failed[f.x .. "," .. f.y .. "," .. f.z] = f.why end
    end
    if opts.inside then T.inside(opts.inside, verifyAll) else verifyAll() end
    local diffs = {}
    local info = { checked = #cells, inspected = #look, differing = 0, unverified = 0 }
    for _, cell in ipairs(cells) do
        local want = cell.entry
        local row
        local couldNot = cell.inspect and failed[cell.x .. "," .. cell.y .. "," .. cell.z]
        if couldNot and (cell.name == nil or next(want.state or {}) ~= nil) then
            row = { why = "couldn't look at it: " .. tostring(couldNot), unverified = true }
        elseif cell.name == nil then
            row = { why = "not in the map", unverified = true }
        else
            local sameName = isBlockOf(cell.name, want) or (AIRS[cell.name] and AIRS[want.name])
            if not sameName or not stateHolds(want.state, cell.state) then
                row = { why = "wanted " .. itemText(want.name, want.state) .. ", found " .. itemText(cell.name, cell.state) }
            end
        end
        if row then
            row.x, row.y, row.z = cell.x, cell.y, cell.z
            row.want, row.wantState, row.found, row.foundState = want.name, want.state, cell.name, cell.state
            diffs[#diffs + 1] = row
            if row.unverified then info.unverified = info.unverified + 1 else info.differing = info.differing + 1 end
        end
    end
    table.sort(diffs, function(m, n)
        if m.y ~= n.y then return m.y < n.y end
        if m.z ~= n.z then return m.z > n.z end
        return m.x < n.x
    end)
    if opts.player then
        local warnings, why = T.lint({ bp.extent(p) })
        info.warnings = warnings
        if not warnings then info.playerWhy = why end
    end
    return diffs, info
end

--------------------------------------------------------------------------
-- Swapping blocks
--------------------------------------------------------------------------

-- The cells next to a block the turtle could stand in, best first (the map says air; then never seen), as { x, y, z }.
local function standsFor(cell)
    local out = {}
    for _, d in ipairs({ 0, 1, 2, 3, "up", "down" }) do
        local v = T.DELTA[d]
        local s = { x = cell.x + v[1], y = cell.y + v[2], z = cell.z + v[3] }
        local name = T.map.get(s.x, s.y, s.z)
        if name == nil then s.rank = 2 elseif AIRS[name] then s.rank = 1 end
        if s.rank then
            s.dist = T.dist(T.pos, s)
            out[#out + 1] = s
        end
    end
    table.sort(out, function(m, n)
        if m.rank ~= n.rank then return m.rank < n.rank end
        if m.dist ~= n.dist then return m.dist < n.dist end
        if m.x ~= n.x then return m.x < n.x end
        if m.y ~= n.y then return m.y < n.y end
        return m.z < n.z
    end)
    return out
end

-- Swap every block in a box whose name matches a glob for another block: how many, and what could not be.
-- Returns true, info; false, why, info when some were trapped or failed; nil, why when it couldn't begin.
--
-- The box is six numbers in a table, or { x1 =, ... }; the glob matches block names (the namespace may be left
-- out); `item` is the block to put in, with a state in brackets if it has one.  The cells are those the map holds (opts.scan
-- scans the box first, which the map needs to know it).  Each is taken from the nearest free side the map shows, nearest
-- next: the turtle looks at the block (one that has changed since is left), digs it and places the new one.  A block
-- with no free side (every neighbour solid in the map) is listed in `trapped` and never dug to, unless opts.digBelow:
-- then (for a plain block) a neighbour with air over it is dug, stood in, the block swapped from there, and the
-- neighbour put back from above with the same block (one that digging gives back, T.dropsItself, or one carried).  It
-- refuses if there is less of `item` on board than cells to swap, unless opts.partial.  Info is { replaced, same,
-- trapped, failed, gone, more, via (swapped by way of a neighbour) }, trapped and failed being lists of { x, y, z,
-- name, why }.  opts: scan, limit (cells at most, default 1000), move (for T.moveTo), inside (a protected area the
-- job owns, to swap blocks in it), partial, digBelow.
function T.replace(box, pattern, item, opts)
    opts = opts or {}
    local name, state = parseItem(item)
    if not name then return nil, state end
    if type(pattern) ~= "string" or pattern == "" then return nil, "replace wants a glob of block names to swap" end
    local entry = { name = name, state = state }
    local want, asked = wantsOf(entry)
    local plain = asked == 0 and PLAIN_FAMILIES[infoOf(entry).family]
    if opts.scan then
        local v = box
        if type(box) == "table" and box.x1 == nil then v = { x1 = box[1], y1 = box[2], z1 = box[3], x2 = box[4], y2 = box[5], z2 = box[6] } end
        local scanned, why = T.scanBox(v, { move = opts.move or { path = true, scan = false } })
        if not scanned then return nil, "couldn't scan the box: " .. tostring(why) end
    end
    local found, cut = T.map.find(pattern, box, opts.limit or 1000)
    if not found then return nil, cut end
    local test = T.nameTest(pattern)     -- (as T.map.find: a glob with no namespace also matches the short name)
    local todo, info = {}, { replaced = 0, same = 0, trapped = {}, failed = {}, gone = 0, more = cut == true, via = 0 }
    for _, c in ipairs(found) do
        local _, now = T.map.get(c.x, c.y, c.z)
        if c.name == name and (not state or stateHolds(state, now)) then info.same = info.same + 1 else todo[#todo + 1] = c end
    end
    local have = T.countItem(name)
    if have < #todo and not opts.partial then
        return nil, "short of " .. text.replace(name, "minecraft:", "") .. ": " .. #todo .. " blocks to swap, have " .. have ..
            " (opts.partial swaps as many as it can)", info
    end
    if asked > 0 and (want.facing or (want.axis and want.axis ~= "y")) and not T.origin() then
        return nil, "a compass facing or axis needs the world origin: T.setOrigin(x, y, z, facing)"
    end
    local move = opts.move or { path = true, scan = false }
    -- (ADR-0015 D8.5) A trapped cell by way of a neighbour n with air over it: dig n from above, stand in it, swap the
    -- cell, step out and put n back.  True; or false and why (n put back if it was dug).
    local function viaNeighbour(c)
        local why = "no neighbour with air over it that can be dug and put back"
        for _, d in ipairs({ "up", 0, 1, 2, 3 }) do
            local v = T.DELTA[d]
            local n = { x = c.x + v[1], y = c.y + v[2], z = c.z + v[3] }
            local nName, nState = T.map.get(n.x, n.y, n.z)
            local over = T.map.get(n.x, n.y + 1, n.z)
            if nName and nName ~= AIR and (over == AIR or over == "minecraft:cave_air") and not T.guarded(n.x, n.y, n.z)
                and (T.dropsItself(nName) or T.countItem(nName) > 0) then
                local ok, moveWhy = T.moveTo(n.x, n.y + 1, n.z, move)
                if not ok then
                    why = "couldn't get over " .. T.posKey(n) .. ": " .. tostring(moveWhy)
                else
                    local seen, data = T.look("down")
                    local now = seen and type(data) == "table" and data.name or nil
                    if now ~= nName then
                        why = T.posKey(n) .. " is " .. tostring(now) .. " now, not " .. nName
                    else
                        local dug, digWhy = T.digDir("down")
                        if not dug then
                            why = "couldn't dig " .. T.posKey(n) .. ": " .. tostring(digWhy)
                        else
                            local result
                            if T.moveDir("down") then
                                local dc = T.dirTo(c)
                                local cSeen, cData = T.look(dc)
                                local here = cSeen and type(cData) == "table" and cData.name or nil
                                if not (here and test(here)) then
                                    result = "it is " .. tostring(here) .. " now"
                                else
                                    local cDug, cWhy = T.digDir(dc)
                                    if not cDug then result = "couldn't dig it from " .. T.posKey(n) .. ": " .. tostring(cWhy)
                                    else
                                        T.selectItem(name)
                                        local placed, placeWhy = T.placeDir(dc)
                                        if not placed then result = "dug it but couldn't place " .. name .. ": " .. tostring(placeWhy) end
                                    end
                                end
                                T.moveDir("up")
                            else
                                result = "couldn't step into " .. T.posKey(n)
                            end
                            -- the neighbour back as it was
                            local back = T.selectItem(nName) and T.placeDir("down")
                            if not back then
                                return false, (result and (result .. "; ") or "") .. T.posKey(n) .. " not put back: no " .. nName .. " to place"
                            end
                            if result then return false, result end
                            return true
                        end
                    end
                end
            end
        end
        return false, why
    end
    local function swapOne(c)
        local stands = standsFor(c)
        if #stands == 0 then
            if opts.digBelow and plain and T.countItem(name) > 0 then
                local ok, why = viaNeighbour(c)
                if ok then
                    info.replaced, info.via = info.replaced + 1, info.via + 1
                    return
                end
                info.trapped[#info.trapped + 1] = { x = c.x, y = c.y, z = c.z, name = c.name, why = "no free side, and by way of a neighbour: " .. why }
                return
            end
            info.trapped[#info.trapped + 1] = { x = c.x, y = c.y, z = c.z, name = c.name,
                why = "no free side: every neighbour is solid in the map" .. (plain and " (opts.digBelow goes in by way of one)" or "") }
            return
        end
        local why
        for _, s in ipairs(stands) do
            local ok, reason = T.moveTo(s.x, s.y, s.z, move)
            if ok then
                local d = T.dirTo(c)
                local seen, data = T.look(d)
                local here = seen and type(data) == "table" and data.name or nil
                if not here then
                    T.map.set(c.x, c.y, c.z, AIR)
                    info.gone = info.gone + 1
                    return
                end
                if not test(here) then
                    T.map.set(c.x, c.y, c.z, here, data.state)
                    info.gone = info.gone + 1
                    return
                end
                if T.countItem(name) == 0 then
                    info.failed[#info.failed + 1] = { x = c.x, y = c.y, z = c.z, name = c.name, why = "no " .. name .. " left on board" }
                    return
                end
                local dug, digWhy = T.digDir(d)
                if not dug then
                    info.failed[#info.failed + 1] = { x = c.x, y = c.y, z = c.z, name = c.name, why = "couldn't dig it: " .. tostring(digWhy) }
                    return
                end
                local placed, placeWhy
                if plain then
                    T.selectItem(name)
                    placed, placeWhy = T.placeDir(d)
                else
                    local opts2 = { move = move }
                    for key, value in pairs(want) do opts2[key] = value end
                    placed, placeWhy = T.placeAt(c.x, c.y, c.z, name, opts2)
                end
                if placed then
                    info.replaced = info.replaced + 1
                else
                    info.failed[#info.failed + 1] = { x = c.x, y = c.y, z = c.z, name = c.name,
                        why = "dug it but couldn't place " .. name .. ": " .. tostring(placeWhy) }
                end
                return
            end
            why = reason
        end
        info.failed[#info.failed + 1] = { x = c.x, y = c.y, z = c.z, name = c.name, why = "couldn't get next to it: " .. tostring(why) }
    end
    local function loop()
        while #todo > 0 do
            local best = 1
            for i = 2, #todo do
                if T.dist(T.pos, todo[i]) < T.dist(T.pos, todo[best]) then best = i end
            end
            swapOne(table.remove(todo, best))
            breathe()
        end
    end
    if opts.inside then T.inside(opts.inside, loop) else loop() end
    if #info.trapped == 0 and #info.failed == 0 then return true, info end
    return false, info.replaced .. " swapped, " .. #info.trapped .. " with no free side, " .. #info.failed .. " failed", info
end

return T
