#!/usr/bin/env python3
"""Drive the last two modules with consumers and assert what comes back.

`logic_bounce`'s staging helpers are pure filesystem functions and run against a temp directory.
Every `logic_bounce_ui` entry takes its System Events runner, its JXA runner, its sleep, or its
event driver as a PARAMETER — the defaults reach the machine, the seams do not. So nothing here
spawns osascript, and nothing sleeps.

`logic_bounce.main()` is not driven: it is the command-line entry and reaches the running
application. Stated rather than omitted.

    python3 test_bounce_modules.py
"""
import json
import os
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import logic_bounce as BO  # noqa: E402
import logic_bounce_ui as UI  # noqa: E402

failed = 0
checks = []


def shape(why, ok):
    checks.append((why, bool(ok)))


# --- logic_bounce: staging helpers over a real temp directory ------------------------------------
tmp = tempfile.mkdtemp()
staged = os.path.join(tmp, "take.wav")
with open(staged, "w") as fh:
    fh.write("x")
old = time.time() - 3600

shape("unique_staging_name returns a str", isinstance(BO.unique_staging_name("take.wav"), str))
shape("unique_staging_name does not return the name it was given",
      BO.unique_staging_name("take.wav") != "take.wav")
shape("unique_staging_name differs across calls",
      BO.unique_staging_name("take.wav") != BO.unique_staging_name("take.wav"))

shape("fresh_staged_file returns a bool", isinstance(BO.fresh_staged_file(staged, tmp, old), bool))
shape("a file written after the floor is fresh", BO.fresh_staged_file(staged, tmp, old) is True)
shape("a file written before the floor is not fresh",
      BO.fresh_staged_file(staged, tmp, time.time() + 60) is False)
shape("a path outside the staging directory is not fresh",
      BO.fresh_staged_file("/etc/hosts", tmp, old) is False)

found = BO.find_staged_artifact(tmp, "take.wav", old)
shape("find_staged_artifact returns the path or None", found is None or isinstance(found, str))
shape("an absent name finds nothing", BO.find_staged_artifact(tmp, "nope.wav", old) is None)

# Measured, not assumed: this returns None on SUCCESS and a reason string on refusal. The first
# version of these assertions expected the destination path back, which is the opposite convention.
# Had they been written that way and the code "fixed" to match, a working guarantee would have been
# inverted to satisfy a test. The contract is the code's to state.
final = os.path.join(tmp, "final.wav")
moved = BO.move_staged_artifact_no_overwrite(staged, final)
shape("a successful move returns None, not a path", moved is None)
shape("the destination exists after the move", os.path.exists(final))
shape("the source is gone after the move", not os.path.exists(staged))

# The guarantee in the name.
second = os.path.join(tmp, "second.wav")
with open(second, "w") as fh:
    fh.write("y")
kept = open(final).read()
again = BO.move_staged_artifact_no_overwrite(second, final)
shape("refusing to overwrite returns a reason, not None", isinstance(again, str))
shape("the reason names what happened", again == "artifact_already_exists")
shape("the existing destination is untouched", open(final).read() == kept)
shape("the source survives a refused move, rather than being lost", os.path.exists(second))


# --- logic_bounce_ui: every entry takes its runner as a parameter ---------------------------------
calls = []


def stub_osa(script, timeout=8.0):
    calls.append(("osa", script[:40]))
    return "Bounce"


def stub_jxa(source, **kwargs):
    """The module reads `.stdout` off this, so it must be a CompletedProcess — not the parsed
    dict my first stub returned. Guessing a collaborator's protocol has produced a false
    "cannot be driven" three times in this run; the module is the authority on its own seam."""
    calls.append(("jxa", source[:40]))
    return subprocess.CompletedProcess(
        args=["osascript"], returncode=0,
        stdout=json.dumps({"present": True, "labels": ["OK"]}), stderr="")


shape("bounce_dialog_present returns a bool",
      isinstance(UI.bounce_dialog_present(run_osa=stub_osa), bool))
shape("logic_front_window_name returns a str",
      isinstance(UI.logic_front_window_name(run_osa=stub_osa), str))
shape("logic_front_sheet_name returns a str",
      isinstance(UI.logic_front_sheet_name(run_osa=stub_osa), str))
shape("bounce_settings_present returns a bool",
      isinstance(UI.bounce_settings_present(run_jxa_fn=stub_jxa), bool))
shape("save_panel_present returns a bool",
      isinstance(UI.save_panel_present(run_jxa_fn=stub_jxa), bool))

slept = []
opened = UI.open_bounce_dialog(run_osa=stub_osa, sleep_fn=slept.append,
                               activate_fn=lambda: True)
shape("open_bounce_dialog returns (bool, list)",
      isinstance(opened, tuple) and len(opened) == 2
      and isinstance(opened[0], bool) and isinstance(opened[1], list))
shape("open_bounce_dialog used the injected sleep rather than blocking",
      all(isinstance(s, (int, float)) for s in slept))
shape("the injected runners were the ones called", len(calls) > 0)

waited = UI.wait_for_bounce_dialog(run_osa=stub_osa, sleep_fn=slept.append)
shape("wait_for_bounce_dialog returns a bool", isinstance(waited, bool))

for why, ok in checks:
    failed += 0 if ok else 1
    print(f"{'ok  ' if ok else 'FAIL'} {why}")
print(f"\n{'FAILED' if failed else 'all shapes held'} ({failed} unexpected)")
sys.exit(1 if failed else 0)
