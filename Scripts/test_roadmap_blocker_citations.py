#!/usr/bin/env python3
"""Drive `check-roadmap-blockers-cite-measurements.py` and watch it fail.

A guard nobody has seen fail is a guard nobody has tested. Each case below feeds the guard's own
predicate a table and asserts the verdict, including the two refusals — an unparseable file and a
file with no OPEN rows both have to come back as "cannot tell", not as clean.

The offending rows are the real ones from 2026-08-30, before they were corrected.
"""
import importlib.util
import os
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GUARD = os.path.join(REPO, "Scripts", "check-roadmap-blockers-cite-measurements.py")

spec = importlib.util.spec_from_file_location("roadmap_blocker_guard", GUARD)
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)

HEADER = "| ADR | issue | state | what it is waiting on |\n|---|---|---|---|\n"

# Verbatim from docs/roadmap/README.md before the correction. Each asserts a fact about a surface
# and none of the three had been measured against the surface it names.
UNCITED = HEADER + "\n".join([
    "| ADR-013 | #301 | OPEN | **zero band operations registered** — no public surface; the AX plane a readback needs is not exposed |",
    "| ADR-017 | #305 | OPEN | AU parameter view observed AX-opaque; starts with a measurement |",
    "| ADR-018 | #306 | OPEN | same wall as #305 |",
]) + "\n"

CITED_BY_DATE = HEADER + (
    "| ADR-013 | #301 | OPEN | measured 2026-08-30, Channel EQ exposes 24 named settable sliders; "
    "the opacity claim came from a census run outside Logic |\n"
)

CITED_BY_COMMENT = HEADER + (
    "| ADR-018 | #306 | OPEN | Tier B is not opaque — "
    "https://github.com/MongLong0214/logic-pro-mcp/issues/299#issuecomment-5466600291 |\n"
)

# No wall mentioned at all. "Behind a dependency" and "not started" are not claims about a
# surface, so the guard must leave them alone or it becomes a tax on ordinary rows.
NO_CLAIM = HEADER + "\n".join([
    "| ADR-011 | #299 | OPEN | behind #292 |",
    "| ADR-015 | #303 | OPEN | behind #293; what is missing is a maker, not a measurement |",
]) + "\n"

# A row DENYING a wall is making the same kind of claim and owes the same date. This is the real
# #304 row as it stood, and letting it through is how "there is no obstacle here" becomes something
# everybody believes and nobody checked. The guard is deliberately not negation-aware.
DENIAL_UNCITED = HEADER + (
    "| ADR-016 | #304 | OPEN | implementation; no measured AX wall in front of it |\n"
)
DENIAL_CITED = HEADER + (
    "| ADR-016 | #304 | OPEN | measured 2026-08-30, no AX wall in front of it |\n"
)

CLOSED_ROW_WITH_WALL = HEADER + (
    "| ADR-013 | #301 | closed | the AX plane a readback needs is not exposed |\n"
)

failures = []


def case(name, text, want_bad, want_scanned_nonzero=True):
    scanned, bad = guard.offenders(text)
    got_bad = len(bad)
    if got_bad != want_bad:
        failures.append(f"{name}: expected {want_bad} offender(s), got {got_bad} -> {bad}")
    if want_scanned_nonzero and scanned == 0:
        failures.append(f"{name}: scanned 0 rows, so it checked nothing")


case("three uncited wall claims are all caught", UNCITED, 3)
case("a date in the same cell clears it", CITED_BY_DATE, 0)
case("a link to the measurement comment clears it", CITED_BY_COMMENT, 0)
case("rows that mention no wall are left alone", NO_CLAIM, 0)
case("denying a wall without a date is caught too", DENIAL_UNCITED, 1)
case("denying a wall with a date is fine", DENIAL_CITED, 0)

# A closed row is not telling anyone to go measure anything.
scanned, bad = guard.offenders(CLOSED_ROW_WITH_WALL)
if bad:
    failures.append(f"closed rows must not be flagged, got {bad}")
if scanned != 0:
    failures.append(f"a table with no OPEN rows should scan 0, got {scanned}")

# The two refusals. `main` reads the real roadmap, so these drive the predicate's own zero case and
# the missing-file path through a temporary override.
real = guard.ROADMAP
try:
    guard.ROADMAP = os.path.join(REPO, "docs", "roadmap", "does-not-exist.md")
    if guard.main() != 2:
        failures.append("a missing roadmap must refuse (exit 2), not pass")
finally:
    guard.ROADMAP = real

# And the guard must pass on the file actually in the tree, so a correction that lands without its
# citation is caught here rather than in review.
if guard.main() != 0:
    failures.append("the roadmap in this tree does not satisfy the guard")

if failures:
    print(f"{len(failures)} failure(s):")
    for f in failures:
        print(f"  {f}")
    sys.exit(1)
print("ok — the guard catches three real uncited wall claims, clears cited ones, "
      "leaves non-claims alone, and refuses rather than passing when it cannot parse")
