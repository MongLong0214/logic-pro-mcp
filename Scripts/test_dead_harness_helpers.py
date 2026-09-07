#!/usr/bin/env python3
"""Prove `Scripts/check-dead-harness-helpers.py` can fail, and on the right things.

The two cases that matter are the last two: a name that appears only as a STRING must not keep a
dead function alive, and a `live_*.py` that somebody imports must break the guard's premise loudly
rather than silently.
"""
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("dead_helpers", HERE / "check-dead-harness-helpers.py")
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)


def main():
    failures = []
    ran = [0]

    def case(name, cond, detail):
        ran[0] += 1
        if not cond:
            failures.append(f"{name}: {detail}")

    def dead(src):
        return [n for n, _ in guard.dead_defs(src)]

    case("a def nobody calls is dead",
         dead("def helper():\n    return 1\n") == ["helper"], dead("def helper():\n    return 1\n"))
    case("a def that is called is not dead",
         dead("def helper():\n    return 1\n\nhelper()\n") == [],
         dead("def helper():\n    return 1\n\nhelper()\n"))
    case("a def referenced without calling is not dead",
         dead("def helper():\n    return 1\n\nf = helper\n") == [],
         dead("def helper():\n    return 1\n\nf = helper\n"))
    case("a def called from inside another function is not dead",
         dead("def a():\n    return 1\n\ndef b():\n    return a()\n\nb()\n") == [],
         dead("def a():\n    return 1\n\ndef b():\n    return a()\n\nb()\n"))

    # THE STRING CASE. `live_519` carried a dead `start_bar` while `recorded.get("start_bar")`
    # appeared three times — as a dictionary KEY. Counting text rather than names would have read
    # those as references and left the dead helper in place.
    src = 'def start_bar(t):\n    return 1\n\nx = {"start_bar": 2}\ny = x.get("start_bar")\n'
    case("a name that appears only as a string does not keep a def alive",
         dead(src) == ["start_bar"], dead(src))

    # A decorated function has a call site this guard cannot see through. Refusing it would be a
    # guess about a framework rather than a reading of the code.
    src = "import functools\n\n@functools.cache\ndef helper():\n    return 1\n"
    case("a decorated def is not called dead", dead(src) == [], dead(src))
    # ...but the decorator's own name still counts as a use of whatever it names.
    src = "def deco(f):\n    return f\n\n@deco\ndef helper():\n    return 1\n\nhelper()\n"
    case("a decorator counts as a reference to the function it names", dead(src) == [], dead(src))

    # Nested defs are not module-level and are not this guard's business.
    src = "def outer():\n    def inner():\n        return 1\n    return 2\n\nouter()\n"
    case("a nested def is out of scope", dead(src) == [], dead(src))

    # THE PREMISE CHECK. `live_*.py` is treated as unreachable-if-unreferenced only because nothing
    # imports it. If that stops being true the guard must say so, not keep reasoning from it.
    root = Path(tempfile.mkdtemp())
    (root / "Scripts" / "livekit").mkdir(parents=True)
    (root / "Scripts" / "livekit" / "live_x.py").write_text("def helper():\n    return 1\n",
                                                            encoding="utf-8")
    case("with nothing importing it, no premise complaint",
         guard.importers(guard.harnesses(str(root / "Scripts" / "livekit")), str(root)) == {},
         "")
    (root / "Scripts" / "importer.py").write_text("import live_x\n", encoding="utf-8")
    found = guard.importers(guard.harnesses(str(root / "Scripts" / "livekit")), str(root))
    case("an imported harness is reported, not assumed away",
         set(found) == {"live_x"}, found)

    # And the guard as a whole is green on the real tree.
    proc = subprocess.run([sys.executable, str(HERE / "check-dead-harness-helpers.py")],
                          capture_output=True, text=True)
    case("repository has no dead harness helpers", proc.returncode == 0, proc.stdout.strip()[:200])

    if failures:
        for f in failures:
            print(f"FAIL {f}")
        return 1
    print(f"{ran[0]} case(s) pass: a helper nobody calls is a check that cannot fail")
    return 0


if __name__ == "__main__":
    sys.exit(main())
