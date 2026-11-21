-- sim/realtime.lua
--
-- lib/realtime.lua (ADR-0015 D9): real seconds at any server tick rate.
-- A clock with two hands: game time (os.clock, what CC's timers and sleep
-- count) and real time (os.epoch("utc")), moved together at TPS ticks a
-- real second.  The tick rate measured (20 until there's a measure, the
-- first after 2 real seconds, then over 10 or more, a change seen; a span
-- over a minute not used), timers and sleeps for real seconds, the
-- measure shared through _G.ccnix, and lib/net's timers on it: the
-- stack's clock, await's timeout, the hook's tick.
local PROJ = ...
package.path = PROJ .. "/lib/?.lua;" .. PROJ .. "/sim/lib/?.lua;" .. package.path
local M = require("mock")
local check = M.check

local GAME, REAL, TPS = 0, 1000000, 20          -- game seconds, real ms, ticks a real second
local TIMERS = {}                               -- the game seconds each os.startTimer asked for
local function pass(realSeconds)                -- time goes by
    GAME = GAME + realSeconds * TPS / 20
    REAL = REAL + realSeconds * 1000
end
local was = { clock = os.clock, epoch = os.epoch, startTimer = os.startTimer, sleep = sleep }
os.clock = function() return GAME end
os.epoch = function(kind) assert(kind == "utc", "realtime asks for utc"); return math.floor(REAL) end
os.startTimer = function(s) TIMERS[#TIMERS + 1] = s; return #TIMERS end
sleep = function(s) GAME = GAME + s; REAL = REAL + s * 20 / TPS * 1000 end    -- (s game seconds)

local function fresh()
    package.loaded.realtime = nil
    _G.ccnix = nil
    TIMERS = {}
    return require("realtime")
end
local function near(a, b) return math.abs(a - b) < 1e-6 end

-- 1. at 20 ticks a second
local R = fresh()
check("now: real seconds (os.epoch / 1000)", R.now() == 1000)
check("tickRate: 20 before there's a measure", R.tickRate() == 20)
check("ticks(5) at 20: 5 game seconds", R.ticks(5) == 5)
pass(3)
check("...measured after 2 real seconds: still 20, exactly", R.tickRate() == 20)
R.timer(30)
check("timer(30) at 20: a 30 s CC timer", TIMERS[#TIMERS] == 30)

-- 2. the server at 60 (/tick rate 60)
R = fresh()
TPS = 60
R.tickRate()                                    -- (the window starts)
pass(1)
check("at 60: 20 until 2 real seconds have passed", R.tickRate() == 20)
pass(1.5)
check("...then measured: 60", near(R.tickRate(), 60), R.tickRate())
check("ticks(1) at 60: 3 game seconds", near(R.ticks(1), 3))
R.timer(10)
check("timer(10) at 60: a CC timer of 30 game seconds, 10 real ones", near(TIMERS[#TIMERS], 30), TIMERS[#TIMERS])
local from = REAL
R.sleep(5)
check("sleep(5) at 60: 5 real seconds (in halves, each at the rate measured so far)", math.abs((REAL - from) / 1000 - 5) < 0.01, (REAL - from) / 1000)

-- 3. the rate changes while it runs: measured again over 10 real seconds
TPS = 20
pass(4)
check("the server back at 20: the old measure until the window is 10 real seconds", near(R.tickRate(), 60))
pass(7)
check("...then measured again: about 20 (the window spans both)", R.tickRate() < 60 and R.tickRate() >= 20, R.tickRate())
pass(11)
check("...and 20 over a window all at 20", R.tickRate() == 20, R.tickRate())

-- a sleep that starts on a stale measure waits again for what's left
TPS = 60
from = REAL
R.sleep(6)
check("sleep(6) with the measure 20 and the server at 60: waits again by what the first go took, 6 real seconds in all",
    (REAL - from) / 1000 >= 5.95 and (REAL - from) / 1000 <= 6.05, (REAL - from) / 1000)

-- (#345) the other way: the measure 60 and the server set back to 20.  A sleep by the stale measure waited three times
-- what was asked, and the next one (the window not yet 10 s) again
R = fresh()
TPS = 60
R.tickRate()
pass(3)
R.tickRate()                                    -- (measured: 60)
TPS = 20
pass(1)
from = REAL
R.sleep(3)
local first = (REAL - from) / 1000
check("sleep(3) with the measure 60 and the server back at 20: 3 real seconds, not 9", first >= 2.95 and first <= 3.05, first)
from = REAL
R.sleep(3)
check("...and the next sleep, the window not yet 10 s: 3 real seconds too (the measure it made is kept)",
    (REAL - from) / 1000 >= 2.95 and (REAL - from) / 1000 <= 3.05 and near(R.tickRate(), 20), (REAL - from) / 1000 .. " s, rate " .. R.tickRate())
-- a measure that spans the change (about 27): the field's 4.1 s for 3
R = fresh()
TPS = 60
R.tickRate()
pass(3)
R.tickRate()
pass(2)
TPS = 20
pass(8)
R.tickRate()                                    -- (a window of 10 s, 2 at 60 and 8 at 20: about 28)
from = REAL
R.sleep(3)
check("a measure spanning the change (about 28 for 20): sleep(3) is 3 real seconds, not 4.1", (REAL - from) / 1000 >= 2.95
    and (REAL - from) / 1000 <= 3.05, (REAL - from) / 1000)
REAL = math.ceil(REAL)                          -- (back on a whole millisecond, as os.epoch gives)

-- 4. a window over a minute (the computer may have been unloaded): not used
R = fresh()
TPS = 60
R.tickRate()
pass(3)
check("measured at 60", near(R.tickRate(), 60))
REAL = REAL + 120 * 1000                        -- two real minutes, the game stood still (unloaded)
check("a span over a minute isn't measured (it would say 1): the last measure kept", near(R.tickRate(), 60), R.tickRate())

-- 5. shared through _G.ccnix (boot starts the measure; each program's own
-- copy of the library uses it)
R = fresh()
TPS = 60
_G.ccnix = { ticks = { clock = GAME, epoch = REAL } }
pass(3)
local R2 = dofile(PROJ .. "/lib/realtime.lua")
check("_G.ccnix.ticks: boot's start of the measure, used by every copy", near(R.tickRate(), 60) and near(R2.tickRate(), 60)
    and near(_G.ccnix.ticks.rate, 60))

-- 6. no os.epoch (a test's world): game time, as before
R = fresh()
os.epoch = nil
TPS = 60
from = GAME
R.sleep(4)
check("no os.epoch: 20, and sleep(4) is CC's sleep(4)", R.tickRate() == 20 and near(GAME - from, 4))
os.epoch = function(kind) return math.floor(REAL) end

-- 7. lib/net on real seconds
R = fresh()
TPS = 60
R.tickRate()
pass(3)
package.loaded.net = nil
local N = require("net")
local S = N.new({ id = 1, transmit = function() end, queue = function() end })
check("the stack's clock (TCP's retransmit, keepalive, TIME_WAIT; ARP): real seconds", S.clock() == math.floor(REAL) / 1000, S.clock())
local events = { { "timer", 1 } }
local pullWas = os.pullEvent
os.pullEvent = function() return table.unpack(table.remove(events, 1)) end
os.cancelTimer = function() end
TIMERS = {}
N.await("never", nil, 5)
check("net.await(..., 5) at 60: a CC timer of 15 game seconds, 5 real ones", near(TIMERS[1], 15), TIMERS[1])
local osT = { startTimer = os.startTimer, pullEventRaw = function() return "x" end }
TIMERS = {}
N.hook(S, osT)
S.wantTick()
check("the stack's tick: every half a real second (1.5 game ones at 60)", near(TIMERS[1], 1.5), TIMERS[1])
os.pullEvent = pullWas

os.clock, os.epoch, os.startTimer, sleep = was.clock, was.epoch, was.startTimer, was.sleep
_G.ccnix = nil
