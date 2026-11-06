-- ccnix.lua -- this computer's ccnix: where it comes from, and updates
--
--   ccnix            what the ROM has (its version and commit), and this
--                    computer's updates over it, if any
--   ccnix version    the version in use (semantic: major.minor.patch), and
--                    the one a reboot brings if an update or reset changed it
--   ccnix update     the latest from the ROM's repo into /ccnix with git,
--                    keeping only the files that differ from the ROM's;
--                    reboot to use them (all of them: until then, programs
--                    already found keep the ROM's)
--   ccnix reset      drop the updates: back to the ROM (files of your own
--                    in /ccnix, a turtle's job files, stay)
--   ccnix setup [app...] [options]
--                    choose what this computer runs (deploy/setup: the
--                    apps, --autostart, ccsh at boot...; `help setup`)
--
-- The ccnix mod puts this repo in every computer's ROM, at /rom/ccnix;
-- deploy/boot.lua says how the two layers go together.  When the ROM is
-- newer than the repo's branch, an update keeps nothing: the ROM is it.
-- The server's ops update the ROM itself: /ccnix rom update (the mod's
-- README).  On a server without the mod, ccnix is a whole checkout at
-- /ccnix (deploy/setup clones it there), and update is a git pull of that;
-- ccnix setup there pulls too.
-- The version is deploy/version's: a ROM from before there was one shows
-- as "unversioned".
-- `help ccnix` goes on with every command ccnix adds.

local ROM, OVER = "/rom/ccnix", "/ccnix"
local unjson = textutils.unserialiseJSON or textutils.unserializeJSON
local args = { ... }

local function readJSON(path)
    if not fs.exists(path) or fs.isDir(path) then return nil end
    local f = fs.open(path, "r")
    local text = f.readAll()
    f.close()
    local ok, v = pcall(unjson, text or "")
    return ok and type(v) == "table" and v or nil
end

local function die(msg)
    printError("ccnix: " .. msg)
    error("", 0)
end

local manifest = readJSON(ROM .. "/.manifest")
local state = readJSON(OVER .. "/.gitlite")
local function count(t)
    local n = 0
    for _ in pairs(t or {}) do n = n + 1 end
    return n
end
local function when(t)
    return t and os.date("!%Y-%m-%d %H:%M", t) .. " UTC" or "?"
end

-- The program at a repo path: this computer's updates first, then the
-- ROM's, or (no ccnix in ROM) the one in this program's own checkout
local function find(path)
    if ccnix and ccnix.find then return ccnix.find(path) end
    for _, r in ipairs({ OVER, ROM, "/" .. fs.getDir(fs.getDir(shell.getRunningProgram())) }) do
        if fs.exists(r .. "/" .. path) then return r .. "/" .. path end
    end
end

-- The version in the file at path (deploy/version), or nil.
local function versionIn(path)
    if not path or not fs.exists(path) or fs.isDir(path) then return nil end
    local f = fs.open(path, "r")
    local text = f.readAll() or ""
    f.close()
    return text:match("^%s*(%S+)")
end
local romVersion = versionIn(ROM .. "/deploy/version") or "unversioned"

local cmd = args[1]
if cmd == nil or cmd == "status" then
    if manifest then
        print(string.format("ROM: ccnix %s, %s %s at %s (%s)", romVersion, manifest.url or "?", manifest.branch or "?",
            (manifest.commit or "?"):sub(1, 7), when(manifest.date)))
        print("  " .. count(manifest.files) .. " files, from " .. (manifest.source or "the mod"))
    else
        print("No ccnix in ROM here (a server without the mod).")
    end
    if not state then
        print(manifest and "Updates: none (ccnix update fetches any)" or "No ccnix here: deploy/setup installs it.")
    elseif state.lower == nil then
        print(string.format("%s: ccnix %s, a whole checkout at %s, %d files", OVER,
            versionIn(OVER .. "/deploy/version") or "unversioned", (state.commit or "?"):sub(1, 7), count(state.files)))
    else
        local inUse = manifest and state.lowerCommit == manifest.commit
        local booted = not (ccnix and ccnix.updates == false)   -- (made since this boot: not yet)
        -- (a version file the same as the ROM's isn't kept)
        print(string.format("Updates: ccnix %s, %d files at %s, %s", versionIn(OVER .. "/deploy/version") or romVersion,
            count(state.files), (state.commit or "?"):sub(1, 7),
            not inUse and "made for another ROM: ccnix update" or booted and "in use" or "in use after a reboot"))
    end
    if manifest and not state and ccnix and ccnix.updates then
        print("  (the updates dropped stay in use until a reboot)")
    end
    if fs.exists("/cc-turtles/.gitlite") then
        print("An install from before ccnix runs this computer (/cc-turtles); deploy/setup moves it over.")
    end

elseif cmd == "version" then
    -- in use: what this boot read; next: the updates if they're for this
    -- ROM (their version, or the ROM's if they kept none), else the ROM's
    local now = (ccnix and ccnix.version) or versionIn(find("deploy/version")) or "unversioned"
    local nextV
    if manifest then
        local current = state and (state.lower == nil or state.lowerCommit == manifest.commit)
        nextV = current and versionIn(OVER .. "/deploy/version") or romVersion
    else
        nextV = versionIn(find("deploy/version")) or "unversioned"
    end
    print("ccnix " .. now .. (nextV ~= now and (" (" .. nextV .. " after a reboot)") or ""))

elseif cmd == "update" then
    local git = find("bin/git.lua") or die("no git")
    local only = { "bin/", "lib/", "help/", "deploy/", turtle and "turtle/" or "pc/" }
    local opts = {}
    for _, p in ipairs(only) do opts[#opts + 1] = "--only"; opts[#opts + 1] = p end
    local ok
    if not manifest then
        if not state then die("no ccnix in ROM, and no checkout at " .. OVER .. ": deploy/setup makes one") end
        ok = shell.run(git, "pull", OVER)
    elseif state then
        ok = shell.run(git, "pull", OVER, "--lower", ROM, table.unpack(opts))
    else
        ok = shell.run(git, "clone", manifest.url, OVER, "-b", manifest.branch, "--lower", ROM, table.unpack(opts))
    end
    if not ok then die("git stopped; run it again when what it said is fixed") end
    print("Reboot to use the updates.")

elseif cmd == "reset" then
    if not state then print("No updates here."); return end
    if state.lower == nil then die(OVER .. " is a whole checkout, not updates over a ROM: delete it yourself if you mean to") end
    for path in pairs(state.files or {}) do
        local p = OVER .. "/" .. path
        if fs.exists(p) then fs.delete(p) end
        local dir = fs.getDir(p)
        while dir ~= "" and dir ~= fs.combine(OVER, "") and fs.isDir(dir) and #fs.list(dir) == 0 do
            fs.delete(dir)
            dir = fs.getDir(dir)
        end
    end
    fs.delete(OVER .. "/.gitlite")
    print("Back to the ROM's: reboot to use it.")

elseif cmd == "setup" then
    local setup = find("deploy/setup.lua") or die("no deploy/setup.lua")
    shell.run(setup, table.unpack(args, 2))

else
    print("Usage: ccnix [status | version | update | reset | setup [app...]]")
end
