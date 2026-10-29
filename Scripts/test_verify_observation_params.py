#!/usr/bin/env python3
"""Focused tests for acceptance calls that consume session-issued string references."""

import json
import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "verify"))

import evidence_doc as E  # noqa: E402
import runner  # noqa: E402


class RecordingSession:
    def __init__(self):
        self.calls = []

    def call(self, tool, command, params, timeout_s):
        self.calls.append((tool, command, params, timeout_s))
        return json.dumps({"state": "A", "raw_value": 18.0})


class CleanLife:
    def now(self):
        return 0.0

    def problems(self, _ctx, _when):
        return []


class ScriptedSession(RecordingSession):
    def call(self, tool, command, params, timeout_s):
        self.calls.append((tool, command, params, timeout_s))
        if command == "get_inventory":
            return json.dumps({"plugins": [{
                "plugin_id": "logic.stock.effect.compressor",
                "plugin_insert_ref": "ins_from_row",
            }]})
        return json.dumps({"state": "A"})


def call(name, command, params):
    return {"as": name, "call": {
        "tool": "logic_plugins", "command": command, "params": params,
    }}


class ObservationParamResolutionTests(unittest.TestCase):
    def setUp(self):
        self.session = RecordingSession()
        inventory = call("inventory", "get_inventory", {"track": 12})
        raw = json.dumps({
            "state": "A",
            "plugins": [{
                "insert": 1,
                "plugin_id": "logic.stock.effect.compressor",
                "plugin_insert_ref": "ins_session_123",
            }],
        })
        self.ctx = {
            "session": self.session,
            "observations": {"inventory": E.make_observation(inventory, raw)},
        }

    def operation(self, path):
        return call("ratio", "get_param_verified", {
            "target_ref": {"$observation": path},
            "param": "ratio",
        })

    def test_prior_setup_call_path_supplies_the_exact_string(self):
        step = self.operation(
            'inventory.plugins[plugin_id="logic.stock.effect.compressor"].plugin_insert_ref')
        text = runner._take(self.ctx, step)
        self.assertEqual(json.loads(text)["raw_value"], 18.0)
        self.assertEqual(self.session.calls[0][2], {
            "target_ref": "ins_session_123", "param": "ratio",
        })

    def test_missing_path_refuses_before_the_operation_is_sent(self):
        step = self.operation("inventory.plugins[0].missing")
        with self.assertRaisesRegex(runner.StepUnreadable, "no such key"):
            runner._take(self.ctx, step)
        self.assertEqual(self.session.calls, [])

    def test_non_string_value_refuses_before_the_operation_is_sent(self):
        step = self.operation("inventory.plugins[0].insert")
        with self.assertRaisesRegex(runner.StepUnreadable, "not a string"):
            runner._take(self.ctx, step)
        self.assertEqual(self.session.calls, [])

    def test_duplicate_key_source_refuses_before_the_operation_is_sent(self):
        inventory = call("inventory", "get_inventory", {"track": 12})
        raw = '{"plugin_insert_ref":"first","plugin_insert_ref":"second"}'
        self.ctx["observations"]["inventory"] = E.make_observation(inventory, raw)
        step = self.operation("inventory.plugin_insert_ref")
        with self.assertRaisesRegex(runner.StepUnreadable, "appears twice"):
            runner._take(self.ctx, step)
        self.assertEqual(self.session.calls, [])

    def test_empty_string_refuses_before_the_operation_is_sent(self):
        inventory = call("inventory", "get_inventory", {"track": 12})
        self.ctx["observations"]["inventory"] = E.make_observation(
            inventory, '{"plugin_insert_ref":""}')
        step = self.operation("inventory.plugin_insert_ref")
        with self.assertRaisesRegex(runner.StepUnreadable, "empty string"):
            runner._take(self.ctx, step)
        self.assertEqual(self.session.calls, [])

    def test_non_target_parameter_reference_refuses_before_the_operation_is_sent(self):
        step = call("ratio", "get_param_verified", {
            "target_ref": "fixed",
            "param": {"$observation": "inventory.plugins[0].plugin_insert_ref"},
        })
        with self.assertRaisesRegex(runner.StepUnreadable, "not an admitted target parameter"):
            runner._take(self.ctx, step)
        self.assertEqual(self.session.calls, [])

    def test_nested_reserved_key_refuses_before_the_operation_is_sent(self):
        path = "inventory.plugins[0].plugin_insert_ref"
        for name, value in (
            ("target_ref", {"wrapper": {"$observation": path}}),
            ("param", {"wrapper": {"$observation": path}}),
        ):
            with self.subTest(name=name):
                self.session.calls.clear()
                step = call("ratio", "get_param_verified", {
                    "target_ref": "fixed", "param": "ratio", name: value,
                })
                with self.assertRaisesRegex(
                    runner.StepUnreadable,
                    r"reserved \$observation|not an admitted target parameter",
                ):
                    runner._take(self.ctx, step)
                self.assertEqual(self.session.calls, [])

    def test_run_row_makes_each_stored_reply_available_to_the_next_step(self):
        session = ScriptedSession()
        inventory = call("inventory", "get_inventory", {"track": 12})
        ratio = self.operation(
            'inventory.plugins[plugin_id="logic.stock.effect.compressor"].plugin_insert_ref')
        ctx = {"session": session, "life": CleanLife(), "row": "ratio", "lproj": "ko",
               "log": []}
        result = runner.run_row(ctx, {"steps": [inventory, ratio], "restore": []})
        self.assertEqual(session.calls[1][2]["target_ref"], "ins_from_row")
        self.assertIn("raw", result["observations"]["ratio"])
        self.assertNotIn("observations", ctx)


class ObservationParamAdmissionTests(unittest.TestCase):
    def row(self, source=None, target=None, restore=None):
        source = source or call("inventory", "get_inventory", {"track": 12})
        target = target or call("ratio", "get_param_verified", {
            "target_ref": {"$observation": "inventory.plugins[0].plugin_insert_ref"},
            "param": "ratio",
        })
        return {"steps": [source, target], "operation": "ratio", "restore": restore or []}

    def problems(self, row):
        return "\n".join(runner.engine.observation_param_problems(row))

    def test_prior_setup_call_reference_is_admissible(self):
        self.assertEqual(self.problems(self.row()), "")

    def test_reference_from_a_non_call_is_refused(self):
        source = {"as": "inventory", "read": {"uri": "logic://mixer"}}
        self.assertIn("not a setup call", self.problems(self.row(source=source)))

    def test_reference_on_a_non_operation_call_is_refused(self):
        target = call("setup2", "get_param_verified", {
            "target_ref": {"$observation": "inventory.plugins[0].plugin_insert_ref"},
        })
        row = self.row(target=target)
        row["steps"].append(call("ratio", "get_param_verified", {"target_ref": "fixed"}))
        row["operation"] = "ratio"
        self.assertIn("only the operation", self.problems(row))

    def test_future_or_operation_reply_reference_is_refused(self):
        row = self.row()
        row["steps"][1]["call"]["params"]["target_ref"] = {
            "$observation": "ratio.plugin_insert_ref",
        }
        self.assertIn("not bound before", self.problems(row))

    def test_unknown_source_is_refused(self):
        row = self.row()
        row["steps"][1]["call"]["params"]["target_ref"] = {
            "$observation": "missing.plugin_insert_ref",
        }
        self.assertIn("not bound before", self.problems(row))

    def test_whole_reply_reference_is_refused(self):
        row = self.row()
        row["steps"][1]["call"]["params"]["target_ref"] = {
            "$observation": "inventory",
        }
        self.assertIn("names a whole reply", self.problems(row))

    def test_malformed_path_is_refused(self):
        row = self.row()
        row["steps"][1]["call"]["params"]["target_ref"] = {
            "$observation": "inventory..plugin_insert_ref",
        }
        self.assertIn("cannot parse", self.problems(row))

    def test_restore_reference_is_refused(self):
        restore = [call("cleanup", "get_param_verified", {
            "target_ref": {"$observation": "inventory.plugins[0].plugin_insert_ref"},
        })]
        self.assertIn("only the operation", self.problems(self.row(restore=restore)))

    def test_reserved_key_with_extra_fields_is_refused(self):
        row = self.row()
        row["steps"][1]["call"]["params"]["target_ref"] = {
            "$observation": "inventory.plugins[0].plugin_insert_ref", "fallback": "fixed",
        }
        self.assertIn("exactly one field", self.problems(row))

    def test_reserved_key_nested_in_an_operation_parameter_is_refused(self):
        row = self.row()
        row["steps"][1]["call"]["params"]["target_ref"] = {
            "wrapper": {"$observation": "inventory.plugins[0].plugin_insert_ref"},
        }
        self.assertIn("top-level object", self.problems(row))

    def test_reserved_key_on_a_probe_is_refused_instead_of_becoming_a_literal(self):
        row = self.row()
        row["steps"].insert(1, {
            "as": "probe_with_reserved_key",
            "probe": {"name": "track_armed", "args": {
                "index": {"$observation": "inventory.track"},
            }},
        })
        self.assertIn("reserved $observation", self.problems(row))

    def test_non_target_operation_parameters_cannot_consume_observations(self):
        for name in ("param", "mode"):
            with self.subTest(name=name):
                row = self.row()
                row["steps"][1]["call"]["params"]["target_ref"] = "fixed"
                row["steps"][1]["call"]["params"][name] = {
                    "$observation": "inventory.plugins[0].plugin_insert_ref",
                }
                self.assertIn("not an admitted target parameter", self.problems(row))


if __name__ == "__main__":
    unittest.main()
