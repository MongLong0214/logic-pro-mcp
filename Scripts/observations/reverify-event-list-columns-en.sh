#!/usr/bin/env bash
# Re-check 2026-09-08-en-US-event-list-column-titles.
# NEEDS LOGIC PRO RUNNING with the Event pane open. Read-only.
#
# Logic renders TWO header schemas — six columns for the region list, eight for a selected region's
# events — and which one is on screen depends on the selection, not on this check. So instead of
# demanding one state, this identifies which schema is showing and validates it against that
# schema's expected titles. Neither shape matching is the failure; being in the other state is not.
set -uo pipefail
cd "$(dirname "$0")/../.."
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

swiftc -O Scripts/livekit/ax_event_list_header_cells.swift -o "$WORK/hdr" 2>"$WORK/build.err" || {
  echo "REVERIFY FAIL: the probe did not compile"; cat "$WORK/build.err"; exit 1; }
"$WORK/hdr" > "$WORK/hdr.json" 2>"$WORK/run.err" || {
  echo "REVERIFY FAIL: the probe did not run"; cat "$WORK/run.err"; exit 1; }

python3 - "$WORK/hdr.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
if not d.get("ok"):
    print("REVERIFY FAIL: the probe reported", d.get("error")); sys.exit(1)

cells  = d["headerCells"]
titles = [c["title"] for c in cells]
roles  = {(c["role"], c["subrole"]) for c in cells}
REGION = ["L", "M", "Position", "Name", "Trk", "Length"]
NOTE   = ["L", "M", "Position", "Status", "Ch", "Num", "Val", "Length/Info"]

print("  header cells   %d" % len(cells))
print("  roles seen     %s" % sorted(roles))
print("  titles         %s" % titles)

if roles != {("AXButton", "AXSortButton")}:
    print("REVERIFY FAIL: the header cells are no longer AXSortButton buttons: %s" % sorted(roles))
    print("The product reads titles off exactly those, so this is a read-path change, not a relabel.")
    sys.exit(1)
if titles == REGION:
    print("REVERIFY PASS — region-level schema, titles unchanged"); sys.exit(0)
if titles == NOTE:
    print("REVERIFY PASS — note-level schema, titles unchanged"); sys.exit(0)
print("REVERIFY FAIL: %d titles matching neither schema." % len(titles))
print("  region level expects %s" % REGION)
print("  note level expects   %s" % NOTE)
print("Logic has relabelled or restructured the header; every coverage claim citing this record is stale.")
sys.exit(1)
PY
