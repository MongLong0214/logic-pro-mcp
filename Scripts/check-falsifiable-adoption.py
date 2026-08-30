#!/usr/bin/env python3
"""The strongest affordance a live harness has must not decay, and the gap must be a number.

`evidence.falsifiable()` hands the predicate to the framework, which runs it twice: once on what
the run observed, once on a counterexample the author had to write down. The check passes only when
the first is accepted AND the second rejected, and the author cannot supply the second result.
It is the only thing in the live kit that can notice a condition which could not have failed.

`is_clean` counts `checks_with_a_counterexample` and deliberately does not require it:

    Requiring every harness to HAVE one is the clause with teeth, and it is left
    counted-but-unenforced ... thirty-odd harnesses predate the affordance, and turning the whole
    live suite red in one step invites someone to delete the clause instead of converting the
    call sites. Enforce it when the count reaches the harness count, not before.

That reasoning is right and it left the number to nobody. Measured 2026-08-29: **1 of 35**. A
comment saying "enforce it later" has no way to notice going backwards, and no way to say how far
"later" is.

So this guard does the smaller thing that is mechanical rather than the larger one that is a
promise: the count may rise and may not fall. Raising FLOOR is a reviewed edit in this file, which
is where a ratchet's teeth are — a number that can be lowered by whoever is inconvenienced is a
suggestion.

It does not check that a counterexample is a GOOD one. `falsifiable` establishes that a predicate
can distinguish the observation from one stated alternative, and no more; whether that alternative
is the one that matters is the author's claim and a reviewer's job. Said here because a guard named
"adoption" invites being read as "quality".
"""
import ast
import glob
import os
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# The measured floor. Raise it when a harness converts; never lower it to make a branch pass.
FLOOR = 4

def _calls_falsifiable(text):
    """Whether the source contains an actual CALL to `falsifiable`, not a mention of the word.

    Parsed, because a regex counts `# falsifiable(` in a comment and a `"falsifiable("` in a
    string. Found by review, 2026-08-29, reproduced: a harness whose only occurrence was a comment
    held the floor and passed CI, and the test that was supposed to catch it wrote the word without
    the parenthesis — so the control could not see the defect it was aimed at.

    A file that will not parse claims nothing. It cannot be run either, so it cannot be an adopter.
    """
    try:
        tree = ast.parse(text)
    except SyntaxError:
        return False
    for node in ast.walk(tree):
        if not isinstance(node, ast.Call):
            continue
        func = node.func
        name = func.attr if isinstance(func, ast.Attribute) else getattr(func, "id", None)
        if name == "falsifiable":
            return True
    return False


def adoption(paths=None):
    """`(adopters, total)` — harnesses calling `falsifiable(`, and how many there are."""
    files = paths if paths is not None else sorted(
        glob.glob(os.path.join(REPO, "Scripts", "livekit", "live_*.py")))
    adopters = []
    for path in files:
        try:
            with open(path, encoding="utf-8") as fh:
                text = fh.read()
        except OSError:
            # Unreadable is not adopted. Counting it either way would let a permissions accident
            # move the number, and this number is the whole point of the guard.
            continue
        if _calls_falsifiable(text):
            adopters.append(os.path.basename(path))
    return adopters, len(files)


def main():
    adopters, total = adoption()
    if total == 0:
        print("-> FAIL: no live harnesses found — an empty set satisfies any floor")
        return 1

    print(f"   falsifiable() adoption: {len(adopters)} of {total} harnesses (floor {FLOOR})")
    for name in adopters:
        print(f"     uses it  {name}")

    if len(adopters) < FLOOR:
        print(f"-> FAIL: adoption fell to {len(adopters)}, below the recorded floor {FLOOR}")
        print("   A harness lost its counterexample, or one was deleted. Restore it, or raise the")
        print("   question in review — do not lower FLOOR to make this pass.")
        return 1

    if len(adopters) > FLOOR:
        print(f"-> FAIL: adoption is {len(adopters)} but FLOOR is still {FLOOR}")
        print(f"   Raise FLOOR to {len(adopters)} in this file. A ratchet that does not tighten")
        print("   when it can is a counter, and the next regression falls back to the old number.")
        return 1

    remaining = total - len(adopters)
    if remaining:
        print(f"   {remaining} harness(es) have no counterexample. `is_clean` will enforce")
        print(f"   checks_with_a_counterexample > 0 when this reaches {total}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
