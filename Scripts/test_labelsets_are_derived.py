#!/usr/bin/env python3
"""Drive `check-labelsets-are-derived.py` with the defects it names.

The case that matters most is the first: a LabelSet carrying three languages, pointed at a row that
has ten. That is the shape of #892 -- a label somebody measured in Korean, Japanese and German,
matching nothing in the other six languages Logic ships, with no count anywhere saying so.

The second most important is structural. The reader must parse EVERY declaration or refuse: a guard
that silently covers 153 of 155 reports clean over a tree it never examined, and the two it first
missed were ordinary Swift.
"""
import importlib.util
import os
import re
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)


def _load(name, filename):
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


guard = _load("labelsets_derived_guard", "check-labelsets-are-derived.py")
canon = _load("logic_canon_for_labelset_test", "logic_canon.py")


def _source():
    with open(guard.SWIFT, encoding="utf-8") as handle:
        return handle.read()


class TheReaderSeesEveryDeclaration(unittest.TestCase):
    def test_it_parses_all_of_them_or_none(self):
        source = _source()
        declared = set(re.findall(r"static let ([A-Za-z0-9_]+) = LabelSet\(", source))
        parsed = {name for name, _, _ in guard.declarations(source)}
        self.assertEqual(parsed, declared,
                         "a LabelSet this reader skips is one the guard does not check")

    def test_a_multi_line_rationale_does_not_hide_a_declaration(self):
        """`deleteTracksPrimaryButton` uses a `\"\"\"` rationale and defeated the first reader."""
        parsed = dict((name, members) for name, members, _ in guard.declarations(_source()))
        self.assertIn("deleteTracksPrimaryButton", parsed)
        self.assertIn("삭제", parsed["deleteTracksPrimaryButton"])

    def test_a_concatenated_rationale_does_not_hide_a_declaration(self):
        """`transportKeywordFalseFriends` builds its rationale with `+` and defeated it too."""
        parsed = dict((name, members) for name, members, _ in guard.declarations(_source()))
        self.assertIn("transportKeywordFalseFriends", parsed)

    def test_a_declaration_it_cannot_read_raises_instead_of_being_skipped(self):
        broken = 'static let x = LabelSet(\n    rationale: "no canonical here"\n)'
        with self.assertRaises(guard.UnreadableDeclaration):
            list(guard.declarations(broken))


class TheGuardCatchesWhatItNames(unittest.TestCase):
    def test_the_committed_tree_passes(self):
        failures, checked = guard.check(_source(), canon)
        self.assertEqual(failures, [])
        self.assertGreater(checked, 0, "no LabelSet names a row, so the guard checked nothing")

    def _mutated(self, old, new):
        source = _source()
        self.assertIn(old, source, "the mutation did not apply, so this case proves nothing")
        return guard.check(source.replace(old, new, 1), canon)[0]

    def test_a_label_that_covers_three_languages_of_ten_is_named(self):
        """#892 in one case: the LabelSet as it stood before derivation, against its own row."""
        failures = self._mutated(
            '"파일", "ファイル", "Ablage", "Archivo", "Fichier", "Arquivo", "文件", "檔案"',
            '"파일", "ファイル", "Ablage"')
        self.assertTrue(failures, "a three-language LabelSet passed a ten-locale check")
        self.assertIn("fileMenuBar", failures[0])
        for locale in ("es", "fr", "pt", "zh_CN", "zh_TW"):
            self.assertIn(locale, failures[0])

    def test_a_row_nobody_pinned_is_refused(self):
        failures = self._mutated("/en/File%23mti#value", "/en/NoSuchKey%23mti#value")
        self.assertTrue(any("not pinned" in failure for failure in failures), failures)

    def test_a_reference_with_no_key_is_refused(self):
        failures = self._mutated("/en/File%23mti#value", "/en#value")
        self.assertTrue(failures)

    def test_a_labelset_with_no_reference_is_not_checked_and_not_counted(self):
        source = _source()
        _, checked = guard.check(source, canon)
        total = sum(1 for _ in guard.declarations(source))
        self.assertLess(checked, total,
                        "every LabelSet names a row, so this case no longer distinguishes anything")


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
    def test_a_member_that_is_not_the_rows_value_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            real = os.path.join(REPO_ROOT, "Sources", "LogicProMCP", "Accessibility",
                                "AXLocalePolicy.swift")
            source = open(real, encoding="utf-8").read()
            assert source.count('"리전"') >= 1
            path = os.path.join(tmp, "Policy.swift")
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(source.replace('"리전"', '"NotWhatAppleShips"', 1))
            proc = self._run("check-labelsets-are-derived.py", LPM_POLICY_SWIFT=path)
            self.assertEqual(proc.returncode, 1, (proc.stdout + proc.stderr)[:300])

    def test_the_repositorys_own_policy_is_accepted(self):
        """The control."""
        proc = self._run("check-labelsets-are-derived.py")
        self.assertEqual(proc.returncode, 0, (proc.stdout + proc.stderr)[:300])


if __name__ == "__main__":
    unittest.main(verbosity=2)
