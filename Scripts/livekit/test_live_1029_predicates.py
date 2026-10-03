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
        # The tabs carry their label in AXDescription and no AXTitle, as probe-tabs-ko.json read them.
        elements = [(window, 0)] + [({"AXRole": role, "AXDescription": label, "AXValue": value}, 3)
                                    for role, label, value in tabs]

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

    def test_the_label_is_read_from_the_description(self):
        window = object()
        titled = [(window, 0), ({"AXRole": "AXRadioButton", "AXTitle": self.piano, "AXValue": 1}, 3),
                  ({"AXRole": "AXRadioButton", "AXTitle": self.score, "AXValue": 0}, 3)]

        class TitledAX:
            def walk(self, element, depth):
                return iter(titled)

            def value(self, element, name):
                return element.get(name) if isinstance(element, dict) else None

        with mock.patch.object(H.A, "arrange_window", return_value=window):
            self.assertIsNone(H.editor_kind(TitledAX()), "a title is not where Logic puts the tab's label")

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


def usable_snap(**overrides):
    snap = {"boxes": {"Play": 0, "Cycle": 0}, "tracks": 19, "bar": 9, "undo_title": WORDS["Can\u2019t Undo"],
            "regions": 8, "regions_selected": 0, "windows": [[0, "fixture - Tracks"]], "structure": {"1:AXGroup": 3},
            "sliders": [120.0, 0.5, 0.2]}
    snap.update(overrides)
    return snap


def judged_row(op, before, after, extra=None, extra_before=None, method="cgevent", nth=0):
    return {"index": index_of(op, nth), "op": op, "before": before, "after": after, "extra": extra or {},
            "extra_before": extra_before or {}, "reply": {"state": "B", "method": method},
            "letter_unbound": False, "source_after": H.A.KOREAN_2SET}


class JudgeReadsTheRawReadings(unittest.TestCase):
    """#1091 review R2, R1091-07: the counterexample must reach the op's own predicate."""

    def setUp(self):
        use_words()

    def test_a_join_that_happened_passes_and_the_unchanged_row_does_not(self):
        before = usable_snap(undo_title=titled(WORDS["Split Regions#und"]), regions=9, regions_selected=2)
        after = usable_snap(undo_title=titled(WORDS["Join Regions#und"]), regions=8, regions_selected=1)
        row = judged_row("edit.join", before, after)
        self.assertTrue(H.judge(row))
        self.assertFalse(H.judge(H.unchanged(row)))

    def test_a_predicate_that_always_passes_is_caught_by_the_unchanged_row(self):
        # The mutation the review ran: an op's predicate replaced by `return True`. The unchanged row
        # still differs from nothing, so only others_kept and the predicate stand between it and a
        # pass; with the predicate gone it passes, and this test fails.
        row = judged_row("edit.join", usable_snap(), usable_snap())
        self.assertFalse(H.judge(row), "an op whose readings did not move passed")

    def test_a_join_that_also_moved_another_reading_fails(self):
        before = usable_snap(undo_title=titled(WORDS["Split Regions#und"]), regions=9)
        after = usable_snap(undo_title=titled(WORDS["Join Regions#und"]), regions=8, tracks=20)
        self.assertFalse(H.judge(judged_row("edit.join", before, after)), "a join that also added a track passed")

    def test_another_channel_is_not_the_fallback(self):
        before = usable_snap(undo_title=titled(WORDS["Split Regions#und"]), regions=9)
        after = usable_snap(undo_title=titled(WORDS["Join Regions#und"]), regions=8)
        self.assertTrue(H.judge(judged_row("edit.join", before, after)))
        self.assertFalse(H.judge(judged_row("edit.join", before, after, method="accessibility")))
        self.assertFalse(H.judge(judged_row("edit.join", before, after, method=None)))

    def test_pause_is_judged_on_the_bar_pair_from_before_the_call(self):
        with mock.patch.object(H, "box_named", side_effect=lambda snap, key: ("Play", snap["boxes"]["Play"])):
            before = usable_snap(boxes={"Play": 1}, bar=12)
            after = usable_snap(boxes={"Play": 1}, bar=15)
            row = judged_row("transport.pause", before, after, extra={"bar_later": 15},
                             extra_before={"after_bar": 9, "bar_later": 12})
            self.assertTrue(H.judge(row))
            self.assertFalse(H.judge(H.unchanged(row)), "a transport still playing passed as paused")

    def test_an_editor_counterexample_uses_the_reading_before_the_call(self):
        with mock.patch.object(H, "unnamed_box_on", return_value=True):
            row = judged_row("view.toggle_piano_roll", usable_snap(), usable_snap(),
                             extra={"editor_kind": "piano_roll"}, extra_before={"editor_kind": None})
            self.assertTrue(H.judge(row))
            self.assertFalse(H.judge(H.unchanged(row)))


class UnreadReadingsFail(unittest.TestCase):
    """#1091 review R2, R1091-06: two readings that did not read are not one unchanged reading."""

    def test_equal_missing_readings_are_unread_not_kept(self):
        base = usable_snap()
        moved = H.others_kept(dict(base, tracks=None), dict(base, tracks=None), set())
        self.assertIn("unread:tracks", moved)

    def test_a_window_shell_is_not_a_reading(self):
        self.assertFalse(H.usable({"boxes": {}, "tracks": None, "bar": None, "undo_title": None}))
        self.assertFalse(H.usable(None))
        self.assertTrue(H.usable(usable_snap()))


class DuplicateAndCloseIdentity(unittest.TestCase):
    def setUp(self):
        use_words()

    def test_duplicate_needs_the_source_strips_patch_name(self):
        extra = {"selected_track": {"index": 0, "name": "Absolute Zero"}, "renamed_track": {"name": "LPM1029 0 50374"},
                 "source_patch": "Absolute Zero", "new_track_description": "Track 25 'Absolute Zero'"}
        self.assertTrue(H.carries_source_settings({}, {}, extra))
        for described in ("Track 25 '<audio> 2'", "Track 25 'Deluxe Classic'"):
            self.assertFalse(H.carries_source_settings({}, {}, dict(extra, new_track_description=described)),
                             "a created track passed as a duplicate")
        self.assertFalse(H.carries_source_settings({}, {}, {"new_track_description": "x"}))
        self.assertFalse(H.carries_source_settings({}, {}, dict(extra, source_patch=None)), "no patch name read")
        self.assertFalse(H.carries_source_settings({}, {}, dict(extra, selected_track={"index": 2})), "another source")

    def test_a_chinese_duplicate_carries_the_localized_patch_name(self):
        # zh_CN on 2026-10-04: the source reads Absolute Zero, the duplicate 绝对零度.
        extra = {"selected_track": {"index": 0, "name": "Absolute Zero"}, "source_patch": "绝对零度",
                 "new_track_description": "轨道 25“绝对零度”"}
        self.assertTrue(H.carries_source_settings({}, {}, extra))
        self.assertFalse(H.carries_source_settings({}, {}, dict(extra, source_patch="Absolute Zero")))

    def test_close_needs_every_fixture_window_gone(self):
        two = ["fixture - Tracks", "fixture - Marker List"]
        self.assertTrue(H.project_closed({}, {}, {"arrange_after": False, "fixture_windows_before": two,
                                                  "fixture_windows_after": []}))
        self.assertFalse(H.project_closed({}, {}, {"arrange_after": False, "fixture_windows_before": two,
                                                   "fixture_windows_after": ["fixture - Marker List"]}),
                         "closing the front window passed as closing the project")
        self.assertFalse(H.project_closed({}, {}, {"arrange_after": False, "fixture_windows_before": two[:1],
                                                   "fixture_windows_after": []}),
                         "with one window open, Close Window and Close Project cannot be told apart")
        self.assertFalse(H.project_closed({}, {}, {"arrange_after": False, "fixture_windows_before": two,
                                                   "fixture_windows_after": None}))


class NamedZoomAutomationAndCopy(unittest.TestCase):
    """#1091 review R2, R1091-06: zoom, automation and copy named by their own controls."""

    def setUp(self):
        use_words()

    def test_zoom_needs_its_named_sliders_to_move(self):
        before = usable_snap(zoom={"vertical": 0.684, "horizontal": 0.213}, sliders=[120.0, 0.684, 0.213])
        after = usable_snap(zoom={"vertical": 0.0, "horizontal": 0.585}, sliders=[120.0, 0.0, 0.585])
        row = judged_row("nav.zoom_to_fit", before, after)
        self.assertTrue(H.judge(row))
        self.assertFalse(H.judge(H.unchanged(row)))
        other = usable_snap(zoom={"vertical": 0.684, "horizontal": 0.213}, sliders=[121.0, 0.684, 0.213])
        self.assertFalse(H.judge(judged_row("nav.zoom_to_fit", before, other)), "another slider passed as zoom")
        unread = usable_snap(zoom={"vertical": None, "horizontal": None})
        self.assertFalse(H.judge(judged_row("nav.zoom_to_fit", before, unread)))

    def test_automation_needs_its_checkbox_and_mode_popups(self):
        hidden = usable_snap(automation={"box": 0, "mode_popups": 0})
        shown = usable_snap(automation={"box": 1, "mode_popups": 19}, structure={"1:AXGroup": 3, "8:AXPopUpButton": 38})
        row = judged_row("automation.toggle_view", hidden, shown)
        self.assertTrue(H.judge(row))
        self.assertFalse(H.judge(H.unchanged(row)))
        group_only = usable_snap(automation={"box": 0, "mode_popups": 0}, structure={"1:AXGroup": 4})
        self.assertFalse(H.judge(judged_row("automation.toggle_view", hidden, group_only)),
                         "an unrelated group passed as automation")
        box_only = usable_snap(automation={"box": 1, "mode_popups": 0})
        self.assertFalse(H.judge(judged_row("automation.toggle_view", hidden, box_only)))
        self.assertTrue(H.judge(judged_row("automation.toggle_view", shown, hidden, nth=1)))

    def test_copy_needs_a_seeded_clipboard_and_the_paste_after_it(self):
        paste = judged_row("edit.paste", usable_snap(regions=8),
                           usable_snap(regions=9, undo_title=titled(WORDS["Paste#und"])))
        copy = judged_row("edit.copy", usable_snap(), usable_snap(),
                          extra={"clipboard_seeded": True, "paste_row": paste})
        self.assertTrue(H.judge(copy))
        self.assertFalse(H.judge(H.unchanged(copy)), "a copy whose paste added nothing passed")
        unseeded = dict(copy, extra={"clipboard_seeded": False, "paste_row": paste})
        self.assertFalse(H.judge(unseeded), "a clipboard left from earlier passed copy")
        self.assertFalse(H.judge(dict(copy, extra={"clipboard_seeded": True})), "a copy with no paste passed")


class EmbeddedCommit(unittest.TestCase):
    HEAD = "0123456789abcdef0123456789abcdef01234567"

    def test_the_section_is_read_at_its_file_offset(self):
        import tempfile
        with tempfile.NamedTemporaryFile(delete=False) as handle:
            handle.write(b"\0" * 64 + self.HEAD.encode() + b"\0" * 8)
            path = handle.name
        listing = "Section\n  sectname __lpm_commit\n   segname __TEXT\n      size 0x0000000000000028\n    offset 64\n"
        try:
            with mock.patch.object(H.subprocess, "run", return_value=mock.Mock(stdout=listing)):
                self.assertEqual(H.embedded_commit(path), self.HEAD)
            with mock.patch.object(H.subprocess, "run", return_value=mock.Mock(stdout=listing.replace("offset 64", "offset 60"))):
                self.assertIsNone(H.embedded_commit(path))
            with mock.patch.object(H.subprocess, "run", return_value=mock.Mock(stdout="")):
                self.assertIsNone(H.embedded_commit(path), "a binary with no section read as stamped")
        finally:
            os.unlink(path)


class RouteEnvironment(unittest.TestCase):
    """#1091 review R2, R1091-08: production must not inherit the debug route."""

    def test_production_clears_and_isolated_sets(self):
        env = {H.ONLY_CHANNEL_KEY: "CGEvent", H.PASS_KEY: "transport.get_state"}
        self.assertEqual(H.apply_route_environment("production", env), {H.ONLY_CHANNEL_KEY: None, H.PASS_KEY: None})
        self.assertNotIn(H.ONLY_CHANNEL_KEY, env)
        got = H.apply_route_environment("isolated", env)
        self.assertEqual(got[H.ONLY_CHANNEL_KEY], "CGEvent")
        self.assertEqual(got[H.PASS_KEY], ",".join(H.PASS_OPERATIONS))


class ProductionCompletion(unittest.TestCase):
    def test_every_row_must_read_usably_and_reply_and_restorations_hold(self):
        row = {"op": "transport.play", "before": usable_snap(), "after": usable_snap(), "reply": {"state": "A"}}
        runs = {"en": {"rows": [row, dict(row)]}}
        self.assertTrue(H.production_complete(runs, ["en"], 2, {"restorations_failed": 0}))
        self.assertFalse(H.production_complete(runs, ["en"], 3, {"restorations_failed": 0}))
        self.assertFalse(H.production_complete(runs, ["en"], 2, {"restorations_failed": 1}))
        broken = {"en": {"rows": [row, dict(row, reply={})]}}
        self.assertFalse(H.production_complete(broken, ["en"], 2, {"restorations_failed": 0}))
        shell = {"en": {"rows": [row, dict(row, after={"boxes": {}, "tracks": None})]}}
        self.assertFalse(H.production_complete(shell, ["en"], 2, {"restorations_failed": 0}),
                         "an AX window shell with nothing read passed")


class QuotedName(unittest.TestCase):
    """The 2026-10-04 full run failed German duplicate: the source's name read as None from „…“."""

    def test_every_language_quote_style_reads_the_name(self):
        for description in ("트랙 1 ‘Absolute Zero’", "Track 1 “Absolute Zero”", "Spur 1 „Absolute Zero“",
                            "Piste 1 « Absolute Zero »", "トラック 1「Absolute Zero」", "Track 1 'Absolute Zero'"):
            self.assertEqual(H.quoted_name(description), "Absolute Zero", description)

    def test_no_quotes_or_an_empty_pair_is_no_name(self):
        self.assertIsNone(H.quoted_name("Track 1"))
        self.assertIsNone(H.quoted_name("Track 1 “”"))
        self.assertIsNone(H.quoted_name(None))


if __name__ == "__main__":
    unittest.main()
