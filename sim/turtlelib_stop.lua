-- sim/turtlelib_stop.lua
--
-- T.run and Ctrl+T.  In CC a turtle command waits for its
-- "turtle_response" event, and a Ctrl+T ("terminate") during that wait
-- stops the program, although the turtle still turns or moves: the
-- program never records it, and its saved heading or position is wrong.
-- Under T.run the terminate is held back until the command is done, and
-- the program stops once the turn is saved.  Without it, the saved
-- heading is off by one.
local PROJ = ...
package.path = PROJ .. "/turtle/?.lua;" .. PROJ .. "/lib/?.lua;" .. PROJ .. "/sim/lib/?.lua;" .. package.path
local M = require("mock")

local realPrint = print
local S = { files = {} }               -- the computer's files, for M.fsApi
fs = M.fsApi(S)
shell = M.shellApi("x.lua")

-- A turtle whose turns wait for their response, as in CC; the user
-- presses Ctrl+T while the second turn is under way.
local facing, turns = 0, 0
local EVENTS
os.pullEventRaw = function() return table.remove(EVENTS, 1) end
local function command(apply)
    -- the turtle does it whatever happens to the program meanwhile
    apply()
    local ev
    repeat ev = coroutine.yield("turtle_response") until ev == "turtle_response" or ev == "terminate"
    if ev == "terminate" then error("Terminated", 0) end      -- what CC does
    return true
end
turtle = {
    turnRight = function() return command(function() facing = (facing + 1) % 4; turns = turns + 1 end) end,
}

local function trial(label, safe)
    S.files, facing, turns = {}, 0, 0
    EVENTS = { "turtle_response", "terminate", "turtle_response", "turtle_response", "turtle_response" }
    package.loaded.turtlelib = nil
    local T = require("turtlelib")
    local function job()
        for _ = 1, 4 do T.turnRight() end
    end
    local ok, err
    if safe then
        ok, err = pcall(T.run, job)
    else
        local co = coroutine.create(job)          -- what the shell does: pass every event
        local args = {}
        while true do
            local r = table.pack(coroutine.resume(co, table.unpack(args)))
            if not r[1] then ok, err = false, r[2]; break end
            if coroutine.status(co) == "dead" then ok = true; break end
            args = { os.pullEventRaw() }
        end
    end
    local saved = tonumber((S.files[".turtlepos"] or ""):match("^%-?%d+ %-?%d+ %-?%d+ (%d)"))
    realPrint(string.format("%s: %s after %d turns, really facing %d, saved %s",
        label, ok and "finished" or tostring(err), turns, facing, tostring(saved)))
    return ok, err, saved
end

local ok, err, saved = trial("without T.run", false)
realPrint("   (the saved heading is " .. (saved == facing and "right" or "WRONG: the turn under way was lost") .. ")")
ok, err, saved = trial("with T.run", true)
realPrint(string.format("   %s stopped by Ctrl+T, with the heading saved right",
    (not ok and err == "Terminated" and saved == facing) and "ok   " or "ERROR:"))
