#!/usr/bin/env python3
"""Prove the #1092 harness's predicate refuses a shuttle, a call that did nothing, and another rung.

Each case builds the row the harness records and calls the harness's own `stepped`. Nothing talks to
Logic. The shuttle readings are the ones the MCU rung gave in ko on 2026-10-03.

    python3 test_live_1092_predicate.py
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


H = load("live_1092_rewind_and_forward_step_one_bar")


def row(direction, readings, start=9, answered_by=("CGEvent",), success=True):
    return {"direction": direction, "start": start, "readings": list(readings),
            "answered_by": list(answered_by), "reply_success": success}


class Stepped(unittest.TestCase):
    def test_one_bar_held_at_every_sample_is_a_step(self):
        self.assertTrue(H.stepped(row(-1, [8, 8, 8])))
        self.assertTrue(H.stepped(row(1, [10, 10, 10])))

    def test_a_shuttle_is_not_a_step(self):
        self.assertFalse(H.stepped(row(-1, [5, 2, -3])))
        self.assertFalse(H.stepped(row(1, [13, 16, 19])))
        self.assertFalse(H.stepped(H.as_shuttle(row(-1, [8, 8, 8]))))
        self.assertFalse(H.stepped(H.as_shuttle(row(1, [10, 10, 10]))))

    def test_a_step_that_keeps_going_after_the_first_sample_is_not_a_step(self):
        self.assertFalse(H.stepped(row(-1, [8, 8, 7])), "the last sample moved on")
        self.assertFalse(H.stepped(row(1, [10, 11, 11])))

    def test_nothing_moving_is_not_a_step(self):
        self.assertFalse(H.stepped(row(-1, [9, 9, 9])))
        self.assertFalse(H.stepped(row(1, [9, 9, 9])))

    def test_the_wrong_direction_is_not_a_step(self):
        self.assertFalse(H.stepped(row(-1, [10, 10, 10])))
        self.assertFalse(H.stepped(row(1, [8, 8, 8])))

    def test_a_reading_that_did_not_read_is_not_a_step(self):
        self.assertFalse(H.stepped(row(-1, [8, None, 8])))
        self.assertFalse(H.stepped(row(-1, [8, 8])), "a missing sample")

    def test_a_start_off_bar_nine_is_not_measured(self):
        self.assertFalse(H.stepped(row(-1, [7, 7, 7], start=8)))
        self.assertFalse(H.stepped(row(-1, [8, 8, 8], start=None)))

    def test_another_rung_is_not_the_step(self):
        self.assertFalse(H.stepped(row(-1, [8, 8, 8], answered_by=("MCU",))))
        self.assertFalse(H.stepped(row(-1, [8, 8, 8], answered_by=("MCU", "CGEvent"))))
        self.assertFalse(H.stepped(row(-1, [8, 8, 8], answered_by=())))

    def test_a_failed_reply_is_not_a_step(self):
        self.assertFalse(H.stepped(row(-1, [8, 8, 8], success=False)))
        self.assertFalse(H.stepped(row(-1, [8, 8, 8], success=None)))


class ReplySuccess(unittest.TestCase):
    def test_a_wrapped_write_result_is_read(self):
        self.assertTrue(H.reply_success({"success": True}))
        self.assertFalse(H.reply_success({"write_result": {"success": False}, "success": True}))
        self.assertIsNone(H.reply_success("text"))


if __name__ == "__main__":
    unittest.main()
