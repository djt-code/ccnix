-- rm.lua -- remove files (POSIX rm)
--
--   rm [-fiRrd] file...
--
-- Removes each file.  A directory only with -r or -R (it and everything
-- in it) or -d (if it's empty); without, rm says it's a directory and
-- leaves it.  -f: no message for a file that isn't there, and no
-- questions; -i: asks before each removal (y removes); the last of -f and
-- -i given wins.  . and .. (and /) are never removed.  Status 1 if
-- anything couldn't be.  CraftOS's own rm (an alias for delete) removes
-- directories without asking; ccnix points rm here instead.

package.path = (ccnix and ccnix.lib or "/" .. fs.getDir(fs.getDir(shell.getRunningProgram())) .. "/lib/?.lua;") .. package.path  -- ccnix's lib/, or the one beside bin/
local cu = require("cu").init("rm", "rm [-fiRrd] file...")
local opts, files, order = cu.getopt({ ... }, "fiRrd")
local force, ask = false, false
for _, o in ipairs(order) do
    if o[1] == "f" then force, ask = true, false elseif o[1] == "i" then ask, force = true, false end
end
local recursive = opts.r or opts.R
if #files == 0 then
    if force then return cu.exit() end
    cu.usageError("missing operand")
end

local function yes(question)
    io.stderr:write("rm: " .. question .. "? ")
    local answer = cu.readLine(io.input()) or ""
    return answer:match("^%s*[yY]") ~= nil
end

local function remove(shown, path)
    local ok, err = pcall(fs.delete, path)
    if not ok then cu.fail(shown .. ": " .. tostring(err):gsub("^.-: ", ""), 1); return false end
    return true
end

-- path (shown as `shown`) and, for a directory with -r, what's in it
local function rm(shown, path)
    if fs.isDir(path) then
        if not recursive then
            if opts.d and #fs.list(path) == 0 then
                if not ask or yes("remove directory '" .. shown .. "'") then remove(shown, path) end
            else
                cu.fail(shown .. ": is a directory")
            end
            return
        end
        if ask then
            if #fs.list(path) > 0 and not yes("descend into directory '" .. shown .. "'") then return end
            for _, name in ipairs(fs.list(path)) do
                rm(shown .. (shown:sub(-1) == "/" and "" or "/") .. name, fs.combine(path, name))
            end
            -- (something in it was kept: it stays, unasked)
            if #fs.list(path) == 0 and yes("remove directory '" .. shown .. "'") then remove(shown, path) end
            return
        end
    elseif ask and not yes("remove '" .. shown .. "'") then
        return
    end
    remove(shown, path)
end

for _, f in ipairs(files) do
    local last = f:gsub("/+$", ""):match("([^/]*)$")
    local path = shell.resolve(f)
    if last == "." or last == ".." then
        cu.fail("refusing to remove '.' or '..' directory: skipping '" .. f .. "'")
    elseif path == "" then
        cu.fail("refusing to remove '/'")
    elseif not fs.exists(path) then
        if not force then cu.fail(f .. ": No such file or directory") end
    elseif fs.isReadOnly(path) then
        cu.fail(f .. ": Permission denied (read-only)")
    else
        rm(f, path)
    end
end
return cu.exit()
