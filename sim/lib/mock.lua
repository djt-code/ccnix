-- sim/lib/mock.lua -- the CC:Tweaked mocks the simulators share
--
-- A simulator builds its world from one of the fixtures next to this file
-- (farmworld.lua, mineworld.lua, composter.lua); they build the mocked
-- APIs (turtle, fs, peripheral, sleep, ...) from the pieces here.  The
-- pieces work on a state table S the fixture owns:
--   S.inv[1..16] = { name, count }, S.sel      the turtle's inventory
--   S.P = { x, y, z, d }                       where it is and faces (d as T.dir)
--   S.moves, S.turns                           how much it has moved
--   S.files[path] = contents                   the computer's files
--   S.log                                      what the program printed
-- and on a few globals that scenarios set as knobs and read as counters,
-- as the simulators always have: FUEL (nil: unlimited), LOWEST, DRY (moves
-- tried on an empty tank), EQ (the upgrades on each side), SPLIT (pickups
-- that started a second part stack), SPILLED (items that didn't fit).
--
-- Items are stored as the game stores them: a pickup goes into the first
-- slot, counting on from the selected one, that is empty or holds the same
-- item; a container is filled into matching stacks first, then empty
-- slots; sucking takes the container's first stack.

local M = {}

M.DX = { [0] = 0, 1, 0, -1 }
M.DZ = { [0] = 1, 0, -1, 0 }
M.SIDES6 = { { 1, 0, 0 }, { -1, 0, 0 }, { 0, 1, 0 }, { 0, -1, 0 }, { 0, 0, 1 }, { 0, 0, -1 } }
M.SIDES4 = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }

function M.key(x, y, z) return x .. "," .. y .. "," .. z end

-- Join the pieces into one table (later ones win).
function M.merge(...)
    local t = {}
    for i = 1, select("#", ...) do
        for k, v in pairs(select(i, ...) or {}) do t[k] = v end
    end
    return t
end

--------------------------------------------------------------------------
-- Items
--------------------------------------------------------------------------
-- How many of an item make a stack: tools and water buckets one, empty
-- buckets 16, everything else 64.
function M.stackSize(name)
    if name:find("_pickaxe$") or name:find("_hoe$") or name:find("_axe$") or name:find("_shovel$")
        or name:find("_sword$") or name == "minecraft:water_bucket" or name == "minecraft:lava_bucket" then
        return 1
    end
    if name == "minecraft:bucket" then return 16 end
    return 64
end

-- Put n of `name` in the turtle's inventory as CC:Tweaked does: into the
-- first slot, counting on from the selected one, that is empty or holds
-- the same item (an empty slot ahead of a part stack starts a second
-- stack: SPLIT counts those).  What doesn't fit is SPILLED; false then.
function M.addItem(S, name, n)
    local max = M.stackSize(name)
    local part = false
    for s = 1, 16 do
        local it = S.inv[s]
        if it and it.name == name and it.count < max then part = true end
    end
    for i = 0, 15 do
        local s = (S.sel - 1 + i) % 16 + 1
        local it = S.inv[s]
        if not it then
            if part then SPLIT = (SPLIT or 0) + 1 end
            S.inv[s] = { name = name, count = math.min(n, max) }
            n = n - S.inv[s].count
        elseif it.name == name and it.count < max then
            local take = math.min(n, max - it.count)
            it.count = it.count + take
            n = n - take
        end
        if n == 0 then return true end
    end
    SPILLED = (SPILLED or 0) + n
    return false
end

-- Take n (one) from the selected slot.
function M.useSel(S, n)
    local it = S.inv[S.sel]
    it.count = it.count - (n or 1)
    if it.count <= 0 then S.inv[S.sel] = nil end
end

-- How many of `name` the turtle holds.
function M.carried(S, name)
    local n = 0
    for s = 1, 16 do
        local it = S.inv[s]
        if it and it.name == name then n = n + it.count end
    end
    return n
end

-- The turtle's inventory functions.
function M.inventoryApi(S)
    return {
        select = function(s) S.sel = s; return true end,
        getSelectedSlot = function() return S.sel end,
        getItemCount = function(s) local it = S.inv[s or S.sel]; return it and it.count or 0 end,
        getItemDetail = function(s)
            local it = S.inv[s or S.sel]
            return it and { name = it.name, count = it.count } or nil
        end,
        getItemSpace = function(s)
            local it = S.inv[s or S.sel]
            return it and (M.stackSize(it.name) - it.count) or 64
        end,
        transferTo = function(to, n)
            local it, dst = S.inv[S.sel], S.inv[to]
            if not it or to == S.sel then return false end
            if dst and dst.name ~= it.name then return false end
            local k = math.min(n or it.count, it.count, M.stackSize(it.name) - (dst and dst.count or 0))
            if k <= 0 then return false end
            S.inv[to] = { name = it.name, count = (dst and dst.count or 0) + k }
            it.count = it.count - k
            if it.count == 0 then S.inv[S.sel] = nil end
            return true
        end,
    }
end

--------------------------------------------------------------------------
-- Containers: c[slot] = { name, count }, `size` slots
--------------------------------------------------------------------------
-- Drop n from the selected slot into the container (matching stacks
-- first, then empty slots).  True if any went in.
function M.dropInto(S, c, size, n)
    local it = S.inv[S.sel]
    if not it then return false end
    n = math.min(n or it.count, it.count)
    local max = M.stackSize(it.name)
    local left = n
    for s = 1, size do
        local d = c[s]
        if d and d.name == it.name and d.count < max then
            local t = math.min(left, max - d.count)
            d.count = d.count + t
            left = left - t
        end
    end
    for s = 1, size do
        if left == 0 then break end
        if not c[s] then
            c[s] = { name = it.name, count = math.min(left, max) }
            left = left - c[s].count
        end
    end
    local moved = n - left
    it.count = it.count - moved
    if it.count == 0 then S.inv[S.sel] = nil end
    return moved > 0
end

-- Suck up to n from the container's first stack: into the selected slot
-- first, then any slot holding the same item, then empty ones (as CC
-- does).  True if anything came out.
function M.suckFrom(S, c, size, n)
    for s = 1, size do
        local d = c[s]
        if d then
            local max = M.stackSize(d.name)
            local want = math.min(n or 64, d.count)
            local left = want
            local order = { S.sel }
            for i = 1, 16 do if i ~= S.sel then order[#order + 1] = i end end
            for pass = 1, 2 do
                for _, i in ipairs(order) do
                    local it = S.inv[i]
                    if left > 0 and it and it.name == d.name and it.count < max then
                        local t = math.min(left, max - it.count)
                        it.count = it.count + t
                        left = left - t
                    elseif left > 0 and not it and (pass == 2 or i == S.sel) then
                        S.inv[i] = { name = d.name, count = math.min(left, max) }
                        left = left - S.inv[i].count
                    end
                end
            end
            local took = want - left
            d.count = d.count - took
            if d.count == 0 then c[s] = nil end
            return took > 0
        end
    end
    return false
end

-- The container as a peripheral (what peripheral.wrap gives): list, size,
-- getItemDetail and pushItems.  `name` is what peripheral.getName says.
function M.containerPeripheral(c, size, name)
    return {
        size = function() return size end,
        list = function()
            local t = {}
            for s = 1, size do
                if c[s] then t[s] = { name = c[s].name, count = c[s].count } end
            end
            return t
        end,
        getItemDetail = function(s)
            local d = c[s]
            return d and { name = d.name, count = d.count, maxCount = M.stackSize(d.name) } or nil
        end,
        pushItems = function(to, from, limit, toSlot)
            local d = c[from]
            if not d then return 0 end
            local t = c[toSlot]
            if t and t.name ~= d.name then return 0 end
            local n = math.min(limit or 64, d.count, M.stackSize(d.name) - (t and t.count or 0))
            if t then t.count = t.count + n else c[toSlot] = { name = d.name, count = n } end
            d.count = d.count - n
            if d.count == 0 then c[from] = nil end
            PUSHES = (PUSHES or 0) + 1
            return n
        end,
        _name = name,
    }
end

-- How many of each item a container holds, and a sorted "n name, ..." line.
function M.contents(c, size)
    local n, order = {}, {}
    for s = 1, (size or #c) do
        local d = c and c[s]
        if d then
            if not n[d.name] then n[d.name] = 0; order[#order + 1] = d.name end
            n[d.name] = n[d.name] + d.count
        end
    end
    table.sort(order)
    local parts = {}
    for _, name in ipairs(order) do parts[#parts + 1] = n[name] .. " " .. name:gsub("^%a+:", "") end
    return table.concat(parts, ", "), n
end

--------------------------------------------------------------------------
-- The turtle, in pieces
--------------------------------------------------------------------------
-- Moving and turning.  `passable(block)` says what it can move into;
-- `onMove(ox, oy, oz, nx, ny, nz)` runs before a move, `moved(ox, oy, oz)`
-- after one and `turned()` after a turn (for a world that moves on with
-- time).  Fuel: with FUEL a number, a move burns one and fails on an
-- empty tank (DRY counts the tries, LOWEST the least fuel seen).
function M.movementApi(S, passable, hooks)
    hooks = hooks or {}
    local function move(dx, dy, dz)
        if FUEL ~= nil and FUEL <= 0 then DRY = (DRY or 0) + 1; return false end
        local nx, ny, nz = S.P.x + dx, S.P.y + dy, S.P.z + dz
        if not passable(S.get(nx, ny, nz)) then return false end
        if hooks.onMove then hooks.onMove(S.P.x, S.P.y, S.P.z, nx, ny, nz) end
        local ox, oy, oz = S.P.x, S.P.y, S.P.z
        S.P.x, S.P.y, S.P.z = nx, ny, nz
        S.moves = S.moves + 1
        if FUEL ~= nil then
            FUEL = FUEL - 1
            LOWEST = math.min(LOWEST or FUEL, FUEL)
        end
        if hooks.moved then hooks.moved(ox, oy, oz) end
        return true
    end
    local function turn(by)
        S.P.d = (S.P.d + by) % 4
        S.turns = S.turns + 1
        if hooks.turned then hooks.turned() end
        return true
    end
    return {
        forward = function() return move(M.DX[S.P.d], 0, M.DZ[S.P.d]) end,
        back = function() return move(-M.DX[S.P.d], 0, -M.DZ[S.P.d]) end,
        up = function() return move(0, 1, 0) end,
        down = function() return move(0, -1, 0) end,
        turnRight = function() return turn(1) end,
        turnLeft = function() return turn(3) end,
    }
end

-- The block in front of, above and below the turtle.
function M.front(S) return S.P.x + M.DX[S.P.d], S.P.y, S.P.z + M.DZ[S.P.d] end
function M.above(S) return S.P.x, S.P.y + 1, S.P.z end
function M.below(S) return S.P.x, S.P.y - 1, S.P.z end
function M.behind(S) return S.P.x - M.DX[S.P.d], S.P.y, S.P.z - M.DZ[S.P.d] end

-- Looking: inspect and detect each way.  `inspectAt(x, y, z)` returns
-- what turtle.inspect would; `solid(block)` what detect counts.
function M.lookingApi(S, inspectAt, solid)
    return {
        inspect = function() return inspectAt(M.front(S)) end,
        inspectUp = function() return inspectAt(M.above(S)) end,
        inspectDown = function() return inspectAt(M.below(S)) end,
        detect = function() return solid(S.get(M.front(S))) end,
        detectUp = function() return solid(S.get(M.above(S))) end,
        detectDown = function() return solid(S.get(M.below(S))) end,
    }
end

-- Acting on the block each way: `f(x, y, z, dir)` for dig/place/drop/
-- suck, dir "front", "up" or "down".  Each gets the extra arguments
-- (place's text, drop and suck's count) after dir.
function M.actingApi(S, name, f)
    local api = {}
    api[name] = function(...) local x, y, z = M.front(S); return f(x, y, z, "front", ...) end
    api[name .. "Up"] = function(...) local x, y, z = M.above(S); return f(x, y, z, "up", ...) end
    api[name .. "Down"] = function(...) local x, y, z = M.below(S); return f(x, y, z, "down", ...) end
    return api
end

function M.noAttackApi()
    return {
        attack = function() return false end,
        attackUp = function() return false end,
        attackDown = function() return false end,
    }
end

-- Upgrades on each side (the global EQ = { left = name, right = name }):
-- equipping swaps the selected slot with the side.  `onEquip(side)` runs
-- after a swap.
function M.equipmentApi(S, onEquip)
    local function equip(side)
        local it = S.inv[S.sel]
        S.inv[S.sel] = EQ[side] and { name = EQ[side], count = 1 } or nil
        EQ[side] = it and it.name
        if onEquip then onEquip(side) end
        return true
    end
    return {
        equipLeft = function() return equip("left") end,
        equipRight = function() return equip("right") end,
        getEquippedLeft = function() return EQ.left and { name = EQ.left } or nil end,
        getEquippedRight = function() return EQ.right and { name = EQ.right } or nil end,
    }
end

-- Fuel: the global FUEL, a number (as on a survival server) or nil for a
-- turtle that needs none.  Burning fuel is worth what `values` says
-- (coal 80, charcoal 80, a lava bucket 1000, which leaves the bucket).
M.FUEL_VALUE = { ["minecraft:coal"] = 80, ["minecraft:charcoal"] = 80, ["minecraft:lava_bucket"] = 1000 }
M.FUEL_LIMIT = 20000
function M.fuelApi(S, values)
    values = values or M.FUEL_VALUE
    return {
        refuel = function(n)
            local it = S.inv[S.sel]
            if not it or not values[it.name] then return false end
            if FUEL == nil then return true end
            n = math.min(n or it.count, it.count)
            for _ = 1, n do
                if FUEL + values[it.name] > M.FUEL_LIMIT then break end
                FUEL = FUEL + values[it.name]
                if it.name == "minecraft:lava_bucket" then
                    S.inv[S.sel] = { name = "minecraft:bucket", count = 1 }
                    break
                end
                it.count = it.count - 1
                if it.count == 0 then S.inv[S.sel] = nil; break end
            end
            return true
        end,
        getFuelLevel = function() return FUEL == nil and "unlimited" or FUEL end,
        getFuelLimit = function() return M.FUEL_LIMIT end,
    }
end

--------------------------------------------------------------------------
-- The computer: files, the shell, printing
--------------------------------------------------------------------------
-- fs over S.files (path -> contents), as far as the programs use it.
function M.fsApi(S)
    -- as CC's: the parts joined, no leading or trailing slash, . and .. resolved
    local function combine(...)
        local out = {}
        for _, part in ipairs({ ... }) do
            for seg in tostring(part):gmatch("[^/\\]+") do
                if seg == ".." then out[#out] = nil elseif seg ~= "." then out[#out + 1] = seg end
            end
        end
        return table.concat(out, "/")
    end
    S.dirs = S.dirs or {}
    return {
        combine = combine,
        -- the folder part ("" at the root, and CC's ".." for the root itself)
        getDir = function(p) p = combine(p); return p == "" and ".." or p:match("^(.*)/[^/]*$") or "" end,
        exists = function(p) p = combine(p); return S.files[p] ~= nil or S.dirs[p] ~= nil end,
        isDir = function(p) return S.dirs[combine(p)] ~= nil end,
        makeDir = function(p) S.dirs[combine(p)] = true end,
        isReadOnly = function() return false end,
        getSize = function(p) return #(S.files[combine(p)] or "") end,
        -- the names in a folder: its files' and folders' next part, sorted
        list = function(p)
            p = combine(p)
            local seen, out = {}, {}
            local function add(key)
                local rest = p == "" and key or (key:sub(1, #p + 1) == p .. "/" and key:sub(#p + 2))
                local name = rest and rest:match("^[^/]+")
                if name and not seen[name] then seen[name] = true; out[#out + 1] = name end
            end
            for k in pairs(S.files) do add(k) end
            for k in pairs(S.dirs) do add(k) end
            table.sort(out)
            return out
        end,
        -- (a folder with all that's in it, as CC's does)
        delete = function(p)
            p = combine(p)
            S.files[p], S.dirs[p] = nil, nil
            for _, t in ipairs({ S.files, S.dirs }) do
                for k in pairs(t) do if k:sub(1, #p + 1) == p .. "/" then t[k] = nil end end
            end
        end,
        copy = function(a, b) S.files[combine(b)] = S.files[combine(a)] end,
        move = function(a, b) a, b = combine(a), combine(b); S.files[b], S.files[a] = S.files[a], nil end,
        open = function(p, mode)
            p = combine(p)
            if mode == "w" or mode == "a" or mode == "wb" or mode == "ab" then       -- (binary modes write the same bytes)
                local buf = { (mode == "a" or mode == "ab") and S.files[p] or nil }
                return {
                    write = function(s) buf[#buf + 1] = s end,
                    writeLine = function(s) buf[#buf + 1] = s .. "\n" end,
                    close = function() S.files[p] = table.concat(buf) end,
                }
            end
            local data = S.files[p]
            if not data then return nil end
            local pos = 1
            return {
                readAll = function() return data end,
                readLine = function()
                    if pos > #data then return nil end
                    local e = data:find("\n", pos) or #data + 1
                    local l = data:sub(pos, e - 1)
                    pos = e + 1
                    return l
                end,
                close = function() end,
            }
        end,
    }
end

function M.shellApi(prog)
    return { getRunningProgram = function() return prog end, resolve = function(p) return p end }
end

--------------------------------------------------------------------------
-- JSON, as textutils.serialiseJSON/unserialiseJSON do it: a table with
-- keys 1..n is an array, any other table an object (keys in order, so the
-- output repeats), null reads as nil.  Bytes past ASCII as CC writes them:
-- each one its own \u00XX, or with { unicode_strings = true } as UTF-8 (an
-- error if the string isn't UTF-8, as CC's utf8.codes gives).
--------------------------------------------------------------------------
local json = {}
M.json = json

local function isArray(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n > 0 and n == #t
end

local ESC = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }
function json.encode(v, opts)
    local t = type(v)
    if t == "nil" then return "null" end
    if t == "boolean" then return tostring(v) end
    if t == "number" then
        if math.type and math.type(v) == "integer" or v == math.floor(v) then return string.format("%d", v) end
        return string.format("%.14g", v)
    end
    if t == "string" then
        local s = v:gsub('[%c"\\]', function(c) return ESC[c] or string.format("\\u%04x", c:byte()) end)
        if opts and opts.unicode_strings then
            if not utf8.len(v) then error("bad argument #1 (invalid UTF-8 code)", 0) end
        else
            s = s:gsub("[\128-\255]", function(c) return string.format("\\u%04X", c:byte()) end)
        end
        return '"' .. s .. '"'
    end
    if t ~= "table" then error("can't serialise a " .. t) end
    if v == M.EMPTY_ARRAY then return "[]" end
    if isArray(v) then
        local parts = {}
        for i = 1, #v do parts[i] = json.encode(v[i], opts) end
        return "[" .. table.concat(parts, ",") .. "]"
    end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do parts[#parts + 1] = json.encode(k, opts) .. ":" .. json.encode(v[k], opts) end
    return "{" .. table.concat(parts, ",") .. "}"
end
M.EMPTY_ARRAY = setmetatable({}, { __name = "empty_json_array" })
-- (the API sends UTF-8 as it is)
local UTF8 = { unicode_strings = true }

function json.decode(s)
    local pos = 1
    local function skip() pos = s:find("%S", pos) or #s + 1 end
    local value
    local function str()
        local out = {}
        pos = pos + 1
        while true do
            local c = s:sub(pos, pos)
            if c == "" then error("unterminated string") end
            if c == '"' then pos = pos + 1; return table.concat(out) end
            if c == "\\" then
                local e = s:sub(pos + 1, pos + 1)
                local map = { n = "\n", r = "\r", t = "\t", b = "\b", f = "\f", ['"'] = '"', ["\\"] = "\\", ["/"] = "/" }
                if e == "u" then
                    out[#out + 1] = utf8 and utf8.char(tonumber(s:sub(pos + 2, pos + 5), 16)) or "?"
                    pos = pos + 6
                else
                    out[#out + 1] = map[e] or e
                    pos = pos + 2
                end
            else
                out[#out + 1] = c
                pos = pos + 1
            end
        end
    end
    function value()
        skip()
        local c = s:sub(pos, pos)
        if c == "{" then
            local t = {}
            pos = pos + 1
            skip()
            if s:sub(pos, pos) == "}" then pos = pos + 1; return t end
            while true do
                skip()
                local k = str()
                skip()
                assert(s:sub(pos, pos) == ":", "expected : at " .. pos)
                pos = pos + 1
                t[k] = value()
                skip()
                local d = s:sub(pos, pos)
                pos = pos + 1
                if d == "}" then return t end
                assert(d == ",", "expected , at " .. pos)
            end
        elseif c == "[" then
            local t = {}
            pos = pos + 1
            skip()
            if s:sub(pos, pos) == "]" then pos = pos + 1; return t end
            while true do
                t[#t + 1] = value()
                skip()
                local d = s:sub(pos, pos)
                pos = pos + 1
                if d == "]" then return t end
                assert(d == ",", "expected , at " .. pos)
            end
        elseif c == '"' then
            return str()
        else
            local lit = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
            if lit and lit ~= "" then pos = pos + #lit; return tonumber(lit) end
            for word, v in pairs({ ["true"] = true, ["false"] = false, ["null"] = json.NULL }) do
                if s:sub(pos, pos + #word - 1) == word then pos = pos + #word; return v end
            end
            error("bad JSON at " .. pos .. ": " .. s:sub(pos, pos + 20))
        end
    end
    local v = value()
    return v
end
json.NULL = nil                -- null reads as nil, as textutils does by default

-- textutils, as far as the programs use it.
function M.textutilsApi()
    local function serialise(v, opts)
        if type(v) ~= "table" then
            if type(v) == "string" then return string.format("%q", v) end
            return tostring(v)
        end
        local parts = {}
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = k end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        for _, k in ipairs(keys) do
            local key = type(k) == "string" and k:match("^[%a_][%w_]*$") and k or ("[" .. serialise(k) .. "]")
            parts[#parts + 1] = key .. "=" .. serialise(v[k], opts)
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return {
        serialiseJSON = function(v, opts) return json.encode(v, opts) end,
        serializeJSON = function(v, opts) return json.encode(v, opts) end,
        unserialiseJSON = function(s) local ok, v = pcall(json.decode, s); if ok then return v end; return nil, v end,
        unserializeJSON = function(s) local ok, v = pcall(json.decode, s); if ok then return v end; return nil, v end,
        serialise = serialise, serialize = serialise,
        unserialize = function(s) return M.textutilsApi().unserialise(s) end,
        unserialise = function(s)
            local f = load("return " .. s, "=unserialise", "t", {})
            if not f then return nil end
            local ok, v = pcall(f)
            if ok then return v end
        end,
        empty_json_array = M.EMPTY_ARRAY,
    }
end

--------------------------------------------------------------------------
-- A scripted http: each post takes the next reply off H.queue and keeps
-- the request (its decoded body and headers) in H.requests.  A reply is
-- { code = 200, body = <table> }, or { fail = "reason" } for no
-- connection; an empty queue is an error.
--------------------------------------------------------------------------
-- A Messages API reply as the server-sent events of a streamed response:
-- text, thinking and tool input in small deltas, a ping between blocks.
function M.sse(msg)
    local out = {}
    local function ev(t) out[#out + 1] = "event: " .. t.type .. "\ndata: " .. json.encode(t, UTF8) .. "\n\n" end
    local function pieces(s, n)
        local t = {}
        for i = 1, #s, n do t[#t + 1] = s:sub(i, i + n - 1) end
        return t
    end
    local start = {}
    for k, v in pairs(msg) do if k ~= "content" and k ~= "stop_reason" and k ~= "stop_details" then start[k] = v end end
    start.content, start.stop_reason = {}, nil
    local u = msg.usage or {}
    start.usage = { input_tokens = u.input_tokens, cache_read_input_tokens = u.cache_read_input_tokens,
                    cache_creation_input_tokens = u.cache_creation_input_tokens, output_tokens = 1 }
    ev({ type = "message_start", message = start })
    for i, b in ipairs(msg.content or {}) do
        local idx = i - 1
        ev({ type = "ping" })
        if b.type == "text" then
            ev({ type = "content_block_start", index = idx, content_block = { type = "text", text = "" } })
            for _, p in ipairs(pieces(b.text, 5)) do ev({ type = "content_block_delta", index = idx, delta = { type = "text_delta", text = p } }) end
            for _, c in ipairs(b.citations or {}) do   -- a quoted web page each
                ev({ type = "content_block_delta", index = idx, delta = { type = "citations_delta", citation = c } })
            end
        elseif b.type == "thinking" then
            ev({ type = "content_block_start", index = idx, content_block = { type = "thinking", thinking = "", signature = "" } })
            for _, p in ipairs(pieces(b.thinking, 5)) do ev({ type = "content_block_delta", index = idx, delta = { type = "thinking_delta", thinking = p } }) end
            ev({ type = "content_block_delta", index = idx, delta = { type = "signature_delta", signature = b.signature } })
        elseif b.type == "tool_use" or b.type == "server_tool_use" then
            ev({ type = "content_block_start", index = idx, content_block = { type = b.type, id = b.id, name = b.name, input = {} } })
            local input = json.encode(b.input or {}, UTF8)
            if input ~= "[]" and input ~= "{}" then
                for _, p in ipairs(pieces(input, 7)) do ev({ type = "content_block_delta", index = idx, delta = { type = "input_json_delta", partial_json = p } }) end
            end
        else
            ev({ type = "content_block_start", index = idx, content_block = b })
        end
        ev({ type = "content_block_stop", index = idx })
    end
    ev({ type = "message_delta", delta = { stop_reason = msg.stop_reason, stop_details = msg.stop_details },
         usage = { output_tokens = msg.usage and msg.usage.output_tokens }, context_management = msg.context_management })
    ev({ type = "message_stop" })
    return table.concat(out)
end

function M.httpApi()
    local H = { queue = {}, requests = {} }
    local function handle(code, text)
        return {
            getResponseCode = function() return code end,
            readAll = function() return text end,
            close = function() end,
        }
    end
    H.api = {
        post = function(req, body, headers)
            if type(req) == "table" then
                -- as rom/apis/http/http.lua checks it
                if req.timeout ~= nil and not (req.timeout >= 0 and req.timeout <= 60) then
                    error("timeout out of range (between 0.0 and 60.0)", 2)
                end
                body, headers = req.body, req.headers; req = req.url
            end
            H.requests[#H.requests + 1] = { url = req, headers = headers, body = json.decode(body) }
            local r = table.remove(H.queue, 1)
            if not r then error("http.post with nothing scripted for it (request " .. #H.requests .. ")") end
            if r.fail then return nil, r.fail, nil end
            local text = type(r.body) == "string" and r.body or json.encode(r.body, UTF8)
            local asked = H.requests[#H.requests].body
            if r.code == 200 and type(asked) == "table" and asked.stream and type(r.body) == "table" then
                text = M.sse(r.body)        -- a streamed request gets the reply as events
            end
            if r.code == 200 then return handle(200, text) end
            return nil, "HTTP " .. r.code, handle(r.code, text)
        end,
        get = function() error("http.get isn't scripted") end,
        checkURL = function() return true end,
    }
    return H
end

-- The keyboard: read() takes the next answer off `answers` (an error
-- when there is none: the program asked something unexpected); write()
-- shows up in the program's output.
function M.consoleApi(S, answers)
    read = function()
        if #answers == 0 then error("read() with no answer scripted") end
        return table.remove(answers, 1)
    end
    write = function(s) print(s) end
    return answers
end

-- A w x h screen (the turtle's is 39 x 13): term draws into T.rows (one
-- string per row), T.inverse[r] says a row was last written black on
-- white.  os.pullEvent takes the next of T.events, { "char", "q" } or
-- { "key", keys.up } (an error when there is none: the program waited for
-- a key nobody pressed).  keys holds the CC key codes the programs use.
function M.termApi(w, h)
    local T = { rows = {}, inverse = {}, events = {}, x = 1, y = 1, w = w, h = h, scrolledOff = {} }
    for r = 1, h do T.rows[r] = string.rep(" ", w) end
    local bg = "black"
    colours = colours or { black = "black", white = "white" }
    colors = colors or colours
    keys = keys or { up = 200, down = 208, left = 203, right = 205, pageUp = 201, pageDown = 209,
                     home = 199, ["end"] = 207, enter = 28 }
    term = {
        getSize = function() return T.w, T.h end,
        setCursorPos = function(x, y) T.x, T.y = x, y end,
        getCursorPos = function() return T.x, T.y end,
        setBackgroundColour = function(c) bg = c end,
        setTextColour = function() end,
        isColour = function() return false end,
        clearLine = function() T.rows[T.y] = string.rep(" ", T.w); T.inverse[T.y] = bg == "white" end,
        -- (the rows going off the top kept in T.scrolledOff, as the console's scrollback keeps them)
        scroll = function(n)
            for _ = 1, n do
                T.scrolledOff[#T.scrolledOff + 1] = (table.remove(T.rows, 1):gsub("%s+$", ""))
                T.rows[T.h] = string.rep(" ", T.w)
                for r = 1, T.h - 1 do T.inverse[r] = T.inverse[r + 1] end
                T.inverse[T.h] = nil
            end
        end,
        write = function(s)
            s = tostring(s)
            local row = T.rows[T.y]
            if row then
                local from, to = math.max(T.x, 1), math.min(T.x + #s - 1, T.w)
                if to >= from then
                    T.rows[T.y] = row:sub(1, from - 1) .. s:sub(from - T.x + 1, to - T.x + 1) .. row:sub(to + 1)
                end
                T.inverse[T.y] = bg == "white"
            end
            T.x = T.x + #s
        end,
    }
    term.setBackgroundColor, term.setTextColor, term.isColor = term.setBackgroundColour, term.setTextColour, term.isColour
    os.pullEvent = function()
        if #T.events == 0 then error("os.pullEvent with no event scripted") end
        return table.unpack(table.remove(T.events, 1))
    end
    -- the screen's text rows, trailing spaces trimmed
    function T.text(r) return (T.rows[r]:gsub("%s+$", "")) end
    return T
end

-- The print the simulator keeps for itself; the program's print goes to
-- S.log (see M.capturePrint).
M.realPrint = print

local function join(...)
    local t = {}
    for i = 1, select("#", ...) do t[#t + 1] = tostring(select(i, ...)) end
    return table.concat(t, " ")
end

-- Make `print` collect the program's lines in S.log; `each(line)`, if
-- given, sees every line as it comes.
function M.capturePrint(S, each)
    print = function(...)
        local line = join(...)
        if each then each(line) end
        S.log[#S.log + 1] = line
    end
end

-- Did the program print a line matching `pat`?
function M.logHas(S, pat)
    for _, l in ipairs(S.log) do if l:find(pat) then return true end end
    return false
end

-- A result line: "ok   label" or "ERROR: label" (which fails the run).
function M.check(label, ok, detail)
    M.realPrint(string.format("   %s %s%s", ok and "ok   " or "ERROR:", label, detail and ("  (" .. detail .. ")") or ""))
end

-- A function that runs the program at `path` with the arguments it's
-- given, as the simulators report it: the program's name and arguments
-- and `opts.stats()` on a "==" line, then what it printed, then how it
-- ended and where the turtle is.  opts:
--   before()        before each run (reset counters)
--   after(ok, err)  after it
--   stats()         the figures for the header ("moves: 12")
--   stopped(err)    a line for an error that was expected (a simulated
--                   Ctrl+T, say), or nil for a real one
--   keep(line)      false to leave a line of the program's out
function M.runner(S, path, opts)
    opts = opts or {}
    local name = path:match("([^/]+)%.lua$") or path
    return function(...)
        S.log, S.moves, S.turns = {}, 0, 0
        if opts.before then opts.before() end
        package.loaded.turtlelib = nil
        local chunk = assert(loadfile(path))
        local ok, err = pcall(chunk, ...)
        if opts.after then opts.after(ok, err) end
        local stats = opts.stats and opts.stats() or ("moves: " .. S.moves)
        M.realPrint("== " .. name .. " " .. table.concat({ ... }, " ") .. "  (" .. stats .. ")")
        for _, l in ipairs(S.log) do
            if not opts.keep or opts.keep(l) then M.realPrint("   " .. l) end
        end
        if not ok then
            local line = opts.stopped and opts.stopped(err)
            M.realPrint("   " .. (line or ("ERROR: " .. tostring(err))))
        end
        M.realPrint(string.format("   ends at (%d,%d,%d) facing %d", S.P.x, S.P.y, S.P.z, S.P.d))
        return ok, err
    end
end

-- A fresh state table.
function M.state()
    return { inv = {}, sel = 1, P = { x = 0, y = 0, z = 0, d = 0 }, moves = 0, turns = 0, files = {}, log = {} }
end

return M
