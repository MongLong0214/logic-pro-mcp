#!/usr/bin/env python3
"""Public docs may not claim support for a variant the qualification matrix does not cover.

`ReleaseQualificationAttestation.shipVariants` is the authority on what this release claims to
control. It is `[.desktop]`. The README said "Same MCP server controls both" — a support claim for
Creator Studio, for which no qualification evidence exists.

The variant list is READ FROM THE SWIFT, not repeated here. A copy would go stale the moment
shipVariants changes, and the direction it would go stale in is the dangerous one: docs claiming
more than the matrix covers is exactly the failure this exists to catch.

Recognising a bundle ID is not claiming support for it. The runtime tells the two Logics apart so a
machine with both is not targeted by accident, and the docs may say so. What they may not do is
state that both are controlled, supported, or validated.
"""
import os
import re
import sys

DOCS = ("README.md", "docs/SETUP.md", "docs/API.md")

# Sentences that assert support. Each must be shown to FIRE on a planted string, below, or it is
# decoration — a pattern that never matched anything is green for the wrong reason.
CLAIM_PATTERNS = [
    r"controls?\s+both",
    r"supports?\s+both",
    r"both\s+variants?\s+(?:are\s+)?(?:supported|validated|qualified)",
    r"works?\s+with\s+both",
]


def shipped_variants(repo):
    """The variant list, read from the attestation rather than repeated."""
    path = os.path.join(repo, "Sources/LogicProMCP/Qualification/ReleaseQualificationAttestation.swift")
    m = re.search(r"shipVariants:\s*\[LogicVariant\]\s*=\s*\[([^\]]*)\]", open(path).read())
    if not m:
        return None
    return [v.strip().lstrip(".") for v in m.group(1).split(",") if v.strip()]


def offending_lines(repo):
    out = []
    for rel in DOCS:
        path = os.path.join(repo, rel)
        if not os.path.exists(path):
            continue
        for i, line in enumerate(open(path).read().splitlines(), 1):
            for pat in CLAIM_PATTERNS:
                if re.search(pat, line, re.I):
                    out.append((rel, i, pat, line.strip()[:120]))
    return out


def main():
    repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    variants = shipped_variants(repo)
    if variants is None:
        print("could not read shipVariants — the authority is unreadable, which is not a pass")
        return 1
    print(f"shipVariants (read from the attestation): {variants}")
    if len(variants) > 1:
        print("more than one variant is shipped; a both-variants claim would be legitimate")
        return 0

    hits = offending_lines(repo)
    if hits:
        print(f"\n{len(hits)} public claim(s) of multi-variant support, "
              f"while only {variants[0]} is qualified:")
        for rel, n, pat, text in hits:
            print(f"  {rel}:{n}  /{pat}/\n      {text}")
        return 1
    print("no public claim of support for an unqualified variant")
    return 0


if __name__ == "__main__":
    sys.exit(main())
