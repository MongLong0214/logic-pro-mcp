"""Shared readers and drivers for the live harnesses that post keys through CGEvent (#1039, #1029).

What is here was written for live_1039_plain_letters_under_2set_korean.py and measured there:
- canon labels matched as `AXLocalePolicy` matches them (`matches`);
- Accessibility read from this process (`AX`), and the arrange window found by the title the
  language switch gives, not by AXMainWindow, which is the Marker List window right after a launch;
- the Tracks header rail given the key focus before a key, since Tracks-area commands did nothing
  from the launch's own focus (`focus_tracks`);
- the characters Logic's key command set binds with no modifier, from its preferences
  (`plain_bindings`), and the keyboard input source (`Source`);
- the control-bar checkboxes and the one a canon key names (`control_bar_boxes`, `target_box`);
- a reply's state and channel fields, from `write_result` when a verified transport command wraps
  them (`reply_summary`).

This module drives nothing by itself; a harness that imports it holds LIVE.lock.
"""

import json
import os
import re
import subprocess
import time

HERE = os.path.dirname(os.path.abspath(__file__))
LABELS = os.path.join(HERE, "..", "..", "docs", "locale", "ui-labels.json")
HISERVICES = "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework"
LOGIC_BUNDLE = "com.apple.logic10"
LOGIC_PREFERENCES = os.path.expanduser("~/Library/Preferences/com.apple.logic10.plist")
KOREAN_2SET = "com.apple.inputmethod.Korean.2SetKorean"
SETTLE = 1.2
READY_WAIT = 40.0


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



class Source:
    def __init__(self):
        from logic_input_source import TISRuntime  # Scripts/, which the harnesses put on sys.path
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




def track_header_rows(ax):
    """The rows under the Tracks header rail (canon `trackHeadersDescription`), or None when the
    rail did not read."""
    window = arrange_window(ax)
    if window is None:
        return None
    rail = next((e for e, _ in ax.walk(window, 12)
                 if matches(ax.value(e, "AXDescription"), "trackHeadersDescription")), None)
    if rail is None:
        return None
    return ax.children(rail)


def wait_ready(ax, key="transportCycleControl"):
    """Wait until the control bar reads after a launch: the first readings after Logic opens its
    window came back empty for a while in the #1039 Korean pilot."""
    end = time.monotonic() + READY_WAIT
    while time.monotonic() < end:
        window = arrange_window(ax)
        boxes = control_bar_boxes(ax, window) if window is not None else None
        if boxes and target_box(boxes, key) is not None:
            return True
        time.sleep(1.0)
    return False
