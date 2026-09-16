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


class AgainstTheRealTree(unittest.TestCase):
    def test_the_repository_passes(self):
        self.assertEqual(guard.check(), [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
