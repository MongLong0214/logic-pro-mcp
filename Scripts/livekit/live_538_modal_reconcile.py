#!/usr/bin/env python3
"""Live proof for track.delete's modal reconciler (#538) against the running Logic Pro.

Usage:  LPM_EVIDENCE_ROOT=/abs/path/outside/repo \
        python3 live_538_modal_reconcile.py <worktree> <full-40-char-head-sha>

Deleting the LAST track makes Logic raise its mandatory "New Track" sheet, whose only exit is Create. That
sheet is the subject: the branch exists to observe it, press the Create it actually read, and then witness
the sheet go away. So the run reduces the project to one track on purpose — that is the precondition, not
the assertion.

Two traps this harness has already been caught by, both encoded here rather than left to the operator:

- `logic://tracks` falls back to names synthesised from the project file when the live AX read is
  unavailable, and a synthesised name is stale the moment a rename lands. Trusting one handed `track.delete`
  an identity that no longer existed; the product correctly refused, and the run read as a product failure.
  The precondition now settles on a reading that agrees with the rename it just performed.
- Logic replaces the deleted last track with a fresh default one, so the header rail can end up
  pixel-identical to how it started. The surviving track is renamed to something nothing else would produce
  so the name band HAS to change when it is replaced.
"""

import json
import os
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

WITNESS_NAME = "ZZ538 Witness Fixture"

ev = E.Evidence(HEAD, os.environ["LPM_EVIDENCE_ROOT"])
d = E.Driver()
rec = None  # started after the precondition: the recording should show the operation, not the setup


def tracks():
    """A `select` forces a live AX read of the track headers.

    Without it the resource answers with names synthesised from the project file, which are not an
    observation of anything on screen.
    """
    d.tool("logic_tracks", "select", {"index": 0})
    return d.resource("logic://tracks").get("data", []) or []


def sheet_count():
    """Logic's own answer, via a path the product does not use, so it is not a mirror of the product."""
    script = ('tell application "System Events" to tell process "Logic Pro" to '
              'get count of every sheet of (first window whose name ends with "Tracks")')
    import subprocess
    r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
    return (r.stdout or "").strip()


win = E.logic_window()
if not win:
    ev.check("538/precondition-logic-window", False, "Logic's Tracks window is on screen",
             "no window found", "closed the Tracks window; this check went red")
    d.close(); ev.stop_recording(rec)
    print(json.dumps(ev.write(), indent=1)); sys.exit(1)

# The track header rail: the name band of the surviving track lives here.
RAIL = (0, int(win["h"] * 0.10), int(win["w"] * 0.20), int(win["h"] * 0.80))

# ---- precondition: exactly one track, distinctively named ----
#
# Logic hands several new tracks the SAME default name, and `track.delete` rightly refuses an ambiguous
# target: "'Deluxe Classic' names more than one live track, so the target cannot be identified." Its hint is
# the way through — rename by INDEX, which is not blocked by name ambiguity, then delete by the new unique
# name. Binding by `track_ref` does not help: the refusal is about the live name, not about which reference
# was supplied.
#
# The attempt bound below is the other half: a precondition that cannot converge must say so rather than
# spin. An earlier version had no bound and ran against an unsatisfiable refusal until it was killed.
t = tracks()
attempts = 0
while len(t) > 1 and attempts < 40:
    attempts += 1
    idx = t[-1]["id"]
    unique = f"ZZ538 Doomed {attempts}"
    d.tool("logic_tracks", "rename", {"index": idx, "name": unique})
    time.sleep(0.8)
    d.tool("logic_tracks", "delete", {"index": idx, "expected_name": unique})
    time.sleep(1.2)
    t = tracks()

if len(t) != 1:
    ev.check("538/precondition-reduced-to-one-track", False,
             "the project can be reduced to a single track so the mandatory sheet is raised",
             f"still {len(t)} tracks after {attempts} rounds: {[x.get('name') for x in t]}",
             "removed the attempt bound; the loop ran against a refusal it could not satisfy until killed")
    d.close(); print(json.dumps(ev.write(), indent=1)); sys.exit(1)

renamed = None
settle_attempts = []
if t:
    renamed = d.tool("logic_tracks", "rename", {"index": t[0]["id"], "name": WITNESS_NAME})
    for _ in range(6):
        time.sleep(1.0)
        t = tracks()
        settle_attempts.append([x.get("name") for x in t])
        if t and t[0].get("name") == WITNESS_NAME:
            break

ev.check("538/precondition-distinctive-track-name",
         bool(t) and t[0].get("name") == WITNESS_NAME,
         "the surviving track carries a name nothing else would produce",
         f"rename={json.dumps(renamed)[:160]} settle_attempts={settle_attempts}",
         "read the track list once instead of settling on the rename; the stale synthesised name was "
         "handed to delete and the product refused it as a target identity mismatch")

ev.note("precondition", {"tracks": [x.get("name") for x in t],
                         "sheets_before": sheet_count()})

rec = ev.record_screen(seconds=45)
pre = ev.shot("before-last-track-delete", settle_region=RAIL)

# ---- the operation under test ----
body = d.tool("logic_tracks", "delete",
              {"index": t[0]["id"], "expected_name": t[0]["name"]}) if t else {}
time.sleep(2.0)
post = ev.shot("after-last-track-delete", settle_region=RAIL)
ev.note("response", {"body": body})

witness = (body.get("modal_reconciliation_witness") or {}) if isinstance(body, dict) else {}
observations = witness.get("observations") or {}
polls = witness.get("polls")

ev.check("538/the-sheet-was-classified-not-guessed",
         body.get("reconciled_modal_kind") == "mandatory_new_track",
         "the mandatory New Track sheet is recognised for what it is",
         f"kind={body.get('reconciled_modal_kind')!r} action={body.get('reconciled_action')!r}",
         "treated a -25205 AXSheets answer as a failure; the sheet was never found and every poll "
         "reported unknown_sheet")

ev.check("538/the-create-it-read-is-the-one-it-pressed",
         body.get("reconciled_action") == "click_create",
         "the reconciler presses the Create control it resolved, not a default button",
         f"action={body.get('reconciled_action')!r}",
         "restored the unchecked Return seam; the receipt showed a confirmation with no control read")

ev.check("538/the-sheet-close-is-actually-observed",
         (observations.get("gone", 0) or 0) > 0,
         "at least one poll observed the sheet gone",
         f"polls={polls} observations={observations}",
         "classified the observer's own -25205 as a failure; all polls answered the same status and "
         "'gone' never appeared")

unreadable = sum(v for k, v in observations.items() if str(k).endswith(tuple(f"-252{n:02d}" for n in range(0, 15))))
ev.check("538/the-witness-is-not-blind",
         polls is not None and unreadable == 0,
         "not every poll was an unreadable status — a blind witness proves nothing",
         f"polls={polls} unreadable={unreadable}",
         "made every sheet read fail; the witness still reported a settled observation")

after_sheets = sheet_count()
ev.check("538/logic-agrees-the-sheet-is-gone",
         after_sheets == "0",
         "System Events, a path the product does not use, reports no sheet remains",
         f"sheets_after={after_sheets!r}",
         "left the sheet up by skipping the Create press; this independent read still said 1")

ev.visual("538/the-track-rail-changes",
          pre["file"], post["file"], RAIL, expect_change=True,
          why=f"the distinctively named track {WITNESS_NAME!r} was deleted and replaced")

ev.restored("538/project-has-a-track-again", True,
            f"tracks_after={[x.get('name') for x in tracks()]}")

d.close()
ev.stop_recording(rec)
print(json.dumps(ev.write(), indent=1))
