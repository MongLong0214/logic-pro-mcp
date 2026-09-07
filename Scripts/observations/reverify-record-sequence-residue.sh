#!/usr/bin/env bash
# Re-check 2026-09-07-the-campaign-projects-tracks-are-harness-residue.
#
# Entirely offline and read-only: the claim is about what the repository's own harnesses do and
# what the operation's contract says they will do, so it is answerable without Logic. The live
# count reading in the record is the confirmation, not the derivation.
set -uo pipefail
cd "$(dirname "$0")/../.."

FAIL=0
say() { printf '  %-58s %s\n' "$1" "$2"; }

# Counted as INVOCATIONS, not as lines mentioning the name. `live_545_delete_confirm.py` names
# `record_sequence` in its docstring — it tried that route and it failed — and counting lines
# would have reported seven callers where there are six.
CALLERS=()
for f in Scripts/livekit/live_*.py; do
  if grep -qE '\.tool\("logic_tracks",\s*"record_sequence"' "$f"; then CALLERS+=("$f"); fi
done
say "harnesses that INVOKE record_sequence" "${#CALLERS[@]}"
[ "${#CALLERS[@]}" -eq 6 ] || { FAIL=1; echo "  FAIL expected 6 invoking harnesses"; }

for f in "${CALLERS[@]}"; do
  n=$(grep -cE '\.tool\("logic_tracks",\s*"record_sequence"' "$f")
  say "  $(basename "$f")" "$n call(s)"
  [ "$n" -eq 1 ] || { FAIL=1; echo "  FAIL expected exactly one call in $f"; }
done

if grep -q 'creates a new track each call' Sources/LogicProMCP/Dispatchers/TrackDispatcher.swift; then
  say "the contract states the per-call track creation" "found"
else
  FAIL=1; echo "  FAIL TrackDispatcher no longer states 'creates a new track each call'"
fi

if grep -q 'the run imports one sequence and leaves it' \
     Scripts/livekit/live_572_record_sequence_first_call.py; then
  say "the harness declares its own residue" "found"
else
  FAIL=1; echo "  FAIL live_572 no longer declares that it leaves the track"
fi

if [ "$FAIL" -ne 0 ]; then
  echo "REVERIFY FAIL — the record no longer describes this tree"
  exit 1
fi
echo "REVERIFY PASS — six harnesses, one call each, a contract that creates a track per call"
