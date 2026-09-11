#!/usr/bin/env python3
"""Live proof that routing the track-type read through the caller's runtime did not disable it.

Usage:  LPM_EVIDENCE_ROOT=/abs/path/outside/repo \
        python3 live_866_the_live_track_type_read_still_happens.py <worktree> <full-40-char-head-sha>

WHAT WAS WRONG
--------------
`inspectorStripReading` defaults `runtime` to `.production`, and the track-creation verifier omitted
the argument while every other AX read on that path used the injected one. A unit test that builds a
complete fake AX tree therefore had its verdict decided by the REAL Logic inspector, and produced a
false GREEN in the ship gate: the same test passed the full suite half an hour before it began
failing, with no change to anything it touches.

WHAT THIS RUN IS FOR, AND WHAT IT IS NOT
----------------------------------------
It is NOT the proof that the defect is fixed. That proof is offline and cannot be otherwise: the
defect was a test reading the live world, so what establishes the fix is the test producing the same
verdict whichever world it is run in, plus `check-injected-runtime-reaches-ax-reads.py`, whose
self-test injects the defect rather than asserting the tree is clean.

This run guards the opposite risk, which a live run is the only thing that can see: that passing the
runtime through BROKE production. The fix's whole claim is that production is unchanged, because in
production the runtime being passed IS `.production`. A claim of "nothing changed" that nobody
checked against the running application is an assumption, and this is the cheapest way to stop
making it.

WHAT IT DOES NOT MEASURE, SAID FIRST
------------------------------------
It cannot force the inspector BRANCH. That branch needs the created track's name to be unique in the
project, and Logic names new instrument tracks after their patch -- this project already carries
eight strips called `Studio Grand`. So the run asserts that the verifier reached State A and named a
source from the closed set it is allowed to name; it does not assert WHICH, because which one is a
property of the project rather than of the change. Recorded here rather than discovered by a reader
wondering why the check looks weak.

THE COUNTEREXAMPLE
------------------
A response with no `track_type_verification_source` at all, or one outside the closed set. That is
what a runtime threaded through wrongly would produce -- a read that now goes nowhere, leaving the
field empty or unset -- and it is the one shape "the track was created" would still be true for.

The created track is deleted and the deletion is confirmed by re-reading the track count.
"""
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import evidence as E  # noqa: E402


COVERS = [
    "Sources/LogicProMCP/Channels/AccessibilityChannel+Tracks.swift",
]

# The sources this verifier is allowed to name, written out here rather than imported. An oracle
# that read the product's own enum would accept whatever the product decided to emit.
ALLOWED_SOURCES = {
    "observed_header",
    "inspector_channel_strip",
    "inspector_channel_strip_instrument_family",
}

WT = sys.argv[1] if len(sys.argv) > 1 else ""
HEAD = sys.argv[2] if len(sys.argv) > 2 else ""
if not WT or not HEAD:
    sys.exit(__doc__)

E.REPO = WT
E.BIN = f"{WT}/.build/release/LogicProMCP"
missing = E.have_tools()
if missing:
    sys.exit(f"cannot run: missing {missing}")

ev = E.Evidence(HEAD, os.environ["LPM_EVIDENCE_ROOT"], surface="ui")
recording = ev.record_screen(seconds=100)

d = E.Driver()
d.tool("logic_system", "refresh_cache")

rail, rail_subject = ev.located_band("트랙 헤더")
if rail is None:
    rail, rail_subject = ev.located_band("Tracks header")
ev.note("866/watched-band", {"region": rail, "subject": rail_subject})

before_shot = ev.shot("866/before-create", settle_region=rail)


def tracks():
    census = d.resource("logic://tracks") or {}
    return census, [r for r in (census.get("data") or []) if isinstance(r.get("id"), int)]


census_before, rows_before = tracks()
ev.note("866/census-before", {"readable": census_before.get("readable"), "count": len(rows_before)})

created = d.tool("logic_tracks", "create_instrument", {}) or {}
time.sleep(1.0)
d.tool("logic_system", "refresh_cache")
census_after, rows_after = tracks()
ev.note("866/create", {"response": created, "count_after": len(rows_after)})

after_shot = ev.shot("866/after-create", settle_region=rail)
ev.visual(
    "866/a-new-row-appears-in-the-rail",
    before_shot["file"],
    after_shot["file"],
    rail,
    subject=rail_subject,
    expect_change=True,
    why="the run creates one instrument track, so the header rail must differ; a rail that did not "
    "change means the operation reported a creation the arrangement does not have",
)

# Restore. The first shape of this deleted by `{index, expected_name}` and was REFUSED, correctly:
# Logic names a new instrument track after its patch, this project already carries eight strips
# called `Studio Grand`, and the product will not delete a target whose name matches eight live
# tracks -- "same-named tracks can swap and stay self-consistent" is its own wording. Supplying
# `target_ref` instead does not help either, because the ambiguity is in the LIVE names rather than
# in the reference. The product's refusal names the way through: rename it to something unique
# first, then delete by that name. So the restore follows the product's own identity rules rather
# than arguing with them, and is confirmed by re-reading the count.
restored = False
detail = "nothing was created"
if len(rows_after) > len(rows_before):
    last = rows_after[-1]
    unique = f"lpm-866-{os.getpid()}"
    d.tool("logic_tracks", "rename", {"track": last["id"], "name": unique})
    time.sleep(1.0)
    d.tool("logic_system", "refresh_cache")
    deleted = d.tool("logic_tracks", "delete", {"index": last["id"], "expected_name": unique})
    time.sleep(1.2)
    d.tool("logic_system", "refresh_cache")
    _census, rows_final = tracks()
    restored = len(rows_final) == len(rows_before)
    detail = f"before={len(rows_before)} after={len(rows_after)} final={len(rows_final)}"
    ev.note("866/restore", {"rename_to": unique, "delete": deleted, "count_final": len(rows_final)})
ev.restored("866/the-created-track-is-deleted", restored, detail)

source = created.get("track_type_verification_source")
reading = {
    "create_state": created.get("state"),
    "create_verified": created.get("verified"),
    "track_count_before": len(rows_before),
    "track_count_after": len(rows_after),
    "observed_delta": len(rows_after) - len(rows_before),
    "track_type_verification_source": source,
    "source_is_one_the_verifier_may_name": source in ALLOWED_SOURCES,
    "verification_source": created.get("verification_source"),
    "restored": restored,
}

ev.falsifiable(
    "866/the-track-type-verifier-still-names-a-source-in-production",
    lambda o: (o["create_state"] == "A"
               and o["create_verified"] is True
               and o["observed_delta"] == 1
               and o["source_is_one_the_verifier_may_name"]
               and o["verification_source"] == "track_count_delta"
               and o["restored"]),
    reading,
    {"create_state": "A", "create_verified": True,
     "track_count_before": 19, "track_count_after": 20, "observed_delta": 1,
     "track_type_verification_source": None,
     "source_is_one_the_verifier_may_name": False,
     "verification_source": "track_count_delta",
     "restored": True},
    "creating an instrument track against the real application still reaches State A, still counts "
    "the delta, and still names a track-type verification source from the closed set the verifier is "
    "allowed to name -- so threading the runtime through that read did not take production's read "
    "away with it. THE COUNTEREXAMPLE is the one shape where every other clause holds: the track is "
    "created and counted, and the source is absent, which is what a runtime threaded through wrongly "
    "produces -- a read that now goes nowhere and leaves the field unset",
    mutation="pass a runtime to `inspectorStripReading` that resolves no application -- the read "
             "returns `.undetermined` for a reason that is not about the project, and while it would "
             "still fall through to `observed_header` here, the same mistake on a resolver WITHOUT a "
             "header fallback empties the field outright. The clause is written against the field "
             "being present and in the closed set, not against one value, because which of the three "
             "is named is a property of the project rather than of the change",
)

d.close()
ev.stop_recording(recording)
out = ev.write()
print(json.dumps(out, indent=1))
sys.exit(0 if E.is_clean(out) else 1)
