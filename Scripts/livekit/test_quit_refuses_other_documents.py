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
        "only the fixture and a palette": (fixture + "\nmissing value\n" + END, []),
        "no windows": (END, []),
        "an iCloud project beside the fixture": (fixture + "\n" + ICLOUD + "\n" + END, [ICLOUD]),
        "a list that could not be read": (None, None),
        "a list cut off before its end": (fixture, None),
    }
    for label, (documents, expected) in readings.items():
        answering(module, documents, [])
        check(f"{name}: {label} reads as {expected!r}", module.unidentified_documents() == expected)

    for label, documents in (("another project is open", fixture + "\n" + ICLOUD + "\n" + END),
                             ("the document list is unreadable", None)):
        calls = []
        answering(module, documents, calls)
        refused = module.quit_logic() is False
        asked = any("to quit" in call for call in calls)
        answered = any("AXDialog" in call for call in calls)
        check(f"{name}: {label}, quit refuses without quitting or answering a prompt",
              refused and not asked and not answered)

    calls = []
    answering(module, fixture + "\n" + END, calls)
    module.quit_logic()
    check(f"{name}: only the fixture is open, quit asks Logic to quit",
          any("to quit" in call for call in calls))

sys.exit(1 if failed else 0)
