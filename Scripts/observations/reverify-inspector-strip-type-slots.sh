#!/usr/bin/env bash
# Re-check 2026-09-08-the-inspector-strip-slots-discriminate-track-type.
# NEEDS LOGIC PRO RUNNING with the Inspector open and at least one audio track and one software
# instrument track, and needs the accessibility permission the parent terminal holds.
#
# It changes the track selection while it runs and puts the original selection back.
#
# The claim under test is a rule, so it is checked as a rule and not as a count: some track shows
# an Input slot and no MIDI Effect slot, some track shows the reverse, and NO track shows both.
# The third clause is the one that makes the rule a discriminator rather than a coincidence, and
# it is the one a Logic update is most likely to break.
set -uo pipefail
cd "$(dirname "$0")/../.."
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

swiftc -O Scripts/livekit/ax_inspector_strip_type_census.swift -o "$WORK/strips" 2>"$WORK/build.err" || {
  echo "REVERIFY FAIL: the census probe did not compile"; cat "$WORK/build.err"; exit 1; }
"$WORK/strips" > "$WORK/strips.json" 2>"$WORK/run.err" || {
  echo "REVERIFY FAIL: the census probe did not run"; cat "$WORK/run.err"; exit 1; }

python3 - "$WORK/strips.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
if not d.get("ok"):
    print("REVERIFY FAIL: the probe reported", d.get("error")); sys.exit(1)

tracks = d["tracks"]
unsettled = [t["header"] for t in tracks if not t["settled"]]
if unsettled:
    print("REVERIFY FAIL: the inspector strip never agreed with the selected header for:",
          ", ".join(unsettled[:5]))
    print("A strip that was not confirmed to belong to the selected track cannot support this rule.")
    sys.exit(1)

audio  = [t["header"] for t in tracks if "Input slot" in t["slots"] and "MIDI Effect slot" not in t["slots"]]
instr  = [t["header"] for t in tracks if "MIDI Effect slot" in t["slots"] and "Input slot" not in t["slots"]]
both   = [t["header"] for t in tracks if "MIDI Effect slot" in t["slots"] and "Input slot" in t["slots"]]
neither= [t["header"] for t in tracks if "MIDI Effect slot" not in t["slots"] and "Input slot" not in t["slots"]]

print("  input slot only (audio-shaped)       %d" % len(audio))
print("  MIDI FX slot only (instrument-shaped) %d" % len(instr))
print("  both slots (would break the rule)    %d" % len(both))
print("  neither slot (unclassified here)     %d  %s" % (len(neither), neither[:3]))

if both:
    print("REVERIFY FAIL: %s shows both slots. The rule no longer discriminates." % both[0]); sys.exit(1)
if not audio or not instr:
    print("REVERIFY INCONCLUSIVE: this project does not contain both kinds, so nothing here could")
    print("have distinguished them. Open a project with an audio track and an instrument track.")
    sys.exit(1)
print("REVERIFY PASS — the input slot and the MIDI Effect slot still separate the two kinds")
PY
