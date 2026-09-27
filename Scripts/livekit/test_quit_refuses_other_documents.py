#!/usr/bin/env python3
"""Prove the #993 harnesses refuse to quit Logic while a project other than the fixture is open.

Quitting answers Logic's save prompt with don't-save. That answer is only ours for the disposable
fixture: another open project may be an iCloud one, which no authorisation covers. The cases drive
each script's quit path with canned osascript results, so nothing here talks to Logic.

    python3 test_quit_refuses_other_documents.py
"""
import importlib.util
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
SCRIPTS = {
    "live_993_plugin_root_menu_in_every_locale.py": ["x"],
    # The probe reads its worktree, output and an absolute scratch directory at import.
    "probe_993_1004_nbsp_labels_as_drawn.py": ["x", REPO, os.devnull, tempfile.gettempdir()],
}
END = "lpm:end-of-documents"  # the scripts' terminator: a list cut off before it is not whole


def listing(*rows):
    """The shared DOCUMENTS_SCRIPT's output: a counted header, one line per window, the end."""
    return "\n".join([f"lpm:windows {len(rows)}", *rows, END])


def doc(url, subrole="AXStandardWindow"):
    return f"doc\t{subrole}\t{url}"


PALETTE = "none\tAXFloatingWindow"
FAILED = "error\tAXStandardWindow\t-1728\tCan't get attribute"
ICLOUD = "file:///Users/someone/Library/Mobile%20Documents/com~apple~CloudDocs/song.logicx/"

failed = 0


def check(label, ok):
    global failed
    print(("ok   " if ok else "FAIL ") + label)
    failed += 0 if ok else 1


class Clock:
    """Time that moves only when the script sleeps, so a quit loop ends without waiting."""

    def __init__(self):
        self.now = 0.0

    def monotonic(self):
        return self.now

    time = monotonic

    def sleep(self, seconds):
        self.now += seconds


def load(name, argv):
    saved = sys.argv
    sys.argv = argv
    try:
        spec = importlib.util.spec_from_file_location(name[:-3], os.path.join(HERE, name))
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
    finally:
        sys.argv = saved
    return module


def answering(module, documents, calls):
    def osa(script, timeout=20):
        calls.append(script)
        if "AXDocument" in script:
            return documents
        if "count of (every process" in script:
            return "1"
        return ""
    module.osa = osa
    module.time = Clock()
    module.dismiss_sheets = lambda: None
    if hasattr(module, "close_left_open_menus"):
        module.close_left_open_menus = lambda: None


for name, argv in SCRIPTS.items():
    module = load(name, argv)
    fixture = "file://" + module.FIXTURE.replace(" ", "%20") + "/"
    readings = {
        "only the fixture and a palette": (listing(doc(fixture), PALETTE), []),
        "no windows": (listing(), []),
        "an iCloud project beside the fixture": (listing(doc(fixture), doc(ICLOUD)), [ICLOUD]),
        "a list that could not be read": (None, None),
        "a list cut off before its end": (listing(doc(fixture))[:-len(END)], None),
        # PR #1033 review R1: every AXDocument read failed and the old script's silent `try`
        # printed only the terminator, which read as "no document".
        "every read failed silently (the old script's output)": (END, None),
        "one window's AXDocument read failed": (listing(doc(fixture), FAILED), None),
        "an untitled project window": (listing(doc(fixture), "none\tAXStandardWindow"),
                                       ["none\tAXStandardWindow"]),
    }
    for label, (documents, expected) in readings.items():
        answering(module, documents, [])
        check(f"{name}: {label} reads as {expected!r}", module.unidentified_documents() == expected)

    for label, documents in (("another project is open", listing(doc(fixture), doc(ICLOUD))),
                             ("the document list is unreadable", None),
                             ("every read failed silently", END),
                             ("one window's AXDocument read failed", listing(doc(fixture), FAILED))):
        calls = []
        answering(module, documents, calls)
        refused = module.quit_logic() is False
        asked = any("to quit" in call for call in calls)
        answered = any("AXDialog" in call for call in calls)
        check(f"{name}: {label}, quit refuses without quitting or answering a prompt",
              refused and not asked and not answered)

    calls = []
    answering(module, listing(doc(fixture), PALETTE), calls)
    module.quit_logic()
    check(f"{name}: only the fixture is open, quit asks Logic to quit",
          any("to quit" in call for call in calls))

sys.exit(1 if failed else 0)
