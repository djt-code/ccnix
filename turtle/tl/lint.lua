-- lint.lua -- a build as a two-tall player meets it: warnings about its stairs, railings, drops and lights, and paths
--
-- Loaded by turtlelib the first time T.lint or T.walkable is used.  Cells are the turtle's own (the frame it counts in).
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
--   light     a torch on a wall (soul and redstone too) in a walk cell's feet or head cell: it sticks into the way (a
--             lantern at head height is the lantern rule's); glowstone or a shroomlight set flush, or a torch on a merlon
--             or the wall's top, lights it as well
-- A stair goes by its state (facing, half), which the map has only for blocks that were inspected (T.inspectAll,
-- T.verify; a scan gives names alone), and its compass facing needs the world origin: a stair without them is
-- counted as unchecked and only its headroom is looked at.  A lone stair that climbs to nothing (a seat against a wall,
-- a bench of stairs side by side) isn't a flight, and none of the stair rules is looked at for it.  A cell the map has
-- never seen breaks no rule.
--
-- T.walkable searches the map for a way a player walks from one cell to another (breadth first: fewest steps).  A
-- player's place is the cell its feet are in, over a block to stand on (or on a ladder), and its height in half blocks
-- (a bottom slab is half a block, a fence or wall one and a half).  A step goes to a side, up a block at most (a stair or
-- a slab is a step like any other) or down any height; a climb goes up or down a ladder.  The body is 1.8 high, so a
-- step up needs 3 air where it starts as well as 2 where it ends (the reason a stair needs 3 air).  Lava and fire are
-- never walked into, water breaks a fall, and a fall over 3 is taken only when there is no way without one, and listed.

local T = require("turtlelib")

local LIMIT = 50                  -- warnings listed at most (opts.limit); the rest are counted
local MAX_CELLS = 65536           -- the biggest box a lint reads
local SAFE_FALL = 3               -- the most a player falls without a railing being wanted
local DEEP = 64                   -- how far down a drop is measured
-- The rules in the order the warnings come
local RULES = { "headroom", "approach", "exit", "railing", "drop", "lantern", "light" }
local COMPASS_AT = { north = 0, east = 1, south = 2, west = 3 }
local WALK_LIMIT = 20000          -- places a walk search visits at most (opts.limit)
local WALK_MARGIN = 16            -- how far outside the box of the two ends it may go (opts.margin)
local REASONS = 3                 -- why-nots told, at most, when there is no walk

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
    walltorch = { pass = true, light = true },       -- the body goes through it, but it is in the way
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
    { "walltorch", { "*wall_torch" } },
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

-- The name of a block's kind, by the block's name (worked out once a name).
local kindCache = {}
local function kindNameOf(name)
    local kind = kindCache[name]
    if not kind then
        kind = "solid"
        for _, t in ipairs(TESTS) do
            if t.test(name) then kind = t.kind; break end
        end
        kindCache[name] = kind
    end
    return kind
end

-- The kind of a block, by name.
local function kindOf(name) return KINDS[kindNameOf(name)] end

-- What a block is to a player, by its name: the kind's name (open, railing, stairs, slab, solid, ...) and a copy of its
-- facts ({ pass, floor, height, ... }).
--
-- The kinds are open, ladder, water, hot, gate, railing, lantern, walltorch, stairs, slab and solid (a name no rule
-- knows).  The facts: pass (the body goes through it), floor (a player stands on it), height (its top in half blocks),
-- climb, soft, hot, rail, lantern, light, stairs, slab.  The lint and T.walkable go by these; tl.light reads light's
-- way through a block from them.
function T.blockKind(name)
    local kind = kindNameOf(tostring(name))
    local facts = {}
    for k, v in pairs(KINDS[kind]) do facts[k] = v end
    return kind, facts
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

-- The view and the box for a box or a plan: view, x1, y1, z1, x2, y2, z2, and the plan (nil for a box); or nil and why.
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
        local x1, y1, z1, x2, y2, z2 = bp.extent(plan)
        return newView(function(x, y, z)
            local name, state = bp.at(plan, x, y, z)
            if name then return name, state end
            return mapRead(x, y, z)
        end), x1, y1, z1, x2, y2, z2, plan
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
                .. " (" .. c.name .. " at " .. key(x, y + k, z) .. ")", { { x, y + k, z } })
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
                .. " is in the way (a player needs a floor and 3 air in front of the first stair)", { { ax, y + k, az } })
            return
        end
    end
    local feet = view(ax, y, az)
    if not feet then return end
    if not feet.kind.pass and not feet.kind.floor then
        warn("approach", x, y, z, "the first stair of a flight has no free approach: " .. feet.name .. " at " .. key(ax, y, az) .. " is in the way",
            { { ax, y, az } })
    elseif feet.kind.pass then
        local floor = view(ax, y - 1, az)
        if floor and floor.kind.pass then
            warn("approach", x, y, z, "the cell in front of the first stair, " .. key(ax, y, az) .. ", has no floor", { { ax, y, az } })
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
            warn("exit", x, y, z, "beyond the last stair of the flight, " .. head.name .. " at " .. key(ex, y + 2, ez) .. " is at head height",
                { { ex, y + 2, ez } })
            return 3
        end
        local floor = view(ex, y, ez)
        if floor and floor.kind.pass then
            warn("exit", x, y, z, "the flight runs out over an edge: no floor beyond its last stair, under " .. key(ex, y + 1, ez),
                { { ex, y + 1, ez } })
        end
        return 2
    end
    -- (a half step up, or the next flight turning, goes on; anything else is a wall)
    if not ((feet.kind.slab and heightOf(feet) == 1) or walkStair(view, ex, y + 1, ez)) then
        warn("exit", x, y, z, "the flight runs into " .. feet.name .. " at " .. key(ex, y + 1, ez) .. ": a player needs a landing beyond the last stair",
            { { ex, y + 1, ez } })
    end
    return 3
end

-- Does a stair at x, y, z, going up the step (dx, dz), climb to anything: a floor level with its top beyond it (a
-- ledge), or a half step or another stair going on?  A cell beyond that the map hasn't seen counts as yes.
local function climbsTo(view, x, y, z, dx, dz)
    local ex, ez = x + dx, z + dz
    local feet, under = view(ex, y + 1, ez), view(ex, y, ez)
    if not (feet and under) then return true end
    if feet.kind.pass then return not under.kind.pass end
    return (feet.kind.slab and heightOf(feet) == 1) or walkStair(view, ex, y + 1, ez) ~= nil
end

-- The rules for the stair c at x, y, z.  A lone stair (no stair of its flight below or above it) that climbs to
-- nothing, against a wall or out over a lower floor, is a seat, not a flight: no rule is looked at.
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
    local first, last = not inFlight(x - dx, y - 1, z - dz), not inFlight(x + dx, y + 1, z + dz)
    if first and last and not climbsTo(view, x, y, z, dx, dz) then return end
    local need = 3
    if first then approach(view, warn, x, y, z, dx, dz) end
    if last then need = exit(view, warn, x, y, z, dx, dz) end
    headroom(view, warn, x, y, z, need)
end

--------------------------------------------------------------------------
-- Railings, drops and lights
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
                    .. "so they don't join: a player slips between them (a railing at " .. key(x + b[1], y + b[2], z + b[3]) .. " closes it)",
                    { { px, py, pz }, { x + b[1], y + b[2], z + b[3] } })
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

-- A walk cell's two cells, by height over its feet
local PART = { [0] = "feet", [1] = "head" }

-- The rules for a walk cell: feet at x, y, z (passable, over a floor).  (Its warnings count the floor among their cells.)
local function checkWalk(view, warn, x, y, z)
    local head = view(x, y + 1, z)
    if not head then return end
    if head.kind.lantern then
        warn("lantern", x, y, z, "the " .. head.name .. " at " .. key(x, y + 1, z) .. " hangs at head height over this walk cell: "
            .. "a player walks into it (hang it a block higher)", { { x, y + 1, z }, { x, y - 1, z } })
        return
    end
    if not head.kind.pass then return end
    for _, dy in ipairs({ 0, 1 }) do
        local c = view(x, y + dy, z)
        if c.kind.light then
            warn("light", x, y, z, "the " .. c.name .. " at " .. key(x, y + dy, z) .. " sticks into this walk cell at "
                .. PART[dy] .. " height (glowstone or a shroomlight set flush in the wall or floor, or a torch on a merlon "
                .. "or the wall's top, lights it out of the way)", { { x, y + dy, z }, { x, y - 1, z } })
            break
        end
    end
    for h = 0, 3 do
        local d = T.DELTA[h]
        local nx, nz = x + d[1], z + d[3]
        if gapAt(view, nx, y, nz) and gapAt(view, nx, y + 1, nz) then
            local depth, found = fallFrom(view, nx, y - 1, nz)
            if depth > SAFE_FALL then
                warn("drop", x, y, z, "an open side at " .. key(nx, y, nz) .. " with a drop of " .. (found and "" or "at least ") .. depth
                    .. " below it and no railing: a player can fall", { { nx, y, nz }, { x, y - 1, z } })
                return
            end
        end
    end
end

--------------------------------------------------------------------------
-- The lint
--------------------------------------------------------------------------

-- A line a rule for the warnings found (a list a rule) that keep(w) passes: its first, and how many more.
local function summaryOf(found, keep)
    local lines = {}
    for _, rule in ipairs(RULES) do
        local first, n = nil, 0
        for _, w in ipairs(found[rule]) do
            if keep(w) then
                n = n + 1
                first = first or w
            end
        end
        if first then lines[#lines + 1] = first.text .. (n > 1 and (" (and " .. (n - 1) .. " more like it)") or "") end
    end
    return lines
end

local function always() return true end
local function ofPlan(w) return w.where == "plan" end
local function roundIt(w) return w.where == "around" end

-- What stops a two-tall player in a build (a box or a plan), read-only: headroom over stairs, a flight's approach and
-- exit, railings meeting on a diagonal, drops over 3, lights in the way.  A list of { rule, x, y, z, text }, and info.
--
-- `what` is a box of the map ({ x1, y1, z1, x2, y2, z2 }, or the fields) or a plan (as T.build takes one: its own
-- cells and states, the map for the cells it leaves alone and round it).  The cells looked at are the box's and,
-- for walking on its top, the layer over it; the cells round them (an approach, a drop) are read too.  A warning is
-- { rule, x, y, z, text }: rule is headroom, approach, exit, railing, drop, lantern or light (see the overview), x, y, z the
-- cell (the stair, the railing or the walk cell), text says it in plain words with the cells involved.  Warnings, not
-- refusals: a design may break a rule on purpose.  Nil and why if it can't start.  Info is { cells, unchecked (stairs
-- with no facing in the map or no origin: only their headroom looked at), more (warnings past opts.limit, default 50),
-- rules (a count by rule), summary (a line a rule: its first warning, and how many more) }.  opts.rules (a list of
-- rule names) checks only those.  The limit is shared: the list takes each rule's first, then each one's second, and
-- so on, so one rule with many can't crowd out the others.
-- For a plan, each warning is tagged where = "plan" when its cell, the floor under its walk cell or a cell it names is
-- one of the plan's, else "around" (terrain and buildings round it); the plan's come first, and info adds inPlan and
-- around (the counts) and planSummary (the summary of the plan's own).  T.build prints only those, and a count of the rest.
function T.lint(what, opts)
    opts = opts or {}
    local view, x1, y1, z1, x2, y2, z2, plan = viewOf(what)
    if not view then return nil, x1 end
    local cells = (x2 - x1 + 1) * (y2 - y1 + 1) * (z2 - z1 + 1)
    if cells > MAX_CELLS then return nil, "the box is " .. cells .. " cells; a lint reads " .. MAX_CELLS .. " at most" end
    local origin = T.origin()
    local base = origin and COMPASS_AT[origin.facing]
    local limit = opts.limit or LIMIT
    local only
    if opts.rules ~= nil then
        if type(opts.rules) ~= "table" then return nil, "opts.rules is a list of rules: " .. table.concat(RULES, ", ") end
        only = {}
        for _, name in ipairs(opts.rules) do
            local known = false
            for _, rule in ipairs(RULES) do known = known or rule == name end
            if not known then return nil, "no lint rule " .. tostring(name) .. " (the rules: " .. table.concat(RULES, ", ") .. ")" end
            only[name] = true
        end
    end
    local found, info = {}, { cells = cells, unchecked = 0, more = 0, rules = {}, summary = {} }
    for _, rule in ipairs(RULES) do found[rule] = {} end
    local bp = plan and T.blueprint      -- (a box's lint never loads tl.blueprint)
    -- (a warning is the plan's when its own cell or one of the cells it names is)
    local function where(x, y, z, named)
        if bp.at(plan, x, y, z) then return "plan" end
        for _, c in ipairs(named) do
            if bp.at(plan, c[1], c[2], c[3]) then return "plan" end
        end
        return "around"
    end
    local function warn(rule, x, y, z, words, named)
        if only and not only[rule] then return end
        local list = found[rule]
        list[#list + 1] = { rule = rule, x = x, y = y, z = z, text = rule .. " at " .. key(x, y, z) .. ": " .. words,
                            where = plan and where(x, y, z, named or {}) or nil }
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
        if #found[rule] > 0 then info.rules[rule] = #found[rule] end
    end
    info.summary = summaryOf(found, always)
    -- (a plan's own warnings first, so the limit cuts those round it)
    local passes = { always }
    if plan then
        passes = { ofPlan, roundIt }
        info.planSummary = summaryOf(found, ofPlan)
        info.inPlan, info.around = 0, 0
    end
    for _, keep in ipairs(passes) do
        -- (each rule's warnings in turn, a round at a time: the limit is shared)
        local lists, longest = {}, 0
        for _, rule in ipairs(RULES) do
            local list = {}
            for _, w in ipairs(found[rule]) do
                if keep(w) then
                    list[#list + 1] = w
                    if plan then
                        if w.where == "plan" then info.inPlan = info.inPlan + 1 else info.around = info.around + 1 end
                    end
                end
            end
            lists[#lists + 1] = list
            longest = math.max(longest, #list)
        end
        for i = 1, longest do
            for _, list in ipairs(lists) do
                local w = list[i]
                if w then
                    if #warnings < limit then warnings[#warnings + 1] = w else info.more = info.more + 1 end
                end
            end
        end
    end
    return warnings, info
end

--------------------------------------------------------------------------
-- Walking
--------------------------------------------------------------------------

-- The highest cell a player's body is in, standing at H (half blocks): its top is 1.8 over its feet.
local function topCell(H) return math.ceil((5 * H + 18) / 10) - 1 end

-- Half blocks as blocks, in words: "1", "1.5".
local function blocks(n) return math.floor(n / 2) .. (n % 2 == 1 and ".5" or "") end

-- Where a player with its feet in x, y, z stands: its height H in half blocks, or nil and why.
local function standIn(view, x, y, z)
    local feet = view(x, y, z)
    if not feet then return nil, key(x, y, z) .. " isn't in the map" end
    if not feet.kind.pass or feet.kind.hot then return nil, key(x, y, z) .. " holds " .. feet.name end
    local floor = view(x, y - 1, z)
    local H
    if floor and not floor.kind.pass then
        H = 2 * (y - 1) + heightOf(floor)
    elseif feet.kind.climb then
        H = 2 * y
    elseif not floor then
        return nil, "the map hasn't seen under " .. key(x, y, z)
    else
        return nil, "nothing to stand on under " .. key(x, y, z)
    end
    for c = y + 1, topCell(H) do
        local b = view(x, c, z)
        if not (b and b.kind.pass) then return nil, "no room for a player's head at " .. key(x, c, z) end
    end
    return H
end

-- A step from the place p ({ x, y, z, H }) to the column nx, nz: the place it ends in ({ x, y, z, H, fall }), or nil
-- and why.  The player goes across at its height and drops to what is under it there, or steps up onto it.
local function stepTo(view, p, nx, nz, maxFall)
    local top = topCell(p.H)
    local c, soft, block = top, false, nil
    while true do
        local b = view(nx, c, nz)
        if not b then return nil, "the map hasn't seen " .. key(nx, c, nz) end
        if not b.kind.pass then block = b; break end
        if b.kind.hot then return nil, b.name .. " at " .. key(nx, c, nz) end
        if b.kind.soft then soft = true end
        if b.kind.climb and c <= p.y then          -- (walked into a ladder, or caught one falling)
            local H, why = standIn(view, nx, c, nz)
            if not H then return nil, why end
            return { x = nx, y = c, z = nz, H = H }
        end
        if top - c > DEEP then return nil, "a drop of more than " .. DEEP .. " at " .. key(nx, p.y, nz) end
        c = c - 1
    end
    local H = 2 * c + heightOf(block)
    local rise = H - p.H
    if rise > 2 then
        if c > p.y then return nil, block.name .. " at " .. key(nx, c, nz) .. " is in the way" end
        return nil, block.name .. " at " .. key(nx, c, nz) .. " is a step of " .. blocks(rise) .. " (a player climbs 1 at most)"
    end
    -- (going up, the body reaches higher in both columns: 3 air where a step up starts)
    for k = top + 1, topCell(math.max(p.H, H)) do
        for _, at in ipairs({ { p.x, p.z }, { nx, nz } }) do
            local b = view(at[1], k, at[2])
            if not (b and b.kind.pass) then
                return nil, "headroom: " .. (b and b.name or "a cell never seen") .. " at " .. key(at[1], k, at[2])
                    .. ": a step up needs 3 air where it starts and 2 where it ends"
            end
        end
    end
    local fall = (not soft and -rise > 2 * SAFE_FALL) and -rise or nil
    if fall and fall > 2 * maxFall then
        return nil, "a fall of " .. blocks(fall) .. " to " .. key(nx, c + 1, nz) .. " (opts.maxFall is " .. maxFall .. ")"
    end
    return { x = nx, y = c + 1, z = nz, H = H, fall = fall }
end

-- Where a player goes from the place p: a list of places; fail(x, y, z, why) is told of each way that's shut.
local function movesFrom(view, p, maxFall, fail)
    local out = {}
    for h = 0, 3 do
        local d = T.DELTA[h]
        local nx, nz = p.x + d[1], p.z + d[3]
        local q, why = stepTo(view, p, nx, nz, maxFall)
        if q then out[#out + 1] = q else fail(nx, p.y, nz, why) end
    end
    local here = view(p.x, p.y, p.z)
    if here and here.kind.climb then
        for _, dy in ipairs({ 1, -1 }) do
            local rung = view(p.x, p.y + dy, p.z)
            if rung and rung.kind.climb then
                local H, why = standIn(view, p.x, p.y + dy, p.z)
                if H then out[#out + 1] = { x = p.x, y = p.y + dy, z = p.z, H = H } else fail(p.x, p.y + dy, p.z, why) end
            end
        end
    end
    return out
end

-- The search, breadth first, with falls over 3 up to maxFall: the path (the places after the start) and info, or nil
-- and why.
local function walkSearch(view, from, H, to, maxFall, opts)
    local limit, margin = opts.limit or WALK_LIMIT, opts.margin or WALK_MARGIN
    local x1, x2 = math.min(from.x, to.x) - margin, math.max(from.x, to.x) + margin
    local y1, y2 = math.min(from.y, to.y) - margin, math.max(from.y, to.y) + margin
    local z1, z2 = math.min(from.z, to.z) - margin, math.max(from.z, to.z) + margin
    local goal = key(to.x, to.y, to.z)
    local start = { x = from.x, y = from.y, z = from.z, H = H }
    local parent = { [key(from.x, from.y, from.z)] = false }
    local queue, head, nodes = { start }, 1, 0
    -- the ways shut nearest the goal, for the why
    local near = { d = math.huge, list = {}, seen = {} }
    local function fail(x, y, z, why)
        local d = math.abs(x - to.x) + math.abs(y - to.y) + math.abs(z - to.z)
        if d < near.d then near.d, near.list, near.seen = d, {}, {} end
        if d == near.d and not near.seen[why] and #near.list < REASONS then
            near.seen[why] = true
            near.list[#near.list + 1] = why
        end
    end
    while head <= #queue do
        local p = queue[head]
        head = head + 1
        if key(p.x, p.y, p.z) == goal then
            local path, falls = {}, {}
            while p ~= start do
                table.insert(path, 1, { x = p.x, y = p.y, z = p.z })
                if p.fall then table.insert(falls, 1, { x = p.x, y = p.y, z = p.z, height = p.fall / 2 }) end
                p = parent[key(p.x, p.y, p.z)]
            end
            return path, { nodes = nodes, falls = falls }
        end
        nodes = nodes + 1
        if nodes > limit then
            return nil, "no walk: gave up after " .. limit .. " places without reaching " .. goal .. " (opts.limit raises that)"
        end
        for _, q in ipairs(movesFrom(view, p, maxFall, fail)) do
            local k = key(q.x, q.y, q.z)
            if parent[k] == nil and q.x >= x1 and q.x <= x2 and q.y >= y1 and q.y <= y2 and q.z >= z1 and q.z <= z2 then
                parent[k] = p
                queue[#queue + 1] = q
            end
        end
        if nodes % 32 == 0 then breathe() end
    end
    local why = "no walk from " .. key(from.x, from.y, from.z) .. " to " .. goal
    if #near.list > 0 then why = why .. ": nearest the goal (" .. near.d .. " cells off), " .. table.concat(near.list, "; ") end
    return nil, why
end

-- A cell as { x, y, z } from { x, y, z } or { x =, y =, z = }, or nil.
local function cellOf(c)
    if type(c) ~= "table" then return nil end
    local x, y, z = c.x or c[1], c.y or c[2], c.z or c[3]
    if not (whole(x) and whole(y) and whole(z)) then return nil end
    return { x = x, y = y, z = z }
end

-- A way a two-tall player walks from one feet cell to another over the map (steps up 1, ladders, falls over 3 only
-- if there's no other way): the path (feet cells after `from`, the last `to`) and { falls }; nil and why if none.
--
-- `from` and `to` are cells ({ x, y, z } or { x =, y =, z = }) a player's feet are in: the cell over the block stood
-- on.  A player steps to a side, up a block at most (stairs and slabs included) or down, and climbs ladders; a step up
-- needs 3 air where it starts (see the overview).  Falls over 3 are taken only when there is no way without one, and
-- listed; opts.maxFall refuses those over it.  The why of no walk names what shuts the ways nearest the goal (a block
-- in the way, a step too high, headroom, a fall, cells the map hasn't seen).  Info is { nodes (places searched), falls
-- = list of { x, y, z, height } (where each fall over 3 lands) }.  opts: maxFall, limit (places to search, default
-- 20000), margin (how far outside the box of the two cells, default 16).
function T.walkable(from, to, opts)
    opts = opts or {}
    local a, b = cellOf(from), cellOf(to)
    if not (a and b) then return nil, "walkable wants two cells of whole numbers: { x, y, z }" end
    local view = newView(mapRead)
    local H, why = standIn(view, a.x, a.y, a.z)
    if not H then return nil, "a player can't stand at " .. key(a.x, a.y, a.z) .. ": " .. why end
    local goalOk, goalWhy = standIn(view, b.x, b.y, b.z)
    if not goalOk then return nil, "a player can't stand at " .. key(b.x, b.y, b.z) .. ": " .. goalWhy end
    local path, info = walkSearch(view, a, H, b, opts.maxFall or SAFE_FALL, opts)
    if path or opts.maxFall then return path, info end
    return walkSearch(view, a, H, b, DEEP, opts)
end

return T
