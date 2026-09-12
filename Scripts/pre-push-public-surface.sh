#!/bin/bash
# Refuse to push commits that leak internal process metadata into a public repository.
#
# This replaces `pre-push-require-stamp.sh`, which demanded a RECORDED TOKEN proving the preflight
# had been run — minted by a gate, keyed on (tree, HEAD, BASE), and re-demanded after a merge
# changed any of the three. That was a permission system around a check that takes under a second.
# Now the hook just runs the check.
#
# What it catches is real and user-visible: this repository is public, and a commit message or
# comment carrying a session identifier, a model name, or a worker-routing note is visible to
# everyone who clones it. That has happened here before, which is why the check exists.
#
# Install (the execute bit is load-bearing — CommitLore's shim execs this only when it is -x):
#   ln -sf ../../Scripts/pre-push-public-surface.sh .git/hooks/pre-push.commitlore-chained
#   chmod +x .git/hooks/pre-push.commitlore-chained
set -u
PREFLIGHT="$HOME/.claude/scripts/lpm-public-surface-preflight.sh"
[ -x "$PREFLIGHT" ] || exit 0          # not installed here: nothing to enforce, and refusing would
                                       # block a clone that never had the check in the first place

ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
BASE=$(git merge-base origin/main HEAD 2>/dev/null) || exit 0

"$PREFLIGHT" "$ROOT" "$BASE" HEAD || {
  echo "pre-push: public-surface preflight failed; push refused." >&2
  echo "Fix the reported lines, or re-run it yourself:" >&2
  echo "  $PREFLIGHT $ROOT $BASE HEAD" >&2
  exit 1
}
