#!/usr/bin/env python3
"""Offline contracts for the independent #955 Undo-stack probe."""

import json
import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(os.path.dirname(HERE)))

import engine  # noqa: E402
import evidence_doc  # noqa: E402
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


class TrackMutedProbeTests(unittest.TestCase):
    def test_exact_target_mute_is_read_independently(self):
        got = spec_probes.track_muted_of(
            flags("mute"), len(SPEC["names"]), SPEC["flag_track"])
        self.assertEqual(got, {
            "track": SPEC["flag_track"],
            "muted": True,
            "name": SPEC["names"][SPEC["flag_track"]],
        })

    def test_unreadable_mute_checkbox_is_not_false(self):
        run = flags()
        row = run["observation"]["tracks"][SPEC["flag_track"]]
        row["matches"]["mute"] = 0
        with self.assertRaisesRegex(spec_probes.Unreadable, "track_muted"):
            spec_probes.track_muted_of(run, len(SPEC["names"]), SPEC["flag_track"])


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


class ParameterPlanAcceptanceCounterexampleTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE))))
        with open(os.path.join(root, "docs", "acceptance", "955.json"), encoding="utf-8") as f:
            cls.rows = json.load(f)["rows"]

    @staticmethod
    def observation(step, value):
        return evidence_doc.make_observation(step, json.dumps(value, sort_keys=True))

    @staticmethod
    def reply(row_id):
        common = {
            "write_attempted": False,
            "application_authorized": False,
            "atomic_snapshot": False,
            "target_identity": {"plugin_id": "logic.stock.effect.compressor"},
        }
        if row_id == "supported-subset-keeps-the-undo-entry":
            return {**common, "state": "A", "complete": True, "entries": [
                {"param": "threshold", "status": "change", "read_observations": [1, 2]},
                {"param": "limiter_on", "status": "unchanged", "read_observations": [1, 2]},
                {"param": "ratio", "status": "change", "read_observations": [1, 2]},
            ]}
        requested = {
            "unsupported-field-refuses-without-false-completeness":
                {"param": "gain", "value": 2, "unit": "raw_ax_value"},
            "missing-field-refuses-without-false-completeness":
                {"value": 1, "unit": "boolean"},
            "extra-field-refuses-without-false-completeness":
                {"param": "limiter_on", "value": False, "unit": "boolean", "apply": True},
        }[row_id]
        status = "unsupported" if row_id.startswith("unsupported-") else "invalid_request"
        entry = {"status": status, "read_observations": [], "requested": requested}
        if status == "unsupported":
            entry["param"] = "gain"
        return {**common, "state": "C", "complete": False, "entries": [entry]}

    def values(self, row):
        operation = row["operation"]
        values = {
            "as_found_arm": {"armed": False},
            "as_found_mute": {"muted": False},
            "seed_mute": {},
            "seed_mute_read": {"muted": True},
            "counterexample_undo": {"title": "Undo Mute", "enabled": True},
            "unseed_mute": {},
            "unseed_mute_read": {"muted": False},
            "setup": {},
            "refresh": {},
            "project_info": {},
            "inventory": {},
            "pre_arm": {"armed": True},
            "pre_mute": {"muted": False},
            "pre_undo": {"title": "Undo Record Enable", "enabled": True},
            operation: self.reply(row["id"]),
            "post_arm": {"armed": True},
            "post_mute": {"muted": False},
            "post_undo": {"title": "Undo Record Enable", "enabled": True},
            "undo_setup": {},
            "restored_arm": {"armed": False},
            "restored_mute": {"muted": False},
        }
        return values

    def evaluate(self, row, values):
        run_row = {"observations": {
            step["as"]: self.observation(step, values[step["as"]])
            for step in row["steps"] + row["restore"]
        }}
        return engine.evaluate_row(row, run_row, "en")

    def test_all_four_rows_reject_each_independent_counterexample(self):
        for row in self.rows:
            with self.subTest(row=row["id"]):
                verdict = self.evaluate(row, self.values(row))
                self.assertEqual(verdict["verdict"], "PASS", verdict)
                self.assertEqual(verdict["counterexample"], ["FAIL", "FAIL", "FAIL"])

    def test_same_undo_action_title_is_rejected_as_an_accepted_counterexample(self):
        row = self.rows[1]
        values = self.values(row)
        values["counterexample_undo"] = values["pre_undo"]
        verdict = self.evaluate(row, values)
        self.assertEqual(verdict["verdict"], "FAIL", verdict)
        self.assertTrue(any("counterexample_accepted" in reason
                            for reason in verdict["reasons"]), verdict)

if __name__ == "__main__":
    unittest.main()
