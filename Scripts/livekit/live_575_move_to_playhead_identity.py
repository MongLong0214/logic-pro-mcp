#!/usr/bin/env python3
"""Live context for the same-region gate added to `region.move_to_playhead`.

Usage:  LPM_EVIDENCE_ROOT=/abs/path/outside/repo \
        python3 live_575_move_to_playhead_identity.py <worktree> <full-40-char-head-sha>

WHAT THE CHANGE IS
------------------
`defaultMoveSelectedRegionToPlayhead` reads "the selected region" before the Edit ▸ Move ▸ To
Playhead click and again after it, then returned State A whenever the post-read's start bar sat on
the playhead. Nothing required the two reads to be about the SAME region. A selection that drifted
during the click could therefore certify State A on a region the caller never asked about, purely
because it happens to sit on the playhead. `startBar` cannot be the identity that decides it — that
is the property the operation exists to change.

The gate now requires the same name AND the same track index, with a `trackIndex` of -1 treated as a
readback gap rather than a match.

WHAT THIS RUN CAN AND CANNOT SHOW — READ THIS FIRST
---------------------------------------------------
`region.move_to_playhead` is reachable from NO tool. There is no live call that reaches the changed
branch, and this document does not pretend otherwise. The branch is covered by unit tests, including
a mutation (`sameRegion = true`) that reddens only the two new drift tests.

What the run does show is two things a unit test cannot:

1. The reachable region surface is undisturbed. The change sits in the same file and leans on the
   same enumeration that `logic_project.get_regions` uses, so the observable half of that machinery
   is exercised against the real application.

2. Why the gate needs BOTH fields. Logic names regions non-uniquely — measured here, against the real
   project — so a same-name check on its own would let one region certify another. That is the
   measurement that makes the shape of the fix a finding rather than a preference.
"""

import json
import os
import subprocess
import sys
import time
from collections import Counter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import evidence as E  # noqa: E402

WT = sys.argv[1] if len(sys.argv) > 1 else ""
HEAD = sys.argv[2] if len(sys.argv) > 2 else ""
if not WT or not HEAD:
    sys.exit(__doc__)

E.REPO = WT
E.BIN = f"{WT}/.build/release/LogicProMCP"
missing = E.have_tools()
if missing:
    sys.exit(f"cannot run: missing {missing}")

ev = E.Evidence(HEAD, os.environ["LPM_EVIDENCE_ROOT"])
# Measured band over the track-header rail: the arrange window sits at 0,30 and the rail's own AX
# frame is 603,192 325x406, so this is 603,162 in window coordinates. Every call here is a read.
HEADER_BAND = (603, 162, 325, 406)


def osa(script):
    r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
    return (r.stdout or "").strip()


titles = osa('tell application "System Events" to tell process "Logic Pro" to '
             'return name of every window')
ev.check("575/precondition-an-arrange-window-is-open", "Tracks" in titles,
         "Logic is up with a project, so the region enumeration has something to read",
         f"titles={titles!r}", None)

rec = ev.record_screen(seconds=120)
before = ev.shot("575/before", settle_region=HEADER_BAND)

d = E.Driver()
time.sleep(4)

body = d.tool("logic_project", "get_regions", {})
regions = (body.get("regions") or []) if isinstance(body, dict) else []
names = Counter(r.get("name") for r in regions)
tracks = [r.get("trackIndex") for r in regions]
ev.note("575/inventory", {"count": len(regions), "names": dict(names),
                          "track_indexes": sorted(set(t for t in tracks if t is not None))})

ev.check("575/the-region-enumeration-still-works",
         isinstance(body, dict) and body.get("error") is None and len(regions) > 0,
         "`logic_project.get_regions` still routes, reaches Accessibility and returns regions — the "
         "observable half of the machinery the changed handler leans on is undisturbed",
         f"error={body.get('error') if isinstance(body, dict) else None!r} regions={len(regions)}",
         "break `enumerateRegionItems`' content-group lookup: this call returns a failure instead "
         "of an inventory")

duplicates = {name: n for name, n in names.items() if n > 1}
ev.check("575/logic-does-not-name-regions-uniquely",
         bool(duplicates),
         "more than one region on this project carries the same name, so a same-NAME check alone "
         "would let one region certify another — which is why the gate compares the track index too",
         f"duplicate names={duplicates} of {len(regions)} regions",
         # No mutation: this is a measurement of Logic's naming, not of this repository's code. It
         # is the reason the fix has the shape it has, and it is recorded as an observation that
         # could have come out the other way — a project of uniquely named regions would have left
         # the name-only check defensible.
         None)

ev.check("575/every-region-carries-a-placed-track-index",
         all(isinstance(t, int) and t >= 0 for t in tracks),
         "each region resolved to a real track, so the second half of the gate has a value to "
         "compare here; a -1 would be the enumeration saying it could not place the region, which "
         "the gate treats as a readback gap rather than as a match",
         f"track_indexes={sorted(set(tracks))}",
         "return -1 from the nearest-header match: the gate stops reaching State A at all, which is "
         "the fail-closed direction")

sweep = {
    "logic_system.health": d.tool("logic_system", "health", {}),
    "logic_project.is_running": d.tool("logic_project", "is_running", {}),
}
resources = {
    "logic://tracks": d.resource("logic://tracks"),
    "logic://transport/state": d.resource("logic://transport/state"),
}
broken = {k: v for k, v in sweep.items()
          if not isinstance(v, dict) or v.get("error") is not None}
unreadable = [k for k, v in resources.items() if not isinstance(v, dict)]
ev.check("575/the-reachable-surface-is-unchanged",
         not broken and not unreadable,
         "health, is_running and the state resources all still answer, so the edit to the region "
         "channel did not disturb anything a caller can reach",
         f"broken={list(broken)} unreadable={unreadable}",
         "return a hard error from `defaultGetRegions`: `logic://tracks` is unaffected but the "
         "region call above goes red, which is how the two checks divide the surface")

after = ev.shot("575/after", settle_region=HEADER_BAND)
ev.visual("575/no-project-state-was-touched",
          before["file"], after["file"], HEADER_BAND, expect_change=False,
          why="every call in this run is a read, so the track-header rail must be byte-identical "
              "across it — a change here would mean a read path wrote something")

d.close()
ev.restored("575/nothing-to-restore", True,
            "this run performs reads only; the negative visual assertion above is the evidence for "
            "that rather than a claim made here")
ev.stop_recording(rec)
out = ev.write()
print(json.dumps(out, indent=1))
sys.exit(0 if E.is_clean(out) else 1)
