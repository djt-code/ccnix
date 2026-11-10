-- sim/coreutils_test.lua
--
-- test and expr in a shellworld: every primary, the POSIX rules by
-- argument count, -a/-o/!/( ), test through the stock shell, and
-- expr's operators, results and exit statuses.
local PROJ = ...
package.path = PROJ .. "/lib/?.lua;" .. PROJ .. "/sim/lib/?.lua;" .. package.path
local M = require("mock")
local SW = require("shellworld")
local check = M.check

local W = SW.new(PROJ)
W:file("a.txt", "hello\n")
W:file("empty.txt", "")
W:file("prog", "print(1)")
W:file("notes.md", "x")
W:dir("sub")
W:install("test")

-- status of test with these arguments (nil if it crashed)
local function T(...)
    local r = W:run("test", ...)
    if not r.ok then return "crash: " .. tostring(r.error) end
    return r.status, r
end
local function is(name, want, ...)
    local got, r = T(...)
    check(name, got == want and r.out == "", "got " .. tostring(got) .. " " .. (r and r.errText or ""))
end

--------------------------------------------------------------------------
-- 1. test: argument counts
--------------------------------------------------------------------------
is("no arguments: false", 1)
is("one argument: true if not empty", 0, "x")
is("one empty argument: false", 1, "")
is("one argument that looks like a primary: -n alone is true", 0, "-n")
is("! alone is a non-empty string: true", 0, "!")
is("two: ! negates the one-argument test", 1, "!", "x")
is("two: ! of empty is true", 0, "!", "")
local s, r = T("-q", "x")
check("two: unknown unary is an error, status 2", s == 2 and r.err[1] == "test: -q: unary operator expected", r and r.errText)
is("three: binary primary wins (! = !)", 0, "!", "=", "!")
is("three: ! negates two-argument test", 0, "!", "-z", "x")
is("three: ( x ) is the one-argument test", 0, "(", "x", ")")
is("four: ! negates the three-argument test", 0, "!", "a", "=", "b")
is("four: ( -n x ) is the two-argument test", 0, "(", "-n", "x", ")")

--------------------------------------------------------------------------
-- 2. test: file primaries
--------------------------------------------------------------------------
is("-e file", 0, "-e", "a.txt")
is("-e directory", 0, "-e", "sub")
is("-e missing", 1, "-e", "nope")
is("-f file", 0, "-f", "a.txt")
is("-f directory is false", 1, "-f", "sub")
is("-d directory", 0, "-d", "sub")
is("-d file is false", 1, "-d", "a.txt")
is("-s non-empty file", 0, "-s", "a.txt")
is("-s empty file is false", 1, "-s", "empty.txt")
is("-s missing is false", 1, "-s", "nope")
is("-r existing", 0, "-r", "a.txt")
is("-r missing", 1, "-r", "nope")
is("-w file", 0, "-w", "a.txt")
is("-w rom is false", 1, "-w", "/rom/programs/list.lua")
is("-x directory", 0, "-x", "sub")
is("-x a .lua program", 0, "-x", "/rom/programs/list.lua")
is("-x a file with no extension", 0, "-x", "prog")
is("-x a .txt file is false", 1, "-x", "a.txt")
is("-x missing is false", 1, "-x", "nope")
is("-b/-c/-p/-S/-h/-L are false", 1, "-L", "a.txt")
is("a path above the root is just missing", 1, "-e", "../../x")
is("-e of an empty path is false (not the current folder)", 1, "-e", "")
is("-d of an empty path is false", 1, "-d", "")
W.shell.setDir("sub")
is("paths are relative to the shell's directory", 0, "-f", "../a.txt")
W.shell.setDir("")
r = W:run("test", "-t", "1")
local r2 = W:run("test", "-t", "1", { pipeOut = true })
check("-t 1: the screen is a terminal, a pipe is not", r.status == 0 and r2.status == 1)
r = W:run("test", "-t", "0", { pipeIn = true })
check("-t 0: piped input is not the keyboard", r.status == 1)
s, r = T("-t", "x")
check("-t x: not a number, status 2", s == 2 and r.err[1] == "test: x: integer expression expected", r and r.errText)

-- -nt / -ot / -ef
W:advance(10)
W:file("new.txt", "n")
is("new -nt old", 0, "new.txt", "-nt", "a.txt")
is("old -nt new is false", 1, "a.txt", "-nt", "new.txt")
is("existing -nt missing", 0, "a.txt", "-nt", "nope")
is("old -ot new", 0, "a.txt", "-ot", "new.txt")
is("missing -ot existing", 0, "nope", "-ot", "a.txt")
is("-ef: the same file by two paths", 0, "a.txt", "-ef", "sub/../a.txt")
is("-ef: different files", 1, "a.txt", "-ef", "new.txt")

--------------------------------------------------------------------------
-- 3. test: strings and integers
--------------------------------------------------------------------------
is("-n non-empty", 0, "-n", "x")
is("-n empty", 1, "-n", "")
is("-z empty", 0, "-z", "")
is("-z non-empty", 1, "-z", "x")
is("= equal", 0, "abc", "=", "abc")
is("= differ", 1, "abc", "=", "abd")
is("!= differ", 0, "a", "!=", "b")
is("< byte order", 0, "abc", "<", "abd")
is("> byte order", 1, "abc", ">", "abd")
is("-eq numeric (010 = 10)", 0, "010", "-eq", "10")
is("-ne", 0, "1", "-ne", "2")
is("-lt negative", 0, "-5", "-lt", "3")
is("-le equal", 0, "3", "-le", "3")
is("-gt", 1, "3", "-gt", "3")
is("-ge", 0, "+4", "-ge", "3")
s, r = T("a", "-eq", "1")
check("-eq with a non-integer: status 2 and a message", s == 2 and r.err[1] == "test: a: integer expression expected", r and r.errText)
is("= with an empty side", 1, "", "=", "x")
is("-eq past 2^53 compares exactly", 1, "99999999999999999999", "-eq", "99999999999999999998")
is("-gt past 2^53", 0, "9007199254740993", "-gt", "9007199254740992")
is("-lt between negatives", 0, "-10", "-lt", "-9")
is("-eq: -0 equals +000", 0, "-0", "-eq", "+000")

--------------------------------------------------------------------------
-- 4. test: !, -a, -o, ( )
--------------------------------------------------------------------------
is("-a both true", 0, "-n", "x", "-a", "-f", "a.txt")
is("-a one false", 1, "-n", "x", "-a", "-f", "nope")
is("-o one true", 0, "-f", "nope", "-o", "-d", "sub")
is("-a binds tighter than -o", 0, "x", "-o", "", "-a", "")
is("! binds tighter than -a", 0, "!", "-f", "nope", "-a", "-d", "sub")
is("parentheses group", 1, "(", "x", "-o", "", ")", "-a", "")
is("three: s -a s", 0, "x", "-a", "y")
is("three: s -o empty", 0, "x", "-o", "")
s, r = T("(", "x", "-a", "y")
check("missing ): status 2", s == 2 and r.err[1] == "test: missing )", r and r.errText)
s, r = T("a", "b", "c", "d", "e")
check("junk: status 2", s == 2 and r.err[1] == "test: b: unexpected argument", r and r.errText)

--------------------------------------------------------------------------
-- 5. test through the shell ([ is ccsh's: sim/ccsh.lua)
--------------------------------------------------------------------------
r = W:sh("test ]")
check("test ] is a one-argument test: true", r.status == 0)
r = W:sh("test ! ]")
check("test ! ] is false", r.status == 1)
r = W:sh('test "hello world" = "hello world"')
check("quoted strings through the shell", r.status == 0)

--------------------------------------------------------------------------
-- 6. expr
--------------------------------------------------------------------------
local function E(...)
    local r = W:run("expr", ...)
    return r.out, r.status, r
end
local function ex(name, out, status, ...)
    local o, st, r = E(...)
    check(name, o == out and st == status, ("got %q status %s %s"):format(o, tostring(st), r.errText))
end
ex("addition", "3\n", 0, "1", "+", "2")
ex("a + sign: still an integer (scan.isInteger)", "6\n", 0, "+5", "+", "1")
ex("+0 is zero", "0\n", 1, "+0", "&", "x")
ex("subtraction to zero: status 1", "0\n", 1, "5", "-", "5")
ex("precedence: * before +", "7\n", 0, "1", "+", "2", "*", "3")
ex("parentheses", "9\n", 0, "(", "1", "+", "2", ")", "*", "3")
ex("left-associative -", "5\n", 0, "10", "-", "3", "-", "2")
ex("division truncates toward zero", "-3\n", 0, "-7", "/", "2")
ex("remainder has the dividend's sign", "-1\n", 0, "-7", "%", "2")
ex("leading zeros", "8\n", 0, "007", "+", "1")
ex("negative operand after --", "1\n", 0, "--", "-1", "+", "2")
ex("integer comparison", "1\n", 0, "10", ">", "9")
ex("string comparison", "0\n", 1, "10", ">", "9a")
ex("= numeric", "1\n", 0, "01", "=", "1")
ex("!= strings", "1\n", 0, "a", "!=", "b")
ex("<= and >=", "1\n", 0, "3", "<=", "3")
ex("| returns the first if non-zero", "a\n", 0, "a", "|", "b")
ex("| falls to the second", "b\n", 0, "0", "|", "b")
ex("| both empty gives 0", "0\n", 1, "", "|", "")
ex("| a zero second operand gives 0", "0\n", 1, "0", "|", "00")
ex("= past 2^53 compares exactly", "0\n", 1, "99999999999999999999", "=", "99999999999999999998")
ex("-4 % 2 is 0", "0\n", 1, "-4", "%", "2")
ex("7 / -2 truncates", "-3\n", 0, "7", "/", "-2")
local o, st, rr = E("99999999999999999999", "+", "1")
check("arithmetic past 2^53: status 2, not a crash", rr.ok and st == 2 and o == "", rr.errText)
o, st, rr = E("4503599627370496", "*", "4")
check("a result past 2^53: status 2", rr.ok and st == 2 and rr.err[1] == "expr: result out of range", rr.errText)
ex("& returns the first", "a\n", 0, "a", "&", "b")
ex("& with a zero gives 0", "0\n", 1, "a", "&", "0")
ex("a lone string", "hello\n", 0, "hello")
ex("an empty string: status 1", "\n", 1, "")
ex("a lone operator is a string", "*\n", 0, "*")
o, st, rr = E("1", "+", "a")
check("non-integer argument: status 2", st == 2 and o == "" and rr.err[1] == "expr: non-integer argument", rr.errText)
o, st, rr = E("1", "/", "0")
check("division by zero: status 2", st == 2 and rr.err[1] == "expr: division by zero", rr.errText)
o, st, rr = E("1", "+")
check("missing operand: syntax error, status 2", st == 2 and rr.err[1] == "expr: syntax error", rr.errText)
o, st, rr = E("(", "1", "+", "2")
check("missing ): syntax error", st == 2 and rr.err[1] == "expr: syntax error", rr.errText)
o, st, rr = E("1", "2")
check("two operands: syntax error", st == 2)
o, st, rr = E()
check("no arguments: usage, status 2", st == 2 and rr.err[1] == "expr: missing operand"
    and rr.err[2] == "usage: expr operand...", rr.errText)
ex(": counts the bytes matched", "3\n", 0, "abcdef", ":", "a.c")
ex(": is anchored at the start", "0\n", 1, "xabc", ":", "abc")
ex(": a leading ^ is the same anchor", "2\n", 0, "abc", ":", "^ab")
ex(": longest match with *", "6\n", 0, "aaaaaa", ":", "a*")
ex(": a \\( \\) group returns its text", "def\n", 0, "abc.def", ":", "abc\\.\\(.*\\)")
ex(": a group that fails gives the empty string", "\n", 1, "abc", ":", "x\\(.*\\)")
ex(": binds tighter than +", "4\n", 0, "abc", ":", "a.*", "+", "1")
ex(": on a number's text", "2\n", 0, "42", ":", "[0-9]*")
o, st, rr = E("abc", ":", "a\\(")
check(": a bad regex: status 2 and a message", st == 2 and rr.err[1] ~= nil, rr.errText)
o, st, rr = W:run("expr", "6", "*", "7", { pipeOut = true }).out, nil, nil
check("output goes to io.output (a pipe)", o == "42\n")
r = W:sh("expr 2 * 21")
check("through the shell: * is not a glob", r.out == "42\n" and r.status == 0)
