-- head.lua -- copy the first part of files to standard output (POSIX head)
--
--   head [-c number | -n number] [file...]
--
-- Writes the first `number` lines (-n, 10 by default) or bytes (-c) of
-- each file; "-" or no files at all reads standard input (from the
-- keyboard: hold Ctrl+T to end it early).  The last -c or -n wins.  With
-- more than one file, each one starts with a "==> name <==" header, and a
-- blank line separates them.  A file that can't be read is reported and
-- skipped, and head exits 1 at the end.  "head -5" is taken as
-- "head -n 5", as most systems do.

package.path = (ccnix and ccnix.lib or "/" .. fs.getDir(fs.getDir(shell.getRunningProgram())) .. "/lib/?.lua;") .. package.path  -- ccnix's lib/, or the one beside bin/
local cu = require("cu").init("head", "head [-c number | -n number] [file...]")
local scan = require("scan")
local text = require("text")
local args = { ... }
-- the obsolete form: -number is -n number
local obsolete = args[1] and text.stripPrefix(args[1], "-")
if obsolete and scan.isUnsigned(obsolete) then args[1] = "-n" .. obsolete end
local opts, files, order = cu.getopt(args, "c:n:")

-- whole numbers, 0 or more; the last -c or -n given wins
local byteCount, lineCount = cu.number(opts, "c", nil, 0, true), cu.number(opts, "n", 10, 0, true)
local bytes = false
for _, o in ipairs(order) do bytes = o[1] == "c" end
local count = math.min(bytes and byteCount or lineCount, 0x7fffffff)

-- Copy the first `count` lines or bytes of h; yield now and then so a
-- long copy to the screen can't run "too long without yielding".
local function copy(h)
    local left = count
    while left > 0 do
        local s
        if bytes and h ~= io.stdin then
            s = h:read(math.min(left, 4096))
        else
            s = cu.readLine(h, true)
        end
        if not s then return end
        if bytes then
            s = s:sub(1, left)
            left = left - #s
        else
            left = left - 1
        end
        io.write(s)
        cu.breathe()
    end
end

local first = true
cu.each(files, function(h, name)
    if #files > 1 then
        io.write(first and "" or "\n", "==> ", name, " <==\n")
    end
    first = false
    copy(h)
end)
return cu.exit()
