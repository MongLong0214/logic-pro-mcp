#!/bin/bash
# Reverify 2026-09-09-no-key-command-moves-a-track-in-the-track-list.
#
# The record's claim is that a route is ABSENT, and an absence is the easiest thing in the world to
# report by accident. So this fails four ways, and each is a way a census can be wrong:
#
#   * the window never opened — a probe that read no list found nothing for the wrong reason;
#   * the list is implausibly short — a virtualised table that handed back one screenful would
#     also report zero candidates;
#   * a control is missing — four commands that certainly exist must be in the census, or it is
#     not seeing Track-menu commands at all;
#   * a candidate APPEARED — that is the good outcome and it still fails here, because the record
#     would then be wrong.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 2
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

swiftc -O Scripts/livekit/ax_key_command_census.swift -o "$WORK/kcc" 2>"$WORK/build.err" || {
  echo "REVERIFY FAIL: the probe did not compile"; cat "$WORK/build.err"; exit 1; }
"$WORK/kcc" > "$WORK/out.txt" 2>&1
RC=$?
cat "$WORK/out.txt"
if [ "$RC" -ne 0 ]; then
  echo "REVERIFY FAIL: the probe exited $RC (no Logic, or the Key Commands window did not open)"
  exit 1
fi

COUNT=$(sed -n 's/^commands=\([0-9]*\)$/\1/p' "$WORK/out.txt")
FOUND=$(sed -n 's/^controlsFound=\([0-9]*\) of \([0-9]*\) .*/\1/p' "$WORK/out.txt")
TOTAL=$(sed -n 's/^controlsFound=[0-9]* of \([0-9]*\) .*/\1/p' "$WORK/out.txt")
CAND=$(sed -n 's/^controlsFound=[0-9]* of [0-9]* trackMoveCandidates=\([0-9]*\)$/\1/p' "$WORK/out.txt")
if [ -z "$COUNT" ] || [ -z "$FOUND" ] || [ -z "$TOTAL" ] || [ -z "$CAND" ]; then
  echo "REVERIFY FAIL: the probe printed no tally line — its output shape changed."; exit 1; fi

# 1000 is well under the 2203 measured and well over anything a single visible screenful returns.
if [ "$COUNT" -lt 1000 ]; then
  echo "REVERIFY INCONCLUSIVE: only $COUNT commands read — the table was probably not fully walked,"
  echo "  and a census that saw one screenful finds no candidate for the wrong reason."
  exit 1
fi
if [ "$FOUND" -ne "$TOTAL" ]; then
  echo "REVERIFY FAIL: $FOUND of $TOTAL control commands found — the census is not seeing"
  echo "  Track-menu commands, so its silence about track moves says nothing."
  exit 1
fi
if [ "$CAND" -ne 0 ]; then
  echo "REVERIFY FAIL: $CAND key command(s) now look like they move a track — the wall has moved."
  echo "  That would be a better world; re-measure and update the record."
  grep "^candidate: " "$WORK/out.txt"
  exit 1
fi
echo "REVERIFY PASS — $COUNT key commands, $FOUND/$TOTAL controls found, none moves a track"
