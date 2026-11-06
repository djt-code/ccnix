-- procrun.lua -- how init's kernel (lib/proc.lua) runs a command line
--
--   rom/programs/shell.lua "/ccnix/lib/procrun" telnetd -p 23
--
-- Not a program to type: the kernel runs each command in a CraftOS shell
-- of its own with this in front of it.  The shell splits the line into
-- words as it always does (this name first), and this runs the rest of
-- the words with shell.execute: the same as shell.run(command line), but
-- what the shell's run says is kept.  The shell catches a program's
-- error itself (it prints it, then carries on), so without this a program
-- that crashed would end as if all went well.  One that failed (an error,
-- Ctrl+T, a syntax error, no such program) and left _G.POSIX_STATUS at 0
-- or unset ends with status 1; one that set its own (cu.exit, ccsh)
-- keeps it.  The kernel finds the error itself (see lib/proc.lua).

_G.POSIX_STATUS = nil
local words = table.pack(...)
if words.n == 0 then return end
local ok = shell.execute(table.unpack(words, 1, words.n))
local status = rawget(_G, "POSIX_STATUS")
if not ok and (type(status) ~= "number" or status == 0) then _G.POSIX_STATUS = 1 end
