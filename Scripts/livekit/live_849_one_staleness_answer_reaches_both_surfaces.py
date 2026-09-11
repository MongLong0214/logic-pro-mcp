#!/usr/bin/env python3
"""Live proof that the published MCU staleness bit follows the rule its own snapshot states.

Usage:  LPM_EVIDENCE_ROOT=/abs/path/outside/repo \
        python3 live_849_one_staleness_answer_reaches_both_surfaces.py <worktree> <full-40-char-head-sha>

WHAT WAS WRONG
--------------
`age > 5.0` was written twice. `MCUChannel.health` compared it after an early return on
`!conn.isConnected`; `SystemDispatcher` compared `mcu.isConnected && (age ?? .infinity) > 5.0`
inline for `mcu.feedback_stale`. `MCUConnectionState.isFeedbackStale(now:)` is now the one spelling.

WHAT THIS DOES NOT MEASURE, SAID FIRST
--------------------------------------
The two former spellings AGREED. This harness would have passed before the change, and nothing here
claims otherwise -- `MCUFeedbackStalenessRuleTests` carries that load, with four mutants killed.

Rejected, after being this harness's first shape: comparing `mcu.feedback_stale` against the word in
`channels[].detail`. Those two fields ship in one payload but come from two reads of the cache --
`router.healthReport()` at `SystemDispatcher.swift:371` and `cache.getMCUConnection()` at `:386`. Feedback arriving between them can separate the two fields legitimately, so a check that
required them to match would have been green by luck and red on a race -- a flake wearing the shape
of a proof. That gap is a defect in its own right and is filed separately; it is not this change's,
and folding a fix for it into a refactor would have widened the very definition this change narrowed.

WHAT IT DOES MEASURE
--------------------
Every field the check reads comes from the SAME `getMCUConnection()` read: `connected`,
`feedback_stale` and `last_feedback_at` are one snapshot. So the question it can answer is whether
the published bit follows the published rule -- `connected && age > 5s`, recomputed here from the
timestamp on the wire.

The threshold is written out in this file rather than imported. An oracle that read the product's
own constant would agree with any value the product chose, including a wrong one.

THE COUNTEREXAMPLE, AND WHY THE SWEEP HAS TO SEE BOTH STATES
------------------------------------------------------------
"The bit matches the timestamp" is satisfied by a surface where the bit is permanently true and the
timestamp permanently ancient -- a server whose MCU never connects agrees with itself forever. So
the sweep must contain BOTH readings: a fresh one and a stale one. The server's own startup device
query supplies them without touching the project -- Logic answers it, which makes feedback fresh,
and five seconds of silence afterwards makes it stale. A sweep that saw one state is recorded as a
failure, not as a weaker pass: it cannot tell a rule from a constant.

This is a `non_ui` run: there is no rectangle to photograph.
"""
import datetime
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import evidence as E  # noqa: E402


COVERS = [
    "Sources/LogicProMCP/State/StateModels.swift",
    "Sources/LogicProMCP/Channels/MCUChannel.swift",
    "Sources/LogicProMCP/Dispatchers/SystemDispatcher.swift",
]

# Deliberately not imported from the product. See the docstring.
STALE_AFTER_SEC = 5.0

WT = sys.argv[1] if len(sys.argv) > 1 else ""
HEAD = sys.argv[2] if len(sys.argv) > 2 else ""
if not WT or not HEAD:
    sys.exit(__doc__)

E.REPO = WT
E.BIN = f"{WT}/.build/release/LogicProMCP"
missing = E.have_tools()
if missing:
    sys.exit(f"cannot run: missing {missing}")

ev = E.Evidence(HEAD, os.environ["LPM_EVIDENCE_ROOT"], surface="non_ui")


def parse_stamp(text):
    if not isinstance(text, str) or not text:
        return None
    try:
        return datetime.datetime.strptime(text, "%Y-%m-%dT%H:%M:%S.%fZ").replace(
            tzinfo=datetime.timezone.utc
        )
    except ValueError:
        return None


d = E.Driver()

samples = []
# Read across the staleness boundary without driving the project. The first read lands while
# Logic's answer to the startup device query is still inside the window; the rest land after it has
# aged out. 2s is inside the 5s window, 2+3 is on the far side.
for delay in (2, 3, 7):
    time.sleep(delay)
    # The wall clock is read as close to the call as this harness can manage. It is only ever used
    # to age a timestamp the product itself published, never to time the product.
    asked_at = datetime.datetime.now(datetime.timezone.utc)
    health = d.tool("logic_system", "health")
    mcu = health.get("mcu") or {}
    stamp = parse_stamp(mcu.get("last_feedback_at"))
    published = mcu.get("feedback_stale")
    connected = mcu.get("connected")
    age = None if stamp is None else (asked_at - stamp).total_seconds()
    # `nil` timestamp means no feedback has ever arrived, which both former spellings read as
    # infinitely old.
    expected = bool(connected) and (True if age is None else age > STALE_AFTER_SEC)
    samples.append({
        "connected": connected,
        "feedback_stale": published,
        "last_feedback_at": mcu.get("last_feedback_at"),
        "age_sec_at_ask": None if age is None else round(age, 3),
        "rule_says_stale": expected,
        "published_matches_rule": isinstance(published, bool) and published == expected,
        # A sample whose age sits within a few milliseconds of the threshold cannot arbitrate
        # between the product's clock and this harness's, and is excluded from the comparison
        # rather than counted as either outcome.
        "near_boundary": age is not None and abs(age - STALE_AFTER_SEC) < 0.25,
    })

decidable = [s for s in samples if not s["near_boundary"] and isinstance(s["feedback_stale"], bool)]

reading = {
    "samples": len(samples),
    "decidable_samples": len(decidable),
    "samples_excluded_near_the_boundary": sum(1 for s in samples if s["near_boundary"]),
    "samples_where_the_bit_follows_the_rule": sum(1 for s in decidable if s["published_matches_rule"]),
    "fresh_readings": sum(1 for s in decidable if s["feedback_stale"] is False),
    "stale_readings": sum(1 for s in decidable if s["feedback_stale"] is True),
    "connected_readings": sum(1 for s in decidable if s["connected"] is True),
    "observed": samples,
}

ev.falsifiable(
    "849/the-published-staleness-bit-follows-its-own-snapshot",
    lambda o: (o["decidable_samples"] >= 2
               and o["samples_where_the_bit_follows_the_rule"] == o["decidable_samples"]
               and o["fresh_readings"] > 0
               and o["stale_readings"] > 0
               and o["connected_readings"] == o["decidable_samples"]),
    reading,
    {"samples": 3, "decidable_samples": 3, "samples_excluded_near_the_boundary": 0,
     "samples_where_the_bit_follows_the_rule": 3,
     "fresh_readings": 0, "stale_readings": 3, "connected_readings": 3,
     "observed": [{"connected": True, "feedback_stale": True,
                   "last_feedback_at": "2026-09-11T02:43:43.756Z", "age_sec_at_ask": 611.2,
                   "rule_says_stale": True, "published_matches_rule": True, "near_boundary": False}]},
    "`mcu.feedback_stale` follows the rule recomputed from `connected` and `last_feedback_at` in the "
    "same snapshot, and the sweep contains BOTH answers -- a fresh reading and a stale one -- so what "
    "passed is a rule and not a constant. The counterexample is the shape that satisfies every other "
    "clause: three samples that all agree and are all stale, which is exactly what a server with no "
    "MCU binding produces, and what a `feedback_stale` hardwired to `true` would produce. `connected` "
    "is required across the sweep for the same reason -- a disconnected port is not stale under either "
    "former spelling, so agreement on a dead port measures nothing",
    mutation="`MCUConnectionState.isFeedbackStale` returns `false` unconditionally. Every sample then "
             "publishes a fresh bit while its own `last_feedback_at` ages past five seconds, so "
             "`samples_where_the_bit_follows_the_rule` falls below `decidable_samples` and "
             "`stale_readings` reaches zero -- two clauses, not one. The narrower mutation of dropping "
             "the `isConnected` guard is NOT claimed here: this run never observes a disconnected "
             "port, so nothing in this document would move",
)

ev.write()
