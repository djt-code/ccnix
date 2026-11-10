-- curl.lua -- fetch a URL over HTTP, a small curl for ccnix (lib/httpc.lua)
--
--   curl [options] url
--
-- curl is Daniel Stenberg's: he created it and leads the curl project
-- (https://curl.se), whose many contributors keep it going.  This isn't
-- that curl, only a small HTTP-only tool for ccnix that borrows its name,
-- some of its options and its exit codes, with thanks to him and to them.
--
-- The body goes to the output (on the screen without its carriage
-- returns), the headers too with -i.  Options may come before or after
-- the URL, short or long:
--   -X, --request <method>   GET unless -d or -I say otherwise
--   -d, --data <data>        send data, a POST (form-encoded unless -H says
--                            another Content-Type); several are joined with
--                            &; @file reads a file (@- the input), less its
--                            newlines
--   -H, --header <line>      a header to send, "Name: value"; "Name:"
--                            leaves out one curl sends, "Name;" sends it empty
--   -A, --user-agent <name>  the User-Agent (ccnix-curl)
--   -u, --user <user:pass>   Basic authentication (asks for the password if
--                            there's no colon)
--   -L, --location           follow redirects (at most 50)
--   -i, --include            the response's status line and headers first
--   -I, --head               a HEAD request: the headers alone
--   -o, --output <file>      write the body to file
--   -O, --remote-name        write it to the file the URL's path names
--   -f, --fail               an HTTP error (400 and up): no body, exit 22
--   -m, --max-time <secs>    give up after that long, exit 28
--   -s, --silent             no error messages (-S, --show-error: those)
--   -v, --verbose            what's sent (> lines) and received (< lines)
--   -h, --help               this, briefly
--
-- HTTP only: https:// and other schemes exit 1 (CC's own http API does
-- HTTPS from the server).  A URL with no scheme is http.  Names are looked
-- up as everywhere (`ip host`, then DNS).  There's no progress meter.
-- Exit status, as curl's: 0, 1 (not HTTP), 2 (usage), 3 (a bad URL), 6
-- (no such host), 7 (couldn't connect), 18 (the body cut short), 22 (-f
-- and an HTTP error), 23 (couldn't write the output), 26 (couldn't read a
-- -d @file), 28 (timed out), 47 (too many redirects), 52 (an empty
-- reply), 55 (couldn't send), 56 (the connection broke).  The network
-- must be up (`ip up`).

package.path = (ccnix and ccnix.lib or "/" .. fs.getDir(fs.getDir(shell.getRunningProgram())) .. "/lib/?.lua;") .. package.path  -- ccnix's lib/, or the one beside bin/
local cu = require("cu").init("curl", "curl [-fiILOsSv] [-X method] [-d data] [-H header] [-A agent] [-u user:pass] [-o file] [-m secs] url")
local httpc = require("httpc")
local scan = require("scan")
local text = require("text")

local LONG = { request = "X", data = "d", header = "H", ["user-agent"] = "A", user = "u", location = "L",
               include = "i", head = "I", output = "o", ["remote-name"] = "O", fail = "f", ["max-time"] = "m",
               silent = "s", ["show-error"] = "S", verbose = "v", help = "h" }
local TAKES = { X = true, d = true, H = true, A = true, u = true, o = true, m = true }
local FLAGS = { L = true, i = true, I = true, O = true, f = true, s = true, S = true, v = true, h = true }

-- the options (each a list of its values, in order) and the URLs
local opts, urls = {}, {}
do
    local args, i = { ... }, 1
    local function add(c, v) opts[c] = opts[c] or {}; table.insert(opts[c], v) end
    while i <= #args do
        local a = args[i]
        if a == "--" then
            for k = i + 1, #args do urls[#urls + 1] = args[k] end
            break
        elseif a:sub(1, 2) == "--" then
            local name, value = text.cut(a:sub(3), "=")     -- (--name or --name=value)
            if name == "" then name, value = a:sub(3), nil end
            local c = LONG[name]
            if not c then cu.usageError("option --" .. name .. ": is unknown") end
            if TAKES[c] and not value then
                i = i + 1
                value = args[i]
                if value == nil then cu.usageError("option --" .. name .. ": requires parameter") end
            end
            add(c, TAKES[c] and value or true)
        elseif a:sub(1, 1) == "-" and #a > 1 then
            local j = 2
            while j <= #a do
                local c = a:sub(j, j)
                if TAKES[c] then
                    local v = a:sub(j + 1)
                    if v == "" then
                        i = i + 1
                        v = args[i]
                        if v == nil then cu.usageError("option -" .. c .. ": requires parameter") end
                    end
                    add(c, v)
                    break
                elseif FLAGS[c] then add(c, true)
                else cu.usageError("option -" .. c .. ": is unknown") end
                j = j + 1
            end
        else
            urls[#urls + 1] = a
        end
        i = i + 1
    end
end
local function last(c) return opts[c] and opts[c][#opts[c]] end

if opts.h then
    print("usage: " .. cu.usage)
    print("HTTP only; help curl says more.  curl itself is Daniel Stenberg's (curl.se): this small one borrows its name.")
    return cu.exit(0)
end
if #urls == 0 then cu.usageError("no URL specified") end
if #urls > 1 then cu.usageError("one URL at a time") end

local quiet = opts.s and not opts.S
local function fail(code, why)
    if not quiet then cu.err("(" .. code .. ") " .. why) end
    cu.exit(code)
end

-- what to send
local headers = opts.H or {}
local body
if opts.d then
    local parts = {}
    for _, d in ipairs(opts.d) do
        if d:sub(1, 1) == "@" then
            local h = cu.open(d:sub(2) == "" and "-" or d:sub(2))
            if not h then return fail(26, "can't read " .. d:sub(2)) end
            local kept, text = {}, cu.readAll(h)            -- (the file without its CR and LF characters)
            for k = 1, #text do
                local c = text:sub(k, k)
                if c ~= "\r" and c ~= "\n" then kept[#kept + 1] = c end
            end
            d = table.concat(kept)
            cu.close(h)
        end
        parts[#parts + 1] = d
    end
    body = table.concat(parts, "&")
    local typed = false
    for _, line in ipairs(headers) do
        local sc = scan.new(line:lower())               -- (blanks, "content-type", blanks, ":" or ";")
        sc:skipSpaces()
        if sc:accept("content-type") then
            sc:skipSpaces()
            if sc:peek() == ":" or sc:peek() == ";" then typed = true end
        end
    end
    if not typed then headers[#headers + 1] = "Content-Type: application/x-www-form-urlencoded" end
end
local method = last("X") or (opts.I and "HEAD") or (body and "POST") or "GET"
local user = last("u")
if user and not user:find(":", 1, true) then
    io.write("Enter host password for user '" .. user .. "': ")
    user = user .. ":" .. (read("*") or "")
end
local timeout = last("m") and tonumber(last("m"))
if last("m") and not timeout then cu.usageError("bad -m " .. last("m")) end

-- where the body goes
local url = urls[1]
local screen = cu.isTerminal()
local outName = last("o")
if opts.O and not outName then
    local u = httpc.parseURL(url)
    if u then
        local folder, name = text.cutLast((text.cut(u.path, "?")), "/")    -- (the path's last part, before any ?query)
        outName = name or folder
    end
    if not outName or outName == "" then return fail(23, "remote file name has no length") end
end
local out
if outName then
    out = io.open(shell and shell.resolve(outName) or outName, "wb")
    if not out then return fail(23, "can't write " .. outName) end
end
local function emit(s)
    if out then out:write(s) else io.write(screen and s:gsub("\r\n", "\n") or s) end
end

local failing
local resp, why, kind = httpc.request({
    url = url, method = method, headers = headers, body = body, user = user, follow = opts.L ~= nil,
    timeout = timeout, agent = last("A") or "ccnix-curl",
    onHeaders = function(r, redirecting)
        if not redirecting and opts.f and r.status >= 400 then failing = r return end
        if opts.i or opts.I then
            for _, l in ipairs(r.lines) do emit(l .. "\r\n") end
            emit("\r\n")
        end
    end,
    sink = function(s) if not failing then emit(s) end end,
    debug = opts.v and function(k, text)
        printError((k == "out" and "> " or k == "in" and "< " or "* ") .. text)
    end or nil,
})
if out then out:close() end
if not resp then
    local CODES = { protocol = 1, url = 3, resolve = 6, connect = 7, partial = 18, timeout = 28, redirects = 47,
                    empty = 52, send = 55, read = 56 }
    return fail(CODES[kind] or 56, why)
end
if failing then return fail(22, "the requested URL returned error: " .. failing.status) end
return cu.exit()
