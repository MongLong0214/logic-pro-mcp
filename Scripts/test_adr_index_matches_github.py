#!/usr/bin/env python3
"""Prove `Scripts/check-adr-index-matches-github.py` can fail, and on the right things.

The case that carries the rule is the first: the exact eight-row shape the index was in on
2026-09-07 — `In Implementation` against a CLOSED issue — must be caught. The second-most
important is the one that must NOT be caught, because refusing it would make the rule unadoptable:
a SHIPPED ADR whose issue stays open for a remainder is honest, and ADR-014's R1 is exactly that.
"""
import importlib.util
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location(
    "adr_index", HERE / "check-adr-index-matches-github.py"
)
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)

ROW = "| {adr} | Name | A | `{status}` | [#{issue}](https://github.com/o/r/issues/{issue}) |"


def main():
    failures = []
    ran = [0]

    def case(name, cond, detail):
        ran[0] += 1
        if not cond:
            failures.append(f"{name}: {detail}")

    def check(rows_text, states, documented=frozenset()):
        return guard.problems(guard.rows(rows_text), states, set(documented))

    # THE SHAPE IT WAS IN. Eight rows like this on 2026-09-07.
    stale = ROW.format(adr="ADR-002", status="In Implementation", issue=285)
    found = check(stale, {285: "CLOSED"})
    case("an unfinished status on a closed issue is caught",
         len(found) == 1 and "CLOSED" in found[0], found)

    # `Proposed` is the same lie in a different word — ADR-014 carried it after R1 shipped.
    found = check(ROW.format(adr="ADR-014", status="Proposed", issue=302), {302: "CLOSED"})
    case("Proposed on a closed issue is caught", len(found) == 1, found)

    # THE ONE THAT MUST NOT BE CAUGHT. An ADR can ship while its issue stays open for a
    # remainder; refusing that would force the index to lie in the other direction.
    found = check(ROW.format(adr="ADR-014", status="Shipped", issue=302), {302: "OPEN"})
    case("Shipped against an open issue is allowed", found == [], found)

    # The honest pairs.
    found = check(ROW.format(adr="ADR-002", status="Shipped", issue=285), {285: "CLOSED"})
    case("Shipped against a closed issue is clean", found == [], found)
    found = check(ROW.format(adr="ADR-001", status="In Implementation", issue=284), {284: "OPEN"})
    case("In Implementation against an open issue is clean", found == [], found)

    # A ROW WITH NO ISSUE is allowed — ADR-019 landed with #768 and has none of its own — but it
    # still has to be a row.
    no_issue = "| ADR-019 | Observation Ledger | B | `Shipped` | no issue of its own |"
    case("a row without an issue link parses and is allowed",
         check(no_issue, {}) == [], check(no_issue, {}))

    # ...and an ADR with a document but no row is caught, which is how ADR-019 was invisible.
    found = check(stale, {285: "CLOSED"}, documented={"ADR-002", "ADR-019"})
    case("a documented ADR with no row is caught",
         any("no row in the index" in f for f in found), found)
    found = check(stale + "\n" + no_issue, {285: "CLOSED"}, documented={"ADR-002", "ADR-019"})
    case("...and stops being caught once the row exists",
         not any("no row" in f for f in found), found)

    # Prose that merely mentions an ADR is not a row.
    case("prose is not a row", guard.rows("ADR-002 is In Implementation, see #285.") == [], "")

    # THE INSTRUMENT MUST SAY WHEN IT CANNOT SEE. A `gh` that fails is not a clean index.
    states, error = guard.issue_states([285], fetch=lambda nums: (None, "gh not authenticated"))
    case("an unusable gh reports cannot-determine rather than passing",
         states == {} and error == "gh not authenticated", (states, error))
    # An issue the index names and the listing does not carry is unknown, not fine.
    states, error = guard.issue_states([285], fetch=lambda nums: ([{"number": 1, "state": "OPEN"}], None))
    case("an issue missing from the listing is an error, not an empty answer",
         states == {} and error and "did not return" in error, (states, error))

    # The real tree, through the real gh.
    proc = subprocess.run([sys.executable, str(HERE / "check-adr-index-matches-github.py")],
                          capture_output=True, text=True)
    case("the ADR index is honest on this tree",
         proc.returncode == 0, (proc.stdout + proc.stderr).strip()[:300])

    if failures:
        for f in failures:
            print(f"FAIL {f}")
        return 1
    print(f"{ran[0]} case(s) pass: a closed issue cannot be called unfinished")
    return 0


if __name__ == "__main__":
    sys.exit(main())
