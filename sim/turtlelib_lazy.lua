-- sim/turtlelib_lazy.lua
--
-- turtlelib's loader for the modules beside it (ADR-0008): a function T
-- lacks is looked up in T.registry, its module (tl.<name>, here a fixture
-- in sim/lib/tl/) is required once, only when first used, and is handed the
-- very T that asked for it.
local PROJ = ...
package.path = PROJ .. "/turtle/?.lua;" .. PROJ .. "/lib/?.lua;" .. PROJ .. "/sim/lib/?.lua;" .. package.path
local M = require("mock")
local check = M.check

local S = M.state()
fs = M.fsApi(S)
shell = M.shellApi("x.lua")
sleep = function() end
turtle = M.merge(M.inventoryApi(S), M.fuelApi(S))
FIXTURE_LOADS = nil

local function load()
    package.loaded.turtlelib = nil
    return require("turtlelib")
end
local T = load()
local S1 = package.searchpath("tl.fixture", PROJ .. "/turtle/?.lua;" .. PROJ .. "/sim/lib/?.lua")
check("require(\"tl.x\") turns the dot into a folder on a ?.lua path", S1 and S1:gsub("\\", "/"):find("tl/fixture.lua", 1, true) ~= nil)

check("turtlelib has a registry, empty to begin with, and loads no module itself", next(T.registry) == nil and FIXTURE_LOADS == nil)
check("a name nobody registered is nil, and loads nothing", T.fixtureHello == nil and T.nothingAtAll == nil and FIXTURE_LOADS == nil)

T.registry.fixtureHello = "tl.fixture"
T.registry.fixtureSecond = "tl.fixture"
T.registry.fixtureSame = "tl.fixture"
T.registry.fixtureReadsKey = "tl.fixture"
check("registering a name loads nothing yet", FIXTURE_LOADS == nil and rawget(T, "fixtureHello") == nil)

check("first use loads the module and calls on", T.fixtureHello("you") == "hello you" and FIXTURE_LOADS == 1, tostring(FIXTURE_LOADS))
check("the module's other functions are in T now, with no second load",
    rawget(T, "fixtureSecond") ~= nil and T.fixtureSecond() == "second" and FIXTURE_LOADS == 1, tostring(FIXTURE_LOADS))
check("the module was handed this very T", T.fixtureSame() == T)
check("the module sees the real world (the fs turtlelib has)", T.fixtureReadsKey() == false)
S.files["claude.key"] = "sk-x"
check("...and reads what is there", T.fixtureReadsKey() == true)

-- a module is handed the T that asked for it, whatever package.loaded says
local T2 = load()
T2.registry.fixtureSame = "tl.fixture"
local other = {}
package.loaded.turtlelib = other
check("a second copy of turtlelib loads its own copy of the module, and gives it that copy",
    T2.fixtureSame() == T2 and FIXTURE_LOADS == 2 and T2 ~= T, tostring(FIXTURE_LOADS))
check("package.loaded.turtlelib is put back as it was", package.loaded.turtlelib == other)
package.loaded.turtlelib = T2

-- T.need
local f, why = T.need("fixtureHello")
check("T.need gives the function", type(f) == "function" and why == nil)
f, why = T.need("nothingAtAll")
check("T.need on an unknown name says so", f == nil and why == "turtlelib has no nothingAtAll", tostring(why))
f, why = T.need("cfg")
check("T.need on what T has gives it as it is", f == T.cfg)

-- a module that doesn't define what the registry says
T.registry.fixtureAbsent = "tl.fixture"
f, why = T.need("fixtureAbsent")
check("a module that lacks the name: nil and why", f == nil and why and why:find("loaded but doesn't define T.fixtureAbsent", 1, true), tostring(why))

-- modules that won't load
T.registry.brokenOne = "tl.broken"
T.registry.missingOne = "tl.nowhere"
f, why = T.need("brokenOne")
check("a module that errors: nil and what it said", f == nil and why and why:find("didn't load", 1, true) and why:find("this module is broken", 1, true), tostring(why))
check("...and package.loaded.turtlelib is as it was", package.loaded.turtlelib == T2)
local g = T.brokenOne
local ok, err = pcall(g)
check("T.name for such a module is a function that raises the reason when called",
    type(g) == "function" and not ok and tostring(err):find("this module is broken", 1, true), tostring(err))
f, why = T.need("missingOne")
check("a module that isn't there: nil and why", f == nil and why and why:find("tl.nowhere", 1, true) and not why:find("\n", 1, true))
check("neither is kept as loaded", package.loaded["tl.broken"] == nil and package.loaded["tl.nowhere"] == nil)

-- a module that asks for its own function while it loads
T.registry.reentrantOne = "tl.reenter"
T.registry.reentrantTwo = "tl.reenter"
check("a module that asks for its own function while it loads gets nil and why, not a loop",
    T.reentrantOne() == 1 and REENTER_EARLY[1] == nil and tostring(REENTER_EARLY[2]):find("is loading", 1, true)
    and T.reentrantTwo() == 2, tostring(REENTER_EARLY[2]))
