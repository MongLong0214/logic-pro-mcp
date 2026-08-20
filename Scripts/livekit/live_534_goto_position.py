#!/usr/bin/env python3
"""Live proof for transport.goto_position (#534) against the running Logic Pro.

Usage:  LPM_EVIDENCE_ROOT=/abs/path/outside/repo \
        python3 live_534_goto_position.py <worktree> <full-40-char-head-sha>

What this proves, and why each check exists:

- The playhead actually MOVES. Verification for this operation used to be granted by a post-read that
  merely equalled the request, which is satisfied by a playhead that was already there. The run parks
  the playhead first and asserts a transition, so a no-op cannot pass.
- The route under test is the one that ran. A sibling router rung can move the playhead by other means;
  an envelope that says `via: dialog` while a later rung did the work is not evidence about this route.
- The receipt does not claim more than it observed. Logic's control bar exposes only bar and beat, so a
  four-component State A would be synthesised rather than read.
- The dialog does not outlive the operation. A modal left on screen poisons every later call.
"""

import json
import os
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

PARK = "1.1.1.1"
TARGET = "37.3.1.1"

ev = E.Evidence(HEAD, os.environ["LPM_EVIDENCE_ROOT"])
rec = ev.record_screen(seconds=45)
d = E.Driver()


def playhead():
    """The transport readout, read live rather than from cache."""
    body = d.tool("logic_transport", "goto_position", {"position": PARK}) if False else None
    return d.resource("logic://transport")


win = E.logic_window()
if not win:
    ev.check("534/precondition-logic-window", False,
             "Logic's Tracks window is on screen", "no window found",
             "closed the Tracks window; this check went red")
    d.close()
    ev.stop_recording(rec)
    print(json.dumps(ev.write(), indent=1))
    sys.exit(1)

# The transport LCD sits in the control bar along the top of the arrange window. The region is named so
# the visual assertion is about the readout, not about "some pixel somewhere changed" — Logic repaints
# meters continuously and a whole-window diff is always true.
# The playhead-position readout, located by the AXDescription it carries. What stood here was a
# fraction of the window — measured 2026-08-20 those fractions give (806, 0, 652, 57), which is a
# 652-point slab of the control bar starting inside the title bar, while the readout itself is
# 120x50 at (828, 27). Wide enough to hold the answer, and wide enough to hold the tempo field, the
# transport buttons and whatever else Logic repaints up there.
LCD, LCD_SUBJECT = ev.located_band("Playhead Position")
ev.check("534/precondition-the-position-readout-was-located",
         LCD is not None and bool(LCD_SUBJECT),
         "the transport's playhead-position readout, located by AXDescription",
         f"band={LCD!r} subject={LCD_SUBJECT!r}", None)

# ---- precondition: park the playhead so the measured move is unambiguous ----
park_body = d.tool("logic_transport", "goto_position", {"position": PARK})
time.sleep(0.8)
before_state = d.resource("logic://transport")
ev.note("precondition", {"park_result_state": park_body.get("state"),
                         "transport_before": before_state})

pre = ev.shot("before-goto", settle_region=LCD)

# ---- the operation under test ----
body = d.tool("logic_transport", "goto_position", {"position": TARGET})
time.sleep(0.8)
post = ev.shot("after-goto", settle_region=LCD)
ev.note("response", {"body": body})

observed_before = body.get("observed_before")
observed = body.get("observed")

ev.check("534/the-playhead-actually-moved",
         bool(observed_before) and bool(observed) and observed_before != observed,
         "the readout differs before and after, so a transition was observed",
         f"observed_before={observed_before!r} observed={observed!r}",
         "restored verification-by-equality; a request equal to the current position then passed")

ev.check("534/the-requested-bar-and-beat-are-reached",
         str(observed or "").startswith("37.3"),
         "the playhead lands on bar 37 beat 3",
         f"requested={body.get('requested')!r} observed={observed!r}",
         "dropped the beat from the typed position; the readout stayed on 37.1")

ev.check("534/the-request-is-not-silently-rewritten",
         body.get("requested") == TARGET,
         f"the envelope echoes {TARGET}",
         f"requested={body.get('requested')!r}",
         "rewrote the request to the nearest bar before echoing it")

ev.check("534/the-operation-under-test-actually-ran",
         body.get("error") is None and body.get("write_attempted") is True,
         "the envelope is an outcome of goto_position, not a routing refusal",
         f"state={body.get('state')!r} error={body.get('error')!r} "
         f"write_attempted={body.get('write_attempted')!r}",
         "made the menu lookup fail; the run became a refusal with write_attempted false")

ev.check("534/a-partial-readback-is-not-certified-complete",
         not (body.get("state") == "A" and
              body.get("observed_position_components") not in (None, [])
              and len(body.get("observed_position_components") or []) < 4),
         "State A is withheld while subdivision and tick are unobserved",
         f"state={body.get('state')!r} components={body.get('observed_position_components')!r}",
         "let a two-component readback certify State A; a bar/beat-only read was reported verified")

ev.check("534/the-dialog-does-not-outlive-the-operation",
         body.get("dialog_cleanup") in ("closed", None),
         "no Go To Position window remains after the route returns",
         f"dialog_cleanup={body.get('dialog_cleanup')!r}",
         "skipped the dismissal; the modal stayed up and the next call refused")

ev.visual("534/the-transport-readout-moves-with-the-operation",
          pre["file"], post["file"], LCD, subject=LCD_SUBJECT,
          expect_change=True,
          why=f"the playhead moved from {PARK} to {TARGET}, so the LCD must repaint")

# ---- restore ----
restore = d.tool("logic_transport", "goto_position", {"position": PARK})
time.sleep(0.6)
after_restore = d.resource("logic://transport")
ev.restored("534/playhead-parked-again",
            restore.get("error") is None,
            f"restore_state={restore.get('state')!r} transport={after_restore.get('position')!r}")

d.close()
ev.stop_recording(rec)
# #622: this harness printed its summary and exited 0 whatever the summary said. Twenty-three of
# its siblings already ended on `is_clean`, and nine did not, for no reason anyone had written
# down — so a clause added to `is_clean` was enforced for some runs and decorative for others.
out = ev.write()
print(json.dumps(out, indent=1))
sys.exit(0 if E.is_clean(out) else 1)
