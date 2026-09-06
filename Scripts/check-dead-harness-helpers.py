#!/usr/bin/env python3
"""A live harness may not define a check it never calls.

Discovered automatically by `run-repo-guards.py` (top-level `Scripts/check-*.py`), so it runs in
both CI jobs that gate a merge.

THE FAILURE THIS REFUSES, three times over. A helper is added to a harness, described in a commit
message as closing a review finding, and never wired in. A function that runs zero times is a check
that cannot fail — the exact defect these harnesses exist to catch — and until now it was invisible
to everything: the ship gate runs the suite and the harness, and both are happy with a function
nobody calls. The third instance is what prompted this: `same_region` was added to
`live_575_move_to_playhead_reachable.py` to close a finding about a band that could be built from
two different regions, documented as the fix, and called from nowhere. A blind review of that commit
approved it.

WHY `live_*.py` AND NOT THE WHOLE DIRECTORY. These files are entry points: they are run, never
imported. So a module-level name referenced only by its own `def` is unreachable, full stop.
`evidence.py` is the opposite — every harness imports it, and its `label_set`, `artifact_answered`,
`is_clean` and `have_tools` are its public surface. `test_*.py` there are unit tests of the rules
and are run by the discoverer, not imported either, but their `def`s are collected by a test runner
rather than called by name.

That assumption is CHECKED rather than trusted: if a `live_*.py` ever does get imported somewhere,
this says so instead of quietly continuing to treat it as an entry point.

A RATCHET WOULD BE THE WRONG INSTRUMENT and this deliberately does not offer one. A dead helper is
not a debt to hold a line on, it is a deletion; a guard that lets one be registered instead of
removed re-creates the thing it detects.
"""
import ast
import glob
import os
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIVEKIT = os.path.join(REPO, "Scripts", "livekit")


def harnesses(root=LIVEKIT):
    """The entry-point harnesses: `live_*.py`, which are run and never imported."""
    return sorted(glob.glob(os.path.join(root, "live_*.py")))


def dead_defs(source):
    """Module-level function names that appear nowhere else in their own file.

    Counts NAME references, so a dictionary key that happens to spell the same word — `recorded
    .get("start_bar")` — is not a reference and does not keep a dead `start_bar` alive. Decorated
    functions are excluded: a decorator is a call site this file cannot see through, and refusing
    one would be a guess about a framework rather than a reading of the code.
    """
    tree = ast.parse(source)
    defined = {}
    for node in tree.body:
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) and not node.decorator_list:
            defined.setdefault(node.name, node.lineno)
    used = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Name) and isinstance(node.ctx, ast.Load):
            used.add(node.id)
        elif isinstance(node, ast.Attribute):
            used.add(node.attr)
        elif isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            for dec in node.decorator_list:
                for sub in ast.walk(dec):
                    if isinstance(sub, ast.Name):
                        used.add(sub.id)
    return sorted((name, line) for name, line in defined.items() if name not in used)


def importers(paths, root=REPO):
    """Any file that imports one of these harnesses as a module, by stem.

    The premise of this guard is that a `live_*.py` is an entry point. If that ever stops being
    true the premise is wrong, and saying so is better than continuing to reason from it.
    """
    stems = {os.path.splitext(os.path.basename(p))[0] for p in paths}
    found = {}
    for path in glob.glob(os.path.join(root, "Scripts", "**", "*.py"), recursive=True):
        if os.path.basename(path).startswith("live_"):
            continue
        try:
            tree = ast.parse(open(path, encoding="utf-8").read())
        except (OSError, SyntaxError):
            continue
        for node in ast.walk(tree):
            names = []
            if isinstance(node, ast.Import):
                names = [a.name for a in node.names]
            elif isinstance(node, ast.ImportFrom) and node.module:
                names = [node.module]
            for n in names:
                stem = n.split(".")[-1]
                if stem in stems:
                    found.setdefault(stem, set()).add(os.path.relpath(path, root))
    return found


def main():
    paths = harnesses()
    problems = []
    for stem, where in sorted(importers(paths).items()):
        problems.append(f"{stem} is IMPORTED by {sorted(where)} — this guard assumes `live_*.py` "
                        f"files are entry points and reasons about them on that basis. Reading a "
                        f"name as unreachable is only sound while nothing imports it")
    for path in paths:
        rel = os.path.relpath(path, REPO)
        try:
            source = open(path, encoding="utf-8").read()
        except OSError as exc:
            problems.append(f"{rel}: cannot be read ({exc})")
            continue
        try:
            dead = dead_defs(source)
        except SyntaxError as exc:
            problems.append(f"{rel}: does not parse ({exc})")
            continue
        for name, line in dead:
            problems.append(f"{rel}:{line}: `{name}` is defined and referenced nowhere in this "
                            f"file. A harness is run, never imported, so this cannot be called — "
                            f"and a check that runs zero times cannot fail. Delete it, or wire it "
                            f"in")
    if problems:
        print("dead helpers in live harnesses:")
        for line in problems:
            print(f"  {line}")
        print("\n  There is no ratchet for this on purpose: a dead helper is a deletion, not a "
              "debt.")
        return 1
    print(f"{len(paths)} live harness(es): every module-level def is referenced in its own file")
    return 0


if __name__ == "__main__":
    sys.exit(main())
