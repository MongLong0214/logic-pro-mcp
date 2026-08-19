#!/usr/bin/env python3
"""Drive three more injected modules and assert what comes back.

Fills the return-shape square for `logic_ui_jxa`, `logic_free_tempo_modal`, and the pure half of
`logic_session_bootstrap`. Each was measured for headless drivability separately — that one module
drives is no evidence about another, and guessing would either fabricate a drive or record a wall
that is not there.

WHAT IS MACHINE-BOUND HERE, STATED RATHER THAN OMITTED
------------------------------------------------------
`logic_session_bootstrap.collect_ui_snapshot()` takes no arguments and reads the running
application. It has no seam and is NOT driven below. `bootstrap_fresh_logic_session` is fully
injectable — every dependency arrives as a keyword callable — but it orchestrates a live session
and is left to the live harnesses; a stub-driven run of it would assert the shape of a fiction.

So this module is partly covered, and the report should not be read as saying otherwise.

    python3 test_injected_logic_modules.py
"""
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import logic_free_tempo_modal as F  # noqa: E402
import logic_session_bootstrap as B  # noqa: E402
import logic_ui_jxa as J  # noqa: E402

failed = 0
checks = []


def shape(why, ok):
    checks.append((why, bool(ok)))


def completed(returncode, stdout, stderr=""):
    return subprocess.CompletedProcess(args=["osascript"], returncode=returncode,
                                       stdout=stdout, stderr=stderr)


# --- logic_ui_jxa --------------------------------------------------------------------------------
parsed = J.parse_jxa_json_result(completed(0, '{"a": 1}'))
shape("parse_jxa_json_result returns a dict", isinstance(parsed, dict))
shape("a well-formed payload comes back as itself", parsed == {"a": 1})

broken = J.parse_jxa_json_result(completed(1, "not json", "boom"))
shape("unparseable output is a dict, not an exception", isinstance(broken, dict))
shape("unparseable output is an ERROR, not an empty result", broken.get("status") == "error")
shape("the reason names the cause", broken.get("reason") == "invalid_jxa_output")
shape("stderr is carried, not dropped", broken.get("stderr") == "boom")
shape("stdout is carried so the caller can see what arrived", broken.get("stdout") == "not json")

# The seam: `run` is a parameter, so no osascript is spawned here.
spawned = []


def fake_run(*args, **kwargs):
    spawned.append((args, kwargs))
    return completed(0, "{}")


result = J.run_jxa("ObjC.import('stdlib')", run=fake_run)
shape("run_jxa returns a CompletedProcess", isinstance(result, subprocess.CompletedProcess))
shape("run_jxa used the injected runner and spawned nothing", len(spawned) == 1)

for name, value in [("ui_prelude", J.ui_prelude(marker_constant="M", markers=["a", "b"])),
                    ("save_panel_snapshot_source", J.save_panel_snapshot_source())]:
    shape(f"{name} returns a str", isinstance(value, str))
    shape(f"{name} is not empty", len(value) > 0)
shape("ui_prelude embeds the markers it was given",
      "a" in J.ui_prelude(marker_constant="M", markers=["a"]))


# --- logic_free_tempo_modal ----------------------------------------------------------------------
class StubRunner:
    """Only what the module calls: `detect()`."""

    def __init__(self, snapshot):
        self.snapshot = snapshot

    def detect(self):
        return self.snapshot


for snapshot in ({"status": "not_present"}, {"status": "error", "reason": "osascript_failed"}):
    out = F.detect_free_tempo_modal(runner=StubRunner(snapshot))
    shape(f"detect_free_tempo_modal returns a dict for {snapshot['status']}", isinstance(out, dict))
    shape(f"detect carries the status it was given ({snapshot['status']})",
          out.get("status") == snapshot["status"])

# `pause` is a parameter, so resolve does not actually sleep.
slept = []
resolved = F.resolve_free_tempo_modal(runner=StubRunner({"status": "not_present"}),
                                      pause=lambda seconds: slept.append(seconds))
shape("resolve_free_tempo_modal returns a dict", isinstance(resolved, dict))
shape("resolve did not sleep for real", all(isinstance(s, (int, float)) for s in slept))


# --- logic_session_bootstrap (the pure half) ------------------------------------------------------
shape("detect_language finds English", B.detect_language(["File", "Edit", "Track"]) == "en")
shape("detect_language finds Korean", B.detect_language(["파일", "편집", "트랙"]) == "ko")
shape("detect_language returns None when nothing matches, rather than guessing",
      B.detect_language(["zzz", "qqq"]) is None)
shape("detect_language on an empty menu is None", B.detect_language([]) is None)

for why, ok in checks:
    failed += 0 if ok else 1
    print(f"{'ok  ' if ok else 'FAIL'} {why}")
print(f"\n{'FAILED' if failed else 'all shapes held'} ({failed} unexpected)")
sys.exit(1 if failed else 0)
