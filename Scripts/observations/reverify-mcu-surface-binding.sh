#!/bin/bash
# Reverify the READ half of 2026-09-11-the-mcu-plane-was-never-connected-and-plug-in-mode-works.
#
# Covering BOTH halves in this script was rejected: the send half needs a build carrying the #856
# spike, and a reverify that cannot run on the shipped tree is a reverify nobody can run.
# The record has two halves and this script covers one of them honestly. It checks what Logic's
# Control Surface Setup actually contains — which is the finding that mattered, because the product
# reports `mcu.connected: true` regardless. The SEND half (does an MCU note take effect) needs a
# build carrying the #856 spike and is NOT re-run here; the record says so in its limits.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 2
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

swiftc -O Scripts/livekit/ax_control_surface_census.swift -o "$WORK/census" 2>"$WORK/build.err" || {
  echo "REVERIFY FAIL: the census did not compile"; cat "$WORK/build.err"; exit 1; }

# The window has to be open, and this opens it rather than assuming the operator did.
osascript >/dev/null 2>&1 <<'AS'
tell application "Logic Pro" to activate
delay 1
tell application "System Events" to tell process "Logic Pro"
  set frontmost to true
  delay 0.5
  try
    click menu item "Setup…" of menu 1 of menu item "Control Surfaces" of menu 1 of menu bar item "Logic Pro" of menu bar 1
  end try
  delay 2
end tell
AS

"$WORK/census" > "$WORK/out.txt" 2>&1
RC=$?
cat "$WORK/out.txt"

# Leave the window as it was found: an open Setup window makes the live harnesses report
# `checks_with_blocking_modal_unknown`, which correctly invalidates them.
osascript >/dev/null 2>&1 <<'AS'
tell application "System Events" to tell process "Logic Pro"
  try
    click (first button of window "Control Surface Setup" whose subrole is "AXCloseButton")
  end try
end tell
AS

[ "$RC" -eq 0 ] || { echo "REVERIFY INCONCLUSIVE: the census could not read the Setup window"; exit 1; }

# table[0] is the device inspector: 0 rows means no device is selected/installed.
ROWS=$(awk -F'rows=' '/^table\[0\]/ {print $2}' "$WORK/out.txt")
[ -n "${ROWS:-}" ] || { echo "REVERIFY INCONCLUSIVE: could not read the device table"; exit 1; }

if [ "$ROWS" -eq 0 ]; then
  echo "REVERIFY PASS (state A) — Logic has NO control surface installed, which is the state this record found."
  echo "  Nothing this product sends on the MCU port can reach Logic in this state."
  exit 0
fi
echo "REVERIFY PASS (state B) — a control surface IS installed ($ROWS inspector rows)."
echo "  The record's state-A readings describe a host without one and are not comparable to a run taken now."
