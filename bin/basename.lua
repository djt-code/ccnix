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
local scan = require("scan")
local text = require("text")
local _, ops = cu.getopt({ ... }, "")
if #ops < 1 or #ops > 2 then cu.usageError(#ops < 1 and "missing operand" or "extra operand") end

local isSlash = scan.oneOf("/")

-- s without the slashes at its end
local function stripSlashes(s)
    local to = #s
    while to > 0 and s:sub(to, to) == "/" do to = to - 1 end
    return s:sub(1, to)
end

local s, suffix = ops[1], ops[2]
if s ~= "" and scan.all(s, isSlash) then
    s = "/"
else
    local _, last = text.cutLast(stripSlashes(s), "/")
    s = last or stripSlashes(s)
    if suffix and suffix ~= "" and suffix ~= s and s:sub(-#suffix) == suffix then
        s = s:sub(1, #s - #suffix)
    end
end
io.write(s, "\n")
return cu.exit()
