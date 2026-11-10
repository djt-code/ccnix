-- mkdir.lua -- make directories (POSIX mkdir)
--
--   mkdir [-p] [-m mode] dir...
--
-- Makes each directory, whose parent must be there already, and which
-- mustn't be.  -p makes the parents too, as needed, and says nothing of
-- one that's there already.  -m is taken and ignored: CraftOS has no
-- permissions.  Status 1 if any couldn't be made.  (CraftOS's mkdir makes
-- the parents always and takes no options: `mkdir -p a` makes a folder
-- called -p.)

package.path = (ccnix and ccnix.lib or "/" .. fs.getDir(fs.getDir(shell.getRunningProgram())) .. "/lib/?.lua;") .. package.path  -- ccnix's lib/, or the one beside bin/
local cu = require("cu").init("mkdir", "mkdir [-p] [-m mode] dir...")
local opts, dirs = cu.getopt({ ... }, "pm:")
if #dirs == 0 then cu.usageError("missing operand") end

for _, shown in ipairs(dirs) do
    local path = shell.resolve(shown)
    local parent = fs.getDir(path)
    if fs.isDir(path) and path ~= "" then
        if not opts.p then cu.fail(shown .. ": File exists") end
    elseif fs.exists(path) or path == "" then
        cu.fail(shown .. ": File exists")
    elseif not opts.p and parent ~= "" and parent ~= ".." and not fs.isDir(parent) then
        cu.fail(shown .. ": No such file or directory")
    else
        -- (with -p: a file on the way is in the way)
        local up, blocked = parent, nil
        while up ~= "" and up ~= ".." and not blocked do
            if fs.exists(up) and not fs.isDir(up) then blocked = up end
            up = fs.getDir(up)
        end
        if blocked then cu.fail(shown .. ": Not a directory")
        elseif fs.isReadOnly(path) then cu.fail(shown .. ": Permission denied")
        else
            local ok, err = pcall(fs.makeDir, path)
            if not ok then cu.fail(shown .. ": " .. cu.reason(err)) end
        end
    end
end
return cu.exit()
