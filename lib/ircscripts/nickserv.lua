-- nickserv.lua -- identify to NickServ when it asks
--
--   /script load nickserv
--   /set network.<name>.nickserv_pass <password>
--
-- When NickServ says your nick is registered (and asks you to
-- IDENTIFY), this answers with the password set for that network, once
-- a connection.  bin/ircd's NickServ asks so; so do Anope's and Atheme's.

script.name, script.version = "nickserv", "1.0"
script.description = "IDENTIFY to NickServ when it asks, with network.<name>.nickserv_pass"

local done = {}

irc.signal_add("server connected", function(server) done[server] = nil end)

irc.signal_add("message irc notice", function(server, body, nick)
    if server:fold(nick) ~= server:fold("NickServ") or done[server] then return end
    local plain = irc.strip(body):lower()
    if not (irc.contains(plain, "registered") and irc.contains(plain, "identify")) then return end
    local pass = irc.settings_get_str("network." .. server.name .. ".nickserv_pass")
    if not pass or pass == "" then return end
    done[server] = true
    server:send_raw("PRIVMSG NickServ :IDENTIFY " .. pass)
    server.buffer:print("Identifying to NickServ", { prefix = "--", prefixColour = 12 })
end)
