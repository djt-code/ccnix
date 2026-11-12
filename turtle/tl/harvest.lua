-- harvest.lua -- taking blocks by name, fuel from lava, and what a job will cost in fuel
--
-- Loaded by turtlelib the first time one of its functions is used (T.harvest, T.refuelFromLava, T.fuelFor).
--
-- T.harvest digs every block in a place whose name matches a glob, nearest first, but a block only after the matching
-- blocks above it in its column (top down), and never one with a falling block (sand, gravel, concrete powder, an anvil)
-- over it that is not itself to be dug: digging out from under it would bring it down.  A block that lava touches is left
-- (opts.lava lifts that), so is one in a protected area (opts.inside names the area the job owns) and a chest or a
-- computer (T.cfg.digContainers).  It counts as it goes and stops at the target.  The place is a box in the turtle's frame
-- (the map is scanned for it as needed), a scan's result (T.scan's { ["x,y,z"] = name }) or a list of cells such as
-- T.map.find gives.  Each block is dug from the nearest cell next to it that the map shows free, tunnelling to one when
-- opts.move allows digging.  The turtle stays where the last block was.
--
-- T.refuelFromLava finds the nearest lava source the map knows, goes next to it, takes it up with an empty bucket (a
-- turtle that places an empty bucket on a source takes it up, as mine's scoop does), burns the bucket of lava for 1000
-- fuel and goes back where it began.
--
-- T.fuelFor adds up what a route, a build and some scans will cost in fuel and says whether the tank and the fuel on board
-- will do.  The cost of a scan is an estimate (set T.cfg.scanFuel = { [8] = cost } from what T.scan reports in info.fuel).

local T = require("turtlelib")
local text = require("text")
local tables = require("tables")
local glob = require("glob")

local BUCKET, LAVA_BUCKET = "minecraft:bucket", "minecraft:lava_bucket"
local BUCKET_FUEL = 1000                      -- what a bucket of lava burns for
local AIR = "minecraft:air"
local AIRS = { [AIR] = true, ["minecraft:cave_air"] = true, ["minecraft:void_air"] = true }
local LAVA = { ["minecraft:lava"] = true, ["minecraft:flowing_lava"] = true }
local FLUIDS = { ["minecraft:water"] = true, ["minecraft:flowing_water"] = true, ["minecraft:lava"] = true, ["minecraft:flowing_lava"] = true }
-- Where to go by default: along the map when something is in the way, and no scanning
local MOVE = { path = true, scan = false }
-- The blocks that fall when what is under them goes (names, and globs for the families)
local FALLING = {
    "minecraft:sand", "minecraft:red_sand", "minecraft:gravel", "minecraft:suspicious_sand", "minecraft:suspicious_gravel",
    "minecraft:*_concrete_powder", "minecraft:anvil", "minecraft:chipped_anvil", "minecraft:damaged_anvil",
    "minecraft:dragon_egg", "minecraft:pointed_dripstone",
}
local FALLING_TESTS = {}
for i, g in ipairs(FALLING) do FALLING_TESTS[i] = glob.compile(g) end
-- Does this block fall when what is under it goes?
local function isFalling(name)
    for _, test in ipairs(FALLING_TESTS) do
        if test(name) then return true end
    end
    return false
end
local SCAN_FUEL_R16 = 5300                    -- what a radius-16 scan once cost
local DETOUR = 1.25                           -- a route is this much longer than the straight way

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

-- A test on block or item names from a glob; the namespace may be left out (a glob without one also matches the
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

-- The six numbers of a box, smallest corner first, or nil and why.  A box is { x1, y1, z1, x2, y2, z2 } or has the
-- fields x1 to z2, the corners in any order.
local function boxOf(box)
    local v
    if type(box) ~= "table" then return nil, "a box is six numbers" end
    if box.x1 ~= nil then v = { box.x1, box.y1, box.z1, box.x2, box.y2, box.z2 } else v = { box[1], box[2], box[3], box[4], box[5], box[6] } end
    for i = 1, 6 do
        if not whole(v[i]) then return nil, "a box is six whole numbers" end
    end
    return math.min(v[1], v[4]), math.min(v[2], v[5]), math.min(v[3], v[6]), math.max(v[1], v[4]), math.max(v[2], v[5]), math.max(v[3], v[6])
end

-- What kind of place `where` is: "box", "scan" (a scan's { ["x,y,z"] = name }), "list" (cells), or nil.
local function kindOf(where)
    if type(where) ~= "table" then return nil end
    if where.x1 ~= nil or (#where == 6 and type(where[1]) == "number") then return "box" end
    if type(where[1]) == "table" then return "list" end
    local k = next(where)
    if type(k) == "string" and type(where[k]) == "string" then return "scan" end
    if k == nil then return "list" end
    return nil
end

-- The cells next to a block the turtle could stand in, best first, as { x, y, z, rank }: the map says air (rank 1), or has
-- never seen it (2), or with `tunnel` is solid and would be dug (3).
local function standsFor(cell, tunnel)
    local out = {}
    for _, d in ipairs({ 0, 1, 2, 3, "up", "down" }) do
        local v = T.DELTA[d]
        local s = { x = cell.x + v[1], y = cell.y + v[2], z = cell.z + v[3] }
        local name = T.map.get(s.x, s.y, s.z)
        if name == nil then s.rank = 2
        elseif AIRS[name] then s.rank = 1
        elseif tunnel and not FLUIDS[name] and not T.neverDig(name) then s.rank = 3 end
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

-- Is the map's lava touching the cell (any side, above too)?
local function lavaNear(cell)
    for _, d in ipairs({ 0, 1, 2, 3, "up", "down" }) do
        local v = T.DELTA[d]
        local name = T.map.get(cell.x + v[1], cell.y + v[2], cell.z + v[3])
        if name and LAVA[name] then return true end
    end
    return false
end

-- How many items aboard match the test.
local function countMatching(test)
    local n = 0
    for slot = 1, 16 do
        local it = turtle.getItemDetail(slot)
        if it and test(it.name) then n = n + it.count end
    end
    return n
end

-- What is aboard, { name = count }.
local function inventory()
    local out = {}
    for slot = 1, 16 do
        local it = turtle.getItemDetail(slot)
        if it then out[it.name] = (out[it.name] or 0) + it.count end
    end
    return out
end

-- Go to p, the other way round the axes if the first fails.  True, or false and why.
local function reach(p, move)
    local ok, why = T.moveTo(p.x, p.y, p.z, move)
    if ok then return true end
    local other = tables.copy(move)
    other.order = "xzy"
    return T.moveTo(p.x, p.y, p.z, other)
end

--------------------------------------------------------------------------
-- Harvesting
--------------------------------------------------------------------------

-- The cells of `where` whose block matches the test, as { x, y, z, name }, and true if cut to `limit`.  Scans a box the map
-- does not fully know unless opts.scan is false (true: always).  Nil and why if it can't.
local function cellsOf(pattern, test, where, opts, info)
    local kind = kindOf(where)
    if not kind then return nil, "harvest wants somewhere to look: a box { x1, y1, z1, x2, y2, z2 }, a scan's result or a list of cells" end
    local limit = opts.limit or 1000
    local out = {}
    if kind == "box" then
        local x1, y1, z1, x2, y2, z2 = boxOf(where)
        if not x1 then return nil, y1 end
        local box = { x1, y1, z1, x2, y2, z2 }
        local volume = (x2 - x1 + 1) * (y2 - y1 + 1) * (z2 - z1 + 1)
        local known = T.map.count("*", box)
        if opts.scan == true or (opts.scan ~= false and known and known < volume) then
            local report, why = T.scanBox(box, { move = opts.move or MOVE })
            if report then
                info.scanned = report.scanned
                if #report.failed > 0 then why = tostring(report.failed[1].why) end
            end
            if not report or #report.failed > 0 then
                if opts.scan == true and not (report and report.scanned > 0) then return nil, "couldn't scan the box: " .. tostring(why) end
                info.scanWhy = why
            end
        end
        local found, cut = T.map.find(pattern, box, limit)
        if not found then return nil, cut end
        for i = #found, 1, -1 do
            if AIRS[found[i].name] or FLUIDS[found[i].name] then table.remove(found, i) end
        end
        return found, cut == true
    end
    if kind == "scan" then
        for key, name in pairs(where) do
            local x, y, z = T.keyPos(key)
            if x and test(name) and not AIRS[name] and not FLUIDS[name] then out[#out + 1] = { x = x, y = y, z = z, name = name } end
        end
    else
        for _, c in ipairs(where) do
            if whole(c.x) and whole(c.y) and whole(c.z) then
                local name = c.name or T.map.get(c.x, c.y, c.z)
                if name == nil or (test(name) and not AIRS[name] and not FLUIDS[name]) then out[#out + 1] = { x = c.x, y = c.y, z = c.z, name = name } end
            end
        end
    end
    table.sort(out, function(m, n)
        local dm, dn = T.dist(T.pos, m), T.dist(T.pos, n)
        if dm ~= dn then return dm < dn end
        if m.x ~= n.x then return m.x < n.x end
        if m.y ~= n.y then return m.y < n.y end
        return m.z < n.z
    end)
    local cut = #out > limit
    for i = #out, limit + 1, -1 do out[i] = nil end
    return out, cut
end

-- Tell the job journal how far the harvest has got, if a job is on (without one nothing is loaded or written).
local function tellJob(info, pattern)
    if not fs.exists(T.dataPath(".job")) then return end
    local line = pattern .. ": " .. info.got .. (info.target and (" of " .. info.target) or "") .. " dug"
    local ok, err = pcall(T.job.progress, "harvest", line)
    if not ok and err == "Terminated" then error(err, 0) end
end

-- Dig the blocks in a place whose name matches a glob, nearest first and top down: how many, and what could not be.
-- Returns true, info; false, why, info when it stopped short; nil, why when it couldn't begin.
--
-- `pattern` is a glob of block names (the namespace may be left out).  `where` is a box in the turtle's frame (six numbers in a
-- table, or x1 to z2 fields; the map is scanned for it if it does not know it all, unless opts.scan is false), the result of
-- T.scan, or a list of cells ({ x, y, z }, as T.map.find gives).  `target`, if given, is how many blocks to dig before
-- stopping (opts.item, a glob of item names, counts the items of that kind that came aboard instead).  Each block is looked
-- at before it is dug and left if the map was wrong.  Left alone, and listed in info.skipped with why: a block with a
-- falling block over it that is not to be dug too, one that lava touches (opts.lava digs those), one in a protected area
-- (opts.inside names the area the job owns) and a chest or a computer (T.cfg.digContainers).  A block with no free cell
-- beside it is skipped unless opts.move lets it dig a way in.  It stops when the inventory is full (T.cfg.autoDump
-- keeps room), or the fuel is out.  Info is { got, target, items = { name = count aboard now that were not before },
-- seen, gone, skipped, failed, more, scanned, stopped }, the lists of { x, y, z, name, why }.  opts: scan, limit (cells
-- at most, default 1000), move (for T.moveTo, default { path = true, scan = false }), inside, lava, item.
function T.harvest(pattern, where, target, opts)
    opts = opts or {}
    if opts.inside then
        local inner = tables.copy(opts)
        inner.inside = nil
        return T.inside(opts.inside, T.harvest, pattern, where, target, inner)
    end
    if type(pattern) ~= "string" or pattern == "" then return nil, "harvest wants a glob of block names to dig" end
    if target ~= nil and not (whole(target) and target >= 1) then return nil, "the target is a whole number of blocks from 1" end
    local test = matcher(pattern)
    local itemTest = opts.item and matcher(opts.item)
    local info = { got = 0, target = target, items = {}, gone = 0, skipped = {}, failed = {}, more = false }
    local cells, cut = cellsOf(pattern, test, where, opts, info)
    if not cells then return nil, cut end
    info.seen, info.more = #cells, cut == true
    local move = opts.move or MOVE
    local tunnel = move.dig and true or false

    -- the cells still to do, by column, highest first: only the head of a column may be dug
    local columns, todo = {}, 0
    for _, c in ipairs(cells) do
        local k = c.x .. "," .. c.z
        columns[k] = columns[k] or {}
        table.insert(columns[k], c)
    end
    for _, col in pairs(columns) do
        table.sort(col, function(m, n) return m.y > n.y end)
        todo = todo + #col
    end
    local function skip(c, why)
        info.skipped[#info.skipped + 1] = { x = c.x, y = c.y, z = c.z, name = c.name, why = why }
    end
    -- what can be said before going: protected, a container, lava touching
    for key, col in pairs(columns) do
        local keep = {}
        for _, c in ipairs(col) do
            local guard = T.guarded(c.x, c.y, c.z)
            if guard then skip(c, "protected: " .. guard)
            elseif c.name and T.neverDig(c.name) and not T.cfg.digContainers then skip(c, "won't dig " .. c.name .. " (a container or a computer)")
            elseif not opts.lava and lavaNear(c) then skip(c, "lava touches it")
            else keep[#keep + 1] = c end
        end
        columns[key] = keep
    end

    local startItems = itemTest and countMatching(itemTest) or 0
    local function have()
        if itemTest then return countMatching(itemTest) - startItems end
        return info.got
    end
    local before = inventory()

    -- dig one block: true if it counted, nil if the way is shut or it changed
    local function dig(c)
        local why
        for _, s in ipairs(standsFor(c, tunnel)) do
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
                if T.neverDig(here) and not T.cfg.digContainers then
                    skip(c, "won't dig " .. here .. " (a container or a computer)")
                    return
                end
                if T.inventoryFull() then
                    info.stopped = "the inventory is full"
                    return "stop"
                end
                local dug, digWhy = T.digDir(d)
                if dug then
                    info.got = info.got + 1
                    if info.got % 8 == 0 then tellJob(info, pattern) end
                else
                    info.failed[#info.failed + 1] = { x = c.x, y = c.y, z = c.z, name = c.name, why = "couldn't dig it: " .. tostring(digWhy) }
                end
                return
            end
            why = reason
            if reason == "out of fuel" then
                info.stopped = "out of fuel"
                return "stop"
            end
        end
        if not why then why = "no free cell beside it that the map shows" end
        info.failed[#info.failed + 1] = { x = c.x, y = c.y, z = c.z, name = c.name, why = "couldn't get next to it: " .. tostring(why) }
    end

    local function loop()
        while not (target and have() >= target) and not info.stopped do
            -- the nearest cell at the head of a column
            local best, bestKey, bestAt
            for key, col in pairs(columns) do
                local c = col[1]
                if c then
                    local d = T.dist(T.pos, c)
                    if not best or d < bestAt or (d == bestAt and (c.x < best.x or (c.x == best.x and c.z < best.z))) then
                        best, bestKey, bestAt = c, key, d
                    end
                end
            end
            if not best then break end
            table.remove(columns[bestKey], 1)
            local above = T.map.get(best.x, best.y + 1, best.z)
            if above and isFalling(above) then
                skip(best, above .. " is over it: digging it out would bring that down")
            else
                if dig(best) == "stop" then break end
            end
            breathe()
        end
    end
    loop()
    tellJob(info, pattern)

    local after = inventory()
    for name, n in pairs(after) do
        if n > (before[name] or 0) then info.items[name] = n - (before[name] or 0) end
    end
    local done = target and have() >= target
    if done and #info.failed == 0 then return true, info end
    if not target and #info.failed == 0 and not info.stopped then return true, info end
    local why
    if info.stopped then why = info.stopped
    elseif #info.failed > 0 then why = info.failed[1].why
    elseif #info.skipped > 0 then why = #info.skipped .. " left alone (" .. info.skipped[1].why .. ")"
    else why = "no more matching blocks within reach" end
    if target and not done then why = "got " .. have() .. " of " .. target .. ": " .. why end
    if done then why = "reached the target, but " .. #info.failed .. " could not be dug: " .. why end
    return false, why, info
end

--------------------------------------------------------------------------
-- Fuel from lava
--------------------------------------------------------------------------

-- Burn one lava bucket from the inventory.  True if it burned.
local function burnBucket()
    local before = turtle.getFuelLevel()
    local sel = turtle.getSelectedSlot()
    local burned = T.selectItem(LAVA_BUCKET) and turtle.refuel(1)
    turtle.select(sel)
    return burned and turtle.getFuelLevel() > before
end

-- Fill the tank from lava the map knows: go to the nearest source, take it up with an empty bucket, burn it, and
-- come back, facing as before.  Returns true, fuel gained; false, why, fuel gained; nil, why.
--
-- `target` is the fuel level to reach (default the tank's limit); it stops there, or when another bucket would not fit
-- the tank (1000 each), or when no lava source is left to reach.  It needs an empty bucket aboard (a lava bucket aboard
-- is burned first).  The lava comes from the map (T.scan puts it there), the nearest first; a cell is looked at before
-- the bucket goes on it, and one that proves to be flowing, not a source, is passed over.  opts.tries (default 20) is
-- how many lava cells it will try, opts.move is T.moveTo's (default { path = true, scan = false }, never into lava).
function T.refuelFromLava(target, opts)
    opts = opts or {}
    local level, limit = turtle.getFuelLevel(), turtle.getFuelLimit()
    if level == "unlimited" then return true, 0 end
    target = math.min(target or limit, limit)
    local start = level
    while turtle.getFuelLevel() < target and T.countItem(LAVA_BUCKET) > 0 and limit - turtle.getFuelLevel() >= BUCKET_FUEL do
        if not burnBucket() then break end
    end
    local function gained() return turtle.getFuelLevel() - start end
    local function fits() return limit - turtle.getFuelLevel() >= BUCKET_FUEL end
    if turtle.getFuelLevel() >= target or not fits() then return true, gained() end
    if T.countItem(BUCKET) == 0 then
        return false, "no empty bucket aboard to take lava up with", gained()
    end
    local move = opts.move or MOVE
    local from, dir = T.here(), T.dir
    local found, why = T.map.find("minecraft:lava")
    if not found then return nil, "the map has no lava to look in: " .. tostring(why) end
    local candidates = {}
    for _, c in ipairs(found) do
        local _, state = T.map.get(c.x, c.y, c.z)
        if not (state and state.level and tonumber(state.level) ~= 0) then candidates[#candidates + 1] = c end
    end
    if #candidates == 0 then return false, "the map knows no lava source", gained() end
    local tries, stopWhy = opts.tries or 20, nil
    local tried = 0
    while turtle.getFuelLevel() < target and fits() and #candidates > 0 and tried < tries do
        local best = 1
        for i = 2, #candidates do
            if T.dist(T.pos, candidates[i]) < T.dist(T.pos, candidates[best]) then best = i end
        end
        local c = table.remove(candidates, best)
        tried = tried + 1
        local scooped = false
        for _, s in ipairs(standsFor(c, false)) do
            local ok = T.moveTo(s.x, s.y, s.z, move)
            if ok then
                local d = T.dirTo(c)
                local seen, data = T.look(d)
                if not (seen and type(data) == "table" and LAVA[data.name]) then
                    T.map.set(c.x, c.y, c.z, seen and type(data) == "table" and data.name or AIR, seen and data.state or nil)
                elseif data.state and tonumber(data.state.level) ~= 0 then
                    T.map.set(c.x, c.y, c.z, data.name, data.state)
                else
                    local sel = turtle.getSelectedSlot()
                    if T.selectItem(BUCKET) and T.placeDir(d) then scooped = true else stopWhy = "the bucket would not take the lava up at " .. T.posKey(c) end
                    turtle.select(sel)
                end
                break
            end
        end
        if scooped and not burnBucket() then
            stopWhy = "took lava up but it would not burn"
            break
        end
    end
    local back, backWhy = reach(from, move)
    T.face(dir)
    local ok = turtle.getFuelLevel() >= target or not fits()
    if not back then return false, "couldn't get back to " .. T.posKey(from) .. ": " .. tostring(backWhy), gained() end
    if ok then return true, gained() end
    return false, stopWhy or (#candidates == 0 and "no more lava sources it could reach") or ("gave up after " .. tried .. " tries"), gained()
end

--------------------------------------------------------------------------
-- What a job costs in fuel
--------------------------------------------------------------------------

-- What a scan of radius r costs in fuel: T.cfg.scanFuel[r] if given, else the one measured cost scaled by volume.
local function scanCost(r)
    local given = type(T.cfg.scanFuel) == "table" and T.cfg.scanFuel[r]
    if given then return given end
    return math.ceil(SCAN_FUEL_R16 * (r / 16) ^ 3)
end

-- Moves along a list of points from where the turtle is, as the straight ways between them add up.
local function routeLength(points, from)
    local n, at = 0, from
    for _, p in ipairs(points) do
        n = n + T.dist(at, p)
        at = p
    end
    return n, at
end

-- The scans a box takes (radius r tiled) and the moves between their centres.
local function boxScans(box, r)
    local x1, y1, z1, x2, y2, z2 = boxOf(box)
    if not x1 then return nil, y1 end
    local step = 2 * r + 1
    local tiles = math.ceil((x2 - x1 + 1) / step) * math.ceil((y2 - y1 + 1) / step) * math.ceil((z2 - z1 + 1) / step)
    return tiles, tiles * step
end

-- What a build takes in moves: a stand over each cell it places, a climb per layer, and the way to its start.
local function buildMoves(source, from)
    local plan, why = T.blueprint.new(source)
    if not plan then return nil, why end
    local x1, y1, z1, x2, y2, z2 = T.blueprint.extent(plan)
    if not x1 then return 0 end
    local cells = 0
    for y = y1, y2 do
        for z = z1, z2 do
            for x = x1, x2 do
                local name = T.blueprint.at(plan, x, y, z)
                if name and not AIRS[name] then cells = cells + 1 end
            end
            breathe()
        end
    end
    return cells + (y2 - y1 + 1) + T.dist(from, { x = x1, y = y1, z = z1 }), cells
end

-- What a job will cost in fuel, against the tank and the fuel on board: true, info if it will do; false, why, info if short;
-- nil, why for a plan it can't read.  Moves nothing.
--
-- `plan` is a table with any of: route (a list of points { x, y, z } to go through from here), go (one point), build (a
-- blueprint, or its text), box and radius (a box to scan with T.scanBox), scans (a number of scans of `radius`, default
-- 8), back (true: and return to where the turtle is now), extra (fuel to add).  A plan that is a blueprint, or a bare
-- list of points, is a build or a route.  Moves cost a fuel each; those of a route and the way to a build are made
-- 25% longer for detours (opts.detour), and T.cfg.fuelMargin (30) is added on top.  Info is { route, build, scans, back,
-- extra, margin, need, tank, board, have, enough, short }, the costs in fuel and `board` the fuel value of the T.fuel
-- items aboard.
function T.fuelFor(plan, opts)
    opts = opts or {}
    if type(plan) ~= "table" then return nil, "fuelFor wants a plan: { route = ..., build = ..., scans = ..., back = true }" end
    if plan.layers or plan.legend then plan = { build = plan }
    elseif type(plan[1]) == "table" and plan.route == nil and plan.build == nil then plan = { route = plan } end
    local detour = opts.detour or DETOUR
    local here = T.here()
    local info = { route = 0, build = 0, scans = 0, back = 0, extra = plan.extra or 0 }
    local at = here
    local points = {}
    if plan.go then points[#points + 1] = plan.go end
    for _, p in ipairs(plan.route or {}) do points[#points + 1] = p end
    for _, p in ipairs(points) do
        if not (type(p) == "table" and whole(p.x) and whole(p.y) and whole(p.z)) then return nil, "a point of the route is { x, y, z }, whole numbers" end
    end
    if #points > 0 then
        local len
        len, at = routeLength(points, here)
        info.route = math.ceil(len * detour)
    end
    if plan.build then
        local moves, cells = buildMoves(plan.build, at)
        if not moves then return nil, cells end
        info.build = math.ceil(moves * detour)
    end
    local r = plan.radius or 8
    if not (whole(r) and r >= 1) then return nil, "the radius of a scan is a whole number from 1" end
    if plan.box then
        local tiles, moves = boxScans(plan.box, r)
        if not tiles then return nil, moves end
        info.scans = tiles * scanCost(r) + moves
    end
    if plan.scans then
        if not (whole(plan.scans) and plan.scans >= 0) then return nil, "scans is a whole number of scans" end
        info.scans = info.scans + plan.scans * scanCost(r)
    end
    if plan.back then info.back = math.ceil(T.dist(at, here) * detour) end
    info.margin = T.cfg.fuelMargin or 30
    info.need = info.route + info.build + info.scans + info.back + info.extra + info.margin
    local tank = turtle.getFuelLevel()
    if tank == "unlimited" then
        info.tank, info.board, info.have, info.enough, info.short = "unlimited", 0, math.huge, true, 0
        return true, info
    end
    info.tank = tank
    info.have = T.totalFuelAvailable()
    info.board = info.have - tank
    info.enough = info.have >= info.need
    info.short = math.max(0, info.need - info.have)
    if info.enough then return true, info end
    return false, "short of fuel: needs about " .. info.need .. ", has " .. info.have .. " (" .. tank .. " in the tank, " .. info.board
        .. " on board): " .. info.short .. " short", info
end

return T
