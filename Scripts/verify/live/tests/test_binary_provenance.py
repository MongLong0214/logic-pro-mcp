#!/usr/bin/env python3
"""Offline: no file on disk can make `build()` report a binary it did not build (PR #1033 R2).

A real throwaway git repository supplies a commit; the swift build is replaced by /usr/bin/false,
so the build fails fast after the checkout. A forged record naming /bin/ls, with /bin/ls's true
hash and the `built-by-verifier` binding, sits where the old cache looked for records.
Each test names the mutation of binary.py it kills.
"""

import json
import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(os.path.dirname(HERE)))

from live import binary  # noqa: E402

FORGED = "/bin/ls"


def git(repo, *args):
    return subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True, check=True)


class Provenance(unittest.TestCase):

    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.repo = os.path.join(self.dir.name, "repo")
        self.root = os.path.join(self.dir.name, "build-root")
        os.makedirs(self.repo)
        git(self.repo, "init", "-q")
        with open(os.path.join(self.repo, "README"), "w") as handle:
            handle.write("fixture\n")
        git(self.repo, "add", "README")
        git(self.repo, "-c", "user.name=t", "-c", "user.email=t@example.invalid",
            "commit", "-q", "-m", "fixture")
        self.head = git(self.repo, "rev-parse", "HEAD").stdout.strip()
        os.makedirs(os.path.join(self.root, "bin"))
        forged = {"head": self.head, "binary_path": FORGED,
                  "binary_sha256": binary.sha256_of(FORGED), "binding": "built-by-verifier"}
        for name in (f"{self.head}.json", "record.json"):
            with open(os.path.join(self.root, "bin", name), "w") as handle:
                json.dump(forged, handle)
        self.saved = binary.SWIFT_BUILD if hasattr(binary, "SWIFT_BUILD") else None
        binary.SWIFT_BUILD = ["/usr/bin/false"]

    def tearDown(self):
        if self.saved is not None:
            binary.SWIFT_BUILD = self.saved
        self.dir.cleanup()

    def test_a_forged_record_is_never_consulted(self):
        # Kills: a record on disk (head + hash of its own claimed file) read back as a build.
        result = binary.build(self.head, self.repo, self.root, timeout_s=60)
        self.assertIsNot(result.get("reused"), True)
        self.assertNotEqual(result.get("binary_path"), FORGED)
        self.assertIsNone(result.get("binary_path"))
        self.assertNotEqual(result.get("binding"), "built-by-verifier")
        self.assertIn("swift-build", [stage["stage"] for stage in result["stages"]])

    def test_a_run_builds_a_head_once_and_reuses_it_only_from_memory(self):
        # Kills: Builds.get calling build() again for a head it already built in this run.
        calls = []
        saved_build = binary.build

        def fake_build(sha, repo, root, timeout_s):
            calls.append(sha)
            return {"head": sha, "binary_path": "/nonexistent/built", "binding": "built-by-verifier",
                    "stages": [{"stage": "swift-build", "returncode": 0}]}
        binary.build = fake_build
        try:
            builds = binary.Builds(self.repo, self.root)
            first, second = builds.get(self.head), builds.get(self.head)
            other = binary.Builds(self.repo, self.root).get(self.head)
        finally:
            binary.build = saved_build
        self.assertEqual(calls, [self.head, self.head])
        self.assertNotIn("reused_in_run", first)
        self.assertTrue(second["reused_in_run"])
        self.assertNotIn("reused_in_run", other)


if __name__ == "__main__":
    unittest.main()
