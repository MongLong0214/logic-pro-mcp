#!/usr/bin/env python3
"""Drive `check-third-party-imports-are-installed.py` over roots whose answer is known.

The guard exists because of a defect that only CI could see, so every case here builds a small
repository root where the answer is decided by construction: a driven file, an import, and a
workflow that either proves the module importable or does not. The control at each end is the
unmutated root, because a case that cannot tell a clean root from a dirty one is not a control.

The real repository is driven too, in `test_this_repository_passes`. That case is the one that
would have caught PyYAML had it existed on 2026-09-21, and it is the one that keeps the guard
pointed at the tree rather than only at fixtures.
"""
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GUARD = os.path.join(REPO, "Scripts", "check-third-party-imports-are-installed.py")

#: The readback the guard reads. Spelled once here so a change to the form in the guard fails
#: these cases rather than quietly making every fixture below satisfy nothing.
READBACK = 'python3 -c "import %s; print(%s)"'

WORKFLOW_HEAD = """\
name: ci
on: [push]
jobs:
  test:
    runs-on: macos-15
    steps:
      - name: prove what this runner can import
        run: |
"""


def workflow(*modules):
    lines = [WORKFLOW_HEAD]
    for module in modules:
        lines.append("          python3 -m pip install --quiet %s\n" % module)
        lines.append("          " + READBACK % (module, "'ok'") + "\n")
    return "".join(lines)


class Root:
    """A disposable repository root the guard can be run against."""

    def __init__(self):
        self.path = tempfile.mkdtemp(prefix="thirdparty-")
        os.makedirs(os.path.join(self.path, "Scripts", "livekit"))
        os.makedirs(os.path.join(self.path, ".github", "workflows"))
        # Both files the guard reaches for: itself, and the runner it asks for the driven set.
        # A root missing `run-repo-guards.py` does not run a weaker guard -- it runs no guard, and
        # the case would read the traceback as the refusal it was looking for.
        # The guard lands under a name `discovered()` does NOT match. It is a `check-*.py` in the
        # tree and would otherwise be its own first driven file, which makes the driven set of
        # every fixture non-empty and puts the "discovery returned nothing" branch out of reach --
        # an unreachable refusal is one nobody can show works.
        shutil.copy(os.path.join(REPO, "Scripts", "check-third-party-imports-are-installed.py"),
                    os.path.join(self.path, "Scripts", "_guard_under_test.py"))
        shutil.copy(os.path.join(REPO, "Scripts", "run-repo-guards.py"),
                    os.path.join(self.path, "Scripts", "run-repo-guards.py"))
        self.write_workflow(workflow())

    def write(self, relative, text):
        full = os.path.join(self.path, relative)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "w", encoding="utf-8") as handle:
            handle.write(text)

    def write_workflow(self, text):
        self.write(os.path.join(".github", "workflows", "ci.yml"), text)

    def run(self):
        proc = subprocess.run(
            [sys.executable,
             os.path.join(self.path, "Scripts", "_guard_under_test.py")],
            capture_output=True, text=True)
        return proc.returncode, proc.stdout + proc.stderr

    def close(self):
        shutil.rmtree(self.path, ignore_errors=True)


class TheGuardOverConstructedRoots(unittest.TestCase):
    def setUp(self):
        self.root = Root()
        self.addCleanup(self.root.close)

    def test_the_unmutated_root_passes(self):
        self.root.write("Scripts/test_plain.py", "import os\nimport json\n")
        code, out = self.root.run()
        self.assertEqual(code, 0, out)
        self.assertIn("all proved importable", out)

    def test_an_unproved_module_fails_and_names_the_file(self):
        self.root.write("Scripts/test_plain.py", "import os\nimport requests\n")
        code, out = self.root.run()
        self.assertEqual(code, 1, out)
        self.assertIn("requests", out)
        self.assertIn("Scripts/test_plain.py", out)

    def test_the_same_module_passes_once_the_workflow_proves_it(self):
        self.root.write("Scripts/test_plain.py", "import os\nimport requests\n")
        self.assertEqual(self.root.run()[0], 1)
        self.root.write_workflow(workflow("requests"))
        code, out = self.root.run()
        self.assertEqual(code, 0, out)

    def test_installing_without_the_readback_is_not_enough(self):
        # The defect this guard was written for was a package that WAS named somewhere and still
        # could not be imported. `pyyaml` installs and `yaml` imports; only the readback settles
        # which name a driven file will ask for.
        self.root.write("Scripts/test_plain.py", "import yaml\n")
        self.root.write_workflow(WORKFLOW_HEAD + "          python3 -m pip install pyyaml\n")
        code, out = self.root.run()
        self.assertEqual(code, 1, out)
        self.assertIn("yaml", out)

    def test_a_conditional_import_is_not_a_demand_on_ci(self):
        # How `Scripts/livekit/evidence.py` reaches Quartz. A harness that asks whether PyObjC is
        # present and answers honestly must not force CI to install it.
        self.root.write("Scripts/test_plain.py",
                        "import os\n\n\ndef ask():\n    try:\n        import Quartz\n"
                        "    except ImportError:\n        return None\n    return Quartz\n")
        code, out = self.root.run()
        self.assertEqual(code, 0, out)

    def test_an_import_reached_through_a_local_module_still_counts(self):
        # The residual that would have made this guard decorative: the driven file imports nothing
        # third-party, and dies anyway because the module it imports does.
        self.root.write("Scripts/test_plain.py", "import helper\n")
        self.root.write("Scripts/helper.py", "import requests\n")
        code, out = self.root.run()
        self.assertEqual(code, 1, out)
        self.assertIn("requests", out)
        self.assertIn("Scripts/helper.py", out)

    def test_a_file_the_runner_does_not_drive_is_not_scanned(self):
        # `Scripts/livekit/live_*.py` are run by hand against a live Logic, never by the runner.
        # Counting them would demand PyObjC in CI for a file CI never launches.
        self.root.write("Scripts/test_plain.py", "import os\n")
        self.root.write("Scripts/livekit/live_something.py", "import Quartz\n")
        code, out = self.root.run()
        self.assertEqual(code, 0, out)

    def test_a_missing_workflow_refuses_rather_than_passing(self):
        os.remove(os.path.join(self.root.path, ".github", "workflows", "ci.yml"))
        code, out = self.root.run()
        self.assertEqual(code, 2, out)
        self.assertIn("refusing rather than passing", out)

    def test_a_root_with_nothing_to_drive_refuses_rather_than_passing(self):
        # Zero is the answer a broken discovery gives, and it is indistinguishable from a clean
        # sweep unless the guard says so.
        code, out = self.root.run()
        self.assertEqual(code, 2, out)
        self.assertIn("discovered no Python file", out)

    def test_an_unparsable_driven_file_is_not_treated_as_importing_nothing(self):
        self.root.write("Scripts/test_plain.py", "def (\n")
        code, out = self.root.run()
        self.assertEqual(code, 1, out)
        self.assertIn("<unparsed>", out)


class TheGuardOverThisRepository(unittest.TestCase):
    def test_this_repository_passes(self):
        proc = subprocess.run([sys.executable, GUARD], capture_output=True, text=True, cwd=REPO)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)

    def test_it_actually_found_the_dependency_that_caused_this(self):
        # A guard that scanned the tree and required nothing would print the same exit code. The
        # count is what says it saw PyYAML; `test_issue_form_canon_field.py` imports it at module
        # level on purpose, so zero here means the scan stopped working.
        proc = subprocess.run([sys.executable, GUARD], capture_output=True, text=True, cwd=REPO)
        self.assertNotIn("0 third-party module(s) required", proc.stdout)


if __name__ == "__main__":
    unittest.main()
