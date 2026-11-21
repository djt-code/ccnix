-- sim/turtlelib_equip.lua
--
-- T.withPeripheral and T.equipPeripheral (ADR-0008): an upgrade swapped in
-- for the time it is used, on the side that holds no chunk controller,
-- waited for until it shows up as a peripheral, and put back even when the
-- code using it errors; and T.pull, a count of one item out of a mixed chest.
local PROJ = ...
package.path = PROJ .. "/turtle/?.lua;" .. PROJ .. "/lib/?.lua;" .. PROJ .. "/sim/lib/?.lua;" .. package.path
local M = require("mock")
local check = M.check

local S = M.state()
fs = M.fsApi(S)
shell = M.shellApi("x.lua")
SLEEPS = 0
sleep = function() SLEEPS = SLEEPS + 1 end

local CONTROLLER = "advancedperipherals:chunk_controller"
local SCANNER = "advancedperipherals:geo_scanner"
local CHAT = "advancedperipherals:chat_box"
local PICK = "minecraft:diamond_pickaxe"
-- the peripherals the upgrades are: their type and methods; the sides
-- front, top and bottom hold a chest
local PERIPHERALS = {
    [CONTROLLER] = { type = "chunky", methods = { "getLoadedChunks" } },
    [SCANNER] = { type = "geoScanner", methods = { "scanBlocks" } },
    [CHAT] = { type = "chatBox", methods = { "sendMessage" } },
}
LAG = 0                                -- polls after an equip before the peripheral shows up
local polls, lastEq = {}, {}           -- per side: asked since the upgrade there changed
EQ = {}
local function seen(side)
    if lastEq[side] ~= EQ[side] then lastEq[side], polls[side] = EQ[side], 0 end
    polls[side] = polls[side] + 1
    return PERIPHERALS[EQ[side]], polls[side] > LAG
end

local chest, CHEST_SIZE = {}, 27
local chestPeripheral = M.containerPeripheral(chest, CHEST_SIZE, "chest_0")
peripheral = {
    getType = function(side)
        if side == "left" or side == "right" then
            local p, ready = seen(side)
            return p and ready and p.type or nil
        end
        return "minecraft:chest"
    end,
    getMethods = function(side)
        local p, ready = seen(side)
        return p and ready and p.methods or {}
    end,
    wrap = function(side)
        if side == "left" or side == "right" then
            local p, ready = seen(side)
            if not (p and ready) then return nil end
            local wrapped = { _is = p.type }
            for _, m in ipairs(p.methods) do wrapped[m] = function() return "result of " .. m end end
            return wrapped
        end
        return chestPeripheral
    end,
    getName = function(p) return p._name end,
}
-- a dig in front: only with a pickaxe on (CC's why without one)
local DIGS_WITH = { ["minecraft:diamond_pickaxe"] = true, ["minecraft:iron_pickaxe"] = true }
DUG = 0
turtle = M.merge(M.inventoryApi(S), M.equipmentApi(S), M.fuelApi(S),
    M.actingApi(S, "dig", function()
        if not (DIGS_WITH[EQ.left] or DIGS_WITH[EQ.right]) then return false, "No tool to dig with" end
        DUG = DUG + 1
        return true
    end),
    M.actingApi(S, "suck", function(_, _, _, _, n) return M.suckFrom(S, chest, CHEST_SIZE, n) end),
    M.actingApi(S, "drop", function(_, _, _, _, n) return M.dropInto(S, chest, CHEST_SIZE, n) end))

package.loaded.turtlelib = nil
local T = require("turtlelib")
local function put(slot, name, count) S.inv[slot] = name and { name = name, count = count or 1 } or nil end
local function carrying(name)
    local n = 0
    for s = 1, 16 do
        if S.inv[s] and S.inv[s].name == name then n = n + S.inv[s].count end
    end
    return n
end
local function inChest(name)
    local n = 0
    for q = 1, CHEST_SIZE do
        if chest[q] and chest[q].name == name then n = n + chest[q].count end
    end
    return n
end
local function reset(left, right)
    S.inv, S.sel = {}, 1
    EQ = { left = left, right = right }
    lastEq, polls, LAG, SLEEPS = {}, {}, 0, 0
    T.cfg.keepSide = nil
end

--------------------------------------------------------------------------
-- withPeripheral
--------------------------------------------------------------------------
reset(CONTROLLER, PICK)
put(1, SCANNER)
local during
local ok, result = T.withPeripheral(SCANNER, function(p)
    during = { left = EQ.left, right = EQ.right }
    return p.scanBlocks(8)
end)
check("the scanner goes on the side without the chunk controller, and fn gets the peripheral",
    ok == true and result == "result of scanBlocks" and during.left == CONTROLLER and during.right == SCANNER)
check("afterwards the pickaxe is back, the controller never left, the scanner is in the inventory",
    EQ.left == CONTROLLER and EQ.right == PICK and carrying(SCANNER) == 1 and carrying(PICK) == 0)

reset(CONTROLLER, PICK)
put(1, SCANNER)
LAG = 4
ok, result = T.withPeripheral(SCANNER, function(p) return p.scanBlocks(8) end)
check("it waits for the scanner to show up as a peripheral", ok == true and result == "result of scanBlocks" and SLEEPS >= 4,
    SLEEPS .. " waits")

reset(PICK, CONTROLLER)
put(3, CHAT)
ok = T.withPeripheral(CHAT, function() during = { left = EQ.left, right = EQ.right } end)
check("with the controller on the right it uses the left", ok and during.right == CONTROLLER and during.left == CHAT
    and EQ.left == PICK and EQ.right == CONTROLLER)

-- errors
reset(CONTROLLER, PICK)
put(1, SCANNER)
local okErr, err = pcall(T.withPeripheral, SCANNER, function() error("the scan broke", 0) end)
check("an error in fn is thrown again, after everything is put back",
    not okErr and err == "the scan broke" and EQ.left == CONTROLLER and EQ.right == PICK and carrying(SCANNER) == 1, tostring(err))
okErr, err = pcall(T.withPeripheral, SCANNER, function() error("Terminated", 0) end)
check("so is Ctrl+T", not okErr and err == "Terminated" and EQ.left == CONTROLLER and EQ.right == PICK)

-- the controller is never taken off
reset(CONTROLLER, CONTROLLER)
put(1, SCANNER)
local p, why = T.equipPeripheral(SCANNER)
check("two chunk controllers leave nowhere: nil and why, nothing moved",
    p == nil and why and why:find("nowhere to put", 1, true) and EQ.left == CONTROLLER and EQ.right == CONTROLLER and carrying(SCANNER) == 1,
    tostring(why))
reset(CONTROLLER, PICK)
T.cfg.keepSide = "right"
put(1, SCANNER)
p, why = T.equipPeripheral(SCANNER)
check("T.cfg.keepSide keeps a side too: the controller's and the pickaxe's, so nowhere",
    p == nil and EQ.right == PICK and EQ.left == CONTROLLER, tostring(why))
reset(PICK, PICK)
T.cfg.keepSide = { "left" }
put(1, SCANNER)
ok = T.withPeripheral(SCANNER, function() during = { left = EQ.left, right = EQ.right } end)
check("a list of kept sides: the other one is used", ok and during.left == PICK and during.right == SCANNER and EQ.right == PICK)
T.cfg.keepSide = nil

-- preference: an empty side, then a tool
reset(CONTROLLER, nil)
put(1, SCANNER)
ok = T.withPeripheral(SCANNER, function() during = { left = EQ.left, right = EQ.right } end)
check("an empty side is used, and left empty after", ok and during.right == SCANNER and EQ.right == nil and carrying(SCANNER) == 1)
reset(CHAT, PICK)
put(1, SCANNER)
ok = T.withPeripheral(SCANNER, function() during = { left = EQ.left, right = EQ.right } end)
check("with another upgrade on one side and a tool on the other, the tool's side is used",
    ok and during.left == CHAT and during.right == SCANNER and EQ.right == PICK and EQ.left == CHAT)

-- opts.free (ADR-0012 D3): only an empty side or a tool's; no upgrade comes off
reset(SCANNER, PICK)
put(1, CHAT)
local fp, frestore = T.equipPeripheral(CHAT, { free = true })
check("opts.free: the tool's side, not the scanner's", fp and EQ.left == SCANNER and EQ.right == CHAT
    and frestore() and EQ.right == PICK and carrying(CHAT) == 1)
reset(CONTROLLER, SCANNER)
put(1, CHAT)
fp, why = T.equipPeripheral(CHAT, { free = true })
check("opts.free with the controller and the scanner on: nil and why, nothing moved",
    fp == nil and why == "neither side is free (left " .. CONTROLLER .. ", right " .. SCANNER .. "; an upgrade stays on): nowhere to put the " .. CHAT
        and EQ.left == CONTROLLER and EQ.right == SCANNER and carrying(CHAT) == 1, tostring(why))

-- already on
reset(CONTROLLER, SCANNER)
ok, result = T.withPeripheral(SCANNER, function(q) return q.scanBlocks(8) end)
check("an upgrade that is on already is used where it is, and left on", ok and result == "result of scanBlocks"
    and EQ.right == SCANNER and EQ.left == CONTROLLER)

-- the ways it can't
reset(CONTROLLER, PICK)
ok, why = T.withPeripheral(SCANNER, function() error("not run") end)
check("not on board: nil and why, fn not run", ok == nil and why == "no " .. SCANNER .. " on board", tostring(why))
ok, why = T.withPeripheral(PICK, function() end)
check("a tool is not a peripheral", ok == nil and why and why:find("T.withTool", 1, true), tostring(why))
put(1, "minecraft:dirt")
ok, why = T.withPeripheral("minecraft:dirt", function() error("not run") end)
check("an item that never shows up as a peripheral: nil and why, and everything put back",
    ok == nil and why and why:find("didn't show up", 1, true) and EQ.left == CONTROLLER and EQ.right == PICK
    and carrying("minecraft:dirt") == 1, tostring(why))
reset(CONTROLLER, PICK)
for s = 1, 15 do put(s, "minecraft:cobblestone", 64) end
put(16, SCANNER, 2)
p, why = T.equipPeripheral(SCANNER)
check("a stack of the upgrade in a full inventory: no free slot for what comes off, nothing moved",
    p == nil and why and why:find("no free slot", 1, true) and EQ.right == PICK, tostring(why))
put(16, SCANNER, 1)
ok = T.withPeripheral(SCANNER, function() end)
check("a single one needs no free slot (the pickaxe takes its place)", ok == true and EQ.right == PICK and carrying(SCANNER) == 1)

-- equipPeripheral by hand
reset(CONTROLLER, PICK)
put(1, SCANNER)
local q, restore = T.equipPeripheral(SCANNER)
check("T.equipPeripheral gives the peripheral and a restore", q and q.scanBlocks and type(restore) == "function" and EQ.right == SCANNER)
check("restore puts back, and a second call does nothing", restore() == true and EQ.right == PICK and restore() == true
    and EQ.right == PICK and carrying(SCANNER) == 1)

-- ADR-0019: restore puts back only over what it put on, checks the equip, and says why it didn't
local MODEM = "computercraft:wireless_modem_advanced"
local back, notBack
reset(CONTROLLER, PICK)
put(1, CHAT); put(2, MODEM)
q, restore = T.equipPeripheral(CHAT)
S.sel = 2; turtle.equipRight(); S.sel = 1        -- (a modem equipped by hand over the chat box)
back, notBack = restore()
check("a modem equipped by hand over the chat box stays on: false and why, the pickaxe left in the inventory",
    back == false and notBack == "the right side holds the " .. MODEM .. " now, not the " .. CHAT .. " put on: left as it is, and the "
        .. PICK .. " not put back" and EQ.right == MODEM and carrying(PICK) == 1 and carrying(CHAT) == 1, tostring(notBack))
reset(CONTROLLER, nil)
put(1, CHAT); put(2, MODEM)
q, restore = T.equipPeripheral(CHAT)
S.sel = 2; turtle.equipRight(); S.sel = 1
back, notBack = restore()
check("...and over a side that was empty, the modem isn't taken off either",
    back == false and notBack:find("left as it is, not emptied", 1, true) and EQ.right == MODEM and carrying(MODEM) == 0, tostring(notBack))
reset(CONTROLLER, PICK)
put(1, CHAT)
q, restore = T.equipPeripheral(CHAT)
S.inv[1] = nil                                  -- (the pickaxe put away in a chest)
back, notBack = restore()
check("the pickaxe gone from the inventory: the chat box stays on, false and why (no empty slot takes it off)",
    back == false and notBack == "couldn't put the " .. PICK .. " back on the right: it isn't on board" and EQ.right == CHAT, tostring(notBack))
reset(CONTROLLER, PICK)
put(1, CHAT)
q, restore = T.equipPeripheral(CHAT)
S.inv[1] = { name = PICK, count = 1, damaged = true }
put(5, PICK)
back, notBack = restore()
check("a damaged pickaxe ahead of a good one: the good one goes back on, the damaged one stays in its slot",
    back == true and EQ.right == PICK and S.inv[1] and S.inv[1].damaged and S.inv[5] and S.inv[5].name == CHAT, tostring(notBack))
reset(CONTROLLER, PICK)
put(1, CHAT)
q, restore = T.equipPeripheral(CHAT)
S.inv[1] = { name = PICK, count = 1, damaged = true }
back, notBack = restore()
check("...only a damaged one: false and why, the chat box left on",
    back == false and notBack == "couldn't put the " .. PICK .. " back on the right: Not a valid upgrade" and EQ.right == CHAT, tostring(notBack))
reset(CONTROLLER, PICK)
put(1, CHAT); put(2, MODEM)
local printed, printWas = {}, print
print = function(s) printed[#printed + 1] = s end
ok, result = T.withPeripheral(CHAT, function() S.sel = 2; turtle.equipRight(); S.sel = 1; return "said" end)
print = printWas
check("T.withPeripheral: fn's modem stays on, fn's result comes back, and why the side wasn't put back is printed",
    ok == true and result == "said" and EQ.right == MODEM and #printed == 1
        and printed[1] == "T.withPeripheral: the right side holds the " .. MODEM .. " now, not the " .. CHAT .. " put on: left as it is, and the "
        .. PICK .. " not put back", printed[1])

--------------------------------------------------------------------------
-- ADR-0019 D3: a dig with the tool aboard but not on (T.cfg.equipToDig)
--------------------------------------------------------------------------
local function quietly(fn)
    local said, was = {}, print
    print = function(s2) said[#said + 1] = s2 end
    local res = table.pack(pcall(fn))
    print = was
    if not res[1] then error(res[2], 0) end
    return said, table.unpack(res, 2, res.n)
end
local said, dug, digWhy
reset(CONTROLLER, MODEM)
put(3, PICK)
said, dug, digWhy = quietly(function() return turtle.dig() end)
check("equipToDig off (programs): the dig fails as CC says, nothing equipped",
    dug == false and digWhy == "No tool to dig with" and EQ.right == MODEM and carrying(PICK) == 1 and #said == 0, tostring(digWhy))
T.cfg.equipToDig = true
said, dug, digWhy = quietly(function() return turtle.dig() end)
check("equipToDig on: the pickaxe goes on the side without the controller, the modem into its slot, the dig goes through",
    dug == true and DUG == 1 and EQ.left == CONTROLLER and EQ.right == PICK and S.inv[3] and S.inv[3].name == MODEM
        and S.sel == 1, tostring(digWhy))
check("...and says so", #said == 1 and said[1] == "A dig put the " .. PICK .. " on the right (T.cfg.equipToDig); the " .. MODEM
    .. " it took off is in slot 3.", said[1])
S.sel = 3; turtle.equipRight(); S.sel = 1        -- (the modem put back on by hand)
said, dug = quietly(function() return T.digDir(0) end)
check("...once: the next one equips again without a word", dug == true and EQ.right == PICK and #said == 0, said[1])
reset(MODEM, CONTROLLER)
S.inv[1] = { name = PICK, count = 1, damaged = true }
put(5, "minecraft:iron_pickaxe")
said, dug = quietly(function() return turtle.dig() end)
check("a damaged pickaxe ahead of a good one: the good one goes on (the left, the controller's on the right)",
    dug == true and EQ.left == "minecraft:iron_pickaxe" and EQ.right == CONTROLLER and S.inv[1].damaged and S.inv[5].name == MODEM)
reset(CONTROLLER, MODEM)
S.inv[1] = { name = PICK, count = 1, damaged = true }
said, dug, digWhy = quietly(function() return turtle.dig() end)
check("...only a damaged one: the dig fails as before, the modem stays on",
    dug == false and digWhy == "No tool to dig with" and EQ.right == MODEM and S.inv[1].damaged, tostring(digWhy))
reset(CONTROLLER, MODEM)
put(2, PICK)
T.cfg.tools = { "*_shovel" }
said, dug, digWhy = quietly(function() return turtle.dig() end)
check("T.cfg.tools names the job's tools: a pickaxe it doesn't name stays in the inventory",
    dug == false and digWhy == "No tool to dig with" and EQ.right == MODEM and carrying(PICK) == 1, tostring(digWhy))
T.cfg.tools, T.cfg.equipToDig = nil, nil

--------------------------------------------------------------------------
-- pull
--------------------------------------------------------------------------
local function show()
    local t = {}
    for q2 = 1, CHEST_SIZE do
        if chest[q2] then t[#t + 1] = chest[q2].name:gsub("minecraft:", "") .. " " .. chest[q2].count end
    end
    table.sort(t)
    return table.concat(t, ", ")
end
local function fill(list)
    for q2 = 1, CHEST_SIZE do chest[q2] = nil end
    for q2, it in ipairs(list) do chest[q2] = { name = it[1], count = it[2] } end
end
local COBBLE = "minecraft:cobblestone"
reset(CONTROLLER, PICK)
fill({ { "minecraft:wheat_seeds", 32 }, { "minecraft:wheat", 40 }, { "minecraft:dirt", 64 }, { COBBLE, 64 }, { "minecraft:water_bucket", 1 },
       { COBBLE, 64 }, { COBBLE, 30 } })
put(1, PICK)
local got
got, why = T.pull("bottom", COBBLE, 150)
check("T.pull takes a count out of a mixed chest, across stacks", got == 150 and why == nil and carrying(COBBLE) == 150, got .. ", " .. tostring(why))
check("...and nothing else comes out", carrying("minecraft:dirt") == 0 and carrying("minecraft:wheat") == 0 and carrying("minecraft:wheat_seeds") == 0
    and carrying("minecraft:water_bucket") == 0)
check("...the rest stays in the chest", show() == "cobblestone 8, dirt 64, water_bucket 1, wheat 40, wheat_seeds 32", show())
check("...the pickaxe is where it was, and slot 1 is selected as before", S.inv[1].name == PICK and S.sel == 1)

got, why = T.pull("bottom", "minecraft:water_bucket", 2)
check("asking for more than the chest has: what it has, and why", got == 1 and why and why:find("has no more minecraft:water_bucket", 1, true)
    and why:find("got 1 of 2", 1, true), got .. ", " .. tostring(why))
got, why = T.pull("bottom", "minecraft:diamond", 3)
check("an item that isn't in it: 0 and why", got == 0 and why and why:find("has no more", 1, true), tostring(why))

-- joins a part stack
reset(CONTROLLER, PICK)
fill({ { "minecraft:dirt", 64 }, { COBBLE, 64 } })
put(1, PICK); put(2, COBBLE, 40)
got = T.pull("front", COBBLE, 50)
check("it tops up a part stack first", got == 50 and S.inv[2].count == 64 and carrying(COBBLE) == 90 and S.inv[3].count == 26,
    got .. " / " .. S.inv[2].count)

-- a short stack in front (#340): CC:T's suck of 28 from a stack of 8 goes on to the next stack asking for 28 again
reset(CONTROLLER, PICK)
fill({ { COBBLE, 8 }, { COBBLE, 64 } })
put(1, PICK)
got = T.pull("front", COBBLE, 28)
check("a short stack in front: exactly what was asked, no more", got == 28 and carrying(COBBLE) == 28 and inChest(COBBLE) == 44,
    got .. " / " .. carrying(COBBLE) .. " aboard")

-- a full chest, the wanted stack at the back: the stack in front is held meanwhile
reset(CONTROLLER, PICK)
local full = {}
for q2 = 1, CHEST_SIZE do full[q2] = { q2 == 27 and COBBLE or "minecraft:dirt", 64 } end
fill(full)
put(1, PICK)
got = T.pull("top", COBBLE, 10)
check("a full chest: gets it, and the stack that was in front goes back in the chest",
    got == 10 and carrying("minecraft:dirt") == 0 and carrying(COBBLE) == 10, got .. " cobble, " .. carrying("minecraft:dirt") .. " dirt")
check("...none lost", inChest("minecraft:dirt") == 26 * 64 and inChest(COBBLE) == 54, inChest("minecraft:dirt") .. " dirt")

-- no room
reset(CONTROLLER, PICK)
fill({ { COBBLE, 64 } })
for s = 1, 16 do put(s, "minecraft:dirt", 64) end
got, why = T.pull("front", COBBLE, 5)
check("no room in the turtle: 0 and why", got == 0 and why and why:find("no room in the turtle", 1, true), tostring(why))
check("...the chest still has it", show() == "cobblestone 64")

-- bad side
got, why = T.pull("left", COBBLE, 1)
check("a side that isn't front, top or bottom: 0 and why", got == 0 and why and why:find("not left", 1, true), tostring(why))
