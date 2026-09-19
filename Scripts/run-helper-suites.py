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

WHY IT IS NOT NAMED `test_*.py`
-------------------------------
`run-repo-guards.py` runs on ubuntu, and that is a MEASURED property: every guard it discovers was
checked to need neither Xcode nor macOS before the job moved there. Named `test_*.py` this drive
WAS discovered, ran on Linux, and `logic_key_event_test.py` failed with `no such module 'AppKit'`
-- it compiles `logic_key_event.swift`, which imports AppKit and CoreGraphics. The drive had
quietly made the guards job platform-dependent, and CI said so on the first run.

Declaring the skip was the other option and it is wrong twice: `docs/canon/CI-SKIPS.json` may only
SHRINK, so the allowance could not be added; and a suite skipped on the only machine that runs it
is a suite nobody runs, which is the defect this file exists to close.

So it is NOT discovered. `ci.yml`'s `test` job runs it on macos-15, where these suites can actually
run, and `docs/canon/CI-GATE.json`'s `required_commands` -- a list that may only GROW -- names the
command, so the step cannot be dropped without `check-every-ci-job-is-required.py` noticing.

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
#: A seam, so a caller can drive main() at a directory whose suites must fail.
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
