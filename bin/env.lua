-- env.lua -- show the environment, or run a command in a changed one
--
--   env [-i] [-u name]... [name=value]... [command [arg...]]
--
-- With no command, writes the environment, a name=value line for each
-- variable, sorted by name.  With one, runs it with the environment
-- changed for it alone: -i starts from an empty one, -u name takes name
-- out, name=value sets it.  The environment is what a program reads with
-- os.getenv(name): under ccsh, the exported variables (export, and
-- X=1 cmd; PS1 is one), PATH, PWD and HOSTNAME.  CraftOS itself has
-- none: outside ccsh env says so.
-- Exit status: the command's, 127 if it isn't found; 125 for env's own
-- errors.

package.path = (ccnix and ccnix.lib or "/" .. fs.getDir(fs.getDir(shell.getRunningProgram())) .. "/lib/?.lua;") .. package.path  -- ccnix's lib/, or the one beside bin/
local cu = require("cu").init("env", "env [-i] [-u name]... [name=value]... [command [arg...]]")
local text = require("text")
local args = { ... }
if not (os.environ and os.setenv) then
    cu.fail("no environment here: run it under ccsh", 125)
    return cu.exit()
end

local opts, operands, order = cu.getopt(args, "iu:", 125)
local drop = {}
for _, o in ipairs(order) do if o[1] == "u" then drop[#drop + 1] = o[2] end end
-- the name=value operands first (a name: not empty, before the first =)
local set, i = {}, 1
while operands[i] do
    local name, value = text.cut(operands[i], "=")
    if not value or name == "" then break end
    set[#set + 1] = { name, value }
    i = i + 1
end

-- A program shares its environment with what it runs: change it for the
-- command, then put it back.
local saved = os.environ()
local function restore()
    for k in pairs(os.environ()) do os.setenv(k, nil) end
    for k, v in pairs(saved) do os.setenv(k, v) end
end
if opts.i then for k in pairs(saved) do os.setenv(k, nil) end end
for _, n in ipairs(drop) do os.setenv(n, nil) end
for _, p in ipairs(set) do os.setenv(p[1], p[2]) end

local cmd = operands[i]
if not cmd then
    local env, names = os.environ(), {}
    for k in pairs(env) do names[#names + 1] = k end
    table.sort(names)
    for _, k in ipairs(names) do io.write(k, "=", env[k], "\n") end
    restore()
    return cu.exit()
end
if not shell.resolveProgram(cmd) then
    restore()
    cu.fail(cmd .. ": not found", 127)
    return cu.exit()
end
_G.POSIX_STATUS = nil
local ok = shell.execute(cmd, table.unpack(operands, i + 1))
local status = _G.POSIX_STATUS or 0
if not ok and status == 0 then status = 1 end
restore()
return cu.exit(status)
