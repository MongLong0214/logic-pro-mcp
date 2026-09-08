#!/bin/bash
# #552 — refuse to push a tree whose public-surface preflight was never recorded as passing.
#
# Install as the CommitLore chained hook, which the installed `pre-push` shim runs first and preserves
# across reinstalls (measured in v1.0.2: it execs `pre-push.commitlore-chained` when that file is `-x`):
#
#   ln -sf ../../Scripts/pre-push-require-stamp.sh .git/hooks/pre-push.commitlore-chained
#   chmod +x .git/hooks/pre-push.commitlore-chained     # the execute bit is load-bearing
#
# With this installed it no longer matters HOW the preflight was invoked. Chained with `&&` after a `tail`
# that swallowed the exit code, run from the wrong directory, or not run at all — the push stops, because
# the check has moved from something you must remember to something you must pass.
#
# WHAT THIS DOES NOT DO. The commit that introduced this said "impossible to walk past". That is one step
# stronger than the mechanism: `git push --no-verify` skips every pre-push hook, and no local hook can
# prevent that. What this actually converts is ACCIDENTAL walk-past into DELIBERATE opt-out — nobody
# intended `| tail -2 &&`, whereas `--no-verify` has to be typed. That is a real improvement and it is the
# most a local hook can offer; it is not an unbypassable gate. Making it unbypassable requires enforcement
# where the push LANDS (a server-side ruleset / required status check), not where it starts.
#
# Stating this here because the alternative has already cost us twice: a guard header that claimed a
# literal "can no longer be written at all" was defeated by one escape, and a receipt that claimed more
# than its code did was three times a blocker. A header that overstates its mechanism gets believed.
#
# Deletions and branch removals pass: there is no tree to have verified.
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
STAMPER="$REPO_ROOT/Scripts/preflight-stamp.sh"
if [ ! -f "$STAMPER" ]; then
    # This used to `exit 0` silently, which meant the gate switched itself off from WORKING-TREE state:
    # check out any branch forked before this script existed, or move one file, and pushes went through
    # with no message at all — indistinguishable from a pass. Say so on stderr instead of vanishing.
    echo "pre-push: no Scripts/preflight-stamp.sh in the working tree — stamp gate NOT enforced" >&2
    exit 0
fi

FAILED=0
# `|| [ -n ... ]` because `read` returns non-zero on a final line with no trailing newline, which
# silently dropped that ref and left FAILED at 0 — a vacuous hook for any hand-fed stdin.
while read -r _local_ref local_sha _remote_ref remote_sha || [ -n "${local_sha:-}" ]; do
    [ -z "${local_sha:-}" ] && continue
    case "$local_sha" in
        0000000000000000000000000000000000000000) continue ;;   # deletion
    esac
    # ALREADY PUBLISHED CONTENT PASSES, for the same reason a deletion does: there is no new tree
    # to have verified. This gate exists to stop UNPUSHED content going out without a preflight,
    # and a commit already reachable from a remote-tracking ref went out through one.
    #
    # The case that forced this is a release TAG. `release-stable.sh` tags the merge commit on
    # `main`, and at that moment `main` and `origin/main` are the same commit — so the tag adds
    # nothing, and yet the push was refused. Worse, no honest route to the stamp existed: the ship
    # gate keys its stamp on (tree, HEAD, BASE) and refuses to run at all when the base resolves to
    # HEAD, so on `main` the token could be neither obtained nor waived. Measured 2026-09-08 with
    # v3.16.0 — a tree carrying a green 4440-test suite, a passing preflight and live evidence
    # bound to its head, stuck at the last step (#821).
    #
    # `--contains` and not `merge-base --is-ancestor <sha> origin/main`: the question is whether
    # ANY remote-tracking ref already holds this commit, not whether one particular branch does,
    # and a tag on a release branch is as published as one on main. New commits are not reachable
    # from any of them, which is exactly the property that keeps this narrow.
    if [ -n "$(git for-each-ref --contains "$local_sha" --count=1 --format='%(refname)' refs/remotes/ 2>/dev/null)" ]; then
        continue
    fi
    if ! bash "$STAMPER" check "$local_sha" >/dev/null 2>&1; then
        TREE=$(git rev-parse "${local_sha}^{tree}" 2>/dev/null)
        echo "pre-push REFUSED: no passing-preflight stamp for tree ${TREE:-<unresolved>} (commit ${local_sha:0:8})" >&2
        echo "  The preflight is not recorded as having passed for this exact content." >&2
        echo "  Run the ship gate — it records the stamp for you:" >&2
        echo "    ~/.claude/scripts/lpm-ship.sh . --push origin <branch>" >&2
        echo "  Amending a message alone does NOT invalidate a stamp: it is keyed to the tree." >&2
        FAILED=1
    fi
done

exit "$FAILED"
