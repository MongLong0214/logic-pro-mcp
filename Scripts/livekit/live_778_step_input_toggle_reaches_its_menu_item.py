#!/usr/bin/env python3
"""Live proof that `edit.toggle_step_input` reaches the menu item Logic actually has.

Usage:  LPM_EVIDENCE_ROOT=/abs/path/outside/repo \
        python3 live_778_step_input_toggle_reaches_its_menu_item.py <worktree> <full-40-char-head-sha>

WHAT WAS WRONG
--------------
`AXLocalePolicy.showStepInputKeyboardMenuItem` looked for `Show Step Input Keyboard`. Logic 12.3
titles that item `Step Input Keyboard`, with no verb — in every language measured — and it has no
submenu, so the old spelling could not resolve at a deeper level either. Measured before the fix,
on an ENGLISH Logic, calling the operation twice:

    call 1   state C · element_not_found · "Window > Show Step Input Keyboard was not found."
    call 2   state C · same
    windows  unchanged across all three readings

So a registered, advertised operation could not succeed in any locale, and the key-command
destination did not rescue it.

WHY THIS RUN CALLS IT TWICE
---------------------------
It is a TOGGLE. One call that opens a window proves the menu item was reached; a second call that
closes it again proves the run left Logic as it found it AND that the first result was not a
window somebody else opened. One call proves less and leaves a window behind.

WHAT THIS DOES NOT ESTABLISH
----------------------------
Nothing here says why the key-command destination did not answer before the fix — whether that is
routing order, a missing binding, or the AX channel being the only registered destination. The run
drives the operation and reads Logic's window list; it does not inspect the router.
"""

import json
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import evidence as E  # noqa: E402

COVERS = [
    "Sources/LogicProMCP/Channels/AccessibilityChannel+Editing.swift",
]

WT = sys.argv[1] if len(sys.argv) > 1 else ""
HEAD = sys.argv[2] if len(sys.argv) > 2 else ""
if not WT or not HEAD:
    sys.exit(__doc__)

E.REPO = WT
E.BIN = f"{WT}/.build/release/LogicProMCP"
missing = E.have_tools()
if missing:
    sys.exit(f"cannot run: missing {missing}")


def windows():
    """Logic's on-screen windows, from CoreGraphics — not from the server, and not from Logic.

    The server is what is under test, so a window count from its own envelope would let the
    operation certify itself. That is why this reads the list separately.

    It reads it through CoreGraphics rather than System Events, and that is not a style choice.
    Measured 2026-09-05: driving this toggle while asking System Events for
    `name of every window` crashed Logic — `EXC_BAD_ACCESS`, "Thread stack size exceeded due to
    excessive recursion", with `-[NSApplication windows]` and `-[NSApplication _copyWindows]` on
    the faulting thread. Asking an application to enumerate its own windows while it is opening one
    reaches into its AppKit state; the CoreGraphics window list is the window server's own record
    and asks Logic nothing.

    `E.logic_window()` is the same source and returns one window; this needs all of them, so it
    reads the list the same way that function does.
    """
    try:
        import Quartz
    except ImportError:
        return ""
    found = []
    for w in E._on_screen_windows(Quartz) or []:
        if E._is_logic_owned_window(w):
            name = w.get("kCGWindowName") or ""
            if name:
                found.append(name)
    return ", ".join(found)


ev = E.Evidence(HEAD, os.environ["LPM_EVIDENCE_ROOT"])
rec = ev.record_screen(seconds=90)
d = E.Driver()

# The band is the Logic window's own title bar area, located by the arrange canvas — the Step Input
# Keyboard opens as a SEPARATE window, so the arrange canvas is where its absence and presence are
# NOT visible. That is deliberate: the visual assertion below is negative, and it is the honest one
# to make, because what this operation changes is the window list rather than the arrange content.
CANVAS, CANVAS_SUBJECT = ev.located_band("Tracks contents")
ev.check("778/precondition-the-arrange-canvas-was-located",
         CANVAS is not None and bool(CANVAS_SUBJECT),
         "the arrange canvas, located by AXDescription, to settle captures against",
         f"band={CANVAS!r} subject={CANVAS_SUBJECT!r}", None)

before_windows = windows()
ev.note("778/windows-before", {"windows": before_windows[:300]})
ev.check("778/precondition-the-step-input-window-is-not-already-open",
         "Step Input" not in before_windows and "스텝 입력" not in before_windows
         and "ステップインプット" not in before_windows,
         "the window this operation opens is not on screen before the run, so a window seen after "
         "the first call was opened by it",
         f"windows={before_windows[:200]!r}", None)

if CANVAS is None:
    d.close(); ev.stop_recording(rec)
    print(json.dumps(ev.write(), indent=1)); sys.exit(1)

pre = ev.shot("778/before-toggle", settle_region=CANVAS)

opened = d.tool("logic_edit", "toggle_step_input") or {}
time.sleep(2)
after_open = windows()
ev.note("778/open", {"envelope": {k: opened.get(k) for k in
                                  ("state", "verified", "error", "hint", "previous_open",
                                   "observed_open", "via")},
                     "windows": after_open[:300]})

# The counterexample is the envelope this operation returned before the fix, against this same
# application: State C with the hint naming a menu item Logic does not have.
ev.falsifiable(
    "778/the-operation-reaches-its-menu-item",
    lambda o: o.get("state") == "A" and o.get("verified") is True
    and o.get("observed_open") is True,
    opened,
    {"state": "C", "error": "element_not_found",
     "hint": "Window > Show Step Input Keyboard was not found."},
    "the operation returns State A verified with the window observed open, rather than the "
    "element_not_found refusal it returned when the policy looked for a title Logic does not have",
    "restore `Show Step Input Keyboard` as the canonical: the menu lookup finds nothing and the "
    "channel returns exactly the counterexample")

# The independent half. The envelope says `observed_open`; this says Logic's window list changed,
# read by something that is not the server.
ev.falsifiable(
    "778/logic-itself-lists-the-window-it-opened",
    lambda w: isinstance(w, str)
    and any(t in w for t in ("Step Input Keyboard", "스텝 입력 키보드", "ステップインプットキーボード")),
    after_open,
    before_windows,
    "Logic's own window list gains the Step Input Keyboard window, in whichever language it is "
    "running — read through osascript, not through the server whose operation is under test",
    "make the channel report success without pressing the menu item: the envelope still claims the "
    "toggle and this check, which never reads the envelope, goes red")

closed = d.tool("logic_edit", "toggle_step_input") or {}
time.sleep(2)
after_close = windows()
ev.note("778/close", {"envelope": {k: closed.get(k) for k in
                                   ("state", "verified", "error", "previous_open", "observed_open")},
                      "windows": after_close[:300]})
ev.check("778/the-second-call-closes-it-again",
         closed.get("state") == "A" and closed.get("observed_open") is False
         and not any(t in after_close for t in
                     ("Step Input Keyboard", "스텝 입력 키보드", "ステップインプットキーボード")),
         "the toggle's second call returns State A with the window observed closed, and Logic's "
         "window list no longer carries it — which is both halves of a toggle and the restoration",
         f"state={closed.get('state')!r} observed_open={closed.get('observed_open')!r} "
         f"windows={after_close[:160]!r}",
         "return early after the first press: the window stays open, this check goes red, and the "
         "run leaves Logic in a state it did not find it in")

post = ev.shot("778/after-toggle", settle_region=CANVAS)
ev.visual("778/the-arrange-canvas-is-not-what-changed",
          pre["file"], post["file"], CANVAS, subject=CANVAS_SUBJECT, expect_change=False,
          why="the Step Input Keyboard opens as a SEPARATE window, so the arrange canvas must be "
              "unchanged across a toggle that opened and closed it — an assertion that it DID "
              "change would be describing something other than this operation")

d.close()
ev.restored("778/the-window-is-closed-again",
            not any(t in after_close for t in
                    ("Step Input Keyboard", "스텝 입력 키보드", "ステップインプットキーボード")),
            f"opened and closed by the operation's own two calls; Logic's window list ends at "
            f"{after_close[:120]!r}")

ev.stop_recording(rec)
out = ev.write()
print(json.dumps(out, indent=1))
sys.exit(0 if E.is_clean(out) else 1)
