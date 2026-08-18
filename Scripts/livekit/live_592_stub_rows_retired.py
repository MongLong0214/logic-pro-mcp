#!/usr/bin/env python3
"""Live proof that retiring six more table rows took nothing reachable with it.

Usage:  LPM_EVIDENCE_ROOT=/abs/path/outside/repo \
        python3 live_592_stub_rows_retired.py <worktree> <full-40-char-head-sha>

WHAT WAS REMOVED
----------------
`mixer.set_input`, `mixer.set_output`, `mixer.toggle_eq`, `mixer.reset_strip`, `plugin.list` and
`automation.get_mode` had rows in the channel table. None had an implementation — the accessibility
channel answered each with a refusal string — and for `toggle_eq` and `reset_strip` the `.mcu` the
row named FIRST had no arm either, so the table was promising a fallback that did not exist.

Two accessibility arms went with them without their rows: `mixer.set_send` and
`automation.set_mode`. Those two operations WORK — MCU carries the first, the key-command channel the
second — and neither routes through accessibility at all, so those arms were unreachable code that
made a working operation look unbuilt to anyone who grepped for it. That distinction is the point of
this change, and it is what the checks below are aimed at.

WHAT THIS RUN CAN AND CANNOT SHOW
---------------------------------
The six removed operations were registered for no tool, so no live call could reach them before or
after. Their absence is not what this run proves.

What it proves is that removing six named rows disturbed neither the families they sat in nor the
two operations whose arms were deleted. `mixer.set_master_volume` and `mixer.set_volume` share a
prefix with four of the removed rows; `plugin.get_inventory` shares one with `plugin.list`;
`tracks.set_automation` is the reachable automation surface. Each is probed, and the discriminator is
the HINT rather than the error code, because a live command and a retired one both answer
`invalid_params`:

    live command    "Unknown parameters: … Allowed parameters: …"   <- it validated input
    retired command "Command '…' is not registered for …"           <- it never existed
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
# The band is derived from the window at run time rather than measured once. The arrange window has
# moved display during this program — 1920x1050 landscape on one run, 1080x1890 portrait on another —
# and a rectangle measured against the first is not inside the second, which records as an unsettled
# capture straddling displays rather than as an honest failure.
HEADER_BAND = None   # resolved below, once the window's own frame is known


def osa(script):
    r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
    return (r.stdout or "").strip()


titles = osa('tell application "System Events" to tell process "Logic Pro" to '
             'return name of every window')
ev.check("592/precondition-an-arrange-window-is-open", "Tracks" in titles,
         "Logic is up with a project, so the surviving region operation has something to answer "
         "about and an empty inventory would mean something",
         f"titles={titles!r}", None)

win = E.logic_window("Tracks") or E.logic_window(None)
HEADER_BAND = (0, 0, win["w"], min(400, win["h"])) if win else None
ev.check("592/precondition-the-window-frame-is-known",
         HEADER_BAND is not None,
         "the arrange window's own frame read, so the capture band below is inside it — a band "
         "measured against a different display records as an unsettled straddling capture rather "
         "than as an honest result",
         f"window={win!r} band={HEADER_BAND!r}", None)
if HEADER_BAND is None:
    print(json.dumps(ev.write(), indent=1)); sys.exit(1)

rec = ev.record_screen(seconds=150)
before = ev.shot("592/before", settle_region=HEADER_BAND)

d = E.Driver()
time.sleep(4)

# The neighbours that share a prefix with a removed row. Called with a parameter they REJECT: proving
# a neighbour survives does not require moving the user's master volume, and the hint is what
# separates "validated my input" from "never existed".
neighbours = {
    "logic_mixer.set_master_volume": d.tool("logic_mixer", "set_master_volume", {"nope": "1"}),
    "logic_mixer.set_volume": d.tool("logic_mixer", "set_volume", {"nope": "1"}),
    "logic_plugins.get_inventory": d.tool("logic_plugins", "get_inventory", {"nope": "1"}),
    "logic_tracks.set_automation": d.tool("logic_tracks", "set_automation", {"nope": "1"}),
}
ev.note("592/neighbours", {k: str(v)[:200] for k, v in neighbours.items()})


def survived(body):
    """A command that reached its dispatcher: it either answered, or rejected a parameter by name."""
    if not isinstance(body, dict):
        return False
    hint = str(body.get("hint") or "")
    if "not registered" in hint:
        return False
    return body.get("error") is None or "Allowed parameters" in hint or "Unknown parameters" in hint


broken = [k for k, v in neighbours.items() if not survived(v)]
ev.check("592/the-prefix-neighbours-of-the-removed-rows-still-route",
         not broken,
         "mixer.set_master_volume, mixer.set_volume, plugins.get_inventory and tracks.set_automation "
         "all still reach their dispatchers — the removal took six named rows and not the families "
         "that share their prefixes",
         f"broken={broken} · hints="
         f"{ {k: str((v or {}).get('hint'))[:60] for k, v in neighbours.items()} }",
         "remove `mixer.set_master_volume` alongside them: its hint becomes \"Command "
         "'set_master_volume' is not registered\" and this check goes red")

# The two whose ARMS were deleted while their rows stayed cannot be probed live, and the first
# attempt at this check found that out the hard way:
#
#     mixer.set_send      -> "mixer.set_send is not exposed in the production MCP contract"
#     automation.set_mode -> no tool command at all
#
# Both are implemented — MCU carries the first, key commands the second — but neither is registered
# for a tool, so no live call reaches either. Their survival is a property of the table and the unit
# suite, and this document says so rather than dressing a probe of something else as evidence.
#
# What IS reachable on that surface is `tracks.set_automation`, and it is checked above with the
# other neighbours.
ev.note("592/not-live-probeable", {
    "mixer.set_send": "implemented on MCU, registered for no tool — table + unit suite only",
    "automation.set_mode": "implemented on the key-command channel, registered for no tool",
})

sweep = {
    "logic_system.health": d.tool("logic_system", "health", {}),
    "logic_project.is_running": d.tool("logic_project", "is_running", {}),
}
resources = {
    "logic://tracks": d.resource("logic://tracks"),
    "logic://mixer": d.resource("logic://mixer"),
}
broken_sweep = {k: v for k, v in sweep.items()
                if not isinstance(v, dict) or v.get("error") is not None}
unreadable = [k for k, v in resources.items() if not isinstance(v, dict)]
ev.check("592/the-reachable-read-only-surface-still-answers",
         not broken_sweep and not unreadable,
         "health, is_running and the state resources all answer, so six rows came out of the shared "
         "table without disturbing it",
         f"broken={list(broken_sweep)} unreadable={unreadable}",
         "remove `system.health` from the table alongside them: the router stops recognising it")

removed = {name: d.tool("logic_mixer", name, {})
           for name in ("set_input", "set_output", "toggle_eq", "reset_strip")}
ev.note("592/removed", {k: str(v)[:150] for k, v in removed.items()})
ev.check("592/the-removed-names-did-not-become-reachable",
         all(isinstance(v, dict)
             and v.get("error") in ("invalid_params", "command_not_exposed")
             for v in removed.values()),
         "none of the removed names became reachable or started answering differently",
         f"{ {k: (v.get('error') if isinstance(v, dict) else None) for k, v in removed.items()} }",
         # No mutation: they answered `invalid_params` before this change too, never having been
         # registered for a tool. This check cannot tell the two versions apart.
         None)

after = ev.shot("592/after", settle_region=HEADER_BAND)
ev.visual("592/no-project-state-was-touched",
          before["file"], after["file"], HEADER_BAND, expect_change=False,
          why="every call in this run is a read, so the track-header rail must be byte-identical "
              "across it — a change here would mean a read path wrote something")

d.close()
ev.restored("592/nothing-to-restore", True,
            "this run performs reads only; no project state was changed, which the negative visual "
            "assertion above is the evidence for rather than a claim made here")
ev.stop_recording(rec)
out = ev.write()
print(json.dumps(out, indent=1))
sys.exit(0 if E.is_clean(out) else 1)
