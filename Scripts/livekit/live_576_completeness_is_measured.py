#!/usr/bin/env python3
"""Live proof that the region inventory's `complete` flag is measured, not hardcoded.

Usage:  LPM_EVIDENCE_ROOT=/abs/path/outside/repo \
        python3 live_576_completeness_is_measured.py <worktree> <full-40-char-head-sha>

WHAT CHANGED
------------
`defaultGetRegions` published `complete: false` on every successful read. Safe, but uninformative —
and it made every consumer fail closed forever, which is why `midi.import_file` could not tell "no
region" from "no region visible" (#576).

It is now derived from the TRACK HEADERS, not from the regions. That distinction is the point: a
track carrying no regions produces no entry, so the highest observed `trackIndex` says nothing about
the tracks above it. `allTrackHeaders` is not viewport-limited — measured 21 of 21 while the region
layer stopped at 13 — so it is the denominator a completeness claim needs.

HOW THE TRIGGER IS ESTABLISHED
------------------------------
The arrange window exposes `AXSlider` with `AXDescription` `Vertical Zoom`. It is a write with a
readback, unlike `nav.zoom_to_fit`, which routes to `[.midiKeyCommands, .cgEvent]` and cannot prove
anything. Driving it moves tracks in and out of the viewport, so this run can produce BOTH answers
from the same project and show the flag following the observation rather than sitting on a constant.

A run that only ever saw one value would not distinguish a measured field from a hardcoded one. That
is why both directions are required below, and why the run refuses if it cannot produce them.
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
# Band over the arrange area's track-header column, in window coordinates.
#
# Measured rather than guessed, because the first attempt guessed and failed: at (10,120,260,320) the
# two captures hashed IDENTICALLY across a zoom change that the envelope showed working
# (in_viewport 6 -> 21). That rectangle is the Library browser, which vertical zoom does not touch.
# Live frames on this window (1920x1050 at 0,30):
#
#     Library    x 0..364     Inspector  x 366..601     arrange content  x 603..1920, y 117..
#
# so the header column starts just inside x=603, and y=90 is window-relative for the content's top.
HEADER_BAND = (610, 95, 190, 420)
ZOOM_TIGHT = 0.0     # every track visible
ZOOM_LOOSE = 0.6     # tall rows, most tracks pushed out of the viewport
MIN_TRACKS = 12      # below this the loose zoom may still fit everything


def osa(script):
    r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
    return (r.stdout or "").strip()


def zoom_script(body):
    return ('tell application "System Events" to tell process "Logic Pro"\n'
            'set w to first window whose name ends with "Tracks"\n'
            'repeat with g in (every group of w)\n'
            'repeat with e in (every UI element of g)\n'
            'try\n'
            'if (description of e as text) is "Tracks" then\n'
            'try\n'
            'set s to (first slider of e whose description is "Vertical Zoom")\n'
            f'{body}\n'
            'end try\n'
            'end if\n'
            'end try\n'
            'end repeat\n'
            'end repeat\n'
            'return "not found"\n'
            'end tell')


def read_zoom():
    raw = osa(zoom_script('return (value of s as text)'))
    try:
        return float(raw)
    except ValueError:
        return None


def set_zoom(value):
    raw = osa(zoom_script(f'set value of s to {value}\ndelay 0.8\nreturn (value of s as text)'))
    try:
        return float(raw)
    except ValueError:
        return None


d = E.Driver()
time.sleep(3)

original_zoom = read_zoom()
ev.check("576/precondition-the-vertical-zoom-slider-is-readable",
         original_zoom is not None,
         "the arrange window exposes a Vertical Zoom slider whose value can be read, which is what "
         "makes the viewport actuable with a readback rather than by a blind key command",
         f"value={original_zoom!r}",
         None)

# The track count comes from a LIVE AX read, not from `logic://tracks`.
#
# That resource is served from the poller's cache, and a run that reads it seconds after the server
# starts sees whatever has been polled by then — measured on this branch: `track_count=0` on a
# project with 21 tracks, which failed the precondition and stopped a run that had nothing wrong with
# it. `get_regions` reports `_debug.track_headers` from `allTrackHeaders()` at call time, which is the
# same number the completeness rule itself uses.
probe = d.tool("logic_project", "get_regions", {})
track_count = ((probe.get("_debug") or {}).get("track_headers") or 0) if isinstance(probe, dict) else 0
ev.check("576/precondition-enough-tracks-to-overflow-the-viewport",
         track_count >= MIN_TRACKS,
         f"the project has at least {MIN_TRACKS} tracks, read live rather than from the poller's "
         "cache, so a loose zoom can push some out of view and the two answers are genuinely "
         "different situations",
         f"track_headers={track_count}",
         None)

if original_zoom is None or track_count < MIN_TRACKS:
    d.close()
    print(json.dumps(ev.write(), indent=1)); sys.exit(1)

rec = ev.record_screen(seconds=150)


def inventory(tag, zoom):
    got = set_zoom(zoom)
    time.sleep(1.5)
    shot = ev.shot(tag, settle_region=HEADER_BAND)
    body = d.tool("logic_project", "get_regions", {})
    debug = body.get("_debug") or {}
    reading = {
        "requested_zoom": zoom, "observed_zoom": got,
        "complete": body.get("complete"), "scope": body.get("scope"), "reason": body.get("reason"),
        "headers": debug.get("track_headers"),
        "in_viewport": debug.get("track_headers_in_viewport"),
        "regions": len(body.get("regions") or []),
    }
    ev.note(f"576/{tag}", reading)
    return reading, shot


loose, loose_shot = inventory("576/zoom-loose", ZOOM_LOOSE)
tight, tight_shot = inventory("576/zoom-tight", ZOOM_TIGHT)

ev.check("576/the-flag-reports-incomplete-when-tracks-are-out-of-view",
         loose["complete"] is False
         and isinstance(loose["in_viewport"], int)
         and isinstance(loose["headers"], int)
         and loose["in_viewport"] < loose["headers"],
         "with tracks pushed out of the viewport the inventory says it is incomplete, and reports "
         "how far short it fell",
         f"{loose}",
         "hardcode `complete: false` again — this half keeps passing, which is exactly why the "
         "other direction below is required")

ev.check("576/the-flag-reports-complete-when-every-track-is-in-view",
         tight["complete"] is True
         and tight["in_viewport"] == tight["headers"]
         and tight["scope"] == "whole_arrangement"
         and tight["reason"] is None,
         "with every track inside the viewport the inventory says so, names the whole arrangement "
         "as its scope, and drops the viewport reason",
         f"{tight}",
         "restore the hardcoded `complete: false`: this check goes red while the incomplete case "
         "above stays green, which is the pair that tells a measured field from a constant")

ev.check("576/completeness-is-not-derived-from-the-regions",
         tight["headers"] == tight["in_viewport"] and tight["regions"] < tight["headers"],
         "at full coverage the region count is LOWER than the track count — a track with no regions "
         "produces no entry, so the regions cannot be the denominator",
         f"headers={tight['headers']} in_viewport={tight['in_viewport']} regions={tight['regions']}",
         "derive completeness from the observed trackIndex range instead: this project has a track "
         "with no region, so that derivation reports short of the truth and never reaches complete")

ev.visual("576/the-viewport-actually-moved",
          loose_shot["file"], tight_shot["file"], HEADER_BAND, expect_change=True,
          why="the two readings come from genuinely different viewports, not from two calls against "
              "the same screen — the track-header band must differ between them")

restored = set_zoom(original_zoom)
ev.restored("576/vertical-zoom-put-back",
            restored is not None and abs(restored - original_zoom) < 0.02,
            f"vertical zoom restored to {restored!r} (found at {original_zoom!r}); the run changes "
            f"only this view setting and puts it back")

d.close()
ev.stop_recording(rec)
out = ev.write()
print(json.dumps(out, indent=1))
sys.exit(0 if E.is_clean(out) else 1)
