-- sim/turtlelib_journal.lua
--
-- tl.journal (ADR-0008 phase 4): the job journal, the undo journal and T.report, on sim/lib/buildworld's mock world with a chat
-- box that can be equipped (and that is busy for a few calls when asked to be).
--   * T.job: start, done (the next step, a number, a text), resume after a restart of the computer at the step it was at, notes,
--     progress lines, status, clear; what is refused (no job, a bad goal, a step that is not there);
--   * T.build and T.harvest write their progress into the job when one is on, and touch nothing when there is none (the module
--     is not even loaded);
--   * the undo journal: off by default (nothing written), on with T.cfg.undo; two placed blocks and a dug one put back by T.undo;
--     a dug stair put back facing as it was (through T.placeAt); a mark and T.undo(nil, { since }); an entry that cannot be undone
--     stays and is told (no item aboard, the cell holds something else), one whose cell is empty already is done; a planted
--     crop and redstone dust (blocks whose item has another name) written down and undone; nothing the undo
--     does is written down; the journal is cut at undo.max; the numbering goes on after a restart; an entry from before a
--     re-zero refused and marked stale (ADR-0012), the frame numbered anew by a re-zero, not by reset --here;
--   * T.report: the text with the position (the world cell), fuel and the job's progress; the chat box equipped for the moment and
--     the pickaxe put back; a chat box on a side used as it is; the cooldown retried and given up on; no player, no chat box, a
--     bad text; T.report.every(n) telling the player once in every n steps.
local PROJ = ...
package.path = PROJ .. "/turtle/?.lua;" .. PROJ .. "/lib/?.lua;" .. PROJ .. "/sim/lib/?.lua;" .. package.path
local M = require("mock")
local B = require("buildworld")
local realCheck = M.check
-- (a check's detail is only shown when it fails)
local function check(label, ok, detail) realCheck(label, ok, (not ok) and detail or nil) end

-- real time (os.epoch): stands still but for the timers T.report.ask waits
-- on (TPS: the server's ticks a second; a timer for t game seconds lasts
-- t * 20 / TPS real ones)
local EPOCH, TPS = 1000 * 1000, 20
os.epoch = function() return math.floor(EPOCH) end
local CLK = 0
os.clock = function() CLK = CLK + 0.001; return CLK end
local SETTINGS, DEFAULTS = {}, {}
settings = {
    define = function(name, opts) DEFAULTS[name] = opts.default end,
    get = function(name) if SETTINGS[name] ~= nil then return SETTINGS[name] end return DEFAULTS[name] end,
}
print = function() end

local PICK, CHAT = "minecraft:diamond_pickaxe", "advancedperipherals:chat_box"
local STONE, COBBLE, STAIRS, BSTONE = "minecraft:stone", "minecraft:cobblestone", "minecraft:oak_stairs", "minecraft:blackstone"
local W, T
local SENT, BUSY, SWAPS = {}, 0, 0
local MODS = { "turtlelib", "tl.world", "tl.path", "tl.place", "tl.blueprint", "tl.harvest", "tl.store", "tl.journal" }

-- The chat box: what it was told, busy (false) for the next BUSY calls.
local chatApi = {
    sendMessageToPlayer = function(message, player, opts)
        if BUSY > 0 then BUSY = BUSY - 1; return false end
        SENT[#SENT + 1] = { message = message, player = player, prefix = type(opts) == "table" and opts.prefix or opts }
        return true
    end,
    sendMessage = function(message) SENT[#SENT + 1] = { message = message, everyone = true }; return true end,
}

-- A new world: a floor of stone, the pickaxe on the left, 200 fuel, the library loaded afresh and told where it is in the world
-- (100,64,-20, north).  The chat box can be equipped, and is not attached.
local function fresh(noOrigin)
    W = B.new({ facing = "north" })
    W.install()
    EQ.left, EQ.right = PICK, nil
    FUEL = 200
    SENT, BUSY, SWAPS = {}, 0, 0
    SETTINGS = { ["turtle.player"] = "Steve" }
    local p = W.peripheral
    local rawWrap, rawMethods, rawType = p.wrap, p.getMethods, p.getType
    p.wrap = function(side) if EQ[side] == CHAT then return chatApi end return rawWrap(side) end
    p.getMethods = function(side) if EQ[side] == CHAT then return { "sendMessageToPlayer", "sendMessage" } end return rawMethods(side) end
    p.getType = function(side) if EQ[side] == CHAT then return "chatBox" end return rawType(side) end
    p.find = function(kind)
        for _, side in ipairs({ "left", "right" }) do
            if p.getType(side) == kind then return p.wrap(side) end
        end
    end
    local rawRight = turtle.equipRight
    turtle.equipRight = function(...) SWAPS = SWAPS + 1; return rawRight(...) end
    for x = -8, 8 do for z = -8, 8 do W.set(x, -1, z, STONE) end end
    for _, name in ipairs(MODS) do package.loaded[name] = nil end
    T = require("turtlelib")
    if not noOrigin then T.setOrigin(100, 64, -20, "north") end
    return W, T
end
-- A restart of the computer: the disk and the world as they are, the library loaded afresh, the turtle where it is.
local function restart()
    local p, d = { W.S.P.x, W.S.P.y, W.S.P.z }, W.S.P.d
    for _, name in ipairs(MODS) do package.loaded[name] = nil end
    local S = turtle._ccnixJournal
    if S then S.seq, S.count = nil, nil end       -- (what was counted in memory is gone)
    T = require("turtlelib")
    T.pos.x, T.pos.y, T.pos.z, T.dir = p[1], p[2], p[3], d
    T.savePos()
    return T
end
local function know(x1, y1, z1, x2, y2, z2)
    for x = x1, x2 do for y = y1, y2 do for z = z1, z2 do
        local b = W.get(x, y, z)
        T.map.set(x, y, z, b and b.name or "minecraft:air", b and b.state or nil)
    end end end
end
local function carrying(name) return W.carrying(name) end
-- How many of an item the chest below the start holds.
local function inChest(name)
    local n = 0
    for _, it in pairs(W.get(0, -1, 0).inv) do if it.name == name then n = n + it.count end end
    return n
end
local function has(x, y, z, name) local b = W.get(x, y, z); return b ~= nil and (name == nil or b.name == name) end
local function contains(s, part) return type(s) == "string" and s:find(part, 1, true) ~= nil end
local function readFile(name)
    local f = fs.open(T.dataPath(name), "r")
    if not f then return nil end
    local s = f.readAll()
    f.close()
    return s
end
local function lines(name)
    local n = 0
    for _ in (readFile(name) or ""):gmatch("[^\n]+") do n = n + 1 end
    return n
end

--------------------------------------------------------------------------
-- The job journal
--------------------------------------------------------------------------
do
    fresh()
    check("no job at first: resume, status and done say so", select(1, T.job.resume()) == nil and T.job.status() == nil
        and select(2, T.job.done()) ~= nil and contains(select(2, T.job.done()), "no job is on"))
    check("a job needs a goal", select(1, T.job.start("")) == nil and select(1, T.job.start(nil)) == nil)
    check("...and steps that are texts", select(1, T.job.start("x", { "a", 5 })) == nil)
    check("T.job.start writes the job", T.job.start("build the keep", { "clear the ground", "lay the floor", "raise the walls" }) == true)
    local job = T.job.resume()
    check("resume: the goal, the first step to do, none done", job and job.goal == "build the keep" and job.next == 1
        and job.step == "clear the ground" and job.done == 0 and job.total == 3 and not job.finished)
    local ok, left = T.job.done()
    check("done with no step marks the next one: two are left", ok == true and left == 2)
    job = T.job.resume()
    check("...and the step to do moves on", job.next == 2 and job.step == "lay the floor" and job.done == 1)
    check("status is one line", T.job.status() == "step 2 of 3: lay the floor", tostring(T.job.status()))

    restart()
    job = T.job.resume()
    check("after a restart of the computer the job is resumed at its step", job and job.next == 2 and job.step == "lay the floor"
        and job.steps[1].done == true and job.goal == "build the keep", job and tostring(job.step))

    ok, left = T.job.done("raise the walls")
    check("a step by its text", ok == true and left == 1)
    ok, left = T.job.done("raise the walls")
    check("...done twice is still done", ok == true and left == 1)
    ok = T.job.done(7)
    local _, why = T.job.done(7)
    check("a step that is not there: nil and why", ok == nil and contains(why, "no step 7"), tostring(why))
    _, why = T.job.done("paint it")
    check("...by text too", contains(why, "no step paint it"), tostring(why))
    check("done by number", T.job.done(2) == true)
    job = T.job.resume()
    check("every step done: finished", job.finished == true and job.next == nil and job.step == nil and T.job.status() == "all 3 steps done")
    _, why = T.job.done()
    check("...and done with no step says so", contains(why, "every step is done"), tostring(why))

    check("a note", T.job.note("the quarry is to the east") == true)
    T.job.note("lava at the bottom")
    job = T.job.resume()
    check("notes are kept in order", #job.notes == 2 and job.notes[1] == "the quarry is to the east" and job.notes[2] == "lava at the bottom")
    for i = 1, 50 do T.job.note("n" .. i) end
    job = T.job.resume()
    check("only the newest 40 notes are kept", #job.notes == 40 and job.notes[40] == "n50" and job.notes[1] == "n11", #job.notes)
    check("a text with a newline is one line", T.job.note("two\nlines") == true and #T.job.resume().notes == 40)

    check("progress lines: set, shown in the status, replaced", T.job.progress("build", "keep: 3 of 9 cells tried") == true
        and T.job.progress("build", "keep: 6 of 9 cells tried") == true
        and T.job.resume().work.build == "keep: 6 of 9 cells tried"
        and T.job.status() == "all 3 steps done; build: keep: 6 of 9 cells tried", tostring(T.job.status()))
    T.job.progress("build", nil)
    check("...and taken away", T.job.resume().work.build == nil)
    check("a job with no steps: the status is the goal", T.job.start("look around") == true and T.job.status() == "look around")
    check("T.job.clear forgets it", T.job.clear() == true and T.job.resume() == nil and T.job.status() == nil)
    check("...and the file is gone", readFile(".job") == nil)
    check("notes and progress need a job", select(1, T.job.note("x")) == nil and select(1, T.job.progress("build", "x")) == nil)
end

--------------------------------------------------------------------------
-- A build and a harvest write their progress into the job
--------------------------------------------------------------------------
do
    fresh()
    W.give(2, STONE, 8)
    local plan = T.blueprint.fill(2, 0, 2, 3, 0, 3, "stone")
    local ok = T.build(plan, { name = "pad" })
    check("with no job a build writes nothing and the journal is not loaded", ok == true and readFile(".job") == nil
        and package.loaded["tl.journal"] == nil)
    check("...the blocks went up", has(2, 0, 2, STONE) and has(3, 0, 3, STONE))

    fresh()
    W.give(2, STONE, 8)
    T.job.start("lay a pad", { "pad" })
    plan = T.blueprint.fill(2, 0, 2, 3, 0, 3, "stone")
    ok = T.build(plan, { name = "pad" })
    local job = T.job.resume()
    check("with a job on a build writes its progress there, finished", ok == true and job and job.work.build == "pad: 4 of 4 cells tried (finished)",
        job and tostring(job.work.build))
    check("...in the status", contains(T.job.status(), "build: pad: 4 of 4 cells tried (finished)"), tostring(T.job.status()))

    fresh()
    W.give(2, STONE, 8)
    T.job.start("lay a pad", { "pad" })
    ok = T.build(T.blueprint.fill(2, 0, 2, 3, 0, 3, "stone"), { name = "pad", limit = 2 })
    job = T.job.resume()
    check("a build stopped part way says how far", ok == false and job.work.build == "pad: 2 of 4 cells tried", tostring(job.work.build))

    fresh()
    W.fill(2, 0, 2, 3, 0, 3, BSTONE)
    know(-1, -1, -1, 5, 2, 5)
    local noJob = T.harvest("blackstone", { 2, 0, 2, 3, 0, 3 }, nil, { scan = false })
    check("with no job a harvest writes nothing", noJob == true and readFile(".job") == nil and package.loaded["tl.journal"] == nil)
    fresh()
    W.fill(2, 0, 2, 3, 0, 3, BSTONE)
    know(-1, -1, -1, 5, 2, 5)
    T.job.start("get blackstone", { "dig" })
    ok = T.harvest("blackstone", { 2, 0, 2, 3, 0, 3 }, nil, { scan = false })
    job = T.job.resume()
    check("with a job on a harvest writes how many it dug", ok == true and job.work.harvest == "blackstone: 4 dug", job and tostring(job.work.harvest))
    fresh()
    W.fill(2, 0, 2, 3, 0, 3, BSTONE)
    know(-1, -1, -1, 5, 2, 5)
    T.job.start("get blackstone", { "dig" })
    T.harvest("blackstone", { 2, 0, 2, 3, 0, 3 }, 3, { scan = false })
    check("...of the target when there is one", T.job.resume().work.harvest == "blackstone: 3 of 3 dug", tostring(T.job.resume().work.harvest))
end

--------------------------------------------------------------------------
-- The undo journal
--------------------------------------------------------------------------
do
    fresh()
    W.set(0, 0, 1, STONE)
    turtle.dig()
    check("undo is off by default: a dig writes nothing", readFile(".undo") == nil and package.loaded["tl.journal"] == nil)
    local ok, why = T.undo()
    check("...so there is nothing to undo, and it says how to turn it on", ok == nil and contains(why, "T.cfg.undo = true"), tostring(why))
    check("...and the stone is still gone", not has(0, 0, 1))

    fresh()
    T.cfg.undo = true
    check("setting T.cfg.undo loads the module", package.loaded["tl.journal"] ~= nil)
    W.set(0, 0, 1, STONE)
    local mark0 = T.undoMark()
    turtle.dig()                                    -- the stone is dug
    W.give(2, COBBLE, 4)
    turtle.select(2)
    turtle.place()                                  -- cobble where the stone was
    turtle.turnRight()
    turtle.place()                                  -- cobble to the right of the turtle
    turtle.turnLeft()
    check("the journal has a dig and two placements", lines(".undo") == 3, tostring(readFile(".undo")))
    check("...the world is as the turtle left it", has(0, 0, 1, COBBLE) and has(1, 0, 0, COBBLE))
    local before = T.undoMark()
    local ok2, info = T.undo(3)
    check("T.undo(3) puts back the dug stone and takes out the two placed blocks", ok2 == true and info.undone == 3 and #info.failed == 0
        and has(0, 0, 1, STONE) and not has(1, 0, 0), tostring(info and info.failed[1] and info.failed[1].why))
    check("...the journal is empty and the undo wrote nothing", lines(".undo") == 0 and T.undoMark() == before)
    check("...the turtle's position is right", W.S.P.x == T.pos.x and W.S.P.y == T.pos.y and W.S.P.z == T.pos.z and W.S.P.d == T.dir)
    check("nothing left to undo", select(1, T.undo()) == nil)

    -- a mark: everything after it
    fresh()
    T.cfg.undo = true
    W.set(0, 0, 1, STONE)
    W.set(0, 1, 0, STONE)
    turtle.dig()                                    -- before the mark
    local mark = T.undoMark()
    turtle.digUp()
    W.give(3, COBBLE, 1)
    turtle.select(3)
    turtle.place()
    ok2, info = T.undo(nil, { since = mark })
    check("T.undo(nil, { since }) undoes what came after the mark, not before", ok2 == true and info.undone == 2 and has(0, 1, 0, STONE)
        and not has(0, 0, 1) and lines(".undo") == 1, tostring(info and info.undone))
    check("...bad arguments are refused", select(1, T.undo(0)) == nil and select(1, T.undo(1.5)) == nil and select(1, T.undo(nil, { since = "x" })) == nil)

    -- a dug stair is put back facing as it was
    fresh()
    T.cfg.undo = true
    W.set(2, 0, 2, STAIRS, { facing = "east", half = "bottom" })
    know(-1, -1, -1, 4, 2, 4)
    T.moveTo(2, 0, 1, {})
    T.digDir(0)
    check("a dug stair is aboard and gone", carrying(STAIRS) == 1 and not has(2, 0, 2))
    ok2, info = T.undo()
    local st = W.state(2, 0, 2)
    check("T.undo puts the stair back, facing east, bottom half", ok2 == true and has(2, 0, 2, STAIRS) and st and st.facing == "east" and st.half == "bottom",
        tostring(info and info.failed[1] and info.failed[1].why) .. " " .. tostring(st and st.facing))
    check("...and the stair is not aboard any more", carrying(STAIRS) == 0)

    -- with no world origin a facing can't be asked for: the undo says so
    fresh(true)
    T.cfg.undo = true
    W.set(2, 0, 2, STAIRS, { facing = "east", half = "bottom" })
    know(-1, -1, -1, 4, 2, 4)
    T.moveTo(2, 0, 1, {})
    T.digDir(0)
    local why2
    ok2, why2 = T.undo()
    check("a faced block with no origin: the undo says what placeAt said", ok2 == false and contains(why2, "T.setOrigin"), tostring(why2))

    -- seeds make a crop, a block of their own: it's written down, and the undo takes it out and the seeds back
    fresh()
    T.cfg.undo = true
    T.undoClear()
    W.set(0, -1, 1, "minecraft:farmland")
    W.give(1, "minecraft:wheat_seeds", 4)
    turtle.select(1)
    -- (the mock has no crops: seeds placed down make wheat, as in the game)
    T.raw.placeDown = function()
        if W.get(0, 0, 1) then return false, "Cannot place block here" end
        W.set(0, 0, 1, "minecraft:wheat", { age = 0 })
        return true
    end
    T.up()
    T.forward()
    local planted = turtle.placeDown()
    check("seeds planted with the journal on are written down (a wheat crop is theirs)", planted and lines(".undo") == 1,
        tostring(readFile(".undo")))
    -- (the stand-in placeDown above leaves the seed aboard; the dug crop gives one more)
    local seedsBefore = T.countItem("minecraft:wheat_seeds")
    local okSeeds, infoSeeds = T.undo()
    check("...and T.undo takes the crop out, the seeds back aboard", okSeeds == true and not has(0, 0, 1)
        and T.countItem("minecraft:wheat_seeds") == seedsBefore + 1, tostring(infoSeeds and infoSeeds.undone) .. " " .. T.countItem("minecraft:wheat_seeds"))

    -- redstone makes redstone_wire: placed with the journal on, it's written down and undone
    fresh()
    T.cfg.undo = true
    T.undoClear()
    W.set(0, -1, 1, STONE)
    W.give(1, "minecraft:redstone", 2)
    turtle.select(1)
    local dusted = turtle.place()
    check("redstone dust placed with the journal on is written down", dusted and has(0, 0, 1, "minecraft:redstone_wire")
        and lines(".undo") == 1, tostring(readFile(".undo")))
    local okDust = T.undo()
    check("...and T.undo takes the dust out, the redstone back aboard", okDust == true and not has(0, 0, 1)
        and T.countItem("minecraft:redstone") == 2, T.countItem("minecraft:redstone"))

    -- a top-half stair too
    fresh()
    T.cfg.undo = true
    W.set(2, 2, 2, STAIRS, { facing = "south", half = "top" })
    know(-1, -1, -1, 4, 4, 4)
    T.moveTo(2, 2, 1, {})
    T.digDir(0)
    ok2, info = T.undo()
    st = W.state(2, 2, 2)
    check("a top-half stair comes back top-half, facing south", ok2 == true and st and st.facing == "south" and st.half == "top",
        tostring(st and st.facing) .. " " .. tostring(st and st.half))
    fresh()
    T.cfg.undo = true
    T.cfg.undo = false
    W.set(0, 0, 1, STONE)
    turtle.dig()
    check("with T.cfg.undo turned off again a dig writes nothing", lines(".undo") == 0 and not has(0, 0, 1), lines(".undo"))

    -- an entry that cannot be undone stays; one already done goes
    fresh()
    T.cfg.undo = true
    W.set(0, 0, 1, STONE)
    turtle.dig()
    W.S.inv[1] = nil                                -- the stone is gone from the turtle
    ok2, why, info = T.undo()
    check("no item aboard: false, why, and the entry stays", ok2 == false and contains(why, "none of minecraft:stone aboard") and info.undone == 0
        and #info.failed == 1 and info.failed[1].kind == "dig" and lines(".undo") == 1, tostring(why))
    W.give(1, STONE, 1)
    ok2, info = T.undo()
    check("...with the item back it goes", ok2 == true and has(0, 0, 1, STONE) and lines(".undo") == 0, tostring(info and info.failed and info.failed[1] and info.failed[1].why))

    fresh()
    T.cfg.undo = true
    W.give(1, COBBLE, 2)
    turtle.place()                                  -- cobble in front
    W.set(0, 0, 1, STONE)                           -- then someone swapped it for stone
    ok2, why, info = T.undo()
    check("a placed block whose cell holds something else is left, and told", ok2 == false and contains(why, "holds minecraft:stone, not minecraft:cobblestone")
        and has(0, 0, 1, STONE) and lines(".undo") == 1, tostring(why))
    W.set(0, 0, 1, nil)
    ok2, info = T.undo()
    check("...an empty cell is done already", ok2 == true and lines(".undo") == 0 and not has(0, 0, 1))

    -- a re-zero since (ADR-0012): the journal's cells are in the frame they were written in
    fresh()
    T.cfg.undo = true
    local f0 = T.frameId()
    T.setHomeHere()
    check("reset --here (T.setHomeHere) keeps the frame: the turtle is at home as it was", T.frameId() == f0, tostring(T.frameId()))
    W.set(0, 0, 1, STONE)
    turtle.dig()
    T.forward()
    T.startAtHome(true)                             -- the cell it moved to is 0,0,0 from now on
    check("a re-zero that moves where 0,0,0 is numbers a new frame", T.frameId() == f0 + 1, f0 .. " -> " .. T.frameId())
    ok2, why, info = T.undo()
    check("an entry from before the re-zero is refused, saying why, and nothing is put back", ok2 == false and contains(why, "re-zeroed")
        and info.undone == 0 and lines(".undo") == 1 and not has(0, 0, 2) and not has(0, 0, 1) and carrying(STONE) == 1, tostring(why))
    check("...and marked stale in the journal", contains(readFile(".undo"), " stale"), tostring(readFile(".undo")))
    W.set(0, 0, 2, COBBLE)
    turtle.dig()
    ok2, why = T.undo(1)
    check("...a new entry, from this frame, is undone as before", ok2 == true and has(0, 0, 2, COBBLE) and lines(".undo") == 1, tostring(why))

    -- a placed torch (the item's name is not the block's)
    fresh()
    T.cfg.undo = true
    W.set(0, 0, 2, STONE)
    W.give(1, "minecraft:torch", 1)
    turtle.place()
    check("a torch is placed", has(0, 0, 1, "minecraft:wall_torch") or has(0, 0, 1, "minecraft:torch"), tostring(W.get(0, 0, 1) and W.get(0, 0, 1).name))
    ok2, info = T.undo()
    check("...and taken out, though the block is a wall torch", ok2 == true and not has(0, 0, 1), tostring(info and info.failed and info.failed[1] and info.failed[1].why))

    -- protected: the dig is refused, the entry stays
    fresh()
    T.cfg.undo = true
    W.give(1, COBBLE, 1)
    turtle.place()
    T.protect("keep", 0, 0, 1, 0, 0, 1)
    ok2, why, info = T.undo()
    check("a placed block in a protected area is not dug out", ok2 == false and contains(info.failed[1].why, "protected") and has(0, 0, 1, COBBLE), tostring(why))
    ok2 = T.undo(1, { inside = "keep" })
    check("...unless the job owns the area", ok2 == true and not has(0, 0, 1))

    -- the numbering and the cut
    fresh()
    T.cfg.undo = true
    W.set(0, 0, 1, STONE)
    turtle.dig()
    local m1 = T.undoMark()
    restart()
    check("the numbering goes on after a restart", T.undoMark() == m1 and m1 == 1, tostring(T.undoMark()))
    T.cfg.undo = true
    W.set(0, 0, 1, STONE)
    turtle.dig()
    check("...and the journal is read from its file", T.undoMark() == 2 and lines(".undo") == 2)
    ok2, info = T.undo(2)
    check("...both entries can be undone after the restart", ok2 == true and info.undone == 2)

    fresh()
    T.cfg.undo = true
    SETTINGS["undo.max"] = 8
    for i = 1, 20 do
        W.set(0, 0, 1, STONE)
        turtle.dig()
    end
    local n = lines(".undo")
    check("the journal is cut at undo.max", n <= 8 and n >= 6, n)
    check("...keeping the newest", T.undoMark() == 20 and contains(readFile(".undo"), "20 dig") and not contains(readFile(".undo"), "\n1 dig"))
    check("T.undoClear empties it", T.undoClear() == true and lines(".undo") == 0)
end

--------------------------------------------------------------------------
-- Reports to the player
--------------------------------------------------------------------------
do
    fresh()
    local ok, why = T.report("hello")
    check("no chat box anywhere: nil and why, nothing sent", ok == nil and contains(why, "chat_box"), tostring(why))
    check("...and the pickaxe is where it was", EQ.left == PICK and EQ.right == nil)

    W.give(1, CHAT, 1)
    ok, why = T.report("the walls are up")
    check("a chat box aboard is equipped, used and taken off again", ok == true and #SENT == 1 and EQ.right == nil and EQ.left == PICK and carrying(CHAT) == 1, tostring(why))
    check("...it told the player, with the position (the world cell), fuel and no job", SENT[1].player == "Steve"
        and SENT[1].message == "the walls are up [at 100,64,-20; fuel 200]", tostring(SENT[1] and SENT[1].message))
    T.pos.x, T.pos.y, T.pos.z = 3, 2, 1
    T.report("moved")
    check("the position is converted to the world's", SENT[2].message == "moved [at 103,66,-21; fuel 200]", tostring(SENT[2] and SENT[2].message))
    T.pos.x, T.pos.y, T.pos.z = 0, 0, 0
    check("opts.plain sends the text alone", T.report.now("just this", { plain = true }) == true and SENT[3].message == "just this")
    check("opts.player tells someone else", T.report.now("hi", { player = "Alex", plain = true }) == true and SENT[4].player == "Alex")
    FUEL = nil
    T.report("unlimited")
    check("unlimited fuel is said", contains(SENT[5].message, "fuel unlimited"), tostring(SENT[5].message))
    FUEL = 200

    T.job.start("raise the keep", { "floor", "walls" })
    T.job.done()
    T.report("status")
    check("the job's progress is added", SENT[6].message == "status [at 100,64,-20; fuel 200; job: step 2 of 2: walls]", tostring(SENT[6].message))

    local sent = #SENT
    SETTINGS["turtle.player"] = ""
    ok, why = T.report("nobody")
    check("no player set: said to everyone (ADR-0013 D3)", ok == true and #SENT == sent + 1 and SENT[#SENT].everyone == true
        and SENT[#SENT].message:find("^nobody %[") ~= nil, tostring(why))
    SETTINGS["turtle.player"] = "Steve"
    ok, why = T.report("")
    check("an empty text is refused", ok == nil and contains(why, "nothing to say"))
    ok, why = T.report(nil)
    check("...and no text", ok == nil)

    -- the cooldown
    BUSY = 2
    local swaps = SWAPS
    ok, why = T.report("slow", { plain = true, wait = 0.1 })
    check("a busy chat box is retried until it takes it", ok == true and SENT[#SENT].message == "slow" and BUSY == 0, tostring(why))
    check("...with one equip and one restore", SWAPS - swaps == 2, SWAPS - swaps)
    sent = #SENT
    BUSY = 100
    ok, why = T.report("never", { plain = true, tries = 3, wait = 0.1 })
    check("a chat box that stays busy: nil and why, the pickaxe and chat box put back", ok == nil and contains(why, "stayed busy") and #SENT == sent
        and EQ.left == PICK and EQ.right == nil and carrying(CHAT) == 1, tostring(why))
    BUSY = 0

    -- a chat box on the side, not aboard
    fresh()
    EQ.right = CHAT
    local swaps2 = SWAPS
    ok, why = T.report("attached", { plain = true })
    check("a chat box on a side is used as it is, nothing swapped", ok == true and SENT[1] and SENT[1].message == "attached" and SWAPS == swaps2 and EQ.right == CHAT, tostring(why))

    -- a chat box in the chest below (opts.from): taken out for the telling and put back
    fresh()
    W.set(0, -1, 0, "minecraft:chest")
    W.get(0, -1, 0).inv[3] = { name = CHAT, count = 1 }
    W.get(0, -1, 0).inv[4] = { name = "minecraft:wheat_seeds", count = 5 }
    ok, why = T.report("no box aboard", { plain = true })
    check("without opts.from a chat box in a chest is not looked for", ok == nil and contains(why, "chat_box") and #SENT == 0, tostring(why))
    ok, why = T.report("from the chest", { plain = true, from = "bottom" })
    check("opts.from: the chat box comes out of the chest below, is used, and goes back", ok == true and #SENT == 1
        and SENT[1].message == "from the chest" and carrying(CHAT) == 0 and inChest(CHAT) == 1
        and inChest("minecraft:wheat_seeds") == 5 and EQ.left == PICK and EQ.right == nil, tostring(why))
    BUSY = 100
    ok, why = T.report("busy", { plain = true, from = "bottom", tries = 2, wait = 0.1 })
    check("...and goes back when the telling fails", ok == nil and contains(why, "stayed busy") and carrying(CHAT) == 0
        and inChest(CHAT) == 1, tostring(why))
    BUSY = 0
    for slot, it in pairs(W.get(0, -1, 0).inv) do if it.name == CHAT then W.get(0, -1, 0).inv[slot] = nil end end
    ok, why = T.report("empty chest", { plain = true, from = "bottom" })
    check("a chest with no chat box: nil and why, nothing sent", ok == nil and contains(why, "chat_box") and #SENT == 1, tostring(why))
    W.give(1, CHAT, 1)
    ok = T.report("aboard", { plain = true, from = "bottom" })
    check("a chat box aboard is used and the chest is left alone", ok == true and carrying(CHAT) == 1 and inChest(CHAT) == 0)

    -- T.report.try never raises
    fresh()
    ok, why = T.report.try("nothing aboard")
    check("T.report.try: a refusal comes back as nil and why", ok == nil and contains(why, "chat_box"), tostring(why))
    local rawSelect = turtle.getFuelLevel
    turtle.getFuelLevel = function() error("boom") end
    W.give(1, CHAT, 1)
    ok, why = T.report.try("broken", {})
    turtle.getFuelLevel = rawSelect
    check("...and so does an error inside, with the chat box put back", ok == nil and contains(why, "boom") and EQ.right == nil and carrying(CHAT) == 1, tostring(why))
    turtle.getFuelLevel = function() error("Terminated", 0) end
    ok, why = pcall(T.report.try, "stopped", {})
    turtle.getFuelLevel = rawSelect
    check("...but Ctrl+T goes on", ok == false and why == "Terminated", tostring(why))
    ok = T.report.try("fine", { plain = true })
    check("...and a good telling is true", ok == true and SENT[#SENT].message == "fine")

    -- every n steps
    fresh()
    W.give(1, CHAT, 1)
    ok, why = T.report.every(2)
    check("T.report.every needs a job", ok == nil and contains(why, "no job is on"), tostring(why))
    T.job.start("raise the keep", { "floor", "walls", "roof", "door" })
    check("every(2) is kept in the job", T.report.every(2) == true and T.job.resume().every == 2)
    T.job.done()
    check("the first step is not reported", #SENT == 0)
    T.job.done()
    check("the second is, with the job's progress", #SENT == 1 and SENT[1].message == "raise the keep - done: walls [at 100,64,-20; fuel 200; job: step 3 of 4: roof]",
        tostring(SENT[1] and SENT[1].message))
    T.job.done()
    T.job.done()
    check("...and every second one after", #SENT == 2)
    restart()
    check("it lasts a restart", T.job.resume().every == 2)
    check("a bad n is refused", select(1, T.report.every(-1)) == nil and select(1, T.report.every(1.5)) == nil)
    check("every(0) turns it off", T.report.every(0) == true and T.job.resume().every == nil)
    T.job.start("again", { "a", "b", "c" })
    T.report.every(1)
    T.job.progress("build", "a: 8 of 40 cells tried")
    check("a progress line counts as a step", #SENT == 3 and contains(SENT[3].message, "again - build: a: 8 of 40 cells tried"), tostring(SENT[3] and SENT[3].message))
    -- a report that cannot go is noted in the job, and the work goes on
    fresh()
    T.job.start("quiet", { "a", "b" })
    T.report.every(1)
    ok = T.job.done()
    local job = T.job.resume()
    check("a report that cannot go does not stop the job: it is noted", ok == true and #job.notes == 1 and contains(job.notes[1], "a report did not go"), tostring(job.notes[1]))
end

-- A finished job no longer rides on every report (mine's, farm's and mow's share the journal's file)
do
    fresh()
    W.give(1, CHAT, 1)
    T.job.start("raise the keep", { "floor", "walls" })
    T.job.done()
    T.report("half way")
    check("an unfinished job rides on the report", SENT[#SENT].message == "half way [at 100,64,-20; fuel 200; job: step 2 of 2: walls]",
        tostring(SENT[#SENT].message))
    local ok, left = T.job.done()
    check("T.job.done on the last step: true, none left, and the job is finished", ok == true and left == 0 and T.job.resume().finished == true)
    T.report("all done")
    check("...and a finished job is left out of the report", SENT[#SENT].message == "all done [at 100,64,-20; fuel 200]", tostring(SENT[#SENT].message))
    check("...while its status still says how it ended", T.job.status() == "all 2 steps done", tostring(T.job.status()))
    restart()
    T.report("after a restart")
    check("...a restart of the computer changes nothing", SENT[#SENT].message == "after a restart [at 100,64,-20; fuel 200]", tostring(SENT[#SENT].message))
    T.job.start("look around")
    T.report("looking")
    check("a job with no steps rides on the report", SENT[#SENT].message == "looking [at 100,64,-20; fuel 200; job: look around]", tostring(SENT[#SENT].message))
    ok, left = T.job.done()
    check("...until T.job.done finishes it: true, none left", ok == true and left == 0 and T.job.resume().finished == true)
    T.report("looked")
    check("...then it is left out", SENT[#SENT].message == "looked [at 100,64,-20; fuel 200]", tostring(SENT[#SENT].message))
    local _, why = T.job.done()
    check("...and done again says it is finished", contains(why, "finished"), tostring(why))
    T.job.start("next", { "a" })
    T.report("new")
    check("a new job rides again", SENT[#SENT].message == "new [at 100,64,-20; fuel 200; job: step 1 of 1: a]", tostring(SENT[#SENT].message))
end

-- T.report.ask (ADR-0011 D4): the question told through the chat box, the answer read from its chat events (AP's two
-- layouts), only from the player and only after the prefix; a timer a second counts the wait, flushes the cooldown and
-- reminds; the other messages go to T.hooks.heard; T.report.lastTold says when the player was last told anything
do
    local EVENTS, lastTimer = {}, 1
    os.startTimer = function(t) lastTimer = t; return 1 end
    os.pullEvent = function()
        local e = table.remove(EVENTS, 1)
        if not e then error("os.pullEvent with no event scripted") end
        if e[1] == "timer" then
            CLK = CLK + lastTimer
            EPOCH = EPOCH + lastTimer * 1000 * 20 / TPS
        end
        return table.unpack(e)
    end
    local function timers(n) for _ = 1, n do EVENTS[#EVENTS + 1] = { "timer", 1 } end end

    fresh()
    check("T.report.lastTold: nil before anything is told", T.report.lastTold() == nil)
    local text, who, at = T.report.ask("which stair?")
    check("no chat box anywhere: nil and why, nothing sent", text == nil and contains(who, "chat_box") and #SENT == 0, tostring(who))
    W.give(1, CHAT, 1)
    text, who = T.report.ask("")
    check("an empty question is refused", text == nil and contains(who, "nothing to ask"), tostring(who))

    EVENTS = { { "timer", 1 }, { "chat", "Alex", "claude no", "uuid-a", false }, { "chat", "Steve", "hello there", "uuid-s", false },
        { "chat", "Steve", "claudette yes", "uuid-s", false }, { "chat", "Steve", "$claude hidden", "uuid-s", true },
        { "chat", "0f00-11aa", "Steve", "Claude: the oak one", false } }
    local swaps = SWAPS
    local passed = {}
    T.hooks.heard = function(e) passed[#passed + 1] = e.player .. ": " .. e.text end
    text, who, at = T.report.ask("which stair?")
    T.hooks.heard = nil
    check("the answer: the text after the prefix (any case, its colon off), the player and when (a second in)",
        text == "the oak one" and who == "Steve" and at == 1001, tostring(text) .. " / " .. tostring(who) .. " / " .. tostring(at))
    check("...not another player's, nor a message without the prefix as a word of its own, nor a hidden one", #EVENTS == 0)
    check("...those (the hidden one aside) handed to T.hooks.heard, the answer not (ADR-0013 D2)",
        table.concat(passed, " | ") == "Alex: claude no | Steve: hello there | Steve: claudette yes", table.concat(passed, " | "))
    check("the question went to the player with how to answer", #SENT == 1 and SENT[1].player == "Steve"
        and SENT[1].message == 'which stair? (answer in chat: "claude <your answer>")', tostring(SENT[1] and SENT[1].message))
    check("the chat box aboard was equipped for the wait and put back", SWAPS - swaps == 2 and EQ.left == PICK and EQ.right == nil
        and carrying(CHAT) == 1, SWAPS - swaps)
    check("T.report.lastTold: when the question went", T.report.lastTold() == 1000)

    SENT = {}
    timers(5)
    text, who = T.report.ask("still there?", { timeout = 5, remind = 2 })
    check("no answer in opts.timeout seconds: nil and why", text == nil and who == "no answer in 5 s" and #EVENTS == 0, tostring(who))
    check("...reminded every opts.remind seconds", #SENT == 3 and SENT[2].message == "still waiting for an answer: still there?"
        and SENT[3].message == SENT[2].message, #SENT)
    check("...and the chat box put back", EQ.right == nil and carrying(CHAT) == 1)

    -- ADR-0015 D9: a server at 60 ticks a second (/tick rate 60): a timer
    -- of 1 game second lasts a third of a real one, and the wait still
    -- lasts opts.timeout real seconds, reminders too
    SENT, TPS = {}, 60
    timers(2000)
    local from, clockFrom = EPOCH, CLK
    text, who = T.report.ask("fast server?", { timeout = 600, remind = 120 })
    local took, game = (EPOCH - from) / 1000, CLK - clockFrom
    check("a server at 60 ticks a second: a 600 s wait lasts 600 real seconds (1800 game ones), not 200",
        text == nil and who == "no answer in 600 s" and took >= 600 and took < 601 and game > 1790 and #EVENTS > 0,
        string.format("%s; %.1f real s, %.1f game s", tostring(who), took, game))
    check("...reminded every 120 real seconds", #SENT == 5, #SENT)
    EVENTS, TPS = {}, 20

    SENT, BUSY = {}, 1
    EVENTS = { { "timer", 1 }, { "chat", "Steve", "claude go", "uuid-s", false } }
    text = T.report.ask("busy box?")
    check("a question the cooldown held back goes at the next second (the chat box flushed)", text == "go" and #SENT == 1
        and SENT[1].message == 'busy box? (answer in chat: "claude <your answer>")', #SENT)

    SENT = {}
    EVENTS = { { "chat", "Steve", "turtle: up", "uuid-s", false } }
    text = T.report.ask("prefix?", { prefix = "turtle", player = "Steve" })
    check("opts.prefix names another prefix", text == "up" and SENT[1].message == 'prefix? (answer in chat: "turtle <your answer>")')

    SENT = {}
    SETTINGS["turtle.player"] = ""
    EVENTS = { { "chat", "Alex", "claude yes", "uuid-a", false } }
    text, who = T.report.ask("anyone?")
    check("no player set: asked of everyone, and anyone's answer taken", text == "yes" and who == "Alex" and SENT[1].everyone == true,
        tostring(who))
    SETTINGS["turtle.player"] = "Steve"

    fresh()
    EQ.right = CHAT
    local swaps2 = SWAPS
    EVENTS = { { "chat", "Steve", "claude fine", "uuid-s", false } }
    text = T.report.ask("attached?")
    check("a chat box on a side is used as it is, nothing swapped", text == "fine" and SWAPS == swaps2 and EQ.right == CHAT)

    fresh()
    W.give(1, CHAT, 1)
    T.report("the walls are up")
    check("T.report stamps T.report.lastTold too", T.report.lastTold() == math.floor(EPOCH / 1000))
    os.pullEvent, os.startTimer = nil, nil
end
