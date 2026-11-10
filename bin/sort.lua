-- sort.lua -- sort, merge or check lines of text (POSIX sort)
--
--   sort [-m] [-o output] [-bdfinru] [-t char] [-k keydef]... [file...]
--   sort -c|-C [-bdfinru] [-t char] [-k keydef] [file]
--
-- Sorts the lines of all the files together (standard input if there are
-- none, or for "-") and writes them out, comparing bytes.
--   -n  by the number at the start (blanks, a minus sign, digits, a point)
--   -r  largest first          -u  only one of each set of equal lines
--   -f  fold lower case into upper case
--   -b  ignore leading blanks   -d  only blanks, letters and digits count
--   -i  ignore unprintable characters
--   -t  fields are separated by this character (by default a field is
--       its leading blanks plus the non-blanks after them)
--   -k  sort on a key: field[.char][mods][,field[.char][mods]], counting
--       from 1; mods are b d f i n r and override the global ones for that
--       key.  Several -k: the first decides, later ones break ties.  Lines
--       still equal are compared whole (not with -u).
--   -o  write to this file (it may be one of the inputs)
--   -m  the inputs are already sorted (they are just sorted together)
--   -c  check the input is sorted: report the first line out of order and
--       exit 1.  -C does the same without the report.
-- Exits 2 if a file can't be read or written.

package.path = (ccnix and ccnix.lib or "/" .. fs.getDir(fs.getDir(shell.getRunningProgram())) .. "/lib/?.lua;") .. package.path  -- ccnix's lib/, or the one beside bin/
local cu = require("cu").init("sort", "sort [-cCmu] [-o output] [-bdfinr] [-t char] [-k keydef]... [file...]")
local scan = require("scan")
local text = require("text")
local opts, files, order = cu.getopt({ ... }, "bcCdfik:mno:rt:u")
local sep = opts.t
if sep and #sep ~= 1 then cu.usageError("the -t separator must be one character") end
local check = opts.c or opts.C
if check and #files > 1 then cu.usageError("-c takes at most one file") end

local MODS = "bdfinr"
local isMod = scan.oneOf(MODS)

-- one end of a keydef: field ("." char?)? mods, field and char digits, the
-- mods some of b d f i n r.  The three as text ("" for one left out), or
-- nil if no field number comes first
local function readKeyEnd(ks)
    local field = ks:readWhile(scan.isDigit)
    if field == "" then return nil end
    local char = ""
    if ks:accept(".") then char = ks:readWhile(scan.isDigit) end
    return field, char, ks:readWhile(isMod)
end

-- a keydef: start ("," end)?, as the start's field, char and mods, then
-- the end's (nil if it has none); nil if it's neither
local function readKeydef(keydef)
    local ks = scan.new(keydef)
    local sf, sc, sm = readKeyEnd(ks)
    if not sf then return nil end
    if ks:atEnd() then return sf, sc, sm end
    if not ks:accept(",") then return nil end
    local ef, ec, em = readKeyEnd(ks)
    if not ef or not ks:atEnd() then return nil end
    return sf, sc, sm, ef, ec, em
end

-- the global modifiers, then each key { sf, sc, ef, ec, mods, bstart, bend }
local global = {}
for i = 1, #MODS do global[MODS:sub(i, i)] = opts[MODS:sub(i, i)] end
local keys = {}
for _, o in ipairs(order) do
    if o[1] == "k" then
        local sf, sc, sm, ef, ec, em = readKeydef(o[2])
        if not sf or tonumber(sf) == 0 or (sc ~= "" and tonumber(sc) == 0) then
            cu.usageError("bad key: " .. o[2])
        end
        local k = { sf = tonumber(sf), sc = tonumber(sc) or 1, ef = tonumber(ef), ec = tonumber(ec) or 0 }
        if sm == "" and (em or "") == "" then
            k.mods, k.bs, k.be = global, global.b, global.b
        else
            local mods = sm .. (em or "")
            k.mods, k.bs, k.be = {}, text.contains(sm, "b"), text.contains(em or "", "b")
            for i = 1, #mods do k.mods[mods:sub(i, i)] = true end
        end
        keys[#keys + 1] = k
    end
end
local whole = #keys == 0
if whole then keys[1] = { sf = 1, sc = 1, ec = 0, mods = global, bs = global.b, be = false } end

local isBlank = scan.oneOf(" \t")
local function notBlank(c) return not isBlank(c) end

-- where the blanks from p on in l end: the next non-blank (#l + 1 if none)
local function pastBlanks(l, p)
    local sc = scan.new(l, p)
    sc:readWhile(isBlank)
    return sc:pos()
end

-- the fields of a line as start and end positions
local function fields(l)
    local f, p = {}, 1
    if sep then
        while true do
            local q = text.find(l, sep, p)
            f[#f + 1] = { p, (q or #l + 1) - 1 }
            if not q then break end
            p = q + 1
        end
    else
        -- a field: its blanks, then the non-blanks after them
        local sc = scan.new(l)
        while not sc:atEnd() do
            sc:readWhile(isBlank)
            sc:readWhile(notBlank)
            f[#f + 1] = { p, sc:pos() - 1 }
            p = sc:pos()
        end
    end
    return f
end

-- the position char c of field n (b: after its blanks), at most its end + 1
local function at(l, f, n, c, b)
    local p = f[n][1]
    if b then p = pastBlanks(l, p) end
    return math.min(p + c - 1, f[n][2] + 1)
end

-- t with only the characters for which keep(c) holds
local function keepOnly(t, keep)
    local out = {}
    for i = 1, #t do
        local c = t:sub(i, i)
        if keep(c) then out[#out + 1] = c end
    end
    return table.concat(out)
end

local function isDictChar(c) return scan.isAlnum(c) or isBlank(c) end     -- (-d)

-- the number at the start of t for -n: blanks, then "-"? digit* ("."
-- digit*)?; 0 if that isn't a number
local function leadingNumber(t)
    local sc = scan.new(t)
    sc:readWhile(isBlank)
    local from = sc:pos()
    sc:accept("-")
    sc:readWhile(scan.isDigit)
    if sc:accept(".") then sc:readWhile(scan.isDigit) end
    return tonumber(t:sub(from, sc:pos() - 1)) or 0
end

local function keyText(l, k)
    local f = fields(l)
    if k.sf > #f then return k.mods.n and 0 or "" end      -- (a line too short for the key: empty, 0 for -n)
    local s = at(l, f, k.sf, k.sc, k.bs)
    local e = #l
    if k.ef and k.ef <= #f then e = k.ec == 0 and f[k.ef][2] or math.min(at(l, f, k.ef, k.ec, k.be), f[k.ef][2]) end
    if whole and k.mods.b then s = pastBlanks(l, 1) end
    local t = l:sub(s, e)
    if k.mods.d then t = keepOnly(t, isDictChar) end
    if k.mods.i then t = keepOnly(t, scan.isPrintable) end
    if k.mods.f then t = t:upper() end
    if k.mods.n then t = leadingNumber(t) end
    return t
end

-- read everything, working out each line's keys once
local lines, kt = {}, {}
for l in cu.lines(files) do
    -- yield now and then so a big file can't run "too long without yielding"
    if #lines % 1000 == 999 then os.queueEvent("sort_yield"); os.pullEvent("sort_yield") end
    local t = {}
    for n, k in ipairs(keys) do t[n] = keyText(l, k) end
    local n = #lines + 1
    lines[n], kt[n] = l, t
end
if cu.status ~= 0 then cu.status = 2 end

-- -1, 0 or 1: how line i compares with line j
local function compare(i, j)
    for n, k in ipairs(keys) do
        local x, y = kt[i][n], kt[j][n]
        if x ~= y then
            local r = x < y and -1 or 1
            return k.mods.r and -r or r
        end
    end
    local a, b = lines[i], lines[j]
    if opts.u or a == b then return 0 end
    local r = a < b and -1 or 1
    return opts.r and -r or r
end

if check then
    for i = 2, #lines do
        local c = compare(i - 1, i)
        if c > 0 or (opts.u and c == 0) then
            if opts.c then
                cu.err((files[1] or "-") .. ":" .. i .. ": disorder: " .. lines[i])
            end
            return cu.exit(math.max(cu.status, 1))
        end
    end
    return cu.exit()
end

-- sort, keeping equal lines in input order, then drop repeats for -u
local idx = {}
for i = 1, #lines do idx[i] = i end
table.sort(idx, function(i, j)
    local c = compare(i, j)
    if c ~= 0 then return c < 0 end
    return i < j
end)
local out = {}
for n, i in ipairs(idx) do
    if not (opts.u and n > 1 and compare(idx[n - 1], i) == 0) then
        out[#out + 1] = lines[i] .. "\n"
    end
end

if opts.o then
    local h, e = io.open(shell.resolve(opts.o), "wb")
    -- io.open's message starts with the path and ": ": keep just the reason
    local why = tostring(e)
    local _, rest = text.cut(why, ":")
    why = rest and text.stripPrefix(rest, " ") or why
    if not h then cu.fail(opts.o .. ": " .. why, 2); return cu.exit() end
    h:write(table.concat(out))
    h:close()
else
    io.write(table.concat(out))
end
return cu.exit()
