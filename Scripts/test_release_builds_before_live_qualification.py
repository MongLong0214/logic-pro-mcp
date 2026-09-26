#!/usr/bin/env python3
"""release-stable.sh builds the release binary before `swift test` runs (#985).

The live qualification tests in the suite are enabled only when `.build/release/LogicProMCP` exists, and they drive that
binary against a running Logic. Run before the release build, they drive whatever this tree built last, or they are
skipped. So the script builds release first, refuses to go on without a running Logic, then runs the suite.
"""
import os
import re
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(REPO, "Scripts", "release-stable.sh")

BUILD = r"run swift build -c release$"
SUITE = r"run swift test\b"
LOGIC = r'.*! pgrep -xq "Logic Pro"'


def order_problems(text):
    lines = [line.strip() for line in text.splitlines()]

    def where(pattern):
        return [i for i, line in enumerate(lines) if re.match(pattern, line)]

    build, suite, logic = where(BUILD), where(SUITE), where(LOGIC)
    problems = []
    for name, hits in (("release build", build), ("swift test", suite), ("running-Logic check", logic)):
        if len(hits) != 1:
            problems.append(f"expected one {name} line, found {len(hits)}")
    if problems:
        return problems
    if not build[0] < suite[0]:
        problems.append("swift test runs before the release build")
    if not build[0] < logic[0] < suite[0]:
        problems.append("the running-Logic check is not between the release build and swift test")
    return problems


class ReleaseBuildsBeforeLiveQualification(unittest.TestCase):
    def test_the_repository_script_builds_first_and_requires_logic(self):
        with open(SCRIPT, encoding="utf-8") as f:
            self.assertEqual(order_problems(f.read()), [])

    def test_the_order_before_985_is_refused(self):
        old = 'run swift test --no-parallel\nrun swift build -c release\nif ! pgrep -xq "Logic Pro"; then\n'
        self.assertIn("swift test runs before the release build", order_problems(old))

    def test_a_script_without_the_logic_check_is_refused(self):
        text = "run swift build -c release\nrun swift test --no-parallel\n"
        self.assertEqual(order_problems(text), ["expected one running-Logic check line, found 0"])

    def test_a_logic_check_after_the_suite_is_refused(self):
        text = 'run swift build -c release\nrun swift test --no-parallel\nif ! pgrep -xq "Logic Pro"; then\n'
        self.assertEqual(
            order_problems(text),
            ["the running-Logic check is not between the release build and swift test"],
        )


if __name__ == "__main__":
    unittest.main()
