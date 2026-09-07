#!/usr/bin/env python3
"""The ADR index may not call an ADR unfinished after its issue closed.

NOT discovered by `run-repo-guards.py`, and deliberately not named `check-*.py`. That runner's
contract is plain Python needing neither Xcode nor a network, and this asks GitHub for issue state
— the same reason `roadmap-table-matches-github.py` sits outside it. It runs in the `roadmap` CI
job, which is the one job holding a token, beside the check it is the sibling of.

THE FAILURE THIS REFUSES, eight rows at once. On 2026-09-07 `docs/adr/README.md` marked ADR-002,
-003, -004, -005, -006, -007, -012 and -013 `In Implementation` while every one of those issues was
CLOSED — four of them for weeks — and ADR-014 read `Proposed` after its R1 had shipped. Anyone
asking "what is still being built" got eight wrong answers from the file whose whole job is that
question, and nothing anywhere noticed, because the roadmap guard beside this one checks the
ROADMAP table and had never been pointed at this one.

WHY THE DIRECTION IS ASYMMETRIC. A closed issue whose row says `In Implementation` is a lie about
the present. An OPEN issue whose row says `Shipped` is a different and rarer claim — an ADR can
ship while its issue stays open for a remainder, which is exactly what ADR-014's R1 did — so that
direction is reported rather than refused. What is refused is the one that was actually wrong.

EVERY ADR DOCUMENT NEEDS A ROW. `ADR-019-observation-ledger.md` had shipped, was governing the
observation ledger, and appeared nowhere in the index — so the index was incomplete as well as
stale, and a reader counting rows would have counted eighteen ADRs where there are nineteen. A row
may honestly say an ADR has no issue of its own; saying nothing is what this refuses.

THE REACH. This compares the index against GitHub and against the `docs/adr/` directory. It does
not read the ADR bodies, so an ADR whose row is right and whose text is stale passes. It also
cannot run without `gh`; absent or unauthenticated, it reports that it CANNOT DETERMINE rather than
passing, because a check that goes green when it cannot see is the failure this directory is full
of.
"""
import glob
import json
import os
import re
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
INDEX = os.path.join(REPO, "docs", "adr", "README.md")
ADR_DIR = os.path.join(REPO, "docs", "adr")

CANNOT_DETERMINE = 2

# A status that asserts the work is still ahead of us. `Shipped`, `Closed` and `Superseded` all
# assert the opposite and are what a closed issue should carry.
UNFINISHED = ("In Implementation", "Proposed", "Draft", "Accepted")

ROW = re.compile(r"^\|\s*(ADR-\d+)\s*\|[^|]*\|[^|]*\|\s*`([^`]*)`\s*\|(.*)\|\s*$")
ISSUE_REF = re.compile(r"/issues/(\d+)\)")


def rows(text):
    """(adr id, status, issue number or None) for each index row, in file order."""
    out = []
    for line in text.split("\n"):
        m = ROW.match(line)
        if not m:
            continue
        issue = ISSUE_REF.search(m.group(3))
        out.append((m.group(1), m.group(2), int(issue.group(1)) if issue else None))
    return out


def documented_adrs(directory=ADR_DIR):
    """ADR ids that have a document on disk. README.md is the index, not an ADR."""
    found = set()
    for path in glob.glob(os.path.join(directory, "*.md")):
        name = os.path.basename(path)
        m = re.match(r"^(ADR-\d+)", name)
        if m:
            found.add(m.group(1))
    return found


def issue_states(numbers, fetch=None):
    """{number: "OPEN"|"CLOSED"} for the issues the index names."""
    if not numbers:
        return {}, None
    if fetch is None:
        def fetch(nums):
            proc = subprocess.run(
                ["gh", "issue", "list", "--repo", "MongLong0214/logic-pro-mcp",
                 "--state", "all", "--limit", "500", "--json", "number,state"],
                capture_output=True, text=True,
            )
            if proc.returncode != 0:
                return None, proc.stderr.strip()[:200] or "gh failed"
            return json.loads(proc.stdout), None
    listing, error = fetch(numbers)
    if error:
        return {}, error
    states = {row["number"]: row["state"] for row in listing}
    missing = [n for n in numbers if n not in states]
    if missing:
        return {}, f"the index names issue(s) GitHub did not return: {missing}"
    return states, None


def problems(index_rows, states, documented):
    """Every disagreement, as human-readable lines. Empty means the index is honest."""
    found = []
    for adr, status, issue in index_rows:
        if issue is None:
            continue
        state = states.get(issue)
        if state == "CLOSED" and status in UNFINISHED:
            found.append(
                f"{adr}: index says `{status}` but #{issue} is CLOSED — "
                f"the row claims work that is finished is still ahead"
            )
    listed = {adr for adr, _, _ in index_rows}
    for adr in sorted(documented - listed):
        found.append(f"{adr}: has a document in docs/adr/ and no row in the index")
    return found


def main():
    with open(INDEX, encoding="utf-8") as handle:
        text = handle.read()
    index_rows = rows(text)
    if not index_rows:
        print("CANNOT DETERMINE: parsed 0 ADR rows from docs/adr/README.md. An empty index agrees "
              "with everything, which is not the same as being correct.", file=sys.stderr)
        return CANNOT_DETERMINE
    numbers = sorted({issue for _, _, issue in index_rows if issue is not None})
    states, error = issue_states(numbers)
    if error:
        print(f"CANNOT DETERMINE: {error}", file=sys.stderr)
        return CANNOT_DETERMINE
    found = problems(index_rows, states, documented_adrs())
    if found:
        print("The ADR index disagrees with GitHub:", file=sys.stderr)
        for line in found:
            print(f"  {line}", file=sys.stderr)
        return 1
    # Count the index's OWN issues. The listing is repository-wide, and reporting its open
    # total here would describe the backlog while claiming to describe the index.
    open_here = sum(1 for _, _, issue in index_rows
                    if issue is not None and states.get(issue) == "OPEN")
    print(f"ADR index agrees with GitHub: {len(index_rows)} rows, {open_here} still open")
    return 0


if __name__ == "__main__":
    sys.exit(main())
