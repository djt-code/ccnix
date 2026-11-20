-- area.lua -- work over a box: paving its floor, clearing it out, picking up what lies in it
--
-- Loaded by turtlelib the first time T.pave, T.clearBox or T.sweep is used.  Cells are the turtle's own (the frame it
-- counts in).  From the claude model's own helpers (ADR-0015 D8): its serpentine road floor, its three-rows-a-move
-- tunnel, and the pickup of what its digs dropped.
--
-- Each goes over the box in rows along its longer side, one way and back (a serpentine), starting at the corner
-- nearest the turtle, so a cell costs one move.  opts.exclude (protected areas' names and boxes, as T.harvest takes)
-- leaves cells alone; protected areas hold as they do for every dig; opts.maxFuel stops it, saying so; opts.inside
-- names the area the job owns.  Each returns true, info; false, why, info when it stopped or cells failed; nil, why
-- when it couldn't begin.  Info has failed = { { x, y, z, why } } and stopped (why it stopped early, if it did).

local T = require("turtlelib")

local MOST_CELLS = 16384        -- the biggest box worked at once

-- The cells of the layer y of the box, in a serpentine: rows along the longer side, from the corner nearest `from`.
local function serpentine(x1, z1, x2, z2, y, from)
    local alongX = (x2 - x1) >= (z2 - z1)
    local a1, a2, b1, b2 = x1, x2, z1, z2
    if not alongX then a1, a2, b1, b2 = z1, z2, x1, x2 end
    local fa, fb = alongX and from.x or from.z, alongX and from.z or from.x
    local aFwd = math.abs(fa - a1) <= math.abs(fa - a2)
    local bFwd = math.abs(fb - b1) <= math.abs(fb - b2)
    local out = {}
    local bs, be, bstep = b1, b2, 1
    if not bFwd then bs, be, bstep = b2, b1, -1 end
    for b = bs, be, bstep do
        local as, ae, astep = a1, a2, 1
        if not aFwd then as, ae, astep = a2, a1, -1 end
        for a = as, ae, astep do
            if alongX then out[#out + 1] = { x = a, y = y, z = b } else out[#out + 1] = { x = b, y = y, z = a } end
        end
        aFwd = not aFwd
    end
    return out
end

-- The fuel spent since `start` (what the tank lost), 0 where it's unlimited.
local function spentSince(start)
    local f = turtle.getFuelLevel()
    if type(f) ~= "number" or type(start) ~= "number" then return 0 end
    return start - f
end

-- What the box and opts come to for every function here: x1..z2, the exclude test, or nil and why.
local function setUp(name, box, opts)
    local x1, y1, z1, x2, y2, z2 = T.boxOf(box)
    if not x1 then return nil, name .. ": " .. y1 end
    if (x2 - x1 + 1) * (y2 - y1 + 1) * (z2 - z1 + 1) > MOST_CELLS then
        return nil, name .. ": the box is over " .. MOST_CELLS .. " cells: do it in parts"
    end
    if opts.maxFuel ~= nil and not (type(opts.maxFuel) == "number" and opts.maxFuel >= 0) then
        return nil, name .. ": opts.maxFuel is a number from 0"
    end
    local out, why = T.excludeTest(opts.exclude)
    if not out then return nil, name .. ": " .. why end
    return { x1 = x1, y1 = y1, z1 = z1, x2 = x2, y2 = y2, z2 = z2, out = out }
end

-- With T.cfg.digNeedsRoom, would what the map shows `p`'s cells (a list of { x, y, z }) give, dug, fit aboard?  Each
-- kind of drop (T.digDrop) wants a stack of it with room, or a free slot; cells the map hasn't seen, already `keep`
-- or protected aren't counted.  Nil, or why not, with the counts.
local function noRoomFor(cells, keep)
    if not T.cfg.digNeedsRoom then return nil end
    local count, kinds = {}, {}
    for _, c in ipairs(cells) do
        local name = T.map.get(c.x, c.y, c.z)
        local drop = name ~= keep and not T.guarded(c.x, c.y, c.z) and T.digDrop(name)
        if drop then
            if not count[drop] then kinds[#kinds + 1] = drop end
            count[drop] = (count[drop] or 0) + 1
        end
    end
    local need, free = {}, T.freeSlots()
    for _, drop in ipairs(kinds) do
        local merges = false
        for slot = 1, 16 do
            local it = turtle.getItemDetail(slot)
            merges = merges or (it ~= nil and it.name == drop and turtle.getItemSpace(slot) > 0)
        end
        if not merges then need[#need + 1] = drop end
    end
    if #need <= free then return nil end
    table.sort(kinds)
    local listed = {}
    for i, drop in ipairs(kinds) do listed[i] = drop .. " x" .. count[drop] end
    return string.format("what it would dig won't fit: the map shows %d kinds to dig (%s), %d of them with no stack aboard "
        .. "to join, and %d slot%s free (T.cfg.digNeedsRoom; T.stow or drop something first, or a smaller box)", #kinds,
        table.concat(listed, ", "), #need, free, free == 1 and " is" or "s are")
end

-- The result from info: true, info; or false, why, info.
local function result(info, what)
    if info.stopped then return false, info.stopped, info end
    if #info.failed > 0 then
        local f = info.failed[1]
        return false, what .. ": " .. #info.failed .. " cells failed, the first " .. f.x .. "," .. f.y .. "," .. f.z .. ": " .. f.why, info
    end
    return true, info
end

-- Pave a floor: every cell of the layer `box` (y1 = y2: the floor's own layer) made `item`, the turtle going over it
-- in rows a block above, digging down what's there and placing down: one move a cell.  True, info; false, why, info.
--
-- A cell already holding the item is left as it is.  What a dig gives comes aboard (T.cfg.digNeedsRoom refuses a dig
-- with no room for it, and the whole pave before it moves when the kinds the map shows to dig need more free slots
-- than there are).  It stops when the item runs out, the fuel does or opts.maxFuel is spent.  opts: exclude,
-- maxFuel, inside, move (T.moveTo's for going between rows and to the start; default { path = true, scan = false }).
-- Info is { placed, there (already the item), failed, stopped, spent }.
function T.pave(box, item, opts)
    opts = opts or {}
    local b, why = setUp("pave", box, opts)
    if not b then return nil, why end
    if b.y1 ~= b.y2 then return nil, "pave: the box is the floor's one layer (y1 = y2)" end
    if type(item) ~= "string" or item == "" then return nil, "pave wants the item to lay, like minecraft:stone_bricks" end
    if not item:find(":", 1, true) then item = "minecraft:" .. item end
    local info = { placed = 0, there = 0, failed = {}, spent = 0 }
    local start = turtle.getFuelLevel()
    local move = opts.move or { path = true, scan = false }
    local function run()
        local cells = {}
        for _, c in ipairs(serpentine(b.x1, b.z1, b.x2, b.z2, b.y1, T.pos)) do
            if not b.out(c) then cells[#cells + 1] = c end
        end
        local full = noRoomFor(cells, item)
        if full then return nil, "pave: " .. full end
        for _, c in ipairs(cells) do
            if opts.maxFuel and spentSince(start) >= opts.maxFuel then
                info.stopped = "pave: spent " .. spentSince(start) .. " fuel (opts.maxFuel " .. opts.maxFuel .. ")"
                break
            end
            if T.countItem(item) == 0 then
                info.stopped = "pave: out of " .. item .. " (" .. info.placed .. " placed)"
                break
            end
            local ok, moveWhy = T.moveTo(c.x, c.y + 1, c.z, move)
            if not ok then
                info.failed[#info.failed + 1] = { x = c.x, y = c.y, z = c.z, why = "couldn't get over it: " .. tostring(moveWhy) }
            else
                local seen, data = T.look("down")
                local here = seen and type(data) == "table" and data.name or nil
                if here == item then
                    info.there = info.there + 1
                else
                    local dug, digWhy = true, nil
                    if here then dug, digWhy = T.digDir("down") end
                    if not dug then
                        info.failed[#info.failed + 1] = { x = c.x, y = c.y, z = c.z, why = "couldn't dig " .. here .. ": " .. tostring(digWhy) }
                    else
                        T.selectItem(item)
                        local placed, placeWhy = T.placeDir("down")
                        if placed then info.placed = info.placed + 1
                        else info.failed[#info.failed + 1] = { x = c.x, y = c.y, z = c.z, why = "the game wouldn't place it: " .. tostring(placeWhy) } end
                    end
                end
            end
        end
        info.spent = spentSince(start)
        return result(info, "pave")
    end
    if opts.inside then return T.inside(opts.inside, run) end
    return run()
end

-- Clear a box (a tunnel, a room) to air, three layers a pass: along the middle layer of each three, digging ahead,
-- above and below, a third of the moves of digging cell by cell.  True, info; false, why, info.
--
-- It digs only inside the box (not what opts.exclude lists or a protected area holds), going to the box through what
-- the map shows open, and refuses a dig with lava or a water source beside it as T.moveTo does (opts.liquid digs it).
-- What the digs give comes aboard; it stops when the inventory is full (T.stow, then call it again: it goes on where
-- the box is still solid), the fuel runs out or opts.maxFuel is spent.  opts: exclude, maxFuel, inside, liquid.  Info
-- is { dug, failed, stopped, spent }.
function T.clearBox(box, opts)
    opts = opts or {}
    local b, why = setUp("clearBox", box, opts)
    if not b then return nil, why end
    local inBox = {}
    for x = b.x1, b.x2 do for y = b.y1, b.y2 do for z = b.z1, b.z2 do
        local c = { x = x, y = y, z = z }
        if not b.out(c) then inBox[T.posKey(c)] = true end
    end end end
    local info = { dug = 0, failed = {}, spent = 0 }
    local start = turtle.getFuelLevel()
    local move = { path = true, scan = false, dig = true, digOnly = inBox, liquid = opts.liquid }
    local function digSide(d, x, y, z)
        local k = x .. "," .. y .. "," .. z
        if not inBox[k] then return end
        local seen, data = T.look(d)
        if not (seen and type(data) == "table" and data.name) then return end
        if not opts.liquid and T.liquidNear(x, y, z) then
            info.failed[#info.failed + 1] = { x = x, y = y, z = z, why = "lava or a water source beside it (opts.liquid digs it)" }
            return
        end
        local dug, digWhy = T.digDir(d)
        if not dug then info.failed[#info.failed + 1] = { x = x, y = y, z = z, why = "couldn't dig " .. data.name .. ": " .. tostring(digWhy) } end
    end
    local function run()
        -- (every dig in the box counted, the moves' and the ones above and below)
        local off = T.onChange(function(e)
            if e.kind == "dig" and inBox[e.x .. "," .. e.y .. "," .. e.z] then info.dug = info.dug + 1 end
        end)
        local layers = {}
        local y = b.y1 + 1
        while true do
            if y > b.y2 then y = b.y2 end
            layers[#layers + 1] = y
            if y + 1 >= b.y2 then break end
            y = y + 3
        end
        for _, ly in ipairs(layers) do
            for _, c in ipairs(serpentine(b.x1, b.z1, b.x2, b.z2, ly, T.pos)) do
                if inBox[T.posKey(c)] then
                    if opts.maxFuel and spentSince(start) >= opts.maxFuel then
                        info.stopped = "clearBox: spent " .. spentSince(start) .. " fuel (opts.maxFuel " .. opts.maxFuel .. ")"
                        break
                    end
                    if T.freeSlots() == 0 then
                        info.stopped = "clearBox: the inventory is full (T.stow, then clearBox again)"
                        break
                    end
                    local ok, moveWhy = T.moveTo(c.x, c.y, c.z, move)
                    if not ok then
                        info.failed[#info.failed + 1] = { x = c.x, y = c.y, z = c.z, why = "couldn't get there: " .. tostring(moveWhy) }
                    else
                        digSide("up", c.x, c.y + 1, c.z)
                        digSide("down", c.x, c.y - 1, c.z)
                    end
                end
            end
            if info.stopped then break end
        end
        off()
        info.spent = spentSince(start)
        return result(info, "clearBox")
    end
    if opts.inside then return T.inside(opts.inside, run) end
    return run()
end

-- Pick up what lies in a box (the drops of digs, what a player threw), going over each layer, sucking ahead, above and
-- below from empty cells only: never from a chest.  True, info; false, why, info.
--
-- It moves only through what the map shows open (no digs), and stops when the inventory is full or opts.maxFuel is
-- spent.  opts: exclude, maxFuel, inside, move (T.moveTo's; default { path = true, scan = false }).  Info is { picked
-- (items), failed, stopped, spent }.
function T.sweep(box, opts)
    opts = opts or {}
    local b, why = setUp("sweep", box, opts)
    if not b then return nil, why end
    local info = { picked = 0, failed = {}, spent = 0 }
    local start = turtle.getFuelLevel()
    local move = opts.move or { path = true, scan = false }
    local function carried()
        local n = 0
        for s = 1, 16 do n = n + turtle.getItemCount(s) end
        return n
    end
    local function inside(x, y, z)
        return x >= b.x1 and x <= b.x2 and y >= b.y1 and y <= b.y2 and z >= b.z1 and z <= b.z2 and not b.out({ x = x, y = y, z = z })
    end
    local function suckAt(d)
        local v = T.DELTA[d]
        local x, y, z = T.pos.x + v[1], T.pos.y + v[2], T.pos.z + v[3]
        if not inside(x, y, z) then return end
        local seen = T.look(d)
        if seen then return end                           -- (a block: maybe a chest; only empty cells are swept)
        while T.freeSlots() > 0 and T.suckDir(d) do end
    end
    local function run()
        local before = carried()
        for y = b.y1, b.y2 do
            for _, c in ipairs(serpentine(b.x1, b.z1, b.x2, b.z2, y, T.pos)) do
                if not b.out(c) then
                    if opts.maxFuel and spentSince(start) >= opts.maxFuel then
                        info.stopped = "sweep: spent " .. spentSince(start) .. " fuel (opts.maxFuel " .. opts.maxFuel .. ")"
                        break
                    end
                    if T.freeSlots() == 0 then
                        info.stopped = "sweep: the inventory is full"
                        break
                    end
                    -- (what lies in the next cell is taken before going in: from inside it, it can't be reached)
                    if T.dist(T.pos, c) == 1 then suckAt(T.dirTo(c)) end
                    local ok = T.dist(T.pos, c) == 0 or T.moveTo(c.x, c.y, c.z, move)
                    if ok then
                        suckAt("down")
                        suckAt("up")
                    end
                end
            end
            if info.stopped then break end
        end
        info.picked = carried() - before
        info.spent = spentSince(start)
        return result(info, "sweep")
    end
    if opts.inside then return T.inside(opts.inside, run) end
    return run()
end

return T
