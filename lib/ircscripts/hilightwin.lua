-- hilightwin.lua -- every hilight and private message, gathered in a buffer of their own
--
--   /script load hilightwin          (a "hilight" buffer opens)
--
-- irssi's classic: lines with your nick (or hilight_words) and private
-- messages are copied into the hilight buffer, each with where it came
-- from, so nothing's missed in a busy channel.

script.name, script.version = "hilightwin", "1.0"
script.description = "hilights and private messages, copied into a hilight buffer"

local hl

local function window()
    if not hl or not irc.buffer_find("hilight") then hl = irc.buffer_new("hilight") end
    return hl
end

irc.signal_add("print text", function(buffer, line)
    if buffer == hl or not (line.hilight or line.level == "private") then return end
    window():print(line.text, { prefix = buffer.name .. " " .. line.prefix, prefixColour = line.prefixColour,
        level = "public", time = line.time })
end)

window()

function unload()
    if hl then hl.client:closeBuffer(hl) end
end
