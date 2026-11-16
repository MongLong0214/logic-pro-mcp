#!/usr/bin/env python3
"""Regression tests for exact Swift test shard and xUnit manifests."""

import importlib.util
from pathlib import Path
import re
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
    INVENTORY = (
        "LogicProMCPTests.Fast/a()\n"
        "LogicProMCPTests.Fast/b()\n"
        "LogicProMCPTests.Outer/Inner/c()\n"
        "LogicProMCPTests.Slow/heavy(mode:)\n"
        "LogicProMCPTests.Slow/heavier()\n"
        "LogicProMCPTests.TopLevel()\n"
    )

    def partition(self, count: int, weights: str = "", inventory: str = INVENTORY,
                  directory: str = "shards") -> list[Path]:
        inventory_path = self.write("inventory.txt", inventory)
        weights_path = self.write("weights.tsv", weights)
        output = self.root / directory
        manifest.partition_manifest(inventory_path, weights_path, count, output)
        return [manifest.shard_path(output, index) for index in range(1, count + 1)]

    def lines(self, path: Path) -> list[str]:
        return path.read_text(encoding="utf-8").splitlines()

    def test_every_test_lands_in_exactly_one_nonempty_sorted_shard(self):
        for count in (1, 2, 3, 6):
            with self.subTest(count=count):
                shards = self.partition(count, directory=f"shards-{count}")
                entries = [entry for shard in shards for entry in self.lines(shard)]
                self.assertEqual(sorted(entries), sorted(self.INVENTORY.splitlines()))
                self.assertEqual(len(entries), len(set(entries)))
                for shard in shards:
                    self.assertTrue(self.lines(shard))
                    self.assertEqual(self.lines(shard), sorted(self.lines(shard)))

    def test_partition_depends_on_contents_not_on_inventory_order(self):
        weights = "30\tLogicProMCPTests.Slow/heavy(mode:)\n"
        first = [self.lines(path) for path in self.partition(3, weights, directory="a")]
        reversed_inventory = "\n".join(reversed(self.INVENTORY.splitlines())) + "\n"
        second = [self.lines(path) for path in
                  self.partition(3, weights, reversed_inventory, directory="b")]
        self.assertEqual(first, second)

    def test_the_slowest_tests_are_spread_across_shards(self):
        weights = ("# measured\n"
                   "50\tLogicProMCPTests.Slow/heavy(mode:)\n"
                   "40\tLogicProMCPTests.Slow/heavier()\n"
                   "9\tLogicProMCPTests.Retired/gone()\n")
        shards = [self.lines(path) for path in self.partition(2, weights)]
        self.assertIn("LogicProMCPTests.Slow/heavy(mode:)", shards[0])
        self.assertIn("LogicProMCPTests.Slow/heavier()", shards[1])
        self.assertNotIn("LogicProMCPTests.Retired/gone()", shards[0] + shards[1])

    def test_more_shards_than_tests_is_refused(self):
        with self.assertRaisesRegex(manifest.ManifestError, "shard 7 of 7 is empty"):
            self.partition(7)

    def test_malformed_or_duplicate_weights_are_refused(self):
        for suffix, weights, message in (
            ("no-tab", "30 LogicProMCPTests.Fast/a()\n", "malformed shard weight"),
            ("not-a-number", "slow\tLogicProMCPTests.Fast/a()\n", "malformed shard weight"),
            ("negative", "-1\tLogicProMCPTests.Fast/a()\n", "non-negative"),
            ("nan", "nan\tLogicProMCPTests.Fast/a()\n", "non-negative"),
            ("duplicate", "1\tLogicProMCPTests.Fast/a()\n2\tLogicProMCPTests.Fast/a()\n",
             "duplicate shard weight"),
        ):
            with self.subTest(suffix=suffix):
                with self.assertRaisesRegex(manifest.ManifestError, message):
                    self.partition(2, weights, directory=suffix)

    def test_duplicate_inventory_entry_is_refused(self):
        with self.assertRaisesRegex(manifest.ManifestError, "duplicate"):
            self.partition(2, inventory="Suite.Fast/a()\nSuite.Fast/a()\n")

    def test_existing_manifest_is_never_replaced(self):
        self.partition(2)
        with self.assertRaisesRegex(manifest.ManifestError, "refusing to replace"):
            self.partition(2)


class UnionTests(ManifestFixture):
    def setUp(self):
        super().setUp()
        self.inventory = self.write("inventory.txt", "Suite/a()\nSuite/b()\nSuite/c()\nSuite/d()\n")

    def shards(self, *contents: str) -> list[Path]:
        return [self.write(f"actual-shard-{index}.txt", text)
                for index, text in enumerate(contents, 1)]

    def test_exact_union_of_n_shards_is_accepted(self):
        manifest.verify_union(
            self.inventory, self.shards("Suite/a()\n", "Suite/b()\nSuite/d()\n", "Suite/c()\n"), 3)

    def test_a_dropped_test_is_refused(self):
        shards = self.shards("Suite/a()\n", "Suite/b()\nSuite/d()\n", "Suite/c()\n")
        shards[1].write_text("Suite/b()\n", encoding="utf-8")
        with self.assertRaisesRegex(manifest.ManifestError, r"missing=\['Suite/d\(\)'\]"):
            manifest.verify_union(self.inventory, shards, 3)

    def test_a_test_run_by_two_shards_is_refused(self):
        shards = self.shards("Suite/a()\nSuite/c()\n", "Suite/b()\nSuite/d()\n", "Suite/c()\n")
        with self.assertRaisesRegex(manifest.ManifestError, r"overlap: Suite/c\(\)"):
            manifest.verify_union(self.inventory, shards, 3)

    def test_a_test_outside_the_inventory_is_refused(self):
        shards = self.shards("Suite/a()\nSuite/b()\n", "Suite/c()\nSuite/d()\nSuite/e()\n")
        with self.assertRaisesRegex(manifest.ManifestError, r"extra=\['Suite/e\(\)'\]"):
            manifest.verify_union(self.inventory, shards, 2)

    def test_a_missing_or_repeated_shard_is_refused(self):
        shards = self.shards("Suite/a()\nSuite/b()\n", "Suite/c()\nSuite/d()\n")
        with self.assertRaisesRegex(manifest.ManifestError, "expected 3 shard manifests, got 2"):
            manifest.verify_union(self.inventory, shards, 3)
        with self.assertRaisesRegex(manifest.ManifestError, "given twice"):
            manifest.verify_union(self.inventory, [shards[0], shards[0]], 2)

    def test_an_empty_or_unsorted_shard_is_refused(self):
        for suffix, text, message in (
            ("empty", "", "is empty"),
            ("unsorted", "Suite/d()\nSuite/c()\n", "not byte-sorted"),
        ):
            with self.subTest(suffix=suffix):
                first = self.write(f"first-{suffix}.txt", "Suite/a()\nSuite/b()\n")
                second = self.write(f"second-{suffix}.txt", text)
                with self.assertRaisesRegex(manifest.ManifestError, message):
                    manifest.verify_union(self.inventory, [first, second], 2)


class FilterPatternTests(ManifestFixture):
    IDS = {
        # Swift Testing matches the expression against a test's ID, which is the listed name
        # plus `/<file>:<line>:<column>`, and also against every suite's ID.
        "LogicProMCPTests.Suite/a()": "LogicProMCPTests.Suite/a()/SuiteTests.swift:4:3",
        "LogicProMCPTests.Suite/ab()": "LogicProMCPTests.Suite/ab()/SuiteTests.swift:8:3",
        "LogicProMCPTests.Suite/p(mode:)": "LogicProMCPTests.Suite/p(mode:)/SuiteTests.swift:9:3",
        "LogicProMCPTests.Outer/Inner/c()": "LogicProMCPTests.Outer/Inner/c()/OuterTests.swift:2:5",
        "LogicProMCPTests.TopLevel()": "LogicProMCPTests.TopLevel()/TopLevelTests.swift:1:1",
        "LogicProMCPTests.SuiteTwo/a()": "LogicProMCPTests.SuiteTwo/a()/SuiteTwoTests.swift:3:3",
        # Overloads share a name, so `swift test list` prints each with its source location.
        "LogicProMCPTests.Over/f()/OverTests.swift:1:2": "LogicProMCPTests.Over/f()/OverTests.swift:1:2",
        "LogicProMCPTests.Over/f()/OverTests.swift:1:20": "LogicProMCPTests.Over/f()/OverTests.swift:1:20",
        # Another module whose name ends in this one's.
        "AppLogicProMCPTests.Suite/a()": "AppLogicProMCPTests.Suite/a()/SuiteTests.swift:4:3",
    }
    SUITES = ("LogicProMCPTests.Suite", "LogicProMCPTests.Outer", "LogicProMCPTests.Outer/Inner",
              "LogicProMCPTests.SuiteTwo", "LogicProMCPTests.Over")

    def selected(self, listed: list[str]) -> set[str]:
        path = self.write("shard.txt", "".join(f"{entry}\n" for entry in sorted(listed)))
        expression = re.compile(manifest.filter_pattern(path))
        for suite in self.SUITES:
            self.assertIsNone(expression.search(suite), f"{suite} would select its whole suite")
        return {name for name, test_id in self.IDS.items() if expression.search(test_id)}

    def test_selects_exactly_the_listed_tests(self):
        for listed in (
            ["LogicProMCPTests.Suite/a()"],
            ["LogicProMCPTests.Suite/p(mode:)", "LogicProMCPTests.Outer/Inner/c()"],
            ["LogicProMCPTests.TopLevel()", "LogicProMCPTests.SuiteTwo/a()"],
            ["LogicProMCPTests.Over/f()/OverTests.swift:1:2"],
            list(self.IDS),
        ):
            with self.subTest(listed=listed):
                self.assertEqual(self.selected(listed), set(listed))

    def test_regex_metacharacters_in_names_are_literal(self):
        path = self.write("shard.txt", "LogicProMCPTests.S/x(a:b:)\n")
        expression = re.compile(manifest.filter_pattern(path))
        self.assertIsNotNone(expression.search("LogicProMCPTests.S/x(a:b:)/S.swift:1:1"))
        self.assertIsNone(expression.search("LogicProMCPTestsXS/x(a:b:)/S.swift:1:1"))


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
