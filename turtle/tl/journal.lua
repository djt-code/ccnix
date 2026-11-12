-- journal.lua -- the job journal, the undo journal and reports to the player
--
-- Loaded by turtlelib the first time T.job, T.report, T.undo, T.undoMark or T.undoClear is used, or when T.cfg.undo is set.
--
-- The job journal (T.job) keeps a job in one data file, .job: the goal, the steps of the plan and which are done, notes, and
-- the progress a build or a harvest reports as it goes.  A reset, a crash or a cleared conversation then carries on at the
-- step:
--     T.job.start("build the keep", { "clear the ground", "lay the floor", "raise the walls" })
--     T.job.done()                  -- the next step is done
--     local job = T.job.resume()    -- job.step is the text of the step to do now, job.done of job.total are done
-- T.build and T.harvest write their progress there (T.job.progress) when a job is on, and write nothing when there is none.
--
-- The undo journal (T.cfg.undo = true) writes down each block the turtle digs or places, in the data file .undo: the block's
-- name and its state for a dig (the dig looks first, so the state comes free), the item for a placement.  T.undo(n) puts
-- the last n back: a dug block is placed again (through T.placeAt when it has a state, with the item on hand) and a placed one
-- is dug out.  T.undoMark() gives a mark to undo back to later: T.undo(nil, { since = mark }).  The journal is cut to its
-- newest 2000 entries (the setting undo.max).  Moves are not written down, and neither is anything done while undoing.
--
-- T.report tells the player (the setting turtle.player, never in the code) through a chat box, with where the turtle is, its
-- fuel and the job's progress added.  A chat box that is not attached is equipped for the moment through T.withPeripheral;
-- the chat box's cooldown is waited out and retried.  T.report.every(n) makes the job tell the player once in every n steps
-- (a step is a T.job.done, or a progress line from a build or a harvest).

local T = require("turtlelib")
local text = require("text")
local convert = require("convert")
local fileio = require("fileio")
local tables = require("tables")

local JOB_FILE = ".job"
local UNDO_FILE = ".undo"
local CHAT_BOX = "advancedperipherals:chat_box"
local MAX_NOTES = 40
local UNDO_MAX = 2000
-- Where to stand to reach a cell: above first, then below, then the four sides
local STANDS = { { 0, 1, 0 }, { 0, -1, 0 }, { 1, 0, 0 }, { -1, 0, 0 }, { 0, 0, 1 }, { 0, 0, -1 } }
-- The compass words placeAt takes for a facing
local COMPASS = { north = true, east = true, south = true, west = true }

--------------------------------------------------------------------------
-- State shared by every copy of this module (one turtle, a library per program)
--------------------------------------------------------------------------
local holder = turtle or _G
local S = holder._ccnixJournal
if not S then
    S = { undoing = false, ticks = 0, reporting = false }
    holder._ccnixJournal = S
end

-- The line with its newlines made spaces: a line of a file is one line.
local function oneLine(s) return text.replace(tostring(s), "\n", " ") end

--------------------------------------------------------------------------
-- The job journal
--------------------------------------------------------------------------
T.job = {}

-- The job as the file has it: { goal, every, steps = { { text, done } }, notes = { text }, work = { key = text }, keys = { key } },
-- or nil if there is none.
local function loadJob()
    local data = fileio.read(T.dataPath(JOB_FILE))
    if not data then return nil end
    local job = { steps = {}, notes = {}, work = {}, keys = {} }
    for _, line in ipairs(text.lines(data)) do
        local word, rest = text.cut(line, " ")
        rest = rest or ""
        if word == "goal" then
            job.goal = rest
        elseif word == "every" then
            job.every = convert.toInteger(rest)
        elseif word == "step" then
            local state, said = text.cut(rest, " ")
            job.steps[#job.steps + 1] = { text = said or "", done = state == "done" }
        elseif word == "note" then
            job.notes[#job.notes + 1] = rest
        elseif word == "work" then
            local key, said = text.cut(rest, " ")
            if not job.work[key] then job.keys[#job.keys + 1] = key end
            job.work[key] = said or ""
        end
    end
    if not job.goal then return nil end
    return job
end

-- Write the job to its file.  True, or nil and why.
local function saveJob(job)
    local out = { "goal " .. oneLine(job.goal) }
    if job.every and job.every > 0 then out[#out + 1] = "every " .. job.every end
    for _, s in ipairs(job.steps) do out[#out + 1] = "step " .. (s.done and "done " or "todo ") .. oneLine(s.text) end
    for _, key in ipairs(job.keys) do
        if job.work[key] then out[#out + 1] = "work " .. key .. " " .. oneLine(job.work[key]) end
    end
    for _, note in ipairs(job.notes) do out[#out + 1] = "note " .. oneLine(note) end
    return fileio.write(T.dataPath(JOB_FILE), table.concat(out, "\n") .. "\n")
end

-- The index of the first step not done, or nil.
local function nextStep(job)
    for i, s in ipairs(job.steps) do
        if not s.done then return i end
    end
end

-- How the job stands, in one line: "step 2 of 3: lay the floor; build keep: 40 of 300 cells".
local function statusOf(job)
    local parts = {}
    local n = nextStep(job)
    if #job.steps > 0 then
        if n then parts[#parts + 1] = "step " .. n .. " of " .. #job.steps .. ": " .. job.steps[n].text
        else parts[#parts + 1] = "all " .. #job.steps .. " steps done" end
    end
    for _, key in ipairs(job.keys) do
        if job.work[key] then parts[#parts + 1] = key .. ": " .. job.work[key] end
    end
    if #parts == 0 then return job.goal end
    return table.concat(parts, "; ")
end

-- Declared below with T.report; a step done or progress made counts toward T.report.every.
local tick

-- Start a job: its goal and the steps of the plan (a list of texts, or none).  Replaces the job that was on.  True, or nil and
-- why.
function T.job.start(goal, steps)
    if type(goal) ~= "string" or text.trim(goal) == "" then return nil, "a job needs a goal (a text)" end
    local job = { goal = goal, steps = {}, notes = {}, work = {}, keys = {} }
    for i, s in ipairs(steps or {}) do
        if type(s) ~= "string" or text.trim(s) == "" then return nil, "step " .. i .. " is not a text" end
        job.steps[i] = { text = s, done = false }
    end
    S.ticks = 0
    return saveJob(job)
end

-- Mark a step done: its number, its text, or nothing for the next one not done.  Returns true and how many steps are left, or
-- nil and why (no job, no such step).
--
-- A step done twice is done.  With T.report.every set, the player is told once in every n steps.
function T.job.done(step)
    local job = loadJob()
    if not job then return nil, "no job is on: T.job.start(goal, steps)" end
    local at
    if step == nil then
        at = nextStep(job)
        if not at then return nil, "every step is done already" end
    elseif type(step) == "number" then
        at = job.steps[step] and step or nil
    else
        for i, s in ipairs(job.steps) do
            if s.text == step then at = i; break end
        end
    end
    if not at then return nil, "the job has no step " .. tostring(step) end
    job.steps[at].done = true
    local ok, why = saveJob(job)
    if not ok then return nil, why end
    local left = 0
    for _, s in ipairs(job.steps) do if not s.done then left = left + 1 end end
    tick(job, "done: " .. job.steps[at].text)
    return true, left
end

-- The job as it stands: { goal, steps = { { text, done } }, step (the text of the step to do now), next (its number), done,
-- total, finished, notes, work = { key = text }, every }; nil and why if there is none.
--
-- This is what to call after a restart: the job is carried on at job.next.
function T.job.resume()
    local job = loadJob()
    if not job then return nil, "no job is on" end
    local at = nextStep(job)
    local done = 0
    for _, s in ipairs(job.steps) do if s.done then done = done + 1 end end
    job.next, job.step = at, at and job.steps[at].text or nil
    job.done, job.total = done, #job.steps
    job.finished = #job.steps > 0 and at == nil
    job.keys = nil
    return job
end

-- Add a note to the job (the newest 40 are kept).  True, or nil and why.
function T.job.note(said)
    local job = loadJob()
    if not job then return nil, "no job is on: T.job.start(goal, steps)" end
    job.notes[#job.notes + 1] = said
    while #job.notes > MAX_NOTES do table.remove(job.notes, 1) end
    return saveJob(job)
end

-- Set the progress line for a key such as "build" or "harvest" (text nil takes it away).  T.build and T.harvest call this
-- when a job is on.  True, or nil and why.
function T.job.progress(key, said)
    local job = loadJob()
    if not job then return nil, "no job is on: T.job.start(goal, steps)" end
    if not job.work[key] and said ~= nil then job.keys[#job.keys + 1] = key end
    job.work[key] = said
    local ok, why = saveJob(job)
    if not ok then return nil, why end
    if said ~= nil then tick(job, key .. ": " .. said) end
    return true
end

-- How the job stands in one line ("step 2 of 3: lay the floor; build keep: 40 of 300 cells"), or nil if there is none.
function T.job.status()
    local job = loadJob()
    if not job then return nil end
    return statusOf(job)
end

-- Forget the job.  True.
function T.job.clear()
    local path = T.dataPath(JOB_FILE)
    if fs.exists(path) then fs.delete(path) end
    S.ticks = 0
    return true
end

--------------------------------------------------------------------------
-- Reports to the player
--------------------------------------------------------------------------
T.report = {}

-- Where the turtle is, for a report: the world cell when the origin is known, else the turtle's own frame.
local function whereText()
    if T.origin and T.origin() then
        local w = T.toWorld(T.pos)
        if w then return string.format("at %d,%d,%d", w.x, w.y, w.z) end
    end
    return string.format("at %d,%d,%d (turtle frame)", T.pos.x, T.pos.y, T.pos.z)
end

-- The player to tell: the setting turtle.player.
local function playerName()
    return T.setting("turtle.player", "", "The player the turtle's reports go to (through a chat box)")
end

-- Hand the message to a chat box and wait out its cooldown.  True, or nil and why.
local function deliver(box, who, message, tries, wait)
    local mc = require("mc")
    local chat = mc.new(box and { chatBox = box } or nil)
    if not chat.has.chat then return nil, "no chat box to speak through" end
    local label = os.getComputerLabel and os.getComputerLabel() or "turtle"
    local ok, why = chat.tell(who, message, label)
    if not ok then return nil, why end
    for _ = 1, tries do
        if chat.flush() then return true end
        sleep(wait)
    end
    return nil, "the chat box stayed busy"
end

-- The telling itself, for T.report.now: `said` with its additions, through the chat box, however it is reached.  True, or nil and why.
local function sendReport(said, opts, who)
    local message = said
    if not opts.plain then
        local fuel = turtle.getFuelLevel()
        local parts = { whereText(), "fuel " .. tostring(fuel) }
        local job = loadJob()
        if job then parts[#parts + 1] = "job: " .. statusOf(job) end
        message = said .. " [" .. table.concat(parts, "; ") .. "]"
    end
    local tries, wait = opts.tries or 5, opts.wait or 1
    local mc = require("mc")
    if mc.new().has.chat == "chat box" then return deliver(nil, who, message, tries, wait) end
    local ok, a, b = T.withPeripheral(CHAT_BOX, function(box) return deliver(box, who, message, tries, wait) end)
    if not ok then return nil, a end
    return a, b
end

-- Tell the player `said`, with where the turtle is, its fuel and the job's progress added: true, or nil and why.
--
-- The player is the setting turtle.player (opts.player overrides it); with none, nothing is said.  A chat box on a side is used
-- as it is; otherwise one aboard is equipped for the moment (T.withPeripheral), which puts back what was on that side.  The
-- chat box's cooldown is retried opts.tries times (default 5), opts.wait seconds apart (default 1).  opts.plain sends the
-- text alone.  T.report(said, opts) does the same.
--
-- opts.from names a side ("top", "bottom" or "front") whose container may hold the chat box: with none aboard or attached, one is
-- taken out of it for the telling and put back after (a program that keeps its chat box in the chest at home).
function T.report.now(said, opts)
    opts = opts or {}
    if type(said) ~= "string" or said == "" then return nil, "nothing to say: give the text" end
    local who = opts.player or playerName()
    if type(who) ~= "string" or who == "" then
        return nil, "no player to tell: set turtle.player (sysctl turtle.player=<name>)"
    end
    local borrowed = false
    if opts.from and T.countItem(CHAT_BOX) == 0 and require("mc").new().has.chat ~= "chat box" and T.containerOn(opts.from) then
        borrowed = T.pull(opts.from, CHAT_BOX, 1) == 1
    end
    local ok, sent, why = pcall(sendReport, said, opts, who)
    if borrowed and T.selectItem(CHAT_BOX) then T.dropSide(opts.from, 1); turtle.select(1) end
    if not ok then error(sent, 0) end
    return sent, why
end

-- T.report.now for a program's end or trouble: the same arguments, but it never raises.  True, or nil and why (Ctrl+T goes on).
function T.report.try(said, opts)
    local ok, sent, why = pcall(T.report.now, said, opts)
    if not ok and sent == "Terminated" then error(sent, 0) end
    if not ok then return nil, tostring(sent) end
    return sent, why
end

setmetatable(T.report, { __call = function(_, said, opts) return T.report.now(said, opts) end })

-- Make the job tell the player once in every n steps (a T.job.done, or a progress line from a build or a harvest); 0 or nil
-- turns it off.  It is kept in the job, so it needs one (T.job.start) and lasts a restart.  True, or nil and why.
function T.report.every(n)
    if n ~= nil and (type(n) ~= "number" or n < 0 or n ~= math.floor(n)) then return nil, "n is a whole number of steps, or nil" end
    local job = loadJob()
    if not job then return nil, "no job is on: T.job.start(goal, steps)" end
    job.every = n and n > 0 and n or nil
    S.ticks = 0
    return saveJob(job)
end

-- A step happened: every n-th one is reported.  A report that fails is noted in the job and goes no further.
function tick(job, said)
    local n = job.every
    if not n or n <= 0 or S.reporting then return end
    S.ticks = S.ticks + 1
    if S.ticks < n then return end
    S.ticks = 0
    S.reporting = true
    local ok, sent, why = pcall(T.report.now, job.goal .. " - " .. said)
    S.reporting = false
    if not ok and sent == "Terminated" then error(sent, 0) end
    if not ok then sent, why = nil, sent end
    if not sent then pcall(T.job.note, "a report did not go: " .. tostring(why)) end
end

--------------------------------------------------------------------------
-- The undo journal
--------------------------------------------------------------------------

-- A state as one word of the file: "facing=north,half=top", or "-" for none.
local function stateText(state)
    if type(state) ~= "table" or next(state) == nil then return "-" end
    local parts = {}
    for _, key in ipairs(tables.sortedKeys(state)) do parts[#parts + 1] = key .. "=" .. tostring(state[key]) end
    return table.concat(parts, ",")
end

-- The state a word of the file stands for: a table of text values, or nil.
local function stateOf(word)
    if not word or word == "-" then return nil end
    local state = {}
    for _, pair in ipairs(text.split(word, ",")) do
        local key, value = text.cut(pair, "=")
        if value then state[key] = value end
    end
    return next(state) and state or nil
end

-- The entries of the journal file, oldest first: { seq, kind = "dig" | "place", x, y, z, name, state }.
local function loadUndo()
    local list = {}
    for _, line in ipairs(text.lines(fileio.read(T.dataPath(UNDO_FILE)) or "")) do
        local w = text.words(line)
        local seq, x, y, z = convert.toInteger(w[1] or ""), convert.toInteger(w[3] or ""), convert.toInteger(w[4] or ""), convert.toInteger(w[5] or "")
        if seq and x and y and z and (w[2] == "dig" or w[2] == "place") and w[6] then
            list[#list + 1] = { seq = seq, kind = w[2], x = x, y = y, z = z, name = w[6], state = stateOf(w[7]) }
        end
    end
    return list
end

-- One entry as a line of the file.
local function undoLine(e)
    return string.format("%d %s %d %d %d %s %s", e.seq, e.kind, e.x, e.y, e.z, e.name, stateText(e.state))
end

-- Write the journal file from a list of entries.  True, or nil and why.
local function saveUndo(list)
    local out = {}
    for i, e in ipairs(list) do out[i] = undoLine(e) end
    S.count = #list
    return fileio.write(T.dataPath(UNDO_FILE), #out > 0 and table.concat(out, "\n") .. "\n" or "")
end

-- Where the numbering and the length stand, read from the file the first time.
local function counters()
    if S.seq then return end
    local list = loadUndo()
    S.seq, S.count = list[#list] and list[#list].seq or 0, #list
end

-- Add an entry to the file; the file is cut to three quarters of undo.max when it passes it.
local function record(e)
    counters()
    S.seq = S.seq + 1
    e.seq = S.seq
    local f = fs.open(T.dataPath(UNDO_FILE), "a")
    if not f then return end
    f.write(undoLine(e) .. "\n")
    f.close()
    S.count = S.count + 1
    local max = T.setting("undo.max", UNDO_MAX, "How many blocks the undo journal keeps")
    if S.count > max then
        local list = loadUndo()
        local keep = math.floor(max * 3 / 4)
        local cut = {}
        for i = #list - keep + 1, #list do cut[#cut + 1] = list[i] end
        saveUndo(cut)
    end
end

-- Hear a dig or a placement (T.cfg.undo on, and not while undoing) and write it down.
local function heard(e)
    if S.undoing or not T.cfg.undo then return end
    if e.kind == "dig" and e.was then
        record({ kind = "dig", x = e.x, y = e.y, z = e.z, name = e.was, state = e.state })
    elseif e.kind == "place" and e.item then
        record({ kind = "place", x = e.x, y = e.y, z = e.z, name = e.item })
    end
end

S.heard = heard
if not S.listening then
    S.listening = true
    T.onChange(function(e) return S.heard(e) end)
end

-- The mark of the journal as it is now: T.undo(nil, { since = mark }) undoes everything done after it.
function T.undoMark()
    counters()
    return S.seq
end

-- Empty the undo journal.  True.
function T.undoClear()
    counters()
    saveUndo({})
    return true
end

-- The block's short name, for telling a placed block from the item that placed it (a torch item, a wall_torch block).
local function shortOf(name)
    local _, short = text.cut(name, ":")
    return short or name
end

-- Go to a cell next to `cell` (the way `opts.move` allows) and say which way it is: the direction (T.dirTo), or nil and why.
local function standBeside(cell, opts)
    local why
    for _, s in ipairs(STANDS) do
        local ok, reason = T.moveTo(cell.x + s[1], cell.y + s[2], cell.z + s[3], opts.move)
        if ok then return T.dirTo(cell) end
        why = why or reason
    end
    return nil, why
end

-- The compass facing, half, axis and face the state names, for T.placeAt.
local function placeOpts(state, opts)
    local o = { move = opts.move, inside = opts.inside }
    if not state then return o end
    if COMPASS[state.facing or ""] then o.facing = state.facing end
    if state.half == "top" or state.half == "bottom" then o.half = state.half
    elseif state.type == "top" or state.type == "bottom" then o.half = state.type end
    if state.axis then o.axis = state.axis end
    if state.face then o.face = state.face end
    return o
end

-- Put back a block that was dug: true, or false and why.
local function putBack(e, opts)
    if T.countItem(e.name) == 0 then return false, "none of " .. e.name .. " aboard" end
    if e.state then
        local placeAt = T.need("placeAt")
        if placeAt then
            local name, _, how = placeAt(e.x, e.y, e.z, e.name, placeOpts(e.state, opts))
            if name then return true end
            return false, tostring(how)
        end
    end
    local d, why = standBeside(e, opts)
    if d == nil then return false, "can't get next to it: " .. tostring(why) end
    local seen, data = T.look(d)
    if seen and type(data) == "table" and data.name then
        if data.name == e.name then return true end
        return false, "the cell holds " .. data.name
    end
    T.selectItem(e.name)
    local ok, err = T.placeDir(d)
    if ok then return true end
    return false, "couldn't place it: " .. tostring(err)
end

-- Dig out a block that was placed: true, or false and why.  A cell that is empty already is done.
local function takeOut(e, opts)
    local d, why = standBeside(e, opts)
    if d == nil then return false, "can't get next to it: " .. tostring(why) end
    local seen, data = T.look(d)
    if not (seen and type(data) == "table" and data.name) then return true end
    local want, found = shortOf(e.name), shortOf(data.name)
    if not (found == want or text.endsWith(found, "_" .. want)) then
        return false, "the cell holds " .. data.name .. ", not " .. e.name
    end
    local ok, err = T.digDir(d)
    if ok then return true end
    return false, "couldn't dig it: " .. tostring(err)
end

-- Put back what the journal wrote down, newest first: the last n entries (default 1), or those after opts.since (T.undoMark).
-- Returns true, info; false, why, info when some could not be; nil, why if there is nothing to undo.
--
-- A block that was dug is placed again (T.placeAt when it had a state, so it faces as it did; the item must be aboard); one that
-- was placed is dug out if it is still there.  The turtle goes next to each cell (opts.move is T.moveTo's; opts.inside names a
-- protected area the job may work in).  An entry that was done leaves the journal; one that could not stays, and info.failed lists
-- it: { seq, kind, x, y, z, name, why }.  info.undone is how many went.  It does nothing to what the turtle did since to those cells
-- except as said, and it writes nothing to the journal itself.
function T.undo(n, opts)
    opts = opts or {}
    if n ~= nil and (type(n) ~= "number" or n < 1 or n ~= math.floor(n)) then return nil, "n is a whole number of entries, from 1" end
    if opts.since ~= nil and type(opts.since) ~= "number" then return nil, "opts.since is a mark from T.undoMark()" end
    counters()
    local list = loadUndo()
    local picked = {}
    for i = #list, 1, -1 do
        local e = list[i]
        if opts.since then
            if e.seq <= opts.since then break end
        elseif #picked >= (n or 1) then
            break
        end
        picked[#picked + 1] = e
    end
    if #picked == 0 then
        return nil, "nothing to undo: the journal is empty (T.cfg.undo = true writes it)"
    end
    local info = { undone = 0, failed = {} }
    local gone = {}
    S.undoing = true
    local ok, err = pcall(function()
        local run = function()
            for _, e in ipairs(picked) do
                local good, why
                if e.kind == "dig" then good, why = putBack(e, opts) else good, why = takeOut(e, opts) end
                if good then
                    info.undone = info.undone + 1
                    gone[e.seq] = true
                else
                    info.failed[#info.failed + 1] = { seq = e.seq, kind = e.kind, x = e.x, y = e.y, z = e.z, name = e.name, why = why }
                end
            end
        end
        if opts.inside then T.inside(opts.inside, run) else run() end
    end)
    S.undoing = false
    local kept = {}
    for _, e in ipairs(list) do
        if not gone[e.seq] then kept[#kept + 1] = e end
    end
    saveUndo(kept)
    if not ok then error(err, 0) end
    if #info.failed > 0 then
        local f = info.failed[1]
        return false, #info.failed .. " could not be undone, the first " .. f.name .. " at " .. f.x .. "," .. f.y .. "," .. f.z .. ": " .. f.why, info
    end
    return true, info
end

return T
