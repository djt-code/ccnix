-- claudeprompt.lua -- claude's prompt: a line from the keyboard with a shell's keys
--
--   local prompt = require("claudeprompt").new{ history = "/.claude_history", pager = true }
--   local line, back = prompt:read("Goal: ")
--
-- What claude (turtle/claude.lua) reads at its prompts: the goal, the
-- next line after a reply, and the y/N confirms.  It reads through
-- lib/readline, so the prompt has ccsh's keys (that file's header lists
-- them): moving by character and word, cutting and Ctrl+Y, Ctrl+L, the
-- history with Up, Down and Ctrl+R, and Tab.  As a shell has them:
--
--   Ctrl+C       with something typed, drops the line ("^C", a new
--                prompt); on an empty line it ends the session, as Ctrl+D
--                does; at a confirm it is no
--   Ctrl+D       on an empty line, ends the session; at a confirm, no
--   Tab          completes the prompt's commands (prompt.commands, a
--                list: /new, /tidy...), shown in grey as ccsh shows them
--   Shift+Enter  the goal goes on on the next line ("... "); Enter sends
--                all of it.  A paste brings its first line only
--   Alt+Enter    the same, for telnet, which sends no Shift (Esc, Enter)
--   PgUp, the wheel up   on an empty line, the pager (opts.pager)
--   Ctrl+T held  stops claude, as before (the error "Terminated")
--
-- The goals and lines typed are kept in opts.history (a file, the last
-- 1000 lines), so Up brings back one from an earlier session; a goal of
-- several lines is kept as one, its lines joined by spaces.  The confirms
-- aren't kept.  Without lib/readline it reads with CraftOS read().
--
-- prompt:read(label) returns the line ("" for the end of the session),
-- or nil and how far to scroll the pager up (opts.pager: PgUp or the
-- wheel on an empty line).

local P = {}
P.__index = P

local MORE = "... "                 -- the prompt of a goal's next line

function P.new(opts)
    opts = opts or {}
    local self = setmetatable({ historyPath = opts.history, max = opts.max or 1000, pager = opts.pager,
                                commands = opts.commands or {} }, P)
    local ok, rl = pcall(require, "readline")
    self.rl = ok and type(rl) == "table" and rl.read and rl or nil
    return self
end

-- The history: its lines, read from the file the first time
function P:history()
    if not self.lines then
        if self.rl and self.historyPath and self.rl.historyFile then
            self.lines, self.add = self.rl.historyFile(self.historyPath, self.max)
        else
            self.lines, self.add = {}, function() end
        end
    end
    return self.lines
end

-- Tab: what could follow a line that starts a command
function P:complete(line)
    local out = {}
    if line:sub(1, 1) ~= "/" then return out end
    local names = {}
    for _, name in ipairs(self.commands) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
        if #name > #line and name:sub(1, #line) == line then out[#out + 1] = name:sub(#line + 1) end
    end
    return out
end

-- CraftOS read(), with the wheel up or PgUp before anything is typed
-- coming back as how far to scroll (what the prompt did before
-- lib/readline)
function P:plainRead(label)
    local colour = colours and term and term.isColour and term.isColour()
    if colour then term.setTextColour(colours.yellow) end
    write(label)
    if colour then term.setTextColour(colours.white) end
    if not (self.pager and term and parallel) then return read() or "" end
    local line, back, typed
    parallel.waitForAny(
        function() line = read() end,
        function()
            while true do
                local ev, a = os.pullEvent()
                if ev == "char" or ev == "paste" then typed = true
                elseif not typed and ev == "mouse_scroll" and a < 0 then
                    back = 3                -- as far as a notch goes in the pager
                    return
                elseif not typed and ev == "key" and a == keys.pageUp then
                    back = select(2, term.getSize()) - 2      -- a page
                    return
                end
            end
        end)
    if back then return nil, back end
    return line or ""
end

function P:read(label)
    if not self.rl then return self:plainRead(label) end
    local confirm = label:find("[y/N]", 1, true) ~= nil
    local pager = self.pager and not confirm
    local lines, shown = {}, label
    while true do
        local first = #lines == 0
        local line, why, partial = self.rl.read({
            prompt = shown, promptColour = colours.yellow, colour = colours.white,
            history = not confirm and self:history() or nil,
            complete = not confirm and first and function(l) return self:complete(l) end or nil,
            more = not confirm,
            -- (Ctrl+C on an empty line ends the session, as Ctrl+D; with something typed it drops it)
            ctrl = { c = function(e) return e.line == "" and "eof" or "interrupt" end },
            keys = pager and first and { [keys.pageUp] = function(e)
                if e.line == "" then return "page" end
            end } or nil,
            events = pager and first and { mouse_scroll = function(e, dir)
                if e.line == "" and dir and dir < 0 then return "wheel" end
            end } or nil,
        })
        if line then
            lines[#lines + 1] = line
            break
        end
        if why == "terminate" then error("Terminated", 0) end
        if why == "page" then return nil, select(2, term.getSize()) - 2 end
        if why == "wheel" then return nil, 3 end
        if why == "eof" then
            print()
            return ""
        end
        if why == "more" then
            lines[#lines + 1] = partial or ""
            shown = MORE
        elseif why == "interrupt" and confirm then
            return ""
        end
        -- (interrupt: the line dropped, "^C" shown; the prompt again, the lines before it dropped too)
        if why == "interrupt" then lines, shown = {}, label end
    end
    local goal = table.concat(lines, "\n")
    if not confirm then
        self:history()
        self.add(table.concat(lines, " "))
    end
    return goal
end

return P
