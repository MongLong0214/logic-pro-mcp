#!/usr/bin/env python3
"""Cases for `check-a-guard-can-refuse.py`, driven at fixture directories through the entry point.

The rule exists because a guard whose every exit path is a literal 0 prints `ok` for the same
reason a passing one does, and `run-repo-guards.py` counts it as coverage. The limit recorded
against the `NOT A GATE` marker said "nothing detects that, and nothing can". Whether a file has
any non-zero exit path is a question about its syntax tree, so something can.

    python3 Scripts/test_a_guard_can_refuse.py
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
GUARD = os.path.join(REPO, "Scripts", "check-a-guard-can-refuse.py")
_spec = importlib.util.spec_from_file_location("a_guard_can_refuse", GUARD)
guard = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(guard)

CANNOT_FAIL = '''\
import sys


def main():
    print("everything is fine")
    return 0


if __name__ == "__main__":
    sys.exit(main())
'''

CAN_FAIL = '''\
import sys


def main():
    problems = []
    if problems:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
'''


class Detection(unittest.TestCase):
    def _dir(self, files):
        root = tempfile.mkdtemp(prefix="can-refuse-")
        self.addCleanup(shutil.rmtree, root, ignore_errors=True)
        for name, body in files.items():
            with open(os.path.join(root, name), "w", encoding="utf-8") as handle:
                handle.write(body)
        return root

    def _run(self, root):
        return subprocess.run([sys.executable, GUARD], capture_output=True, text=True,
                              env=dict(os.environ, LPM_GUARD_DIR=root))

    def test_a_guard_that_cannot_fail_is_refused(self):
        proc = self._run(self._dir({"check-fixture.py": CANNOT_FAIL}))
        self.assertEqual(proc.returncode, 1, (proc.stdout + proc.stderr)[:300])
        self.assertIn("every exit path is a literal 0", proc.stderr)

    def test_a_guard_that_can_fail_passes(self):
        """The control. Without it the case above passes on a rule that refuses every guard."""
        proc = self._run(self._dir({"check-fixture.py": CAN_FAIL}))
        self.assertEqual(proc.returncode, 0, (proc.stdout + proc.stderr)[:300])

    def test_a_declared_counter_passes(self):
        declared = CANNOT_FAIL.replace("def main():", "#: NOT A GATE\ndef main():")
        proc = self._run(self._dir({"check-fixture.py": declared}))
        self.assertEqual(proc.returncode, 0, (proc.stdout + proc.stderr)[:300])
        self.assertIn("1 declared", proc.stdout)

    def test_mentioning_the_marker_is_not_declaring_it(self):
        """A docstring that EXPLAINS the marker must not switch the rule off -- which is the same
        loose match that classified this guard itself as a counter before the runner was fixed."""
        mentions = CANNOT_FAIL.replace(
            "def main():", 'MARKER = "#: NOT A GATE"  # the sentence a counter carries\ndef main():')
        proc = self._run(self._dir({"check-fixture.py": mentions}))
        self.assertEqual(proc.returncode, 1, (proc.stdout + proc.stderr)[:300])

    def test_a_directory_with_no_guards_is_refused(self):
        """An empty expectation passes against anything."""
        proc = self._run(self._dir({"not-a-guard.py": CAN_FAIL}))
        self.assertEqual(proc.returncode, 1, (proc.stdout + proc.stderr)[:300])
        self.assertIn("checking nothing", proc.stderr)

    def test_a_file_that_is_not_python_is_refused_not_skipped(self):
        proc = self._run(self._dir({"check-fixture.py": "def main(:\n"}))
        self.assertEqual(proc.returncode, 1, (proc.stdout + proc.stderr)[:300])
        self.assertIn("Unknown is not clean", proc.stderr)

    def test_the_repository_passes(self):
        proc = subprocess.run([sys.executable, GUARD], capture_output=True, text=True)
        self.assertEqual(proc.returncode, 0, (proc.stdout + proc.stderr)[:300])


class TheRunnerAgrees(unittest.TestCase):
    """The marker means the same thing to both readers, and neither reads a mention as one."""

    def test_both_read_the_marker_as_a_line_of_its_own(self):
        spec = importlib.util.spec_from_file_location(
            "run_repo_guards_for_marker", os.path.join(REPO, "Scripts", "run-repo-guards.py"))
        runner = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(runner)
        self.assertEqual(runner.NOT_A_GATE, guard.NOT_A_GATE)
        declaring = "#!/usr/bin/env python3\n    #: NOT A GATE\nx = 1\n"
        mentioning = '#!/usr/bin/env python3\nMARKER = "#: NOT A GATE"\n'
        for reader in (runner.declares_it_counts, guard.declares_it_counts):
            self.assertTrue(reader(declaring))
            self.assertFalse(reader(mentioning))


if __name__ == "__main__":
    unittest.main(verbosity=2)
