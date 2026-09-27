#!/usr/bin/env python3
"""Offline: a probe that returns zeros or nothing FAILS each positive control (PR #1033 review).

The controls (controls.py) are driven end to end against a fake Logic: `probes.run` reads a model,
the fake MCP server's logic_tracks calls change the model, the send selection and the fixture reset
change it too. With a faithful probe the registered `known` predicate passes; with a probe stubbed
to return zeros, or no tracks / no strips, or no inputs, it fails. Each test names the mutation of
probes.py it kills.
"""

import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(os.path.dirname(HERE)))

from live import controls, fixture, probes  # noqa: E402

FLAGS_SPEC = fixture.spec("locale_campaign_19")
MIXER_SPEC = fixture.spec("locale_campaign_mixer")
ALL_MATCH = {"arm": 1, "mute": 1, "solo": 1}
INPUT = "입력 1"


def known(name):
    control = probes.REGISTRY[name]["positive_control"]
    return lambda record: control["known"](fixture.spec(control["fixture"]), record)


class FakeLogic:
    """Track flags, one input label and per-strip occupied sends, as the probes would read them."""

    def __init__(self):
        self.flags = {i: {"arm": 0, "mute": 0, "solo": 0} for i in range(FLAGS_SPEC["track_count"])}
        self.occupied = set()

    def tool(self, name, command, args, timeout_s=None):
        self.flags[args["index"]][command] = 1 if args["enabled"] else 0
        return {"ok": True, "tool": name, "command": command}

    def flags_observation(self):
        tracks = [{"index": i, "name": FLAGS_SPEC["names"][i], "matches": dict(ALL_MATCH),
                   **self.flags[i]} for i in range(FLAGS_SPEC["track_count"])]
        return {"readable": True, "track_count": len(tracks), "tracks": tracks,
                "children_read_failures": 0}

    def mixer_observation(self):
        strips = []
        for i in range(MIXER_SPEC["mixer_strips"]):
            is_track = i < MIXER_SPEC["track_count"]
            strips.append({
                "outputs": [{"description": "St Out"}] if is_track else [],
                "inputs": [{"description": INPUT}] if i == MIXER_SPEC["input_strip"] else [],
                "sends": [{"occupied": i in self.occupied}] if is_track else []})
        return {"readable": True, "mixer_found": True, "strips": strips, "read_failures": 0}


def zeroed(observation):
    """What a probe that reads every flag as 0 and every slot as empty returns."""
    if "tracks" in observation:
        return dict(observation, tracks=[dict(t, arm=0, mute=0, solo=0)
                                         for t in observation["tracks"]])
    return dict(observation, strips=[dict(s, inputs=[], sends=[dict(x, occupied=False)
                                                                 for x in s["sends"]])
                                     for s in observation["strips"]])


def emptied(observation):
    """What a probe that finds nothing returns: still `readable`, with no tracks or strips."""
    if "tracks" in observation:
        return dict(observation, track_count=0, tracks=[])
    return dict(observation, strips=[])


class Harness(unittest.TestCase):

    def setUp(self):
        self.logic = FakeLogic()
        self.distort = None
        self.saved = (probes.run, controls.FLAG_WAIT_S, controls.SEND_WAIT_S,
                      controls.select_send_bus, controls.input_label, fixture.reset)
        controls.FLAG_WAIT_S = controls.SEND_WAIT_S = 0.0

        def run(name, args):
            observation = (self.logic.flags_observation() if name == "track_flags_ax"
                           else self.logic.mixer_observation())
            if self.distort:
                observation = self.distort(observation)
            return {"probe": name, "args": args, "observation": observation}

        def select(lproj, strip):
            self.logic.occupied.add(strip)
            return {"strip": strip, "selected": "버스 256"}

        def reset(name, lproj, server=None):
            self.logic.occupied.clear()
            return {"fixture": name}

        probes.run = run
        controls.select_send_bus = select
        controls.input_label = lambda lproj, number=1: {"readable": True, "value": INPUT}
        fixture.reset = reset

    def tearDown(self):
        (probes.run, controls.FLAG_WAIT_S, controls.SEND_WAIT_S,
         controls.select_send_bus, controls.input_label, fixture.reset) = self.saved

    def drive(self, name):
        return controls.drive(name, "ko", self.logic)["control"]


class TrackFlags(Harness):

    def test_a_faithful_probe_passes_and_leaves_every_flag_at_zero(self):
        self.assertTrue(known("track_flags_ax")(self.drive("track_flags_ax")))
        self.assertEqual({v for f in self.logic.flags.values() for v in f.values()}, {0})

    def test_a_probe_that_reads_every_flag_as_zero_fails(self):
        # Kills: track_flags_known dropping the `post == expected` clause (the phase-1 control
        # accepted an all-zero reading of an all-zero fixture).
        self.distort = zeroed
        self.assertFalse(known("track_flags_ax")(self.drive("track_flags_ax")))

    def test_a_probe_that_finds_no_tracks_fails(self):
        # Kills: track_flags_known without its track_count/names comparison.
        self.distort = emptied
        self.assertFalse(known("track_flags_ax")(self.drive("track_flags_ax")))

    def test_a_probe_that_sets_every_track_fails(self):
        # Kills: the predicate reading only the target track (a probe echoing one value for all).
        self.distort = lambda o: dict(o, tracks=[dict(t, **{k: max(u[k] for u in o["tracks"])
                                                            for k in ("arm", "mute", "solo")})
                                                 for t in o["tracks"]])
        self.assertFalse(known("track_flags_ax")(self.drive("track_flags_ax")))

    def test_a_flag_left_set_after_the_control_fails(self):
        # Kills: the `after == zeros` clause dropped; the unset calls are what restore the fixture.
        record = self.drive("track_flags_ax")
        record["after"] = record["post"]
        self.assertFalse(known("track_flags_ax")(record))


class RoutingSlots(Harness):

    def test_a_faithful_probe_passes(self):
        self.assertTrue(known("routing_slots_ax")(self.drive("routing_slots_ax")))

    def test_a_probe_that_reads_no_input_and_no_occupied_send_fails(self):
        # Kills: routing_slots_known dropping the input-label and `occupied(post) == [strip]`
        # clauses (the phase-1 control passed an all-empty reading of an all-empty fixture).
        self.distort = zeroed
        self.assertFalse(known("routing_slots_ax")(self.drive("routing_slots_ax")))

    def test_a_probe_that_finds_no_strips_fails(self):
        # Kills: the `len(pre["strips"]) == mixer_strips` clause dropped.
        self.distort = emptied
        self.assertFalse(known("routing_slots_ax")(self.drive("routing_slots_ax")))

    def test_a_probe_that_reads_no_input_fails(self):
        # Kills: the input-label clause dropped (the send half alone passing).
        self.distort = lambda o: dict(o, strips=[dict(s, inputs=[]) for s in o["strips"]])
        self.assertFalse(known("routing_slots_ax")(self.drive("routing_slots_ax")))

    def test_the_input_alone_is_not_enough(self):
        # Kills: the send half of the control ignored (only the input compared).
        self.distort = lambda o: dict(o, strips=[dict(s, sends=[dict(x, occupied=False)
                                                                 for x in s["sends"]])
                                                 for s in o["strips"]])
        self.assertFalse(known("routing_slots_ax")(self.drive("routing_slots_ax")))

    def test_a_send_seen_on_every_strip_fails(self):
        # Kills: `occupied(post)` compared by membership instead of equality.
        self.distort = lambda o: dict(o, strips=[dict(s, sends=[dict(x, occupied=True)
                                                                 for x in s["sends"]])
                                                 for s in o["strips"]])
        self.assertFalse(known("routing_slots_ax")(self.drive("routing_slots_ax")))


if __name__ == "__main__":
    unittest.main()
