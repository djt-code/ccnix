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
-- what, the status and the body's size.
--
-- Settings, which the options override:
--   httpd.root      the document root (/www)
--   httpd.port      the TCP port (80)
--   httpd.listing   false: no folder listings (true)
--   httpd.index     the index files to look for, in order, spaces
--                   between ("index.html index.htm")
--
-- It needs the network (`ip up`).  To keep it running in the background,
-- with init:
--   service add httpd httpd
--   service enable httpd            (at boot)
--   service start httpd
-- deploy/setup httpd does all that.  Static files only, for now: lib/httpd
-- takes handlers of your own ahead of the files (its top comment says
-- how).  Try it with curl: `curl -i http://<this computer>/`.

package.path = (ccnix and ccnix.lib or "/" .. fs.getDir(fs.getDir(shell.getRunningProgram())) .. "/lib/?.lua;") .. package.path  -- ccnix's lib/, or the one beside bin/
local cu = require("cu").init("httpd", "httpd [-L] [-p port] [root]")
local net = require("net")
local httpd = require("httpd")

local opts, operands = cu.getopt({ ... }, "Lp:")
if #operands > 1 then cu.usageError() end
local root = operands[1] and shell.resolve(operands[1]) or settings.get("httpd.root") or "/www"
local port = tonumber(opts.p or settings.get("httpd.port") or 80)
if not port or port < 1 or port > 65535 or port % 1 ~= 0 then cu.usageError("bad port " .. tostring(opts.p or settings.get("httpd.port"))) end
local listing = not opts.L and settings.get("httpd.listing") ~= false
local index = {}
for name in tostring(settings.get("httpd.index") or "index.html index.htm"):gmatch("[^%s,]+") do index[#index + 1] = name end

if not net.stack() then cu.fail("the network isn't up (`ip up`)"); return cu.exit() end
if not fs.isDir(root) then cu.fail("no folder " .. root .. ": make it, or set httpd.root"); return cu.exit() end

local srv = httpd.new({ port = port, log = function(s) print(os.date("%H:%M ") .. s) end })
srv:use(httpd.static({ root = root, index = index, listing = listing }))
print("serving /" .. fs.combine(root, "") .. (listing and "" or " (no listings)") .. " on port " .. port)
local ok, why = srv:run()
if not ok then cu.fail(why) end
return cu.exit()
