#!/usr/bin/env python3
"""Live proof for track.create's mandatory-sheet retry (#538 follow-up) against the running Logic Pro.

Usage:  LPM_EVIDENCE_ROOT=/abs/path/outside/repo \
        python3 live_542_track_create_retry.py <worktree> <full-40-char-head-sha>

`live_538_modal_reconcile.py` drives the same mandatory "New Track" sheet, but it reaches it by DELETING
the last track. That is a different call site. `createTrackViaMenu` had its own single-pass reconcile, and
a sheet whose AXDescription publishes before its Create control classified correctly and then pressed
nothing — leaving Logic wedged on a sheet only Create can dismiss. A green 538 run says nothing about it.
This harness exercises `track.create_instrument` itself.

What is and is not independent here, stated rather than implied:

- The sheet count is read through System Events, a path the product does not use. A wedged sheet is exactly
  what the defect produced, so this is the load-bearing witness.
- The header-rail pixels are independent of AX entirely: a created track has to show up as a new row.
- A per-row track count through System Events is NOT available: Logic does not vend the "Track Headers"
  list at any depth System Events can address from the Tracks window (probed; `-1719` at the window, and
  no list under any of its groups). So the count below is the product's own read and is labelled as such —
  it corroborates, it does not witness.

The retry only fires when Logic publishes the sheet's description ahead of its Create control, which is a
timing race this harness cannot force. A pass here therefore proves the fix did not BREAK the common path
and that no sheet is left behind; the delayed-publish path itself is locked by the unit fixture, which was
watched to fail in both directions.

KNOWN RED: `542/create-is-certified-not-abandoned` currently fails, and the failure is true. Modal ABSENCE
is structurally unobservable on a live arrange window, so `track.create` never certifies State A even
though the track is created and nothing is blocking — issue #549, measured identically on the pre-fix
binary. The check stays as written. A harness that is edited until it agrees with the product has stopped
being an instrument, and this one found the defect precisely because it did not.
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
d = E.Driver()
rec = None


def tracks():
    """A `select` forces a live AX read; without it the resource answers with synthesised names."""
    d.tool("logic_tracks", "select", {"index": 0})
    return d.resource("logic://tracks").get("data", []) or []


def sheet_count():
    script = ('tell application "System Events" to tell process "Logic Pro" to '
              'get count of every sheet of (first window whose name ends with "Tracks")')
    r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
    return (r.stdout or "").strip()


win = E.logic_window()
if not win:
    ev.check("542/precondition-logic-window", False, "Logic's Tracks window is on screen",
             "no window found", "closed the Tracks window; this check went red")
    d.close()
    print(json.dumps(ev.write(), indent=1)); sys.exit(1)

RAIL = (0, int(win["h"] * 0.10), int(win["w"] * 0.20), int(win["h"] * 0.80))

# ---- precondition: no sheet is already up ----
#
# A sheet left over from an earlier run would make every claim below meaningless: the create would be
# refused, and "a sheet is present afterward" would be true for a reason that has nothing to do with the
# code under test. A stuck modal reads as a product failure when it is an environment failure.
before_sheets = sheet_count()
ok_pre = before_sheets == "0"
ev.check("542/precondition-no-sheet-is-already-up", ok_pre,
         "the run starts with no modal sheet on screen",
         f"sheets_before={before_sheets!r}",
         "started with the New Track sheet up; the create was refused and the run read as a code failure")
if not ok_pre:
    d.close()
    print(json.dumps(ev.write(), indent=1)); sys.exit(1)

before = tracks()
ev.note("precondition", {"count": len(before), "names": [x.get("name") for x in before],
                         "sheets_before": before_sheets})

rec = ev.record_screen(seconds=45)
pre = ev.shot("before-create", settle_region=RAIL)

# ---- the operation under test ----
body = d.tool("logic_tracks", "create_instrument")
time.sleep(2.0)
post = ev.shot("after-create", settle_region=RAIL)
ev.note("response", {"body": body})

state = body.get("state") if isinstance(body, dict) else None
verified = body.get("verified") if isinstance(body, dict) else None

ev.check("542/create-is-certified-not-abandoned",
         state == "A" and verified is True,
         "create returns State A, not the State B waiting_for_user the wedge produced",
         f"state={state!r} verified={verified!r} reason={body.get('reason')!r} "
         f"waiting_for_user={body.get('waiting_for_user')!r}",
         "removed the retry loop; a description-only first pass pressed nothing and this became State B")

after_sheets = sheet_count()
ev.check("542/no-sheet-is-left-behind",
         after_sheets == "0",
         "System Events, a path the product does not use, reports no sheet remains after the create",
         f"sheets_after={after_sheets!r}",
         "removed the retry loop; the mandatory sheet stayed up and this read 1, with Logic needing a "
         "human to clear it")

after = tracks()
ev.check("542/exactly-one-track-was-added",
         len(after) == len(before) + 1,
         "the project gained exactly one track — not zero (wedged) and not two (double-press)",
         f"before={len(before)} after={len(after)} names={[x.get('name') for x in after]}",
         "removed the actionAttempted break; the loop pressed Create again on the replacement sheet and "
         "the count rose by more than one")

ev.visual("542/a-new-row-appears-in-the-rail",
          pre["file"], post["file"], RAIL, expect_change=True,
          why="a created track has to be visible as a new header row, independent of any AX read")

# ---- restoration: leave the project as it was found ----
restored = False
detail = "no track was created, nothing to remove"
if len(after) == len(before) + 1:
    last = after[-1]
    d.tool("logic_tracks", "delete", {"index": last["id"], "expected_name": last.get("name")})
    time.sleep(1.5)
    final = tracks()
    restored = len(final) == len(before)
    detail = f"tracks_after_restore={len(final)} expected={len(before)}"
ev.restored("542/project-track-count-restored", restored, detail)

d.close()
ev.stop_recording(rec)
print(json.dumps(ev.write(), indent=1))
