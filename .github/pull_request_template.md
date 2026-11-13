## What and why



## Checklist

- [ ] `python sim/run.py --check` and `python sim/run.py` pass (CI runs them too)
- [ ] a change to a program comes with a sim check that fails without it
- [ ] `deploy/version` bumped, if this ships (a feature the minor, a fix the patch)
- [ ] UNTESTED.md has the new in-game checks
- [ ] ccnix-mod checked: changed in its own pull request (labelled `lockstep`), or it needs nothing because ...
- [ ] nothing private in the diff or the commit messages (hosts, addresses, usernames, paths, secrets)

Closes #
