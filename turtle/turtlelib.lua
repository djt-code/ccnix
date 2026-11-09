-- turtlelib.lua -- shared helpers for the turtle programs
--
-- Usage in a program (same directory):
--     local T = require("turtlelib")
--
-- Provides:
--   * dead-reckoned position/heading (T.pos, T.dir, T.face)
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
--   * reading item names and saved files without Lua patterns
--     (T.startsWith, T.endsWith, T.words, T.isInteger ...)
--
-- Programs configure it by setting fields on T.cfg and T.diggable before
-- moving.  Everything is relative to where the turtle starts: (0,0,0)
-- facing +z, with +x to its right.

local T = {}

--------------------------------------------------------------------------
-- Reading names and the saved files: a few of lib/scan's helpers, kept
-- here so turtlelib needs nothing beside it (a turtle may have turtle/
-- and no lib/).  Plain comparisons, no Lua patterns.
--------------------------------------------------------------------------
function T.startsWith(s, prefix) return s:sub(1, #prefix) == prefix end
function T.endsWith(s, suffix) return suffix == "" or s:sub(-#suffix) == suffix end

-- s without prefix, if it starts with it: dropPrefix("minecraft:wheat", "minecraft:") is "wheat"
function T.dropPrefix(s, prefix)
    if T.startsWith(s, prefix) then return s:sub(#prefix + 1) end
    return s
end

-- the blanks Lua's %s knows: space, \t \n \v \f \r (bytes 9 to 13)
local function isBlank(c)
    local b = c:byte()
    return b == 32 or (b ~= nil and b >= 9 and b <= 13)
end

-- s without the blanks at either end
function T.trim(s)
    local from, to = 1, #s
    while from <= to and isBlank(s:sub(from, from)) do from = from + 1 end
    while to >= from and isBlank(s:sub(to, to)) do to = to - 1 end
    return s:sub(from, to)
end

-- the words of s between blanks, as a list
function T.words(s)
    local out, i = {}, 1
    while i <= #s do
        if isBlank(s:sub(i, i)) then
            i = i + 1
        else
            local j = i
            while j <= #s and not isBlank(s:sub(j, j)) do j = j + 1 end
            out[#out + 1] = s:sub(i, j - 1)
            i = j
        end
    end
    return out
end

-- true if every character of s (one at least) passes test
local function allOf(s, test)
    if s == nil or s == "" then return false end
    for i = 1, #s do
        if not test(s:sub(i, i)) then return false end
    end
    return true
end
local function isDigit(c) return c >= "0" and c <= "9" end
local function isLetter(c) return (c >= "a" and c <= "z") or (c >= "A" and c <= "Z") end

-- digits only: "12"; false for "", nil, "-3" and "1.5"
function T.isDigits(s) return allOf(s, isDigit) end
-- a whole number: digits, a - before them or not
function T.isInteger(s)
    if s ~= nil and s:sub(1, 1) == "-" then s = s:sub(2) end
    return T.isDigits(s)
end
-- letters only: "flat"
function T.isLetters(s) return allOf(s, isLetter) end

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

-- Path for a data file kept next to the running program.  The programs
-- moved from the repo's top folder into turtle/ on 2026-10-28; a file
-- left up there (a job half done) is moved down the first time it's asked
-- for, so `--resume` and `reset` still find it.  A program in ccnix's ROM
-- (/rom/ccnix/turtle) keeps its files in /ccnix/turtle, where its updates
-- go too (the ROM is read-only); one from an install before ccnix
-- (/cc-turtles/turtle) is moved there the same way.
function T.dataPath(name)
    local prog = shell and shell.getRunningProgram and shell.getRunningProgram() or ""
    local dir = fs.getDir(prog)
    if dir:sub(1, 4) == "rom/" then
        dir = dir:sub(5)
        if not fs.exists(dir) then fs.makeDir(dir) end
    end
    local path = fs.combine(dir, name)
    local old = fs.combine(fs.getDir(dir), name)
    if dir == "ccnix/turtle" and not fs.exists(old) then old = fs.combine("cc-turtles/turtle", name) end
    if T.endsWith("/" .. dir, "/turtle") and not fs.exists(path) and fs.exists(old) then fs.move(old, path) end
    return path
end

local POS_FILE = ".turtlepos"

-- Ctrl+T while a program runs under T.run: held back during a turtle
-- command, and raised here, once the move or turn is saved.
T.stopping = false

function T.savePos()
    local f = fs.open(T.dataPath(POS_FILE), "w")
    if not f then return end
    f.write(string.format("%d %d %d %d %s", T.pos.x, T.pos.y, T.pos.z, T.dir, T.mode))
    f.close()
    if T.stopping then
        T.stopping = false
        error("Terminated", 0)
    end
end

-- Run fn(...) so that Ctrl+T can't leave the saved position wrong.  Plain
-- Ctrl+T stops a program wherever it's waiting, in the middle of a turtle
-- command too: the turtle still moves or turns, but the program never
-- records it, so its saved position or heading is off by one and going
-- home from there goes astray.  Under T.run a Ctrl+T that comes during a
-- command (or a peripheral call) is held back until it's done: the
-- program stops at the next saved move or turn (T.savePos), or the next
-- ordinary wait (sleep, a key), whichever comes first.
local COMMAND_EVENTS = { turtle_response = true, task_complete = true }
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

-- Returns the saved position table or nil.
function T.loadPos()
    local p = T.dataPath(POS_FILE)
    if not fs.exists(p) then return nil end
    local f = fs.open(p, "r")
    local line = f.readAll() or ""
    f.close()
    -- "x y z dir mode", as savePos writes it: three whole numbers, a digit, a word
    local w = T.words(line)
    local x, y, z, d, mode = w[1], w[2], w[3], w[4], w[5]
    if not (T.isInteger(x) and T.isInteger(y) and T.isInteger(z) and T.isDigits(d) and #d == 1
            and T.isLetters(mode)) then
        return nil
    end
    return { x = tonumber(x), y = tonumber(y), z = tonumber(z), dir = tonumber(d), mode = mode }
end

function T.clearPos()
    local p = T.dataPath(POS_FILE)
    if fs.exists(p) then fs.delete(p) end
end

-- Call at the start of a job: the turtle is at home, facing forward.
-- If a saved position says otherwise, returns it instead of resetting so
-- the program can warn the user.
function T.startAtHome(force)
    local saved = T.loadPos()
    if saved and not force and (saved.x ~= 0 or saved.y ~= 0 or saved.z ~= 0 or saved.dir ~= 0) then
        return saved
    end
    T.pos.x, T.pos.y, T.pos.z, T.dir = 0, 0, 0, 0
    T.savePos()
    return nil
end

function T.turnRight() turtle.turnRight(); T.dir = (T.dir + 1) % 4; T.savePos() end
function T.turnLeft()  turtle.turnLeft();  T.dir = (T.dir + 3) % 4; T.savePos() end

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

function T.posString()
    return string.format("(%d,%d,%d)", T.pos.x, T.pos.y, T.pos.z)
end

-- The heading is really d (a program worked it out from what's round the
-- turtle: the saved one can be off after a stop between a turn and its
-- save, or a turtle put back by hand).
function T.setDir(d)
    T.dir = d
    T.savePos()
end

-- What's beside the turtle, by quarter turns to the right of the way it
-- faces: seen[a] is the inspect data at a turns, or false for air.  For
-- checking the heading, so it turns with the raw turtle calls (which
-- leave it facing as it was) and T.dir isn't touched.
function T.lookAround()
    local seen = {}
    for a = 0, 3 do
        local ok, data = turtle.inspect()
        seen[a] = ok and data or false
        turtle.turnRight()
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

-- Called before every move.  Below what it takes to get home (plus
-- cfg.fuelMargin) the tank is topped up from the inventory; when that
-- isn't enough and the program set T.fuelTrip, it runs, so the turtle
-- refuels at home instead of running dry in the field.  Without one, or
-- on the trip itself, it waits for the user once truly out.
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

function T.isTool(name)
    if not name then return false end
    for _, suffix in ipairs(TOOL_SUFFIXES) do
        if T.endsWith(name, suffix) then return true end
    end
    return false
end

-- `what`, here and in the inventory helpers below, names an item or is a
-- function(name, item) that picks one.
local function picks(what, it)
    if type(what) == "function" then return what(it.name, it) end
    return it.name == what
end

-- The first empty slot, or the first holding `what`; nil if none.
function T.emptySlot()
    for slot = 1, 16 do
        if turtle.getItemCount(slot) == 0 then return slot end
    end
end

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
        if name and T.endsWith(name, suffix) then return name end
    end
    local slot = T.findSlot(function(n) return T.endsWith(n, suffix) end)
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
-- Low-level moves.  Each keeps T.pos in sync, cuts through T.diggable
-- blocks, attacks mobs, and returns false if blocked by anything else.
--------------------------------------------------------------------------
local function clearWay(inspect, dig)
    local ok, data = inspect()
    if not ok then return true end
    if T.diggable[data.name] then dig(); return true end
    return false
end

function T.up()
    if T.pos.y >= T.cfg.maxHeight then return false end
    T.ensureFuel()
    for _ = 1, 5 do
        if not clearWay(turtle.inspectUp, turtle.digUp) then return false end
        if turtle.up() then T.pos.y = T.pos.y + 1; T.savePos(); return true end
        turtle.attackUp(); sleep(0.3)
    end
    return false
end

function T.down()
    if T.pos.y <= -T.cfg.maxDrop then return false end
    T.ensureFuel()
    for _ = 1, 5 do
        if not clearWay(turtle.inspectDown, turtle.digDown) then return false end
        if turtle.down() then T.pos.y = T.pos.y - 1; T.savePos(); return true end
        turtle.attackDown(); sleep(0.3)
    end
    return false
end

function T.forward()
    T.ensureFuel()
    for _ = 1, 5 do
        if not clearWay(turtle.inspect, turtle.dig) then return false end
        if turtle.forward() then
            T.pos.x = T.pos.x + DX[T.dir]; T.pos.z = T.pos.z + DZ[T.dir]
            T.savePos()
            return true
        end
        turtle.attack(); sleep(0.3)
    end
    return false
end

-- Back up a block without turning (saves turning round to go back the
-- way it came).  It can't see or dig behind it: false if anything is
-- there.
function T.back()
    T.ensureFuel()
    if not turtle.back() then return false end
    T.pos.x = T.pos.x - DX[T.dir]; T.pos.z = T.pos.z - DZ[T.dir]
    T.savePos()
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

function T.here() return { x = T.pos.x, y = T.pos.y, z = T.pos.z } end
function T.at(p) return T.pos.x == p.x and T.pos.y == p.y and T.pos.z == p.z end
function T.posKey(p) return p.x .. "," .. p.y .. "," .. p.z end
-- Inverse of posKey: the x, y, z of "x,y,z".
function T.keyPos(k)
    local c1 = k:find(",", 1, true)
    local c2 = c1 and k:find(",", c1 + 1, true)
    if not c2 then return nil end
    return tonumber(k:sub(1, c1 - 1)), tonumber(k:sub(c1 + 1, c2 - 1)), tonumber(k:sub(c2 + 1))
end
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

function T.look(d)
    if d == "up" then return turtle.inspectUp() end
    if d == "down" then return turtle.inspectDown() end
    T.face(d)
    return turtle.inspect()
end

function T.digDir(d)
    if d == "up" then return turtle.digUp() end
    if d == "down" then return turtle.digDown() end
    T.face(d)
    return turtle.dig()
end

function T.placeDir(d)
    if d == "up" then return turtle.placeUp() end
    if d == "down" then return turtle.placeDown() end
    T.face(d)
    return turtle.place()
end

function T.attackDir(d)
    if d == "up" then return turtle.attackUp() end
    if d == "down" then return turtle.attackDown() end
    T.face(d)
    return turtle.attack()
end

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
function T.ckey(x, z) return x .. "," .. z end

-- Inverse of ckey: the x, z a key was made from.
function T.keyXZ(k)
    local comma = k:find(",", 1, true)          -- "x,z"
    if not comma then return nil, nil end
    return tonumber(k:sub(1, comma - 1)), tonumber(k:sub(comma + 1))
end
function T.markBlocked(x, z) T.blocked[T.ckey(x, z)] = true end
function T.clearBlocked() T.blocked = {} end

-- Sign and magnitude of a dimension: sgn(-20) -> -1, 20
local function sgn(n) if n < 0 then return -1, -n else return 1, n end end
T.sgn = sgn

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
            if T.inBounds(nx, nz) and parent[nk] == nil and not T.blocked[nk] then
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

-- Return to the start from wherever the saved position says we are.
-- Used by the `reset` subcommands and home.lua.  In flat mode the trip is
-- made at height opts.travelY (default 0, the start height), e.g. above
-- tall crops.  The routing area is cfg.width/length, stretched to take in
-- the turtle's position.  opts.check, if given, runs once at travel height
-- before setting off (it may correct T.dir); false from it stops the trip.
-- Returns true if home.
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

-- The keys of a table, sorted (by `cmp` if given): going over a table
-- with pairs takes a different order every run, so wherever the order
-- shows (which chest stack is taken first, a tie between two targets),
-- this gives the same one each time.
function T.sortedKeys(t, cmp)
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys, cmp)
    return keys
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
    for _, name in ipairs(T.sortedKeys(values)) do settings.set(name, values[name]) end
    settings.save()
end

-- Remove every occurrence of `flag` from an argument list; true if found.
function T.popFlag(args, flag)
    local found = false
    for i = #args, 1, -1 do
        if args[i] == flag then found = true; table.remove(args, i) end
    end
    return found
end

-- Remove the first `flag` and the word after it; that word, or nil when
-- the flag isn't there (a flag with nothing after it stays).
function T.popValue(args, flag)
    for i = 1, #args - 1 do
        if args[i] == flag then
            local v = args[i + 1]
            table.remove(args, i); table.remove(args, i)
            return v
        end
    end
end

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

-- Positions for light sources so that every tile of the grid is within
-- taxicab distance `radius` of one.  Uses the diamond lattice generated by
-- (r, r+1) and (r+1, -r), which tiles the plane with L1 balls exactly, and
-- clamps lattice points that fall outside the grid onto its edge (which can
-- only shorten their distance to tiles inside).  Returns a set keyed by
-- T.ckey plus an ordered list.
-- Computed on a 0-based grid, then shifted to the 1-based, signed grid
-- the plan uses; the start tile (0,0) is outside it and never gets a torch.
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

-- Picked-up items go into the first slot, counting on from the selected
-- one, that is empty or holds the same item (CC:Tweaked's InventoryUtil),
-- so an empty slot ahead of a part stack starts a second stack of it.
-- Merge part stacks of the same item, move part stacks into the empty
-- slots ahead of them, and select slot 1: what's picked up next then
-- joins its stack.  A move takes as long as a step (a failed one hardly
-- any); with nothing to do it only reads the slots.  Returns how many
-- slots it freed.
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

function T.inventoryFull()
    for slot = 1, 16 do
        if turtle.getItemCount(slot) == 0 then return false end
    end
    return true
end

function T.freeSlots()
    local n = 0
    for slot = 1, 16 do
        if turtle.getItemCount(slot) == 0 then n = n + 1 end
    end
    return n
end

function T.isContainer(name)
    return name:find("chest", 1, true) ~= nil or name:find("barrel", 1, true) ~= nil
end

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
            local name = T.dropPrefix(it.name, "minecraft:")
            if not counts[name] then order[#order + 1] = name; counts[name] = 0 end
            counts[name] = counts[name] + it.count
        end
    end
    local parts = {}
    for _, name in ipairs(order) do parts[#parts + 1] = counts[name] .. " " .. name end
    print(label .. ": " .. (#parts > 0 and table.concat(parts, ", ") or "nothing"))
end

-- Make sure at least `need` slots are free before working a tile whose
-- drops must not spill: if short, and dumping with keepCount would free
-- something, call goDump() (the program's trip to its chest).  Prints
-- `warning` once if still short, and stops making trips that free
-- nothing (no chest) until slots open up again.
local warnedRoom, dumpFreesNothing = false, false
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
-- A container as a peripheral on one of the turtle's three interaction
-- sides ("front", "top" or "bottom", the CC:Tweaked names for turtle.suck/
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

-- Drop from, suck into the selected slot, or inspect, on a side.
function T.dropSide(side, n) local _, drop = sideFuncs(side); return drop(n) end
function T.suckSide(side, n) local suck = sideFuncs(side); return suck(n) end
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
    local from = #name
    while from > 0 and name:sub(from, from) ~= "_" and name:sub(from, from) ~= ":" do from = from - 1 end
    local kind = name:sub(from + 1)               -- after the last _ or :
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

-- Tidy the container on `side`: merge part stacks of the same item, so
-- everything sits in as few slots as it can (hoppers and the turtle's own
-- partial takes leave small stacks scattered about), filling the earliest
-- part stack from the latest; then sort it (sortContainer).  Uses the
-- container's pushItems.
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

-- Pull `name` out of the container on `side` until we hold `target` of
-- it.  Sucking from a side always takes from the container's first
-- occupied slot regardless of what it is, so with a readable container
-- the wanted stack is moved to the front first (frontStack) and exactly
-- what's needed is taken.  Otherwise anything else that comes out is set
-- aside and dropped back once we're done (fuel is kept).  opts: label
-- (for messages), quiet (report nothing), room (free slots to leave
-- untouched, default 1).
local restockWarned = {}
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

-- Burn fuel from the container on `side` until the tank holds `target`
-- (capped at the tank's limit), fuel already on board first.  Takes one
-- item of a kind to learn what it's worth, then only as many as needed.
-- Empty buckets left by lava go back in.  True if the target was reached.
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

return T
