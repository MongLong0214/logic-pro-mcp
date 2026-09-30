#!/usr/bin/env python3
"""Prove the #993 harness's `osa` restarts System Events only when it refuses GUI scripting.

Measured 2026-09-29 (#904 r5): a System Events respawned mid-run answered every osascript GUI read
with -25211 while python AX kept working; `killall "System Events"` made the next on-demand
instance answer. `osa` restarts it once on -25211 and retries once; every other failure is returned
as before. The cases fake `subprocess.run` and `time.sleep`, so nothing here runs osascript,
killall or waits on the clock.

    python3 test_osa_restarts_refusing_system_events.py
"""
import importlib.util
import os
import subprocess
import sys
import types

HERE = os.path.dirname(os.path.abspath(__file__))
NAME = "live_993_plugin_root_menu_in_every_locale.py"
REFUSED = "osascript에 보조 접근이 허용되지 않습니다. (-25211)"
NO_OBJECT = "execution error: System Events got an error: Can't get window 1. (-1728)"

failed = 0


def check(label, ok):
    global failed
    print(("ok   " if ok else "FAIL ") + label)
    failed += 0 if ok else 1


def load():
    saved = sys.argv
    sys.argv = ["x"]
    try:
        spec = importlib.util.spec_from_file_location(NAME[:-3], os.path.join(HERE, NAME))
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
    finally:
        sys.argv = saved
    return module


def drive(module, answers):
    """Run `osa` against canned osascript results; return (result, killalls, osascripts, sleeps)."""
    calls, sleeps = [], []
    queue = list(answers)

    def run(argv, **_):
        calls.append(argv)
        if argv[0].endswith("killall"):
            return subprocess.CompletedProcess(argv, 0, "", "")
        # Past the canned answers osascript keeps giving the last one, as a stuck System Events would.
        answer = queue.pop(0) if len(queue) > 1 else queue[0]
        if isinstance(answer, BaseException):
            raise answer
        code, out, err = answer
        return subprocess.CompletedProcess(argv, code, out, err)

    module.subprocess = types.SimpleNamespace(run=run, TimeoutExpired=subprocess.TimeoutExpired)
    module.time = types.SimpleNamespace(sleep=sleeps.append)
    del module.SYSTEM_EVENTS_RESTARTS[:]
    result = module.osa('tell application "System Events" to get name of every window')
    killalls = [argv for argv in calls if argv[0].endswith("killall")]
    osascripts = [argv for argv in calls if argv[0].endswith("osascript")]
    return result, killalls, osascripts, sleeps


module = load()

result, killalls, osascripts, sleeps = drive(module, [(1, "", REFUSED), (0, "lpm-reply\n", "")])
restarts = list(module.SYSTEM_EVENTS_RESTARTS)
check("A: -25211 then success returns the retry's stdout", result == "lpm-reply")
check("A: exactly one killall, of System Events",
      killalls == [["/usr/bin/killall", "System Events"]])
check("A: the same script is sent twice", len(osascripts) == 2 and osascripts[0] == osascripts[1])
check("A: one wait after the kill, through the injectable delay",
      sleeps == [module.SYSTEM_EVENTS_RELAUNCH_WAIT])
check("A: one restart recorded with a timestamp and the triggering stderr",
      len(restarts) == 1 and restarts[0]["at"] and "-25211" in restarts[0]["stderr_tail"])

result, killalls, osascripts, _ = drive(module, [(1, "", REFUSED), (1, "", REFUSED)])
check("B: -25211 twice returns None", result is None)
check("B: exactly one killall and two osascript runs", len(killalls) == 1 and len(osascripts) == 2)
check("B: one restart recorded", len(module.SYSTEM_EVENTS_RESTARTS) == 1)

result, killalls, osascripts, sleeps = drive(module, [(1, "", NO_OBJECT)])
check("C: -1728 returns None", result is None)
check("C: -1728 kills nothing, retries nothing and waits for nothing",
      killalls == [] and len(osascripts) == 1 and sleeps == [])
check("C: no restart recorded", module.SYSTEM_EVENTS_RESTARTS == [])

result, killalls, osascripts, _ = drive(module, [(0, "1\n", "")])
check("D: success returns stdout", result == "1")
check("D: success kills nothing and runs once", killalls == [] and len(osascripts) == 1)
check("D: no restart recorded", module.SYSTEM_EVENTS_RESTARTS == [])

result, killalls, osascripts, _ = drive(module, [subprocess.TimeoutExpired("osascript", 20)])
check("E: a timeout returns None without a killall or a retry",
      result is None and killalls == [] and len(osascripts) == 1)
check("E: no restart recorded", module.SYSTEM_EVENTS_RESTARTS == [])

sys.exit(1 if failed else 0)
