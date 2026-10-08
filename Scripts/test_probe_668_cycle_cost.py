#!/usr/bin/env python3
"""Exercise the real cycle probe with synthetic stdio replies, never a native server."""
import contextlib
import io
import itertools
import json
from pathlib import Path
import queue
import runpy
import sys
import threading
import unittest
from unittest.mock import patch


PROBE = Path(__file__).parent / "livekit" / "probe_668_cycle_cost.py"
GOOD = {"result": {"structuredContent": {
    "operation": "system.refresh_cache", "source": "ax_fallback_poller",
    "refreshed": True,
}}}


class StdioFixture:
    def __init__(self, failed_sample, reply, readable):
        self.failed_sample = failed_sample
        self.reply = reply
        self.readable = readable
        self.samples = 0
        self.lines = queue.Queue()
        self.stdin = self
        self.stdout = iter(self.lines.get, None)
        self.stopped = False

    def write(self, line):
        request = json.loads(line)
        if request["method"] == "tools/call":
            sample = self.samples
            self.samples += 1
            response = self.reply if sample == self.failed_sample else GOOD
        elif request["method"] == "resources/read":
            response = {"result": {"contents": [{"text": json.dumps({
                "readable": self.readable, "data": [{}] * 81,
            })}]}}
        else:
            response = {"result": {}}
        if response is None:
            return  # Exercise the actual client's unanswered-request path.
        self.lines.put(json.dumps({"jsonrpc": "2.0", "id": request["id"], **response}) + "\n")

    def flush(self):
        pass

    def terminate(self):
        self.stopped = True
        self.lines.put(None)


def run_probe(failed_sample=None, reply=GOOD, step=1, readable=True):
    fixture = StdioFixture(failed_sample, reply, readable)
    output = io.StringIO()
    ticks = itertools.count(step=step)
    event_wait = threading.Event.wait
    with patch("subprocess.Popen", return_value=fixture) as start, \
            patch("os.path.exists", return_value=True), \
            patch("time.sleep"), patch("time.monotonic", side_effect=lambda: next(ticks)), \
            patch("threading.Event.wait", new=lambda event, timeout=None:
                  event_wait(event, min(timeout, 0.2) if timeout is not None else None)), \
            patch.object(sys, "argv", [str(PROBE), "synthetic-worktree"]), \
            patch.object(sys, "path", list(sys.path)), contextlib.redirect_stdout(output):
        try:
            runpy.run_path(str(PROBE), run_name="__main__")
        except SystemExit as exc:
            code = exc.code
    assert start.call_count == 1
    assert fixture.stopped
    return code, output.getvalue()


class CycleProbeTests(unittest.TestCase):
    def test_successful_refresh_samples_still_fit(self):
        code, report = run_probe()
        self.assertEqual(code, 0, report)
        self.assertIn("FITS at 81 tracks", report)

    def test_failed_refresh_is_not_a_fast_success(self):
        replies = {
            "unanswered_request": None,
            "rpc_error": {"error": {"code": -32603, "message": "failed"}},
            "missing_result": {},
            "missing_structured_content": {"result": {}},
            "missing_refresh_flag": {"result": {"structuredContent": {}}},
            "no_cache_advance": {"result": {"structuredContent": {"refreshed": False}}},
            "tool_error": {"result": {"isError": True,
                                      "structuredContent": {"refreshed": True}}},
            "non_object_result": {"result": ["refreshed"]},
            "non_object_body": {"result": {"structuredContent": [True]}},
            "truthy_string": {"result": {"structuredContent": dict(
                GOOD["result"]["structuredContent"], refreshed="true")}},
            "truthy_integer": {"result": {"structuredContent": dict(
                GOOD["result"]["structuredContent"], refreshed=1)}},
        }
        # Warm-up, the first solo cycle and one concurrent cycle must all count.
        for sample in (0, 1, 6):
            for name, reply in replies.items():
                with self.subTest(sample=sample, reply=name):
                    code, report = run_probe(sample, reply)
                    self.assertNotEqual(code, 0, report)
                    self.assertNotIn("FITS at", report)
                    self.assertIn("REFUSED", report)

    def test_success_flag_must_belong_to_the_actual_refresh_poller(self):
        for key, value in (("operation", "system.health"), ("source", "none")):
            for sample in (0, 1, 6):
                with self.subTest(sample=sample, key=key):
                    body = dict(GOOD["result"]["structuredContent"], **{key: value})
                    code, report = run_probe(sample, {"result": {"structuredContent": body}})
                    self.assertNotEqual(code, 0, report)
                    self.assertNotIn("FITS at", report)
                    self.assertIn("REFUSED", report)

    def test_unreadable_project_still_refuses(self):
        code, report = run_probe(readable=False)
        self.assertEqual(code, 2, report)
        self.assertIn("REFUSED", report)
        self.assertNotIn("FITS at", report)

    def test_empty_walk_timing_still_refuses(self):
        code, report = run_probe(step=0.001)
        self.assertEqual(code, 2, report)
        self.assertIn("REFUSED", report)
        self.assertNotIn("FITS at", report)

    def test_censored_success_samples_still_refuse(self):
        code, report = run_probe(step=25)
        self.assertEqual(code, 1, report)
        self.assertIn("CENSORED", report)
        self.assertNotIn("FITS at", report)


if __name__ == "__main__":
    unittest.main()
