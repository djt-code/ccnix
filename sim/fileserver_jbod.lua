-- sim/fileserver_jbod.lua
--
-- lib/jbod.lua over a mock file system with a floppy in each of several
-- drives (125,000 bytes each, CC's 500 bytes at least for every file and
-- folder): blank disks join by themselves; /jbod is in the root listing;
-- the space adds up; folders are shared; a file too big for one disk is
-- split and reads back the same; out of space is an error, not a half
-- file; a fifth drive grows the pool; a disk with files waits for add();
-- a disk taken out takes its files, and a split file with a part on it
-- says so (its last part too, and its first); copy and move in and out;
-- fs.find; Tab completion in the pool; and the paths outside /jbod
-- untouched.
local PROJ = ...
package.path = PROJ .. "/lib/?.lua;" .. PROJ .. "/sim/lib/?.lua;" .. package.path
local M = require("mock")
local check = M.check
local J = require("jbod")

--------------------------------------------------------------------------
-- A file system with mounts: "" (the computer, 1 MB) and a disk per drive
--------------------------------------------------------------------------
local MIN, FLOPPY = 500, 125000
local files, dirs, mounts = {}, { [""] = true }, { [""] = 1000000 }
local function norm(p)
    local out = {}
    for part in p:gsub("\\", "/"):gmatch("[^/]+") do
        if part == ".." then table.remove(out) elseif part ~= "." then out[#out + 1] = part end
    end
    return table.concat(out, "/")
end
local function under(p, root) return root == "" or p == root or p:sub(1, #root + 1) == root .. "/" end
local function mountOf(p)
    local best = ""
    for root in pairs(mounts) do if under(p, root) and #root > #best then best = root end end
    return best
end
local function used(root)
    local n = 0
    for p, s in pairs(files) do if mountOf(p) == root then n = n + math.max(#s, MIN) end end
    for p in pairs(dirs) do if p ~= root and mountOf(p) == root then n = n + MIN end end
    return n
end
local fake = {}
function fake.combine(...)
    local t = {}
    for _, s in ipairs({ ... }) do t[#t + 1] = s end
    return norm(table.concat(t, "/"))
end
function fake.getDir(p) p = norm(p); return p:match("^(.*)/[^/]*$") or "" end
function fake.getName(p) p = norm(p); return p == "" and "root" or p:match("([^/]*)$") end
function fake.exists(p) p = norm(p); return files[p] ~= nil or dirs[p] == true end
function fake.isDir(p) return dirs[norm(p)] == true end
function fake.isReadOnly() return false end
function fake.isDriveRoot(p) return mounts[norm(p)] ~= nil end
function fake.getDrive(p) p = norm(p); if not fake.exists(p) then return nil end return mountOf(p) == "" and "hdd" or mountOf(p) end
function fake.list(p)
    p = norm(p)
    if not dirs[p] then error("/" .. p .. ": Not a directory", 0) end
    local out = {}
    local function add(q)
        if q ~= p and fake.getDir(q) == p then out[#out + 1] = fake.getName(q) end
    end
    for q in pairs(files) do add(q) end
    for q in pairs(dirs) do add(q) end
    table.sort(out)
    return out
end
function fake.makeDir(p)
    p = norm(p)
    if files[p] then error("/" .. p .. ": File exists", 0) end
    local acc = ""
    for part in p:gmatch("[^/]+") do
        acc = acc == "" and part or acc .. "/" .. part
        if not dirs[acc] then
            local root = mountOf(acc)
            if used(root) + MIN > mounts[root] then error("/" .. acc .. ": Out of space", 0) end
            dirs[acc] = true
        end
    end
end
function fake.delete(p)
    p = norm(p)
    for q in pairs(files) do if under(q, p) then files[q] = nil end end
    for q in pairs(dirs) do if under(q, p) and not mounts[q] then dirs[q] = nil end end
end
function fake.getSize(p)
    p = norm(p)
    if files[p] then return #files[p] end
    if dirs[p] then return 0 end
    error("/" .. p .. ": No such file", 0)
end
function fake.getFreeSpace(p) local root = mountOf(norm(p)); return mounts[root] - used(root) end
function fake.getCapacity(p) return mounts[mountOf(norm(p))] end
function fake.attributes(p)
    p = norm(p)
    if not fake.exists(p) then error("/" .. p .. ": No such file", 0) end
    return { size = files[p] and #files[p] or 0, isDir = dirs[p] == true, isReadOnly = false,
             created = 1, modified = 1, modification = 1 }
end
function fake.open(p, mode)
    p = norm(p)
    if mode:sub(1, 1) == "r" then
        if not files[p] then return nil, "/" .. p .. ": No such file" end
        local data, pos = files[p], 1
        return {
            readAll = function() local s = data:sub(pos); pos = #data + 1; return s end,
            readLine = function()
                if pos > #data then return nil end
                local e = data:find("\n", pos, true) or #data + 1
                local l = data:sub(pos, e - 1); pos = e + 1; return l
            end,
            close = function() end,
        }
    end
    if dirs[p] then return nil, "/" .. p .. ": Cannot write to directory" end
    fake.makeDir(fake.getDir(p))
    local buf = { mode:sub(1, 1) == "a" and files[p] or "" }
    local old = files[p]
    files[p] = buf[1]
    return {
        write = function(s) buf[#buf + 1] = type(s) == "number" and string.char(s) or s end,
        writeLine = function(s) buf[#buf + 1] = s .. "\n" end,
        close = function()
            local s = table.concat(buf)
            files[p] = s
            local root = mountOf(p)
            if used(root) > mounts[root] then files[p] = old; error("Out of space", 0) end
        end,
    }
end
function fake.move(a, b)
    a, b = norm(a), norm(b)
    if fake.exists(b) then error("/" .. b .. ": File exists", 0) end
    for q, s in pairs(files) do if under(q, a) then files[b .. q:sub(#a + 1)] = s; files[q] = nil end end
    for q in pairs(dirs) do if under(q, a) then dirs[b .. q:sub(#a + 1)] = true; dirs[q] = nil end end
end
function fake.copy(a, b)
    a, b = norm(a), norm(b)
    for q, s in pairs(files) do if under(q, a) then files[b .. q:sub(#a + 1)] = s end end
    for q in pairs(dirs) do if under(q, a) then dirs[b .. q:sub(#a + 1)] = true end end
end
function fake.find(pattern)
    local lua = "^" .. norm(pattern):gsub("[%.%-]", "%%%0"):gsub("%*", "[^/]*"):gsub("%?", "[^/]") .. "$"
    local out = {}
    for q in pairs(files) do if q:match(lua) then out[#out + 1] = q end end
    for q in pairs(dirs) do if q ~= "" and q:match(lua) then out[#out + 1] = q end end
    table.sort(out)
    return out
end

-- the drives: a floppy in each, mounted at disk, disk2, ...
local DRIVES, LABELS = {}, {}
local function addDrive(i)
    local root = i == 1 and "disk" or ("disk" .. i)
    mounts[root], dirs[root] = FLOPPY, true
    DRIVES[#DRIVES + 1] = { name = "drive_" .. (i - 1), root = root }
end
local function removeDrive(name)
    for i, d in ipairs(DRIVES) do
        if d.name == name then table.remove(DRIVES, i); return d end
    end
end
for i = 1, 4 do addDrive(i) end
local CLOCK = 0
local function tick() CLOCK = CLOCK + 2 end      -- (the pool looks for drives at most once a second)

local fs = fake
local P = J.install(fs, {
    mount = "jbod",
    drives = function() local t = {} for i, d in ipairs(DRIVES) do t[i] = d end return t end,
    clock = function() return CLOCK end,
    label = function(name) LABELS[name] = "FS " .. name end,
})
local function write(p, s)
    local h, err = fs.open(p, "w")
    if not h then error(err, 0) end
    h.write(s)
    h.close()
end
local function read(p)
    local h, err = fs.open(p, "r")
    if not h then return nil, err end
    local s = h.readAll()
    h.close()
    return s
end
local function kb(n) return string.format("%.1f KB", n / 1000) end

--------------------------------------------------------------------------
check("four blank floppies joined by themselves, each labelled (by opts.label) for its drive",
    #P.members() == 4 and LABELS.drive_0 == "FS drive_0" and LABELS.drive_3 == "FS drive_3")
local rootList = table.concat(fs.list("/"), " ")
check("/jbod is in the root listing, an empty folder", rootList:find("jbod") and fs.isDir("/jbod")
    and #fs.list("/jbod") == 0, rootList)
check("its capacity is the four disks', 500 KB", fs.getCapacity("/jbod") == 4 * FLOPPY, kb(fs.getCapacity("/jbod")))
check("and its free space the four disks' less a member file each",
    fs.getFreeSpace("/jbod") == 4 * (FLOPPY - MIN), kb(fs.getFreeSpace("/jbod")))

write("/jbod/a.txt", "one\ntwo\n")
local h = fs.open("jbod/a.txt", "r")
check("a small file: written, read back line by line", h.readLine() == "one" and h.readLine() == "two"
    and h.readLine() == nil)
h.close()
check("the member files don't show", table.concat(fs.list("/jbod"), " ") == "a.txt")
fs.makeDir("/jbod/docs")
write("/jbod/docs/x.txt", "x")
write("/jbod/docs/y.txt", "y")
check("folders: made, and what's in them listed (the files may be on different disks)",
    table.concat(fs.list("/jbod/docs"), " ") == "x.txt y.txt" and fs.isDir("/jbod/docs"))

local BIG = {}
for i = 1, 300000 do BIG[i] = string.char(32 + (i * 7) % 90) end
BIG = table.concat(BIG)
write("/jbod/big.bin", BIG)
local onDisks = 0
for _, d in ipairs(DRIVES) do
    if fs.exists(d.root .. "/big.bin") or fs.isDir(d.root .. "/.jbod.parts") then onDisks = onDisks + 1 end
end
check("a 300 KB file, too big for any one floppy: split across 3 disks", onDisks >= 3, onDisks .. " disks")
check("and it reads back the same, 300,000 bytes", read("/jbod/big.bin") == BIG and fs.getSize("/jbod/big.bin") == 300000,
    tostring(fs.getSize("/jbod/big.bin")))
check("the parts don't show", table.concat(fs.list("/jbod"), " ") == "a.txt big.bin docs")

local before = fs.getFreeSpace("/jbod")
local ok, err = pcall(write, "/jbod/huge.bin", string.rep("z", 250000))
check("too big for what's left: an error, and nothing half written",
    not ok and tostring(err):find("Out of space") and not fs.exists("/jbod/huge.bin")
        and fs.getFreeSpace("/jbod") == before, tostring(err))

tick(); addDrive(5)
check("a fifth drive with a blank floppy: the pool grows by itself",
    #P.members() == 5 and fs.getCapacity("/jbod") == 5 * FLOPPY, kb(fs.getCapacity("/jbod")))
write("/jbod/more.bin", string.rep("m", 110000))
check("and takes a file that wouldn't have fit", read("/jbod/more.bin") == string.rep("m", 110000))

tick(); addDrive(6)
write("/disk6/notes.txt", "mine")
tick(); P.members(true)
check("a disk with files on it isn't taken: it waits", #P.members() == 5 and #P.others() == 1
    and P.others()[1].name == "drive_5")
local added = P.add("drive_5")
check("add() makes it a member, its files in the pool", added and #P.members() == 6 and read("/jbod/notes.txt") == "mine")

fs.copy("/jbod/a.txt", "/a-copy.txt")
fs.move("/jbod/docs/x.txt", "/x.txt")
fs.copy("/x.txt", "/jbod/docs/x2.txt")
check("copy and move out of the pool and into it", read("/a-copy.txt") == "one\ntwo\n" and read("/x.txt") == "x"
    and not fs.exists("/jbod/docs/x.txt") and read("/jbod/docs/x2.txt") == "x")
local found = table.concat(fs.find("jbod/docs/*.txt"), " ")
check("fs.find in the pool", found == "jbod/docs/x2.txt jbod/docs/y.txt", found)
local function comp(...) return table.concat(fs.complete(...), " ") end
local c1, c2, c3, c4 = comp("/jb", "", true, true), comp("jbod/do", "", true, true),
    comp("docs/", "jbod", true, false), comp("", "jbod/docs", { include_dirs = false })
check("Tab completion in the pool: /jbod, its folders, their files", c1 == "od/ od" and c2 == "cs/ cs"
    and c3 == "x2.txt y.txt" and c4 == "../ x2.txt y.txt", c1 .. " | " .. c2 .. " | " .. c3 .. " | " .. c4)
check("paths outside /jbod as they were", fs.getDrive("/a-copy.txt") == "hdd" and fs.getDrive("/jbod/a.txt") == "jbod"
    and fs.getFreeSpace("/") < 1000000)

-- a disk out: the files on it go, and a split file with a part there says so
local holderOfA
for _, d in ipairs(DRIVES) do if fs.exists(d.root .. "/a.txt") then holderOfA = d.name end end
local partDisk
for _, d in ipairs(DRIVES) do
    if fs.isDir(d.root .. "/.jbod.parts") and #fs.list(d.root .. "/.jbod.parts") > 0 and d.name ~= holderOfA then
        partDisk = d
    end
end
local gone = removeDrive(partDisk.name)
tick()
local hb, herr = fs.open("/jbod/big.bin", "r")
check("a disk with part of a split file taken out: opening it says so", hb == nil and herr:find("disk that's out"),
    tostring(herr))
DRIVES[#DRIVES + 1] = gone
tick()
check("put back: it reads again", read("/jbod/big.bin") == BIG)
-- the disk with its last part, and the one with its first
local function diskWith(want)
    for _, d in ipairs(DRIVES) do
        local dir = d.root .. "/.jbod.parts"
        if fs.isDir(dir) then
            for _, n in ipairs(fs.list(dir)) do
                local i, of = n:match("^big%.bin%.(%d+)%-(%d+)$")
                if i and want(tonumber(i), tonumber(of)) then return d end
            end
        end
    end
end
local lastDisk = diskWith(function(i, of) return i == of and i > 1 end)
gone = removeDrive(lastDisk.name)
tick()
hb, herr = fs.open("/jbod/big.bin", "r")
check("its last part's disk taken out: opening it says so (not a short file)", hb == nil and tostring(herr):find("disk that's out"),
    tostring(herr))
DRIVES[#DRIVES + 1] = gone
tick()
gone = removeDrive(diskWith(function(i) return i == 1 end).name)
tick()
hb, herr = fs.open("/jbod/big.bin", "r")
check("its first part's disk taken out: that says so too", hb == nil and tostring(herr):find("disk that's out"),
    tostring(herr))
DRIVES[#DRIVES + 1] = gone
tick()
check("all back: it reads again", read("/jbod/big.bin") == BIG)

local freeBefore = fs.getFreeSpace("/jbod")
fs.delete("/jbod/big.bin")
local leftParts = 0
for _, d in ipairs(DRIVES) do
    if fs.isDir(d.root .. "/.jbod.parts") then leftParts = leftParts + #fs.list(d.root .. "/.jbod.parts") end
end
check("deleting the split file deletes every part, and frees the space",
    not fs.exists("/jbod/big.bin") and leftParts == 0 and fs.getFreeSpace("/jbod") >= freeBefore + 300000,
    leftParts .. " parts left, " .. kb(fs.getFreeSpace("/jbod") - freeBefore) .. " freed")
-- in two parts (as in game: the second's disk out, nothing else said there were two)
local TWO = string.rep("t", 200000)
write("/jbod/two.bin", TWO)
local twoDisk
for _, d in ipairs(DRIVES) do
    if fs.exists(d.root .. "/.jbod.parts/two.bin.2-2") then twoDisk = d end
end
gone = removeDrive(twoDisk.name)
tick()
hb, herr = fs.open("/jbod/two.bin", "r")
check("a file in two parts, the second's disk out: opening it says so (not the first part alone)",
    hb == nil and tostring(herr):find("disk that's out"), tostring(herr))
DRIVES[#DRIVES + 1] = gone
tick()
check("and back: it reads whole", read("/jbod/two.bin") == TWO)
fs.delete("/jbod/two.bin")
local apnd = fs.open("/jbod/a.txt", "a")
apnd.write("three\n")
apnd.close()
check("append", read("/jbod/a.txt") == "one\ntwo\nthree\n")
check("installing twice gives the same pool", J.install(fs, {}) == P)
