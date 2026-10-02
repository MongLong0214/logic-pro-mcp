#!/usr/bin/env python3
"""Live proof that the eight plain-letter operations act under 2-Set Korean through CGEvent alone (#1039).

Usage: LPM_LIVE_LOCK=<held lock> LPM_EVIDENCE_ROOT=<absolute dir> /usr/bin/python3 \
       Scripts/livekit/live_1039_plain_letters_under_2set_korean.py \
       <worktree> <full-40-char-head> <candidate-binary> <control-binary> [--lprojs lproj ...]
       (default lprojs: en ko ja de es fr it pt zh_CN zh_TW; both binaries debug builds)

WHAT IS ASKED
-------------
Under the 2-Set Korean input source a plain letter key reaches Logic as a Hangul character and runs
no key command. Eight operations post one through CGEventChannel: record (R), toggle_cycle (C),
toggle_metronome (K), toggle_mixer (X), toggle_piano_roll (P), toggle_library (Y), zoom_to_fit (Z) and
automation toggle_view (A). The candidate selects the ASCII-capable layout for the key and selects
the user's source back; the control is the same build without that switch, which refuses the key.
This asks whether each operation, driven through CGEventChannel alone, changes Logic's state under
the candidate and not under the control, and whether the input source is 2-Set Korean again after it.

HOW CGEVENT IS ISOLATED
-----------------------
Both servers are started with LOGIC_MCP_DEBUG_ONLY_CHANNEL=CGEvent, which keeps CGEvent alone in every
chain (`ChannelRouter.debugOnlyChannel`). Record, cycle and metronome reach Accessibility first
without it. The MIDI key-command channel's operator approval is also withdrawn for the run, and
operator-approvals.json is put back byte for byte at the end. A candidate reply whose `method` is
`cgevent` for an operation whose table chain starts with Accessibility is the restriction firing.

HOW THE STATE IS READ
---------------------
Through the Accessibility API from this process, not from the server's reply:
  record, cycle, metronome, mixer, library  the value of the one control-bar checkbox whose
      description matches the operation's label in docs/locale/ui-labels.json, under that label's
      match mode; every other control-bar checkbox must keep its value.
  piano roll   the one control-bar checkbox, other than the five above, that turns on after the
      first P and off after the second (the editors' checkbox; the canon has no label for it).
  automation   the counts of layout areas, pop-up buttons, menu buttons and groups at each depth
      within nine levels of the arrange window.
  zoom to fit  the values of the sliders within three levels of the arrange window.
None of the last three is read by name. Each must change and then come back, so a reading that
moves for some other reason has to move twice in step with the key to pass.

Per language, on a fresh launch of the locale-campaign fixture: the control is called once per
operation and nothing may change. Then the candidate is called twice per toggle and must change the
reading and bring it back. Record is called once, its checkbox must turn on, and then
`logic_transport stop` (keypad 0, not a plain letter) must turn it off; `logic_edit undo` (Command-Z)
follows. The input source is read after every call and must be 2-Set Korean. Around the candidate's
first mixer call the control bar's mixer checkbox is photographed, and the region must change.

A KEY LOGIC LEAVES UNBOUND
-------------------------
Which keys Logic's current key command set binds with no modifier is read from its preferences
(`KeyCommands`) per language. An operation whose letter has no such binding cannot change Logic's
state by its key under any input source, so for it only the switch is judged: the key went out under
ABC through CGEvent and 2-Set Korean read back after it. Measured 2026-10-02: this machine runs an
edited U.S. set that binds R, C, X, Y, P, Z and A with no modifier, and not K.

PASS
----
In every language every candidate operation and every control operation matches its row above, each
checked against the other binary's row as the state it must reject. Korean is restored at the end
and read back, as is operator-approvals.json. The exit code is also the evidence document's own
`is_clean`.

WHAT IS NOT JUDGED
------------------
Which command Logic ran is read from the state it changed, not from Logic. The piano roll,
automation and zoom readings are structural and unnamed. The waits around the key are the
candidate's own and are not varied here. A recording may leave an audio file in the fixture's
package; the fixture is closed without saving at every language switch.
"""

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, ".."))
import evidence as E  # noqa: E402
import live_993_plugin_root_menu_in_every_locale as L993  # noqa: E402
from logic_input_source import TISRuntime  # noqa: E402

LABELS = os.path.join(HERE, "..", "..", "docs", "locale", "ui-labels.json")
ONLY_CHANNEL_KEY = "LOGIC_MCP_DEBUG_ONLY_CHANNEL"
KOREAN_2SET = "com.apple.inputmethod.Korean.2SetKorean"
APPROVALS = os.path.expanduser("~/Library/Application Support/LogicProMCP/operator-approvals.json")
HISERVICES = "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework"
LOGIC_BUNDLE = "com.apple.logic10"
SETTLE = 1.2
STARTUP = 2.0
SLIDER_MOVED = 0.01
SLIDER_BACK = 0.02
RECORDING_SECONDS_PER_LANGUAGE = 150

#: (operation, tool, command, params, reading, canon key). The reading names how the state is read.
#: Automation and zoom to fit come first, on the launch's own key focus in the Tracks area: both are
#: Tracks-area commands, and the panes the later operations open and close move the key focus.
TOGGLES = (
    ("automation.toggle_view", "logic_navigate", "toggle_view", {"view": "automation"}, "structure", None),
    ("nav.zoom_to_fit", "logic_navigate", "zoom_to_fit", {}, "sliders", None),
    ("transport.toggle_cycle", "logic_transport", "toggle_cycle", {}, "box", "transportCycleControl"),
    ("transport.toggle_metronome", "logic_transport", "toggle_metronome", {}, "box", "transportMetronomeControl"),
    ("view.toggle_library", "logic_navigate", "toggle_view", {"view": "library"}, "box", "libraryPanelLabel"),
    ("view.toggle_mixer", "logic_navigate", "toggle_view", {"view": "mixer"}, "box", "mixerNamedElement"),
    ("view.toggle_piano_roll", "logic_navigate", "toggle_view", {"view": "piano_roll"}, "unnamed_box", None),
)
#: The canon keys of the checkboxes other operations own; the piano roll's is the one left.
NAMED_BOXES = ("transportCycleControl", "transportMetronomeControl", "libraryPanelLabel",
               "mixerNamedElement", "transportRecordControl")
#: The roles whose per-depth counts make the structural reading.
STRUCTURE_ROLES = ("AXLayoutArea", "AXPopUpButton", "AXMenuButton", "AXGroup")
READY_WAIT = 40.0
RECORD = ("transport.record", "logic_transport", "record", {}, "box", "transportRecordControl")
#: The character each operation's key types under ABC (`CGEventChannel.keyMap`, Apple's U.S. preset).
CHARACTERS = {"transport.record": "r", "transport.toggle_cycle": "c", "transport.toggle_metronome": "k",
              "view.toggle_mixer": "x", "view.toggle_library": "y", "view.toggle_piano_roll": "p",
              "nav.zoom_to_fit": "z", "automation.toggle_view": "a"}
LOGIC_PREFERENCES = os.path.expanduser("~/Library/Preferences/com.apple.logic10.plist")
#: The operations whose table chain starts with Accessibility: a cgevent reply is the restriction.
ACCESSIBILITY_FIRST = ("transport.record", "transport.toggle_cycle", "transport.toggle_metronome")


def arguments():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("worktree")
    parser.add_argument("head")
    parser.add_argument("candidate")
    parser.add_argument("control")
    parser.add_argument("--lprojs", nargs="+", default=list(L993.DEFAULT_LPROJS), metavar="lproj")
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9a-f]{40}", args.head):
        parser.error("head must be a full lowercase 40-character SHA")
    if not os.path.isdir(args.worktree):
        parser.error("worktree does not exist")
    for path in (args.candidate, args.control):
        if not os.access(path, os.X_OK):
            parser.error(f"binary is not executable: {path}")
    unknown = [name for name in args.lprojs if name not in L993.CODES]
    if unknown:
        parser.error(f"unknown lproj(s): {', '.join(unknown)}")
    if not os.path.isabs(os.environ.get("LPM_EVIDENCE_ROOT", "")):
        parser.error("LPM_EVIDENCE_ROOT must be set by the caller to an absolute path")
    lock = os.environ.get("LPM_LIVE_LOCK") or ""
    if not os.path.isfile(lock):
        parser.error(f"LPM_LIVE_LOCK must name an existing lock file held by the caller (got {lock!r})")
    return args


def sha256_of(path):
    with open(path, "rb") as handle:
        return hashlib.sha256(handle.read()).hexdigest()


# --- the canon ---------------------------------------------------------------------------------

def label(key):
    """(mode, names) for one canon key."""
    with open(LABELS, encoding="utf-8") as handle:
        row = json.load(handle)["labels"][key]
    return row.get("match") or "exact", [row["canonical"], *row["variants"]]


def matches(text, key):
    """Whether `text` matches the canon key under its mode, as `AXLocalePolicy` compares:
    `contains` is case-insensitive containment, `exact` case-insensitive equality after trimming,
    and `exact_strict` case-insensitive equality of the verbatim string, untrimmed. The English
    pilot stopped on a case-sensitive `exact_strict`: the control bar is described with capitals."""
    if not text:
        return False
    mode, names = label(key)
    if mode == "contains":
        return any(name.casefold() in text.casefold() for name in names)
    if mode == "exact_strict":
        return any(text.casefold() == name.casefold() for name in names)
    return any(text.strip().casefold() == name.strip().casefold() for name in names)


# --- Accessibility, from this process -------------------------------------------------------------

class AX:
    def __init__(self):
        import objc
        from Foundation import NSBundle
        bundle = NSBundle.bundleWithPath_(HISERVICES)
        self.f, point, size = {}, {}, {}
        objc.loadBundleFunctions(bundle, self.f, [("AXUIElementCreateApplication", b"@i"),
                                                  ("AXUIElementCopyAttributeValue", b"i@@o^@"),
                                                  ("AXUIElementPerformAction", b"i@@"),
                                                  ("AXUIElementSetAttributeValue", b"i@@@")])
        objc.loadBundleFunctions(bundle, point, [("AXValueGetValue", b"Z@Io^{CGPoint=dd}")])
        objc.loadBundleFunctions(bundle, size, [("AXValueGetValue", b"Z@Io^{CGSize=dd}")])
        self.point, self.size = point["AXValueGetValue"], size["AXValueGetValue"]

    def value(self, element, name):
        status, found = self.f["AXUIElementCopyAttributeValue"](element, name, None)
        return found if status == 0 else None

    def children(self, element):
        return list(self.value(element, "AXChildren") or [])

    def walk(self, element, depth_left, depth=0):
        yield element, depth
        if depth_left == 0:
            return
        for child in self.children(element):
            yield from self.walk(child, depth_left - 1, depth + 1)

    def perform(self, element, action):
        return self.f["AXUIElementPerformAction"](element, action)

    def set(self, element, name, value):
        return self.f["AXUIElementSetAttributeValue"](element, name, value)

    def window_titled(self, pid, title):
        """The application's window with exactly this AXTitle, or None. Not AXMainWindow: right
        after a launch that is the Marker List window the fixture also opens (Korean pilot)."""
        app = self.f["AXUIElementCreateApplication"](pid)
        for window in self.value(app, "AXWindows") or []:
            if self.value(window, "AXTitle") == title:
                return window
        return None

    def frame(self, element):
        position, extent = self.value(element, "AXPosition"), self.value(element, "AXSize")
        if position is None or extent is None:
            return None
        ok_p, p = self.point(position, 1, None)
        ok_s, s = self.size(extent, 2, None)
        if not (ok_p and ok_s):
            return None
        return (p.x, p.y, s.width, s.height)


#: The arrange window's title for the language being run, from `L993.switch_to`.
ARRANGE = {"title": None}


def arrange_window(ax):
    pid = logic_pid()
    return ax.window_titled(pid, ARRANGE["title"]) if pid and ARRANGE["title"] else None


def focus_tracks(ax):
    """Raise the arrange window, make it main, and give the Tracks header rail the key focus, as
    #1079's probe does. The fixture also opens a Marker List window, and right after a launch that
    window held the key focus: in the Korean pilot A, Z and K posted under ABC changed nothing.
    Returns the two statuses, which are recorded; a failed focus fails the reading after it."""
    window = arrange_window(ax)
    if window is None:
        return {"window": False}
    raised = ax.perform(window, "AXRaise")
    main = ax.set(window, "AXMain", True)
    rail = next((e for e, _ in ax.walk(window, 12)
                 if matches(ax.value(e, "AXDescription"), "trackHeadersDescription")), None)
    focused = ax.set(rail, "AXFocused", True) if rail is not None else None
    time.sleep(0.3)
    return {"window": True, "raised": raised, "main": main, "rail": rail is not None, "focused": focused}


def plain_bindings():
    """The characters Logic's current key command set binds with no modifier, read from its
    preferences (`KeyCommands`: command id -> CharCode, Modifier), or None when they did not read.
    Measured 2026-10-02: this machine runs an edited U.S. set in which every one of the eight
    letters but K has a binding with modifier 0, so K, which Apple's U.S. preset binds to Toggle
    Metronome Click, reaches Logic and runs nothing whatever the input source."""
    import plistlib
    try:
        with open(LOGIC_PREFERENCES, "rb") as handle:
            commands = plistlib.load(handle).get("KeyCommands") or {}
    except (OSError, ValueError):
        return None
    return sorted({chr(entry["CharCode"]) for entry in commands.values()
                   if isinstance(entry, dict) and entry.get("Modifier") == 0
                   and isinstance(entry.get("CharCode"), int) and 32 < entry["CharCode"] < 127})


def logic_pid():
    out = subprocess.run(["/usr/bin/lsappinfo", "info", "-only", "pid", "-app", LOGIC_BUNDLE],
                         capture_output=True, text=True).stdout
    found = re.search(r"=\s*(\d+)", out)
    return int(found.group(1)) if found else None


def control_bar_boxes(ax, window):
    """[(description, value, element)] for the checkboxes of the group the canon names the control
    bar; None when no such group with checkboxes was found."""
    for element, _ in ax.walk(window, 6):
        if ax.value(element, "AXRole") != "AXGroup" \
                or not matches(ax.value(element, "AXDescription"), "controlBarGroupLabel"):
            continue
        boxes = [(ax.value(c, "AXDescription") or ax.value(c, "AXTitle") or "",
                  ax.value(c, "AXValue"), c)
                 for c in ax.children(element) if ax.value(c, "AXRole") == "AXCheckBox"]
        if boxes:
            return boxes
    return None


def target_box(boxes, key):
    """The one checkbox the canon key names: its match mode first, then, when that leaves more than
    one, exact equality without regard to case (Korean's record label is also inside the free-tempo
    recording checkbox's). None unless exactly one is left."""
    found = [(d, v) for d, v, _ in boxes if matches(d, key)]
    if len(found) > 1:
        names = [name.casefold() for name in label(key)[1]]
        found = [(d, v) for d, v in found if d.casefold() in names]
    return found[0] if len(found) == 1 else None


def reading(ax, kind, key):
    """The reading one operation is judged on, as a plain value; None when it did not read."""
    window = arrange_window(ax)
    if window is None:
        return None
    if kind == "box":
        boxes = control_bar_boxes(ax, window)
        if boxes is None:
            return None
        target = target_box(boxes, key)
        if target is None or target[1] is None:
            return {"unread": f"no single control-bar checkbox matches {key}"}
        return {"target": int(target[1]),
                "others": {d: (None if v is None else int(v)) for d, v, _ in boxes if d != target[0]}}
    if kind == "unnamed_box":
        boxes = control_bar_boxes(ax, window)
        if boxes is None:
            return None
        named = {t[0] for t in (target_box(boxes, k) for k in NAMED_BOXES) if t is not None}
        return {d: (None if v is None else int(v)) for d, v, _ in boxes if d not in named}
    if kind == "structure":
        counts = {}
        for element, depth in ax.walk(window, 9):
            role = ax.value(element, "AXRole")
            if role in STRUCTURE_ROLES:
                counts[f"{depth}:{role}"] = counts.get(f"{depth}:{role}", 0) + 1
        return counts
    if kind == "sliders":
        values = [ax.value(e, "AXValue") for e, _ in ax.walk(window, 3) if ax.value(e, "AXRole") == "AXSlider"]
        return [float(v) for v in values if isinstance(v, (int, float))]
    raise ValueError(kind)


def turned_on(before, after):
    """The unnamed checkboxes that went from off to on."""
    return sorted(d for d, v in (after or {}).items() if v == 1 and (before or {}).get(d) == 0)


def changed(kind, before, after):
    if before is None or after is None or isinstance(before, dict) and "unread" in before \
            or isinstance(after, dict) and "unread" in after:
        return None
    if kind == "box":
        return before["target"] != after["target"]
    if kind == "unnamed_box":
        return len(turned_on(before, after)) == 1
    if kind == "sliders":
        if len(before) != len(after) or not before:
            return None
        return max(abs(a - b) for a, b in zip(before, after)) > SLIDER_MOVED
    return before != after


def same(kind, before, after):
    if before is None or after is None or isinstance(before, dict) and "unread" in before \
            or isinstance(after, dict) and "unread" in after:
        return None
    if kind == "box":
        return before == after
    if kind == "unnamed_box":
        # Only the checkbox the first press turned on has to come back; showing the editor in place
        # of an open mixer closes the mixer, and closing the editor does not reopen it.
        return None
    if kind == "sliders":
        if len(before) != len(after) or not before:
            return None
        return max(abs(a - b) for a, b in zip(before, after)) <= SLIDER_BACK
    return before == after


def others_kept(kind, before, after):
    """For a checkbox reading: no other control-bar checkbox changed."""
    if kind != "box":
        return True
    return bool(before and after) and before.get("others") == after.get("others")


# --- the input source -------------------------------------------------------------------------

class Source:
    def __init__(self):
        self.runtime = TISRuntime.load()

    def current(self):
        import ctypes
        carbon = self.runtime.carbon
        carbon.TISCopyCurrentKeyboardInputSource.restype = ctypes.c_void_p
        source = carbon.TISCopyCurrentKeyboardInputSource()
        if not source:
            return None
        try:
            return self.runtime.source_id(source)
        finally:
            self.runtime.core_foundation.CFRelease(source)


# --- driving ----------------------------------------------------------------------------------

def activate_logic():
    subprocess.run(["/usr/bin/osascript", "-e", f'tell application id "{LOGIC_BUNDLE}" to activate'],
                   capture_output=True, timeout=10)
    time.sleep(0.8)


def call(driver, source, tool, command, params, ax=None):
    activate_logic()
    focus = focus_tracks(ax) if ax is not None else None
    started = time.monotonic()
    reply = driver.tool(tool, command, params)
    seconds = round(time.monotonic() - started, 2)
    time.sleep(SETTLE)
    return {"reply": reply, "seconds": seconds, "source_after": source.current(), "focus": focus}


def reply_summary(reply):
    """The reply's state and the channel's fields. A verified transport command carries the
    channel's own reply under `write_result`; its fields are taken from there when absent above."""
    keys = ("state", "success", "error", "reason", "method", "operation", "input_source_switched",
            "input_source_before", "input_source_switched_to", "input_source_restored",
            "input_source_after", "input_source_switch_failure")
    if not isinstance(reply, dict):
        return {"unparsed": repr(reply)[:200]}
    summary = {k: reply.get(k) for k in keys if k in reply}
    inner = reply.get("write_result")
    if isinstance(inner, dict):
        summary["write_result"] = {k: inner.get(k) for k in keys if k in inner}
        for k in ("method",) + keys[6:]:
            if k not in summary and k in inner:
                summary[k] = inner[k]
    return summary


def unchanged(kind, before, after):
    """For the control: the reading did not move at all."""
    if kind == "unnamed_box":
        return None if before is None or after is None else before == after
    return same(kind, before, after)


def wait_ready(ax):
    """Wait until the control bar reads after a launch: the first readings after Logic opens its
    window come back empty for a while (measured in the Korean pilot)."""
    end = time.monotonic() + READY_WAIT
    while time.monotonic() < end:
        found = reading(ax, "box", "transportCycleControl")
        if isinstance(found, dict) and "target" in found:
            return True
        time.sleep(1.0)
    return False


def run_control(driver, ax, source, lproj):
    rows = {}
    for name, tool, command, params, kind, key in TOGGLES + (RECORD,):
        before = reading(ax, kind, key)
        result = call(driver, source, tool, command, params, ax)
        after = reading(ax, kind, key)
        rows[name] = {"kind": kind, "before": before, "after": after,
                      "unchanged": unchanged(kind, before, after), "reply": reply_summary(result["reply"]),
                      "source_after": result["source_after"], "seconds": result["seconds"]}
        print(json.dumps({"lproj": lproj, "role": "control", "op": name,
                          "unchanged": rows[name]["unchanged"], "reply": rows[name]["reply"]},
                         ensure_ascii=False), flush=True)
    return rows


def run_candidate(ev, driver, ax, source, lproj):
    rows = {}
    for name, tool, command, params, kind, key in TOGGLES:
        first_shot = None
        if name == "view.toggle_mixer":
            first_shot = mixer_shot(ev, ax, f"1039/{lproj}/candidate/mixer-before")
        before = reading(ax, kind, key)
        first = call(driver, source, tool, command, params, ax)
        middle = reading(ax, kind, key)
        if first_shot is not None:
            after_shot = mixer_shot(ev, ax, f"1039/{lproj}/candidate/mixer-after", first_shot["region"])
            if after_shot is not None:
                ev.visual(f"1039/{lproj}/candidate/mixer-checkbox-changed", first_shot["file"],
                          after_shot["file"], first_shot["region"], expect_change=True,
                          why="X posted under ABC toggles the mixer, and the control bar's mixer "
                              "checkbox shows the new state",
                          subject=f"the control-bar checkbox described {first_shot['description']!r}, "
                                  "matched to the canon's mixer label",
                          window_points=first_shot["window_points"])
        second = call(driver, source, tool, command, params, ax)
        after = reading(ax, kind, key)
        if kind == "unnamed_box":
            on = turned_on(before, middle)
            came_back = len(on) == 1 and (after or {}).get(on[0]) == 0
        else:
            came_back = same(kind, before, after)
        rows[name] = {"kind": kind, "before": before, "middle": middle, "after": after,
                      "changed": changed(kind, before, middle), "came_back": came_back,
                      "others_kept": others_kept(kind, before, middle),
                      "replies": [reply_summary(first["reply"]), reply_summary(second["reply"])],
                      "sources_after": [first["source_after"], second["source_after"]]}
        print(json.dumps({"lproj": lproj, "role": "candidate", "op": name, "changed": rows[name]["changed"],
                          "came_back": rows[name]["came_back"], "replies": rows[name]["replies"]},
                         ensure_ascii=False), flush=True)
    name, tool, command, params, kind, key = RECORD
    before = reading(ax, kind, key)
    started = call(driver, source, tool, command, params, ax)
    recording = reading(ax, kind, key)
    stopped = call(driver, source, "logic_transport", "stop", {}, ax)
    after = reading(ax, kind, key)
    undone = call(driver, source, "logic_edit", "undo", {}, ax)
    rows[name] = {"kind": kind, "before": before, "middle": recording, "after": after,
                  "changed": changed(kind, before, recording), "came_back": same(kind, before, after),
                  "others_kept": True,
                  "replies": [reply_summary(started["reply"]), reply_summary(stopped["reply"]),
                              reply_summary(undone["reply"])],
                  "sources_after": [started["source_after"], stopped["source_after"]]}
    print(json.dumps({"lproj": lproj, "role": "candidate", "op": name, "changed": rows[name]["changed"],
                      "came_back": rows[name]["came_back"], "replies": rows[name]["replies"]},
                     ensure_ascii=False), flush=True)
    return rows


def mixer_shot(ev, ax, tag, region=None):
    """A capture of Logic's arrange window settled on the mixer checkbox, with that checkbox's region in
    window points; None when the checkbox or the window did not read."""
    window = arrange_window(ax)
    window_frame = ax.frame(window) if window is not None else None
    boxes = control_bar_boxes(ax, window) if window is not None else None
    target = [(d, e) for d, _, e in boxes or [] if matches(d, "mixerNamedElement")]
    if region is None:
        if window_frame is None or len(target) != 1:
            return None
        box = ax.frame(target[0][1])
        if box is None:
            return None
        region = (int(box[0] - window_frame[0]), int(box[1] - window_frame[1]), int(box[2]), int(box[3]))
    shot = ev.shot(tag, settle_region=region)
    return {"file": shot["file"], "region": region,
            "description": target[0][0] if target else None,
            "window_points": (int(window_frame[2]), int(window_frame[3])) if window_frame else None}


# --- judging ----------------------------------------------------------------------------------

def candidate_switched(row):
    """The key went out under ABC through CGEvent alone, and 2-Set Korean read back after it."""
    replies, sources = row.get("replies") or [], row.get("sources_after") or []
    # Record is one plain letter; the stop and the undo after it are not.
    toggled = replies[:1] if row.get("op") == RECORD[0] else replies[:2]
    switched = bool(toggled) and all(
        r.get("success") is True and r.get("input_source_switched") is True
        and r.get("input_source_before") == KOREAN_2SET and r.get("input_source_restored") is True
        for r in toggled)
    routed = all(r.get("method") == "cgevent" for r in toggled) if row.get("accessibility_first") else True
    return switched and routed and bool(sources) and all(s == KOREAN_2SET for s in sources)


def candidate_acted(row):
    """The key went out under ABC and Logic's state changed and came back. For a key Logic's key
    command set leaves unbound with no modifier, the state cannot change by that key, and only the
    switch is judged; the row says so, and the record must."""
    if row.get("key_bound") is False:
        return candidate_switched(row) and row.get("changed") is not True
    return (row.get("changed") is True and row.get("came_back") is True and row.get("others_kept") is True
            and candidate_switched(row))


def control_refused(row):
    reply = row.get("reply") or {}
    return (row.get("unchanged") is True and reply.get("success") is False
            and row.get("source_after") == KOREAN_2SET)


def main():
    args = arguments()
    sys.path.insert(0, os.path.join(args.worktree, "Scripts"))
    import logic_canon  # noqa: E402
    setattr(L993, "logic_canon", logic_canon)
    E.REPO = args.worktree
    E.BIN = args.candidate
    missing = E.have_tools()
    if missing:
        sys.exit(f"cannot run: missing {missing}")
    if E.screen_is_locked() is not False:
        sys.exit("cannot run: the screen is locked or its state did not read; nothing was sent to Logic")
    others = subprocess.run(["/usr/bin/pgrep", "-fl", "LogicProMCP"], capture_output=True, text=True)
    if others.stdout.strip():
        sys.exit(f"cannot run: a LogicProMCP process is already running: {others.stdout.strip()[:300]}")
    source = Source()
    if source.current() != KOREAN_2SET:
        sys.exit(f"cannot run: the input source is {source.current()!r}, not 2-Set Korean")
    with open(APPROVALS, "rb") as handle:
        approvals = handle.read()
    ax = AX()

    ev = E.Evidence(args.head, os.environ["LPM_EVIDENCE_ROOT"], surface="ui")
    ev.note("1039/binaries", {"candidate": args.candidate, "candidate_sha256": sha256_of(args.candidate),
                              "control": args.control, "control_sha256": sha256_of(args.control),
                              "lprojs": args.lprojs, "only_channel": "CGEvent"})
    runs, failures, restored = {}, {}, {}
    recording = ev.record_screen(seconds=RECORDING_SECONDS_PER_LANGUAGE * len(args.lprojs) + 120)
    os.environ[ONLY_CHANNEL_KEY] = "CGEvent"
    try:
        withdrawn = json.loads(approvals)
        withdrawn.get("approvals", {}).pop("MIDIKeyCommands", None)
        with open(APPROVALS, "w") as handle:
            json.dump(withdrawn, handle, indent=2)
        for lproj in args.lprojs:
            language = L993.switch_to(lproj, force=True)
            runs[lproj] = {"launch": language}
            ARRANGE["title"] = language.get("arrange_window")
            runs[lproj]["plain_bindings"] = plain_bindings()
            ev.note(f"1039/{lproj}/plain-bindings", {"characters": runs[lproj]["plain_bindings"],
                                                     "source": LOGIC_PREFERENCES})
            if language.get("arrange_window") is None \
                    or language.get("language_setting", [])[:1] != [L993.CODES[lproj]]:
                failures[lproj] = "the fixture did not open in this language"
                break
            if source.current() != KOREAN_2SET:
                failures[lproj] = f"the input source read {source.current()!r} after the launch"
                break
            activate_logic()
            if not wait_ready(ax):
                failures[lproj] = "the control bar did not read within the wait after the launch"
                break
            for role, binary in (("control", args.control), ("candidate", args.candidate)):
                driver = E.Driver(binary=binary)
                try:
                    time.sleep(STARTUP)
                    if role == "control":
                        runs[lproj][role] = run_control(driver, ax, source, lproj)
                    else:
                        runs[lproj][role] = run_candidate(ev, driver, ax, source, lproj)
                finally:
                    try:
                        driver.close()
                    except Exception:  # noqa: BLE001 - the rows are already in hand
                        pass
                ev.note(f"1039/{lproj}/{role}", runs[lproj][role])
            if source.current() != KOREAN_2SET:
                failures[lproj] = f"the input source read {source.current()!r} after the candidate"
                break
    finally:
        os.environ.pop(ONLY_CHANNEL_KEY, None)
        with open(APPROVALS, "wb") as handle:
            handle.write(approvals)
        with open(APPROVALS, "rb") as handle:
            ev.restored("1039/operator-approvals-restored-byte-for-byte", handle.read() == approvals)
        try:
            restored = L993.switch_to(L993.RESTORE, force=True)
        except Exception as exc:  # noqa: BLE001 - recorded as a failed restoration
            restored = {"error": f"Korean restoration raised: {exc!r}"}
        restored["language_setting_after_restore"] = L993.language_setting()
        restored["window_names_after_restore"] = L993.window_names()
        restored["ok"] = (restored.get("arrange_window") is not None
                          and restored["language_setting_after_restore"][:1] == [L993.CODES[L993.RESTORE]]
                          and restored["arrange_window"] in (restored["window_names_after_restore"] or []))
        ev.restored("1039/Logic-language-restored-to-Korean", restored["ok"], repr(restored))
        ev.restored("1039/input-source-is-2-Set-Korean-at-the-end", source.current() == KOREAN_2SET,
                    repr(source.current()))
        ev.stop_recording(recording)

    ev.note("1039/failures", failures)
    for lproj in args.lprojs:
        row = runs.get(lproj) or {}
        candidate, control = row.get("candidate") or {}, row.get("control") or {}
        bound = row.get("plain_bindings")
        for name, *_ in TOGGLES + (RECORD,):
            c = dict(candidate.get(name) or {}, op=name, accessibility_first=name in ACCESSIBILITY_FIRST,
                     key_bound=None if bound is None else CHARACTERS[name] in bound)
            k = dict(control.get(name) or {}, op=name)
            ev.falsifiable(f"1039/{lproj}/candidate/{name}", candidate_acted, c, k,
                           "under 2-Set Korean through CGEvent alone the key is posted under ABC, the "
                           "reading changes and comes back, and the source reads 2-Set Korean after; "
                           "for a key Logic leaves unbound, only the switch and the restore",
                           mutation="remove the switch from CGEventChannel.execute (the control binary): "
                                    "the key is refused and nothing changes")
            ev.falsifiable(f"1039/{lproj}/control/{name}", control_refused, k, c,
                           "the build without the switch refuses the key and the reading does not move",
                           mutation="none: this is the positive control; a reading that moved without the "
                                    "switch would fail it and void the candidate check")
    out = ev.write()
    clean = E.is_clean(out)
    print(json.dumps({"written": out, "is_clean": clean, "failures": failures,
                      "korean_restored": restored.get("ok")}, ensure_ascii=False))
    return 0 if clean and not failures else 1


if __name__ == "__main__":
    sys.exit(main())
