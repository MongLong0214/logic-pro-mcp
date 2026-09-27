#!/usr/bin/env python3
"""Live proof that `track.set_arm` on the MCU rung sets the arm state instead of toggling it (#1020).

Usage:  LPM_EVIDENCE_ROOT=/abs/path/outside/repo \
        python3 live_1020_mcu_set_arm_is_a_set.py <worktree> <full-40-char-head-sha> [binary]

`binary` defaults to `<worktree>/.build/release/LogicProMCP`. Pass a copy at a fresh path when the
build directory may be serving a stale image.

HOW THE RUN REACHES THE MCU RUNG
--------------------------------
`track.set_arm` routes Accessibility -> MCU -> CGEvent. The Accessibility rung arms a track with the
"Toggle Track Record Enable" key chord, and `LOGIC_PRO_MCP_ARM_KEYCODE` overrides that chord. This
harness starts the server with that variable set to a value that does not parse, which is a real
misconfiguration the product already handles: the key rung refuses `arm_key_config_invalid`, which is
not terminal, and the router walks on to the MCU. Every reply is checked for `write_source: mcu`, so a
run where Accessibility answered instead is reported, not counted.

Only a state that DIFFERS from the request reaches the MCU this way. When the track already holds the
requested state, the Accessibility rung answers a verified no-op before any rung runs, so the
MCU's own "already set" branch is not driven here; the unit tests carry it.

WHAT THIS MEASURES
------------------
On one track that starts disarmed: arm it, then disarm it, each through the MCU rung. After each
reply the harness refreshes the cache and reads the track's `isArmed` from `logic://tracks`, which the
poller fills from the track list, not from the handler's own readback.

Before #1020, `enabled: false` sent a lone velocity-0 release, which Logic ignores, so a disarm through
the MCU left the track armed. That is the counterexample for the disarm check.

While the track is armed the harness also reads `logic://tracks` thirty times, 100 ms apart, WITHOUT a
refresh. Logic blinks the Rec LED of an armed track, and before #1020 `MCUFeedbackParser` wrote each
frame into the cache, so the reads came back `FFFTTTTTTTFFFFFFFTTTTTTTFFFFFF` on an armed track
(measured 2026-09-27, en-US). That pattern is the counterexample for the hold check.

THE SECOND PHASE: A TRACK IN BANK 2
-----------------------------------
The same arm -> hold reads -> disarm sequence then runs on track 16, which the MCU reaches only by
walking the fader bank two steps right and two back. Logic 12.3 was measured moving ONE bank for two
bank presses sent back to back (docs/observations/2026-09-27-*-a-bank-step-answers-from-the-redrawn-
upper-row.json), and before review round 1 of #1020 `withBanking` sent exactly that: a strip byte
behind two unverified presses, which would land on bank 1 and toggle track 8. So this phase records
the MCU reply's bank fields raw (`bank_presses_sent`, `banks_moved`, `bank_restored`, `step_windows`)
and reads track 8's arm from `logic://tracks` before the arm, after it and after the disarm. The
fixture has 19 tracks; with fewer than 17 listed the precondition fails with a message, it does not
skip.

Restoring: the run ends by disarming through a second server started WITHOUT the bad variable, so the
restore does not depend on the code under test. It puts back track 16 and track 8 as well.
"""
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import evidence as E  # noqa: E402


COVERS = [
    "Sources/LogicProMCP/Channels/MCUChannel.swift",
    "Sources/LogicProMCP/Server/LogicProServer.swift",
    "Sources/LogicProMCP/Channels/RoutingTable.swift",
    "Sources/LogicProMCP/MIDI/MCUFeedbackParser.swift",
]

WT = sys.argv[1] if len(sys.argv) > 1 else ""
HEAD = sys.argv[2] if len(sys.argv) > 2 else ""
if not WT or not HEAD:
    sys.exit(__doc__)

E.REPO = WT
E.BIN = sys.argv[3] if len(sys.argv) > 3 else f"{WT}/.build/release/LogicProMCP"
missing = E.have_tools()
if missing:
    sys.exit(f"cannot run: missing {missing}")

ev = E.Evidence(HEAD, os.environ["LPM_EVIDENCE_ROOT"], surface="non_ui")

ARM_KEYCODE_ENV = "LOGIC_PRO_MCP_ARM_KEYCODE"
UNPARSEABLE_KEYCODE = "not-a-keycode"
# The tracks tried, in order, before giving up on finding one the MCU rung answers for.
CANDIDATE_LIMIT = 4
# Unrefreshed reads of the armed track: 30 x 100 ms spans two blink cycles and one poller tick.
HOLD_SAMPLES = 30
HOLD_INTERVAL_S = 0.1
# The reads measured on 2026-09-27 (en-US) before the parser stopped writing the Rec LED into the cache.
MEASURED_BLINK = "FFFTTTTTTTFFFFFFFTTTTTTTFFFFFF"


def mcu_state(d):
    raw = d.resource("logic://mcu/state") or {}
    conn = raw.get("connection") or {}
    return {"isConnected": conn.get("isConnected"), "registeredAsDevice": conn.get("registeredAsDevice")}


def track_rows(d):
    d.tool("logic_system", "refresh_cache")
    tracks = d.resource("logic://tracks") or {}
    rows = [r for r in (tracks.get("data") or []) if isinstance(r.get("id"), int)]
    return {"readable": tracks.get("readable"), "source": tracks.get("source"),
            "rows": sorted(rows, key=lambda r: r["id"])}


def armed_of(d, index):
    """`isArmed` for one track as the refreshed track list reports it, or None when it is not listed."""
    for r in track_rows(d)["rows"]:
        if r["id"] == index:
            return r.get("isArmed")
    return None


def armed_unrefreshed(d, index):
    """`isArmed` for one track straight from the cache, with no refresh first; None when not listed."""
    tracks = d.resource("logic://tracks") or {}
    for r in tracks.get("data") or []:
        if r.get("id") == index:
            return r.get("isArmed")
    return None


def arm(d, label, index, enabled):
    body = d.tool("logic_tracks", "arm", {"index": index, "enabled": enabled}) or {}
    ev.note(f"1020/{label}", body)
    return body


def summary(body):
    return {k: body.get(k) for k in ("state", "reason", "error", "write_source", "verification_source",
                                     "write_attempted", "observed", "fallback_from_channel",
                                     "fallback_from_error")}


BANK_FIELDS = ("bank_presses_sent", "banks_moved", "banks_requested", "bank_restored", "step_windows",
               "bank_bookkeeping_after")


def bank_fields(body):
    """The bank walk's own fields of an MCU reply, raw; a field the reply lacks reads None."""
    return {k: body.get(k) for k in BANK_FIELDS}


# The track the second phase drives: strip 0 of bank 2. One bank short of it is TRACK_ONE_BANK_SHORT.
BANK_2_TRACK = 16
TRACK_ONE_BANK_SHORT = 8


# ---- A server whose Accessibility arm rung refuses -------------------------------------------------
os.environ[ARM_KEYCODE_ENV] = UNPARSEABLE_KEYCODE
d = E.Driver()
# Logic answers the device query within a second on a bound surface; the rest is the LCD burst.
time.sleep(8)
mcu = mcu_state(d)
if not mcu["isConnected"]:
    ev.note("1020/setup-control-surface", d.tool("logic_system", "setup_control_surface", {"consent": True}) or {})
    time.sleep(8)
    mcu = mcu_state(d)
ev.note("1020/mcu-state", mcu)

census = track_rows(d)
ev.note("1020/track-census", {"readable": census["readable"], "source": census["source"],
                              "rows": [{k: r.get(k) for k in ("id", "name", "type", "isArmed")}
                                       for r in census["rows"]]})
candidates = [r["id"] for r in census["rows"] if r.get("isArmed") is False][:CANDIDATE_LIMIT]

chosen, on, tried = None, {}, []
for index in candidates:
    on = arm(d, f"arm-track-{index}", index, True)
    tried.append({"index": index, **summary(on)})
    if on.get("write_source") == "mcu":
        chosen = index
        break
    # Accessibility or nothing answered. Put back anything that moved before trying the next one.
    if armed_of(d, index) is True:
        arm(d, f"undo-track-{index}", index, False)

ev.check("1020/precondition-the-arm-reached-the-mcu-rung",
         bool(mcu["isConnected"]) and chosen is not None,
         f"the MCU surface is connected, and with {ARM_KEYCODE_ENV} unparseable an arm on a disarmed "
         "track is answered by the MCU rung (write_source mcu)",
         {"mcu": mcu, "candidates": candidates, "tried": tried},
         "give the Accessibility arm rung a working chord: it answers and the MCU rung is never reached")

armed_after_on = armed_of(d, chosen) if chosen is not None else None
held = []
if chosen is not None:
    for _ in range(HOLD_SAMPLES):
        held.append(armed_unrefreshed(d, chosen))
        time.sleep(HOLD_INTERVAL_S)
off = arm(d, f"disarm-track-{chosen}", chosen, False) if chosen is not None else {}
armed_after_off = armed_of(d, chosen) if chosen is not None else None

arm_reading = {**summary(on), "track": chosen, "armed_in_track_list_after": armed_after_on}
ev.falsifiable(
    "1020/arm-through-the-mcu-sets-and-confirms",
    lambda o: (o["write_source"] == "mcu" and o["state"] == "A" and o["write_attempted"] is True
               and o["observed"] is True and o["armed_in_track_list_after"] is True),
    arm_reading,
    {**arm_reading, "state": "B", "reason": "readback_unavailable", "verification_source": "mcu_led_echo",
     "write_attempted": None, "observed": None},
    "arming a disarmed track through the MCU rung answers State A with write_attempted true and observed "
    "true, and the refreshed track list shows the track armed. THE COUNTEREXAMPLE is the reply before "
    "#1020: State B readback_unavailable from the LED echo, with no reading of the track",
    mutation="drop the confirming read in MCUChannel.executeStripButtonSet and answer State B after the press",
)

ev.falsifiable(
    "1020/the-cached-arm-holds-through-the-rec-led-blink",
    lambda o: len(o["reads"]) == HOLD_SAMPLES and all(v is True for v in o["reads"]),
    {"track": chosen, "reads": held},
    {"track": chosen, "reads": [c == "T" for c in MEASURED_BLINK]},
    f"while the track is armed, {HOLD_SAMPLES} reads of logic://tracks {int(HOLD_INTERVAL_S * 1000)} ms "
    "apart with no refresh all report it armed. THE COUNTEREXAMPLE is what they read before #1020, when "
    "every dark frame of Logic's blinking Rec LED was written into the cache as a disarm",
    mutation="write isArmed from the Rec LED frame in MCUFeedbackParser.handleButton, as before #1020",
)

disarm_reading = {**summary(off), "track": chosen, "armed_in_track_list_after": armed_after_off}
ev.falsifiable(
    "1020/disarm-through-the-mcu-clears-the-arm",
    lambda o: (o["write_source"] == "mcu" and o["state"] == "A" and o["write_attempted"] is True
               and o["observed"] is False and o["armed_in_track_list_after"] is False),
    disarm_reading,
    {**disarm_reading, "state": "B", "reason": "readback_unavailable", "verification_source": "mcu_led_echo",
     "write_attempted": None, "observed": None, "armed_in_track_list_after": True},
    "disarming the same track through the MCU rung answers State A with observed false, and the refreshed "
    "track list shows it disarmed. THE COUNTEREXAMPLE is the shape before #1020: a lone velocity-0 "
    "release that Logic ignores, State B, and the track still armed",
    mutation="send enabled:false as the bare velocity-0 release, as MCUChannel did before #1020",
)

# ---- Second phase: a track two banks away ----------------------------------------------------------
listed = len(census["rows"])
b2_before = armed_of(d, BANK_2_TRACK) if listed > BANK_2_TRACK else None
t8_before = armed_of(d, TRACK_ONE_BANK_SHORT) if listed > BANK_2_TRACK else None
b2_ready = listed > BANK_2_TRACK and b2_before is False and isinstance(t8_before, bool)
ev.check("1020/precondition-bank-2-track-is-listed-and-disarmed",
         b2_ready,
         f"logic://tracks lists at least {BANK_2_TRACK + 1} tracks (the fixture has 19), track "
         f"{BANK_2_TRACK} reads disarmed and track {TRACK_ONE_BANK_SHORT}'s arm reads as a boolean",
         {"tracks_listed": listed, "track_16_armed": b2_before, "track_8_armed": t8_before,
          "message": None if b2_ready else
          f"cannot drive bank 2: need track {BANK_2_TRACK} listed and disarmed and track "
          f"{TRACK_ONE_BANK_SHORT}'s arm readable; open the 19-track fixture and disarm track {BANK_2_TRACK}"},
         "open a project with 16 or fewer tracks: the phase has no bank-2 track to drive")

b2_on, b2_off, b2_held = {}, {}, []
t8_after_on = t8_after_off = b2_after_on = b2_after_off = None
if b2_ready:
    b2_on = arm(d, f"arm-track-{BANK_2_TRACK}", BANK_2_TRACK, True)
    b2_after_on = armed_of(d, BANK_2_TRACK)
    t8_after_on = armed_of(d, TRACK_ONE_BANK_SHORT)
    for _ in range(HOLD_SAMPLES):
        b2_held.append(armed_unrefreshed(d, BANK_2_TRACK))
        time.sleep(HOLD_INTERVAL_S)
    b2_off = arm(d, f"disarm-track-{BANK_2_TRACK}", BANK_2_TRACK, False)
    b2_after_off = armed_of(d, BANK_2_TRACK)
    t8_after_off = armed_of(d, TRACK_ONE_BANK_SHORT)
ev.note("1020/bank-2-bank-fields", {"arm": bank_fields(b2_on), "disarm": bank_fields(b2_off)})

# What 71c2ead3 answered on the measured cadence: the second of two back-to-back bank presses
# absorbed, the strip byte on bank 1, track 16 unchanged, and no bank fields at all.
PRE_REPAIR_BANK_FIELDS = {k: None for k in BANK_FIELDS}

b2_arm_reading = {**summary(b2_on), **bank_fields(b2_on), "track": BANK_2_TRACK,
                  "armed_in_track_list_after": b2_after_on}
ev.falsifiable(
    "1020/bank-2-arm-through-the-mcu-sets-and-confirms",
    lambda o: (o["write_source"] == "mcu" and o["state"] == "A" and o["write_attempted"] is True
               and o["observed"] is True and o["armed_in_track_list_after"] is True
               and o["banks_moved"] == 2 and o["bank_restored"] is True),
    b2_arm_reading,
    {**b2_arm_reading, **PRE_REPAIR_BANK_FIELDS, "state": "B", "reason": "readback_mismatch",
     "observed": False, "armed_in_track_list_after": False},
    f"arming disarmed track {BANK_2_TRACK} through the MCU rung walks two verified bank steps, answers "
    "State A with write_attempted true and observed true, walks back (bank_restored true), and the "
    "refreshed track list shows it armed. THE COUNTEREXAMPLE is the reply at 71c2ead3 on the measured "
    "cadence: the strip byte lands on bank 1, track 16 never flips, State B readback_mismatch, no bank fields",
    mutation="send withBanking's bank presses back to back with no per-step reading, as at 71c2ead3",
)

ev.falsifiable(
    "1020/bank-2-the-cached-arm-holds-through-the-rec-led-blink",
    lambda o: len(o["reads"]) == HOLD_SAMPLES and all(v is True for v in o["reads"]),
    {"track": BANK_2_TRACK, "reads": b2_held},
    {"track": BANK_2_TRACK, "reads": [c == "T" for c in MEASURED_BLINK]},
    f"while track {BANK_2_TRACK} is armed, {HOLD_SAMPLES} reads of logic://tracks "
    f"{int(HOLD_INTERVAL_S * 1000)} ms apart with no refresh all report it armed. THE COUNTEREXAMPLE is "
    "what they read before #1020, when every dark frame of the blinking Rec LED was written as a disarm",
    mutation="write isArmed from the Rec LED frame in MCUFeedbackParser.handleButton, as before #1020",
)

b2_disarm_reading = {**summary(b2_off), **bank_fields(b2_off), "track": BANK_2_TRACK,
                     "armed_in_track_list_after": b2_after_off}
ev.falsifiable(
    "1020/bank-2-disarm-through-the-mcu-clears-the-arm",
    lambda o: (o["write_source"] == "mcu" and o["state"] == "A" and o["write_attempted"] is True
               and o["observed"] is False and o["armed_in_track_list_after"] is False
               and o["banks_moved"] == 2 and o["bank_restored"] is True),
    b2_disarm_reading,
    {**b2_disarm_reading, **PRE_REPAIR_BANK_FIELDS, "state": "B", "reason": "readback_mismatch",
     "observed": True, "armed_in_track_list_after": True},
    f"disarming track {BANK_2_TRACK} through the MCU rung walks two verified bank steps and back, answers "
    "State A with observed false, and the refreshed track list shows it disarmed. THE COUNTEREXAMPLE is "
    "the defect review round 1 named: enabled false pressed strip 0 on bank 1, track 16 stayed armed",
    mutation="send withBanking's bank presses back to back with no per-step reading, as at 71c2ead3",
)

ev.falsifiable(
    "1020/bank-2-replies-came-from-the-mcu-rung-over-a-verified-walk",
    lambda o: all(
        r["write_source"] == "mcu" and r["bank_presses_sent"] == 4 and r["banks_moved"] == 2
        and r["banks_requested"] == 2 and r["bank_restored"] is True
        and isinstance(r["step_windows"], list) and len(r["step_windows"]) == 4
        for r in (o["arm"], o["disarm"])
    ),
    {"arm": {"write_source": b2_on.get("write_source"), **bank_fields(b2_on)},
     "disarm": {"write_source": b2_off.get("write_source"), **bank_fields(b2_off)}},
    {"arm": {"write_source": "mcu", **PRE_REPAIR_BANK_FIELDS},
     "disarm": {"write_source": "mcu", **PRE_REPAIR_BANK_FIELDS}},
    "both bank-2 replies came from the MCU rung and carry the walk's own fields: four bank presses, two "
    "banks moved of two requested, restored, and one upper-row window per press. THE COUNTEREXAMPLE is "
    "the MCU reply at 71c2ead3, which sent its presses unverified and reported none of these fields",
    mutation="drop the addExtras of the bank fields from MCUChannel.withBanking's success path",
)

t8_reading = {"before": t8_before, "after_arm": t8_after_on, "after_disarm": t8_after_off}
ev.falsifiable(
    "1020/bank-2-writes-leave-track-8-arm-unchanged",
    lambda o: (isinstance(o["before"], bool) and o["after_arm"] is o["before"]
               and o["after_disarm"] is o["before"]),
    t8_reading,
    {"before": False, "after_arm": True, "after_disarm": True},
    f"track {TRACK_ONE_BANK_SHORT}'s arm, read from logic://tracks before the bank-2 arm, after it and "
    "after the disarm, never changes. THE COUNTEREXAMPLE is the strip byte landing one bank short: the "
    f"arm meant for track {BANK_2_TRACK} arms track {TRACK_ONE_BANK_SHORT}, and the disarm leaves it armed",
    mutation="run the strip write in MCUChannel.withBanking even when a bank step did not move",
)
d.close()

# ---- Restore through a server that does not depend on the code under test ---------------------------
os.environ.pop(ARM_KEYCODE_ENV, None)
if chosen is not None or b2_ready:
    restorer = E.Driver()
    time.sleep(5)
    if chosen is not None:
        final = armed_of(restorer, chosen)
        if final is True:
            ev.note("1020/restore-disarm",
                    restorer.tool("logic_tracks", "arm", {"index": chosen, "enabled": False}) or {})
            final = armed_of(restorer, chosen)
        ev.restored("1020/track-disarmed-again", final is False,
                    json.dumps({"track": chosen, "armed_in_track_list": final}))
    if b2_ready:
        final_16 = armed_of(restorer, BANK_2_TRACK)
        if final_16 is True:
            ev.note("1020/restore-disarm-track-16",
                    restorer.tool("logic_tracks", "arm", {"index": BANK_2_TRACK, "enabled": False}) or {})
            final_16 = armed_of(restorer, BANK_2_TRACK)
        ev.restored("1020/track-16-disarmed-again", final_16 is False,
                    json.dumps({"track": BANK_2_TRACK, "armed_in_track_list": final_16}))
        final_8 = armed_of(restorer, TRACK_ONE_BANK_SHORT)
        if isinstance(final_8, bool) and final_8 is not t8_before:
            ev.note("1020/restore-track-8",
                    restorer.tool("logic_tracks", "arm",
                                  {"index": TRACK_ONE_BANK_SHORT, "enabled": t8_before}) or {})
            final_8 = armed_of(restorer, TRACK_ONE_BANK_SHORT)
        ev.restored("1020/track-8-arm-as-found", final_8 is t8_before,
                    json.dumps({"track": TRACK_ONE_BANK_SHORT, "armed_before": t8_before,
                                "armed_in_track_list": final_8}))
    restorer.close()

out = ev.write()
print(json.dumps(out, indent=1))
sys.exit(0 if E.is_clean(out) else 1)
