# Git hooks in this repository

## pre-push — public-surface preflight

This repository is public. A commit message or source comment carrying a session identifier, a model
name, or an internal routing note is visible to everyone who clones it, and that has happened here.
`Scripts/pre-push-public-surface.sh` runs the preflight and refuses the push when it fails.

```sh
ln -sf ../../Scripts/pre-push-public-surface.sh .git/hooks/pre-push.commitlore-chained
chmod +x .git/hooks/pre-push.commitlore-chained     # the execute bit is load-bearing
```

CommitLore's installed `pre-push` shim runs the chained hook first and preserves it across
reinstalls.

### What this replaced, and why

There used to be a *stamp*: `preflight-stamp.sh` recorded that the preflight had passed for a
specific (tree, HEAD, BASE), and the hook refused any push without that record. It was a permission
system wrapped around a check that runs in under a second, and the keying made it worse — a merge
changed HEAD, so a tree that had passed needed a new stamp it had no honest way to mint. The hook
runs the check now. Nothing records that it ran, because nothing needs to.
