-- getopt.lua -- command-line options, the POSIX way, with long ones too
--
--   local getopt = require("getopt")
--   local opts, operands = getopt.parse({ "-vn", "3", "--output=x", "a" }, "vn:",
--       { output = "o", verbose = "v", ["max-time"] = "=" })
--   -- opts.v = true, opts.n = "3", opts.o = "x"; operands = { "a" }
--
-- getopt.parse(args, spec [, long]) reads the options at the front of
-- args and returns
--   opts       each option given: opts.v = true for a flag, the argument
--              string for one that takes one (the last given wins)
--   operands   the args after the options
--   order      every option in the order given, as { name, value }
-- or nil and a message ("illegal option -- x", "option requires an
-- argument -- n", "unrecognized option '--foo'") when args are wrong.
--
-- spec is the short options, POSIX getopt's: each letter, followed by a
-- colon when it takes an argument ("vn:" is -v, and -n with one).
-- Flags can share a dash (-vn 3), and the argument can follow its
-- letter (-n3) or be the next arg (-n 3).
--
-- long, if given, names the long options:
--   name = "x"    --name is the same as -x (x a letter in spec)
--   name = true   --name is a flag of its own:          opts.name = true
--   name = "="    --name takes an argument of its own:  opts.name = "..."
-- and an argument comes after = (--name=value) or as the next arg.
--
-- The options end at "--" (stepped over), at "-" alone and at the first
-- arg not starting with "-": everything from there is an operand.

local getopt = {}

-- spec ("vn:") as { letter = takesArgument }
local function readSpec(spec)
    local takes = {}
    for k = 1, #spec do
        local c = spec:sub(k, k)
        if c ~= ":" then takes[c] = spec:sub(k + 1, k + 1) == ":" end
    end
    return takes
end

-- "--name" or "--name=value": the name and the value (nil without =)
local function readLong(a)
    local body = a:sub(3)
    local eq = body:find("=", 1, true)
    if not eq then return body, nil end
    return body:sub(1, eq - 1), body:sub(eq + 1)
end

function getopt.parse(args, spec, long)
    local takes, opts, order = readSpec(spec), {}, {}
    long = long or {}
    local i = 1
    local function give(name, value)
        opts[name] = value
        order[#order + 1] = { name, value }
    end
    -- the argument for an option: inline, or the next arg
    local function argument(inline, missing)
        if inline then return inline end
        i = i + 1
        if args[i] == nil then return nil, missing end
        return args[i]
    end

    while i <= #args do
        local a = args[i]
        if a == "--" then i = i + 1; break end
        if a:sub(1, 1) ~= "-" or a == "-" then break end
        if a:sub(1, 2) == "--" then
            local name, inline = readLong(a)
            local kind = long[name]
            if kind == nil then return nil, "unrecognized option '--" .. name .. "'" end
            local key = kind
            if kind == true or kind == "=" then key = name end
            local wants = kind == "=" or (takes[key] == true)
            if wants then
                local v, err = argument(inline, "option '--" .. name .. "' requires an argument")
                if not v then return nil, err end
                give(key, v)
            elseif inline then
                return nil, "option '--" .. name .. "' doesn't allow an argument"
            else
                give(key, true)
            end
        else
            local j = 2
            while j <= #a do
                local c = a:sub(j, j)
                if takes[c] == nil then return nil, "illegal option -- " .. c end
                if takes[c] then
                    local rest = a:sub(j + 1)
                    local v, err = argument(rest ~= "" and rest or nil, "option requires an argument -- " .. c)
                    if not v then return nil, err end
                    give(c, v)
                    break
                end
                give(c, true)
                j = j + 1
            end
        end
        i = i + 1
    end

    local operands = {}
    for k = i, #args do operands[#operands + 1] = args[k] end
    return opts, operands, order
end

return getopt
