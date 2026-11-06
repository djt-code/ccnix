-- reset.lua -- put settings back to their defaults
--
--   reset name...
--
-- Takes each setting named out of /.settings, undoing `set name value`:
-- it reads as its default again, or as not set if it has none.  Says
-- what each one is now.  One that wasn't set is left as it is, and said
-- so.  (Not Unix's reset, which sets a terminal straight: a CraftOS
-- terminal has nothing to set straight.)  `get name` shows a setting.
-- Exit status: 0; 2 with no name.

package.path = (ccnix and ccnix.lib or "/" .. fs.getDir(fs.getDir(shell.getRunningProgram())) .. "/lib/?.lua;") .. package.path  -- ccnix's lib/, or the one beside bin/
local cu = require("cu").init("reset", "reset name...")
local _, names = cu.getopt({ ... }, "")
if #names == 0 then return cu.usageError() end

local function text(v)
    if type(v) == "table" then return textutils.serialise(v, { compact = true }) end
    return tostring(v)
end

for _, name in ipairs(names) do
    -- (getDetails' changed says whether it's set apart from its default;
    -- without it, taken as set)
    local details = settings.getDetails and settings.getDetails(name)
    local was = details == nil or details.changed ~= false
    settings.unset(name)
    local v = settings.get(name)
    local now = v == nil and "not set" or (text(v) .. " (its default)")
    io.write(name, ": ", was and now or ("was " .. now .. " already"), "\n")
end
settings.save()
return cu.exit()
