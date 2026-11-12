"""Make help/<name>.txt for each program from the comment at its top.

    python sim/mkhelp.py            write help/ (and turtle/tl/index.txt)
    python sim/mkhelp.py --check    say which help files are out of date

CraftOS's `help` wraps each line to the screen, so prose is joined into
one line per paragraph (it reflows on a 39-column turtle); indented lines
(usage) are kept as they are; a table of "command  what it does" rows
becomes each command on its line and what it does on the next, and a
"* " bullet's or a "name = ..." definition's lines are joined.  The header
stops at a "How it works" section, which is about the code, not its use.
help/ccnix.txt ends with the index: every command, and the topics:
hand-written help in doc/<topic>.txt (a guide, not a program's), copied
as it is.

A library is made differently (turtle/turtlelib.lua and the modules in
turtle/tl/): its top comment is the overview, and each "function T.name(...)"
in column 0 with the comment right above it is an entry.  help/turtlelib.txt
has the whole reference; turtle/tl/index.txt has one line a function (the
signature and the comment's first paragraph: what it does and returns),
under the headings of the banners ("-----", a title, "-----") it stands
beneath: claude puts that in its system prompt.  A public function with no
comment, or an index line too long, is a mistake (--check says so).
"""
import glob
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
DIRS = ["bin", "turtle", "pc"]
TOPICS = "doc"                          # hand-written help topics
LEAVE_OUT = {"[", "turtlelib"}          # "[" is test's other name; turtlelib a library (below)
LIBRARY = os.path.join("turtle", "turtlelib.lua")
MODULES = os.path.join("turtle", "tl")  # the library's modules: tl/<name>.lua is required as "tl.<name>"
INDEX = "turtle/tl/index.txt"           # one line a function, for claude's system prompt
INDEX_LINE = 260                        # the longest an index line may be (it costs tokens in every request)


def header(path):
    out = []
    for line in open(path, encoding="utf-8"):
        line = line.rstrip("\r\n")
        if not line.startswith("--"):
            break
        text = line[2:]
        if text.startswith(" "):
            text = text[1:]
        if re.match(r"\s*\*?\s*How it works", text):
            break
        out.append(text)
    while out and not out[-1].strip():
        out.pop()
    return out


def lead(line):
    return len(line) - len(line.lstrip(" "))


def column(block):
    """Where the descriptions start in a block of indented "command  what
    it does" rows: the column most rows have text at after two spaces."""
    counts = {}
    for line in block:
        for m in re.finditer(r"  (?=\S)", line):
            c = m.end()
            if c >= 12 and c > lead(line):
                counts[c] = counts.get(c, 0) + 1
    if not counts:
        return None
    best = max(counts, key=lambda c: (counts[c], -c))
    return best if counts[best] >= min(2, len(block)) else None


def table(block):
    """Rows of a table, each command on its own line and what it does on
    the next, indented, as one line the screen can wrap."""
    col = column(block)
    # two or more columns of pairs ("-e f  f exists    -f f  a file") read
    # best as they are
    wide = sum(1 for l in block if len(re.findall(r"\S  +(?=\S)", l)) >= 3)
    if col is None or wide * 2 > len(block):
        return [l.rstrip() for l in block]
    def split(line):
        # a command wider than the column, its description further on after
        # a gap (two spaces after a full stop are only a sentence's end)
        late = [m.end() for m in re.finditer(r"[^ .:;?!]  +(?=\S)", line) if m.end() > col + 2]
        if late:
            return late[-1]
        # where the description starts: at the column, give or take two
        # (hand-aligned columns drift), after a gap or a full command
        for c in (col, col - 1, col + 1, col - 2, col + 2):
            # (arguments lined up, "git pull   [dir]", aren't a description)
            if 0 < c < len(line) and line[c] not in " [<-|" and line[c - 1] == " "                     and (c == col or line[c - 2] == " "):
                return c
        return None

    out, desc = [], False               # desc: the last line out is a description
    for line in block:
        c = split(line) if lead(line) < col - 2 else None
        if lead(line) >= col - 2:       # the description going on, or starting
            if desc:
                out[-1] += " " + line.strip()
            else:
                out.append(" " * (lead(block[0]) + 4) + line.strip())
                desc = True
        elif c:
            cmd = line[:c].rstrip()
            out.append(cmd)
            out.append(" " * (lead(cmd) + 4) + line[c:].strip())
            desc = True
        else:
            out.append(line.rstrip())   # too long for the column: what it does comes below
            desc = False
    return out


def reflow(lines):
    out = []
    kind = None                         # what the last line out was: "para", "bullet", "def", None
    indent = 0
    i = 0
    while i < len(lines):
        line = lines[i]
        stripped = line.strip()
        bullet = re.match(r"(\s*)\* (?=\S)", line)
        if not stripped:
            out.append("")
            kind = None
        elif bullet:
            out.append(line.rstrip())
            kind, indent = "bullet", len(bullet.group(0))
        elif kind == "bullet" and lead(line) >= indent - 2 and lead(line) > 0:
            out[-1] += " " + stripped
        elif kind == "def" and lead(line) > 0:
            out[-1] += " " + stripped   # a definition going on
        elif lead(line) == 0 and re.match(r"[\w<>]+\s*=\s", stripped):
            out.append(stripped)        # a definition: "width  = blocks to the RIGHT..."
            kind = "def"
        elif lead(line) == 0 and kind == "para":
            out[-1] += " " + stripped
        elif lead(line) == 0:
            out.append(stripped)
            kind = "para"
        else:
            # indented lines: usage, or a table of commands and what they do
            block = []
            while i < len(lines) and lines[i].strip() and lead(lines[i]) > 0 \
                    and not re.match(r"\s*\* (?=\S)", lines[i]):
                block.append(lines[i])
                i += 1
            out.extend(table(block))
            kind = None
            continue
        i += 1
    return out


def programs():
    for d in DIRS:
        for path in sorted(glob.glob(os.path.join(ROOT, d, "*.lua"))):
            name = os.path.basename(path)[:-4]
            if name not in LEAVE_OUT:
                yield d, name, path
    yield "deploy", "setup", os.path.join(ROOT, "deploy", "setup.lua")   # (ccnix setup runs it)


# ---------------------------------------------------------------------
# Libraries: turtlelib and the modules in turtle/tl/
# ---------------------------------------------------------------------
FUNCTION = re.compile(r"function (T(?:[.:]\w+)+)\(([^)]*)\)")
BANNER = re.compile(r"-{20,}")


def library_files():
    """(name, path) of the library and then its modules."""
    yield "turtlelib", os.path.join(ROOT, LIBRARY)
    for path in sorted(glob.glob(os.path.join(ROOT, MODULES, "*.lua"))):
        yield "tl." + os.path.basename(path)[:-4], path


def section_title(first):
    """A banner's title: its first line up to the first full stop."""
    first = first.strip()
    for stop in (". ", ":"):
        if stop in first:
            first = first.split(stop, 1)[0]
    return first.rstrip(".:").strip()


def parse_library(path):
    """The functions of a library file, in order: (line, section, signature,
    comment lines).  The section is the title of the last banner above."""
    lines = open(path, encoding="utf-8").read().replace("\r\n", "\n").split("\n")
    out, section = [], None
    i = 0
    while i < len(lines):
        line = lines[i]
        if BANNER.fullmatch(line):                              # a banner: dashes, comment, dashes
            j = i + 1
            while j < len(lines) and lines[j].startswith("--") and not BANNER.fullmatch(lines[j]):
                j += 1
            if j < len(lines) and BANNER.fullmatch(lines[j]) and j > i + 1:
                title = lines[i + 1][2:]
                section = section_title(title[1:] if title.startswith(" ") else title)
                i = j + 1
                continue
        m = FUNCTION.match(line)
        if m:
            above, j = [], i - 1
            while j >= 0 and lines[j].startswith("--") and not lines[j].startswith("---"):
                text = lines[j][2:]
                above.insert(0, text[1:] if text.startswith(" ") else text)
                j -= 1
            out.append((i + 1, section, m.group(1) + "(" + m.group(2).strip() + ")", above))
        i += 1
    return out


def first_paragraph(comment):
    """The comment's first paragraph as one line: what the function does
    and returns.  It ends at a blank comment line or an indented one."""
    words = []
    for line in comment:
        if not line.strip() or line.startswith(" "):
            break
        words.append(line.strip())
    return " ".join(" ".join(words).split())


def comment_lines(comment, indent="    "):
    """A comment for help: each paragraph on one line (the screen wraps
    it), indented lines kept as they are."""
    out, para = [], []
    for line in comment + [""]:
        if line.strip() and not line.startswith(" "):
            para.append(line.strip())
            continue
        if para:
            out.append(indent + " ".join(" ".join(para).split()))
            para = []
        if line.strip():
            out.append(indent + line.rstrip())
        elif out and out[-1].strip():
            out.append("")
    while out and not out[-1].strip():
        out.pop()
    return out


def library():
    """(the library's help text, its index, the mistakes found)."""
    help_out, index_out, problems = [], [], []
    for name, path in library_files():
        if not os.path.exists(path):
            continue
        head = header(path)
        title = re.sub(r"^\S+\.lua\s+--\s+", "", head[0]) if head else ""
        rest = head[1:]
        while rest and rest[0].strip() and not rest[0].startswith(" "):
            title += " " + rest[0].strip()
            rest = rest[1:]
        rel = os.path.relpath(path, ROOT).replace("\\", "/")
        help_out.append(name + ": " + title)
        help_out.extend(reflow(rest))
        help_out.append("")
        shown = None
        for line, section, sig, comment in parse_library(path):
            heading = section or (name + ": " + title)
            if heading != shown:
                shown = heading
                help_out.extend(["== " + heading + " ==", ""])
                index_out.append(heading + ":")
            help_out.append(sig)
            if not comment:
                problems.append("%s:%d: %s has no comment above it" % (rel, line, sig))
                help_out.append("")
                continue
            help_out.extend(comment_lines(comment))
            help_out.append("")
            entry = sig + " - " + first_paragraph(comment)
            if len(entry) > INDEX_LINE:
                problems.append("%s:%d: the index line for %s is %d characters (the most is %d): "
                                "shorten the first paragraph of its comment" % (rel, line, sig, len(entry), INDEX_LINE))
            index_out.append(entry)
    return "\n".join(help_out).rstrip() + "\n", "\n".join(index_out) + "\n", problems


def undocumented():
    """Mistakes in the libraries' comments: a public function without one,
    an index line too long."""
    return library()[2]


def build():
    files, index = {}, {}
    manual, listing, _ = library()
    files["turtlelib.txt"] = manual
    extras = {INDEX: listing}                   # (made outside help/)
    index.setdefault("turtle", []).append(("turtlelib", "the turtle library: what a program or the model can call"))
    for d, name, path in programs():
        lines = header(path)
        if not lines:
            continue
        first = re.sub(r"^\S+\.lua\s+--\s+", "", lines[0])
        rest = lines[1:]
        # a title that runs onto the next line ("-- copy a directory onto ... a\n-- dispenser can feed")
        while rest and rest[0].strip() and not rest[0].startswith(" "):
            first += " " + rest[0].strip()
            rest = rest[1:]
        text = [name + ": " + first] + reflow(rest)
        files[name + ".txt"] = "\n".join(text).rstrip() + "\n"
        index.setdefault(d, []).append((name, first))
    out = ["The commands ccnix adds; `help <command>` for one.", ""]
    titles = {"bin": "Anywhere (bin/)", "turtle": "Turtles (turtle/)", "pc": "Computers (pc/)",
              "deploy": "Setting up (deploy/setup.lua, or ccnix setup)"}
    for d in DIRS + ["deploy"]:
        if d not in index:
            continue
        out.append(titles[d] + ":")
        for name, first in index[d]:
            out.append("  " + name + ": " + first)
        out.append("")
    topics = sorted(glob.glob(os.path.join(ROOT, TOPICS, "*.txt")))
    if topics:
        out.append("Topics:")
        for path in topics:
            text = open(path, encoding="utf-8").read().replace("\r\n", "\n")
            name = os.path.basename(path)
            files[name] = text.rstrip() + "\n"
            first = text.split("\n", 1)[0]
            out.append("  " + (first if first.startswith(name[:-4] + ":") else name[:-4] + ": " + first))
        out.append("")
    out.append("Settings: `set` lists them, with what each means (mine.*, farm.*, mow.*, net.*, telnetd.*, httpd.*, syslog.*,"
               " service.*, ccnix.autostart, ccsh.login, init.boot).")
    files["ccnix.txt"] = files["ccnix.txt"] + "\n" + "\n".join(out) + "\n"     # the index, after the program's own
    return files, extras


def main(args):
    files, extras = build()
    helpdir = os.path.join(ROOT, "help")
    if args[:1] == ["--check"]:
        stale = []
        for name, text in sorted(files.items()):
            p = os.path.join(helpdir, name)
            have = open(p, encoding="utf-8").read() if os.path.exists(p) else None
            if have != text:
                stale.append(name)
        extra = sorted(set(os.listdir(helpdir)) - set(files)) if os.path.isdir(helpdir) else []
        for rel, text in sorted(extras.items()):
            p = os.path.join(ROOT, rel)
            have = open(p, encoding="utf-8").read() if os.path.exists(p) else None
            if have != text:
                stale.append(rel)
        return stale + extra
    os.makedirs(helpdir, exist_ok=True)
    for rel, text in extras.items():
        p = os.path.join(ROOT, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w", encoding="utf-8", newline="\n") as f:
            f.write(text)
    for name in os.listdir(helpdir):
        if name not in files:
            os.remove(os.path.join(helpdir, name))
    for name, text in files.items():
        with open(os.path.join(helpdir, name), "w", encoding="utf-8", newline="\n") as f:
            f.write(text)
    print("%d help files in help/, and %s" % (len(files), " ".join(extras)))
    return []


if __name__ == "__main__":
    bad = main(sys.argv[1:])
    for problem in undocumented():
        print(problem)
        bad = bad or ["(the comments above)"]
    if bad:
        print("out of date (python sim/mkhelp.py): " + " ".join(bad))
        sys.exit(1)
