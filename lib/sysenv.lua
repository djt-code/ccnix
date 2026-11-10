-- sysenv.lua -- what a program asks of the computer it runs on
--
--   local sysenv = require("sysenv")
--   local api = sysenv.envApi({ HOME = "/" })    -- getenv, setenv, environ over a table
--   local saved = sysenv.swapEnv(api)            -- in os while a command runs ...
--   sysenv.swapEnv(saved)                        -- ... and the old ones back
--   sysenv.hostname()                            --> "miner", or "7" with no label
--   sysenv.findProgram("bin/ccsh")               --> "/ccnix/bin/ccsh", or nil
--   sysenv.setting("telnetd.port", 23)           -- a number setting, 23 if unset
--
-- The few things the shell (ccsh, which runs without init) and init's
-- kernel (lib/proc) both need, and the daemons with them, in one place
-- each.  It sits on lib/tables and lib/convert.
--
-- The environment.  CraftOS has none; ccsh and lib/proc give each
-- command its own table of NAME = value strings, and put these three
-- functions over it in os while the command runs:
--   sysenv.envApi(env)     { getenv, setenv, environ } over the table env:
--                          os.getenv(name) its value (nil if unset; an error
--                          if name isn't a string), os.setenv(name, value)
--                          (tostring'd; nil unsets it; an error for a name
--                          that's empty or has "=" in it), os.environ() a
--                          copy of the table
--   sysenv.swapEnv(api [, osT])  put api's three in os (osT) and return the
--                          ones that were there, as a table of the same
--                          shape: swapEnv(saved) puts them back
--
-- The computer:
--   sysenv.hostname([osT])      its label, or its ID (as a string) when it
--                          has none (an empty label is none): $HOSTNAME, the
--                          system log's host, \h in ccsh's prompt
--   sysenv.computerName([osT])  its label, or "computer <ID>": for showing
--                          to a person (telnetd's login, a fileserver
--                          disk's label)
--
-- ccnix's programs:
--   sysenv.repoRoot([shellT])   the checkout the running program is in:
--                          the folder above its own (/ccnix for
--                          /ccnix/bin/ls.lua)
--   sysenv.findProgram(rel [, shellT])  the program at rel in ccnix ("bin/ccsh",
--                          without .lua): ccnix's own (ccnix.find: the ROM
--                          or the /ccnix overlay), else the one in the
--                          checkout beside the running program; its path
--                          without .lua, as it's run; nil if neither has it
--
-- Settings:
--   sysenv.setting(name [, default [, least]])  setting name as a number: a
--                          number, or a string that is one (convert's
--                          toNumber); default when it's unset, anything
--                          else, or below least

local tables = require("tables")
local convert = require("convert")
local text = require("text")

local sysenv = {}

--------------------------------------------------------------------------
-- The environment
--------------------------------------------------------------------------

function sysenv.envApi(env)
    return {
        getenv = function(name)
            if type(name) ~= "string" then error("bad argument #1 (string expected, got " .. type(name) .. ")", 2) end
            return env[name]
        end,
        setenv = function(name, value)
            if type(name) ~= "string" or name == "" or text.contains(name, "=") then error("bad argument #1 (a name expected)", 2) end
            env[name] = value ~= nil and tostring(value) or nil
        end,
        environ = function() return tables.copy(env) end,
    }
end

local ENV_FUNCTIONS = { "getenv", "setenv", "environ" }

function sysenv.swapEnv(api, osT)
    osT = osT or os
    local was = {}
    for _, name in ipairs(ENV_FUNCTIONS) do
        was[name] = rawget(osT, name)
        osT[name] = api[name]
    end
    return was
end

--------------------------------------------------------------------------
-- The computer
--------------------------------------------------------------------------

-- its label, nil if it has none (or an empty one)
local function labelOf(osT)
    local label = osT.getComputerLabel and osT.getComputerLabel()
    if label ~= "" then return label end
end

local function idOf(osT)
    return tostring(osT.getComputerID and osT.getComputerID() or 0)
end

function sysenv.hostname(osT)
    osT = osT or os
    return labelOf(osT) or idOf(osT)
end

function sysenv.computerName(osT)
    osT = osT or os
    return labelOf(osT) or ("computer " .. idOf(osT))
end

--------------------------------------------------------------------------
-- ccnix's programs
--------------------------------------------------------------------------

function sysenv.repoRoot(shellT)
    shellT = shellT or shell
    return "/" .. fs.getDir(fs.getDir(shellT.getRunningProgram()))
end

function sysenv.findProgram(rel, shellT)
    local found = ccnix and ccnix.find and ccnix.find(rel .. ".lua")
    if not found then
        shellT = shellT or shell
        if not (shellT and shellT.getRunningProgram) then return nil end
        local beside = sysenv.repoRoot(shellT) .. "/" .. rel .. ".lua"
        found = fs.exists(beside) and beside or nil
    end
    if not found then return nil end
    return text.stripSuffix(found, ".lua") or found
end

--------------------------------------------------------------------------
-- Settings
--------------------------------------------------------------------------

function sysenv.setting(name, default, least)
    local v = settings.get(name)
    if type(v) == "string" then v = convert.toNumber(v) end
    if type(v) ~= "number" or v ~= v or (least and v < least) then return default end
    return v
end

return sysenv
