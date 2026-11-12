-- grep.lua -- print the lines that match a pattern (POSIX grep)
--
--   grep [-E|-F] [-c|-l|-q] [-inrsvx] -e patterns ... [-f file] ... [file...]
--   grep [-E|-F] [-c|-l|-q] [-inrsvx] patterns [file...]
--   grep -r pattern [dir...]          (the files under each dir, all the way down)
--
-- Patterns are basic regular expressions (-E: extended, -F: fixed
-- strings); a pattern list holds one pattern per line, and a line is
-- selected if any of them matches.  -e gives a list (repeatable), -f reads
-- one from a file.  -i ignores case, -x matches whole lines only, -v
-- selects the lines that do NOT match.  Output: the lines, prefixed with
-- "file:" when there are several files and "number:" with -n; -c prints a
-- count per file instead, -l the names of the files with a selected line,
-- -q nothing.  -s hides the messages about unreadable files.  No files (or
-- "-") reads standard input (the keyboard: hold Ctrl+T to end it).
-- -r (or -R: CC has no links to tell apart), as GNU's and BSD's grep
-- have it: a directory operand stands for every file under it, in name
-- order, each line prefixed with its file; no operands searches the
-- current directory (the names without "./").
-- Exit status: 0 a line was selected, 1 none, 2 an error (0 with -q if a
-- line was selected anyway).

package.path = (ccnix and ccnix.lib or "/" .. fs.getDir(fs.getDir(shell.getRunningProgram())) .. "/lib/?.lua;") .. package.path  -- ccnix's lib/, or the one beside bin/
local cu = require("cu").init("grep",
    "grep [-E|-F] [-c|-l|-q] [-inrsvx] [-e patterns] [-f file] [patterns] [file...]")
local regex = require("regex")
local text = require("text")
local path = require("path")
local opts, files, order = cu.getopt({ ... }, "EFRce:f:ilnqrsvx")

-- the pattern lists from -e and -f, in order; else the first operand
local ere, fixed, pats, given = false, false, {}, false
local function addList(s)
    for _, p in ipairs(text.split(s, "\n", true)) do pats[#pats + 1] = p end
end
for _, o in ipairs(order) do
    local c, v = o[1], o[2]
    if c == "E" then ere, fixed = true, false
    elseif c == "F" then ere, fixed = false, true
    elseif c == "e" then given = true; addList(v)
    elseif c == "f" then
        given = true
        local h = cu.open(v)
        if not h then return cu.exit(2) end
        for l in function() return cu.readLine(h) end do pats[#pats + 1] = l end
        cu.close(h)
    end
end
if not given then
    if #files == 0 then cu.usageError() end
    addList(table.remove(files, 1))
end

-- one test per pattern
local tests = {}
for _, p in ipairs(pats) do
    if fixed then
        local want = opts.i and p:lower() or p
        tests[#tests + 1] = function(l)
            if opts.i then l = l:lower() end
            if opts.x then return l == want end
            return text.contains(l, want)
        end
    else
        local re, err = regex.compile(p, { ere = ere, icase = opts.i })
        if not re then cu.err(err); return cu.exit(2) end
        tests[#tests + 1] = function(l) return re:test(l, opts.x) end
    end
end
local function selected(l)
    for _, t in ipairs(tests) do
        if t(l) then return not opts.v end
    end
    return opts.v == true
end

-- -r: each directory operand as the files under it ("" for none given:
-- the current directory, its names shown bare)
local tree = false
if opts.r or opts.R then
    local function walk(shown, real, out)
        local names = fs.list(real)
        table.sort(names)
        for _, name in ipairs(names) do
            local s, r = path.join(shown, name), fs.combine(real, name)
            if fs.isDir(r) then walk(s, r, out) else out[#out + 1] = s end
            cu.breathe()
        end
    end
    local list = {}
    for _, f in ipairs(#files > 0 and files or { "" }) do
        local real = f ~= "-" and shell.resolve(f == "" and "." or f)
        if real and fs.isDir(real) then
            tree = true
            walk(f, real, list)
        else
            list[#list + 1] = f
        end
    end
    files = list
    if #files == 0 then return cu.exit(1) end       -- (empty directories: no lines, and not the keyboard)
end

local mode = opts.q and "q" or opts.l and "l" or opts.c and "c"
local multi, found = #files > 1 or tree, false
if opts.s then cu.err = function() end end   -- unreadable files: quietly
cu.each(files, function(h, name)
    local label = name == "-" and "(standard input)" or name
    local prefix = multi and label .. ":" or ""
    local n, count = 0, 0
    for line in function() return cu.readLine(h) end do
        n = n + 1
        -- a big file takes a while: yield now and then, or CC stops us
        -- (the keyboard yields by itself)
        if h ~= io.stdin then cu.breathe() end
        if selected(line) then
            count, found = count + 1, true
            if mode == "q" then return false end
            if mode == "l" then break end
            if not mode then
                io.write(prefix, opts.n and tostring(n) .. ":" or "", line, "\n")
            end
        end
    end
    if mode == "l" and count > 0 then io.write(label, "\n")
    elseif mode == "c" then io.write(prefix, tostring(count), "\n") end
end)

if found and opts.q then return cu.exit(0) end
if cu.status > 0 then return cu.exit(2) end
return cu.exit(found and 0 or 1)
