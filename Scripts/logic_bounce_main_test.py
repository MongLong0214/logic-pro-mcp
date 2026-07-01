#!/usr/bin/env python3
from __future__ import annotations

import contextlib
import io
import json
import os
import sys
import tempfile
import unittest
from unittest import mock

import logic_bounce


def _window_metrics_osa(script, timeout=logic_bounce.OSA_TIMEOUT_SEC):
    if "position of front window" in script:
        return "100, 200"
    if "size of front window" in script:
        return "800, 600"
    return ""


def _ui_events_with_staged_artifact(staging_dir: str, typed_name):
    def fake_ui_events(*commands):
        for command in commands:
            if command.startswith("t:"):
                typed_name["value"] = command[2:]
        if "c:840,768" in commands and typed_name["value"] is not None:
            artifact = os.path.join(staging_dir, f"{typed_name['value']}.aif")
            with open(artifact, "wb") as handle:
                handle.write(b"bounce")
            os.utime(artifact, (1001.0, 1001.0))
        return True

    return fake_ui_events


class LogicBounceMainTests(unittest.TestCase):
    def test_main_fails_closed_when_save_panel_is_not_detected(self):
        with tempfile.TemporaryDirectory() as staging_dir, tempfile.TemporaryDirectory() as output_dir:
            argv = [
                "logic_bounce.py",
                "--target-path", os.path.join(output_dir, "Song.wav"),
                "--staging", staging_dir,
            ]
            stdout = io.StringIO()
            with (
                mock.patch.object(sys, "argv", argv),
                mock.patch.object(logic_bounce, "set_input_abc", return_value=True),
                mock.patch.object(logic_bounce, "open_bounce_dialog", return_value=(True, ["key_command"])),
                mock.patch.object(logic_bounce, "click_bounce_settings_confirm", return_value=True),
                mock.patch.object(logic_bounce, "bounce_dialog_present", return_value=False),
                mock.patch.object(logic_bounce, "bounce_focus_diagnostics", return_value={"frontmost_app": "Logic Pro"}),
                mock.patch.object(logic_bounce, "save_panel_present", return_value=False),
                mock.patch.object(logic_bounce, "osa", side_effect=_window_metrics_osa),
                mock.patch.object(logic_bounce, "send_ui_events", return_value=None),
                mock.patch.object(logic_bounce.time, "sleep", lambda _: None),
                mock.patch.object(logic_bounce.time, "time", lambda: 1000.0),
                contextlib.redirect_stdout(stdout),
            ):
                exit_code = logic_bounce.main()

            result = json.loads(stdout.getvalue().strip())
            self.assertEqual(exit_code, 1, result)
            self.assertEqual(result["error"], "bounce_save_panel_did_not_appear")
            self.assertFalse(result["save_panel_present"])

    def test_main_accepts_save_panel_even_when_window_title_still_contains_bounce(self):
        with tempfile.TemporaryDirectory() as staging_dir, tempfile.TemporaryDirectory() as output_dir:
            typed_name = {"value": None}
            staged_name = "Song--lpmcp-fixed"
            argv = [
                "logic_bounce.py",
                "--target-path", os.path.join(output_dir, "Song.wav"),
                "--staging", staging_dir,
            ]
            stdout = io.StringIO()
            with (
                mock.patch.object(sys, "argv", argv),
                mock.patch.object(logic_bounce, "set_input_abc", return_value=True),
                mock.patch.object(logic_bounce, "open_bounce_dialog", return_value=(True, ["key_command"])),
                mock.patch.object(logic_bounce, "click_bounce_settings_confirm", return_value=True),
                mock.patch.object(logic_bounce, "bounce_dialog_present", return_value=True),
                mock.patch.object(logic_bounce, "save_panel_present", return_value=True),
                mock.patch.object(logic_bounce, "osa", side_effect=_window_metrics_osa),
                mock.patch.object(logic_bounce, "send_ui_events", side_effect=_ui_events_with_staged_artifact(staging_dir, typed_name)),
                mock.patch.object(logic_bounce.time, "sleep", lambda _: None),
                mock.patch.object(logic_bounce.time, "time", lambda: 1000.0),
                mock.patch.object(logic_bounce, "unique_staging_name", return_value=staged_name),
                contextlib.redirect_stdout(stdout),
            ):
                exit_code = logic_bounce.main()

            result = stdout.getvalue().strip()
            self.assertEqual(exit_code, 0, result)
            self.assertEqual(typed_name["value"], staged_name)
            self.assertTrue(os.path.exists(os.path.join(output_dir, "Song.aif")))

    def test_main_types_unique_staging_name_before_polling_staging(self):
        with tempfile.TemporaryDirectory() as staging_dir, tempfile.TemporaryDirectory() as output_dir:
            typed_name = {"value": None}
            staged_name = "Song--lpmcp-fixed"
            argv = [
                "logic_bounce.py",
                "--target-path", os.path.join(output_dir, "Song.wav"),
                "--staging", staging_dir,
            ]
            stdout = io.StringIO()
            with (
                mock.patch.object(sys, "argv", argv),
                mock.patch.object(logic_bounce, "set_input_abc", return_value=True),
                mock.patch.object(logic_bounce, "open_bounce_dialog", return_value=(True, ["key_command"])),
                mock.patch.object(logic_bounce, "click_bounce_settings_confirm", return_value=True),
                mock.patch.object(logic_bounce, "bounce_dialog_present", return_value=False),
                mock.patch.object(logic_bounce, "save_panel_present", return_value=True),
                mock.patch.object(logic_bounce, "osa", side_effect=_window_metrics_osa),
                mock.patch.object(logic_bounce, "send_ui_events", side_effect=_ui_events_with_staged_artifact(staging_dir, typed_name)),
                mock.patch.object(logic_bounce.time, "sleep", lambda _: None),
                mock.patch.object(logic_bounce.time, "time", lambda: 1000.0),
                mock.patch.object(logic_bounce, "unique_staging_name", return_value=staged_name),
                contextlib.redirect_stdout(stdout),
            ):
                exit_code = logic_bounce.main()

            result = stdout.getvalue().strip()
            self.assertEqual(exit_code, 0, result)
            self.assertEqual(typed_name["value"], staged_name)
            self.assertTrue(os.path.exists(os.path.join(output_dir, "Song.aif")))

    def test_main_keeps_bounce_fired_false_when_final_bounce_click_fails(self):
        with tempfile.TemporaryDirectory() as staging_dir, tempfile.TemporaryDirectory() as output_dir:
            argv = [
                "logic_bounce.py",
                "--target-path", os.path.join(output_dir, "Song.wav"),
                "--staging", staging_dir,
            ]
            stdout = io.StringIO()

            def fake_ui_events(*commands):
                return "c:840,768" not in commands

            with (
                mock.patch.object(sys, "argv", argv),
                mock.patch.object(logic_bounce, "set_input_abc", return_value=True),
                mock.patch.object(logic_bounce, "open_bounce_dialog", return_value=(True, ["key_command"])),
                mock.patch.object(logic_bounce, "click_bounce_settings_confirm", return_value=True),
                mock.patch.object(logic_bounce, "save_panel_present", return_value=True),
                mock.patch.object(logic_bounce, "osa", side_effect=_window_metrics_osa),
                mock.patch.object(logic_bounce, "send_ui_events", side_effect=fake_ui_events),
                mock.patch.object(logic_bounce.time, "sleep", lambda _: None),
                mock.patch.object(logic_bounce.time, "time", lambda: 1000.0),
                mock.patch.object(logic_bounce, "unique_staging_name", return_value="Song--lpmcp-fixed"),
                contextlib.redirect_stdout(stdout),
            ):
                exit_code = logic_bounce.main()

            result = json.loads(stdout.getvalue().strip())
            self.assertEqual(exit_code, 1, result)
            self.assertFalse(result["bounce_fired"], result)
            self.assertEqual(result["error"], "bounce_button_click_failed")
