#!/usr/bin/env python3
"""Live proof for #543's mixer control-lookup diagnostics against the running Logic Pro.

Usage:  LPM_EVIDENCE_ROOT=/abs/path/outside/repo \
        python3 live_543_lookup_names_the_step.py <worktree> <full-40-char-head-sha>

What this run is actually for, stated plainly rather than implied.

The #543 fix replaced `allTrackHeaders` with `allTrackHeadersRead` in the refusal path. Those two are
NOT the same reader. The old one is tolerant: any traversal failure becomes an empty array. The new one
is strict and status-preserving: it distinguishes "rail absent", "rail found but not enumerable", and
"rail read, zero rows". That is the whole point of the change — but it is also the risk the change
introduces, and it is a risk only the real application can settle. If Logic's live track-header rail does
not satisfy the strict reader, then every real-world lookup failure would now report
`track_header_list_unreadable` instead of naming the step, and the fix would have made the diagnostic
worse than the bug it replaced. No unit fixture can answer that: the fake tree is built to be readable.

So the load-bearing check is: drive a genuinely out-of-range index at the REAL rail and confirm the
receipt says `no_header_at_index` with a truthful `header_count` — which is possible only if the strict
reader successfully enumerated the live rail.

What this run does NOT prove, and no live run here can:

- The `.unreadable` branch itself. Forcing a real `kAXErrorCannotComplete` from Logic's window server on
  demand is not something this harness can do, so that branch is locked by the unit fixture, which was
  watched to fail in both directions (mutation-tested at commit time).
- The re-read race. It needs a track added or removed between two AX reads inside one refusal, which is a
  timing window this harness cannot force. Also locked by fixture.

`header_count` is corroborated against the product's own `logic://tracks` resource. That is a DIFFERENT
function from the one under test, but it is still the product reading AX, so it corroborates rather than
witnesses — labelled as such below. System Events cannot supply an independent per-row count: Logic does
not vend the "Track Headers" list at any depth addressable from the Tracks window (probed during #542;
`-1719` at the window, no list under any of its groups). The screenshot is the independent witness that
rows exist at all.

This harness mutates nothing: the operation under test is refused before any write, and the requested
index does not exist. There is no state to restore, and that is asserted rather than assumed.
"""

import json
import os
import sys

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

# An index no real project reaches. Chosen far above any plausible track count so that a pass cannot be
# an accident of this project happening to have that many tracks.
OUT_OF_RANGE = 4096


def tracks():
    """A `select` forces a live AX read; without it the resource answers with synthesised names."""
    d.tool("logic_tracks", "select", {"index": 0})
    return d.resource("logic://tracks").get("data", []) or []


win = E.logic_window()
if not win:
    ev.check("543/precondition-logic-window", False, "Logic's Tracks window is on screen",
             "no window found", "closed the Tracks window; this check went red")
    d.close()
    print(json.dumps(ev.write(), indent=1)); sys.exit(1)

RAIL = (0, int(win["h"] * 0.10), int(win["w"] * 0.20), int(win["h"] * 0.80))

live_tracks = tracks()
ev.note("precondition", {"track_count": len(live_tracks),
                         "names": [t.get("name") for t in live_tracks]})

# The rail must be non-empty for this run to mean anything. With zero tracks the expected answer would be
# `track_header_list_empty`, and a pass on `no_header_at_index` would be impossible — but so would the
# claim that the strict reader can enumerate a populated rail, which is the point of the run.
ok_pre = len(live_tracks) > 0
ev.check("543/precondition-the-rail-has-rows", ok_pre,
         "the open project has at least one track, so the strict reader has a populated rail to enumerate",
         f"track_count={len(live_tracks)}",
         "opened an empty project; the expected step becomes track_header_list_empty and this went red")
if not ok_pre:
    d.close()
    print(json.dumps(ev.write(), indent=1)); sys.exit(1)

rec = ev.record_screen(seconds=60)
shot = ev.shot("rail-with-rows", settle_region=RAIL)

# ---- the operation under test ----
body = d.tool("logic_mixer", "set_volume", {"index": str(OUT_OF_RANGE), "value": "0.5"})
ev.note("response", {"body": body})

lookup = body.get("control_lookup") if isinstance(body, dict) else None
lookup = lookup if isinstance(lookup, dict) else {}
step = lookup.get("failed_step")
count = lookup.get("header_count")

# THE load-bearing check. `no_header_at_index` is reachable only from the `.read(headers)` branch, so
# observing it proves `allTrackHeadersRead` enumerated the live rail rather than refusing it.
ev.check("543/strict-reader-enumerates-the-live-rail",
         step == "no_header_at_index",
         "the refusal names the index step, which only the .read branch can produce — so the strict "
         "reader succeeded against real Logic",
         f"failed_step={step!r} header_count={count!r}",
         "pointed the lookup at a reader that refuses Logic's real rail; the step became "
         "track_header_list_unreadable and this went red")

# Pre-fix this said `track_header_list_not_found` whenever the tolerant reader returned empty for ANY
# reason. Naming the absent-rail step while the rail is visibly populated is the specific false statement
# the fix exists to stop, so assert against it directly.
ev.check("543/the-receipt-does-not-claim-a-missing-rail",
         step != "track_header_list_not_found",
         "with a populated rail on screen, the receipt must not report the rail as absent",
         f"failed_step={step!r}",
         "collapsed the three read answers back into one empty array; a strict-read failure reported "
         "track_header_list_not_found and this went red")

ev.check("543/header-count-matches-the-project",
         count == len(live_tracks),
         "the published header_count equals the number of tracks the project actually has",
         f"header_count={count!r} tracks_via_resource={len(live_tracks)}",
         "published a hard-coded 0 for header_count; this went red against a project with tracks")
# Deliberately a note, not a `provenance` record. That affordance means "this value came from a cache
# and is therefore not live", and the gate refuses a run that leans on one. This read is live and fresh
# — it is simply a DIFFERENT product function reading the same application, so it corroborates the count
# rather than independently witnessing it. Saying so here is the honest form of that distinction.
ev.note("543/header-count-corroboration",
        {"source": "product logic://tracks AX read, fresh", "independent_of_product": False,
         "why": "System Events cannot address Logic's Track Headers list, so no non-product per-row "
                "count exists; the screenshot witnesses that rows are present at all"})

# The requested index is out of range, so nothing may be written. A receipt that reports a write here
# would be the identity defect this whole surface exists to prevent.
state = body.get("state") if isinstance(body, dict) else None
ev.check("543/an-impossible-index-writes-nothing",
         state == "C",
         "an out-of-range index is refused as State C, not reported as a performed write",
         f"state={state!r} error={body.get('error')!r}",
         "let the lookup fall through to the first slider; the op reported a write to a track the "
         "caller never named and this went red")

after_tracks = tracks()
ev.restored("543/no-state-was-mutated", len(after_tracks) == len(live_tracks),
            f"track count {len(live_tracks)} -> {len(after_tracks)}; the op is refused before any write")

ev.visual("543/the-rail-is-unchanged", shot["file"], ev.shot("rail-after", settle_region=RAIL)["file"],
          RAIL, expect_change=False,
          why="a refused lookup must leave the track rail exactly as it was; this is the pixel witness "
              "that the run mutated nothing")

ev.stop_recording(rec)

d.close()
out = ev.write()
print(json.dumps(out, indent=1))
sys.exit(0 if E.is_clean(out) else 1)
