-- httpc.lua -- a small HTTP/1.1 client over the network stack (lib/net.lua)
--
--   local httpc = require("httpc")
--   local r, why = httpc.get("http://10.0.2.5/index.html")
--   if r then print(r.status, r.headers["content-type"], #r.body) end
--   r = httpc.post("http://10.0.2.5/form", "a=1&b=2",
--                  { ["Content-Type"] = "application/x-www-form-urlencoded" })
--   r = httpc.request({ url = "http://wiki/page", method = "PUT", body = "...",
--                       headers = { "Content-Type: text/plain" }, follow = true, timeout = 10 })
--
-- What bin/curl is built on.  Its shape follows curl's, by Daniel Stenberg
-- and the curl project (https://curl.se), with thanks: this is a far
-- smaller thing, and only HTTP.  No TLS: an https:// URL is refused (CC's
-- own http API does HTTPS, from the server, outside the CC network).  One
-- request a connection (Connection: close); the body comes as
-- Content-Length says, chunked, or until the server closes.
--
-- httpc.request(opts) -> a response, or nil, why and what kind of failure.
--   url        http://[user:pass@]host[:port][/path][?query] (no scheme:
--              http; a #fragment is left off)
--   method     GET, or POST when there's a body
--   headers    { ["Name"] = "value" } or { "Name: value", ... }; false (or
--              "Name:") leaves out one sent by default (Host, User-Agent,
--              Accept, Connection), "Name;" sends it empty
--   body       sent as it is, with its Content-Length
--   user       "name:password" for Basic authentication (else the URL's),
--              sent only to the first URL's host and port, as curl does
--   follow     follow redirects (a 3xx with a Location), at most
--              maxRedirects (50); 301 and 302 turn a POST into a GET
--              without the body, 303 anything but HEAD, 307 and 308 keep it
--   timeout    seconds for the whole request, redirects and all
--   agent      the User-Agent (httpc.AGENT, "ccnix-httpc")
--   sink       function(chunk): the final response's body goes here, as it
--              comes, instead of into response.body
--   onHeaders  function(response, redirecting): each response once its
--              headers are in, before its body
--   debug      function(kind, text): "info" (what it's doing), "out" (a
--              request header line), "in" (a response header line)
-- A response: { status = 200, reason = "OK", version = "HTTP/1.1",
--   headers = { ["content-type"] = "text/plain", ... } (names in lower
--   case; repeated ones joined with ", "), lines = the status line and
--   header lines as they came, body (unless a sink took it), url (the
--   last one asked for), redirects (how many were followed) }.
-- The kinds of failure: "url" (malformed), "protocol" (not http),
-- "resolve" (no such host), "connect", "send", "timeout", "redirects"
-- (too many), "empty" (it closed without a word), "partial" (it closed
-- before Content-Length's end), "read" (it broke, or what came isn't HTTP).

local net = require("net")
local scan = require("scan")
local text = require("text")
local convert = require("convert")

local H = {}
H.AGENT = "ccnix-httpc"
H.MAX_REDIRECTS = 50

-- scheme "://" rest, the scheme a letter then letters, digits and +.-:
-- the scheme and the rest; nil if url doesn't start with one.
local function isSchemeChar(c) return scan.isAlnum(c) or c == "+" or c == "." or c == "-" end
local function isHostChar(c) return scan.isAlnum(c) or c == "." or c == "-" end
local function schemeOf(url)
    if not scan.isAlpha(url:sub(1, 1)) then return nil end
    local sc = scan.new(url)
    local scheme = sc:readWhile(isSchemeChar)
    if not sc:accept("://") then return nil end
    return scheme, sc:rest()
end

-- A URL's parts: { host, port, path (with its query), user, url (as
-- asked for, less the user and fragment) }, or nil, why and the kind.
-- url: [scheme "://"] [user "@"] host [":" digits] [path] ["?" query] ["#" fragment]
function H.parseURL(url)
    if type(url) ~= "string" or url == "" then return nil, "no URL", "url" end
    url = text.cut(url, "#")
    local scheme, rest = schemeOf(url)
    if not scheme then scheme, rest = "http", url end
    scheme = scheme:lower()
    if scheme ~= "http" then return nil, 'protocol "' .. scheme .. '" not supported (HTTP only)', "protocol" end
    local sc = scan.new(rest)
    local authority = sc:readWhile(function(c) return c ~= "/" and c ~= "?" end)
    local target = sc:rest()                       -- (the path and query)
    if target == "" or text.startsWith(target, "?") then target = "/" .. target end
    local user, hostport = text.cutLast(authority, "@")
    if not hostport then user, hostport = nil, authority end
    local host, port = text.cutLast(hostport, ":")
    if not port or not scan.all(port, scan.isDigit) then host, port = hostport, nil end   -- ("" too: host:)
    if host == "" or not scan.all(host, isHostChar) then return nil, "bad host in " .. url, "url" end
    port = (port == nil or port == "") and 80 or tonumber(port)
    if port < 1 or port > 65535 then return nil, "bad port in " .. url, "url" end
    return { host = host:lower(), port = port, path = target, user = user and convert.urlDecode(user),
             url = "http://" .. host:lower() .. (port ~= 80 and (":" .. port) or "") .. target }
end

-- A path with its . and .. segments worked out, as RFC 3986's
-- remove_dot_segments does ("/a/b/.." is "/a/": lib/path's normalize
-- would drop that last slash, so not that).
local function dots(target)
    local before, query = text.cut(target, "?")
    local q = query and ("?" .. query) or ""
    local segs, out = text.split(before, "/", true), {}
    for i = 2, #segs do                            -- (segs[1] is before the leading /)
        local s = segs[i]
        if s == ".." then out[#out] = nil end
        if s ~= "." and s ~= ".." then out[#out + 1] = s
        elseif i == #segs then out[#out + 1] = "" end   -- ("/a/b/.." is "/a/")
    end
    return "/" .. table.concat(out, "/") .. q
end

-- Where a redirect's Location points, from the URL that sent it.
function H.resolve(base, loc)
    if schemeOf(loc) then return loc end
    local b = H.parseURL(base)
    local origin = "http://" .. b.host .. (b.port ~= 80 and (":" .. b.port) or "")
    if text.startsWith(loc, "//") then return "http:" .. loc end
    if text.startsWith(loc, "/") then return origin .. dots(loc) end
    local basePath = text.cut(b.path, "?")
    if loc == "" then return origin .. b.path end
    if text.startsWith(loc, "?") then return origin .. basePath .. loc end
    local folder = text.cutLast(basePath, "/") .. "/"     -- (the path up to its last /; it starts with one)
    return origin .. dots(folder .. loc)
end

-- Reading a response off a connection, by lines and by counts.
local function reader(conn, deadline)
    local R = { buf = "" }
    local function more()
        local left = deadline and deadline - os.clock()
        if left and left <= 0 then return nil, "timeout" end
        local s, e = conn:read(left)
        if not s then return nil, e end
        R.buf = R.buf .. s
        return true
    end
    function R.line()
        while true do
            local l, rest = text.cut(R.buf, "\n")
            if rest then
                R.buf = rest
                return text.stripSuffix(l, "\r") or l
            end
            if #R.buf > 16384 then return nil, "a header line past 16 KiB" end
            local ok, e = more()
            if not ok then return nil, e end
        end
    end
    function R.take(n, sink)
        while n > 0 do
            if #R.buf == 0 then
                local ok, e = more()
                if not ok then return nil, e, n end
            end
            local s = R.buf:sub(1, n)
            R.buf = R.buf:sub(#s + 1)
            n = n - #s
            sink(s)
        end
        return true
    end
    function R.rest(sink)
        while true do
            if #R.buf > 0 then sink(R.buf); R.buf = "" end
            local ok, e = more()
            if not ok then
                if e == "closed" then return true end
                return nil, e
            end
        end
    end
    return R
end

local function failed(e, what)
    if e == "timeout" then return nil, "timed out " .. what, "timeout" end
    return nil, what .. ": " .. tostring(e), "read"
end

-- The headers to send: { { name, value }, ... }, the defaults first.
local function requestHeaders(u, opts, auth, body)
    local list, dropped = {}, {}
    local function find(name)
        for i, h in ipairs(list) do if h[1]:lower() == name:lower() then return i end end
    end
    local function set(name, value)
        local i = find(name)
        dropped[name:lower()] = value == false or nil
        if value == false then if i then table.remove(list, i) end
        elseif i then list[i][2] = value
        else list[#list + 1] = { name, value } end
    end
    set("Host", u.host .. (u.port ~= 80 and (":" .. u.port) or ""))
    if auth then set("Authorization", "Basic " .. convert.toBase64(auth)) end
    set("User-Agent", opts.agent or H.AGENT)
    set("Accept", "*/*")
    for k, v in pairs(opts.headers or {}) do
        if type(k) == "string" then set(k, v) end
    end
    -- a header line: name (":" | ";") value, blanks before the name and
    -- round the value dropped
    local function headerLine(line)
        local sc = scan.new(line)
        sc:skipSpaces()
        local name = sc:readWhile(function(c) return c ~= ":" and c ~= ";" end)
        if name == "" or sc:atEnd() then return nil end
        return name, sc:advance(), text.trim(sc:rest())
    end
    for _, line in ipairs(opts.headers or {}) do
        local name, sep, value = headerLine(tostring(line))
        if name then
            if sep == ";" then set(name, "")
            elseif value == "" then set(name, false)
            else set(name, value) end
        end
    end
    if body and not find("Content-Length") then set("Content-Length", tostring(#body)) end
    if not find("Connection") and not dropped.connection then set("Connection", "close") end
    return list
end

local REDIRECTS = { [301] = true, [302] = true, [303] = true, [307] = true, [308] = true }

-- status-line: "HTTP/" digit "." digit, blanks, three digits, the reason
-- (without the blanks round it): version, code, reason; nil if it isn't one.
local function statusLine(line)
    local sc = scan.new(line)
    if not sc:accept("HTTP/") then return nil end
    if not (scan.isDigit(sc:peek(1)) and sc:peek(2) == "." and scan.isDigit(sc:peek(3))) then return nil end
    local version = "HTTP/" .. sc:advance(3)
    if sc:skipSpaces() == 0 then return nil end
    local code = sc:advance(3)
    if #code ~= 3 or not scan.all(code, scan.isDigit) then return nil end
    return version, code, text.trim(sc:rest())
end

-- One request and its response, on a connection of its own.
local function exchange(u, method, body, opts, auth, deadline, canFollow)
    local debug = opts.debug or function() end
    local S, down = net.stack()
    if not S then return nil, down or "the network isn't up", "connect" end
    local ip, why = net.resolve(u.host)
    if not ip then return nil, "couldn't resolve host " .. u.host .. (why and (" (" .. why .. ")") or ""), "resolve" end
    debug("info", "Trying " .. net.ipString(ip) .. ":" .. u.port .. "...")
    local left = deadline and math.max(deadline - os.clock(), 0.05)
    local conn, err = net.connect(ip, u.port, left)
    if not conn then
        if deadline and os.clock() >= deadline then return nil, "timed out connecting to " .. u.host, "timeout" end
        return nil, "failed to connect to " .. u.host .. " port " .. u.port .. ": " .. tostring(err), "connect"
    end
    debug("info", "Connected to " .. u.host .. " (" .. net.ipString(ip) .. ") port " .. u.port)

    local lines = { method .. " " .. u.path .. " HTTP/1.1" }
    for _, h in ipairs(requestHeaders(u, opts, auth, body)) do lines[#lines + 1] = h[1] .. ": " .. h[2] end
    for _, l in ipairs(lines) do debug("out", l) end
    debug("out", "")
    if not conn:send(table.concat(lines, "\r\n") .. "\r\n\r\n" .. (body or "")) then
        conn:abort()
        return nil, "the connection broke sending the request", "send"
    end

    local R = reader(conn, deadline)
    local function bail(...) conn:abort() return ... end
    local resp
    repeat                                          -- (1xx: an interim answer, then the real one)
        local status, e0 = R.line()
        if e0 == "closed" and resp == nil and R.buf == "" then return bail(nil, "an empty reply from the server", "empty") end
        if not status then return bail(failed(e0, "waiting for the response")) end
        local version, code, reason = statusLine(status)
        if not version then return bail(nil, "not an HTTP response: " .. status:sub(1, 60), "read") end
        resp = { version = version, status = tonumber(code), reason = reason, headers = {}, lines = { status } }
        debug("in", status)
        while true do
            local l, e = R.line()
            if not l then return bail(failed(e, "reading the headers")) end
            debug("in", l)
            if l == "" then break end
            resp.lines[#resp.lines + 1] = l
            local name, value = text.cut(l, ":")        -- (name ":" value)
            if value and name ~= "" then
                value = text.trim(value)
                name = name:lower()
                resp.headers[name] = resp.headers[name] and (resp.headers[name] .. ", " .. value) or value
            end
        end
    until resp.status >= 200 or resp.status == 101

    local redirecting = canFollow and REDIRECTS[resp.status] and resp.headers.location ~= nil
    if opts.onHeaders then opts.onHeaders(resp, redirecting) end
    if redirecting then conn:abort() return resp, nil, nil, true end

    local parts = {}
    local sink = opts.sink or function(s) parts[#parts + 1] = s end
    local te, length = resp.headers["transfer-encoding"], resp.headers["content-length"]
    local len = scan.isUnsigned(length) and tonumber(length)
    if method == "HEAD" or resp.status == 204 or resp.status == 304 or resp.status < 200 then
        -- (no body)
    elseif te and text.contains(te:lower(), "chunked") then
        while true do
            local l, e = R.line()
            if not l then return bail(failed(e, "reading a chunk")) end
            local size = scan.new(l)                -- (a chunk's size: blanks, hex digits, anything)
            size:skipSpaces()
            local n = convert.toInteger(size:readWhile(scan.isHexDigit), 16)
            if not n then return bail(nil, "a bad chunk size: " .. l:sub(1, 20), "read") end
            if n == 0 then
                repeat l, e = R.line() until not l or l == ""
                break
            end
            local ok, e2 = R.take(n, sink)
            if not ok then return bail(failed(e2, "reading a chunk")) end
            R.line()
        end
    elseif len then
        local ok, e, short = R.take(len, sink)
        if not ok then
            if e == "closed" then return bail(nil, "it closed with " .. short .. " of " .. len .. " bytes to come", "partial") end
            return bail(failed(e, "reading the body"))
        end
    else
        local ok, e = R.rest(sink)
        if not ok then return bail(failed(e, "reading the body")) end
    end
    conn:close()
    debug("info", "Closing the connection")
    if not opts.sink then resp.body = table.concat(parts) end
    return resp
end

function H.request(opts)
    if type(opts) == "string" then opts = { url = opts } end
    local deadline = opts.timeout and os.clock() + opts.timeout
    local method = (opts.method or (opts.body and "POST" or "GET")):upper()
    local body, url = opts.body, opts.url
    local max = opts.maxRedirects or H.MAX_REDIRECTS
    local first, why, kind = H.parseURL(url)
    if not first then return nil, why, kind end
    local auth = opts.user or first.user
    local redirects = 0
    while true do
        local u
        u, why, kind = H.parseURL(url)
        if not u then return nil, why, kind end
        local sendAuth = u.host == first.host and u.port == first.port and auth or nil
        local resp, err, k, again = exchange(u, method, body, opts, sendAuth, deadline, opts.follow and redirects < max)
        if not resp then return nil, err, k end
        resp.url, resp.redirects = u.url, redirects
        if not again then
            if opts.follow and REDIRECTS[resp.status] and resp.headers.location then
                return nil, "maximum (" .. max .. ") redirects followed", "redirects"
            end
            return resp
        end
        url = H.resolve(u.url, resp.headers.location)
        if (resp.status == 303 and method ~= "HEAD") or ((resp.status == 301 or resp.status == 302) and method == "POST") then
            method, body = "GET", nil
        end
        redirects = redirects + 1
        if opts.debug then opts.debug("info", "Issue another request to this URL: '" .. url .. "'") end
    end
end

function H.get(url, headers) return H.request({ url = url, headers = headers }) end
function H.post(url, body, headers) return H.request({ url = url, method = "POST", body = body, headers = headers }) end

return H
