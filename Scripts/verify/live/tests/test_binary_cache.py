#!/usr/bin/env python3
"""Offline: a cached build is reused only when its head and sha256 still describe the file.

`binary.build` itself needs swift and minutes; the reuse decision is the part that can go wrong
silently (a rebuilt or replaced file served under an old record), and it is pure file I/O.
Each test names the mutation of binary.py it kills.
"""

import json
import os
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(os.path.dirname(HERE)))

from live import binary  # noqa: E402

SHA = "d7fb006de0ead0e94cf3a6f73eed709a983386dc"


class Cache(unittest.TestCase):

    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        os.makedirs(os.path.join(self.dir.name, "bin"))
        self.bin = os.path.join(self.dir.name, "bin", "LogicProMCP-x")
        with open(self.bin, "wb") as handle:
            handle.write(b"binary bytes")
        self.write_record(SHA, binary.sha256_of(self.bin))

    def tearDown(self):
        self.dir.cleanup()

    def write_record(self, head, digest):
        with open(binary.record_path(SHA, self.dir.name), "w") as handle:
            json.dump({"head": head, "binary_path": self.bin, "binary_sha256": digest}, handle)

    def test_a_matching_record_is_usable(self):
        self.assertTrue(binary.cached(SHA, self.dir.name)["usable"])

    def test_a_replaced_file_is_not_reused(self):
        # Kills: trusting the recorded sha256 instead of re-hashing the file.
        with open(self.bin, "wb") as handle:
            handle.write(b"other bytes")
        found = binary.cached(SHA, self.dir.name)
        self.assertFalse(found["usable"])
        self.assertNotEqual(found["measured_sha256"], found["record"]["binary_sha256"])

    def test_a_record_for_another_head_is_not_reused(self):
        # Kills: the head comparison dropped from `usable`.
        self.write_record("0" * 40, binary.sha256_of(self.bin))
        self.assertFalse(binary.cached(SHA, self.dir.name)["usable"])

    def test_a_missing_file_is_not_reused(self):
        os.unlink(self.bin)
        found = binary.cached(SHA, self.dir.name)
        self.assertFalse(found["usable"])
        self.assertIsNotNone(found["measure_error"])


if __name__ == "__main__":
    unittest.main()
