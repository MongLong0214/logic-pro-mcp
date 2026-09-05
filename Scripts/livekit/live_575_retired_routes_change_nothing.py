#!/usr/bin/env python3
"""Live proof that retiring two unreachable table entries changed nothing reachable.

Usage:  LPM_EVIDENCE_ROOT=/abs/path/outside/repo \
        python3 live_575_retired_routes_change_nothing.py <worktree> <full-40-char-head-sha>

WHAT THIS IS FOR
----------------
`system.cache_state` and `system.refresh` were removed from the table. They had an empty channel
chain — which is not itself a defect: `system.health` and `system.permissions` share it and work,
because the dispatcher answers them directly and the entry only tells the router the operation is
real. What made these two dead is that nothing in `Sources/` named either, and `system.refresh` was
shadowed by the registered `system.refresh_cache` that every caller actually uses.

A removal's risk is not in what it deletes but in what it takes with it. So the assertions here are
about the NEIGHBOURS: the operations that share the empty-chain pattern, and the one that shadowed
the removed name, must all still work against the real application.

The removed names are checked too, but that check is weak on its own — they answered
`invalid_params` before the change as well. It is recorded for completeness, not as the proof.
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
# #622: this said "band over the arrange window's track headers" and the rectangle was
# (10, 120, 260, 220) — which is inside the LIBRARY, on the other side of the window. A read path
# that wrote to a track header could not have shown up there, so the negative assertion below has
# never been able to fail for the reason it exists.
#
# `Tracks header` is what AX calls the rail the claim is about, and it is unique in this window.
# Located rather than written down, with the name read back off the element that answered.
BAND_SOURCE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ax_control_bar_band.swift")
BAND_TOOL = os.path.join(ev.dir, "ax_control_bar_band")
subprocess.run(["swiftc", "-O", BAND_SOURCE, "-o", BAND_TOOL], check=True, capture_output=True)


def located_band(*selector):
    """(band, subject) for a named region, or (None, None) — never a fallback rectangle."""
    r = subprocess.run([BAND_TOOL, *selector], capture_output=True, text=True)
    try:
        payload = json.loads(r.stdout or "{}")
    except ValueError:
        return None, None
    b = payload.get("band")
    if not (isinstance(b, list) and len(b) == 4):
        return None, None
    return tuple(b), payload.get("description")


TRACK_BAND, TRACK_SUBJECT = located_band("Tracks header")


def osa(script):
    r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
    return (r.stdout or "").strip()


titles = osa('tell application "System Events" to tell process "Logic Pro" to '
             'return name of every window')
ev.check("575/precondition-the-track-header-rail-was-located",
         TRACK_BAND is not None and bool(TRACK_SUBJECT),
         "the rail this run asserts about, located by AXDescription rather than written down. A "
         "failed lookup is a red precondition, not a fallback rectangle",
         f"band={TRACK_BAND!r} subject={TRACK_SUBJECT!r}", None)

# `titles` is the AppleScript window list joined into one string, so this is a substring
# test. It carried ONE of the three spellings Logic uses, and `evidence.py` has held all
# three since #767 — a harness that knows one of them fails a precondition about a window
# that is open, and says "no arrange window" about a Logic that has one.
ev.check("575/precondition-an-arrange-window-is-open",
         any(spelling in titles for spelling in E.ARRANGE_WINDOW_TITLES),
         "Logic is up with a project, so the surviving operations have something to answer about",
         f"titles={titles!r} tried={E.ARRANGE_WINDOW_TITLES!r}",
         None)

rec = ev.record_screen(seconds=120)
before = ev.shot("575/before", settle_region=TRACK_BAND)

d = E.Driver()
time.sleep(3)

# The neighbours: same empty-chain pattern, and the operation that shadowed the removed name.
survivors = {
    "logic_system.health": d.tool("logic_system", "health", {}),
    "logic_system.permissions": d.tool("logic_system", "permissions", {}),
    "logic_system.refresh_cache": d.tool("logic_system", "refresh_cache", {}),
    "logic_project.is_running": d.tool("logic_project", "is_running", {}),
}

# A prefix neighbour of the three retired mixer rows. The removal was of three NAMED rows, not of a
# family, and this checks that against the running server rather than against the table.
#
# Deliberately not driven with valid parameters: proving the neighbour survives does not require
# moving the user's master volume. It is called with a parameter it rejects, and the discriminator is
# the HINT, not the error code — both a live command and a retired one answer `invalid_params`:
#
#   live command    "Unknown parameters: …  Allowed parameters: value, volume"   <- it validated input
#   retired command "Command '…' is not registered for …"                         <- it never existed
neighbour = d.tool("logic_mixer", "set_master_volume", {"definitely_not_a_param": "1"})
neighbour_hint = (neighbour.get("hint") or "") if isinstance(neighbour, dict) else ""
ev.note("575/prefix-neighbour", neighbour)
ev.check("575/a-prefix-neighbour-of-the-retired-rows-still-exists",
         "not registered" not in neighbour_hint and "Allowed parameters" in neighbour_hint,
         "mixer.set_master_volume still reaches its dispatcher and validates its input, so the "
         "removal took three named rows and not the family that shares their prefix",
         f"hint={neighbour_hint!r}",
         "remove `mixer.set_master_volume` alongside them: the hint becomes "
         "\"Command 'set_master_volume' is not registered\" and this check goes red")
ev.note("575/survivors", {k: str(v)[:300] for k, v in survivors.items()})

broken = {k: v for k, v in survivors.items()
          if not isinstance(v, dict) or v.get("error") is not None}
ev.check("575/the-operations-that-share-the-empty-chain-still-work",
         not broken,
         "health, permissions, refresh_cache and is_running all answer without an error — the "
         "empty-chain pattern survived the removal of two entries that used it",
         f"broken={list(broken)} keys={{k: sorted(v)[:4] for k, v in survivors.items() "
         f"if isinstance(v, dict)}}",
         "remove `system.health` or `system.permissions` from the table alongside them: the router "
         "stops recognising the operation and the dispatcher's answer never reaches the caller")

ev.check("575/refresh_cache-still-refreshes",
         isinstance(survivors["logic_system.refresh_cache"], dict)
         and survivors["logic_system.refresh_cache"].get("refreshed") is True,
         "the operation that shadowed the removed `system.refresh` still performs a refresh, so the "
         "removal took the dead name and not the live one",
         f"body={str(survivors['logic_system.refresh_cache'])[:200]}",
         "remove `system.refresh_cache` instead of `system.refresh` — the names differ by a suffix "
         "and the dead one is the shorter")

# Weak on its own: these answered the same way before the change. Recorded for completeness.
removed = {
    "logic_system.cache_state": d.tool("logic_system", "cache_state", {}),
    "logic_system.refresh": d.tool("logic_system", "refresh", {}),
    # The three whose CHANNEL had no case for them either — a stronger case for removal than the
    # two above, which at least named a channel that would have answered.
    "logic_mixer.set_output_volume": d.tool("logic_mixer", "set_output_volume", {}),
    "logic_mixer.get_bus_routing": d.tool("logic_mixer", "get_bus_routing", {}),
    "logic_tracks.get_parameter": d.tool("logic_tracks", "get_parameter", {}),
}
ev.note("575/removed", {k: str(v)[:200] for k, v in removed.items()})
ev.check("575/the-removed-names-are-still-unreachable",
         all(isinstance(v, dict) and v.get("error") == "invalid_params"
             for v in removed.values()),
         "neither removed name became reachable or started answering differently",
         f"{ {k: (v.get('error') if isinstance(v, dict) else None) for k, v in removed.items()} }",
         # No mutation: they answered `invalid_params` before the change too, so this check cannot
         # distinguish the two versions. It is here to show the removal did not accidentally BIND
         # them to something, not as evidence the removal was correct.
         None)

after = ev.shot("575/after", settle_region=TRACK_BAND)
ev.visual("575/no-project-state-was-touched",
          before["file"], after["file"], TRACK_BAND, expect_change=False, subject=TRACK_SUBJECT,
          why="every call in this run is a read or a cache refresh, so the arrange window's track "
              "headers must be byte-identical across it")

d.close()
ev.restored("575/nothing-to-restore", True,
            "the run performs no write; it reads health, permissions and running state and refreshes "
            "the cache, none of which changes the project")

ev.stop_recording(rec)
out = ev.write()
print(json.dumps(out, indent=1))
sys.exit(0 if E.is_clean(out) else 1)
