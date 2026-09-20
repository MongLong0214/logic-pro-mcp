#!/usr/bin/env python3
"""Cases for which guards `mutation-sweep-guard-tests.py` measures, and which it admits it did not.

The sweep is the tool that proves a guard's tests would notice the gate being removed. `--fast`
drops the two guards whose tests take over a minute -- and it used to drop them silently: they left
the target list, and the run then reported "N of M guard(s)" over the set it had chosen. Two guards
absent from the measurement AND from the sentence describing it is the shape this repository keeps
removing from everything else.

    python3 Scripts/test_mutation_sweep_targets.py
"""
import importlib.util
import os
import subprocess
import sys
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOOL = os.path.join(REPO, "Scripts", "mutation-sweep-guard-tests.py")
_spec = importlib.util.spec_from_file_location("mutation_sweep", TOOL)
sweep = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(sweep)

COVERED = {
    "check-alpha.py": ["test_alpha.py"],
    "check-canon-citations.py": ["test_canon_citations_guard.py"],
    "check-policy-literals-against-canon.py": ["test_policy_literals_against_canon.py"],
}


class Selection(unittest.TestCase):
    def test_a_full_run_sweeps_everything_and_skips_nothing(self):
        targets, skipped = sweep.select_targets(COVERED, set(), False)
        self.assertEqual(targets, sorted(COVERED))
        self.assertEqual(skipped, [])

    def test_fast_reports_what_it_left_out(self):
        """The property. Not that it skips -- that the caller is handed the names."""
        targets, skipped = sweep.select_targets(COVERED, set(), True)
        self.assertEqual(targets, ["check-alpha.py"])
        self.assertEqual(skipped, sorted(sweep.SLOW))

    def test_a_guard_named_on_the_command_line_is_swept_even_under_fast(self):
        """Asking for one of the slow guards used to answer `no guards to sweep` on exit 0."""
        targets, skipped = sweep.select_targets(COVERED, {"check-canon-citations.py"}, True)
        self.assertEqual(targets, ["check-canon-citations.py"])
        self.assertEqual(skipped, [])

    def test_the_slow_set_names_guards_that_exist(self):
        """A skip list keyed to a renamed file skips nothing and says it skipped two."""
        for name in sweep.SLOW:
            self.assertTrue(os.path.exists(os.path.join(REPO, "Scripts", name)), name)


class TheRunSaysSo(unittest.TestCase):
    """The entry point, not the helper: the sentence a reader sees has to carry the omission."""

    def test_fast_prints_the_unmeasured_guards_before_it_sweeps(self):
        proc = subprocess.run([sys.executable, TOOL, "--fast", "--dry-run"],
                              capture_output=True, text=True, timeout=300)
        self.assertIn("NOT MEASURED", proc.stdout)
        for name in sweep.SLOW:
            self.assertIn(name, proc.stdout)

    def test_a_full_run_claims_no_omission(self):
        """The control. Without it the case above passes on a tool that always prints the note."""
        proc = subprocess.run([sys.executable, TOOL, "--dry-run"],
                              capture_output=True, text=True, timeout=300)
        self.assertNotIn("NOT MEASURED", proc.stdout)
        for name in sweep.SLOW:
            self.assertIn(name, proc.stdout)  # a full run measures them, so it names them as targets


if __name__ == "__main__":
    unittest.main(verbosity=2)
