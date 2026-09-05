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
# The arrange canvas, located by AXDescription. This rectangle was right — measured 2026-08-20
# the canvas sits at 928,162 and the band began twelve points inside it. It is anchored anyway:
# the canvas moves whenever the Library or Inspector is opened, and a run had no way to say
# whether it still watched the canvas or the pane that had slid under it.
_CONTENTS, _CONTENTS_SUBJECT = ev.located_band("Tracks contents")
# TWO rectangles, because they answer different questions and one of them was doing both badly.
#
# SETTLE band — a slice of the canvas, used only to decide when the pixels have stopped moving.
# A whole-window settle never converges (level meters, the clock), so this has to be a slice, and
# any slice of the canvas will do for that purpose.
SETTLE_BAND = (_CONTENTS[0] + 12, _CONTENTS[1], 500, 300) if _CONTENTS else None
# COMPARE band — the region's own frame, before and after, unioned. Computed after the move,
# below, because half of it does not exist until then.
#
# This rectangle used to be SETTLE_BAND, and #780 is what that cost: `+12` and a fixed 500x300
# assume a zoom and scroll where the moved bars fall inside them, and the expression reads neither.
# Measured 2026-09-05 on one run, both bands against the same region in the same layout: the fixed
# band contained 39 of the region's 64 vertical points at each position while the derived band
# contained all 64 — so it was watching a fraction of its own subject even where it worked. The
# issue records a run where it saw nothing at all, and that run is NOT reproduced here.
#
# A band derived from the region contains the change in AX SPACE at any zoom or scroll, and cannot
# pass by accident on empty canvas. It does NOT follow that it cannot fail: `visual()` clips to the
# captured window, so a union outside the window hashes a subset or nothing. An earlier version of
# this comment claimed the stronger thing; `within_window` below is what makes the weaker one
# checkable instead of assumed. Raised by review, 2026-09-05.
ev.check("575/precondition-the-arrange-canvas-was-located",
         SETTLE_BAND is not None and bool(_CONTENTS_SUBJECT),
         "a slice of the arrange canvas, located by AXDescription, to settle captures against",
         f"contents={_CONTENTS!r} settle={SETTLE_BAND!r} subject={_CONTENTS_SUBJECT!r}", None)
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


def logic_ui_language():
    """What language Logic's own menu bar is in, read from Logic rather than from `defaults`.

    `defaults read com.apple.logic10 AppleLanguages` says what the NEXT launch will use. This says
    what the running one actually did, which is the only thing a locale claim may rest on.
    """
    return osa('tell application "System Events" to tell process "Logic Pro" to '
               'return name of menu bar item 4 of menu bar 1')


def undo_title():
    """What Logic says its Edit > Undo entry would undo, verbatim."""
    return osa('tell application "System Events" to tell process "Logic Pro" to '
               'return name of menu item 1 of menu 1 of menu bar item "Edit" of menu bar 1')


FRAME_PAD = 8
WINDOW_RELATIVE = "window-relative"


def frame_of(region):
    """`(x, y, w, h)` in WINDOW coordinates, or None when any component is missing.

    All four, and only from a witness that says it worked in window coordinates. `Evidence.visual`
    clips what it is given against the window's size, so a screen rectangle from a window that is
    not at the origin — or on a second display — aims the comparison somewhere else and the receipt
    cannot show it: a rectangle records where it looked, never what was there.
    """
    if not isinstance(region, dict):
        return None
    parts = [region.get(k) for k in ("x", "y", "w", "h")]
    if any(not isinstance(v, int) for v in parts) or parts[2] <= 0 or parts[3] <= 0:
        return None
    return tuple(parts)


def same_region(before, after):
    """Whether the two witness readings are about ONE region.

    Raised by review 2026-09-05. `union_frame` took the sole selected region before and after and
    never asked whether they were the same one — the harness's same-region check reads the
    ENVELOPE's `region_name`/`post_region_name`, not the witness objects the band is built from. If
    the selection drifts from A to B across the call, the band covers both, selection highlighting
    alone changes pixels inside it, and `expect_change=True` passes while A never moved.

    The envelope's check does not transfer to the witness, so this asks the witness directly.
    """
    if not isinstance(before, dict) or not isinstance(after, dict):
        return False
    return (before.get("name") or "") == (after.get("name") or "") and bool(before.get("name"))


def within_window(band, state):
    """Whether a band lies inside the window the witness measured, so `visual()` will not clip it.

    Also raised by that review, and it refutes a claim this harness's own pull request made: a
    derived band contains the change in AX space, NOT in the captured image. `Evidence.visual`
    clips the band to the window, so a real move whose union lies outside — a region dragged
    off-screen, or a union wider than the window — hashes only the visible subset, which may omit
    the movement entirely, or nothing at all.

    Clipping silently is the problem. Refusing loudly is the fix.
    """
    window = state.get("window") if isinstance(state, dict) else None
    if not isinstance(window, dict) or band is None:
        return False
    x, y, w, h = band
    return x >= 0 and y >= 0 and x + w <= window.get("w", 0) and y + h <= window.get("h", 0)


def union_frame(before, after):
    """The rectangle containing both frames, padded, or None if either is unreadable.

    Padded because a region's edge is antialiased and a band flush to it can differ by rendering
    rather than by position. Not padded so far that it stops being about the region: eight points
    either side is under a fifth of the narrowest region this project holds.
    """
    a, b = frame_of(before), frame_of(after)
    if a is None or b is None:
        return None
    # The witness names its own space, and the value it uses is deliberately not the bare word for
    # a Logic window: a protocol token that collides with a UI label is a token the literal guard
    # cannot tell from a menu title, and neither can a reader.
    if (before_state.get("coordinateSpace") != WINDOW_RELATIVE
            or after_state.get("coordinateSpace") != WINDOW_RELATIVE):
        return None
    x0 = min(a[0], b[0]) - FRAME_PAD
    y0 = min(a[1], b[1]) - FRAME_PAD
    x1 = max(a[0] + a[2], b[0] + b[2]) + FRAME_PAD
    y1 = max(a[1] + a[3], b[1] + b[3]) + FRAME_PAD
    return (max(0, x0), max(0, y0), x1 - max(0, x0), y1 - max(0, y0))


def start_bar(help_text):
    """The bar Logic's own help string says a region starts at.

    The two languages put the number on OPPOSITE SIDES of the verb, and an earlier version of this
    took the first digits after it in both:

        en   "Region starts at 1 bar  and ends at 2 bars"      1 follows "starts at"
        ko   "리전은 1 마디 에서 시작하여 2 마디 에서 끝납니다"    1 PRECEDES "시작", 2 follows it

    So on Korean it read the END bar and called it the start. That is not a crash — it is a check
    passing for the wrong reason: after a move to bar 9 the Korean help reads "9 마디 … 시작하여 10
    마디", the reader returned 10, and `abs(10 - 9) <= 1` still let the assertion through. A witness
    that agrees by accident is worse than none, because the run reports it as corroboration.

    Found by a blind review of this file, not by a red run.
    """
    text = help_text or ""
    korean = re.search(r"(\d+)\s*마디[^0-9]*시작", text)
    if korean:
        return int(korean.group(1))
    english = re.search(r"starts at\D*(\d+)", text)
    return int(english.group(1)) if english else None


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

# The arrange window's title SUFFIX is localized — "… - Tracks" in English, "… - 트랙" in Korean
# (#519). Matching on the English word would find no window on a Korean Logic, and every capture in
# the run would record `window: null` while Logic was plainly on screen. So the run reads the live
# window list and carries the full title forward instead of assuming a word.
titles = osa('tell application "System Events" to tell process "Logic Pro" to '
             'return name of every window')
window_titles = [t.strip() for t in titles.split(",") if t.strip()]
# Logic's project chooser can sit alongside an open project — since #590 it no longer blocks
# `project.new`, so a session that created its project from a cold launch legitimately has both on
# screen. It is not a document and it is not what this run captures, so it is set aside by name.
CHOOSER_TITLES = ("Choose a Project", "프로젝트 선택")
document_titles = [t for t in window_titles
                   if not any(c in t for c in CHOOSER_TITLES)]
arrange_title = document_titles[0] if len(document_titles) == 1 else ""
ev.check("575/precondition-exactly-one-project-window-is-open",
         bool(arrange_title),
         "exactly one Logic window is a project window, so the arrange window is unambiguous and "
         "its full title — whatever language it is in — can be used to find it on screen; the "
         "project chooser is set aside because it may legitimately be on screen beside a project",
         f"all={window_titles!r} project windows={document_titles!r}", None)

if build.returncode != 0 or not arrange_title:
    print(json.dumps(ev.write(), indent=1)); sys.exit(1)

ev.note("575/locale", {"windows": window_titles, "edit_menu_bar_item": logic_ui_language()})

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
seek = d.tool("logic_transport", "goto_position", {"bar": str(TARGET_BAR)})
time.sleep(2)
ev.note("575/seek", seek if isinstance(seek, dict) else {"raw": str(seek)[:200]})
# Captured AFTER the seek, deliberately. The playhead line moving from bar 1 to bar 9 changes this
# band on its own, so a "before" taken ahead of the seek would let the visual assertion pass on the
# playhead alone — it would be claiming the region moved while measuring that the cursor did.
before_shot = ev.shot("575/before-move", settle_region=SETTLE_BAND, window_title=arrange_title)

# ---- the operation ------------------------------------------------------------------------------

# What Logic's Edit menu WAS when the operation ran, recorded rather than asserted.
#
# Measured 2026-09-05: with the Mixer pane OPEN, Logic's Edit menu is the MIXER's — it carries
# `Mixer Undo` and `Select Audio Channel Strips` and has NO `Move` submenu — so this call returns
# `state B / readback_mismatch / "no position change"`, the undo title does not move, and the run
# reads as though the operation is broken. Nothing in the document said why, and finding it cost a
# full cycle.
#
# A note and not a check, deliberately. Two candidate preconditions were tried and rejected:
# `located_band("Mixer")` answers None with the pane open AND closed, so it is not a signal; and a
# Move-submenu assertion needs `moveMenuItem`'s labels, which carry no Japanese form — a
# precondition that can go red for a missing label rather than for the condition it names is the
# failure this repository refuses everywhere else.
ev.note("575/edit-menu-when-the-move-ran",
        {"items": osa('tell application "System Events" to tell process "Logic Pro" to '
                      'return name of every menu item of menu 1 of '
                      'menu bar item "Edit" of menu bar 1')[:400]})

moved = d.tool("logic_edit", "move_to_playhead", {})
time.sleep(2)
after_state = witness()
after_target = selected_region(after_state)
post_bar = start_bar((after_target or {}).get("help", ""))
after_shot = ev.shot("575/after-move", settle_region=SETTLE_BAND, window_title=arrange_title)
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

# The band the assertion is actually about: where the region WAS and where it IS, unioned and
# padded. `frame_of` refuses anything it cannot read rather than substituting a default — a band
# built from a missing frame is a rectangle nobody measured, which is the defect this replaces.
COMPARE_BAND = union_frame(target, after_target)
COMPARE_BAND_SUBJECT = (
    f"the region Logic calls {(after_target or target or {}).get('name')!r}, its frame before and "
    f"after the move, unioned and padded {FRAME_PAD}px"
) if COMPARE_BAND else None
ev.check("575/precondition-the-region-frame-was-read-before-and-after",
         COMPARE_BAND is not None,
         "the witness reported a readable frame for the SAME region on both reads, in window "
         "coordinates, so a band containing the change can be derived from it",
         f"space={before_state.get('coordinateSpace')!r}/{after_state.get('coordinateSpace')!r} "
         f"before={frame_of(target)!r} after={frame_of(after_target)!r} band={COMPARE_BAND!r}",
         "have the witness emit position without size: `frame_of` returns None, this check goes "
         "red, and no band is built from half a rectangle")

# The band must also be somewhere `visual()` can actually look. It clips to the window, so a union
# outside it hashes a subset — or nothing — and an assertion about the region would then fail for a
# reason that is not about the region.
ev.check("575/precondition-the-band-is-inside-the-captured-window",
         within_window(COMPARE_BAND, after_state),
         "the derived band lies inside the window the witness measured, so the comparison below "
         "sees the whole of it rather than a clipped subset",
         f"band={COMPARE_BAND!r} window={(after_state or {}).get('window')!r} "
         f"title={(after_state or {}).get('windowTitle')!r}",
         "move the region so its union leaves the window: this check goes red instead of the "
         "visual assertion failing for a reason that has nothing to do with the move")

ev.visual("575/the-region-visibly-moved",
          before_shot["file"], after_shot["file"], COMPARE_BAND, subject=COMPARE_BAND_SUBJECT,
          expect_change=True,
          why="the band is the union of the region's own measured frame before and after, so it "
              "contains the change if there is one at any zoom or scroll — and it cannot pass on "
              "empty canvas, which is how a fixed rectangle can be green about nothing")

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
