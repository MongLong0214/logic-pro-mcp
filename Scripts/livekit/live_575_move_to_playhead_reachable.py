#!/usr/bin/env python3
"""Live proof that `logic_edit.move_to_playhead` moves the region it says it moved.

Usage:  LPM_EVIDENCE_ROOT=/abs/path/outside/repo \
        python3 live_575_move_to_playhead_reachable.py <worktree> <full-40-char-head-sha>

WHAT IS NEW
-----------
`region.move_to_playhead` has been implemented and verified since v3.1.3 and was reachable from no
tool. It is now registered as `logic_edit.move_to_playhead`, an edit-family verb on the current
selection — the same contract `cut`, `split` and `join` already ship, because Logic's selection names
the subject and the caller does not.

Its State A gate was also tightened first: it now requires the SAME region (same name, same track)
before and after the menu click. Without that, a selection that drifted mid-click could certify a
region the caller never asked about, purely because that region happens to sit on the playhead.

HOW THE SELECTION IS ESTABLISHED, AND WHY NOT BY THIS HARNESS
-------------------------------------------------------------
An earlier version of the witness below wrote `AXSelected` to place the selection on a chosen
region. Measured on Logic 12.3, that write does not behave as a setter: setting it true ADDS to the
selection rather than replacing it, and a pass that set it false on eighteen other regions left
those eighteen selected and the target NOT selected — the opposite of both writes, with `.success`
returned throughout.

So the selection is established the way a caller would: `record_sequence` imports a region and Logic
leaves that region, and only that region, selected. Measured here as a precondition rather than
assumed. The witness is READ-ONLY, which also means it cannot be accused of having caused what it
reports.

THE WITNESS IS NOT THE PRODUCT'S OWN READBACK
---------------------------------------------
`ax_region_select.swift` reads Logic's region help strings straight out of the arrange window's
track-content group. The operation's envelope is checked against that, not only against itself, so
"it moved" has a second source. The witness is scoped to that one group on purpose: an earlier pass
walked the whole application, picked up the Piano Roll's own region item, and reported 23 regions on
one call and 40 on the next — an index space that moves is not a witness.
"""

import json
import os
import re
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
# Measured band over the arrange CONTENT area (right of the track-header rail, which ends at
# x=928): the window sits at 0,30 and the content group starts just past the headers. This is where
# a region that moved has to leave a mark.
CONTENT_BAND = (940, 162, 500, 300)
TARGET_BAR = 9
WITNESS_SOURCE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ax_region_select.swift")
WITNESS = os.path.join(ev.dir, "ax_region_select")


def osa(script):
    r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
    return (r.stdout or "").strip()


def witness():
    r = subprocess.run([WITNESS], capture_output=True, text=True)
    try:
        return json.loads(r.stdout or "{}")
    except ValueError:
        return {"error": (r.stdout or r.stderr or "")[:200]}


def undo_title():
    """What Logic says its Edit > Undo entry would undo, verbatim."""
    return osa('tell application "System Events" to tell process "Logic Pro" to '
               'return name of menu item 1 of menu 1 of menu bar item "Edit" of menu bar 1')


def start_bar(help_text):
    """The bar Logic's own help string says a region starts at."""
    match = re.search(r"(?:starts at|시작)\D*(\d+)", help_text or "")
    return int(match.group(1)) if match else None


def selected_region(state):
    regions = state.get("regions") or []
    picked = [regions[i] for i in (state.get("selected") or []) if i < len(regions)]
    return picked[0] if len(picked) == 1 else None


build = subprocess.run(["swiftc", "-O", WITNESS_SOURCE, "-o", WITNESS], capture_output=True, text=True)
ev.check("575/precondition-the-independent-region-witness-builds",
         build.returncode == 0 and os.path.exists(WITNESS),
         "the harness's own region reader compiles, so the envelope is checked against something "
         "that is not the code under test",
         f"swiftc rc={build.returncode} {build.stderr.strip()[:200]}", None)

titles = osa('tell application "System Events" to tell process "Logic Pro" to '
             'return name of every window')
ev.check("575/precondition-an-arrange-window-is-open", "Tracks" in titles,
         "Logic is up with an arrange window to move a region inside",
         f"titles={titles!r}", None)

if build.returncode != 0 or "Tracks" not in titles:
    print(json.dumps(ev.write(), indent=1)); sys.exit(1)

rec = ev.record_screen(seconds=240)
d = E.Driver()
time.sleep(4)

# ---- establish a single known selection, through the product ------------------------------------

created = d.tool("logic_tracks", "record_sequence", {"notes": "60,0,480"})
time.sleep(3)
before_state = witness()
target = selected_region(before_state)
ev.note("575/created", {k: v for k, v in created.items() if k != "raw_help"}
        if isinstance(created, dict) else {"raw": str(created)[:200]})
ev.note("575/selection-before", {"selected": before_state.get("selected"),
                                 "regions": len(before_state.get("regions") or []),
                                 "target_help": (target or {}).get("help", "")[:80]})

ev.check("575/precondition-exactly-one-region-is-selected",
         target is not None,
         "the import left exactly one region selected, so 'the selected region' names one thing and "
         "the operation below has an unambiguous subject",
         f"selected={before_state.get('selected')!r} of "
         f"{len(before_state.get('regions') or [])} regions", None)

pre_bar = start_bar((target or {}).get("help", ""))
ev.check("575/precondition-the-target-starts-somewhere-other-than-the-playhead",
         pre_bar is not None and pre_bar != TARGET_BAR,
         f"the selected region starts at a bar that is not {TARGET_BAR}, so a successful move has to "
         f"CHANGE something — a region already sitting on the playhead would let a no-op pass",
         f"pre_bar={pre_bar!r} target_bar={TARGET_BAR}", None)

if target is None or pre_bar is None or pre_bar == TARGET_BAR:
    d.close(); ev.stop_recording(rec)
    print(json.dumps(ev.write(), indent=1)); sys.exit(1)

undo_before = undo_title()
before_shot = ev.shot("575/before-move", settle_region=CONTENT_BAND)
seek = d.tool("logic_transport", "goto_position", {"bar": str(TARGET_BAR)})
time.sleep(2)
ev.note("575/seek", seek if isinstance(seek, dict) else {"raw": str(seek)[:200]})

# ---- the operation ------------------------------------------------------------------------------

moved = d.tool("logic_edit", "move_to_playhead", {})
time.sleep(2)
after_state = witness()
after_target = selected_region(after_state)
post_bar = start_bar((after_target or {}).get("help", ""))
after_shot = ev.shot("575/after-move", settle_region=CONTENT_BAND)
ev.note("575/move", moved if isinstance(moved, dict) else {"raw": str(moved)[:300]})

body = moved if isinstance(moved, dict) else {}
ev.check("575/the-operation-is-reachable-at-all",
         body.get("error") != "invalid_params",
         "`logic_edit.move_to_playhead` reaches its dispatcher instead of being refused as an "
         "unregistered command — which is what it did before this change",
         f"error={body.get('error')!r} hint={str(body.get('hint'))[:120]!r}",
         "remove the registry row: the call comes back `invalid_params` with "
         "\"is not registered for MCP tool 'logic_edit'\" and every check below is unreachable")

ev.check("575/the-move-is-verified-not-merely-attempted",
         body.get("state") == "A" and body.get("verified") is True,
         "the envelope is State A: the operation performed the move AND read back the result, "
         "rather than reporting an unverifiable attempt",
         f"state={body.get('state')!r} verified={body.get('verified')!r} "
         f"reason={body.get('reason')!r}",
         "make `selectedRegionInfo` return nil after the click: the handler falls to State B "
         "readback_unavailable and this check goes red while the reachability check above stays "
         "green")

ev.check("575/it-verified-against-the-same-region-it-started-with",
         body.get("region_name") == body.get("post_region_name")
         and isinstance(body.get("pre_track_index"), int)
         and body.get("pre_track_index") >= 0
         and body.get("pre_track_index") == body.get("post_track_index"),
         "the region read after the move is the same one read before it, by name and by track — "
         "without this a selection that drifted mid-click could certify a region the caller never "
         "asked about, purely because it happens to sit on the playhead",
         f"name {body.get('region_name')!r} -> {body.get('post_region_name')!r} · track "
         f"{body.get('pre_track_index')!r} -> {body.get('post_track_index')!r}",
         "restore `sameRegion = true`: the two drift unit tests go red, and this check is the live "
         "counterpart that shows the fields it compares are really on the envelope")

ev.check("575/it-actually-moved-and-landed-on-the-playhead",
         isinstance(body.get("pre_start_bar"), int)
         and isinstance(body.get("post_start_bar"), int)
         and body["pre_start_bar"] != body["post_start_bar"]
         and abs(body["post_start_bar"] - TARGET_BAR) <= 1,
         f"the region's start bar changed and ended up on bar {TARGET_BAR} within the one-bar snap "
         f"tolerance — a no-op that reported the playhead value would fail the first half",
         f"start bar {body.get('pre_start_bar')!r} -> {body.get('post_start_bar')!r} · "
         f"playhead={body.get('playhead_bar')!r}",
         "return the pre-click start bar as `post_start_bar`: the equality half goes red while the "
         "playhead half still passes, which is the pair that separates a move from a report")

ev.check("575/an-independent-reader-agrees-the-region-is-there-now",
         post_bar is not None and abs(post_bar - TARGET_BAR) <= 1 and post_bar != pre_bar,
         "Logic's own help string on the still-selected region, read by a tool that is not the "
         "product, says it now starts on the playhead bar and no longer where it started",
         f"witness bar {pre_bar!r} -> {post_bar!r} (target {TARGET_BAR})",
         "have the handler report success without performing the menu click: the envelope still "
         "claims the move, and this check — which never reads the envelope — goes red")

ev.visual("575/the-region-visibly-moved",
          before_shot["file"], after_shot["file"], CONTENT_BAND, expect_change=True,
          why="a region that moved from one bar to another is drawn somewhere else in the arrange "
              "content, so the band must differ — an envelope that claimed a move the screen did "
              "not show would be describing something other than what the user sees")

# ---- restore ------------------------------------------------------------------------------------
#
# `logic_edit.undo` routes to the send-only key-command channels and did NOT undo the move when this
# harness first tried it — the region stayed where it had been moved to. That is recorded below as
# an observation, not asserted as a defect: those channels need a bound key command and this host's
# binding was never established by this run.
#
# The restoration therefore goes through Logic's own Edit menu, and it is self-verifying in a way
# that needs no knowledge of the menu's language: the entry's title is captured BEFORE the move and
# again after it, and the click only happens if the title CHANGED — which is Logic saying this run's
# action is what sits on top of the undo stack.

tool_undo = d.tool("logic_edit", "undo", {})
time.sleep(2)
after_tool_undo = start_bar((selected_region(witness()) or {}).get("help", ""))
undo_after = undo_title()
ev.note("575/undo", {"tool_undo": str(tool_undo)[:200], "bar_after_tool_undo": after_tool_undo,
                     "undo_title_before_move": undo_before, "undo_title_after_move": undo_after})

menu_undo_ran = False
if after_tool_undo != pre_bar and undo_after and undo_after != undo_before:
    osa('tell application "System Events" to tell process "Logic Pro" to click '
        f'(first menu item of menu 1 of menu bar item "Edit" of menu bar 1 whose name is "{undo_after}")')
    time.sleep(2.5)
    menu_undo_ran = True

restored_bar = start_bar((selected_region(witness()) or {}).get("help", ""))
d.close()

ev.restored("575/the-move-was-undone",
            restored_bar == pre_bar,
            f"the region is back at bar {restored_bar!r} (it started at {pre_bar!r}). "
            f"logic_edit.undo left it at {after_tool_undo!r}; the menu entry Logic titled "
            f"{undo_after!r} (it read {undo_before!r} before the move, so the move was on top of "
            f"the undo stack) was {'used' if menu_undo_ran else 'not needed'}. The imported track "
            f"this run created to obtain a single selection is left in place: removing it would "
            f"need a destructive operation this run has no reason to perform, and the project is a "
            f"scratch document.")

ev.stop_recording(rec)
out = ev.write()
print(json.dumps(out, indent=1))
sys.exit(0 if E.is_clean(out) else 1)
