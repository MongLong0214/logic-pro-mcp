#!/usr/bin/env python3
"""#1028: independent arm readers cannot select between conflicting complete rails.

Positive states are the existing 73b5921c ko raw walks, not a product reply or an
acceptance row's supplied expectation. Duplicate/partial trees are constructed
counterexamples, not additional measured native observations. No AX API is called.
"""

import copy
import hashlib
import json
import os
import sys
import types
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(os.path.dirname(HERE)))

import probes as registered_probes  # noqa: E402
import setups  # noqa: E402
from live import probes as readers, spec_probes  # noqa: E402


class TrackFlagsRailBinding(unittest.TestCase):
    def setUp(self):
        self.samples = {}
        for state, filename in ((False, "track-flags-ko-clear.json"),
                                (True, "track-flags-ko-track-0-armed.json")):
            with open(os.path.join(HERE, "samples", filename), encoding="utf-8") as handle:
                sample = json.load(handle)
            self.assertEqual(sample["source"]["head"], "73b5921c516c08dd3396951ea88118f9366c8295")
            observed = sample["probe_output"]["observation"]
            self.assertEqual(observed["rails"], [{"path": observed["rail"],
                                                "items": 19, "items_with_arm": 19}])
            self.samples[state] = observed
        self.saved_run = readers.run
        self.kept = []
        self.asked = []
        self.raw = None

        def walk(name, args):
            self.asked.append((name, args))
            # Execute the real parser on the raw walk on every consumer read.
            return {"observation": readers.track_flags_parse(copy.deepcopy(self.raw))}

        readers.run = walk

        def sidecar(data):
            self.kept.append(data)
            return hashlib.sha256(data).hexdigest()

        self.ctx = {"lproj": "ko", "decl": setups.declaration("lpm-locale-campaign-19"),
                    "life": types.SimpleNamespace(sidecar=sidecar)}

    def tearDown(self):
        readers.run = self.saved_run

    def read(self, probe):
        args = {"index": 0} if probe == "track_armed" else {}
        text = registered_probes.run(probe, self.ctx, args)
        result = json.loads(text)
        self.assertEqual(result.pop("walk_sha256"), hashlib.sha256(self.kept[-1]).hexdigest())
        self.assertEqual(self.asked[-1][0], "track_flags_ax")
        return result

    def combined(self, first, second, partial=False):
        raw = copy.deepcopy(self.samples[first]["raw"])
        rail = self.samples[second]["rail"]
        target = rail[:-1] + [99]
        extra = []
        for node in self.samples[second]["raw"]["walk"]["value"]["nodes"]:
            path = node["path"]
            if path[:len(rail)] != rail:
                continue
            # A one-item secondary subtree remains ineligible for the 19-track fixture.
            if partial and len(path) > len(rail) and path[len(rail)] != 0:
                continue
            cloned = copy.deepcopy(node)
            cloned["path"] = target + path[len(rail):]
            extra.append(cloned)
        raw["walk"]["value"]["nodes"].extend(extra)
        return raw

    def test_unique_recorded_clear_and_armed_rails_reach_registered_readers(self):
        for state in (False, True):
            for probe in ("track_armed", "armed_set"):
                with self.subTest(state=state, probe=probe):
                    self.raw = self.samples[state]["raw"]
                    wanted = ({"track": 0, "armed": state, "name": "Absolute Zero"}
                              if probe == "track_armed" else {"armed": [0] if state else []})
                    self.assertEqual(self.read(probe), wanted)

    def test_conflicting_complete_rails_are_unreadable_in_both_orders(self):
        for first in (False, True):
            for probe in ("track_armed", "armed_set"):
                with self.subTest(first=first, probe=probe):
                    self.raw = self.combined(first, not first)
                    # This passes only when the real parser/consumer refuses ambiguity.
                    with self.assertRaisesRegex(registered_probes.ProbeUnreadable, "rail"):
                        self.read(probe)

    def test_one_complete_rail_remains_readable_with_a_smaller_partial_subtree(self):
        for state in (False, True):
            for probe in ("track_armed", "armed_set"):
                with self.subTest(state=state, probe=probe):
                    self.raw = self.combined(state, not state, partial=True)
                    parsed = readers.track_flags_parse(self.raw)
                    self.assertEqual(sorted(r["items"] for r in parsed["rails"]), [1, 19])
                    wanted = ({"track": 0, "armed": state, "name": "Absolute Zero"}
                              if probe == "track_armed" else {"armed": [0] if state else []})
                    self.assertEqual(self.read(probe), wanted)


if __name__ == "__main__":
    unittest.main()
