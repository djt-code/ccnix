-- turtlelib.lua -- shared helpers for the turtle programs
--
-- Usage in a program (same directory):
--     local T = require("turtlelib")
--
-- Provides:
--   * dead-reckoned position/heading (T.pos, T.dir, T.face), kept right
--     by the turtle API itself: loading this wraps the moves and turns
--     (forward, back, up, down, turnLeft, turnRight) and the digs and
--     places, once however many programs load it, so a move made
--     straight through turtle.* is counted too; T.raw holds the originals
--   * protected areas (T.protect, T.unprotect, T.protected, T.inside) that
--     no dig through the turtle API goes into, and a refusal to dig
--     chests, barrels, shulker boxes, spawners and ComputerCraft blocks
--     (T.cfg.digContainers lifts it)
--   * change hooks: T.onChange(fn) hears every successful dig, placement
--     and move
--   * T.moveTo: a move to a cell in three dimensions that says why it
--     stopped (blocked, protected, lava), T.withPeripheral and
--     T.equipPeripheral: use an item as a peripheral without taking off a
--     chunk controller, T.pull: a count of one item out of a chest, and
--     a junk chest (T.setJunkChest, T.isJunk, T.dumpJunk) that nothing is
--     ever dropped on the ground for
--   * the map and the frames (tl.world, loaded when first used): T.scan, the
--     geo scanner's blocks in the turtle's own frame, kept in a map on disk
--     (T.map.get/find/heights/slice, ...) that digs, placements and moves update,
--     T.setOrigin/T.toWorld/T.toLocal for world coordinates, and T.inspectAt
--     for block states; a re-zeroed frame (--here) keeps the map right
--   * routes (tl.path, loaded when first used): T.path, A* over the map round
--     protected areas, lava, fire and doors, and T.travel, which walks one
--     along a clear layer (or the search), planning again at a block it did
--     not expect; T.moveTo's opts.path asks for it
--   * placing (tl.place, loaded when first used): T.placeAt puts a stair, slab,
--     log, torch, door or the like down with the state wanted (facing, half,
--     axis), choosing how to place it from a table of what each approach
--     gives, checking and trying another way if the game differed, and
--     remembering what it learnt; T.ignite lights a fire from above
--   * building (tl.blueprint, loaded when first used): a plan is layers of
--     text with a legend (T.blueprint.parse/fill/box/walls/fromMap); T.build
--     puts one up layer by layer, materials checked first, progress kept so a
--     stop or reboot carries on; T.verify says which cells differ, states
--     included; T.replace swaps the blocks matching a glob in a box
--   * crafting (tl.craft, loaded when first used): T.craft makes stairs, slabs, walls, doors, chests and the
--     rest of vanilla's building basics from a chest, through the crafting table equipped as a peripheral
--     (a chunk controller stays on); recipes are data (T.addRecipe adds more), T.canCraft says what is short;
--     T.smelt runs a furnace; T.fuelTicks and T.smeltsTo are what burns and what smelts
--   * the chests at home (tl.store, loaded when first used): T.addChest tells it where they are, T.catalogue
--     goes round them and writes down what each holds, T.where says which have an item, T.fetch goes and takes
--     some, T.stow puts what the turtle carries away (into a chest that holds it, else the bulk chest), and
--     T.cfg.autoDump = true does that on its own when the inventory nearly fills
--   * taking blocks by name and fuel (tl.harvest, loaded when first used): T.harvest digs the blocks matching a glob in a
--     place, nearest first and top down, leaving lava-touched, protected and falling-supported ones; T.refuelFromLava
--     takes up the nearest lava source and burns it; T.fuelFor says what a route or build will cost
--   * jobs, undo and reports (tl.journal, loaded when first used): T.job keeps a job's goal, steps and progress in a file
--     so a restart carries on at the step; T.cfg.undo = true writes down each dig and placement and T.undo(n) puts them
--     back; T.report tells the player (the setting turtle.player) through a chat box, with position, fuel and progress
--   * modules loaded when first used: a function T lacks that is in
--     T.registry is looked up there, its module (turtle/tl/<name>.lua,
--     required as "tl.<name>") fills T in, and the call goes on
--   * fuel management that refuels from inventory mid-task (T.ensureFuel)
--   * low-level moves that only dig blocks listed in T.diggable
--   * six directions (0..3 and "up"/"down"): look, dig, place or move in
--     one, the fewest-turns ordering, 3D positions and keys
--   * a learned 2D obstacle map with BFS routing (T.goTo)
--   * two column-stepping strategies: flat (fixed height) and terrain
--     (climb steps, follow the ground, refuse crevasses)
--   * inventory helpers (items by name or by a test), tool hot-swapping,
--     serpentine plan generation
--   * chest-below helpers: dump with a keep policy, count, restock,
--     merge part stacks
--   * reading item names and saved files with lib/scan and lib/text,
--     not Lua patterns; the files with lib/fileio
--   * the programs' options (T.options, on lib/getopt) and mine's job
--     file (T.loadMineJob, T.saveMineJob: mine and autostart read it)
--
-- Programs configure it by setting fields on T.cfg and T.diggable before
-- moving.  Everything is relative to where the turtle starts: (0,0,0)
-- facing +z, with +x to its right.

local T = {}

-- Reading names and the saved files: lib/scan, lib/text and the rest
-- (ccnix's boot puts lib/ on the path beside turtle/)
local scan = require("scan")
local text = require("text")
local convert = require("convert")
local fileio = require("fileio")
local tables = require("tables")
local getopt = require("getopt")
local glob = require("glob")

--------------------------------------------------------------------------
-- Configuration (override from the program)
--------------------------------------------------------------------------
T.cfg = {
    width      = 16,    -- tiles to the RIGHT of the start (negative = LEFT)
    length     = 16,    -- tiles AHEAD of the start (negative = BEHIND)
                        -- the start tile itself is outside the grid: x in 1..w, z in 1..l
    margin     = 1,     -- columns outside the grid usable for detours
    maxReplans = 10,    -- BFS re-plans per target before giving up
    lowFuel    = 50,    -- top up from inventory below this
    topupFuel  = 1000,  -- ...to about this level
    fuelMargin = 30,    -- spare fuel kept beyond the trip home (detours)
    maxClimb   = 3,     -- terrain stepping: max climb per column
    maxDrop    = 12,    -- max blocks below start level
    maxHeight  = 16,    -- max blocks above start level
}

-- Block names the move functions are allowed to dig through.
T.diggable = {}

-- Fuel items, each with what one refuels (what CC:Tweaked gives: a
-- furnace's burn time / 20); T.fuel is their set.
T.FUEL_VALUE = {
    ["minecraft:coal"] = 80, ["minecraft:charcoal"] = 80, ["minecraft:coal_block"] = 800,
    ["minecraft:lava_bucket"] = 1000, ["minecraft:blaze_rod"] = 120, ["minecraft:dried_kelp_block"] = 200,
}
T.fuel = {}
for name in pairs(T.FUEL_VALUE) do T.fuel[name] = true end

-- Items dumpDown never throws away by default: fuel and torches.
T.keep = { ["minecraft:torch"] = true }
for name in pairs(T.fuel) do T.keep[name] = true end

--------------------------------------------------------------------------
-- Position tracking.  dir: 0=+z 1=+x 2=-z 3=-x
--------------------------------------------------------------------------
T.pos = { x = 0, y = 0, z = 0 }
T.dir = 0
local DX = { [0] = 0, [1] = 1, [2] = 0, [3] = -1 }
local DZ = { [0] = 1, [1] = 0, [2] = -1, [3] = 0 }
T.DX, T.DZ = DX, DZ

--------------------------------------------------------------------------
-- Position persistence.  Every successful move/turn is written to a small
-- file next to the program, so after Ctrl+T or a reboot `home` / `reset`
-- can still find the way back to the start.
--------------------------------------------------------------------------
T.mode = "flat"            -- "flat" or "terrain": which stepper to use going home

-- The path of a data file kept next to the running program (/ccnix/turtle for one in the ROM),
-- moving an old copy down the first time it's asked for.
--
-- The programs moved from the repo's top folder into turtle/ on 2026-10-28; a file left up there (a job
-- half done) is moved down the first time it's asked for, so `--resume` and `reset` still find it.  A
-- program in ccnix's ROM (/rom/ccnix/turtle) keeps its files in /ccnix/turtle, where its updates go too
-- (the ROM is read-only); one from an install before ccnix (/cc-turtles/turtle) is moved there the same
-- way.
function T.dataPath(name)
    local prog = shell and shell.getRunningProgram and shell.getRunningProgram() or ""
    local dir = fs.getDir(prog)
    local inRom = text.stripPrefix(dir, "rom/")
    if inRom then
        dir = inRom
        if not fs.exists(dir) then fs.makeDir(dir) end
    end
    local path = fs.combine(dir, name)
    local old = fs.combine(fs.getDir(dir), name)
    if dir == "ccnix/turtle" and not fs.exists(old) then old = fs.combine("cc-turtles/turtle", name) end
    if text.endsWith("/" .. dir, "/turtle") and not fs.exists(path) and fs.exists(old) then fs.move(old, path) end
    return path
end

local POS_FILE = ".turtlepos"

-- Ctrl+T while a program runs under T.run: held back during a turtle
-- command, and raised here, once the move or turn is saved.
T.stopping = false

-- Write T.pos, T.dir and T.mode to the position file, so a stop or a reboot can still find the way
-- home.  Raises "Terminated" if a Ctrl+T was held back (see T.run).
function T.savePos()
    if not fileio.write(T.dataPath(POS_FILE), string.format("%d %d %d %d %s", T.pos.x, T.pos.y, T.pos.z, T.dir, T.mode)) then
        return
    end
    if T.stopping then
        T.stopping = false
        error("Terminated", 0)
    end
end

local COMMAND_EVENTS = { turtle_response = true, task_complete = true }

-- Run fn(...) so that Ctrl+T can't leave the saved position wrong: one that
-- comes during a turtle command is held back until the move or turn is saved.
--
-- Plain Ctrl+T stops a program wherever it's waiting, in the middle of a
-- turtle command too: the turtle still moves or turns, but the program never
-- records it, so its saved position or heading is off by one and going home
-- from there goes astray.  Under T.run a Ctrl+T that comes during a command
-- (or a peripheral call) is held back until it's done: the program stops at
-- the next saved move or turn (T.savePos), or the next ordinary wait (sleep, a
-- key), whichever comes first.
function T.run(fn, ...)
    local co = coroutine.create(fn)
    local args = table.pack(...)
    while true do
        local ok, filter = coroutine.resume(co, table.unpack(args, 1, args.n))
        if not ok then error(filter, 0) end
        if coroutine.status(co) == "dead" then return end
        if T.stopping and not COMMAND_EVENTS[filter] then
            T.stopping = false
            args = table.pack("terminate")
        else
            repeat
                args = table.pack(os.pullEventRaw())
                local hold = args[1] == "terminate" and COMMAND_EVENTS[filter]
                if hold then T.stopping = true end
            until not hold and (filter == nil or args[1] == filter or args[1] == "terminate")
        end
    end
end

-- The saved position as { x, y, z, dir, mode }, or nil if there is none.
function T.loadPos()
    local line = fileio.read(T.dataPath(POS_FILE))
    if not line then return nil end
    -- "x y z dir mode", as savePos writes it: three whole numbers, a digit, a word
    local w = text.words(line)
    local x, y, z, d, mode = w[1], w[2], w[3], w[4], w[5]
    if not (scan.isInteger(x) and scan.isInteger(y) and scan.isInteger(z) and scan.isUnsigned(d) and #d == 1
            and scan.isName(mode)) then
        return nil
    end
    return { x = tonumber(x), y = tonumber(y), z = tonumber(z), dir = tonumber(d), mode = mode }
end

-- The folder of the map (tl.world) in the data folder.  Its being there is how
-- the code below knows there is a map whose frame a re-zeroing would move.
T.MAP_DIR = ".map"

-- Tell the map (if there is one) that the frame the turtle counts in changed: the spot
-- that was `old` ({ x, y, z, dir }, or nil if that isn't known) is now `new` (default
-- the start, 0,0,0 facing 0).  Without a map on disk this does nothing, and loads nothing.
local function frameMoved(old, new)
    if not fs.exists(T.dataPath(T.MAP_DIR)) then return end
    if old and old.x == 0 and old.y == 0 and old.z == 0 and old.dir == 0 and not new then return end
    local changed = T.need("frameChanged")
    if changed then pcall(changed, old, new) end
end

-- Where the turtle was when T.clearPos last forgot it: the frame it left, for the map
local cleared

-- Delete the saved position file: the next job starts from home as (0,0,0).
function T.clearPos()
    local p = T.dataPath(POS_FILE)
    cleared = T.loadPos() or { x = T.pos.x, y = T.pos.y, z = T.pos.z, dir = T.dir }
    if fs.exists(p) then fs.delete(p) end
end

-- Call at the start of a job: the turtle is at home, facing forward.
-- If a saved position says otherwise, returns it instead of resetting so
-- the program can warn the user.
--
-- Where it does reset, the spot the turtle stands on becomes (0,0,0) in a new frame; the
-- map (T.map, if one is kept) is told where that spot was in the old one, so it stays
-- right.  With no saved position (the file was deleted) and no T.clearPos before it,
-- nobody knows where that was, and the map is marked unaligned (T.alignMap).
function T.startAtHome(force)
    local saved = T.loadPos()
    if saved and not force and (saved.x ~= 0 or saved.y ~= 0 or saved.z ~= 0 or saved.dir ~= 0) then
        return saved
    end
    local old = saved or cleared
    cleared = nil
    T.pos.x, T.pos.y, T.pos.z, T.dir = 0, 0, 0, 0
    T.savePos()
    frameMoved(old)
    return nil
end

--------------------------------------------------------------------------
-- The turtle API, wrapped once
--
-- Loading turtlelib replaces turtle.dig/digUp/digDown, place/placeUp/
-- placeDown, forward/back/up/down and turnLeft/turnRight with versions
-- that know which cell they act on (from T.pos and T.dir):
--   * a move or turn that succeeds updates T.pos / T.dir and saves them,
--     so the position is right whatever code made it (a program, or
--     claude's code calling turtle.forward() straight);
--   * a dig into a protected area, or at a chest, barrel, shulker box,
--     spawner or ComputerCraft block, returns false and why;
--   * every successful dig, placement and move is told to the listeners
--     (T.onChange).
-- The originals are kept in T.raw: T.forward and the rest use those, with
-- their own bookkeeping, so nothing is counted twice.
--
-- It happens once per turtle table, however many programs load turtlelib
-- (each program the shell runs, and claude's code, gets a copy of this
-- module of its own, but there is one `turtle`): the first load installs
-- the wrappers and a marker (turtle._ccnixWrap) holding the originals, the
-- listeners and the protected areas; later loads install nothing and take
-- over the marker's owner, the module whose T.pos the wrapped calls
-- update.  The newest load is the owner; T.claim() makes a module the
-- owner again (claude does after running a program).
--------------------------------------------------------------------------
local WRAP_KEY = "_ccnixWrap"
local WRAPPED = { "dig", "digUp", "digDown", "place", "placeUp", "placeDown",
                  "forward", "back", "up", "down", "turnLeft", "turnRight" }

-- Which side of the turtle each digging and placing function acts on, and
-- the inspect that looks at the same side
local DIG_SIDE = { dig = "front", digUp = "up", digDown = "down" }
local PLACE_SIDE = { place = "front", placeUp = "up", placeDown = "down" }
local INSPECT_SIDE = { front = "inspect", up = "inspectUp", down = "inspectDown" }

-- How each move changes the position: dx, dy, dz from the heading
local MOVE_STEP = {
    forward = function() return DX[T.dir], 0, DZ[T.dir] end,
    back    = function() return -DX[T.dir], 0, -DZ[T.dir] end,
    up      = function() return 0, 1, 0 end,
    down    = function() return 0, -1, 0 end,
}
-- ...and how each turn changes the heading
local TURN_BY = { turnRight = 1, turnLeft = 3 }

-- What the dig functions refuse (the checks mine always made for itself):
-- a name that has one of these words in it, or starts with one of these
local NEVER_DIG_WORDS = { "chest", "barrel", "shulker", "spawner" }
local NEVER_DIG_PREFIXES = { "computercraft:" }

local W                                -- the marker: raw, listeners, areas, owner, impl
local raw = {}                         -- the turtle's own functions, as before wrapping
local impl = {}                        -- this module's versions (T.raw's counterpart)

if turtle then
    W = turtle[WRAP_KEY]
    if not W then
        W = { raw = {}, listeners = {} }
        for _, name in ipairs(WRAPPED) do
            if type(turtle[name]) == "function" then
                W.raw[name] = turtle[name]
                -- the installed function hands over to whichever module owns the marker now
                turtle[name] = function(...) return W.impl[name](...) end
            end
        end
        turtle[WRAP_KEY] = W
    end
    raw = W.raw
    W.owner, W.impl = T, impl
    W.areas = nil                      -- (read again from the file: another program may have changed it)
end
-- The turtle's functions as they were before the wrapping: the same ones
-- T.forward, T.digDir and the rest call underneath.  Nothing here tracks
-- the position, checks an area or tells a listener.
T.raw = raw

-- Make this module the one the wrapped turtle functions keep up to date.
-- Loading turtlelib does it already; call it when another program's
-- module may have loaded since (claude, after run_program).
function T.claim()
    if W then W.owner, W.impl = T, impl end
end

-- Call fn(event) for every successful dig, placement and move from now on, by any program on this
-- turtle; event.kind is "dig", "place" or "move", with x, y, z.  Returns a function that removes the
-- listener.
--
-- For "dig", x, y, z is the cell, was the block's name and state the block's state table, as the inspect
-- before it gave them; for "place", x, y, z is the cell and item the name of what was placed, if the slot's
-- details have it; for "move", x, y, z is the cell it arrived at and from = { x, y, z }.
--
-- A listener's error is dropped (except Ctrl+T), so one can't stop the turtle.  Listeners last until the
-- computer restarts: remove yours when the program ends.
function T.onChange(fn)
    if not W then return function() end end
    local list = W.listeners
    list[#list + 1] = fn
    return function()
        for i, f in ipairs(list) do
            if f == fn then table.remove(list, i); return end
        end
    end
end

-- Tell the listeners (if there are any) of an event, built from the
-- fields given.
local function tell(event)
    if not W or not W.listeners[1] then return end
    for _, fn in ipairs({ table.unpack(W.listeners) }) do
        local ok, err = pcall(fn, event)
        if not ok and err == "Terminated" then error(err, 0) end
    end
end

-- The cell the turtle acts on to its front, up or down.
local function targetOf(side)
    local v = T.DELTA[side == "front" and T.dir or side]
    return T.pos.x + v[1], T.pos.y + v[2], T.pos.z + v[3]
end

-- A successful move: T.pos follows, the listeners hear, it's saved.
local function moved(name)
    local dx, dy, dz = MOVE_STEP[name]()
    local from = W and W.listeners[1] and T.here()
    T.pos.x, T.pos.y, T.pos.z = T.pos.x + dx, T.pos.y + dy, T.pos.z + dz
    if from then tell({ kind = "move", x = T.pos.x, y = T.pos.y, z = T.pos.z, from = from }) end
    T.savePos()
end

-- A successful turn.
local function turned(by)
    T.dir = (T.dir + by) % 4
    T.savePos()
end

-- onOk() if the call's first result is true; the results as they were.
local function afterwards(onOk, ok, ...)
    if ok then onOk() end
    return ok, ...
end

-- Protected areas, as a list of { name, x1, y1, z1, x2, y2, z2 } (the
-- corners in order, low to high).  The list is the marker's, read from
-- the data file the first time it's needed, so every program has the
-- same one; a line of the file is "x1 y1 z1 x2 y2 z2 name" (the name may
-- have spaces).
local PROTECT_FILE = ".protected"

local function areas()
    if W and W.areas then return W.areas end
    local list = {}
    if W then W.areas = list end
    local data = fileio.read(T.dataPath(PROTECT_FILE))
    for _, line in ipairs(data and text.lines(data) or {}) do
        local w = text.words(line)
        local n, name = {}, text.afterWords(line, 6)
        for i = 1, 6 do n[i] = convert.toInteger(w[i]) end
        if name and n[1] and n[2] and n[3] and n[4] and n[5] and n[6] then
            list[#list + 1] = { name = name, n[1], n[2], n[3], n[4], n[5], n[6] }
        end
    end
    return list
end

-- Write the list back to the file (or delete it when empty); true, or nil
-- and why.
local function saveAreas(list)
    local path = T.dataPath(PROTECT_FILE)
    if #list == 0 then
        if fs.exists(path) then fs.delete(path) end
        return true
    end
    local lines = {}
    for _, a in ipairs(list) do
        lines[#lines + 1] = string.format("%d %d %d %d %d %d %s", a[1], a[2], a[3], a[4], a[5], a[6], a.name)
    end
    return fileio.write(path, table.concat(lines, "\n") .. "\n")
end

local function isWhole(n) return type(n) == "number" and n == math.floor(n) end

-- Protect the box between two corners (x, y, z in the turtle's frame, either order) under `name`:
-- a dig into it returns false, "protected: <name>".  Replaces a box of the same name.  Returns true,
-- or nil and why.
function T.protect(name, x1, y1, z1, x2, y2, z2)
    if type(name) ~= "string" or name == "" or text.contains(name, "\n") then
        return nil, "an area needs a name (one line of text)"
    end
    local corners = { x1, y1, z1, x2, y2, z2 }
    for i = 1, 6 do
        if not isWhole(corners[i]) then return nil, "an area's corners are x1, y1, z1, x2, y2, z2: whole numbers" end
    end
    local list = areas()
    local area = { name = name, math.min(x1, x2), math.min(y1, y2), math.min(z1, z2),
                   math.max(x1, x2), math.max(y1, y2), math.max(z1, z2) }
    local at = #list + 1
    for i, a in ipairs(list) do
        if a.name == name then at = i end
    end
    list[at] = area
    local ok, err = saveAreas(list)
    if not ok then return nil, "couldn't save the protected areas: " .. tostring(err) end
    return true
end

-- Remove the area called `name`.  True, or false and why (none by that name).
function T.unprotect(name)
    local list = areas()
    for i, a in ipairs(list) do
        if a.name == name then
            table.remove(list, i)
            local ok, err = saveAreas(list)
            if not ok then return false, "couldn't save the protected areas: " .. tostring(err) end
            return true
        end
    end
    return false, "no protected area called " .. tostring(name)
end

-- The name of the first protected area that holds the cell, or nil.
-- `skip`, a name, leaves that area out (see T.guarded).
function T.protected(x, y, z, skip)
    for _, a in ipairs(areas()) do
        if a.name ~= skip and x >= a[1] and x <= a[4] and y >= a[2] and y <= a[5] and z >= a[3] and z <= a[6] then
            return a.name
        end
    end
end

-- The protected areas, as a list of { name, x1, y1, z1, x2, y2, z2 }
-- (copies: changing one changes nothing).
function T.protections()
    local out = {}
    for i, a in ipairs(areas()) do
        out[i] = { name = a.name, x1 = a[1], y1 = a[2], z1 = a[3], x2 = a[4], y2 = a[5], z2 = a[6] }
    end
    return out
end

-- The name of the protected area that stops the current job from digging
-- the cell: T.protected, but not counting the area the job is working
-- inside (T.cfg.inside, set by T.inside).  nil if none.
function T.guarded(x, y, z)
    return T.protected(x, y, z, T.cfg.inside)
end

-- Run fn(...) as a job that owns the protected area `name`: digging in it
-- is allowed meanwhile (other areas still hold).  Puts back what was set
-- before, even if fn errors (the error is re-thrown); returns what fn
-- returned.
function T.inside(name, fn, ...)
    local before = T.cfg.inside
    T.cfg.inside = name
    local res = table.pack(pcall(fn, ...))
    T.cfg.inside = before
    if not res[1] then error(res[2], 0) end
    return table.unpack(res, 2, res.n)
end

-- Is this block one the dig functions refuse (a container, spawner or
-- ComputerCraft block)?  mine's own list of blocks never to dig.
function T.neverDig(name)
    for _, word in ipairs(NEVER_DIG_WORDS) do
        if text.contains(name, word) then return true end
    end
    for _, prefix in ipairs(NEVER_DIG_PREFIXES) do
        if text.startsWith(name, prefix) then return true end
    end
    return false
end

-- The wrapped digs: refuse what's protected, look at what's there (the
-- listeners are told it), then dig (with the tool side the caller named,
-- if any).
for name, side in pairs(DIG_SIDE) do
    impl[name] = function(...)
        local x, y, z = targetOf(side)
        local area = T.guarded(x, y, z)
        if area then return false, "protected: " .. area end
        local inspect = turtle[INSPECT_SIDE[side]]
        local ok, data = false, nil
        if inspect then ok, data = inspect() end
        if ok and type(data) == "table" and data.name and not T.cfg.digContainers and T.neverDig(data.name) then
            return false, "won't dig " .. data.name .. " (set T.cfg.digContainers = true to allow it)"
        end
        return afterwards(function()
            if W and W.listeners[1] then
                tell({ kind = "dig", x = x, y = y, z = z,
                       was = ok and data and data.name or nil, state = ok and data and data.state or nil })
            end
        end, raw[name](...))
    end
end

-- The wrapped placements: place, then tell the listeners what went where.
for name, side in pairs(PLACE_SIDE) do
    impl[name] = function(...)
        local x, y, z = targetOf(side)
        local item
        if W and W.listeners[1] and turtle.getItemDetail then
            local it = turtle.getItemDetail(turtle.getSelectedSlot())
            item = it and it.name
        end
        return afterwards(function()
            tell({ kind = "place", x = x, y = y, z = z, item = item })
        end, raw[name](...))
    end
end

-- The wrapped moves and turns: keep the position.
for name in pairs(MOVE_STEP) do
    impl[name] = function() return afterwards(function() moved(name) end, raw[name]()) end
end
for name, by in pairs(TURN_BY) do
    impl[name] = function() return afterwards(function() turned(by) end, raw[name]()) end
end

-- Turn a quarter turn to the right, keeping T.dir and the saved position right.
function T.turnRight() raw.turnRight(); turned(1) end
-- Turn a quarter turn to the left, keeping T.dir and the saved position right.
function T.turnLeft()  raw.turnLeft();  turned(3) end

-- Turn to face heading d (0 to 3, as T.dir) by the shorter way.
function T.face(d)
    if T.dir == d then return end
    if (T.dir + 1) % 4 == d then T.turnRight()
    elseif (T.dir + 3) % 4 == d then T.turnLeft()
    else T.turnRight(); T.turnRight() end
end

-- Face toward an adjacent column.
function T.faceToward(x, z)
    local dx, dz = x - T.pos.x, z - T.pos.z
    if dz == 1 then T.face(0) elseif dx == 1 then T.face(1)
    elseif dz == -1 then T.face(2) else T.face(3) end
end

-- The position as "(x,y,z)".
function T.posString()
    return string.format("(%d,%d,%d)", T.pos.x, T.pos.y, T.pos.z)
end

-- The heading is really d (a program worked it out from what's round the
-- turtle: the saved one can be off after a stop between a turn and its
-- save, or a turtle put back by hand).
--
-- That turns the frame the turtle counts in about where it stands, so the map (T.map, if
-- one is kept) is told.
function T.setDir(d)
    if d ~= T.dir then
        frameMoved({ x = T.pos.x, y = T.pos.y, z = T.pos.z, dir = T.dir }, { x = T.pos.x, y = T.pos.y, z = T.pos.z, dir = d })
    end
    T.dir = d
    T.savePos()
end

-- What's beside the turtle, by quarter turns to the right of the way it faces:
-- seen[a] is the inspect data at a turns, or false for air.
--
-- For checking the heading, so it turns with the raw turtle calls (which leave
-- it facing as it was) and T.dir isn't touched.
function T.lookAround()
    local seen = {}
    for a = 0, 3 do
        local ok, data = turtle.inspect()
        seen[a] = ok and data or false
        raw.turnRight()
    end
    return seen
end

--------------------------------------------------------------------------
-- Fuel
--------------------------------------------------------------------------
-- Is there fuel for n moves?  (Always, with fuel turned off.)
function T.hasFuel(n)
    local level = turtle.getFuelLevel()
    return level == "unlimited" or level >= n
end

-- Burn fuel from the inventory until the tank holds `target`.  Only what
-- T.fuel lists is burnt: logs, planks, sticks, chests and crafting tables
-- burn too, but they're what chests and torches are made from.
function T.refuelTo(target)
    if turtle.getFuelLevel() == "unlimited" then return true end
    if turtle.getFuelLevel() >= target then return true end
    local sel = turtle.getSelectedSlot()
    for slot = 1, 16 do
        local it = turtle.getItemDetail(slot)
        if it and T.fuel[it.name] then
            turtle.select(slot)
            if turtle.refuel(0) then
                while turtle.getFuelLevel() < target and turtle.refuel(1) do end
            end
        end
        if turtle.getFuelLevel() >= target then break end
    end
    turtle.select(sel)
    return turtle.getFuelLevel() >= target
end

-- Fuel to get home from here: straight-line moves by default.  Programs
-- that travel at a set height or dig down to a chest override it.
function T.homeCost()
    return math.abs(T.pos.x) + math.abs(T.pos.y) + math.abs(T.pos.z)
end

-- Set by a program: function() that goes home, refuels and comes back to
-- exactly where it was (see ensureFuel).
T.fuelTrip = nil
local onFuelTrip = false

-- Called before every move: when the tank is short of the trip home plus T.cfg.fuelMargin, tops it
-- up from the inventory; if that isn't enough, runs T.fuelTrip, else waits for the user once truly out.
--
-- On the trip itself, or with no T.fuelTrip set, it waits for the user once truly out, rather than
-- starting another trip.
function T.ensureFuel()
    local level = turtle.getFuelLevel()
    if level == "unlimited" then return end
    local need = T.cfg.lowFuel
    if onFuelTrip then need = 1                 -- budgeted for already: just don't stall
    elseif T.fuelTrip then need = math.max(need, T.homeCost() + T.cfg.fuelMargin) end
    if level >= need then return end
    T.refuelTo(math.max(need, T.cfg.topupFuel))
    if turtle.getFuelLevel() >= need then return end
    if T.fuelTrip and not onFuelTrip then
        onFuelTrip = true
        local ok, err = pcall(T.fuelTrip)
        onFuelTrip = false
        if not ok then error(err, 0) end
        if turtle.getFuelLevel() >= T.cfg.lowFuel then return end
    end
    while not T.refuelTo(T.cfg.topupFuel) and turtle.getFuelLevel() < need do
        print("Out of fuel at " .. T.posString() .. ". Add fuel, then press a key.")
        os.pullEvent("key")
    end
end

-- Fuel in tank plus the fuel value of the T.fuel items in the inventory.
-- Burns nothing.
function T.totalFuelAvailable()
    if turtle.getFuelLevel() == "unlimited" then return math.huge end
    local total = turtle.getFuelLevel()
    for slot = 1, 16 do
        local it = turtle.getItemDetail(slot)
        if it and T.fuel[it.name] then total = total + (T.FUEL_VALUE[it.name] or 80) * it.count end
    end
    return total
end

-- Block until at least `needed` fuel is available (tank + inventory),
-- filling the tank up to `needed` from inventory first.
function T.requireFuel(needed)
    while true do
        T.refuelTo(needed)
        if T.totalFuelAvailable() >= needed then return end
        print(string.format("Need ~%d fuel on board; have %s. Add fuel, then press a key.",
            needed, tostring(turtle.getFuelLevel())))
        os.pullEvent("key")
    end
end

--------------------------------------------------------------------------
-- Tool upgrades
--
-- turtle.dig() with no side tries the LEFT tool first and only falls back
-- to the right if that fails.  With a pickaxe and a hoe both equipped, a
-- left-hand pickaxe will happily break the dirt the hoe was meant to till.
-- So rather than guess sides, usePrimaryTool() makes the program's tool
-- the ONLY tool equipped: any other tool is parked in the inventory for
-- the duration and restored afterwards.  Non-tool upgrades (chunky,
-- modem, ...) are never touched.
--------------------------------------------------------------------------
local TOOL_SUFFIXES = { "_pickaxe", "_hoe", "_shovel", "_axe", "_sword" }

-- Is the item `name` a tool (a pickaxe, hoe, shovel, axe or sword)?
function T.isTool(name)
    if not name then return false end
    for _, suffix in ipairs(TOOL_SUFFIXES) do
        if text.endsWith(name, suffix) then return true end
    end
    return false
end

-- `what`, here and in the inventory helpers below, names an item or is a
-- function(name, item) that picks one.
local function picks(what, it)
    if type(what) == "function" then return what(it.name, it) end
    return it.name == what
end

-- The first empty slot, or nil if there is none.
function T.emptySlot()
    for slot = 1, 16 do
        if turtle.getItemCount(slot) == 0 then return slot end
    end
end

-- The first slot holding `what` (an item name, or a function(name, item) that picks one); nil if none.
function T.findSlot(what)
    for slot = 1, 16 do
        local it = turtle.getItemDetail(slot)
        if it and picks(what, it) then return slot end
    end
end
local findEmptySlot, findItemSlot = T.emptySlot, T.findSlot

local function equipSide(side)
    if side == "left" then return turtle.equipLeft() else return turtle.equipRight() end
end

-- Name of the item equipped on `side`, or nil.  Uses getEquippedLeft/Right
-- (CC:Tweaked 1.110+); older versions are probed by swapping through an
-- empty slot, which needs one free slot.
function T.equipped(side)
    if turtle.getEquippedLeft then
        local it
        if side == "left" then it = turtle.getEquippedLeft() else it = turtle.getEquippedRight() end
        return it and it.name or nil
    end
    local empty = findEmptySlot()
    if not empty then error("Need one empty inventory slot to inspect tool upgrades", 0) end
    local sel = turtle.getSelectedSlot()
    turtle.select(empty)
    local name
    if equipSide(side) then
        local it = turtle.getItemDetail(empty)
        name = it and it.name
        equipSide(side)                   -- put it straight back
    end
    turtle.select(sel)
    return name
end

-- A tool whose name ends with `suffix` ("_pickaxe"): the one equipped,
-- else the first in the inventory; nil if there's none.
function T.findTool(suffix)
    for _, side in ipairs({ "left", "right" }) do
        local name = T.equipped(side)
        if name and text.endsWith(name, suffix) then return name end
    end
    local slot = T.findSlot(function(n) return text.endsWith(n, suffix) end)
    return slot and turtle.getItemDetail(slot).name or nil
end

-- Equip `name` from the inventory if it isn't already, unequip any OTHER
-- tool into the inventory, and return a function that restores the
-- original arrangement.  Errors if the tool is nowhere on the turtle.
function T.usePrimaryTool(name)
    local before = { left = T.equipped("left"), right = T.equipped("right") }
    local sel = turtle.getSelectedSlot()
    local freed

    for _, side in ipairs({ "left", "right" }) do
        local item = before[side]
        if item and item ~= name and T.isTool(item) then
            local empty = findEmptySlot()
            if not empty then error("Need an empty inventory slot to unequip the " .. item, 0) end
            turtle.select(empty)
            equipSide(side)
            freed = freed or side
        end
    end

    if before.left ~= name and before.right ~= name then
        local slot = findItemSlot(name)
        if not slot then
            turtle.select(sel)
            error(name .. " is neither equipped nor in the inventory", 0)
        end
        local side = freed
            or (before.right == nil and "right")
            or (before.left == nil and "left")
        if not side then
            turtle.select(sel)
            error("Both sides hold non-tool upgrades; no room to equip " .. name, 0)
        end
        turtle.select(slot)
        equipSide(side)
    end
    turtle.select(sel)

    return function()
        local cur = turtle.getSelectedSlot()
        for _, side in ipairs({ "left", "right" }) do
            local want = before[side]
            if T.equipped(side) ~= want then
                local slot = want and findItemSlot(want) or findEmptySlot()
                if slot then turtle.select(slot); equipSide(side) end
            end
        end
        turtle.select(cur)
    end
end

-- Run fn with `name` as the only equipped tool, restoring the original
-- tools afterwards even if fn errors (the error is re-thrown).
function T.withTool(name, fn)
    local restore = T.usePrimaryTool(name)
    local ok, err = pcall(fn)
    restore()
    if not ok then error(err, 0) end
end

-- Back-compat: equip `name` onto `side` from the inventory, if present.
function T.equipTool(name, side)
    local slot = findItemSlot(name)
    if not slot then return false end
    local sel = turtle.getSelectedSlot()
    turtle.select(slot)
    local ok = equipSide(side or "right")
    turtle.select(sel)
    return ok
end

--------------------------------------------------------------------------
-- Peripheral upgrades.  A Geo Scanner, a chat box or a crafting table: CC
-- attaches one only while it is equipped, so using one takes a swap in and
-- a swap back.  The upgrade that comes off goes into the slot the new one
-- came from, so no free slot is needed unless the new one is a stack.
-- A chunk controller keeps the chunks round the turtle loaded, so it is
-- never taken off; nor is the upgrade on a side named in T.cfg.keepSide
-- (a side, "left" or "right", or a list of them).
--------------------------------------------------------------------------
local KEEP_UPGRADES = { ["advancedperipherals:chunk_controller"] = true }
local EQUIP_SIDES = { "left", "right" }

-- Is the upgrade `held` on `side` one to leave on?
local function upgradeKept(side, held)
    local keep = T.cfg.keepSide
    if keep == side then return true end
    if type(keep) == "table" then
        for _, s in ipairs(keep) do
            if s == side then return true end
        end
    end
    return held ~= nil and KEEP_UPGRADES[held] == true
end

-- Wait up to two seconds for a peripheral to show up on `side` (an
-- upgrade can take a moment after it is equipped: ask until it has
-- methods).  Returns the wrapped peripheral, or nil.
local function waitForPeripheral(side)
    for _ = 1, 20 do
        if peripheral.getType(side) then
            local methods = peripheral.getMethods(side)
            if methods and #methods > 0 then return peripheral.wrap(side) end
        end
        sleep(0.1)
    end
    return nil
end

-- Equip the item `name` on the side that holds no chunk controller (or kept side), and wait for
-- it to show up.  Returns the peripheral and a function that puts back what was there, or nil and why.
--
-- It prefers an empty side, then one with a tool, then another upgrade.  Call the returned function
-- when done (calling it again does nothing).  The reasons for nil: not on board, a tool rather than a
-- peripheral, both sides kept, no free slot for what comes off, or it never showed up.
function T.equipPeripheral(name)
    if T.isTool(name) then return nil, name .. " is a tool, not a peripheral (T.withTool)" end
    local before = { left = T.equipped("left"), right = T.equipped("right") }
    for _, side in ipairs(EQUIP_SIDES) do
        if before[side] == name then
            local p = waitForPeripheral(side)
            if p then return p, function() return true end end
            return nil, "the " .. name .. " on the " .. side .. " isn't showing up as a peripheral"
        end
    end
    local slot = T.findSlot(name)
    if not slot then return nil, "no " .. name .. " on board" end
    local side, rank
    for _, s in ipairs(EQUIP_SIDES) do
        local held = before[s]
        if not upgradeKept(s, held) then
            local r = held == nil and 0 or (T.isTool(held) and 1 or 2)
            if not rank or r < rank then side, rank = s, r end
        end
    end
    if not side then
        return nil, "both sides hold an upgrade to keep (a chunk controller or T.cfg.keepSide): nowhere to put the " .. name
    end
    local was = before[side]
    if was and turtle.getItemCount(slot) > 1 and not T.emptySlot() then
        return nil, "no free slot for the " .. was .. " that comes off the " .. side
    end
    local sel = turtle.getSelectedSlot()
    turtle.select(slot)
    local ok, err = equipSide(side)
    turtle.select(sel)
    if not ok then return nil, "couldn't equip the " .. name .. (err and (": " .. tostring(err)) or "") end
    local done = false
    -- puts back what was on the side (an empty slot selected takes the
    -- peripheral off when there was nothing); true, or false and why
    local function restore()
        if done then return true end
        done = true
        local cur = turtle.getSelectedSlot()
        local from = was and T.findSlot(was) or T.emptySlot()
        if not from then
            return false, "couldn't put the " .. (was or "empty side") .. " back on the " .. side .. ": it isn't on board"
        end
        turtle.select(from)
        equipSide(side)
        turtle.select(cur)
        return true
    end
    local p = waitForPeripheral(side)
    if not p then
        restore()
        return nil, "the " .. name .. " didn't show up as a peripheral on the " .. side
    end
    return p, restore
end

-- Run fn(peripheral) with the item `name` equipped as a peripheral, and put back
-- what was on that side afterwards.  Returns true and what fn returned, or nil
-- and why it couldn't equip (see T.equipPeripheral).
--
-- The side is put back even if fn errors (the error is re-thrown).
function T.withPeripheral(name, fn)
    local p, restore = T.equipPeripheral(name)
    if not p then return nil, restore end
    local res = table.pack(pcall(fn, p))
    restore()
    if not res[1] then error(res[2], 0) end
    return true, table.unpack(res, 2, res.n)
end

--------------------------------------------------------------------------
-- Low-level moves.  Each keeps T.pos in sync, cuts through T.diggable
-- blocks, attacks mobs, and returns false if blocked by anything else.
--------------------------------------------------------------------------
local function clearWay(inspect, dig)
    local ok, data = inspect()
    if not ok then return true end
    if T.diggable[data.name] then dig(); return true end
    return false
end

-- Move up one block, digging what T.diggable lists and attacking what's in the way (fuel first).
-- True, or false if anything else is in the way or T.cfg.maxHeight is reached.
function T.up()
    if T.pos.y >= T.cfg.maxHeight then return false end
    T.ensureFuel()
    for _ = 1, 5 do
        if not clearWay(turtle.inspectUp, impl.digUp) then return false end
        if raw.up() then moved("up"); return true end
        turtle.attackUp(); sleep(0.3)
    end
    return false
end

-- Move down one block, digging what T.diggable lists and attacking what's in the way (fuel first).
-- True, or false if anything else is in the way or T.cfg.maxDrop is reached.
function T.down()
    if T.pos.y <= -T.cfg.maxDrop then return false end
    T.ensureFuel()
    for _ = 1, 5 do
        if not clearWay(turtle.inspectDown, impl.digDown) then return false end
        if raw.down() then moved("down"); return true end
        turtle.attackDown(); sleep(0.3)
    end
    return false
end

-- Move forward one block, digging what T.diggable lists and attacking what's in the way (fuel first).
-- True, or false if anything else is in the way.
function T.forward()
    T.ensureFuel()
    for _ = 1, 5 do
        if not clearWay(turtle.inspect, impl.dig) then return false end
        if raw.forward() then moved("forward"); return true end
        turtle.attack(); sleep(0.3)
    end
    return false
end

-- Back up a block without turning (saves turning round to go back the
-- way it came).  It can't see or dig behind it: false if anything is
-- there.
function T.back()
    T.ensureFuel()
    if not raw.back() then return false end
    moved("back")
    return true
end

-- Sink until resting on something solid.
function T.settle()
    while T.down() do end
end

-- Climb or sink to height y in the current column.
function T.toY(y)
    while T.pos.y < y and T.up() do end
    while T.pos.y > y and T.down() do end
    return T.pos.y == y
end

-- Return to y = 0.
function T.toStartHeight()
    T.toY(0)
end

-- What is directly below: a block name (or "air"), plus inspect details.
function T.below()
    local ok, d = turtle.inspectDown()
    if not ok then return "air" end
    return d.name, d
end

--------------------------------------------------------------------------
-- Six directions: 0..3 as T.dir (0 = +z ahead, 1 = +x right, 2 = -z,
-- 3 = -x), plus "up" and "down".  Looking, digging, placing or moving in
-- one faces it first (up and down need no turn).  Positions are
-- { x, y, z } tables; T.posKey makes a table key of one (T.ckey does the
-- same for columns).
--------------------------------------------------------------------------
T.DELTA = {
    [0] = { 0, 0, 1 }, [1] = { 1, 0, 0 }, [2] = { 0, 0, -1 }, [3] = { -1, 0, 0 },
    up = { 0, 1, 0 }, down = { 0, -1, 0 },
}
T.OPP = { [0] = 2, [1] = 3, [2] = 0, [3] = 1, up = "down", down = "up" }

-- The direction a side (CC's "front", "top", "bottom", as for chests) is
-- in from the turtle as it faces now.
function T.sideDir(side)
    if side == "top" then return "up" end
    if side == "bottom" then return "down" end
    return T.dir
end

-- A copy of T.pos: { x, y, z }.
function T.here() return { x = T.pos.x, y = T.pos.y, z = T.pos.z } end
-- Is the turtle at p ({ x, y, z })?
function T.at(p) return T.pos.x == p.x and T.pos.y == p.y and T.pos.z == p.z end
-- The key "x,y,z" for a position p.
function T.posKey(p) return p.x .. "," .. p.y .. "," .. p.z end
-- Inverse of posKey: the x, y, z of "x,y,z" (whole numbers, as posKey
-- writes them); nil if k isn't one.
function T.keyPos(k)
    local part = text.split(k, ",", true)
    if #part ~= 3 then return nil end
    return convert.toInteger(part[1]), convert.toInteger(part[2]), convert.toInteger(part[3])
end
-- The taxicab distance between two positions.
function T.dist(a, b) return math.abs(a.x - b.x) + math.abs(a.y - b.y) + math.abs(a.z - b.z) end

-- The block next to the turtle in direction d.
function T.neighbour(d)
    local v = T.DELTA[d]
    return { x = T.pos.x + v[1], y = T.pos.y + v[2], z = T.pos.z + v[3] }
end

-- The direction from the turtle to the block next to it at p.
function T.dirTo(p)
    if p.x > T.pos.x then return 1 elseif p.x < T.pos.x then return 3
    elseif p.y > T.pos.y then return "up" elseif p.y < T.pos.y then return "down"
    elseif p.z > T.pos.z then return 0 else return 2 end
end

-- Face direction d (0 to 3, "up" or "down") and inspect there: returns turtle.inspect's ok, data.
function T.look(d)
    if d == "up" then return turtle.inspectUp() end
    if d == "down" then return turtle.inspectDown() end
    T.face(d)
    return turtle.inspect()
end

-- Face direction d (0 to 3, "up" or "down") and dig there, through the wrapped dig, so a protected
-- area holds.  Returns turtle.dig's results (false and why if it can't).
function T.digDir(d)
    if d == "up" then return impl.digUp() end
    if d == "down" then return impl.digDown() end
    T.face(d)
    return impl.dig()
end

-- Face direction d (0 to 3, "up" or "down") and place the selected item there.  Returns
-- turtle.place's results.
function T.placeDir(d)
    if d == "up" then return impl.placeUp() end
    if d == "down" then return impl.placeDown() end
    T.face(d)
    return impl.place()
end

-- Face direction d (0 to 3, "up" or "down") and attack there.  Returns turtle.attack's results.
function T.attackDir(d)
    if d == "up" then return turtle.attackUp() end
    if d == "down" then return turtle.attackDown() end
    T.face(d)
    return turtle.attack()
end

-- Face direction d (0 to 3, "up" or "down") and pick up items there.  Returns turtle.suck's results.
function T.suckDir(d)
    if d == "up" then return turtle.suckUp() end
    if d == "down" then return turtle.suckDown() end
    T.face(d)
    return turtle.suck()
end

-- Move one block in direction d (T.up/T.down/T.forward: digging what
-- T.diggable allows, attacking what's in the way).
function T.moveDir(d)
    if d == "up" then return T.up() end
    if d == "down" then return T.down() end
    T.face(d)
    return T.forward()
end

--------------------------------------------------------------------------
-- Moving to a cell in three dimensions, and saying why it stopped
--------------------------------------------------------------------------
-- For each axis letter of an order: the position field, and the direction
-- toward more and toward less
local AXIS = { x = { "x", 1, 3 }, y = { "y", "up", "down" }, z = { "z", 0, 2 } }

-- What moveTo goes round by default: lava, fire and doors (a turtle
-- can't open one)
local DEFAULT_AVOID = { "minecraft:lava", "minecraft:flowing_lava", "minecraft:fire", "minecraft:soul_fire", "*_door" }
T.DEFAULT_AVOID = DEFAULT_AVOID           -- (tl.path routes round the same by default)

-- Blocks a turtle moves into without digging them
local FLUID = {
    ["minecraft:water"] = true, ["minecraft:flowing_water"] = true,
    ["minecraft:lava"] = true, ["minecraft:flowing_lava"] = true,
}

-- A test on a block name, from a spec: true (every name), a glob, or a
-- list of globs; anything else (nil, false) matches none.
local function nameTest(spec)
    if spec == true then return function() return true end end
    local globs = type(spec) == "string" and { spec } or type(spec) == "table" and spec or {}
    local tests = {}
    for i, g in ipairs(globs) do tests[i] = glob.compile(g) end
    return function(name)
        for _, test in ipairs(tests) do
            if test(name) then return true end
        end
        return false
    end
end
T.nameTest = nameTest                     -- (tl.path reads opts.dig and opts.avoid the same way)

-- One step in direction d for moveTo: look at what's there; refuse what's
-- to be avoided, dig what may be dug (not what is protected), move,
-- attacking what's in the way.  true, or false, why, the block's name (if
-- a block stopped it) and its cell.
local function stepInto(d, mayDig, avoid)
    local v = T.DELTA[d]
    local cell = { x = T.pos.x + v[1], y = T.pos.y + v[2], z = T.pos.z + v[3] }
    local at = T.posKey(cell)
    local move = (d == "up" or d == "down") and d or "forward"
    local name
    for _ = 1, 6 do
        local ok, data = T.look(d)
        name = ok and type(data) == "table" and data.name or nil
        if name and avoid(name) then return false, "avoiding " .. name .. " at " .. at, name, cell end
        if name and not FLUID[name] then
            if not mayDig(name) then return false, "blocked by " .. name .. " at " .. at, name, cell end
            local area = T.guarded(cell.x, cell.y, cell.z)
            if area then return false, "protected: " .. area .. " (" .. name .. " at " .. at .. ")", name, cell end
            local dug, why = T.digDir(d)
            if not dug then
                return false, "couldn't dig " .. name .. " at " .. at .. (why and (": " .. tostring(why)) or ""), name, cell
            end
        end
        local level = turtle.getFuelLevel()
        if level ~= "unlimited" and level < T.cfg.lowFuel then
            T.refuelTo(T.cfg.topupFuel)
            if turtle.getFuelLevel() < 1 then return false, "out of fuel at " .. T.posString(), nil, T.here() end
        end
        if raw[move]() then moved(move); return true end
        T.attackDir(d)
        sleep(0.3)
    end
    return false, "can't move into " .. at .. (name and (" (" .. name .. ")") or ": something is in the way"), name, cell
end

-- Move to the cell x, y, z (the turtle's frame), digging only what opts.dig
-- allows.  Returns true, or false, why, the block's name and cell where one
-- stopped it.  opts: order, dig, avoid, inside, path.
--
-- It goes along the axes in the order opts.order names (default "yxz": up or
-- down first, then x, then z).  opts (all optional):
--   dig     false (default), true, a glob or a list of globs: the blocks it
--           may dig on the way (a protected area, a chest or a computer is
--           never dug)
--   avoid   a glob or a list: blocks it stops at rather than enter
--           (default: lava, fire and doors); {} avoids nothing
--   inside  the name of a protected area the move may dig in (see T.inside)
--   path    true, or a function(x, y, z, opts): when a straight run is
--           blocked, ask a route finder (T.travel, from the path module, if
--           there is one; or this function) to take it the rest of the way
-- The why is a sentence: "blocked by minecraft:obsidian at 3,12,-4",
-- "protected: castle (...)", "avoiding minecraft:lava at ..."; the cell is
-- { x, y, z }.  The turtle stays wherever it got to.  (T.cfg.maxHeight and maxDrop, a
-- program's grid, don't apply.)
function T.moveTo(x, y, z, opts)
    opts = opts or {}
    for _, n in ipairs({ x, y, z }) do
        if not isWhole(n) then return false, "moveTo wants a cell of whole numbers: x, y, z" end
    end
    local order = opts.order or "yxz"
    for i = 1, #order do
        if not AXIS[order:sub(i, i)] then return false, "the order of axes is letters x, y and z, like \"yxz\"" end
    end
    local want = { x = x, y = y, z = z }
    local mayDig = nameTest(opts.dig)
    local avoid = nameTest(opts.avoid == nil and DEFAULT_AVOID or opts.avoid)
    local function run()
        for i = 1, #order do
            local field, more, less = table.unpack(AXIS[order:sub(i, i)])
            while T.pos[field] ~= want[field] do
                local ok, why, name, cell = stepInto(T.pos[field] < want[field] and more or less, mayDig, avoid)
                if not ok then
                    local finder = type(opts.path) == "function" and opts.path or opts.path and (T.need("travel") or T.need("path"))
                    if finder and name then
                        local routed, noRoute = finder(x, y, z, opts)
                        if routed and T.pos.x == x and T.pos.y == y and T.pos.z == z then return true end
                        if noRoute then why = why .. " (no route: " .. tostring(noRoute) .. ")" end
                    end
                    return false, why, name, cell
                end
            end
        end
        return true
    end
    if opts.inside then return T.inside(opts.inside, run) end
    return run()
end

-- Turns it takes to face direction d (none for up or down).
function T.turnsTo(d)
    if d == "up" or d == "down" or d == T.dir then return 0 end
    return (d - T.dir) % 4 == 2 and 2 or 1
end

-- Call fn(d) with each direction but `skip`, the fewest turns away first
-- (so up and down, and the way it faces, come before any turn).
function T.eachAround(skip, fn)
    local todo = {}
    for _, e in ipairs({ "up", "down", 0, 1, 2, 3 }) do
        if e ~= skip then todo[#todo + 1] = e end
    end
    while #todo > 0 do
        local best = 1
        for i = 2, #todo do
            if T.turnsTo(todo[i]) < T.turnsTo(todo[best]) then best = i end
        end
        fn(table.remove(todo, best))
    end
end

-- A step toward p (nearer by taxicab distance), the one needing the
-- fewest turns; nil when there.
function T.stepToward(p)
    local best
    for _, d in ipairs({ T.dir, "up", "down", 0, 1, 2, 3 }) do
        local n = T.neighbour(d)
        if T.dist(n, p) < T.dist(T.pos, p) and (not best or T.turnsTo(d) < T.turnsTo(best)) then best = d end
    end
    return best
end

--------------------------------------------------------------------------
-- Obstacle map (2D, by column) and BFS routing
--------------------------------------------------------------------------
T.blocked = {}
-- The key "x,z" for a column.
function T.ckey(x, z) return x .. "," .. z end

-- Inverse of ckey: the x, z a key ("x,z") was made from; nils if k isn't one.
function T.keyXZ(k)
    local part = text.split(k, ",", true)
    if #part ~= 2 then return nil, nil end
    return convert.toInteger(part[1]), convert.toInteger(part[2])
end
-- Mark column x, z as blocked, for T.bfs and T.goTo.
function T.markBlocked(x, z) T.blocked[T.ckey(x, z)] = true end
-- Forget every column marked blocked.
function T.clearBlocked() T.blocked = {} end

-- Sign and magnitude of a dimension: sgn(-20) -> -1, 20
local function sgn(n) if n < 0 then return -1, -n else return 1, n end end
T.sgn = sgn

-- Is column x, z inside the routing area (T.cfg.width and length, plus T.cfg.margin)?
function T.inBounds(x, z)
    local c = T.cfg
    local sx, w = sgn(c.width)
    local sz, l = sgn(c.length)
    local u, v = x * sx, z * sz           -- grid coords: 1..w, 1..l inside
    return u >= 1 - c.margin and u <= w + c.margin
       and v >= 1 - c.margin and v <= l + c.margin
end

local NEIGH = { { 0, 1 }, { 1, 0 }, { 0, -1 }, { -1, 0 } }

-- Shortest column path from the current position to (tx,tz), or nil.
--
-- Columns marked blocked are walls, and so are the ones outside the routing area.  A program can also set T.edgeOK to a
-- function(x, z, nx, nz) that says whether the step from column x, z into its neighbour nx, nz may be planned (mow, which
-- knows the height of the ground, refuses a step up or down more than it can make).
function T.bfs(tx, tz)
    local parent = { [T.ckey(T.pos.x, T.pos.z)] = false }
    local queue, head = { { T.pos.x, T.pos.z } }, 1
    while head <= #queue do
        local n = queue[head]; head = head + 1
        local x, z = n[1], n[2]
        if x == tx and z == tz then
            local path, k, node = {}, T.ckey(x, z), n
            while parent[k] do
                table.insert(path, 1, { x = node[1], z = node[2] })
                node = parent[k]; k = T.ckey(node[1], node[2])
            end
            return path
        end
        for _, d in ipairs(NEIGH) do
            local nx, nz = x + d[1], z + d[2]
            local nk = T.ckey(nx, nz)
            if T.inBounds(nx, nz) and parent[nk] == nil and not T.blocked[nk] and (not T.edgeOK or T.edgeOK(x, z, nx, nz)) then
                parent[nk] = n
                queue[#queue + 1] = { nx, nz }
            end
        end
    end
    return nil
end

--------------------------------------------------------------------------
-- Column-stepping strategies.  Each moves one column in the current
-- facing and returns true, or marks that column blocked and returns false.
--------------------------------------------------------------------------

-- Flat: stay at the current height.
function T.stepFlat()
    local nx, nz = T.pos.x + DX[T.dir], T.pos.z + DZ[T.dir]
    if T.forward() then return true end
    T.markBlocked(nx, nz)
    return false
end

-- Terrain: climb up to maxClimb to get in, then sink onto the ground.
-- A drop deeper than maxClimb is a crevasse: back out and mark it.
function T.stepTerrain()
    local startY, startDir = T.pos.y, T.dir
    local nx, nz = T.pos.x + DX[T.dir], T.pos.z + DZ[T.dir]
    local climb = T.cfg.maxClimb
    while true do
        if T.forward() then
            while T.pos.y > startY - climb and T.down() do end
            if turtle.detectDown() then return true end
            -- crevasse: climb back, retreat, record the hole
            while T.pos.y < startY and T.up() do end
            T.face((startDir + 2) % 4)
            T.forward()
            T.face(startDir)
            T.settle()
            T.markBlocked(nx, nz)
            return false
        end
        if T.pos.y - startY >= climb or not T.up() then
            while T.pos.y > startY and T.down() do end
            T.markBlocked(nx, nz)
            return false
        end
    end
end

-- Active stepping strategy; programs set this.
T.step = T.stepFlat

-- Navigate to column (tx,tz) with BFS + re-planning.
function T.goTo(tx, tz)
    for _ = 1, T.cfg.maxReplans do
        if T.pos.x == tx and T.pos.z == tz then return true end
        local path = T.bfs(tx, tz)
        if not path then return false end
        local ok = true
        for _, n in ipairs(path) do
            T.faceToward(n.x, n.z)
            if not T.step() then ok = false; break end   -- obstacle learned
        end
        if ok then return true end
    end
    return false
end

-- Stretch the routing area (cfg.width/length) so it takes in column
-- (x,z) too: a turtle stopped outside it, on a farm bigger than the
-- defaults or one lying left of or behind home, would otherwise have no
-- route at all.
function T.coverColumn(x, z)
    local function cover(dim, p)
        if p == 0 then return dim end
        if (p > 0) ~= (dim > 0) then return p end      -- on the other side of home
        local s = p > 0 and 1 or -1
        return s * math.max(math.abs(dim), math.abs(p))
    end
    T.cfg.width = cover(T.cfg.width, x)
    T.cfg.length = cover(T.cfg.length, z)
end

-- Return to the start from wherever the saved position says we are (used by the `reset` subcommands
-- and home.lua).  Returns true if home.
--
-- In flat mode the trip is made at height opts.travelY (default 0, the start height), e.g. above tall
-- crops.  The routing area is cfg.width/length, stretched to take in the turtle's position.  opts.check, if
-- given, runs once at travel height before setting off (it may correct T.dir); false from it stops the trip.
function T.goHome(opts)
    opts = opts or {}
    local saved = T.loadPos()
    if not saved then
        print("No saved position; the turtle has not moved since its last job, or is already home.")
        return true
    end
    T.pos.x, T.pos.y, T.pos.z, T.dir = saved.x, saved.y, saved.z, saved.dir
    T.mode = saved.mode or "flat"
    T.step = (T.mode == "terrain") and T.stepTerrain or T.stepFlat
    T.clearBlocked()
    T.coverColumn(T.pos.x, T.pos.z)
    print(string.format("Last position %s facing %d (%s). Heading home.", T.posString(), T.dir, T.mode))

    if T.mode == "flat" then T.toY(opts.travelY or 0) end
    if opts.check and not opts.check() then return false end
    local ok = T.goTo(0, 0)
    if T.mode == "flat" then T.toStartHeight() else T.settle() end
    T.face(0)
    if ok and T.pos.x == 0 and T.pos.z == 0 then
        print("Home.")
        T.pos.y = 0
        T.savePos()
        return true
    end
    print("Couldn't reach home; stopped at " .. T.posString())
    return false
end

-- `reset --here`: the turtle was put back by hand, so accept where it is
-- (facing forward) as home without moving.
function T.setHomeHere()
    T.startAtHome(true)
    print("Home set to the current position.")
end

-- Start a job: startAtHome, but when the saved position says the turtle
-- is elsewhere, print the standard warning (naming the program's reset
-- command) and return false so the program can stop.
function T.requireHome(force, prog)
    local stale = T.startAtHome(force)
    if not stale then return true end
    print(string.format("Turtle may not be at home: last saved position (%d,%d,%d).",
        stale.x, stale.y, stale.z))
    print("Run `" .. prog .. " reset` to send it home, or add --here to use this spot as home.")
    return false
end

-- A setting from CC's settings (`sysctl mine.width=5` at the prompt), defined
-- here so `sysctl -d` describes it with its description; its default where there is
-- no settings API.
function T.setting(name, default, description)
    if not settings then return default end
    settings.define(name, { description = description, default = default,
                            type = default ~= nil and type(default) or nil })
    return settings.get(name)
end

-- Keep values given on the command line ({ [name] = value }) as the
-- settings, so the next run without them (or the autostart) uses them.
function T.saveSettings(values)
    if not settings or next(values) == nil then return end
    for _, name in ipairs(tables.sortedKeys(values)) do settings.set(name, values[name]) end
    settings.save()
end

-- A program's options, read by lib/getopt (parseMixed: anywhere among the
-- words).  long names them as getopt's long table does: name = true a
-- flag (--here), name = "=" one that takes a word (--spacing 8, or
-- --spacing=8).  Returns opts (opts.here = true, opts.spacing = "8") and
-- the other words in order, or nil and getopt's message.
--
-- The turtles' words are free: sizes go negative (`mine -3 3 32`, three
-- blocks to the left) and claude's goal is any text, so only the
-- program's own options are options here.  Any other word starting with
-- a dash (-3, -x, --, --foo) is handed to getopt as a stand-in that
-- doesn't, and comes back as itself, an operand (or the word after an
-- option that takes one).
local STAND_IN = "\0"         -- (no word typed at a prompt has a NUL in it)

-- `a` is one of the options in long: "--name" for a flag, "--name" or
-- "--name=word" for one that takes a word
local function isOption(a, long)
    local body = text.stripPrefix(a, "--")
    if not body then return false end
    local name, value = text.cut(body, "=")
    local kind = long[name]
    return kind == "=" or (kind == true and value == nil)
end

-- Parse a program's command-line `args` with lib/getopt, options and operands
-- in any order.  Returns the options table and the operands, or nil and why.
--
-- `long` lists the long options: name = true for a flag, "=" for one with a
-- value.  A dash word that isn't one of them stays an operand.
function T.options(args, long)
    local given, held = {}, {}
    for i, a in ipairs(args) do
        if text.startsWith(a, "-") and not isOption(a, long) then
            given[i] = STAND_IN .. i
            held[given[i]] = a
        else
            given[i] = a
        end
    end
    local opts, operands = getopt.parseMixed(given, "", long)
    if not opts then return nil, operands end
    local function back(w) return held[w] or w end
    for name, v in pairs(opts) do opts[name] = back(v) end
    for i, w in ipairs(operands) do operands[i] = back(w) end
    return opts, operands
end

-- mine's job file (mine.job): "width height length spacing homes state",
-- length 0 for a tunnel with no end.  mine writes it; mine and autostart
-- read it.
local MINE_JOB = "mine.job"

-- The job: { width, height, length (nil: no end), spacing, homes, state },
-- or nil if there's none or it isn't one.
function T.loadMineJob()
    local job = fileio.read(T.dataPath(MINE_JOB))
    if not job then return nil end
    local w = text.words(job)
    local width, height, length = convert.toInteger(w[1]), convert.toInteger(w[2]), convert.toInteger(w[3])
    if not (width and height and length and scan.isUnsigned(w[4]) and scan.isUnsigned(w[5]) and scan.isName(w[6])) then
        return nil
    end
    return { width = width, height = height, length = length ~= 0 and length or nil,
             spacing = convert.toInteger(w[4]), homes = convert.toInteger(w[5]), state = w[6] }
end

-- Save a job as loadMineJob reads it back.
function T.saveMineJob(job)
    fileio.write(T.dataPath(MINE_JOB), string.format("%d %d %d %d %d %s", job.width, job.height,
        job.length or 0, job.spacing, job.homes, job.state))
end

-- Whether a mine.job file is there at all (a job that can't be read
-- still counts: mine was given one).
function T.hasMineJob() return fs.exists(T.dataPath(MINE_JOB)) end

--------------------------------------------------------------------------
-- Plans
--------------------------------------------------------------------------
-- Serpentine over the grid: columns along x, rows alternating in z.
-- Tiles are counted OUT from the start: x = 1..w, z = 1..l (signed), so
-- the start tile (0,0) is never part of the plan.
function T.serpentine(width, length)
    width, length = width or T.cfg.width, length or T.cfg.length
    local sx, w = sgn(width)
    local sz, l = sgn(length)
    local plan = {}
    for i = 1, w do
        if i % 2 == 1 then
            for j = 1, l do plan[#plan + 1] = { x = i * sx, z = j * sz } end
        else
            for j = l, 1, -1 do plan[#plan + 1] = { x = i * sx, z = j * sz } end
        end
    end
    return plan
end

-- Positions for light sources so that every tile of the grid is within taxicab distance `radius`
-- of one.  Returns a set keyed by T.ckey and an ordered list.
--
-- It uses the diamond lattice generated by (r, r+1) and (r+1, -r), which tiles the plane with L1 balls
-- exactly, and clamps lattice points that fall outside the grid onto its edge (which can only shorten
-- their distance to tiles inside).
--
-- Computed on a 0-based grid, then shifted to the 1-based, signed grid the plan uses; the start tile
-- (0,0) is outside it and never gets a torch.
function T.lightLattice(radius, width, length)
    width, length = width or T.cfg.width, length or T.cfg.length
    local sx, sz
    sx, width = sgn(width)
    sz, length = sgn(length)
    local r = radius
    local set, list = {}, {}
    local K = math.ceil((width + length) / r) + 2
    for a = -K, K do
        for b = -K, K do
            local x = a * r + b * (r + 1) + 1
            local z = a * (r + 1) - b * r + 1
            -- L1 distance from the point to the rectangle
            local dx = math.max(0, -x, x - (width - 1))
            local dz = math.max(0, -z, z - (length - 1))
            if dx + dz <= r then
                local cx = math.max(0, math.min(width - 1, x))
                local cz = math.max(0, math.min(length - 1, z))
                cx, cz = (cx + 1) * sx, (cz + 1) * sz
                local k = T.ckey(cx, cz)
                if not set[k] then
                    set[k] = true
                    list[#list + 1] = { x = cx, z = cz }
                end
            end
        end
    end
    return set, list
end

--------------------------------------------------------------------------
-- Inventory
--------------------------------------------------------------------------
-- Select the first slot holding `what` (a name, or a function(name,
-- item)); false if there's none.
function T.selectItem(what)
    local slot = T.findSlot(what)
    if slot then turtle.select(slot) end
    return slot ~= nil
end

-- How many of `what` the turtle carries.
function T.countItem(what)
    local n = 0
    for slot = 1, 16 do
        local it = turtle.getItemDetail(slot)
        if it and picks(what, it) then n = n + it.count end
    end
    return n
end

-- Merge part stacks of the same item, move part stacks into the empty slots ahead of them and
-- select slot 1, so what's picked up next joins its stack.  Returns how many slots it freed.
--
-- Picked-up items go into the first slot, counting on from the selected one, that is empty or holds the
-- same item (CC:Tweaked's InventoryUtil), so an empty slot ahead of a part stack starts a second stack
-- of it.  A move takes as long as a step (a failed one hardly any); with nothing to do it only reads
-- the slots.
function T.tidyInventory()
    local items = {}
    for s = 1, 16 do items[s] = turtle.getItemDetail(s) end
    local before = T.freeSlots()
    local function part(s) return items[s] ~= nil and turtle.getItemSpace(s) > 0 end
    local function move(from, to)
        turtle.select(from)
        turtle.transferTo(to)
        items[from], items[to] = turtle.getItemDetail(from), turtle.getItemDetail(to)
    end
    for a = 1, 15 do
        for b = a + 1, 16 do
            if part(a) and part(b) and items[a].name == items[b].name and items[a].nbt == items[b].nbt then
                move(b, a)
            end
        end
    end
    for e = 1, 15 do
        if not items[e] then
            for p = 16, e + 1, -1 do
                if part(p) then move(p, e); break end
            end
        end
    end
    turtle.select(1)
    return T.freeSlots() - before
end

-- Is every slot taken?
function T.inventoryFull()
    for slot = 1, 16 do
        if turtle.getItemCount(slot) == 0 then return false end
    end
    return true
end

-- How many slots are empty.
function T.freeSlots()
    local n = 0
    for slot = 1, 16 do
        if turtle.getItemCount(slot) == 0 then n = n + 1 end
    end
    return n
end

-- Is the block name a chest or a barrel?
function T.isContainer(name)
    return text.contains(name, "chest") or text.contains(name, "barrel")
end

-- Is there a chest or barrel below the turtle?  (T.containerOn("bottom"))
function T.containerBelow() return T.containerOn("bottom") end

-- What a dump would drop: a list of { slot, n }.  keepCount(item, kept)
-- returns how many of that item to keep (default: all of T.keep items,
-- none of others).
local function dumpPlan(keepCount)
    local plan, kept = {}, {}
    for slot = 1, 16 do
        local it = turtle.getItemDetail(slot)
        if it then
            local keep
            if T.isTool(it.name) then
                keep = it.count                   -- never dump a parked tool
            elseif keepCount then
                keep = keepCount(it, kept[it.name] or 0)
            else
                keep = T.keep[it.name] and it.count or 0
            end
            kept[it.name] = (kept[it.name] or 0) + math.min(keep, it.count)
            if it.count > keep then plan[#plan + 1] = { slot = slot, n = it.count - keep } end
        end
    end
    return plan
end

-- Would dumpDown(keepCount) get rid of anything?
function T.wouldDump(keepCount)
    return #dumpPlan(keepCount) > 0
end

-- Drop inventory into the container below.  Returns false if there is no
-- container below; otherwise true and how many items didn't fit (the
-- container is full).
function T.dumpDown(keepCount)
    if not T.containerBelow() then return false end
    local left = 0
    for _, d in ipairs(dumpPlan(keepCount)) do
        local before = turtle.getItemCount(d.slot)
        turtle.select(d.slot)
        turtle.dropDown(d.n)
        left = left + d.n - (before - turtle.getItemCount(d.slot))
    end
    T.tidyInventory()
    return true, left
end

-- dumpDown, but while the container is full, stop and wait for room,
-- checking every `interval` seconds.  Returns false if there is no
-- container below.
function T.dumpDownWait(keepCount, interval)
    local ok, left = T.dumpDown(keepCount)
    if not ok then return false end
    if left > 0 then
        print(string.format("Chest is full (%d items didn't fit); waiting for room.", left))
        repeat
            sleep(interval or 30)
            ok, left = T.dumpDown(keepCount)
        until not ok or left == 0
        print("Chest has room again; carrying on.")
    end
    return true
end

-- Print one line listing what the turtle is carrying.
function T.inventoryLine(label)
    local counts, order = {}, {}
    for s = 1, 16 do
        local it = turtle.getItemDetail(s)
        if it then
            local name = (text.stripPrefix(it.name, "minecraft:") or it.name)
            if not counts[name] then order[#order + 1] = name; counts[name] = 0 end
            counts[name] = counts[name] + it.count
        end
    end
    local parts = {}
    for _, name in ipairs(order) do parts[#parts + 1] = counts[name] .. " " .. name end
    print(label .. ": " .. (#parts > 0 and table.concat(parts, ", ") or "nothing"))
end

local warnedRoom, dumpFreesNothing = false, false

-- Make sure at least `need` slots are free before working a tile whose drops
-- must not spill, calling goDump() (the trip to the chest) if short.  Returns
-- true, or false once still short (printing `warning` once).
--
-- It only calls goDump when dumping with keepCount would free something, and
-- stops making trips that free nothing (no chest) until slots open up again.
function T.ensureRoom(need, keepCount, goDump, warning)
    T.tidyInventory()
    if T.freeSlots() >= need then dumpFreesNothing = false; return true end
    if not dumpFreesNothing and T.wouldDump(keepCount) then
        local before = T.freeSlots()
        goDump()
        if T.freeSlots() >= need then return true end
        if T.freeSlots() <= before then dumpFreesNothing = true end
    end
    if warning and not warnedRoom then
        warnedRoom = true
        print(warning)
    end
    return false
end

--------------------------------------------------------------------------
-- Containers.  A chest or barrel as a peripheral on one of the turtle's three
-- interaction sides ("front", "top" or "bottom", the CC:Tweaked names for turtle.suck/
-- drop/inspect and their Up/Down variants): counting, tidying, restocking.
-- Everything degrades gracefully when it can't be wrapped (restocking
-- falls back to blind sucking).
--------------------------------------------------------------------------

-- The turtle.suck/drop/inspect triple for a given side.
local function sideFuncs(side)
    if side == "front" then return turtle.suck, turtle.drop, turtle.inspect end
    if side == "top" then return turtle.suckUp, turtle.dropUp, turtle.inspectUp end
    if side == "bottom" then return turtle.suckDown, turtle.dropDown, turtle.inspectDown end
    error("Unknown turtle side (want front/top/bottom): " .. tostring(side), 0)
end

-- Drop up to n items from the selected slot into whatever is on `side`
-- ("front", "top" or "bottom"): turtle.drop's results.
function T.dropSide(side, n) local _, drop = sideFuncs(side); return drop(n) end
-- Pick up up to n items from `side` ("front", "top" or "bottom") into the selected slot.
function T.suckSide(side, n) local suck = sideFuncs(side); return suck(n) end
-- turtle.inspect on `side` ("front", "top" or "bottom"): ok, data.
function T.inspectSide(side) local _, _, inspect = sideFuncs(side); return inspect() end

-- Is there a chest or barrel on `side`?
function T.containerOn(side)
    local ok, data = T.inspectSide(side)
    return ok and T.isContainer(data.name)
end

-- How many of each item the container on `side` holds ({ name = count }),
-- or nil if it can't be read.
function T.containerCounts(side)
    local chest = peripheral and peripheral.wrap(side)
    if not (chest and chest.list) then return nil end
    local n = {}
    for _, it in pairs(chest.list()) do n[it.name] = (n[it.name] or 0) + it.count end
    return n
end

-- How many `name` the container on `side` holds, or nil if it can't be read.
function T.countContainer(side, name)
    local counts = T.containerCounts(side)
    return counts and (counts[name] or 0)
end

-- What kind of thing an item is, for grouping like with like: the last
-- word of its id ("wheat_seeds" -> "seeds", "water_bucket" -> "bucket").
local function itemKind(name)
    local _, id = text.cutLast(name, ":")         -- (the id after the mod's name)
    local _, kind = text.cutLast(id or name, "_")
    kind = kind or id or name                     -- after the last _ or :
    return kind ~= "" and kind or name
end

-- Lay the container out in order, packed against its last slot: by kind,
-- then by item, fullest stack first, so every item's stacks sit together
-- and similar items (all the seeds, all the buckets) side by side.  The
-- empty slots come first: slot 1 is where hoppers fill and the turtle
-- sucks from, so it stays a working slot.  Each stack is given a slot
-- (one already on a slot meant for a stack just like it stays there),
-- then stacks are moved into empty slots meant for them, and when no
-- empty slot is meant for anything, a stack in another's way goes to an
-- empty slot to make one.  A full container has no empty slot, so the
-- turtle holds one of its stacks meanwhile (if it has an empty slot
-- itself) and drops it back into the slot left for it at the end.
local function sortContainer(chest, self, side)
    local size = chest.size()
    local items = chest.list()
    local n = 0
    for _ in pairs(items) do n = n + 1 end
    local held, heldSlot
    if n >= size then
        for s = 1, 16 do
            if turtle.getItemCount(s) == 0 then heldSlot = s; break end
        end
        if not heldSlot then return end
        local suck = sideFuncs(side)
        local sel = turtle.getSelectedSlot()
        turtle.select(heldSlot)
        local took = suck()
        turtle.select(sel)
        if not took then return end
        local d = turtle.getItemDetail(heldSlot)
        held = { name = d.name, nbt = d.nbt or "", count = d.count }
        items = chest.list()
    end
    local stacks, at = { held }, {}         -- at[slot] = the stack in it
    for slot, it in pairs(items) do
        local s = { slot = slot, name = it.name, nbt = it.nbt or "", count = it.count }
        stacks[#stacks + 1] = s
        at[slot] = s
    end
    table.sort(stacks, function(a, b)
        local ka, kb = itemKind(a.name), itemKind(b.name)
        if ka ~= kb then return ka < kb end
        if a.name ~= b.name then return a.name < b.name end
        if a.nbt ~= b.nbt then return a.nbt < b.nbt end
        if a.count ~= b.count then return a.count > b.count end
        return (a.slot or 0) < (b.slot or 0)
    end)
    -- Give each stack its slot: slot base+i gets a stack like stacks[i].
    local function like(s) return s.name .. "|" .. s.nbt .. "|" .. s.count end
    local base = size - #stacks
    local home, wants = {}, {}              -- home[stack] = slot; wants[slot] = stack
    for i, s in ipairs(stacks) do
        local t = base + i
        local o = at[t]
        if o and like(o) == like(s) then home[o], wants[t] = t, o end
    end
    for i, s in ipairs(stacks) do
        local t = base + i
        if not wants[t] then
            for _, c in ipairs(stacks) do
                if not home[c] and like(c) == like(s) then home[c], wants[t] = t, c; break end
            end
        end
    end
    local function move(s, to)
        if chest.pushItems(self, s.slot, s.count, to) ~= s.count then error("chest sort: move failed", 0) end
        at[s.slot] = nil
        s.slot = to
        at[to] = s
    end
    local ok, err = pcall(function()
        while true do
            local filled = false
            for e = 1, size do
                local w = wants[e]
                if not at[e] and w and w ~= held then move(w, e); filled = true; break end
            end
            if not filled then
                -- no empty slot is meant for anything: move a stack that's
                -- in another's way to an empty slot (the held stack's, or
                -- one before the sorted block), freeing the slot it was in
                local blocker
                for e = 1, size do
                    local s = at[e]
                    if s and home[s] ~= e and wants[e] then blocker = s; break end
                end
                if not blocker then return end      -- all in place
                local empty
                for e = 1, size do
                    if not at[e] then empty = e; break end
                end
                if not empty then error("chest sort: no room", 0) end
                move(blocker, empty)
            end
        end
    end)
    if heldSlot then
        local _, drop = sideFuncs(side)
        local sel = turtle.getSelectedSlot()
        turtle.select(heldSlot)
        drop()
        turtle.select(sel)
    end
    if not ok then error(err, 0) end
end

-- Tidy the container on `side`: merge part stacks so everything sits in as few slots as it
-- can, then sort it.
--
-- Hoppers and the turtle's own partial takes leave small stacks scattered about; it fills the
-- earliest part stack from the latest, then sorts (sortContainer).  Uses the container's pushItems.
function T.compactContainer(side)
    local chest = peripheral and peripheral.wrap(side)
    if not (chest and chest.list and chest.pushItems and chest.getItemDetail) then return end
    local self = peripheral.getName(chest)
    pcall(function()
        local groups = {}
        for slot, it in pairs(chest.list()) do
            local key = it.name .. "|" .. (it.nbt or "")
            groups[key] = groups[key] or {}
            table.insert(groups[key], { slot = slot, count = it.count })
        end
        for _, g in pairs(groups) do
            if #g > 1 then
                local max = (chest.getItemDetail(g[1].slot) or {}).maxCount or 64
                local part = {}
                for _, s in ipairs(g) do
                    if s.count < max then part[#part + 1] = s end
                end
                table.sort(part, function(a, b) return a.slot < b.slot end)
                local i, j = 1, #part
                while i < j do
                    local n = chest.pushItems(self, part[j].slot,
                        math.min(max - part[i].count, part[j].count), part[i].slot)
                    if n == 0 then break end
                    part[i].count, part[j].count = part[i].count + n, part[j].count - n
                    if part[j].count == 0 then j = j - 1 end
                    if part[i].count >= max then i = i + 1 end
                end
            end
        end
        sortContainer(chest, self, side)
    end)
end

-- Move a stack of `name` into the container's first slot, where sucking
-- from it takes from.  Whatever is in slot 1 goes to an empty slot, or,
-- with the container full, into an empty turtle slot (taken with `suck`,
-- the turtle.suck for the container's side) that is returned so the
-- caller can put it back.  Returns found, held.
local function frontStack(chest, name, suck)
    local items = chest.list()
    local from
    for slot, it in pairs(items) do
        if it.name == name and (not from or slot < from) then from = slot end
    end
    if not from then return false end
    if from == 1 then return true end
    local self = peripheral.getName(chest)
    local held
    if items[1] then
        local empty
        for s = 2, chest.size() do
            if not items[s] then empty = s; break end
        end
        if empty then
            chest.pushItems(self, 1, 64, empty)
        else
            held = findEmptySlot()
            if not held then return false end
            turtle.select(held)
            suck(64)
        end
    end
    return chest.pushItems(self, from, 64, 1) > 0, held
end

local restockWarned = {}

-- Pull `name` out of the container on `side` until the turtle holds `target`
-- of it (opts: label for messages, quiet, room: free slots to leave, default 1).
--
-- Sucking from a side always takes from the container's first occupied slot
-- regardless of what it is, so with a readable container the wanted stack is
-- moved to the front first (frontStack) and exactly what's needed is taken.
-- Otherwise anything else that comes out is set aside and dropped back once
-- we're done (fuel is kept).
function T.restockFrom(side, name, target, opts)
    opts = opts or {}
    local room = opts.room or 1
    local label = opts.label or name
    local suck, drop = sideFuncs(side)
    if target <= 0 or T.countItem(name) >= target then return end

    local chest = peripheral and peripheral.wrap(side)
    if chest and chest.list then
        local any = false
        for _, it in pairs(chest.list()) do
            if it.name == name then any = true; break end
        end
        if not any then
            local key = side .. "|" .. name
            if not opts.quiet and not restockWarned[key] then
                restockWarned[key] = true
                print("Nothing on the " .. side .. " to restock " .. label:lower() .. " from.")
            end
            return
        end
        restockWarned[side .. "|" .. name] = nil
    end

    local fronted = chest and chest.pushItems and chest.size and pcall(function()
        while T.countItem(name) < target and T.freeSlots() > room do
            local found, held = frontStack(chest, name, suck)
            if not found then break end
            turtle.select(1)
            local got = suck(math.min(64, target - T.countItem(name)))
            if held then turtle.select(held); drop() end
            if not got then break end
        end
    end)

    local junk = {}
    for _ = 1, 54 do                              -- a double chest's worth
        if fronted or T.countItem(name) >= target then break end
        local before = {}
        for s = 1, 16 do before[s] = turtle.getItemCount(s) end
        if T.freeSlots() <= room then break end   -- leave room for drops and tool swaps
        if not suck(64) then break end            -- container empty
        for s = 1, 16 do
            local got = turtle.getItemCount(s) - before[s]
            if got > 0 then
                local it = turtle.getItemDetail(s)
                if it and it.name ~= name and not T.fuel[it.name] then
                    junk[#junk + 1] = { slot = s, n = got }   -- only what came out
                end
            end
        end
    end
    for _, j in ipairs(junk) do
        turtle.select(j.slot)
        drop(j.n)
    end
    -- whole stacks come out, so hand back anything over the target
    local extra = T.countItem(name) - target
    for s = 16, 1, -1 do
        if extra <= 0 then break end
        local it = turtle.getItemDetail(s)
        if it and it.name == name then
            local n = math.min(extra, it.count)
            turtle.select(s)
            drop(n)
            extra = extra - n
        end
    end
    turtle.select(1)
    if not opts.quiet then
        print(string.format("%s on board: %d (target %d)", label, T.countItem(name), target))
    end
end

-- Take `name` from the container on `side` into the turtle's slot `slot`
-- (empty, or holding some of it already) until that slot holds n (at most
-- a stack).  Needs a readable container.  Returns how many the slot holds.
function T.takeInto(side, name, n, slot)
    local suck, drop = sideFuncs(side)
    local chest = peripheral and peripheral.wrap(side)
    if not (chest and chest.list and chest.pushItems and chest.size) then return turtle.getItemCount(slot) end
    for _ = 1, 64 do
        local have = turtle.getItemCount(slot)
        if have >= n then break end
        local found, held = frontStack(chest, name, suck)
        if not found then break end
        turtle.select(slot)
        local got = suck(n - have)
        if held then turtle.select(held); drop() end
        if not got then break end
    end
    turtle.select(1)
    return turtle.getItemCount(slot)
end

-- Take n (default 1) of the item `name` out of the container on `side` ("front", "top" or "bottom") into
-- whatever slots will have it.  Returns how many it got and, when short of n, why.
--
-- A part stack of it is topped up first, else an empty slot is used.  Sucking from a side takes the
-- container's first stack whatever it is, so each time the wanted stack is moved to the front first (as
-- T.takeInto does), and as many stacks are taken as it needs.  Needs a container it can read (a chest or a
-- barrel).  When short of n, why is: no container, none left in it, or no room in the turtle.
function T.pull(side, name, n)
    n = n or 1
    if side ~= "front" and side ~= "top" and side ~= "bottom" then
        return 0, "the side is \"front\", \"top\" or \"bottom\", not " .. tostring(side)
    end
    local suck, drop = sideFuncs(side)
    local chest = peripheral and peripheral.wrap(side)
    if not (chest and chest.list and chest.pushItems and chest.size) then
        return 0, "no container I can read on the " .. side
    end
    local start, sel = T.countItem(name), turtle.getSelectedSlot()
    local why
    local ok, err = pcall(function()
        for _ = 1, 256 do
            local have = T.countItem(name) - start
            if have >= n then return end
            local found, held = frontStack(chest, name, suck)
            if not found then
                why = "the container on the " .. side .. " has no more " .. name
                return
            end
            local into
            for s = 1, 16 do
                local it = turtle.getItemDetail(s)
                if s ~= held and it and it.name == name and turtle.getItemSpace(s) > 0 then into = s; break end
            end
            if not into then
                for s = 1, 16 do
                    if s ~= held and turtle.getItemCount(s) == 0 then into = s; break end
                end
            end
            if not into then
                if held then turtle.select(held); drop() end
                why = "no room in the turtle for " .. name
                return
            end
            turtle.select(into)
            local got = suck(math.min(64, n - have))
            if held then turtle.select(held); drop() end
            if not got then
                why = "couldn't take " .. name .. " from the " .. side
                return
            end
        end
    end)
    turtle.select(sel)
    if not ok then
        if err == "Terminated" then error(err, 0) end
        why = tostring(err)
    end
    local got = T.countItem(name) - start
    if got >= n then return got end
    return got, (why or "short of " .. name) .. " (got " .. got .. " of " .. n .. ")"
end

--------------------------------------------------------------------------
-- Junk.  The library never drops anything on the ground or into lava:
-- what isn't wanted goes into a junk chest (T.setJunkChest), or stays in
-- the turtle.  What counts as junk is everything but what's kept: the
-- items in T.keep (put the job's building materials there), tools, fuel,
-- peripherals and what T.craft made this job.  (A program's own dumping,
-- like mine's bulk chest, is its own: T.dumpDown.)
--------------------------------------------------------------------------
local JUNK_FILE = ".junkchest"
-- The words for the side of a junk chest, as the file keeps them: a
-- heading (T.dir's 0 to 3) or up or down
local JUNK_SIDES = { up = "up", top = "up", down = "down", bottom = "down", [0] = 0, [1] = 1, [2] = 2, [3] = 3 }
-- Not junk by name: a bucket, a crafting table, anything of these mods
local NEVER_JUNK = { ["minecraft:bucket"] = true, ["minecraft:water_bucket"] = true, ["minecraft:crafting_table"] = true }
local NEVER_JUNK_PREFIXES = { "advancedperipherals:", "computercraft:" }
local crafted = {}                         -- what T.craft made this job

-- Remember the junk chest: it stands on `side` of the cell x, y, z (the turtle's
-- frame): "up" or "top", "down" or "bottom", or a heading 0 to 3.  True, or nil
-- and why.
--
-- The heading is T.dir's: 0 is +z, 1 is +x.  Kept in a data file, so every
-- program on the turtle uses the same one.
function T.setJunkChest(x, y, z, side)
    for _, n in ipairs({ x, y, z }) do
        if not isWhole(n) then return nil, "the junk chest's cell is x, y, z: whole numbers" end
    end
    local d = JUNK_SIDES[side]
    if d == nil then return nil, "the junk chest's side is \"up\", \"down\" or a heading 0 to 3, not " .. tostring(side) end
    if not fileio.write(T.dataPath(JUNK_FILE), string.format("%d %d %d %s", x, y, z, tostring(d))) then
        return nil, "couldn't save the junk chest's place"
    end
    return true
end

-- Where the junk chest is, as { x, y, z, side } (side a heading 0 to 3,
-- "up" or "down"), or nil if none is set.
function T.junkChest()
    local line = fileio.read(T.dataPath(JUNK_FILE))
    local w = line and text.words(line) or {}
    local x, y, z = convert.toInteger(w[1]), convert.toInteger(w[2]), convert.toInteger(w[3])
    local d = w[4] == "up" and "up" or w[4] == "down" and "down" or convert.toInteger(w[4])
    if x and y and z and JUNK_SIDES[d] ~= nil then return { x = x, y = y, z = z, side = d } end
    return nil
end

-- The craft module calls this for each item it makes, so it is never
-- junk for the rest of the job (until the computer restarts, or
-- T.clearCrafted()).
function T.markCrafted(name) crafted[name] = true end
-- Forget what T.markCrafted named: the end of a job.
function T.clearCrafted() crafted = {} end

-- Is the item `name` something a turtle needs whatever the job: a tool, fuel, a bucket, a crafting
-- table or a peripheral?  (Never junk, and never put away in a chest by T.stow.)
function T.isEssential(name)
    if T.fuel[name] or T.isTool(name) or NEVER_JUNK[name] then return true end
    for _, prefix in ipairs(NEVER_JUNK_PREFIXES) do
        if text.startsWith(name, prefix) then return true end
    end
    return false
end

-- Is the item `name` junk?  False for what's in T.keep, tools, fuel,
-- buckets, a crafting table, peripherals and what was crafted this job.
function T.isJunk(name)
    return not (T.keep[name] or crafted[name] or T.isEssential(name))
end

-- Go to the junk chest, put every junk stack in it and come back facing as before; nothing is dropped
-- unless a chest is there.  Returns true, items dropped, items left; or false and why.
--
-- It looks at the chest first, and what doesn't fit stays aboard.  With no junk on board it goes
-- nowhere.  The reasons for false: no junk chest set, no way there, no chest there.
function T.dumpJunk()
    local spot = T.junkChest()
    if not spot then return false, "no junk chest set (T.setJunkChest)" end
    local plan = {}
    for slot = 1, 16 do
        local it = turtle.getItemDetail(slot)
        if it and T.isJunk(it.name) then plan[#plan + 1] = { slot = slot, n = it.count } end
    end
    if #plan == 0 then return true, 0, 0 end
    local from, dir, sel = T.here(), T.dir, turtle.getSelectedSlot()
    -- (a second try along the axes the other way round)
    local function go(p)
        if T.moveTo(p.x, p.y, p.z) then return true end
        return T.moveTo(p.x, p.y, p.z, { order = "xzy" })
    end
    local ok, why = go(spot)
    if not ok then
        go(from); T.face(dir)
        return false, "can't get to the junk chest: " .. tostring(why)
    end
    local side = spot.side == "up" and "top" or spot.side == "down" and "bottom" or "front"
    if side == "front" then T.face(spot.side) end
    if not T.containerOn(side) then
        go(from); T.face(dir)
        return false, "no chest at the junk chest's place: on the " .. side .. " of " .. T.posKey(spot)
    end
    local dropped, left = 0, 0
    for _, j in ipairs(plan) do
        local before = turtle.getItemCount(j.slot)
        turtle.select(j.slot)
        T.dropSide(side, j.n)
        local gone = before - turtle.getItemCount(j.slot)
        dropped, left = dropped + gone, left + j.n - gone
    end
    turtle.select(sel)
    local back, why2 = go(from)
    T.face(dir)
    if not back then return false, "put " .. dropped .. " junk in the chest but can't get back: " .. tostring(why2) end
    return true, dropped, left
end

-- Burn fuel from the container on `side` until the tank holds `target`, fuel on board first; empty
-- buckets go back in.  True if the target was reached.
--
-- It takes one item of a kind to learn what it's worth, then only as many as are needed (capped at
-- the tank's limit).
function T.refuelFrom(side, target)
    if turtle.getFuelLevel() == "unlimited" then return true end
    target = math.min(target, turtle.getFuelLimit())
    local _, drop = sideFuncs(side)
    local buckets = T.countItem("minecraft:bucket")
    T.refuelTo(target)
    for name in pairs(T.fuel) do
        local per
        while turtle.getFuelLevel() < target and (T.countContainer(side, name) or 1) > 0 do
            local want = per and math.ceil((target - turtle.getFuelLevel()) / per) or 1
            local have = T.countItem(name)
            T.restockFrom(side, name, have + want, { quiet = true, room = 0 })
            if T.countItem(name) == have then break end
            local before = turtle.getFuelLevel()
            local sel = turtle.getSelectedSlot()
            for s = 1, 16 do
                local it = turtle.getItemDetail(s)
                if it and it.name == name then
                    turtle.select(s)
                    while turtle.getFuelLevel() < target and turtle.refuel(1) do end
                end
            end
            turtle.select(sel)
            if turtle.getFuelLevel() == before then break end
            per = per or (turtle.getFuelLevel() - before)
        end
    end
    local sel = turtle.getSelectedSlot()
    for s = 16, 1, -1 do
        if T.countItem("minecraft:bucket") <= buckets then break end
        local it = turtle.getItemDetail(s)
        if it and it.name == "minecraft:bucket" then
            turtle.select(s)
            drop(math.min(it.count, T.countItem("minecraft:bucket") - buckets))
        end
    end
    turtle.select(sel)
    return turtle.getFuelLevel() >= target
end

--------------------------------------------------------------------------
-- Modules loaded when first used.  The big parts of the library (the map,
-- routes, building, crafting, ...) live beside this file, in turtle/tl/,
-- as modules named "tl.<name>" (Lua's require turns the dot into a
-- folder, and ccnix's boot has turtle/ on the path).  T.registry says
-- which module defines each function T doesn't have: { craft =
-- "tl.craft" }.  Using T.craft the first time requires that module, which
-- does `local T = require("turtlelib")` (it is handed this very T, loaded
-- already) and adds its functions to it; later uses are plain lookups.  A
-- program that never crafts never loads the recipes.
--
-- A module loads in this module's own world, as turtlelib does: the real
-- fs, io and require (in claude too: the guarded fs and io are only the
-- model's code's).  Each copy of turtlelib loads its own copy of a module,
-- as each program has its own require.
--------------------------------------------------------------------------
T.registry = {
    -- tl.world: the map, the frames and the scanner
    map = "tl.world", scan = "tl.world", scanBox = "tl.world", inspectAt = "tl.world", inspectAll = "tl.world",
    setOrigin = "tl.world", origin = "tl.world", toWorld = "tl.world", toLocal = "tl.world",
    alignMap = "tl.world", frameChanged = "tl.world", mergeScan = "tl.world",
    -- tl.path: routes
    path = "tl.path", travel = "tl.path",
    -- tl.place: blocks placed with the state wanted, and fire
    placeAt = "tl.place", ignite = "tl.place", placeInfo = "tl.place",
    -- tl.blueprint: building from a plan, checking it, swapping blocks
    blueprint = "tl.blueprint", build = "tl.blueprint", verify = "tl.blueprint", replace = "tl.blueprint",
    -- tl.craft: recipes, crafting from a chest, and smelting
    craft = "tl.craft", canCraft = "tl.craft", recipe = "tl.craft", addRecipe = "tl.craft",
    smelt = "tl.craft", fuelTicks = "tl.craft", smeltsTo = "tl.craft",
    -- tl.store: the chests at home, what is in them, putting away and fetching
    addChest = "tl.store", forgetChest = "tl.store", chests = "tl.store", catalogue = "tl.store", where = "tl.store",
    fetch = "tl.store", stow = "tl.store", autoDump = "tl.store",
    -- tl.harvest: blocks by name, fuel from lava, and what a job will cost in fuel
    harvest = "tl.harvest", refuelFromLava = "tl.harvest", fuelFor = "tl.harvest",
    -- tl.journal: the job journal, the undo journal and reports to the player
    job = "tl.journal", report = "tl.journal", undo = "tl.journal", undoMark = "tl.journal", undoClear = "tl.journal",
}
local loadingModule = {}

-- The function T.<name>: as it is, or from the module the registry names,
-- loading that first.  Returns it, or nil and why (not a function of T,
-- or its module wouldn't load or lacks it).
function T.need(name)
    local f = rawget(T, name)
    if f ~= nil then return f end
    local mod = T.registry[name]
    if not mod then return nil, "turtlelib has no " .. tostring(name) end
    if loadingModule[mod] then return nil, mod .. " is loading: T." .. name .. " isn't defined yet" end
    loadingModule[mod] = true
    local owner, was = package.loaded.turtlelib, package.loaded[mod]
    package.loaded.turtlelib, package.loaded[mod] = T, nil
    local ok, err = pcall(require, mod)
    package.loaded.turtlelib = owner
    if not ok then package.loaded[mod] = was end
    loadingModule[mod] = nil
    if not ok then
        if err == "Terminated" then error(err, 0) end
        -- (require lists every place it looked: the first line says enough)
        return nil, "T." .. name .. " is in " .. mod .. ", which didn't load: " .. text.split(tostring(err), "\n", true)[1]
    end
    f = rawget(T, name)
    if f == nil then return nil, mod .. " loaded but doesn't define T." .. name end
    return f
end

-- A name T lacks that the registry knows is that module's function; one
-- whose module won't load becomes a function that raises the reason when
-- called, rather than "attempt to call a nil value".
setmetatable(T, { __index = function(_, name)
    if T.registry[name] == nil then return nil end
    local f, why = T.need(name)
    if f then return f end
    return function() error(why, 2) end
end })

-- T.cfg.autoDump = true (or a number of free slots) turns on the store module's dumping when the
-- inventory nearly fills, and T.cfg.undo = true the journal's record of every dig and placement; a
-- program only sets them, so setting one the first time loads the module.
setmetatable(T.cfg, { __newindex = function(cfg, key, value)
    rawset(cfg, key, value)
    if key == "autoDump" and value then pcall(T.need, "autoDump") end
    if key == "undo" and value then pcall(T.need, "undo") end
end })

-- A map on disk is kept right by every program that digs, places or moves, so its module
-- listens from the start (without a map, nothing is loaded).
if turtle and fs and fs.exists(T.dataPath(T.MAP_DIR)) then pcall(T.need, "map") end

return T
