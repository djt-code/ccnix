-- tables.lua -- the few things done to Lua tables everywhere
--
--   local tables = require("tables")
--   for _, name in ipairs(tables.sortedKeys(settings)) do ... end
--   local mine = tables.copy(defaults)
--
--   tables.sortedKeys(t [, less])  t's keys as a sorted list: by less(a, b)
--                       if given, else numbers as numbers and strings as
--                       strings (numbers first when they're mixed); the
--                       same order every run, where pairs' isn't
--   tables.copy(t)      a shallow copy: a new table with t's keys and
--                       values (tables inside are shared, not copied)

local tables = {}

-- numbers by value, then strings, then anything else by its tostring
local KIND_ORDER = { number = 1, string = 2 }
local function natural(a, b)
    local ka, kb = KIND_ORDER[type(a)] or 3, KIND_ORDER[type(b)] or 3
    if ka ~= kb then return ka < kb end
    if ka == 3 then return tostring(a) < tostring(b) end
    return a < b
end

function tables.sortedKeys(t, less)
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys, less or natural)
    return keys
end

function tables.copy(t)
    local out = {}
    for k, v in pairs(t) do out[k] = v end
    return out
end

return tables
