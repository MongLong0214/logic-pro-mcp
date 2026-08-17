#!/usr/bin/env python3
"""Live proof that a Marker List with no markers reads as EMPTY, not as unreadable.

Usage:  LPM_EVIDENCE_ROOT=/abs/path/outside/repo \
        python3 live_565_empty_marker_list.py <worktree> <full-40-char-head-sha>

WHAT WENT WRONG
---------------
Measured on Logic Pro 12.3: the Marker List table vends four `AXColumn` children plus one `AXGroup`
at every row count. The row reader's corroboration guard was `children.isEmpty || !rows.isEmpty`, so
on the live tree the first clause never held and the guard meant *an empty row set is always
unreadable*. In a project with no markers every marker operation returned State C — including
`create_marker`, the only route to a first marker — and deleting the LAST marker could not certify.

THE TRIGGER IS ZERO MARKERS, SO THE RUN ESTABLISHES IT FIRST
------------------------------------------------------------
Against a project that already has markers every check below passes while testing nothing: the
defect only exists at a row count of zero. So the run drives the list to zero through the product's
own delete and REFUSES to continue unless an instrument outside the product agrees the list is
empty. Following #549, an unestablished trigger is a failed run, not a quiet pass.

INSTRUMENTS
-----------
The marker count is read two ways that do not share a code path:

  product   each operation's own envelope (`marker_count_before`, `observed_marker_count_after`)
  witness   Logic's own "Number of Items" static text, read through System Events

The witness is what makes "the list really was empty" a measurement rather than the product's
opinion of itself. It is also the discriminator the fix uses, so a run where the two disagree is
reporting something worth seeing, not a harness bug to paper over.
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

MARKER_WINDOW = "Marker List"
# Window-relative rectangle over the first rows of the Marker List table, derived from a live
# measurement (window at 452x746, table origin 142 points below the window's own origin). The band
# stops well short of the table's full height so the assertion is about ROWS appearing, not about
# the window being repainted.
ROW_BAND = (4, 145, 420, 60)


def osa(script):
    r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
    return (r.stdout or "").strip()


def witness():
    """Logic's own Number of Items rendering. Not a path the product uses.

    Returns the raw string (`"0 Markers"`, `"1 Marker"`) or "" when it could not be read — an
    unreadable witness is never reported as a count.
    """
    return osa(
        'tell application "System Events" to tell process "Logic Pro"\n'
        'set w to first window whose name ends with "Marker List"\n'
        'return value of (first static text of (first group of w) whose description is "Number of Items")\n'
        'end tell')


def witness_count(tries=5):
    """The witness as an integer, or None when it could not be read.

    Retried because a single failed UI read is not an answer — the window can be mid-open. None is
    still a real outcome and callers must not spell it as zero.
    """
    for attempt in range(tries):
        raw = witness()
        head = raw.split(" ")[0] if raw else ""
        if head.isdigit():
            return int(head)
        if attempt < tries - 1:
            time.sleep(0.8)
    return None


def state_of(body):
    return body.get("state") if isinstance(body, dict) else None


def open_marker_list():
    if MARKER_WINDOW in osa('tell application "System Events" to tell process "Logic Pro" to '
                            'return name of every window'):
        return
    osa('tell application "System Events" to tell process "Logic Pro"\n'
        'set frontmost to true\n'
        'delay 0.5\n'
        'click menu item "Open Marker List" of menu 1 of menu bar item "Navigate" of menu bar 1\n'
        'end tell')
    time.sleep(2)


def seed_marker_via_menu():
    """Put one marker in the list using Logic's own menu, never the product.

    The delete that empties the list is half of what is under test, so the run needs something to
    delete. Seeding through the product would make the setup depend on the operation being proven.

    The click is VERIFIED against the witness and retried. Measured on this branch: a click issued
    moments after the server process starts can land with no effect, and a seed that quietly does
    nothing leaves the run with nothing to delete — which reads downstream as "the delete path was
    not exercised", the precise shape of an unestablished trigger.
    """
    for _ in range(3):
        before = witness_count()
        osa('tell application "System Events" to tell process "Logic Pro"\n'
            'set frontmost to true\n'
            'delay 0.8\n'
            'click menu item "Create Marker" of menu 1 of menu bar item "Navigate" of menu bar 1\n'
            'end tell')
        time.sleep(1.5)
        after = witness_count()
        if after is not None and after > (before or 0):
            return True
    return False


open_marker_list()
if witness_count() == 0:
    seed_marker_via_menu()
started_with = witness_count()
rec = ev.record_screen(seconds=200)

# ---- establish the trigger: drive the list to zero through the product ----------------------
deletes = []
for _ in range(8):
    if witness_count() == 0:
        break
    body = d.tool("logic_navigate", "delete_marker", {"index": 0})
    deletes.append({"state": state_of(body), "witness_after": witness()})
    if state_of(body) not in ("A", "B"):
        break

empty_witness = witness_count()
ev.note("565/drive-to-empty", {"started_with": started_with, "deletes": deletes,
                               "witness_now": witness()})

# The LAST delete is half the defect: with zero rows left the post-write read had nothing it would
# accept, so emptying the list could not certify. This asserts the tail of that sequence directly.
last_delete = deletes[-1] if deletes else None
ev.check("565/emptying-the-list-certifies",
         bool(last_delete) and last_delete["state"] == "A",
         "the delete that leaves zero markers reaches State A",
         f"last_delete={last_delete} deletes={len(deletes)} started_with={started_with}"
         + ("" if deletes else " — NOTHING WAS DELETED, so this path was never exercised"),
         "restore `children.isEmpty || !rows.isEmpty`: the post-write read of a table with no rows "
         "left becomes unreadable and the delete can no longer certify")

ev.check("565/precondition-the-list-is-actually-empty", empty_witness == 0,
         "Logic's own Number of Items reads zero, so the run is exercising the empty-list path",
         f"witness={witness()!r} parsed={empty_witness!r}",
         "none — this is the trigger, not the fix. A run that reaches the checks below without it "
         "passes them against a NON-empty list and proves nothing about the defect")

if empty_witness != 0:
    ev.stop_recording(rec)
    d.close()
    out = ev.write()
    print(json.dumps(out, indent=1))
    sys.exit(1)

before = ev.shot("565/list-empty", settle_region=ROW_BAND, window_title=MARKER_WINDOW)

# ---- the operation the defect made impossible -------------------------------------------------
# The playhead is moved first: `Create Marker` at a position that already carries one is a no-op in
# Logic, which would produce an honest readback_mismatch for a reason unrelated to this fix.
goto = d.tool("logic_transport", "goto_position", {"bar": "33"})
created = d.tool("logic_navigate", "create_marker", {})
time.sleep(1.5)
after_witness = witness_count()
ev.note("565/create-on-empty", {"goto": goto, "created": created, "witness_after": witness()})

ev.check("565/create-marker-works-on-an-empty-list",
         state_of(created) == "A",
         "create_marker reaches State A in a project that has no markers",
         f"state={state_of(created)!r} error={created.get('error')!r} "
         f"before={created.get('marker_count_before')!r} after={created.get('marker_count_after')!r}",
         "restore `children.isEmpty || !rows.isEmpty`: the pre-write read fails and the operation "
         "returns State C readback_unavailable before it ever presses the menu item")

ev.check("565/the-product-saw-the-empty-list-as-empty",
         created.get("marker_count_before") == 0,
         "the operation's own pre-write count is zero, so it read the empty list rather than "
         "refusing it",
         f"marker_count_before={created.get('marker_count_before')!r}",
         "publish the empty row set without corroboration — the count would still be 0 here, so "
         "this check alone cannot tell the fix from the unsafe version; it is paired with the "
         "witness check below")

ev.check("565/an-independent-witness-agrees-a-marker-appeared",
         after_witness == 1,
         "Logic's own Number of Items goes from 0 to 1, measured outside the product",
         f"witness={witness()!r} parsed={after_witness!r}",
         "make create_marker return State A without pressing the menu item: the envelope would "
         "still claim a create while this count stayed at 0")

after = ev.shot("565/marker-created", settle_region=ROW_BAND, window_title=MARKER_WINDOW)
ev.visual("565/a-row-appears-in-the-marker-table",
          before["file"], after["file"], ROW_BAND, expect_change=True,
          why="the first rows of the Marker List table are empty before the create and carry the "
              "new marker after it")

# ---- restore ----------------------------------------------------------------------------------
# The run leaves the project with the marker count it found. It cannot restore the specific markers
# it deleted — Logic does not undo marker mutations within a session — so it says exactly what it
# put back rather than claiming the project is untouched.
for _ in range(4):
    now = witness_count()
    if now is None or started_with is None or now <= started_with:
        break
    d.tool("logic_navigate", "delete_marker", {"index": 0})
    time.sleep(0.5)
restored_to = witness_count()
# An unread baseline is not a baseline of zero. Spelling `started_with or 0` here would let a run
# that never measured what it started from report a successful restore — the same shape as the
# defect this branch fixes, in the instrument rather than the product.
ev.restored("565/marker-count-back-to-what-the-run-found",
            started_with is not None and restored_to is not None and restored_to <= started_with,
            f"started_with={started_with} now={restored_to}; the run's own markers are removed, but "
            f"markers this run deleted to reach the empty state are NOT restorable in-session"
            + ("" if started_with is not None
               else " — and the starting count was never read, so there is nothing to restore TO"))

ev.stop_recording(rec)
d.close()
out = ev.write()
print(json.dumps(out, indent=1))
sys.exit(0 if E.is_clean(out) else 1)
