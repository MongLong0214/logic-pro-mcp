#!/bin/bash
# Reverify 2026-09-09-the-routing-slots-advertise-a-press-they-refuse.
#
# The record's claim is that a route is CLOSED, so the probe must be shown to have found the slots
# before its report means anything: a run that located no strip would print no slot lines and read
# as a confirmation of the wall.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 2
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

swiftc -O Scripts/livekit/ax_routing_slot_actions.swift -o "$WORK/slots" 2>"$WORK/build.err" || {
  echo "REVERIFY FAIL: the probe did not compile"; cat "$WORK/build.err"; exit 1; }
"$WORK/slots" > "$WORK/out.txt" 2>&1 || {
  echo "REVERIFY FAIL: the probe did not run"; cat "$WORK/out.txt"; exit 1; }

FOUND=$(grep -c "slot" "$WORK/out.txt" || true)
if [ "$FOUND" -lt 2 ]; then
  echo "REVERIFY INCONCLUSIVE: found $FOUND routing slot(s) — the strip was probably not located,"
  echo "  and an instrument that found nothing has not established that a press is refused."
  cat "$WORK/out.txt"; exit 1
fi
if grep -q "enabled=true" "$WORK/out.txt"; then
  echo "REVERIFY FAIL: a routing slot now reports AXEnabled=true — the wall may have moved."
  grep "enabled=true" "$WORK/out.txt"
  echo "  That would be a better world; re-measure the press and update the record."
  exit 1
fi
echo "REVERIFY PASS — $FOUND routing slot(s), all AXEnabled=false while advertising AXPress"
