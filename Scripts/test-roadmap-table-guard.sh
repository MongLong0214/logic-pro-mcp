#!/usr/bin/env bash
# Proves `Scripts/roadmap-table-matches-github.py` can fail, and fails for the right reason.
#
# A drift guard that has only ever been watched pass is decoration. Each case below is a defect the
# guard exists to catch, plus the two cases where it must refuse to answer rather than report clean:
# a truncated issue list and a table it could not parse. Those two are the ones that would silently
# turn the guard off, so they assert exit 2 specifically — not merely "non-zero".
#
# Runs entirely on fixtures: no network, no `gh`, no repository state.
set -uo pipefail

GUARD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/roadmap-table-matches-github.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAILURES=0

# Asserts the guard exits with $1 for the given roadmap/issues pair. $2 is the case name.
# $5, when given, is a pull-request body: the guard then allows the table to be ahead of GitHub
# for the issues that body says the PR closes.
expect_exit() {
  local want="$1" name="$2" roadmap="$3" issues="$4" prbody="${5-}"
  local got=0 out
  if [ -n "$prbody" ]; then
    out="$(python3 "$GUARD" --roadmap "$roadmap" --issues-json "$issues" \
             --pr 1 --pr-body "$prbody" 2>&1)" || got=$?
  else
    out="$(python3 "$GUARD" --roadmap "$roadmap" --issues-json "$issues" 2>&1)" || got=$?
  fi
  if [ "$got" != "$want" ]; then
    printf 'FAIL  %-46s expected exit %s, got %s\n%s\n' "$name" "$want" "$got" "$out"
    FAILURES=$((FAILURES + 1))
  else
    printf 'ok    %-46s exit %s\n' "$name" "$got"
  fi
}

# --- fixtures -----------------------------------------------------------------------------------
cat > "$TMP/issues-ok.json" <<'JSON'
[{"number":284,"state":"OPEN"},{"number":285,"state":"CLOSED"},{"number":300,"state":"OPEN"}]
JSON

cat > "$TMP/roadmap-ok.md" <<'MD'
| ADR | issue | state | what it is waiting on |
|---|---|---|---|
| ADR-001 | #284 | OPEN | a thing |
| ADR-002 | #285 | closed | |

| issue | state | what it is waiting on |
|---|---|---|
| #300 | OPEN | another thing |
MD

# A row that was never flipped when its issue closed.
sed 's/| #300 | OPEN |/| #300 | closed |/' "$TMP/roadmap-ok.md" > "$TMP/roadmap-stale-state.md"

# An issue nobody ever added to the table — the direction a row-by-row check cannot see.
cat > "$TMP/issues-extra-open.json" <<'JSON'
[{"number":284,"state":"OPEN"},{"number":285,"state":"CLOSED"},{"number":300,"state":"OPEN"},
 {"number":683,"state":"OPEN"}]
JSON

# A table row pointing at an issue that does not exist.
cat > "$TMP/issues-missing.json" <<'JSON'
[{"number":284,"state":"OPEN"},{"number":285,"state":"CLOSED"}]
JSON

# Prose with no table rows at all: agrees with everything, proves nothing.
printf '# Roadmap\n\nNo table here yet.\n' > "$TMP/roadmap-empty.md"

# A list that hit the cap. Every row is consistent with the table, so only the length betrays it.
python3 - "$TMP/issues-truncated.json" <<'PY'
import json, sys
rows = [{"number": 284, "state": "OPEN"}, {"number": 285, "state": "CLOSED"},
        {"number": 300, "state": "OPEN"}]
rows += [{"number": 10_000 + i, "state": "CLOSED"} for i in range(1000 - len(rows))]
json.dump(rows, open(sys.argv[1], "w"))
PY

# --- cases --------------------------------------------------------------------------------------
expect_exit 0 "agreeing table passes"                    "$TMP/roadmap-ok.md"           "$TMP/issues-ok.json"
expect_exit 1 "row not flipped when the issue closed"    "$TMP/roadmap-stale-state.md"  "$TMP/issues-ok.json"
expect_exit 1 "open issue absent from the table"         "$TMP/roadmap-ok.md"           "$TMP/issues-extra-open.json"
expect_exit 1 "table row for a nonexistent issue"        "$TMP/roadmap-ok.md"           "$TMP/issues-missing.json"
expect_exit 2 "truncated issue list is not 'clean'"      "$TMP/roadmap-ok.md"           "$TMP/issues-truncated.json"
expect_exit 2 "unparseable table is not 'clean'"         "$TMP/roadmap-empty.md"        "$TMP/issues-ok.json"
expect_exit 2 "absent roadmap file is not 'clean'"       "$TMP/nope.md"                 "$TMP/issues-ok.json"

# --- the closing-PR window ----------------------------------------------------------------------
# A pull request that closes an issue cannot describe the result truthfully in its own diff. Marked
# closed early it disagrees with GitHub; left open it lands stale the moment it merges. #684 hit the
# second and turned main red. The table may run ahead, but only for what the PR says it closes.
sed 's/| #300 | OPEN |/| #300 | closed |/' "$TMP/roadmap-ok.md" > "$TMP/roadmap-ahead.md"

expect_exit 1 "a row ahead of GitHub fails without a PR"  "$TMP/roadmap-ahead.md" "$TMP/issues-ok.json"
expect_exit 0 "the PR that closes it may mark it closed"  "$TMP/roadmap-ahead.md" "$TMP/issues-ok.json" \
  "Adds the thing.

Closes #300"
expect_exit 1 "a PR closing something else grants nothing" "$TMP/roadmap-ahead.md" "$TMP/issues-ok.json" \
  "Closes #284"
# The exemption runs one way only. Claiming an issue is OPEN when GitHub closed it is staleness,
# and no PR body excuses it — that is what #684's merge produced.
sed 's/| #285 | closed |/| #285 | OPEN |/' "$TMP/roadmap-ok.md" > "$TMP/roadmap-behind.md"
expect_exit 1 "a stale OPEN row is not excused by a PR"   "$TMP/roadmap-behind.md" "$TMP/issues-ok.json" \
  "Closes #285"
# And the exemption does not let the closing PR DELETE the row instead of flipping it.
grep -v '| #300 |' "$TMP/roadmap-ok.md" > "$TMP/roadmap-dropped.md"
expect_exit 1 "the closing PR must still list the issue"  "$TMP/roadmap-dropped.md" "$TMP/issues-ok.json" \
  "Closes #300"

# The row this PR closes must be flipped IN this PR. Leaving it OPEN agrees with GitHub while
# the PR is open — both say open — and then the merge closes the issue and strands the row, so
# `main` fails for a state no PR was ever told about. Measured twice: #684 closing #678, and
# #725 closing #301. This is the only place the fix is cheap.
expect_exit 1 "a row this PR closes may not stay OPEN"    "$TMP/roadmap-ok.md" "$TMP/issues-ok.json" \
  "Closes #284"

# The failing cases must name the issue they are about, or the report is unusable in CI.
OUT="$(python3 "$GUARD" --roadmap "$TMP/roadmap-ok.md" --issues-json "$TMP/issues-extra-open.json" 2>&1)" || true
if printf '%s' "$OUT" | grep -q '#683'; then
  printf 'ok    %-46s names the drifting issue\n' "report content"
else
  printf 'FAIL  %-46s did not name #683:\n%s\n' "report content" "$OUT"
  FAILURES=$((FAILURES + 1))
fi

if [ "$FAILURES" -ne 0 ]; then
  printf '\n%s case(s) failed: the drift guard does not behave as documented.\n' "$FAILURES"
  exit 1
fi
printf '\nall cases passed: the guard fails on drift and refuses on partial input.\n'
