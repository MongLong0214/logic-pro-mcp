#!/usr/bin/env python3
"""Offline contract tests for the #291 fixed-verifier pilot."""

import json
import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
VERIFY = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, VERIFY)

import runner_live  # noqa: E402
import setups  # noqa: E402
from live import fixture, spec_probes  # noqa: E402


APPLE_ROWS = {
    "stereo_output": "Stereo Output",
    "no_output": "No Output",
    "bus": "Bus",
    "physical_output": "Output",
}


def routing_run(outputs=None, occupied=None, count=21, failures=0):
    outputs = outputs or {index: "Stereo Output" for index in range(19)}
    occupied = occupied or set()
    strips = []
    for index in range(count):
        strips.append({
            "outputs": ([{"description": outputs[index]}] if index in outputs else []),
            "inputs": ([{"description": "Input 1"}] if index == 1 else []),
            "sends": [{"occupied": index in occupied}],
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


class RoutingSpecProbeTests(unittest.TestCase):

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

    def test_probe_refuses_an_incomplete_mixer_walk(self):
        with self.assertRaisesRegex(spec_probes.Unreadable, "read failure"):
            spec_probes.routing_slots_of(routing_run(failures=1), APPLE_ROWS)

    def test_live_probe_keeps_the_raw_walk_as_a_sidecar(self):
        sidecars = Sidecars()
        saved = spec_probes.live_probes.run
        spec_probes.live_probes.run = lambda name, args: routing_run()
        try:
            text = spec_probes.routing_slots(
                {"life": sidecars, "lproj": "en",
                 "decl": setups.declaration("lpm-locale-campaign-mixer")})
        finally:
            spec_probes.live_probes.run = saved
        got = json.loads(text)
        self.assertEqual(got["walk_sha256"], "kept-sha")
        self.assertEqual(got["strip_count"], 21)
        self.assertEqual(len(sidecars.kept), 1)

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


class MixerFixtureGateTests(unittest.TestCase):

    def test_mixer_fixture_is_live_and_its_strip_count_is_gated(self):
        decl = setups.declaration("lpm-locale-campaign-mixer")
        life = runner_live.LiveLifecycle()
        self.assertEqual(life.fixture_problems(decl), [])
        reading = runner_live.gate_reading_of(
            fixture.FIXTURES[decl["live"]], flags_run(), None, routing_run())
        self.assertEqual(setups.gate_problems(decl, reading, reading), [])
        reading["fingerprint"]["mixer_strips"] = 20
        self.assertEqual(setups.gate_problems(decl, reading, reading),
                         ["20 Mixer strips, declared 21"])


if __name__ == "__main__":
    unittest.main()
