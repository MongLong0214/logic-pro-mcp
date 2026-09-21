#!/usr/bin/env python3
"""Cases for `run-helper-suites.py`: that it still counts, and that a suite cannot go quiet.

The drive refused only when the TOTAL case count was zero. One suite losing every case lowered a
number nobody reads and passed -- the same shape as a guard that checks nothing. And the number it
printed was not the number of cases it had: `test_logic_bounce.py` re-exports three `TestCase`
classes from its neighbours, discovery loads a class wherever it finds it, and 32 cases were run
and counted twice (167 reported over 135 distinct).

Driven against fixture directories, so these run on any platform. The real runner runs on macOS,
where the AppKit-dependent standalone drive can execute.

    python3 Scripts/test_helper_suite_floors.py
"""
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DRIVE = os.path.join(REPO, "Scripts", "run-helper-suites.py")
_spec = importlib.util.spec_from_file_location("run_helper_suites", DRIVE)
drive = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(drive)

ALPHA = '''\
import unittest


class Alpha(unittest.TestCase):
    def test_one(self):
        pass

    def test_two(self):
        pass
'''

BETA = '''\
import unittest


class Beta(unittest.TestCase):
    def test_one(self):
        pass
'''

#: The aggregator, as `test_logic_bounce.py` is written: it imports a neighbour's class to
#: re-export it, and discovery then loads that class twice.
AGGREGATOR = '''\
import unittest

from logic_bounce_alpha_test import Alpha

__all__ = ["Alpha"]
'''


class Floors(unittest.TestCase):
    def _tree(self, files, suites):
        root = tempfile.mkdtemp(prefix="helper-suites-")
        self.addCleanup(shutil.rmtree, root, ignore_errors=True)
        for name, body in files.items():
            with open(os.path.join(root, name), "w", encoding="utf-8") as handle:
                handle.write(body)
        floors = os.path.join(root, "floors.json")
        with open(floors, "w", encoding="utf-8") as handle:
            json.dump({"suites": suites}, handle)
        return subprocess.run(
            [sys.executable, DRIVE], capture_output=True, text=True,
            env=dict(os.environ, LPM_HELPER_SUITES_DIR=root, LPM_HELPER_SUITE_FLOORS=floors))

    def test_a_tree_at_its_floors_passes(self):
        """The control. Without it every case below passes on a drive that refuses every tree."""
        proc = self._tree({"logic_bounce_alpha_test.py": ALPHA,
                           "logic_bounce_beta_test.py": BETA},
                          {"logic_bounce_alpha_test": 2, "logic_bounce_beta_test": 1})
        self.assertEqual(proc.returncode, 0, (proc.stdout + proc.stderr)[-400:])
        self.assertIn("3 distinct case(s)", proc.stdout)

    def test_a_suite_that_lost_a_case_is_refused(self):
        proc = self._tree({"logic_bounce_alpha_test.py": BETA.replace("Beta", "Alpha")},
                          {"logic_bounce_alpha_test": 2})
        self.assertEqual(proc.returncode, 1, (proc.stdout + proc.stderr)[-400:])
        self.assertIn("below its committed floor", proc.stderr)

    def test_a_suite_that_vanished_entirely_is_refused(self):
        """The total falling to zero was already refused. This is one suite of two going quiet."""
        proc = self._tree({"logic_bounce_alpha_test.py": ALPHA},
                          {"logic_bounce_alpha_test": 2, "logic_bounce_beta_test": 1})
        self.assertEqual(proc.returncode, 1, (proc.stdout + proc.stderr)[-400:])
        self.assertIn("discovery found NONE of it", proc.stderr)

    def test_an_undeclared_suite_is_refused(self):
        proc = self._tree({"logic_bounce_alpha_test.py": ALPHA,
                           "logic_bounce_beta_test.py": BETA},
                          {"logic_bounce_alpha_test": 2})
        self.assertEqual(proc.returncode, 1, (proc.stdout + proc.stderr)[-400:])
        self.assertIn("no floor", proc.stderr)

    def test_an_empty_floor_file_is_refused_rather_than_passed(self):
        proc = self._tree({"logic_bounce_alpha_test.py": ALPHA}, {})
        self.assertEqual(proc.returncode, 1, (proc.stdout + proc.stderr)[-400:])
        self.assertIn("names no suite", proc.stderr)

    def test_a_reexported_class_is_counted_once_and_under_the_module_that_defines_it(self):
        """`test_logic_bounce.py` exactly: 32 cases were being run, and counted, twice."""
        proc = self._tree({"logic_bounce_alpha_test.py": ALPHA,
                           "logic_bounce_bundle_test.py": AGGREGATOR},
                          {"logic_bounce_alpha_test": 2})
        self.assertEqual(proc.returncode, 0, (proc.stdout + proc.stderr)[-400:])
        self.assertIn("2 distinct case(s)", proc.stdout)
        self.assertIn("Ran 2 tests", proc.stderr)


class TheRealSuitesAreDeclared(unittest.TestCase):
    """The floors file is only worth having while it names the suites this repository ships."""

    def test_every_helper_suite_file_defines_a_declared_module(self):
        import glob
        committed = json.load(open(os.path.join(REPO, "Scripts", "helper-suite-cases.json"),
                                   encoding="utf-8"))["suites"]
        self.assertTrue(committed)
        for path in sorted(glob.glob(os.path.join(REPO, "Scripts", drive.PATTERN))):
            name = os.path.basename(path)[: -len(".py")]
            with open(path, encoding="utf-8") as handle:
                source = handle.read()
            # A file that defines no TestCase of its own is an aggregator; its cases are counted
            # under the module that defines them, so it is not expected to have a floor.
            if "unittest.TestCase" not in source:
                continue
            self.assertIn(name, committed, f"{name} defines cases and has no floor")


if __name__ == "__main__":
    unittest.main(verbosity=2)
