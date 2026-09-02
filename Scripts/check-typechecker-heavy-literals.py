#!/usr/bin/env python3
"""String concatenations big enough to time out the Swift type-checker, inside an argument literal.

THE DEFECT
----------
Swift type-checks one expression at a time, and a `+` chain of string literals mixed with
interpolation multiplies the solver's work. Put that chain inside a collection literal that is
itself an argument to a generic call with a trailing closure, and the whole construct is a single
expression. Whether it solves inside the limit then depends on the toolchain.

Reported by a contributor on 2026-09-02 while testing a merged fix: `main` would not build on their
machine at all. `AccessibilityChannel+MIDIImport.swift` had a five-way chain inside
`extras.merging([...]) { _, new in new }`, and their compiler gave up on it. It built here. A
timeout is not a diagnosable error in the reader's own code, so the cost lands entirely on whoever
pulls the repository cold (#749).

The fix is always the same and always behaviour-preserving: bind the string to a `let` before the
call, so the literal holds one identifier.

WHAT IS COUNTED
---------------
A collection literal passed as a call argument, containing a value with `THRESHOLD` or more `+`
operators. Concatenations that are NOT inside a call argument are left alone: a `let` with a long
chain is exactly the shape this guard wants people to write.

The threshold is deliberately below the reported five: the site that broke had five, and a guard
that only refuses what already broke cannot prevent the next one.
"""
import glob
import os
import re
import sys

THRESHOLD = 3
REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# A collection literal that is an argument to a call: `name([ ... ])` or `name([ ... ]) { ... }`.
# Non-greedy to the first `])`, which is enough for the flat literals this repository writes.
ARGUMENT_LITERAL = re.compile(r"\w+\(\s*\[(.*?)\]\s*\)", re.S)


def offenders():
    found = []
    for path in sorted(glob.glob(os.path.join(REPO, "Sources", "**", "*.swift"), recursive=True)):
        text = open(path, encoding="utf-8").read()
        for match in ARGUMENT_LITERAL.finditer(text):
            body = match.group(1)
            # Count `+` used as concatenation between string pieces, not inside interpolation.
            plus = len(re.findall(r'"\s*\n?\s*\+', body)) + len(re.findall(r'\+\s*\n?\s*"', body))
            concatenations = plus // 2 + plus % 2
            if concatenations >= THRESHOLD:
                line = text[: match.start()].count("\n") + 1
                found.append((os.path.relpath(path, REPO), line, concatenations))
    return found


def main():
    found = offenders()
    if not found:
        print(f"no argument literal carries {THRESHOLD}+ string concatenations")
        return 0
    print(f"{len(found)} argument literal(s) carry {THRESHOLD}+ string concatenations:")
    for path, line, count in found:
        print(f"  {path}:{line}  concatenations={count}")
    print()
    print("Bind the string to a `let` before the call. The type-checker then sees an identifier,")
    print("and the build stops depending on which toolchain the reader happens to have (#749).")
    return 1


if __name__ == "__main__":
    sys.exit(main())
