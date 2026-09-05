#!/usr/bin/env python3
"""Live proof that `record_sequence` works as the FIRST operation of a fresh server process.

Usage:  LPM_EVIDENCE_ROOT=/abs/path/outside/repo \
        python3 live_572_record_sequence_first_call.py <worktree> <full-40-char-head-sha>

WHAT WAS WRONG
--------------
`record_sequence` resets the playhead to bar 1 as a hard precondition before importing its SMF. As
the first operation of a fresh process that reset failed, every time:

    {"operation":"transport.goto_position","requested":"1.1.1.1","error":"ax_write_failed",
     "menu_state":"could_not_be_closed","menu_actuation_attempted":false,
     "dialog_actuation_attempted":false,"write_attempted":false}

Nothing was actuated, and no menu was open — an external System Events read counted zero.

WHAT THE MEASUREMENT SHOWED
---------------------------
Three samples each way on a freshly created project, same binary otherwise:

    with the pre-read at the channel's goto dispatch        OK  OK  OK
    with it removed                                        FAIL FAIL FAIL

and, from the isolation that led there: the same `transport.get_state` issued SECONDS EARLIER as a
separate request does not help (3/3 FAIL), while issued inside the request it does. Not elapsed
time, not the track count, not the parameter key.

Every caller that reached the operation through `TransportDispatcher.handleGotoPosition` was already
covered by its `liveTransportState` pre-read. `record_sequence` routes the operation directly and was
the only caller without it — so the read now belongs to the operation, where no caller can miss it.

THE TRIGGER IS "FIRST CALL", SO THE RUN PROTECTS IT
---------------------------------------------------
`record_sequence` must be the first TOOL call this driver makes. Anything issued before it — even a
resource read — changes the condition under test, and the run would pass while measuring the
second-call case, which never failed. The captures and the recording below use Quartz and
screencapture, not the product, precisely so they cannot warm it.
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
# Band over the arrange window's track lane area, where an imported region becomes visible.
# The arrange canvas, located by AXDescription. The rectangle that stood here spans x 280..980,
# and measured 2026-08-20 the canvas begins at x=928 — so all but the last fifty points of it lay
# over the Library, the Inspector and the track headers. An imported region is drawn in the canvas;
# this band was almost entirely somewhere else.
_CONTENTS, _CONTENTS_SUBJECT = ev.located_band("Tracks contents")
REGION_BAND = (_CONTENTS[0], _CONTENTS[1], 700, 220) if _CONTENTS else None
REGION_BAND_SUBJECT = f"{_CONTENTS_SUBJECT} — the first bars of the top lanes" if _CONTENTS else None
ev.check("572/precondition-the-arrange-canvas-was-located",
         REGION_BAND is not None and bool(REGION_BAND_SUBJECT),
         "a slice of the arrange canvas, offset into a region located by AXDescription",
         f"contents={_CONTENTS!r} band={REGION_BAND!r} subject={REGION_BAND_SUBJECT!r}", None)


def osa(script):
    r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
    return (r.stdout or "").strip()


def window_titles():
    return osa('tell application "System Events" to tell process "Logic Pro" to '
               'return name of every window')


def menus_open():
    raw = osa('tell application "System Events" to tell process "Logic Pro" to '
              'return count of (every menu bar item of menu bar 1 whose selected is true)')
    return int(raw) if raw.isdigit() else None


titles = window_titles()
# `titles` is the AppleScript window list joined into one string, so this is a substring
# test. It carried ONE of the three spellings Logic uses, and `evidence.py` has held all
# three since #767 — a harness that knows one of them fails a precondition about a window
# that is open, and says "no arrange window" about a Logic that has one.
ev.check("572/precondition-an-arrange-window-is-open",
         any(spelling in titles for spelling in E.ARRANGE_WINDOW_TITLES),
         "Logic has an arrange window, so there is a project to import into",
         f"titles={titles!r} tried={E.ARRANGE_WINDOW_TITLES!r}",
         None)

standing_menus = menus_open()
ev.check("572/precondition-no-menu-is-open-before-the-run", standing_menus == 0,
         "no menu bar item is selected, so a later `could_not_be_closed` cannot be blamed on one "
         "that was already standing",
         f"menus_open={standing_menus!r}",
         None)

rec = ev.record_screen(seconds=120)
before = ev.shot("572/before-first-call", settle_region=REGION_BAND)

# The driver is created HERE and record_sequence is its first tool call. Nothing above touched the
# product.
d = E.Driver()
result = d.tool("logic_tracks", "record_sequence", {"notes": "60,0,500;64,500,500;67,1000,500"})
time.sleep(2)
ev.note("572/first-call", result)

ev.check("572/record-sequence-succeeds-as-the-first-call-of-a-fresh-process",
         result.get("verified") is True,
         "the very first operation a fresh server process performs reaches a verified import",
         f"verified={result.get('verified')!r} error={result.get('error')!r} "
         f"message={str(result.get('message'))[:160]!r}",
         "remove the `runtime.transportState()` read from the channel's transport.goto_position "
         "dispatch: measured 3/3, record_sequence then fails its mandatory playhead reset with "
         "menu_state could_not_be_closed and menu_actuation_attempted false")

ev.check("572/the-playhead-reset-is-not-what-failed",
         "reset playhead" not in str(result.get("message") or ""),
         "the failure this issue is about — the mandatory reset to bar 1 — did not occur",
         f"message={str(result.get('message'))[:200]!r}",
         "remove the pre-read: the message becomes "
         "'record_sequence failed to reset playhead to bar 1 (required for accurate import)'")

ev.check("572/a-region-was-actually-created",
         bool(result.get("region_name")) and result.get("start_bar") == 1,
         "the import produced a MIDI region anchored at bar 1, which is what the reset exists for",
         f"region_name={result.get('region_name')!r} start_bar={result.get('start_bar')!r} "
         f"end_bar={result.get('end_bar')!r} created_track={result.get('created_track')!r}",
         "leave the playhead where it was: the SMF's bar offset is relative to tick 0, so the "
         "region lands at playhead+offset instead of at bar 1")

after = ev.shot("572/after-first-call", settle_region=REGION_BAND)
ev.visual("572/the-region-appears-in-the-arrange-window",
          before["file"], after["file"], REGION_BAND, subject=REGION_BAND_SUBJECT,
          expect_change=True,
          why="a new track carrying the imported region is drawn in the arrange area, so this band "
              "must differ across the call")

trailing_menus = menus_open()
ev.check("572/no-menu-was-left-standing",
         trailing_menus == 0,
         "the run leaves no menu open for the next operation to trip over",
         f"menus_open={trailing_menus!r}",
         "let the goto route abandon its menu: the next operation refuses with a blocking-dialog "
         "preflight that has nothing to do with it")

d.close()
ev.restored("572/the-imported-track-is-left-in-place",
            True,
            f"the run imports one sequence and leaves it: created_track="
            f"{result.get('created_track')!r}. Removing it would need a destructive delete this "
            f"run has no reason to perform, and the project is a scratch document.")

ev.stop_recording(rec)
out = ev.write()
print(json.dumps(out, indent=1))
sys.exit(0 if E.is_clean(out) else 1)
