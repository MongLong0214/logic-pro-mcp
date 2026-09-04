#!/bin/bash
# Re-run the measurement behind docs/observations/2026-09-04-controls-view-popup-selection.json.
#
# Preconditions it CHECKS rather than assumes: Logic running, a plug-in editor open in Controls view
# (exactly one AXTable). It refuses instead of reporting an empty census, because "no popups found"
# and "popups found and empty" are different answers and only one of them is about Logic.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
BIN="${TMPDIR:-/tmp}/lpm-popup-census-$$"
trap 'rm -f "$BIN"' EXIT
swiftc -O "$HERE/popup-menu-census.swift" -o "$BIN" 2>/dev/null || { echo "cannot compile the census probe"; exit 2; }
OUT=$("$BIN")
printf '%s\n' "$OUT"
printf '%s' "$OUT" | python3 -c '
import json, sys
d = json.load(sys.stdin)
if d.get("error"):
    print("\nPRECONDITION: " + d["error"]); raise SystemExit(2)
pops = d.get("popups") or []
if not pops:
    print("\nPRECONDITION: the table exposes no AXPopUpButton — open a plug-in that has one"); raise SystemExit(2)
print(f"\n{len(pops)} popup(s) censused. Recorded verdict: selection is not addressable by name.")
print("Open each menu with the probe and compare item titles against the record; a menu that now")
print("lists its real choices, with distinct titles, DISAGREES with the record and needs a fresh one.")
'
