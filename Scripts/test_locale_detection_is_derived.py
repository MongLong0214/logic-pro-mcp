#!/usr/bin/env python3
"""Drive `check-locale-detection-is-derived.py` with the defects it names.

Each case injects one and asserts the guard reports it, then asserts the real table does not. A
guard that only ever sees a correct table has never been shown to be able to fail, and this one
stands between the product and the answer `unknown` for seven of the ten languages Logic ships.

The most important case is `Datei`. It is the German word for `File`, it is what a person would
type, and it is what the OTHER row whose English is `File` says — so a guard that merely checked
"is this a German word Apple ships" would pass it. The macOS German menu bar says `Ablage`.
"""
import importlib.util
import os
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


guard = _load("locale_detection_guard", "check-locale-detection-is-derived.py")
canon = _load("logic_canon_for_locale_detection_test", "logic_canon.py")


def _source():
    with open(guard.SWIFT, encoding="utf-8") as handle:
        return handle.read()


class TheGuardReadsTheRealTable(unittest.TestCase):
    def test_the_committed_table_passes(self):
        self.assertEqual(guard.check(_source(), canon), [])

    def test_it_parses_every_locale_logic_ships(self):
        table = guard.parse_table(_source())
        self.assertEqual({locale for locale, _ in table}, set(guard.LOCALE_OF))

    def test_the_pinned_digests_are_actually_there(self):
        """Without this the guard could pass by finding nothing to compare."""
        index = canon.load_index("strings")
        for locale, short in guard.LOCALE_OF.items():
            for key in guard.KEYS:
                self.assertIn((guard.UNIT, short, key, "value"), index,
                              f"{locale}/{key} is not pinned, so the guard checks nothing for it")


class TheGuardCatchesWhatItNames(unittest.TestCase):
    def _mutated(self, old, new):
        source = _source()
        self.assertIn(old, source, "the mutation did not apply, so this case proves nothing")
        return guard.check(source.replace(old, new, 1), canon)

    def test_a_plausible_wrong_translation_is_refused(self):
        """`Datei` is German for `File`, is what the other `File` row says, and is not the menu."""
        failures = self._mutated('"Ablage", "Bearbeiten", "Spur"', '"Datei", "Bearbeiten", "Spur"')
        self.assertTrue(any("Datei" in failure and "de-DE" in failure for failure in failures),
                        failures)

    def test_a_missing_locale_is_refused(self):
        failures = self._mutated('("zh-TW", ["檔案", "編輯", "音軌"]),', "")
        self.assertTrue(any("zh-TW" in failure for failure in failures), failures)

    def test_two_locales_that_cannot_be_told_apart_are_refused(self):
        failures = self._mutated('"文件", "编辑", "轨道"', '"檔案", "編輯", "音軌"')
        self.assertTrue(failures, "a table with two identical rows was accepted")

    def test_a_short_row_is_refused(self):
        failures = self._mutated('"Archivo", "Edición", "Pista"', '"Archivo", "Edición"')
        self.assertTrue(any("expected" in failure for failure in failures), failures)

    def test_a_locale_logic_does_not_ship_is_refused(self):
        failures = self._mutated('("zh-TW"', '("xx-XX"')
        self.assertTrue(any("xx-XX" in failure for failure in failures), failures)

    def test_a_table_it_cannot_read_is_refused_rather_than_passed(self):
        """Silence on an unreadable table is how a guard reports clean on a tree it never saw."""
        failures = guard.check("no table here", canon)
        self.assertTrue(failures)




class TheEntryPointRefuses(unittest.TestCase):
    """The cases above call the guard's helpers. A `main()` returning 0 without ever calling them
    passed all of them, because the repository passes -- `Scripts/mutation-sweep-guard-tests.py`
    measured that on 2026-09-18. `LPM_POLICY_SWIFT` is the seam.
    """

    def _run(self, **env):
        import subprocess
        here = os.path.dirname(os.path.abspath(__file__))
        return subprocess.run(
            [sys.executable, os.path.join(here, "check-locale-detection-is-derived.py")],
            capture_output=True, text=True, env=dict(os.environ, **env))

    def test_a_detection_label_that_is_not_the_rows_value_is_refused(self):
        here = os.path.dirname(os.path.abspath(__file__))
        real = os.path.join(os.path.dirname(here), "Sources", "LogicProMCP", "Accessibility",
                            "AXLocalePolicy.swift")
        source = open(real, encoding="utf-8").read()
        assert '"\ud30c\uc77c"' in source
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "Policy.swift")
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(source.replace('"\ud30c\uc77c"', '"NotTheFileMenu"', 1))
            proc = self._run(LPM_POLICY_SWIFT=path)
            self.assertEqual(proc.returncode, 1, (proc.stdout + proc.stderr)[:300])

    def test_the_repositorys_own_policy_is_accepted(self):
        """The control."""
        proc = self._run()
        self.assertEqual(proc.returncode, 0, (proc.stdout + proc.stderr)[:300])


if __name__ == "__main__":
    unittest.main(verbosity=2)
