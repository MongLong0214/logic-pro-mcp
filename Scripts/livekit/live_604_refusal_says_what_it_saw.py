#!/usr/bin/env python3
"""Live proof that a save_as refusal is legible and leaves nothing blocking behind it.

Usage:  LPM_EVIDENCE_ROOT=/abs/path/outside/repo \
        python3 live_604_refusal_says_what_it_saw.py <worktree> <full-40-char-head-sha>

WHAT THIS RUN IS ABOUT
----------------------
`project.save_as` does not work on this host, and this change does not fix that. What it changes is
the refusal.

The old message was "Exact Save As dialog did not appear within 3 seconds". Timed from the menu
click, the panel appears in 0.75s — so the budget was never the failure, and the message sent the
reader to the wrong place. It also returned before the dismissal helper is even defined, leaving the
panel on screen; every later operation then refused with `preflight_blocking_dialog` on a "Save"
window that exposes no buttons a caller can answer with.

So the run drives the failing operation on purpose and checks two things about how it fails: that the
refusal names the shape it actually saw, and that the next operation is not blocked by a leftover
panel.

The classifier is untouched. Its filename-field clause is what fails, and two readers disagree about
that panel — AppleScript's `entire contents` finds 156 text fields described "text field" while this
code's own reader finds zero at the same depth. Until that is explained, any replacement rule is a
guess, and the honest deliverable is a failure that can be read.
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
CHOOSER_TITLES = ("Choose a Project", "프로젝트 선택")
TARGET = "/Users/isaac/Music/Logic/lpm-604-refusal-proof.logicx"


def osa(script):
    r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
    return (r.stdout or "").strip()


def window_titles():
    raw = osa('tell application "System Events" to tell process "Logic Pro" to '
              'return name of every window')
    return [t.strip() for t in raw.split(",") if t.strip()] if raw else []


def document_titles():
    return [t for t in window_titles() if not any(c in t for c in CHOOSER_TITLES)]


def save_panels():
    """Windows AND sheets that are the modal surface a failed Save As leaves behind.

    The first cut of this file compared `len(window_titles())` against `len(document_titles())`,
    which only ever says "no project chooser is visible" — a leftover window named Save sits in
    BOTH lists, so the mutation those checks named could not turn them red. This asks the
    question the checks were written to ask.
    """
    raw = osa('tell application "System Events" to tell process "Logic Pro" to '
              'return (name of every window whose name is "Save") & '
              '(name of every sheet of every window)')
    return [t.strip() for t in raw.split(",") if t.strip() == "Save"]


def inner(result):
    return result if isinstance(result, dict) else {}


titles = document_titles()
ev.check("604/precondition-a-project-is-open", bool(titles),
         "Logic has a project window, so File > Save As has something to save",
         f"windows={window_titles()!r}", None)
if not titles:
    print(json.dumps(ev.write(), indent=1)); sys.exit(1)

# The first document window is not necessarily the arrange window: a plugin window carries the TRACK
# name ("Absolute Zero" here), and picking it gave a title `logic_window` could not find a frame for.
# So the run picks the largest window it can actually locate on screen, which is the arrange window
# on any layout, and needs no knowledge of the title's language.
located = [(t, E.logic_window(t)) for t in titles]
located = [(t, w) for t, w in located if w]
located.sort(key=lambda pair: pair[1]["w"] * pair[1]["h"], reverse=True)
arrange_title, win = located[0] if located else (titles[0], None)
band = (0, 0, win["w"], 28) if win else None
ev.check("604/precondition-the-window-frame-is-known", band is not None,
         "the arrange window's own frame read, so the capture band is inside it",
         f"window={win!r} band={band!r}", None)
if band is None:
    print(json.dumps(ev.write(), indent=1)); sys.exit(1)

ev.check("604/precondition-nothing-is-blocking-before-the-run",
         len(window_titles()) == len(document_titles()),
         "no modal is up when the run starts, so a blocking dialog afterwards is one this operation "
         "left behind rather than one it inherited",
         f"windows={window_titles()!r}", None)

rec = ev.record_screen(seconds=150)
before = ev.shot("604/before", settle_region=band, window_title=arrange_title)

d = E.Driver()
time.sleep(5)

# Logic must own the keyboard or the menu press opens NO panel at all — measured four times on
# 2026-08-19: backgrounded 0/2 panels, frontmost 2/2. Without this the refusal under test would be
# refusing an absent panel, the dismissal would never run, and the checks below could not tell a
# working dismissal from a missing one.
osa('tell application "Logic Pro" to activate')
time.sleep(2)
front = osa('tell application "System Events" to return name of first process whose frontmost is true')
ev.check("604/precondition-logic-owns-the-keyboard",
         front == "Logic Pro",
         "the menu press lands in Logic, so a Save panel actually opens and there is something for "
         "the refusal to describe and the dismissal to clear",
         f"frontmost={front!r}",
         None)

saved = inner(d._send("tools/call", {"name": "logic_project", "arguments": {
    "command": "save_as", "params": {"path": TARGET, "confirmed": True}}}))
text = ((saved.get("result") or {}).get("content") or [{}])[0].get("text", "")
try:
    body = json.loads(text)
except ValueError:
    body = {"raw": text[:400]}
hint = str(body.get("hint") or body.get("raw") or "")
ev.note("604/save-as", {"error": body.get("error"), "hint": hint[:400]})

ev.check("604/the-refusal-names-the-shape-it-saw",
         all(k in hint for k in ("filename_fields", "save_buttons", "subrole", "Candidates enumerated:")),
         "the refusal reports each candidate window's observed counts INCLUDING subrole — one of the "
         "seven conjuncts — so the failing clause is visible in its own output instead of guessed at",
         f"hint={hint[:300]!r}",
         "restore the old message: it says only that the panel did not appear within three seconds, "
         "which is a cause that was never measured — the panel is on screen in 0.75s")

ev.check("604/the-refusal-says-whether-logic-owned-the-keyboard",
         "Logic owned the keyboard when the menu was pressed: true" in hint,
         "the refusal distinguishes the two worlds it can fail in — panel-absent-because-backgrounded "
         "versus panel-present-but-unclassified. Measured 2026-08-19: the same menu press opens no "
         "panel at all when Logic is backgrounded (0/2) and one panel when it is frontmost (2/2), so "
         "a message that omits this fact points the reader at the classifier for a missing panel",
         f"hint={hint[:300]!r}",
         "drop the `logic_owned_the_keyboard` observation from the refusal: this goes red")

ev.check("604/the-refusal-does-not-claim-a-timing-cause-it-never-measured",
         "within 3 seconds" not in hint,
         "the message no longer asserts a timeout as the reason; the panel appears in 0.75s and the "
         "budget was never what failed",
         f"hint={hint[:200]!r}",
         "restore the old message: this check goes red on the sentence that sent the last reader to "
         "look at timing")

time.sleep(2)
after_titles = window_titles()
ev.note("604/windows-after", after_titles)

panels_left = save_panels()
ev.check("604/no-panel-is-left-blocking-the-next-operation",
         len(panels_left) == 0,
         "no Save panel remains after the refusal — the old timeout path returned before its "
         "dismissal helper was even defined, and the panel it left up refused every later operation",
         f"save_panels={panels_left!r} all_windows={after_titles!r}",
         "remove the `escapeAnyOpenPanel` call from the timeout path: the 'Save' window stays on "
         "screen, `save_panels()` returns it, and this check goes red")

# The decisive one: the NEXT operation must not be refused by something this run left behind.


after = ev.shot("604/after", settle_region=band, window_title=arrange_title)
# This capture is `screencapture -l <arrange window id>`, so a top-level Save dialog is not in
# frame and its presence could never move this band. The assertion is therefore the narrower true
# one — the refusal disturbed nothing behind it. "The panel is gone" is claimed by
# `604/no-panel-is-left-blocking-the-next-operation`, which can see the panel.
ev.visual("604/the-arrange-window-behind-is-undisturbed",
          before["file"], after["file"], band, expect_change=False,
          why="a refusal that writes nothing must leave the document window exactly as it found it; "
              "a difference in the title band would mean the failed save renamed or dirtied it")

# `system.health` was the wrong witness: it builds its report from channel health, cache and
# permissions and never consults `blockingDialogInfo()`, so it cannot report a blocking dialog no
# matter what is on screen. `list_library` (which routes `library.list`) is read-only AND runs the same preflight the mutating
# operations do (TrackDispatcher: `blockingLogicDialogResult(operation: "library.list")`), so a
# leftover panel actually turns this red. It runs AFTER the visual comparison because listing
# the Library can open Logic's Library panel, which would move the very window the visual guards.
follow = d.tool("logic_tracks", "list_library", {})
follow_hint = str((follow or {}).get("hint") or "")
ev.check("604/the-next-operation-is-not-blocked-by-what-this-one-left",
         isinstance(follow, dict) and "preflight_blocking_dialog" not in str(follow),
         "a later operation that fails closed on blocking modals runs instead of refusing — which "
         "is what a leftover panel does to everything that follows it",
         f"error={(follow or {}).get('error')!r} hint={follow_hint[:160]!r}",
         "remove the dismissal: `list_library` refuses with `preflight_blocking_dialog`, and so "
         "would every mutating call after it")

d.close()
ev.restored("604/no-file-was-written-and-no-panel-remains",
            not os.path.exists(TARGET) and not save_panels(),
            f"the save did not complete, so no project was written to {TARGET!r} — that is the "
            f"failure under study, not a side effect — and no modal is left on screen. "
            f"Save panels: {save_panels()!r} Windows: {window_titles()!r}")

ev.stop_recording(rec)
out = ev.write()
print(json.dumps(out, indent=1))
sys.exit(0 if E.is_clean(out) else 1)
