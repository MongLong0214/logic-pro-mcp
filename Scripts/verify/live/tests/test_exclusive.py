#!/usr/bin/env python3
"""Offline: the live lock, the stale lock, and exclusivity over a fake process table.

The lock path is pointed at a temporary directory through LPM_LIVE_LOCK, never the real one.
Each test names the mutation of exclusive.py it kills.
"""

import json
import os
import socket
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(os.path.dirname(HERE)))

from live import exclusive  # noqa: E402


class Lock(unittest.TestCase):

    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.path = os.path.join(self.dir.name, "LIVE.lock")
        self.saved = os.environ.get(exclusive.LOCK_ENV)
        os.environ[exclusive.LOCK_ENV] = self.path

    def tearDown(self):
        if self.saved is None:
            os.environ.pop(exclusive.LOCK_ENV, None)
        else:
            os.environ[exclusive.LOCK_ENV] = self.saved
        self.dir.cleanup()

    def test_the_environment_variable_moves_the_lock(self):
        # Kills: lock_path() ignoring LPM_LIVE_LOCK (the tests would then touch the real lane).
        self.assertEqual(exclusive.lock_path(), self.path)

    def test_the_first_taker_wins_and_the_second_is_told_who(self):
        # Kills: O_EXCL dropped from the open flags (a second create would succeed).
        first = exclusive.acquire("first")
        second = exclusive.acquire("second")
        self.assertTrue(first["acquired"])
        self.assertFalse(second["acquired"])
        self.assertEqual(second["found"]["holder"]["purpose"], "first")
        self.assertEqual(second["found"]["pid"], os.getpid())
        self.assertEqual(second["found"]["host"], socket.gethostname())

    def test_a_lock_whose_pid_is_dead_is_stale_and_is_broken(self):
        # Kills: pid_alive answering True for a dead pid, or stale never set.
        with open(self.path, "w") as handle:
            json.dump({"pid": 999999, "host": socket.gethostname(), "purpose": "gone"}, handle)
        found = exclusive.read_lock(alive=lambda pid: False)
        self.assertTrue(found["stale"])
        taken = exclusive.acquire("after", alive=lambda pid: False)
        self.assertTrue(taken["acquired"])
        self.assertEqual(taken["broke_stale"]["was"]["pid"], 999999)
        self.assertTrue(os.path.exists(taken["broke_stale"]["moved_to"]))

    def test_two_recoverers_interleaved_leave_exactly_one_holder(self):
        # Kills: renaming whatever file is at the path after reading it stale (PR #1033 review R3),
        # i.e. the lock not re-read under the recovery flock. The interleaving is the
        # reviewer's: B's whole recovery runs between A's read of the stale lock and A's move. It
        # is injected through `alive`, which A's read calls, so no sleep orders the two.
        dead = 999999
        with open(self.path, "w") as handle:
            json.dump({"pid": dead, "host": socket.gethostname(), "purpose": "gone"}, handle)
        results = {}

        def b_alive(pid):
            return pid != dead

        def a_alive(pid):
            if "b" not in results:
                results["b"] = exclusive.acquire("B", alive=b_alive)
            return pid != dead

        results["a"] = exclusive.acquire("A", alive=a_alive)
        holders = [name for name in ("a", "b") if results[name]["acquired"]]
        self.assertEqual(holders, ["b"])
        with open(self.path) as handle:
            self.assertEqual(json.load(handle)["purpose"], "B")
        self.assertEqual(results["a"]["broke_stale"]["cause"], "the lock changed before recovery")
        self.assertTrue(os.path.exists(exclusive.recover_path(self.path)))

    def test_a_different_stale_lock_found_under_the_flock_is_not_moved(self):
        # Kills: the same-device/inode/bytes comparison dropped from the re-read (moving a stale
        # lock other than the one read). B recovers and takes the lane, then A judges B's pid dead:
        # the file A re-reads is stale, but it is not the file A read, so A leaves it.
        dead = 999999
        with open(self.path, "w") as handle:
            json.dump({"pid": dead, "host": socket.gethostname(), "purpose": "gone"}, handle)
        results = {}

        def a_alive(pid):
            if "b" not in results:
                results["b"] = exclusive.acquire("B", alive=lambda p: p != dead)
            return pid not in (dead, os.getpid())

        results["a"] = exclusive.acquire("A", alive=a_alive)
        self.assertTrue(results["b"]["acquired"])
        self.assertFalse(results["a"]["acquired"])
        self.assertTrue(results["a"]["broke_stale"]["reread"]["stale"])
        self.assertEqual(results["a"]["broke_stale"]["cause"], "the lock changed before recovery")
        with open(self.path) as handle:
            self.assertEqual(json.load(handle)["purpose"], "B")

    def test_the_real_pid_check_sees_a_dead_pid(self):
        # Kills: pid_alive() returning True unconditionally.
        child = os.fork()
        if child == 0:
            os._exit(0)
        os.waitpid(child, 0)
        self.assertIs(exclusive.pid_alive(child), False)
        self.assertIs(exclusive.pid_alive(os.getpid()), True)

    def test_a_live_holder_is_never_broken(self):
        # Kills: breaking any lock that exists.
        exclusive.acquire("holder")
        taken = exclusive.acquire("thief", alive=lambda pid: True)
        self.assertFalse(taken["acquired"])
        self.assertIsNone(taken["broke_stale"])

    def test_a_pidless_lock_cannot_be_proved_stale(self):
        # Kills: an empty lock (live291.sh's `touch`) read as stale.
        open(self.path, "w").close()
        found = exclusive.read_lock(alive=lambda pid: False)
        self.assertFalse(found["stale"])
        self.assertFalse(exclusive.acquire("x", alive=lambda pid: False)["acquired"])

    def test_release_removes_only_its_own_lock(self):
        # Kills: release() unlinking without comparing the token.
        mine = exclusive.acquire("mine")
        os.unlink(self.path)
        theirs = exclusive.acquire("theirs")
        refused = exclusive.release(mine)
        self.assertFalse(refused["released"])
        self.assertTrue(os.path.exists(self.path))
        self.assertTrue(exclusive.release(theirs)["released"])
        self.assertFalse(os.path.exists(self.path))

    def test_waiting_is_bounded_and_says_it_timed_out(self):
        # Kills: wait_and_acquire looping without a deadline or hiding the timeout.
        exclusive.acquire("holder")
        waited = exclusive.wait_and_acquire("waiter", timeout_s=0.3, interval_s=0.1,
                                            alive=lambda pid: True)
        self.assertFalse(waited["acquired"])
        self.assertTrue(waited["timed_out"])
        self.assertGreaterEqual(waited["polls"], 2)


PS_COMM = """\
    1     0 /sbin/launchd
  501     1 /Applications/Logic Pro.app/Contents/MacOS/Logic Pro
  610   600 /Users/me/.verify-build/bin/LogicProMCP-d7fb006de0ead0e94cf3a6f73eed709a983386dc-0123456789abcdef
  620   600 /usr/bin/python3
  630   600 /Applications/Xcode.app/Contents/Developer/usr/bin/xctest
  640   600 /x/.build/debug/LogicProMCPPackageTests.xctest/Contents/MacOS/LogicProMCPPackageTests
  650   600 /x/.build/release/LogicProMCP
"""
PS_ARGS = """\
  620 /usr/bin/python3 live_1020.py --binary /x/.build/release/LogicProMCP
  630 /Applications/Xcode.app/Contents/Developer/usr/bin/xctest /x/.build/debug/LogicProMCPPackageTests.xctest
  640 /x/.build/debug/LogicProMCPPackageTests.xctest/Contents/MacOS/LogicProMCPPackageTests
"""


class Exclusivity(unittest.TestCase):

    def found(self, own=()):
        rows = exclusive.parse_process_table(PS_COMM, PS_ARGS)
        return {r["pid"]: r["kind"] for r in exclusive.competing(rows, own_pids=own)}

    def test_servers_and_test_bundles_are_reported_with_their_pids(self):
        # Kills: the .xctest pattern dropped, or the xctest runner's arguments not consulted.
        self.assertEqual(self.found(), {610: "LogicProMCP server", 630: "test bundle",
                                        640: "test bundle", 650: "LogicProMCP server"})

    def test_a_harness_naming_the_binary_in_its_arguments_is_not_a_server(self):
        # Kills: matching the server pattern against arguments instead of the executable.
        self.assertNotIn(620, self.found())

    def test_logic_itself_is_not_competing(self):
        self.assertNotIn(501, self.found())

    def test_the_run_own_server_is_excluded(self):
        # Kills: own_pids ignored (a run would refuse because of the server it started).
        self.assertNotIn(610, self.found(own=(610,)))


if __name__ == "__main__":
    unittest.main()
