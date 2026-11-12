-- path.lua -- routes: a search over the map for a way to a cell, and walking it
--
-- Loaded by turtlelib the first time T.path or T.travel is used (T.moveTo asks for T.travel when a
-- straight run is blocked and opts.path is set).  Cells are the turtle's own (the frame it counts in).
--
-- T.path finds a route: A* in three dimensions over the map (tl.world), with a binary heap.  What a
-- step into a cell costs depends on what the map holds there:
--   known air or water   one move
--   a block it may dig   a move and a dig (opts.dig says what may be dug, as for T.moveTo)
--   a cell never seen    a move and a dig when digging everything is allowed; otherwise a move and a
--                        penalty, so a route through the unseen is possible but the known is preferred
--                        (it is checked as it is walked)
--   a wall               never: a protected area (except the one opts.inside names, and except the empty cells of an
--                        area the route starts or ends in), what opts.avoid lists (lava, fire and doors unless it says
--                        otherwise), a block it may not dig (a chest, bedrock, anything opts.dig leaves out), and any
--                        cell in opts.avoidCells
-- The search reads the map's cubes as strings (string.byte), not as tables of cells, so a big search stays cheap in
-- memory; it gives the rest of the computer a turn about every half second (CC stops code that goes seven seconds
-- without yielding), and gives up past a limit of cells searched, saying so.
--
-- T.travel goes there.  From the map it looks for a clear layer, a height at which the whole way is known to be
-- empty, between the highest floor and the lowest ceiling on the way (the Nether has a roof: a fixed height hits
-- bastion ceilings): up, across, down.  If the map doesn't know enough it scans the route's box first; if there is
-- no layer it uses the search.  Then it walks the route.  A block it didn't expect stops a step: it notes the block
-- in the map and plans again from where it is, a few times.

local T = require("turtlelib")

local UNKNOWN, PASS, DIG, WALL = 0, 1, 2, 3      -- what a cell is to a route
local DIG_COST = 3                                -- a dig costs this much more than a move (a move is 1)
local UNKNOWN_PENALTY = 2                         -- what a cell never seen costs more than a move, if digging is off
local LIMIT = 20000                               -- cells searched, at most (opts.limit)
local MARGIN = 24                                 -- how far outside the box of the two cells a search may go (opts.margin)
local YIELD_EVERY = 0.5                           -- seconds of work before giving the computer a turn
local LAYER_SPAN = 8                              -- how far above the higher end a layer may be (opts.span)
local REPLANS = 6                                 -- times travel plans again after an unexpected block (opts.replans)
local TIE = 0.001                                 -- (a hair of weight on the guess: straight lines first among equals)
local CUBE = 16
local OFF, SPAN = 32768, 65536                    -- a cell's number: ((x + OFF) * SPAN + z + OFF) * SPAN + y + OFF
local STEP = { SPAN * SPAN, -SPAN * SPAN, SPAN, -SPAN, 1, -1 }                  -- the number's change for +x -x +z -z +y -y
local STEP_XYZ = { { 1, 0, 0 }, { -1, 0, 0 }, { 0, 0, 1 }, { 0, 0, -1 }, { 0, 1, 0 }, { 0, -1, 0 } }
local AIR = "minecraft:air"

-- Blocks a turtle moves through without digging
local PASSABLE = {
    [AIR] = true, ["minecraft:cave_air"] = true, ["minecraft:void_air"] = true,
    ["minecraft:water"] = true, ["minecraft:flowing_water"] = true, ["minecraft:bubble_column"] = true,
    ["minecraft:lava"] = true, ["minecraft:flowing_lava"] = true,
}

-- Blocks no turtle can dig
local UNBREAKABLE = {
    ["minecraft:bedrock"] = true, ["minecraft:barrier"] = true, ["minecraft:end_portal_frame"] = true,
    ["minecraft:end_portal"] = true, ["minecraft:end_gateway"] = true, ["minecraft:command_block"] = true,
    ["minecraft:chain_command_block"] = true, ["minecraft:repeating_command_block"] = true,
    ["minecraft:structure_block"] = true, ["minecraft:jigsaw"] = true, ["minecraft:reinforced_deepslate"] = true,
}

-- The time since the last turn given to the rest of the computer
local lastYield = os.clock()

-- Give the rest of the computer a turn when this has run for a while.
local function breathe()
    local t = os.clock()
    if t - lastYield > YIELD_EVERY then
        sleep(0)
        lastYield = os.clock()
    end
end

local function whole(n) return type(n) == "number" and n == math.floor(n) end

-- The number of the cell x, y, z (whole numbers within 32768 of the origin).
local function idOf(x, y, z) return ((x + OFF) * SPAN + (z + OFF)) * SPAN + (y + OFF) end

-- The cell a number stands for: x, y, z.
local function cellOf(id)
    local y = id % SPAN
    local rest = math.floor(id / SPAN)
    local z = rest % SPAN
    return math.floor(rest / SPAN) - OFF, y - OFF, z - OFF
end

--------------------------------------------------------------------------
-- What the map says, read for a search
--------------------------------------------------------------------------

-- The world a search reads, for the rules in opts and the two ends of the route (turtle frame).
--
-- The search runs in the map's frame (a shift and quarter turns from the turtle's, so axes line up); an unaligned map is
-- no use, and every cell it holds counts as never seen.  cls(x, y, z) gives a cell's class; toS and fromS convert.
local function newWorld(opts, from, to)
    lastYield = os.clock()
    local map = T.map
    local aligned = map.frame().aligned
    local toS, fromS = map.toMap, map.fromMap
    if not aligned then
        toS = function(x, y, z) return x, y, z end
        fromS = toS
    end
    local mayDig = T.nameTest(opts.dig)
    local avoid = T.nameTest(opts.avoid == nil and T.DEFAULT_AVOID or opts.avoid)
    local containers = T.cfg.digContainers
    local memo = {}
    -- what a block is to a route
    local function nameClass(name)
        local c = memo[name]
        if c then return c end
        if avoid(name) then c = WALL
        elseif PASSABLE[name] then c = PASS
        elseif UNBREAKABLE[name] or (T.neverDig(name) and not containers) then c = WALL
        elseif mayDig(name) then c = DIG
        else c = WALL end
        memo[name] = c
        return c
    end
    -- the cubes the map holds, as bytes with a class for each code
    local cubes = {}
    local function cubeAt(cx, cy, cz)
        local key = ((cx + 2048) * 4096 + (cy + 2048)) * 4096 + (cz + 2048)
        local c = cubes[key]
        if c == nil then
            local data, pal = map.cube(cx, cy, cz)
            c = false
            if data then
                local classes = { [0] = UNKNOWN, [1] = PASS }
                for i, name in ipairs(pal) do classes[i + 1] = nameClass(name) end
                c = { data = data, classes = classes, pal = pal }
            end
            cubes[key] = c
        end
        return c
    end
    local floor, byte = math.floor, string.byte
    local function baseClass(mx, my, mz)
        if not aligned then return UNKNOWN end
        local cx, cy, cz = floor(mx / CUBE), floor(my / CUBE), floor(mz / CUBE)
        local c = cubeAt(cx, cy, cz)
        if not c then return UNKNOWN end
        local code = byte(c.data, ((my - cy * CUBE) * CUBE + (mz - cz * CUBE)) * CUBE + (mx - cx * CUBE) + 1)
        return c.classes[code] or UNKNOWN
    end
    -- the cells a route may not use
    local banned, anyBanned = {}, false
    for _, cell in ipairs(opts.avoidCells or {}) do
        if type(cell) == "table" and whole(cell.x) and whole(cell.y) and whole(cell.z) then
            banned[idOf(toS(cell.x, cell.y, cell.z))] = true
            anyBanned = true
        end
    end
    -- the protected areas, as boxes of this frame; one the route starts or ends in is open to empty cells
    local sx, sy, sz = toS(from.x, from.y, from.z)
    local gx, gy, gz = toS(to.x, to.y, to.z)
    local boxes = {}
    local inside = opts.inside or T.cfg.inside
    for _, a in ipairs(T.protections()) do
        if a.name ~= inside then
            local ax, ay, az = toS(a.x1, a.y1, a.z1)
            local bx, by, bz = toS(a.x2, a.y2, a.z2)
            local box = { math.min(ax, bx), math.min(ay, by), math.min(az, bz), math.max(ax, bx), math.max(ay, by),
                          math.max(az, bz), name = a.name }
            local function holds(x, y, z)
                return x >= box[1] and x <= box[4] and y >= box[2] and y <= box[5] and z >= box[3] and z <= box[6]
            end
            box.open = holds(sx, sy, sz) or holds(gx, gy, gz)
            boxes[#boxes + 1] = box
        end
    end
    local w = { toS = toS, fromS = fromS, dig = opts.dig, boxes = boxes }
    -- A cell's class: unknown, pass, dig or wall.
    function w.cls(mx, my, mz)
        if anyBanned and banned[idOf(mx, my, mz)] then return WALL end
        local c = baseClass(mx, my, mz)
        for i = 1, #boxes do
            local b = boxes[i]
            if mx >= b[1] and mx <= b[4] and my >= b[2] and my <= b[5] and mz >= b[3] and mz <= b[6] then
                if b.open and c == PASS then return PASS end
                return WALL
            end
        end
        return c
    end
    -- Why a cell is a wall, in words: the protected area, the cell banned, or the block.
    function w.why(mx, my, mz)
        if anyBanned and banned[idOf(mx, my, mz)] then return "a cell it was asked to keep out of" end
        for _, b in ipairs(boxes) do
            if mx >= b[1] and mx <= b[4] and my >= b[2] and my <= b[5] and mz >= b[3] and mz <= b[6] then
                return "inside the protected area " .. b.name
            end
        end
        if aligned then
            local cx, cy, cz = floor(mx / CUBE), floor(my / CUBE), floor(mz / CUBE)
            local c = cubeAt(cx, cy, cz)
            if c then
                local code = byte(c.data, ((my - cy * CUBE) * CUBE + (mz - cz * CUBE)) * CUBE + (mx - cx * CUBE) + 1)
                local name = code == 1 and AIR or c.pal[code - 1]
                if name then return name .. ", which a route here may not enter" end
            end
        end
        return "a cell it may not enter"
    end
    return w
end

-- Whole-number cell from a table { x, y, z }, or nil and why.
local function cellArg(c, what)
    if type(c) ~= "table" or not (whole(c.x) and whole(c.y) and whole(c.z)) then
        return nil, what .. " is a cell of whole numbers: { x = , y = , z = }"
    end
    return c
end

--------------------------------------------------------------------------
-- The search
--------------------------------------------------------------------------

-- A* from (sx, sy, sz) to (gx, gy, gz) in the world's frame: the route as a list of cells after the first, up to and
-- including the last, and an info table { nodes, cost, digs, unknown }; or nil and why.
local function astar(w, sx, sy, sz, gx, gy, gz, limit, margin)
    local cls = w.cls
    local sid, gid = idOf(sx, sy, sz), idOf(gx, gy, gz)
    if sid == gid then return {}, { nodes = 0, cost = 0, digs = 0, unknown = 0 } end
    local x1, x2 = math.min(sx, gx) - margin, math.max(sx, gx) + margin
    local y1, y2 = math.min(sy, gy) - margin, math.max(sy, gy) + margin
    local z1, z2 = math.min(sz, gz) - margin, math.max(sz, gz) + margin
    local cost = { [PASS] = 1, [DIG] = 1 + DIG_COST, [UNKNOWN] = w.dig == true and 1 + DIG_COST or 1 + UNKNOWN_PENALTY }
    local g, parent, closed = { [sid] = 0 }, {}, {}
    -- the open set: a binary heap of cell numbers by priority
    local hp, hv, hn = {}, {}, 0
    local function push(p, v)
        hn = hn + 1
        local i = hn
        while i > 1 do
            local up = math.floor(i / 2)
            if hp[up] <= p then break end
            hp[i], hv[i] = hp[up], hv[up]
            i = up
        end
        hp[i], hv[i] = p, v
    end
    local function pop()
        local top = hv[1]
        local p, v = hp[hn], hv[hn]
        hp[hn], hv[hn] = nil, nil
        hn = hn - 1
        if hn > 0 then
            local i = 1
            while true do
                local c = i * 2
                if c > hn then break end
                if c < hn and hp[c + 1] < hp[c] then c = c + 1 end
                if hp[c] >= p then break end
                hp[i], hv[i] = hp[c], hv[c]
                i = c
            end
            hp[i], hv[i] = p, v
        end
        return top
    end
    push(0, sid)
    local nodes = 0
    lastYield = os.clock()
    while hn > 0 do
        local id = pop()
        if not closed[id] then
            closed[id] = true
            if id == gid then
                local route, digs, unknown = {}, 0, 0
                local at = id
                while at ~= sid do
                    local x, y, z = cellOf(at)
                    table.insert(route, 1, { x = x, y = y, z = z })
                    local c = cls(x, y, z)
                    if c == DIG then digs = digs + 1 elseif c == UNKNOWN then unknown = unknown + 1 end
                    at = parent[at]
                end
                return route, { nodes = nodes, cost = g[gid], digs = digs, unknown = unknown }
            end
            nodes = nodes + 1
            if nodes > limit then
                return nil, "no route: gave up after searching " .. limit .. " cells without reaching it (opts.limit raises that)"
            end
            if nodes % 32 == 0 then breathe() end
            local x, y, z = cellOf(id)
            for i = 1, 6 do
                local nid = id + STEP[i]
                if not closed[nid] then
                    local d = STEP_XYZ[i]
                    local nx, ny, nz = x + d[1], y + d[2], z + d[3]
                    if nx >= x1 and nx <= x2 and ny >= y1 and ny <= y2 and nz >= z1 and nz <= z2 then
                        local c = cls(nx, ny, nz)
                        if c ~= WALL then
                            local ng = g[id] + cost[c]
                            if ng < (g[nid] or math.huge) then
                                g[nid], parent[nid] = ng, id
                                push(ng + (math.abs(gx - nx) + math.abs(gy - ny) + math.abs(gz - nz)) * (1 + TIE), nid)
                            end
                        end
                    end
                end
            end
        end
    end
    return nil, "no route: every way is walled off (searched " .. nodes .. " cells within " .. margin .. " of the two ends)"
end

-- The route from `from` to `to` (turtle frame cells), planned: list, info | nil, why.  `from` is where the turtle is
-- unless opts.from says otherwise.
local function plan(from, to, opts)
    local w = newWorld(opts, from, to)
    local sx, sy, sz = w.toS(from.x, from.y, from.z)
    local gx, gy, gz = w.toS(to.x, to.y, to.z)
    if w.cls(gx, gy, gz) == WALL then
        return nil, "no route: the goal " .. to.x .. "," .. to.y .. "," .. to.z .. " is " .. w.why(gx, gy, gz)
    end
    local route, info = astar(w, sx, sy, sz, gx, gy, gz, opts.limit or LIMIT, opts.margin or MARGIN)
    if not route then return nil, info end
    for i, c in ipairs(route) do
        local x, y, z = w.fromS(c.x, c.y, c.z)
        route[i] = { x = x, y = y, z = z }
    end
    return route, info
end

-- A route to the cell x, y, z through the map: a list of cells to step into, one after another, the last being the goal (empty when already there); nil and why if there is none.
--
-- It starts from where the turtle is (opts.from = { x, y, z } to plan from elsewhere).  The costs and the walls are in the
-- overview of this module.  A second result gives { nodes, cost, digs, unknown }: how many cells the search
-- looked at, the route's cost, and how many of its cells need a dig or were never seen.  Nothing moves.  opts (all optional):
--   dig        false (default), true, a glob or a list of globs: what a route may dig (as for T.moveTo)
--   avoid      a glob or a list: blocks a route stays out of (default: lava, fire and doors; {} avoids nothing)
--   inside     the name of a protected area the route may dig in (default T.cfg.inside, see T.inside)
--   avoidCells a list of { x, y, z } cells a route may not use
--   limit      cells to search before giving up (default 20000)
--   margin     how far outside the box of the two cells it may look (default 24)
function T.path(x, y, z, opts)
    opts = opts or {}
    for _, n in ipairs({ x, y, z }) do
        if not whole(n) then return nil, "path wants a cell of whole numbers: x, y, z" end
    end
    local from, why = cellArg(opts.from or T.here(), "opts.from")
    if not from then return nil, why end
    return plan(from, { x = x, y = y, z = z }, opts)
end

--------------------------------------------------------------------------
-- A clear layer
--------------------------------------------------------------------------

-- Cells from (x, y, z) toward (tx, ty, tz) along one axis, after the first, added to the list in the world's frame.
local function addLine(list, x, y, z, tx, ty, tz)
    local dx, dy, dz = tx > x and 1 or -1, ty > y and 1 or -1, tz > z and 1 or -1
    while x ~= tx do x = x + dx; list[#list + 1] = { x = x, y = y, z = z } end
    while z ~= tz do z = z + dz; list[#list + 1] = { x = x, y = y, z = z } end
    while y ~= ty do y = y + dy; list[#list + 1] = { x = x, y = y, z = z } end
end

-- The route up, across and down at the height y: x first or z first; nil if the map doesn't show every cell empty.
-- A second result says whether a cell never seen was what stopped it.
local function layerAt(w, sx, sy, sz, gx, gy, gz, y, xFirst)
    local list = {}
    addLine(list, sx, sy, sz, sx, y, sz)
    if xFirst then
        addLine(list, sx, y, sz, gx, y, sz)
        addLine(list, gx, y, sz, gx, y, gz)
    else
        addLine(list, sx, y, sz, sx, y, gz)
        addLine(list, sx, y, gz, gx, y, gz)
    end
    addLine(list, gx, y, gz, gx, gy, gz)
    for i, c in ipairs(list) do
        local k = w.cls(c.x, c.y, c.z)
        if k ~= PASS then return nil, k == UNKNOWN end
        if i % 64 == 0 then breathe() end
    end
    return list, false
end

-- The route at the best clear height: the heights from the lower end to `span` above the higher, the least climbing first (the
-- higher on a tie).  The route as a list in the world's frame, or nil, and whether any height was only unknown.
local function layerRoute(w, sx, sy, sz, gx, gy, gz, span)
    local heights = {}
    for y = math.min(sy, gy), math.max(sy, gy) + span do heights[#heights + 1] = y end
    table.sort(heights, function(a, b)
        local ca, cb = math.abs(sy - a) + math.abs(gy - a), math.abs(sy - b) + math.abs(gy - b)
        if ca ~= cb then return ca < cb end
        return a > b
    end)
    local sawUnknown = false
    for _, y in ipairs(heights) do
        for _, xFirst in ipairs({ true, false }) do
            local list, unknown = layerAt(w, sx, sy, sz, gx, gy, gz, y, xFirst)
            if list then return list, false end
            sawUnknown = sawUnknown or unknown
            if sx == gx or sz == gz then break end
        end
    end
    return nil, sawUnknown
end

--------------------------------------------------------------------------
-- Walking a route
--------------------------------------------------------------------------

-- Walk a route of cells (turtle frame) from where the turtle is: T.moveTo for each straight stretch.  True, or
-- false, why, the block's name and its cell, as T.moveTo says.
local function walk(route, moveOpts)
    local i = 1
    while i <= #route do
        local from = i == 1 and T.pos or route[i - 1]
        local c = route[i]
        local dx, dy, dz = c.x - from.x, c.y - from.y, c.z - from.z
        local j = i
        while route[j + 1] and route[j + 1].x - route[j].x == dx and route[j + 1].y - route[j].y == dy
              and route[j + 1].z - route[j].z == dz do
            j = j + 1
        end
        local ok, why, name, cell = T.moveTo(route[j].x, route[j].y, route[j].z, moveOpts)
        if not ok then return false, why, name, cell end
        i = j + 1
    end
    return true
end

-- The box of the turtle's frame a route between two cells looks through, for a scan before the layer is looked for.
local function routeBox(from, to, span)
    return { math.min(from.x, to.x), math.min(from.y, to.y), math.min(from.z, to.z),
             math.max(from.x, to.x), math.max(from.y, to.y) + span, math.max(from.z, to.z) }
end

-- Go to the cell x, y, z by the map: along a clear layer if there is one, else by a search; true, or false and why.
--
-- Up, across and down at a height where the map shows the whole way empty (the lowest climb first); if the map
-- doesn't know enough to find one it scans the route's box first (T.scanBox, once; opts.scan = false skips that); with no
-- layer, T.path's search.  Each stretch is walked with T.moveTo.  A block it did not expect stops a step: the block is
-- noted in the map, the cell is kept out of the next plan, and it plans again from where it is, up to opts.replans
-- times (default 6).  opts are T.path's (dig, avoid, inside, avoidCells, limit, margin), plus span (how far above the
-- higher end a layer may be, default 8), scan, replans, and scanning's opts.move.  On failure the turtle stays where it got to.
function T.travel(x, y, z, opts)
    opts = opts or {}
    for _, n in ipairs({ x, y, z }) do
        if not whole(n) then return false, "travel wants a cell of whole numbers: x, y, z" end
    end
    local goal = { x = x, y = y, z = z }
    if T.pos.x == x and T.pos.y == y and T.pos.z == z then return true end
    local banned = {}
    for _, c in ipairs(opts.avoidCells or {}) do banned[#banned + 1] = c end
    local ruleOpts = { dig = opts.dig, avoid = opts.avoid, inside = opts.inside, limit = opts.limit, margin = opts.margin,
                       avoidCells = banned }
    local moveOpts = { dig = opts.dig, avoid = opts.avoid, inside = opts.inside, path = false }
    local here = T.here()
    -- the first route: a layer, scanning for it if the map doesn't know
    local route
    local w = newWorld(ruleOpts, here, goal)
    local sx, sy, sz = w.toS(here.x, here.y, here.z)
    local gx, gy, gz = w.toS(goal.x, goal.y, goal.z)
    local span = opts.span or LAYER_SPAN
    if w.cls(gx, gy, gz) ~= WALL then
        local list, unknown = layerRoute(w, sx, sy, sz, gx, gy, gz, span)
        if not list and unknown and opts.scan ~= false then
            -- (a scan that fails, for any reason, leaves the search to take over; Ctrl+T still stops it)
            local scanned, err = pcall(T.scanBox, routeBox(here, goal, span), { move = opts.move or moveOpts })
            if not scanned and tostring(err) == "Terminated" then error(err, 0) end
            w = newWorld(ruleOpts, T.here(), goal)
            here = T.here()
            sx, sy, sz = w.toS(here.x, here.y, here.z)
            list = layerRoute(w, sx, sy, sz, gx, gy, gz, span)
        end
        if list then
            route = {}
            for i, c in ipairs(list) do
                local rx, ry, rz = w.fromS(c.x, c.y, c.z)
                route[i] = { x = rx, y = ry, z = rz }
            end
        end
    end
    local why
    if not route then
        route, why = plan(T.here(), goal, ruleOpts)
        if not route then return false, why end
    end
    local replans = opts.replans or REPLANS
    local last
    for attempt = 0, replans do
        local ok, stopped, name, cell = walk(route, moveOpts)
        if ok then
            if T.pos.x == x and T.pos.y == y and T.pos.z == z then return true end
            return false, "stopped short of " .. x .. "," .. y .. "," .. z .. " at " .. T.posString()
        end
        last = stopped
        -- a stop with no cell of its own (or at the turtle: out of fuel) is not the map's to fix
        if not cell or (not name and cell.x == T.pos.x and cell.y == T.pos.y and cell.z == T.pos.z) then
            return false, stopped
        end
        if attempt == replans then break end
        if name and T.map then pcall(T.map.set, cell.x, cell.y, cell.z, name) end
        banned[#banned + 1] = { x = cell.x, y = cell.y, z = cell.z }
        local fresh, noRoute = plan(T.here(), goal, ruleOpts)
        if not fresh then return false, stopped .. " (no route round: " .. tostring(noRoute) .. ")" end
        route = fresh
    end
    return false, "gave up after " .. replans .. " re-plans: " .. tostring(last)
end

return true
