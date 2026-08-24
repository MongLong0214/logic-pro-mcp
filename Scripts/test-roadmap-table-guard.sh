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
expect_exit() {
  local want="$1" name="$2" roadmap="$3" issues="$4"
  local got=0 out
  out="$(python3 "$GUARD" --roadmap "$roadmap" --issues-json "$issues" 2>&1)" || got=$?
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
