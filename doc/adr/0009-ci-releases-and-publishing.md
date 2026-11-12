# ADR-0009: CI, a protected main, pull requests, releases and publishing the mod

**Status:** Accepted (2026-11-12). D2, D7 and D9 are the user's
answers. The user took the rest as recommended, along with the lockstep
automation (D4) and the shared board (D11) proposed after it.
**Date:** 2026-11-12
**Deciders:** Dan Theisen

## Context

ccnix (this repo: the Lua) and ccnix-mod (the NeoForge mod: the ROM and
the gateway) are public on GitHub. Until now every change was committed
and pushed straight to `main`, tested by the sims on the author's machine
and by hand in game. Nothing checks a push, nothing stops a broken one,
and there are no tags or releases: a player can only build the jar
themselves.

The user asked (2026-11-12) for:

- CI on each repo;
- `main` protected, with changes going feature branch → pull request →
  `main`, and that flow written into the repos;
- GitHub releases for each;
- in the end, the mod published on CurseForge.

Things that shape the answer:

- **The two repos are codependent.** Each is a submodule of the other.
  ccnix-mod's ROM is built from its `ccnix/` submodule's HEAD, and
  ccnix's `mod/` follows ccnix-mod (`update = none`). A submodule
  pointer is a commit hash, so anything that rewrites commits on the way
  into `main` (squash, rebase) leaves a pointer at a commit `main` never
  gets.
- **One person owns both repos.** GitHub won't let a pull request's
  author approve it, so a required review would block every change.
- **Most changes are made by Claude Code** in the author's session. It
  commits each change and has standing permission to push these repos.
- **What the tests need.** ccnix's tests need only Python and `lupa`
  (`python sim/run.py`, `--check`). ccnix-mod's need Java 21 and Gradle
  (`./gradlew build` runs its JUnit tests and builds the ROM from the
  submodule with `git archive`). The TUN helper is a small Linux C
  program.
- **Versions** are already semver in files: ccnix's `deploy/version` and
  ccnix-mod's `mod_version` in `gradle.properties`, bumped with the
  change that needs it.
- **CurseForge** has no API to create a project; that is done by hand on
  the site, and a project goes through moderation on its first file.
  Its rules want a 400×400 logo that isn't a flat colour, a one-sentence
  summary, a description of what the project does, and licences honoured
  with credit. Files are uploaded with an API token.

## Decision

GitHub Actions CI on both repos. A ruleset on each `main` that takes
changes only through a pull request with CI green. Merge commits only.
A release, made by a workflow, whenever a merged pull request raises the
version. The mod's release workflow also uploads the jar to CurseForge
and Modrinth with mc-publish.

The lockstep between the repos is automated: a ccnix release opens the
ccnix-mod pull request that carries the new ROM, and that pull request
merges itself on green. So a Lua-only change is one pull request, and
the rest follows. One GitHub Project, "ccnix", tracks the issues and
pull requests of both repos. ccnix-claude stays as it is.

## Decisions

**D1. How pull requests merge: merge commits only.** Squash and rebase
merging are turned off in both repos' settings. A submodule pointer only
ever names a commit already on the sibling's `main`.
*Why:* squash and rebase make new commits, so a pointer bumped on a
feature branch would name a commit that never reaches `main`. The ROM
build would then fail, or worse, build from a commit no one can fetch.

**D2. Who merges: Claude Code, once CI is green** (the user's answer).
No review is required. The user can look at any pull request, and says
when they want to see one before it merges.

**D3. The ruleset on `main`** (both repos):

- a pull request is required (0 approvals);
- the CI checks must pass, and the branch must be up to date with `main`;
- no force pushes, and `main` can't be deleted;
- nobody bypasses it.

*Why no bypass:* Claude Code pushes with the owner's own key. An owner
bypass would let a direct push to `main` through without a word, which
is the thing this is meant to stop. In an emergency the owner turns the
ruleset off for a moment on GitHub.

**D4. The lockstep, automated.** Two workflows do the submodule round
trip, so most changes need one pull request:

1. **ccnix releases, so the mod follows.** When ccnix's release workflow
   tags a new version (D5), a job opens a ccnix-mod pull request on
   branch `bump/ccnix-vX.Y.Z`:
   - it moves `ccnix/` to the tagged commit;
   - it raises `mod_version` by a patch;
   - it is labelled `lockstep`, and has auto-merge (merge commit) set;
   - it merges once CI is green, and the mod's own release follows
     (D5, D6, D7).
2. **The mod releases, so ccnix catches up.** When ccnix-mod's release
   workflow tags a version, a job opens a ccnix pull request on branch
   `bump/mod-vX.Y.Z`. It moves only `mod/`, and auto-merges the same
   way.

Rules that keep it sound:

- **It ends.** Step 2's pull request changes only `mod/`, not
  `deploy/version`, so ccnix doesn't release and step 1 doesn't run
  again. ccnix's `mod/` stays one mod release behind; that is the
  existing "the last one bumped lags its sibling by one", now kept up
  without anyone doing it.
- **Only releases move the mod.** A merged ccnix change that doesn't
  raise `deploy/version` reaches the mod with the next ccnix release. So
  the mod isn't released, and uploaded to CurseForge and Modrinth, for
  each edit to a help page.
- **Mod code makes it two pull requests.** A change that needs mod code
  too (a frame both sides speak, a setting) is made by hand:
  - the ccnix pull request first;
  - then a ccnix-mod pull request with the code, the `ccnix/` bump and
    the version, opened together and linked, and labelled `lockstep`.

  Step 1 does nothing while an open ccnix-mod pull request has the
  `lockstep` label, so the two don't race.
- **One credential.** It is a fine-grained token, as the repository
  secret `LOCKSTEP_TOKEN` in both repos. It is limited to ccnix and
  ccnix-mod, with Contents and Pull requests read and write, and expires
  after a year (the renewal goes on the board as an issue). The
  workflows' own `GITHUB_TOKEN` won't do: a pull request it opens
  doesn't start CI, so the required check would never come and the pull
  request could never merge.
- **Auto-merge.** "Allow auto-merge" is turned on in both repos.

CLAUDE.md in both repos says how this works, and when a change needs
the two pull requests made by hand.

**D5. When a release is made:** when a push to `main` (a merged pull
request) carries a version that has no tag yet. The workflow tags it
`vX.Y.Z` and makes the GitHub release, with notes generated from the
merged pull requests' titles. Nobody tags by hand.
*Why:* the version is already bumped with the change that needs it, so
the bump is the signal. Tags made by hand get forgotten or put on the
wrong commit.

**D6. What the releases carry:**

- **ccnix:** the notes only. GitHub adds the source archives itself,
  `setup` and `ccnix update` already fetch from git, and the ROM ships
  in the mod.
- **ccnix-mod:** the jar, with the notes saying which ccnix version its
  ROM carries.

**D7. Where the mod is published: CurseForge and Modrinth** (the user's
answer). mc-publish (`Kir-Antipov/mc-publish@v3.3`, which supports
NeoForge) uploads the jar to both from the release workflow, with:

- **loader** `neoforge`, **game version** 1.21.1, **Java** 21;
- **CC: Tweaked** declared as required, and **Advanced Peripherals** as
  optional (lib/mc uses it when it's there);
- **release type** `beta` while the mod is 0.x.

The tokens are repository secrets (`CURSEFORGE_TOKEN`,
`MODRINTH_TOKEN`), and the project IDs are repository variables. Claude
Code never sees the tokens.

**D8. What CI runs:**

- **ccnix** (`.github/workflows/ci.yml`), on every pull request and push
  to `main`:
  - `python sim/run.py --check`, which covers syntax, the help being made
    from the code, Cobalt's local limit, and the vendored copies;
  - `python sim/run.py`, all the sims;
  - `lupa` pinned to the version the sims are run with locally (2.8).
- **ccnix-mod** (`.github/workflows/ci.yml`):
  - checks out with the `ccnix/` submodule (not recursive);
  - `./gradlew build` with Java 21, which builds the ROM and runs the
    tests;
  - compiles `helper/ccnix-tun.c` with `-Wall -Werror`;
  - keeps the jar as a build artifact.

The private-detail scan stays the local git hook (ccnix-claude's
`githooks/`). Its list of private details is the user's, outside every
repo, so CI can't run it.

**D9. Scope: ccnix and ccnix-mod** (the user's answer). ccnix-claude, a
small skills repo with nothing to build, keeps pushing straight to
`main`.

**D10. The flow, written into the repos:**

- **branches:** `feat/<topic>`, `fix/<topic>`, `docs/<topic>` or
  `ci/<topic>`, made from `main` and deleted once merged;
- **`.github/pull_request_template.md`**, a checklist:
  - the sims or the build pass;
  - the version is bumped if this ships;
  - UNTESTED.md has the new in-game checks;
  - the sibling repo has been checked, and changed or said to need
    nothing;
  - nothing private in the diff;
- **CONTRIBUTING.md:** the flow, the checks, versions and the submodule
  round trip;
- **CLAUDE.md:** the same for Claude Code. The "commit and push to
  `main`" habit becomes "commit on a branch, push it, open a pull
  request, merge on green".

**D11. One board for both repos: the GitHub Project "ccnix".** It is
owned by the user's account and linked to both repos.

- **Fields:**
  - Status (Todo, In progress, In review, Done);
  - Area (turtles, network, shell and tools, ROM and deploy, mod and
    gateway, release);
  - Release (the version it ships in);
  - the repo, which GitHub adds itself.
- **Views:**
  - a board by Status;
  - a table by Area;
  - "Needs in-game test", for items with that label.
- **Built-in workflows:** a closed issue or a merged pull request goes
  to Done. The one auto-add workflow a free account gets adds ccnix's
  issues and pull requests.
- **ccnix-mod's items** are added when they're opened (`gh issue create
  --project ccnix`, and the same for pull requests). That is the rule in
  CLAUDE.md. The auto-add can't cover a second repo on a free plan. An
  Action can't add them either: neither fine-grained tokens nor GitHub
  Apps reach a Project owned by a personal account, and a classic token
  with the `project` scope is broader than this is worth.
- **Labels, the same in both repos:**
  - `bug`, `feature`, `docs`;
  - `lockstep`, a change that needs both repos;
  - `needs-in-game-test`;
  - `release`.
- **Cross-repo work:** a change needing both repos is one issue in ccnix
  with a sub-issue in ccnix-mod. Each pull request says `Closes` its
  issue.

**Later, decided on its own: UNTESTED.md as issues.** UNTESTED.md is
already a backlog of things to try by hand. Its entries could become
`needs-in-game-test` issues on the board, closed when tried. That
changes how the walkthroughs are recorded, so it waits until the board
has been used for a while.

## Options considered

### Merging

| Option | Submodule pointers | History |
|---|---|---|
| Merge commits (chosen) | stay valid: the PR's commits reach `main` as they are | the branch's commits plus a merge |
| Squash | break: the pointer's commit never reaches `main` | one commit a PR |
| Rebase | break: every commit gets a new hash | linear |

### Releases

| Option | For | Against |
|---|---|---|
| On a version bump (chosen) | follows the existing habit; nothing to remember | a bump in a PR that shouldn't release is a release anyway |
| A tag pushed by hand | full control | easy to forget, or to put on the wrong commit |
| release-please / changesets | changelogs, version bumps from commit messages | another set of rules over the existing semver habit |

### The lockstep between the repos

| Option | For | Against |
|---|---|---|
| A release opens the sibling's bump pull request, which auto-merges (chosen) | one pull request for a Lua-only change; the mod always carries the latest ccnix release | one token to keep, and a year's expiry to renew |
| Two or three pull requests by hand | no token, nothing automatic to trust | every release costs two to three pull requests, in order |
| A GitHub Project over both repos | one place to see the work | it tracks; it can't open, order or merge anything, so the pull requests stay manual |
| One repo for both | no lockstep at all | undoes the two-repo design, and the history and URLs change for both |

### Publishing

| Option | For | Against |
|---|---|---|
| mc-publish (chosen) | one step for CurseForge, Modrinth and the GitHub release; reads the jar's metadata | a third-party action, so pin it |
| A Gradle plugin (CurseForgeGradle, Minotaur) | builds and publishes in Gradle | one plugin per site, and more build code |
| Uploading by hand | no tokens in CI | slow, and forgotten |

## Consequences

- `main` is always green and releasable, and every change has a pull
  request to look back at.
- A one-line fix now costs a branch, a pull request and a CI run (a few
  minutes). Claude Code does that part.
- A Lua-only change is one pull request. Its release brings a mod
  release, and the CurseForge and Modrinth uploads, with no one doing
  more. A change with mod code is two linked pull requests made by hand.
- Each ccnix release makes a mod patch release, so both sites get a new
  file for each ccnix release.
- `LOCKSTEP_TOKEN` expires after a year. If it lapses, the bump pull
  requests stop being opened, and that is the symptom to recognise.
- The user creates the CurseForge and Modrinth projects, their tokens and
  `LOCKSTEP_TOKEN`. Moderation reviews the first upload.
- Items opened in ccnix-mod reach the board only when they are opened
  with `--project`.
- **Before the first upload,** check:
  - **The jar's network use.** It has no native code, but in TUN mode it
    starts the operator-built `ccnix-tun` helper, and `/ccnix rom update`
    fetches the ROM from GitHub. The project description should say so
    plainly. CurseForge's published rules don't cover either case.
  - **The 2026-11-06 attribution audit's three required items**, all
    three confirmed fixed:
    - R1, jbod's completion, looks done (it loads the ROM's own);
    - R2, boot's startup search, looks gone;
    - R3, shellworld in the sims, is not yet checked.
  - **The mod's name.** `ccnix` must be free on both sites.

## Action items

1. [ ] The user installs gh (done 2026-11-12, 2.103.3) and runs `gh auth login -s project`.
2. [ ] ccnix: `.github/workflows/ci.yml`, in its first pull request (this ADR with it).
3. [ ] ccnix-mod: `.github/workflows/ci.yml`, in its first pull request.
4. [ ] Both: the merge settings (merge commits only, allow auto-merge, delete branches on merge) and the D3 ruleset, set through `gh api` once CI has run once (so the check names exist).
5. [ ] The Project "ccnix" (D11): its fields, views and built-in workflows, both repos linked, and the shared labels.
6. [ ] Both: CONTRIBUTING.md, the pull request template, CLAUDE.md (D4's rules, D10, D11's `--project` rule).
7. [ ] Both: `.github/workflows/release.yml` (D5, D6). The first releases: ccnix v0.50.2 and ccnix-mod v0.26.9.
8. [ ] The user makes `LOCKSTEP_TOKEN` (a fine-grained token, D4) and sets it in both repos with `gh secret set`. An issue on the board for its renewal.
9. [ ] The lockstep jobs (D4) in both release workflows. Tried once end to end with a patch release of ccnix.
10. [ ] CurseForge readiness: the description and summary, a 400×400 logo, mods.toml dependencies, the network-use note, and the attribution check above.
11. [ ] The user creates the CurseForge and Modrinth projects and their tokens, and adds them as secrets and variables.
12. [ ] The release workflow publishes with mc-publish (D7). The first upload goes to moderation.
13. [ ] Later, on its own: UNTESTED.md's entries as `needs-in-game-test` issues (D11).
