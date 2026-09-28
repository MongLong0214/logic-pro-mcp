#!/usr/bin/env python3
"""Drive `check-cgevent-keystrokes-are-apples.py` with the defects it names.

Each case applies one mutation to the real CGEventChannel.swift, or to a copy of the pinned tables,
and asserts the guard refuses it; the real tree is the control. The three the rule was written for
come first: a keycode changed, a modifier changed, and an op given a keystroke with no Apple row.
The last of those is `edit.delete` restored to `.key(51)` -- the value it carried before #1029, a
key Apple's U.S. preset binds to no delete command.
"""
import hashlib
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
GUARD = "check-cgevent-keystrokes-are-apples.py"


def _load(name, filename):
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


guard = _load("cgevent_keystrokes_guard", GUARD)


def _source():
    with open(guard.SWIFT, encoding="utf-8") as handle:
        return handle.read()


def _mutated(test, old, new):
    source = _source()
    test.assertIn(old, source)
    return source.replace(old, new, 1)


class TheGuardReadsTheRealTable(unittest.TestCase):
    def test_the_committed_table_passes(self):
        self.assertEqual(guard.check(_source(), guard.CANON), [])

    def test_every_keymap_entry_is_read_and_joined(self):
        failures = []
        entries = guard.parse_keymap(_source(), failures)
        self.assertEqual(failures, [])
        self.assertEqual(set(entries), set(guard.JOIN))

    def test_a_keypad_row_reads_as_the_keypad_key(self):
        self.assertEqual(guard.apple_keystroke("\U0001D356 0"), (0x52, {"keypad"}))
        self.assertEqual(guard.apple_keystroke("Option-Command-W"), (0x0D, {"option", "command"}))
        self.assertEqual(guard.apple_keystroke("Command-Delete (⌫)"), (0x33, {"command"}))
        self.assertIsNone(guard.apple_keystroke("Hyper-Q"))


class TheThreeMutantsTheRuleNames(unittest.TestCase):
    def test_one_keycode_changed_is_refused(self):
        source = _mutated(self, '"view.toggle_score_editor":   .key(45)',
                          '"view.toggle_score_editor":   .key(46)')
        failures = guard.check(source, guard.CANON)
        self.assertTrue(any("view.toggle_score_editor: posts keycode 46" in f for f in failures), failures)

    def test_one_modifier_changed_is_refused(self):
        source = _mutated(self, '"edit.bounce_in_place":       .control(11)',
                          '"edit.bounce_in_place":       .cmd(11)')
        failures = guard.check(source, guard.CANON)
        self.assertTrue(any(f.startswith("edit.bounce_in_place: posts keycode 11 with ['command']")
                            for f in failures), failures)

    def test_an_op_added_without_a_row_is_refused(self):
        source = _mutated(self, '        "edit.select_all":',
                          '        "edit.delete":                .key(51),\n        "edit.select_all":')
        failures = guard.check(source, guard.CANON)
        self.assertTrue(any(f.startswith("edit.delete posts a keystroke but names no Apple row")
                            for f in failures), failures)


class TheGuardCatchesWhatItNames(unittest.TestCase):
    def test_a_keypad_row_posted_on_the_main_row_is_refused(self):
        source = _mutated(self, '"transport.stop":             .keypad(82)',
                          '"transport.stop":             .key(82)')
        self.assertTrue(any(f.startswith("transport.stop:") for f in guard.check(source, guard.CANON)))

    def test_the_old_space_bar_stop_is_refused(self):
        source = _mutated(self, '"transport.stop":             .keypad(82)',
                          '"transport.stop":             .key(49)')
        self.assertTrue(any(f.startswith("transport.stop:") for f in guard.check(source, guard.CANON)))

    def test_a_constructor_whose_flags_change_is_refused(self):
        source = _mutated(self, "Shortcut(keyCode: code, flags: .maskControl)",
                          "Shortcut(keyCode: code, flags: .maskCommand)")
        self.assertTrue(any(f.startswith("edit.bounce_in_place:") for f in guard.check(source, guard.CANON)))

    def test_a_line_it_cannot_read_is_refused_rather_than_skipped(self):
        source = _mutated(self, '"edit.cut":                   .cmd(7),',
                          '"edit.cut":                   Shortcut(keyCode: 7, flags: .maskCommand),')
        failures = guard.check(source, guard.CANON)
        self.assertTrue(any("cannot read, refused" in f for f in failures), failures)

    def test_a_join_row_for_a_removed_op_is_refused(self):
        source = _source()
        line = next(l for l in source.split("\n") if l.strip().startswith('"nav.zoom_to_fit":'))
        source = source.replace(line + "\n", "", 1)
        self.assertNotIn('"nav.zoom_to_fit":', source)
        failures = guard.check(source, guard.CANON)
        self.assertTrue(any("JOIN names nav.zoom_to_fit" in f for f in failures), failures)

    def test_an_edited_pinned_table_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            canon = os.path.join(tmp, "canon")
            shutil.copytree(guard.CANON, canon)
            path = os.path.join(canon, "global-commands.table.html")
            with open(path, encoding="utf-8") as handle:
                data = handle.read()
            self.assertIn("<p>Show/Hide Score Editor</p></td><td><p>N</p>", data)
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(data.replace("<p>Show/Hide Score Editor</p></td><td><p>N</p>",
                                          "<p>Show/Hide Score Editor</p></td><td><p>M</p>", 1))
            failures = guard.check(_source(), canon)
            self.assertTrue(any("is not the bytes SOURCE.json pinned" in f for f in failures), failures)

    def test_an_edit_that_also_rewrites_the_digest_still_meets_the_row(self):
        """A table edited AND re-digested is caught by the row it changed, not by the digest."""
        with tempfile.TemporaryDirectory() as tmp:
            canon = os.path.join(tmp, "canon")
            shutil.copytree(guard.CANON, canon)
            path = os.path.join(canon, "global-commands.table.html")
            with open(path, encoding="utf-8") as handle:
                data = handle.read().replace(
                    "<p>Show/Hide Score Editor</p></td><td><p>N</p>",
                    "<p>Show/Hide Score Editor</p></td><td><p>M</p>", 1)
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(data)
            meta_path = os.path.join(canon, "SOURCE.json")
            with open(meta_path, encoding="utf-8") as handle:
                meta = json.load(handle)
            meta["pages"]["global-commands"]["table_sha256"] = hashlib.sha256(data.encode("utf-8")).hexdigest()
            with open(meta_path, "w", encoding="utf-8") as handle:
                json.dump(meta, handle)
            failures = guard.check(_source(), canon)
            self.assertTrue(any(f.startswith("view.toggle_score_editor:") for f in failures), failures)


class TheEntryPointRefuses(unittest.TestCase):
    """The cases above call the helpers. A `main()` that returned 0 without calling them would pass
    all of them, because the repository passes. `LPM_CGEVENT_SWIFT` and `LPM_KEYCMD_CANON` are the
    seams that point the entry point at a tree that must fail.
    """

    def _run(self, **env):
        return subprocess.run([sys.executable, os.path.join(HERE, GUARD)],
                              capture_output=True, text=True, env=dict(os.environ, **env))

    def test_a_keycode_that_is_not_apples_is_refused(self):
        source = _mutated(self, '"view.toggle_score_editor":   .key(45)',
                          '"view.toggle_score_editor":   .key(46)')
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "CGEventChannel.swift")
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(source)
            proc = self._run(LPM_CGEVENT_SWIFT=path)
            self.assertEqual(proc.returncode, 1, (proc.stdout + proc.stderr)[:300])

    def test_a_missing_pinned_table_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            proc = self._run(LPM_KEYCMD_CANON=tmp)
            self.assertEqual(proc.returncode, 1, (proc.stdout + proc.stderr)[:300])

    def test_the_repositorys_own_table_is_accepted(self):
        """The control."""
        proc = self._run()
        self.assertEqual(proc.returncode, 0, (proc.stdout + proc.stderr)[:300])


if __name__ == "__main__":
    unittest.main(verbosity=2)
