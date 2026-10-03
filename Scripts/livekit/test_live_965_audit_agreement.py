#!/usr/bin/env python3
"""Prove the #965 O3 harness's predicate refuses an audit that counted another bundle, a gap only one
side names, and an inspection that named no expected count. Nothing talks to Logic.

    python3 test_live_965_audit_agreement.py
"""
import importlib.util
import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
spec = importlib.util.spec_from_file_location("h965", os.path.join(HERE, "live_965_audit_reads_the_inspections_observation.py"))
H = importlib.util.module_from_spec(spec)
spec.loader.exec_module(H)


def row(expected, names_gap, audit_count):
    return {"inspection_expected_count": expected, "inspection_names_the_gap": names_gap,
            "audit_gap_file_count": audit_count}


class Agreement(unittest.TestCase):
    def test_the_same_gap_and_count_agree(self):
        self.assertTrue(H.agree(row(26, True, 26)))
        self.assertTrue(H.agree(row(19, False, None)))

    def test_another_count_or_a_one_sided_gap_does_not(self):
        self.assertFalse(H.agree(row(26, True, 31)), "the audit counted another bundle")
        self.assertFalse(H.agree(row(26, True, None)), "only the inspection names the gap")
        self.assertFalse(H.agree(row(19, False, 19)), "only the audit names the gap")
        self.assertFalse(H.agree(H.disagreeing(row(26, True, 26))))

    def test_no_expected_count_is_not_agreement(self):
        self.assertFalse(H.agree(row(None, False, None)))

    def test_the_gap_count_is_read_from_the_finding(self):
        audit = {"findings": [{"id": "track_readback_gap", "evidence": {"values": ["file_track_count=26", "ax_track_count=19"]}}]}
        self.assertEqual(H.gap_count(audit), 26)
        self.assertIsNone(H.gap_count({"findings": [{"id": "track_inventory_empty", "evidence": {"values": []}}]}))


if __name__ == "__main__":
    unittest.main()
