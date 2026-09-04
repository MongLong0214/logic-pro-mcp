#!/bin/bash
# Re-run the measurement behind docs/observations/2026-09-03-track-header-elements-do-not-move-on-sort.json.
#
# Drives a real sort through Logic's own menu and reports whether the header ELEMENTS moved with
# their rows. The recorded finding is that they do not; if a future Logic reorders them, the name
# join in trackSortAfterOrder is no longer the right key and this prints the disagreement.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
BIN="${TMPDIR:-/tmp}/lpm-header-identity-$$"
trap 'rm -f "$BIN"' EXIT
swiftc -O "$HERE/header-element-identity.swift" -o "$BIN" 2>/dev/null || { echo "cannot compile the identity probe"; exit 2; }
OUT=$("$BIN") || { echo "probe failed"; exit 2; }
printf '%s\n' "$OUT"
if printf '%s' "$OUT" | grep -q "NO MATCH"; then
  echo; echo "DISAGREES with the record: an after-element matched no before-element."
  exit 1
fi
BEFORE=$(printf '%s' "$OUT" | sed -n '/^BEFORE:/,/^AFTER:/p' | grep -c '«')
if [ "$BEFORE" -lt 3 ]; then
  echo; echo "PRECONDITION: fewer than 3 header rows; arrange a project where a sort can move something"
  exit 2
fi
echo; echo "Compare the BEFORE/AFTER row names against the identity map."
echo "Record says: names move, elements do not (after[i] -> before[i] for every i)."
echo "If the map is a real permutation instead, the elements now move and the record is superseded."
