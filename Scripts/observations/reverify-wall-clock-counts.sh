#!/usr/bin/env bash
# Re-check 2026-09-07-a-bounded-refusal-counted-instead-of-timed.
#
# Read-only: it runs tests and guards and edits nothing. The counterfactual this record rests on —
# 119 censuses when the writer's own 3 s default governs, against 13 when the argument is passed —
# is a checked-in test rather than a mutation someone has to apply by hand, so re-reading it does
# not require touching a tracked file. An evidence tool that edits the tree it is measuring has
# been a real defect here before.
set -uo pipefail
cd "$(dirname "$0")/../.."

FAIL=0
step() {
  local label="$1"; shift
  if "$@" >/tmp/reverify-wall-clock.$$ 2>&1; then
    printf '  ok   %s\n' "$label"
  else
    FAIL=1
    printf '  FAIL %s\n' "$label"
    tail -20 /tmp/reverify-wall-clock.$$ | sed 's/^/       /'
  fi
  rm -f /tmp/reverify-wall-clock.$$
}

echo "== the counted assertions and their control =="
step "the bounded refusal, and the 3 s default it is bounded against" \
  swift test --no-parallel --filter \
  'switchThatNeverChangesStructureRefusesWithinDeadlineAndLeavesEntryView|viewSwitchWithNoSuppliedTimeoutWaitsOnTheWritersOwnThreeSecondDefault'
step "the two waitForSegmentVisible waits, counted rather than timed" \
  swift test --no-parallel --filter 'libraryAccessorWaitFor'
step "the traversal budget, as 3101 probe calls" \
  swift test --no-parallel --filter 'testEnumerateTree_Perf_100Folders_UnderBudget'

echo "== the rule that keeps the clock out =="
step "no wall-clock read anywhere in Tests/" \
  python3 Scripts/check-test-wall-clock-assertions.py
step "the rule's own 17 cases, including the verbatim line that failed CI three times" \
  python3 Scripts/test_test_wall_clock_assertions.py

# `swift test` rewrites Package.resolved on some toolchains and the ship gate reads it as drift.
if ! git diff --quiet -- Package.resolved 2>/dev/null; then
  git checkout -- Package.resolved
  echo "  note Package.resolved was rewritten by the build and has been restored"
fi

if [ "$FAIL" -ne 0 ]; then
  echo "REVERIFY FAIL — the record no longer describes this tree"
  exit 1
fi
echo "REVERIFY PASS — counts hold and no test reads the clock"
