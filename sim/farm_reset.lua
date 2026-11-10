-- sim/farm_reset.lua
--
-- `farm reset` after the turtle stopped out on the farm (chunk unloaded,
-- server restarted): a 5x22 farm with a sugar cane strip, so the turtle
-- can be past the library's default 16x16 routing area and among 3-high
-- cane.  Each case leaves the turtle somewhere with its position saved,
-- runs `farm reset` and checks it got home: (0,0,0) facing +z.  Some
-- cases face the turtle other than its saved heading, which it must work
-- out from the farm, as must a farming run started at home facing wrong.
local PROJ = ...
package.path = PROJ .. "/turtle/?.lua;" .. PROJ .. "/lib/?.lua;" .. PROJ .. "/sim/lib/?.lua;" .. package.path
local F = require("farmworld")
local run = F.runner(PROJ)
local P = F.P

F.build({ width = 5, length = 22, lanes = { 3 }, crops = { [4] = "cane", [5] = "minecraft:beetroots" } })
F.stock({ cane = 16, water = 1 })
run("5", "22", "0")
for z = 1, F.LENGTH do for h = 1, 3 do F.set(4, -2 + h, z, { name = F.CANE }) end end

-- facing: which way it really faces, when not the saved d (a turn the
-- server stop kept it from saving, or put back by hand)
local function stopAt(label, x, y, z, d, facing)
    P.x, P.y, P.z, P.d = x, y, z, facing or d
    F.files[".turtlepos"] = string.format("%d %d %d %d flat", x, y, z, d)
    run("reset")
    local home = P.x == 0 and P.y == 0 and P.z == 0 and P.d == 0
    F.print(string.format("RESET %s: %s", label, home and "home" or "NOT HOME"))
end
-- The ground and crops, to see that a run changed nothing it shouldn't.
local function ground()
    local t = {}
    for x = -3, F.WIDTH + 3 do for z = -3, F.LENGTH + 3 do for y = -2, -1 do
        local b = F.get(x, y, z)
        if b and b.name ~= F.CANE then t[#t + 1] = x .. "," .. y .. "," .. z .. "=" .. (F.RIPE[b.name] and "crop" or b.name) end
    end end end
    table.sort(t)
    return table.concat(t, ";")
end
-- R1. cruising over the far end of the farm, past z = 17
stopAt("far end", 2, 0, 21, 0)
-- R2. working cane: one above cruise height over a cane column cut to 2
F.set(4, 1, 10, nil)
stopAt("over cane", 4, 1, 10, 1)
-- R3. down at lane level, walking along the lane
stopAt("in a lane", 3, -1, 19, 2)
-- R4. travelling at cane height past the far end
stopAt("travel height", 5, 2, 22, 3)
-- R7-R9. the saved heading is wrong: at home, and out on the farm
stopAt("home, facing right", 0, 0, 0, 0, 1)
stopAt("home, saved facing left", 0, 0, 0, 3, 0)
stopAt("mid-farm, facing back", 2, 0, 12, 0, 2)
-- R10. a farming run started at home facing the wrong way works the farm
-- the right way round, and changes nothing outside it
local before = ground()
P.x, P.y, P.z, P.d = 0, 0, 0, 3
F.files[".turtlepos"] = "0 0 0 0 flat"
run("0")
local function offFarm(s)
    local n = {}
    for e in s:gmatch("[^;]+") do
        local x, z = e:match("^(-?%d+),%-?%d+,(-?%d+)")
        x, z = tonumber(x), tonumber(z)
        if x < 1 or x > F.WIDTH or z < 1 or z > F.LENGTH then n[#n + 1] = e end
    end
    return table.concat(n, ";")
end
F.print("RUN facing left at home: " .. (P.d == 0 and P.x == 0 and P.z == 0 and "home" or "NOT HOME")
    .. ", outside the farm " .. (offFarm(before) == offFarm(ground()) and "untouched" or "CHANGED"))
-- R5. stopped while learning: no farm map saved yet, far end of the farm
F.files["farm.map"] = nil
stopAt("no map", 2, 0, 21, 0)
-- R6. no map, and left of home (negative x), outside any default area
stopAt("left of home", -4, 0, 3, 0)
