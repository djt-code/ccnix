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
local HTTP = M.httpApi()
http = HTTP.api
local answers = M.consoleApi(Mine, {})
local run = M.runner(Mine, PROJ .. "/turtle/claude.lua", {
    stats = function() return "moves: " .. Mine.moves .. ", turns: " .. Mine.turns .. ", API calls: " .. #HTTP.requests end,
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
                usage = { input_tokens = 100, output_tokens = 20, cache_read_input_tokens = 50 } }
    for k, v in pairs(extra or {}) do r[k] = v end
    return { code = 200, body = r }
end
local function thinking() return { type = "thinking", thinking = "", signature = "sig" } end

-- The tool results in the user turn of request n: { [tool_use_id] = block }.
local function resultsIn(n)
    local req = HTTP.requests[n]
    if not req then return {}, { content = {} } end
    local msgs = req.body.messages
    local last = msgs[#msgs]
    local out = {}
    if type(last.content) == "table" then
        for _, b in ipairs(last.content) do
            if b.type == "tool_result" then out[b.tool_use_id] = b end
        end
    end
    return out, last
end

local function fresh(answersList)
    Mine.setup(Mine.stock(0, 0))
    Mine.startAt()
    Mine.inv, Mine.files = {}, { ["claude.key"] = "sk-test-key\n" }
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
check("the request names the model, effort, cached system prompt and the three tools",
    r1 and r1.body.model == "claude-opus-5-5" and r1.body.output_config.effort == "medium"
        and r1.body.system[1].cache_control.type == "ephemeral"
        and #r1.body.tools == 3 and r1.body.tools[1].name == "lua" and r1.body.tools[1].input_schema.required[1] == "code")
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
check("the token totals were printed", Mine.logHas("tokens in"))
check("the code was logged to claude.log", (Mine.files["claude.log"] or ""):find("T.turnRight") ~= nil)

-- 2. the sandbox: fs is out of reach, a syntax error and a runtime error
--    come back as error results, tables are serialised, definitions
--    persist between calls
fresh({ "" })
HTTP.queue = {
    reply({ toolUse("lua", { code = "return http, shell" }) }, "tool_use"),
    reply({ toolUse("lua", { code = "return (" }) }, "tool_use"),
    reply({ toolUse("lua", { code = "function twice(n) return 2 * n end; return { a = twice(2) }" }) }, "tool_use"),
    reply({ toolUse("lua", { code = "return twice(5), http, shell" }) }, "tool_use"),
    reply({ text("Checked.") }, "end_turn"),
}
run("poke at the sandbox")
local e1 = resultsIn(2).toolu_1
check("http and shell aren't there", e1 and e1.content == "-> nil\n-> nil", e1 and e1.content)
local e2 = resultsIn(3).toolu_2
check("a syntax error is an error result", e2 and e2.is_error == true and tostring(e2.content):find("syntax"), e2 and e2.content)
local e3 = resultsIn(4).toolu_3
check("a returned table is serialised", e3 and e3.content == "-> {a=4}" and e3.is_error == nil, e3 and e3.content)
local e4 = resultsIn(5).toolu_4
check("a function defined in one call is there in the next; http and shell aren't",
    e4 and e4.content == "-> 10\n-> nil\n-> nil", e4 and e4.content)

-- 3. an overloaded API is retried; a refusal is reported and stops the goal
fresh({ "" })
HTTP.queue = {
    { code = 529, body = { type = "error", error = { type = "overloaded_error", message = "Overloaded" } } },
    { fail = "Could not connect" },
    reply({}, "refusal", { stop_details = { type = "refusal", category = "cyber", explanation = "Not this." } }),
}
run("something it won't do")
check("retried after the 529 and the failed connection", #HTTP.requests == 3 and Mine.logHas("trying again"))
check("the refusal was reported with its category", Mine.logHas("Claude declined %(cyber%)"))

-- 3b. an error the API won't recover from stops the goal with its message
fresh({ "" })
HTTP.queue = {
    { code = 400, body = { type = "error", error = { type = "invalid_request_error", message = "bad request" } } },
}
run("anything")
check("a 400 isn't retried and its message is shown", #HTTP.requests == 1 and Mine.logHas("HTTP 400.*bad request"))

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
fresh({ "" })
run("dig", "--steps")
check("an option with no word after it: getopt's message, nothing sent",
    #HTTP.requests == 0 and Mine.logHas("claude: option '%-%-steps' requires an argument"))

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
}
HTTP.queue = {}
for i, c in ipairs(REQ_CODES) do HTTP.queue[i] = reply({ toolUse("lua", { code = c }) }, "tool_use") end
HTTP.queue[#REQ_CODES + 1] = reply({ text("Checked.") }, "end_turn")
run("poke at require")
local function reqOut(i) local r = resultsIn(i + 1)["toolu_" .. i]; return r and tostring(r.content) or "", r and r.is_error end
local q1, e1 = reqOut(1)
local _, e2 = reqOut(2)
check("require of anything else is an error result naming what it can have",
    e1 and q1:find("only these here") and q1:find("cc.strings", 1, true) and q1:find("text", 1, true) and e2, q1)
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
--     tool_use answered in the very next turn) before asking to carry on
fresh({ "" })
HTTP.queue = {
    reply({ text("Digging now."), toolUse("lua", { code = "turtle.dig(" }) }, "max_tokens"),
    reply({ text("Stopped short; nothing was run.") }, "end_turn"),
}
run("dig a lot")
local cutTurn = HTTP.requests[2] and HTTP.requests[2].body.messages[3]
local cr = cutTurn and type(cutTurn.content) == "table" and cutTurn.content
check("a tool call cut off at max_tokens is answered (not run), then told to carry on",
    cr and cr[1].type == "tool_result" and cr[1].tool_use_id == "toolu_1" and cr[1].is_error == true
        and cr[2].type == "text" and cr[2].text:find("cut off") and DIGS == 0, cutTurn and textutils.serialiseJSON(cutTurn))

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
