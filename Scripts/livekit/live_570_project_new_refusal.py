#!/usr/bin/env python3
"""Live proof that `project.new` explains its refusal instead of misdescribing it.

Usage:  LPM_EVIDENCE_ROOT=/abs/path/outside/repo \
        python3 live_570_project_new_refusal.py <worktree> <full-40-char-head-sha>

WHAT WAS WRONG
--------------
Measured on desktop Logic Pro 12.3 with one project open:

    {"error":"channels_exhausted",
     "hint":"Creator Studio has a non-chooser window; refusing project.new"}

Two false statements about the caller's situation. The operator is running Logic Pro, not Creator
Studio. And `channels_exhausted` means "every channel in the chain reported itself unavailable",
while here the single accessibility channel ran and declined on purpose — a bare sentence is not
something `ChannelRouter` can recognise as a State C envelope, so it fell through to the exhaustion
wrapper.

THE REFUSAL IS CORRECT AND STAYS
--------------------------------
With a document already open, a newly created project's window cannot be told apart from the ones
already on screen. This run does NOT assert that `project.new` succeeds with a project open; it
asserts that the refusal says which precondition failed, what was observed, that nothing was
written, and how to recover — and that the recovery it names actually works.

THE TRIGGER IS AN OPEN DOCUMENT, SO THE RUN ESTABLISHES IT FIRST
----------------------------------------------------------------
Against a Logic with no document open the refusal never happens and every check below would be
vacuous. The run therefore requires a window to be present and stops if it cannot get one.
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
d = E.Driver()

# Window-relative band over the track headers of the arrange window (measured 1920x1050 at 0,30).
# Deliberately over content the caller owns: the claim is that a REFUSED project.new leaves it alone.
TRACK_BAND = (10, 120, 260, 200)


def osa(script):
    r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
    return (r.stdout or "").strip()


def window_names():
    return osa('tell application "System Events" to tell process "Logic Pro" to '
               'return name of every window')


def window_count():
    raw = osa('tell application "System Events" to tell process "Logic Pro" to '
              'return count of every window')
    return int(raw) if raw.isdigit() else None


def body_of(result):
    return result if isinstance(result, dict) else {}


# ---- establish the trigger: a document must be open ------------------------------------------
if (window_count() or 0) == 0:
    d.tool("logic_project", "new", {})
    time.sleep(6)

open_windows = window_count()
ev.check("570/precondition-a-document-is-open", (open_windows or 0) > 0,
         "Logic has at least one window, which is the state this refusal is about",
         f"window_count={open_windows!r} names={window_names()!r}",
         # No mutation: this is the trigger. Against a Logic with nothing open the refusal never
         # fires and every check below would pass without observing it.
         None)
if not open_windows:
    d.close()
    print(json.dumps(ev.write(), indent=1)); sys.exit(1)

rec = ev.record_screen(seconds=150)
before = ev.shot("570/before-refused-new", settle_region=TRACK_BAND)

refused = body_of(d.tool("logic_project", "new", {}))
time.sleep(1.5)
ev.note("570/refusal", refused)

ev.check("570/refusal-names-the-precondition-not-the-channel-chain",
         refused.get("error") == "unsupported_state",
         "the refusal is classified as an unsupported state, not as an exhausted channel chain",
         f"error={refused.get('error')!r} failure_stage={refused.get('failure_stage')!r}",
         "return the refusal as a bare sentence again: ChannelRouter cannot recognise prose as a "
         "State C envelope and relabels it channels_exhausted, which sends the caller to look at "
         "channel health when no channel is unhealthy")

hint = refused.get("hint") or ""
ev.check("570/refusal-does-not-blame-a-product-the-operator-is-not-running",
         "Creator Studio" not in hint,
         "the hint describes THIS Logic, not Creator Studio",
         f"hint={hint!r}",
         "restore the Creator Studio wording — it is what a desktop Logic Pro operator was told, "
         "about a product they may never have installed")

ev.check("570/refusal-reports-what-it-observed",
         refused.get("observed_window_count") == open_windows,
         "the reported window count equals the count read outside the product",
         f"reported={refused.get('observed_window_count')!r} externally_observed={open_windows!r}",
         "drop observed_window_count: the caller is told a precondition failed with no way to see "
         "how far off they are")

ev.check("570/refusal-is-pre-write",
         refused.get("write_attempted") is False and refused.get("safe_to_retry") is True,
         "nothing was attempted and the call is safe to retry, and the envelope says both",
         f"write_attempted={refused.get('write_attempted')!r} "
         f"safe_to_retry={refused.get('safe_to_retry')!r}",
         "omit write_attempted: a caller cannot tell a refusal-before-acting from a failed write")

after = ev.shot("570/after-refused-new", settle_region=TRACK_BAND)
ev.visual("570/a-refused-new-leaves-the-open-project-alone",
          before["file"], after["file"], TRACK_BAND, expect_change=False,
          why="the refusal reports write_attempted:false, so the open project's track headers must "
              "be untouched across it")

# ---- the recovery the envelope names must actually work ---------------------------------------
recovery = refused.get("recovery_action") or ""
ev.check("570/recovery-action-names-the-confirmed-close",
         "confirmed: true" in recovery,
         "the recovery names the confirmed form of close",
         f"recovery_action={recovery!r}",
         "name the bare `project.close`: it answers confirmation_required, so following the "
         "instruction lands the caller in a second refusal")

bare_close = body_of(d.tool("logic_project", "close", {}))
ev.check("570/the-bare-close-really-is-refused",
         bare_close.get("status") == "confirmation_required",
         "close without confirmation is refused, which is why the recovery text names the "
         "confirmed form",
         f"status={bare_close.get('status')!r}",
         # No mutation: this measures Logic-side/product gating that this change does not touch. It
         # is here so the recovery wording is checked against behaviour, not against my memory of it.
         None)

d.tool("logic_project", "close", {"confirmed": True})
time.sleep(5)
after_close = window_count()
created = body_of(d.tool("logic_project", "new", {}))
time.sleep(4)
after_new = window_names()
ev.note("570/recovery", {"after_close_window_count": after_close, "created": created,
                         "windows_after": after_new})

ev.check("570/the-named-recovery-actually-creates-a-project",
         after_close == 0 and created.get("state") in ("A", "B")
         and bool(created.get("window_title")),
         "closing with confirmation empties Logic, and project.new then creates a document",
         f"after_close={after_close!r} state={created.get('state')!r} "
         f"window_title={created.get('window_title')!r} error={created.get('error')!r}",
         "point the recovery at something that does not clear the precondition — the caller would "
         "follow the instruction and hit the same refusal")

ev.restored("570/logic-is-left-with-a-project-open",
            bool(after_new),
            f"windows after the run: {after_new!r}. The run closes the document it found — that is "
            f"the recovery being proven, not a side effect — and leaves the project it created.")

ev.stop_recording(rec)
d.close()
out = ev.write()
print(json.dumps(out, indent=1))
sys.exit(0 if E.is_clean(out) else 1)
