#!/usr/bin/env python3
"""Live proof that each CGEvent fallback keystroke performs its op's function and no other (#1029).

Usage: LPM_LIVE_LOCK=<held lock> LPM_EVIDENCE_ROOT=<absolute dir> /usr/bin/python3 \
       Scripts/livekit/live_1029_cgevent_fallback_in_every_locale.py \
       <worktree> <full-40-char-head> <binary> [--lprojs lproj ...] [--mode isolated|production]
       (default lprojs: en ko ja de es fr it pt zh_CN zh_TW; mode isolated; a debug build)

WHAT IS ASKED
-------------
#1029 criterion 3: for each op that keeps a CGEvent fallback, a live run in all ten locales shows
that the fallback keystroke performs the op's function and no other command, observed
independently of the op's own reply. Criterion 4: whether the fallback is reachable in production,
for example when the MIDI key-command path is unavailable.

HOW
---
`isolated`: the server is started with LOGIC_MCP_DEBUG_ONLY_CHANNEL=CGEvent, so every op goes
through CGEvent alone, and the MIDI key-command approval is withdrawn for the run. Each op is called
once from a prepared state, and the harness reads Logic through Accessibility from this process
before and after: the control-bar checkboxes, the number of track header rows, the playhead's bar,
the Logic windows on screen, and the per-depth structure and slider values the view ops change. The
op's function is the one reading it must move, as named in OPS; every other reading must stay as
it was, which is what "no other command" is taken to mean here. The reply is recorded, not judged.

`production`: no route restriction and the MIDI key-command approval withdrawn. Each op is called
the same way and the reply's channel is recorded: that is the criterion 4 measurement.

Before every call the arrange window is raised and the Tracks header rail focused
(`logic_live_ax.focus_tracks`). Letters Logic's key command set leaves unbound with no modifier are
read from its preferences per language; for such an op the function cannot happen by its key and
only the reply is recorded.

REGIONS AND THE PROJECT
-----------------------
The fixture's tracks each hold one MIDI region from bar 1 to bar 2. Region selection is set through
AXSelected before each region op and read back; the region count, the selected count and the Edit
menu's first item (the last undoable edit) are read before and after. Select all selects every
region; copy moves nothing and the paste after it adds one; cut removes one; split at 1.3.1.1 adds
one and join removes it; quantize changes the undo item; bounce in place opens a dialog, which one
Escape cancels while Logic holds the keyboard; record turns the record checkbox on and stop off.
Save must advance ProjectData's modification time, and close must take the arrange window away.
The fixture is copied before the run and put back, with Logic quit, before every launch and at the
end, and the copy is compared byte for byte.

WHAT IS NOT JUDGED
------------------
Which command Logic ran is read from the state it changed, not from Logic.
"""

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, ".."))
import evidence as E  # noqa: E402
import live_993_plugin_root_menu_in_every_locale as L993  # noqa: E402
import logic_live_ax as A  # noqa: E402
import probe_942_escape_over_goto_dialog as P  # noqa: E402
import shutil  # noqa: E402

ONLY_CHANNEL_KEY = "LOGIC_MCP_DEBUG_ONLY_CHANNEL"
PASS_KEY = "LOGIC_MCP_DEBUG_ONLY_CHANNEL_PASS"
# Reads and setups whose chain holds no CGEvent rung. Pause reads the tempo as well as the state
# before its key (the 2026-10-03 ten-language run refused pause in nine languages without it). The router walks these as the table has them
# and still keeps CGEvent alone in any chain that holds it, so no op under test is widened.
PASS_OPERATIONS = ("transport.get_state", "transport.get_tempo", "track.get_tracks", "track.get_selected", "track.select",
                   "track.rename", "region.get_regions", "project.get_info")
APPROVALS = os.path.expanduser("~/Library/Application Support/LogicProMCP/operator-approvals.json")
STARTUP = 2.0
STRUCTURE_ROLES = ("AXLayoutArea", "AXPopUpButton", "AXMenuButton", "AXGroup")
RECORDING_SECONDS_PER_LANGUAGE = 240
BAR_GOTO = 9


def arguments():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("worktree")
    parser.add_argument("head")
    parser.add_argument("binary")
    parser.add_argument("--lprojs", nargs="+", default=list(L993.DEFAULT_LPROJS), metavar="lproj")
    parser.add_argument("--mode", choices=("isolated", "production"), default="isolated")
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9a-f]{40}", args.head):
        parser.error("head must be a full lowercase 40-character SHA")
    if not os.access(args.binary, os.X_OK):
        parser.error(f"binary is not executable: {args.binary}")
    unknown = [name for name in args.lprojs if name not in L993.CODES]
    if unknown:
        parser.error(f"unknown lproj(s): {', '.join(unknown)}")
    if not os.path.isabs(os.environ.get("LPM_EVIDENCE_ROOT", "")):
        parser.error("LPM_EVIDENCE_ROOT must be set by the caller to an absolute path")
    lock = os.environ.get("LPM_LIVE_LOCK") or ""
    if not os.path.isfile(lock):
        parser.error(f"LPM_LIVE_LOCK must name an existing lock file held by the caller (got {lock!r})")
    return args


def sha256_of(path):
    with open(path, "rb") as handle:
        return hashlib.sha256(handle.read()).hexdigest()


# --- one snapshot of Logic, read by this process ---------------------------------------------------

def playhead_bar(ax, window):
    """The bar the playhead group's bar slider reads (canon `playheadPositionGroupLabel`,
    `barSliderLabel`), or None."""
    for element, _ in ax.walk(window, 8):
        if ax.value(element, "AXRole") == "AXGroup" \
                and A.matches(ax.value(element, "AXDescription"), "playheadPositionGroupLabel"):
            for slider, _ in ax.walk(element, 8):
                if ax.value(slider, "AXRole") == "AXSlider" \
                        and A.matches(ax.value(slider, "AXDescription"), "barSliderLabel"):
                    value = ax.value(slider, "AXValue")
                    return int(value) if isinstance(value, (int, float)) else None
    return None


def logic_windows():
    """(layer, name) of Logic's windows at layers 0, 3 and 8, front to back."""
    import Quartz
    rows = Quartz.CGWindowListCopyWindowInfo(
        Quartz.kCGWindowListOptionOnScreenOnly | Quartz.kCGWindowListExcludeDesktopElements,
        Quartz.kCGNullWindowID) or []
    pid = A.logic_pid()
    return sorted({(int(w.get(Quartz.kCGWindowLayer) or 0), w.get(Quartz.kCGWindowName) or "")
                   for w in rows if int(w.get(Quartz.kCGWindowOwnerPID) or 0) == pid
                   and int(w.get(Quartz.kCGWindowLayer) or 0) in (0, 3, 8)})


def region_items(ax, window):
    """The region layout items under the arrange window's track-content groups (canon
    `trackContentExplicit` / `trackContentGeneric`), each told by its help (`regionHelpKeyword`).
    Read by the harness, which is not the server, so reading help here ends nothing that matters."""
    out = []
    if window is None:
        return out
    for group, _ in ax.walk(window, 7):
        description = ax.value(group, "AXDescription") or ""
        if ax.value(group, "AXRole") == "AXGroup" and (A.matches(description, "trackContentExplicit")
                                                       or A.matches(description, "trackContentGeneric")):
            for item, _ in ax.walk(group, 4):
                if ax.value(item, "AXRole") == "AXLayoutItem" and A.matches(ax.value(item, "AXHelp"), "regionHelpKeyword"):
                    out.append(item)
    return out


def undo_title():
    """The Edit menu's first item, which names the last undoable edit, read through System Events
    without opening the menu; None when it did not read."""
    _, names = A.label("editMenuBar")
    for name in names:
        out = P.osa('with timeout of 4 seconds\ntell application "System Events" to tell process "Logic Pro" '
                    f'to get name of menu item 1 of menu 1 of menu bar item {P.applescript_string(name)} '
                    'of menu bar 1\nend timeout', timeout=8)
        if out:
            return out.strip()
    return None


def snapshot(ax):
    window = A.arrange_window(ax)
    if window is None:
        return None
    boxes = A.control_bar_boxes(ax, window) or []
    rows = A.track_header_rows(ax)
    counts = {}
    for element, depth in ax.walk(window, 9):
        role = ax.value(element, "AXRole")
        if role in STRUCTURE_ROLES:
            counts[f"{depth}:{role}"] = counts.get(f"{depth}:{role}", 0) + 1
    sliders = [float(v) for v in (ax.value(e, "AXValue") for e, _ in ax.walk(window, 3)
                                  if ax.value(e, "AXRole") == "AXSlider") if isinstance(v, (int, float))]
    regions = region_items(ax, window)
    return {"boxes": {d: (None if v is None else int(v)) for d, v, _ in boxes},
            "tracks": None if rows is None else len(rows),
            "regions": len(regions),
            "regions_selected": sum(1 for item in regions if ax.value(item, "AXSelected") is True),
            "undo_title": undo_title(),
            "bar": playhead_bar(ax, window),
            "windows": logic_windows(),
            "structure": counts,
            "sliders": sliders}


def box_named(snap, key):
    """(description, value) of the one control-bar checkbox the canon key names, or None."""
    boxes = [(d, v, None) for d, v in (snap or {}).get("boxes", {}).items()]
    found = A.target_box(boxes, key)
    return found


def box_value(snap, key):
    found = box_named(snap, key)
    return None if found is None else found[1]


# --- the ops ------------------------------------------------------------------------------------
#
# Each op: (id, tool, command, params, letter or None, expect, allowed)
#   expect(before, after, extra) -> bool: the op's function happened.
#   allowed: the snapshot keys the op may change; every other key must read the same after it.
#   A key of the form "boxes:<canon key>" allows that one checkbox to change.

def toggled(key):
    def check(before, after, extra):
        b, a = box_value(before, key), box_value(after, key)
        return b is not None and a is not None and a != b
    return check


def set_to(key, value):
    def check(before, after, extra):
        return box_value(after, key) == value
    return check


def tracks_by(delta):
    def check(before, after, extra):
        return before.get("tracks") is not None and after.get("tracks") == before["tracks"] + delta
    return check


def bar_is(target):
    def check(before, after, extra):
        return after.get("bar") == target
    return check


def bar_moved(direction):
    def check(before, after, extra):
        b, a = before.get("bar"), after.get("bar")
        return b is not None and a is not None and (a - b) * direction > 0
    return check


def regions_by(delta):
    def check(before, after, extra):
        return before.get("regions") is not None and after.get("regions") == before["regions"] + delta
    return check


def all_regions_selected(before, after, extra):
    return (before.get("regions") or 0) > 1 and before.get("regions_selected") == 1 \
        and after.get("regions_selected") == after.get("regions")


def nothing_visible(before, after, extra):
    """Copy has no reading of its own: it passes when it moved nothing, and the paste after it,
    which needs what copy put on the clipboard, is what shows it acted."""
    return True


def undo_title_changed(before, after, extra):
    return before.get("undo_title") is not None and after.get("undo_title") is not None \
        and after["undo_title"] != before["undo_title"]


def window_appeared(before, after, extra):
    return len(after.get("windows") or []) > len(before.get("windows") or [])


def saved(before, after, extra):
    return extra.get("mtime_before") is not None and extra.get("mtime_after") is not None \
        and extra["mtime_after"] > extra["mtime_before"]


def project_closed(before, after, extra):
    return extra.get("arrange_after") is False


def structure_changed(before, after, extra):
    return before.get("structure") != after.get("structure")


def sliders_moved(before, after, extra):
    b, a = before.get("sliders") or [], after.get("sliders") or []
    return len(a) == len(b) and bool(b) and max(abs(x - y) for x, y in zip(a, b)) > 0.01


def unnamed_box_on(before, after, extra):
    named = {box_named(before, k)[0] for k in ("transportCycleControl", "transportMetronomeControl",
                                               "libraryPanelLabel", "mixerNamedElement",
                                               "transportRecordControl", "transportPlayControl")
             if box_named(before, k) is not None}
    b, a = before.get("boxes") or {}, after.get("boxes") or {}
    on = [d for d, v in a.items() if d not in named and v == 1 and b.get(d) == 0]
    extra["turned_on"] = on
    return len(on) == 1


def unnamed_box_off(before, after, extra):
    named = {box_named(before, k)[0] for k in ("transportCycleControl", "transportMetronomeControl",
                                               "libraryPanelLabel", "mixerNamedElement",
                                               "transportRecordControl", "transportPlayControl")
             if box_named(before, k) is not None}
    b, a = before.get("boxes") or {}, after.get("boxes") or {}
    off = [d for d, v in a.items() if d not in named and v == 0 and b.get(d) == 1]
    extra["turned_off"] = off
    return len(off) == 1


def playhead_advancing(before, after, extra):
    """The bar read twice, 2.5 s apart, after the op: at the fixture's tempo the playhead moves."""
    return extra.get("bar_later") is not None and after.get("bar") is not None \
        and extra["bar_later"] > after["bar"]


def playhead_held(before, after, extra):
    return extra.get("bar_later") is not None and extra["bar_later"] == after.get("bar")


# --- setups and post-steps for the region and project ops ----------------------------------------
#
# A setup runs before the op's first reading and a post-step after its second; both write what they
# did into the row's `extra`. Region selection is set through AXSelected, which toggles: the
# selected regions are toggled off first, then the wanted ones on, and the count is read back.

def select_regions(ax, pick):
    window = A.arrange_window(ax)
    items = region_items(ax, window)
    for item in items:
        if ax.value(item, "AXSelected") is True:
            ax.set(item, "AXSelected", False)
    for item in pick(ax, items):
        ax.set(item, "AXSelected", True)
    time.sleep(0.4)
    return sum(1 for item in region_items(ax, A.arrange_window(ax)) if ax.value(item, "AXSelected") is True)


def first_region(ax, items):
    return items[:1]


def first_row(ax, items):
    """Every region on the same row as the first: after a split, its two halves."""
    if not items:
        return []
    top = (ax.frame(items[0]) or (0, None))[1]
    return [item for item in items if (ax.frame(item) or (0, None))[1] == top]


def selected_track(ax):
    """(index, name) of the one selected track header, the name read from the quoted part of its
    description; (None, None) when not exactly one is selected."""
    rows = A.track_header_rows(ax) or []
    chosen = [(i, row) for i, row in enumerate(rows) if ax.value(row, "AXSelected") is True]
    if len(chosen) != 1:
        return None, None
    index, row = chosen[0]
    found = re.search(r"[\u2018'\u201c\"](.+?)[\u2019'\u201d\"]", ax.value(row, "AXDescription") or "")
    return index, (found.group(1) if found else None)


def setup_selected_track(driver, ax, extra):
    """delete and duplicate are corroborated: they take the index and the name expected there. A
    name another track also has is refused as ambiguous_target_name (the fixture already holds a
    Deluxe Classic track, the name a new instrument track gets), so the selected track is renamed
    to a name no other track has first, through the rename command."""
    index, name = selected_track(ax)
    extra["selected_track"] = {"index": index, "name": name}
    if index is not None:
        unique = f"LPM1029 {index} {int(time.time()) % 100000}"
        reply, _, _ = call(driver, ax, "logic_tracks", "rename", {"index": index, "name": unique})
        extra["rename"] = A.reply_summary(reply)
        time.sleep(0.5)
        index, _ = selected_track(ax)
        # The name is confirmed by finding the unique name in the row's description, not by
        # parsing quotes: German writes „…“ and French « … », which the quote pattern missed and
        # read as no name (2026-10-03, de and fr).
        rows = A.track_header_rows(ax) or []
        described = ax.value(rows[index], "AXDescription") or "" if index is not None and index < len(rows) else ""
        name = unique if unique in described else None
        extra["renamed_track"] = {"index": index, "name": name, "description": described[:120]}
    extra["params"] = {"index": index, "expected_name": name}


def setup_select_all(driver, ax, extra):
    """Every region selected. Q quantized notes in the 2026-09-27 run after Command-A selected every
    region; with one region selected through AXSelected it changed nothing (Korean pilot)."""
    extra["setup_selected"] = select_regions(ax, lambda ax, items: items)


def setup_select_one(driver, ax, extra):
    extra["setup_selected"] = select_regions(ax, first_region)


def setup_split(driver, ax, extra):
    extra["setup_selected"] = select_regions(ax, first_region)
    reply, _, _ = call(driver, ax, "logic_transport", "goto_position", {"position": "1.3.1.1"})
    extra["setup_goto"] = A.reply_summary(reply)


def setup_join(driver, ax, extra):
    extra["setup_selected"] = select_regions(ax, first_row)


def post_cancel_dialog(driver, ax, extra):
    """Bounce in Place opens a dialog; one Escape, only while Logic holds the keyboard, cancels it."""
    owner = P.keyboard_owner_is_logic()
    extra["escape_owner_is_logic"] = owner
    if owner is True:
        P.post_escape()
        time.sleep(1.0)
    extra["windows_after_escape"] = logic_windows()


def project_data_mtime():
    path = os.path.join(L993.FIXTURE, "Alternatives", "000", "ProjectData")
    try:
        return os.path.getmtime(path)
    except OSError:
        return None


def setup_mtime(driver, ax, extra):
    extra["mtime_before"] = project_data_mtime()


def post_mtime(driver, ax, extra):
    time.sleep(1.5)
    extra["mtime_after"] = project_data_mtime()


def post_closed(driver, ax, extra):
    time.sleep(1.5)
    extra["arrange_after"] = A.arrange_window(ax) is not None


OPS = [
    # Transport. Play and stop leave the playhead where it stops; the bar is allowed to move.
    ("transport.play", "logic_transport", "play", {}, None, set_to("transportPlayControl", 1), {"boxes:transportPlayControl", "bar"}),
    ("transport.pause", "logic_transport", "pause", {}, None, playhead_held, {"boxes:transportPlayControl", "bar"}),
    # Resume is reached through play while paused: the play command sends Logic's Play key then.
    ("transport.resume", "logic_transport", "play", {}, None, playhead_advancing, {"boxes:transportPlayControl", "bar"}),
    ("transport.stop", "logic_transport", "stop", {}, None, set_to("transportPlayControl", 0), {"boxes:transportPlayControl", "bar"}),
    ("transport.goto_position", "logic_transport", "goto_position", {"bar": BAR_GOTO}, None, bar_is(BAR_GOTO), {"bar"}),
    ("transport.rewind", "logic_transport", "rewind", {}, None, bar_moved(-1), {"bar"}),
    ("transport.fast_forward", "logic_transport", "fast_forward", {}, None, bar_moved(+1), {"bar"}),
    ("transport.toggle_cycle", "logic_transport", "toggle_cycle", {}, "c", toggled("transportCycleControl"), {"boxes:transportCycleControl"}),
    ("transport.toggle_cycle", "logic_transport", "toggle_cycle", {}, "c", toggled("transportCycleControl"), {"boxes:transportCycleControl"}),
    ("transport.toggle_metronome", "logic_transport", "toggle_metronome", {}, "k", toggled("transportMetronomeControl"), {"boxes:transportMetronomeControl"}),
    ("transport.toggle_metronome", "logic_transport", "toggle_metronome", {}, "k", toggled("transportMetronomeControl"), {"boxes:transportMetronomeControl"}),
    # Views, each twice so the state comes back.
    ("automation.toggle_view", "logic_navigate", "toggle_view", {"view": "automation"}, "a", structure_changed, {"structure", "sliders"}),
    ("automation.toggle_view", "logic_navigate", "toggle_view", {"view": "automation"}, "a", structure_changed, {"structure", "sliders"}),
    ("nav.zoom_to_fit", "logic_navigate", "zoom_to_fit", {}, "z", sliders_moved, {"sliders", "structure"}),
    ("nav.zoom_to_fit", "logic_navigate", "zoom_to_fit", {}, "z", sliders_moved, {"sliders", "structure"}),
    ("view.toggle_library", "logic_navigate", "toggle_view", {"view": "library"}, "y", toggled("libraryPanelLabel"), {"boxes:libraryPanelLabel", "structure", "sliders"}),
    ("view.toggle_library", "logic_navigate", "toggle_view", {"view": "library"}, "y", toggled("libraryPanelLabel"), {"boxes:libraryPanelLabel", "structure", "sliders"}),
    ("view.toggle_mixer", "logic_navigate", "toggle_view", {"view": "mixer"}, "x", toggled("mixerNamedElement"), {"boxes:mixerNamedElement", "structure", "sliders"}),
    ("view.toggle_mixer", "logic_navigate", "toggle_view", {"view": "mixer"}, "x", toggled("mixerNamedElement"), {"boxes:mixerNamedElement", "structure", "sliders"}),
    # The score editor and the piano roll share the editors checkbox, so each is closed before the
    # other opens: with the score editor open, P switches the editor and turns no checkbox on.
    ("view.toggle_score_editor", "logic_navigate", "toggle_view", {"view": "score"}, "n", unnamed_box_on, {"boxes:*", "structure", "sliders"}),
    ("view.toggle_score_editor", "logic_navigate", "toggle_view", {"view": "score"}, "n", unnamed_box_off, {"boxes:*", "structure", "sliders"}),
    ("view.toggle_piano_roll", "logic_navigate", "toggle_view", {"view": "piano_roll"}, "p", unnamed_box_on, {"boxes:*", "structure", "sliders"}),
    ("view.toggle_piano_roll", "logic_navigate", "toggle_view", {"view": "piano_roll"}, "p", unnamed_box_off, {"boxes:*", "structure", "sliders"}),
    # Regions. Each fixture track holds one MIDI region from bar 1 to bar 2, and the playhead sits
    # past them, so a paste lands on its own.
    ("edit.select_all", "logic_edit", "select_all", {}, None, all_regions_selected, {"regions_selected"}, setup_select_one),
    ("edit.copy", "logic_edit", "copy", {}, None, nothing_visible, set(), setup_select_one),
    ("edit.paste", "logic_edit", "paste", {}, None, regions_by(+1), {"regions", "regions_selected", "undo_title", "structure", "sliders", "bar"}),
    ("edit.undo", "logic_edit", "undo", {}, None, regions_by(-1), {"regions", "regions_selected", "undo_title", "structure", "sliders"}),
    ("edit.cut", "logic_edit", "cut", {}, None, regions_by(-1), {"regions", "regions_selected", "undo_title", "structure", "sliders"}, setup_select_one),
    ("edit.undo", "logic_edit", "undo", {}, None, regions_by(+1), {"regions", "regions_selected", "undo_title", "structure", "sliders"}),
    ("edit.split", "logic_edit", "split", {}, None, regions_by(+1), {"regions", "regions_selected", "undo_title", "structure", "sliders"}, setup_split),
    ("edit.join", "logic_edit", "join", {}, None, regions_by(-1), {"regions", "regions_selected", "undo_title", "structure", "sliders"}, setup_join),
    ("edit.quantize", "logic_edit", "quantize", {"value": "1/16"}, "q", undo_title_changed, {"undo_title", "regions_selected", "structure", "sliders"}, setup_select_all),
    ("edit.undo", "logic_edit", "undo", {}, None, undo_title_changed, {"undo_title", "structure", "sliders"}),
    ("edit.bounce_in_place", "logic_edit", "bounce_in_place", {}, None, window_appeared, {"windows", "structure", "sliders", "boxes:*"}, setup_select_one, post_cancel_dialog),
    ("transport.record", "logic_transport", "record", {}, "r", set_to("transportRecordControl", 1), {"boxes:transportRecordControl", "boxes:transportPlayControl", "boxes:transportMetronomeControl", "bar", "regions", "regions_selected", "undo_title", "structure", "sliders"}),
    ("transport.stop", "logic_transport", "stop", {}, None, set_to("transportRecordControl", 0), {"boxes:transportRecordControl", "boxes:transportPlayControl", "boxes:transportMetronomeControl", "bar", "regions", "regions_selected", "undo_title", "structure", "sliders"}),
    # Tracks: create, undo, redo, delete; the other creators each followed by a delete.
    ("track.create_audio", "logic_tracks", "create_audio", {}, None, tracks_by(+1), {"tracks", "structure", "sliders", "boxes:*", "regions_selected", "undo_title"}),
    ("edit.undo", "logic_edit", "undo", {}, None, tracks_by(-1), {"tracks", "structure", "sliders", "boxes:*", "regions_selected", "undo_title"}),
    ("edit.redo", "logic_edit", "redo", {}, None, tracks_by(+1), {"tracks", "structure", "sliders", "boxes:*", "regions_selected", "undo_title"}),
    ("track.delete", "logic_tracks", "delete", {}, None, tracks_by(-1), {"tracks", "structure", "sliders", "boxes:*", "regions_selected", "undo_title"}, setup_selected_track),
    ("track.create_instrument", "logic_tracks", "create_instrument", {}, None, tracks_by(+1), {"tracks", "structure", "sliders", "boxes:*", "windows", "regions_selected", "undo_title"}),
    ("track.delete", "logic_tracks", "delete", {}, None, tracks_by(-1), {"tracks", "structure", "sliders", "boxes:*", "windows", "regions_selected", "undo_title"}, setup_selected_track),
    ("track.duplicate", "logic_tracks", "duplicate", {}, None, tracks_by(+1), {"tracks", "structure", "sliders", "boxes:*", "regions_selected", "undo_title"}, setup_selected_track),
    ("track.delete", "logic_tracks", "delete", {}, None, tracks_by(-1), {"tracks", "structure", "sliders", "boxes:*", "regions_selected", "undo_title"}, setup_selected_track),
    # The project: save, then close. Close is last, since nothing reads after it.
    ("project.save", "logic_project", "save", {}, None, saved, {"windows", "undo_title"}, setup_mtime, post_mtime),
    ("project.close", "logic_project", "close", {"confirmed": True, "saving": "no"}, None, project_closed, {"windows", "boxes:*", "tracks", "bar", "structure", "sliders", "regions", "regions_selected", "undo_title"}, None, post_closed),
]


def others_kept(before, after, allowed):
    """The snapshot keys the op was not allowed to change, each compared whole; boxes compared
    one by one unless all boxes are allowed."""
    moved = []
    for key in ("tracks", "bar", "windows", "structure", "sliders", "regions", "regions_selected"):
        if key not in allowed and before.get(key) != after.get(key):
            moved.append(key)
    if "boxes:*" not in allowed:
        free = {box_named(before, k[6:])[0] for k in allowed if k.startswith("boxes:") and box_named(before, k[6:])}
        b, a = before.get("boxes") or {}, after.get("boxes") or {}
        for d in set(b) | set(a):
            if d not in free and b.get(d) != a.get(d):
                moved.append(f"box:{d}")
    return moved


REGION_OPS = ("edit.select_all", "edit.copy", "edit.paste", "edit.cut", "edit.split", "edit.join",
              "edit.quantize", "edit.bounce_in_place")


def call(driver, ax, tool, command, params, content=False):
    A.activate_logic()
    focus = A.focus_content(ax) if content else A.focus_tracks(ax)
    started = time.monotonic()
    reply = driver.tool(tool, command, params)
    seconds = round(time.monotonic() - started, 2)
    time.sleep(A.SETTLE)
    return reply, seconds, focus


def box_shot(ev, ax, key, tag, region=None):
    """A capture of the arrange window settled on the control-bar checkbox the canon key names,
    with that checkbox's region in window points; None when it did not read."""
    window = A.arrange_window(ax)
    frame = ax.frame(window) if window is not None else None
    boxes = A.control_bar_boxes(ax, window) if window is not None else None
    found = [(d, e) for d, _, e in boxes or [] if A.target_box([(d, 0, e)], key)]
    description = found[0][0] if len(found) == 1 else None
    if region is None:
        if frame is None or len(found) != 1:
            return None
        box = ax.frame(found[0][1])
        if box is None:
            return None
        region = (int(box[0] - frame[0]), int(box[1] - frame[1]), int(box[2]), int(box[3]))
    shot = ev.shot(tag, settle_region=region)
    return {"file": shot["file"], "region": region, "description": description,
            "window_points": (int(frame[2]), int(frame[3])) if frame else None}


def run_language(ev, driver, ax, source, lproj, bindings, mode):
    rows = []
    for index, (op, tool, command, params, letter, expect, allowed, *steps) in enumerate(OPS):
        setup, post = (list(steps) + [None, None])[:2]
        extra = {}
        if setup is not None:
            setup(driver, ax, extra)
        first_shot = box_shot(ev, ax, "transportPlayControl", f"1029/{lproj}/play-before") \
            if op == "transport.play" else None
        before = snapshot(ax)
        reply, seconds, focus = call(driver, ax, tool, command, extra.get("params", params),
                                     content=op in REGION_OPS)
        after = snapshot(ax)
        if first_shot is not None:
            second = box_shot(ev, ax, "transportPlayControl", f"1029/{lproj}/play-after", first_shot["region"])
            if second is not None:
                ev.visual(f"1029/{lproj}/play-checkbox-changed", first_shot["file"], second["file"],
                          first_shot["region"], expect_change=True,
                          why="the play keystroke starts playback, and the control bar's play checkbox "
                              "shows it",
                          subject=f"the control-bar checkbox described {first_shot['description']!r}, "
                                  "matched to the canon's play label",
                          window_points=first_shot["window_points"])
        if post is not None:
            post(driver, ax, extra)
        if op in ("transport.pause", "transport.resume"):
            time.sleep(2.5)
            later = snapshot(ax)
            extra["bar_later"] = None if later is None else later.get("bar")
        summary = A.reply_summary(reply)
        unbound = letter is not None and bindings is not None and letter not in bindings
        row = {"index": index, "op": op, "before": before, "after": after, "extra": extra,
               "reply": summary, "seconds": seconds, "focus": focus, "letter": letter,
               "letter_unbound": unbound, "source_after": source.current()}
        if before is not None and after is not None:
            row["function"] = bool(expect(before, after, extra))
            row["others_moved"] = others_kept(before, after, allowed)
        elif op == "project.close" and before is not None:
            # Nothing reads once the arrange window is gone; the post-step read whether it went.
            row["function"] = bool(expect(before, {}, extra))
            row["others_moved"] = []
        rows.append(row)
        print(json.dumps({"lproj": lproj, "mode": mode, "op": op, "function": row.get("function"),
                          "others_moved": row.get("others_moved"), "method": summary.get("method"),
                          "success": summary.get("success")}, ensure_ascii=False), flush=True)
    # Leave the transport stopped whatever happened above, unless the project was closed.
    if A.arrange_window(ax) is not None:
        call(driver, ax, "logic_transport", "stop", {})
    return rows


def performed(row):
    """The op's reading moved, no other did, and 2-Set Korean read back. A letter Logic leaves
    unbound cannot move its reading, and fails: a reply alone is not the op acting (the same
    correction as review R1 of #1085, R-1039-02)."""
    if row.get("letter_unbound"):
        return False
    return row.get("function") is True and row.get("others_moved") == [] \
        and row.get("source_after") == A.KOREAN_2SET


def nothing_happened(row):
    """The counterexample for each op: the same row with the after reading equal to the before."""
    return dict(row, after=row.get("before"), function=False, others_moved=[])


def tree_digest(path):
    """One SHA-256 over every file under `path`, by relative name and content, and over every
    extended attribute in the tree. The attributes count: the package's Finder info hides its
    extension, and a copy that lost it opened with `.logicx` in Logic's window title, which no
    title match expected (2026-10-03)."""
    digest = hashlib.sha256()
    # -x prints values as hex: some are binary (the Finder info), and the output is read as bytes.
    listed = subprocess.run(["/usr/bin/xattr", "-r", "-l", "-x", path], capture_output=True).stdout
    digest.update(listed.replace(path.encode(), b""))
    for root, dirs, files in os.walk(path):
        dirs.sort()
        for name in sorted(files):
            full = os.path.join(root, name)
            digest.update(os.path.relpath(full, path).encode())
            with open(full, "rb") as handle:
                digest.update(handle.read())
    return digest.hexdigest()


def restore_fixture(backup):
    """project.save writes the fixture, so it is put back from the copy taken before the run, with
    Logic quit first: files under an open project are not replaced."""
    if L993.logic_running() and not L993.quit_logic():
        raise RuntimeError("Logic did not quit, so the fixture was not replaced under it")
    shutil.rmtree(L993.FIXTURE)
    # ditto, not shutil.copytree: on macOS copytree drops extended attributes.
    subprocess.run(["/usr/bin/ditto", backup, L993.FIXTURE], check=True)


def main():
    args = arguments()
    sys.path.insert(0, os.path.join(args.worktree, "Scripts"))
    import logic_canon  # noqa: E402
    setattr(L993, "logic_canon", logic_canon)
    E.REPO = args.worktree
    E.BIN = args.binary
    missing = E.have_tools()
    if missing:
        sys.exit(f"cannot run: missing {missing}")
    if E.screen_is_locked() is not False:
        sys.exit("cannot run: the screen is locked or its state did not read")
    if subprocess.run(["/usr/bin/pgrep", "-x", "LogicProMCP"], capture_output=True, text=True).stdout.strip():
        sys.exit("cannot run: a LogicProMCP process is already running")
    source = A.Source()
    if source.current() != A.KOREAN_2SET:
        sys.exit(f"cannot run: the input source is {source.current()!r}, not 2-Set Korean")
    with open(APPROVALS, "rb") as handle:
        approvals = handle.read()
    ax = A.AX()
    ev = E.Evidence(args.head, os.environ["LPM_EVIDENCE_ROOT"], surface="ui")
    ev.note("1029/binary", {"binary": args.binary, "sha256": sha256_of(args.binary), "mode": args.mode,
                            "lprojs": args.lprojs})
    runs, failures, restored = {}, {}, {}
    recording = ev.record_screen(seconds=RECORDING_SECONDS_PER_LANGUAGE * len(args.lprojs) + 120)
    if args.mode == "isolated":
        os.environ[ONLY_CHANNEL_KEY] = "CGEvent"
        os.environ[PASS_KEY] = ",".join(PASS_OPERATIONS)
        ev.note("1029/pass-operations", {"operations": list(PASS_OPERATIONS)})
    backup = os.path.join(os.environ["LPM_EVIDENCE_ROOT"], "fixture-before-the-run.logicx")
    if os.path.exists(backup):
        shutil.rmtree(backup)
    subprocess.run(["/usr/bin/ditto", L993.FIXTURE, backup], check=True)
    fixture_digest = tree_digest(backup)
    ev.note("1029/fixture", {"path": L993.FIXTURE, "sha256_of_tree": fixture_digest})
    try:
        withdrawn = json.loads(approvals)
        withdrawn.get("approvals", {}).pop("MIDIKeyCommands", None)
        with open(APPROVALS, "w") as handle:
            json.dump(withdrawn, handle, indent=2)
        for lproj in args.lprojs:
            restore_fixture(backup)
            language = L993.switch_to(lproj, force=True)
            runs[lproj] = {"launch": language}
            if language.get("arrange_window") is None \
                    or language.get("language_setting", [])[:1] != [L993.CODES[lproj]]:
                failures[lproj] = "the fixture did not open in this language"
                break
            A.ARRANGE["title"] = language.get("arrange_window")
            bindings = A.plain_bindings()
            ev.note(f"1029/{lproj}/plain-bindings", {"characters": bindings})
            A.activate_logic()
            if not A.wait_ready(ax):
                failures[lproj] = "the control bar did not read within the wait after the launch"
                break
            driver = E.Driver(binary=args.binary)
            try:
                time.sleep(STARTUP)
                runs[lproj]["rows"] = run_language(ev, driver, ax, source, lproj, bindings, args.mode)
            finally:
                try:
                    driver.close()
                except Exception:  # noqa: BLE001 - the rows are already in hand
                    pass
            ev.note(f"1029/{lproj}/rows", runs[lproj]["rows"])
    finally:
        os.environ.pop(ONLY_CHANNEL_KEY, None)
        os.environ.pop(PASS_KEY, None)
        with open(APPROVALS, "wb") as handle:
            handle.write(approvals)
        with open(APPROVALS, "rb") as handle:
            ev.restored("1029/operator-approvals-restored-byte-for-byte", handle.read() == approvals)
        try:
            restore_fixture(backup)
            ev.restored("1029/fixture-restored-byte-for-byte", tree_digest(L993.FIXTURE) == fixture_digest)
            restored = L993.switch_to(L993.RESTORE, force=True)
        except Exception as exc:  # noqa: BLE001 - recorded as a failed restoration
            restored = {"error": f"Korean restoration raised: {exc!r}"}
        restored["language_setting_after_restore"] = L993.language_setting()
        restored["ok"] = (restored.get("arrange_window") is not None
                          and restored["language_setting_after_restore"][:1] == [L993.CODES[L993.RESTORE]])
        ev.restored("1029/Logic-language-restored-to-Korean", restored["ok"], repr(restored)[:400])
        ev.restored("1029/input-source-is-2-Set-Korean-at-the-end", source.current() == A.KOREAN_2SET,
                    repr(source.current()))
        ev.stop_recording(recording)

    ev.note("1029/failures", failures)
    if args.mode == "isolated":
        for lproj in args.lprojs:
            for row in (runs.get(lproj) or {}).get("rows") or []:
                ev.falsifiable(f"1029/{lproj}/{row['index']:02d}/{row['op']}", performed, row, nothing_happened(row),
                               "through CGEvent alone the keystroke changed the op's reading and no other",
                               mutation="a keystroke bound to another command, or none: the op's reading "
                                        "does not move, or another one does")
    out = ev.write()
    clean = E.is_clean(out)
    print(json.dumps({"written": out, "is_clean": clean, "failures": failures,
                      "korean_restored": restored.get("ok")}, ensure_ascii=False))
    return 0 if clean and not failures else 1


if __name__ == "__main__":
    sys.exit(main())
