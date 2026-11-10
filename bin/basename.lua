-- basename.lua -- the last part of a path name (POSIX basename)
--
--   basename string [suffix]
--
-- Strips trailing slashes and everything up to the last remaining slash,
-- then the suffix, if one is given and it is not the whole of what is
-- left.  A string of only slashes gives "/", an empty string an empty
-- line.  Only "/" separates: the string is not looked up on disk.

package.path = (ccnix and ccnix.lib or "/" .. fs.getDir(fs.getDir(shell.getRunningProgram())) .. "/lib/?.lua;") .. package.path  -- ccnix's lib/, or the one beside bin/
local cu = require("cu").init("basename", "basename string [suffix]")
local path = require("path")
local _, ops = cu.getopt({ ... }, "")
if #ops < 1 or #ops > 2 then cu.usageError(#ops < 1 and "missing operand" or "extra operand") end

io.write(path.basename(ops[1], ops[2]), "\n")
return cu.exit()
