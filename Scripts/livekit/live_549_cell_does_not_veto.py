#!/usr/bin/env python3
"""Live proof that #549's trigger no longer withholds State A, and that the scan is not blinded.

Usage:  LPM_EVIDENCE_ROOT=/abs/path/outside/repo \
        python3 live_549_cell_does_not_veto.py <worktree> <full-40-char-head-sha>

The trigger is a MARKER ROW, not the Marker List window. One `AXCell` in that window's table answers
`AXChildren` with -25200 on every read; with zero markers the row does not exist and neither does the
failure. That is why this looked intermittent for hours — the other harnesses delete markers, so a run
following one found an empty table and certified normally with the window still open.

So this harness ESTABLISHES the trigger before asserting anything, and says so if it cannot. A run against
a project with no marker would pass every check below while testing nothing.

The last check is the one that could go wrong in the dangerous direction. Excluding a role from the sheet
scan risks blinding it: a scan that stops noticing a real sheet lets both operations certify while Logic
sits on a blocker, which is a false State A — strictly worse than the withheld State A being fixed. So the
run also raises Logic's mandatory New Track sheet, with the trigger still present, and requires it to be
classified and pressed.

Instrument conditions: product answers come from each operation's own envelope; the failing node's
presence is read by an external AX walk at the same depth the product uses (32), not inferred; the sheet
count is read through System Events, which the product does not use.
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
CENSUS = "/tmp/ax_role_census"
missing = E.have_tools()
if missing:
    sys.exit(f"cannot run: missing {missing}")

ev = E.Evidence(HEAD, os.environ["LPM_EVIDENCE_ROOT"])
d = E.Driver()
rec = None


def osa(script):
    return (subprocess.run(["osascript", "-e", script], capture_output=True, text=True).stdout or "").strip()


def windows():
    return osa('tell application "System Events" to tell process "Logic Pro" to return name of every window')


def sheet_count():
    return osa('tell application "System Events" to tell process "Logic Pro" to '
               'get count of every sheet of (first window whose name ends with "Tracks")')


def failing_node_present():
    """External AX walk at the product's own depth. Not the product's opinion of itself."""
    if not os.path.exists(CENSUS):
        return None
    return "25200" in (subprocess.run([CENSUS], capture_output=True, text=True).stdout or "")


def tracks():
    d.tool("logic_tracks", "select", {"index": 0})
    return d.resource("logic://tracks").get("data", []) or []


def clear_blocking_dialog():
    """Clear a dialog the product left on screen, choosing by what the dialog IS.

    An unrecognised sheet is not dismissed by the product and wedges every later operation into State C
    (#545). Two shapes appear here: Logic's delete confirmation, which this run genuinely intends to
    accept because it asked for the delete; and anything else, which is cancelled. Blindly pressing the
    affirmative button on an unknown dialog would make this harness destructive in ways it never
    declared, so the choice is made on the dialog's own static text.
    """
    osa('tell application "System Events" to tell process "Logic Pro"\n'
        'try\n'
        'set t to (value of every static text of window 1) as text\n'
        'if t contains "Delete Track" then\n'
        'click (first button of window 1 whose name is "Delete")\n'
        'else if (name of every button of window 1) contains "Cancel" then\n'
        'click (first button of window 1 whose name is "Cancel")\n'
        'end if\n'
        'end try\n'
        'end tell')


clear_blocking_dialog()

# ---- establish the trigger, or stop ----
if "Marker List" not in windows():
    # Menu clicks require Logic frontmost here; without it the click silently does nothing and the
    # precondition below reports the trigger absent for the wrong reason.
    osa('tell application "System Events" to tell process "Logic Pro"\n'
        'set frontmost to true\n'
        'delay 0.5\n'
        'click menu item "Open Marker List" of menu 1 of menu bar item "Navigate" of menu bar 1\n'
        'end tell')
    time.sleep(2)

if failing_node_present() is False:
    # `first window whose name ends with ...` intermittently raises -1719 here even when the window is
    # listed; `contains` bound to a variable first is what works. The button is nested a level down, so
    # walk the window's children rather than addressing it directly.
    osa('tell application "System Events" to tell process "Logic Pro"\n'
        'set frontmost to true\n'
        'delay 0.5\n'
        'set w to (first window whose name contains "Marker List")\n'
        'repeat with g in (every UI element of w)\n'
        'try\n'
        'click (first button of g whose description is "Create new Marker")\n'
        'exit repeat\n'
        'end try\n'
        'end repeat\n'
        'end tell')
    time.sleep(2.5)

present = failing_node_present()
ev.check("549/precondition-the-trigger-is-present", present is True,
         "the unreadable AXCell is actually in the tree, so the run tests the defect rather than its absence",
         f"failing_node_present={present} windows={windows()!r}",
         "ran the matrix against a project with no marker; every check passed while the defect could not "
         "have occurred, because the row that carries the failing node did not exist")
if present is not True:
    d.close()
    print(json.dumps(ev.write(), indent=1)); sys.exit(1)

rec = ev.record_screen(seconds=100)
win = E.logic_window()
# NOT the track rail: the Marker List window floats over the left of the arrange window, and it has to
# stay open because it carries the trigger. A crop there shows the Marker List, which does not change when
# tracks are added, so the assertion compared two identical wrong pictures and read as "nothing happened"
# on a run that plainly worked. Sample the arrange lanes to the right of it instead.
RAIL = (int(win["w"] * 0.45), int(win["h"] * 0.15),
        int(win["w"] * 0.45), int(win["h"] * 0.60)) if win else None
pre = ev.shot("before-create", settle_region=RAIL)

# ---- the defect: create must certify with the failing node present ----
def bring_logic_forward():
    """The menu drive needs Logic frontmost. Starting the screen recording and taking the settling
    captures moves focus away, so without this the creates fail for an environment reason and the run
    reads as a product regression — it did, once, while a manual run seconds earlier certified three
    times. Activation goes through osascript: in-process activation poisons this process's own CGEvent
    posting.
    """
    subprocess.run(["osascript", "-e", 'tell application "Logic Pro" to activate'],
                   capture_output=True, text=True)
    time.sleep(1.0)


bring_logic_forward()
before = len(tracks())
results = []
for _ in range(3):
    bring_logic_forward()
    body = d.tool("logic_tracks", "create_instrument")
    time.sleep(1.8)
    results.append(body)

certified = [b for b in results
             if isinstance(b, dict) and b.get("state") == "A" and b.get("verified") is True]
still_there = failing_node_present()

ev.check("549/create-certifies-with-the-failing-node-present",
         len(certified) == len(results) and still_there is True,
         "track.create reaches State A while the node that used to veto absence is still in the tree",
         f"certified={len(certified)}/{len(results)} node_still_present={still_there} "
         f"states={[b.get('state') for b in results if isinstance(b, dict)]}",
         "reverted the role exclusion; every one of these returned State B retry_exhausted with "
         "window_sheet_read_failed and ax -25200")

after_create = len(tracks())
ev.check("549/the-writes-actually-landed",
         after_create == before + len(results),
         "each certified create really added a track — State A is not being granted over a no-op",
         f"before={before} after={after_create} expected={before + len(results)}",
         "made the exclusion return .absent without performing the create; the count did not move while "
         "the envelope still said State A")

post = ev.shot("after-create", settle_region=RAIL)
if RAIL:
    ev.visual("549/new-track-lanes-appear", pre["file"], post["file"], RAIL, expect_change=True,
              why="three tracks were added, so their lanes must appear in the arrange area")

# ---- the dangerous direction: the scan must still see a REAL sheet ----
t = tracks()
guard = 0
while len(t) > 1 and guard < 20:
    guard += 1
    last = t[-1]
    unique = f"ZZ549v {last['id']}"
    bring_logic_forward()
    d.tool("logic_tracks", "rename", {"index": last["id"], "name": unique})
    time.sleep(0.7)
    d.tool("logic_tracks", "delete", {"index": last["id"], "expected_name": unique})
    # Logic raises its delete confirmation and the product does not dismiss it (#545), so the count does
    # not move until the dialog is answered. Clear it, then give the delete time to land before deciding
    # the loop has stalled — checking immediately reads the pre-dialog count and aborts a loop that was
    # about to succeed.
    prev = len(t)
    landed = False
    for _ in range(3):
        time.sleep(1.2)
        clear_blocking_dialog()
        time.sleep(1.2)
        t = tracks()
        if len(t) < prev:
            landed = True
            break
    if not landed:
        break

sheet_body = {}
if len(t) == 1:
    bring_logic_forward()
    d.tool("logic_tracks", "rename", {"index": t[0]["id"], "name": "ZZ549v last"})
    time.sleep(0.8)
    sheet_body = d.tool("logic_tracks", "delete", {"index": t[0]["id"], "expected_name": "ZZ549v last"})
    time.sleep(2.2)

# The property is that the scan still NOTICES a sheet. Which sheet Logic raises depends on the project:
# a Live Loops project answers a last-track delete with #545's unrecognised "Delete Track and Cells?"
# dialog, a regular one with the mandatory New Track sheet. Asserting the New Track sheet specifically
# would make this check pass or fail on project type rather than on the thing under test.
#
# `unknown_sheet` with `action: none` is the scan seeing a blocker and correctly refusing to act on one it
# cannot identify — exactly the fail-closed behaviour that must survive. What must NOT happen is
# `kind: none`: that would mean the narrowing blinded the scan, and both operations would certify with a
# blocker on screen.
#
# Stated limit: the mandatory-New-Track branch (classified AND pressed) was verified by hand on a
# non-Live-Loops project — `mandatory_new_track` / `click_create`, no sheet left. This harness does not
# re-prove that leg, because it cannot choose which sheet Logic raises.
seen_kind = sheet_body.get("reconciled_modal_kind") if isinstance(sheet_body, dict) else None
ev.check("549/a-real-sheet-is-still-seen",
         seen_kind is not None and seen_kind != "none",
         "excluding a role did not blind the scan — a sheet on screen is still detected, with the "
         "failing node present",
         f"kind={seen_kind!r} action={sheet_body.get('reconciled_action')!r} reduced_to={len(t)}",
         "widened the excluded set until a sheet's own ancestor was skipped; the scan reported no "
         "blocker while one was on screen, and the operation certified — a false State A")

ev.check("549/no-blocker-is-left-on-screen",
         sheet_count() == "0",
         "System Events, a path the product does not use, reports no sheet remains",
         f"sheets_after={sheet_count()!r}",
         "skipped the Create press; this independent read still said 1 with Logic waiting on a human")

ev.restored("549/project-has-tracks-again", len(tracks()) >= 1, f"tracks={len(tracks())}")

d.close()
ev.stop_recording(rec)
print(json.dumps(ev.write(), indent=1))
