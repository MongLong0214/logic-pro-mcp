#!/usr/bin/env python3
"""Prove the #965 O3 harness's predicate refuses an audit that counted another bundle, a gap only one
side names, and an inspection that named no expected count. Nothing talks to Logic.

    python3 test_live_965_audit_agreement.py
"""
import importlib.util
import os
import sys
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
spec = importlib.util.spec_from_file_location("h965", os.path.join(HERE, "live_965_audit_reads_the_inspections_observation.py"))
H = importlib.util.module_from_spec(spec)
spec.loader.exec_module(H)


def row(expected, names_gap, audit_count, answered=True, findings=None):
    if findings is None:
        findings = 0 if audit_count is None else 1
    return {"inspection_expected_count": expected, "inspection_names_the_gap": names_gap,
            "audit_gap_file_count": audit_count, "audit_answered": answered, "audit_gap_findings": findings}


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

    def test_an_audit_that_did_not_answer_is_not_agreement(self):
        # #1096 review round 1, R965-2: a missing or error-shaped audit read as "no gap".
        self.assertFalse(H.agree(row(19, False, None, answered=False)))
        self.assertFalse(H.agree(row(42, True, 42, answered=False)))
        for reply in (None, {}, {"_transport_error": None}, {"state": "C", "error": "invalid_params"},
                      {"status": "ok"}, {"findings": []}, {"status": "", "findings": []}):
            self.assertFalse(H.audit_answered(reply), repr(reply))
        self.assertTrue(H.audit_answered({"status": "degraded", "findings": []}))

    def test_a_gap_finding_whose_count_does_not_read_is_not_agreement(self):
        # #1096 review round 2, R965-2: a gap finding with empty or missing evidence read as no gap.
        for audit in ({"status": "degraded", "findings": [{"id": "track_readback_gap", "evidence": {"values": []}}]},
                      {"status": "degraded", "findings": [{"id": "track_readback_gap"}]},
                      {"status": "degraded", "findings": [{"id": "track_readback_gap",
                                                            "evidence": {"values": ["file_track_count=x"]}}]}):
            r = {"inspection_expected_count": 19, "inspection_names_the_gap": False, "audit_answered": True,
                 "audit_gap_findings": len(H.gap_findings(audit)), "audit_gap_file_count": H.gap_count(audit)}
            self.assertFalse(H.agree(r), repr(audit))
        two = {"status": "degraded", "findings": [
            {"id": "track_readback_gap", "evidence": {"values": ["file_track_count=42"]}},
            {"id": "track_readback_gap", "evidence": {"values": ["file_track_count=42"]}}]}
        self.assertIsNone(H.gap_count(two))
        self.assertFalse(H.agree(row(42, True, None, findings=2)))

    def test_read_language_end_to_end_refuses_a_malformed_gap(self):
        # The path the review drove: read_language over a driver, then agree.
        class Driver:
            def __init__(self, audit):
                self.audit = audit

            def tool(self, tool, command, params=None):
                if command == "inspect_session":
                    return {"tracks": {"witnesses": {"expected_count": 19, "expected_count_source": "project_file",
                                                      "count": 19}, "reasons": []}}
                if command == "audit":
                    return self.audit
                return {}

        malformed = {"status": "degraded", "findings": [{"id": "track_readback_gap", "evidence": {"values": []}}]}
        clean = {"status": "ok", "findings": []}
        with mock.patch.object(H.time, "sleep"):
            self.assertFalse(H.agree(H.read_language(Driver(malformed))))
            self.assertTrue(H.agree(H.read_language(Driver(clean))))

    def test_the_gap_count_is_read_from_the_finding(self):
        audit = {"findings": [{"id": "track_readback_gap", "evidence": {"values": ["file_track_count=26", "ax_track_count=19"]}}]}
        self.assertEqual(H.gap_count(audit), 26)
        self.assertIsNone(H.gap_count({"findings": [{"id": "track_inventory_empty", "evidence": {"values": []}}]}))


if __name__ == "__main__":
    unittest.main()
