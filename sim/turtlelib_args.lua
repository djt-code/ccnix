-- sim/turtlelib_args.lua
--
-- What the turtle programs read from their command line and their files,
-- on the shared libraries: T.options (lib/getopt, with a negative size or
-- a goal's -x left a word: `mine -3 3 32`), the position and column keys
-- (lib/text and lib/convert), and mine's job file (lib/fileio), written
-- by mine and read by mine and autostart through turtlelib alone.
local PROJ = ...
package.path = PROJ .. "/turtle/?.lua;" .. PROJ .. "/lib/?.lua;" .. PROJ .. "/sim/lib/?.lua;" .. package.path
local M = require("mock")
local check = M.check

local S = { files = {} }               -- the computer's files, for M.fsApi
fs = M.fsApi(S)
textutils = M.textutilsApi()           -- (lib/fileio reads JSON with it)
shell = M.shellApi("ccnix/turtle/mine.lua")
local T = require("turtlelib")

local function words(list) return table.concat(list, " ") end

-- 1. options
local MINE = { here = true, resume = true, new = true, ["no-lights"] = true, spacing = "=", home = "=",
               ["to-start"] = true }
local opts, args = T.options({ "-3", "3", "32" }, MINE)
check("mine -3 3 32: a negative size is a size", opts and next(opts) == nil and words(args) == "-3 3 32", words(args))
opts, args = T.options({ "-3", "--spacing", "8", "-2", "--no-lights", "40", "--here" }, MINE)
check("options among the sizes, anywhere", opts and opts.spacing == "8" and opts["no-lights"] == true and opts.here == true
    and words(args) == "-3 -2 40", words(args))
opts, args = T.options({ "reset", "--home=2", "--to-start" }, MINE)
check("--name=word too", opts and opts.home == "2" and opts["to-start"] == true and words(args) == "reset", words(args))
opts, args = T.options({ "--spacing", "-8" }, MINE)
check("an option's word can start with a dash", opts and opts.spacing == "-8" and #args == 0)
opts, args = T.options({ "3", "3", "--spacing" }, MINE)
check("an option with no word after it is an error, getopt's", opts == nil and args == "option '--spacing' requires an argument", args)
opts, args = T.options({ "--foo", "3", "--", "-x", "--here=1" }, MINE)
check("a word that isn't one of the options stays a word (--foo, --, -x, a flag given a value)",
    opts and next(opts) == nil and words(args) == "--foo 3 -- -x --here=1", words(args))
opts, args = T.options({ "go", "-5", "blocks", "--model", "m", "--confirm", "-", "x" },
    { confirm = true, model = "=", effort = "=", steps = "=" })
check("claude's goal keeps its words", opts and opts.model == "m" and opts.confirm == true
    and words(args) == "go -5 blocks - x", words(args))

-- 2. keys
local x, y, z = T.keyPos(T.posKey({ x = -12, y = 3, z = 2950 }))
check("keyPos reads what posKey writes", x == -12 and y == 3 and z == 2950)
check("keyPos: not three whole numbers, nil", T.keyPos("1,2") == nil and T.keyPos("1,2,3,4") == nil
    and select(3, T.keyPos("1,2,x")) == nil)
local cx, cz = T.keyXZ(T.ckey(-7, 0))
check("keyXZ reads what ckey writes", cx == -7 and cz == 0)
check("keyXZ: not two whole numbers, nil", T.keyXZ("1,2,3") == nil and T.keyXZ("") == nil and T.keyXZ("1.5,2") == nil)

-- 3. mine's job file
local JOB = "ccnix/turtle/mine.job"
check("no job file: no job", not T.hasMineJob() and T.loadMineJob() == nil)
T.saveMineJob({ width = -3, height = 3, length = nil, spacing = 16, homes = 2, state = "active" })
check("a job is saved as mine always wrote it (length 0: no end)", S.files[JOB] == "-3 3 0 16 2 active", S.files[JOB])
local job = T.loadMineJob()
check("and read back", job and job.width == -3 and job.height == 3 and job.length == nil and job.spacing == 16
    and job.homes == 2 and job.state == "active")
S.files[JOB] = "3 3 40 16 2 done\n"
job = T.loadMineJob()
check("a length", job and job.length == 40 and job.state == "done")
S.files[JOB] = "3 x 40 16 2 done"
check("a job that isn't one: there, but nil", T.hasMineJob() and T.loadMineJob() == nil)

-- 4. the position
T.pos.x, T.pos.y, T.pos.z, T.dir, T.mode = 4, -2, 17, 3, "terrain"
T.savePos()
local saved = T.loadPos()
check("the position, saved and read back", saved and saved.x == 4 and saved.y == -2 and saved.z == 17 and saved.dir == 3
    and saved.mode == "terrain", S.files["ccnix/turtle/.turtlepos"])
