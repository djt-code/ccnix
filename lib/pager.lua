-- pager.lua -- show text a screenful at a time, like less
--
--   local pager = require("pager")
--   pager.page(text)            -- a string, or a list of lines
--   pager.page(text, opts)      -- with options:
--     wrap = true     long lines wrap at word breaks instead of scrolling
--                     sideways
--     from = n        open at line n of the text (math.huge: at the end)
--     up = n          then n rows up from there
--     always = true   open the viewer even if the text fits on the screen
--
-- In the list, a line can also be { text, fg }: fg gives each character's
-- colour as term.blit does, one hex digit apiece ("0" white, "e" red, ...).
-- On a colour screen the line is drawn in those colours; elsewhere as
-- plain text.  pager.blitOf(colour) is a colour's digit.
--
-- Text that fits on the screen is just printed.  Anything longer or wider
-- opens in a viewer: every line but the bottom one shows text, the bottom
-- one says where you are.  Lines aren't wrapped unless asked; scroll
-- sideways instead.
--
--   mouse wheel           3 lines up / down
--   space, f, PgDn        a page down (the screen less one line)
--   b, PgUp               a page up
--   j, down, Enter        a line down
--   k, up                 a line up
--   d / u                 half a page down / up
--   g, Home / G, End      the top / the bottom
--   l, right / h, left    8 columns right / left
--   0 / $                 the left edge / the end of the widest line
--   q                     back to the shell (what's on screen stays)

local scan = require("scan")
local text = require("text")

local P = {}

local HSTEP = 8            -- columns per sideways step
local WHEEL = 3            -- lines per notch of the mouse wheel

-- The text as a list of lines: no carriage returns, tabs as 4 spaces;
-- no text at all is one empty line.
function P.lines(s)
    local out = text.lines(text.replace(text.replace(s, "\r", ""), "\t", "    "))
    if #out == 0 then out[1] = "" end
    return out
end

local HEX = "0123456789abcdef"

-- A line's text, whether it's a string or { text, fg }.
local function textOf(l) return type(l) == "table" and l[1] or l end

local function colourScreen()
    return term.isColour ~= nil and term.isColour() and term.blit ~= nil
end

-- The blit digit of a colour (colours.red -> "e").
function P.blitOf(colour)
    local n = 0
    while colour > 1 do colour = colour / 2; n = n + 1 end
    return HEX:sub(n + 1, n + 1)
end

-- `lines` wrapped to `w` columns at spaces (a word longer than a row is
-- cut), and for each line the row it starts on.  A coloured line's rows
-- keep their colours.
function P.wrap(lines, w)
    local rows, first = {}, {}
    for i, l in ipairs(lines) do
        first[i] = #rows + 1
        local body, fg = textOf(l), type(l) == "table" and l[2] or nil
        local function row(a, b)
            rows[#rows + 1] = fg and { body:sub(a, b), fg:sub(a, b) } or body:sub(a, b)
        end
        local pos, n, added = 1, #body, false
        while n - pos + 1 > w do
            local chunk = body:sub(pos, pos + w)
            -- break at the chunk's last space, if there's text before it
            local before, after = text.cutLast(chunk, " ")
            if after and not scan.isBlank(before) then
                local cut = #before + 1                         -- (where the space is)
                row(pos, pos + cut - 2)
                pos = pos + cut
                while body:sub(pos, pos) == " " do pos = pos + 1 end
            else
                row(pos, pos + w - 1)
                pos = pos + w
            end
            added = true
        end
        if pos <= n or not added then row(pos, n) end
    end
    return rows, first
end

-- Draw columns left.. of line `l` at the cursor, `w` wide at most.
function P.drawLine(l, left, w)
    local shown = textOf(l):sub(left, left + w - 1)
    if type(l) == "table" and l[2] and colourScreen() then
        local fg = text.padRight(l[2]:sub(left, left + w - 1), #shown, "0")
        term.blit(shown, fg, string.rep("f", #shown))
    else
        term.write(shown)
    end
end

-- Print line `l` (a row at most `w` wide) as print does; a coloured one
-- in its colours on a colour screen.
local function printLine(l, w)
    if type(l) ~= "table" or not l[2] or not colourScreen() then return print(textOf(l)) end
    P.drawLine(l, 1, w)
    print()
end

function P.page(src, opts)
    opts = opts or {}
    local lines = type(src) == "table" and src or P.lines(src)
    local widest = 0
    for _, l in ipairs(lines) do widest = math.max(widest, #textOf(l)) end

    local w, h = term.getSize()
    if not opts.always and #lines <= h - 1 and (widest <= w or opts.wrap) then
        local rows = opts.wrap and P.wrap(lines, w) or lines
        if #rows <= h - 1 then
            for _, l in ipairs(rows) do printLine(l, w) end
            return
        end
    end

    local rows, first, wrappedAt = lines, nil, nil
    local top, left = opts.from or 1, 1
    local up = opts.up
    -- under init, the wheel is the pager's while it shows, not the
    -- console's scrollback
    local kernel = rawget(_G, "proc")
    local claimed, owned = type(kernel) == "table" and kernel.ownScrollback and kernel.ownScrollback(true)
    while true do
        w, h = term.getSize()
        if opts.wrap and wrappedAt ~= w then
            -- (again if the screen changed width), keeping the line at the top
            local line = 1
            if first then
                for i = #first, 1, -1 do if first[i] <= top then line = i; break end end
            else
                line = top
            end
            rows, first = P.wrap(lines, w)
            wrappedAt = w
            top = first[line] or #rows + 1
            widest = 0
            for _, l in ipairs(rows) do widest = math.max(widest, #textOf(l)) end
        end
        local view = h - 1
        local step = math.max(1, view - 1)      -- a page keeps one line of the last
        local maxTop = math.max(1, #rows - view + 1)
        local maxLeft = math.max(1, widest - w + 1)
        if up then top, up = math.min(top, maxTop) - up, nil end
        top = math.max(1, math.min(top, maxTop))
        left = math.max(1, math.min(left, maxLeft))

        term.setBackgroundColour(colours.black)
        term.setTextColour(colours.white)
        for r = 1, view do
            term.setCursorPos(1, r)
            term.clearLine()
            local l = rows[top + r - 1]
            if l then P.drawLine(l, left, w) end
        end
        local status = string.format("%d-%d/%d", top, math.min(top + view - 1, #rows), #rows)
        if maxLeft > 1 then status = status .. " col " .. left end
        if top >= maxTop then status = status .. " END" end
        status = status .. "  q:quit"
        term.setCursorPos(1, h)
        term.setBackgroundColour(colours.white)
        term.setTextColour(colours.black)
        term.clearLine()
        term.write(status:sub(1, w))
        term.setBackgroundColour(colours.black)
        term.setTextColour(colours.white)

        -- letters and space come as char events (taking the key's char
        -- event off the queue, so q doesn't reach the shell's prompt);
        -- keys with no char as key events
        local ev, k = os.pullEvent()
        if ev == "mouse_scroll" then
            top = top + k * WHEEL                  -- k: 1 down, -1 up
        elseif ev == "char" then
            if k == "q" or k == "Q" then break
            elseif k == " " or k == "f" then top = top + step
            elseif k == "b" then top = top - step
            elseif k == "j" then top = top + 1
            elseif k == "k" then top = top - 1
            elseif k == "d" then top = top + math.floor(view / 2)
            elseif k == "u" then top = top - math.floor(view / 2)
            elseif k == "g" then top = 1
            elseif k == "G" then top = maxTop
            elseif k == "l" then left = left + HSTEP
            elseif k == "h" then left = left - HSTEP
            elseif k == "0" then left = 1
            elseif k == "$" then left = maxLeft
            end
        elseif ev == "key" then
            if k == keys.pageDown then top = top + step
            elseif k == keys.pageUp then top = top - step
            elseif k == keys.down or k == keys.enter then top = top + 1
            elseif k == keys.up then top = top - 1
            elseif k == keys.home then top = 1
            elseif k == keys["end"] then top = maxTop
            elseif k == keys.right then left = left + HSTEP
            elseif k == keys.left then left = left - HSTEP
            end
        end
    end
    if claimed and not owned then kernel.ownScrollback(false) end
    term.setCursorPos(1, h)
    term.clearLine()
end

return P
