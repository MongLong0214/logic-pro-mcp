#!/usr/bin/env python3
"""Cases for `check-guards-have-self-tests.py`, the rule that a guard ships with a test driving it.

The rule demanded a test for itself the first time it ran, which is the right answer and this is it.

The case that matters is the third: a guard named only in a test's opening paragraph must still
count as bare. Three tests in this repository mention `check-python-contracts.py` in prose and none
of them run it, so a rule that counted prose would report eleven of fourteen guards covered while
nine were not — flattering itself with the exact failure it exists to name.
"""
import importlib.util
import os
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
spec = importlib.util.spec_from_file_location(
    "guards_self_tests", os.path.join(REPO, "Scripts", "check-guards-have-self-tests.py"))
G = importlib.util.module_from_spec(spec)
spec.loader.exec_module(G)

failed = 0


def case(name, condition, detail):
    global failed
    failed += 0 if condition else 1
    print(f"{'ok  ' if condition else 'FAIL'} {name} -> {detail}")


def write(directory, name, body):
    path = os.path.join(directory, name)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(body)
    return path


def coverage_in(tmp, guard_body, test_body, test_name="test_thing.py"):
    scripts = os.path.join(tmp, "Scripts")
    os.makedirs(os.path.join(scripts, "livekit"), exist_ok=True)
    write(scripts, "check-thing.py", guard_body)
    if test_body is not None:
        write(scripts, test_name, test_body)
    original = G.REPO
    G.REPO = tmp
    try:
        return G.coverage()
    finally:
        G.REPO = original


# 1. A guard with nothing beside it is bare.
with tempfile.TemporaryDirectory() as tmp:
    covered, bare = coverage_in(tmp, "print(1)\n", None)
    case("a guard with no test is bare", bare == ["check-thing.py"], f"bare={bare!r}")

# 2. A guard a test LOADS is covered. Naming it is not enough — the file has to run something,
#    which an outside review is the reason for: a dead `if False: marker = "check-thing.py"`
#    counted as coverage while only a substring was read.
with tempfile.TemporaryDirectory() as tmp:
    covered, bare = coverage_in(
        tmp, "print(1)\n",
        'import importlib.util\n'
        'GUARD = os.path.join(REPO, "Scripts", "check-thing.py")\n'
        'spec = importlib.util.spec_from_file_location("g", GUARD)\n')
    case("a guard referenced in code is covered",
         list(covered) == ["check-thing.py"] and bare == [], f"covered={covered!r} bare={bare!r}")

# 3. THE CASE. A guard named only in prose is still bare — three real tests name
#    `check-python-contracts.py` in their opening paragraph and none of them run it.
with tempfile.TemporaryDirectory() as tmp:
    covered, bare = coverage_in(
        tmp, "print(1)\n",
        '"""Scripts/check-thing.py proves every name a consumer references exists."""\nprint(2)\n')
    case("a guard named only in a docstring is still bare",
         bare == ["check-thing.py"], f"covered={covered!r} bare={bare!r}")

# 3b. A file that names the guard but runs NOTHING is bare, however the name is spelled.
with tempfile.TemporaryDirectory() as tmp:
    covered, bare = coverage_in(
        tmp, "print(1)\n", 'if False:\n    marker = "check-thing.py"\n')
    case("a guard named in a file that executes nothing is bare",
         bare == ["check-thing.py"], f"covered={covered!r} bare={bare!r}")

# 4. And named only in a comment, for the shell tests, which have no docstrings.
with tempfile.TemporaryDirectory() as tmp:
    covered, bare = coverage_in(
        tmp, "print(1)\n", "# Self-test for check-thing.py\nbash /dev/null\n", test_name="test-thing.sh")
    case("a guard named only in a comment is still bare",
         bare == ["check-thing.py"], f"covered={covered!r} bare={bare!r}")

# 5. The ratchet is a reviewed constant, and it matches the tree. If a guard gains a test the list
#    has to be shortened by hand — that edit is what records the progress.
_, live_bare = G.coverage()
case("the known-bare list equals what the repository actually has",
     set(live_bare) == set(G.KNOWN_BARE),
     f"{len(live_bare)} bare, KNOWN_BARE={len(G.KNOWN_BARE)}, "
     f"difference={sorted(set(live_bare) ^ set(G.KNOWN_BARE))!r}")

# 6. This rule holds itself to its own rule: it is a guard, and it is not on the bare list.
case("the rule is not exempt from itself",
     "check-guards-have-self-tests.py" not in G.KNOWN_BARE and
     "check-guards-have-self-tests.py" not in live_bare,
     "it names a test that drives it")

print()
print(f"FAILED ({failed} unexpected)" if failed else "all cases behaved (0 unexpected)")
sys.exit(1 if failed else 0)
