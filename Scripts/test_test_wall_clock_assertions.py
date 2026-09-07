#!/usr/bin/env python3
"""Prove `Scripts/check-test-wall-clock-assertions.py` can fail, and on the right things.

The three cases that carry the rule are the first, the fourth and the last: the exact line that
failed CI three times must be caught; a FIXED instant must not be, or every test in this
repository that stamps `Date(timeIntervalSince1970: 0)` turns red for no reason; and the guard's
own explanation of itself must not trip it, which is the way a text rule most often eats its own
documentation.
"""
import importlib.util
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location(
    "wall_clock", HERE / "check-test-wall-clock-assertions.py"
)
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)


def main():
    failures = []
    ran = [0]

    def case(name, cond, detail):
        ran[0] += 1
        if not cond:
            failures.append(f"{name}: {detail}")

    def hits(src):
        return [spelling for _, _, spelling in guard.clock_reads(src)]

    # THE LINE ITSELF. Verbatim from ControlsViewBooleanParameterWriterTests.swift before #804.
    original = (
        "        let completedWithinBoundedRestore = "
        "Date().timeIntervalSince(started) < 0.75\n"
    )
    case("the assertion that failed CI three times is caught",
         hits(original) == ["Date().timeIntervalSince(…)"], hits(original))

    # A lower bound is not a flake, but it is weak, and the rule bans it on purpose.
    src = "    #expect(Date().timeIntervalSince(start) >= 0.10)\n"
    case("a lower bound is caught too", len(hits(src)) == 1, hits(src))

    # The binding form, where the comparison is on another line entirely.
    src = "        let elapsed = Date().timeIntervalSince(start)\n        #expect(elapsed < 2.0)\n"
    case("an elapsed binding is caught even when the comparison is elsewhere",
         len(hits(src)) == 1, hits(src))

    # FIXED INSTANTS ARE NOT MEASUREMENTS. These spellings are everywhere in this suite —
    # 40-odd sites — and catching one of them would make the rule unadoptable.
    for fixed in (
        "        let t = Date(timeIntervalSince1970: 1_700_000_000)\n",
        "        lastUpdated: Date(timeIntervalSinceNow: -18)\n",
        "        approvedAt: Date(timeIntervalSince1970: 0), note: \"test\")\n",
    ):
        case(f"a fixed instant is not a measurement: {fixed.strip()[:40]}",
             hits(fixed) == [], hits(fixed))

    # ...but reading the property off a Date variable IS an elapsed measurement.
    src = "        let age = -started.timeIntervalSinceNow\n"
    case("elapsed read off a variable is caught", hits(src) == [".timeIntervalSinceNow"], hits(src))

    # The other clocks the rule names.
    for src, spelling in (
        ("        let t0 = CFAbsoluteTimeGetCurrent()\n", "CFAbsoluteTimeGetCurrent()"),
        ("        let t0 = DispatchTime.now()\n", "DispatchTime.now()"),
        ("        let c = ContinuousClock()\n", "ContinuousClock()/SuspendingClock()"),
    ):
        case(f"{spelling} is caught", hits(src) == [spelling], hits(src))

    # COMMENTS ARE NOT CODE. A rule that fired on prose would make its own subject unmentionable —
    # every one of these lines exists in the files this rule now governs.
    for comment in (
        "        // replaces Date().timeIntervalSince(started) < 0.75, which measured the runner\n",
        "        /* Date().timeIntervalSince(start) */ let x = 1\n",
        "        /*\n         * CFAbsoluteTimeGetCurrent() is banned here\n         */\n",
    ):
        case(f"a comment is not a clock read: {comment.strip()[:44]}",
             hits(comment) == [], hits(comment))

    # ...and code on the same line as a trailing comment is still code.
    src = "        let t = CFAbsoluteTimeGetCurrent() // start\n"
    case("code before a trailing comment is still read",
         hits(src) == ["CFAbsoluteTimeGetCurrent()"], hits(src))

    # A file with no clock in it is silent.
    case("a clean file yields nothing", hits("        #expect(polls.value <= 4)\n") == [], "")

    # The walk finds Swift at any depth, since Tests/ is nested.
    root = Path(tempfile.mkdtemp())
    (root / "A" / "B").mkdir(parents=True)
    (root / "A" / "B" / "T.swift").write_text(original, encoding="utf-8")
    (root / "A" / "notes.md").write_text(original, encoding="utf-8")
    found = guard.swift_tests(str(root))
    case("nested Swift is walked and non-Swift is left alone",
         [Path(p).name for p in found] == ["T.swift"], found)

    # THE GUARD'S OWN PROSE. Its docstring quotes the banned spellings by necessity; if the rule
    # read Python the way it reads Swift it would flag itself, so this is the self-eating case.
    proc = subprocess.run([sys.executable, str(HERE / "check-test-wall-clock-assertions.py")],
                          capture_output=True, text=True)
    case("the repository is green under the rule",
         proc.returncode == 0, (proc.stdout + proc.stderr).strip()[:300])

    if failures:
        for f in failures:
            print(f"FAIL {f}")
        return 1
    print(f"{ran[0]} case(s) pass: an upper bound on elapsed time measures the machine")
    return 0


if __name__ == "__main__":
    sys.exit(main())
