-- sim/turtlelib_datapath.lua
--
-- T.dataPath after the programs moved into turtle/: a data file left in
-- the repo's top folder by an older copy (a job half done) is moved down
-- next to the program, so `--resume` and `reset` still find it.  Nothing
-- else is moved: not a file that's already in turtle/, and not files
-- beside a program anywhere else.
local PROJ = ...
package.path = PROJ .. "/turtle/?.lua;" .. PROJ .. "/lib/?.lua;" .. PROJ .. "/sim/lib/?.lua;" .. package.path
local M = require("mock")
local check = M.check

local S = { files = {} }               -- the computer's files, for M.fsApi
fs = M.fsApi(S)
textutils = M.textutilsApi()               -- (lib/fileio, under turtlelib, reads JSON with it)
local T = require("turtlelib")

S.files, shell = { ["ccnix/mine.seg"] = "12 64" }, M.shellApi("ccnix/turtle/mine.lua")
local p = T.dataPath("mine.seg")
check("a file in the top folder is moved into turtle/", p == "ccnix/turtle/mine.seg"
    and S.files[p] == "12 64" and S.files["ccnix/mine.seg"] == nil, p)

S.files = { ["ccnix/.turtlepos"] = "old", ["ccnix/turtle/.turtlepos"] = "new" }
p = T.dataPath(".turtlepos")
check("one already in turtle/ wins; the old one is left", S.files[p] == "new"
    and S.files["ccnix/.turtlepos"] == "old", p)

S.files, shell = { ["farm.map"] = "x" }, M.shellApi("disk/farm.lua")
p = T.dataPath("farm.map")
check("a program outside turtle/ moves nothing", p == "disk/farm.map" and S.files["farm.map"] == "x", p)

S.files, shell = {}, M.shellApi("farm.lua")
p = T.dataPath("farm.map")
check("a program at the root: beside it, as before", p == "farm.map", p)
