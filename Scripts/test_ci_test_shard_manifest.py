#!/usr/bin/env python3
"""Regression tests for exact Swift test shard and xUnit manifests."""

import importlib.util
from pathlib import Path
import re
import subprocess
import sys
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
    def partition(self, entries, shards):
        inventory = self.write("inventory.txt", "".join(f"{entry}\n" for entry in entries))
        out = self.root / "out"
        manifest.partition_manifest(inventory, shards, out)
        return inventory, [manifest.shard_manifest_path(out, index) for index in range(shards)], out

    def lines(self, path):
        return path.read_text(encoding="utf-8").splitlines()

    def test_sorted_round_robin_is_exact_for_every_shard_count(self):
        entries = [f"M.Suite{suite}/t{number:02d}()" for suite in range(5) for number in range(7)]
        for shards in (1, 2, 3, 4, 6, 35):
            with self.subTest(shards=shards):
                self.root = Path(tempfile.mkdtemp(dir=self.temporary.name))
                inventory, paths, _ = self.partition(entries, shards)
                dealt = [self.lines(path) for path in paths]
                self.assertEqual(sorted(entry for shard in dealt for entry in shard), sorted(entries))
                self.assertEqual(dealt, [sorted(entries)[index::shards] for index in range(shards)])
                self.assertLessEqual(max(map(len, dealt)) - min(map(len, dealt)), 1)
                manifest.verify_union(inventory, paths)

    def test_one_long_suite_is_spread_over_every_shard(self):
        entries = [f"M.Long/t{number:03d}()" for number in range(40)] + ["M.Other/a()"]
        _, paths, _ = self.partition(entries, 4)
        for path in paths:
            self.assertTrue(any(line.startswith("M.Long/") for line in self.lines(path)))

    def test_assignment_does_not_depend_on_inventory_order(self):
        entries = ["M.B/a()", "M.A/b()", "M.A/a()", "M.C/a()"]
        _, forward, _ = self.partition(entries, 2)
        first = [self.lines(path) for path in forward]
        self.root = Path(tempfile.mkdtemp(dir=self.temporary.name))
        _, backward, _ = self.partition(list(reversed(entries)), 2)
        self.assertEqual(first, [self.lines(path) for path in backward])

    def test_fewer_tests_than_shards_and_bad_counts_are_refused(self):
        inventory = self.write("inventory.txt", "M.S/a()\nM.S/b()\n")
        with self.assertRaisesRegex(manifest.ManifestError, "fewer than 3 shards"):
            manifest.partition_manifest(inventory, 3, self.root / "out")
        with self.assertRaisesRegex(manifest.ManifestError, "at least 1"):
            manifest.partition_manifest(inventory, 0, self.root / "out-zero")

    def test_duplicate_inventory_entry_is_refused(self):
        inventory = self.write("inventory.txt", "Suite.Fast/a()\nSuite.Fast/a()\n")
        with self.assertRaisesRegex(manifest.ManifestError, "duplicate"):
            manifest.partition_manifest(inventory, 2, self.root / "out")

    def test_existing_manifest_is_never_replaced(self):
        entries = ["M.S/a()", "M.S/b()"]
        inventory, _, out = self.partition(entries, 2)
        with self.assertRaisesRegex(manifest.ManifestError, "refusing to replace"):
            manifest.partition_manifest(inventory, 2, out)

    def test_oversized_filter_is_refused_before_a_shard_could_fail_to_exec(self):
        inventory = self.write("inventory.txt", "".join(f"M.S/t{n:05d}()\n" for n in range(60)))
        original = manifest.MAX_FILTER_BYTES
        manifest.MAX_FILTER_BYTES = 100
        try:
            with self.assertRaisesRegex(manifest.ManifestError, "use more shards"):
                manifest.partition_manifest(inventory, 2, self.root / "out")
        finally:
            manifest.MAX_FILTER_BYTES = original

    def test_filter_matches_exactly_its_own_entries_and_no_other(self):
        entries = [
            "M.Suite/plain()", "M.Suite/param(_:)", "M.Suite/param(arguments:)",
            "M.Suite/Nested/deep()", "M.free_function()", "M.Class/test_snake_case",
            "M.SuiteTwo/plain()", "M.Other/a.b()",
        ]
        _, paths, out = self.partition(entries, 3)
        compiled = [re.compile(self.lines(manifest.shard_filter_path(out, index))[0])
                    for index in range(3)]
        for index, path in enumerate(paths):
            own = set(self.lines(path))
            for entry in entries:
                matches = [bool(pattern.search(entry)) for pattern in compiled]
                self.assertEqual(matches.count(True), 1, entry)
                self.assertEqual(matches[index], entry in own, entry)
        # Swift Testing identifiers carry a "/<file>:<line>:<column>" suffix when matched.
        for index, path in enumerate(paths):
            for entry in self.lines(path):
                self.assertTrue(compiled[index].search(entry + "/File.swift:12:3"), entry)
        # An identifier that merely contains or extends a member is not selected.
        for lookalike in ("M.Suite/plain()x", "xM.Suite/plain()", "M.Suite/plain", "M.SuiteX/plain()",
                          "M.Suite/paramX_:)"):
            self.assertFalse(any(pattern.search(lookalike) for pattern in compiled), lookalike)

    def test_filter_is_one_line_and_carries_no_shell_hostile_newline(self):
        _, _, out = self.partition(["M.S/a()", "M.S/b()"], 2)
        for index in range(2):
            self.assertEqual(len(self.lines(manifest.shard_filter_path(out, index))), 1)


class UnionTests(ManifestFixture):
    def shards(self, inventory_text, *shard_texts):
        inventory = self.write("inventory.txt", inventory_text)
        paths = [self.write(f"shard-{index}.txt", text) for index, text in enumerate(shard_texts)]
        return inventory, paths

    def test_exact_union_of_many_shards_is_accepted(self):
        inventory, paths = self.shards(
            "S/a()\nS/b()\nS/c()\nS/d()\n", "S/a()\nS/d()\n", "S/b()\n", "S/c()\n")
        manifest.verify_union(inventory, paths)

    def test_overlap_between_any_two_shards_is_refused(self):
        inventory, paths = self.shards(
            "S/a()\nS/b()\nS/c()\n", "S/a()\n", "S/b()\n", "S/b()\nS/c()\n")
        with self.assertRaisesRegex(manifest.ManifestError, "overlap"):
            manifest.verify_union(inventory, paths)

    def test_a_test_in_no_shard_is_refused(self):
        inventory, paths = self.shards(
            "S/a()\nS/b()\nS/c()\n", "S/a()\n", "S/b()\n", "S/b2()\n")
        with self.assertRaisesRegex(manifest.ManifestError, "union.*missing=.*S/c.*extra=.*S/b2"):
            manifest.verify_union(inventory, paths)

    def test_a_missing_shard_is_refused(self):
        inventory, paths = self.shards(
            "S/a()\nS/b()\nS/c()\n", "S/a()\n", "S/b()\n")
        with self.assertRaisesRegex(manifest.ManifestError, "missing="):
            manifest.verify_union(inventory, paths)

    def test_an_empty_or_unsorted_shard_and_no_shards_are_refused(self):
        inventory, paths = self.shards("S/a()\nS/b()\n", "S/a()\nS/b()\n", "")
        with self.assertRaisesRegex(manifest.ManifestError, "empty"):
            manifest.verify_union(inventory, paths)
        inventory, paths = self.shards("S/a()\nS/b()\n", "S/b()\nS/a()\n")
        with self.assertRaisesRegex(manifest.ManifestError, "not byte-sorted"):
            manifest.verify_union(inventory, paths)
        with self.assertRaisesRegex(manifest.ManifestError, "no shard manifests"):
            manifest.verify_union(inventory, [])

    def test_command_line_deals_and_verifies_the_same_shards(self):
        inventory = self.write("inventory.txt", "S/a()\nS/b()\nS/c()\nS/d()\nS/e()\n")
        out = self.root / "cli"
        script = str(SCRIPT)
        subprocess.run([sys.executable, script, "partition", "--inventory", str(inventory),
                        "--shards", "3", "--output-directory", str(out)], check=True)
        shard_args = [arg for index in range(3)
                      for arg in ("--shard", str(manifest.shard_manifest_path(out, index)))]
        subprocess.run([sys.executable, script, "verify-union", "--inventory", str(inventory),
                        *shard_args], check=True)
        manifest.shard_manifest_path(out, 2).write_text("S/zz()\n", encoding="utf-8")
        failed = subprocess.run([sys.executable, script, "verify-union", "--inventory",
                                 str(inventory), *shard_args], capture_output=True, text=True)
        self.assertEqual(failed.returncode, 1)
        self.assertIn("shard union differs from inventory", failed.stderr)


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

    def test_top_level_dot_shape_is_resolved(self):
        expected = self.write(
            "expected.txt",
            "LogicProMCPTests.Issue497AmbiguousTargetReferenceTerminatesWithoutHumanRoute()\n")
        self.xunit(
            '<testcase classname="LogicProMCPTests" '
            'name="Issue497AmbiguousTargetReferenceTerminatesWithoutHumanRoute()" />')
        actual = self.root / "actual.txt"

        manifest.verify_xunit(expected, self.root / "xunit", actual)

        self.assertEqual(actual.read_text(encoding="utf-8"), expected.read_text(encoding="utf-8"))

    def test_nested_suite_mixed_dot_and_slash_shape_is_resolved(self):
        expected = self.write(
            "expected.txt",
            "LogicProMCPTests.OperationTraceTests/FeatureFlagEnvironmentTests/"
            "operationTraceDefaultsToOn()\n")
        self.xunit(
            '<testcase '
            'classname="LogicProMCPTests.OperationTraceTests.FeatureFlagEnvironmentTests" '
            'name="operationTraceDefaultsToOn()" />')
        actual = self.root / "actual.txt"

        manifest.verify_xunit(expected, self.root / "xunit", actual)

        self.assertEqual(actual.read_text(encoding="utf-8"), expected.read_text(encoding="utf-8"))

    def test_unexpected_testcase_is_refused(self):
        expected = self.write("expected.txt", "LogicProMCPTests.Suite/expected()\n")
        self.xunit('<testcase classname="LogicProMCPTests.Suite" name="unexpected()" />')

        with self.assertRaisesRegex(manifest.ManifestError, "unexpected xUnit testcase"):
            manifest.verify_xunit(expected, self.root / "xunit", self.root / "actual.txt")

    def test_expected_entries_with_same_canonical_xunit_key_are_refused(self):
        expected = self.write(
            "expected.txt",
            "LogicProMCPTests.Suite/test()\n"
            "LogicProMCPTests/Suite/test()\n")
        self.xunit('<testcase classname="LogicProMCPTests.Suite" name="test()" />')

        with self.assertRaisesRegex(manifest.ManifestError, "canonical xUnit key collision"):
            manifest.verify_xunit(expected, self.root / "xunit", self.root / "actual.txt")

    def test_duplicate_testcase_is_refused(self):
        expected = self.write("expected.txt", "LogicProMCPTests.Suite/a()\n")
        self.xunit(
            '<testcase classname="LogicProMCPTests.Suite" name="a()" />'
            '<testcase classname="LogicProMCPTests.Suite" name="a()" />')
        with self.assertRaisesRegex(manifest.ManifestError, "duplicate xUnit testcase key"):
            manifest.verify_xunit(expected, self.root / "xunit", self.root / "actual.txt")

    def test_missing_expected_testcase_is_refused(self):
        expected = self.write(
            "expected.txt",
            "LogicProMCPTests.Suite/a()\n"
            "LogicProMCPTests.Suite/b()\n")
        self.xunit('<testcase classname="LogicProMCPTests.Suite" name="a()" />')

        with self.assertRaisesRegex(manifest.ManifestError, "missing=.*Suite/b"):
            manifest.verify_xunit(expected, self.root / "xunit", self.root / "actual.txt")

    def test_expected_manifest_must_be_sorted_and_unique(self):
        cases = (
            ("unsorted", "LogicProMCPTests.Suite/b()\nLogicProMCPTests.Suite/a()\n",
             "not byte-sorted"),
            ("duplicate", "LogicProMCPTests.Suite/a()\nLogicProMCPTests.Suite/a()\n",
             "duplicate entry"),
        )
        for suffix, contents, message in cases:
            with self.subTest(suffix=suffix):
                expected = self.write(f"expected-{suffix}.txt", contents)
                with self.assertRaisesRegex(manifest.ManifestError, message):
                    manifest.verify_xunit(
                        expected, self.root / "unused-xunit", self.root / f"actual-{suffix}.txt")

    def test_malformed_expected_manifest_entry_is_refused(self):
        expected = self.write("expected.txt", "MalformedEntry()\n")

        with self.assertRaisesRegex(manifest.ManifestError, "malformed expected manifest entry"):
            manifest.verify_xunit(
                expected, self.root / "unused-xunit", self.root / "actual.txt")

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

    def test_xunit_with_no_testcases_is_refused(self):
        expected = self.write("expected.txt", "LogicProMCPTests.Suite/a()\n")
        self.xunit("")

        with self.assertRaisesRegex(manifest.ManifestError, "xUnit contains no testcases"):
            manifest.verify_xunit(expected, self.root / "xunit", self.root / "actual.txt")


if __name__ == "__main__":
    unittest.main()
