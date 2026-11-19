-- home.lua -- send the turtle back to its job's start position
--
-- Both mow and farm save the turtle's position after every move.  If a job
-- was stopped with Ctrl+T (or the server restarted) run `home` and the
-- turtle navigates back to where it started, using the same stepping mode
-- the job used.  `mow reset` and `farm reset` do the same thing.  With GPS
-- it heads home from where GPS puts it, when the saved position is up to
-- 16 blocks off or was lost; farther, it stays put and says why.

package.path = (ccnix and ccnix.lib or "") .. package.path    -- (ccnix's turtlelib, the updates' first)
local T = require("turtlelib")
T.goHome()
