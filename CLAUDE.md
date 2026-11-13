# ccnix and ccnix-mod are codependent

This repo (ccnix, the Lua: programs, libraries, network stack, deploy) and
**ccnix-mod** (the sibling folder `../ccnix-mod`, the NeoForge mod: the
ROM and the TUN gateway) are one project in two repos, kept in lockstep. Each
is a submodule of the other:

- here, `mod/` is ccnix-mod (`update = none`, so recursive submodule commands end);
- there, `ccnix/` is this repo. The mod's ROM is built from that submodule's
  HEAD (`bin lib turtle pc help deploy`, via git archive).

## The rule

Whatever is asked in either repo, look at the other one before deciding the
work is done. Check whether the goal needs changes there too, for example:
a frame or protocol change the gateway also speaks, a file the ROM, boot or
`ccnix update` depends on, a rename, a setting, docs or help that describe the
other side. Read the sibling's code. Don't assume it's unaffected.

- If the sibling needs changes, make them in its own folder (not inside the
  submodule copy here), on a branch, in its own pull request.
- Submodule pointers only ever move to a commit on the sibling's `main`
  (normally a release tag), by pull request. A ccnix release brings the mod
  along (ADR-0009 D4): ccnix-mod's `ccnix/` moves to it with a patch bump,
  then this repo's `mod/` moves to the mod's release. The lockstep jobs do
  that by opening `bump/ccnix` there and `bump/mod` here, which merge on
  green; until those jobs exist, open the same two pull requests by hand.
  The pointers can't both be at each other's tip (a hash cycle), so the last
  one bumped lags its sibling by one commit. That's expected.
- A change that needs mod code too is two pull requests labelled `lockstep`:
  this repo's first (it merges and releases), then ccnix-mod's with the code,
  `ccnix/` at that release's tag and the mod's version.
- If the sibling needs nothing, say so in a line, so it's clear it was checked.

## Versions

Both use semantic versioning, each its own: ccnix's is `deploy/version`
(the ROM carries it; `ccnix version` and the mod's `/ccnix` show it), the
mod's is `mod_version` in its `gradle.properties`. Bump them with the
change that calls for it: a new feature the minor, a fix the patch (while
they're 0.x, a breaking change is a minor bump too). A merged version bump
on a green `main` makes the release; nobody tags by hand.

## Pull requests (ADR-0009)

`main` is protected in both repos (a ruleset: a pull request, CI green,
merge commits only, no bypass). Never push to `main`.

- Branch from `main` (`feat/`, `fix/`, `docs/`, `ci/` + a topic), commit
  each change on it, push the branch, and open a pull request with `gh`.
  Fill in the template's checklist. In ccnix-mod add `--project ccnix`
  (only ccnix's items reach the board by themselves).
- Once its CI is green, merge it yourself: `gh pr merge <n> --merge
  --delete-branch` (the owner's standing decision, ADR-0009 D2). Then
  `git switch main && git pull`.
- Anything else that publishes (a tag or release by hand, a repo setting,
  a secret) is asked first.
- See CONTRIBUTING.md for the checks and the labels.
