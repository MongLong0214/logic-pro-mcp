#!/usr/bin/env python3
"""A roadmap row may not claim a wall it has not measured.

WHY THIS EXISTS
---------------
On 2026-08-30 four roadmap rows said an AX surface was opaque. Three of the four were wrong, and
none of the three had ever been measured against the surface it named:

    #301  "the AX plane a readback needs is not exposed"
          -> Channel EQ exposes all 24 band sliders, named and settable. The claim came from a
             census that instantiates the Audio Unit OUTSIDE Logic, which ADR-018 itself says
             cannot speak for Logic's live instance.
    #305  "AU parameter view observed AX-opaque"
          -> Flex Pitch is in the Audio Track Editor. The blocker was never about this surface.
    #306  "same wall as #305"
          -> inherited from a row that had no measurement, which turned ONE unobserved claim into
             two that appeared to corroborate each other.

Every one of them told the next person to go measure a wall, and the wall was not there. A wrong
blocker is more expensive than a missing one: a missing blocker gets investigated, a wrong one gets
believed and routed around. ADR-013's whole Decision section — a virtual Mackie C4 control surface,
two virtual MIDI endpoints, an adapter and a doctor capability — exists to route around a wall that
does not exist.

WHAT IT CHECKS, AND WHAT IT CANNOT
----------------------------------
Form, not truth. It cannot tell whether a measurement was real, aimed at the right thing, or taken
while a modal was silently blocking the application. What it can do is refuse the shape all three
of those rows had: a wall asserted with nothing dated beside it.

So a row that mentions a wall must carry, in the same cell, either an ISO date or a link to the
comment that recorded the measurement. That is a low bar deliberately — it is the bar that would
have caught all three, and a higher one would be a bar on prose that nothing can enforce.

It applies in BOTH directions, and that is not an accident of substring matching. The row for #304
said "no measured AX wall in front of it", and *when did you check there was no wall?* is exactly
the question whose absence cost the three rows above. A row denying a wall answers it the same way
a row asserting one does.

It says nothing about rows that describe work as unstarted, behind a dependency, or waiting on a
decision without mentioning a wall at all. Those are not claims about a surface.

WHAT IT MISSES, so nobody reads a pass as coverage
--------------------------------------------------
It matches literal phrases in the LAST cell of a row whose cells include exactly `OPEN`. So it does
not see:

  * a wall described in words this list does not carry — "unreachable", "cannot be read",
    "the tree returns nothing"
  * a wall claim in a cell other than the last, or a table whose columns are ordered differently
  * a state cell spelled anything but `OPEN`, or a row split across lines
  * a pipe inside backticks, which splits one cell into two

And a date is a pointer, not proof: `2026-08-30` typed into a cell satisfies this guard and
measures nothing. It raises the floor from "a wall with nothing beside it" to "a wall with
something a reader can go and check", and that is the whole of what it does.
"""
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ROADMAP = os.path.join(REPO, "docs", "roadmap", "README.md")

# Phrases that assert a measurable fact about a surface. Taken from what the wrong rows actually
# said rather than invented, so the list stays answerable to real text.
WALL_CLAIMS = [
    "opaque",
    "not exposed",
    "no accessible path",
    "ax wall",
    "same wall as",
]

# A citation is a date or the comment that carries the measurement. Both are things a reader can
# go and check; neither is proof the measurement was sound.
DATE = re.compile(r"20\d\d-\d\d-\d\d")
COMMENT_URL = re.compile(r"github\.com/[\w.-]+/[\w.-]+/issues/\d+#issuecomment-\d+")


def rows(text):
    """Every markdown table row in the file, as a list of cells.

    Header and separator rows are dropped. A row is a line that starts and ends with a pipe once
    stripped, which is how every table in this file is written.
    """
    out = []
    for lineno, line in enumerate(text.splitlines(), start=1):
        s = line.strip()
        if not s.startswith("|") or not s.endswith("|"):
            continue
        cells = [c.strip() for c in s.strip("|").split("|")]
        if not cells:
            continue
        if all(set(c) <= set("-: ") for c in cells):
            continue
        out.append((lineno, cells))
    return out


def offenders(text):
    bad = []
    scanned = 0
    for lineno, cells in rows(text):
        if "OPEN" not in cells:
            continue
        scanned += 1
        detail = cells[-1]
        lowered = detail.lower()
        # Deliberately not negation-aware. A row saying there is NO wall is making the same
        # kind of claim and owes the same date; see the module docstring.
        hit = next((c for c in WALL_CLAIMS if c in lowered), None)
        if hit is None:
            continue
        if DATE.search(detail) or COMMENT_URL.search(detail):
            continue
        bad.append((lineno, hit, detail))
    return scanned, bad


def main():
    if not os.path.exists(ROADMAP):
        print(f"cannot read {os.path.relpath(ROADMAP, REPO)} — refusing rather than passing")
        return 2
    text = open(ROADMAP, encoding="utf-8").read()
    scanned, bad = offenders(text)
    if scanned == 0:
        # No OPEN rows at all means the table moved or stopped parsing. A guard that scanned
        # nothing has not checked anything, and reporting that as clean is the failure mode this
        # repository keeps finding in its own checks.
        print("no OPEN roadmap rows were parsed — the table shape changed; refusing rather than passing")
        return 2
    if bad:
        print(f"{len(bad)} of {scanned} OPEN roadmap rows mention a wall with nothing dated beside it:\n")
        for lineno, hit, detail in bad:
            print(f"  docs/roadmap/README.md:{lineno}  says {hit!r}")
            print(f"      {detail[:160]}")
        print(
            "\nEither measure it and put the date (or the issue comment that records the "
            "measurement) in the same cell, or drop the wall language and say the work is "
            "unstarted. This applies to a row DENYING a wall too: 'no wall here' is a claim that "
            "needs a date as much as 'opaque' does. An undated wall reads as a measured one and "
            "sends the next person to route around something that may not be there."
        )
        return 1
    print(f"ok — {scanned} OPEN roadmap rows scanned, every wall mention carries a citation")
    return 0


if __name__ == "__main__":
    sys.exit(main())
