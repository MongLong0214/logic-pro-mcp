"""Live proof that a fresh process's first call is not refused for a dialog that is not there.

Usage:  LPM_EVIDENCE_ROOT=/abs/path/outside/repo \
        python3 live_608_first_call_is_not_refused.py <worktree> <full-40-char-head-sha>

WHAT THIS RUN IS ABOUT
----------------------
Every mutating operation consults a fail-closed blocking-dialog guard. In a FRESH process that guard
refused the first call, on a screen holding one ordinary window and nothing else. Measured before the
fix, four trials out of four, with the refusal's own instrumentation:

    last_dialog_presence_reason   windows_read_failed
    windows_read_ax_error         -25204   (kAXErrorCannotComplete)
    dialog_present_recheck        false    (the same read, milliseconds later)

So the AX messaging to Logic had not gone through yet, and the guard reported that as
`blocking_dialog_present: true` — sending an operator to dismiss a modal that does not exist.

The fix re-reads ONCE, and only on that status. A read that succeeds is never re-read, whatever it
says, so this is not "retry until the answer is convenient" — it is "a failed read is not an
observation". Both halves are checked here, because a fix that stops refusing is worthless if it also
stops refusing when it should.
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


def osa(script):
    r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
    return (r.stdout or "").strip()


def window_titles():
    raw = osa('tell application "System Events" to tell process "Logic Pro" to '
              'return name of every window')
    return [t.strip() for t in raw.split(",") if t.strip()] if raw else []


def save_panels():
    raw = osa('tell application "System Events" to tell process "Logic Pro" to '
              'return (name of every window whose name is "Save")')
    return [t.strip() for t in raw.split(",") if t.strip() == "Save"]


def first_call_in_a_fresh_process():
    """Spawn the server, make ONE read-only call, and return its parsed body.

    `logic_tracks.list_library` is read-only and runs the same preflight the mutating operations do,
    so it exercises the guard without writing anything.
    """
    d = E.Driver()
    try:
        return d.tool("logic_tracks", "list_library", {}) or {}
    finally:
        d.close()


titles = window_titles()
ev.check("608/precondition-a-project-is-open", bool(titles),
         "Logic has a project window, so the guard has an ordinary window to look at and any refusal "
         "is about the read rather than about an empty app",
         f"windows={titles!r}", None)
if not titles:
    ev.write()
    sys.exit("no project open")

ev.check("608/precondition-no-dialog-is-on-screen-to-begin-with",
         not save_panels(),
         "nothing modal is up before the run, so a refusal in the next check cannot be a correct one",
         f"save_panels={save_panels()!r} windows={titles!r}", None)

located = [(t, E.logic_window(t)) for t in titles]
located = [(t, w) for t, w in located if w]
located.sort(key=lambda pair: pair[1]["w"] * pair[1]["h"], reverse=True)
arrange_title, win = located[0] if located else (titles[0], None)
band = (0, 0, win["w"], 28) if win else None
ev.check("608/precondition-the-window-frame-is-known", band is not None,
         "the arrange window's own frame read, so the capture band is inside it",
         f"window={win!r} band={band!r}", None)
if band is None:
    print(json.dumps(ev.write(), indent=1)); sys.exit(1)

rec = ev.record_screen(seconds=120)
before = ev.shot("608/before", settle_region=band, window_title=arrange_title)

# ---- the fix: four independent fresh processes, each making exactly one call ----
bodies = [first_call_in_a_fresh_process() for _ in range(4)]
ev.note("608/fresh-process-first-calls", [
    {"error": b.get("error"),
     "blocking_dialog_present": b.get("blocking_dialog_present"),
     "reason": b.get("last_dialog_presence_reason"),
     "ax_error": b.get("windows_read_ax_error")}
    for b in bodies
])

refused = [b for b in bodies if b.get("error") == "unsupported_state"]
ev.check("608/no-fresh-process-is-refused-on-its-first-call",
         len(refused) == 0,
         "four separate server processes each make one read-only call as their FIRST call and none "
         "is refused — before the fix this was refused 4 times out of 4 with "
         "windows_read_ax_error -25204 on the same screen",
         f"refused={len(refused)}/4 details={[b.get('last_dialog_presence_reason') for b in bodies]!r}",
         "change the `error.raw == AXError.cannotComplete.rawValue` re-read condition to `false`: "
         "every one of these four is refused again and this goes red")

ev.check("608/the-first-call-actually-did-its-work",
         all("categories" in json.dumps(b) for b in bodies),
         "each call returned its real payload rather than merely not erroring — a refusal that was "
         "downgraded to a silent empty success would pass the check above and fail this one",
         f"payload_present={[('categories' in json.dumps(b)) for b in bodies]!r}", None)

# ---- the negative control: with a REAL dialog up, the guard must still refuse ----
osa('tell application "Logic Pro" to activate')
time.sleep(2)
osa('tell application "System Events" to tell process "Logic Pro" to '
    'click menu item "Save As…" of menu 1 of menu bar item 3 of menu bar 1')
time.sleep(4)
panel_up = save_panels()
ev.check("608/negative-control-a-real-panel-is-on-screen",
         bool(panel_up),
         "a genuine modal was opened, so the next check is asked in the condition the guard exists "
         "for — without this the negative control would be green because nothing was ever there",
         f"save_panels={panel_up!r} windows={window_titles()!r}", None)

blocked = first_call_in_a_fresh_process()
ev.note("608/first-call-with-a-real-panel", {
    "error": blocked.get("error"),
    "blocking_dialog_present": blocked.get("blocking_dialog_present"),
    "failure_stage": blocked.get("failure_stage"),
    "dialog_title": blocked.get("dialog_title"),
})
ev.check("608/a-real-dialog-still-refuses-and-is-named",
         blocked.get("error") == "unsupported_state"
         and blocked.get("blocking_dialog_present") is True
         and blocked.get("dialog_title") == "Save",
         "the guard still fails closed on an actual modal AND names it — the fix removed a false "
         "refusal, and this is what proves it did not remove the true one",
         f"error={blocked.get('error')!r} blocking={blocked.get('blocking_dialog_present')!r} "
         f"title={blocked.get('dialog_title')!r} stage={blocked.get('failure_stage')!r}",
         "make `dialogPresent` return false unconditionally: this goes red while the four checks "
         "above stay green, which is exactly the trade this check exists to catch")

osa('tell application "System Events" to key code 53')
time.sleep(2)

after = ev.shot("608/after", settle_region=band, window_title=arrange_title)
ev.visual("608/the-guard-changed-nothing-on-screen",
          before["file"], after["file"], band, expect_change=False,
          why="this whole change is to a read-only preflight, so the document window must look "
              "exactly as it did — a difference would mean something in the run wrote to the project")

ev.restored("608/the-panel-opened-by-the-negative-control-is-gone",
            not save_panels(),
            f"the Save panel this run opened on purpose was dismissed. Save panels now: "
            f"{save_panels()!r}. Windows: {window_titles()!r}")

ev.stop_recording(rec)
out = ev.write()
print(json.dumps(out, indent=1))
