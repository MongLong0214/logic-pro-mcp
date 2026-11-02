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
from live import probes as live_probes, spec_probes  # noqa: E402


def routing_run(found, *, walk_readable=True, child_failures=None, nodes=None,
                frontier_truncations=None):
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
                        "frontier_truncations": list(frontier_truncations or []),
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

    def test_hidden_requires_an_explicitly_exhausted_frontier(self):
        run = routing_run(False)
        del run["observation"]["raw"]["walk"]["value"]["frontier_truncations"]
        with self.assertRaisesRegex(spec_probes.Unreadable, "complete walk"):
            spec_probes.mixer_visible_of(run)

    def test_hidden_is_unreadable_when_a_node_attribute_failed(self):
        run = routing_run(False, nodes=[{"read_errors": ["AXHelp:-25204"]}])
        with self.assertRaisesRegex(spec_probes.Unreadable, "node-read failure"):
            spec_probes.mixer_visible_of(run)

    def test_below_cutoff_mixer_is_unreadable_instead_of_hidden(self):
        run = routing_run(False, frontier_truncations=[{
            "path": [0] + [0] * 20,
            "children": 1,
        }])
        with self.assertRaisesRegex(spec_probes.Unreadable, "depth cutoff"):
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


class AXWalkExhaustionTests(unittest.TestCase):
    def test_cutoff_node_with_a_child_records_frontier_truncation(self):
        class FakeAX:
            def __init__(self, _pid):
                self.app = "app"
                self.timeout_status = 0

            def elements(self, element, name):
                if element == "app" and name == "AXWindows":
                    return {"status": 0, "elements": ["window"]}
                children = {
                    "window": ["level-1"],
                    "level-1": ["cutoff"],
                    "cutoff": ["mixer-below-cutoff"],
                }.get(element, [])
                return {"status": 0, "elements": children}

            def value(self, element, name):
                value = "window" if name == "AXTitle" else f"{element}-{name}"
                return {"status": 0, "value": value}

            def close(self):
                pass

        saved = live_probes.cfbridge.AX
        live_probes.cfbridge.AX = FakeAX
        try:
            walked = live_probes.ax_walk(123, max_depth=2)
        finally:
            live_probes.cfbridge.AX = saved
        self.assertTrue(walked["readable"])
        self.assertEqual(walked["value"]["frontier_truncations"], [{
            "path": [0, 0, 0],
            "children": 1,
        }])
        self.assertNotIn("mixer-below-cutoff", [
            node["AXRole"] for node in walked["value"]["nodes"]])


class SessionBindingTests(unittest.TestCase):
    @staticmethod
    def observation(name, value):
        step = {"as": name, "call": {"tool": "logic_project", "command": "x", "params": {}}}
        return evidence_doc.make_observation(step, json.dumps(value))

    def test_exact_session_fields_resolve_from_prior_call_replies(self):
        ctx = {"observations": {
            "inspection": self.observation("inspection", {
                "snapshot_id": "snapshot-1", "project": {"project_ref": "project-1"},
                "associations": {"rows": [{"track_index": 1, "track_ref": "track-1"}]}}),
            "plan": self.observation("plan", {"plan_id": "plan-1", "digest": "digest-1"}),
        }}
        plan = runner._resolved_call_params(ctx, "logic_project", "plan_session_repair", {
            "snapshot_id": {"$observation": "inspection.snapshot_id"},
            "policy": {
                "schema": "logic_pro_mcp_repair_policy.v1",
                "project_ref": {"$observation": "inspection.project.project_ref"},
                "targets": [{"handle": "source", "track_ref": {
                    "$observation": "inspection.associations.rows[track_index=1].track_ref"}}],
                "roles": [], "outputs": [],
                "presentation": {"mixer_visible": False},
            },
        })
        self.assertEqual(plan["snapshot_id"], "snapshot-1")
        self.assertEqual(plan["policy"]["project_ref"], "project-1")
        self.assertEqual(plan["policy"]["targets"][0]["track_ref"], "track-1")
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

    def test_combined_output_and_send_row_is_falsifiable_and_restores(self):
        import engine

        spec = self.spec()
        self.assertEqual(engine.validate_spec(spec), [])
        row = next(row for row in spec["rows"]
                   if row["id"] == "approved-output-and-send-are-independently-final")
        self.assertEqual(row["operation"], "apply")
        self.assertEqual(row["steps"][1]["probe"]["name"],
                         "routing_send_assign_stereo")
        self.assertEqual(row["restore"][-1]["wait"]["probe"]["name"], "routing_slots")
        self.assertEqual([step["as"] for step in row["restore"]], [
            "restore_output_inspection", "restore_output_plan", "restore_output_apply",
            "restore_send_inspection", "restore_send_plan", "restore_send_apply", "restored",
        ])
        output_policy = row["restore"][1]["call"]["params"]["policy"]
        send_policy = row["restore"][4]["call"]["params"]["policy"]
        self.assertEqual(output_policy["outputs"], [
            {"target": "source", "output": {"kind": "stereo_output"}},
        ])
        self.assertEqual(send_policy["sends"], [
            {"target": "source", "observed_ordinal": 1, "remove": True},
        ])
        self.assertTrue(row["counterexample"])
        self.assertEqual({counterexample["observation"]
                          for counterexample in row["restore_counterexample"]}, {"post"})

    def run_combined_row(self, row, *, fail_inspection=False):
        class Life:
            def __init__(self):
                self.clock = 0.0
                self.send_occupied = False
                self.output = {"kind": "stereo_output"}

            def now(self):
                return self.clock

            def sleep(self, seconds):
                self.clock += seconds

            def problems(self, _ctx, _when):
                return []

            def probe(self, name, _ctx, _args):
                if name == "routing_send_assign_stereo":
                    self.send_occupied = True
                    return json.dumps({"selected": "Stereo Output", "strip": 1})
                if name != "routing_slots":
                    raise AssertionError(name)
                return json.dumps({
                    "strip_count": 2,
                    "occupied_strips": [1] if self.send_occupied else [],
                    "send_counts": [0, 1],
                    "inputs": [None, {"kind": "physical", "ports": [1]}],
                    "outputs": [None, self.output],
                }, sort_keys=True)

        class Session:
            def __init__(self, life):
                self.life = life
                self.ctx = None
                self.calls = []

            def call(self, tool, command, params, timeout_s):
                step = self.ctx["step"]["as"]
                self.calls.append((step, tool, command, params, timeout_s))
                if step == "inspection" and fail_inspection:
                    raise runner.StepUnreadable("forced failure before apply")
                if command == "inspect_session":
                    return json.dumps({
                        "snapshot_id": f"snapshot-{step}",
                        "project": {"project_ref": f"project-{step}"},
                        "associations": {"rows": [
                            {"track_index": 1, "track_ref": f"track-{step}"},
                        ]},
                    })
                if command == "plan_session_repair":
                    if step == "restore_send_plan" and not self.life.send_occupied:
                        return json.dumps({"state": "C", "write_attempted": False,
                                           "executable": False})
                    reply = {"plan_id": f"plan-{step}", "digest": f"digest-{step}"}
                    if step == "plan":
                        reply.update({"executable": True, "steps": [
                            {"kind": "local_output"},
                            {"kind": "local_send_removal", "observed_ordinal": 1},
                        ]})
                    return json.dumps(reply)
                if command == "apply_session_repair":
                    if step == "baseline_apply":
                        return json.dumps({"state": "C", "write_attempted": False})
                    if step == "apply":
                        self.life.output = {"kind": "physical", "ports": [3, 4]}
                        self.life.send_occupied = False
                        return json.dumps({"state": "A", "write_attempted": True,
                                           "saga_state": "completed",
                                           "final_disposition": "completed_verified"})
                    if step == "restore_output_apply":
                        self.life.output = {"kind": "stereo_output"}
                    if step == "restore_send_apply":
                        self.life.send_occupied = False
                    return json.dumps({"state": "A", "write_attempted": True})
                raise AssertionError((tool, command))

        life = Life()
        session = Session(life)
        ctx = {"life": life, "session": session, "row": row["id"], "lproj": "en", "log": []}
        session.ctx = ctx
        steps = row["steps"]
        if fail_inspection:
            steps = [row["steps"][0], row["steps"][1], row["steps"][3]]
        result = runner.run_row(ctx, {"steps": steps, "restore": row["restore"]})
        return result, session

    def test_setup_send_is_removed_when_inspection_fails_before_apply(self):
        spec = self.spec()
        row = next(row for row in spec["rows"]
                   if row["id"] == "approved-output-and-send-are-independently-final")
        self.assertEqual(row["steps"][3]["as"], "inspection")
        result, session = self.run_combined_row(row, fail_inspection=True)

        self.assertIn("forced failure before apply", result["observations"]["inspection"]["unreadable"])
        restored = json.loads(result["observations"]["restored"]["raw"])
        as_found = json.loads(result["observations"]["as_found"]["raw"])
        self.assertEqual(restored, as_found)
        self.assertEqual([call[0] for call in session.calls[1:]], [
            "restore_output_inspection", "restore_output_plan", "restore_output_apply",
            "restore_send_inspection", "restore_send_plan", "restore_send_apply",
        ])

    def test_success_still_confirms_full_restore_when_send_cleanup_is_already_satisfied(self):
        import engine

        spec = self.spec()
        row = next(row for row in spec["rows"]
                   if row["id"] == "approved-output-and-send-are-independently-final")
        result, session = self.run_combined_row(row)

        send_plan = json.loads(result["observations"]["restore_send_plan"]["raw"])
        self.assertEqual(send_plan["state"], "C")
        self.assertNotIn("plan_id", send_plan)
        self.assertIn("no such key", result["observations"]["restore_send_apply"]["unreadable"])
        restored = json.loads(result["observations"]["restored"]["raw"])
        as_found = json.loads(result["observations"]["as_found"]["raw"])
        self.assertEqual(restored, as_found)
        self.assertNotIn("restore_send_apply", [call[0] for call in session.calls])
        verdict = engine.evaluate_row(row, result, "en")
        self.assertEqual(verdict["verdict"], "PASS", verdict)


if __name__ == "__main__":
    unittest.main()
