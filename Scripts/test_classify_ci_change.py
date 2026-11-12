#!/usr/bin/env python3
"""Behavioral tests for the exact PR merge change-scope classifier."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

import yaml


REPO = Path(__file__).resolve().parent.parent
SCRIPT = REPO / "Scripts" / "classify-ci-change.py"
ROADMAP = Path("docs/roadmap/README.md")


class MergeFixture:
    def __init__(self, mutate):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.git("init", "-q", "--initial-branch=main")
        self.git("config", "user.name", "CI Fixture")
        self.git("config", "user.email", "ci-fixture@example.invalid")
        (self.root / ROADMAP).parent.mkdir(parents=True)
        (self.root / ROADMAP).write_text("roadmap v1\n", encoding="utf-8")
        source = self.root / "Sources" / "value.swift"
        source.parent.mkdir(parents=True)
        source.write_text("let value = 1\n", encoding="utf-8")
        self.git("add", ".")
        self.git("commit", "-qm", "base")
        self.base = self.rev("HEAD")
        self.git("switch", "-qc", "feature")
        mutate(self.root)
        self.git("add", "-A")
        self.git("commit", "--allow-empty", "-qm", "feature")
        self.head = self.rev("HEAD")
        self.git("switch", "-q", "main")
        self.git("merge", "--no-ff", "-qm", "merge", "feature")
        self.merge = self.rev("HEAD")

    def close(self):
        self.temporary.cleanup()

    def git(self, *arguments):
        return subprocess.run(
            ["git", *arguments], cwd=self.root, check=True,
            capture_output=True, text=True,
        )

    def rev(self, revision):
        return self.git("rev-parse", revision).stdout.strip()

    def run(self, *, head=None, base=None, checkout=None):
        event = {"pull_request": {"head": {"sha": head or self.head},
                                  "base": {"sha": base or self.base}}}
        event_path = self.root / "event.json"
        output_path = self.root / "output.txt"
        summary_path = self.root / "summary.md"
        event_path.write_text(json.dumps(event), encoding="utf-8")
        environment = dict(os.environ, GITHUB_EVENT_PATH=str(event_path),
                           GITHUB_SHA=checkout or self.merge,
                           GITHUB_OUTPUT=str(output_path),
                           GITHUB_STEP_SUMMARY=str(summary_path))
        result = subprocess.run(
            [sys.executable, str(SCRIPT), "--git", "git"], cwd=self.root,
            env=environment, capture_output=True, text=True,
        )
        outputs = {}
        if output_path.exists():
            for line in output_path.read_text(encoding="utf-8").splitlines():
                key, value = line.split("=", 1)
                outputs[key] = value
        summary = summary_path.read_text(encoding="utf-8") if summary_path.exists() else ""
        return result, outputs, summary


def roadmap(root, value="roadmap v2\n"):
    (root / ROADMAP).write_text(value, encoding="utf-8")


class ClassifyCIChangeTests(unittest.TestCase):
    def fixture(self, mutate):
        fixture = MergeFixture(mutate)
        self.addCleanup(fixture.close)
        return fixture

    def test_exact_regular_roadmap_modification_is_docs_only(self):
        result, outputs, summary = self.fixture(roadmap).run()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(outputs, {"mode": "roadmap-docs-only", "full-validation": "false"})
        self.assertIn("docs/roadmap/README.md", summary)

    def test_source_or_mixed_change_requires_full_validation(self):
        def source(root):
            (root / "Sources/value.swift").write_text("let value = 2\n", encoding="utf-8")

        def mixed(root):
            roadmap(root)
            source(root)

        for mutate in (source, mixed):
            with self.subTest(mutate=mutate.__name__):
                result, outputs, _ = self.fixture(mutate).run()
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(outputs, {"mode": "full", "full-validation": "true"})

    def test_empty_merge_difference_requires_full_validation(self):
        result, outputs, _ = self.fixture(lambda _root: None).run()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(outputs, {"mode": "full", "full-validation": "true"})

    def test_add_delete_rename_and_symlink_never_take_docs_only_path(self):
        def added(root):
            roadmap(root)
            (root / "docs/roadmap/OTHER.md").write_text("other\n", encoding="utf-8")

        def deleted(root):
            (root / ROADMAP).unlink()

        def renamed(root):
            (root / ROADMAP).rename(root / "docs/roadmap/RENAMED.md")

        def symlink(root):
            (root / ROADMAP).unlink()
            (root / ROADMAP).symlink_to("../../Sources/value.swift")

        for mutate in (added, deleted, renamed, symlink):
            with self.subTest(mutate=mutate.__name__):
                result, outputs, _ = self.fixture(mutate).run()
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(outputs, {"mode": "full", "full-validation": "true"})

    def test_newline_path_cannot_hide_a_mixed_change(self):
        def mutate(root):
            roadmap(root)
            (root / "docs/roadmap/hidden\nSources-value.swift").write_text("x\n", encoding="utf-8")

        result, outputs, _ = self.fixture(mutate).run()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(outputs, {"mode": "full", "full-validation": "true"})

    def test_wrong_head_base_or_nonmerge_checkout_fails_without_outputs(self):
        fixture = self.fixture(roadmap)
        cases = [
            {"head": fixture.base},
            {"base": fixture.head},
            {"checkout": fixture.head},
        ]
        for arguments in cases:
            with self.subTest(arguments=arguments):
                result, outputs, _ = fixture.run(**arguments)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(outputs, {})
                self.assertIn("identity", result.stderr.lower())


class CIWorkflowRoutingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = (REPO / ".github/workflows/ci.yml").read_text(encoding="utf-8")
        cls.workflow = yaml.safe_load(cls.source)
        cls.jobs = cls.workflow["jobs"]

    def test_classifier_is_a_required_dependency_of_the_final_gate(self):
        self.assertIn("change-scope", self.jobs)
        self.assertIn("change-scope", self.jobs["build"]["needs"])
        command = self.jobs["change-scope"]["steps"][1]["run"]
        self.assertEqual(command, "python3 Scripts/classify-ci-change.py")

    def test_platform_producer_keeps_checkout_evidence_in_both_modes(self):
        platform = self.jobs["platform-validation"]
        self.assertEqual(platform["needs"], "change-scope")
        self.assertIn("full-validation", platform["runs-on"])
        checkout = platform["steps"][0]
        self.assertRegex(checkout["uses"], r"^actions/checkout@[0-9a-f]{40}$")
        self.assertEqual(checkout["with"]["fetch-depth"], 0)

    def test_required_contexts_fail_closed_over_both_modes(self):
        for name in ("compile", "test"):
            job = self.jobs[name]
            self.assertIn("change-scope", job["needs"])
            body = job["steps"][0]["run"]
            self.assertIn('"full"', body)
            self.assertIn('"roadmap-docs-only"', body)
            self.assertIn('"$DOCS_ONLY" = "success"', body)

    def test_no_broad_path_filter_can_bypass_the_classifier(self):
        self.assertNotIn("paths-ignore", self.source)
        self.assertNotIn("docs/**", self.source)


if __name__ == "__main__":
    unittest.main()
