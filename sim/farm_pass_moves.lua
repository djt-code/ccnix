-- sim/farm_pass_moves.lua
--
-- Movement benchmark: learn a 9x8 farm, then count the moves of one
-- plain farming pass.  ALONGX=1 turns the lanes along x instead of z.
local PROJ = ...
package.path = PROJ .. "/turtle/?.lua;" .. PROJ .. "/lib/?.lua;" .. PROJ .. "/sim/lib/?.lua;" .. package.path
local F = require("farmworld")
local run = F.runner(PROJ)

F.build({ width = 9, length = 8, lanes = { 3, 6 }, alongX = os.getenv("ALONGX") == "1" })
F.stock()
run("9", "8", "0")
F.stock()
run("0")
F.print("PASS MOVES " .. F.moves)
