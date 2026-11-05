-- rmdir.lua -- remove empty directories (POSIX rmdir)
--
--   rmdir [-p] dir...
--
-- Removes each directory, which must be empty (rm -r removes one that
-- isn't).  -p also removes each directory named in the path above it, as
-- far as they've become empty: rmdir -p a/b/c removes c, then b, then a.
-- Status 1 if any couldn't be removed.

package.path = (ccnix and ccnix.lib or "/" .. fs.getDir(fs.getDir(shell.getRunningProgram())) .. "/lib/?.lua;") .. package.path  -- ccnix's lib/, or the one beside bin/
local cu = require("cu").init("rmdir", "rmdir [-p] dir...")
local opts, dirs = cu.getopt({ ... }, "p")
if #dirs == 0 then cu.usageError("missing operand") end

-- remove one directory; true if it went
local function rmdir(shown)
    local path = shell.resolve(shown)
    if not fs.exists(path) then cu.fail(shown .. ": No such file or directory"); return false end
    if not fs.isDir(path) then cu.fail(shown .. ": Not a directory"); return false end
    if path == "" or fs.isReadOnly(path) then cu.fail(shown .. ": Permission denied"); return false end
    if #fs.list(path) > 0 then cu.fail(shown .. ": Directory not empty"); return false end
    local ok, err = pcall(fs.delete, path)
    if not ok then cu.fail(shown .. ": " .. tostring(err)); return false end
    return true
end

for _, d in ipairs(dirs) do
    d = d:gsub("(.)/+$", "%1")
    if rmdir(d) and opts.p then
        local up = d:match("^(.+)/[^/]+$")
        while up and up ~= "" and up ~= "." and up ~= ".." and rmdir(up) do
            up = up:match("^(.+)/[^/]+$")
        end
    end
end
return cu.exit()
