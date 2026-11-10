-- du.lua -- report disk usage (POSIX du)
--
--   du [-a|-s] [-kx] [-H|-L] [file...]
--
-- For each file (default "."), writes "<size> <path>" for every directory
-- under it, deepest first, ending with the file itself.  A directory's size
-- counts everything under it.  Sizes are in 512-byte blocks, or 1024-byte
-- blocks with -k, each file rounded up.
--   -a  list files too, not just directories
--   -s  only the total for each file operand
--   -x  stay on the operand's drive (don't count /rom or disks under it)
-- -H and -L (follow symbolic links) are accepted; CraftOS has no links.

package.path = (ccnix and ccnix.lib or "/" .. fs.getDir(fs.getDir(shell.getRunningProgram())) .. "/lib/?.lua;") .. package.path  -- ccnix's lib/, or the one beside bin/
local cu = require("cu").init("du", "du [-a|-s] [-kx] [-H|-L] [file...]")
local path = require("path")
local opts, files = cu.getopt({ ... }, "askxHL")
if opts.a and opts.s then cu.usageError("-a and -s can't be used together") end
local unit = opts.k and 1024 or 512
if #files == 0 then files = { "." } end

-- the size of p (shown as `shown`) in blocks, writing a line for each
-- entry that should get one
local seen = 0
local function walk(p, shown, drive, top)
    -- yield now and then, or a big tree trips "Too long without yielding"
    seen = seen + 1
    if seen % 200 == 0 then os.queueEvent("du"); os.pullEvent("du") end
    local n
    if fs.isDir(p) then
        n = 0
        local ok, names = pcall(fs.list, p)
        if not ok then cu.fail(shown .. ": " .. tostring(names)); names = {} end
        for _, name in ipairs(names) do
            local cp = fs.combine(p, name)
            if not opts.x or fs.getDrive(cp) == drive then
                n = n + walk(cp, path.join(shown, name), drive, false)
            end
        end
        if not opts.s or top then io.write(tostring(n), " ", shown, "\n") end
    else
        n = math.ceil(fs.getSize(p) / unit)
        if top or opts.a then io.write(tostring(n), " ", shown, "\n") end
    end
    return n
end

for _, f in ipairs(files) do
    local p = shell.resolve(f)
    if fs.exists(p) then walk(p, f, fs.getDrive(p), true)
    else cu.fail(f .. ": No such file or directory") end
end
return cu.exit()
