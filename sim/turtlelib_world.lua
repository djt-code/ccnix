-- sim/turtlelib_world.lua
--
-- tl.world (ADR-0008): the frames, the map on disk and the scans.
--   * a scan from each of the four headings (and from elsewhere) lands in the right cells; a radius over 8 is
--     refused unless forced; the scanner is asked again while it cools down; the fuel it cost is told;
--   * a cube is written as a text header and 4096 bytes, and read back byte for byte, from a file written by
--     hand too; the map is written in batches, not for every cell;
--   * digs, placements and moves note themselves in the map, without a world function ever having been called
--     once a map is on disk;
--   * the map survives T.setHomeHere (the transform is updated) and a heading correction, and says it is
--     unaligned when the position was lost, until T.alignMap;
--   * the world: T.setOrigin from the player, from GPS, and the facing from a scan, in each of the four ways the
--     start can face; T.toWorld and T.toLocal;
--   * the queries (get, top, find, count, heights, slice);
--   * the cap: the cubes unseen longest are dropped first, at the smaller of the setting and a quarter of the disk;
--   * T.inspectAt records a state; T.inspectAll goes nearest first; T.scanBox tiles scans.
local PROJ = ...
package.path = PROJ .. "/turtle/?.lua;" .. PROJ .. "/lib/?.lua;" .. PROJ .. "/sim/lib/?.lua;" .. package.path
local M = require("mock")
local check = M.check

local S = M.state()
local CLOCK = 1000
os.epoch = function() return CLOCK * 1000 end

-- The disk: 1 MB, with the cube files counted as they are written
local CAPACITY = 1000000
local WRITES = 0
local base = M.fsApi(S)
fs = M.merge(base, {
    getCapacity = function() return CAPACITY end,
    getFreeSpace = function()
        local used = 0
        for _, data in pairs(S.files) do used = used + math.max(#data, 500) end
        return CAPACITY - used
    end,
    open = function(p, mode)
        if mode == "wb" then WRITES = WRITES + 1 end
        return base.open(p, mode)
    end,
})
textutils = M.textutilsApi()
shell = M.shellApi("x.lua")
SLEEPS = 0
sleep = function() SLEEPS = SLEEPS + 1 end
local SETTINGS, DEFAULTS = {}, {}
settings = {
    define = function(name, opts) DEFAULTS[name] = opts.default end,
    get = function(name) if SETTINGS[name] ~= nil then return SETTINGS[name] end return DEFAULTS[name] end,
}
local realPrint = print
print = function() end

--------------------------------------------------------------------------
-- The world the mock turtle is in, and the world around that
--------------------------------------------------------------------------
-- Blocks by cell of the mock's own frame (its start: (0,0,0), facing +z, +x to the right); nothing is air.
local W = {}
local function get(x, y, z) return W[M.key(x, y, z)] or nil end
local function put(x, y, z, name, state) W[M.key(x, y, z)] = name and { name = name, state = state } or nil end
S.get = get
local DIGS = 0

-- Where that frame is in the real world: the world cell of its (0,0,0), and the compass way its +z points
-- (0 north, 1 east, 2 south, 3 west).  Worked out by hand, from which side of the way you face is your right:
-- facing south your right is west, facing east it is south, facing north east, facing west north.
local ORIGIN = { x = 100, y = 64, z = -50 }
local F0 = 2
local COMPASS = { [0] = "north", "east", "south", "west" }
local function worldOf(mx, my, mz)
    local o = ORIGIN
    if F0 == 2 then return o.x - mx, o.y + my, o.z + mz
    elseif F0 == 1 then return o.x + mz, o.y + my, o.z + mx
    elseif F0 == 0 then return o.x + mx, o.y + my, o.z - mz
    else return o.x - mz, o.y + my, o.z - mx end
end

-- The geo scanner: every block in the cube about the turtle, with the world's offsets (x, y, z) and the
-- turtle's own (r right, u up, f forward).  COOL scans are refused first ("on cooldown"); ABS gives world
-- coordinates (and a turtle entry) instead of offsets.
local scanCalls, COOL, ABS = 0, 0, false
local function scanBlocks(r)
    scanCalls = scanCalls + 1
    if COOL > 0 then COOL = COOL - 1; return nil, "Scan is on cooldown" end
    if FUEL then FUEL = FUEL - r * 10 end
    local px, py, pz, d = S.P.x, S.P.y, S.P.z, S.P.d
    local wx0, wy0, wz0 = worldOf(px, py, pz)
    local out = {}
    for dy = -r, r do
        for dz = -r, r do
            for dx = -r, r do
                local b = get(px + dx, py + dy, pz + dz)
                if b then
                    local wx, wy, wz = worldOf(px + dx, py + dy, pz + dz)
                    local e = { name = b.name, tags = {}, u = dy,
                                f = dx * M.DX[d] + dz * M.DZ[d], r = dx * M.DX[(d + 1) % 4] + dz * M.DZ[(d + 1) % 4] }
                    if ABS then e.x, e.y, e.z = wx, wy, wz else e.x, e.y, e.z = wx - wx0, wy - wy0, wz - wz0 end
                    out[#out + 1] = e
                end
            end
        end
    end
    if ABS then out[#out + 1] = { name = "computercraft:turtle_advanced", tags = {}, x = wx0, y = wy0, z = wz0, r = 0, u = 0, f = 0 } end
    return out
end

local SCANNER, CONTROLLER, PICK = "advancedperipherals:geo_scanner", "advancedperipherals:chunk_controller", "minecraft:diamond_pickaxe"
EQ = { left = SCANNER, right = CONTROLLER }
peripheral = {
    getType = function(side) return (EQ[side] == SCANNER) and "geoScanner" or nil end,
    getMethods = function(side) return EQ[side] == SCANNER and { "scanBlocks" } or {} end,
    wrap = function(side) if EQ[side] == SCANNER then return { scanBlocks = scanBlocks } end end,
}

local function inspectAt(x, y, z)
    local b = get(x, y, z)
    if not b then return false, "No block to inspect" end
    return true, { name = b.name, state = b.state or {} }
end
local function newTurtle()
    turtle = M.merge(
        M.inventoryApi(S), M.equipmentApi(S), M.fuelApi(S), M.noAttackApi(),
        M.movementApi(S, function(b) return b == nil or b.fluid == true end),
        M.lookingApi(S, inspectAt, function(b) return b ~= nil and not b.fluid end),
        M.actingApi(S, "dig", function(x, y, z)
            local b = get(x, y, z)
            if not b or b.fluid then return false, "Nothing to dig here" end
            DIGS = DIGS + 1
            put(x, y, z, nil)
            return true
        end),
        M.actingApi(S, "place", function(x, y, z)
            local it = S.inv[S.sel]
            if get(x, y, z) or not it then return false, "Cannot place block here" end
            -- (a bucket places its fluid, as in the game)
            put(x, y, z, ({ ["minecraft:water_bucket"] = "minecraft:water", ["minecraft:lava_bucket"] = "minecraft:lava" })[it.name] or it.name)
            return true
        end))
end

-- A new start of the computer: the turtle API unwrapped, turtlelib and the module loaded afresh, the disk as it was.
local function reboot()
    newTurtle()
    package.loaded.turtlelib, package.loaded["tl.world"] = nil, nil
    return require("turtlelib")
end
-- An empty disk and an empty world, a new start.
local function fresh(f0)
    S.files, S.dirs, S.inv, S.sel = {}, {}, {}, 1
    W, F0, ABS, COOL, FUEL = {}, f0 or 2, false, 0, nil
    EQ.left, EQ.right = SCANNER, CONTROLLER
    CLOCK, WRITES, SLEEPS = 1000, 0, 0
    S.P.x, S.P.y, S.P.z, S.P.d = 0, 0, 0, 0
    return reboot()
end
-- The turtle (really, and as the library counts) at x, y, z facing d.
local function tp(T, x, y, z, d)
    S.P.x, S.P.y, S.P.z, S.P.d = x, y, z, d or 0
    T.pos.x, T.pos.y, T.pos.z, T.dir = x, y, z, d or 0
    T.savePos()
end

-- Every block of the world within r of the cell, by "x,y,z" of the mock's frame.
local function within(px, py, pz, r)
    local out = {}
    for dx = -r, r do
        for dy = -r, r do
            for dz = -r, r do
                local b = get(px + dx, py + dy, pz + dz)
                if b then out[M.key(px + dx, py + dy, pz + dz)] = b.name end
            end
        end
    end
    return out
end
local function same(a, b)
    for k, v in pairs(a) do if b[k] ~= v then return false end end
    for k, v in pairs(b) do if a[k] ~= v then return false end end
    return true
end
local function count(t) local n = 0; for _ in pairs(t) do n = n + 1 end; return n end
local function dump(t)
    local keys = {}
    for k, v in pairs(t) do keys[#keys + 1] = k .. "=" .. tostring(v) end
    table.sort(keys)
    return table.concat(keys, " ")
end

local STONE, DIRT, GOLD, IRON, GLASS, SAND = "minecraft:stone", "minecraft:dirt", "minecraft:gold_block",
    "minecraft:iron_block", "minecraft:glass", "minecraft:sand"
local function sprinkle()
    put(2, 0, 3, STONE); put(-3, 1, 0, DIRT); put(0, -1, -4, GOLD); put(4, 2, -2, IRON); put(5, 0, 0, GLASS)
    put(6, 0, 0, SAND)                  -- (beyond a radius of 5)
end

--------------------------------------------------------------------------
-- Nothing on disk, nothing loaded
--------------------------------------------------------------------------
local T = fresh()
check("with no map on disk, loading turtlelib loads nothing of the module", package.loaded["tl.world"] == nil and rawget(T, "map") == nil
    and not S.dirs[".map"])
T.startAtHome(true)
check("...and starting at home does not make one", not S.dirs[".map"] and package.loaded["tl.world"] == nil)
turtle.forward()
check("...nor does a move", not S.dirs[".map"] and package.loaded["tl.world"] == nil)

--------------------------------------------------------------------------
-- A scan from each heading
--------------------------------------------------------------------------
T = fresh()
sprinkle()
local cells, info = T.scan(5)
check("T.scan loads the module the first time it is used", package.loaded["tl.world"] ~= nil and S.dirs[".map"] == true)
check("a scan gives { [\"x,y,z\"] = name } in the turtle's frame", cells and same(cells, within(0, 0, 0, 5)) and count(cells) == 5,
    cells and dump(cells) or tostring(info))
check("...and an info table: radius, blocks, merged", info and info.radius == 5 and info.blocks == 5 and info.merged == true)
for h = 0, 3 do
    tp(T, 0, 0, 0, h)
    S.P.d = h
    cells = T.scan(5)
    check("scan facing " .. h .. ": the blocks are in the cells they are", cells and same(cells, within(0, 0, 0, 5)), cells and dump(cells) or "nil")
end
check("the map holds them", T.map.get(2, 0, 3) == STONE and T.map.get(-3, 1, 0) == DIRT and T.map.get(0, -1, -4) == GOLD
    and T.map.get(4, 2, -2) == IRON and T.map.get(5, 0, 0) == GLASS)
local name, why = T.map.get(1, 0, 1)
check("...air where the scan lists nothing", name == "minecraft:air", tostring(name) .. " " .. tostring(why))
name, why = T.map.get(0, 0, 0)
check("...the turtle's own cell is air", name == "minecraft:air")
name, why = T.map.get(6, 0, 0)
check("...and a cell beyond the scan was never seen: nil and why", name == nil and why == "not in the map", tostring(name) .. " " .. tostring(why))
-- from somewhere else, turned
tp(T, 2, 0, -1, 3)
cells = T.scan(5)
check("a scan from (2,0,-1) facing 3 lands every block in its own cell", cells and same(cells, within(2, 0, -1, 5)) and count(cells) >= 4,
    cells and dump(cells) or "nil")
tp(T, -1, 1, 2, 1)
cells = T.scan(4)
check("...and from (-1,1,2) facing 1, radius 4", cells and same(cells, within(-1, 1, 2, 4)), cells and dump(cells) or "nil")

-- the world's x is mirrored against the turtle's: nothing on the turtle's side gives a different cell
tp(T, 0, 0, 0, 0)
local pairsBefore = count(within(0, 0, 0, 5))
cells = T.scan(5, { map = false })
check("opts.map = false: scanned, not merged, and says so", cells and count(cells) == pairsBefore and select(2, T.scan(5, { map = false })).merged == false)

-- guards
local calls = scanCalls
cells, why = T.scan(9)
check("a radius over 8 is refused without force, before the scanner is asked", cells == nil and why:find("force", 1, true) and scanCalls == calls,
    tostring(why))
cells, why = T.scan(9, { force = true })
check("...and done with force = true", cells ~= nil and scanCalls == calls + 1, tostring(why))
cells, why = T.scan(0)
check("a radius under 1 is refused", cells == nil and why, tostring(why))
cells, why = T.scan(2.5)
check("...so is a part of a block", cells == nil and why, tostring(why))
FUEL = 5000
cells, info = T.scan(3)
check("the fuel a scan cost is in the info", info and info.fuel == 30 and FUEL == 4970, tostring(info and info.fuel))
FUEL = nil
-- cooldown
COOL, calls, SLEEPS = 2, scanCalls, 0
cells, info = T.scan(3)
check("a scanner cooling down is asked again", cells ~= nil and scanCalls == calls + 3 and SLEEPS >= 2, scanCalls - calls .. " calls, " .. SLEEPS .. " sleeps")
COOL, calls = 50, scanCalls
cells, why = T.scan(3)
check("...but not for ever: nil and why", cells == nil and why:find("cooldown", 1, true) and scanCalls == calls + 5, tostring(why) .. " / " .. scanCalls - calls)
COOL = 0
EQ.left, S.inv[1] = PICK, { name = SCANNER, count = 1 }
cells = T.scan(3)
check("a scanner in the inventory is put on for the scan and taken off, the controller stays on",
    cells ~= nil and EQ.left == PICK and EQ.right == CONTROLLER and S.inv[1] and S.inv[1].name == SCANNER)
EQ.left, S.inv[1] = PICK, nil
cells, why = T.scan(3)
check("no scanner on board: nil and why", cells == nil and why:find("no " .. SCANNER, 1, true), tostring(why))
EQ.left = SCANNER

--------------------------------------------------------------------------
-- A cube on disk, byte for byte
--------------------------------------------------------------------------
T = fresh()
sprinkle()
tp(T, 0, 0, 0, 0)
CLOCK = 1234
T.scan(5)
check("a scan writes its cubes in a batch: eight cubes, each once", WRITES == 8 and S.files[".map/0_0_0"] and S.files[".map/-1_0_0"]
    and S.files[".map/0_-1_-1"] and S.files[".map/-1_-1_-1"], WRITES .. " writes")
local file = S.files[".map/0_0_0"]
check("a cube is its header and 4096 bytes", file and #file > 4096 and #file < 4096 + 1000 and file:sub(1, 13) == "ccnix-cube 1\n", #file)
local lines = {}
for line in (file:sub(1, #file - 4096)):gmatch("([^\n]*)\n") do lines[#lines + 1] = line end
check("...with when it was seen, then its palette (glass and stone)", lines[2] == "1234" and tonumber(lines[3]) == 2
    and lines[4] == GLASS and lines[5] == STONE, table.concat(lines, "|"))
local pal = {}
for i = 1, tonumber(lines[3]) do pal[i] = lines[3 + i] end
-- (cell 2,0,3 of the cube 0,0,0 is byte (0 * 16 + 3) * 16 + 2 = 50; the palette entries are codes 2 and up)
local code = file:sub(-4096):byte(51)
check("...the byte for a cell is a code into the palette (read here without the module)", pal[code - 1] == STONE, tostring(code))
check("...1 for air and 0 for a cell never seen", file:sub(-4096):byte(1) == 1 and file:sub(-4096):byte(4096) == 0, tostring(file:sub(-4096):byte(1)))
local frameFile = S.files[".map/frame"]
check("the frames are kept beside them", frameFile == "frame 0 0 0 0 1\n", tostring(frameFile))
local before = {}
for k, v in pairs(S.files) do if k:sub(1, 5) == ".map/" then before[k] = v end end
-- a new start of the computer reads them back
T = reboot()
local data, palette = T.map.cube(0, 0, 0)
check("read back after a restart, the bytes are the ones written", data == file:sub(-4096) and palette[1] == pal[1], data and #data or "nil")
check("...the same cells answer", T.map.get(2, 0, 3) == STONE and T.map.get(1, 0, 1) == "minecraft:air" and T.map.get(-3, 1, 0) == DIRT)
local _, _, when = T.map.get(2, 0, 3)
check("...and the time it was seen", when == 1234, tostring(when))
T.map.set(2, 0, 3, STONE)
T.map.flush()
local same2 = true
for k, v in pairs(before) do if S.files[k] ~= v then same2 = false end end
check("writing the cube again with nothing new, the file is the same byte for byte", same2 and S.files[".map/0_0_0"] == file)
-- one made by hand
local hand = table.concat({ "ccnix-cube 1", "777", "2", "minecraft:obsidian", "minecraft:stone", "1", "5 facing=north,half=top,n=3,wet=false" }, "\n") .. "\n"
local bytes = { }
for i = 1, 4096 do bytes[i] = 0 end
bytes[6], bytes[7], bytes[8] = 2, 3, 1
S.files[".map/3_0_0"] = hand .. string.char(table.unpack(bytes, 1, 200)) .. string.char(table.unpack(bytes, 201, 4096))
T = reboot()
local n1, s1, w1 = T.map.get(53, 0, 0)
check("a cube written by hand: name, state and time", n1 == "minecraft:obsidian" and s1 and s1.facing == "north" and s1.half == "top"
    and s1.n == 3 and s1.wet == false and w1 == 777, tostring(n1) .. " " .. tostring(w1))
check("...another name, air and a cell never seen", T.map.get(54, 0, 0) == STONE and T.map.get(55, 0, 0) == "minecraft:air"
    and T.map.get(56, 0, 0) == nil)
S.files[".map/4_0_0"] = "garbage"
T = reboot()
local g, gwhy = T.map.get(64, 0, 0)
check("a file that is not a cube is no cube", g == nil and gwhy == "not in the map")

--------------------------------------------------------------------------
-- Written in batches
--------------------------------------------------------------------------
T = fresh()
tp(T, 0, 0, 0, 0)
T.map.set(0, 0, 0, STONE)
T.map.flush()
WRITES = 0
for _ = 1, 10 do turtle.forward() end
check("ten moves note their cells and write nothing yet", WRITES == 0 and T.map.stats().unsaved >= 1, WRITES .. " writes")
check("...but the map has them", T.map.get(0, 0, 5) == "minecraft:air" and T.map.get(0, 0, 10) == "minecraft:air")
T.map.flush()
check("T.map.flush writes them: a cube or two", WRITES >= 1 and WRITES <= 2 and T.map.stats().unsaved == 0, WRITES .. " writes")
local w0 = WRITES
T.map.flush()
check("...and flushing with nothing new writes nothing", WRITES == w0)
for z = 0, 80 do T.map.set(0, 0, 100 + z, STONE) end
check("enough changes write by themselves", WRITES > w0, WRITES .. " writes")

--------------------------------------------------------------------------
-- What the turtle does notes itself
--------------------------------------------------------------------------
T = fresh()
tp(T, 0, 0, 0, 0)
put(0, 0, 1, STONE); put(0, 1, 0, DIRT)
T.scan(2)
check("a block is in the map", T.map.get(0, 0, 1) == STONE and T.map.get(0, 1, 0) == DIRT)
turtle.dig()
check("turtle.dig() called straight notes the cell as air", T.map.get(0, 0, 1) == "minecraft:air")
S.inv[1] = { name = "minecraft:cobblestone", count = 4 }
turtle.place()
check("turtle.place() notes the block placed", T.map.get(0, 0, 1) == "minecraft:cobblestone")
turtle.digUp()
check("digUp notes the cell above", T.map.get(0, 1, 0) == "minecraft:air")
T.map.set(0, 0, 1, "minecraft:oak_stairs", { facing = "east", half = "bottom" })
local nm, st = T.map.get(0, 0, 1)
check("T.map.set notes a block and its state", nm == "minecraft:oak_stairs" and st and st.facing == "east" and st.half == "bottom")
S.inv[1] = { name = "minecraft:cobblestone", count = 4 }
put(0, 0, 1, nil)
turtle.place()
nm, st = T.map.get(0, 0, 1)
check("a placement forgets the state the cell had", nm == "minecraft:cobblestone" and st == nil)
S.inv[1] = { name = "minecraft:water_bucket", count = 1 }
turtle.placeUp()
check("a bucket of water placed notes water", T.map.get(0, 1, 0) == "minecraft:water")
T.map.set(0, 0, 3, "minecraft:lava")
put(0, 0, 3, "minecraft:lava"); W[M.key(0, 0, 3)].fluid = true
turtle.dig()                            -- (cobblestone in front: dug and gone)
turtle.forward(); turtle.forward()
check("a move notes the cells it went through as air", T.map.get(0, 0, 1) == "minecraft:air" and T.map.get(0, 0, 2) == "minecraft:air")
turtle.forward()
check("...but not lava the turtle swims into", T.map.get(0, 0, 3) == "minecraft:lava" and S.P.z == 3)
T.digDir(1)
T.forward()
check("T's own moves note them too", T.map.get(1, 0, 3) == "minecraft:air" or T.pos.x == 1, tostring(T.map.get(1, 0, 3)))

-- a map on disk is listened to from the start
T = reboot()
check("with a map on disk, turtlelib loads the module at once", package.loaded["tl.world"] ~= nil)
tp(T, 0, 0, 0, 0)
put(0, 0, 1, DIRT)
turtle.dig()
check("...and a dig is noted though no function of it was called", T.map.get(0, 0, 1) == "minecraft:air")

--------------------------------------------------------------------------
-- Frames: --here, a corrected heading, a lost position
--------------------------------------------------------------------------
T = fresh()
put(5, 0, 2, STONE)
tp(T, 3, 0, 2, 1)
T.scan(4)
check("the stone ahead of a turtle at (3,0,2) facing +x is mapped at (5,0,2)", T.map.get(5, 0, 2) == STONE)
T.startAtHome(true)                     -- (what a program's --here does)
check("--here (T.startAtHome(true)) makes the spot (0,0,0) facing 0", T.pos.x == 0 and T.pos.z == 0 and T.dir == 0)
check("...and the stone is now two ahead: (0,0,2)", T.map.get(0, 0, 2) == STONE and T.map.get(5, 0, 2) == nil)
local f = T.map.frame()
check("the transform is a quarter turn and a shift", f.turns == 1 and f.dx == 3 and f.dy == 0 and f.dz == 2 and f.aligned, dump(f))
local mx, my, mz = T.map.toMap(0, 0, 2)
check("a turtle-frame cell maps to the cell it is in the map's frame", mx == 5 and my == 0 and mz == 2)
check("the frames are saved", S.files[".map/frame"] == "frame 1 3 0 2 1\n", tostring(S.files[".map/frame"]))
put(3, 0, 6, SAND)
cells = T.scan(4)
check("a scan after it lands in the new frame: the stone two ahead, the sand four to the left", cells and cells["0,0,2"] == STONE
    and cells["-4,0,0"] == SAND and count(cells) == 2, cells and dump(cells) or "nil")
mx, my, mz = T.map.toMap(-4, 0, 0)
check("...and it is the mock's own cell (3,0,6) in the map", mx == 3 and my == 0 and mz == 6)
check("nothing in the map moved: the old stone is still the one stone", T.map.count(STONE) == 1, tostring(T.map.count(STONE)))
-- the same, and the world too
T = fresh()
put(5, 0, 2, STONE)
tp(T, 3, 0, 2, 1)
T.scan(4)
local wx, wy, wz = worldOf(3, 0, 2)
check("T.setOrigin(x, y, z, facing) with where the turtle stands (3,0,2) facing +x", T.setOrigin(wx, wy, wz, COMPASS[(F0 + 1) % 4]) == true)
local w5 = { worldOf(5, 0, 2) }
local before5 = T.toWorld({ x = 5, y = 0, z = 2 })
T.startAtHome(true)
local after5 = T.toWorld({ x = 0, y = 0, z = 2 })
check("a re-zero leaves the world's cells alone: (0,0,2) now is the world cell (5,0,2) was",
    before5 and after5 and after5.x == w5[1] and after5.y == w5[2] and after5.z == w5[3] and before5.x == w5[1], dump(after5 or {}))

-- an origin told after the frame was re-zeroed (the turtle still stands at the mock's (3,0,2) facing +x)
check("an origin told in a re-zeroed frame: T.setOrigin with where the turtle stands now", T.setOrigin(wx, wy, wz, COMPASS[(F0 + 1) % 4]) == true)
local ahead2 = T.toWorld({ x = 0, y = 0, z = 2 })
check("...two ahead of the turtle is the world cell the stone is in", ahead2 and ahead2.x == w5[1] and ahead2.y == w5[2] and ahead2.z == w5[3])
check("...and the frame's +z points the way the turtle faces", T.origin().facing == COMPASS[(F0 + 1) % 4], T.origin().facing)

-- `reset --here` after the turtle was carried home by hand: the saved position is stale, home is home
T = fresh()
put(0, 0, 2, STONE)
tp(T, 0, 0, 0, 0)
T.scan(4)
T.pos.x, T.pos.z, T.dir = 5, 7, 2
T.savePos()                             -- (where it was when it was picked up)
T.setHomeHere()
check("T.setHomeHere (the turtle put back at home by hand) leaves the map where it was", T.map.get(0, 0, 2) == STONE
    and T.map.frame().turns == 0 and T.map.frame().dx == 0 and T.map.frame().aligned, dump(T.map.frame()))
cells = T.scan(4)
check("...so a scan after it agrees: one stone, at (0,0,2)", T.map.count(STONE) == 1 and cells and cells["0,0,2"] == STONE)

-- a heading corrected: only the heading was wrong, so the map stays where it is
T = fresh()
put(4, 0, 3, STONE)
tp(T, 2, 0, 1, 0)
T.scan(4)
T.dir = 3                               -- (a turn lost: the turtle faces 0 but believes 3)
T.setDir(0)
check("T.setDir corrects the heading and leaves the map alone: the stone is still at (4,0,3)", T.map.get(4, 0, 3) == STONE
    and T.map.frame().turns == 0, tostring(T.map.get(4, 0, 3)))
cells = T.scan(4)
check("...and a scan after it puts it in the same cell: one stone", T.map.count(STONE) == 1 and cells and cells["4,0,3"] == STONE,
    tostring(T.map.count(STONE)))

-- T.clearPos then a start, in the same program: the place it was is known
T = fresh()
put(5, 0, 2, STONE)
tp(T, 3, 0, 2, 1)
T.scan(4)
T.clearPos()
T.startAtHome(false)
check("T.clearPos then startAtHome keeps the map aligned: the same shift as --here", T.map.get(0, 0, 2) == STONE and T.map.frame().aligned
    and T.map.frame().turns == 1)

-- the saved position lost behind the program's back
T = fresh()
put(5, 0, 2, STONE)
tp(T, 3, 0, 2, 1)
T.scan(4)
S.files[".turtlepos"] = nil
T = reboot()
T.startAtHome(false)
name, why = T.map.get(0, 0, 2)
check("with the position file gone and a map on disk, the map is unaligned", name == nil and why:find("unaligned", 1, true), tostring(why))
check("...and the frame file says so", S.files[".map/frame"] == "frame 0 0 0 0 0\n", tostring(S.files[".map/frame"]))
local found
found, why = T.map.find("*")
check("...queries answer nil and why", found == nil and why:find("unaligned", 1, true) and T.map.heights() == nil and T.map.slice(0) == nil
    and T.map.top(0, 0) == nil and T.map.count("*") == nil)
cells, info = T.scan(3)
check("...a scan still tells its cells, and says it was not merged", cells ~= nil and info.merged == false and info.why:find("unaligned", 1, true))
put(0, 0, 1, DIRT)
turtle.dig()
check("...digs are not noted", T.map.stats().aligned == false)
local ok
ok, why = T.setOrigin(1, 2, 3, "north")
check("...nor can an origin be set on it", ok == nil and why:find("unaligned", 1, true))
ok = T.alignMap(3, 0, 2, 1)
check("T.alignMap says how the frames sit, and the old cells answer again", ok == true and T.map.get(0, 0, 2) == STONE and T.map.frame().aligned)
ok, why = T.alignMap(1, 2, "x", 1)
check("alignMap wants whole numbers", ok == nil and why, tostring(why))
-- cleared
T = reboot()
S.files[".turtlepos"] = nil
T.startAtHome(false)
check("unaligned again, a new start of the program", T.map.get(0, 0, 2) == nil and T.map.stats().aligned == false)
T.map.clear()
check("T.map.clear throws the cubes away and the map is aligned with this frame", T.map.stats().cubes == 0 and T.map.stats().aligned
    and S.files[".map/0_0_0"] == nil and T.map.set(1, 1, 1, STONE) == true)

--------------------------------------------------------------------------
-- The world: the origin, from the player, GPS and a scan
--------------------------------------------------------------------------
for f0 = 0, 3 do
    for _, absolute in ipairs({ false, true }) do
        T = fresh(f0)
        ABS = absolute
        put(3, 0, 2, STONE)
        put(0, 0, 2, DIRT)
        put(-1, 1, -1, GLASS)
        tp(T, 1, 0, 1, 1)
        local label = COMPASS[f0] .. (absolute and ", world coordinates" or "")
        gps = nil
        local px, py, pz = worldOf(1, 0, 1)
        local facing = COMPASS[(f0 + 1) % 4]              -- (it turned to its right from the mock's own +z)
        local okSet = T.setOrigin(px, py, pz, facing)
        local o = T.origin()
        local ox, oy, oz = worldOf(0, 0, 0)
        check("[" .. label .. "] setOrigin(x, y, z, facing): the origin is the world cell of (0,0,0), facing the mock's +z",
            okSet == true and o and o.x == ox and o.y == oy and o.z == oz and o.facing == COMPASS[f0], o and dump(o) or "nil")
        check("[" .. label .. "] the file holds the compass of the map's +z and the world cell of its (0,0,0)",
            S.files[".map/frame"] == string.format("frame 0 0 0 0 1\nworld %d %d %d %d\n", f0, ox, oy, oz), tostring(S.files[".map/frame"]))
        local all = true
        for _, p in ipairs({ { 0, 0, 0 }, { 3, 0, 2 }, { -4, 2, 7 }, { 5, -1, -6 } }) do
            local w = T.toWorld({ x = p[1], y = p[2], z = p[3] })
            local x, y, z = worldOf(p[1], p[2], p[3])
            local back = w and T.toLocal(w)
            local back2 = w and T.toLocal(w.x, w.y, w.z)
            if not (w and w.x == x and w.y == y and w.z == z and back and back.x == p[1] and back.y == p[2] and back.z == p[3]
                    and back2.x == p[1]) then
                all = false
            end
        end
        check("[" .. label .. "] toWorld and toLocal agree with where the cells really are, both ways", all)
        -- the facing from a scan
        T = fresh(f0)
        ABS = absolute
        put(3, 0, 2, STONE); put(0, 0, 2, DIRT); put(-1, 1, -1, GLASS)
        tp(T, 1, 0, 1, 1)
        local c0 = scanCalls
        okSet = T.setOrigin(px, py, pz)
        o = T.origin()
        check("[" .. label .. "] setOrigin(x, y, z) works the facing out from a scan", okSet == true and o and o.facing == COMPASS[f0]
            and o.x == ox and o.z == oz and scanCalls > c0, o and dump(o) or tostring(select(2, T.setOrigin(px, py, pz))))
        -- GPS
        T = fresh(f0)
        ABS = absolute
        put(3, 0, 2, STONE); put(0, 0, 2, DIRT)
        tp(T, 1, 0, 1, 1)
        gps = { locate = function() return px, py, pz end }
        okSet = T.setOrigin()
        o = T.origin()
        check("[" .. label .. "] setOrigin() asks GPS for the cell and a scan for the facing", okSet == true and o and o.facing == COMPASS[f0]
            and o.x == ox and o.y == oy and o.z == oz, o and dump(o) or "nil")
        gps = nil
    end
end
T = fresh()
ok, why = T.setOrigin()
check("setOrigin() with no GPS: nil and why", ok == nil and why:find("GPS", 1, true), tostring(why))
ok, why = T.setOrigin(1, 2, 3, "up")
check("a facing that is no compass way is refused", ok == nil and why:find("north, east, south or west", 1, true), tostring(why))
ok, why = T.setOrigin(1.5, 2, 3, "north")
check("so is a part of a block", ok == nil and why, tostring(why))
ok, why = T.setOrigin(1, 2, 3)
check("a facing from a scan with nothing near: nil and why", ok == nil and why and why:find("line", 1, true), tostring(why))
ok, why = T.toWorld({ x = 0, y = 0, z = 0 })
check("toWorld before an origin: nil and why", ok == nil and why:find("T.setOrigin", 1, true), tostring(why))
T.setOrigin(10, 20, 30, "e")
local t0 = T.toWorld(0, 0, 0)
check("\"e\" is east; T.toWorld takes three numbers too", t0 and t0.x == 10 and t0.y == 20 and t0.z == 30 and T.origin().facing == "east")
local t1 = T.toWorld(0, 0, 2)
check("facing east, two ahead is two to the east (+x)", t1 and t1.x == 12 and t1.z == 30)
local t2 = T.toWorld(2, 0, 0)
check("...and two to the right is two to the south (+z)", t2 and t2.x == 10 and t2.z == 32)
T = reboot()
check("the origin is kept: another start reads it", T.toWorld(0, 0, 2).x == 12 and T.origin().facing == "east")

--------------------------------------------------------------------------
-- The queries
--------------------------------------------------------------------------
T = fresh()
tp(T, 0, 0, 0, 0)
for x = 0, 3 do
    for z = 0, 2 do T.map.set(x, 0, z, STONE) end
end
T.map.set(3, 0, 2, GOLD)
T.map.set(1, 1, 1, "minecraft:oak_stairs")
T.map.set(2, 1, 1, "minecraft:oak_stairs")
T.map.set(0, 1, 0, "minecraft:water")
local y, topName = T.map.top(1, 1)
check("T.map.top: the highest solid cell of a column", y == 1 and topName == "minecraft:oak_stairs", tostring(y))
y, topName = T.map.top(0, 0)
check("...water is not solid", y == 0 and topName == STONE, tostring(y))
y, why = T.map.top(9, 9)
check("...a column nothing is known of: nil and why", y == nil and why, tostring(why))
local list, cut = T.map.find("*_stairs")
check("T.map.find: a glob, nearest first, as { x, y, z, name }", list and #list == 2 and list[1].x == 1 and list[1].y == 1 and list[1].z == 1
    and list[2].x == 2 and list[1].name == "minecraft:oak_stairs" and cut == false)
list = T.map.find("oak_stairs")
check("...a pattern with no namespace matches the name without it", list and #list == 2)
list = T.map.find("minecraft:stone", { 0, 0, 0, 1, 0, 1 })
check("...inside a box", list and #list == 4)
list = T.map.find("minecraft:stone", { 1, 0, 1, 0, 0, 0 })
check("...the corners in any order", list and #list == 4)
list, cut = T.map.find("minecraft:stone", nil, 3)
check("...cut to a limit, and says so", list and #list == 3 and cut == true)
check("T.map.count", T.map.count(STONE) == 11 and T.map.count("*_stairs") == 2 and T.map.count("minecraft:stone", { 0, 0, 0, 1, 0, 0 }) == 2,
    tostring(T.map.count(STONE)))
check("...a box is checked", select(1, T.map.count("*", { 1, 2 })) == nil)
local expectHeights = table.concat({ "highest solid y; x 0 to 3 across, z 2 down to 0 (rows)", "z2 0 0 0 0", "z1 0 1 1 0", "z0 0 0 0 0" }, "\n")
local heights = T.map.heights({ 0, -5, 0, 3, 5, 2 })
check("T.map.heights: a column's top, the rows from the high z down", heights == expectHeights, heights)
local expectSlice0 = table.concat({ "y = 0; x 0 to 3 across, z 2 down to 0 (rows)", "z2 ###%", "z1 ####", "z0 ####",
    "# minecraft:stone", "% minecraft:gold_block" }, "\n")
local slice = T.map.slice(0, { 0, 0, 0, 3, 0, 2 })
check("T.map.slice: a character a cell and a legend", slice == expectSlice0, slice)
local expectSlice1 = table.concat({ "y = 1; x 0 to 3 across, z 2 down to 0 (rows)", "z2 ????", "z1 ?##?", "z0 ~???", "# minecraft:oak_stairs" }, "\n")
slice = T.map.slice(1, { 0, 0, 0, 3, 0, 2 })
check("...? for never seen, ~ for water", slice == expectSlice1, slice)
heights, why = T.map.heights({ 0, 0, 0, 100, 0, 5 })
check("a view is limited to 64 across", heights == nil and why:find("64", 1, true), tostring(why))
check("a default view about the turtle", T.map.slice(0):find("y = 0; x -8 to 8 across", 1, true) == 1)
-- through a turned frame the same answers come out turned
T = fresh()
tp(T, 0, 0, 0, 0)
T.map.set(2, 0, 0, STONE)
T.alignMap(0, 0, 0, 1)
check("with the frames a quarter turn apart, the map's stone at (2,0,0) answers at the turtle's (0,0,2)", T.map.get(0, 0, 2) == STONE
    and T.map.get(2, 0, 0) == nil)
list = T.map.find(STONE)
check("T.map.find gives the cell in the turtle's frame", list and #list == 1 and list[1].x == 0 and list[1].z == 2, list and dump(list[1]) or "nil")
y = T.map.top(0, 2)
check("top works in the turtle's frame too", y == 0)

--------------------------------------------------------------------------
-- The cap
--------------------------------------------------------------------------
local function cubeCells(n) return n * 16, 0, 0 end     -- the cell at the start of the nth cube along x
local function cubesOnDisk()
    local n = {}
    for k in pairs(S.files) do
        if k:sub(1, 5) == ".map/" and k ~= ".map/frame" then n[#n + 1] = k:sub(6) end
    end
    table.sort(n)
    return table.concat(n, " ")
end
T = fresh()
tp(T, 0, 0, 0, 0)
SETTINGS["map.maxBytes"] = 12900                         -- (three cubes of air: 4118 bytes each)
for i = 0, 3 do
    CLOCK = 100 + i * 100
    T.map.set(i * 16, 0, 0, "minecraft:air")
    T.map.flush()
end
check("over the cap, the cube unseen longest is dropped: the first of four", cubesOnDisk() == "1_0_0 2_0_0 3_0_0", cubesOnDisk())
check("...stats: three cubes, under the cap", T.map.stats().cubes == 3 and T.map.stats().bytes <= 12900 and T.map.stats().cap == 12900,
    dump(T.map.stats()))
CLOCK = 600
T.map.set(32, 0, 0, "minecraft:stone")                    -- seen again, and changed
T.map.flush()
CLOCK = 700
T.map.set(64, 0, 0, "minecraft:air")
T.map.flush()
check("a cube seen again outlives an older one: the next to go is the oldest of the rest", cubesOnDisk() == "2_0_0 3_0_0 4_0_0"
    or cubesOnDisk() == "2_0_0 4_0_0 3_0_0", cubesOnDisk())
check("...the dropped cube is gone from the map", T.map.get(16, 0, 0) == nil and T.map.get(32, 0, 0) == "minecraft:stone")
-- a quarter of the disk
T = fresh()
tp(T, 0, 0, 0, 0)
SETTINGS["map.maxBytes"] = nil
CAPACITY = 4 * 12900
for i = 0, 3 do
    CLOCK = 100 + i * 100
    T.map.set(i * 16, 0, 0, "minecraft:air")
    T.map.flush()
end
check("the cap is a quarter of the disk when that is less than the setting", T.map.stats().cap == 12900 and T.map.stats().cubes == 3
    and cubesOnDisk() == "1_0_0 2_0_0 3_0_0", dump(T.map.stats()))
CAPACITY = 4000000
T = reboot()
check("the cap is the setting's 512 KB on a big disk", T.map.stats().cap == 524288, tostring(T.map.stats().cap))

--------------------------------------------------------------------------
-- Inspecting: block states
--------------------------------------------------------------------------
T = fresh()
tp(T, 0, 0, 0, 0)
put(10, 0, 10, "minecraft:oak_stairs", { facing = "east", half = "top", shape = "straight", waterlogged = false })
name, st = T.inspectAt(10, 0, 10)
check("T.inspectAt goes next to the cell and reads its block and state", name == "minecraft:oak_stairs" and st and st.facing == "east"
    and st.half == "top" and st.waterlogged == false, tostring(name))
check("...the turtle is beside it", T.dist(T.pos, { x = 10, y = 0, z = 10 }) == 1 and S.P.x == T.pos.x and S.P.z == T.pos.z)
local gname, gstate = T.map.get(10, 0, 10)
check("...and the map keeps the state", gname == "minecraft:oak_stairs" and gstate and gstate.facing == "east" and gstate.half == "top"
    and gstate.waterlogged == false)
T.map.flush()
T = reboot()
gname, gstate = T.map.get(10, 0, 10)
check("...also after a restart (the states are in the cube's file)", gname == "minecraft:oak_stairs" and gstate and gstate.shape == "straight")
tp(T, 0, 0, 0, 0)
name, st = T.inspectAt(10, 0, 12)
check("an empty cell is air", name == "minecraft:air" and st == nil)
-- the state is replaced by a new inspect
put(10, 0, 10, "minecraft:oak_stairs", { facing = "west", half = "bottom" })
T.inspectAt(10, 0, 10)
gname, gstate = T.map.get(10, 0, 10)
check("inspecting again replaces the state", gstate and gstate.facing == "west" and gstate.half == "bottom" and gstate.shape == nil)
-- a cell shut in
for _, v in ipairs({ { 1, 0, 0 }, { -1, 0, 0 }, { 0, 1, 0 }, { 0, -1, 0 }, { 0, 0, 1 }, { 0, 0, -1 } }) do
    put(30 + v[1], 5 + v[2], 30 + v[3], STONE)
end
put(30, 5, 30, "minecraft:chest")
tp(T, 0, 0, 0, 0)
S.moves = 0
name, why = T.inspectAt(30, 5, 30)
check("a cell with every side solid: nil and why, and it learns what was in the way", name == nil and why:find("couldn't get next to", 1, true)
    and T.map.get(30, 5, 29) == STONE, tostring(why))
-- (a straight run can wedge the turtle against the shell; finding a way round is the path module's)
for _, v in ipairs({ { 1, 0, 0 }, { -1, 0, 0 }, { 0, 1, 0 }, { 0, -1, 0 }, { 0, 0, 1 }, { 0, 0, -1 } }) do
    T.map.set(30 + v[1], 5 + v[2], 30 + v[3], STONE)
end
S.moves = 0
name, why = T.inspectAt(30, 5, 30)
check("...when the map knows every side is solid it says so without going", name == nil and why:find("solid in the map", 1, true) and S.moves == 0,
    S.moves .. " moves: " .. tostring(why))
-- the order
local asked = {}
local rawInspectAt = T.inspectAt
T.inspectAt = function(x, y, z, o) asked[#asked + 1] = x .. "," .. y .. "," .. z; return rawInspectAt(x, y, z, o) end
tp(T, 0, 0, 0, 0)
put(10, 0, 0, "minecraft:oak_stairs", { facing = "north" }); put(3, 0, 0, "minecraft:oak_slab", { type = "top" }); put(7, 0, 0, "minecraft:oak_slab", { type = "bottom" })
local results, failed = T.inspectAll({ { x = 10, y = 0, z = 0 }, "3,0,0", { 7, 0, 0 } })
check("T.inspectAll goes to the nearest cell next", table.concat(asked, " ") == "3,0,0 7,0,0 10,0,0", table.concat(asked, " "))
check("...and returns what it saw, by \"x,y,z\"", results["3,0,0"] and results["3,0,0"].name == "minecraft:oak_slab" and results["3,0,0"].state.type == "top"
    and results["10,0,0"].state.facing == "north" and results["7,0,0"].state.type == "bottom" and #failed == 0)
-- a cell beside the one it stands by is looked at from there
tp(T, 0, 0, 0, 0)
put(20, 0, 20, "minecraft:oak_stairs", { facing = "south" }); put(20, 0, 22, "minecraft:oak_stairs", { facing = "north" })
tp(T, 20, 0, 21, 0)
asked, S.moves = {}, 0
results, failed = T.inspectAll({ { 20, 0, 20 }, { 20, 0, 22 } })
check("a second cell beside the turtle is looked at from where it stands: no move", S.moves == 0 and #asked == 1 and results["20,0,22"]
    and results["20,0,22"].state.facing == "north" and results["20,0,20"].state.facing == "south", S.moves .. " moves, " .. #asked .. " asks")
-- one that cannot be reached
tp(T, 0, 0, 0, 0)
results, failed = T.inspectAll({ { 30, 5, 30 }, { 3, 0, 0 } })
check("a cell it cannot reach is in the failures, the rest still seen", #failed == 1 and failed[1].x == 30 and failed[1].why and results["3,0,0"])
T.inspectAt = rawInspectAt

--------------------------------------------------------------------------
-- Scanning a box
--------------------------------------------------------------------------
T = fresh()
tp(T, 0, 0, 0, 0)
put(1, 0, 0, STONE); put(18, 0, 3, GOLD); put(10, 4, 4, IRON)
local report
report, why = T.scanBox({ 0, 0, 0, 19, 4, 4 })
check("T.scanBox tiles radius-8 scans over the box: two scans for 20 across", report and report.tiles == 2 and report.scanned == 2 and #report.failed == 0,
    report and dump(report) or tostring(why))
check("...and the whole box is in the map", T.map.get(1, 0, 0) == STONE and T.map.get(18, 0, 3) == GOLD and T.map.get(10, 4, 4) == IRON
    and T.map.get(19, 4, 4) == "minecraft:air", tostring(T.map.get(18, 0, 3)))
report, why = T.scanBox({ 0, 0, 0, 600, 4, 4 })
check("a box that takes over 27 scans is refused", report == nil and why:find("27", 1, true), tostring(why))
report, why = T.scanBox({ 0, 0, 0, 5 })
check("...a box is six numbers", report == nil and why)
T = fresh()
tp(T, 0, 0, 0, 0)
put(8, 2, 2, STONE); put(1, 0, 0, STONE)               -- the first centre is solid
report = T.scanBox({ 0, 0, 0, 19, 4, 4 })
check("a centre it cannot get to is a failure; the other scan is made", report and report.scanned == 1 and #report.failed == 1
    and report.failed[1].x == 8 and report.failed[1].why:find("blocked by", 1, true), report and report.failed[1] and tostring(report.failed[1].why) or "nil")
report = T.scanBox({ 0, 0, 0, 19, 4, 4 }, { move = { dig = true } })
check("...with opts.move = { dig = true } it digs its way there", report and report.scanned == 2 and #report.failed == 0)
EQ.left = nil
report = T.scanBox({ 0, 0, 0, 5, 2, 2 })
check("no scanner: the failure says why, and it stops", report and report.scanned == 0 and #report.failed == 1 and report.failed[1].why:find("no " .. SCANNER, 1, true))
EQ.left = SCANNER

--------------------------------------------------------------------------
-- A scan somebody else took (mine's own)
--------------------------------------------------------------------------
T = fresh()
sprinkle()
tp(T, 0, 0, 0, 1)
local entries = scanBlocks(5)
local merged, n = T.mergeScan(entries, 5)
check("T.mergeScan puts the scanner's entries in the map: true and how many blocks", merged == true and n == 5, tostring(merged) .. " " .. tostring(n))
check("...each in its own cell, turned as the turtle is", T.map.get(2, 0, 3) == STONE and T.map.get(-3, 1, 0) == DIRT and T.map.get(0, -1, -4) == GOLD
    and T.map.get(4, 2, -2) == IRON and T.map.get(5, 0, 0) == GLASS)
check("...air where it lists nothing, and nothing beyond its radius", T.map.get(1, 0, 3) == "minecraft:air" and T.map.get(6, 0, 0) == nil)
local T2 = fresh()
sprinkle()
tp(T2, 0, 0, 0, 1)
T2.scan(5)
local same5 = true
for dx = -5, 5 do for dy = -5, 5 do for dz = -5, 5 do
    if T.map.get(dx, dy, dz) ~= T2.map.get(dx, dy, dz) then same5 = false end
end end end
check("...the same cells as T.scan makes of the same scan", same5)
T = fresh()
sprinkle()
merged, why = T.mergeScan({ { name = STONE, x = 1, y = 0, z = 1 } }, 5)
check("entries with no r, u and f are refused with the reason", merged == nil and why:find("r, u and f", 1, true), tostring(why))
merged, why = T.mergeScan("nothing", 5)
check("...and so is something that isn't a list", merged == nil and why)
merged, why = T.mergeScan(scanBlocks(5), 0)
check("...and a radius of 0", merged == nil and why)
T.map.clear()
T.frameChanged(nil, nil)
tp(T, 0, 0, 0, 0)
T.map.set(0, 0, 3, STONE)
T.frameChanged(nil, nil)
merged, why = T.mergeScan(scanBlocks(5), 5)
check("an unaligned map takes nothing, and says so", merged == nil and why:find("unaligned", 1, true), tostring(why))

print = realPrint
