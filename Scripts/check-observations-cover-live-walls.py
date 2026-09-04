#!/usr/bin/env python3
"""A measured wall named in the roadmap must have an observation record behind it.

The schema guard beside this one checks records that EXIST. On its own that is the shape of check
that cannot see the failure it matters most for: a wall asserted in prose with no reading behind it
passes, because there is nothing to inspect. This closes that direction.

The roadmap is where this repository states what it has measured, and its rows are read as settled
fact — `NOT STARTED`, `measured 2026-08-30`, `AXPress is inert`. A row that claims a live
measurement while `docs/observations/` holds nothing for that issue is a claim with no evidence
anyone can re-check, which is exactly the drift the roadmap table exists to prevent for issue state.

The rule is deliberately narrow. It fires only on rows that CLAIM a dated live measurement, because
that is a claim about the world rather than a plan, and only for issues whose row says so. Prose
about intent, dependencies, or what is still open is not covered and should not be.
"""
import glob
import json
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ROADMAP = os.path.join(REPO, "docs", "roadmap", "README.md")
OBS = os.path.join(REPO, "docs", "observations")

# "measured 2026-08-30", "Measured live 2026-09-04", "Driven live 2026-09-03"
CLAIM = re.compile(r"\b(?:measured|driven)\b[^|]{0,24}?\b(20\d\d-\d\d-\d\d)\b", re.IGNORECASE)
ISSUE = re.compile(r"#(\d+)")

# Rows whose measurement predates the observation records themselves. Grandfathered explicitly, by
# issue, so the list can only shrink: a NEW row cannot join it without editing this file, which is
# the point. Each entry names what would have to be re-measured to remove it.
GRANDFATHERED = {
    290: "ADR-007, closed 2026-08-30 — all seven criteria measured before records existed",
    291: "ADR-008 routing-graph node identity, measured before records existed",
    292: "the 2026-08-30 Controls-view addressability reading (the 2026-09-04 popup wall IS recorded)",
    293: "ADR-010 Event List collector, measured 2026-08-29",
    299: "ADR-011 Compressor native-editor slider census, measured 2026-08-30",
    301: "ADR-013 Channel EQ named-band writes, shipped and measured 2026-08-31",
    302: "ADR-014 kAXColumns reading, measured 2026-08-29",
    303: "ADR-015 TransformVerification dependency, measured 2026-08-29",
    304: "ADR-016 tempo-map bounds",
    305: "ADR-017 Flex Pitch surface correction",
    306: "ADR-018 Tier B addressability, measured 2026-08-30",
    369: "export panel walls, measured across seven live rounds",
    736: "the reporter's own MCU/port measurements, made outside this repository",
    747: "the Korean save_as path, measured 2026-09-03",
    748: "the collapsed-stack truncation, measured 2026-09-03",
}


def recorded_issues():
    out = set()
    for p in glob.glob(os.path.join(OBS, "*.json")):
        try:
            doc = json.load(open(p, encoding="utf-8"))
        except ValueError:
            continue          # the schema guard reports malformed records; not this one's job
        for n in doc.get("issues") or []:
            out.add(int(n))
    return out


def main():
    if not os.path.exists(ROADMAP):
        print("no roadmap; nothing to check")
        return 0
    have = recorded_issues()
    missing = []
    for line in open(ROADMAP, encoding="utf-8"):
        if not line.startswith("|"):
            continue
        claim = CLAIM.search(line)
        if not claim:
            continue
        issues = {int(n) for n in ISSUE.findall(line)}
        if not issues:
            continue
        if issues & have:
            continue
        if issues & set(GRANDFATHERED):
            continue
        missing.append((sorted(issues), claim.group(1), line.strip()[:150]))

    if missing:
        print(f"{len(missing)} roadmap row(s) claim a live measurement with no observation record:")
        for issues, date, row in missing:
            print(f"  issues {issues} claim a measurement dated {date}")
            print(f"    {row}")
        print("\n  Write docs/observations/<date>-<slug>.json with the readings, or drop the claim.")
        print("  Schema: docs/observations/SCHEMA.md")
        return 1

    print(f"every roadmap measurement claim has an observation record "
          f"({len(have)} issue(s) covered, {len(GRANDFATHERED)} grandfathered)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
