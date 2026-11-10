-- tee.lua -- copy standard input to standard output and to files (POSIX tee)
--
--   tee [-ai] [file...]
--
-- Every line read is written at once to standard output and to each file
-- (replacing them, or adding to their ends with -a).  "-" is a file named
-- "-", as POSIX says, not standard output.  A file that can't be opened is
-- reported and the copy goes on to the others; tee then exits 1.  From the
-- keyboard, hold Ctrl+T to end the input.  -i (ignore interrupts) is
-- accepted; CraftOS has no SIGINT, and Ctrl+T only ever ends the input.

package.path = (ccnix and ccnix.lib or "/" .. fs.getDir(fs.getDir(shell.getRunningProgram())) .. "/lib/?.lua;") .. package.path  -- ccnix's lib/, or the one beside bin/
local cu = require("cu").init("tee", "tee [-ai] [file...]")
local text = require("text")

-- io.open's message can start with the path and ": ": keep just the reason
local function reason(e)
    if text.startsWith(e, "/") then
        local _, rest = text.cut(e, ": ")
        if rest then return rest end
    end
    return e
end
local opts, files = cu.getopt({ ... }, "ai")

local outs = {}
for _, name in ipairs(files) do
    local path = shell.resolve(name)
    local h, e
    if fs.isDir(path) then e = "Is a directory"
    elseif fs.isReadOnly(path) then e = "Permission denied"
    else h, e = io.open(path, opts.a and "ab" or "wb") end
    if h then outs[#outs + 1] = h else cu.fail(name .. ": " .. reason(tostring(e or "cannot open"))) end
end

local input, n = io.input(), 0
for l in function() return cu.readLine(input, true) end do
    io.write(l)
    for _, h in ipairs(outs) do h:write(l); h:flush() end
    -- a long piped input never waits for a key: yield now and then
    n = n + 1
    if n % 256 == 0 and input ~= io.stdin then os.queueEvent("tee"); os.pullEvent("tee") end
end
for _, h in ipairs(outs) do h:close() end
return cu.exit()
