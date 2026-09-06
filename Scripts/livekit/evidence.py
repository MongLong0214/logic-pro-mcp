"""Live-evidence recorder for driving Logic Pro through a built LogicProMCP binary.

A unit test says the code does what its fixtures say. Only a run against the real application says it
does what the user needs. This module is the instrument for that run, and it is deliberately hostile to
its own operator: every affordance here exists because a specific class of false evidence was produced
without it.

What it refuses to let you record:

- **A check made through a blocking modal.** `blocking_modal()` uses the CoreGraphics window list
  plus the narrowly necessary AX modal/sheet reads. Its AX sheet scan is application-wide across
  every window of every running Logic process: a sheet on another document makes this run refuse,
  rather than claiming that the observed document is clear. That can be a conservative false
  positive, but it cannot silently certify a different document while a sheet blocks it. A modal can
  block the current document while leaving application-wide menu items enabled, so an AX value read
  through it is not evidence about the affordance it appears to describe. Only `check()` and
  `falsifiable()` receipts carry this snapshot; notes, captures, visuals, operations, and
  restorations do not claim modal coverage. The summary gate invalidates those CHECK receipts rather
  than preventing a caller from making one.
- **An unsettled capture.** A screenshot taken while Logic is still redrawing shows a state nobody was
  ever in. `shot()` takes frames until two consecutive ones are byte-identical, and marks the record
  `settled: false` if they never converge.
- **A capture straddling two displays.** On a multi-monitor desk a window can span screens and the
  resulting image is not what the user sees. Every capture records which display it fell wholly within.
- **A whole-window diff as a visual assertion.** A full-window comparison changes when the clock ticks.
  `visual()` requires an explicit region and states what it expected to happen there.
- **A check that cannot fail.** `check()` requires you to NAME a mutation you believe would flip it —
  which is a claim, and the field says so (`mutation_claimed`). `falsifiable()` is the form that
  establishes something: it hands the assertion to this module, which runs it against the observation
  AND against a counterexample the author wrote down, and passes only if the first is accepted and the
  second REJECTED. A condition that cannot fail fails there.
- **A cached read presented as live.** `provenance()` records the source and age of any value that did
  not come from a fresh read, and marks it unusable as live evidence.

The ship gate (`~/.claude/scripts/lpm-ship.sh` -> `lpm-live-gate.sh`) reads the document this writes and
refuses the push if any of the above is violated. The gate is the enforcement; this module is what makes
compliance the easy path.

Usage:

    import evidence as E
    E.REPO = "/path/to/worktree"
    E.BIN  = f"{E.REPO}/.build/release/LogicProMCP"

    ev = E.Evidence(HEAD_SHA_40_CHARS, os.environ["LPM_EVIDENCE_ROOT"])
    rec = ev.record_screen()             # start a screen recording of the whole run
    d   = E.Driver()                     # MCP stdio client against the built binary

    before = ev.shot("before", settle_region=REGION)
    body   = d.tool("logic_tracks", "delete", {"index": 3})
    after  = ev.shot("after", settle_region=REGION)

    ev.check("523/the-count-drops-by-one", observed == before_n - 1,
             "Logic's own count readout drops by exactly one",
             f"before={before_n} after={observed}",
             "reverted the post-write inventory guard; this check went green on a delete that never happened")
    ev.visual("523/the-readout-changes", before["file"], after["file"], REGION,
              expect_change=True, why="one marker was deleted")
    ev.stop_recording(rec)
    print(json.dumps(ev.write(), indent=1))

`LPM_EVIDENCE_ROOT` must be an absolute path OUTSIDE every worktree of the repository; the gate refuses
otherwise, because evidence living inside the tree can be rewritten by the thing it is judging.
"""

import hashlib
import json
import os
import re
import shutil
import signal
import subprocess
import tempfile
import sys
import time
import ctypes

# Set by the harness before use.
REPO = ""
BIN = ""

_SETTLE_TRIES = 8
_SETTLE_GAP = 0.35


# The Event tab of the List Editors pane. Measured 2026-08-29 on a Korean Logic, where the four
# list tabs describe themselves `이벤트`, `마커`, `템포`, `조표 및 박자표` — and where the
# collector's own literal `== "Event"` meant it could not find the tab at all.
EVENT_LIST_TAB_NAMES = ["event", "Event", "이벤트", "イベント"]
# The Marker tab, needed only to point the pane somewhere else so a refusal can be observed.
# Measured beside the others on 2026-08-29: `마커`.
MARKER_LIST_TAB_NAMES = ["Marker", "마커", "マーカー"]
# The other two, measured in the same read. They are here so a harness can tell "no list tab is
# selected" from "a tab I do not recognise is selected" — filtering to only the tabs a run drives
# turns the second into the first, and a run that then skips restoration reports itself clean.
OTHER_LIST_TAB_NAMES = ["Tempo", "템포", "テンポ",
                        "Signature", "조표 및 박자표", "調号と拍子記号"]
ALL_LIST_TAB_NAMES = (EVENT_LIST_TAB_NAMES + MARKER_LIST_TAB_NAMES + OTHER_LIST_TAB_NAMES)


# `None` from blocking_modal() means a completed scan found no blocker. A dictionary whose state is
# `cannot_tell` means at least one required detector read did not answer; it is deliberately truthy
# so existing precondition callers refuse it, and summarize() records it separately from a detected
# blocker. Keep the string public: live harnesses can display the reason without guessing a shape.
MODAL_CANNOT_TELL = "cannot_tell"
_MODAL_SNAPSHOT_UNSET = object()


def label_set(name, repo=None):
    """`[canonical] + variants` for one `AXLocalePolicy` LabelSet, read from the Swift source.

    PARSED, not imported — a harness cannot link the product, and shelling out to it would make the
    thing under test supply the labels its own assertion is checked against.

    The limit is worth stating: the harness and the product then read the SAME declaration, so a
    declaration that is wrong for a locale is wrong in both and this comparison cannot see it. What
    it does catch is the case it was written for — Logic rendering a different set of columns than
    the product expects — and it catches it in every language, which a list of English literals in
    a harness does not.
    """
    repo = repo or os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    path = os.path.join(repo, "Sources", "LogicProMCP", "Accessibility", "AXLocalePolicy.swift")
    try:
        text = open(path, encoding="utf-8").read()
    except OSError:
        return None
    # Comments first. Swift `// "위치" is documentation` inside a variants list is not a declared
    # variant, and a regex that cannot see the difference reports one the compiler does not.
    text = re.sub(r"//[^\n]*", "", text)
    m = re.search(r"static let " + re.escape(name) + r"\s*=\s*LabelSet\((.*?)\)\s*\n", text, re.S)
    if not m:
        return None
    body = m.group(1)
    canonical = re.search(r'canonical:\s*"((?:[^"\\]|\\.)*)"', body)
    if not canonical:
        return None
    out = [canonical.group(1)]
    variants = re.search(r"variants:\s*\[(.*?)\]", body, re.S)
    if variants:
        out += re.findall(r'"((?:[^"\\]|\\.)*)"', variants.group(1))
    return out


# ---------------------------------------------------------------------------
# Window geometry
# ---------------------------------------------------------------------------

_NAME_SAFE = re.compile(r"[^A-Za-z0-9._-]")


def _safe_name(raw):
    """A document name that can only ever be a single file inside the head directory.

    `name` used to live only inside the JSON. It is now a PATH COMPONENT, so an unconstrained value
    escapes: `Evidence(..., name="../escaped")` wrote `escaped.evidence.json` in the evidence ROOT,
    outside the head directory, where the gate would never look for it and nothing would notice.
    """
    stem = os.path.basename(str(raw)).strip() or "livekit"
    stem = _NAME_SAFE.sub("_", stem).lstrip(".") or "livekit"
    return stem[:80]


def _running_harness_name():
    """The stem of the script that is running, e.g. `live_608_first_call_is_not_refused`.

    When the entry point cannot be determined — `python3 -c`, a REPL, a wrapper that execs without
    setting `__file__` — this used to fall back to the WORKTREE basename, which is exactly the
    ambiguity #612 is about: two harnesses under one worktree share it and overwrite each other
    again. The fallback now carries the pid, so two such runs cannot collide, and it says in the name
    that it could not identify itself.
    """
    path = getattr(sys.modules.get("__main__"), "__file__", None)
    if path:
        return _safe_name(os.path.splitext(os.path.basename(path))[0])
    return _safe_name(f"unidentified-harness-pid{os.getpid()}")


# The arrange window's title, in every language this repository has measured it in. Logic names it
# after the current view, so an English Logic says `… - Tracks` and a Korean one `… - 트랙`.
#
# This sits beside `logic_window` because its DEFAULT was the English word, and eighteen harnesses
# take that default. Measured 2026-08-29 on a Korean Logic: `logic_window("Tracks")` returned None,
# so `shot` took its no-window branch and recorded `settled: false`, `region: null` and
# `wholly_within: false` — and I read those three as a settling problem and blamed blinking level
# meters. They were one missing translation, and the capture never happened at all.
ARRANGE_WINDOW_TITLES = ["Tracks", "트랙", "トラック"]


def _is_logic_owned_window(window):
    """Whether a CoreGraphics window belongs to Logic, including its measured Korean owner spelling."""
    # Measured 2026-08-17: with Logic running in Korean, `kCGWindowOwnerName` comes back as
    # "Logic Pro" — a NO-BREAK SPACE — while English and Japanese give an ordinary space.
    # An exact compare therefore found ZERO Logic windows on a Korean Logic, and every capture
    # in the run recorded `window: null` while Logic was plainly on screen.
    owner = (window.get("kCGWindowOwnerName") or "").replace(" ", " ")
    return owner == "Logic Pro"


def _on_screen_windows(Quartz):
    """The CoreGraphics window list both on-screen window readers use."""
    return Quartz.CGWindowListCopyWindowInfo(
        Quartz.kCGWindowListOptionOnScreenOnly | Quartz.kCGWindowListExcludeDesktopElements,
        Quartz.kCGNullWindowID)


# Read ONCE, when this module is imported — which is before a harness does anything. Asking again
# at write() time would answer about the moment the document was written rather than the moment the
# readings were taken, and a screen that locked mid-run is exactly the case worth catching.
def screen_is_locked(session=None):
    """Whether the login session's screen is locked, or None when it cannot be read.

    ONE call, one boolean, no heuristics — and the only reading in this file that says what is
    actually true when the session is locked. Measured 2026-09-07 (#797), screen locked, Logic Pro
    running as pid 3574:

        direct AXUIElement, AXWindows of the pid       1   titled 'Logic Pro'
        System Events, `count of windows`              0
        CGWindowList, on-screen, owner Logic Pro       1   name '', 260x282
        logic_window()                                 None
        _production_ax_modal_signals()                 _ModalReadError('AX sheet descendant
                                                        search reached depth 32')

    Three readings of the same application at the same moment, and none of them mentions the lock.
    The System Events answer says "Logic has no windows" and the precondition names a recursion
    guard; both are plausible product defects, and on 2026-09-06 the first was believed and Logic
    was force-restarted on the strength of it, which changed nothing.

    None rather than False when the dictionary cannot be read: a harness must be able to tell "not
    locked" from "could not ask", the same distinction `is_clean` already makes with `cannot_tell`.

    `session` is injectable so the MAPPING can be tested. Against a real machine the only available
    assertion is "returns one of three values", which a function that always answers `False`
    satisfies — and that is precisely the mutation this has to be able to fail on.
    """
    if session is None:
        try:
            import Quartz
            session = Quartz.CGSessionCopyCurrentDictionary()
        except Exception:  # noqa: BLE001 - no Quartz means the question cannot be asked
            return None
    if not session:
        return None
    return bool(session.get("CGSSessionScreenIsLocked", False))


_SESSION_LOCKED = screen_is_locked()


def logic_window(title_contains=None):
    """The on-screen bounds of a Logic window, via CoreGraphics rather than AX.

    Deliberately not an AX read: the harness must be able to see the window even when the AX tree is
    exactly what is under test. Returns None when no matching window is on screen.

    `title_contains` defaults to every known spelling of the arrange window rather than to one of
    them. A caller naming a specific window still gets exactly that.
    """
    if title_contains is None:
        for candidate in ARRANGE_WINDOW_TITLES:
            found = logic_window(candidate)
            if found:
                return found
        return None
    try:
        import Quartz
    except ImportError:
        return None
    wins = _on_screen_windows(Quartz)
    for w in wins or []:
        if not _is_logic_owned_window(w):
            continue
        name = w.get("kCGWindowName") or ""
        if title_contains and title_contains not in name:
            continue
        b = w["kCGWindowBounds"]
        return {"id": w["kCGWindowNumber"], "title": name,
                "x": int(b["X"]), "y": int(b["Y"]),
                "w": int(b["Width"]), "h": int(b["Height"])}
    return None


class _ModalReadError(RuntimeError):
    """An AX read that did not answer, kept separate from a completed empty search."""

    def __init__(self, site, status=None):
        self.site = site
        self.status = status
        suffix = "" if status is None else f" (AX status {status!r})"
        super().__init__(site + suffix)


def _modal_cannot_tell(signal, reason):
    """The explicit third blocking_modal state; None is reserved for a completed clear scan."""
    return {"state": MODAL_CANNOT_TELL, "kind": MODAL_CANNOT_TELL,
            "signal": signal, "reason": reason}


class _AXRuntime:
    """The small C Accessibility bridge PyObjC does not vend through this Quartz installation."""

    _UTF8 = 0x08000100
    _ATTRIBUTE_UNSUPPORTED = -25205
    _NO_VALUE = -25212

    def __init__(self):
        try:
            self.ax = ctypes.CDLL(
                "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices")
            self.cf = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
        except OSError as exc:
            raise _ModalReadError(f"could not load the Accessibility framework: {exc!r}") from exc

        self.ax.AXUIElementCreateApplication.restype = ctypes.c_void_p
        self.ax.AXUIElementCreateApplication.argtypes = (ctypes.c_int,)
        self.ax.AXUIElementCopyAttributeValue.restype = ctypes.c_int
        self.ax.AXUIElementCopyAttributeValue.argtypes = (
            ctypes.c_void_p, ctypes.c_void_p, ctypes.POINTER(ctypes.c_void_p))
        self.cf.CFStringCreateWithCString.restype = ctypes.c_void_p
        self.cf.CFStringCreateWithCString.argtypes = (ctypes.c_void_p, ctypes.c_char_p, ctypes.c_uint32)
        self.cf.CFStringGetLength.restype = ctypes.c_long
        self.cf.CFStringGetLength.argtypes = (ctypes.c_void_p,)
        self.cf.CFStringGetTypeID.restype = ctypes.c_ulong
        self.cf.CFStringGetMaximumSizeForEncoding.restype = ctypes.c_long
        self.cf.CFStringGetMaximumSizeForEncoding.argtypes = (ctypes.c_long, ctypes.c_uint32)
        self.cf.CFStringGetCString.restype = ctypes.c_bool
        self.cf.CFStringGetCString.argtypes = (ctypes.c_void_p, ctypes.c_char_p, ctypes.c_long, ctypes.c_uint32)
        self.cf.CFArrayGetCount.restype = ctypes.c_long
        self.cf.CFArrayGetCount.argtypes = (ctypes.c_void_p,)
        self.cf.CFArrayGetValueAtIndex.restype = ctypes.c_void_p
        self.cf.CFArrayGetValueAtIndex.argtypes = (ctypes.c_void_p, ctypes.c_long)
        self.cf.CFGetTypeID.restype = ctypes.c_ulong
        self.cf.CFGetTypeID.argtypes = (ctypes.c_void_p,)
        self.cf.CFArrayGetTypeID.restype = ctypes.c_ulong
        self.cf.CFBooleanGetTypeID.restype = ctypes.c_ulong
        self.cf.CFBooleanGetValue.restype = ctypes.c_bool
        self.cf.CFBooleanGetValue.argtypes = (ctypes.c_void_p,)
        self.cf.CFRelease.argtypes = (ctypes.c_void_p,)
        self._owned = []

    def application(self, pid):
        element = self.ax.AXUIElementCreateApplication(pid)
        if not element:
            raise _ModalReadError("could not create an AX application element")
        self._owned.append(element)
        return element

    def attribute(self, element, attribute, site):
        name = self.cf.CFStringCreateWithCString(None, attribute.encode("utf-8"), self._UTF8)
        if not name:
            raise _ModalReadError(f"{site}: could not create a CFString")
        value = ctypes.c_void_p()
        try:
            status = self.ax.AXUIElementCopyAttributeValue(element, name, ctypes.byref(value))
        finally:
            self.cf.CFRelease(name)
        if status != 0:
            raise _ModalReadError(site, status)
        if not value.value:
            raise _ModalReadError(f"{site}: successful but empty payload")
        self._owned.append(value.value)
        return value.value

    def elements(self, value, site):
        if self.cf.CFGetTypeID(value) != self.cf.CFArrayGetTypeID():
            raise _ModalReadError(f"{site}: successful but non-array payload")
        return [self.cf.CFArrayGetValueAtIndex(value, index)
                for index in range(self.cf.CFArrayGetCount(value))]

    def text(self, value, site):
        if self.cf.CFGetTypeID(value) != self.cf.CFStringGetTypeID():
            raise _ModalReadError(f"{site}: successful but non-string payload")
        length = self.cf.CFStringGetLength(value)
        capacity = self.cf.CFStringGetMaximumSizeForEncoding(length, self._UTF8) + 1
        if capacity <= 0:
            raise _ModalReadError(f"{site}: invalid CFString length")
        buffer = ctypes.create_string_buffer(capacity)
        if not self.cf.CFStringGetCString(value, buffer, capacity, self._UTF8):
            raise _ModalReadError(f"{site}: could not decode CFString")
        return buffer.value.decode("utf-8", "replace")

    def boolean(self, value, site):
        if self.cf.CFGetTypeID(value) != self.cf.CFBooleanGetTypeID():
            raise _ModalReadError(f"{site}: successful but non-boolean payload")
        return bool(self.cf.CFBooleanGetValue(value))

    def definitive_absence(self, status):
        return status in {self._ATTRIBUTE_UNSUPPORTED, self._NO_VALUE}

    def close(self):
        for value in reversed(self._owned):
            self.cf.CFRelease(value)
        self._owned.clear()


def _ax_optional_title(ax, element):
    """A title helps correlate CG and AX records, but its absence does not veto a known blocker."""
    try:
        return ax.text(ax.attribute(element, "AXTitle", "AXTitle"), "AXTitle")
    except _ModalReadError:
        return ""


def _first_ax_sheet(ax, window, max_depth=32):
    """Find a sheet on one host through AXSheets or its descendant tree.

    Logic can report AXSheets as unsupported even while New Track is visible. AXSheets is therefore a
    cheap positive only; descendants are still searched for an AXSheet role. A direct AXSheets
    candidate whose AXRole cannot be read, or a failed descendant read, is not changed into an empty
    branch because that would certify a clear document without having searched it.
    """
    unreadable = None
    try:
        direct = ax.elements(ax.attribute(window, "AXSheets", "AXSheets"), "AXSheets")
    except _ModalReadError:
        # AXSheets is non-authoritative. Logic has measured it as unsupported even while the sheet
        # is visible, so neither an AXSheets error nor a malformed AXSheets value may veto the
        # descendant traversal that actually decides this detector's sheet signal.
        direct = []

    for candidate in direct:
        try:
            role = ax.text(ax.attribute(candidate, "AXRole", "AXSheets candidate AXRole"),
                           "AXSheets candidate AXRole")
        except _ModalReadError as exc:
            # A direct sheet is not necessarily duplicated under AXChildren. Keep this unreadable
            # candidate so a later clear scan returns cannot-tell instead of pretending it was not
            # there. A positively identified sheet below still outranks an unreadable sibling.
            if unreadable is None:
                unreadable = exc
            continue
        if role == "AXSheet":
            return candidate

    stack = [(window, 0)]
    while stack:
        current, depth = stack.pop()
        try:
            children = ax.elements(ax.attribute(current, "AXChildren", "AXChildren"), "AXChildren")
        except _ModalReadError as exc:
            # A confirmed no-children status is a completed leaf. Any other status leaves this
            # branch unreadable, but a later sibling can still positively identify a sheet.
            if not ax.definitive_absence(exc.status) and unreadable is None:
                unreadable = exc
            continue
        if depth >= max_depth:
            if children:
                raise _ModalReadError(f"AX sheet descendant search reached depth {max_depth}")
            continue
        for child in children:
            try:
                role = ax.text(ax.attribute(child, "AXRole", "AX descendant AXRole"),
                               "AX descendant AXRole")
            except _ModalReadError as exc:
                if unreadable is None:
                    unreadable = exc
                continue
            if role == "AXSheet":
                return child
            stack.append((child, depth + 1))
    if unreadable is not None:
        raise unreadable
    return None


def _production_ax_modal_signals():
    """Return app-wide modal AX windows and sheets for every running Logic process.

    This deliberately does not bind a sheet to the document a harness is about to inspect. Any sheet
    on any Logic window therefore makes the detector report a blocker. The cost is a conservative
    refusal when another document has a sheet; the benefit is that this generic precondition never
    labels the application clear while its AX sheet enumeration is scoped to the wrong window.
    """
    try:
        from AppKit import NSWorkspace
        applications = NSWorkspace.sharedWorkspace().runningApplications()
    except Exception as exc:  # noqa: BLE001 - no workspace means the off-screen check did not run
        raise _ModalReadError(f"could not enumerate running Logic applications: {exc!r}") from exc

    logic_apps = [app for app in applications
                  if app.bundleIdentifier() in {"com.apple.logic10", "com.apple.mobilelogic"}]
    ax = _AXRuntime()
    try:
        first_unreadable = None
        for app in logic_apps:
            app_element = ax.application(app.processIdentifier())
            windows = ax.elements(ax.attribute(app_element, "AXWindows", "AXWindows"), "AXWindows")
            for window in windows:
                title = _ax_optional_title(ax, window)
                # A positively identified sheet already proves this document is blocked. Do not
                # discard that fact because AXModal on its ordinary host fails a later read: the
                # product's reconciliation takes the same "found outranks unreadable sibling"
                # direction for sheets.
                try:
                    sheet = _first_ax_sheet(ax, window)
                except _ModalReadError as exc:
                    sheet = None
                    if first_unreadable is None:
                        first_unreadable = exc
                if sheet is not None:
                    return {"modal_windows": [],
                            "sheets": [{"host_title": title, "pid": app.processIdentifier()}]}
                try:
                    modal = ax.boolean(ax.attribute(window, "AXModal", "AXModal"), "AXModal")
                except _ModalReadError as exc:
                    if first_unreadable is None:
                        first_unreadable = exc
                    continue
                if modal:
                    return {"modal_windows": [{"title": title, "pid": app.processIdentifier()}],
                            "sheets": []}
        if first_unreadable is not None:
            raise first_unreadable
        return {"modal_windows": [], "sheets": []}
    finally:
        ax.close()


def _normal_ax_modal_signals(signals):
    """Validate the small test seam as strictly as production validates a completed AX scan."""
    if not isinstance(signals, dict):
        raise _ModalReadError("AX modal query returned no signal object")
    modal_windows, sheets = signals.get("modal_windows"), signals.get("sheets")
    if not isinstance(modal_windows, list) or not isinstance(sheets, list):
        raise _ModalReadError("AX modal query returned malformed signal lists")
    if not all(isinstance(item, dict) for item in modal_windows + sheets):
        raise _ModalReadError("AX modal query returned malformed signal entries")
    return signals


def _coregraphics_modal_panels(Quartz, windows):
    """The on-screen modal-panel-level candidates, before AX confirms that they are modal."""
    modal_panel_level = Quartz.CGWindowLevelForKey(Quartz.kCGModalPanelWindowLevelKey)
    out = []
    for window in windows:
        if not _is_logic_owned_window(window):
            continue
        layer = window.get(Quartz.kCGWindowLayer)
        try:
            if int(layer) != int(modal_panel_level):
                continue
        except (TypeError, ValueError):
            continue
        candidate = {"id": window.get(Quartz.kCGWindowNumber),
                     "title": window.get(Quartz.kCGWindowName) or "", "layer": int(layer)}
        # NOT `isinstance(b, dict)`: CoreGraphics returns an NSDictionary proxy, which is
        # subscriptable but not a Python dict. Geometry identifies a detected panel more usefully,
        # but cannot be allowed to erase the already-read level signal when it is malformed.
        bounds = window.get(Quartz.kCGWindowBounds)
        if bounds is not None:
            try:
                candidate.update({"x": int(bounds["X"]), "y": int(bounds["Y"]),
                                  "w": int(bounds["Width"]), "h": int(bounds["Height"])})
            except (KeyError, TypeError, ValueError):
                pass
        out.append(candidate)
    return out


def _same_modal_window(panel, window, panel_count, modal_count):
    """Correlate the two APIs only when a title or unambiguous singleton makes it honest."""
    panel_title, ax_title = panel.get("title") or "", window.get("title") or ""
    return ((bool(panel_title) and panel_title == ax_title)
            or (panel_count == 1 and modal_count == 1))


# kAXErrorCannotComplete. Measured 2026-08-31: a scan taken while Logic was busy answering
# `system.refresh_cache` came back cannot-tell with `AX status -25204`, and five scans a moment
# later were all clean. That code means the request did not finish in time, which is a statement
# about timing and not about the screen — so it is the ONE error worth asking again about. Every
# other failure stays cannot-tell on the first answer: a scan that failed for a reason other than
# a timeout has no reason to succeed on a retry, and retrying it would only blur a real refusal.
AX_ERROR_CANNOT_COMPLETE = -25204
_MODAL_RETRY_DELAY_SEC = 0.35


def blocking_modal(lister=None, ax_lister=None, _attempt=0):
    """Describe a detected Logic blocker, `None` after a clear scan, or explicit cannot-tell.

    CoreGraphics is still the screen-side signal: it observes the rendered modal-panel level without
    relying on the AX tree under test. `kCGWindowListOptionOnScreenOnly` is deliberately retained.
    Its known limitation is that it cannot see an inactive-Space/off-screen panel; widening it would
    also report windows on other Spaces that are not blocking the current one. The AX window/sheet
    signal covers a running process beyond that list, but is weaker exactly when AX itself is broken.
    AX sheets are application-wide rather than bound to the document a harness will inspect, so a
    sheet on another Logic document is a deliberate conservative refusal. An unreadable AXRole on a
    directly enumerated sheet is likewise cannot-tell, not a completed clear scan.

    A panel level is not modality — a modeless panel can occupy it — so AXModal confirms that a
    CoreGraphics candidate actually blocks. Sheets need AX outright: their host reports AXModal=false,
    while the AXSheet below it blocks that document. `lister` and `ax_lister` are test seams; a seam
    must return an empty list/object for a completed clear scan, never None.
    """
    try:
        import Quartz
    except ImportError:
        return _modal_cannot_tell("coregraphics", "could not import Quartz")

    try:
        windows = lister() if lister is not None else _on_screen_windows(Quartz)
    except Exception as exc:  # noqa: BLE001 - an unread window list is not a clear desktop
        return _modal_cannot_tell("coregraphics", f"could not read the window list: {exc!r}")
    if windows is None:
        return _modal_cannot_tell("coregraphics", "could not read the window list")
    try:
        panels = _coregraphics_modal_panels(Quartz, list(windows))
    except Exception as exc:  # noqa: BLE001
        return _modal_cannot_tell("coregraphics", f"could not interpret the window list: {exc!r}")

    try:
        raw_signals = ax_lister() if ax_lister is not None else _production_ax_modal_signals()
        signals = _normal_ax_modal_signals(raw_signals)
    except _ModalReadError as exc:
        return _modal_retry_or_give_up(
            _modal_cannot_tell("accessibility", str(exc)), lister, ax_lister, _attempt)
    except Exception as exc:  # noqa: BLE001 - avoid making an AX outage look like no sheet
        return _modal_retry_or_give_up(
            _modal_cannot_tell("accessibility", f"AX modal query failed: {exc!r}"),
            lister, ax_lister, _attempt)

    if signals["sheets"]:
        sheet = signals["sheets"][0]
        return {"state": "detected", "kind": "sheet", "signal": "ax_sheet",
                "host_title": sheet.get("host_title") or "", "pid": sheet.get("pid")}

    modal_windows = signals["modal_windows"]
    for panel in panels:
        for window in modal_windows:
            if _same_modal_window(panel, window, len(panels), len(modal_windows)):
                return {**panel, "state": "detected", "kind": "modal_panel",
                        "signal": "coregraphics_modal_panel_level+ax_modal"}
    if modal_windows:
        window = modal_windows[0]
        return {"state": "detected", "kind": "modal_window", "signal": "ax_modal",
                "title": window.get("title") or "", "pid": window.get("pid")}
    return None


def _modal_retry_or_give_up(answer, lister, ax_lister, attempt):
    """Ask once more, but ONLY when the scan timed out.

    `kAXErrorCannotComplete` (-25204) means the AX request did not finish in time — a statement
    about timing, not about the screen. Measured 2026-08-31: a scan taken while Logic was busy
    answering `system.refresh_cache` returned cannot-tell with that code, and five scans a moment
    later were all clean, so a run was marked unusable by a busy instant rather than by a blocker.

    Every other failure keeps its first answer. A scan that failed for a reason other than a
    timeout has no reason to succeed on a retry, and retrying it would blur a real refusal into a
    pass. Test seams never retry: a seam's answer is the answer under test.
    """
    if attempt != 0 or lister is not None or ax_lister is not None:
        return answer
    if f"{AX_ERROR_CANNOT_COMPLETE}" not in str(answer.get("reason", "")):
        return answer
    time.sleep(_MODAL_RETRY_DELAY_SEC)
    return blocking_modal(_attempt=1)


def _displays():
    try:
        import Quartz
    except ImportError:
        return []
    err, ids, _ = Quartz.CGGetActiveDisplayList(16, None, None)
    if err:
        return []
    out = []
    for i, did in enumerate(ids):
        r = Quartz.CGDisplayBounds(did)
        out.append({"display": i,
                    "bounds": [int(r.origin.x), int(r.origin.y),
                               int(r.size.width), int(r.size.height)]})
    return out


def _display_containing(win):
    """Which display wholly contains this window, if any.

    A window spanning two screens produces a capture that matches nothing the user saw, so the answer
    `wholly_within: False` is recorded rather than silently accepted.
    """
    for d in _displays():
        x, y, w, h = d["bounds"]
        if win["x"] >= x and win["y"] >= y and \
           win["x"] + win["w"] <= x + w and win["y"] + win["h"] <= y + h:
            return {**d, "wholly_within": True}
    ds = _displays()
    return {**(ds[0] if ds else {"display": -1, "bounds": []}), "wholly_within": False}


# ---------------------------------------------------------------------------
# MCP stdio driver
# ---------------------------------------------------------------------------

class Driver:
    """A minimal MCP stdio client against the built binary.

    Speaks to the same artifact the gate hashes, so the evidence and the shipped code cannot diverge.
    """

    def __init__(self, binary=None, timeout=180):
        self.binary = binary or BIN
        self.timeout = timeout
        self._id = 0
        # The server's diagnostics go to stderr (`Logger.swift:60`). Discarding them made every
        # `Log.info` in the product unobservable from a live document -- code could say "this
        # fallback fired" and no harness could assert it fired or did not. Measured 2026-08-21:
        # that is exactly the state the two #628 branches were in.
        #
        # A FILE, not a PIPE. Nothing drains this stream while `_read` blocks on stdout, so a pipe
        # would deadlock the server once the buffer filled -- silently, and only on the runs that
        # logged the most.
        self._stderr_file = tempfile.NamedTemporaryFile(
            prefix="lpm-server-stderr-", suffix=".log", delete=False)
        self._stderr_path = self._stderr_file.name
        # `Log` gates on LOG_LEVEL (`Logger.swift:69`), which the driver would otherwise INHERIT.
        # At LOG_LEVEL=warn every `Log.info` vanishes while an unrelated warning still fills the
        # file -- so a harness asserting absence would see a non-empty log and conclude the channel
        # carried, when the only lines that could have carried were suppressed. Pinned, not inherited.
        env = dict(os.environ, LOG_LEVEL="info")
        self.proc = subprocess.Popen(
            [self.binary], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=self._stderr_file, text=True, bufsize=1, env=env)
        self._send("initialize", {
            "protocolVersion": "2024-11-05", "capabilities": {},
            "clientInfo": {"name": "livekit", "version": "1"}})
        self._notify("notifications/initialized")

    def _write(self, obj):
        self.proc.stdin.write(json.dumps(obj) + "\n")
        self.proc.stdin.flush()

    def _read(self):
        deadline = time.time() + self.timeout
        while time.time() < deadline:
            line = self.proc.stdout.readline()
            if not line:
                return None
            line = line.strip()
            if not line:
                continue
            try:
                return json.loads(line)
            except ValueError:
                continue
        return None

    def _notify(self, method, params=None):
        self._write({"jsonrpc": "2.0", "method": method, "params": params or {}})

    @staticmethod
    def operation_of(method, params, response=None):
        """The operation a JSON-RPC call drives, as `(name, command, params)`, or None.

        Pulled out of `_send` so the rule is checkable without a server. Both methods below reach
        the product over the same connection, which is what `operations_driven` claims to count;
        counting only `tools/call` made the clause narrower than its own docstring and left a
        resource-only harness unable ever to be clean. #769.

        A resource read that came back an ERROR is not counted. A review pointed out that
        `{"uri": "logic://does-not-exist"}` otherwise scored as having touched the product, which is
        the opposite of what the clause is for: reading a URI the server rejects reaches the
        dispatcher and nothing else. Tool calls stay counted whatever they return, and that
        asymmetry is deliberate — a tool call that errors still ran an operation against Logic,
        while a rejected URI names no resource at all.

        What this still does NOT establish, stated so nobody reads it as more: some resources are
        served without touching Logic (`logic://system/operations` is a static catalogue). Counting
        one rules out a run that touched NOTHING; it does not show the run drove its own subject.
        """
        if not isinstance(params, dict):
            return None
        if method == "tools/call":
            args = params.get("arguments") or {}
            return (params.get("name"), args.get("command"), args.get("params"))
        if method == "resources/read":
            if isinstance(response, dict) and response.get("error") is not None:
                return None
            return (params.get("uri"), "resources/read", None)
        return None

    def _record_operation(self, name, command, params, body):
        """Put a driven operation in the document, however it was sent.

        `tool()` is not the only path: a harness that needs the full JSON-RPC envelope calls `_send`
        directly, and the very first run under this recording showed why that matters — the harness
        drove ONE operation through `tool()` and the operation it was actually about through `_send`,
        so `operations_driven` read 1 and the subject of the run was absent from its own receipt.
        """
        if Evidence.current is None:
            return
        Evidence.current.records.append({
            "kind": "operation",
            "tool": name,
            "command": command,
            "params": params or {},
            "response": {k: body.get(k) for k in
                         ("state", "success", "error", "hint", "verified", "write_attempted")}
            if isinstance(body, dict) else {"raw": str(body)[:400]},
        })

    def _send(self, method, params=None):
        self._id += 1
        self._write({"jsonrpc": "2.0", "id": self._id, "method": method, "params": params or {}})
        raw = self._read()
        # Record here as well as in `tool()`, because a harness that needs the full envelope calls
        # this directly — and the first run under this recording proved it: the operation the harness
        # was ABOUT went through `_send` and was absent from the document, while a warm-up call made
        # through `tool()` was the only thing `operations_driven` counted.
        driven = Driver.operation_of(method, params, raw)
        if driven is not None:
            name, command, op_params = driven
            self._record_operation(name, command, op_params,
                                   _body(raw) if method == "tools/call" else raw)
        return raw

    def tool(self, name, command, params=None):
        """Call a tool and return its parsed body.

        Arguments nest under `params`, matching the wire shape the server actually accepts.

        The call is recorded in the evidence document by `_send`, not here — a harness that needs the
        full JSON-RPC envelope bypasses this wrapper, and recording in both places would double-count
        everything that does come through it.
        """
        args = {"command": command}
        if params is not None:
            args["params"] = params
        return _body(self._send("tools/call", {"name": name, "arguments": args}))

    def resource(self, uri):
        raw = self._send("resources/read", {"uri": uri})
        try:
            return json.loads(raw["result"]["contents"][0]["text"])
        except (KeyError, IndexError, TypeError, ValueError):
            return {}

    def get(self, uri, key, default=None):
        return self.resource(uri).get(key, default)

    def server_log(self):
        """Everything the server has written to stderr so far.

        Returns "" when the file is unreadable, which is indistinguishable from a server that logged
        nothing -- so a caller asserting ABSENCE must pair this with a control proving the channel
        carries at all. `server_logged` returns that control; prefer it over this.
        """
        try:
            self._stderr_file.flush()
            with open(self._stderr_path, "r", errors="replace") as fh:
                return fh.read()
        except Exception:
            return ""

    def server_logged(self, needle, since=0):
        """(present, channel_is_live) -- the second value is the control.

        `since` is a byte offset from a previous `len(server_log())`, so a caller can ask about the
        window AFTER something it did rather than about the whole run. Without it every later read
        still sees the earlier lines, and "nothing was logged by the write" is indistinguishable
        from "nothing was logged by the read either" -- the check reads as scoped and is not.

        `channel_is_live` requires an `[INFO]` line, not merely a non-empty file. A log holding only
        warnings proves the stream is connected and proves nothing about whether an INFO line could
        have arrived, which is the level every caller of this asserts absence at.
        """
        log = self.server_log()
        window = log[since:] if since else log
        return (needle in window, "[INFO]" in log)

    def close(self):
        try:
            self.proc.terminate()
            self.proc.wait(timeout=5)
        except Exception:
            try:
                self.proc.kill()
            except Exception:
                pass
        # `delete=False` is required -- the server holds this file open and Python must not remove
        # it underneath. That makes cleanup THIS function's job: without it every Driver in a run
        # leaves a descriptor and a file behind, and a long harness accumulates both.
        for step in (self._stderr_file.close, lambda: os.unlink(self._stderr_path)):
            try:
                step()
            except Exception:
                pass


def _body(raw):
    if not raw or "result" not in raw:
        return {"_transport_error": raw}
    res = raw["result"]
    if res.get("structuredContent") is not None:
        return res["structuredContent"]
    text = "".join(c.get("text", "") for c in res.get("content", []))
    try:
        return json.loads(text)
    except ValueError:
        return {"_text": text}


def artifact_answered(body):
    """Whether a parsed tool body came from an answered transport request.

    `_body(None)` deliberately preserves the failed transport as a non-empty dictionary so a receipt
    can show what went wrong. A bare truthiness check on that dictionary turns a dead transport into
    an answered artifact, so harnesses must use this predicate for that question instead.
    """
    return isinstance(body, dict) and "_transport_error" not in body


# ---------------------------------------------------------------------------
# Evidence document
# ---------------------------------------------------------------------------

# An AXDescription is LOCALIZED, and not uniformly. Measured on Logic 12.3, 2026-08-21, by running
# the same window under `AppleLanguages -array en` and `-array ko`:
#
#     Tracks contents  ->  트랙 콘텐츠          Library    ->  라이브러리
#     Tracks header    ->  트랙 헤더            Mixer      ->  믹서
#     Tracks           ->  트랙                 Inspector  ->  인스펙터
#     Step Sequencer   ->  Step Sequencer      <- NOT translated
#
# That last row is why this is a measured table and not a rule. Some descriptions translate and
# some do not, so neither "they are stable identifiers" nor "they are all localized" is safe — and
# the first of those is exactly what a comment in `live_519_region_op_on_a_localized_logic` used to
# claim. A Korean run disproved it: the canvas lookup found nothing and the harness could not take
# a capture, on the one run where the locale was the entire point.
#
# ONLY measured pairs belong here. An unmeasured locale must fail to resolve, loudly, rather than
# be guessed at — guessing localized labels is the defect #519 exists to remove from the product,
# and a harness is not exempt from it.
AX_REGION_LABELS = {
    # Measured 2026-08-29: absent until then, so `located_band("Control Bar", ...)` answered
    # `no element with that exact AXDescription` on a Korean Logic and three harnesses failed a
    # precondition about a window frame. Every other region in this table already had its row —
    # this was one missing line, not a missing mechanism.
    "Control Bar": ["컨트롤 막대", "コントロールバー"],
    # The Japanese column below is measured, not translated: every string is a verbatim
    # AXDescription from the ja-JP arrange census of 2026-09-05 (Logic 12.3 build 6674), filed
    # under docs/observations/evidence/. Until then `Control Bar` was the only row with one, so on
    # a Japanese Logic `located_band` answered "no element with that exact AXDescription" for every
    # other selector — 26 harnesses pass one of them and would have failed a precondition about a
    # window frame. The same failure #778 reports for the product, one layer up.
    #
    # The three extra ASCII spellings on the next row are there for the reason the `Tracks header`
    # row lists its own: the policy declares four and nothing here knows which one a given Logic
    # renders, so a spelling the product would match must be one the locator can try.
    "Tracks contents": ["트랙 콘텐츠", "トラックコンテンツ",
                        "track content", "track contents", "tracks content"],
    # Four ASCII spellings because the policy declares four and nothing here knows which one a
    # given Logic renders — measured `Tracks header` in English 12.x, `트랙 헤더` in Korean. The
    # alias guard found the other three unreachable: the policy claimed to know them and the
    # locator would never have tried them.
    "Tracks header": ["트랙 헤더", "track headers", "track header", "tracks headers", "トラックヘッダ"],
    "Tracks": ["트랙", "トラック"],
    "Library": ["라이브러리", "ライブラリ"],
    "Mixer": ["믹서", "ミキサー"],
    "Inspector": ["인스펙터", "インスペクタ"],
    # No row at all until now, and two harnesses ask for it by this name — so on any Logic that is
    # not English they were locating nothing. The Korean form is the policy's; the Japanese one is
    # measured, and it is `再生ヘッドの位置` rather than the `再生ヘッド位置` the policy carried.
    "Playhead Position": ["재생헤드 위치", "再生ヘッドの位置"],
}


class Evidence:
    """Accumulates records and writes `<root>/<head>/evidence.json`.

    `head` must be the FULL 40-character SHA. The gate looks the directory up by that exact name, and a
    short SHA fails it with a message that reads like missing evidence rather than a misfiled path.
    """

    # The Evidence in play, so `Driver` can record what it drove without every harness threading it
    # through. Set on construction; a harness that builds two Evidences gets the later one, which is
    # the only sensible reading of "the run".
    current = None

    # The surfaces a document may declare. Declaring one is a claim about the CHANGE under proof,
    # made by the harness author, and `is_clean` reads it. There is deliberately no third value: a
    # run that cannot say which it is has not thought about what it is proving.
    SURFACES = ("ui", "non_ui")

    def __init__(self, head, root, name=None, surface=None):
        if surface is not None and surface not in self.SURFACES:
            raise ValueError(f"surface must be one of {self.SURFACES}, not {surface!r}")
        if not re.fullmatch(r"[0-9a-f]{40}", head or ""):
            # Not fatal: exploratory runs use a label. The gate will simply not find it, which is correct.
            pass
        self.head = head
        self.dir = os.path.join(root, head)
        os.makedirs(self.dir, exist_ok=True)
        # #612: the document used to be named after the WORKTREE, so two harnesses run at the same
        # head both called themselves `lpm-wt-608` and there was no field saying which script wrote
        # it. Name it after the running script instead, and key the file by that name too — see
        # `write()`.
        self.name = _safe_name(name) if name else _running_harness_name()
        self.records = []
        self._window_points = None
        # #754. A change with no surface in Logic's UI cannot earn captures, visual assertions or a
        # recording — there is nothing to photograph — and `is_clean` used to require all three of
        # every run. A harness that proves such a change says so HERE, up front, as a record the
        # summary can read; it is not inferred from which counters happen to be zero, because "the
        # counters are zero" is also what a harness that did nothing looks like.
        if surface is not None:
            self.records.append({"kind": "declaration", "surface": surface})
        Evidence.current = self

    # -- locating a band ----------------------------------------------------

    def located_band(self, *selector):
        """`(band, subject)` for a region named by AXDescription, or `(None, None)`.

        A rectangle written as four numbers is not defined by its content. The five harnesses that
        shared `(0, 0.10h, 0.20w, 0.80h)` were all claiming something about the track-header rail,
        and measured on 2026-08-20 with the Library pane open that rectangle lies 94% inside the
        LIBRARY: the rail sits at x=603. The band was right in the layout it was written in and
        wrong in the next one, and nothing in the run could say which.

        So the band is resolved from the live tree and the `subject` comes back off the element
        that was found, not off the request — which is what makes it evidence rather than a label.

        `(None, None)` on any failure, INCLUDING an ambiguous description, which the tool reports
        as an error with all its candidates. Callers must treat that as a red precondition; before
        #634 a `None` band silently became a whole-image comparison that passed.
        """
        source = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ax_control_bar_band.swift")
        tool = os.path.join(self.dir, "ax_control_bar_band")
        if not os.path.exists(tool):
            built = subprocess.run(["swiftc", "-O", source, "-o", tool], capture_output=True)
            if built.returncode != 0:
                self.note("located_band/build-failed",
                          {"selector": list(selector),
                           "stderr": (built.stderr or b"").decode("utf-8", "replace")[:400]})
                return None, None

        def refuse(why, r=None):
            # A refusal that says nothing is a wall. Every one of these has been mistaken for a
            # different failure at least once: an ambiguous description reads exactly like a
            # missing element, and both read like the tool not having run at all.
            self.note("located_band/refused",
                      {"selector": list(selector), "why": why,
                       "rc": None if r is None else r.returncode,
                       "stdout": "" if r is None else (r.stdout or "")[:400],
                       "stderr": "" if r is None else (r.stderr or "")[:400]})
            return None, None

        # The requested name first, then the measured translations of it. Not a fallback in the
        # sense this file spends so much effort removing — each candidate is an exact match against
        # a description read off a live window, and a name nobody has measured is simply absent
        # from the table and cannot be tried.
        wanted = selector[0] if selector else ""
        candidates = [wanted] + [alt for alt in AX_REGION_LABELS.get(wanted, []) if alt != wanted]
        r = None
        payload = {}
        for candidate in candidates:
            r = subprocess.run([tool, candidate, *selector[1:]], capture_output=True, text=True)
            try:
                payload = json.loads(r.stdout or "{}")
            except ValueError:
                return refuse("the tool printed something that is not JSON", r)
            if isinstance(payload.get("band"), list):
                break
            # An AMBIGUOUS name is an answer, not a miss: trying the next language's word for it
            # would be answering a different question than the one that just failed.
            if payload.get("matches"):
                break
        band = payload.get("band")
        if not (isinstance(band, list) and len(band) == 4):
            return refuse(payload.get("error") or "no band in the tool's answer", r)
        if payload.get("description") and payload["description"] != wanted:
            # Which language's label actually matched. Silence here would let a run claim it
            # watched `Tracks header` when what it found was `트랙 헤더` — the same region, but the
            # record should say which word was on screen.
            self.note("located_band/matched-a-localized-label",
                      {"requested": wanted, "matched": payload["description"]})
        subject = payload.get("description")
        if not isinstance(subject, str) or not subject.strip():
            return refuse("a band with no description cannot be named", r)
        attempts = payload.get("windowAttempts")
        if isinstance(attempts, int) and attempts > 1:
            # Absorbed, not hidden: the lookup succeeded, and it took more than one read of the AX
            # tree to see a window at all.
            self.note("located_band/window-list-was-empty-at-first",
                      {"selector": list(selector), "attempts": attempts})
        # #628, item 3: the candidate count reaches the DOCUMENT, not just the tool's stdout.
        #
        # Refusing when a name is ambiguous is half the job. The other half is that "there was
        # exactly one" survives into the record — a lookup that stays silent on success leaves a
        # result with no way to tell a discriminator from tree order, which is the whole issue.
        #
        # Recorded on EVERY success, including `candidates: 1`, and including the case where the
        # tool did not report a count at all. A note written only when the number is interesting
        # cannot be distinguished from a run of an older tool that never counted: both are silence,
        # and one of them is a lookup nobody has checked.
        self.note("located_band/candidates",
                  {"selector": list(selector), "subject": subject,
                   "candidates": payload.get("candidates"),
                   "counted": isinstance(payload.get("candidates"), int)})
        return tuple(band), subject

    # -- observations -------------------------------------------------------

    def note(self, tag, payload):
        """Record a reading that is context rather than a claim."""
        self.records.append({"kind": "observation", "tag": tag, "payload": payload})

    def check(self, tag, passed, expected, observed, mutation, modal_snapshot=_MODAL_SNAPSHOT_UNSET):
        """Assert something about the run.

        `mutation` NAMES a change to the product the author believes would flip this check. The
        field recording it is called `mutation_claimed` because that is all it is. It was called
        `mutation_flips` until 2026-08-28, one word away from a claim nothing here establishes:
        nobody reruns the build with the mutation applied, so `bool(mutation)` only ever meant "a
        non-empty string was supplied". The docstring above it said "a check nobody has watched fail
        is decoration" while the value beneath it counted decoration.

        Requiring a mutant receipt was considered and rejected. The live gate hashes every
        `*.evidence.json` at a head against the shipped release binary, and a mutant binary has a
        different digest by construction — so a receipt cannot live in that directory at all, and
        exempting it would move the trust rather than establish it. A second GUI run against another
        binary in another UI state also cannot show that the NAMED mutation caused the red; it shows
        only that something did.

        `falsifiable()` below is the cheap form that does establish something.
        """
        # The interesting instant is when `observed` was measured, not when this receipt happens to
        # be appended. A caller that took a modal snapshot beside its AX read supplies it here; the
        # fallback preserves the older convenience for callers that did not. The sentinel matters:
        # explicit None is the completed-clear snapshot and must not trigger a second, later read.
        modal = blocking_modal() if modal_snapshot is _MODAL_SNAPSHOT_UNSET else modal_snapshot
        self.records.append({
            "kind": "check", "tag": tag, "passed": bool(passed),
            "expected": expected, "observed": observed,
            "mutation": mutation or None, "mutation_claimed": bool(mutation),
            "blocking_modal": modal,
        })
        return bool(passed)

    def falsifiable(self, tag, predicate, observation, counterexample, expected, mutation=None,
                    modal_snapshot=_MODAL_SNAPSHOT_UNSET):
        """A check whose assertion is run against a state it MUST reject, in the same run.

        `check()` records whether the author's condition held. It cannot notice a condition that
        could not have failed — a constant, a field that is never read, a comparison too weak to
        reject the state it names. Those pass live and pass everywhere.

        So the predicate is handed to the framework and the framework calls it twice: once on what
        the run observed, once on an explicit counterexample the author had to write down. The check
        passes only when the first is accepted AND the second is rejected. An author cannot supply
        the second result; there is no parameter for it.

        This costs no rebuild and no second Logic session, and it catches the defects that make an
        assertion decoration. What it does NOT establish is that the check would catch a real
        regression in the product — only that its condition can distinguish the observation from one
        stated alternative. That boundary is the tag and that counterexample, and nothing wider.
        """
        try:
            live_ok = bool(predicate(observation))
        except Exception as exc:                       # noqa: BLE001 - recorded, not swallowed
            live_ok, observation = False, f"predicate raised on the observation: {exc!r}"
        try:
            counter_ok = bool(predicate(counterexample))
        except Exception as exc:                       # noqa: BLE001
            # A predicate that throws on the counterexample has not rejected it on the merits, and
            # reading a crash as a rejection is how a broken condition looks strong.
            counter_ok, counterexample = True, f"predicate raised on the counterexample: {exc!r}"

        passed = live_ok and not counter_ok
        # As with check(), prefer the state sampled beside `observation`; predicates can take long
        # enough for a sheet to close before the receipt is written. Callers without a contemporaneous
        # snapshot retain the old record-time fallback.
        modal = blocking_modal() if modal_snapshot is _MODAL_SNAPSHOT_UNSET else modal_snapshot
        self.records.append({
            "kind": "check", "tag": tag, "passed": passed,
            "expected": expected,
            "observed": {"observation": repr(observation)[:400],
                         "accepted_the_observation": live_ok,
                         "counterexample": repr(counterexample)[:400],
                         "rejected_the_counterexample": not counter_ok},
            "mutation": mutation or None, "mutation_claimed": bool(mutation),
            "has_counterexample": True,
            "counterexample_rejected": not counter_ok,
            "blocking_modal": modal,
        })
        return passed

    def provenance(self, tag, source, cache_age_sec, usable):
        """Record where a value came from when it did not come from a fresh read."""
        self.records.append({
            "kind": "provenance", "tag": tag, "source": source,
            "cache_age_sec": cache_age_sec,
            "usable_as_live_evidence": bool(usable),
        })

    def restored(self, tag, restored, detail=""):
        """Record that state the run mutated was put back."""
        self.records.append({
            "kind": "restoration", "tag": tag,
            "restored": bool(restored), "detail": detail,
        })

    # -- capture ------------------------------------------------------------

    def shot(self, tag, settle_region=None, window_title=None):
        """Capture the Logic window, waiting until the pixels stop moving.

        `settle_region` is an (x, y, w, h) rectangle in window coordinates. Settling is judged on that
        region alone: Logic repaints level meters and clocks continuously, so a whole-window settle
        never converges and would silently record `settled: false` on a perfectly good run.
        """
        # Keyed by harness as well as tag (#612 follow-up). Tags collide across harnesses —
        # `575/before` is used by three different files, `before-create` by two — so a document
        # rotated aside for later comparison used to name PNGs a later run had already replaced.
        # Archiving a document whose pixels are gone is the opposite of keeping a flake visible.
        path = os.path.join(self.dir, f"{self.name}__{tag.replace('/', '_')}.png")
        win = logic_window(window_title)
        if not win:
            self.records.append({"kind": "capture", "tag": tag, "file": path,
                                 "window": None, "display": {"wholly_within": False},
                                 "hash": None, "frames": 0, "settled": False,
                                 "why": "no Logic window on screen"})
            return {"file": path, "settled": False}

        prev, frames, settled = None, 0, False
        for _ in range(_SETTLE_TRIES):
            _capture_window(win["id"], path)
            frames += 1
            h = _region_hash(path, _clip_to_window(settle_region, (win["w"], win["h"])),
                             (win["w"], win["h"]))
            if prev is not None and h == prev:
                settled = True
                break
            prev = h
            time.sleep(_SETTLE_GAP)

        self._window_points = (win["w"], win["h"])
        self.records.append({
            "kind": "capture", "tag": tag, "file": path, "window": win,
            "display": _display_containing(win),
            "hash": _file_hash(path), "region_hash": prev,
            "frames": frames, "settled": settled,
        })
        return {"file": path, "settled": settled, "window": win, "region_hash": prev}

    def visual(self, tag, before_file, after_file, region, expect_change, why,
               window_points=None, subject=None):
        """Compare one named region across two captures and state what was expected there.

        A region is mandatory. A full-window diff answers "did anything at all change", which is true
        whenever the transport clock advances, and proves nothing about the feature.

        `subject` is mandatory too, and it is the harder requirement: state what the region IS, as the
        UI itself describes it — not where it is. Measured this week, three different rectangles over
        one window each produced a confident wrong answer, and every one of them looked identical in
        the receipt because a receipt that records only `(x, y, w, h)` cannot show that the band moved
        onto something else:

            (0, 0, 1920, 28)    named "the title band"; `screencapture -l` excludes the title bar, so
                                it was window CONTENT — track names and the Inspector
            (0, 0, 240, 28)     the track-name column with the Mixer closed, a column of MIXER STRIPS
                                with it open, and mixer strips carry level meters
            the rail by AXDescription   correct, and still wrong for the claim: the arrange SCROLLS
                                when a modal takes and returns focus

        So pass what AX says the element is — its description, and ideally its parent's. A run that
        aimed at the wrong thing then says so in its own document instead of reading as a clean pass.
        """
        # NOT raised. Twenty-nine harnesses predate this parameter, and filling their `subject` in
        # bulk would mean writing down what I believe each band is without measuring it — which is the
        # defect this parameter exists to catch, committed at scale. So an absent subject is RECORDED
        # as absent and `is_clean` refuses the run: each harness's next run tells its owner that this
        # assertion does not say what it watches, and the fix arrives with a measurement attached.
        wp = window_points or self._window_points
        # What was HASHED, which is not always what was asked for — see `_clip_to_window`. The
        # record carries the clipped rectangle, and says so when the two differ.
        effective = _clip_to_window(region, wp)
        b = _region_hash(before_file, effective, wp)
        a = _region_hash(after_file, effective, wp)
        readable = b is not None and a is not None
        changed = readable and b != a
        # An unreadable comparison is not a passing one, whichever way the expectation points.
        passed = readable and (changed == bool(expect_change))
        self.records.append({
            "kind": "visual", "tag": tag, "region": list(effective) if effective else None,
            "subject": subject,   # None until the harness measures what the region is

            "before": before_file, "after": after_file,
            "expected": ("region changes" if expect_change else "region does not change") + f" — {why}",
            "observed": f"before {(b or '?')[:16]} after {(a or '?')[:16]} changed={changed}",
            "passed": passed,
        })
        if effective is not None and region is not None and tuple(effective) != tuple(region):
            self.records[-1]["region_requested"] = list(region)
        return passed

    # -- recording ----------------------------------------------------------

    def record_screen(self, seconds=90):
        """Start a screen recording covering the whole run.

        `seconds` is a hard duration, not a maximum, and `stop_recording` waits it out. That is not a
        convenience choice: `screencapture -v` only finalises its file when its own `-V` timer elapses.
        Measured on macOS 15 — SIGINT, SIGTERM, closing stdin, and a process-group SIGINT all leave NO
        file at all. Pick a duration a little longer than the run rather than a generous one, since the
        wait is real.

        The file name never begins with a dot: `screencapture` rejects dotfiles while still exiting 0,
        which produces a silent absence rather than an error.
        """
        path = os.path.join(self.dir, f"{self.name}__run.mov")
        proc = subprocess.Popen(
            ["/usr/sbin/screencapture", "-v", "-V", str(seconds), path],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(1.5)
        return {"proc": proc, "file": path, "seconds": seconds}

    def stop_recording(self, handle, settle=1.0):
        """Wait for the recording to finalise, then record what actually landed on disk."""
        if not handle:
            return
        time.sleep(settle)
        try:
            handle["proc"].wait(timeout=handle.get("seconds", 90) + 30)
        except Exception:
            try:
                handle["proc"].kill()
            except Exception:
                pass
        time.sleep(1.0)
        self.recording(handle["file"])

    def recording(self, path):
        exists = os.path.isfile(path)
        self.records.append({
            "kind": "recording", "file": path, "exists": exists,
            "bytes": os.path.getsize(path) if exists else 0,
        })

    # -- output -------------------------------------------------------------

    def write(self):
        built_from, dirty = _worktree_head(REPO)
        stale = _sources_newer_than_binary(REPO, BIN)
        if stale:
            # THE BINARY, not the checkout. `built_from` is the WORKTREE's head and nothing compared
            # it to the artifact, so a document could read `built_from: <head>` with
            # `worktree_clean: true` while the binary was built from an earlier commit — and the two
            # fields together read as an attestation neither of them makes.
            #
            # Measured 2026-09-06 (#794): a fix was committed, `swift build` started, and the harness
            # launched before it finished. The run used the previous commit's binary, claimed the new
            # head, and reported 2 red checks — read as "the fix does not work". Driving the same
            # operation by hand against the finished binary returned state A, verified true. So the
            # false document did not merely mislabel itself: it asserted a BEHAVIOURAL conclusion
            # about a commit whose code never ran.
            #
            # mtime is the cheap check, not the strong one. Embedding the commit in the binary and
            # reading it back would MEASURE the correspondence rather than infer it; this only
            # refuses the case where a source file is newer than the thing built from it, which is
            # the case that actually happened.
            self.records.append({
                "kind": "provenance", "tag": "artifact/older-than-its-sources",
                "source": "mtime(Sources/**) vs mtime(binary)", "cache_age_sec": None,
                "usable_as_live_evidence": False,
                "newer_than_binary": stale[:8],
                "newer_than_binary_count": len(stale),
            })
        if dirty:
            # A binary built from a dirty tree does not correspond to the commit it claims. Say so in
            # the document rather than letting the SHA imply a correspondence that does not hold.
            self.records.append({
                "kind": "provenance", "tag": "artifact/worktree-was-dirty",
                "source": "git status --porcelain", "cache_age_sec": None,
                "usable_as_live_evidence": False,
            })
        doc = {
            "name": self.name,
            "head": self.head,
            "artifact": {
                "path": BIN,
                "sha256": _file_hash(BIN),
                "built_from": built_from,
                # BOTH, because the two fields are read together. `worktree_clean: true` beside a
                # `built_from` nothing checked made the claim look MORE bound, not less; it now says
                # false whenever either the tree was dirty or the binary predates its sources, and
                # the reason is a record of its own.
                "worktree_clean": not dirty and not stale,
                "built_from_is_measured": False,
                "artifact_older_than_sources": bool(stale),
            },
            "records": self.records,
        }
        # #612: one file per HARNESS per head, not one per head. `evidence.json` was keyed by the
        # head SHA alone, so the last harness to run at a given head silently replaced every earlier
        # one's document — measured: running #606's harness on the #608 branch to check for a
        # regression overwrote #608's own evidence, and the gate then validated #608 against #606's
        # proof and reported ok. A check whose subject can be swapped without the check noticing is
        # not a check.
        out = os.path.join(self.dir, f"{self.name}.evidence.json")
        # A re-run against the SAME binary is a re-measurement of the same thing. Replacing the
        # earlier document silently would hide a flake — two runs disagreeing is exactly what you
        # want to see — so the previous one is kept beside it rather than dropped.
        # Rotate ANY existing document, not only one from the same binary.
        #
        # The first cut rotated only when the artifact sha256 matched, on the theory that a different
        # binary is a new measurement and may replace cleanly. That erases the case the rotation
        # exists for: the normal loop is edit → rebuild → re-run, so the second run almost always has
        # a DIFFERENT hash, and the flake it was meant to preserve was the thing overwritten.
        # Unreadable or pre-schema JSON took the same overwrite path for the same reason.
        #
        # Keeping every document costs a few kilobytes and is the only way "two runs disagreeing" is
        # something anyone can see afterwards.
        if os.path.exists(out):
            n = 1
            while os.path.exists(os.path.join(self.dir, f"{self.name}.evidence.{n}.json")):
                n += 1
            os.replace(out, os.path.join(self.dir, f"{self.name}.evidence.{n}.json"))
        with open(out, "w") as fh:
            json.dump(doc, fh, indent=1)
        # The old single-file name is still written, because the gate reads it. It is the LAST run at
        # this head whatever produced it, which is the very ambiguity #612 is about — the per-harness
        # file above is the one to trust, and the gate should move to requiring one per harness.
        legacy = os.path.join(self.dir, "evidence.json")
        with open(legacy, "w") as fh:
            json.dump(doc, fh, indent=1)
        return self._summary(out)

    def _summary(self, out):
        return summarize(self.records, out)


def summarize(recs, out=None):
    """The counters `is_clean` reads, from a list of records.

    Module-level rather than a method because the records are the whole input: a document read back
    off disk has records and no Evidence around them, and the alternative — building a throwaway
    object with a `.records` attribute so a method can be called on it — is a shim standing where an
    argument belongs. The test file already had to write that shim once.

    Indexed with `.get` rather than `[...]` throughout: a document read back off disk may predate a
    field or have been truncated, and every missing key here reads as the FAILING value — an absent
    `passed` is not a pass, an absent `settled` is unsettled, and an absent `blocking_modal` is not a
    clear modal scan. Crashing on a malformed document would turn "this evidence is unreadable" into
    a stack trace at the gate.
    """
    if not isinstance(recs, list):
        return None
    recs = [r for r in recs if isinstance(r, dict) and "kind" in r]
    checks = [r for r in recs if r["kind"] == "check"]
    caps = [r for r in recs if r["kind"] == "capture"]
    vis = [r for r in recs if r["kind"] == "visual"]
    return {
        "file": out,
        "checks": len(checks),
        "passed": sum(1 for c in checks if c.get("passed")),
        # A detected document/application modal contaminates the check made through it, even where
        # an application-wide menu remains enabled. None is the only completed-clear modal state.
        "checks_recorded_under_blocking_modal":
            sum(1 for c in checks
                if "blocking_modal" in c
                and c.get("blocking_modal") is not None
                and not _modal_snapshot_is_unknown(c.get("blocking_modal"))),
        # Do not collapse "we did not record a snapshot" or "the detector could not inspect AX/CG"
        # into a clear check. They are different defects, counted independently for diagnostics.
        "checks_missing_blocking_modal_snapshot":
            sum(1 for c in checks if "blocking_modal" not in c),
        "checks_with_blocking_modal_unknown":
            sum(1 for c in checks if _modal_snapshot_is_unknown(c.get("blocking_modal"))),
        "mutation_claimed": sum(1 for c in checks if c.get("mutation_claimed")),
        # THE SESSION, asked once per document rather than per check. A locked screen does not make
        # the accessibility API fail — it makes the three paths this repository reads disagree, and
        # none of them says "locked" (#797). `None` is not False: a session state that could not be
        # read is `cannot_tell`, the same distinction the modal snapshot already makes, and
        # `is_clean` refuses both.
        "screen_locked": _SESSION_LOCKED,
        # The LAST declaration wins, and an absent or malformed one reads as None — which
        # `is_clean` treats as the UI surface, the stricter of the two. A document that never
        # declared itself is judged the way every document was judged before #754.
        "declared_surface": next(
            (r.get("surface") for r in reversed(recs)
             if isinstance(r, dict) and r.get("kind") == "declaration"
             and r.get("surface") in Evidence.SURFACES),
            None),
        "checks_with_a_counterexample": sum(1 for c in checks if c.get("has_counterexample")),
        "counterexamples_not_rejected":
            sum(1 for c in checks if c.get("has_counterexample") and not c.get("counterexample_rejected")),
        "captures_unsettled": sum(1 for c in caps if not c.get("settled")),
        "captures_straddling_displays":
            sum(1 for c in caps if not c.get("display", {}).get("wholly_within")),
        "restorations_failed":
            sum(1 for r in recs if r["kind"] == "restoration" and not r.get("restored")),
        "cached_reads_used_as_live":
            sum(1 for r in recs if r["kind"] == "provenance" and not r.get("usable_as_live_evidence")),
        "captures": len(caps),
        "visual_assertions": len(vis),
        "visual_failed": sum(1 for v in vis if not v.get("passed")),
        "recordings": sum(1 for r in recs if r["kind"] == "recording"),
        "operations_driven": sum(1 for r in recs if r["kind"] == "operation"),
        # A subject must be a non-empty STRING. `not v.get("subject")` alone accepted True, a
        # dict, or any other truthy object as a name.
        "visual_assertions_without_a_subject":
            sum(1 for v in vis
                if not isinstance(v.get("subject"), str) or not v["subject"].strip()),
    }


def _modal_snapshot_is_unknown(snapshot):
    """Whether a check carries the detector's explicit cannot-tell state rather than a blocker."""
    return (isinstance(snapshot, dict)
            and snapshot.get("state") == MODAL_CANNOT_TELL
            and snapshot.get("kind") == MODAL_CANNOT_TELL)


# Every counter `is_clean` reads. A summary missing any of them is not clean.
#
# The polarity used to depend on which key it was: `summary.get("visual_assertions_without_a_subject", 0) == 0`
# passed when the key was ABSENT, while `summary.get("mutation_claimed", 0) > 0` failed when absent.
# So a summary carrying the new counters but not that one — an older _summary, a hand-built dict —
# was clean, and the newest condition was the one that vanished quietly. Listing the keys fixes the
# shape of the bug rather than the one clause where it was noticed.
_REQUIRED_SUMMARY_KEYS = (
    "checks", "passed", "checks_recorded_under_blocking_modal",
    "checks_missing_blocking_modal_snapshot", "checks_with_blocking_modal_unknown",
    "mutation_claimed", "operations_driven",
    "checks_with_a_counterexample", "counterexamples_not_rejected",
    "captures", "captures_unsettled", "captures_straddling_displays",
    "restorations_failed", "cached_reads_used_as_live",
    "visual_assertions", "visual_failed", "visual_assertions_without_a_subject",
    "recordings", "declared_surface",
)


def _non_vacuity_earned(summary):
    """Whether the run looked at its subject, by an instrument that fits the subject.

    For a change with a surface in Logic's UI that means what it always meant: a capture, a visual
    assertion, and a recording, each earned. A run that photographed nothing has not looked.

    For a change the document declares `non_ui` there is nothing to photograph — the stream
    terminates inside the server — so those three counters are not evidence of anything and are
    not required. In their place the run must carry at least one check with a COUNTEREXAMPLE, so
    the assertion is shown to be able to fail (`counterexamples_not_rejected == 0` is enforced
    beside this for every surface). A non_ui run that asserted nothing therefore still fails, which
    is the property #754 exists to keep: the zeros are unearnable by silence on either surface.

    An undeclared document is judged as UI. Silence is not a class.
    """
    if summary.get("declared_surface") == "non_ui":
        return summary["checks_with_a_counterexample"] > 0
    return (summary["captures"] > 0
            and summary["visual_assertions"] > 0
            and summary["recordings"] > 0)


def is_clean(summary):
    """Whether a run may be reported as passing.

    Exists because every harness got this wrong the same way: `sys.exit(0 if out["passed"] else 1)`.
    `passed` is a COUNT, not a boolean — 5-of-7 is truthy, so a harness with two red checks exited 0 and
    reported success. The only value that failed was zero, i.e. a run where NOTHING passed. A harness
    whose exit code cannot express failure is not an instrument.

    Every dimension the evidence document tracks has to be clean, not just the check count: a check
    recorded while a blocker was present, a missing/unknown modal snapshot, an unsettled capture, a
    failed visual assertion, a restoration that did not happen, or a cached read presented as live each
    invalidate the run on their own.

    THE ZEROS HAVE TO BE EARNED. Every `== 0` clause below is satisfied by a run that never did the
    thing at all: no visual assertion means no visual can lack a subject, and no capture means none
    was unsettled. So the counts that make those zeros meaningful are required to be positive. The
    cheapest way to satisfy "every visual names a subject" must not be to assert nothing.

    What these clauses do NOT establish, stated so nobody reads them as more:

      * `operations_driven` counts operations SENT, not successful ones — `tools/call` and
        `resources/read` alike, since both reach the server over the same connection and either is
        the product being touched. A warm-up call, a read, or a
        call that came back a transport error each increment it. It rules out a harness that never
        touched the product; it does not show the run drove its own subject.
      * `mutation_claimed` counts checks that NAME a mutation. Naming is not demonstrating — the
        string is prose, and nothing here reruns the build with the mutation applied. Whether the
        named mutation would actually flip that check is the author's claim and a reviewer's job.
        It was called `mutation_backed` until 2026-08-28, which read as though something backed it.
      * `counterexamples_not_rejected` is enforced and `checks_with_a_counterexample` is NOT, yet.
        A `falsifiable()` check whose predicate accepts the state it was supposed to reject fails
        immediately — that clause is real. Requiring every harness to HAVE one is the clause with
        teeth, and it is left counted-but-unenforced for the same reason
        `visual_assertions_without_a_subject` was: thirty-odd harnesses predate the affordance, and
        turning the whole live suite red in one step invites someone to delete the clause instead of
        converting the call sites. Enforce it when the count reaches the harness count, not before.
      * a subject is any non-empty string. That it truthfully names what the rectangle contains is
        not checkable here.

    `visual_assertions_without_a_subject` is GATED as of #622. It was counted and not enforced for
    one release, because enforcing it while thirty harnesses passed no subject would have turned
    the whole live suite red in a step and the predictable next move is that somebody deletes the
    clause. All thirty-one call sites name a subject now, and the count reached zero by measuring
    what each band contains rather than by writing a string that would satisfy the counter.

    What the clause still cannot do is check that the name is TRUE. Most bands are resolved from
    the live tree by `located_band`, so their subject is read back off the element that was found
    and cannot drift from it; the few that are authored — a window's title bar, a slice offset into
    a located rail — are the ones a reviewer has to read.
    """
    if not isinstance(summary, dict):
        return False
    if any(key not in summary for key in _REQUIRED_SUMMARY_KEYS):
        return False
    return (
        summary["checks"] > 0
        and summary["passed"] == summary["checks"]
        # A detected blocker, a missing snapshot, or a detector that could not inspect the state all
        # retire a check. Only CHECK records carry modal snapshots; the other record kinds are not
        # sampled and this condition deliberately makes no claim about them.
        and summary["checks_recorded_under_blocking_modal"] == 0
        and summary["checks_missing_blocking_modal_snapshot"] == 0
        and summary["checks_with_blocking_modal_unknown"] == 0
        # A run recorded behind a locked screen read an application it could not see. False is the
        # only value that passes; None means the session could not be asked, which is not evidence
        # that it was unlocked.
        and summary.get("screen_locked") is False
        # Non-vacuity: the run has to have looked, driven, and recorded. WHAT counts as having
        # looked depends on the surface the document declared — see `_non_vacuity_earned`.
        and _non_vacuity_earned(summary)
        and summary["mutation_claimed"] > 0
        and summary["counterexamples_not_rejected"] == 0
        and summary["operations_driven"] > 0
        # ... and nothing it did may have gone wrong.
        and summary["visual_failed"] == 0
        and summary["captures_unsettled"] == 0
        and summary["captures_straddling_displays"] == 0
        and summary["restorations_failed"] == 0
        and summary["cached_reads_used_as_live"] == 0
        and summary["visual_assertions_without_a_subject"] == 0
    )


# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

def _capture_window(window_id, path):
    subprocess.run(["/usr/sbin/screencapture", "-x", "-o", "-l", str(window_id), path],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)


def _file_hash(path):
    try:
        with open(path, "rb") as fh:
            return hashlib.sha256(fh.read()).hexdigest()
    except OSError:
        return None


# --- Restored after a merge dropped them -------------------------------------------------------
#
# #620 rewrote this file from a base that predated these three, so merging it deleted them while
# every CALL SITE stayed: `_region_hash` at shot()/visual(), `_worktree_head` at write(), and
# `have_tools` in thirty-two harnesses. Main could not run a single live harness.
#
# Neither gate could see it. The ship gate runs the Swift suite, and #620 changed no Sources/ so it
# needed no live evidence; #620's own test exercises is_clean and _safe_name and never calls shot(),
# visual(), or write(). Each branch was green and the breakage existed only in their merge.
#
# The import smoke test beside this file is the part that would have caught it.

def _clip_to_window(region, window_points):
    """The part of `region` a capture of that window can actually contain, or None if none of it.

    A band can legitimately be larger than the window it is measured in: `Tracks contents` is 6162
    points wide on a 1920-point window, because the arrange canvas extends past the viewport it is
    drawn into. `CGImageCreateWithImageInRect` intersects an oversized crop against the image and
    says nothing, so the record claimed the whole canvas while the hash covered the visible part.

    Clipping here rather than there keeps the two honest: what is recorded as the region is what
    was hashed. A band lying entirely outside the window returns None, which reads as unreadable
    rather than as a comparison of two empty crops — those would be equal, and equal is a PASS for
    every negative assertion.
    """
    if not region or not window_points:
        return tuple(region) if region else None
    wpts, hpts = window_points
    if not wpts or not hpts:
        return tuple(region)
    x, y, w, h = region
    x0, y0 = max(0, x), max(0, y)
    x1, y1 = min(x + w, wpts), min(y + h, hpts)
    if x1 <= x0 or y1 <= y0:
        return None
    return (x0, y0, x1 - x0, y1 - y0)


def _region_hash(png, region, window_points=None):
    """Hash one rectangle of a PNG.

    `region` is in WINDOW POINTS, the same units `logic_window()` reports. The capture is in backing
    PIXELS — measured 3840x2100 for a 1920x1050 window on this hardware — so the rectangle is scaled by
    the ratio the image itself reveals. Without that scaling the crop lands somewhere else entirely and
    the assertion compares two identical wrong regions, which reads as "nothing changed" on a run where
    the feature plainly worked.

    Returns None rather than falling back to a whole-file hash: an unusable comparison must be visible
    as unusable, not disguised as a difference.
    """
    # A falsy region hashes the WHOLE FILE, which is how a region-less visual passes. The docstring
    # above has always said otherwise, and the #620 review said so again; it stayed true anyway.
    # Measured today: a band lookup returned None, `visual()` compared two whole images, found them
    # equal, and reported a passing negative assertion about a rectangle it never looked at.
    #
    # A comparison with no region is not a weak comparison, it is a different one — "did anything on
    # screen change" instead of "did this change" — and the run has no way to know it was answered.
    if not region:
        return None
    # The whole-image fallback that used to live further down is DELETED, not merely bypassed. It
    # said the opposite of this guard, in the same function, and this guard won only by running
    # first — so deleting it would have restored the defect silently, and anyone reading that
    # branch had every reason to think whole-image hashing was supported.
    #
    # With the fallback gone this guard is no longer individually load-bearing: `x, y, w, h = region`
    # raises on None and the broad `except` below returns None anyway. Measured — removing this line
    # leaves the shape test green. It stays because being correct by way of an exception handler is
    # not the same as being correct on purpose, and that handler also swallows real failures. Said
    # plainly so nobody reads a passing suite as proof this line is doing the work.
    if not os.path.isfile(png):
        return None
    try:
        from Quartz import (CGImageSourceCreateWithURL, CGImageSourceCreateImageAtIndex,
                            CGImageCreateWithImageInRect, CGRectMake, CGDataProviderCopyData,
                            CGImageGetDataProvider, CGImageGetWidth, CGImageGetHeight)
        from Foundation import NSURL
        url = NSURL.fileURLWithPath_(png)
        src = CGImageSourceCreateWithURL(url, None)
        if src is None:
            return None
        img = CGImageSourceCreateImageAtIndex(src, 0, None)
        if img is None:
            return None
        pw, ph = CGImageGetWidth(img), CGImageGetHeight(img)
        sx = sy = 1.0
        if window_points:
            wpts, hpts = window_points
            if wpts:
                sx = pw / float(wpts)
            if hpts:
                sy = ph / float(hpts)
        x, y, w, h = region
        sub = CGImageCreateWithImageInRect(
            img, CGRectMake(x * sx, y * sy, w * sx, h * sy))
        if sub is None:
            return None
        data = CGDataProviderCopyData(CGImageGetDataProvider(sub))
        return hashlib.sha256(bytes(data)).hexdigest()
    except Exception:
        return None


def _sources_newer_than_binary(repo, binary):
    """Tracked files under `Sources/` modified after the binary was built.

    A non-empty answer means the artifact cannot be what this head describes. It is a necessary
    check, not a sufficient one: a build that finished and was then reverted leaves no trace here,
    and only embedding the commit in the binary would settle it. What this catches is the case that
    happened — the harness launched while `swift build` was still running.
    """
    try:
        built = os.path.getmtime(binary)
    except OSError:
        return []
    try:
        listed = subprocess.run(["git", "-C", repo, "ls-files", "Sources"],
                                capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.SubprocessError):
        return []
    if listed.returncode != 0:
        return []
    newer = []
    for rel in listed.stdout.splitlines():
        rel = rel.strip()
        if not rel:
            continue
        path = os.path.join(repo, rel)
        try:
            if os.path.getmtime(path) > built:
                newer.append(rel)
        except OSError:
            continue
    return sorted(newer)


def _worktree_head(repo):
    """(HEAD sha, dirty) for the worktree the binary was built in.

    `dirty` counts tracked-file modifications under Sources/ and Tests/ only: an untracked scratch file
    does not change what was compiled, but an edited source does, and a binary built from an edited tree
    is not evidence about the commit it is filed under.
    """
    if not repo:
        return None, False
    try:
        head = subprocess.run(["git", "-C", repo, "rev-parse", "HEAD"],
                              capture_output=True, text=True, check=False).stdout.strip()
        st = subprocess.run(["git", "-C", repo, "status", "--porcelain", "--", "Sources", "Tests"],
                            capture_output=True, text=True, check=False).stdout.strip()
        return (head or None), bool(st)
    except Exception:
        return None, False


def have_tools():
    """Everything the recorder needs, checked before a run rather than mid-run."""
    missing = []
    if not shutil.which("screencapture") and not os.path.exists("/usr/sbin/screencapture"):
        missing.append("screencapture")
    try:
        import Quartz  # noqa: F401
    except ImportError:
        missing.append("pyobjc (Quartz)")
    if BIN and not os.access(BIN, os.X_OK):
        missing.append(f"built binary at {BIN}")
    return missing
