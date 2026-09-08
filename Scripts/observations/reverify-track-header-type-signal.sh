#!/usr/bin/env bash
# Re-check 2026-09-08-the-track-header-carries-no-type-signal-in-english-either.
# NEEDS LOGIC PRO RUNNING with a project whose tracks are not all the same kind, and needs the
# accessibility permission the parent terminal holds.
#
# The claim under test is narrow: within the radius `inferTrackType` searches, the ONLY thing that
# varies between track headers is the track's name. So this fails the moment a header grows any
# other distinguishing field — which is the outcome worth being told about, because that field
# would be the type signal the classifier does not have.
set -uo pipefail
cd "$(dirname "$0")/../.."
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

swiftc -O Scripts/livekit/ax_track_type_signal_census.swift -o "$WORK/census" 2>"$WORK/build.err" || {
  echo "REVERIFY FAIL: the census probe did not compile"; cat "$WORK/build.err"; exit 1; }
"$WORK/census" > "$WORK/census.json" 2>"$WORK/run.err" || {
  echo "REVERIFY FAIL: the census probe did not run"; cat "$WORK/run.err"; exit 1; }

python3 - "$WORK/census.json" <<'PY'
import json, re, sys
d = json.load(open(sys.argv[1]))
if not d.get("ok"):
    print("REVERIFY FAIL: the probe reported", d.get("error")); sys.exit(1)

headers = d["headers"]
if len(headers) < 2:
    print("REVERIFY INCONCLUSIVE: %d header(s); one header cannot show what varies between headers"
          % len(headers)); sys.exit(1)

# A track stack's disclosure arrow is a real non-name difference, and it separates a STACK from a
# plain track — not audio from software instrument, which is what this record is about. It is named
# here so that it is an acknowledged exception rather than something the check silently tolerates.
STACK_ONLY = ("Track stack disclosure arrow", "AXRoleDescription=disclosure triangle")

unexplained = []
for h in headers:
    name = h["headerDescription"]
    quoted = re.search(r'[“"]([^”"]*)[”"]', name)
    bare = quoted.group(1) if quoted else name
    for field in h["notSharedByAllHeaders"]:
        if bare and bare in field:      # the name, or the description that quotes it
            continue
        if any(s in field for s in STACK_ONLY):
            continue
        unexplained.append((name, field))

print("  headers censused                     %d" % len(headers))
print("  fields every header carries          %d" % d["sharedByAllHeadersCount"])
print("  differing fields not explained by the name or a track stack: %d" % len(unexplained))
if unexplained:
    for n, f in unexplained[:20]:
        print("    %-32s %s" % (n[:32], f[:110]))
    print("REVERIFY FAIL: a header now carries a distinguishing field. Re-measure — this may be the")
    print("type signal the classifier lacks, in which case the record is superseded, not merely stale.")
    sys.exit(1)
print("REVERIFY PASS — the only thing that varies across track headers is still the track's name")
PY
