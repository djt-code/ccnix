-- fileio.lua -- a whole file in or out, in one call
--
--   local fileio = require("fileio")
--   local conf = fileio.read("/etc/syslog.conf")       -- the text, or nil
--   local state = fileio.readJSON("/ccnix/.gitlite")   -- a table, or nil
--   fileio.write("/tmp/x", "hello\n")
--
--   fileio.read(path [, binary])   the file's contents, or nil and why
--                       (no such file, a directory, can't open it).
--                       binary: its bytes as they are ("rb")
--   fileio.write(path, data [, binary])  data as the whole file (made, or
--                       replaced); true, or nil and why
--   fileio.readJSON(path)  the file read as JSON: a table, or nil (no file,
--                       not JSON, or JSON that isn't an object or array)
--   fileio.on(fsApi)    the same three over another filesystem: one with
--                       fs's exists, isDir and open (httpd's opts.fs, the
--                       disk under lib/jbod's pool)
--
-- The plain ones go through the global fs as it is when they're called,
-- so a program that patches fs (lib/jbod) is seen through.

-- the three functions over fsOf(), the filesystem to use at each call
local function over(fsOf)
    local io_ = {}

    function io_.read(path, binary)
        local fsx = fsOf()
        if not fsx.exists(path) then return nil, path .. ": No such file" end
        if fsx.isDir(path) then return nil, path .. ": Is a directory" end
        local h, err = fsx.open(path, binary and "rb" or "r")
        if not h then return nil, err or (path .. ": can't open it") end
        local data = h.readAll() or ""
        h.close()
        return data
    end

    function io_.write(path, data, binary)
        local h, err = fsOf().open(path, binary and "wb" or "w")
        if not h then return nil, err or (path .. ": can't write it") end
        h.write(data)
        h.close()
        return true
    end

    function io_.readJSON(path)
        local data = io_.read(path)
        if not data then return nil end
        local ok, value = pcall(textutils.unserialiseJSON or textutils.unserializeJSON, data)
        if ok and type(value) == "table" then return value end
        return nil
    end

    return io_
end

local fileio = over(function() return fs end)

function fileio.on(fsApi) return over(function() return fsApi end) end

return fileio
