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
local getopt = require("getopt")

local SPEC = "X:d:H:A:u:o:m:LiIOfsSvh"
local LONG = { request = "X", data = "d", header = "H", ["user-agent"] = "A", user = "u", location = "L",
               include = "i", head = "I", output = "o", ["remote-name"] = "O", fail = "f", ["max-time"] = "m",
               silent = "s", ["show-error"] = "S", verbose = "v", help = "h" }

-- the options (each a list of its values, in order) and the URLs.  As
-- curl, options may come after a URL too: getopt reads up to the first
-- URL, which is kept, then on from the arg after it; after "--" all are
-- URLs.
local opts, urls = {}, {}
do
    local args = { ... }
    while #args > 0 do
        local given, rest, order = getopt.parse(args, SPEC, LONG)
        if not given then cu.usageError(rest) end
        for _, o in ipairs(order) do
            opts[o[1]] = opts[o[1]] or {}
            table.insert(opts[o[1]], o[2])
        end
        local used = #args - #rest                  -- (the args the options took, a "--" too)
        local last = order[#order]
        if used > 0 and args[used] == "--" and not (last and last[2] == "--") then   -- (all URLs from here)
            for _, u in ipairs(rest) do urls[#urls + 1] = u end
            break
        end
        if rest[1] then urls[#urls + 1] = table.remove(rest, 1) end
        args = rest
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
        local file = text.stripPrefix(d, "@")
        if file then
            local h = cu.open(file == "" and "-" or file)
            if not h then return fail(26, "can't read " .. file) end
            d = cu.readAll(h)                               -- (the file without its CR and LF characters)
            d = text.replace(text.replace(d, "\r", ""), "\n", "")
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
if user and not text.contains(user, ":") then
    io.write("Enter host password for user '" .. user .. "': ")
    user = user .. ":" .. (read("*") or "")
end
local timeout = cu.number({ m = last("m") }, "m")          -- (the last -m given)

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
    if out then out:write(s) else io.write(screen and (text.replace(s, "\r\n", "\n")) or s) end
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
    debug = opts.v and function(k, line)
        printError((k == "out" and "> " or k == "in" and "< " or "* ") .. line)
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
