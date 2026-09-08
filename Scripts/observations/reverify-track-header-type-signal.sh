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

# ESTABLISH THE PRECONDITION RATHER THAN ASSUMING IT. The claim is that nothing varies WITH THE KIND
# of track, and a project whose tracks are all one kind cannot support it — two same-kind headers
# differing only by name would reach PASS and prove nothing. The header carries no kind (that is the
# finding), so the kinds come from the inspector strip, where they are readable. Found by review
# 2026-09-08: this script asked only for two headers.
swiftc -O Scripts/livekit/ax_inspector_strip_type_census.swift -o "$WORK/strips" 2>>"$WORK/build.err" || {
  echo "REVERIFY FAIL: the strip probe did not compile"; cat "$WORK/build.err"; exit 1; }
"$WORK/strips" > "$WORK/strips.json" 2>>"$WORK/run.err" || {
  echo "REVERIFY FAIL: the strip probe did not run"; cat "$WORK/run.err"; exit 1; }

python3 - "$WORK/census.json" "$WORK/strips.json" <<'PY'
import json, re, sys
d = json.load(open(sys.argv[1]))
if not d.get("ok"):
    print("REVERIFY FAIL: the probe reported", d.get("error")); sys.exit(1)

headers = d["headers"]
if len(headers) < 2:
    print("REVERIFY INCONCLUSIVE: %d header(s); one header cannot show what varies between headers"
          % len(headers)); sys.exit(1)

strips = json.load(open(sys.argv[2]))
if not strips.get("ok"):
    print("REVERIFY INCONCLUSIVE: the strip probe reported", strips.get("error"))
    print("Without it the mixed-kind precondition is unestablished, so a PASS would mean nothing.")
    sys.exit(1)
if any(not t.get("childrenReadable", False) for t in strips["tracks"]):
    print("REVERIFY INCONCLUSIVE: a strip's child list was unreadable, so the kinds present here")
    print("cannot be established, and neither can this check's precondition.")
    sys.exit(1)
kinds = set()
for t in strips["tracks"]:
    has_input = "Input slot" in t["slots"]
    has_midifx = "MIDI Effect slot" in t["slots"]
    if has_input and not has_midifx:
        kinds.add("audio")
    elif has_midifx and not has_input:
        kinds.add("instrument")
if len(kinds) < 2:
    print("REVERIFY INCONCLUSIVE: the strips show %d distinguishable kind(s) %s. This project cannot"
          % (len(kinds), sorted(kinds) or "[]"))
    print("show that a header varies with KIND, because it does not contain two kinds. Open a")
    print("project with an audio track and a software instrument track.")
    sys.exit(1)
print("  kinds present (from the strips)      %s" % sorted(kinds))

# A track stack's disclosure arrow is a real non-name difference, and it separates a STACK from a
# plain track — not audio from software instrument, which is what this record is about. It is named
# here so that it is an acknowledged exception rather than something the check silently tolerates.
STACK_ONLY = ("Track stack disclosure arrow", "AXRoleDescription=disclosure triangle")

unexplained = []
for h in headers:
    name = h["headerDescription"]
    quoted = re.search(r'[“"]([^”"]*)[”"]', name)
    bare = quoted.group(1) if quoted else name
    # The two fields the NAME accounts for, matched exactly — not "any field containing the name".
    # `bare in field` discards a whole field for any name that happens to be a substring of it, so a
    # track called `e` erased every differing field and the check passed by explaining nothing.
    # Found by a merge-gate inventory 2026-09-08. The census emits exactly two name-derived fields
    # per header, and those are what may be excused.
    explained_by_name = {"AXDescription=" + bare, "AXDescription=" + name} if bare else set()
    for field in h["notSharedByAllHeaders"]:
        if field in explained_by_name:
            continue
        if any(s in field for s in STACK_ONLY):
            continue
        unexplained.append((name, field))

# The sweep's REACH, before anything it found. A failed child read contributes no fields and looks
# exactly like a subtree with none, so an absence read from it is an absence the instrument could not
# see into. Measured 2026-09-08: 60, stably, across 21 headers.
child_failures = d.get("childReadFailures")
if child_failures is None:
    print("REVERIFY FAIL: this probe does not report childReadFailures, so its reach is unknown")
    sys.exit(1)
if child_failures > 60:
    print("REVERIFY FAIL: %d unreadable child lists, more than the 60 this record was measured with"
          % child_failures)
    sys.exit(1)
print("  child lists that could NOT be read   %d" % child_failures)
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
