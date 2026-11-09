-- autoaway.lua -- marked away after a while without typing, back at the next line
--
--   /script load autoaway
--   /set autoaway_minutes 10         (0: never)
--   /set autoaway_message idle

script.name, script.version = "autoaway", "1.0"
script.description = "away after autoaway_minutes without typing; back when you type"

irc.settings_add_int("autoaway_minutes", 10, "minutes without typing before you're marked away (0: never)")
irc.settings_add_str("autoaway_message", "idle", "the away message autoaway sets")

local last, auto = os.clock(), false

local function typed()
    last = os.clock()
    if auto then
        auto = false
        irc.command("/back")
    end
end

irc.signal_add("send text", typed)
irc.signal_add("send command", function(line)
    local cmd = (irc.words(line:lower())[1] or ""):sub(2)
    if cmd ~= "away" and cmd ~= "back" then typed() end
end)

irc.timeout_add(30000, function()
    local minutes = irc.settings_get_int("autoaway_minutes") or 0
    if minutes > 0 and not auto and os.clock() - last > minutes * 60 then
        auto = true
        irc.command("/away " .. irc.settings_get_str("autoaway_message"))
    end
end)
