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

THE LATER PHASES: A FULL BANK AND THE CLAMPED LAST BANK
-------------------------------------------------------
Logic does not page the last bank by eight. With N strips a bank-right press lands on
min(offset + 8, N - 8), so on the 19-track fixture (21 MCU strips with Stereo Out and Master) the
second press shows strips 13-20, and strip 0 is TRACK 13, not track 16. Measured 2026-09-27 (ko) at
78581bbf: an arm meant for track 16 walked two steps that each redrew the row, pressed strip 0, and
armed track 13 (State B readback_mismatch). The repair counts a step as moved only when the row
provably shifted by all eight cells. A bank-right step whose row reads as the old one slid by fewer
is settled by ONE probe: Logic clamps only the last right step, so if one more Bank Right still
moves the row the step was a full eight, and a Bank Left must then redraw that step's row byte for
byte before the walk goes on. A probe that redraws the same row means Logic's last bank: refused.

Bank-1 phase, track 15 (strip 7 of the full bank 8-15): arm -> hold reads -> disarm through the MCU,
with the census armed set read before, after the arm and after the disarm, and track 7's arm (strip 7
of bank 0, where an unmoved walk would land) read throughout. Bank 0 and bank 1 of the ko fixture
share `DelCls`, so that step reads as a slide and is settled by the probe; the reply's
`bank_steps_disambiguated` is recorded raw. The fixture is not renamed: the repeated names are the
case the probe exists for.

Final-bank phase, track 16: one arm through the MCU. Expected: refused (State C), nothing armed, the
census armed set unchanged, track 13 unchanged, and the MCU upper row read from logic://mcu/state the
same after the reply as before it (the walk came home). The MCU rung's own code is
`bank_walk_unverified` with `write_attempted false`; the ROUTED reply is whatever the router makes of
that refusal, and both are recorded raw.

With fewer than 17 tracks listed the precondition fails with a message; it does not skip.

Restoring: the run ends through a second server started WITHOUT the bad variable, so the restore does
not depend on the code under test. It puts tracks 15, 16, 7 and 13 back as found.
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
               "bank_bookkeeping_after", "bank_step_short_of_eight", "bank_window_unaligned",
               "bank_steps_disambiguated", "bank_probe_unresolved")


def bank_fields(body):
    """The bank walk's own fields of an MCU reply, raw; a field the reply lacks reads None."""
    return {k: body.get(k) for k in BANK_FIELDS}


def armed_set(d):
    """The ids the refreshed track list reports armed, sorted; None when the list is not readable."""
    rows = track_rows(d)
    if not rows["rows"]:
        return None
    return sorted(r["id"] for r in rows["rows"] if r.get("isArmed") is True)


def upper_row(d):
    """The MCU LCD upper row as logic://mcu/state reports it, raw; None when absent."""
    raw = d.resource("logic://mcu/state") or {}
    return (raw.get("display") or {}).get("upperRow")


# Bank 1 (strips 8-15) is a full bank: its strip 7 is track 15. An unmoved walk lands on bank 0,
# whose strip 7 is track 7.
BANK_1_TRACK = 15
BANK_1_NEIGHBOUR = 7
# Track 16 is in the clamped last bank; Logic shows strips 13-20 there, so strip 0 is track 13.
FINAL_BANK_TRACK = 16
CLAMPED_TRACK = 13
# Rows measured 2026-09-27 (ko, 21 strips) for bank 0 and the clamped bank 2.
MEASURED_BANK_0_ROW = "AbsZer Audio1 DelCls DelCls DelCls DelCls DelCls DelCls "
MEASURED_BANK_2_ROW = "StdGrn StdGrn StdGrn StdGrn StdGrn StdGrn St Out Master "


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

# ---- Later phases: the full bank 1, then the clamped last bank --------------------------------------
listed = len(census["rows"])
enough = listed > FINAL_BANK_TRACK
found = {i: (armed_of(d, i) if enough else None)
         for i in (BANK_1_NEIGHBOUR, CLAMPED_TRACK, BANK_1_TRACK, FINAL_BANK_TRACK)}
found_set = armed_set(d) if enough else None
later_ready = (enough and found[BANK_1_TRACK] is False and found[FINAL_BANK_TRACK] is False
               and isinstance(found[BANK_1_NEIGHBOUR], bool) and isinstance(found[CLAMPED_TRACK], bool)
               and isinstance(found_set, list))
ev.check("1020/precondition-bank-1-and-final-bank-tracks-are-listed-and-disarmed",
         later_ready,
         f"logic://tracks lists at least {FINAL_BANK_TRACK + 1} tracks (the fixture has 19), tracks "
         f"{BANK_1_TRACK} and {FINAL_BANK_TRACK} read disarmed, and tracks {BANK_1_NEIGHBOUR} and "
         f"{CLAMPED_TRACK} read their arm as a boolean",
         {"tracks_listed": listed, "found": {str(k): v for k, v in found.items()}, "armed_set": found_set,
          "message": None if later_ready else
          f"cannot drive the bank phases: need at least {FINAL_BANK_TRACK + 1} tracks listed, tracks "
          f"{BANK_1_TRACK} and {FINAL_BANK_TRACK} disarmed and the arms of tracks {BANK_1_NEIGHBOUR} and "
          f"{CLAMPED_TRACK} readable; open the 19-track fixture and disarm tracks {BANK_1_TRACK} and "
          f"{FINAL_BANK_TRACK}"},
         "open a project with 16 or fewer tracks: the phases have no bank-1 or final-bank track to drive")

# -- Bank-1 phase: track 15, strip 7 of a full bank --
b1_on, b1_off, b1_held = {}, {}, []
b1_after_on = b1_after_off = n7_after_on = n7_after_off = None
set_after_on = set_after_off = None
if later_ready:
    b1_on = arm(d, f"arm-track-{BANK_1_TRACK}", BANK_1_TRACK, True)
    b1_after_on = armed_of(d, BANK_1_TRACK)
    n7_after_on = armed_of(d, BANK_1_NEIGHBOUR)
    set_after_on = armed_set(d)
    for _ in range(HOLD_SAMPLES):
        b1_held.append(armed_unrefreshed(d, BANK_1_TRACK))
        time.sleep(HOLD_INTERVAL_S)
    b1_off = arm(d, f"disarm-track-{BANK_1_TRACK}", BANK_1_TRACK, False)
    b1_after_off = armed_of(d, BANK_1_TRACK)
    n7_after_off = armed_of(d, BANK_1_NEIGHBOUR)
    set_after_off = armed_set(d)
ev.note("1020/bank-1-bank-fields", {"arm": bank_fields(b1_on), "disarm": bank_fields(b1_off)})

# What b1f16569 answered on the ko fixture, before the probe: bank 0 and bank 1 share `DelCls`, the
# one step could not be proved a full shift, and the MCU rung refused.
UNPROVABLE_STEP = {"state": "C", "write_source": None, "write_attempted": None, "observed": None,
                   "bank_presses_sent": 2, "banks_moved": 0, "banks_requested": 1, "bank_restored": True,
                   "bank_step_short_of_eight": True}

b1_arm_reading = {**summary(b1_on), **bank_fields(b1_on), "track": BANK_1_TRACK,
                  "armed_in_track_list_after": b1_after_on}
ev.falsifiable(
    "1020/bank-1-arm-through-the-mcu-sets-and-confirms",
    lambda o: (o["write_source"] == "mcu" and o["state"] == "A" and o["write_attempted"] is True
               and o["observed"] is True and o["armed_in_track_list_after"] is True
               and o["banks_moved"] == 1 and o["bank_restored"] is True
               and o["bank_step_short_of_eight"] is False),
    b1_arm_reading,
    {**b1_arm_reading, **UNPROVABLE_STEP, "armed_in_track_list_after": False},
    f"arming disarmed track {BANK_1_TRACK} through the MCU rung walks one step that provably shifted the "
    "row by eight strips, answers State A with write_attempted true and observed true, walks back, and the "
    "refreshed track list shows it armed. THE COUNTEREXAMPLE is b1f16569's refusal on the ko fixture, "
    "whose bank-0 and bank-1 names repeat: the step could not be proved a full shift and nothing was pressed",
    mutation="drop the probe in MCUChannel.walkBank and refuse every ambiguous step, as at b1f16569",
)

ev.falsifiable(
    "1020/bank-1-the-cached-arm-holds-through-the-rec-led-blink",
    lambda o: len(o["reads"]) == HOLD_SAMPLES and all(v is True for v in o["reads"]),
    {"track": BANK_1_TRACK, "reads": b1_held},
    {"track": BANK_1_TRACK, "reads": [c == "T" for c in MEASURED_BLINK]},
    f"while track {BANK_1_TRACK} is armed, {HOLD_SAMPLES} reads of logic://tracks "
    f"{int(HOLD_INTERVAL_S * 1000)} ms apart with no refresh all report it armed. THE COUNTEREXAMPLE is "
    "what they read before #1020, when every dark frame of the blinking Rec LED was written as a disarm",
    mutation="write isArmed from the Rec LED frame in MCUFeedbackParser.handleButton, as before #1020",
)

b1_disarm_reading = {**summary(b1_off), **bank_fields(b1_off), "track": BANK_1_TRACK,
                     "armed_in_track_list_after": b1_after_off}
ev.falsifiable(
    "1020/bank-1-disarm-through-the-mcu-clears-the-arm",
    lambda o: (o["write_source"] == "mcu" and o["state"] == "A" and o["write_attempted"] is True
               and o["observed"] is False and o["armed_in_track_list_after"] is False
               and o["banks_moved"] == 1 and o["bank_restored"] is True),
    b1_disarm_reading,
    {**b1_disarm_reading, "state": "B", "reason": "readback_unavailable", "verification_source": "mcu_led_echo",
     "write_attempted": None, "observed": None, "armed_in_track_list_after": True},
    f"disarming track {BANK_1_TRACK} through the MCU rung walks one full step and back, answers State A "
    "with observed false, and the refreshed track list shows it disarmed. THE COUNTEREXAMPLE is the shape "
    "before #1020: a lone velocity-0 release that Logic ignores, State B, and the track still armed",
    mutation="send enabled:false as the bare velocity-0 release, as MCUChannel did before #1020",
)

census_reading = {"as_found": found_set, "after_arm": set_after_on, "after_disarm": set_after_off}
ev.falsifiable(
    "1020/bank-1-census-armed-set-is-15-then-as-found",
    lambda o: (isinstance(o["as_found"], list)
               and o["after_arm"] == sorted(set(o["as_found"]) | {BANK_1_TRACK})
               and o["after_disarm"] == o["as_found"]),
    census_reading,
    {"as_found": [], "after_arm": [BANK_1_NEIGHBOUR], "after_disarm": []},
    f"the refreshed census's armed set is the as-found set plus track {BANK_1_TRACK} after the arm (on the "
    f"fixture, where nothing is armed, [{BANK_1_TRACK}]) and the as-found set after the disarm ([]). THE "
    f"COUNTEREXAMPLE is a strip byte that landed on an unmoved bank 0: track {BANK_1_NEIGHBOUR} armed instead",
    mutation="run the strip write in MCUChannel.withBanking even when a bank step did not move",
)

n7_reading = {"before": found.get(BANK_1_NEIGHBOUR), "after_arm": n7_after_on, "after_disarm": n7_after_off}
ev.falsifiable(
    "1020/bank-1-writes-leave-track-7-arm-unchanged",
    lambda o: (isinstance(o["before"], bool) and o["after_arm"] is o["before"]
               and o["after_disarm"] is o["before"]),
    n7_reading,
    {"before": False, "after_arm": True, "after_disarm": True},
    f"track {BANK_1_NEIGHBOUR}'s arm, read before the bank-1 arm, after it and after the disarm, never "
    f"changes. THE COUNTEREXAMPLE is the strip byte landing on an unmoved bank 0, where strip 7 is track "
    f"{BANK_1_NEIGHBOUR}",
    mutation="run the strip write in MCUChannel.withBanking even when a bank step did not move",
)

# -- Final-bank phase: track 16 in the clamped last bank --
fb_on = {}
fb_set_before = fb_row_before = fb_row_after = fb_set_after = fb_16_after = fb_13_after = None
if later_ready:
    fb_set_before = armed_set(d)
    fb_row_before = upper_row(d)
    fb_on = arm(d, f"arm-track-{FINAL_BANK_TRACK}", FINAL_BANK_TRACK, True)
    fb_row_after = upper_row(d)
    fb_16_after = armed_of(d, FINAL_BANK_TRACK)
    fb_13_after = armed_of(d, CLAMPED_TRACK)
    fb_set_after = armed_set(d)
ev.note("1020/final-bank-reply-raw", {**summary(fb_on), **bank_fields(fb_on), "code": fb_on.get("code"),
                                      "last_error": fb_on.get("last_error"), "success": fb_on.get("success")})

fb_reading = {"state": fb_on.get("state"), "success": fb_on.get("success"), "error": fb_on.get("error"),
              "last_error": fb_on.get("last_error"), "write_source": fb_on.get("write_source"),
              "write_attempted": fb_on.get("write_attempted"),
              "armed_set_before": fb_set_before, "armed_set_after": fb_set_after,
              "track_16_armed_after": fb_16_after,
              "track_13_before": found.get(CLAMPED_TRACK), "track_13_after": fb_13_after}
ev.falsifiable(
    "1020/final-bank-arm-is-refused-with-nothing-armed",
    lambda o: (o["state"] == "C" and o["success"] is not True and o["write_attempted"] is not True
               and isinstance(o["armed_set_before"], list) and o["armed_set_after"] == o["armed_set_before"]
               and o["track_16_armed_after"] is False
               and isinstance(o["track_13_before"], bool) and o["track_13_after"] is o["track_13_before"]),
    fb_reading,
    {**fb_reading, "state": "B", "success": None, "error": "readback_mismatch", "last_error": None,
     "write_source": "mcu", "write_attempted": True, "armed_set_before": [], "armed_set_after": [CLAMPED_TRACK],
     "track_16_armed_after": False, "track_13_before": False, "track_13_after": True},
    f"arming track {FINAL_BANK_TRACK}, which sits in the clamped last bank, is refused (State C, no success, "
    f"no write attempted), nothing is armed: the census armed set is the same before and after, track "
    f"{FINAL_BANK_TRACK} reads disarmed and track {CLAMPED_TRACK} is unchanged. THE COUNTEREXAMPLE is the "
    f"reply measured at 78581bbf (ko): State B readback_mismatch after a strip byte that armed track "
    f"{CLAMPED_TRACK}",
    mutation="drop the full-shift requirement from withBanking's outward walk in MCUChannel",
)

ev.falsifiable(
    "1020/final-bank-leaves-the-mcu-window-home",
    lambda o: isinstance(o["before"], str) and bool(o["before"].strip()) and o["after"] == o["before"],
    {"before": fb_row_before, "after": fb_row_after},
    {"before": MEASURED_BANK_0_ROW, "after": MEASURED_BANK_2_ROW},
    "the MCU upper row read from logic://mcu/state after the refused arm is the row it showed before: the "
    "walk went back as far as it went out. THE COUNTEREXAMPLE is a walk left on the clamped bank, the rows "
    "measured 2026-09-27 (ko) for bank 0 and bank 2",
    mutation="skip the walk back in MCUChannel.withBanking when the outward walk falls short",
)
d.close()

# ---- Restore through a server that does not depend on the code under test ---------------------------
os.environ.pop(ARM_KEYCODE_ENV, None)
if chosen is not None or later_ready:
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
    if later_ready:
        for index in (BANK_1_TRACK, FINAL_BANK_TRACK, BANK_1_NEIGHBOUR, CLAMPED_TRACK):
            want = found[index]
            now = armed_of(restorer, index)
            if isinstance(now, bool) and now is not want:
                ev.note(f"1020/restore-track-{index}",
                        restorer.tool("logic_tracks", "arm", {"index": index, "enabled": want}) or {})
                now = armed_of(restorer, index)
            ev.restored(f"1020/track-{index}-arm-as-found", now is want,
                        json.dumps({"track": index, "armed_before": want, "armed_in_track_list": now}))
    restorer.close()

out = ev.write()
print(json.dumps(out, indent=1))
sys.exit(0 if E.is_clean(out) else 1)
