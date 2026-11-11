-- help.lua -- the help pages, in ccnix's pager
--
--   help [topic]
--   help index
--
-- Shows a help page (intro if none is named): the ones CraftOS has, and
-- ccnix's (help/, which boot adds to the help path).  A page that fits on
-- the screen is printed; a longer one opens in the pager (pager.lua:
-- space/PgDn a page, j/k or the arrows a line, the mouse wheel, g/G the
-- top and the end, q to quit), wrapped to the screen.  The pager scrolls
-- what was on the screen up first, so the console's scrollback keeps the
-- command that opened it.  `help index` lists the topics.  When the
-- output isn't the screen, the page is copied out as it is.
--
-- It takes the place of CraftOS's help (boot makes `help` this), whose
-- viewer drew over the screen and cleared it on the way out.  Markdown
-- pages (.md) are shown as their text.

package.path = (ccnix and ccnix.lib or "/" .. fs.getDir(fs.getDir(shell.getRunningProgram())) .. "/lib/?.lua;") .. package.path  -- ccnix's lib/, or the one beside bin/
local cu = require("cu").init("help", "help [topic]")
local fileio = require("fileio")
local pager = require("pager")
local text = require("text")
local _, args = cu.getopt({ ... }, "")
local topic = args[1] or "intro"

if topic == "index" then
    local topics = help.topics()
    table.sort(topics)
    if not cu.isTerminal() then
        io.write(table.concat(topics, "\n"), "\n")
        return cu.exit()
    end
    -- as many columns as fit, filled across, as CraftOS's tabulate does
    local w = term.getSize()
    local widest = 0
    for _, t in ipairs(topics) do widest = math.max(widest, #t) end
    local per = math.max(1, math.floor((w + 2) / (widest + 2)))
    local lines, row = { "Help topics available:" }, {}
    for i, t in ipairs(topics) do
        row[#row + 1] = i % per == 0 and t or t .. string.rep(" ", widest + 2 - #t)
        if i % per == 0 or i == #topics then
            lines[#lines + 1] = text.trimEnd(table.concat(row))
            row = {}
        end
    end
    pager.page(lines)
    return cu.exit()
end

local file = help.lookup(topic)
local page = file and fileio.read(file)
if not page then
    cu.fail("No help available for " .. topic)
    return cu.exit()
end
if not cu.isTerminal() then
    io.write(page)
    return cu.exit()
end
pager.page(page, { wrap = true })
return cu.exit()
