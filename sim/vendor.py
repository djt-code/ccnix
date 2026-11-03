"""Copy what lib/ takes from vendor/ (the submodules of other people's code).

    python sim/vendor.py            copy them into lib/
    python sim/vendor.py --check    say which copies differ (run.py --check does)

A computer gets ccnix by bin/git.lua's clone or the mod's ROM (git archive):
neither carries a submodule's files, so lib/ holds a copy of each, as it is,
and vendor/ says where it came from.  Update one with
`git -C vendor/<name> checkout <tag>`, then this.

    vendor/etlua/etlua.lua -> lib/etlua.lua    etlua by Leaf Corcoran, MIT
                                               (https://github.com/leafo/etlua)
"""
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
COPIES = [("vendor/etlua/etlua.lua", "lib/etlua.lua")]


def read(rel):
    """The file's bytes, with LF line ends (Windows checkouts may have CRLF), or None."""
    path = os.path.join(ROOT, rel)
    return open(path, "rb").read().replace(b"\r\n", b"\n") if os.path.exists(path) else None


def main(args):
    stale = []
    for src, dst in COPIES:
        data = read(src)
        if data is None:
            print("no %s: git submodule update --init %s" % (src, os.path.dirname(src)))
            if "--check" not in args:
                return 1
            continue
        if read(dst) != data:
            stale.append(dst)
            if "--check" not in args:
                open(os.path.join(ROOT, dst), "wb").write(data)
                print("copied %s -> %s" % (src, dst))
    if "--check" in args:
        return stale
    return 0


if __name__ == "__main__":
    r = main(sys.argv[1:])
    sys.exit(1 if r else 0) if isinstance(r, list) else sys.exit(r)
