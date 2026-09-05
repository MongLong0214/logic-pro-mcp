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
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def discovered():
    out = []
    out += sorted(glob.glob(os.path.join(REPO, "Scripts", "check-*.py")))
    out += sorted(glob.glob(os.path.join(REPO, "Scripts", "test_*.py")))
    out += sorted(glob.glob(os.path.join(REPO, "Scripts", "livekit", "test_*.py")))
    # This file is neither a guard nor a drive.
    return [p for p in out if os.path.basename(p) != os.path.basename(__file__)]


def _isolated_env():
    """A child environment whose bytecode cache is empty and per-run.

    Every guard here loads the module it checks with `spec_from_file_location`, which goes through
    the ordinary bytecode cache. On this platform that cache is redirected out of the tree
    (`sys.pycache_prefix` = ~/Library/Caches/com.apple.python), so `rm -rf __pycache__` inside the
    repository clears nothing and a stale entry outlives any edit made here.

    Measured 2026-09-05: a guard whose source on disk resolved evidence paths with `realpath` was
    executing an older compiled body that used `normpath`, so its self-test reported a symlink
    escape as unblocked while the shipped source blocked it. Copying the identical bytes to a new
    filename passed. A cache that can serve a different body than the file being reviewed defeats
    every claim these guards make, so each run gets its own empty prefix.
    """
    env = dict(os.environ)
    env["PYTHONPYCACHEPREFIX"] = tempfile.mkdtemp(prefix="lpm-pyc-")
    return env


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
                              capture_output=True, text=True, env=_isolated_env())
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
