-- slap.lua -- /slap <nick>: the old mIRC trout
--
--   /script load slap
--   /slap bob                        * you slap bob around a bit with a large trout
--   /set slap_with a wet noodle

script.name, script.version = "slap", "1.0"
script.description = "/slap <nick>, as mIRC and BitchX had it"

irc.settings_add_str("slap_with", "a large trout", "what /slap slaps with")

irc.command_bind("slap", function(args, server, buffer)
    local nick = irc.words(args)[1]
    if not nick then return buffer:print("/slap <nick>") end
    irc.command("/me slaps " .. nick .. " around a bit with " .. irc.settings_get_str("slap_with"), buffer)
end, "slap someone around a bit", "<nick>")
