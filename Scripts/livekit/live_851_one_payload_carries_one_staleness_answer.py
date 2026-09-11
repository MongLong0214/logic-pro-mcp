#!/usr/bin/env python3
"""Live proof that a health payload's MCU staleness prose and its boolean cannot disagree.

Usage:  LPM_EVIDENCE_ROOT=/abs/path/outside/repo \
        python3 live_851_one_payload_carries_one_staleness_answer.py <worktree> <full-40-char-head-sha>

THE CHECK live_849 REFUSED TO WRITE
-----------------------------------
`live_849` says so in its own docstring. Comparing `mcu.feedback_stale` against the word in
`channels[].detail` was its first shape and was rejected: those two fields shipped in one payload
but came from TWO reads of the cache -- `router.healthReport()` at `SystemDispatcher.swift:371` and
`cache.getMCUConnection()` at `:386`. Feedback arriving between them separates the two fields
legitimately, so the check would have been green by luck and red on a race: a flake wearing the
shape of a proof. It was filed as #851 instead of being written.

#851 removed the second derivation. `MCUChannel.healthCheck` no longer renders staleness at all;
the dispatcher evaluates the rule ONCE and the same boolean produces both the wire field and the
clause appended to the MCU channel's detail. So the comparison is now a statement about the
product rather than about timing, and this is that check.

WHAT THIS DOES NOT MEASURE, SAID FIRST
--------------------------------------
It does not show that the race USED to happen. Nobody caught the two fields disagreeing on a live
server; the defect was read out of the two call sites, and a run against the old build would very
probably have been green -- which is the whole reason `live_849` would not accept this check as
evidence back then. What carries that load is `MCUFeedbackStalenessRuleTests`, where the renderer
is pinned as a function of its argument and the channel is pinned to render no staleness word.

What this run adds is the half a unit test cannot reach: that the ASSEMBLED payload a real client
receives is self-consistent, across both answers, on a live server.

THE COUNTEREXAMPLE, AND WHY THE SWEEP HAS TO SEE BOTH STATES
------------------------------------------------------------
"The prose agrees with the boolean" is satisfied for free by a surface that is permanently stale and
permanently says so -- a server whose MCU never connects agrees with itself forever. So the sweep
must contain BOTH readings. The server's own startup device query supplies them without touching the
project: Logic answers it, which makes feedback fresh, and five seconds of silence afterwards makes
it stale.

A disconnected port is the third case and is neither: it is not stale under the rule and it is not
active either, so the clause is omitted entirely. A run that only saw a disconnected port would
agree with itself while measuring nothing, so `connected_readings` is required across the sweep --
the same requirement, for the same reason, that `live_849` imposes.

This is a `non_ui` run: there is no rectangle to photograph.
"""
import datetime
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import evidence as E  # noqa: E402


COVERS = [
    "Sources/LogicProMCP/Channels/MCUChannel.swift",
    "Sources/LogicProMCP/Dispatchers/SystemDispatcher.swift",
]

# The two spellings, written out here rather than imported. An oracle that read the product's own
# strings would agree with any pair the product chose, including a swapped one.
STALE_CLAUSE = "feedback stale"
ACTIVE_CLAUSE = "feedback active"

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

d = E.Driver()

samples = []
# Read across the staleness boundary without driving the project, exactly as live_849 does: the
# first read lands while Logic's answer to the startup device query is still inside the window, the
# rest after it has aged out.
for delay in (2, 3, 7):
    time.sleep(delay)
    health = d.tool("logic_system", "health") or {}
    mcu = health.get("mcu") or {}
    rows = [c for c in (health.get("channels") or []) if c.get("channel") == "MCU"]
    detail = rows[0].get("detail") if rows else None
    published = mcu.get("feedback_stale")
    connected = mcu.get("connected")

    says_stale = isinstance(detail, str) and STALE_CLAUSE in detail
    says_active = isinstance(detail, str) and ACTIVE_CLAUSE in detail
    if connected is True:
        # Exactly one clause, and it is the one the boolean names.
        agrees = (says_stale != says_active) and (says_stale == (published is True))
    else:
        # Not stale, not active: a dead port earns no clause in either direction.
        agrees = not says_stale and not says_active

    samples.append({
        "connected": connected,
        "feedback_stale": published,
        "mcu_channel_detail": detail,
        "detail_says_stale": says_stale,
        "detail_says_active": says_active,
        "prose_agrees_with_the_boolean": agrees,
    })

decidable = [s for s in samples if isinstance(s["feedback_stale"], bool) and s["mcu_channel_detail"]]

reading = {
    "samples": len(samples),
    "decidable_samples": len(decidable),
    "samples_where_the_prose_agrees_with_the_boolean": sum(
        1 for s in decidable if s["prose_agrees_with_the_boolean"]
    ),
    "fresh_readings": sum(1 for s in decidable if s["feedback_stale"] is False),
    "stale_readings": sum(1 for s in decidable if s["feedback_stale"] is True),
    "connected_readings": sum(1 for s in decidable if s["connected"] is True),
    "observed": samples,
}

ev.falsifiable(
    "851/one-payload-carries-one-staleness-answer",
    lambda o: (o["decidable_samples"] >= 2
               and o["samples_where_the_prose_agrees_with_the_boolean"] == o["decidable_samples"]
               and o["fresh_readings"] > 0
               and o["stale_readings"] > 0
               and o["connected_readings"] == o["decidable_samples"]),
    reading,
    {"samples": 3, "decidable_samples": 3,
     "samples_where_the_prose_agrees_with_the_boolean": 3,
     "fresh_readings": 0, "stale_readings": 3, "connected_readings": 3,
     "observed": [{"connected": True, "feedback_stale": True,
                   "mcu_channel_detail": "MCU device registration confirmed, feedback stale",
                   "detail_says_stale": True, "detail_says_active": False,
                   "prose_agrees_with_the_boolean": True}]},
    "in every payload the MCU channel's detail carries exactly ONE staleness clause and it is the "
    "one `mcu.feedback_stale` names, and the sweep contains BOTH answers -- a fresh payload and a "
    "stale one -- so what passed is an agreement and not a constant. THE COUNTEREXAMPLE is the shape "
    "that satisfies every other clause: three samples that all agree and are all stale, which is "
    "what a server with no MCU binding produces and what a `feedback_stale` hardwired to `true` "
    "would produce. `connected` is required across the sweep for the same reason -- a disconnected "
    "port earns no clause at all, so it agrees with itself while measuring nothing",
    mutation="restore the second derivation: give `MCUChannel.healthCheck` back its own "
             "`conn.isFeedbackStale()` clause while the dispatcher keeps publishing its own. The "
             "two agree whenever no feedback lands between the reads, so this run would very likely "
             "still be green -- said plainly because it is the limit of what a live payload check "
             "can show. The mutation that DOES flip it deterministically is a renderer that reads "
             "only `stale` and so prints `feedback active` on a disconnected port; "
             "`prose_agrees_with_the_boolean` goes false on every disconnected sample. The "
             "structural claim is carried by `MCUFeedbackStalenessRuleTests`, not by this file",
)

d.close()
out = ev.write()
print(json.dumps(out, indent=1))
sys.exit(0 if E.is_clean(out) else 1)
