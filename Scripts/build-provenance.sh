#!/usr/bin/env bash
# Bind a built executable to the CONTENT it was built from, so a later reader does not have to
# infer the relationship from timestamps.
#
# WHY. `evidence.py` records `built_from` — the WORKTREE's head — beside the binary's sha256, and
# nothing compares them. The field it sets honestly alongside is `built_from_is_measured: false`.
# The substitute check is an mtime comparison, and on 2026-09-08 it produced a FALSE POSITIVE: a
# rebase reapplied identical content, moved a source file's mtime, SwiftPM decided by content and
# relinked nothing, and a binary that was exactly what those sources produce read as stale. The
# live gate then refused a document whose every reading was clean.
#
# Timestamps cannot settle this in either direction. A build that finished and was then reverted
# leaves the binary newer than everything and says nothing; identical content with a newer mtime
# says nothing either. What settles it is hashing the same INPUTS the compiler consumed.
#
# WHAT IS BOUND, and what that does not prove. This hashes the tracked content of `Sources/`, the
# dependency pins, the toolchain identity and the build configuration, then names the executable's
# own sha256. Two builds agreeing on all of those should produce the same executable, and a
# disagreement means the artifact is not what the inputs describe. It does NOT prove the compiler
# was deterministic, that no untracked file participated, or that the executable was not replaced
# after this ran — the last of those is why the consumer re-hashes rather than trusting the record.
#
# Usage:
#   Scripts/build-provenance.sh emit  [<binary>]   write the binding beside the binary
#   Scripts/build-provenance.sh check [<binary>]   exit 0 bound, 1 mismatch, 2 cannot tell
set -uo pipefail

REPO="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "CANNOT-TELL(2): not a git repository" >&2; exit 2; }
cd "$REPO" || exit 2
BIN="${2:-$REPO/.build/release/LogicProMCP}"
SIDECAR="$BIN.provenance.json"

inputs_digest() {
    # Tracked Sources content, by CONTENT: `git hash-object` reads the file on disk, so an
    # uncommitted edit changes the digest. That is the point — the question is what the compiler
    # read, not what was committed.
    local list
    list=$(git ls-files -- Sources Package.swift 2>/dev/null) || return 2
    [ -n "$list" ] || return 2
    {
        printf '%s\n' "$list" | while IFS= read -r f; do
            [ -f "$f" ] || continue
            printf '%s  %s\n' "$(git hash-object -- "$f")" "$f"
        done
        # The COMMITTED pins, not the file on disk. Every `swift build` rewrites `Package.resolved`,
        # and this repository already treats that churn as noise — the ship gate restores it and
        # refuses a commit that carries it. Digesting the on-disk copy made the binding flap between
        # a build and its own gate: measured, two emits either side of one restore disagreed while
        # the executable's hash was identical. The pins that describe the build are the ones that
        # were committed.
        printf 'pins  %s\n' "$(git show HEAD:Package.resolved 2>/dev/null | shasum -a 256 | cut -d' ' -f1)"
        printf 'swift  %s\n' "$(swift --version 2>&1 | head -1)"
        printf 'config  %s\n' "${LPM_BUILD_CONFIG:-release}"
    } | shasum -a 256 | cut -d' ' -f1
}

case "${1:?usage: $0 emit|check [<binary>]}" in
  emit)
      [ -f "$BIN" ] || { echo "CANNOT-TELL(2): no binary at $BIN" >&2; exit 2; }
      D=$(inputs_digest) || { echo "CANNOT-TELL(2): could not digest the build inputs" >&2; exit 2; }
      python3 - "$SIDECAR" "$D" "$(shasum -a 256 "$BIN" | cut -d' ' -f1)" "$(git rev-parse HEAD)" <<'PY'
import json, sys
path, inputs, artifact, head = sys.argv[1:5]
json.dump({
    "schema": 1,
    "inputs_sha256": inputs,
    "artifact_sha256": artifact,
    # Recorded for a reader's convenience and deliberately NOT what `check` compares: a head is a
    # label, and the binding that matters is content to content.
    "head_at_build": head,
}, open(path, "w"), indent=1)
open(path, "a").write("\n")
print("bound " + artifact[:12] + " to inputs " + inputs[:12])
PY
      ;;
  check)
      [ -f "$BIN" ] || { echo "CANNOT-TELL(2): no binary at $BIN" >&2; exit 2; }
      [ -f "$SIDECAR" ] || { echo "CANNOT-TELL(2): no provenance beside $BIN — run: $0 emit" >&2; exit 2; }
      D=$(inputs_digest) || { echo "CANNOT-TELL(2): could not digest the build inputs" >&2; exit 2; }
      A=$(shasum -a 256 "$BIN" | cut -d' ' -f1)
      python3 - "$SIDECAR" "$D" "$A" <<'PY'
import json, sys
path, inputs, artifact = sys.argv[1:4]
try:
    rec = json.load(open(path))
except Exception as exc:
    print("CANNOT-TELL(2): unreadable provenance: {}".format(exc), file=sys.stderr); sys.exit(2)
problems = []
if rec.get("artifact_sha256") != artifact:
    problems.append("the executable has changed since it was bound")
if rec.get("inputs_sha256") != inputs:
    problems.append("the build inputs have changed since this executable was built")
if problems:
    for p in problems:
        print("MISMATCH: " + p, file=sys.stderr)
    sys.exit(1)
print("bound: artifact {} matches inputs {}".format(artifact[:12], inputs[:12]))
PY
      ;;
  *) echo "usage: $0 emit|check [<binary>]" >&2; exit 2 ;;
esac
