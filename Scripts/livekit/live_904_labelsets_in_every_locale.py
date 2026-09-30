#!/usr/bin/env python3
"""Live reading of every #904 LabelSet in every Logic language: matched through the set, or a fallback.

Usage:  LPM_LIVE_LOCK=<existing lock file> LPM_EVIDENCE_ROOT=/abs/path/outside/repo \
        /usr/bin/python3 live_904_labelsets_in_every_locale.py <worktree> <full-40-char-head-sha> \
        [lproj ...]
        (default lprojs: de en es fr it ja ko pt zh_CN zh_TW; the binary is $LPM_BINARY, else
        <worktree>/.build/release/LogicProMCP, as live_883 chooses it)

WHAT IS ASKED
-------------
#904 filled sixteen LabelSets in `AXLocalePolicy.swift` with Apple's own per-locale values. A value
that is in a set is not yet a value Logic was seen to match. For each language this run opens the
locale-campaign fixture (live_993's `switch_to`, which quits without saving and reads the language
back from Apple's `Tracks` window-title suffix), drives the MCP calls that reach each set, and writes
one row per (set, locale, call) saying HOW the reply was reached:

    set                         the reply can only have come from this set matching
    set_or_fallback:<name>      the set, or the named fallback beside it; the reply cannot say which
    fallback:<name>             the named fallback answered, not the set
    not_reached                 the call did not get as far as the set (or its fixture was absent)
    indistinguishable           the reply is the same whichever path answered
    refused                     the set was reached and did not match
    not_reachable_via_mcp       no MCP call reaches this set; a Limit, with the reason in the row

WHERE EACH READING COMES FROM (Sources/LogicProMCP, read at this head)
--------------------------------------------------------------------
- deleteTracksPrimaryButton, `logic_tracks.delete` on a track `get_regions` shows holding a region
  (an empty track is deleted with no sheet). `reconciled_modal_kind == "delete_confirm"` needs the
  primary button, which is the set OR the English `hasPrefix("Delete ")` beside it, in EVERY
  language (Channels/AccessibilityChannel+ModalReconcile.swift:873-876). The reply carries the kind
  and no button title or match source: `deletePrimaryTitle` goes to the executor, not to the
  envelope (mergeReconcileExtras, :2237). So a German sheet whose button reads `Delete anything`
  answers exactly as the German set would, and the row is `set_or_fallback:Delete_prefix` in every
  language, never `set`. `unknown_sheet` is the sheet read without the button: refused.
- inspectorChannelStripHelpPrefix and midiEffectSlotHelpKeyword, `create_instrument`,
  `create_audio`, `create_external_midi`: `track_type_verification_source`
  (Channels/AccessibilityChannel+Tracks.swift:2192-2207). `inspector_channel_strip_instrument_family`
  is returned only when the MIDI-effect slot signal alone matched, on a strip found by the prefix
  (Accessibility/AXLogicProElements+Mixer.swift:927-954, :1006), so it proves both;
  `inspector_channel_strip` proves the prefix only; `observed_header` is the fallback.
- trackTypeExternalMIDI, `logic://tracks` after `create_external_midi`. The wire value is
  `external_midi` (State/StateModels.swift:54). It is not proof of this set alone: a name shaped
  `gm device <n>` or the trackTypeGMDevice set returns external MIDI BEFORE the counted sets are
  consulted (Accessibility/AXValueExtractors.swift:863-868), so the best this reply shows is
  `set_or_fallback:trackTypeGMDevice`, and `fallback:gm_device_name` when the name has that shape.
  `unknown` means more than one type set matched (:904-905): indistinguishable.
- automationModeRead / Touch / Write, `logic_navigate.toggle_view automation`, then
  `logic_tracks.set_automation` per mode. Two rows per mode: the reply's `observed_mode` is the
  readable-only reading (Server/LogicProServer.swift:384-389, Channels/MCUChannel.swift:1017), absent
  when unreadable; `logic://tracks`' `automationMode` after `refresh_cache` falls back to `off` when
  unreadable (AXValueExtractors.swift:517): `fallback:unreadable_defaults_off`.
- pluginWindowControlsViewMenuItem, `insert_verified` a Compressor on the new audio track, then
  `set_param_verified compressor limiter_on` (a Controls-view boolean). `plugin_view_restore_attempted`
  is True only when the view was switched through the Controls item
  (HostParameters/ControlsViewBooleanParameterWriter.swift:349-399); False is the no-switch path
  (the window was already in Controls view): not_reached. `plugin_view_not_confirmed` with
  `plugin_view_switch_phase: item_not_found` is the set failing: refused.
- regionKindMidi, `logic_project.get_regions`: a region whose `kind` is `midi`
  (Channels/AccessibilityChannel+Regions.swift:170). No MIDI region in the fixture: not_reached.
  No region is created for it.
- trackContentExplicit, the same `get_regions` reply: an answered inventory is found through the
  explicit set OR the generic-content fallback (Regions.swift:198-208), so it is indistinguishable.
- undoMenuItemPrefix, pluginWindowSmartControlsControl, trackTypeGMDevice, trackHeadersDescription,
  automationModeOff: `not_reachable_via_mcp`, one Limit row per locale; the reason is in the row.

WHAT IS NOT JUDGED
------------------
Nothing is saved: every language reopens the fixture through a quit that discards, and Korean is
restored (and read back) in a `finally`. The run does not take the live lock; it refuses to start
unless LPM_LIVE_LOCK names an existing file, because the caller holds it. The exit code is 1 when a
requested locale has fewer rows than the set list (zero rows is never a pass), when a reply is one
the classifier cannot name (a transport failure, non-JSON text, an empty resource, State C with no
error code), when the Korean restore did not read back, or when the evidence document is not
`evidence.is_clean` -- which for this `ui` surface needs a recording, a capture and a visual
assertion with a subject, as live_993 earns them: a screen recording over the run, and the Korean
fixture's `Tracks header` band captured before the sweep (reopened discarding, so it is the fixture
as saved) and after the Korean restore, asserted unchanged because nothing was saved.
"""

import hashlib
import json
import os
import re
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import evidence as E  # noqa: E402
import live_993_plugin_root_menu_in_every_locale as L993  # noqa: E402

COVERS = [
    "Sources/LogicProMCP/Accessibility/AXLocalePolicy.swift",
]

DEFAULT_LPROJS = ("de", "en", "es", "fr", "it", "ja", "ko", "pt", "zh_CN", "zh_TW")
RESTORE = L993.RESTORE
COMPRESSOR_ID = "logic.stock.effect.compressor"
# Protocol values, not Logic UI words: the `logic_tracks` command that deletes
# (Dispatchers/TrackDispatcher.swift:181) and the wire value `AutomationMode.off` encodes to
# (State/StateModels.swift:94), which is what an unreadable header defaults to.
DELETE_COMMAND = "delete"
WIRE_AUTOMATION_OFF = "off"
AUTOMATION_MODES = {"automationModeRead": "read", "automationModeTouch": "touch",
                    "automationModeWrite": "write"}
#: AXValueExtractors.swift:863 -- the English track-name shape that answers external MIDI early.
GM_NAME = re.compile(r"^gm device\s+\d+$")

#: The sets no MCP call reaches, with the reason carried in each Limit row.
LIMITS = {
    "undoMenuItemPrefix": "read only through editUndoMenuPath when a verified insert rolls back a "
                          "plug-in mounted in the wrong slot (VerifiedPlugins.swift:4158); no call "
                          "triggers that on demand",
    "pluginWindowSmartControlsControl": "read in a docked Smart Controls pane "
                                        "(AXLogicProElements.swift:880); no toggle_view opens it",
    "trackTypeGMDevice": "needs a GM Device strip; MCP cannot create one",
    "trackHeadersDescription": "the structural check runs first (AXLogicProElements.swift:923) and "
                               "no reply says which check matched",
    "automationModeOff": "an `off` reading is also what an unreadable header defaults to "
                         "(AXValueExtractors.swift:517)",
}

#: Every set this branch changed the values of, and the order the rows are counted against.
SETS = ("deleteTracksPrimaryButton", "inspectorChannelStripHelpPrefix", "midiEffectSlotHelpKeyword",
        "trackTypeExternalMIDI", "automationModeRead", "automationModeTouch", "automationModeWrite",
        "pluginWindowControlsViewMenuItem", "regionKindMidi", "trackContentExplicit") + tuple(LIMITS)

OUTCOMES = ("set", "set_or_fallback", "fallback", "not_reached", "indistinguishable", "refused",
            "not_reachable_via_mcp")

#: The reply keys `classify` reads for each set, and the only keys an excerpt carries.
CONSUMED = {
    "deleteTracksPrimaryButton": ("reconciled_modal_kind",),
    "inspectorChannelStripHelpPrefix": ("track_type_verification_source",),
    "midiEffectSlotHelpKeyword": ("track_type_verification_source",),
    "trackTypeExternalMIDI": ("name", "type"),
    "pluginWindowControlsViewMenuItem": ("plugin_view_restore_attempted", "plugin_view_switch_phase",
                                         "error"),
    "automationModeRead": ("observed_mode", "automationMode"),
    "automationModeTouch": ("observed_mode", "automationMode"),
    "automationModeWrite": ("observed_mode", "automationMode"),
    "regionKindMidi": ("regions",),
    "trackContentExplicit": ("regions",),
}
EXCERPT_LIMIT = 400

#: The reply's own account of why it stopped, carried even when the classifier does not read them.
STOP_REASON_KEYS = ("state", "error", "reason", "reconciled_modal_observation",
                     "reconciled_modal_unreadable_reason", "reconciled_modal_unreadable_ax_status")


def _fallback(name):
    return f"fallback:{name}"


def _set_or_fallback(name):
    return f"set_or_fallback:{name}"


def _regions(reply):
    regions = reply.get("regions")
    return regions if isinstance(regions, list) else None


def classify(set_name, locale, call, reply):
    """How `reply` reached `set_name`: one of OUTCOMES, a fallback naming what answered.

    Pure: it reads only its arguments. A (set, call) pair it does not know, or a reply without the
    keys it reads, is `not_reached` -- never `set`. No outcome depends on `locale`: every fallback
    the product consults is consulted in every language.
    """
    if set_name in LIMITS:
        return "not_reachable_via_mcp"
    if not isinstance(reply, dict):
        return "not_reached"
    if set_name == "deleteTracksPrimaryButton" and call == DELETE_COMMAND:
        kind = reply.get("reconciled_modal_kind")
        if kind == "delete_confirm":
            # Not locale-dependent: the English prefix is consulted in every language, and the
            # reply names neither the button it matched nor which test matched it.
            return _set_or_fallback("Delete_prefix")
        return "refused" if kind == "unknown_sheet" else "not_reached"
    if set_name in ("inspectorChannelStripHelpPrefix", "midiEffectSlotHelpKeyword") \
            and call.startswith("create_"):
        if set_name == "midiEffectSlotHelpKeyword" and call != "create_instrument":
            return "not_reached"
        source = reply.get("track_type_verification_source")
        if source == "inspector_channel_strip_instrument_family":
            return "set"
        if source == "inspector_channel_strip":
            # The strip was found by the prefix and read as audio or external MIDI: on an
            # instrument track that is the MIDI-effect keyword reached and not matching.
            return "set" if set_name == "inspectorChannelStripHelpPrefix" else "refused"
        if source == "observed_header":
            return _fallback("observed_header")
        return "not_reached"
    if set_name == "trackTypeExternalMIDI" and call == "logic://tracks after create_external_midi":
        kind = reply.get("type")
        if kind == "external_midi":
            name = str(reply.get("name") or "").strip().lower()
            return _fallback("gm_device_name") if GM_NAME.match(name) \
                else _set_or_fallback("trackTypeGMDevice")
        if kind == "unknown":
            return "indistinguishable"
        return "refused" if isinstance(kind, str) else "not_reached"
    if set_name == "pluginWindowControlsViewMenuItem" and call == "set_param_verified":
        if reply.get("error") == "plugin_view_not_confirmed":
            phase = reply.get("plugin_view_switch_phase")
            if phase == "item_not_found":
                return "refused"
            if phase == "item_ambiguous":
                return "indistinguishable"
            if phase in ("item_not_enabled", "pick_performed_structure_never_confirmed"):
                return "set"
            return "not_reached"
        return "set" if reply.get("plugin_view_restore_attempted") is True else "not_reached"
    if set_name in AUTOMATION_MODES:
        mode = AUTOMATION_MODES[set_name]
        if call.startswith(f"set_automation:{mode}"):
            observed = reply.get("observed_mode")
            if observed == mode:
                return "set"
            return "indistinguishable" if observed is None and reply.get("state") == "B" \
                else "not_reached"
        if call.startswith(f"logic://tracks after set_automation:{mode}"):
            observed = reply.get("automationMode")
            if observed == mode:
                return "set"
            if observed == WIRE_AUTOMATION_OFF:
                return _fallback("unreadable_defaults_off")
            return "not_reached"
        return "not_reached"
    if set_name == "regionKindMidi" and call == "get_regions":
        regions = _regions(reply)
        return "set" if regions and any(isinstance(r, dict) and r.get("kind") == "midi"
                                        for r in regions) else "not_reached"
    if set_name == "trackContentExplicit" and call == "get_regions":
        return "indistinguishable" if _regions(reply) is not None else "not_reached"
    return "not_reached"


def excerpt(set_name, reply):
    """The consumed keys of `reply`, as JSON of at most EXCERPT_LIMIT characters."""
    if not isinstance(reply, dict):
        return json.dumps(str(reply), ensure_ascii=False)[:EXCERPT_LIMIT]
    kept = {}
    for key in CONSUMED.get(set_name, ()):
        if key not in reply:
            continue
        value = reply[key]
        if key == "regions" and isinstance(value, list):
            value = [r.get("kind") if isinstance(r, dict) else r for r in value]
        kept[key] = value
    # A reply that did not get as far as the set says why in these; they are the reply's own.
    for key in STOP_REASON_KEYS:
        if key in reply and key not in kept:
            kept[key] = reply[key]
    return json.dumps(kept, ensure_ascii=False, sort_keys=True)[:EXCERPT_LIMIT]


def unnamed_error(reply):
    """Why `reply` is a failure the classifier cannot name, or None when it is an answer."""
    if not isinstance(reply, dict):
        return f"reply is not an object: {type(reply).__name__}"
    if "_transport_error" in reply:
        return "transport error"
    if "_text" in reply:
        return "reply is not JSON"
    if not reply:
        return "empty reply"
    if reply.get("state") == "C" and not reply.get("error"):
        return "State C without an error code"
    return None


def incomplete_locales(rows, lprojs):
    """Locales with fewer rows than SETS, or missing a set: {lproj: {rows, missing_sets}}."""
    out = {}
    for lproj in lprojs:
        mine = [row for row in rows if row.get("locale") == lproj]
        present = {row.get("set") for row in mine}
        missing = [name for name in SETS if name not in present]
        if len(mine) < len(SETS) or missing:
            out[lproj] = {"rows": len(mine), "missing_sets": missing}
    return out


class Rows:
    """Appends each row to the JSONL as it is made, so a run that dies keeps what it read."""

    def __init__(self, path, head, binary):
        self.path, self.head, self.binary = path, head, binary
        self.rows, self.unnamed = [], []
        open(path, "w").close()

    def add(self, set_name, locale, call, reply, reason=None):
        row = {"set": set_name, "locale": locale, "call": call,
               "matched_via": classify(set_name, locale, call, reply),
               "raw_reply_excerpt": "" if set_name in LIMITS else excerpt(set_name, reply),
               "head_sha": self.head, "binary": self.binary}
        if reason:
            row["reason"] = reason
        failure = None if set_name in LIMITS else unnamed_error(reply)
        if failure:
            row["unnamed_error"] = failure
            self.unnamed.append({"set": set_name, "locale": locale, "call": call, "why": failure})
        self.rows.append(row)
        with open(self.path, "a", encoding="utf-8") as handle:
            handle.write(json.dumps(row, ensure_ascii=False) + "\n")
        print(json.dumps({k: row[k] for k in ("locale", "set", "call", "matched_via")},
                         ensure_ascii=False), flush=True)
        return row


def tracks(driver):
    driver.tool("logic_system", "refresh_cache", {})
    body = driver.resource("logic://tracks")
    return body, [t for t in (body.get("data") or []) if isinstance(t, dict)]


def track_named(rows, name):
    """The one track row carrying `name`, or None when none or several do."""
    found = [t for t in rows if name and t.get("name") == name]
    return found[0] if len(found) == 1 else None


#: Every alert `acknowledge_alert` answered, as {"locale", "call", "button", "text"}, so the summary
#: shows it; an entry whose button is None is a poll osascript could not read.
ACKNOWLEDGED_ALERTS = []
#: Seconds `acknowledge_alert` watches for the alert, and between its polls.
ALERT_WAIT, ALERT_POLL = 2.0, 0.25
#: Only a dialog with exactly one button is pressed, and only through its AXDefaultButton when that
#: is the one button: a save prompt (more than one button, or none AX can reach) is left alone.
ACKNOWLEDGE_SCRIPT = '''tell application "System Events" to tell process "Logic Pro"
  repeat with d in (windows whose subrole is "AXDialog")
    if (count of buttons of d) is 1 then
      set b to missing value
      try
        set candidate to value of attribute "AXDefaultButton" of d
        if (name of candidate as string) is (name of button 1 of d as string) then set b to candidate
      end try
      if b is not missing value then
        set t to ""
        try
          set t to (value of static text 1 of d) as string
        end try
        set n to name of b as string
        click b
        return "pressed" & linefeed & n & linefeed & t
      end if
    end if
  end repeat
  return "none"
end tell'''


def acknowledge_alert():
    """Press the default button of a Logic dialog with exactly one button, if one appears.

    Polls for up to ALERT_WAIT seconds. Returns {"button", "text"} for the dialog it pressed, and
    None when every poll read no such dialog. A poll osascript could not read is not a poll that saw
    nothing: when no dialog was pressed and any poll was unreadable, the return is
    {"button": None, "text": None, "unreadable_polls": n}.
    """
    deadline = time.monotonic() + ALERT_WAIT
    unreadable = 0
    while True:
        out = L993.osa(ACKNOWLEDGE_SCRIPT)
        parts = (out or "").split("\n", 2)
        if parts[0] == "pressed":
            parts += ["", ""]
            return {"button": parts[1], "text": parts[2]}
        if out != "none":
            unreadable += 1
        if time.monotonic() + ALERT_POLL > deadline:
            break
        time.sleep(ALERT_POLL)
    return {"button": None, "text": None, "unreadable_polls": unreadable} if unreadable else None


#: Seconds `park_pointer` waits after its move before it reads the pointer back.
PARK_SETTLE = 0.5


def pick_park_point(displays, logic_windows):
    """The centre of the first display no Logic window overlaps, or None when every one holds one.

    Every rect is [x, y, w, h] in global display points. Overlap is strict: a window that only
    touches a display's edge does not hold that display. Displays meet edge to edge, so X6's main
    window, [0, 30, 1920, 1050] on the first display, touches the edges of both displays beside it;
    counting a touch would leave no display to park on.
    """
    def overlaps(a, b):
        return (a[0] < b[0] + b[2] and b[0] < a[0] + a[2]
                and a[1] < b[1] + b[3] and b[1] < a[1] + a[3])
    for display in displays:
        if not any(overlaps(display, window) for window in logic_windows):
            return [display[0] + display[2] / 2, display[1] + display[3] / 2]
    return None


def park_pointer(quartz=None):
    """Move the pointer off every Logic window, to the centre of the first display that holds none.

    Posts one kCGEventMouseMoved through the HID tap and nothing else: no click, no button event.
    Returns {"from", "to", "after", "parked", "why"}; `parked` is True only when the pointer reads
    back within 1 pt of `to`. Nothing is moved when every display holds a Logic window, or when the
    display or window list cannot be read: a list that could not be read does not say where Logic
    is. Never raises; a Quartz failure is its repr in `why`, and the shot is taken anyway.
    """
    out = {"from": None, "to": None, "after": None, "parked": False, "why": None}
    try:
        if quartz is None:
            import Quartz as quartz
        here = quartz.CGEventGetLocation(quartz.CGEventCreate(None))
        out["from"] = [here.x, here.y]
        err, ids, count = quartz.CGGetActiveDisplayList(16, None, None)
        if err or not count:
            out["why"] = f"no active display could be read (error {err}, count {count})"
            return out
        displays = []
        for display in list(ids)[:count]:
            r = quartz.CGDisplayBounds(display)
            displays.append([r.origin.x, r.origin.y, r.size.width, r.size.height])
        windows = quartz.CGWindowListCopyWindowInfo(quartz.kCGWindowListOptionOnScreenOnly,
                                                    quartz.kCGNullWindowID)
        if windows is None:
            out["why"] = "the on-screen window list could not be read"
            return out
        logic = []
        for window in windows:
            if not E._is_logic_owned_window(window):
                continue
            b = window.get(quartz.kCGWindowBounds)
            if not b:
                out["why"] = "a Logic window's bounds could not be read"
                return out
            logic.append([b["X"], b["Y"], b["Width"], b["Height"]])
        target = pick_park_point(displays, logic)
        if target is None:
            out["why"] = f"every display holds a Logic window: displays {displays}, Logic {logic}"
            return out
        out["to"] = target
        quartz.CGEventPost(quartz.kCGHIDEventTap, quartz.CGEventCreateMouseEvent(
            None, quartz.kCGEventMouseMoved, tuple(target), quartz.kCGMouseButtonLeft))
        time.sleep(PARK_SETTLE)
        there = quartz.CGEventGetLocation(quartz.CGEventCreate(None))
        out["after"] = [there.x, there.y]
        out["parked"] = abs(there.x - target[0]) <= 1 and abs(there.y - target[1]) <= 1
        if not out["parked"]:
            out["why"] = "the pointer did not read back at the target"
    except Exception as exc:  # noqa: BLE001 - a pointer that could not be parked must not end the run
        out["parked"], out["why"] = False, repr(exc)
    return out


def run_locale(driver, rows, lproj):
    """Drive every call for one language; every set gets at least one row, reached or not."""
    add = rows.add
    driver.tool("logic_system", "refresh_cache", {})
    info = (driver.resource("logic://project/info") or {}).get("data") or {}
    path = (info.get("filePath") or "").strip()

    regions = driver.tool("logic_project", "get_regions", {})
    add("regionKindMidi", lproj, "get_regions", regions)
    add("trackContentExplicit", lproj, "get_regions", regions)

    created = {}
    for op in ("create_instrument", "create_audio", "create_external_midi"):
        body = driver.tool("logic_tracks", op)
        time.sleep(1.5)
        add("inspectorChannelStripHelpPrefix", lproj, op, body)
        if op == "create_instrument":
            add("midiEffectSlotHelpKeyword", lproj, op, body)
        listing, current = tracks(driver)
        named = body.get("observed_track_name") if isinstance(body, dict) else None
        created[op] = (body, listing, track_named(current, named))
    ext_body, ext_listing, ext_row = created["create_external_midi"]
    add("trackTypeExternalMIDI", lproj, "logic://tracks after create_external_midi",
        ext_row if ext_row is not None else ext_listing)

    audio_body, audio_listing, audio = created["create_audio"]
    plugin_row = ("create_audio", audio_body)
    if audio is not None and path:
        inventory = driver.tool("logic_plugins", "get_inventory", {"track": audio["id"]})
        free = [p.get("insert") for p in (inventory.get("plugins") or [])
                if isinstance(p, dict) and p.get("occupied") is False]
        plugin_row = ("get_inventory", inventory)
        if free:
            inserted = driver.tool("logic_plugins", "insert_verified", {
                "track": audio["id"], "insert": free[0], "plugin": "Compressor",
                "mode": "duplicate_applyback", "project_expected_path": path,
                "expected_name": audio["name"]})
            plugin_row = ("insert_verified", inserted)
            after = driver.tool("logic_plugins", "get_inventory", {"track": audio["id"]})
            slots = [p.get("insert") for p in (after.get("plugins") or [])
                     if isinstance(p, dict) and p.get("plugin_id") == COMPRESSOR_ID]
            if len(slots) == 1:
                plugin_row = ("set_param_verified", driver.tool("logic_plugins", "set_param_verified", {
                    "track": audio["id"], "insert": slots[0], "plugin": "compressor",
                    "param": "limiter_on", "value": "1", "unit": "boolean",
                    "mode": "duplicate_applyback", "project_expected_path": path}))
            else:
                plugin_row = ("get_inventory after insert_verified", after)
    elif audio is not None:
        plugin_row = ("logic://project/info", info)
    add("pluginWindowControlsViewMenuItem", lproj, plugin_row[0], plugin_row[1])

    target = audio
    if target is None:
        _, current = tracks(driver)
        target = current[0] if current else None
    toggled = driver.tool("logic_navigate", "toggle_view", {"view": "automation"})

    def set_automation(mode, call):
        reply = driver.tool("logic_tracks", "set_automation", {"index": target["id"], "mode": mode})
        # Measured 2026-09-30: `mode: write` leaves Logic's one-button Write warning open and the
        # server returns without dismissing it; left open, the discard-quit that ends this language
        # crashed Logic 4 of 4 times, and acknowledged it crashed 0 of 1. Every mode is asked, and an
        # acknowledged alert is recorded, not a failure.
        alert = acknowledge_alert()
        if alert is not None:
            ACKNOWLEDGED_ALERTS.append({"locale": lproj, "call": call, **alert})
        return reply

    for set_name, mode in AUTOMATION_MODES.items():
        if target is None:
            add(set_name, lproj, "toggle_view", toggled)
            continue
        call = f"set_automation:{mode}"
        reply = set_automation(mode, call)
        if set_name == "automationModeRead" and isinstance(reply, dict) and "observed_mode" not in reply:
            # The toggle may have HIDDEN a view the fixture already showed: record the first
            # reading, toggle back, and read again.
            add(set_name, lproj, call, reply)
            driver.tool("logic_navigate", "toggle_view", {"view": "automation"})
            call = f"set_automation:{mode} (after a second toggle_view)"
            reply = set_automation(mode, call)
        add(set_name, lproj, call, reply)
        listing, current = tracks(driver)
        row = track_named(current, target.get("name"))
        add(set_name, lproj, f"logic://tracks after {call}", row if row is not None else listing)

    # Last, because it removes a track. Regions are read again: the creates moved the indices.
    held = driver.tool("logic_project", "get_regions", {})
    _, current = tracks(driver)
    candidates = []
    for region in _regions(held) or []:
        index = region.get("trackIndex") if isinstance(region, dict) else None
        owner = next((t for t in current if t.get("id") == index), None)
        if owner is not None and track_named(current, owner.get("name")) is not None:
            candidates.append(owner)
    if candidates:
        owner = candidates[-1]
        body = driver.tool("logic_tracks", DELETE_COMMAND,
                           {"index": owner["id"], "expected_name": owner["name"]})
        time.sleep(2.0)
        add("deleteTracksPrimaryButton", lproj, DELETE_COMMAND, body)
    else:
        add("deleteTracksPrimaryButton", lproj, "get_regions", held,
            reason="no track holding a region carries a name no other track shares")

    for set_name, reason in LIMITS.items():
        add(set_name, lproj, "none", {}, reason=reason)


def refuse_without_lock():
    lock = os.environ.get("LPM_LIVE_LOCK") or ""
    if not lock or not os.path.isfile(lock):
        sys.exit(f"refusing to run: LPM_LIVE_LOCK must name an existing lock file held by the "
                 f"caller (got {lock!r}); nothing was sent to Logic")


def arguments(argv):
    if len(argv) < 3:
        sys.exit(__doc__)
    worktree, head, lprojs = argv[1], argv[2], argv[3:] or list(DEFAULT_LPROJS)
    if not re.fullmatch(r"[0-9a-f]{40}", head):
        sys.exit("head must be a full lowercase 40-character SHA")
    if not os.path.isdir(worktree):
        sys.exit(f"worktree does not exist: {worktree}")
    unknown = [name for name in lprojs if name not in L993.CODES]
    if unknown:
        sys.exit(f"unknown lproj(s): {', '.join(unknown)}")
    if not os.environ.get("LPM_EVIDENCE_ROOT"):
        sys.exit("LPM_EVIDENCE_ROOT must be set by the caller")
    return worktree, head, lprojs


def main(argv):
    refuse_without_lock()
    worktree, head, lprojs = arguments(argv)
    sys.path.insert(0, os.path.join(worktree, "Scripts"))
    import logic_canon  # noqa: E402
    # live_993's main binds this module global for its own helpers; set it the same way.
    setattr(L993, "logic_canon", logic_canon)

    E.REPO = worktree
    E.BIN = os.environ.get("LPM_BINARY") or f"{worktree}/.build/release/LogicProMCP"
    missing = E.have_tools()
    if missing:
        sys.exit(f"cannot run: missing {missing}")
    with open(E.BIN, "rb") as handle:
        binary_sha = hashlib.sha256(handle.read()).hexdigest()

    ev = E.Evidence(head, os.environ["LPM_EVIDENCE_ROOT"], surface="ui")
    rows = Rows(os.path.join(ev.dir, "live_904_labelset_rows.jsonl"), head, E.BIN)
    languages, failures = {}, {}
    restored = {}
    # live_993's duration, for the same per-language quit-and-relaunch sweep.
    recording = ev.record_screen(seconds=max(150, 90 * len(lprojs)))
    band, subject, before_shot = None, None, None
    try:
        # Reopened discarding, so the band below is the fixture as saved; the Korean restore in the
        # `finally` reopens it the same way, and every language between them discards its tracks.
        baseline = L993.switch_to(RESTORE, force=True)
        ev.note("904/korean-baseline", baseline)
        if baseline.get("arrange_window"):
            band, subject = ev.located_band("Tracks header")
            if band:
                # Measured 2026-09-30 (X6): the pointer rested at (862,571), inside the E-Piano
                # strip's audio-FX insert slot. The before shot had that slot's hover highlight and
                # the after shot did not, so the visual failed on that 113x33 box while the content
                # was unchanged. Nothing in the run moves the pointer, so both shots park it first.
                ev.note("904/pointer-parked-before-shot", park_pointer())
                before_shot = ev.shot("904/korean-fixture-before", settle_region=band,
                                      window_title=baseline["arrange_window"])
        for lproj in lprojs:
            language = L993.switch_to(lproj, force=True)
            languages[lproj] = language
            ev.note(f"904/{lproj}/language", language)
            if language.get("arrange_window") is None \
                    or language.get("language_setting", [])[:1] != [L993.CODES[lproj]]:
                failures[lproj] = "the fixture did not open in this language"
                continue
            driver = E.Driver()
            try:
                run_locale(driver, rows, lproj)
            except Exception as exc:  # the rows made so far stay; the count below reports the rest
                failures[lproj] = repr(exc)
                ev.note(f"904/{lproj}/harness-exception", repr(exc))
            finally:
                driver.close()
    finally:
        try:
            restored = L993.switch_to(RESTORE, force=True)
        except Exception as exc:
            restored = {"error": f"Korean restoration raised: {exc!r}"}
        restored["language_setting_after_restore"] = L993.language_setting()
        restored["window_names_after_restore"] = L993.window_names()
        restored["ok"] = (restored.get("arrange_window") is not None
                          and restored["language_setting_after_restore"][:1] == [L993.CODES[RESTORE]]
                          and restored["arrange_window"] in (restored["window_names_after_restore"]
                                                             or []))
        ev.restored("904/Logic-language-restored-to-Korean", restored["ok"], repr(restored))
        # No before capture (the baseline did not open, or the band did not resolve) records no
        # visual, and `E.is_clean` below refuses the run for it: absence is not a pass.
        if before_shot and restored.get("arrange_window"):
            ev.note("904/pointer-parked-before-after-shot", park_pointer())
            after_shot = ev.shot("904/korean-fixture-after", settle_region=band,
                                 window_title=restored["arrange_window"])
            ev.visual("904/korean-fixture-rail-after-locale-sweep",
                      before_shot["file"], after_shot["file"], band,
                      expect_change=False,
                      why="every language reopened the fixture through a quit that discards, so "
                          "the tracks each one created and deleted were never saved",
                      subject=subject)
        ev.stop_recording(recording)

    incomplete = incomplete_locales(rows.rows, lprojs)
    for lproj in lprojs:
        ev.check(f"904/{lproj}/every-set-has-a-row", lproj not in incomplete,
                 f"at least {len(SETS)} rows and one for every set in {lproj}",
                 incomplete.get(lproj, {"rows": sum(r["locale"] == lproj for r in rows.rows)}),
                 "drop the Limit rows from run_locale: every locale is short five sets")
    complete = not incomplete and not rows.unnamed
    ev.check("904/every-requested-language-has-a-named-row-for-every-set", complete,
             f"every requested language has a row for each of the {len(SETS)} sets and no reply "
             "the classifier cannot name",
             {"requested": lprojs, "incomplete_locales": incomplete, "unnamed_errors": rows.unnamed,
              "locale_failures": failures},
             "return a State C with no error code from logic_tracks.create_audio: every language's "
             "create_audio row becomes an unnamed error")
    matrix = {}
    for row in rows.rows:
        matrix.setdefault(row["set"], {}).setdefault(row["locale"], {})[row["call"]] = row["matched_via"]
    summary = {"head_sha": head, "binary": E.BIN, "binary_sha256": binary_sha, "lprojs": lprojs,
               "sets": list(SETS), "matrix": matrix, "incomplete_locales": incomplete,
               "unnamed_errors": rows.unnamed, "locale_failures": failures,
               "languages": languages, "korean_restore": restored,
               "system_events_restarts": list(L993.SYSTEM_EVENTS_RESTARTS),
               "acknowledged_alerts": list(ACKNOWLEDGED_ALERTS)}
    with open(os.path.join(ev.dir, "live_904_labelset_summary.json"), "w", encoding="utf-8") as handle:
        json.dump(summary, handle, ensure_ascii=False, indent=1)
    out = ev.write()
    clean = E.is_clean(out)
    print(json.dumps({"incomplete_locales": incomplete, "unnamed_errors": rows.unnamed,
                      "korean_restored": restored.get("ok"), "rows": len(rows.rows),
                      "evidence_clean": clean}, ensure_ascii=False, indent=1))
    return 0 if complete and restored.get("ok") and clean else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
