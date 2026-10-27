#!/usr/bin/env python3
"""Offline contract tests for the #291 fixed-verifier pilot."""

import json
import os
import sys
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
VERIFY = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, VERIFY)

import runner_live  # noqa: E402
import setups  # noqa: E402
import engine  # noqa: E402
import evidence_doc  # noqa: E402
from live import fixture, spec_probes  # noqa: E402


APPLE_ROWS = {
    "input": "Input",
    "stereo_output": "Stereo Output",
    "no_output": "No Output",
    "bus": "Bus",
    "physical_output": "Output",
}


def routing_run(outputs=None, inputs=None, occupied=None, count=21, failures=0, send_counts=None):
    if outputs is None:
        outputs = {index: "Stereo Output" for index in range(19)}
    if inputs is None:
        inputs = {1: "Input 1"}
    occupied = occupied or set()
    send_counts = send_counts or [1] * count
    strips = []
    for index in range(count):
        strips.append({
            "outputs": ([{"description": outputs[index]}] if index in outputs else []),
            "inputs": ([{"description": inputs[index]}] if index in inputs else []),
            "sends": [{"occupied": index in occupied and slot == 0}
                      for slot in range(send_counts[index])],
        })
    return {"observation": {"readable": True, "mixer_found": True, "strips": strips,
                            "read_failures": failures}}


def flags_run():
    names = fixture.FIXTURES["locale_campaign_mixer"]["names"]
    tracks = [{"index": index, "name": name, "arm": 0, "mute": 0, "solo": 0}
              for index, name in enumerate(names)]
    return {"observation": {"readable": True, "track_count": len(tracks), "tracks": tracks}}


class Sidecars:
    def __init__(self):
        self.kept = []

    def sidecar(self, data):
        self.kept.append(data)
        return "kept-sha"


class MixerSession:
    def __init__(self, edges, data_source="ax_poll", cache_age=0.01, refreshed=True,
                 product_run=None, before_fetched="2026-10-27T00:00:00Z",
                 after_fetched="2026-10-27T00:00:01Z", changed_sections=None,
                 input_states=None, omitted_input_observations=None,
                 output_states=None, omitted_output_observations=None):
        self.edges = edges
        self.data_source = data_source
        self.cache_age = cache_age
        self.refreshed = refreshed
        self.product_run = product_run or routing_run()
        self.before_fetched = before_fetched
        self.after_fetched = after_fetched
        self.changed_sections = (["project", "tracks", "transport", "mixer"]
                                 if changed_sections is None else changed_sections)
        self.input_states = input_states or {}
        self.omitted_input_observations = omitted_input_observations or set()
        self.output_states = output_states or {}
        self.omitted_output_observations = omitted_output_observations or set()
        self.calls = []
        self.reads = 0

    def call_structured(self, tool, command, params, _timeout):
        self.calls.append((tool, command, params))
        return {"operation": "system.refresh_cache", "refreshed": self.refreshed,
                "source": "ax_fallback_poller",
                "changed_sections": self.changed_sections,
                "message": "State refresh completed via AX fallback poller."}

    def read(self, uri, _timeout):
        assert uri == spec_probes.MIXER_STATE
        self.reads += 1
        observed = self.product_run["observation"]
        strips = []
        for index, strip in enumerate(observed["strips"]):
            row = {"trackIndex": index, "send_slots": [
                {"ordinal": ordinal,
                 "state": "occupied_unknown_destination" if slot["occupied"] else "observed_empty"}
                for ordinal, slot in enumerate(strip["sends"])
            ]}
            if strip["inputs"]:
                row["input"] = strip["inputs"][0]["description"]
                observation = {"state": "observed_source", "source": row["input"]}
            else:
                observation = {"state": "no_slot", "source": None}
            if index in self.input_states:
                observation = {"state": self.input_states[index], "source": None}
            if index not in self.omitted_input_observations:
                row["input_observation"] = observation
            if strip["outputs"]:
                row["output"] = strip["outputs"][0]["description"]
                output_observation = {
                    "state": "observed_destination", "destination": row["output"]}
            else:
                output_observation = {"state": "no_slot", "destination": None}
            if index in self.output_states:
                output_observation = {"state": self.output_states[index], "destination": None}
            if index not in self.omitted_output_observations:
                row["output_observation"] = output_observation
            strips.append(row)
        return json.dumps({"data_source": self.data_source, "cache_age_sec": self.cache_age,
                           "fetched_at": self.before_fetched if self.reads == 1 else self.after_fetched,
                           "strips": strips, "routing_graph": {"edges": self.edges}})


class PinnedRoutingRowsTestCase(unittest.TestCase):
    """Keep downstream contract tests independent of an installed Logic app.

    Production still resolves these labels from Apple's locale tables. These
    tests exercise the routing normalization, refresh and fixture contracts
    with the exact values they declare, including on non-Logic CI hosts.
    """

    def setUp(self):
        super().setUp()
        patcher = mock.patch.object(spec_probes, "_routing_rows", return_value=APPLE_ROWS)
        patcher.start()
        self.addCleanup(patcher.stop)


class RoutingSpecProbeTests(PinnedRoutingRowsTestCase):

    @staticmethod
    def fully_observed_run():
        return routing_run(outputs={index: "Stereo Output" for index in range(21)})

    def test_probe_normalizes_outputs_and_send_occupancy(self):
        run = routing_run(outputs={**{index: "Stereo Output" for index in range(19)},
                                   1: "Output 3-4", 2: "Bus 17"},
                          occupied={1}, count=22)
        got = spec_probes.routing_slots_of(run, APPLE_ROWS)
        self.assertEqual(got["strip_count"], 22)
        self.assertEqual(got["occupied_strips"], [1])
        self.assertEqual(got["outputs"][1], {"kind": "physical", "ports": [3, 4]})
        self.assertEqual(got["outputs"][2], {"kind": "bus", "number": 17})
        self.assertEqual(got["outputs"][0], {"kind": "stereo_output"})
        self.assertEqual(got["inputs"][1], {"kind": "physical", "ports": [1]})

    def test_probe_refuses_an_incomplete_mixer_walk(self):
        with self.assertRaisesRegex(spec_probes.Unreadable, "read failure"):
            spec_probes.routing_slots_of(routing_run(failures=1), APPLE_ROWS)

    def test_live_probe_keeps_the_raw_walk_as_a_sidecar(self):
        sidecars = Sidecars()
        saved = spec_probes.live_probes.run
        complete = self.fully_observed_run()
        spec_probes.live_probes.run = lambda name, args: complete
        session = MixerSession([], product_run=complete)
        try:
            text = spec_probes.routing_slots(
                {"life": sidecars, "lproj": "en",
                 "decl": setups.declaration("lpm-locale-campaign-mixer"),
                 "session": session})
        finally:
            spec_probes.live_probes.run = saved
        got = json.loads(text)
        self.assertEqual(got["walk_sha256"], "kept-sha")
        self.assertEqual(got["strip_count"], 21)
        self.assertEqual(got["product_send_edges"], [])
        self.assertEqual(got["product_edges"], [])
        self.assertEqual(session.calls, [("logic_system", "refresh_cache", {})])
        self.assertEqual(len(sidecars.kept), 3)

    def test_refresh_receipt_uses_production_structured_content_without_weakening_text_calls(self):
        record = {"sent": True, "reply": {"result": {
            "content": [{"type": "text", "text": "State refresh completed via AX fallback poller."}],
            "structuredContent": {"operation": "system.refresh_cache", "refreshed": True,
                                  "source": "ax_fallback_poller",
                                  "changed_sections": ["mixer"],
                                  "message": "State refresh completed via AX fallback poller."},
        }}}
        with self.assertRaisesRegex(runner_live.runner.StepUnreadable, "not the same JSON"):
            runner_live.text_of(record, "content")
        self.assertEqual(runner_live.structured_of(record)["refreshed"], True)

    def test_live_probe_rejects_stale_or_non_ax_product_routing(self):
        sidecars = Sidecars()
        saved = spec_probes.live_probes.run
        complete = self.fully_observed_run()
        spec_probes.live_probes.run = lambda name, args: complete
        try:
            for session, reason in (
                (MixerSession([], data_source="mcu", product_run=complete), "data_source"),
                (MixerSession([], cache_age=9, product_run=complete), "cache_age_sec"),
                (MixerSession([], refreshed=False, product_run=complete), "refresh_cache"),
                (MixerSession([], after_fetched="2026-10-27T00:00:00Z",
                              product_run=complete), "fetched_at"),
            ):
                with self.subTest(reason=reason), self.assertRaisesRegex(
                        spec_probes.Unreadable, reason):
                    spec_probes.routing_slots(
                        {"life": sidecars, "lproj": "en",
                         "decl": setups.declaration("lpm-locale-campaign-mixer"),
                         "session": session})
        finally:
            spec_probes.live_probes.run = saved

    def test_live_probe_requires_the_requested_cycle_to_write_mixer(self):
        sidecars = Sidecars()
        saved = spec_probes.live_probes.run
        complete = self.fully_observed_run()
        spec_probes.live_probes.run = lambda name, args: complete
        try:
            with self.assertRaisesRegex(spec_probes.Unreadable, "Mixer section"):
                spec_probes.routing_slots(
                    {"life": sidecars, "lproj": "en",
                     "decl": setups.declaration("lpm-locale-campaign-mixer"),
                     "session": MixerSession([], product_run=complete,
                                             changed_sections=["project", "tracks"])})
        finally:
            spec_probes.live_probes.run = saved

    def test_live_probe_accepts_a_cold_cache_before_timestamp(self):
        sidecars = Sidecars()
        saved = spec_probes.live_probes.run
        complete = self.fully_observed_run()
        spec_probes.live_probes.run = lambda name, args: complete
        try:
            got = json.loads(spec_probes.routing_slots(
                {"life": sidecars, "lproj": "en",
                 "decl": setups.declaration("lpm-locale-campaign-mixer"),
                 "session": MixerSession([], product_run=complete, before_fetched=None)}))
        finally:
            spec_probes.live_probes.run = saved
        self.assertEqual(got["strip_count"], 21)

    def test_live_probe_rejects_missing_or_unreadable_product_input_status(self):
        sidecars = Sidecars()
        saved = spec_probes.live_probes.run
        complete = self.fully_observed_run()
        spec_probes.live_probes.run = lambda name, args: complete
        try:
            cases = (
                MixerSession([], product_run=complete, omitted_input_observations={0}),
                MixerSession([], product_run=complete, input_states={0: "unreadable"}),
            )
            for session in cases:
                with self.subTest(session=session), self.assertRaisesRegex(
                        spec_probes.Unreadable, "input observation"):
                    spec_probes.routing_slots(
                        {"life": sidecars, "lproj": "en",
                         "decl": setups.declaration("lpm-locale-campaign-mixer"),
                         "session": session})
        finally:
            spec_probes.live_probes.run = saved

    def test_live_probe_rejects_product_output_nil_as_unknown_not_absent(self):
        sidecars = Sidecars()
        saved = spec_probes.live_probes.run
        incomplete = routing_run()
        spec_probes.live_probes.run = lambda name, args: incomplete
        try:
            with self.assertRaisesRegex(spec_probes.Unreadable, "output"):
                spec_probes.routing_slots(
                    {"life": sidecars, "lproj": "en",
                     "decl": setups.declaration("lpm-locale-campaign-mixer"),
                     "session": MixerSession([], product_run=incomplete,
                                             output_states={0: "unreadable"})})
        finally:
            spec_probes.live_probes.run = saved

    def test_live_probe_accepts_explicit_no_output_slot_without_inventing_a_route(self):
        sidecars = Sidecars()
        saved = spec_probes.live_probes.run
        # The committed 21-strip fixture has two terminal strips with no output
        # control. That is a positive no-slot observation, not output:nil alone.
        fixture = routing_run(outputs={index: "Stereo Output" for index in range(19)})
        spec_probes.live_probes.run = lambda name, args: fixture
        try:
            got = json.loads(spec_probes.routing_slots(
                {"life": sidecars, "lproj": "en",
                 "decl": setups.declaration("lpm-locale-campaign-mixer"),
                 "session": MixerSession([], product_run=fixture)}))
        finally:
            spec_probes.live_probes.run = saved
        self.assertEqual(got["outputs"][19:], [None, None])

    def test_live_probe_rejects_a_fresh_product_topology_that_differs_from_the_ax_walk(self):
        sidecars = Sidecars()
        saved = spec_probes.live_probes.run
        independent = routing_run(occupied={1}, count=22,
            outputs={index: "Stereo Output" for index in range(22)})
        product = self.fully_observed_run()
        spec_probes.live_probes.run = lambda name, args: independent
        try:
            with self.assertRaisesRegex(spec_probes.Unreadable, "topology differs"):
                spec_probes.routing_slots(
                    {"life": sidecars, "lproj": "en",
                     "decl": setups.declaration("lpm-locale-campaign-mixer"),
                     "session": MixerSession([], product_run=product)})
        finally:
            spec_probes.live_probes.run = saved

    def test_live_probe_rejects_a_product_send_edge_without_destination_witness(self):
        sidecars = Sidecars()
        saved = spec_probes.live_probes.run
        complete = routing_run(occupied={1},
            outputs={index: "Stereo Output" for index in range(21)})
        spec_probes.live_probes.run = lambda name, args: complete
        try:
            with self.assertRaisesRegex(spec_probes.Unreadable, "source-edge"):
                spec_probes.routing_slots(
                    {"life": sidecars, "lproj": "en",
                     "decl": setups.declaration("lpm-locale-campaign-mixer"),
                     "session": MixerSession(
                         [{"kind": "send", "source": "mix_1", "destination": "bus_1"}],
                         product_run=complete)})
        finally:
            spec_probes.live_probes.run = saved

    def test_send_actuator_uses_the_declared_strip_and_keeps_its_record(self):
        sidecars = Sidecars()
        saved = spec_probes.controls.select_send_bus
        spec_probes.controls.select_send_bus = lambda lproj, strip: {
            "strip": strip, "selected": "Bus 256", "press": {"status": -25204},
            "select_status": -25204}
        try:
            text = spec_probes.routing_send_assign(
                {"life": sidecars, "lproj": "en",
                 "decl": setups.declaration("lpm-locale-campaign-mixer")}, strip=1)
        finally:
            spec_probes.controls.select_send_bus = saved
        self.assertEqual(json.loads(text), {
            "record_sha256": "kept-sha", "selected": "Bus 256", "strip": 1})
        self.assertEqual(len(sidecars.kept), 1)


class MixerFixtureGateTests(PinnedRoutingRowsTestCase):

    def test_mixer_fixture_is_live_and_its_strip_count_is_gated(self):
        decl = setups.declaration("lpm-locale-campaign-mixer")
        life = runner_live.LiveLifecycle()
        self.assertEqual(life.fixture_problems(decl), [])
        reading = runner_live.gate_reading_of(
            fixture.FIXTURES[decl["live"]], flags_run(), None, routing_run(), "en")
        self.assertEqual(setups.gate_problems(decl, reading, reading), [])
        reading["fingerprint"]["mixer_strips"] = 20
        self.assertEqual(setups.gate_problems(decl, reading, reading),
                         ["20 Mixer strips, declared 21"])

    def test_mixer_fixture_gate_refuses_partial_or_wrong_routing_state(self):
        decl = setups.declaration("lpm-locale-campaign-mixer")
        fx = fixture.FIXTURES[decl["live"]]
        partial = runner_live.gate_reading_of(fx, flags_run(), None,
                                              routing_run(failures=9), "en")
        self.assertTrue(any("routing" in problem.lower() for problem in
                            setups.gate_problems(decl, partial, partial)))

        wrong = runner_live.gate_reading_of(
            fx, flags_run(), None,
            routing_run(outputs={}, inputs={}, occupied={1}, send_counts=[2] * 21), "en")
        problems = setups.gate_problems(decl, wrong, wrong)
        for field in ("occupied_strips", "send_counts", "inputs", "outputs"):
            self.assertTrue(any(problem.startswith(setups.ROUTING_FINGERPRINT_LABELS[field])
                                for problem in problems), (field, problems))

    def test_reset_fingerprint_requires_the_exact_declared_routing(self):
        fx = fixture.FIXTURES["locale_campaign_mixer"]
        exact = runner_live.gate_reading_of(fx, flags_run(), None, routing_run(), "en")
        self.assertTrue(fixture.fingerprint_matches(fx, exact["fingerprint"]))
        replacements = {"occupied_strips": [1], "send_counts": [], "inputs": [], "outputs": []}
        for field, replacement in replacements.items():
            wrong = json.loads(json.dumps(exact["fingerprint"]))
            wrong["routing"][field] = replacement
            self.assertFalse(fixture.fingerprint_matches(fx, wrong), field)


class RoutingAcceptanceTests(unittest.TestCase):

    @staticmethod
    def observation(step, value):
        return evidence_doc.make_observation(step, json.dumps(value, sort_keys=True))

    def send_row_and_values(self):
        spec_path = os.path.join(os.path.dirname(os.path.dirname(VERIFY)),
                                 "docs", "acceptance", "291.json")
        with open(spec_path, encoding="utf-8") as handle:
            row = next(row for row in json.load(handle)["rows"]
                       if row["id"] == "send-occupancy-is-not-an-edge")

        as_found = {"strip_count": 21, "occupied_strips": [],
                    "send_counts": [1] * 21,
                    "inputs": [None, {"kind": "physical", "ports": [1]}] + [None] * 19,
                    "outputs": [{"kind": "stereo_output"}] * 19 + [None, None]}
        after = {"strip_count": 22, "occupied_strips": [1],
                 "send_counts": [1, 2] + [1] * 20,
                 "inputs": [None, {"kind": "physical", "ports": [1]}] + [None] * 20,
                 "product_edges": [],
                 "product_send_edges": [],
                 "outputs": [{"kind": "stereo_output"}] * 19 + [None, None, None]}
        reply = {"strips": {"witnesses": {"count": 22},
                              "rows": [{"strip_index": 1,
                                        "send_slots": [{"ordinal": 1,
                                                        "state": "occupied_unknown_destination"}]}]},
                 "routing": {"coverage": "partial", "graph": {"sends": {"state": "partial"}},
                             "edges": []}}
        baseline_reply = {"strips": {"witnesses": {"count": 21}, "rows": []},
                          "routing": {"coverage": "partial",
                                      "graph": {"sends": {"state": "partial"}}, "edges": []}}
        values = {"baseline_reply": baseline_reply, "as_found": as_found,
                  "mutate": {"selected": "Bus 256"}, "pre": after,
                  "reply": reply, "post": after, "undo": {"state": "A"},
                  "restored": as_found}
        return row, values

    def evaluate(self, row, values):
        run_row = {"observations": {
            step["as"]: self.observation(step, values[step["as"]])
            for step in row["steps"] + row["restore"]
        }}
        return engine.evaluate_row(row, run_row, "en")

    def test_send_undo_must_restore_the_original_send_topology(self):
        row, values = self.send_row_and_values()
        values["restored"] = {**values["restored"], "send_counts": [2] * 21}
        verdict = self.evaluate(row, values)
        self.assertEqual(verdict["verdict"], "FAIL", verdict)
        self.assertTrue(any("send_counts" in reason for reason in verdict["reasons"]), verdict)

    def test_inspect_reply_cannot_invent_a_send_edge_absent_from_product_state(self):
        row, values = self.send_row_and_values()
        values["reply"] = json.loads(json.dumps(values["reply"]))
        values["reply"]["routing"]["edges"] = [
            {"kind": "send", "source": "mix_1", "destination": "bus_1"}
        ]
        verdict = self.evaluate(row, values)
        self.assertEqual(verdict["verdict"], "FAIL", verdict)
        self.assertTrue(any("reply.routing.edges" in reason
                            for reason in verdict["reasons"]), verdict)


if __name__ == "__main__":
    unittest.main()
