#!/usr/bin/env python3
"""Run every guard and every headless drive this repository has, discovered rather than listed.

WHY THIS EXISTS
---------------
Each guard used to be its own step in `ci.yml`, duplicated across `compile` and `test`. Adding
guards is the work, so the file conflicted on three consecutive pull requests — every one of them
appending a step at the same point, and git cannot tell that independent appends are independent.

More than convenience: a hand-maintained list of guards is a second copy of the truth, and it goes
stale in the direction where a guard exists but nothing runs it. That is the same failure the
guards themselves are about, so it should not sit in their runner.

WHAT IT RUNS
------------
  Scripts/check-*.py          guards — refuse a state the repository must not be in
  Scripts/**/test_*.py        drives — call an API and assert what comes back

Both are plain Python needing neither Xcode nor Logic. Anything that needs the running application
belongs in Scripts/livekit/ as a live harness and is not picked up here.

Every discovered file runs even after one fails, because "which guards are broken" is more useful
than "the first one". The exit code is non-zero if any failed.
"""
import glob
import os
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def discovered():
    out = []
    out += sorted(glob.glob(os.path.join(REPO, "Scripts", "check-*.py")))
    out += sorted(glob.glob(os.path.join(REPO, "Scripts", "test_*.py")))
    out += sorted(glob.glob(os.path.join(REPO, "Scripts", "livekit", "test_*.py")))
    # This file is neither a guard nor a drive.
    return [p for p in out if os.path.basename(p) != os.path.basename(__file__)]


def main():
    files = discovered()
    if not files:
        print("no guards or drives discovered — that is not a pass")
        return 1
    print(f"discovered {len(files)} guard(s) and drive(s)\n")
    failures = []
    for path in files:
        rel = os.path.relpath(path, REPO)
        proc = subprocess.run([sys.executable, path], cwd=REPO,
                              capture_output=True, text=True)
        status = "ok  " if proc.returncode == 0 else "FAIL"
        print(f"{status} {rel}")
        if proc.returncode != 0:
            failures.append(rel)
            for line in (proc.stdout + proc.stderr).splitlines():
                print(f"       {line}")
    print()
    if failures:
        print(f"{len(failures)} of {len(files)} failed: {', '.join(failures)}")
        return 1
    print(f"all {len(files)} passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
