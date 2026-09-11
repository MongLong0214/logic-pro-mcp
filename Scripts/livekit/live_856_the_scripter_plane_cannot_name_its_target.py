#!/usr/bin/env python3
"""Live proof that `mixer.set_plugin_param` cannot say WHICH parameter it moved.

Usage:  LPM_EVIDENCE_ROOT=/abs/path/outside/repo \
        python3 live_856_the_scripter_plane_cannot_name_its_target.py <worktree> <full-40-char-head-sha>

WHAT #856 ASKED
---------------
"Can the Scripter plane read a plug-in parameter back? ADR-009's close depends on it."

The oracle table excluded `mixer.set_plugin_param` with the words *"there is no State A to verify"*.
That sentence describes OUR ROUTING. #373 rejected exactly that wording elsewhere, for exactly this
reason: it says where the code goes rather than what the world allows, and read that way an
exclusion looks like unfinished plumbing. This run measures what the world allows.

WHAT THIS DOES NOT MEASURE, SAID FIRST
--------------------------------------
It does not show that a plug-in parameter failed to move. It very likely DOES move when the
operator has inserted Scripter and assigned the controller; that is the plane's whole purpose. The
claim here is narrower and is the one ADR-009 needs: the RESPONSE contains nothing that came from
Logic, so the product cannot name the target it wrote to.

Nor does it measure the un-approved refusal. `ScripterChannel` is gated behind
`--approve-channel Scripter`, and a run against the closed gate would only measure our own gate.
The channel is approved before this runs, so every reading below is about the plane.

THE MEASUREMENT, AND THE COUNTEREXAMPLE IT HAS TO SURVIVE
--------------------------------------------------------
The first shape of this harness claimed the plane would answer an ABSENT track exactly as a real
one. It does not, and the run said so rather than being adjusted until it agreed: `set_plugin_param`
rejects a track index that is not in the cached track list (`element_not_found`, "Track at index 41
not found"). That rejection is real and it is OURS -- it comes from our own cache, not from Logic --
but it means the absent-target contrast measures our validation, so it is not the contrast to use.

What the plane actually does is visible on the WIRE. The run drives four requests that differ in one
field at a time and reads what the product put on the bus:

    track A, insert 0, param 0     the baseline
    track A, insert 1, param 0     only `insert` moved
    track B, insert 0, param 0     only `track` moved
    track A, insert 0, param 3     only `param` moved

`insert` and `track` are accepted, validated and echoed -- and neither reaches the bus. The emitted
`cc` and `midi_channel` are identical across the first three and change only with `param`. So the
only field of the request that leaves this product is a controller NUMBER, and what that number
reaches is an assignment the operator made by hand inside Scripter. The product is not addressing a
plug-in parameter; it is addressing whatever the operator wired that controller to.

That is why no readback could close ADR-009 on this plane. It is not that the reply omits a name --
it is that the product never had one to omit.

This is a `non_ui` run. The write is a MIDI CC on channel 16 whose destination is a controller
assignment this project does not have, so there is no rectangle to photograph — which is itself the
point being made.
"""
import json
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import evidence as E  # noqa: E402


# The exclusion reason this run substantiates lives in the oracle table; the behaviour it describes
# lives in the Scripter channel. Both are claimed because the reworded reason is only as good as the
# reading below.
COVERS = [
    "Sources/LogicProMCP/Qualification/SemanticOracleTable.swift",
    "Sources/LogicProMCP/Channels/ScripterChannel.swift",
]

# Every key the response may carry, and where each comes from. Nothing in either column is an
# observation of Logic: the first is the caller's own request reflected back, the second is what the
# product itself chose to put on the wire. A key OUTSIDE this set is the interesting case — it would
# be a field whose value had to come from somewhere else — so the check is written as a subset test
# and an unexpected key turns it red rather than being ignored.
CALLER_ECHO_KEYS = {"track", "insert", "param", "requested"}
OUR_OWN_WIRE_KEYS = {"cc", "midi_channel", "applied_midi_value", "readback_source"}
CONTRACT_KEYS = {"operation", "state", "success", "verified", "reason", "trace_id"}
ALLOWED_KEYS = CALLER_ECHO_KEYS | OUR_OWN_WIRE_KEYS | CONTRACT_KEYS

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

# The plane, not our gate. Recorded so a reader knows the refusal path was deliberately opened.
approve = subprocess.run([E.BIN, "--approve-channel", "Scripter"],
                         capture_output=True, text=True, timeout=120)
ev.note("856/scripter-channel-approved-so-the-reading-is-about-the-plane", {
    "returncode": approve.returncode,
    "stdout": (approve.stdout or "").strip()[:200],
})

d = E.Driver()

# A LIVE census, not whatever the cache is holding. The first run of this harness read a stale list
# of 42 tracks with `readable: false` and built its "absent" index on top of it; the indices it then
# called real were rejected by the product as not found. A refresh first, and the run refuses to
# proceed on a list Logic did not just answer for.
d.tool("logic_system", "refresh_cache")
tracks = d.resource("logic://tracks") or {}
rows = tracks.get("data") or []
track_ids = sorted(r.get("id") for r in rows if isinstance(r.get("id"), int))
census = {
    "readable": tracks.get("readable"),
    "source": tracks.get("source"),
    "count": len(track_ids),
    "ids": track_ids,
}
ev.note("856/live-track-census", census)

# Two real tracks and two real inserts, so every request below is one the product accepts. The whole
# reading is about what reaches the WIRE, and a request refused before the wire measures nothing.
track_a = track_ids[0] if track_ids else None
track_b = track_ids[-1] if len(track_ids) > 1 else None

requests = []
if track_a is not None and track_b is not None:
    requests = [
        ("baseline", {"track": track_a, "insert": 0, "param": 0, "value": 0.5}),
        ("only-insert-moved", {"track": track_a, "insert": 1, "param": 0, "value": 0.5}),
        ("only-track-moved", {"track": track_b, "insert": 0, "param": 0, "value": 0.5}),
        ("only-param-moved", {"track": track_a, "insert": 0, "param": 3, "value": 0.5}),
    ]

readings = []
for label, params in requests:
    body = d.tool("logic_mixer", "set_plugin_param", params) or {}
    keys = sorted(body.keys())
    readings.append({
        "label": label,
        "request": params,
        "state": body.get("state"),
        "reason": body.get("reason"),
        "readback_source": body.get("readback_source"),
        "verified": body.get("verified"),
        "cc": body.get("cc"),
        "midi_channel": body.get("midi_channel"),
        "keys": keys,
        "keys_outside_the_caller_echo_and_our_own_wire": sorted(set(keys) - ALLOWED_KEYS),
        # Checked against what was ASKED for rather than against a constant: a plane that observed
        # anything could disagree with the request here.
        "echoes_the_request": all(
            body.get(k) == params.get(k) for k in ("track", "insert", "param")
        ),
        "body": body,
    })
    ev.note(f"856/{label}", body)

by_label = {r["label"]: r for r in readings}
base = by_label.get("baseline")
moved_insert = by_label.get("only-insert-moved")
moved_track = by_label.get("only-track-moved")
moved_param = by_label.get("only-param-moved")


def same_wire(a, b):
    return bool(a and b and a["cc"] == b["cc"] and a["midi_channel"] == b["midi_channel"])


reading = {
    "census_readable": census["readable"] is True,
    "census_source": census["source"],
    "requests_driven": len(readings),
    "all_state_b": all(r["state"] == "B" for r in readings),
    "all_unverified": all(r["verified"] is False for r in readings),
    "all_send_only": all(r["readback_source"] == "scripter_send_only" for r in readings),
    "all_echo_the_request": all(r["echoes_the_request"] for r in readings),
    "fields_no_caller_could_have_supplied": sorted(
        {k for r in readings for k in r["keys_outside_the_caller_echo_and_our_own_wire"]}
    ),
    # The three clauses the claim rests on.
    "insert_does_not_reach_the_wire": same_wire(base, moved_insert),
    "track_does_not_reach_the_wire": same_wire(base, moved_track),
    "param_is_the_only_field_that_does": bool(base and moved_param and base["cc"] != moved_param["cc"]),
    "observed": readings,
}

ev.falsifiable(
    "856/only-a-controller-number-leaves-this-product-so-it-cannot-name-a-parameter",
    lambda o: (o["census_readable"]
               and o["requests_driven"] == 4
               and o["all_state_b"]
               and o["all_unverified"]
               and o["all_send_only"]
               and o["all_echo_the_request"]
               and o["fields_no_caller_could_have_supplied"] == []
               and o["insert_does_not_reach_the_wire"]
               and o["track_does_not_reach_the_wire"]
               and o["param_is_the_only_field_that_does"]),
    reading,
    {"census_readable": True, "census_source": "ax_live", "requests_driven": 4,
     "all_state_b": True, "all_unverified": True, "all_send_only": True,
     "all_echo_the_request": True, "fields_no_caller_could_have_supplied": [],
     "insert_does_not_reach_the_wire": False,
     "track_does_not_reach_the_wire": True,
     "param_is_the_only_field_that_does": True,
     "observed": []},
    "changing `insert`, and changing `track`, leave the emitted CC and MIDI channel identical; only "
    "`param` changes them. Both fields are accepted, validated against our own cache and echoed back, "
    "and neither reaches the bus -- so the only part of the request that leaves this product is a "
    "controller NUMBER, and what that number reaches is an assignment the operator made by hand "
    "inside Scripter. The product never held a parameter identity, which is why no readback could "
    "close ADR-009 here: the reply does not omit the name, there was never a name to omit. THE "
    "COUNTEREXAMPLE is a run where `insert` DOES change the wire -- every other clause still "
    "satisfied -- because that is the world in which this operation addresses a plug-in slot and a "
    "readback would have something to be about",
    mutation="`ScripterChannel` derives its CC from `insert` as well as `param` (cc = base + insert*18). "
             "`insert_does_not_reach_the_wire` goes false on its own, leaving the other clauses "
             "untouched, which is what makes that clause load-bearing rather than decorative. The "
             "separate mutation of adding any Logic-sourced field to the reply is caught by "
             "`fields_no_caller_could_have_supplied`",
)

d.close()
out = ev.write()
print(json.dumps(out, indent=1))
sys.exit(0 if E.is_clean(out) else 1)
