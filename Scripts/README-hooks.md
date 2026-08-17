
## #552 — the preflight stamp

`Scripts/preflight-stamp.sh` records that the public-surface preflight passed for a specific **tree**, and
`Scripts/pre-push-require-stamp.sh` refuses to push a tree with no such record.

Install once per clone:

```sh
ln -sf ../../Scripts/pre-push-require-stamp.sh .git/hooks/pre-push.commitlore-chained
chmod +x .git/hooks/pre-push.commitlore-chained
```

It goes in the *chained* slot because `.git/hooks/pre-push` is a CommitLore shim that rewrites itself on
reinstall; the shim runs `pre-push.commitlore-chained` first and preserves it. The execute bit is
load-bearing — the shim only runs the chained hook when it is `-x`.

**Keyed over content, the commit object, and the base.** An earlier revision keyed on the tree alone and
advertised "a message-only amend keeps its stamp" as the design win. That property was the exploit: the
preflight's C1a check greps **commit messages** for internal-process metadata, and messages are not in the
tree, so `git commit --amend -m "<forbidden metadata>"` kept a valid stamp and the gate permitted exactly
the class it refuses. An amend now invalidates the stamp.

**What this does and does not defend against.** It defends against *forgetting* the preflight. It does
**not** defend against bypassing it: `record` verifies nothing — deliberately, because a recorder that
also verified could certify its own work — so one `touch` in the stamp directory forges a pass that is
indistinguishable from a real one. Nor does it survive `git push --no-verify`, which skips every pre-push
hook; no local hook can prevent that. What the hook converts is *accidental* walk-past into *deliberate*
opt-out — nobody intended `| tail -2 &&`, whereas `--no-verify` has to be typed. Genuine
unbypassability has to live where the push lands, as a required server-side status check. Treat the stamp
as a reminder with teeth, not as proof.

**An uninstalled hook is a silent absence**, which is the same failure shape the stamp exists to fix: a
fresh clone, a second machine, or a reinstall that drops the chained slot leaves no gate and says nothing.
`lpm-ship.sh` therefore checks for the hook and prints `NOT ENFORCED` with the install command when it is
missing, so the absence is reported rather than assumed away.

**Run the install from the main clone**, not a linked worktree: there `.git` is a file, not a directory,
and the relative symlink will not resolve.

`~/.claude/scripts/lpm-ship.sh` records the stamp when the preflight passes, so the normal path needs no
extra step. `bash Scripts/test-preflight-stamp.sh` proves the gate refuses an unstamped tree; it runs in
CI beside the other guards.
