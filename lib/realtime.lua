-- realtime.lua -- seconds as the clock on the wall counts them
--
--   local realtime = require("realtime")
--   realtime.now()            --> 1763400000.25 (real seconds, UTC)
--   local id = realtime.timer(30)   -- a "timer" event in 30 real seconds
--   realtime.sleep(5)         -- 5 real seconds
--   realtime.tickRate()       --> 20 (game ticks a real second)
--
-- CraftOS counts time in game ticks: os.clock() is ticks / 20, and
-- os.startTimer(s) and sleep(s) wait s * 20 ticks.  At 20 ticks a second
-- that's real time; a server running `/tick rate 60` (or lagging at 10)
-- makes them run 3x fast (or 2x slow).  Game time is right for what the
-- game does (a crop growing, a furnace, the day), and wrong for what
-- counts the clock on the wall: a protocol timer whose other end is
-- outside the game, a timeout a person is waiting on, an API's retry.
-- Those use this.
--
--   realtime.now()        real seconds (os.epoch("utc") / 1000)
--   realtime.tickRate()   game ticks a real second, measured: game time
--                         (os.clock) against real time (os.epoch("utc"))
--                         over the last 10 real seconds or more (the
--                         first over 2), 20 until there's a measure.  The
--                         server's tick rate can change while it runs, so
--                         it's measured again each 10 s or more apart it's
--                         asked for; a span over a minute (the computer
--                         may have been unloaded) starts a new one.
--   realtime.ticks(s)     the game seconds that last s real ones now
--                         (what to give os.startTimer for s real seconds)
--   realtime.timer(s)     os.startTimer for s real seconds: its id
--   realtime.sleep(s)     wait s real seconds (events in between are lost,
--                         as with sleep): over a second, in halves, each
--                         at the rate measured so far (the first at 20 at
--                         most), so a measure gone stale (the tick rate
--                         changed) can't make it long;
--                         a rate it measured that differs from the kept
--                         one replaces it
--
-- The measure is kept in _G.ccnix (boot starts it), so every program on a
-- computer shares it; without ccnix each program measures for itself.

local R = {}

local NORMAL = 20            -- ticks a second, Minecraft's own
local WINDOW = 10            -- real seconds a measure spans, at least
local FIRST = 2              -- (the first: until then it's 20)
local STALE = 60             -- real seconds past which a window isn't used
local LOWEST, HIGHEST = 1, 10000

-- real milliseconds (game ones where there's no os.epoch: not in CC, but
-- in a test that leaves it out)
local function epoch() return os.epoch and os.epoch("utc") or os.clock() * 1000 end

function R.now() return epoch() / 1000 end

-- where the measure is kept: { clock, epoch (ms), rate }
local own
local function state()
    local c = rawget(_G, "ccnix")
    if type(c) == "table" then
        if type(c.ticks) ~= "table" then c.ticks = { clock = os.clock(), epoch = epoch() } end
        return c.ticks
    end
    own = own or { clock = os.clock(), epoch = epoch() }
    return own
end

function R.tickRate()
    if not os.epoch then return NORMAL end
    local s = state()
    local clock, ms = os.clock(), epoch()
    local real = (ms - s.epoch) / 1000
    if real >= (s.rate and WINDOW or FIRST) then
        local game = clock - s.clock
        -- (a window much longer than asked for may span a time the
        -- computer wasn't running, its chunk unloaded: it starts again)
        if game > 0 and real <= STALE then
            local rate = NORMAL * game / real
            if math.abs(rate - NORMAL) < NORMAL * 0.02 then rate = NORMAL end   -- (20, give or take a tick's rounding)
            s.rate = math.max(LOWEST, math.min(HIGHEST, rate))
        end
        s.clock, s.epoch = clock, ms
    end
    return s.rate or NORMAL
end

function R.ticks(s)
    local rate = R.tickRate()
    if rate == NORMAL then return s end
    return s * rate / NORMAL
end

function R.timer(s) return os.startTimer(R.ticks(math.max(s, 0))) end

function R.sleep(s)
    if not os.epoch then return sleep(s) end          -- (no real clock to check)
    local start, clock = R.now(), os.clock()
    local done, rate = start + s, R.tickRate()       -- (s as it is at 20: sleep(2) is sleep(2))
    -- (#345: a measure gone stale, the server's tick rate changed since, made a sleep long, and a long go can't be
    -- taken back.  Over a second it goes in halves, each at the rate measured since the sleep began; the first at no
    -- more than 20, since a kept rate over the real one is what makes a sleep long.  A go that comes up short is made
    -- up by the next.  A test's clock may not move.)
    local measured = false
    local first = math.min(rate, NORMAL)
    for _ = 1, 16 do
        local left = done - R.now()
        if left <= 0.05 then break end
        local before = R.now()
        sleep((left > 1 and left / 2 or left) * (measured and rate or first) / NORMAL)
        local after = R.now()
        if after == before then return end
        local game, real = os.clock() - clock, after - start
        if game > 0 and real > 0 then rate, measured = NORMAL * game / real, true end
    end
    -- (a measure that differs from the kept one by over 2% replaces it, so the next sleep or timer doesn't wait by the
    -- stale one until its window closes)
    local kept = state()
    if measured and R.now() - start >= 1 and math.abs(rate - (kept.rate or NORMAL)) > (kept.rate or NORMAL) * 0.02 then
        if math.abs(rate - NORMAL) < NORMAL * 0.02 then rate = NORMAL end
        kept.rate = math.max(LOWEST, math.min(HIGHEST, rate))
        kept.clock, kept.epoch = os.clock(), epoch()
    end
end

return R
