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
--          [--steps N] [--cache 5m|1h] [--confirm] [--resume]
--
--   claude dig a 3 by 3 tunnel 20 blocks ahead and come back
--   claude                      asks for the goal
--
--   --model id   the model: opus, sonnet or haiku (claude-opus-5-5,
--                claude-sonnet-5-5, claude-haiku-5-5), or any model id as
--                the API names it (default opus)
--   --steps N    at most N tool calls per goal (default 60), then it's
--                told to stop and sum up
--   --cache 1h   keep the conversation cached for an hour with no call
--                reading it, not 5 minutes (for long pauses between
--                goals: writing it costs more, 2x the input price, not
--                1.25x; reading it is cheap either way)
--   --confirm    show each piece of code and ask before running it (the
--                model can ask that for one piece: review = true)
--   --resume     carry on with the goal in /claude/resume.txt, in a new
--                conversation, with the options it was given (what
--                autostart runs after a reboot; nothing there: it asks)
--
-- When it stops, type the next thing to do (it keeps the conversation),
-- /new to start a new conversation (its memory and files stay, and its
-- helpers are loaded again), or press Enter on an empty line to quit.
-- Ctrl+T stops it (under T.run, so the saved position stays right).
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
-- What's new: claude keeps the ccnix version it last ran with in
-- /claude/.version.  When ccnix has been updated since, the first goal
-- tells the model what changed for it (help/claude-news.txt, from
-- doc/claude-news.txt: the lines for each version since).
--
-- Resuming after a reboot: while a goal is under way /claude/resume.txt
-- holds it (a first line of the session's options, then the goal, to
-- which the model adds where it is), and it's removed when the goal ends
-- or Ctrl+T stops claude.  With the settings ccnix.autostart = claude and
-- claude.resume = true, a turtle that went down mid-goal (a server
-- restart, its chunk unloaded) starts `claude --resume` at boot: the
-- model is told it was interrupted and to read its memory and carry on.
-- That spends API money with nobody at the turtle, so it's off unless
-- set; with no goal to resume, autostart starts claude waiting for one.
--
-- Keeping the player told: when claude.remindChat minutes (default 15, 0
-- for never) pass with no chat message to the player (T.report, the chat
-- tool), the model is reminded after the next tool results.
--
-- Hearing the player: while claude waits for the model's reply, a chat
-- box aboard goes on the free side (an empty one or a tool's: never the
-- chunk controller's or another upgrade's) and the chat is heard; what
-- was there is back before the model's code runs.  What turtle.player
-- says (anyone, when it isn't set) comes with the next results.  What's
-- said while the code runs is missed.  claude.listen = false turns it off.
--
-- The log, claude.log beside the program: each entry with its time (UTC);
-- the options a session started with, the goals, the code and what it
-- did, the thinking, each call's tokens and how long it took, retries,
-- clears, and each goal's tokens in all.  A call that writes many tokens
-- to the cache after a long gap is the cache having run out (--cache 1h).
-- At 256 KB (the setting claude.logSize, in bytes) it becomes claude.log.1,
-- the older copies moving up to claude.log.3 (the setting claude.logKeep:
-- that many kept, about 8 hours at 3), and a new claude.log starts.  On a
-- disk with less than a quarter free (turtlelib's map, .map/, counted in)
-- fewer are kept, the oldest going first; the current log always stays.
--
-- Its helpers: functions it wants again are kept one to a file, each
-- with keep(name, code) in its code, which runs the code (so it's defined
-- at once) and writes it to /claude/helpers/<name>.lua; code that doesn't
-- compile or run is refused and nothing is written.  At the start of each
-- session /claude/helpers.lua (an older single file, which it can still
-- write) and then each file in /claude/helpers/, in name order, is run in
-- the code's own world, each on its own, so what they define is in scope
-- for every chunk the model runs.  The files that fail are told to the
-- model with its first goal, and the session goes on without them.  A
-- call whose code declares a `local` at its top level (an unindented
-- `local` line) gets a note: that name is gone when the call ends.
--
-- What it can call: the system prompt carries turtlelib's index, one line a
-- function (turtle/tl/index.txt, made from the comments above the functions
-- by sim/mkhelp.py), and says where help/turtlelib.txt, the full reference,
-- is to read with fs.  The index is read when claude starts; if it isn't on
-- the computer the prompt says so and sends the model to the source.
--
-- The code has the turtle, turtlelib, peripherals, the plain Lua bits,
-- CC's http, `require` for CraftOS's cc.* modules (cc.strings, cc.pretty,
-- ...) and ccnix's libraries for text, the network and the world (text,
-- scan, convert, path, glob, regex, tables, fileio, getopt, net, netdb,
-- httpc, mc), and the files: fs, io, loadfile and dofile read anything
-- but the API key, and write only under /claude/ (so it can't rewrite the
-- programs or the startup).  No shell.
--
-- Each result of the code ends with a line saying where the turtle is, its
-- fuel and what the call used, its free slots, and any lava or water
-- beside it (the log has it too; the screen doesn't).
--
-- The other tools:
--   status       where it is, fuel, what's around, what it carries, the
--                tools equipped, what's attached, the protected areas
--                near it, a mine job, the network
--   run_program  runs one of ccnix's turtle programs (mine, farm, mow,
--                home), or ip and ping for the network, with arguments,
--                or reads its manual (help/)
--   ask_user     asks you, at the prompt
--   chat         says something in the game's chat (through a chat box, to
--                the setting turtle.player, or everyone when it isn't set),
--                or asks there and waits for an answer starting with
--                "claude" from that player, or one typed at the prompt,
--                whichever comes first (T.report.ask); the wait is kept
--                under the cache's time unless the model asks for longer
--   memory       its notes, kept between sessions in /claude/memories/
--                (the API's memory tool: view, create, str_replace,
--                insert, delete, rename, only under that folder)
--   web_search, web_fetch   run on Anthropic's side, not the turtle's
--                (each costs a little; at most a few a reply)
-- Old tool calls (the code and its results) and old thinking are cleared
-- from the conversation once it's long (the API's context editing), the
-- memory tool's kept; when the API says the conversation is too long all
-- the same, it's sent again with more of it cleared.  A reply paused
-- partway through its web searches is carried on.
--
-- Position: it picks up turtlelib's saved position (.turtlepos) if there
-- is one, so `home` still works afterwards; otherwise here is (0,0,0)
-- facing +z.  In a session T.cfg.maxHeight is 256 (programs keep 16), unless
-- the helpers or the model set it otherwise.
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
local pager = select(2, pcall(require, "pager"))     -- (a failed require leaves its message: not a table)
if not (type(pager) == "table" and pager.page) then pager = nil end
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
-- The log: its file, the size at which it's moved to claude.log.1, and how
-- many old ones are kept (one table, not locals: claude.lua is near CC's
-- 200 locals)
local LOG = {
    file = T.dataPath("claude.log"),
    size = tonumber(T.setting("claude.logSize", 262144,
        "claude: bytes at which claude.log is moved to claude.log.1 and a new one started")) or 262144,
    keep = tonumber(T.setting("claude.logKeep", 3,
        "claude: old logs kept (claude.log.1 ...), fewer when the disk has less than a quarter free")) or 3,
}
local REMIND_CHAT = tonumber(T.setting("claude.remindChat", 15,
    "claude: minutes without a chat message to the player before the model is reminded to tell them (0: never)")) or 15
-- (read by autostart; defined here so sysctl describes it)
T.setting("claude.resume", false,
    "claude: with ccnix.autostart=claude, carry on at boot with a goal a reboot cut short (spends API money unattended)")
local HELPERS_FILE = "claude/helpers.lua"   -- the functions the model keeps, loaded each session: the old single file,
local HELPERS_DIR = "claude/helpers"        -- and then each file in here, one a helper (keep(name, code) writes them)
local MAX_HEIGHT = 256          -- T.cfg.maxHeight in a session (blocks above the start; programs keep 16)
local MAX_TOKENS = 32000        -- a reply is a short note and some code, but the
                                -- thinking before it counts too
local MAX_OUTPUT = 6000         -- characters of a tool's output sent back
local RETRIES = 4               -- on rate limits, overload and outages
local HTTP_TIMEOUT = 60         -- seconds with nothing coming in, at most 60 in CC; the
                                -- reply is streamed, so a long one keeps coming
local NEAR_AREAS = 16          -- blocks: how close a protected area is "near" in status
local MEMORY_DIR = "claude/memories"   -- where the memory tool's /memories is kept
local VERSION_FILE = "claude/.version"  -- the ccnix version the model last ran with
local NEWS = "help/claude-news.txt"     -- what changed, for the model (doc/claude-news.txt, copied to help/)
local WEB_USES = 5              -- web searches, and fetches, at most per reply
local PAUSES = 5                -- times a paused reply (pause_turn) is carried on
-- Old tool results cleared once the conversation is this long (tokens in),
-- the last KEEP_TOOL_USES kept, and only if it frees CLEAR_AT_LEAST.  A
-- clear changes the conversation from the first result cleared on, so the
-- cache is written again from there: rarer and bigger clears cost less
-- than many small ones.
local CLEAR_TRIGGER, KEEP_TOOL_USES, CLEAR_AT_LEAST = 100000, 6, 30000
-- The harder clear once the API has said the prompt is too long: sooner,
-- fewer results kept, and whatever it frees
local HARD_TRIGGER, HARD_KEEP, HARD_AT_LEAST = 50000, 2, 0
-- The thinking of the last THINKING_TURNS assistant turns is kept; older
-- thinking is cleared with the old tool results' code
local THINKING_TURNS = 3
-- How long the cache keeps the conversation with no request reading it:
-- the API has 5 minutes and an hour (writing for an hour costs 2x the
-- input price, for 5 minutes 1.25x; reading 0.05x on Opus 5.5), and how
-- the system prompt says it
local CACHE_TTLS = { ["5m"] = "5 minutes", ["1h"] = "an hour" }
-- The same in seconds, and how far under it the chat tool's wait for an
-- answer stops unless the model asks for longer
local CACHE_SECONDS = { ["5m"] = 300, ["1h"] = 3600 }
local CACHE_MARGIN = 30
-- The chat tool: the chat box it equips for a wait when none is attached,
-- the word an answer in chat starts with, and how often the question is
-- said again while it waits (seconds)
local CHAT_BOX = "advancedperipherals:chat_box"
local CHAT_PREFIX = "claude"
local CHAT_REMIND = 120
-- The programs run_program may run: ccnix's turtle programs, and ip (the
-- network's settings: it saves them itself) and ping to set up and check
-- the network
local PROGRAMS = { mine = "turtle/mine", farm = "turtle/farm", mow = "turtle/mow", home = "turtle/home",
                   ip = "bin/ip", ping = "bin/ping" }
-- Those that go on until stopped unless told otherwise: the option letters
-- that end them, and what's added when none of those is given (a ping
-- left to run would hold the session for ever)
local BOUNDED = { ping = { letters = { "c", "w" }, add = { "-c", "4" } } }
-- The short names --model takes, and the model each stands for (any other
-- name is sent to the API as it is)
local MODEL_ALIASES = { opus = "claude-opus-5-5", sonnet = "claude-sonnet-5-5", haiku = "claude-haiku-5-5" }

--------------------------------------------------------------------------
-- Arguments
--------------------------------------------------------------------------
-- (T.options: the goal's words are free, a "-5" or a "-x" in it too;
-- only these are options)
local USAGE = "Usage: claude [goal words...] [--model id] [--effort low|medium|high] [--steps N] [--cache 5m|1h] [--confirm] [--resume]"
-- A goal kept for a resume after a reboot (ADR-0012 D4): /claude/resume.txt,
-- its first line the session's options ("options: --steps 400 --cache 1h"),
-- then the goal and what the model added.  (The options' table is here too:
-- that line is read with it.)
local resume = { file = "claude/resume.txt", prefix = "options:",
                 options = { confirm = true, model = "=", effort = "=", steps = "=", cache = "=", resume = true } }
local opts, args = T.options({ ... }, resume.options)
if not opts then
    print("claude: " .. args)
    print(USAGE)
    return
end
-- --resume: the goal from the file, the options it was given under any given here
if opts.resume then
    local saved = fileio.read(resume.file)
    if saved then
        local first, rest = text.cut(saved, "\n")
        local given = text.stripPrefix(first, resume.prefix)
        if given then
            for k, v in pairs(T.options(text.words(given), resume.options) or {}) do
                if opts[k] == nil then opts[k] = v end
            end
        else
            rest = saved            -- (the model rewrote it without the line)
        end
        resume.goal = text.trim(rest or "")
    end
end
if opts.cache and not CACHE_TTLS[opts.cache] then
    print("claude: --cache is 5m or 1h, not " .. opts.cache)
    print(USAGE)
    return
end
local CONFIRM = opts.confirm == true
local MODEL = opts.model and (MODEL_ALIASES[opts.model] or opts.model) or MODEL_ALIASES.opus
local EFFORT = opts.effort or "medium"
local MAX_STEPS = opts.steps and tonumber(opts.steps) or 60
-- (5 minutes is the API's own default, so it isn't named)
local CACHE = { type = "ephemeral", ttl = opts.cache ~= "5m" and opts.cache or nil }
local goal = table.concat(args, " ")
if resume.goal then
    goal = "You were interrupted (reboot); read your memory and resume: " .. resume.goal
end

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
-- A file of ccnix's (ccnix's, else the checkout's), or nil
local function findFile(rel)
    local file = ccnix and ccnix.find and ccnix.find(rel)
    if not file and shell and shell.getRunningProgram then
        file = sysenv.repoRoot() .. "/" .. rel
        if not fs.exists(file) then file = nil end
    end
    return file
end

-- turtlelib's index (one line a function, made from the comments above
-- them) and where its full reference is, for the prompt below
local INDEX_FILE = findFile("turtle/tl/index.txt")
local INDEX = INDEX_FILE and fileio.read(INDEX_FILE)
local MANUAL_FILE = findFile("help/turtlelib.txt")
if not INDEX then
    say("yellow", "turtle/tl/index.txt isn't on this computer: Claude gets no list of turtlelib's functions (ccnix update, or setup, brings it).")
    INDEX = "(The index of turtlelib's functions, turtle/tl/index.txt, isn't on this computer. The functions are the ones the source, turtlelib.lua in the turtle folder, defines as `function T.name(...)`: read it with fs and search it for a name before you guess.)"
end

local DETAILS = MANUAL_FILE
    and ("When a line is not enough (all the options, the cases, how it fails), the full reference is help/turtlelib.txt, at " .. MANUAL_FILE
        .. ": each function has a paragraph under its signature line. It is long, so don't print it whole; read the part you need, for instance: local f = fs.open(\""
        .. MANUAL_FILE .. "\", \"r\"); local all = f.readAll(); f.close(); local a = all:find(\"T.moveTo(\", 1, true); print(all:sub(a, a + 1800)).")
    or "The full reference, help/turtlelib.txt, isn't on this computer: for the details read the source, turtlelib.lua in the turtle folder, with fs."

local SYSTEM = [==[
You are driving a ComputerCraft (CC:Tweaked) turtle in Minecraft, from inside the turtle. You act mostly by calling the `lua` tool with Lua code (Lua 5.2 as CC runs it), which runs on the turtle; what it prints and returns comes back to you. Nothing happens unless you call a tool.

Frames: coordinates are the turtle's own, dead-reckoned by the turtlelib library `T`. It started at (0,0,0) facing +z (heading 0); +x is to its right (heading 1), -z is heading 2, -x is heading 3; y is up. T.pos = {x, y, z} and T.dir are where it thinks it is. turtlelib wraps the turtle API, so they stay right however a move is made: turtle.forward(), back(), up(), down(), turnLeft() and turnRight() called straight are counted, and so are digs and placements. T's own moves add fuel (T.ensureFuel), digging what T.diggable lists (empty to start; or set T.diggable["minecraft:stone"] = true) and attacking what's in the way. T.scan(r) does the Geo Scanner's work in this frame for you (see Building below); if you call scanBlocks yourself, its entries carry r, u and f (right, up and forward of the turtle, relative to its heading) as well as the world x, y and z: use r/u/f for cells in this frame. A program run with `--here` makes where the turtle stands its (0,0,0), and so yours; the map, the protected areas, the junk chest and the chests at home move with the frame, so they still name the same blocks.

Safety: protected areas stop every dig through the turtle API, yours included: T.protect(name, x1, y1, z1, x2, y2, z2) protects a box (kept on disk, the same for every program on the turtle), and turtle.dig() or T.forward() into it returns false, "protected: <name>"; T.inside(name, fn) runs fn as a job that owns that area. Protect what you build and what you must not damage (the base, chests, a build you have finished). Digs at chests, barrels, shulker boxes, spawners and ComputerCraft blocks are refused too (unless T.cfg.digContainers = true, which you should not set unless asked): never dig or break those, hoppers or computers, and don't break blocks you weren't asked to. T.moveTo says why it stopped (blocked, protected, lava) and avoids lava, fire, doors and the player's furnishings (ladders, trapdoors, gates, signs, lanterns, torches, rails) by default, even with dig = true. Nothing in turtlelib drops items on the ground or into lava: junk goes to a junk chest (T.setJunkChest, T.dumpJunk) or stays in the turtle; put the job's building materials in T.keep (a table of item names) first, since everything not kept is junk. In this session T.cfg.maxHeight is 256 (T.up and the other moves stop that far above where the turtle started; a program keeps 16): set it lower for a ceiling. A lua call with review = true shows its code to the person at the turtle and runs only on a yes: use it before something risky you can't undo.

Cost: a move costs one fuel; a Geo Scanner scan costs fuel too, steeply with its radius (r=16 has cost thousands), so scan with r of 8 or less and check turtle.getFuelLevel() before and after. Keep an eye on fuel: T.refuelTo(n) burns fuel items from the inventory, T.refuelFrom(side, n) from a chest. Each tool call is a slow network round trip and the whole conversation is sent each time (cached, but it grows), so work in few calls with loops that check themselves. The cache keeps the conversation for @CACHE@ with no call reading it: a call or a wait (sleep, ask_user, a chat that asks) longer than that has the whole conversation written to the cache again, at more than the call costs. So keep a call to a few minutes, and give every long loop caps on fuel, time and count.

Building: the library is meant to be used end to end, and loads each part the first time you call it. (1) Where: T.setOrigin(x, y, z, facing) once, with the cell the turtle stands on and the compass way it faces (ask the player; gps.locate is used when there is a GPS; without a facing a scan works it out), then T.toWorld / T.toLocal convert between this frame and the game's. (2) Look: T.scan(r) and T.scanBox(box) put what the Geo Scanner sees into the map, a record on disk of every block the turtle has seen, dug, placed or walked through; read it with T.map.get / find / count / top, and as text with T.map.heights(box) and T.map.slice(y, box). A scan gives names, not states: T.inspectAt / inspectAll read a block's facing and half. Ask the map rather than keeping your own tables of the world. (3) Go: T.moveTo for a short run, T.travel(x, y, z) for a long one (it plans over the map, along a clear layer, round protected areas and lava, and re-plans at a bump); T.path only plans. (4) Place: T.placeAt(x, y, z, item, { facing = "north", half = "top" }) gets stairs, slabs, logs, doors, torches and the like the right way round (it learns what the game does; T.forgetPlacements() drops what it learnt if that goes wrong); for a structure write a blueprint (T.blueprint.walls / box / fill / fromMap, or parse a plan file or table) and T.build(plan, { inside = "keep" }) (inside names the protected area the build works in, protect "keep" afterwards with opts.protect): it checks the materials, builds layer by layer, saves its progress and carries on where it stopped if you call T.build() again; T.verify(plan) lists what differs; T.replace swaps one block for another in a box. (5) Materials: T.canCraft and T.craft(name, n) work from a chest in front (they stash and restore the inventory themselves), T.smelt, T.harvest(pattern, box, n) digs what you need nearest first, T.fetch / T.stow / T.where / T.catalogue for the chests at home (tell it with T.addChest), T.refuelFromLava, T.fuelFor(plan) before a big job; T.cfg.autoDump = true sends a nearly full inventory to the chests by itself (in your code, not while a program you run has the turtle). T.addRecipe is kept in memory only: keep() the calls. (6) Keep track: T.job.start(goal, steps) and T.job.done() so a cleared conversation or a reboot resumes at the step; T.report(text) tells the player through a chat box; T.cfg.undo = true journals your digs and placements (not a program's you run) so T.undo(n) can put them back; a block with a facing goes back only once T.setOrigin is told.

How to work: do several steps per call, check results in the code, and return short summaries of what you learn (counts, what failed), not whole tables. Each call is a chunk of its own: a global you set (x = 1, function f() end) persists for the session, a `local` ends with its call, and clearing old results never removes a definition (only a new session starts without them): keep each reusable helper (a function you will want again) with keep(name, code): it runs the code now and writes it to /claude/helpers/<name>.lua (code that doesn't compile or run is refused, and nothing is written); at the start of every session /claude/helpers.lua, then each file in /claude/helpers/, is loaded into the code's world, each on its own, so what they define is there in every lua call. Settings every session should have (T.keep items, T.cfg values, T.diggable) go in a keep() helper too: a session starts with turtlelib's defaults. While a goal is under way /claude/resume.txt holds it, for a resume after a reboot: keep its first line, and add where you are and what's left as you go. Before a big job, write its plan to /claude/<job>.md and T.job.start it, and check first: fuel for the job and the way back, free slots, the materials, the protected areas, the route, and lava or water next to anything you will dig. T.job.clear() ends a finished job. Before telling the player something is done, check each result, and the why that comes with every T call's false or nil. Prefer turtlelib's functions to writing your own loops, and look a function up in the index below before you write one. An upgrade you want as a peripheral (the Geo Scanner, a chat box, a crafting table) is used with T.withPeripheral(name, fn), which swaps it in and back and never takes off a chunk controller. Files: read any with fs or io; write only under /claude/ (fs.makeDir("/claude") first), for notes, maps, helpers or programs you keep between goals. The rest of the turtle API works as usual: turtle.inspect(), inspectUp(), inspectDown() -> ok, {name=..., state=...}; detect/detectUp/detectDown; select(slot), getItemDetail(slot), getItemCount(slot); place/placeUp/placeDown; drop/dropUp/dropDown(n); suck/suckUp/suckDown(n); getFuelLevel(); peripheral.wrap("left"/"right"/"front"/"top"/"bottom"); sleep(seconds).

The player: keep them told in chat (T.report) at the start, at milestones, at trouble and at the end, honestly, saying what failed too. What they say in chat while you think comes with your next results (a chat box aboard listens); what's said while your code runs is missed. The chat tool says something in the game's chat without code, and with ask = true asks and waits for the answer, from the chat or the keyboard; T.report.ask(question, opts) asks from code. Don't undo or "fix" their changes; ask before replacing their things or digging big holes in shared spaces. Restore a floor you dig through with the same block, and stow what isn't in use. Build for a player two blocks tall: 3 air above a stair's walking line, a landing and a turn where a flight meets a wall, corner pieces where railings meet on a diagonal, and railings at drops of more than 3.

What you can call in turtlelib (T), one line a function, with what it does and returns (made from the code's own comments, so it is right). A line ending in a colon is a group heading, not a function.
@INDEX@

@DETAILS@

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

Memory: the memory tool keeps notes between sessions (where the base, chests and fuel are, what's been mined, what the person likes, jobs half done). Look at it before you start; write down what you'd want next time, briefly, and keep it pruned: what's current first, the old moved to an archive file. web_search and web_fetch look things up on the internet (recipes, how a mod's block works); they cost a little each, so use them when you need to know, not by habit.

Call `status` to see where the turtle is, what's around it, what it carries and has attached, the protected areas near it, the world origin and the job journal's step, and whether the network is up. If the task is unclear or risky, ask: the chat tool with ask = true reaches the player in the game, ask_user only the keyboard. When done (or stuck), stop and say what you did and where the turtle is; say plainly if something failed.]==]
SYSTEM = text.replace(text.replace(SYSTEM, "@DETAILS@", DETAILS), "@INDEX@", INDEX)
-- (the session's TTL: the prompt stays the same for the whole session, so
-- it stays cached)
SYSTEM = text.replace(SYSTEM, "@CACHE@", CACHE_TTLS[opts.cache or "5m"])

local TOOLS = {
    {
        name = "lua",
        description = "Run Lua on the turtle. The code runs as a chunk with turtle, T (turtlelib), peripheral, http, os, textutils, math, string, table, sleep, fs and io in scope (fs, io, loadfile and dofile read any file but the API key and write only under /claude/), and require for ccnix's libraries text, scan, convert, path, glob, regex, tables, fileio, getopt, net, netdb, httpc and mc, and the CraftOS modules cc.strings, cc.pretty, cc.expect, cc.base64, cc.completion, cc.shell.completion, cc.image.nft, cc.audio.dfpwm and cc.require; what it prints (print, write, io.write, printError) and returns comes back to you (tables are serialised). Errors come back as an error result. Globals persist for the session (clearing old results doesn't remove them); a local ends with its call. keep(name, code) runs a helper and keeps it, in /claude/helpers/<name>.lua, for every session after. Each result ends with a status line: where the turtle is, its fuel and what the call used of it, the free slots, and lava or water beside it.",
        input_schema = {
            type = "object",
            properties = {
                code = { type = "string", description = "The Lua code to run." },
                review = { type = "boolean", description = "Show the code to the person at the turtle first, and run it only if they say yes." },
            },
            required = { "code" },
        },
    },
    {
        name = "status",
        description = "Where the turtle is (position, heading), its fuel, what's in front, above and below it, what it carries, the tools it has equipped, the peripherals attached, the protected areas within 16 blocks of it, the computer's label, whether `mine` has a job under way, and whether http and ccnix's network are up (its addresses).",
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
    {
        name = "chat",
        description = "Say something to the player in the game's chat (through a chat box: the player in the setting turtle.player, or everyone when none is set). With ask = true it asks and waits for the answer: a chat message starting with \"claude\" from that player, or a line typed at the turtle's keyboard, whichever comes first. The wait stops short of the cache's " .. CACHE_TTLS[opts.cache or "5m"] .. " unless you give a longer timeout_s; no answer by then is a normal result, not an error.",
        input_schema = {
            type = "object",
            properties = {
                text = { type = "string", description = "What to say, or the question." },
                ask = { type = "boolean", description = "Wait for an answer." },
                timeout_s = { type = "number", description = "The longest wait for an answer, in seconds." },
            },
            required = { "text" },
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
local net = select(2, pcall(require, "net"))
if type(net) ~= "table" then net = nil end

-- Seconds since 1970 (CC's os.epoch is in ms; plain Lua has os.time)
local function now()
    return os.epoch and math.floor(os.epoch("utc") / 1000) or os.time()
end

-- Will a quarter of the log's disk stay free once the current log has
-- grown to LOG.size?  (Yes where CC can't tell.)  The map caps itself at a
-- quarter of the disk, so the logs leaving a quarter free leave it room.
function LOG.roomy()
    local dir = fs.getDir(LOG.file)
    local okCap, capacity = pcall(fs.getCapacity, dir)
    local okFree, free = pcall(fs.getFreeSpace, dir)
    if not (okCap and okFree and type(capacity) == "number" and type(free) == "number") then return true end
    local growth = LOG.size - (fs.exists(LOG.file) and fs.getSize(LOG.file) or 0)
    return free - math.max(0, growth) >= capacity / 4
end

-- Past LOG.size the log becomes claude.log.1, each old one moving up a
-- number (the one past LOG.keep goes); then, and at the session's first
-- entry, old ones go, the oldest first, while the disk is short of a
-- quarter free.  The current log is never deleted.
function LOG.rotate()
    local function old(n) return LOG.file .. "." .. n end
    local full = fs.exists(LOG.file) and fs.getSize(LOG.file) >= LOG.size
    if full then
        if fs.exists(old(LOG.keep)) then fs.delete(old(LOG.keep)) end
        for n = LOG.keep - 1, 1, -1 do
            if fs.exists(old(n)) then fs.move(old(n), old(n + 1)) end
        end
        if LOG.keep >= 1 then fs.move(LOG.file, old(1)) else fs.delete(LOG.file) end
    end
    if not full and LOG.trimmed then return end
    LOG.trimmed = true
    for n = LOG.keep, 1, -1 do
        if LOG.roomy() then return end
        if fs.exists(old(n)) then fs.delete(old(n)) end
    end
end

-- Each entry in the log starts with when it was written (UTC).
local function log(line)
    LOG.rotate()
    local f = fs.open(LOG.file, "a")
    if f then f.writeLine(os.date("!%Y-%m-%d %H:%M:%S ", now()) .. line); f.close() end
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
    math = math, string = string, table = table, sleep = sleep, keys = keys,
    colours = colours, colors = colors or colours,
    fs = codeFs, io = codeIo,
    pairs = pairs, ipairs = ipairs, next = next, select = select, type = type,
    tostring = tostring, tonumber = tonumber, unpack = unpack or table.unpack,
    pcall = pcall, xpcall = xpcall, error = error, assert = assert,
    setmetatable = setmetatable, getmetatable = getmetatable,
    rawget = rawget, rawset = rawset, rawequal = rawequal,
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

-- What the code prints is shown and, while a call runs, kept in `printed`
-- for the model (nil between calls: what helpers.lua prints as it loads is
-- only shown).  It's the code's print from the start, so a print at the top
-- of helpers.lua works too.  write and io.write go a line at a time: what
-- they leave without a newline waits in `partial` for the rest of its line.
local printed
local partial = ""
local function emit(line)
    keepPrint(line)
    if printed then printed[#printed + 1] = line end
end
local function capture(...)
    local line = partial .. joined(...)
    partial = ""
    emit(line)
end
local function codeWrite(s)
    local lines = text.split(partial .. s, "\n", true)
    partial = table.remove(lines)
    for _, l in ipairs(lines) do emit(l) end
end
-- what's left of a line when the code stops writing
local function flushPartial()
    if partial ~= "" then capture() end
end
API.print = capture
API.write = function(s) codeWrite(tostring(s)) end
codeIo.write = function(...)
    for i = 1, select("#", ...) do codeWrite(tostring((select(i, ...)))) end
end
-- (red on a colour screen, as CC's own)
API.printError = function(...)
    local was = COLOUR and term.getTextColour()
    if was then term.setTextColour(colours.red) end
    capture(...)
    if was then term.setTextColour(was) end
end

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

-- Run one helper file in the code's world: nil, or what went wrong, as a
-- sentence for the model.
local function loadHelperFile(file)
    local chunk, err = codeLoadfile(file, "t", env)
    local ok = chunk ~= nil
    if chunk then
        ok, err = pcall(chunk)
        flushPartial()
        if err == "Terminated" then error(err, 0) end
    end
    if ok then return nil end
    return "/" .. file .. " failed to load: " .. tostring(err)
end

-- The helper files there are: /claude/helpers.lua first, then the .lua
-- files in /claude/helpers/ in name order.
local function helperFiles()
    local files = {}
    if fs.exists(HELPERS_FILE) and not fs.isDir(HELPERS_FILE) then files[1] = HELPERS_FILE end
    if fs.isDir(HELPERS_DIR) then
        local names = fs.list(HELPERS_DIR)
        table.sort(names)
        for _, name in ipairs(names) do
            local file = HELPERS_DIR .. "/" .. name
            if text.endsWith(name, ".lua") and not fs.isDir(file) then files[#files + 1] = file end
        end
    end
    return files
end

-- Run the helper files in the code's world, each on its own, so what they
-- define is there for the model's code: one that fails costs only what it
-- defines.  Returns nil, or the files that failed, as a sentence for the
-- model.
local function loadHelpers()
    local failed = {}
    for _, file in ipairs(helperFiles()) do
        local why = loadHelperFile(file)
        if why then failed[#failed + 1] = why end
    end
    if #failed == 0 then return nil end
    local note = "Not all your kept helpers loaded, so what these define is missing (fix the file, or keep() it again): "
        .. table.concat(failed, "; ")
    log(note)
    return note
end

-- keep(name, code) in the code: a helper kept for every session after.
-- The code is compiled (its errors named after the helper) and run, so
-- what it defines is there at once, then written to
-- /claude/helpers/<name>.lua.  Code that doesn't compile or run is an
-- error, and nothing is written.  Returns true and the file.
API.keep = function(name, code)
    if type(name) ~= "string" or not scan.isName(name) then
        error("keep: the name is one word (letters, digits and _): it names the file", 2)
    end
    if type(code) ~= "string" then error("keep: the code is a string of Lua", 2) end
    local chunk, err = load(code, "=" .. name, "t", env)
    if not chunk then error("keep: " .. name .. " doesn't compile, so nothing was kept: " .. tostring(err), 2) end
    local ok, why = pcall(chunk)
    if not ok then
        if why == "Terminated" then error(why, 0) end
        error("keep: " .. name .. " failed as it ran, so nothing was kept: " .. tostring(why), 2)
    end
    local file = HELPERS_DIR .. "/" .. name .. ".lua"
    fs.makeDir(HELPERS_DIR)
    local saved, notSaved = fileio.write(file, code)
    if not saved then error("keep: " .. tostring(notSaved), 2) end
    return true, "/" .. file
end

-- The functions the code's unindented `local` lines declare ("local
-- function f", "local f = function"), each once: a local at the top of a
-- call ends with it, which the model may have forgotten.  Only functions:
-- `local text = require("text")` or `local ok, why = T.up()` is meant to
-- end with the call.  (A heuristic: a long string's line that starts with
-- "local" counts too.)
local function topLocals(code)
    local names, seen = {}, {}
    for _, line in ipairs(text.split(code, "\n", true)) do
        local sc = scan.new(line)
        local name
        if sc:accept("local") and scan.isSpace(sc:peek()) then
            sc:skipSpaces()
            name = sc:readName()
            if name == "function" then
                sc:skipSpaces()
                name = sc:readName()
            else
                -- local NAME = function
                sc:skipSpaces()
                local isFunction = false
                if sc:accept("=") then
                    sc:skipSpaces()
                    isFunction = sc:readName() == "function"
                end
                if not isFunction then name = nil end
            end
        end
        if name and not seen[name] then seen[name] = true; names[#names + 1] = name end
    end
    return names
end

-- The note for those names, or nil
local function localsNote(code)
    local names = topLocals(code)
    if #names == 0 then return nil end
    if #names == 1 then
        return "note: " .. names[1] .. " was local to this call and is gone; make it global, or keep() it"
    end
    return "note: " .. table.concat(names, ", ") .. " were local to this call and are gone; make them global, or keep() them"
end

local function runLua(code)
    local out = {}
    local realPrint = print
    printed = out
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
    flushPartial()
    print, printed = realPrint, nil
    if ok then
        for i = 2, results.n do out[#out + 1] = "-> " .. show(results[i]) end
    else
        if err == "Terminated" then error(err, 0) end
        out[#out + 1] = "error: " .. tostring(err)
    end
    local all = table.concat(out, "\n")
    if all == "" then all = "(no output)" end
    all = clip(all)
    local note = ok and localsNote(code)
    if note then all = all .. "\n" .. note end
    return all, not ok
end

-- The liquids the status line names, by block, in the order it names them,
-- and the sides it looks at, with the inspect for each
local LIQUIDS = { ["minecraft:lava"] = "lava", ["minecraft:water"] = "water" }
local LIQUID_ORDER = { "lava", "water" }
local LOOKS = { { "below", "inspectDown" }, { "ahead", "inspect" }, { "above", "inspectUp" } }

-- The line that ends each lua result: where the turtle is, its fuel and
-- what the call used of it (fuelBefore: the level before), the free
-- slots, and lava or water beside it:
-- "[at 1,0,2 facing 1, fuel 997 (-3), 14 slots free; lava below/ahead]".
-- A fault in it is said in its place; Ctrl+T still stops claude.
local function statusLine(fuelBefore)
    local ok, line = pcall(function()
        local fuel = turtle.getFuelLevel()
        local used = ""
        if type(fuel) == "number" and type(fuelBefore) == "number" then
            local d = fuel - fuelBefore
            used = d > 0 and string.format(" (+%d)", d) or string.format(" (-%d)", -d)
        end
        local free = 0
        for s = 1, 16 do
            if turtle.getItemCount(s) == 0 then free = free + 1 end
        end
        local sides = {}                -- liquid -> the sides it is on
        for _, look in ipairs(LOOKS) do
            local seen, data = turtle[look[2]]()
            local liquid = seen and type(data) == "table" and LIQUIDS[data.name]
            if liquid then
                sides[liquid] = sides[liquid] or {}
                table.insert(sides[liquid], look[1])
            end
        end
        local wet = {}
        for _, liquid in ipairs(LIQUID_ORDER) do
            if sides[liquid] then wet[#wet + 1] = liquid .. " " .. table.concat(sides[liquid], "/") end
        end
        return string.format("[at %d,%d,%d facing %d, fuel %s%s, %d slots free%s]", T.pos.x, T.pos.y, T.pos.z, T.dir,
            tostring(fuel), used, free, #wet > 0 and "; " .. table.concat(wet, ", ") or "")
    end)
    if ok then return line end
    if line == "Terminated" then error(line, 0) end
    return "[status: " .. tostring(line) .. "]"
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
    -- the protected areas within NEAR_AREAS blocks of the turtle (the distance to the box: 0 inside it)
    local areas, near = T.protections(), {}
    for _, a in ipairs(areas) do
        local gap = 0
        for _, axis in ipairs({ "x", "y", "z" }) do
            local lo, hi = a[axis .. "1"], a[axis .. "2"]
            gap = gap + math.max(0, lo - T.pos[axis], T.pos[axis] - hi)
        end
        if gap <= NEAR_AREAS then
            near[#near + 1] = string.format("%s (%d,%d,%d to %d,%d,%d)%s", a.name, a.x1, a.y1, a.z1, a.x2, a.y2, a.z2,
                gap == 0 and " - the turtle is inside it" or "")
        end
    end
    if #areas > 0 then
        lines[#lines + 1] = "protected areas near: " .. (#near > 0 and table.concat(near, ", ")
            or string.format("none within %d blocks (%d elsewhere: T.protections())", NEAR_AREAS, #areas))
    end
    -- the world origin when it is set, and the job journal's step when a job is on
    local origin = T.origin()
    if origin then
        lines[#lines + 1] = string.format("world origin: the turtle's 0,0,0 is %d,%d,%d and its +z points %s%s", origin.x, origin.y, origin.z,
            origin.facing, origin.aligned == false and " (the map is unaligned)" or "")
    end
    if fs.exists(T.dataPath(".job")) then
        local goal = T.job.resume()
        if goal then lines[#lines + 1] = "job: " .. goal.goal .. " - " .. T.job.status() end
    end
    local job = T.loadMineJob()
    if job then
        lines[#lines + 1] = string.format("mine job under way: %d wide, %d high, %s long, spacing %d, %s",
            job.width, job.height, job.length and tostring(job.length) or "no end", job.spacing, job.state)
            .. (job.stale and job.state ~= "stale" and " (stale: saved in another frame)" or "")
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

-- The chat tool: say input.text in the game's chat (T.report.now), or
-- with input.ask ask it there (T.report.ask) while the prompt waits for a
-- line at the keyboard, and take whichever answer comes first.  The chat
-- box is equipped for the whole wait, if it isn't attached, so a keyboard
-- answer still puts back what it took off.  No answer in time is a
-- normal result.
local function chatTool(input)
    local said = tostring(input.text or "")
    if said == "" then return "Nothing to say: give the text.", true end
    if not input.ask then
        say("yellow", "Claude says in chat: " .. convert.fromUTF8(said))
        log("chat: " .. said)
        local ok, why = T.report.now(said, { plain = true })
        if ok then return "said in chat" end
        return "not said in chat: " .. tostring(why), true
    end
    local ttl = CACHE_SECONDS[opts.cache or "5m"]
    local timeout = tonumber(input.timeout_s) or (ttl - CACHE_MARGIN)
    say("yellow", "Claude asks in chat (or answer here): " .. convert.fromUTF8(said))
    log("chat, asking: " .. said)
    local answer, from, failed
    local function byChat()
        local a, who = T.report.ask(said, { prefix = CHAT_PREFIX, timeout = timeout, remind = CHAT_REMIND })
        if a then answer, from = a, tostring(who) .. " answered in chat" else failed = who end
    end
    local function byKeyboard()
        answer = ask("> ")
        from = "answered at the keyboard"
    end
    local function wait()
        if parallel then parallel.waitForAny(byChat, byKeyboard) else byChat() end
    end
    local started = now()
    if require("mc").new().has.hears then
        wait()
    else
        local ok, why = T.withPeripheral(CHAT_BOX, wait)
        if not ok then failed = why end
    end
    local waited = now() - started
    -- (past the cache's time, the next call writes the conversation to it again)
    local cost = waited >= ttl and string.format(" (that was longer than the cache keeps the conversation, %s: the next call writes it to the cache again)",
        CACHE_TTLS[opts.cache or "5m"]) or ""
    if answer then
        if from ~= "answered at the keyboard" then say("yellow", "(" .. from .. ": " .. convert.fromUTF8(answer) .. ")") end
        log("chat, " .. from .. ": " .. answer)
        return from .. ": " .. answer .. cost
    end
    if text.startsWith(tostring(failed), "no answer in") then
        say("orange", "(" .. failed .. ")")
        log("chat: " .. failed)
        if tonumber(input.timeout_s) then return failed .. cost end
        return string.format("%s (the wait stops short of the cache's %s; a longer timeout_s waits longer, and then the next call writes the conversation to the cache again)",
            failed, CACHE_TTLS[opts.cache or "5m"])
    end
    return "couldn't ask in chat: " .. tostring(failed) .. " (ask_user asks at the keyboard alone)", true
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
    local file = findFile("help/" .. name .. ".txt")
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
    T.claim()                           -- (the program loaded a turtlelib of its own: the wrapped turtle API is ours again)
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
        -- (--confirm asks of every call; review = true, of the model's choosing, of this one)
        if CONFIRM or input.review == true then
            local a = ask(input.review == true and "Claude asks you to review this. Run it? [y/N] " or "Run it? [y/N] ")
            if not text.startsWith(a:lower(), "y") then
                say("orange", "--- not run")
                log("not run: declined")
                if input.review == true then return "not run: declined" end
                return "The user declined to run this code.", true
            end
        end
        say("lightBlue", "---")
        -- what the code prints, in grey, apart from what Claude says
        if COLOUR then term.setTextColour(colours.lightGrey) end
        local fuelBefore = turtle.getFuelLevel()
        local ok, out, isErr = pcall(runLua, code)
        if COLOUR then term.setTextColour(colours.white) end
        if not ok then error(out, 0) end        -- Terminated
        if isErr then
            -- the line from "error: " on, else all of it
            local from = text.find(out, "error: ")
            say("red", from and (text.cut(out:sub(from), "\n")) or out)
        end
        -- (for the model and the log; the screen has seen it happen)
        out = out .. "\n" .. statusLine(fuelBefore)
        log((isErr and "error:\n" or "result:\n") .. out)
        return out, isErr
    elseif name == "status" then
        -- (a fault in it goes to the model, not out of claude; Ctrl+T still stops it)
        local ok, out = pcall(status)
        if ok then return out end
        if out == "Terminated" then error(out, 0) end
        say("red", tostring(out))
        log("error:\nstatus: " .. tostring(out))
        return "status failed: " .. tostring(out), true
    elseif name == "run_program" then
        return runProgram(input)
    elseif name == "ask_user" then
        return askUser(input.question)
    elseif name == "chat" then
        return chatTool(input)
    elseif name == "memory" then
        return memory(input)
    end
    return "No such tool: " .. tostring(name), true
end

--------------------------------------------------------------------------
-- What's new since the version the model last ran with
--------------------------------------------------------------------------
-- The ccnix version in use, as `ccnix version` tells it: what this boot
-- read (ccnix.version: the updates' deploy/version, else the ROM's), else
-- the first line of deploy/version where ccnix's files are; nil if none.
local function ccnixVersion()
    local v = ccnix and ccnix.version
    if v == nil or v == "unversioned" then
        local file = findFile("deploy/version")
        v = file and text.trim((text.cut(fileio.read(file) or "", "\n")))
    end
    if v == nil or v == "" or v == "unversioned" then return nil end
    return v
end

-- A version's numbers ("0.51.0" -> { 0, 51, 0 }; what isn't a number counts as 0)
local function versionParts(v)
    local parts = {}
    for _, p in ipairs(text.split(v, ".")) do parts[#parts + 1] = convert.toInteger(p) or 0 end
    return parts
end

-- Is version a later than version b?
local function isLater(a, b)
    local pa, pb = versionParts(a), versionParts(b)
    for i = 1, math.max(#pa, #pb) do
        local x, y = pa[i] or 0, pb[i] or 0
        if x ~= y then return x > y end
    end
    return false
end

-- The news file's lines for the versions after `from` up to `to`, newest
-- first.  The file has a "== 0.51.0" heading a version, newest first,
-- and short lines under each; lines before the first heading, blank ones
-- and ones starting "--" are for people.  With no `from` (the model's
-- first run with this), only the newest version's lines up to `to`.
local function newsLines(news, from, to)
    local out, version, taken = {}, nil, 0
    for _, line in ipairs(text.lines(news)) do
        local l = text.trim(line)
        local heading = text.stripPrefix(l, "== ")
        if heading then
            version = text.trim(heading)
            local wanted = not isLater(version, to) and (from == nil and taken == 0 or from ~= nil and isLater(version, from))
            if wanted then taken = taken + 1 else version = nil end
        elseif version and l ~= "" and not text.startsWith(l, "--") then
            out[#out + 1] = "- " .. l
        end
    end
    return out
end

-- The version to write to VERSION_FILE once the model has had the news
local newVersion

-- The note on what changed since the version the model last ran with,
-- or nil (the same version, no news, nothing in it for these versions).
local function whatsNew()
    local current = ccnixVersion()
    if not current then return nil end
    local last = fileio.read(VERSION_FILE)
    last = last and text.trim((text.cut(last, "\n")))
    if last == "" then last = nil end
    if last == current then return nil end
    newVersion = current
    local file = findFile(NEWS)
    local lines = newsLines(file and fileio.read(file) or "", last, current)
    if #lines == 0 then return nil end
    return string.format("ccnix was updated from %s to %s; what changed for you:\n%s", last or "an earlier version", current,
        table.concat(lines, "\n"))
end

-- Keep the version the model has had the news for.
local function keepVersion()
    if not newVersion then return end
    fs.makeDir(WRITE_DIR)
    fileio.write(VERSION_FILE, newVersion .. "\n")
    log("version: " .. newVersion .. " kept in /" .. VERSION_FILE)
    newVersion = nil
end

--------------------------------------------------------------------------
-- The chat listener (ADR-0012 D3): the wait for the model's reply is most
-- of a step's time, so the chat box goes on the free side for it and the
-- chat is heard; what was on that side (the pickaxe) is back before the
-- model's code runs.  What's said while the code runs is missed: the chat
-- box keeps no history.  A side with an upgrade that isn't a tool (the
-- chunk controller, a modem, the scanner) is never used.
--------------------------------------------------------------------------
-- (one table, not locals: claude.lua is near CC's 200 locals)
local listen = {
    on = T.setting("claude.listen", true,
        "claude: hear the chat while the model thinks (a chat box aboard goes on the free side meanwhile)") ~= false,
    max = 20,           -- chat messages kept for the next results; the rest only counted
    heard = {},         -- for the next results: what was heard, and why the listener was off
    left = 0,           -- messages heard past max, only counted
    told = {},          -- the reasons the listener was off, each told to the model once
}

-- lib/mc on the chat box it hears through, and the function that puts
-- back what was on the side; or nil and why not (nil alone when it's off
-- by the setting, or there's no parallel: not CC)
function listen.chatBox()
    if not (listen.on and parallel) then return nil end
    local mc = require("mc")
    local here = mc.new()
    if here.has.hears then return here, function() return true end end
    local box, restore = T.equipPeripheral(CHAT_BOX, { free = true })
    if not box then return nil, restore end
    return mc.new({ chatBox = box }), restore
end

-- Hear the chat (the setting turtle.player's, or everyone's when it isn't set) until stopped.
function listen.hear(chat)
    local who = settings and settings.get("turtle.player") or ""
    while true do
        local e = chat.event(os.pullEvent("chat"))
        if e and (who == "" or text.equalFold(tostring(e.player), who)) then
            local line = string.format("%s said in chat: %s (at %s UTC)", tostring(e.player), tostring(e.text),
                os.date("!%H:%M:%S", now()))
            say("yellow", "(" .. convert.fromUTF8(line) .. ")")
            log("heard: " .. line)
            if #listen.heard < listen.max then listen.heard[#listen.heard + 1] = line else listen.left = listen.left + 1 end
        end
    end
end

-- fn() (the request), with the chat heard meanwhile when the listener can
-- be on; why it's off is told to the model once
function listen.around(fn)
    local chat, why = listen.chatBox()
    if not chat then
        if why and not listen.told[why] then
            listen.told[why] = true
            listen.heard[#listen.heard + 1] = "The chat listener is off (" .. why .. "): what the player says in chat while you think isn't heard."
            log("listener off: " .. why)
        end
        return fn()
    end
    local out
    local ok, err = pcall(parallel.waitForAny, function() out = table.pack(fn()) end, function() listen.hear(chat) end)
    local back, notBack = why()
    if not back then
        listen.heard[#listen.heard + 1] = "After listening to the chat: " .. tostring(notBack)
        log("listener: " .. tostring(notBack))
    end
    if not ok then error(err, 0) end
    return table.unpack(out, 1, out.n)
end

-- What was heard since it was last taken, as text for the model, or nil
function listen.take()
    if listen.left > 0 then listen.heard[#listen.heard + 1] = listen.left .. " more chat messages were heard and not kept." end
    local said = #listen.heard > 0 and table.concat(listen.heard, "\n") or nil
    listen.heard, listen.left = {}, 0
    return said
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

-- Once the API has said the conversation is too long, the clear is the
-- harder one for the rest of the conversation (/new starts it again)
local hardClear = false

-- The context edits: old thinking first (the API wants that edit listed
-- before the others), then the old tool calls, their code and results
-- both, the memory tool's kept.
local function contextEdits()
    local trigger, keep, atLeast = CLEAR_TRIGGER, KEEP_TOOL_USES, CLEAR_AT_LEAST
    if hardClear then trigger, keep, atLeast = HARD_TRIGGER, HARD_KEEP, HARD_AT_LEAST end
    return { edits = {
        { type = "clear_thinking_20251015", keep = { type = "thinking_turns", value = THINKING_TURNS } },
        {
            type = "clear_tool_uses_20250919",
            trigger = { type = "input_tokens", value = trigger },
            keep = { type = "tool_uses", value = keep },
            clear_at_least = { type = "input_tokens", value = atLeast },
            clear_tool_inputs = true,
            exclude_tools = { "memory" },
        },
    } }
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
        -- a long session's old tool calls and thinking are cleared
        -- server-side (the newest kept, the memory tool's never), so each
        -- round trip doesn't carry all of them (see the API docs: context
        -- editing)
        context_management = contextEdits(),
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
    for attempt = 1, RETRIES + 2 do         -- (one more for the harder clear)
        local h, err, failed = http.post({ url = API_URL, headers = HEADERS, body = body(), timeout = HTTP_TIMEOUT })
        local code, got
        if h then
            code, got = h.getResponseCode(), h.readAll()
            h.close()
        elseif failed then
            code, got = failed.getResponseCode(), failed.readAll()
            if failed.close then failed.close() end
        end
        local detail, again, tooLong
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
                -- (the conversation has outgrown the model's context)
                tooLong = code == 400 and e and e.error and e.error.type == "invalid_request_error"
                    and text.contains(tostring(e.error.message), "prompt is too long")
            end
            again = (not code) or RETRY_CODES[code] == true
        end
        if tooLong and not hardClear then
            -- once, at once: the same conversation with more of it cleared
            hardClear = true
            say("orange", "API: the conversation is too long; trying again with more of it cleared.")
            log(string.format("API: %s; trying again with a harder clear (from %d tokens, the last %d tool uses kept)",
                detail, HARD_TRIGGER, HARD_KEEP))
        elseif not again or attempt > RETRIES then
            local failure = string.format("API request failed%s: %s", code and code ~= 200 and (" (HTTP " .. code .. ")") or "", detail)
            log(failure)
            return nil, failure
        else
            say("orange", string.format("API: %s; trying again in %ds.", detail, wait))
            log(string.format("API: %s; trying again in %ds", detail, wait))
            sleep(wait)
            wait = wait * 2
        end
    end
end

-- Counted, and logged with how long the round trip took (`took`, seconds),
-- so the log shows where the tokens went and when the cache was written
-- again (a long gap before a call, then many tokens written)
local function count(reply, took)
    local u = reply.usage or {}
    usage.input = usage.input + (u.input_tokens or 0)
    usage.output = usage.output + (u.output_tokens or 0)
    usage.written = usage.written + (u.cache_creation_input_tokens or 0)
    usage.cached = usage.cached + (u.cache_read_input_tokens or 0)
    local thought = (u.output_tokens_details or {}).thinking_tokens
    log(string.format("tokens: %d in (%d from the cache, %d written to it, %d new), %d out%s; %ds",
        (u.input_tokens or 0) + (u.cache_creation_input_tokens or 0) + (u.cache_read_input_tokens or 0),
        u.cache_read_input_tokens or 0, u.cache_creation_input_tokens or 0, u.input_tokens or 0,
        u.output_tokens or 0, thought and string.format(" (%d thinking)", thought) or "", took))
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

-- A line for after the tool results when the player hasn't been told
-- anything in chat (T.report, T.report.ask, the chat tool) for
-- claude.remindChat minutes, counted from `since` (the goal's start, or
-- the last reminder) or the last message, whichever is later; or nil.
local function chatReminder(since)
    if REMIND_CHAT <= 0 or now() - since < REMIND_CHAT * 60 then return nil end
    local quiet = now() - math.max(since, T.report.lastTold() or 0)
    if quiet < REMIND_CHAT * 60 then return nil end
    return string.format("%d minutes without a word to the player in chat: tell them how it is going (the chat tool, or T.report).",
        math.floor(quiet / 60))
end

-- Work at `goal` until the model stops: run its tool calls and send the
-- results back, call after call, up to MAX_STEPS of them.
local startNotes = {}   -- what the model is told with its next goal: helpers that failed to load, a new conversation
-- The log's line for each kind of context edit the API applied, from the
-- fields it reports (another kind: its type, and the tokens it freed)
local EDIT_LINES = {
    clear_thinking_20251015 = function(e)
        return string.format("context: old thinking cleared (%d turns, %d tokens)",
            e.cleared_thinking_turns or 0, e.cleared_input_tokens or 0)
    end,
    clear_tool_uses_20250919 = function(e)
        return string.format("context: %d old tool results cleared (%d tokens)",
            e.cleared_tool_uses or 0, e.cleared_input_tokens or 0)
    end,
}
local function editLine(e)
    local line = EDIT_LINES[e.type]
    if line then return line(e) end
    return string.format("context: %s (%d tokens)", tostring(e.type), e.cleared_input_tokens or 0)
end
-- The last `context:` line logged for each kind of edit: the API reports
-- the same clear on every call after it, so a line is logged when it
-- differs from its own kind's last one
local lastCleared = {}
local function converse(goal)
    startNotes[#startNotes + 1] = listen.take()     -- (chat heard since the last reply)
    local said = #startNotes > 0 and goal .. "\n\n[" .. table.concat(startNotes, "]\n[") .. "]" or goal
    addUser(said, "Not run: the goal ended before this call was answered.")
    log("goal: " .. goal)
    local steps, overBudget, cutOff, pauses = 0, false, false, 0
    local quietSince = now()             -- (the goal's start, then each reminder: the player's last word is T.report's)
    while true do
        local started = now()
        local reply, err = listen.around(request)
        if not reply then
            say("red", err)
            -- a goal it never answered goes; tool results stay, for the
            -- next goal to go on from
            local last = messages[#messages]
            if last.role == "user" and last.content == said then messages[#messages] = nil end
            return false
        end
        count(reply, now() - started)
        startNotes = {}
        keepVersion()
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
        -- (logged when it differs from the last one of its kind: a clear
        -- stays applied, and is reported again, on every call until a
        -- bigger one)
        for _, edit in ipairs((reply.context_management or {}).applied_edits or {}) do
            local line = editLine(edit)
            if line ~= lastCleared[edit.type] then log(line); lastCleared[edit.type] = line end
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
            local heardNote = listen.take()
            if heardNote then results[#results + 1] = { type = "text", text = heardNote } end
            if steps >= MAX_STEPS and not overBudget then
                overBudget = true
                results[#results + 1] = { type = "text",
                    text = string.format("That was tool call %d of the %d allowed for this goal: stop here and say what you did.", steps, MAX_STEPS) }
            end
            local quiet = chatReminder(quietSince)
            if quiet then
                quietSince = now()
                results[#results + 1] = { type = "text", text = quiet }
                log("reminded: " .. quiet)
            end
            messages[#messages + 1] = { role = "user", content = results }
        elseif reply.stop_reason == "max_tokens" and not cutOff then
            cutOff = true
            say("orange", "(the reply was cut off; asking it to carry on)")
            local heardNote = listen.take()
            addUser("Your reply was cut off; carry on, more briefly." .. (heardNote and "\n\n" .. heardNote or ""),
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
-- /new at the prompt: the conversation emptied, the helpers loaded again
-- (what's on disk, the memory and the files, carries over)
local NEW = "/new"
local function newConversation()
    for i = #messages, 1, -1 do messages[i] = nil end
    hardClear, lastCleared, startNotes = false, {}, {}
    startNotes[1] = "This is a new conversation: the one before it was put aside. Your memory and your files are as they were."
    local failed = loadHelpers()
    if failed then say("red", failed); startNotes[2] = failed end
    say("yellow", "A new conversation: the old one is put aside (the memory and the files stay); the helpers are loaded again.")
    log("new conversation")
end

local function main()
    if not takeSavedPos() then T.startAtHome(true) end
    -- (a session climbs further than a program: the helpers or the model may set it otherwise)
    T.cfg.maxHeight = MAX_HEIGHT
    say("yellow", string.format("Claude at the controls (%s, effort %s). Turtle at %s facing %d, fuel %s.",
        MODEL, EFFORT, T.posString(), T.dir, tostring(turtle.getFuelLevel())))
    -- the options as given, and what they came to
    local given = {}
    for _, k in ipairs({ "model", "effort", "steps", "cache" }) do
        if opts[k] then given[#given + 1] = "--" .. k .. " " .. opts[k] end
    end
    if CONFIRM then given[#given + 1] = "--confirm" end
    resume.given = table.concat(given, " ")
    log(string.format("start: claude%s (model %s, effort %s, steps %d, cache %s%s; at %s facing %d, fuel %s)",
        #given > 0 and " " .. table.concat(given, " ") or "", MODEL, EFFORT, MAX_STEPS, opts.cache or "5m",
        CONFIRM and ", confirming each call" or "", T.posString(), T.dir, tostring(turtle.getFuelLevel())))
    local failed = loadHelpers()
    if failed then say("red", failed); startNotes[#startNotes + 1] = failed end
    local news = whatsNew()
    if news then
        say("yellow", (text.cut(news, ";")) .. ": Claude is told what changed.")
        log("news: " .. news)
        startNotes[#startNotes + 1] = news
    end
    if opts.resume and not resume.goal then say("yellow", "Nothing to resume: /" .. resume.file .. " isn't there.") end
    if goal == "" then
        goal = ask("Goal: ")
    end
    while goal ~= "" do
        if text.trim(goal) == NEW then
            newConversation()
            goal = ask("Goal: ")
        else
            -- (a resumed goal is kept as the file had it, not as the model was told it)
            fs.makeDir(WRITE_DIR)
            fileio.write(resume.file, resume.prefix .. " " .. resume.given .. "\n" .. (resume.goal or goal) .. "\n")
            resume.goal = nil
            local before = tables.copy(usage)
            converse(goal)
            local line = tokenLine(before)
            say("grey", line)
            log("goal done: " .. line)
            fs.delete(resume.file)
            goal = ask("> ")
        end
    end
end

local ok, err = pcall(T.run, main)
print = screenPrint
-- (Ctrl+T is the player's stop: not a goal to resume at the next boot)
if err == "Terminated" and fs.exists(resume.file) then fs.delete(resume.file) end
if not ok then error(err, 0) end
