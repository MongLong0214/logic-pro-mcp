#!/usr/bin/env python3
"""Prove the #904 live runner's row classifier never counts a fallback as the set.

`live_904_labelsets_in_every_locale.classify` turns one MCP reply into how a LabelSet was reached:
the set, a named fallback, or not at all. The cases below give it reply shapes the server emits
(the keys are the ones the Swift sources write: `reconciled_modal_kind`,
`track_type_verification_source`, `observed_mode`, `automationMode`, `type`,
`plugin_view_restore_attempted`, `plugin_view_switch_phase`, `regions[].kind`) and assert the
outcome, then drive `run_locale` against a canned driver to show every set gets a row and that the
row count check refuses a locale that is short. Last, `main` runs with the screen instruments
answered by a scenario, to show its exit code is 1 whenever evidence.py's `is_clean` refuses the
document it wrote, even when every row is complete.

WHAT IS NOT JUDGED
------------------
Nothing here talks to Logic. Whether Logic emits these shapes in each language is what the live
runner measures; this file only proves the classifier reads them honestly.

    python3 test_live_904_labelset_rows.py
"""
import contextlib
import importlib.util
import io
import json
import datetime
import os
import re
import subprocess
import sys
import tempfile
import types

HERE = os.path.dirname(os.path.abspath(__file__))
LIVEKIT = os.path.join(HERE, "livekit")
sys.path.insert(0, LIVEKIT)  # the runner imports `evidence` and live_993 beside it


def load(name):
    """The harness loaded from its file, as livekit/test_quit_refuses_other_documents.py does.

    A `live_*.py` is an entry point, which check-dead-harness-helpers.py relies on; it is loaded
    here by path rather than imported by name so that premise stays true.
    """
    spec = importlib.util.spec_from_file_location(name, os.path.join(LIVEKIT, name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


R = load("live_904_labelsets_in_every_locale")

failed = 0


def check(label, ok, detail=""):
    global failed
    print(("ok   " if ok else "FAIL ") + label + (f"  ({detail})" if detail and not ok else ""))
    failed += 0 if ok else 1


def expect(label, got, want):
    check(label, got == want, f"got {got!r}, want {want!r}")


C = R.classify

# deleteTracksPrimaryButton: the English prefix fallback sits beside the set in EVERY language
# (readModalSignals, ModalReconcile.swift:873-876), and the reply names neither the button it matched
# nor which test matched: a German sheet whose button reads `Delete arbitrary` answers exactly this.
expect("an English delete_confirm is the set or the Delete prefix, never the set alone",
       C("deleteTracksPrimaryButton", "en", "delete", {"reconciled_modal_kind": "delete_confirm"}),
       "set_or_fallback:Delete_prefix")
for lproj in ("de", "ja", "zh_TW"):
    expect(f"a {lproj} delete_confirm is the set or the Delete prefix: the reply cannot say which",
           C("deleteTracksPrimaryButton", lproj, "delete", {"reconciled_modal_kind": "delete_confirm"}),
           "set_or_fallback:Delete_prefix")
check("no locale's delete_confirm is credited to the set alone",
      all(C("deleteTracksPrimaryButton", code, "delete", {"state": "A",
                                                          "reconciled_modal_kind": "delete_confirm",
                                                          "reconciled_action": "confirm_delete"})
          != "set" for code in R.DEFAULT_LPROJS))
expect("an unknown_sheet on delete is the set refusing",
       C("deleteTracksPrimaryButton", "fr", "delete", {"reconciled_modal_kind": "unknown_sheet"}),
       "refused")
expect("a delete with no sheet did not reach the set",
       C("deleteTracksPrimaryButton", "fr", "delete", {"state": "A"}), "not_reached")

# inspectorChannelStripHelpPrefix / midiEffectSlotHelpKeyword.
family = {"track_type_verification_source": "inspector_channel_strip_instrument_family"}
strip = {"track_type_verification_source": "inspector_channel_strip"}
header = {"track_type_verification_source": "observed_header"}
expect("instrument_family proves the prefix",
       C("inspectorChannelStripHelpPrefix", "ko", "create_instrument", family), "set")
expect("instrument_family proves the MIDI-effect keyword",
       C("midiEffectSlotHelpKeyword", "ko", "create_instrument", family), "set")
expect("inspector_channel_strip proves the prefix",
       C("inspectorChannelStripHelpPrefix", "es", "create_audio", strip), "set")
check("inspector_channel_strip does not prove the MIDI-effect keyword",
      C("midiEffectSlotHelpKeyword", "es", "create_instrument", strip) != "set")
for name in ("inspectorChannelStripHelpPrefix", "midiEffectSlotHelpKeyword"):
    expect(f"observed_header is the fallback for {name}",
           C(name, "it", "create_instrument", header), "fallback:observed_header")
expect("a create with no source did not reach the strip",
       C("inspectorChannelStripHelpPrefix", "it", "create_audio", {"state": "C", "error": "x"}),
       "not_reached")

# trackTypeExternalMIDI.
ext_call = "logic://tracks after create_external_midi"
check("an `unknown` type is not the set",
      C("trackTypeExternalMIDI", "pt", ext_call, {"name": "Ext", "type": "unknown"}) != "set")
expect("an external_midi type is the set or the GM Device set",
       C("trackTypeExternalMIDI", "pt", ext_call, {"name": "MIDI 3", "type": "external_midi"}),
       "set_or_fallback:trackTypeGMDevice")
expect("a GM Device name answers before the set",
       C("trackTypeExternalMIDI", "pt", ext_call, {"name": "GM Device 2", "type": "external_midi"}),
       "fallback:gm_device_name")
expect("a different type is the set refusing",
       C("trackTypeExternalMIDI", "pt", ext_call, {"name": "x", "type": "software_instrument"}),
       "refused")

# automationModeRead / Touch / Write.
expect("`off` read back for a requested read is the unreadable default",
       C("automationModeRead", "de", "logic://tracks after set_automation:read",
         {"automationMode": "off"}),
       "fallback:unreadable_defaults_off")
expect("the requested mode read back is the set",
       C("automationModeWrite", "de", "logic://tracks after set_automation:write",
         {"automationMode": "write"}), "set")
expect("the reply's readable observed_mode is the set",
       C("automationModeTouch", "de", "set_automation:touch", {"observed_mode": "touch"}), "set")
check("a mode read for another request is not the set",
      C("automationModeTouch", "de", "set_automation:touch", {"observed_mode": "read"}) != "set")
check("a Read row cannot be satisfied by a Write call",
      C("automationModeRead", "de", "set_automation:write", {"observed_mode": "read"}) != "set")

# pluginWindowControlsViewMenuItem.
expect("plugin_view_not_confirmed with item_not_found is the set refusing",
       C("pluginWindowControlsViewMenuItem", "zh_CN", "set_param_verified",
         {"error": "plugin_view_not_confirmed", "plugin_view_switch_phase": "item_not_found"}),
       "refused")
check("a reply without plugin_view_restore_attempted is not the set",
      C("pluginWindowControlsViewMenuItem", "zh_CN", "set_param_verified", {"state": "A"}) != "set")
check("plugin_view_restore_attempted False (already in Controls view) is not the set",
      C("pluginWindowControlsViewMenuItem", "zh_CN", "set_param_verified",
        {"state": "A", "plugin_view_restore_attempted": False}) != "set")
expect("plugin_view_restore_attempted True is the set",
       C("pluginWindowControlsViewMenuItem", "zh_CN", "set_param_verified",
         {"state": "A", "plugin_view_restore_attempted": True}), "set")
check("a reply from a call other than set_param_verified is not the set",
      C("pluginWindowControlsViewMenuItem", "zh_CN", "insert_verified",
        {"plugin_view_restore_attempted": True}) != "set")

# regionKindMidi / trackContentExplicit.
expect("a midi region is the set",
       C("regionKindMidi", "ja", "get_regions", {"regions": [{"kind": "audio"}, {"kind": "midi"}]}),
       "set")
expect("no midi region did not reach the set",
       C("regionKindMidi", "ja", "get_regions", {"regions": [{"kind": "audio"}]}), "not_reached")
expect("trackContentExplicit is indistinguishable from its generic fallback",
       C("trackContentExplicit", "ja", "get_regions", {"regions": []}), "indistinguishable")

# The Limits.
for name in R.LIMITS:
    expect(f"{name} is a Limit", C(name, "ko", "none", {}), "not_reachable_via_mcp")

# Every outcome is one of the named ones.
seen = set()
for name in R.SETS:
    for call in ("delete", "create_instrument", "create_audio", ext_call, "set_param_verified",
                 "set_automation:read", "logic://tracks after set_automation:read", "get_regions"):
        for reply in (family, strip, header, {"automationMode": "off"}, {"type": "unknown"},
                      {"reconciled_modal_kind": "delete_confirm"}, {}, None):
            seen.add(C(name, "en", call, reply).split(":")[0])
check("classify returns only the named outcomes", seen <= set(R.OUTCOMES), sorted(seen))

# The excerpt carries the reply's own consumed keys and nothing derived.
big = {"regions": [{"kind": "midi", "name": "x" * 50}] * 40, "state": "A", "noise": 1}
text = R.excerpt("regionKindMidi", big)
check("an excerpt is at most 400 characters", len(text) <= R.EXCERPT_LIMIT, len(text))
check("an excerpt drops keys the classifier does not read", "noise" not in text)
check("an excerpt carries the consumed value itself",
      json.loads(R.excerpt("automationModeRead", {"automationMode": "off"})) == {"automationMode": "off"})
reply_b = {"state": "B", "reason": "retry_exhausted", "reconciled_modal_observation": "incomplete",
           "reconciled_modal_unreadable_reason": "top_level_window_modal_read_failed",
           "reconciled_modal_unreadable_ax_status": -25205, "noise": 1}
check("an excerpt carries a State B reply's own account of why it stopped",
      json.loads(R.excerpt("inspectorChannelStripHelpPrefix", reply_b)) ==
      {"state": "B", "reason": "retry_exhausted", "reconciled_modal_observation": "incomplete",
       "reconciled_modal_unreadable_reason": "top_level_window_modal_read_failed",
       "reconciled_modal_unreadable_ax_status": -25205})

# A failure the classifier cannot name is flagged.
check("a transport error is unnamed", R.unnamed_error({"_transport_error": "EOF"}) is not None)
check("State C without a code is unnamed", R.unnamed_error({"state": "C"}) is not None)
check("State C with a code is named", R.unnamed_error({"state": "C", "error": "x"}) is None)


class Canned:
    """The MCP calls run_locale makes, answered with the shapes the server emits."""

    def __init__(self):
        self.tracks = [{"id": 0, "name": "Inst 1", "type": "software_instrument", "automationMode": "off"},
                       {"id": 1, "name": "Audio 1", "type": "audio", "automationMode": "off"},
                       {"id": 2, "name": "MIDI 3", "type": "external_midi", "automationMode": "off"}]
        self.inserted = False

    def resource(self, uri):
        if uri == "logic://tracks":
            return {"data": [dict(t) for t in self.tracks]}
        return {"data": {"filePath": "/Users/x/Music/Logic/lpm-locale-campaign.logicx"}}

    def tool(self, name, command, params=None):
        params = params or {}
        if command == "create_instrument":
            return dict(family, observed_track_name="Inst 1")
        if command == "create_audio":
            return dict(strip, observed_track_name="Audio 1")
        if command == "create_external_midi":
            return dict(header, observed_track_name="MIDI 3")
        if command == "get_regions":
            return {"regions": [{"trackIndex": 0, "kind": "midi"}]}
        if command == "get_inventory":
            if self.inserted:
                return {"plugins": [{"insert": 1, "occupied": True, "plugin_id": R.COMPRESSOR_ID}]}
            return {"plugins": [{"insert": 1, "occupied": False}]}
        if command == "insert_verified":
            self.inserted = True
            return {"state": "A"}
        if command == "set_param_verified":
            return {"state": "A", "plugin_view_restore_attempted": True}
        if command == "set_automation":
            self.tracks[params["index"]]["automationMode"] = params["mode"]
            return {"state": "A", "observed_mode": params["mode"]}
        if command == "delete":
            return {"state": "A", "reconciled_modal_kind": "delete_confirm"}
        return {"state": "A"}


R.time.sleep = lambda seconds: None
# No case here sends osascript: the alert poll answers "no dialog" unless a case replaces it.
REAL_ACKNOWLEDGE_ALERT = R.acknowledge_alert
R.acknowledge_alert = lambda: None
# No case here moves the pointer either: run_main answers park_pointer with a fake, and the real one
# is driven below against a fake Quartz.
REAL_PARK_POINTER = R.park_pointer
with tempfile.TemporaryDirectory() as scratch:
    rows = R.Rows(os.path.join(scratch, "rows.jsonl"), "0" * 40, "/bin/LogicProMCP")
    R.run_locale(Canned(), rows, "de")
    with open(rows.path, encoding="utf-8") as handle:
        written = [json.loads(line) for line in handle]
got = {(r["set"], r["call"]): r["matched_via"] for r in rows.rows}
check("run_locale writes every row it makes to the JSONL", written == rows.rows)
check("run_locale gives every set a row", R.incomplete_locales(rows.rows, ["de"]) == {},
      R.incomplete_locales(rows.rows, ["de"]))
check("run_locale meets no unnamed error on answered calls", rows.unnamed == [], rows.unnamed)
expect("the canned de delete is the set or the Delete prefix",
       got.get(("deleteTracksPrimaryButton", "delete")), "set_or_fallback:Delete_prefix")
expect("the canned external MIDI header is the fallback",
       got.get(("inspectorChannelStripHelpPrefix", "create_external_midi")), "fallback:observed_header")
expect("the canned touch readback is the set",
       got.get(("automationModeTouch", "logic://tracks after set_automation:touch")), "set")
expect("the canned Controls-view switch is the set",
       got.get(("pluginWindowControlsViewMenuItem", "set_param_verified")), "set")
check("every row carries head_sha and binary",
      all(r["head_sha"] == "0" * 40 and r["binary"] == "/bin/LogicProMCP" for r in rows.rows))

# The row-count check refuses a locale that is short.
short = [r for r in rows.rows if r["set"] != "regionKindMidi"]
incomplete = R.incomplete_locales(short, ["de"])
check("a locale missing one set's rows is refused",
      incomplete.get("de", {}).get("missing_sets") == ["regionKindMidi"], incomplete)
check("a locale with zero rows is refused",
      R.incomplete_locales(rows.rows, ["de", "ko"]).get("ko") == {"rows": 0,
                                                                  "missing_sets": list(R.SETS)})
padded = short + [dict(short[0])]
check("padding with a duplicate row does not stand in for a missing set",
      "de" in R.incomplete_locales(padded, ["de"]))

# The runner refuses to start without the caller's lock.
saved = os.environ.pop("LPM_LIVE_LOCK", None)
try:
    try:
        R.refuse_without_lock()
        check("an unset LPM_LIVE_LOCK is refused", False)
    except SystemExit:
        check("an unset LPM_LIVE_LOCK is refused", True)
    os.environ["LPM_LIVE_LOCK"] = os.path.join(tempfile.gettempdir(), "lpm-904-no-such-lock")
    try:
        R.refuse_without_lock()
        check("an LPM_LIVE_LOCK naming no file is refused", False)
    except SystemExit:
        check("an LPM_LIVE_LOCK naming no file is refused", True)
finally:
    os.environ.pop("LPM_LIVE_LOCK", None)
    if saved is not None:
        os.environ["LPM_LIVE_LOCK"] = saved

# main's exit code agrees with the evidence document (R1-904-02). The instruments that touch the
# screen are replaced; the records they leave have the shapes evidence.py writes, and the verdict is
# evidence.py's own `summarize` and `is_clean`, not a copy of them. Every product-side condition the
# runner checks is met in each scenario, so the exit code can only move with the evidence.
E = R.E
L993 = R.L993


class RunEvidence(E.Evidence):
    """E.Evidence with the screen instruments answered by the scenario; records and verdict are real."""

    band = (0, 40, 240, 600)
    subject = "Tracks header"
    visual_passes = True

    def located_band(self, *selector):
        return (self.band, self.subject) if self.band else (None, None)

    def shot(self, tag, settle_region=None, window_title=None, window=None):
        path = os.path.join(self.dir, tag.replace("/", "_") + ".png")
        self.records.append({"kind": "capture", "tag": tag, "file": path, "settled": True,
                             "display": {"wholly_within": True}})
        return {"file": path, "settled": True}

    def visual(self, tag, before_file, after_file, region, expect_change, why,
               window_points=None, subject=None):
        self.records.append({"kind": "visual", "tag": tag, "region": list(region),
                             "subject": subject, "passed": self.visual_passes})
        return self.visual_passes

    def record_screen(self, seconds=90):
        return {"file": os.path.join(self.dir, "run.mov"), "seconds": seconds}

    def stop_recording(self, handle, settle=1.0):
        if handle:
            with open(handle["file"], "wb") as movie:
                movie.write(b"\0" * E.MIN_RECORDING_BYTES)
            self.recording(handle["file"])

    def write(self):
        self.records.append({"kind": "environment", "screen_locked": False})
        type(self).last_dir = self.dir
        type(self).last_records = self.records
        type(self).last = E.summarize(self.records)
        return type(self).last


RECORD_OPERATION = E.Driver._record_operation


class RecordingCanned(Canned):
    """Canned, with each call put in the document the way E.Driver puts it there."""

    def tool(self, name, command, params=None):
        body = Canned.tool(self, name, command, params)
        RECORD_OPERATION(self, name, command, params, body)
        return body

    def close(self):
        pass


class UnnamedAudioCanned(RecordingCanned):
    """RecordingCanned, except create_audio answers a State C with no error code.

    That is the change the runner's named-row check names as its own mutation: the reply is one the
    classifier cannot name, and nothing else about the run is disturbed.
    """

    def tool(self, name, command, params=None):
        if command == "create_audio":
            body = {"state": "C"}
            RECORD_OPERATION(self, name, command, params, body)
            return body
        return RecordingCanned.tool(self, name, command, params)


#: Every call `fake_park` answered in the latest run_main, numbered from 1.
PARKS = []


def fake_park():
    """park_pointer without Quartz: counts itself, and its payload names which call it was."""
    PARKS.append(len(PARKS) + 1)
    return {"from": [0, 0], "to": [PARKS[-1]] * 2, "after": [PARKS[-1]] * 2, "parked": True,
            "why": None}


def run_main(scenario, driver=RecordingCanned, acknowledge=lambda: None, park=fake_park):
    """main()'s exit code, evidence summary, check records and the runner's own summary JSON for one
    `scenario`, `driver`, alert poll `acknowledge` (by default: no dialog, and no osascript) and
    pointer park `park` (by default `fake_park`: no Quartz, and the pointer never moves)."""
    title = lambda code: f"{L993.FIXTURE_NAME} - {code}"  # noqa: E731
    saved = {(E, "Evidence"): E.Evidence, (E, "Driver"): E.Driver, (E, "have_tools"): E.have_tools,
             (E, "blocking_modal"): E.blocking_modal, (E, "REPO"): E.REPO, (E, "BIN"): E.BIN,
             (L993, "switch_to"): L993.switch_to, (L993, "language_setting"): L993.language_setting,
             (L993, "window_names"): L993.window_names, (R, "acknowledge_alert"): R.acknowledge_alert,
             (R, "park_pointer"): R.park_pointer}
    saved_env = {k: os.environ.get(k) for k in ("LPM_LIVE_LOCK", "LPM_EVIDENCE_ROOT", "LPM_BINARY")}
    try:
        with tempfile.TemporaryDirectory() as scratch:
            lock, binary = os.path.join(scratch, "lock"), os.path.join(scratch, "LogicProMCP")
            for path in (lock, binary):
                open(path, "w").close()
            os.environ.update(LPM_LIVE_LOCK=lock, LPM_EVIDENCE_ROOT=scratch, LPM_BINARY=binary)
            E.Evidence = type("Scenario", (RunEvidence,),
                              dict(scenario, last=None, last_records=None, last_dir=None))
            E.Driver, E.have_tools, E.blocking_modal = driver, lambda: [], lambda: None
            L993.switch_to = lambda code, force=False: {"arrange_window": title(code),
                                                         "language_setting": [L993.CODES[code]]}
            L993.language_setting = lambda: [L993.CODES[R.RESTORE]]
            L993.window_names = lambda: [title(R.RESTORE)]
            R.acknowledge_alert, R.park_pointer = acknowledge, park
            del PARKS[:]
            del R.ACKNOWLEDGED_ALERTS[:]  # a module list, like SYSTEM_EVENTS_RESTARTS: one run each
            with contextlib.redirect_stdout(io.StringIO()):  # main prints every row
                code = R.main(["live_904", os.path.dirname(HERE), "0" * 40, "de"])
            runner = None
            if E.Evidence.last_dir:
                with open(os.path.join(E.Evidence.last_dir, "live_904_labelset_summary.json"),
                          encoding="utf-8") as handle:
                    runner = json.load(handle)
            return code, E.Evidence.last, E.Evidence.last_records or [], runner
    finally:
        del R.ACKNOWLEDGED_ALERTS[:]
        for (owner, attr), value in saved.items():
            setattr(owner, attr, value)
        for key, value in saved_env.items():
            os.environ.pop(key, None)
            if value is not None:
                os.environ[key] = value


code, summary, records, runner = run_main({})
check("a run whose evidence earns a recording, a capture and a visual with a subject is clean",
      E.is_clean(summary), summary)
expect("main exits 0 when the rows are complete and the evidence is clean", code, 0)
expect("a run where no alert appeared writes an empty acknowledged_alerts to the summary",
       (runner or {}).get("acknowledged_alerts"), [])
BASELINE_CODE = code


def parked_note(records, tag):
    """The payload of each `tag` note, and the tag of the record right after the first one."""
    at = [i for i, r in enumerate(records) if r.get("kind") == "observation" and r.get("tag") == tag]
    after = records[at[0] + 1].get("tag") if at and at[0] + 1 < len(records) else None
    return [records[i].get("payload") for i in at], after


expect("a clean run parks the pointer exactly twice", PARKS, [1, 2])
expect("the first park is noted with its payload, and the before shot is the next record",
       parked_note(records, "904/pointer-parked-before-shot"),
       ([{"from": [0, 0], "to": [1, 1], "after": [1, 1], "parked": True, "why": None}],
        "904/korean-fixture-before"))
expect("the second park is noted with its payload, and the after shot is the next record",
       parked_note(records, "904/pointer-parked-before-after-shot"),
       ([{"from": [0, 0], "to": [2, 2], "after": [2, 2], "parked": True, "why": None}],
        "904/korean-fixture-after"))
code, summary, records, _ = run_main({"visual_passes": False})
check("a failed visual leaves the evidence unclean", summary and not E.is_clean(summary), summary)
expect("main exits 1 when the evidence is unclean though every row is complete", code, 1)
code, summary, records, _ = run_main({"band": None})
check("a band that does not resolve records no visual", summary and summary["visual_assertions"] == 0,
      summary)
expect("main exits 1 when no visual was earned", code, 1)
expect("a run that takes no shot parks nothing", PARKS, [])

# The only fault is a reply the classifier cannot name: every row is present and every screen
# instrument passes, so the named-row check alone must hold main's exit code at 1.
NAMED_ROW_TAG = "904/every-requested-language-has-a-named-row-for-every-set"
code, summary, records, _ = run_main({}, driver=UnnamedAudioCanned)
checks = [r for r in records if r.get("kind") == "check"]
named = [r for r in checks if r.get("tag") == NAMED_ROW_TAG]
others = [r for r in checks if r.get("tag") != NAMED_ROW_TAG]
expect("main exits 1 when a reply the classifier cannot name is the only fault", code, 1)
check("the named-row check is recorded false when a reply the classifier cannot name is the only fault",
      len(named) == 1 and named[0].get("passed") is False
      and bool((named[0].get("observed") or {}).get("unnamed_errors")), named)
check("a reply the classifier cannot name is the only fault: every other check passes",
      bool(others) and all(r.get("passed") is True for r in others),
      [(r.get("tag"), r.get("passed")) for r in others])

# Logic's one-button Write warning (measured 2026-09-30: left open, the discard-quit crashed Logic).
# The poll is faked: it finds a dialog only on the call right after a set_automation that asked for
# write, and counts itself; the driver counts the set_automation calls it answered, in the same run.


class UnobservedReadCanned(RecordingCanned):
    """RecordingCanned, except the first read request answers without `observed_mode`, so run_locale
    toggles the view back and asks for read a second time."""

    def __init__(self):
        RecordingCanned.__init__(self)
        self.reads = 0

    def tool(self, name, command, params=None):
        if command == "set_automation" and (params or {}).get("mode") == "read":
            self.reads += 1
            if self.reads == 1:
                body = {"state": "A"}
                RECORD_OPERATION(self, name, command, params, body)
                return body
        return RecordingCanned.tool(self, name, command, params)


def alert_run(base, answer=None):
    """main() with an alert poll that finds a dialog only right after a Write request, and answers
    `answer` (by default a press of "b" with text "t") for it."""
    answer = answer or {"button": "b", "text": "t"}
    seen = {"last": None, "set_automation": 0, "polls": 0}

    class Driver(base):
        def tool(self, name, command, params=None):
            seen["last"] = (command, (params or {}).get("mode"))
            seen["set_automation"] += command == "set_automation"
            return base.tool(self, name, command, params)

    def poll():
        seen["polls"] += 1
        return dict(answer) if seen["last"] == ("set_automation", "write") else None

    code, _, _, runner = run_main({}, driver=Driver, acknowledge=poll)
    return code, runner, seen


code, runner, seen = alert_run(RecordingCanned)
expect("the alert acknowledged after set_automation:write is the one entry in acknowledged_alerts",
       (runner or {}).get("acknowledged_alerts"),
       [{"locale": "de", "call": "set_automation:write", "button": "b", "text": "t"}])
expect("an acknowledged alert does not move main's exit code", (code, BASELINE_CODE), (0, 0))
check("the alert poll runs once for every set_automation call the driver answered",
      seen["polls"] == seen["set_automation"] == len(R.AUTOMATION_MODES), seen)
code, runner, seen = alert_run(UnobservedReadCanned)
check("the second read after the extra toggle_view is polled too: once per set_automation call",
      seen["polls"] == seen["set_automation"] == len(R.AUTOMATION_MODES) + 1, seen)
code, runner, seen = alert_run(RecordingCanned, {"button": "b", "text": "t", "unreadable_polls": 1,
                                                 "unreadable_why": ["no_reply"]})
expect("a press that came after an unread poll reaches the summary with both",
       (runner or {}).get("acknowledged_alerts"),
       [{"locale": "de", "call": "set_automation:write", "button": "b", "text": "t",
         "unreadable_polls": 1, "unreadable_why": ["no_reply"]}])

# acknowledge_alert itself, with osascript answered from a list: a press, no dialog, and a poll
# osascript could not read, which is not a poll that saw nothing.


class Clock:
    """A clock that moves only when slept on, so the poll's deadline is counted, not timed."""

    def __init__(self):
        self.now = 0.0

    def monotonic(self):
        return self.now

    def sleep(self, seconds):
        self.now += seconds


def poll_with(replies, wait=0.0):
    """REAL_ACKNOWLEDGE_ALERT's answer and the scripts it sent, osascript answering `replies`."""
    saved = (L993.osa, R.ALERT_WAIT, R.time)
    answers, sent = iter(replies), []

    def osa(script, timeout=20, deadline=None):
        sent.append(script)
        return next(answers, "none")

    L993.osa, R.ALERT_WAIT, R.time = osa, wait, Clock()
    try:
        return REAL_ACKNOWLEDGE_ALERT(), sent
    finally:
        L993.osa, R.ALERT_WAIT, R.time = saved


expect("a pressed dialog answers its button and text",
       poll_with(["pressed\nb\nt"])[0], {"button": "b", "text": "t"})
expect("a pressed dialog's text keeps its own line breaks",
       poll_with(["pressed\nb\nline 1\nline 2"])[0], {"button": "b", "text": "line 1\nline 2"})
expect("a pressed dialog with an empty name and text is still a press",
       poll_with(["pressed"])[0], {"button": "", "text": ""})
expect("no dialog is None", poll_with(["none"])[0], None)
expect("an unreadable poll is recorded, not read as no dialog",
       poll_with([None])[0],
       {"button": None, "text": None, "unreadable_polls": 1, "unreadable_why": ["no_reply"]})
expect("an unreadable poll before a press is kept beside the press, not dropped by it",
       poll_with([None, "pressed\nb\nt"], wait=R.ALERT_POLL * 4)[0],
       {"button": "b", "text": "t", "unreadable_polls": 1, "unreadable_why": ["no_reply"]})
expect("a dialog whose default button could not be read is not a press, and its error is kept",
       poll_with(["unreadable\n-25204"])[0], {"button": None, "text": None, "unreadable_polls": 1,
                                              "unreadable_why": ["AXDefaultButton:-25204"]})
got, sent = poll_with(["none", "pressed\nb\nt"], wait=R.ALERT_POLL * 4)
check("a dialog that appears on a later poll is pressed", got == {"button": "b", "text": "t"}
      and len(sent) == 2, (got, len(sent)))
got, sent = poll_with([], wait=R.ALERT_POLL * 4)
check("polls that never see a dialog stop at the deadline: one at the start and one per step",
      got is None and len(sent) == 5, (got, len(sent)))
literals = set(re.findall(r'"([^"]*)"', R.ACKNOWLEDGE_SCRIPT))
check("the alert script names no UI label, only processes, AX names and its own reply tokens",
      literals <= {"System Events", "Logic Pro", "AXDialog", "AXDefaultButton", "pressed", "none",
                   "unreadable", ""},
      sorted(literals))
# The script's own branches, read as text: osascript is not run here.
SCRIPT = R.ACKNOWLEDGE_SCRIPT
default_read = [block for block in re.findall(r"try\n(.*?)end try", SCRIPT, re.S)
                if 'attribute "AXDefaultButton"' in block]
check("the alert script answers an AXDefaultButton read error as unreadable with its number, and "
      "that answer comes before the click",
      len(default_read) == 1
      and re.search(r'on error number (\w+)\n\s*return "unreadable" & linefeed & \1\n', default_read[0])
      and SCRIPT.index('return "unreadable"') < SCRIPT.index("click b"), default_read)
_lines = SCRIPT.split("\n")
_guard = [i for i, line in enumerate(_lines) if line.strip() == "if isDefault then"]
_end = next((j for j in range(_guard[0] + 1, len(_lines))
             if _lines[j].startswith(_lines[_guard[0]][:len(_lines[_guard[0]]) - len(_lines[_guard[0]].lstrip())] + "end if")),
            None) if len(_guard) == 1 else None
_clicks = [i for i, line in enumerate(_lines) if "click " in line]
check("the alert script's one click sits inside the `if isDefault then` block, so no other condition "
      "can press a dialog (review R3: `if true then` passed every earlier check)",
      len(_guard) == 1 and _end is not None and len(_clicks) == 1 and _guard[0] < _clicks[0] < _end,
      (_guard, _end, _clicks))
check("the alert script clicks only in a dialog with one button, through a default button named as "
      "that one button",
      "(count of buttons of d) is 1" in SCRIPT
      and "(name of b as string) is (name of button 1 of d as string)" in SCRIPT
      and SCRIPT.index("(count of buttons of d) is 1") < SCRIPT.index("click b"))

# The watch's budget, with the real L993.osa between acknowledge_alert and a faked subprocess.run.
# One Clock serves both modules, and the time a probe takes is what the fake adds to it.


def watch_with(run):
    """REAL_ACKNOWLEDGE_ALERT's answer, each (program, timeout) subprocess.run was given, the clock
    when it returned and the System Events restarts recorded, with subprocess.run answered by
    `run(argv, timeout, clock)`."""
    clock, calls = Clock(), []
    saved = (L993.subprocess, L993.time, R.time)

    def fake_run(argv, timeout=None, **_):
        calls.append((os.path.basename(argv[0]), timeout))
        return run(argv, timeout, clock)

    L993.subprocess = types.SimpleNamespace(run=fake_run, TimeoutExpired=subprocess.TimeoutExpired)
    L993.time = R.time = clock
    del L993.SYSTEM_EVENTS_RESTARTS[:]
    try:
        try:
            got = REAL_ACKNOWLEDGE_ALERT()
        except Exception as error:  # a FAIL line, not a crash that hides the cases after it
            got = repr(error)
        return got, calls, clock.now, list(L993.SYSTEM_EVENTS_RESTARTS)
    finally:
        L993.subprocess, L993.time, R.time = saved
        del L993.SYSTEM_EVENTS_RESTARTS[:]


def blocked(argv, timeout, clock):
    """An osascript that never answers: subprocess.run kills it once its timeout has run out."""
    clock.now += timeout
    raise subprocess.TimeoutExpired(argv, timeout)


def late_press(argv, timeout, clock):
    """A probe that does not keep to its timeout and reports a press three seconds later."""
    clock.now += 3.0
    return subprocess.CompletedProcess(argv, 0, "pressed\nb\nt\n", "")


def refusing(argv, timeout, clock):
    """A System Events that refuses GUI scripting (-25211) after 1.5 s; the kill answers at once."""
    if argv[0].endswith("killall"):
        return subprocess.CompletedProcess(argv, 0, "", "")
    clock.now += 1.5
    return subprocess.CompletedProcess(argv, 1, "", "execution error: (-25211)")


UNREAD = {"button": None, "text": None, "unreadable_polls": 1}
got, calls, now, _ = watch_with(blocked)
check("a probe that blocks is cut at the deadline: its osascript is given the watch's budget, not "
      "20 s, and the watch ends at ALERT_WAIT with the poll counted",
      calls == [("osascript", R.ALERT_WAIT)] and now == R.ALERT_WAIT
      and got == dict(UNREAD, unreadable_why=["no_reply"]), (got, calls, now))
got, calls, now, _ = watch_with(late_press)
expect("a press reported after the deadline is not taken as a press, and is kept as late",
       got, dict(UNREAD, unreadable_why=["after_deadline:pressed"]))
got, calls, now, restarts = watch_with(refusing)
check("a System Events restart inside the watch ends at the deadline: the kill gets the 0.5 s left, "
      "the relaunch wait is cut to it, and no retry starts",
      calls == [("osascript", R.ALERT_WAIT), ("killall", R.ALERT_WAIT - 1.5)]
      and now == R.ALERT_WAIT and len(restarts) == 1
      and got == dict(UNREAD, unreadable_why=["no_reply"]), (got, calls, now, restarts))


def osa_reading(readings):
    """L993.osa with a 2.0 s deadline, a clock that answers `readings` in order (the last repeats),
    an osascript refused with -25211 and a kill that answers at once: (calls, restarts)."""
    calls, reads = [], list(readings)
    saved = (L993.subprocess, L993.time)

    def fake_run(argv, timeout=None, **_):
        calls.append((os.path.basename(argv[0]), None if timeout is None else round(timeout, 6)))
        if argv[0].endswith("killall"):
            return subprocess.CompletedProcess(argv, 0, "", "")
        return subprocess.CompletedProcess(argv, 1, "", "execution error: (-25211)")

    L993.subprocess = types.SimpleNamespace(run=fake_run, TimeoutExpired=subprocess.TimeoutExpired)
    L993.time = types.SimpleNamespace(monotonic=lambda: reads.pop(0) if len(reads) > 1 else reads[0],
                                      sleep=lambda seconds: None)
    del L993.SYSTEM_EVENTS_RESTARTS[:]
    try:
        L993.osa("x", deadline=2.0)
        return calls, list(L993.SYSTEM_EVENTS_RESTARTS)
    finally:
        L993.subprocess, L993.time = saved
        del L993.SYSTEM_EVENTS_RESTARTS[:]


def osa_bookkeeping(osascript_ends, bookkeeping):
    """L993.osa with a 2.0 s deadline on one clock: the refused osascript ends at `osascript_ends`,
    building the restart record advances the clock by `bookkeeping`, and each subprocess.run records
    the clock at the moment it is invoked: (calls as (program, timeout, clock), restarts)."""
    clock, calls = Clock(), []
    saved = (L993.subprocess, L993.time, L993.datetime)

    def fake_run(argv, timeout=None, **_):
        calls.append((os.path.basename(argv[0]), None if timeout is None else round(timeout, 6),
                      round(clock.now, 6)))
        if argv[0].endswith("killall"):
            return subprocess.CompletedProcess(argv, 0, "", "")
        clock.now = osascript_ends
        return subprocess.CompletedProcess(argv, 1, "", "execution error: (-25211)")

    class FakeDatetime:
        @staticmethod
        def now():
            clock.now += bookkeeping
            return datetime.datetime(2026, 10, 2, tzinfo=datetime.timezone.utc)

    L993.subprocess = types.SimpleNamespace(run=fake_run, TimeoutExpired=subprocess.TimeoutExpired)
    L993.time = clock
    L993.datetime = types.SimpleNamespace(datetime=FakeDatetime)
    del L993.SYSTEM_EVENTS_RESTARTS[:]
    try:
        L993.osa("x", deadline=clock.now + 2.0)
        return calls, list(L993.SYSTEM_EVENTS_RESTARTS)
    finally:
        L993.subprocess, L993.time, L993.datetime = saved
        del L993.SYSTEM_EVENTS_RESTARTS[:]


# Review R3 of #1081: the budget was read before the restart record was built; building it took the
# clock from 1.9 to 2.1 and the kill started after the deadline with the 0.1 s read before. The
# kill's own invocation time is what is checked: it must be inside the deadline, or not happen.
calls, restarts = osa_bookkeeping(1.9, 0.2)
check("a restart whose record takes the clock past the deadline launches no kill and records nothing",
      [c[0] for c in calls] == ["osascript"] and restarts == [], (calls, restarts))
calls, restarts = osa_bookkeeping(1.5, 0.2)
check("a restart inside the deadline launches the kill before it, given the time left at its launch",
      [c[0] for c in calls] == ["osascript", "killall"] and calls[1][2] < 2.0
      and abs(calls[1][1] + calls[1][2] - 2.0) < 1e-6 and len(restarts) == 1, (calls, restarts))

# Review R2 of #1081: the clock read 1.9 when the restart was allowed and 2.1 when the kill launched,
# and the kill was given -0.1. The budget is read once and that reading is the one the kill gets.
calls, restarts = osa_reading([0.0, 1.9, 2.1])
expect("a restart allowed at 1.9 gives the kill the 0.1 s it was allowed, never a budget read later",
       calls, [("osascript", 2.0), ("killall", 0.1)])
calls, restarts = osa_reading([0.0, 2.1])
check("a restart whose budget has run out when it is read is neither recorded nor launched",
      calls == [("osascript", 2.0)] and restarts == [], (calls, restarts))


def default_osa(answers):
    """L993.osa called as its other callers call it: no deadline, subprocess.run faked, and a `time`
    with no clock, so reading one raises."""
    calls, sleeps, queue = [], [], list(answers)
    saved = (L993.subprocess, L993.time)

    def fake_run(argv, timeout=None, **_):
        calls.append((os.path.basename(argv[0]), timeout))
        if argv[0].endswith("killall"):
            return subprocess.CompletedProcess(argv, 0, "", "")
        return subprocess.CompletedProcess(argv, *queue.pop(0))

    L993.subprocess = types.SimpleNamespace(run=fake_run, TimeoutExpired=subprocess.TimeoutExpired)
    L993.time = types.SimpleNamespace(sleep=sleeps.append)
    try:
        try:
            got = L993.osa("x")
        except Exception as error:
            got = repr(error)
        return got, calls, sleeps
    finally:
        L993.subprocess, L993.time = saved
        del L993.SYSTEM_EVENTS_RESTARTS[:]


got, calls, sleeps = default_osa([(1, "", "execution error: (-25211)"), (0, "ok\n", "")])
check("L993.osa without a deadline is unchanged for its other callers: 20 s per osascript, a kill "
      "with no timeout, the whole relaunch wait, and no clock read",
      got == "ok" and calls == [("osascript", 20), ("killall", None), ("osascript", 20)]
      and sleeps == [L993.SYSTEM_EVENTS_RELAUNCH_WAIT], (got, calls, sleeps))

# pick_park_point: every rect is [x, y, w, h] in global display points, as CGDisplayBounds and
# kCGWindowBounds give them.
MAIN = [0, 0, 1920, 1080]
LEFT, RIGHT = [-1920, 0, 1920, 1080], [1920, 0, 1920, 1080]
ABOVE, BELOW = [0, -1080, 1920, 1080], [0, 1080, 1920, 1080]
FAR_RIGHT = [3840, 0, 1920, 1080]
X6_MAIN_WINDOW = [0, 30, 1920, 1050]
SOME_WINDOW = [100, 100, 800, 600]

expect("a display no Logic window overlaps is chosen, at its centre",
       R.pick_park_point([MAIN, RIGHT], [SOME_WINDOW]), [2880, 540])
expect("a window that only touches a display's edge does not hold it (the X6 shape: the main window "
       "[0,30,1920,1050] between two neighbours)",
       R.pick_park_point([MAIN, LEFT, RIGHT], [X6_MAIN_WINDOW]), [-960, 540])
for side, display in (("left of", LEFT), ("right of", RIGHT), ("above", ABOVE), ("below", BELOW)):
    expect(f"a window filling its display does not hold the display {side} it, which it only touches",
           R.pick_park_point([MAIN, display], [MAIN]), [display[0] + 960, display[1] + 540])
expect("a window straddling two displays holds both",
       R.pick_park_point([MAIN, RIGHT, FAR_RIGHT], [[1900, 100, 40, 40]]), [4800, 540])
expect("every display holding a Logic window is None",
       R.pick_park_point([MAIN, RIGHT], [SOME_WINDOW, [2000, 100, 800, 600]]), None)
expect("no display at all is None", R.pick_park_point([], []), None)
expect("the first free display wins over a later one",
       R.pick_park_point([MAIN, RIGHT, LEFT], [SOME_WINDOW]), [2880, 540])


# park_pointer against a fake Quartz: nothing here reads or moves the real pointer.


class FakeQuartz:
    """The Quartz calls park_pointer makes, answered from a scene; every posted event is kept.

    `lands` maps the posted target to where the pointer reads back; `raises` names the call that
    raises. `log` is the order of pointer reads, posts and settles.
    """

    kCGWindowListOptionOnScreenOnly, kCGNullWindowID, kCGWindowBounds = 1, 0, "kCGWindowBounds"
    kCGHIDEventTap, kCGSessionEventTap = 0, 1
    kCGEventMouseMoved, kCGMouseButtonLeft = 5, 0

    def __init__(self, displays, windows, display_error=0, lands=lambda to: to, raises=None):
        self.displays, self.windows, self.display_error = displays, windows, display_error
        self.lands, self.raises, self.pointer = lands, raises, (862, 571)
        self.log, self.posted = [], []

    def _call(self, name):
        if self.raises == name:
            raise RuntimeError(f"{name} failed")

    def CGEventCreate(self, source):
        self._call("CGEventCreate")
        return "current"

    def CGEventGetLocation(self, event):
        self.log.append("read")
        return types.SimpleNamespace(x=self.pointer[0], y=self.pointer[1])

    def CGGetActiveDisplayList(self, most, ids, count):
        return self.display_error, tuple(range(1, len(self.displays) + 1)), len(self.displays)

    def CGDisplayBounds(self, display):
        x, y, w, h = self.displays[display - 1]
        return types.SimpleNamespace(origin=types.SimpleNamespace(x=x, y=y),
                                     size=types.SimpleNamespace(width=w, height=h))

    def CGWindowListCopyWindowInfo(self, option, relative):
        return self.windows

    def CGEventCreateMouseEvent(self, source, kind, point, button):
        return (kind, point, button)

    def CGEventPost(self, tap, event):
        self._call("CGEventPost")
        self.log.append("post")
        self.posted.append((tap,) + event)
        self.pointer = self.lands(event[1])


class Settle:
    """The runner's `time` for park_pointer: a settle is logged in order, never waited."""

    def __init__(self, fake):
        self.fake = fake

    def sleep(self, seconds):
        self.fake.log.append(("sleep", seconds))


def window_of(owner, rect=None):
    """A CoreGraphics window entry; no `rect` is a window whose bounds are missing."""
    window = {"kCGWindowOwnerName": owner}
    if rect:
        window["kCGWindowBounds"] = dict(zip(("X", "Y", "Width", "Height"), rect))
    return window


def park_with(fake):
    """REAL_PARK_POINTER's answer against `fake`, and what it raised, if it raised."""
    saved = R.time
    R.time = Settle(fake)
    try:
        return REAL_PARK_POINTER(fake), None
    except Exception as exc:  # noqa: BLE001 - a raise is what the checks below look for
        return None, exc
    finally:
        R.time = saved


def moved_nothing(got, raised, fake):
    """Whether park_pointer returned without posting anything, saying why."""
    return (raised is None and fake.posted == [] and got["parked"] is False and got["to"] is None
            and bool(got["why"]))


LOGIC_ON_MAIN = window_of("Logic Pro", X6_MAIN_WINDOW)
fake = FakeQuartz([MAIN, RIGHT], [LOGIC_ON_MAIN, window_of("Some Other App", RIGHT)])
got, raised = park_with(fake)
expect("the pointer is parked at the centre of the display no Logic window holds, and reads back there",
       (got, raised), ({"from": [862, 571], "to": [2880, 540], "after": [2880, 540], "parked": True,
                        "why": None}, None))
expect("one mouse-moved event is posted, through the HID tap, and nothing else",
       fake.posted, [(0, 5, (2880, 540), 0)])
expect("the pointer is read back PARK_SETTLE seconds after the post",
       fake.log, ["read", "post", ("sleep", R.PARK_SETTLE), "read"])
fake = FakeQuartz([MAIN, RIGHT], [LOGIC_ON_MAIN, window_of("Some Other App")])
got, raised = park_with(fake)
check("another app's window with no bounds does not stop the park",
      raised is None and got["parked"] and got["to"] == [2880, 540], (got, raised))
fake = FakeQuartz([MAIN, RIGHT], [window_of("Logic Pro", MAIN)])
got, raised = park_with(fake)
check("a Logic window owned under the Korean no-break-space name still holds its display",
      raised is None and got["to"] == [2880, 540], (got, raised))
fake = FakeQuartz([MAIN, RIGHT], [], display_error=1001)
got, raised = park_with(fake)
check("an unreadable display list posts nothing and says why", moved_nothing(got, raised, fake),
      (got, raised, fake.posted))
fake = FakeQuartz([MAIN, RIGHT], None)
got, raised = park_with(fake)
check("an unreadable window list posts nothing and says why, not read as no Logic window",
      moved_nothing(got, raised, fake), (got, raised, fake.posted))
fake = FakeQuartz([MAIN, RIGHT], [window_of("Logic Pro")])
got, raised = park_with(fake)
check("a Logic window with no bounds posts nothing and says why", moved_nothing(got, raised, fake),
      (got, raised, fake.posted))
fake = FakeQuartz([MAIN, RIGHT], [LOGIC_ON_MAIN, window_of("Logic Pro", [2000, 100, 800, 600])])
got, raised = park_with(fake)
check("every display holding a Logic window posts nothing and says why",
      moved_nothing(got, raised, fake), (got, raised, fake.posted))
fake = FakeQuartz([MAIN, RIGHT], [LOGIC_ON_MAIN], lands=lambda to: (100, 100))
got, raised = park_with(fake)
check("a pointer that reads back off the target is not parked, and says why",
      raised is None and got["parked"] is False and got["after"] == [100, 100] and bool(got["why"])
      and len(fake.posted) == 1, (got, raised))
near = park_with(FakeQuartz([MAIN, RIGHT], [LOGIC_ON_MAIN], lands=lambda to: (to[0] + 1, to[1] - 1)))
off = park_with(FakeQuartz([MAIN, RIGHT], [LOGIC_ON_MAIN], lands=lambda to: (to[0] + 2, to[1])))
check("a readback within 1 pt of the target is parked, and 2 pt off is not",
      near[0]["parked"] is True and off[0]["parked"] is False, (near, off))
fake = FakeQuartz([MAIN, RIGHT], [LOGIC_ON_MAIN], raises="CGEventCreate")
got, raised = park_with(fake)
check("a Quartz call that raises before the post never raises, posts nothing and names the error",
      raised is None and fake.posted == [] and got["parked"] is False
      and got["why"] == repr(RuntimeError("CGEventCreate failed")), (got, raised))
fake = FakeQuartz([MAIN, RIGHT], [LOGIC_ON_MAIN], raises="CGEventPost")
got, raised = park_with(fake)
check("a post that raises never raises, is not parked and names the error",
      raised is None and got["parked"] is False and got["to"] == [2880, 540]
      and got["why"] == repr(RuntimeError("CGEventPost failed")), (got, raised))

print(f"\n{'FAILED' if failed else 'passed'}: {failed} failure(s)")
sys.exit(1 if failed else 0)
