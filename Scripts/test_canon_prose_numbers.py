#!/usr/bin/env python3
"""Cases for `check-canon-prose-numbers.py`.

Every one of these was run by hand while the guard was written, and the third is the reason the
guard exists in the shape it does: the obvious implementation passes the exact defect it was
written for.

Driven against temporary trees, so the real `docs/canon/README.md` is neither read nor written.
"""
import importlib.util
import json
import os
import shutil
import sys
import tempfile
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_spec = importlib.util.spec_from_file_location(
    "canon_prose_numbers", os.path.join(REPO, "Scripts", "check-canon-prose-numbers.py"))
guard = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(guard)


class ProseNumbers(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="prose-numbers-")
        self.addCleanup(shutil.rmtree, self.root, ignore_errors=True)
        for part in (("docs", "canon"), ("docs", "observations"), ("Scripts",)):
            os.makedirs(os.path.join(self.root, *part), exist_ok=True)
        self._write("docs/canon/SOURCES.json", json.dumps({"sources": {"strings": {"entries": 605190}}}))
        self._write("docs/canon/MANIFEST.json", json.dumps({"sources": {"strings": {"absence_entries": {"ko": 47115}}}}))
        self._write("docs/observations/a-record.json", json.dumps({"observations": [{"what": "keys", "count": 9835}]}))
        self._write("docs/canon/PROSE-NUMBERS.json", json.dumps({"numbers": {}}))
        self._write("docs/canon/README.md", "The corpus holds 605,190 entries.\n")

    def _write(self, rel, text):
        path = os.path.join(self.root, *rel.split("/"))
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(text)

    def _readme(self, text):
        self._write("docs/canon/README.md", text)

    def test_the_baseline_passes(self):
        """Or every case below proves nothing."""
        self.assertEqual(guard.problems(self.root), [])

    def test_a_number_from_an_artifact_passes(self):
        self._readme("One corpus holds 47,115 values and another 605,190.\n")
        self.assertEqual(guard.problems(self.root), [])

    def test_a_number_from_a_record_passes(self):
        self._readme("QuickHelp carries 9,835 keys.\n")
        self.assertEqual(guard.problems(self.root), [])

    def test_a_number_from_nowhere_fails(self):
        self._readme("The corpus holds 8,675,309 entries.\n")
        found = guard.problems(self.root)
        self.assertTrue(any("8675309" in line for line in found), found)

    def test_source_prose_does_not_back_a_number(self):
        """THE CASE THIS GUARD EXISTS FOR.

        295,050 was retracted IN `logic_canon.py`, by a sentence that contains it. A haystack made
        of the tree rather than of artifacts calls that backed, so the defect survives the check
        written to catch it.
        """
        self._write("Scripts/logic_canon.py",
                    "# an earlier docstring said 8675309, which was arithmetic and wrong\n")
        self._readme("The corpus holds 8,675,309 entries.\n")
        found = guard.problems(self.root)
        self.assertTrue(any("8675309" in line for line in found),
                        f"source prose must not count as backing: {found!r}")

    def test_a_declared_number_passes(self):
        self._write("docs/canon/PROSE-NUMBERS.json",
                    json.dumps({"numbers": {"8675309": "measured by breaking something in <sha>"}}))
        self._readme("The corpus holds 8,675,309 entries.\n")
        self.assertEqual(guard.problems(self.root), [])

    def test_a_declaration_written_with_separators_still_matches(self):
        """`"8,675,309"` and `8675309` are the same number; a waiver keyed either way must work."""
        self._write("docs/canon/PROSE-NUMBERS.json",
                    json.dumps({"numbers": {"8,675,309": "measured in <sha>"}}))
        self._readme("The corpus holds 8,675,309 entries.\n")
        self.assertEqual(guard.problems(self.root), [])

    def test_three_digits_and_below_are_not_checked(self):
        """A sentence carries "ten locales" and "113 of 114" on its own; checking those would mean
        declaring every ordinary count in the document."""
        self._readme("113 of 114 readings resolve across 10 locales and 4 sources.\n")
        self.assertEqual(guard.problems(self.root), [])

    def test_a_comma_separated_pair_is_read_as_one_number(self):
        """A KNOWN LIMIT, pinned so it is visible rather than discovered.

        `TrackDispatcher:127,166` means lines 127 and 166, and the thousands-separator pattern
        reads it as 127,166. Nothing distinguishes the two without knowing the sentence. It is
        tolerable only because the scope is `docs/canon/README.md`, where a comma between digits is
        a thousands separator by convention -- and it is the concrete reason the scope is not
        widened to files full of `file.swift:12,34` citations.
        """
        self._readme("See AccessibilityChannel:127,166 for the two call sites.\n")
        found = guard.problems(self.root)
        self.assertTrue(any("127166" in line for line in found),
                        f"the limit is real; if this ever passes the pattern changed: {found!r}")

    def test_an_empty_haystack_refuses_rather_than_accepting_everything(self):
        """A reader that finds nothing would pass any number at all -- silently."""
        os.remove(os.path.join(self.root, "docs", "canon", "SOURCES.json"))
        os.remove(os.path.join(self.root, "docs", "canon", "MANIFEST.json"))
        os.remove(os.path.join(self.root, "docs", "observations", "a-record.json"))
        self._readme("The corpus holds 8,675,309 entries.\n")
        found = guard.problems(self.root)
        self.assertTrue(any("would accept anything" in line for line in found), found)

    def test_a_missing_readme_is_a_failure_not_a_pass(self):
        os.remove(os.path.join(self.root, "docs", "canon", "README.md"))
        found = guard.problems(self.root)
        self.assertTrue(any("is missing" in line for line in found), found)

    def test_the_real_readme_passes(self):
        """The guard is pointed at the tree it ships in, not only at fixtures."""
        self.assertEqual(guard.problems(REPO), [])


class TheEntryPointRefuses(unittest.TestCase):
    """Every case above calls `problems()`. A `main()` that returned 0 without ever calling it
    would pass all of them, because the repository passes -- `Scripts/mutation-sweep-guard-tests.py`
    measured that on 2026-09-18. A guard is its entry point, so these drive it.

    `LPM_CANON_REPO` is a ROOT rather than a README path: `problems()` derives the README, the
    artifacts and the records from one root, and pointing only the README elsewhere would check a
    fixture against the real repository's numbers.
    """

    def _root(self, readme_text):
        root = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, root, True)
        canon = os.path.join(root, "docs", "canon")
        os.makedirs(canon)
        with open(os.path.join(canon, "MANIFEST.json"), "w", encoding="utf-8") as handle:
            json.dump({"sources": {"strings": {"entries": 605190}}}, handle)
        with open(os.path.join(canon, "PROSE-NUMBERS.json"), "w", encoding="utf-8") as handle:
            json.dump({"numbers": {}}, handle)
        with open(os.path.join(canon, "README.md"), "w", encoding="utf-8") as handle:
            handle.write(readme_text)
        return root

    def _run(self, root):
        import subprocess
        return subprocess.run(
            [sys.executable, os.path.join(REPO, "Scripts", "check-canon-prose-numbers.py")],
            capture_output=True, text=True, env=dict(os.environ, LPM_CANON_REPO=root))

    def test_a_number_from_nowhere_is_refused(self):
        proc = self._run(self._root("The corpus holds 987654 entries nobody wrote down.\n"))
        self.assertEqual(proc.returncode, 1, (proc.stdout + proc.stderr)[:300])
        self.assertIn("987654", proc.stdout + proc.stderr)

    def test_a_number_the_manifest_carries_is_accepted(self):
        """The control. Without it the case above passes on a guard that refuses every number."""
        proc = self._run(self._root("The corpus holds 605190 entries.\n"))
        self.assertEqual(proc.returncode, 0, (proc.stdout + proc.stderr)[:300])


class CountsOfCorpora(unittest.TestCase):
    """A count of corpora is the one quantity here the digit rule cannot see.

    `A_BIG_NUMBER` starts at four digits, and there are 24 corpora. That is not a gap somebody
    might have: README line 159 said `Input Port:` is "absent from all 23 corpora" while the
    manifest pinned 24, and line 139 said in prose that number WORDS were invisible -- naming a
    gap is not closing it.
    """

    def _root(self, readme_text, corpora=3, rows=2, declared=None):
        root = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, root, True)
        canon = os.path.join(root, "docs", "canon")
        os.makedirs(os.path.join(canon, "index"))
        artifacts = {f"absence/strings.l{n}.u32": "0" * 8 for n in range(corpora)}
        with open(os.path.join(canon, "MANIFEST.json"), "w", encoding="utf-8") as handle:
            json.dump({"sources": {"strings": {"entries": 605190}}, "artifacts": artifacts}, handle)
        with open(os.path.join(canon, "index", "strings.tsv"), "w", encoding="utf-8") as handle:
            handle.write("key\tlocale\tvalue\n")
            for n in range(rows):
                handle.write(f"k{n}\tl{n}\tv{n}\n")
        with open(os.path.join(canon, "PROSE-NUMBERS.json"), "w", encoding="utf-8") as handle:
            json.dump({"numbers": declared or {}}, handle)
        with open(os.path.join(canon, "README.md"), "w", encoding="utf-8") as handle:
            handle.write(readme_text)
        return root

    def test_all_n_corpora_must_be_every_corpus(self):
        found = guard.problems(self._root("It is absent from all 2 corpora.\n"))
        self.assertTrue(any("all 2 corpora" in line for line in found), found)

    def test_all_n_corpora_at_the_manifests_count_passes(self):
        """The control. Without it the case above passes on a rule that refuses every sentence."""
        self.assertEqual(guard.problems(self._root("It is absent from all 3 corpora.\n")), [])

    def test_a_count_of_corpora_written_as_a_word_is_read(self):
        found = guard.problems(self._root("The manifest carries twenty-four corpora.\n"))
        self.assertTrue(any("twenty-four corpora" in line for line in found), found)

    def test_the_two_legitimate_denominators_pass(self):
        """How many exist, and how many carry a row. The document uses both."""
        self.assertEqual(guard.problems(
            self._root("The manifest carries three corpora and two of the corpora carry a row.\n")), [])

    def test_a_declared_count_is_excused(self):
        """A retraction QUOTES the number it retracts, and this file quotes several."""
        self.assertEqual(guard.problems(
            self._root("It used to say all 2 corpora.\n", declared={"2": "quoted from a retraction"})), [])

    def test_a_sentence_that_names_no_count_is_left_alone(self):
        self.assertEqual(guard.problems(self._root("The corpora are pinned by the manifest.\n")), [])

    def test_counting_corpora_against_a_manifest_that_names_none_is_refused(self):
        """Abstaining here would report clean on a broken reader."""
        root = self._root("It is absent from all 3 corpora.\n")
        with open(os.path.join(root, "docs", "canon", "MANIFEST.json"), "w", encoding="utf-8") as h:
            json.dump({"sources": {"strings": {"entries": 605190}}, "artifacts": {}}, h)
        found = guard.problems(root)
        self.assertTrue(any("MANIFEST.json names none" in line for line in found), found)


if __name__ == "__main__":
    unittest.main(verbosity=2)
