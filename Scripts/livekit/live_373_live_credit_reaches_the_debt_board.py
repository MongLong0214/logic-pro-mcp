#!/usr/bin/env python3
"""Live proof that a real qualification run's passes reach the debt board.

Usage:  LPM_EVIDENCE_ROOT=/abs/path/outside/repo \
        python3 live_373_live_credit_reaches_the_debt_board.py <worktree> <full-40-char-head-sha>

WHAT WAS WRONG
--------------
Two evaluators answer "did this operation pass live qualification?". `PromotionGate` reads a real
attestation at release time. `ProductionReadinessContracts` reports the R-SEM debt over the same
question on the repository tree -- and took NO LIVE INPUT AT ALL, so it counted every registered
operation as uncovered no matter how much evidence existed. Running the whole live matrix to
completion would not have moved its number by one operation. R-SEM was not open because coverage
was short; it was open because nothing could reach it.

WHY THIS IS A HARNESS AND NOT A UNIT TEST
-----------------------------------------
The unit tests build cases by hand and prove the predicate. They cannot say that a REAL drive of the
release binary against a running Logic produces cases the predicate accepts -- and that gap is the
whole point: review named it as the thing still untested after the channel was added. So this reads
what a real 113-operation drive produced, from outside the product, and follows those results all
the way to the number the debt board prints.

THE COUNTEREXAMPLE
------------------
An evaluator that ignored the new parameter would report the same missing count with and without
credit, and the DROP would be zero -- while "the drop equals the credited set" stayed true, because
zero equals zero. That shape is the counterexample below, and it is why the check requires the
credited set to be non-empty as well as exact. A live run that credited nothing satisfies every
other clause.

The exactness matters on its own: crediting an operation twice, or crediting one the registry does
not list, would still SHRINK the count. Only "the drop is exactly the credited set" separates a
channel that works from one that merely moves the number.

This is a `non_ui` run: the subject is a number two evaluators compute, and there is no rectangle to
photograph.
"""
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import evidence as E  # noqa: E402


COVERS = [
    "Sources/LogicProMCP/Qualification/PromotionGate.swift",
    "Sources/LogicProMCP/Qualification/ProductionReadinessContracts.swift",
]

WT = sys.argv[1] if len(sys.argv) > 1 else ""
HEAD = sys.argv[2] if len(sys.argv) > 2 else ""
if not WT or not HEAD:
    sys.exit(__doc__)

E.REPO = WT
E.BIN = f"{WT}/.build/release/LogicProMCP"
missing = E.have_tools()
if missing:
    sys.exit(f"cannot run: missing {missing}")

ev = E.Evidence(HEAD, os.environ["LPM_EVIDENCE_ROOT"], surface="non_ui")

# The drive is the release binary talking to the running Logic; the test that performs it is
# `.enabled(if:)` on that binary existing, so a missing release build would SKIP rather than fail
# and this harness would read no line at all. That is caught below rather than assumed.
proc = subprocess.run(
    ["swift", "test", "--filter",
     "realReleaseBinaryExecutesEveryOperationWithIndependentReadback"],
    cwd=WT, capture_output=True, text=True, timeout=3600,
)
out = proc.stdout + proc.stderr
line = re.search(
    r"373 live-credit: credited=(\d+) registered=(\d+) missingWithoutCredit=(\d+) "
    r"missingWithCredit=(\d+) dropIsExactlyTheCreditedSet=(\w+) "
    r"everyCreditedOperationIsRegistered=(\w+)", out)
short = re.search(r"read-only short of passed \((\d+) of (\d+)\)", out)

reading = {
    "drive_exit": proc.returncode,
    "credited": int(line.group(1)) if line else 0,
    "registered": int(line.group(2)) if line else 0,
    "missing_without_credit": int(line.group(3)) if line else 0,
    "missing_with_credit": int(line.group(4)) if line else 0,
    "drop_is_exactly_the_credited_set": (line.group(5) == "true") if line else False,
    "every_credited_operation_is_registered": (line.group(6) == "true") if line else False,
    "read_only_short_of_passed": int(short.group(1)) if short else -1,
    "read_only_total": int(short.group(2)) if short else -1,
}

ev.falsifiable(
    "373/a-real-run-moves-the-debt-board",
    lambda o: (o["drive_exit"] == 0
               and o["credited"] > 0
               and o["missing_without_credit"] == o["registered"]
               and o["missing_with_credit"] == o["registered"] - o["credited"]
               and o["drop_is_exactly_the_credited_set"]
               and o["every_credited_operation_is_registered"]),
    reading,
    {"drive_exit": 0, "credited": 0, "registered": 113,
     "missing_without_credit": 113, "missing_with_credit": 113,
     "drop_is_exactly_the_credited_set": True,
     "every_credited_operation_is_registered": True,
     "read_only_short_of_passed": 2, "read_only_total": 23},
    "a real drive of the release binary against the running Logic produced cases that the release "
    "gate's own pass predicate accepts, and feeding exactly those to the static evaluator moved its "
    "missing count down by exactly that many. The counterexample is an evaluator that ignores the "
    "parameter: it reports the same count with and without credit, so the DROP is zero -- and "
    "'the drop equals the credited set' is still TRUE, because zero equals zero. That is why the "
    "credited set must be non-empty as well as exact, and why `missing_without_credit == registered` "
    "is checked too: without it, a tree that already credited everything would also pass",
    mutation="drop the `liveCreditedOperationIDs` early-return from the missingSemantic filter",
)

ev.check("373/the-drive-actually-ran",
         reading["read_only_total"] == 23 and reading["credited"] > 0,
         "the qualification drive reported its read-only census, so the numbers above come from a "
         "run that happened rather than from a skipped test whose absent output parses as zeros",
         f"read_only_total={reading['read_only_total']} credited={reading['credited']}", None)

ev.check("373/credit-is-not-the-whole-registry",
         0 < reading["credited"] < reading["registered"],
         "credit is a measurement, not a constant: the 90 mutating operations cannot reach `passed` "
         "by design, so a run crediting all 113 would mean the predicate had stopped discriminating",
         f"credited={reading['credited']} of {reading['registered']}", None)

# The drive above happens inside the test process, so the receipt has no record of this harness
# touching the product. One call afterwards puts a driven operation in the document — the same
# reason `live_736` makes one. It is not the subject of the run; the subject is the number two
# evaluators computed from the drive.
#
# It runs AFTER the test rather than before, because the test owns a server of its own and two
# transports against one Logic is a race this harness has no reason to take.
#
# `refresh_cache`, not `health`: health is served from the poller cache, and the framework records a
# cached read presented as live — which invalidated the first run of this harness, correctly.
d = E.Driver()
d.tool("logic_system", "refresh_cache")

print(ev.write())
