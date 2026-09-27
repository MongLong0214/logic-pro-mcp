#!/usr/bin/env python3
"""Offline: MCP framing, the raw transcript, the distinct timeout, and a verified stop.

Driven against fake_mcp_server.py, a stdio stand-in with the same framing as LogicProMCP.
Each test names the mutation of mcp.py it kills.
"""

import os
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(os.path.dirname(HERE)))

from live import mcp  # noqa: E402

FAKE = os.path.join(HERE, "fake_mcp_server.py")


class Framing(unittest.TestCase):

    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.server = mcp.Server(FAKE, argv=[sys.executable, FAKE], stderr_dir=self.dir.name)
        self.start = self.server.start(init_timeout_s=20)

    def tearDown(self):
        self.server.stop()
        self.dir.cleanup()

    def test_initialize_then_the_initialized_notification(self):
        # Kills: the notifications/initialized line not sent after a successful initialize.
        self.assertTrue(self.start["spawned"])
        self.assertIn("result", self.start["initialize"]["reply"])
        sent = [e["json"] for e in self.server.transcript if e["dir"] == "send"]
        self.assertEqual([m["method"] for m in sent], ["initialize", "notifications/initialized"])
        self.assertEqual(sent[0]["params"]["protocolVersion"], mcp.PROTOCOL_VERSION)

    def test_tool_arguments_nest_command_and_params_and_both_body_shapes_parse(self):
        # Kills: arguments sent flat, or the text-content body not parsed as JSON.
        echo = self.server.tool("logic_tracks", "echo", {"index": 3})
        self.assertEqual(echo["body"], {"echo": {"index": 3}})
        text = self.server.tool("logic_tracks", "text", {"k": 1})
        self.assertEqual(text["body"], {"from": "text", "k": 1})
        call = [e["json"] for e in self.server.transcript
                if e["dir"] == "send" and e["json"].get("method") == "tools/call"][0]
        self.assertEqual(call["params"]["arguments"], {"command": "echo", "params": {"index": 3}})

    def test_resource_body_is_the_json_text_of_the_first_content(self):
        read = self.server.resource("logic://tracks")
        self.assertEqual(read["body"], {"uri": "logic://tracks"})

    def test_the_transcript_is_raw_untruncated_and_stamped_in_order(self):
        # Kills: a reply cut to a prefix (evidence.py's [:400]) or stamps from a non-monotonic clock.
        big = self.server.tool("logic_tracks", "big", {"n": 200000})
        self.assertEqual(len(big["body"]["blob"]), 200000)
        raw = [e for e in self.server.transcript if e["dir"] == "recv"][-1]["raw"]
        self.assertIn("x" * 200000, raw)
        stamps = [e["t"] for e in self.server.transcript]
        self.assertEqual(stamps, sorted(stamps))

    def test_a_line_that_is_not_json_is_kept_and_does_not_break_the_call(self):
        noisy = self.server.tool("logic_tracks", "noise", {"a": 1})
        self.assertEqual(noisy["body"], {"echo": {"a": 1}})
        self.assertIn("this line is not json",
                      [e["raw"] for e in self.server.transcript if e.get("not_json")])

    def test_replies_are_matched_by_id_not_by_order(self):
        # Kills: taking the next reply line as the answer to the current request.
        self.server.tool("logic_tracks", "swap", {"which": "first"}, timeout_s=0.5)
        second = self.server.tool("logic_tracks", "echo", {"which": "second"})
        self.assertEqual(second["body"], {"echo": {"which": "second"}})

    def test_a_timeout_is_reported_as_a_timeout(self):
        # Kills: a timed-out call returned as an empty reply with timed_out False.
        slow = self.server.tool("logic_tracks", "slow", {"s": 2}, timeout_s=0.3)
        self.assertTrue(slow["timed_out"])
        self.assertIsNone(slow["reply"])
        self.assertNotIn("server_exited", slow)
        late = self.server.tool("logic_tracks", "echo", {"after": "slow"}, timeout_s=10)
        self.assertEqual(late["body"], {"echo": {"after": "slow"}})

    def test_a_server_that_exits_is_not_a_timeout(self):
        # Kills: EOF on stdout folded into a timeout.
        gone = self.server.tool("logic_tracks", "exit", {}, timeout_s=10)
        self.assertTrue(gone.get("server_exited"))
        self.assertFalse(gone["timed_out"])

    def test_stderr_goes_to_a_file_the_record_can_read(self):
        stop = self.server.stop()
        self.assertTrue(stop["pid_gone"])
        self.assertIn("[INFO] fake server up", self.server.stderr_text()["value"])


class Stop(unittest.TestCase):

    def test_stop_verifies_the_process_is_gone(self):
        # Kills: stop() returning before the process has exited (pid_gone asserted, not assumed).
        server = mcp.Server(FAKE, argv=[sys.executable, FAKE])
        server.start(init_timeout_s=20)
        pid = server.pid
        record = server.stop()
        self.assertTrue(record["pid_gone"])
        self.assertEqual(record["pid"], pid)
        with self.assertRaises(ProcessLookupError):
            os.kill(pid, 0)


if __name__ == "__main__":
    unittest.main()
