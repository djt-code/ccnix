-- store.lua -- chests at home: where they are, what is in them, fetching from them and putting away
--
-- Loaded by turtlelib the first time one of its functions is used (T.addChest, T.forgetChest, T.chests, T.catalogue,
-- T.where, T.fetch, T.stow, T.autoDump), or when T.cfg.autoDump is set.
--
-- A chest is known by where the turtle stands to reach it, as the junk chest is (T.setJunkChest): the cell x, y, z in the
-- turtle's frame, and the side the chest is on ("up", "down", or a heading 0 to 3).  T.addChest tells the turtle about
-- one, T.catalogue goes round them and writes down what each holds, T.where says which have an item, T.fetch goes and
-- takes some, T.stow puts what the turtle carries away (into a chest that already holds that item, else into the bulk
-- chest) and T.autoDump is that done for you when the inventory nearly fills: T.cfg.autoDump = true (or a number of free
-- slots) and every dig is followed, when the room has run out, by a trip to the chests and back.  With no chests known
-- it takes the junk chest's trip instead (T.dumpJunk).
--
-- The chests and what they held when last looked at are in the data file .chests, so every program on the turtle
-- shares them and a restart keeps them.  A line "chest x y z side bulk|plain seen" starts a chest ("seen" the time it was
-- read, in seconds) and the lines "item count name" after it are what it held.  Fetching and stowing read the chest again
-- as they go, so the list stays right; a chest someone else emptied is found out the next time it is visited.

local T = require("turtlelib")
local text = require("text")
local convert = require("convert")
local fileio = require("fileio")
local tables = require("tables")
local glob = require("glob")

local FILE = ".chests"
local NS = "minecraft:"
-- The words for the side a chest is on, as the file keeps them: a heading (T.dir's 0 to 3), up or down
local SIDES = { up = "up", top = "up", down = "down", bottom = "down", [0] = 0, [1] = 1, [2] = 2, [3] = 3 }
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

-- A test on item names from a name or a glob; the namespace may be left out (a glob without one also matches the
-- short name).
local function matcher(spec)
    local test = glob.compile(spec)
    local plain = not text.contains(spec, ":")
    return function(name)
        if test(name) then return true end
        if not plain then return false end
        local _, short = text.cut(name, ":")
        return short ~= nil and test(short)
    end
end

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

-- The chests as the file has them: a list of { x, y, z, side, bulk, seen, items = { name = count } }.
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
        end
    end
    return list
end

-- Write the list of chests to the file.  True, or false and why.
local function save(list)
    local out = {}
    for _, c in ipairs(list) do
        out[#out + 1] = string.format("chest %d %d %d %s %s %d", c.x, c.y, c.z, tostring(c.side), c.bulk and "bulk" or "plain", c.seen or 0)
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
    end
    return save(list)
end

-- A copy of a chest record.
local function copyOf(c)
    return { x = c.x, y = c.y, z = c.z, side = c.side, bulk = c.bulk, seen = c.seen, items = tables.copy(c.items) }
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
-- "down"/"bottom", or a heading 0 to 3 as T.dir counts them).  True, or nil and why.
--
-- Nothing is visited: T.catalogue reads what is in it.  With `bulk` true it becomes the bulk chest, where T.stow
-- puts what no chest holds already (there is one bulk chest; the earlier one is a plain chest again).  Adding a chest
-- again keeps what was written down of it.  Kept in the data file .chests.
function T.addChest(x, y, z, side, bulk)
    for _, n in ipairs({ x, y, z }) do
        if not whole(n) then return nil, "a chest's place is x, y, z: whole numbers" end
    end
    local d = sideOf(side)
    if d == nil then return nil, "a chest's side is \"up\", \"down\" or a heading 0 to 3, not " .. tostring(side) end
    local list = load()
    local want = { x = x, y = y, z = z, side = d }
    local c = find(list, want)
    if not c then
        c = { x = x, y = y, z = z, side = d, items = {} }
        list[#list + 1] = c
    end
    if bulk then
        for _, q in ipairs(list) do q.bulk = false end
        c.bulk = true
    end
    return save(list)
end

-- Forget the chest at this place (as T.addChest was given it).  True, or false and why.
function T.forgetChest(x, y, z, side)
    local d = sideOf(side)
    local list = load()
    for i, c in ipairs(list) do
        if d ~= nil and keyOf(c) == keyOf({ x = x, y = y, z = z, side = d }) then
            table.remove(list, i)
            return save(list)
        end
    end
    return false, "no chest is known at " .. tostring(x) .. "," .. tostring(y) .. "," .. tostring(z) .. " on the " .. tostring(side)
end

-- The chests the turtle knows, as a list of { x, y, z, side, bulk, seen, items = { name = count } }; seen is when
-- the chest was last read (seconds, the clock T.catalogue uses), 0 if never.
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

-- Run fn and then go back to where the turtle began, facing as before.  Returns fn's results, with a note on the
-- last if it couldn't get back.
local function round(move, fn)
    local from, dir = T.here(), T.dir
    local a, b, c = fn()
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

--------------------------------------------------------------------------
-- Cataloguing
--------------------------------------------------------------------------

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
-- (T.addChest); nil goes round the ones already known.  opts.find, a box in the map (six numbers, as T.map.find
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
    local kinds = {}
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
                info.chests = info.chests + 1
                for name, n in pairs(c.items) do
                    kinds[name] = true
                    info.items = info.items + n
                end
            else
                info.failed[#info.failed + 1] = { x = c.x, y = c.y, z = c.z, side = c.side, why = reason or "can't read what it holds" }
            end
        end
        return true
    end)
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
-- of { x, y, z, side, count, bulk }, the nearest to the turtle first, and the total.  Moves nothing.
--
-- It is the list T.catalogue made, kept right by T.fetch and T.stow as they go; nil and why when no chest is known.
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
            found[#found + 1] = { x = c.x, y = c.y, z = c.z, side = c.side, count = n, bulk = c.bulk }
            total = total + n
        end
    end
    return nearest(found, T.here()), total
end

-- Go to the chests that hold `name` and take n of it (default 1), then come back facing as before.  Returns how many
-- came aboard, and why if that is short of n.
--
-- `name` is an item's name (minecraft: assumed).  The chests come nearest first, each read again as it is visited
-- (so a chest that no longer has it is put right in the list and the next is tried); it stops when it has n or the
-- turtle has no room.  opts.move is T.moveTo's.
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
                    why = pullWhy
                    return
                end
            else
                why = reason
            end
        end
    end)
    if got >= n then return got end
    return got, (why or "the chests hold no more " .. name) .. " (got " .. got .. " of " .. n .. ")"
end

--------------------------------------------------------------------------
-- Putting away
--------------------------------------------------------------------------

-- Can the item go in a chest by default?  What isn't kept (T.isJunk); with opts.all also what the job keeps, but never a
-- tool, fuel or a peripheral (T.isEssential).
local function stowable(name, opts)
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

-- Put what the turtle carries away in the chests: into one that already holds the item, else into the bulk chest.
-- Returns true, info; false, why, info when something stayed aboard; nil, why if no chest is known.
--
-- By default it puts away what is junk (T.isJunk: not kept by T.keep, not crafted this job, not a tool, fuel, a bucket or
-- a peripheral); opts.all puts away what the job keeps as well (the end of a job), still never a tool, fuel or
-- a peripheral.  It goes to the nearest chest that wants something, drops what that chest should have, reads it again
-- for the list and goes on, then comes back facing as before.  What no chest holds, with no bulk chest, or what does
-- not fit, stays aboard.  Info is { stowed, chests, left = { name = count } }; opts.move is T.moveTo's.
function T.stow(opts)
    opts = opts or {}
    local move = opts.move or MOVE
    local list = load()
    if #list == 0 then return nil, "no chests are known: T.addChest (and a bulk chest), then T.stow" end
    local names = {}
    for slot = 1, 16 do
        local it = turtle.getItemDetail(slot)
        if it and stowable(it.name, opts) then names[it.name] = true end
    end
    local info = { stowed = 0, chests = 0, left = {} }
    if next(names) == nil then return true, info end
    local tried, bad = {}, {}
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
                    for slot = 1, 16 do
                        local it = turtle.getItemDetail(slot)
                        if it and it.name == name then
                            turtle.select(slot)
                            T.dropSide(side, it.count)
                            info.stowed = info.stowed + it.count - turtle.getItemCount(slot)
                        end
                    end
                end
                turtle.select(sel)
                note(list, best, side)
            else
                bad[keyOf(best)] = reason
            end
            for _, name in ipairs(wanted) do tried[keyOf(best) .. name] = true end
        end
    end)
    local why
    for name in pairs(names) do
        local n = T.countItem(name)
        if n > 0 then info.left[name] = n end
    end
    if next(info.left) then
        local k = tables.sortedKeys(info.left)[1]
        why = "some stayed aboard (" .. info.left[k] .. " " .. k .. ", ...): no chest holds it and no bulk chest, or no room"
        local bads = tables.sortedKeys(bad)
        if #bads > 0 then why = why .. "; " .. bad[bads[1]] end
        return false, why, info
    end
    return true, info
end

-- Make room: stow what is not kept (T.stow), or dump the junk (T.dumpJunk) if there are no chests; T.cfg.autoDump = true runs it
-- when the inventory is nearly full.  The results are those of the one it ran; nil and why if neither is set up.
--
-- T.cfg.autoDump is true or a number of free slots (2 for true): after a dig that leaves that few, the turtle makes this trip and
-- comes back where it was, facing as before.  A dump that did nothing is not tried again until there is less room.
function T.autoDump()
    if #load() > 0 then return T.stow() end
    if T.junkChest() then return T.dumpJunk() end
    return nil, "nowhere to dump: T.addChest (and a bulk chest), or T.setJunkChest"
end

--------------------------------------------------------------------------
-- Dumping when the inventory fills
--------------------------------------------------------------------------

-- Hear a dig: with T.cfg.autoDump on and the room run down, make room.  Not again until there is less room than when
-- it could do nothing.
local function heard(e)
    if e.kind ~= "dig" or S.busy then return end
    local at = T.cfg.autoDump
    if not at then return end
    at = type(at) == "number" and at or DUMP_AT
    local before = T.freeSlots()
    if before > at or before >= (S.failedAt or math.huge) then return end
    S.busy = true
    local ok, err = pcall(T.autoDump)
    S.busy = false
    if not ok and err == "Terminated" then error(err, 0) end
    local after = T.freeSlots()
    S.failedAt = (not ok or after <= before) and after or nil
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
