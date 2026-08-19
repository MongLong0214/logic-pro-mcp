#!/usr/bin/env python3
"""Drive the dependency-injected Logic modules and assert what comes back.

`Scripts/check-python-contracts.py` proves every name a consumer references exists and every call
binds; it cannot see a function that keeps its name and signature and returns a different shape.
This is that half for two more of the twelve modules with consumers.

Both drive with no Logic and no display, and that had to be MEASURED per module rather than assumed
from another one being drivable:

  * `classify_controller_learn_mode` is a pure function over a snapshot dict.
  * `detect_controller_learn_mode` takes the runner as an argument, so the System Events call is
    replaceable with a stub that returns a snapshot.
  * `select_input_source` takes the TIS runtime as an argument; only `set_input_abc`'s default path
    loads the real Carbon framework.

The stubs implement the protocols the code actually calls — `detect()`, `available_source_ids()`,
`select_source_id()`. A first pass at this file guessed those names, the calls raised
AttributeError, and the honest-looking conclusion was "these cannot be driven headlessly". That
would have recorded a wall where there was none, which is worse than leaving the square open: a
wall stops the next person from trying.

    python3 test_pure_logic_modules.py
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import logic_controller_learn_mode as C  # noqa: E402
import logic_input_source as I  # noqa: E402

failed = 0
checks = []


def shape(why, ok):
    checks.append((why, bool(ok)))


# --- logic_controller_learn_mode -----------------------------------------------------------------
POLICY_ID = C.DEFAULT_CONTROLLER_LEARN_MODE_POLICY["policy_id"]

for snapshot, expected_status, why in [
    ({"status": "not_present"}, "inactive", "an absent window is inactive"),
    ({"status": "inactive"}, "inactive", "an inactive window is inactive"),
    ({"status": "error", "reason": "osascript_failed"}, "error", "a failed read stays an error"),
    ({}, "error", "a snapshot with no status is an error, not an absence"),
]:
    out = C.classify_controller_learn_mode(snapshot)
    shape(f"classify returns a dict — {why}", isinstance(out, dict))
    shape(f"classify carries the policy id — {why}", out.get("policy_id") == POLICY_ID)
    shape(f"classify: {why}", out.get("status") == expected_status)

err = C.classify_controller_learn_mode({"status": "error", "reason": "x", "stderr": "boom"})
shape("classify passes stderr through when the snapshot carries it", err.get("stderr") == "boom")


class StubRunner:
    """Only what the module calls: `detect()`."""

    def __init__(self, snapshot):
        self.snapshot = snapshot

    def detect(self):
        return self.snapshot


detected = C.detect_controller_learn_mode(runner=StubRunner({"status": "inactive"}))
shape("detect returns a dict", isinstance(detected, dict))
shape("detect classifies what the runner gave it", detected.get("status") == "inactive")
shape("detect does not invent a policy id", detected.get("policy_id") == POLICY_ID)

guarded = C.guard_controller_learn_mode(runner=StubRunner({"status": "inactive"}))
shape("guard returns a dict", isinstance(guarded, dict))


# --- logic_input_source --------------------------------------------------------------------------
class StubTIS:
    """Only what the module calls: `available_source_ids()` and `select_source_id()`."""

    def __init__(self, ids, accept=True):
        self.ids = ids
        self.accept = accept
        self.asked = []

    def available_source_ids(self):
        return self.ids

    def select_source_id(self, source_id):
        self.asked.append(source_id)
        return self.accept


shape("select_input_source returns a bool",
      isinstance(I.select_input_source(StubTIS(["com.apple.keylayout.ABC"])), bool))
shape("a present target is selected",
      I.select_input_source(StubTIS(["com.apple.keylayout.ABC"])) is True)
shape("no sources at all is False", I.select_input_source(StubTIS([])) is False)
shape("None from the runtime is False, not a crash", I.select_input_source(StubTIS(None)) is False)
shape("a target that is absent is False",
      I.select_input_source(StubTIS(["com.apple.keylayout.Other"])) is False)
shape("a runtime that refuses the write is False",
      I.select_input_source(StubTIS(["com.apple.keylayout.ABC"], accept=False)) is False)

order = StubTIS(["com.apple.keylayout.US", "com.apple.keylayout.ABC"], accept=False)
I.select_input_source(order)
shape("targets are tried in the order the module declares, not the runtime's",
      order.asked == list(I.TARGET_INPUT_SOURCE_IDS))

for why, ok in checks:
    failed += 0 if ok else 1
    print(f"{'ok  ' if ok else 'FAIL'} {why}")
print(f"\n{'FAILED' if failed else 'all shapes held'} ({failed} unexpected)")
sys.exit(1 if failed else 0)
