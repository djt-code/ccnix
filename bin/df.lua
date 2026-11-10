-- df.lua -- report free disk space (POSIX df)
--
--   df [-k] [-P] [file...]
--
-- With no files, lists every mounted drive: the computer's own drive at
-- /, the read-only /rom, and any disks (/disk, /disk2, ...).  With files,
-- lists the drive each one is on.  Sizes are in 512-byte blocks, or
-- 1024-byte blocks with -k, rounded up.  -P gives the portable format:
--   Filesystem 1024-blocks Used Available Capacity Mounted on
--   hdd 977 3 974 1% /
-- Without -P the same figures are lined up in columns that fit a turtle's
-- screen.  The filesystem name is fs.getDrive's ("hdd", "rom", or the disk
-- drive's side).  /rom has no capacity, so its size is what its files use.

package.path = (ccnix and ccnix.lib or "/" .. fs.getDir(fs.getDir(shell.getRunningProgram())) .. "/lib/?.lua;") .. package.path  -- ccnix's lib/, or the one beside bin/
local cu = require("cu").init("df", "df [-k] [-P] [file...]")
local text = require("text")
local opts, files = cu.getopt({ ... }, "kP")
local unit = opts.k and 1024 or 512

-- bytes taken by the files at or under p, yielding now and then
local seen = 0
local function used(p)
    seen = seen + 1
    if seen % 200 == 0 then os.queueEvent("df"); os.pullEvent("df") end
    if not fs.isDir(p) then return fs.getSize(p) end
    local n = 0
    for _, name in ipairs(fs.list(p)) do n = n + used(fs.combine(p, name)) end
    return n
end

-- the mount point holding path p: walk up to a drive root
local function mountOf(p)
    while p ~= "" and not fs.isDriveRoot(p) do p = fs.getDir(p) end
    return p
end

-- one row of figures for the drive mounted at p
local function row(p)
    local free, cap = fs.getFreeSpace(p), fs.getCapacity(p)
    if type(free) ~= "number" then free = 0 end
    local use = cap and cap - free or used(p)
    local total, u, a = math.ceil((use + free) / unit), math.ceil(use / unit), math.floor(free / unit)
    local pct = (u + a) > 0 and math.ceil(u * 100 / (u + a)) or 0
    return { fs.getDrive(p) or "?", tostring(total), tostring(u), tostring(a), pct .. "%", "/" .. p }
end

local mounts, seen = {}, {}
local function add(p)
    if not seen[p] then seen[p] = true; mounts[#mounts + 1] = p end
end
if #files == 0 then
    add("")
    for _, name in ipairs(fs.list("")) do
        if fs.isDriveRoot(name) then add(name) end
    end
else
    for _, f in ipairs(files) do
        local p = shell.resolve(f)
        if fs.exists(p) then add(mountOf(p)) else cu.fail(f .. ": No such file or directory") end
    end
end

local rows = {}
for _, p in ipairs(mounts) do rows[#rows + 1] = row(p) end
if opts.P then
    io.write("Filesystem ", tostring(unit), "-blocks Used Available Capacity Mounted on\n")
    for _, r in ipairs(rows) do io.write(table.concat(r, " "), "\n") end
    return cu.exit()
end

-- columns: the name and mount point left-aligned, the numbers right
table.insert(rows, 1, { "Drive", unit .. "-blk", "Used", "Avail", "Use%", "Mount" })
local width = {}
for _, r in ipairs(rows) do
    for i, s in ipairs(r) do width[i] = math.max(width[i] or 0, #s) end
end
for _, r in ipairs(rows) do
    local out = { text.padRight(r[1], width[1]) }
    for i = 2, 5 do out[i] = text.padLeft(r[i], width[i]) end
    out[6] = r[6]
    io.write(text.join(out, " "), "\n")
end
return cu.exit()
