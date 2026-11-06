-- git.lua -- minimal git client for CC:Tweaked
--
-- Clones and pulls a single branch over HTTP using the hosting server's
-- REST API (Forgejo/Gitea or GitHub) instead of the git wire protocol, so
-- there are no packfiles to decode.  Tracks the commit and blob SHAs of
-- what it checked out in .gitlite, and on pull only downloads blobs whose
-- SHA changed, deletes tracked files removed upstream, and never touches
-- untracked files.
--
-- A computer's disk is small (1 MB by default), so a clone leaves out
-- what the device doesn't run: sim/ always, pc/ on a turtle and turtle/
-- on a computer.  --skip <dir> leaves out more, --all nothing, and
-- --only <path> (a file, or a folder ending in /) takes just those, sim/
-- and the other device's folder too if named (the device rule is for
-- when nothing is); the choice
-- is kept in .gitlite and pull keeps to it (a checkout from before this
-- gets the device's rule on its next pull, and loses those folders).  If the disk fills anyway it
-- stops, keeping what it got, and `git pull` carries on once there's room.
-- The same options on pull change the choice (deploy/setup uses --only to
-- put just the apps you name on a device).
--
-- --lower <dir> makes the checkout an overlay on a read-only copy of the
-- repo (ccnix's ROM, /rom/ccnix: see bin/ccnix.lua): a file whose blob the
-- copy's .manifest lists the same isn't fetched, and is deleted here if it
-- was, so only what differs takes disk.  When the copy's commit is newer
-- than the branch's, nothing is kept.  The choice is kept for pulls.
--
-- Usage:
--   git clone <url> [dir] [-b <branch>] [--token <token>] [--skip <dir>]... [--only <path>]... [--all] [--lower <dir>]
--   git pull   [dir] [--skip <dir>]... [--only <path>]... [--all] [--lower <dir>]
--   git status [dir]
--   git log    [dir] [-n <count>]
--
--   <url> is the repo's web URL, with or without .git:
--     https://git.example.com/me/ccnix
--     https://github.com/djt-code/ccnix.git
--
-- Bootstrap onto a turtle or computer: deploy/setup.lua does it all;
--   wget run https://raw.githubusercontent.com/djt-code/ccnix/main/deploy/setup.lua
--
-- --token is only needed for private repos (Forgejo access token or
-- GitHub PAT); it is saved in .gitlite so pull can reuse it.
--
-- Git is the Git project's (https://git-scm.com), and "Git" is a trademark
-- of Software Freedom Conservancy.  This isn't Git, only a small client
-- for ccnix that borrows its name and a few of its commands.

local STATE_FILE = ".gitlite"

-- What a clone leaves out unless told otherwise: the simulators, and the
-- programs for the other kind of device.
local function defaultSkip()
    return { "sim", turtle and "pc" or "turtle" }
end

--------------------------------------------------------------------------
-- Small helpers
--------------------------------------------------------------------------
local function die(msg)
    printError(msg)
    error("", 0)
end

-- Show lines in pager.lua when it can be found (in lib/ beside this bin/;
-- the bootstrap copy of git sits on its own), otherwise a screenful at a
-- time with textutils.pagedPrint.
local function page(lines)
    package.path = (ccnix and ccnix.lib or "/" .. fs.getDir(fs.getDir(shell.getRunningProgram())) .. "/lib/?.lua;") .. package.path
    local _, pager = pcall(require, "pager")
    if type(pager) == "table" and pager.page then pager.page(lines)
    else textutils.pagedPrint(table.concat(lines, "\n")) end
end

local function encodeSegment(s)
    return (s:gsub("[^%w%-%._~]", function(c)
        return string.format("%%%02X", c:byte())
    end))
end

local function encodePath(path)
    local out = {}
    for seg in path:gmatch("[^/]+") do out[#out + 1] = encodeSegment(seg) end
    return table.concat(out, "/")
end

local unjson = textutils.unserialiseJSON or textutils.unserializeJSON
local tojson = textutils.serialiseJSON or textutils.serializeJSON

-- Seconds since 1970 for an ISO 8601 time ("2026-10-29T21:04:05Z",
-- "...+02:00"), or nil
local function isoTime(s)
    local y, mo, d, h, mi, se, rest = tostring(s):match("^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)%.?%d*(.*)$")
    if not y then return nil end
    y, mo, d = tonumber(y), tonumber(mo), tonumber(d)
    if mo <= 2 then y, mo = y - 1, mo + 12 end            -- (days from 1970, the civil calendar)
    local days = 365 * y + math.floor(y / 4) - math.floor(y / 100) + math.floor(y / 400)
        + math.floor((153 * (mo - 3) + 2) / 5) + d - 719469
    local t = days * 86400 + tonumber(h) * 3600 + tonumber(mi) * 60 + tonumber(se)
    local sign, oh, om = rest:match("^([+-])(%d%d):?(%d%d)$")
    if sign then t = t - (sign == "+" and 1 or -1) * (tonumber(oh) * 3600 + tonumber(om) * 60) end
    return t
end

local function request(url, headers, binary)
    local h, err, failed = http.get({ url = url, headers = headers, binary = binary })
    if not h then
        local code = failed and failed.getResponseCode and failed.getResponseCode()
        if failed and failed.close then failed.close() end
        die(string.format("GET %s failed: %s%s", url, tostring(err),
            code and (" (HTTP " .. code .. ")") or ""))
    end
    local body = h.readAll()
    h.close()
    return body
end

local function requestJSON(url, headers)
    local body = request(url, headers, false)
    local obj, err = unjson(body)
    if obj == nil then die("Bad JSON from " .. url .. ": " .. tostring(err)) end
    return obj
end

local function readState(dir)
    local p = fs.combine(dir, STATE_FILE)
    if not fs.exists(p) then return nil end
    local f = fs.open(p, "r")
    local s = unjson(f.readAll())
    f.close()
    return s
end

local function writeState(dir, state)
    local f = fs.open(fs.combine(dir, STATE_FILE), "w")
    f.write(tojson(state))
    f.close()
end

local function writeFile(path, data)
    local parent = fs.getDir(path)
    if parent ~= "" and not fs.exists(parent) then fs.makeDir(parent) end
    local f = fs.open(path, "wb")
    f.write(data)
    f.close()
end

-- Remove now-empty directories left behind by deleted files.
local function pruneDirs(dir, path)
    local parent = fs.getDir(path)
    while parent ~= "" and parent ~= dir and fs.isDir(parent)
          and #fs.list(parent) == 0 do
        fs.delete(parent)
        parent = fs.getDir(parent)
    end
end

--------------------------------------------------------------------------
-- Remote adapters: Forgejo/Gitea (default) and GitHub
--------------------------------------------------------------------------
local function makeRemote(url, token)
    local scheme, host, owner, repo = url:match("^(https?)://([^/]+)/([^/]+)/([^/?#]+)")
    if not repo then die("Can't parse repo URL: " .. url) end
    repo = repo:gsub("%.git$", "")
    local R = { url = scheme .. "://" .. host .. "/" .. owner .. "/" .. repo,
                host = host, owner = owner, repo = repo, headers = {} }

    if host == "github.com" or host == "www.github.com" then
        R.kind = "github"
        R.api  = "https://api.github.com/repos/" .. owner .. "/" .. repo
        R.headers["Accept"] = "application/vnd.github+json"
        R.headers["User-Agent"] = "cc-tweaked-git"
        if token then R.headers["Authorization"] = "Bearer " .. token end
        R.branchSha = function(j) return j.commit.sha end
        R.branchDate = function(j)
            local c = j.commit.commit or {}
            return isoTime((c.committer or {}).date or (c.author or {}).date)
        end
        R.treeUrl = function(sha, page)
            return R.api .. "/git/trees/" .. sha .. "?recursive=1"
        end
        R.rawUrl = function(sha, path)
            return "https://raw.githubusercontent.com/" .. owner .. "/" .. repo
                   .. "/" .. sha .. "/" .. encodePath(path)
        end
        R.logUrl = function(branch, n)
            return R.api .. "/commits?sha=" .. encodeSegment(branch) .. "&per_page=" .. n
        end
    else
        R.kind = "forgejo"
        R.api  = scheme .. "://" .. host .. "/api/v1/repos/" .. owner .. "/" .. repo
        if token then R.headers["Authorization"] = "token " .. token end
        R.branchSha = function(j) return j.commit.id end
        R.branchDate = function(j) return isoTime(j.commit.timestamp) end
        R.treeUrl = function(sha, page)
            return R.api .. "/git/trees/" .. sha .. "?recursive=true&per_page=1000&page=" .. page
        end
        R.rawUrl = function(sha, path)
            return R.api .. "/raw/" .. encodePath(path) .. "?ref=" .. sha
        end
        R.logUrl = function(branch, n)
            return R.api .. "/commits?sha=" .. encodeSegment(branch) .. "&limit=" .. n .. "&stat=false"
        end
    end

    function R.defaultBranch()
        return requestJSON(R.api, R.headers).default_branch
    end

    -- The branch's commit, and its time (seconds, or nil)
    function R.headCommit(branch)
        local j = requestJSON(R.api .. "/branches/" .. encodeSegment(branch), R.headers)
        return R.branchSha(j), R.branchDate(j)
    end

    -- Returns { [path] = blobSha } for every file in the tree.
    function R.tree(sha)
        local files, count, page = {}, 0, 1
        while true do
            local j = requestJSON(R.treeUrl(sha, page), R.headers)
            local entries = j.tree or {}
            for _, e in ipairs(entries) do
                if e.type == "blob" then files[e.path] = e.sha end
            end
            count = count + #entries
            if j.truncated == true and R.kind == "github" then
                die("Repository tree too large for the GitHub API (truncated).")
            end
            local total = j.total_count
            if not total or count >= total or #entries == 0 then break end
            page = page + 1
        end
        return files
    end

    -- Recent commits on a branch: { {sha, message, author, date}, ... }
    function R.log(branch, n)
        local list = requestJSON(R.logUrl(branch, n), R.headers)
        local out = {}
        for _, c in ipairs(list) do
            local cm = c.commit or {}
            local au = cm.author or {}
            out[#out + 1] = { sha = c.sha, message = cm.message or "",
                              author = au.name or "?", date = au.date or "" }
        end
        return out
    end

    function R.blob(sha, path)
        return request(R.rawUrl(sha, path), R.headers, true)
    end

    return R
end

--------------------------------------------------------------------------
-- Checkout: bring `dir` from state.files to the tree at `commit`
--------------------------------------------------------------------------
local function skipped(state, path)
    if state.only then
        local wanted = false
        for _, o in ipairs(state.only) do
            if path == o or (o:sub(-1) == "/" and path:sub(1, #o) == o) then wanted = true; break end
        end
        if not wanted then return true end
    end
    for _, d in ipairs(state.skip or {}) do
        if path == d or path:sub(1, #d + 1) == d .. "/" then return true end
    end
    return false
end

-- The read-only copy under an overlay checkout: its .manifest, { commit,
-- date, files = { [path] = blobSha } }, or {} if it has none
local function lowerManifest(state)
    if not state.lower then return {} end
    local p = fs.combine(state.lower, ".manifest")
    if not fs.exists(p) then return {} end
    local f = fs.open(p, "r")
    local m = unjson(f.readAll())
    f.close()
    return type(m) == "table" and m or {}
end

local function checkout(R, dir, state, commit)
    local lower = lowerManifest(state)
    local lowerFiles = lower.files or {}
    local remote, fromLower = {}, 0
    local tree = R.tree(commit)
    for path, sha in pairs(tree) do
        if skipped(state, path) then
            -- not wanted
        elseif lowerFiles[path] == sha then
            fromLower = fromLower + 1                   -- (the copy below has it)
        else
            remote[path] = sha
        end
    end
    state.lowerCommit = lower.commit
    local have = state.files or {}
    local fetched, deleted, dropped = 0, 0, 0

    -- deletions first, so files that moved don't need room twice (one the
    -- copy below now has as it is is dropped, not deleted: it's still there)
    local got = {}
    for path, sha in pairs(have) do
        if remote[path] then
            got[path] = sha
        else
            local p = fs.combine(dir, path)
            if fs.exists(p) then fs.delete(p); pruneDirs(dir, p) end
            if tree[path] and lowerFiles[path] == tree[path] then dropped = dropped + 1 else deleted = deleted + 1 end
        end
    end
    state.files = got
    writeState(dir, state)

    local paths = {}
    for path in pairs(remote) do paths[#paths + 1] = path end
    table.sort(paths)
    for _, path in ipairs(paths) do
        local sha, p = remote[path], fs.combine(dir, path)
        if have[path] ~= sha or not fs.exists(p) then
            print("  " .. path)
            local data = R.blob(commit, path)
            -- CC counts a file as at least 500 bytes; keep room for .gitlite
            -- to grow, as it's what lets a pull carry on from here
            local need = math.max(#data, 500) - (fs.exists(p) and math.max(fs.getSize(p), 500) or 0)
            local sp = fs.combine(dir, STATE_FILE)
            local room = fs.getFreeSpace(dir) - (fs.exists(sp) and fs.getSize(sp) or 0) - 1024
            if need > room then
                state.files[path] = nil
                writeState(dir, state)              -- what's here so far
                die(string.format("Out of disk space at %s (%d bytes, %d free). " ..
                    "Delete something, then `git pull` carries on.", path, #data, math.max(room, 0)))
            end
            writeFile(p, data)
            state.files[path] = sha
            fetched = fetched + 1
        end
    end

    state.commit = commit
    writeState(dir, state)
    if state.lower then print(string.format("%d files are %s's, as they are there.", fromLower, state.lower)) end
    return fetched, deleted, dropped
end

-- An overlay whose copy below is newer than the branch: nothing to keep
local function lowerIsNewer(dir, state, date)
    local lower = lowerManifest(state)
    if not (lower.date and date and lower.date > date) then return false end
    for path in pairs(state.files or {}) do
        local p = fs.combine(dir, path)
        if fs.exists(p) then fs.delete(p); pruneDirs(dir, p) end
    end
    state.files, state.commit, state.lowerCommit = {}, lower.commit, lower.commit
    writeState(dir, state)
    print(state.lower .. " is newer than " .. state.branch .. ": nothing to keep here.")
    return true
end

--------------------------------------------------------------------------
-- Commands
--------------------------------------------------------------------------
local function parseArgs(list)
    local pos, opts = {}, {}
    local i = 1
    while i <= #list do
        local a = list[i]
        if a == "-b" or a == "--branch" then opts.branch = list[i + 1]; i = i + 1
        elseif a == "--token" then opts.token = list[i + 1]; i = i + 1
        elseif a == "--skip" then
            opts.skip = opts.skip or {}
            opts.skip[#opts.skip + 1] = (list[i + 1] or ""):gsub("^/+", ""):gsub("/+$", "")
            i = i + 1
        elseif a == "--only" then
            opts.only = opts.only or {}
            opts.only[#opts.only + 1] = ((list[i + 1] or ""):gsub("^/+", ""))
            i = i + 1
        elseif a == "--all" then opts.all = true
        elseif a == "--lower" then opts.lower = list[i + 1]; i = i + 1
        elseif a == "-n" then opts.count = tonumber(list[i + 1]); i = i + 1
        else pos[#pos + 1] = a end
        i = i + 1
    end
    return pos, opts
end

-- What to leave out given the options, or nil if they don't say: --all
-- nothing; --skip adds to the device's rule, but with --only the paths
-- named are fetched wherever they are, so only --skip's folders are left out.
local function chosenSkip(opts)
    if opts.all then return {} end
    if opts.only then return opts.skip or {} end
    if opts.skip then
        local skip = defaultSkip()
        for _, d in ipairs(opts.skip) do skip[#skip + 1] = d end
        return skip
    end
end

local function cmdClone(pos, opts)
    local url = pos[1] or die("Usage: git clone <url> [dir] [-b branch] [--token t] [--skip dir]... [--only path]... [--all]")
    local R = makeRemote(url, opts.token)
    local dir = shell.resolve(pos[2] or R.repo)
    if fs.exists(fs.combine(dir, STATE_FILE)) then
        die(dir .. " already contains a checkout; use `git pull`.")
    end
    local skip = chosenSkip(opts) or defaultSkip()
    local branch = opts.branch or R.defaultBranch()
    local commit, date = R.headCommit(branch)
    print(string.format("Cloning %s (%s @ %s) into %s", R.url, branch, commit:sub(1, 7), dir))
    fs.makeDir(dir)
    if #skip > 0 then print("Leaving out " .. table.concat(skip, "/, ") .. "/ (--all for everything)") end
    if opts.only then print("Taking only " .. table.concat(opts.only, ", ")) end
    local state = { url = R.url, branch = branch, token = opts.token, files = {}, skip = skip,
                    only = (not opts.all) and opts.only or nil, lower = opts.lower }
    if state.lower then print("Over " .. state.lower .. ": only what differs comes") end
    if lowerIsNewer(dir, state, date) then return end
    local n = checkout(R, dir, state, commit)
    print(string.format("Done: %d files.", n))
end

local function openCheckout(pos)
    local dir = shell.resolve(pos[1] or ".")
    local state = readState(dir)
    if not state then die("No " .. STATE_FILE .. " in " .. dir .. " (not a checkout).") end
    return dir, state, makeRemote(state.url, state.token)
end

local function cmdPull(pos, opts)
    local dir, state, R = openCheckout(pos)
    local commit, date = R.headCommit(state.branch)
    if opts.lower and opts.lower ~= state.lower then
        state.lower = opts.lower                        -- (an overlay now: go over every file)
        state.commit = nil
    end
    if opts.all or opts.skip or opts.only then
        -- a new choice of what to keep: go over every file again
        state.skip = chosenSkip(opts) or state.skip or defaultSkip()
        state.only = (not opts.all) and opts.only or nil
        state.commit = nil
    elseif state.skip == nil then
        -- a checkout from before the device rule: it gets it now
        state.skip = defaultSkip()
        print("Leaving out " .. table.concat(state.skip, "/, ") .. "/ from now on")
        state.commit = nil
    end
    if lowerIsNewer(dir, state, date) then return end
    if commit == state.commit and state.lowerCommit == lowerManifest(state).commit then
        print("Already up to date (" .. commit:sub(1, 7) .. ").")
        return
    end
    print(string.format("Updating %s..%s on %s",
        (state.commit or ""):sub(1, 7), commit:sub(1, 7), state.branch))
    local fetched, deleted, dropped = checkout(R, dir, state, commit)
    print(string.format("Done: %d files updated, %d deleted.", fetched, deleted))
    if dropped > 0 then
        print(string.format("%d dropped from here: %s has them as they are now.", dropped, state.lower))
    end
end

local function cmdStatus(pos)
    local dir, state, R = openCheckout(pos)
    local n = 0
    for _ in pairs(state.files or {}) do n = n + 1 end
    print("Remote:  " .. state.url)
    print("Branch:  " .. state.branch)
    print("Commit:  " .. (state.commit or "none"))
    print("Files:   " .. n .. " tracked")
    if state.skip and #state.skip > 0 then print("Skips:   " .. table.concat(state.skip, "/ ") .. "/") end
    if state.only then print("Only:    " .. table.concat(state.only, " ")) end
    if state.lower then print("Over:    " .. state.lower .. " (" .. (state.lowerCommit or "no manifest"):sub(1, 7) .. ")") end
    local ok, head = pcall(R.headCommit, state.branch)
    if ok then
        print(head == state.commit and "Up to date with remote."
              or ("Remote is at " .. head:sub(1, 7) .. "; run `git pull`."))
    end
end

local function cmdLog(pos, opts)
    local dir, state, R = openCheckout(pos)
    local n = opts.count or 10
    local commits = R.log(state.branch, n)
    local lines = {}
    for _, c in ipairs(commits) do
        local marker = (c.sha == state.commit) and "*" or " "
        local subject = c.message:match("^[^\n]*")
        lines[#lines + 1] = string.format("%s%s %s", marker, c.sha:sub(1, 7), subject)
        lines[#lines + 1] = string.format("   %s  %s", c.author, c.date:sub(1, 10))
    end
    if #commits == 0 then lines[#lines + 1] = "No commits." end
    lines[#lines + 1] = "(* = checked out)"
    page(lines)          -- a screenful at a time
end

--------------------------------------------------------------------------
local pos, opts = parseArgs({ ... })
local cmd = table.remove(pos, 1)

if not http then die("HTTP is disabled on this server.") end

if cmd == "clone" then cmdClone(pos, opts)
elseif cmd == "pull" then cmdPull(pos, opts)
elseif cmd == "status" then cmdStatus(pos)
elseif cmd == "log" then cmdLog(pos, opts)
else
    print("Usage:")
    print("  git clone <url> [dir] [-b branch] [--token t]")
    print("            [--skip dir]... [--only path]... [--all] [--lower dir]")
    print("  git pull [dir] [--skip dir]... [--only path]... [--all] [--lower dir]")
    print("  git status [dir]")
    print("  git log [dir] [-n count]")
end
