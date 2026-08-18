#!/usr/bin/env python3
"""Live proof that retiring five region routing rows took nothing reachable with it.

Usage:  LPM_EVIDENCE_ROOT=/abs/path/outside/repo \
        python3 live_575_region_stub_rows_retired.py <worktree> <full-40-char-head-sha>

WHAT WAS REMOVED
----------------
`region.select`, `region.loop`, `region.set_name`, `region.move` and `region.resize` had routing
rows. None of them had an implementation — the channel answered all five with a single arm:

    case "region.select", "region.loop", "region.set_name", "region.move", "region.resize":
        return .error("Region operations not yet implemented via AX")

A routing row says an operation is real and names the surfaces that may carry it. For these it named
a channel order for a refusal. The rows and the arm are gone; the operations now answer the way any
unknown one does.

WHAT THIS RUN CAN AND CANNOT SHOW
---------------------------------
The honest limit first, because it decides what the checks below are worth. Of the eight routed
`region.*` operations, exactly ONE is reachable from a tool: `region.get_regions`, as
`logic_project.get_regions`. `region.select_last` and `region.move_to_playhead` are implemented and
routed but reachable from no dispatcher, so no live call can exercise them — their survival is
visible in the table and in the unit suite, and this document does not claim otherwise.

So the live question is not "do the five still work" — they never did. It is whether removing five
named rows took anything reachable with it. The strongest available evidence for that is the
surviving sibling of the same family answering with a real inventory, plus a sweep of the reachable
read-only surface across every tool.

The removed names are probed too. That check is weak on its own: they answered `invalid_params`
before the change as well, because none of them was ever registered for a tool. It is recorded to
show the removal did not accidentally BIND them to something, not as evidence the removal was right.
"""

import json
import os
import subprocess
import sys
import time

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
# frame is 603,192 325x406, so this is 603,162 in window coordinates. Every call in this run is a
# read, so the assertion over it is a NEGATIVE one.
HEADER_BAND = (603, 162, 325, 406)


def osa(script):
    r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
    return (r.stdout or "").strip()


titles = osa('tell application "System Events" to tell process "Logic Pro" to '
             'return name of every window')
ev.check("575/precondition-an-arrange-window-is-open", "Tracks" in titles,
         "Logic is up with a project, so the surviving region operation has something to answer "
         "about and an empty inventory would mean something",
         f"titles={titles!r}", None)

rec = ev.record_screen(seconds=150)
before = ev.shot("575/before", settle_region=HEADER_BAND)

d = E.Driver()
time.sleep(4)

regions = d.tool("logic_project", "get_regions", {})
ev.note("575/get_regions", {k: v for k, v in regions.items() if k != "regions"}
        if isinstance(regions, dict) else {"raw": str(regions)[:200]})

ev.check("575/the-surviving-region-operation-still-answers",
         isinstance(regions, dict)
         and regions.get("error") is None
         and isinstance(regions.get("regions"), list)
         and isinstance((regions.get("_debug") or {}).get("track_headers"), int)
         and (regions["_debug"]["track_headers"]) > 0,
         "`region.get_regions` still routes, still reaches Accessibility and still comes back with "
         "a real inventory — the removal took five named rows and not the family that shares their "
         "prefix",
         f"error={regions.get('error') if isinstance(regions, dict) else None!r} "
         f"regions={len(regions.get('regions') or []) if isinstance(regions, dict) else None} "
         f"track_headers={(regions.get('_debug') or {}).get('track_headers') if isinstance(regions, dict) else None}",
         "remove `region.get_regions` alongside the five: the router stops recognising the "
         "operation and this call comes back with an error instead of an inventory")

# The reachable read-only surface, across every tool that has one. A removal's risk is in what it
# takes with it, and the table is shared by every operation in the server.
sweep = {
    "logic_system.health": d.tool("logic_system", "health", {}),
    "logic_system.permissions": d.tool("logic_system", "permissions", {}),
    "logic_project.is_running": d.tool("logic_project", "is_running", {}),
    "logic_midi.list_ports": d.tool("logic_midi", "list_ports", {}),
}
resources = {
    "logic://tracks": d.resource("logic://tracks"),
    "logic://mixer": d.resource("logic://mixer"),
    "logic://markers": d.resource("logic://markers"),
    "logic://transport/state": d.resource("logic://transport/state"),
}
ev.note("575/sweep", {k: str(v)[:160] for k, v in sweep.items()})
ev.note("575/resources", {k: str(v)[:160] for k, v in resources.items()})

broken = {k: v for k, v in sweep.items()
          if not isinstance(v, dict) or v.get("error") is not None}
unreadable = [k for k, v in resources.items() if not isinstance(v, dict)]
ev.check("575/every-reachable-read-only-operation-still-answers",
         not broken and not unreadable,
         "health, permissions, is_running, list_ports and the four state resources all answer "
         "without an error, so the five rows came out without disturbing the table they shared",
         f"broken={list(broken)} unreadable={unreadable}",
         "remove `system.health` from the table alongside them: the router stops recognising it "
         "and the dispatcher's answer never reaches the caller")

# Weak on its own — see the module docstring. Recorded so a reader can see the removal did not bind
# these names to something rather than freeing them.
removed = {name: d.tool("logic_project", name, {})
           for name in ("select", "loop", "set_name", "move", "resize")}
ev.note("575/removed", {k: str(v)[:160] for k, v in removed.items()})
ev.check("575/the-removed-names-did-not-become-reachable",
         all(isinstance(v, dict) and v.get("error") == "invalid_params"
             for v in removed.values()),
         "none of the five became reachable or started answering differently",
         f"{ {k: (v.get('error') if isinstance(v, dict) else None) for k, v in removed.items()} }",
         # No mutation: they answered `invalid_params` before the change too, because none of them
         # was ever registered for a tool. This check cannot tell the two versions apart.
         None)

after = ev.shot("575/after", settle_region=HEADER_BAND)
ev.visual("575/no-project-state-was-touched",
          before["file"], after["file"], HEADER_BAND, expect_change=False,
          why="every call in this run is a read, so the track-header rail must be byte-identical "
              "across it — a change here would mean a read path wrote something")

d.close()
ev.restored("575/nothing-to-restore", True,
            "this run performs reads only; no project state was changed, which the negative visual "
            "assertion above is the evidence for rather than a claim made here")
ev.stop_recording(rec)
out = ev.write()
print(json.dumps(out, indent=1))
sys.exit(0 if E.is_clean(out) else 1)
