#!/usr/bin/env bash
# Re-check 2026-09-08-the-region-origin-is-the-bridge-not-a-label. Offline; a grep.
set -uo pipefail
cd "$(dirname "$0")/../.."
A=Sources/LogicProMCP/MIDIReadback/MIDIReadbackAssessment.swift
FAIL=0
say() { printf '  %-58s %s\n' "$1" "$2"; }

if grep -q "regionStartTick: Int64" "$A"; then say "parseNote still takes a region origin" found
else FAIL=1; echo "  FAIL parseNote no longer takes regionStartTick — the bridge has moved"; fi

if grep -q "subtractingReportingOverflow(regionStartTick)" "$A"; then
  say "the origin is still subtracted from the absolute start" found
else FAIL=1; echo "  FAIL the subtraction is gone — this record describes a different parser"; fi

# The other half: the descriptor must still NOT carry a tick, or the wall in this record has moved.
#
# FIND IT FIRST. This used to be one grep whose `else` branch printed "confirmed" — so when the
# struct was absent the check reported the absence of a FIELD by failing to find a TYPE, and passed
# for the wrong reason. Caught by review 2026-09-08: `ObservedRegionDescriptor` lives on the LRI-1
# branch and not on main, and the script said PASS on a head that has never contained it. An
# instrument that was not aimed cannot report an absence.
E=Sources/LogicProMCP/MIDIReadback/EventListReadbackEvidence.swift
if ! grep -q "struct ObservedRegionDescriptor" "$E" 2>/dev/null; then
  echo "  REVERIFY INCONCLUSIVE: no \`struct ObservedRegionDescriptor\` in $E."
  echo "  This record is about that type's fields; on a tree without it there is nothing to read."
  exit 1
fi
if grep -A5 "struct ObservedRegionDescriptor" "$E" | grep -q "startTick"; then
  FAIL=1; echo "  FAIL the descriptor now carries a startTick — re-measure before citing this record"
else say "the descriptor still carries no start tick" confirmed; fi

[ "$FAIL" -eq 0 ] || { echo "REVERIFY FAIL"; exit 1; }
echo "REVERIFY PASS — the origin is still the bridge, and the surface still does not supply it"
