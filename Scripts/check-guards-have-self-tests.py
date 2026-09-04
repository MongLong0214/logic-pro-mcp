#!/usr/bin/env python3
"""Every guard ships with a test that drives it, because a guard proved once is a guard that drifts.

On 2026-09-04 six rules in this repository turned out to enforce something NARROWER than their own
docstring claimed, and every one was found by a defect slipping past rather than by a test:

    the coverage trigger          five wordings escaped it
    coverage attribution          any issue number on the line, not the row's own
    `depends`                     checked the file and not the symbol it named
    `reverify`                    demanded an exec bit 41 of 42 harnesses do not carry
    `operations_driven`           counts tools/call while saying "touched the product"
    the menu-literal guard        Sources/ only, while the defect lived in Scripts/livekit

Each had been proved by hand when it was written — inject the defect, watch it fail, restore — and
each proof was thrown away. A control that runs once tests the rule at one instant.

Committing the controls for `check-livekit-ui-literals.py` found three defects in it the same hour:
an exemption that accepted a HORIZONTAL ELLIPSIS as a translation, a site reported twice by two
patterns, and a replacement clause that measured to change nothing.

## What counts as covered

The guard's filename must appear in a test **in code, not in prose**. Three tests mention
`check-python-contracts.py` in their opening paragraph and none of them run it; counting those
would make this rule flatter itself, which is the failure it exists to name. Python tests are
parsed and their docstrings skipped; shell tests ignore comment lines.

The known list only shrinks. Turning nine guards red at once is how a rule gets deleted rather than
satisfied.
"""
import ast
import glob
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Guards with no test that drives them, measured 2026-09-04. This list may only shrink.
KNOWN_BARE = {
    "check-ax-locator-census.py",
    "check-livekit-locale-aliases.py",
    "check-locale-labels-json.py",
    "check-locale-policy-coverage.py",
    "check-observation-records.py",
    "check-observations-cover-live-walls.py",
    "check-python-contracts.py",
    "check-shipped-variant-claims.py",
    "ci-forbid-dead-expect.sh",
}


def guards():
    return sorted(glob.glob(os.path.join(REPO, "Scripts", "check-*.py"))) + \
           sorted(glob.glob(os.path.join(REPO, "Scripts", "ci-*.sh")))


def tests():
    return sorted(glob.glob(os.path.join(REPO, "Scripts", "test_*.py"))) + \
           sorted(glob.glob(os.path.join(REPO, "Scripts", "test-*.sh"))) + \
           sorted(glob.glob(os.path.join(REPO, "Scripts", "livekit", "test_*.py")))


def code_text(path):
    """The parts of a test that are code. Prose naming a guard is not a test of it."""
    source = open(path, encoding="utf-8", errors="replace").read()
    if not path.endswith(".py"):
        return "\n".join(l for l in source.splitlines() if not l.strip().startswith("#"))
    try:
        tree = ast.parse(source)
    except SyntaxError:
        return source
    docstrings = set()
    for node in ast.walk(tree):
        body = getattr(node, "body", None)
        if isinstance(node, (ast.Module, ast.ClassDef, ast.FunctionDef, ast.AsyncFunctionDef)) \
           and body and isinstance(body[0], ast.Expr) and isinstance(body[0].value, ast.Constant) \
           and isinstance(body[0].value.value, str):
            docstrings.add(body[0].value.value)
    kept = []
    for line in source.splitlines():
        if line.strip().startswith("#"):
            continue
        kept.append(line)
    text = "\n".join(kept)
    for doc in docstrings:
        text = text.replace(doc, "")
    return text


def coverage():
    bodies = {os.path.basename(t): code_text(t) for t in tests()}
    covered, bare = {}, []
    for guard in guards():
        base = os.path.basename(guard)
        hits = sorted(name for name, body in bodies.items() if base in body)
        if hits:
            covered[base] = hits
        else:
            bare.append(base)
    return covered, sorted(bare)


def main():
    covered, bare = coverage()
    total = len(covered) + len(bare)
    new_bare = [b for b in bare if b not in KNOWN_BARE]
    now_covered = sorted(KNOWN_BARE - set(bare))

    if new_bare:
        print(f"{len(new_bare)} guard(s) with no test that drives them:")
        for base in new_bare:
            print(f"  {base}")
        print("\n  Add Scripts/test_<name>.py beside it: inject the defect the guard names, assert")
        print("  it is reported, restore, assert it is not. run-repo-guards.py discovers both.")
    if now_covered:
        print(f"\n{len(now_covered)} guard(s) gained a test — remove them from KNOWN_BARE so the")
        print("next regression cannot fall back to the old number:")
        for base in now_covered:
            print(f"  {base}")
    if new_bare or now_covered:
        return 1
    print(f"{len(covered)} of {total} guards are driven by a test "
          f"({len(KNOWN_BARE)} known bare, awaiting one)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
