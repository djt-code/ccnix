-- ccsh.lua -- ccsh, a small POSIX-style shell for CraftOS
--
--   ccsh                               an interactive shell
--   ccsh -c 'commands' [name [arg...]] run one command line
--   ccsh script [arg...]               run a file of commands
--
-- ccsh runs inside the stock CraftOS shell and has it find and run the
-- programs (the same path, aliases and directory; cd, alias and set work
-- as they always do).  What it adds:
--
--   a | b | c             pipes.  Each command runs to its end, then the
--                         next reads what it wrote: nothing streams, so
--                         `a | head` still runs all of a.
--   < f   > f   >> f      redirects; also 2> f, 2>> f, 2>&1, >&2, n>&-,
--                         and &> f (output and errors to f), &>> f.
--                         /dev/null works for reading and writing.
--   a ; b   a && b   a || b   ! a      and a newline is a ;
--   'single' "double" \x  quoting; # starts a comment.  A line ending in
--                         \, |, &&, || or inside quotes goes on to the next.
--   X=value $X ${X} $? $# $1..$9 ${10} $@ "$@" $* $$ $PPID $! $0
--                         variables.  $PATH is the shell's path (setting
--                         it changes the path), $PWD its directory and
--                         $HOSTNAME the computer's label (its ID if it
--                         has none).  $! is the last & job's process ID.
--                         $$ is the shell's (under init; else the
--                         computer's ID), $PPID its parent's.
--   ${X:-word}            word if X is unset or empty; ${X:=word} that,
--                         and X set to it; ${X:+word} word if X is set
--                         and not empty, else nothing; ${X:?word} if X is
--                         unset or empty, an error (word the message) and
--                         a script ends.  Without the colon (${X-word}),
--                         only unset counts.  The word is expanded:
--                         ${X:-$HOME}.
--   export X  X=1 cmd     the environment.  Programs read it with
--                         os.getenv("X") (and change their own copy with
--                         os.setenv(name, value), list it with
--                         os.environ()): the exported variables (PS1 is
--                         one), PATH, PWD and HOSTNAME, and for one
--                         command its own X=1 words.  A
--                         ccsh run from ccsh starts with them as
--                         exported variables; `env` shows them.
--   PS1                   the prompt, an exported variable: \h (label, or
--                         ID), \w (the directory), \W (its last part), \i
--                         (the ID), \$, \n and \\: PS1='\h \W\$ '.  It
--                         starts as '\h:\w\$ ' ("label:/dir$ ") on a
--                         computer with a label, '\w\$ ' without one,
--                         unless the environment brought one.
--   *  ?  [abc]  [!a-z]   globs; a name starting with a dot only matches
--                         an explicit dot, and the fileserver's member disks
--                         (/disk, /disk2... with /jbod mounted) only a
--                         pattern that starts with a plain character
--                         (disk*, not *).
--                         No match leaves the word as is.
--   $(cmd)  `cmd`         command substitution (in a subshell).
--   if a; then b; elif c; then d; else e; fi
--   while a; do b; done   until a; do b; done
--   for x in words; do b; done   (no `in words`: "$@")
--   case word in pat|pat) a;; (pat) b;; *) c;; esac   (globs, as in names)
--   { a; b; }             a group; ( a; b ) a subshell: its variables,
--                         functions, exit and directory are its own
--   name() { body; }      a function (function name { body; } too):
--                         $1... are its arguments; return [n]; local
--                         name[=value] until it returns
--   break [n], continue [n] out of, or on round, the n'th loop out.
--                         Any of these can be piped and redirected as a
--                         whole: for f in *; do ...; done | sort,
--                         while read l; do ...; done < file.  They span
--                         lines at the prompt.  A loop lets the rest of
--                         the computer run every 100 turns, and Ctrl+T
--                         stops it.
--   a &                   a background job: the line goes on while it
--                         runs.  It gets its own copy of the variables
--                         and every event but the keyboard's and the
--                         mouse's.  At the prompt, Ctrl+Z stops the job
--                         in front (a stopped job keeps the events it
--                         misses for later).  Under init, see below.
--   jobs [-l|-p]          the jobs: [1]+ Running  sleep 10 &
--   fg [%n]  bg [%n]      a job to the front (waiting for it), or a
--                         stopped one carried on in the background.  %n
--                         is job n; %% or %+ the latest, %- the one
--                         before, %str the one whose line starts so.
--   fg prog  bg prog      as CraftOS's fg and bg: prog in a new multishell
--                         tab (shown, for fg), with the environment.
--   wait [%n|pid...]      wait for jobs (all, with none named); their
--                         status.  Ctrl+T stops waiting.
--   kill [-9] %n|pid...   end a job as Ctrl+T would; -9 drops it at once,
--                         -STOP stops it, -CONT carries it on.  Under
--                         init, a pid that isn't a job's is a process's
--                         (see ps), and -pid a process group's.
--   builtins              also exit [n], :, true, false, read [-r] name...,
--                         shift [n], unset [-v] name... (variables),
--                         unset -f name... (functions), . file,
--                         export [-n] name[=value]... and export -p,
--                         [ expression ] (test, with a last ])
--
-- Not yet: here-documents, $(( arithmetic )) (expr does sums), ~.
--
-- At the prompt, ccsh first runs the commands in /.profile (PS1,
-- export...), as `. /.profile` would.  Tab completes a program's name,
-- and an argument as the stock shell would, or else as a file or
-- directory name: what it would add shows in grey after the cursor.  The
-- up and down keys go through
-- the lines typed before, kept in $HISTFILE (/.ccsh_history; unset or
-- empty, none) across sessions and tabs, the last $HISTSIZE of them
-- (1000; 0 keeps none).  Both are shell variables, set before /.profile
-- runs so it can change them.  The line is edited with a Unix shell's
-- keys (lib/readline; the read builtin's too, at the keyboard):
--
--   Ctrl+A, Ctrl+E, Home, End      the start / the end of the line
--   Ctrl+B, Ctrl+F, Left, Right    a character back / forward
--   Alt+B, Alt+F                   a word back / forward (or Esc then b/f)
--   Backspace, Delete, Ctrl+D      a character out (before / under it)
--   Ctrl+K, Ctrl+U                 cut to the end / to the start
--   Ctrl+W, Alt+Backspace, Alt+D   cut the word before / before / after
--   Ctrl+Y                         put back what was cut last
--   Up, Down, Ctrl+P, Ctrl+N       the history (Up and Down go through
--                                  the completions while one shows)
--   Ctrl+R                         search back through the history as
--                                  you type: Ctrl+R again for an older
--                                  match, Enter runs it, Ctrl+G gives up,
--                                  another key edits it
--   Tab                            the completion shown
--   Ctrl+L                         clear the screen
--   Ctrl+C                         drop the line (status 130)
--   Ctrl+D on an empty line        leave, as exit does
--
-- A long line scrolls sideways.  What a background job prints while a
-- line is being typed goes where the prompt was, and the prompt and the
-- line (and the cursor's place in it) come back below it, as in zsh.
-- Tap Ctrl+R: held, CraftOS reboots (and
-- Ctrl+S held shuts down).  Leave with exit, Ctrl+D, or by holding
-- Ctrl+T at the prompt; with jobs left, the first try only warns, and the
-- jobs end with the shell.  Ctrl+C or Ctrl+T while a command runs stops
-- it, and the rest of the line, with status 130.  Programs that use Ctrl+C
-- as a key get it as a key instead: CraftOS's edit (so nano), paint, lua,
-- shell, multishell and games, which Ctrl+T still stops, and ccnix's vi,
-- vim and telnet (and, under init, any program that ignores INT).  A
-- script or -c waits for its background jobs before it ends: they can't
-- outlive it.
--
-- Under init (`help init`), a program from the path runs as a process of
-- its own, as Unix's shells fork one: a child of this shell's, which ps
-- lists and kill and Ctrl+T reach.  At the prompt each job is a process
-- group (its number is $! and what jobs -l shows), put in front of the
-- terminal while it's the job in front, so the keyboard goes to it, and
-- Ctrl+Z stops the whole group, and the job; Ctrl+C sends the group INT,
-- which ends it as Ctrl+T would, but for a program that ignores INT
-- (proc.ignore: vi, telnet), which gets the key.  Builtins, functions and
-- compound commands run in the shell itself (cd and X=1 have to).  A
-- script or -c runs its programs in its own group, so Ctrl+T reaches it
-- and them alike.
--
-- A script can start with #!/ccnix/bin/ccsh (the stock shell honours the
-- #! line; under the ROM alone it's #!/rom/ccnix/bin/ccsh), or run as
-- `ccsh script`.
--
-- Programs see a pipe or a file as io.input() and io.output().  print,
-- write, term.write and printError are redirected too, so stock programs
-- can be piped: `ls | grep lua`.  ls lays its names out in columns as it
-- would on screen, so `ls | wc -l` counts rows, not files.  Full-screen
-- programs (edit, paint) need the screen: don't pipe them.  While a
-- command runs, _G.POSIX_SH is set (echo leaves > to the shell then).

local args = { ... }

-- What a command gets when nothing is redirected: this shell's own.
local real = {
    term = term.current(), input = io.input(), output = io.output(), stderr = io.stderr,
    write = _G.write, printError = _G.printError, read = _G.read,
}
local kb = io.stdin._handle          -- the keyboard: its readLine is read()
real.kb = kb.readLine
local ioMeta = getmetatable(io.stdout)
local function handle(h) return setmetatable({ _handle = h }, ioMeta) end

local TTY = {}                       -- an fd that is left as it is

-- The shell's state.  A background job runs in its own copy of it, as a
-- subshell would: its $?, variables and exports are its own.
local P = {
    vars = {},                       -- the variables
    exported = {},                   -- the names in programs' environment
    pos = {}, arg0 = "ccsh",      -- $1..., $0
    status = 0,                      -- $?
    subStatus = nil,                 -- the last $(...)'s status
    exiting = false,                 -- exit ran
    interrupted = false,             -- Ctrl+T stopped a command: skip the rest
    aborting = nil,                  -- at the prompt, a ${X:?} failed: skip the rest
    defaultOut = nil,                -- where commands write, inside $(...) or a redirected { }
    defaultIn = nil,                 -- what they read ({ handle }), in a piped or redirected compound
    defaultErr = nil,                -- where their errors go
    lastBg = nil,                    -- $!
    funcs = {},                      -- name -> the function's body
    loopDepth = 0, funcDepth = 0, dotDepth = 0,
    locals = nil,                    -- in a function: what `local` hid, name -> { value, exported }
    -- breaking, continuing (how many loops), returning: stop what's running
}
local mainP = P

local function copy(t)
    local c = {}
    for k, v in pairs(t) do c[k] = v end
    return c
end

local function cloneState(s)
    local c = copy(s)
    c.vars, c.exported, c.pos, c.funcs = copy(s.vars), copy(s.exported), copy(s.pos), copy(s.funcs)
    return c
end

-- What os.environ was when ccsh started: CraftOS has none, but a ccsh
-- that runs another gives it its own.  A command's os.getenv, setenv and
-- environ are put in only while it runs, like its io.
local sys = { environ = rawget(os, "environ") }
-- An environment taken over (from a ccsh that ran this one, or for
-- fg/bg prog) as exported variables; PATH, PWD and HOSTNAME are worked
-- out afresh.
local function importEnv(env)
    for k, v in pairs(env) do
        if k ~= "PATH" and k ~= "PWD" and k ~= "HOSTNAME" then P.vars[k], P.exported[k] = v, true end
    end
end
if sys.environ then importEnv(sys.environ()) end

-- PS1, exported: unless it came with the environment, "label:/dir$ "
-- on a computer with a label, "/dir$ " on one without.
if P.vars.PS1 == nil then
    P.vars.PS1 = (os.getComputerLabel and os.getComputerLabel()) and "\\h:\\w\\$ " or "\\w\\$ "
end
P.exported.PS1 = true

-- The functions a program gets over its environment `env`.
local function envApi(env)
    return {
        getenv = function(name)
            if type(name) ~= "string" then error("bad argument #1 (string expected, got " .. type(name) .. ")", 2) end
            return env[name]
        end,
        setenv = function(name, value)
            if type(name) ~= "string" or not name:match("^[^=]+$") then error("bad argument #1 (a name expected)", 2) end
            env[name] = value ~= nil and tostring(value) or nil
        end,
        environ = function() return copy(env) end,
    }
end

local function join(...)
    local t = table.pack(...)
    for i = 1, t.n do t[i] = tostring(t[i]) end
    return table.concat(t, "\t", 1, t.n)
end

-- fn(...) drawing on the real screen, from a command whose output is
-- captured (reading the keyboard, an error message).
local function withReal(fn, ...)
    local t, w = term.redirect(real.term), _G.write
    _G.write = real.write
    local r = table.pack(pcall(fn, ...))
    _G.write = w
    term.redirect(t)
    if not r[1] then error(r[2], 0) end
    return table.unpack(r, 2, r.n)
end

--------------------------------------------------------------------------
-- Streams: where a command's output goes when it isn't the screen
--------------------------------------------------------------------------
-- A stream over out(text): S.raw(s) writes s (write and io.write end up
-- here), S.handle is it as an io handle, S.term a terminal that turns
-- cursor moves into text: what's drawn on a line goes out when the line
-- ends, moving down a row is a newline, and nothing wraps.
local function stream(out, onClose)
    local S = {}
    local cur, base, x, y = "", 0, 1, 1  -- cur: drawn, not yet out, from column base + 1
    local function flush()
        if cur ~= "" then out(cur); base = base + #cur; cur = "" end
    end
    function S.raw(s)
        s = tostring(s)
        flush()
        out(s)
        local _, nl = s:gsub("\n", "")
        if nl > 0 then y = y + nl; base = #s:match("[^\n]*$") else base = base + #s end
        x = base + 1
        return nl
    end
    S.flush = flush
    S.handle = handle({ write = S.raw, flush = flush })
    function S.close() flush(); if onClose then onClose() end end

    local w = real.term.getSize()
    local fg, bg, blink = colours.white, colours.black, false
    local t = {}
    function t.write(s)
        s = tostring(s)
        local at = x - 1 - base
        x = x + #s
        if at < 0 then s, at = s:sub(1 - at), 0 end     -- over what's already out: lost
        if #cur < at then cur = cur .. (" "):rep(at - #cur) end
        cur = cur:sub(1, at) .. s .. cur:sub(at + #s + 1)
    end
    function t.blit(s) t.write(s) end
    function t.setCursorPos(nx, ny)
        nx, ny = math.floor(nx), math.floor(ny)
        if ny > y then flush(); out(("\n"):rep(ny - y)); y, base = ny, 0 end
        x = nx
    end
    function t.getCursorPos() return x, y end
    function t.getSize() return w, 10000 end     -- tall, so paged output never stops to ask
    function t.scroll(n) if n > 0 then flush(); out(("\n"):rep(n)); base = 0 end end
    function t.clear() end
    function t.clearLine() cur = "" end
    function t.setCursorBlink(b) blink = b end
    function t.getCursorBlink() return blink end
    function t.isColour() return real.term.isColour() end
    function t.setTextColour(c) fg = c end
    function t.getTextColour() return fg end
    function t.setBackgroundColour(c) bg = c end
    function t.getBackgroundColour() return bg end
    t.isColor, t.setTextColor, t.getTextColor = t.isColour, t.setTextColour, t.getTextColour
    t.setBackgroundColor, t.getBackgroundColor = t.setBackgroundColour, t.getBackgroundColour
    for k, v in pairs(term.native()) do
        if type(v) == "function" and t[k] == nil then
            t[k] = (k:match("^get") or k:match("^is")) and function(...) return real.term[k](...) end
                or function() end
        end
    end
    S.term = t
    return S
end

-- A stream collected in memory; S.text() is everything written.
local function buffer()
    local parts = {}
    local S = stream(function(s) parts[#parts + 1] = s end)
    function S.text() S.flush(); return table.concat(parts) end
    return S
end

-- An io handle reading the string `data`.
local function reader(data)
    local p = 1
    return handle({
        readLine = function(keep)
            if p > #data then return nil end
            local e = data:find("\n", p, true) or #data
            local l = data:sub(p, (keep or data:sub(e, e) ~= "\n") and e or e - 1)
            p = e + 1
            return l
        end,
        readAll = function() local s = data:sub(p); p = #data + 1; return s end,
        read = function(n)
            if p > #data then return nil end
            local s = data:sub(p, p + (n or 1) - 1)
            p = p + #s
            return s
        end,
        close = function() end,
    })
end

local function readFile(name)
    local path = shell.resolve(name)
    if not fs.exists(path) or fs.isDir(path) then return nil end
    local f = fs.open(path, "rb")
    if not f then return nil end
    local s = f.readAll() or ""
    f.close()
    return s
end

--------------------------------------------------------------------------
-- Parsing
--------------------------------------------------------------------------
-- A word is a list of parts: { t = "lit", s, q } (q: quoted; split: text
-- of a ${X:-word} to split), { t = "var", name, op, word, q } (op and word:
-- ${name<op>word}) or { t = "cmd", src, q }.  A syntax error is raised as
-- { msg, more }; more means the line could still be finished.
local function bad(msg, more) error({ msg = msg, more = more }, 0) end

-- The ")" that closes the "(" just before position i.
local function closer(src, i)
    local depth = 1
    while i <= #src do
        local c = src:sub(i, i)
        if c == "\\" then i = i + 1
        elseif c == "'" then i = src:find("'", i + 1, true) or bad("unterminated '", true)
        elseif c == '"' then
            i = i + 1
            while src:sub(i, i) ~= '"' do
                if i > #src then bad('unterminated "', true) end
                if src:sub(i, i) == "\\" then i = i + 1 end
                i = i + 1
            end
        elseif c == "(" then depth = depth + 1
        elseif c == ")" then
            depth = depth - 1
            if depth == 0 then return i end
        end
        i = i + 1
    end
    bad("unterminated $(", true)
end

local OPS3 = { ["&>>"] = true }
local OPS2 = { ["&&"] = true, ["||"] = true, [">>"] = true, [">&"] = true, ["<&"] = true, [">|"] = true, [";;"] = true,
    ["&>"] = true }
local OPS1 = { ["|"] = true, [";"] = true, ["&"] = true, ["<"] = true, [">"] = true, ["("] = true, [")"] = true }

-- What a character c (one, or "" past the end) is.
local function isDigit(c) return c ~= "" and c >= "0" and c <= "9" end
local function isLetter(c) return c ~= "" and ((c >= "a" and c <= "z") or (c >= "A" and c <= "Z")) end
local function isNameStart(c) return c == "_" or isLetter(c) end
local function isNameChar(c) return isNameStart(c) or isDigit(c) end
-- $? $# $@ $* $$ $!: the one-character special parameters
local SPECIAL_PARAMS = { ["?"] = true, ["#"] = true, ["@"] = true, ["*"] = true, ["$"] = true, ["!"] = true }
-- the operators of ${name<op>word}: with a colon, an empty value counts
-- as unset too
local PARAM_OPS = { ["-"] = true, ["="] = true, ["+"] = true, ["?"] = true }

-- Tokens: { parts = word } or { op = "|", fd = n (2>), nl = true (a newline) }.
local function lex(src)
    local toks, parts, start = {}, nil, nil
    local i, n = 1, #src
    local function part(p)
        if not parts then parts, start = {}, i end
        local last = parts[#parts]
        if p.t == "lit" and last and last.t == "lit" and last.q == p.q and last.split == p.split then last.s = last.s .. p.s
        else parts[#parts + 1] = p end
    end
    -- split: unquoted text in a ${name:-word}, split at blanks as an
    -- expansion is
    local function lit(s, q, split) part({ t = "lit", s = s, q = q, split = split }) end
    local function finish()
        if parts then toks[#toks + 1] = { parts = parts, s = start, e = i - 1 }; parts = nil end
    end
    local doubleQuoted, braceWord

    -- A parameter's name at j: a name (a letter or _, then letters,
    -- digits and _), a positional number (one digit, or with braces all
    -- the digits: ${10}) or one of ? # @ * $ !.  The name and the
    -- position after it, or nil.
    local function readParamName(j, braced)
        local c = src:sub(j, j)
        local e = j
        if isNameStart(c) then
            while isNameChar(src:sub(e + 1, e + 1)) do e = e + 1 end
        elseif isDigit(c) then
            while braced and isDigit(src:sub(e + 1, e + 1)) do e = e + 1 end
        elseif not SPECIAL_PARAMS[c] then
            return nil
        end
        return src:sub(j, e), e + 1
    end
    -- An operator of ${name<op>word} at j: an optional ":", then one of
    -- - = + ?.  The operator and the position after it, or nil.
    local function readParamOp(j)
        local colon = src:sub(j, j) == ":"
        local k = colon and j + 1 or j
        local c = src:sub(k, k)
        if not PARAM_OPS[c] then return nil end
        return (colon and ":" or "") .. c, k + 1
    end

    -- the $ at i; returns where it ends
    local function dollar(q)
        local c = src:sub(i + 1, i + 1)
        if c == "(" then
            if src:sub(i + 2, i + 2) == "(" then bad("$(( )) arithmetic isn't supported") end
            local e = closer(src, i + 2)
            part({ t = "cmd", src = src:sub(i + 2, e - 1), q = q })
            return e + 1
        elseif c == "{" then
            -- ${name}, or ${name<op>word}: its word is read here, as a
            -- word of its own, and expanded only if it's used
            if not parts then parts, start = {}, i end      -- (the word this ${ is in starts here)
            local at = i
            local function bracedText() return src:sub(at, src:find("}", at, true) or n) end
            local name, j = readParamName(i + 2, true)
            if not name then
                if i + 2 > n then bad("unterminated ${", true) end
                bad("bad substitution " .. bracedText())
            end
            local p = { t = "var", name = name, q = q }
            if src:sub(j, j) == "}" then
                i = j + 1
            else
                if j > n then bad("unterminated ${", true) end
                local op, k = readParamOp(j)
                if not op then bad("bad substitution " .. bracedText()) end
                p.op = op
                i = k
                p.word = braceWord(q)
            end
            part(p)
            return i
        end
        local name, e = readParamName(i + 1, false)
        if not name then lit("$", q); return i + 1 end
        part({ t = "var", name = name, q = q })
        return e
    end
    local function backtick(q)
        local e = i + 1
        while src:sub(e, e) ~= "`" do
            if e > n then bad("unterminated `", true) end
            if src:sub(e, e) == "\\" then e = e + 1 end
            e = e + 1
        end
        part({ t = "cmd", src = (src:sub(i + 1, e - 1):gsub("\\([`\\$])", "%1")), q = q })
        return e + 1
    end
    -- the "..." whose opening quote is at i; returns where it ends
    function doubleQuoted()
        lit("", true)                                   -- "" is still a word
        i = i + 1
        while true do
            local d = src:sub(i, i)
            if d == "" then bad('unterminated "', true)
            elseif d == '"' then return i + 1
            elseif d == "\\" and src:sub(i + 1, i + 1):match('[%$`"\\\n]') then
                if src:sub(i + 1, i + 1) ~= "\n" then lit(src:sub(i + 1, i + 1), true) end
                i = i + 2
            elseif d == "$" then i = dollar(true)
            elseif d == "`" then i = backtick(true)
            else lit(d, true); i = i + 1 end
        end
    end
    -- The word of ${name<op>word}, from i to the } that closes the ${ (i
    -- is left after it), as a list of parts.  It reads as a word does
    -- (\x, '...', "...", $, `), but blanks and operators are part of it;
    -- inside "..." (q) all of it is quoted, and a ' is just text.  A {
    -- in it needs its own } first.
    function braceWord(q)
        local outer = parts
        parts = {}
        local depth = 0
        while true do
            local c = src:sub(i, i)
            if c == "" then bad("unterminated ${", true)
            elseif c == "}" and depth == 0 then i = i + 1; break
            elseif c == "\\" then
                local d = src:sub(i + 1, i + 1)
                if d == "" then bad("unterminated ${", true) end
                if q and not (d == "$" or d == "`" or d == '"' or d == "\\" or d == "}" or d == "\n") then
                    lit("\\", true)                     -- (in "...", other \s stay)
                    i = i + 1
                else
                    if d ~= "\n" then lit(d, true) end
                    i = i + 2
                end
            elseif c == "'" and not q then
                local e = src:find("'", i + 1, true) or bad("unterminated '", true)
                lit(src:sub(i + 1, e - 1), true)
                i = e + 1
            elseif c == '"' then
                if q then i = i + 1 else i = doubleQuoted() end   -- (in "...", "" quotes nothing more)
            elseif c == "$" then i = dollar(q)
            elseif c == "`" then i = backtick(q)
            else
                if c == "{" then depth = depth + 1 elseif c == "}" then depth = depth - 1 end
                lit(c, q, not q or nil)
                i = i + 1
            end
        end
        local word = parts
        parts = outer
        return word
    end

    while i <= n do
        local c = src:sub(i, i)
        if c == " " or c == "\t" then finish(); i = i + 1
        elseif c == "\n" then finish(); toks[#toks + 1] = { op = ";", nl = true, s = i, e = i }; i = i + 1
        elseif c == "#" and not parts then i = src:find("\n", i, true) or n + 1
        elseif c == "\\" then
            if i == n then bad("", true) end            -- the line goes on
            if src:sub(i + 1, i + 1) ~= "\n" then lit(src:sub(i + 1, i + 1), true) end
            i = i + 2
        elseif c == "'" then
            local e = src:find("'", i + 1, true) or bad("unterminated '", true)
            lit(src:sub(i + 1, e - 1), true)
            i = e + 1
        elseif c == '"' then i = doubleQuoted()
        elseif c == "$" then i = dollar(false)
        elseif c == "`" then i = backtick(false)
        else
            -- the longest operator here: &>> before &> before &
            local op = OPS3[src:sub(i, i + 2)] and src:sub(i, i + 2)
                or OPS2[src:sub(i, i + 1)] and src:sub(i, i + 1) or OPS1[c] and c
            if op then
                local fd
                if op:find("^[<>]") and parts and #parts == 1 and parts[1].t == "lit" and not parts[1].q
                    and parts[1].s:match("^%d$") then
                    fd, parts = tonumber(parts[1].s), nil
                end
                finish()
                toks[#toks + 1] = { op = op, fd = fd, s = i, e = i + #op - 1 }
                i = i + #op
            else
                lit(c, false)
                i = i + 1
            end
        end
    end
    finish()
    return toks
end

local REDIR = { ["<"] = true, [">"] = true, [">>"] = true, [">|"] = true, [">&"] = true, ["<&"] = true,
    ["&>"] = true, ["&>>"] = true }

-- A list is and-or lists: { { pipe = p }, { conn = "&&", pipe = p }, ...,
-- bg = true (it ended in &), text = its source }.  A pipeline is { neg,
-- cmds }; a command is one of
--   { kind = "simple", words, assigns, redirs }
--   { kind = "group", body, redirs }               { list; }
--   { kind = "subshell", body, redirs }            ( list )
--   { kind = "if", clauses = { { cond, body }... }, otherwise, redirs }
--   { kind = "while", cond, body, ["until"] = true, redirs }
--   { kind = "for", name, items (nil: "$@"), body, redirs }
--   { kind = "case", subject, items = { { patterns, body }... }, redirs }
--   { kind = "func", name, body }                  name() compound
-- Reserved words count only unquoted, where a command starts.
local ENDS = { ["then"] = true, ["else"] = true, ["elif"] = true, ["fi"] = true, ["do"] = true, ["done"] = true,
    ["esac"] = true, ["}"] = true, ["in"] = false }
local function parse(src)
    local toks = lex(src)
    local i = 1
    local list, command
    local function op(...)
        local t = toks[i]
        if t and t.op then
            for _, o in ipairs({ ... }) do if t.op == o then return o end end
        end
    end
    -- the plain word token t is (one unquoted literal), or nil
    local function plain(t)
        if t and t.parts and #t.parts == 1 and t.parts[1].t == "lit" and not t.parts[1].q then return t.parts[1].s end
    end
    local function is(w) return plain(toks[i]) == w end
    local function newlines() while toks[i] and toks[i].nl do i = i + 1 end end
    local function unexpected()
        local t = toks[i]
        if not t then bad("unexpected end of line", true) end
        bad("unexpected " .. (t.nl and "newline" or t.op or plain(t) or "word"))
    end
    local function expect(w)
        if is(w) then i = i + 1; return end
        if not toks[i] then bad("unexpected end of line (" .. w .. " missing)", true) end
        unexpected()
    end
    local function redirect(cmd)
        local t = toks[i]
        local target = toks[i + 1]
        if not target then bad("missing file name after " .. t.op) end
        if not target.parts then i = i + 1; unexpected() end
        cmd.redirs[#cmd.redirs + 1] = { fd = t.fd or (t.op:sub(1, 1) == "<" and 0 or 1), op = t.op, target = target.parts }
        i = i + 2
    end
    local function redirects(cmd)
        while toks[i] and REDIR[toks[i].op] do redirect(cmd) end
        return cmd
    end
    local function simple()
        local cmd = { kind = "simple", words = {}, assigns = {}, redirs = {} }
        if ENDS[plain(toks[i])] then unexpected() end
        while toks[i] do
            local t = toks[i]
            if t.parts then
                local p1, name, rest = t.parts[1], nil, nil
                if #cmd.words == 0 and p1.t == "lit" and not p1.q then name, rest = p1.s:match("^([%a_][%w_]*)=(.*)$") end
                if name then
                    local value = { { t = "lit", s = rest, q = false } }
                    for k = 2, #t.parts do value[#value + 1] = t.parts[k] end
                    cmd.assigns[#cmd.assigns + 1] = { name = name, value = value }
                else
                    cmd.words[#cmd.words + 1] = t.parts
                end
                i = i + 1
            elseif REDIR[t.op] then
                redirect(cmd)
            else
                break
            end
        end
        if #cmd.words + #cmd.assigns + #cmd.redirs == 0 then unexpected() end
        return cmd
    end
    local function name(what)
        local n = plain(toks[i])
        if not n or not n:match("^[%a_][%w_]*$") then
            if not toks[i] then bad("unexpected end of line", true) end
            bad(what .. ": bad name " .. (n or "here"))
        end
        i = i + 1
        return n
    end
    function command()
        local t = toks[i]
        local w = plain(t)
        if t and t.op == "(" then
            i = i + 1
            local body = list({ [")"] = true })
            if not op(")") then if not toks[i] then bad("unexpected end of line () missing)", true) end; unexpected() end
            i = i + 1
            return redirects({ kind = "subshell", body = body, redirs = {} })
        elseif w == "{" then
            i = i + 1
            local body = list({ ["}"] = true })
            expect("}")
            return redirects({ kind = "group", body = body, redirs = {} })
        elseif w == "if" then
            i = i + 1
            local cmd = { kind = "if", clauses = {}, redirs = {} }
            while true do
                local cond = list({ ["then"] = true })
                expect("then")
                cmd.clauses[#cmd.clauses + 1] = { cond = cond, body = list({ ["elif"] = true, ["else"] = true, ["fi"] = true }) }
                if is("elif") then i = i + 1
                else
                    if is("else") then i = i + 1; cmd.otherwise = list({ ["fi"] = true }) end
                    expect("fi")
                    return redirects(cmd)
                end
            end
        elseif w == "while" or w == "until" then
            i = i + 1
            local cond = list({ ["do"] = true })
            expect("do")
            local body = list({ ["done"] = true })
            expect("done")
            return redirects({ kind = "while", ["until"] = w == "until", cond = cond, body = body, redirs = {} })
        elseif w == "for" then
            i = i + 1
            local cmd = { kind = "for", name = name("for"), redirs = {} }
            newlines()
            if is("in") then
                i = i + 1
                cmd.items = {}
                while toks[i] and toks[i].parts do cmd.items[#cmd.items + 1] = toks[i].parts; i = i + 1 end
                if op(";") then i = i + 1 elseif toks[i] then unexpected() end
            elseif op(";") then
                i = i + 1
            end
            newlines()
            expect("do")
            cmd.body = list({ ["done"] = true })
            expect("done")
            return redirects(cmd)
        elseif w == "case" then
            i = i + 1
            local subject = toks[i]
            if not (subject and subject.parts) then unexpected() end
            i = i + 1
            local cmd = { kind = "case", subject = subject.parts, items = {}, redirs = {} }
            newlines()
            expect("in")
            newlines()
            while not is("esac") do
                if not toks[i] then bad("unexpected end of line (esac missing)", true) end
                if op("(") then i = i + 1 end
                local pats = {}
                while true do
                    local p = toks[i]
                    if not (p and p.parts) then unexpected() end
                    pats[#pats + 1] = p.parts
                    i = i + 1
                    if op("|") then i = i + 1
                    elseif op(")") then i = i + 1; break
                    else unexpected() end
                end
                cmd.items[#cmd.items + 1] = { patterns = pats, body = list({ [";;"] = true, esac = true }) }
                if op(";;") then i = i + 1; newlines()
                elseif not is("esac") then unexpected() end
            end
            i = i + 1
            return redirects(cmd)
        elseif w == "function" or (w and w:match("^[%a_][%w_]*$") and toks[i + 1] and toks[i + 1].op == "("
                and toks[i + 2] and toks[i + 2].op == ")") then
            if w == "function" then i = i + 1 end
            local n = name("function")
            if op("(") then
                i = i + 1
                if not op(")") then unexpected() end
                i = i + 1
            end
            newlines()
            if not toks[i] then bad("unexpected end of line", true) end
            local body = command()
            if body.kind == "simple" or body.kind == "func" then bad("a function's body is { ... } or another compound command") end
            return { kind = "func", name = n, body = body }
        end
        return simple()
    end
    local function pipeline()
        local p = { cmds = {} }
        if is("!") then p.neg = true; i = i + 1 end
        while true do
            p.cmds[#p.cmds + 1] = command()
            if not op("|") then break end
            i = i + 1
            newlines()
        end
        return p
    end
    -- and-or lists until one of ends (reserved words, or ")" ";;") or
    -- the end
    function list(ends)
        ends = ends or {}
        local out = {}
        local function atEnd()
            local t = toks[i]
            if not t then return true end
            if t.op then return ends[t.op] == true end
            local w = plain(t)
            return w ~= nil and ends[w] == true
        end
        while true do
            while op(";") do i = i + 1 end
            if atEnd() then return out end
            local first = toks[i]
            local ao = { { pipe = pipeline() } }
            while op("&&", "||") do
                local o = op("&&", "||")
                i = i + 1
                newlines()
                ao[#ao + 1] = { conn = o, pipe = pipeline() }
            end
            ao.text = src:sub(first.s, toks[i - 1].e)
            out[#out + 1] = ao
            if op("&") then ao.bg = true; i = i + 1
            elseif op(";") then i = i + 1
            elseif not atEnd() then unexpected() end
        end
    end
    local top = list()
    if toks[i] then unexpected() end
    return top
end

--------------------------------------------------------------------------
-- Expansion
--------------------------------------------------------------------------
local runSource

-- $$ and $PPID: under init (a process table), this shell's own process
-- ID and its parent's, taken as it starts, so a subshell or a job says
-- the shell's too; without one, $$ is the computer's ID and PPID unset.
local ids = {}
do
    local kp = rawget(_G, "proc")
    if kp and kp.self then
        ids.pid = kp.self()
        for _, p in ipairs(kp.list and kp.list() or {}) do
            if p.pid == ids.pid then ids.ppid = p.ppid end
        end
    end
end

local function getVar(name)
    if name == "?" then return tostring(P.status)
    elseif name == "#" then return tostring(#P.pos)
    elseif name == "$" then return tostring(ids.pid or os.getComputerID())
    elseif name == "0" then return P.arg0
    elseif isDigit(name:sub(1, 1)) then return P.pos[tonumber(name)] or ""
    elseif name == "@" or name == "*" then return P.pos, true
    elseif name == "PATH" then return shell.path()
    elseif name == "PWD" then return "/" .. shell.dir()
    elseif name == "HOSTNAME" then
        return os.getComputerLabel and os.getComputerLabel() or tostring(os.getComputerID())
    elseif name == "PPID" then return ids.ppid and tostring(ids.ppid) or ""
    elseif name == "!" then return P.lastBg and tostring(P.lastBg) or ""
    end
    return P.vars[name] or ""
end

-- Whether parameter name is set (for ${name-word} and the like): an
-- empty variable is set, one never given a value (or unset) isn't.
local function isSet(name)
    if name == "@" or name == "*" then return #P.pos > 0
    elseif name == "!" then return P.lastBg ~= nil
    elseif name == "PPID" then return ids.ppid ~= nil
    elseif name ~= "0" and isDigit(name:sub(1, 1)) then return tonumber(name) <= #P.pos
    elseif SPECIAL_PARAMS[name] or name == "0" or name == "PATH" or name == "PWD" or name == "HOSTNAME" then
        return true
    end
    return P.vars[name] ~= nil
end

local function setVar(name, v)
    if name == "PATH" then shell.setPath(v)
    elseif name ~= "PWD" and name ~= "PPID" then P.vars[name] = v end
end

-- The environment a command gets: the exported variables (PS1 among
-- them), PATH, PWD and HOSTNAME, and the command's own NAME=value words.
local function processEnv(assigns)
    local env = {}
    for name in pairs(P.exported) do
        local v = name == "HOSTNAME" and getVar(name) or P.vars[name]
        if v ~= nil then env[name] = v end
    end
    env.PATH, env.PWD, env.HOSTNAME = shell.path(), "/" .. shell.dir(), getVar("HOSTNAME")
    for _, a in ipairs(assigns or {}) do env[a.name] = a.value end
    return env
end

local subshell                      -- (below, with the jobs)

-- What $(src) writes, trailing newlines dropped.  It runs in a subshell.
local function substitute(src)
    local buf = buffer()
    P.subStatus = subshell(function()
        P.defaultOut = buf
        runSource(src)
    end)
    return (buf.text():gsub("\n+$", ""))
end

-- A message for fd 2 (a stream, or the screen).
local function report(fd2, s)
    if fd2 ~= TTY and fd2.raw then fd2.raw(s .. "\n") else printError(s) end
end

-- Raised when a ${name:?word} finds name unset (it said so); the command
-- doesn't run (see expansionFailed).
local EXPANSION = {}

-- The fields a word expands to, each { chars, magic }: magic marks the
-- unquoted characters, the ones a glob can use.  Unquoted expansions are
-- split at blanks; "$@" is a field per argument.  whole: one string, no
-- splitting (assignments and redirect targets); "pattern": one field, not
-- split, unquoted expansions still magic (case's patterns).
local function fields(parts, whole)
    local out, cur = {}, nil
    local function new() cur = { chars = {}, magic = {}, keep = false } end
    local function add(s, q)
        if q then cur.keep = true end
        for ch in s:gmatch(".") do
            cur.chars[#cur.chars + 1] = ch
            cur.magic[#cur.magic + 1] = not q
            cur.keep = true
        end
    end
    local function cut()
        if cur.keep then out[#out + 1] = cur end
        new()
    end
    -- v, what an expansion gave: quoted (q), all of it; else split at blanks
    local function expanded(v, q)
        if q or whole == true then
            add(v, true)
        elseif whole == "pattern" then
            add(v, false)
        else
            local k = 1
            while true do
                local a, b = v:find("[ \t\n]+", k)
                add(v:sub(k, (a or 0) - 1), false)
                if not a then break end
                cut()
                k = b + 1
            end
        end
    end
    -- ${name<op>word}: the value (and true for $@ and $*'s list), or nil
    -- and the word's parts, to expand in its place.  The word is expanded
    -- only if it's used.
    --   -  word if name is unset           :-  ... or empty
    --   =  that, and name set to it        :=  ... or empty
    --   +  word if name is set, else ""    :+  ... and not empty
    --   ?  if unset, an error: word, or "parameter null or not set"
    --                                       :?  ... or empty
    local function param(p)
        local v, list = getVar(p.name)
        if not p.op then return v, list end
        local colon = p.op:sub(1, 1) == ":"
        local kind = p.op:sub(-1)
        local empty = not isSet(p.name) or (colon and (list and #v == 0 or v == ""))
        if kind == "+" then
            if empty then return "" end
            return nil, p.word
        elseif not empty then
            return v, list
        elseif kind == "-" then
            return nil, p.word
        end
        local w = fields(p.word, true)
        local err = P.defaultErr or TTY
        if kind == "=" then
            if not isNameStart(p.name:sub(1, 1)) then
                report(err, "ccsh: $" .. p.name .. ": can't be assigned this way")
                error(EXPANSION, 0)
            end
            setVar(p.name, w)
            return w
        end
        report(err, "ccsh: " .. p.name .. ": " .. (w ~= "" and w or "parameter null or not set"))
        error(EXPANSION, 0)
    end
    local function expandParts(list)
        for _, p in ipairs(list) do
            if p.t == "lit" and p.split then
                expanded(p.s, false)
            elseif p.t == "lit" then
                add(p.s, p.q)
            elseif p.t == "cmd" then
                expanded(substitute(p.src), p.q)
            else
                local v, isList = param(p)
                if v == nil then
                    expandParts(isList)                 -- (the word of a ${name:-word})
                elseif isList and p.q and p.name == "@" and not whole then
                    for k, a in ipairs(v) do
                        add(a, true)
                        if k < #v then cut() end
                    end
                else
                    if isList then v = table.concat(v, " ") end
                    expanded(v, p.q)
                end
            end
        end
    end
    new()
    expandParts(parts)
    cut()
    if whole == "pattern" then return out[1] or { chars = {}, magic = {} } end
    if whole then return out[1] and table.concat(out[1].chars) or "" end
    return out
end

-- A Lua pattern for one path segment of a glob, or nil if it has no
-- wildcards.
local function globPattern(chars, magic)
    local pat, wild, k = { "^" }, false, 1
    while k <= #chars do
        local c = chars[k]
        if magic[k] and c == "*" then pat[#pat + 1] = ".*"; wild = true
        elseif magic[k] and c == "?" then pat[#pat + 1] = "."; wild = true
        elseif magic[k] and c == "[" then
            local j = k + 1
            local neg = chars[j] == "!" or chars[j] == "^"
            if neg then j = j + 1 end
            local e = chars[j] == "]" and j + 1 or j
            while chars[e] and chars[e] ~= "]" do e = e + 1 end
            if chars[e] then
                local cls = { neg and "[^" or "[" }
                for m = j, e - 1 do
                    local d = chars[m]
                    cls[#cls + 1] = (d == "-" and m > j and m < e - 1) and "-" or d:match("%w") and d or "%" .. d
                end
                pat[#pat + 1] = table.concat(cls) .. "]"
                wild = true
                k = e
            else
                pat[#pat + 1] = "%["
            end
        else
            pat[#pat + 1] = c:match("%w") and c or "%" .. c
        end
        k = k + 1
    end
    if not wild then return nil end
    return table.concat(pat) .. "$"
end

-- The paths a field matches as a glob, sorted; nil if it isn't one or
-- matches nothing.
local function glob(f)
    local segs, cur = {}, { chars = {}, magic = {} }
    for k, c in ipairs(f.chars) do
        if c == "/" then
            segs[#segs + 1] = cur
            cur = { chars = {}, magic = {} }
        else
            cur.chars[#cur.chars + 1] = c
            cur.magic[#cur.magic + 1] = f.magic[k]
        end
    end
    segs[#segs + 1] = cur
    local any = false
    for _, s in ipairs(segs) do
        s.name = table.concat(s.chars)
        s.pat = globPattern(s.chars, s.magic)
        any = any or s.pat ~= nil
    end
    if not any then return nil end

    local abs = f.chars[1] == "/"
    local found = { { shown = abs and "/" or "", path = abs and "" or shell.dir() } }
    for idx, s in ipairs(segs) do
        local nxt = {}
        if s.name == "" then
            if idx == #segs and idx > 1 then        -- a trailing /: directories only
                for _, e in ipairs(found) do
                    if fs.isDir(e.path) then nxt[#nxt + 1] = { shown = e.shown .. "/", path = e.path } end
                end
            else
                nxt = found
            end
        else
            for _, e in ipairs(found) do
                local sep = (e.shown == "" or e.shown:sub(-1) == "/") and "" or "/"
                if s.pat then
                    if fs.isDir(e.path) then
                        -- the fileserver's pool: its disks' mounts are hidden too, unless
                        -- the pattern starts with a plain character
                        local pool = fs.jbodPool
                        if pool and not pool.isMember then pool = nil end   -- (an older jbod.lua's)
                        local wildFirst = s.magic[1] and (s.chars[1] == "*" or s.chars[1] == "?" or s.chars[1] == "[")
                        for _, n in ipairs(fs.list(e.path)) do
                            if n:match(s.pat) and (n:sub(1, 1) ~= "." or s.name:sub(1, 1) == ".")
                                    and not (pool and wildFirst and pool.isMember(fs.combine(e.path, n))) then
                                nxt[#nxt + 1] = { shown = e.shown .. sep .. n, path = fs.combine(e.path, n) }
                            end
                        end
                    end
                else
                    local p = fs.combine(e.path, s.name)
                    if fs.exists(p) then nxt[#nxt + 1] = { shown = e.shown .. sep .. s.name, path = p } end
                end
            end
        end
        found = nxt
    end
    if #found == 0 then return nil end
    local out = {}
    for k, e in ipairs(found) do out[k] = e.shown end
    table.sort(out)
    return out
end

--------------------------------------------------------------------------
-- Running
--------------------------------------------------------------------------
-- Install a command's terminal, io and printing functions; what they
-- were is returned for leave.
local function enter(ctx)
    local o = {
        term = term.redirect(ctx.term), input = io.input(), output = io.output(), stderr = io.stderr,
        write = _G.write, printError = _G.printError, read = _G.read, kb = kb.readLine, sh = _G.POSIX_SH,
        getenv = rawget(os, "getenv"), setenv = rawget(os, "setenv"), environ = rawget(os, "environ"),
    }
    io.input(ctx.input)
    io.output(ctx.output)
    io.stderr = ctx.stderr
    _G.write, _G.printError, _G.read, kb.readLine = ctx.write, ctx.printError, ctx.read, ctx.kb
    _G.POSIX_SH = "ccsh"
    os.getenv, os.setenv, os.environ = ctx.env.getenv, ctx.env.setenv, ctx.env.environ
    return o
end

-- Keep what the command changed for its next turn, put the shell's back.
local function leave(ctx, o)
    ctx.term, ctx.input, ctx.output, ctx.write = term.current(), io.input(), io.output(), _G.write
    term.redirect(o.term)
    io.input(o.input)
    io.output(o.output)
    io.stderr = o.stderr
    _G.write, _G.printError, _G.read, kb.readLine, _G.POSIX_SH = o.write, o.printError, o.read, o.kb, o.sh
    os.getenv, os.setenv, os.environ = o.getenv, o.setenv, o.environ
end

-- Run fn(...) as a coroutine, its context installed only while it runs
-- (other multishell tabs keep theirs), until it ends.  Returns what it
-- returned and whether Ctrl+T reached it.
local function drive(ctx, fn, ...)
    local co = coroutine.create(fn)
    local ev, terminated = table.pack(...), false
    while true do
        local o = enter(ctx)
        local r = table.pack(coroutine.resume(co, table.unpack(ev, 1, ev.n)))
        leave(ctx, o)
        if coroutine.status(co) == "dead" then
            if not r[1] then printError(tostring(r[2])); return false, terminated end
            return r[2], terminated
        end
        local filter = r[2]
        repeat ev = table.pack(os.pullEventRaw()) until filter == nil or ev[1] == filter or ev[1] == "terminate"
        if ev[1] == "terminate" then terminated = true end
    end
end

--------------------------------------------------------------------------
-- Jobs
--------------------------------------------------------------------------
-- Every command line runs as a job: a coroutine that run() below hands
-- events to, with its shell state swapped into P while it runs.  The
-- foreground job gets the keyboard, the mouse and Ctrl+T; background jobs
-- (a &) get everything else (timers, rednet, redstone...).  At the prompt,
-- Ctrl+Z stops the foreground job; a stopped job keeps the events it
-- misses (up to 256) for when fg or bg starts it again.
local jobs = {}                      -- the numbered jobs: background, stopped, or done and not yet said
local waiters = {}                   -- jobs blocked in fg or wait
local jobControl = false             -- Ctrl+Z: only at the prompt
local REQ, INTR = {}, {}             -- a builtin's yield to run(); what wakes it on Ctrl+T or kill
local nextPid, touches, ctrlDown, altDown, dropChar = 1, 0, false, false, nil
local runAndOr
-- Under init (an init with process groups), programs are processes:
local kern = rawget(_G, "proc")
local procs = kern ~= nil and kern.setForeground ~= nil
local children = {}                  -- process ID -> the job it's a command of
local myPgid                         -- this shell's own group, at the prompt
local frontTop                       -- the job run() has in front

local USER = { char = true, key = true, key_up = true, paste = true, terminate = true,
    mouse_click = true, mouse_up = true, mouse_scroll = true, mouse_drag = true }

local function newJob(fn, state, text)
    return { co = coroutine.create(fn), P = state, text = text, state = "running", queue = {}, procs = 0 }
end

-- Resume j with ...; it ends ("done", j.status), waits for an event
-- (j.filter) or blocks in fg or wait (j.req).
local currentJob                     -- the one step() is running
local function step(j, ...)
    if coroutine.status(j.co) ~= "suspended" then return end
    local saved, savedJob = P, currentJob
    P, currentJob = j.P, j
    local r = table.pack(coroutine.resume(j.co, ...))
    P, currentJob = saved, savedJob
    if coroutine.status(j.co) == "dead" then
        j.state = "done"
        if r[1] then j.value, j.status = r[2], type(r[2]) == "number" and r[2] or 0
        else printError("ccsh: " .. tostring(r[2])); j.status = 1 end
    elseif r[2] == REQ then
        j.req, j.filter, waiters[j] = r[3], nil, true
    else
        j.filter = r[2]
    end
end

local function touch(j) touches = touches + 1; j.touched = touches end

-- Run fn in a subshell: a copy of the shell's state (variables,
-- functions, $?...), and the directory and path put back after.  Its
-- status.
function subshell(fn)
    local outer, j = P, currentJob
    local sub = cloneState(P)
    sub.exiting, sub.breaking, sub.continuing, sub.returning = false, nil, nil, nil
    sub.loopDepth, sub.funcDepth, sub.dotDepth, sub.locals = 0, 0, 0, nil
    local dir, path = shell.dir(), shell.path()
    P = sub
    if j and j.P == outer then j.P = sub end
    local ok, e = pcall(fn)
    P = outer
    if j and j.P == sub then j.P = outer end
    if shell.dir() ~= dir then shell.setDir(dir) end
    if shell.path() ~= path then shell.setPath(path) end
    if sub.interrupted then outer.interrupted = true end   -- (Ctrl+T stops the whole line)
    if not ok then error(e, 0) end
    return sub.status
end

-- j's process ID: under init one of its own, so kill's numbers can't
-- clash, and its processes' group.
local function jobPid(j)
    if not j.pid then
        local proc = rawget(_G, "proc")
        if proc and proc.reservePid then j.pid = proc.reservePid() else j.pid, nextPid = nextPid, nextPid + 1 end
    end
    return j.pid
end

-- Give j a number (and a process ID, for $! and kill).
local function addJob(j)
    if j.id then return end
    local n = 0
    for _, o in ipairs(jobs) do n = math.max(n, o.id) end
    j.id = n + 1
    jobPid(j)
    jobs[#jobs + 1] = j
end

local function removeJob(j)
    for k, o in ipairs(jobs) do
        if o == j then table.remove(jobs, k); return end
    end
end

-- %+ and %-: the jobs most recently started, stopped or moved.
local function marks()
    local cur, prev
    for _, j in ipairs(jobs) do
        if not cur or j.touched > cur.touched then cur, prev = j, cur
        elseif not prev or j.touched > prev.touched then prev = j end
    end
    return cur, prev
end

-- "[1]+ Running  sleep 10 &", as jobs shows it; long: with the process ID.
local function describe(j, long)
    local cur, prev = marks()
    local st = j.state == "running" and "Running" or j.state == "stopped" and "Stopped"
        or j.killed and "Killed" or j.signalled and "Terminated"
        or j.status == 0 and "Done" or "Exit " .. tostring(j.status)
    return ("[%d]%s %s%-8s %s%s"):format(j.id, j == cur and "+" or j == prev and "-" or " ",
        long and (j.pid .. " ") or "", st, j.text, j.state == "running" and " &" or "")
end

-- %1, %%, %+, %-, %name (a job whose line starts so) or a number: a
-- process ID if pids, else a job number.
local function findJob(spec, pids)
    local cur, prev = marks()
    if spec == nil or spec == "%" or spec == "%%" or spec == "%+" then return cur end
    if spec == "%-" then return prev end
    local n = spec:match("^%%(%d+)$") or not pids and spec:match("^(%d+)$")
    for _, j in ipairs(jobs) do if n and j.id == tonumber(n) then return j end end
    n = spec:match("^(%d+)$")
    for _, j in ipairs(jobs) do if n and j.pid == tonumber(n) then return j end end
    local pre = spec:match("^%%(.+)$")
    for _, j in ipairs(jobs) do if pre and j.text:sub(1, #pre) == pre then return j end end
end

local function isJobSpec(s) return s:sub(1, 1) == "%" or s:match("^%d+$") ~= nil end

-- Signal sig to j's processes: its group, or (no job control) each one.
local function signalProcs(j, sig)
    if not procs or j.procs == 0 then return end
    if jobControl and j.pid then kern.kill(-j.pid, sig); return end
    for pid, owner in pairs(children) do
        if owner == j then kern.kill(pid, sig) end
    end
end

-- The job the keyboard is for: top, or the one it waits on with fg.
local function fgOf(j)
    while j.req and j.req.fg do j = j.req.fg end
    return j
end

local function isFront(j) return frontTop ~= nil and fgOf(frontTop) == j end

-- Put group pgid in front of the terminal, at the prompt under init.
local function toFront(pgid)
    if not (jobControl and procs and myPgid and pgid) then return end
    local fg = kern.foreground()
    if fg and fg ~= pgid then kern.setForeground(pgid) end
end

-- Ctrl+Z: stop j.  A line typed at the prompt gets its own state from
-- here on, so the shell's carries on without it.
local function stop(j)
    if j.state ~= "running" then return end
    j.state = "stopped"
    if j.P == mainP then
        j.P = cloneState(mainP)
        mainP.defaultOut, mainP.interrupted, mainP.exiting = nil, false, false
    end
    addJob(j)
    touch(j)
    print()
    print(describe(j))
end

-- fg, bg: start stopped j again (its processes too), with the events it
-- missed.
local function continue(j)
    if j.state ~= "stopped" then return end
    j.state = "running"
    signalProcs(j, "CONT")
    local missed = j.queue
    j.queue = {}
    for _, ev in ipairs(missed) do
        if j.state == "running" and not j.req and (j.filter == nil or j.filter == ev[1]) then
            step(j, table.unpack(ev, 1, ev.n))
        end
    end
end

-- Ctrl+T or kill for j: wakes a wait or fg, or stops its command.
local function signal(j)
    if j.state == "done" then return end
    j.state = "running"
    j.queue = {}
    if j.req then j.req, waiters[j] = nil, nil; step(j, INTR) else step(j, "terminate") end
end

local function deliver(j, ev)
    if j.state == "stopped" then
        if #j.queue < 256 then j.queue[#j.queue + 1] = ev end
    elseif j.state == "running" and not j.req and (j.filter == nil or j.filter == ev[1] or ev[1] == "terminate") then
        step(j, table.unpack(ev, 1, ev.n))
    end
end

local function dispatch(top, ev)
    -- a job's process stopped, carried on or ended: news for that job alone
    local owner = (ev[1] == "proc_exit" or ev[1] == "proc_stop" or ev[1] == "proc_cont") and children[ev[2]]
    if owner then
        if owner.state == "done" then
            children[ev[2]] = nil               -- (kill -9 ended the job already)
        elseif ev[1] == "proc_stop" then
            if jobControl and owner.state == "running" then
                local front = isFront(owner)
                stop(owner)
                if front then toFront(myPgid) end
            end
        else
            continue(owner)                     -- (it was carried on, or ended, while stopped: it runs)
            if ev[1] == "proc_exit" then deliver(owner, ev) end
        end
        return
    end
    if USER[ev[1]] then
        local j = fgOf(top)
        local drop = dropChar
        if ev[1] == "key" then dropChar = nil end
        if ev[1] == "char" and drop then
            dropChar = nil
            if ev[2]:lower() == drop then return end          -- (Ctrl+Z's or Ctrl+C's, if one comes)
        end
        if ev[1] == "key" or ev[1] == "key_up" then
            local down = ev[1] == "key"
            if ev[2] == keys.leftCtrl or ev[2] == keys.rightCtrl then ctrlDown = down
            elseif ev[2] == keys.leftAlt or ev[2] == keys.rightAlt then altDown = down end
            -- a command line running in front: Ctrl+Z stops it, Ctrl+C
            -- ends it as Ctrl+T does, unless it's a program that uses
            -- Ctrl+C itself (Ctrl with Alt is AltGr, typing)
            if jobControl and ctrlDown and not altDown and down and j.text then
                if ev[2] == keys.z then dropChar = "z"; stop(j); return end
                if ev[2] == keys.c and not j.keepsCtrlC then dropChar = "c"; ev = table.pack("terminate") end
            end
        end
        if ev[1] == "terminate" and j.req then signal(j) else deliver(j, ev) end
        return
    end
    deliver(top, ev)
    for _, j in ipairs(copy(jobs)) do
        if j ~= top then deliver(j, ev) end
    end
end

-- Answer the fg and wait builtins whose jobs have ended or stopped.
local function settle()
    local woke = true
    while woke do
        woke = false
        for j in pairs(waiters) do
            local q, answer = j.req, nil
            if not q then
                waiters[j] = nil
            elseif j.state == "running" then
                if q.fg then
                    if q.fg.state == "done" then answer = q.fg.status; removeJob(q.fg)
                    elseif q.fg.state == "stopped" then answer = 148 end
                else
                    answer = 0
                    for _, t in ipairs(q.wait) do
                        if t.state == "running" then answer = nil; break end
                        answer = t.state == "stopped" and 148 or t.status
                    end
                    if answer then
                        for _, t in ipairs(q.wait) do if t.state == "done" then removeJob(t) end end
                    end
                end
            end
            if answer then
                j.req, waiters[j] = nil, nil
                step(j, answer)
                woke = true
                break
            end
        end
    end
end

-- Run job `top` in the foreground until it ends or stops; the others get
-- their events meanwhile.
local function run(top)
    local outer = frontTop
    frontTop = top
    if not top.begun then top.begun = true; step(top) end
    settle()
    while top.state == "running" do
        dispatch(top, table.pack(os.pullEventRaw()))
        settle()
    end
    frontTop = outer
    return top
end

local function runTop(fn) return run(newJob(fn, P)) end

-- a &: the and-or list as a background job, in a copy of the shell's state.
local function background(ao)
    local j = newJob(function() runAndOr(ao); return P.status end, cloneState(P), ao.text)
    j.P.bg, j.P.interrupted, j.P.exiting = true, false, false
    addJob(j)
    touch(j)
    P.lastBg = j.pid
    if jobControl and P == mainP then print("[" .. j.id .. "] " .. j.pid) end
    j.begun = true
    step(j)
end

-- Tell of the jobs that have ended, before a prompt.
local function notify()
    for _, j in ipairs(copy(jobs)) do
        if j.state == "done" then print(describe(j)); removeJob(j) end
    end
end

local function liveJobs()
    local n = 0
    for _, j in ipairs(jobs) do if j.state ~= "done" then n = n + 1 end end
    return n
end

-- Ctrl+T for every job (HUP for their processes), then forget them:
-- they can't outlive the shell.
local function endJobs()
    for _, j in ipairs(copy(jobs)) do
        signalProcs(j, "HUP")
        signalProcs(j, "CONT")
        signal(j)
    end
    jobs = {}
end

-- The end of a script: its background jobs are waited for (they'd die
-- with the shell).  Ctrl+T ends them.
local function waitAll()
    local live = {}
    for _, j in ipairs(jobs) do if j.state == "running" then live[#live + 1] = j end end
    if #live == 0 then return end
    local w = runTop(function() return coroutine.yield(REQ, { wait = live }) end)
    if w.value == INTR then endJobs() end
end

-- fg prog / bg prog: as CraftOS's fg and bg, prog in a new multishell tab
-- (shown, for fg), and with the environment: a ccsh runs it there.
local SELF = "/" .. shell.getRunningProgram()
local spawned = 0
local function openTab(a, b, assigns, focus)
    if not (multishell and shell.openTab) then
        b.err(a[1] .. ": " .. a[2] .. ": no such job, and no tabs to run it in (multishell needs an advanced computer)")
        return 1
    end
    if not shell.resolveProgram(a[2]) then b.err(a[1] .. ": " .. a[2] .. ": not found"); return 127 end
    local hand = rawget(_G, "CCSH_SPAWN") or {}
    _G.CCSH_SPAWN = hand
    spawned = spawned + 1
    local token = os.getComputerID() .. "." .. os.epoch("utc") .. "." .. spawned
    hand[token] = { env = processEnv(assigns), argv = { table.unpack(a, 2) } }
    local id = shell.openTab(SELF, "--spawn", token)
    if not id then hand[token] = nil; b.err(a[1] .. ": can't open a tab"); return 1 end
    if focus then multishell.setFocus(id) end
    return 0
end

local builtins = {}
builtins[":"] = function() return 0 end
builtins["true"] = builtins[":"]
builtins["false"] = function() return 1 end
function builtins.exit(a, b)
    local n = a[2] and tonumber(a[2])
    if a[2] and not (n and n == math.floor(n)) then b.err("exit: " .. a[2] .. ": numeric argument required"); n = 2 end
    P.exiting = true
    return n or P.status
end
-- unset [-v] name...: the variables; unset -f name...: the functions
function builtins.unset(a, b)
    local k, what = 2, "v"
    while a[k] == "-v" or a[k] == "-f" do what, k = a[k]:sub(2), k + 1 end
    if a[k] == "--" then k = k + 1
    elseif a[k] and a[k]:sub(1, 1) == "-" and a[k] ~= "-" then
        b.err("unset: " .. a[k] .. ": bad option (unset [-f | -v] name...)")
        return 2
    end
    local st = 0
    for j = k, #a do
        local name = a[j]
        local ok = isNameStart(name:sub(1, 1))
        for c = 2, #name do ok = ok and isNameChar(name:sub(c, c)) end
        if not ok then
            b.err("unset: " .. name .. ": not a valid name")
            st = 1
        elseif what == "f" then
            P.funcs[name] = nil
        else
            P.vars[name], P.exported[name] = nil, nil
        end
    end
    return st
end
local function quote(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
function builtins.export(a, b)
    local k, un = 2, a[2] == "-n"
    if un then k = 3 end
    if a[k] == "-p" or not a[k] then
        local env, names = processEnv(), {}
        for name in pairs(env) do names[#names + 1] = name end
        for name in pairs(P.exported) do if env[name] == nil then names[#names + 1] = name end end
        table.sort(names)
        for _, name in ipairs(names) do
            b.out("export " .. name .. (env[name] and ("=" .. quote(env[name])) or "") .. "\n")
        end
        return 0
    end
    local st = 0
    for j = k, #a do
        local name, v = a[j]:match("^([%a_][%w_]*)=(.*)$")
        name = name or a[j]:match("^[%a_][%w_]*$")
        if not name then
            b.err("export: " .. a[j] .. ": not a valid name")
            st = 1
        else
            if v then setVar(name, v) end
            P.exported[name] = not un or nil
        end
    end
    return st
end
function builtins.jobs(a, b)
    for _, j in ipairs(copy(jobs)) do
        b.out((a[2] == "-p" and tostring(j.pid) or describe(j, a[2] == "-l")) .. "\n")
        if j.state == "done" then removeJob(j) end
    end
    return 0
end
function builtins.fg(a, b)
    if a[2] and not isJobSpec(a[2]) then return openTab(a, b, b.assigns, true) end
    if P.bg then b.err("fg: no job control in a background job"); return 1 end
    local j = findJob(a[2])
    if not j then b.err("fg: " .. (a[2] or "%+") .. ": no such job"); return 1 end
    b.out(j.text .. "\n")
    touch(j)
    if j.state == "done" then removeJob(j); return j.status end
    continue(j)
    if j.procs > 0 then toFront(j.pid) end
    local st = coroutine.yield(REQ, { fg = j })
    if st == INTR then P.interrupted = true; return 130 end
    return st
end
function builtins.bg(a, b)
    if a[2] and not isJobSpec(a[2]) then return openTab(a, b, b.assigns, false) end
    local st = 0
    for k = 2, math.max(2, #a) do
        local j = findJob(a[k])
        if not j then
            b.err("bg: " .. (a[k] or "%+") .. ": no such job")
            st = 1
        elseif j.state == "stopped" then
            touch(j)
            b.out("[" .. j.id .. "]+ " .. j.text .. " &\n")
            continue(j)
        end
    end
    return st
end
function builtins.wait(a, b)
    local targets, st = {}, 0
    if not a[2] then
        for _, j in ipairs(jobs) do if j.state == "running" then targets[#targets + 1] = j end end
    end
    for k = 2, #a do
        local j = findJob(a[k], true)
        if j then targets[#targets + 1] = j else b.err("wait: " .. a[k] .. ": no such job"); st = 127 end
    end
    if #targets == 0 then return st end
    local r = coroutine.yield(REQ, { wait = targets })
    if r == INTR then P.interrupted = true; return 130 end
    if a[2] and st == 0 then st = r end
    return st
end
local SIGNUMS = { ["1"] = "HUP", ["2"] = "INT", ["9"] = "KILL", ["15"] = "TERM", ["18"] = "CONT",
    ["19"] = "STOP", ["20"] = "TSTP" }
function builtins.kill(a, b)
    -- a job gets Ctrl+T (its processes the signal), or with KILL (9) is
    -- dropped at once, with STOP stopped, with CONT carried on; a process
    -- (init's) gets the signal itself, and init says if it's unknown
    local k, sig = 2, "TERM"
    if a[2] == "-s" then sig, k = a[3], 4
    elseif a[2] and a[2]:match("^%-.") and a[2] ~= "--" then sig, k = a[2]:sub(2), 3 end
    if a[k] == "--" then k = k + 1 end
    if not sig or not a[k] then b.err("kill: usage: kill [-s signal | -signal] %job|pid..."); return 2 end
    local name = sig:upper():gsub("^SIG", "")
    name = SIGNUMS[name] or name
    local st = 0
    for j = k, #a do
        local job = findJob(a[j], true)
        local proc = rawget(_G, "proc")
        if not job and proc and a[j]:match("^%-?%d+$") then
            -- not a job of ours: a process (init's), or -n a process group
            local ok, err = proc.kill(tonumber(a[j]), sig)
            if not ok then b.err("kill: " .. a[j] .. ": " .. err); st = 1 end
        elseif not job then
            b.err("kill: " .. a[j] .. ": no such job")
            st = 1
        elseif job.state ~= "done" then
            if name == "KILL" then
                job.state, job.status, job.killed, job.req, waiters[job] = "done", 137, true, nil, nil
                signalProcs(job, "KILL")
            elseif name == "STOP" or name == "TSTP" then
                signalProcs(job, name)
                if jobControl then stop(job) end
            elseif name == "CONT" then
                continue(job)
            elseif name ~= "0" then
                job.signalled = true
                local stopped = job.state == "stopped"
                signalProcs(job, sig)
                if stopped then signalProcs(job, "CONT") end
                signal(job)
            end
        end
    end
    return st
end
function builtins.shift(a, b)
    local n = tonumber(a[2] or "1")
    if not n or n < 0 or n > #P.pos then b.err("shift: can't shift that many"); return 1 end
    for _ = 1, n do table.remove(P.pos, 1) end
    return 0
end
function builtins.read(a, b)
    local names = {}
    for k = (a[2] == "-r") and 3 or 2, #a do names[#names + 1] = a[k] end
    if #names == 0 then names[1] = "REPLY" end
    local line = b.readLine()
    if not line then
        for _, nm in ipairs(names) do setVar(nm, "") end
        return 1
    end
    local rest = line:match("^[ \t]*(.-)[ \t]*$")
    for k, nm in ipairs(names) do
        if k == #names then
            setVar(nm, rest)
        else
            local w, r = rest:match("^(%S*)[ \t]*(.*)$")
            setVar(nm, w)
            rest = r
        end
    end
    return 0
end
builtins["."] = function(a, b)
    if not a[2] then b.err(".: needs a file name"); return 2 end
    local text = readFile(a[2])
    if not text then b.err(".: " .. a[2] .. ": not found"); return 1 end
    P.dotDepth = P.dotDepth + 1
    runSource(text)
    P.dotDepth = P.dotDepth - 1
    P.returning = nil
    return P.status
end
-- break [n] and continue [n]: out of the n'th loop out, or on to its
-- next turn
local function loopJump(kind)
    return function(a, b)
        local n = tonumber(a[2] or "1")
        if not n or n < 1 or n ~= math.floor(n) then b.err(kind .. ": " .. a[2] .. ": loop count out of range"); return 1 end
        if P.loopDepth == 0 then b.err(kind .. ": only meaningful in a loop"); return 0 end
        P[kind == "break" and "breaking" or "continuing"] = math.min(n, P.loopDepth)
        return 0
    end
end
builtins["break"] = loopJump("break")
builtins["continue"] = loopJump("continue")
builtins["return"] = function(a, b)
    if P.funcDepth == 0 and P.dotDepth == 0 then b.err("return: only in a function or a . file"); return 1 end
    local n = a[2] and tonumber(a[2])
    if a[2] and not n then b.err("return: " .. a[2] .. ": numeric argument required"); n = 2 end
    P.returning = true
    return n or P.status
end
-- local name[=value]...: the variable as it was comes back when the
-- function returns
builtins["local"] = function(a, b)
    if not P.locals then b.err("local: only in a function"); return 1 end
    for k = 2, #a do
        local name, v = a[k]:match("^([%a_][%w_]*)=(.*)$")
        name = name or a[k]:match("^[%a_][%w_]*$")
        if not name then b.err("local: " .. a[k] .. ": not a valid name"); return 1 end
        if not P.locals[name] then P.locals[name] = { value = P.vars[name], exported = P.exported[name] } end
        P.vars[name] = v
    end
    return 0
end
-- builtins a function can't hide
local SPECIAL = { [":"] = true, ["."] = true, ["break"] = true, ["continue"] = true, ["return"] = true,
    exit = true, export = true, unset = true, shift = true, ["local"] = true }

-- Something has to stop what's running: Ctrl+T, exit, break, continue or return.
local function halted()
    return P.interrupted or P.aborting or P.exiting or P.breaking or P.continuing or P.returning
end

-- A ${name:?word} failed (it said so): a script, a subshell or a job ends
-- with status 1, as POSIX has a non-interactive shell exit; at the prompt
-- the rest of the line is skipped.  The command's status.
local function expansionFailed()
    P.status = 1
    if P == mainP and jobControl then P.aborting = true else P.exiting = true end
    return 1
end

-- Apply redirects to fd; what they open goes in opened (to close after).
-- False if one couldn't be done (said so).
local function redirect(redirs, fd, opened)
    for _, r in ipairs(redirs) do
        local name = fields(r.target, true)
        if r.op == ">&" or r.op == "<&" then
            local n = tonumber(name)
            if name == "-" then fd[r.fd] = r.op == "<&" and { data = "" } or stream(function() end)
            elseif n and fd[n] then fd[r.fd] = fd[n]
            else report(fd[2], "ccsh: " .. name .. ": bad file descriptor"); return false end
        elseif r.op == "<" then
            local text = name == "/dev/null" and "" or readFile(name)
            if not text then report(fd[2], "ccsh: " .. name .. ": No such file or directory"); return false end
            fd[r.fd] = { data = text }
        else
            -- > >> >|, and &> &>> (bash's): both stdout and stderr to the file
            local s
            if name == "/dev/null" then
                s = stream(function() end)
            else
                local path = shell.resolve(name)
                local f = not fs.isDir(path) and fs.open(path, (r.op == ">>" or r.op == "&>>") and "ab" or "wb")
                if not f then report(fd[2], "ccsh: " .. name .. ": can't create"); return false end
                s = stream(function(x) f.write(x) end, function() f.close() end)
                opened[#opened + 1] = s
            end
            fd[r.fd] = s
            if r.op == "&>" or r.op == "&>>" then fd[2] = s end
        end
    end
    return true
end
local function closeAll(opened) for _, s in ipairs(opened) do s.close() end end

-- What a command starts with: the pipe's ends, else the shell's (or, in
-- a piped or redirected compound command, its).
local function startFds(inText, out)
    return { [0] = inText and { data = inText } or P.defaultIn or TTY, [1] = out or P.defaultOut or TTY,
             [2] = P.defaultErr or TTY }
end

-- fn(), with what's in fd as what the commands inside read and write.
-- Their input is one reader they share: each takes what it reads.
local function withFds(fd, fn)
    local i0, o1, e2 = P.defaultIn, P.defaultOut, P.defaultErr
    local inp = fd[0]
    if inp ~= TTY and inp.data then inp = { handle = reader(inp.data) } end
    P.defaultIn = inp ~= TTY and inp.handle and inp or nil
    P.defaultOut = fd[1] ~= TTY and fd[1].raw and fd[1] or nil
    P.defaultErr = fd[2] ~= TTY and fd[2].raw and fd[2] or nil
    local ok, st = pcall(fn)
    P.defaultIn, P.defaultOut, P.defaultErr = i0, o1, e2
    if not ok then error(st, 0) end
    return st
end

-- Words as a command's arguments: expanded, split, globbed.
local function expandWords(words)
    local argv = {}
    for _, w in ipairs(words) do
        for _, f in ipairs(fields(w)) do
            local g = glob(f)
            if g then
                for _, s in ipairs(g) do argv[#argv + 1] = s end
            else
                argv[#argv + 1] = table.concat(f.chars)
            end
        end
    end
    return argv
end

local runList, execCompound

-- A loop's turn ends: true to leave the loop (break, Ctrl+T, exit,
-- return; continue for a loop further out).
local function loopTurn()
    if P.breaking then
        P.breaking = P.breaking > 1 and P.breaking - 1 or nil
        return true
    elseif P.continuing then
        P.continuing = P.continuing > 1 and P.continuing - 1 or nil
        return P.continuing ~= nil
    end
    return halted() and true or false
end

-- Every 100 turns of a loop, let the rest of the computer run (and see
-- Ctrl+T): a loop of builtins alone would never wait for anything.
local turns = 0
local function breathe()
    turns = turns + 1
    if turns % 100 ~= 0 then return end
    os.queueEvent("ccsh_loop")
    if os.pullEventRaw("ccsh_loop") == "terminate" then P.interrupted, P.status = true, 130 end
end

local function loop(cmd, items)
    local st = 0
    P.loopDepth = P.loopDepth + 1
    local k = 0
    while true do
        local go = true                 -- (false: the condition was cut short, by continue say)
        if items then
            k = k + 1
            if k > #items then break end
            setVar(cmd.name, items[k])
        else
            runList(cmd.cond)
            if halted() then
                if loopTurn() then break end
                go = false
            elseif (P.status == 0) == (cmd["until"] == true) then
                break
            end
        end
        if go then
            runList(cmd.body)
            st = P.status
            if halted() and loopTurn() then break end
        end
        breathe()
        if P.interrupted then break end
    end
    P.loopDepth = P.loopDepth - 1
    return P.interrupted and 130 or st
end

-- if, while, until, for, case, { }, ( ): its status.
local function compound(cmd)
    local kind = cmd.kind
    if kind == "group" then
        runList(cmd.body)
        return P.status
    elseif kind == "subshell" then
        return subshell(function() runList(cmd.body) end)
    elseif kind == "if" then
        for _, c in ipairs(cmd.clauses) do
            runList(c.cond)
            if halted() then return P.status end
            if P.status == 0 then
                P.status = 0
                runList(c.body)
                return P.status
            end
        end
        P.status = 0
        if cmd.otherwise then runList(cmd.otherwise) end
        return P.status
    elseif kind == "while" then
        return loop(cmd)
    elseif kind == "for" then
        local items = cmd.items and expandWords(cmd.items) or copy(P.pos)
        return loop(cmd, items)
    elseif kind == "case" then
        local subject = fields(cmd.subject, true)
        for _, item in ipairs(cmd.items) do
            for _, p in ipairs(item.patterns) do
                local f = fields(p, "pattern")
                local pat = globPattern(f.chars, f.magic)
                if (pat and subject:match(pat)) or (not pat and table.concat(f.chars) == subject) then
                    P.status = 0
                    runList(item.body)
                    return P.status
                end
            end
        end
        return 0
    end
end

-- A compound command (or a function definition), in a pipe or not, with
-- its redirects.
function execCompound(cmd, inText, out)
    if cmd.kind == "func" then
        P.funcs[cmd.name] = cmd.body
        return 0
    end
    local fd, opened = startFds(inText, out), {}
    local ok, st = pcall(function()
        if not redirect(cmd.redirs, fd, opened) then return 1 end
        return withFds(fd, function() return compound(cmd) end)
    end)
    closeAll(opened)
    if not ok and st == EXPANSION then return expansionFailed() end
    if not ok then error(st, 0) end
    return st
end

-- A function called: its arguments as $1..., its body with the call's
-- input and output.
local function callFunction(body, argv, fd)
    if P.funcDepth >= 64 then report(fd[2], "ccsh: " .. argv[1] .. ": functions nested too deep"); return 1 end
    local pos, loops, locals = P.pos, P.loopDepth, P.locals
    P.pos, P.loopDepth, P.locals = { table.unpack(argv, 2) }, 0, {}
    P.funcDepth = P.funcDepth + 1
    local ok, st = pcall(withFds, fd, function() return execCompound(body) end)
    for name, v in pairs(P.locals) do P.vars[name], P.exported[name] = v.value, v.exported end
    P.pos, P.loopDepth, P.locals = pos, loops, locals
    P.funcDepth = P.funcDepth - 1
    if not ok then error(st, 0) end
    if P.returning then P.returning = nil; st = P.status end
    return st
end

-- Under init: run argv as a process of its own (ctx its io, env its
-- environment), a child of this shell's in its job's group (at the
-- prompt), in front of the terminal while its job is.  Returns what
-- shell.execute did, whether Ctrl+T reached it, and how it ended ("ok",
-- "killed", an error), as drive's first two.
-- Programs that use Ctrl+C as a key, so it isn't made an interrupt for
-- them: CraftOS's interactive ones (edit, which nano is; paint; the lua
-- prompt; shells and games), which stop on Ctrl+T as they always have,
-- and ccnix's vi, vim and telnet (Esc, and the far end's Ctrl+C).
local KEEPS_CTRL_C = { edit = true, paint = true, lua = true, shell = true, multishell = true,
    fg = true, bg = true, adventure = true, worm = true, redirection = true, chat = true,
    vi = true, vim = true, telnet = true }
local function keepsCtrlC(name)
    local path = name and shell.resolveProgram(name)
    if not path then return false end
    local base = fs.getName(path)
    if base:sub(-4) == ".lua" then base = base:sub(1, -5) end
    return KEEPS_CTRL_C[base] == true
end

local function spawnCommand(ctx, argv, env)
    local j = currentJob
    local res = {}
    local pid = kern.spawn({
        cmd = table.concat(argv, " "), term = ctx.term, env = env,
        pgid = jobControl and jobPid(j) or nil,
        enter = function() return enter(ctx) end,
        leave = function(_, o) leave(ctx, o) end,
        fn = function()
            if keepsCtrlC(argv[1]) then kern.ignore("INT") end
            _G.POSIX_STATUS = nil
            local ok, r = pcall(shell.execute, table.unpack(argv))
            if not ok then printError(tostring(r)) end
            res.ok, res.st = ok and r, _G.POSIX_STATUS
        end,
    })
    children[pid] = j
    j.procs = j.procs + 1
    if isFront(j) then toFront(j.pid) end
    local ended
    repeat
        local ev = table.pack(os.pullEventRaw())
        if ev[1] == "proc_exit" and ev[2] == pid then ended = ev end
    until ended
    children[pid] = nil
    j.procs = j.procs - 1
    if isFront(j) then toFront(myPgid) end
    _G.POSIX_STATUS = res.st
    return res.ok, ended[5] == true, ended[3]
end

-- Run one command: inText is what the pipe before it wrote (nil: none),
-- out the pipe after it (nil: the shell's output).  Returns its status.
local function runCommand(cmd, inText, out)
    if cmd.kind ~= "simple" then return execCompound(cmd, inText, out) end
    local fd, opened = startFds(inText, out), {}
    local function done(st)
        closeAll(opened)
        return st
    end

    -- the words, the redirects and the X=value words, expanded (a
    -- ${X:?} that fails stops it here)
    P.subStatus = nil
    local argv, assigns = nil, {}
    local expandedOk, redirected = pcall(function()
        argv = expandWords(cmd.words)
        if not redirect(cmd.redirs, fd, opened) then return false end
        for k, a in ipairs(cmd.assigns) do assigns[k] = { name = a.name, value = fields(a.value, true) } end
        return true
    end)
    if not expandedOk then
        if redirected == EXPANSION then return done(expansionFailed()) end
        closeAll(opened)
        error(redirected, 0)
    end
    if not redirected then return done(1) end
    if #argv == 0 then
        for _, a in ipairs(assigns) do setVar(a.name, a.value) end
        return done(P.subStatus or 0)
    end

    local fn = P.funcs[argv[1]]
    if fn and not SPECIAL[argv[1]] then return done(callFunction(fn, argv, fd)) end

    -- [ expression ]: test, its last word "]".  A ROM path can't hold "[",
    -- so this is the shell's, not a [.lua.
    if argv[1] == "[" then
        if argv[#argv] ~= "]" then report(fd[2], "[: missing ]"); return done(2) end
        argv = { "test", table.unpack(argv, 2, #argv - 1) }
    end

    local input = fd[0] == TTY and real.input or fd[0].handle or reader(type(fd[0].data) == "string" and fd[0].data or "")
    local builtin = builtins[argv[1]]
    if builtin then
        return done(builtin(argv, {
            err = function(s) report(fd[2], "ccsh: " .. s) end,
            out = function(s)
                if fd[1] ~= TTY and fd[1].raw then fd[1].raw(s) else write(s) end
            end,
            assigns = assigns,
            readLine = function()
                if input ~= io.stdin then return input:read("l") end
                local l, why = real.editLine({})
                if why == "interrupt" or why == "terminate" then P.interrupted = true end   -- (Ctrl+C or Ctrl+T: the rest stops too)
                return l
            end,
        }))
    end
    if not shell.resolveProgram(argv[1]) then
        report(fd[2], "ccsh: " .. argv[1] .. ": not found")
        return done(127)
    end

    local outS = fd[1] ~= TTY and fd[1].raw and fd[1] or nil
    local errS = fd[2] ~= TTY and fd[2].raw and fd[2] or nil
    local envT = processEnv(assigns)
    local ctx = { input = input, kb = real.kb, env = envApi(envT) }
    if outS then
        ctx.term, ctx.output, ctx.write = outS.term, outS.handle, outS.raw
        ctx.kb = function(...) return withReal(real.kb, ...) end
    else
        ctx.term, ctx.output, ctx.write = real.guarded or real.term, real.output, real.write
    end
    if errS then
        ctx.stderr = errS.handle
        ctx.printError = function(...) errS.raw(join(...) .. "\n") end
    elseif outS then
        ctx.stderr = handle({ write = function(s) withReal(function() real.stderr:write(s) end) end })
        ctx.printError = function(...) return withReal(real.printError, ...) end
    else
        ctx.stderr, ctx.printError = real.stderr, real.printError
    end
    if fd[0] ~= TTY then ctx.read = function() return input:read("l") end
    elseif outS then ctx.read = function(...) return withReal(real.read, ...) end
    else ctx.read = real.read end

    _G.POSIX_STATUS = nil
    local ok, terminated, how
    if procs then ok, terminated, how = spawnCommand(ctx, argv, envT)
    else
        if currentJob then currentJob.keepsCtrlC = keepsCtrlC(argv[1]) end
        ok, terminated = drive(ctx, shell.execute, table.unpack(argv))
        if currentJob then currentJob.keepsCtrlC = nil end
    end
    local st = _G.POSIX_STATUS
    if how == "killed" then
        st = 137
    elseif terminated and not ok and (st == nil or st == 0) then
        P.interrupted = true
        st = 130
    elseif st == nil or (st == 0 and not ok) then
        st = ok and 0 or 1
    end
    return done(st)
end

local function runPipeline(p)
    local data, st = nil, 0
    for k, cmd in ipairs(p.cmds) do
        local out = k < #p.cmds and buffer() or nil
        st = runCommand(cmd, data, out)
        data = out and out.text()
        if halted() then break end
    end
    if p.neg then st = st == 0 and 1 or 0 end
    P.status = st
end

function runAndOr(ao)
    for k, item in ipairs(ao) do
        if k == 1 or (item.conn == "&&") == (P.status == 0) then runPipeline(item.pipe) end
        if halted() then return end
    end
end

function runList(list)
    for _, ao in ipairs(list) do
        if halted() then return end
        if ao.bg then background(ao); P.status = 0 else runAndOr(ao) end
    end
end

-- Parse and run src; a syntax error is reported, status 2.
function runSource(src)
    local ok, list = pcall(parse, src)
    if not ok then
        if type(list) ~= "table" then error(list, 0) end
        printError("ccsh: syntax error: " .. (list.msg ~= "" and list.msg or "unexpected end of line"))
        P.status = 2
        return
    end
    runList(list)
end

--------------------------------------------------------------------------
-- The prompt
--------------------------------------------------------------------------
-- Tab completion, for the command after the last |, ; or &: the stock
-- shell's (program names, and what a program registers for its
-- arguments), else a file or directory name.
local function complete(line)
    local start, q = 1, nil
    for k = 1, #line do
        local c = line:sub(k, k)
        if q then
            if c == q then q = nil end
        elseif c == "'" or c == '"' then q = c
        elseif c == "|" or c == ";" or c == "&" then start = k + 1 end
    end
    local tail = line:sub(start):gsub("^%s+", "")
    if tail == "" then return nil end
    local got = shell.complete and shell.complete(tail)
    if got and #got > 0 then return got end
    -- an argument the program has no completion of its own for: a file
    -- or directory name, as POSIX shells complete (not a glob or $X)
    local word = tail:match("[^%s<>]*$")
    if word == tail or not fs.complete then return got end
    word = word:gsub("^['\"]", "")
    if word:find("[%*%?%[%$`]") then return got end
    return fs.complete(word, shell.dir(), true, true)
end

-- The line editor: lib/readline (its keys are in the header above), or
-- read() if it can't be loaded.  opts as readline.read's; the line, or
-- nil and why ("eof", "interrupt", "terminate").
package.path = (ccnix and ccnix.lib or "/" .. fs.getDir(fs.getDir(shell.getRunningProgram())) .. "/lib/?.lua;") .. package.path  -- ccnix's lib/, or the one beside bin/
local editor                         -- readline once loaded; false if it couldn't be
local function editLine(opts)
    if editor == nil then
        local ok, m = pcall(require, "readline")
        editor = ok and type(m) == "table" and m or false
        -- commands write through it: a background job's output takes the
        -- prompt off first, and the editor draws it again below
        if editor and editor.guard then real.guarded = editor.guard(real.term) end
    end
    if editor then return editor.read(opts) end
    if opts.prompt then
        if term.isColour() and opts.promptColour then term.setTextColour(opts.promptColour) end
        write(opts.prompt)
        term.setTextColour(colours.white)
    end
    local ok, line = pcall(read, nil, opts.history, opts.complete)
    if ok then return line end
    if line == "Terminated" then return nil, "terminate" end
    error(line, 0)
end
real.editLine = editLine             -- (the read builtin's, at the keyboard)

-- A line typed at the prompt `text`: nil for Ctrl+T, or Ctrl+D on an
-- empty line; false for Ctrl+C (the line dropped, status 130).
local function prompt(text, hist)
    local useComplete = not settings or settings.get("shell.autocomplete", true)
    local line, why = editLine({ prompt = text, promptColour = colours.yellow, colour = colours.white,
        history = hist, complete = useComplete and complete or nil })
    if line then return line end
    if why == "interrupt" then P.status = 130; return false end
    return nil
end

-- The prompt's text: $PS1 with its escapes (\h the computer's label, or
-- its ID if it has none; \w the directory; \W its last part; \i the ID;
-- \$ \n \\), or, with PS1 unset, "label:/dir$ " ("/dir$ " with no label).
local function promptText()
    local label = os.getComputerLabel and os.getComputerLabel()
    local ps1 = P.vars.PS1
    if ps1 == nil then return (label and (label .. ":") or "") .. "/" .. shell.dir() .. "$ " end
    local dir = "/" .. shell.dir()
    local esc = {
        h = label or tostring(os.getComputerID()), H = label or tostring(os.getComputerID()),
        w = dir, W = dir == "/" and "/" or dir:match("([^/]+)$"), i = tostring(os.getComputerID()),
        ["$"] = "$", n = "\n", ["\\"] = "\\",
    }
    return (ps1:gsub("\\(.)", function(c) return esc[c] or ("\\" .. c) end))
end

-- History: the lines typed at the prompt, the last $HISTSIZE of them
-- (1000 when it's unset or not a number), kept in $HISTFILE too (none
-- when it's unset or empty).  A line is added to the file as it's typed,
-- and the file is cut to its last $HISTSIZE lines when ccsh starts and
-- leaves, so shells in other tabs add to it too.
local function histSize()
    local n = tonumber(P.vars.HISTSIZE)
    return n and math.max(0, math.floor(n)) or 1000
end

local function histFile()
    local name = P.vars.HISTFILE
    return name and name ~= "" and shell.resolve(name) or nil
end

-- The file cut to its last $HISTSIZE lines; those lines.
local function histTrim()
    local path, max = histFile(), histSize()
    local lines = {}
    if not path then return lines end
    for l in (readFile("/" .. path) or ""):gmatch("[^\n]+") do lines[#lines + 1] = l end
    if #lines > max then
        lines = { table.unpack(lines, #lines - max + 1) }
        local f = fs.open(path, "wb")
        if f then
            f.write(#lines > 0 and table.concat(lines, "\n") .. "\n" or "")
            f.close()
        end
    end
    return lines
end

-- line, typed at the prompt, added to the history and its file.
local function remember(hist, line)
    if not line:match("%S") or hist[#hist] == line then return end
    local max = histSize()
    if max == 0 then return end
    hist[#hist + 1] = line
    while #hist > max do table.remove(hist, 1) end
    local path = histFile()
    local f = path and not fs.isDir(path) and fs.open(path, "ab")
    if f then
        f.write(line .. "\n")
        f.close()
    end
end

-- A line typed at the prompt, parsed: { line, list } or { line, err };
-- nil for Ctrl+T.  It's read as a job, so background jobs carry on
-- meanwhile.
local function readLine(hist)
    local j = runTop(function()
        local line = prompt(promptText(), hist)
        if line == false then return { line = "", list = {} } end      -- (Ctrl+C)
        if line then remember(hist, line) end
        while line do
            local ok, r = pcall(parse, line)
            if ok then return { line = line, list = r } end
            if type(r) ~= "table" then error(r, 0) end
            if not r.more then return { line = line, err = r.msg } end
            local nxt = prompt("> ", {})
            if nxt == false then return { line = "", list = {} } end
            line = nxt and line .. "\n" .. nxt
        end
    end)
    return j.value
end

local PROFILE = "/.profile"
local HISTFILE = "/.ccsh_history"

local function interactive()
    jobControl = true
    if procs then
        myPgid = kern.getpgid()
        kern.ignore("TSTP")             -- (Ctrl+Z is for the job in front, not this shell)
        kern.ignore("INT")              -- (and Ctrl+C at the prompt drops the line)
    end
    local warned = false
    print("ccsh: exit, or hold Ctrl+T, to leave")
    if P.vars.HISTFILE == nil then P.vars.HISTFILE = HISTFILE end
    if P.vars.HISTSIZE == nil then P.vars.HISTSIZE = "1000" end
    if fs.exists(PROFILE) and not fs.isDir(PROFILE) then
        runTop(function() runSource(readFile(PROFILE)) end)
    end
    local hist = histTrim()
    while true do
        if P.exiting then
            if liveJobs() == 0 or warned then break end
            printError("ccsh: there are jobs (jobs lists them); exit again to end them")
            P.exiting, warned = false, true
        end
        notify()
        local got = readLine(hist)
        if not got then
            if liveJobs() == 0 or warned then print(); break end
            print()
            printError("ccsh: there are jobs (jobs lists them); Ctrl+T again to end them")
            warned = true
        else
            P.interrupted, P.aborting = false, nil
            if got.err then
                printError("ccsh: syntax error: " .. got.err)
                P.status = 2
            elseif #got.list > 0 then
                local j = run(newJob(function() runList(got.list); return P.status end, mainP, got.line))
                if j.state == "stopped" then P.status = 148 end
            end
            if got.line:match("%S") and not P.exiting then warned = false end
        end
    end
    histTrim()
    endJobs()
end

-- ccsh --spawn token: what fg or bg prog left in CCSH_SPAWN, run
-- in this new tab with its environment.
local function spawn(token)
    local hand = rawget(_G, "CCSH_SPAWN")
    local rec = hand and hand[token]
    if not rec then printError("ccsh: --spawn: nothing to run"); P.status = 2; return end
    hand[token] = nil
    if next(hand) == nil then _G.CCSH_SPAWN = nil end
    importEnv(rec.env)
    if multishell and multishell.setTitle and multishell.getCurrent then
        multishell.setTitle(multishell.getCurrent(), fs.getName(rec.argv[1]))
    end
    local words = {}
    for k, a in ipairs(rec.argv) do words[k] = { { t = "lit", s = a, q = true } } end
    runTop(function() runList({ { { pipe = { cmds = { { kind = "simple", words = words, assigns = {}, redirs = {} } } } } } }) end)
end

if args[1] == "-c" then
    if not args[2] then
        printError("usage: ccsh [-c command [name [arg...]] | script [arg...]]")
        P.status = 2
    else
        -- The stock shell splits words at spaces and keeps single quotes,
        -- so `ccsh -c 'echo a; b'` typed there arrives as "'echo",
        -- "a;", "b'": join the pieces up to the closing quote and drop the
        -- quotes, as a POSIX shell would have.
        local src, k = args[2], 3
        local ok, e = pcall(parse, src)
        if not ok and type(e) == "table" and e.more and src:sub(1, 1) == "'" then
            while not (#src > 1 and src:sub(-1) == "'") and args[k] do
                src, k = src .. " " .. args[k], k + 1
            end
            if #src > 1 and src:sub(-1) == "'" then src = src:sub(2, -2) end
        end
        P.arg0 = args[k] or "ccsh"
        for j = k + 1, #args do P.pos[#P.pos + 1] = args[j] end
        runTop(function() runSource(src) end)
        waitAll()
    end
elseif args[1] == "--spawn" then
    spawn(args[2])
elseif args[1] then
    local text = readFile(args[1])
    if not text then
        printError("ccsh: " .. args[1] .. ": can't open")
        P.status = 127
    else
        P.arg0 = args[1]
        for k = 2, #args do P.pos[#P.pos + 1] = args[k] end
        runTop(function() runSource(text) end)
        waitAll()
    end
else
    interactive()
end

_G.POSIX_STATUS = P.status
if P.status ~= 0 then error("", 0) end
