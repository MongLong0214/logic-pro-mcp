#!/usr/bin/env bash
# Prove Scripts/build-provenance.sh binds by CONTENT, in both directions.
#
# The case that made this necessary: on 2026-09-08 a rebase reapplied identical content, moved a
# source file's mtime, SwiftPM relinked nothing, and the mtime heuristic called a correct binary
# stale — so the live gate refused a document whose every reading was clean. A replacement that only
# silences that direction would be worse than the heuristic, so the reverse cases are here too.
set -uo pipefail
cd "$(dirname "$0")/.."
P="Scripts/build-provenance.sh"
BIN=".build/release/LogicProMCP"
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }

[ -x "$BIN" ] || { echo "CANNOT-TEST(2): no release binary — run swift build -c release"; exit 2; }
SRC="Sources/LogicProMCP/Qualification/ProductionReadinessContracts.swift"
[ -f "$SRC" ] || { echo "CANNOT-TEST(2): fixture source missing"; exit 2; }

SAVED=$(mktemp) || exit 2
cp "$SRC" "$SAVED"
BINSAVE=$(mktemp) || exit 2
cp "$BIN" "$BINSAVE"
SIDESAVE=$(mktemp) || exit 2
[ -f "$BIN.provenance.json" ] && cp "$BIN.provenance.json" "$SIDESAVE"
restore() {
    cp "$SAVED" "$SRC"; cp "$BINSAVE" "$BIN"
    [ -s "$SIDESAVE" ] && cp "$SIDESAVE" "$BIN.provenance.json"
    rm -f "$SAVED" "$BINSAVE" "$SIDESAVE"
    if ! git diff --quiet -- Package.resolved 2>/dev/null; then git checkout -- Package.resolved; fi
}
trap restore EXIT

bash "$P" emit >/dev/null 2>&1 || { echo "CANNOT-TEST(2): emit failed"; exit 2; }
bash "$P" check >/dev/null 2>&1 && ok "a freshly emitted binding checks out" || no "emit then check failed"

# THE FALSE POSITIVE THIS REPLACES. Content identical, mtime moved.
touch "$SRC"
bash "$P" check >/dev/null 2>&1 && ok "a moved mtime with unchanged content stays BOUND" \
    || no "the mtime false positive survived"

# ...and the direction that must still fail.
echo "// mutation" >> "$SRC"
bash "$P" check >/dev/null 2>&1 && no "a real source change was called bound" \
    || ok "a real source change is a MISMATCH"
cp "$SAVED" "$SRC"

# The one mtime could never see: the executable replaced after it was bound.
printf '\0' >> "$BIN"
bash "$P" check >/dev/null 2>&1 && no "a replaced executable was called bound" \
    || ok "a replaced executable is a MISMATCH"
cp "$BINSAVE" "$BIN"

# Absence is cannot-tell, never a pass — the failure shape this repository keeps finding.
mv "$BIN.provenance.json" "$BIN.provenance.json.hidden"
bash "$P" check >/dev/null 2>&1; [ $? -eq 2 ] && ok "a missing binding is cannot-tell, not a pass" \
    || no "a missing binding did not stop the caller"
mv "$BIN.provenance.json.hidden" "$BIN.provenance.json"

echo
if [ "$FAIL" -ne 0 ]; then echo "FAIL: the provenance binding does not do what it claims"; exit 1; fi
echo "OK: $PASS case(s) — content binds the artifact, timestamps do not"
