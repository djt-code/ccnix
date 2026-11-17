---
name: field-report
description: Keep /claude/report_harness_v<N>.md as you work: what you did with numbers, what failed and why, library friction, top fixes. The developers read it.
---
# The field report

Use whenever you work a goal, and always when the player asks for a report or a harness pass.
The developers of turtlelib and this harness read the report next to `claude.log`, check each
claim in the code, and turn it into fixes (the news after an update says what changed). It is
the one channel from you to the code you drive, so it pays to be exact.

## The file
- `/claude/report_harness_v<N>.md`. List /claude for the highest N. If that report was written
  on the ccnix version running now (its title says it; the version is in /claude/.version),
  add to it; else start N + 1.
- Title line: `# Harness report v<N> (ccnix <version>) - <what this session is about>`.
- Write as you go, after each goal or milestone, not at the end: a session can stop at any
  time, and old results get cleared from what you see.

## Sections
1. **Log**: one bullet per step, with the time (UTC: `os.date("!%H:%M")`) so it lines up with
   claude.log, what you called and the numbers: fuel before and after, cells placed of total,
   blocks dug, seconds, calls it took, retries.
2. **What worked**: the functions that did the job, with counts ("T.build: 23 of 24 cells, 55
   fuel, 53 s"). The developers need to know what not to break.
3. **What went wrong (mine) and what would have prevented it**: your own mistakes as well as
   the library's, each with the cause and a general fix.
4. **Library / harness friction**: per item, the call as you made it, what came back (quote
   the error or why whole, in backticks), what you expected, what you did instead, and how
   many times it happened ("4 times", "every trip").
5. **Helpers I wrote**: each `keep()` helper by name, what it wraps, whether it is general or
   only for this world. A general one is a candidate for turtlelib.
6. **Top improvements, in order**: the five to seven that would have saved the most, most
   valuable first.
7. **Process lessons** (optional): how you'd work differently next time.

## Before you write a claim
- Look the function up in the index and the manual first: "it exists but I didn't know" is a
  documentation fix, and saying so is just as useful.
- Quote what the code said; don't paraphrase or cut it. A why cut to 200 characters hid the
  advice at its end ("opts.limit raises that") and was reported as "says only no path".
- Separate what you saw from why you think it happened.
- Read the last report's top list and the news: say which items are now fixed, still open, or
  not tried yet.

## Keep it general
Describe places by kind ("a lava moat", "a 9 by 9 room under a courtyard"), not by your world's
coordinates or names: the fixes go to every world. Player preferences that hold anywhere
("tidy beats maximal", "ask before replacing their things") belong in the report; their
private details don't.

## Pitfalls from past reports
- Notes written after every step are what let a session with most of its context cleared
  finish correctly; a report kept the same way survives a stop too.
- A claim checked against your own shortened output can be wrong (the "no path" above): the
  reviewers find that in claude.log and the claim is dropped.
- Counts without units ("cost a lot") can't be acted on; give fuel, cells, seconds, calls.
- A long list of equal wishes is hard to act on: order them.

## Tell the player
When you add a section, say so in a line ("report v4 updated: 3 friction items"), and where
the file is, so they can pass it on.
