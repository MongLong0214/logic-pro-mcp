#!/usr/bin/env python3
"""Prove the #1029 harness's predicates refuse a wrong command and a no-op (PR #1091 review R1).

R1091-02 replayed the saved rows and found predicates that passed Stop as Pause, an unrelated
command as Quantize, and identical readings as Copy. R1091-04 found that an isolated row passed with
a reply from another channel, and R1091-01 that the fixture was replaced while Logic's process count
did not read. Each case here builds the readings the harness records and calls the harness's own
functions. Nothing talks to Logic. The undo nouns are synthetic words, not Logic's strings; the
harness reads the real ones from the installed Logic at run time.

    python3 test_live_1029_predicates.py
"""
import importlib.util
import os
import sys
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)


def load(name):
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


H = load("live_1029_cgevent_fallback_in_every_locale")

# Synthetic undo nouns for one synthetic locale, so no case depends on Logic being installed.
WORDS = {key: f"<{key}>" for key in set(H.UNDO_NOUN_KEYS.values())}
WORDS["Undo"] = "<bare-undo>"
WORDS["Can’t Undo"] = "<bare-cant>"
WORDS[H.AUDIO_TRACK_KEY] = "<audio>"
for _key in H.EDITOR_TAB_KEYS.values():
    WORDS[_key] = f"<{_key}>"


def use_words():
    H.UNDO_TABLE.clear()
    H.UNDO_TABLE.update({key: {"xx": value} for key, value in WORDS.items()})
    H.CANON_LOCALE["value"] = "xx"


def titled(word):
    return f"Undo {word}"


def predicate(index):
    return H.OPS[index][5], H.OPS[index][6]


def index_of(op, nth=0):
    return [i for i, row in enumerate(H.OPS) if row[0] == op][nth]


class UndoNounPredicates(unittest.TestCase):
    def setUp(self):
        use_words()

    def test_join_needs_its_own_noun(self):
        expect, _ = predicate(index_of("edit.join"))
        before = {"undo_title": titled(WORDS["Split Regions#und"]), "regions": 9}
        named = {"undo_title": titled(WORDS["Join Regions#und"]), "regions": 8}
        unrelated = {"undo_title": "Undo Renaming", "regions": 8}
        self.assertTrue(expect(before, named, {}))
        self.assertFalse(expect(before, unrelated, {}), "an unrelated command passed as join")
        self.assertFalse(expect(before, dict(before), {}), "a no-op passed as join")

    def test_quantize_is_not_driven(self):
        self.assertNotIn("edit.quantize", [row[0] for row in H.OPS],
                         "quantize posts no keystroke since #1029; a row for it measures nothing")

    def test_paste_needs_the_paste_noun_and_a_new_region(self):
        expect, _ = predicate(index_of("edit.paste"))
        before = {"undo_title": WORDS["Can’t Undo"], "regions": 8}
        self.assertTrue(expect(before, {"undo_title": titled(WORDS["Paste#und"]), "regions": 9}, {}))
        self.assertFalse(expect(before, {"undo_title": titled(WORDS["Cut#und"]), "regions": 9}, {}),
                         "a region added under another command's name passed as paste")
        self.assertFalse(expect(before, {"undo_title": titled(WORDS["Paste#und"]), "regions": 8}, {}))

    def test_an_undo_must_stop_naming_what_it_undid(self):
        expect, _ = predicate(index_of("edit.undo"))
        before = {"undo_title": titled(WORDS["Paste#und"]), "regions": 9}
        self.assertTrue(expect(before, {"undo_title": WORDS["Can’t Undo"], "regions": 8}, {}))
        self.assertFalse(expect(before, {"undo_title": titled(WORDS["Paste#und"]), "regions": 8}, {}))

    def test_track_creation_and_deletion_are_named(self):
        create, _ = predicate(index_of("track.create_audio"))
        delete, _ = predicate(index_of("track.delete"))
        b = {"undo_title": "Undo Renaming", "tracks": 19}
        audio_row = {"new_track_description": "Track 20 '<audio> 2'"}
        self.assertTrue(create(b, {"undo_title": titled(WORDS["Create Track#und"]), "tracks": 20}, dict(audio_row)))
        self.assertFalse(create(b, {"undo_title": titled(WORDS["Paste#und"]), "tracks": 20}, dict(audio_row)))
        self.assertTrue(delete(b, {"undo_title": titled(WORDS["Delete Tracks#und"]), "tracks": 18}, {}))
        self.assertFalse(delete(b, {"undo_title": "Undo Renaming", "tracks": 18}, {}))


class TrackKind(unittest.TestCase):
    def setUp(self):
        use_words()

    def test_audio_and_instrument_creation_are_told_apart(self):
        audio, _ = predicate(index_of("track.create_audio"))
        instrument, _ = predicate(index_of("track.create_instrument"))
        b = {"undo_title": "Undo Renaming", "tracks": 19}
        a = {"undo_title": titled(WORDS["Create Track#und"]), "tracks": 20}
        audio_named = {"new_track_description": "Track 20 '<audio> 2'"}
        patch_named = {"new_track_description": "Track 20 'Deluxe Classic'"}
        self.assertTrue(audio(b, a, dict(audio_named)))
        self.assertFalse(audio(b, a, dict(patch_named)), "an instrument track passed as audio")
        self.assertTrue(instrument(b, a, dict(patch_named)))
        self.assertFalse(instrument(b, a, dict(audio_named)), "an audio track passed as instrument")
        self.assertFalse(instrument(b, a, {}), "no reading passed as instrument")


class EditorAndDialogIdentity(unittest.TestCase):
    def test_the_editor_kind_must_match(self):
        score, _ = predicate(index_of("view.toggle_score_editor"))
        piano, _ = predicate(index_of("view.toggle_piano_roll"))
        with mock.patch.object(H, "unnamed_box_on", return_value=True):
            self.assertTrue(score({}, {}, {"editor_kind": "score"}))
            self.assertFalse(score({}, {}, {"editor_kind": "piano_roll"}), "the piano roll passed as the score")
            self.assertTrue(piano({}, {}, {"editor_kind": "piano_roll"}))
            self.assertFalse(piano({}, {}, {"editor_kind": "score"}))
            self.assertFalse(piano({}, {}, {}))

    def test_a_window_must_be_the_bounce_dialog(self):
        bounce, _ = predicate(index_of("edit.bounce_in_place"))
        before, after = {"windows": [[0, "a"]]}, {"windows": [[0, "a"], [0, ""]]}
        self.assertTrue(bounce(before, after, {"bounce_dialog": True}))
        self.assertFalse(bounce(before, after, {"bounce_dialog": False}), "another window passed as bounce")


class EditorKindFromTheTabBar(unittest.TestCase):
    """editor_kind over a fake window: the tab whose value is 1 names the editor."""

    def setUp(self):
        use_words()
        self.piano, self.score = (WORDS[H.EDITOR_TAB_KEYS[k]] for k in ("piano_roll", "score"))

    def kind(self, *tabs):
        window = object()
        elements = [(window, 0)] + [({"AXRole": role, "AXTitle": title, "AXValue": value}, 3)
                                    for role, title, value in tabs]

        class FakeAX:
            def walk(self, element, depth):
                return iter(elements)

            def value(self, element, name):
                return element.get(name) if isinstance(element, dict) else None

        with mock.patch.object(H.A, "arrange_window", return_value=window):
            return H.editor_kind(FakeAX())

    def test_the_tab_that_reads_one_names_the_editor(self):
        self.assertEqual(self.kind(("AXRadioButton", self.piano, 1), ("AXRadioButton", self.score, 0)), "piano_roll")
        self.assertEqual(self.kind(("AXRadioButton", self.piano, 0), ("AXRadioButton", self.score, 1)), "score")

    def test_no_tab_bar_or_no_tab_on_names_nothing(self):
        self.assertIsNone(self.kind())
        self.assertIsNone(self.kind(("AXRadioButton", self.piano, 0), ("AXRadioButton", self.score, 0)))
        self.assertIsNone(self.kind(("AXRadioButton", self.piano, 1), ("AXRadioButton", self.score, 1)))

    def test_a_lone_tab_or_another_role_is_not_the_tab_bar(self):
        self.assertIsNone(self.kind(("AXRadioButton", self.piano, 1)), "one tab is not the editors' tab bar")
        self.assertIsNone(self.kind(("AXGroup", self.piano, 1), ("AXRadioButton", self.score, 0)))


class PauseIsNotStop(unittest.TestCase):
    def test_pause_needs_play_still_on(self):
        expect, _ = predicate(index_of("transport.pause"))
        with mock.patch.object(H, "box_named", side_effect=lambda snap, key: ("Play", snap["play"])):
            self.assertTrue(expect({"play": 1}, {"play": 1, "bar": 15}, {"bar_later": 15}))
            self.assertFalse(expect({"play": 1}, {"play": 0, "bar": 15}, {"bar_later": 15}),
                             "Stop (Play off, bar held) passed as pause")
            self.assertFalse(expect({"play": 1}, {"play": 1, "bar": 15}, {"bar_later": 16}))


class CopyNeedsItsPaste(unittest.TestCase):
    def rows(self, paste_function):
        return [{"op": "edit.copy", "function": True, "others_moved": []},
                {"op": "edit.paste", "function": paste_function, "others_moved": []}]

    def test_copy_is_credited_only_through_the_paste_after_it(self):
        rows = self.rows(True)
        H.witness_copy_by_paste(rows)
        self.assertTrue(rows[0]["function"])
        rows = self.rows(False)
        H.witness_copy_by_paste(rows)
        self.assertFalse(rows[0]["function"], "identical readings passed copy with no paste behind it")
        alone = [{"op": "edit.copy", "function": True, "others_moved": []}]
        H.witness_copy_by_paste(alone)
        self.assertFalse(alone[0]["function"])


class IsolatedRowsNeedCGEvent(unittest.TestCase):
    def row(self, method):
        return {"function": True, "others_moved": [], "letter_unbound": False,
                "source_after": H.A.KOREAN_2SET, "reply": {"state": "A", "method": method}}

    def test_another_channel_is_not_the_fallback(self):
        self.assertTrue(H.performed(self.row("cgevent")))
        self.assertFalse(H.performed(self.row("accessibility")))
        self.assertFalse(H.performed(self.row(None)))


class UndoTitleFocus(unittest.TestCase):
    def setUp(self):
        use_words()

    def test_a_bare_title_is_focus_and_a_named_change_is_history(self):
        _, allowed = predicate(index_of("view.toggle_library"))
        base = {"tracks": 1, "bar": 1, "windows": [], "structure": {}, "sliders": [], "regions": 8,
                "regions_selected": 0, "boxes": {}}
        to_bare = H.others_kept(dict(base, undo_title=titled(WORDS["Paste#und"])),
                                dict(base, undo_title=WORDS["Undo"]), allowed)
        self.assertEqual(to_bare, [])
        named = H.others_kept(dict(base, undo_title=titled(WORDS["Paste#und"])),
                              dict(base, undo_title=titled(WORDS["Cut#und"])), allowed)
        self.assertEqual(named, ["undo_title"])


class FixtureRestorationNeedsAZeroCount(unittest.TestCase):
    def attempt(self, censuses):
        calls = iter(censuses)
        with mock.patch.object(H.L993, "logic_census", side_effect=lambda: next(calls)), \
                mock.patch.object(H.L993, "quit_logic", return_value=True), \
                mock.patch.object(H.shutil, "rmtree") as rmtree, \
                mock.patch.object(H.subprocess, "run") as run:
            try:
                H.restore_fixture("/nonexistent/backup")
                raised = False
            except RuntimeError:
                raised = True
        return raised, rmtree.called, run.called

    def test_an_unreadable_or_nonzero_count_stops_the_replacement(self):
        for census in ({"status": "unreadable", "raw": None}, {"status": "running", "raw": "2"}):
            raised, removed, copied = self.attempt([census, census])
            self.assertTrue(raised, census)
            self.assertFalse(removed or copied, f"the fixture was replaced under {census}")

    def test_a_zero_count_after_the_quit_allows_it(self):
        raised, removed, copied = self.attempt([{"status": "running", "raw": "1"}, {"status": "gone", "raw": "0"}])
        self.assertFalse(raised)
        self.assertTrue(removed and copied)


class ProductionCompletion(unittest.TestCase):
    def test_every_row_must_read_and_reply_and_restorations_hold(self):
        row = {"op": "transport.play", "before": {}, "after": {}, "reply": {"state": "A"}}
        runs = {"en": {"rows": [row, dict(row)]}}
        self.assertTrue(H.production_complete(runs, ["en"], 2, {"restorations_failed": 0}))
        self.assertFalse(H.production_complete(runs, ["en"], 3, {"restorations_failed": 0}))
        self.assertFalse(H.production_complete(runs, ["en"], 2, {"restorations_failed": 1}))
        broken = {"en": {"rows": [row, dict(row, reply={})]}}
        self.assertFalse(H.production_complete(broken, ["en"], 2, {"restorations_failed": 0}))


if __name__ == "__main__":
    unittest.main()
