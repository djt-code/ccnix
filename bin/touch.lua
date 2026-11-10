-- touch.lua -- create files, or mark them modified now (POSIX touch)
--
--   touch [-acm] [-r ref_file | -t time | -d date_time] file...
--
-- A missing file is created empty (-c: left missing, quietly); its
-- directory must already exist.  CraftOS cannot set a file's times, so
-- for an existing file touch rewrites it unchanged, which makes its
-- modification time now.  There is no access time: -a alone does
-- nothing to an existing file, and -m is the same as the default.
-- -r, -t and -d are checked but no file can be given that time: missing
-- files are still created (with the time now), existing ones left alone.
-- Directories are left alone.

package.path = (ccnix and ccnix.lib or "/" .. fs.getDir(fs.getDir(shell.getRunningProgram())) .. "/lib/?.lua;") .. package.path  -- ccnix's lib/, or the one beside bin/
local cu = require("cu").init("touch", "touch [-acm] [-r ref_file | -t time | -d date_time] file...")
local scan = require("scan")
local text = require("text")
local opts, files = cu.getopt({ ... }, "acmr:t:d:")
if #files == 0 then cu.usageError("missing file operand") end
-- month, day, hour, minute and second (strings) all in POSIX's ranges?
local function inRange(mo, d, h, mi, s)
    mo, d, h, mi, s = tonumber(mo), tonumber(d), tonumber(h), tonumber(mi), tonumber(s)
    return mo and mo >= 1 and mo <= 12 and d >= 1 and d <= 31 and h <= 23 and mi <= 59 and s <= 60
end
-- exactly n digits next in scanner sc, stepped over; nil if they aren't there
local function readDigits(sc, n)
    local digits = ""
    for _ = 1, n do
        if not scan.isDigit(sc:peek()) then return nil end
        digits = digits .. sc:advance()
    end
    return digits
end

-- -d's date: digit digit digit digit+ "-" MM "-" DD ("T" | " ") hh ":" mm ":"
-- SS, then the rest; the five fields and the rest, or nil
local function readDate(text)
    local sc = scan.new(text)
    if #sc:readWhile(scan.isDigit) < 4 or not sc:accept("-") then return nil end
    local mo = readDigits(sc, 2)
    if not mo or not sc:accept("-") then return nil end
    local d = readDigits(sc, 2)
    if not d or not (sc:accept("T") or sc:accept(" ")) then return nil end
    local h = readDigits(sc, 2)
    if not h or not sc:accept(":") then return nil end
    local mi = readDigits(sc, 2)
    if not mi or not sc:accept(":") then return nil end
    local s = readDigits(sc, 2)
    if not s then return nil end
    return mo, d, h, mi, s, sc:rest()
end

-- what may follow -d's seconds: ("." | "," digit+)? "Z"?
local function isDateEnd(rest)
    local sc = scan.new(rest)
    if sc:accept(".") or sc:accept(",") then
        if sc:readWhile(scan.isDigit) == "" then return false end
    end
    sc:accept("Z")
    return sc:atEnd()
end

-- how many digits -t's [[CC]YY]MMDDhhmm can have
local T_LENGTHS = { [8] = true, [10] = true, [12] = true }

if opts.t then
    -- [[CC]YY]MMDDhhmm[.SS]: the digits, then "" or "." and two digits
    local sc = scan.new(opts.t)
    local digits = sc:readWhile(scan.isDigit)
    local secs = sc:rest()
    local md = digits:sub(-8)
    local ss = text.stripPrefix(secs, ".")
    local secsOk = secs == "" or (ss ~= nil and #ss == 2 and scan.isUnsigned(ss))
    if not T_LENGTHS[#digits] or not secsOk
        or not inRange(md:sub(1, 2), md:sub(3, 4), md:sub(5, 6), md:sub(7, 8), ss or "0") then
        cu.usageError("invalid date format '" .. opts.t .. "'")
    end
end
if opts.d then
    -- YYYY-MM-DDThh:mm:SS[.frac][Z] (a space can stand for the T)
    local mo, d, h, mi, s, rest = readDate(opts.d)
    if not (mo and inRange(mo, d, h, mi, s) and isDateEnd(rest)) then
        cu.usageError("invalid date format '" .. opts.d .. "'")
    end
end
if opts.r and not fs.exists(shell.resolve(opts.r)) then
    cu.fail(opts.r .. ": No such file or directory")
    return cu.exit()
end
-- bump the modification time of existing files?
local bump = not (opts.r or opts.t or opts.d) and (opts.m or not opts.a)

-- an fs error without its "/path: " prefix
local function why(e)
    local _, reason = text.cut(tostring(e), ": ")
    return reason or tostring(e)
end

for _, name in ipairs(files) do
    local path = shell.resolve(name)
    if name == "" then
        cu.fail(": No such file or directory")
    elseif (text.endsWith(name, "/") or text.endsWith(name, "\\")) and not fs.isDir(path) then
        -- "file/" names a directory, which can't be made here
        if fs.exists(path) then cu.fail(name .. ": Not a directory")
        elseif not opts.c then cu.fail(name .. ": No such file or directory") end
    elseif fs.isDir(path) then
        -- nothing CraftOS can change
    elseif fs.exists(path) then
        if bump then
            local f, e = io.open(path, "rb")
            local body = f and f:read("a") or ""
            if f then f:close(); f, e = io.open(path, "wb") end
            if f then f:write(body); f:close()
            else cu.fail(name .. ": " .. why(e)) end
        end
    elseif not opts.c then
        local dir = fs.getDir(path)
        if dir ~= "" and not fs.isDir(dir) then
            cu.fail(name .. ": " .. (fs.exists(dir) and "Not a directory" or "No such file or directory"))
        else
            local f, e = io.open(path, "wb")
            if f then f:close() else cu.fail(name .. ": " .. why(e)) end
        end
    end
end
return cu.exit()
