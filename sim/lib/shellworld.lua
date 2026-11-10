-- sim/lib/shellworld.lua -- a CraftOS computer for the utility sims
--
--   local SW = require("shellworld")
--   local W = SW.new(PROJ)                 -- a turtle: 39 x 13 screen
--   W:file("notes.txt", "one\ntwo\n")
--   local r = W:run("cat", "notes.txt", { stdin = "typed\n" })
--   -- r.out, r.err (lines), r.status, r.ok
--
-- An in-memory file system (directories, a read-only /rom with stubs of
-- the stock programs, the repo's programs copied into /ccnix/bin
-- (or lib/, turtle/, pc/, as in the repo) as they are run or required),
-- the shell, io, term, os and the printing globals,
-- all as CraftOS has them.  A program runs in its own environment over
-- the real globals, as the shell runs it, so a world leaves the sim's own
-- globals alone (except term, keys and colours, which mock.termApi sets).
--
-- Standard input is the keyboard unless the run says pipe: read() (and so
-- io.stdin) takes the next line of opts.stdin, and when they run out the
-- user holds Ctrl+T (read raises "Terminated").  Writing to the screen
-- (write, print, io.stdout) is collected as text, not drawn; term.write
-- draws into W.T as mock.termApi does.  printError and io.stderr go to the
-- error lines.  read, write, print and printError are put in _G for the
-- length of a run, as the BIOS has them (print looks write up live), so a
-- shell can swap them; term.redirect works.  W.yieldEvents = true makes
-- os.pullEvent inside a coroutine yield for its event as the real one does.
--
-- W.modules: what require gives for a name instead of the repo's file.
-- It starts with lib/readline's stand-in, which writes the prompt and
-- calls read() (so a line of opts.stdin is a line typed, as before);
-- W.modules.readline = nil for the real one, on key events.

local M = require("mock")
local SW = {}

local hostOpen = io.open     -- for reading the repo's files

local ROM = {
    ["rom/programs"] = { "about", "alias", "apis", "cd", "clear", "copy", "delete", "drive", "edit", "eject",
        "exit", "gps", "help", "id", "import", "label", "list", "lua", "mkdir", "monitor", "motd", "move",
        "peripherals", "programs", "reboot", "redstone", "rename", "set", "shell", "shutdown", "time", "type" },
    ["rom/programs/http"] = { "pastebin", "wget" },
    ["rom/programs/turtle"] = { "craft", "dance", "equip", "excavate", "go", "refuel", "tunnel", "turn", "unequip" },
    ["rom/programs/rednet"] = { "chat", "repeat" },
    ["rom/programs/fun"] = { "adventure", "dj", "hello", "speaker", "worm" },
}
local ALIASES = { ls = "list", dir = "list", cp = "copy", mv = "move", rm = "delete", clr = "clear",
                  rs = "redstone", sh = "shell" }
-- a plain turtle's path (rom/startup.lua: rednet and fun are for non-turtles)
local PATH = ".:/rom/programs:/rom/programs/http:/rom/programs/turtle:/ccnix/bin:/ccnix/turtle"
-- where the repo keeps its Lua files, in the order a name is looked for
local REPO_DIRS = { "bin", "lib", "turtle", "pc" }

-- A path as fs keeps it: root-relative, no "." or "..", no illegal
-- characters ("*" kept only for patterns).
local function clean(p, wild)
    p = p:gsub("\\", "/"):gsub(wild and "[%c\"<>:?|]" or "[%c\"<>:?|*]", "")
    local out = {}
    for s in p:gmatch("[^/]+") do
        local seg = s:match("^%s*(.-)%s*$")
        if seg:match("^%.%.+$") then
            if #out > 0 and out[#out] ~= ".." then out[#out] = nil else out[#out + 1] = ".." end
        elseif seg ~= "." and seg ~= "" then
            out[#out + 1] = seg
        end
    end
    return table.concat(out, "/")
end
SW.clean = clean

local function parentOf(p) return p:match("^(.*)/[^/]*$") or "" end
local function isRom(p) return p == "rom" or p:sub(1, 4) == "rom/" end
local function under(p, dir) return dir == "" or p == dir or p:sub(1, #dir + 1) == dir .. "/" end

-- "a\nb\n" -> { "a", "b" }
local function splitLines(s)
    local t = {}
    if s == nil or s == "" then return t end
    if s:sub(-1) ~= "\n" then s = s .. "\n" end
    for l in s:gmatch("([^\n]*)\n") do t[#t + 1] = l end
    return t
end
SW.splitLines = splitLines

local function join(...)
    local t = {}
    for i = 1, select("#", ...) do t[#t + 1] = tostring(select(i, ...)) end
    return table.concat(t, "\t")
end

--------------------------------------------------------------------------
-- fs handles
--------------------------------------------------------------------------
-- A read handle over `data`: readLine drops "\n" (and the "\r" of "\r\n"),
-- readLine(true) keeps them; read() is a byte (a number in binary mode).
local function reader(data, binary)
    local pos, closed = 1, false
    local h = {}
    local function live() if closed then error("attempt to use a closed file", 3) end end
    function h.readLine(keep)
        live()
        if pos > #data then return nil end
        local e = data:find("\n", pos, true)
        local l
        if e then
            l = data:sub(pos, e - 1)
            pos = e + 1
            if keep then l = l .. "\n" elseif l:sub(-1) == "\r" then l = l:sub(1, -2) end
        else
            l = data:sub(pos)
            pos = #data + 1
        end
        return l
    end
    function h.readAll()
        live()
        local s = data:sub(pos)
        pos = #data + 1
        return s
    end
    function h.read(n)
        live()
        if pos > #data then return nil end
        if n == nil then
            local b = data:sub(pos, pos)
            pos = pos + 1
            return binary and b:byte() or b
        end
        local s = data:sub(pos, pos + n - 1)
        pos = pos + #s
        return s
    end
    function h.seek(whence, off)
        live()
        whence, off = whence or "cur", off or 0
        local base = ({ set = 0, cur = pos - 1, ["end"] = #data })[whence]
        if not base then error("bad argument #1 to 'seek' (invalid option '" .. tostring(whence) .. "')", 2) end
        if base + off < 0 then return nil, "Position is negative" end
        pos = base + off + 1
        return base + off
    end
    function h.close() live(); closed = true end
    return h
end

-- A write handle appending to W.files[p] as it goes.  In binary mode a
-- number is written as one byte (as CC:Tweaked does), otherwise as text.
local function writer(W, p, binary)
    local closed = false
    local h = {}
    local function live() if closed then error("attempt to use a closed file", 3) end end
    function h.write(s)
        live()
        if type(s) == "number" and binary then s = string.char(math.floor(s) % 256)
        elseif type(s) ~= "string" and type(s) ~= "number" then
            error("bad argument #1 (string expected, got " .. type(s) .. ")", 2)
        end
        W.files[p] = (W.files[p] or "") .. tostring(s)
        W.mtime[p] = W:ms()
    end
    function h.writeLine(s) h.write(tostring(s)); h.write("\n") end
    function h.flush() live() end
    function h.close() live(); closed = true end
    return h
end

--------------------------------------------------------------------------
-- fs
--------------------------------------------------------------------------
local function fsApi(W)
    local fs = {}
    local function mkdirs(p)
        if p == "" or W.dirs[p] then return end
        mkdirs(parentOf(p))
        W.dirs[p], W.ctime[p], W.mtime[p] = true, W:ms(), W:ms()
    end
    W.mkdirs = mkdirs
    local function err(p, msg) error("/" .. p .. ": " .. msg, 3) end
    local function children(p)
        local t, pre = {}, p == "" and "" or p .. "/"
        local function add(k)
            if k ~= "" and k ~= p and k:sub(1, #pre) == pre and not k:find("/", #pre + 1, true) then
                t[#t + 1] = k:sub(#pre + 1)
            end
        end
        for k in pairs(W.files) do add(k) end
        for k in pairs(W.dirs) do add(k) end
        table.sort(t)
        return t
    end
    -- every path at or under p
    local function tree(p)
        local t = {}
        for k in pairs(W.files) do if under(k, p) then t[#t + 1] = k end end
        for k in pairs(W.dirs) do if k ~= "" and under(k, p) then t[#t + 1] = k end end
        table.sort(t)
        return t
    end

    function fs.combine(a, ...)
        local parts = { a, ... }
        for i, s in ipairs(parts) do
            if type(s) ~= "string" then error("bad argument #" .. i .. " (string expected, got " .. type(s) .. ")", 2) end
        end
        return clean(table.concat(parts, "/"), true)
    end
    function fs.getName(p) p = clean(p, true); return p == "" and "root" or p:match("([^/]*)$") end
    function fs.getDir(p) p = clean(p, true); if p == "" then return ".." end return parentOf(p) end
    function fs.exists(p) p = clean(p); return W.files[p] ~= nil or W.dirs[p] ~= nil end
    function fs.isDir(p) return W.dirs[clean(p)] == true end
    function fs.isReadOnly(p) return isRom(clean(p)) end
    function fs.isDriveRoot(p) p = clean(p); return p == "" or p == "rom" end
    function fs.list(p)
        p = clean(p)
        if not W.dirs[p] then err(p, "Not a directory") end
        return children(p)
    end
    function fs.getSize(p)
        p = clean(p)
        if W.files[p] then return #W.files[p] end
        if W.dirs[p] then return 0 end
        err(p, "No such file")
    end
    function fs.getDrive(p)
        p = clean(p)
        if not fs.exists(p) then return nil end
        return isRom(p) and "rom" or "hdd"
    end
    function fs.getCapacity(p) if isRom(clean(p)) then return nil end return W.capacity end
    function fs.getFreeSpace(p)
        if isRom(clean(p)) then return 0 end
        local used = 0
        for k, v in pairs(W.files) do if not isRom(k) then used = used + #v end end
        return math.max(0, W.capacity - used)
    end
    function fs.attributes(p)
        p = clean(p)
        if not fs.exists(p) then err(p, "No such file") end
        local m = W.mtime[p] or 0
        return { size = W.files[p] and #W.files[p] or 0, isDir = W.dirs[p] == true, isReadOnly = isRom(p),
                 created = W.ctime[p] or m, modified = m, modification = m }
    end
    function fs.makeDir(p)
        p = clean(p)
        if isRom(p) then err(p, "Access denied") end
        if W.files[p] then err(p, "File exists") end
        mkdirs(p)
    end
    function fs.delete(p)
        p = clean(p)
        if p == "" or isRom(p) then err(p, "Access denied") end
        for _, k in ipairs(tree(p)) do W.files[k], W.dirs[k], W.mtime[k], W.ctime[k] = nil, nil, nil, nil end
    end
    local function transfer(a, b, move)
        a, b = clean(a), clean(b)
        if (move and isRom(a)) or isRom(b) then err(move and isRom(a) and a or b, "Access denied") end
        if not fs.exists(a) then err(a, "No such file") end
        if fs.exists(b) then err(b, "File exists") end
        if W.dirs[a] and under(b, a) then
            error("Can't " .. (move and "move" or "copy") .. " a directory inside itself", 3)
        end
        mkdirs(parentOf(b))
        for _, k in ipairs(tree(a)) do
            local nk = b .. k:sub(#a + 1)
            if W.dirs[k] then mkdirs(nk) else W.files[nk] = W.files[k]; W.mtime[nk] = move and W.mtime[k] or W:ms() end
            W.ctime[nk] = W.ctime[nk] or W:ms()
        end
        if move then fs.delete(a) end
    end
    function fs.move(a, b) transfer(a, b, true) end
    function fs.copy(a, b) transfer(a, b, false) end
    function fs.find(pat)
        pat = clean(pat, true)
        local found = { "" }
        for seg in pat:gmatch("[^/]+") do
            local nxt = {}
            local lp = "^" .. seg:gsub("[%^%$%(%)%%%.%[%]%+%-%?]", "%%%0"):gsub("%*", ".*") .. "$"
            for _, base in ipairs(found) do
                if W.dirs[base] then
                    for _, name in ipairs(children(base)) do
                        if name:match(lp) then nxt[#nxt + 1] = base == "" and name or base .. "/" .. name end
                    end
                end
            end
            found = nxt
        end
        if pat == "" then return {} end
        table.sort(found)
        return found
    end
    function fs.open(p, mode)
        if type(p) ~= "string" then error("bad argument #1 (string expected, got " .. type(p) .. ")", 2) end
        p = clean(p)
        local m, b = (mode or ""):match("^([rwa])(b?)$")
        if not m then error("Unsupported mode", 2) end
        if p == ".." or p:sub(1, 3) == "../" then return nil, "/" .. p .. ": Invalid Path" end
        if m == "r" then
            if not W.files[p] then return nil, "/" .. p .. ": No such file" end
            return reader(W.files[p], b == "b")
        end
        if isRom(p) then return nil, "/" .. p .. ": Access denied" end
        if W.dirs[p] then return nil, "/" .. p .. ": Cannot write to directory" end
        mkdirs(parentOf(p))
        if m == "w" or not W.files[p] then W.files[p] = ""; W.ctime[p] = W:ms() end
        W.mtime[p] = W:ms()
        return writer(W, p, b == "b")
    end
    -- as CC:T's: the endings that complete path (from location); a
    -- directory with "/" (and bare, with includeDirs); hidden names only
    -- for a name that starts with a dot
    function fs.complete(path, location, includeFiles, includeDirs)
        if type(includeFiles) == "table" then
            includeFiles, includeDirs = includeFiles.include_files ~= false, includeFiles.include_dirs ~= false
        end
        if includeFiles == nil then includeFiles = true end
        if includeDirs == nil then includeDirs = true end
        local dirPart, name = path:match("^(.*/)([^/]*)$")
        if not dirPart then dirPart, name = "", path end
        local dir = dirPart:sub(1, 1) == "/" and fs.combine(dirPart, "") or fs.combine(location or "", dirPart)
        if not fs.isDir(dir) then return {} end
        local out = {}
        for _, n in ipairs(fs.list(dir)) do
            if n:sub(1, #name) == name and (n:sub(1, 1) ~= "." or name:sub(1, 1) == ".") then
                local rest = n:sub(#name + 1)
                if fs.isDir(fs.combine(dir, n)) then
                    out[#out + 1] = rest .. "/"
                    if includeDirs and rest ~= "" then out[#out + 1] = rest end
                elseif includeFiles and rest ~= "" then
                    out[#out + 1] = rest
                end
            end
        end
        return out
    end
    return fs
end

--------------------------------------------------------------------------
-- io over fs handles, as CC:T's io library behaves (as documented)
--------------------------------------------------------------------------
local function ioApi(W)
    local mt = { __name = "FILE*" }
    local H = {}
    mt.__index = H
    mt.__tostring = function(self) return self._closed and "file (closed)" or "file" end
    local function chk(self)
        if type(self) ~= "table" or getmetatable(self) ~= mt then
            error("bad argument #1 (FILE expected, got " .. type(self) .. ")", 3)
        end
        if self._closed then error("attempt to use a closed file", 3) end
    end
    local function make(handle) return setmetatable({ _handle = handle }, mt) end

    -- The methods, written from the documented io library (Lua's, as
    -- CC:T's io gives it over fs handles).  What a handle can do is what
    -- its fs handle has: a write handle has no readLine, the keyboard no
    -- readAll or read, the screen no close.

    -- close: the fs handle's close; a standard stream has none and stays open
    function H.close(self)
        chk(self)
        local handle = self._handle
        if not handle.close then return nil, "attempt to close standard stream" end
        self._closed = true
        handle.close()
        return true
    end
    function H.flush(self)
        chk(self)
        if self._handle.flush then self._handle.flush() end
        return true
    end

    -- read's formats, by letter: "l" a line, "L" a line with its "\n",
    -- "a" the rest ("" at the end, never nil), "n" a number (CC reads none:
    -- nil).  A number instead reads that many characters.  Each gives nil
    -- where the fs handle can't do it (the keyboard has no readAll).
    local FORMATS = {
        l = function(handle) if handle.readLine then return handle.readLine() end end,
        L = function(handle) if handle.readLine then return handle.readLine(true) end end,
        a = function(handle) if handle.readAll then return handle.readAll() or "" end end,
        n = function() return nil end,
    }
    -- the letter of a format: Lua 5.1 wrote them "*l", Lua 5.3 "l"; past
    -- the letter is ignored ("line" is "l")
    local function formatLetter(format)
        local at = 1
        if format:sub(at, at) == "*" then at = at + 1 end
        return format:sub(at, at)
    end
    -- one of read's arguments, the i-th; errors blame read's caller
    local function readOne(handle, format, i)
        if type(format) == "number" then
            if handle.read then return handle.read(format) end
            return nil
        end
        if type(format) ~= "string" then
            error("bad argument #" .. i .. " (string expected, got " .. type(format) .. ")", 3)
        end
        local reader = FORMATS[formatLetter(format)]
        if not reader then error("bad argument #" .. i .. " (invalid format)", 3) end
        return reader(handle)
    end

    -- read(...): a value for each format, "l" if none is given; at the
    -- first that gets nothing, it and the rest are nil
    function H.read(self, ...)
        chk(self)
        local handle = self._handle
        if not (handle.read or handle.readLine) then return nil, "Not opened for reading" end
        local formats = table.pack(...)
        if formats.n == 0 then
            if not handle.readLine then return end
            return handle.readLine()
        end
        local values = {}
        for i = 1, formats.n do
            local value = readOne(handle, formats[i], i)
            if not value then break end
            values[i] = value
        end
        return table.unpack(values, 1, formats.n)
    end

    -- lines(...): an iterator calling read with the same formats; one from
    -- io.lines(name) closes its file when it reaches the end
    function H.lines(self, ...)
        chk(self)
        if not self._handle.read then return nil, "file is not readable" end
        local formats = table.pack(...)
        return function()
            if self._closed then error("file is already closed", 2) end
            local got = table.pack(self:read(table.unpack(formats, 1, formats.n)))
            if got[1] == nil and self._autoclose then self:close() end
            return table.unpack(got, 1, got.n)
        end
    end

    function H.seek(self, whence, offset)
        chk(self)
        if not self._handle.seek then return nil, "file is not seekable" end
        return self._handle.seek(whence, offset)
    end
    function H.setvbuf() end

    -- write(...): strings and numbers, in order; the file, to chain
    function H.write(self, ...)
        chk(self)
        local handle = self._handle
        if not handle.write then return nil, "file is not writable" end
        local values = table.pack(...)
        for i = 1, values.n do
            local kind = type(values[i])
            if kind ~= "string" and kind ~= "number" then
                error("bad argument #" .. i .. " (string or number expected, got " .. kind .. ")", 2)
            end
            handle.write(values[i])
        end
        return self
    end

    local io = { make = make }
    io.stdin = make({ readLine = function(...) return W.kbRead(...) end })
    io.stdout = make({ write = function(s) W._tty[#W._tty + 1] = tostring(s) end })
    io.stderr = make({ write = function(s) W._err[#W._err + 1] = tostring(s) end })
    W.curIn, W.curOut = io.stdin, io.stdout

    function io.open(name, mode)
        if type(name) ~= "string" then error("bad argument #1 (string expected, got " .. type(name) .. ")", 2) end
        local f, e = W.fs.open(name, mode or "r")
        if not f then return nil, e end
        return make(f)
    end
    function io.lines(name, ...)
        if name ~= nil and type(name) ~= "string" then
            error("bad argument #1 (string or nil expected, got " .. type(name) .. ")", 2)
        end
        if name then
            local f, e = io.open(name, "r")
            if not f then error(e, 2) end
            f._autoclose = true
            return f:lines(...)
        end
        return W.curIn:lines(...)
    end
    local function pick(file, mode, cur)
        if type(file) == "string" then
            local f, e = io.open(file, mode)
            if not f then error(e, 3) end
            W[cur] = f
        elseif type(file) == "table" and getmetatable(file) == mt then
            W[cur] = file
        elseif file ~= nil then
            error("bad argument #1 (FILE expected, got " .. type(file) .. ")", 3)
        end
        return W[cur]
    end
    function io.input(file) return pick(file, "r", "curIn") end
    function io.output(file) return pick(file, "wb", "curOut") end
    function io.read(...) return W.curIn:read(...) end
    function io.write(...) return W.curOut:write(...) end
    function io.close(f) if f == nil then return W.curOut:close() end return f:close() end
    function io.flush() return W.curOut:flush() end
    function io.type(o)
        if type(o) == "table" and getmetatable(o) == mt then return o._closed and "closed file" or "file" end
        return nil
    end
    return io
end

--------------------------------------------------------------------------
-- shell
--------------------------------------------------------------------------
-- shell.run's words, written from the shell's documented behaviour: its
-- arguments joined with spaces, then cut into words at spaces and tabs.
-- Text in double quotes is one word as it stands, spaces and all (a pair
-- with nothing in it is an empty word; a quote left open runs to the
-- end).  A quote also ends the word before it: a"b c" is two words, a
-- and "b c".
local function isBlank(c) return c == " " or c == "\t" end
local function tokenise(...)
    local line = table.concat({ ... }, " ")
    local pos = 1
    local function peek() return line:sub(pos, pos) end
    -- the text from pos up to (not including) the first character `stops`
    -- says yes to, or the end; pos is left on that character
    local function readUntil(stops)
        local start = pos
        while pos <= #line and not stops(peek()) do pos = pos + 1 end
        return line:sub(start, pos - 1)
    end
    local function isQuote(c) return c == "\"" end
    local function endsBareWord(c) return isBlank(c) or isQuote(c) end

    local words = {}
    while pos <= #line do
        local c = peek()
        if isBlank(c) then
            pos = pos + 1
        elseif isQuote(c) then
            pos = pos + 1                               -- past the opening quote
            words[#words + 1] = readUntil(isQuote)
            pos = pos + 1                               -- past the closing one (or the end)
        else
            words[#words + 1] = readUntil(endsBareWord)
        end
    end
    return words
end
SW.tokenise = tokenise

local function shellApi(W)
    local fs = W.fs
    local shell = {}
    function shell.dir() return W.cwd end
    function shell.setDir(d)
        if not fs.isDir(d) then error("Not a directory", 2) end
        W.cwd = fs.combine(d, "")
    end
    function shell.path() return W.path end
    function shell.setPath(p) W.path = p end
    function shell.resolve(p)
        local c = p:sub(1, 1)
        if c == "/" or c == "\\" then return fs.combine("", p) end
        return fs.combine(W.cwd, p)
    end
    local function file(p)
        if fs.exists(p) and not fs.isDir(p) then return p end
        if fs.exists(p .. ".lua") and not fs.isDir(p .. ".lua") then return p .. ".lua" end
    end
    function shell.resolveProgram(cmd)
        cmd = W.aliases[cmd] or cmd
        if cmd:find("/") or cmd:find("\\") then return file(shell.resolve(cmd)) end
        for dir in W.path:gmatch("[^:]+") do
            local p = file(fs.combine(shell.resolve(dir), cmd))
            if p then return p end
        end
        return nil
    end
    function shell.programs(hidden)
        local seen, t = {}, {}
        for d in W.path:gmatch("[^:]+") do
            local dir = shell.resolve(d)
            if fs.isDir(dir) then
                for _, name in ipairs(fs.list(dir)) do
                    if not fs.isDir(fs.combine(dir, name)) and (hidden or name:sub(1, 1) ~= ".") then
                        local f = name:gsub("%.lua$", "")
                        if not seen[f] then seen[f] = true; t[#t + 1] = f end
                    end
                end
            end
        end
        table.sort(t)
        return t
    end
    function shell.aliases()
        local t = {}
        for k, v in pairs(W.aliases) do t[k] = v end
        return t
    end
    function shell.setAlias(a, p) W.aliases[a] = p end
    function shell.clearAlias(a) W.aliases[a] = nil end
    function shell.getRunningProgram() return W.stack[#W.stack] end
    function shell.execute(cmd, ...)
        local p = shell.resolveProgram(cmd)
        if not p then W.env0.printError("No such program"); return false end
        return (W:osRun(p, { ... }))
    end
    function shell.run(...)
        local words = tokenise(...)
        if not words[1] then return false end
        return shell.execute(table.unpack(words))
    end
    function shell.exit() end
    function shell.complete() return nil end
    function shell.completeProgram() return {} end
    function shell.setCompletionFunction() end
    function shell.getCompletionInfo() return {} end
    return shell
end

--------------------------------------------------------------------------
-- os and the screen
--------------------------------------------------------------------------
local function osApi(W)
    local T = W.T
    local function pull(raw, filter)
        -- W.yieldEvents: inside a coroutine, yield for the event as the
        -- real os.pullEvent does (a shell resuming the program gives it)
        if W.yieldEvents and coroutine.isyieldable() then
            local e = table.pack(coroutine.yield(filter))
            if e[1] == "terminate" and not raw then error("Terminated", 0) end
            return table.unpack(e, 1, e.n)
        end
        if W.onPull then W.onPull(W, filter) end
        for i, e in ipairs(T.events) do
            if filter == nil or e[1] == filter or e[1] == "terminate" then
                table.remove(T.events, i)
                if e[1] == "terminate" and not raw then error("Terminated", 0) end
                return table.unpack(e, 1, e.n or #e)
            end
        end
        error("os.pullEvent with no event scripted" .. (filter and (" (" .. filter .. ")") or ""))
    end
    local timer = 0
    return setmetatable({
        pullEvent = function(f) return pull(false, f) end,
        pullEventRaw = function(f) return pull(true, f) end,
        queueEvent = function(...) T.events[#T.events + 1] = table.pack(...) end,
        startTimer = function() timer = timer + 1; return timer end,
        cancelTimer = function() end,
        clock = function() return W.clock end,
        epoch = function(kind)
            if kind == "utc" or kind == "local" then return math.floor(W.now * 1000) end
            return math.floor(W.clock * 1000)
        end,
        time = function(a)
            if type(a) == "table" then return os.time(a) end
            if a == "utc" or a == "local" then return math.floor(W.now) end
            return 12.0      -- in-game noon
        end,
        date = function(fmt, t) return os.date(fmt or "%c", math.floor(t or W.now)) end,
        day = function() return 1 end,
        sleep = function(n) W:advance(n) end,
        getComputerID = function() return 1 end,
        computerID = function() return 1 end,
        getComputerLabel = function() return W.label end,
        computerLabel = function() return W.label end,
        setComputerLabel = function(l) W.label = l end,
        version = function() return "CraftOS 1.9" end,
        run = function(env, path, ...) return (W:osRun(clean(path), { ... }, env)) end,
        shutdown = function() error("os.shutdown called", 0) end,
        reboot = function() error("os.reboot called", 0) end,
    }, { __index = os })
end

-- What mock.termApi leaves out, as no-ops or near enough.
local function fillTerm(T)
    local fg, bg = "white", "black"
    local extra = {
        clear = function() for r = 1, T.h do T.rows[r] = string.rep(" ", T.w); T.inverse[r] = false end end,
        scroll = function(n)
            for _ = 1, n do table.remove(T.rows, 1); T.rows[T.h] = string.rep(" ", T.w) end
        end,
        setCursorBlink = function() end, getCursorBlink = function() return false end,
        getTextColour = function() return fg end, getBackgroundColour = function() return bg end,
        blit = function(s) term.write(s) end,
        current = function() return term end, native = function() return term end,
        redirect = function(t) return term end,
        setPaletteColour = function() end, getPaletteColour = function() return 0, 0, 0 end,
    }
    for k, v in pairs(extra) do if term[k] == nil then term[k] = v end end
    term.getTextColor, term.getBackgroundColor, term.setPaletteColor, term.getPaletteColor =
        term.getTextColour, term.getBackgroundColour, term.setPaletteColour, term.getPaletteColour
    local more = { backspace = 14, tab = 15, q = 16, enter = 28, leftCtrl = 29, d = 32, z = 44, c = 46, space = 57, rightCtrl = 157 }
    for k, v in pairs(more) do if keys[k] == nil then keys[k] = v end end
    colours.red, colours.yellow, colours.lightGrey, colours.grey = colours.red or "red", colours.yellow or "yellow",
        colours.lightGrey or "lightGrey", colours.grey or "grey"

    -- term.redirect as the term API does it: every term.x calls the
    -- current target's x; native() is the screen
    local native, target = {}, nil
    for k, v in pairs(term) do if type(v) == "function" then native[k] = v end end
    target = native
    for k in pairs(native) do term[k] = function(...) return target[k](...) end end
    term.redirect = function(t)
        for k in pairs(native) do
            if type(t[k]) ~= "function" then t[k] = function() error("Redirect object is missing method " .. k .. ".", 2) end end
        end
        local old = target
        target = t
        return old
    end
    term.current = function() return target end
    term.native = function() return native end
end

--------------------------------------------------------------------------
-- The world
--------------------------------------------------------------------------
local W_ = {}
W_.__index = W_

-- A new computer.  opts: w, h (screen, 39 x 13), capacity (bytes, 1e6),
-- now (unix seconds), files = { [path] = text }, cwd.
function SW.new(proj, opts)
    opts = opts or {}
    local W = setmetatable({
        proj = proj, files = {}, dirs = { [""] = true }, mtime = {}, ctime = {},
        now = opts.now or 1793188800, clock = 0, capacity = opts.capacity or 1000000,
        cwd = "", path = PATH, aliases = {}, stack = {}, progDir = "ccnix",
        typed = {}, _tty = {}, _err = {},
    }, W_)
    for k, v in pairs(ALIASES) do W.aliases[k] = v end
    W.kbRead = W:readFn()
    W.modules = { readline = SW.readlineStandIn() }
    -- the printing globals, put in _G while a session runs (as the BIOS
    -- has them there, so a shell can swap them); print and printError
    -- look write up live, as the BIOS ones do
    W.g = {
        read = W.kbRead,
        write = function(s)
            if type(s) ~= "string" and type(s) ~= "number" then
                error("bad argument #1 (string or number expected, got " .. type(s) .. ")", 2)
            end
            s = tostring(s)
            W._tty[#W._tty + 1] = s
            return select(2, s:gsub("\n", ""))
        end,
        print = function(...) return _G.write(join(...) .. "\n") end,
        printError = function(...) W._err[#W._err + 1] = join(...) .. "\n" end,
    }
    W.T = M.termApi(opts.w or 39, opts.h or 13)
    fillTerm(W.T)
    W.fs = fsApi(W)
    W.io = ioApi(W)
    W.shell = shellApi(W)
    W.os = osApi(W)
    for dir, names in pairs(ROM) do
        W.mkdirs(dir)
        for _, n in ipairs(names) do W.files[dir .. "/" .. n .. ".lua"] = "-- rom stub\n" end
    end
    W.mkdirs(W.progDir)
    W.env0 = W:env("", {})
    for p, text in pairs(opts.files or {}) do W:file(p, text) end
    if opts.cwd then W.shell.setDir(opts.cwd) end
    return W
end

function W_:ms() return math.floor(self.now * 1000) end
function W_:advance(n) n = n or 0; self.clock = self.clock + n; self.now = self.now + n end

-- Put a file in the world (parent directories made), or a directory.
function W_:file(p, text)
    p = clean(p)
    self.mkdirs(parentOf(p))
    self.files[p] = text
    self.ctime[p], self.mtime[p] = self.ctime[p] or self:ms(), self:ms()
end
function W_:dir(p) self.mkdirs(clean(p)) end
-- A file's text (nil if it isn't one).
function W_:read(p) return self.files[clean(p)] end

-- Copy <repo>/<dir>/<name>.lua (bin/, lib/, turtle/ or pc/) into the
-- same folder of /ccnix; its path there, or nil if the repo has no
-- such file.
function W_:install(name)
    for _, dir in ipairs(REPO_DIRS) do
        local f = hostOpen(self.proj .. "/" .. dir .. "/" .. name .. ".lua", "rb")
        if f then
            local text = f:read("a")
            f:close()
            local p = self.progDir .. "/" .. dir .. "/" .. name .. ".lua"
            self:file(p, text)
            return p
        end
    end
end

-- A path in /ccnix: the repo's file there copied in, if the repo has one.
function W_:installPath(p)
    local rel = p:sub(1, #self.progDir + 1) == self.progDir .. "/" and p:sub(#self.progDir + 2)
    if not rel or not rel:find("%.lua$") then return end
    local f = hostOpen(self.proj .. "/" .. rel, "rb")
    if not f then return end
    local text = f:read("a")
    f:close()
    self:file(p, text)
end

-- lib/readline's stand-in: its read(opts) as read() (the next line of
-- opts.stdin, the history and completion noted as read() notes them).
function SW.readlineStandIn()
    return {
        read = function(opts)
            opts = opts or {}
            if opts.prompt then _G.write(opts.prompt) end
            local ok, line = pcall(_G.read, nil, opts.history, opts.complete)
            if ok then return line end
            if line == "Terminated" then return nil, "terminate" end
            error(line, 0)
        end,
    }
end

-- read(): the next line typed (opts.stdin); none left, the user holds Ctrl+T.
function W_.readFn(W)
    return function(replace, history, completeFn)
        if replace ~= nil and type(replace) ~= "string" then
            error("bad argument #1 (string expected, got " .. type(replace) .. ")", 3)
        end
        if history then W.history = { table.unpack(history) } end
        if completeFn then W.completer = completeFn end     -- (a sim can try it: W.completer("cat no"))
        if #W.typed == 0 then error("Terminated", 0) end
        return table.remove(W.typed, 1)
    end
end

-- require for code in directory `dir`, as cc.require does it: each
-- program its own package.loaded; for a program in /ccnix, a name
-- missing there is copied in from the repo first.
function W_:makeRequire(env, dir)
    local W = self
    local package = { loaded = {}, preload = {},
                      path = "?;?.lua;?/init.lua;/rom/modules/main/?;/rom/modules/main/?.lua;/rom/modules/main/?/init.lua" }
    local function find(rel)
        for pat in package.path:gmatch("[^;]+") do
            local p = pat:gsub("%?", rel)
            p = p:sub(1, 1) == "/" and clean(p) or W.fs.combine(dir, p)
            if not W.files[p] then W:installPath(p) end      -- (the repo's files are all there, as on disk)
            if W.files[p] then return p end
        end
    end
    local function require(name)
        if package.loaded[name] ~= nil then return package.loaded[name] end
        if W.modules[name] ~= nil then return W.modules[name] end
        if package.preload[name] then                         -- (cc.require looks there first too)
            local r = package.preload[name](name, ":preload:")
            if r == nil then r = true end
            package.loaded[name] = r
            return r
        end
        local rel = name:gsub("%.", "/")
        local p = find(rel)
        if not p and (dir .. "/"):sub(1, #W.progDir + 1) == W.progDir .. "/" and W:install(rel) then
            p = find(rel)
        end
        if not p then error("module '" .. name .. "' not found", 2) end
        local fn, e = load(W.files[p], "@/" .. p, "t", env)
        if not fn then error(e, 0) end
        local r = fn(name, p)
        if r == nil then r = true end
        package.loaded[name] = r
        return r
    end
    return require, package
end

-- A program's environment: the world's APIs over the real globals.
function W_:env(path, args)
    local W = self
    local env = setmetatable({}, { __index = _G })
    env.fs, env.io, env.shell, env.os, env.term = W.fs, W.io, W.shell, W.os, term
    env.multishell = W.multishell       -- nil: a turtle with no tabs, unless a sim gives one
    env.sleep = function(n) W:advance(n) end
    env.loadfile = function(p, mode, e)
        if type(mode) == "table" and e == nil then mode, e = nil, mode end
        local text = W.files[clean(p)]
        if not text then return nil, "File not found" end
        return load(text, "@/" .. clean(p), mode, e or W:env(clean(p), {}))
    end
    env.dofile = function(p)
        local fn, e = env.loadfile(p)
        if not fn then error(e, 2) end
        return fn()
    end
    env.require, env.package = W:makeRequire(env, parentOf(path))
    env.arg = { [0] = path }
    for i, a in ipairs(args) do env.arg[i] = a end
    return env
end

-- os.run: the program at `path` in its own environment; a real error is
-- printed (as os.run does) and returned.  ok, err.
function W_:osRun(path, args, env)
    local text = self.files[path]
    if not text then self.env0.printError("File not found"); return false, "File not found" end
    env = env or self:env(path, args)
    local fn, e = load(text, "@/" .. path, "t", env)
    if not fn then self.env0.printError(e); return false, e end
    self.stack[#self.stack + 1] = path
    local ok, err = pcall(fn, table.unpack(args))
    self.stack[#self.stack] = nil
    if not ok and err ~= nil and err ~= "" then self.env0.printError(tostring(err)) end
    return ok, err
end

-- Set up a run's input and output, do `body`, collect what came of it.
function W_:session(opts, body)
    opts = opts or {}
    if opts.cwd then self.shell.setDir(opts.cwd) end
    local tty, errs, pipe = {}, {}, {}
    self._tty, self._err = tty, errs
    local pin, pout = opts.pipe or opts.pipeIn, opts.pipe or opts.pipeOut
    self.typed = pin and {} or splitLines(opts.stdin)
    self.curIn = pin and self.io.make(reader(opts.stdin or "", false)) or self.io.stdin
    self.curOut = pout and self.io.make({ write = function(s) pipe[#pipe + 1] = tostring(s) end, flush = function() end })
        or self.io.stdout
    self.T.events = {}
    for i, e in ipairs(opts.events or {}) do self.T.events[i] = e end
    self.onPull = opts.onPull
    _G.POSIX_STATUS = nil
    local saved = {}
    for k, v in pairs(self.g) do saved[k] = rawget(_G, k); _G[k] = v end

    local ok, e, value = body()

    for k in pairs(self.g) do _G[k] = saved[k] end
    local status
    if ok then status = _G.POSIX_STATUS or 0
    elseif e == "" then ok, status = true, _G.POSIX_STATUS or 1
    else status = 1 end
    self.curIn, self.curOut = self.io.stdin, self.io.stdout
    self.onPull = nil
    local errText = table.concat(errs)
    local r = {
        out = table.concat(pout and pipe or tty), tty = table.concat(tty),
        err = splitLines(errText), errText = errText,
        status = status, ok = ok, error = (not ok) and tostring(e) or nil, value = value,
        events = self.T.events, typed = self.typed,
    }
    return r
end

-- Run the repo's <prog>.lua (copied in fresh) with these arguments; a
-- table last is the options: stdin = text, pipe / pipeIn / pipeOut,
-- events = { {"char", "q"}, ... }, onPull = function(W, filter), cwd.
function W_:run(prog, ...)
    local args = { ... }
    local opts = type(args[#args]) == "table" and table.remove(args) or {}
    local path = self:install(prog) or error("no such program in the repo: " .. prog, 2)
    return self:session(opts, function() return self:osRun(path, args) end)
end

-- Run a command line through the world's shell (aliases, the path,
-- quoting), as typed at the prompt; a repo program of the command's name
-- is copied into /ccnix first.  Same result as run.
function W_:sh(line, opts)
    return self:session(opts, function()
        local words = tokenise(line)
        if words[1] and not words[1]:find("[/\\]") then self:install(words[1]) end
        local p = words[1] and self.shell.resolveProgram(words[1])
        if not p then self.env0.printError("No such program"); return false, "No such program" end
        return self:osRun(p, { table.unpack(words, 2) })
    end)
end

-- fn(env) inside the world, as if it were a program in /ccnix/bin
-- (env.require("cu") works); r.value is what it returned.
function W_:call(fn, opts)
    return self:session(opts, function()
        local env = self:env(self.progDir .. "/bin/call.lua", {})
        env.package.path = "/" .. self.progDir .. "/lib/?.lua;" .. env.package.path
        local ok, e = pcall(fn, env)
        if ok then return true, nil, e end
        if e ~= "" then self.env0.printError(tostring(e)) end
        return false, e
    end)
end

return SW
