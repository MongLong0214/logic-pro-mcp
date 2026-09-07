#!/usr/bin/env python3
"""A test may not measure the wall clock, because the wall clock measures the machine.

Discovered automatically by `run-repo-guards.py` (top-level `Scripts/check-*.py`), so it runs in
both CI jobs that gate a merge.

THE FAILURE THIS REFUSES, three times in two days on one assertion. `switchThatNeverChanges
StructureRefusesWithinDeadlineAndLeavesEntryView` bounded a refusal at `Date().timeIntervalSince
(started) < 0.75`. On a loaded GitHub runner it recorded 0.763, 0.771 and 0.778 s — roughly 3%
over — and each time it failed a pull request that changed **no Swift at all**. Two of those three
branches touched only Python and JSON; the third touched only an evidence document. The assertion
was red about the runner's scheduler and green about the code, and nothing distinguished the two.

WHAT THE ASSERTION WAS ACTUALLY FOR, and this is the part that makes raising the constant wrong.
It passed `confirmationTimeout: 0.025` and the writer's default is 3 s, so the real claim was *the
argument is honoured*. `waitForView` re-censuses the window structure on every turn of its wait
loop, and that count says the same thing without asking the machine: measured 2026-09-07, 13
censuses with the argument and 119 without it. A loaded machine makes such a loop turn FEWER
times, so load cannot cross a ceiling on it — the failure mode this rule exists to end is not
reachable from the replacement.

WHY A BAN AND NOT A LARGER BOUND. Moving 0.75 to 2.0 removes the symptom and keeps the property:
the next loaded runner moves it again, and each move is indistinguishable from a real regression
having been papered over. The three sites this repository had were all re-expressible as counts of
work the implementation does — polls, censuses, probe calls — and two of them got *stronger* in the
translation, because a count of one is a sharper statement than "finished inside half a second".

LOWER BOUNDS ARE BANNED TOO, for a different reason. `#expect(elapsed >= 0.10)` cannot be broken by
load, so it is not a flake; it is merely weak. `libraryAccessorWaitForRightmostSegmentIgnoresSame
NamedLeftColumn` used one to say a wait kept polling, and a count says that directly: the counted
version catches the same mutation in 1 ms rather than 120, and says "the loop turned" instead of
"the machine was not impossibly fast".

THE REACH, stated rather than implied. This reads text, so it sees the spellings below and not
every conceivable clock. `mach_absolute_time`, a `Task` measured through an injected clock, or a
timing helper that hides the read behind a name of its own would all pass. What it does close is
the cheap route — the one all three real instances took. There is deliberately no allowlist: a
site that genuinely needs a clock should change this file and say why in the same commit, so the
exception is reviewed as prose rather than registered as a line number.
"""
import glob
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TESTS = os.path.join(REPO, "Tests")

# Each spelling reads a clock at the moment the test runs. `Date(timeIntervalSince1970: 0)` and
# `Date(timeIntervalSinceNow: -18)` are constructor labels rather than reads, and carry no leading
# dot, so they are outside every pattern here on purpose: a fixed instant is not a measurement.
CLOCK_READS = (
    (re.compile(r"Date\(\)\s*\.\s*timeIntervalSince\b"), "Date().timeIntervalSince(…)"),
    (re.compile(r"Date\.now\s*\.\s*timeIntervalSince\b"), "Date.now.timeIntervalSince(…)"),
    (re.compile(r"\.\s*timeIntervalSinceNow\b"), ".timeIntervalSinceNow"),
    (re.compile(r"\bCFAbsoluteTimeGetCurrent\s*\("), "CFAbsoluteTimeGetCurrent()"),
    (re.compile(r"\bDispatchTime\.now\s*\("), "DispatchTime.now()"),
    (re.compile(r"\b(?:Continuous|Suspending)Clock\s*\("), "ContinuousClock()/SuspendingClock()"),
)

ADVICE = (
    "count the work the implementation does instead — polls, censuses, probe calls — which load "
    "can only reduce; see libraryAccessorWaitForSegmentReturnsPromptlyWhenAlreadyVisible (#804)"
)


def swift_tests(root=TESTS):
    return sorted(glob.glob(os.path.join(root, "**", "*.swift"), recursive=True))


def code_lines(source):
    """(1-based line number, text) with `//` comments and `/* */` blocks blanked out.

    A rule that fired on its own explanation would make every site unmentionable, including the
    docstring above this one.
    """
    out = []
    in_block = False
    for number, raw in enumerate(source.splitlines(), start=1):
        text = ""
        index = 0
        while index < len(raw):
            if in_block:
                end = raw.find("*/", index)
                if end < 0:
                    index = len(raw)
                    break
                in_block = False
                index = end + 2
                continue
            start_block = raw.find("/*", index)
            start_line = raw.find("//", index)
            if start_line >= 0 and (start_block < 0 or start_line < start_block):
                text += raw[index:start_line]
                index = len(raw)
                break
            if start_block >= 0:
                text += raw[index:start_block]
                in_block = True
                index = start_block + 2
                continue
            text += raw[index:]
            index = len(raw)
        out.append((number, text))
    return out


def clock_reads(source):
    """Every clock read in `source`, as (line number, line text, spelling)."""
    found = []
    for number, text in code_lines(source):
        for pattern, spelling in CLOCK_READS:
            if pattern.search(text):
                found.append((number, text.strip(), spelling))
    return found


def main():
    failures = []
    for path in swift_tests():
        with open(path, encoding="utf-8") as handle:
            source = handle.read()
        for number, text, spelling in clock_reads(source):
            failures.append((os.path.relpath(path, REPO), number, text, spelling))
    if failures:
        print("A test read the wall clock. " + ADVICE + ".", file=sys.stderr)
        for path, number, text, spelling in failures:
            print(f"  {path}:{number}: {spelling}", file=sys.stderr)
            print(f"      {text}", file=sys.stderr)
        return 1
    print(f"OK: no wall-clock reads in {len(swift_tests())} test files (#804)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
