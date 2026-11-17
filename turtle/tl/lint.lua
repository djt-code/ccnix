-- lint.lua -- a build as a two-tall player meets it: warnings about its stairs, railings, drops and lanterns
--
-- Loaded by turtlelib the first time T.lint is used.  Cells are the turtle's own (the frame it counts in).
--
-- The turtle is one block tall and the player two (1.8, stepping up a block at most), so a build the turtle gets
-- round can still stop a player.  T.lint reads a build from the map, or a plan's own cells with the map round them,
-- and warns; it never refuses, since a player's own design may break a rule on purpose.  The rules:
--   headroom  a stair walked up needs 3 air above it: the body rises half a block onto the next step while the head
--             is still over this one (the top stair of a flight needs only 2 when the way off it is level)
--   approach  the cell in front of a flight's first stair needs a floor and 3 air (the step up starts there)
--   exit      the cell beyond a flight's last stair needs a floor at the stair's top and 2 air: not a wall, not an edge
--   railing   two railings (fences, walls, panes, bars, gates) that meet only on a diagonal, level or a block apart in
--             height, don't join: a player slips between them; a railing or a block in either cell between closes it
--   drop      a walk cell (2 air over a floor) with an open side over a drop of more than 3, and no railing there
--   lantern   a lantern at head height over a walk cell: a player walks into it
-- A stair goes by its state (facing, half), which the map has only for blocks that were inspected (T.inspectAll,
-- T.verify; a scan gives names alone), and its compass facing needs the world origin: a stair without them is
-- counted as unchecked and only its headroom is looked at.  A cell the map has never seen breaks no rule.

local T = require("turtlelib")

local LIMIT = 50                  -- warnings listed at most (opts.limit); the rest are counted
local MAX_CELLS = 65536           -- the biggest box a lint reads
local SAFE_FALL = 3               -- the most a player falls without a railing being wanted
local DEEP = 64                   -- how far down a drop is measured
-- The rules in the order the warnings come
local RULES = { "headroom", "approach", "exit", "railing", "drop", "lantern" }
local COMPASS_AT = { north = 0, east = 1, south = 2, west = 3 }

-- What a block is to a player, by kind.  pass: the body goes through it; floor: a player stands on it; height: its
-- top in half blocks
local KINDS = {
    open    = { pass = true },                       -- air, torches, signs, carpets, doors, ...
    ladder  = { pass = true, climb = true },
    water   = { pass = true, soft = true },          -- a fall into it does no harm
    hot     = { pass = true, hot = true },           -- lava and fire
    gate    = { pass = true, rail = true },          -- a player opens it; shut, it is part of a railing
    railing = { rail = true, height = 3 },           -- 1.5 high: nobody steps up onto one
    lantern = { lantern = true, height = 1 },
    stairs  = { floor = true, stairs = true, height = 2 },
    slab    = { floor = true, slab = true, height = 1 },   -- a bottom slab (a top or double one is a full block)
    solid   = { floor = true, height = 2 },          -- anything else
}
-- Block names to kinds, the first that matches winning (a name without a namespace matches any mod's)
local NAMES = {
    { "ladder", { "ladder" } },
    { "water", { "water", "flowing_water", "bubble_column" } },
    { "hot", { "lava", "flowing_lava", "fire", "soul_fire" } },
    { "lantern", { "lantern", "soul_lantern", "*copper_lantern" } },
    { "gate", { "*_fence_gate" } },
    { "railing", { "*_fence", "*_wall", "*_pane", "*bars" } },
    { "open", { "*air", "light", "*torch", "*_sign", "*_button", "lever", "*_pressure_plate", "*_carpet", "*rail",
                "short_grass", "tall_grass", "grass", "fern", "large_fern", "dead_bush", "vine", "snow", "redstone_wire",
                "tripwire", "*_door", "*_trapdoor", "*_banner" } },
    { "stairs", { "*_stairs" } },
    { "slab", { "*_slab" } },
}
local TESTS = {}
for i, row in ipairs(NAMES) do TESTS[i] = { kind = row[1], test = T.nameTest(row[2]) } end

-- Two railings on a diagonal, and the two cells between them (offsets from the first, the lower one); the second
-- cell between is where a railing closes the gap best (on top of the lower post, for a stepped one)
local DIAGONALS = {
    { to = { 1, 0, 1 }, between = { { 0, 0, 1 }, { 1, 0, 0 } } },
    { to = { 1, 0, -1 }, between = { { 0, 0, -1 }, { 1, 0, 0 } } },
    { to = { 1, 1, 0 }, between = { { 1, 0, 0 }, { 0, 1, 0 } } },
    { to = { -1, 1, 0 }, between = { { -1, 0, 0 }, { 0, 1, 0 } } },
    { to = { 0, 1, 1 }, between = { { 0, 0, 1 }, { 0, 1, 0 } } },
    { to = { 0, 1, -1 }, between = { { 0, 0, -1 }, { 0, 1, 0 } } },
}

local S = { lastYield = 0 }

-- Give the rest of the computer a turn when this has run for a while.
local function breathe()
    local t = os.clock()
    if t - S.lastYield > 0.4 then
        S.lastYield = t
        sleep(0)
    end
end

local function whole(n) return type(n) == "number" and n == math.floor(n) end
local function key(x, y, z) return x .. "," .. y .. "," .. z end

-- The kind of a block, by name (worked out once a name).
local kindCache = {}
local function kindOf(name)
    local kind = kindCache[name]
    if not kind then
        kind = "solid"
        for _, t in ipairs(TESTS) do
            if t.test(name) then kind = t.kind; break end
        end
        kindCache[name] = kind
    end
    return KINDS[kind]
end

-- How high a block's top is, in half blocks.
local function heightOf(c)
    if c.kind.slab and c.state and (c.state.type == "top" or c.state.type == "double") then return 2 end
    return c.kind.height or 0
end

-- A view of the world: cell(x, y, z) -> { kind, name, state }, or nil for a cell never seen.  read(x, y, z) gives
-- a name and state, or nil; each cell is read once.
local function newView(read)
    local memo = {}
    return function(x, y, z)
        local k = key(x, y, z)
        local c = memo[k]
        if c == nil then
            local name, state = read(x, y, z)
            if type(name) == "string" then
                c = { kind = kindOf(name), name = name, state = type(state) == "table" and state or nil }
            else
                c = false
            end
            memo[k] = c
        end
        return c or nil
    end
end

local function mapRead(x, y, z) return T.map.get(x, y, z) end

-- The view and the box for a box or a plan: view, x1, y1, z1, x2, y2, z2; or nil and why.
local function viewOf(what)
    if type(what) == "table" and (what.x1 ~= nil or type(what[1]) == "number") then
        local v = what
        if what.x1 ~= nil then v = { what.x1, what.y1, what.z1, what.x2, what.y2, what.z2 } end
        for i = 1, 6 do
            if not whole(v[i]) then return nil, "a box is { x1, y1, z1, x2, y2, z2 }, whole numbers" end
        end
        return newView(mapRead), math.min(v[1], v[4]), math.min(v[2], v[5]), math.min(v[3], v[6]),
            math.max(v[1], v[4]), math.max(v[2], v[5]), math.max(v[3], v[6])
    end
    if type(what) == "string" or (type(what) == "table" and what.layers ~= nil) then
        local bp = T.blueprint
        local plan, why = bp.new(what)
        if not plan then return nil, why end
        -- (the plan's own cells; the map for those it leaves alone and round it)
        return newView(function(x, y, z)
            local name, state = bp.at(plan, x, y, z)
            if name then return name, state end
            return mapRead(x, y, z)
        end), bp.extent(plan)
    end
    return nil, "lint wants a box { x1, y1, z1, x2, y2, z2 } or a plan"
end

--------------------------------------------------------------------------
-- Stairs
--------------------------------------------------------------------------

-- The stair at a cell if it is one a player walks on (not upside down, air over it), else nil.
local function walkStair(view, x, y, z)
    local c = view(x, y, z)
    if not (c and c.kind.stairs) or (c.state and c.state.half == "top") then return nil end
    local above = view(x, y + 1, z)
    if not (above and above.kind.pass) then return nil end
    return c
end

-- The way a stair's flight goes up, as a step { dx, 0, dz } of the turtle's frame; nil without a facing or an origin.
local function upOf(c, base)
    local f = c.state and COMPASS_AT[c.state.facing]
    if not (f and base) then return nil end
    return T.DELTA[(f - base) % 4]
end

-- Headroom over the stair at x, y, z: `need` air.
local function headroom(view, warn, x, y, z, need)
    for k = 2, need do        -- (the cell right over it is air: that makes it a stair walked on)
        local c = view(x, y + k, z)
        if not c then return end
        if not c.kind.pass then
            warn("headroom", x, y, z, "the stair has " .. (k - 1) .. " air above it; a two-tall player walking up needs " .. need
                .. " (" .. c.name .. " at " .. key(x, y + k, z) .. ")")
            return
        end
    end
end

-- The approach to the first stair of a flight, at x, y, z, going up the step (dx, dz).
local function approach(view, warn, x, y, z, dx, dz)
    local ax, az = x - dx, z - dz
    for k = 1, 2 do
        local c = view(ax, y + k, az)
        if not c then return end
        if not c.kind.pass then
            warn("approach", x, y, z, "the first stair of a flight has no free approach: " .. c.name .. " at " .. key(ax, y + k, az)
                .. " is in the way (a player needs a floor and 3 air in front of the first stair)")
            return
        end
    end
    local feet = view(ax, y, az)
    if not feet then return end
    if not feet.kind.pass and not feet.kind.floor then
        warn("approach", x, y, z, "the first stair of a flight has no free approach: " .. feet.name .. " at " .. key(ax, y, az) .. " is in the way")
    elseif feet.kind.pass then
        local floor = view(ax, y - 1, az)
        if floor and floor.kind.pass then
            warn("approach", x, y, z, "the cell in front of the first stair, " .. key(ax, y, az) .. ", has no floor")
        end
    end
end

-- The exit from the last stair of a flight, at x, y, z, going up the step (dx, dz).  Returns the headroom the stair
-- needs: 2 for a level way off it, else 3.
local function exit(view, warn, x, y, z, dx, dz)
    local ex, ez = x + dx, z + dz
    local feet, head = view(ex, y + 1, ez), view(ex, y + 2, ez)
    if not (feet and head) then return 3 end
    if feet.kind.pass then
        if not head.kind.pass then
            warn("exit", x, y, z, "beyond the last stair of the flight, " .. head.name .. " at " .. key(ex, y + 2, ez) .. " is at head height")
            return 3
        end
        local floor = view(ex, y, ez)
        if floor and floor.kind.pass then
            warn("exit", x, y, z, "the flight runs out over an edge: no floor beyond its last stair, under " .. key(ex, y + 1, ez))
        end
        return 2
    end
    -- (a half step up, or the next flight turning, goes on; anything else is a wall)
    if not ((feet.kind.slab and heightOf(feet) == 1) or walkStair(view, ex, y + 1, ez)) then
        warn("exit", x, y, z, "the flight runs into " .. feet.name .. " at " .. key(ex, y + 1, ez) .. ": a player needs a landing beyond the last stair")
    end
    return 3
end

-- The rules for the stair c at x, y, z.
local function checkStair(view, warn, info, base, x, y, z, c)
    local up = upOf(c, base)
    if not up then
        info.unchecked = info.unchecked + 1
        headroom(view, warn, x, y, z, 3)
        return
    end
    local dx, dz = up[1], up[3]
    local function inFlight(nx, ny, nz)
        local n = walkStair(view, nx, ny, nz)
        return n ~= nil and n.state ~= nil and n.state.facing == c.state.facing
    end
    local need = 3
    if not inFlight(x - dx, y - 1, z - dz) then approach(view, warn, x, y, z, dx, dz) end
    if not inFlight(x + dx, y + 1, z + dz) then need = exit(view, warn, x, y, z, dx, dz) end
    headroom(view, warn, x, y, z, need)
end

--------------------------------------------------------------------------
-- Railings, drops and lanterns
--------------------------------------------------------------------------

-- Is a cell open between two railings (known, the body goes through, not a railing itself)?
local function gapAt(view, x, y, z)
    local c = view(x, y, z)
    return c ~= nil and c.kind.pass and not c.kind.rail
end

-- The railing at x, y, z and those on a diagonal from it, each pair once.
local function checkRailing(view, warn, x, y, z)
    for _, d in ipairs(DIAGONALS) do
        local px, py, pz = x + d.to[1], y + d.to[2], z + d.to[3]
        local other = view(px, py, pz)
        if other and other.kind.rail then
            local a, b = d.between[1], d.between[2]
            if gapAt(view, x + a[1], y + a[2], z + a[3]) and gapAt(view, x + b[1], y + b[2], z + b[3]) then
                warn("railing", x, y, z, "the railings at " .. key(x, y, z) .. " and " .. key(px, py, pz) .. " meet only on a diagonal, "
                    .. "so they don't join: a player slips between them (a railing at " .. key(x + b[1], y + b[2], z + b[3]) .. " closes it)")
            end
        end
    end
end

-- How far a player falls from x, y, z down (the cells it passes through, stopping at a floor, water or a ladder), and
-- whether the bottom was found.
local function fallFrom(view, x, y, z)
    local depth = 0
    while depth < DEEP do
        local c = view(x, y - depth, z)
        if not c then return depth, false end
        if not c.kind.pass or c.kind.soft or c.kind.climb then return depth, true end
        depth = depth + 1
    end
    return depth, false
end

-- The rules for a walk cell: feet at x, y, z (passable, over a floor).
local function checkWalk(view, warn, x, y, z)
    local head = view(x, y + 1, z)
    if not head then return end
    if head.kind.lantern then
        warn("lantern", x, y, z, "the " .. head.name .. " at " .. key(x, y + 1, z) .. " hangs at head height over this walk cell: "
            .. "a player walks into it (hang it a block higher)")
        return
    end
    if not head.kind.pass then return end
    for h = 0, 3 do
        local d = T.DELTA[h]
        local nx, nz = x + d[1], z + d[3]
        if gapAt(view, nx, y, nz) and gapAt(view, nx, y + 1, nz) then
            local depth, found = fallFrom(view, nx, y - 1, nz)
            if depth > SAFE_FALL then
                warn("drop", x, y, z, "an open side at " .. key(nx, y, nz) .. " with a drop of " .. (found and "" or "at least ") .. depth
                    .. " below it and no railing: a player can fall")
                return
            end
        end
    end
end

--------------------------------------------------------------------------
-- The lint
--------------------------------------------------------------------------

-- What stops a two-tall player in a build (a box or a plan), read-only: headroom over stairs, a flight's approach and
-- exit, railings meeting on a diagonal, drops over 3, lanterns at head height.  A list of { rule, x, y, z, text }, and info.
--
-- `what` is a box of the map ({ x1, y1, z1, x2, y2, z2 }, or the fields) or a plan (as T.build takes one: its own
-- cells and states, the map for the cells it leaves alone and round it).  The cells looked at are the box's and,
-- for walking on its top, the layer over it; the cells round them (an approach, a drop) are read too.  A warning is
-- { rule, x, y, z, text }: rule is headroom, approach, exit, railing, drop or lantern (see the overview), x, y, z the
-- cell (the stair, the railing or the walk cell), text says it in plain words with the cells involved.  Warnings, not
-- refusals: a design may break a rule on purpose.  Nil and why if it can't start.  Info is { cells, unchecked (stairs
-- with no facing in the map or no origin: only their headroom looked at), more (warnings past opts.limit, default 50),
-- rules (a count by rule), summary (a line a rule: its first warning, and how many more) }.
function T.lint(what, opts)
    opts = opts or {}
    local view, x1, y1, z1, x2, y2, z2 = viewOf(what)
    if not view then return nil, x1 end
    local cells = (x2 - x1 + 1) * (y2 - y1 + 1) * (z2 - z1 + 1)
    if cells > MAX_CELLS then return nil, "the box is " .. cells .. " cells; a lint reads " .. MAX_CELLS .. " at most" end
    local origin = T.origin()
    local base = origin and COMPASS_AT[origin.facing]
    local limit = opts.limit or LIMIT
    local found, info = {}, { cells = cells, unchecked = 0, more = 0, rules = {}, summary = {} }
    for _, rule in ipairs(RULES) do found[rule] = {} end
    local function warn(rule, x, y, z, words)
        local list = found[rule]
        list[#list + 1] = { rule = rule, x = x, y = y, z = z, text = rule .. " at " .. key(x, y, z) .. ": " .. words }
    end
    for y = y1, y2 + 1 do
        for z = z1, z2 do
            for x = x1, x2 do
                local c = view(x, y, z)
                if c and y <= y2 then
                    local stair = walkStair(view, x, y, z)
                    if stair then checkStair(view, warn, info, base, x, y, z, stair) end
                    if c.kind.rail then checkRailing(view, warn, x, y, z) end
                end
                if c and c.kind.pass and not (c.kind.hot or c.kind.soft) then
                    local floor = view(x, y - 1, z)
                    if floor and floor.kind.floor then checkWalk(view, warn, x, y, z) end
                end
            end
            breathe()
        end
    end
    local warnings = {}
    for _, rule in ipairs(RULES) do
        local list = found[rule]
        if #list > 0 then
            info.rules[rule] = #list
            local line = list[1].text
            if #list > 1 then line = line .. " (and " .. (#list - 1) .. " more like it)" end
            info.summary[#info.summary + 1] = line
        end
        for _, w in ipairs(list) do
            if #warnings < limit then warnings[#warnings + 1] = w else info.more = info.more + 1 end
        end
    end
    return warnings, info
end

return T
