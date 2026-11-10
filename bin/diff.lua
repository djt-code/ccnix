-- diff.lua -- show the differences between two files (POSIX diff)
--
--   diff [-c|-e|-f|-u|-C n|-U n] [-bqr] file1 file2
--
-- Writes the lines that must change to turn file1 into file2, as a
-- shortest edit (Myers' algorithm).  The default "normal" format gives
-- commands like 3,5c3 with "< " lines from file1 and "> " from file2; -u
-- (or -U n) is the unified format with 3 (n) lines of context, -c (or
-- -C n) the context format, -e an ed script and -f the same forwards.
-- -b ignores trailing blanks and treats other runs of blanks as one; -q
-- only says whether the files differ.  Either file can be "-", standard
-- input.  If one operand is a directory, the file of the other's name in
-- it is used; if both are, their files are compared by name, and -r goes
-- on into common subdirectories.  Exit 0: no differences, 1: some,
-- 2: trouble.

package.path = (ccnix and ccnix.lib or "/" .. fs.getDir(fs.getDir(shell.getRunningProgram())) .. "/lib/?.lua;") .. package.path  -- ccnix's lib/, or the one beside bin/
local cu = require("cu").init("diff", "diff [-c|-e|-f|-u|-C n|-U n] [-bqr] file1 file2")
local convert = require("convert")
local path = require("path")
local scan = require("scan")
local text = require("text")
local args = { ... }
local opts, ops, order = cu.getopt(args, "bcefqruC:U:", 2)
if #ops ~= 2 then cu.usageError() end
-- the options as typed, for the "diff <options> a b" lines between files
local typed = {}
for i = 1, #args - 2 do if args[i] ~= "--" then typed[#typed + 1] = args[i] end end
local optText = table.concat(typed, " ")

-- the output format: n(ormal), c, u, e or f; the last one given wins
local fmt, ctx = "n", 0
for _, o in ipairs(order) do
    local c, v = o[1], o[2]
    if c == "c" or c == "u" then fmt, ctx = c, 3
    elseif c == "e" or c == "f" then fmt = c
    elseif c == "C" or c == "U" then
        local num = convert.toInteger(v)
        if not num or num < 0 then cu.usageError("bad context length: " .. v) end
        fmt, ctx = c:lower(), num
    end
end

-- a long job (a big diff, or a lot of output) yields now and then, or
-- CC stops the program for running too long without yielding
local lastYield = os.clock()
local function breathe()
    if os.clock() - lastYield > 2 then
        os.queueEvent("diff")
        os.pullEvent("diff")
        lastYield = os.clock()
    end
end

local outs = 0
local function out(...)
    io.write(...)
    outs = outs + 1
    if outs % 200 == 0 then breathe() end
end
local NOEOL = "\\ No newline at end of file\n"

-- The whole of an operand, or nil (reported, status 2).  "-" is read
-- once and kept, so "diff - -" compares it with itself.
local stdinText
local function slurp(name)
    if name == "-" and stdinText then return stdinText end
    local h = cu.open(name)
    if not h then cu.status = 2; return nil end
    local s = cu.readAll(h)
    cu.close(h)
    if name == "-" then stdinText = s end
    return s
end

-- lines without their newlines, the keys they are compared by, and
-- whether the last line has no newline (its key gets a marker, so "x"
-- and "x\n" differ)
local function notSpace(c) return not scan.isSpace(c) end

local function split(s)
    local L, K = text.split(s, "\n", true), {}
    local last = table.remove(L)    -- (what comes after the last newline)
    if last ~= "" then L[#L + 1] = last end
    for i, l in ipairs(L) do
        K[i] = opts.b and text.trimEnd(text.squeeze(l)) or l
    end
    if last ~= "" then K[#K] = K[#K] .. "\0" end
    return L, K, last ~= ""
end

--------------------------------------------------------------------------
-- Myers' O(ND) diff in linear space: find the middle snake of the
-- shortest edit, recurse on both sides.  mA[i] = j when line i of file1
-- is kept as line j of file2 (and mB[j] = i).
--------------------------------------------------------------------------
local A, B, mA, mB
local steps = 0

-- the middle snake of A(a0..a1] against B(b0..b1], relative to a0, b0
local function snake(a0, a1, b0, b1)
    local N, M = a1 - a0, b1 - b0
    local delta = N - M
    local odd = delta % 2 ~= 0
    local vf, vb = { [1] = 0 }, { [1] = 0 }
    for d = 0, math.ceil((N + M) / 2) do
        steps = steps + d
        if steps > 20000 then steps = 0; breathe() end
        -- forwards from the start, on diagonals k = x - y
        for k = -d, d, 2 do
            local x
            if k == -d or (k ~= d and vf[k - 1] < vf[k + 1]) then x = vf[k + 1] else x = vf[k - 1] + 1 end
            local y = x - k
            local x0, y0 = x, y
            while x < N and y < M and A[a0 + x + 1] == B[b0 + y + 1] do x, y = x + 1, y + 1 end
            vf[k] = x
            local c = delta - k
            if odd and c > -d and c < d and x + vb[c] >= N then return x0, y0, x, y end
        end
        -- backwards from the end, u and v counted from the ends
        for c = -d, d, 2 do
            local u
            if c == -d or (c ~= d and vb[c - 1] < vb[c + 1]) then u = vb[c + 1] else u = vb[c - 1] + 1 end
            local v = u - c
            local u0, v0 = u, v
            while u < N and v < M and A[a1 - u] == B[b1 - v] do u, v = u + 1, v + 1 end
            vb[c] = u
            local k = delta - c
            if not odd and k >= -d and k <= d and u + vf[k] >= N then return N - u, M - v, N - u0, M - v0 end
        end
    end
end

local function lcs(a0, a1, b0, b1)
    -- common lines at the start and end are kept as they are
    while a0 < a1 and b0 < b1 and A[a0 + 1] == B[b0 + 1] do
        a0, b0 = a0 + 1, b0 + 1
        mA[a0], mB[b0] = b0, a0
    end
    while a1 > a0 and b1 > b0 and A[a1] == B[b1] do
        mA[a1], mB[b1] = b1, a1
        a1, b1 = a1 - 1, b1 - 1
    end
    if a0 == a1 or b0 == b1 then return end
    local x0, y0, x, y = snake(a0, a1, b0, b1)
    lcs(a0, a0 + x0, b0, b0 + y0)
    for i = 1, x - x0 do mA[a0 + x0 + i], mB[b0 + y0 + i] = b0 + y0 + i, a0 + x0 + i end
    lcs(a0 + x, a1, b0 + y, b1)
end

-- the changes as { s1, e1, s2, e2 }: lines s1..e1 of file1 become lines
-- s2..e2 of file2 (an empty side has e = s - 1)
local function changes(KA, KB)
    -- a line found only in one file can't be kept: leave those out of the
    -- search (so two quite different files are quick), then map back
    local function only(K, other)
        local has, k, at = {}, {}, {}
        for _, v in ipairs(other) do has[v] = true end
        for i, v in ipairs(K) do if has[v] then k[#k + 1] = v; at[#k] = i end end
        return k, at
    end
    local atA, atB
    A, atA = only(KA, KB)
    B, atB = only(KB, KA)
    mA, mB = {}, {}
    lcs(0, #A, 0, #B)
    local keepA, keepB = {}, {}
    for i, j in pairs(mA) do keepA[atA[i]], keepB[atB[j]] = atB[j], atA[i] end
    local ch, i, j = {}, 1, 1
    while i <= #KA or j <= #KB do
        if i <= #KA and keepA[i] == j then
            i, j = i + 1, j + 1
        else
            local si, sj = i, j
            while i <= #KA and not keepA[i] do i = i + 1 end
            while j <= #KB and not keepB[j] do j = j + 1 end
            ch[#ch + 1] = { si, i - 1, sj, j - 1 }
        end
    end
    return ch
end

--------------------------------------------------------------------------
-- Output formats
--------------------------------------------------------------------------
local DAY = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }
local MON = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }

-- an operand's modification time for the -c and -u headers (UTC); "-" is now
local function stamp(name)
    local ms = name ~= "-" and fs.attributes(shell.resolve(name)).modified or os.epoch("utc")
    local t = os.date("!*t", math.floor(ms / 1000))
    if fmt == "u" then
        return string.format("%04d-%02d-%02d %02d:%02d:%02d.%09d +0000",
            t.year, t.month, t.day, t.hour, t.min, t.sec, (ms % 1000) * 1000000)
    end
    return string.format("%s %s %2d %02d:%02d:%02d %d",
        DAY[t.wday], MON[t.month], t.day, t.hour, t.min, t.sec, t.year)
end

-- "s,e" or "s" (sep is " " for -f)
local function range(s, e, sep)
    if e > s then return s .. (sep or ",") .. e end
    return tostring(s)
end

-- lines s..e of L, each after prefix, with the no-newline note after
-- the last line of a file that has none
local function lines(L, noeol, s, e, prefix)
    for i = s, e do
        out(prefix, L[i], "\n")
        if i == #L and noeol and prefix then out(NOEOL) end
    end
end

local function normal(ch, L1, L2, ne1, ne2)
    for _, c in ipairs(ch) do
        local s1, e1, s2, e2 = c[1], c[2], c[3], c[4]
        if e2 < s2 then out(range(s1, e1), "d", s2 - 1, "\n")
        elseif e1 < s1 then out(s1 - 1, "a", range(s2, e2), "\n")
        else out(range(s1, e1), "c", range(s2, e2), "\n") end
        lines(L1, ne1, s1, e1, "< ")
        if e1 >= s1 and e2 >= s2 then out("---\n") end
        lines(L2, ne2, s2, e2, "> ")
    end
end

-- ed script: -e from the end backwards (so line numbers stay right),
-- -f forwards with the letter first
local function edScript(ch, L2)
    local first, last, step = #ch, 1, -1
    if fmt == "f" then first, last, step = 1, #ch, 1 end
    for n = first, last, step do
        local s1, e1, s2, e2 = ch[n][1], ch[n][2], ch[n][3], ch[n][4]
        local cmd, where = "c", range(s1, e1, fmt == "f" and " ")
        if e2 < s2 then cmd = "d" elseif e1 < s1 then cmd, where = "a", tostring(s1 - 1) end
        out(fmt == "f" and (cmd .. where) or (where .. cmd), "\n")
        -- a line of just "." would end the text early: write "..", end
        -- the text, s/.// it back to ".", and go on appending after it
        if cmd ~= "d" then
            for i = s2, e2 do
                if L2[i] ~= "." then out(L2[i], "\n")
                else out("..\n.\ns/.//\n", i < e2 and "a\n" or "") end
            end
            if L2[e2] ~= "." then out(".\n") end
        end
    end
end

-- -c and -u: changes less than 2*ctx lines apart share a hunk
local function hunks(ch, n1, n2)
    local H, i = {}, 1
    while i <= #ch do
        local j = i
        while j < #ch and ch[j + 1][1] - ch[j][2] - 1 <= 2 * ctx do j = j + 1 end
        local f, l = ch[i], ch[j]
        local s1 = math.max(1, f[1] - ctx)
        local e1 = math.min(n1, l[2] + ctx)
        H[#H + 1] = { i = i, j = j, s1 = s1, e1 = e1, s2 = f[3] - (f[1] - s1), e2 = math.min(n2, l[4] + (e1 - l[2])) }
        i = j + 1
    end
    return H
end

local function unified(ch, L1, L2, ne1, ne2)
    local function urange(s, e)
        if e - s == 0 then return tostring(s) end
        if e < s then return (s - 1) .. ",0" end
        return s .. "," .. (e - s + 1)
    end
    for _, h in ipairs(hunks(ch, #L1, #L2)) do
        out("@@ -", urange(h.s1, h.e1), " +", urange(h.s2, h.e2), " @@\n")
        local at = h.s1
        for n = h.i, h.j do
            local c = ch[n]
            lines(L1, ne1, at, c[1] - 1, " ")
            lines(L1, ne1, c[1], c[2], "-")
            lines(L2, ne2, c[3], c[4], "+")
            at = c[2] + 1
        end
        lines(L1, ne1, at, h.e1, " ")
    end
end

local function context(ch, L1, L2, ne1, ne2)
    local function crange(s, e)
        if e <= s then return tostring(e) end
        return s .. "," .. e
    end
    for _, h in ipairs(hunks(ch, #L1, #L2)) do
        -- the mark of each changed line: "- " gone, "+ " new, "! " changed
        local m1, m2, any1, any2 = {}, {}, false, false
        for n = h.i, h.j do
            local c = ch[n]
            local both = c[2] >= c[1] and c[4] >= c[3]
            for i = c[1], c[2] do m1[i] = both and "! " or "- "; any1 = true end
            for i = c[3], c[4] do m2[i] = both and "! " or "+ "; any2 = true end
        end
        out("***************\n*** ", crange(h.s1, h.e1), " ****\n")
        if any1 then for i = h.s1, h.e1 do lines(L1, ne1, i, i, m1[i] or "  ") end end
        out("--- ", crange(h.s2, h.e2), " ----\n")
        if any2 then for i = h.s2, h.e2 do lines(L2, ne2, i, i, m2[i] or "  ") end end
    end
end

--------------------------------------------------------------------------
-- Comparing
--------------------------------------------------------------------------
-- compare two files; inDir: part of a directory comparison
local function diffFiles(n1, n2, inDir)
    local t1, t2 = slurp(n1), slurp(n2)
    if not t1 or not t2 or (t1 == t2) then return end
    local binary = text.contains(t1, "\0") or text.contains(t2, "\0")
    local L1, K1, ne1 = split(t1)
    local L2, K2, ne2 = split(t2)
    local ch = (binary or (opts.q and not opts.b)) and { true } or changes(K1, K2)
    if #ch == 0 then return end
    cu.status = math.max(cu.status, 1)
    if binary or opts.q then
        out("Files ", n1, " and ", n2, " differ\n")
        return
    end
    if inDir then out("diff ", optText ~= "" and (optText .. " ") or "", n1, " ", n2, "\n") end
    if fmt == "u" then
        out("--- ", n1, "\t", stamp(n1), "\n+++ ", n2, "\t", stamp(n2), "\n")
        unified(ch, L1, L2, ne1, ne2)
    elseif fmt == "c" then
        out("*** ", n1, " ", stamp(n1), "\n--- ", n2, " ", stamp(n2), "\n")
        context(ch, L1, L2, ne1, ne2)
    elseif fmt == "n" then normal(ch, L1, L2, ne1, ne2)
    else edScript(ch, L2) end
end

local function isDir(name) return name ~= "-" and fs.isDir(shell.resolve(name)) end

-- compare two directories by the names in them
local function diffDirs(d1, d2)
    local names, seen = {}, {}
    for _, d in ipairs({ d1, d2 }) do
        for _, f in ipairs(fs.list(shell.resolve(d))) do
            if not seen[f] then seen[f] = true; names[#names + 1] = f end
        end
    end
    table.sort(names)
    for _, f in ipairs(names) do
        local p1, p2 = path.join(d1, f), path.join(d2, f)
        local e1, e2 = fs.exists(shell.resolve(p1)), fs.exists(shell.resolve(p2))
        if not e2 then out("Only in ", d1, ": ", f, "\n"); cu.status = math.max(cu.status, 1)
        elseif not e1 then out("Only in ", d2, ": ", f, "\n"); cu.status = math.max(cu.status, 1)
        elseif isDir(p1) and isDir(p2) then
            if opts.r then diffDirs(p1, p2) else out("Common subdirectories: ", p1, " and ", p2, "\n") end
        elseif isDir(p1) or isDir(p2) then
            out("File ", p1, " is a ", isDir(p1) and "directory" or "regular file", " while file ", p2,
                " is a ", isDir(p2) and "directory" or "regular file", "\n")
            cu.status = math.max(cu.status, 1)
        else
            diffFiles(p1, p2, true)
        end
    end
end

local f1, f2 = ops[1], ops[2]
if isDir(f1) and isDir(f2) then
    diffDirs(f1, f2)
else
    -- a directory and a file: the file of that name in the directory
    if isDir(f1) then f1 = path.join(f1, f2 == "-" and "-" or fs.getName(shell.resolve(f2))) end
    if isDir(f2) then f2 = path.join(f2, f1 == "-" and "-" or fs.getName(shell.resolve(f1))) end
    diffFiles(f1, f2, false)
end
return cu.exit()
