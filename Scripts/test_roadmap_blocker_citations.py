#!/usr/bin/env python3
"""Drive `check-roadmap-blockers-cite-measurements.py` and watch it fail.

A guard nobody has seen fail is a guard nobody has tested. Each case below feeds the guard's own
predicate a table and asserts the verdict, and both refusal paths through `main` are driven: a file
that is not there, and a file that parses to zero OPEN rows. Both must come back as "cannot tell"
rather than as clean.

The offending rows are the real ones from 2026-08-30, before they were corrected.

What is NOT covered, so the next reader does not assume it is: reordered columns, a wall phrase in a
cell other than the last, alternate spellings of the state cell, rows split across lines, pipes
inside backticks, and any wall described in words the guard's list does not carry ("unreachable",
"the tree returns nothing"). The guard's own docstring carries the same list.
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
    "| ADR-013 | #301 | OPEN | measured 2026-08-30 — the AX plane a readback needs is not exposed "
    "was wrong; Channel EQ exposes 26 sliders total, including 24 named band parameters, all named and settable |\n"
)
# The cell must contain a phrase from WALL_CLAIMS or this case proves nothing about dates: an
# earlier version said "opacity", which is in no list, so deleting DATE handling entirely left it
# passing. A fixture that cannot reach the code path it names is decoration.
assert any(w in CITED_BY_DATE.lower() for w in guard.WALL_CLAIMS), \
    "the date fixture no longer contains a wall phrase, so it tests nothing"

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

# Both refusals, driven through `main` rather than through `offenders`. The zero-scan branch was
# previously only reached via `offenders`, so `main`'s return of 2 was asserted by nobody and the
# docstring said otherwise.
import tempfile

real = guard.ROADMAP
try:
    guard.ROADMAP = os.path.join(REPO, "docs", "roadmap", "does-not-exist.md")
    if guard.main() != 2:
        failures.append("a missing roadmap must refuse (exit 2), not pass")

    with tempfile.TemporaryDirectory() as tmp:
        empty = os.path.join(tmp, "README.md")
        with open(empty, "w", encoding="utf-8") as fh:
            fh.write("# a roadmap whose table stopped parsing\n\nno rows here at all\n")
        guard.ROADMAP = empty
        if guard.main() != 2:
            failures.append("a roadmap with zero OPEN rows must refuse (exit 2), not pass")

        # And a table that parses but is all closed: scanned stays 0, so it is the same refusal.
        closed_only = os.path.join(tmp, "closed.md")
        with open(closed_only, "w", encoding="utf-8") as fh:
            fh.write(CLOSED_ROW_WITH_WALL)
        guard.ROADMAP = closed_only
        if guard.main() != 2:
            failures.append("a table with only closed rows must refuse (exit 2), not pass")
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
print("ok — the guard catches three real uncited wall claims, clears cited ones, leaves rows that "
      "mention no wall alone, catches an undated DENIAL, and refuses through main() when the file "
      "is missing and when the table parses to zero OPEN rows")
