#!/usr/bin/env python3
"""Run the three bounce `TestCase` libraries, which have no direct entry point.

WHY THIS EXISTS
---------------
The runner globs `Scripts/check-*.py`, `Scripts/test_*.py` and `Scripts/livekit/test_*.py`. The
nine executable #896 drives now use `test_*.py` and run there. The three bounce libraries retain
their `*_test.py` names because they define `TestCase` classes but no `unittest.main()`.

This is not hypothetical and it was not caught by reading. On 2026-09-19 a change to
`logic_bounce_ui.py` broke THREE cases in `logic_bounce_ui_test.py` -- a hard-coded attempt count,
a script literal that had become a generated table, and an assertion on capitalisation -- and all
67 discovered guards passed. The breakage surfaced only because the author ran the file by hand.

The three libraries have no `unittest.main()`: running them directly exits 0 having asserted
NOTHING. `python3 Scripts/logic_bounce_ui_test.py` was silent while three of its cases were red.

The runner is in `ci.yml`'s macos-15 `test` job, where the AppKit-dependent
`test_logic_key_event.py` can run. The Ubuntu `guards` job retains only shell guards, so it stays
platform-independent. `.github/ci/CI-GATE.json` names this helper command, so it cannot be dropped
without `check-every-ci-job-is-required.py` noticing.

WHAT THIS DOES, AND WHAT IT DOES NOT
------------------------------------
It runs the three libraries through `unittest` discovery, which imports each module and collects
its `TestCase`s whether or not the file calls `main()`.

Exit: 0 = every suite passes and every suite still has its cases - 1 = one does not
"""
import json
import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
#: A seam, so a caller can drive main() at a directory whose suites must fail.
SUITES = os.environ.get("LPM_HELPER_SUITES_DIR") or HERE
#: The committed floor per suite. A seam for the same reason: a case needs a tree of its own.
#:
#: Beside the drive rather than in `docs/canon/`, where this repository's other ratchets live, and
#: the reason is the citation rule: `docs/canon/` is a Logic-facing prefix, so a change touching
#: anything there must cite a row of Apple's data in its pull request body. This file states no
#: fact about Logic -- it counts test cases -- so putting it there would make every future edit
#: manufacture a citation it does not rest on, which is what the citation rule exists to stop.
FLOORS = os.environ.get("LPM_HELPER_SUITE_FLOORS") or os.path.join(HERE, "helper-suite-cases.json")
PATTERN = "logic_bounce_*_test.py"


def _cases(suite):
    for item in suite:
        if isinstance(item, unittest.TestSuite):
            yield from _cases(item)
        else:
            yield item


def distinct_cases(suite) -> dict:
    """Every case once, grouped by the module that DEFINES it.

    Twice matters. `test_logic_bounce.py` imports three `TestCase` classes from its neighbours to
    re-export them, and discovery loads a class wherever it finds it, so 32 cases were being run --
    and counted -- twice. The drive reported "167 case(s) pass" over 135 distinct ones. Grouping by
    the DEFINING module rather than the file discovery found it in is what makes a floor per suite
    mean anything: otherwise deleting a suite's cases could be hidden by an aggregator importing
    them from somewhere else.
    """
    by_module = {}
    for case in _cases(suite):
        by_module.setdefault(type(case).__module__, {})[case.id()] = case
    return by_module


def floors() -> dict:
    try:
        with open(FLOORS, encoding="utf-8") as handle:
            return json.load(handle).get("suites") or {}
    except (OSError, json.JSONDecodeError):
        return {}


def floor_problems(by_module: dict, committed: dict) -> list:
    """A suite that quietly stops contributing cases, and a suite nobody declared.

    The drive used to refuse only when the TOTAL was zero. A suite whose cases vanish -- a class
    renamed, an import guard that stops being satisfied, a file that stops defining `TestCase`s --
    lowers the total and passes, which is the same shape as a guard that checks nothing.
    """
    problems = []
    if not committed:
        problems.append(
            f"{os.path.relpath(FLOORS, os.path.dirname(HERE))} names no suite, so nothing here has "
            f"a floor and a suite losing every case would pass. That is a missing or unreadable "
            f"file, not a repository with no suites.")
        return problems
    for module, cases in sorted(by_module.items()):
        if module not in committed:
            problems.append(
                f"{module} has {len(cases)} case(s) and no floor in "
                f"{os.path.basename(FLOORS)}. Declare it, or a later change that empties it is "
                f"invisible.")
        elif len(cases) < committed[module]:
            problems.append(
                f"{module} contributes {len(cases)} case(s), below its committed floor of "
                f"{committed[module]}. Cases do not disappear by "
                f"accident: either a class stopped being discovered, or the floor is being lowered "
                f"and that belongs in the diff.")
    for module, floor in sorted(committed.items()):
        if module not in by_module:
            problems.append(
                f"{module} is declared with a floor of {floor} and discovery found NONE of it. A "
                f"suite nothing runs is the defect this drive exists to close.")
    return problems


def main() -> int:
    # Imported by path, so the modules under test must be importable the way they import each
    # other -- `logic_bounce_ui` imports `logic_ui_labels` from the same directory.
    if SUITES not in sys.path:
        sys.path.insert(0, SUITES)
    discovered = unittest.defaultTestLoader.discover(SUITES, pattern=PATTERN, top_level_dir=SUITES)
    by_module = distinct_cases(discovered)
    total = sum(len(cases) for cases in by_module.values())
    if total == 0:
        print(f"no {PATTERN} suite under {SUITES}, so this drive has nothing to run and an empty "
              f"expectation would pass against anything.", file=sys.stderr)
        return 1
    problems = floor_problems(by_module, floors())
    if problems:
        print(f"{len(problems)} problem(s) with what the {PATTERN} suites still carry:",
              file=sys.stderr)
        for problem in problems:
            print(f"  {problem}", file=sys.stderr)
        return 1
    suite = unittest.TestSuite(case for cases in by_module.values() for case in cases.values())
    result = unittest.TextTestRunner(stream=sys.stderr, verbosity=1).run(suite)
    if not result.wasSuccessful():
        print(f"{len(result.failures)} failure(s) and {len(result.errors)} error(s) in the "
              f"non-executable bounce test libraries -- see #896.", file=sys.stderr)
        return 1
    print(f"{total} distinct case(s) pass across {len(by_module)} non-executable bounce test "
          f"suite(s), each at or above its committed floor")
    return 0


if __name__ == "__main__":
    sys.exit(main())
