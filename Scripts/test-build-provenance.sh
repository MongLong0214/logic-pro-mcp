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
# The pins as they are RIGHT NOW, committed or not. `emit` may rewrite them and the cleanup has to
# put back what it found rather than what the index holds.
PINSAVE=$(mktemp) || exit 2
PINABSENT=0
if [ -f Package.resolved ]; then cp Package.resolved "$PINSAVE"; else PINABSENT=1; fi
[ -f "$BIN.provenance.json" ] && cp "$BIN.provenance.json" "$SIDESAVE"
restore() {
    cp "$SAVED" "$SRC"; cp "$BINSAVE" "$BIN"
    [ -s "$SIDESAVE" ] && cp "$SIDESAVE" "$BIN.provenance.json"
    rm -f "$SAVED" "$BINSAVE" "$SIDESAVE"
    # RESTORE WHAT WAS THERE, not what git has. `git checkout -- Package.resolved` discards a
    # developer's UNCOMMITTED dependency edits — this suite runs `build-provenance.sh emit`, which
    # can rewrite the file, and the cleanup then reverted to HEAD and destroyed work it never saved.
    # Found by a merge-gate inventory 2026-09-08. A test that cleans up by deleting state it did not
    # capture is not cleaning up.
    if [ -s "$PINSAVE" ]; then
        cp "$PINSAVE" Package.resolved
    elif [ "$PINABSENT" = "1" ]; then
        rm -f Package.resolved
    fi
    rm -f "$PINSAVE"
}
trap restore EXIT

bash "$P" emit >/dev/null 2>&1 || { echo "CANNOT-TEST(2): emit failed"; exit 2; }
bash "$P" check >/dev/null 2>&1 && ok "a freshly emitted binding checks out" || no "emit then check failed"

# THE FALSE POSITIVE THIS REPLACES. Content identical, mtime moved.
touch "$SRC"
bash "$P" check >/dev/null 2>&1 && ok "a moved mtime with unchanged content stays BOUND" \
    || no "the mtime false positive survived"

# ...and the direction that must still fail.
#
# EXIT 1 EXACTLY, not "nonzero". `|| ok` fires on any failure, so a checker that crashed, could not
# read its inputs, or exited 2 for "cannot tell" would satisfy a case that means "it detected the
# mismatch". Caught by review 2026-09-08: both cases below were written that way and would have
# passed on a broken checker.
mismatches() { bash "$P" check >/dev/null 2>&1; [ "$?" -eq 1 ]; }

echo "// mutation" >> "$SRC"
mismatches && ok "a real source change is a MISMATCH" \
    || no "a real source change was not reported as a mismatch (want exit 1)"
cp "$SAVED" "$SRC"

# `emit` must REFUSE when an input is newer than the executable — that binary cannot have been
# built from that source, and binding them would mint a false provenance. Found by review
# 2026-09-08: emit hashed both sides independently and never checked that a build connected them.
touch "$SRC"
bash "$P" emit >/dev/null 2>&1; [ "$?" -eq 2 ] \
    && ok "emit REFUSES when an input is newer than the binary" \
    || no "emit minted a binding for a binary that predates its source"
touch "$BIN"                     # rebuild's effect on order, without a rebuild
bash "$P" emit >/dev/null 2>&1 && ok "emit proceeds once the binary is the newer of the two" \
    || no "emit refused a binary newer than every input"

# A FAILED READING MUST NOT BECOME A MEASUREMENT. `inputs_digest` read every input through
# `printf '...' "$(cmd)"`, where a failed substitution leaves an empty field that printf happily
# hashes — so a source file the tool could not read contributed a digest of nothing and `check`
# still reported BOUND. Found by a merge-gate inventory 2026-09-08 and reproduced with a `git` that
# fails only on `hash-object`: every file failed, stderr said so, and the digest came back clean.
STUBBIN=$(mktemp -d) || exit 2
trap 'rm -rf "$STUBBIN"' EXIT
cat > "$STUBBIN/git" <<'GITSTUB'
#!/bin/sh
if [ "$1" = "hash-object" ]; then echo "simulated hash-object failure" >&2; exit 1; fi
exec /usr/bin/git "$@"
GITSTUB
chmod +x "$STUBBIN/git"
PATH="$STUBBIN:$PATH" bash "$P" check >/dev/null 2>&1; [ "$?" -eq 2 ] \
    && ok "a source it cannot hash is CANNOT-TELL, not a binding" \
    || no "an unreadable source still produced a digest (want exit 2)"

# The one mtime could never see: the executable replaced after it was bound.
printf '\0' >> "$BIN"
mismatches && ok "a replaced executable is a MISMATCH" \
    || no "a replaced executable was not reported as a mismatch (want exit 1)"
cp "$BINSAVE" "$BIN"

# Absence is cannot-tell, never a pass — the failure shape this repository keeps finding.
mv "$BIN.provenance.json" "$BIN.provenance.json.hidden"
bash "$P" check >/dev/null 2>&1; [ $? -eq 2 ] && ok "a missing binding is cannot-tell, not a pass" \
    || no "a missing binding did not stop the caller"
mv "$BIN.provenance.json.hidden" "$BIN.provenance.json"

echo
if [ "$FAIL" -ne 0 ]; then echo "FAIL: the provenance binding does not do what it claims"; exit 1; fi
echo "OK: $PASS case(s) — content binds the artifact, timestamps do not"
