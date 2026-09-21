#!/usr/bin/env python3
"""Unit coverage for the Logic Controller Assignments Learn Mode guard."""

from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path

import logic_session_bootstrap as bootstrap_module
from logic_controller_learn_mode import (
    DEFAULT_CONTROLLER_LEARN_MODE_POLICY,
    classify_controller_learn_mode,
    guard_controller_learn_mode,
)


class FakeRunner:
    def __init__(self, snapshot):
        self.snapshot = snapshot
        self.detect_calls = 0

    def detect(self):
        self.detect_calls += 1
        return self.snapshot


class ControllerLearnModeGuardTests(unittest.TestCase):
    def test_inactive_snapshot_is_clear(self):
        result = guard_controller_learn_mode(
            runner=FakeRunner(
                {
                    "status": "present",
                    "title": "Tracks",
                    "buttons": [],
                    "checkboxes": [],
                    "static_texts": ["Tracks"],
                }
            )
        )

        self.assertEqual(result["status"], "clear")
        self.assertEqual(result["policy_id"], DEFAULT_CONTROLLER_LEARN_MODE_POLICY["policy_id"])

    def test_assignment_prompt_blocks(self):
        result = guard_controller_learn_mode(
            runner=FakeRunner(
                {
                    "status": "present",
                    "title": "Controller Assignments",
                    "buttons": ["Cancel", "OK"],
                    "checkboxes": [],
                    "static_texts": ["This control is already assigned to another parameter."],
                }
            )
        )

        self.assertEqual(result["status"], "blocked")
        self.assertEqual(result["reason"], "assignment_prompt_present")
        self.assertIn("This control is already assigned", " ".join(result["evidence"]["labels"]))

    def test_enabled_learn_mode_checkbox_blocks(self):
        result = guard_controller_learn_mode(
            runner=FakeRunner(
                {
                    "status": "present",
                    "title": "Controller Assignments",
                    "buttons": [],
                    "checkboxes": [{"name": "Learn Mode", "value": "1"}],
                    "static_texts": ["Controller Assignments"],
                }
            )
        )

        self.assertEqual(result["status"], "blocked")
        self.assertEqual(result["reason"], "learn_mode_enabled")
        self.assertEqual(result["evidence"]["control"]["name"], "Learn Mode")

    def test_detect_error_returns_error_with_policy_id(self):
        result = guard_controller_learn_mode(
            runner=FakeRunner({"status": "error", "reason": "osascript_failed", "stderr": "denied"})
        )

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["reason"], "osascript_failed")
        self.assertEqual(result["policy_id"], DEFAULT_CONTROLLER_LEARN_MODE_POLICY["policy_id"])

    def test_classifier_accepts_not_present_as_inactive(self):
        result = classify_controller_learn_mode({"status": "not_present"})

        self.assertEqual(result["status"], "inactive")
        self.assertEqual(result["reason"], "not_present")


class LiveE2EGuardedCallTests(unittest.TestCase):
    @staticmethod
    def load_live_e2e_module():
        module_path = Path(__file__).with_name("live-e2e-test.py")
        spec = importlib.util.spec_from_file_location("live_e2e_test_module", module_path)
        module = importlib.util.module_from_spec(spec)
        assert spec.loader is not None
        spec.loader.exec_module(module)
        return module

    def test_guarded_live_tool_call_does_not_call_client_when_blocked(self):
        module = self.load_live_e2e_module()

        class FakeClient:
            def __init__(self):
                self.calls = []

            def send(self, message, timeout=None):
                self.calls.append((message, timeout))
                return {"result": {"content": [{"type": "text", "text": "called"}]}}

        client = FakeClient()
        result = module.guarded_live_tool_call(
            client,
            "logic_midi",
            "play_sequence",
            {"notes": "60,0,100"},
            ready=False,
            reason="controller assignments Learn Mode guard blocked",
        )

        self.assertEqual(client.calls, [])
        self.assertEqual(result["gate"], "controller assignments Learn Mode guard blocked")
        self.assertEqual(result["tool"], "logic_midi")
        self.assertEqual(result["command"], "play_sequence")
        self.assertTrue(module.is_error(result))

    def test_bootstrap_failure_reason_includes_hint(self):
        module = self.load_live_e2e_module()
        bootstrap = bootstrap_module.BootstrapResult(
            ok=False,
            reason="fresh_project_close_failed",
            hint="Dismiss modal dialogs and retry.",
        )

        self.assertEqual(
            module.bootstrap_failure_reason(bootstrap),
            "fresh bootstrap failed: fresh_project_close_failed (Dismiss modal dialogs and retry.)",
        )

    def test_bootstrap_status_payload_embeds_failed_bootstrap_detail(self):
        module = self.load_live_e2e_module()
        bootstrap = bootstrap_module.BootstrapResult(
            ok=False,
            reason="health_unavailable",
            hint="Could not read logic_system.health from the MCP server.",
        )

        payload = module.bootstrap_status_payload("fresh bootstrap failed: health_unavailable", bootstrap)

        self.assertEqual(payload["result"]["bootstrap"], "fresh bootstrap failed: health_unavailable")
        self.assertEqual(payload["result"]["detail"]["reason"], "health_unavailable")
        self.assertEqual(
            payload["result"]["detail"]["hint"],
            "Could not read logic_system.health from the MCP server.",
        )


if __name__ == "__main__":
    unittest.main()
