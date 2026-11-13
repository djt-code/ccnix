# ADR-0009: CI, a protected main, pull requests, releases and publishing the mod

**Status:** Accepted (2026-11-12). D2, D7 and D9 are the user's
answers. The user took the rest as recommended, along with the lockstep
automation (D4) and the shared board (D11) proposed after it. Revised
after a review the same day (see Review). After the review the user
chose to publish on CurseForge now as well as Modrinth (D7).
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
merging are turned off in both repos' settings, and the ruleset allows
only `merge` (D3), so the setting can't drift. A submodule pointer only
ever names a commit already on the sibling's `main`.
*Why:* squash and rebase make new commits, so a pointer bumped on a
feature branch would name a commit that never reaches `main`. The ROM
build would then fail, or worse, build from a commit no one can fetch.

**D2. Who merges: Claude Code, once CI is green** (the user's answer).
No review is required. The user can look at any pull request, and says
when they want to see one before it merges.

**D3. The ruleset on `main`** (both repos):

- a pull request is required (0 approvals), merged by merge commit only
  (`allowed_merge_methods: ["merge"]`);
- the CI check must pass: `sims` in ccnix, `build` in ccnix-mod;
- the branch need **not** be up to date with `main` (the strict policy is
  off);
- no force pushes, and `main` can't be deleted;
- nobody bypasses it.

*Why not strict:* GitHub never brings a pull request's branch up to date
by itself. The one feature that does, the merge queue, isn't offered on
repos owned by a personal account. So with the strict policy, any
pull request opened while something else merges waits forever. Most of
all that hits the lockstep's own (D4), which are opened while `main` is
moving.

*What covers it instead:* every push to `main` runs CI again. A release
is made only from a green run on `main` (D5), so a bad combination of
two pull requests fails there and isn't released.

*Why no bypass:* Claude Code pushes with the owner's own key. An owner
bypass would let a direct push to `main` through without a word, which
is the thing this is meant to stop. In an emergency the owner turns the
ruleset off for a moment on GitHub.

**D4. The lockstep, automated.** Two jobs do the submodule round trip,
so most changes need one pull request. Each runs under `LOCKSTEP_TOKEN`
(below) for every step: the push, the pull request, the label and the
auto-merge. Anything done with `GITHUB_TOKEN` starts no workflows. A pull
request it opens would never get its CI, and a merge it enabled would
never start the sibling's release.

1. **ccnix releases, so the mod follows.** After ccnix's release job
   (D5) makes ccnix vX.Y.Z, a job rebuilds ccnix-mod's branch
   `bump/ccnix` from ccnix-mod's current `main`:
   - `ccnix/` is set to the tagged commit with
     `git update-index --cacheinfo 160000,<sha>,ccnix`, so no clone is
     needed;
   - `mod_version` goes up by a patch;
   - the commit is force-pushed.

   If that branch's pull request is open it is reused and retitled ("the
   ROM at ccnix vX.Y.Z"); if not, one is opened. Either way it gets the
   `lockstep` label and `gh pr merge --auto --merge`, or a plain
   `--merge` if GitHub calls it clean already. Once its CI is green it
   merges, and the mod's own release follows (D5, D6, D7).
2. **The mod releases, so ccnix catches up.** After ccnix-mod's release
   job makes a version, a job rebuilds ccnix's branch `bump/mod` the same
   way. It moves only `mod/`, to the mod's tagged commit.

Rules that keep it sound:

- **One branch a direction, rebuilt every time, never skipped.** Two
  ccnix releases close together leave one open pull request, carrying
  the newer one. A pull request that went red, because the Lua broke the
  mod, is rebuilt by the next release, so it never blocks the ones
  after it. Each job can be run again by hand (`workflow_dispatch` with
  a version).
- **Nothing to do is nothing done.** If the sibling's `main` already
  points at the commit, the job closes its open pull request, if there
  is one, and stops. Step 1 also stops when the ROM's files (`bin lib
  turtle pc help deploy`) are the same at the tag as at the mod's
  `ccnix/`: the mod would ship nothing new. A real ccnix release changes
  `deploy/version`, so this happens only when the mod already carries
  it, as at the start.
- **It ends.** Step 2 changes only `mod/`, not `deploy/version`, so
  ccnix makes no release and step 1 doesn't run again.
  - After a full round, ccnix's `mod/` is at the mod's newest release.
  - ccnix-mod's `ccnix/` is one commit behind ccnix's `main`: the
    `bump/mod` merge, which touched only `mod/`.

  This is the existing "the last one bumped lags its sibling by one",
  kept up with no one doing it.
- **Only releases move the mod.** A merged ccnix change that doesn't
  raise `deploy/version` reaches the mod with the next ccnix release. So
  the mod isn't released, and uploaded, for each edit to a help page.
- **Mod code makes it two pull requests.** A change that needs mod code
  too (a frame both sides speak, a setting) is made by hand, in this
  order:
  1. the ccnix pull request, which merges and releases;
  2. a ccnix-mod pull request with the code, `ccnix/` at that release's
     tag and the version, labelled `lockstep` for people to see, which
     merges;
  3. the step 1 job run again: it finds `ccnix/` already there and
     closes its own pull request.

  The bot's pull request is disposable; the hand-made one wins.
- **One credential, `LOCKSTEP_TOKEN`.** It is a fine-grained token,
  stored as a repository secret in both repos:
  - limited to ccnix and ccnix-mod;
  - Contents read and write, and Pull requests read and write, which
    cover the push, the pull request, the label and the auto-merge. No
    Workflows permission is needed, since a bump never touches
    `.github/workflows`;
  - its lifetime is the user's choice, from none up to 366 days. If it
    lapses, the job fails with a 401 and GitHub emails the failure.

  A renewal date, if it has one, goes on the board as an issue.
- **Auto-merge.** "Allow auto-merge" is turned on in both repos.

CLAUDE.md in both repos says how this works, and when a change needs
the two pull requests made by hand.

**D5. When a release is made:** after a green CI run on `main`, for a
version that has no GitHub release yet.

- It is a `release` job in `ci.yml`, `needs:` the test job (`sims` or
  `build`). It runs only for a push to `main`, or by hand
  (`workflow_dispatch`).
- It reads the version: `deploy/version`, or `mod_version`.
- It asks whether release vX.Y.Z exists (`gh release view`). It doesn't
  ask the tag: a run that died after making the tag must be able to try
  again, and a shallow checkout holds no tags anyway.
- If there is none, `gh release create vX.Y.Z --target $GITHUB_SHA
  --generate-notes` makes the tag and the release together, with notes
  from the merged pull requests.
- That job, and only that job, has `contents: write`. The repos' default
  for workflows stays read-only.
- The release job's concurrency group never cancels a run. The test
  job's cancels an older run only for pull requests: a run on `main` is
  never cancelled, so every merge is checked.

Nobody tags by hand.
*Why:* the version is already bumped with the change that needs it, so
the bump is the signal. Tags made by hand get forgotten or put on the
wrong commit.

**D6. What the releases carry:**

- **ccnix:** the notes only. GitHub adds the source archives itself,
  `setup` and `ccnix update` already fetch from git, and the ROM ships
  in the mod.
- **ccnix-mod:** the jar. Its notes start with the ROM's version ("ROM:
  ccnix vA.B.C", given as `--notes` ahead of the generated ones).
- **The first releases** (amended 2026-11-12, when the release jobs were
  built):
  - ccnix v0.50.2 comes from the first green `main` after its release job
    lands.
  - The mod's first release is 0.26.9, from its own release job landing.
    Its `ccnix/` (588aa65, the 0.50.2 fix) holds the same ROM files as
    ccnix v0.50.2: everything since then is docs, CI and sims. So that is
    the ROM 0.26.9 carries, and v0.50.2's lockstep has nothing to ship
    (D4's rule on ROM files).

    The plan before was a 0.26.10 from v0.50.2's bump, to avoid two
    releases of one ROM. With the ROM already the same, that would have
    been the second release, not the first.
  - The first notes list every merged pull request so far, since there's
    no earlier tag.

**D7. Where the mod is published: Modrinth, and CurseForge** (the user's
answer; see the note on CurseForge below). In the mod's `release` job,
after `gh release create`, mc-publish uploads the jar. It is pinned by
commit (`Kir-Antipov/mc-publish@<sha> # v3.3.2`); it supports NeoForge,
and runs on Node 24. Its inputs are set in full, because its defaults
assume a `release` event and the job runs on `push`:

- **the release:** `version`, and `version-type: beta` while the mod is
  0.x (on the sites; the GitHub release, made first by `gh`, is a normal
  one);
- **the game:** `loaders: neoforge`, `game-versions: 1.21.1`, `java: 21`;
- **the project IDs**, from repository variables;
- **the files:** the GitHub release already exists, so its own inputs go
  unused.

Each site is its own step, which runs only if that site's token is set.
That lets the workflow land before the projects exist, and a run can be
repeated for one site alone (`workflow_dispatch`, a `platforms` input).
Modrinth refuses a version number it already has, and mc-publish has no
"skip what's already there".

The dependencies come from the jar's `META-INF/neoforge.mods.toml`, which
mc-publish reads, given there with mc-publish's own slugs. On its own,
mc-publish takes a modId as the slug, and the modId `computercraft` is
dan200's ComputerCraft from 2017 on both sites.

- **CC: Tweaked**, required: `[dependencies.ccnix.mc-publish]` with
  `curseforge="cc-tweaked"` and `modrinth="cc-tweaked"`.
- **Advanced Peripherals**, optional: a new dependency on the modId
  `advancedperipherals`, type `optional`, from `[0.7,)`. Its slugs are
  `curseforge="advanced-peripherals"` and `modrinth="advancedperipherals"`.

What each site needs as well:

- **CurseForge:** the Java version is set on the project by hand, since
  mc-publish's own setting doesn't reach it there (its issue #145).
- **Modrinth:** the content disclosures under its rules 1.11 and 5.9 are
  filled in: the ROM fetched from GitHub, and the TUN helper the server
  can start. The side is set to both, and the summary doesn't repeat
  the title.

The tokens are repository secrets (`CURSEFORGE_TOKEN`, `MODRINTH_TOKEN`),
and the project IDs are repository variables. Claude Code never sees the
tokens.

*CurseForge:* CC: Tweaked is no longer published there. Its page says
"CC: Tweaked is no longer published to CurseForge. Please download from
Modrinth instead", and its newest file there is 1.113.1, from September
2024. ccnix needs 1.120 or later. So:

- a CurseForge user can't get a CC: Tweaked that works with ccnix from
  CurseForge;
- a CurseForge modpack can't carry one, short of the jar added by hand,
  as this project's own dev server does;
- the required relation on CurseForge points at a project that will
  never have a build that works.

The user chose (2026-11-12) to publish on both now. ccnix's CurseForge
description says, at the top, that CC: Tweaked 1.120 or later comes from
Modrinth or CC: Tweaked's own site, not CurseForge. The required
relation to `cc-tweaked` is declared there all the same, so the page
shows what it needs.

**D8. What CI runs.** Every action is pinned by commit, with its version
in a comment. `.github/dependabot.yml` (`github-actions`, weekly) keeps
them current. The majors as of 2026-11-12:

- `actions/checkout` v7;
- `actions/setup-python` v7;
- `actions/setup-java` v6;
- `gradle/actions/setup-gradle` v6;
- `actions/upload-artifact` v7.

The Node 20 majors are gone from the runners.

- **ccnix** (`.github/workflows/ci.yml`), on every pull request and push
  to `main`, job `sims`:
  - `python sim/run.py --check`, which covers syntax, the help being made
    from the code, Cobalt's local limit, and the vendored copies;
  - `python sim/run.py`, all the sims;
  - `lupa` pinned to the version the sims are run with locally (2.8,
    which runs Lua 5.5, as the local copy does);
  - both take under a minute.
- **ccnix-mod** (`.github/workflows/ci.yml`), job `build`:
  - checks out with the `ccnix/` submodule (shallow, not recursive;
    ccnix's own `mod/` is `update = none`);
  - `./gradlew build` with Java 21, which builds the ROM with
    `git archive` and runs the tests;
  - compiles `helper/ccnix-tun.c` with `-Wall -Werror`;
  - keeps the jar as a build artifact. The `release` job uses that jar,
    so a push builds it once.

Neither uses a secret on a pull request, so pull requests from forks are
safe. Only the `release` jobs, which run on `main`, see the tokens.

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
| A release opens the sibling's bump pull request, which auto-merges (chosen) | one pull request for a Lua-only change; the mod always carries the latest ccnix release | one token to keep |
| Two or three pull requests by hand | no token, nothing automatic to trust | every release costs two to three pull requests, in order |
| A GitHub Project over both repos | one place to see the work | it tracks; it can't open, order or merge anything, so the pull requests stay manual |
| One repo for both | no lockstep at all | undoes the two-repo design, and the history and URLs change for both |

### Publishing

| Option | For | Against |
|---|---|---|
| mc-publish (chosen) | uploads to CurseForge and Modrinth; reads the jar's metadata | a third-party action, so pinned by commit; its defaults assume a `release` event |
| A Gradle plugin (CurseForgeGradle, Minotaur) | builds and publishes in Gradle | one plugin per site, and more build code |
| Uploading by hand | no tokens in CI | slow, and forgotten |

## Consequences

- `main` is always green and releasable, and every change has a pull
  request to look back at.
- **A bad pair can reach `main`.** With the strict policy off, two pull
  requests that each pass but conflict in meaning can merge one after
  the other. The red CI run on `main` shows it, and no release is made
  from it (D5). The fix is the next pull request.
- A one-line fix now costs a branch, a pull request and a CI run (a few
  minutes). Claude Code does that part.
- **A Lua-only change is one pull request.** Its release brings a mod
  release and the uploads, with no one doing more. A change with mod
  code is two pull requests made by hand, in the order D4 gives.
- **Each ccnix release makes a mod patch release,** so the sites get a
  new file for each ccnix release.
- **If `LOCKSTEP_TOKEN` lapses,** the lockstep job fails with a 401 and
  GitHub emails the failure. A new token and a re-run of the job set it
  right.
- The user creates the Modrinth (and CurseForge) projects, their tokens
  and `LOCKSTEP_TOKEN`. Moderation reviews the first upload on each site.
- Items opened in ccnix-mod reach the board only when they are opened
  with `--project`.
- **Before the first upload,** check:
  - **The jar's network use.** It has no native code, but in TUN mode it
    starts the operator-built `ccnix-tun` helper, and `/ccnix rom update`
    fetches the ROM from GitHub. Both go in Modrinth's disclosures and in
    the description. CurseForge's published rules don't cover either
    case.
  - **The 2026-11-06 attribution audit's three required items**, all
    three confirmed fixed:
    - R1, jbod's completion, looks done (it loads the ROM's own);
    - R2, boot's startup search, looks gone;
    - R3, shellworld in the sims, is not yet checked.
  - **The mod's name.** `ccnix` was free on both sites on 2026-11-12.

## Review (2026-11-12)

Before anything was built, a review of this ADR, read-only and checked
against GitHub's docs, mc-publish's source and the two sites' APIs,
changed it as follows.

- **D3's strict policy is off.** On a personal account it stalls
  auto-merge, because GitHub never updates a branch and has no merge
  queue for such repos. A release is made only from a green `main`
  instead.
- **D4 changed in four ways:**
  - one branch a direction, rebuilt each time and never skipped,
    replacing a branch per version and a skip on the `lockstep` label,
    which dropped releases and could wedge;
  - every step runs under the token, not just "one credential";
  - the description of the lag is the right way round;
  - the hand-made order is spelled out.
- **D5 checks for a release, not a tag.** A run that dies partway can
  try again. The release job comes after the test job in `ci.yml`, and
  `main`'s runs are never cancelled.
- **D6:** the mod's first release is the bump's 0.26.10, not a 0.26.9
  made by hand.
- **D7 changed in three ways:**
  - mc-publish's inputs are set in full, since its defaults assume a
    `release` event;
  - one step a site, each guarded on its token;
  - the dependency slugs are given in mods.toml, since the modId
    `computercraft` is dan200's old mod on both sites, and Advanced
    Peripherals was added.

  It also found that CC: Tweaked left CurseForge after 1.113.1.
- **D8:** the actions are at their current majors, pinned by commit,
  with Dependabot. The Node 20 majors the first CI files used are gone
  from the runners.

## Action items

1. [x] The user installs gh (2.103.3) and runs `gh auth login -s project` (done 2026-11-12: scopes repo, project).
2. [ ] ccnix: `.github/workflows/ci.yml` (D8, with the `release` job of D5 once the CI has run green), in its first pull request, this ADR with it.
3. [ ] ccnix-mod: `.github/workflows/ci.yml` the same way, in its first pull request.
4. [ ] Both: `.github/dependabot.yml` for `github-actions`.
5. [ ] Both: the merge settings (merge commits only, allow auto-merge, delete branches on merge) and the D3 ruleset (`sims` / `build`, not strict, merge only, no bypass), through `gh api`.
6. [ ] The Project "ccnix" (D11): its fields, views and built-in workflows, both repos linked, and the shared labels.
7. [ ] Both: CONTRIBUTING.md, the pull request template, CLAUDE.md (D4's rules and order, D10, D11's `--project` rule).
8. [ ] The `release` jobs (D5, D6). The first releases: ccnix v0.50.2, and ccnix-mod v0.26.9 with the jar.
9. [ ] The user makes `LOCKSTEP_TOKEN` (D4) and sets it in both repos with `gh secret set`.
10. [ ] The lockstep jobs (D4), tried end to end with the next ccnix release: the mod's patch release, then ccnix's `bump/mod` merges.
11. [ ] mods.toml: the mc-publish slugs for CC: Tweaked, and Advanced Peripherals as optional (D7).
12. [ ] Readiness for the sites: the description and summary, a 400×400 logo, Modrinth's disclosures, the network-use note, and the attribution check above.
13. [ ] The user creates the Modrinth (and CurseForge) projects and their tokens, and adds them as secrets and variables.
14. [ ] The mc-publish steps (D7). The first upload goes to moderation.
15. [ ] Later, on its own: UNTESTED.md's entries as `needs-in-game-test` issues (D11).
