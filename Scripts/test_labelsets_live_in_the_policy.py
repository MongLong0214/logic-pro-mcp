#!/usr/bin/env python3
"""Drive `check-labelsets-live-in-the-policy.py` with the defect it names, and with what it allows.

Both halves matter. The guard exists because a LabelSet outside the policy file is counted by
nothing; it would be useless if it refused the three places that legitimately wrap a VARIABLE,
because somebody would delete it rather than route around it.
"""
import importlib.util
import os
import shutil
import tempfile
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)


def _load(name, filename):
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


guard = _load("labelsets_in_policy_guard", "check-labelsets-live-in-the-policy.py")


class ATreeIsBuilt(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.root, True)
        self.policy = os.path.join(self.root, "AXLocalePolicy.swift")
        with open(self.policy, "w", encoding="utf-8") as handle:
            handle.write('static let a = LabelSet(\n    canonical: "File",\n    variants: [])\n')

    def _write(self, name, body):
        path = os.path.join(self.root, name)
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(body)
        return path


class TheGuardCatchesWhatItNames(ATreeIsBuilt):
    def test_a_literal_canonical_outside_the_policy_is_refused(self):
        self._write("Elsewhere.swift",
                    'let s = AXLocalePolicy.LabelSet(\n    canonical: "Show Library",\n'
                    '    variants: [],\n    rationale: "x")\n')
        self.assertEqual(len(guard.offenders(self.root, self.policy)), 1)

    def test_a_literal_variant_outside_the_policy_is_refused(self):
        self._write("Elsewhere.swift",
                    'let s = AXLocalePolicy.LabelSet(\n    canonical: scope,\n'
                    '    variants: ["라이브러리"],\n    rationale: "x")\n')
        self.assertEqual(len(guard.offenders(self.root, self.policy)), 1)

    def test_the_line_number_names_the_declaration(self):
        self._write("Elsewhere.swift",
                    '// one\n// two\nlet s = AXLocalePolicy.LabelSet(canonical: "X", variants: [])\n')
        self.assertEqual(guard.offenders(self.root, self.policy)[0][1], 3)


class TheGuardAllowsWhatItMust(ATreeIsBuilt):
    def test_a_labelset_wrapping_a_variable_is_allowed(self):
        """`MainEntrypoint`, `SemanticSelector` and `AtlasCapture` all do this, and must keep working."""
        self._write("Elsewhere.swift",
                    'let s = AXLocalePolicy.LabelSet(canonical: scope, variants: [],\n'
                    '    rationale: "ax-snapshot scope")\n')
        self.assertEqual(guard.offenders(self.root, self.policy), [])

    def test_variants_from_an_array_variable_are_allowed(self):
        self._write("Elsewhere.swift",
                    'let s = AXLocalePolicy.LabelSet(\n    canonical: labels.first ?? "",\n'
                    '    variants: Array(labels.dropFirst()),\n    rationale: "selector predicate")\n')
        self.assertEqual(guard.offenders(self.root, self.policy), [])

    def test_the_policy_file_itself_is_never_an_offender(self):
        self.assertEqual(guard.offenders(self.root, self.policy), [])

    def test_the_real_tree_passes(self):
        self.assertEqual(guard.offenders(os.path.join(REPO, "Sources"), guard.POLICY), [])


REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))




class TheEntryPointRefuses(unittest.TestCase):
    """The cases above call the guard's helpers. A `main()` that returned 0 without ever calling
    them would pass every one, because the repository passes --
    `Scripts/mutation-sweep-guard-tests.py` measured exactly that on 2026-09-18. A guard is its
    entry point, so these drive it at an input that must fail, with a control that must pass.
    """

    def _run(self, script, **env):
        import subprocess
        return subprocess.run(
            [sys.executable, os.path.join(REPO_ROOT, "Scripts", script)],
            capture_output=True, text=True, env=dict(os.environ, **env))
    def test_a_labelset_outside_the_policy_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            src = os.path.join(tmp, "src")
            os.makedirs(src)
            with open(os.path.join(src, "Bad.swift"), "w", encoding="utf-8") as handle:
                handle.write('let x = LabelSet(canonical: "Mixer", variants: [], rationale: "x")\n')
            proc = self._run("check-labelsets-live-in-the-policy.py", LPM_POLICY_ROOTS=src)
            self.assertEqual(proc.returncode, 1, (proc.stdout + proc.stderr)[:300])
            self.assertIn("Bad.swift", proc.stdout + proc.stderr)

    def test_the_repositorys_own_sources_are_accepted(self):
        """The control."""
        proc = self._run("check-labelsets-live-in-the-policy.py")
        self.assertEqual(proc.returncode, 0, (proc.stdout + proc.stderr)[:300])


if __name__ == "__main__":
    unittest.main(verbosity=2)
