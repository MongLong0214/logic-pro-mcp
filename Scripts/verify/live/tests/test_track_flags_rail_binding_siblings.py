#!/usr/bin/env python3
"""AFTER-only #1028 sibling contract: the existing flags control sees parser refusal.

The original three frozen RED functions remain unchanged in test_track_flags_rail_binding.py.
"""

import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(os.path.dirname(HERE)))

from live.tests import test_track_flags_rail_binding as rail_witness
from live import fixture, probes as readers


class TrackFlagsRailBindingSiblings(unittest.TestCase):
    def test_flags_show_keeps_unique_clear_control_and_refuses_ambiguous_rails(self):
        witness = rail_witness.TrackFlagsRailBinding()
        witness.setUp()
        try:
            spec = fixture.spec("locale_campaign_19")
            clear = readers.track_flags_parse(witness.samples[False]["raw"])
            self.assertTrue(readers.flags_show(spec, {"observation": clear}))
            for first in (False, True):
                with self.subTest(first=first):
                    ambiguous = readers.track_flags_parse(witness.combined(first, not first))
                    self.assertFalse(readers.flags_show(spec, {"observation": ambiguous}))
        finally:
            witness.tearDown()


if __name__ == "__main__":
    unittest.main()
