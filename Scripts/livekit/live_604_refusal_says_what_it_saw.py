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
         "filename_fields" in hint and "save_buttons" in hint and "Save" in hint,
         "the refusal reports each candidate window's observed counts, so the failing clause of a "
         "seven-conjunct rule is visible in its own output instead of being guessed at",
         f"hint={hint[:260]!r}",
         "restore the old message: it says only that the panel did not appear within three seconds, "
         "which is a cause that was never measured — the panel is on screen in 0.75s")

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

ev.check("604/no-panel-is-left-blocking-the-next-operation",
         len(after_titles) == len(document_titles()),
         "no modal remains after the refusal — the old timeout path returned before its dismissal "
         "helper was even defined, and the panel it left up refused every later operation",
         f"windows={after_titles!r}",
         "remove the `escapeAnyOpenPanel` call from the timeout path: a 'Save' window stays on "
         "screen and this check goes red")

# The decisive one: the NEXT operation must not be refused by something this run left behind.
follow = d.tool("logic_system", "health", {})
follow_hint = str((follow or {}).get("hint") or "")
ev.check("604/the-next-operation-is-not-blocked-by-what-this-one-left",
         isinstance(follow, dict) and "preflight_blocking_dialog" not in str(follow),
         "an unrelated operation immediately afterwards runs instead of refusing on a blocking "
         "dialog — which is what a leftover panel does to everything that follows it",
         f"error={(follow or {}).get('error')!r} hint={follow_hint[:160]!r}",
         "remove the dismissal: this check reports `preflight_blocking_dialog` for `system.health`, "
         "and would for every later call too")

after = ev.shot("604/after", settle_region=band, window_title=arrange_title)
ev.visual("604/the-panel-is-gone-from-the-screen",
          before["file"], after["file"], band, expect_change=False,
          why="the run opens a Save panel and the refusal dismisses it, so the window behind must "
              "look exactly as it did before — a difference here would mean the panel is still up or "
              "something else changed")

d.close()
ev.restored("604/no-file-was-written-and-no-panel-remains",
            not os.path.exists(TARGET) and len(window_titles()) == len(document_titles()),
            f"the save did not complete, so no project was written to {TARGET!r} — that is the "
            f"failure under study, not a side effect — and no modal is left on screen. "
            f"Windows: {window_titles()!r}")

ev.stop_recording(rec)
out = ev.write()
print(json.dumps(out, indent=1))
sys.exit(0 if E.is_clean(out) else 1)
