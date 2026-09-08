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
# TWICE, and they must agree. The probe settles on the strip reporting the selected track's NAME,
# and measured 2026-09-08 the name can arrive before the slots do: the first run after a rebuild put
# a `Studio Grand` strip in `neither`, and three runs after it were 1/19/1. A rule read once off a
# surface that is still catching up is a reading of the transition, not of the state.
"$WORK/strips" > "$WORK/strips.json" 2>"$WORK/run.err" || {
  echo "REVERIFY FAIL: the census probe did not run"; cat "$WORK/run.err"; exit 1; }
"$WORK/strips" > "$WORK/strips2.json" 2>>"$WORK/run.err" || {
  echo "REVERIFY FAIL: the census probe did not run a second time"; cat "$WORK/run.err"; exit 1; }

python3 - "$WORK/strips.json" "$WORK/strips2.json" <<'PY'
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

# An unreadable child list is not an empty one. A strip nobody could read reports no slots, lands in
# `neither`, and would let "NO strip shows both" stay green over a strip that might show both — the
# absence proved by an instrument that was not aimed. Found by review 2026-09-08.
unreadable = [t["header"] for t in tracks if not t.get("childrenReadable", False)]
if unreadable:
    print("REVERIFY FAIL: the child list was unreadable for %d strip(s): %s"
          % (len(unreadable), ", ".join(unreadable[:5])))
    print("A strip that could not be read cannot support a claim about what no strip shows.")
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
# THE SECOND PASS IS EVIDENCE TOO, so it is checked as evidence. Settlement and readability were
# validated on pass one only, and pass two was then compared against it — so a second pass whose
# strips never settled, or whose child lists could not be read, still decided whether the rule held.
# Found by a merge-gate inventory 2026-09-08.
second = json.load(open(sys.argv[2]))
if not second.get("ok"):
    print("REVERIFY FAIL: the second pass reported", second.get("error")); sys.exit(1)
unsettled2 = [t["header"] for t in second["tracks"] if not t["settled"]]
if unsettled2:
    print("REVERIFY FAIL: on the second pass the strip never agreed with the selected header for:",
          ", ".join(unsettled2[:5]))
    sys.exit(1)
unreadable2 = [t["header"] for t in second["tracks"] if not t.get("childrenReadable", False)]
if unreadable2:
    print("REVERIFY FAIL: on the second pass the child list was unreadable for %d strip(s): %s"
          % (len(unreadable2), ", ".join(unreadable2[:5])))
    sys.exit(1)
# BY POSITION, not by name. Nineteen of these tracks share a name with another, so a dict keyed on
# the header collapses them and a drift in one is invisible behind the last one that overwrote it.
# My own negative control found that: changing slot four of nine `Deluxe Classic` rows left this
# check green.
before = [(t["header"], t["slots"]) for t in tracks]
after = [(t["header"], t["slots"]) for t in second["tracks"]]
if len(before) != len(after):
    print("REVERIFY FAIL: pass 1 saw %d strips and pass 2 saw %d" % (len(before), len(after)))
    sys.exit(1)
moved = [i for i in range(len(before)) if before[i] != after[i]]
if moved:
    i = moved[0]
    print("REVERIFY FAIL: %d strip(s) read differently on a second pass, first at index %d (%s)"
          % (len(moved), i, before[i][0]))
    print("  pass 1 %s" % (before[i][1],))
    print("  pass 2 %s" % (after[i][1],))
    print("The inspector was still catching up; this is a reading of the transition, not the state.")
    sys.exit(1)

print("REVERIFY PASS — the input slot and the MIDI Effect slot still separate the two kinds")
PY
