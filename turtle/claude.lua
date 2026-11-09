-- claude.lua -- let Claude drive the turtle
--
-- Talks to the Claude API (Anthropic) from the turtle over HTTP and gives
-- the model one tool that matters: `lua`, which runs the Lua it writes on
-- the turtle, with the turtle API and turtlelib (T) in scope.  You give
-- it a goal; it works at it, call by call, says what it did, and asks
-- when it isn't sure.
--
-- Usage:
--   claude [goal words...] [--model id] [--effort low|medium|high]
--          [--steps N] [--confirm]
--
--   claude dig a 3 by 3 tunnel 20 blocks ahead and come back
--   claude                      asks for the goal
--
--   --steps N    at most N tool calls per goal (default 60), then it's
--                told to stop and sum up
--   --confirm    show each piece of code and ask before running it
--
-- When it stops, type the next thing to do (it keeps the conversation),
-- or press Enter on an empty line to quit.  Ctrl+T stops it (under T.run,
-- so the saved position stays right).
--
-- Colour (an advanced computer or turtle): the code it runs is highlighted
-- as `edit` does it, what the code prints is grey, prompts and questions
-- yellow, retries orange, errors red; Claude's own words are white.
--
-- Reading back: when more comes out than the screen holds, it opens in
-- the pager (lib/pager.lua) at the first line you haven't seen before it
-- asks you anything: the mouse wheel, arrows or space to scroll, q to
-- get to the prompt.  At an empty prompt, the wheel up (or PgUp) opens
-- the whole session.
--
-- Setup:
--   * put an API key in `claude.key` next to this program (`edit
--     claude.key`, paste the key, save).  Make it a key of its own with a
--     spending limit: anything on a computer's disk can be read by whoever
--     can open the turtle or the server's save folder.  The file is in
--     .gitignore, and `git pull` never touches untracked files.
--   * the server's CC:Tweaked config must allow HTTP to api.anthropic.com
--     (the same `http.rules` allow-list that lets `git` reach your host).
--
-- What it costs: every round trip (one tool call) sends the whole
-- conversation, so a long job is many calls; the system prompt and tools
-- are marked for prompt caching.  The totals are printed when a goal ends.
--
-- The code has the turtle, turtlelib, peripherals, the plain Lua bits,
-- `require` for CraftOS's cc.* modules (cc.strings, cc.pretty, ...) and
-- the files: fs, io, loadfile and dofile read anything but the API key,
-- and write only under /claude/ (so it can't rewrite the programs or the
-- startup).  No http or shell.
--
-- Position: it picks up turtlelib's saved position (.turtlepos) if there
-- is one, so `home` still works afterwards; otherwise here is (0,0,0)
-- facing +z.
--
-- Claude and Anthropic are trademarks of Anthropic.  This program calls
-- the Claude API with your own API key, under Anthropic's terms; it isn't
-- made or endorsed by Anthropic.

package.path = (ccnix and ccnix.lib or "") .. package.path    -- (ccnix's turtlelib, the updates' first)
local T = require("turtlelib")
-- the pager is in lib/, beside turtle/; without it the output just scrolls
if shell and shell.getRunningProgram then
    package.path = (ccnix and ccnix.lib or "/" .. fs.getDir(fs.getDir(shell.getRunningProgram())) .. "/lib/?.lua;") .. package.path
end
local okPager, pager = pcall(require, "pager")
if not (okPager and type(pager) == "table" and pager.page) then pager = nil end

-- Colour on an advanced computer or turtle, plain text on the others.
local COLOUR = term ~= nil and term.isColour ~= nil and term.isColour() and colours ~= nil
local function say(colour, ...)
    if COLOUR and colour then term.setTextColour(colours[colour]) end
    print(...)
    if COLOUR and colour then term.setTextColour(colours.white) end
end

local API_URL = "https://api.anthropic.com/v1/messages"
local API_VERSION = "2026-10-21"
local KEY_FILE = T.dataPath("claude.key")
local LOG_FILE = T.dataPath("claude.log")
local MAX_TOKENS = 32000        -- a reply is a short note and some code, but the
                                -- thinking before it counts too
local MAX_OUTPUT = 6000         -- characters of a tool's output sent back
local RETRIES = 4               -- on rate limits, overload and outages
local HTTP_TIMEOUT = 60         -- seconds with nothing coming in, at most 60 in CC; the
                                -- reply is streamed, so a long one keeps coming

--------------------------------------------------------------------------
-- Arguments
--------------------------------------------------------------------------
local args = { ... }
local MODEL, EFFORT, MAX_STEPS = "claude-opus-5-5", "medium", 60
local CONFIRM = T.popFlag(args, "--confirm")
MODEL = T.popValue(args, "--model") or MODEL
EFFORT = T.popValue(args, "--effort") or EFFORT
local stepsArg = T.popValue(args, "--steps")
MAX_STEPS = stepsArg and tonumber(stepsArg) or MAX_STEPS
local goal = table.concat(args, " ")

--------------------------------------------------------------------------
-- The key
--------------------------------------------------------------------------
local function readKey()
    if not fs.exists(KEY_FILE) then return nil end
    local f = fs.open(KEY_FILE, "r")
    local key = T.trim(f.readLine() or "")
    f.close()
    return key ~= "" and key or nil
end

local KEY = readKey()
if not KEY then
    say("red", "No API key: put one in " .. KEY_FILE .. " (edit " .. KEY_FILE .. ", paste it, save).")
    return
end
if not http then say("red", "HTTP is disabled on this server."); return end

--------------------------------------------------------------------------
-- What the model is told
--------------------------------------------------------------------------
local SYSTEM = [[
You are driving a ComputerCraft (CC:Tweaked) turtle in Minecraft, from inside the turtle. You act by calling the `lua` tool with Lua code (Lua 5.2 as CC runs it), which runs on the turtle; what it prints and returns comes back to you. Nothing happens unless you call a tool.

Coordinates are the turtle's own, dead-reckoned by the turtlelib library `T`: it started at (0,0,0) facing +z (heading 0); +x is to its right (heading 1), -z is heading 2, -x is heading 3; y is up. T.pos = {x, y, z} and T.dir are where it thinks it is, and stay right only if you move and turn through T: T.forward(), T.back(), T.up(), T.down(), T.turnLeft(), T.turnRight(), T.face(d), T.moveDir(d) (d a heading, "up" or "down"), T.toY(y), T.goTo(x, z) (routes to a column at the current height, learning obstacles). Never call turtle.forward/back/up/down/turnLeft/turnRight yourself: T.pos would be wrong from then on. T.forward() and the others only dig blocks listed in T.diggable (empty to start): to dig, call turtle.dig(), turtle.digUp() or turtle.digDown() first, or set T.diggable["minecraft:stone"] = true for what it may dig on the way. Moves cost one fuel each; T.refuelTo(n) burns fuel items from the inventory.

Also useful: T.look(d) / T.digDir(d) / T.placeDir(d) (inspect, dig, place in a direction, facing it first); turtle.inspect(), turtle.inspectUp(), turtle.inspectDown() -> ok, {name=..., state=...}; turtle.detect/detectUp/detectDown(); turtle.select(slot), turtle.getItemDetail(slot), turtle.getItemCount(slot); T.selectItem(name), T.countItem(name), T.freeSlots(), T.tidyInventory(); turtle.place/placeUp/placeDown(), turtle.drop/dropUp/dropDown(n), turtle.suck/suckUp/suckDown(n); turtle.getFuelLevel(); peripheral.wrap("left"/"right"/"front"/"top"/"bottom"); sleep(seconds); T.posString(). Files: read any with fs or io; write only under /claude/ (fs.makeDir("/claude") first), for notes, maps or programs you keep between goals.

Each tool call is a slow network round trip, so do several steps per call: write loops, check results in the code, and return or print what you learn, briefly. Variables and functions you define persist between calls. Call `status` to see where the turtle is, what's around it and what it carries. Never dig or break chests, barrels, hoppers or computers, and don't break blocks you weren't asked to. If the task is unclear or risky, call ask_user. When done (or stuck), stop and say what you did and where the turtle is; say plainly if something failed.]]

local TOOLS = {
    {
        name = "lua",
        description = "Run Lua on the turtle. The code runs as a chunk with turtle, T (turtlelib), peripheral, os, textutils, math, string, table, sleep, fs and io in scope (fs, io, loadfile and dofile read any file but the API key and write only under /claude/), and require for the CraftOS modules cc.strings, cc.pretty, cc.expect, cc.base64, cc.completion, cc.shell.completion, cc.image.nft, cc.audio.dfpwm and cc.require; print output and return values come back to you (tables are serialised). Errors come back as an error result. Definitions persist between calls.",
        input_schema = {
            type = "object",
            properties = { code = { type = "string", description = "The Lua code to run." } },
            required = { "code" },
        },
    },
    {
        name = "status",
        description = "Where the turtle is (position, heading), its fuel, what's in front, above and below it, and what it carries.",
        input_schema = { type = "object", properties = {} },
    },
    {
        name = "ask_user",
        description = "Ask the person at the turtle a question and wait for the answer.",
        input_schema = {
            type = "object",
            properties = { question = { type = "string" } },
            required = { "question" },
        },
    },
}

--------------------------------------------------------------------------
-- The screen: what's shown is kept, to read back in the pager
--------------------------------------------------------------------------
local SCROLLBACK = 3000         -- lines kept
local shown = {}                -- the lines shown this session
local seen = 0                  -- how many of them were out at the last prompt
local screenPrint = print

-- The blit digit of a colour, as term.blit takes them ("0" white); with
-- no pager to show colours, every line is plain.
local function blit(colour) return pager and pager.blitOf(colour) or "0" end

-- Keep `text`'s lines; `fg`, on a colour screen, is each character's
-- colour (blit digits), and a line that isn't all white keeps it, for the
-- pager to show in colour.
local function keep(text, fg)
    local pos = 1
    while pos <= #text + 1 do            -- a line a time, the one after the last newline too
        local nl = text:find("\n", pos, true) or #text + 1
        local l = text:sub(pos, nl - 1)
        local lfg = fg and fg:sub(pos, nl - 1)
        if lfg and lfg ~= string.rep("0", #lfg) then shown[#shown + 1] = { l, lfg } else shown[#shown + 1] = l end
        pos = nl + 1
    end
    if #shown > SCROLLBACK + 500 then
        local cut, t = #shown - SCROLLBACK, {}
        for i = cut + 1, #shown do t[#t + 1] = shown[i] end
        shown, seen = t, math.max(0, seen - cut)
    end
end

-- everything printed goes through here: claude's notes, the code, what
-- the code and turtlelib print, each line kept in the colour it's printed in
print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    local text = table.concat(parts, " ")
    keep(text, COLOUR and string.rep(blit(term.getTextColour()), #text) or nil)
    return screenPrint(...)
end

-- Lua code, highlighted as `edit` does it on a colour screen: keywords
-- yellow, comments green, strings red.
local KEYWORDS = {}
local KEYWORD_LIST = "and break do else elseif end false for function goto if in local nil not or "
    .. "repeat return then true until while"
for _, w in ipairs(T.words(KEYWORD_LIST)) do KEYWORDS[w] = true end

local function isNameStart(c) return (c >= "a" and c <= "z") or (c >= "A" and c <= "Z") or c == "_" end
local function isNameChar(c) return isNameStart(c) or (c >= "0" and c <= "9") end

-- `code` as runs of { colour, text }.
local function luaRuns(code)
    local runs, i, n = {}, 1, #code
    local function add(colour, s)
        local last = runs[#runs]
        if last and last[1] == colour then last[2] = last[2] .. s else runs[#runs + 1] = { colour, s } end
    end
    -- a long bracket's opening at j, [[ or [=[ ...: its ='s ("" for [[), or nil
    local function longOpenAt(j)
        if code:sub(j, j) ~= "[" then return nil end
        local k = j + 1
        while code:sub(k, k) == "=" do k = k + 1 end
        if code:sub(k, k) ~= "[" then return nil end
        return code:sub(j + 1, k - 1)
    end
    -- from j on, while test holds for the characters: where that stops
    local function runEnd(j, test)
        while j <= n and test(code:sub(j, j)) do j = j + 1 end
        return j
    end
    -- what ends a run of plain text: a name, a string, a comment or a long bracket's start
    local function isPlain(ch) return not (isNameChar(ch) or ch == '"' or ch == "'" or ch == "-" or ch == "[") end
    while i <= n do
        local c = code:sub(i, i)
        local long = code:sub(i, i + 1) == "--" and longOpenAt(i + 2) or nil
        local longStr = longOpenAt(i)
        if long or longStr then          -- a long comment or string, to its ]]
            local eq = long or longStr
            local close = "]" .. eq .. "]"
            local _, e = code:find(close, i + #eq + 2 + (long and 2 or 0), true)
            e = e or n
            add(long and "green" or "red", code:sub(i, e))
            i = e + 1
        elseif code:sub(i, i + 1) == "--" then
            local e = (code:find("\n", i, true) or n + 1) - 1
            add("green", code:sub(i, e))
            i = e + 1
        elseif c == '"' or c == "'" then
            local j = i + 1
            while j <= n do
                local d = code:sub(j, j)
                if d == "\\" then j = j + 2
                elseif d == c or d == "\n" then break
                else j = j + 1 end
            end
            j = math.min(j, n)
            add("red", code:sub(i, j))
            i = j + 1
        elseif isNameStart(c) then
            local word = code:sub(i, runEnd(i, isNameChar) - 1)
            add(KEYWORDS[word] and "yellow" or "white", word)
            i = i + #word
        else
            local e = runEnd(i, isPlain)
            local s = e > i and code:sub(i, e - 1) or c       -- (a lone - or [ is plain too)
            add("white", s)
            i = i + #s
        end
    end
    return runs
end

-- Show the code: highlighted on a colour screen, kept for the pager.
local function showCode(code)
    if not COLOUR then return print(code) end
    local fg = {}
    for _, r in ipairs(luaRuns(code)) do
        term.setTextColour(colours[r[1]])
        write(r[2])
        fg[#fg + 1] = string.rep(blit(colours[r[1]]), #r[2])
    end
    keep(code, table.concat(fg))
    term.setTextColour(colours.white)
    write("\n")
end

-- If more came out since the last prompt than fits above it, show it in
-- the pager from its first line.  After the pager, the screen shows the
-- end of the session again, above the prompt.
local function view(opts)
    opts.wrap, opts.always = true, true
    pager.page(shown, opts)
    local w, h = term.getSize()
    local tail = {}
    for i = math.max(1, #shown - h + 2), #shown do tail[#tail + 1] = shown[i] end
    local rows = pager.wrap(tail, w)
    for r = 1, h do
        term.setCursorPos(1, r)
        term.clearLine()
        local l = r < h and rows[#rows - (h - 1) + r]
        if l then pager.drawLine(l, 1, w) end
    end
    term.setCursorPos(1, h)
end

local function catchUp()
    if not (pager and term) then return end
    local w, h = term.getSize()
    local new = {}
    for i = seen + 1, #shown do new[#new + 1] = shown[i] end
    if #pager.wrap(new, w) > h - 1 then view({ from = seen + 1 }) end
end

-- read(), except that the wheel up or PgUp before anything is typed
-- comes back as `back`.
local function readLine()
    if not (pager and term and parallel) then return read() or "" end
    local line, back, typed
    parallel.waitForAny(
        function() line = read() end,
        function()
            while true do
                local ev, a = os.pullEvent()
                if ev == "char" or ev == "paste" then typed = true
                elseif not typed and ev == "mouse_scroll" and a < 0 then
                    back = 3                -- as far as a notch goes in the pager
                    return
                elseif not typed and ev == "key" and a == keys.pageUp then
                    back = select(2, term.getSize()) - 2      -- a page
                    return
                end
            end
        end)
    return line or "", back
end

-- Ask for a line after `label`, the pager first if need be.
local function ask(label)
    catchUp()
    while true do
        if COLOUR then term.setTextColour(colours.yellow) end
        write(label)
        if COLOUR then term.setTextColour(colours.white) end
        local line, back = readLine()
        if not back then
            keep(label .. line, COLOUR and (string.rep(blit(colours.yellow), #label) .. string.rep("0", #line)) or nil)
            seen = #shown
            return line
        end
        term.setCursorBlink(false)
        view({ from = math.huge, up = back })
    end
end

--------------------------------------------------------------------------
-- The tools
--------------------------------------------------------------------------
local function log(line)
    local f = fs.open(LOG_FILE, "a")
    if f then f.writeLine(line); f.close() end
end

local function clip(s)
    if #s <= MAX_OUTPUT then return s end
    local half = math.floor(MAX_OUTPUT / 2)
    return s:sub(1, half) .. "\n... (" .. (#s - MAX_OUTPUT) .. " characters left out) ...\n" .. s:sub(-half)
end

local function show(v)
    if type(v) == "table" then
        local ok, s = pcall(textutils.serialise, v, { compact = true, allow_repetitions = true })
        return ok and s or tostring(v)
    end
    return tostring(v)
end

-- The files: the code may read anything but the API key, and write only
-- under /claude/, so a slip can't rewrite the programs or the startup.
local WRITE_DIR = "claude"
local NO_WRITE = "writable only under /" .. WRITE_DIR .. "/"
local NO_READ = "the API key isn't readable"
local function norm(path) return fs.combine(tostring(path), "") end
local KEY_PATH = norm(KEY_FILE):lower()
local function isKey(path) return norm(path):lower() == KEY_PATH end
-- `path` is the key or a folder it's in (copying that would copy the key)
local function holdsKey(path)
    local p = norm(path):lower()
    return p == KEY_PATH or p == "" or KEY_PATH:sub(1, #p + 1) == p .. "/"
end
local function writable(path)
    local p = norm(path)
    return p == WRITE_DIR or p:sub(1, #WRITE_DIR + 1) == WRITE_DIR .. "/"
end
local function denied(path, why) error(tostring(path) .. ": " .. why, 3) end
local function isWrite(mode) return mode ~= nil and mode ~= "r" and mode ~= "rb" end

local codeFs = {}
for k, v in pairs(fs) do codeFs[k] = v end
function codeFs.open(path, mode)
    if isKey(path) then return nil, tostring(path) .. ": " .. NO_READ end
    if isWrite(mode) and not writable(path) then return nil, tostring(path) .. ": " .. NO_WRITE end
    return fs.open(path, mode)
end
function codeFs.makeDir(path)
    if not writable(path) then denied(path, NO_WRITE) end
    return fs.makeDir(path)
end
function codeFs.delete(path)
    if not writable(path) then denied(path, NO_WRITE) end
    return fs.delete(path)
end
function codeFs.move(from, to)
    if not writable(from) then denied(from, NO_WRITE) end
    if not writable(to) then denied(to, NO_WRITE) end
    return fs.move(from, to)
end
function codeFs.copy(from, to)
    if holdsKey(from) then denied(from, isKey(from) and NO_READ or "has the API key in it, so it can't be copied") end
    if not writable(to) then denied(to, NO_WRITE) end
    return fs.copy(from, to)
end
function codeFs.isReadOnly(path) return not writable(path) or fs.isReadOnly(path) end

local codeIo = {
    open = function(path, mode)
        if isKey(path) then return nil, tostring(path) .. ": " .. NO_READ end
        if isWrite(mode) and not writable(path) then return nil, tostring(path) .. ": " .. NO_WRITE end
        return io.open(path, mode)
    end,
    lines = function(path, ...)
        if path ~= nil and isKey(path) then denied(path, NO_READ) end
        return io.lines(path, ...)
    end,
    type = io.type,
}

-- What the code may use: the turtle, the library, the world's peripherals,
-- the files as above and the plain Lua bits.  Not http or shell.
local API = {
    turtle = turtle, T = T, peripheral = peripheral, os = os, textutils = textutils,
    math = math, string = string, table = table, sleep = sleep,
    fs = codeFs, io = codeIo,
    pairs = pairs, ipairs = ipairs, next = next, select = select, type = type,
    tostring = tostring, tonumber = tonumber, unpack = unpack or table.unpack,
    pcall = pcall, error = error, assert = assert,
}
local env = setmetatable({}, { __index = API })
local function codeLoadfile(path, mode, e)
    if isKey(path) then return nil, tostring(path) .. ": " .. NO_READ end
    return loadfile(path, mode, e or env)
end
API.loadfile = codeLoadfile
API.dofile = function(path) return assert(codeLoadfile(path))() end

-- `require` in the code: CraftOS's cc.* modules, and only those.  They're
-- loaded afresh from /rom with a world of their own: the code's fs and io
-- (cc.image.nft's load and cc.require's loaders read files), and the
-- code's globals as cc.require's _G, not the real ones.
local CC_MODULES = {
    ["cc.audio.dfpwm"] = true, ["cc.base64"] = true, ["cc.completion"] = true, ["cc.expect"] = true,
    ["cc.image.nft"] = true, ["cc.pretty"] = true, ["cc.require"] = true,
    ["cc.shell.completion"] = true, ["cc.strings"] = true,
}
local modWorld = {
    fs = codeFs,
    io = setmetatable({ open = codeIo.open, lines = codeIo.lines }, { __index = io }),
    loadfile = codeLoadfile,
    dofile = API.dofile,
    debug = { getregistry = function() return nil end },
    _G = env,
    shell = shell,                  -- cc.shell.completion asks it for the directory
}
setmetatable(modWorld, { __index = _G })
local loadedMods = {}
local function ccRequire(name)
    if type(name) ~= "string" or not CC_MODULES[name] then
        local names = {}
        for n in pairs(CC_MODULES) do names[#names + 1] = n end
        table.sort(names)
        error("require: only CraftOS's modules here: " .. table.concat(names, ", "), 2)
    end
    if loadedMods[name] == nil then
        local file = {}                                  -- cc.image.nft -> cc/image/nft
        for j = 1, #name do
            local ch = name:sub(j, j)
            file[j] = ch == "." and "/" or ch
        end
        local path = "/rom/modules/main/" .. table.concat(file) .. ".lua"
        local chunk, err = loadfile(path, "t", modWorld)
        if not chunk then error("require: " .. tostring(err), 2) end
        local m = chunk(name, path)
        loadedMods[name] = m == nil and true or m
    end
    return loadedMods[name]
end
modWorld.require = ccRequire
API.require = ccRequire

local function runLua(code)
    local out = {}
    local realPrint = print
    local function capture(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
        local line = table.concat(parts, " ")
        realPrint(line)
        out[#out + 1] = line
    end
    env.print = capture
    print = capture                    -- what turtlelib says, too
    local chunk, err = load(code, "=claude", "t", env)
    local ok, results
    if not chunk then
        ok, err = false, "syntax: " .. tostring(err)
    else
        results = table.pack(pcall(chunk))
        ok = results[1]
        if not ok then err = results[2] end
    end
    print = realPrint
    if ok then
        for i = 2, results.n do out[#out + 1] = "-> " .. show(results[i]) end
    else
        if err == "Terminated" then error(err, 0) end
        out[#out + 1] = "error: " .. tostring(err)
    end
    local text = table.concat(out, "\n")
    if text == "" then text = "(no output)" end
    return clip(text), not ok
end

local function status()
    local function at(inspect)
        local ok, d = inspect()
        return ok and d.name or "air"
    end
    local items = {}
    for s = 1, 16 do
        local it = turtle.getItemDetail(s)
        if it then items[#items + 1] = string.format("%d: %d %s", s, it.count, it.name) end
    end
    return string.format("at %s facing %d (0=+z 1=+x 2=-z 3=-x), fuel %s\nfront: %s  above: %s  below: %s\nslots: %s\nselected slot %d",
        T.posString(), T.dir, tostring(turtle.getFuelLevel()),
        at(turtle.inspect), at(turtle.inspectUp), at(turtle.inspectDown),
        #items > 0 and table.concat(items, ", ") or "empty", turtle.getSelectedSlot()), false
end

local function askUser(question)
    say("yellow", "Claude asks: " .. tostring(question))
    return ask("> "), false
end

local function runTool(name, input)
    input = input or {}
    if name == "lua" then
        local code = tostring(input.code or "")
        say("lightBlue", "--- lua")
        showCode(code)
        log("lua:\n" .. code)
        if CONFIRM then
            local a = ask("Run it? [y/N] ")
            if a:lower():sub(1, 1) ~= "y" then
                say("orange", "--- not run")
                return "The user declined to run this code.", true
            end
        end
        say("lightBlue", "---")
        -- what the code prints, in grey, apart from what Claude says
        if COLOUR then term.setTextColour(colours.lightGrey) end
        local ok, out, isErr = pcall(runLua, code)
        if COLOUR then term.setTextColour(colours.white) end
        if not ok then error(out, 0) end        -- Terminated
        if isErr then
            -- the line from "error: " on, else all of it
            local from = out:find("error: ", 1, true)
            local nl = from and out:find("\n", from, true)
            say("red", from and out:sub(from, nl and nl - 1 or -1) or out)
        end
        log((isErr and "error:\n" or "result:\n") .. out)
        return out, isErr
    elseif name == "status" then
        return status()
    elseif name == "ask_user" then
        return askUser(input.question)
    end
    return "No such tool: " .. tostring(name), true
end

--------------------------------------------------------------------------
-- The API
--------------------------------------------------------------------------
local messages = {}
local usage = { input = 0, output = 0, cached = 0 }

local function body()
    return textutils.serialiseJSON({
        model = MODEL,
        max_tokens = MAX_TOKENS,
        system = { { type = "text", text = SYSTEM, cache_control = { type = "ephemeral" } } },
        tools = TOOLS,
        messages = messages,
        output_config = { effort = EFFORT },
        -- streamed, with the thinking summarised as it goes: CC's timeout
        -- is for 60 s with nothing coming in, so the reply has to keep
        -- coming (the thinking text is hidden by default, and a long think
        -- would be a long silence)
        stream = true,
        thinking = { type = "adaptive", display = "summarized" },
        -- a refusal by the safety classifiers is retried on a fallback
        -- model server-side (see the API docs: server-side fallback)
        fallbacks = "default",
    }, { allow_repetitions = true })
end

local HEADERS = {
    ["Content-Type"] = "application/json",
    ["x-api-key"] = KEY,
    ["anthropic-version"] = API_VERSION,
    ["anthropic-beta"] = "server-side-fallback-2026-07-01",
}

-- The events' data in a streamed reply: what follows each "data: ", up to
-- the end of its line.
local function eventData(text)
    local out, pos = {}, 1
    while true do
        local from = text:find("data: ", pos, true)
        if not from then return out end
        local start = from + #"data: "
        local nl = text:find("\n", start, true) or #text + 1
        local line = text:sub(start, nl - 1)
        local cr = line:find("\r", 1, true)          -- (a CR ends it too)
        if cr then line = line:sub(1, cr - 1) end
        out[#out + 1] = line
        pos = start + #line
    end
end

-- The message from a streamed reply's events, or nil and the error the
-- stream ended with ({ type = ..., message = ... }).
local function fromEvents(text)
    local msg, parts = nil, {}
    for _, data in ipairs(eventData(text)) do
        local e = textutils.unserialiseJSON(data)
        local t = e and e.type
        if t == "message_start" then
            msg = e.message
            msg.content = {}
        elseif t == "content_block_start" and msg then
            msg.content[e.index + 1] = e.content_block
            parts[e.index + 1] = {}
        elseif t == "content_block_delta" and msg and parts[e.index + 1] then
            local d, p = e.delta, parts[e.index + 1]
            local field = d.type == "text_delta" and "text" or d.type == "thinking_delta" and "thinking"
                or d.type == "signature_delta" and "signature" or d.type == "input_json_delta" and "input"
            local piece = d.text or d.thinking or d.signature or d.partial_json
            if field and piece then
                p[field] = p[field] or {}
                table.insert(p[field], piece)
            end
        elseif t == "content_block_stop" and msg and parts[e.index + 1] then
            local b = msg.content[e.index + 1]
            for field, pieces in pairs(parts[e.index + 1]) do
                local s = table.concat(pieces)
                if field == "input" then
                    b.input = textutils.unserialiseJSON(s) or {}
                else
                    b[field] = (b[field] or "") .. s
                end
            end
        elseif t == "message_delta" and msg then
            msg.stop_reason = e.delta and e.delta.stop_reason
            msg.stop_details = e.delta and e.delta.stop_details
            msg.usage = msg.usage or {}
            for k, v in pairs(e.usage or {}) do msg.usage[k] = v end
        elseif t == "error" then
            return nil, e.error or { type = "error", message = data }
        end
    end
    if not msg then return nil, { type = "unreadable", message = tostring(text):sub(1, 200) } end
    return msg
end

-- Send the conversation; the reply as a table, or nil and why.  Rate
-- limits, overloads and outages are retried with a growing wait, and so
-- is a stream cut off by an overload.
local function request()
    local wait = 2
    for attempt = 1, RETRIES + 1 do
        local h, err, failed = http.post({ url = API_URL, headers = HEADERS, body = body(), timeout = HTTP_TIMEOUT })
        local code, text
        if h then
            code, text = h.getResponseCode(), h.readAll()
            h.close()
        elseif failed then
            code, text = failed.getResponseCode(), failed.readAll()
            if failed.close then failed.close() end
        end
        local detail, again
        if code == 200 then
            local reply, e = fromEvents(text)
            if reply then return reply end
            -- an error partway: the ones a wait cures, as for their HTTP codes
            detail = tostring(e.type) .. ": " .. tostring(e.message)
            again = e.type == "overloaded_error" or e.type == "api_error" or e.type == "rate_limit_error"
        else
            detail = tostring(err or "")
            if text then
                local e = textutils.unserialiseJSON(text)
                detail = e and e.error and (e.error.type .. ": " .. tostring(e.error.message)) or text:sub(1, 200)
            end
            again = code == 429 or code == 500 or code == 502 or code == 503 or code == 529 or (not code)
        end
        if not again or attempt > RETRIES then
            return nil, string.format("API request failed%s: %s", code and code ~= 200 and (" (HTTP " .. code .. ")") or "", detail)
        end
        say("orange", string.format("API: %s; trying again in %ds.", detail, wait))
        sleep(wait)
        wait = wait * 2
    end
end

local function count(reply)
    local u = reply.usage or {}
    usage.input = usage.input + (u.input_tokens or 0)
    usage.output = usage.output + (u.output_tokens or 0)
    usage.cached = usage.cached + (u.cache_read_input_tokens or 0)
end

-- Error results for the tool calls in the last assistant turn, if it has
-- any: the API wants every tool_use answered in the very next turn, even
-- one cut off at max_tokens or never run.
local function unanswered(why)
    local out, last = {}, messages[#messages]
    if last and last.role == "assistant" and type(last.content) == "table" then
        for _, b in ipairs(last.content) do
            if b.type == "tool_use" then
                out[#out + 1] = { type = "tool_result", tool_use_id = b.id, content = why, is_error = true }
            end
        end
    end
    return out
end

-- Add `text` as the user's: after tool calls left unanswered, with their
-- results first; after a user turn the API never answered (tool results
-- whose request failed), onto that turn.
local function addUser(text, why)
    local last = messages[#messages]
    if last and last.role == "user" then
        if type(last.content) == "string" then last.content = { { type = "text", text = last.content } } end
        table.insert(last.content, { type = "text", text = text })
        return
    end
    local blocks = unanswered(why)
    if #blocks == 0 then
        messages[#messages + 1] = { role = "user", content = text }
    else
        blocks[#blocks + 1] = { type = "text", text = text }
        messages[#messages + 1] = { role = "user", content = blocks }
    end
end

-- Work at `goal` until the model stops: run its tool calls and send the
-- results back, call after call, up to MAX_STEPS of them.
local function converse(goal)
    addUser(goal, "Not run: the goal ended before this call was answered.")
    log("goal: " .. goal)
    local steps, overBudget, cutOff = 0, false, false
    while true do
        local reply, err = request()
        if not reply then
            say("red", err)
            -- a goal it never answered goes; tool results stay, for the
            -- next goal to go on from
            local last = messages[#messages]
            if last.role == "user" and last.content == goal then messages[#messages] = nil end
            return false
        end
        count(reply)
        messages[#messages + 1] = { role = "assistant", content = reply.content }
        for _, b in ipairs(reply.content) do
            if b.type == "text" and b.text ~= "" then print(b.text); log("claude: " .. b.text) end
            if b.type == "thinking" and (b.thinking or "") ~= "" then log("thinking: " .. b.thinking) end
        end
        if reply.stop_reason == "tool_use" then
            local results = {}
            for _, b in ipairs(reply.content) do
                if b.type == "tool_use" then
                    local out, isErr
                    if overBudget then
                        out, isErr = "The step budget is used up: stop, and say what you did.", true
                    else
                        steps = steps + 1
                        out, isErr = runTool(b.name, b.input)
                    end
                    results[#results + 1] = { type = "tool_result", tool_use_id = b.id, content = out, is_error = isErr or nil }
                end
            end
            if steps >= MAX_STEPS and not overBudget then
                overBudget = true
                results[#results + 1] = { type = "text",
                    text = string.format("That was tool call %d of the %d allowed for this goal: stop here and say what you did.", steps, MAX_STEPS) }
            end
            messages[#messages + 1] = { role = "user", content = results }
        elseif reply.stop_reason == "max_tokens" and not cutOff then
            cutOff = true
            say("orange", "(the reply was cut off; asking it to carry on)")
            addUser("Your reply was cut off; carry on, more briefly.",
                "Not run: your reply was cut off before this call was complete.")
        elseif reply.stop_reason == "refusal" then
            local d = reply.stop_details or {}
            say("red", "Claude declined (" .. tostring(d.category or "refusal") .. "): " .. tostring(d.explanation or ""))
            return false
        else
            return true
        end
    end
end

--------------------------------------------------------------------------
-- Main
--------------------------------------------------------------------------
local function main()
    local saved = T.loadPos()
    if saved then
        T.pos.x, T.pos.y, T.pos.z, T.dir, T.mode = saved.x, saved.y, saved.z, saved.dir, saved.mode or "flat"
    else
        T.startAtHome(true)
    end
    say("yellow", string.format("Claude at the controls (%s, effort %s). Turtle at %s facing %d, fuel %s.",
        MODEL, EFFORT, T.posString(), T.dir, tostring(turtle.getFuelLevel())))
    if goal == "" then
        goal = ask("Goal: ")
    end
    while goal ~= "" do
        local before = { input = usage.input, output = usage.output, cached = usage.cached }
        converse(goal)
        say("grey", string.format("[%d tokens in (%d from cache), %d out; %d in all]",
            usage.input - before.input, usage.cached - before.cached, usage.output - before.output,
            usage.input + usage.output))
        goal = ask("> ")
    end
end

local ok, err = pcall(T.run, main)
print = screenPrint
if not ok then error(err, 0) end
