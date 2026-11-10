-- xargs.lua -- run a command with arguments read from input (POSIX xargs)
--
--   xargs [-prtx] [-E eofstr | -0] [-I replstr | -L number | -n number] [-s size]
--         [utility [argument...]]
--
-- Reads arguments from standard input (from the keyboard: hold Ctrl+T to
-- end it) and runs utility (default echo) with the given arguments
-- followed by those, through the shell, so aliases and the path apply.
-- Input arguments are separated by blanks and newlines; '...' and "..."
-- quote within one line and a backslash escapes the next character.
--   -n number  at most number input arguments per run
--   -L number  each input line is one argument (a line ending in a blank
--              goes on into the next one); number of them per run
--   -I replstr one run per input line (leading blanks dropped), with every
--              replstr in the arguments replaced by the line
--   -s size    keep each command line shorter than size bytes
--   -0         arguments end at NUL bytes only, with no quoting
--   -E eofstr  an argument equal to eofstr ends the input
--   -r         don't run utility at all when the input is empty
--   -t         write each command to stderr before running it
--   -p         ask before each run (y runs it); implies -t
--   -x         stop if a command (with -n's number of arguments) would
--              not fit in -s size; there is no other length limit
-- Without -n, -L, -I or -s everything goes into one run.  The status is 0
-- if every run succeeded, 1 if one failed (or the input was bad), 127 if
-- utility was not found; a run ending with status 255 stops xargs.

package.path = (ccnix and ccnix.lib or "/" .. fs.getDir(fs.getDir(shell.getRunningProgram())) .. "/lib/?.lua;") .. package.path  -- ccnix's lib/, or the one beside bin/
local cu = require("cu").init("xargs", "xargs [-prtx] [-E eofstr | -0] "
    .. "[-I replstr | -L number | -n number] [-s size] [utility [argument...]]")
local scan = require("scan")
local text = require("text")
local convert = require("convert")
local opts, ops, order = cu.getopt({ ... }, "prtx0E:I:L:n:s:")
local mode, count, repl = nil, nil, nil     -- "I", "L" or "n" (the last one given)
for _, o in ipairs(order) do
    local c, v = o[1], o[2]
    if c == "I" or c == "L" or c == "n" then
        mode, count, repl = c, nil, nil
        if c == "I" then
            repl = v
            if v == "" then cu.usageError("empty replstr") end
        else
            count = convert.toInteger(v)
            if not count or count < 1 then cu.usageError("invalid number '" .. v .. "'") end
        end
    end
end
local size = opts.s and convert.toInteger(opts.s)
if opts.s and (not size or size < 1) then cu.usageError("invalid size '" .. opts.s .. "'") end
local eof = not opts["0"] and opts.E ~= "" and opts.E or nil
local lineMode = (mode == "I" or mode == "L") and not opts["0"]
local cmd = ops[1] or "echo"
local base = { table.unpack(ops, 2) }

-- Yield now and then, so long runs don't stop with "Too long without yielding".
local last = os.clock()
local function breathe()
    if os.clock() - last >= 2 then
        os.queueEvent("xargs"); os.pullEvent("xargs")
        last = os.clock()
    end
end

local isBlank = scan.oneOf(" \t")
local isSpecial = scan.oneOf(" \t'\"\\")     -- (a blank, a quote or a backslash)
local function notSpecial(c) return not isSpecial(c) end

-- Split one input line into arguments.  In line mode (-I, -L) the whole
-- line is one argument; cont is true when -L's line ends in a blank.
local function split(line)
    local args, parts, q, i, trail = {}, nil, nil, 1, 0
    local function add(s) parts = parts or {}; parts[#parts + 1] = s end
    if mode == "I" then     -- (the blanks before the line dropped)
        local sc = scan.new(line)
        sc:readWhile(isBlank)
        line = sc:rest()
    end
    while i <= #line do
        if q then
            local j = line:find(q, i, true)
            if not j then break end
            add(line:sub(i, j - 1))
            q, i, trail = nil, j + 1, 0
        else
            -- up to the next blank, quote or backslash (or the end)
            local sc = scan.new(line, i)
            sc:readWhile(notSpecial)
            local j = sc:pos()
            if j > i then add(line:sub(i, j - 1)); trail = 0 end
            local c = line:sub(j, j)
            if c == "'" or c == '"' then
                q, trail = c, 0
                add("")
            elseif c == "\\" then
                j = j + 1
                add(line:sub(j, j)); trail = 0
            elseif c ~= "" then         -- a blank
                if lineMode then add(c); trail = trail + 1
                elseif parts then args[#args + 1] = table.concat(parts); parts = nil end
            end
            i = j + 1
        end
    end
    if q then
        cu.fail("unmatched " .. (q == '"' and "double" or "single") .. " quote")
        cu.exit()
    end
    local cont = false
    if parts then
        local s = table.concat(parts)
        if mode == "L" and trail > 0 then s, cont = s:sub(1, #s - trail), true end
        args[#args + 1] = s
    end
    return args, cont
end

-- The input arguments as a queue: peek() is the next one (nil at the end
-- of the input), take() uses it up.
local input, queue, qi, done, carry = io.input(), {}, 1, false, nil
local function fill()
    while queue[qi] == nil and not done do
        breathe()
        queue, qi = {}, 1
        if opts["0"] then
            -- each argument ends at a NUL (the last one may not have one)
            queue = text.split(cu.readAll(input), "\0", true)
            if queue[#queue] == "" then queue[#queue] = nil end
            done = true
        else
            local line = cu.readLine(input)
            if not line then
                queue[1], carry, done = carry, nil, true
            else
                local args, cont = split(line)
                if cont then carry = (carry or "") .. args[1]
                elseif carry and args[1] then args[1] = carry .. args[1]; carry = nil end
                if not cont then queue = args end
            end
        end
    end
end
local function peek()
    fill()
    local a = queue[qi]
    if a ~= nil and a == eof then queue, qi, done, a = {}, 1, true, nil end
    return a
end
local function take() qi = qi + 1 end

local function run(args)
    if not shell.resolveProgram(cmd) then
        cu.fail(cmd .. ": No such program")
        cu.exit(127)
    end
    local line = table.concat({ cmd, table.unpack(args) }, " ")
    if opts.p then
        io.stderr:write(line .. " ?...")
        local answer = cu.readLine(io.stdin)
        local first = answer and text.trim(answer):sub(1, 1)      -- (blanks before it are allowed)
        if not (first == "y" or first == "Y") then return end
    elseif opts.t then
        printError(line)
    end
    _G.POSIX_STATUS = nil
    local ok = shell.execute(cmd, table.unpack(args))
    -- a cu program leaves its status; a crash (even after cu.init) is 1
    local status = _G.POSIX_STATUS or 0
    if not ok and status == 0 then status = 1 end
    if status == 255 then
        cu.fail(cmd .. ": exited with status 255; aborting")
        cu.exit()
    end
    if status ~= 0 then cu.status = math.max(cu.status, 1) end
    breathe()
end

local function tooLong()
    cu.fail("argument line too long")
    cu.exit()
end

local runs = 0
while true do
    local args, len, n = {}, #cmd, 0
    local function push(a) args[#args + 1] = a; len = len + #a + 1 end
    if mode == "I" then
        local v = peek()
        if v == nil then break end
        take()
        for _, a in ipairs(base) do push((text.replace(a, repl, v))) end   -- (every replstr, as it is)
    else
        for _, a in ipairs(base) do push(a) end
        while not count or n < count do
            local a = peek()
            if a == nil or (size and len + #a + 1 >= size) then break end
            push(a); take()
            n = n + 1
        end
        -- peek() below only looks at what the loop above already read, so
        -- a full run goes ahead without waiting for more keyboard input
        if n == 0 then
            if peek() ~= nil then tooLong() end     -- the next argument can't fit
            if runs > 0 or opts.r then break end
        elseif opts.x and count and n < count and peek() ~= nil then
            tooLong()
        end
    end
    if size and len >= size then tooLong() end
    run(args)
    runs = runs + 1
end
return cu.exit()
