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


class Provenance(unittest.TestCase):
    """#1095 review round 3, R1092-04: only a binary stamped with the head is driven."""
    HEAD = "0123456789abcdef0123456789abcdef01234567"

    def test_a_missing_malformed_or_other_stamp_is_refused(self):
        self.assertIsNone(H.provenance_refusal(self.HEAD, self.HEAD))
        self.assertIsNotNone(H.provenance_refusal(None, self.HEAD), "an unstamped binary was driven")
        self.assertIsNotNone(H.provenance_refusal("f" * 40, self.HEAD), "another commit's binary was driven")

    def test_the_reader_takes_the_section_bytes_at_their_file_offset(self):
        import tempfile
        from unittest import mock
        with tempfile.NamedTemporaryFile(delete=False) as handle:
            handle.write(b"\0" * 64 + self.HEAD.encode() + b"\0" * 8)
            path = handle.name
        listing = ("Section\n  sectname __lpm_commit\n   segname __TEXT\n      addr 0x0\n      size 0x0000000000000028\n"
                   "    offset 64\n")
        malformed = listing.replace("offset 64", "offset 60")
        try:
            with mock.patch.object(H.subprocess, "run", return_value=mock.Mock(stdout=listing)):
                self.assertEqual(H.embedded_commit(path), self.HEAD)
            with mock.patch.object(H.subprocess, "run", return_value=mock.Mock(stdout=malformed)):
                self.assertIsNone(H.embedded_commit(path), "bytes that are not a commit read as one")
            with mock.patch.object(H.subprocess, "run", return_value=mock.Mock(stdout="Section\n  sectname __text\n")):
                self.assertIsNone(H.embedded_commit(path))
        finally:
            os.unlink(path)


class ReplySuccess(unittest.TestCase):
    def test_a_wrapped_write_result_is_read(self):
        self.assertTrue(H.reply_success({"success": True}))
        self.assertFalse(H.reply_success({"write_result": {"success": False}, "success": True}))
        self.assertIsNone(H.reply_success("text"))


if __name__ == "__main__":
    unittest.main()
