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
