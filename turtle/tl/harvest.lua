-- harvest.lua -- taking blocks by name, fuel from lava, and what a job will cost in fuel
--
-- Loaded by turtlelib the first time one of its functions is used (T.harvest, T.refuelFromLava, T.fuelFor).
--
-- T.harvest digs every block in a place whose name matches a glob, nearest first, but a block only after the matching
-- blocks above it in its column (top down), and never one with a falling block (sand, gravel, concrete powder, an anvil)
-- over it that is not itself to be dug: digging out from under it would bring it down.  A block that lava or a water source
-- touches beside it or over it (T.liquidNear) is left (opts.liquid lifts that), so is one in a protected area (opts.inside names the area the job owns) and a chest or a
-- computer (T.cfg.digContainers).  It counts as it goes and stops at the target.  The place is a box in the turtle's frame
-- (the map is scanned for it as needed), a scan's result (T.scan's { ["x,y,z"] = name }) or a list of cells such as
-- T.map.find gives.  Each block is dug from the nearest cell next to it that the map shows free, tunnelling to one when
-- opts.move allows digging.  The turtle stays where the last block was.
--
-- T.refuelFromLava finds the nearest lava source the map knows within reach (those it has seen at level 0 first), goes
-- next to it, takes it up with an empty bucket (a turtle that places an empty bucket on a source takes it up, as mine's
-- scoop does), burns the bucket of lava for 1000 fuel and goes back where it began.  In the nether, with none in reach,
-- it digs down to the lava sea and back (ADR-0023 D3).
--
-- T.fuelFor adds up what a route, a build and some scans will cost in fuel and says whether the tank and the fuel on board
-- will do.  A scan of radius 8 or less costs nothing (the Geo Scanner's free radius by default); a wider one is an
-- estimate (set T.cfg.scanFuel = { [12] = cost } from what T.scan reports in info.fuel).

local T = require("turtlelib")
local text = require("text")
local tables = require("tables")
local realtime = require("realtime")

local BUCKET, LAVA_BUCKET = "minecraft:bucket", "minecraft:lava_bucket"
local BUCKET_FUEL = 1000                      -- what a bucket of lava burns for
local AIR = "minecraft:air"
local AIRS = { [AIR] = true, ["minecraft:cave_air"] = true, ["minecraft:void_air"] = true }
local LAVA = { ["minecraft:lava"] = true, ["minecraft:flowing_lava"] = true }
local FLUIDS = { ["minecraft:water"] = true, ["minecraft:flowing_water"] = true, ["minecraft:lava"] = true, ["minecraft:flowing_lava"] = true }
-- Where to go by default: along the map when something is in the way, and no scanning
local MOVE = { path = true, scan = false }
local SCAN_FUEL_R16 = 5300                    -- what a radius-16 scan once cost
local FREE_RADIUS = 8                         -- a scan this wide or less costs nothing (Advanced Peripherals' default)
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

-- A test on block or item names from a glob, or a list or set of them; the namespace may be left out (a glob without
-- one also matches the short name).  turtlelib's, as for every list of names.
local matcher = T.nameTest

local boxOf = T.boxOf

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

-- Why a block is left for the liquid T.liquidNear finds beside it or over it ("lava touches it (minecraft:lava at
-- 5,0,0)"), or nil if none would flow in.
local function liquidTouches(cell)
    local name, x, y, z = T.liquidNear(cell.x, cell.y, cell.z)
    if not name then return nil end
    return (LAVA[name] and "lava" or "a water source") .. " touches it (" .. name .. " at " .. x .. "," .. y .. "," .. z .. ")"
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

-- A test for the cells opts.exclude leaves alone: a list of protected areas' names and boxes (six numbers, or x1 to z2
-- fields).  The test, or nil and why for an entry that is neither.
local excluded = T.excludeTest


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

-- Dig the blocks in a place matching a glob, nearest first, top down, leaving protected areas, ones liquid would flow in
-- by and ones under sand.  True, info; false, why, info when short; nil, why if it couldn't begin.
--
-- `pattern` is a glob of block names (the namespace may be left out).  `where` is a box in the turtle's frame (six numbers in a
-- table, or x1 to z2 fields; the map is scanned for it if it does not know it all, unless opts.scan is false), the result of
-- T.scan, or a list of cells ({ x, y, z }, as T.map.find gives).  `target`, if given, is how many blocks to dig before
-- stopping (opts.item, a glob of item names, counts the items of that kind that came aboard instead).  Each block is looked
-- at before it is dug and left if the map was wrong.  Left alone, and listed in info.skipped with why: a block with a
-- falling block over it that is not to be dug too, one that lava or a water source touches beside it or over it (T.liquidNear;
-- opts.liquid, or opts.lava as before, digs those), one in a protected area
-- (opts.inside names the area the job owns) and a chest or a computer (T.cfg.digContainers).  A block with no free cell
-- beside it is skipped unless opts.move lets it dig a way in, and so is one in opts.exclude (protected areas' names and boxes,
-- as T.refuelFromLava takes).  It stops when the inventory is full (T.cfg.autoDump keeps room), the fuel is out, it has
-- spent opts.maxFuel fuel (scanning included) or run opts.timeout seconds (real ones, at any tick rate).  Info is { got,
-- target, items = { name = count aboard now that were not before }, seen, gone, skipped, failed, more, scanned, spent,
-- stopped }, the lists of { x, y, z, name, why }, spent the fuel it used.  opts: scan, limit (cells at most, default 1000), move (for T.moveTo, default
-- { path = true, scan = false }), inside, liquid, item, exclude, maxFuel, timeout.
function T.harvest(pattern, where, target, opts)
    opts = opts or {}
    if opts.inside then
        local inner = tables.copy(opts)
        inner.inside = nil
        return T.inside(opts.inside, T.harvest, pattern, where, target, inner)
    end
    if type(pattern) ~= "string" or pattern == "" then return nil, "harvest wants a glob of block names to dig" end
    if target ~= nil and not (whole(target) and target >= 1) then return nil, "the target is a whole number of blocks from 1" end
    for _, o in ipairs({ "maxFuel", "timeout" }) do
        if opts[o] ~= nil and not (type(opts[o]) == "number" and opts[o] >= 0) then return nil, "opts." .. o .. " is a number from 0" end
    end
    local outside, badExclude = excluded(opts.exclude)
    if not outside then return nil, badExclude end
    -- the fuel spent so far (what the tank lost; a refuel on the way isn't taken off) and the clock
    local began, spent, lastLevel = realtime.now(), 0, turtle.getFuelLevel()
    local function spend()
        local level = turtle.getFuelLevel()
        if level == "unlimited" then return 0 end
        if level < lastLevel then spent = spent + lastLevel - level end
        lastLevel = level
        return spent
    end
    local test = matcher(pattern)
    local itemTest = opts.item and matcher(opts.item)
    local info = { got = 0, target = target, items = {}, gone = 0, skipped = {}, failed = {}, more = false }
    local cells, cut = cellsOf(pattern, test, where, opts, info)
    if not cells then return nil, cut end
    info.spent = spend()
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
            elseif outside(c) then skip(c, "in opts.exclude")
            elseif c.name and T.neverDig(c.name) and not T.cfg.digContainers then skip(c, "won't dig " .. c.name .. " (a container or a computer)")
            else
                local wet = not (opts.liquid or opts.lava) and liquidTouches(c)
                if wet then skip(c, wet) else keep[#keep + 1] = c end
            end
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
        if not why then
            why = "no free cell beside it that the map shows" .. (tunnel and "" or " (opts.move = { dig = true } tunnels in)")
        end
        info.failed[#info.failed + 1] = { x = c.x, y = c.y, z = c.z, name = c.name, why = "couldn't get next to it: " .. tostring(why) }
    end

    local function loop()
        while not (target and have() >= target) and not info.stopped do
            if opts.maxFuel and spend() >= opts.maxFuel then
                info.stopped = "spent " .. spent .. " fuel (opts.maxFuel " .. opts.maxFuel .. ")"
                break
            end
            if opts.timeout and realtime.now() - began >= opts.timeout then
                info.stopped = "ran " .. opts.timeout .. " s (opts.timeout)"
                break
            end
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
            if above and T.isFalling(above) then
                skip(best, above .. " is over it: digging it out would bring that down")
            else
                if dig(best) == "stop" then break end
            end
            breathe()
        end
    end
    loop()
    info.spent = spend()
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

-- What came of the tries at lava that came to nothing, for a why: "1,-1,1 flowing, 3,-1,3 out of reach", three at most
-- and how many more; nil if every try took lava up.
local TRIES_SHOWN = 3
local function triesText(tries)
    local parts = {}
    for _, t in ipairs(tries) do
        if t.found ~= "taken" then parts[#parts + 1] = T.posKey(t) .. " " .. t.found end
    end
    if #parts == 0 then return nil end
    local shown = {}
    for i = 1, math.min(#parts, TRIES_SHOWN) do shown[i] = parts[i] end
    local out = table.concat(shown, ", ")
    if #parts > TRIES_SHOWN then out = out .. " and " .. (#parts - TRIES_SHOWN) .. " more (info.tries)" end
    return out
end

-- How far from where it starts T.refuelFromLava looks for lava by default (opts.within), and how far down it digs for
-- the nether's lava sea (opts.depth)
local WITHIN, DEPTH = 64, 128
local SEA_LEVELS = 4                          -- the most levels of the lava sea it goes into for more buckets

-- Is this lava data a source (level 0, or no level said)?
local function isSource(data)
    return type(data) == "table" and LAVA[data.name] and not (data.state and data.state.level ~= nil
        and tonumber(data.state.level) ~= 0)
end

-- Take up the lava source on side d with the empty bucket and burn it.  "taken", or why not.
local function scoop(d)
    if T.countItem(BUCKET) == 0 then return "no empty bucket" end
    local sel = turtle.getSelectedSlot()
    local placed = T.selectItem(BUCKET) and T.placeDir(d)
    turtle.select(sel)
    if not placed then return "the bucket would not take it up" end
    if not burnBucket() then return "took lava up but it would not burn" end
    return "taken"
end

-- The nether's way (ADR-0023 D3): straight down from where the turtle is to the lava sea, digging what is in the way
-- and dropping through caverns, sources taken at the surface (the one under it, then round it, a level or more into
-- it), and back up the shaft.  Stops at `target`, when another bucket wouldn't fit, or with why.  Returns what it did:
-- { from (y), depth, dug, fell, took, stopped }; the turtle ends where it began, or `back` is false and why.
local function downToTheSea(target, fits, opts)
    local start = T.here()
    local down = { from = start.y, depth = 0, dug = 0, fell = 0, took = 0 }
    local most = opts.depth or DEPTH
    local function short() return turtle.getFuelLevel() < target and fits() end
    -- the shaft: down while it isn't lava
    local surface = false
    while not down.stopped do
        local below = { x = T.pos.x, y = T.pos.y - 1, z = T.pos.z }
        local fuel = turtle.getFuelLevel()
        if fuel ~= "unlimited" and fuel <= (start.y - T.pos.y) + 2 then
            down.stopped = "only fuel enough to come back up"
            break
        end
        if start.y - T.pos.y >= most then
            down.stopped = "went down " .. most .. " blocks (opts.depth) without reaching lava"
            break
        end
        local seen, data = T.look("down")
        local name = seen and type(data) == "table" and data.name or nil
        if name and LAVA[name] and isSource(data) then
            surface = true
            break
        elseif name and not LAVA[name] and not AIRS[name] then
            local area = T.guarded(below.x, below.y, below.z)
            local lq, lx, ly, lz = T.liquidNear(below.x, below.y, below.z)
            if area then
                down.stopped = "protected: " .. area .. " (" .. name .. " at " .. T.posKey(below) .. "): not dug"
            elseif lq and not opts.liquid then
                down.stopped = "digging " .. name .. " at " .. T.posKey(below) .. " would release " .. (LAVA[lq] and "lava" or "water")
                    .. " at " .. lx .. "," .. ly .. "," .. lz .. " (opts.liquid = true digs it anyway)"
            else
                local dug, why = T.digDir("down")
                if dug then down.dug = down.dug + 1
                else down.stopped = "couldn't dig " .. name .. " at " .. T.posKey(below) .. (why and (": " .. tostring(why)) or "") end
            end
        elseif not name then
            down.fell = down.fell + 1                    -- (a cavern: dropping through it)
        end
        if not down.stopped and not turtle.down() then
            local _, now = T.look("down")
            down.stopped = "couldn't go down to " .. T.posKey(below) .. " (" .. tostring(type(now) == "table" and now.name
                or "nothing to dig") .. ")"
        end
        breathe()
    end
    -- the surface: the source under it, then into it and the ones round it, a level at a time
    if surface then
        down.at = T.pos.y - 1
        local levels = 0
        while short() and levels < SEA_LEVELS do
            local took = scoop("down")
            if took ~= "taken" then
                if down.took == 0 then down.stopped = took end
                break
            end
            down.took = down.took + 1
            levels = levels + 1
            if not (short() and turtle.down()) then break end
            for d = 0, 3 do
                if not short() then break end
                local seen, data = T.look(d)
                if seen and isSource(data) then
                    if scoop(d) == "taken" then down.took = down.took + 1 end
                end
            end
            if short() then
                local seen, data = T.look("down")
                if not (seen and isSource(data)) then break end
            end
        end
    end
    -- back up the shaft (digging what fell into it)
    down.depth = start.y - T.pos.y
    while T.pos.y < start.y do
        if not turtle.up() then
            local seen = T.look("up")
            if not (seen and T.digDir("up") and turtle.up()) then
                return down, false, "couldn't come back up the shaft at " .. T.posKey(T.pos)
            end
        end
    end
    return down, true
end

-- Fill the tank from lava the map knows: go to the nearest source, take it up with an empty bucket, burn it, and
-- come back, facing as before.  Returns true, fuel gained, info; false, why, fuel gained, info; nil, why.
--
-- `target` is the fuel level to reach (default the tank's limit); it stops there, or when another bucket would not fit
-- the tank (1000 each), or when no lava source is left to reach.  It needs an empty bucket aboard (a lava bucket aboard
-- is burned first).  The lava comes from the map (T.scan puts it there) within opts.within (default 64) of where it
-- starts: sources it has seen (level 0) first, then cells known by name only (a scan's), each the nearest; a cell is
-- looked at before the bucket goes on it, and one that proves to be flowing, not a source, is passed over, and so is the
-- rest of its column and those beside it (a lava fall).  Lava in a protected area is left (the area T.inside names is
-- the job's), and so is lava in opts.exclude, a list of areas' names and boxes.  In the nether (T.dimension) with no
-- source within reach, it digs straight down to the lava sea (never into a protected area, nor where lava or water would
-- come in: opts.liquid), drops through caverns, takes the sources at its surface and comes back up the shaft; info.down
-- says how: { depth, dug, fell, took, at, stopped }, opts.depth the most it goes down (128).  opts.tries (default 20) is
-- how many lava cells it will try, opts.move is T.moveTo's (default { path = true, scan = false }, never into lava).
-- Info, once it has gone looking, is { tries = { { x, y, z, found } }, beyond (sources past opts.within), columns
-- (cells passed over in a flowing column), down }: each cell tried, in order, and what it found there ("taken",
-- "flowing", "out of reach", "not lava (minecraft:air)", ...); when it comes back short, the why says what the tries
-- that came to nothing found, and where.
function T.refuelFromLava(target, opts)
    opts = opts or {}
    local skip, badExclude = excluded(opts.exclude)
    if not skip then return nil, badExclude end
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
    local within = opts.within or WITHIN
    local from, dir = T.here(), T.dir
    local found, why = T.map.find("minecraft:lava")
    local candidates, left, beyond = {}, 0, 0
    for _, c in ipairs(found or {}) do
        local _, state = T.map.get(c.x, c.y, c.z)
        local lvl = state and state.level ~= nil and tonumber(state.level) or nil
        if lvl == nil or lvl == 0 then
            if T.guarded(c.x, c.y, c.z) or skip(c) then left = left + 1
            elseif T.dist(from, c) > within then beyond = beyond + 1
            else
                c.seen = lvl == 0                        -- (a source it has looked at, before those known by name only)
                candidates[#candidates + 1] = c
            end
        end
    end
    local info = { tries = {}, beyond = beyond, columns = 0 }
    local nether = #candidates == 0 and select(1, T.dimension()) == "nether"
    if not found and not nether then return nil, "the map has no lava to look in: " .. tostring(why) end
    local farText = beyond > 0 and (beyond .. " beyond opts.within (" .. within .. ")") or nil
    if #candidates == 0 and not nether then
        if left > 0 or beyond > 0 then
            local parts = {}
            if left > 0 then parts[#parts + 1] = left .. " protected or excluded" end
            if farText then parts[#parts + 1] = farText end
            return false, "the lava sources the map knows are out of bounds (" .. table.concat(parts, ", ") .. ")", gained(), info
        end
        return false, "the map knows no lava source", gained()
    end
    local tries, stopWhy = opts.tries or 20, nil
    local tried = 0
    local flowingColumns = {}
    local function inFlowing(c) return flowingColumns[c.x .. "," .. c.z] end
    while turtle.getFuelLevel() < target and fits() and #candidates > 0 and tried < tries do
        -- (cells known by name only in a column found flowing are passed over)
        for i = #candidates, 1, -1 do
            if not candidates[i].seen and inFlowing(candidates[i]) then
                table.remove(candidates, i)
                info.columns = info.columns + 1
            end
        end
        if #candidates == 0 then break end
        local best = 1
        for i = 2, #candidates do
            local a, b = candidates[i], candidates[best]
            if a.seen ~= b.seen then
                if a.seen then best = i end
            elseif T.dist(T.pos, a) < T.dist(T.pos, b) then
                best = i
            end
        end
        local c = table.remove(candidates, best)
        tried = tried + 1
        local scooped = false
        local result = "out of reach"                    -- (no stand beside it the turtle could get to)
        for _, s in ipairs(standsFor(c, false)) do
            local ok = T.moveTo(s.x, s.y, s.z, move)
            if ok then
                local d = T.dirTo(c)
                local seen, data = T.look(d)
                if not (seen and type(data) == "table" and LAVA[data.name]) then
                    local name = seen and type(data) == "table" and data.name or AIR
                    T.map.set(c.x, c.y, c.z, name, seen and data.state or nil)
                    result = "not lava (" .. name .. ")"
                elseif data.state and tonumber(data.state.level) ~= 0 then
                    T.map.set(c.x, c.y, c.z, data.name, data.state)
                    result = "flowing"
                    for dx = -1, 1 do
                        for dz = -1, 1 do flowingColumns[(c.x + dx) .. "," .. (c.z + dz)] = true end
                    end
                else
                    local sel = turtle.getSelectedSlot()
                    if T.selectItem(BUCKET) and T.placeDir(d) then
                        scooped, result = true, "taken"
                    else
                        stopWhy, result = "the bucket would not take the lava up at " .. T.posKey(c), "the bucket would not take it up"
                    end
                    turtle.select(sel)
                end
                break
            end
        end
        info.tries[#info.tries + 1] = { x = c.x, y = c.y, z = c.z, found = result }
        if scooped and not burnBucket() then
            info.tries[#info.tries].found = "taken, but it would not burn"
            stopWhy = "took lava up but it would not burn"
            break
        end
    end
    local back, backWhy = reach(from, move)
    T.face(dir)
    if not back then return false, "couldn't get back to " .. T.posKey(from) .. ": " .. tostring(backWhy), gained(), info end
    -- the nether, nothing taken within reach: down to the lava sea, from where it began
    local short = turtle.getFuelLevel() < target and fits()
    if short and not stopWhy and (nether or select(1, T.dimension()) == "nether") then
        local down, home, homeWhy = downToTheSea(target, fits, opts)
        info.down = down
        T.face(dir)
        if not home then return false, homeWhy, gained(), info end
        if turtle.getFuelLevel() >= target or not fits() then return true, gained(), info end
        return false, "went " .. down.depth .. " down for the nether's lava sea and took " .. down.took .. " bucket"
            .. (down.took == 1 and "" or "s") .. ": " .. tostring(down.stopped or "no more sources there"), gained(), info
    end
    local ok = turtle.getFuelLevel() >= target or not fits()
    if ok then return true, gained(), info end
    local whyNot = stopWhy or (#candidates == 0 and "no more lava sources it could reach") or ("gave up after " .. tried .. " tries")
    local said = not stopWhy and triesText(info.tries)
    if said then whyNot = whyNot .. ": " .. said end
    if not stopWhy and info.columns > 0 then whyNot = whyNot .. "; " .. info.columns .. " passed over in columns found flowing" end
    if not stopWhy and farText then whyNot = whyNot .. "; " .. farText end
    return false, whyNot, gained(), info
end

--------------------------------------------------------------------------
-- What a job costs in fuel
--------------------------------------------------------------------------

-- What a scan of radius r costs in fuel: T.cfg.scanFuel[r] if given, nothing up to the free radius, else the one measured
-- cost scaled by volume.
local function scanCost(r)
    local given = type(T.cfg.scanFuel) == "table" and T.cfg.scanFuel[r]
    if given then return given end
    if r <= FREE_RADIUS then return 0 end
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
