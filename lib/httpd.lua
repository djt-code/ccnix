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
-- version = "HTTP/1.1", headers = { host = ..., ... } (names in lower
-- case; repeated ones joined with ", "), body = "" (as Content-Length
-- says), remote = "10.0.1.5" }.
--
-- One request a connection: every answer says Connection: close.  A
-- request's head may be 8 KiB, its body 64 KiB; a request with a
-- Transfer-Encoding is refused (501), as is HTTP/2 or 0.9.  A connection
-- that hasn't sent a whole request in 10 seconds is closed.
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
function H.html(s)
    return (tostring(s):gsub("[&<>\"']", { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ['"'] = "&quot;", ["'"] = "&#39;" }))
end

function H.unescape(s)
    return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

-- A path segment as it may go in a URL.
function H.escape(s)
    return (s:gsub("[^%w%-._~!$&'()*+,;=:@]", function(c) return string.format("%%%02X", c:byte()) end))
end

-- "a=1&b=x+y" -> { a = "1", b = "x y" } (the last of a repeated name).
function H.parseQuery(q)
    local args = {}
    for pair in (q or ""):gmatch("[^&]+") do
        local k, v = pair:match("^([^=]*)=?(.*)$")
        args[H.unescape((k:gsub("%+", " ")))] = H.unescape((v:gsub("%+", " ")))
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
    local names = {}
    for k in pairs(headers or {}) do names[#names + 1] = k end
    table.sort(names)
    for _, k in ipairs(names) do
        if not ({ date = true, server = true, connection = true })[k:lower()] then add(k, headers[k]) end
    end
    local noBody = status == 204 or status == 304 or status < 200
    if not seen["content-length"] and not noBody then add("Content-Length", #body) end
    add("Connection", "close")
    return table.concat(lines, "\r\n") .. "\r\n\r\n" .. ((head or noBody) and "" or body)
end

--------------------------------------------------------------------------
-- Requests
--------------------------------------------------------------------------
-- A request from raw: the request; nil if it isn't all there yet; or
-- false and the status to refuse it with.
function H.parse(raw)
    local s, e = raw:find("\r\n\r\n", 1, true)
    if not s then s, e = raw:find("\n\n", 1, true) end
    if not s then
        if #raw > H.MAX_HEAD then return false, 431 end
        return nil
    end
    if s > H.MAX_HEAD then return false, 431 end
    local lines = {}
    for l in (raw:sub(1, s - 1) .. "\n"):gmatch("(.-)\r?\n") do lines[#lines + 1] = l end
    local method, target, major, minor = (lines[1] or ""):match("^(%u+) (%S+) HTTP/(%d)%.(%d)$")
    if not method then return false, 400 end
    if major ~= "1" then return false, 505 end
    if #target > 2048 then return false, 414 end
    local headers = {}
    for i = 2, #lines do
        local name, value = lines[i]:match("^([%w!#$%%&'*+.^_`|~-]+):%s*(.-)%s*$")
        if not name then return false, 400 end
        name = name:lower()
        headers[name] = headers[name] and (headers[name] .. ", " .. value) or value
    end
    if headers["transfer-encoding"] then return false, 501 end
    local len = 0
    if headers["content-length"] then
        len = tonumber(headers["content-length"]:match("^%d+$") or "")
        if not len then return false, 400 end
        if len > H.MAX_BODY then return false, 413 end
    end
    if #raw - e < len then return nil end
    target = target:match("^[Hh][Tt][Tt][Pp][Ss]?://[^/?]*(.*)$") or target   -- (absolute-form)
    if target == "" then target = "/" end
    if target:sub(1, 1) ~= "/" and not (method == "OPTIONS" and target == "*") then return false, 400 end
    local rawPath, query = target:match("^([^?]*)%??(.*)$")
    local path = H.unescape(rawPath)
    if path:find("%z") then return false, 400 end
    return { method = method, target = target, rawPath = rawPath, path = path, query = query,
             args = H.parseQuery(query), version = "HTTP/" .. major .. "." .. minor, headers = headers,
             body = raw:sub(e + 1, e + len) }
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
        self.log(string.format('%s "%s" %d %d', k.remote, req and (req.method .. " " .. req.target) or k.buf:match("^[^\r\n]*"):sub(1, 80),
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

    local function file(p)
        local h = fs.open(p, "rb")
        if not h then return H.page(403, "That can't be read.") end
        local data = h.readAll() or ""
        h.close()
        local ext = p:match("%.([^./]+)$")
        return 200, { ["Content-Type"] = H.TYPES[ext and ext:lower()] or H.DEFAULT_TYPE }, data
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
            out[#out + 1] = string.format('<li><a href="%s%s">%s%s</a>%s</li>', H.html(H.escape(name)), dir and "/" or "",
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
        for seg in req.path:gmatch("[^/]+") do
            if seg == ".." then return H.page(403, "No .. in a path here.") end
            if seg ~= "." then segs[#segs + 1] = seg end
        end
        local p = fs.combine(root, table.concat(segs, "/"))
        if root ~= "" and p ~= root and p:sub(1, #root + 1) ~= root .. "/" then return H.page(403) end
        if not fs.exists(p) then return H.page(404, "There's nothing at " .. req.path .. ".") end
        if not fs.isDir(p) then return file(p) end
        if req.path:sub(-1) ~= "/" then
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

return H
