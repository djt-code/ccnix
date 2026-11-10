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
--
-- Each goes through the fs that's there when it's called, so a program
-- that patches fs (lib/jbod) is seen through; one that needs the disk
-- underneath keeps its own handle on it.

local fileio = {}

function fileio.read(path, binary)
    if not fs.exists(path) then return nil, path .. ": No such file" end
    if fs.isDir(path) then return nil, path .. ": Is a directory" end
    local h, err = fs.open(path, binary and "rb" or "r")
    if not h then return nil, err or (path .. ": can't open it") end
    local data = h.readAll() or ""
    h.close()
    return data
end

function fileio.write(path, data, binary)
    local h, err = fs.open(path, binary and "wb" or "w")
    if not h then return nil, err or (path .. ": can't write it") end
    h.write(data)
    h.close()
    return true
end

local unjson = textutils.unserialiseJSON or textutils.unserializeJSON

function fileio.readJSON(path)
    local data = fileio.read(path)
    if not data then return nil end
    local ok, value = pcall(unjson, data)
    if ok and type(value) == "table" then return value end
    return nil
end

return fileio
