-- sysctl.lua -- show and change CraftOS's settings
--
--   sysctl [-n | -d] name[=value]...
--   sysctl [-n | -d] -a
--
-- As Linux's and the BSDs' sysctl, over CraftOS's settings (in ccsh, set
-- is the shell's own, as POSIX has it).  name shows a setting as
-- name = value; name=value changes it, and name= (nothing after the =)
-- puts it back to its default, or takes it away if it has none; either
-- way it's saved to /.settings at once and shown as it is now.  -a shows
-- every setting there is (set, or defined with a default), sorted.  -n
-- shows the values alone, for a script: x=$(sysctl -n motd.enable).  -d
-- shows each one's description (as the BSDs' -d) instead.  -w is taken
-- and ignored (a name=value is a change anyway).
--
-- A setting defined with a type takes a value of that type: true or
-- false, a number, or the text as it is.  One without is read as true,
-- false or a number when it looks like one, else as the text.  A table
-- is shown as textutils.serialise writes it, on one line.
-- Exit status: 0; 1 if a name to show doesn't exist, or a value is of
-- the wrong type; 2 for a usage error.

package.path = (ccnix and ccnix.lib or "/" .. fs.getDir(fs.getDir(shell.getRunningProgram())) .. "/lib/?.lua;") .. package.path  -- ccnix's lib/, or the one beside bin/
local cu = require("cu").init("sysctl", "sysctl [-n | -d] -a | name[=value]...")
local text = require("text")
local convert = require("convert")
local tables = require("tables")
local opts, ops = cu.getopt({ ... }, "adnw")
if opts.n and opts.d then return cu.usageError("-n or -d, not both") end
if (opts.a ~= nil) == (#ops > 0) then return cu.usageError() end

local known = {}
for _, name in ipairs(settings.getNames()) do known[name] = true end
if opts.a then ops = tables.sortedKeys(known) end

local function shown(v)
    if v == nil then return "" end
    if type(v) == "table" then return textutils.serialise(v, { compact = true }) end
    return tostring(v)
end
local function details(name)
    return settings.getDetails and settings.getDetails(name) or {}
end
local function show(name, after)
    if opts.d then
        io.write(name, ": ", details(name).description or "", "\n")
    elseif opts.n then
        io.write(shown(settings.get(name)), "\n")
    else
        local v = settings.get(name)
        io.write(name, " = ", shown(v), after or "", "\n")
    end
end

-- given, as the setting's type has it; nil if it isn't one
local function valueFor(name, given)
    local want = details(name).type
    if want == "string" then return given end
    if want == "boolean" or (want == nil and (given == "true" or given == "false")) then
        if given == "true" then return true elseif given == "false" then return false end
        return nil
    end
    if want == "number" or (want == nil and convert.toNumber(given)) then return convert.toNumber(given) end
    if want == nil then return given end
end

local changed = false
for _, op in ipairs(ops) do
    local name, given = text.cut(op, "=")      -- name ["=" value]
    if name == "" then
        cu.fail(op .. ": no name")
    elseif not given then
        if settings.get(name) == nil and not known[name] then cu.fail(name .. ": unknown key") else show(name) end
    elseif given == "" then
        settings.unset(name)
        changed = true
        if settings.get(name) == nil then io.write(name, ": not set\n") else show(name, " (its default)") end
    else
        local value = valueFor(name, given)
        if value == nil then
            cu.fail(name .. " is a " .. tostring(details(name).type) .. ": not " .. given)
        else
            settings.set(name, value)
            changed = true
            show(name)
        end
    end
end
if changed then settings.save() end
return cu.exit()
