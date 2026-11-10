-- tr.lua -- translate, squeeze or delete characters (POSIX tr)
--
--   tr [-c|-C] [-s] string1 string2
--   tr -s [-c|-C] string1
--   tr -d [-c|-C] string1
--   tr -ds [-c|-C] string1 string2
--
-- Copies standard input to standard output (from the keyboard: hold Ctrl+T
-- to end it), changing each character found in string1 into the one at
-- the same place in string2.  If string2 is shorter, its last character
-- is repeated.
--   -c, -C  use every character NOT in string1, in code order
--   -d      delete the characters of string1 instead
--   -s      squeeze a run of the same character into one, for the
--           characters of the last string given
-- In the strings: a-z is a range; [:alpha:] and the other classes (alnum
-- blank cntrl digit graph lower print punct space upper xdigit); [=c=] is
-- c; [c*n] is n copies of c in string2 ([c*] as many as fill it); escapes
-- \\ \a \b \f \n \r \t \v and \ooo (octal).  [:lower:] to [:upper:] (and
-- back) changes case.  The shell strips double quotes, so tr "a b" "_ _"
-- passes the spaces through.

package.path = (ccnix and ccnix.lib or "/" .. fs.getDir(fs.getDir(shell.getRunningProgram())) .. "/lib/?.lua;") .. package.path  -- ccnix's lib/, or the one beside bin/
local cu = require("cu").init("tr", "tr [-c|-C] [-ds] string1 [string2]")
local scan = require("scan")
local text = require("text")
local opts, ops = cu.getopt({ ... }, "cCds")
local comp = opts.c or opts.C
local want = (opts.d and opts.s or not opts.d and not opts.s) and 2 or 1
if opts.s and not opts.d and #ops == 2 then want = 2 end
if #ops ~= want then cu.usageError(#ops < want and "missing operand" or "extra operand") end

local ESC = { ["\\"] = "\\", a = "\a", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t", v = "\v" }
-- the classes, each a test on one character (bytes 0 to 127 are tried)
local function isGraph(c) return scan.isPrintable(c) and c ~= " " end
local CLASS = { alnum = scan.isAlnum, alpha = scan.isAlpha, blank = scan.oneOf(" \t"),
    cntrl = scan.isControl, digit = scan.isDigit,
    graph = isGraph, lower = scan.isLower, print = scan.isPrintable, punct = scan.isPunct,
    space = scan.isSpace, upper = scan.isUpper, xdigit = scan.isHexDigit }

-- one character (escapes allowed) at i: the character and the next index
local function char(s, i)
    local c = s:sub(i, i)
    if c ~= "\\" or i == #s then return c, i + 1 end
    -- \ooo: one to three octal digits
    local sc, oct = scan.new(s, i + 1), ""
    while #oct < 3 and scan.isOctalDigit(sc:peek()) do oct = oct .. sc:advance() end
    if oct ~= "" then return string.char(tonumber(oct, 8) % 256), i + 1 + #oct end
    c = s:sub(i + 1, i + 1)
    return ESC[c] or c, i + 2
end

-- "[:" letters ":]" at i: the class's name, or nil
local function className(s, i)
    local sc = scan.new(s, i)
    if not sc:accept("[:") then return nil end
    local name = sc:readWhile(scan.isAlpha)
    if name == "" or not sc:accept(":]") then return nil end
    return name
end

-- digits "]" at i (the n and the end of [c*n]): the digits ("" for none),
-- or nil if no "]" comes after them
local function repeatCount(s, i)
    local sc = scan.new(s, i)
    local digits = sc:readWhile(scan.isDigit)
    if not sc:accept("]") then return nil end
    return digits
end

-- a string operand as a list of characters; fill is where [c*] goes
local function parse(s, second)
    local t, fill, i = {}, nil, 1
    while i <= #s do
        local name = className(s, i)
        local c, j = char(s, i + 1)     -- for [c*n]
        local q, k = char(s, i + 2)     -- for [=c=]
        if name then
            if not CLASS[name] then cu.usageError("invalid class: " .. name, 1) end
            for b = 0, 127 do
                if CLASS[name](string.char(b)) then t[#t + 1] = string.char(b) end
            end
            i = i + #name + 4
        elseif s:sub(i, i + 1) == "[=" and s:sub(k, k + 1) == "=]" then
            t[#t + 1] = q
            i = k + 2
        elseif s:sub(i, i) == "[" and s:sub(j, j) == "*" and repeatCount(s, j + 1) then
            local num = repeatCount(s, j + 1)
            if not second then cu.usageError("[c*n] belongs in string2", 1) end
            local count = tonumber(num, text.startsWith(num, "0") and 8 or 10) or 0
            if count == 0 and not fill then fill = #t + 1; t[#t + 1] = { c } end
            for _ = 1, count do t[#t + 1] = c end
            i = j + #num + 2
        else
            c, j = char(s, i)
            if s:sub(j, j) == "-" and j < #s then
                local e
                e, j = char(s, j + 1)
                if e < c then cu.usageError("range-endpoints of " .. c .. "-" .. e .. " are in reverse order", 1) end
                for b = c:byte(), e:byte() do t[#t + 1] = string.char(b) end
            else
                t[#t + 1] = c
            end
            i = j
        end
    end
    return t, fill
end

-- the set of string1, complemented if asked, as a list and a lookup
local list1 = parse(ops[1])
local in1 = {}
for _, c in ipairs(list1) do in1[c] = true end
if comp then
    list1 = {}
    for b = 0, 255 do
        local c = string.char(b)
        if not in1[c] then list1[#list1 + 1] = c end
    end
    in1 = {}
    for _, c in ipairs(list1) do in1[c] = true end
end

local map, squeeze = {}, {}
if ops[2] then
    local list2, fill = parse(ops[2], true)
    if fill then
        local c = table.remove(list2, fill)[1]
        for _ = 1, #list1 - #list2 do table.insert(list2, fill, c) end
    end
    for _, c in ipairs(list2) do squeeze[c] = opts.s end
    if not opts.d then
        if #list2 == 0 and #list1 > 0 then cu.usageError("string2 is empty", 1) end
        for k, c in ipairs(list1) do map[c] = list2[math.min(k, #list2)] end
    end
elseif opts.s then
    squeeze = in1
end

local last = nil    -- the last character written, for -s across lines
local h = io.input()
local done = 0      -- bytes since the last yield
for l in function() return cu.readLine(h, true) end do
    -- yield now and then so a big input can't run "too long without yielding"
    done = done + #l + 20
    if done > 50000 then done = 0; os.queueEvent("tr_yield"); os.pullEvent("tr_yield") end
    local t = {}
    for k = 1, #l do
        local c = l:sub(k, k)
        if not (opts.d and in1[c]) then
            c = map[c] or c
            if not (squeeze[c] and c == last) then t[#t + 1] = c end
            last = c
        end
    end
    io.write(table.concat(t))
end
return cu.exit()
