#!/usr/bin/env python3
"""Prove the #1077 live harness counts a quit only when the quit is witnessed (PR #1080 R1077-2).

`quit_and_read` quits Logic through live_993 and reads the process count before and after it; the
candidate's crash check (`quit_left_no_crash`) stands on that record. Review R1077-2 found the old
record took `not logic_running()` as "Logic is gone", and `logic_running` answers False when the
count did not read or did not parse, so an unreadable count after a failed quit passed. It also
ignored `quit_returned`, and `quit_logic` itself returns True without quitting when its own first
count does not read.

Each case drives the harness's real `quit_and_read` and predicate with live_993's osascript call
answered by the case: the count answers what the case says before the quit, during it and after
it. Nothing talks to Logic. The harness is loaded by path, not imported by name: a `live_*.py` is an
entry point, which check-dead-harness-helpers.py relies on.

    python3 test_live_1077_quit_witness.py
"""
import importlib.util
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)  # the harness imports `evidence` and live_993 beside it


def load(name):
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


H = load("live_1077_write_warning_is_cleared_in_every_locale")
L993 = H.L993  # the live_993 module the harness itself loaded
H.CRASH_WAIT = 0
H.crash_reports = lambda: set()
REAL_QUIT = L993.quit_logic

failed = 0


def check(label, ok, detail=""):
    global failed
    print(("ok   " if ok else "FAIL ") + label + (f"  ({detail})" if detail and not ok else ""))
    failed += 0 if ok else 1


def run(before, after, quit_returns=None, during=None):
    """`quit_and_read` with the process count answering `before`, `during` and `after` the quit.

    A count answer of None is osascript failing. `quit_returns` None runs live_993's real
    `quit_logic` against the same answers; otherwise the quit returns that value without asking.
    """
    phase = {"now": "before"}
    answers = {"before": before, "during": during, "after": after}
    asked_to_quit = []

    def osa(script, timeout=20):
        if "count of (every process" in script:
            return answers[phase["now"]]
        if "to quit" in script:
            asked_to_quit.append(script)
        return None

    def quit_logic():
        phase["now"] = "during"
        try:
            return REAL_QUIT() if quit_returns is None else quit_returns
        finally:
            phase["now"] = "after"

    L993.osa = osa
    L993.quit_logic = quit_logic
    record = H.quit_and_read()
    return record, asked_to_quit


CASES = [
    # label, before, after, quit_returns, during, counts as a quit
    ("the control: running before, quit returned True, a count of 0 after", "1", "0", True, None, True),
    ("the count after the quit did not read", "1", None, True, None, False),
    ("the count after the quit answered something that is not a count", "1", "missing value", True,
     None, False),
    ("the count after the quit is empty", "1", "", True, None, False),
    ("Logic is still running after the quit", "1", "1", True, None, False),
    ("two Logic processes after the quit", "1", "2", True, None, False),
    ("the quit returned False and the count after reads 0", "1", "0", False, None, False),
    ("the quit returned something other than True", "1", "0", "yes", None, False),
    ("the count before the quit did not read", None, "0", True, None, False),
]

for label, before, after, quit_returns, during, expected in CASES:
    record, _ = run(before, after, quit_returns=quit_returns, during=during)
    check(f"{label}: quit_left_no_crash is {expected}", H.quit_left_no_crash(record) is expected,
          f"record {record!r}")

# R1077-2's last finding, driven through live_993's real quit_logic: when its own first count does
# not read it returns True without asking Logic to quit. The first check is the seam firing; the
# witness must not take that True for a quit, whatever the count reads afterwards.
for after in ("0", "1", None):
    record, asked = run(None, after, during=None)
    check(f"quit_logic with an unreadable first count returns True without asking (after {after!r})",
          record.get("quit_returned") is True and not asked, f"record {record!r}, asked {asked!r}")
    check(f"that True is not a witnessed quit (after {after!r})",
          H.quit_left_no_crash(record) is False, f"record {record!r}")

# The census itself, and `logic_running` unchanged for live_993's other callers.
census = getattr(L993, "logic_census", None)
check("live_993 has a status-preserving census", callable(census))
for raw, status, running in ((None, "unreadable", False), ("missing value", "unreadable", False),
                             ("", "unreadable", False), ("-1", "unreadable", False),
                             ("0", "gone", False), ("1", "running", True), ("2", "running", False)):
    L993.osa = lambda script, timeout=20, raw=raw: raw
    if callable(census):
        got = census()
        check(f"census of {raw!r} is {status}", got.get("status") == status and got.get("raw") == raw,
              f"got {got!r}")
    check(f"logic_running of {raw!r} is still {running}", L993.logic_running() is running)

sys.exit(1 if failed else 0)
