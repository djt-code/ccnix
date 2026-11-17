-- store.lua -- chests at home: where they are, what is in them, fetching from them and putting away
--
-- Loaded by turtlelib the first time one of its functions is used (T.addChest, T.forgetChest, T.chests, T.catalogue,
-- T.where, T.fetch, T.stow, T.recount, T.inventoryReport, T.prepare, T.autoDump), or when T.cfg.autoDump is set.
--
-- A chest is known by where the turtle stands to reach it, as the junk chest is (T.setJunkChest): the cell x, y, z in the
-- turtle's frame, and the side the chest is on ("up", "down", or a heading 0 to 3).  T.addChest tells the turtle about
-- one, T.catalogue goes round them and writes down what each holds, T.where says which have an item, T.fetch goes and
-- takes some, T.stow puts what the turtle carries away (into a chest that already holds that item, else into the bulk
-- chest) and T.autoDump is that done for you when the inventory nearly fills: T.cfg.autoDump = true (or a number of free
-- slots) and every dig is followed, when the room has run out, by a trip to the chests and back.  With no chests known
-- it takes the junk chest's trip instead (T.dumpJunk).  T.inventoryReport adds up what the chests and the turtle hold,
-- and T.prepare readies the turtle for a job in one trip: what isn't needed put away, what is fetched, the room checked.
--
-- A chest is one record however it is reached: a second stand for the same chest (the cell the stand and side point at)
-- is the same chest, and so are the two halves of a double chest (each half is a peripheral listing the whole of it), which
-- T.catalogue finds out from the halves' block states (by their facing when the world origin is known, else by two
-- halves side by side holding the same).
--
-- The chests and what they held when last looked at are in the data file .chests, so every program on the turtle
-- shares them and a restart keeps them.  A line "chest x y z side bulk|plain seen" starts a chest ("seen" the time it was
-- read, in seconds), "other x y z" after it is the other half's cell for a double chest, and the lines "item count name"
-- are what it held.  Fetching and stowing read the chest again as they go, and so does crafting at a known chest
-- (T.recount: the chest beside the turtle read again), so the list stays right; a chest someone else emptied is found
-- out the next time it is visited.

local T = require("turtlelib")
local text = require("text")
local convert = require("convert")
local fileio = require("fileio")
local tables = require("tables")

local FILE = ".chests"
local NS = "minecraft:"
-- The words for the side a chest is on, as the file keeps them: a heading (T.dir's 0 to 3), up or down
local SIDES = { up = "up", top = "up", down = "down", bottom = "down", [0] = 0, [1] = 1, [2] = 2, [3] = 3 }
-- The compass in the turtle's headings' order, and which way a double chest's half has its other half: a left half's
-- is clockwise from the way it faces, a right half's anticlockwise (Minecraft's ChestBlock)
local COMPASS_AT = { north = 0, east = 1, south = 2, west = 3 }
local HALF_TURN = { left = 1, right = 3 }
-- Where to go by default: along the map when something is in the way, and no scanning
local MOVE = { path = true, scan = false }
-- The free slots a dump is wanted at when T.cfg.autoDump is just true
local DUMP_AT = 2

--------------------------------------------------------------------------
-- State shared by every copy of this module
--
-- Each program has its own turtlelib and its own copy of this module, but one turtle: the dump on a full inventory
-- is one listener, and it asks the copy whose program owns the turtle now.
--------------------------------------------------------------------------
local holder = turtle or _G
local S = holder._ccnixStore
if not S then
    S = { busy = false }
    holder._ccnixStore = S
end

local function whole(n) return type(n) == "number" and n == math.floor(n) end

-- The time, in seconds.
local function clock()
    if os.epoch then return math.floor(os.epoch("utc") / 1000) end
    return math.floor(os.time())
end

-- The name with its namespace (minecraft: if it has none).
local function full(name)
    if text.contains(name, ":") then return name end
    return NS .. name
end

-- A test on item names from a name, a glob, or a list or set of them; the namespace may be left out (a glob without
-- one also matches the short name).  turtlelib's, as for every list of names.
local matcher = T.nameTest

--------------------------------------------------------------------------
-- The list of chests, in a data file
--------------------------------------------------------------------------

-- The side a word in the file or a caller's side stands for: "up", "down", 0 to 3, or nil.
local function sideOf(word)
    if word == nil then return nil end
    local d = SIDES[word]
    if d ~= nil then return d end
    local n = convert.toInteger(tostring(word))
    return n ~= nil and SIDES[n] or nil
end

-- The key of a chest in a table: "x,y,z,side".
local function keyOf(c) return c.x .. "," .. c.y .. "," .. c.z .. "," .. tostring(c.side) end

-- The cell the chest itself is in: the stand, one step toward the side.
local function cellOf(c)
    local v = T.DELTA[c.side]
    return { x = c.x + v[1], y = c.y + v[2], z = c.z + v[3] }
end

-- Is the chest record c the chest in this cell (the cell it points at, or its other half's)?
local function holds(c, cell)
    local own = cellOf(c)
    if own.x == cell.x and own.y == cell.y and own.z == cell.z then return true end
    local o = c.other
    return o ~= nil and o.x == cell.x and o.y == cell.y and o.z == cell.z
end

-- The chest in the list that is the chest in this cell, and its index; nil if none.
local function chestAt(list, cell)
    for i, q in ipairs(list) do
        if holds(q, cell) then return q, i end
    end
    return nil
end

-- The chests as the file has them: a list of { x, y, z, side, bulk, seen, other, items = { name = count } }.  Two records of
-- one chest (from an older file) are one: the first, the bulk chest if either was.
local function load()
    local list, cur = {}, nil
    for _, line in ipairs(text.lines(fileio.read(T.dataPath(FILE)) or "")) do
        local w = text.words(line)
        if w[1] == "chest" then
            local x, y, z = convert.toInteger(w[2] or ""), convert.toInteger(w[3] or ""), convert.toInteger(w[4] or "")
            local side = sideOf(w[5])
            if x and y and z and side ~= nil then
                cur = { x = x, y = y, z = z, side = side, bulk = w[6] == "bulk", seen = convert.toInteger(w[7] or ""), items = {} }
                list[#list + 1] = cur
            else
                cur = nil
            end
        elseif w[1] == "item" and cur then
            local n = convert.toInteger(w[2] or "")
            if n and w[3] then cur.items[w[3]] = n end
        elseif w[1] == "other" and cur then
            local x, y, z = convert.toInteger(w[2] or ""), convert.toInteger(w[3] or ""), convert.toInteger(w[4] or "")
            if x and y and z then cur.other = { x = x, y = y, z = z } end
        end
    end
    for i = #list, 2, -1 do
        local c = list[i]
        for j = 1, i - 1 do
            if holds(list[j], cellOf(c)) or (c.other and holds(list[j], c.other)) then
                list[j].bulk = list[j].bulk or c.bulk
                table.remove(list, i)
                break
            end
        end
    end
    return list
end

-- Write the list of chests to the file.  True, or false and why.
local function save(list)
    local out = {}
    for _, c in ipairs(list) do
        out[#out + 1] = string.format("chest %d %d %d %s %s %d", c.x, c.y, c.z, tostring(c.side), c.bulk and "bulk" or "plain", c.seen or 0)
        if c.other then out[#out + 1] = string.format("other %d %d %d", c.other.x, c.other.y, c.other.z) end
        for _, name in ipairs(tables.sortedKeys(c.items)) do
            if c.items[name] > 0 then out[#out + 1] = "item " .. c.items[name] .. " " .. name end
        end
    end
    if not fileio.write(T.dataPath(FILE), table.concat(out, "\n") .. (#out > 0 and "\n" or "")) then
        return false, "couldn't save the list of chests"
    end
    return true
end

-- turtlelib's hook for a re-zeroed frame (--here somewhere else): every chest's cell is moved with move(x, y, z), and a
-- side that is a heading turned by `turns`, so each is still the same chest.  (Not a function to call: turtlelib does.)
T.reframeChests = function(move, turns)
    local list = load()
    for _, c in ipairs(list) do
        c.x, c.y, c.z = move(c.x, c.y, c.z)
        if type(c.side) == "number" then c.side = (c.side + turns) % 4 end
        if c.other then c.other.x, c.other.y, c.other.z = move(c.other.x, c.other.y, c.other.z) end
    end
    return save(list)
end

-- A copy of a chest record.
local function copyOf(c)
    return { x = c.x, y = c.y, z = c.z, side = c.side, bulk = c.bulk, seen = c.seen, items = tables.copy(c.items),
             other = c.other and { x = c.other.x, y = c.other.y, z = c.other.z } or nil }
end

-- The chest in the list with this place, or nil.
local function find(list, c)
    local k = keyOf(c)
    for _, q in ipairs(list) do
        if keyOf(q) == k then return q end
    end
    return nil
end

-- Tell the turtle about a chest: it stands at x, y, z (the turtle's frame) and the chest is on `side` ("up"/"top",
-- "down"/"bottom", or a heading 0 to 3 as T.dir counts them).  True (and a note if it was known), or nil and why.
--
-- Nothing is visited: T.catalogue reads what is in it.  With `bulk` true it becomes the bulk chest, where T.stow
-- puts what no chest holds already (there is one bulk chest; the earlier one is a plain chest again).  Adding a chest
-- again, from this stand or another, or the other half of a known double chest, keeps the one record and what was
-- written down of it, and the note says which it is ("already known: the other half of the double chest at 3,0,1,
-- reached from 3,0,0 side 0").  Kept in the data file .chests.
function T.addChest(x, y, z, side, bulk)
    for _, n in ipairs({ x, y, z }) do
        if not whole(n) then return nil, "a chest's place is x, y, z: whole numbers" end
    end
    local d = sideOf(side)
    if d == nil then return nil, "a chest's side is \"up\", \"down\" or a heading 0 to 3, not " .. tostring(side) end
    local list = load()
    local want = { x = x, y = y, z = z, side = d }
    local c = find(list, want) or chestAt(list, cellOf(want))
    local known
    if c then
        local own, at = cellOf(c), cellOf(want)
        local same = own.x == at.x and own.y == at.y and own.z == at.z
        known = "already known: " .. (same and "the chest at " or "the other half of the double chest at ") .. T.posKey(own) ..
            ", reached from " .. T.posKey(c) .. " side " .. tostring(c.side)
    else
        c = { x = x, y = y, z = z, side = d, items = {} }
        list[#list + 1] = c
    end
    if bulk then
        for _, q in ipairs(list) do q.bulk = false end
        c.bulk = true
    end
    local ok, why = save(list)
    if not ok then return nil, why end
    return true, known
end

-- Forget the chest at this place (as T.addChest was given it, or another stand for the same chest).  True, or false and why.
function T.forgetChest(x, y, z, side)
    local d = sideOf(side)
    local list = load()
    if d ~= nil then
        local _, i = chestAt(list, cellOf({ x = x, y = y, z = z, side = d }))
        if i then
            table.remove(list, i)
            return save(list)
        end
    end
    return false, "no chest is known at " .. tostring(x) .. "," .. tostring(y) .. "," .. tostring(z) .. " on the " .. tostring(side)
end

-- The chests the turtle knows, as a list of { x, y, z, side, bulk, seen, other, items = { name = count } }; seen is when
-- the chest was last read (seconds, the clock T.catalogue uses), 0 if never; other is the other half's cell of a double chest.
function T.chests()
    local list = load()
    for i, c in ipairs(list) do
        list[i] = copyOf(c)
        list[i].seen = list[i].seen or 0
    end
    return list
end

--------------------------------------------------------------------------
-- Going to a chest
--------------------------------------------------------------------------

-- Go to the cell x, y, z (the cell the turtle stands at for a chest), by the way the options say, and
-- the other way round the axes if that is blocked.  True, or false and why.
local function reach(p, move)
    local ok, why = T.moveTo(p.x, p.y, p.z, move)
    if ok then return true end
    local other = tables.copy(move)
    other.order = "xzy"
    ok, why = T.moveTo(p.x, p.y, p.z, other)
    return ok, why
end

-- The side of the turtle (as turtle.suck wants it) a chest is on, and face it if it is on a side.
local function faceChest(c)
    if c.side == "up" then return "top" end
    if c.side == "down" then return "bottom" end
    T.face(c.side)
    return "front"
end

-- Go to a chest and find a container where it should be.  Returns the side to use ("front", "top", "bottom"), or nil
-- and why.
local function arrive(c, move)
    local ok, why = reach(c, move)
    if not ok then return nil, "can't get to " .. T.posKey(c) .. ": " .. tostring(why) end
    local side = faceChest(c)
    if not T.containerOn(side) then return nil, "no chest on the " .. side .. " of " .. T.posKey(c) end
    return side
end

-- Run fn and then go back to where the turtle began, facing as before (unless `stay`: then it stays where fn left it).
-- Returns fn's results, with a note on the last if it couldn't get back.
local function round(move, fn, stay)
    local from, dir = T.here(), T.dir
    local a, b, c = fn()
    if stay then return a, b, c end
    if not T.at(from) then
        local ok, why = reach(from, move)
        if not ok then
            T.face(dir)
            local note = "couldn't get back to " .. T.posKey(from) .. ": " .. tostring(why)
            if type(b) == "string" then b = b .. " (" .. note .. ")" else a, b = false, note end
            return a, b, c
        end
    end
    T.face(dir)
    return a, b, c
end

-- The chests ordered nearest first from the turtle (a copy of the list, the nearest to the turtle's place leading).
local function nearest(list, from)
    local out = {}
    for i, c in ipairs(list) do out[i] = c end
    table.sort(out, function(a, b)
        local da, db = T.dist(from, a), T.dist(from, b)
        if da ~= db then return da < db end
        return keyOf(a) < keyOf(b)
    end)
    return out
end

-- Write down what the container on `side` holds for the chest c (in list), saving the list.  Returns the counts, or
-- nil if the container couldn't be read.
local function note(list, c, side)
    local counts = T.containerCounts(side)
    if not counts then return nil end
    local rec = find(list, c)
    if rec then
        rec.items, rec.seen = counts, clock()
        save(list)
    end
    return counts
end

-- The sides T.recount takes: the turtle's side to read (as peripheral.wrap wants it) and the way the chest is from the
-- turtle (nil: the way it faces)
local RECOUNT_SIDES = {
    front = { side = "front" }, top = { side = "top", dir = "up" }, up = { side = "top", dir = "up" },
    bottom = { side = "bottom", dir = "down" }, down = { side = "bottom", dir = "down" },
}

-- Read the known chest on `side` of the turtle ("front", "top"/"up", "bottom"/"down") again, into the list of chests.
-- The chest as T.chests gives it, or nil and why.
--
-- T.fetch and T.stow do this as they go, and T.craft and T.craftBatch at a chest the list knows; call it after your
-- own drops into a known chest or pulls from it, so T.where, T.inventoryReport and T.craftPlan count what is there now.
-- Nothing moves.
function T.recount(side)
    local s = RECOUNT_SIDES[side]
    if not s then return nil, "T.recount wants the side the chest is on: \"front\", \"top\" or \"bottom\", not " .. tostring(side) end
    local v = T.DELTA[s.dir or T.dir]
    local cell = { x = T.pos.x + v[1], y = T.pos.y + v[2], z = T.pos.z + v[3] }
    local list = load()
    local c = chestAt(list, cell)
    if not c then
        return nil, "no known chest on the " .. s.side .. " of " .. T.posKey(T.pos) .. " (T.addChest tells the turtle about one)"
    end
    if not note(list, c, s.side) then return nil, "can't read the chest on the " .. s.side .. " of " .. T.posKey(T.pos) end
    local out = copyOf(c)
    out.seen = out.seen or 0
    return out
end

--------------------------------------------------------------------------
-- Cataloguing
--------------------------------------------------------------------------

-- The cell of a double chest's other half, from the half's state, or nil when it can't be told (a single chest, or no
-- world origin to turn the compass into the turtle's headings).
local function otherHalf(cell, state)
    local turn, facing = HALF_TURN[state.type], COMPASS_AT[state.facing]
    if not (turn and facing) then return nil end
    local origin = T.need("origin")
    local o = origin and origin()
    local base = o and COMPASS_AT[o.facing]
    if base == nil then return nil end
    local v = T.DELTA[(facing + turn - base) % 4]
    return { x = cell.x + v[1], y = cell.y, z = cell.z + v[3] }
end

-- Do two counts of items ({ name = count }) say the same?
local function sameCounts(a, b)
    for k, n in pairs(a) do
        if b[k] ~= n then return false end
    end
    for k, n in pairs(b) do
        if a[k] ~= n then return false end
    end
    return true
end

-- Is the chest q the other half of c, a half of a double chest just read (its state given)?  By the cell its facing
-- points to (other) when the origin is known; else a half read this time beside it, facing the same way, the other
-- type, holding the same.
local function isOtherHalf(q, c, state, other, read)
    if q == c then return false end
    local qc, cell = cellOf(q), cellOf(c)
    if other then return qc.x == other.x and qc.y == other.y and qc.z == other.z end
    return read[q] == true and q.half ~= nil and q.half.facing == state.facing and q.half.type ~= state.type and qc.y == cell.y
        and math.abs(qc.x - cell.x) + math.abs(qc.z - cell.z) == 1 and sameCounts(q.items, c.items)
end

-- The chest c was just read from `side`: if it is half of a double chest and the other half is in the list too, the two
-- are one chest.  The other half's record goes (from the list and from what is still to visit), and c keeps the other
-- half's cell, so a stand for that half is this chest from now on.
local function pairUp(list, todo, read, c, side)
    local seen, data = T.inspectSide(side)
    local state = seen and type(data) == "table" and data.state
    if not (type(state) == "table" and HALF_TURN[state.type]) then return end
    c.half = state
    local other = otherHalf(cellOf(c), state)
    if other then c.other = other end
    for i, q in ipairs(list) do
        if isOtherHalf(q, c, state, other, read) then
            table.remove(list, i)
            for j, t in ipairs(todo) do
                if t == q then table.remove(todo, j); break end
            end
            read[q] = nil
            c.other, c.bulk = cellOf(q), c.bulk or q.bulk
            break
        end
    end
    if c.other then save(list) end
end

-- A stand for a chest the map knows at cell p: a free cell next to it and the side the chest is on from there, or
-- nil.
local function standFor(p)
    local best
    for _, d in ipairs({ "up", "down", 0, 1, 2, 3 }) do
        local v = T.DELTA[d]
        local s = { x = p.x - v[1], y = p.y - v[2], z = p.z - v[3] }      -- (standing there, the chest is in direction d)
        local name = T.map.get(s.x, s.y, s.z)
        if name == "minecraft:air" or name == "minecraft:cave_air" then
            s.side = d
            s.dist = T.dist(T.pos, s)
            if not best or s.dist < best.dist then best = s end
        end
    end
    return best
end

-- Go round the chests and write down what each holds.  Returns true, info; false, why, info when some could not be
-- read; nil, why when there is nothing to do.
--
-- `spots` is a list of chests as { x, y, z, side } (and bulk = true for the bulk chest), which are remembered
-- (T.addChest); nil goes round the ones already known.  The two halves of a double chest become one chest as they are
-- read (see the top of this module).  opts.find, a box in the map (six numbers, as T.map.find
-- takes), adds the chests and barrels the map shows in it, each from a free cell beside it.  opts.move is T.moveTo's
-- (default { path = true, scan = false }).  The nearest comes next and the turtle ends where it began, facing as
-- before.  Info is { chests, kinds, items, failed = { { x, y, z, side, why } } }.
function T.catalogue(spots, opts)
    opts = opts or {}
    local move = opts.move or MOVE
    for _, s in ipairs(spots or {}) do
        local ok, why = T.addChest(s.x, s.y, s.z, s.side, s.bulk)
        if not ok then return nil, why end
    end
    local info = { chests = 0, kinds = 0, items = 0, failed = {} }
    if opts.find then
        local cells, why = T.map.find("*chest", opts.find)
        if not cells then return nil, "couldn't look in the map: " .. tostring(why) end
        local barrels = T.map.find("*barrel", opts.find)
        for _, b in ipairs(barrels or {}) do cells[#cells + 1] = b end
        for _, cell in ipairs(cells) do
            local s = standFor(cell)
            if s then
                local ok, why2 = T.addChest(s.x, s.y, s.z, s.side)
                if not ok then return nil, why2 end
            else
                info.failed[#info.failed + 1] = { x = cell.x, y = cell.y, z = cell.z, side = "?", why = "no free cell the map knows next to it" }
            end
        end
    end
    local list = load()
    if #list == 0 and #info.failed == 0 then return nil, "no chests to go round: T.addChest, or give T.catalogue the places" end
    local read = {}
    local ok, why = round(move, function()
        local todo = {}
        for i, c in ipairs(list) do todo[i] = c end
        while #todo > 0 do
            local best = 1
            for i = 2, #todo do
                if T.dist(T.pos, todo[i]) < T.dist(T.pos, todo[best]) then best = i end
            end
            local c = table.remove(todo, best)
            local side, reason = arrive(c, move)
            if side and note(list, c, side) then
                read[c] = true
                pairUp(list, todo, read, c, side)
            else
                info.failed[#info.failed + 1] = { x = c.x, y = c.y, z = c.z, side = c.side, why = reason or "can't read what it holds" }
            end
        end
        return true
    end)
    local kinds = {}
    for _, c in ipairs(list) do
        if read[c] then
            info.chests = info.chests + 1
            for name, n in pairs(c.items) do
                kinds[name] = true
                info.items = info.items + n
            end
        end
    end
    for _ in pairs(kinds) do info.kinds = info.kinds + 1 end
    if ok == false then return false, why, info end
    if #info.failed > 0 then
        return false, info.chests .. " chests read, " .. #info.failed .. " not: " .. info.failed[1].why, info
    end
    return true, info
end

--------------------------------------------------------------------------
-- Where an item is, and fetching it
--------------------------------------------------------------------------

-- Which chests hold the item `name` (or a glob of item names; the namespace may be left out), as written down: a list
-- of { x, y, z, side, count, bulk, seen, age }, the nearest to the turtle first, and the total.  Moves nothing.
--
-- It is the list T.catalogue made, kept right by T.fetch and T.stow as they go; seen is when the chest was read (seconds)
-- and age how long ago that was, so an old count can be read again first.  Nil and why when no chest is known.
function T.where(name)
    local list = load()
    if #list == 0 then return nil, "no chests are known: T.addChest, then T.catalogue" end
    local test = matcher(name)
    local found, total = {}, 0
    for _, c in ipairs(list) do
        local n = 0
        for item, count in pairs(c.items) do
            if test(item) then n = n + count end
        end
        if n > 0 then
            found[#found + 1] = { x = c.x, y = c.y, z = c.z, side = c.side, count = n, bulk = c.bulk, seen = c.seen or 0,
                                  age = c.seen and c.seen > 0 and clock() - c.seen or nil }
            total = total + n
        end
    end
    return nearest(found, T.here()), total
end

-- Go to the chests that hold `name` and take n of it (default 1), then come back facing as before (opts.stay: stay at
-- the last chest).  Returns how many came aboard, and why if that is short of n.
--
-- `name` is an item's name (minecraft: assumed).  The chests come nearest first, each read again as it is visited
-- (so a chest that no longer has it is put right in the list and the next is tried); it stops when it has n or the
-- turtle has no room.  opts.move is T.moveTo's; opts.stay saves the walk back when another chest is next.
function T.fetch(name, n, opts)
    opts = opts or {}
    n = n or 1
    if not (whole(n) and n >= 1) then return 0, "fetch wants a whole number of items" end
    name = full(name)
    local move = opts.move or MOVE
    local holders, total = T.where(name)
    if not holders then return 0, total end
    if total == 0 then return 0, "no chest is known to hold " .. name .. " (T.catalogue reads them again)" end
    local got, why = 0, nil
    local list = load()
    round(move, function()
        for _, c in ipairs(holders) do
            if got >= n then return end
            local side, reason = arrive(c, move)
            if side then
                local took, pullWhy = T.pull(side, name, n - got)
                got = got + took
                note(list, c, side)
                if pullWhy and text.contains(pullWhy, "no room") then
                    why = "no room in the turtle for " .. name            -- (T.pull's own count is this chest's: the total is said below)
                    return
                end
            else
                why = reason
            end
        end
    end, opts.stay)
    if got >= n then return got end
    return got, (why or "the chests hold no more " .. name) .. " (got " .. got .. " of " .. n .. ")"
end

--------------------------------------------------------------------------
-- What there is, everywhere
--------------------------------------------------------------------------

-- An age in seconds in words: "40s", "12m", "3h".
local function ageText(s)
    if s < 120 then return s .. "s" end
    if s < 7200 then return math.floor(s / 60) .. "m" end
    return math.floor(s / 3600) .. "h"
end

-- How the rows of a report are sorted: by name, or the most first
local REPORT_ORDER = {
    name = function(a, b) return a.name < b.name end,
    count = function(a, b)
        if a.total ~= b.total then return a.total > b.total end
        return a.name < b.name
    end,
}

-- Every item across the chests (as last read) and the turtle, with totals, sorted by name: a list of { name, total,
-- turtle, chests, places, age }, and info { kinds, items, chests, oldest, text }.  Moves nothing.
--
-- turtle is what is aboard, chests what the chests held when T.catalogue (or a fetch or stow since) last read them, places
-- how many chests hold some, and age the seconds since the oldest of those counts was read (nil: aboard only).
-- info.text is the report as lines ("cobblestone 164: turtle 20, 2 chests, read 5m ago").  opts.match (a name, a glob,
-- a list or set of them) reports only those; opts.sort = "count" puts the most first.
function T.inventoryReport(opts)
    opts = opts or {}
    local order = REPORT_ORDER[opts.sort or "name"]
    if not order then return nil, "opts.sort is \"name\" or \"count\", not " .. tostring(opts.sort) end
    local test = opts.match and matcher(opts.match) or function() return true end
    local now, rows = clock(), {}
    local function row(name)
        if not rows[name] then rows[name] = { name = name, total = 0, turtle = 0, chests = 0, places = 0 } end
        return rows[name]
    end
    for slot = 1, 16 do
        local it = turtle.getItemDetail(slot)
        if it and test(it.name) then row(it.name).turtle = row(it.name).turtle + it.count end
    end
    local list = load()
    for _, c in ipairs(list) do
        for name, n in pairs(c.items) do
            if n > 0 and test(name) then
                local r = row(name)
                r.chests, r.places = r.chests + n, r.places + 1
                local age = c.seen and c.seen > 0 and now - c.seen or nil
                if age and (not r.age or age > r.age) then r.age = age end
            end
        end
    end
    local report = {}
    local info = { kinds = 0, items = 0, chests = #list, text = {} }
    for _, r in pairs(rows) do
        r.total = r.turtle + r.chests
        report[#report + 1] = r
        info.kinds, info.items = info.kinds + 1, info.items + r.total
        if r.age and (not info.oldest or r.age > info.oldest) then info.oldest = r.age end
    end
    table.sort(report, order)
    for i, r in ipairs(report) do
        local parts = {}
        if r.turtle > 0 then parts[#parts + 1] = "turtle " .. r.turtle end
        if r.places > 0 then
            parts[#parts + 1] = (r.places == 1 and "1 chest" or r.places .. " chests") ..
                (r.age and ", read " .. ageText(r.age) .. " ago" or "")
        end
        info.text[i] = (text.stripPrefix(r.name, NS) or r.name) .. " " .. r.total .. ": " .. table.concat(parts, ", ")
    end
    info.text = table.concat(info.text, "\n")
    return report, info
end

--------------------------------------------------------------------------
-- Putting away
--------------------------------------------------------------------------

-- Can the item go in a chest by default?  What isn't kept (T.isJunk); with opts.all also what the job keeps, but never a
-- tool, fuel or a peripheral (T.isEssential); never what opts.keep names (a test made from it).
local function stowable(name, opts, keep)
    if keep and keep(name) then return false end
    if opts.all then return not T.isEssential(name) end
    return T.isJunk(name)
end

-- Is there any of the item name aboard?
local function aboard(name) return T.countItem(name) > 0 end

-- The chests to try for an item now: the ones that hold it which have not been tried, else the bulk chest if it has
-- not.
local function candidates(list, name, tried)
    local out = {}
    for _, c in ipairs(list) do
        if not tried[keyOf(c) .. name] and (c.items[name] or 0) > 0 then out[#out + 1] = c end
    end
    if #out > 0 then return out end
    for _, c in ipairs(list) do
        if c.bulk and not tried[keyOf(c) .. name] then out[#out + 1] = c end
    end
    return out
end

-- What the game says when a drop finds no room in the container (any other failure is said as it is)
local NO_ROOM = { ["No space for items"] = true }

-- The chest c as a reason's words begin: "chest at x,y,z" or "bulk chest at x,y,z" (the chest's own cell).
local function chestWords(c)
    return (c.bulk and "bulk chest at " or "chest at ") .. T.posKey(cellOf(c))
end

-- Why each item left aboard stayed, from the notes T.stow made at the chests it was tried at: { name = reason }, and
-- the sentence that says them, the items with the same reason together ("64 cobblestone, 5 dirt (bulk chest at
-- 0,0,-3 full)").
local function leftWords(left, notes, list)
    local hasBulk = false
    for _, c in ipairs(list) do hasBulk = hasBulk or c.bulk == true end
    local reasons, groups, order = {}, {}, {}
    for _, name in ipairs(tables.sortedKeys(left)) do
        local why
        if notes[name] then
            why = table.concat(notes[name], ", ") .. (hasBulk and "" or "; no bulk chest")
        else
            why = "no chest holds it and no bulk chest"
        end
        reasons[name] = why
        if not groups[why] then groups[why] = {}; order[#order + 1] = why end
        local g = groups[why]
        g[#g + 1] = left[name] .. " " .. (text.stripPrefix(name, NS) or name)
    end
    local parts = {}
    for i, why in ipairs(order) do parts[i] = table.concat(groups[why], ", ") .. " (" .. why .. ")" end
    return reasons, "some stayed aboard: " .. table.concat(parts, "; ")
end

-- Put what the turtle carries away in the chests: into one that already holds the item, else into the bulk chest.
-- Returns true, info; false, why, info when something stayed aboard; nil, why if no chest is known.
--
-- By default it puts away what is junk (T.isJunk: not kept by T.keep, not crafted this job, not a tool, fuel, a bucket or
-- a peripheral); opts.all puts away what the job keeps as well (the end of a job), still never a tool, fuel or
-- a peripheral.  It goes to the nearest chest that wants something, drops what that chest should have, reads it again
-- for the list and goes on, then comes back facing as before.  What no chest holds, with no bulk chest, or what does
-- not fit, stays aboard.  Info is { stowed, chests, left = { name = count }, reasons = { name = why } }: each item left
-- aboard with why, every chest it was tried at ("chest at 3,0,1 full, bulk chest at 0,0,-3 full", "no chest holds it
-- and no bulk chest"), and the why returned says them all.  opts: move (T.moveTo's), keep (names, a list or set, globs
-- too, that stay aboard whatever), stay (stay at the last chest).
function T.stow(opts)
    opts = opts or {}
    local move = opts.move or MOVE
    local list = load()
    if #list == 0 then return nil, "no chests are known: T.addChest (and a bulk chest), then T.stow" end
    local keep = opts.keep and T.nameTest(opts.keep)
    local names = {}
    for slot = 1, 16 do
        local it = turtle.getItemDetail(slot)
        if it and stowable(it.name, opts, keep) then names[it.name] = true end
    end
    local info = { stowed = 0, chests = 0, left = {}, reasons = {} }
    if next(names) == nil then return true, info end
    local tried, notes = {}, {}
    -- note, for the item name, what happened at a chest it was tried at
    local function noteFor(name, said)
        notes[name] = notes[name] or {}
        local l = notes[name]
        l[#l + 1] = said
    end
    round(move, function()
        while true do
            local best, bestAt
            for name in pairs(names) do
                if aboard(name) then
                    for _, c in ipairs(candidates(list, name, tried)) do
                        local d = T.dist(T.pos, c)
                        if not best or d < bestAt or (d == bestAt and keyOf(c) < keyOf(best)) then best, bestAt = c, d end
                    end
                end
            end
            if not best then return end
            local wanted = {}
            for name in pairs(names) do
                if aboard(name) then
                    for _, c in ipairs(candidates(list, name, tried)) do
                        if c == best then wanted[#wanted + 1] = name end
                    end
                end
            end
            local side, reason = arrive(best, move)
            if side then
                info.chests = info.chests + 1
                local sel = turtle.getSelectedSlot()
                for _, name in ipairs(wanted) do
                    local said
                    for slot = 1, 16 do
                        local it = turtle.getItemDetail(slot)
                        if it and it.name == name then
                            turtle.select(slot)
                            local dropped, err = T.dropSide(side, it.count)
                            local left = turtle.getItemCount(slot)
                            info.stowed = info.stowed + it.count - left
                            if left > 0 and not said then
                                said = chestWords(best) .. ((dropped or NO_ROOM[err]) and " full" or ": " .. tostring(err))
                            end
                        end
                    end
                    if said then noteFor(name, said) end
                end
                turtle.select(sel)
                note(list, best, side)
            else
                for _, name in ipairs(wanted) do noteFor(name, reason) end
            end
            for _, name in ipairs(wanted) do tried[keyOf(best) .. name] = true end
        end
    end, opts.stay)
    for name in pairs(names) do
        local n = T.countItem(name)
        if n > 0 then info.left[name] = n end
    end
    if next(info.left) then
        local reasons, why = leftWords(info.left, notes, list)
        info.reasons = reasons
        return false, why, info
    end
    return true, info
end

--------------------------------------------------------------------------
-- Getting ready for a job
--------------------------------------------------------------------------

-- What is short as words: "cobblestone: need 64, have 20; torch: need 8, have 0".
local function shortWords(short)
    local parts = {}
    for i, s in ipairs(short) do
        parts[i] = (text.stripPrefix(s.item, NS) or s.item) .. ": need " .. s.need .. ", have " .. s.have
    end
    return table.concat(parts, "; ")
end

-- Get ready for a job in one trip, T.prepare{ need = { [name] = n }, freeSlots = k }: stow what isn't needed, fetch
-- what is, come back, check the room.  True, info; false, why, info (what is short, too few slots free); nil, why.
--
-- spec.need is { [name] = n }: what the turtle should carry (names, minecraft: assumed), spec.freeSlots how many slots
-- must be empty after (default 0).  The chests' list (as last read) is checked first: if they and the turtle together
-- hold too little of something it refuses before moving, naming what is short, unless spec.partial.  Then it stows
-- everything that isn't needed (but never tools, fuel or a peripheral; what is needed stays aboard whole), fetches what
-- is missing, nearest chest first, and comes back facing as before (spec.stay: stays at the last chest).  Then it counts
-- again: anything still short, or fewer free slots than asked, is a failure that says what.  spec.move is T.moveTo's.
-- Info is { fetched = { name = n }, stowed, short = { { item, need, have } }, free }.
function T.prepare(spec)
    spec = spec or {}
    local need = spec.need or {}
    if type(need) ~= "table" then return nil, "T.prepare wants { need = { [name] = n }, freeSlots = k }" end
    local slots = spec.freeSlots or 0
    if not (whole(slots) and slots >= 0 and slots <= 16) then return nil, "freeSlots is a whole number from 0 to 16" end
    local want = {}
    for name, n in pairs(need) do
        if type(name) ~= "string" or not (whole(n) and n >= 0) then
            return nil, "need is { [name] = n }, each n a whole number: " .. tostring(name) .. " = " .. tostring(n)
        end
        want[full(name)] = n
    end
    local names = tables.sortedKeys(want)
    if #load() == 0 then return nil, "no chests are known: T.addChest, then T.catalogue" end
    local short = {}
    for _, name in ipairs(names) do
        local have = T.countItem(name)
        if have < want[name] then
            local _, stored = T.where(name)
            if have + (stored or 0) < want[name] then short[#short + 1] = { item = name, need = want[name], have = have + (stored or 0) } end
        end
    end
    if #short > 0 and not spec.partial then
        return nil, "short of " .. shortWords(short) .. " (aboard and in the chests as last read; T.catalogue reads them " ..
            "again, spec.partial goes for what there is)", { short = short }
    end
    local move = spec.move or MOVE
    local info = { fetched = {}, stowed = 0, short = {}, free = 0 }
    local notes = {}
    local ok, why = round(move, function()
        local stowed, stowWhy, stowInfo = T.stow({ all = true, keep = names, stay = true, move = move })
        if stowed then stowInfo = stowWhy else notes[#notes + 1] = "stowing: " .. tostring(stowWhy) end
        info.stowed = stowInfo and stowInfo.stowed or 0
        for _, name in ipairs(names) do
            local missing = want[name] - T.countItem(name)
            if missing > 0 then
                local got, fetchWhy = T.fetch(name, missing, { stay = true, move = move })
                info.fetched[name] = got
                if got < missing then notes[#notes + 1] = tostring(fetchWhy) end
            end
        end
        return true
    end, spec.stay)
    for _, name in ipairs(names) do
        local have = T.countItem(name)
        if have < want[name] then info.short[#info.short + 1] = { item = name, need = want[name], have = have } end
    end
    info.free = T.freeSlots()
    local fails = {}
    if not ok then fails[#fails + 1] = tostring(why) end
    if #info.short > 0 then fails[#fails + 1] = "short of " .. shortWords(info.short) end
    if info.free < slots then
        fails[#fails + 1] = "only " .. info.free .. " slots free, " .. slots .. " wanted (what is needed, tools, fuel and " ..
            "what no chest would take stay aboard)"
    end
    if #fails == 0 then return true, info end
    if #notes > 0 then fails[#fails + 1] = "(" .. table.concat(notes, "; ") .. ")" end
    return false, table.concat(fails, "; "), info
end

-- Make room: stow what is not kept (T.stow), or dump the junk (T.dumpJunk) if there are no chests; T.cfg.autoDump = true runs it
-- when the inventory is nearly full.  The results are those of the one it ran; nil and why if neither is set up.
--
-- T.cfg.autoDump is true or a number of free slots (2 for true): after a dig that leaves that few (part stacks merged first), the
-- turtle makes this trip and comes back where it was, facing as before.  A trip that fails, or leaves no more room than that, is
-- printed and noted in the job (T.job.note) and not tried again until there is less room; two in a row turn T.cfg.autoDump off.
function T.autoDump()
    if #load() > 0 then return T.stow() end
    if T.junkChest() then return T.dumpJunk() end
    return nil, "nowhere to dump: T.addChest (and a bulk chest), or T.setJunkChest"
end

--------------------------------------------------------------------------
-- Dumping when the inventory fills
--------------------------------------------------------------------------

-- Say a failed dump: printed, and noted in the job if one is on.
local function tellFailure(said)
    print(said)
    if fs.exists(T.dataPath(".job")) then
        local ok, err = pcall(T.job.note, said)
        if not ok and err == "Terminated" then error(err, 0) end
    end
end

-- Hear a dig: with T.cfg.autoDump on and the room run down, merge part stacks, and if that isn't room enough, make room.
-- A trip that failed, or left no more than the limit free, is a failure: said, and not tried again until there is less
-- room than it left; the second in a row turns T.cfg.autoDump off.
local function heard(e)
    if e.kind ~= "dig" or S.busy then return end
    local at = T.cfg.autoDump
    if not at then return end
    at = type(at) == "number" and at or DUMP_AT
    if T.freeSlots() > at then return end
    S.busy = true
    local sel = turtle.getSelectedSlot()
    local tidied, terr = pcall(T.tidyInventory)
    turtle.select(sel)
    S.busy = false
    if not tidied and terr == "Terminated" then error(terr, 0) end
    local before = T.freeSlots()
    if before > at or before >= (S.failedAt or math.huge) then return end
    S.busy = true
    local ok, done, why = pcall(T.autoDump)
    S.busy = false
    if not ok and done == "Terminated" then error(done, 0) end
    local after = T.freeSlots()
    if ok and done and after > at then
        S.failedAt, S.failures = nil, 0
        return
    end
    if not ok then why = tostring(done)
    elseif done then why = "made no room: " .. after .. " slots free, and the rest aboard is kept (T.keep, tools, fuel)"
    else why = tostring(why) end
    S.failedAt, S.failures = after, (S.failures or 0) + 1
    if S.failures < 2 then return tellFailure("autoDump: " .. why) end
    T.cfg.autoDump = false
    S.failedAt, S.failures = nil, 0
    tellFailure("autoDump is off after two failures in a row: " .. why .. " (set T.cfg.autoDump again once that is put right)")
end

-- One listener for the turtle, which every program's copy of this module shares: it hands each event to the copy
-- whose program owns the turtle now (T.owns), so T.cfg.autoDump set by one program (claude) is neither run by another's
-- digs (with the first copy's stale position) nor switched off by another program loading the module.
S.hearers = S.hearers or setmetatable({}, { __mode = "k" })
S.hearers[T] = heard
if not S.listening then
    S.listening = true
    T.onChange(function(e)
        for t, fn in pairs(S.hearers) do
            if t.owns() then return fn(e) end
        end
    end)
end

return T
