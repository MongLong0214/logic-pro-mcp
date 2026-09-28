#!/usr/bin/env python3
"""Drives `Scripts/verify/verify.py self-test`, the fixed verifier's fixtures and engine mutants (ADR-027).

The self-test is what gives the verifier's exit codes their meaning. Its fixtures cover every
verdict and refusal, and its mutants show that each rule has a fixture that fails without it. If
someone weakens a rule without also weakening that rule's fixture, a mutant survives and this
drive fails. It needs no network and no running Logic.

    python3 Scripts/test_verify_self_test.py
"""
import os
import re
import subprocess
import sys
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VERIFY = os.path.join(REPO, "Scripts", "verify", "verify.py")
SUMMARY = re.compile(r"^self-test: (\d+) case\(s\) passed; (\d+) of (\d+) mutant\(s\) killed, "
                     r"0 survived; control survived \(exit 0\)$", re.M)


class VerifierSelfTest(unittest.TestCase):
    def test_every_case_passes_and_every_mutant_is_killed(self):
        proc = subprocess.run([sys.executable, VERIFY, "self-test"], capture_output=True, text=True,
                              timeout=600)
        tail = "\n".join((proc.stdout + proc.stderr).strip().splitlines()[-25:])
        self.assertEqual(proc.returncode, 0, tail)
        found = SUMMARY.search(proc.stdout)
        self.assertIsNotNone(found, tail)
        cases, killed, total = (int(g) for g in found.groups())
        self.assertGreater(cases, 0, tail)
        self.assertGreater(total, 0, tail)
        self.assertEqual(killed, total, tail)

    def test_run_and_batch_refuse_before_anything_is_built(self):
        """The live commands refuse bad input with exit 2 before a build or the live lock: a head
        that is not 40 hex, and a spec handed to batch as its queue."""
        spec = os.path.join(REPO, "docs", "acceptance", "1020.json")
        for argv, says in ((["run", spec, "--head", "HEAD", "--out", os.devnull],
                            "not a full 40-hex commit"),
                           (["batch", "--queue", spec, "--out-dir", os.devnull],
                            "not an lpm-queue/1 queue")):
            proc = subprocess.run([sys.executable, VERIFY] + argv, capture_output=True, text=True,
                                  timeout=60)
            self.assertEqual(proc.returncode, 2, proc.stdout + proc.stderr)
            self.assertIn(says, proc.stdout)
            self.assertIn("refused before anything was built or driven", proc.stdout)


if __name__ == "__main__":
    unittest.main()
