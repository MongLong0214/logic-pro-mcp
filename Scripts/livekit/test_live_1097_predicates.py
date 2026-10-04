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


class RenameNeedsReadNames(unittest.TestCase):
    """#1091 review R3, R1091-10: names that did not read are not unchanged names."""

    def test_unread_or_missing_names_fail(self):
        self.assertFalse(H.rename_honest(rename_row(before=(None, None, None), after=(None, None, None))))
        unread_after = rename_row()
        unread_after["names_after"] = ["Kit", None, "Keys"]
        self.assertFalse(H.rename_honest(unread_after))
        missing = rename_row()
        missing.pop("names_before")
        missing.pop("names_after")
        self.assertFalse(H.rename_honest(missing))

    def test_a_missing_reply_state_fails(self):
        self.assertFalse(H.rename_honest(rename_row(state=None)))

    def test_names_must_cover_the_selected_rows(self):
        self.assertFalse(H.rename_honest(rename_row(before=("Kit",), after=("Kit",), selected=(0, 1))))


class MainCountsTheRestoration(unittest.TestCase):
    """#1091 review R3, R1091-11: a failed restoration fails the run."""

    def drive(self, final_restore_error):
        import tempfile
        from argparse import Namespace
        from unittest import mock

        class Notes:
            def __init__(self, *_a, **_k):
                self.records = []

            def note(self, *_a, **_k):
                pass

            def falsifiable(self, *_a, **_k):
                pass

            def restored(self, tag, restored, detail=""):
                self.records.append((tag, restored))

            def write(self):
                return {}

        class Driver:
            def __init__(self, *_a, **_k):
                pass

            def close(self):
                pass

        head = "0" * 40
        with tempfile.NamedTemporaryFile(delete=False) as handle:
            binary = handle.name
        root = tempfile.mkdtemp()
        args = Namespace(worktree=os.path.dirname(os.path.dirname(HERE)), head=head, binary=binary, lprojs=["ko"])
        passing_select = {"lproj": "ko", "trial": "select", "selected_after": [0, 1], "reply_state": "B",
                          "also_selected": [1]}
        passing_rename = {"lproj": "ko", "trial": "rename", "selected_before": [0, 1], "names_before": ["a", "b"],
                          "names_after": ["a", "b"], "reply_state": "C", "reply_error": "selection_not_exclusive",
                          "requested": "x"}
        restores = [None, final_restore_error]
        try:
            with mock.patch.object(H, "arguments", return_value=args), \
                    mock.patch.object(H.P, "embedded_commit", return_value=head), \
                    mock.patch.object(H.P, "sha256_of", return_value="0"), \
                    mock.patch.object(H.E, "Evidence", Notes), \
                    mock.patch.object(H.E, "Driver", Driver), \
                    mock.patch.object(H.A, "AX", return_value=None), \
                    mock.patch.object(H.subprocess, "run"), \
                    mock.patch.object(H, "restore_fixture", side_effect=restores), \
                    mock.patch.object(H.L993, "switch_to", return_value={"arrange_window": "t"}), \
                    mock.patch.object(H, "select_trial", return_value=passing_select), \
                    mock.patch.object(H, "rename_trial", return_value=passing_rename), \
                    mock.patch.object(H.time, "sleep"), \
                    mock.patch.dict(os.environ, {"LPM_EVIDENCE_ROOT": root}):
                return H.main()
        finally:
            os.unlink(binary)

    def test_a_failed_final_restoration_returns_one(self):
        self.assertEqual(self.drive(RuntimeError("Logic did not quit")), 1)

    def test_the_same_run_restored_returns_zero(self):
        self.assertEqual(self.drive(None), 0)


if __name__ == "__main__":
    unittest.main()
