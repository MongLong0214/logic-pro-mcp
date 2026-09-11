#!/usr/bin/env python3
"""Live proof that `logic_edit undo` undoes something, and can say what.

Usage:  LPM_EVIDENCE_ROOT=/abs/path/outside/repo \
        python3 live_864_undo_moves_the_stack_and_says_what_it_undid.py <worktree> <full-40-char-head-sha>

WHAT WAS WRONG
--------------
`edit.undo` routed `[.midiKeyCommands, .cgEvent]` and the MIDI rung sent CC 30 on channel 16 -- a
controller number that does nothing unless the operator bound it in Controller Assignments, which
this product can neither create nor enumerate. Because a send-only channel succeeds at the wire, the
`.cgEvent` rung that would have posted a real Cmd+Z was never reached. Measured 2026-09-12: two
inserted plug-ins survived two `logic_edit undo` calls, each answering `success: true`.

The sharp end is that undo is the ROLLBACK primitive. A rollback that did not roll back could report
that it did.

WHAT THIS DOES NOT MEASURE, SAID FIRST
--------------------------------------
It does not exercise the refusal branch, and deliberately does not try to. Reaching "there is
nothing to undo" means draining Logic's undo stack, which means undoing the OPERATOR's work; a
harness that did that to reach a clause would be doing the exact thing this operation exists to make
safe. `EditStackEntryIdentityTests` carries the disabled-entry case against a fixture built from the
same live reading.

Nor does it measure a host that has remapped Cmd+Z. The row is identified by its shortcut, so such a
host matches no row and is refused -- which is the intended behaviour and is unit-tested, not
measured here.

THE MEASUREMENT, AND THE COUNTEREXAMPLE IT HAS TO SURVIVE
--------------------------------------------------------
The run renames one track, undoes, and reads three things that have to agree:

    the Edit-menu entry CHANGED when the rename landed        (the stack took the action)
    the undo reached State A and its entry_before != entry_after   (the stack moved back)
    the track's NAME is the original again                    (something was actually undone)

The third clause is the one the old implementation could never satisfy, and it is independent of the
menu: it is read from `logic://tracks`, not from the thing that was pressed. A response that names a
menu entry proves a menu was read; only the name coming back proves an undo happened.

THE COUNTEREXAMPLE is precisely the old behaviour: `success: true` with the entry unmoved and the
probe name still on the track. It satisfies "the command answered" and fails every clause that is
about the world.

The run restores itself by construction -- the rename it makes is the thing it undoes -- so a failed
undo leaves the probe name in place and the restoration is recorded as failed rather than claimed.
This is a `non_ui` run: the subject is a menu-driven state change reported on the wire, and the
window behind it is the operator's own arrangement rather than a rectangle this run is asserting on.
"""
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import evidence as E  # noqa: E402


COVERS = [
    "Sources/LogicProMCP/Channels/AccessibilityChannel+Editing.swift",
    "Sources/LogicProMCP/Channels/RoutingTable.swift",
]

PROBE_NAME = "lpm-864-undo-probe"

WT = sys.argv[1] if len(sys.argv) > 1 else ""
HEAD = sys.argv[2] if len(sys.argv) > 2 else ""
if not WT or not HEAD:
    sys.exit(__doc__)

E.REPO = WT
E.BIN = f"{WT}/.build/release/LogicProMCP"
missing = E.have_tools()
if missing:
    sys.exit(f"cannot run: missing {missing}")

ev = E.Evidence(HEAD, os.environ["LPM_EVIDENCE_ROOT"], surface="non_ui")

d = E.Driver()
d.tool("logic_system", "refresh_cache")


def track_name(index):
    tracks = d.resource("logic://tracks") or {}
    for row in tracks.get("data") or []:
        if row.get("id") == index:
            return row.get("name")
    return None


# The target is chosen from the live census rather than written down: a project edited between runs
# moves every ordinal, and renaming whichever track happens to sit at a hardcoded index is how a
# harness damages the thing it is measuring.
tracks = d.resource("logic://tracks") or {}
rows = [r for r in (tracks.get("data") or []) if isinstance(r.get("id"), int)]
target = next((r for r in rows if not r.get("is_stack_header")), None)
ev.note("864/target-track", {"readable": tracks.get("readable"), "target": target})

if target is None:
    ev.note("864/no-target", {"reason": "no ordinary track in the live census"})
    d.close()
    out = ev.write()
    print(json.dumps(out, indent=1))
    sys.exit(1)

index = target["id"]
original = target.get("name")

renamed = d.tool("logic_tracks", "rename", {"track": index, "name": PROBE_NAME}) or {}
time.sleep(0.8)
d.tool("logic_system", "refresh_cache")
name_after_rename = track_name(index)
ev.note("864/rename", {"response": renamed, "name_after": name_after_rename})

undone = d.tool("logic_edit", "undo") or {}
time.sleep(1.2)
d.tool("logic_system", "refresh_cache")
name_after_undo = track_name(index)
ev.note("864/undo", undone)

restored = name_after_undo == original
ev.restored(
    "864/the-probe-rename-is-undone",
    restored,
    f"track={index} original={original!r} after_undo={name_after_undo!r}",
)
if not restored:
    # The undo under test is what restores this run. When it does not, put the name back by the
    # ordinary rename path so the operator's project does not keep a probe name because a check
    # failed. Recorded separately: this is cleanup, not evidence.
    fallback = d.tool("logic_tracks", "rename", {"track": index, "name": original}) or {}
    time.sleep(0.8)
    d.tool("logic_system", "refresh_cache")
    ev.note("864/fallback-rename-because-the-undo-did-not-restore", {
        "response": fallback, "name_now": track_name(index),
    })

entry_before = undone.get("entry_before") or ""
entry_after = undone.get("entry_after") or ""

reading = {
    "rename_reached_state_a": renamed.get("state") == "A",
    "rename_landed_on_the_track": name_after_rename == PROBE_NAME,
    "undo_state": undone.get("state"),
    "undo_verified": undone.get("verified"),
    "undo_write_attempted": undone.get("write_attempted"),
    "verify_source": undone.get("verify_source"),
    "entry_before": entry_before,
    "entry_after": entry_after,
    "the_entry_moved": bool(entry_before) and bool(entry_after) and entry_before != entry_after,
    # The independent clause. Read from logic://tracks, not from the menu that was pressed.
    "the_name_came_back": name_after_undo == original,
    "original_name": original,
    "name_after_rename": name_after_rename,
    "name_after_undo": name_after_undo,
}

ev.falsifiable(
    "864/an-undo-moves-the-stack-and-the-world-agrees",
    lambda o: (o["rename_reached_state_a"]
               and o["rename_landed_on_the_track"]
               and o["undo_state"] == "A"
               and o["undo_verified"] is True
               and o["undo_write_attempted"] is True
               and o["verify_source"] == "ax_edit_menu_entry"
               and o["the_entry_moved"]
               and o["the_name_came_back"]),
    reading,
    {"rename_reached_state_a": True, "rename_landed_on_the_track": True,
     "undo_state": "B", "undo_verified": None, "undo_write_attempted": None,
     "verify_source": "scripter_send_only",
     "entry_before": "", "entry_after": "",
     "the_entry_moved": False,
     "the_name_came_back": False,
     "original_name": "Audio 1", "name_after_rename": PROBE_NAME,
     "name_after_undo": PROBE_NAME},
    "a rename lands on the track, the undo reaches State A naming a DIFFERENT Edit entry after than "
    "before, and the track's original name is back when read from `logic://tracks` -- a source "
    "independent of the menu that was pressed. THE COUNTEREXAMPLE is the behaviour this replaced: "
    "`success: true` from a send-only CC, no entry named in either direction, and the probe name "
    "still on the track. It satisfies 'the command answered' and fails every clause that is about "
    "the world, which is the distinction the old response could not express",
    mutation="route `edit.undo` back to `[.midiKeyCommands, .cgEvent]`. The MIDI rung answers State "
             "B `readback_unavailable` at the wire, so `undo_state` is no longer A, `the_entry_moved` "
             "goes false for want of any entry at all, and `the_name_came_back` goes false because "
             "nothing was undone -- three clauses, from one change, and the third is the one no "
             "response shape can fake",
)

d.close()
out = ev.write()
print(json.dumps(out, indent=1))
sys.exit(0 if E.is_clean(out) else 1)
