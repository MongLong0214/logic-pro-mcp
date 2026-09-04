#!/usr/bin/env python3
"""Cases for `check-observations-cover-live-walls.py` — a roadmap row claiming a measurement needs
a record for the issue that row is ABOUT.

Both halves of this guard were wrong once, and both were found by writing a wording that escaped it
rather than by a test:

  * the trigger matched too few phrasings. `live-verified 2026-09-04`, `observed live on`,
    `drove this live` and two more sailed past, and widening it exposed two genuinely unrecorded
    claims that had been sitting in the table.
  * attribution read every issue number on the line. ADR-011's row claims a measurement about #299
    and says "behind #292", so a record about #292 was accepted as covering #299 — the guard
    reported full coverage while nothing had been written about the claim it was reading.

`claim_in` and `own_issue` are pure functions of one line, so the cases drive them directly and
neither read nor disturb the real roadmap.
"""
import importlib.util
import os
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
spec = importlib.util.spec_from_file_location(
    "coverage_guard", os.path.join(REPO, "Scripts", "check-observations-cover-live-walls.py"))
G = importlib.util.module_from_spec(spec)
spec.loader.exec_module(G)

failed = 0


def case(name, condition, detail):
    global failed
    failed += 0 if condition else 1
    print(f"{'ok  ' if condition else 'FAIL'} {name} -> {detail}")


# 1. The five wordings that escaped the first trigger. Each is a row asserting a reading, and each
#    has to be caught or the rule only covers the phrasing its author happened to use.
ESCAPEES = [
    "| ADR-0 | #1 | OPEN | the slot is live-verified 2026-09-04 and reads back |",
    "| ADR-0 | #1 | OPEN | observed live on the arrange window |",
    "| ADR-0 | #1 | OPEN | drove this live and it refused |",
    "| ADR-0 | #1 | OPEN | measured on a live Logic yesterday |",
    "| ADR-0 | #1 | OPEN | 2026-09-04 measurement: the menu opens |",
]
missed = [row for row in ESCAPEES if not G.claim_in(row)]
case("every wording that escaped the first trigger is caught now", missed == [],
     f"missed={missed!r}")

# 2. A row that claims nothing is not a claim. Without this the rule would demand a record for
#    every row in the table and be switched off within a day.
quiet = "| ADR-0 | #1 | OPEN | this is waiting on a decision about node identity |"
case("a row asserting nothing is not treated as a claim", not G.claim_in(quiet), repr(quiet[:60]))

# 2b. It fires on a dated measurement whether or not the row says "live". An outside review read
#     the old wording as a promise that it required a `live` token; the behaviour is wider and the
#     wider behaviour is the wanted one — a dated measurement deserves a record either way.
static_claim = "| ADR-0 | #1 | OPEN | Measured 2026-09-04 by static source inspection |"
case("a dated measurement with no `live` token is still a claim",
     bool(G.claim_in(static_claim)), repr(static_claim[:60]))

# 3. THE ATTRIBUTION. A row is about the issue in its identity cells, not about every issue its
#    prose happens to name. ADR-011 claims about #299 and mentions "behind #292"; before this,
#    a #292 record covered it.
row = "| ADR-011 | #299 | OPEN | behind #292. Measured 2026-08-30: 22 sliders |"
case("a claim is attributed to the row's own issue, not one named in passing",
     G.own_issue(row) == {299}, f"own_issue={G.own_issue(row)!r}")

# 4. The other table shape puts the issue first, and it has to work there too.
row = "| #369 | closed | export panel walls, measured across seven live rounds |"
case("the issue-first table shape attributes to its own issue",
     G.own_issue(row) == {369}, f"own_issue={G.own_issue(row)!r}")

# 5. A dependency named in prose must NOT be able to stand in as the subject.
row = "| ADR-011 | #299 | OPEN | behind #292 and #293 and #306 |"
case("issues named only in prose are not the row's subject",
     G.own_issue(row) == {299}, f"own_issue={G.own_issue(row)!r}")

# 6. The grandfather list is for measurements that predate the records, and it is consulted only
#    after a real record fails to cover — so an entry there can never hide a recorded issue.
case("the grandfather list is a dict of issue -> reason",
     isinstance(G.GRANDFATHERED, dict) and all(isinstance(k, int) for k in G.GRANDFATHERED)
     and all(isinstance(v, str) and v for v in G.GRANDFATHERED.values()),
     f"{len(G.GRANDFATHERED)} entries")

# 7. And the repository is in the state the rule describes: every claim covered or grandfathered.
recorded = G.recorded_issues()
case("records exist and are read as a set of issue numbers",
     isinstance(recorded, set) and recorded and all(isinstance(i, int) for i in recorded),
     f"{len(recorded)} issue(s) covered by a record")

print()
print(f"FAILED ({failed} unexpected)" if failed else "all cases behaved (0 unexpected)")
sys.exit(1 if failed else 0)
