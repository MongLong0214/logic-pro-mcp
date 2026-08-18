#!/usr/bin/env python3
"""Live proof that retiring six more table rows took nothing reachable with it.

Usage:  LPM_EVIDENCE_ROOT=/abs/path/outside/repo \
        python3 live_592_stub_rows_retired.py <worktree> <full-40-char-head-sha>

WHAT WAS REMOVED
----------------
`mixer.set_input`, `mixer.set_output`, `mixer.toggle_eq`, `mixer.reset_strip`, `plugin.list` and
`automation.get_mode` had rows in the channel table. None was implemented anywhere: the accessibility
channel answered all six with a "not yet implemented via AX" string, and for `toggle_eq` and
`reset_strip` — which named `.mcu` FIRST — the MCU channel had no arm either, so the table promised a
fallback that did not exist.

Two more that look identical from the accessibility channel were deliberately kept, because they are
implemented on the channel their chain actually names:

    mixer.set_send        [.mcu]                              MCUChannel
    automation.set_mode   [.mcu, .midiKeyCommands, .cgEvent]  key command 84

Their accessibility arms were unreachable code — a reader grepping for the operation found a refusal
that is not what the operation does — so the arms went and the rows stayed.

WHAT THIS RUN CAN AND CANNOT SHOW
---------------------------------
None of the six was reachable from a tool, so no live call can demonstrate a behaviour change in
them. The removed names are probed for completeness, and that check names no mutation because it
cannot distinguish the two versions: they answered `invalid_params` before this change as well.

The load-bearing evidence is about the NEIGHBOURS. A removal's risk is not in what it deletes but in
what it takes with it, and `plugin.list` sat beside a `plugin.*` family that is very much alive.
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
CHOOSER_TITLES = ("Choose a Project", "프로젝트 선택")


def osa(script):
    r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
    return (r.stdout or "").strip()


def header_rail_band():
    """The rail band, derived at run time by the shared recorder.

    Was a local copy of the AppleScript; it now lives in `evidence.py` so the next harness gets it
    without rediscovering that `by` is a reserved word and that `first window whose name is …` can
    answer "invalid index" for a window that was just listed.
    """
    return E.track_header_band()


def windows():
    raw = osa('tell application "System Events" to tell process "Logic Pro" to '
              'return name of every window')
    return [t.strip() for t in raw.split(",") if t.strip()] if raw else []


titles = windows()
project_windows = [t for t in titles if not any(c in t for c in CHOOSER_TITLES)]
ev.check("592/precondition-a-project-is-open",
         bool(project_windows),
         "Logic has a project open, so the surviving neighbours have something to answer about and "
         "an empty answer would mean something",
         f"windows={titles!r}", None)

if not project_windows:
    print(json.dumps(ev.write(), indent=1)); sys.exit(1)

arrange_title = project_windows[0]
band = header_rail_band()
ev.check("592/precondition-the-track-header-rail-can-be-located",
         band is not None,
         "the rail's own AX frame is readable, so the visual assertion below watches the track "
         "headers rather than a rectangle measured on some earlier window shape",
         f"band={band!r} window={arrange_title!r}", None)

if band is None:
    d = None
    print(json.dumps(ev.write(), indent=1)); sys.exit(1)

rec = ev.record_screen(seconds=150)
before = ev.shot("592/before", settle_region=band, window_title=arrange_title)

d = E.Driver()
time.sleep(4)

# The prefix neighbours, driven with a parameter each one REJECTS. Proving a neighbour survives does
# not require moving the user's mixer, and the discriminator is the HINT rather than the error code:
# both a live command and a retired one answer `invalid_params`.
#
#   live command    "Unknown parameters: …  Allowed parameters: …"   <- it validated input
#   retired command "Command '…' is not registered for …"            <- it never existed
neighbours = {
    "logic_mixer.set_volume": d.tool("logic_mixer", "set_volume", {"definitely_not_a_param": "1"}),
    "logic_mixer.set_pan": d.tool("logic_mixer", "set_pan", {"definitely_not_a_param": "1"}),
    # Probed the same way as the mixer ones: `get_inventory` requires parameters, so calling it
    # bare answers `invalid_params` for a reason that has nothing to do with this removal. The
    # rejected-parameter form asks the only question that matters here — does it still resolve.
    "logic_plugins.get_inventory": d.tool("logic_plugins", "get_inventory",
                                          {"definitely_not_a_param": "1"}),
    "logic_tracks.set_automation": d.tool("logic_tracks", "set_automation",
                                          {"definitely_not_a_param": "1"}),
}
ev.note("592/neighbours", {k: str(v)[:200] for k, v in neighbours.items()})


def reached_its_dispatcher(body):
    if not isinstance(body, dict):
        return False
    if body.get("error") is None:
        return True
    hint = body.get("hint") or ""
    return "not registered" not in hint


unreached = [k for k, v in neighbours.items() if not reached_its_dispatcher(v)]
ev.check("592/the-prefix-neighbours-still-reach-their-dispatchers",
         not unreached,
         "`mixer.set_volume`, `mixer.set_pan`, `plugins.get_inventory` and `tracks.set_automation` "
         "all still resolve and validate their input — the removal took six named rows and not the "
         "mixer, plugin or automation families that share their prefixes",
         f"unreached={unreached} · "
         f"{ {k: (v.get('hint') or v.get('error') or 'ok')[:60] if isinstance(v, dict) else '?' for k, v in neighbours.items()} }",
         "remove `mixer.set_volume` alongside them: its hint becomes \"Command 'set_volume' is not "
         "registered for MCP tool 'logic_mixer'\" and this check goes red")

ev.check("592/the-plugin-family-still-resolves",
         reached_its_dispatcher(neighbours["logic_plugins.get_inventory"]),
         "`plugin.get_inventory` still reaches its dispatcher and validates its input — "
         "`plugin.list` was retired from beside it and the family it belongs to is untouched",
         f"{str(neighbours['logic_plugins.get_inventory'])[:220]}",
         "retire `plugin.get_inventory` instead of `plugin.list` — the names differ by a word and "
         "the live one is the longer")

sweep = {
    "logic_system.health": d.tool("logic_system", "health", {}),
    "logic_project.is_running": d.tool("logic_project", "is_running", {}),
    "logic_project.get_regions": d.tool("logic_project", "get_regions", {}),
}
resources = {
    "logic://tracks": d.resource("logic://tracks"),
    "logic://mixer": d.resource("logic://mixer"),
    "logic://transport/state": d.resource("logic://transport/state"),
}
broken = {k: v for k, v in sweep.items()
          if not isinstance(v, dict) or v.get("error") is not None}
unreadable = [k for k, v in resources.items() if not isinstance(v, dict)]
ev.check("592/every-reachable-read-only-operation-still-answers",
         not broken and not unreadable,
         "health, is_running, get_regions and the three state resources all answer without an "
         "error, so six rows came out of the shared table without disturbing it",
         f"broken={list(broken)} unreadable={unreadable}",
         "remove `system.health` from the table alongside them: the router stops recognising it and "
         "the dispatcher's answer never reaches the caller")

removed = {
    "logic_mixer.set_input": d.tool("logic_mixer", "set_input", {}),
    "logic_mixer.set_output": d.tool("logic_mixer", "set_output", {}),
    "logic_mixer.toggle_eq": d.tool("logic_mixer", "toggle_eq", {}),
    "logic_mixer.reset_strip": d.tool("logic_mixer", "reset_strip", {}),
    "logic_plugins.list": d.tool("logic_plugins", "list", {}),
    "logic_tracks.get_automation": d.tool("logic_tracks", "get_automation", {}),
}
ev.note("592/removed", {k: str(v)[:140] for k, v in removed.items()})
# Two shapes of refusal, both meaning unreachable, and the difference is the product being MORE
# specific than this check first assumed. The mixer dispatcher carries an explicit not-exposed list
# and answers `command_not_exposed`; the others fall through to `invalid_params` as unknown commands.
# Demanding one shape would have failed the run for the product being clearer.
UNREACHABLE = ("command_not_exposed", "invalid_params")
ev.check("592/the-removed-names-did-not-become-reachable",
         all(isinstance(v, dict) and v.get("error") in UNREACHABLE for v in removed.values()),
         "none of the six became reachable — each is refused either as an unknown command or by the "
         "mixer dispatcher's explicit not-exposed list",
         f"{ {k: (v.get('error') if isinstance(v, dict) else None) for k, v in removed.items()} }",
         # No mutation: they answered `invalid_params` before this change too, because none was ever
         # registered for a tool. This check cannot tell the two versions apart, and is here to show
         # the removal did not BIND them to something rather than free them.
         None)

after = ev.shot("592/after", settle_region=band, window_title=arrange_title)
ev.visual("592/no-project-state-was-touched",
          before["file"], after["file"], band, expect_change=False,
          why="every call in this run is a read or a write rejected before it was attempted, so the "
              "track-header rail must be byte-identical across it — a change here would mean one of "
              "those rejected writes was not rejected")

d.close()
ev.restored("592/nothing-to-restore", True,
            "this run performs reads and rejected writes only; the negative visual assertion above "
            "is the evidence for that rather than a claim made here")
ev.stop_recording(rec)
out = ev.write()
print(json.dumps(out, indent=1))
sys.exit(0 if E.is_clean(out) else 1)
