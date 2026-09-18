#!/usr/bin/env python3
"""Drive check-canon-citations.py by injecting each defect it claims to refuse.

A guard proved once by hand is a guard that drifts -- `Scripts/check-guards-have-self-tests.py`
says so at length, and names six rules in this repository that turned out to enforce something
narrower than their own docstring. So every refusal listed in that guard's docstring gets a case
here, and each case builds a whole temporary repository rather than mutating this one: a test that
edits the tree it is checking can pass because of state it left behind.
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
GUARD = os.path.join(REPO, "Scripts", "check-canon-citations.py")

REAL_REF = None    # both are read from a committed record in setUpModule, never from Logic
REAL_VALUE = None  # resolved from the real bundle in setUpModule, or the module skips


def setUpModule():
    """Take a real canonical value from the committed tree, not from Logic.

    The first version asked Logic for it and raised `SkipTest` at module level when Logic was
    absent -- which is every CI runner. `run-repo-guards.py` keys on the exit code, so the suite
    reported `ok` having executed ZERO assertions: the guard ran in CI and its proof that the guard
    works did not. Measured by review 2026-09-15.

    A schema-3 record already carries Apple's text in `canon[].value`, with the reference beside
    it, and `docs/canon/index/` pins its digest. So the fixture is in the repository, and the whole
    suite runs anywhere.
    """
    global REAL_VALUE, REAL_REF
    for name in sorted(os.listdir(os.path.join(REPO, "docs", "observations"))):
        if not name.endswith(".json"):
            continue
        with open(os.path.join(REPO, "docs", "observations", name), encoding="utf-8") as handle:
            try:
                record = json.load(handle)
            except json.JSONDecodeError:
                continue
        for citation in record.get("canon", []):
            ref, value = citation.get("ref"), citation.get("value")
            # A QuickHelp citation in a real locale, because the absence cases assert the corpus
            # by name. Taking the first citation of any kind picked a locale-free `nib` value the
            # moment a record carrying one joined the tree, and the case then asserted a corpus the
            # value does not live in.
            if ref and value and ref.startswith("logic-canon://quickhelp/") and "/-/" not in ref:
                REAL_REF, REAL_VALUE = ref, value
                return
    why = "no committed record carries a localised QuickHelp citation"
    if os.environ.get("CI") == "true":
        # The defect this function's docstring describes, still here in its replacement. A
        # module-level SkipTest exits 0, `run-repo-guards.py` keys on the exit code, and the suite
        # reports ok having executed zero assertions -- which is exactly what it said went wrong
        # the first time. Locally a developer may be on a branch without such a record; CI has the
        # committed tree, so there it means the fixture search is broken, not that the tree is thin.
        raise AssertionError(f"{why}. Under CI this is a failure, not a skip: these 60 cases would "
                             f"otherwise report ok having asserted nothing.")
    raise unittest.SkipTest(why)


class GuardBehaviour(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="canon-guard-")
        self.addCleanup(shutil.rmtree, self.root, ignore_errors=True)
        os.makedirs(os.path.join(self.root, "Scripts"))
        os.makedirs(os.path.join(self.root, "docs", "observations"))
        for name in ("logic_canon.py", "check-canon-citations.py", "nibarchive.py"):
            shutil.copy2(os.path.join(REPO, "Scripts", name),
                         os.path.join(self.root, "Scripts", name))
        shutil.copytree(os.path.join(REPO, "docs", "canon"),
                        os.path.join(self.root, "docs", "canon"))
        self.without_canon(["docs/observations/2000-01-01-seeded.json"])
        self.record("2000-01-01-seeded.json", {"schema": 1, "id": "seeded"})
        # A real repository with a base commit, because the guard compares the waiver lists against
        # `git merge-base` and fails OUTRIGHT under CI when it cannot. A fixture without git made
        # every passing case fail the moment CI=true was set -- which is how the fixture had come
        # to differ from the thing it checks. Predicted by review 2026-09-15 and reproduced.
        self._make_repo_with_a_base()

    def without_canon(self, records):
        path = os.path.join(self.root, "docs", "canon", "WITHOUT-CANON.json")
        with open(path, "w", encoding="utf-8") as handle:
            json.dump({"records": records}, handle)

    def record(self, name, body):
        path = os.path.join(self.root, "docs", "observations", name)
        with open(path, "w", encoding="utf-8") as handle:
            json.dump(body, handle, ensure_ascii=False)

    def run_guard(self):
        return subprocess.run([sys.executable, os.path.join(self.root, "Scripts",
                                                            "check-canon-citations.py")],
                              capture_output=True, text=True)

    # -- the baseline must pass, or every failure below proves nothing -------------------------
    def test_a_clean_tree_passes(self):
        result = self.run_guard()
        self.assertEqual(result.returncode, 0, result.stderr)

    # -- rule 1 --------------------------------------------------------------------------------
    def test_a_malformed_reference_fails(self):
        self.record("2026-09-15-bad-ref.json", {
            "schema": 3, "id": "bad-ref",
            "canon": [{"ref": "logic-canon://quickhelp/ko/K#Title", "value": "x",
                       "used_for": "y", "binding": {"kind": "record"}}]})
        self.without_canon(["docs/observations/2000-01-01-seeded.json"])
        result = self.run_guard()
        self.assertEqual(result.returncode, 1)
        self.assertIn("not a canonical reference", result.stderr)

    # -- rule 2 --------------------------------------------------------------------------------
    def test_a_reference_nobody_pinned_fails(self):
        self.record("2026-09-15-unpinned.json", {
            "schema": 3, "id": "unpinned",
            "canon": [{"ref": "logic-canon://quickhelp/QuickHelp/ko/NO_SUCH_KEY#composed",
                       "value": "x", "used_for": "y", "binding": {"kind": "record"}}]})
        result = self.run_guard()
        self.assertEqual(result.returncode, 1)
        self.assertIn("is not in docs/canon/index", result.stderr)

    # -- rule 3: the one that matters most ------------------------------------------------------
    def test_a_quoted_value_that_is_not_logics_value_fails(self):
        """One character wrong is the whole failure class this axis exists for."""
        self.record("2026-09-15-misquoted.json", {
            "schema": 3, "id": "misquoted",
            "canon": [{"ref": REAL_REF, "value": REAL_VALUE + "x", "used_for": "y",
                       "binding": {"kind": "record"}}]})
        result = self.run_guard()
        self.assertEqual(result.returncode, 1)
        self.assertIn("Logic's value hashes to", result.stderr)

    def test_the_correct_value_passes_so_the_previous_test_is_about_the_value(self):
        self.record("2026-09-15-quoted.json", {
            "schema": 3, "id": "quoted",
            "canon": [{"ref": REAL_REF, "value": REAL_VALUE, "used_for": "y",
                       "binding": {"kind": "record"}}],
            "observations": [{"what": REAL_VALUE}]})
        result = self.run_guard()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_a_citation_missing_used_for_fails(self):
        self.record("2026-09-15-no-use.json", {
            "schema": 3, "id": "no-use",
            "canon": [{"ref": REAL_REF, "value": REAL_VALUE, "used_for": "",
                       "binding": {"kind": "record"}}]})
        result = self.run_guard()
        self.assertEqual(result.returncode, 1)
        self.assertIn("`used_for` is required", result.stderr)

    # -- rule 4 --------------------------------------------------------------------------------
    def test_claiming_absence_for_a_string_logic_ships_fails(self):
        self.record("2026-09-15-false-absence.json", {
            "schema": 3, "id": "false-absence",
            "canon_absent": [{"claim": "c", "strings": [REAL_VALUE],
                              "searched": [{"source": "quickhelp", "locale": "ko"}, {"source": "strings", "locale": "ko"},
                                          {"source": "madsp", "locale": "-"},
                                          {"source": "nib", "locale": "-"}],
                              "why_runtime": "r"}]})
        result = self.run_guard()
        self.assertEqual(result.returncode, 1)
        self.assertIn("is PRESENT in quickhelp/ko", result.stderr)

    def _every_corpus(self):
        """Derived from the manifest, exactly as the guard derives it.

        Written out by hand first, and the hand-written list went stale the moment the rule changed
        from "the record's locale" to "every locale" -- a fixture that names what it is testing
        rather than deriving it tests the fixture.
        """
        with open(os.path.join(self.root, "docs", "canon", "MANIFEST.json"), encoding="utf-8") as h:
            manifest = json.load(h)
        return [{"source": source, "locale": locale}
                for source, block in sorted(manifest["sources"].items())
                for locale in sorted(block["locales"])]

    def test_a_real_absence_passes(self):
        self.record("2026-09-15-absence.json", {
            "schema": 3, "id": "absence",
            "canon_absent": [{"claim": "c",
                              "strings": ["a string no shipped application contains anywhere 91xq"],
                              "searched": self._every_corpus(),
                              "why_runtime": "r"}],
            "host": {"locale": "ko-KR"}})
        result = self.run_guard()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_an_absence_that_only_decorates_a_shipped_string_fails(self):
        """`is_absent` is EXACT, so a colon, an ellipsis or a capital makes a shipped label look
        uncitable. `Input Port:`, `Output Port:` and `Model:` were each proved absent from all 23
        corpora while Logic ships them without the colon, and none had been read off a screen.

        The decoration fold has existed since it was written and only the CLI asked it; the rule
        that gates a RECORD did not, which is two definitions of "in the corpus" in one system.
        """
        self.record("2026-09-15-decorated-absence.json", {
            "schema": 3, "id": "decorated-absence",
            "canon_absent": [{"claim": "c", "strings": [REAL_VALUE + ":"],
                              "searched": self._every_corpus(), "why_runtime": "r"}],
            "host": {"locale": "ko-KR"}})
        result = self.run_guard()
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("differ only by case or decoration", result.stderr)

    def test_a_decorated_absence_passes_when_the_shipped_spelling_is_cited(self):
        """Sometimes the decoration IS the finding. `Set Locators…` is absent from every corpus and
        Apple ships `Set Locators`, and saying so is the point of the record that carries it.

        A record that has READ the shipped spelling can cite it; one that has not is guessing. So
        the near miss is allowed exactly when the record also carries a citation whose value folds
        to the same thing -- which makes the record say which spelling Logic actually has instead
        of reading as `Logic has no such label`.
        """
        self.record("2026-09-15-decorated-and-cited.json", {
            "schema": 3, "id": "decorated-and-cited",
            "canon": [{"ref": REAL_REF, "value": REAL_VALUE, "used_for": "the shipped spelling",
                       "binding": {"kind": "record"}}],
            "canon_absent": [{"claim": "c", "strings": [REAL_VALUE + ":"],
                              "searched": self._every_corpus(), "why_runtime": "r"}],
            "host": {"locale": "ko-KR"}})
        result = self.run_guard()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_an_absence_over_a_corpus_with_no_set_fails(self):
        self.record("2026-09-15-no-corpus.json", {
            "schema": 3, "id": "no-corpus",
            "canon_absent": [{"claim": "c", "strings": ["anything"],
                              "searched": [{"source": "quickhelp", "locale": "xx"}],
                              "why_runtime": "r"}]})
        result = self.run_guard()
        self.assertEqual(result.returncode, 1)
        self.assertIn("no absence set", result.stderr)

    # -- rule 5 --------------------------------------------------------------------------------
    def test_schema_3_with_neither_citation_nor_absence_fails(self):
        self.record("2026-09-15-empty.json", {"schema": 3, "id": "empty"})
        result = self.run_guard()
        self.assertEqual(result.returncode, 1)
        self.assertIn("none of `canon`, `canon_absent` or `canon_not_applicable`", result.stderr)

    # -- rule 6: the ratchet --------------------------------------------------------------------
    def test_a_new_record_at_schema_1_fails(self):
        self.record("2026-09-15-new-old-schema.json", {"schema": 1, "id": "new-old"})
        result = self.run_guard()
        self.assertEqual(result.returncode, 1)
        self.assertIn("may only shrink", result.stderr)

    def test_a_waiver_naming_a_file_that_is_gone_fails(self):
        self.without_canon(["docs/observations/2000-01-01-seeded.json",
                            "docs/observations/1999-01-01-deleted.json"])
        result = self.run_guard()
        self.assertEqual(result.returncode, 1)
        self.assertIn("which is not in the tree", result.stderr)

    # -- the manifest ---------------------------------------------------------------------------
    def test_an_index_built_by_a_different_extractor_fails(self):
        path = os.path.join(self.root, "docs", "canon", "MANIFEST.json")
        with open(path, "r", encoding="utf-8") as handle:
            manifest = json.load(handle)
        manifest["extractor_version"] = manifest["extractor_version"] + 1
        with open(path, "w", encoding="utf-8") as handle:
            json.dump(manifest, handle)
        result = self.run_guard()
        self.assertEqual(result.returncode, 1)
        self.assertIn("were never comparable", result.stderr)

    # -- rule 7: the waiver lists may only shrink, measured against a real merge base -------------
    def _git(self, *args):
        return subprocess.run(["git", *args], cwd=self.root, capture_output=True, text=True)

    def _make_repo_with_a_base(self):
        """A real repository, because rule 7 compares against `git merge-base` and nothing else.

        Without this the rule never runs in its own test: a plain temp directory has no base, the
        guard prints a note and moves on, and the case would pass while checking nothing.
        """
        self._git("init", "-q", "-b", "main")
        self._git("config", "user.email", "t@example.com")
        self._git("config", "user.name", "t")
        self._git("add", "-A")
        self._git("commit", "-q", "-m", "base")

    def test_adding_to_a_waiver_list_fails(self):
        self.without_canon(["docs/observations/2000-01-01-seeded.json",
                            "docs/observations/2026-09-15-new.json"])
        self.record("2026-09-15-new.json", {"schema": 1, "id": "new"})
        result = self.run_guard()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("may only SHRINK", result.stderr)

    def test_adding_to_a_requirement_list_passes(self):
        """A requirement is not a waiver, and the ratchet had them pointing the same way.

        Rule 14 refuses a Swift file declaring a LabelSet outside `LOGIC-FACING.json`, so a new
        Logic-facing directory MUST add a prefix — and rule 7 refused the addition. The first
        change that needed it would have had nowhere to go.
        """
        self._make_repo_with_a_base()
        path = os.path.join(self.root, "docs", "canon", "LOGIC-FACING.json")
        with open(path, encoding="utf-8") as handle:
            body = json.load(handle)
        body["prefixes"].append("Sources/LogicProMCP/SomethingNew/")
        with open(path, "w", encoding="utf-8") as handle:
            json.dump(body, handle, ensure_ascii=False)
        result = self.run_guard()
        self.assertNotIn("LOGIC-FACING", result.stderr)

    def test_removing_from_a_requirement_list_fails(self):
        self._make_repo_with_a_base()
        path = os.path.join(self.root, "docs", "canon", "CI-GATE.json")
        with open(path, encoding="utf-8") as handle:
            body = json.load(handle)
        body["required_commands"] = body["required_commands"][:-1]
        with open(path, "w", encoding="utf-8") as handle:
            json.dump(body, handle, ensure_ascii=False)
        result = self.run_guard()
        self.assertEqual(result.returncode, 1)
        self.assertIn("may only", result.stderr)
        self.assertIn("CI-GATE", result.stderr)

    # -- rule 7, applied to the corpus: the denominator of every absence proof ------------------
    # The four lists above are hand-written, and the corpus is derived, so it was not on the list
    # at all. Measured before these cases existed: delete `madsp` and `nib` from the manifest,
    # delete their index and absence files, drop the entries the records named -- and all 48
    # guards passed while every absence proof in the tree silently searched half the corpus.

    def _manifest(self):
        return os.path.join(self.root, "docs", "canon", "MANIFEST.json")

    def _rewrite_manifest(self, mutate):
        with open(self._manifest(), encoding="utf-8") as handle:
            body = json.load(handle)
        mutate(body)
        with open(self._manifest(), "w", encoding="utf-8") as handle:
            json.dump(body, handle, ensure_ascii=False)

    def test_removing_a_source_from_the_corpus_fails(self):
        self._make_repo_with_a_base()
        gone = sorted(json.load(open(self._manifest(), encoding="utf-8"))["sources"])[0]
        self._rewrite_manifest(lambda body: body["sources"].pop(gone))
        result = self.run_guard()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("MANIFEST.json", result.stderr)
        self.assertIn("may only", result.stderr)

    def test_removing_one_locale_from_a_corpus_fails(self):
        """A whole source is the loud case; one locale is the quiet one, and it is the likelier.

        An absence proof searches every (source, locale). Losing one locale makes every existing
        proof weaker by exactly the strings that live only there -- which is what a locale IS.
        """
        self._make_repo_with_a_base()
        body = json.load(open(self._manifest(), encoding="utf-8"))
        source = sorted(k for k, v in body["sources"].items() if len(v.get("locales") or []) > 1)
        self.assertTrue(source, "the fixture must carry a multi-locale source or this checks nothing")
        name = source[0]
        self._rewrite_manifest(lambda b: b["sources"][name]["locales"].pop())
        result = self.run_guard()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn(name, result.stderr)

    def test_adding_a_source_to_the_corpus_passes(self):
        """The positive control. A ratchet that refused growth would block #895's `nibstrings`."""
        self._make_repo_with_a_base()
        self._rewrite_manifest(
            lambda body: body["sources"].update({"nibstrings": {"locales": ["en"]}}))
        result = self.run_guard()
        self.assertNotIn("corpora every absence proof searches", result.stderr)

    def test_an_extractor_that_stops_matching_the_shape_fails(self):
        """The failure this ratchet is most likely to die of, and only one direction is silent.

        The other four ratchets read a list. The corpus reads a map of maps, so it needs its own
        extractor -- and an extractor that no longer matches returns an empty set. Which side goes
        empty decides everything:

            the CURRENT tree reads empty   every member looks REMOVED -- loud, and correct
            the BASE reads empty           nothing can be lost, so the rule passes everything

        The second is the one worth a case, because it looks exactly like a clean run. It is
        driven by committing the unmatched shape as the base and restoring the real one, which is
        what a renamed key in the manifest writer would actually leave behind.
        """
        def rename_the_key(body):
            for block in body["sources"].values():
                block["languages"] = block.pop("locales")

        def restore_the_key(body):
            for block in body["sources"].values():
                block["locales"] = block.pop("languages")

        self._rewrite_manifest(rename_the_key)
        self._make_repo_with_a_base()          # the base now carries the shape nothing reads
        self._rewrite_manifest(restore_the_key)
        result = self.run_guard()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("no longer matches the file's shape", result.stderr)

    def test_a_shape_change_in_the_current_tree_is_loud_too(self):
        """The other direction, pinned so the case above is read as being about silence."""
        self._make_repo_with_a_base()

        def rename_the_key(body):
            for block in body["sources"].values():
                block["languages"] = block.pop("locales")

        self._rewrite_manifest(rename_the_key)
        result = self.run_guard()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("may only", result.stderr)

    # -- rule 16: an absence set may not lose entries under the same Logic --------------------
    # Rule 7 ratchets WHICH corpora are searched. Nothing watched how many values each holds, and
    # `verify_absence_counts` says why its own reading is not enough: the forgery needs "three
    # consistent edits" and a rebuild makes all three. Measured before these cases existed: twelve
    # sets truncated to 50 entries, counts and digests rewritten, 410,771 values gone, exit 0.

    def _shrink_a_set(self, body, by=lambda n: 50):
        for source, block in body["sources"].items():
            entries = block.get("absence_entries") or {}
            for locale in entries:
                entries[locale] = by(entries[locale])
                return f"{source}/{locale}"
        return None

    def test_an_absence_set_that_lost_entries_fails(self):
        self._make_repo_with_a_base()
        name = None
        with open(self._manifest(), encoding="utf-8") as handle:
            body = json.load(handle)
        name = self._shrink_a_set(body)
        self.assertIsNotNone(name, "the fixture must declare absence_entries or this checks nothing")
        with open(self._manifest(), "w", encoding="utf-8") as handle:
            json.dump(body, handle, ensure_ascii=False)
        result = self.run_guard()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("at the merge base", result.stderr)
        self.assertIn(name.split("/")[0], result.stderr)

    def test_a_shape_number_that_fell_fails(self):
        """The second population rule 16 covers, and the one that shrinks a TEST rather than a proof.

        `TheAlgorithmAgainstASurrogateCorpus` builds its fixture from these numbers, so lowering
        them lowers the bar the parser has to clear.
        """
        self._make_repo_with_a_base()
        with open(self._manifest(), encoding="utf-8") as handle:
            body = json.load(handle)
        shape = (body["sources"].get("quickhelp") or {}).get("shape") or {}
        self.assertTrue(shape, "the fixture must carry a shape block or this checks nothing")
        locale = sorted(shape)[0]
        shape[locale]["suffix_pairs"] = 1
        with open(self._manifest(), "w", encoding="utf-8") as handle:
            json.dump(body, handle, ensure_ascii=False)
        result = self.run_guard()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("suffix_pairs", result.stderr)

    def test_a_length_that_fell_is_not_a_weakening(self):
        """`median_length` and `shortest` move with the language, not with the strength of a claim.

        Ratcheting them would refuse a rebuild for a reason nobody can act on. Everything else
        under shape and round_trip IS ratcheted, so a structural number added later is covered by
        default rather than by somebody remembering.
        """
        self._make_repo_with_a_base()
        with open(self._manifest(), encoding="utf-8") as handle:
            body = json.load(handle)
        shape = (body["sources"].get("quickhelp") or {}).get("shape") or {}
        locale = sorted(shape)[0]
        shape[locale]["median_length"] = 1
        shape[locale]["shortest"] = 1
        with open(self._manifest(), "w", encoding="utf-8") as handle:
            json.dump(body, handle, ensure_ascii=False)
        result = self.run_guard()
        self.assertNotIn("median_length", result.stderr)
        self.assertNotIn("over the same Logic", result.stderr)

    def test_a_shape_block_that_disappeared_fails(self):
        """A block that is gone takes its ratchet with it, and nothing downstream says so.

        The surrogate corpus cases skip when the shape is missing, and a skip exits 0.
        """
        self._make_repo_with_a_base()
        with open(self._manifest(), encoding="utf-8") as handle:
            body = json.load(handle)
        for block in body["sources"].values():
            block.pop("shape", None)
            block.pop("round_trip", None)
            block.pop("absence_entries", None)
        with open(self._manifest(), "w", encoding="utf-8") as handle:
            json.dump(body, handle, ensure_ascii=False)
        result = self.run_guard()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("takes its ratchet with it", result.stderr)

    def test_an_absence_set_that_gained_entries_passes(self):
        """The positive control. A rebuild on the same Logic that finds MORE is not a regression."""
        self._make_repo_with_a_base()
        with open(self._manifest(), encoding="utf-8") as handle:
            body = json.load(handle)
        self._shrink_a_set(body, by=lambda n: n + 1000)
        with open(self._manifest(), "w", encoding="utf-8") as handle:
            json.dump(body, handle, ensure_ascii=False)
        result = self.run_guard()
        self.assertNotIn("over the same Logic", result.stderr)

    def test_a_shrunken_set_under_a_different_logic_is_allowed_and_said_aloud(self):
        """A different Logic holds different strings, so the rule steps aside -- visibly.

        Silence here would make the escape the cheapest path: bump a version string and every
        count is free. It is not free -- `check_build_agrees_with_the_ledger` then disagrees with
        every record's host block -- but the note is what a reviewer reads.
        """
        self._make_repo_with_a_base()
        with open(self._manifest(), encoding="utf-8") as handle:
            body = json.load(handle)
        self._shrink_a_set(body)
        body["logic"] = dict(body.get("logic") or {}, build="9999")
        with open(self._manifest(), "w", encoding="utf-8") as handle:
            json.dump(body, handle, ensure_ascii=False)
        result = self.run_guard()
        self.assertIn("names a different Logic, so this is allowed", result.stderr)
        self.assertNotIn("over the same Logic", result.stderr)

    # -- rule 7 over the CI skip allowance ------------------------------------------------------
    # A skip exits 0, so `run-repo-guards.py` reports ok for a check that ran nothing. The
    # allowance lives in a file so this ratchet can see it, and its members are one per ALLOWED
    # SKIP rather than one per guard, so the number moves in the right direction.

    def _skips(self):
        return os.path.join(self.root, "docs", "canon", "CI-SKIPS.json")

    def _rewrite_skips(self, mutate):
        with open(self._skips(), encoding="utf-8") as handle:
            body = json.load(handle)
        mutate(body)
        with open(self._skips(), "w", encoding="utf-8") as handle:
            json.dump(body, handle, ensure_ascii=False)

    def test_raising_a_skip_allowance_fails(self):
        self._make_repo_with_a_base()
        with open(self._skips(), encoding="utf-8") as handle:
            name = sorted(json.load(handle)["allowed"])[0]
        self._rewrite_skips(lambda body: body["allowed"][name].update(
            skips=body["allowed"][name]["skips"] + 1))
        result = self.run_guard()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("CI-SKIPS", result.stderr)
        self.assertIn("may only", result.stderr)

    def test_lowering_a_skip_allowance_passes(self):
        """The direction that must stay open, or the allowance can never be paid down."""
        self._make_repo_with_a_base()
        with open(self._skips(), encoding="utf-8") as handle:
            name = sorted(json.load(handle)["allowed"])[0]
        self._rewrite_skips(lambda body: body["allowed"][name].update(
            skips=body["allowed"][name]["skips"] - 1))
        result = self.run_guard()
        self.assertNotIn("CI-SKIPS", result.stderr)

    def test_a_new_guard_claiming_a_skip_fails(self):
        self._make_repo_with_a_base()
        self._rewrite_skips(lambda body: body["allowed"].update(
            {"Scripts/check-something-new.py": {"skips": 1, "why": "because"}}))
        result = self.run_guard()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("check-something-new.py", result.stderr)

    def test_removing_from_a_waiver_list_passes(self):
        os.remove(os.path.join(self.root, "docs", "observations", "2000-01-01-seeded.json"))
        self.without_canon([])
        result = self.run_guard()
        self.assertEqual(result.returncode, 0, result.stderr)

    # -- the base the ratchets are measured against ---------------------------------------------
    def test_a_waiver_absent_at_the_base_is_ratcheted_against_the_last_ancestor_carrying_it(self):
        """Delete-then-restore must not become the new base.

        `_at_base` returned None both when the file is NEW and when the merge base does not carry
        it, and the caller skipped for both. So a pair of commits -- delete the waiver, restore it
        with anything written in -- handed the ratchet whatever the restored file said. The walk is
        the one `check-observation-ratchets.py` already does one directory over.
        """
        self._make_repo_with_a_base()                       # commit 1 carries the waiver
        waiver = os.path.join(self.root, "docs", "canon", "WITHOUT-CANON.json")
        os.remove(waiver)
        self._git("add", "-A")
        self._git("commit", "-q", "-m", "delete the waiver")
        self.without_canon(["docs/observations/2000-01-01-seeded.json",
                            "docs/observations/2026-09-15-new.json"])
        self.record("2026-09-15-new.json", {"schema": 1, "id": "new"})
        result = self.run_guard()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("may only SHRINK", result.stderr)
        self.assertIn("last ancestor carrying it", result.stderr)

    def test_a_list_no_ancestor_ever_carried_says_its_ratchet_did_not_run(self):
        """The honest bootstrap, and it must be audible.

        Every ratchet introduced on this branch was silent for this reason, which is how rule 14
        and rule 7 came to contradict each other with nothing firing.
        """
        self._make_repo_with_a_base()
        path = os.path.join(self.root, "docs", "canon", "BRAND-NEW-LIST.json")
        with open(path, "w", encoding="utf-8") as handle:
            json.dump({"prefixes": ["Sources/"]}, handle)
        guard = os.path.join(self.root, "Scripts", "check-canon-citations.py")
        with open(guard, encoding="utf-8") as handle:
            body = handle.read()
        body = body.replace('    ("docs/canon/CI-GATE.json", "required_commands", "grow",',
                            '    ("docs/canon/BRAND-NEW-LIST.json", "prefixes", "grow", "a new list"),\n'
                            '    ("docs/canon/CI-GATE.json", "required_commands", "grow",', 1)
        self.assertIn("BRAND-NEW-LIST", body, "the ratchet table anchor moved; this case is inert")
        with open(guard, "w", encoding="utf-8") as handle:
            handle.write(body)
        result = self.run_guard()
        self.assertIn("BRAND-NEW-LIST.json is carried by neither", result.stderr)
        self.assertIn("does not run here", result.stderr)

    def test_a_shallow_checkout_under_ci_fails_rather_than_degrading(self):
        # Remove the repository setUp made: this case is about the state a shallow clone leaves,
        # where no merge base resolves.
        shutil.rmtree(os.path.join(self.root, ".git"), ignore_errors=True)
        env = dict(os.environ, CI="true")
        result = subprocess.run(
            [sys.executable, os.path.join(self.root, "Scripts", "check-canon-citations.py")],
            capture_output=True, text=True, env=env)
        self.assertEqual(result.returncode, 1)
        self.assertIn("fetch-depth: 0", result.stderr)

    # -- rule 9: a citation must be load-bearing -------------------------------------------------
    def test_a_citation_with_no_binding_fails(self):
        self.record("2026-09-15-unbound.json", {
            "schema": 3, "id": "unbound",
            "canon": [{"ref": REAL_REF, "value": REAL_VALUE, "used_for": "y"}]})
        result = self.run_guard()
        self.assertEqual(result.returncode, 1)
        self.assertIn("`binding` is required", result.stderr)

    def test_a_citation_nothing_in_the_record_refers_to_fails(self):
        """Citing is not using. The record must mention the value or its key somewhere else."""
        self.record("2026-09-15-decorative.json", {
            "schema": 3, "id": "decorative",
            "canon": [{"ref": REAL_REF, "value": REAL_VALUE, "used_for": "y",
                       "binding": {"kind": "record"}}],
            "observations": [{"what": "nothing to do with the citation"}]})
        result = self.run_guard()
        self.assertEqual(result.returncode, 1)
        self.assertIn("decorative", result.stderr)

    def test_a_code_binding_whose_file_lacks_the_value_fails(self):
        self.record("2026-09-15-wrong-file.json", {
            "schema": 3, "id": "wrong-file",
            "canon": [{"ref": REAL_REF, "value": REAL_VALUE, "used_for": "y",
                       "binding": {"kind": "code", "path": "Scripts/nibarchive.py"}}]})
        result = self.run_guard()
        self.assertEqual(result.returncode, 1)
        self.assertIn("does not contain it", result.stderr)

    def test_a_code_binding_naming_a_file_that_does_not_exist_fails(self):
        self.record("2026-09-15-no-file.json", {
            "schema": 3, "id": "no-file",
            "canon": [{"ref": REAL_REF, "value": REAL_VALUE, "used_for": "y",
                       "binding": {"kind": "code", "path": "Scripts/nope.swift"}}]})
        result = self.run_guard()
        self.assertEqual(result.returncode, 1)
        self.assertIn("does not exist", result.stderr)

    # -- rule 10: the committed artefacts are pinned ---------------------------------------------
    def test_an_edited_index_fails(self):
        """The whole offline check rests on these bytes, and an edited file looks like a built one."""
        path = os.path.join(self.root, "docs", "canon", "index", "quickhelp.tsv")
        with open(path, "a", encoding="utf-8") as handle:
            handle.write("QuickHelp\tko\tINVENTED\tcomposed\t000000000000\n")
        result = self.run_guard()
        self.assertEqual(result.returncode, 1)
        self.assertIn("does not match the digest", result.stderr)

    def test_a_truncated_absence_set_fails(self):
        path = os.path.join(self.root, "docs", "canon", "absence", "quickhelp.ko.u32")
        with open(path, "rb") as handle:
            blob = handle.read()
        with open(path, "wb") as handle:
            handle.write(blob[:len(blob) - 4])
        result = self.run_guard()
        self.assertEqual(result.returncode, 1)
        self.assertIn("does not match the digest", result.stderr)

    def test_a_manifest_with_no_artifacts_block_fails(self):
        path = os.path.join(self.root, "docs", "canon", "MANIFEST.json")
        with open(path, "r", encoding="utf-8") as handle:
            manifest = json.load(handle)
        manifest.pop("artifacts", None)
        with open(path, "w", encoding="utf-8") as handle:
            json.dump(manifest, handle)
        result = self.run_guard()
        self.assertEqual(result.returncode, 1)
        self.assertIn("carries no `artifacts` block", result.stderr)

    # -- rule 8: one Logic, not two --------------------------------------------------------------
    def test_an_index_pinning_a_different_logic_than_the_ledger_fails(self):
        os.makedirs(os.path.join(self.root, "docs", "observations"), exist_ok=True)
        with open(os.path.join(self.root, "docs", "observations", "LOGIC-BUILD.json"),
                  "w", encoding="utf-8") as handle:
            json.dump({"app": "Logic Pro", "version": "99.9", "build": "1"}, handle)
        result = self.run_guard()
        self.assertEqual(result.returncode, 1)
        self.assertIn("must describe the same application", result.stderr)

    # -- rule 3 again, now that absence must search everything -----------------------------------
    def test_an_absence_that_skips_a_pinned_corpus_fails(self):
        self.record("2026-09-15-cherry-picked.json", {
            "schema": 3, "id": "cherry-picked",
            "canon_absent": [{"claim": "c", "strings": ["a string nothing writes 91xq"],
                              "searched": [{"source": "quickhelp", "locale": "ko"}],
                              "why_runtime": "r"}],
            "host": {"locale": "ko-KR"}})
        result = self.run_guard()
        self.assertEqual(result.returncode, 1)
        self.assertIn("must search EVERY corpus", result.stderr)


class TheGapsReviewFound(unittest.TestCase):
    """One case per hole that was open after the first five reviews, found on a second pass."""

    def _check(self, body, changed=None):
        handle = tempfile.NamedTemporaryFile("w", suffix=".md", delete=False, encoding="utf-8")
        handle.write(body)
        handle.close()
        self.addCleanup(os.remove, handle.name)
        args = [sys.executable, GUARD, "--text", handle.name]
        if changed is not None:
            ch = tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False, encoding="utf-8")
            ch.write("\n".join(changed))
            ch.close()
            self.addCleanup(os.remove, ch.name)
            args += ["--changed", ch.name]
        return subprocess.run(args, capture_output=True, text=True)

    def test_an_empty_changed_list_fails_closed(self):
        """The CI step's `||` fallback can produce one, and it used to REOPEN the opt-out."""
        result = self._check("This states no fact about Logic.\n", changed=[])
        self.assertEqual(result.returncode, 1)
        self.assertIn("cannot be derived", result.stderr)

    def test_the_opt_out_is_refused_when_the_body_quotes_something_citable(self):
        """An issue changes no files, so this is the only check available there."""
        result = self._check(f'Logic shows "{REAL_VALUE}" here. This states no fact about Logic.\n')
        self.assertEqual(result.returncode, 1)
        self.assertIn("quotes", result.stderr)

    def test_a_body_that_opts_out_and_quotes_nothing_citable_passes(self):
        result = self._check("This renames a private helper and states no fact about Logic.\n")
        self.assertEqual(result.returncode, 0, result.stderr)


class AValueCitationInABody(unittest.TestCase):
    """`Count In` and `Audio Units` are both `logic-canon://strings/en#value`.

    A key citation has one row and therefore one digest, so the body check compared against that.
    A value citation names a corpus and a locale; WHICH string is the quote. Comparing against a
    single `committed` digest refused the second citation in a body -- and refused the pull request
    describing the feature that introduced the form.
    """

    def setUp(self):
        spec = importlib.util.spec_from_file_location("canon_guard_values", GUARD)
        self.guard = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.guard)
        self.canon = self.guard.canon
        self.saved = self.canon.load_value_index("strings")
        self.addCleanup(lambda: self.canon.write_value_index("strings", self.saved))
        self.canon.write_value_index("strings", {
            ("en", self.canon.short_digest("Count In")),
            ("en", self.canon.short_digest("Audio Units")),
        })

    def test_one_reference_may_carry_two_different_values(self):
        ref = self.canon.CanonRef.parse("logic-canon://strings/en#value")
        for value in ("Count In", "Audio Units"):
            with self.subTest(value=value):
                self.assertTrue(self.guard._quotes_the_value(f"value:    {value}\n", ref, ""))

    def test_a_value_nobody_pinned_is_refused(self):
        ref = self.canon.CanonRef.parse("logic-canon://strings/en#value")
        self.assertFalse(
            self.guard._quotes_the_value("value:    Not A Shipped String zz91\n", ref, ""))

    def test_the_locale_is_part_of_the_claim(self):
        """`Count In` is pinned for en; citing it as Korean is a different claim and unpinned."""
        ref = self.canon.CanonRef.parse("logic-canon://strings/ko#value")
        self.assertFalse(self.guard._quotes_the_value("value:    Count In\n", ref, ""))


class ARecordMayDeclareTheAxisInapplicable(unittest.TestCase):
    """Rule 13, and the bound that keeps it from becoming a free pass.

    Several records state facts about Logic's BEHAVIOUR -- read order, settle time, which window
    steals a menu. There is no key to cite and nothing to prove absent, and forcing a citation
    there produces a perfunctory one. The declaration is allowed and checked: a record whose
    READINGS quote a string the corpus holds had a citation available, so the claim is false.
    """

    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="canon-na-")
        self.addCleanup(shutil.rmtree, self.root, ignore_errors=True)
        os.makedirs(os.path.join(self.root, "Scripts"))
        os.makedirs(os.path.join(self.root, "docs", "observations"))
        for name in ("logic_canon.py", "check-canon-citations.py", "nibarchive.py"):
            shutil.copy2(os.path.join(REPO, "Scripts", name),
                         os.path.join(self.root, "Scripts", name))
        shutil.copytree(os.path.join(REPO, "docs", "canon"),
                        os.path.join(self.root, "docs", "canon"))
        os.makedirs(os.path.join(self.root, "Sources"), exist_ok=True)
        with open(os.path.join(self.root, "docs", "canon", "WITHOUT-CANON.json"),
                  "w", encoding="utf-8") as handle:
            json.dump({"records": []}, handle)
        subprocess.run(["git", "init", "-q", "-b", "main"], cwd=self.root)
        subprocess.run(["git", "config", "user.email", "t@e.com"], cwd=self.root)
        subprocess.run(["git", "config", "user.name", "t"], cwd=self.root)
        subprocess.run(["git", "add", "-A"], cwd=self.root)
        subprocess.run(["git", "commit", "-qm", "base"], cwd=self.root)

    def record(self, body):
        with open(os.path.join(self.root, "docs", "observations", "2026-09-15-probe.json"),
                  "w", encoding="utf-8") as handle:
            json.dump(body, handle, ensure_ascii=False)
        return subprocess.run(
            [sys.executable, os.path.join(self.root, "Scripts", "check-canon-citations.py")],
            capture_output=True, text=True, cwd=self.root)

    def test_a_behaviour_record_may_decline(self):
        result = self.record({"schema": 3, "id": "probe",
                              "canon_not_applicable": {"reason": "read order, not any string"},
                              "observations": [{"what": "twenty three nodes on the second read"}]})
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_a_declaration_without_a_reason_fails(self):
        result = self.record({"schema": 3, "id": "probe",
                              "canon_not_applicable": {},
                              "observations": [{"what": "anything at all here"}]})
        self.assertEqual(result.returncode, 1)
        self.assertIn("reason` is required", result.stderr)

    def test_a_record_quoting_a_citable_string_may_not_decline(self):
        """The bound. Measured against #882: five of its thirteen records are in this case."""
        result = self.record({"schema": 3, "id": "probe",
                              "canon_not_applicable": {"reason": "claims to be about behaviour"},
                              "observations": [{"read": REAL_VALUE}]})
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("A citation was available", result.stderr)

    def test_a_short_fragment_does_not_trigger_the_bound(self):
        """Below the floor a corpus hit means nothing, so it must not refuse the declaration."""
        result = self.record({"schema": 3, "id": "probe",
                              "canon_not_applicable": {"reason": "behaviour"},
                              "observations": [{"role": "AXGroup", "n": 23}]})
        self.assertEqual(result.returncode, 0, result.stderr)


class ABindingIsNotSatisfiedByAComment(unittest.TestCase):
    """The limitation that was written up as needing the strong fix, closed with the cheap one.

    `check_binding` read the whole file, so a value sitting only in a `//` line satisfied a `code`
    binding -- demonstrated by review on an otherwise empty file. Stripping comments closes the
    case that was shown; what it does not close is a value inside a symbol the change never used,
    which still wants the binding to name the symbol.
    """

    def setUp(self):
        spec = importlib.util.spec_from_file_location("canon_guard_comments", GUARD)
        self.guard = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.guard)
        self.path = os.path.join(REPO, "Scripts", "_binding_probe.swift")
        self.addCleanup(lambda: os.path.exists(self.path) and os.remove(self.path))

    def _bind(self, body):
        with open(self.path, "w", encoding="utf-8") as handle:
            handle.write(body)
        citation = {"ref": REAL_REF, "value": REAL_VALUE, "used_for": "probe",
                    "binding": {"kind": "code", "path": "Scripts/_binding_probe.swift"}}
        failures = []
        self.guard.check_binding("probe", citation, {"observations": []}, failures)
        return failures

    def test_a_value_only_in_a_line_comment_is_refused(self):
        self.assertTrue(self._bind(f"// {REAL_VALUE}\nfunc unrelated() {{}}\n"))

    def test_a_value_only_in_a_block_comment_is_refused(self):
        self.assertTrue(self._bind(f"/* {REAL_VALUE} */\nfunc unrelated() {{}}\n"))

    def test_a_value_in_code_passes(self):
        self.assertEqual(self._bind(f'let real = "{REAL_VALUE}"\n'), [])

    def test_a_file_type_with_no_known_comment_syntax_is_read_whole(self):
        """JSON has no comments, so stripping nothing is the honest answer for it."""
        self.assertEqual(self.guard._without_comments("{\"a\": 1}", "x.json"), "{\"a\": 1}")


class LogicFacingIsSelfMaintaining(unittest.TestCase):
    """Rule 14, driven against the real tree because that is what it is pointed at.

    The first attempt at this rule was WRITTEN AND COMMITTED WITHOUT LANDING -- the replacement
    that was supposed to swap a tuple for a file silently matched nothing, the commit message said
    it was fixed, and the tuple was still there. These cases exist so the next such failure is a
    red test rather than a claim.
    """

    def setUp(self):
        spec = importlib.util.spec_from_file_location("canon_guard_rule14", GUARD)
        self.guard = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.guard)
        self.path = self.guard.LOGIC_FACING_PATH
        with open(self.path, encoding="utf-8") as handle:
            self.backup = handle.read()
        self.addCleanup(lambda: open(self.path, "w", encoding="utf-8").write(self.backup))

    def _write(self, prefixes):
        with open(self.path, "w", encoding="utf-8") as handle:
            json.dump({"prefixes": prefixes}, handle, ensure_ascii=False)

    def test_the_real_tree_passes(self):
        failures = []
        self.guard.check_labelsets_are_logic_facing(failures)
        self.assertEqual(failures, [])

    def test_a_labelset_outside_every_prefix_fails(self):
        kept = [p for p in json.loads(self.backup)["prefixes"] if "SelectorAtlas" not in p]
        self._write(kept)
        failures = []
        self.guard.check_labelsets_are_logic_facing(failures)
        self.assertTrue(any("SelectorAtlas" in f for f in failures), failures)

    def test_a_missing_list_fails_closed(self):
        """Empty prefixes would make EVERY change eligible for the opt-out."""
        os.remove(self.path)
        failures = []
        self.guard.check_labelsets_are_logic_facing(failures)
        self.assertTrue(any("is missing" in f for f in failures), failures)

    def test_an_empty_list_fails_closed(self):
        self._write([])
        failures = []
        self.guard.check_labelsets_are_logic_facing(failures)
        self.assertTrue(any("no prefixes" in f for f in failures), failures)

    def test_livekit_swift_is_scanned(self):
        """`Scripts/livekit` holds Swift that matches Logic and was not looked at."""
        self.assertIn(os.path.join("Scripts", "livekit"), self.guard.SWIFT_ROOTS)


class PullRequestBody(unittest.TestCase):
    """--text mode. The rule was NAMED for pull requests and enforced only for files."""

    def _check(self, body):
        handle = tempfile.NamedTemporaryFile("w", suffix=".md", delete=False, encoding="utf-8")
        handle.write(body)
        handle.close()
        self.addCleanup(os.remove, handle.name)
        return subprocess.run([sys.executable, GUARD, "--text", handle.name],
                              capture_output=True, text=True)

    def _check_changed(self, body, changed):
        handle = tempfile.NamedTemporaryFile("w", suffix=".md", delete=False, encoding="utf-8")
        handle.write(body)
        handle.close()
        self.addCleanup(os.remove, handle.name)
        listing = tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False, encoding="utf-8")
        listing.write("\n".join(changed) + "\n")
        listing.close()
        self.addCleanup(os.remove, listing.name)
        return subprocess.run(
            [sys.executable, GUARD, "--text", handle.name, "--changed", listing.name],
            capture_output=True, text=True)

    def test_a_citation_that_bears_on_nothing_changed_is_refused(self):
        """A resolving reference used to be enough, whatever the change was about.

        Paste any valid citation, change two Logic-facing files that have nothing to do with it,
        and the body printed "1 citation(s) resolved". The rule says "cite what those claims rest
        on" and enforced "cite something".
        """
        policy = os.path.join("Sources", "LogicProMCP", "Accessibility", "AXLocalePolicy.swift")
        result = self._check_changed(
            f"before\n{REAL_REF}\n{REAL_VALUE}\nafter\n", [policy])
        if REAL_REF in open(os.path.join(REPO, policy), encoding="utf-8").read():
            self.skipTest("the module-level fixture reference is used by the policy, so it BEARS "
                          "on it -- this case needs one that does not, and picking one here would "
                          "be reading the index to build a fixture from it")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("bears on", result.stderr)

    def test_a_citation_the_change_uses_is_accepted(self):
        """The control. The reference is in the file the change touches, which is what a
        `derivedFrom` gives by construction."""
        policy = os.path.join("Sources", "LogicProMCP", "Accessibility", "AXLocalePolicy.swift")
        source = open(os.path.join(REPO, policy), encoding="utf-8").read()
        spec = importlib.util.spec_from_file_location(
            "logic_canon_for_case", os.path.join(REPO, "Scripts", "logic_canon.py"))
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        used = list(module.find_refs(source))
        self.assertTrue(used, "the policy declares no derivedFrom, so this case checks nothing")
        ref = used[0]
        body = f"before\n{REAL_REF}\n{REAL_VALUE}\nand this change rests on\n{ref}\n"
        result = self._check_changed(body, [policy])
        # It may still fail on the quoted-value rule for `ref`; what must NOT appear is the
        # binding complaint, because `ref` is in the changed file.
        self.assertNotIn("bears on", result.stderr)

    def test_a_body_with_a_resolving_citation_and_its_value_passes(self):
        result = self._check(f"before\n{REAL_REF}\n  value: {REAL_VALUE}\nafter\n")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_a_reference_without_its_value_fails(self):
        result = self._check(f"we rely on {REAL_REF} here\n")
        self.assertEqual(result.returncode, 1)
        self.assertIn("appears without the value", result.stderr)

    def test_a_wrong_value_is_refused_the_same_way_a_missing_one_is(self):
        """Named for what the code does, not for a discrimination it does not make.

        `_quotes_the_value` asks whether SOME line hashes to the committed digest, so in `--text`
        mode a wrong value and an absent value are one event. The case used to be called
        `test_a_wrong_value_fails` and asserted only the exit code, which would have passed on any
        failure at all. Review 2026-09-15 read the stderr and found it identical in kind to its
        neighbour's.
        """
        result = self._check(f"{REAL_REF}\n  value: {REAL_VALUE}x\n")
        self.assertEqual(result.returncode, 1)
        self.assertIn("appears without the value it resolves to", result.stderr)

    def test_a_body_with_nothing_fails(self):
        result = self._check("just a description of a refactor\n")
        self.assertEqual(result.returncode, 1)
        self.assertIn("no opt-out", result.stderr)

    def test_the_opt_out_sentence_passes(self):
        result = self._check("This states no fact about Logic; it renames a private helper.\n")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_an_unresolvable_reference_fails(self):
        result = self._check(
            "logic-canon://quickhelp/QuickHelp/ko/NOT_A_KEY#composed\n  value: whatever\n")
        self.assertEqual(result.returncode, 1)
        self.assertIn("is not in docs/canon/index", result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
