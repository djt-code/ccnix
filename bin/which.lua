-- which.lua -- show which program a command name runs (not in POSIX)
--
--   which [-a] name...
--
-- Writes the absolute path of the program the shell would run for each
-- name, finding it the way the shell does: an alias first, then a name
-- with a "/" relative to the current directory, otherwise each directory
-- of the shell's path in turn, trying name and name.lua.
-- -a lists every match: the alias's program, then each one on the path.
-- A name with no program is reported, and which exits 1.

package.path = (ccnix and ccnix.lib or "/" .. fs.getDir(fs.getDir(shell.getRunningProgram())) .. "/lib/?.lua;") .. package.path  -- ccnix's lib/, or the one beside bin/
local cu = require("cu").init("which", "which [-a] name...")
local text = require("text")
local opts, names = cu.getopt({ ... }, "a")
if #names == 0 then cu.usageError("missing operand") end

-- p or p.lua, if either is a file
local function file(p)
    if fs.exists(p) and not fs.isDir(p) then return p end
    if fs.exists(p .. ".lua") and not fs.isDir(p .. ".lua") then return p .. ".lua" end
end

for _, name in ipairs(names) do
    local found, seen = {}, {}
    local function add(p)
        if p and not seen[p] then seen[p] = true; found[#found + 1] = p end
    end
    -- first, exactly what the shell would run (an alias wins even when
    -- its program is missing)
    add(shell.resolveProgram(name))
    if opts.a then
        if text.contains(name, "/") or text.contains(name, "\\") then
            add(file(shell.resolve(name)))
        else
            for _, dir in ipairs(text.split(shell.path(), ":", true)) do
                if dir ~= "" then add(file(fs.combine(shell.resolve(dir), name))) end
            end
        end
    end
    if #found == 0 then cu.fail(name .. ": not found") end
    for _, p in ipairs(found) do io.write("/" .. p .. "\n") end
end
return cu.exit()
