#!/usr/bin/env python3
"""Prove the #1094 harness's predicate refuses an unchanged pop-up, another grid, an unread value and a
reply that is not State A. Nothing talks to Logic.

    python3 test_live_1094_predicate.py
"""
import importlib.util
import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
spec = importlib.util.spec_from_file_location("h1094", os.path.join(HERE, "live_1094_quantize_sets_the_grid_in_every_locale.py"))
H = importlib.util.module_from_spec(spec)
spec.loader.exec_module(H)


def row(before, after, state="A", label="<1/8>"):
    return {"label": label, "value_before": before, "value_after": after, "reply_state": state}


class SetGrid(unittest.TestCase):
    def test_the_label_shown_after_a_change_passes(self):
        self.assertTrue(H.set_grid(row("<off>", "<1/8>")))

    def test_an_unchanged_pop_up_or_another_grid_fails(self):
        self.assertFalse(H.set_grid(row("<off>", "<off>")))
        self.assertFalse(H.set_grid(H.unchanged(row("<off>", "<1/8>"))))
        self.assertFalse(H.set_grid(row("<off>", "<1/16>")), "the held value passed as the grid")
        self.assertFalse(H.set_grid(row("<1/8>", "<1/8>")), "a value already there proves no change")

    def test_an_unread_value_or_another_state_fails(self):
        self.assertFalse(H.set_grid(row("<off>", None)))
        self.assertFalse(H.set_grid(row("<off>", "<1/8>", label=None)))
        self.assertFalse(H.set_grid(row("<off>", "<1/8>", state="B")))
        self.assertFalse(H.set_grid(row("<off>", "<1/8>", state=None)))


if __name__ == "__main__":
    unittest.main()
