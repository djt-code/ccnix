-- diskclone.lua -- copy a directory onto as many floppy disks as a
-- dispenser can feed
--
-- Runs on a computer with a disk drive below it and a dispenser wired to
-- its back.  Each cycle: pulse the back output (the dispenser drops one
-- floppy into the hopper that feeds the drive), wait for the disk, copy
-- the directory onto it, label it, eject it.  Ejected disks are collected
-- by the hopper in front of the drive.  Stops when no disk arrives (the
-- dispenser is empty) or after <count> disks.
--
-- Usage:
--   diskclone <dir> [count] [--force]
--
-- <dir> must have a file named LABEL in its root: its first line becomes
-- each disk's label, and LABEL itself is not copied.  A disk that already
-- has a label or files on it is ejected untouched, unless --force is
-- given, in which case it is wiped and written like a blank one.

local DRIVE = "bottom"         -- disk drive
local PULSE_SIDE = "back"      -- redstone to the dispenser
local PULSE_TIME = 0.2         -- seconds the output stays on
local ARRIVE_TIMEOUT = 5       -- seconds to wait for a dispensed disk
local EJECT_TIMEOUT = 2        -- seconds to wait for the drive to empty
local MIN_FILE = 500           -- bytes CC charges for any file or folder

--------------------------------------------------------------------------
-- Small helpers
--------------------------------------------------------------------------
local function die(msg)
    printError(msg)
    error("", 0)
end

-- s without the blanks (space, tab, newline...: bytes 9 to 13 and 32) at
-- either end.  (Here rather than lib/scan's: diskclone runs on its own.)
local function trim(s)
    local function blank(i)
        local b = s:byte(i)
        return b == 32 or (b >= 9 and b <= 13)
    end
    local from, to = 1, #s
    while from <= to and blank(from) do from = from + 1 end
    while to >= from and blank(to) do to = to - 1 end
    return s:sub(from, to)
end

-- Bytes `path` will take on a disk, counted the way CC counts free space.
local function sizeOf(path)
    if not fs.isDir(path) then return math.max(fs.getSize(path), MIN_FILE) end
    local n = MIN_FILE
    for _, name in ipairs(fs.list(path)) do n = n + sizeOf(fs.combine(path, name)) end
    return n
end

-- Do `a` and `b` hold the same files with the same sizes?
local function sameTree(a, b)
    if fs.isDir(a) then
        if not fs.isDir(b) then return false end
        local la, lb = fs.list(a), fs.list(b)
        if #la ~= #lb then return false end
        for _, name in ipairs(la) do
            if not sameTree(fs.combine(a, name), fs.combine(b, name)) then return false end
        end
        return true
    end
    return fs.exists(b) and not fs.isDir(b) and fs.getSize(a) == fs.getSize(b)
end

--------------------------------------------------------------------------
-- Arguments and source directory
--------------------------------------------------------------------------
local args = { ... }
local FORCE = false
for i = #args, 1, -1 do
    if args[i] == "--force" then FORCE = true; table.remove(args, i) end
end
local SRC, COUNT = args[1], tonumber(args[2])
if not SRC or (args[2] and not COUNT) then
    die("Usage: diskclone <dir> [count] [--force]")
end
SRC = shell.resolve(SRC)
if not fs.isDir(SRC) then die(SRC .. " is not a directory") end

local labelPath = fs.combine(SRC, "LABEL")
if not fs.exists(labelPath) or fs.isDir(labelPath) then
    die(SRC .. " has no LABEL file; its first line is the disk label")
end
local f = fs.open(labelPath, "r")
local LABEL = trim(f.readLine() or "")
f.close()
if LABEL == "" then die("The first line of " .. labelPath .. " is empty") end

local ENTRIES, NEED = {}, 0     -- what goes on each disk, and its size
for _, name in ipairs(fs.list(SRC)) do
    if name ~= "LABEL" then
        ENTRIES[#ENTRIES + 1] = name
        NEED = NEED + sizeOf(fs.combine(SRC, name))
    end
end
table.sort(ENTRIES)

if peripheral.getType(DRIVE) ~= "drive" then
    die("No disk drive on the " .. DRIVE .. " of this computer")
end

--------------------------------------------------------------------------
-- Drive and dispenser
--------------------------------------------------------------------------
local function pulse()
    redstone.setOutput(PULSE_SIDE, true)
    sleep(PULSE_TIME)
    redstone.setOutput(PULSE_SIDE, false)
end

-- Wait until something is in the drive, at most `timeout` seconds.  A
-- "disk" event can be left over from a disk already handled, so the drive
-- itself is asked every time.
local function waitForDisk(timeout)
    if disk.isPresent(DRIVE) then return true end
    local timer = os.startTimer(timeout)
    while true do
        local ev, p1 = os.pullEvent()
        if ev == "disk" and p1 == DRIVE and disk.isPresent(DRIVE) then return true end
        if ev == "timer" and p1 == timer then return disk.isPresent(DRIVE) end
    end
end

local function ejectDisk()
    disk.eject(DRIVE)
    local timer = os.startTimer(EJECT_TIMEOUT)
    while disk.isPresent(DRIVE) do
        local ev, p1 = os.pullEvent()
        if ev == "timer" and p1 == timer then
            die("The drive won't eject; is the space in front of it blocked?")
        end
    end
end

-- Write the disk in the drive.  Returns "written", or "skipped"/"failed"
-- and a reason (and true if it failed for the directory being too big
-- for the disk).  Leaves the disk in the drive.
local function writeDisk()
    if not disk.hasData(DRIVE) then return "skipped", "not a floppy disk" end
    local mount = disk.getMountPath(DRIVE)
    local label = disk.getLabel(DRIVE)
    local existing = fs.list(mount)
    if label or #existing > 0 then
        local what = label and ("labelled \"" .. label .. "\"") or (#existing .. " files on it")
        if not FORCE then return "skipped", what .. " (use --force to overwrite)" end
        for _, name in ipairs(existing) do fs.delete(fs.combine(mount, name)) end
        disk.setLabel(DRIVE, nil)
    end
    local free = fs.getFreeSpace(mount)
    if free < NEED then
        return "failed", string.format("needs %d bytes, disk has %d free", NEED, free), true
    end
    for _, name in ipairs(ENTRIES) do
        local ok, err = pcall(fs.copy, fs.combine(SRC, name), fs.combine(mount, name))
        if not ok then return "failed", "copying " .. name .. ": " .. tostring(err) end
    end
    for _, name in ipairs(ENTRIES) do
        if not sameTree(fs.combine(SRC, name), fs.combine(mount, name)) then
            return "failed", name .. " didn't copy correctly"
        end
    end
    disk.setLabel(DRIVE, LABEL)
    return "written"
end

--------------------------------------------------------------------------
-- Main
--------------------------------------------------------------------------
print(string.format("Cloning %s as \"%s\": %d entries, about %d bytes%s",
    SRC, LABEL, #ENTRIES, NEED, FORCE and " (--force: overwriting used disks)" or ""))

local counts = { written = 0, skipped = 0, failed = 0 }
local ok, err = pcall(function()
    while not COUNT or counts.written < COUNT do
        if not disk.isPresent(DRIVE) then
            pulse()
            if not waitForDisk(ARRIVE_TIMEOUT) then
                print("No disk arrived; the dispenser is empty.")
                break
            end
        end
        local n = counts.written + counts.skipped + counts.failed + 1
        local result, why, tooBig = writeDisk()
        counts[result] = counts[result] + 1
        print(string.format("Disk %d: %s%s", n, result, why and (" - " .. why) or ""))
        ejectDisk()
        if tooBig then
            print("The directory doesn't fit on a floppy; stopping.")
            break
        end
    end
end)
redstone.setOutput(PULSE_SIDE, false)
if not ok then
    if err ~= "" then printError(err) end
    error("", 0)
end
print(string.format("Done: %d written, %d skipped, %d failed.",
    counts.written, counts.skipped, counts.failed))
