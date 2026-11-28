#!/usr/bin/env python3
"""Regression tests for exact Swift test shard and xUnit manifests."""

import importlib.util
import json
import os
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
        listed = self.write("not-run.json", json.dumps({"tests": [
            {"id": "S/a()", "class": "live", "lane": "release", "reason": "fixture"}]}))
        shard_args = [arg for index in range(3)
                      for arg in ("--shard", str(manifest.shard_manifest_path(out, index)))]
        shard_args += ["--not-run", str(listed)]
        subprocess.run([sys.executable, script, "verify-union", "--inventory", str(inventory),
                        *shard_args], check=True)
        manifest.shard_manifest_path(out, 2).write_text("S/zz()\n", encoding="utf-8")
        failed = subprocess.run([sys.executable, script, "verify-union", "--inventory",
                                 str(inventory), *shard_args], capture_output=True, text=True)
        self.assertEqual(failed.returncode, 1)
        self.assertIn("shard union differs from inventory", failed.stderr)


def not_run_document(*rows):
    """Rows are (id, class) or (id, "live", lane); a live row without a lane gets "release"."""
    tests = []
    for row in rows:
        entry = {"id": row[0], "class": row[1], "reason": "fixture"}
        if row[1] == "live":
            entry["lane"] = row[2] if len(row) > 2 else "release"
        tests.append(entry)
    return json.dumps({"tests": tests})


class XUnitFixture(ManifestFixture):
    def verify_xunit(self, expected, directory, actual, not_run=()):
        listed = self.write("not-run.json", not_run_document(*not_run))
        manifest.verify_xunit(expected, directory, actual, listed)

    def xunit(self, cases: str, name: str = "results.xml") -> Path:
        directory = self.root / "xunit"
        directory.mkdir(exist_ok=True)
        return self.write(
            f"xunit/{name}",
            '<?xml version="1.0"?><testsuites><testsuite>' + cases
            + "</testsuite></testsuites>")


class XUnitTests(XUnitFixture):
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

        self.verify_xunit(expected, self.root / "xunit", actual,
                          not_run=[("LogicProMCPTests.Suite/skipped()", "operator")])

        self.assertEqual(actual.read_text(encoding="utf-8"), expected.read_text(encoding="utf-8"))

    def test_top_level_dot_shape_is_resolved(self):
        expected = self.write(
            "expected.txt",
            "LogicProMCPTests.Issue497AmbiguousTargetReferenceTerminatesWithoutHumanRoute()\n")
        self.xunit(
            '<testcase classname="LogicProMCPTests" '
            'name="Issue497AmbiguousTargetReferenceTerminatesWithoutHumanRoute()" />')
        actual = self.root / "actual.txt"

        self.verify_xunit(expected, self.root / "xunit", actual)

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

        self.verify_xunit(expected, self.root / "xunit", actual)

        self.assertEqual(actual.read_text(encoding="utf-8"), expected.read_text(encoding="utf-8"))

    def test_unexpected_testcase_is_refused(self):
        expected = self.write("expected.txt", "LogicProMCPTests.Suite/expected()\n")
        self.xunit('<testcase classname="LogicProMCPTests.Suite" name="unexpected()" />')

        with self.assertRaisesRegex(manifest.ManifestError, "unexpected xUnit testcase"):
            self.verify_xunit(expected, self.root / "xunit", self.root / "actual.txt")

    def test_expected_entries_with_same_canonical_xunit_key_are_refused(self):
        expected = self.write(
            "expected.txt",
            "LogicProMCPTests.Suite/test()\n"
            "LogicProMCPTests/Suite/test()\n")
        self.xunit('<testcase classname="LogicProMCPTests.Suite" name="test()" />')

        with self.assertRaisesRegex(manifest.ManifestError, "canonical xUnit key collision"):
            self.verify_xunit(expected, self.root / "xunit", self.root / "actual.txt")

    def test_duplicate_testcase_is_refused(self):
        expected = self.write("expected.txt", "LogicProMCPTests.Suite/a()\n")
        self.xunit(
            '<testcase classname="LogicProMCPTests.Suite" name="a()" />'
            '<testcase classname="LogicProMCPTests.Suite" name="a()" />')
        with self.assertRaisesRegex(manifest.ManifestError, "duplicate xUnit testcase key"):
            self.verify_xunit(expected, self.root / "xunit", self.root / "actual.txt")

    def test_missing_expected_testcase_is_refused(self):
        expected = self.write(
            "expected.txt",
            "LogicProMCPTests.Suite/a()\n"
            "LogicProMCPTests.Suite/b()\n")
        self.xunit('<testcase classname="LogicProMCPTests.Suite" name="a()" />')

        with self.assertRaisesRegex(manifest.ManifestError, "missing=.*Suite/b"):
            self.verify_xunit(expected, self.root / "xunit", self.root / "actual.txt")

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
                    self.verify_xunit(
                        expected, self.root / "unused-xunit", self.root / f"actual-{suffix}.txt")

    def test_malformed_expected_manifest_entry_is_refused(self):
        expected = self.write("expected.txt", "MalformedEntry()\n")

        with self.assertRaisesRegex(manifest.ManifestError, "malformed expected manifest entry"):
            self.verify_xunit(
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
                    self.verify_xunit(expected, xunit_dir, self.root / f"actual-{suffix}.txt")

    def test_missing_or_ambiguous_xunit_output_is_refused(self):
        expected = self.write("expected.txt", "LogicProMCPTests.Suite/a()\n")
        empty = self.root / "empty"
        empty.mkdir()
        with self.assertRaisesRegex(manifest.ManifestError, "exactly one"):
            self.verify_xunit(expected, empty, self.root / "actual.txt")

        self.xunit('<testcase classname="LogicProMCPTests.Suite" name="a()" />')
        self.write("xunit/results-swift-testing.xml", "<testsuites />")
        with self.assertRaisesRegex(manifest.ManifestError, "exactly one"):
            self.verify_xunit(expected, self.root / "xunit", self.root / "actual-2.txt")

    def test_xunit_with_no_testcases_is_refused(self):
        expected = self.write("expected.txt", "LogicProMCPTests.Suite/a()\n")
        self.xunit("")

        with self.assertRaisesRegex(manifest.ManifestError, "xUnit contains no testcases"):
            self.verify_xunit(expected, self.root / "xunit", self.root / "actual.txt")


class HostedNotRunRuleTests(XUnitFixture):
    """The hosted rule: a skipped testcase must be listed, and a listed test must be skipped."""

    SUITE = "LogicProMCPTests.Suite"
    RAN = f'<testcase classname="{SUITE}" name="ran()" />'
    SKIPPED = f'<testcase classname="{SUITE}" name="gated()"><skipped>no Logic</skipped></testcase>'

    def expected(self, *names):
        return self.write("expected.txt", "".join(f"{self.SUITE}/{name}()\n" for name in sorted(names)))

    def test_a_skip_that_is_not_listed_fails_whatever_its_condition_looks_like(self):
        # The hosted verifier sees only the result, so a closure condition, a suite-level trait or a
        # condition behind a constant all arrive here as the same skipped testcase.
        self.xunit(self.RAN + self.SKIPPED)
        with self.assertRaisesRegex(manifest.ManifestError, "skipped but is not in the not-run list.*gated"):
            self.verify_xunit(self.expected("ran", "gated"), self.root / "xunit",
                              self.root / "actual.txt")

    def test_a_listed_skip_passes_in_every_class(self):
        self.xunit(self.RAN + self.SKIPPED)
        for kind in manifest.NOT_RUN_CLASSES:
            with self.subTest(kind=kind):
                self.verify_xunit(self.expected("ran", "gated"), self.root / "xunit",
                                  self.root / f"actual-{kind}.txt",
                                  not_run=[(f"{self.SUITE}/gated()", kind)])

    def test_an_entry_of_any_class_that_is_not_skipped_is_stale(self):
        # The reviewer's relabel: a test that runs on the hosted lane is called `operator`, which
        # would exempt it from the Logic host as well. It was never skipped, so the entry is stale.
        self.xunit(self.RAN + self.SKIPPED)
        for kind in manifest.NOT_RUN_CLASSES:
            with self.subTest(kind=kind):
                with self.assertRaisesRegex(manifest.ManifestError, "stale.*ran"):
                    self.verify_xunit(self.expected("ran", "gated"), self.root / "xunit",
                                      self.root / f"actual-{kind}.txt",
                                      not_run=[(f"{self.SUITE}/gated()", kind),
                                               (f"{self.SUITE}/ran()", kind)])

    def test_an_ordinary_test_added_as_logic_host_is_refused_because_it_is_not_skipped(self):
        self.xunit(self.RAN)
        with self.assertRaisesRegex(manifest.ManifestError, "stale"):
            self.verify_xunit(self.expected("ran"), self.root / "xunit", self.root / "actual.txt",
                              not_run=[(f"{self.SUITE}/ran()", "logic_host")])

    def test_an_entry_for_a_test_in_another_shard_is_not_judged_here(self):
        self.xunit(self.RAN)
        self.verify_xunit(self.expected("ran"), self.root / "xunit", self.root / "actual.txt",
                          not_run=[(f"{self.SUITE}/elsewhere()", "logic_host")])

    def test_removing_the_entry_of_a_skipped_test_fails(self):
        self.xunit(self.SKIPPED)
        with self.assertRaisesRegex(manifest.ManifestError, "not in the not-run list"):
            self.verify_xunit(self.expected("gated"), self.root / "xunit", self.root / "actual.txt")

    def test_the_list_must_be_well_formed(self):
        bad = {
            "not json": "{",
            "no tests key": "{}",
            "extra key": json.dumps({"tests": [], "more": 1}),
            "unknown class": not_run_document((f"{self.SUITE}/gated()", "somewhere")),
            "duplicate": not_run_document((f"{self.SUITE}/gated()", "live"), (f"{self.SUITE}/gated()", "live")),
            "blank reason": json.dumps({"tests": [
                {"id": "a", "class": "live", "lane": "release", "reason": " "}]}),
            "multiline reason": json.dumps({"tests": [
                {"id": "a", "class": "live", "lane": "release", "reason": "a\nb"}]}),
            "missing reason": json.dumps({"tests": [{"id": "a", "class": "live", "lane": "release"}]}),
            "live with no owning lane": json.dumps({"tests": [
                {"id": "a", "class": "live", "reason": "r"}]}),
            "live with an unknown lane": json.dumps({"tests": [
                {"id": "a", "class": "live", "lane": "nowhere", "reason": "r"}]}),
            "lane on a class that has none": json.dumps({"tests": [
                {"id": "a", "class": "operator", "lane": "release", "reason": "r"}]}),
        }
        for label, text in bad.items():
            with self.subTest(label):
                with self.assertRaises(manifest.ManifestError):
                    manifest.read_not_run(self.write("bad.json", text))

    def test_an_entry_absent_from_the_inventory_is_refused(self):
        inventory = self.write("inventory.txt", f"{self.SUITE}/ran()\n")
        listed = self.write("listed.json", not_run_document((f"{self.SUITE}/typo()", "logic_host")))
        with self.assertRaisesRegex(manifest.ManifestError, "absent from the inventory.*typo"):
            manifest.verify_not_run_in_inventory(inventory, listed)
        listed = self.write("ok.json", not_run_document((f"{self.SUITE}/ran()", "logic_host")))
        manifest.verify_not_run_in_inventory(inventory, listed)

    def test_the_checked_in_list_is_well_formed_and_names_these_exact_tests(self):
        # Identities, not counts: swapping one test for another keeps every count, so the exempted
        # tests are named here, and a change to this set is a visible change to review.
        path = Path(__file__).resolve().parents[1] / "Tests" / "not-run-on-hosted.json"
        entries = manifest.read_not_run(path)
        listed = {test_id: (entry.kind, entry.lane) for test_id, entry in entries.items()}
        self.assertEqual(listed, {
            "LogicProMCPTests.Issue965HeldSelectionAssociationTests/nativeMixerScrollToRetainsItsObservedOwners()":
                ("operator", None),
            "LogicProMCPTests.LibraryDiskScannerTests/installedLibraryEmitsOnlyPanelCategories()":
                ("logic_host", None),
            "LogicProMCPTests.LibraryDiskScannerTests/scanLocalFactoryLibraryReportsFullCoverage()":
                ("logic_host", None),
            "LogicProMCPTests.QualificationRunnerTests/realReleaseBinaryExecutesEveryOperationWithIndependentReadback()":
                ("live", "release"),
            "LogicProMCPTests.QualificationRunnerTests/runnerIgnoresPartialStateFaultEnvOnRealServer()":
                ("live", "release"),
            "LogicProMCPTests.QualificationRunnerTests/runnerRejectsPartialStateObservedFromRealServer()":
                ("live", "debug"),
            "LogicProMCPTests.StockPluginFactoryPresetTests/hostFactorySettingsFoldersAreAccountedFor()":
                ("logic_host", None),
            "LogicProMCPTests.testProcessUtilsBundleURLResolvesWithoutAppKitRunloop()":
                ("logic_host", None),
            "LogicProMCPTests.testProcessUtilsLogicProVersionResolvesOffMain()":
                ("logic_host", None),
        })
        self.assertEqual(
            {test_id for test_id, entry in entries.items() if entry.kind == "operator"},
            set(manifest.BOOTSTRAP_OPERATOR_IDS))


class TrustedOperatorTests(ManifestFixture):
    """HOST-04: an `operator` exemption exists only where the trusted copy already has it."""

    VERSION = "LogicProMCPTests.testProcessUtilsLogicProVersionResolvesOffMain()"
    OWNED = "LogicProMCPTests.Operator/needsProject()"
    PLAIN = "LogicProMCPTests.Suite/plain()"

    def verify(self, candidate_rows, trusted_rows):
        candidate = self.write("candidate.json", not_run_document(*candidate_rows))
        trusted = self.root / "trusted.json"
        if trusted_rows is not None:
            trusted.write_text(not_run_document(*trusted_rows), encoding="utf-8")
        manifest.verify_trusted_operator(candidate, trusted)

    def test_an_operator_entry_the_trusted_copy_has_is_accepted(self):
        self.verify([(self.OWNED, "operator"), (self.VERSION, "logic_host")],
                    [(self.OWNED, "operator"), (self.VERSION, "logic_host")])

    def test_dropping_an_operator_entry_is_accepted(self):
        self.verify([(self.VERSION, "logic_host")], [(self.OWNED, "operator")])

    def test_a_new_operator_entry_is_refused(self):
        with self.assertRaisesRegex(manifest.ManifestError, "trusted not-run list does not have.*needsProject"):
            self.verify([(self.OWNED, "operator")], [(self.VERSION, "logic_host")])

    def test_the_reviewers_count_preserving_swap_is_refused_on_both_sides(self):
        # Trusted: one operator test and a logic_host version check. The candidate swaps which
        # test is the operator one: the class counts are unchanged.
        trusted = [(self.OWNED, "operator"), (self.VERSION, "logic_host")]
        swapped = [(self.OWNED, "logic_host"), (self.VERSION, "operator")]
        self.assertEqual(sorted(kind for _, kind in swapped), sorted(kind for _, kind in trusted))
        # Native side: the trusted copy has no operator entry for the version check.
        with self.assertRaisesRegex(manifest.ManifestError, "does not have.*testProcessUtils"):
            self.verify(swapped, trusted)
        # Hosted side: the version check is not skipped there, so calling it operator is stale.
        directory = self.root / "xunit"
        directory.mkdir()
        (directory / "results.xml").write_text(
            "<testsuites><testsuite>"
            + testcase(self.VERSION) + testcase(self.OWNED, "<skipped />")
            + "</testsuite></testsuites>", encoding="utf-8")
        expected = self.write("expected.txt", "".join(f"{entry}\n" for entry in sorted((self.OWNED, self.VERSION))))
        listed = self.write("swapped.json", not_run_document(*swapped))
        with self.assertRaisesRegex(manifest.ManifestError, "stale.*testProcessUtils"):
            manifest.verify_xunit(expected, directory, self.root / "actual.txt", listed)

    def test_a_logic_host_entry_relabelled_operator_is_refused_by_the_trusted_copy(self):
        # Hosted cannot tell: the test is skipped there under either label. Only the trusted copy can.
        with self.assertRaisesRegex(manifest.ManifestError, "does not have"):
            self.verify([(self.VERSION, "operator")], [(self.VERSION, "logic_host")])

    def test_without_a_trusted_copy_only_the_built_in_operator_id_is_accepted(self):
        bootstrap = sorted(manifest.BOOTSTRAP_OPERATOR_IDS)
        self.verify([(test_id, "operator") for test_id in bootstrap] + [(self.PLAIN, "logic_host")], None)
        self.verify([(self.PLAIN, "logic_host")], None)
        with self.assertRaisesRegex(manifest.ManifestError, "does not have"):
            self.verify([(self.OWNED, "operator")], None)
        with self.assertRaisesRegex(manifest.ManifestError, "does not have.*needsProject"):
            self.verify([(test_id, "operator") for test_id in bootstrap] + [(self.OWNED, "operator")], None)

    def test_a_present_trusted_copy_replaces_the_built_in_id(self):
        bootstrap = sorted(manifest.BOOTSTRAP_OPERATOR_IDS)
        with self.assertRaisesRegex(manifest.ManifestError, "does not have"):
            self.verify([(test_id, "operator") for test_id in bootstrap], [(self.PLAIN, "logic_host")])

    def test_an_unreadable_trusted_copy_fails_closed(self):
        self.write("trusted.json", "{")
        candidate = self.write("candidate.json", not_run_document((self.OWNED, "operator")))
        with self.assertRaisesRegex(manifest.ManifestError, "cannot read not-run list"):
            manifest.verify_trusted_operator(candidate, self.root / "trusted.json")

    def test_command_line_exit_codes(self):
        candidate = self.write("candidate.json", not_run_document((self.OWNED, "operator")))
        trusted = self.write("trusted.json", not_run_document((self.OWNED, "operator")))
        command = [sys.executable, str(SCRIPT), "verify-trusted", "--not-run", str(candidate),
                   "--trusted"]
        self.assertEqual(subprocess.run([*command, str(trusted)], capture_output=True).returncode, 0)
        other = self.write("other.json", not_run_document((self.PLAIN, "logic_host")))
        refused = subprocess.run([*command, str(other)], capture_output=True, text=True)
        self.assertEqual(refused.returncode, 1)
        self.assertIn("does not have", refused.stderr)
        absent = subprocess.run([*command, str(self.root / "absent.json")], capture_output=True, text=True)
        self.assertEqual(absent.returncode, 1)


HOST = ("LogicProMCPTests.LibraryDiskScannerTests/installedLibraryEmitsOnlyPanelCategories()",
        "LogicProMCPTests.StockPluginFactoryPresetTests/hostFactorySettingsFoldersAreAccountedFor()",
        "LogicProMCPTests.testProcessUtilsLogicProVersionResolvesOffMain()")


def testcase(test_id, outcome=""):
    head, name = test_id.rsplit("/", 1) if "/" in test_id else test_id.rsplit(".", 1)
    return f'<testcase classname="{head.replace("/", ".")}" name="{name}">{outcome}</testcase>'


class HostRunTests(ManifestFixture):
    """The Logic-host rule: each logic_host ID present, executed and passed, from the xUnit file."""

    def setUp(self):
        super().setUp()
        self.listed = self.write("not-run.json", not_run_document(
            *[(test_id, "logic_host") for test_id in HOST],
            ("LogicProMCPTests.QualificationRunnerTests/live()", "live"),
            ("LogicProMCPTests.Other/operator()", "operator")))
        self.directory = self.root / "xunit"
        self.directory.mkdir()

    def results(self, *cases):
        (self.directory / "results.xml").write_text(
            "<testsuites><testsuite>" + "".join(cases) + "</testsuite></testsuites>", encoding="utf-8")

    def verify(self):
        manifest.verify_host(self.listed, self.directory)

    def test_the_filter_selects_exactly_the_logic_host_ids(self):
        pattern = re.compile(manifest.host_filter(self.listed))
        # SwiftPM matches the module-qualified identifier followed by "/<file>:<line>:<column>".
        for test_id in HOST:
            self.assertTrue(pattern.search(test_id + "/File.swift:1:2"), test_id)
            self.assertTrue(pattern.search(test_id), test_id)
        for other in (
            "LogicProMCPTests.LibraryDiskScannerTests/retestInstalledLibraryEmitsOnlyPanelCategories()",
            "LogicProMCPTests.LibraryDiskScannerTests/installedLibraryEmitsOnlyPanelCategories2()",
            "LogicProMCPTests.testProcessUtilsLogicProVersionResolvesOffMain()x",
            "LogicProMCPTests.retestProcessUtilsLogicProVersionResolvesOffMain()",
            "LogicProMCPTests.QualificationRunnerTests/live()",
            "Prefix.LogicProMCPTests.testProcessUtilsLogicProVersionResolvesOffMain()",
        ):
            self.assertIsNone(pattern.search(other), other)

    def test_all_passing_is_accepted(self):
        self.results(*[testcase(test_id) for test_id in HOST])
        self.verify()

    def test_a_skip_fails(self):
        self.results(testcase(HOST[0], "<skipped>no Logic</skipped>"), testcase(HOST[1]), testcase(HOST[2]))
        with self.assertRaisesRegex(manifest.ManifestError, "skipped on the Logic host.*installedLibrary"):
            self.verify()

    def test_a_missing_id_fails(self):
        self.results(testcase(HOST[0]), testcase(HOST[1]))
        with self.assertRaisesRegex(manifest.ManifestError, "missing from the results.*testProcessUtils"):
            self.verify()

    def test_a_failure_or_error_fails(self):
        for outcome in ("<failure />", "<error />"):
            with self.subTest(outcome):
                self.results(testcase(HOST[0], outcome), testcase(HOST[1]), testcase(HOST[2]))
                with self.assertRaisesRegex(manifest.ManifestError, "failed: .*installedLibrary"):
                    self.verify()

    def test_a_similarly_named_passing_test_cannot_stand_in_for_a_skipped_one(self):
        # The reviewer's counter-example: the required test skipped, `retest...` passed.
        self.results(
            testcase(HOST[0]), testcase(HOST[1]),
            testcase(HOST[2], "<skipped>no Logic</skipped>"),
            testcase("LogicProMCPTests.retestProcessUtilsLogicProVersionResolvesOffMain()"))
        with self.assertRaises(manifest.ManifestError) as caught:
            self.verify()
        self.assertIn("not a host test: LogicProMCPTests/retestProcessUtils", str(caught.exception))
        self.assertIn("skipped on the Logic host", str(caught.exception))

    def test_a_duplicate_or_a_listed_live_test_in_the_results_fails(self):
        self.results(*[testcase(test_id) for test_id in HOST], testcase(HOST[0]))
        with self.assertRaisesRegex(manifest.ManifestError, "ran twice"):
            self.verify()
        self.results(*[testcase(test_id) for test_id in HOST],
                     testcase("LogicProMCPTests.QualificationRunnerTests/live()"))
        with self.assertRaisesRegex(manifest.ManifestError, "not a host test"):
            self.verify()

    def test_a_list_with_no_logic_host_entry_fails(self):
        self.listed = self.write("none.json", not_run_document(("A.b/c()", "live")))
        self.results(testcase("A.b/c()"))
        with self.assertRaisesRegex(manifest.ManifestError, "no logic_host test"):
            self.verify()


LIVE_RELEASE = ("LogicProMCPTests.QualificationRunnerTests/releaseOne()",
                "LogicProMCPTests.QualificationRunnerTests/releaseTwo()")
LIVE_DEBUG = "LogicProMCPTests.QualificationRunnerTests/debugOne()"


class LiveRunTests(ManifestFixture):
    """HOST-04(b): each live ID is selected by its exact ID and judged from its own xUnit output."""

    def setUp(self):
        super().setUp()
        self.listed = self.write("not-run.json", not_run_document(
            (LIVE_RELEASE[0], "live", "release"), (LIVE_RELEASE[1], "live", "release"),
            (LIVE_DEBUG, "live", "debug"), (HOST[0], "logic_host"),
            ("LogicProMCPTests.Other/operator()", "operator")))
        self.directory = self.root / "xunit"
        self.directory.mkdir()

    def results(self, *cases):
        (self.directory / "results.xml").write_text(
            "<testsuites><testsuite>" + "".join(cases) + "</testsuite></testsuites>", encoding="utf-8")

    def verify(self, only, lane="release"):
        manifest.verify_host(self.listed, self.directory, "live", lane, only)

    def test_lanes_select_their_own_ids(self):
        self.assertEqual(manifest.listed_ids(self.listed, "live", "release"), sorted(LIVE_RELEASE))
        self.assertEqual(manifest.listed_ids(self.listed, "live", "debug"), [LIVE_DEBUG])
        self.assertEqual(manifest.listed_ids(self.listed, "live"), sorted(LIVE_RELEASE + (LIVE_DEBUG,)))
        self.assertEqual(manifest.listed_ids(self.listed, "live", "debug", LIVE_DEBUG), [LIVE_DEBUG])
        with self.assertRaisesRegex(manifest.ManifestError, "not a live test"):
            manifest.listed_ids(self.listed, "live", "debug", LIVE_RELEASE[0])
        with self.assertRaisesRegex(manifest.ManifestError, "not a live test"):
            manifest.listed_ids(self.listed, "live", None, HOST[0])

    def test_the_filter_selects_exactly_one_live_id(self):
        pattern = re.compile(manifest.host_filter(self.listed, "live", "release", LIVE_RELEASE[0]))
        self.assertTrue(pattern.search(LIVE_RELEASE[0] + "/File.swift:1:2"))
        for other in (LIVE_RELEASE[1], LIVE_DEBUG, LIVE_RELEASE[0].replace("releaseOne", "releaseOne2"),
                      LIVE_RELEASE[0].replace("releaseOne", "retestReleaseOne")):
            self.assertIsNone(pattern.search(other), other)

    def test_an_executed_and_passed_live_test_is_accepted(self):
        self.results(testcase(LIVE_RELEASE[0]))
        self.verify(LIVE_RELEASE[0])

    def test_a_live_test_that_reports_a_skip_fails(self):
        # The reviewer's replay: the live test skips and the process still exits 0.
        self.results(testcase(LIVE_RELEASE[0], "<skipped>Logic is not driven</skipped>"))
        with self.assertRaisesRegex(manifest.ManifestError, "skipped on the Logic host.*releaseOne"):
            self.verify(LIVE_RELEASE[0])

    def test_a_missing_failed_or_extra_live_test_fails(self):
        self.results()
        with self.assertRaisesRegex(manifest.ManifestError, "missing from the results.*releaseOne"):
            self.verify(LIVE_RELEASE[0])
        self.results(testcase(LIVE_RELEASE[0], "<failure />"))
        with self.assertRaisesRegex(manifest.ManifestError, "failed: .*releaseOne"):
            self.verify(LIVE_RELEASE[0])
        self.results(testcase(LIVE_RELEASE[0]), testcase(LIVE_RELEASE[1]))
        with self.assertRaisesRegex(manifest.ManifestError, "not a live test: .*releaseTwo"):
            self.verify(LIVE_RELEASE[0])
        self.results(testcase(LIVE_RELEASE[0].replace("releaseOne", "retestReleaseOne")))
        with self.assertRaisesRegex(manifest.ManifestError, "missing from the results.*releaseOne"):
            self.verify(LIVE_RELEASE[0])

    def test_a_live_id_with_no_owning_lane_fails_validation(self):
        unowned = self.write("unowned.json", json.dumps({"tests": [
            {"id": LIVE_RELEASE[0], "class": "live", "reason": "fixture"}]}))
        for call in (lambda: manifest.read_not_run(unowned),
                     lambda: manifest.listed_ids(unowned, "live", "release"),
                     lambda: manifest.verify_host(unowned, self.directory, "live", "release")):
            with self.assertRaisesRegex(manifest.ManifestError, "no owning lane"):
                call()
        result = subprocess.run([sys.executable, str(SCRIPT), "list-ids", "--not-run", str(unowned),
                                 "--class", "live", "--lane", "release"], capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn("no owning lane", result.stderr)

    def test_command_line_lists_ids_and_requires_some_live_test(self):
        listing = subprocess.run([sys.executable, str(SCRIPT), "list-ids", "--not-run", str(self.listed),
                                  "--class", "live", "--lane", "debug"],
                                 capture_output=True, text=True, check=True)
        self.assertEqual(listing.stdout.split("\n"), [LIVE_DEBUG, ""])
        none = self.write("none.json", not_run_document((HOST[0], "logic_host")))
        empty = subprocess.run([sys.executable, str(SCRIPT), "list-ids", "--not-run", str(none),
                                "--class", "live"], capture_output=True, text=True)
        self.assertEqual(empty.returncode, 1)
        quiet = subprocess.run([sys.executable, str(SCRIPT), "list-ids", "--not-run", str(none),
                                "--class", "live", "--lane", "debug"], capture_output=True, text=True)
        self.assertEqual((quiet.returncode, quiet.stdout), (0, ""))


FAKE_LIVE_SWIFT = r"""#!/bin/bash
# Stands in for `swift test` in a live lane: records the filter of each process and writes the
# xUnit file for the one test it selected. FAKE_OUTCOME is the testcase child ("" passes).
printf '%s\n' "$*" >> "$FAKE_LOG"
filter=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --xunit-output) xunit="$2" ;;
        --filter) filter="$2" ;;
    esac
    shift
done
id="$(python3 - "$filter" "$FAKE_IDS" <<'PY'
import re, sys
for test_id in sys.argv[2].split("|"):
    if re.search(sys.argv[1], test_id + "/File.swift:1:2"):
        print(test_id)
PY
)"
head="${id%/*}"; name="${id##*/}"
printf '<testsuites><testsuite><testcase classname="%s" name="%s">%s</testcase></testsuite></testsuites>' \
    "$head" "$name" "$FAKE_OUTCOME" > "$xunit"
exit "${FAKE_EXIT:-0}"
"""


class LiveLaneScriptTests(ManifestFixture):
    """The run_live_lane function of Scripts/release-qualify.sh, extracted and run with a stand-in swift."""

    GATE = Path(__file__).with_name("release-qualify.sh")

    def run_lane(self, lane, outcome="", exit_code=0, rows=None):
        text = self.GATE.read_text(encoding="utf-8")
        function = text[text.index("run_live_lane() {"):]
        function = function[:function.index("\n}\n") + 3]
        listed = self.write("not-run.json", not_run_document(*(rows or (
            (LIVE_RELEASE[0], "live", "release"), (LIVE_RELEASE[1], "live", "release"),
            (LIVE_DEBUG, "live", "debug")))))
        bin_dir = self.root / "bin"
        bin_dir.mkdir(exist_ok=True)
        swift = bin_dir / "swift"
        swift.write_text(FAKE_LIVE_SWIFT, encoding="utf-8")
        swift.chmod(0o755)
        work = self.root / "work"
        work.mkdir(exist_ok=True)
        harness = f"""set -euo pipefail
cd {work}
HELPER={SCRIPT}
NOT_RUN={listed}
verify_candidate_bytes() {{ echo bytes-checked >> "$FAKE_LOG"; }}
{function}
run_live_lane {lane}
echo LANE_DONE
"""
        env = dict(os.environ, PATH=f"{bin_dir}:{os.environ['PATH']}", FAKE_LOG=str(self.root / "log.txt"),
                   FAKE_IDS="|".join(LIVE_RELEASE + (LIVE_DEBUG,)), FAKE_OUTCOME=outcome,
                   FAKE_EXIT=str(exit_code))
        result = subprocess.run(["/bin/bash", "-c", harness], env=env, text=True, capture_output=True, check=False)
        log = (self.root / "log.txt").read_text().splitlines() if (self.root / "log.txt").exists() else []
        return result, log

    def test_each_test_of_a_lane_runs_in_its_own_process_by_exact_id(self):
        result, log = self.run_lane("release")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("LANE_DONE", result.stdout)
        processes = [line for line in log if line != "bytes-checked"]
        self.assertEqual(len(processes), 2, log)
        for line in processes:
            self.assertIn("--no-parallel", line)
            self.assertIn("--xunit-output", line)
        self.assertEqual(sum(1 for line in log if line == "bytes-checked"), 2)
        self.assertIn("releaseOne", processes[0])
        self.assertNotIn("releaseTwo", processes[0])
        self.assertIn("releaseTwo", processes[1])
        self.setUp_clean()
        debug, log = self.run_lane("debug")
        self.assertEqual(debug.returncode, 0, debug.stderr)
        self.assertEqual(len([line for line in log if line != "bytes-checked"]), 1)

    def test_a_live_test_that_reports_a_skip_fails_the_step_although_the_process_exits_zero(self):
        for lane in ("release", "debug"):
            with self.subTest(lane=lane):
                self.setUp_clean()
                result, _ = self.run_lane(lane, outcome="<skipped>not driven</skipped>")
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("LANE_DONE", result.stdout)
                self.assertIn("skipped on the Logic host", result.stderr)

    def test_a_live_test_that_fails_or_whose_process_fails_fails_the_step(self):
        failed, _ = self.run_lane("release", outcome="<failure />")
        self.assertNotEqual(failed.returncode, 0)
        self.setUp_clean()
        crashed, _ = self.run_lane("release", exit_code=3)
        self.assertEqual(crashed.returncode, 3)
        self.assertNotIn("LANE_DONE", crashed.stdout)

    def test_a_live_id_with_no_owning_lane_fails_the_step_before_any_process_runs(self):
        result, log = self.run_lane("release", rows=((LIVE_RELEASE[0], "logic_host"), ))
        self.assertEqual(log, [])
        unowned = self.root / "unowned.json"
        unowned.write_text(json.dumps({"tests": [
            {"id": LIVE_RELEASE[0], "class": "live", "reason": "fixture"}]}), encoding="utf-8")
        text = self.GATE.read_text(encoding="utf-8")
        function = text[text.index("run_live_lane() {"):]
        function = function[:function.index("\n}\n") + 3]
        harness = f"set -euo pipefail\nHELPER={SCRIPT}\nNOT_RUN={unowned}\n{function}\nrun_live_lane release\necho LANE_DONE\n"
        failed = subprocess.run(["/bin/bash", "-c", harness], text=True, capture_output=True, check=False)
        self.assertNotEqual(failed.returncode, 0)
        self.assertIn("no owning lane", failed.stderr)
        self.assertNotIn("LANE_DONE", failed.stdout)

    def setUp_clean(self):
        for name in ("log.txt",):
            path = self.root / name
            if path.exists():
                path.unlink()


FAKE_SWIFT = r"""#!/bin/bash
# Stands in for `swift test`: records its arguments, prints console lines in the renderings that
# defeated the old line counter, and writes the xUnit file named by --xunit-output from $FAKE_XUNIT.
printf '%s\n' "$@" > "$FAKE_ARGS"
while [ "$#" -gt 0 ]; do
    if [ "$1" = "--xunit-output" ]; then cp "$FAKE_XUNIT" "$2"; fi
    shift
done
printf '\033[32m\xf4\x80\x80\x80 Test x passed after 0.1 seconds.\033[0m\n'
printf '\xf0\x9f\x9f\xa2 Test y passed after 0.1 seconds.\n'
exit "${FAKE_EXIT:-0}"
"""


class HostScriptTests(ManifestFixture):
    """Scripts/host-tests.sh end to end with a stand-in `swift`."""

    SCRIPT = Path(__file__).with_name("host-tests.sh")

    def run_script(self, cases, exit_code=0, output=None, extra_env=None):
        listed = self.write("not-run.json", not_run_document(
            *[(test_id, "logic_host") for test_id in HOST]))
        xunit = self.write("fake.xml", "<testsuites><testsuite>" + "".join(cases) + "</testsuite></testsuites>")
        bin_dir = self.root / "bin"
        bin_dir.mkdir(exist_ok=True)
        swift = bin_dir / "swift"
        swift.write_text(FAKE_SWIFT, encoding="utf-8")
        swift.chmod(0o755)
        env = dict(os.environ, PATH=f"{bin_dir}:{os.environ['PATH']}", FAKE_XUNIT=str(xunit),
                   FAKE_ARGS=str(self.root / "args.txt"), FAKE_EXIT=str(exit_code), **(extra_env or {}))
        return subprocess.run(["/bin/bash", str(self.SCRIPT), str(listed), str(output or self.root / "out")],
                              env=env, text=True, capture_output=True, check=False)

    def test_all_executed_passes_whatever_the_console_looks_like(self):
        result = self.run_script([testcase(test_id) for test_id in HOST])
        self.assertEqual(result.returncode, 0, result.stderr)
        arguments = (self.root / "args.txt").read_text(encoding="utf-8").split("\n")
        self.assertIn("--xunit-output", arguments)
        selected = arguments[arguments.index("--filter") + 1]
        self.assertTrue(selected.startswith("^(?:") and selected.endswith("(?:/|$)"), selected)

    def test_a_skipped_test_fails_even_though_the_console_shows_passes(self):
        cases = [testcase(HOST[0], "<skipped>no Logic</skipped>"), testcase(HOST[1]), testcase(HOST[2])]
        result = self.run_script(cases)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("skipped on the Logic host", result.stderr)

    def test_a_missing_test_fails(self):
        result = self.run_script([testcase(HOST[1]), testcase(HOST[2])])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing from the results", result.stderr)

    def test_a_substring_collision_cannot_make_up_the_count(self):
        cases = [testcase(HOST[0]), testcase(HOST[1]),
                 testcase("LogicProMCPTests.retestProcessUtilsLogicProVersionResolvesOffMain()"),
                 testcase("LogicProMCPTests.anotherPassing()")]
        result = self.run_script(cases)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not a host test", result.stderr)

    def test_a_failing_swift_exit_fails_even_when_the_results_pass(self):
        result = self.run_script([testcase(test_id) for test_id in HOST], exit_code=1)
        self.assertEqual(result.returncode, 1)

    def existing_directory(self):
        existing = self.root / "precious"
        (existing / "nested").mkdir(parents=True)
        (existing / "keep.txt").write_text("keep", encoding="utf-8")
        (existing / "nested" / "deep.txt").write_text("deep", encoding="utf-8")
        return existing

    @staticmethod
    def snapshot(directory):
        return sorted((str(path.relative_to(directory)), path.read_bytes() if path.is_file() else None)
                      for path in directory.rglob("*"))

    def test_an_existing_non_empty_directory_is_never_deleted_or_overwritten(self):
        existing = self.existing_directory()
        before = self.snapshot(existing)
        bin_dir = self.root / "bin"
        bin_dir.mkdir(exist_ok=True)
        # A stand-in `rm` that fails loudly: the script has no business deleting anything.
        rm = bin_dir / "rm"
        rm.write_text("#!/bin/bash\necho \"rm called: $*\" >> \"$FAKE_RM_LOG\"\nexit 99\n", encoding="utf-8")
        rm.chmod(0o755)
        result = self.run_script([testcase(test_id) for test_id in HOST], output=existing,
                                 extra_env={"FAKE_RM_LOG": str(self.root / "rm.log")})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.root / "rm.log").exists())
        after = self.snapshot(existing)
        self.assertTrue(all(entry in after for entry in before), (before, after))
        fresh = [path for path in existing.iterdir() if path.name not in ("keep.txt", "nested")]
        self.assertEqual(len(fresh), 1)
        self.assertTrue((fresh[0] / "results.xml").is_file())
        self.assertEqual((existing / "keep.txt").read_text(), "keep")

    def test_two_runs_under_one_parent_use_two_fresh_directories(self):
        parent = self.root / "runs"
        for _ in range(2):
            result = self.run_script([testcase(test_id) for test_id in HOST], output=parent)
            self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(list(parent.iterdir())), 2)

    def test_an_unusable_list_is_refused_before_the_filesystem_is_touched(self):
        existing = self.existing_directory()
        before = self.snapshot(existing)
        broken = self.write("broken.json", "{")
        bin_dir = self.root / "bin"
        bin_dir.mkdir(exist_ok=True)
        swift = bin_dir / "swift"
        swift.write_text(FAKE_SWIFT, encoding="utf-8")
        swift.chmod(0o755)
        for target in (existing, self.root / "never-created"):
            result = subprocess.run(["/bin/bash", str(self.SCRIPT), str(broken), str(target)],
                                    env=dict(os.environ, PATH=f"{bin_dir}:{os.environ['PATH']}"),
                                    text=True, capture_output=True, check=False)
            self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.snapshot(existing), before)
        self.assertFalse((self.root / "never-created").exists())


if __name__ == "__main__":
    unittest.main()
