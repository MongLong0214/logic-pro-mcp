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
    # The case the prose one could not see. A regex matched `falsifiable(` wherever it appeared,
    # so a harness whose only occurrence was a COMMENT held the floor and passed CI — and this
    # test's first version wrote the word without the parenthesis, which the regex also rejected.
    # The control agreed with the defect.
    ("a commented-out call is not a call",
     [harness("live_h.py", "# E.falsifiable(tag, p, obs, cx, exp)\nE.check(1)\n")], 0),
    ("the word inside a string is not a call",
     [harness("live_i.py", "msg = 'use falsifiable(...) instead'\n")], 0),
    ("a call reached through the module still counts",
     [harness("live_j.py", "import evidence\nevidence.falsifiable(1)\n")], 1),
    ("a call nested inside a function body counts",
     [harness("live_k.py", "def run():\n    if x:\n        E.falsifiable(1)\n")], 1),
    ("a file that will not parse is not an adopter",
     [harness("live_l.py", "def (\n E.falsifiable(1)\n")], 0),
    ("whitespace before the paren still counts",
     [harness("live_d.py", "E.falsifiable (tag, p, obs, cx, exp)\n")], 1),
    ("a longer name is not this one",
     [harness("live_e.py", "unfalsifiable(x)\n")], 0),
    ("two adopters count as two",
     [harness("live_f.py", "falsifiable(1)\n"), harness("live_g.py", "E.falsifiable(1)\n")], 2),
    ("an unreadable file is not adopted",
     [os.path.join(tmp, "live_missing.py")], 0),
]:
    adopters, total = G.adoption(files)
    ok = len(adopters) == want and total == len(files)
    failed += 0 if ok else 1
    print(f"{'ok  ' if ok else 'FAIL'} {label} -> {len(adopters)} of {total}")

# This is the exact shape that made the ratchet lie: the predicate receives only a boolean wrapper
# and the counterexample is a hand-authored constant dictionary. A real observation predicate beside
# it must still count, while the hollow call is reported with the source location that needs repair.
hollow = harness(
    "live_hollow.py",
    'E.falsifiable("hollow", lambda observation: observation["ok"], {"ok": True}, '
    '{"ok": False}, "expected")\n',
)
real = harness(
    "live_real.py",
    'E.falsifiable("real", lambda sliders: all(slider["description"] for slider in sliders), '
    '[{"description": "Peak 3 Q"}], [{"description": ""}], "expected")\n',
)
adopters, total, hollow_calls = G.adoption([hollow, real], include_hollow=True)
ok = (adopters == ["live_real.py"] and total == 2 and hollow_calls == [("live_hollow.py", 1)])
failed += 0 if ok else 1
print(f"{'ok  ' if ok else 'FAIL'} hollow calls do not count but real predicates do -> "
      f"adopters={adopters!r} hollow={hollow_calls!r}")

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
