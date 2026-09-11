#!/bin/bash
# Reverify 2026-09-11-routing-slots-open-their-menus-and-a-destination-can-be-selected.
#
# This one MUTATES: it changes a channel strip's output, reads it back, and undoes it. The undo is
# not optional cleanup -- it is the last assertion, because a probe that leaves a project edited is
# not a measurement anyone can afford to re-run.
#
# The destination is deliberately NOT `No Output`. That is a legitimate choice which leaves the
# strip with no menu to open afterwards, and using it is how this repository first mistook its own
# test value for a wall.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 2
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
TARGET="${1:-Output 3-4}"

swiftc -O Scripts/livekit/ax_routing_slot_menu_probe.swift -o "$WORK/probe" 2>"$WORK/build.err" || {
  echo "REVERIFY FAIL: the probe did not compile"; cat "$WORK/build.err"; exit 1; }

# The Mute spelling for the positive control comes from AXLocalePolicy, not from the probe.
LABELS=$(python3 -c "
import sys; sys.path.insert(0, 'Scripts/livekit')
import evidence as E
E.REPO = '.'
print(' '.join(E.label_set('trackMuteButton')))
" 2>"$WORK/labels.err")
[ -n "${LABELS:-}" ] || { echo "REVERIFY FAIL: could not read AXLocalePolicy.trackMuteButton"; cat "$WORK/labels.err"; exit 1; }
# shellcheck disable=SC2086
"$WORK/probe" --mute-labels $LABELS --select "$TARGET" > "$WORK/out.txt" 2>&1
RC=$?
cat "$WORK/out.txt"
[ "$RC" -eq 2 ] && { echo "REVERIFY INCONCLUSIVE: the probe could not aim"; exit 1; }

field() { awk -F': ' -v k="$1" '$1 == k {print $2}' "$WORK/out.txt"; }
CONTROL=$(field "control mute moved")
MENUS=$(field "menus opened")
DISTINCT=$(field "distinct titles")
CHANGED=$(field "readback changed")
BEFORE=$(field "slot destination")
AFTER=$(field "destination after select")

# Undo FIRST, before any verdict, so a failed assertion never leaves the project edited.
# `activate` and `set frontmost` are load-bearing: osascript returns the menu item's name whether or
# not the click lands, so three undos silently did nothing when Logic was not frontmost.
if [ "${CHANGED:-0}" = "1" ]; then
  osascript >/dev/null 2>&1 <<'AS'
tell application "Logic Pro" to activate
delay 1
tell application "System Events" to tell process "Logic Pro"
  set frontmost to true
  delay 0.5
  click menu item 1 of menu 1 of menu bar item "Edit" of menu bar 1
  delay 2
end tell
AS
  RESTORED=$("$WORK/probe" --mute-labels $LABELS 2>/dev/null | awk -F': ' '$1 == "slot destination" {print $2}')
  echo "restored to: ${RESTORED:-<unreadable>}"
  [ "$RESTORED" = "$BEFORE" ] || {
    echo "REVERIFY FAIL: the undo did not restore '$BEFORE' — the project is left edited at '${RESTORED:-?}'"
    exit 1; }
fi

[ "${CONTROL:-0}" = "1" ] || {
  echo "REVERIFY INCONCLUSIVE: the CONTROL failed — a Mute that should move did not, so the readings say nothing"; exit 1; }
[ -n "${MENUS:-}" ] && [ "$MENUS" -ge 2 ] || {
  echo "REVERIFY FAIL: the press opened ${MENUS:-0} menu(s). This record says it opens them."; exit 1; }
[ -n "${DISTINCT:-}" ] && [ "$DISTINCT" -ge 20 ] || {
  echo "REVERIFY FAIL: only ${DISTINCT:-0} distinct enabled titles — a destination could not be named"; exit 1; }
[ "${RC}" -eq 3 ] && { echo "REVERIFY INCONCLUSIVE: '$TARGET' was absent or duplicated in this project"; exit 1; }
[ "${CHANGED:-0}" = "1" ] || {
  echo "REVERIFY FAIL: selecting '$TARGET' did not change the slot readback ('$BEFORE' -> '${AFTER:-?}')"; exit 1; }

echo "REVERIFY PASS — $MENUS menus, $DISTINCT distinct titles, '$BEFORE' -> '$AFTER' by name, undone"
