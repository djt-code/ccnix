-- sim/claude_drive.lua
--
-- claude.lua against a scripted API: the "model" is a list of canned
-- replies, so the loop, the tool results it sends back, the Lua sandbox,
-- retries, refusals, the step budget, --confirm and the key check are all
-- checked without a network or a token spent.  The world is the mine's
-- rock.
local PROJ = ...
package.path = PROJ .. "/turtle/?.lua;" .. PROJ .. "/lib/?.lua;" .. PROJ .. "/sim/lib/?.lua;" .. package.path
local M = require("mock")
local Mine = require("mineworld")
local P = Mine.P
local check = Mine.check

textutils = M.textutilsApi()
-- A clock that stands still unless a scenario moves it (a run's "took N s"
-- is then the same on every run of the simulator)
local STILL = os.time()
local clockWas = os.time
os.time = function(t) if t ~= nil then return clockWas(t) end return STILL end
local HTTP = M.httpApi()
http = HTTP.api
local answers = M.consoleApi(Mine, {})
-- (the prompt reads with CraftOS read() here, the scripted answers: lib/readline's keys at it are sim/claude_prompt.lua's)
package.loaded.readline = "sim: read() answers the prompts"
local run = M.runner(Mine, PROJ .. "/turtle/claude.lua", {
    stats = function() return "moves: " .. Mine.moves .. ", turns: " .. Mine.turns .. ", API calls: " .. #HTTP.requests end,
    -- (Ctrl+T, as scenario 17 stops it)
    stopped = function(err) if tostring(err) == "Terminated" then return "stopped (Terminated)" end end,
})

-- Canned replies, as the API sends them.
local ids = 0
local function toolUse(name, input)
    ids = ids + 1
    return { type = "tool_use", id = "toolu_" .. ids, name = name, input = input }
end
local function text(s) return { type = "text", text = s } end
local function reply(blocks, stop, extra)
    local r = { id = "msg_1", type = "message", role = "assistant", model = "claude-opus-5-5",
                content = blocks, stop_reason = stop or "end_turn",
                usage = { input_tokens = 100, output_tokens = 20, cache_read_input_tokens = 50,
                          cache_creation_input_tokens = 25 } }
    for k, v in pairs(extra or {}) do r[k] = v end
    return { code = 200, body = r }
end
local function thinking() return { type = "thinking", thinking = "", signature = "sig" } end

-- The tool results in the user turn of request n: { [tool_use_id] = block }.
-- A lua result's last line, the status line ("[at 0,0,2 facing 0, ...]"),
-- is taken off its content and kept as the block's .status, so the checks
-- on what the code said read it alone (scenario 30 checks the line).
local function withoutStatus(b)
    if type(b.content) ~= "string" then return b end
    local cut = b.content:find("\n%[at %-?%d+,%-?%d+,%-?%d+ facing [^\n]*%]$") or b.content:find("\n%[status: [^\n]*%]$")
    if not cut then return b end
    local copy = {}
    for k, v in pairs(b) do copy[k] = v end
    copy.content, copy.status = b.content:sub(1, cut - 1), b.content:sub(cut + 1)
    return copy
end
local function resultsIn(n)
    local req = HTTP.requests[n]
    if not req then return {}, { content = {} } end
    local msgs = req.body.messages
    local last = msgs[#msgs]
    local out = {}
    if type(last.content) == "table" then
        for _, b in ipairs(last.content) do
            if b.type == "tool_result" then out[b.tool_use_id] = withoutStatus(b) end
        end
    end
    return out, last
end

local function repoFile(rel)
    local f = assert(io.open(PROJ .. "/" .. rel, "rb"))
    local data = f:read("a")
    f:close()
    return data
end
REAL_INDEX, REAL_MANUAL = repoFile("turtle/tl/index.txt"), repoFile("help/turtlelib.txt")

local function fresh(answersList)
    Mine.setup(Mine.stock(0, 0))
    Mine.startAt()
    -- (turtlelib's index and reference are on the computer, as setup puts them)
    Mine.inv, Mine.files = {}, { ["claude.key"] = "sk-test-key\n", ["turtle/tl/index.txt"] = REAL_INDEX,
                                 ["help/turtlelib.txt"] = REAL_MANUAL }
    HTTP.queue, HTTP.requests, ids = {}, {}, 0
    for i = #answers, 1, -1 do answers[i] = nil end
    for _, a in ipairs(answersList or {}) do answers[#answers + 1] = a end
    EQ = { right = "minecraft:diamond_pickaxe" }
    FUEL, DIGS = 1000, 0
end

-- 1. a goal that takes a status call and one piece of code: the request
--    is well formed, the results go back, the turtle ends where the code
--    put it, and the final note is printed
fresh({ "" })
HTTP.queue = {
    reply({ thinking(), text("Let me look first."), toolUse("status", {}) }, "tool_use"),
    reply({ thinking(), toolUse("lua", { code = [[
for _ = 1, 2 do turtle.dig(); T.forward() end
T.turnRight(); turtle.dig(); T.forward()
print("moved")
return T.posString(), T.dir]] }) }, "tool_use"),
    reply({ text("Done: the turtle is at (1,0,2) facing +x.") }, "end_turn"),
}
run("go", "two", "forward", "and", "one", "right")
local r1 = HTTP.requests[1]
check("posted to the Messages API with the key and version headers",
    r1 and r1.url == "https://api.anthropic.com/v1/messages" and r1.headers["x-api-key"] == "sk-test-key"
        and r1.headers["anthropic-version"] ~= nil, r1 and tostring(r1.url))
local toolNames = {}
for i, t in ipairs(r1 and r1.body.tools or {}) do toolNames[i] = t.name .. (t.type and ("=" .. t.type) or "") end
check("the request names the model, effort, cached system prompt and the tools: its own five, memory, web search and fetch",
    r1 and r1.body.model == "claude-opus-5-5" and r1.body.output_config.effort == "medium"
        and r1.body.system[1].cache_control.type == "ephemeral"
        and table.concat(toolNames, " ") == "lua status run_program ask_user chat memory=memory_20250818 "
            .. "web_search=web_search_20260209 web_fetch=web_fetch_20260209"
        and r1.body.tools[1].input_schema.required[1] == "code", table.concat(toolNames, " "))
local edits1 = r1 and r1.body.context_management.edits or {}
check("a short conversation keeps all its thinking and every tool call (ADR-0013 D1: scenario 42 has the clear), with the beta header for it",
    #edits1 == 1 and edits1[1].type == "clear_thinking_20251015" and edits1[1].keep == "all"
        and r1.headers["anthropic-beta"]:find("context-management-2025-06-27", 1, true)
        and r1.headers["anthropic-beta"]:find("server-side-fallback-2026-07-01", 1, true), textutils.serialiseJSON(edits1))
check("the system prompt tells it of ccnix's libraries, whole (a [[:alpha:]] in it doesn't end it)",
    r1 and r1.body.system[1].text:find('require("text")', 1, true) and r1.body.system[1].text:find("[[:alpha:]]", 1, true)
        and r1.body.system[1].text:find("say plainly if something failed.", 1, true))
check("the goal is the first user message", r1 and r1.body.messages[1].role == "user"
    and r1.body.messages[1].content == "go two forward and one right")
local res2 = resultsIn(2)
check("status went back as a tool result with the turtle's position",
    res2.toolu_1 and tostring(res2.toolu_1.content):find("at %(0,0,0%) facing 0") and res2.toolu_1.is_error == nil,
    res2.toolu_1 and res2.toolu_1.content)
check("the assistant turn went back as it came (thinking block included)",
    HTTP.requests[2].body.messages[2].role == "assistant" and HTTP.requests[2].body.messages[2].content[1].type == "thinking"
        and HTTP.requests[2].body.messages[2].content[1].signature == "sig")
local res3 = resultsIn(3)
check("the code's print and return values came back",
    res3.toolu_2 and res3.toolu_2.content == "moved\n-> (1,0,2)\n-> 1", res3.toolu_2 and res3.toolu_2.content)
check("the turtle moved as the code said", P.x == 1 and P.y == 0 and P.z == 2 and P.d == 1, string.format("(%d,%d,%d) facing %d", P.x, P.y, P.z, P.d))
check("three API calls, then it stopped at end_turn and waited for the next goal", #HTTP.requests == 3)
check("the final note was printed", Mine.logHas("^Done: the turtle is at"))
check("the conversation is cached too (the top-level mark), for the API's default 5 minutes",
    r1 and r1.body.cache_control and r1.body.cache_control.type == "ephemeral" and r1.body.cache_control.ttl == nil
        and r1.body.system[1].cache_control.ttl == nil)
check("the token totals were printed, cache reads and writes counted in",
    Mine.logHas("^%[525 tokens in: 150 from the cache, 75 written to it, 300 new; 60 out; 585 in all%]"))
check("the code was logged to claude.log", (Mine.files["claude.log"] or ""):find("T.turnRight") ~= nil)
-- The log's entries: each starting with its time; the session's start, each
-- call's tokens and how long it took, and the goal's in all.
local logText = Mine.files["claude.log"] or ""
local STAMP = "%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d "
local _, calls = logText:gsub("\n" .. STAMP .. "tokens: 175 in %(50 from the cache, 25 written to it, 100 new%), 20 out; %d+s\n", "")
check("claude.log: each entry starts with its time, the first with the session's options",
    logText:find("^" .. STAMP .. "start: claude %(model claude%-opus%-5%-5, effort medium, steps 60, cache 5m; at %(0,0,0%) facing 0, fuel 1000%)\n")
        and logText:find("\n" .. STAMP .. "goal: go two forward and one right\n"), logText:sub(1, 200))
check("claude.log: each call's tokens (from the cache, written, new, out) and how long it took", calls == 3, calls)
check("claude.log: the goal's tokens in all when it's done",
    logText:find("\n" .. STAMP .. "goal done: %[525 tokens in: 150 from the cache, 75 written to it, 300 new; 60 out; 585 in all%]\n"))

-- 2. the sandbox: fs is out of reach, a syntax error and a runtime error
--    come back as error results, tables are serialised, definitions
--    persist between calls
fresh({ "" })
HTTP.queue = {
    reply({ toolUse("lua", { code = "return http == _ENV.http and http ~= nil, shell" }) }, "tool_use"),
    reply({ toolUse("lua", { code = "return (" }) }, "tool_use"),
    reply({ toolUse("lua", { code = "function twice(n) return 2 * n end; return { a = twice(2) }" }) }, "tool_use"),
    reply({ toolUse("lua", { code = "return twice(5), http ~= nil, shell" }) }, "tool_use"),
    reply({ text("Checked.") }, "end_turn"),
}
run("poke at the sandbox")
local e1 = resultsIn(2).toolu_1
check("CC's http is there, the shell isn't", e1 and e1.content == "-> true\n-> nil", e1 and e1.content)
local e2 = resultsIn(3).toolu_2
check("a syntax error is an error result", e2 and e2.is_error == true and tostring(e2.content):find("syntax"), e2 and e2.content)
local e3 = resultsIn(4).toolu_3
check("a returned table is serialised", e3 and e3.content == "-> {a=4}" and e3.is_error == nil, e3 and e3.content)
local e4 = resultsIn(5).toolu_4
check("a function defined in one call is there in the next, http still there, the shell not",
    e4 and e4.content == "-> 10\n-> true\n-> nil", e4 and e4.content)

-- 3. an overloaded API is retried; a refusal is reported and stops the goal
fresh({ "" })
HTTP.queue = {
    { code = 529, body = { type = "error", error = { type = "overloaded_error", message = "Overloaded" } } },
    { fail = "Could not connect" },
    reply({}, "refusal", { stop_details = { type = "refusal", category = "cyber", explanation = "Not this." } }),
}
run("something it won't do")
check("retried after the 529 and the failed connection", #HTTP.requests == 3 and Mine.logHas("trying again"))
check("the retries are in claude.log too", select(2, (Mine.files["claude.log"] or ""):gsub("; trying again in %d+s\n", "")) == 2)
check("the refusal was reported with its category", Mine.logHas("Claude declined %(cyber%)"))

-- 3b. an error the API won't recover from stops the goal with its message
fresh({ "" })
HTTP.queue = {
    { code = 400, body = { type = "error", error = { type = "invalid_request_error", message = "bad request" } } },
}
run("anything")
check("a 400 isn't retried and its message is shown", #HTTP.requests == 1 and Mine.logHas("HTTP 400.*bad request"))

-- 3c. "prompt is too long": sent again at once with a harder clear (from
--     50k tokens, 2 tool uses kept, whatever it frees), which then stays;
--     a second one is reported as any other error
fresh({ "" })
local TOO_LONG = { code = 400, body = { type = "error", error = { type = "invalid_request_error",
    message = "prompt is too long: 1000123 tokens > 1000000 maximum" } } }
HTTP.queue = {
    reply({ toolUse("lua", { code = "return 1" }) }, "tool_use"),
    TOO_LONG,
    reply({ toolUse("lua", { code = "return 2" }) }, "tool_use"),
    reply({ text("Done.") }, "end_turn"),
}
run("talk a lot")
local function clearOf(n)
    local req = HTTP.requests[n]
    return req and req.body.context_management.edits[2] or {}
end
check("prompt too long: sent again at once (no wait) with the harder clear, the same conversation",
    #HTTP.requests == 4 and clearOf(3).trigger.value == 50000 and clearOf(3).keep.value == 2
        and clearOf(3).clear_at_least.value == 0 and clearOf(2).trigger == nil
        and HTTP.requests[3].body.context_management.edits[1].keep.value == 3
        and #HTTP.requests[3].body.messages == #HTTP.requests[2].body.messages
        and Mine.logHas("too long; trying again with more of it cleared"), textutils.serialiseJSON(clearOf(3)))
check("...the harder clear stays for the conversation's next calls", clearOf(4).trigger.value == 50000)
check("...and the log says so", (Mine.files["claude.log"] or ""):find("prompt is too long: 1000123 tokens > 1000000 maximum; trying again with a harder clear (from 50000 tokens, the last 2 tool uses kept)", 1, true))
fresh({ "" })
HTTP.queue = { TOO_LONG, TOO_LONG }
run("talk even more")
check("too long again with the harder clear: reported as any error, nothing more sent",
    #HTTP.requests == 2 and Mine.logHas("HTTP 400.*prompt is too long"))

-- 4. the step budget: with --steps 2 the third tool call isn't run, and
--    the model is told to stop
fresh({ "" })
HTTP.queue = {
    reply({ toolUse("lua", { code = "turtle.dig(); T.forward(); return 1" }) }, "tool_use"),
    reply({ toolUse("lua", { code = "turtle.dig(); T.forward(); return 2" }) }, "tool_use"),
    reply({ toolUse("lua", { code = "turtle.dig(); T.forward(); return 3" }) }, "tool_use"),
    reply({ text("Stopping.") }, "end_turn"),
}
run("dig forever", "--steps", "2")
local _, budgetTurn = resultsIn(3)
local told = false
for _, b in ipairs(budgetTurn.content) do if b.type == "text" and b.text:find("tool call 2 of the 2") then told = true end end
check("told to stop after the second call", told)
local over = resultsIn(4).toolu_3
check("the third call wasn't run and came back as an error", over and over.is_error == true and tostring(over.content):find("budget"), over and over.content)
check("only two steps were taken", Mine.moves == 2 and P.z == 2, Mine.moves .. " moves")

-- 5. --confirm: the code is shown and run only on a "y"
fresh({ "n", "y", "" })
HTTP.queue = {
    reply({ toolUse("lua", { code = "turtle.dig(); return 'dug'" }) }, "tool_use"),
    reply({ toolUse("lua", { code = "turtle.dig(); return 'dug'" }) }, "tool_use"),
    reply({ text("Done.") }, "end_turn"),
}
run("dig once", "--confirm")
local c1 = resultsIn(2).toolu_1
local c2 = resultsIn(3).toolu_2
check("declined code isn't run and the model is told", c1 and c1.is_error == true and tostring(c1.content):find("declined") and DIGS == 1, c1 and c1.content)
check("accepted code runs", c2 and c2.content == "-> dug", c2 and c2.content)

-- 5b. the options are getopt's (T.options): among the goal's words, which
--     keep a "-2" or a "-x" as they are; --name=word too; one missing its
--     word says so and nothing is sent
fresh({ "" })
HTTP.queue = { reply({ text("Ok.") }, "end_turn") }
run("go", "-2", "blocks", "--model=claude-x", "on", "-x", "--effort", "low")
local g1 = HTTP.requests[1]
check("the goal keeps its words; the options are taken out",
    g1 and g1.body.messages[1].content == "go -2 blocks on -x" and g1.body.model == "claude-x"
        and g1.body.output_config.effort == "low", g1 and g1.body.messages[1].content)
check("claude.log: the options as given, and what they came to",
    (Mine.files["claude.log"] or ""):find("start: claude --model claude-x --effort low (model claude-x, effort low, steps 60, cache 5m;", 1, true),
    (Mine.files["claude.log"] or ""):sub(1, 160))
fresh({ "" })
HTTP.queue = { reply({ text("Ok.") }, "end_turn") }
run("dig", "--model", "sonnet")
local ms = HTTP.requests[1]
check("--model sonnet: the short name sent as the model's id, and logged as both",
    ms and ms.body.model == "claude-sonnet-5-5"
        and (Mine.files["claude.log"] or ""):find("start: claude --model sonnet (model claude-sonnet-5-5,", 1, true),
    ms and ms.body.model)
fresh({ "" })
HTTP.queue = { reply({ text("Ok.") }, "end_turn") }
run("dig", "--model", "haiku")
local mh = HTTP.requests[1]
check("--model haiku: its own id", mh and mh.body.model == "claude-haiku-5-5", mh and mh.body.model)
fresh({ "" })
run("dig", "--steps")
check("an option with no word after it: getopt's message, nothing sent",
    #HTTP.requests == 0 and Mine.logHas("claude: option '%-%-steps' requires an argument"))
fresh({ "" })
HTTP.queue = { reply({ text("Ok.") }, "end_turn") }
run("dig", "--cache", "1h")
local c1 = HTTP.requests[1]
check("--cache 1h: the conversation and the system prompt both cached for an hour",
    c1 and c1.body.cache_control and c1.body.cache_control.ttl == "1h" and c1.body.system[1].cache_control.ttl == "1h")
check("claude.log: --cache 1h among the options",
    (Mine.files["claude.log"] or ""):find("start: claude --cache 1h (model claude-opus-5-5, effort medium, steps 60, cache 1h;", 1, true))
fresh({ "" })
run("dig", "--cache", "15m")
check("--cache 15m: refused (the API has 5m and 1h), nothing sent",
    #HTTP.requests == 0 and Mine.logHas("claude: %-%-cache is 5m or 1h, not 15m"))

-- 6. ask_user hands the question to the keyboard
fresh({ "left", "" })
HTTP.queue = {
    reply({ toolUse("ask_user", { question = "Which way?" }) }, "tool_use"),
    reply({ text("Going left.") }, "end_turn"),
}
run("turn somewhere")
local a1 = resultsIn(2).toolu_1
check("the answer went back", a1 and a1.content == "left", a1 and a1.content)
check("the question was shown", Mine.logHas("Claude asks: Which way%?"))

-- 7. a second goal keeps the conversation
fresh({ "and now back", "" })
HTTP.queue = {
    reply({ text("Ready.") }, "end_turn"),
    reply({ text("Back.") }, "end_turn"),
}
run("say ready")
check("the second goal's request carries the whole conversation",
    #HTTP.requests == 2 and #HTTP.requests[2].body.messages == 3 and HTTP.requests[2].body.messages[3].content == "and now back")

-- 8. no key: says so and does nothing
fresh({})
Mine.files = {}
run("anything")
check("without a key it says where to put one, and calls nothing", Mine.logHas("No API key") and #HTTP.requests == 0)

-- 9. the pager: what's longer than the screen opens in it before the next
--    prompt, at the first line not yet seen; what fits doesn't
package.path = PROJ .. "/lib/?.lua;" .. package.path
local Tm = M.termApi(39, 13)
fresh({ "more please", "" })
local long = {}
for i = 1, 30 do long[i] = "note line " .. i end
HTTP.queue = {
    reply({ text("Ready.") }, "end_turn"),
    reply({ text(table.concat(long, "\n")) }, "end_turn"),
}
local opened = {}
Tm.events = { { "char", "q" }, { "char", "MARK" } }
local pull = os.pullEvent
os.pullEvent = function(...) opened[#opened + 1] = Tm.text(1); return pull(...) end
run("say ready")
os.pullEvent = pull
check("a short reply: no pager at its prompt; a long one opens at its first line",
    #opened == 1 and opened[1] == "note line 1", table.concat(opened, " | "))
check("q gives the prompt back, the next key left for it", Tm.events[1] and Tm.events[1][2] == "MARK")
check("everything still printed as before", Mine.logHas("note line 30") and Mine.logHas("^Ready%.$"))
term, Tm = nil, nil

-- 10. require: CraftOS's cc.* modules (they're tried for real under the
--     ROM; here there's no /rom) and ccnix's libraries, and only those;
--     the libraries see the code's files, not the real ones
fresh({ "" })
Mine.files["notes.txt"] = "a, b ,c"
local REQ_CODES = {
    "return require('turtlelib')",
    "return require('fs')",
    [[local text = require("text"); return table.concat(text.split("a, b ,c", ","), "|")]],
    [[local glob, convert = require("glob"), require("convert"); return glob.match("minecraft:*_ore", "minecraft:iron_ore"), convert.toInteger("ff", 16), convert.duration(3725)]],
    [[local fileio = require("fileio"); return fileio.read("claude.key"), fileio.write("startup.lua", "x"), fileio.read("notes.txt")]],
    [[fs.makeDir("claude"); local fileio = require("fileio"); return fileio.write("claude/f.txt", "kept"), require("text") == require("text")]],
    "return require('json')",
}
HTTP.queue = {}
for i, c in ipairs(REQ_CODES) do HTTP.queue[i] = reply({ toolUse("lua", { code = c }) }, "tool_use") end
HTTP.queue[#REQ_CODES + 1] = reply({ text("Checked.") }, "end_turn")
run("poke at require")
local function reqOut(i) local r = resultsIn(i + 1)["toolu_" .. i]; return r and tostring(r.content) or "", r and r.is_error end
local q1, e1 = reqOut(1)
local q2, e2 = reqOut(2)
check("require of what the code has as a global (turtlelib, fs): an error result saying which global",
    e1 and q1:find("the global T", 1, true) and e2 and q2:find("the global fs", 1, true), q1 .. " / " .. q2)
local q7, e7 = reqOut(7)
check("require of anything else is an error result naming what it can have",
    e7 and q7:find("only these here") and q7:find("cc.strings", 1, true) and q7:find("text", 1, true), q7)
check("ccnix's libraries load in the code: text, glob, convert",
    reqOut(3) == "-> a|b|c" and reqOut(4) == "-> true\n-> 255\n-> 1h 2m 5s", reqOut(3) .. " / " .. reqOut(4))
local f5 = reqOut(5)
check("fileio in the code reads through the code's files: not the key, no writing outside /claude/",
    f5:find("^%-> nil\n%-> nil\n") and f5:find("a, b ,c", 1, true) and Mine.files["startup.lua"] == nil, f5)
check("fileio writes under /claude/; a library is loaded once",
    reqOut(6) == "-> true\n-> true" and Mine.files["claude/f.txt"] == "kept", reqOut(6))

-- 11. the files: anything but the key can be read, only /claude/ written
fresh({ "" })
Mine.files["notes.txt"] = "hello"
Mine.files["startup.lua"] = "shell.run('x')"
local FS_CODES = {
    [[local f = fs.open("notes.txt", "r"); local s = f.readAll(); f.close(); return s]],
    [[return fs.open("claude.key", "r")]],
    [[return fs.open("/./CLAUDE.KEY", "r")]],
    [[return io.open("claude.key")]],
    [[return loadfile("claude.key")]],
    [[return fs.open("startup.lua", "w")]],
    [[return fs.open("claude/../startup.lua", "a")]],
    [[return pcall(fs.delete, "startup.lua")]],
    [[return pcall(fs.copy, "claude.key", "claude/k")]],
    [[return pcall(fs.copy, "/", "claude/all")]],
    [[return pcall(fs.move, "notes.txt", "claude/notes.txt")]],
    [[fs.makeDir("/claude"); local f = fs.open("/claude/map.txt", "w"); f.write("mapped"); f.close(); fs.copy("notes.txt", "claude/n.txt"); return fs.isReadOnly("claude/x"), fs.isReadOnly("startup.lua")]],
}
HTTP.queue = {}
for i, c in ipairs(FS_CODES) do HTTP.queue[i] = reply({ toolUse("lua", { code = c }) }, "tool_use") end
HTTP.queue[#FS_CODES + 1] = reply({ text("Filed.") }, "end_turn")
run("poke at the files")
local function fsOut(i) local r = resultsIn(i + 1)["toolu_" .. i]; return r and tostring(r.content) or "" end
check("any other file can be read", fsOut(1) == "-> hello", fsOut(1))
check("the key can't, through fs, io or loadfile, nor by another spelling",
    fsOut(2):find("API key isn't readable", 1, true) and fsOut(3):find("API key isn't readable", 1, true)
        and fsOut(4):find("API key isn't readable", 1, true) and fsOut(5):find("API key isn't readable", 1, true)
        and not (fsOut(2) .. fsOut(3) .. fsOut(4) .. fsOut(5)):find("sk-test", 1, true), fsOut(3))
check("nothing outside /claude/ can be written, .. or not",
    fsOut(6):find("writable only under /claude/", 1, true) and fsOut(7):find("writable only under /claude/", 1, true)
        and fsOut(8):find("^%-> false") and Mine.files["startup.lua"] == "shell.run('x')", fsOut(7))
check("the key can't be copied out, nor a folder it's in",
    fsOut(9):find("^%-> false") and fsOut(10):find("^%-> false") and Mine.files["claude/k"] == nil, fsOut(10))
check("nor moved out of where it is into /claude/ (only /claude/ files move)",
    fsOut(11):find("^%-> false") and Mine.files["notes.txt"] == "hello", fsOut(11))
check("in /claude/ it can make folders, write and copy in; isReadOnly says which is which",
    Mine.files["claude/map.txt"] == "mapped" and Mine.files["claude/n.txt"] == "hello"
        and fsOut(12) == "-> false\n-> true", fsOut(12))

-- 12. streaming: the request asks for a stream with the thinking
--     summarised (CC's 60 s timeout is for silence, and a stream keeps
--     talking); a stream an overload cuts off is retried
fresh({ "" })
HTTP.queue = {
    { code = 200, body = "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"m\",\"content\":[],\"usage\":{\"input_tokens\":5}}}\n\nevent: error\ndata: {\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"}}\n\n" },
    reply({ { type = "thinking", thinking = "Plan: say hi.", signature = "sig2" }, text("Hi there.") }, "end_turn"),
}
run("say hi")
local s1 = HTTP.requests[1] and HTTP.requests[1].body
check("the request asks for a stream, thinking summarised", s1 and s1.stream == true
    and s1.thinking and s1.thinking.type == "adaptive" and s1.thinking.display == "summarized")
check("an overload partway through the stream is retried", #HTTP.requests == 2 and Mine.logHas("overloaded_error.*trying again"))
check("the reply put back together from its events is printed, the thinking logged",
    Mine.logHas("^Hi there%.$") and (Mine.files["claude.log"] or ""):find("thinking: Plan: say hi.", 1, true) ~= nil)

-- 13. a reply cut off at max_tokens partway through a tool call: the call
--     isn't run, and the next turn answers it (the API wants every
--     tool_use answered in the very next turn) before telling the model it
--     ran out of room while writing (ADR-0013 D4); max_tokens is 64000
fresh({ "" })
HTTP.queue = {
    reply({ text("Digging now."), toolUse("lua", { code = "turtle.dig(" }) }, "max_tokens"),
    reply({ text("Stopped short; nothing was run.") }, "end_turn"),
}
run("dig a lot")
local cutTurn = HTTP.requests[2] and HTTP.requests[2].body.messages[3]
local cr = cutTurn and type(cutTurn.content) == "table" and cutTurn.content
check("a tool call cut off at max_tokens is answered (not run), then told it ran out of room while writing",
    cr and cr[1].type == "tool_result" and cr[1].tool_use_id == "toolu_1" and cr[1].is_error == true
        and cr[2].type == "text"
        and cr[2].text == "Your reply was cut off at the length limit while you were writing: say less and take a smaller step."
        and DIGS == 0, cutTurn and textutils.serialiseJSON(cutTurn))
check("...a reply may be 64000 tokens long", HTTP.requests[1] and HTTP.requests[1].body.max_tokens == 64000,
    HTTP.requests[1] and tostring(HTTP.requests[1].body.max_tokens))

-- 13b. each cut-off is logged with what the reply used (ADR-0013 phase 1);
--      one cut off while thinking is told so (ADR-0013 D4); a second in
--      the same goal ends the goal with that reason, logged and shown, and
--      the model is told at its next goal
do
fresh({ "go on", "" })
HTTP.queue = {
    reply({ thinking() }, "max_tokens", { usage = { input_tokens = 100, output_tokens = 64000, cache_read_input_tokens = 50,
        cache_creation_input_tokens = 25, output_tokens_details = { thinking_tokens = 64000 } } }),
    reply({ text("Still thinking") }, "max_tokens", { usage = { input_tokens = 100, output_tokens = 64000,
        cache_read_input_tokens = 50, cache_creation_input_tokens = 25 } }),
    reply({ text("Smaller then.") }, "end_turn"),
}
run("think hard")
local klog = Mine.files["claude.log"] or ""
check("a cut-off at max_tokens is logged with the tokens out and thinking, each time",
    #HTTP.requests == 3 and klog:find("cut off at max_tokens (64000 out, 64000 thinking)", 1, true)
        and klog:find("cut off at max_tokens (64000 out)\n", 1, true), klog)
local k2 = HTTP.requests[2] and HTTP.requests[2].body.messages
local kTold = k2 and k2[#k2].content
check("cut off while thinking: told to decide with what it has and take a smaller step",
    kTold == "Your reply was cut off at the length limit while you were thinking: decide with what you have and take a smaller step.",
    tostring(kTold))
local ENDED = "Your last goal ended when your reply was cut off at the length limit a second time (64000 tokens, while you were writing): take smaller steps, and think less before each."
check("a second cut-off in the goal ends it: logged and shown",
    klog:find("goal ended: the reply was cut off at the length limit a second time (64000 tokens, while writing)", 1, true)
        and Mine.logHas("^%(the goal ended: the reply was cut off at the length limit a second time"), klog)
local k3 = HTTP.requests[3] and HTTP.requests[3].body.messages
local kNext = k3 and k3[#k3].content
check("...and the model is told at its next goal", kNext == "go on\n\n[" .. ENDED .. "]", tostring(kNext))
end

-- 14. a request that fails after tool results: the results stay, and the
--     next goal goes on from them in the same turn
fresh({ "try again", "" })
HTTP.queue = {
    reply({ toolUse("lua", { code = "return 1" }) }, "tool_use"),
    { code = 400, body = { type = "error", error = { type = "invalid_request_error", message = "nope" } } },
    reply({ text("Carrying on.") }, "end_turn"),
}
run("count")
local m3 = HTTP.requests[3] and HTTP.requests[3].body.messages
local lastTurn = m3 and m3[#m3]
check("after a failed request, the next goal joins the tool results it never sent back",
    m3 and #m3 == 3 and lastTurn.role == "user" and lastTurn.content[1].type == "tool_result"
        and lastTurn.content[2].text == "try again", m3 and textutils.serialiseJSON(m3))

-- 15. colour: on an advanced computer the code is highlighted as vi does
--     it (lib/syntax), a long string going on from one line to the next;
--     on a plain one (every scenario above) it's printed as it is
-- (a screen 8 rows high, so what comes out overflows it and opens in the
-- pager, which must show it in the same colours)
local Tc = M.termApi(39, 8)
local CC_COLOURS = { white = 1, orange = 2, magenta = 4, lightBlue = 8, yellow = 16, grey = 128, lightGrey = 256,
    cyan = 512, green = 8192, red = 16384, black = 32768 }
local NAME = {}
for k, v in pairs(CC_COLOURS) do NAME[v] = k end
local cur, segs, blits = 1, {}, {}
term.isColour = function() return true end
term.setTextColour = function(c) cur = c end
term.getTextColour = function() return cur end
term.blit = function(t, fg) blits[#blits + 1] = t .. "/" .. fg end
colours = CC_COLOURS
local plainWrite = write
write = function(s) segs[#segs + 1] = { NAME[cur], s } end
fresh({ "" })
Tc.events = { { "char", "q" } }
HTTP.queue = {
    reply({ toolUse("lua", { code = [==[-- look
local s = "a" .. 'b' --[[x]] local t = [[one
two]] return s, 42, math.max(1, #t)]==] }) }, "tool_use"),
    reply({ text("Looked.") }, "end_turn"),
}
run("look")
write, term, colours = plainWrite, nil, nil
local seen = {}
for _, sg in ipairs(segs) do seen[#seen + 1] = tostring(sg[1]) .. ":" .. sg[2] end
local all = table.concat(seen, "|")
check("code highlighted: comments green, keywords yellow, strings red, numbers magenta, library names cyan, the rest white",
    all:find("green:-- look", 1, true) and all:find("yellow:local", 1, true) and all:find('red:"a"', 1, true)
        and all:find("red:'b'", 1, true) and all:find("green:--[[x]]", 1, true) and all:find("yellow:return", 1, true)
        and all:find("white: s, |magenta:42|", 1, true) and all:find("|cyan:math|", 1, true), all)
check("a long string goes on to the next line", all:find("red:[[one|", 1, true) and all:find("red:two]]|", 1, true), all)
check("and the prompt in yellow", all:find("yellow:> ", 1, true) ~= nil, all)
local drawn = table.concat(blits, "|")
check("the pager shows it in the same colours: the code highlighted, the banner yellow",
    drawn:find("-- look/ddddddd", 1, true) and drawn:find("--- lua/3333333", 1, true)
        and drawn:find("Claude at the controls", 1, true) and drawn:find("/444444", 1, true)
        and drawn:find("two]] return s, 42, math.max(1, #t)/eeeee044444400002200999900000200000", 1, true), drawn)

-- 16. the memory tool: /memories kept in claude/memories, its commands
--     answered as the API's documentation says; nothing outside it
fresh({ "" })
local MEM_CALLS = {
    { command = "view", path = "/memories" },
    { command = "create", path = "/memories/base.md", file_text = "chest at 3 0 4\nfuel: coal\n" },
    { command = "view", path = "/memories/base.md" },
    { command = "str_replace", path = "/memories/base.md", old_str = "coal", new_str = "charcoal" },
    { command = "str_replace", path = "/memories/base.md", old_str = "zzz", new_str = "y" },
    { command = "insert", path = "/memories/base.md", insert_line = 0, insert_text = "# base\n" },
    { command = "view", path = "/memories/base.md", view_range = { 1, 1 } },
    { command = "view", path = "/memories/../claude.key" },
    { command = "rename", old_path = "/memories/base.md", new_path = "/memories/notes/base.md" },
    { command = "view", path = "/memories" },
    { command = "delete", path = "/memories" },
    { command = "delete", path = "/memories/notes" },
}
HTTP.queue = {}
for i, c in ipairs(MEM_CALLS) do HTTP.queue[i] = reply({ toolUse("memory", c) }, "tool_use") end
HTTP.queue[#MEM_CALLS + 1] = reply({ text("Remembered.") }, "end_turn")
run("remember the base")
local function memOut(i) local r = resultsIn(i + 1)["toolu_" .. i]; return r and tostring(r.content) or "", r and r.is_error end
check("the first view of an empty memory is a listing, not an error",
    memOut(1):find("^Here're the files and directories up to 2 levels deep in /memories, excluding hidden items and node_modules:\n")
        and memOut(1):find("\t/memories$") and not select(2, memOut(1)), memOut(1))
check("create, then view with line numbers",
    memOut(2) == "File created successfully at: /memories/base.md"
        and memOut(3) == "Here's the content of /memories/base.md with line numbers:\n     1\tchest at 3 0 4\n     2\tfuel: coal", memOut(3))
local _, e5 = memOut(5)
check("str_replace edits once; text that isn't there is an error",
    memOut(4) == "The memory file has been edited." and e5 and memOut(5):find("did not appear verbatim", 1, true), memOut(5))
check("insert at line 0, and a view of one line",
    memOut(6) == "The file /memories/base.md has been edited."
        and memOut(7) == "Here's the content of /memories/base.md with line numbers:\n     1\t# base", memOut(7))
local _, e8 = memOut(8)
check("a path out of /memories is refused (the key stays unread)", e8 and memOut(8):find("outside /memories", 1, true), memOut(8))
check("rename moves it into a new folder; the listing shows both levels",
    memOut(9) == "Successfully renamed /memories/base.md to /memories/notes/base.md"
        and memOut(10):find("\n37\t/memories/notes/base.md", 1, true)      -- "# base\nchest at 3 0 4\nfuel: charcoal\n"
        and memOut(10):find("\t/memories/notes\n", 1, true) and memOut(10):find("\t/memories/notes/base.md", 1, true), memOut(10))
local _, e11 = memOut(11)
check("/memories itself can't be deleted; what's in it can",
    e11 and memOut(12) == "Successfully deleted /memories/notes" and Mine.files["claude/memories/notes/base.md"] == nil, memOut(11))

-- 17. run_program: a program's manual, a run with its arguments (what it
--     prints comes back, and T takes the position it saved), and only
--     the programs it knows.  (io's output as CC's is: a handle is a table
--     with io's own metatable, which io.output takes; the rest of io real.)
local realIO = io
local ccFile = { __name = "FILE*" }
ccFile.__index = {
    write = function(self, ...)
        for _, v in ipairs(table.pack(...)) do self._handle.write(tostring(v)) end
        return self
    end,
}
local screenOut = setmetatable({ _handle = { write = function(v) write(v) end } }, ccFile)
local currentOut = screenOut
io = setmetatable({
    stdout = screenOut,
    output = function(h)
        if h ~= nil then
            if getmetatable(h) ~= ccFile then error("bad argument #1 (FILE expected)", 2) end
            currentOut = h
        end
        return currentOut
    end,
    write = function(...) return currentOut:write(...) end,
}, { __index = realIO })
fresh({ "" })
Mine.files["turtle/mine.lua"] = "-- mine"
Mine.files["help/mine.txt"] = "mine: tunnels and branch mines"
local ranWith
shell.run = function(file, ...)
    ranWith = { file, ... }
    print("Mining 3x3.")
    local f = fs.open(package.loaded.turtlelib.dataPath(".turtlepos"), "w")
    f.write("4 0 9 2 flat")
    f.close()
    return true
end
HTTP.queue = {
    reply({ toolUse("run_program", { program = "mine", help = true }) }, "tool_use"),
    reply({ toolUse("run_program", { program = "mine", args = "3 3 32  --here" }) }, "tool_use"),
    reply({ toolUse("lua", { code = "return T.posString(), T.dir" }) }, "tool_use"),
    reply({ toolUse("run_program", { program = "autocompost" }) }, "tool_use"),
    reply({ text("Mined.") }, "end_turn"),
}
run("mine a bit")
local function progOut(i) local r = resultsIn(i + 1)["toolu_" .. i]; return r and tostring(r.content) or "", r and r.is_error end
check("help = true gives the manual and runs nothing", progOut(1) == "mine: tunnels and branch mines" and ranWith == nil or progOut(1) == "mine: tunnels and branch mines", progOut(1))
check("the program ran with its arguments, its output and where it left the turtle came back",
    ranWith and ranWith[1]:find("turtle/mine$") and table.concat(ranWith, " ", 2) == "3 3 32 --here"
        and progOut(2) == "Mining 3x3.\n[mine finished; the turtle is at (4,0,9) facing 2, fuel 1000]", progOut(2))
check("T took the position the program saved", progOut(3) == "-> (4,0,9)\n-> 2", progOut(3))
local _, e4p = progOut(4)
check("a program it doesn't know is refused", e4p and progOut(4):find("No such program: autocompost", 1, true), progOut(4))
check("the run was shown and logged", Mine.logHas("^%-%-%- run mine 3 3 32 %-%-here$")
    and (Mine.files["claude.log"] or ""):find("run: mine 3 3 32 --here", 1, true))

-- ip, for the network: what it writes (io.write) comes back, and io's
-- output is the screen again afterwards
fresh({ "" })
Mine.files["bin/ip.lua"] = "-- ip"
shell.run = function(file, ...)
    ranWith = { file, ... }
    io.write("up: 1 interface\n", "partial")
    return true
end
HTTP.queue = {
    reply({ toolUse("run_program", { program = "ip", args = "up" }) }, "tool_use"),
    reply({ text("Up.") }, "end_turn"),
}
run("bring the network up")
check("run_program ip: bin/ip ran, what it wrote with io.write came back",
    ranWith and ranWith[1]:find("bin/ip$") and ranWith[2] == "up"
        and progOut(1):find("^up: 1 interface\npartial\n%[ip finished") ~= nil and io.output() == screenOut, progOut(1))

-- ping without a count would go on for ever: it gets -c 4, unless it has
-- -c or -w already
fresh({ "" })
Mine.files["bin/ping.lua"] = "-- ping"
local pings = {}
shell.run = function(_, ...) pings[#pings + 1] = table.concat({ ... }, " "); return true end
HTTP.queue = {
    reply({ toolUse("run_program", { program = "ping", args = "10.1.4.1" }) }, "tool_use"),
    reply({ toolUse("run_program", { program = "ping", args = "-qc2 10.1.4.1" }) }, "tool_use"),
    reply({ toolUse("run_program", { program = "ping", args = "-w 5 10.1.4.1" }) }, "tool_use"),
    reply({ text("Pinged.") }, "end_turn"),
}
run("ping the gateway")
check("ping gets -c 4 when it has no count or deadline, and not when it has",
    pings[1] == "-c 4 10.1.4.1" and pings[2] == "-qc2 10.1.4.1" and pings[3] == "-w 5 10.1.4.1", table.concat(pings, " | "))

-- Ctrl+T in the program stops claude too
fresh({ "" })
Mine.files["turtle/mine.lua"] = "-- mine"
shell.run = function() printError("Terminated"); return false end
HTTP.queue = { reply({ toolUse("run_program", { program = "mine" }) }, "tool_use") }
local okT, errT = run("mine")
check("Ctrl+T in a program stops claude, nothing more is asked", not okT and tostring(errT):find("Terminated") and #HTTP.requests == 1, tostring(errT))
shell.run = nil
io = realIO

-- 18. status: the tools equipped, what's attached, the computer, a mine
--     job, and the network; the code's net sees the running stack
fresh({ "" })
Mine.files["mine.job"] = "3 3 32 4 1 mining"
_G.ccnet = { ifaces = { back = { ip = 167837701, len = 16 } } }
HTTP.queue = {
    reply({ toolUse("status", {}) }, "tool_use"),
    reply({ toolUse("lua", { code = 'local httpc = require("httpc"); return type(httpc.get), require("net").stack() == ccnet' }) }, "tool_use"),
    reply({ text("Looked.") }, "end_turn"),
}
run("look around")
_G.ccnet = nil
local st = tostring((resultsIn(2).toolu_1 or {}).content)
check("status: equipped, attached, the computer, the mine job, http and the network's addresses",
    st:find("equipped: left nothing, right minecraft:diamond_pickaxe", 1, true) and st:find("attached: ", 1, true)
        and st:find("computer 7, label none", 1, true)
        and st:find("mine job under way: 3 wide, 3 high, 32 long, spacing 4, mining", 1, true)
        and st:find("http: on; ccnix network: back 10.1.0.5/16", 1, true), st)
local nt = tostring((resultsIn(3).toolu_2 or {}).content)
check("the code can require httpc and net, and net finds the running stack", nt == "-> function\n-> true", nt)

-- 19. web search: done by the API, shown; a reply paused partway
--     (pause_turn) is sent back as it is, with no new user turn, and goes
--     on; old results cleared is logged; a quote's citations are kept
fresh({ "and now", "" })
HTTP.queue = {
    reply({ { type = "server_tool_use", id = "srvtoolu_1", name = "web_search", input = { query = "crafting turtle recipe" } },
            { type = "web_search_tool_result", tool_use_id = "srvtoolu_1",
              content = { { type = "web_search_result", url = "https://wiki.example/turtle", title = "Turtle", encrypted_content = "x" } } } },
        "pause_turn", { context_management = { applied_edits = { { type = "clear_tool_uses_20250919", cleared_tool_uses = 4, cleared_input_tokens = 20000 } } } }),
    reply({ { type = "text", text = "A turtle takes a computer and a chest.",
              citations = { { type = "web_search_result_location", url = "https://wiki.example/turtle", title = "Turtle",
                              encrypted_index = "i", cited_text = "computer, chest" } } } }, "end_turn"),
    reply({ text("Done.") }, "end_turn"),
}
run("how is a turtle made")
local w2 = HTTP.requests[2] and HTTP.requests[2].body.messages
check("a paused reply goes back as it came, last, with no user turn after it",
    w2 and #w2 == 2 and w2[2].role == "assistant" and w2[2].content[1].type == "server_tool_use"
        and w2[2].content[1].input.query == "crafting turtle recipe" and w2[2].content[2].type == "web_search_tool_result",
    w2 and textutils.serialiseJSON(w2))
check("the search was shown, the clearing logged",
    Mine.logHas("^%-%-%- web search: crafting turtle recipe$")
        and (Mine.files["claude.log"] or ""):find("context: 4 old tool results cleared (20000 tokens)", 1, true))
local w3 = HTTP.requests[3] and HTTP.requests[3].body.messages
local quoted = w3 and w3[3] and w3[3].content[1]
check("the quoting text block goes back with its citations",
    quoted and quoted.text == "A turtle takes a computer and a chest." and quoted.citations
        and quoted.citations[1].url == "https://wiki.example/turtle", w3 and textutils.serialiseJSON(w3))

-- the same clear, reported on each call after it, is logged once; a new
-- one is logged again
fresh({ "" })
local function cleared(n, tokens)
    return { context_management = { applied_edits = { { type = "clear_tool_uses_20250919", cleared_tool_uses = n, cleared_input_tokens = tokens } } } }
end
HTTP.queue = {
    reply({ toolUse("lua", { code = "return 1" }) }, "tool_use", cleared(4, 20000)),
    reply({ toolUse("lua", { code = "return 2" }) }, "tool_use", cleared(4, 20000)),
    reply({ toolUse("lua", { code = "return 3" }) }, "tool_use", cleared(4, 20000)),
    reply({ text("Done.") }, "end_turn", cleared(9, 41000)),
}
run("clear a lot")
local clog = Mine.files["claude.log"] or ""
local _, sameClears = clog:gsub("context: 4 old tool results cleared %(20000 tokens%)", "")
check("the same clear reported on three calls is logged once, a new one again",
    sameClears == 1 and clog:find("context: 9 old tool results cleared (41000 tokens)", 1, true), sameClears)

-- both edits in one reply, as the API reports them (ADR-0013 phase 1):
-- each logged by its own type (old thinking as turns, not as "0 old tool
-- results"), and each once until it changes, the other's line between
-- them notwithstanding
do
fresh({ "" })
local function bothCleared(turns, thinkTokens)
    return { context_management = { applied_edits = {
        { type = "clear_thinking_20251015", cleared_thinking_turns = turns, cleared_input_tokens = thinkTokens },
        { type = "clear_tool_uses_20250919", cleared_tool_uses = 4, cleared_input_tokens = 20000 } } } }
end
HTTP.queue = {
    reply({ toolUse("lua", { code = "return 1" }) }, "tool_use", bothCleared(3, 15000)),
    reply({ toolUse("lua", { code = "return 2" }) }, "tool_use", bothCleared(3, 15000)),
    reply({ toolUse("lua", { code = "return 3" }) }, "tool_use", bothCleared(4, 18000)),
    reply({ text("Done.") }, "end_turn", bothCleared(4, 18000)),
}
run("clear both")
local blog = Mine.files["claude.log"] or ""
local _, toolLines = blog:gsub("context: 4 old tool results cleared %(20000 tokens%)", "")
local _, think3 = blog:gsub("context: old thinking cleared %(3 turns, 15000 tokens%)", "")
local _, think4 = blog:gsub("context: old thinking cleared %(4 turns, 18000 tokens%)", "")
check("both edits in a reply: old thinking logged as turns, each edit once until it changes",
    toolLines == 1 and think3 == 1 and think4 == 1 and not blog:find("context: 0 old tool results", 1, true),
    toolLines .. " " .. think3 .. " " .. think4)
end

-- the cache written again (ADR-0013 phase 1): a call that reads much less
-- from the cache than the last call had in all is logged, with why when
-- the harness saw why (a clear in that reply, a wait past the cache's
-- TTL); the growth of a conversation isn't, nor the call after a web
-- search (its usage adds up the search's passes), nor a new conversation
do
fresh({ "/new", "fresh start", "" })
local function used(read, written, more)
    local r = { usage = { input_tokens = 100, output_tokens = 20, cache_read_input_tokens = read,
                          cache_creation_input_tokens = written } }
    for k, v in pairs(more or {}) do r[k] = v end
    return r
end
local thinkCleared = { context_management = { applied_edits = {
    { type = "clear_thinking_20251015", cleared_thinking_turns = 1, cleared_input_tokens = 9000 } } } }
local timeWas19, sleepWas19 = os.time, sleep
local skipped = 0
os.time = function(t) if t ~= nil then return timeWas19(t) end return timeWas19() + skipped end
sleep = function(s) skipped = skipped + (tonumber(s) or 0) end
HTTP.queue = {
    reply({ toolUse("lua", { code = "return 1" }) }, "tool_use", used(27000, 70000)),
    reply({ toolUse("lua", { code = "return 2" }) }, "tool_use", used(97000, 3000)),
    reply({ toolUse("lua", { code = "return 3" }) }, "tool_use", used(27000, 76000, thinkCleared)),
    reply({ toolUse("lua", { code = "sleep(400) return 4" }) }, "tool_use", used(103000, 2000, thinkCleared)),
    reply({ toolUse("lua", { code = "return 5" }) }, "tool_use", used(27000, 80000, thinkCleared)),
    reply({ { type = "server_tool_use", id = "srvtoolu_9", name = "web_search", input = { query = "x" } },
            { type = "web_search_tool_result", tool_use_id = "srvtoolu_9", content = {} },
            toolUse("lua", { code = "return 6" }) }, "tool_use", used(300000, 5000, thinkCleared)),
    reply({ toolUse("lua", { code = "return 7" }) }, "tool_use", used(110000, 4000, thinkCleared)),
    reply({ toolUse("lua", { code = "return 8" }) }, "tool_use", used(80000, 60000, thinkCleared)),
    reply({ text("Done.") }, "end_turn", used(140000, 2000, thinkCleared)),
    reply({ text("New here.") }, "end_turn", used(27000, 1000)),
}
run("rewrites")
os.time, sleep = timeWas19, sleepWas19
local rlog = Mine.files["claude.log"] or ""
local rewrites = {}
for line in rlog:gmatch("cache: written again[^\n]*") do rewrites[#rewrites + 1] = line end
check("the cache written again is logged with why: a clear, the cache's TTL passed, or not seen; growth and a web search's sum aren't",
    #rewrites == 3
        and rewrites[1] == "cache: written again (76000 tokens written, 27000 read from it; the last call had 100100 in): old thinking cleared"
        and rewrites[2] == "cache: written again (80000 tokens written, 27000 read from it; the last call had 105100 in): over the cache's 5 minutes since the last call"
        and rewrites[3] == "cache: written again (60000 tokens written, 80000 read from it; the last call had 114100 in): why not seen",
    table.concat(rewrites, "\n"))
end

-- 19b. the rest of the sandbox (scenario 2 has the start of it): write
--     and io.write come back a line at a time (print after a write
--     finishes its line), printError too, and the plain Lua bits a helper
--     wants (metatables, raw access, xpcall), keys and colours
local savedColours, savedKeys = colours, keys
colours, keys = { white = 1, red = 16384 }, { enter = 28 }
fresh({ "" })
HTTP.queue = {
    reply({ toolUse("lua", { code = [[
io.write("a", 1); write("b\nc"); print("d"); printError("oops"); write("tail")
local t = setmetatable({}, { __index = function() return 7 end })
return t.x, getmetatable(t) ~= nil, rawget(t, "x"), rawset(t, "y", 2).y, rawequal(t, t),
    select(2, xpcall(function() error("boom", 0) end, function(e) return "caught " .. e end)),
    keys ~= nil, colours.red, colors ~= nil]] }) }, "tool_use"),
    reply({ text("Checked.") }, "end_turn"),
}
run("more of the sandbox")
colours, keys = savedColours, savedKeys
local sb = resultsIn(2).toolu_1
check("write, io.write and printError come back with print's, a line at a time",
    sb and tostring(sb.content):find("^a1b\ncd\noops\ntail\n") and sb.is_error == nil, sb and sb.content)
check("setmetatable, getmetatable, rawget, rawset, rawequal, xpcall, keys, colours and colors are there",
    sb and tostring(sb.content):find("\n%-> 7\n%-> true\n%-> nil\n%-> 2\n%-> true\n%-> caught boom\n%-> true\n%-> 16384\n%-> true$"),
    sb and sb.content)

-- 20. Text past ASCII: the model's UTF-8 goes back byte for byte (a
--     thinking block after it is bound to it), CC's Latin-1 from a tool goes
--     as UTF-8, and the screen shows what CC can ("×" as itself, "—" and "’"
--     as ASCII); a step of the API's own the code a search filters with
--     is shown by its name
fresh({ "" })
local UTF = "3\195\1513 \226\128\148 it\226\128\153s done"
HTTP.queue = {
    reply({ text(UTF), { type = "server_tool_use", id = "srvtoolu_2", name = "code_execution", input = { code = "x" } },
            thinking(), toolUse("lua", { code = "print('a' .. string.char(167) .. 'b')" }) }, "tool_use"),
    reply({ text("Done.") }, "end_turn"),
}
run("dig")
local u2 = HTTP.requests[2] and HTTP.requests[2].body.messages
check("the model's UTF-8 goes back as it came", u2 and u2[2].content[1].text == UTF, u2 and u2[2].content[1].text)
local lr = tostring((resultsIn(2).toolu_1 or {}).content)
check("a tool's Latin-1 goes as UTF-8", lr:find("a\194\167b", 1, true) ~= nil, lr)
check("the screen shows x as CC has it, the dash and quote as ASCII", Mine.logHas("^3\2153 %- it's done$"))
check("the API's own code step shown by its name", Mine.logHas("^%-%-%- code execution$"))

-- 21. The log rotates at claude.logSize, keeping one old copy (claude.logKeep 1: scenario 38 has more); the helpers
--     the model keeps in /claude/helpers.lua are in its code's world; a
--     broken helpers file is told to the model and the session goes on
-- (loadfile reads the real disk in the sim: files in the mock's fs are read from it first)
local realLoadfile = loadfile
loadfile = function(p, ...)
    local body = Mine.files[(tostring(p):gsub("^/", ""))]
    if body then
        local mode, e = ...
        return load(body, "=" .. p, mode, e)
    end
    return realLoadfile(p, ...)
end
local SET = { ["claude.logSize"] = 600, ["claude.logKeep"] = 1 }
settings = { define = function() end, get = function(n) return SET[n] end }
fresh({ "" })
HTTP.queue = {
    reply({ toolUse("lua", { code = "return string.rep('x', 400)" }) }, "tool_use"),
    reply({ toolUse("lua", { code = "return string.rep('y', 400)" }) }, "tool_use"),
    reply({ toolUse("lua", { code = "return string.rep('z', 400)" }) }, "tool_use"),
    reply({ text("Done.") }, "end_turn"),
}
run("fill the log")
local cur, old = Mine.files["claude.log"], Mine.files["claude.log.1"]
check("claude.log passes claude.logSize: the old log is kept as claude.log.1, a new one started",
    cur and old and #old >= 600 and cur:find("^%d+%-%d+%-%d+ %d+:%d+:%d+ ") ~= nil, tostring(cur and #cur) .. " / " .. tostring(old and #old))
check("claude.logKeep 1: only one old copy, the first entries gone from both", not (Mine.files["claude.log.2"])
    and not (old or ""):find("start: claude", 1, true) and not (cur or ""):find("start: claude", 1, true))
settings = nil

fresh({ "" })
Mine.files["claude/helpers.lua"] = "function double(n) return n * 2 end\nHELPER_NAME = 'kept'"
HTTP.queue = {
    reply({ toolUse("lua", { code = "return double(21), HELPER_NAME" }) }, "tool_use"),
    reply({ text("Done.") }, "end_turn"),
}
run("use the helper")
check("what /claude/helpers.lua defines is there for the model's code",
    resultsIn(2).toolu_1 and resultsIn(2).toolu_1.content == "-> 42\n-> kept", resultsIn(2).toolu_1 and resultsIn(2).toolu_1.content)
check("the system prompt tells it to keep helpers in /claude/helpers.lua and of T.takeInto, T.refuelFrom and r/u/f",
    HTTP.requests[1] and textutils.serialiseJSON(HTTP.requests[1].body.system):find("/claude/helpers.lua", 1, true)
        and textutils.serialiseJSON(HTTP.requests[1].body.system):find("T.takeInto", 1, true)
        and textutils.serialiseJSON(HTTP.requests[1].body.system):find("T.refuelFrom", 1, true))

fresh({ "" })
Mine.files["claude/helpers.lua"] = "print('helpers loading')\nfunction triple(n) return 3 * n end"
HTTP.queue = {
    reply({ toolUse("lua", { code = "print('hi'); return triple(2)" }) }, "tool_use"),
    reply({ text("Done.") }, "end_turn"),
}
run("print from the helpers")
local hp = HTTP.requests[1] and textutils.serialiseJSON(HTTP.requests[1].body.messages[1].content) or ""
check("a print at the top of helpers.lua works: shown, the file loaded, the code's own print still comes back",
    Mine.logHas("^helpers loading$") and not hp:find("failed to load", 1, true)
        and resultsIn(2).toolu_1 and resultsIn(2).toolu_1.content == "hi\n-> 6", hp)

fresh({ "" })
Mine.files["claude/helpers.lua"] = "function broken( end"
HTTP.queue = { reply({ toolUse("lua", { code = "return 1 + 1" }) }, "tool_use"), reply({ text("Done.") }, "end_turn") }
run("go on")
local m1 = HTTP.requests[1] and HTTP.requests[1].body.messages[1]
local m1text = m1 and textutils.serialiseJSON(m1.content) or ""
check("a broken helpers.lua is reported to the model with its first goal",
    m1text:find("helpers.lua failed to load", 1, true) and m1text:find("go on", 1, true), m1text)
check("the session carries on, and the failure is logged",
    resultsIn(2).toolu_1 and resultsIn(2).toolu_1.content == "-> 2"
        and (Mine.files["claude.log"] or ""):find("helpers.lua failed to load", 1, true))

-- 22. the turtle API is wrapped (ADR-0008): moves made straight through
--     turtle.* keep T.pos right, the prompt says so, and a program that
--     loaded a turtlelib of its own meanwhile doesn't take that from claude
fresh({ "" })
Mine.files["turtle/mine.lua"] = "-- mine"
currentOut = screenOut
io = setmetatable({
    stdout = screenOut,
    output = function(h)
        if h ~= nil then currentOut = h end
        return currentOut
    end,
    write = function(...) return currentOut:write(...) end,
}, { __index = realIO })
shell.run = function()
    local mine = package.loaded.turtlelib
    package.loaded.turtlelib = nil          -- what a program run by the shell gets: a copy of its own
    require("turtlelib")
    package.loaded.turtlelib = mine
    return true
end
HTTP.queue = {
    reply({ toolUse("lua", { code = "turtle.dig(); turtle.forward(); turtle.turnRight(); return T.posString(), T.dir" }) }, "tool_use"),
    reply({ toolUse("run_program", { program = "mine" }) }, "tool_use"),
    reply({ toolUse("lua", { code = "turtle.digUp(); turtle.up(); return T.posString(), T.dir" }) }, "tool_use"),
    reply({ text("Done.") }, "end_turn"),
}
run("move straight through turtle")
shell.run = nil
io = realIO
local sys = HTTP.requests[1] and textutils.serialiseJSON(HTTP.requests[1].body.system) or ""
check("turtle.forward() and turnRight() called straight keep T.pos and T.dir right",
    resultsIn(2).toolu_1 and resultsIn(2).toolu_1.content == "-> (0,0,1)\n-> 1", resultsIn(2).toolu_1 and resultsIn(2).toolu_1.content)
check("after a program loaded its own turtlelib, claude's T is still the one the turtle API updates",
    resultsIn(4).toolu_3 and resultsIn(4).toolu_3.content == "-> (0,1,1)\n-> 1", resultsIn(4).toolu_3 and resultsIn(4).toolu_3.content)
check("the prompt no longer says never to call turtle.forward, and tells of protected areas",
    not sys:find("Never call turtle.forward", 1, true) and sys:find("T.protect(name", 1, true)
        and sys:find("T.onChange(fn)", 1, true) and sys:find("T.cfg.digContainers", 1, true))

-- 23. a module loaded through T (ADR-0008's lazy loader): the model's code
--     asks T for a function T lacks, T loads its module from turtlelib's
--     own world (the real require and the real fs, as turtlelib itself),
--     and only the code's own fs is guarded
fresh({ "" })
FIXTURE_LOADS = nil
HTTP.queue = {
    reply({ toolUse("lua", { code = [[T.registry.fixtureReadsKey = "tl.fixture"; T.registry.fixtureHello = "tl.fixture"
return T.fixtureReadsKey(), (select(2, fs.open("claude.key", "r")))]] }) }, "tool_use"),
    reply({ toolUse("lua", { code = [[return T.fixtureHello("again")]] }) }, "tool_use"),
    reply({ text("Done.") }, "end_turn"),
}
run("a module through T")
local viaT = resultsIn(2).toolu_1 and tostring(resultsIn(2).toolu_1.content) or ""
check("a module loaded through T reads what the code's own fs may not (turtlelib's world, not the code's)",
    viaT:find("^%-> true\n") and viaT:find("API key isn't readable", 1, true) and FIXTURE_LOADS == 1, viaT)
check("...a second function of it needs no second load",
    resultsIn(3).toolu_2 and tostring(resultsIn(3).toolu_2.content):find("^%-> hello again") and FIXTURE_LOADS == 1)

-- 24. the system prompt carries turtlelib's index (ADR-0008, phase 1): one
--     line a function, from turtle/tl/index.txt, and says where the full
--     reference is and how to read it; with no index on the computer the
--     prompt says so; status names the protected areas near the turtle
fresh({ "" })
HTTP.queue = {
    reply({ toolUse("lua", { code = [[
T.protect("keep", 3, 0, 3, 5, 4, 5)
T.protect("far", 100, 0, 100, 105, 4, 105)
return #T.protections()]] }) }, "tool_use"),
    reply({ toolUse("status", {}) }, "tool_use"),
    reply({ toolUse("lua", { code = "T.pos.x = 4; T.pos.y = 1; T.pos.z = 4; return 1" }) }, "tool_use"),
    reply({ toolUse("status", {}) }, "tool_use"),
    reply({ text("Done.") }, "end_turn"),
}
run("index please")
local sys24 = HTTP.requests[1] and HTTP.requests[1].body.system[1].text or ""
local nIndexLines = 0
for line in REAL_INDEX:gmatch("[^\n]+") do
    if line:sub(1, 2) == "T." then
        nIndexLines = nIndexLines + 1
        if not sys24:find(line, 1, true) then nIndexLines = -1000 end
    end
end
check("the system prompt holds every line of turtle/tl/index.txt, whole", nIndexLines > 100, nIndexLines)
check("...among them the ones for the wrap, protection and the new moves",
    sys24:find("T.protect(name, x1, y1, z1, x2, y2, z2) - ", 1, true) and sys24:find("T.onChange(fn) - ", 1, true)
        and sys24:find("T.moveTo(x, y, z, opts) - ", 1, true) and sys24:find("T.pull(side, name, n, opts) - ", 1, true)
        and sys24:find("T.withPeripheral(name, fn) - ", 1, true) and sys24:find("T.dumpJunk() - ", 1, true))
check("it says where the full reference is and how to read part of it with fs",
    sys24:find("help/turtlelib.txt", 1, true) and sys24:find('all:find("T.moveTo(", 1, true)', 1, true)
        and sys24:find("fs.open(", 1, true))
check("the interim notes are folded in: helpers file, T.keep, r/u/f, the frame, safety and cost",
    sys24:find("/claude/helpers.lua", 1, true) and sys24:find("T.keep", 1, true) and sys24:find("r, u and f", 1, true)
        and sys24:find("Frames:", 1, true) and sys24:find("Safety:", 1, true) and sys24:find("Cost:", 1, true))
check("the prompt still ends the way it did", sys24:find("say plainly if something failed.", 1, true) ~= nil)
check("the placeholders are all filled", not sys24:find("@INDEX@", 1, true) and not sys24:find("@DETAILS@", 1, true))
-- the path the prompt names is one the code's own fs can read
local readsManual = sys24:match('fs%.open%("([^"]+)"')
check("the path the prompt gives for the reference exists", readsManual ~= nil and fs.exists(readsManual), tostring(readsManual))
local st1 = resultsIn(3).toolu_2 and tostring(resultsIn(3).toolu_2.content) or ""
check("status names the protected area near the turtle and leaves out the far one, counting it",
    st1:find("protected areas near: keep (3,0,3 to 5,4,5)", 1, true) and not st1:find("far (", 1, true), st1)
local st2 = resultsIn(5).toolu_4 and tostring(resultsIn(5).toolu_4.content) or ""
check("...and says when the turtle is inside one", st2:find("keep (3,0,3 to 5,4,5) - the turtle is inside it", 1, true), st2)

fresh({ "" })
Mine.files["turtle/tl/index.txt"] = nil
HTTP.queue = { reply({ text("Done.") }, "end_turn") }
run("no index")
local sysNone = HTTP.requests[1] and HTTP.requests[1].body.system[1].text or ""
check("with no index on the computer the prompt says so and points at the source",
    sysNone:find("index of turtlelib's functions, turtle/tl/index.txt, isn't on this computer", 1, true)
        and sysNone:find("turtlelib.lua", 1, true) and sysNone:find("say plainly if something failed.", 1, true)
        and not sysNone:find("@INDEX@", 1, true))

-- 25. status shows the world origin and the job journal's step (ADR-0008, phase 4)
fresh({ "" })
HTTP.queue = {
    reply({ toolUse("status", {}) }, "tool_use"),
    reply({ toolUse("lua", { code = [[
T.map.clear()
T.setOrigin(100, 64, -20, "north")
T.job.start("build the keep", { "clear", "floor", "walls" })
T.job.done()
return 1]] }) }, "tool_use"),
    reply({ toolUse("status", {}) }, "tool_use"),
    reply({ text("Done.") }, "end_turn"),
}
run("what is the job")
local st25a = resultsIn(2).toolu_1 and tostring(resultsIn(2).toolu_1.content) or ""
local st25b = resultsIn(4).toolu_3 and tostring(resultsIn(4).toolu_3.content) or ""
check("status says nothing of an origin or a job while there is none", st25a ~= "" and not st25a:find("world origin", 1, true) and not st25a:find("job: ", 1, true), st25a)
check("...and shows the origin and the job's step once there is", st25b:find("world origin: the turtle's 0,0,0 is 100,64,-20 and its +z points north", 1, true)
    and st25b:find("job: build the keep - step 2 of 3: floor", 1, true), st25b)

-- 26. the prompt's prose on using the whole library (ADR-0008, phase 5): a
--     Building paragraph walks through origin, map, moving, placing and
--     blueprints, materials and the journals, and every T.name in it is a
--     function in the index (or one of the settings it names)
fresh({ "" })
HTTP.queue = { reply({ text("Done.") }, "end_turn") }
run("how do I build")
local sys26 = HTTP.requests[1] and HTTP.requests[1].body.system[1].text or ""
local para26 = sys26:match("\nBuilding:(.-)\n\n") or ""
check("the prompt has a Building paragraph", #para26 > 500, #para26)
check("...naming the origin, the map, scans, travel, placing, blueprints, crafting, the chests and the journals",
    para26:find("T.setOrigin", 1, true) and para26:find("T.map.get", 1, true) and para26:find("T.scan(r)", 1, true)
        and para26:find("T.travel", 1, true) and para26:find("T.placeAt", 1, true) and para26:find("T.build(", 1, true)
        and para26:find("T.verify", 1, true) and para26:find("T.craft(", 1, true) and para26:find("T.stow", 1, true)
        and para26:find("T.job.start", 1, true) and para26:find("T.undo", 1, true) and para26:find("T.report", 1, true))
-- (settings, and T.report, which is a table that can be called: its functions are indexed as T.report.now and so on)
local fields26 = { ["T.cfg.undo"] = true, ["T.cfg.autoDump"] = true, ["T.report"] = true }
local missing26 = {}
for word in para26:gmatch("T%.[%w%.]+") do
    local name = word:gsub("%.$", "")
    if not fields26[name] and not ("\n" .. REAL_INDEX):find("\n" .. name .. "(", 1, true) then
        missing26[#missing26 + 1] = name
    end
end
check("every T.name the paragraph mentions is in the index", #missing26 == 0, table.concat(missing26, " "))
check("the old interim sentence about scanBlocks now points at T.scan", sys26:find("T.scan(r) does the Geo Scanner's work in this frame for you", 1, true)
    and sys26:find("r, u and f", 1, true))
check("the prompt says what moves with a --here, how to drop a wrong lesson, and whose autoDump and undo they are",
    sys26:find("move with the frame", 1, true) and para26:find("T.forgetPlacements()", 1, true)
    and para26:find("not while a program you run has the turtle", 1, true) and para26:find("not a program's you run", 1, true))

-- 27. a fault inside the status tool goes back to the model as a tool error;
-- claude carries on (in game a missing .map folder ended the session here)
fresh({ "" })
HTTP.queue = {
    reply({ toolUse("lua", { code = [[
T.loadMineJob = function() error("disk on fire", 0) end
return 1]] }) }, "tool_use"),
    reply({ toolUse("status", {}) }, "tool_use"),
    reply({ text("Status is broken.") }, "end_turn"),
}
run("where are you")
local st27 = resultsIn(3).toolu_2
check("a status that fails goes back as a tool error saying why",
    st27 and st27.is_error == true and tostring(st27.content):find("status failed: disk on fire", 1, true), st27 and tostring(st27.content))
check("...and the session carries on to the model's answer", #HTTP.queue == 0 and Mine.logHas("Status is broken%."))

-- 28. what the prompt says of working (ADR-0011, phase 2): globals last the
--     session and a local its call, a plan file and a check before a big
--     job, caps on long loops, results checked before the player is told,
--     memory kept pruned, the cache's TTL (the session's, so the prompt
--     stays the same all session), and what the player wants
fresh({ "" })
HTTP.queue = { reply({ text("Done.") }, "end_turn") }
run("how should I work")
local sys28 = HTTP.requests[1] and HTTP.requests[1].body.system[1].text or ""
local lua28 = HTTP.requests[1] and HTTP.requests[1].body.tools[1].description or ""
check("the prompt: a global persists for the session, a local ends with its call, clearing removes no definition",
    sys28:find("a global you set (x = 1, function f() end) persists for the session, a `local` ends with its call", 1, true)
        and sys28:find("clearing old results never removes a definition", 1, true)
        and not sys28:find("but not between sessions or after old results are cleared", 1, true))
check("...and the lua tool says the same",
    lua28:find("Globals persist for the session (clearing old results doesn't remove them); a local ends with its call.", 1, true)
        and not lua28:find("Definitions persist", 1, true), lua28)
check("...a plan in /claude/<job>.md and a check first (fuel, slots, materials, protections, route, liquids); T.job.clear()",
    sys28:find("write its plan to /claude/<job>.md", 1, true) and sys28:find("fuel for the job and the way back, free slots, the materials, the protected areas, the route, and lava or water next to anything you will dig", 1, true)
        and sys28:find("T.job.clear() ends a finished job", 1, true))
check("...caps on long loops and a call kept to a few minutes; each result checked before the player is told; short summaries",
    sys28:find("keep a call to a few minutes, and give every long loop caps on fuel, time and count", 1, true)
        and sys28:find("Before telling the player something is done, check each result", 1, true)
        and sys28:find("return short summaries", 1, true))
check("...memory kept pruned, the old archived",
    sys28:find("keep it pruned: what's current first, the old moved to an archive file", 1, true) ~= nil)
check("...the cache's TTL as the session has it (5 minutes by default) and what a longer wait costs",
    sys28:find("The cache keeps the conversation for 5 minutes with no call reading it", 1, true)
        and sys28:find("has the whole conversation written to the cache again", 1, true) and not sys28:find("@CACHE@", 1, true))
check("...the player: told in chat, honestly; their changes left alone; ask first; floors restored; built for a 2-tall player",
    sys28:find("keep them told in chat (T.report) at the start, at milestones, at trouble and at the end, honestly", 1, true)
        and sys28:find('Don\'t undo or "fix" their changes', 1, true)
        and sys28:find("ask before replacing their things or digging big holes in shared spaces", 1, true)
        and sys28:find("Restore a floor you dig through with the same block, and stow what isn't in use", 1, true)
        and sys28:find("3 air above a stair's walking line", 1, true) and sys28:find("railings at drops of more than 3", 1, true))
fresh({ "" })
HTTP.queue = { reply({ text("Done.") }, "end_turn") }
run("how long is the cache", "--cache", "1h")
local sys28h = HTTP.requests[1] and HTTP.requests[1].body.system[1].text or ""
check("with --cache 1h the prompt says an hour", sys28h:find("The cache keeps the conversation for an hour with no call reading it", 1, true) ~= nil)

-- 29. /new at the prompt: the conversation emptied, the helpers loaded
--     again, the model told it's a new conversation; the files stay
fresh({ "/new", "dig again", "" })
Mine.files["claude/helpers.lua"] = "HELPER_LOADS = (HELPER_LOADS or 0) + 1"
HTTP.queue = {
    reply({ toolUse("lua", { code = "fs.makeDir('/claude'); local f = fs.open('/claude/plan.md', 'w'); f.write('plan'); f.close(); return HELPER_LOADS" }) }, "tool_use"),
    reply({ text("Dug.") }, "end_turn"),
    reply({ toolUse("lua", { code = "return HELPER_LOADS, fs.exists('/claude/plan.md')" }) }, "tool_use"),
    reply({ text("Dug again.") }, "end_turn"),
}
run("dig")
Mine.files["claude/helpers.lua"] = nil
local n3 = HTTP.requests[3] and HTTP.requests[3].body.messages
check("/new: the next goal starts a conversation of its own, told that it is new",
    n3 and #n3 == 1 and n3[1].content:find("^dig again\n\n%[This is a new conversation") ~= nil, n3 and n3[1].content)
check("...the helpers loaded again, the files as they were", resultsIn(4).toolu_2 and resultsIn(4).toolu_2.content == "-> 2\n-> true",
    resultsIn(4).toolu_2 and resultsIn(4).toolu_2.content)
check("...and it says so, and logs it", Mine.logHas("^A new conversation") and (Mine.files["claude.log"] or ""):find("new conversation\n", 1, true))


-- 30. each lua result ends with a status line (ADR-0011 D8): where the
--     turtle is, its fuel and what the call used, the free slots, and lava
--     or water beside it; an error result has it too, and a fault in it is
--     said in its place
do
fresh({ "" })
Mine.set(0, -1, 0, { name = "minecraft:lava", level = 0 })
Mine.set(0, 0, 3, { name = "minecraft:lava", level = 0 })
Mine.set(0, 1, 2, { name = "minecraft:water", level = 0 })
HTTP.queue = {
    reply({ toolUse("lua", { code = "turtle.dig(); T.forward(); turtle.dig(); T.forward(); return 'two'" }) }, "tool_use"),
    reply({ toolUse("lua", { code = "error('stuck', 0)" }) }, "tool_use"),
    reply({ toolUse("lua", { code = "turtle.getItemCount = function() error('no count', 0) end; return 1" }) }, "tool_use"),
    reply({ text("Done.") }, "end_turn"),
}
local countWas = turtle.getItemCount
run("look at the status line")
turtle.getItemCount = countWas
local s30 = resultsIn(2).toolu_1
check("a lua result ends with the status line: position, fuel and what the call used, slots free, lava and water beside it, how long the run took",
    s30 and s30.content == "-> two" and s30.status == "[at 0,0,2 facing 0, fuel 998 (-2), 14 slots free; lava ahead, water above; took 0 s]",
    s30 and tostring(s30.status))
local e30 = resultsIn(3).toolu_2
check("...an error result too", e30 and e30.is_error == true and e30.content == "error: stuck"
    and e30.status == "[at 0,0,2 facing 0, fuel 998 (-0), 14 slots free; lava ahead, water above; took 0 s]", e30 and tostring(e30.status))
local f30 = resultsIn(4).toolu_3
check("...and a status line that fails says why in its place", f30 and f30.content == "-> 1" and f30.status == "[status: no count]",
    f30 and tostring(f30.status))
check("...the line is logged with the result, not shown on the screen",
    (Mine.files["claude.log"] or ""):find("result:\n-> two\n[at 0,0,2 facing 0,", 1, true) and not Mine.logHas("^%[at 0,0,2"))
fresh({ "" })
Mine.set(0, -1, 0, { name = "minecraft:lava", level = 0 })
Mine.set(0, 1, 0, { name = "minecraft:lava", level = 0 })
HTTP.queue = { reply({ toolUse("lua", { code = "return 1" }) }, "tool_use"), reply({ text("Done.") }, "end_turn") }
run("lava round it")
local l30 = resultsIn(2).toolu_1
check("lava on two sides is named once with both", l30 and l30.status == "[at 0,0,0 facing 0, fuel 1000 (-0), 16 slots free; lava below/above; took 0 s]",
    l30 and tostring(l30.status))
end

-- 31. helpers one to a file (ADR-0011 D6): /claude/helpers.lua first, then
--     each file in /claude/helpers/ in name order, each on its own, the
--     broken ones named; keep(name, code) compiles, runs and writes one,
--     and writes nothing for code that doesn't compile or run; a local at
--     the top of a call is noted as gone
do
fresh({ "" })
Mine.dirs["claude/helpers"] = true
Mine.files["claude/helpers.lua"] = "ORDER = 'file'"
Mine.files["claude/helpers/b_bad.lua"] = "function broken( end"
Mine.files["claude/helpers/a_err.lua"] = "error('a_err fails', 0)"
Mine.files["claude/helpers/c_good.lua"] = "ORDER = ORDER .. ',c'; function quad(n) return 4 * n end"
Mine.files["claude/helpers/notes.txt"] = "not a helper"
HTTP.queue = {
    reply({ toolUse("lua", { code = "return ORDER, quad(2)" }) }, "tool_use"),
    reply({ toolUse("lua", { code = [[local ok, file = keep("triple", "function triple(n) return 3 * n end"); return ok, file, triple(2)]] }) }, "tool_use"),
    reply({ toolUse("lua", { code = [[return keep("bad", "function bad( end")]] }) }, "tool_use"),
    reply({ toolUse("lua", { code = [[return keep("boom", "error('it broke', 0)")]] }) }, "tool_use"),
    reply({ toolUse("lua", { code = [[return keep("../startup", "x = 1")]] }) }, "tool_use"),
    reply({ toolUse("lua", { code = "local function helper() return 1 end\nlocal two = function() return 2 end\nlocal helper = function() end\n  local function inner() end\nlocal a, b = 1, 2\nlocal text = require('text')\nreturn 1" }) }, "tool_use"),
    reply({ toolUse("lua", { code = "local x = function() return 5 end\nreturn x()" }) }, "tool_use"),
    reply({ toolUse("lua", { code = "local function y() end\nerror('no', 0)" }) }, "tool_use"),
    reply({ toolUse("lua", { code = "W = 1\nlocal function W() return 7 end\nlocal function x() return 8 end\nreturn W(), x()" }) }, "tool_use"),
    reply({ toolUse("lua", { code = "for i = 1, 20 do print('no route: walled in by stone') end\nprint('the end')\nreturn 1" }) }, "tool_use"),
    reply({ toolUse("lua", { code = "print(string.rep('a', 6100))" }) }, "tool_use"),
    reply({ toolUse("lua", { code = "print('if a then\\nx\\nend\\nif b then\\ny\\nend')" }) }, "tool_use"),
    reply({ toolUse("lua", { code = "print('a\\nb\\na')\nprint('#####.\\n......\\n#####.\\n#####.')" }) }, "tool_use"),
    reply({ text("Done.") }, "end_turn"),
}
run("keep things")
local first31 = HTTP.requests[1] and HTTP.requests[1].body.messages[1].content or ""
check("helpers.lua, then the folder's files in name order, each on its own: the good ones loaded",
    resultsIn(2).toolu_1 and resultsIn(2).toolu_1.content == "-> file,c\n-> 8", resultsIn(2).toolu_1 and resultsIn(2).toolu_1.content)
check("...the broken ones named to the model with its first goal, a syntax error and a runtime one",
    first31:find("/claude/helpers/a_err.lua failed to load: a_err fails; /claude/helpers/b_bad.lua failed to load: ", 1, true)
        and not first31:find("c_good", 1, true) and not first31:find("helpers.lua failed", 1, true), first31)
local k2 = resultsIn(3).toolu_2
check("keep: compiled, run (defined at once) and written to /claude/helpers/<name>.lua",
    k2 and k2.content == "-> true\n-> /claude/helpers/triple.lua\n-> 6"
        and Mine.files["claude/helpers/triple.lua"] == "function triple(n) return 3 * n end", k2 and k2.content)
local k3, k4, k5 = resultsIn(4).toolu_3, resultsIn(5).toolu_4, resultsIn(6).toolu_5
check("keep: code that doesn't compile is an error naming the helper, and nothing is written",
    k3 and k3.is_error and k3.content:find("keep: bad doesn't compile, so nothing was kept: bad:1:", 1, true)
        and Mine.files["claude/helpers/bad.lua"] == nil, k3 and k3.content)
check("...nor code that fails as it runs",
    k4 and k4.is_error and k4.content:find("keep: boom failed as it ran, so nothing was kept: it broke", 1, true)
        and Mine.files["claude/helpers/boom.lua"] == nil, k4 and k4.content)
check("...and the name is one word, so the file stays in the folder",
    k5 and k5.is_error and k5.content:find("the name is one word", 1, true) and Mine.files["startup.lua"] == nil, k5 and k5.content)
local l6, l7, l8 = resultsIn(7).toolu_6, resultsIn(8).toolu_7, resultsIn(9).toolu_8
check("an unindented local function at the top of a call is noted as gone, each name once; an indented one, and other locals, not",
    l6 and l6.content == "-> 1\nnote: helper, two were local to this call and are gone; make them global, or keep() them", l6 and l6.content)
check("...one name in the singular", l7 and l7.content == "-> 5\nnote: x was local to this call and is gone; make it global, or keep() it", l7 and l7.content)
check("...and nothing is noted when the call failed", l8 and l8.is_error and l8.content == "error: no", l8 and l8.content)
-- ADR-0015: no note for a name that is a global after all; repeated lines once, with a count; no clip of a few characters
local l9, l10, l11 = resultsIn(10).toolu_9, resultsIn(11).toolu_10, resultsIn(12).toolu_11
check("...nor for a name that is a global too, nor one noted before (once a session is enough)", l9 and l9.content == "-> 7\n-> 8",
    l9 and l9.content)
check("a line printed 20 times comes back once, with how many times, the rest after it",
    l10 and l10.content == "no route: walled in by stone (x20)\nthe end\n-> 1", l10 and l10.content)
check("output a little over the limit is sent whole: no \"(3 characters left out)\"",
    l11 and #l11.content == 6100 and not l11.content:find("left out", 1, true), l11 and #l11.content)
-- ADR-0019: only a run of three or more alike, side by side, folds, and never a short line: printed code keeps its ends
local l12, l13 = resultsIn(13).toolu_12, resultsIn(14).toolu_13
check("...printed code comes back as it was: a short line like `end` never folds",
    l12 and l12.content == "if a then\nx\nend\nif b then\ny\nend", l12 and l12.content)
check("...nor do lines apart, nor two alike side by side (map rows)",
    l13 and l13.content == "a\nb\na\n#####.\n......\n#####.\n#####.", l13 and l13.content)
fresh({ "" })
HTTP.queue = { reply({ text("Done.") }, "end_turn") }
run("what do I keep")
local sys31 = HTTP.requests[1] and HTTP.requests[1].body.system[1].text or ""
local lua31 = HTTP.requests[1] and HTTP.requests[1].body.tools[1].description or ""
check("the prompt and the lua tool tell of keep(name, code) and /claude/helpers/",
    sys31:find("with keep(name, code): it runs the code now and writes it to /claude/helpers/<name>.lua", 1, true)
        and sys31:find("/claude/helpers.lua, then each file in /claude/helpers/", 1, true)
        and lua31:find("keep(name, code) runs a helper and keeps it", 1, true))
end

-- 32. the chat tool (ADR-0011 D4): says something through a chat box (the
--     one aboard equipped for the moment), or asks and waits for an answer
--     from the chat or the keyboard, whichever comes first; the chat box
--     goes back whichever it was; the wait stops short of the cache's TTL
--     unless the model asks for longer, and no answer is a normal result.
--     (A chat box peripheral, AP's chat events, the settings, and CC's
--     parallel over coroutines: each scripted event goes to the routines
--     waiting for it, as CC's does; read() waits for a "sim_read" event.)
do
local CHAT = "advancedperipherals:chat_box"
local CHATSENT = {}
local chatBox = {
    sendMessageToPlayer = function(m, p) CHATSENT[#CHATSENT + 1] = { message = m, player = p }; return true end,
    sendMessage = function(m) CHATSENT[#CHATSENT + 1] = { message = m, everyone = true }; return true end,
}
local rawWrap, rawType = peripheral.wrap, peripheral.getType
peripheral.wrap = function(side) if EQ[side] == CHAT then return chatBox end return rawWrap(side) end
peripheral.getType = function(side) if EQ[side] == CHAT then return "chat_box" end return rawType(side) end
peripheral.find = function(kind)
    for _, side in ipairs({ "left", "right" }) do
        if peripheral.getType(side) == kind then return peripheral.wrap(side) end
    end
end
local SET32 = { ["turtle.player"] = "Steve" }
settings = { define = function() end, get = function(n) return SET32[n] end }
local SCRIPT = {}
local inParallel = 0
-- The clocks while waiting: a scripted timer event moves game time
-- (os.clock) on by what the timer asked for, and real time (os.epoch when
-- a scenario gives one) by that at CLK.tps ticks a second
local CLK = { game = 0, real = 1000000, tps = 20, last = 1 }
parallel = { waitForAny = function(...)
    inParallel = inParallel + 1
    local cos, filters, ev = {}, {}, { n = 0 }
    for i, f in ipairs({ ... }) do cos[i] = coroutine.create(f) end
    while true do
        for i, co in ipairs(cos) do
            if filters[i] == nil or filters[i] == ev[1] then
                local ok, f = coroutine.resume(co, table.unpack(ev, 1, ev.n))
                if not ok then inParallel = inParallel - 1; error(f, 0) end
                if coroutine.status(co) == "dead" then inParallel = inParallel - 1; return i end
                filters[i] = f
            end
        end
        local nxt = table.remove(SCRIPT, 1)
        if not nxt then error("waited with no event scripted") end
        if nxt[1] == "timer" then CLK.game, CLK.real = CLK.game + CLK.last, CLK.real + CLK.last * 20 / CLK.tps end
        ev = table.pack(table.unpack(nxt))
    end
end }
local pullWas, readWas, timerWas, clockWas = os.pullEvent, read, os.startTimer, os.clock
os.pullEvent = function(filter) return coroutine.yield(filter) end
os.startTimer = function(t) CLK.last = t or 1; return 1 end
os.clock = function() return CLK.game end
-- (the goal's prompt, outside a wait, reads the scripted answers as before)
read = function()
    if inParallel == 0 then return readWas() end
    local _, line = os.pullEvent("sim_read")
    return line
end
local function timers(n) for _ = 1, n do SCRIPT[#SCRIPT + 1] = { "timer", 1 } end end

local function chatFresh()
    fresh({ "" })
    Mine.inv[2] = { name = CHAT, count = 1 }
    CHATSENT, SCRIPT = {}, {}
end
local function chatBack()
    local aboard = 0
    for s = 1, 16 do if Mine.inv[s] and Mine.inv[s].name == CHAT then aboard = aboard + Mine.inv[s].count end end
    return EQ.left == nil and EQ.right == "minecraft:diamond_pickaxe" and aboard == 1
end

chatFresh()
SCRIPT = { { "chat", "Alex", "claude no", "u-a", false }, { "chat", "Steve", "claude: the oak one", "u-s", false } }
HTTP.queue = {
    reply({ toolUse("chat", { text = "Starting the wall." }) }, "tool_use"),
    reply({ toolUse("chat", { text = "Which stair?", ask = true }) }, "tool_use"),
    reply({ text("Done.") }, "end_turn"),
}
run("talk to the player")
local c1, c2 = resultsIn(2).toolu_1, resultsIn(3).toolu_2
check("chat: said to the player through the chat box aboard, equipped for the moment and put back",
    c1 and c1.content == "said in chat" and c1.is_error == nil and CHATSENT[1] and CHATSENT[1].player == "Steve"
        and CHATSENT[1].message == "Starting the wall." and chatBack(), c1 and c1.content)
check("chat ask: the player's answer from the chat, after the prefix (another player's not taken)",
    c2 and c2.content == "Steve answered in chat: the oak one" and c2.is_error == nil
        and CHATSENT[2].message == 'Which stair? (answer in chat: "claude <your answer>")' and #SCRIPT == 0, c2 and c2.content)
check("...the chat box put back though the keyboard was still waiting, and the answer shown",
    chatBack() and Mine.logHas("^%(Steve answered in chat: the oak one%)$"))
check("...and the tool is offered: lua status run_program ask_user chat, then the API's",
    HTTP.requests[1].body.tools[5].name == "chat" and HTTP.requests[1].body.tools[5].input_schema.required[1] == "text"
        and HTTP.requests[1].body.tools[5].description:find("stops short of the cache's 5 minutes", 1, true))

-- the model writes UTF-8 (an arrow, a dash): the chat box gets it as the
-- game shows text, spelled out ("->", "--"), not as mojibake
chatFresh()
HTTP.queue = {
    reply({ toolUse("chat", { text = "Keep done: ladder \226\134\146 terrace \226\128\148 F4." }) }, "tool_use"),
    reply({ text("Done.") }, "end_turn"),
}
run("say it with an arrow")
check("chat: UTF-8 the model wrote spelled out for the game (no mojibake)",
    CHATSENT[1] and CHATSENT[1].message == "Keep done: ladder -> terrace - F4.", CHATSENT[1] and CHATSENT[1].message)

-- the player's other messages during the wait come with the next results
-- (ADR-0013 D2: T.report.ask passes them on), the answer once
chatFresh()
SCRIPT = { { "chat", "Steve", "wait, the spruce", "u-s", false }, { "chat", "Steve", "claude: oak", "u-s", false } }
HTTP.queue = {
    reply({ toolUse("chat", { text = "Which wood?", ask = true }) }, "tool_use"),
    reply({ text("Done.") }, "end_turn"),
}
run("ask about wood")
local ca, caTurn = resultsIn(2).toolu_1, select(2, resultsIn(2))
local caText = caTurn and type(caTurn.content) == "table" and caTurn.content[2] and caTurn.content[2].text or ""
check("chat ask: the player's other messages meanwhile come with the next results, the answer in the result alone",
    ca and ca.content == "Steve answered in chat: oak" and caText:find("^Steve said in chat: wait, the spruce %(at %d%d:%d%d:%d%d UTC%)$") ~= nil,
    caText)

chatFresh()
SCRIPT = { { "timer", 1 }, { "sim_read", "go left" } }
HTTP.queue = {
    reply({ toolUse("chat", { text = "Which way?", ask = true }) }, "tool_use"),
    reply({ text("Done.") }, "end_turn"),
}
run("ask at the keyboard")
local c3 = resultsIn(2).toolu_1
check("chat ask: a line typed at the keyboard answers too, and the chat box goes back",
    c3 and c3.content == "answered at the keyboard: go left" and chatBack(), c3 and c3.content)

chatFresh()
timers(270)
HTTP.queue = {
    reply({ toolUse("chat", { text = "Anyone?", ask = true }) }, "tool_use"),
    reply({ text("Done.") }, "end_turn"),
}
run("ask nobody")
local c4 = resultsIn(2).toolu_1
check("no answer: the wait stops short of the cache's 5 minutes, a normal result saying so",
    c4 and c4.is_error == nil and c4.content:find("^no answer in 270 s %(the wait stops short of the cache's 5 minutes; a longer timeout_s")
        and #SCRIPT == 0 and chatBack(), c4 and c4.content)
check("...the question said again every 2 minutes meanwhile", #CHATSENT == 3 and CHATSENT[2].message == "still waiting for an answer: Anyone?", #CHATSENT)

-- the server at 60 ticks a second (/tick rate 60): a timer of 1 s fires
-- after a third of a real one, and the wait still lasts 270 real seconds
-- (ADR-0015 D9), not the 90 that 270 one-second timers would make
chatFresh()
timers(900)
HTTP.queue = {
    reply({ toolUse("chat", { text = "Anyone, fast?", ask = true }) }, "tool_use"),
    reply({ text("Done.") }, "end_turn"),
}
CLK.tps = 60
os.epoch = function() return math.floor(CLK.real * 1000) end
CLK.realFrom, CLK.gameFrom = CLK.real, CLK.game
run("ask nobody on a fast server")
os.epoch, CLK.tps = nil, 20
check("a server at 60 ticks a second: the wait lasts 270 real seconds (810 game ones), not 90",
    resultsIn(2).toolu_1 and resultsIn(2).toolu_1.content:find("^no answer in 270 s") and CLK.real - CLK.realFrom >= 270
        and CLK.real - CLK.realFrom < 272 and CLK.game - CLK.gameFrom >= 790 and #SCRIPT > 0,
    string.format("%.1f real s, %.1f game s", CLK.real - CLK.realFrom, CLK.game - CLK.gameFrom))
check("...reminded every 2 real minutes", #CHATSENT == 3 and CHATSENT[3].message == "still waiting for an answer: Anyone, fast?", #CHATSENT)

chatFresh()
timers(3)
HTTP.queue = {
    reply({ toolUse("chat", { text = "Quick?", ask = true, timeout_s = 3 }) }, "tool_use"),
    reply({ text("Done.") }, "end_turn"),
}
run("ask quickly")
local c5 = resultsIn(2).toolu_1
check("timeout_s sets the wait", c5 and c5.content == "no answer in 3 s" and c5.is_error == nil, c5 and c5.content)

chatFresh()
timers(3)
HTTP.queue = {
    reply({ toolUse("chat", { text = "Long?", ask = true, timeout_s = 3 }) }, "tool_use"),
    reply({ text("Done.") }, "end_turn"),
}
local timeWas = os.time
local jump = 0
os.time = function(t) if t ~= nil then return timeWas(t) end jump = jump + 400; return timeWas() + jump end
run("ask for long")
os.time = timeWas
local c6 = resultsIn(2).toolu_1
check("a wait longer than the cache keeps the conversation says what it costs",
    c6 and c6.content:find("^no answer in 3 s %(that was longer than the cache keeps the conversation, 5 minutes: the next call writes it to the cache again%)$"),
    c6 and c6.content)

chatFresh()
Mine.inv[2] = nil
HTTP.queue = {
    reply({ toolUse("chat", { text = "Hello?", ask = true }) }, "tool_use"),
    reply({ toolUse("chat", { text = "Hello." }) }, "tool_use"),
    reply({ text("Done.") }, "end_turn"),
}
run("no chat box")
local c7, c8 = resultsIn(2).toolu_1, resultsIn(3).toolu_2
check("no chat box: an error result saying why, nothing waited for",
    c7 and c7.is_error == true and c7.content:find("^couldn't ask in chat: .*chat_box") and c8 and c8.is_error == true
        and c8.content:find("^not said in chat: "), c7 and c7.content)
local nlog = Mine.files["claude.log"] or ""
check("...both failures logged and shown (ADR-0013 phase 1)",
    nlog:find("chat, couldn't ask: [^\n]*chat_box") and nlog:find("chat: not said: [^\n]*chat_box")
        and Mine.logHas("^%(not said in chat: .*chat_box"), nlog)

-- with no turtle.player, the chat tool speaks to everyone (ADR-0013 D3),
-- and the session says at its start that reports go to everyone, on the
-- screen and with the first goal
chatFresh()
SET32["turtle.player"] = nil
HTTP.queue = {
    reply({ toolUse("chat", { text = "Starting." }) }, "tool_use"),
    reply({ text("Done.") }, "end_turn"),
}
run("nobody set")
SET32["turtle.player"] = "Steve"
local c9 = resultsIn(2).toolu_1
check("no player set: the chat tool speaks to everyone",
    c9 and c9.content == "said in chat" and c9.is_error == nil and CHATSENT[1] and CHATSENT[1].everyone == true
        and CHATSENT[1].message == "Starting.", c9 and c9.content)
local NOBODY = "turtle.player isn't set: reports go to everyone; `sysctl turtle.player=<name>` makes them private."
local goal9 = HTTP.requests[1] and HTTP.requests[1].body.messages[1].content or ""
check("...and the session said at its start that reports go to everyone, on the screen and with the first goal",
    goal9 == "nobody set\n\n[" .. NOBODY .. "]" and Mine.logHas("^turtle%.player isn't set: reports go to everyone"), goal9)

chatFresh()
HTTP.queue = { reply({ text("Done.") }, "end_turn") }
run("what can I say")
local sys32 = HTTP.requests[1] and HTTP.requests[1].body.system[1].text or ""
check("with turtle.player set, no such note", HTTP.requests[1] and HTTP.requests[1].body.messages[1].content == "what can I say")
check("the prompt tells of the chat tool and T.report.ask, and to ask in the game",
    sys32:find("The chat tool says something in the game's chat without code", 1, true)
        and sys32:find("T.report.ask(question, opts)", 1, true)
        and sys32:find("the chat tool with ask = true reaches the player in the game, ask_user only the keyboard", 1, true))

peripheral.wrap, peripheral.getType, peripheral.find = rawWrap, rawType, nil
os.pullEvent, read, os.startTimer, os.clock = pullWas, readWas, timerWas, clockWas
parallel, settings = nil, nil

-- 33. keeping the player told (ADR-0011 D5): after claude.remindChat
--     minutes with no chat message (from the goal's start, the last message
--     or the last reminder), a line after the tool results says so; a
--     message told (here the chat tool's) starts the count again; 0 turns
--     it off.  (Five minutes pass at each request.)
local CLOCK33, postWas, timeWas33 = 0, HTTP.api.post, os.time
HTTP.api.post = function(...) CLOCK33 = CLOCK33 + 300; return postWas(...) end
local BASE33 = timeWas33()
os.time = function(t) if t ~= nil then return timeWas33(t) end return BASE33 + CLOCK33 end
peripheral.wrap = function(side) if EQ[side] == CHAT then return chatBox end return rawWrap(side) end
peripheral.getType = function(side) if EQ[side] == CHAT then return "chat_box" end return rawType(side) end
peripheral.find = function(kind)
    for _, side in ipairs({ "left", "right" }) do
        if peripheral.getType(side) == kind then return peripheral.wrap(side) end
    end
end
local function remindRun(minutes)
    SET32 = { ["turtle.player"] = "Steve", ["claude.remindChat"] = minutes }
    settings = { define = function() end, get = function(n) return SET32[n] end }
    chatFresh()
    CLOCK33 = 0
    -- (nothing told yet: scenario 32's clock ran ahead of this one)
    if turtle._ccnixJournal then turtle._ccnixJournal.told = nil end
    HTTP.queue = {}
    for i = 1, 7 do
        HTTP.queue[i] = reply({ i == 4 and toolUse("chat", { text = "Going well." }) or toolUse("lua", { code = "return " .. i }) }, "tool_use")
    end
    HTTP.queue[8] = reply({ text("Done.") }, "end_turn")
    run("work quietly")
    local notes = {}
    for n = 2, 8 do
        local _, turn = resultsIn(n)
        for _, b in ipairs(turn.content) do
            if b.type == "text" then notes[#notes + 1] = n .. ": " .. b.text end
        end
    end
    return notes
end
local r33 = remindRun(15)
check("15 minutes with nothing told: a line after the tool results; the chat tool's message starts the count again",
    #r33 == 2 and r33[1] == "4: 15 minutes without a word to the player in chat: tell them how it is going (the chat tool, or T.report)."
        and r33[2]:find("^8: 15 minutes without a word") ~= nil, table.concat(r33, " | "))
check("...and the reminder is logged", (Mine.files["claude.log"] or ""):find("reminded: 15 minutes without a word", 1, true) ~= nil)
local r33off = remindRun(0)
check("claude.remindChat 0: no reminders", #r33off == 0, table.concat(r33off, " | "))
HTTP.api.post, os.time = postWas, timeWas33
peripheral.wrap, peripheral.getType, peripheral.find = rawWrap, rawType, nil
settings = nil
end

-- 34. the harness's own settings (ADR-0011 D10): T.cfg.maxHeight is 256 in a
--     session, unless the helpers set it otherwise, and the prompt says so;
--     a lua call with review = true is shown and asked about first, a no
--     being a normal result
do
fresh({ "n", "y", "" })
HTTP.queue = {
    reply({ toolUse("lua", { code = "return T.cfg.maxHeight" }) }, "tool_use"),
    reply({ toolUse("lua", { code = "turtle.dig(); return 'dug'", review = true }) }, "tool_use"),
    reply({ toolUse("lua", { code = "turtle.dig(); return 'dug'", review = true }) }, "tool_use"),
    reply({ text("Done.") }, "end_turn"),
}
run("climb high")
local h1, v2, v3 = resultsIn(2).toolu_1, resultsIn(3).toolu_2, resultsIn(4).toolu_3
check("T.cfg.maxHeight is 256 in a session", h1 and h1.content == "-> 256", h1 and h1.content)
check("review = true: the code shown and asked about; a no is a normal result, nothing run",
    v2 and v2.content == "not run: declined" and v2.is_error == nil and Mine.logHas("^Claude asks you to review this%. Run it%? %[y/N%]"), v2 and v2.content)
check("...and a yes runs it", v3 and v3.content == "-> dug" and DIGS == 1, v3 and v3.content)
local sys34 = HTTP.requests[1] and HTTP.requests[1].body.system[1].text or ""
local lua34 = HTTP.requests[1] and HTTP.requests[1].body.tools[1].input_schema.properties.review
check("the prompt tells of maxHeight 256 and review = true; the lua tool takes review",
    sys34:find("In this session T.cfg.maxHeight is 256", 1, true) and sys34:find("A lua call with review = true shows its code", 1, true)
        and lua34 and lua34.type == "boolean")
-- ADR-0015 D3: in a session a dig with no slot for its drop is refused, with why, not spilled; the prompt says so
fresh({ "" })
for s = 1, 16 do Mine.inv[s] = { name = "minecraft:oak_log", count = 64 } end
local digsBefore = DIGS
HTTP.queue = {
    reply({ toolUse("lua", { code = "return T.cfg.digNeedsRoom, turtle.dig()" }) }, "tool_use"),
    reply({ text("Done.") }, "end_turn"),
}
run("dig when full")
local d34 = resultsIn(2).toolu_1
check("T.cfg.digNeedsRoom in a session: a dig with every slot full is refused, saying why, nothing dug",
    d34 and d34.content:find("^%-> true\n%-> false\n%-> no room for what digging minecraft:[%w_]+ drops: every slot is full") and DIGS == digsBefore,
    d34 and d34.content)
check("...and the prompt says so", (HTTP.requests[1].body.system[1].text or ""):find("A dig with no slot for its drop is refused, not spilled", 1, true) ~= nil)
fresh({ "" })
Mine.files["claude/helpers.lua"] = "T.cfg.maxHeight = 20"
HTTP.queue = { reply({ toolUse("lua", { code = "return T.cfg.maxHeight" }) }, "tool_use"), reply({ text("Done.") }, "end_turn") }
run("not so high")
Mine.files["claude/helpers.lua"] = nil
check("...unless the helpers set it otherwise", resultsIn(2).toolu_1 and resultsIn(2).toolu_1.content == "-> 20")
-- ADR-0015 D8.7: check(code) compiles without running; helpers() says what each helper file defined, and the names T
-- has too; the lua tool says what the sandbox lacks
fresh({ "" })
Mine.files["claude/helpers.lua"] = "function digCell() end\nfunction myThing() end"
HTTP.queue = {
    reply({ toolUse("lua", { code = "ran = false\nlocal ok, err = check('x =')\nreturn ok, err, check('ran = true'), ran" }) }, "tool_use"),
    reply({ toolUse("lua", { code = "return helpers()" }) }, "tool_use"),
    reply({ text("Done.") }, "end_turn"),
}
run("what have I got")
Mine.files["claude/helpers.lua"] = nil
local ch, hp = resultsIn(2).toolu_1, resultsIn(3).toolu_2
check("check(code): nil and the error for code that doesn't compile, true for code that does, and nothing run",
    ch and ch.content:find("^%-> nil\n%-> check:1:") and ch.content:find("\n%-> true\n%-> false$") ~= nil, ch and ch.content)
check("helpers(): each helper file's globals, and the names T has too", hp
    and hp.content == "-> /claude/helpers.lua: digCell, myThing; T has digCell too", hp and hp.content)
check("...and the lua tool says what's absent and how to check code", (HTTP.requests[1].body.tools[1].description or "")
    :find("There's no load, loadstring, _G or coroutine: check(code) compiles code without running it", 1, true) ~= nil)
end

-- 35. what's new (ADR-0011 D9): claude keeps the ccnix version it last ran
--     with in /claude/.version; when ccnix was updated since, the first
--     goal carries the news file's lines for the versions after it, up to
--     the one running, and the version is written once the model has had
--     them
do
local NEWS35 = "for people\n\n== 0.52.0\nnot yet\n== 0.51.0\n-- a note for people\nT.digCell exists now: your digCell can go\n\nkeep() keeps helpers\n== 0.50.2\nT.up says why\n== 0.50.0\nold news\n"
local function newsRun(files, queue)
    fresh({ "" })
    for k, v in pairs(files) do Mine.files[k] = v end
    HTTP.queue = queue or { reply({ text("Done.") }, "end_turn") }
    run("what's new")
    local m = HTTP.requests[1] and HTTP.requests[1].body.messages[1].content
    return type(m) == "string" and m or ""
end
local n1 = newsRun({ ["deploy/version"] = "0.51.0\n", ["help/claude-news.txt"] = NEWS35, ["claude/.version"] = "0.50.0\n" })
check("updated: the first goal carries the lines for each version since, up to the running one, none for people",
    n1 == "what's new\n\n[ccnix was updated from 0.50.0 to 0.51.0; what changed for you:\n- T.digCell exists now: your digCell can go\n- keep() keeps helpers\n- T.up says why]", n1)
check("...the version kept once the model had them, and the screen and the log say so",
    Mine.files["claude/.version"] == "0.51.0\n" and Mine.logHas("^ccnix was updated from 0%.50%.0 to 0%.51%.0: Claude is told what changed%.$")
        and (Mine.files["claude.log"] or ""):find("version: 0.51.0 kept in /claude/.version", 1, true))
local n2 = newsRun({ ["deploy/version"] = "0.51.0\n", ["help/claude-news.txt"] = NEWS35, ["claude/.version"] = "0.51.0\n" })
check("the same version: nothing said", n2 == "what's new", n2)
local n3 = newsRun({ ["deploy/version"] = "0.51.0\n", ["help/claude-news.txt"] = NEWS35 })
check("no version kept yet and a news file: the newest version's lines up to the running one",
    n3 == "what's new\n\n[ccnix was updated from an earlier version to 0.51.0; what changed for you:\n- T.digCell exists now: your digCell can go\n- keep() keeps helpers]"
        and Mine.files["claude/.version"] == "0.51.0\n", n3)
local n4 = newsRun({ ["deploy/version"] = "0.51.0\n" })
check("no news file: nothing said, the version kept all the same", n4 == "what's new" and Mine.files["claude/.version"] == "0.51.0\n", n4)
local n5 = newsRun({ ["deploy/version"] = "0.51.0\n", ["help/claude-news.txt"] = NEWS35, ["claude/.version"] = "0.50.2\n" },
    { { code = 400, body = { type = "error", error = { type = "invalid_request_error", message = "nope" } } } })
check("a first goal that never reached the model: the version isn't kept, so the news comes again", Mine.files["claude/.version"] == "0.50.2\n",
    tostring(Mine.files["claude/.version"]))
-- ADR-0019: the ROM's deploy/version is read at each start, before what boot kept (a /ccnix rom update without a
-- reboot leaves ccnix.version behind); with no file to read, boot's is used
ccnix = { version = "0.51.0", find = function(rel) if fs.exists(rel) then return "/" .. rel end end }
local n7 = newsRun({ ["deploy/version"] = "0.52.0\n", ["help/claude-news.txt"] = NEWS35, ["claude/.version"] = "0.51.0\n" })
check("the ROM updated since boot (it kept 0.51.0, deploy/version says 0.52.0): the news for 0.52.0, and 0.52.0 kept",
    n7 == "what's new\n\n[ccnix was updated from 0.51.0 to 0.52.0; what changed for you:\n- not yet]"
        and Mine.files["claude/.version"] == "0.52.0\n", n7)
local n8 = newsRun({ ["help/claude-news.txt"] = NEWS35, ["claude/.version"] = "0.50.2\n" })
check("...no deploy/version to read: the version boot kept", n8:find("updated from 0.50.2 to 0.51.0;", 1, true) ~= nil, n8)
ccnix = nil
local REAL_NEWS = repoFile("help/claude-news.txt")
local n6 = newsRun({ ["deploy/version"] = "0.51.0\n", ["help/claude-news.txt"] = REAL_NEWS, ["claude/.version"] = "0.50.2\n" })
check("the real news file reads: its 0.51.0 lines, the note for people left out",
    n6:find("updated from 0.50.2 to 0.51.0; what changed for you:\n- ", 1, true) and n6:find("- The chat tool says something", 1, true)
        and not n6:find("more lines from", 1, true) and not n6:find("claude-news:", 1, true), n6)
end

-- 36. the chat listener (ADR-0012 D3, ADR-0013 D2): while the harness
--     waits for the model's reply, the chat box goes on the free side
--     (never the chunk controller's, nor another upgrade's) and the chat is
--     heard; it stays on through the code's run, the chat heard then too,
--     until the first dig (the pickaxe back on, the run carrying on, the
--     chat box on again only for the next request), run_program (the
--     pickaxe first) or the goal's end; what the player said comes with
--     the next results, or the next goal, or chatHeard() in the code; a run
--     says how long it took, and a long one when chat went unheard.  No
--     free side or no chat box: off, and the first results say why, once;
--     claude.listen = false: off, nothing said.  (A request waits for a
--     "sim_http" event here, so chat events can come meanwhile, as CC's
--     http.post pulls events; the code waits for "sim_step".)
do
local CHAT = "advancedperipherals:chat_box"
local CONTROLLER = "advancedperipherals:chunk_controller"
local MODEM = "computercraft:wireless_modem_advanced"
local PICK = "minecraft:diamond_pickaxe"
local chatBox = { sendMessage = function() return true end }
local rawWrap, rawType = peripheral.wrap, peripheral.getType
peripheral.wrap = function(side) if EQ[side] == CHAT then return chatBox end return rawWrap(side) end
peripheral.getType = function(side) if EQ[side] == CHAT then return "chat_box" end return rawType(side) end
peripheral.find = function(kind)
    for _, side in ipairs({ "left", "right" }) do
        if peripheral.getType(side) == kind then return peripheral.wrap(side) end
    end
end
local SET36 = { ["turtle.player"] = "Steve" }
settings = { define = function() end, get = function(n) return SET36[n] end }
local SCRIPT, inParallel = {}, 0
parallel = { waitForAny = function(...)
    inParallel = inParallel + 1
    local cos, filters, ev = {}, {}, { n = 0 }
    for i, f in ipairs({ ... }) do cos[i] = coroutine.create(f) end
    while true do
        for i, co in ipairs(cos) do
            if filters[i] == nil or filters[i] == ev[1] then
                local ok, f = coroutine.resume(co, table.unpack(ev, 1, ev.n))
                if not ok then inParallel = inParallel - 1; error(f, 0) end
                if coroutine.status(co) == "dead" then inParallel = inParallel - 1; return i end
                filters[i] = f
            end
        end
        local nxt = table.remove(SCRIPT, 1)
        if not nxt then error("waited with no event scripted") end
        ev = table.pack(table.unpack(nxt))
    end
end }
local pullWas, postWas = os.pullEvent, HTTP.api.post
os.pullEvent = function(filter) return coroutine.yield(filter) end
-- what was on each side while each request waited; a request in the
-- listener's parallel waits for its "sim_http" event (STOP36: Ctrl+T then)
local DURING, STOP36 = {}, false
HTTP.api.post = function(...)
    DURING[#DURING + 1] = (EQ.left or "-") .. " | " .. (EQ.right or "-")
    if inParallel > 0 then
        os.pullEvent("sim_http")
        if STOP36 then error("Terminated", 0) end
    end
    return postWas(...)
end
-- (AP 0.8's chat event: the UUID, the name, the message, hidden: AP hides one starting with $)
local function said(player, message) return { "chat", "uuid-" .. player, player, message, message:sub(1, 1) == "$" } end
local function listenFresh(left, right, box)
    fresh({ "" })
    EQ = { left = left, right = right }
    if box then Mine.inv[2] = { name = CHAT, count = 1 } end
    DURING, SCRIPT, STOP36 = {}, {}, false
end
local function textsIn(n)
    local _, turn = resultsIn(n)
    local out = {}
    for _, b in ipairs(type(turn.content) == "table" and turn.content or {}) do
        if b.type == "text" then out[#out + 1] = b.text end
    end
    return table.concat(out, " | ")
end
local function chatAboard()
    local n = 0
    for s = 1, 16 do if Mine.inv[s] and Mine.inv[s].name == CHAT then n = n + Mine.inv[s].count end end
    return n
end
local CLOCK = "%(at %d%d:%d%d:%d%d UTC%)"

listenFresh(CONTROLLER, PICK, true)
SCRIPT = { said("Steve", "claude use the oak stairs"), said("Alex", "hi all"), said("Steve", "$hidden"), { "sim_http" },
           { "sim_http" }, said("Steve", "thanks"), { "sim_http" }, { "sim_http" } }
HTTP.queue = {
    reply({ toolUse("lua", { code = "return turtle.getEquippedLeft().name, turtle.getEquippedRight().name" }) }, "tool_use"),
    reply({ toolUse("lua", { code = "return 2" }) }, "tool_use"),
    reply({ text("Done.") }, "end_turn"),
    reply({ text("Ok.") }, "end_turn"),
}
answers[1] = "next"
answers[2] = ""
run("build the stairs")
local r36 = resultsIn(2).toolu_1
check("while the model thinks the chat box is on the pickaxe's side, the controller never moves",
    DURING[1] == CONTROLLER .. " | " .. CHAT and DURING[2] == DURING[1] and DURING[3] == DURING[1], table.concat(DURING, ", "))
check("...and stays on through code that doesn't dig, the controller where it was; the pickaxe back when the goal ends",
    r36 and r36.content == "-> " .. CONTROLLER .. "\n-> " .. CHAT and chatAboard() == 1 and EQ.right == PICK and EQ.left == CONTROLLER,
    r36 and r36.content)
local t36 = textsIn(2)
check("what turtle.player said while the model thought comes with the next results (not another player's, not a hidden one)",
    t36:find("^Steve said in chat: claude use the oak stairs " .. CLOCK .. "$") ~= nil, t36)
check("...and only once: the results after have nothing heard", textsIn(3) == "", textsIn(3))
local g36 = HTTP.requests[4] and HTTP.requests[4].body.messages
local next36 = g36 and g36[#g36].content
check("heard during the last reply: it comes with the next goal",
    type(next36) == "string" and next36:find("^next\n\n%[Steve said in chat: thanks " .. CLOCK .. "%]$") ~= nil, tostring(next36))
check("...shown, and in claude.log", Mine.logHas("^%(Steve said in chat: claude use the oak stairs " .. CLOCK .. "%)$")
    and (Mine.files["claude.log"] or ""):find("heard: Steve said in chat: thanks", 1, true) ~= nil)

-- chat while code that doesn't dig runs: heard, and with the results;
-- chatHeard() takes what's heard so far (it doesn't come again)
listenFresh(CONTROLLER, PICK, true)
SCRIPT = { { "sim_http" }, said("Steve", "careful by the lava"), { "sim_step" }, said("Steve", "and now left"), { "sim_step" },
           { "sim_http" } }
HTTP.queue = {
    reply({ toolUse("lua", { code = "os.pullEvent('sim_step'); local h = chatHeard(); os.pullEvent('sim_step'); return #h, h[1]" }) }, "tool_use"),
    reply({ text("Done.") }, "end_turn"),
}
run("walk about")
local w36 = resultsIn(2).toolu_1
check("chat while the code runs is heard: chatHeard() in the code takes what's heard so far",
    w36 and w36.content:find("^%-> 1\n%-> Steve said in chat: careful by the lava " .. CLOCK .. "$") ~= nil, w36 and w36.content)
check("...the rest comes with the results, what chatHeard() took not again",
    textsIn(2):find("^Steve said in chat: and now left " .. CLOCK .. "$") ~= nil, textsIn(2))
check("...and the run says how long it took", w36 and w36.status and w36.status:find("; took 0 s%]$") ~= nil, w36 and tostring(w36.status))

-- a dig in the run: the pickaxe back on at once, the run carrying on; the
-- chat box on again only for the next request (a second run in the same
-- reply has the pickaxe); a run over a minute says when chat went unheard
listenFresh(CONTROLLER, PICK, true)
local timeWas36, sleepWas36, skipped36 = os.time, sleep, 0
os.time = function(t) if t ~= nil then return timeWas36(t) end return timeWas36() + skipped36 end
sleep = function(s) skipped36 = skipped36 + (tonumber(s) or 0) end
SCRIPT = { { "sim_http" }, said("Steve", "before the dig"), { "sim_step" }, { "sim_http" } }
HTTP.queue = {
    reply({ toolUse("lua", { code = "os.pullEvent('sim_step'); local was = turtle.getEquippedRight().name; local dug = turtle.dig(); sleep(70)"
                .. "; return was, dug, turtle.getEquippedLeft().name, turtle.getEquippedRight().name" }),
            toolUse("lua", { code = "return turtle.getEquippedRight().name" }) }, "tool_use"),
    reply({ text("Done.") }, "end_turn"),
}
run("dig one")
os.time, sleep = timeWas36, sleepWas36
local d36, d36b = resultsIn(2).toolu_1, resultsIn(2).toolu_2
check("a dig mid-run: the pickaxe back on for it, the run carrying on, the controller where it was",
    d36 and d36.content == "-> " .. CHAT .. "\n-> true\n-> " .. CONTROLLER .. "\n-> " .. PICK, d36 and d36.content)
check("...the chat box not on again for the next run in the same reply, but for the next request",
    d36b and d36b.content == "-> " .. PICK and DURING[2] == CONTROLLER .. " | " .. CHAT, (d36b and d36b.content or "") .. " " .. table.concat(DURING, ", "))
check("...what was heard before the dig comes with the results",
    textsIn(2):find("^Steve said in chat: before the dig " .. CLOCK .. "$") ~= nil, textsIn(2))
check("...and a run over a minute says how long, and that chat went unheard after the dig",
    d36 and d36.status and d36.status:find("; took 70 s, chat not heard for the last 70 s %(the pickaxe went back on for a dig%)%]$") ~= nil,
    d36 and tostring(d36.status))

-- run_program: the pickaxe back on before the program runs
listenFresh(CONTROLLER, PICK, true)
Mine.files["turtle/mine.lua"] = "-- mine"
local progEQ
local shellRunWas, ioWas36 = shell.run, io
io = setmetatable({ stdout = false }, { __index = ioWas36 })
shell.run = function() progEQ = (EQ.left or "-") .. " | " .. (EQ.right or "-"); return true end
SCRIPT = { { "sim_http" }, { "sim_http" } }
HTTP.queue = { reply({ toolUse("run_program", { program = "mine", args = "3 3 8" }) }, "tool_use"), reply({ text("Done.") }, "end_turn") }
run("mine a little")
shell.run, io = shellRunWas, ioWas36
check("run_program: the pickaxe back on before the program runs, the controller where it was",
    progEQ == CONTROLLER .. " | " .. PICK and DURING[1] == CONTROLLER .. " | " .. CHAT and DURING[2] == DURING[1], tostring(progEQ))

-- ADR-0019: the model's code equips a modem by hand over the listening chat box; at the goal's end the put-back
-- leaves the modem on, and the next goal is told the pickaxe couldn't go back
listenFresh(CONTROLLER, PICK, true)
Mine.inv[3] = { name = MODEM, count = 1 }
SCRIPT = { { "sim_http" }, { "sim_http" }, { "sim_http" } }
HTTP.queue = {
    reply({ toolUse("lua", { code = "turtle.select(3); turtle.equipRight(); return turtle.getEquippedRight().name" }) }, "tool_use"),
    reply({ text("Done.") }, "end_turn"),
    reply({ text("Ok.") }, "end_turn"),
}
answers[1] = "next"
answers[2] = ""
run("put the modem on")
local g36m = HTTP.requests[3] and HTTP.requests[3].body.messages
local next36m = g36m and g36m[#g36m].content
local NOTBACK = "when it was to be put back, the right side held the " .. MODEM .. ", not the " .. CHAT .. " put on: left as it was, and the " .. PICK
    .. " not put back"
check("a modem equipped by hand over the listening chat box stays on at the goal's end; the pickaxe stays in the inventory",
    EQ.left == CONTROLLER and EQ.right == MODEM and chatAboard() == 1 and Mine.inv[2] and Mine.inv[2].name == PICK, tostring(EQ.right))
check("...the next goal is told the pickaxe couldn't go back, and the log says so",
    type(next36m) == "string" and next36m:find("[After listening to the chat: " .. NOTBACK .. "; the right side holds the " .. MODEM .. " now]", 1, true) ~= nil
        and (Mine.files["claude.log"] or ""):find("listener: " .. NOTBACK, 1, true) ~= nil, tostring(next36m))

-- (#344) the field's case: the modem put on by hand over the chat box, then a dig.  The dig's put-back finds the modem
-- there (the line says so, as it was then), and the dig with no pickaxe on puts the pickaxe on (T.cfg.equipToDig): the
-- note the model reads says what the side holds when it reads it, not the modem
listenFresh(CONTROLLER, PICK, true)
Mine.inv[3] = { name = MODEM, count = 1 }
NEED_TOOL = true
SCRIPT = { { "sim_http" }, { "sim_http" }, { "sim_http" } }
HTTP.queue = {
    reply({ toolUse("lua", { code = "turtle.select(3); turtle.equipRight(); return turtle.dig(), turtle.getEquippedRight().name" }) }, "tool_use"),
    reply({ text("Done.") }, "end_turn"),
}
answers[1] = ""
run("dig with the modem on")
NEED_TOOL = nil
local said344 = textsIn(2)
check("a dig after a modem put on by hand: the put-back line says what the side held then, and the note what it holds now",
    said344:find("when it was to be put back, the right side held the " .. MODEM, 1, true) ~= nil
        and said344:find("; the right side holds the " .. PICK .. " now", 1, true) ~= nil and EQ.right == PICK, said344)

listenFresh(CONTROLLER, MODEM, true)
HTTP.queue = {
    reply({ toolUse("lua", { code = "return 1" }) }, "tool_use"),
    reply({ toolUse("lua", { code = "return 2" }) }, "tool_use"),
    reply({ text("Done.") }, "end_turn"),
}
run("no free side")
check("no side free of upgrades: nothing moves, the first results say why",
    DURING[1] == CONTROLLER .. " | " .. MODEM and textsIn(2) == "The chat listener is off (neither side is free (left " .. CONTROLLER
        .. ", right " .. MODEM .. "; an upgrade stays on): nowhere to put the " .. CHAT .. "): what the player says in chat isn't heard.",
    textsIn(2))
check("...once", textsIn(3) == "", textsIn(3))

listenFresh(CONTROLLER, PICK, false)
HTTP.queue = { reply({ toolUse("lua", { code = "return 1" }) }, "tool_use"), reply({ text("Done.") }, "end_turn") }
run("no chat box")
check("no chat box aboard: off, and the first results say so",
    textsIn(2) == "The chat listener is off (no " .. CHAT .. " on board): what the player says in chat isn't heard.", textsIn(2))

listenFresh(CONTROLLER, PICK, true)
SET36["claude.listen"] = false
HTTP.queue = { reply({ toolUse("lua", { code = "return 1" }) }, "tool_use"), reply({ text("Done.") }, "end_turn") }
run("not listening")
SET36["claude.listen"] = nil
check("claude.listen = false: nothing swapped, nothing said", DURING[1] == CONTROLLER .. " | " .. PICK and textsIn(2) == "", textsIn(2))

listenFresh(CONTROLLER, PICK, true)
STOP36 = true
SCRIPT = { { "sim_http" } }
HTTP.queue = { reply({ text("Never.") }, "end_turn") }
run("stopped while it thinks")
check("Ctrl+T while the model thinks: the pickaxe is put back", EQ.left == CONTROLLER and EQ.right == PICK and chatAboard() == 1,
    tostring(EQ.right))

listenFresh(CONTROLLER, PICK, true)
HTTP.queue = { reply({ text("Done.") }, "end_turn") }
SCRIPT = { { "sim_http" } }
run("what do you hear")
local sys36 = HTTP.requests[1] and HTTP.requests[1].body.system[1].text or ""
check("the prompt says what the player says comes with the next results, while it thinks and while the code runs until a dig, and chatHeard()",
    sys36:find("What they say in chat comes with your next results: a chat box aboard listens on the pickaxe's side while you think and while your code runs", 1, true) ~= nil
        and sys36:find("chatHeard()", 1, true) ~= nil and not sys36:find("is missed", 1, true))

peripheral.wrap, peripheral.getType, peripheral.find = rawWrap, rawType, nil
os.pullEvent, HTTP.api.post = pullWas, postWas
parallel, settings = nil, nil
end

-- 37. resuming after a reboot (ADR-0012 D4): while a goal is under way
--     /claude/resume.txt holds the session's options and the goal, and
--     it's gone when the goal ends or Ctrl+T stops claude; --resume starts
--     a new conversation telling the model it was interrupted, with the
--     file's goal (what the model added too) and options, and keeps the
--     file as it was; with no file it says so and asks for a goal
do
fresh({ "" })
HTTP.queue = {
    reply({ toolUse("lua", { code = "local f = fs.open('claude/resume.txt', 'r'); local s = f.readAll(); f.close(); return s" }) }, "tool_use"),
    reply({ text("Done.") }, "end_turn"),
}
run("dig the tunnel", "--steps", "400", "--cache", "1h")
local k1 = resultsIn(2).toolu_1
check("a goal under way: /claude/resume.txt holds the options given and the goal",
    k1 and k1.content == "-> options: --steps 400 --cache 1h\ndig the tunnel\n", k1 and k1.content)
check("...and it's gone when the goal ends", Mine.files["claude/resume.txt"] == nil)

fresh({ "" })
Mine.files["claude/resume.txt"] = "options: --steps 3 --cache 1h\ndig the tunnel\nat 0,0,5, 12 blocks left\n"
HTTP.queue = {
    reply({ toolUse("lua", { code = "local f = fs.open('claude/resume.txt', 'r'); local s = f.readAll(); f.close(); return s" }) }, "tool_use"),
    reply({ text("Carried on.") }, "end_turn"),
}
run("--resume")
local m37 = HTTP.requests[1] and HTTP.requests[1].body
check("--resume: a new conversation whose first message says it was interrupted, with the file's goal and notes",
    m37 and #m37.messages == 1 and m37.messages[1].content
        == "You were interrupted (reboot); read your memory and resume: dig the tunnel\nat 0,0,5, 12 blocks left", m37 and m37.messages[1].content)
check("...with the options the file kept (steps 3, cache 1h)", m37 and m37.cache_control.ttl == "1h"
    and (Mine.files["claude.log"] or ""):find("start: claude --steps 3 --cache 1h (model claude-opus-5-5, effort medium, steps 3, cache 1h;", 1, true),
    (Mine.files["claude.log"] or ""):sub(1, 200))
-- (#404: the start line said nothing of where those options came from)
check("...and the start line says they came from resume.txt",
    (Mine.files["claude.log"] or ""):find("; resuming the goal in resume.txt, with its options: --steps 3 --cache 1h\n", 1, true),
    (Mine.files["claude.log"] or ""):match("start: [^\n]*"))
local k2 = resultsIn(2).toolu_1
check("...the file kept as it was meanwhile (not the interrupted message), and gone at the end",
    k2 and k2.content == "-> options: --steps 3 --cache 1h\ndig the tunnel\nat 0,0,5, 12 blocks left\n" and Mine.files["claude/resume.txt"] == nil,
    k2 and k2.content)

fresh({ "" })
Mine.files["claude/resume.txt"] = "options: --steps 3\ndig the tunnel\n"
HTTP.queue = { reply({ text("Ok.") }, "end_turn") }
run("--resume", "--steps", "9")
check("--resume: options given on the command line win over the file's",
    (Mine.files["claude.log"] or ""):find("steps 9, cache 5m", 1, true) ~= nil)

fresh({ "" })
Mine.files["claude/resume.txt"] = "dig the tunnel, rewritten\n"
HTTP.queue = { reply({ text("Ok.") }, "end_turn") }
run("--resume")
local m37b = HTTP.requests[1] and HTTP.requests[1].body.messages[1].content
check("--resume with the options line gone: the whole file is the goal",
    m37b == "You were interrupted (reboot); read your memory and resume: dig the tunnel, rewritten", tostring(m37b))

fresh({ "" })
run("--resume")
check("--resume with nothing kept: it says so, asks for a goal, and sends nothing",
    #HTTP.requests == 0 and Mine.logHas("^Nothing to resume: /claude/resume%.txt isn't there%.$") and Mine.logHas("^Goal: $"))

fresh({ "" })
HTTP.queue = { reply({ toolUse("lua", { code = "error('Terminated', 0)" }) }, "tool_use") }
run("dig until stopped")
check("Ctrl+T: the player's stop, so nothing is left to resume", Mine.files["claude/resume.txt"] == nil and #HTTP.requests == 1)

fresh({ "" })
HTTP.queue = { reply({ text("Ok.") }, "end_turn") }
run("what about reboots")
local sys37 = HTTP.requests[1] and HTTP.requests[1].body.system[1].text or ""
check("the prompt says /claude/resume.txt holds the goal, to add where it is",
    sys37:find("While a goal is under way /claude/resume.txt holds it, for a resume after a reboot", 1, true) ~= nil)
-- ADR-0019 (G10: the model asked for a reboot and ended its reply, which ended the goal and deleted the file)
check("...that the file is the harness's, lines added under its first; and that ending a reply ends the goal and deletes it,"
        .. " so a planned reboot stays in the goal",
    sys37:find("The file is the harness's: add lines under its first, never rewrite it", 1, true) ~= nil
        and sys37:find("Ending your reply ends the goal and deletes the file: for a planned reboot, stay in the goal (a chat ask, or a call that waits)", 1, true) ~= nil)
end

-- 38. how much log is kept (ADR-0012 D5): past claude.logSize the log
--     moves to claude.log.1, the older ones up to claude.log.<logKeep>
--     (default 3); on a small disk old ones go, oldest first, until a
--     quarter of it is free beside turtlelib's map (.map/); the current
--     log never goes.  (The mock disk counts the logs and the map alone.)
do
local SET38 = { ["claude.logSize"] = 600 }
settings = { define = function() end, get = function(n) return SET38[n] end }
local CAP38
fs.getCapacity = function() return CAP38 end
fs.getFreeSpace = function()
    local used = 0
    for name, data in pairs(Mine.files) do
        if name:find("^claude%.log") or name:find("^%.map/") then used = used + #data end
    end
    return CAP38 - used
end
-- eight calls, each result 400 of its own letter: a to h
local function logRun(map)
    fresh({ "" })
    if map then Mine.files[".map/0_0_0"] = string.rep("m", map) end
    HTTP.queue = {}
    for i = 1, 8 do
        HTTP.queue[i] = reply({ toolUse("lua", { code = "return string.rep('" .. string.char(96 + i) .. "', 400)" }) }, "tool_use")
    end
    HTTP.queue[9] = reply({ text("Done.") }, "end_turn")
    run("fill the logs")
end
-- the old logs there are (1, 2, ...), and the first letter run in each
local function olds()
    local n, firsts = 0, {}
    while Mine.files["claude.log." .. (n + 1)] do
        n = n + 1
        firsts[n] = Mine.files["claude.log." .. n]:match("%-> (%l)%l%l%l") or "?"
    end
    return n, table.concat(firsts)
end

CAP38 = 1000000
logRun()
local n1, f1 = olds()
check("claude.logKeep 3 by default: claude.log, .1, .2 and .3, the newest first", n1 == 3 and f1 > "" and f1:sub(1, 1) > f1:sub(3, 3)
    and Mine.files["claude.log"] ~= nil, n1 .. " " .. f1)

SET38["claude.logKeep"] = 1
logRun()
local n2 = olds()
check("claude.logKeep 1: one old copy, as before", n2 == 1, n2)
SET38["claude.logKeep"] = nil

CAP38 = 6000
logRun(2500)
local n3 = olds()
check("a small disk: fewer old logs, so a quarter stays free beside the map",
    n3 >= 1 and n3 < 3 and fs.getFreeSpace() >= CAP38 / 4, n3 .. " kept, " .. fs.getFreeSpace() .. " free")

logRun(5000)
local n4 = olds()
check("the map alone leaves less than a quarter free: every old log goes, the current one stays",
    n4 == 0 and Mine.files["claude.log"] ~= nil and Mine.files[".map/0_0_0"] ~= nil, n4)
fs.getCapacity, fs.getFreeSpace = nil, nil
settings = nil
end

-- 39. the prompt (ADR-0012 phase 1): the settings a session should have
--     (T.keep, T.cfg) are kept in a keep() helper, since a session starts
--     with turtlelib's defaults
do
fresh({ "" })
HTTP.queue = { reply({ text("Ok.") }, "end_turn") }
run("keep my settings")
local sys39 = HTTP.requests[1] and HTTP.requests[1].body.system[1].text or ""
check("the prompt says to keep T.keep and T.cfg settings in a keep() helper",
    sys39:find("Settings every session should have (T.keep items, T.cfg values, T.diggable) go in a keep() helper too", 1, true) ~= nil)
end

-- 40. large notes (ADR-0013 phase 1, D9): memory over 32 KB in all (its
--     folders counted) at a session's start is its first task, a goal of
--     the harness's before the player's: notes.md rewritten as the current
--     state (about 12 KB), the rest moved to /claude/notes-archive/<the
--     day>.md; the player's goal then starts a conversation of its own,
--     told the notes were tidied; after /new it's a note, saying what they
--     cost and where the old goes; under 32 KB, neither
do
fresh({ "/new", "again", "" })
fs.makeDir("claude/memories")
fs.makeDir("claude/memories/old")
Mine.files["claude/memories/notes.md"] = string.rep("x", 30 * 1024)
Mine.files["claude/memories/old/done.md"] = string.rep("y", 10 * 1024)
HTTP.queue = { reply({ text("Tidied.") }, "end_turn"), reply({ text("Ok.") }, "end_turn"), reply({ text("Ok.") }, "end_turn") }
run("tidy up")
local tidy40 = HTTP.requests[1] and HTTP.requests[1].body.messages[1].content or ""
check("memory over 32 KB: the session's first task is to tidy it, before the player's goal",
    tidy40:find("^A task from the harness, before the player's next goal: tidy your notes%. /memories holds 40 KB, about 14k tokens on every call")
        and tidy40:find("Rewrite /memories/notes.md as the current state, about 12 KB", 1, true)
        and tidy40:find("to /claude/notes-archive/" .. os.date("!%Y-%m-%d") .. ".md with fs", 1, true)
        and #HTTP.requests[1].body.messages == 1, tidy40:sub(1, 60))
check("...and the screen says so", Mine.logHas("^Your notes in /memories are 40 KB, about 14k tokens on every call once viewed: .* Claude tidies them first%.$"))
local goal40 = HTTP.requests[2] and HTTP.requests[2].body.messages or {}
check("...then the player's goal starts a conversation of its own, told the notes were tidied",
    #goal40 == 1 and goal40[1].content == "tidy up\n\n[Your notes were tidied in a conversation before this one, which was put aside: view /memories afresh.]",
    goal40[1] and goal40[1].content)
check("...logged", (Mine.files["claude.log"] or ""):find("\n[^\n]* tidy done: %[") ~= nil)
local NOTE40 = "Your notes in /memories are 40 KB, about 14k tokens on every call once viewed: move what you no longer need to an archive file outside /memories (under /claude/, read with fs when it's wanted)."
local new40 = HTTP.requests[3] and HTTP.requests[3].body.messages[1].content or ""
check("...and after /new, a note with the first goal", new40:sub(-#NOTE40 - 1) == NOTE40 .. "]", new40)

fresh({ "" })
fs.makeDir("claude/memories")
Mine.files["claude/memories/notes.md"] = string.rep("x", 20 * 1024)
HTTP.queue = { reply({ text("Ok.") }, "end_turn") }
run("small notes")
check("...under it, no tidy and no note", #HTTP.requests == 1 and HTTP.requests[1].body.messages[1].content == "small notes")

-- /tidy at the prompt: the same task, on demand, in the conversation as it is
fresh({ "/tidy", "" })
HTTP.queue = { reply({ text("Ok.") }, "end_turn"), reply({ text("Tidied.") }, "end_turn") }
run("small notes")
local m2 = HTTP.requests[2] and HTTP.requests[2].body.messages or {}
check("/tidy: the harness's tidy task as the next goal, in the same conversation",
    #m2 == 3 and type(m2[3].content) == "string" and m2[3].content:find("^A task from the harness, before the player's next goal: tidy your notes%."),
    m2[3] and tostring(m2[3].content):sub(1, 60))
end

-- 41. the prompt and the manual (ADR-0013 phase 2): what a turtle can't
--     do and the player tests, a block put back with T.placeAt, a why
--     read whole before it's shortened, notes kept short; the index's
--     lines for T.moveTo's path and T.inspectAll
do
fresh({ "" })
HTTP.queue = { reply({ text("Ok.") }, "end_turn") }
run("what can't I do")
local sys41 = HTTP.requests[1] and HTTP.requests[1].body.system[1].text or ""
check("the prompt: no doors, buttons, repeater delays or portals for a turtle: the player tests them",
    sys41:find("A turtle can't open doors or trapdoors, press buttons, set a repeater's delay or pass a nether portal", 1, true) ~= nil)
check("...a block put back with T.placeAt, not placed up from the hole",
    sys41:find("put a block back with T.placeAt", 1, true) ~= nil)
check("...a why read whole before it's shortened",
    sys41:find("read the whole why before you shorten it", 1, true) ~= nil)
check("...notes kept short, the old outside /memories",
    sys41:find("the old moved to an archive file outside /memories", 1, true) ~= nil)
check("the manual's overview says what a turtle can't do",
    REAL_MANUAL:find("A turtle can't open doors or trapdoors, press buttons, set a repeater's delay or pass a nether portal", 1, true) ~= nil)
check("the index: T.moveTo's path = true said plainly, T.inspectAll as the way to block states over an area",
    sys41:find("\nT%.moveTo%(x, y, z, opts%) %- [^\n]*path = true hands a blocked run to T%.travel")
        and sys41:find("\nT%.inspectAll%(list, opts%) %- [^\n]*the way to get block states over an area %(T%.scan gives names only%)"))
end

-- The calls' usage for the scenarios on compaction: n tokens in, all but
-- 100 of them read from the cache
local function inTokens(n)
    return { usage = { input_tokens = 100, output_tokens = 20, cache_read_input_tokens = n - 100, cache_creation_input_tokens = 0 } }
end
-- The compaction block request n starts with, or nil
local function blockOf(n)
    local first = HTTP.requests[n] and HTTP.requests[n].body.messages[1]
    local b = first and type(first.content) == "table" and first.content[1]
    return b and b.type == "compaction" and b or nil, first
end
local function hasBeta(n)
    local h = HTTP.requests[n] and HTTP.requests[n].headers or {}
    return tostring(h["anthropic-beta"] or ""):find("compact-2026-09-04", 1, true) ~= nil
end

-- 42. context editing for the cache (ADR-0013 D1, as D9 amends it): every
--     request keeps all thinking and clears no tool call, up to the 150k
--     where a goal is summarized (ADR-0015 D7)
--     (D1's mark is gone: compaction keeps the conversation in bounds, 44;
--     the deep clear stands in when no summary comes, 45; the hard clear
--     is 3c's)
do
fresh({ "and more", "" })
HTTP.queue = {
    reply({ toolUse("lua", { code = "return 1" }) }, "tool_use", inTokens(120000)),
    reply({ toolUse("lua", { code = "return 2" }) }, "tool_use", inTokens(135000)),
    reply({ toolUse("lua", { code = "return 3" }), toolUse("memory", { command = "view", path = "/memories" }) }, "tool_use", inTokens(148000)),
    reply({ text("Done.") }, "end_turn", inTokens(99000)),
    reply({ text("More.") }, "end_turn", inTokens(99500)),
}
run("grow")
local keepsAll = true
for n = 1, 5 do
    local e = HTTP.requests[n] and HTTP.requests[n].body.context_management.edits or {}
    keepsAll = keepsAll and #e == 1 and e[1].type == "clear_thinking_20251015" and e[1].keep == "all"
end
check("every request keeps all thinking and clears no tool call, at 135k and 148k too", keepsAll and #HTTP.requests == 5,
    #HTTP.requests)
check("...and no deep clear is logged", not (Mine.files["claude.log"] or ""):find("deep clear", 1, true))
end

-- 43. compaction at a goal's end (ADR-0013 D9): a goal that ends with the
--     last call's input over 100k has the conversation summarized before
--     the next goal is sent: a request of its own, the conversation as it
--     stands with our summary prompt (no tool calls, text only), several
--     thousand tokens, no context edits, the beta header; the next goal's
--     request starts with the block, an assistant message of its own with
--     the cache's mark after it, in place of all it summarized; later
--     requests carry the header too; compacting again starts from the
--     block, and only the newest is sent; under 100k, none; logged
do
fresh({ "and the next", "and a third", "" })
HTTP.queue = {
    reply({ toolUse("lua", { code = "return 1" }) }, "tool_use", inTokens(90000)),
    reply({ text("Done.") }, "end_turn", inTokens(120000)),
    M.compactionReply("Summary one: dug at 0,0,2."),
    reply({ text("Next done.") }, "end_turn", inTokens(130000)),
    M.compactionReply("Summary two: one and the next."),
    reply({ text("Third done.") }, "end_turn", inTokens(50000)),
}
run("grow big")
local c3 = HTTP.requests[3] and HTTP.requests[3].body or {}
check("a goal ending over 100k: the next request is a compaction of the conversation as it stands (4 messages, the last the reply)",
    c3.compaction and c3.compaction.type == "summarize" and #c3.messages == 4 and c3.messages[4].role == "assistant"
        and c3.messages[1].content == "grow big", textutils.serialiseJSON(c3.compaction or {}))
check("...with our own summary prompt: the goal, the player's words, places, lessons, helpers and skills; no tool calls, text only",
    c3.compaction and c3.compaction.instructions:find("the player's own words", 1, true) and c3.compaction.instructions:find("coordinates", 1, true)
        and c3.compaction.instructions:find("lessons and mistakes", 1, true) and c3.compaction.instructions:find("skills", 1, true)
        and c3.compaction.instructions:find("what's new in this release", 1, true)
        and c3.compaction.instructions:find("Do not call any tool: answer with the summary text only.", 1, true) and #c3.compaction.instructions <= 16384)
check("...the same model, system prompt, tools and thinking; several thousand tokens; no context edits, no fallback model; the beta header",
    c3.model == HTTP.requests[2].body.model and c3.system[1].text == HTTP.requests[2].body.system[1].text
        and #c3.tools == #HTTP.requests[2].body.tools and c3.thinking.type == "adaptive" and c3.max_tokens == 16000
        and c3.context_management == nil and c3.fallbacks == nil and hasBeta(3) and not hasBeta(2), tostring(c3.max_tokens))
local b4, first4 = blockOf(4)
local m4 = HTTP.requests[4] and HTTP.requests[4].body.messages or {}
check("the next goal's request starts with the block, as returned, an assistant message of its own, the cache's mark after it; then the goal alone",
    b4 and b4.content == "Summary one: dug at 0,0,2." and b4.signature == "csig" and #first4.content == 1 and first4.role == "assistant"
        and b4.cache_control and b4.cache_control.type == "ephemeral" and #m4 == 2 and m4[2].role == "user"
        and m4[2].content == "and the next", textutils.serialiseJSON(m4))
check("...with the beta header, and its usual context edit (all thinking kept)", hasBeta(4)
    and HTTP.requests[4].body.context_management.edits[1].keep == "all")
local c5 = HTTP.requests[5] and HTTP.requests[5].body or {}
check("compacting again: the request starts with the current block and has the rest after it",
    c5.compaction and blockOf(5) and blockOf(5).content == "Summary one: dug at 0,0,2." and #c5.messages == 3, #(c5.messages or {}))
local m6 = HTTP.requests[6] and HTTP.requests[6].body.messages or {}
local blocks6 = 0
for _, m in ipairs(m6) do
    for _, b in ipairs(type(m.content) == "table" and m.content or {}) do if b.type == "compaction" then blocks6 = blocks6 + 1 end end
end
check("...and then only the newest block is sent", blocks6 == 1 and blockOf(6) and blockOf(6).content == "Summary two: one and the next."
    and #m6 == 2 and hasBeta(6), blocks6)
check("a goal ending under 100k: no compaction (six calls in all)", #HTTP.requests == 6, #HTTP.requests)
local log43 = Mine.files["claude.log"] or ""
check("the log: what was compacted and into what",
    log43:find("compacting at a goal's end: 4 messages, 0 kept as they are; the last call had 120000 tokens in", 1, true)
        and log43:find("compacted: 4 messages into a summary of 1200 tokens (26 characters); the call read 95000 tokens, 90000 of them from the cache", 1, true),
    log43:match("compacted[^\n]*"))
check("...and the summary call's tokens counted in the session's (210040, then its 96200, then 130020: 436260)",
    Mine.logHas("^%[130000 tokens in: 129900 from the cache, 0 written to it, 100 new; 20 out; 436260 in all%]"))
check("...and the screen says it's summarized while the player types", Mine.logHas("^%(the conversation, 120k tokens, is summarized while you type%)"))
end

-- 43b. the summary at a goal's end runs beside the prompt (CC's parallel:
--      each scripted event goes to the routines waiting for it; read()
--      waits for "sim_read", the summary's request for "sim_http"): the
--      player typing first has their goal wait for the summary and go
--      after it; the summary done first, the prompt goes on; a /new isn't
--      kept waiting (nothing more is sent for it).  And a goal that ended
--      on a reply with a tool call (a second cut-off) leaves that turn out
--      of the summary, kept after the block, its call answered.
do
local SCRIPT, inParallel, ORDER = {}, 0, {}
parallel = { waitForAny = function(...)
    inParallel = inParallel + 1
    local cos, filters, ev = {}, {}, { n = 0 }
    for i, f in ipairs({ ... }) do cos[i] = coroutine.create(f) end
    while true do
        for i, co in ipairs(cos) do
            if filters[i] == nil or filters[i] == ev[1] then
                local ok, f = coroutine.resume(co, table.unpack(ev, 1, ev.n))
                if not ok then inParallel = inParallel - 1; error(f, 0) end
                if coroutine.status(co) == "dead" then inParallel = inParallel - 1; return i end
                filters[i] = f
            end
        end
        local nxt = table.remove(SCRIPT, 1)
        if not nxt then error("waited with no event scripted") end
        ev = table.pack(table.unpack(nxt))
    end
end }
local pullWas, readWas, postWas = os.pullEvent, read, HTTP.api.post
os.pullEvent = function(filter) return coroutine.yield(filter) end
peripheral.find = function() return nil end         -- (no chat box: the listener has nothing to do)
read = function()
    if inParallel == 0 then return readWas() end
    local _, line = os.pullEvent("sim_read")
    ORDER[#ORDER + 1] = "typed"
    return line
end
HTTP.api.post = function(...)
    if inParallel > 0 then
        os.pullEvent("sim_http")
        ORDER[#ORDER + 1] = "summarized"
    end
    return postWas(...)
end
local function big(n) return reply({ text("Done.") }, "end_turn", inTokens(n)) end

fresh({ "" })
SCRIPT, ORDER = { { "sim_read", "the next goal" }, { "sim_http" } }, {}
HTTP.queue = { big(120000), M.compactionReply("S1."), big(50000) }
run("typed first")
local m3 = HTTP.requests[3] and HTTP.requests[3].body.messages or {}
check("the player typing first: their goal waits for the summary, then goes after it",
    table.concat(ORDER, " ") == "typed summarized" and HTTP.requests[2].body.compaction and blockOf(3)
        and m3[2] and m3[2].content:sub(1, 15) == "the next goal\n\n", table.concat(ORDER, " "))

fresh({ "" })
SCRIPT, ORDER = { { "sim_http" }, { "sim_read", "go on" } }, {}
HTTP.queue = { big(120000), M.compactionReply("S1."), big(50000) }
run("summary first")
check("the summary done first: the prompt goes on, and the goal goes after it",
    table.concat(ORDER, " ") == "summarized typed" and blockOf(3) and #HTTP.requests == 3, table.concat(ORDER, " "))

fresh({ "", "" })
SCRIPT, ORDER = { { "sim_read", "/new" } }, {}
HTTP.queue = { big(120000) }
run("then new")
check("a /new isn't kept waiting for the summary, and nothing is sent for it",
    #HTTP.requests == 1 and table.concat(ORDER, " ") == "typed" and Mine.logHas("^A new conversation"), #HTTP.requests)

os.pullEvent, read, HTTP.api.post = pullWas, readWas, postWas
parallel, peripheral.find = nil, nil

fresh({ "go on", "" })
local cutUsage = inTokens(120000)
cutUsage.usage.output_tokens = 64000
HTTP.queue = {
    reply({ toolUse("lua", { code = "return 1" }) }, "max_tokens", cutUsage),
    reply({ toolUse("lua", { code = "return 2" }) }, "max_tokens", cutUsage),
    M.compactionReply("S2."),
    big(50000),
}
run("cut twice")
local c3b = HTTP.requests[3] and HTTP.requests[3].body or {}
local m4b = HTTP.requests[4] and HTTP.requests[4].body.messages or {}
local kept4 = m4b[2] and m4b[2].content or {}
local answered = m4b[3] and type(m4b[3].content) == "table" and m4b[3].content[1] or {}
check("a goal ended on a tool call: the summary leaves that turn out, kept after the block, its call answered with the next goal",
    c3b.compaction and #c3b.messages == 3 and blockOf(4) and m4b[2].role == "assistant" and kept4[1] and kept4[1].type == "tool_use"
        and answered.type == "tool_result" and answered.tool_use_id == kept4[1].id and answered.is_error == true,
    #(c3b.messages or {}))
end

-- 44. compaction inside a goal (ADR-0013 D9; 150k since ADR-0015 D7): once a call's input reaches
--     150k, right after its tool results the conversation is summarized
--     but for the last 3 turns (a reply and its results each): the
--     compaction request ends where an earlier request ended (results, not
--     a reply waiting on them); the next request is the block, then the
--     kept turns word for word (their thinking too), nothing else; the
--     goal carries on; compacting again in the goal sends only the newest
--     block; under 150k in a goal, none; logged and shown
do
fresh({ "" })
local function step(n, at) return reply({ thinking(), toolUse("lua", { code = "return " .. n }) }, "tool_use", inTokens(at)) end
HTTP.queue = {
    step(1, 100000), step(2, 120000), step(3, 140000), step(4, 155000),
    M.compactionReply("Mid summary."),
    step(5, 160000),
    M.compactionReply("Mid two."),
    reply({ text("Done.") }, "end_turn", inTokens(42000)),
}
run("long job")
local c5 = HTTP.requests[5] and HTTP.requests[5].body or {}
local last5 = c5.messages and c5.messages[#c5.messages] or {}
check("under 150k in a goal no compaction; at 155k one, right after that call's results",
    c5.compaction and not HTTP.requests[4].body.compaction and #HTTP.requests == 8, #HTTP.requests)
check("...of what came before the last 3 turns: the goal and the first turn, ending on its results",
    #(c5.messages or {}) == 3 and last5.role == "user" and type(last5.content) == "table" and last5.content[1].type == "tool_result"
        and last5.content[1].tool_use_id == "toolu_1", #(c5.messages or {}))
local m6 = HTTP.requests[6] and HTTP.requests[6].body.messages or {}
local was = HTTP.requests[5].body.messages        -- (the turns as they were sent before)
local r4 = HTTP.requests[4].body.messages
check("the next request: the block, then the 3 turns as they were, thinking and all, then nothing else",
    blockOf(6) and blockOf(6).content == "Mid summary." and #m6 == 7 and m6[2].role == "assistant"
        and m6[2].content[1].type == "thinking" and m6[2].content[1].signature == "sig" and m6[2].content[2].id == "toolu_2"
        and textutils.serialiseJSON(m6[3]) == textutils.serialiseJSON(r4[3 + 2])
        and m6[7].role == "user" and m6[7].content[1].tool_use_id == "toolu_4" and hasBeta(6), #m6)
local c7 = HTTP.requests[7] and HTTP.requests[7].body or {}
check("compacting again in the goal: from the block on, the last 3 turns kept; then only the newest block",
    c7.compaction and blockOf(7) and blockOf(7).content == "Mid summary." and #c7.messages == 3
        and blockOf(8) and blockOf(8).content == "Mid two." and #HTTP.requests[8].body.messages == 7, #(c7.messages or {}))
local log44 = Mine.files["claude.log"] or ""
check("logged: where it was compacted, what was kept, and what came of it",
    log44:find("compacting at a goal's middle: 3 messages, 6 kept as they are; the last call had 155000 tokens in", 1, true)
        and log44:find("compacted: 3 messages into a summary of 1200 tokens (12 characters)", 1, true), log44:match("compacting[^\n]*"))
check("...and shown", Mine.logHas("^%(the conversation, 155k tokens, is summarized; the last 3 turns kept%)"))
check("the goal carried on to its end", Mine.logHas("^Done%.$"))
end

-- 45. when no summary comes (ADR-0013 D9, D1's deep clear as the
--     fallback): a summary cut off at its max_tokens is asked for again
--     with twice as many; one that brings none has the next request clear
--     deep (the thinking of all but the turn in progress, all but the last
--     6 tool calls, the memory tool's never), logged, and no second try in
--     that goal; the requests after it ask for the same clear, the counts
--     grown; a summary at a goal's end that brings none has the next
--     goal's first request clear deep
do
fresh({ "" })
local function step(n, at) return reply({ toolUse("lua", { code = "return " .. n }) }, "tool_use", inTokens(at)) end
HTTP.queue = {
    step(1, 100000),
    step(2, 255000),
    M.compactionReply(nil, nil, "max_tokens"),
    M.compactionReply("Second try."),
    reply({ text("Done.") }, "end_turn", inTokens(30000)),
}
run("cut short")
check("a summary cut off at max_tokens: asked again with twice the tokens, and that one taken",
    HTTP.requests[3].body.max_tokens == 16000 and HTTP.requests[4].body.compaction and HTTP.requests[4].body.max_tokens == 32000
        and blockOf(5) and blockOf(5).content == "Second try."
        and (Mine.files["claude.log"] or ""):find("compaction: no summary (stop_reason max_tokens); asked again with 32000 tokens", 1, true),
    tostring(HTTP.requests[4].body.max_tokens))

fresh({ "" })
local function edits45(n) return HTTP.requests[n] and HTTP.requests[n].body.context_management and HTTP.requests[n].body.context_management.edits or {} end
local function kept(n)
    local e = edits45(n)
    if not (e[1] and e[2] and type(e[1].keep) == "table") then return textutils.serialiseJSON(e) end
    return e[1].keep.value .. "/" .. e[2].keep.value
end
HTTP.queue = {}
for n = 1, 7 do HTTP.queue[n] = step(n, 100000 + n) end
HTTP.queue[8] = reply({ toolUse("lua", { code = "return 8" }), toolUse("memory", { command = "view", path = "/memories" }) }, "tool_use", inTokens(255000))
HTTP.queue[9] = M.compactionReply(nil)
HTTP.queue[10] = step(9, 256000)
HTTP.queue[11] = reply({ text("Done.") }, "end_turn", inTokens(50000))
run("no summary")
local deep = edits45(10)
check("no summary: the next request clears deep, the thinking edit first (1 turn kept), all but the last 6 tool calls, the memory tool's never",
    #deep == 2 and deep[1].keep.value == 1 and deep[2].type == "clear_tool_uses_20250919" and deep[2].keep.value == 6
        and deep[2].clear_at_least.value == 0 and deep[2].clear_tool_inputs == true and deep[2].exclude_tools[1] == "memory"
        and deep[2].trigger.value <= 255000, textutils.serialiseJSON(deep))
local log45 = Mine.files["claude.log"] or ""
check("...logged: no summary, then the deep clear",
    log45:find("compaction: no summary (stop_reason end_turn)\n", 1, true)
        and log45:find("context: a deep clear at 255000 tokens in (the last call's), as no summary came", 1, true))
check("...no second try in that goal at 256k, and the request after it asks for the same clear, a call more kept",
    #HTTP.requests == 11 and not HTTP.requests[11].body.compaction and kept(11) == "1/7", kept(11))

fresh({ "next", "" })
HTTP.queue = {}
for n = 1, 7 do HTTP.queue[n] = step(n, 50000 + n) end
HTTP.queue[8] = reply({ text("Done.") }, "end_turn", inTokens(120000))
HTTP.queue[9] = M.compactionReply(nil, nil, "refusal")
HTTP.queue[10] = reply({ text("Next done.") }, "end_turn", inTokens(30000))
run("refused summary")
check("a summary at a goal's end that brings none (a refusal): the next goal's first request clears deep",
    HTTP.requests[9].body.compaction and kept(10) == "1/6" and not blockOf(10)
        and (Mine.files["claude.log"] or ""):find("compaction: no summary (stop_reason refusal)\n", 1, true), kept(10))
end

-- 46. skills (ADR-0013 D10): the session's first message lists each skill
--     (its name, whose, its description, where), the shipped ones
--     (turtle/skills/, where ccnix's files are) and the model's own
--     (/claude/skills/), its own winning over a shipped one of the same
--     name; not the system prompt, which says how to use them; skill() in
--     the code writes one (its name and description on top) and refuses a
--     bad name, a missing or overlong description, an empty body; /skills
--     shows them; a goal sharing words with a description comes with
--     "Skills that may fit: ..." (none when nothing does); after a
--     summary the list comes again, at a goal's end with the next goal,
--     inside a goal onto the results; with ccnix's layers (ccnix.roots)
--     the updates' skill wins over the ROM's, and each layer's own show
do
local function skillFile(path, name, description)
    local dir = path .. "/" .. name
    fs.makeDir(path)
    fs.makeDir(dir)
    Mine.files[dir .. "/skill.md"] = "---\nname: " .. name .. "\ndescription: " .. description .. "\n---\n# " .. name .. "\n1. Do it.\n"
end
local function shipped()
    skillFile("turtle/skills", "storage", "Set up and keep the chests at home: categories, sorting, stowing.")
    skillFile("turtle/skills", "light-an-area", "Light a place so mobs can't spawn.")
    skillFile("turtle/skills", "build-for-player", "\"Stairs, walkways and rooms a two-tall player uses.\"")
    Mine.files["turtle/skills/readme.md"] = "# Skills for claude\n"
end
fresh({ "/skills", "light the farm", "" })
shipped()
fs.makeDir("claude")
skillFile("claude/skills", "light-an-area", "Use when lighting a farm or a base: my own way.")
HTTP.queue = {
    reply({ toolUse("lua", { code = [[
local out = {}
local function try(...) local ok, a, b = pcall(skill, ...); out[#out + 1] = tostring(ok) .. " " .. tostring(a) .. " " .. tostring(b) end
try("dig-stairs", "Use when digging a staircase down.", "1. Dig.\n2. Place stairs.")
try("Bad Name", "Use when x.", "body")
try("ok-name", "  ", "body")
try("ok-name", string.rep("x", 201), "body")
try("ok-name", "Use when x.", "   ")
try("ok-name", "line one\nline two", "body")
return table.concat(out, "\n")]] }) }, "tool_use"),
    reply({ text("Sorted.") }, "end_turn", inTokens(120000)),
    M.compactionReply("S."),
    reply({ toolUse("lua", { code = "return 1" }) }, "tool_use", inTokens(100000)),
    reply({ toolUse("lua", { code = "return 2" }) }, "tool_use", inTokens(255000)),
    M.compactionReply("S2."),
    reply({ text("Lit.") }, "end_turn", inTokens(30000)),
}
run("sort the chests")
local first = HTTP.requests[1] and HTTP.requests[1].body.messages[1].content or ""
local LIST = "Your skills, procedures for kinds of goal: before a goal, read with fs any that fit it.\n"
    .. "- build-for-player: Stairs, walkways and rooms a two-tall player uses. (/turtle/skills/build-for-player/skill.md)\n"
    .. "- light-an-area (yours): Use when lighting a farm or a base: my own way. (/claude/skills/light-an-area/skill.md)\n"
    .. "- storage: Set up and keep the chests at home: categories, sorting, stowing. (/turtle/skills/storage/skill.md)"
check("the first message lists the skills, a line each, the model's own winning over the shipped one of its name (the readme isn't one)",
    first:find("[" .. LIST .. "]", 1, true) ~= nil, first)
check("...and the goal comes with the skills it may fit", first:find("\n[Skills that may fit: storage]", 1, true) ~= nil, first)
local sys46 = HTTP.requests[1] and HTTP.requests[1].body.system[1].text or ""
check("the system prompt says how to use them, and lists none",
    sys46:find("Before starting a goal, check the list and read with fs any that fit it: a skill's steps come before your own habits.", 1, true)
        and sys46:find("skill(name, description, body) in your code writes /claude/skills/<name>/skill.md", 1, true)
        and not sys46:find("build-for-player", 1, true))
local wrote = resultsIn(2).toolu_1
local lines46 = {}
for l in tostring(wrote and wrote.content or ""):gmatch("[^\n]+") do lines46[#lines46 + 1] = l end
check("skill() writes /claude/skills/<name>/skill.md, its name and description on top",
    lines46[1] == "-> true true /claude/skills/dig-stairs/skill.md"
        and Mine.files["claude/skills/dig-stairs/skill.md"] == "---\nname: dig-stairs\ndescription: Use when digging a staircase down.\n---\n1. Dig.\n2. Place stairs.\n",
    lines46[1])
check("...and refuses a bad name, a blank description, an overlong one, an empty body, a description of two lines",
    lines46[2] and lines46[2]:find("^false skill: the name is lowercase letters, digits and %-") and lines46[3]:find("^false skill: a skill needs a description")
        and lines46[4]:find("^false skill: the description is one line of at most 200") and lines46[5]:find("^false skill: the body is the procedure")
        and lines46[6]:find("^false skill: the description is one line") and not Mine.files["claude/skills/ok-name/skill.md"],
    tostring(wrote and wrote.content))
check("/skills shows them on the screen, the one written in the session too",
    Mine.logHas("^dig%-stairs %(Claude's own%): Use when digging a staircase down%.$") and Mine.logHas("^storage: Set up and keep the chests")
        and Mine.logHas("^light%-an%-area %(Claude's own%): Use when lighting a farm"))
local m4 = HTTP.requests[4] and HTTP.requests[4].body.messages or {}
local next46 = m4[2] and m4[2].content or ""
check("after a summary at a goal's end, the next goal brings the list again (the new skill in it), and the skills it may fit",
    blockOf(4) and next46:find("^light the farm\n\n%[") and next46:find("- dig-stairs (yours): Use when digging a staircase down. (/claude/skills/dig-stairs/skill.md)", 1, true)
        and next46:find("[Skills that may fit: light-an-area]", 1, true), next46)
local m7 = HTTP.requests[7] and HTTP.requests[7].body.messages or {}
local last7 = m7[#m7] and m7[#m7].content or {}
check("after a summary inside a goal (2 turns kept: the goal's own), the list goes onto the results",
    blockOf(7) and type(last7) == "table" and last7[1].type == "tool_result" and last7[#last7].type == "text"
        and last7[#last7].text:find("Your skills, procedures for kinds of goal", 1, true) == 1
        and last7[#last7].text:find("- dig-stairs (yours)", 1, true), textutils.serialiseJSON(last7))
local log46 = Mine.files["claude.log"] or ""
check("the log: how many listed, the nudge, the skill written",
    log46:find("skills: 3 listed\n", 1, true) and log46:find("Skills that may fit: storage\n", 1, true)
        and log46:find("skill written: /claude/skills/dig-stairs/skill.md\n", 1, true))

fresh({ "" })
shipped()
HTTP.queue = { reply({ text("Hi.") }, "end_turn") }
run("say hello")
local hello = HTTP.requests[1] and HTTP.requests[1].body.messages[1].content or ""
check("a goal sharing no words with a description: no nudge", hello:find("[Your skills", 1, true) and not hello:find("may fit", 1, true), hello)

-- ccnix's layers: the updates (/ccnix) over the ROM (/rom/ccnix)
fresh({ "" })
skillFile("rom/ccnix/turtle/skills", "storage", "The ROM's storage.")
skillFile("rom/ccnix/turtle/skills", "big-jobs", "Scope and batches for long jobs.")
skillFile("ccnix/turtle/skills", "storage", "The update's storage.")
skillFile("ccnix/turtle/skills", "new-one", "Only in the update.")
ccnix = { roots = { "/ccnix", "/rom/ccnix" }, find = function(rel)
    for _, r in ipairs({ "ccnix", "rom/ccnix" }) do if fs.exists(r .. "/" .. rel) then return "/" .. r .. "/" .. rel end end
end }
HTTP.queue = { reply({ text("Hi.") }, "end_turn") }
run("layers")
ccnix = nil
local layers = HTTP.requests[1] and HTTP.requests[1].body.messages[1].content or ""
check("with ccnix's layers, each one's skills listed, the update's winning over the ROM's of a name",
    layers:find("- big-jobs: Scope and batches for long jobs. (/rom/ccnix/turtle/skills/big-jobs/skill.md)\n", 1, true)
        and layers:find("- new-one: Only in the update. (/ccnix/turtle/skills/new-one/skill.md)\n", 1, true)
        and layers:find("- storage: The update's storage. (/ccnix/turtle/skills/storage/skill.md)]", 1, true), layers)
end

-- ADR-0018: the position checked against GPS at each goal's start; what changed goes to the model with the goal.
--     (A wireless modem on the back, GPS answering, a world origin from GPS on disk.)
do
local rawNames, rawType, rawCall = peripheral.getNames, peripheral.getType, peripheral.call
peripheral.getNames = function() local n = rawNames(); n[#n + 1] = "back"; return n end
peripheral.getType = function(side) if side == "back" then return "modem" end return rawType(side) end
peripheral.call = function(side, m, ...) if side == "back" and m == "isWireless" then return true end return rawCall(side, m, ...) end
local fixAt
gps = { locate = function() return fixAt[1], fixAt[2], fixAt[3] end }
fresh({ "" })
local dataDir = fs.getDir(package.loaded.turtlelib and package.loaded.turtlelib.dataPath(".turtlepos") or ".turtlepos")
local function data(name) return dataDir == "" and name or (dataDir .. "/" .. name) end
Mine.files[data(".map/frame")] = "frame 0 0 0 0 1\nworld 2 100 64 -50\nsource gps\n"   -- (+z south; (0,0,0) at 100,64,-50)
Mine.files[data(".turtlepos")] = "0 0 0 0 flat"
fixAt = { 100, 64, -50 }                               -- (where it is: nothing to say)
HTTP.queue = { reply({ text("Hi.") }, "end_turn") }
run("say hello")
local m1 = HTTP.requests[1] and HTTP.requests[1].body.messages[1].content or ""
check("gps: a goal with GPS agreeing: no note", m1 == "say hello" or not m1:find("GPS", 1, true), m1)
fresh({ "" })
Mine.files[data(".map/frame")] = "frame 0 0 0 0 1\nworld 2 100 64 -50\nsource gps\n"
Mine.files[data(".turtlepos")] = "0 0 0 0 flat"
fixAt = { 100, 64, 50 }                                -- (100 blocks south: carried off)
HTTP.queue = { reply({ text("Hi.") }, "end_turn") }
run("say hello")
local m2 = HTTP.requests[1] and HTTP.requests[1].body.messages[1].content or ""
check("gps: GPS far from the count: the goal says so, and T.pos is left as counted",
    m2:find("[Position check: GPS puts the turtle at 100,64,50 (0,0,100 in its frame), 100 blocks from where it was saved (0,0,0)", 1, true)
        and m2:find("ask the player before moving far.]", 1, true) and Mine.files[data(".turtlepos")]:find("^0 0 0 0"), m2)
gps = nil
peripheral.getNames, peripheral.getType, peripheral.call = rawNames, rawType, rawCall
end

-- ADR-0019 D1: the code's sleep is in real seconds (realtime.sleep), os.clock and os.startTimer stay game time, and
--     gps is a global; the prompt says so and names T.gpsHere for a fix with a modem swapped in.  (The server at 60
--     ticks a second: a game second is a third of a real one.)  D3: T.cfg.equipToDig is on in a session.
do
local clocks = { game = 0, real = 5000000 }
local sleepWas, clockWas, epochWas, gpsWas = sleep, os.clock, os.epoch, gps
sleep = function(s) clocks.game, clocks.real = clocks.game + s, clocks.real + s / 3 end
os.clock = function() return clocks.game end
os.epoch = function() return math.floor(clocks.real * 1000 + 0.5) end
gps = { locate = function() return 100, 64, -50 end }
fresh({ "" })
HTTP.queue = {
    reply({ toolUse("lua", { code = "local r, g = os.epoch('utc'), os.clock()\nsleep(10)\n"
        .. "return string.format('%.1f real, %.1f game', (os.epoch('utc') - r) / 1000, os.clock() - g)" }) }, "tool_use"),
    reply({ toolUse("lua", { code = "return gps.locate()" }) }, "tool_use"),
    reply({ toolUse("lua", { code = "return T.cfg.equipToDig" }) }, "tool_use"),
    reply({ text("Done.") }, "end_turn"),
}
run("wait ten seconds")
sleep, os.clock, os.epoch, gps = sleepWas, clockWas, epochWas, gpsWas
local s1, g1, e1 = resultsIn(2).toolu_1, resultsIn(3).toolu_2, resultsIn(4).toolu_3
check("D1: sleep(10) in the code at 60 ticks a second lasts 10 real seconds (30 game ones on os.clock)",
    s1 and s1.content == "-> 10.0 real, 30.0 game", s1 and s1.content)
check("D1: gps is a global in the code", g1 and g1.content == "-> 100\n-> 64\n-> -50", g1 and g1.content)
check("D3: T.cfg.equipToDig is on in a session", e1 and e1.content == "-> true", e1 and e1.content)
local sys = HTTP.requests[1] and HTTP.requests[1].body.system[1].text or ""
local tool = HTTP.requests[1] and HTTP.requests[1].body.tools[1].description or ""
check("D1: the prompt says sleep is real seconds and os.clock game time, and names T.gpsHere for a modem swapped in",
    sys:find("Your sleep is realtime.sleep (real seconds); os.clock and os.startTimer count game time", 1, true)
        and sys:find("T.gpsHere() swaps one in from the inventory for the fix", 1, true)
        and not sys:find("sleep, os.clock and os.startTimer count game ticks", 1, true)
        and tool:find("sleep (real seconds), gps, settings (read-only: get, getNames, getDetails), fs and io in scope", 1, true))
check("the system prompt ends with the date (ADR-0020: the model dated its files days off without it)",
    sys:find("\n\nToday is %d%d%d%d%-%d%d%-%d%d %(UTC%)%.$") ~= nil, sys:sub(-60))
end

-- ADR-0019 D4: each session keeps its options in the setting claude.options, and a claude started without them (as
--     autostart's plain `claude` after a reboot) takes them; a flag given wins, and is kept in turn; --confirm isn't
--     kept.  (The settings: a table, saved when told.)
do
local SETD, saves = {}, 0
settings = { define = function() end, get = function(n) return SETD[n] end, set = function(n, v) SETD[n] = v end,
             save = function() saves = saves + 1 end }
local function startLine() return ((Mine.files["claude.log"] or ""):match("start: claude[^\n]*")) or "" end
fresh({ "" })
HTTP.queue = { reply({ text("Ok.") }, "end_turn") }
run("dig the tunnel", "--steps", "400", "--cache", "1h", "--confirm")
check("D4: a session keeps its options in claude.options (not --confirm), saved",
    SETD["claude.options"] == "--steps 400 --cache 1h" and saves == 1, tostring(SETD["claude.options"]))
fresh({ "say hello", "" })
HTTP.queue = { reply({ text("Hi.") }, "end_turn") }
run()
local r1 = HTTP.requests[1] and HTTP.requests[1].body
check("D4: a plain claude (as autostart starts it after a reboot) starts with them, and says so",
    r1 and r1.cache_control.ttl == "1h" and startLine():find("steps 400, cache 1h", 1, true)
        and not startLine():find("confirming", 1, true)
        and Mine.logHas("^Options from the last session %(claude%.options%): %-%-steps 400 %-%-cache 1h%.$") and saves == 1,
    startLine())
check("...and the log's start line says where they came from (the reboot check's evidence)",
    startLine():find("; from claude.options: --steps 400 --cache 1h", 1, true) ~= nil, startLine())
fresh({ "" })
HTTP.queue = { reply({ text("Ok.") }, "end_turn") }
run("dig more", "--steps", "9")
check("D4: a flag given wins over the kept one, and is kept in turn",
    startLine():find("steps 9, cache 1h", 1, true) and SETD["claude.options"] == "--steps 9 --cache 1h" and saves == 2,
    startLine() .. " / " .. tostring(SETD["claude.options"]))
-- ADR-0020 D4: the settings, read-only, in the code
fresh({ "" })
HTTP.queue = {
    reply({ toolUse("lua", { code = "return settings.get('claude.options'), settings.set == nil" }) }, "tool_use"),
    reply({ text("Ok.") }, "end_turn"),
}
run("read a setting")
local set1 = resultsIn(2).toolu_1
check("ADR-0020 D4: settings.get in the code reads a setting; there's no settings.set", set1 and set1.content == "-> --steps 9 --cache 1h\n-> true",
    set1 and set1.content)
settings = nil
end

-- #93: a goal longer than a line, from a file: /goal <file> at the prompt, --goal-file at the start
do
fresh({ "/goal plan.txt", "" })
Mine.files["plan.txt"] = "build a wall\ntwo high, of stone\n"
HTTP.queue = { reply({ text("Ok.") }, "end_turn") }
run()
local g1 = HTTP.requests[1] and HTTP.requests[1].body.messages[1].content
check("#93: /goal <file> at the prompt: the file's text is the goal, all its lines", g1 == "build a wall\ntwo high, of stone",
    tostring(g1))
fresh({ "/goal nowhere.txt", "" })
HTTP.queue = {}
run()
check("...a file that isn't there: the prompt again, nothing sent", #HTTP.requests == 0, tostring(#HTTP.requests))
fresh({ "" })
Mine.files["brief.txt"] = "dig a tunnel\n20 long\n"
HTTP.queue = { reply({ text("Ok.") }, "end_turn") }
run("--goal-file", "brief.txt")
local g2 = HTTP.requests[1] and HTTP.requests[1].body.messages[1].content
check("#93: --goal-file at the start: the file's text is the first goal", g2 == "dig a tunnel\n20 long", tostring(g2))
end
