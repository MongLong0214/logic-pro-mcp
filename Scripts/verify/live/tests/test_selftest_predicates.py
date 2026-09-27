#!/usr/bin/env python3
"""Offline: the self-test's must-FAIL control is judged by what the probe read, and aimed.

The live run arms track 0 through the product and reads the #1020 arm probe before and after. These
cases are that probe's observation shape with the values changed. Each names the mutation of
selftest_live.py it kills.
"""

import copy
import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(os.path.dirname(HERE)))

from live import selftest_live as st  # noqa: E402


def reading(*arms):
    return {"observation": {"readable": True, "tracks": [
        {"arm": a, "mute": 0, "solo": 0} for a in arms]}}


def control(pre, post, after):
    return {"pre": reading(*pre), "post": reading(*post), "after": reading(*after)}


class MustFail(unittest.TestCase):

    def test_track_0_armed_then_restored_is_the_control_failing_as_it_must(self):
        o = control((0, 0, 0), (1, 0, 0), (0, 0, 0))
        self.assertIs(st.pred_arm_probe_agrees_with_pre_state(o), False)
        self.assertTrue(st.pred_must_fail(o))

    def test_a_probe_that_did_not_see_the_arm_does_not_pass(self):
        # Kills: pred_must_fail not requiring the control predicate to be False (a blind probe).
        self.assertFalse(st.pred_must_fail(control((0, 0, 0), (0, 0, 0), (0, 0, 0))))

    def test_a_probe_reading_another_row_does_not_pass(self):
        # Kills: the post reading compared on track 0 only (another track's change also disagrees).
        self.assertFalse(st.pred_must_fail(control((0, 0, 0), (1, 1, 0), (0, 0, 0))))

    def test_a_disarm_that_did_not_restore_does_not_pass(self):
        # Kills: the `after == pre` restore term dropped.
        self.assertFalse(st.pred_must_fail(control((0, 0, 0), (1, 0, 0), (1, 0, 0))))

    def test_an_unreadable_reading_is_not_a_pass(self):
        o = control((0, 0, 0), (1, 0, 0), (0, 0, 0))
        broken = copy.deepcopy(o)
        broken["post"] = {"observation": {"readable": False, "cause": "no rail"}}
        self.assertIsNone(st.pred_arm_probe_agrees_with_pre_state(broken))
        self.assertFalse(st.pred_must_fail(broken))


if __name__ == "__main__":
    unittest.main()
