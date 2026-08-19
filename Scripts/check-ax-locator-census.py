#!/usr/bin/env python3
"""How many AX lookups still pick one element from many without recording the count.

THE DEFECT
----------
`AXLocalePolicy.findDescendant` and `AXHelpers.findDescendant` return the first match in traversal
order. `findAllDescendants(...).first` does the same by hand. When the answer is right, nothing
records that it was right for a reason rather than by luck, and a later reader cannot tell a
discriminator from tree order. Measured on one arrange window, AXDescription "Control Bar" matches
two elements, "Library" four, "Event" three.

`censusDescendant` returns the match AND the candidate count, so `candidates == 1` becomes a fact.

WHAT IS AND IS NOT COUNTED
--------------------------
Finding many and USING many is not this defect — `findAllDescendants` has 89 call sites and most of
them are fine. Only sites that narrow to a single element are counted. Getting this distinction
wrong is how the first census of this issue reported 110 instead of 27, in the flattering direction.

A RATCHET, NOT A GATE ON ZERO
-----------------------------
Twenty-seven sites cannot convert at once — each needs its own judgement about what discriminates
the target, and conversions in the product need live proof. Gating on zero would paint the tree red
and the next move after that is somebody deleting the check.

So the bar only moves down. A new blind lookup fails this; converting one lets BLIND_SITE_BUDGET
drop. The derived count is always printed, so a budget that has drifted from reality is visible
rather than trusted.
"""
import os
import re
import sys

# Lower this when sites convert. It may never rise: that is the whole mechanism.
BLIND_SITE_BUDGET = 27

SEARCH_ROOTS = ("Sources", "Scripts")


def blind_sites(root):
    out = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in (".build", ".git")]
        for f in filenames:
            if not f.endswith(".swift"):
                continue
            path = os.path.join(dirpath, f)
            lines = open(path).read().splitlines()
            for i, line in enumerate(lines):
                if "static func" in line or line.strip().startswith("//"):
                    continue
                if re.search(r"\bfindDescendant\(", line):
                    out.append((path, i + 1, "findDescendant"))
                elif re.search(r"\bfindAllDescendants\(", line):
                    # narrowed to one within the call's own expression
                    if re.search(r"\)\s*\.first\b", "\n".join(lines[i:i + 8])):
                        out.append((path, i + 1, "findAllDescendants(...).first"))
    return out


def main():
    repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    sites = []
    for r in SEARCH_ROOTS:
        d = os.path.join(repo, r)
        if os.path.isdir(d):
            sites.extend(blind_sites(d))

    converted = 0
    for dirpath, dirnames, filenames in os.walk(os.path.join(repo, "Sources")):
        dirnames[:] = [d for d in dirnames if d not in (".build", ".git")]
        for f in filenames:
            if f.endswith(".swift"):
                src = open(os.path.join(dirpath, f)).read()
                converted += len([m for m in re.finditer(r"\bcensusDescendant\(", src)
                                  if "static func" not in src[max(0, m.start() - 80):m.start()]])

    files = {p for p, _, _ in sites}
    print(f"AX lookups that keep one candidate and record no count: {len(sites)}"
          f"  (in {len(files)} files)")
    print(f"lookups that report their candidate count:               {converted}")
    print(f"budget:                                                  {BLIND_SITE_BUDGET}")

    if len(sites) > BLIND_SITE_BUDGET:
        print("\nOVER BUDGET — a lookup that keeps one candidate without counting them was added.")
        print("Use AXLocalePolicy.censusDescendant, or lower nothing and convert one first.")
        for p, n, kind in sites:
            print(f"  {os.path.relpath(p, repo)}:{n}  {kind}")
        return 1
    if len(sites) < BLIND_SITE_BUDGET:
        print(f"\nUNDER BUDGET by {BLIND_SITE_BUDGET - len(sites)} — lower BLIND_SITE_BUDGET to "
              f"{len(sites)} so the ground gained is held.")
        return 1
    print("\nat budget")
    return 0


if __name__ == "__main__":
    sys.exit(main())
