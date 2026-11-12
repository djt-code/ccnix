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
--          [--steps N] [--cache 5m|1h] [--confirm]
--
--   claude dig a 3 by 3 tunnel 20 blocks ahead and come back
--   claude                      asks for the goal
--
--   --steps N    at most N tool calls per goal (default 60), then it's
--                told to stop and sum up
--   --cache 1h   keep the conversation cached for an hour with no call
--                reading it, not 5 minutes (for long pauses between
--                goals: writing it costs more, 2x the input price, not
--                1.25x; reading it is cheap either way)
--   --confirm    show each piece of code and ask before running it
--
-- When it stops, type the next thing to do (it keeps the conversation),
-- or press Enter on an empty line to quit.  Ctrl+T stops it (under T.run,
-- so the saved position stays right).
--
-- Colour (an advanced computer or turtle): the code it runs is highlighted
-- as vi does it (lib/syntax: keywords yellow, comments green, strings
-- red, numbers and nil/true/false magenta, library names cyan), what the
-- code prints is grey, prompts and questions yellow, retries orange,
-- errors red; Claude's own words are white.
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
-- conversation, so a long job is many calls; the conversation is cached
-- (the API's prompt caching), so each call reads what came before from
-- the cache, at a fraction of the price, and pays in full only for
-- what's new.  When a goal ends its tokens are printed: those read from
-- the cache, written to it and new, and what came out.
--
-- The code has the turtle, turtlelib, peripherals, the plain Lua bits,
-- CC's http, `require` for CraftOS's cc.* modules (cc.strings, cc.pretty,
-- ...) and ccnix's libraries for text, the network and the world (text,
-- scan, convert, path, glob, regex, tables, fileio, getopt, net, netdb,
-- httpc, mc), and the files: fs, io, loadfile and dofile read anything
-- but the API key, and write only under /claude/ (so it can't rewrite the
-- programs or the startup).  No shell.
--
-- The other tools:
--   status       where it is, fuel, what's around, what it carries, the
--                tools equipped, what's attached, a mine job, the network
--   run_program  runs one of ccnix's turtle programs (mine, farm, mow,
--                home), or ip and ping for the network, with arguments,
--                or reads its manual (help/)
--   ask_user     asks you, at the prompt
--   memory       its notes, kept between sessions in /claude/memories/
--                (the API's memory tool: view, create, str_replace,
--                insert, delete, rename, only under that folder)
--   web_search, web_fetch   run on Anthropic's side, not the turtle's
--                (each costs a little; at most a few a reply)
-- Old tool results are cleared from the conversation once it's long (the
-- API's context editing), the memory tool's kept; a reply paused partway
-- through its web searches is carried on.
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
local scan = require("scan")
local text = require("text")
-- the pager is in lib/, beside turtle/; without it the output just scrolls
if shell and shell.getRunningProgram then
    package.path = (ccnix and ccnix.lib or "/" .. fs.getDir(fs.getDir(shell.getRunningProgram())) .. "/lib/?.lua;") .. package.path
end
local okPager, pager = pcall(require, "pager")
if not (okPager and type(pager) == "table" and pager.page) then pager = nil end
local convert = require("convert")
local fileio = require("fileio")
local path = require("path")
local syntax = require("syntax")
local sysenv = require("sysenv")
local tables = require("tables")

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
local MEMORY_DIR = "claude/memories"   -- where the memory tool's /memories is kept
local WEB_USES = 5              -- web searches, and fetches, at most per reply
local PAUSES = 5                -- times a paused reply (pause_turn) is carried on
-- Old tool results cleared once the conversation is this long (tokens in),
-- the last KEEP_TOOL_USES kept, and only if it frees CLEAR_AT_LEAST.  A
-- clear changes the conversation from the first result cleared on, so the
-- cache is written again from there: rarer and bigger clears cost less
-- than many small ones.
local CLEAR_TRIGGER, KEEP_TOOL_USES, CLEAR_AT_LEAST = 100000, 6, 30000
-- How long the cache keeps the conversation with no request reading it:
-- the API has 5 minutes and an hour (writing for an hour costs 2x the
-- input price, for 5 minutes 1.25x; reading 0.05x on Opus 5.5)
local CACHE_TTLS = { ["5m"] = true, ["1h"] = true }
-- The programs run_program may run: ccnix's turtle programs, and ip (the
-- network's settings: it saves them itself) and ping to set up and check
-- the network
local PROGRAMS = { mine = "turtle/mine", farm = "turtle/farm", mow = "turtle/mow", home = "turtle/home",
                   ip = "bin/ip", ping = "bin/ping" }
-- Those that go on until stopped unless told otherwise: the option letters
-- that end them, and what's added when none of those is given (a ping
-- left to run would hold the session for ever)
local BOUNDED = { ping = { letters = { "c", "w" }, add = { "-c", "4" } } }

--------------------------------------------------------------------------
-- Arguments
--------------------------------------------------------------------------
-- (T.options: the goal's words are free, a "-5" or a "-x" in it too;
-- only these are options)
local USAGE = "Usage: claude [goal words...] [--model id] [--effort low|medium|high] [--steps N] [--cache 5m|1h] [--confirm]"
local opts, args = T.options({ ... }, { confirm = true, model = "=", effort = "=", steps = "=", cache = "=" })
if not opts then
    print("claude: " .. args)
    print(USAGE)
    return
end
if opts.cache and not CACHE_TTLS[opts.cache] then
    print("claude: --cache is 5m or 1h, not " .. opts.cache)
    print(USAGE)
    return
end
local CONFIRM = opts.confirm == true
local MODEL = opts.model or "claude-opus-5-5"
local EFFORT = opts.effort or "medium"
local MAX_STEPS = opts.steps and tonumber(opts.steps) or 60
-- (5 minutes is the API's own default, so it isn't named)
local CACHE = { type = "ephemeral", ttl = opts.cache ~= "5m" and opts.cache or nil }
local goal = table.concat(args, " ")

--------------------------------------------------------------------------
-- The key
--------------------------------------------------------------------------
local function readKey()
    local saved = fileio.read(KEY_FILE)
    if not saved then return nil end
    local key = text.trim((text.cut(saved, "\n")))     -- (its first line)
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
local SYSTEM = [==[
You are driving a ComputerCraft (CC:Tweaked) turtle in Minecraft, from inside the turtle. You act mostly by calling the `lua` tool with Lua code (Lua 5.2 as CC runs it), which runs on the turtle; what it prints and returns comes back to you. Nothing happens unless you call a tool.

Coordinates are the turtle's own, dead-reckoned by the turtlelib library `T`: it started at (0,0,0) facing +z (heading 0); +x is to its right (heading 1), -z is heading 2, -x is heading 3; y is up. T.pos = {x, y, z} and T.dir are where it thinks it is, and stay right only if you move and turn through T: T.forward(), T.back(), T.up(), T.down(), T.turnLeft(), T.turnRight(), T.face(d), T.moveDir(d) (d a heading, "up" or "down"), T.toY(y), T.goTo(x, z) (routes to a column at the current height, learning obstacles). Never call turtle.forward/back/up/down/turnLeft/turnRight yourself: T.pos would be wrong from then on. T.forward() and the others only dig blocks listed in T.diggable (empty to start): to dig, call turtle.dig(), turtle.digUp() or turtle.digDown() first, or set T.diggable["minecraft:stone"] = true for what it may dig on the way. Moves cost one fuel each; T.refuelTo(n) burns fuel items from the inventory.

Also useful: T.look(d) / T.digDir(d) / T.placeDir(d) (inspect, dig, place in a direction, facing it first); turtle.inspect(), turtle.inspectUp(), turtle.inspectDown() -> ok, {name=..., state=...}; turtle.detect/detectUp/detectDown(); turtle.select(slot), turtle.getItemDetail(slot), turtle.getItemCount(slot); T.selectItem(name), T.countItem(name), T.freeSlots(), T.tidyInventory(); turtle.place/placeUp/placeDown(), turtle.drop/dropUp/dropDown(n), turtle.suck/suckUp/suckDown(n); turtle.getFuelLevel(); peripheral.wrap("left"/"right"/"front"/"top"/"bottom"); sleep(seconds); T.posString(). Files: read any with fs or io; write only under /claude/ (fs.makeDir("/claude") first), for notes, maps or programs you keep between goals.

More of turtlelib: T.goHome() goes back to (0,0,0); T.inventoryFull(); T.dumpDown() empties the inventory into the container below (tools and the items in T.keep, torches to start, stay); T.containerCounts(side) -> { [name] = count } of a chest beside, above or below ("front", "top", "bottom"); T.restockFrom(side, name, target) takes items from it until the turtle has target of them; T.dropSide(side, n), T.suckSide(side, n), T.inspectSide(side); T.hasMineJob() and T.loadMineJob() -> { width, height, length, spacing, homes, state } tell whether the `mine` program has a job under way (leave it alone unless asked).

Libraries: `local text = require("text")` and so on give ccnix's own; use them rather than writing string code by hand or using Lua patterns.
- text: trim(s), trimStart, trimEnd, squeeze (runs of blanks as one space), words(s) -> list, split(s, sep [, keep]) -> trimmed pieces (keep: as they are, empty ones too), join(list, sep), cut(s, sep) / cutLast(s, sep) -> before, after, lines(s), startsWith, endsWith, stripPrefix, stripSuffix, find(s, part [, from]) / findLast (plain text), contains(s, part), containsAny(s, chars), count(s, part), replace(s, old, new) (plain text, never a pattern), padRight(s, w) / padLeft / center / truncate(s, w), columns(rows [, right]) -> aligned lines, wrap(s, w) -> lines, equalFold(a, b), capitalize, swapCase.
- scan: the character tests (isDigit, isAlpha, isSpace, isUpper, isPrintable, ...) and whole-string checks: isBlank, isInteger, isNumber, isNegative, isUnsigned, isHex, isName, isTime ("H:MM[:SS]"), isDateTime (ISO 8601); scan.new(s) is a scanner for small parsers (peek, advance, accept(c), readWhile(test), readName, readInteger, readFloat, readQuoted(q), readUntil(c), rest, atEnd).
- convert: toInteger(s [, base]) and toNumber(s) (strict: nil unless all of s is one), toBase(n, base), humanSize(bytes), duration(seconds) -> "1h 2m 5s", clock(ms), timeOfDay("14:05") -> seconds, fromDateTime(iso) -> epoch seconds, toHex/fromHex, toBase64/fromBase64, toUTF8/fromUTF8, escape/unescape (C's backslash escapes), urlEncode/urlDecode, html, shellQuote.
- path: basename(p [, suffix]), dirname, join(a, b, ...), normalize, resolve(dir, p), segments, extension, isAbsolute.
- glob: match(pattern, s) with * ? [a-z] [[:alpha:]] (a whole-string match; good for block names: glob.match("minecraft:*_ore", name)), compile(pattern) -> a test, hasWildcards, escape.
- regex: regex.compile(pattern, { ere = true, icase = true }) -> re, or nil and why; re:test(s [, whole]), re:find(s [, init]) -> start, stop, captures (POSIX regular expressions).
- tables: sortedKeys(t), copy(t). fileio: read(path), write(path, data) (under /claude/ only), readJSON(path). getopt: parse(args, "ab:") -> options, operands.
- mc: require("mc").new() -> the world through what's attached (Advanced Peripherals' chat box, player detector, environment detector): time(), weather(), players(), say(text, from) into the game's chat, tell(player, text, from); a function whose peripheral isn't there returns nil and why.
- httpc, net, netdb: ccnix's own network stack over modems (IPv4, UDP, TCP, DNS), when it's up (`status` says): httpc.get(url) / httpc.post(url, body, headers) / httpc.request({ url, method, body, headers, follow, timeout }) -> { status, headers, body } or nil and why (http:// only, no TLS); net.connect(host, port) -> a TCP connection (conn:send(s), conn:read(timeout), conn:close()); net.udp(); netdb.getaddrinfo(name).

Networking: prefer CC's own `http` (http.get(url [, headers]) -> a handle: h.readAll(), h.getResponseCode(), h.close(); or nil, why and the error response; http.post(url, body, headers); http.request for more): it is real HTTP and HTTPS from the server to the internet, as far as the server's allow-list lets it. Use ccnix's stack (httpc, net) for what only it reaches: addresses on the CC network (10.x.x.x and names there), raw TCP or UDP, or when http is disabled or refuses the host. To set the network up or change it (an interface's address, routes, DNS, bringing it up, starting it at boot), run_program ip, after reading its manual; ping checks the result. The code itself can't change settings. Web pages for research are better fetched with web_fetch (below), which reads them for you.

Programs: run_program runs ccnix's own turtle programs, tested and careful about fuel, chests and getting home: mine (tunnels and branch mines), farm (crops), mow (grass and flowers) and home (back to a job's start); and ip and ping, for the network. Prefer one of them to writing your own loops when the job is theirs. Read its manual first (run_program with help = true); it runs until it finishes (or the person stops it) and its output comes back. They keep the same saved position as T, so T.pos is right afterwards; `--here` makes where the turtle stands their (0,0,0), and so yours.

Memory: the memory tool keeps notes between sessions (where the base, chests and fuel are, what's been mined, what the person likes, jobs half done). Look at it before you start; write down what you'd want next time, briefly, and keep it tidy. web_search and web_fetch look things up on the internet (recipes, how a mod's block works); they cost a little each, so use them when you need to know, not by habit.

Each tool call is a slow network round trip, so do several steps per call: write loops, check results in the code, and return or print what you learn, briefly. Variables and functions you define persist between calls. Call `status` to see where the turtle is, what's around it, what it carries and has attached, and whether the network is up. Never dig or break chests, barrels, hoppers or computers, and don't break blocks you weren't asked to. If the task is unclear or risky, call ask_user. When done (or stuck), stop and say what you did and where the turtle is; say plainly if something failed.]==]

local TOOLS = {
    {
        name = "lua",
        description = "Run Lua on the turtle. The code runs as a chunk with turtle, T (turtlelib), peripheral, http, os, textutils, math, string, table, sleep, fs and io in scope (fs, io, loadfile and dofile read any file but the API key and write only under /claude/), and require for ccnix's libraries text, scan, convert, path, glob, regex, tables, fileio, getopt, net, netdb, httpc and mc, and the CraftOS modules cc.strings, cc.pretty, cc.expect, cc.base64, cc.completion, cc.shell.completion, cc.image.nft, cc.audio.dfpwm and cc.require; print output and return values come back to you (tables are serialised). Errors come back as an error result. Definitions persist between calls.",
        input_schema = {
            type = "object",
            properties = { code = { type = "string", description = "The Lua code to run." } },
            required = { "code" },
        },
    },
    {
        name = "status",
        description = "Where the turtle is (position, heading), its fuel, what's in front, above and below it, what it carries, the tools it has equipped, the peripherals attached, the computer's label, whether `mine` has a job under way, and whether http and ccnix's network are up (its addresses).",
        input_schema = { type = "object", properties = {} },
    },
    {
        name = "run_program",
        description = "Run one of ccnix's turtle programs (mine, farm, mow or home) or network tools (ip, ping: `ip` with no arguments shows the network, `ip help` its commands; ping gets -c 4 unless you give -c or -w), with its arguments as you'd type them (\"3 3 32 --spacing 4\"), and wait until it ends; what it prints comes back, with where the turtle is afterwards. With help = true, its manual comes back instead and nothing runs.",
        input_schema = {
            type = "object",
            properties = {
                program = { type = "string", enum = tables.sortedKeys(PROGRAMS) },
                args = { type = "string", description = "The arguments, as on a command line." },
                help = { type = "boolean", description = "Read the program's manual instead of running it." },
            },
            required = { "program" },
        },
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
    { type = "memory_20250818", name = "memory" },
    { type = "web_search_20260209", name = "web_search", max_uses = WEB_USES },
    { type = "web_fetch_20260209", name = "web_fetch", max_uses = WEB_USES },
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

-- Keep `said`'s lines; `fg`, on a colour screen, is each character's
-- colour (blit digits), and a line that isn't all white keeps it, for the
-- pager to show in colour.
local function keep(said, fg)
    local pos = 1                        -- (where the line starts in said, and in fg)
    for _, l in ipairs(text.split(said, "\n", true)) do     -- the one after the last newline too
        local lfg = fg and fg:sub(pos, pos + #l - 1)
        if lfg and lfg ~= string.rep("0", #lfg) then shown[#shown + 1] = { l, lfg } else shown[#shown + 1] = l end
        pos = pos + #l + 1
    end
    if #shown > SCROLLBACK + 500 then
        local cut, t = #shown - SCROLLBACK, {}
        for i = cut + 1, #shown do t[#t + 1] = shown[i] end
        shown, seen = t, math.max(0, seen - cut)
    end
end

-- everything printed goes through here: claude's notes, the code, what
-- the code and turtlelib print, each line kept in the colour it's printed in
-- print's arguments as the one line it prints
local function joined(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    return table.concat(parts, " ")
end

print = function(...)
    local line = joined(...)
    keep(line, COLOUR and string.rep(blit(term.getTextColour()), #line) or nil)
    return screenPrint(...)
end
local keepPrint = print                -- (the run programs' print goes here too)

-- The colour of a blit digit ("e" -> colours.red)
local function colourOf(digit) return math.floor(2 ^ convert.toInteger(digit, 16)) end

-- Show the code: highlighted on a colour screen as lib/syntax colours
-- Lua (vi's colours), kept for the pager.
local function showCode(code)
    code = convert.fromUTF8(code)
    if not COLOUR then return print(code) end
    local fg, state = {}, nil
    for i, line in ipairs(text.split(code, "\n", true)) do
        if i > 1 then write("\n") end
        local digits
        digits, state = syntax.line("lua", line, state)
        -- each run of one colour at a time, so write wraps it as it goes
        local sc = scan.new(digits)
        while not sc:atEnd() do
            local from, digit = sc:pos(), sc:peek()
            sc:readWhile(scan.oneOf(digit))
            term.setTextColour(colourOf(digit))
            write(line:sub(from, sc:pos() - 1))
        end
        fg[#fg + 1] = digits
    end
    keep(code, table.concat(fg, "0"))      -- (a digit for each newline too)
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
-- T at the position turtlelib saved (claude's, or a program's), if any;
-- true if there was one
local function takeSavedPos()
    local saved = T.loadPos()
    if not saved then return false end
    T.pos.x, T.pos.y, T.pos.z, T.dir, T.mode = saved.x, saved.y, saved.z, saved.dir, saved.mode or "flat"
    return true
end

-- lib/net, for showing the running stack's addresses (nil without it)
local okNet, net = pcall(require, "net")
if not (okNet and type(net) == "table") then net = nil end

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
    return p == KEY_PATH or p == "" or text.startsWith(KEY_PATH, p .. "/")
end
local function writable(path)
    local p = norm(path)
    return p == WRITE_DIR or text.startsWith(p, WRITE_DIR .. "/")
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
-- CC's http, the files as above and the plain Lua bits.  Not the shell.
local API = {
    turtle = turtle, T = T, peripheral = peripheral, http = http, os = os, textutils = textutils,
    math = math, string = string, table = table, sleep = sleep,
    fs = codeFs, io = codeIo,
    pairs = pairs, ipairs = ipairs, next = next, select = select, type = type,
    tostring = tostring, tonumber = tonumber, unpack = unpack or table.unpack,
    pcall = pcall, error = error, assert = assert,
}
-- The code's globals: API's, and the running network stack as it is now
-- (lib/net keeps it in _G.ccnet, and the code's libraries see env as _G)
local env = setmetatable({}, { __index = function(_, k)
    if k == "ccnet" then return rawget(_G, "ccnet") end
    return API[k]
end })
local function codeLoadfile(path, mode, e)
    if isKey(path) then return nil, tostring(path) .. ": " .. NO_READ end
    return loadfile(path, mode, e or env)
end
API.loadfile = codeLoadfile
API.dofile = function(path) return assert(codeLoadfile(path))() end

-- `require` in the code: CraftOS's cc.* modules, and ccnix's libraries
-- for text, paths, conversions, the network and the world (lib/), and
-- only those.
-- They're loaded afresh with a world of their own: the code's fs and io
-- (cc.image.nft's load, cc.require's loaders and lib/fileio read files),
-- and the code's globals as cc.require's _G, not the real ones.
local CC_MODULES = {
    ["cc.audio.dfpwm"] = true, ["cc.base64"] = true, ["cc.completion"] = true, ["cc.expect"] = true,
    ["cc.image.nft"] = true, ["cc.pretty"] = true, ["cc.require"] = true,
    ["cc.shell.completion"] = true, ["cc.strings"] = true,
}
local CCNIX_MODULES = {
    scan = true, text = true, convert = true, getopt = true, glob = true, path = true,
    regex = true, tables = true, fileio = true, mc = true, net = true, netdb = true, httpc = true,
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

-- A ccnix library's chunk, from where this program's own require finds
-- it (package.path's places in order, ccnix's lib/ first)
local function loadLib(name)
    for _, place in ipairs(text.split(package.path, ";")) do
        local chunk = loadfile(text.replace(place, "?", name), "t", modWorld)
        if chunk then return chunk end
    end
    return nil, name .. " isn't on this computer"
end

-- What isn't a module here because the code has it already, as a global
-- (turtlelib is T, the very one moving the turtle: a second copy would
-- keep a position of its own; fs and io are the guarded ones)
local AS_GLOBAL = { turtlelib = "T", fs = "fs", io = "io", turtle = "turtle", http = "http", os = "os",
                    peripheral = "peripheral", textutils = "textutils" }

local function ccRequire(name)
    if AS_GLOBAL[name] then
        error("require: " .. name .. " isn't a module here: the code has it already, as the global " .. AS_GLOBAL[name], 2)
    end
    if type(name) ~= "string" or not (CC_MODULES[name] or CCNIX_MODULES[name]) then
        error("require: only these here: " .. table.concat(tables.sortedKeys(CC_MODULES), ", ")
            .. ", and ccnix's " .. table.concat(tables.sortedKeys(CCNIX_MODULES), ", "), 2)
    end
    if loadedMods[name] == nil then
        local romFile = "/rom/modules/main/" .. text.replace(name, ".", "/") .. ".lua"   -- cc.image.nft -> cc/image/nft
        local chunk, err
        if CCNIX_MODULES[name] then chunk, err = loadLib(name) else chunk, err = loadfile(romFile, "t", modWorld) end
        if not chunk then error("require: " .. tostring(err), 2) end
        local m = chunk(name, romFile)
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
        local line = joined(...)
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
    local all = table.concat(out, "\n")
    if all == "" then all = "(no output)" end
    return clip(all), not ok
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
    local lines = {
        string.format("at %s facing %d (0=+z 1=+x 2=-z 3=-x), fuel %s", T.posString(), T.dir, tostring(turtle.getFuelLevel())),
        string.format("front: %s  above: %s  below: %s", at(turtle.inspect), at(turtle.inspectUp), at(turtle.inspectDown)),
        "slots: " .. (#items > 0 and table.concat(items, ", ") or "empty"),
        "selected slot " .. turtle.getSelectedSlot(),
    }
    -- (only where CC can tell without swapping tools in and out)
    if turtle.getEquippedLeft then
        local l, r = turtle.getEquippedLeft(), turtle.getEquippedRight()
        lines[#lines + 1] = string.format("equipped: left %s, right %s", l and l.name or "nothing", r and r.name or "nothing")
    end
    local attached = {}
    for _, side in ipairs(peripheral.getNames()) do
        attached[#attached + 1] = side .. " " .. tostring(peripheral.getType(side))
    end
    lines[#lines + 1] = "attached: " .. (#attached > 0 and table.concat(attached, ", ") or "nothing")
    lines[#lines + 1] = string.format("computer %d, label %s", os.getComputerID(), os.getComputerLabel() or "none")
    local job = T.loadMineJob()
    if job then
        lines[#lines + 1] = string.format("mine job under way: %d wide, %d high, %s long, spacing %d, %s",
            job.width, job.height, job.length and tostring(job.length) or "no end", job.spacing, job.state)
    end
    local addrs = {}
    local S = rawget(_G, "ccnet")
    for _, name in ipairs(S and tables.sortedKeys(S.ifaces) or {}) do
        local ifc = S.ifaces[name]
        local ip = type(ifc.ip) == "number" and net and net.ipString(ifc.ip) or tostring(ifc.ip)
        addrs[#addrs + 1] = string.format("%s %s/%s", name, ip, tostring(ifc.len))
    end
    lines[#lines + 1] = "http: " .. (http and "on" or "off") .. "; ccnix network: "
        .. (S and (#addrs > 0 and table.concat(addrs, ", ") or "up, no addresses") or "down")
    return table.concat(lines, "\n"), false
end

local function askUser(question)
    say("yellow", "Claude asks: " .. convert.fromUTF8(tostring(question)))
    return ask("> "), false
end

--------------------------------------------------------------------------
-- The memory tool: the API's /memories, kept in MEMORY_DIR.  Its commands
-- and replies are the ones the API's documentation gives.
--------------------------------------------------------------------------
local MEMORY_ROOT = "/memories"

-- The file or folder on disk for a /memories path, and the path tidied;
-- nil for anything outside /memories (.. and all)
local function memoryFile(p)
    if type(p) ~= "string" then return nil end
    local tidy = path.normalize(p)
    if tidy == MEMORY_ROOT then return MEMORY_DIR, tidy end
    local rest = text.stripPrefix(tidy, MEMORY_ROOT .. "/")
    if not rest then return nil end
    return MEMORY_DIR .. "/" .. rest, tidy
end

local function sizeOf(file)
    if not fs.isDir(file) then return fs.getSize(file) end
    local n = 0
    for _, name in ipairs(fs.list(file)) do n = n + sizeOf(file .. "/" .. name) end
    return n
end

-- The lines "size<TAB>path" of a folder and what's in it, two levels
-- deep, hidden things (and node_modules) left out
local function listing(file, shownAs, depth, out)
    out[#out + 1] = convert.humanSize(sizeOf(file)) .. "\t" .. shownAs
    if not fs.isDir(file) or depth == 2 then return out end
    local names = fs.list(file)
    table.sort(names)
    for _, name in ipairs(names) do
        if not text.startsWith(name, ".") and name ~= "node_modules" then
            listing(file .. "/" .. name, shownAs .. "/" .. name, depth + 1, out)
        end
    end
    return out
end

-- A file's lines, without the newline at its end
local function linesOf(content)
    return text.split(text.stripSuffix(content, "\n") or content, "\n", true)
end

local MEMORY = {}

function MEMORY.view(file, shownAs, input)
    if not fs.exists(file) then
        if file ~= MEMORY_DIR then return "The path " .. shownAs .. " does not exist. Please provide a valid path.", true end
        fs.makeDir(file)                -- the first look, at nothing yet
    end
    if fs.isDir(file) then
        return "Here're the files and directories up to 2 levels deep in " .. shownAs
            .. ", excluding hidden items and node_modules:\n" .. table.concat(listing(file, shownAs, 0, {}), "\n")
    end
    local lines = linesOf(fileio.read(file) or "")
    local from, to = 1, #lines
    local range = input.view_range
    if type(range) == "table" and type(range[1]) == "number" and type(range[2]) == "number" then
        from, to = math.max(1, range[1]), range[2] == -1 and #lines or math.min(#lines, range[2])
    end
    local out = { "Here's the content of " .. shownAs .. " with line numbers:" }
    for i = from, to do out[#out + 1] = string.format("%6d\t%s", i, lines[i]) end
    return table.concat(out, "\n")
end

function MEMORY.create(file, shownAs, input)
    if type(input.file_text) ~= "string" then return "Error: create needs file_text", true end
    if fs.isDir(file) then return "Error: " .. shownAs .. " is a directory", true end
    fs.makeDir(fs.getDir(file))
    local ok, why = fileio.write(file, input.file_text)
    if not ok then return "Error: " .. tostring(why), true end
    return "File created successfully at: " .. shownAs
end

function MEMORY.str_replace(file, shownAs, input)
    if not fs.exists(file) or fs.isDir(file) then
        return "Error: The path " .. shownAs .. " does not exist. Please provide a valid path.", true
    end
    local content, old = fileio.read(file) or "", tostring(input.old_str or "")
    local found = text.count(content, old)
    if found == 0 then
        return "No replacement was performed, old_str `" .. old .. "` did not appear verbatim in " .. shownAs .. ".", true
    elseif found > 1 then
        local at, from = {}, 1
        while true do
            local s, e = text.find(content, old, from)
            if not s then break end
            at[#at + 1] = tostring(text.count(content:sub(1, s - 1), "\n") + 1)
            from = e + 1
        end
        return "No replacement was performed. Multiple occurrences of old_str `" .. old .. "` in lines: "
            .. table.concat(at, ", ") .. ". Please ensure it is unique", true
    end
    fileio.write(file, (text.replace(content, old, tostring(input.new_str or ""), 1)))
    return "The memory file has been edited."
end

function MEMORY.insert(file, shownAs, input)
    if not fs.exists(file) or fs.isDir(file) then return "Error: The path " .. shownAs .. " does not exist", true end
    local lines = text.split(fileio.read(file) or "", "\n", true)
    local at = input.insert_line
    if type(at) ~= "number" or at ~= math.floor(at) or at < 0 or at > #lines then
        return "Error: Invalid `insert_line` parameter: " .. tostring(at)
            .. ". It should be within the range of lines of the file: [0, " .. #lines .. "]", true
    end
    local new = tostring(input.insert_text or "")
    table.insert(lines, at + 1, text.stripSuffix(new, "\n") or new)
    fileio.write(file, table.concat(lines, "\n"))
    return "The file " .. shownAs .. " has been edited."
end

function MEMORY.delete(file, shownAs)
    if file == MEMORY_DIR then return "Error: " .. MEMORY_ROOT .. " itself can't be deleted", true end
    if not fs.exists(file) then return "Error: The path " .. shownAs .. " does not exist", true end
    fs.delete(file)
    return "Successfully deleted " .. shownAs
end

-- (rename's paths are old_path and new_path, not path)
function MEMORY.rename(_, _, input)
    local from, fromShown = memoryFile(input.old_path)
    local to, toShown = memoryFile(input.new_path)
    if not (from and to) then return "Error: both paths must be in " .. MEMORY_ROOT, true end
    if from == MEMORY_DIR then return "Error: " .. MEMORY_ROOT .. " itself can't be renamed", true end
    if not fs.exists(from) then return "Error: The path " .. fromShown .. " does not exist", true end
    if fs.exists(to) then return "Error: The destination " .. toShown .. " already exists", true end
    fs.makeDir(fs.getDir(to))
    fs.move(from, to)
    return "Successfully renamed " .. fromShown .. " to " .. toShown
end

local function memory(input)
    local command = MEMORY[input.command]
    if not command then return "Error: unknown command " .. tostring(input.command), true end
    local file, shownAs = MEMORY_DIR, MEMORY_ROOT
    if input.command ~= "rename" then
        file, shownAs = memoryFile(input.path)
        if not file then return "Error: " .. tostring(input.path) .. " is outside " .. MEMORY_ROOT, true end
    end
    say("lightBlue", "--- memory: " .. input.command .. " " .. tostring(input.path or input.old_path))
    log("memory: " .. textutils.serialiseJSON(input))
    return command(file, shownAs, input)
end

--------------------------------------------------------------------------
-- run_program: ccnix's turtle programs
--------------------------------------------------------------------------
-- A program's manual (help/<name>.txt: ccnix's, else the checkout's), or nil
local function manualOf(name)
    local rel = "help/" .. name .. ".txt"
    local file = ccnix and ccnix.find and ccnix.find(rel)
    if not file and shell and shell.getRunningProgram then file = sysenv.repoRoot() .. "/" .. rel end
    return file and fileio.read(file) or nil
end

local function runProgram(input)
    local name = tostring(input.program or "")
    if not PROGRAMS[name] then
        return "No such program: " .. name .. " (" .. table.concat(tables.sortedKeys(PROGRAMS), ", ") .. ")", true
    end
    if input.help then
        local manual = manualOf(name)
        if not manual then return "No manual for " .. name .. " on this computer.", true end
        return clip(manual)
    end
    local file = sysenv.findProgram(PROGRAMS[name])
    if not (file and shell and shell.run) then return name .. " isn't on this computer.", true end
    local words = text.words(tostring(input.args or ""))
    local bound = BOUNDED[name]
    if bound then
        local ends = false
        for _, w in ipairs(words) do
            local opts = text.startsWith(w, "-") and not text.startsWith(w, "--") and w:sub(2) or ""
            for _, letter in ipairs(bound.letters) do
                if text.contains(opts, letter) then ends = true end
            end
        end
        if not ends then
            for i, a in ipairs(bound.add) do table.insert(words, i, a) end
        end
    end
    local line = #words > 0 and (name .. " " .. text.join(words, " ")) or name
    say("lightBlue", "--- run " .. line)
    log("run: " .. line)
    if CONFIRM then
        local a = ask("Run it? [y/N] ")
        if not text.startsWith(a:lower(), "y") then
            say("orange", "--- not run")
            return "The user declined to run this program.", true
        end
    end
    -- what it prints and its errors, kept for the model and shown as the
    -- code's output is (its own program, so through the real globals)
    local out, stopped = {}, false
    local savedPrint, savedPrintError = _G.print, _G.printError
    _G.print = function(...)
        out[#out + 1] = joined(...)
        return keepPrint(...)
    end
    _G.printError = function(...)
        local said = joined(...)
        out[#out + 1] = said
        if said == "Terminated" then stopped = true end
        if COLOUR then term.setTextColour(colours.red) end
        keepPrint(said)
        if COLOUR then term.setTextColour(colours.lightGrey) end
    end
    -- and what it writes to io.write (ip and ping do): a handle as io's own
    -- are (ccsh pipes the same way), kept and shown a line at a time
    local savedOut, pending = io and io.output and io.output(), ""
    local ioMeta = io and io.stdout and getmetatable(io.stdout)
    if ioMeta then
        io.output(setmetatable({ _handle = {
            write = function(s)
                pending = pending .. tostring(s)
                local lines = text.split(pending, "\n", true)
                pending = table.remove(lines)
                for _, l in ipairs(lines) do out[#out + 1] = l; keepPrint(l) end
            end,
            flush = function() end, close = function() end,
        } }, ioMeta))
    end
    T.savePos()                         -- where it starts from, for it to read
    if COLOUR then term.setTextColour(colours.lightGrey) end
    local ok, ran = pcall(shell.run, file, table.unpack(words))
    if COLOUR then term.setTextColour(colours.white) end
    _G.print, _G.printError = savedPrint, savedPrintError
    if ioMeta then
        io.output(savedOut)
        if pending ~= "" then out[#out + 1] = pending; keepPrint(pending) end
    end
    if stopped then error("Terminated", 0) end
    if not ok then error(ran, 0) end
    takeSavedPos()                      -- where it left the turtle
    out[#out + 1] = string.format("[%s %s; the turtle is at %s facing %d, fuel %s]", name,
        ran and "finished" or "failed", T.posString(), T.dir, tostring(turtle.getFuelLevel()))
    local all = clip(table.concat(out, "\n"))
    log("result:\n" .. all)
    return all, not ran
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
            if not text.startsWith(a:lower(), "y") then
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
            local from = text.find(out, "error: ")
            say("red", from and (text.cut(out:sub(from), "\n")) or out)
        end
        log((isErr and "error:\n" or "result:\n") .. out)
        return out, isErr
    elseif name == "status" then
        return status()
    elseif name == "run_program" then
        return runProgram(input)
    elseif name == "ask_user" then
        return askUser(input.question)
    elseif name == "memory" then
        return memory(input)
    end
    return "No such tool: " .. tostring(name), true
end

--------------------------------------------------------------------------
-- The API
--------------------------------------------------------------------------
local messages = {}
-- (input: tokens in at the full price; written: into the cache; cached:
-- read from it.  The three add up to all that was sent.)
local usage = { input = 0, written = 0, cached = 0, output = 0 }

-- Every string in v (in place) as UTF-8, which the API reads: the model's
-- own text is already, and stays byte for byte as it was (a thinking
-- block's signature covers all that came before it); CC's text (what was
-- typed, what a tool printed) is Latin-1, made UTF-8.
local function asUTF8(v)
    for k, x in pairs(v) do
        if type(x) == "string" then
            if not utf8.len(x) then v[k] = convert.toUTF8(x) end
        elseif type(x) == "table" then
            asUTF8(x)
        end
    end
    return v
end

local function body()
    -- (unicode_strings: without it each byte past ASCII is sent as a
    -- character of its own, and the API reads its "×" back as "Ã—")
    return textutils.serialiseJSON(asUTF8({
        model = MODEL,
        max_tokens = MAX_TOKENS,
        -- cached: the system prompt and tools (they never change), and
        -- the conversation up to its last block, read back by the next
        -- call (the top-level cache_control: the API moves that mark on
        -- as the conversation grows).  One TTL for both: a longer one
        -- may not come after a shorter.
        system = { { type = "text", text = SYSTEM, cache_control = CACHE } },
        cache_control = CACHE,
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
        -- a long session's old tool results are cleared server-side
        -- (the newest kept, the memory tool's never), so each round trip
        -- doesn't carry all of them (see the API docs: context editing)
        context_management = { edits = { {
            type = "clear_tool_uses_20250919",
            trigger = { type = "input_tokens", value = CLEAR_TRIGGER },
            keep = { type = "tool_uses", value = KEEP_TOOL_USES },
            clear_at_least = { type = "input_tokens", value = CLEAR_AT_LEAST },
            exclude_tools = { "memory" },
        } } },
    }), { allow_repetitions = true, unicode_strings = true })
end

local HEADERS = {
    ["Content-Type"] = "application/json",
    ["x-api-key"] = KEY,
    ["anthropic-version"] = API_VERSION,
    ["anthropic-beta"] = "server-side-fallback-2026-07-01,context-management-2025-06-27",
}

-- The events' data in a streamed reply: what follows each "data: ", up to
-- the end of its line.
local function eventData(stream)
    local out, pos = {}, 1
    while true do
        local _, last = text.find(stream, "data: ", pos)
        if not last then return out end
        local nl = text.find(stream, "\n", last + 1)
        local line = text.cut(stream:sub(last + 1, (nl or #stream + 1) - 1), "\r")   -- (a CR ends it too)
        out[#out + 1] = line
        pos = last + 1 + #line
    end
end

-- The API's own tools as shown: what they're called, and the input field
-- that says what they did (any other, such as the code a web search's
-- results are filtered with, shown by its name)
local SERVER_TOOL = { web_search = { "web search", "query" }, web_fetch = { "web fetch", "url" } }

-- Which field of a content block each kind of delta adds to
local DELTA_FIELD = { text_delta = "text", thinking_delta = "thinking", signature_delta = "signature",
                      input_json_delta = "input" }

-- The message from a streamed reply's events, or nil and the error the
-- stream ended with ({ type = ..., message = ... }).
local function fromEvents(stream)
    local msg, parts = nil, {}
    for _, data in ipairs(eventData(stream)) do
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
            local field = DELTA_FIELD[d.type]
            local piece = d.text or d.thinking or d.signature or d.partial_json
            if d.type == "citations_delta" and d.citation then
                -- a web page a text block quotes: one more for its list
                p.citations = p.citations or {}
                table.insert(p.citations, d.citation)
            elseif field and piece then
                p[field] = p[field] or {}
                table.insert(p[field], piece)
            end
        elseif t == "content_block_stop" and msg and parts[e.index + 1] then
            local b = msg.content[e.index + 1]
            for field, pieces in pairs(parts[e.index + 1]) do
                if field == "citations" then
                    b.citations = type(b.citations) == "table" and b.citations or {}
                    for _, c in ipairs(pieces) do table.insert(b.citations, c) end
                elseif field == "input" then
                    b.input = textutils.unserialiseJSON(table.concat(pieces)) or {}
                else
                    b[field] = (b[field] or "") .. table.concat(pieces)
                end
            end
        elseif t == "message_delta" and msg then
            msg.stop_reason = e.delta and e.delta.stop_reason
            msg.stop_details = e.delta and e.delta.stop_details
            msg.context_management = e.context_management or msg.context_management
            msg.usage = msg.usage or {}
            for k, v in pairs(e.usage or {}) do msg.usage[k] = v end
        elseif t == "error" then
            return nil, e.error or { type = "error", message = data }
        end
    end
    if not msg then return nil, { type = "unreadable", message = tostring(stream):sub(1, 200) } end
    return msg
end

-- What a wait cures: rate limits, overloads and outages, by HTTP code,
-- and by the error a stream ends with
local RETRY_CODES = { [429] = true, [500] = true, [502] = true, [503] = true, [529] = true }
local RETRY_ERRORS = { overloaded_error = true, api_error = true, rate_limit_error = true }

-- Send the conversation; the reply as a table, or nil and why.  Rate
-- limits, overloads and outages are retried with a growing wait, and so
-- is a stream cut off by an overload.
local function request()
    local wait = 2
    for attempt = 1, RETRIES + 1 do
        local h, err, failed = http.post({ url = API_URL, headers = HEADERS, body = body(), timeout = HTTP_TIMEOUT })
        local code, got
        if h then
            code, got = h.getResponseCode(), h.readAll()
            h.close()
        elseif failed then
            code, got = failed.getResponseCode(), failed.readAll()
            if failed.close then failed.close() end
        end
        local detail, again
        if code == 200 then
            local reply, e = fromEvents(got)
            if reply then return reply end
            -- an error partway: the ones a wait cures, as for their HTTP codes
            detail = tostring(e.type) .. ": " .. tostring(e.message)
            again = RETRY_ERRORS[e.type] == true
        else
            detail = tostring(err or "")
            if got then
                local e = textutils.unserialiseJSON(got)
                detail = e and e.error and (e.error.type .. ": " .. tostring(e.error.message)) or got:sub(1, 200)
            end
            again = (not code) or RETRY_CODES[code] == true
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
    usage.written = usage.written + (u.cache_creation_input_tokens or 0)
    usage.cached = usage.cached + (u.cache_read_input_tokens or 0)
end

-- The tokens a goal took (since `before`), and the session's in all
local function tokenLine(before)
    local d = {}
    for k, v in pairs(usage) do d[k] = v - before[k] end
    return string.format("[%d tokens in: %d from the cache, %d written to it, %d new; %d out; %d in all]",
        d.input + d.written + d.cached, d.cached, d.written, d.input, d.output,
        usage.input + usage.written + usage.cached + usage.output)
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

-- Add `said` as the user's: after tool calls left unanswered, with their
-- results first; after a user turn the API never answered (tool results
-- whose request failed), onto that turn.
local function addUser(said, why)
    local last = messages[#messages]
    if last and last.role == "user" then
        if type(last.content) == "string" then last.content = { { type = "text", text = last.content } } end
        table.insert(last.content, { type = "text", text = said })
        return
    end
    local blocks = unanswered(why)
    if #blocks == 0 then
        messages[#messages + 1] = { role = "user", content = said }
    else
        blocks[#blocks + 1] = { type = "text", text = said }
        messages[#messages + 1] = { role = "user", content = blocks }
    end
end

-- Work at `goal` until the model stops: run its tool calls and send the
-- results back, call after call, up to MAX_STEPS of them.
local function converse(goal)
    addUser(goal, "Not run: the goal ended before this call was answered.")
    log("goal: " .. goal)
    local steps, overBudget, cutOff, pauses = 0, false, false, 0
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
            if b.type == "text" and b.text ~= "" then print(convert.fromUTF8(b.text)); log("claude: " .. b.text) end
            if b.type == "thinking" and (b.thinking or "") ~= "" then log("thinking: " .. b.thinking) end
            if b.type == "server_tool_use" then         -- a web search or fetch, done by the API
                local shows = SERVER_TOOL[b.name]
                local what = shows and shows[1] .. ": " .. tostring((b.input or {})[shows[2]] or "")
                    or tostring(b.name):gsub("_", " ")
                say("lightBlue", "--- " .. convert.fromUTF8(what))
                log(what)
            end
        end
        for _, edit in ipairs((reply.context_management or {}).applied_edits or {}) do
            log(string.format("context: %d old tool results cleared (%d tokens)",
                edit.cleared_tool_uses or 0, edit.cleared_input_tokens or 0))
        end
        if reply.stop_reason == "pause_turn" and pauses < PAUSES then
            -- the API stopped partway through its own tools (web searches):
            -- sent back as it is, it carries on where it was
            pauses = pauses + 1
        elseif reply.stop_reason == "tool_use" then
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
    if not takeSavedPos() then T.startAtHome(true) end
    say("yellow", string.format("Claude at the controls (%s, effort %s). Turtle at %s facing %d, fuel %s.",
        MODEL, EFFORT, T.posString(), T.dir, tostring(turtle.getFuelLevel())))
    if goal == "" then
        goal = ask("Goal: ")
    end
    while goal ~= "" do
        local before = tables.copy(usage)
        converse(goal)
        say("grey", tokenLine(before))
        goal = ask("> ")
    end
end

local ok, err = pcall(T.run, main)
print = screenPrint
if not ok then error(err, 0) end
