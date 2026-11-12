-- world.lua -- the map and the frames: what the turtle has seen, dug and placed, and where that is in the world
--
-- Loaded by turtlelib the first time one of these is used (T.scan, T.map, T.setOrigin, ...), and
-- from the start on a turtle that already has a map on disk, so that digs and moves made by any
-- program keep it right.  Coordinates in the calls are the turtle's own (the frame it counts in:
-- (0,0,0) where its job started, facing +z, +x to its right).
--
-- Frames.  The turtle's frame isn't fixed: `--here`, T.setHomeHere, T.clearPos and a run with no saved
-- position make wherever it stands (0,0,0) again.  So the map keeps a frame of its own, the one it
-- was started in, and the transform (a shift and quarter turns) from the turtle's current frame to
-- it.  Whenever turtlelib re-zeroes it tells this module where that spot was, and the transform is
-- updated, so what the map holds stays where it is.  If the frame was lost without that (the saved
-- position was deleted) the map is kept but marked unaligned: it answers nothing and takes nothing
-- new until T.alignMap says how the frames sit, or T.map.clear starts a new map.  The world is one
-- more transform: T.setOrigin gives the turtle's place in the world and the way it faces (from GPS
-- and a scan if it isn't told), and T.toWorld and T.toLocal convert.  They are kept in the data folder
-- (.map/frame).
--
-- The map.  One file per 16 by 16 by 16 cube of space in the data folder's .map: a text header (when it
-- was seen, the names of the blocks the cube holds, and the block states that were inspected) and
-- then one byte a cell (4096 of them, written in binary mode): 0 for a cell never seen, 1 for air,
-- 2 and up for a name of the palette.  A cube is loaded when it's used and written when it
-- changed, in batches (not for every cell).  The map is capped at the smaller of 512 KB (the setting
-- map.maxBytes) and a quarter of the disk, and the cubes unseen longest are dropped first.  What the
-- turtle dug, placed and moved through (T.onChange) goes in as it happens; a scan fills in the cells
-- it covered, air where it lists no block.
--
-- A cell's "when" is the time its cube was last seen, in seconds (os.epoch "utc").

local T = require("turtlelib")
local text = require("text")
local scan = require("scan")
local convert = require("convert")
local fileio = require("fileio")
local glob = require("glob")

local CUBE, CELLS = 16, 4096                  -- a cube is 16 cells each way
local FORMAT = "ccnix-cube 1"                 -- the first line of a cube's file
local FRAME_FILE = "frame"                    -- the frames, in the map's folder
local SCANNER = "advancedperipherals:geo_scanner"
local MAX_RADIUS = 8                          -- the most a scan may be, unless forced (D3)
local MAX_TILES = 27                          -- the most scans a scanBox makes, unless forced
local SCAN_TRIES = 5                          -- asks of a scanner that is still cooling down
local MAX_PALETTE = 254                       -- codes 2 to 255 name blocks
local MAX_STATES = 256                        -- inspected states kept for a cube
local CACHE_KEEP = 8                          -- cubes kept loaded when nothing is changing
local FLUSH_CELLS, FLUSH_SECONDS = 64, 10     -- changes (or seconds) before they are written
local MAX_FOUND = 20000                       -- the most map.find holds before it cuts to the limit
local MAX_SIDE = 64                           -- the widest a heights or slice may be
local AIR, AIR_CODE = "minecraft:air", 1
local SYMBOLS = "#%&=+*@$ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
local NEIGHBOURS = { 0, 1, 2, 3, "up", "down" }

-- Names that are air, and names that aren't a surface to stand on or build on
local AIRS = { [AIR] = true, ["minecraft:cave_air"] = true, ["minecraft:void_air"] = true }
local FLUIDS = { ["minecraft:water"] = true, ["minecraft:flowing_water"] = true, ["minecraft:lava"] = true,
                 ["minecraft:flowing_lava"] = true }
local NONSOLID = { ["minecraft:bubble_column"] = true, ["minecraft:fire"] = true, ["minecraft:soul_fire"] = true,
                   ["minecraft:light"] = true }
for name in pairs(AIRS) do NONSOLID[name] = true end
for name in pairs(FLUIDS) do NONSOLID[name] = true end

-- A slice's symbols for what is common to every map
local FIXED_SYMBOLS = { [AIR] = ".", ["minecraft:water"] = "~", ["minecraft:flowing_water"] = "~",
                        ["minecraft:lava"] = "^", ["minecraft:flowing_lava"] = "^" }

-- What an item becomes where it's placed, when that isn't its own name
local PLACED_AS = { ["minecraft:water_bucket"] = "minecraft:water", ["minecraft:lava_bucket"] = "minecraft:lava",
                    ["minecraft:bucket"] = AIR }

-- A quarter turn k about the vertical: x' = a*x + b*z, z' = c*x + d*z as {a, b, c, d}
-- (k turns take heading 0 (+z) to heading k, with 1 being +x)
local ROT = { [0] = { 1, 0, 0, 1 }, { 0, 1, -1, 0 }, { -1, 0, 0, -1 }, { 0, -1, 1, 0 } }

-- The compass, clockwise from north, as the world's x and z: north is -z, east +x
local COMPASS_VECTOR = { [0] = { 0, -1 }, { 1, 0 }, { 0, 1 }, { -1, 0 } }
local COMPASS_NAME = { [0] = "north", "east", "south", "west" }
local COMPASS_AT = { [0] = { [-1] = 0, [1] = 2 }, [1] = { [0] = 1 }, [-1] = { [0] = 3 } }  -- [x][z] of a unit vector
local COMPASS_WORDS = {
    north = 0, n = 0, ["-z"] = 0, east = 1, e = 1, ["+x"] = 1, south = 2, s = 2, ["+z"] = 2, west = 3, w = 3, ["-x"] = 3,
}

local UNALIGNED = "the map is unaligned: the turtle's position was lost, so how its frame sits in the map's isn't known "
    .. "(T.alignMap(dx, dy, dz, turns) says; T.map.clear() starts a new map)"

--------------------------------------------------------------------------
-- State shared by every copy of this module
--
-- Each program the shell runs loads its own turtlelib and its own copy of
-- this module, but there is one turtle: what's loaded of the map, and the
-- frames, live on the turtle table, so every copy works on the same cubes
-- and writes them once.
--------------------------------------------------------------------------
local holder = turtle or _G
local S = holder._ccnixWorld
if not S then
    S = { cache = {}, index = {}, bytes = 0, count = 0, ndirty = 0, cells = 0, tick = 0, now = 0 }
    holder._ccnixWorld = S
end

local function whole(n) return type(n) == "number" and n == math.floor(n) end

-- The time, in seconds.
local function clock()
    if os.epoch then return math.floor(os.epoch("utc") / 1000) end
    return math.floor(os.time())
end

-- Give the rest of the computer a turn when this has run for a while
-- (CC stops code that goes seven seconds without yielding).
local function breathe()
    local t = os.clock()
    if t - (S.lastYield or 0) > 0.4 then
        S.lastYield = t
        sleep(0)
    end
end

--------------------------------------------------------------------------
-- Frames: the turtle's, the map's and the world's
--------------------------------------------------------------------------

-- Rotate (x, z) by k quarter turns.
local function rot(k, x, z)
    local m = ROT[k % 4]
    return m[1] * x + m[2] * z, m[3] * x + m[4] * z
end

-- A point in the turtle's frame, in the map's.
local function toMap(x, y, z)
    local f = S.frame
    local rx, rz = rot(f.t, x, z)
    return rx + f.dx, y + f.dy, rz + f.dz
end

-- A point in the map's frame, in the turtle's.
local function fromMap(mx, my, mz)
    local f = S.frame
    local x, z = rot(-f.t, mx - f.dx, mz - f.dz)
    return x, my - f.dy, z
end

-- A point in the map's frame, in the world's (the map is a turtle's frame:
-- its +x is to the right of its +z, which the world's is not, so it's mirrored).
local function toWorldPoint(mx, my, mz)
    local w = S.world
    local fx, fz = COMPASS_VECTOR[w.s][1], COMPASS_VECTOR[w.s][2]
    return w.ox - fz * mx + fx * mz, w.oy + my, w.oz + fx * mx + fz * mz
end

-- A point in the world, in the map's frame.
local function fromWorldPoint(wx, wy, wz)
    local w = S.world
    local fx, fz = COMPASS_VECTOR[w.s][1], COMPASS_VECTOR[w.s][2]
    local a, b = wx - w.ox, wz - w.oz
    return -fz * a + fx * b, wy - w.oy, fx * a + fz * b
end

-- Write the frames.  True, or nil and why.
local function saveFrame()
    local f, w = S.frame, S.world
    local lines = { string.format("frame %d %d %d %d %d", f.t, f.dx, f.dy, f.dz, f.aligned and 1 or 0) }
    if w then lines[2] = string.format("world %d %d %d %d", w.s, w.ox, w.oy, w.oz) end
    return fileio.write(fs.combine(S.dir, FRAME_FILE), table.concat(lines, "\n") .. "\n")
end

-- Read the frames (the turtle's own and the map's are the same until they're told otherwise).
local function loadFrame()
    S.frame, S.world = { t = 0, dx = 0, dy = 0, dz = 0, aligned = true }, nil
    local data = fileio.read(fs.combine(S.dir, FRAME_FILE))
    if not data then return false end
    for _, line in ipairs(text.lines(data)) do
        local w = text.words(line)
        local nums = {}
        for i = 2, #w do
            if not scan.isInteger(w[i]) then nums = nil; break end
            nums[#nums + 1] = tonumber(w[i])
        end
        if nums and w[1] == "frame" and #nums == 5 then
            S.frame = { t = nums[1] % 4, dx = nums[2], dy = nums[3], dz = nums[4], aligned = nums[5] == 1 }
        elseif nums and w[1] == "world" and #nums == 4 then
            S.world = { s = nums[1] % 4, ox = nums[2], oy = nums[3], oz = nums[4] }
        end
    end
    return true
end

--------------------------------------------------------------------------
-- Cubes
--------------------------------------------------------------------------
local function cubeOf(v) return math.floor(v / CUBE) end
local function cubeName(cx, cy, cz) return cx .. "_" .. cy .. "_" .. cz end

-- The cube a file name stands for: cx, cy, cz; nil if it isn't one.
local function parseName(name)
    local part = text.split(name, "_", true)
    if #part ~= 3 then return nil end
    local cx, cy, cz = convert.toInteger(part[1]), convert.toInteger(part[2]), convert.toInteger(part[3])
    if not (cx and cy and cz) or cubeName(cx, cy, cz) ~= name then return nil end
    return cx, cy, cz
end

local function newCube(name, cx, cy, cz)
    return { name = name, cx = cx, cy = cy, cz = cz, data = string.rep("\0", CELLS), pal = {}, code = {},
             pend = {}, npend = 0, states = {}, sorder = {}, nstates = 0, seen = 0, dirty = false, used = 0 }
end

-- A state table as text ("facing=north,half=bottom": keys in order), or nil for none.
local function stateText(state)
    if type(state) ~= "table" then return nil end
    local keys = {}
    for k in pairs(state) do keys[#keys + 1] = tostring(k) end
    if #keys == 0 then return nil end
    table.sort(keys)
    local parts = {}
    for i, k in ipairs(keys) do parts[i] = k .. "=" .. tostring(state[k]) end
    return table.concat(parts, ",")
end

-- The state table a text stands for (true and false, whole numbers and words).
local function parseState(str)
    local state = {}
    for _, pair in ipairs(text.split(str, ",")) do
        local k, v = text.cut(pair, "=")
        if v == "true" then state[k] = true
        elseif v == "false" then state[k] = false
        elseif v and scan.isInteger(v) then state[k] = tonumber(v)
        elseif v then state[k] = v end
    end
    return state
end

-- A cube from its file's bytes; nil if they aren't one.
local function decode(whole_, name, cx, cy, cz)
    if #whole_ <= CELLS then return nil end
    local lines = text.lines(whole_:sub(1, #whole_ - CELLS))
    if lines[1] ~= FORMAT then return nil end
    local seen, np = convert.toInteger(lines[2]), convert.toInteger(lines[3])
    if not (seen and np) then return nil end
    local c = newCube(name, cx, cy, cz)
    c.data, c.seen = whole_:sub(-CELLS), seen
    for i = 1, np do
        local n = lines[3 + i]
        if not n then return nil end
        c.pal[i], c.code[n] = n, i + 1
    end
    local ns = convert.toInteger(lines[4 + np] or "0") or 0
    for i = 1, ns do
        local idx, st = text.cut(lines[4 + np + i] or "", " ")
        idx = convert.toInteger(idx)
        if idx and st then
            c.states[idx] = st
            c.nstates = c.nstates + 1
            c.sorder[#c.sorder + 1] = idx
        end
    end
    return c
end

-- A cube's file contents: header text, then its 4096 bytes.
local function encode(c)
    -- (the changes waiting go into the bytes first)
    if c.npend > 0 then
        local pieces, from = {}, 1
        for idx = 0, CELLS - 1 do
            local code = c.pend[idx]
            if code then
                if idx + 1 > from then pieces[#pieces + 1] = c.data:sub(from, idx) end
                pieces[#pieces + 1] = string.char(code)
                from = idx + 2
            end
        end
        pieces[#pieces + 1] = c.data:sub(from)
        c.data, c.pend, c.npend = table.concat(pieces), {}, 0
    end
    local lines = { FORMAT, tostring(c.seen), tostring(#c.pal) }
    for _, n in ipairs(c.pal) do lines[#lines + 1] = n end
    local kept, done = {}, {}
    for _, idx in ipairs(c.sorder) do
        if c.states[idx] and not done[idx] then
            done[idx] = true
            kept[#kept + 1] = idx .. " " .. c.states[idx]
        end
    end
    c.sorder = {}
    for _, line in ipairs(kept) do c.sorder[#c.sorder + 1] = convert.toInteger((text.cut(line, " "))) end
    lines[#lines + 1] = tostring(#kept)
    for _, line in ipairs(kept) do lines[#lines + 1] = line end
    return table.concat(lines, "\n") .. "\n" .. c.data
end

local function markDirty(c)
    if c.dirty then return end
    c.dirty = true
    S.ndirty = S.ndirty + 1
    if S.ndirty == 1 then S.firstDirty = os.clock() end
end

-- The cube at cx, cy, cz, loaded (from its file) or, with create, made; nil if there is none.
local function getCube(cx, cy, cz, create)
    local last = S.last
    if last and last.cx == cx and last.cy == cy and last.cz == cz and S.cache[last.name] == last then
        return last
    end
    local name = cubeName(cx, cy, cz)
    local c = S.cache[name]
    if not c then
        local e = S.index[name]
        if e and e.saved then
            local bytes = fileio.read(fs.combine(S.dir, name), true)
            c = bytes and decode(bytes, name, cx, cy, cz)
            if c then e.seen = c.seen end
        end
        if not c and create then c = newCube(name, cx, cy, cz) end
        if not c then return nil end
        S.cache[name] = c
        if not S.index[name] then
            S.index[name] = { cx = cx, cy = cy, cz = cz, size = 0 }
            S.count = S.count + 1
        end
    end
    S.tick = S.tick + 1
    c.used = S.tick
    S.last = c
    return c
end

-- A cell's place in its cube's bytes (0 to 4095).
local function cellIndex(lx, ly, lz) return (ly * CUBE + lz) * CUBE + lx end

-- A cell's code: 0 unseen, 1 air, 2 and up a palette entry.
local function codeOf(c, idx) return c.pend[idx] or c.data:byte(idx + 1) end

-- The code a name has in a cube, added to its palette if it's new (0, unseen, if the palette is full).
local function nameCode(c, name)
    if name == nil then return 0 end
    if AIRS[name] then return AIR_CODE end
    local code = c.code[name]
    if code then return code end
    if #c.pal >= MAX_PALETTE then return 0 end
    c.pal[#c.pal + 1] = name
    code = #c.pal + 1
    c.code[name] = code
    markDirty(c)
    return code
end

local function codeName(c, code)
    if code == AIR_CODE then return AIR end
    return c.pal[code - 1]
end

-- Put a code at idx.  True if it was another.
local function putCode(c, idx, code)
    if codeOf(c, idx) == code then return false end
    if c.pend[idx] == nil then c.npend = c.npend + 1 end
    c.pend[idx] = code
    if c.states[idx] then
        c.states[idx] = nil
        c.nstates = c.nstates - 1
    end
    markDirty(c)
    return true
end

-- Keep a state for idx (the oldest go when there are too many).
local function putState(c, idx, str)
    if c.states[idx] == str then return false end
    if not c.states[idx] then c.nstates = c.nstates + 1 end
    c.states[idx] = str
    c.sorder[#c.sorder + 1] = idx
    while c.nstates > MAX_STATES do
        local old = table.remove(c.sorder, 1)
        if not old then break end
        if c.states[old] and old ~= idx then
            c.states[old] = nil
            c.nstates = c.nstates - 1
        end
    end
    markDirty(c)
    return true
end

-- Set a cell of the map's frame: its name (nil: unseen), and the state if it was inspected
-- (an empty table says it has none).  fresh: it was seen just now, changed or not.  True if the
-- map changed.
local function setCell(mx, my, mz, name, state, fresh)
    local cx, cy, cz = cubeOf(mx), cubeOf(my), cubeOf(mz)
    local c = getCube(cx, cy, cz, true)
    local idx = cellIndex(mx - cx * CUBE, my - cy * CUBE, mz - cz * CUBE)
    local changed = putCode(c, idx, nameCode(c, name))
    if state ~= nil then
        local str = stateText(state)
        if str then
            changed = putState(c, idx, str) or changed
        elseif c.states[idx] then
            c.states[idx] = nil
            c.nstates = c.nstates - 1
            markDirty(c)
            changed = true
        end
    end
    if changed then S.cells = S.cells + 1 end
    if changed or fresh then
        c.seen = S.now
        markDirty(c)
    end
    return changed
end

-- The name, state text and time of a cell of the map's frame; nil if it's unseen.
local function getCell(mx, my, mz)
    local cx, cy, cz = cubeOf(mx), cubeOf(my), cubeOf(mz)
    local c = getCube(cx, cy, cz, false)
    if not c then return nil end
    local idx = cellIndex(mx - cx * CUBE, my - cy * CUBE, mz - cz * CUBE)
    local code = codeOf(c, idx)
    if code == 0 then return nil end
    return codeName(c, code), c.states[idx], c.seen
end

--------------------------------------------------------------------------
-- The disk: writing cubes, the cap, dropping the longest unseen
--------------------------------------------------------------------------

-- The most the map may take: the setting (512 KB) or a quarter of the disk, whichever is less.
local function capBytes()
    local cap = T.setting("map.maxBytes", 524288, "most bytes the turtle's map (.map) may take on disk; the cubes unseen longest go first")
    local ok, capacity = pcall(fs.getCapacity, S.dir)
    if not (ok and type(capacity) == "number") then
        local free
        ok, free = pcall(fs.getFreeSpace, S.dir)
        capacity = ok and type(free) == "number" and free + S.bytes or nil
    end
    if capacity then cap = math.min(cap, math.floor(capacity / 4)) end
    return cap
end

-- When a saved cube was last seen (read from its file if it isn't known yet).
local function seenOf(name)
    local e = S.index[name]
    local c = S.cache[name]
    if c then return c.seen end
    if e.seen then return e.seen end
    e.seen = 0
    local h = fs.open(fs.combine(S.dir, name), "rb")
    if h then
        if h.readLine() == FORMAT then e.seen = convert.toInteger(h.readLine() or "") or 0 end
        h.close()
    end
    return e.seen
end

-- Forget a cube, and delete its file.
local function dropCube(name)
    local e = S.index[name]
    if not e then return end
    if e.saved then fs.delete(fs.combine(S.dir, name)) end
    local c = S.cache[name]
    if c and c.dirty then S.ndirty = S.ndirty - 1 end
    if c and S.last == c then S.last = nil end
    S.cache[name] = nil
    S.bytes = S.bytes - (e.size or 0)
    S.count = S.count - 1
    S.index[name] = nil
end

-- Delete the saved cube that was seen longest ago, except those in `keep` and any not yet written.
-- True if there was one.
local function dropOldest(keep)
    local best, bestSeen
    for name, e in pairs(S.index) do
        local c = S.cache[name]
        if e.saved and not (keep and keep[name]) and not (c and c.dirty) then
            local seen = seenOf(name)
            if not best or seen < bestSeen or (seen == bestSeen and name < best) then best, bestSeen = name, seen end
        end
    end
    if not best then return false end
    dropCube(best)
    return true
end

-- Write one cube.  True, or false and why.
local function writeCube(c, keep)
    local payload = encode(c)
    local path = fs.combine(S.dir, c.name)
    local ok, wrote, why = pcall(fileio.write, path, payload, true)
    if not (ok and wrote) then
        -- the disk is full: let the longest unseen go and try again
        if dropOldest(keep) then
            ok, wrote, why = pcall(fileio.write, path, payload, true)
        end
        if not (ok and wrote) then return false, tostring(ok and why or wrote) end
    end
    local e = S.index[c.name]
    S.bytes = S.bytes - (e.size or 0) + #payload
    e.size, e.saved, e.seen = #payload, true, c.seen
    c.dirty = false
    S.ndirty = S.ndirty - 1
    return true
end

-- Write every cube that changed, then drop the longest unseen cubes if the map is over its cap.
-- True, or false and why.
local function flush()
    if not S.dir then return true end
    local keep, failed = {}, nil
    for name, c in pairs(S.cache) do
        if c.dirty then
            keep[name] = true
            local ok, why = writeCube(c, keep)
            if not ok then failed = why end
        end
    end
    S.cells = 0
    if S.ndirty <= 0 then S.ndirty, S.firstDirty = 0, nil end
    local cap = capBytes()
    while S.bytes > cap and dropOldest(keep) do end
    if failed then return false, failed end
    return true
end

-- Let go of cubes not changed, the longest unused first, beyond the few kept.
local function trim()
    local list = {}
    for _, c in pairs(S.cache) do
        if not c.dirty then list[#list + 1] = c end
    end
    if #list <= CACHE_KEEP then return end
    table.sort(list, function(a, b) return a.used < b.used end)
    for i = 1, #list - CACHE_KEEP do
        local c = list[i]
        S.cache[c.name] = nil
        if S.last == c then S.last = nil end
        if not S.index[c.name].saved then
            S.index[c.name] = nil
            S.count = S.count - 1
        end
    end
end

-- After changes: write them if enough piled up or long enough has passed (or if forced), and let
-- go of cubes not needed.
local function settle(force)
    if force or S.cells >= FLUSH_CELLS or (S.firstDirty and os.clock() - S.firstDirty >= FLUSH_SECONDS) then flush() end
    trim()
end

-- Get ready: find the map's folder (for the program running now), read the frames and the list of
-- cubes.  The clock's reading for this call is taken too.
local function ensure()
    S.now = clock()
    local prog = shell and shell.getRunningProgram and shell.getRunningProgram() or ""
    if S.dir and S.prog == prog then return end
    local dir = T.dataPath(T.MAP_DIR)
    if S.dir and S.dir ~= dir then flush() end
    if S.dir ~= dir then
        S.dir, S.cache, S.index, S.bytes, S.count, S.ndirty, S.cells, S.last = dir, {}, {}, 0, 0, 0, 0, nil
        if not fs.exists(dir) then fs.makeDir(dir) end
        if not loadFrame() then saveFrame() end
        for _, name in ipairs(fs.list(dir)) do
            local cx, cy, cz = parseName(name)
            if cx then
                local size = fs.getSize(fs.combine(dir, name))
                S.index[name] = { cx = cx, cy = cy, cz = cz, size = size, saved = true }
                S.bytes = S.bytes + size
                S.count = S.count + 1
            end
        end
    end
    S.prog = prog
end

--------------------------------------------------------------------------
-- Keeping up with what the turtle does
--------------------------------------------------------------------------

-- Set a cell of the turtle's frame in the map.  No-op if the map is unaligned.
local function setLocal(x, y, z, name, state, fresh)
    local mx, my, mz = toMap(x, y, z)
    return setCell(mx, my, mz, name, state, fresh)
end

-- Hear a dig, placement or move (T.onChange) and note it.
local function heard(e)
    ensure()
    if not S.frame.aligned then return end
    if e.kind == "dig" then
        setLocal(e.x, e.y, e.z, AIR)
    elseif e.kind == "place" then
        setLocal(e.x, e.y, e.z, e.item and (PLACED_AS[e.item] or e.item) or nil)
    elseif e.kind == "move" then
        -- the turtle is in the cell it went into, and was in the one it left: not solid (water and lava it may swim through)
        for _, p in ipairs({ { e.x, e.y, e.z }, { e.from.x, e.from.y, e.from.z } }) do
            local mx, my, mz = toMap(p[1], p[2], p[3])
            local name = getCell(mx, my, mz)
            if not (name and FLUIDS[name]) then setCell(mx, my, mz, AIR) end
        end
    end
    settle(false)
end

S.heard = heard
if not S.listening then
    S.listening = true
    T.onChange(function(e) return S.heard(e) end)
end

--------------------------------------------------------------------------
-- Frames and the world
--------------------------------------------------------------------------

-- A point from either way of giving it: a table with x, y, z, or three numbers.
local function pointOf(a, b, c)
    if type(a) == "table" then return a.x, a.y, a.z end
    return a, b, c
end

-- Tell the map the turtle's frame changed: the spot that was `old` ({x, y, z, dir}) is now `new` (default 0,0,0 facing 0).
-- turtlelib calls it; returns true, or false and why.
--
-- turtlelib calls it when a program re-zeroes (T.setHomeHere, --here, T.clearPos then a start) or corrects the
-- heading (T.setDir), so what the map holds stays where it is.  With old nil, nobody knows where the spot was: a
-- map holding cubes is marked unaligned.  False and why if the map is unaligned now or was already.
function T.frameChanged(old, new)
    ensure()
    local f = S.frame
    if not f.aligned then return false, UNALIGNED end
    if not old then
        if S.count == 0 then return true end
        f.aligned = false
        saveFrame()
        return false, UNALIGNED
    end
    new = new or { x = 0, y = 0, z = 0, dir = 0 }
    local turns = (old.dir - new.dir) % 4
    local t2 = (f.t + turns) % 4
    -- the new frame's point q is the old frame's O + R(turns) (q - P), and the map's is R(t) of that + d
    local ox, oz = rot(f.t, old.x, old.z)
    local px, pz = rot(t2, new.x, new.z)
    f.dx, f.dy, f.dz = f.dx + ox - px, f.dy + old.y - new.y, f.dz + oz - pz
    f.t = t2
    saveFrame()
    return true
end

-- Say how the turtle's frame sits in the map's, and mark the map aligned. Returns true, or nil and why.
--
-- A point (x, y, z) of the turtle's frame is the map's after turning `turns` quarter turns to the right (about
-- the vertical axis, from (0,0,0)) and then adding (dx, dy, dz).  Use it after a lost position, when you know where the
-- turtle is relative to something in the map.
function T.alignMap(dx, dy, dz, turns)
    if not (whole(dx) and whole(dy) and whole(dz) and whole(turns)) then
        return nil, "alignMap wants whole numbers: dx, dy, dz and quarter turns"
    end
    ensure()
    S.frame = { t = turns % 4, dx = dx, dy = dy, dz = dz, aligned = true }
    local ok, why = saveFrame()
    if not ok then return nil, why end
    return true
end

-- The turtle's frame in the world: { x, y, z, facing, aligned }, the world cell of its (0,0,0) and the compass
-- way its +z points.  Nil and why if T.setOrigin hasn't been told.
--
-- facing is "north", "east", "south" or "west".
function T.origin()
    ensure()
    if not S.world then return nil, "no origin set: T.setOrigin(x, y, z, facing)" end
    if not S.frame.aligned then return nil, UNALIGNED end
    local x, y, z = toWorldPoint(toMap(0, 0, 0))
    return { x = x, y = y, z = z, facing = COMPASS_NAME[(S.world.s + S.frame.t) % 4], aligned = true }
end

-- The turtle's cell by GPS: x, y, z; nil and why if there is no fix.
local function gpsFix()
    if not (gps and gps.locate) then return nil, "no GPS API on this computer" end
    local ok, x, y, z = pcall(gps.locate, 2)
    if not (ok and x) then return nil, "no GPS fix (it needs a wireless modem and GPS hosts in range)" end
    return math.floor(x + 0.5), math.floor(y + 0.5), math.floor(z + 0.5)
end

-- Ask the geo scanner for a scan of radius `radius`, putting it on for the time it takes and
-- asking again while it cools down.  The scanner's entries, or nil and why.
local function rawScan(radius)
    local res = table.pack(T.withPeripheral(SCANNER, function(p)
        local method = p.scanBlocks or p.scan
        if not method then return nil, "the scanner has no scanBlocks method" end
        local why
        for try = 1, SCAN_TRIES do
            local ok, entries, err = pcall(method, radius)
            if ok and entries then return entries end
            why = ok and err or entries
            if try < SCAN_TRIES then sleep(1) end
        end
        return nil, "the scan didn't come back: " .. tostring(why)
    end))
    if not res[1] then return nil, res[2] end
    return res[2], res[3]
end

-- A whole number from a scan's decimal.
local function round(v) return v and math.floor(v + 0.5) end

-- The world compass way (0 to 3) the turtle faces now, worked out from scans: a block's world x and z
-- against its r and f, which are the same offset in the turtle's own terms.  The index of "north"...;
-- nil and why if no block gave one.
local function compassFromScan()
    local why = "no block near enough to line a scan up with"
    for _, radius in ipairs({ 2, 5, MAX_RADIUS }) do
        local entries, err = rawScan(radius)
        if not entries then return nil, err end
        -- (world coordinates, if that's what the scan gives, less the turtle's own)
        local me
        for _, e in ipairs(entries) do
            if type(e.name) == "string" and text.startsWith(e.name, "computercraft:turtle") then
                if me == nil then me = e else me = false end
            end
        end
        local far = false
        for _, e in ipairs(entries) do
            if math.abs(e.x or 0) > radius or math.abs(e.z or 0) > radius then far = true; break end
        end
        if far and not me then
            why = "the scan gives world coordinates and the turtle can't tell which block is itself"
        else
            local best, bestD
            for _, e in ipairs(entries) do
                local r, f = round(e.r), round(e.f)
                if r and f and e.x and e.z and (r ~= 0 or f ~= 0) then
                    local d = r * r + f * f
                    if not bestD or d > bestD then best, bestD = { r = r, f = f, x = round(e.x - (far and me.x or 0)), z = round(e.z - (far and me.z or 0)) }, d end
                end
            end
            if best then
                -- (x, z) = f * F + r * right(F) for the unit vector F the turtle faces
                local fx = (best.f * best.x + best.r * best.z) / bestD
                local fz = (best.f * best.z - best.r * best.x) / bestD
                local ix, iz = math.floor(fx + 0.5), math.floor(fz + 0.5)
                local c = COMPASS_AT[ix] and COMPASS_AT[ix][iz]
                if c and math.abs(fx - ix) < 1e-6 and math.abs(fz - iz) < 1e-6 then return c end
                why = "the scan's blocks don't line up with the turtle's directions (r, f against x, z)"
            end
        end
    end
    return nil, why
end

-- Say where the turtle stands in the world: world cell (x, y, z), facing "north", "east", "south" or "west". Returns
-- true and T.origin()'s table, or nil and why.
--
-- Also n/e/s/w, or -z/+x/+z/-x.  Called with no arguments it asks GPS for the cell and works out the facing
-- from a geo scan; with x, y, z only, it finds the facing from a scan.
function T.setOrigin(x, y, z, facing)
    ensure()
    if not S.frame.aligned then return nil, UNALIGNED end
    if x == nil and y == nil and z == nil then
        local why
        x, y, z = gpsFix()
        if not x then why = y; return nil, tostring(why) .. "; give x, y, z" end
    end
    if not (whole(x) and whole(y) and whole(z)) then return nil, "setOrigin wants whole numbers: x, y, z" end
    local c
    if facing == nil then
        local why
        c, why = compassFromScan()
        if not c then return nil, why end
    else
        c = COMPASS_WORDS[type(facing) == "string" and facing:lower() or facing]
        if not c then return nil, "the facing is north, east, south or west" end
    end
    local mx, my, mz = toMap(T.pos.x, T.pos.y, T.pos.z)
    local heading = (T.dir + S.frame.t) % 4                -- the way it faces, in the map's frame
    S.world = { s = (c - heading) % 4, ox = 0, oy = 0, oz = 0 }
    local ax, ay, az = toWorldPoint(mx, my, mz)
    S.world.ox, S.world.oy, S.world.oz = x - ax, y - ay, z - az
    local ok, why = saveFrame()
    if not ok then return nil, why end
    return true, T.origin()
end

-- Convert a point of the turtle's frame (a table with x, y, z, or three numbers) to the world's: a table
-- { x, y, z }; nil and why if there's no origin or the map is unaligned.
function T.toWorld(a, b, c)
    ensure()
    if not S.world then return nil, "no origin set: T.setOrigin(x, y, z, facing)" end
    if not S.frame.aligned then return nil, UNALIGNED end
    local x, y, z = pointOf(a, b, c)
    if type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number" then return nil, "toWorld wants a point: x, y, z" end
    local wx, wy, wz = toWorldPoint(toMap(x, y, z))
    return { x = wx, y = wy, z = wz }
end

-- Convert a world point (a table with x, y, z, or three numbers) to the turtle's frame: a table { x, y, z };
-- nil and why if there's no origin or the map is unaligned.
function T.toLocal(a, b, c)
    ensure()
    if not S.world then return nil, "no origin set: T.setOrigin(x, y, z, facing)" end
    if not S.frame.aligned then return nil, UNALIGNED end
    local x, y, z = pointOf(a, b, c)
    if type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number" then return nil, "toLocal wants a point: x, y, z" end
    local lx, ly, lz = fromMap(fromWorldPoint(x, y, z))
    return { x = lx, y = ly, z = lz }
end

--------------------------------------------------------------------------
-- The map: the queries
--------------------------------------------------------------------------
T.map = {}

-- A box as six numbers {x1, y1, z1, x2, y2, z2} (or a table with those fields), the corners in any order:
-- x1, y1, z1, x2, y2, z2 with the low corner first; nil and why if it isn't one.
local function normBox(box)
    local v = box
    if type(box) == "table" and box.x1 ~= nil then v = { box.x1, box.y1, box.z1, box.x2, box.y2, box.z2 } end
    if type(v) ~= "table" then return nil, "a box is { x1, y1, z1, x2, y2, z2 }" end
    for i = 1, 6 do
        if not whole(v[i]) then return nil, "a box is { x1, y1, z1, x2, y2, z2 }, whole numbers" end
    end
    return math.min(v[1], v[4]), math.min(v[2], v[5]), math.min(v[3], v[6]),
           math.max(v[1], v[4]), math.max(v[2], v[5]), math.max(v[3], v[6])
end

-- A box of the turtle's frame as the box of the map's frame that holds it.
local function mapBox(x1, y1, z1, x2, y2, z2)
    local ax, ay, az = toMap(x1, y1, z1)
    local bx, by, bz = toMap(x2, y2, z2)
    return { math.min(ax, bx), math.min(ay, by), math.min(az, bz), math.max(ax, bx), math.max(ay, by), math.max(az, bz) }
end

-- Call fn(cube) for each cube there is that touches the box mb (the map's frame; nil for all), in name order.
local function eachCube(mb, fn)
    local names = {}
    local function inside(e)
        return e.cx >= cubeOf(mb[1]) and e.cx <= cubeOf(mb[4]) and e.cy >= cubeOf(mb[2]) and e.cy <= cubeOf(mb[5])
            and e.cz >= cubeOf(mb[3]) and e.cz <= cubeOf(mb[6])
    end
    if mb then
        local nx, ny, nz = cubeOf(mb[4]) - cubeOf(mb[1]) + 1, cubeOf(mb[5]) - cubeOf(mb[2]) + 1, cubeOf(mb[6]) - cubeOf(mb[3]) + 1
        if nx * ny * nz <= S.count then
            for cx = cubeOf(mb[1]), cubeOf(mb[4]) do
                for cy = cubeOf(mb[2]), cubeOf(mb[5]) do
                    for cz = cubeOf(mb[3]), cubeOf(mb[6]) do
                        local name = cubeName(cx, cy, cz)
                        if S.index[name] then names[#names + 1] = name end
                    end
                end
            end
        else
            for name, e in pairs(S.index) do
                if inside(e) then names[#names + 1] = name end
            end
        end
    else
        for name in pairs(S.index) do names[#names + 1] = name end
    end
    table.sort(names)
    for _, name in ipairs(names) do
        local e = S.index[name]
        local c = e and getCube(e.cx, e.cy, e.cz, false)
        if c then fn(c) end
        breathe()
        trim()
    end
end

-- A test on a block name from a glob; a pattern with no ":" also matches the name without its namespace.
local function nameTest(pattern)
    local test = glob.compile(pattern)
    if text.contains(pattern, ":") then return test end
    return function(name)
        local _, short = text.cut(name, ":")
        return test(name) or (short ~= nil and test(short))
    end
end

-- Call visit(code, mx, my, mz) for each cell of cube c inside the box mb (map frame; nil for all of it).
local function eachCell(c, mb, visit)
    local x0, y0, z0 = c.cx * CUBE, c.cy * CUBE, c.cz * CUBE
    local lx1, lx2 = mb and math.max(mb[1] - x0, 0) or 0, mb and math.min(mb[4] - x0, CUBE - 1) or CUBE - 1
    local ly1, ly2 = mb and math.max(mb[2] - y0, 0) or 0, mb and math.min(mb[5] - y0, CUBE - 1) or CUBE - 1
    local lz1, lz2 = mb and math.max(mb[3] - z0, 0) or 0, mb and math.min(mb[6] - z0, CUBE - 1) or CUBE - 1
    for lz = lz1, lz2 do
        for ly = ly1, ly2 do
            for lx = lx1, lx2 do
                visit(codeOf(c, cellIndex(lx, ly, lz)), x0 + lx, y0 + ly, z0 + lz)
            end
        end
    end
end

-- Make the map ready for a query: nil and why if it's unaligned.
local function ready()
    ensure()
    if not S.frame.aligned then return nil, UNALIGNED end
    return true
end

-- What the map holds at x, y, z (turtle frame): the block's name, its state table if inspected, and when it was last
-- seen (seconds); nil and why if never seen.
--
-- Air is "minecraft:air".  An unaligned map gives nil and why too.
function T.map.get(x, y, z)
    local ok, why = ready()
    if not ok then return nil, why end
    local name, st, when = getCell(toMap(x, y, z))
    if not name then return nil, "not in the map" end
    return name, st and parseState(st) or nil, when
end

-- Note a cell in the map by hand: the block `name` (nil: forget it) at x, y, z of the turtle's frame, with
-- its state table if it's known.  True, or nil and why.  (Digs, placements, moves and scans note themselves.)
function T.map.set(x, y, z, name, state)
    local ok, why = ready()
    if not ok then return nil, why end
    if not (whole(x) and whole(y) and whole(z)) then return nil, "map.set wants a cell of whole numbers" end
    setLocal(x, y, z, name, state, true)
    settle(false)
    return true
end

-- The cubes that hold something, grouped by column: "cx,cz" -> their cy, highest first.
local function columnsOf()
    local columns = {}
    for _, e in pairs(S.index) do
        local key = e.cx .. "," .. e.cz
        columns[key] = columns[key] or {}
        table.insert(columns[key], e.cy)
    end
    for _, list in pairs(columns) do table.sort(list, function(a, b) return a > b end) end
    return columns
end

-- The highest solid cell of the column mx, mz (map frame) between my-heights lo and hi: its y and name.
local function columnTop(columns, mx, mz, lo, hi)
    local cx, cz = cubeOf(mx), cubeOf(mz)
    for _, cy in ipairs(columns[cx .. "," .. cz] or {}) do
        if cy * CUBE + CUBE - 1 >= lo and cy * CUBE <= hi then
            local c = getCube(cx, cy, cz, false)
            if c then
                local top = math.min(hi, cy * CUBE + CUBE - 1) - cy * CUBE
                local bottom = math.max(lo, cy * CUBE) - cy * CUBE
                for ly = top, bottom, -1 do
                    local code = codeOf(c, cellIndex(mx - cx * CUBE, ly, mz - cz * CUBE))
                    if code > AIR_CODE and not NONSOLID[codeName(c, code)] then return cy * CUBE + ly, codeName(c, code) end
                end
            end
        end
    end
    return nil
end

-- The y of the highest solid cell known in the column x, z (not air, water, lava or fire), and its name;
-- nil and why if the map knows none.
function T.map.top(x, z)
    local ok, why = ready()
    if not ok then return nil, why end
    local mx, _, mz = toMap(x, 0, z)
    local my, name = columnTop(columnsOf(), mx, mz, -math.huge, math.huge)
    trim()
    if not my then return nil, "no solid block known in that column" end
    return my - S.frame.dy, name
end

-- The cells in the box (whole map if none) whose block name matches the glob, nearest first: a list of {x, y, z, name}, and
-- true if cut to `limit` (default 500).
--
-- The glob may leave out the namespace ("*_stairs", "stone").  Nil and why if the map is unaligned.
function T.map.find(pattern, box, limit)
    local ok, why = ready()
    if not ok then return nil, why end
    local mb
    if box ~= nil then
        local x1, y1, z1, x2, y2, z2 = normBox(box)
        if not x1 then return nil, y1 end
        mb = mapBox(x1, y1, z1, x2, y2, z2)
    end
    local test = nameTest(pattern)
    local found, cut = {}, false
    eachCube(mb, function(c)
        local want = {}
        if test(AIR) then want[AIR_CODE] = true end
        for i, name in ipairs(c.pal) do
            if test(name) then want[i + 1] = true end
        end
        if next(want) == nil then return end
        eachCell(c, mb, function(code, mx, my, mz)
            if want[code] then
                if #found >= MAX_FOUND then cut = true; return end
                local x, y, z = fromMap(mx, my, mz)
                found[#found + 1] = { x = x, y = y, z = z, name = codeName(c, code) }
            end
        end)
    end)
    local px, py, pz = T.pos.x, T.pos.y, T.pos.z
    for _, f in ipairs(found) do f.d = math.abs(f.x - px) + math.abs(f.y - py) + math.abs(f.z - pz) end
    table.sort(found, function(a, b)
        if a.d ~= b.d then return a.d < b.d end
        if a.x ~= b.x then return a.x < b.x end
        if a.y ~= b.y then return a.y < b.y end
        return a.z < b.z
    end)
    limit = limit or 500
    if #found > limit then
        cut = true
        for i = #found, limit + 1, -1 do found[i] = nil end
    end
    for _, f in ipairs(found) do f.d = nil end
    return found, cut
end

-- How many cells inside the box (the whole map if none) hold a block whose name matches the glob (as in
-- T.map.find).  Nil and why if the map is unaligned.
function T.map.count(pattern, box)
    local ok, why = ready()
    if not ok then return nil, why end
    local mb
    if box ~= nil then
        local x1, y1, z1, x2, y2, z2 = normBox(box)
        if not x1 then return nil, y1 end
        mb = mapBox(x1, y1, z1, x2, y2, z2)
    end
    local test = nameTest(pattern)
    local n = 0
    eachCube(mb, function(c)
        local want = {}
        if test(AIR) then want[AIR_CODE] = true end
        for i, name in ipairs(c.pal) do
            if test(name) then want[i + 1] = true end
        end
        if next(want) == nil then return end
        eachCell(c, mb, function(code)
            if want[code] then n = n + 1 end
        end)
    end)
    return n
end

-- A box for heights and slice: the one given, or 17 by 17 about the turtle (and 64 up and down).
-- x1, y1, z1, x2, y2, z2, or nil and why.
local function viewBox(box)
    if box == nil then
        local p = T.pos
        return p.x - 8, p.y - 64, p.z - 8, p.x + 8, p.y + 64, p.z + 8
    end
    local x1, y1, z1, x2, y2, z2 = normBox(box)
    if not x1 then return nil, y1 end
    if x2 - x1 + 1 > MAX_SIDE or z2 - z1 + 1 > MAX_SIDE then
        return nil, "a view is at most " .. MAX_SIDE .. " by " .. MAX_SIDE .. " cells across"
    end
    return x1, y1, z1, x2, y2, z2
end

-- A height map of the box (17 by 17 about the turtle if none) as text: each column's highest solid y, "." where none is known.
--
-- Rows run from the box's high z down to its low z, columns from low x to high.  Nil and why if the map is unaligned.
function T.map.heights(box)
    local ok, why = ready()
    if not ok then return nil, why end
    local x1, y1, z1, x2, y2, z2 = viewBox(box)
    if not x1 then return nil, y1 end
    local columns = columnsOf()
    local rows, width = {}, 1
    for z = z2, z1, -1 do
        local row = {}
        for x = x1, x2 do
            local mx, _, mz = toMap(x, 0, z)
            local _, my1 = toMap(x, y1, z)
            local _, my2 = toMap(x, y2, z)
            local my = columnTop(columns, mx, mz, math.min(my1, my2), math.max(my1, my2))
            row[#row + 1] = my and tostring(my - S.frame.dy) or "."
            width = math.max(width, #row[#row])
        end
        rows[#rows + 1] = { z = z, cells = row }
        breathe()
        trim()
    end
    local zw = math.max(#tostring(z1), #tostring(z2))
    local out = { string.format("highest solid y; x %d to %d across, z %d down to %d (rows)", x1, x2, z2, z1) }
    for _, r in ipairs(rows) do
        local cells = {}
        for i, v in ipairs(r.cells) do cells[i] = text.padLeft(v, width) end
        out[#out + 1] = "z" .. text.padLeft(tostring(r.z), zw) .. " " .. table.concat(cells, " ")
    end
    return table.concat(out, "\n")
end

-- The layer at height y in the box (17 by 17 about the turtle if none) as text, a character a cell, with a legend of the symbols.
--
-- "." is air, "?" never seen, "~" water, "^" lava, any other symbol a block listed after.  Rows run from the box's high z
-- down to its low z, columns from low x to high.  Nil and why if the map is unaligned.
function T.map.slice(y, box)
    local ok, why = ready()
    if not ok then return nil, why end
    if not whole(y) then return nil, "slice wants a whole y" end
    local x1, _, z1, x2, _, z2 = viewBox(box)
    if not x1 then return nil, z1 end
    local symbols, legend, nextSymbol = {}, {}, 1
    local out = { string.format("y = %d; x %d to %d across, z %d down to %d (rows)", y, x1, x2, z2, z1) }
    local zw = math.max(#tostring(z1), #tostring(z2))
    for z = z2, z1, -1 do
        local row = {}
        for x = x1, x2 do
            local name = getCell(toMap(x, y, z))
            local ch
            if not name then
                ch = "?"
            elseif FIXED_SYMBOLS[name] then
                ch = FIXED_SYMBOLS[name]
            else
                ch = symbols[name]
                if not ch then
                    ch = nextSymbol <= #SYMBOLS and SYMBOLS:sub(nextSymbol, nextSymbol) or "*"
                    nextSymbol = nextSymbol + 1
                    symbols[name] = ch
                    legend[#legend + 1] = ch .. " " .. name
                end
            end
            row[#row + 1] = ch
        end
        out[#out + 1] = "z" .. text.padLeft(tostring(z), zw) .. " " .. table.concat(row)
        breathe()
        trim()
    end
    for _, l in ipairs(legend) do out[#out + 1] = l end
    return table.concat(out, "\n")
end

--------------------------------------------------------------------------
-- The map: keeping it
--------------------------------------------------------------------------

-- Write what has changed to disk now (it is written in batches as it goes).  True, or false and why.
function T.map.flush()
    ensure()
    local ok, why = flush()
    trim()
    return ok, why
end

-- What the map takes: { cubes, bytes, cap, unsaved, aligned }: how many cubes, how many bytes they take on
-- disk, the most it may take, how many cubes have changes not written, and whether it is aligned.
function T.map.stats()
    ensure()
    return { cubes = S.count, bytes = S.bytes, cap = capBytes(), unsaved = S.ndirty, aligned = S.frame.aligned }
end

-- Throw the map away: every cube is deleted.  An unaligned map becomes aligned again, with the turtle's
-- frame as its own (and the world origin is forgotten, as it was set against the old frame).
function T.map.clear()
    ensure()
    local names = {}
    for name in pairs(S.index) do names[#names + 1] = name end
    for _, name in ipairs(names) do dropCube(name) end
    S.cells, S.ndirty, S.firstDirty = 0, 0, nil
    if not S.frame.aligned then
        S.frame, S.world = { t = 0, dx = 0, dy = 0, dz = 0, aligned = true }, nil
        saveFrame()
    end
    return true
end

-- The frame the map is in relation to the turtle's: { turns, dx, dy, dz, aligned } (see T.alignMap).
function T.map.frame()
    ensure()
    local f = S.frame
    return { turns = f.t, dx = f.dx, dy = f.dy, dz = f.dz, aligned = f.aligned }
end

-- A point of the turtle's frame in the map's: mx, my, mz (T.map.frame says how they relate).
function T.map.toMap(x, y, z)
    ensure()
    return toMap(x, y, z)
end

-- A point of the map's frame in the turtle's: x, y, z.
function T.map.fromMap(mx, my, mz)
    ensure()
    return fromMap(mx, my, mz)
end

-- The cube at cx, cy, cz (map frame) as its 4096 bytes and its palette, for code that reads many cells at once; nil if there is none.
--
-- A cell's cube is its map coordinate divided by 16, rounded down.  string.byte(bytes, (ly * 16 + lz) * 16 + lx + 1) is
-- the cell at lx, ly, lz in the cube: 0 never seen, 1 air, 2 and up palette[code - 1].
function T.map.cube(cx, cy, cz)
    ensure()
    local c = getCube(cx, cy, cz, false)
    if not c then return nil end
    encode(c)                                  -- (the changes waiting go into the bytes)
    local pal = {}
    for i, n in ipairs(c.pal) do pal[i] = n end
    return c.data, pal
end

--------------------------------------------------------------------------
-- Scans
--------------------------------------------------------------------------

-- Geo-scan around the turtle (radius r, default 8; over 8 needs opts.force) into the map: { ["x,y,z"] = name } in the turtle's frame, and an info table.
--
-- opts: force; map = false (leave the map alone); air = false (don't note the cells the scan lists no block for as air).  The info
-- table is { radius, blocks, fuel (paid), merged, why (if not merged) }; nil and why if it can't scan.  The scanner is put on for the scan (T.withPeripheral: the chunk controller stays on) and asked again while it cools
-- down.  The cells come from each entry's r, u and f (right, up and forward of the turtle) and the turtle's heading.  A
-- radius over 8 costs a lot of fuel (16 once cost about 5300), so it's refused unless forced.
function T.scan(r, opts)
    opts = opts or {}
    r = r or MAX_RADIUS
    if not (whole(r) and r >= 1) then return nil, "the radius of a scan is a whole number from 1" end
    if r > MAX_RADIUS and not opts.force then
        return nil, "a scan of radius " .. r .. " costs a lot of fuel (16 once cost about 5300); pass { force = true } to do it"
    end
    ensure()
    local fuel0 = turtle.getFuelLevel and turtle.getFuelLevel()
    local px, py, pz, dir = T.pos.x, T.pos.y, T.pos.z, T.dir
    local entries, why = rawScan(r)
    if not entries then return nil, why end
    local ahead, right = T.DELTA[dir], T.DELTA[(dir + 1) % 4]
    local w = 2 * r + 1
    local cells, named, n = {}, {}, 0
    for _, e in ipairs(entries) do
        local er, eu, ef = round(e.r), round(e.u), round(e.f)
        if not (er and eu and ef) then
            return nil, "the scan's entries carry no r, u and f (right, up, forward): this scanner is too old for T.scan"
        end
        if (er ~= 0 or eu ~= 0 or ef ~= 0) and type(e.name) == "string" then
            local dx, dz = ef * ahead[1] + er * right[1], ef * ahead[3] + er * right[3]
            if math.abs(dx) <= r and math.abs(dz) <= r and math.abs(eu) <= r then
                cells[(px + dx) .. "," .. (py + eu) .. "," .. (pz + dz)] = e.name
                named[((eu + r) * w + (dz + r)) * w + (dx + r)] = e.name
                n = n + 1
            end
        end
    end
    local fuel1 = turtle.getFuelLevel and turtle.getFuelLevel()
    local info = { radius = r, blocks = n, merged = false }
    if type(fuel0) == "number" and type(fuel1) == "number" then info.fuel = fuel0 - fuel1 end
    if opts.map == false then
        info.why = "left out of the map (opts.map is false)"
    elseif not S.frame.aligned then
        info.why = UNALIGNED
    else
        S.now = clock()
        local air = opts.air ~= false
        for dz = -r, r do
            for dy = -r, r do
                for dx = -r, r do
                    local name = named[((dy + r) * w + (dz + r)) * w + (dx + r)]
                    if name then
                        setLocal(px + dx, py + dy, pz + dz, name, nil, true)
                    elseif air then
                        setLocal(px + dx, py + dy, pz + dz, AIR, nil, true)
                    end
                end
            end
            breathe()
        end
        settle(true)
        info.merged = true
    end
    return cells, info
end

-- The centres of the scans that tile [lo, hi] along one axis with scans of radius r.
local function centres(lo, hi, r)
    local len, step = hi - lo + 1, 2 * r + 1
    if len <= step then return { math.floor((lo + hi) / 2) } end
    local out = {}
    for i = 0, math.ceil(len / step) - 1 do out[#out + 1] = math.min(lo + r + i * step, hi - r) end
    return out
end

-- Scan a whole box ({x1, y1, z1, x2, y2, z2}, turtle frame) with radius-8 scans side by side, nearest next: { tiles, scanned, failed }.
--
-- It goes to each scan's centre first (T.moveTo with opts.move, such as { dig = true }); opts.radius for less.  Refuses a box that takes
-- over 27 scans unless opts.force.  failed lists { x, y, z, why } for the scans not made; nil and why if the box is no good.
function T.scanBox(box, opts)
    opts = opts or {}
    local x1, y1, z1, x2, y2, z2 = normBox(box)
    if not x1 then return nil, y1 end
    local r = opts.radius or MAX_RADIUS
    if not (whole(r) and r >= 1) then return nil, "the radius of a scan is a whole number from 1" end
    if r > MAX_RADIUS and not opts.force then
        return nil, "a scan of radius " .. r .. " costs a lot of fuel; pass { force = true } to do it"
    end
    local tiles = {}
    for _, cx in ipairs(centres(x1, x2, r)) do
        for _, cy in ipairs(centres(y1, y2, r)) do
            for _, cz in ipairs(centres(z1, z2, r)) do tiles[#tiles + 1] = { x = cx, y = cy, z = cz } end
        end
    end
    if #tiles > MAX_TILES and not opts.force then
        return nil, "that box takes " .. #tiles .. " scans (at most " .. MAX_TILES .. " unless forced): scan it in parts"
    end
    local report = { tiles = #tiles, scanned = 0, failed = {} }
    local here = T.here()
    while #tiles > 0 do
        local best = 1
        for i = 2, #tiles do
            if T.dist(here, tiles[i]) < T.dist(here, tiles[best]) then best = i end
        end
        local t = table.remove(tiles, best)
        local ok, why = T.moveTo(t.x, t.y, t.z, opts.move)
        if ok then
            local cells, info = T.scan(r, { force = opts.force })
            if cells then
                report.scanned = report.scanned + 1
            else
                report.failed[#report.failed + 1] = { x = t.x, y = t.y, z = t.z, why = info }
                break
            end
        else
            report.failed[#report.failed + 1] = { x = t.x, y = t.y, z = t.z, why = why }
        end
        here = T.here()
    end
    for _, t in ipairs(tiles) do
        report.failed[#report.failed + 1] = { x = t.x, y = t.y, z = t.z, why = "not tried: the scans stopped" }
    end
    return report
end

--------------------------------------------------------------------------
-- Inspecting: block states
--------------------------------------------------------------------------

-- Look at the cell x, y, z in direction d from where the turtle is, and note what's there.  The name and state.
local function lookAt(x, y, z, d)
    local found, data = T.look(d)
    ensure()
    if found and type(data) == "table" and data.name then
        if S.frame.aligned then setLocal(x, y, z, data.name, data.state or {}, true) end
        return data.name, data.state
    end
    if S.frame.aligned then setLocal(x, y, z, AIR, nil, true) end
    return AIR, nil
end

-- Go next to the cell x, y, z, inspect it and note its block and state in the map: name, state table (nil if none), or nil and why.
--
-- The state (a stair's facing, a slab's half) is what a scan can't give.  opts.move is passed to T.moveTo (dig and so on).
function T.inspectAt(x, y, z, opts)
    opts = opts or {}
    if not (whole(x) and whole(y) and whole(z)) then return nil, "inspectAt wants a cell of whole numbers" end
    ensure()
    local mapped = S.frame.aligned
    local options = {}
    for _, d in ipairs(NEIGHBOURS) do
        local v = T.DELTA[d]
        local c = { x = x + v[1], y = y + v[2], z = z + v[3], d = T.OPP[d] }
        local known = mapped and getCell(toMap(c.x, c.y, c.z))
        -- where the turtle already is first; then cells known to be air, the unknown, and (to be tried last) water and lava
        c.rank = T.at(c) and 0 or (known and AIRS[known] and 1) or (not known and 2) or (FLUIDS[known] and 3) or nil
        if c.rank then
            c.dist = T.dist(T.pos, c)
            options[#options + 1] = c
        end
    end
    table.sort(options, function(a, b)
        if a.rank ~= b.rank then return a.rank < b.rank end
        if a.dist ~= b.dist then return a.dist < b.dist end
        return tostring(a.d) < tostring(b.d)
    end)
    local why = "every neighbour of " .. x .. "," .. y .. "," .. z .. " is solid in the map"
    for _, c in ipairs(options) do
        local ok, reason, name, cell = true, nil, nil, nil
        if not T.at(c) then ok, reason, name, cell = T.moveTo(c.x, c.y, c.z, opts.move) end
        if ok then
            local found, state = lookAt(x, y, z, c.d)
            settle(false)
            return found, state
        end
        why = reason
        if mapped and type(name) == "string" and cell then setLocal(cell.x, cell.y, cell.z, name) end
    end
    settle(false)
    return nil, "couldn't get next to " .. x .. "," .. y .. "," .. z .. ": " .. tostring(why)
end

-- A cell given as { x = , y = , z = }, { x, y, z } or "x,y,z": x, y, z; nil if it isn't one.
local function cellOf(item)
    if type(item) == "string" then return T.keyPos(item) end
    if type(item) ~= "table" then return nil end
    if item.x ~= nil then return item.x, item.y, item.z end
    return item[1], item[2], item[3]
end

-- T.inspectAt for each cell of a list ({x, y, z} tables or "x,y,z" keys), nearest next: { ["x,y,z"] = {name, state} } and a list of {x, y, z, why} that failed.
--
-- Each time it goes next to the nearest one (greedy, not the shortest tour), and looks at any other cell beside it from there.
function T.inspectAll(list, opts)
    local pending, seen = {}, {}
    for _, item in ipairs(list or {}) do
        local x, y, z = cellOf(item)
        if whole(x) and whole(y) and whole(z) and not seen[x .. "," .. y .. "," .. z] then
            seen[x .. "," .. y .. "," .. z] = true
            pending[#pending + 1] = { x = x, y = y, z = z }
        end
    end
    local results, failed = {}, {}
    while #pending > 0 do
        local best = 1
        for i = 2, #pending do
            if T.dist(T.pos, pending[i]) < T.dist(T.pos, pending[best]) then best = i end
        end
        local p = table.remove(pending, best)
        local name, state = T.inspectAt(p.x, p.y, p.z, opts)
        if name then
            results[p.x .. "," .. p.y .. "," .. p.z] = { name = name, state = state }
            -- anything else beside the turtle now is a look away
            for i = #pending, 1, -1 do
                local q = pending[i]
                if T.dist(T.pos, q) == 1 then
                    local qname, qstate = lookAt(q.x, q.y, q.z, T.dirTo(q))
                    results[q.x .. "," .. q.y .. "," .. q.z] = { name = qname, state = qstate }
                    table.remove(pending, i)
                end
            end
        else
            failed[#failed + 1] = { x = p.x, y = p.y, z = p.z, why = state }
        end
    end
    ensure()
    settle(true)
    return results, failed
end

return T
