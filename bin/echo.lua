-- echo.lua -- write its arguments to standard output (POSIX/XSI echo)
--
--   echo [string...]
--
-- Writes the strings separated by single spaces, then a newline.  There
-- are no options: -n and -- are printed like any other string.  The XSI
-- escapes are understood: \a \b \f \n \r \t \v, \\ a backslash, \0num a
-- character by its octal code (up to 3 digits), and \c, which stops the
-- output there with no newline.  Any other backslash is written as is.
--
-- CraftOS extension: its shell has no redirects, so echo does them:
--   echo some text > notes.txt     writes the file (replacing it)
--   echo more text >> notes.txt    adds a line to the end
-- (">file" attached works too; the last one given wins.)  The shell splits
-- words on spaces and strips double quotes, so a quoted phrase becomes one
-- argument; use single quotes for Lua strings:
--   echo shell.run('autocompost') > /startup.lua
-- Under ccsh (_G.POSIX_SH set) the shell does the redirects, and a >
-- that reaches echo was quoted: it's printed like any other string.

package.path = (ccnix and ccnix.lib or "/" .. fs.getDir(fs.getDir(shell.getRunningProgram())) .. "/lib/?.lua;") .. package.path  -- ccnix's lib/, or the one beside bin/
local cu = require("cu").init("echo", "echo [string...] [> file | >> file]")
local scan = require("scan")
local text = require("text")

local isOctal = scan.oneOf("01234567")

local ESC = { a = "\a", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t", v = "\v", ["\\"] = "\\" }

local words, out, mode = {}, nil, nil
local args = { ... }
local i = 1
while i <= #args do
    local a = args[i]
    -- a redirect: ">" or ">>", then the file name or nothing (it's the next word)
    local op, rest = nil, nil
    if text.startsWith(a, ">>") then op, rest = ">>", a:sub(3)
    elseif text.startsWith(a, ">") then op, rest = ">", a:sub(2) end
    if op and not _G.POSIX_SH then
        mode = op == ">>" and "ab" or "wb"
        if rest ~= "" then out = rest
        else i = i + 1; out = args[i] end
        if not out then cu.usageError(op .. " needs a file name") end
    else
        words[#words + 1] = a
    end
    i = i + 1
end

-- expand the escapes; \c ends everything, newline included
local printed, stop = {}, false
local s = table.concat(words, " ")
local p = 1
while p <= #s do
    local b = s:find("\\", p, true)
    if not b then printed[#printed + 1] = s:sub(p); break end
    printed[#printed + 1] = s:sub(p, b - 1)
    local c = s:sub(b + 1, b + 1)
    if c == "c" then stop = true; break
    elseif c == "0" then
        -- \0 then up to three octal digits
        local sc, oct = scan.new(s, b + 2), ""
        while #oct < 3 and isOctal(sc:peek()) do oct = oct .. sc:advance() end
        printed[#printed + 1] = string.char(tonumber(oct ~= "" and oct or "0", 8) % 256)
        p = b + 2 + #oct
    elseif ESC[c] then
        printed[#printed + 1] = ESC[c]
        p = b + 2
    else
        printed[#printed + 1] = "\\"
        p = b + 1
    end
end
if not stop then printed[#printed + 1] = "\n" end
printed = table.concat(printed)

if not out then
    io.write(printed)
    return cu.exit()
end
local path = shell.resolve(out)
if fs.isDir(path) then cu.fail(out .. ": Is a directory"); return cu.exit() end
local f = io.open(path, mode)
if not f then cu.fail(out .. ": cannot write"); return cu.exit() end
f:write(printed)
f:close()
return cu.exit()
