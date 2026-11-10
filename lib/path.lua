-- path.lua -- path strings: names, parents, joining and tidying
--
--   local path = require("path")
--   path.basename("/usr/lib/x.lua", ".lua")   --> "x"
--   path.dirname("/usr/lib/x.lua")            --> "/usr/lib"
--   path.join("/etc", "net", "hosts")         --> "/etc/net/hosts"
--   path.normalize("a//b/./c/../d/")          --> "a/b/d"
--   path.resolve("/home/me", "../lib")        --> "/home/lib"
--
-- Only strings: nothing here looks at the disk (that's fs, and
-- shell.resolve for the working directory).  Paths are split at "/".
--
--   path.basename(p [, suffix])  the last name in p, as POSIX basename
--                         gives it: trailing slashes ignored, "/" for all
--                         slashes, suffix taken off its end (unless that
--                         would leave nothing)
--   path.dirname(p)       all of p before its last name, as POSIX dirname:
--                         "." when there's no slash, "/" at the top
--   path.stripSlashes(p)  p without the slashes at its end; "/" if p is
--                         only slashes
--   path.isAbsolute(p)    p starts with "/"
--   path.segments(p)      the names in p, as a list (no empty ones)
--   path.join(a, b, ...)  the parts with one "/" between each; a part
--                         starting with "/" starts over from it
--   path.normalize(p)     p with "//" as "/", the "." names gone and each
--                         ".." taking off the name before it (none above
--                         "/"; leading ones kept in a relative path);
--                         "." if nothing's left of a relative one
--   path.resolve(dir, p)  p from dir: normalize(join(dir, p))
--   path.extension(p)     what follows the last "." of p's last name
--                         ("lua"); "" if none, or if the dot is its first
--                         character (".profile")

local path = {}

local function isSlash(c) return c == "/" end

function path.isAbsolute(p) return p:sub(1, 1) == "/" end

function path.stripSlashes(p)
    local to = #p
    while to > 1 and isSlash(p:sub(to, to)) do to = to - 1 end
    if to == 1 and isSlash(p:sub(1, 1)) then return "/" end
    return p:sub(1, to)
end

function path.segments(p)
    local out, from = {}, 1
    while from <= #p + 1 do
        local at = p:find("/", from, true) or #p + 1
        local name = p:sub(from, at - 1)
        if name ~= "" then out[#out + 1] = name end
        from = at + 1
    end
    return out
end

-- p split at its last slash (after the trailing ones are gone): what's
-- before it and the name after it; nil before if there's no slash
local function lastName(p)
    p = path.stripSlashes(p)
    if p == "/" then return nil, "/" end
    local at
    for k = #p, 1, -1 do
        if isSlash(p:sub(k, k)) then at = k; break end
    end
    if not at then return nil, p end
    return p:sub(1, at - 1), p:sub(at + 1)
end

function path.basename(p, suffix)
    if p == "" then return "" end
    local _, name = lastName(p)
    if suffix and suffix ~= "" and suffix ~= name and name:sub(-#suffix) == suffix then
        name = name:sub(1, #name - #suffix)
    end
    return name
end

function path.dirname(p)
    local before, name = lastName(p)
    if name == "/" then return "/" end
    if not before then return "." end
    before = path.stripSlashes(before)
    if before == "" then return "/" end
    return before
end

function path.join(...)
    local out = ""
    for _, part in ipairs({ ... }) do
        if part ~= "" then
            if path.isAbsolute(part) or out == "" then out = part
            elseif isSlash(out:sub(-1)) then out = out .. part
            else out = out .. "/" .. part end
        end
    end
    return out
end

function path.normalize(p)
    local absolute, names = path.isAbsolute(p), {}
    for _, name in ipairs(path.segments(p)) do
        if name == ".." then
            if #names > 0 and names[#names] ~= ".." then names[#names] = nil
            elseif not absolute then names[#names + 1] = ".." end
        elseif name ~= "." then
            names[#names + 1] = name
        end
    end
    local body = table.concat(names, "/")
    if absolute then return "/" .. body end
    return body == "" and "." or body
end

function path.resolve(dir, p) return path.normalize(path.join(dir, p)) end

function path.extension(p)
    local name = path.basename(p)
    for k = #name, 2, -1 do
        if name:sub(k, k) == "." then return name:sub(k + 1) end
    end
    return ""
end

return path
