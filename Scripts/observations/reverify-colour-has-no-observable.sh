#!/bin/bash
# Reverify 2026-09-09-no-attribute-value-anywhere-carries-a-track-colour.
#
# The record's claim is an ABSENCE, so the probe must be able to find something before its silence
# means anything. It reports the element count too, and this refuses a run that visited implausibly
# few — a sweep that reached nothing would otherwise report "no colour" and read as a confirmation.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 2
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

swiftc -O Scripts/livekit/ax_colour_value_sweep.swift -o "$WORK/sweep" 2>"$WORK/build.err" || {
  echo "REVERIFY FAIL: the sweep probe did not compile"; cat "$WORK/build.err"; exit 1; }
"$WORK/sweep" > "$WORK/out.txt" 2>&1 || {
  echo "REVERIFY FAIL: the sweep probe did not run"; cat "$WORK/out.txt"; exit 1; }

VISITED=$(awk '/elements visited/ {print $3}' "$WORK/out.txt")
UNREADABLE=$(awk '/child lists unreadable/ {print $4}' "$WORK/out.txt")
CGCOLOR=$(awk '/attributes of CGColor type/ {print $5}' "$WORK/out.txt")

[ -n "${VISITED:-}" ] || { echo "REVERIFY INCONCLUSIVE: could not read the element count"; cat "$WORK/out.txt"; exit 1; }
# The instrument has to have been AIMED. 1304 was measured; anything near zero means Logic was not
# up, or no window was reachable, and the absence below would then be the silence of an unaimed
# instrument rather than a reading.
if [ "$VISITED" -lt 200 ]; then
  echo "REVERIFY INCONCLUSIVE: only $VISITED element(s) visited — Logic is probably not showing a project"
  exit 1
fi
if [ "${CGCOLOR:-1}" != "0" ]; then
  echo "REVERIFY FAIL: $CGCOLOR attribute(s) of CGColor type — a colour observable now EXISTS, and"
  echo "  this record says none does. That is a better world; update the record."
  exit 1
fi
echo "REVERIFY PASS — $VISITED elements, $UNREADABLE unreadable, no attribute of colour type"
