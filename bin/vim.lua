-- vim.lua -- vi with colours: syntax highlighting for Lua and ccsh scripts
--
--   vim [-R] [+line | +/pattern | +] [file...]
--
-- The vi editor (`help vi` has its commands), and on an Advanced Computer
-- (or any colour screen: an advanced turtle or pocket computer, a telnet
-- session) it colours the text:
--   Lua    keywords yellow, strings red, comments green, numbers and
--          nil/true/false magenta, the standard and CraftOS libraries cyan
--   ccsh   reserved words yellow, builtins cyan, $variables and NAME=
--          light blue, strings red, comments green, | & ; < > orange
-- Line numbers (:set nu) are yellow, and :set hlsearch marks the last
-- search's matches (:noh hides them until the next search).
--
-- Which language: a #! line naming lua or a shell, then the name: .lua;
-- .sh, .ccsh and /.profile are ccsh; a name with no extension is a
-- CraftOS program, so Lua.  :set ft=lua, :set ft=sh or :set ft=off says
-- otherwise; :syntax off and :syntax on turn the colours off and on.  On a
-- screen without colours it's vi.  At start the ex commands in /.vimrc
-- are run (or /.exrc if there's no /.vimrc).
--
-- This is ccnix's own vi, written from vi's documented behaviour; it
-- isn't Vim (by Bram Moolenaar and the Vim team) and has none of its code.
-- Its messages (the E-numbered errors, "-- INSERT --", '"file" 3L, 42B
-- written' and the like) use Vim's wording, so they read as Vim users
-- expect.

package.path = (ccnix and ccnix.lib or "/" .. fs.getDir(fs.getDir(shell.getRunningProgram())) .. "/lib/?.lua;") .. package.path  -- ccnix's lib/, or the one beside bin/
require("vi").main({ ... }, { vim = true })
