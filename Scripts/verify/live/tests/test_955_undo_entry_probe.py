#!/usr/bin/env python3
"""Offline contracts for the independent #955 Undo-stack probe."""

import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(os.path.dirname(HERE)))

from live import controls, fixture, probes, spec_probes  # noqa: E402

SPEC = fixture.spec("locale_campaign_19")


def flags(flag=None):
    tracks = []
    for index, name in enumerate(SPEC["names"]):
        tracks.append({
            "index": index,
            "name": name,
            "matches": {"arm": 1, "mute": 1, "solo": 1},
            "arm": 0,
            "mute": 1 if flag and index == SPEC["flag_track"] else 0,
            "solo": 0,
            "value_errors": {},
        })
    return {"observation": {"readable": True, "track_count": len(tracks), "tracks": tracks,
                            "children_read_failures": 0}}


def raw_entry(title="Undo Record Enable", enabled=True):
    return {
        "edit_row": {"readable": True, "value": "Edit"},
        "menu_bar_matches": 1,
        "menu_opened": True,
        "entries": [{
            "title": title,
            "enabled": enabled,
            "cmd_char": "Z",
            "cmd_modifiers": 0,
        }],
        "cleanup": {"clean": True, "sent_escape": True},
    }


class UndoEntryParseTests(unittest.TestCase):
    def test_exact_cmd_z_entry_is_read(self):
        parsed = probes.undo_entry_parse(raw_entry())
        self.assertTrue(parsed["readable"])
        self.assertEqual(parsed["title"], "Undo Record Enable")
        self.assertTrue(parsed["enabled"])

    def test_ambiguous_shortcut_is_unreadable(self):
        raw = raw_entry()
        raw["entries"].append(dict(raw["entries"][0]))
        self.assertFalse(probes.undo_entry_parse(raw)["readable"])

    def test_dirty_cleanup_is_unreadable(self):
        raw = raw_entry()
        raw["cleanup"]["clean"] = False
        self.assertFalse(probes.undo_entry_parse(raw)["readable"])

    def test_spec_probe_refuses_an_unreadable_menu(self):
        with self.assertRaisesRegex(spec_probes.Unreadable, "undo_entry"):
            spec_probes.undo_entry_of({"observation": {"readable": False, "cause": "no menu"}})

    def test_spec_probe_returns_only_the_independent_value(self):
        got = spec_probes.undo_entry_of({"observation": probes.undo_entry_parse(raw_entry())})
        self.assertEqual(got, {
            "title": "Undo Record Enable",
            "enabled": True,
            "shortcut": "cmd+z",
        })


class UndoEntryPositiveControlTests(unittest.TestCase):
    def test_control_brackets_one_mute_mutation_with_entry_reads(self):
        saved_run, saved_set = probes.run, controls.set_track_flag
        reads = iter([{"observation": {"readable": True, "title": name, "enabled": True}}
                      for name in ("Undo Record Enable", "Undo Mute", "Undo Mute")])
        calls = []
        probes.run = lambda name, args: next(reads)
        controls.set_track_flag = lambda server, lproj, spec, flag, value: (
            calls.append((flag, value)) or {"last": {"observation": {"readable": True}}})
        try:
            got = controls.undo_entry_control("en", object(), {})
        finally:
            probes.run, controls.set_track_flag = saved_run, saved_set
        self.assertEqual(calls, [("mute", 1), ("mute", 0)])
        self.assertEqual(got["pre"]["observation"]["title"], "Undo Record Enable")
        self.assertEqual(got["post"]["observation"]["title"], "Undo Mute")

    def test_control_requires_the_entry_to_change_after_a_different_mutation(self):
        control = {
            "pre": {"observation": probes.undo_entry_parse(raw_entry("Undo Record Enable"))},
            "post": {"observation": probes.undo_entry_parse(raw_entry("Undo Mute"))},
            "after": {"observation": probes.undo_entry_parse(raw_entry("Undo Mute"))},
            "set": {"last": flags("mute")},
            "unset": {"last": flags()},
        }
        self.assertTrue(probes.undo_entry_known(SPEC, control))
        control["post"] = control["pre"]
        self.assertFalse(probes.undo_entry_known(SPEC, control))

    def test_control_requires_the_mute_to_land_and_restore(self):
        control = {
            "pre": {"observation": probes.undo_entry_parse(raw_entry("Undo Record Enable"))},
            "post": {"observation": probes.undo_entry_parse(raw_entry("Undo Mute"))},
            "after": {"observation": probes.undo_entry_parse(raw_entry("Undo Mute"))},
            "set": {"last": flags()},
            "unset": {"last": flags()},
        }
        self.assertFalse(probes.undo_entry_known(SPEC, control))

    def test_control_rejects_a_probe_that_returns_one_constant(self):
        same = {"observation": probes.undo_entry_parse(raw_entry("Undo"))}
        control = {
            "pre": same,
            "post": same,
            "after": same,
            "set": {"last": flags("mute")},
            "unset": {"last": flags()},
        }
        self.assertFalse(probes.undo_entry_known(SPEC, control))


if __name__ == "__main__":
    unittest.main()
