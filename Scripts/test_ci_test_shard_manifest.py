#!/usr/bin/env python3
"""Regression tests for exact Swift test shard and xUnit manifests."""

import importlib.util
from pathlib import Path
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("ci-test-shard-manifest.py")
SPEC = importlib.util.spec_from_file_location("ci_test_shard_manifest", SCRIPT)
manifest = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(manifest)


class ManifestFixture(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)

    def tearDown(self):
        self.temporary.cleanup()

    def write(self, name: str, contents: str) -> Path:
        path = self.root / name
        path.write_text(contents, encoding="utf-8")
        return path


class PartitionTests(ManifestFixture):
    def test_partition_is_nonempty_disjoint_and_complete(self):
        inventory = self.write("inventory.txt", "Suite.Slow/b()\nSuite.Fast/a()\nSuite.Slow/a()\n")
        selected = self.root / "selected.txt"
        complement = self.root / "complement.txt"

        manifest.partition_manifest(inventory, r"^Suite\.Slow/", selected, complement)

        self.assertEqual(selected.read_text(encoding="utf-8"),
                         "Suite.Slow/a()\nSuite.Slow/b()\n")
        self.assertEqual(complement.read_text(encoding="utf-8"), "Suite.Fast/a()\n")
        manifest.verify_union(inventory, selected, complement)

    def test_selector_typo_that_matches_nothing_is_refused(self):
        inventory = self.write("inventory.txt", "Suite.Fast/a()\nSuite.Slow/a()\n")
        with self.assertRaisesRegex(manifest.ManifestError, "selected shard is empty"):
            manifest.partition_manifest(
                inventory, r"^Suite\.Slwo/", self.root / "selected.txt",
                self.root / "complement.txt")

    def test_duplicate_inventory_entry_is_refused(self):
        inventory = self.write("inventory.txt", "Suite.Fast/a()\nSuite.Fast/a()\n")
        with self.assertRaisesRegex(manifest.ManifestError, "duplicate"):
            manifest.partition_manifest(
                inventory, r"Fast", self.root / "selected.txt",
                self.root / "complement.txt")

    def test_union_refuses_overlap_and_gap(self):
        inventory = self.write("inventory.txt", "Suite/a()\nSuite/b()\nSuite/c()\n")
        selected = self.write("selected.txt", "Suite/a()\nSuite/b()\n")
        overlap = self.write("overlap.txt", "Suite/b()\nSuite/c()\n")
        with self.assertRaisesRegex(manifest.ManifestError, "overlap"):
            manifest.verify_union(inventory, selected, overlap)

        gap = self.write("gap.txt", "Suite/c()\n")
        selected.write_text("Suite/a()\n", encoding="utf-8")
        with self.assertRaisesRegex(manifest.ManifestError, "union"):
            manifest.verify_union(inventory, selected, gap)


class XUnitTests(ManifestFixture):
    def xunit(self, cases: str, name: str = "results.xml") -> Path:
        directory = self.root / "xunit"
        directory.mkdir(exist_ok=True)
        return self.write(
            f"xunit/{name}",
            '<?xml version="1.0"?><testsuites><testsuite>' + cases
            + "</testsuite></testsuites>")

    def test_exact_parameterized_and_skipped_shapes_are_accepted(self):
        expected = self.write(
            "expected.txt",
            "LogicProMCPTests.Suite/parameterized(arguments:)\n"
            "LogicProMCPTests.Suite/skipped()\n")
        self.xunit(
            '<testcase classname="LogicProMCPTests.Suite" '
            'name="parameterized(arguments:)" />'
            '<testcase classname="LogicProMCPTests.Suite" name="skipped()">'
            '<skipped /></testcase>', name="results-swift-testing.xml")
        actual = self.root / "actual.txt"

        manifest.verify_xunit(expected, self.root / "xunit", actual)

        self.assertEqual(actual.read_text(encoding="utf-8"), expected.read_text(encoding="utf-8"))

    def test_duplicate_testcase_is_refused(self):
        expected = self.write("expected.txt", "LogicProMCPTests.Suite/a()\n")
        self.xunit(
            '<testcase classname="LogicProMCPTests.Suite" name="a()" />'
            '<testcase classname="LogicProMCPTests.Suite" name="a()" />')
        with self.assertRaisesRegex(manifest.ManifestError, "duplicate"):
            manifest.verify_xunit(expected, self.root / "xunit", self.root / "actual.txt")

    def test_missing_extra_failure_and_error_are_refused(self):
        expected = self.write("expected.txt", "LogicProMCPTests.Suite/a()\n")
        for suffix, child in (
            ("missing", '<testcase classname="LogicProMCPTests.Suite" name="b()" />'),
            ("failure", '<testcase classname="LogicProMCPTests.Suite" name="a()"><failure /></testcase>'),
            ("error", '<testcase classname="LogicProMCPTests.Suite" name="a()"><error /></testcase>'),
        ):
            with self.subTest(suffix=suffix):
                xunit_dir = self.root / suffix
                xunit_dir.mkdir()
                (xunit_dir / "results.xml").write_text(
                    f"<testsuites><testsuite>{child}</testsuite></testsuites>", encoding="utf-8")
                with self.assertRaises(manifest.ManifestError):
                    manifest.verify_xunit(expected, xunit_dir, self.root / f"actual-{suffix}.txt")

    def test_missing_or_ambiguous_xunit_output_is_refused(self):
        expected = self.write("expected.txt", "LogicProMCPTests.Suite/a()\n")
        empty = self.root / "empty"
        empty.mkdir()
        with self.assertRaisesRegex(manifest.ManifestError, "exactly one"):
            manifest.verify_xunit(expected, empty, self.root / "actual.txt")

        self.xunit('<testcase classname="LogicProMCPTests.Suite" name="a()" />')
        self.write("xunit/results-swift-testing.xml", "<testsuites />")
        with self.assertRaisesRegex(manifest.ManifestError, "exactly one"):
            manifest.verify_xunit(expected, self.root / "xunit", self.root / "actual-2.txt")


if __name__ == "__main__":
    unittest.main()
