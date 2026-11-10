-- cu.lua -- the shared core of the POSIX-style command-line utilities
--
--   local cu = require("cu").init("cat", "cat [-u] [file...]")
--   local opts, files = cu.getopt({ ... }, "u")
--   for line in cu.lines(files) do io.write(line, "\n") end
--   return cu.exit()
--
-- Options are lib/getopt's (the POSIX Utility Syntax Guidelines); a bad
-- one prints getopt's message and the usage line and exits with status 2.
--
-- Output goes to io.write (io.output()), diagnostics to printError as
-- "<name>: <message>", so a shell that can redirect io.input()/io.output()
-- gets pipes for free.  Input from the keyboard (io.stdin, which CraftOS
-- reads with read()) has no end of file: holding Ctrl+T ends it instead,
-- and only inside these helpers -- elsewhere Ctrl+T stops the program.
--
-- cu.exit(status) records the status in _G.POSIX_STATUS; a nonzero one
-- ends the program with error("", 0), which the stock shell takes as a
-- failure without printing anything.

local getopt = require("getopt")

local cu = {}

cu.name = "?"       -- the utility's name, the prefix of every message
cu.usage = nil      -- its usage line, shown after a usage error
cu.status = 0       -- the exit status so far (1 once an operand failed)

local stdinDone = false     -- Ctrl+T ended the keyboard input

function cu.init(name, usage)
    cu.name, cu.usage, cu.status = name, usage, 0
    stdinDone = false
    _G.POSIX_STATUS = 0
    return cu
end

function cu.err(msg) printError(cu.name .. ": " .. msg) end

-- Report a problem and remember a failure status (1 unless given), but
-- carry on: the status comes out at cu.exit().
function cu.fail(msg, status)
    cu.err(msg)
    cu.status = math.max(cu.status, status or 1)
end

-- End with `status` (default: the one remembered so far).  Zero returns,
-- so finish with `return cu.exit()`.
function cu.exit(status)
    status = status or cu.status
    _G.POSIX_STATUS = status
    if status ~= 0 then error("", 0) end
end

-- A usage error: the message (if any), the usage line, exit 2 (or status).
function cu.usageError(msg, status)
    if msg then cu.err(msg) end
    if cu.usage then printError("usage: " .. cu.usage) end
    cu.exit(status or 2)
end

-- getopt.parse(args, spec, long) (lib/getopt's header says what it reads
-- and returns: opts, operands, order), with a bad option made a usage
-- error: its message, the usage line, status 2 (or status).
function cu.getopt(args, spec, status, long)
    local opts, operands, order = getopt.parse(args, spec, long)
    if not opts then cu.usageError(operands, status) end
    return opts, operands, order
end

--------------------------------------------------------------------------
-- Input
--------------------------------------------------------------------------
-- Is output going to the screen (not redirected by a shell)?
function cu.isTerminal() return io.output() == io.stdout end

-- Is the file at `path` hidden from listings: a name starting with a dot,
-- or, with the fileserver's pool mounted, a member disk's own mount (/disk,
-- /disk2...: its files are in /jbod)?
function cu.hidden(path)
    if fs.getName(path):sub(1, 1) == "." then return true end
    local pool = fs.jbodPool
    -- (a pool mounted by an older jbod.lua, before a git pull, can't tell)
    return pool ~= nil and pool.isMember ~= nil and pool.isMember(path)
end

-- Is input coming from the keyboard?
function cu.isKeyboard() return io.input() == io.stdin end

-- The next line of handle h, without its newline (with it if keep), or
-- nil at the end.  The keyboard can only read "l"; Ctrl+T ends it.
function cu.readLine(h, keep)
    if h ~= io.stdin then return h:read(keep and "L" or "l") end
    if stdinDone then return nil end
    local ok, l = pcall(h.read, h, "l")
    if not ok then
        if l == "Terminated" then stdinDone = true; return nil end
        error(l, 0)
    end
    if l and keep then l = l .. "\n" end
    return l
end

-- The rest of handle h as one string ("" at the end).
function cu.readAll(h)
    if h ~= io.stdin then return h:read("a") or "" end
    local t = {}
    for l in function() return cu.readLine(h, true) end do t[#t + 1] = l end
    return table.concat(t)
end

-- Open an operand for reading: "-" is io.input(), anything else a file
-- relative to the shell's directory.  Nil (reported, status 1) when it
-- can't be read.
function cu.open(name)
    if name == "-" then return io.input() end
    local path = shell.resolve(name)
    if fs.isDir(path) then cu.fail(name .. ": Is a directory"); return nil end
    if not fs.exists(path) then cu.fail(name .. ": No such file or directory"); return nil end
    local h, e = io.open(path, "rb")
    if not h then cu.fail(name .. ": " .. tostring(e)) end
    return h
end

-- Close what cu.open opened (not the standard input).
function cu.close(h)
    if h and h ~= io.input() and h ~= io.stdin and io.type(h) == "file" then h:close() end
end

-- fn(handle, name) for each operand that opens ("-" if there are none);
-- fn returning false stops early.
function cu.each(operands, fn)
    if #operands == 0 then operands = { "-" } end
    for _, name in ipairs(operands) do
        local h = cu.open(name)
        if h then
            local r = fn(h, name)
            cu.close(h)
            if r == false then return end
        end
    end
end

-- Iterate over the lines of all the operands in turn ("-" if none):
-- yields line (newline kept if keep), operand name.
function cu.lines(operands, keep)
    if #operands == 0 then operands = { "-" } end
    local i, h, name = 0, nil, nil
    return function()
        while true do
            if h then
                local l = cu.readLine(h, keep)
                if l then return l, name end
                cu.close(h)
                h = nil
            end
            i = i + 1
            if i > #operands then return nil end
            name = operands[i]
            h = cu.open(name)
        end
    end
end

return cu
