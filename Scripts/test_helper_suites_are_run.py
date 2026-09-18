#!/usr/bin/env python3
"""Run the `*_test.py` suites, which `run-repo-guards.py` does not discover.

WHY THIS EXISTS
---------------
The runner globs `Scripts/check-*.py`, `Scripts/test_*.py` and `Scripts/livekit/test_*.py`. Twelve
suites are named `*_test.py` instead and are found by none of it, so a pull request can break any
of them and CI stays green (#896).

That is not hypothetical and it was not caught by reading. On 2026-09-19 a change to
`logic_bounce_ui.py` broke THREE cases in `logic_bounce_ui_test.py` -- a hard-coded attempt count,
a script literal that had become a generated table, and an assertion on capitalisation -- and all
67 discovered guards passed. The breakage surfaced only because the author ran the file by hand.

Worse, three of the twelve have no `unittest.main()`: running them directly exits 0 having asserted
NOTHING. `python3 Scripts/logic_bounce_ui_test.py` was silent while three of its cases were red.

WHAT THIS DOES, AND WHAT IT DOES NOT
------------------------------------
It runs them through `unittest` discovery, which imports each module and collects its `TestCase`s
whether or not the file calls `main()`. It does NOT rename anything: #896 proposes renaming the
nine standalone suites, which is the tidier end state and touches twelve files plus whatever refers
to them. One discovered drive closes the gap for all twelve today, and the rename can still happen.

Exit: 0 = every suite passes - 1 = one does not
"""
import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
#: A seam, so the self-test can drive main() at a directory whose suites must fail.
SUITES = os.environ.get("LPM_HELPER_SUITES_DIR") or HERE
PATTERN = "*_test.py"


def main() -> int:
    # Imported by path, so the modules under test must be importable the way they import each
    # other -- `logic_bounce_ui` imports `logic_ui_labels` from the same directory.
    if SUITES not in sys.path:
        sys.path.insert(0, SUITES)
    suite = unittest.defaultTestLoader.discover(SUITES, pattern=PATTERN, top_level_dir=SUITES)
    count = suite.countTestCases()
    if count == 0:
        print(f"no {PATTERN} suite under {SUITES}, so this drive has nothing to run and an empty "
              f"expectation would pass against anything.", file=sys.stderr)
        return 1
    result = unittest.TextTestRunner(stream=sys.stderr, verbosity=1).run(suite)
    if not result.wasSuccessful():
        print(f"{len(result.failures)} failure(s) and {len(result.errors)} error(s) in suites "
              f"`run-repo-guards.py` does not discover. They are named {PATTERN}, which its globs "
              f"do not match -- see #896.", file=sys.stderr)
        return 1
    print(f"{count} case(s) pass across the {PATTERN} suites the runner does not discover")
    return 0


if __name__ == "__main__":
    sys.exit(main())
