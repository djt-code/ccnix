-- mc.lua -- the Minecraft world from a CC computer: its time, weather, players and chat
--
--   local mc = require("mc").new()      -- finds what's attached
--   mc.time()              -- "day 12, 14:05" (the world's clock, from CC itself)
--   mc.weather()           -- "clear", "rain", "thunder", or nil if it can't tell
--   mc.players()           -- { "Steve", "Alex" }, or nil if it can't tell
--   mc.say(text, from)     -- into the game's chat, as [from] text
--   mc.tell(player, text, from)   -- to one player only (nil and why if they aren't on)
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
--     chat_box ...), both of its ways of calling (0.8's options table,
--     the older arguments in a row) and both of its events' layouts
--     (0.8's UUID first, the name first before), so the version doesn't
--     matter.  What can't be sent at all is dropped, and says why.
--   * A command computer's commands API: `list` for who's on and
--     `tellraw` to speak (no hearing chat: that needs the Chat Box).
-- What isn't there is nil in mc.has, and its function returns nil and
-- why.  A chat box only speaks every so often (AP's cooldown): what's
-- said meanwhile waits, in order, and mc.flush() (call it each second)
-- sends it.  A chat message starting with $ is hidden in the game (AP's
-- rule), and isn't an event here.

local text = require("text")
local convert = require("convert")

local M = {}

local function findPeripheral(...)
    if not peripheral then return nil end
    for _, kind in ipairs({ ... }) do
        local p = peripheral.find(kind)
        if p then return p end
    end
    return nil
end

-- Call p[name] with each way of passing the arguments in turn (AP's
-- versions differ), until one is taken: "sent", or "busy" (refused for
-- now: the cooldown), or nil and why it can't be done at all.
local function call(p, name, ...)
    local f = p[name]
    if type(f) ~= "function" then return nil, "no " .. name end
    local why
    for _, args in ipairs({ ... }) do
        local ok, a, b = pcall(f, table.unpack(args))
        if ok then return a and "sent" or "busy", b end
        why = tostring(a)
    end
    return nil, why
end

-- "There are 2 of a max of 20 players online: Steve, Alex" (and the
-- older "There are 2/20 players online:") as a list of names.
local function namesFromList(out)
    local _, names = text.cut(text.join(out or {}, " "), ":")
    if not names then return {} end
    return text.split(names, ",")
end

-- Advanced Peripherals' player events (both names it has used), as the
-- kind of game event each is.
local PLAYER_EVENTS = {
    playerJoin = "join", player_join = "join",
    playerLeave = "leave", player_leave = "leave",
    playerDeath = "death", player_death = "death",
}

-- Where an event's player, text and $-hidden flag are, as AP has laid
-- them out: 0.8 puts the player's UUID first (chat: uuid, name, message,
-- hidden, the message as UTF-8 bytes; the others: uuid, name ...), older
-- versions the name (chat: name, message, uuid, hidden).
local LAYOUTS = {
    uuidFirst = { player = 2, text = 3, hidden = 4, utf8 = 5 },
    nameFirst = { player = 1, text = 2, hidden = 4 },
}
-- A UUID has dashes, and a player's name can't (letters, digits, _).
local function layoutOf(first)
    if first == nil or text.find(tostring(first), "-") then return LAYOUTS.uuidFirst end
    return LAYOUTS.nameFirst
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

    -- Speak now: "sent", "busy" (the chat box's cooldown), or nil and why.
    -- To one player: sendMessageToPlayer before AP 0.8, sendMessage with
    -- the player in its options since (never a sendMessage that could
    -- tell everyone instead).
    local function speak(item)
        local from = item.from
        if chat then
            if item.player then
                local r, why = call(chat, "sendMessageToPlayer", { item.text, item.player, { prefix = from } },
                    { item.text, item.player, from })
                if r or type(chat.sendMessageToPlayer) == "function" then return r, why end
                return call(chat, "sendMessage", { item.text, { prefix = from, player = item.player } })
            end
            return call(chat, "sendMessage", { item.text, { prefix = from } }, { item.text, from })
        end
        if commands and commands.exec then
            local json = textutils.serializeJSON({ text = (from and ("[" .. from .. "] ") or "") .. item.text })
            local ok, done = pcall(commands.exec, "tellraw " .. (item.player or "@a") .. " " .. json)
            if ok and done then return "sent" end
            return nil, "tellraw failed"
        end
        return nil, "no chat box or command computer"
    end

    -- What waits, sent in order until the chat box is busy; what can't be
    -- sent at all is dropped (item.failed says why), not left in the way.
    function self.flush()
        while queue[1] do
            local r, why = speak(queue[1])
            if r == "busy" then return false end
            local item = table.remove(queue, 1)
            if not r then item.failed = why or "it failed" end
        end
        return true
    end

    local function enqueue(item)
        if not self.has.chat then return nil, "no chat box or command computer" end
        if #queue >= 50 then table.remove(queue, 1) end   -- (a flood: the oldest goes)
        queue[#queue + 1] = item
        self.flush()
        if item.failed then return nil, item.failed end
        return true
    end
    function self.say(message, from) return enqueue({ text = message, from = from }) end
    -- (AP 0.8 sends to nobody, and says it did, for a player who isn't on:
    -- so who's on is asked first, when something here can say.)
    function self.tell(player, message, from)
        local online = self.players()
        if online then
            local found
            for _, p in ipairs(online) do if text.equalFold(p, player) then found = p end end
            if not found then return nil, player .. " isn't in the game" end
            player = found
        end
        return enqueue({ text = message, from = from, player = player })
    end
    function self.waiting() return #queue end

    -- A CC event as a game event, or nil.
    function self.event(name, ...)
        local args = { ... }
        local at = layoutOf(args[1])
        if name == "chat" then
            if not chat or args[at.hidden] == true then return nil end          -- ($: hidden)
            local said = args[at.text]
            if at.utf8 and type(args[at.utf8]) == "string" then said = convert.fromUTF8(args[at.utf8]) end
            return { kind = "chat", player = args[at.player], text = said }
        end
        local kind = PLAYER_EVENTS[name]
        return kind and { kind = kind, player = args[at.player] } or nil
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
