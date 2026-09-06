#!/usr/bin/env python3
"""Live proof that an unreadable region is reported as unverified, not as a failed import.

Usage:  LPM_EVIDENCE_ROOT=/abs/path/outside/repo \
        python3 live_576_viewport_limited_region_readback.py <worktree> <full-40-char-head-sha>

WHAT WAS WRONG
--------------
`midi.import_file` verifies by diffing `enumerateRegionItems`, and `defaultGetRegions` publishes
what that reader can see on EVERY successful read:

    {"complete": false, "scope": "visible_arrange_area", "reason": "logic_ax_viewport_only"}

Logic only exposes regions for the part of the arrangement in view. Once a project outgrows the
viewport the freshly imported track is off-screen and its region is unreadable — so an import that
worked read back as zero new regions and was reported as State C `readback_mismatch`, "did not
create a verifiable MIDI region", stated as fact. Measured 2026-08-17 on the same binary and
project: `track_count 14 -> 15` (a track WAS created) with `region_count 13 -> 13`.

The failure direction matters. A caller told the import failed retries, which creates a SECOND track
and a second region and fails again — compounding the mess it says did not happen.

THE TRIGGER IS A PROJECT PAST THE VIEWPORT, SO THE RUN ESTABLISHES IT
--------------------------------------------------------------------
Against a small project every import reads back fine and this branch is never entered; the checks
below would pass while measuring nothing. The run therefore imports until the readback stops seeing
its own region, and STOPS if it never does — an unreached branch is a failed run, not a quiet pass.

That is also why this harness deliberately grows the project: the condition under test is a property
of arrangement size. It says so in its restoration record rather than pretending it left no trace.
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
# A slice of the arrange window's track headers. NOT because it changes — measured, it does not:
# the lane Logic creates is below the visible arrangement. That is the point the visual assertion
# makes, and it is exactly why the rectangle that stood here was dangerous.
#
# `(10, 120, 260, 320)` is the LIBRARY browser, not the track headers — `live_576_completeness`
# says so in its own comment, having found it the hard way when two captures hashed identically
# across a zoom change that plainly worked. Here the assertion is NEGATIVE, so the wrong rectangle
# did not fail: the Library does not change when a track is created, so the check passed for a
# reason that had nothing to do with the claim. Sitting green, saying nothing.
HEADER_BAND, HEADER_BAND_SUBJECT = ev.located_band("Tracks header")
ev.check("576/precondition-the-track-header-rail-was-located",
         HEADER_BAND is not None and bool(HEADER_BAND_SUBJECT),
         "the track-header rail, located by the AXDescription it carries",
         f"band={HEADER_BAND!r} subject={HEADER_BAND_SUBJECT!r}", None)
MAX_ATTEMPTS = 12


def osa(script):
    r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
    return (r.stdout or "").strip()


def window_titles():
    return osa('tell application "System Events" to tell process "Logic Pro" to '
               'return name of every window')


def inner_of(result):
    """The channel envelope `record_sequence` carries verbatim under `detail`."""
    raw = result.get("detail") if isinstance(result, dict) else None
    if not raw:
        return {}
    try:
        return json.loads(raw)
    except ValueError:
        return {}


titles = window_titles()
ev.check("576/precondition-an-arrange-window-is-open", "Tracks" in titles,
         "Logic has an arrange window to import into",
         f"titles={titles!r}",
         None)

rec = ev.record_screen(seconds=240)
before = ev.shot("576/before", settle_region=HEADER_BAND)

d = E.Driver()
time.sleep(3)

attempts = []
target = None
for attempt in range(MAX_ATTEMPTS):
    result = d.tool("logic_tracks", "record_sequence", {"notes": "60,0,400;64,400,400"})
    inner = inner_of(result)
    attempts.append({
        "attempt": attempt,
        "verified": result.get("verified"),
        "error": result.get("error"),
        "inner_state": inner.get("state"),
        "inner_reason": inner.get("reason") or inner.get("error"),
        "tracks": [inner.get("track_count_before"), inner.get("track_count_after")],
    })
    # The branch under test: a track was created and no imported region read back.
    if inner.get("region_readback_complete") is False:
        target = {"result": result, "inner": inner}
        break
    time.sleep(2)

ev.note("576/attempts", attempts)

ev.check("576/precondition-the-unreadable-region-branch-was-reached",
         target is not None,
         "an import created a track whose region the readback could not see, which is the only "
         "state this fix is about",
         f"attempts={len(attempts)} last={attempts[-1] if attempts else None}",
         # No mutation: this is the trigger. Against a project that fits in the viewport the branch
         # is never entered and every check below would pass without observing it.
         None)

if target is None:
    d.close()
    ev.stop_recording(rec)
    print(json.dumps(ev.write(), indent=1)); sys.exit(1)

inner = target["inner"]
result = target["result"]

ev.check("576/an-unreadable-region-is-unverified-not-a-failed-import",
         inner.get("state") == "B" and inner.get("reason") == "readback_unavailable",
         "the channel reports State B readback_unavailable rather than State C readback_mismatch",
         f"state={inner.get('state')!r} reason={inner.get('reason')!r} "
         f"error={inner.get('error')!r}",
         "restore the State C branch: the same run then asserts 'did not create a verifiable MIDI "
         "region' about a region it could not see, and the caller is told the import failed")

ev.check("576/the-readbacks-limit-is-named-in-the-envelope",
         inner.get("region_readback_complete") is False
         and inner.get("region_readback_scope") == "visible_arrange_area"
         and inner.get("region_readback_limit") == "logic_ax_viewport_only",
         "the envelope says the readback was incomplete and which scope it covered, so this is "
         "distinguishable from a region looked for across the whole arrangement and absent",
         f"complete={inner.get('region_readback_complete')!r} "
         f"scope={inner.get('region_readback_scope')!r} "
         f"limit={inner.get('region_readback_limit')!r}",
         "drop the scope fields: State B alone does not tell the caller WHY it is unverified, and "
         "an unverified import is indistinguishable from an unreadable one")

ev.check("576/the-observation-that-does-hold-is-still-reported",
         isinstance(inner.get("track_count_before"), int)
         and isinstance(inner.get("track_count_after"), int)
         and inner["track_count_after"] > inner["track_count_before"],
         "the track-count delta — the part that IS solid — survives on the envelope, so the caller "
         "knows something was created even though the region could not be confirmed",
         f"tracks {inner.get('track_count_before')!r} -> {inner.get('track_count_after')!r}",
         "drop the delta: the caller cannot tell 'a track exists, unconfirmed contents' from "
         "'nothing happened', and retrying is the natural next move — which creates another track")

ev.check("576/nothing-is-promoted-to-a-verified-take",
         result.get("verified") is not True and inner.get("state") != "A",
         "the downgrade from State C to State B does not become a claim that the import worked",
         f"record_sequence verified={result.get('verified')!r} error={result.get('error')!r} "
         f"import_reason={result.get('import_reason')!r} inner_state={inner.get('state')!r}",
         "return State A on the empty-region branch: an import nobody could read would be published "
         "as a verified take, which is the failure this whole contract exists to prevent")

after = ev.shot("576/after", settle_region=HEADER_BAND)
# This assertion was written as `expect_change=True` — "the import adds a lane, so the header band
# must change" — and it FAILED on the first run: identical hashes across a call whose envelope
# reported `track_count 19 -> 20`.
#
# The expectation was wrong for the same reason this issue exists. The track Logic created is BELOW
# the visible arrangement, so it is invisible to a screenshot of the arrange window exactly as it is
# invisible to the AX region reader. The corrected assertion is the stronger one: the operation's
# effect leaves no mark inside the viewport, which is why a verification that only reads the viewport
# cannot certify it — and why an empty region result must not be published as a definite failure.
ev.visual("576/the-created-track-is-invisible-inside-the-viewport",
          before["file"], after["file"], HEADER_BAND, subject=HEADER_BAND_SUBJECT,
          expect_change=False,
          why="the envelope reports a track-count delta while the visible track-header band is "
              "byte-identical: the lane Logic created is outside the viewport, so the screenshot "
              "and the AX region reader are blind in the same place and for the same reason")

d.close()
ev.restored("576/the-run-declares-the-tracks-it-added",
            True,
            f"this run imports until the readback stops seeing its own region, so it ADDS tracks on "
            f"purpose — {len(attempts)} attempt(s), ending at "
            f"track_count {inner.get('track_count_after')!r}. They are left in place: the project is "
            f"a scratch document, and deleting them would need a destructive op this run has no "
            f"reason to perform.")

ev.stop_recording(rec)
out = ev.write()
print(json.dumps(out, indent=1))
sys.exit(0 if E.is_clean(out) else 1)
