#!/usr/bin/env python3
"""Fails when `AXLocalePolicy.allLabelSets` does not list every `LabelSet` declared beside it.

WHY THIS EXISTS
---------------
`allLabelSets` answers "does the product recognise this string at all", and `AXSnapshot` uses it as
an ALLOWLIST: a value that is not a recognised label is recorded as a shape (`len:13 latin+space`)
rather than verbatim, so a track name, a plugin name or a project filename cannot reach a fixture.

That makes the list a second copy of the declarations, and a second copy drifts. This is the thing
that fails when it does.

WHICH DIRECTION MATTERS
-----------------------
An omission OVER-redacts — a label the product knows is written as a shape. That is safe, and it is
why a hand-maintained list is tolerable here at all. It is still wrong: the fixture then cannot be
matched against the selector that uses that label, which is what fixtures are for.

An entry naming a set that no longer exists does not compile, so it needs no check.

Exit: 0 = every declaration is listed · 1 = something is missing
"""
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE = os.path.join(REPO, "Sources", "LogicProMCP", "Accessibility", "AXLocalePolicy.swift")


def main() -> int:
    with open(SOURCE, encoding="utf-8") as handle:
        text = handle.read()

    declared = re.findall(r"^\s+static let ([A-Za-z0-9_]+) = LabelSet\(", text, re.M)
    block = re.search(r"static let allLabelSets: \[LabelSet\] = \[(.*?)\n    \]", text, re.S)
    if not declared:
        print("CANNOT DETERMINE: no `= LabelSet(` declarations found — the file shape changed, and "
              "an empty expectation would pass against anything.")
        return 1
    if not block:
        print("CANNOT DETERMINE: `allLabelSets` not found in the expected shape.")
        return 1

    listed = set(re.findall(r"\.?([A-Za-z0-9_]+),", block.group(1)))
    missing = sorted(set(declared) - listed)
    if missing:
        print(f"AXLocalePolicy.allLabelSets is missing {len(missing)} of {len(declared)} label sets:")
        for name in missing:
            print(f"  {name}")
        print("\nAn omission over-redacts an AX snapshot: the label is written as a shape instead "
              "of verbatim, and the fixture stops being matchable against the selector using it.")
        return 1

    print(f"AXLocalePolicy.allLabelSets lists all {len(declared)} declared label sets")
    return 0


if __name__ == "__main__":
    sys.exit(main())
