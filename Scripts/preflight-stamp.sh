#!/bin/bash
# #552 — record that the public-surface preflight passed for a specific TREE, and answer whether a given
# tree is stamped.
#
# Why a stamp exists at all: the preflight only protects what it is invoked on, and three times it was
# walked past — piped through `tail`, which swallows its exit code, so `&&` proceeded while `PREFLIGHT
# FAIL` scrolled by on screen. `lpm-ship.sh` was written to make that impossible and works, but only when
# someone remembers to use it, and hand-chaining recurs exactly when people are in a hurry. A stamp moves
# the check from a place that must be INVOKED to a place that must be PASSED.
#
# WHAT THE KEY MUST COVER — and an earlier version of this file got it wrong in the most dangerous way.
#
# The first version keyed on the TREE alone and advertised "an amend that only rewords a message keeps its
# stamp" as the design win. That property was the exploit. The preflight this stamp attests is NOT a
# function of the tree: its C1a check greps COMMIT MESSAGES in `$BASE..$HEAD` for internal-process
# metadata, and messages are not in the tree. So `git commit --amend -m "<forbidden metadata>"` produced a
# new commit, the same tree, a still-valid stamp, and a permitted push — the gate certifying precisely the
# class it exists to refuse, by the one operation the documentation promised was safe.
#
# The key is therefore over (tree, HEAD commit object, BASE sha): the content, the messages, and the range
# the preflight diffed against. An amend now DOES invalidate the stamp, because an amend can change
# something the preflight read. That costs a re-run on a reword, and that cost is correct — the previous
# saving was purchased with a hole.
#
# Usage:
#   Scripts/preflight-stamp.sh record [<tree-ish>]   run nothing; record that the caller verified this tree
#   Scripts/preflight-stamp.sh check  [<tree-ish>]   exit 0 stamped, 1 not stamped, 2 cannot tell
#   Scripts/preflight-stamp.sh path                  print the stamp file location
#
# `record` deliberately does NOT run the preflight itself. A recorder that also verifies would be trusted
# to do both and could then certify its own work; this only writes down a result someone else produced.
set -uo pipefail

STAMP_DIR="${LPM_STAMP_DIR:-$(git rev-parse --git-dir 2>/dev/null)/lpm-preflight}"
MODE="${1:-check}"
TREEISH="${2:-HEAD}"

# The stamp key: content + commit object + the base the preflight diffed against. `BASE` matters because
# every diff-based check is relative to it, and `LPM_BASE` can move it.
stamp_key () {
    local tree commit base
    tree=$(git rev-parse "${TREEISH}^{tree}" 2>/dev/null) || return 1
    commit=$(git rev-parse "${TREEISH}^{commit}" 2>/dev/null) || return 1
    base=$(git rev-parse "${LPM_BASE:-origin/main}" 2>/dev/null || echo "no-base")
    [ -n "$tree" ] && [ -n "$commit" ] || return 1
    printf '%s %s %s' "$tree" "$commit" "$base" | shasum -a 256 | cut -d" " -f1
}

case "$MODE" in
  path)
    echo "$STAMP_DIR"
    ;;
  record)
    TREE=$(stamp_key) || { echo "CANNOT-STAMP(2): cannot resolve a stamp key for $TREEISH"; exit 2; }
    [ -n "$TREE" ] || { echo "CANNOT-STAMP(2): could not resolve a tree for $TREEISH"; exit 2; }
    mkdir -p "$STAMP_DIR" || { echo "CANNOT-STAMP(2): cannot create $STAMP_DIR"; exit 2; }
    printf 'tree %s\n' "$TREE" > "$STAMP_DIR/$TREE"
    echo "stamped tree $TREE"
    ;;
  check)
    TREE=$(stamp_key) || { echo "CANNOT-CHECK(2): cannot resolve a stamp key for $TREEISH"; exit 2; }
    if [ -z "$TREE" ]; then
        echo "CANNOT-CHECK(2): could not resolve a tree for $TREEISH"; exit 2
    fi
    # An ABSENT store means nothing has been stamped yet — a fresh clone, and a real verdict of 1. An
    # store that EXISTS but cannot be read is an environment failure, and reporting that as "never
    # verified" would collapse the distinction these exit codes exist for.
    if [ -e "$STAMP_DIR" ] && [ ! -r "$STAMP_DIR" ]; then
        echo "CANNOT-CHECK(2): stamp store $STAMP_DIR exists but is not readable"
        exit 2
    fi
    if [ -f "$STAMP_DIR/$TREE" ]; then
        echo "OK: $TREEISH is stamped (key $TREE)"
        exit 0
    fi
    echo "NOT-STAMPED(1): $TREEISH has no passing-preflight stamp (key $TREE)"
    exit 1
    ;;
  *)
    echo "usage: $0 {record|check|path} [tree-ish]"; exit 2
    ;;
esac
