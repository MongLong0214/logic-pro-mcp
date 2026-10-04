#!/usr/bin/env python3
"""Prove the #1097 harness's predicates refuse what the merge-base binary did, and an unreproduced
condition.

Each case builds the row the harness records and calls the harness's own predicate. The base
readings are the ones measured in Korean on 2026-10-04 (lpm-evidence/1029/probe-kc-ko.json): rows
[0, 1] selected after select answered State A, and a rename of track 0 to "LPM-KDUP 55348" renamed
track 1 to "LPM-KDUP 55349". Nothing talks to Logic.

    python3 test_live_1097_predicates.py
"""
import importlib.util
import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)


def load(name):
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


H = load("live_1097_select_and_rename_need_the_target_alone")


def select_row(selected_after=(0, 1), state="B", also=(1,)):
    return {"trial": "select", "selected_after": list(selected_after), "reply_state": state,
            "also_selected": None if also is None else list(also)}


def rename_row(state="C", error="selection_not_exclusive", before=("Kit", "Bass", "Keys"),
               after=("Kit", "Bass", "Keys"), selected=(0, 1), requested="LPM1097 1"):
    return {"trial": "rename", "selected_before": list(selected), "names_before": list(before),
            "names_after": list(after), "reply_state": state, "reply_error": error, "requested": requested}


class Select(unittest.TestCase):
    def test_a_refused_selection_that_names_the_other_row_passes(self):
        self.assertTrue(H.select_honest(select_row()))

    def test_the_base_answer_fails(self):
        self.assertFalse(H.select_honest(select_row(state="A", also=None)))
        self.assertFalse(H.select_honest(H.select_as_base(select_row())))

    def test_an_unreproduced_condition_fails(self):
        self.assertFalse(H.select_honest(select_row(selected_after=(0,), also=())), "Logic replaced the selection")
        self.assertFalse(H.select_honest(select_row(selected_after=(1, 2), also=(1, 2))), "row 0 was not selected")

    def test_naming_the_wrong_rows_fails(self):
        self.assertFalse(H.select_honest(select_row(also=(2,))))
        self.assertFalse(H.select_honest(select_row(also=())))

    def test_a_missing_reply_fails(self):
        self.assertFalse(H.select_honest(select_row(state=None)))


class Rename(unittest.TestCase):
    def test_a_refusal_that_renamed_nothing_passes(self):
        self.assertTrue(H.rename_honest(rename_row()))

    def test_row_zero_alone_renamed_with_state_a_passes(self):
        self.assertTrue(H.rename_honest(rename_row(state="A", error=None, after=("LPM1097 1", "Bass", "Keys"))))

    def test_the_base_rename_of_both_rows_fails(self):
        both = rename_row(state="A", error=None, after=("LPM1097 1", "LPM1097 2", "Keys"))
        self.assertFalse(H.rename_honest(both))
        self.assertFalse(H.rename_honest(H.rename_as_base(rename_row())))

    def test_a_refusal_that_still_renamed_something_fails(self):
        self.assertFalse(H.rename_honest(rename_row(after=("Kit", "LPM1097 2", "Keys"))))

    def test_another_refusal_or_a_wrong_name_fails(self):
        self.assertFalse(H.rename_honest(rename_row(error="ax_write_failed")))
        self.assertFalse(H.rename_honest(rename_row(state="A", error=None, after=("Other", "Bass", "Keys"))))

    def test_an_unreproduced_condition_fails(self):
        self.assertFalse(H.rename_honest(rename_row(selected=(0,))))

    def test_rows_that_did_not_read_fail(self):
        self.assertFalse(H.rename_honest(rename_row(after=("Kit", "Bass"))))


if __name__ == "__main__":
    unittest.main()
