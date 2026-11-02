#!/usr/bin/env python3
"""Offline contracts for the independent #971 Mixer-visibility probe."""

import json
import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(os.path.dirname(HERE)))

import runner  # noqa: E402
import evidence_doc  # noqa: E402
from live import spec_probes  # noqa: E402


def routing_run(found, *, walk_readable=True, child_failures=None, nodes=None):
    return {
        "observation": {
            "readable": True,
            "mixer_found": found,
            "raw": {
                "walk": {
                    "readable": walk_readable,
                    "value": {
                        "nodes": list(nodes or []),
                        "children_read_failures": list(child_failures or []),
                    },
                }
            },
        }
    }


class Sidecars:
    def __init__(self):
        self.kept = []

    def sidecar(self, data):
        self.kept.append(data)
        return "walk-sha"


class MixerVisibilityProbeTests(unittest.TestCase):
    def test_visible_mixer_is_true(self):
        self.assertEqual(spec_probes.mixer_visible_of(routing_run(True)), {"visible": True})

    def test_complete_walk_without_mixer_is_false(self):
        self.assertEqual(spec_probes.mixer_visible_of(routing_run(False)), {"visible": False})

    def test_hidden_is_unreadable_when_any_child_read_failed(self):
        run = routing_run(False, child_failures=[{"path": [0], "error": "cannot complete"}])
        with self.assertRaisesRegex(spec_probes.Unreadable, "child-read failure"):
            spec_probes.mixer_visible_of(run)

    def test_hidden_is_unreadable_when_the_walk_is_incomplete(self):
        with self.assertRaisesRegex(spec_probes.Unreadable, "complete walk"):
            spec_probes.mixer_visible_of(routing_run(False, walk_readable=False))

    def test_hidden_is_unreadable_when_a_node_attribute_failed(self):
        run = routing_run(False, nodes=[{"read_errors": ["AXHelp:-25204"]}])
        with self.assertRaisesRegex(spec_probes.Unreadable, "node-read failure"):
            spec_probes.mixer_visible_of(run)

    def test_live_probe_keeps_the_complete_raw_walk(self):
        run = routing_run(False)
        sidecars = Sidecars()
        saved = spec_probes.live_probes.run
        spec_probes.live_probes.run = lambda name, args: run
        try:
            got = json.loads(spec_probes.mixer_visible({"life": sidecars, "lproj": "en"}))
        finally:
            spec_probes.live_probes.run = saved
        self.assertEqual(got, {"visible": False, "walk_sha256": "walk-sha"})
        self.assertEqual(len(sidecars.kept), 1)


class SessionBindingTests(unittest.TestCase):
    @staticmethod
    def observation(name, value):
        step = {"as": name, "call": {"tool": "logic_project", "command": "x", "params": {}}}
        return evidence_doc.make_observation(step, json.dumps(value))

    def test_exact_session_fields_resolve_from_prior_call_replies(self):
        ctx = {"observations": {
            "inspection": self.observation("inspection", {
                "snapshot_id": "snapshot-1", "project": {"project_ref": "project-1"}}),
            "plan": self.observation("plan", {"plan_id": "plan-1", "digest": "digest-1"}),
        }}
        plan = runner._resolved_call_params(ctx, "logic_project", "plan_session_repair", {
            "snapshot_id": {"$observation": "inspection.snapshot_id"},
            "policy": {
                "schema": "logic_pro_mcp_repair_policy.v1",
                "project_ref": {"$observation": "inspection.project.project_ref"},
                "targets": [], "roles": [], "outputs": [],
                "presentation": {"mixer_visible": False},
            },
        })
        self.assertEqual(plan["snapshot_id"], "snapshot-1")
        self.assertEqual(plan["policy"]["project_ref"], "project-1")
        apply = runner._resolved_call_params(ctx, "logic_project", "apply_session_repair", {
            "plan_id": {"$observation": "plan.plan_id"},
            "digest": {"$observation": "plan.digest"},
            "confirmed": True,
            "idempotency_key": "acceptance-971-mixer-hidden",
        })
        self.assertEqual(apply["plan_id"], "plan-1")
        self.assertEqual(apply["digest"], "digest-1")

    def test_unlisted_nested_binding_is_refused(self):
        ctx = {"observations": {"inspection": self.observation("inspection", {"x": "hidden"})}}
        with self.assertRaisesRegex(runner.StepUnreadable, "not an admitted session field"):
            runner._resolved_call_params(ctx, "logic_project", "plan_session_repair", {
                "policy": {"presentation": {
                    "mixer_visible": {"$observation": "inspection.x"}}},
            })


class AcceptanceContractTests(unittest.TestCase):
    @staticmethod
    def spec():
        path = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE)))),
                            "docs", "acceptance", "971.json")
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)

    def test_session_binding_paths_are_exact_and_semantics_stay_literal(self):
        import copy
        import engine

        spec = self.spec()
        self.assertEqual(engine.validate_spec(spec), [])
        mutant = copy.deepcopy(spec)
        mutant["rows"][0]["steps"][2]["call"]["params"]["policy"]["presentation"][
            "mixer_visible"] = {"$observation": "inspection.project.project_ref"}
        problems = engine.validate_spec(mutant)
        self.assertTrue(any("not an admitted session field" in problem for problem in problems),
                        problems)

    def test_dedicated_setup_enables_only_the_existing_saga_opt_in(self):
        import setups

        declaration = setups.declaration("lpm-locale-campaign-mixer-saga")
        self.assertEqual(declaration["live"], "locale_campaign_mixer")
        self.assertEqual(declaration["server_env"], {"LOGIC_MCP_ADR004_MUTATION_SAGA": "1"})
        self.assertEqual(declaration["gate"], ["fingerprint"])


if __name__ == "__main__":
    unittest.main()
