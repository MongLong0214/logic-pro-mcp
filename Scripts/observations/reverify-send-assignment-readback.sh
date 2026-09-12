#!/bin/bash
# Reverify 2026-09-12-a-send-can-be-assigned-by-name-and-is-not-named-back-at-the-source.
#
# This one MUTATES: it assigns a send on a real channel strip. The undo is the last assertion, not
# tidying — a probe that leaves a project edited is not a measurement anyone can afford to re-run.
#
# The witness for "did it land" is LOGIC'S OWN undo entry, never the slot's readback. The slot's
# readback is the thing under question here and cannot also be the evidence for it.
#
#   Scripts/observations/reverify-send-assignment-readback.sh [destination-title]
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 2
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
TARGET="${1:-Bus 12}"

swiftc -O Scripts/livekit/ax_routing_slot_menu_probe.swift -o "$WORK/probe" 2>"$WORK/e" || {
  echo "REVERIFY FAIL: the probe did not compile"; cat "$WORK/e"; exit 1; }
swiftc -O Scripts/livekit/ax_edit_stack_menu_census.swift -o "$WORK/edit" 2>>"$WORK/e" || {
  echo "REVERIFY FAIL: the Edit-menu census did not compile"; cat "$WORK/e"; exit 1; }

echo "-- the menu offers (a title must be chosen from THIS list, never guessed):"
"$WORK/probe" --slot-prefix "Send slot" --print-titles 8 | grep '^title:'

echo "-- assigning ${TARGET}"
"$WORK/probe" --slot-prefix "Send slot" --select "$TARGET" | grep -E 'control mute|menus opened|destination after|readback changed|selected'

echo "-- Logic's own undo entry (the witness that the edit happened):"
"$WORK/edit" | python3 -c "import sys,json;d=json.load(sys.stdin);print((d.get('entries') or [{}])[0].get('title'))"

echo "-- every send slot on the source strip:"
"$WORK/probe" --slot-prefix "Send slot" --dump-slots | grep '^slot\[' | head -12

echo "-- undoing"
osascript -e 'tell application "Logic Pro" to activate' -e 'delay 0.8' \
  -e 'tell application "System Events" to tell process "Logic Pro" to click menu item 1 of menu 1 of menu bar item "Edit" of menu bar 1' >/dev/null 2>&1
sleep 2
echo "-- undo entry after the undo (expected: Can’t Undo, i.e. the stack is back):"
"$WORK/edit" | python3 -c "import sys,json;d=json.load(sys.stdin);print((d.get('entries') or [{}])[0].get('title'))"
