#!/usr/bin/env python3
"""Cases for `check-ax-comparisons-use-labelsets.py`.

Every one of these was run by hand while the guard was written, and two of them are defects the
guard had. It reported 11 findings of which 9 were internal identifiers — `if name == "Stop"`,
where `name` is this product's own command name — and its separator rule could never pass, because
it upper-cased the haystack and then looked for a lowercase `\\u` escape in it.
"""
import importlib.util
import os
import tempfile
import json
import subprocess
import sys
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_spec = importlib.util.spec_from_file_location(
    "ax_comparisons", os.path.join(REPO, "Scripts", "check-ax-comparisons-use-labelsets.py"))
guard = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(guard)


class TracingAReadingToTheAccessibilityAPI(unittest.TestCase):
    """Condition 1: the variable must actually hold something AX returned."""

    def test_a_variable_read_from_ax_is_traced(self):
        source = 'let title = AXHelpers.getTitle(cb, runtime: r)\nif title == "Stop" { }'
        self.assertIn("title", guard.ax_backed_names(source))

    def test_a_parameter_named_name_is_not_an_ax_reading(self):
        """The defect that produced 9 of 11 findings. `name` here is a command name."""
        source = 'static func toggle(named name: String) {\n  if name == "Stop" { }\n}'
        self.assertNotIn("name", guard.ax_backed_names(source))

    def test_a_catalogue_constant_is_not_an_ax_reading(self):
        source = 'let bandName = band.displayName\nif bandName.hasSuffix("Cut") { }'
        self.assertNotIn("bandName", guard.ax_backed_names(source))


class SeparatorsAreNotLabels(unittest.TestCase):
    """A literal made only of punctuation names no control, so a LabelSet is the wrong home.

    What it must do is handle every spelling Apple ships: a Chinese Logic writes the full-width
    `\uff1a` where the others write `:`.
    """

    def _file(self, text):
        handle = tempfile.NamedTemporaryFile("w", suffix=".swift", delete=False,
                                             dir=REPO, encoding="utf-8")
        handle.write(text)
        handle.close()
        self.addCleanup(os.unlink, handle.name)
        return os.path.relpath(handle.name, REPO)

    def test_the_table_supplies_more_than_one_spelling(self):
        groups = guard.separator_groups()
        self.assertTrue(any(":" in g and "\uff1a" in g for g in groups),
                        "DECORATION-RULES.json must carry both colons or this rule is inert")

    def test_handling_only_the_ascii_spelling_fails(self):
        path = self._file('if value.contains(":") { }\n')
        self.assertFalse(guard.handles_every_spelling(":", [path]))

    def test_handling_both_spellings_passes(self):
        path = self._file('if value.contains(":") || value.contains("\\u{FF1A}") { }\n')
        self.assertTrue(guard.handles_every_spelling(":", [path]))

    def test_the_escape_is_matched_case_insensitively(self):
        """THE CHECK THAT COULD NOT PASS.

        The first version upper-cased the source and then looked for a lowercase `\\u{ffff}`
        escape in it, so a file spelling the character correctly still failed. Swift writes
        `\\u{FF1A}`; the test is that either case is accepted.
        """
        for spelling in ("\\u{FF1A}", "\\u{ff1a}"):
            with self.subTest(spelling=spelling):
                path = self._file(f'if value.contains(":") || value.contains("{spelling}") {{ }}\n')
                self.assertTrue(guard.handles_every_spelling(":", [path]))

    def test_the_literal_character_also_counts(self):
        path = self._file('if value.contains(":") || value.contains("\uff1a") { }\n')
        self.assertTrue(guard.handles_every_spelling(":", [path]))


class TheGuardActuallyRefusesSomething(unittest.TestCase):
    """THE CASES THIS SUITE DID NOT HAVE.

    Every case above drove a helper, and the only whole-guard assertion was "the repository
    passes" -- which a guard that returns `[]` unconditionally satisfies. An outside review made
    `check()` return `[]` and this suite stayed green: the rule had never been watched refuse
    anything, which is the definition of a decorative guard.

    `LPM_AX_COMPARISON_ROOTS` points the scan at a directory the case builds, so a positive input
    exists at all. The waiver cases use a temporary file: `docs/canon/AX-COMPARISON-WAIVERS.json`
    is deliberately absent from the tree (a waiver hides a defect instead of removing it, and nine
    of the eleven findings it would have carried were this guard's own false positives), and these
    cases must not be the reason it appears.
    """

    def _scan(self, source, waiver=None):
        with tempfile.TemporaryDirectory() as tmp:
            root = os.path.join(tmp, "Sources")
            os.makedirs(root)
            with open(os.path.join(root, "Offender.swift"), "w", encoding="utf-8") as handle:
                handle.write(source)
            before_root = os.environ.get("LPM_AX_COMPARISON_ROOTS")
            before_waiver = guard.WAIVER
            os.environ["LPM_AX_COMPARISON_ROOTS"] = root
            if waiver is not None:
                path = os.path.join(tmp, "waivers.json")
                with open(path, "w", encoding="utf-8") as handle:
                    json.dump({"literals": waiver}, handle)
                guard.WAIVER = path
            try:
                return guard.check()
            finally:
                guard.WAIVER = before_waiver
                if before_root is None:
                    os.environ.pop("LPM_AX_COMPARISON_ROOTS", None)
                else:
                    os.environ["LPM_AX_COMPARISON_ROOTS"] = before_root

    #: `Mixer` is shipped by Apple and translated by Apple, so it satisfies conditions 2 and 3.
    _READ = 'let title = AXHelpers.getTitle(element) ?? ""\n'

    def test_the_plain_comparison_is_refused(self):
        problems = self._scan(self._READ + 'if title == "Mixer" { }\n')
        self.assertTrue(problems, "a translated label compared against an AX reading must fail")
        self.assertIn("Mixer", problems[0])

    def test_a_waiver_excuses_it(self):
        self.assertEqual(self._scan(self._READ + 'if title == "Mixer" { }\n',
                                    waiver={"Mixer": "declared safe by the case"}), [])

    def test_a_comparison_against_a_non_ax_variable_is_not_refused(self):
        """The control. Without it the cases above would pass on a rule that fires on everything."""
        self.assertEqual(self._scan('let commandName = "x"\nif commandName == "Mixer" { }\n'), [])

    def test_an_untranslated_literal_is_not_refused(self):
        """`MIDI` is in the corpus and identical in every locale — matching it by literal is safe,
        and condition 3 is what keeps this guard from being wrong more often than right."""
        self.assertEqual(self._scan(self._READ + 'if title == "MIDI" { }\n'), [])

    def test_the_evasive_shapes_are_refused(self):
        """The three spellings an outside review walked the same defect through, each of which had
        been invisible because the patterns anchored on the variable and on `==`."""
        for label, source in [
            # `copy`, not `mixer`: `mixer` IS a policy literal (a lowercase containment fragment),
            # so a comparison against it is correctly not a finding -- the first version of this
            # case chose it and failed for the right reason, which is what a positive case is for.
            ("lowercased", self._READ + 'if title.lowercased() == "copy" { }\n'),
            ("collection", self._READ + 'return ["Mixer", "Cut"].contains(title)\n'),
            ("switch", self._READ + 'switch title {\ncase "Mixer":\n    break\ndefault:\n    break\n}\n'),
        ]:
            with self.subTest(shape=label):
                self.assertTrue(self._scan(source), f"{label} must be refused like `==` is")


class TheEntryPointRefuses(unittest.TestCase):
    """The cases above call `check()`. A `main()` that returned 0 without ever calling it would
    pass every one of them, because the repository passes -- `Scripts/mutation-sweep-guard-tests.py`
    measured that on 2026-09-18. A guard is its entry point, so one case drives it at a tree that
    must fail."""

    def test_main_refuses_an_offending_tree(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = os.path.join(tmp, "Sources")
            os.makedirs(root)
            with open(os.path.join(root, "Offender.swift"), "w", encoding="utf-8") as handle:
                handle.write('let title = AXHelpers.getTitle(element) ?? ""\n'
                             'if title == "Mixer" { }\n')
            proc = subprocess.run(
                [sys.executable, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                              "check-ax-comparisons-use-labelsets.py")],
                capture_output=True, text=True,
                env=dict(os.environ, LPM_AX_COMPARISON_ROOTS=root))
            self.assertEqual(proc.returncode, 1, (proc.stdout + proc.stderr)[:300])
            self.assertIn("Mixer", proc.stdout + proc.stderr)

    def test_main_accepts_a_clean_tree(self):
        """The control: without it the case above passes on an entry point that always fails."""
        with tempfile.TemporaryDirectory() as tmp:
            root = os.path.join(tmp, "Sources")
            os.makedirs(root)
            with open(os.path.join(root, "Fine.swift"), "w", encoding="utf-8") as handle:
                handle.write('let commandName = "x"\nif commandName == "Mixer" { }\n')
            proc = subprocess.run(
                [sys.executable, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                              "check-ax-comparisons-use-labelsets.py")],
                capture_output=True, text=True,
                env=dict(os.environ, LPM_AX_COMPARISON_ROOTS=root))
            self.assertEqual(proc.returncode, 0, (proc.stdout + proc.stderr)[:300])


class AgainstTheRealTree(unittest.TestCase):
    def test_the_repository_passes(self):
        self.assertEqual(guard.check(), [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
