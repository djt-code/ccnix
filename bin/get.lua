-- get.lua -- show settings (CraftOS's set changes them)
--
--   get [-n] [name...]
--
-- Writes a "name = value" line for each setting named, or with none
-- named for every one there is (set, or defined with a default), sorted
-- by name, as sysctl writes them.  -n writes the values alone, a line
-- each, for a script: x=$(get -n motd.enable).  A string is written as
-- it is, a table as textutils.serialise writes it on one line, a setting
-- with no value as nothing.  A name that is neither set nor defined is
-- an error; the others are still written.  `set name value` changes a
-- setting, `reset name` puts it back to its default.
-- Exit status: 0; 1 if a name wasn't found; 2 for a usage error.

package.path = (ccnix and ccnix.lib or "/" .. fs.getDir(fs.getDir(shell.getRunningProgram())) .. "/lib/?.lua;") .. package.path  -- ccnix's lib/, or the one beside bin/
local cu = require("cu").init("get", "get [-n] [name...]")
local opts, names = cu.getopt({ ... }, "n")

local known = {}
for _, name in ipairs(settings.getNames()) do known[name] = true end
if #names == 0 then
    for name in pairs(known) do names[#names + 1] = name end
    table.sort(names)
end

local function text(v)
    if v == nil then return "" end
    if type(v) == "table" then return textutils.serialise(v, { compact = true }) end
    return tostring(v)
end

for _, name in ipairs(names) do
    local v = settings.get(name)
    if v == nil and not known[name] then
        cu.fail(name .. ": no such setting")
    elseif opts.n then
        io.write(text(v), "\n")
    else
        io.write(name, " = ", text(v), "\n")
    end
end
return cu.exit()
