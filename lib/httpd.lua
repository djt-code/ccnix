-- httpd.lua -- a small HTTP/1.1 server over the network stack (lib/net.lua)
--
--   local httpd = require("httpd")
--   local srv = httpd.new({ port = 80, log = print })
--   srv:use(function(req)                          -- a handler of your own
--       if req.path == "/hello" then return 200, { ["Content-Type"] = "text/plain" }, "hi\n" end
--   end)
--   srv:use(httpd.static({ root = "/www" }))       -- then the files
--   srv:run()                                      -- until Ctrl+T
--
-- What bin/httpd is built on.  A request goes to each handler in turn,
-- in the order they were added, until one answers: a handler takes the
-- request and returns status, headers, body (headers a table, Name =
-- value), or nothing to pass it on.  None answers: 404.  A handler that
-- throws: 500, and the error logged.  That's the seam for more than
-- files later (a Lua script per URL, say, or a framework's router).
--
-- A request: { method = "GET", target = "/a%20b?x=1" (as sent), path =
-- "/a b" (decoded), rawPath = "/a%20b", query = "x=1", args = { x = "1" },
-- form = { ... } (a POST's application/x-www-form-urlencoded body),
-- params (args and form together, form's winning), cookies = { ... },
-- version = "HTTP/1.1", headers = { host = ..., ... } (names in lower
-- case; repeated ones joined with ", "), body = "" (as Content-Length
-- says), remote = "10.0.1.5" }.  A header's value may be a list: one
-- line each (Set-Cookie).
--
-- httpd.lua(opts): Lua pages, scripts that answer URLs (see "Lua pages"
-- below); httpd.router(): routes by method and path, for a page to
-- return.  Templates are etlua's (lib/etlua.lua, by Leaf Corcoran).
--
-- One request a connection: every answer says Connection: close.  A
-- request's head may be 8 KiB, its body 64 KiB; a request with a
-- Transfer-Encoding is refused (501), as is HTTP/2 or 0.9.  A connection
-- that hasn't sent a whole request in 10 seconds is closed.  A handler
-- runs to its end before the next request is read: one that waits
-- (sleep, a network call) holds the others up.
--
-- httpd.static(opts): the files under opts.root.  GET and HEAD (else
-- 405).  A folder answers with the first of opts.index that's there
-- ({ "index.html", "index.htm" }), else a listing of what's in it (unless
-- opts.listing is false: 403); a folder asked for without its trailing
-- slash is redirected (301) to it, so relative links work.  ".." in a
-- path is refused (403): nothing outside the root is served.  The
-- Content-Type goes by the file's extension (httpd.TYPES).  opts.fs: the
-- filesystem API (fs).
--
-- httpd.new(opts):dispatch(raw, remote) answers a request held in a
-- string: the response's bytes, its status and the request; nil if the
-- request isn't all there yet.  run() is that, around net.listen.

local net = require("net")
local scan = require("scan")
local text = require("text")
local convert = require("convert")
local path = require("path")
local httpc = require("httpc")
local tables = require("tables")
local fileio = require("fileio")

local H = {}
H.SERVER = "ccnix-httpd"
H.MAX_HEAD, H.MAX_BODY, H.IDLE = 8192, 65536, 10

H.REASONS = {
    [200] = "OK", [201] = "Created", [204] = "No Content", [301] = "Moved Permanently", [302] = "Found",
    [303] = "See Other", [304] = "Not Modified", [307] = "Temporary Redirect", [308] = "Permanent Redirect",
    [400] = "Bad Request", [401] = "Unauthorized", [403] = "Forbidden", [404] = "Not Found",
    [405] = "Method Not Allowed", [408] = "Request Timeout", [413] = "Content Too Large", [414] = "URI Too Long",
    [431] = "Request Header Fields Too Large", [500] = "Internal Server Error", [501] = "Not Implemented",
    [503] = "Service Unavailable", [505] = "HTTP Version Not Supported",
}

H.TYPES = {
    html = "text/html; charset=utf-8", htm = "text/html; charset=utf-8", css = "text/css; charset=utf-8",
    js = "text/javascript; charset=utf-8", json = "application/json", txt = "text/plain; charset=utf-8",
    md = "text/markdown; charset=utf-8", lua = "text/plain; charset=utf-8", xml = "application/xml",
    svg = "image/svg+xml", png = "image/png", jpg = "image/jpeg", jpeg = "image/jpeg", gif = "image/gif",
    ico = "image/x-icon", webp = "image/webp", pdf = "application/pdf", wasm = "application/wasm",
}
H.DEFAULT_TYPE = "application/octet-stream"

--------------------------------------------------------------------------
-- Bits
--------------------------------------------------------------------------

-- s (anything: tostring'd) with & < > " ' as HTML entities (pages' html())
function H.html(s) return convert.html(tostring(s)) end

-- "a=1&b=x+y" -> { a = "1", b = "x y" } (the last of a repeated name).
function H.parseQuery(q)
    local args = {}
    -- query: pair ("&" pair)*; pair: name ["=" value], + a space in each
    for _, pair in ipairs(text.pieces(q or "", "&")) do
        local k, v = text.cut(pair, "=")
        args[convert.urlDecode(k, true)] = convert.urlDecode(v or "", true)
    end
    return args
end

function H.date(t)
    return os.date("!%a, %d %b %Y %H:%M:%S GMT", t or (os.epoch and math.floor(os.epoch("utc") / 1000)) or os.time())
end

-- A small HTML page for an answer that isn't a file: status, headers, body.
function H.page(status, message, headers)
    local title = status .. " " .. (H.REASONS[status] or "")
    local h = { ["Content-Type"] = "text/html; charset=utf-8" }
    for k, v in pairs(headers or {}) do h[k] = v end
    return status, h, "<!DOCTYPE html>\n<html><head><meta charset=\"utf-8\"><title>" .. H.html(title) .. "</title></head>\n"
        .. "<body><h1>" .. H.html(title) .. "</h1>" .. (message and ("<p>" .. H.html(message) .. "</p>") or "")
        .. "<hr><address>" .. H.SERVER .. "</address></body></html>\n"
end

-- The response's bytes.  head: leave the body out (HEAD) but keep its length.
function H.response(status, headers, body, head)
    body = body or ""
    local lines = { "HTTP/1.1 " .. status .. " " .. (H.REASONS[status] or "Unknown") }
    local seen = {}
    local function add(k, v)
        seen[k:lower()] = true
        lines[#lines + 1] = k .. ": " .. tostring(v)
    end
    add("Date", H.date())
    add("Server", H.SERVER)
    for _, k in ipairs(tables.sortedKeys(headers or {})) do
        if not ({ date = true, server = true, connection = true })[k:lower()] then
            local v = headers[k]
            if type(v) == "table" then for _, one in ipairs(v) do add(k, one) end    -- (Set-Cookie, one a line)
            else add(k, v) end
        end
    end
    local noBody = status == 204 or status == 304 or status < 200
    if not seen["content-length"] and not noBody then add("Content-Length", #body) end
    add("Connection", "close")
    return table.concat(lines, "\r\n") .. "\r\n\r\n" .. ((head or noBody) and "" or body)
end

--------------------------------------------------------------------------
-- Requests
--------------------------------------------------------------------------
-- request-line: method " " target " HTTP/" digit "." digit, method in
-- capitals, target without blanks.  method, target, major, minor; nil if
-- the line isn't one.
local function requestLine(line)
    local sc = scan.new(line)
    local method = sc:readWhile(scan.isUpper)
    if method == "" or not sc:accept(" ") then return nil end
    local target = sc:readWhile(function(c) return not scan.isSpace(c) end)
    if target == "" or not sc:accept(" HTTP/") then return nil end
    local major = sc:advance()
    if not scan.isDigit(major) or not sc:accept(".") then return nil end
    local minor = sc:advance()
    if not scan.isDigit(minor) or not sc:atEnd() then return nil end
    return method, target, major, minor
end

-- header: name ":" value, name a token (letters, digits and
-- !#$%&'*+.^_`|~-), the value without the blanks round it; nil if the
-- line isn't one.
local TOKEN_PUNCT = scan.oneOf("!#$%&'*+.^_`|~-")
local function isTokenChar(c) return scan.isAlnum(c) or TOKEN_PUNCT(c) end
local function headerLine(line)
    local sc = scan.new(line)
    local name = sc:readWhile(isTokenChar)
    if name == "" or not sc:accept(":") then return nil end
    return name, text.trim(sc:rest())
end

-- An absolute-form target ("http://host:port/path?q") made the path and
-- query alone; any other target as it is.
local function originForm(target)
    local lower = target:lower()
    local scheme = (text.startsWith(lower, "http://") and "http://") or (text.startsWith(lower, "https://") and "https://")
    if not scheme then return target end
    local sc = scan.new(target, #scheme + 1)
    sc:readWhile(function(c) return c ~= "/" and c ~= "?" end)     -- (the authority)
    return sc:rest()
end

-- A request from raw: the request; nil if it isn't all there yet; or
-- false and the status to refuse it with.
function H.parse(raw)
    local s, e = text.find(raw, "\r\n\r\n")
    if not s then s, e = text.find(raw, "\n\n") end
    if not s then
        if #raw > H.MAX_HEAD then return false, 431 end
        return nil
    end
    if s > H.MAX_HEAD then return false, 431 end
    local lines = text.lines(raw:sub(1, s - 1) .. "\n")
    local method, target, major, minor = requestLine(lines[1] or "")
    if not method then return false, 400 end
    if major ~= "1" then return false, 505 end
    if #target > 2048 then return false, 414 end
    local headers = {}
    for i = 2, #lines do
        local name, value = headerLine(lines[i])
        if not name then return false, 400 end
        httpc.addHeader(headers, name, value)
    end
    if headers["transfer-encoding"] then return false, 501 end
    local len = 0
    if headers["content-length"] then
        local digits = headers["content-length"]
        len = scan.isUnsigned(digits) and tonumber(digits)
        if not len then return false, 400 end
        if len > H.MAX_BODY then return false, 413 end
    end
    if #raw - e < len then return nil end
    target = originForm(target)
    if target == "" then target = "/" end
    if not path.isAbsolute(target) and not (method == "OPTIONS" and target == "*") then return false, 400 end
    local rawPath, query = text.cut(target, "?")
    query = query or ""
    local decoded = convert.urlDecode(rawPath)
    if text.contains(decoded, "\0") then return false, 400 end
    local body = raw:sub(e + 1, e + len)
    local args = H.parseQuery(query)
    local contentType = text.trim((headers["content-type"] or ""):lower())
    local form = text.startsWith(contentType, "application/x-www-form-urlencoded") and H.parseQuery(body) or {}
    local params = tables.copy(args)
    for k, v in pairs(form) do params[k] = v end
    return { method = method, target = target, rawPath = rawPath, path = decoded, query = query, args = args,
             form = form, params = params, cookies = H.parseCookies(headers.cookie),
             version = "HTTP/" .. major .. "." .. minor, headers = headers, body = body }
end

-- "a=1; b=two" -> { a = "1", b = "two" }
function H.parseCookies(s)
    local t = {}
    -- cookies: pair (";" pair)*; pair: name "=" value, the value maybe in "quotes"
    for _, pair in ipairs(text.split(s or "", ";")) do
        local k, v = text.cut(pair, "=")
        if v then
            k, v = text.trim(k), text.trim(v)
            if #v >= 2 and text.startsWith(v, '"') and text.endsWith(v, '"') then v = v:sub(2, -2) end
            if k ~= "" then t[k] = v end
        end
    end
    return t
end

--------------------------------------------------------------------------
-- The server
--------------------------------------------------------------------------
local Server = {}
Server.__index = Server

function H.new(opts)
    opts = opts or {}
    return setmetatable({ port = opts.port or 80, log = opts.log or function() end, handlers = {} }, Server)
end

function Server:use(handler)
    self.handlers[#self.handlers + 1] = handler
    return self
end

function Server:dispatch(raw, remote)
    local req, refused = H.parse(raw)
    if req == nil then return nil end
    local status, headers, body
    if req then
        req.remote = remote
        for _, handler in ipairs(self.handlers) do
            local ok, s, h, b = pcall(handler, req)
            if not ok then
                self.log("error: " .. req.method .. " " .. req.target .. ": " .. tostring(s))
                status, headers, body = H.page(500)
                break
            elseif s then
                status, headers, body = s, h, b
                break
            end
        end
        if not status then status, headers, body = H.page(404, "There's nothing at " .. req.path .. ".") end
    else
        status, headers, body = H.page(refused)
    end
    return H.response(status, headers, body, req and req.method == "HEAD"), status, req or nil, #(body or "")
end

-- Serve until Ctrl+T (or "terminate"); nil and why if it can't listen.
function Server:run()
    local listener, err = net.listen(self.port)
    if not listener then return nil, err end
    local conns = {}
    local function drop(id)
        local k = conns[id]
        conns[id] = nil
        if k and k.conn:state() ~= "CLOSED" then k.conn:close() end
    end
    local function serve(id)
        local k = conns[id]
        while k do
            local data, why = k.conn:read(0)
            if data then k.buf = k.buf .. data
            elseif why == "timeout" then break
            else drop(id); return end
        end
        local out, status, req, size = self:dispatch(k.buf, k.remote)
        if not out then return end
        k.conn:send(out)
        drop(id)
        local firstLine = scan.new(k.buf):readWhile(function(c) return c ~= "\r" and c ~= "\n" end)
        self.log(string.format('%s "%s" %d %d', k.remote, req and (req.method .. " " .. req.target) or firstLine:sub(1, 80),
            status, size))
    end
    self.log("listening on port " .. self.port)
    local sweep = os.startTimer(1)
    local ok, e = pcall(function()
        while true do
            local ev = table.pack(os.pullEventRaw())
            if ev[1] == "terminate" then return
            elseif ev[1] == "net_accept" and ev[2] == self.port then
                local c = listener:poll()
                while c do
                    conns[c:id()] = { conn = c, buf = "", since = os.clock(), remote = (c:remote()) }
                    serve(c:id())
                    c = listener:poll()
                end
            elseif ev[1] == "net_tcp" and conns[ev[2]] then
                serve(ev[2])
            elseif ev[1] == "timer" and ev[2] == sweep then
                for id, k in pairs(conns) do
                    if os.clock() - k.since > H.IDLE then
                        k.conn:send(H.response(H.page(408)))
                        drop(id)
                    end
                end
                sweep = os.startTimer(1)
            end
        end
    end)
    listener:close()
    for id in pairs(conns) do drop(id) end
    if not ok then error(e, 0) end
    return true
end

--------------------------------------------------------------------------
-- Files
--------------------------------------------------------------------------
function H.static(opts)
    local fs = opts.fs or fs
    local root = fs.combine(opts.root or "/", "")
    local index = opts.index or { "index.html", "index.htm" }
    local listing = opts.listing ~= false

    local files = fileio.on(fs)

    local function file(p)
        local data = files.read(p, true)
        if not data then return H.page(403, "That can't be read.") end
        return 200, { ["Content-Type"] = H.TYPES[path.extension(p):lower()] or H.DEFAULT_TYPE }, data
    end

    local function list(p, req)
        local names = fs.list(p)
        table.sort(names, function(a, b)
            local da, db = fs.isDir(fs.combine(p, a)), fs.isDir(fs.combine(p, b))
            if da ~= db then return da end
            return a:lower() < b:lower()
        end)
        local title = "Index of " .. H.html(req.path)
        local out = { "<!DOCTYPE html>\n<html><head><meta charset=\"utf-8\"><title>" .. title .. "</title></head>\n<body><h1>"
            .. title .. "</h1>\n<ul>" }
        if req.path ~= "/" then out[#out + 1] = '<li><a href="../">../</a></li>' end
        for _, name in ipairs(names) do
            local full = fs.combine(p, name)
            local dir = fs.isDir(full)
            out[#out + 1] = string.format('<li><a href="%s%s">%s%s</a>%s</li>', H.html(convert.urlEncode(name)), dir and "/" or "",
                H.html(name), dir and "/" or "", dir and "" or (" " .. fs.getSize(full) .. " bytes"))
        end
        out[#out + 1] = "</ul>\n<hr><address>" .. H.SERVER .. "</address></body></html>\n"
        return 200, { ["Content-Type"] = "text/html; charset=utf-8" }, table.concat(out, "\n")
    end

    return function(req)
        if req.method ~= "GET" and req.method ~= "HEAD" then
            return H.page(405, req.method .. " isn't something files do.", { Allow = "GET, HEAD" })
        end
        local segs = {}
        for _, seg in ipairs(path.segments(req.path)) do     -- (no empty ones: "//" is "/")
            if seg == ".." then return H.page(403, "No .. in a path here.") end
            if seg ~= "." then segs[#segs + 1] = seg end
        end
        local p = fs.combine(root, table.concat(segs, "/"))
        if root ~= "" and p ~= root and not text.startsWith(p, root .. "/") then return H.page(403) end
        if not fs.exists(p) then return H.page(404, "There's nothing at " .. req.path .. ".") end
        if not fs.isDir(p) then return file(p) end
        if not text.endsWith(req.path, "/") then
            return H.page(301, "It's a folder: " .. req.path .. "/",
                { Location = req.rawPath .. "/" .. (req.query ~= "" and ("?" .. req.query) or "") })
        end
        for _, name in ipairs(index) do
            local f = fs.combine(p, name)
            if fs.exists(f) and not fs.isDir(f) then return file(f) end
        end
        if not listing then return H.page(403, "There's no index here, and listings are off.") end
        return list(p, req)
    end
end

--------------------------------------------------------------------------
-- Routes
--------------------------------------------------------------------------
local Router = {}
Router.__index = Router

function H.router() return setmetatable({ routes = {} }, Router) end

-- A route: "/notes/:id" (a :name takes one segment), "/files/*" (* the
-- rest, as params.splat); fn(req, params) answers as a page does.
-- A route's pattern as parts: { text = "/notes/" }, { name = "id" } (":id",
-- a name of letters, digits and _), { splat = true } ("*"); any other
-- character is text.  names: the :names and "splat", in order.
local function routeParts(pattern)
    local sc, parts, names, chars = scan.new(pattern), {}, {}, {}
    local function endText()
        if #chars > 0 then parts[#parts + 1] = { text = table.concat(chars) } end
        chars = {}
    end
    while not sc:atEnd() do
        if sc:at(":") and scan.isNameChar(sc:peek(2)) then
            sc:advance()
            local name = sc:readWhile(scan.isNameChar)
            endText()
            parts[#parts + 1] = { name = name }
            names[#names + 1] = name
        elseif sc:accept("*") then
            endText()
            parts[#parts + 1] = { splat = true }
            names[#names + 1] = "splat"
        else
            chars[#chars + 1] = sc:advance()
        end
    end
    endText()
    return parts, names
end

-- Whether urlPath from at on matches parts from i on, the matches put in
-- caps.  A :name takes one or more characters but "/", a * any; each the
-- most it can that still lets the rest match.
local function matchParts(parts, i, urlPath, at, caps)
    local part = parts[i]
    if not part then return at == #urlPath + 1 end
    if part.text then
        if urlPath:sub(at, at + #part.text - 1) ~= part.text then return false end
        return matchParts(parts, i + 1, urlPath, at + #part.text, caps)
    end
    local last = #urlPath                                       -- (a * can take it all)
    if part.name then
        local stop = text.find(urlPath, "/", at)
        last = (stop or #urlPath + 1) - 1
    end
    local shortest = part.name and at or at - 1                 -- (a :name takes one at least)
    for to = last, shortest, -1 do
        caps[#caps + 1] = urlPath:sub(at, to)
        if matchParts(parts, i + 1, urlPath, to + 1, caps) then return true end
        caps[#caps] = nil
    end
    return false
end

function Router:route(method, pattern, fn)
    local parts, names = routeParts(pattern)
    self.routes[#self.routes + 1] = { method = method, parts = parts, names = names, fn = fn }
    return self
end
for _, m in ipairs({ "get", "post", "put", "delete", "patch" }) do
    Router[m] = function(self, pattern, fn) return self:route(m:upper(), pattern, fn) end
end

-- The route for urlPath (a page's own part of the URL: "/" and on),
-- called; 404 if none matches, 405 (with Allow) if one does for another
-- method.  HEAD takes a GET route.
function Router:dispatch(req, urlPath)
    local allowed = {}
    for _, r in ipairs(self.routes) do
        local caps = {}
        if matchParts(r.parts, 1, urlPath, 1, caps) then
            if r.method == req.method or (req.method == "HEAD" and r.method == "GET") then
                local params = {}
                for i, n in ipairs(r.names) do params[n] = caps[i] end
                return r.fn(req, params)
            end
            allowed[#allowed + 1] = r.method
        end
    end
    if #allowed > 0 then return H.page(405, nil, { Allow = table.concat(allowed, ", ") }) end
    return H.page(404, "There's nothing at " .. req.path .. ".")
end

--------------------------------------------------------------------------
-- Lua pages
--------------------------------------------------------------------------
-- httpd.lua(opts): the Lua scripts in opts.dir answer the URLs under
-- opts.prefix ("/cgi"): /cgi/hello.lua and /cgi/hello run hello.lua, and
-- /cgi/notes/12 notes.lua with "/12" its own part (req.pathInfo); /cgi/
-- runs index.lua.  Nothing else there is served (404), so the scripts'
-- source never is.  Each request runs the script afresh, as the file is
-- now, in an environment of its own over _G:
--   req                the request, and req.script (the script's URL),
--                      req.pathInfo
--   write(...)         add to the page (text/html unless header() says)
--   status(n), header(name, value)
--   redirect(url [, status])   303 unless said; `return redirect(...)`
--   cookie(name, value [, { path, maxAge, httpOnly, sameSite } ])
--   html(s)            s escaped for HTML
--   render(file, vars) an etlua template in the script's folder, filled
--                      in from vars, then the page's names (<%= x %>
--                      escaped, <%- x %> as it is, <% code %>)
--   router()           httpd.router(): `return r` and the routes answer
--   state              a table kept for the script between requests
--   here               the script's folder ("/www/cgi"): for its own files,
--                      which the script root never serves
--   text               lib/text (text.trim, text.split ...), for what
--                      visitors type
-- A script answers with what it writes, or returns a string (the body),
-- status, headers, body, or a router.  An error: 500, and with
-- opts.debug the traceback on the page.  opts.fs: the filesystem API.
function H.lua(opts)
    local fs = opts.fs or fs
    local dir = fs.combine(opts.dir, "")
    local prefix = opts.prefix or "/cgi"
    prefix = path.stripSlashes(prefix)
    if prefix == "/" then prefix = "" end           -- (the whole site: each path is under it)
    local states, templates = {}, {}

    -- The script for the part of a path below prefix: its file, its own
    -- part of the path and the part that named it; nil (and 403) if none.
    local function find(rel)
        local segs = {}
        for _, seg in ipairs(path.segments(rel)) do
            if seg == ".." then return nil, 403 end
            if seg ~= "." then segs[#segs + 1] = seg end
        end
        local at = dir
        for i, seg in ipairs(segs) do
            local p = fs.combine(at, seg)
            local file = text.endsWith(seg, ".lua") and p or (p .. ".lua")
            if fs.exists(file) and not fs.isDir(file) then
                return file, "/" .. table.concat(segs, "/", i + 1), table.concat(segs, "/", 1, i)
            end
            if not fs.isDir(p) then return nil end
            at = p
        end
        local index = fs.combine(at, "index.lua")
        if fs.exists(index) and not fs.isDir(index) then return index, "/", table.concat(segs, "/") end
    end

    local read = fileio.on(fs).read

    local function template(p)
        local source = read(p)
        if not source then error("no template " .. p, 0) end
        local t = templates[p]
        if not t or t.text ~= source then
            local fn, err = require("etlua").compile(source)
            if not fn then error(p .. ": " .. tostring(err), 0) end
            t = { text = source, fn = fn }
            templates[p] = t
        end
        return t.fn
    end

    return function(req)
        if req.path == prefix then
            return H.page(301, nil, { Location = req.rawPath .. "/" .. (req.query ~= "" and ("?" .. req.query) or "") })
        end
        local below = text.stripPrefix(req.path, prefix .. "/")     -- (the path under the prefix)
        if not below then return nil end
        local script, info, named = find(below)
        if not script then
            if info == 403 then return H.page(403, "No .. in a path here.") end
            return H.page(404, "There's nothing at " .. req.path .. ".")
        end
        req.script = prefix .. (named ~= "" and ("/" .. named) or "")
        req.pathInfo = info

        local out, code = {}, 200
        local headers = { ["Content-Type"] = "text/html; charset=utf-8" }
        local cookies = {}
        local env = setmetatable({}, { __index = _G })
        states[script] = states[script] or {}
        env.req, env.state, env.html, env.router = req, states[script], H.html, H.router
        env.here, env.fs, env.text, env.fileio = "/" .. fs.getDir(script), fs, text, fileio.on(fs)
        function env.write(...)
            for i = 1, select("#", ...) do out[#out + 1] = tostring((select(i, ...))) end
        end
        function env.status(n) code = n end
        function env.header(k, v) headers[k] = v end
        function env.redirect(url, n)
            code, headers.Location = n or 303, url
            return true
        end
        function env.cookie(name, value, o)
            o = o or {}
            local c = name .. "=" .. tostring(value) .. "; Path=" .. (o.path or "/")
            if o.maxAge then c = c .. "; Max-Age=" .. math.floor(o.maxAge) end
            if o.httpOnly ~= false then c = c .. "; HttpOnly" end
            c = c .. "; SameSite=" .. (o.sameSite or "Lax")
            cookies[#cookies + 1] = c
        end
        function env.render(name, vars)
            local fn = template(fs.combine(fs.getDir(script), name))
            return fn(setmetatable({}, { __index = function(_, k)
                local v = vars and vars[k]
                if v == nil then v = env[k] end
                return v
            end }))
        end

        -- what the script (or its route) said: status, headers, body
        local function finish(a, b, c)
            if getmetatable(a) == Router then return finish(a:dispatch(req, info)) end
            local body
            if type(a) == "number" then
                code, body = a, c
                for k, v in pairs(b or {}) do headers[k] = v end
            elseif type(a) == "string" then
                body = a
            else
                body = table.concat(out)
            end
            if #cookies > 0 then headers["Set-Cookie"] = cookies end
            return code, headers, body or ""
        end

        local source = read(script)
        local fn, err = source and load(source, "@/" .. script, "t", env)
        local ok, a, b, c
        if fn then
            ok, a, b, c = xpcall(fn, function(e) return debug.traceback(tostring(e), 2) end)
            if ok then ok, a, b, c = xpcall(finish, function(e) return debug.traceback(tostring(e), 2) end, a, b, c) end
        else
            a = err or ("can't read " .. script)
        end
        if not ok then
            if opts.log then opts.log("error: " .. req.method .. " " .. req.target .. ": " .. (text.cut(tostring(a), "\n"))) end
            local status, h, body = H.page(500, "The script " .. req.script .. " failed.")
            if opts.debug then body = text.replace(body, "</body>", "<pre>" .. H.html(a) .. "</pre></body>") end
            return status, h, body
        end
        return a, b, c
    end
end

return H
