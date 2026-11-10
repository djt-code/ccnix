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
-- A server error (5xx, as when many computers on one server update at
-- once) is tried again after 2, 4 and 8 s.  GitHub allows each address
-- so many API requests an hour without a token, and a server's computers
-- share one; when they're used up it says until when.
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

-- ccnix's lib/, or the one beside this bin/.  (Fetched alone by
-- deploy/setup, git runs in setup's environment, which has the text
-- libraries loaded already.)
package.path = (ccnix and ccnix.lib or "/" .. fs.getDir(fs.getDir(shell.getRunningProgram())) .. "/lib/?.lua;") .. package.path
local text = require("text")
local path = require("path")
local convert = require("convert")
local getopt = require("getopt")
local fileio = require("fileio")
local tables = require("tables")

-- Show lines in pager.lua when it can be found (deploy/setup's copy of
-- git has the text libraries but no pager), otherwise a screenful at a
-- time with textutils.pagedPrint.
local function page(lines)
    local _, pager = pcall(require, "pager")
    if type(pager) == "table" and pager.page then pager.page(lines)
    else textutils.pagedPrint(table.concat(lines, "\n")) end
end

-- each name in a repo path, as it goes in a URL (%XX for anything but
-- letters, digits and -._~), the empty ones left out
local function encodePath(p)
    local out = {}
    for _, name in ipairs(path.segments(p)) do out[#out + 1] = convert.urlEncode(name) end
    return table.concat(out, "/")
end

local unjson = textutils.unserialiseJSON or textutils.unserializeJSON
local tojson = textutils.serialiseJSON or textutils.serializeJSON

-- A response header, whatever its case (servers differ)
local function header(headers, name)
    for k, v in pairs(headers or {}) do
        if text.equalFold(k, name) then return v end
    end
end

-- A server error (5xx: busy, or a gateway timing out, as when a server's
-- worth of computers update at once) is tried again after 2, 4 and 8 s;
-- anything else fails at once.  The REST API allows an address so many
-- requests an hour without a token, and every computer on a server shares
-- one: when they're used up, it says until when.
local RETRIES = 3

local function request(url, headers, binary)
    local wait = 2
    for try = 1, RETRIES + 1 do
        local h, err, failed = http.get({ url = url, headers = headers, binary = binary })
        if h then
            local body = h.readAll()
            h.close()
            return body
        end
        local code = failed and failed.getResponseCode and failed.getResponseCode()
        local got = failed and failed.getResponseHeaders and failed.getResponseHeaders()
        if failed and failed.close then failed.close() end
        local what = string.format("GET %s failed: %s%s", url, tostring(err), code and (" (HTTP " .. code .. ")") or "")
        if not (code and code >= 500) or try > RETRIES then
            if header(got, "x-ratelimit-remaining") == "0" then
                local reset = tonumber(header(got, "x-ratelimit-reset"))
                what = what .. "\nThe API's requests for this address are used up"
                    .. (reset and (" until " .. os.date("!%H:%M UTC", reset)) or "")
                    .. ": try again then."
            end
            die(what)
        end
        printError(what .. "; trying again in " .. wait .. " s")
        sleep(wait)
        wait = wait * 2
    end
end

local function requestJSON(url, headers)
    local body = request(url, headers, false)
    local obj, err = unjson(body)
    if obj == nil then die("Bad JSON from " .. url .. ": " .. tostring(err)) end
    return obj
end

local function readState(dir) return fileio.readJSON(fs.combine(dir, STATE_FILE)) end

local function writeState(dir, state)
    local ok, err = fileio.write(fs.combine(dir, STATE_FILE), tojson(state))
    if not ok then die(err) end
end

local function writeFile(file, data)
    local parent = fs.getDir(file)
    if parent ~= "" and not fs.exists(parent) then fs.makeDir(parent) end
    local ok, err = fileio.write(file, data, true)
    if not ok then die(err) end
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
-- repo URL: ("http" | "https") "://" host "/" owner "/" repo, then
-- anything after a "/", "?" or "#": scheme, host, owner, repo; nil if not one
local function parseRepoURL(url)
    local scheme = (text.startsWith(url, "https://") and "https") or (text.startsWith(url, "http://") and "http")
    if not scheme then return nil end
    local host, rest = text.cut(url:sub(#scheme + #"://" + 1), "/")
    if host == "" or not rest then return nil end
    local owner
    owner, rest = text.cut(rest, "/")
    if owner == "" or not rest then return nil end
    local stop = #rest + 1                                -- (the repo ends at a / ? or #)
    for _, mark in ipairs({ "/", "?", "#" }) do
        local found = text.find(rest, mark)
        if found and found < stop then stop = found end
    end
    local repo = rest:sub(1, stop - 1)
    if repo == "" then return nil end
    return scheme, host, owner, repo
end

local function makeRemote(url, token)
    local scheme, host, owner, repo = parseRepoURL(url)
    if not repo then die("Can't parse repo URL: " .. url) end
    if text.endsWith(repo, ".git") then repo = repo:sub(1, -5) end
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
            return convert.fromDateTime((c.committer or {}).date or (c.author or {}).date)
        end
        R.treeUrl = function(sha, page)
            return R.api .. "/git/trees/" .. sha .. "?recursive=1"
        end
        R.rawUrl = function(sha, path)
            return "https://raw.githubusercontent.com/" .. owner .. "/" .. repo
                   .. "/" .. sha .. "/" .. encodePath(path)
        end
        R.logUrl = function(branch, n)
            return R.api .. "/commits?sha=" .. convert.urlEncode(branch) .. "&per_page=" .. n
        end
    else
        R.kind = "forgejo"
        R.api  = scheme .. "://" .. host .. "/api/v1/repos/" .. owner .. "/" .. repo
        if token then R.headers["Authorization"] = "token " .. token end
        R.branchSha = function(j) return j.commit.id end
        R.branchDate = function(j) return convert.fromDateTime(j.commit.timestamp) end
        R.treeUrl = function(sha, page)
            return R.api .. "/git/trees/" .. sha .. "?recursive=true&per_page=1000&page=" .. page
        end
        R.rawUrl = function(sha, path)
            return R.api .. "/raw/" .. encodePath(path) .. "?ref=" .. sha
        end
        R.logUrl = function(branch, n)
            return R.api .. "/commits?sha=" .. convert.urlEncode(branch) .. "&limit=" .. n .. "&stat=false"
        end
    end

    function R.defaultBranch()
        return requestJSON(R.api, R.headers).default_branch
    end

    -- The branch's commit, and its time (seconds, or nil)
    function R.headCommit(branch)
        local j = requestJSON(R.api .. "/branches/" .. convert.urlEncode(branch), R.headers)
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
            if path == o or (text.endsWith(o, "/") and text.startsWith(path, o)) then wanted = true; break end
        end
        if not wanted then return true end
    end
    for _, d in ipairs(state.skip or {}) do
        if path == d or text.startsWith(path, d .. "/") then return true end
    end
    return false
end

-- The read-only copy under an overlay checkout: its .manifest, { commit,
-- date, files = { [path] = blobSha } }, or {} if it has none
local function lowerManifest(state)
    if not state.lower then return {} end
    return fileio.readJSON(fs.combine(state.lower, ".manifest")) or {}
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

    for _, path in ipairs(tables.sortedKeys(remote)) do
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
-- A path in the repo as --skip and --only name it: from the top, no "/"
-- at its start; a folder for --only keeps the "/" at its end ("sim/").
local function repoPath(p, folderSlash)
    local rel = text.join(path.segments(p), "/")
    if folderSlash and rel ~= "" and text.endsWith(p, "/") then rel = rel .. "/" end
    return rel
end

-- the options (anywhere among the operands: git clone url dir --only lib/)
local LONG = { branch = "b", token = "=", skip = "=", only = "=", all = true, lower = "=" }

local function parseArgs(list)
    local given, pos, order = getopt.parseMixed(list, "b:n:", LONG)
    if not given then die(pos) end
    local opts = { branch = given.b, token = given.token, all = given.all, lower = given.lower,
                   count = given.n and convert.toInteger(given.n) }
    for _, o in ipairs(order) do                       -- (--skip and --only add up)
        if o[1] == "skip" then
            opts.skip = opts.skip or {}
            opts.skip[#opts.skip + 1] = repoPath(o[2], false)
        elseif o[1] == "only" then
            opts.only = opts.only or {}
            opts.only[#opts.only + 1] = repoPath(o[2], true)
        end
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
        local subject = text.cut(c.message, "\n")              -- (the first line)
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

local COMMANDS = { clone = cmdClone, pull = cmdPull, status = cmdStatus, log = cmdLog }
if COMMANDS[cmd] then COMMANDS[cmd](pos, opts)
else
    print("Usage:")
    print("  git clone <url> [dir] [-b branch] [--token t]")
    print("            [--skip dir]... [--only path]... [--all] [--lower dir]")
    print("  git pull [dir] [--skip dir]... [--only path]... [--all] [--lower dir]")
    print("  git status [dir]")
    print("  git log [dir] [-n count]")
end
