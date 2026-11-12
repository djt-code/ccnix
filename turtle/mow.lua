-- mow.lua -- lawn-mowing turtle for CC:Tweaked
--
-- Needs a diamond pickaxe, equipped or in the inventory.  Any other tool
-- (e.g. a hoe on the other side) is parked in the inventory while the
-- program runs and put back afterwards.  Optional: Advanced Peripherals
-- Chunky Turtle upgrade so it keeps running unattended.
--
-- Usage:  mow [<width> <length> [repeatMinutes]] [notorch] [--here]
--         mow reset                 return to home after a Ctrl+T
--         mow reset --here          turtle was put back by hand: reset position
--
-- width  = tiles to the RIGHT of the turtle (negative = to the LEFT)
-- length = tiles AHEAD of the turtle (negative = BEHIND)
-- Both are counted OUT from the turtle: its own row and column are not
-- part of the lawn, so the box is x = 1..width, z = 1..length.
--
-- With no size it mows the one in the settings (mow.width, mow.length:
-- 16 x 16 unless changed with `sysctl mow.width=30`); mow.repeat is the
-- minutes between passes (0 = once), mow.torches false keeps the torches.
-- A size given here is saved there for the next `mow` (or the autostart).
--
-- Place the turtle diagonally outside one corner of the lawn, on the ground
-- at grass level, facing along the LENGTH axis.
-- Optional chest/barrel directly below the start position for seeds.
-- Put torches in the inventory and it lights the lawn as it mows.
--
-- How it works:
--  * The mow plan is a precomputed serpentine list of (x,z) columns.
--  * Terrain is handled locally (turtlelib.stepTerrain): climb steps up
--    to maxClimb, sink onto the ground, refuse crevasses.
--  * Columns that can't be entered are recorded and routed around (BFS).
--  * Unreachable columns are retried at the end while progress is made.
--  * The ground's height where the turtle has stood is kept, and written in
--    the map (T.map) for the next run: a step between two columns whose
--    ground differs by more than it can climb or sink is not planned, and a
--    column something solid stopped it in is left out for the rest of the
--    run, so a second pass doesn't run into the same pillar again.  A
--    column of unknown height is taken to be level with where the turtle
--    stands.  `sysctl mow.map=false` turns the heights off.
--  * Protected areas (T.protect, by another program or by hand) are kept
--    out of: the tiles in one are left alone, the routes go round them, and
--    mow says how many tiles it kept out of.
--  * Torches go on a diamond lattice so every tile is within TORCH_RADIUS
--    (taxicab) of one.  Since 1.18 mobs spawn only at block light 0; a
--    torch is light 14, so radius 13 is the limit and 12 leaves a margin.
--    (Pre-1.18 servers spawn at light <= 7: use radius 6.)

package.path = (ccnix and ccnix.lib or "") .. package.path    -- (ccnix's turtlelib, the updates' first)
local T = require("turtlelib")

-- (T.options: a negative size, -3, is a size, not an option; a flag
-- alone can't be wrong, so there's no error to check)
local opts, args = T.options({ ... }, { here = true })
local HERE = opts.here == true
-- notorch is a word, not an option: wherever it is, it's taken out
local noTorch = false
for i = #args, 1, -1 do
    if args[i] == "notorch" then noTorch = true; table.remove(args, i) end
end
local TORCHES = not noTorch and T.setting("mow.torches", true, "Light the lawn as mow goes")
if args[1] == "reset" then
    if HERE then T.setHomeHere() else T.goHome() end
    return
end
local SET_W = T.setting("mow.width", 16, "Lawn width for mow: tiles + right / - left of the turtle")
local SET_L = T.setting("mow.length", 16, "Lawn length for mow: tiles + ahead / - behind the turtle")
local SET_R = T.setting("mow.repeat", 0, "Minutes between mow passes; 0 = a single pass")
local WIDTH  = tonumber(args[1]) or SET_W
local LENGTH = tonumber(args[2]) or SET_L
local REPEAT = tonumber(args[3]) or (SET_R > 0 and SET_R or nil)   -- minutes between passes; nil = once
local MIN_FUEL = math.abs(WIDTH * LENGTH) + math.abs(WIDTH) + math.abs(LENGTH) + 150

local TORCH = "minecraft:torch"
local TORCH_RADIUS = 12

T.cfg.width, T.cfg.length = WIDTH, LENGTH
T.cfg.maxClimb, T.cfg.maxDrop, T.cfg.maxHeight = 3, 12, 16
T.step = T.stepTerrain
T.mode = "terrain"

-- Blocks we are allowed to cut.  Anything else is terrain / an obstacle.
T.diggable = {
    ["minecraft:short_grass"] = true,    -- 1.20.3+
    ["minecraft:grass"]       = true,    -- older name for short grass
    ["minecraft:tall_grass"]  = true,
    ["minecraft:fern"]        = true,
    ["minecraft:large_fern"]  = true,
    ["minecraft:dead_bush"]   = true,
}

--------------------------------------------------------------------------
-- The ground, in the map; protected areas
--------------------------------------------------------------------------
-- Where the turtle has stood, the ground's height is kept (and written in
-- the map, so a later run knows it too), and the routing leaves out a step
-- between two columns whose ground differs by more than it can climb or
-- sink.  A column something solid blocked is given a height too far from
-- its neighbours' for the rest of the run (terrain stays where it is).
-- Columns in a protected area are never entered: the tiles are left
-- alone and the routes go round them.
local USE_MAP = T.setting("mow.map", true, "Keep the ground heights mow finds in the map, and route over them")
local ground = {}                                  -- ground[T.ckey(x, z)] = y of the ground block there

local function groundAt(x, z) return ground[T.ckey(x, z)] end

-- The name of the protected area a tile's turtle cell lies in, or nil.
local function gardenAt(x, z)
    local g = groundAt(x, z)
    return T.guarded(x, g and g + 1 or 0, z)
end

-- Is the step from column x, z into nx, nz one to plan?  A column whose
-- ground isn't known is taken to be level with the ground under the turtle.
local function stepAllowed(x, z, nx, nz)
    if gardenAt(nx, nz) then return false end
    local here = T.pos.y - 1
    local a, b = groundAt(x, z) or here, groundAt(nx, nz) or here
    return math.abs(a - b) <= T.cfg.maxClimb
end

-- Write down the ground under the turtle.
local function noteGround()
    local ok, block = turtle.inspectDown()
    if not ok then return end
    ground[T.ckey(T.pos.x, T.pos.z)] = T.pos.y - 1
    if USE_MAP then T.map.set(T.pos.x, T.pos.y - 1, T.pos.z, block.name, block.state) end
end

-- What the map knows of the lawn's ground from earlier runs.
local function loadGround(plan)
    if not (USE_MAP and fs.exists(T.dataPath(T.MAP_DIR))) then return end
    for _, t in ipairs(plan) do
        local y = T.map.top(t.x, t.z)
        if y then ground[T.ckey(t.x, t.z)] = y end
    end
end

-- T.stepTerrain, and when something solid stops it, that column is
-- remembered as too high to climb for the rest of the run.
local function stepOver()
    if T.stepTerrain() then return true end
    if USE_MAP then
        local seen = turtle.inspect()
        if seen then
            local ahead = T.neighbour(T.dir)
            ground[T.ckey(ahead.x, ahead.z)] = T.pos.y - 1 + T.cfg.maxClimb + 1
        end
    end
    return false
end

--------------------------------------------------------------------------
local function goToAndSettle(tx, tz)
    if not T.goTo(tx, tz) then return false end
    T.settle()
    noteGround()
    return true
end

-- Empty slots to have before mowing on: room for the seeds grass drops,
-- plus one for tool swaps.  With less, go home and empty into the chest
-- (waiting if it's full) so nothing is left on the ground.
local ROOM = 2
local function ensureRoom()
    T.ensureRoom(ROOM, nil, function()
        if goToAndSettle(0, 0) then
            T.face(0)
            T.dumpDownWait()
        end
    end, "No room for drops and nothing to empty (or no chest below home); drops may spill.")
end

--------------------------------------------------------------------------
-- Torches
--------------------------------------------------------------------------
local torchSet, torchList = {}, {}
if TORCHES then
    torchSet, torchList = T.lightLattice(TORCH_RADIUS, WIDTH, LENGTH)
end
local torchesPlaced, warnedNoTorch = 0, false

-- Called standing on the ground at a lattice tile.  Rises one block and
-- places a torch on the ground below; leaves the turtle above the torch.
local function placeTorch()
    local ok, below = turtle.inspectDown()
    if ok and below.name == TORCH then return end     -- placed on an earlier pass
    if not T.up() then return end
    if turtle.detectDown() then return end           -- already lit (or solid)
    if not T.selectItem(TORCH) then
        if not warnedNoTorch then
            print("No torches in inventory; skipping lighting.")
            warnedNoTorch = true
        end
        return
    end
    if turtle.placeDown() then torchesPlaced = torchesPlaced + 1 end
    turtle.select(1)
end

local function mowTiles(tiles)
    local skipped = {}
    for i, t in ipairs(tiles) do
        ensureRoom()
        if gardenAt(t.x, t.z) then
            -- in a protected area: left alone
        elseif not goToAndSettle(t.x, t.z) then
            print(string.format("Can't reach (%d,%d), skipping", t.x, t.z))
            skipped[#skipped + 1] = t
        elseif torchSet[T.ckey(t.x, t.z)] then
            placeTorch()
        end
        if i % 50 == 0 then
            print(string.format("%d/%d tiles, y=%d, fuel %s", i, #tiles, T.pos.y,
                tostring(turtle.getFuelLevel())))
        end
    end
    return skipped
end

--------------------------------------------------------------------------
if not T.requireHome(HERE, "mow") then return end
if tonumber(args[1]) and tonumber(args[2]) then
    -- a size given is kept for next time, as mine and farm keep theirs: after
    -- the home check (a "no" keeps the old one), and the repeat only if given
    T.saveSettings({ ["mow.width"] = WIDTH, ["mow.length"] = LENGTH, ["mow.repeat"] = tonumber(args[3]) })
end

local plan = T.serpentine(WIDTH, LENGTH)
print(string.format("Mowing %dx%d (%d tiles). Fuel: %s", WIDTH, LENGTH, #plan,
    tostring(turtle.getFuelLevel())))
T.step = stepOver
T.edgeOK = stepAllowed
loadGround(plan)
local kept, keptIn = 0, {}
for _, t in ipairs(plan) do
    local area = gardenAt(t.x, t.z)
    if area then
        kept = kept + 1
        if not keptIn[area] then keptIn[area] = true; keptIn[#keptIn + 1] = area end
    end
end
if kept > 0 then
    print(string.format("Keeping out of %d tiles in a protected area (%s).", kept, table.concat(keptIn, ", ")))
end
if TORCHES then
    print(string.format("Lighting: %d torch sites (radius %d); %d torches on board",
        #torchList, TORCH_RADIUS, T.countItem(TORCH)))
end

T.withTool("minecraft:diamond_pickaxe", function()
    while true do
        T.requireFuel(MIN_FUEL)
        T.clearBlocked()
        T.settle()

        local skipped = mowTiles(plan)
        -- Skipped tiles (e.g. a pocket behind a crevasse) are retried using the
        -- obstacle map built during the pass, until a round makes no progress.
        while #skipped > 0 do
            print("Retrying " .. #skipped .. " skipped tiles")
            local remaining = mowTiles(skipped)
            if #remaining >= #skipped then skipped = remaining; break end
            skipped = remaining
        end
        if #skipped > 0 then
            print("Gave up on " .. #skipped .. " tiles:")
            for _, t in ipairs(skipped) do io.write(string.format("(%d,%d) ", t.x, t.z)) end
            print()
        end

        if not goToAndSettle(0, 0) then
            print("Couldn't get home; at " .. T.posString())
        end
        T.face(0)
        T.dumpDownWait()
        print(string.format("Pass complete. Fuel left: %s, torches placed: %d",
            tostring(turtle.getFuelLevel()), torchesPlaced))

        if not REPEAT then break end
        print("Sleeping " .. REPEAT .. " min (Ctrl+T to stop)")
        sleep(REPEAT * 60)
    end
end)
