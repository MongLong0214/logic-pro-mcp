#!/usr/bin/env python3
"""Live proof for #545 — the track-delete confirmation Logic raises as a top-level dialog.

Usage:  LPM_EVIDENCE_ROOT=/abs/path/outside/repo \
        python3 live_545_delete_confirm.py <worktree> <full-40-char-head-sha>

Requires a project open that has a track carrying at least one region. The harness asserts that rather
than assuming it, and refuses to run otherwise.

Why this harness had to exist before the fix could be believed.

The first #545 fix was wrong, and six green unit tests said it was right. The theory was that Logic
presents "Delete Track and Regions?" as an `AXSheet` with unlocalised button labels, so the fix added
label variants. Logic never vends `AXSheets` at all — it answers `-25205` for that attribute, always —
and this confirmation is a top-level `AXWindow`/`AXDialog`. The label fix therefore changed nothing on
the path that actually runs while every test passed. Only a run against the application caught it.

The trap this harness is built around:

A check that only asks "is a dialog on screen afterwards?" passes just as happily when the dialog NEVER
APPEARED — an empty track deletes silently, and the run would report success while proving nothing. So
the dialog's appearance is witnessed too, by polling System Events on a background thread for the whole
duration of the delete. Both facts are required: it MUST appear, and it MUST be gone afterwards. Neither
alone means anything.

Why the region precondition is not manufactured here. `midi.import_file` validates its path against an
IN-PROCESS registry of files the server itself created, so no externally generated file can reach it
(confirmed live: `invalid_params: path must be a server-managed LogicProMCP temp .mid`).
`track.record_sequence` is the supported route and was tried first; it failed at Logic's file-open panel
("Import button never became enabled"), the known AX wall on that surface. So the run uses a project
that already has regions and states that as a precondition instead of pretending to control it.

What witnesses what:

- **System Events polling is the load-bearing witness**, for both the appearance and the clearing. It is
  a path the product does not use, and "the dialog was left standing" is precisely the pre-fix symptom:
  classified `unknown_sheet`, left up, after which every later operation in every surface returned
  State C until a human clicked it.
- The track count is the product's own AX read and corroborates only.
- The rail pixels witness, independently of AX, that the row went away.

This run deletes a track from the open project. Nothing here saves, so the project ON DISK is untouched;
that is the restoration claim, and it is stated rather than implied.
"""

import json
import os
import subprocess
import sys
import threading
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


def dialog_count():
    """How many top-level modal dialogs Logic has up, via System Events.

    COUNTS them; does not enumerate names. An earlier version of this helper read `name of every window
    whose subrole is "AXDialog"`, and Logic's auto-save recovery alert has an EMPTY name — so the query
    returned an empty string and the helper reported "no dialogs" while a modal alert was plainly on
    screen. A check that cannot see the condition it exists to detect is worse than no check, because it
    reads as evidence.

    Returns None when the measurement itself failed. An unparseable answer is not a zero.
    """
    script = ('tell application "System Events" to tell process "Logic Pro" to '
              'get count of (every window whose subrole is "AXDialog")')
    r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
    raw = (r.stdout or "").strip()
    return int(raw) if raw.isdigit() else None


def tracks():
    """A `select` forces a live AX read; without it the resource answers with synthesised names."""
    d.tool("logic_tracks", "select", {"index": 0})
    return d.resource("logic://tracks").get("data", []) or []


win = E.logic_window()
if not win:
    ev.check("545/precondition-logic-window", False, "Logic's Tracks window is on screen",
             "no window found", "closed the Tracks window; this check went red")
    d.close()
    print(json.dumps(ev.write(), indent=1)); sys.exit(1)

# The track-header band, measured against this window. The obvious choice — the leftmost fifth — is
# WRONG here: with the Library open that strip is the sound browser, which does not move when a track is
# deleted, so the visual assertion failed while the delete had plainly worked. Sample where the rows
# actually are. (This is measurement, not control: nothing is ever clicked by coordinate.)
RAIL = (int(win["w"] * 0.32), int(win["h"] * 0.16), int(win["w"] * 0.17), int(win["h"] * 0.44))

pre = dialog_count()
ev.check("545/precondition-no-dialog-is-already-up", pre == 0,
         "the run starts with no modal dialog on screen",
         f"dialog_count={pre!r}",
         "left a dialog up from a previous run; every later op returned State C and this went red")
if pre != 0:
    d.close()
    print(json.dumps(ev.write(), indent=1)); sys.exit(1)

before = tracks()
ev.note("precondition", {"count": len(before), "names": [t.get("name") for t in before]})

ok_tracks = len(before) >= 2
ev.check("545/precondition-a-deletable-track-exists", ok_tracks,
         "the open project has at least two tracks, so one can be deleted without emptying the project",
         f"count={len(before)} names={[t.get('name') for t in before]}",
         "opened a single-track project; deleting the last track raises the MANDATORY New Track sheet "
         "instead, which is a different dialog and a different code path")
if not ok_tracks:
    d.close()
    print(json.dumps(ev.write(), indent=1)); sys.exit(1)

rec = ev.record_screen(seconds=90)
shot_before = ev.shot("before-delete", settle_region=RAIL)

# ---- watch for the dialog while the delete runs ----
#
# Without this, "no dialog afterwards" is satisfied by a delete that never raised one, and the run would
# certify the fix while exercising nothing. The watcher is the difference between evidence and comfort.
seen = {"max": 0, "samples": 0, "failed_reads": 0}
stop = threading.Event()


def watch():
    while not stop.is_set():
        n = dialog_count()
        seen["samples"] += 1
        if n is None:
            seen["failed_reads"] += 1
        else:
            seen["max"] = max(seen["max"], n)
        time.sleep(0.15)


watcher = threading.Thread(target=watch, daemon=True)
watcher.start()

# Pick the LAST uniquely-named track. Two refusals shaped this, and both were the product being right:
# a bare ordinal is refused outright ("the index is an unproven ordinal"), and an `expected_name` that
# matches more than one live track is refused too, because same-named tracks can swap and stay
# self-consistent. Choosing a unique name is what makes index+name an identity rather than a position.
names = [t.get("name") for t in before]
unique = [i for i, n in enumerate(names) if names.count(n) == 1]
if not unique:
    ev.check("545/precondition-a-uniquely-named-track-exists", False,
             "at least one track has a name no other track shares, so the delete can be bound to an "
             "identity",
             f"names={names}",
             "opened a project whose tracks all share names; delete is refused as ambiguous by design")
    ev.stop_recording(rec)
    d.close()
    print(json.dumps(ev.write(), indent=1)); sys.exit(1)
target = unique[-1]
body = d.tool("logic_tracks", "delete",
              {"index": str(target), "expected_name": before[target].get("name")})

time.sleep(2.0)
stop.set()
watcher.join(timeout=5)

ev.note("delete-response", {"target_index": target,
                            "target_name": before[target].get("name"),
                            "watcher": dict(seen), "body": body})

state = body.get("state") if isinstance(body, dict) else None
reason = body.get("reason") if isinstance(body, dict) else None
reconciled = body.get("reconciled_modal_kind") if isinstance(body, dict) else None

# Half one of the pair: the dialog under test actually appeared. Without this the run proves nothing.
ev.check("545/the-confirmation-dialog-actually-appeared",
         seen["max"] >= 1,
         "System Events observed a modal dialog during the delete — so the code path under test was "
         "genuinely exercised rather than skipped by a silent delete",
         f"max_dialogs_seen={seen['max']} samples={seen['samples']} failed_reads={seen['failed_reads']}",
         "targeted a track with no regions; Logic deleted it silently, no dialog was raised, and this "
         "went red — which is the whole reason this check exists")

# Half two: it was cleared. This is the pre-fix symptom, and the one that poisoned every later operation.
post = dialog_count()
ev.check("545/no-dialog-is-left-on-screen",
         post == 0,
         "System Events, a path the product does not use, reports no modal dialog remains after the "
         "delete",
         f"dialog_count_after={post!r}",
         "removed the .deleteConfirm route; the dialog was classified unknown_sheet, left standing, and "
         "this read one window")

# Gated on the dialog having actually appeared. `reason != "unknown_sheet"` is satisfied by
# `reason=None`, so on a run where the delete never got as far as raising the dialog this check went
# GREEN while proving nothing — it passed for a reason unrelated to what it claims to measure.
ev.check("545/the-dialog-was-recognised-not-refused-as-unknown",
         seen["max"] >= 1 and reason != "unknown_sheet",
         "the reconciler classified the delete-confirm dialog instead of falling through to the generic "
         "fail-closed blocker",
         f"dialog_seen={seen['max']} state={state!r} reason={reason!r} "
         f"reconciled_modal_kind={reconciled!r}",
         "removed the .deleteConfirm case from the top-level dialog switch; the receipt reported "
         "unknown_sheet and this went red")

after = tracks()
ev.check("545/the-track-was-actually-deleted",
         len(after) == len(before) - 1,
         "the project lost exactly one track — the delete went through rather than stalling on the "
         "dialog",
         f"before={len(before)} after={len(after)} names={[t.get('name') for t in after]}",
         "left the dialog unanswered; the track survived and the count did not move")

ev.check("545/the-delete-is-certified-not-abandoned",
         state == "A",
         "delete returns State A rather than the State C the unrecognised dialog produced",
         f"state={state!r} reason={reason!r} error={body.get('error')!r}",
         "removed the .deleteConfirm route; the op could not certify and returned State C")

shot_after = ev.shot("after-delete", settle_region=RAIL)
ev.visual("545/the-row-goes-away",
          shot_before["file"], shot_after["file"], RAIL, expect_change=True,
          why="the deleted track has to disappear from the rail; pixels witness the removal without "
              "trusting any AX read")

ev.restored("545/the-project-on-disk-is-untouched", True,
            "the run deletes a track in memory and never saves; the .logicx bundle is not written")

ev.stop_recording(rec)
d.close()
out = ev.write()
print(json.dumps(out, indent=1))
sys.exit(0 if out.get("passed") else 1)
