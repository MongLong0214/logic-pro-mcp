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
them are fine. Only sites that narrow to a single element are counted. Getting this distinction wrong is how the
first census reported 110 instead of 27, in the flattering direction.

The count has since been wrong in the OTHER direction too. `findAllDescendants` followed by a
hand-written `for … { return candidate }` is the same first-match, and the detector could not see
that spelling — thirteen sites, while it reported a confident 27. A detector blind to a spelling is
a census of the spelling, not of the defect.

It is still a heuristic over text, not a parse. It can miss a spelling nobody has thought of, and it
can count a loop that returns for some other reason. The printed list is the evidence; the number
alone is not.

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

# Lower this when sites convert. It may never rise for a NEW site — that is the mechanism.
#
# It rose once, from 27 to 39, and not because sites were added: the detector learned a spelling it
# had been blind to. Raising a ratchet for that reason is legitimate and has to be visible, which is
# why the reason lives here rather than in a commit nobody re-reads. Raising it because something
# went red is not.
#
# It rose a second time, 37 -> 59, for the same reason and found by an outside review rather than by
# this file. The detector required `findAllDescendants(…)` and `.first` to be ADJACENT, so the
# codebase's dominant spelling —
#
#     let groups = AXHelpers.findAllDescendants(…)      // one line
#     groups.first(where: { … })                        // several lines later
#
# — was invisible. Measured: the thirty-seven-site list contained NONE of `Transport.swift:24`,
# `Mixer.swift:309`, `Mixer.swift:322`, `Tracks.swift:54`, including the one site measured live to
# be genuinely ambiguous (37 groups narrowed to 4 by its own discriminator, then first-in-tree-order
# taken). A census blind to the defect it was built for reported "at budget" while that site shipped.
#
# The twenty-two are not new code. They were always there; only the instrument changed.
#
# 59 -> 57 (2026-08-21, #628). Two sites converted, so the ratchet takes the ground:
# `findVolumeFader` and `findPanControl` no longer take a first match in the long-hand shape — they
# build the candidate list and can say how many there were. This is the bar FALLING because the
# defect was fixed, which is the only direction it is allowed to move. The check fails when the
# count comes in UNDER budget too, on purpose: ground gained and not recorded is ground that the
# next change can quietly give back.
BLIND_SITE_BUDGET = 55

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
                    out.append((path, i + 1, "findDescendant — returns first, no count"))
                elif re.search(r"\bfindAllDescendants\(", line):
                    window = "\n".join(lines[i:i + 14])
                    # The result BOUND TO A NAME and then reduced — `let groups = findAll…` on one
                    # line and `groups.first(where:)` further down. This is the dominant spelling in
                    # this codebase and the detector could not see it: measured 2026-08-21, the
                    # thirty-seven-site list contained NONE of `Transport.swift:24`,
                    # `Mixer.swift:309`, `Mixer.swift:322`, `Tracks.swift:54` — including the one
                    # site measured to be genuinely ambiguous live (37 groups narrowed to 4).
                    #
                    # A census that cannot see the defect it was built for is the third instance of
                    # its own docstring's warning, found by an outside review rather than by the
                    # instrument.
                    bound = re.match(r"\s*(?:let|var)\s+([A-Za-z_][A-Za-z0-9_]*)\s*=", line)
                    reduced_by_name = bool(
                        bound and re.search(
                            r"\b" + re.escape(bound.group(1)) + r"\s*(?:\.first\b|\.last\b|\[0\])",
                            window,
                        )
                    )
                    if re.search(r"\)\s*\.first\b", window) or reduced_by_name:
                        out.append((path, i + 1, "findAllDescendants(...) reduced to one"))
                    elif re.search(r"\bfor\b[^\n]*\{", window) and re.search(r"\breturn\b", window):
                        # `for candidate in … { if matches { return candidate } }` is the same
                        # first-match, written long-hand. The census missed thirteen of these while
                        # reporting a confident 27 — a detector that cannot see a spelling is not a
                        # census of the defect, it is a census of one spelling of it.
                        # Whether the loop's test narrows to ONE is not decidable here. Measured:
                        # all twelve of these carry a discriminator, and one of them
                        # (getControlBar, before #633) still had two candidates. So this is a
                        # candidate for review, not a finding.
                        body = "\n".join(lines[i:i + 16])
                        after_for = body.split("for ", 1)[1] if "for " in body else ""
                        tested = bool(re.search(r"\bif\b|\bguard\b|\bwhere\b", after_for))
                        out.append((path, i + 1,
                                    "return-in-loop, tests something — NEEDS A HUMAN"
                                    if tested else "return-in-loop, no test — returns first"))
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
    print(f"AX lookups this detector cannot clear: {len(sites)}  (in {len(files)} files)")
    print("  These are CANDIDATES, not findings. The detector sees the shape of a lookup, never")
    print("  whether its candidate set has one member. Six are already measured DEAD (identifier")
    print("  lookups matching zero live), and every return-in-loop site carries a test whose")
    print("  strength it cannot judge. Read the lookup's own comment first — for all six dead ones")
    print("  the code already said so.")
    print("  Cheapest order: (1) read the lookup's comment, (2) read what the call site passes,")
    print("  (3) measure the live candidate set. Twice this was started at (3) and (1) had the")
    print("  answer — though (3) is what established that (1) could be trusted.")
    print(f"lookups that report their candidate count: {converted}")
    print(f"budget (may not rise; not a defect tally): {BLIND_SITE_BUDGET}")

    if len(sites) > BLIND_SITE_BUDGET:
        print("\nOVER BUDGET — a lookup this detector cannot clear was added. That does not make it")
        print("wrong; it makes it unreviewed, which is what the bar exists to stop.")
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
