-- dirname.lua -- the directory part of a path name (POSIX dirname)
--
--   dirname string
--
-- Strips trailing slashes, the last part, then the slashes before it.
-- A name with no slash gives ".", one directly under the root (or only
-- slashes) gives "/".  The string is not looked up on disk.

package.path = (ccnix and ccnix.lib or "/" .. fs.getDir(fs.getDir(shell.getRunningProgram())) .. "/lib/?.lua;") .. package.path  -- ccnix's lib/, or the one beside bin/
local cu = require("cu").init("dirname", "dirname string")
local path = require("path")
local _, ops = cu.getopt({ ... }, "")
if #ops ~= 1 then cu.usageError(#ops < 1 and "missing operand" or "extra operand") end

io.write(path.dirname(ops[1]), "\n")
return cu.exit()
