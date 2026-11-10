-- ls.lua -- list directory contents (POSIX ls, with the GNU options in
-- everyday use)
--
--   ls [-aAdFhlpRrSt1] [file...]
--
-- Lists each directory operand's entries (default "."), and file operands
-- as themselves: files first, then each directory under a "name:" header
-- when there's more than one operand.  Names starting with "." are hidden
-- unless -a or -A, and so, with the fileserver's pool mounted, are its
-- member disks' own mounts (/disk, /disk2...: their files are in /jbod).
-- To the screen, entries go in columns (directories in green on a colour
-- screen); into a pipe or a file, one per line.
--   -a  all entries, the hidden ones and "." and ".." too
--   -A  almost all: the hidden ones, not "." and ".."
--   -l  long format: type and permissions, size, modification time, name,
--      after a "total" line (the size of what's listed, in kilobytes).
--      CraftOS has no owners, groups or links, so there are no columns
--      for them; read-only files (/rom, disks set read-only) have no "w".
--   -h  with -l, sizes as 1.5K, 23K, 4.0M instead of bytes
--   -d  list directory operands themselves, not what's in them
--   -R  list subdirectories too, each under its own header
--   -t  newest first;  -S  largest first;  -r  reverse the order
--   -F  mark directories with "/" (-p: the same)
--   -1  one entry per line
-- deploy/boot makes `ls` an alias for this, ahead of CraftOS's own `ls`
-- (an alias for `list`, which shows hidden files only with the setting
-- list.show_hidden).  A missing operand is reported and ls exits 2.

package.path = (ccnix and ccnix.lib or "/" .. fs.getDir(fs.getDir(shell.getRunningProgram())) .. "/lib/?.lua;") .. package.path  -- ccnix's lib/, or the one beside bin/
local cu = require("cu").init("ls", "ls [-aAdFhlpRrSt1] [file...]")
local convert = require("convert")
local path = require("path")
local text = require("text")
local opts, operands = cu.getopt({ ... }, "aAdFhlpRrSt1")
local mark = opts.F or opts.p

-- An entry: name as shown, full path on disk, and its attributes.
local function entry(name, full)
    local ok, a = pcall(fs.attributes, full)
    if not ok or not a then
        a = { size = 0, isDir = fs.isDir(full), isReadOnly = fs.isReadOnly(full) }
    end
    return { name = name, path = full, dir = a.isDir, ro = a.isReadOnly, size = a.isDir and 0 or a.size,
             time = cu.mtime(full) or 0 }
end

local function sorted(list)
    local function cmp(a, b)
        if opts.t and a.time ~= b.time then return a.time > b.time end
        if opts.S and a.size ~= b.size then return a.size > b.size end
        return a.name < b.name
    end
    table.sort(list, function(a, b)
        if opts.r then return cmp(b, a) end
        return cmp(a, b)
    end)
    return list
end

-- a size for -l: bytes, or with -h 1.5K, 23K, 4.0M (as GNU's -h)
local function size(n)
    return opts.h and convert.humanSize(n) or tostring(n)
end

local now = os.epoch and os.epoch("utc") / 1000 or os.time()
local HALF_YEAR = 182 * 24 * 3600
local function when(ms)
    if not ms or ms <= 0 then return "           -" end    -- (none recorded: the root)
    local t = math.floor(ms / 1000)
    local day = os.date("%d", t)
    local oneDigit = text.stripPrefix(day, "0")
    if oneDigit then day = " " .. oneDigit end     -- " 5", not "05"
    if math.abs(now - t) < HALF_YEAR then
        return os.date("%b ", t) .. day .. os.date(" %H:%M", t)
    end
    return os.date("%b ", t) .. day .. os.date("  %Y", t)
end

local colour = cu.isTerminal() and term and term.isColour and term.isColour()
local function shown(e) return e.name .. ((mark and e.dir) and "/" or "") end
-- write a name, a directory in green on a colour screen
local function writeName(e)
    if colour and e.dir then
        local was = term.getTextColour()
        term.setTextColour(colours.green)
        io.write(shown(e))
        term.setTextColour(was)
    else
        io.write(shown(e))
    end
end

local function long(list, withTotal)
    local total = 0
    for _, e in ipairs(list) do total = total + e.size end
    if withTotal then io.write("total ", opts.h and size(total) or tostring(math.ceil(total / 1024)), "\n") end
    local rows, wide = {}, 0
    for i, e in ipairs(list) do
        local w = e.ro and "-" or "w"
        local mode = (e.dir and "d" or "-") .. "r" .. w .. (e.dir and "x" or "-")
            .. "r-" .. (e.dir and "x" or "-") .. "r-" .. (e.dir and "x" or "-")
        rows[i] = { mode = mode, size = size(e.size), time = when(e.time) }
        wide = math.max(wide, #rows[i].size)
    end
    for i, e in ipairs(list) do
        local r = rows[i]
        io.write(r.mode, " ", text.padLeft(r.size, wide), " ", r.time, " ")
        writeName(e)
        io.write("\n")
    end
end

-- In columns down the screen, as many as fit (two spaces between).
local function columns(list)
    if #list == 0 then return end
    local width = term and term.getSize and (term.getSize()) or 51
    local cols, rows, widths = 1, #list, nil
    for c = #list, 1, -1 do
        local r = math.ceil(#list / c)
        if c == 1 or math.ceil(#list / r) == c then
            local ws, total = {}, 0
            for k = 1, c do
                local w = 0
                for j = (k - 1) * r + 1, math.min(k * r, #list) do w = math.max(w, #shown(list[j])) end
                ws[k] = w
                total = total + w + (k < c and 2 or 0)
            end
            if total <= width or c == 1 then cols, rows, widths = c, r, ws; break end
        end
    end
    for row = 1, rows do
        for k = 1, cols do
            local e = list[(k - 1) * rows + row]
            if e then
                writeName(e)
                local nextOne = list[k * rows + row]
                if k < cols and nextOne then io.write(string.rep(" ", widths[k] - #shown(e) + 2)) end
            end
        end
        io.write("\n")
    end
end

local function show(list, isDir)
    if opts.l then long(list, isDir)
    elseif opts["1"] or not cu.isTerminal() then
        for _, e in ipairs(list) do writeName(e); io.write("\n") end
    else columns(list) end
end

-- What's in directory `dir` (shown as `label`), and its subdirectories
-- after it with -R.
local function listDir(dir, label, header)
    if header then io.write(label, ":\n") end
    local ok, names = pcall(fs.list, dir)
    if not ok then cu.fail(label .. ": " .. tostring(names), 2); return end
    local list = {}
    if opts.a then
        list[#list + 1] = entry(".", dir)
        list[#list + 1] = entry("..", dir == "" and "" or fs.getDir(dir))
    end
    for _, n in ipairs(names) do
        local p = fs.combine(dir, n)
        if opts.a or opts.A or not cu.hidden(p) then list[#list + 1] = entry(n, p) end
        cu.breathe()        -- (long trees)
    end
    show(sorted(list), true)
    if opts.R then
        for _, e in ipairs(list) do
            if e.dir and e.name ~= "." and e.name ~= ".." then
                io.write("\n")
                listDir(e.path, path.join(label, e.name), true)
            end
        end
    end
end

if #operands == 0 then operands = { "." } end
local files, dirs = {}, {}
for _, op in ipairs(operands) do
    local p = shell.resolve(op)
    if not fs.exists(p) then
        cu.fail("cannot access '" .. op .. "': No such file or directory", 2)
    elseif fs.isDir(p) and not opts.d then
        dirs[#dirs + 1] = entry(op, p)
    else
        files[#files + 1] = entry(op, p)
    end
end
if #files > 0 then show(sorted(files)) end
sorted(dirs)
local headers = #operands > 1 or opts.R
for i, d in ipairs(dirs) do
    if i > 1 or #files > 0 then io.write("\n") end
    listDir(d.path, d.name, headers)
end
return cu.exit()
