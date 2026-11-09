-- mc.lua -- the Minecraft world from a CC computer: its time, weather, players and chat
--
--   local mc = require("mc").new()      -- finds what's attached
--   mc.time()              -- "day 12, 14:05" (the world's clock, from CC itself)
--   mc.weather()           -- "clear", "rain", "thunder", or nil if it can't tell
--   mc.players()           -- { "Steve", "Alex" }, or nil if it can't tell
--   mc.say(text, from)     -- into the game's chat, as [from] text
--   mc.tell(player, text, from)   -- to one player only
--   local e = mc.event(table.unpack(ev))   -- a CC event, as what happened in the game:
--     { kind = "chat", player = "Steve", text = "hi" } | { kind = "join", player = ... }
--     | { kind = "leave", player = ... } | { kind = "death", player = ... } | nil
--   mc.poll()              -- joins and leaves noticed by asking who's on (no detector)
--   mc.flush()             -- send what's waiting for the chat box's cooldown
--   mc.has                 -- { chat = "chat box" | "commands" | nil, players = ..., weather = ... }
--
-- What it uses, the first of each that's there:
--   * CC itself: os.time("ingame") and os.day("ingame"), the world's clock.
--   * Advanced Peripherals, attached or on the wired network: a Chat Box
--     (says, tells, hears chat: its "chat" event), a Player Detector (who's
--     on; its join and leave events), an Environment Detector (rain and
--     thunder).  Both names AP has used are looked for (chatBox and
--     chat_box ...), and both of its ways of calling (an options table,
--     and the older arguments in a row), so the version doesn't matter.
--   * A command computer's commands API: `list` for who's on and
--     `tellraw` to speak (no hearing chat: that needs the Chat Box).
-- What isn't there is nil in mc.has, and its function returns nil and
-- why.  A chat box only speaks every so often (AP's cooldown): what's
-- said meanwhile waits, in order, and mc.flush() (call it each second)
-- sends it.  A chat message starting with $ is hidden in the game (AP's
-- rule), and isn't an event here.

local M = {}

local function findPeripheral(...)
    if not peripheral then return nil end
    for _, kind in ipairs({ ... }) do
        local p = peripheral.find(kind)
        if p then return p end
    end
    return nil
end

-- Call p[name] with an options table, else with the older arguments
-- (positional); the result, or nil and why.
local function callEither(p, name, withOptions, positional)
    local f = p[name]
    if type(f) ~= "function" then return nil, "no " .. name end
    local ok, a, b = pcall(f, table.unpack(withOptions))
    if ok then return a, b end                  -- (it took them: a cooldown's false is an answer too)
    local ok2, c, d = pcall(f, table.unpack(positional))
    if ok2 then return c, d end
    return nil, tostring(c)
end

-- "There are 2 of a max of 20 players online: Steve, Alex" (and the
-- older "There are 2/20 players online:") as a list of names.
local function namesFromList(out)
    local text = table.concat(out or {}, " ")
    local colon = text:find(":", 1, true)
    local names = {}
    if not colon then return names end
    for name in text:sub(colon + 1):gmatch("[^,%s]+") do names[#names + 1] = name end
    return names
end

function M.new(opts)
    opts = opts or {}
    local self = { has = {} }
    local chat = opts.chatBox or findPeripheral("chat_box", "chatBox")
    local detector = opts.playerDetector or findPeripheral("player_detector", "playerDetector")
    local env = opts.environmentDetector or findPeripheral("environment_detector", "environmentDetector")
    local commands = opts.commands or rawget(_G, "commands")
    local osT = opts.os or os
    self.has.chat = (chat and "chat box") or (commands and "commands") or nil
    self.has.hears = chat and true or nil
    self.has.players = (detector and "player detector") or (commands and "commands") or nil
    self.has.weather = env and "environment detector" or nil
    local queue = {}
    local known                             -- who was on when last asked (for poll)

    function self.clock() return osT.time("ingame") end
    function self.day() return osT.day("ingame") end
    function self.time()
        local t = self.clock()
        local h = math.floor(t)
        local m = math.floor((t - h) * 60)
        return string.format("day %d, %02d:%02d", self.day(), h, m)
    end

    function self.weather()
        if not env then return nil, "no environment detector" end
        local okT, thunder = pcall(env.isThunder)
        if okT and thunder then return "thunder" end
        local okR, rain = pcall(env.isRaining)
        if okR and rain then return "rain" end
        if okR then return "clear" end
        return nil, "the detector didn't say"
    end

    function self.players()
        if detector and detector.getOnlinePlayers then
            local ok, list = pcall(detector.getOnlinePlayers)
            if ok and type(list) == "table" then return list end
        end
        if commands and commands.exec then
            local ok, done, out = pcall(commands.exec, "list")
            if ok and done then return namesFromList(out) end
        end
        return nil, "nothing here can tell who's on"
    end

    -- Speak now (the chat box may refuse: its cooldown); true, or nil and why.
    local function speak(item)
        local from = item.from
        if chat then
            if item.player then
                return callEither(chat, "sendMessageToPlayer", { item.text, item.player, { prefix = from } },
                    { item.text, item.player, from })
            end
            return callEither(chat, "sendMessage", { item.text, { prefix = from } }, { item.text, from })
        end
        if commands and commands.exec then
            local json = textutils.serializeJSON({ text = (from and ("[" .. from .. "] ") or "") .. item.text })
            local ok, done = pcall(commands.exec, "tellraw " .. (item.player or "@a") .. " " .. json)
            if ok and done then return true end
            return nil, "tellraw failed"
        end
        return nil, "no chat box or command computer"
    end

    function self.flush()
        while queue[1] do
            local ok = speak(queue[1])
            if not ok then return false end
            table.remove(queue, 1)
        end
        return true
    end

    local function enqueue(item)
        if not self.has.chat then return nil, "no chat box or command computer" end
        if #queue >= 50 then table.remove(queue, 1) end   -- (a flood: the oldest goes)
        queue[#queue + 1] = item
        self.flush()
        return true
    end
    function self.say(text, from) return enqueue({ text = text, from = from }) end
    function self.tell(player, text, from) return enqueue({ text = text, from = from, player = player }) end
    function self.waiting() return #queue end

    -- A CC event as a game event, or nil.
    function self.event(name, a, b, _, d)
        if name == "chat" and chat then
            if d == true then return nil end                      -- ($: hidden)
            return { kind = "chat", player = a, text = b }
        elseif name == "playerJoin" or name == "player_join" then
            return { kind = "join", player = a }
        elseif name == "playerLeave" or name == "player_leave" then
            return { kind = "leave", player = a }
        elseif name == "playerDeath" or name == "player_death" then
            return { kind = "death", player = a }
        end
        return nil
    end

    -- Without a detector's events: who came and went since the last ask.
    function self.poll()
        if detector then return {} end                         -- (its events say)
        local now = self.players()
        if not now then return {} end
        local events, set = {}, {}
        for _, p in ipairs(now) do set[p] = true end
        if known then
            for _, p in ipairs(now) do
                if not known[p] then events[#events + 1] = { kind = "join", player = p } end
            end
            for p in pairs(known) do
                if not set[p] then events[#events + 1] = { kind = "leave", player = p } end
            end
            table.sort(events, function(x, y) return x.player < y.player end)
        end
        known = set
        return events
    end

    return self
end

return M
