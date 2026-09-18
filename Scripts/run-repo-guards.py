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

EXIT 0 IS NOT EVIDENCE THAT ANYTHING RAN
----------------------------------------
This file keyed on the exit code alone, and two guards were found reporting `ok` having asserted
nothing:

  * `test_canon_citations_guard.py` raised `SkipTest` at module level when it could not find a
    fixture. Sixty cases, zero assertions, exit 0. Its own docstring described that exact defect
    being found and fixed -- in a replacement that kept the skip.
  * `test_logic_canon.py` read its input from `/tmp`, which macOS rebuilds at boot, and skipped
    when it was gone. The case carrying the measurement this repository's canon axis rests on.

So a child must now show that it ran something. `Ran 0 tests` is a failure, no output at all is a
failure, and skips are counted and printed rather than swallowed. Under CI a skip must be declared
in `docs/canon/CI-SKIPS.json` with a reason and a number -- CI has no Logic, and the four cases that
need it are the only honest skip in the tree.

A HUNG GUARD IS A FAILURE, NOT A WAIT
-------------------------------------
Every child ran with no deadline. One that blocks -- a network read nobody bounded, a `communicate`
on a pipe nothing closes -- consumed the whole job's 60-minute budget and ended as a timeout on the
JOB, which names no script. Each child now gets `LPM_GUARD_TIMEOUT` seconds (default below, chosen
from measured times rather than from a round number), is started in its own session, and is killed
by process GROUP on expiry so a child's own children go with it. The timeout is a FAILURE with the
script's name on it.

WHERE THE TIME GOES
-------------------
Measured on the 2026-09-17 main run: this runner was 13.3 minutes of `compile` and 11.7 of `test`,
which is most of both, and it printed nothing until a script finished. Each one now announces itself
before it runs and reports its own wall time after, the summary names the slowest, and each child's
output is kept in a per-run temporary directory instead of being interleaved into the log. Being
able to say WHICH guard is slow is the whole point; a total with no breakdown is what made this
invisible for as long as it was.
"""
import glob
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def discovered():
    out = []
    out += sorted(glob.glob(os.path.join(REPO, "Scripts", "check-*.py")))
    out += sorted(glob.glob(os.path.join(REPO, "Scripts", "test_*.py")))
    out += sorted(glob.glob(os.path.join(REPO, "Scripts", "livekit", "test_*.py")))
    # This file is neither a guard nor a drive.
    return [p for p in out if os.path.basename(p) != os.path.basename(__file__)]


#: Seconds any one guard may take. 600 is ~24x the slowest measured today, which is the right
#: shape for a deadline that exists to catch a HANG and not to police a slow check: a guard that
#: doubles in cost should be seen in the timing column, not killed by the runner.
DEFAULT_TIMEOUT = 600


def _timeout() -> int:
    raw = os.environ.get("LPM_GUARD_TIMEOUT")
    if raw is None:
        return DEFAULT_TIMEOUT
    try:
        value = int(raw)
    except ValueError:
        raise SystemExit(f"LPM_GUARD_TIMEOUT={raw!r} is not an integer number of seconds")
    if value <= 0:
        raise SystemExit("LPM_GUARD_TIMEOUT must be positive; a deadline of zero kills every guard")
    return value


def _isolated_env(cache_root, index):
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

    Each child keeps its OWN prefix -- sharing one would undo the isolation the paragraph above is
    about -- but they now live under a directory this run deletes, instead of `mkdtemp` leaking one
    per guard into the system temp for the life of the machine.
    """
    env = dict(os.environ)
    prefix = os.path.join(cache_root, f"pyc-{index:03d}")
    os.makedirs(prefix, exist_ok=True)
    env["PYTHONPYCACHEPREFIX"] = prefix
    return env


def _run(path, env, deadline):
    """(returncode, output, seconds, timed_out), killing the child's whole process group on expiry.

    `start_new_session` puts the child in its own process group so `killpg` reaches ITS children
    too. A guard that spawned a subprocess and hung would otherwise leave that grandchild holding
    the pipe open, and `communicate()` after the kill would block on exactly the thing being
    cleaned up.
    """
    started = time.monotonic()
    proc = subprocess.Popen([sys.executable, path], cwd=REPO, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, text=True, env=env, start_new_session=True)
    try:
        out, _ = proc.communicate(timeout=deadline)
        return proc.returncode, out, time.monotonic() - started, False
    except subprocess.TimeoutExpired:
        try:
            os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            proc.kill()
        out, _ = proc.communicate()
        return None, out or "", time.monotonic() - started, True


RAN = re.compile(r"^Ran (\d+) tests? in ", re.M)
SKIPPED = re.compile(r"\bskipped=(\d+)")


#: A `check-*.py` carrying this exact sentence declares that it counts rather than refuses. The
#: runner prints `rept` for it, so the log does not claim it as coverage.
NOT_A_GATE = "#: NOT A GATE"


def _source_of(path: str) -> str:
    try:
        with open(path, encoding="utf-8") as handle:
            return handle.read()
    except OSError:
        return ""


def evidence_of_work(text: str):
    """(skips, reason it does not count as a run). `None` reason means it ran something.

    Two shapes reach here. `unittest` prints `Ran N tests`, which is exact. A plain-assert script
    prints whatever it prints, so the only evidence available is that it printed at all -- weaker,
    and true of all 48 files discovered today, so it is a floor rather than a guess.
    """
    ran = RAN.search(text)
    skipped = SKIPPED.search(text)
    skips = int(skipped.group(1)) if skipped else 0
    if ran:
        return skips, None if int(ran.group(1)) else "ran 0 tests"
    return skips, None if text.strip() else "produced no output"


def allowed_skips(rel: str) -> tuple:
    """(how many skips this guard may report under CI, why). Read from a file so it is ratcheted."""
    path = os.path.join(REPO, "docs", "canon", "CI-SKIPS.json")
    try:
        with open(path, "r", encoding="utf-8") as handle:
            allowed = (json.load(handle) or {}).get("allowed") or {}
    except (OSError, json.JSONDecodeError):
        return 0, "docs/canon/CI-SKIPS.json could not be read, so nothing is allowed to skip"
    row = allowed.get(rel) or {}
    return int(row.get("skips") or 0), row.get("why") or ""


#: How many of the slowest guards the summary names. Enough to see where a regression landed,
#: short enough that the interesting lines are not buried under 48 of them.
SLOWEST = 8


def main():
    files = discovered()
    if not files:
        print("no guards or drives discovered — that is not a pass")
        return 1
    deadline = _timeout()
    print(f"discovered {len(files)} guard(s) and drive(s); {deadline}s each\n", flush=True)
    workdir = tempfile.mkdtemp(prefix="lpm-guards-")
    failures, timings = [], []
    try:
        logs = os.path.join(workdir, "logs")
        os.makedirs(logs, exist_ok=True)
        for index, path in enumerate(files):
            rel = os.path.relpath(path, REPO)
            # Before, not after, and on its own line. A runner that prints only on completion
            # says nothing at all while the guard that is hanging is the one still running, and
            # `\r` to overwrite it is not an option: GitHub's log viewer renders the carriage
            # return literally, so the "tidier" version is the unreadable one.
            print(f"→   {rel}", flush=True)
            code, text, seconds, timed_out = _run(path, _isolated_env(workdir, index), deadline)
            timings.append((seconds, rel))
            log = os.path.join(logs, f"{index:03d}-{rel.replace(os.sep, '_')}.log")
            with open(log, "w", encoding="utf-8") as handle:
                handle.write(text)
            skips, vacuous = evidence_of_work(text)
            budget, why = allowed_skips(rel)
            over_budget = (os.environ.get("CI") == "true" and skips > budget)
            broken = timed_out or code != 0 or vacuous is not None or over_budget
            note = f" ({skips} skipped)" if skips else ""
            # A script that CANNOT refuse anything must not print `ok` beside the ones that can.
            #
            # `check-variants-appear-in-a-census.py` returns 0 unconditionally and says so in its
            # own closing comment -- it counts a gap it is deliberately not gating yet, and gating
            # it today would seed a ratchet with 600 entries nobody has read. That is a defensible
            # decision. What is not defensible is that it is discovered by the `check-*.py` glob
            # and reports `ok` in the same column as the rules that refuse things, so the log reads
            # as 62 checks passing when it is 61 checks and one report.
            #
            # The marker is the script's own declaration, and it is one line in each place rather
            # than a category the runner has to maintain.
            kind = "rept" if NOT_A_GATE in _source_of(path) else "ok  "
            print(f"{'FAIL' if broken else kind} {rel}{note}  {seconds:.1f}s", flush=True)
            if not broken:
                continue
            failures.append(rel)
            if timed_out:
                print(f"       it did not finish within {deadline}s and its process group was "
                      f"killed. A guard with no deadline spends the JOB's budget instead, and a "
                      f"job timeout names no script. Raise LPM_GUARD_TIMEOUT only if this one is "
                      f"genuinely that slow.")
            if vacuous is not None:
                print(f"       it exited 0 and {vacuous}. An exit code is not evidence that a "
                      f"check ran; a guard that asserts nothing reports the same as one that "
                      f"passed.")
            if over_budget:
                print(f"       it skipped {skips} under CI and docs/canon/CI-SKIPS.json allows "
                      f"{budget}{' (' + why + ')' if why else ''}. Declare the skip with a reason "
                      f"or remove it -- a skip exits 0.")
            for line in text.splitlines():
                print(f"       {line}")
        print()
        total = sum(seconds for seconds, _ in timings)
        print(f"{total:.1f}s total; slowest:")
        for seconds, rel in sorted(timings, reverse=True)[:SLOWEST]:
            print(f"  {seconds:7.1f}s  {rel}")
        print()
        if failures:
            print(f"{len(failures)} of {len(files)} failed: {', '.join(failures)}")
            return 1
        # "all 65 passed" is the sentence a release note quotes, so it must not count a file
        # that cannot fail as a check that did not.
        reports = sum(1 for f in files if NOT_A_GATE in _source_of(f))
        if reports:
            print(f"all {len(files)} passed — {len(files) - reports} that can refuse, "
                  f"{reports} that only count (`rept` above)")
        else:
            print(f"all {len(files)} passed")
        return 0
    finally:
        # `mkdtemp` per child leaked one directory per guard, per run, for the life of the machine.
        # One root, deleted here, whether this returned or raised.
        shutil.rmtree(workdir, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
