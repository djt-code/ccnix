-- autostart.lua -- at boot, carry on with the turtle's job
--
-- Usage:  autostart          what startup runs (setup puts it there)
--         autostart --now    the same, without the 5 second wait
--
-- Runs the program named by the setting ccnix.autostart (mine, farm,
-- mow, autocompost or claude; `sysctl ccnix.autostart=farm`, or
-- `ccnix setup --autostart farm`).  A turtle reboots whenever its chunk
-- loads again, so this is what keeps a job going.  It waits 5 seconds
-- first: any key cancels, for the prompt.
--
--   mine         a tunnel it was digging when it went down: back to the
--                last home if it's elsewhere, then `mine --resume`.  No
--                tunnel yet: a new one, as the settings say (mine.width,
--                mine.height, mine.length: 3x3, 32 long unless changed).
--                A tunnel it finished, or stopped itself (the start's chest
--                full, bedrock; out of chests or fuel only with mine.wait
--                off, since it waits for them): it says so and leaves it
--                to you.
--   farm         a saved farm: home if it's elsewhere, then farm it.  No
--                farm yet: learn the one the settings give (farm.width,
--                farm.length), then farm it.
--   mow          a pass it was in the middle of: home, then mow.  Mowing
--                on repeat (mow.repeat > 0): mow.  Otherwise nothing: the
--                lawn was mowed.
--   autocompost  autocompost.
--   claude       a goal it was working at when it went down
--                (/claude/resume.txt), with claude.resume = true:
--                `claude --resume`, which tells the model it was
--                interrupted and carries on (API money spent with nobody
--                there, so only when set).  Otherwise claude, waiting for
--                a goal, with the options the last session had (the
--                setting claude.options).
--
-- With init at boot (`ccnix setup init`), the job runs as a service of
-- its own name instead (service mine: `autostart --now`, not started
-- again when it ends), so what it prints is kept in the system log
-- (/var/log/messages) and the console is free: `service status mine`,
-- `tail -f /var/log/messages`, `service stop mine` (as Ctrl+T) and
-- `service start mine` (picks it up again).  Stop the service before
-- running the program by hand.

package.path = (ccnix and ccnix.lib or "") .. package.path    -- (ccnix's turtlelib, the updates' first)
local T = require("turtlelib")

local CHOICES = { mine = true, farm = true, mow = true, autocompost = true, claude = true }
local prog = settings.get("ccnix.autostart", "")
if prog == "" then return end
if not CHOICES[prog] then
    printError("autostart: can't start '" .. prog .. "' (mine, farm, mow, autocompost or claude)")
    return
end

-- Where the turtle last saved itself, checked against GPS where there is GPS (ADR-0018): the position (false if
-- there's none) and whether GPS put it beyond reach.  Asked once.
local checked, beyond
local function position()
    if checked == nil then
        local note
        checked, note, beyond = T.checkedPos()
        checked = checked or false
        if note then print("autostart: " .. note) end
    end
    return checked or nil, beyond
end

-- Where the turtle last saved itself, if not at the start
local function away()
    local p = position()
    return p and (p.x ~= 0 or p.y ~= 0 or p.z ~= 0 or p.dir ~= 0) and p or nil
end

-- The steps for each program: lists of command lines, or nil and why not
local function plan()
    if prog == "mine" or prog == "farm" or prog == "mow" then
        local _, far = position()
        if far then return nil, "GPS puts the turtle far from where it was saved (above): put it back, or start it with --here" end
    end
    if prog == "mine" then
        if not T.hasMineJob() then return { { "mine" } } end
        -- the job as mine saved it (one it can't read: carry on, and mine says why)
        local job = T.loadMineJob() or {}
        local state = job.state
        if job.stale then
            return nil, "the tunnel can't be carried on (" .. job.stale .. "): `mine --new` for another"
        end
        if state == "done" or state == "stopped" then
            return nil, "the tunnel " .. (state == "done" and "is finished" or "stopped itself")
                .. ": `mine --resume`, or `mine --new` for another"
        end
        local p = away()
        local spacing = job.spacing or 0
        local atHome = not p or (p.x == 0 and p.y == 0 and spacing > 0 and p.z % spacing == 0)
        if atHome then return { { "mine", "--resume" } } end
        return { { "mine", "reset" }, { "mine", "--resume" } }
    elseif prog == "farm" then
        if not fs.exists(T.dataPath("farm.map")) then
            if not (settings.get("farm.width") and settings.get("farm.length")) then
                return nil, "no farm learned yet, and no size to learn: `sysctl farm.width=9 farm.length=9`"
            end
            return { { "farm" } }
        end
        if away() then return { { "farm", "reset" }, { "farm" } } end
        return { { "farm" } }
    elseif prog == "mow" then
        if away() then return { { "mow", "reset" }, { "mow" } } end
        if (settings.get("mow.repeat") or 0) > 0 then return { { "mow" } } end
        return nil, "the lawn was mowed (sysctl mow.repeat=<minutes> to keep mowing)"
    elseif prog == "claude" then
        -- (both settings on: a resume spends API money unattended)
        if settings.get("claude.resume") == true and fs.exists("claude/resume.txt") then return { { "claude", "--resume" } } end
        return { { "claude" } }
    end
    return { { prog } }
end

local steps, why = plan()
if not steps then print("autostart: " .. prog .. ": " .. why); return end

local words = {}
for i, s in ipairs(steps) do words[i] = table.concat(s, " ") end
local line = table.concat(words, ", then ")
if ({ ... })[1] ~= "--now" then
    print("autostart: " .. line .. " in 5 s (any key cancels)")
    local timer = os.startTimer(5)
    while true do
        local ev, id = os.pullEvent()
        if ev == "timer" and id == timer then break end
        if ev == "key" or ev == "char" then print("autostart: cancelled"); return end
    end
end
for _, s in ipairs(steps) do
    if not shell.run(table.unpack(s)) then
        printError("autostart: `" .. table.concat(s, " ") .. "` didn't finish; stopping here")
        return
    end
end
