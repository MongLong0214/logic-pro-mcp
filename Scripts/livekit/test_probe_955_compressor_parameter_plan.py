#!/usr/bin/env python3
"""Contract tests for the bounded #955 Compressor plan receipt."""

from __future__ import annotations

import copy
import unittest

from probe_955_compressor_parameter_plan import evaluate_plan


TARGET_REF = "ins_00000000-0000-0000-0000-000000000955"


def read_response(param: str, unit: str, raw: object) -> dict:
    return {
        "state": "A",
        "success": True,
        "verified": True,
        "hc_schema": 2,
        "operation": "logic_plugins.get_param_verified",
        "parameter_read_status": "read",
        "observation_scope": "current_insert_parameter",
        "verify_source": "ax_plugin_window",
        "write_attempted": False,
        "target_identity": {
            "track_index": 13,
            "insert": 1,
            "plugin_id": "logic.stock.effect.compressor",
        },
        "param": param,
        "raw_unit": unit,
        "observed_raw": raw,
        "plugin_view_restore_observed": True,
        "editor_close_observed": True,
    }


def plan_body() -> dict:
    limiter = read_response("limiter_on", "boolean", False)
    threshold = read_response("threshold", "normalized", 51)
    return {
        "state": "A",
        "success": True,
        "verified": True,
        "hc_schema": 2,
        "operation": "logic_plugins.plan_parameter_changes",
        "complete": True,
        "observation_scope": "requested_supported_subset",
        "atomic_snapshot": False,
        "application_authorized": False,
        "write_attempted": False,
        "target_ref": TARGET_REF,
        "target_identity": {
            "track_index": 13,
            "insert": 1,
            "plugin_id": "logic.stock.effect.compressor",
        },
        "entries": [
            {
                "param": "limiter_on",
                "status": "unchanged",
                "raw_unit": "boolean",
                "requested": {"param": "limiter_on", "value": False, "unit": "boolean"},
                "requested_value": 0,
                "observed_before": False,
                "delta": 0,
                "read_observations": [
                    {"bookend": "initial", "response": limiter},
                    {"bookend": "final", "response": copy.deepcopy(limiter)},
                ],
            },
            {
                "param": "threshold",
                "status": "change",
                "raw_unit": "normalized",
                "requested": {"param": "threshold", "value": 38, "unit": "percent"},
                "requested_value": 38,
                "observed_before": 51,
                "delta": -13,
                "read_observations": [
                    {"bookend": "initial", "response": threshold},
                    {"bookend": "final", "response": copy.deepcopy(threshold)},
                ],
            },
        ],
    }


class ParameterPlanReceiptTests(unittest.TestCase):
    def test_accepts_stable_read_only_two_parameter_plan(self) -> None:
        verdict = evaluate_plan(plan_body(), TARGET_REF, 13, 1)
        self.assertTrue(verdict["pass"])
        self.assertTrue(all(verdict["checks"].values()))

    def test_rejects_application_authority(self) -> None:
        body = plan_body()
        body["application_authorized"] = True
        self.assertFalse(evaluate_plan(body, TARGET_REF, 13, 1)["pass"])

    def test_rejects_changed_bookend(self) -> None:
        body = plan_body()
        body["entries"][1]["read_observations"][1]["response"]["observed_raw"] = 52
        self.assertFalse(evaluate_plan(body, TARGET_REF, 13, 1)["pass"])

    def test_rejects_wrong_target_identity(self) -> None:
        body = plan_body()
        body["entries"][0]["read_observations"][0]["response"]["target_identity"]["insert"] = 2
        self.assertFalse(evaluate_plan(body, TARGET_REF, 13, 1)["pass"])


if __name__ == "__main__":
    unittest.main()
