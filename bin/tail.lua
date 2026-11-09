-- tail.lua -- copy the last part of a file to standard output (POSIX tail)
--
--   tail [-f] [-c number | -n number] [file...]
--   tail -r [-n number] [file...]
--
-- Writes the last 10 lines of the file, or of standard input when there
-- is no file or it is "-" (from the keyboard: hold Ctrl+T to end it).
--   -n number   the last `number` lines; "+number" starts at that line
--   -c number   the same in bytes; "+number" starts at that byte
-- (A plain or "-" number counts from the end; the last -c or -n wins.)
--   -r   write the lines last first: all of them, or the last -n number.
-- "tail -5" is taken as "tail -n 5".  With several files each gets a
-- "==> name <==" header, as head does.
--   -f   follow: after the end, keep checking the (last) file once a
--        second and write whatever is added to it.  Hold Ctrl+T to stop.
--        It does nothing when reading standard input.

package.path = (ccnix and ccnix.lib or "/" .. fs.getDir(fs.getDir(shell.getRunningProgram())) .. "/lib/?.lua;") .. package.path  -- ccnix's lib/, or the one beside bin/
local cu = require("cu").init("tail", "tail [-f | -r] [-c number | -n number] [file...]")
local scan = require("scan")
local args = { ... }
if args[1] and args[1]:sub(1, 1) == "-" and cu.isInt(args[1]) then     -- -number
    args[1] = "-n" .. args[1]:sub(2)
end
local opts, files, order = cu.getopt(args, "fc:n:r")

-- The last -c or -n: bytes?, the count, and whether it counts from the start.
local bytes, count, fromStart = false, 10, false
if opts.r then count, fromStart = 1, true end      -- -r alone: every line
for _, o in ipairs(order) do
    if o[1] == "c" or o[1] == "n" then
        local n = cu.int(o[2])
        if not n then cu.usageError("invalid number: " .. o[2]) end
        bytes, count, fromStart = o[1] == "c", math.min(math.abs(n), 0x7fffffff), o[2]:sub(1, 1) == "+"
    end
end
if opts.r and (opts.c or opts.f) then
    cu.usageError("-r can't be used with -" .. (opts.c and "c" or "f"))
end

-- The part of text s that tail writes.
local function part(s)
    if bytes then
        if fromStart then return s:sub(math.max(count, 1)) end
        return count == 0 and "" or s:sub(-count)
    end
    if count == 0 and not fromStart then return "" end
    -- where each line starts; a last line without a newline still counts
    local starts, p = {}, 1
    while p <= #s do
        starts[#starts + 1] = p
        local e = s:find("\n", p, true)
        if not e then break end
        p = e + 1
    end
    local i = fromStart and math.max(count, 1) or #starts - count + 1
    local at = starts[math.max(i, 1)]
    return at and s:sub(at) or ""
end

-- The lines of s last first (a last line without a newline gets one).
local function reverse(s)
    local t, r = scan.split(s, "\n", true), {}
    if t[#t] == "" then t[#t] = nil end     -- (after the last newline: not a line)
    for i = #t, 1, -1 do r[#r + 1] = t[i] .. "\n" end
    return table.concat(r)
end

local first = true
cu.each(files, function(h, name)
    if #files > 1 then
        io.write(first and "" or "\n", "==> ", name, " <==\n")
    end
    first = false
    local s = part(cu.readAll(h))
    io.write(opts.r and reverse(s) or s)
end)

-- Follow the last file: poll its size each second, write what's new.
local name = files[#files]
if opts.f and name and name ~= "-" and fs.exists(shell.resolve(name))
        and not fs.isDir(shell.resolve(name)) then
    local path = shell.resolve(name)
    local size = fs.getSize(path)
    while true do
        local timer = os.startTimer(1)
        local ok, e, id
        repeat ok, e, id = pcall(os.pullEvent, "timer") until not ok or id == timer
        if not ok then
            if e == "Terminated" then break end
            error(e, 0)
        end
        local now = fs.exists(path) and fs.getSize(path) or 0
        if now < size then size = 0 end   -- truncated: start again
        if now > size then
            local h = io.open(path, "rb")
            if h then
                h:seek("set", size)
                io.write(h:read("a") or "")
                h:close()
            end
            size = now
        end
    end
end
return cu.exit()
