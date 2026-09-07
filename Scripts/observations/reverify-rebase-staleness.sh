#!/usr/bin/env bash
# Re-check 2026-09-07-a-rebase-makes-a-truthful-binary-read-as-stale.
#
# It reproduces the CAUSE, not the rebase: touching a source without changing its content is what
# a rebase does to mtimes, and the point is that the build then has nothing to relink.
set -uo pipefail
cd "$(dirname "$0")/../.."
B=.build/release/LogicProMCP
FAIL=0

swift build -c release >/dev/null 2>&1 || { echo "REVERIFY FAIL: release build failed"; exit 1; }
[ -f "$B" ] || { echo "REVERIFY FAIL: no release binary"; exit 1; }
BEFORE=$(stat -f %m "$B")

# A rebase moves the mtime of a file whose content it reapplies unchanged.
SRC=Sources/LogicProMCP/Qualification/ProductionReadinessContracts.swift
touch "$SRC"
swift build -c release >/dev/null 2>&1
AFTER=$(stat -f %m "$B")
SRC_M=$(stat -f %m "$SRC")

printf '  %-56s %s\n' "binary mtime unchanged by the no-op rebuild" "$([ "$BEFORE" = "$AFTER" ] && echo yes || echo no)"
printf '  %-56s %s\n' "source now newer than the binary" "$([ "$SRC_M" -gt "$AFTER" ] && echo yes || echo no)"
[ "$BEFORE" = "$AFTER" ] || { FAIL=1; echo "  FAIL the build relinked, so this machine does not show the effect"; }
[ "$SRC_M" -gt "$AFTER" ] || { FAIL=1; echo "  FAIL the source is not newer, so the comparison cannot fire"; }

# Leave the tree as found: a forced relink is the honest remedy, and `touch` on the binary is not.
rm -f "$B"; swift build -c release >/dev/null 2>&1
if ! git diff --quiet -- Package.resolved 2>/dev/null; then git checkout -- Package.resolved; fi

[ "$FAIL" -eq 0 ] || { echo "REVERIFY FAIL"; exit 1; }
echo "REVERIFY PASS — identical content moves the mtime and relinks nothing"
