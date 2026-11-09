-- dirname.lua -- the directory part of a path name (POSIX dirname)
--
--   dirname string
--
-- Strips trailing slashes, the last part, then the slashes before it.
-- A name with no slash gives ".", one directly under the root (or only
-- slashes) gives "/".  The string is not looked up on disk.

package.path = (ccnix and ccnix.lib or "/" .. fs.getDir(fs.getDir(shell.getRunningProgram())) .. "/lib/?.lua;") .. package.path  -- ccnix's lib/, or the one beside bin/
local cu = require("cu").init("dirname", "dirname string")
local scan = require("scan")
local _, ops = cu.getopt({ ... }, "")
if #ops ~= 1 then cu.usageError(#ops < 1 and "missing operand" or "extra operand") end

local isSlash = scan.oneOf("/")

-- s without the slashes at its end
local function stripSlashes(s)
    local to = #s
    while to > 0 and s:sub(to, to) == "/" do to = to - 1 end
    return s:sub(1, to)
end

local s = ops[1]
if s ~= "" and scan.all(s, isSlash) then
    s = "/"
else
    s = stripSlashes(s)
    if not s:find("/", 1, true) then
        s = "."
    else
        local parent = scan.cutLast(s, "/")     -- (the last part dropped)
        s = stripSlashes(parent)
        if s == "" then s = "/" end
    end
end
io.write(s, "\n")
return cu.exit()
