#!/usr/bin/env bash
# Re-check 2026-09-08-no-element-declares-a-colour-attribute.
# NEEDS LOGIC PRO RUNNING with a project open, and the accessibility permission the parent
# terminal holds. Read-only: it changes nothing in Logic.
#
# The claim is an absence, so the checks that matter are the ones proving the instrument was aimed:
# a sweep that visited nothing, or whose name calls were failing, would report the same empty match
# list as a real absence. Zero failures AND zero empty name lists AND a plausible element count are
# what separate "not declared" from "not looked at".
set -uo pipefail
cd "$(dirname "$0")/../.."
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

swiftc -O Scripts/livekit/ax_attribute_name_census.swift -o "$WORK/census" 2>"$WORK/build.err" || {
  echo "REVERIFY FAIL: the census probe did not compile"; cat "$WORK/build.err"; exit 1; }
"$WORK/census" color > "$WORK/census.json" 2>"$WORK/run.err" || {
  echo "REVERIFY FAIL: the census probe did not run"; cat "$WORK/run.err"; exit 1; }

python3 - "$WORK/census.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
if not d.get("ok"):
    print("REVERIFY FAIL: the probe reported", d.get("error")); sys.exit(1)

visited = d["elementsVisited"]
fails   = d["nameCallFailures"]
empties = d["emptyNameLists"]
inwin   = d["matchesInWindow"]
onhdr   = d["matchesOnTrackHeaders"]

print("  elements visited                     %d" % visited)
print("  distinct attribute names in window   %d" % d["attributeNamesInWindowCount"])
print("  name calls that FAILED               %d" % fails)
print("  elements answering an EMPTY list     %d" % empties)
print("  colour-bearing names in the window   %d  %s" % (len(inwin), inwin[:5]))

if fails or empties:
    print("REVERIFY FAIL: the sweep could not read %d element(s), so an empty result proves nothing"
          % (fails + empties))
    sys.exit(1)

# CHILD reads, not only name reads. The first version of this check counted the elements whose
# ATTRIBUTE-NAME call failed and never asked how many child lists could not be read — so a subtree
# the walk never entered contributed no names and looked like a subtree with nothing to declare.
# Measured 2026-09-08 after a merge-gate inventory flagged the class: 20 elements answer
# kAXErrorFailure (-25200) to a child read, stably across three runs. The record's claim is scoped
# to what the sweep reached, and this is the number that scopes it.
child_failures = d.get("childReadFailures")
if child_failures is None:
    print("REVERIFY FAIL: this probe does not report childReadFailures, so the sweep's reach is")
    print("unknown and an absence read from it cannot be scoped.")
    sys.exit(1)
print("  child lists that could NOT be read   %d" % child_failures)
if child_failures > 20:
    print("REVERIFY FAIL: %d unreadable child lists, more than the 20 this record was measured with."
          % child_failures)
    print("The sweep now reaches less than it did; re-measure before citing the record.")
    sys.exit(1)
if visited < 200:
    print("REVERIFY FAIL: only %d elements were reachable. That is not the window this was measured"
          % visited)
    print("on; open a project before concluding anything from an absence.")
    sys.exit(1)
if inwin or onhdr:
    print("REVERIFY FAIL: a colour-bearing attribute is now declared: %s" % (inwin + onhdr)[:5])
    print("This record is superseded, not stale — go and read it, the readback may now exist.")
    sys.exit(1)
print("REVERIFY PASS — no element in the main window declares a colour-bearing attribute")
PY
