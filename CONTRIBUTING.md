# Contributing to ccnix

ccnix (this repo: the Lua programs, libraries, network stack and deploy)
and [ccnix-mod](https://github.com/djt-code/ccnix-mod) (the NeoForge mod:
the ROM and the TUN gateway) are one project in two repos. Each is a
submodule of the other. How they are built, checked and released is
decided in [ADR-0009](doc/adr/0009-ci-releases-and-publishing.md); this
is the short version.

## The flow

`main` is protected: every change reaches it through a pull request with
CI green, merged with a merge commit (squash and rebase are off, because
submodule pointers name commits by hash). Nobody pushes to `main`.

1. Branch from `main`: `feat/<topic>`, `fix/<topic>`, `docs/<topic>` or
   `ci/<topic>`.
2. Commit, one logical change a commit.
3. Run the checks locally (below), push the branch, open a pull request.
   The template's checklist says what to look at.
4. CI (`sims`) must pass. Then merge it ("Create a merge commit"); the
   branch is deleted on merge.

A pull request needn't be up to date with `main` to merge. Every push to
`main` runs CI again, and a release is only made from a green `main`.

## The checks

```sh
pip install lupa==2.8          # the version CI uses
python sim/run.py --check      # syntax, help made from the code, Cobalt's local limit, vendored copies
python sim/run.py              # every simulator; a line with "ERROR:" fails it
python sim/mkhelp.py           # after changing a program's or library's comments: regenerates help/
```

The sims run the real programs against mock worlds (`sim/lib/`). A change
to a program comes with a sim check that fails without it.

## Versions and releases

`deploy/version` is ccnix's version (semantic versioning; while it's 0.x a
new feature or a breaking change bumps the minor, a fix the patch). Bump
it in the pull request that ships something. When that merges and `main`
is green, a release `vX.Y.Z` is made with notes from the merged pull
requests. Nobody tags by hand.

What's built but not yet tried in a real game goes in
[UNTESTED.md](UNTESTED.md), and moves to its Tested section once tried.

## Changes that touch ccnix-mod too

Look at the other repo before calling a change done: a frame or protocol
the gateway also speaks, a file the ROM or boot depends on, a setting,
docs that describe the other side.

- **Lua only** (most changes): one pull request here. A ccnix release
  makes ccnix-mod follow: a pull request there moves its `ccnix/` to the
  release and bumps the mod's patch version, and merges on green; the
  mod's release then moves this repo's `mod/` the same way.
- **Mod code too**: two pull requests, labelled `lockstep`, in order:
  1. this repo's, which merges and releases;
  2. ccnix-mod's, with the code, `ccnix/` at that release's tag and the
     mod's version.

  The automatic pull request for that release is then closed, since the
  hand-made one did its job.

## Tracking

Issues and pull requests of both repos are on the
[ccnix board](https://github.com/users/djt-code/projects/1). Labels are
the same in both repos: `bug`, `feature`, `docs`, `lockstep`,
`needs-in-game-test`, `release`.

## Keep it public-safe

These repos are public. No hostnames, IP addresses or subnets of your own
networks, usernames, home paths or secrets in files or commit messages;
use placeholders (`192.0.2.10`, `myhost`).
