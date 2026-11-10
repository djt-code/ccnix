-- jbod.lua -- disks in many disk drives as one folder ("just a bunch of
-- disks")
--
--   local jbod = require("jbod")
--   local pool = jbod.install(fs, { mount = "jbod", drives = jbod.drives })
--
-- install() changes the fs table it's given in place (CraftOS's fs, which
-- io, loadfile, shell completion and every program go through), so a path
-- under /<mount> reaches the pool and every other path the disk it always
-- did.  The pool is the disks its members hold, put together:
--
--  * Members: every disk in an attached drive (beside the computer, or
--    over wired modems) with a .jbod file at its root.  A blank disk is
--    made a member when it turns up (opts.label names each member);
--    one with files on it is left alone until add() makes it one, files
--    and all.  The drives are looked for again at most once a second, so
--    the pool grows as drives and disks are added, with nothing to run.
--  * Folders are the union of the members' folders: a folder is in the
--    pool if it's on any member, and lists what's in it on all of them.
--  * A file is on one member, the one with the most room when it was
--    written, or, too big for any one, split across several: the first
--    part at its path on one member, the rest in .jbod.parts/ on the
--    others (and beside the first, an empty file there that says how many
--    parts there are, so a missing last one is missed).  A file is written when it's closed (until then it's held in
--    memory), so it goes where it fits as a whole.
--  * Free space and capacity are the members' added up.  CC charges any
--    file or folder at least 500 bytes, so many small files take more.
--
-- A member taken out takes its files with it (a split file it held part
-- of can't be read until it's back); its disk is still an ordinary disk
-- with ordinary files (and parts) on it.  Files written straight onto a
-- member's own mount (/disk2/...) are in the pool too.

local scan = require("scan")
local text = require("text")
local glob = require("glob")
local path = require("path")

local J = {}

local MARK = ".jbod"              -- at each member's root
local PARTS = ".jbod.parts"       -- split files' later parts, on any member
local MIN = 500                   -- what CC charges a file or folder at least
local SLACK = 2 * MIN             -- kept free on a member when splitting

-- The drives attached that hold a disk with files on it (a floppy, not a
-- music disc): { name = peripheral name, root = mount path }.
function J.drives()
    local out = {}
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "drive" and disk.hasData(name) then
            local root = disk.getMountPath(name)
            if root then out[#out + 1] = { name = name, root = root } end
        end
    end
    return out
end

-- A split file's part n of `of` is named for its path ("!" -> "!!", "/" ->
-- "!s") and the two numbers: "notes!sbig.txt.2-3".
local function escaped(rel) return (text.replace((text.replace(rel, "!", "!!")), "/", "!s")) end
local function partName(rel, n, of) return escaped(rel) .. "." .. n .. "-" .. of end
-- digits, one at least (the numbers in a part's name)

-- A pool over the drives `opts.drives()` gives, using `base` (the real fs
-- functions) for its members' files.  opts.clock: seconds now (os.clock);
-- opts.label(name): label member `name`'s disk (each time the drives
-- are looked at, so a label can follow a disk that's moved).
function J.new(base, opts)
    opts = opts or {}
    local P = { mount = opts.mount or "jbod" }
    local clock = opts.clock or os.clock
    local members, others, seen = {}, {}, nil

    local function real(m, rel) return base.combine(m.root, rel) end
    local function full(rel) return "/" .. base.combine(P.mount, rel) end
    local function hiddenTop(name) return name == MARK or name == PARTS end
    local function marked(root) return base.exists(base.combine(root, MARK)) end

    local function adopt(d)
        local h = base.open(base.combine(d.root, MARK), "w")
        if not h then return false end
        h.write("ccnix jbod member\n")
        h.close()
        return true
    end

    -- The members now (looked for again at most once a second, or `force`).
    function P.members(force)
        local t = clock()
        if force or not seen or t - seen >= 1 or t < seen then
            seen = t
            members, others = {}, {}
            for _, d in ipairs(opts.drives()) do
                if marked(d.root) then members[#members + 1] = d
                elseif #base.list(d.root) == 0 and adopt(d) then members[#members + 1] = d
                else others[#others + 1] = d end
            end
            table.sort(members, function(a, b) return a.root < b.root end)
            table.sort(others, function(a, b) return a.root < b.root end)
            if opts.label then
                for _, m in ipairs(members) do pcall(opts.label, m.name) end
            end
        end
        return members
    end
    -- Drives with a disk that has files on it and isn't a member.
    function P.others() P.members(); return others end

    -- Is `path` a member's own mount (/disk, /disk2...)?  ls and ccsh
    -- treat those as hidden, like a name starting with a dot: their files
    -- are in the pool.
    function P.isMember(path)
        if type(path) ~= "string" then return false end
        path = base.combine(path)
        for _, m in ipairs(P.members()) do
            if base.combine(m.root) == path then return true end
        end
        return false
    end

    -- Make the disk in drive `name` a member, its files and all.
    function P.add(name)
        for _, d in ipairs(opts.drives()) do
            if d.name == name then
                if marked(d.root) then return true, "already a member" end
                for _, n in ipairs(base.list(d.root)) do
                    if hiddenTop(n) then return false, "it has a " .. n .. " already" end
                end
                if not adopt(d) then return false, "can't write to it" end
                P.members(true)
                return true
            end
        end
        return false, "no disk in a drive called " .. name
    end

    ----------------------------------------------------------------------
    -- Finding things
    ----------------------------------------------------------------------
    -- Paths are relative to the pool's root ("" is the root).  Nothing
    -- starting .jbod at the root is part of it.
    local function hidden(rel)
        local top = text.cut(rel, "/")                 -- its first folder (or name)
        return top ~= "" and hiddenTop(top)
    end

    -- The member holding the file at rel (its first part), or nil.
    local function holder(rel)
        if rel == "" or hidden(rel) then return nil end
        for _, m in ipairs(P.members()) do
            local p = real(m, rel)
            if base.exists(p) and not base.isDir(p) then return m end
        end
    end

    local function isDir(rel)
        if rel == "" then return true end
        if hidden(rel) then return false end
        for _, m in ipairs(P.members()) do
            if base.isDir(real(m, rel)) then return true end
        end
        return false
    end

    -- A split file's later parts, in order ({ path on disk }), whether
    -- they're all there (false: one is on a disk that's out), and the
    -- count beside the first part (an empty part 1), if it's in.
    local function partsOf(rel)
        local prefix, byN, of = escaped(rel) .. ".", {}, 1
        for _, m in ipairs(P.members()) do
            local dir = base.combine(m.root, PARTS)
            if base.isDir(dir) then
                for _, name in ipairs(base.list(dir)) do
                    local after = text.stripPrefix(name, prefix)
                    if after then
                        -- after the prefix: "n-total", two numbers
                        local n, total = text.cut(after, "-")
                        if scan.isUnsigned(n) and scan.isUnsigned(total) then
                            byN[tonumber(n)] = base.combine(dir, name)
                            of = math.max(of, tonumber(total))
                        end
                    end
                end
            end
        end
        local out, whole = {}, true
        for n = 2, of do
            if byN[n] then out[#out + 1] = byN[n] else whole = false end
        end
        return out, whole, byN[1]
    end

    local function readFile(path)
        local h = base.open(path, "rb")
        if not h then return nil end
        local s = h.readAll() or ""
        h.close()
        return s
    end

    -- The file at rel, nil if there's none; false if part of it is missing.
    local function contents(rel)
        local m = holder(rel)
        if not m then
            local parts, _, count = partsOf(rel)
            if count or #parts > 0 then return false end      -- (its first part's disk is out)
            return nil
        end
        local parts, whole = partsOf(rel)
        if not whole then return false end
        local t = { readFile(real(m, rel)) or "" }
        for _, p in ipairs(parts) do t[#t + 1] = readFile(p) or "" end
        return table.concat(t)
    end

    local function free(m) return base.getFreeSpace(m.root) or 0 end

    -- Folders missing on member m on the way to rel's folder (each costs MIN).
    local function missingDirs(m, rel)
        local n, dir = 0, base.getDir(rel)
        while dir ~= "" and dir ~= ".." and not base.isDir(real(m, dir)) do
            n = n + 1
            dir = base.getDir(dir)
        end
        return n
    end

    ----------------------------------------------------------------------
    -- Changing things
    ----------------------------------------------------------------------
    -- Delete the file at rel and every part of it.
    local function removeFile(rel)
        for _, m in ipairs(P.members()) do
            local p = real(m, rel)
            if base.exists(p) and not base.isDir(p) then base.delete(p) end
        end
        local parts, _, count = partsOf(rel)
        for _, p in ipairs(parts) do base.delete(p) end
        if count then base.delete(count) end
    end

    local function writeOn(path, data)
        local h, err = base.open(path, "wb")
        if not h then error(err or (path .. ": can't write"), 0) end
        h.write(data)
        h.close()
    end

    -- Put `data` at rel: on the member with the most room if it fits there
    -- whole, else split across them, the most room first.
    local function store(rel, data)
        removeFile(rel)
        local list = {}
        for _, m in ipairs(P.members()) do list[#list + 1] = m end
        if #list == 0 then error(full("") .. ": no disks in the pool", 0) end
        table.sort(list, function(a, b) return free(a) > free(b) end)
        local first = list[1]
        local need = math.max(#data, MIN) + missingDirs(first, rel) * MIN
        if free(first) >= need then
            writeOn(real(first, rel), data)
            return
        end
        -- split: how much each member can take (the first: its folders and the count too)
        local room, total = {}, 0
        for i, m in ipairs(list) do
            local cost = SLACK + (i == 1 and (missingDirs(m, rel) + 1) * MIN or 0)
                + (base.isDir(base.combine(m.root, PARTS)) and 0 or MIN)
            room[i] = math.max(0, free(m) - cost)
            total = total + room[i]
        end
        if total < #data then error(full(rel) .. ": Out of space", 0) end
        local pieces, at = {}, 1
        for i, m in ipairs(list) do
            if at > #data then break end
            if room[i] > 0 then
                pieces[#pieces + 1] = { m = m, data = data:sub(at, at + room[i] - 1) }
                at = at + room[i]
            end
        end
        for n, pc in ipairs(pieces) do
            base.makeDir(base.combine(pc.m.root, PARTS))
            if n == 1 then
                writeOn(real(pc.m, rel), pc.data)
                writeOn(base.combine(pc.m.root, PARTS .. "/" .. partName(rel, 1, #pieces)), "")
            else
                writeOn(base.combine(pc.m.root, PARTS .. "/" .. partName(rel, n, #pieces)), pc.data)
            end
        end
    end

    ----------------------------------------------------------------------
    -- Handles, as fs.open gives them
    ----------------------------------------------------------------------
    local function readHandle(data, binary)
        local pos, open = 1, true
        local h = {}
        local function check() if not open then error("attempt to use a closed file", 2) end end
        function h.readLine(keep)
            check()
            if pos > #data then return nil end
            local e = text.find(data, "\n", pos)
            local line
            if e then line = data:sub(pos, keep and e or e - 1); pos = e + 1
            else line = data:sub(pos); pos = #data + 1 end
            if not keep then line = text.stripSuffix(line, "\r") or line end
            return line
        end
        function h.readAll()
            check()
            local s = data:sub(pos)
            pos = #data + 1
            return s
        end
        function h.read(n)
            check()
            if pos > #data then return nil end
            if n == nil and binary then
                local b = data:byte(pos)
                pos = pos + 1
                return b
            end
            n = n or 1
            local s = data:sub(pos, pos + n - 1)
            pos = pos + #s
            return s
        end
        function h.seek(whence, offset)
            check()
            whence, offset = whence or "cur", offset or 0
            local base0 = whence == "set" and 0 or whence == "end" and #data or pos - 1
            local to = base0 + offset
            if to < 0 then return nil, "Position is negative" end
            pos = to + 1
            return to
        end
        function h.close() open = false end
        return h
    end

    local function writeHandle(rel, start, binary)
        local buf, open = { start }, true
        local h = {}
        local function check() if not open then error("attempt to use a closed file", 2) end end
        function h.write(x)
            check()
            if binary and type(x) == "number" then buf[#buf + 1] = string.char(x % 256)
            else buf[#buf + 1] = tostring(x) end
        end
        function h.writeLine(x) check(); buf[#buf + 1] = tostring(x) .. "\n" end
        function h.flush()
            check()
            local s = table.concat(buf)
            buf = { s }
            store(rel, s)
        end
        function h.close()
            check()
            open = false
            store(rel, table.concat(buf))
        end
        return h
    end

    ----------------------------------------------------------------------
    -- The fs functions, for paths inside the pool
    ----------------------------------------------------------------------
    local F = {}

    function F.exists(rel) return isDir(rel) or holder(rel) ~= nil end
    F.isDir = isDir
    function F.isReadOnly() return false end
    function F.getDrive(rel) return F.exists(rel) and P.mount or nil end
    function F.isDriveRoot(rel) return rel == "" end

    function F.list(rel)
        if not isDir(rel) then error(full(rel) .. ": Not a directory", 0) end
        local set, out = {}, {}
        for _, m in ipairs(P.members()) do
            local p = real(m, rel)
            if base.isDir(p) then
                for _, n in ipairs(base.list(p)) do
                    if not (rel == "" and hiddenTop(n)) and not set[n] then set[n] = true; out[#out + 1] = n end
                end
            end
        end
        table.sort(out)
        return out
    end

    function F.getSize(rel)
        if isDir(rel) then return 0 end
        local m = holder(rel)
        if not m then error(full(rel) .. ": No such file", 0) end
        local n = base.getSize(real(m, rel))
        for _, p in ipairs(partsOf(rel)) do n = n + base.getSize(p) end
        return n
    end

    function F.attributes(rel)
        if isDir(rel) then
            for _, m in ipairs(P.members()) do
                if base.isDir(real(m, rel)) then
                    local a = base.attributes(real(m, rel))
                    a.isReadOnly = false
                    return a
                end
            end
            return { size = 0, isDir = true, isReadOnly = false, created = 0, modified = 0, modification = 0 }
        end
        local m = holder(rel)
        if not m then error(full(rel) .. ": No such file", 0) end
        local a = base.attributes(real(m, rel))
        a.size = F.getSize(rel)
        return a
    end

    function F.getFreeSpace()
        local n = 0
        for _, m in ipairs(P.members()) do n = n + free(m) end
        return n
    end
    function F.getCapacity()
        local n = 0
        for _, m in ipairs(P.members()) do n = n + (base.getCapacity(m.root) or 0) end
        return n
    end

    function F.makeDir(rel)
        if rel == "" or isDir(rel) then return end
        if hidden(rel) then error(full(rel) .. ": Access denied", 0) end
        if holder(rel) then error(full(rel) .. ": File exists", 0) end
        local list = P.members()
        if #list == 0 then error(full("") .. ": no disks in the pool", 0) end
        local best = list[1]
        for _, m in ipairs(list) do if free(m) > free(best) then best = m end end
        base.makeDir(real(best, rel))
    end

    function F.delete(rel)
        if rel == "" then error(full(rel) .. ": Access denied", 0) end
        if hidden(rel) then return end
        if isDir(rel) then
            for _, n in ipairs(F.list(rel)) do F.delete(base.combine(rel, n)) end
            for _, m in ipairs(P.members()) do
                if base.isDir(real(m, rel)) then base.delete(real(m, rel)) end
            end
        else
            removeFile(rel)
        end
    end

    function F.open(rel, mode)
        local binary = text.contains(mode, "b")
        local kind = mode:sub(1, 1)
        if kind == "r" then
            if isDir(rel) then return nil, full(rel) .. ": No such file" end
            local data = contents(rel)
            if data == false then return nil, full(rel) .. ": part of it is on a disk that's out" end
            if not data then return nil, full(rel) .. ": No such file" end
            return readHandle(data, binary)
        elseif kind == "w" or kind == "a" then
            if rel == "" or isDir(rel) then return nil, full(rel) .. ": Cannot write to directory" end
            if hidden(rel) then return nil, full(rel) .. ": Access denied" end
            if #P.members() == 0 then return nil, full("") .. ": no disks in the pool" end
            local start = kind == "a" and contents(rel) or ""
            if start == false then return nil, full(rel) .. ": part of it is on a disk that's out" end
            start = start or ""
            if kind == "w" then
                local ok, err = pcall(store, rel, "")
                if not ok then return nil, err end
            end
            return writeHandle(rel, start, binary)
        end
        return nil, "Unsupported mode"
    end

    P.fs = F
    P.contents, P.store = contents, store
    return P
end

-- fs.find's patterns, for glob.match: "*" any run of characters within a
-- name, "?" any one, anything else itself (no [classes], no \ escapes)
local FIND_GLOB = { escapes = false, classes = false }

--------------------------------------------------------------------------
-- Tab completion through a patched fs table
--------------------------------------------------------------------------

-- CraftOS's fs.complete, loaded again from the ROM's fs API with fsTable
-- as the `fs` it sees, or nil where there's no ROM (as in the sims).  The
-- API copies the functions out of that fs when it runs, so this is
-- called once they're patched.
local ROM_FS_API = "rom/apis/fs.lua"
local function romComplete(base, fsTable)
    if not base.exists(ROM_FS_API) or base.isDir(ROM_FS_API) then return nil end
    local h = base.open(ROM_FS_API, "r")
    if not h then return nil end
    local source = h.readAll()
    h.close()
    local env = setmetatable({ fs = fsTable }, { __index = _G })
    local chunk = source and load(source, "@/" .. ROM_FS_API, "t", env)
    if not chunk or not pcall(chunk) then return nil end
    if type(env.complete) ~= "function" then return nil end
    return env.complete
end

-- Ours, for where there's no ROM, written from fs.complete's documented
-- behaviour.  The path is read from location (or from the root, if it
-- starts with a slash); what comes after its last slash is a name partly
-- typed, and the answers are the endings that finish it to a name in
-- that folder.  A folder gives two: its ending with "/" (to go on into
-- it) and, unless include_dirs is false, the ending alone.  Files are
-- left out if include_files is false; hidden names (a leading dot), if
-- include_hidden is false and the name typed doesn't start with a dot.
-- A name typed on its own, below the root, can also finish to "..".
local function isSlash(c) return c == "/" or c == "\\" end

-- path -> the folder it's in, the name partly typed, and whether the
-- path named a folder at all (rather than just the name)
local function splitCompletion(combine, path, location)
    local lastSlash = 0
    for i = 1, #path do
        if isSlash(path:sub(i, i)) then lastSlash = i end
    end
    local typed = path:sub(lastSlash + 1)
    local folder = (text.replace(path:sub(1, lastSlash), "\\", "/"))
    if isSlash(path:sub(1, 1)) then return combine(folder), typed, true end
    return combine(location or "", folder), typed, lastSlash > 0
end

local function completeThrough(fsTable, path, location, files, dirs)
    local hidden
    if type(files) == "table" then      -- the options form
        files, dirs, hidden = files.include_files, files.include_dirs, files.include_hidden
    end
    files, dirs, hidden = files ~= false, dirs ~= false, hidden ~= false     -- each on unless false
    local combine = fsTable.combine
    local folder, typed, namedFolder = splitCompletion(combine, path, location)
    if not fsTable.isDir(folder) then return {} end

    local names = {}
    if folder ~= "" and not namedFolder then names[1] = ".." end
    for _, name in ipairs(fsTable.list(folder)) do names[#names + 1] = name end
    local showHidden = hidden or text.startsWith(typed, ".")

    local out = {}
    for _, name in ipairs(names) do
        local ending = text.stripPrefix(name, typed)        -- (nil: it doesn't fit)
        if ending and (showHidden or not text.startsWith(name, ".")) then
            if name == ".." or fsTable.isDir(combine(folder, name)) then
                out[#out + 1] = ending .. "/"
                if dirs and ending ~= "" then out[#out + 1] = ending end
            elseif files and ending ~= "" then
                out[#out + 1] = ending
            end
        end
    end
    return out
end

-- Install the pool into `fsTable` (CraftOS's fs) in place, at /<mount>.
-- Returns the pool.  Installing twice does nothing more.
function J.install(fsTable, opts)
    if fsTable.jbodPool then return fsTable.jbodPool end
    local base = {}
    for k, v in pairs(fsTable) do base[k] = v end
    local P = J.new(base, opts)
    local F, mount = P.fs, P.mount

    -- the path inside the pool, or nil for any other path
    local function inside(p)
        if type(p) ~= "string" then return nil end
        p = base.combine(p)
        if p == mount then return "" end
        return text.stripPrefix(p, mount .. "/")
    end

    local function wrap(name, onRoot)
        local orig = base[name]
        fsTable[name] = function(p, ...)
            local rel = inside(p)
            if rel then return F[name](rel, ...) end
            if onRoot then return onRoot(orig, p, ...) end
            return orig(p, ...)
        end
    end
    for _, name in ipairs({ "exists", "isDir", "isReadOnly", "getSize", "getFreeSpace", "getCapacity",
                            "getDrive", "attributes", "makeDir", "delete", "open", "isDriveRoot" }) do
        if base[name] then wrap(name) end
    end
    -- the root lists the mount point too
    wrap("list", function(orig, p)
        local out = orig(p)
        if base.combine(p) == "" then
            local there = false
            for _, n in ipairs(out) do if n == mount then there = true end end
            if not there then out[#out + 1] = mount; table.sort(out) end
        end
        return out
    end)

    -- copy and move: within the pool, out of it, into it
    local function copyTree(from, to)
        if fsTable.exists(to) then error("/" .. base.combine(to) .. ": File exists", 0) end
        if fsTable.isDir(from) then
            fsTable.makeDir(to)
            for _, n in ipairs(fsTable.list(from)) do
                copyTree(base.combine(from, n), base.combine(to, n))
            end
        else
            local r = fsTable.open(from, "rb")
            if not r then error("/" .. base.combine(from) .. ": No such file", 0) end
            local data = r.readAll() or ""
            r.close()
            local w, err = fsTable.open(to, "wb")
            if not w then error(err, 0) end
            w.write(data)
            w.close()
        end
    end
    local origCopy, origMove = base.copy, base.move
    function fsTable.copy(from, to)
        if not inside(from) and not inside(to) then return origCopy(from, to) end
        if not fsTable.exists(from) then error("/" .. base.combine(from) .. ": No such file", 0) end
        copyTree(from, to)
    end
    function fsTable.move(from, to)
        if not inside(from) and not inside(to) then return origMove(from, to) end
        if not fsTable.exists(from) then error("/" .. base.combine(from) .. ": No such file", 0) end
        if inside(from) == "" then error("/" .. mount .. ": Access denied", 0) end
        copyTree(from, to)
        fsTable.delete(from)
    end

    -- completion (the shell's Tab): CraftOS's fs.complete works through
    -- the fs it was loaded with, not this table, so it never sees the
    -- pool.  CraftOS's own, loaded again with this table as its fs (this
    -- has to come after the patches above: see romComplete), or where
    -- there's no ROM, ours
    fsTable.complete = romComplete(base, fsTable) or function(path, location, files, dirs)
        return completeThrough(fsTable, path, location, files, dirs)
    end

    -- find: the pool's matches as well as the disk's
    local origFind = base.find
    if origFind then
        function fsTable.find(pattern)
            local out = origFind(pattern)
            local parts = path.segments(base.combine(pattern))
            if #parts == 0 or not glob.match(parts[1], mount, FIND_GLOB) then return out end
            local function walk(rel, i)
                if i > #parts then out[#out + 1] = base.combine(mount, rel); return end
                if not F.isDir(rel) then return end
                for _, n in ipairs(F.list(rel)) do
                    if glob.match(parts[i], n, FIND_GLOB) then walk(base.combine(rel, n), i + 1) end
                end
            end
            walk("", 2)
            table.sort(out)
            return out
        end
    end

    fsTable.jbodPool = P
    return P
end

return J
