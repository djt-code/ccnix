-- sim/ccsh.lua
--
-- ccsh, the POSIX-style shell, on a shellworld turtle: quoting and
-- variables, pipes, redirects, && || ! ;, globs, $(...), builtins, how
-- print/term.write/printError output is captured, a command that waits
-- for events (its io swapped in only while it runs), Ctrl+T, the prompt
-- and scripts.
local PROJ = ...
package.path = PROJ .. "/lib/?.lua;" .. PROJ .. "/sim/lib/?.lua;" .. package.path
local M = require("mock")
local SW = require("shellworld")
local check = M.check

local W = SW.new(PROJ)
for _, u in ipairs({ "printf", "sort", "head", "tr", "cat", "wc", "grep", "echo", "more", "env" }) do W:install(u) end

-- small programs to run under the shell
local HELPERS = {
    -- its arguments, each in [ ]
    args = [[local t = {} for i, a in ipairs({ ... }) do t[i] = "[" .. a .. "]" end io.write(table.concat(t), "\n")]],
    -- the ways a stock program writes
    pr = [[print("one") term.write("two") print() io.write("three\n") write("four") print(" five")]],
    perr = [[print("out") printError("bad")]],
    -- textutils.tabulate's way: columns by cursor position
    cols = [[local _, y = term.getCursorPos() term.setCursorPos(1, y) term.write("aa")
             term.setCursorPos(10, y) term.write("bb") print() term.write("cc") print()]],
    -- waits for an event, writing before and after
    yld = [[io.write("a\n") local _, v = os.pullEvent("x") io.write("b " .. tostring(v) .. "\n")]],
    waitT = [[os.pullEvent("never")]],
    ask = [[local l = read() print("got " .. tostring(l))]],
    crash = [[error("boom")]],
    -- os.getenv of each argument; senv sets Q and shows it
    genv = [[for _, a in ipairs({ ... }) do print(a .. "=" .. tostring(os.getenv and os.getenv(a))) end]],
    senv = [[os.setenv("Q", "in") print("Q=" .. os.getenv("Q"))]],
    -- waits for an "x" event (with W.yieldEvents)
    tick = [[local _, v = os.pullEvent("x") print("tick " .. tostring(v))]],
    ywait = [[os.pullEvent("y") print("y")]],
}
for name, src in pairs(HELPERS) do W:file("ccnix/bin/" .. name .. ".lua", src) end

local function sh(line, opts) return W:run("ccsh", "-c", line, opts or {}) end
local function show(s) return (tostring(s):gsub("\n", "|")) end

-- 1. quoting, variables, field splitting
local r = sh([[X=val; args 'a  b' "c $X" d\ e "" '$X' "\$X" "it's"]])
check("quotes: single literal, double expands, \\ escapes, \"\" an empty word",
    r.out == "[a  b][c val][d e][][$X][$X][it's]\n", show(r.out))
r = sh([[X='p  q'; args $X "$X" ${X}; E=; args $E "$E" x; args ${NOPE:-dflt} "${NOPE:-two words}"]])
check("unquoted expansions split, quoted ones don't; empty vanishes unless quoted; ${X:-default}",
    r.out == "[p][q][p  q][p][q]\n[][x]\n[dflt][two words]\n", show(r.out))
r = sh([[a=1 b=2; echo $a$b; export E=5; echo $E; unset E; echo "[$E]"]])
check("assignments, export, unset", r.out == "12\n5\n[]\n", show(r.out))
r = sh([[echo a # not this
echo b |
  tr b c]])
check("# comments; a newline ends a command; a line ending in | goes on", r.out == "a\nc\n", show(r.out))

-- 2. pipes
r = sh([[printf 'b\na\nc\n' | sort | head -n 2]])
check("a three-stage pipe", r.out == "a\nb\n" and r.status == 0, show(r.out))
r = sh([[pr | cat]])
check("print, term.write, io.write and write all go down the pipe, in order",
    r.out == "one\ntwo\nthree\nfour five\n", show(r.out))
r = sh([[cols | cat]])
check("cursor-placed columns come out as text", r.out == "aa       bb\ncc\n", show(r.out))
W:file("m.txt", "hi\n")
r = sh([[more nope m.txt | cat; grep zzz m.txt; echo $?]])
check("more in a pipe copies like cat; a utility's status is $?",
    r.out == "hi\n1\n" and r.err[1] == "more: nope: No such file or directory", show(r.out) .. " " .. show(r.err[1]))

-- 3. redirects
r = sh([[echo hi > f.txt; echo there >> f.txt; cat < f.txt]])
check("> writes, >> appends, < reads", r.out == "hi\nthere\n" and W:read("f.txt") == "hi\nthere\n", show(r.out))
r = sh([[cat nope 2> err.txt; echo $?]])
check("2> takes the error message", r.out == "1\n" and #r.err == 0
    and W:read("err.txt") == "cat: nope: No such file or directory\n", show(W:read("err.txt")))
r = sh([[cat nope 2>&1 | tr a-z A-Z]])
check("2>&1 sends errors down the pipe", r.out == "CAT: NOPE: NO SUCH FILE OR DIRECTORY\n" and #r.err == 0, show(r.out))
r = sh([[cat nope > o1.txt 2>&1; cat nope 2>&1 > o2.txt]])
check(">f 2>&1 puts both in f; 2>&1 >f leaves errors on the screen",
    W:read("o1.txt") == "cat: nope: No such file or directory\n" and W:read("o2.txt") == "" and #r.err == 1,
    show(W:read("o1.txt")) .. " / " .. show(W:read("o2.txt")))
r = sh([[perr | cat]])
check("printError stays on the screen when only stdout is piped", r.out == "out\n" and r.err[1] == "bad", show(r.out))
r = sh([[perr 2>&1 | cat; perr 2> e.txt]])
check("printError follows 2>&1 and 2>", r.out == "out\nbad\nout\n" and W:read("e.txt") == "bad\n" and #r.err == 0,
    show(r.out))
r = sh([[cat nope 2>/dev/null; echo x > /dev/null; cat < /dev/null; echo done]])
check("/dev/null swallows output and reads as empty", r.out == "done\n" and #r.err == 0, show(r.out))
r = sh([[echo x > /rom/x; echo $?; cat < nope; echo $?]])
check("a file that can't be made or read: the shell says so, status 1, command not run",
    r.out == "1\n1\n" and r.err[1] == "ccsh: /rom/x: Read-only file system"
    and r.err[2] == "ccsh: nope: No such file or directory", show(r.out) .. " " .. table.concat(r.err, "|"))
r = sh([[echo x > /disk/f.txt; echo $?; echo x >> nodir/f.txt; echo $?; echo x > /rom; echo $?]])
check("> into a folder that isn't there (a disk drive with no disk), or onto a folder: an error, no folder made",
    r.out == "1\n1\n1\n" and r.err[1] == "ccsh: /disk/f.txt: No such file or directory"
    and r.err[2] == "ccsh: nodir/f.txt: No such file or directory" and r.err[3] == "ccsh: /rom: Is a directory"
    and not W.fs.exists("disk") and not W.fs.exists("nodir"), show(r.out) .. " " .. table.concat(r.err, "|"))
r = sh([[echo '>' x; echo hi '>' f2.txt]])
check("a quoted > is just text to echo under ccsh", r.out == "> x\nhi > f2.txt\n" and W:read("f2.txt") == nil,
    show(r.out))

-- 4. && || ! ; and status
r = sh([[false || echo yes; true && echo ok; false && echo no; false; echo $?; ! false; echo $?; ! true; echo $?;
false && echo a || echo b]])
check("&&, ||, !, $?", r.out == "yes\nok\n1\n0\n1\nb\n", show(r.out))
r = sh([[nosuch; echo $?]])
check("a missing program: not found, 127", r.out == "127\n" and r.err[1] == "ccsh: nosuch: not found",
    show(r.out) .. " " .. show(r.err[1]))
r = sh([[crash; echo $?]])
check("a program that errors: its message, status 1", r.out == "1\n" and (r.err[1] or ""):find("boom") ~= nil,
    show(r.err[1]))
r = sh([[echo a; exit 3; echo b]])
check("exit n ends the shell with status n", r.out == "a\n" and r.status == 3, show(r.out) .. " " .. r.status)
r = sh([[false; exit]])
check("exit alone keeps the last status", r.status == 1)

-- 5. globs
W:file("g/a1.txt", "") W:file("g/a2.txt", "") W:file("g/b.txt", "") W:file("g/.hid.txt", "") W:file("g/sub/c.txt", "")
r = sh([[args *.txt; args a?.txt; args [ab]1.txt; args [!a]*; args .*; args z*]], { cwd = "g" })
check("* ? [..] [!..], dot files only by a dot, no match left as is",
    r.out == "[a1.txt][a2.txt][b.txt]\n[a1.txt][a2.txt]\n[a1.txt]\n[b.txt][sub]\n[.hid.txt]\n[z*]\n", show(r.out))
r = sh([[args */*.txt; args /g/a*; args */; args '*.txt' "*.txt" \*.txt; X='a*'; args $X "$X"]], { cwd = "g" })
check("globs across directories, absolute, trailing /; quoted ones literal; unquoted $X globs",
    r.out == "[sub/c.txt]\n[/g/a1.txt][/g/a2.txt]\n[sub/]\n[*.txt][*.txt][*.txt]\n[a1.txt][a2.txt][a*]\n", show(r.out))
W.shell.setDir("")

-- 6. command substitution
r = sh([[echo $(echo hi | tr a-z A-Z); args "$(printf 'a\n\n')" `printf b`; echo $(echo $(echo deep))]])
check("$(...) and `...`, trailing newlines dropped, nested", r.out == "HI\n[a][b]\ndeep\n", show(r.out))
r = sh([[X=$(printf 'x y'); args $X "$X"; X=$(false); echo $?; echo $(exit 3) after; echo still]])
check("substitutions split unless quoted; X=$(false) is status 1; exit inside one ends just it",
    r.out == "[x][y][x y]\n1\nafter\nstill\n", show(r.out))

-- 7. builtins
r = sh([[printf 'a b  c \n' | read x y; echo "$x/$y"; read v < f.txt; echo $v; read q < /dev/null; echo $?]])
check("read splits a line into names, the last gets the rest; 1 at the end",
    r.out == "a/b  c\nhi\n1\n", show(r.out))
r = sh([[echo $PATH; PATH=$PATH:/x; echo $PATH]])
local p0 = ".:/rom/programs:/rom/programs/http:/rom/programs/turtle:/ccnix/bin:/ccnix/turtle"
check("$PATH is the shell's path, and setting it sets that", r.out == p0 .. "\n" .. p0 .. ":/x\n" and W.path == p0 .. ":/x",
    show(r.out))
W.path = p0
W:file("lib.sh", "LIBV=from-lib\n")
r = sh([[. lib.sh; echo $LIBV]])
check(". runs a file in this shell", r.out == "from-lib\n", show(r.out))

-- 8. syntax errors
local function synErr(line, want)
    local rr = sh(line)
    return rr.status == 2 and rr.err[1] == "ccsh: syntax error: " .. want, show(rr.err[1])
end
check("echo | : unexpected end of line, status 2", synErr("echo |", "unexpected end of line"))
check("true && : unexpected end of line", synErr("true &&", "unexpected end of line"))
check("a stray )", synErr("echo )", "unexpected )"))
check("fi with no if", synErr("fi", "unexpected fi"))
check("an open quote", synErr("echo 'x", "unterminated '"))
check("> with no file", synErr("echo >", "missing file name after >"))
check("$(( )) is refused", synErr("echo $((1+1))", "$(( )) arithmetic isn't supported"))
check("${X:} is a bad substitution", synErr("echo ${X:}", "bad substitution ${X:}"))
check("${#X} too (not yet)", synErr("echo ${#X}", "bad substitution ${#X}"))
check("an unclosed ${X:-word", synErr("echo ${X:-abc", "unterminated ${"))

-- 8b. ${X:-word} and the rest: the word expanded; &> and &>>; unset -f; $$
r = sh([[D=/d; args ${U:-$D} "${U:-$D x}" ${U:-a b} "${U:-'q'}" ${U:-'a b'} ${U:-"$D y"} ${U:-$(echo sub)}]])
check("${X:-word}: the word is expanded ($D, $(...)), quoted or not as a word is, split when unquoted",
    r.out == "[/d][/d x][a][b]['q'][a b][/d y][sub]\n", show(r.out))
r = sh([[D=/d; E=; args "${E:-d}" "${E-d}" "${U-d}" "${E:+p}" "${E+p}" "${U+p}" "${D:+p $D}" ${U:+x}]])
check("with a colon, empty counts as unset; without, only unset; :+ and +",
    r.out == "[d][][d][][p][][p /d]\n", show(r.out))
r = sh([[args "${N:=new ${U:-n}}"; echo "$N"; E=; args ${E=kept} "[$E]" ${E:=now}; echo "$E"; args ${U:-${V:-in}} ${U:-{a}}]])
check(":= sets the variable (= only an unset one); nested ${ }, a { } in the word",
    r.out == "[new n]\nnew n\n[[]][now]\nnow\n[in][{a}]\n", show(r.out))
r = sh([[D=/d; X=$(echo ${U:?}); echo "${D:?not this}" "s=$?"; echo ${U:?gone $D}; echo after]])
check(":? : a word as the message, else 'parameter null or not set'; in $(...) only that ends; a script ends, status 1",
    r.out == "/d s=1\n" and r.status == 1 and r.err[1] == "ccsh: U: parameter null or not set"
        and r.err[2] == "ccsh: U: gone /d" and #r.err == 2, show(r.out) .. " " .. r.status .. " " .. show(r.errText))
r = sh([[(echo ${U?x}); echo "s=$?"; for i in 1; do echo ${1:=x}; done; echo no]])
check("? without a colon, in ( ); a positional parameter can't be assigned with :=",
    r.out == "s=1\n" and r.status == 1 and r.err[1] == "ccsh: U: x" and r.err[2] == "ccsh: $1: can't be assigned this way",
    show(r.out) .. " " .. show(r.errText))
r = W:run("ccsh", { stdin = "echo ${U:?no}; echo skipped\nif true; then echo ${U:?}; fi; echo skipped\necho \"st $?\"\n" })
check("at the prompt, a failed :? skips the rest of the line only; $? 1",
    r.out:find("/$ st 1\n", 1, true) ~= nil and not r.out:find("skipped", 1, true)
        and r.err[1] == "ccsh: U: no", show(r.out) .. " " .. show(r.errText))
r = W:run("ccsh", "-c", [[args ${10} $10 ${2}x "${11:-none}"]], "name", "a", "b", "c", "d", "e", "f", "g", "h", "i", "j")
check("${10}: positional parameters past 9 (and $10 is ${1}0)", r.out == "[j][a0][bx][none]\n", show(r.out))
r = sh([[args ${U:-*.txt} "${U:-*.txt}"]], { cwd = "g" })
check("an unquoted default globs, a quoted one doesn't", r.out == "[a1.txt][a2.txt][b.txt][*.txt]\n", show(r.out))
W.shell.setDir("")
r = sh([[cat nope &> both.txt; echo x &>> both.txt; perr &>p.txt; echo "[$!]"; echo gone &> /dev/null; cat both.txt p.txt]])
check("&> f: output and errors to f, &>> appends (not a background job and a > f)",
    r.out == "[]\ncat: nope: No such file or directory\nx\nout\nbad\n" and #r.err == 0, show(r.out) .. " " .. show(r.errText))
r = sh([[f() { echo f; }; f; unset f; f; unset -f f; f; echo $?; V=1; unset -v V; echo "[$V]"; unset -x V; echo $?
unset 1x; echo $?; g() { :; }; unset -f -- g; g]])
check("unset -f a function (not its variable), -v and plain a variable; bad options and names",
    r.out == "f\nf\n127\n[]\n2\n1\n" and r.err[1] == "ccsh: f: not found"
        and r.err[2] == "ccsh: unset: -x: bad option (unset [-f | -v] name...)"
        and r.err[3] == "ccsh: unset: 1x: not a valid name" and r.err[4] == "ccsh: g: not found",
    show(r.out) .. " " .. show(r.errText))
r = sh([[echo $$ "[$PPID]"; (echo $$); PPID=5; echo "[$PPID]"]])
check("without init: $$ is the computer's ID (in a subshell too), PPID unset and can't be set",
    r.out == "1 []\n1\n[]\n", show(r.out))

-- 9. a command that waits for events: its io only while it runs
W.yieldEvents = true
local during = {}
r = sh([[yld | cat]], { events = { { "y" }, { "x", 7 } },
    onPull = function(w)
        during[#during + 1] = w.io.output() == w.io.stdout and _G.write == w.g.write and term.current() == term.native()
            and _G.POSIX_SH == nil
    end })
check("it gets its event (others skipped) and its output stays in order", r.out == "a\nb 7\n", show(r.out))
check("while it waits, the shell's own io, write and terminal are back", #during >= 1 and during[1] == true
    and during[#during] == true)
r = sh([[waitT; echo after]], { events = { { "terminate" } } })
check("Ctrl+T stops the command and the rest of the line, status 130",
    r.out == "" and r.status == 130 and r.err[1] == "Terminated", show(r.out) .. " " .. r.status)
r = W:run("ccsh", { stdin = "waitT; echo no\necho $?\n", events = { { "terminate" } } })
check("and the prompt carries on, $? 130", r.out:find("/$ 130\n", 1, true) ~= nil and not r.out:find("no\n", 1, true),
    show(r.out))
W.yieldEvents = false

-- 10. the prompt
r = W:run("ccsh", { stdin = "echo one\necho 'two\nthree'\nexit 4\necho never\n" })
check("prompts, a quote carried to a second line, exit n",
    r.out:find("/$ one\n", 1, true) ~= nil and r.out:find("> two\nthree\n", 1, true) ~= nil and r.status == 4
    and not r.out:find("never"), show(r.out))
r = W:run("ccsh", { stdin = "echo x\n" })
check("Ctrl+T at the prompt leaves, status 0", r.status == 0 and r.out:find("x\n", 1, true) ~= nil, show(r.out))
r = W:run("ccsh", { stdin = "ask | cat\ntyped\n" })
check("a command reading the keyboard while its output is piped", r.out:find("got typed\n", 1, true) ~= nil, show(r.out))
W.label = "lab-r"
r = W:run("ccsh", { stdin = "echo $HOSTNAME\n" })
check("a computer with a label: label:/dir$ , and $HOSTNAME", r.out:find("lab-r:/$ lab-r\n", 1, true) ~= nil, show(r.out))
r = W:run("ccsh", { stdin = "PS1='[\\i \\h \\W]\\$ '\necho y\n" })
check("PS1 with \\i \\h \\W \\$", r.out:find("[1 lab-r /]$ y\n", 1, true) ~= nil, show(r.out))
W.label = nil
r = W:run("ccsh", { stdin = "PS1='\\h> '\necho z\n" })
check("no label: \\h is the ID; the default prompt unchanged", r.out:find("1> z\n", 1, true) ~= nil
    and r.out:find("/$ PS1", 1, true) == nil and r.out:find("/$ ", 1, true) ~= nil, show(r.out))

-- 11. scripts
W:file("s.sh", "#!/ccnix/bin/ccsh\n# a script\necho \"$0 $# $1\"\nargs \"$@\"\nshift\nargs $*\nexit 5\n")
r = W:run("ccsh", "s.sh", "a b", "c")
check("a script: $0 $# $1 \"$@\" shift $*, exit", r.out == "s.sh 2 a b\n[a b][c]\n[c]\n" and r.status == 5,
    show(r.out))
r = W:run("ccsh", "-c", [[args "$0" "$@"]], "me", "x", "y z")
check("-c with a name and arguments", r.out == "[me][x][y z]\n", show(r.out))
-- what the stock shell passes for: ccsh -c 'args $0 $1; exit' nm one
r = W:run("ccsh", "-c", "'args", "$0", "$1;", "exit'", "nm", "one")
check("-c from the stock shell: a single-quoted command split at spaces is joined back",
    r.out == "[nm][one]\n" and r.status == 0, show(r.out))

-- 12. the environment
r = sh([[X=1; genv X; export X; genv X; Y=2 genv Y; echo "[$Y]"; export Z=3; unset Z; genv Z]])
check("os.getenv: only exported variables; X=1 cmd for that command alone; unset unexports",
    r.out == "X=nil\nX=1\nY=2\n[]\nZ=nil\n", show(r.out))
r = sh([[genv PATH PWD; senv; genv Q]])
check("PATH and PWD are always there; os.setenv changes only the program's own copy",
    r.out == "PATH=" .. p0 .. "\nPWD=/\nQ=in\nQ=nil\n", show(r.out))
r = sh([[export A=1 B="it's" C; export -n A; export -p]])
check("export -p: re-readable, quoted; export -n unexports; a name with no value is listed bare",
    r.out == "export B='it'\\''s'\nexport C\nexport HOSTNAME='1'\nexport PATH='" .. p0
        .. "'\nexport PS1='\\w\\$ '\nexport PWD='/'\n", show(r.out))
r = sh([[genv HOSTNAME PS1; PS1='$ '; genv PS1; ccsh -c 'echo "$PS1"']])
check("HOSTNAME and PS1 are in the environment; a PS1 set is passed on",
    r.out == "HOSTNAME=1\nPS1=\\w\\$ \nPS1=$ \n$ \n", show(r.out))
W.label = "lab-e"
r = sh([[genv HOSTNAME PS1]])
W.label = nil
check("with a label: HOSTNAME is it, PS1 starts as \\h:\\w\\$ ", r.out == "HOSTNAME=lab-e\nPS1=\\h:\\w\\$ \n", show(r.out))
r = W:run("ccsh", { stdin = "unset PS1\necho u\n" })
check("PS1 unset: the prompt falls back to the default text", r.out:find("/$ u\n", 1, true) ~= nil, show(r.out))
r = sh([[export A=outer; ccsh -c 'echo $A; genv A; B=in genv B'; genv B]])
check("a ccsh run from ccsh takes the environment as exported variables",
    r.out == "outer\nA=outer\nB=in\nB=nil\n", show(r.out))
r = sh([[export E=1; env | grep ^E=; env -u E genv E; env F=2 genv F; env -i genv E PATH; genv E]])
check("env lists it, and runs a command with it changed (-u, name=value, -i), then puts it back",
    r.out == "E=1\nE=nil\nF=2\nE=nil\nPATH=nil\nE=1\n", show(r.out))
r = W:run("env")
check("env outside ccsh: there is no environment, 125",
    r.status == 125 and r.err[1] == "env: no environment here: run it under ccsh", show(r.err[1]))

-- 13. jobs
W.yieldEvents = true
r = sh([[tick & echo "first $!"; wait; echo "end $?"]], { events = { { "x", 5 } } })
check("a & runs in the background while the line goes on; $!; wait", r.out == "first 1\ntick 5\nend 0\n", show(r.out))
r = sh([[tick & jobs; jobs -l]], { events = { { "x", 1 } } })
check("jobs (-l with the process ID); a script waits for its jobs at the end",
    r.out == "[1]+ Running  tick &\n[1]+ 1 Running  tick &\ntick 1\n", show(r.out))
r = sh([[waitT & kill %1; wait %1; echo $?; jobs]])
check("kill %1 ends a job (status 130), and wait gives its status", r.out == "130\n", show(r.out))
r = sh([[tick & fg %1; echo "fg $?"]], { events = { { "x", 2 } } })
check("fg %1 waits for the job, with its status", r.out == "tick\ntick 2\nfg 0\n", show(r.out))
r = sh([[X=1; X=2 & exit 4 & echo "$X $?"; wait; echo "w $?"]])
check("a background job has its own variables, and exit there ends only it", r.out == "1 0\nw 0\n", show(r.out))
r = sh([[tick & wait; echo no]], { events = { { "terminate" }, { "terminate" } } })
check("Ctrl+T ends wait and the rest of the line; again, the jobs left at the end",
    r.out == "" and r.status == 130, show(r.out) .. " " .. r.status)
local ctrlZ = { { "key", keys.leftCtrl }, { "key", keys.z } }
r = W:run("ccsh", { stdin = "tick\njobs\nfg\necho \"fg $?\"\n", events = { ctrlZ[1], ctrlZ[2], { "x", 9 } } })
check("at the prompt, Ctrl+Z stops a command; jobs; fg starts it again in front",
    r.out:find("/$ \n[1]+ Stopped  tick\n/$ [1]+ Stopped  tick\n/$ tick\ntick 9\n/$ fg 0\n", 1, true) ~= nil,
    show(r.out))
r = W:run("ccsh", { stdin = "tick\nywait\nbg\njobs\n", events = { ctrlZ[1], ctrlZ[2], { "x", 4 }, { "y" } } })
check("a stopped job keeps the events it misses; bg starts it in the background; Done told before the prompt",
    r.out:find("/$ y\n/$ [1]+ tick &\ntick 4\n[1]+ Done     tick\n/$ /$ ", 1, true) ~= nil, show(r.out))
r = W:run("ccsh", { stdin = "tick &\nexit\nexit\n" })
check("exit with jobs: a warning first, then the jobs end with the shell",
    r.out:find("/$ [1] 1\n", 1, true) ~= nil and r.err[1] == "ccsh: there are jobs (jobs lists them); exit again to end them",
    show(r.out) .. " " .. show(r.errText))
W.yieldEvents = false

-- 14. .profile, and fg/bg prog in a tab
W:file(".profile", "PS1='p> '\nexport PF=yes\n")
r = W:run("ccsh", { stdin = "genv PF\n" })
check("/.profile runs when ccsh starts at the prompt", r.out:find("p> PF=yes\n", 1, true) ~= nil, show(r.out))
r = sh("genv PF")
check("but not for -c or a script", r.out == "PF=nil\n", show(r.out))
W.files[".profile"] = nil
local opened, focus, title
W.multishell = { setFocus = function(id) focus = id end, getCurrent = function() return 3 end,
    setTitle = function(_, t) title = t end }
W.shell.openTab = function(...) opened = { ... }; return 3 end
r = sh([[export E=tabbed; fg genv E]])
check("fg prog: a new tab, shown, running ccsh to run it",
    opened and opened[1] == "/ccnix/bin/ccsh.lua" and opened[2] == "--spawn" and focus == 3 and r.status == 0,
    show(table.concat(opened or {}, " ")))
r = W:run("ccsh", "--spawn", opened[3])
check("there it runs with the environment, the tab named for it",
    r.out == "E=tabbed\n" and title == "genv" and rawget(_G, "CCSH_SPAWN") == nil, show(r.out))
focus, opened = nil, nil
r = sh([[bg genv E]])
check("bg prog: a tab left in the background", opened ~= nil and focus == nil)
r = W:run("ccsh", "--spawn", opened[3])
W.multishell, W.shell.openTab = nil, nil
r = sh([[fg genv; fg %1]])
check("no tabs (no multishell), or no such job: said, status 1",
    r.err[1] == "ccsh: fg: genv: no such job, and no tabs to run it in (multishell needs an advanced computer)"
    and r.err[2] == "ccsh: fg: %1: no such job" and r.status == 1, show(r.errText))

-- 17. history: /.ccsh_history, the last $HISTSIZE lines
W:file(".ccsh_history", "old one\nold two\n")
r = W:run("ccsh", { stdin = "echo a\necho a\n  \necho $HISTSIZE $HISTFILE\n" })
check("history: the file's lines come back at the prompt; typed lines are added (no repeats, no blank ones)",
    W.history and table.concat(W.history, "|") == "old one|old two|echo a|echo $HISTSIZE $HISTFILE"
        and W:read(".ccsh_history") == "old one\nold two\necho a\necho $HISTSIZE $HISTFILE\n"
        and r.out:find("1000 /.ccsh_history\n", 1, true) ~= nil,
    show(W:read(".ccsh_history")) .. " " .. show(r.out))
W:file(".profile", "HISTSIZE=3\n")
r = W:run("ccsh", { stdin = "echo b\n" })
check("HISTSIZE (here from /.profile) cuts the file when ccsh starts and leaves, and what read() is given",
    W:read(".ccsh_history") == "echo a\necho $HISTSIZE $HISTFILE\necho b\n"
        and table.concat(W.history, "|") == "echo a|echo $HISTSIZE $HISTFILE|echo b",
    show(W:read(".ccsh_history")) .. " / " .. table.concat(W.history, "|"))
local kept = W:read(".ccsh_history")
W:file(".profile", "unset HISTFILE\n")
r = W:run("ccsh", { stdin = "echo c\n" })
check("HISTFILE unset: no file kept", W:read(".ccsh_history") == kept, show(W:read(".ccsh_history")))
r = sh("echo d")
check("not for -c or a script", W:read(".ccsh_history") == kept)
W.files[".profile"], W.files[".ccsh_history"], W.history = nil, nil, nil

-- 16. compound commands: if, while, until, for, case, { }, ( ), functions
for _, u in ipairs({ "test", "expr", "seq", "sort" }) do W:install(u) end
W:file("ccnix/bin/cdto.lua", [[shell.setDir(shell.resolve(... or ""))]])
W:file("a.txt", "x")
r = sh([==[[ -f a.txt ]; echo $?; [ -d a.txt ]; echo $?; [ "" ]; echo $?; [ ]; echo $?; [ ] ]; echo $?
X=3; if [ "$X" -gt 2 ]; then echo big; fi; [ -f a.txt; echo $?]==])
check("[ ... ]: test, through the shell's own [; a missing ] is status 2",
    r.out == "0\n1\n1\n1\n0\nbig\n2\n" and r.err[1] == "[: missing ]",
    show(r.out) .. " " .. show(r.errText))
r = sh([==[[ a b c d e ]]==])
check("[ with test's errors", r.status == 2, show(r.errText))
W.files["a.txt"] = nil
r = sh([[if false; then echo a; elif true; then echo b; else echo c; fi; if false; then echo x; fi; echo "s=$?"
X=3; if test "$X" -gt 2; then echo big; else echo small; fi]])
check("if, elif, else; an if with nothing true is status 0; test as the condition", r.out == "b\ns=0\nbig\n", show(r.out))
r = sh([[i=0; while test $i -lt 3; do echo $i; i=$(expr $i + 1); done; until true; do echo no; done; echo "w=$?"]])
check("while counting with expr; until; a loop that never ran is status 0", r.out == "0\n1\n2\nw=0\n", show(r.out))
r = sh([[for x in a "b c" d; do echo "[$x]"; done; for i in $(seq 3); do echo $i; done]])
check("for: words as they're split and quoted, $(...)", r.out == "[a]\n[b c]\n[d]\n1\n2\n3\n", show(r.out))
r = sh([[for f in *.txt; do echo $f; done]], { cwd = "g" })
check("for over a glob", r.out == "a1.txt\na2.txt\nb.txt\n", show(r.out))
W.shell.setDir("")
r = W:run("ccsh", "-c", [[for a; do echo "<$a>"; done]], "name", "x", "y z")
check("for with no in: the arguments", r.out == "<x>\n<y z>\n", show(r.out))
r = sh([[for i in 1 2 3 4; do if test $i = 2; then continue; fi; if test $i = 4; then break; fi; echo $i; done
for a in 1 2; do for b in x y; do echo $a$b; break 2; done; done
for a in 1 2; do for b in x y; do echo $a$b; continue 2; done; echo never; done]])
check("break and continue, and break 2, continue 2 out of an inner loop", r.out == "1\n3\n1x\n1x\n2x\n", show(r.out))
r = sh([[for w in apple b.txt Zed other; do case $w in a*|Z*) echo "AZ $w";; *.txt) echo "txt $w";; *) echo "else $w";; esac; done
case '*' in "*") echo star;; esac; X='a*'; case abc in $X) echo glob;; esac; case abc in "$X") echo no;; esac
case x in (x) ;; esac; echo "e=$?"; case nothing in a) echo a;; esac; echo "n=$?"]])
check("case: | and globs, the first match; a quoted pattern is literal, an unquoted $X a glob; (pat); empty; no match 0",
    r.out == "AZ apple\ntxt b.txt\nAZ Zed\nelse other\nstar\nglob\ne=0\nn=0\n", show(r.out))
r = sh([[case '[ab]' in [ab]) echo set;; *) echo other;; esac; case b in [a-c]) echo range;; esac
case b in [a"-"c]) echo no;; *) echo "not a range";; esac; case - in [a"-"c]) echo dash;; esac
case '[a]' in "["a]) echo quoted;; esac; case a in "["a]) echo no;; *) echo plain;; esac
case 'a?' in a\?) echo escaped;; esac; case ab in a\?) echo no;; *) echo literal;; esac]])
check("case: a glob doesn't also match its own text; quoted [ ? and - are themselves (in a bracket too: [a\"-\"c] is a, - or c)",
    r.out == "other\nrange\nnot a range\ndash\nquoted\nplain\nescaped\nliteral\n", show(r.out))
r = sh([[greet() { echo "hi $1 ($#)"; }; greet bob; greet "a b" c; f() { return 3; echo no; }; f; echo $?
x=1; g() { local x=2; echo "in $x"; }; g; echo "out $x"
c() { if test $1 -gt 0; then echo $1; c $(expr $1 - 1); fi; }; c 3
function k { echo k; }; k; s() { echo b; echo a; }; s | sort]])
check("functions: arguments and $#, return n, local, recursion, the function keyword, piped",
    r.out == "hi bob (1)\nhi a b (2)\n3\nin 2\nout 1\n3\n2\n1\nk\na\nb\n", show(r.out))
r = W:run("ccsh", "-c", [[f() { echo "f $1"; }; f in; echo "after $1"]], "name", "out")
check("a function's arguments are its own: $1 is back after", r.out == "f in\nafter out\n", show(r.out))
r = sh([[w() { echo inside; } > ff.txt; w; w; cat ff.txt; echo hi > m2.txt
for i in 3 1 2; do echo $i; done | sort; { echo a; echo b; } > g.txt; cat g.txt
while read l; do echo "<$l>"; done < m2.txt; printf 'x\ny\n' | while read l; do echo "$l!"; done
{ cat nope; } 2> e2.txt; cat e2.txt]])
check("redirects on a definition, a for in a pipe, { } to a file, while read from a file and from a pipe, 2> on { }",
    r.out == "inside\n1\n2\n3\na\nb\n<hi>\nx!\ny!\ncat: nope: No such file or directory\n" and W:read("ff.txt") == "inside\n",
    show(r.out))
r = sh([[X=1; (X=2; echo $X); echo $X; (exit 3); echo $?; (cdto g; echo $PWD); echo $PWD
Y=$(X=5; echo $X); echo "$X $Y"; (f() { echo sub; }; f); f 2>/dev/null; echo $?]])
check("( ): its own variables, exit, directory and functions; $(...) is a subshell too",
    r.out == "2\n1\n3\n/g\n/\n1 5\nsub\n127\n", show(r.out))
r = W:run("ccsh", { stdin = "for i in 1 2\ndo echo $i\ndone\nif true\nthen echo yes; fi\n" })
check("at the prompt, a for or if goes on to the next line until it's done",
    r.out:find("/$ > > 1\n2\n", 1, true) ~= nil and r.out:find("/$ > yes\n", 1, true) ~= nil, show(r.out))
check("syntax: fi twice", synErr("if true; then :; fi fi", "unexpected fi"))
check("syntax: a for's bad name", synErr("for 1x in a; do :; done", "for: bad name 1x"))
check("syntax: case without esac", synErr("case x in a) echo;;", "unexpected end of line (esac missing)"))
check("syntax: a function's body must be compound", synErr("f() echo", "a function's body is { ... } or another compound command"))
r = sh([[while true; do :; done; echo never]], { events = { { "terminate" } } })
check("a loop of builtins alone still sees Ctrl+T (status 130, the rest of the line skipped)",
    r.status == 130 and r.out == "", show(r.out) .. " " .. r.status)
r = sh([[break; return; echo after]])
check("break outside a loop, return outside a function: said, and the line goes on",
    r.out == "after\n" and r.err[1] == "ccsh: break: only meaningful in a loop"
        and r.err[2] == "ccsh: return: only in a function or a . file", show(r.errText))

-- 15. nothing left behind
check("after: the screen, io, printing globals, POSIX_SH and os.getenv are as they were",
    term.current() == term.native() and W.io.output() == W.io.stdout and W.io.input() == W.io.stdin
    and rawget(_G, "write") == nil and _G.POSIX_SH == nil and rawget(W.os, "getenv") == nil
    and rawget(W.os, "setenv") == nil and rawget(W.os, "environ") == nil)
r = W:run("echo", "a", ">", "z.txt")
check("echo on its own still does > (no shell to)", W:read("z.txt") == "a\n")

-- 18. Tab completion: a file or directory name for an argument the stock
-- shell has none for, after a pipe or a redirect, in quotes; not the
-- command's own name, a glob or a variable
W:file("notes.txt", "") W:file("nodir/x", "") W:file(".nohide", "")
W.completer = nil
W:run("ccsh", { stdin = "echo hi\n" })
local function comp(line)
    local got = W.completer and W.completer(line)
    if not got then return "nil" end
    table.sort(got)
    return table.concat(got, ",")
end
check("Tab: an argument's file and directory names (a directory with / and without; hidden only after a dot)",
    comp("cat no") == "dir,dir/,tes.txt" and comp("cat .no") == "hide", comp("cat no") .. " " .. comp("cat .no"))
check("Tab: after a pipe and a redirect, inside a quote, in a directory",
    comp("echo a | grep x > not") == "es.txt" and comp("cat 'not") == "es.txt" and comp("ls nodir/") == "x",
    comp("echo a | grep x > not") .. " " .. comp("cat 'not") .. " " .. comp("ls nodir/"))
check("Tab: not the command's own name (that's the stock shell's), nor a glob or $X",
    comp("no") == "nil" and comp("cat no*") == "nil" and comp("cat $no") == "nil")
W.files["notes.txt"], W.files[".nohide"] = nil, nil
W.fs.delete("nodir")

--------------------------------------------------------------------------
-- set (POSIX's special builtin): positional parameters, options, $-
--------------------------------------------------------------------------
r = sh([[set -- a 'b c'; args "$#" "$@"; set x; args $#; set --; args "$#"; set -e; args $# "$-"]])
check("set -- and set word: the positional parameters; set -- alone clears them; an option alone keeps them",
    r.out == "[2][a][b c]\n[1]\n[0]\n[0][e]\n", show(r.out))
r = sh([[B=2; A='it''s'; set]])
check("set alone: the variables, sorted, quoted to read back in", r.out:find("A='its'\nB='2'\n", 1, true) ~= nil, show(r.out))
r = sh([[set -e; true; false; echo no]])
check("set -e: a failing command ends the shell with its status", r.out == "" and r.status == 1, show(r.out))
r = sh([[set -e; if false; then :; fi; while false; do :; done; false || true; false && true; ! true; echo yes; f() { false; echo in; }; f; echo no]])
check("set -e: not in a condition, before && or ||, after !; in a function it ends there",
    r.out == "yes\n" and r.status == 1, show(r.out) .. " " .. r.status)
r = sh([[set -u; echo "${U-ok}" "$#" "$@"; echo $U; echo no]])
check("set -u: an unset variable is an error (not ${U-word}, $# or $@)", r.out == "ok 0\n" and r.status == 1
    and r.err[1] == "ccsh: U: parameter not set", show(r.out) .. " " .. show(r.errText))
W:file("gf1.txt", "") W:file("gf2.txt", "")
r = sh([[set -f; args gf*.txt; set +f; args gf*.txt]])
check("set -f: no globbing; +f back on", r.out == "[gf*.txt]\n[gf1.txt][gf2.txt]\n", show(r.out))
W.fs.delete("gf1.txt") W.fs.delete("gf2.txt")
r = sh([[set -x; X=1 args a 'b c'; set +x; args d]])
check("set -x: each command on stderr after +, quoted to read back in", r.out == "[a][b c]\n[d]\n"
    and r.err[1] == "+ X=1 args a 'b c'" and r.err[2] == "+ set +x" and #r.err == 2, show(r.errText))
r = sh([[set -o errexit -o nounset; echo "$-"; set -o; set +o; set +eu -o xtrace; set +x; echo "$-"]])
check("set -o name, set -o and +o to see them (+o as commands), $- the letters",
    r.out == "eu\nerrexit         on\nnoglob          off\nnounset         on\nxtrace          off\n"
        .. "set -o errexit\nset +o noglob\nset -o nounset\nset +o xtrace\n\n", show(r.out))
r = sh([[set -v; echo $?; set -q; echo $?; set -o nope; echo $?]])
check("options not here yet, and ones POSIX hasn't: refused, status 2", r.out == "2\n2\n2\n"
    and r.err[1] == "ccsh: set: -v (verbose) isn't supported yet" and r.err[2] == "ccsh: set: -q: bad option"
    and r.err[3] == "ccsh: set: nope: no such option", show(r.errText))
r = sh([[set() { echo mine; }; set -- a; echo "$1"]])
check("set is special: a function can't hide it", r.out == "a\n", show(r.out))
r = sh([[args a "$@" b; set -- x; args "$@" "${@}"]])
check("\"$@\" with no positional parameters: no field at all, not an empty one", r.out == "[a][b]\n[x][x]\n", show(r.out))
