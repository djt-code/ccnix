-- guestbook.lua -- a guestbook: a Lua page for ccnix's httpd (help httpd-pages)
--
-- `setup httpd --example` puts it and its template, guestbook.etlua, in
-- httpd's script root, where it answers at /cgi/guestbook.  A visitor
-- signs with a name and a message; the newest come first, the last 100
-- are kept.  They're saved in guestbook.db beside it, so they outlast a
-- restart; the script root never serves that file.  Delete it to start
-- over.

local DB = fs.combine(here, "guestbook.db")
local MAX_NAME, MAX_TEXT, KEEP = 40, 500, 100

-- the entries: in memory once read (state lasts while httpd runs), from
-- the file the first time
local function entries()
    if not state.entries then
        local list
        if fs.exists(DB) then
            local h = fs.open(DB, "r")
            list = textutils.unserialize(h.readAll() or "")
            h.close()
        end
        state.entries = type(list) == "table" and list or {}
    end
    return state.entries
end

local function save(list)
    local h = fs.open(DB, "w")
    h.write(textutils.serialize(list))
    h.close()
end

local list = entries()
local problem
if req.method == "POST" then
    local name, message = text.trim(req.form.name or ""), text.trim(req.form.message or "")
    if name == "" or message == "" then
        problem = "A name and a message, please."
    elseif #name > MAX_NAME or #message > MAX_TEXT then
        problem = "At most " .. MAX_NAME .. " characters of name and " .. MAX_TEXT .. " of message."
    else
        table.insert(list, 1, { name = name, text = message, at = os.date("!%Y-%m-%d %H:%M UTC") })
        while #list > KEEP do table.remove(list) end
        save(list)
        return redirect(req.script)                -- (so a reload doesn't sign again)
    end
    status(400)
end
return render("guestbook.etlua", { entries = list, problem = problem, name = req.form.name, message = req.form.message })
