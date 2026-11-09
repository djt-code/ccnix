-- autostart.lua -- at boot, carry on with the turtle's job
--
-- Usage:  autostart          what startup runs (setup puts it there)
--         autostart --now    the same, without the 5 second wait
--
-- Runs the program named by the setting ccnix.autostart (mine, farm,
-- mow or autocompost; `sysctl ccnix.autostart=farm`, or
-- `ccnix setup --autostart farm`).  A turtle reboots whenever its chunk
-- loads again, so this is what keeps a job going.  It waits 5 seconds
-- first: any key cancels, for the prompt.
--
--   mine         a tunnel it was digging when it went down: back to the
--                last home if it's elsewhere, then `mine --resume`.  No
--                tunnel yet: a new one, as the settings say (mine.width,
--                mine.height, mine.length: 3x3, 32 long unless changed).
--                A tunnel it finished, or stopped itself (out of chests or
--                fuel): it says so and leaves it to you.
--   farm         a saved farm: home if it's elsewhere, then farm it.  No
--                farm yet: learn the one the settings give (farm.width,
--                farm.length), then farm it.
--   mow          a pass it was in the middle of: home, then mow.  Mowing
--                on repeat (mow.repeat > 0): mow.  Otherwise nothing: the
--                lawn was mowed.
--   autocompost  autocompost.
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

local CHOICES = { mine = true, farm = true, mow = true, autocompost = true }
local prog = settings.get("ccnix.autostart", "")
if prog == "" then return end
if not CHOICES[prog] then
    printError("autostart: can't start '" .. prog .. "' (mine, farm, mow or autocompost)")
    return
end

-- Where the turtle last saved itself, if not at the start
local function away()
    local p = T.loadPos()
    return p and (p.x ~= 0 or p.y ~= 0 or p.z ~= 0 or p.dir ~= 0) and p or nil
end

-- The steps for each program: lists of command lines, or nil and why not
local function plan()
    if prog == "mine" then
        local f = fs.open(T.dataPath("mine.job"), "r")
        if not f then return { { "mine" } } end
        local text = f.readAll() or ""
        f.close()
        -- mine.job: "width height length spacing homes state"
        local w = T.words(text)
        local spacing, state
        if #w >= 6 and T.isDigits(w[4]) and T.isDigits(w[5]) and T.isLetters(w[6]) then
            spacing, state = w[4], w[6]
        end
        if state == "done" or state == "stopped" then
            return nil, "the tunnel " .. (state == "done" and "is finished" or "stopped itself")
                .. ": `mine --resume`, or `mine --new` for another"
        end
        local p = away()
        spacing = tonumber(spacing) or 0
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
