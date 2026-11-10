-- fileserver.lua -- the disks in every attached disk drive as one folder
--
-- Usage:
--   fileserver                 what's in the pool: each disk, its space, the total
--   fileserver mount           put the pool at /jbod (in this computer's fs, for
--                              every program, until it reboots)
--   fileserver add <drive>     make a disk that has files on it part of the pool
--                              (its files join the pool where they are)
--   fileserver startup         mount it at every boot (a line at the top of
--                              /startup.lua, ahead of ccsh and the rest)
--
-- Disk drives count whether they're beside the computer or on wired
-- modems (right-click each drive's modem to connect it: `peripherals`
-- lists them as drive_0, drive_1...).  A blank floppy put in any of them
-- joins the pool by itself, so /jbod grows as drives and disks are added;
-- a disk with files on it waits for `fileserver add`.  Each disk in the
-- pool is labelled for this computer and the drive it's in ("FS drive_2":
-- hover over it to see), and the label follows it if it's moved; a label
-- you gave it yourself stays.
-- Folders are shared across the disks; each file goes on the disk with the
-- most room, and one too big for any single disk is split across several.
-- A floppy holds 125 KB (the server's floppy_space_limit), less 500 bytes
-- for each file and folder.  Take a disk out and its files go with it
-- until it's back (a split file needs all its disks).  The layer lives in
-- lib/jbod.lua.

package.path = (ccnix and ccnix.lib or "/" .. fs.getDir(fs.getDir(shell.getRunningProgram())) .. "/lib/?.lua;") .. package.path  -- ccnix's lib/, or the one beside pc/
local jbod = require("jbod")
local scan = require("scan")
local text = require("text")

local MOUNT = "jbod"
local args = { ... }

-- a member's label: this computer's and the drive's names; one that isn't
-- of that form (or the old "jbod") was someone's own, and stays
local SIDES = { top = true, bottom = true, left = true, right = true, front = true, back = true }
local function ours(label)
    if label == nil or label == "" or label == "jbod" then return true end
    local _, where = text.cutLast(label, " ")         -- the last word: the drive
    if where == nil then return false end
    local n = text.startsWith(where, "drive_") and where:sub(#"drive_" + 1)
    return (n and n ~= "" and scan.all(n, scan.isDigit)) or SIDES[where] == true
end
local function label(name)
    local host = os.getComputerLabel() or ("computer " .. os.getComputerID())
    local want, have = (host .. " " .. name):sub(1, 32), disk.getLabel(name)
    if have ~= want and ours(have) then disk.setLabel(name, want) end
end

local function opts()
    return { mount = MOUNT, drives = jbod.drives, label = label }
end

local function kb(n) return string.format("%.1f KB", n / 1000) end

-- the pool: the one mounted, or one just for looking
local function pool()
    return fs.jbodPool or jbod.new(fs, opts())
end

local function status()
    local P = pool()
    local members = P.members(true)
    local free, cap = 0, 0
    print(string.format("/%s: %s", MOUNT, fs.jbodPool and "mounted" or "not mounted (fileserver mount)"))
    for _, m in ipairs(members) do
        local f, c = fs.getFreeSpace(m.root) or 0, fs.getCapacity(m.root) or 0
        free, cap = free + f, cap + c
        print(string.format("  %-9s /%-7s %-10s %s free of %s", m.name, m.root, disk.getLabel(m.name) or "",
            kb(f), kb(c)))
    end
    if #members == 0 then print("  no disks yet: put a blank floppy in a drive") end
    print(string.format("  %d disk%s, %s free of %s", #members, #members == 1 and "" or "s", kb(free), kb(cap)))
    for _, d in ipairs(P.others()) do
        print(string.format("  %s (/%s) has files and isn't in the pool: fileserver add %s", d.name, d.root, d.name))
    end
end

local cmd = args[1]
if cmd == nil or cmd == "status" then
    status()
elseif cmd == "mount" then
    local P = jbod.install(fs, opts())
    local n = #P.members(true)
    print(string.format("Mounted at /%s: %d disk%s, %s free.", MOUNT, n, n == 1 and "" or "s",
        kb(fs.getFreeSpace(MOUNT))))
elseif cmd == "add" and args[2] then
    local ok, why = pool().add(args[2])
    if ok then print(args[2] .. (why and (": " .. why) or " is in the pool now."))
    else printError("fileserver: " .. why); _G.POSIX_STATUS = 1; error("", 0) end
elseif cmd == "startup" then
    local line = 'shell.run("fileserver mount")'
    if not ccnix then                                   -- this program by its path, less .lua
        local prog = shell.getRunningProgram()
        if text.endsWith(prog, ".lua") then prog = prog:sub(1, -#".lua" - 1) end
        line = string.format('shell.run("%s mount")', "/" .. prog)
    end
    local target = fs.isDir("/startup") and "/startup/10-fileserver.lua" or "/startup.lua"
    local text = ""
    if fs.exists(target) then
        local f = fs.open(target, "r")
        text = f.readAll() or ""
        f.close()
    end
    if text:find(line, 1, true) then
        print(target .. " mounts it already.")
    else
        -- first, before anything that doesn't return (ccsh at boot, the
        -- autostart), which deploy/setup puts at the end
        local f = fs.open(target, "w")
        f.write(line .. "\n" .. text)
        f.close()
        print("Added to " .. target .. ": /" .. MOUNT .. " is mounted at every boot.")
    end
else
    printError("Usage: fileserver [mount | add <drive> | startup]")
    _G.POSIX_STATUS = 2
    error("", 0)
end
