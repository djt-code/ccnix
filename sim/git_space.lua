-- sim/git_space.lua
--
-- bin/git.lua against a mock GitHub and a small disk: a clone leaves out
-- sim/ and the other device's folder (and keeps everything with --all);
-- a disk that fills stops the clone with what it got saved, and `git
-- pull` finishes it once there's room; a checkout from before the device
-- rule loses sim/ on its next pull; and files that move between folders
-- need no room for two copies, as deletions go first (the git from before
-- fetched everything first, so moving the whole repo into bin/ and turtle/
-- filled the disk and left both copies).  --only takes just the paths
-- named, and a pull with new options changes what's kept.  --lower makes
-- an overlay on ccnix's ROM: only what differs from the ROM is fetched,
-- what the ROM catches up on goes, and a ROM newer than the branch leaves
-- nothing to keep.
local PROJ = ...
package.path = PROJ .. "/lib/?.lua;" .. PROJ .. "/sim/lib/?.lua;" .. package.path    -- (the text libraries, as setup gives git them)
local M = require("mock")
local json = M.json
local realPrint = print

local function check(label, cond, got)
    realPrint(string.format("   %s %s%s", cond and "ok   " or "ERROR:", label, got and ("  (" .. tostring(got) .. ")") or ""))
end

-- the remote: commits of { [path] = text }; a blob's sha is its path and
-- text; DATES (if set) the commits' times, as GitHub gives them
local COMMITS, HEAD, DATES
local function sha(path, text) return (path .. ":" .. #text .. ":" .. text:sub(1, 8)):gsub("[^%w]", "_") end
local API = "https://api.github.com/repos/me/ccnix"
local RAW = "https://raw.githubusercontent.com/me/ccnix/"
local fetched
-- failures to give first, in turn, whatever's asked: { code, headers }
local FAILS = {}
http = {
    get = function(req)
        local url = type(req) == "table" and req.url or req
        local f = table.remove(FAILS, 1)
        if f then
            return nil, "HTTP " .. f[1], { getResponseCode = function() return f[1] end,
                getResponseHeaders = function() return f[2] or {} end, close = function() end }
        end
        local body
        if url == API then body = json.encode({ default_branch = "main" })
        elseif url == API .. "/branches/main" then
            body = json.encode({ commit = { sha = HEAD, commit = { committer = { date = DATES and DATES[HEAD] } } } })
        elseif url:sub(1, #API + 11) == API .. "/git/trees/" then
            local c = url:sub(#API + 12):match("^[^?]+")
            local tree = {}
            for path, text in pairs(COMMITS[c]) do tree[#tree + 1] = { path = path, type = "blob", sha = sha(path, text) } end
            table.sort(tree, function(a, b) return a.path < b.path end)
            body = json.encode({ tree = tree, truncated = false })
        elseif url:sub(1, #RAW) == RAW then
            local c, path = url:sub(#RAW + 1):match("^([^/]+)/(.+)$")
            body = COMMITS[c][path]
            fetched[#fetched + 1] = path
        end
        if not body then return nil, "404" end
        return { readAll = function() return body end, close = function() end }
    end,
}
textutils = M.textutilsApi()

-- the disk: files under "", a capacity in bytes; as in CC a file takes
-- at least 500
local files, CAP = {}, 0
local function size(t) return math.max(#t, 500) end
local function used() local n = 0; for _, t in pairs(files) do n = n + size(t) end; return n end
local function under(d, p) return d == "" or p:sub(1, #d + 1) == d .. "/" end
fs = {
    combine = function(a, b)
        local p = (a == "" and b) or (b == "" and a) or (a .. "/" .. b)
        return (p:gsub("^/+", ""))
    end,
    getDir = function(p) return p:match("^(.*)/[^/]*$") or "" end,
    exists = function(p)
        p = p:gsub("^/+", "")
        if files[p] then return true end
        for k in pairs(files) do if under(p, k) then return true end end
        return false
    end,
    isDir = function(p) return files[p] == nil and fs.exists(p) end,
    list = function(p)
        local t, seen = {}, {}
        for k in pairs(files) do
            if under(p, k) then
                local n = k:sub(#p + 2):match("^[^/]+")
                if not seen[n] then seen[n] = true; t[#t + 1] = n end
            end
        end
        return t
    end,
    makeDir = function() end,
    getFreeSpace = function() return CAP - used() end,
    getSize = function(p) return #(files[p] or "") end,
    delete = function(p)
        p = p:gsub("^/+", "")
        for k in pairs(files) do if k == p or under(p, k) then files[k] = nil end end
    end,
    open = function(p, mode)
        p = p:gsub("^/+", "")
        if mode == "w" or mode == "wb" then
            local buf = {}
            return { write = function(s) buf[#buf + 1] = s end,
                     close = function()
                         local text = table.concat(buf)
                         if size(text) - (files[p] and size(files[p]) or 0) > CAP - used() then error("Out of space", 0) end
                         files[p] = text
                     end }
        end
        local data = files[p]
        if not data then return nil end
        return { readAll = function() return data end, close = function() end }
    end,
}
shell = { resolve = function(p) return (p:gsub("^/+", "")) end, getRunningProgram = function() return "ccnix/bin/git.lua" end }
local errs, slept = {}, {}
printError = function(s) errs[#errs + 1] = s; realPrint("   ! " .. s) end
sleep = function(n) slept[#slept + 1] = n end

local out
local function git(...)
    out, fetched = {}, {}
    print = function(...)
        local t = {}
        for i = 1, select("#", ...) do t[i] = tostring(select(i, ...)) end
        out[#out + 1] = table.concat(t, " ")
    end
    local ok, err = pcall(assert(loadfile(PROJ .. "/bin/git.lua")), ...)
    print = realPrint
    return ok, err
end
local function said(s)
    for _, l in ipairs(out) do if l:find(s, 1, true) then return true end end
    return false
end
local function state() return json.decode(files["ccnix/.gitlite"] or "null") end
local function has(p) return files["ccnix/" .. p] ~= nil end

local REPO = {
    ["README.md"] = string.rep("r", 1000),
    ["bin/git.lua"] = string.rep("g", 2000), ["bin/cat.lua"] = string.rep("c", 1000),
    ["lib/cu.lua"] = string.rep("u", 1000),
    ["turtle/mine.lua"] = string.rep("m", 3000), ["pc/diskclone.lua"] = string.rep("d", 1000),
    ["sim/mine_tunnel.lua"] = string.rep("s", 20000), ["sim/lib/mock.lua"] = string.rep("k", 10000),
}

realPrint("== a turtle clones: sim/ and pc/ left out")
COMMITS, HEAD, files, CAP, turtle = { c1 = REPO }, "c1", {}, 50000, {}
local ok, err = git("clone", "https://github.com/me/ccnix", "/ccnix")
check("the clone finished", ok and said("Done: 5 files."), err)
check("sim/ and pc/ aren't on the disk", not has("sim/mine_tunnel.lua") and not has("pc/diskclone.lua")
    and has("turtle/mine.lua") and has("bin/git.lua"))
check("the rule is kept in .gitlite", state().skip and table.concat(state().skip, ",") == "sim,pc")
check("it says what it left out", said("Leaving out sim/, pc/"))

realPrint("== a computer clones: sim/ and turtle/ left out; --all keeps everything")
files, turtle = {}, nil
git("clone", "https://github.com/me/ccnix", "/ccnix")
check("a computer gets pc/ and not turtle/", has("pc/diskclone.lua") and not has("turtle/mine.lua") and not has("sim/lib/mock.lua"))
files = {}
git("clone", "https://github.com/me/ccnix", "/ccnix", "--all")
check("--all gets sim/ too", has("sim/lib/mock.lua") and has("turtle/mine.lua") and #state().skip == 0)
files = {}
git("clone", "https://github.com/me/ccnix", "/ccnix", "--skip", "lib/")
check("--skip adds to the device's rule", not has("lib/cu.lua") and not has("sim/lib/mock.lua")
    and table.concat(state().skip, ",") == "sim,turtle,lib")

realPrint("== the disk fills during a clone, then there's room")
files, CAP, turtle = { ["junk.txt"] = string.rep("j", 4000) }, 11000, {}
ok, err = git("clone", "https://github.com/me/ccnix", "/ccnix")
check("it stops with a clear message", not ok, err)
check(".gitlite keeps what it got, with no commit", state() and state().commit == nil and next(state().files) ~= nil)
local before = 0
for _ in pairs(state().files) do before = before + 1 end
files["junk.txt"] = nil
ok = git("pull", "/ccnix")
check("git pull finishes it", ok and has("turtle/mine.lua") and has("README.md") and state().commit == "c1",
    #fetched .. " fetched, " .. before .. " kept")
check("fetching only what was missing", #fetched == 5 - before)

realPrint("== a checkout from before the device rule")
local old = {}
for p, t in pairs(REPO) do files["ccnix/" .. p] = t end
for p, t in pairs(REPO) do old[p] = sha(p, t) end
files["ccnix/.gitlite"] = json.encode({ url = "https://github.com/me/ccnix", branch = "main", commit = "c1", files = old })
CAP = 100000
ok = git("pull", "/ccnix")
check("its next pull drops sim/ and pc/, even with no new commit", ok and not has("sim/mine_tunnel.lua")
    and not has("pc/diskclone.lua") and has("turtle/mine.lua") and said("from now on"))
check("and fetches nothing it had", #fetched == 0, #fetched)

realPrint("== files move between folders on a nearly full disk")
local moved = {}
for p, t in pairs(REPO) do moved[p] = t end
moved["turtle/mine.lua"], moved["bin/mine.lua"] = nil, REPO["turtle/mine.lua"]
COMMITS.c2, HEAD = moved, "c2"
CAP = used() + 1500
ok = git("pull", "/ccnix")
check("the pull fits: the old copy goes before the new one comes", ok and has("bin/mine.lua") and not has("turtle/mine.lua"))

realPrint("== the whole repo moves into a folder, on a disk with room for a few files more")
local OLDL, NEWL = {}, {}
for i = 1, 6 do
    OLDL["p" .. i .. ".lua"] = string.rep("o" .. i, 1000)
    NEWL["bin/p" .. i .. ".lua"] = OLDL["p" .. i .. ".lua"]
end
COMMITS, HEAD, files, CAP = { o1 = OLDL, n1 = NEWL }, "o1", {}, 100000
git("clone", "https://github.com/me/ccnix", "/ccnix")
HEAD, CAP = "n1", used() + 5000
ok = git("pull", "/ccnix")
local top, bin = 0, 0
for k in pairs(files) do
    if k:match("^ccnix/p%d") then top = top + 1 elseif k:match("^ccnix/bin/") then bin = bin + 1 end
end
check("every file is in bin/ and none is left at the top", ok and top == 0 and bin == 6,
    top .. " at the top, " .. bin .. " in bin/")

realPrint("== --only: just the files and folders named; a pull changes the choice")
COMMITS, HEAD, files, CAP, turtle = { c1 = REPO }, "c1", {}, 100000, {}
ok = git("clone", "https://github.com/me/ccnix", "/ccnix", "--only", "turtle/mine.lua", "--only", "bin/")
check("only turtle/mine.lua and bin/", ok and has("turtle/mine.lua") and has("bin/cat.lua") and has("bin/git.lua")
    and not has("lib/cu.lua") and not has("README.md"))
ok = git("pull", "/ccnix", "--only", "lib/", "--only", "bin/git.lua")
check("pull --only swaps the choice: what's no longer wanted goes, the new comes", ok and has("lib/cu.lua")
    and has("bin/git.lua") and not has("bin/cat.lua") and not has("turtle/mine.lua"))
ok = git("pull", "/ccnix")
check("a plain pull keeps the choice", ok and has("lib/cu.lua") and not has("bin/cat.lua") and #fetched == 0)
turtle = nil
ok = git("pull", "/ccnix", "--only", "sim/", "--only", "turtle/mine.lua")
check("on a computer, --only sim/ and a turtle program: fetched though the device rule leaves them out",
    ok and has("sim/lib/mock.lua") and has("turtle/mine.lua") and not has("lib/cu.lua"))
ok = git("pull", "/ccnix", "--only", "sim/", "--skip", "sim/lib")
check("a --skip given as well still leaves its folder out", ok and has("sim/mine_tunnel.lua") and not has("sim/lib/mock.lua"))
turtle = {}
ok = git("pull", "/ccnix", "--all")
check("pull --all brings everything back, sim/ too", ok and has("sim/lib/mock.lua") and has("pc/diskclone.lua")
    and has("bin/cat.lua"))

realPrint("== --lower: an overlay on ccnix's ROM keeps only what differs")
-- the ROM: the repo at a commit, with its .manifest (blob shas, the time)
local function rom(commit, date, tree)
    for k in pairs(files) do if k:match("^rom/") then files[k] = nil end end
    local m = { commit = commit, date = date, files = {} }
    for path, text in pairs(tree) do
        files["rom/ccnix/" .. path] = text
        m.files[path] = sha(path, text)
    end
    files["rom/ccnix/.manifest"] = json.encode(m)
end
local function over() return json.decode(files["ccnix/.gitlite"] or "null") end
local function inOver(p) return files["ccnix/" .. p] ~= nil end
local REPO2 = {}
for k, v in pairs(REPO) do REPO2[k] = v end
REPO2["bin/cat.lua"] = string.rep("C", 1100)
REPO2["lib/new.lua"] = string.rep("n", 700)
COMMITS, HEAD, files, CAP, turtle = { c1 = REPO, c2 = REPO2 }, "c1", {}, 200000, nil
DATES = { c1 = "2026-10-01T00:00:00Z", c2 = "2026-10-20T12:00:00+02:00" }
rom("c1", 1790812800, REPO)
local only = { "--only", "bin/", "--only", "lib/", "--only", "pc/" }
ok = git("clone", "https://github.com/me/ccnix", "/ccnix", "--lower", "/rom/ccnix", table.unpack(only))
check("over a ROM at the branch's commit: nothing fetched", ok and #fetched == 0 and next(over().files) == nil,
    #fetched .. " fetched")
check("the overlay remembers the ROM and its commit", over().lower == "/rom/ccnix" and over().lowerCommit == "c1")
HEAD = "c2"
ok = git("pull", "/ccnix")
check("a new commit: only the changed and new files come", ok and #fetched == 2 and inOver("bin/cat.lua")
    and inOver("lib/new.lua") and not inOver("bin/git.lua") and not inOver("lib/cu.lua"),
    table.concat(fetched, " "))
check("and they're tracked; the rest is the ROM's", over().files["bin/cat.lua"] ~= nil and over().files["bin/git.lua"] == nil
    and said("files are /rom/ccnix's"))
rom("c2", 1792490400, REPO2)
ok = git("pull", "/ccnix")
check("the server's ROM catches up: the overlay's copies go, nothing fetched",
    ok and #fetched == 0 and not inOver("bin/cat.lua") and not inOver("lib/new.lua") and next(over().files) == nil
    and over().lowerCommit == "c2")
check("and it says they were dropped for the ROM's, not deleted", said("0 files updated, 0 deleted")
    and said("2 dropped from here: /rom/ccnix has them as they are now"), out[#out])
rom("c1", 1790812800, REPO)
ok = git("pull", "/ccnix")
check("an older ROM under it: what differs comes back", ok and inOver("bin/cat.lua") and inOver("lib/new.lua"))
rom("c3", 1792886400, REPO)
ok = git("pull", "/ccnix")
check("a ROM newer than the branch (dates with an offset): nothing kept", ok and said("is newer than main")
    and not inOver("bin/cat.lua") and next(over().files) == nil and over().lowerCommit == "c3", out[#out])
ok = git("pull", "/ccnix")
check("and it stays that way", ok and #fetched == 0 and not inOver("bin/cat.lua"))
files["ccnix/.gitlite"] = nil
for k in pairs(files) do if k:match("^ccnix/") then files[k] = nil end end
rom("c1", 1790812800, REPO)
files["rom/ccnix/.manifest"] = nil
ok = git("clone", "https://github.com/me/ccnix", "/ccnix", "--lower", "/rom/ccnix", table.unpack(only))
check("no manifest under it: a whole checkout of what's asked for", ok and inOver("bin/cat.lua") and inOver("bin/git.lua")
    and inOver("lib/new.lua") and not inOver("README.md"))
DATES = nil

realPrint("== a busy server: 5xx tried again, the rest not")
COMMITS, HEAD, files, CAP, turtle = { c1 = REPO }, "c1", {}, 50000, nil
FAILS, errs, slept = { { 504 }, { 502 } }, {}, {}
ok, err = git("clone", "https://github.com/me/ccnix", "/ccnix")
check("504 then 502: tried again after 2 s, then 4, and the clone finishes", ok and table.concat(slept, " ") == "2 4"
    and #errs == 2 and errs[1]:find("(HTTP 504); trying again in 2 s", 1, true) ~= nil, table.concat(slept, " "))
files, FAILS, errs, slept = {}, { { 503 }, { 503 }, { 503 }, { 503 } }, {}, {}
ok = git("clone", "https://github.com/me/ccnix", "/ccnix")
check("still failing after 2, 4 and 8 s: it gives up, saying why", not ok and table.concat(slept, " ") == "2 4 8"
    and errs[#errs]:find("(HTTP 503)", 1, true) ~= nil and not errs[#errs]:find("again", 1, true), errs[#errs])
files, FAILS, errs, slept = {}, { { 404 } }, {}, {}
ok = git("clone", "https://github.com/me/ccnix", "/ccnix")
check("a 404: no retry", not ok and #slept == 0 and #errs == 1, errs[1])
files, errs, slept = {}, {}, {}
FAILS = { { 403, { ["X-RateLimit-Remaining"] = "0", ["X-RateLimit-Reset"] = "1793192400" } } }
ok = git("clone", "https://github.com/me/ccnix", "/ccnix")
check("the API's limit used up (403): no retry; until when, in UTC", not ok and #slept == 0
    and errs[1]:find("used up until " .. os.date("!%H:%M UTC", 1793192400) .. ": try again then.", 1, true) ~= nil, errs[1])
FAILS = {}
