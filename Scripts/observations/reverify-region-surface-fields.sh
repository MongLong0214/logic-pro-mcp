#!/usr/bin/env bash
# Re-check 2026-09-08-the-region-surface-has-no-ticks.
#
# Needs Logic running with a project open and a release binary: the claim is about what a LIVE
# region publishes, and a fixture would answer a different question.
set -uo pipefail
cd "$(dirname "$0")/../.."
[ -x .build/release/LogicProMCP ] || { echo "REVERIFY FAIL: no release binary — run swift build -c release"; exit 1; }
pgrep -x "Logic Pro" >/dev/null || { echo "REVERIFY FAIL: Logic Pro is not running"; exit 1; }

OUT=$(python3 - <<'PY'
import json, sys
sys.path.insert(0, "Scripts/livekit")
import evidence as E
d = E.Driver(binary=".build/release/LogicProMCP")
try:
    r = d.tool("logic_project", "get_regions", {}) or {}
    regs = r.get("regions") or []
    fields = sorted({k for reg in regs for k in reg})
    print("FIELDS " + ",".join(fields))
    print("COUNT %d" % len(regs))
finally:
    d.close()
PY
) || { echo "REVERIFY FAIL: could not read regions"; exit 1; }

printf '%s\n' "$OUT" | sed 's/^/  /'
EXPECTED="FIELDS endBar,kind,name,rawHelp,startBar,trackIndex"
FAIL=0
printf '%s\n' "$OUT" | grep -qxF "$EXPECTED" || { FAIL=1; echo "  FAIL expected exactly: $EXPECTED"; }
# The point of the record: no tick, no ordinal. Stated as its own check so a future field that
# ADDS one is reported as the finding it would be, rather than as a formatting difference.
printf '%s\n' "$OUT" | grep -qiE "tick|ordinal" && { FAIL=1; echo "  FAIL a tick or ordinal now appears — the wall in this record has moved"; }

[ "$FAIL" -eq 0 ] || { echo "REVERIFY FAIL — the region surface no longer matches the record"; exit 1; }
echo "REVERIFY PASS — six fields, no tick, no ordinal"
