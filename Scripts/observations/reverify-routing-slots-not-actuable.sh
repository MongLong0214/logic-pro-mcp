#!/bin/bash
# Reverify 2026-09-09-the-routing-slots-advertise-a-press-they-refuse.
#
# The record's claim is that a route is CLOSED, so this has to be able to come back FAIL for three
# different reasons, and each one is a way the first version of this check could have passed while
# the claim was false:
#
#   * the instrument is blind — the probe presses the strip's mute button every run and requires it
#     to move. A probe aimed at a stale element, or reading a signature that cannot see a change,
#     prints exactly what a wall prints;
#   * the probe did not find its subjects — fewer than two routing slots, or two of the same one;
#   * the wall MOVED — a press changed the slot or opened a menu. That is the good outcome and it
#     still fails here, because the record would then be wrong.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 2
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

swiftc -O Scripts/livekit/ax_routing_slot_actions.swift -o "$WORK/slots" 2>"$WORK/build.err" || {
  echo "REVERIFY FAIL: the probe did not compile"; cat "$WORK/build.err"; exit 1; }
"$WORK/slots" > "$WORK/out.txt" 2>&1
RC=$?
cat "$WORK/out.txt"
if [ "$RC" -ne 0 ]; then
  echo "REVERIFY FAIL: the probe exited $RC (no Logic, no inspector strip, or the control did not restore)"
  exit 1
fi

if ! grep -q "^controlMoved=true$" "$WORK/out.txt"; then
  echo "REVERIFY FAIL: the control did not move, so this run cannot see a working press."
  echo "  A slot that did not change is not evidence when the instrument is blind."
  exit 1
fi

# Both subjects must actually be present. Two Input slots would satisfy a bare count of two.
for SUBJECT in "Output slot" "Send slot"; do
  if ! grep -q "^${SUBJECT}" "$WORK/out.txt"; then
    echo "REVERIFY INCONCLUSIVE: no '${SUBJECT}' line — the strip was located but this subject was not."
    exit 1
  fi
done

ATTEMPTED=$(sed -n 's/^pressesAttempted=\([0-9]*\) .*/\1/p' "$WORK/out.txt")
MOVED=$(sed -n 's/^pressesAttempted=[0-9]* slotsThatMoved=\([0-9]*\)$/\1/p' "$WORK/out.txt")
if [ -z "$ATTEMPTED" ] || [ -z "$MOVED" ]; then
  echo "REVERIFY FAIL: the probe printed no tally line — its output shape changed."; exit 1; fi
if [ "$ATTEMPTED" -lt 2 ]; then
  echo "REVERIFY INCONCLUSIVE: $ATTEMPTED press(es) attempted; AXPress may no longer be advertised."
  exit 1
fi
if [ "$MOVED" -ne 0 ]; then
  echo "REVERIFY FAIL: $MOVED routing slot(s) MOVED on a press — the wall has moved."
  echo "  That would be a better world; re-measure and update the record."
  exit 1
fi
echo "REVERIFY PASS — the control moved, $ATTEMPTED routing slot press(es) changed nothing"
