-- autorejoin.lua -- join a channel again after being kicked from it
--
--   /script load autorejoin
--   /set autorejoin_delay 3          (seconds; 0: at once)

script.name, script.version = "autorejoin", "1.0"
script.description = "join a channel again after being kicked from it"

irc.settings_add_int("autorejoin_delay", 3, "seconds before joining again after a kick")

irc.signal_add("message kick", function(server, channel, nick)
    if not server:isMe(nick) then return end
    local wait = irc.settings_get_int("autorejoin_delay") or 3
    irc.timeout_add_once(math.max(50, wait * 1000), function()
        if server.registered then server:send_raw("JOIN " .. channel) end
    end)
end)
