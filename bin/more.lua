-- more.lua -- show files a screenful at a time (POSIX more, a subset)
--
--   more [-cs] [-u] [file...]
--
-- Shows the files ("-" or none: standard input) in the pager (pager.lua:
-- space/PgDn a page, j/k or the arrows a line, h/l sideways, q to quit);
-- what fits on the screen is just printed.  With more than one file each
-- starts with its name between lines of colons.  -s squeezes runs of
-- blank lines into one; -c and -u are accepted (the pager always redraws
-- the whole screen and shows no underlining).  When the output isn't the
-- screen, more copies its input like cat.  A file that can't be read is
-- reported and skipped (exit status 1).
--
-- Not supported: -e, -i, -n number, -p command, -t tagstring, and more's
-- own commands (/ search, :n, v and so on); the pager's keys stand in.

package.path = (ccnix and ccnix.lib or "/" .. fs.getDir(fs.getDir(shell.getRunningProgram())) .. "/lib/?.lua;") .. package.path  -- ccnix's lib/, or the one beside bin/
local cu = require("cu").init("more", "more [-cs] [-u] [file...]")
local pager = require("pager")
local text = require("text")
local opts, files = cu.getopt({ ... }, "csu")

-- s with each run of blank lines made one: three or more newlines in a
-- row become two, and at the very start two or more become one
local function squeeze(s)
    local out, i = {}, 1
    while i <= #s do
        local nl = text.find(s, "\n", i)
        if not nl then out[#out + 1] = s:sub(i); break end
        out[#out + 1] = s:sub(i, nl - 1)
        local run = 1
        while s:sub(nl + run, nl + run) == "\n" do run = run + 1 end
        local keep = math.min(run, 2)
        if nl == 1 and run >= 2 then keep = 1 end
        out[#out + 1] = ("\n"):rep(keep)
        i = nl + run
    end
    return table.concat(out)
end

-- the text of one input, squeezed with -s
local function contents(h)
    local s = cu.readAll(h)
    if opts.s then s = squeeze(s) end
    return s
end

if not cu.isTerminal() then
    cu.each(files, function(h) io.write(contents(h)) end)
    return cu.exit()
end

local parts = {}
cu.each(files, function(h, name)
    if #files > 1 then parts[#parts + 1] = "::::::::::::::\n" .. name .. "\n::::::::::::::\n" end
    local s = contents(h)
    if s ~= "" and not text.endsWith(s, "\n") then s = s .. "\n" end
    parts[#parts + 1] = s
end)
local all = table.concat(parts)
if all ~= "" then pager.page(all) end
return cu.exit()
