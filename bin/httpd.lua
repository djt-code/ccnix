-- httpd.lua -- a web server: the files under a folder, over HTTP (lib/httpd.lua)
--
--   httpd [-L] [-p port] [root]     serve root (else httpd.root) until Ctrl+T
--
-- Each request is answered with the file at its path under the document
-- root.  A folder answers with its index.html or index.htm (the first
-- there; httpd.index names others), else a listing of what's in it, with
-- links; -L (or httpd.listing false) turns listings off, and a folder
-- with no index is then refused (403).  GET and HEAD; nothing above the
-- root is served (a path with .. is refused).  The Content-Type goes by
-- the file's extension.  Each request is logged as it's answered: who,
-- what, the status and the body's size; on this screen and in the system
-- log, /var/log/httpd.log (`help syslog`).
--
-- Lua pages: the scripts in the script root (httpd.cgi, the folder cgi in
-- the document root) answer the URLs under it, /cgi/...: /cgi/hello.lua or
-- /cgi/hello runs hello.lua, /cgi/ index.lua.  A script writes the page,
-- reads the request (req.params: the query and a POSTed form; req.cookies)
-- and may route by method and path; its source is never served.  A
-- script root outside the document root answers at /<its name>/.  The
-- first one:
--   write("<h1>Hello, ", html(req.params.name or "world"), "</h1>",
--         "<form method=post><input name=name><button>Hi</button></form>")
-- `help httpd-pages` has the rest: templates (etlua's), routes, cookies,
-- redirects, state kept between requests.
--
-- Settings, which the options override:
--   httpd.root      the document root (/www)
--   httpd.port      the TCP port (80)
--   httpd.listing   false: no folder listings (true)
--   httpd.index     the index files to look for, in order, spaces
--                   between ("index.html index.htm")
--   httpd.cgi       the script root: a folder in the document root, or
--                   a path (cgi); "" for no Lua pages
--   httpd.debug     true: a failed script's traceback on its error page
--   httpd.facility  the system log's facility it logs as (local7: the
--                   rules file that in /var/log/httpd.log; `help syslog`)
--
-- It needs the network (`ip up`).  To keep it running in the background,
-- with init:
--   service add httpd httpd
--   service enable httpd            (at boot)
--   service start httpd
-- deploy/setup httpd does all that.  lib/httpd takes handlers of your own
-- too (its top comment says how).  Try it with curl: `curl -i
-- http://<this computer>/`.  A script runs to its end before the next
-- request is read, so one that waits holds the others up.

package.path = (ccnix and ccnix.lib or "/" .. fs.getDir(fs.getDir(shell.getRunningProgram())) .. "/lib/?.lua;") .. package.path  -- ccnix's lib/, or the one beside bin/
local cu = require("cu").init("httpd", "httpd [-L] [-p port] [root]")
local net = require("net")
local httpd = require("httpd")
local text = require("text")
local convert = require("convert")
local path = require("path")
local sysenv = require("sysenv")

local opts, operands = cu.getopt({ ... }, "Lp:")
if #operands > 1 then cu.usageError() end
local root = operands[1] and shell.resolve(operands[1]) or settings.get("httpd.root") or "/www"
local port
if opts.p then port = convert.toInteger(opts.p) else port = sysenv.setting("httpd.port", 80) end
if not port or port < 1 or port > 65535 or port % 1 ~= 0 then cu.usageError("bad port " .. tostring(opts.p or settings.get("httpd.port"))) end
local listing = not opts.L and settings.get("httpd.listing") ~= false
local index = {}
for _, item in ipairs(text.split(tostring(settings.get("httpd.index") or "index.html index.htm"), ",")) do
    for _, name in ipairs(text.words(item)) do index[#index + 1] = name end     -- (names between commas or blanks)
end

if not net.stack() then cu.fail("the network isn't up (`ip up`)"); return cu.exit() end
if not fs.isDir(root) then cu.fail("no folder " .. root .. ": make it, or sysctl httpd.root=<folder>"); return cu.exit() end

-- each request, and what failed, to the system log (and this screen)
local syslog = require("log").new("httpd", settings.get("httpd.facility") or "local7", { perror = true })
local function log(s)
    local err = text.stripPrefix(s, "error: ")
    if err then syslog.err(err) else syslog.info(s) end
end
local srv = httpd.new({ port = port, log = log })
-- the script root: in the document root, it answers at its own path there;
-- elsewhere, at /<its name>
local cgi = settings.get("httpd.cgi")
if cgi == nil then cgi = "cgi" end
local pages
if cgi ~= "" and cgi ~= false then
    local dir = path.isAbsolute(tostring(cgi)) and fs.combine(tostring(cgi), "") or fs.combine(root, tostring(cgi))
    local top = fs.combine(root, "")
    local under = top == "" and dir or text.stripPrefix(dir, top .. "/")
    pages = "/" .. (under or fs.getName(dir))
    srv:use(httpd.lua({ dir = dir, prefix = pages, debug = settings.get("httpd.debug") == true, log = log }))
    pages = pages .. "/ runs /" .. dir .. (fs.isDir(dir) and "" or " (not there yet)")
end
srv:use(httpd.static({ root = root, index = index, listing = listing }))
print("serving /" .. fs.combine(root, "") .. (listing and "" or " (no listings)") .. " on port " .. port)
if pages then print("Lua pages: " .. pages) end
local ok, why = srv:run()
if not ok then cu.fail(why) end
return cu.exit()
