"""sim/terrain.py -- real Minecraft terrain for the mine sims.

Reads a box of blocks out of a Minecraft world save (Anvil region files,
1.18 and later) and writes it as a Lua fixture the sims load with
Mine.terrain(path): what's in front of a turtle standing at a given spot,
facing a given way, in the tunnel's own coordinates (x to the turtle's
right, y up, z ahead; the turtle at 0,0,0).  Nothing of the world but the
blocks goes in the fixture: no world name, no coordinates.

    python sim/terrain.py WORLD --at=X,Y,Z --facing south \
        --box=-4,8,-4,8,1,48 --out sim/terrain/lake.lua

(--at= and --box= with the equals sign: a leading minus would read as an
option.)

    python sim/terrain.py WORLD --find --facing south --y 40 --size 5,5,48

--find looks along the world's loaded chunks for a run of tunnel
(--size: width, height, length, from the turtle's spot at height --y)
with water and ore in it, and prints the best spots to --at.

Standard library only.
"""
import argparse
import math
import os
import struct
import sys
import zlib

# ---------------------------------------------------------------------------
# NBT
# ---------------------------------------------------------------------------
END, BYTE, SHORT, INT, LONG, FLOAT, DOUBLE, BYTES, STRING, LIST, COMPOUND, INTS, LONGS = range(13)


class Reader:
    def __init__(self, data):
        self.data, self.pos = data, 0

    def take(self, fmt):
        size = struct.calcsize(fmt)
        value = struct.unpack_from(fmt, self.data, self.pos)
        self.pos += size
        return value

    def string(self):
        (n,) = self.take(">H")
        s = self.data[self.pos:self.pos + n].decode("utf-8", "replace")
        self.pos += n
        return s

    def payload(self, tag):
        if tag == BYTE:
            return self.take(">b")[0]
        if tag == SHORT:
            return self.take(">h")[0]
        if tag == INT:
            return self.take(">i")[0]
        if tag == LONG:
            return self.take(">q")[0]
        if tag == FLOAT:
            return self.take(">f")[0]
        if tag == DOUBLE:
            return self.take(">d")[0]
        if tag == BYTES:
            (n,) = self.take(">i")
            v = self.data[self.pos:self.pos + n]
            self.pos += n
            return v
        if tag == STRING:
            return self.string()
        if tag == LIST:
            inner, n = self.take(">bi")
            return [self.payload(inner) for _ in range(n)]
        if tag == COMPOUND:
            out = {}
            while True:
                (t,) = self.take(">b")
                if t == END:
                    return out
                name = self.string()
                out[name] = self.payload(t)
        if tag == INTS:
            (n,) = self.take(">i")
            return list(self.take(">%di" % n))
        if tag == LONGS:
            (n,) = self.take(">i")
            return list(self.take(">%dq" % n))
        raise ValueError("unknown NBT tag %d" % tag)

    def root(self):
        (t,) = self.take(">b")
        self.string()
        return self.payload(t)


# ---------------------------------------------------------------------------
# Region files and chunks
# ---------------------------------------------------------------------------
class World:
    def __init__(self, path):
        self.dir = os.path.join(path, "region")
        if not os.path.isdir(self.dir):
            sys.exit("no region folder in " + path)
        self.regions, self.sections = {}, {}

    def region(self, rx, rz):
        key = (rx, rz)
        if key not in self.regions:
            path = os.path.join(self.dir, "r.%d.%d.mca" % (rx, rz))
            self.regions[key] = open(path, "rb").read() if os.path.exists(path) else None
        return self.regions[key]

    def chunk(self, cx, cz):
        data = self.region(cx >> 5, cz >> 5)
        if not data or len(data) < 8192:
            return None
        i = 4 * ((cx & 31) + (cz & 31) * 32)
        offset = int.from_bytes(data[i:i + 3], "big") * 4096
        if offset == 0:
            return None
        length, kind = struct.unpack_from(">ib", data, offset)
        raw = data[offset + 5:offset + 4 + length]
        if kind == 2:
            raw = zlib.decompress(raw)
        elif kind == 1:
            import gzip
            raw = gzip.decompress(raw)
        elif kind != 3:
            return None
        return Reader(raw).root()

    # The block at world x, y, z: (name, properties), or None where the
    # world has no chunk.
    def block(self, x, y, z):
        cx, cy, cz = x >> 4, y >> 4, z >> 4
        key = (cx, cy, cz)
        if key not in self.sections:
            self.load(cx, cz)
        sec = self.sections.get(key)
        if sec is None:
            return None
        palette, data = sec
        if data is None:
            return palette[0]
        i = ((y & 15) * 16 + (z & 15)) * 16 + (x & 15)
        bits = max(4, math.ceil(math.log2(len(palette))))
        per = 64 // bits
        word = data[i // per] & 0xFFFFFFFFFFFFFFFF
        return palette[(word >> ((i % per) * bits)) & ((1 << bits) - 1)]

    def load(self, cx, cz):
        root = self.chunk(cx, cz)
        for cy in range(-4, 20):
            self.sections[(cx, cy, cz)] = None
        if root is None:
            return
        for s in root.get("sections", []):
            states = s.get("block_states")
            if not states:
                continue
            palette = [(p.get("Name"), p.get("Properties", {})) for p in states.get("palette", [])]
            self.sections[(cx, s.get("Y"), cz)] = (palette, states.get("data"))


# ---------------------------------------------------------------------------
# Blocks as the sims see them
# ---------------------------------------------------------------------------
AIR = {"minecraft:air", "minecraft:cave_air", "minecraft:void_air"}
# plants that are water themselves (a turtle in game goes through them as through water)
WATERY = {"minecraft:seagrass", "minecraft:tall_seagrass", "minecraft:kelp", "minecraft:kelp_plant",
          "minecraft:bubble_column"}


def simBlock(block):
    """A block as a fixture entry: None for air, else name[:level][:w] (w: waterlogged)."""
    if block is None:
        return "minecraft:stone"                   # (no chunk there: rock)
    name, props = block
    if name in AIR:
        return None
    if name in WATERY:
        return "minecraft:water:0"
    if name in ("minecraft:water", "minecraft:lava"):
        return "%s:%s" % (name, props.get("level", "0"))
    if props.get("waterlogged") == "true":
        return name + ":w"
    return name


# The turtle's right, up and ahead, in world axes, for each way it faces.
FACING = {
    "south": ((-1, 0, 0), (0, 0, 1)),
    "north": ((1, 0, 0), (0, 0, -1)),
    "east": ((0, 0, 1), (1, 0, 0)),
    "west": ((0, 0, -1), (-1, 0, 0)),
}


def toWorld(at, facing, x, y, z):
    right, ahead = FACING[facing]
    return (at[0] + x * right[0] + z * ahead[0], at[1] + y, at[2] + x * right[2] + z * ahead[2])


# Characters for palette indices (none that needs escaping in a Lua long string).
CODES = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz!#$%&()*+,-./:;<>?@^_`{|}~"


def export(world, at, facing, box, out):
    x0, x1, y0, y1, z0, z1 = box
    palette, index, layers = [None], {None: 0}, []
    for y in range(y0, y1 + 1):
        rows = []
        for z in range(z0, z1 + 1):
            row = []
            for x in range(x0, x1 + 1):
                b = simBlock(world.block(*toWorld(at, facing, x, y, z)))
                if b not in index:
                    if len(palette) >= len(CODES):
                        sys.exit("more kinds of block than the fixture can name (%d)" % len(CODES))
                    index[b] = len(palette)
                    palette.append(b)
                row.append(CODES[index[b]])
            rows.append("".join(row))
        layers.append(rows)
    with open(out, "w", encoding="utf-8", newline="\n") as f:
        f.write("-- A box of real Minecraft terrain for the mine sims (sim/terrain.py): x to the turtle's\n")
        f.write("-- right, y up, z ahead, the turtle at 0,0,0.  cells[y][z] is a row along x, each\n")
        f.write("-- character a palette entry (\"0\" air): name[:level][:w], w for waterlogged.\n")
        f.write("return {\n")
        f.write("    box = { %d, %d, %d, %d, %d, %d },\n" % box)
        f.write("    codes = \"%s\",\n" % CODES)
        f.write("    palette = {\n")
        for i, b in enumerate(palette[1:], 1):
            f.write("        [%d] = \"%s\",\n" % (i, b))
        f.write("    },\n    cells = {\n")
        for rows in layers:
            f.write("        {\n")
            for r in rows:
                f.write("            \"%s\",\n" % r)
            f.write("        },\n")
        f.write("    },\n}\n")
    counts = {}
    for rows in layers:
        for r in rows:
            for c in r:
                counts[c] = counts.get(c, 0) + 1
    print("%s: %d blocks, %d kinds" % (out, sum(counts.values()), len(palette) - 1))


# ---------------------------------------------------------------------------
# Looking for a spot
# ---------------------------------------------------------------------------
def find(world, facing, y, size, top):
    w, h, length = size
    chunks = []
    for name in os.listdir(world.dir):
        parts = name.split(".")
        if len(parts) == 4 and parts[0] == "r" and parts[3] == "mca":
            rx, rz = int(parts[1]), int(parts[2])
            data = world.region(rx, rz)
            if not data:
                continue
            for i in range(1024):
                if int.from_bytes(data[4 * i:4 * i + 3], "big"):
                    chunks.append((rx * 32 + i % 32, rz * 32 + i // 32))
    have = set(chunks)
    spots = []
    for cx, cz in chunks:
        at = (cx * 16 + 8, y, cz * 16 + 8)
        ends = [toWorld(at, facing, x, 0, z) for x in (-1, w) for z in (0, length + 1)]
        if not all(((e[0] >> 4), (e[2] >> 4)) in have for e in ends):
            continue
        wet = ore = air = 0
        for z in range(1, length + 1, 2):
            for x in range(-1, w + 1, 2):
                for yy in range(-1, h + 1, 2):
                    b = simBlock(world.block(*toWorld(at, facing, x, yy, z)))
                    if b is None:
                        air += 1
                    elif b.startswith("minecraft:water") or b.startswith("minecraft:lava"):
                        wet += 1
                    elif b.endswith("_ore"):
                        ore += 1
        spots.append((wet, ore, air, at))
    spots.sort(key=lambda s: (-(s[0] > 0), -s[1], -s[0]))
    for wet, ore, air, at in spots[:top]:
        print("--at %d,%d,%d  water/lava %d, ore %d, air %d (of every 8th block)" % (at + (wet, ore, air)))


def nums(text, n):
    v = [int(t) for t in text.split(",")]
    if len(v) != n:
        raise argparse.ArgumentTypeError("needs %d numbers" % n)
    return v


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("world")
    ap.add_argument("--facing", choices=sorted(FACING), default="south")
    ap.add_argument("--at", type=lambda t: nums(t, 3))
    ap.add_argument("--box", type=lambda t: nums(t, 6), default=[-4, 8, -4, 8, 1, 48])
    ap.add_argument("--out")
    ap.add_argument("--find", action="store_true")
    ap.add_argument("--y", type=int, default=40)
    ap.add_argument("--size", type=lambda t: nums(t, 3), default=[5, 5, 48])
    ap.add_argument("--top", type=int, default=10)
    a = ap.parse_args()
    world = World(a.world)
    if a.find:
        find(world, a.facing, a.y, a.size, a.top)
    elif a.at and a.out:
        export(world, a.at, a.facing, tuple(a.box), a.out)
    else:
        ap.error("--at and --out (or --find)")


if __name__ == "__main__":
    main()
