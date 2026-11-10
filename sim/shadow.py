"""A library's name hidden by a local where the library is used.

    local text = require("text")
    ...
    local function show(text)            -- a string now, in here
        return text.trim(text)           -- so this indexes the string: an error
    end

ccnix's libraries are named for what they work on (text, path, glob,
scan, convert), and those make good variable names too.  check(src)
lists the lines where NAME.field is used while a local NAME other than
the library's own (a parameter, a for variable, a later local) is in
scope.  A rough tokenizer, not a parser: blocks are counted by keyword
(function/do/then/repeat ... end/until), which is enough for this.
"""
import re

TOKEN = re.compile(r'''
    (?P<longcomment>--\[(?P<eq>=*)\[.*?\](?P=eq)\])
  | (?P<comment>--[^\n]*)
  | (?P<longstring>\[(?P<eq2>=*)\[.*?\](?P=eq2)\])
  | (?P<string>"(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])*')
  | (?P<name>[A-Za-z_][A-Za-z0-9_]*)
  | (?P<number>\d[\w.]*)
  | (?P<space>\s+)
  | (?P<op>\.\.\.|\.\.|==|~=|<=|>=|::|.)
''', re.S | re.X)

REQUIRE = re.compile(r'^local (\w+) = require\("(\w+)"\)', re.M)


def tokens(src):
    for m in TOKEN.finditer(src):
        kind = m.lastgroup
        if kind in ('longcomment', 'comment', 'space', 'eq', 'eq2'):
            continue
        yield kind, m.group(), m.start()


def check(src):
    """[(line, name)] for each use of a required library's name while a
    local of the same name hides it."""
    libs = {local for local, lib in REQUIRE.findall(src)}
    if not libs:
        return []
    toks = list(tokens(src))
    text = lambda k: toks[k][1] if k < len(toks) else ''
    line = lambda pos: src.count('\n', 0, pos) + 1
    stack = [set()]          # the names declared in each open block
    pending = set()          # a for loop's names, for the block its "do" opens
    hits = []
    i = 0
    while i < len(toks):
        kind, t, pos = toks[i]
        if kind != 'name' or text(i - 1) in ('.', ':'):
            i += 1
            continue
        if t == 'function':
            j = i + 1
            while text(j) != '(':
                j += 1
            params = set()
            while text(j) != ')':
                if toks[j][0] == 'name':
                    params.add(toks[j][1])
                j += 1
            stack.append(params)
            i = j + 1
            continue
        if t == 'for':
            j = i + 1
            while text(j) not in ('in', '='):
                if toks[j][0] == 'name':
                    pending.add(toks[j][1])
                j += 1
        elif t in ('do', 'then', 'repeat'):
            stack.append(pending)
            pending = set()
        elif t == 'else':
            stack[-1] = set()
        elif t == 'elseif':
            stack.pop()
        elif t in ('end', 'until'):
            stack.pop()
        elif t == 'local':
            j = i + 1
            if text(j) == 'function':
                stack[-1].add(text(j + 1))
            elif not (text(j + 1) == '=' and text(j + 2) == 'require'):   # (the library's own)
                while toks[j][0] == 'name':      # name ("<" attrib ">")? ("," name ...)*
                    stack[-1].add(toks[j][1])
                    j += 1
                    if text(j) == '<':
                        j += 3
                    if text(j) != ',':
                        break
                    j += 1
        elif t in libs and text(i + 1) == '.' and any(t in names for names in stack):
            hits.append((line(pos), t))
        i += 1
    return hits
