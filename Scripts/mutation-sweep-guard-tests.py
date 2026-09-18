#!/usr/bin/env python3
"""Which guard self-tests notice their guard's gate being removed, and which do not.

WHY
---
`check-guards-have-self-tests.py` requires a guard's filename to appear in a test that runs
something. Its own docstring says that is a FLOOR and names the rule it declines to write:

    Closing it properly means running each test with its guard mutated and watching the test fail,
    which is a different and much heavier rule; what is here is a floor that makes the cheap
    omission visible, not a proof that a listed test is a real one.

This is that rule, as a measurement rather than a gate. An outside review claimed 13 of 24 tests
stay green when their guard's `main()` is made to return 0 immediately. Rather than take that
number, this reproduces it.

WHAT IT DOES
------------
In a throwaway git worktree at HEAD -- never in the tree you are working in -- it inserts
`return 0` as the first statement of each guard's `main()`, runs that guard's covering tests, and
records whether any of them noticed. The mutation is the one the review used, and it is the
cheapest possible sabotage: the guard still imports, still prints nothing, and still exits 0.

WHAT A "BLIND" RESULT MEANS
---------------------------
The test drives the guard's helper functions and never the gate. Most of these assert "the real
tree passes", which a guard that refuses nothing satisfies. That is the wiring class of defect this
repository keeps finding -- a helper defined and never called, a rule guarding three lists while a
fourth sat open -- and a test blind to it cannot see a wiring regression in its own guard.

Usage:
  mutation-sweep-guard-tests.py            # every guard with a covering test
  mutation-sweep-guard-tests.py --fast     # skip the two guards whose tests take over a minute
  mutation-sweep-guard-tests.py NAME ...   # only these guards

Exit 0 whatever it finds: this MEASURES, it does not gate. The gate is
`docs/canon/GUARD-TESTS-BLIND-TO-THEIR-GUARD.json`, which the merge-base ratchet holds to shrinking.
"""
import importlib.util
import json
import os
import re
import subprocess
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
#: Their tests are 76s and 40s here, and neither is in question -- the review's deeper cut showed
#: both catching a permissive decision function. `--fast` skips them so the sweep is a minute.
SLOW = {"check-canon-citations.py", "check-policy-literals-against-canon.py"}

_spec = importlib.util.spec_from_file_location(
    "guards_have_self_tests", os.path.join(REPO, "Scripts", "check-guards-have-self-tests.py"))
_cov = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_cov)


def neuter(path: str) -> bool:
    """Insert `return 0` as the first statement of `main()`. False if there is no `main()`."""
    with open(path, encoding="utf-8") as handle:
        source = handle.read()
    match = re.search(r"^def main\([^)]*\)[^:]*:\n", source, re.M)
    if not match:
        return False
    rest = source[match.end():]
    # Step over a docstring so the insertion lands after it rather than inside it.
    doc = re.match(r'(\s*)("""|\'\'\')(.*?)\2\n', rest, re.S)
    offset = match.end() + (doc.end() if doc else 0)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(source[:offset] + "    return 0  # MUTANT: the gate is gone\n" + source[offset:])
    return True


def main(argv=None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    fast = "--fast" in argv
    only = {a for a in argv if not a.startswith("--")}

    covered = {}
    covered_map, _bare = _cov.coverage()
    for guard, tests in covered_map.items():
        if tests and guard.endswith(".py"):
            covered[guard] = tests
    targets = sorted(g for g in covered
                     if (not only or g in only) and not (fast and g in SLOW))
    if not targets:
        print("no guards to sweep", file=sys.stderr)
        return 0

    with tempfile.TemporaryDirectory() as tmp:
        tree = os.path.join(tmp, "sweep")
        add = subprocess.run(["git", "-C", REPO, "worktree", "add", "--detach", "-q", tree, "HEAD"],
                             capture_output=True, text=True)
        if add.returncode != 0:
            print(f"could not create a worktree to mutate: {add.stderr.strip()}", file=sys.stderr)
            return 2
        try:
            # The worktree is at HEAD, and what is being measured is the tree you are IN. The first
            # version skipped this and reported two guards BLIND whose tests had just been fixed --
            # a sweep that measures the last commit rather than the change in front of you answers
            # a question nobody asked.
            diff = subprocess.run(["git", "-C", REPO, "diff", "HEAD"],
                                  capture_output=True, text=True).stdout
            if diff.strip():
                applied = subprocess.run(["git", "-C", tree, "apply", "-"],
                                         input=diff, capture_output=True, text=True)
                if applied.returncode != 0:
                    print(f"could not carry the working tree into the sweep: "
                          f"{applied.stderr.strip()}", file=sys.stderr)
                    return 2
                print(f"(sweeping the working tree: {len(diff.splitlines())} diff line(s) applied "
                      f"over HEAD)")
            blind, caught, broken = [], [], []
            for guard in targets:
                path = os.path.join(tree, "Scripts", guard)
                with open(path, encoding="utf-8") as handle:
                    original = handle.read()
                if not neuter(path):
                    broken.append((guard, "no main() to neuter"))
                    continue
                noticed = None
                for test in covered[guard]:
                    proc = subprocess.run([sys.executable, os.path.join(tree, "Scripts", test)],
                                          capture_output=True, text=True, cwd=tree, timeout=600)
                    if proc.returncode != 0:
                        noticed = test
                        break
                with open(path, "w", encoding="utf-8") as handle:
                    handle.write(original)
                (caught if noticed else blind).append(
                    (guard, noticed or ", ".join(covered[guard])))
                print(f"{'caught ' if noticed else 'BLIND  '} {guard}"
                      f"{'  <- ' + noticed if noticed else ''}", flush=True)
        finally:
            subprocess.run(["git", "-C", REPO, "worktree", "remove", "--force", tree],
                           capture_output=True)

    print(f"\n{len(caught)} of {len(caught) + len(blind)} guard(s) have a test that notices the "
          f"gate being removed.")
    if broken:
        print(f"{len(broken)} could not be mutated: " + ", ".join(g for g, _ in broken))
    if blind:
        print("\nBLIND — the covering test drives the helpers and never the gate:")
        for guard, tests in blind:
            print(f"  {guard}  ({tests})")
        print(json.dumps({"guards": {g: t for g, t in blind}}, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
