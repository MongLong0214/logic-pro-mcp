#!/usr/bin/env python3
"""Cases for `check-falsifiable-adoption.py`, the ratchet on the live kit's counterexamples.

A ratchet has to bite in BOTH directions or it is a counter with an opinion: falling below the
floor is a regression, and rising above it without raising the floor leaves the next regression
free to fall back to the old number. Both are asserted here.

Written against `adoption()` with an explicit file list, so the cases do not depend on how many
harnesses the repository happens to contain today — that number is exactly what the guard exists
to track, and a test that reads it too would move with it.
"""
import importlib.util
import os
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
spec = importlib.util.spec_from_file_location(
    "adoption_guard", os.path.join(REPO, "Scripts", "check-falsifiable-adoption.py"))
G = importlib.util.module_from_spec(spec)
spec.loader.exec_module(G)

failed = 0
tmp = tempfile.mkdtemp()


def harness(name, body):
    path = os.path.join(tmp, name)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(body)
    return path


for label, files, want in [
    ("a harness that calls it counts",
     [harness("live_a.py", "E.falsifiable(tag, p, obs, cx, exp)\n")], 1),
    ("a harness that does not, does not",
     [harness("live_b.py", "E.check(tag, True, 'x', 'y')\n")], 0),
    ("a mention in prose is not a call",
     [harness("live_c.py", "# see falsifiable in evidence.py, it is the strong one\n")], 0),
    ("whitespace before the paren still counts",
     [harness("live_d.py", "E.falsifiable (tag, p, obs, cx, exp)\n")], 1),
    ("a longer name is not this one",
     [harness("live_e.py", "unfalsifiable(x)\n")], 0),
    ("two adopters count as two",
     [harness("live_f.py", "falsifiable(\n"), harness("live_g.py", "falsifiable(\n")], 2),
    ("an unreadable file is not adopted",
     [os.path.join(tmp, "live_missing.py")], 0),
]:
    adopters, total = G.adoption(files)
    ok = len(adopters) == want and total == len(files)
    failed += 0 if ok else 1
    print(f"{'ok  ' if ok else 'FAIL'} {label} -> {len(adopters)} of {total}")

# The floor is a constant in the guard, not a value read from the tree — a number the tree can
# move is not a floor.
ok = isinstance(G.FLOOR, int) and G.FLOOR >= 1
failed += 0 if ok else 1
print(f"{'ok  ' if ok else 'FAIL'} the floor is a reviewed constant -> FLOOR={G.FLOOR!r}")

# And it matches what the repository actually has. If this fails the guard itself fails, which is
# the point: raising the floor is the reviewed edit that records progress.
adopters, total = G.adoption()
ok = len(adopters) == G.FLOOR
failed += 0 if ok else 1
print(f"{'ok  ' if ok else 'FAIL'} the floor equals live adoption -> "
      f"{len(adopters)} adopters of {total}, FLOOR={G.FLOOR}")

print()
print(f"FAILED ({failed} unexpected)" if failed else "all cases behaved (0 unexpected)")
sys.exit(1 if failed else 0)
