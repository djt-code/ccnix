-- The terrain fixtures sim/mine_terrain.lua runs mine through: boxes of the
-- dev server's world (sim/terrain.py), x -4..8, y -4..8, z 1..50 round a 5x5
-- tunnel 48 long, homes every 16.
return {
    -- rock, then open sea from z=19 on (the floor at the seabed): open-water mode
    { name = "sea", file = "sea.lua", args = { "5", "5", "48", "--spacing", "16", "--no-lights" } },
    -- rich in ore, a little water: veins, with a scanner
    { name = "ore", file = "ore.lua", scanner = true, args = { "5", "5", "48", "--spacing", "16", "--no-lights" } },
    -- an aquifer's pockets of water among ore
    { name = "aquifer", file = "aquifer.lua", args = { "5", "5", "48", "--spacing", "16", "--no-lights" } },
    -- deep, in deepslate: caves, flowing water, diamond, with a scanner
    { name = "caves", file = "caves.lua", scanner = true, args = { "5", "5", "48", "--spacing", "16", "--no-lights" } },
}
